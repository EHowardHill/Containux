# Containux Engineering & Implementation Guide

**Document Objective:** Provide an exhaustive, production-ready implementation architecture for "Containux" — a zero-latency, transparent, Buildroot-based hypervisor appliance. This document is intended for the lead software engineer to execute without ambiguity.

---

## 1. System Architecture & Base OS Profile

Containux will be built using **Buildroot** to generate a minimal, single-purpose Linux environment.

* **Boot & Storage Strategy:** The host OS will boot via a unified kernel image and run **entirely from an `initramfs**`. This eliminates host disk I/O interference, frees up the NVMe controller for near-native guest access, and ensures maximum stability.
* **Partitioning:** The primary drive (e.g., `/dev/nvme0n1`) will have two partitions:
* `/dev/nvme0n1p1` (FAT32, 100MB): Contains the bootloader (syslinux or systemd-boot), the kernel + initramfs, and a configuration file (`containux.conf`).
* `/dev/nvme0n1p2` (Raw, remaining space): The dedicated guest partition.


* **Memory Allocation:** The host system is strictly capped. Containux will reserve exactly **256 MB** of RAM for the Linux kernel, `udev`, and QEMU overhead. The remainder of the physical system memory (`TOTAL_RAM - 256 MB`) is dynamically calculated and allocated to the guest virtual machine.
* **Silent Boot Implementation:** To achieve absolute invisibility, the Linux kernel must be compiled with the quietest possible parameters.
* **Kernel cmdline:** `quiet loglevel=0 rd.systemd.show_status=false vt.global_cursor_default=0 console=tty3`
* **Buildroot config:** Disable `getty` on `tty1` in `/etc/inittab`. The custom init script will take over `tty1` immediately without printing standard Linux initialization text.



---

## 2. State Detection & First-Boot TUI

The system must present a minimalist Text User Interface (TUI) via the `dialog` package *only* if the system is completely unconfigured/empty.

### 2.1 State Detection Logic

The primary init script (`/init` in the initramfs) will run the `blkid` utility against `/dev/nvme0n1p2`.

* If `blkid` returns a filesystem UUID/signature, the system is deemed **"Installed"** and immediately proceeds to silent QEMU boot.
* If `blkid` returns nothing (raw, zeroed block device), the system is deemed **"Empty"** and triggers the First-Boot TUI.

### 2.2 TUI Workflow & Configuration

The TUI will prompt the user for period-accurate hardware configurations to maximize compatibility.

1. **Target OS Selection:** Prompts for Windows XP, Windows Vista, or Windows 7.
2. **Graphics Mode:**
* *Default (Virtual):* `qxl` (Highly optimized 2D rendering).
* *Expert (VFIO):* Instructs the host to bind the PCIe GPU to `vfio-pci` for raw passthrough.


3. **Audio Emulation Target:**
* If XP is selected: Defaults to `ac97`.
* If Vista/7 is selected: Defaults to `hda` (Intel High Definition Audio).



**Persistence:** Once selected, the script mounts `/dev/nvme0n1p1` as read-write, saves these variables to `containux.conf`, remounts read-only, and initializes QEMU.

---

## 3. QEMU Execution & Hardware Mapping

The core of Containux is the QEMU invocation. Below is the engineered parameter set that the initialization script must construct based on the configuration.

### 3.1 Storage & Media Booting

* **Guest Drive:** Passed as raw IDE to guarantee legacy OS compatibility while maintaining NVMe speeds.
`-drive file=/dev/nvme0n1p2,format=raw,if=ide,cache=none,aio=native`
* **Physical Optical Media:** If `/dev/sr0` is detected at boot, append:
`-drive file=/dev/sr0,media=cdrom,if=ide`
* **Bootable USB Install Media:** USB flash drives present at boot must be mapped as block devices (rather than hotplugged via EHCI later) so the QEMU BIOS can boot from them.
`-drive file=/dev/sda,format=raw,if=none,id=usbdrive -device usb-storage,drive=usbdrive`

### 3.2 Networking (Transparent Bridge)

To expose the guest to the modern network exactly as a physical machine would be, use a `macvtap` interface in bridge mode attached to the host's physical NIC.

* Setup script creates the tap: `ip link add link eth0 name macvtap0 type macvtap mode bridge`
* QEMU parameter: `-netdev tap,fd=3,id=hostnet0 -device e1000,netdev=hostnet0,mac=<generated_mac>`

### 3.3 Power States & Lifecycle

* **Reboot:** By default, a guest reboot command signals QEMU's virtual motherboard to reset. QEMU handles this internally without exiting to the host.
* **Shutdown:** When the guest powers off, QEMU safely terminates and exits. The Buildroot init script will catch the QEMU process exit code (or completion) and immediately execute `/sbin/poweroff -f` to shut down the physical hardware.
* **Sleep/Suspend Prevention:** Because ACPI S3 suspend behavior is unstable when passing raw devices, we must forcefully strip S3 capabilities from the virtual motherboard.
QEMU parameter: `-global PIIX4_PM.disable_s3=1` (Guest OS will gray out "Sleep" and only offer Hibernate/Shutdown).

### 3.4 Audio Output

The guest's emulated sound card (§2.2) must reach the appliance's *own physical* audio output — never a sound server, and never a remote stream. The init script therefore launches the guest QEMU with an explicit ALSA backend:

`-audiodev alsa,id=snd0 -device <AC97|intel-hda + hda-duplex>,audiodev=snd0`

* The appliance kernel drives the physical sound card directly: both AC97 (Intel 8x0) and Intel HDA drivers are built in, covering XP-era hardware, every modern board, and the card the test harness emulates.
* The `audiodev=` property goes on the card device — for HDA that is the *codec* (`hda-duplex`), never the bus controller (`intel-hda`).
* Buildroot's stock QEMU recipe compiles *no* audio backend; the BR2_EXTERNAL tree overrides `package/qemu/qemu.mk` to build QEMU with `--audio-drv-list=alsa` against `alsa-lib`.
* If the audio path is unusable (QEMU without ALSA, or no driven sound device), the init script retries with `-audiodev none`: the guest card stays visible to Windows but silent. A machine must always boot, sound or no sound — exactly like real hardware with broken speakers.

**Test harness note:** `tests/run-test.sh` and `installer/mac-verify.sh` emulate the appliance's sound card on the outer QEMU and route it to the host's audio backend (CoreAudio on macOS, PulseAudio on Linux), so nested guest audio is testable end-to-end without physical hardware.

---

## 4. Dynamic USB Passthrough Architecture (The "Blind" Strategy)

To make Containux feel native, *every* USB device (mice, keyboards, webcams, Bluetooth adapters) plugged into the physical machine must instantly appear in the guest OS via an emulated USB 2.0 (EHCI) controller.

### 4.1 QEMU Preparation

QEMU must be launched with an emulated EHCI bus and a QEMU Monitor Protocol (QMP) socket to receive hotplug commands from the host.

* `-device usb-ehci,id=ehci`
* `-qmp unix:/tmp/qmp.sock,server,nowait`

### 4.2 Udev to QMP Event Pipeline

We will use Buildroot's `eudev` to capture hardware events.

1. **The Udev Rule:** Create `/etc/udev/rules.d/99-containux-usb.rules`:
`ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", RUN+="/usr/local/bin/usb-hotplug.sh add %E{BUSNUM} %E{DEVNUM}"`
`ACTION=="remove", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", RUN+="/usr/local/bin/usb-hotplug.sh remove %E{BUSNUM} %E{DEVNUM}"`
2. **The Hotplug Script (`usb-hotplug.sh`):**
This script converts the udev event into a JSON payload and pushes it to QEMU via `socat`.
* *Add Command Payload:*
`{"execute": "device_add", "arguments": {"driver": "usb-host", "hostbus": "<BUSNUM>", "hostport": "<DEVNUM>", "id": "usb-<BUSNUM>-<DEVNUM>", "bus": "ehci.0"}}`
* *Remove Command Payload:*
`{"execute": "device_del", "arguments": {"id": "usb-<BUSNUM>-<DEVNUM>"}}`



*Note: This strictly passes the raw USB interface to the guest. The host Linux kernel must NOT load its own drivers (e.g., `usbhid`, `uvcvideo`) for these devices. The kernel should be compiled without these drivers, or they must be blacklisted in `modprobe.d`, ensuring the guest gets exclusive, uninhibited access to the hardware.*

---

## 5. Potential Pitfalls & Engineering Mitigations

**Pitfall 1: Input Trap During Initial OS Install**

* *Issue:* Before the OS is installed and before guest drivers are active, QEMU usually relies on SPICE or VNC for mouse/keyboard inputs. If we blindly pass the physical keyboard/mouse via USB EHCI, the Windows XP installer might lack the generic driver to recognize the passed-through controller.
* *Mitigation:* QEMU has built-in PS/2 emulation. The init script must detect if the system is booting from an installation media (CD/USB). If so, the script should *exclude* the primary keyboard and mouse from the blind USB passthrough and instead map them via Linux `evdev` to QEMU's emulated PS/2 ports (`-object input-linux,id=kbd,evdev=/dev/input/event0`). Once the OS is installed (no install media present), it reverts to pure blind USB passthrough.

**Pitfall 2: Host Out of Memory (OOM) Panics**

* *Issue:* If the host calculates `TOTAL_RAM - 256MB` and gives it to QEMU, sudden spikes in host filesystem cache (e.g., from `udev` or bridging) might trigger the Linux OOM Killer, terminating QEMU instantly.
* *Mitigation:* QEMU memory must be pre-allocated. Pass `-mem-prealloc` to QEMU. Additionally, configure the host's `sysctl` to disable memory overcommit (`vm.overcommit_memory=2`). This guarantees the guest RAM is locked, and the host will strictly operate within its 256MB boundary without panicking.

**Pitfall 3: Windows Activation & Hardware Changes**

* *Issue:* Windows XP/Vista triggers reactivation if the underlying hardware UUIDs or MAC addresses change between boots.
* *Mitigation:* The MAC address for the `e1000` NIC and the SMBIOS UUID for the QEMU machine must be deterministically generated on the first boot (derived from the physical motherboard's UUID) and saved in `containux.conf`. These must be passed to QEMU explicitly (`-uuid <saved_uuid>` and `mac=<saved_mac>`) on every boot to ensure the guest sees static hardware.