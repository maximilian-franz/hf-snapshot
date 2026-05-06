#!/usr/bin/env bash
set -euo pipefail

# Usage: preview.sh <port> <outdir>
port="${1:-8080}"
outdir="${2:-$(pwd)}"

if [[ -z "$outdir" ]]; then
  echo "Usage: $0 <port> <outdir>" >&2
  exit 2
fi

mkdir -p "$outdir"
cd "$outdir"

device_file="$outdir/current_device"

# Ensure control file exists; installer will update this file per camera.
touch "$device_file"

cleanup() {
  kill "${ffmpeg_pid:-0}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Capture single frames continuously in background.
# The selected input device is read from $device_file and can be changed live
# by the installer without restarting this preview service.
while true; do
  device="$(tr -d '\r\n' < "$device_file" || true)"
  if [[ -n "$device" ]]; then
    ffmpeg -y -f v4l2 -input_format mjpeg -video_size 640x480 -i "$device" -frames:v 1 latest.jpg >/dev/null 2>&1 || true
  fi
  sleep 1
done &
ffmpeg_pid=$!

# Serve the preview directory via a simple HTTP server (foreground)
# NOTE: binding to 0.0.0.0 makes the preview reachable from the network.
# This is convenient for remote access but may expose the preview publicly.
python3 -m http.server "$port" --bind 0.0.0.0

exit 0
