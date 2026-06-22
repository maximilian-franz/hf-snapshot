#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/hf-snapshot"
VENV_DIR="$APP_DIR/.venv"
ENV_FILE="$APP_DIR/.env"
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

SYSTEMD_DIR="/etc/systemd/system"
SERVICE_FILE="$APP_DIR/hf-snapshot.service"
TIMER_FILE="$APP_DIR/hf-snapshot.timer"
SERVICE_LINK="$SYSTEMD_DIR/hf-snapshot.service"
TIMER_LINK="$SYSTEMD_DIR/hf-snapshot.timer"
REPO_URL="https://github.com/maximilian-franz/hf-snapshot"
REPO_BRANCH="main"
CAMERA_CONFIG_FILE="$APP_DIR/cameras.json"
declare -a CAMERA_DEVICES=()
declare -a CAMERA_NAMES=()
declare -a CAMERA_ROTATIONS=()
declare -a CAMERA_TOWER_IDS=()
declare -a SNAPSHOT_TIMES=()
declare -a PREVIEW_UNITS=()
declare -a PREVIEW_DIRS=()
UNINSTALL_MODE=0
FORCE_UNINSTALL=0

EXISTING_HF_REPO_ID=""
EXISTING_HF_TOKEN=""
EXISTING_TELEGRAM_BOT_TOKEN=""
EXISTING_TELEGRAM_CHAT_ID=""
EXISTING_ENV_FOUND=0
KEEP_EXISTING_HF_CONFIG=0
KEEP_EXISTING_TELEGRAM_CONFIG=0

EXISTING_CAMERAS_FOUND=0
KEEP_EXISTING_CAMERA_CONFIG=0

declare -a EXISTING_SNAPSHOT_TIMES=()
EXISTING_SCHEDULE_FOUND=0
KEEP_EXISTING_SCHEDULE=0

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This installer must run as root."
    echo "Run with: curl -fsSL <INSTALLER_URL> | sudo bash"
    exit 1
  fi
}

require_tty() {
  if [[ ! -r /dev/tty ]]; then
    echo "Interactive mode requires a TTY (/dev/tty is not available)."
    exit 1
  fi
}

cleanup_previews() {
  local u d
  for u in "${PREVIEW_UNITS[@]}"; do
    systemctl stop "$u" >/dev/null 2>&1 || true
    systemctl reset-failed "$u" >/dev/null 2>&1 || true
  done
  for d in "${PREVIEW_DIRS[@]}"; do
    rm -rf "$d" >/dev/null 2>&1 || true
  done
}

trap cleanup_previews EXIT

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --uninstall)
        UNINSTALL_MODE=1
        shift
        ;;
      --yes)
        FORCE_UNINSTALL=1
        shift
        ;;
      -h|--help)
        cat <<'EOF'
Usage:
  install.sh                Install hf-snapshot
  install.sh --uninstall    Uninstall hf-snapshot
  install.sh --uninstall --yes
                            Uninstall without confirmation prompt
EOF
        exit 0
        ;;
      *)
        echo "Unknown argument: $1"
        echo "Run with --help for usage."
        exit 1
        ;;
    esac
  done
}

prompt_input() {
  local prompt="$1"
  local value
  read -r -p "$prompt" value </dev/tty
  printf '%s' "$value"
}

prompt_secret() {
  local prompt="$1"
  local value
  read -r -s -p "$prompt" value </dev/tty
  echo >/dev/tty
  printf '%s' "$value"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

read_env_value() {
  local key="$1"
  local file="$2"
  grep -E "^${key}=" "$file" | head -n 1 | cut -d'=' -f2-
}

prompt_default_yes() {
  local prompt="$1"
  local answer
  answer="$(prompt_input "$prompt [Y/n]: ")"
  [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]
}

detect_existing_config() {
  EXISTING_HF_REPO_ID=""
  EXISTING_HF_TOKEN=""
  EXISTING_TELEGRAM_BOT_TOKEN=""
  EXISTING_TELEGRAM_CHAT_ID=""
  EXISTING_ENV_FOUND=0
  KEEP_EXISTING_HF_CONFIG=0
  KEEP_EXISTING_TELEGRAM_CONFIG=0

  EXISTING_CAMERAS_FOUND=0
  KEEP_EXISTING_CAMERA_CONFIG=0

  EXISTING_SNAPSHOT_TIMES=()
  EXISTING_SCHEDULE_FOUND=0
  KEEP_EXISTING_SCHEDULE=0

  if [[ -f "$ENV_FILE" ]]; then
    EXISTING_ENV_FOUND=1
    EXISTING_HF_REPO_ID="$(read_env_value HF_REPO_ID "$ENV_FILE")"
    EXISTING_HF_TOKEN="$(read_env_value HF_TOKEN "$ENV_FILE")"
    EXISTING_TELEGRAM_BOT_TOKEN="$(read_env_value TELEGRAM_BOT_TOKEN "$ENV_FILE")"
    EXISTING_TELEGRAM_CHAT_ID="$(read_env_value TELEGRAM_CHAT_ID "$ENV_FILE")"
  fi

  if [[ -f "$CAMERA_CONFIG_FILE" ]]; then
    EXISTING_CAMERAS_FOUND=1
  fi

  local timer_candidates=("$TIMER_FILE" "$TIMER_LINK")
  local timer_path
  for timer_path in "${timer_candidates[@]}"; do
    [[ -f "$timer_path" ]] || continue
    while IFS= read -r line; do
      if [[ "$line" =~ ^OnCalendar=.*\ ([0-9]{2}:[0-9]{2}):[0-9]{2}$ ]]; then
        EXISTING_SNAPSHOT_TIMES+=("${BASH_REMATCH[1]}")
      fi
    done <"$timer_path"
    if [[ ${#EXISTING_SNAPSHOT_TIMES[@]} -gt 0 ]]; then
      EXISTING_SCHEDULE_FOUND=1
      break
    fi
  done
}

install_packages() {
  echo "[1/11] Installing required packages..."

  if command_exists apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y git ffmpeg python3 python3-venv ca-certificates openssl
    return
  fi

  echo "Unsupported package manager. Please install git, ffmpeg, python3, and python3-venv manually."
  exit 1
}

fetch_repository() {
  echo "[2/11] Fetching repository into $APP_DIR..."

  if [[ -d "$APP_DIR/.git" ]]; then
    git -C "$APP_DIR" fetch --depth 1 origin "$REPO_BRANCH"
    git -C "$APP_DIR" checkout -f "origin/$REPO_BRANCH"
  else
    rm -rf "$APP_DIR"
    git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$APP_DIR"
  fi

  local required=(
    "$APP_DIR/hf-snapshot.py"
    "$APP_DIR/requirements.txt"
    "$APP_DIR/hf-snapshot.service"
    "$APP_DIR/hf-snapshot.timer"
    "$APP_DIR/preview.sh"
  )

  local path
  for path in "${required[@]}"; do
    if [[ ! -f "$path" ]]; then
      echo "Missing required file in repository: $path"
      exit 1
    fi
  done

  # Ensure preview helper is executable
  if [[ -f "$APP_DIR/preview.sh" ]]; then
    chmod 755 "$APP_DIR/preview.sh" || true
    chown root:root "$APP_DIR/preview.sh" || true
  fi
}

prompt_hf_settings() {
  echo "[3/11] Hugging Face setup"
  echo "  - Repo ID format: username/dataset-name"
  echo "  - Create an access token at: https://huggingface.co/settings/tokens"
  echo "  - Token needs write access for the target dataset"

  if [[ "$EXISTING_ENV_FOUND" -eq 1 && -n "$EXISTING_HF_REPO_ID" && -n "$EXISTING_HF_TOKEN" ]]; then
    if prompt_default_yes "Existing Hugging Face configuration found for ${EXISTING_HF_REPO_ID}. Keep it"; then
      HF_REPO_ID="$EXISTING_HF_REPO_ID"
      HF_TOKEN="$EXISTING_HF_TOKEN"
      KEEP_EXISTING_HF_CONFIG=1
      return
    fi
  fi

  HF_REPO_ID="$(prompt_input "Enter HF repo ID (e.g. your-name/hf-snapshots): ")"
  while [[ -z "${HF_REPO_ID}" ]]; do
    HF_REPO_ID="$(prompt_input "HF repo ID cannot be empty. Enter HF repo ID: ")"
  done

  HF_TOKEN="$(prompt_secret "Enter HF access token: ")"
  while [[ -z "${HF_TOKEN}" ]]; do
    HF_TOKEN="$(prompt_secret "HF token cannot be empty. Enter HF access token: ")"
  done
  KEEP_EXISTING_HF_CONFIG=0
}

prompt_telegram_settings() {
  echo "[3b/11] Optional: Telegram alerts"
  echo "You can provide a Telegram bot token and chat ID to receive error alerts."
  echo "Leave blank to skip Telegram alerts."

  if [[ "$EXISTING_ENV_FOUND" -eq 1 && ( -n "$EXISTING_TELEGRAM_BOT_TOKEN" || -n "$EXISTING_TELEGRAM_CHAT_ID" ) ]]; then
    if prompt_default_yes "Existing Telegram configuration found. Keep it"; then
      TELEGRAM_BOT_TOKEN="$EXISTING_TELEGRAM_BOT_TOKEN"
      TELEGRAM_CHAT_ID="$EXISTING_TELEGRAM_CHAT_ID"
      KEEP_EXISTING_TELEGRAM_CONFIG=1
      return
    fi
  fi

  TELEGRAM_BOT_TOKEN="$(prompt_secret "Telegram bot token (leave empty to skip): ")"
  TELEGRAM_CHAT_ID="$(prompt_input "Telegram chat ID (leave empty to skip): ")"
  KEEP_EXISTING_TELEGRAM_CONFIG=0
}

list_persistent_camera_devices() {
  local devices=()
  local path
  declare -A seen_targets=()

  if [[ -d /dev/v4l/by-path ]]; then
    shopt -s nullglob
    for path in /dev/v4l/by-path/*-video-index0; do
      [[ -e "$path" ]] || continue

      local resolved
      resolved="$(readlink -f "$path" || true)"
      [[ -n "$resolved" ]] || continue
      [[ -c "$resolved" ]] || continue

      if [[ -z "${seen_targets[$resolved]:-}" ]]; then
        seen_targets["$resolved"]=1
        devices+=("$path")
      fi
    done
    shopt -u nullglob
  fi

  printf '%s\n' "${devices[@]:-}"
}

wait_for_new_persistent_camera_device() {
  local -a known_devices=("$@")
  local device
  local attempt

  for attempt in {1..60}; do
    while IFS= read -r device; do
      [[ -n "$device" ]] || continue

      local seen=0
      local known
      for known in "${known_devices[@]}"; do
        if [[ "$known" == "$device" ]]; then
          seen=1
          break
        fi
      done

      if [[ "$seen" -eq 0 ]]; then
        printf '%s' "$device"
        return 0
      fi
    done < <(list_persistent_camera_devices)

    sleep 1
  done

  return 1
}

is_valid_camera_name() {
  local value="$1"
  [[ -n "$value" && "$value" != *"/"* && "$value" != *$'\t'* && "$value" != *$'\n'* ]]
}

is_valid_rotation() {
  local v="$1"
  if [[ -z "$v" ]]; then
    return 0
  fi
  case "$v" in
    0|90|180|270) return 0 ;;
    *) return 1 ;;
  esac
}

prompt_camera_enrollment() {
  echo "[4/11] Camera enrollment"
  echo "Unplug every camera you want to configure, then connect them one at a time."

  if [[ "$EXISTING_CAMERAS_FOUND" -eq 1 ]]; then
    echo "Existing camera configuration file found at: $CAMERA_CONFIG_FILE"
    echo "Current camera configuration contents:"
    cat "$CAMERA_CONFIG_FILE"
    if prompt_default_yes "Keep existing camera configuration"; then
      KEEP_EXISTING_CAMERA_CONFIG=1
      return
    fi
  fi

  KEEP_EXISTING_CAMERA_CONFIG=0

  local camera_count
  camera_count="$(prompt_input "How many cameras do you want to enroll? ")"
  while [[ ! "$camera_count" =~ ^[1-9][0-9]*$ ]]; do
    camera_count="$(prompt_input "Please enter a positive integer camera count: ")"
  done

  echo "When ready, unplug all cameras you want to configure, then press Enter."
  prompt_input "Continue: " >/dev/null

  # Record currently-present persistent devices as known baseline and only
  # watch for new devices that appear after this point.
  echo "Recording currently-present persistent devices and waiting for new devices to appear..."
  readarray -t KNOWN_DEVICES < <(list_persistent_camera_devices)
  echo "Recorded ${#KNOWN_DEVICES[@]} existing persistent device(s). Plug in the first camera when prompted."

  CAMERA_DEVICES=()
  CAMERA_NAMES=()
  CAMERA_ROTATIONS=()
  CAMERA_TOWER_IDS=()

  # Start one preview service for the whole enrollment lifecycle.
  local preview_dir
  preview_dir="$(mktemp -d)"
  PREVIEW_DIRS+=("$preview_dir")
  local preview_port=8080
  local preview_device_file="$preview_dir/current_device"
  local preview_unit_name="hf-snapshot-preview-${RANDOM}.service"

  if [[ ! -x "$APP_DIR/preview.sh" ]]; then
    echo "Preview helper $APP_DIR/preview.sh not found or not executable. Ensure the repository contains preview.sh" >&2
    exit 1
  fi

  systemd-run --unit="$preview_unit_name" --description="hf-snapshot preview server" /bin/bash "$APP_DIR/preview.sh" "$preview_port" "$preview_dir" >/dev/null 2>&1 || true
  PREVIEW_UNITS+=("$preview_unit_name")

  local host_ip
  host_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  echo "Camera preview available at: http://127.0.0.1:${preview_port}/latest.jpg"
  if [[ -n "$host_ip" ]]; then
    echo "Also accessible on the local network at: http://${host_ip}:${preview_port}/latest.jpg"
  fi
  echo "Warning: the preview server is bound to 0.0.0.0 and may be reachable from the network. Use firewall rules or SSH port forwarding if you want to restrict access."

  local idx
  for ((idx = 1; idx <= camera_count; idx++)); do
    echo "Waiting for camera ${idx}/${camera_count} to appear..."

    local known_device_args=()
    local known_device
    # start with baseline devices present at the time the user pressed Enter
    for known_device in "${KNOWN_DEVICES[@]}"; do
      known_device_args+=("$known_device")
    done
    # also include any devices we've already enrolled so they are not treated as new
    for known_device in "${CAMERA_DEVICES[@]}"; do
      known_device_args+=("$known_device")
    done

    local detected_device
    if ! detected_device="$(wait_for_new_persistent_camera_device "${known_device_args[@]}")"; then
      echo "Timed out waiting for a new persistent camera device."
      exit 1
    fi

    echo "Detected camera ${idx}: ${detected_device}"

    # Switch preview input device without restarting the preview service.
    printf '%s\n' "$detected_device" >"$preview_device_file"
    echo "Preview switched to ${detected_device}: http://127.0.0.1:${preview_port}/latest.jpg"

    local camera_name
    while true; do
      camera_name="$(prompt_input "Label for ${detected_device}: ")"
      if is_valid_camera_name "$camera_name"; then
        break
      fi

      echo "Camera names must be non-empty and cannot contain '/', tabs, or newlines."
    done

    local rotation
    while true; do
      rotation="$(prompt_input "Rotation for ${detected_device} in degrees (0,90,180,270) [default 0]: ")"
      if [[ -z "$rotation" ]]; then
        rotation=0
      fi
      if is_valid_rotation "$rotation"; then
        break
      fi
      echo "Invalid rotation; please enter one of: 0,90,180,270"
    done

    local tower_id
    tower_id="$(prompt_input "Tower ID for ${detected_device}: ")"
    while [[ -z "$tower_id" ]]; do
      tower_id="$(prompt_input "Tower ID cannot be empty. Enter Tower ID: ")"
    done

    CAMERA_DEVICES+=("$detected_device")
    CAMERA_NAMES+=("$camera_name")
    CAMERA_ROTATIONS+=("$rotation")
    CAMERA_TOWER_IDS+=("$tower_id")

    if [[ $idx -lt $camera_count ]]; then
      echo "Unplug ${detected_device}, then plug in the next camera and press Enter."
      prompt_input "Continue: " >/dev/null
    fi
  done

  # Enrollment complete; stop preview service now.
  systemctl stop "$preview_unit_name" >/dev/null 2>&1 || true
  systemctl reset-failed "$preview_unit_name" >/dev/null 2>&1 || true
}

install_camera_config() {
  echo "[5/11] Writing camera config file..."

  if [[ "$KEEP_EXISTING_CAMERA_CONFIG" -eq 1 && -f "$CAMERA_CONFIG_FILE" ]]; then
    echo "Keeping existing camera config file: $CAMERA_CONFIG_FILE"
    return
  fi

  local mapping_file
  mapping_file="$(mktemp)"

  {
    local idx
    for idx in "${!CAMERA_DEVICES[@]}"; do
      printf '%s\t%s\t%s\t%s\n' "${CAMERA_DEVICES[$idx]}" "${CAMERA_NAMES[$idx]}" "${CAMERA_ROTATIONS[$idx]}" "${CAMERA_TOWER_IDS[$idx]}"
    done
  } >"$mapping_file"

  python3 - "$CAMERA_CONFIG_FILE" "$mapping_file" <<'PY'
import json
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
mapping_path = Path(sys.argv[2])

cameras = []
with mapping_path.open("r", encoding="utf-8") as f:
    for line in f:
      parts = line.rstrip("\n").split("\t")
      if len(parts) < 2:
        continue
      device_path = parts[0]
      camera_name = parts[1]
      rotation = 0
      if len(parts) >= 3 and parts[2].strip() != "":
        try:
          rotation = int(parts[2])
        except Exception:
          rotation = 0
      tower_id = parts[3].strip() if len(parts) >= 4 else ""
      cameras.append({"device_path": device_path, "camera_name": camera_name, "rotation": rotation, "tower_id": tower_id})

config_path.write_text(
    json.dumps({"cameras": cameras}, indent=2) + "\n",
    encoding="utf-8",
)
PY

  rm -f "$mapping_file"

  chmod 640 "$CAMERA_CONFIG_FILE"
  chown root:root "$CAMERA_CONFIG_FILE"
}

is_valid_hhmm_time() {
  local value="$1"
  [[ "$value" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]
}

time_already_selected() {
  local candidate="$1"
  local existing
  for existing in "${SNAPSHOT_TIMES[@]}"; do
    if [[ "$existing" == "$candidate" ]]; then
      return 0
    fi
  done
  return 1
}

prompt_snapshot_schedule() {
  echo "[6/11] Snapshot schedule setup"
  echo "Default times: 06:00, 08:00, 10:00, 12:00, 14:00, 16:00, 18:00, 20:00, 22:00"
  echo "Times are local server time in 24-hour HH:MM format."

  if [[ "$EXISTING_SCHEDULE_FOUND" -eq 1 && ${#EXISTING_SNAPSHOT_TIMES[@]} -gt 0 ]]; then
    local existing_display
    existing_display="$(printf '%s, ' "${EXISTING_SNAPSHOT_TIMES[@]}")"
    existing_display="${existing_display%, }"
    if prompt_default_yes "Existing schedule found (${existing_display}). Keep it"; then
      SNAPSHOT_TIMES=("${EXISTING_SNAPSHOT_TIMES[@]}")
      KEEP_EXISTING_SCHEDULE=1
      return
    fi
  fi

  local use_defaults
  use_defaults="$(prompt_input "Use default times? [Y/n]: ")"

  if [[ -z "$use_defaults" || "$use_defaults" =~ ^[Yy]$ ]]; then
    SNAPSHOT_TIMES=("06:00" "08:00" "10:00" "12:00" "14:00" "16:00" "18:00" "20:00" "22:00")
    KEEP_EXISTING_SCHEDULE=0
    return
  fi

  SNAPSHOT_TIMES=()

  while true; do
    local schedule_time
    schedule_time="$(prompt_input "Enter snapshot time (HH:MM): ")"

    while ! is_valid_hhmm_time "$schedule_time"; do
      schedule_time="$(prompt_input "Invalid format. Enter time as HH:MM (24-hour): ")"
    done

    if time_already_selected "$schedule_time"; then
      echo "Time $schedule_time is already selected."
    else
      SNAPSHOT_TIMES+=("$schedule_time")
    fi

    local add_more
    add_more="$(prompt_input "Add another time? [y/N]: ")"
    if [[ ! "$add_more" =~ ^[Yy]$ ]]; then
      if [[ ${#SNAPSHOT_TIMES[@]} -eq 0 ]]; then
        echo "At least one schedule time is required."
        continue
      fi
      break
    fi
  done
  KEEP_EXISTING_SCHEDULE=0
}

install_env_file() {
  echo "[7/11] Writing environment file..."

  cat >"$ENV_FILE" <<EOF
HF_REPO_ID=${HF_REPO_ID}
HF_TOKEN=${HF_TOKEN}
CAMERA_CONFIG_FILE=${CAMERA_CONFIG_FILE}
FFMPEG_BINARY=ffmpeg
FFMPEG_INPUT_FORMAT=mjpeg
FFMPEG_VIDEO_SIZE=3840x2160
CAPTURE_WARMUP_SECONDS=8.0
CAPTURE_RETRY_COUNT=3
CAPTURE_RETRY_DELAY_SECONDS=2.0
UPLOAD_RETRY_COUNT=3
UPLOAD_RETRY_DELAY_SECONDS=2.0
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
EOF

  chmod 640 "$ENV_FILE"
  chown root:root "$ENV_FILE"

  mkdir -p "$APP_DIR/.cache"
  chown root:root "$APP_DIR/.cache"
  chmod 770 "$APP_DIR/.cache"

  find "$APP_DIR" -maxdepth 1 -type f -name '*.py' -exec chmod 755 {} +
  find "$APP_DIR" -maxdepth 1 -type f -name '*.py' -exec chown root:root {} +
  chmod 644 "$APP_DIR/requirements.txt"
  chown root:root "$APP_DIR/requirements.txt"
}

install_python_env() {
  echo "[8/11] Creating Python virtual environment and installing dependencies..."

  python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install --upgrade pip
  "$VENV_DIR/bin/pip" install -r "$APP_DIR/requirements.txt"

  chown -R root:root "$VENV_DIR"
}

patch_service_unit() {
  local file="$1"

  sed -i "s|^WorkingDirectory=.*|WorkingDirectory=${APP_DIR}|" "$file"
  sed -i "s|^Environment=XDG_CACHE_HOME=.*|Environment=XDG_CACHE_HOME=${APP_DIR}/.cache|" "$file"
  sed -i "s|^Environment=HF_HOME=.*|Environment=HF_HOME=${APP_DIR}/.cache/huggingface|" "$file"
  sed -i "s|^ExecStart=.*|ExecStart=${VENV_DIR}/bin/python3 ${APP_DIR}/hf-snapshot.py|" "$file"
  sed -i "s|^ReadWritePaths=.*|ReadWritePaths=${APP_DIR}/.cache|" "$file"
}

patch_timer_unit() {
  local file="$1"

  if [[ ${#SNAPSHOT_TIMES[@]} -eq 0 ]]; then
    echo "No snapshot schedule times configured."
    exit 1
  fi

  {
    echo "[Unit]"
    echo "Description=Run ffmpeg snapshot capture/upload at specific times"
    echo
    echo "[Timer]"

    local snapshot_time
    for snapshot_time in "${SNAPSHOT_TIMES[@]}"; do
      echo "OnCalendar=*-*-* ${snapshot_time}:00"
    done

    echo "Persistent=true"
    echo "Unit=hf-snapshot.service"
    echo
    echo "[Install]"
    echo "WantedBy=timers.target"
  } >"$file"
}

install_systemd_units() {
  echo "[9/11] Installing systemd service and timer..."

  if [[ ! -f "$SERVICE_FILE" || ! -f "$TIMER_FILE" ]]; then
    echo "Service or timer file missing in repository."
    exit 1
  fi

  patch_service_unit "$SERVICE_FILE"
  patch_timer_unit "$TIMER_FILE"

  chmod 644 "$SERVICE_FILE" "$TIMER_FILE"
  chown root:root "$SERVICE_FILE" "$TIMER_FILE"

  ln -sfn "$SERVICE_FILE" "$SERVICE_LINK"
  ln -sfn "$TIMER_FILE" "$TIMER_LINK"

  systemctl daemon-reload
}

enable_and_start_services() {
  echo "Enabling and starting services..."

  systemctl enable hf-snapshot.service
  systemctl enable --now hf-snapshot.timer
}

show_summary() {
  echo "Installation complete"
  echo
  echo
  echo "Repository: $REPO_URL (branch: $REPO_BRANCH)"
  echo "Installed path: $APP_DIR"
  echo "Environment file: $ENV_FILE"

  if [[ "$KEEP_EXISTING_HF_CONFIG" -eq 1 ]]; then
    echo "Hugging Face config: kept existing (${HF_REPO_ID})"
  else
    echo "Hugging Face config: newly configured (${HF_REPO_ID})"
  fi

  if [[ "$KEEP_EXISTING_TELEGRAM_CONFIG" -eq 1 ]]; then
    echo "Telegram config: kept existing"
  elif [[ -n "$TELEGRAM_BOT_TOKEN" || -n "$TELEGRAM_CHAT_ID" ]]; then
    echo "Telegram config: newly configured"
  else
    echo "Telegram config: disabled"
  fi

  echo "Camera config file: $CAMERA_CONFIG_FILE"

  if [[ "$KEEP_EXISTING_CAMERA_CONFIG" -eq 1 && -f "$CAMERA_CONFIG_FILE" ]]; then
    echo "Camera config: kept existing"
    cat "$CAMERA_CONFIG_FILE"
  else
    echo "Configured cameras:"
    local idx
    for idx in "${!CAMERA_DEVICES[@]}"; do
      local tower_display=""
      if [[ -n "${CAMERA_TOWER_IDS[$idx]:-}" ]]; then
        tower_display=" (tower: ${CAMERA_TOWER_IDS[$idx]})"
      fi
      echo "  - ${CAMERA_NAMES[$idx]}${tower_display} -> ${CAMERA_DEVICES[$idx]}"
    done
  fi

  if [[ "$KEEP_EXISTING_SCHEDULE" -eq 1 ]]; then
    echo "Snapshot schedule: kept existing"
  else
    echo "Snapshot schedule:"
  fi
  local idx
  for idx in "${!SNAPSHOT_TIMES[@]}"; do
    echo "  - ${SNAPSHOT_TIMES[$idx]}"
  done

  echo
  echo "Credentials were written to:"
  echo "  - $ENV_FILE"
  echo
  echo "Useful commands:"
  echo "  systemctl status hf-snapshot.timer"
  echo "  systemctl start hf-snapshot.service"
  echo "  journalctl -u hf-snapshot.service -n 200 --no-pager"
}

confirm_uninstall() {
  if [[ "$FORCE_UNINSTALL" -eq 1 ]]; then
    return
  fi

  require_tty

  echo
  echo "This will remove:"
  echo "  - $APP_DIR"
  echo "  - $SERVICE_LINK and $TIMER_LINK"
  echo "  - It will also stop/disable hf-snapshot timer/service"
  echo

  local answer
  answer="$(prompt_input "Continue uninstall? [y/N]: ")"
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    echo "Uninstall cancelled."
    exit 0
  fi
}

uninstall_everything() {
  echo "[UNINSTALL] Stopping and disabling services..."

  systemctl disable --now hf-snapshot.timer >/dev/null 2>&1 || true
  systemctl disable --now hf-snapshot.service >/dev/null 2>&1 || true

  echo "[UNINSTALL] Removing systemd links and reloading daemon..."

  rm -f "$SERVICE_LINK" "$TIMER_LINK"
  systemctl daemon-reload

  echo "[UNINSTALL] Removing installed application files..."
  rm -rf "$APP_DIR"

  echo
  echo "Uninstall complete."
}

main() {
  parse_args "$@"

  require_root

  if [[ "$UNINSTALL_MODE" -eq 1 ]]; then
    confirm_uninstall
    uninstall_everything
    return
  fi

  require_tty
  install_packages
  detect_existing_config
  fetch_repository
  prompt_hf_settings
  prompt_telegram_settings
  prompt_camera_enrollment
  install_camera_config
  prompt_snapshot_schedule
  install_env_file
  install_python_env
  install_systemd_units
  enable_and_start_services
  show_summary
}

main "$@"
