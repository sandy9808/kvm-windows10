# Windows 10 KVM VM (libvirt / virt)

Automated setup for a Windows 10 22H2 virtual machine on Linux using **KVM**, **libvirt**, and **virt-manager**. Includes NAT internet access, SSH port forwarding, and scripts to download Windows from [UUP Dump](https://uupdump.net/known.php?q=category:w10-22h2).

**Author:** [@sandy9808](https://github.com/sandy9808)

---

## Features

| Feature | Details |
|---------|---------|
| Hypervisor | KVM via libvirt (`qemu:///system`) |
| Windows source | UUP Dump — Windows 10 22H2 (19045.7417) Pro, en-us |
| CPU / RAM | 4 vCPUs, 8 GB RAM |
| Disk | **C:** 80 GB + **E:** 300 GB (separate qcow2 images, expandable online) |
| Display | SPICE + QXL (use `virt-viewer`), or **GPU passthrough** (physical NVIDIA/AMD) |
| Internet | User-mode NAT — works out of the box in the guest |
| SSH | Host port `2222` → guest port `22` (after OpenSSH is enabled) |

---

## Dependencies

Install on **Ubuntu / Debian** (or equivalent):

```bash
sudo apt-get update
sudo apt-get install -y \
  qemu-kvm libvirt-daemon-system libvirt-clients virt-manager virt-viewer \
  ovmf swtpm \
  aria2 cabextract wimtools chntpw genisoimage unzip curl
```

### Required groups

Your user must be in the `libvirt` and `kvm` groups:

```bash
sudo usermod -aG libvirt,kvm "$USER"
newgrp libvirt
```

Log out and back in if `virsh` reports permission errors.

### Verify KVM

```bash
egrep -c '(vmx|svm)' /proc/cpuinfo   # must be > 0
virsh list --all
systemctl is-active libvirtd          # active
```

---

## Quick start

```bash
git clone https://github.com/sandy9808/kvm-windows10.git
cd kvm-windows10

# 1) Download Windows 10 ISO from UUP Dump (~4 GB, takes time)
./scripts/download-windows.sh

# 2) Register the VM with libvirt
./scripts/setup-vm.sh

# 3) Start and open the installer
./scripts/start-vm.sh
virt-viewer win10-vm
```

Complete the Windows setup wizard in the viewer. Use **SATA** disk — the VM XML is already configured for Windows inbox drivers.

---

## GPU passthrough (VFIO)

Pass a physical NVIDIA or AMD GPU through to the Windows VM for native graphics performance (gaming, CUDA, DirectX, etc.). The discrete GPU is **reserved for the VM** via `vfio-pci` — the Linux host will not use it for its desktop while passthrough is configured.

### Requirements

- **IOMMU** enabled in BIOS (Intel VT-d or AMD-Vi)
- Kernel cmdline: `intel_iommu=on` or `amd_iommu=on` (and often `iommu=pt`)
- A **discrete GPU** bound to `vfio-pci` (not in use by the host desktop)
- **Dual-GPU** strongly recommended: Intel/AMD iGPU for the Linux host, discrete GPU for the VM

Verify IOMMU on the host:

```bash
cat /proc/cmdline | grep -E 'intel_iommu|amd_iommu'
ls /sys/kernel/iommu_groups/ | wc -l   # should be > 0
./scripts/detect-gpu.sh
```

### Overview: what owns the GPU

| State | GPU owner |
|-------|-----------|
| VM **running** | Windows (via VFIO) |
| VM **stopped** | Idle on `vfio-pci` — host still cannot use it |
| Passthrough **disabled** + vfio config removed | Host NVIDIA/AMD driver |

Passthrough means the host gives up the discrete GPU entirely. That is expected.

### Step 1 — Enable passthrough in VM config

```bash
# List candidate GPUs and IOMMU groups
./scripts/detect-gpu.sh

# Auto-detect and enable passthrough (GPU + HDMI audio)
./scripts/setup-gpu.sh --auto

# Or specify PCI slots manually (from detect-gpu.sh output)
./scripts/setup-gpu.sh --enable 01:00.0,01:00.1
```

This writes `scripts/gpu.conf` (gitignored, machine-specific). See `scripts/gpu.conf.example`.

### Step 2 — Switch the host to integrated graphics

The host must stop using the discrete GPU **before** VFIO can bind it. On **Pop!_OS** / System76:

```bash
system76-power graphics          # check current mode (often "nvidia")
sudo system76-power graphics integrated
sudo reboot
```

After reboot:

```bash
system76-power graphics          # should print: integrated
```

**Display note:** External monitors plugged into the NVIDIA HDMI/DP ports will go dark on the host. Use the **laptop internal screen** (Intel iGPU) until the VM is running with the monitor on the passed-through GPU.

On Ubuntu with `nvidia-prime`:

```bash
sudo prime-select intel
sudo reboot
```

### Step 3 — Bind the GPU to vfio-pci at boot

Get PCI IDs from `lspci -nn` (example for NVIDIA GPU + HDMI audio):

```bash
lspci -nn | grep -E 'VGA|Audio' | grep -i nvidia
# 01:00.0 VGA ... [10de:28e0]
# 01:00.1 Audio ... [10de:22be]
```

Create a modprobe config (replace IDs with yours):

```bash
sudo tee /etc/modprobe.d/vfio-pci.conf <<'EOF'
# Reserve discrete GPU + HDMI audio for Windows VM passthrough
options vfio-pci ids=10de:28e0,10de:22be
softdep nvidia pre: vfio-pci
softdep nvidia_drm pre: vfio-pci
softdep nvidia_modeset pre: vfio-pci
softdep nouveau pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci
EOF

sudo update-initramfs -u
sudo reboot
```

### Step 4 — Verify VFIO binding

```bash
lspci -k -s 01:00.0
lspci -k -s 01:00.1
```

Both should show:

```
Kernel driver in use: vfio-pci
```

They should **not** show `nvidia`, `nouveau`, or `snd_hda_intel`.

### Step 5 — Apply VM definition and start

```bash
./scripts/stop-vm.sh
./scripts/setup-vm.sh
./scripts/start-vm.sh
```

- **Primary display:** physical monitor on the passed-through GPU (HDMI/DP on the discrete card)
- **Secondary / remote:** `virt-viewer win10-vm` (QXL over SPICE) if you want a window on Linux

### Windows guest

After Windows is installed, install the GPU vendor driver (NVIDIA GeForce / Studio, or AMD Adrenalin). The VM XML includes NVIDIA-friendly settings (`kvm hidden`, OVMF MMIO quirk).

### Disable passthrough / return GPU to host

```bash
# 1) Remove VFIO binding
sudo rm /etc/modprobe.d/vfio-pci.conf
sudo update-initramfs -u

# 2) Switch host back to discrete graphics (Pop!_OS)
sudo system76-power graphics nvidia
sudo reboot

# 3) Disable passthrough in VM config
./scripts/setup-gpu.sh --disable
./scripts/stop-vm.sh && ./scripts/setup-vm.sh
```

### GPU passthrough troubleshooting

#### `setup-vm.sh` — `unexpected feature 'iommu'`

Libvirt **8.x** (Ubuntu 22.04 / Pop!_OS 22.04) does not support the guest `<iommu>` XML feature (added in libvirt 9.4+). This repo skips that element automatically on older libvirt. Host IOMMU (BIOS + kernel cmdline) is what VFIO actually needs.

#### `virsh start` hangs or never returns

Usually the host still owns the GPU. Check:

1. `system76-power graphics` is `integrated` (not `nvidia`)
2. `lspci -k -s 01:00.0` shows `vfio-pci`, not `nvidia`
3. Restart libvirtd if a previous start attempt hung: `sudo systemctl restart libvirtd`

#### virt-manager stuck on "Connecting to graphical console…"

The VM may be running fine — SPICE can work even when virt-manager's embedded viewer hangs (common on Wayland).

```bash
virsh domstate win10-vm
virsh domdisplay win10-vm          # e.g. spice://127.0.0.1:5900
virt-viewer win10-vm               # preferred over embedded console
# or: GDK_BACKEND=x11 virt-viewer win10-vm
```

With GPU passthrough, the **physical monitor on the discrete GPU** is the primary display, not SPICE.

#### VM defined but GPU not in live XML

After changing `gpu.conf`, always re-apply:

```bash
./scripts/stop-vm.sh && ./scripts/setup-vm.sh
```

---

## Internet access

Internet is enabled automatically via **user-mode NAT** (`<interface type='user'>` in the domain XML). No extra host configuration is required.

Inside Windows you should see a working network adapter (Intel I219-LM / `e1000e`). Open a browser to confirm.

If there is no connectivity:

1. Check the VM is running: `virsh domstate win10-vm`
2. In Windows: **Settings → Network & Internet** — adapter should show "Connected"
3. On the host, confirm QEMU user networking:  
   `virsh qemu-monitor-command win10-vm --hmp 'info usernet'`

---

## SSH access

After Windows is installed, run **PowerShell as Administrator** and execute `scripts/enable-openssh.ps1` (copy it into the guest or type the commands manually).

From the Linux host:

```bash
ssh -p 2222 Administrator@localhost
```

Port forwarding is applied automatically by `start-vm.sh` using the QEMU monitor (`hostfwd_add tcp::2222-:22`).

---

## Disk layout and management

Windows sees **two SATA disks** attached by libvirt. Each disk is a separate **qcow2** file on the Linux host. Growing a disk adds **unallocated space on the same physical disk** in Windows — you then **Extend Volume** in Disk Management (or PowerShell) to give that space to C: or E:.

### Default layout

| Windows | Host file | libvirt target | Default size | Purpose |
|---------|-----------|----------------|--------------|---------|
| **C:** | `disks/win10-vm.qcow2` | `sdb` | 80 GB | Windows system drive |
| **E:** | `disks/win10-vm-d.qcow2` | `sdc` | 300 GB | Data / games / projects |

Configured in `scripts/win10-vm.xml` and created by `scripts/setup-vm.sh`. Paths are defined in `scripts/common.sh`:

```bash
DISK="$VM_DIR/disks/win10-vm.qcow2"       # C:
DATA_DISK="$VM_DIR/disks/win10-vm-d.qcow2" # E:
```

`setup-vm.sh` only **creates** qcow2 files if they do not exist yet. Re-running it re-applies the libvirt XML; it does **not** wipe existing disks.

### How host-side resizing works

| Action | Tool | VM can stay running? |
|--------|------|----------------------|
| Grow **C:** | `./scripts/expand-disk.sh +SIZE` or `virsh blockresize win10-vm sdb SIZE` | Yes |
| Grow **E:** | `virsh blockresize win10-vm sdc SIZE` | Yes |
| Shrink a disk | `sudo qemu-img resize --shrink DISK SIZE` | **No** — stop VM first |
| Add/remove a whole disk | Edit `win10-vm.xml` → `./scripts/stop-vm.sh` → `./scripts/setup-vm.sh` → `./scripts/start-vm.sh` | **No** — SATA does not hot-plug |

**Grow example — extend E: from 300 GB to 400 GB:**

```bash
# On the host (VM may stay running)
virsh blockresize win10-vm sdc 400G
virsh domblkinfo win10-vm sdc    # confirm new Capacity
```

Then inside Windows (Administrator PowerShell):

```powershell
Update-HostStorageCache
$e = Get-Partition -DriveLetter E
$size = Get-PartitionSupportedSize -DiskNumber $e.DiskNumber -PartitionNumber $e.PartitionNumber
Resize-Partition -DiskNumber $e.DiskNumber -PartitionNumber $e.PartitionNumber -Size $size.SizeMax
```

Or run `scripts/extend-e-drive.ps1` (copy into the guest or mount the repo share).

**Grow C: by 20 GB:**

```bash
./scripts/expand-disk.sh +20G
# or: virsh blockresize win10-vm sdb +20G
```

Then extend **C:** in Windows the same way (replace `E` with `C` in the PowerShell above).

**Shrink C: back to 80 GB** (when you expanded the virtual disk but only want 80 GB for Windows):

```bash
./scripts/stop-vm.sh
sudo qemu-img resize --shrink disks/win10-vm.qcow2 80G
./scripts/setup-vm.sh && ./scripts/start-vm.sh
```

Reboot or **Rescan Disks** in Windows so Disk 0 shows the smaller size.

### Inside Windows — extend a volume

**GUI:** `Win + R` → `diskmgmt.msc` → **Action → Rescan Disks** → right-click the volume → **Extend Volume** → use adjacent unallocated space.

**PowerShell (Administrator) — C:**

```powershell
Update-HostStorageCache
$part = Get-Partition -DriveLetter C
$size = Get-PartitionSupportedSize -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber
Resize-Partition -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber -Size $size.SizeMax
```

**First-time setup — format E: on a new blank disk:**

```powershell
# scripts/format-d-drive.ps1 — adjust size filter if your E: disk is not 200 GB
$disk = Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' -and $_.Size -ge 180GB } | Select-Object -First 1
Initialize-Disk -Number $disk.Number -PartitionStyle GPT -Confirm:$false
$part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter E
Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel "Data" -Confirm:$false
```

### Why "Extend Volume" is sometimes greyed out

- **Recovery partition** sits between **C:** and unallocated space → Windows cannot extend C: across it. Use a **separate virtual disk** for E: instead of one huge C: disk.
- **Unallocated space is on a different physical disk** than the volume → Extend only works on the **same** disk, immediately after the partition. To grow E:, resize `win10-vm-d.qcow2` (sdc), not a second disk.
- **Stale disk size in Windows** after a host shrink → reboot the VM or **Action → Rescan Disks**.

### Recommended pattern

1. Keep **C:** small (80 GB) — Windows + apps only.
2. Put bulk storage on **E:** (`win10-vm-d.qcow2`) — grow with `virsh blockresize` + Extend Volume in Windows.
3. Do **not** grow C: to 200 GB if you only need a larger data drive — add/resize the E: disk instead.

### Verify disks from the host

```bash
virsh domblklist win10-vm
virsh domblkinfo win10-vm sdb    # C:
virsh domblkinfo win10-vm sdc    # E:
qemu-img info disks/win10-vm.qcow2
qemu-img info disks/win10-vm-d.qcow2
```

---

## Scripts reference

| Script | Purpose |
|--------|---------|
| `scripts/download-windows.sh` | Download UUP set and build `iso/win10-22h2.iso` |
| `scripts/finish-download.sh` | Convert an already-downloaded UUP set to ISO |
| `scripts/setup-vm.sh` | Create disk, render XML, `virsh define win10-vm` |
| `scripts/start-vm.sh` | Start VM + SSH port forward |
| `scripts/stop-vm.sh` | Graceful shutdown (120 s timeout) |
| `scripts/expand-disk.sh` | Grow **C:** qcow2 online (`+SIZE`) |
| `scripts/extend-e-drive.ps1` | Extend **E:** into unallocated space (run in Windows) |
| `scripts/format-d-drive.ps1` | Initialize a blank second disk as a data volume (run in Windows) |
| `scripts/enable-openssh.ps1` | Enable OpenSSH Server in Windows |
| `scripts/common.sh` | Shared paths and XML templating |
| `scripts/detect-gpu.sh` | List discrete GPUs and IOMMU groups for passthrough |
| `scripts/setup-gpu.sh` | Enable/disable VFIO GPU passthrough |
| `scripts/gpu.conf.example` | Example GPU passthrough configuration |
| `scripts/win10-vm.xml` | libvirt domain template (`@VM_DIR@` placeholder) |

---

## Debugging

### No drives shown during Windows install

**Symptom:** "Where do you want to install Windows?" lists zero drives.

**Cause:** VirtIO disk bus — Windows has no inbox driver during setup.

**Fix (already applied in this repo):** Disk uses **SATA** (`<target bus='sata'>`). Click **Refresh** in the installer. If you changed the XML to VirtIO, either switch back to SATA or attach the [VirtIO Windows drivers ISO](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso) and use **Load driver**.

### VM fails to start — SPICE / GL error

```
SPICE GL support is local-only for now and incompatible with -spice port/tls-port
```

Remove `<gl enable='yes'/>` from the graphics section (already removed in `win10-vm.xml`).

### `virsh define` / permission denied

```bash
groups | grep -E 'libvirt|kvm'
sudo usermod -aG libvirt,kvm "$USER"
```

### UUP download fails — converter 522 timeout

`git.uupdump.net` may be unreachable. `download-windows.sh` falls back to GitHub-hosted converter scripts automatically.

### ISO conversion script exits but ISO exists

The converter writes `*.ISO` (uppercase). `finish-download.sh` uses a case-insensitive search — re-run it or move the file to `iso/win10-22h2.iso` manually.

### SSH connection refused on port 2222

1. VM must be running: `./scripts/start-vm.sh`
2. OpenSSH Server must be installed in Windows (`enable-openssh.ps1`)
3. Confirm forward rule:  
   `virsh qemu-monitor-command win10-vm --hmp 'info usernet'`
4. Re-add forward if missing:  
   `virsh qemu-monitor-command win10-vm --hmp 'hostfwd_add tcp::2222-:22'`

### No internet in guest

- Confirm `<interface type='user'>` in `scripts/win10-vm.xml`
- Use `e1000e` NIC model (Windows inbox driver)
- Restart VM: `./scripts/stop-vm.sh && ./scripts/start-vm.sh`

### GPU passthrough / VFIO

See [GPU passthrough troubleshooting](#gpu-passthrough-troubleshooting) above for `iommu` XML errors, hung `virsh start`, VFIO binding, and virt-manager console issues.

### Check logs

```bash
virsh dominfo win10-vm
virsh dumpxml win10-vm
sudo tail -f /var/log/libvirt/qemu/win10-vm.log
```

---

## Directory layout

```
.
├── README.md
├── scripts/
│   ├── common.sh
│   ├── win10-vm.xml
│   ├── download-windows.sh
│   ├── setup-vm.sh
│   ├── start-vm.sh
│   ├── stop-vm.sh
│   ├── expand-disk.sh
│   └── enable-openssh.ps1
├── iso/                 # win10-22h2.iso (not in git)
├── disks/               # win10-vm.qcow2 (C:), win10-vm-d.qcow2 (E:), OVMF_VARS.fd (not in git)
└── uup/                 # UUP download cache (not in git)
```

---

## Customization

Edit `scripts/win10-vm.xml` before running `setup-vm.sh`:

- **RAM / CPU:** `<memory>`, `<vcpu>`
- **SSH port:** set `SSH_HOST_PORT=2223 ./scripts/start-vm.sh`
- **GPU passthrough:** `./scripts/setup-gpu.sh --auto` then re-run `setup-vm.sh`
- **Initial disk size:** change `80G` in `setup-vm.sh` before first `qemu-img create`

Re-apply changes:

```bash
./scripts/stop-vm.sh
./scripts/setup-vm.sh
./scripts/start-vm.sh
```

---

## License

MIT — use freely; Windows ISOs are subject to Microsoft's license terms.