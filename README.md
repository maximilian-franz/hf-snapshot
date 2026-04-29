# motion-snapshot

Capture snapshots from Motion-managed webcams and upload them to a Hugging Face dataset on a schedule.

This project includes:
- A Python uploader: [motion-snapshot.py](motion-snapshot.py)
- A systemd service: [motion-snapshot.service](motion-snapshot.service)
- A systemd timer: [motion-snapshot.timer](motion-snapshot.timer)
- Motion base config: [motion.conf](motion.conf)
- Camera template config: [camera-1.conf](camera-1.conf)
- Interactive installer: [install.sh](install.sh)

## How It Works

1. Motion is configured to store snapshots under /var/lib/motion/camera-N.
2. The uploader triggers a fresh snapshot through Motion webcontrol.
3. New snapshot files are detected per camera directory.
4. Images are uploaded to your Hugging Face dataset.
5. metadata.csv is updated in the same dataset.
6. Snapshot files are cleaned from camera directories after a successful run.

## Requirements

- Linux host with systemd
- Root access for installation
- Webcam(s) exposed as V4L devices
- Internet access to Hugging Face
- A Hugging Face dataset repo and a write-capable token

The installer currently supports apt-based systems (for example Ubuntu/Debian).

## Installation

Run the installer interactively as root. It is designed for interactive mode and reads prompts from /dev/tty.

Example:

	curl -fsSL https://raw.githubusercontent.com/maximilian-franz/motion-snapshot/main/install.sh | sudo bash

What the installer does:

1. Installs required packages (git, motion, python3, python3-venv, openssl, ca-certificates).
2. Clones or updates this repository to /opt/motion-snapshot.
3. Prompts for Hugging Face repo ID and token.
4. Auto-discovers webcams via /dev/v4l/by-path/*-video-index0 (fallback to /dev/video*).
5. Lets you confirm discovered cameras or enter them manually.
6. Prompts for snapshot schedule times (default: 06:00, 14:00, 22:00, or custom HH:MM times).
7. Generates a Motion webcontrol password.
8. Installs Motion config to /etc/motion and camera configs to /etc/motion/conf.d.
9. Writes /opt/motion-snapshot/.env with your Hugging Face settings and generated Motion credentials.
10. Creates a virtual environment in /opt/motion-snapshot/.venv and installs Python dependencies.
11. Installs and links systemd service and timer units.
12. Enables and starts motion.service and motion-snapshot.timer.

During camera setup, the installer also asks for a camera number offset. Leave it at 0 on the first host, then use 4 on a second four-camera host, 8 on a third, and so on.

## Camera Discovery and Configuration

- Preferred discovery source: /dev/v4l/by-path/*-video-index0
- Fallback discovery source: /dev/video*
- If auto-discovery is not correct for your setup, choose manual mode in the installer.

The installer generates camera configs from [camera-1.conf](camera-1.conf) and writes:

- /etc/motion/conf.d/camera-1.conf
- /etc/motion/conf.d/camera-2.conf
- ...

Each generated file gets:
- camera_id N
- video_device set to your selected device path
- target_dir /var/lib/motion/camera-N

If you enter a camera number offset during installation, the generated numbers start from that offset plus 1. For example, an offset of 4 produces camera-5, camera-6, and so on.

## Runtime Configuration

Environment variables are stored in /opt/motion-snapshot/.env.

Main variables:
- HF_REPO_ID
- HF_TOKEN
- MOTION_SNAPSHOT_ENDPOINT
- MOTION_SNAPSHOT_USER
- MOTION_SNAPSHOT_PASSWORD
- MOTION_SNAPSHOTS_ROOT
- HTTP_TIMEOUT_SECONDS
- SNAPSHOT_WAIT_TIMEOUT_SECONDS
- SNAPSHOT_POLL_INTERVAL_SECONDS
- UPLOAD_RETRY_COUNT
- UPLOAD_RETRY_DELAY_SECONDS

## Scheduling

During installation, [install.sh](install.sh) prompts you for one or more schedule times in 24-hour HH:MM format.

If you accept defaults, it uses:

- 06:00
- 14:00
- 22:00

The installer writes your selected times into [motion-snapshot.timer](motion-snapshot.timer) as OnCalendar entries.

To change the schedule later, either:

- Re-run the installer and enter new times when prompted.
- Or edit [motion-snapshot.timer](motion-snapshot.timer) manually, then reload and restart the timer:

	sudo systemctl daemon-reload
	sudo systemctl restart motion-snapshot.timer

## Useful Commands

Check Motion:

	sudo systemctl status motion.service

Check timer:

	sudo systemctl status motion-snapshot.timer

Run one upload immediately:

	sudo systemctl start motion-snapshot.service

See uploader logs:

	sudo journalctl -u motion-snapshot.service -n 200 --no-pager

See timer logs:

	sudo journalctl -u motion-snapshot.timer -n 200 --no-pager

## Updating

Re-run the installer to pull the latest repository version and re-apply configuration.

## Uninstall

Use the installer in uninstall mode:

	sudo bash install.sh --uninstall

Skip the confirmation prompt:

	sudo bash install.sh --uninstall --yes

What uninstall does:

- Stops and disables:
	- motion-snapshot.timer
	- motion-snapshot.service
	- motion.service
- Removes systemd links:
	- /etc/systemd/system/motion-snapshot.service
	- /etc/systemd/system/motion-snapshot.timer
- Removes installed app directory:
	- /opt/motion-snapshot
- Removes Motion configs managed by this installer:
	- /etc/motion/motion.conf
	- /etc/motion/conf.d/camera-*.conf
- Removes dedicated service user/group (if present):
	- motion-snapshot user
	- motion-snapshot group

## Troubleshooting

No cameras discovered:
- Verify devices under /dev/v4l/by-path and /dev/video.
- Re-run installer and choose manual camera setup if needed.

Service runs but no snapshots upload:
- Check uploader logs with journalctl.
- Verify Hugging Face token and repo ID in /opt/motion-snapshot/.env.
- Verify Motion webcontrol endpoint and credentials.

Motion cannot read config:
- Ensure /etc/motion/motion.conf and /etc/motion/conf.d/*.conf exist and permissions are correct for your Motion service user/group.

## Security Notes

- The installer creates random Motion webcontrol credentials.
- Secrets are stored in /opt/motion-snapshot/.env (mode 640).
- The uploader service runs as a dedicated system user motion-snapshot.

## Project Files

- [install.sh](install.sh): interactive installer
- [motion-snapshot.py](motion-snapshot.py): uploader implementation
- [motion-snapshot.service](motion-snapshot.service): oneshot systemd unit
- [motion-snapshot.timer](motion-snapshot.timer): schedule definition
- [motion.conf](motion.conf): base Motion config template
- [camera-1.conf](camera-1.conf): camera config template
- [requirements.txt](requirements.txt): Python dependencies