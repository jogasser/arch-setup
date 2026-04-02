# Arch Linux Installation with TPM, Secure Boot & Full Disk Encryption

Automated installation scripts for setting up Arch Linux with modern security features:
- **TPM 2.0** for automatic disk encryption unlocking
- **Secure Boot** with custom keys and signed unified kernel images
- **Full Disk Encryption** using LUKS2

## Features

- **dracut-based initramfs** with native Unified Kernel Image (UKI) support
- **sbctl** for user-friendly Secure Boot key management
- **systemd-boot** bootloader
- **TPM PCR 7** binding (Secure Boot state) for automatic LUKS unlocking
- Automatic kernel signing via pacman hooks
- Recovery key generation for emergency access
- Modular scripts for easy customization and troubleshooting

## Prerequisites

Before starting the installation, ensure you have:

### Hardware Requirements

- **UEFI-capable motherboard** (not legacy BIOS)
- **TPM 2.0 chip** (check with `cat /sys/class/tpm/tpm0/tpm_version_major`)
- **SSD/NVMe drive** for installation
- **Secure Boot capable firmware**

### Preparation

1. **Boot from Arch Linux installation media**
   ```bash
   # Download latest ISO from archlinux.org
   # Create bootable USB with dd or Ventoy
   ```

2. **Verify UEFI mode**
   ```bash
   ls /sys/firmware/efi/efivars
   # Should list files; if error, you're in legacy BIOS mode
   ```

3. **Verify TPM 2.0**
   ```bash
   cat /sys/class/tpm/tpm0/tpm_version_major
   # Should output: 2
   ```

4. **Disable Secure Boot temporarily** (in BIOS/UEFI settings)
   - Required during installation
   - Will be re-enabled after setup

5. **Internet connection**
   ```bash
   # Wired (usually works automatically)
   ping -c 3 archlinux.org

   # Wireless
   iwctl
   [iwd]# station wlan0 connect "SSID"
   ```

6. **Clone this repository or download scripts**
   ```bash
   pacman -Sy git
   git clone <this-repo-url> /root/galaxus-setup
   cd /root/galaxus-setup
   ```

See [docs/prerequisites.md](docs/prerequisites.md) for detailed checklist.

## Installation Methods

### Option 1: Automated Installation (Recommended)

Run the main orchestration script:

```bash
./install.sh
```

This will:
1. Guide you through disk selection
2. Prompt for encryption passphrase
3. Execute all installation steps automatically
4. Generate recovery keys
5. Configure TPM, Secure Boot, and bootloader
6. Verify the installation

### Option 2: Manual Step-by-Step

Execute each script individually for more control:

```bash
# 1. Partition disk and setup LUKS
./scripts/01-partition.sh

# 2. Install base system
./scripts/02-install-base.sh

# 3. Configure dracut initramfs
./scripts/03-setup-dracut.sh

# 4. Setup Secure Boot with sbctl
./scripts/04-secure-boot.sh

# 5. Enroll TPM for automatic unlocking
./scripts/05-tpm-enroll.sh

# 6. Install and configure systemd-boot
./scripts/06-bootloader.sh
```

Each script can be run independently for testing or recovery.

## Post-Installation

After installation completes:

### 1. Reboot and Enable Secure Boot

```bash
# Exit chroot if in one
exit

# Unmount filesystems
umount -R /mnt

# Reboot
reboot
```

**In BIOS/UEFI settings:**
- Enable Secure Boot
- Set Secure Boot to "Setup Mode" or "Custom Keys"
- Boot from hard drive

### 2. First Boot Verification

On first boot, you should:
- See systemd-boot menu
- TPM should automatically unlock the disk (no passphrase prompt)
- System boots into Arch Linux

Verify Secure Boot status:
```bash
sbctl status
# Should show: "Secure Boot is enabled"
```

### 3. Test Failure Scenarios

**Important**: Test that recovery works!

```bash
# Test 1: Disable Secure Boot in BIOS
# Expected: System prompts for LUKS passphrase

# Test 2: Re-enable Secure Boot
# Expected: TPM auto-unlocking works again
```

### 4. Save Recovery Information

**CRITICAL**: Store these safely offline:

1. **LUKS recovery key** - Generated during installation
   - Printed to console during TPM enrollment
   - Save to password manager or print and secure physically

2. **LUKS passphrase** - The passphrase you set during installation
   - Keep in secure location

3. **Secure Boot keys** - Located in `/var/lib/sbctl/keys/`
   - Backup these files to external storage
   - Required for disaster recovery

See [docs/troubleshooting.md](docs/troubleshooting.md) for recovery procedures.

## Architecture Overview

### Disk Layout

```
/dev/nvme0n1
├── /dev/nvme0n1p1    EFI System Partition (1GB, FAT32)
│   └── /boot         Mounted here
└── /dev/nvme0n1p2    LUKS2 Encrypted Container
    └── cryptroot     Unlocked volume
        └── ext4      Root filesystem (/)
```

### Boot Process

```
UEFI Firmware
  └─> systemd-boot (signed)
      └─> Unified Kernel Image (signed)
          ├── Kernel
          ├── Initramfs (dracut)
          └── Kernel cmdline
          └─> TPM checks PCR 7 (Secure Boot state)
              └─> Auto-unlock LUKS
                  └─> Boot root filesystem
```

### Security Model

1. **Secure Boot** validates boot chain integrity
   - UEFI firmware verifies systemd-boot signature
   - systemd-boot verifies UKI signature
   - Custom keys enrolled in firmware

2. **TPM PCR 7 Binding**
   - LUKS key sealed to TPM
   - Only released if PCR 7 matches expected value
   - PCR 7 = Secure Boot state and boot configuration

3. **LUKS2 Encryption**
   - Full disk encryption with multiple key slots:
     - Slot 0: User passphrase (fallback)
     - Slot 1: TPM-sealed key (auto-unlock)
     - Slot 2: Recovery key (emergency access)

### Why PCR 7 Only?

- **PCR 7** measures Secure Boot state and boot configuration
- Allows kernel updates without TPM re-enrollment
- Triggers passphrase prompt if Secure Boot disabled
- Good balance of security and maintainability

Alternative PCR combinations and trade-offs are documented in [docs/references.md](docs/references.md).

## Customization

### Changing Disk Layout

Edit `scripts/01-partition.sh` to customize:
- Partition sizes
- Add separate `/home` partition
- Use LVM or Btrfs with subvolumes

### Adding More PCRs

Edit `scripts/05-tpm-enroll.sh`:
```bash
# Change from PCR 7 to PCR 0+7 for firmware + Secure Boot binding
systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 "$DEVICE"
```

### Enable TPM PIN

For additional security, require PIN entry:

Edit `scripts/05-tpm-enroll.sh`:
```bash
systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 \
                     --tpm2-with-pin=yes "$DEVICE"
```

### Package Selection

Edit `configs/packages.txt` to customize installed packages.

## Maintenance

### Kernel Updates

Kernel updates are handled automatically:
- pacman installs new kernel
- dracut hook regenerates UKI
- sbctl hook signs new UKI
- No TPM re-enrollment needed (PCR 7 unchanged)

### Firmware Updates

Firmware updates may require TPM re-enrollment:

```bash
# After firmware update, if boot fails to auto-unlock:
# 1. Boot and enter LUKS passphrase manually
# 2. Remove old TPM key and re-enroll
systemd-cryptenroll --wipe-slot=tpm2 /dev/nvme0n1p2
systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/nvme0n1p2
```

### Checking TPM Status

```bash
# List enrolled keys
systemd-cryptenroll /dev/nvme0n1p2

# Check which PCRs are used
tpm2_pcrread sha256:7
```

### Re-signing After Manual Kernel Install

If you manually compile a kernel:
```bash
sbctl sign -s /boot/EFI/Linux/custom-kernel.efi
```

## Troubleshooting

### Common Issues

**"TPM not found" during enrollment**
- Verify TPM is enabled in BIOS
- Check `ls /dev/tpm*` shows device
- Load TPM modules: `modprobe tpm_tis tpm_crb`

**Boot fails, prompts for passphrase every time**
- TPM key not properly enrolled
- Secure Boot might be disabled
- PCR values changed (firmware update)

**Secure Boot prevents booting**
- Keys not properly enrolled
- UKI not signed
- Check `sbctl verify`

**"Operation not permitted" during sbctl key enrollment**
- Secure Boot must be in "Setup Mode"
- Clear Platform Key in BIOS
- Some firmwares require "Custom Keys" mode

See [docs/troubleshooting.md](docs/troubleshooting.md) for detailed solutions.

## Security Considerations

### Threat Model

**Protects Against:**
- Offline disk attacks (stolen laptop)
- Boot tampering detection
- Unauthorized kernel modifications

**Does NOT Protect Against:**
- Cold boot attacks (RAM dumping)
- Evil Maid attacks with firmware modification capabilities
- Physical access with debugging tools
- Runtime exploitation after boot

### Best Practices

1. **Always maintain multiple unlock methods**
   - Keep LUKS passphrase secure
   - Print and store recovery key safely
   - Don't remove slot 0 (passphrase)

2. **Test recovery procedures** before you need them

3. **Backup Secure Boot keys** to external storage

4. **Physical security** still matters - TPM isn't magic

5. **Consider BIOS password** for additional protection

6. **Monitor for tampering**
   ```bash
   # Check if anyone modified UEFI variables
   sbctl status
   ```

## Project Structure

```
galaxus-setup/
├── README.md                    # This file
├── install.sh                   # Main orchestration script
├── scripts/
│   ├── utils.sh                 # Shared functions
│   ├── 01-partition.sh          # Disk partitioning & LUKS
│   ├── 02-install-base.sh       # Base system installation
│   ├── 03-setup-dracut.sh       # dracut initramfs configuration
│   ├── 04-secure-boot.sh        # sbctl Secure Boot setup
│   ├── 05-tpm-enroll.sh         # TPM key enrollment
│   └── 06-bootloader.sh         # systemd-boot installation
├── configs/
│   ├── dracut.conf.d/           # dracut configurations
│   ├── loader/                  # systemd-boot configs
│   └── packages.txt             # Package list
└── docs/
    ├── prerequisites.md         # Detailed preparation steps
    ├── troubleshooting.md       # Problem resolution guide
    └── references.md            # Additional resources
```

## References

- [Arch Wiki: dm-crypt](https://wiki.archlinux.org/title/Dm-crypt)
- [Arch Wiki: Unified Kernel Image](https://wiki.archlinux.org/title/Unified_kernel_image)
- [Arch Wiki: Secure Boot](https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface/Secure_Boot)
- [Arch Wiki: TPM](https://wiki.archlinux.org/title/Trusted_Platform_Module)
- [systemd-cryptenroll documentation](https://www.freedesktop.org/software/systemd/man/systemd-cryptenroll.html)
- [dracut documentation](https://github.com/dracut-ng/dracut-ng)
- [sbctl GitHub](https://github.com/Foxboron/sbctl)

See [docs/references.md](docs/references.md) for more resources.

## Contributing

Contributions welcome! Areas for improvement:
- Btrfs subvolume support
- LVM configuration options
- Additional bootloader options (GRUB)
- Post-installation configuration scripts
- Automated testing

## License

MIT License - See LICENSE file

## Disclaimer

These scripts modify disk partitions and system configuration. **USE AT YOUR OWN RISK.**
- Always backup important data before installation
- Test in a virtual machine first
- Understand each step before executing
- Keep recovery media available

The authors are not responsible for data loss, bricked systems, or any other issues arising from use of these scripts.
