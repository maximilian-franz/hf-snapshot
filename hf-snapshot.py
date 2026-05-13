from __future__ import annotations

import csv
import json
import logging
import sys
import os
import subprocess
import tempfile
import time
import requests
import io
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import TypedDict, Optional
import traceback
import html

from dotenv import load_dotenv
from huggingface_hub import HfApi, hf_hub_download
from huggingface_hub.errors import EntryNotFoundError
from huggingface_hub.utils import HfHubHTTPError


SCRIPT_DIR = Path(__file__).resolve().parent
load_dotenv(SCRIPT_DIR / ".env")


METADATA_HEADERS = ["file_name", "camera_id", "timestamp"]
FFMPEG_BINARY = os.getenv("FFMPEG_BINARY", "ffmpeg")
FFMPEG_INPUT_FORMAT = os.getenv("FFMPEG_INPUT_FORMAT", "mjpeg")
FFMPEG_VIDEO_SIZE = os.getenv("FFMPEG_VIDEO_SIZE", "3840x2160")
CAPTURE_WARMUP_SECONDS = float(os.getenv("CAPTURE_WARMUP_SECONDS", "4.0"))
CAPTURE_RETRY_COUNT = int(os.getenv("CAPTURE_RETRY_COUNT", "3"))
CAPTURE_RETRY_DELAY_SECONDS = float(os.getenv("CAPTURE_RETRY_DELAY_SECONDS", "2.0"))


class MetadataRow(TypedDict):
    file_name: str
    camera_id: str
    timestamp: str


@dataclass(frozen=True)
class Config:
    hf_token: str
    hf_repo_id: str
    camera_config_file: Path
    upload_retry_count: int
    upload_retry_delay_seconds: float
    telegram_bot_token: Optional[str] = None
    telegram_chat_id: Optional[str] = None


@dataclass(frozen=True)
class SnapshotRecord:
    camera_id: str
    local_path: Path
    remote_path: str
    timestamp: str


class CameraConfigRow(TypedDict):
    device_path: str
    camera_name: str
    rotation: int


def setup_logging() -> tuple[logging.Logger, io.StringIO]:
    logger = logging.getLogger("hf_snapshot")
    logger.setLevel(logging.INFO)
    logger.propagate = False

    # Console handler (goes to stderr / systemd journal)
    console_handler = logging.StreamHandler(sys.stderr)
    console_handler.setLevel(logging.INFO)
    console_handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    logger.addHandler(console_handler)

    # In-memory buffer so we can ship logs to Telegram at the end of a run.
    buf = io.StringIO()
    buf_handler = logging.StreamHandler(buf)
    buf_handler.setLevel(logging.DEBUG)
    buf_handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    logger.addHandler(buf_handler)

    return logger, buf


def env_required(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def load_config() -> Config:
    return Config(
        hf_token=env_required("HF_TOKEN"),
        hf_repo_id=env_required("HF_REPO_ID"),
        camera_config_file=Path(
            os.getenv("CAMERA_CONFIG_FILE", str(SCRIPT_DIR / "cameras.json"))
        ),
        upload_retry_count=int(os.getenv("UPLOAD_RETRY_COUNT", "3")),
        upload_retry_delay_seconds=float(
            os.getenv("UPLOAD_RETRY_DELAY_SECONDS", "2.0")
        ),
        telegram_bot_token=os.getenv("TELEGRAM_BOT_TOKEN") or None,
        telegram_chat_id=os.getenv("TELEGRAM_CHAT_ID") or None,
    )


def send_telegram_alert(
    bot_token: str,
    chat_id: str,
    message: str,
    logger: logging.Logger,
    parse_mode: Optional[str] = None,
) -> None:
    if not bot_token or not chat_id:
        return

    try:
        url = f"https://api.telegram.org/bot{bot_token}/sendMessage"
        payload = {"chat_id": chat_id, "text": message}
        if parse_mode:
            payload["parse_mode"] = parse_mode
        resp = requests.post(url, data=payload, timeout=10)
        if resp.ok:
            logger.info("Sent Telegram alert to chat_id %s", chat_id)
        else:
            logger.error("Telegram API returned %s: %s", resp.status_code, resp.text)
    except Exception:
        logger.exception("Failed to send Telegram alert")


def load_camera_config(path: Path, logger: logging.Logger) -> list[CameraConfigRow]:
    if not path.exists():
        raise RuntimeError(f"Camera config file does not exist: {path}")

    with open(path, "r", encoding="utf-8") as f:
        payload = json.load(f)

    cameras = payload.get("cameras")
    if not isinstance(cameras, list) or not cameras:
        raise RuntimeError(f"Camera config file has no cameras: {path}")

    parsed_cameras: list[CameraConfigRow] = []
    seen_device_paths: set[str] = set()
    seen_camera_names: set[str] = set()

    for index, camera in enumerate(cameras, start=1):
        if not isinstance(camera, dict):
            raise RuntimeError(f"Camera config entry {index} is not an object")

        device_path = camera.get("device_path")
        camera_name = camera.get("camera_name")
        rotation_val = camera.get("rotation", 0)

        if not isinstance(device_path, str) or not device_path.strip():
            raise RuntimeError(f"Camera config entry {index} is missing device_path")
        if not isinstance(camera_name, str) or not camera_name.strip():
            raise RuntimeError(f"Camera config entry {index} is missing camera_name")
        camera_name = camera_name.strip()
        if "/" in camera_name:
            raise RuntimeError(
                f"Camera config entry {index} has invalid camera_name containing '/': {camera_name}"
            )

        # normalize rotation
        try:
            rotation = int(rotation_val)
        except Exception:
            raise RuntimeError(f"Camera config entry {index} has invalid rotation: {rotation_val}")
        if rotation not in (0, 90, 180, 270):
            raise RuntimeError(f"Camera config entry {index} has unsupported rotation: {rotation}")

        resolved_device_path = Path(device_path)
        if not device_path.startswith("/dev/v4l/by-path/"):
            raise RuntimeError(
                f"Camera config entry {index} must use a persistent /dev/v4l/by-path device path: {device_path}"
            )

        if not resolved_device_path.exists():
            logger.error(
                "Camera config entry %s points to a missing device path: %s; skipping",
                index,
                device_path,
            )
            continue

        real_device_path = resolved_device_path.resolve()
        if not real_device_path.is_char_device():
            raise RuntimeError(
                f"Camera config entry {index} does not resolve to a character device: {device_path}"
            )
        if device_path in seen_device_paths:
            raise RuntimeError(f"Camera config contains duplicate device path: {device_path}")
        if camera_name in seen_camera_names:
            raise RuntimeError(f"Camera config contains duplicate camera name: {camera_name}")

        seen_device_paths.add(device_path)
        seen_camera_names.add(camera_name)
        parsed_cameras.append(
            {
                "device_path": device_path,
                "camera_name": camera_name,
                "rotation": rotation,
            }
        )

    return parsed_cameras


def capture_snapshot(device: str, output: Path, rotation: int, logger: logging.Logger) -> None:
    cmd = [
        FFMPEG_BINARY,
        "-y",
        "-f",
        "v4l2",
        "-input_format",
        FFMPEG_INPUT_FORMAT,
        "-video_size",
        FFMPEG_VIDEO_SIZE,
        "-i",
        device,
    ]

    vf_parts: list[str] = []
    if CAPTURE_WARMUP_SECONDS > 0:
        vf_parts.append(f"select='gte(t,{CAPTURE_WARMUP_SECONDS})'")

    if rotation == 90:
        vf_parts.append("transpose=1")
    elif rotation == 180:
        vf_parts.append("transpose=1")
        vf_parts.append("transpose=1")
    elif rotation == 270:
        vf_parts.append("transpose=2")

    if vf_parts:
        cmd.extend(["-vf", ",".join(vf_parts), "-fps_mode", "vfr"])

    # Use the image2 muxer `-update 1` to write/overwrite a single image
    # and add retry logic for transient device/driver errors.
    cmd.extend(["-f", "image2", "-update", "1", "-frames:v", "1", str(output)])


    transient_indicators = [
        "Protocol error",
        "Bad file descriptor",
        "Nothing was written",
        "Device or resource busy",
        "No such device",
        "Device not accepting",
        "failed to resubmit",
        "device descriptor read",
        "unable to enumerate",
    ]

    last_exc: subprocess.CalledProcessError | None = None
    for attempt in range(1, CAPTURE_RETRY_COUNT + 1):
        try:
            logger.debug("Running ffmpeg capture attempt %s/%s: %s", attempt, CAPTURE_RETRY_COUNT, " ".join(cmd))
            subprocess.run(cmd, check=True, capture_output=True, text=True)
            return
        except subprocess.CalledProcessError as exc:
            last_exc = exc
            stderr_text = (exc.stderr or "").strip()
            stdout_text = (exc.stdout or "").strip()

            # Decide whether this looks like a transient error we should retry.
            should_retry = False
            combined = f"{stderr_text}\n{stdout_text}".lower()
            for token in transient_indicators:
                if token.lower() in combined:
                    should_retry = True
                    break

            if attempt < CAPTURE_RETRY_COUNT and should_retry:
                backoff = CAPTURE_RETRY_DELAY_SECONDS * (2 ** (attempt - 1))
                logger.warning(
                    "Transient ffmpeg error on %s (attempt %s/%s): %s. Retrying in %.1f s",
                    device,
                    attempt,
                    CAPTURE_RETRY_COUNT,
                    stderr_text.splitlines()[-1] if stderr_text else repr(exc),
                    backoff,
                )
                time.sleep(backoff)
                continue

            # Non-retryable or no attempts left: re-raise so caller can handle/log stderr.
            raise

    # If we fall out of loop, raise the last exception for the caller to handle.
    if last_exc:
        raise last_exc


def upload_file_with_retries(
    api: HfApi,
    repo_id: str,
    token: str,
    local_path: Path,
    remote_path: str,
    retry_count: int,
    retry_delay_seconds: float,
    logger: logging.Logger,
) -> None:
    retryable_errors = (HfHubHTTPError,)
    last_error: Exception | None = None

    for attempt in range(1, retry_count + 1):
        try:
            api.upload_file(
                path_or_fileobj=str(local_path),
                path_in_repo=remote_path,
                repo_id=repo_id,
                repo_type="dataset",
                token=token,
            )
            return
        except retryable_errors as exc:
            last_error = exc
            if attempt < retry_count:
                logger.warning(
                    "Upload attempt %s/%s failed for %s: %s. Retrying in %.1f seconds.",
                    attempt,
                    retry_count,
                    local_path,
                    exc,
                    retry_delay_seconds,
                )
                time.sleep(retry_delay_seconds)
            else:
                logger.error(
                    "Upload attempt %s/%s failed for %s: %s",
                    attempt,
                    retry_count,
                    local_path,
                    exc,
                )

    if last_error is None:
        raise RuntimeError(f"Upload failed for {local_path} but no retryable exception was captured")

    raise last_error


def download_metadata_csv(
    repo_id: str,
    token: str,
    logger: logging.Logger,
) -> list[MetadataRow]:
    try:
        metadata_path = hf_hub_download(
            repo_id=repo_id,
            repo_type="dataset",
            filename="metadata.csv",
            token=token,
        )
    except EntryNotFoundError:
        logger.info(
            "Remote metadata.csv not found yet. Starting with an empty metadata table."
        )
        return []

    rows: list[MetadataRow] = []
    with open(metadata_path, "r", newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(
                {
                    "file_name": row["file_name"],
                    "camera_id": row["camera_id"],
                    "timestamp": row["timestamp"],
                }
            )
    return rows


def write_metadata_csv(path: Path, rows: list[MetadataRow]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=METADATA_HEADERS)
        writer.writeheader()
        writer.writerows(rows)


def merge_metadata_rows(
    existing_rows: list[MetadataRow],
    new_records: list[SnapshotRecord],
) -> list[MetadataRow]:
    merged_rows = list(existing_rows)
    file_name_to_index = {
        row["file_name"]: index for index, row in enumerate(merged_rows)
    }

    for record in new_records:
        row = {
            "file_name": f"{record.camera_id}/{record.local_path.name}",
            "camera_id": record.camera_id,
            "timestamp": record.timestamp,
        }

        existing_index = file_name_to_index.get(row["file_name"])
        if existing_index is not None:
            # Keep row ordering stable while refreshing data for duplicate keys.
            merged_rows[existing_index] = row
        else:
            file_name_to_index[row["file_name"]] = len(merged_rows)
            merged_rows.append(row)

    return merged_rows


def main(logger: Optional[logging.Logger] = None, log_buffer: Optional[io.StringIO] = None) -> int:
    if logger is None or log_buffer is None:
        logger, log_buffer = setup_logging()

    config = load_config()

    logger.info("Starting snapshot capture and publish run.")

    camera_configs = load_camera_config(config.camera_config_file, logger)
    logger.info(
        "Loaded camera config from %s with cameras: %s",
        config.camera_config_file,
        ", ".join(
            f"{camera['camera_name']}={camera['device_path']}" for camera in camera_configs
        ),
    )

    failures: list[str] = []
    records: list[SnapshotRecord] = []

    api = HfApi(token=config.hf_token)
    existing_rows = download_metadata_csv(
        repo_id=config.hf_repo_id,
        token=config.hf_token,
        logger=logger,
    )

    with tempfile.TemporaryDirectory(prefix="hf-snapshot-captures-") as tmpdir:
        capture_dir = Path(tmpdir)
        for camera in camera_configs:
            camera_id = camera["camera_name"]
            device_path = Path(camera["device_path"])
            rotation = int(camera.get("rotation", 0))
            capture_started_at = datetime.now().astimezone()
            output_name = f"{camera_id}-{capture_started_at.strftime('%Y-%m-%dT%H-%M-%S-%f')}.jpg"
            output_path = capture_dir / output_name

            try:
                capture_snapshot(str(device_path), output_path, rotation, logger)
            except subprocess.CalledProcessError as exc:
                logger.exception("ffmpeg capture failed for %s: %s", device_path, exc)
                if exc.stderr:
                    logger.error("ffmpeg stderr for %s:\n%s", camera_id, exc.stderr.strip())
                failures.append(f"{camera_id}: snapshot capture failed: {exc}")
                if exc.stderr:
                    failures.append(f"{camera_id}: ffmpeg stderr:\n{exc.stderr.strip()}")
                continue
            except FileNotFoundError as exc:
                logger.exception("ffmpeg executable not found: %s", exc)
                return 1

            records.append(
                SnapshotRecord(
                    camera_id=camera_id,
                    local_path=output_path,
                    remote_path=f"{camera_id}/{output_path.name}",
                    timestamp=capture_started_at.isoformat(timespec="seconds"),
                )
            )

        if not records:
            logger.error("No snapshots were captured successfully.")
            for failure in failures:
                logger.error("  %s", failure)
            return 1

        for record in records:
            try:
                upload_file_with_retries(
                    api=api,
                    repo_id=config.hf_repo_id,
                    token=config.hf_token,
                    local_path=record.local_path,
                    remote_path=record.remote_path,
                    retry_count=config.upload_retry_count,
                    retry_delay_seconds=config.upload_retry_delay_seconds,
                    logger=logger,
                )
                logger.info("Uploaded %s -> %s.", record.local_path, record.remote_path)
            except Exception as exc:
                failures.append(f"{record.camera_id}: image upload failed: {exc}")

        if failures:
            logger.error("Run completed with failures during image upload:")
            for failure in failures:
                logger.error("  %s", failure)

            # Send Telegram alert if configured
            if config.telegram_bot_token and config.telegram_chat_id:
                message_lines = ["hf-snapshot: upload run failed.", "Failures:"]
                for failure in failures:
                    message_lines.append(f"- {failure}")
                message = "\n".join(message_lines)
                send_telegram_alert(config.telegram_bot_token, config.telegram_chat_id, message, logger)

            return 1

        updated_rows = merge_metadata_rows(existing_rows, records)

        with tempfile.TemporaryDirectory(prefix="hf-snapshot-metadata-") as metadata_tmpdir:
            metadata_local_path = Path(metadata_tmpdir) / "metadata.csv"
            write_metadata_csv(metadata_local_path, updated_rows)

            try:
                upload_file_with_retries(
                    api=api,
                    repo_id=config.hf_repo_id,
                    token=config.hf_token,
                    local_path=metadata_local_path,
                    remote_path="metadata.csv",
                    retry_count=config.upload_retry_count,
                    retry_delay_seconds=config.upload_retry_delay_seconds,
                    logger=logger,
                )
                logger.info("Uploaded updated metadata.csv.")
            except Exception as exc:
                logger.error("Metadata upload failed: %s", exc)
                return 1

    logger.info("Run completed successfully.")
    return 0


if __name__ == "__main__":
    logger, log_buffer = setup_logging()
    # Read Telegram config early so we can notify on any failure
    telegram_bot = os.getenv("TELEGRAM_BOT_TOKEN") or None
    telegram_chat = os.getenv("TELEGRAM_CHAT_ID") or None

    try:
        exit_code = main(logger=logger, log_buffer=log_buffer)
    except Exception as exc:  # catch any uncaught exception
        tb = traceback.format_exc()
        logger.exception("Uncaught exception in hf-snapshot: %s", exc)
        if telegram_bot and telegram_chat:
            log_text = log_buffer.getvalue()
            max_len = 3800
            if len(log_text) > max_len:
                log_text = "(...truncated...)\n" + log_text[-max_len:]
            # Escape for HTML and wrap in a preformatted block for readability
            escaped = html.escape(log_text + "\n\nTraceback:\n" + tb)
            message_html = f"<pre>{escaped}</pre>"
            send_telegram_alert(telegram_bot, telegram_chat, message_html, logger, parse_mode="HTML")
        raise SystemExit(1)
    else:
        # If the program ended with a non-zero exit code, ensure we notify
        if exit_code != 0:
            logger.error("hf-snapshot exited with code %s", exit_code)
            if telegram_bot and telegram_chat:
                log_text = log_buffer.getvalue()
                max_len = 3800
                if len(log_text) > max_len:
                    log_text = "(...truncated...)\n" + log_text[-max_len:]
                escaped = html.escape(log_text)
                message_html = f"<pre>hf-snapshot: run completed with exit code {exit_code}.\n\n{escaped}</pre>"
                send_telegram_alert(telegram_bot, telegram_chat, message_html, logger, parse_mode="HTML")
        raise SystemExit(exit_code)
