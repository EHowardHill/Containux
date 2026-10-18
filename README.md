# Containux

**The invisible hypervisor for legacy operating systems.**

Containux is a hyper-minimal, Buildroot-based Linux appliance designed to act as a transparent translation layer between modern hardware and legacy operating systems (like Windows XP, Windows Vista, and Windows 7).

By booting silently from an `initramfs` and immediately launching a highly optimized QEMU/KVM environment, Containux creates the illusion that the legacy OS is running bare-metal on your modern system. It captures hardware states, dynamically maps USB devices, and provides near-native storage speeds, all while remaining completely invisible to the end user.

---

## ✨ Features

* **Absolute Invisibility:** No boot text, no host logos, no window managers. Containux boots silently into the guest OS.
* **Native Power States:** When the guest OS restarts, the virtual machine restarts. When the guest OS shuts down, the physical host machine completely powers off.
* **Blind USB Passthrough:** Plug and play works exactly as expected. Physical USB devices (mice, keyboards, webcams, flash drives) are dynamically mapped to the guest's emulated EHCI controller the second they are plugged into the physical machine.
* **Raw Storage Access:** Guest storage is mapped directly to a raw physical partition via QEMU's legacy IDE emulation, granting near-native NVMe/SATA speeds without requiring legacy OS drivers for modern PCIe controllers.
* **Maximized Resources:** The entire host OS runs from an `initramfs` locked to exactly 256 MB of RAM. The rest of your system's physical memory is pre-allocated directly to the guest.
* **Deterministic Hardware UUIDs:** Prevents Windows Activation from breaking by generating and locking the guest's virtual MAC address and SMBIOS UUID to your physical motherboard.

## 🏗️ Architecture

Containux is designed around a strict two-partition layout:

1. **Host Partition (100MB FAT32):** Contains the bootloader, the unified kernel + `initramfs`, and the `containux.conf` state file.
2. **Guest Partition (Raw Block):** The remaining drive space, passed directly to QEMU.

Because the host system runs entirely in memory (RAM disk), it causes zero disk I/O interference with the guest OS. QEMU is executed with strict memory overcommit rules disabled (`vm.overcommit_memory=2`) to prevent host kernel panics during heavy guest workloads.

## 🚀 Installation & First Boot

Once Containux is flashed to a physical drive, it manages the entire setup process automatically.

1. **The Empty State:** On the very first boot, Containux checks the guest partition. If it is entirely blank, it launches a minimalist Text User Interface (TUI).
2. **Configuration:** The TUI allows you to configure period-accurate hardware settings for your target OS:
* **Target OS:** Windows XP, Vista, or 7.
* **Graphics:** Optimized 2D Virtualization (`qxl`) or raw PCIe GPU Passthrough (`vfio-pci`) for advanced users.
* **Audio:** AC97 (XP) or Intel HDA (Vista/7).


3. **Media Insertion:** Insert your original OS installation CD/DVD or a bootable USB drive. Containux will map the installation media to the guest and boot from it.
4. **The Native Experience:** Once the OS is installed and the installation media is removed, Containux will never show the TUI again. Turning on the computer will boot straight into Windows.

## 🔌 Networking & Connectivity

Containux exposes the guest directly to your local network using a transparent `macvtap` bridge. From the perspective of your router and the guest OS, the virtual machine is a physical device plugged directly into your network switch.

⚠️ **SECURITY WARNING:** Containux places legacy operating systems directly onto your network. Windows XP and Windows Vista are unsupported and highly vulnerable to network-level exploits. It is strongly recommended to use a hardware firewall or VLAN segregation if you intend to connect a Containux system to the internet.

## 🛠️ Technical Notes & Edge Cases Handled

* **Input Trap Mitigation:** During the initial OS installation, USB blind passthrough is temporarily bypassed. Keyboards and mice are routed via `evdev` to an emulated PS/2 controller to guarantee input works before Windows installs generic USB/EHCI drivers.
* **Sleep/Suspend Disabled:** Because passing raw block devices and handling blind USB hotplugging is highly unstable during an ACPI S3 Suspend, the virtual motherboard explicitly disables S3 Sleep states. The guest OS will dynamically grey out "Sleep" and only offer "Hibernate" or "Shut Down".

## File Guide ##

```
containux-project/
├── build.sh                        # The master build script (detailed below)
├── external.desc                   # Defines the BR2_EXTERNAL tree name
├── Config.in                       # (Empty file) Required by Buildroot external tree
├── external.mk                     # (Empty file) Required by Buildroot external tree
├── configs/
│   └── containux_defconfig         # Master Buildroot configuration file
└── board/
    └── containux/
        ├── linux.config            # Minimal host kernel configuration
        ├── busybox.config          # Minimal busybox configuration
        ├── post-build.sh           # Script to run before packaging (sets file permissions)
        └── rootfs-overlay/         # Files copied directly into the host OS root filesystem
            ├── init                # The master custom boot script (Replaces systemd/sysvinit)
            ├── etc/
            │   ├── modprobe.d/
            │   │   └── containux.conf       # Blacklists host USB drivers (usbhid, uvcvideo)
            │   └── udev/rules.d/
            │       └── 99-containux-usb.rules # Udev rules mapping USB to QEMU QMP
            └── usr/local/bin/
                ├── containux-tui.sh   # The dialog-based First-Boot interface
                └── usb-hotplug.sh     # Script that sends JSON payloads via socat to QEMU
```

---

*Built with [Buildroot](https://buildroot.org/). Powered by [QEMU/KVM](https://www.qemu.org/).*