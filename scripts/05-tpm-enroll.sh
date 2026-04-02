#!/usr/bin/env bash
#
# Step 5: TPM Key Enrollment
#
# This script:
# - Verifies TPM 2.0 availability
# - Generates recovery key
# - Enrolls TPM key for automatic LUKS unlocking
# - Binds to PCR 7 (Secure Boot state)
# - Configures systemd-cryptenroll
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/utils.sh
source "${SCRIPT_DIR}/utils.sh"

# State file from previous step
readonly STATE_FILE="/tmp/arch-install-state"

# Load state from previous step
load_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        print_error "State file not found. Did you run previous steps first?"
        exit 1
    fi

    # shellcheck source=/dev/null
    source "$STATE_FILE"
}

# Verify TPM availability
verify_tpm() {
    print_info "Verifying TPM 2.0 availability..."

    if ! has_tpm2; then
        print_error "TPM 2.0 not found or not accessible"
        print_error "Please enable TPM in BIOS/UEFI settings"
        return 1
    fi

    local tpm_version
    tpm_version=$(cat /sys/class/tpm/tpm0/tpm_version_major)

    print_success "TPM ${tpm_version}.0 detected"

    # Check TPM device
    if [[ ! -c /dev/tpm0 ]]; then
        print_error "TPM device /dev/tpm0 not accessible"
        return 1
    fi

    print_success "TPM device accessible: /dev/tpm0"
}

# Verify LUKS device is accessible
verify_luks_device() {
    print_info "Verifying LUKS device..."

    # Check if ROOT_PART exists
    if [[ ! -b "$ROOT_PART" ]]; then
        print_error "LUKS partition not found: $ROOT_PART"
        print_error "Did you run 01-partition.sh first?"
        return 1
    fi

    # Verify it's a LUKS device
    if ! cryptsetup isLuks "$ROOT_PART" 2>/dev/null; then
        print_error "$ROOT_PART is not a LUKS device"
        return 1
    fi

    print_success "LUKS device verified: $ROOT_PART"

    # Check if LUKS device is open
    if [[ ! -e "/dev/mapper/${LUKS_NAME}" ]]; then
        print_error "LUKS device is not open: /dev/mapper/${LUKS_NAME}"
        print_error "The encrypted partition must be unlocked for enrollment"
        return 1
    fi

    print_success "LUKS device is open: /dev/mapper/${LUKS_NAME}"
}

# Check current LUKS key slots
check_luks_slots() {
    print_info "Checking current LUKS key slots..."
    echo

    if cryptsetup luksDump "$ROOT_PART" | grep "Key Slot"; then
        echo
    fi

    print_info "Current key slots on $ROOT_PART"
}

# Generate and enroll recovery key
enroll_recovery_key() {
    print_info "Generating LUKS recovery key..."
    echo

    print_warn "IMPORTANT: Save this recovery key in a safe place!"
    print_warn "You will need it if TPM unlocking fails or hardware changes."
    echo

    # Create recovery key file
    local recovery_file="${MOUNT_POINT}/root/luks-recovery-key.txt"

    # Generate recovery key
    print_info "Generating recovery key..."
    echo

    if systemd-cryptenroll --recovery-key "$ROOT_PART" | tee "$recovery_file"; then
        echo
        print_success "Recovery key generated and saved to: /root/luks-recovery-key.txt"

        # Set secure permissions
        chmod 600 "$recovery_file"

        echo
        print_warn "╔════════════════════════════════════════════════════════════╗"
        print_warn "║ BACKUP THIS RECOVERY KEY TO EXTERNAL STORAGE NOW!         ║"
        print_warn "║ It is saved at: /root/luks-recovery-key.txt               ║"
        print_warn "╚════════════════════════════════════════════════════════════╝"
        echo

        # Wait for user acknowledgment
        read -rp "Press Enter after you have saved the recovery key..."
    else
        print_error "Failed to generate recovery key"
        return 1
    fi
}

# Check if systemd-cryptenroll is available on host
# Note: TPM enrollment runs on host, not in chroot, because it needs
# direct access to TPM hardware and the LUKS device
check_cryptenroll() {
    print_info "Checking systemd-cryptenroll availability on host..."

    if command -v systemd-cryptenroll &>/dev/null; then
        print_success "systemd-cryptenroll is available on host"
        return 0
    else
        print_error "systemd-cryptenroll not found on host system"
        print_warn "Install it with: pacman -S systemd"
        return 1
    fi
}

# Enroll TPM key
enroll_tpm_key() {
    print_info "Enrolling TPM key for automatic LUKS unlocking..."
    echo

    print_info "Configuration:"
    echo "  • TPM Device: /dev/tpm0 (auto)"
    echo "  • PCR Register: 7 (Secure Boot state)"
    echo "  • Key Slot: Will be assigned automatically"
    echo

    print_info "PCR 7 measures:"
    echo "  • Secure Boot state (enabled/disabled)"
    echo "  • Secure Boot configuration"
    echo

    print_warn "Note: TPM enrollment may not work fully in chroot environment"
    print_warn "If this fails, you can re-run after first boot with:"
    print_warn "  systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/nvme0n1p2"
    echo

    # Attempt TPM enrollment
    print_info "Attempting TPM enrollment..."
    echo

    # Try to enroll TPM key
    if systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 "$ROOT_PART"; then
        echo
        print_success "TPM key enrolled successfully!"
        return 0
    else
        echo
        print_warn "TPM enrollment failed (this is common in live environment)"
        print_info "This is normal and can be completed after first boot"
        return 1
    fi
}

# Create post-installation TPM enrollment script
create_enrollment_script() {
    print_info "Creating post-installation TPM enrollment script..."

    local enroll_script="${MOUNT_POINT}/root/enroll-tpm.sh"

    cat > "$enroll_script" <<'EOF'
#!/usr/bin/env bash
#
# Post-installation TPM enrollment script
# Run this after first boot if TPM enrollment failed during installation
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Check root
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root"
    exit 1
fi

# Find LUKS device
LUKS_DEVICE=$(lsblk -nlo NAME,TYPE | grep crypt | head -n1 | awk '{print $1}')

if [[ -z "$LUKS_DEVICE" ]]; then
    print_error "No LUKS device found"
    exit 1
fi

# Find backing device
BACKING_DEVICE=$(cryptsetup status "$LUKS_DEVICE" | grep device: | awk '{print $2}')

print_info "Found LUKS device: $LUKS_DEVICE"
print_info "Backing device: $BACKING_DEVICE"
echo

# Check if TPM key already enrolled
if cryptsetup luksDump "$BACKING_DEVICE" | grep -q "systemd-tpm2"; then
    print_warn "TPM key appears to be already enrolled"
    read -rp "Re-enroll anyway? [y/N] " response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        exit 0
    fi

    print_info "Removing existing TPM token..."
    systemd-cryptenroll --wipe-slot=tpm2 "$BACKING_DEVICE"
fi

# Enroll TPM key
print_info "Enrolling TPM key (PCR 7 - Secure Boot state)..."
echo

if systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 "$BACKING_DEVICE"; then
    echo
    print_info "TPM key enrolled successfully!"
    echo
    print_info "Verification:"
    systemd-cryptenroll "$BACKING_DEVICE"
    echo
    print_info "Testing: Please reboot to test automatic unlocking"
else
    echo
    print_error "TPM enrollment failed"
    echo
    print_info "Troubleshooting:"
    echo "  1. Ensure TPM is enabled in BIOS"
    echo "  2. Ensure Secure Boot will be enabled (for PCR 7)"
    echo "  3. Check: systemctl status systemd-cryptsetup@*.service"
    exit 1
fi
EOF

    chmod +x "$enroll_script"

    print_success "TPM enrollment script created: /root/enroll-tpm.sh"
}

# Update crypttab for TPM
update_crypttab() {
    print_info "Updating crypttab for TPM support..."

    local crypttab="${MOUNT_POINT}/etc/crypttab"

    if [[ -f "$crypttab" ]]; then
        backup_file "$crypttab"

        # Update or add TPM options
        if grep -q "^${LUKS_NAME}" "$crypttab"; then
            # Update existing entry
            sed -i "s|^${LUKS_NAME}.*|${LUKS_NAME}   UUID=${LUKS_UUID}   none   tpm2-device=auto,discard|" "$crypttab"
        else
            # Add new entry
            echo "${LUKS_NAME}   UUID=${LUKS_UUID}   none   tpm2-device=auto,discard" >> "$crypttab"
        fi

        print_info "Updated crypttab:"
        cat "$crypttab"
        echo

        print_success "crypttab updated"
    else
        print_warn "crypttab not found, skipping"
    fi
}

# Verify enrollment
verify_enrollment() {
    print_info "Verifying LUKS configuration..."
    echo

    print_info "Key slots:"
    systemd-cryptenroll "$ROOT_PART" 2>/dev/null || {
        print_warn "Could not verify enrollment in live environment"
        print_info "Verification will be performed after first boot"
    }
}

# Generate post-installation instructions
generate_tpm_instructions() {
    local instructions_file="${MOUNT_POINT}/root/tpm-instructions.txt"

    cat > "$instructions_file" <<'EOF'
================================================================================
TPM ENROLLMENT POST-INSTALLATION INSTRUCTIONS
================================================================================

IMPORTANT: TPM enrollment may not have completed during installation due to
chroot environment limitations.

After first boot into the installed system:

1. CHECK IF TPM ENROLLMENT SUCCEEDED
   Run as root:

   systemd-cryptenroll /dev/nvme0n1p2

   Look for "tpm2" in the output. If present, TPM is enrolled!

2. IF TPM NOT ENROLLED
   Run the enrollment script:

   sudo /root/enroll-tpm.sh

   This will:
   - Detect your LUKS device
   - Enroll TPM key bound to PCR 7
   - Verify enrollment

3. ENABLE SECURE BOOT
   CRITICAL: TPM auto-unlock requires Secure Boot to be enabled!

   a) Reboot into BIOS
   b) Enroll Secure Boot keys (if not done):
      - Boot back into Linux
      - Run: sudo sbctl enroll-keys --microsoft
      - Reboot
   c) Enable Secure Boot in BIOS
   d) Boot Linux

4. TEST TPM AUTO-UNLOCK
   After enabling Secure Boot, reboot:

   - You should NOT see a passphrase prompt
   - System should boot automatically
   - Verify with: bootctl status

5. TEST FAILURE SCENARIOS
   IMPORTANT: Test recovery before you need it!

   a) Disable Secure Boot in BIOS:
      - Should prompt for LUKS passphrase
      - Enter your installation passphrase
      - System should boot

   b) Re-enable Secure Boot:
      - TPM auto-unlock should work again
      - No passphrase prompt

6. VERIFY ENROLLMENT
   sudo systemd-cryptenroll /dev/nvme0n1p2

   Should show:
   - Slot 0: passphrase (your original password)
   - Slot 1: tpm2 (PCR 7)
   - Slot 2: recovery (from recovery key)

================================================================================
RECOVERY SCENARIOS
================================================================================

If TPM unlocking fails:

1. Enter LUKS passphrase manually (from installation)
2. Boot into system
3. Check TPM status: systemd-cryptenroll /dev/nvme0n1p2
4. Re-enroll if needed: /root/enroll-tpm.sh

If passphrase forgotten:

1. Boot from live USB
2. Use recovery key from /root/luks-recovery-key.txt
3. Open LUKS: cryptsetup luksOpen /dev/nvme0n1p2 cryptroot --key-file recovery.txt
4. Mount and fix

If TPM changes (motherboard/firmware replacement):

1. Boot with Secure Boot disabled
2. Enter passphrase manually
3. Remove old TPM key: systemd-cryptenroll --wipe-slot=tpm2 /dev/nvme0n1p2
4. Re-enroll: /root/enroll-tpm.sh

================================================================================
TROUBLESHOOTING
================================================================================

Problem: "No such device" error during boot
Solution: Check /etc/crypttab has correct UUID

Problem: Passphrase always required even with Secure Boot
Solution: TPM key not enrolled or PCR values changed
         Re-enroll with: /root/enroll-tpm.sh

Problem: "TPM error" during enrollment
Solution: Clear TPM in BIOS, or reset TPM ownership

For more help:
- Arch Wiki: https://wiki.archlinux.org/title/Trusted_Platform_Module
- systemd-cryptenroll: man systemd-cryptenroll

================================================================================
EOF

    print_info "TPM instructions saved to: /root/tpm-instructions.txt"
}

# Display summary
show_summary() {
    echo
    print_separator "="
    print_success "TPM enrollment configuration complete!"
    print_separator "="
    echo

    print_info "What was configured:"
    echo "  ✓ LUKS recovery key generated"
    echo "  ✓ TPM enrollment attempted (PCR 7)"
    echo "  ✓ crypttab updated for TPM support"
    echo "  ✓ Post-installation scripts created"
    echo

    print_warn "POST-INSTALLATION REQUIREMENTS:"
    echo
    echo "  1. Enable Secure Boot in BIOS (required for PCR 7)"
    echo
    echo "  2. If TPM enrollment failed, run after first boot:"
    echo "     sudo /root/enroll-tpm.sh"
    echo
    echo "  3. Test automatic unlocking by rebooting"
    echo
    echo "  4. Backup recovery key from:"
    echo "     /root/luks-recovery-key.txt"
    echo

    print_info "Documentation:"
    echo "  • /root/tpm-instructions.txt - Detailed TPM setup guide"
    echo "  • /root/enroll-tpm.sh - TPM enrollment script"
    echo "  • /root/luks-recovery-key.txt - Emergency recovery key"
    echo
}

# Main function
main() {
    print_info "=== TPM Key Enrollment ==="
    echo

    # Require root
    require_root || exit 1

    # Load state from previous step
    load_state

    # Verify TPM
    verify_tpm || exit 1

    # Verify LUKS device
    verify_luks_device || exit 1

    # Check LUKS slots
    check_luks_slots

    # Generate recovery key
    enroll_recovery_key

    # Check cryptenroll availability
    check_cryptenroll || {
        print_warn "systemd-cryptenroll not available, skipping enrollment"
        create_enrollment_script
        update_crypttab
        generate_tpm_instructions
        show_summary
        return 0
    }

    # Attempt TPM enrollment
    if enroll_tpm_key; then
        print_success "TPM enrollment succeeded in installation environment"
    else
        print_info "TPM enrollment will be completed after first boot"
    fi

    # Create enrollment script for post-install
    create_enrollment_script

    # Update crypttab
    update_crypttab

    # Verify enrollment
    verify_enrollment

    # Generate instructions
    generate_tpm_instructions

    # Show summary
    show_summary

    print_success "Step 5 complete: TPM enrollment configured"
    echo
    print_info "Next step: Run 06-bootloader.sh to install systemd-boot"
}

# Run main function
main "$@"
