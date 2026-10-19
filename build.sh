#!/bin/bash
set -e

# Configuration
BUILDROOT_VERSION="2024.02.1"
BUILDROOT_TAR="buildroot-${BUILDROOT_VERSION}.tar.gz"
BUILDROOT_DIR="buildroot-${BUILDROOT_VERSION}"
BUILDROOT_URL="https://buildroot.org/downloads/${BUILDROOT_TAR}"
EXTERNAL_DIR="$(pwd)"
OUTPUT_DIR="${EXTERNAL_DIR}/output"

echo "========================================"
echo "    Containux Build System Initiated    "
echo "========================================"

# 0. Pre-flight: Buildroot needs a real Linux filesystem.
#    The build tree must NOT sit on a macOS/Windows share (OrbStack's Mac
#    folder, VMware/Parallels shared folders, WSL /mnt/c, ...). Those
#    filesystems are case-insensitive and do not implement every Linux
#    syscall (hardlinks, FIFOs, chmod variants...), so the build dies with
#    endless "Function not implemented" and case-collision errors.
PREFLIGHT_DIR=".containux-preflight"
PREFLIGHT_OK=1
rm -rf "${PREFLIGHT_DIR}"
mkdir -p "${PREFLIGHT_DIR}"
touch "${PREFLIGHT_DIR}/CASE-FILE"
rm -f "${PREFLIGHT_DIR}/case-file"
[ -e "${PREFLIGHT_DIR}/CASE-FILE" ] || PREFLIGHT_OK=0
touch "${PREFLIGHT_DIR}/data"
ln "${PREFLIGHT_DIR}/data" "${PREFLIGHT_DIR}/hardlink" 2>/dev/null || PREFLIGHT_OK=0
ln -s data "${PREFLIGHT_DIR}/symlink" 2>/dev/null || PREFLIGHT_OK=0
mkfifo "${PREFLIGHT_DIR}/fifo" 2>/dev/null || PREFLIGHT_OK=0
rm -rf "${PREFLIGHT_DIR}"
if [ "${PREFLIGHT_OK}" != 1 ]; then
    echo "[!] ERROR: this build tree is on a filesystem that cannot host a"
    echo "    Buildroot build (case-insensitive and/or missing hardlink,"
    echo "    symlink or FIFO support)."
    echo ""
    echo "    If you are inside a VM (e.g. OrbStack), copy the project to the"
    echo "    VM's own Linux filesystem and rebuild from there:"
    echo "        rsync -a <path-to-mac-share>/Containux/ ~/containux/"
    echo "        cd ~/containux && ./build.sh"
    exit 1
fi

# 1. Host build prerequisites.
#    Buildroot requires a full set of host tools; minimal distro images
#    (e.g. OrbStack's 'ubuntu') ship almost none of them. Anything missing
#    is auto-installed via apt-get when it is available.
REQUIRED_TOOLS="wget make gcc g++ patch gzip bzip2 xz perl tar cpio unzip rsync bc bison flex file find python3"
APT_PACKAGES="build-essential wget cpio unzip rsync bc bison flex patch perl file xz-utils libssl-dev libncurses-dev libelf-dev python3"

MISSING=""
for tool in ${REQUIRED_TOOLS}; do
    command -v "${tool}" >/dev/null 2>&1 || MISSING="${MISSING} ${tool}"
done

if [ -n "${MISSING}" ]; then
    echo "[*] Missing host build tools:${MISSING}"
    if ! command -v apt-get >/dev/null 2>&1; then
        echo "[!] ERROR: apt-get is not available on this system."
        echo "    Install the equivalent packages for:${MISSING}"
        echo "    manually and re-run this script."
        exit 1
    fi
    echo "[*] Installing build prerequisites via apt-get..."
    SUDO=""
    if [ "$(id -u)" != "0" ]; then
        SUDO="sudo"
    fi
    ${SUDO} apt-get update
    ${SUDO} apt-get install -y ${APT_PACKAGES}
    for tool in ${REQUIRED_TOOLS}; do
        command -v "${tool}" >/dev/null 2>&1 || {
            echo "[!] ERROR: '${tool}' is still not installed; aborting."
            exit 1
        }
    done
else
    echo "[*] Host build prerequisites satisfied."
fi

# 1b. Host compiler compatibility.
#     Buildroot 2024.02's host tools predate GCC 15, which made C23
#     (-std=gnu23) the default: their bundled gnulib then selects
#     [[__nodiscard__]] attribute syntax it cannot place correctly, and
#     compiles fail (e.g. host-m4: "'nodiscard' attribute ignored"). When
#     the default compiler is too new, pin Buildroot's HOSTCC/HOSTCXX to
#     the newest older GCC available, installing gcc-13 if necessary.
HOST_GCC_MAJOR=$(gcc -dumpversion 2>/dev/null | cut -d. -f1)
if [[ "${HOST_GCC_MAJOR}" =~ ^[0-9]+$ ]] && (( HOST_GCC_MAJOR >= 15 )); then
    PIN_GCC=""
    for v in 13 14 12; do
        if command -v "gcc-${v}" >/dev/null 2>&1; then
            PIN_GCC="${v}"
            break
        fi
    done
    if [ -z "${PIN_GCC}" ] && command -v apt-get >/dev/null 2>&1; then
        echo "[*] Installing gcc-13/g++-13: host GCC ${HOST_GCC_MAJOR} is too new"
        echo "    for Buildroot ${BUILDROOT_VERSION}'s host tools (gnulib vs. C23)."
        SUDO=""
        if [ "$(id -u)" != "0" ]; then
            SUDO="sudo"
        fi
        ${SUDO} apt-get install -y gcc-13 g++-13
        command -v gcc-13 >/dev/null 2>&1 && PIN_GCC=13
    fi
    if [ -n "${PIN_GCC}" ]; then
        export HOSTCC="gcc-${PIN_GCC}"
        export HOSTCXX="g++-${PIN_GCC}"
        echo "[*] Buildroot host compiler pinned to ${HOSTCC}/${HOSTCXX}."
    else
        echo "[!] WARNING: no older host GCC is available; host tool builds"
        echo "    may fail against gcc ${HOST_GCC_MAJOR}. Install gcc-13."
    fi
fi

# 2. Download and extract Buildroot, verifying integrity.
#    A stale or corrupted tree (e.g. copied from a failed build attempt on
#    a macOS share) is detected and re-extracted instead of producing
#    cryptic failures such as "No rule to make target 'containux_defconfig'".
buildroot_tree_intact() {
    [ -f "${BUILDROOT_DIR}/Makefile" ] &&
    [ -f "${BUILDROOT_DIR}/Config.in" ] &&
    [ -f "${BUILDROOT_DIR}/package/Makefile.in" ] &&
    [ -f "${BUILDROOT_DIR}/support/kconfig/Makefile" ] &&
    grep -q '%_defconfig' "${BUILDROOT_DIR}/Makefile"
}

tarball_intact() {
    [ -f "${BUILDROOT_TAR}" ] && gzip -t "${BUILDROOT_TAR}" 2>/dev/null
}

if buildroot_tree_intact; then
    echo "[*] Buildroot ${BUILDROOT_VERSION} already present and intact."
else
    if [ -d "${BUILDROOT_DIR}" ]; then
        echo "[*] Existing Buildroot tree is incomplete or corrupted; discarding it."
        rm -rf "${BUILDROOT_DIR}"
    fi
    if ! tarball_intact; then
        echo "[*] Downloading Buildroot LTS ${BUILDROOT_VERSION}..."
        rm -f "${BUILDROOT_TAR}"
        wget -q "${BUILDROOT_URL}"
    else
        echo "[*] Re-using cached ${BUILDROOT_TAR}."
    fi
    echo "[*] Extracting Buildroot..."
    if ! tar -xf "${BUILDROOT_TAR}" 2>/dev/null; then
        # GNU tar 1.35 extracts via the openat2() syscall, which sandboxed
        # VM environments (notably OrbStack machines) do not implement —
        # every file fails with "Cannot open: Function not implemented".
        # Python's tarfile module performs the extraction with plain
        # open(2)/mkdir(2) and works everywhere.
        echo "[*] GNU tar failed in this environment (blocked syscall);"
        echo "    falling back to python3-based extraction..."
        rm -rf "${BUILDROOT_DIR}"
        python3 - "${BUILDROOT_TAR}" <<'PYEOF'
import sys, tarfile

with tarfile.open(sys.argv[1]) as tar:
    try:
        # The "tar" filter mimics classic GNU tar extraction semantics
        # (e.g. absolute symlink targets like init -> /sbin/init are kept).
        tar.extractall(".", filter="tar")
    except TypeError:
        # Python < 3.12 has no extraction filters
        tar.extractall(".")
PYEOF
    fi
    buildroot_tree_intact || {
        echo "[!] ERROR: Buildroot extraction failed the integrity check."
        exit 1
    }
fi

# 3. Ensure the mandatory external tree files exist
echo "[*] Verifying BR2_EXTERNAL structure..."
touch "${EXTERNAL_DIR}/Config.in"
touch "${EXTERNAL_DIR}/external.mk"
if [ ! -f "${EXTERNAL_DIR}/external.desc" ]; then
    echo "name: CONTAINUX" > "${EXTERNAL_DIR}/external.desc"
    echo "desc: Containux minimal hypervisor" >> "${EXTERNAL_DIR}/external.desc"
fi
for f in configs/containux_defconfig \
         board/containux/linux.config \
         board/containux/busybox.config \
         board/containux/post-build.sh; do
    if [ ! -f "${EXTERNAL_DIR}/${f}" ]; then
        echo "[!] ERROR: required project file is missing: ${f}"
        echo "    The project tree appears incomplete (bad copy?); re-copy the"
        echo "    full Containux repository and try again."
        exit 1
    fi
done

# 4. Apply the Containux configuration
echo "[*] Applying containux_defconfig..."
cd "${BUILDROOT_DIR}"
make BR2_EXTERNAL="${EXTERNAL_DIR}" containux_defconfig

# 5. Compile the system
# Calculate available CPU cores for parallel build (works on macOS and Linux)
CORES=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 4)
echo "[*] Compiling Containux using ${CORES} threads. This may take a while..."

# Buildroot handles the cross-compilation toolchain, kernel, and rootfs automatically
make -j"${CORES}"

echo "========================================"
echo "              BUILD COMPLETE            "
echo "========================================"
echo "Your artifacts are located in:"
echo "  ${BUILDROOT_DIR}/output/images/"
echo ""
echo "Files of interest:"
echo "  bzImage        -> The minimal Linux Kernel (with initramfs linked in)"
echo "  rootfs.cpio.gz -> The Containux Initramfs (OS Payload)"
echo ""
echo "Next step: Format your boot partition as FAT32, copy bzImage there,"
echo "and configure your bootloader (e.g., systemd-boot or syslinux) to"
echo "boot it with the following kernel command line:"
echo "  quiet loglevel=0 rd.systemd.show_status=false vt.global_cursor_default=0 console=tty3"
