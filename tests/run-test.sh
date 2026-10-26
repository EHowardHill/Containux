#!/bin/bash
set -euo pipefail

# Containux appliance test runner.
#
# Boots the built appliance (bzImage with the initramfs linked in) inside
# QEMU against the test disk created by make-test-disk.sh, attached as an
# NVMe drive so the appliance's hardcoded /dev/nvme0n1p1/p2 paths work.
# Your Windows XP installation ISO is passed through to the appliance as
# /dev/sr0, exactly like a physical CD-ROM would be (GUIDE.md §3.1).
#
# Everything renders in QEMU's own native window on the test host — no
# VNC anywhere in the test path:
#   appliance mode  the window is the appliance's physical monitor: the
#                   first-boot TUI, then a silent screen once the nested
#                   guest takes over. The appliance's sound card is
#                   emulated by this QEMU and routed to the host's audio
#                   output, so the nested Windows' audio is testable
#                   (its inner QEMU plays through the card via ALSA).
#   --mode direct  plain QEMU VM with the appliance's guest hardware
#                   (IDE drive, e1000, AC97): the window shows Windows
#                   directly, and its audio plays through the host.
#                   Handy for a fast first install before exercising the
#                   full appliance flow.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

MODE="appliance"
ISO=""
DISK="${SCRIPT_DIR}/containux-test.img"
BZIMAGE=""
MEMORY="2G"
SMP="2"
GUEST_VNC_PORT="5943"
DEBUGNET="10.0.2.16/24"
SERIAL=""
EXTRA_APPEND=""
USE_KVM=0
HEADLESS=0
AUDIO=""

usage() {
    cat <<EOF
Usage: $(basename "$0") --iso /path/to/windows-xp.iso [options]

  --iso PATH          Windows XP installation ISO (CD or DVD image)
  --disk PATH         test disk image (default: ${DISK};
                      create one with tests/make-test-disk.sh)
  --mode MODE         appliance (default) — boot the real Containux bzImage,
                      with the ISO attached as the physical CD-ROM
                      direct — plain QEMU VM with the appliance's guest
                      hardware (fast install path, no nesting)
  --bzImage PATH      appliance kernel (default: auto-detect
                      buildroot-*/output/images/bzImage)
  --memory SIZE       VM memory, default 2G (appliance keeps 256M for
                      itself and hands the rest to Windows)
  --smp N             virtual CPUs, default 2
  --audio BACKEND     host audio backend for the emulated sound card,
                      default: coreaudio on macOS, pa on Linux
                      ("--audio none" keeps the card visible to the
                      guest but silent)
  --headless          run without QEMU's window (CI/remote boxes)
  --guest-vnc-port N  localhost port forwarded to the appliance's own
                      headless qxl display, default ${GUEST_VNC_PORT}
                      (connect a VNC viewer only when you need to see
                      the nested Windows display; see GUIDE.md §2.2)
  --debugnet IP/PFX   debug address for the appliance host, default
                      ${DEBUGNET} (slirp subnet)
  --serial FILE       also log the appliance kernel console to FILE
  --append STR        extra kernel cmdline parameters
  --kvm               allow KVM inside the appliance (only meaningful on
                      hosts with nested virtualization; the appliance
                      otherwise runs its guest under TCG with a larger
                      host memory reserve)
  -h                  this help

Examples:
  $(basename "$0") --iso ~/isos/winxp_sp3.iso
  $(basename "$0") --iso ~/isos/winxp_sp3.iso --mode direct
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --iso)             ISO="$2"; shift 2 ;;
        --disk)           DISK="$2"; shift 2 ;;
        --mode)           MODE="$2"; shift 2 ;;
        --bzImage)        BZIMAGE="$2"; shift 2 ;;
        --memory)         MEMORY="$2"; shift 2 ;;
        --smp)            SMP="$2"; shift 2 ;;
        --audio)          AUDIO="$2"; shift 2 ;;
        --headless)       HEADLESS=1; shift ;;
        --guest-vnc-port) GUEST_VNC_PORT="$2"; shift 2 ;;
        --debugnet)       DEBUGNET="$2"; shift 2 ;;
        --serial)         SERIAL="$2"; shift 2 ;;
        --append)         EXTRA_APPEND="$2"; shift 2 ;;
        --kvm)            USE_KVM=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                ISO="$1"; shift ;;   # bare argument = ISO path
    esac
done

# --- sanity checks ------------------------------------------------------------
QEMU="qemu-system-x86_64"
if ! command -v "${QEMU}" >/dev/null 2>&1; then
    echo "[!] ERROR: ${QEMU} not found."
    echo "    Debian/Ubuntu: sudo apt-get install -y qemu-system-x86"
    echo "    macOS (homebrew): brew install qemu"
    exit 1
fi

if [ ! -f "${DISK}" ]; then
    echo "[!] ERROR: test disk ${DISK} does not exist."
    echo "    Create it first:  tests/make-test-disk.sh"
    exit 1
fi

if [ -n "${ISO}" ] && [ ! -f "${ISO}" ]; then
    echo "[!] ERROR: ISO ${ISO} does not exist."
    exit 1
fi

if [ "${MODE}" != "appliance" ] && [ "${MODE}" != "direct" ]; then
    echo "[!] ERROR: unknown mode '${MODE}' (expected appliance or direct)."
    exit 1
fi

DEBUGNET_IP="${DEBUGNET%%/*}"

# --- display & audio ------------------------------------------------------------
# Display: QEMU's own window — cocoa on macOS, SDL/GTK on Linux; --headless
# drops the window entirely (the serial log stays available). The emulated
# sound card is routed to the host's audio backend the same way: coreaudio
# on macOS, PulseAudio on a Linux desktop. Audio stays emulated (visible to
# the guest) but silent with --audio none.
DISPLAY_ARGS=(-display cocoa)
if [ "$(uname -s)" != "Darwin" ]; then
    DISPLAY_ARGS=(-display default)
fi
if [ "${HEADLESS}" = 1 ]; then
    DISPLAY_ARGS=(-display none)
fi

if [ -z "${AUDIO}" ]; then
    AUDIO="coreaudio"
    [ "$(uname -s)" = "Linux" ] && AUDIO="pa"
fi
AUDIO_ARGS=(-audiodev "${AUDIO},id=hostaudio" -device "AC97,audiodev=hostaudio")

ARGS=()

if [ "${MODE}" = "appliance" ]; then
    # Locate the appliance kernel (bzImage with the initramfs linked in).
    if [ -z "${BZIMAGE}" ]; then
        for candidate in "${ROOT_DIR}"/buildroot-*/output/images/bzImage; do
            if [ -f "${candidate}" ]; then BZIMAGE="${candidate}"; break; fi
        done
    fi
    if [ -z "${BZIMAGE}" ] || [ ! -f "${BZIMAGE}" ]; then
        echo "[!] ERROR: appliance bzImage not found (looked in ${ROOT_DIR}/buildroot-*/output/images/)."
        echo "    Build it first (./build.sh) or pass --bzImage /path/to/bzImage."
        exit 1
    fi

    # loglevel=0 keeps the appliance silent; raise it when the kernel
    # console is mirrored to a serial log for debugging.
    LOGLEVEL=0
    if [ -n "${SERIAL}" ]; then
        LOGLEVEL=7
    fi
    CMDLINE="quiet loglevel=${LOGLEVEL} rd.systemd.show_status=false vt.global_cursor_default=0 console=tty3"
    if [ -n "${SERIAL}" ]; then
        CMDLINE="${CMDLINE} console=ttyS0"
    fi
    CMDLINE="${CMDLINE} containux.debugnet=${DEBUGNET}"
    # The emulated appliance cannot nest KVM, and no runtime signal can
    # detect that reliably — declare the environment explicitly instead,
    # so the appliance sizes its TCG memory reserve correctly.
    if [ "${USE_KVM}" != 1 ]; then
        CMDLINE="${CMDLINE} containux.no-kvm"
    fi
    CMDLINE="${CMDLINE} ${EXTRA_APPEND}"

    ARGS+=(
        -machine q35
        -m "${MEMORY}"
        -smp "${SMP}"
        -kernel "${BZIMAGE}"
        -append "${CMDLINE}"
        # The test disk plays the physical NVMe drive: partitions land on
        # /dev/nvme0n1p1 + /dev/nvme0n1p2 exactly like real hardware.
        -drive "file=${DISK},format=raw,if=none,id=nvme0"
        -device "nvme,drive=nvme0,serial=containux"
        # The installer ISO is the physical CD-ROM: /dev/sr0 in the appliance.
        -nic "user,hostfwd=tcp:127.0.0.1:${GUEST_VNC_PORT}-${DEBUGNET_IP}:5900"
        # The appliance's "physical" sound card: its inner QEMU's ALSA
        # backend plays the nested Windows' audio through it (GUIDE.md
        # §3.4), and this QEMU routes the card to the host's speakers.
        "${AUDIO_ARGS[@]}"
        "${DISPLAY_ARGS[@]}"
    )
    if [ -n "${ISO}" ]; then
        ARGS+=(-drive "file=${ISO},media=cdrom,format=raw")
    else
        echo "[*] No --iso given: the appliance will wait on screen for"
        echo "    installation media (only matters while the guest is empty)."
    fi

    echo "==================================================================="
    echo " Containux appliance test"
    echo "   disk:     ${DISK}"
    echo "   kernel:  ${BZIMAGE}"
    echo "   iso:     ${ISO:-<none>}"
    echo "   audio:    ${AUDIO} (the appliance's sound card)"
    echo ""
    echo " Display: QEMU's own window — the appliance's 'physical monitor':"
    echo "   the first-boot TUI now, a silent screen once the guest runs."
    echo "   The TUI is keyboard-driven: arrows + Enter (dialog ignores"
    echo "   mouse clicks)."
    echo ""
    echo " The nested Windows' audio plays through this host's speakers."
    echo " Its display stays inside the appliance (headless qxl); to peek,"
    echo " connect a VNC viewer to 127.0.0.1:${GUEST_VNC_PORT} if ever needed."
    echo ""
    echo " Ctrl+C quits. The appliance powers the VM off when Windows does."
    echo "==================================================================="
else
    ARGS+=(
        # Mirror the appliance's inner hardware exactly (GUIDE.md §3):
        # the EHCI controller creates the USB bus the tablet rides on.
        -machine pc
        -m "${MEMORY}"
        -smp "${SMP}"
        -drive "file=${DISK},format=raw,if=ide"
        -device usb-ehci,id=ehci
        -device usb-tablet
        -netdev user,id=hostnet0
        -device e1000,netdev=hostnet0
        # The guest's own sound card, routed to this host's audio output.
        "${AUDIO_ARGS[@]}"
        -global PIIX4_PM.disable_s3=1
        -boot order=dc
        "${DISPLAY_ARGS[@]}"
    )
    if [ -n "${ISO}" ]; then
        ARGS+=(-drive "file=${ISO},media=cdrom,if=ide")
    fi

    echo "==================================================================="
    echo " Containux direct guest test (no appliance nesting)"
    echo "   disk:  ${DISK}"
    echo "   iso:   ${ISO:-<none>}"
    echo "   audio: ${AUDIO} (the guest's AC97)"
    echo ""
    echo " Display: QEMU's own window — Windows directly, audio through"
    echo " this host's speakers."
    echo ""
    echo " Install Windows into partition 2 (the big one). The very same"
    echo " image then boots through the appliance with --mode appliance."
    echo "==================================================================="
fi

if [ -n "${SERIAL}" ]; then
    ARGS+=(-serial "file:${SERIAL}")
fi

# QEMU runs in the foreground: its window is the test's display, and Ctrl+C
# (or closing the window) terminates it directly — no helpers to clean up.
"${QEMU}" "${ARGS[@]}"