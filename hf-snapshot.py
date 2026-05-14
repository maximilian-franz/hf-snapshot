from __future__ import annotations

import csv
import json
import logging
import sys
import os
import subprocess
import tempfile
import shutil
import time
import requests
import io
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import TypedDict, Optional
import traceback

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

TRANSIENT_ERROR_INDICATORS = [
    "protocol error",
    "bad file descriptor",
    "nothing was written",
    "device or resource busy",
    "no such device",
    "device not accepting",
    "failed to resubmit",
    "device descriptor read",
    "unable to enumerate",
]

TELEGRAM_MAX_IMAGES_PER_GROUP = 10

MAX_PREVIEW_IMAGE_EDGE = 640
PREVIEW_IMAGE_QV = 8


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

    console_handler = logging.StreamHandler(sys.stderr)
    console_handler.setLevel(logging.INFO)
    console_handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    logger.addHandler(console_handler)

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
    try:
        upload_retry_count = int(os.getenv("UPLOAD_RETRY_COUNT", "3"))
        upload_retry_delay = float(os.getenv("UPLOAD_RETRY_DELAY_SECONDS", "2.0"))
    except ValueError as exc:
        raise RuntimeError(f"Invalid retry configuration: {exc}") from exc

    if upload_retry_count <= 0:
        raise RuntimeError("UPLOAD_RETRY_COUNT must be greater than 0")
    if upload_retry_delay <= 0:
        raise RuntimeError("UPLOAD_RETRY_DELAY_SECONDS must be greater than 0")
    
    return Config(
        hf_token=env_required("HF_TOKEN"),
        hf_repo_id=env_required("HF_REPO_ID"),
        camera_config_file=Path(
            os.getenv("CAMERA_CONFIG_FILE", str(SCRIPT_DIR / "cameras.json"))
        ),
        upload_retry_count=upload_retry_count,
        upload_retry_delay_seconds=upload_retry_delay,
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
    except requests.RequestException as exc:
        logger.error("Failed to send Telegram alert: %s", exc)


def send_telegram_alert_with_file(
    bot_token: str,
    chat_id: str,
    message: str,
    log_content: str,
    logger: logging.Logger,
) -> None:
    if not bot_token or not chat_id:
        return

    try:
        url = f"https://api.telegram.org/bot{bot_token}/sendDocument"
        files = {
            "document": ("logs.txt", log_content.encode("utf-8"), "text/plain"),
        }
        data = {
            "chat_id": chat_id,
            "caption": message,
        }
        resp = requests.post(url, files=files, data=data, timeout=30)
        if resp.ok:
            logger.info("Sent Telegram alert with log file to chat_id %s", chat_id)
        else:
            logger.error("Telegram API returned %s: %s", resp.status_code, resp.text)
    except requests.RequestException as exc:
        logger.error("Failed to send Telegram alert with file: %s", exc)


def send_telegram_images(
    bot_token: str,
    chat_id: str,
    images: list[tuple[str, bytes]],
    logger: logging.Logger,
) -> None:
    if not bot_token or not chat_id or not images:
        return

    try:
        url = f"https://api.telegram.org/bot{bot_token}/sendMediaGroup"

        media = []
        files = {}
        sent_count = 0

        for camera_id, image_data in images:
            if len(media) >= TELEGRAM_MAX_IMAGES_PER_GROUP:
                break

            file_key = f"photo_{len(media)}"
            media.append(
                {
                    "type": "photo",
                    "media": f"attach://{file_key}",
                    "caption": f"Camera: {camera_id}",
                }
            )
            files[file_key] = ("snapshot.jpg", image_data, "image/jpeg")
            sent_count += 1

        if not media:
            logger.warning("No valid images to send to Telegram")
            return

        data = {
            "chat_id": chat_id,
            "media": json.dumps(media),
        }

        resp = requests.post(url, data=data, files=files, timeout=30)
        if resp.ok:
            logger.info("Sent %d image previews to Telegram", sent_count)
        else:
            logger.error("Failed to send images: %s %s", resp.status_code, resp.text)
    except requests.RequestException as exc:
        logger.error("Failed to send Telegram image previews: %s", exc)


def create_preview_image(image_path: Path, logger: logging.Logger) -> bytes | None:
    try:
        cmd = [
            FFMPEG_BINARY,
            "-y",
            "-i",
            str(image_path),
            "-vf",
            f"scale={MAX_PREVIEW_IMAGE_EDGE}:{MAX_PREVIEW_IMAGE_EDGE}:force_original_aspect_ratio=decrease:flags=lanczos",
            "-frames:v",
            "1",
            "-q:v",
            str(PREVIEW_IMAGE_QV),
            "-f",
            "image2pipe",
            "-vcodec",
            "mjpeg",
            "pipe:1",
        ]

        result = subprocess.run(cmd, check=True, capture_output=True)
        return result.stdout
    except subprocess.CalledProcessError as exc:
        stderr_text = (exc.stderr or b"").decode("utf-8", errors="replace").strip()
        logger.warning("Failed to create preview for %s: %s", image_path, stderr_text or exc)
        return None
    except FileNotFoundError as exc:
        logger.warning("Failed to create preview for %s: %s", image_path, exc)
        return None


def create_previews_batch(
    records: list[SnapshotRecord], logger: logging.Logger, max_count: int = 5
) -> list[tuple[str, bytes]]:
    images: list[tuple[str, bytes]] = []
    selected = [r for r in records if r.local_path.exists()][:max_count]
    if not selected:
        return images

    try:
        with tempfile.TemporaryDirectory(prefix="hf-snapshot-preview-src-") as src_tmp, tempfile.TemporaryDirectory(prefix="hf-snapshot-preview-out-") as out_tmp:
            src = Path(src_tmp)
            out = Path(out_tmp)

            # Stage numbered inputs (img000001.jpg ...)
            for idx, rec in enumerate(selected, start=1):
                name = f"img{idx:06d}.jpg"
                target = src / name
                try:
                    os.symlink(rec.local_path, target)
                except Exception:
                    try:
                        shutil.copy2(rec.local_path, target)
                    except Exception as exc:
                        logger.warning("Failed to stage preview source for %s: %s", rec.local_path, exc)

            cmd = [
                FFMPEG_BINARY,
                "-y",
                "-i",
                str(src / "img%06d.jpg"),
                "-vf",
                f"scale={MAX_PREVIEW_IMAGE_EDGE}:{MAX_PREVIEW_IMAGE_EDGE}:force_original_aspect_ratio=decrease:flags=lanczos",
                "-q:v",
                str(PREVIEW_IMAGE_QV),
                str(out / "preview_%06d.jpg"),
            ]

            try:
                logger.debug("Running batched ffmpeg for %d previews", len(selected))
                subprocess.run(cmd, check=True, capture_output=True)

                # Read generated previews and map back to camera IDs
                for idx, rec in enumerate(selected, start=1):
                    preview_file = out / f"preview_{idx:06d}.jpg"
                    if preview_file.exists():
                        try:
                            data = preview_file.read_bytes()
                            images.append((rec.camera_id, data))
                        except Exception as exc:
                            logger.warning("Failed to read generated preview %s: %s", preview_file, exc)
                    else:
                        logger.warning("Expected preview not found: %s", preview_file)

                return images
            except subprocess.CalledProcessError as exc:
                stderr_text = (exc.stderr or b"").decode("utf-8", errors="replace").strip()
                logger.warning("Batched ffmpeg preview generation failed: %s", stderr_text or exc)
                # fall back to per-image preview creation
    except Exception as exc:
        logger.warning("Failed to run batched preview generation: %s", exc)

    # Fallback: create previews one-by-one
    for rec in selected:
        try:
            preview_data = create_preview_image(rec.local_path, logger)
            if preview_data is not None:
                images.append((rec.camera_id, preview_data))
        except Exception as exc:
            logger.warning("Per-image preview fallback failed for %s: %s", rec.local_path, exc)

    return images


def _ffmpeg_available(logger: logging.Logger) -> bool:
    try:
        subprocess.run([FFMPEG_BINARY, "-version"], check=True, capture_output=True)
        return True
    except FileNotFoundError:
        logger.error("ffmpeg not found: %s. Please install ffmpeg or set FFMPEG_BINARY.", FFMPEG_BINARY)
        return False
    except subprocess.CalledProcessError as exc:
        logger.warning("ffmpeg exists but returned non-zero on -version: %s", (exc.stderr or b"").decode("utf-8", errors="replace"))
        return True


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
            logger.error("Skipped camera config entry %s: device not found at startup: %s", index, device_path)
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

    cmd.extend(["-f", "image2", "-update", "1", "-frames:v", "1", str(output)])

    last_exc: subprocess.CalledProcessError | None = None
    for attempt in range(1, CAPTURE_RETRY_COUNT + 1):
        try:
            logger.debug("Running ffmpeg capture attempt %s/%s: %s", attempt, CAPTURE_RETRY_COUNT, " ".join(cmd))
            subprocess.run(cmd, check=True, capture_output=True, text=True)
            return
        except subprocess.CalledProcessError as exc:
            last_exc = exc
            stderr_text = (exc.stderr or "").strip()

            combined_lower = f"{stderr_text}\n{exc.stdout or ''}".lower()
            should_retry = any(token in combined_lower for token in TRANSIENT_ERROR_INDICATORS)

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

            raise

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
        logger.info("Remote metadata.csv not found yet. Starting with an empty metadata table.")
        return []

    rows: list[MetadataRow] = []
    try:
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
    except (KeyError, csv.Error, ValueError) as exc:
        logger.warning("Failed to parse remote metadata.csv; starting with empty table: %s", exc)
        return []
    
    return rows


def write_metadata_csv(path: Path, rows: list[MetadataRow]) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise RuntimeError(f"Failed to create directory for metadata file: {exc}")
    
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
            merged_rows[existing_index] = row
        else:
            file_name_to_index[row["file_name"]] = len(merged_rows)
            merged_rows.append(row)

    return merged_rows


def main(logger: Optional[logging.Logger] = None, log_buffer: Optional[io.StringIO] = None) -> tuple[int, list[tuple[str, bytes]]]:
    if logger is None or log_buffer is None:
        logger, log_buffer = setup_logging()

    config = load_config()

    logger.info("Starting snapshot capture and publish run.")

    if not _ffmpeg_available(logger):
        return 1, images

    camera_configs = load_camera_config(config.camera_config_file, logger)
    logger.info(
        "Loaded camera config from %s with cameras: %s",
        config.camera_config_file,
        ", ".join(
            f"{camera['camera_name']}={camera['device_path']}" for camera in camera_configs
        ),
    )

    records: list[SnapshotRecord] = []
    images_to_send: list[tuple[str, bytes]] = []

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
                logger.error("ffmpeg capture failed for %s after %d attempts", device_path, CAPTURE_RETRY_COUNT)
                if exc.stderr:
                    logger.error("ffmpeg stderr for %s:\n%s", camera_id, exc.stderr.strip())
                continue
            except FileNotFoundError as exc:
                logger.exception("ffmpeg executable not found: %s", exc)
                return 1, images_to_send

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
            return 1, images_to_send

        images_to_send = create_previews_batch(records, logger, max_count=TELEGRAM_MAX_IMAGES_PER_GROUP)

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
            except (OSError, RuntimeError) as exc:
                logger.error("Image upload failed for %s: %s", record.camera_id, exc)

        if records:
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
                    return 1, images_to_send

    logger.info("Run completed successfully.")
    return 0, images_to_send


if __name__ == "__main__":
    logger, log_buffer = setup_logging()
    telegram_bot = os.getenv("TELEGRAM_BOT_TOKEN") or None
    telegram_chat = os.getenv("TELEGRAM_CHAT_ID") or None

    exit_code = 0
    images: list[tuple[str, bytes]] = []
    exception_message = None

    try:
        exit_code, images = main(logger=logger, log_buffer=log_buffer)
    except Exception as exc:
        tb = traceback.format_exc()
        logger.exception("Uncaught exception in hf-snapshot: %s", exc)
        exit_code = 1
        exception_message = f"Uncaught exception: {exc}\n\nTraceback:\n{tb}"

    if telegram_bot and telegram_chat:
        log_text = log_buffer.getvalue()

        if exception_message:
            send_telegram_alert_with_file(
                telegram_bot,
                telegram_chat,
                "⛔ Run did not complete",
                log_text,
                logger,
            )
            raise SystemExit(exit_code)

        if exit_code == 0:
            send_telegram_alert(
                telegram_bot,
                telegram_chat,
                "✅ Run completed successfully",
                logger,
            )
        else:
            send_telegram_alert_with_file(
                telegram_bot,
                telegram_chat,
                "⚠️ Run completed with errors",
                log_text,
                logger,
            )

        if images:
            send_telegram_images(telegram_bot, telegram_chat, images, logger)

    raise SystemExit(exit_code)
