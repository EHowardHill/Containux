#!/bin/sh
#
# Containux First-Boot TUI (GUIDE.md §2)
#
# Runs on tty1 when the guest partition is completely blank. Prompts for
# period-accurate hardware configuration (target OS, graphics mode, audio
# emulation), deterministically derives the guest's MAC address and SMBIOS
# UUID from the physical motherboard (GUIDE.md §5.3), and persists
# everything to containux.conf on the boot partition.
#
# Invoked by /init as:  setsid cttyhack /usr/local/bin/containux-tui.sh
#

export PATH="/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin"
export TERM="linux"

BOOT_PART="/dev/nvme0n1p1"
BOOT_MNT="/boot"
CONF_NAME="containux.conf"
BACKTITLE="Containux"

TMP=$(mktemp -d /tmp/containux-tui.XXXXXX)

# Handshake with /init: announce ourselves, and always drop the done
# sentinel (even on abnormal exit) so PID 1 never waits forever.
echo $$ > /tmp/tui.pid
trap 'rm -f /tmp/tui.pid; touch /tmp/tui.done; rm -rf "${TMP}"' EXIT

# ---------------------------------------------------------------------------
# Deterministic hardware identity (GUIDE.md §5.3)
# ---------------------------------------------------------------------------
# MAC and SMBIOS UUID must never change between boots or Windows XP/Vista
# will demand reactivation. They are hashed from the motherboard's DMI
# identity on first boot, and thereafter reused verbatim from an existing
# containux.conf (so reinstalling the guest keeps the same hardware).
if mount -t vfat -o ro "${BOOT_PART}" "${BOOT_MNT}" 2>/dev/null; then
    if [ -f "${BOOT_MNT}/${CONF_NAME}" ]; then
        # shellcheck disable=SC1090   # our own generated KEY="VALUE" file
        . "${BOOT_MNT}/${CONF_NAME}"
    fi
    umount "${BOOT_MNT}" 2>/dev/null
fi

SEED=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null)
[ -n "${SEED}" ] || SEED=$(cat /sys/class/dmi/id/board_serial 2>/dev/null)
[ -n "${SEED}" ] || SEED=$(cat /sys/class/dmi/id/product_serial 2>/dev/null)
[ -n "${SEED}" ] || SEED=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)

HASH=$(printf 'containux:%s' "${SEED}" | md5sum | cut -d' ' -f1)

GUEST_MAC="${MAC}"
if [ -z "${GUEST_MAC}" ]; then
    # 52:54:00 is the KVM virtual NIC OUI; the tail is the motherboard hash.
    GUEST_MAC="52:54:00:$(printf '%s' "${HASH}" | cut -c1-2):$(printf '%s' "${HASH}" | cut -c3-4):$(printf '%s' "${HASH}" | cut -c5-6)"
fi

GUEST_UUID="${UUID}"
if [ -z "${GUEST_UUID}" ]; then
    # RFC 4122-shaped (version 4) but still fully deterministic.
    GUEST_UUID="$(printf '%s' "${HASH}" | cut -c1-8)-$(printf '%s' "${HASH}" | cut -c9-12)-4$(printf '%s' "${HASH}" | cut -c14-16)-8$(printf '%s' "${HASH}" | cut -c18-20)-$(printf '%s' "${HASH}" | cut -c21-32)"
fi

# ---------------------------------------------------------------------------
# 1. Target OS selection (GUIDE.md §2.2)
# ---------------------------------------------------------------------------
dialog --backtitle "${BACKTITLE}" --title " First Boot Setup " \
    --msgbox "Welcome to Containux.

This machine has no operating system installed yet. The settings on
the next screens define the virtual hardware your guest OS will see.
They are locked in afterwards, so activation and drivers never break.

After setup, insert your installation CD/DVD or a bootable USB stick
and the installer will boot automatically." 13 64

while :; do
    if dialog --backtitle "${BACKTITLE}" --title " Target Operating System " \
        --menu "Which operating system will run on this machine?" 14 64 3 \
        "xp"    "Windows XP" \
        "vista" "Windows Vista" \
        "7"     "Windows 7" 2> "${TMP}/os"; then
        [ -s "${TMP}/os" ] && break
    fi
done
TARGET_OS=$(cat "${TMP}/os")

# ---------------------------------------------------------------------------
# 2. Graphics mode (GUIDE.md §2.2)
# ---------------------------------------------------------------------------
while :; do
    if dialog --backtitle "${BACKTITLE}" --title " Graphics Mode " \
        --menu "How should the guest render graphics?" 13 64 2 \
        "qxl"  "Virtual QXL - optimized 2D rendering (default)" \
        "vfio" "VFIO - raw PCIe GPU passthrough (expert)" 2> "${TMP}/gfx"; then
        [ -s "${TMP}/gfx" ] && break
    fi
done
GRAPHICS=$(cat "${TMP}/gfx")

if [ "${GRAPHICS}" = "vfio" ]; then
    dialog --backtitle "${BACKTITLE}" --title " VFIO Notice " \
        --msgbox "VFIO passthrough requires a motherboard with working
IOMMU (VT-d / AMD-Vi) support.

If the guest shows no display after setup, re-run setup with
Virtual QXL graphics instead." 10 64
fi

# ---------------------------------------------------------------------------
# 3. Audio emulation target (GUIDE.md §2.2) — default follows the OS choice
# ---------------------------------------------------------------------------
if [ "${TARGET_OS}" = "xp" ]; then
    A1="ac97"; A1_DESC="AC97 - recommended for Windows XP"
    A2="hda";  A2_DESC="Intel HDA - for Vista / 7"
else
    A1="hda";  A1_DESC="Intel HDA - recommended for Vista / 7"
    A2="ac97"; A2_DESC="AC97 - for Windows XP"
fi

while :; do
    if dialog --backtitle "${BACKTITLE}" --title " Audio Emulation " \
        --menu "Which sound card should the guest get?" 13 64 2 \
        "${A1}" "${A1_DESC}" \
        "${A2}" "${A2_DESC}" 2> "${TMP}/audio"; then
        [ -s "${TMP}/audio" ] && break
    fi
done
AUDIO=$(cat "${TMP}/audio")

# ---------------------------------------------------------------------------
# Persistence (GUIDE.md §2.2)
# ---------------------------------------------------------------------------
# Mount the boot partition read-write, save the variables to containux.conf,
# remount read-only (unmount), then hand control back to /init.
CONF_DATA="# containux.conf - generated by the Containux first-boot TUI
# Deterministic guest hardware identity (GUIDE.md \S5.3)
TARGET_OS=\"${TARGET_OS}\"
GRAPHICS=\"${GRAPHICS}\"
AUDIO=\"${AUDIO}\"
MAC=\"${GUEST_MAC}\"
UUID=\"${GUEST_UUID}\"
"

PERSISTED=0
n=0
while [ ${n} -lt 3 ]; do
    if mount -t vfat -o rw "${BOOT_PART}" "${BOOT_MNT}" 2>/dev/null; then
        PERSISTED=1
        break
    fi
    n=$((n + 1))
    sleep 1
done

if [ "${PERSISTED}" = 1 ]; then
    printf '%s\n' "${CONF_DATA}" > "${BOOT_MNT}/${CONF_NAME}"
    printf '%s\n' "${CONF_DATA}" > /tmp/containux.conf
    sync
    umount "${BOOT_MNT}" 2>/dev/null
else
    # Boot partition unwritable: keep the configuration for this session
    # so installation can proceed; it will be regenerated next boot.
    printf '%s\n' "${CONF_DATA}" > /tmp/containux.conf
    dialog --backtitle "${BACKTITLE}" --title " Warning " \
        --msgbox "The configuration could not be saved to the boot
partition (${BOOT_PART}).

Setup will continue for this session, but these choices will be
asked again on the next boot until the partition is writable." 10 64
fi

dialog --backtitle "${BACKTITLE}" --title " Setup Complete " \
    --msgbox "Configuration saved.

Insert your installation media now (if you have not already) and
press OK. The machine will boot straight into the guest installer,
and from now on Containux stays out of your way." 11 64

exit 0
