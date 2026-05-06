# hf-snapshot

Capture snapshots from persistent V4L device paths with ffmpeg and upload them to a Hugging Face dataset on a schedule.

This project includes:
- A Python uploader: [hf-snapshot.py](hf-snapshot.py)
- A systemd service: [hf-snapshot.service](hf-snapshot.service)
- A systemd timer: [hf-snapshot.timer](hf-snapshot.timer)
- Interactive installer: [install.sh](install.sh)

## How It Works

1. The installer asks you to unplug all cameras you want to enroll.
2. You plug cameras in one at a time, and the installer detects each persistent `/dev/v4l/by-path` device as it appears.
3. You assign a name to each camera during installation.
4. The installer writes a small camera mapping file in /opt/hf-snapshot.
5. ffmpeg captures one snapshot per configured camera into a temporary workspace.
6. Images are uploaded to your Hugging Face dataset.
7. metadata.csv is updated in the same dataset.

Preview & Rotation
-------------------

During interactive camera enrollment the installer provides a short-lived preview service for each camera so you can inspect the live image and choose a friendly name and rotation. The preview is served on `127.0.0.1` (port `8080` and subsequent ports if you enroll multiple cameras). If you are installing remotely, use SSH port forwarding to view the preview in your local browser.

You can specify a rotation of `0`, `90`, `180`, or `270` degrees for each camera during enrollment. The installer records this rotation in `/opt/hf-snapshot/cameras.json` and the uploader will apply the rotation to captured snapshots using ffmpeg.

Preview helper requirement
--------------------------

The installer requires a helper script `preview.sh` in the repository root. During installation the installer will make `preview.sh` executable (mode 755) and run it transiently via `systemd-run` to provide the live preview. The preview server binds to `0.0.0.0` so it is reachable from other hosts on your network; this is convenient for remote viewing but may expose the preview publicly. If you'd like to restrict access, use SSH port forwarding or firewall rules. Ensure your cloned repository includes `preview.sh` at the root; this file is included in the project and the installer will use it automatically.

## Requirements

- Linux host with systemd
- Root access for installation
- Webcam(s) exposed as V4L devices
- Persistent device paths under /dev/v4l/by-path
- ffmpeg installed on the host
- Internet access to Hugging Face
- A Hugging Face dataset repo and a write-capable token

The installer currently supports apt-based systems (for example Ubuntu/Debian).

## Installation

Run the installer interactively as root. It is designed for interactive mode and reads prompts from /dev/tty.

Example:

	curl -fsSL https://raw.githubusercontent.com/maximilian-franz/hf-snapshot/main/install.sh | sudo bash

What the installer does:

1. Installs required packages (git, ffmpeg, python3, python3-venv, openssl, ca-certificates).
2. Clones or updates this repository to /opt/hf-snapshot.
3. Prompts for Hugging Face repo ID and token.
4. Prompts you to unplug all cameras, then connect them one at a time.
5. Detects each persistent camera path under /dev/v4l/by-path and prompts you to name it.
6. Writes a camera mapping file in /opt/hf-snapshot/cameras.json.
7. Prompts for snapshot schedule times (default: 06:00, 14:00, 22:00, or custom HH:MM times).
8. Writes /opt/hf-snapshot/.env with your Hugging Face, camera, and ffmpeg settings.
9. Creates a virtual environment in /opt/hf-snapshot/.venv and installs Python dependencies.
10. Installs and links systemd service and timer units.
11. Enables and starts hf-snapshot.timer.

## Runtime Configuration

Environment variables are stored in /opt/hf-snapshot/.env.

Main variables:
- HF_REPO_ID
- HF_TOKEN
- CAMERA_CONFIG_FILE
- FFMPEG_BINARY
- FFMPEG_INPUT_FORMAT
- FFMPEG_VIDEO_SIZE
- UPLOAD_RETRY_COUNT
- UPLOAD_RETRY_DELAY_SECONDS

Camera mapping file:
	/opt/hf-snapshot/cameras.json

Each entry maps a persistent device path to a configured camera name.

## Scheduling

During installation, [install.sh](install.sh) prompts you for one or more schedule times in 24-hour HH:MM format.

If you accept defaults, it uses:

- 06:00
- 14:00
- 22:00

The installer writes your selected times into [hf-snapshot.timer](hf-snapshot.timer) as OnCalendar entries.

To change the schedule later, either:

- Re-run the installer and enter new times when prompted.
- Or edit [hf-snapshot.timer](hf-snapshot.timer) manually, then reload and restart the timer:

	sudo systemctl daemon-reload
	sudo systemctl restart hf-snapshot.timer

## Useful Commands

Check timer:

	sudo systemctl status hf-snapshot.timer

Run one upload immediately:

	sudo systemctl start hf-snapshot.service

See uploader logs:

	sudo journalctl -u hf-snapshot.service -n 200 --no-pager

See timer logs:

	sudo journalctl -u hf-snapshot.timer -n 200 --no-pager

## Updating

Re-run the installer to pull the latest repository version and re-apply configuration.

## Uninstall

Use the installer in uninstall mode:

	sudo bash install.sh --uninstall

If you do not have a local copy of the installer, you can uninstall directly from GitHub:

	curl -fsSL https://raw.githubusercontent.com/maximilian-franz/hf-snapshot/main/install.sh | sudo bash -s -- --uninstall

Skip the confirmation prompt:

	sudo bash install.sh --uninstall --yes

From GitHub (no confirmation prompt):

	curl -fsSL https://raw.githubusercontent.com/maximilian-franz/hf-snapshot/main/install.sh | sudo bash -s -- --uninstall --yes

What uninstall does:

- Stops and disables:
	- hf-snapshot.timer
	- hf-snapshot.service
- Removes systemd links:
	- /etc/systemd/system/hf-snapshot.service
	- /etc/systemd/system/hf-snapshot.timer
- Removes installed app directory:
	- /opt/hf-snapshot

## Troubleshooting

No cameras discovered:
- Verify devices under /dev/v4l/by-path.
- Verify ffmpeg can access the device and that the V4L driver is loaded.

Service runs but no snapshots upload:
- Check uploader logs with journalctl.
- Verify Hugging Face token and repo ID in /opt/hf-snapshot/.env.
- Verify ffmpeg is installed and that the configured input format and video size match your camera.
- Verify the camera names and persistent device paths in /opt/hf-snapshot/cameras.json.

## Security Notes

- Secrets are stored in /opt/hf-snapshot/.env (mode 640).
- The uploader service runs as root with a restricted systemd sandbox.

## Project Files

- [install.sh](install.sh): interactive installer
- [hf-snapshot.py](hf-snapshot.py): uploader implementation
- [hf-snapshot.service](hf-snapshot.service): oneshot systemd unit
- [hf-snapshot.timer](hf-snapshot.timer): schedule definition
- [requirements.txt](requirements.txt): Python dependencies