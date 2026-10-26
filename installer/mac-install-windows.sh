#!/bin/bash
set -euo pipefail

# Containux Windows XP installer (macOS host, direct mode).
#
# Installs Windows XP straight into the raw guest partition (p2) of the
# Containux disk using plain QEMU with the exact virtual hardware the
# appliance presents to the guest (GUIDE.md §3): IDE disk, e1000 NIC
# with the locked MAC from containux.conf, AC97 audio, S3 disabled. The
# result is identical to installing through the appliance itself — the
# guest partition is passed whole to QEMU/SeaBIOS either way — minus the
# nested emulation, which does not exist on Apple Silicon.
#
# Windows renders in QEMU's own native window and its AC97 sound plays
# through the Mac's audio output (CoreAudio) — no VNC anywhere.
#
# Requires: installer/mac-setup-disk.sh has been run, qemu-system-x86_64
# (brew install qemu), admin rights (self-elevates), and the Windows XP
# ISO (auto-detected in the repository root, or pass --iso).
#
# Usage:
#   installer/mac-install-windows.sh [--disk disk4] [--iso PATH]
#                                   [--memory 2G] [--smp 2]
#                                   [--audio coreaudio] [--headless]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
DIST_DIR="${ROOT_DIR}/dist"

DISK="disk4"
ISO=""
MEMORY="2G"
SMP="2"
AUDIO="coreaudio"
HEADLESS=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Install Windows XP into the Containux guest partition with QEMU.

  --disk DISK       target disk (default: disk4)
  --iso PATH        Windows XP installation ISO (default: auto-detected
                    in the repository root)
  --memory SIZE     guest RAM (default 2G; use the amount the target
                    machine will give Windows to keep the XP hardware
                    hash stable)
  --smp N           virtual CPUs (default 2)
  --audio BACKEND   host audio backend for the guest's AC97
                    (default coreaudio; "--audio none" keeps the card
                    visible to Windows but silent)
  --headless        run without QEMU's window (CI/remote boxes)
  -h, --help        this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --disk)      DISK="$2"; shift 2 ;;
        --iso)       ISO="$2"; shift 2 ;;
        --memory)    MEMORY="$2"; shift 2 ;;
        --smp)       SMP="$2"; shift 2 ;;
        --audio)     AUDIO="$2"; shift 2 ;;
        --headless)  HEADLESS=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           usage >&2; exit 1 ;;
    esac
done

die()  { echo "[!] ERROR: $*" >&2; exit 1; }
note() { echo "[*] $*"; }

[ "$(uname -s)" = "Darwin" ] || die "this script must run on macOS"

if [ "$(id -u)" != 0 ]; then
    echo "[*] Administrator rights are needed; re-running with sudo..."
    exec sudo "$0" "$@"
fi

QEMU="qemu-system-x86_64"
command -v "${QEMU}" >/dev/null 2>&1 \
    || die "${QEMU} not found. Install it with: brew install qemu"

[ -e "/dev/${DISK}" ] || die "/dev/${DISK} does not exist. Attach the disk and check 'diskutil list'."
DISK_NUM="${DISK#disk}"
case "${DISK_NUM}" in
    *[!0-9]*|'') die "'${DISK}' is not a disk identifier (expected e.g. disk4)" ;;
esac

# --- appliance slice discovery ----------------------------------------------------
# macOS inserts its own EFI and Apple_Boot partitions on physical disks,
# so slice numbers are not stable; find the appliance partitions by their
# GPT type (diskutil prints known GUIDs in human-readable form like
# "EFI", unknown ones as the raw GUID — accept both spellings).
disk_slices() {
    diskutil list "${DISK}" 2>/dev/null | sed -n 's/^.* \(disk[0-9]*s[0-9]*\)$/\1/p'
}

slice_guid() {
    diskutil info "/dev/$1" 2>/dev/null | sed -n 's/^ *Partition Type: *//p' |
        tr '[:lower:]' '[:upper:]'
}

is_esp_type() {
    case "${1:-}" in
        EFI|C12A7328-F81F-11D2-BA4B-00A0C93EC93B) return 0 ;;
        *) return 1 ;;
    esac
}

is_guest_type() {
    case "${1:-}" in
        LINUX\ FILESYSTEM|0FC63DAF-8483-4772-8E79-3D69D210F577) return 0 ;;
        *) return 1 ;;
    esac
}

mount_point_of() {
    diskutil info "/dev/$1" 2>/dev/null | sed -n 's/^ *Mount Point: *//p'
}

find_guest_slice() {
    local s
    GUEST_SLICE=""
    for s in $(disk_slices); do
        if is_guest_type "$(slice_guid "${s}")"; then
            GUEST_SLICE="${s}"
            return 0
        fi
    done
    return 1
}

# The boot partition is the ESP that carries the appliance (containux.conf
# or the kernel); blank ESPs macOS reserved are skipped by the content
# probe.
find_boot_slice() {
    local s m tmp made
    BOOT_SLICE=""
    for s in $(disk_slices); do
        is_esp_type "$(slice_guid "${s}")" || continue
        m="$(mount_point_of "${s}")"
        made=""
        if [ -z "${m}" ] || [ ! -d "${m}" ]; then
            tmp="$(mktemp -d /tmp/containux-probe.XXXXXX)"
            if ! diskutil mount -mountPoint "${tmp}" "/dev/${s}" >/dev/null 2>&1; then
                rmdir "${tmp}" 2>/dev/null || true
                continue
            fi
            m="${tmp}"
            made="1"
        fi
        if [ -f "${m}/containux.conf" ] || [ -f "${m}/EFI/BOOT/BOOTX64.EFI" ]; then
            BOOT_SLICE="${s}"
        fi
        if [ -n "${made}" ]; then
            diskutil unmount "/dev/${s}" >/dev/null 2>&1 || true
            rmdir "${m}" 2>/dev/null || true
        fi
        [ -n "${BOOT_SLICE}" ] && return 0
    done
    return 1
}

if ! find_boot_slice; then
    die "no Containux boot partition found on ${DISK} — run installer/mac-setup-disk.sh first."
fi
if ! find_guest_slice; then
    die "no Linux-typed guest partition found on ${DISK} — run installer/mac-setup-disk.sh first."
fi
note "Boot partition: /dev/${BOOT_SLICE}  guest partition: /dev/${GUEST_SLICE}"

# --- installation ISO ---------------------------------------------------------
if [ -z "${ISO}" ]; then
    ISO_COUNT=0
    for f in "${ROOT_DIR}"/*.iso; do
        [ -e "$f" ] || continue
        ISO_COUNT=$((ISO_COUNT + 1))
        ISO="$f"
    done
    [ "${ISO_COUNT}" -gt 0 ] || die "no .iso found in ${ROOT_DIR}; pass --iso /path/to/windows-xp.iso"
    [ "${ISO_COUNT}" -eq 1 ] || die "multiple ISOs found in ${ROOT_DIR}; pass --iso to pick one"
fi
[ -f "${ISO}" ] || die "ISO ${ISO} does not exist."

# --- locked guest identity from the boot partition -------------------------------
# The appliance reads MAC/UUID from containux.conf on the boot partition;
# install Windows against the very same values so it never sees changed
# hardware when the drive moves to the real machine.
MNT="$(mount_point_of "${BOOT_SLICE}")"
MADE_MNT=""
if [ -z "${MNT}" ] || [ ! -d "${MNT}" ]; then
    MADE_MNT="$(mktemp -d /tmp/containux-boot.XXXXXX)"
    diskutil mount -mountPoint "${MADE_MNT}" "/dev/${BOOT_SLICE}" >/dev/null \
        || die "could not mount /dev/${BOOT_SLICE} — run installer/mac-setup-disk.sh first"
    MNT="${MADE_MNT}"
fi
[ -f "${MNT}/containux.conf" ] \
    || die "no containux.conf on /dev/${BOOT_SLICE} — run installer/mac-setup-disk.sh first"
# shellcheck disable=SC1091
. "${MNT}/containux.conf"
diskutil unmount "/dev/${BOOT_SLICE}" >/dev/null
[ -n "${MADE_MNT}" ] && rmdir "${MADE_MNT}" 2>/dev/null || true

[ -n "${MAC:-}" ]  || die "containux.conf has no MAC"
[ -n "${UUID:-}" ] || die "containux.conf has no UUID"

# --- acceleration ------------------------------------------------------------------
# Apple Silicon has no hardware x86_64 virtualization; on Intel Macs
# Hypervisor.framework makes the install dramatically faster.
ACCEL="tcg"
if [ "$(uname -m)" = "x86_64" ]; then
    PROBE_LOG="$(mktemp /tmp/containux-accel.XXXXXX)"
    "${QEMU}" -machine none -accel hvf -display none >"${PROBE_LOG}" 2>&1 &
    PROBE_PID=$!
    sleep 2
    if kill -0 "${PROBE_PID}" 2>/dev/null; then
        ACCEL="hvf"
        kill "${PROBE_PID}" 2>/dev/null || true
    fi
    wait "${PROBE_PID}" 2>/dev/null || true
    rm -f "${PROBE_LOG}"
fi
note "QEMU acceleration: ${ACCEL}"

# --- go ---------------------------------------------------------------------------
diskutil unmountDisk "${DISK}" >/dev/null 2>&1 || true

cat <<EOF
===================================================================
 Installing Windows XP into /dev/r${GUEST_SLICE} (raw guest partition)

   ISO:     ${ISO}
   RAM:     ${MEMORY}   CPUs: ${SMP}
   NIC MAC: ${MAC} (locked; matches the real machine)
   Audio:   ${AUDIO} (the guest's AC97)

 Display: QEMU's own window — the XP installer appears in it directly.

 In the XP installer:
   * FIRST boot: press a key when SeaBIOS asks "Press any key to boot
     from CD" — that starts the setup program.
   * You will see ONE unallocated disk (that is partition 2 seen from
     inside, exactly how the appliance will show it to Windows).
   * Create a partition using the full size and install there
     (quick NTFS format is fine).
   * Setup REBOOTS the machine several times: do NOT press anything at
     those "Press any key" prompts — it falls through to the disk and
     setup continues automatically.
   * When XP reaches the desktop, shut Windows down with
     Start -> Turn off computer -> Turn Off. QEMU then exits cleanly.
   * Do NOT press Ctrl+C here while XP is running: this is a real disk.
   ${ACCEL} emulation on this Mac may make the install take a while.
===================================================================
EOF

# Hardware mirrors the appliance's inner QEMU (GUIDE.md §3), with one
# host-side substitution: -vga std (homebrew QEMU ships no QXL; the
# appliance's QXL is VGA-compatible, so XP's in-box VGA driver drives it
# the same way). The AC97 routes to the Mac's audio output through
# CoreAudio; QEMU runs in the foreground with its output captured to a log.
DISPLAY_ARGS=(-display cocoa)
[ "${HEADLESS}" = 1 ] && DISPLAY_ARGS=(-display none)

mkdir -p "${DIST_DIR}"
QLOG="${DIST_DIR}/containux-install.log"
note "Launching QEMU (log: ${QLOG})..."
# Ctrl+C (or a QEMU crash) must not skip the NTFS sanity check below:
# the parent ignores SIGINT for the duration (QEMU itself receives it
# and shuts the machine down), and any QEMU exit status is tolerated.
trap '' INT
"${QEMU}" \
    -machine pc -accel "${ACCEL}" \
    -m "${MEMORY}" -smp "${SMP}" \
    -uuid "${UUID}" \
    -rtc base=localtime \
    -global PIIX4_PM.disable_s3=1 \
    -device usb-ehci,id=ehci \
    -vga std \
    -audiodev "${AUDIO},id=hostaudio" -device AC97,audiodev=hostaudio \
    -drive "file=/dev/r${GUEST_SLICE},format=raw,if=ide" \
    -drive "file=${ISO},media=cdrom,if=ide" \
    -device usb-tablet \
    -netdev user,id=hostnet0 -device e1000,netdev=hostnet0,mac="${MAC}" \
    "${DISPLAY_ARGS[@]}" \
    -boot order=dc >"${QLOG}" 2>&1 || true
trap - INT

# --- sanity check -----------------------------------------------------------------
diskutil unmountDisk "${DISK}" >/dev/null 2>&1 || true
SIG="$(dd if="/dev/r${GUEST_SLICE}" bs=1 skip=3 count=8 2>/dev/null || true)"
case "${SIG}" in
    NTFS*)
        echo ""
        echo "[*] Windows XP is installed: /dev/r${GUEST_SLICE} carries an NTFS signature."
        cat <<EOF

 Next: verify the full appliance chain on this Mac before moving the
 drive back to the machine:

   installer/mac-verify.sh
EOF
        ;;
    *)
        echo ""
        echo "[!] WARNING: /dev/r${GUEST_SLICE} has no NTFS signature ('${SIG}')."
        echo "    Windows XP does not appear to have been installed; re-run this script."
        echo "    QEMU output this session: ${QLOG}"
        exit 1
        ;;
esac
