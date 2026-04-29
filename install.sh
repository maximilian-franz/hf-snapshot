#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/motion-snapshot"
VENV_DIR="$APP_DIR/.venv"
ENV_FILE="$APP_DIR/.env"

MOTION_ETC_DIR="/etc/motion"
MOTION_CAMERA_DIR="$MOTION_ETC_DIR/conf.d"
MOTION_CONF_FILE="$MOTION_ETC_DIR/motion.conf"

SYSTEMD_DIR="/etc/systemd/system"
SERVICE_FILE="$APP_DIR/motion-snapshot.service"
TIMER_FILE="$APP_DIR/motion-snapshot.timer"
SERVICE_LINK="$SYSTEMD_DIR/motion-snapshot.service"
TIMER_LINK="$SYSTEMD_DIR/motion-snapshot.timer"

APP_USER="motion-snapshot"
APP_GROUP="motion-snapshot"
MOTION_API_USER="snapshotctl"
REPO_URL="https://github.com/maximilian-franz/motion-snapshot"
REPO_BRANCH="main"
declare -a CAMERA_DEVICES=()
declare -a SNAPSHOT_TIMES=()
UNINSTALL_MODE=0
FORCE_UNINSTALL=0
MOTION_RUN_USER="motion"
MOTION_RUN_GROUP="motion"
CAMERA_ID_OFFSET=0

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
  install.sh                Install motion-snapshot
  install.sh --uninstall    Uninstall motion-snapshot
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

resolve_motion_runtime_identity() {
  local svc_user=""
  local svc_group=""

  svc_user="$(systemctl show -p User --value motion.service 2>/dev/null || true)"
  svc_group="$(systemctl show -p Group --value motion.service 2>/dev/null || true)"

  if [[ -n "$svc_user" && "$svc_user" != "root" ]] && id -u "$svc_user" >/dev/null 2>&1; then
    MOTION_RUN_USER="$svc_user"
  elif id -u motion >/dev/null 2>&1; then
    MOTION_RUN_USER="motion"
  else
    MOTION_RUN_USER="root"
  fi

  if [[ -n "$svc_group" ]] && getent group "$svc_group" >/dev/null; then
    MOTION_RUN_GROUP="$svc_group"
  elif getent group motion >/dev/null; then
    MOTION_RUN_GROUP="motion"
  elif id -u "$MOTION_RUN_USER" >/dev/null 2>&1; then
    MOTION_RUN_GROUP="$(id -gn "$MOTION_RUN_USER")"
  else
    MOTION_RUN_GROUP="root"
  fi
}

install_packages() {
  echo "[1/11] Installing required packages..."

  if command_exists apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y git motion python3 python3-venv ca-certificates openssl
    return
  fi

  echo "Unsupported package manager. Please install git, motion, python3, and python3-venv manually."
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
    "$APP_DIR/motion-snapshot.py"
    "$APP_DIR/requirements.txt"
    "$APP_DIR/motion-snapshot.service"
    "$APP_DIR/motion-snapshot.timer"
    "$APP_DIR/motion.conf"
    "$APP_DIR/camera-1.conf"
  )

  local path
  for path in "${required[@]}"; do
    if [[ ! -f "$path" ]]; then
      echo "Missing required file in repository: $path"
      exit 1
    fi
  done
}

prompt_hf_settings() {
  echo "[3/11] Hugging Face setup"
  echo "  - Repo ID format: username/dataset-name"
  echo "  - Create an access token at: https://huggingface.co/settings/tokens"
  echo "  - Token needs write access for the target dataset"

  HF_REPO_ID="$(prompt_input "Enter HF repo ID (e.g. your-name/motion-snapshots): ")"
  while [[ -z "${HF_REPO_ID}" ]]; do
    HF_REPO_ID="$(prompt_input "HF repo ID cannot be empty. Enter HF repo ID: ")"
  done

  HF_TOKEN="$(prompt_secret "Enter HF access token: ")"
  while [[ -z "${HF_TOKEN}" ]]; do
    HF_TOKEN="$(prompt_secret "HF token cannot be empty. Enter HF access token: ")"
  done
}

prompt_camera_settings() {
  echo "[4/11] Camera setup"

  discover_camera_devices
  prompt_camera_offset

  if [[ ${#CAMERA_DEVICES[@]} -gt 0 ]]; then
    echo "Discovered webcam device paths:"
    local idx
    for idx in "${!CAMERA_DEVICES[@]}"; do
      echo "  $((idx + 1)). ${CAMERA_DEVICES[$idx]}"
    done

    local use_detected
    use_detected="$(prompt_input "Use discovered devices? [Y/n]: ")"
    if [[ -z "$use_detected" || "$use_detected" =~ ^[Yy]$ ]]; then
      select_discovered_camera_subset
      return
    fi
  else
    echo "No webcams auto-discovered via /dev/v4l/by-path/*-video-index0 or /dev/video*."
    echo "Proceeding with manual camera setup."
  fi

  prompt_camera_settings_manual
}

prompt_camera_offset() {
  local camera_offset
  camera_offset="$(prompt_input "Camera number offset [0]: ")"

  while [[ -n "$camera_offset" && ! "$camera_offset" =~ ^[0-9]+$ ]]; do
    camera_offset="$(prompt_input "Please enter a non-negative integer camera offset [0]: ")"
  done

  if [[ -z "$camera_offset" ]]; then
    CAMERA_ID_OFFSET=0
  else
    CAMERA_ID_OFFSET="$camera_offset"
  fi
}

select_discovered_camera_subset() {
  local discovered=("${CAMERA_DEVICES[@]}")
  local selected=()

  echo
  echo "Select which discovered cameras to configure:"

  local idx
  for idx in "${!discovered[@]}"; do
    local include
    include="$(prompt_input "Include $((idx + 1)) (${discovered[$idx]})? [Y/n]: ")"
    if [[ -z "$include" || "$include" =~ ^[Yy]$ ]]; then
      selected+=("${discovered[$idx]}")
    fi
  done

  if [[ ${#selected[@]} -eq 0 ]]; then
    echo "No discovered cameras selected. Proceeding with manual camera setup."
    prompt_camera_settings_manual
    return
  fi

  CAMERA_DEVICES=("${selected[@]}")
}

discover_camera_devices() {
  CAMERA_DEVICES=()

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
        CAMERA_DEVICES+=("$path")
      fi
    done
    shopt -u nullglob
  fi

  if [[ ${#CAMERA_DEVICES[@]} -eq 0 ]]; then
    shopt -s nullglob
    for path in /dev/video*; do
      [[ -c "$path" ]] || continue
      CAMERA_DEVICES+=("$path")
    done
    shopt -u nullglob
  fi
}

prompt_camera_settings_manual() {
  local camera_count
  camera_count="$(prompt_input "How many cameras are installed? ")"
  while [[ ! "$camera_count" =~ ^[1-9][0-9]*$ ]]; do
    camera_count="$(prompt_input "Please enter a positive integer camera count: ")"
  done

  CAMERA_DEVICES=()

  local idx
  for ((idx = 1; idx <= camera_count; idx++)); do
    local default_device="/dev/video$((idx - 1))"
    local camera_device
    while true; do
      camera_device="$(prompt_input "Device path for camera ${idx} [${default_device}]: ")"
      if [[ -z "$camera_device" ]]; then
        camera_device="$default_device"
      fi

      if [[ -c "$camera_device" ]]; then
        break
      fi

      if [[ ! -e "$camera_device" ]]; then
        echo "Warning: $camera_device does not exist."
      else
        echo "Warning: $camera_device exists but is not a character device."
      fi

      local continue_anyway
      continue_anyway="$(prompt_input "Use this path anyway? [y/N]: ")"
      if [[ "$continue_anyway" =~ ^[Yy]$ ]]; then
        break
      fi
    done

    CAMERA_DEVICES+=("$camera_device")
  done
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
  echo "[5/11] Snapshot schedule setup"
  echo "Default times: 06:00, 14:00, 22:00"
  echo "Times are local server time in 24-hour HH:MM format."

  local use_defaults
  use_defaults="$(prompt_input "Use default times? [Y/n]: ")"

  if [[ -z "$use_defaults" || "$use_defaults" =~ ^[Yy]$ ]]; then
    SNAPSHOT_TIMES=("06:00" "14:00" "22:00")
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
}

create_app_user() {
  echo "[6/11] Creating dedicated service user..."

  if ! getent group "$APP_GROUP" >/dev/null; then
    groupadd --system "$APP_GROUP"
  fi

  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    useradd \
      --system \
      --gid "$APP_GROUP" \
      --home-dir "$APP_DIR" \
      --create-home \
      --shell /usr/sbin/nologin \
      "$APP_USER"
  fi

  if getent group motion >/dev/null; then
    usermod -a -G motion "$APP_USER"
  fi
}

generate_password() {
  openssl rand -base64 36 | tr -d '\n' | cut -c1-28
}

install_motion_configs() {
  local motion_password="$1"

  echo "[7/11] Installing Motion configuration..."

  mkdir -p /var/lib/motion
  chown "$MOTION_RUN_USER":"$MOTION_RUN_GROUP" /var/lib/motion
  chmod 775 /var/lib/motion

  mkdir -p "$MOTION_ETC_DIR" "$MOTION_CAMERA_DIR"

  cp "$APP_DIR/motion.conf" "$MOTION_CONF_FILE"

  if grep -q '^webcontrol_authentication ' "$MOTION_CONF_FILE"; then
    sed -i "s|^webcontrol_authentication .*|webcontrol_authentication ${MOTION_API_USER}:${motion_password}|" "$MOTION_CONF_FILE"
  else
    printf '\nwebcontrol_authentication %s:%s\n' "$MOTION_API_USER" "$motion_password" >>"$MOTION_CONF_FILE"
  fi

  local camera_template="$APP_DIR/camera-1.conf"
  if [[ ! -f "$camera_template" ]]; then
    echo "Template camera config not found: $camera_template"
    exit 1
  fi

  if [[ ${#CAMERA_DEVICES[@]} -eq 0 ]]; then
    echo "No camera devices configured."
    exit 1
  fi

  rm -f "$MOTION_CAMERA_DIR"/*.conf

  local idx
  for idx in "${!CAMERA_DEVICES[@]}"; do
    local camera_id=$((CAMERA_ID_OFFSET + idx + 1))
    local camera_device="${CAMERA_DEVICES[$idx]}"
    local camera_target="/var/lib/motion/camera-${camera_id}"
    local camera_file="$MOTION_CAMERA_DIR/camera-${camera_id}.conf"

    mkdir -p "$camera_target"
    chown "$MOTION_RUN_USER":"$MOTION_RUN_GROUP" "$camera_target"
    chmod 775 "$camera_target"

    cp "$camera_template" "$camera_file"

    if grep -q '^camera_id ' "$camera_file"; then
      sed -i "s|^camera_id .*|camera_id ${camera_id}|" "$camera_file"
    else
      printf '\ncamera_id %s\n' "$camera_id" >>"$camera_file"
    fi

    if grep -q '^video_device ' "$camera_file"; then
      sed -i "s|^video_device .*|video_device ${camera_device}|" "$camera_file"
    else
      printf '\nvideo_device %s\n' "$camera_device" >>"$camera_file"
    fi

    if grep -q '^target_dir ' "$camera_file"; then
      sed -i "s|^target_dir .*|target_dir ${camera_target}|" "$camera_file"
    else
      printf '\ntarget_dir %s\n' "$camera_target" >>"$camera_file"
    fi
  done

  local motion_group="root"
  if getent group motion >/dev/null; then
    motion_group="motion"
  fi

  chmod 640 "$MOTION_CONF_FILE"
  chmod 640 "$MOTION_CAMERA_DIR"/*.conf
  chown root:"$motion_group" "$MOTION_CONF_FILE" "$MOTION_CAMERA_DIR"/*.conf
}

install_env_file() {
  local motion_password="$1"

  echo "[8/11] Writing environment file..."

  cat >"$ENV_FILE" <<EOF
HF_REPO_ID=${HF_REPO_ID}
HF_TOKEN=${HF_TOKEN}
HTTP_TIMEOUT_SECONDS=30
MOTION_SNAPSHOT_ENDPOINT=http://localhost:8080/0/action/snapshot
MOTION_SNAPSHOT_PASSWORD=${motion_password}
MOTION_SNAPSHOT_USER=${MOTION_API_USER}
MOTION_SNAPSHOTS_ROOT=/var/lib/motion
SNAPSHOT_POLL_INTERVAL_SECONDS=0.5
SNAPSHOT_WAIT_TIMEOUT_SECONDS=20
UPLOAD_RETRY_COUNT=3
UPLOAD_RETRY_DELAY_SECONDS=2.0
EOF

  chmod 640 "$ENV_FILE"
  chown root:"$APP_GROUP" "$ENV_FILE"

  mkdir -p "$APP_DIR/.cache"
  chown "$APP_USER":"$APP_GROUP" "$APP_DIR/.cache"
  chmod 770 "$APP_DIR/.cache"

  find "$APP_DIR" -maxdepth 1 -type f -name '*.py' -exec chmod 755 {} +
  find "$APP_DIR" -maxdepth 1 -type f -name '*.py' -exec chown root:root {} +
  chmod 644 "$APP_DIR/requirements.txt"
  chown root:root "$APP_DIR/requirements.txt"
}

install_python_env() {
  echo "[9/11] Creating Python virtual environment and installing dependencies..."

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
  sed -i "s|^ExecStart=.*|ExecStart=${VENV_DIR}/bin/python3 ${APP_DIR}/motion-snapshot.py|" "$file"
  sed -i "s|^User=.*|User=${APP_USER}|" "$file"
  sed -i "s|^Group=.*|Group=${APP_GROUP}|" "$file"
  sed -i "s|^ReadWritePaths=.*|ReadWritePaths=/var/lib/motion ${APP_DIR}/.cache|" "$file"
}

patch_timer_unit() {
  local file="$1"

  if [[ ${#SNAPSHOT_TIMES[@]} -eq 0 ]]; then
    echo "No snapshot schedule times configured."
    exit 1
  fi

  {
    echo "[Unit]"
    echo "Description=Run motion snapshot capture/upload at specific times"
    echo
    echo "[Timer]"

    local snapshot_time
    for snapshot_time in "${SNAPSHOT_TIMES[@]}"; do
      echo "OnCalendar=*-*-* ${snapshot_time}:00"
    done

    echo "Persistent=true"
    echo "Unit=motion-snapshot.service"
    echo
    echo "[Install]"
    echo "WantedBy=timers.target"
  } >"$file"
}

install_systemd_units() {
  echo "[10/11] Installing systemd service and timer..."

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
  echo "[11/11] Enabling and starting services..."

  systemctl enable --now motion.service
  systemctl enable motion-snapshot.service
  systemctl enable --now motion-snapshot.timer
}

show_summary() {
  local motion_password="$1"

  echo "Installation complete"
  echo
  echo
  echo "Repository: $REPO_URL (branch: $REPO_BRANCH)"
  echo "Installed path: $APP_DIR"
  echo "Environment file: $ENV_FILE"
  echo "Camera number offset: $CAMERA_ID_OFFSET"
  echo "Configured cameras: ${#CAMERA_DEVICES[@]}"
  local idx
  for idx in "${!CAMERA_DEVICES[@]}"; do
    echo "  - camera-$((CAMERA_ID_OFFSET + idx + 1)): ${CAMERA_DEVICES[$idx]}"
  done
  echo "Snapshot schedule:"
  for idx in "${!SNAPSHOT_TIMES[@]}"; do
    echo "  - ${SNAPSHOT_TIMES[$idx]}"
  done
  echo
  echo "Generated Motion API credentials:"
  echo "  user: $MOTION_API_USER"
  echo "  password: $motion_password"
  echo
  echo "Credentials were written to:"
  echo "  - $MOTION_CONF_FILE"
  echo "  - $ENV_FILE"
  echo
  echo "Useful commands:"
  echo "  systemctl status motion.service"
  echo "  systemctl status motion-snapshot.timer"
  echo "  systemctl start motion-snapshot.service"
  echo "  journalctl -u motion-snapshot.service -n 200 --no-pager"
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
  echo "  - /etc/motion/motion.conf"
  echo "  - /etc/motion/conf.d/camera-*.conf"
  echo "  - user/group $APP_USER/$APP_GROUP (if present)"
  echo "  - It will also stop/disable motion.service and motion-snapshot timer/service"
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

  systemctl disable --now motion-snapshot.timer >/dev/null 2>&1 || true
  systemctl disable --now motion-snapshot.service >/dev/null 2>&1 || true
  systemctl disable --now motion.service >/dev/null 2>&1 || true

  echo "[UNINSTALL] Removing systemd links and reloading daemon..."

  rm -f "$SERVICE_LINK" "$TIMER_LINK"
  systemctl daemon-reload

  echo "[UNINSTALL] Removing installed application files..."
  rm -rf "$APP_DIR"

  echo "[UNINSTALL] Removing Motion configs managed by installer..."
  rm -f "$MOTION_CONF_FILE"
  rm -f "$MOTION_CAMERA_DIR"/camera-*.conf

  echo "[UNINSTALL] Removing dedicated service user/group..."
  if id -u "$APP_USER" >/dev/null 2>&1; then
    userdel "$APP_USER" >/dev/null 2>&1 || true
  fi

  if getent group "$APP_GROUP" >/dev/null; then
    groupdel "$APP_GROUP" >/dev/null 2>&1 || true
  fi

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
  resolve_motion_runtime_identity
  fetch_repository
  prompt_hf_settings
  prompt_camera_settings
  prompt_snapshot_schedule
  create_app_user

  local motion_password
  motion_password="$(generate_password)"

  install_motion_configs "$motion_password"
  install_env_file "$motion_password"
  install_python_env
  install_systemd_units
  enable_and_start_services
  show_summary "$motion_password"
}

main "$@"
