#!/bin/bash
set -euo pipefail

# Containux test disk builder.
#
# Creates a sparse raw disk image mimicking the physical appliance layout
# (GUIDE.md §1), so the appliance's hardcoded /dev/nvme0n1p1 + /dev/nvme0n1p2
# paths work unchanged when the image is attached to QEMU as an NVMe drive:
#
#   p1: 100 MiB FAT32  -> boot partition (holds containux.conf; no kernel or
#                        bootloader needed inside — run-test.sh boots bzImage
#                        via QEMU's -kernel, exactly like systemd-boot would)
#   p2: rest of image  -> raw guest partition (Windows XP installs here)
#
# No root required: the partition table is written with sfdisk directly into
# the image file, and the FAT32 filesystem is built with mkfs.vfat on a
# temporary file which is then spliced in with dd.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SIZE="20G"          # comfortably fits Windows XP + extra software
IMG="${SCRIPT_DIR}/containux-test.img"
FORCE=0

P1_START_SECT=2048               # 1 MiB, aligned for any sector size
P1_SECTORS=204800                # 100 MiB

usage() {
    cat <<EOF
Usage: $(basename "$0") [-s SIZE] [-o IMG] [-f]

Create a Containux test disk image.

  -s SIZE   total image size (default: ${SIZE}; e.g. 10G, 20G, 32G)
  -o IMG    output image path (default: ${IMG})
  -f        overwrite an existing image without asking
  -h        this help

The image is sparse: a 20G image occupies almost no space until Windows
actually writes to it. Attach it to the appliance with tests/run-test.sh.
EOF
}

while getopts "hs:o:f" opt; do
    case "${opt}" in
        s) SIZE="${OPTARG}" ;;
        o) IMG="${OPTARG}" ;;
        f) FORCE=1 ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

# --- prerequisites ---------------------------------------------------------
for tool in truncate sfdisk mkfs.vfat dd; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "[!] ERROR: '${tool}' is required but not installed."
        echo "    On Debian/Ubuntu: sudo apt-get install -y dosfstools util-linux coreutils"
        echo "    (On a Mac, run this script inside the Linux build machine.)"
        exit 1
    fi
done

if [ -e "${IMG}" ] && [ "${FORCE}" != 1 ]; then
    echo "[!] ERROR: ${IMG} already exists (refusing to overwrite)."
    echo "    Pass -f to recreate it from scratch, or -o to pick another path."
    exit 1
fi

# --- create the sparse image and the partition table ------------------------
echo "[*] Creating ${IMG} (${SIZE}, sparse)..."
rm -f "${IMG}"
truncate -s "${SIZE}" "${IMG}"

echo "[*] Writing the partition table (p1: 100MiB FAT32, p2: raw guest)..."
sfdisk --quiet "${IMG}" <<EOF
label: dos
unit: sectors
start=${P1_START_SECT}, size=${P1_SECTORS}, type=0c, bootable
start=$((P1_START_SECT + P1_SECTORS)), type=07
EOF

# --- format p1 as FAT32 (rootless: build the FS in a file, splice it in) ----
echo "[*] Formatting p1 as FAT32..."
FAT_TMP="$(mktemp)"
trap 'rm -f "${FAT_TMP}"' EXIT
truncate -s 100M "${FAT_TMP}"
mkfs.vfat -F 32 -n CONTAINUX "${FAT_TMP}" >/dev/null
dd if="${FAT_TMP}" of="${IMG}" bs=512 seek="${P1_START_SECT}" conv=notrunc status=none

echo "[*] Done."
echo "    ${IMG}"
echo "      p1: 100 MiB FAT32 at offset $((P1_START_SECT * 512)) (containux.conf)"
echo "      p2: raw guest partition at sector $((P1_START_SECT + P1_SECTORS))"
echo ""
echo "Next: tests/run-test.sh --iso /path/to/windows-xp.iso"
