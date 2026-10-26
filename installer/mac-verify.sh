#!/bin/bash
set -euo pipefail

# Containux full-chain verification (macOS host).
#
# Boots the REAL appliance kernel against the physical disk — attached to
# QEMU as an NVMe drive so the appliance's disk detection behaves like
# real hardware. The appliance renders in QEMU's own native window: the
# "physical monitor" showing the silent boot, the first-boot TUI, or a
# blank screen once the nested guest runs. Its sound card is emulated by
# this QEMU and routed to the Mac's audio output, so the nested Windows'
# audio is testable too (the inner QEMU plays through the card via ALSA).
#
# This proves the entire chain (firmware-independent kernel boot,
# partition detection, conf handling, guest boot) on the Mac before the
# drive goes back into the target machine. Windows XP runs emulated
# inside the emulated appliance (no KVM on macOS), so expect the guest
# to be VERY slow — reaching the XP logo already proves the appliance
# works; the serial trace (and the forwarded inner display, below) show
# the rest. To finish, shut Windows down; the appliance powers off with it.
#
# A full boot trace is written to dist/containux-verify.log.
#
# Usage:
#   installer/mac-verify.sh [--disk disk4] [--bzImage PATH] [--memory 2G]
#                          [--smp 2] [--audio coreaudio] [--headless]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
DIST_DIR="${ROOT_DIR}/dist"

DISK="disk4"
BZIMAGE_OPT=""
MEMORY="2G"
SMP="2"
AUDIO="coreaudio"
HEADLESS=0
DEBUGNET="10.0.2.16/24"
DEBUGNET_IP="10.0.2.16"
GUEST_VNC_PORT="5943"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Boot the real Containux appliance against the physical disk.

  --disk DISK       target disk (default: disk4)
  --bzImage PATH    appliance kernel (default: dist/bzImage)
  --memory SIZE     appliance RAM (default 2G; Windows receives what is
                    left after the host reserve)
  --smp N           virtual CPUs (default 2)
  --audio BACKEND   host audio backend for the appliance's sound card
                    (default coreaudio; "--audio none" keeps the card
                    visible to the appliance but silent)
  --headless        run without QEMU's window (CI/remote boxes)
  -h, --help        this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --disk)      DISK="$2"; shift 2 ;;
        --bzImage)   BZIMAGE_OPT="$2"; shift 2 ;;
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

# --- guest slice discovery -----------------------------------------------------
# macOS inserts its own EFI and Apple_Boot partitions on physical disks,
# so slice numbers are not stable; find the guest partition by its GPT
# type (diskutil prints known GUIDs in human-readable form, unknown ones
# as the raw GUID — accept both spellings).
GUEST_SLICE=""
for s in $(diskutil list "${DISK}" 2>/dev/null | sed -n 's/^.* \(disk[0-9]*s[0-9]*\)$/\1/p'); do
    type="$(diskutil info "/dev/${s}" 2>/dev/null |
        sed -n 's/^ *Partition Type: *//p' | tr '[:lower:]' '[:upper:]')"
    case "${type}" in
        LINUX\ FILESYSTEM|0FC63DAF-8483-4772-8E79-3D69D2105F77)
            GUEST_SLICE="${s}"
            break
            ;;
    esac
done
[ -n "${GUEST_SLICE}" ] \
    || die "no Linux-typed guest partition found on ${DISK} — run installer/mac-setup-disk.sh first."
note "Guest partition: /dev/${GUEST_SLICE}"

BZIMAGE=""
for p in "${BZIMAGE_OPT}" "${DIST_DIR}/bzImage" \
         "${ROOT_DIR}"/buildroot-*/output/images/bzImage; do
    if [ -n "${p}" ] && [ -f "${p}" ]; then BZIMAGE="${p}"; break; fi
done
[ -n "${BZIMAGE}" ] || die "no bzImage found — run installer/mac-setup-disk.sh (it builds the appliance) or pass --bzImage."

SIG="$(dd if="/dev/r${GUEST_SLICE}" bs=1 skip=3 count=8 2>/dev/null || true)"
if ! echo "${SIG}" | grep -q "^NTFS"; then
    echo "[!] WARNING: /dev/r${GUEST_SLICE} has no NTFS signature ('${SIG}')."
    echo "    Windows XP is not installed yet; the appliance will show its"
    echo "    first-boot TUI instead of booting a guest (keyboard-driven)."
    echo "    Consider running installer/mac-install-windows.sh first."
fi

mkdir -p "${DIST_DIR}"
SERIAL_LOG="${DIST_DIR}/containux-verify.log"
QEMU_LOG="${DIST_DIR}/containux-verify-qemu.log"

diskutil unmountDisk "${DISK}" >/dev/null 2>&1 || true

# The kernel console is mirrored to the serial log, so loglevel is raised
# to 7 (same trick as tests/run-test.sh --serial): a silent boot still
# produces a full trace. The appliance's debugnet address lets slirp
# privately forward its own headless qxl display to localhost.
CMDLINE="quiet loglevel=7 rd.systemd.show_status=false vt.global_cursor_default=0 console=tty3 console=ttyS0 containux.debugnet=${DEBUGNET} containux.no-kvm"

cat <<EOF
===================================================================
 Containux full-chain verification (disk: ${DISK})

   kernel:  ${BZIMAGE}
   window:  QEMU's own — the appliance's 'physical monitor'
   audio:   ${AUDIO} (the appliance's sound card)
   log:     ${SERIAL_LOG}

 What you should see, in order:
   1. a silent/black screen while the appliance boots (watch the log)
   2. the first-boot TUI if Windows is not installed yet, or a blank
      screen once the nested machine starts (the appliance itself is
      headless in qxl mode — GUIDE.md §2.2)
   3. the appliance powers the VM off when Windows shuts down, and
      this script exits

 The nested Windows boots VERY slowly (x86 emulation nested inside
 x86 emulation; give it 15-45 minutes to reach the desktop). Its
 audio plays through this Mac's speakers; its display stays inside
 the appliance — to peek, connect a VNC viewer to 127.0.0.1:${GUEST_VNC_PORT}.

 To finish: Start -> Turn off computer -> Turn Off. The appliance
 powers the virtual machine down with it, and this script exits.
 Ctrl+C aborts the test (nothing on disk is harmed by that).
===================================================================
EOF

# The physical disk plays the machine's internal drive; QEMU's NVMe
# model keeps the appliance's disk path detection meaningful (and the
# inner QEMU then exposes the guest partition to Windows over IDE,
# exactly as it will over SATA on the real machine). The appliance's
# sound card is emulated here and routed to the Mac's audio output, so
# the nested Windows' audio is testable end to end. QEMU runs in the
# foreground: its native window is the appliance's monitor.
DISPLAY_ARGS=(-display cocoa)
[ "${HEADLESS}" = 1 ] && DISPLAY_ARGS=(-display none)

note "Booting the appliance (serial trace: ${SERIAL_LOG})..."
"${QEMU}" \
    -machine q35 \
    -m "${MEMORY}" -smp "${SMP}" \
    -kernel "${BZIMAGE}" \
    -append "${CMDLINE}" \
    -drive "file=/dev/rdisk${DISK_NUM},format=raw,if=none,id=nvme0" \
    -device "nvme,drive=nvme0,serial=containux" \
    -nic "user,hostfwd=tcp:127.0.0.1:${GUEST_VNC_PORT}-${DEBUGNET_IP}:5900" \
    -audiodev "${AUDIO},id=hostaudio" -device "AC97,audiodev=hostaudio" \
    "${DISPLAY_ARGS[@]}" \
    -serial "file:${SERIAL_LOG}" >"${QEMU_LOG}" 2>&1

echo ""
echo "[*] Appliance powered off. Boot trace: ${SERIAL_LOG}"
echo "[*] If Windows XP reached the desktop, the drive is ready to go back"
echo "    into the machine. Remember: firmware set to UEFI boot, Secure"
echo "    Boot OFF."