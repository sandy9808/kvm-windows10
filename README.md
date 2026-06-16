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
| Disk | 80 GB qcow2 (expandable while VM is running) |
| Display | SPICE + QXL (use `virt-viewer`) |
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

## Increase disk size (VM stays running)

The guest disk is **qcow2 on SATA**, so you can grow it **without shutting down Windows**.

### On the Linux host

```bash
./scripts/expand-disk.sh +20G    # add 20 GB (default if no argument)
```

Or manually:

```bash
qemu-img resize disks/win10-vm.qcow2 +20G
qemu-img info disks/win10-vm.qcow2
```

### Inside Windows (no reboot needed)

**GUI:** `Win + R` → `diskmgmt.msc` → **Action → Rescan Disks** → right-click **C:** → **Extend Volume**.

**PowerShell (Administrator):**

```powershell
Update-HostStorageCache
$part = Get-Partition -DriveLetter C
$size = Get-PartitionSupportedSize -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber
Resize-Partition -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber -Size $size.SizeMax
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
| `scripts/expand-disk.sh` | Grow qcow2 online |
| `scripts/enable-openssh.ps1` | Enable OpenSSH Server in Windows |
| `scripts/common.sh` | Shared paths and XML templating |
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
├── disks/               # win10-vm.qcow2, OVMF_VARS.fd (not in git)
└── uup/                 # UUP download cache (not in git)
```

---

## Customization

Edit `scripts/win10-vm.xml` before running `setup-vm.sh`:

- **RAM / CPU:** `<memory>`, `<vcpu>`
- **SSH port:** set `SSH_HOST_PORT=2223 ./scripts/start-vm.sh`
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