#!/bin/sh
#
# Containux post-build hook (GUIDE.md file guide: "sets file permissions").
#
# Buildroot invokes this as: post-build.sh <TARGET_DIR>
# Git does not reliably preserve the executable bit across clones, and the
# rootfs overlay copies files verbatim, so enforce the permissions the
# runtime depends on here, right before the rootfs is packaged.
#
set -e

TARGET_DIR="${1:?usage: post-build.sh <target-dir>}"

# PID 1 and the runtime helpers must be executable.
for f in \
    init \
    usr/local/bin/containux-tui.sh \
    usr/local/bin/usb-hotplug.sh
do
    if [ -e "${TARGET_DIR}/${f}" ]; then
        chmod 0755 "${TARGET_DIR}/${f}"
    else
        echo "post-build: missing overlay file: ${f}" >&2
        exit 1
    fi
done

# Policy files must be readable (udev rules + USB driver blacklist).
for f in \
    etc/udev/rules.d/99-containux-usb.rules \
    etc/modprobe.d/containux.conf
do
    if [ -e "${TARGET_DIR}/${f}" ]; then
        chmod 0644 "${TARGET_DIR}/${f}"
    else
        echo "post-build: missing overlay file: ${f}" >&2
        exit 1
    fi
done

# Mount points used at runtime by the init script.
mkdir -p "${TARGET_DIR}/boot" "${TARGET_DIR}/mnt"
chmod 0755 "${TARGET_DIR}/boot" "${TARGET_DIR}/mnt"

# /tmp holds the QMP socket, QMP payloads and the hotplug lock.
mkdir -p "${TARGET_DIR}/tmp"
chmod 1777 "${TARGET_DIR}/tmp"
