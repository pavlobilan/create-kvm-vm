# create-kvm-vm

Interactive script that creates a KVM/libvirt virtual machine on a Debian host (e.g. one installed with [kvm-host-iso](https://github.com/pavlobilan/kvm-host-iso)). The created VM appears in Cockpit (Virtual machines).

## Quick start

Download the script and run it as root:

```bash
curl -fsSL https://raw.githubusercontent.com/pavlobilan/create-kvm-vm/main/new-vm.sh -o /tmp/new-vm.sh && sudo bash /tmp/new-vm.sh
```

Or run without saving to disk (answers are read from the terminal):

```bash
curl -fsSL https://raw.githubusercontent.com/pavlobilan/create-kvm-vm/main/new-vm.sh | sudo bash
```

At the end the script asks whether to start the VM (Enter = yes).

To always run a reviewed version, replace `main` with a commit hash.

## new-vm.sh

### What it configures

- vCPU: asked at runtime, from 1 to the host's logical processor count (default 4, or the host maximum if lower); CPU model `host-passthrough`
- Memory: static, size asked at runtime (default 8 GB, limited to host memory)
- Disks: number and sizes asked at runtime (default 2 disks: 60 GB and 200 GB), all thin-provisioned qcow2 with `discard=unmap`
- Guest OS: Linux (virtio disks and network) or Windows (SATA disks, e1000e network, installs without extra drivers)
- Firmware: UEFI, machine type q35
- Secure Boot: asked at runtime, off by default; when enabled, Microsoft keys are enrolled (Windows and Linux with shim)
- Virtual TPM 2.0: asked at runtime, off by default (installs `swtpm` if missing)
- Network: a host bridge (`br0` by default) or a libvirt network, or not connected
- Static MAC address from the libvirt range `52:54:00:xx:xx:xx`, unique among VMs on the host
- Autostart with the host: off
- Host shutdown: guests are shut down, not saved, and not restarted on boot (`ON_SHUTDOWN=shutdown`, `ON_BOOT=ignore` in `/etc/default/libvirt-guests`); this is a host-wide setting, asked only if it differs
- Installation ISO (for Linux guests a menu, for Windows a file path):
  - **Debian, unattended install**: an image built from the latest Debian netinst with a preseed, as in [kvm-host-iso](https://github.com/pavlobilan/kvm-host-iso) but without the KVM host part. The installer asks only the hostname, domain, user name and password. The first disk of the VM becomes the system disk (LVM on the whole disk), the other disks are left untouched. Installed: SSH server, sudo (root login disabled), `qemu-guest-agent`, login on the serial console, time zone Europe/Kyiv, full upgrade. The image is built once and reused; it is rebuilt only for a new Debian version or new settings. The ISO boots after the disks, so the installed system starts even with the ISO attached; the boot menu waits for Enter, so the installation never starts by itself
  - **Debian, standard installer**: the latest Debian netinst as it is
  - **Another ISO file** (Tab completes paths), attached as the first boot device
  - The Debian netinst is downloaded from `cdimage.debian.org` to `/var/lib/libvirt/images/iso`; if the current image is already there and its SHA256 matches, it is reused; without internet access the newest image already in the folder is used
- Serial console (`virsh console <VMName>`), VNC console for Cockpit, QEMU guest agent channel
- Optional start of the VM after creation (default: yes)

Nested virtualization works when it is enabled in the host's `kvm_intel`/`kvm_amd` module; the summary shows whether it is.

### Folder layout

```text
<Folder>/<VMName>/
├── <VMName>.qcow2
├── <VMName>-Data.qcow2
└── <VMName>-Data2.qcow2 ...
```

The folder is asked at runtime; the default (`/var/lib/libvirt/images`) is pre-filled and can be edited (Tab completes paths). If the folder already contains a subfolder with the VM name, the script asks for another folder. The UEFI variables (and TPM state, if enabled) are kept by libvirt in `/var/lib/libvirt/qemu/nvram` and `/var/lib/libvirt/swtpm`.

If creating the VM fails, the created disks and the VM folder are removed.

### Requirements

- Debian 12 or 13 with libvirt and QEMU/KVM
- Packages `virtinst`, `qemu-utils`, `ovmf`; `curl` for downloading Debian, `xorriso` and `cpio` for the unattended install image (the script offers to install missing ones)
- Run as root

### Defaults

Edit the variables at the top of the script to change defaults:

| Variable | Default | Meaning |
|---|---|---|
| `DEFAULT_CPU` | `4` | vCPU count |
| `DEFAULT_MEM_GB` | `8` | memory, GB |
| `DEFAULT_DISKS` | `2` | number of disks |
| `DEFAULT_SIZES_GB` | `(60 200)` | sizes of disk 1, 2, ..., GB |
| `EXTRA_DISK_GB` | `100` | size of further disks, GB |
| `DEFAULT_ROOT` | `/var/lib/libvirt/images` | folder for virtual machines |
| `DEFAULT_BRIDGE` | `br0` | network selected by default |
| `ISO_DIR` | `/var/lib/libvirt/images/iso` | folder for the downloaded and prepared Debian images |
| `DEBIAN_URL` | `https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/` | where the latest Debian netinst is looked up |

## License

MIT
