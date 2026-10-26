#!/bin/bash
set -euo pipefail

# Containux physical-disk installer (macOS host).
#
# Turns a blank external disk (default: disk4) into a bootable Containux
# appliance, ready to receive a legacy OS:
#
#   1. makes sure the appliance kernel (bzImage with the linked
#      initramfs) exists and is up to date — building inside the Linux
#      VM via ./build.sh when the OrbStack `orb` CLI is available
#   2. partitions the disk: GPT with a 100 MiB EFI System Partition
#      (p1, FAT32) and a raw guest partition (p2)
#   3. installs the unified kernel image as \EFI\BOOT\BOOTX64.EFI — the
#      kernel's EFI stub boots it straight from the firmware, with the
#      silent-boot cmdline baked into linux.config (no bootloader needed)
#      — plus a containux.conf with a locked-in guest MAC/UUID
#
# Everything is verified on the Mac before the drive goes back into the
# machine: run installer/mac-install-windows.sh next, then
# installer/mac-verify.sh.
#
# Requires: macOS, admin rights (self-elevates). diskutil,
# newfs_msdos, file, openssl and uuidgen all ship with macOS.
#
# Usage:
#   installer/mac-setup-disk.sh [--disk disk4] [--bzImage PATH]
#                              [--os xp|vista|7] [--graphics qxl|vfio]
#                              [--audio ac97|hda] [--gpu-bfd 01:00.0]
#                              [--yes] [--skip-build] [--force-build]
#                              [--update-only]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
DIST_DIR="${ROOT_DIR}/dist"

DISK="disk4"
BZIMAGE_OPT=""
TARGET_OS="xp"
GRAPHICS="qxl"
AUDIO="ac97"
ASSUME_YES=0
SKIP_BUILD=0
FORCE_BUILD=0
UPDATE_ONLY=0
GPU_BDF_OPT=""
VERBOSE_OPT=0
BOOT_MB=100

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Install Containux onto a physical disk from macOS.

  --disk DISK       target disk (default: disk4)
  --bzImage PATH     appliance kernel to install (default: dist/bzImage,
                    auto-built via the Linux VM when missing/stale)
  --os OS            guest OS profile: xp (default), vista or 7
  --graphics MODE    qxl (default) or vfio
  --audio CARD       ac97 (default) or hda
  --boot-size MB     boot partition size (default: 100, per GUIDE.md; grown
                     automatically when the kernel image needs more room)
  --update-only      refresh the kernel + containux.conf on an already
                     installed disk WITHOUT re-partitioning (the guest
                     partition and its Windows stay untouched)
  --gpu-bfd BDF      with --graphics vfio: pin the PCIe address (e.g.
                      01:00.0) of the GPU to pass through; written to
                     containux.conf as GPU_BDF (auto-detect if unset)
  --verbose          mirror the appliance's boot traces onto the physical
                      monitor (VERBOSE=yes), so a headless-looking failure
                      can be read off the machine's own display
  --yes              do not ask for confirmation
  --skip-build       never build; fail if no bzImage exists
  --force-build      always rebuild inside the Linux VM
  -h, --help         this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --disk)       DISK="$2"; shift 2 ;;
        --bzImage)    BZIMAGE_OPT="$2"; shift 2 ;;
        --os)         TARGET_OS="$2"; shift 2 ;;
        --graphics)   GRAPHICS="$2"; shift 2 ;;
        --audio)      AUDIO="$2"; shift 2 ;;
        --boot-size)  BOOT_MB="$2"; shift 2 ;;
        --update-only) UPDATE_ONLY=1; shift ;;
        --gpu-bfd)    GPU_BDF_OPT="$2"; shift 2 ;;
        --verbose)    VERBOSE_OPT=1; shift ;;
        --yes|-y)     ASSUME_YES=1; shift ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        --force-build) FORCE_BUILD=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            usage >&2; exit 1 ;;
    esac
done

die()  { echo "[!] ERROR: $*" >&2; exit 1; }
note() { echo "[*] $*"; }

# Make a file/directory owned by the invoking (non-sudo) user, so that
# artifacts the script leaves behind stay editable and that the Linux
# VM — which reaches the Mac through OrbStack's share as the ordinary
# VM user — is allowed to write into dist/.
userown() { chown "${SUDO_UID:-$(id -u)}:${SUDO_GID:-$(id -g)}" "$@"; }

[ "$(uname -s)" = "Darwin" ] || die "this script must run on macOS"

# --- self-elevate ------------------------------------------------------------
if [ "$(id -u)" != 0 ]; then
    echo "[*] Administrator rights are needed; re-running with sudo..."
    exec sudo "$0" "$@"
fi

# --- the target disk ----------------------------------------------------------
[ -e "/dev/${DISK}" ] || die "/dev/${DISK} does not exist. Attach the disk and check 'diskutil list'."
DISK_NUM="${DISK#disk}"
case "${DISK_NUM}" in
    *[!0-9]*|'') die "'${DISK}' is not a disk identifier (expected e.g. disk4)" ;;
esac

# --- appliance slice discovery ---------------------------------------------------
# macOS silently adds its own EFI and Apple_Boot partitions to physical
# disks when they are partitioned, so slice numbers are not stable.
# Identify the appliance partitions by their GPT type instead. diskutil
# prints known type GUIDs in human-readable form ("EFI") but unknown
# ones as the raw GUID, so both spellings are accepted.
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

# Boot slice on a freshly partitioned disk (no content on it yet): our
# ESP is the LARGEST ESP-typed slice — macOS enforces a minimum size on
# our ESP (growing it past the requested size) while its own auto-added
# EFI stays at 100 MB, so size separates ours reliably.
find_new_boot_slice() {
    local s bytes best
    BOOT_SLICE=""
    best=0
    for s in $(disk_slices); do
        is_esp_type "$(slice_guid "${s}")" || continue
        # Slice size from the "Disk Size:"/"Total Size:" line specifically
        # (unformatted vs FAT slices label it differently, and generic
        # byte-count matching trips over "Volume Total Space: 0 Bytes").
        bytes="$(diskutil info "/dev/${s}" 2>/dev/null |
            sed -nE 's/^ *(Disk|Total) Size:.*\(([0-9]*) Bytes\).*/\2/p' | head -1)"
        if [ -n "${bytes}" ] && [ "${bytes}" -gt "${best}" ]; then
            best="${bytes}"
            BOOT_SLICE="${s}"
        fi
    done
    [ -n "${BOOT_SLICE}" ] || return 1
}

# Boot slice on an already-installed disk: the ESP that actually carries
# the appliance (kernel or containux.conf). Blank ESPs that macOS
# reserved for itself fail the content probe and drop out.
find_existing_boot_slice() {
    local s m tmp made
    BOOT_SLICE=""
    for s in $(disk_slices); do
        is_esp_type "$(slice_guid "${s}")" || continue
        m="$(diskutil info "/dev/${s}" 2>/dev/null | sed -n 's/^ *Mount Point: *//p')"
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

BOOT_DISK="$(diskutil info / 2>/dev/null | sed -n 's/.*Part of Whole: *//p')"
if [ "${DISK}" = "${BOOT_DISK}" ]; then
    die "refusing to touch the boot disk"
fi

INFO="$(diskutil info "${DISK}")"
if echo "${INFO}" | grep -q "^ *Internal: *Yes"; then
    die "${DISK} is an internal disk; attach the appliance drive externally"
fi

# --- the appliance kernel -------------------------------------------------------
find_bzimage() {
    local p
    for p in "${BZIMAGE_OPT}" "${DIST_DIR}/bzImage" \
             "${ROOT_DIR}"/buildroot-*/output/images/bzImage; do
        if [ -n "${p}" ] && [ -f "${p}" ]; then
            echo "${p}"
            return 0
        fi
    done
    return 1
}

# Rebuild when any appliance source is newer than the built kernel.
need_build() {
    local b src
    if [ "${FORCE_BUILD}" = 1 ]; then return 0; fi
    if [ "${SKIP_BUILD}" = 1 ]; then return 1; fi
    b="$(find_bzimage)" || return 0        # nothing built yet
    for src in board/containux/linux.config \
               configs/containux_defconfig \
               board/containux/busybox.config \
               board/containux/post-build.sh \
               board/containux/rootfs-overlay/init \
               board/containux/rootfs-overlay/usr/local/bin/containux-tui.sh \
               board/containux/rootfs-overlay/usr/local/bin/usb-hotplug.sh \
               board/containux/rootfs-overlay/etc/modprobe.d/containux.conf \
               board/containux/rootfs-overlay/etc/udev/rules.d/99-containux-usb.rules; do
        if [ -e "${ROOT_DIR}/${src}" ] && [ "${ROOT_DIR}/${src}" -nt "${b}" ]; then
            return 0
        fi
    done
    return 1
}

# Build inside the Linux VM. Buildroot cannot run on macOS, and it must
# not build on a Mac-share mount (build.sh preflight) — OrbStack exposes
# the Mac filesystem inside the VM, so the tree is rsynced into the VM's
# own filesystem, built there, and the kernel copied back.
build_in_vm() {
    command -v orb >/dev/null 2>&1 || die \
"no up-to-date bzImage exists and the OrbStack 'orb' CLI was not found.
    Build inside your Linux VM first:
        rsync -a <this-repo>/ ~/containux/ && cd ~/containux && ./build.sh
    then copy the kernel to ${DIST_DIR}/bzImage (or pass --bzImage)."
    note "Locating the Mac repository inside the Linux VM..."
    SRC="$(orb bash -c "for p in '${ROOT_DIR}' '/mnt/mac${ROOT_DIR}'; do [ -d \"\$p\" ] && echo \"\$p\" && exit 0; done; exit 1" 2>/dev/null || true)"
    [ -n "${SRC}" ] || die \
"the Linux VM cannot see ${ROOT_DIR}.
    Make sure your OrbStack machine is running, or build manually inside
    your VM and pass --bzImage."
    note "Syncing the project into the VM (~/containux, excluding output)..."
    orb bash -c "rsync -a --delete --exclude .git --exclude output '${SRC}/' ~/containux/"
    note "Building Containux inside the VM (first build can take 30-60 min)..."
    orb bash -c "cd ~/containux && ./build.sh"
    note "Copying bzImage back to the Mac..."
    mkdir -p "${DIST_DIR}"
    userown "${DIST_DIR}"
    orb bash -c "set -- ~/containux/buildroot-*/output/images/bzImage; [ -f \"\$1\" ] || { echo 'bzImage not found after build' >&2; exit 1; }; cp \"\$1\" '${DIST_DIR}/bzImage'"
    [ -s "${DIST_DIR}/bzImage" ] || die "the build did not produce ${DIST_DIR}/bzImage"
    userown "${DIST_DIR}/bzImage"
}

BZIMAGE="$(find_bzimage || true)"
if [ -z "${BZIMAGE}" ]; then
    note "No appliance kernel found — building inside the Linux VM."
    build_in_vm
    BZIMAGE="${DIST_DIR}/bzImage"
elif need_build; then
    note "Appliance sources changed since the kernel was last built — rebuilding."
    build_in_vm
    BZIMAGE="${DIST_DIR}/bzImage"
fi
[ -f "${BZIMAGE}" ] || die "bzImage missing at ${BZIMAGE}"

KDESC="$(file -b "${BZIMAGE}")"
case "${KDESC}" in
    *"Linux kernel x86 boot executable bzImage"*) ;;
    *) die "${BZIMAGE} is not an x86_64 bzImage (file says: ${KDESC})" ;;
esac

# Grow the boot partition if the unified kernel needs more than 100 MiB.
BZ_MB=$(( ($(stat -f%z "${BZIMAGE}") + 1048575) / 1048576 ))
if [ "${BZ_MB}" -gt $((BOOT_MB - 8)) ]; then
    note "Kernel image is ${BZ_MB} MiB; growing the boot partition to $((BZ_MB * 2)) MiB."
    BOOT_MB=$((BZ_MB * 2))
fi

# --- update-only mode: refresh an installed disk without touching Windows ----
if [ "${UPDATE_ONLY}" = 1 ]; then
    if ! find_existing_boot_slice; then
        die "no Containux boot partition found on ${DISK} — this disk does not look installed (run without --update-only to install from scratch)"
    fi
    if ! find_guest_slice; then
        die "no Linux-typed guest partition found on ${DISK}"
    fi
    note "Update mode — boot partition: /dev/${BOOT_SLICE}, guest partition /dev/${GUEST_SLICE} is left untouched"
else
# --- confirmation ------------------------------------------------------------------
MODEL="$(echo "${INFO}" | sed -n 's/^ *Device \/ Media Name: *//p')"
SIZE="$(echo "${INFO}"   | sed -n 's/^ *Disk Size: *//p' | cut -d'(' -f1)"
echo "==================================================================="
echo " About to DESTROY ALL DATA on ${DISK} (${SIZE}):"
echo "   ${MODEL}"
echo ""
echo " A fresh Containux GPT will be written:"
echo "   boot slice  ${BOOT_MB} MiB  EFI System Partition (FAT32: kernel + containux.conf)"
echo "   guest slice rest       raw Linux partition (Windows XP will live here)"
echo " (macOS may add small EFI/Apple_Boot slices of its own; the appliance"
echo "  finds its partitions by GPT type GUID, so their numbers do not matter.)"
echo "==================================================================="
if [ "${ASSUME_YES}" != 1 ]; then
    read -r -p "Type 'yes' to continue: " ANSWER
    [ "${ANSWER}" = "yes" ] || die "aborted"
fi

# --- partition -----------------------------------------------------------------------
# Everything goes through diskutil: on modern macOS the `gpt` tool is not
# permitted to write partition tables even as root, while diskutil talks
# to diskmanagementd and does the same job through the sanctioned path.
# Explicit GPT type UUIDs in %...% imply "no filesystem" (diskutil(8)),
# so both slices stay raw and the p1 FAT32 is created afterwards.
note "Unmounting everything on ${DISK}..."
if ! diskutil unmountDisk "${DISK}" >/dev/null 2>&1; then
    echo "[!] ERROR: could not unmount ${DISK}. Currently mounted:"
    diskutil list "${DISK}"
    die "close any program using the disk (Finder, Spotlight, Time Machine?) and retry"
fi

note "Partitioning ${DISK} (GPT: ${BOOT_MB} MiB ESP + raw guest partition)..."
diskutil partitionDisk "${DISK}" GPT \
    %C12A7328-F81F-11D2-BA4B-00A0C93EC93B% boot "${BOOT_MB}M" \
    %0FC63DAF-8483-4772-8E79-3D69D210F577% guest R \
    || die "partitionDisk failed (is the disk in use? unplug/replug and retry)"

# Give diskarbitration a moment to register the new slices, then locate
# them by type (slice numbers can shift when macOS adds its own).
i=0
until find_new_boot_slice && find_guest_slice; do
    i=$((i + 1))
    if [ "${i}" -gt 20 ]; then
        die "appliance partitions did not appear on ${DISK}"
    fi
    sleep 0.5
done
note "Boot partition: /dev/${BOOT_SLICE}  guest partition: /dev/${GUEST_SLICE}"

note "Formatting /dev/${BOOT_SLICE} as FAT32 (label CONTAINUX)..."
newfs_msdos -F 32 -v CONTAINUX "/dev/${BOOT_SLICE}" >/dev/null \
    || die "newfs_msdos failed on /dev/${BOOT_SLICE}"
fi

# --- install the appliance (both modes: boot slice only; guest untouched) ----
note "Installing the appliance kernel (EFI stub)..."
note "Installing the appliance kernel (EFI stub)..."
MNT="$(diskutil info "/dev/${BOOT_SLICE}" 2>/dev/null | sed -n 's/^ *Mount Point: *//p')"
MADE_MNT=""
if [ -z "${MNT}" ] || [ ! -d "${MNT}" ]; then
    MADE_MNT="$(mktemp -d /tmp/containux-boot.XXXXXX)"
    diskutil mount -mountPoint "${MADE_MNT}" "/dev/${BOOT_SLICE}" >/dev/null \
        || die "could not mount /dev/${BOOT_SLICE}"
    MNT="${MADE_MNT}"
fi

mkdir -p "${MNT}/EFI/BOOT"
cp "${BZIMAGE}" "${MNT}/EFI/BOOT/BOOTX64.EFI"

# --- guest hardware identity (GUIDE.md §5.3) ---------------------------------------------
# The first-boot TUI normally derives MAC/UUID from the motherboard; here
# they are generated once on the Mac and pinned in containux.conf instead
# (init and the TUI reuse them verbatim on every later boot). dist/
# keeps the canonical copy so a re-install keeps the same identity and
# an already-installed Windows never sees "new hardware".
note "Writing containux.conf (os=${TARGET_OS}, graphics=${GRAPHICS}, audio=${AUDIO})..."
mkdir -p "${DIST_DIR}"
MAC=""; UUID=""; GPU_BDF=""; VERBOSE=""
if [ -f "${DIST_DIR}/containux.conf" ]; then
    # shellcheck disable=SC1091
    . "${DIST_DIR}/containux.conf"
fi
[ -n "${MAC}" ]  || MAC="52:54:00:$(openssl rand -hex 3 | sed -e 's/../&:/g' -e 's/:$//')"
[ -n "${UUID}" ] || UUID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
if [ -n "${GPU_BDF_OPT}" ]; then
    GPU_BDF="${GPU_BDF_OPT}"
fi
if [ "${VERBOSE_OPT}" = 1 ] || [ "${VERBOSE}" = "yes" ]; then
    VERBOSE="yes"
fi

CONF="# containux.conf - generated by installer/mac-setup-disk.sh
# Deterministic guest hardware identity (GUIDE.md §5.3)
TARGET_OS=\"${TARGET_OS}\"
GRAPHICS=\"${GRAPHICS}\"
AUDIO=\"${AUDIO}\"
MAC=\"${MAC}\"
UUID=\"${UUID}\"
GPU_BDF=\"${GPU_BDF}\"
VERBOSE=\"${VERBOSE}\"
"
printf '%s\n' "${CONF}" > "${DIST_DIR}/containux.conf"
printf '%s\n' "${CONF}" > "${MNT}/containux.conf"
userown "${DIST_DIR}/containux.conf"

sync
diskutil unmount "/dev/${BOOT_SLICE}" >/dev/null \
    || echo "[!] WARNING: could not unmount /dev/${BOOT_SLICE}"
[ -n "${MADE_MNT}" ] && rmdir "${MADE_MNT}" 2>/dev/null || true
diskutil unmountDisk "${DISK}" >/dev/null 2>&1 || true

echo ""
echo "[*] Done. The disk now looks like:"
diskutil list "${DISK}"

if [ "${UPDATE_ONLY}" = 1 ]; then
    cat <<EOF

==================================================================
 Containux updated in place: fresh kernel + containux.conf on
 /dev/${BOOT_SLICE}; the Windows install in /dev/${GUEST_SLICE} was
 not touched.

   graphics=${GRAPHICS}${GPU_BDF:+ (GPU_BDF=${GPU_BDF})}
   guest identity (MAC/UUID) unchanged.

 Optional sanity check on this Mac:
   installer/mac-verify.sh

 Then move the drive back: UEFI boot, Secure Boot OFF, and with
 --graphics vfio enable VT-d / IOMMU in the firmware and connect the
 monitor to the passed-through card.
==================================================================
EOF
else
    cat <<EOF

==================================================================
 Containux is installed. Next steps:

  1. Install Windows XP into the guest partition:
       installer/mac-install-windows.sh

  2. Verify the whole appliance chain on this Mac before pulling the
     drive (boots the real appliance against this disk):
       installer/mac-verify.sh

  3. Shut the computer down, move the drive back into the x86_64
     machine, make sure the firmware boots UEFI (Secure Boot OFF), and
     power on. It should go straight into Windows XP.
==================================================================
EOF
fi
