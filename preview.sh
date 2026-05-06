#!/usr/bin/env bash
set -euo pipefail

# Usage: preview.sh <device> <port> <outdir>
device="${1:-}"
port="${2:-8080}"
outdir="${3:-$(pwd)}"

if [[ -z "$device" ]]; then
  echo "Usage: $0 <device> <port> <outdir>" >&2
  exit 2
fi

mkdir -p "$outdir"
cd "$outdir"

cleanup() {
  kill "${ffmpeg_pid:-0}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Capture single frames continuously in background
while true; do
  ffmpeg -y -f v4l2 -input_format mjpeg -video_size 640x480 -i "$device" -frames:v 1 latest.jpg >/dev/null 2>&1 || true
  sleep 1
done &
ffmpeg_pid=$!

# Serve the preview directory via a simple HTTP server (foreground)
# NOTE: binding to 0.0.0.0 makes the preview reachable from the network.
# This is convenient for remote access but may expose the preview publicly.
python3 -m http.server "$port" --bind 0.0.0.0

exit 0
