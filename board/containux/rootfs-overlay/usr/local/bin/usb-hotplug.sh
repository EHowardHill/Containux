#!/bin/sh
#
# Containux udev → QMP USB passthrough pipeline (GUIDE.md §4.2)
#
# Invoked by /etc/udev/rules.d/99-containux-usb.rules as:
#     usb-hotplug.sh <add|remove> <BUSNUM> <DEVNUM>
#
# Converts the udev event into a JSON QMP payload and pushes it through the
# QEMU Monitor Protocol socket via socat, so a USB device plugged into the
# physical machine instantly appears on the guest's emulated EHCI bus — and
# vanishes the instant it is unplugged.
#

ACTION="$1"
BUSNUM="$2"
DEVNUM="$3"

QMP_SOCK="/tmp/qmp.sock"
LOCK="/tmp/containux-usb.lock"

[ -n "${ACTION}" ] && [ -n "${BUSNUM}" ] && [ -n "${DEVNUM}" ] || exit 0
# QEMU not running yet — nothing to talk to.
[ -S "${QMP_SOCK}" ] || exit 0

# Never pass the USB root hubs; they are devices too, always at devnum 001.
[ "${DEVNUM}" = "1" ] && exit 0

ID="usb-${BUSNUM}-${DEVNUM}"

# Resolve the sysfs device, so install-mode exclusions can be inspected and
# the physical port path can be derived for usb-host.
DEV_PATH=""
for d in /sys/bus/usb/devices/*; do
    case "${d}" in
        *:*) continue ;;                  # interfaces, not whole devices
    esac
    [ -f "${d}/devnum" ] || continue
    if [ "$(cat "${d}/devnum" 2>/dev/null)" = "${DEVNUM}" ] &&
       [ "$(cat "${d}/busnum" 2>/dev/null)" = "${BUSNUM}" ]; then
        DEV_PATH="${d}"
        break
    fi
done

# ---- Install-mode exclusions (GUIDE.md §5.1) ------------------------------
if [ -f /tmp/containux-install-mode ] && [ -n "${DEV_PATH}" ]; then
    # Keep every HID device off the guest's EHCI bus while the OS is being
    # installed: the physical keyboard/mouse are relayed through evdev onto
    # QEMU's emulated PS/2 ports instead, because pre-install Windows lacks
    # generic EHCI/HID drivers.
    for iface in "${DEV_PATH}":*; do
        [ -f "${iface}/bInterfaceClass" ] || continue
        [ "$(cat "${iface}/bInterfaceClass" 2>/dev/null)" = "03" ] && exit 0
    done
    # The USB stick acting as installation media is mapped as a guest block
    # device (-device usb-storage); handing it over twice would collide.
    if [ -f /tmp/containux-install-stick ]; then
        read -r STICK_BUS STICK_DEV < /tmp/containux-install-stick
        if [ "${STICK_BUS}" = "${BUSNUM}" ] && [ "${STICK_DEV}" = "${DEVNUM}" ]; then
            exit 0
        fi
    fi
fi

# ---- Build the QMP payload (GUIDE.md §4.2) ---------------------------------
if [ "${ACTION}" = "add" ]; then
    [ -n "${DEV_PATH}" ] || exit 0       # device vanished — skip quietly
    PORT=$(basename "${DEV_PATH}")       # e.g. "3-2.1"
    PORT="${PORT#*-}"                    # strip "<bus>-" → physical port "2.1"
    CMD="{\"execute\": \"device_add\", \"arguments\": {\"driver\": \"usb-host\", \"hostbus\": \"${BUSNUM}\", \"hostport\": \"${PORT}\", \"id\": \"${ID}\", \"bus\": \"ehci.0\"}}"
else
    CMD="{\"execute\": \"device_del\", \"arguments\": {\"id\": \"${ID}\"}}"
fi

# ---- Push it through the QMP socket ------------------------------------------
# QMP sessions are single-client; serialize concurrent udev events with a
# cheap mkdir lock so hotplug storms cannot trample each other.
n=0
while ! mkdir "${LOCK}" 2>/dev/null; do
    n=$((n + 1))
    [ ${n} -gt 25 ] && exit 0            # stale lock — give up silently
    sleep 0.2
done

{
    printf '%s\n' '{"execute": "qmp_capabilities"}'
    printf '%s\n' "${CMD}"
    sleep 1                              # let QEMU ingest before close
} | socat - "UNIX-CONNECT:${QMP_SOCK}" >/dev/null 2>&1

rmdir "${LOCK}" 2>/dev/null
exit 0
