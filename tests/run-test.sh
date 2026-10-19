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
# Two VNC endpoints are exposed so everything is observable:
#   :$BASE     the appliance's own console (silent boot + first-boot TUI)
#   :$(BASE+1) the Windows XP display (inner guest's VNC, forwarded through
#              the containux.debugnet address baked into the kernel cmdline)
#
# Alternatively --mode direct boots the same disk + ISO as a plain,
# non-nested QEMU VM using the exact guest hardware the appliance provides
# (IDE drive, e1000, AC97, S3 disabled) — handy for a fast first install
# before exercising the full appliance flow.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

MODE="appliance"
ISO=""
DISK="${SCRIPT_DIR}/containux-test.img"
BZIMAGE=""
MEMORY="2G"
SMP="2"
VNC_BASE="5901"
DEBUGNET="10.0.2.16/24"
NATIVE_DISPLAY=0
SERIAL=""
EXTRA_APPEND=""
USE_KVM=0

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
  --vnc-port N        display port, default 5901 (the single window)
  --debugnet IP/PFX   debug address for the appliance host, default
                      ${DEBUGNET} (slirp subnet)
  --native-display    open a QEMU window instead of the outer VNC
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
        --iso)       ISO="$2"; shift 2 ;;
        --disk)      DISK="$2"; shift 2 ;;
        --mode)      MODE="$2"; shift 2 ;;
        --bzImage)   BZIMAGE="$2"; shift 2 ;;
        --memory)    MEMORY="$2"; shift 2 ;;
        --smp)       SMP="$2"; shift 2 ;;
        --vnc-port)  VNC_BASE="$2"; shift 2 ;;
        --debugnet)  DEBUGNET="$2"; shift 2 ;;
        --native-display) NATIVE_DISPLAY=1; shift ;;
        --serial)    SERIAL="$2"; shift 2 ;;
        --append)    EXTRA_APPEND="$2"; shift 2 ;;
        --kvm)       USE_KVM=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           ISO="$1"; shift ;;   # bare argument = ISO path
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

DEBUGNET_IP="${DEBUGNET%%/*}"
# Display plumbing: the mux on VNC_BASE is the single user-facing window
# ("physical monitor"); the raw console and guest-forward endpoints stay
# on private localhost ports.
CONSOLE_VNC_PORT=$((VNC_BASE + 2))
GUEST_FWD_PORT=$((VNC_BASE + 3))
LOCAL_IPS="$(hostname -I 2>/dev/null || true)"

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
        # slirp also answers the guest's DHCP, and privately forwards the
        # inner Windows display to the display mux.
        -nic "user,hostfwd=tcp:127.0.0.1:${GUEST_FWD_PORT}-${DEBUGNET_IP}:5900"
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
    echo ""
    echo " Display (the appliance's 'physical monitor'):"
    echo "   vnc://<host>:${VNC_BASE}"
    [ -n "${LOCAL_IPS}" ] && echo "   e.g. vnc://$(echo ${LOCAL_IPS} | cut -d' ' -f1):${VNC_BASE}"
    echo ""
    echo " One window, like real hardware: it shows the first-boot TUI,"
    echo " then the Windows display takes over the same window when the"
    echo " guest machine starts (the window resizes itself). The TUI is"
    echo " keyboard-driven: arrows + Enter — dialog ignores mouse clicks."
    echo ""
    echo " Ctrl+C quits. The appliance powers the VM off when Windows does."
    echo "==================================================================="
else
    ARGS+=(
        # Mirror the appliance's inner hardware exactly (GUIDE.md §3).
        -machine pc
        -m "${MEMORY}"
        -smp "${SMP}"
        -drive "file=${DISK},format=raw,if=ide"
        -device usb-tablet
        -netdev user,id=hostnet0
        -device e1000,netdev=hostnet0
        -device AC97
        -global PIIX4_PM.disable_s3=1
        -boot order=dc
    )
    if [ -n "${ISO}" ]; then
        ARGS+=(-drive "file=${ISO},media=cdrom,if=ide")
    fi

    echo "==================================================================="
    echo " Containux direct guest test (no appliance nesting)"
    echo "   disk: ${DISK}"
    echo "   iso:  ${ISO:-<none>}"
    echo ""
    echo " Windows display: vnc://<host>:${VNC_BASE}"
    [ -n "${LOCAL_IPS}" ] && echo "                  e.g. vnc://$(echo ${LOCAL_IPS} | cut -d' ' -f1):${VNC_BASE}"
    echo ""
    echo " Install Windows into partition 2 (the big one). The very same"
    echo " image then boots through the appliance with --mode appliance."
    echo "==================================================================="
fi

# --- display -------------------------------------------------------------------
# Single-window experience: the mux on VNC_BASE simulates the appliance's
# physical monitor — it shows the TUI during first boot and hands over to
# the Windows display automatically (the viewer window resizes in place).
MUX_PID=""
if [ "${MODE}" = "appliance" ]; then
    if [ "${NATIVE_DISPLAY}" = 1 ]; then
        ARGS+=(-display default)
    else
        ARGS+=(-display none -vnc "127.0.0.1:$((CONSOLE_VNC_PORT - 5900))")
        python3 "${SCRIPT_DIR}/vncmux.py" "${VNC_BASE}" \
            127.0.0.1 "${CONSOLE_VNC_PORT}" 127.0.0.1 "${GUEST_FWD_PORT}" &
        MUX_PID=$!
    fi
else
    ARGS+=(-display none -vnc ":$((VNC_BASE - 5900))")
fi

if [ -n "${SERIAL}" ]; then
    ARGS+=(-serial "file:${SERIAL}")
fi

# Run QEMU in the foreground so the display mux (a background child) can be
# cleaned up on exit — including Ctrl+C, where the whole process group gets
# the signal and QEMU terminates first.
"${QEMU}" "${ARGS[@]}"
QEMU_RC=$?
if [ -n "${MUX_PID}" ]; then
    kill "${MUX_PID}" 2>/dev/null
    wait "${MUX_PID}" 2>/dev/null
fi
exit ${QEMU_RC}
