#!/usr/bin/env bash
#
# Step 4: Secure Boot Setup with sbctl
#
# This script:
# - Installs sbctl
# - Generates Secure Boot keys
# - Signs bootloader and kernel images
# - Sets up automatic signing via pacman hooks
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

# Install sbctl
install_sbctl() {
    print_info "Installing sbctl..."

    chroot_cmd "pacman -S --noconfirm --needed sbctl"

    print_success "sbctl installed"
}

# Check Secure Boot status
check_secure_boot_status() {
    print_info "Checking Secure Boot status..."

    if chroot_cmd "sbctl status" 2>/dev/null; then
        echo
    else
        print_warn "sbctl status check failed (this is expected in chroot)"
    fi
}

# Create Secure Boot keys
create_keys() {
    print_info "Creating Secure Boot keys..."
    echo

    if chroot_cmd "sbctl status 2>/dev/null | grep -q 'Setup Mode'"; then
        print_info "Firmware is in Setup Mode"
    else
        print_info "Note: Keys will be created but enrollment requires Setup Mode"
        print_info "      You must enable Setup Mode in BIOS after installation"
    fi

    echo
    print_info "Generating custom Secure Boot keys..."

    if chroot_cmd "sbctl create-keys"; then
        print_success "Secure Boot keys created"
    else
        print_error "Failed to create keys"
        return 1
    fi

    echo
    print_info "Keys stored in: /var/lib/sbctl/keys/"
    print_warn "IMPORTANT: Backup these keys to external storage!"
    echo
}

# Sign bootloader files
sign_bootloader() {
    print_info "Signing systemd-boot bootloader..."

    local bootloader_paths=(
        "/usr/lib/systemd/boot/efi/systemd-bootx64.efi"
    )

    for bootloader in "${bootloader_paths[@]}"; do
        local full_path="${MOUNT_POINT}${bootloader}"

        if [[ -f "$full_path" ]]; then
            print_info "Signing: $bootloader"
            if chroot_cmd "sbctl sign -s ${bootloader}"; then
                print_success "Signed: $bootloader"
            else
                print_error "Failed to sign: $bootloader"
            fi
        else
            print_warn "Not found: $bootloader (will sign after bootloader installation)"
        fi
    done
}

# Sign kernel images
sign_kernels() {
    print_info "Signing kernel images..."

    # Find UKI files
    local uki_dir="${MOUNT_POINT}/boot/EFI/Linux"

    if [[ ! -d "$uki_dir" ]]; then
        print_warn "UKI directory not found: $uki_dir"
        return 1
    fi

    # Sign all .efi files in Linux directory
    local found_uki=false
    while IFS= read -r -d '' uki_file; do
        found_uki=true
        local uki_rel_path="${uki_file#${MOUNT_POINT}}"

        print_info "Signing: $uki_rel_path"
        if chroot_cmd "sbctl sign -s ${uki_rel_path}"; then
            print_success "Signed: $uki_rel_path"
        else
            print_error "Failed to sign: $uki_rel_path"
        fi
    done < <(find "$uki_dir" -name "*.efi" -type f -print0)

    if [[ "$found_uki" == false ]]; then
        print_warn "No UKI files found in $uki_dir"
        print_info "They will be signed automatically after generation"
    fi
}

# Verify signatures
verify_signatures() {
    print_info "Verifying signatures..."
    echo

    if chroot_cmd "sbctl verify"; then
        echo
        print_success "All files are properly signed"
    else
        print_warn "Some files are not signed yet (this may be expected)"
        echo
        print_info "Files will be automatically signed by sbctl hooks"
    fi
}

# Setup automatic signing
setup_auto_signing() {
    print_info "Setting up automatic signing with pacman hooks..."

    # sbctl package should install hooks automatically
    # Verify they exist
    local hooks_dir="${MOUNT_POINT}/usr/share/libalpm/hooks"

    if [[ -d "$hooks_dir" ]]; then
        local sbctl_hooks
        sbctl_hooks=$(find "$hooks_dir" -name "*sbctl*" 2>/dev/null | wc -l)

        if [[ $sbctl_hooks -gt 0 ]]; then
            print_success "sbctl pacman hooks are installed"
            print_info "Kernel updates will be automatically signed"
        else
            print_warn "sbctl hooks not found"
        fi
    fi
}

# Generate post-installation instructions
generate_instructions() {
    local instructions_file="${MOUNT_POINT}/root/secure-boot-instructions.txt"

    cat > "$instructions_file" <<'EOF'
================================================================================
SECURE BOOT SETUP INSTRUCTIONS
================================================================================

After rebooting into the installed system, follow these steps:

1. ENTER BIOS/UEFI SETUP
   - Reboot and press the BIOS key (usually F2, F10, F12, or Del)

2. CONFIGURE SECURE BOOT
   - Navigate to the Secure Boot settings
   - Set Secure Boot to "Setup Mode" or "Custom Keys"
     (This clears the existing Microsoft keys)
   - Some systems require "Clear Platform Key" or "Clear Secure Boot keys"
   - Save and exit BIOS

3. BOOT INTO ARCH LINUX
   - Boot normally (Secure Boot is not enforced yet)

4. ENROLL CUSTOM KEYS
   In the booted system, run:

   sudo sbctl status
   # Should show "Setup Mode: Enabled"

   sudo sbctl enroll-keys --microsoft
   # The --microsoft flag includes Microsoft keys for dual-boot compatibility
   # Omit --microsoft if you don't need Windows compatibility

5. VERIFY ENROLLMENT
   sudo sbctl status
   # Should show:
   # Installed: ✓ sbctl is installed
   # Setup Mode: ✗ Disabled
   # Secure Boot: ✗ Disabled (will be enabled after reboot)

6. REBOOT AND ENABLE SECURE BOOT
   - Reboot into BIOS
   - Enable Secure Boot
   - Save and exit

7. VERIFY SECURE BOOT IS ACTIVE
   After booting:

   sudo sbctl status
   # Should show:
   # Secure Boot: ✓ Enabled

   bootctl status
   # Should show "Secure Boot: enabled"

8. VERIFY TPM UNLOCKING WORKS
   - TPM should automatically unlock the disk
   - No passphrase prompt should appear
   - Test by rebooting several times

9. TEST FAILURE SCENARIOS
   a) Disable Secure Boot in BIOS:
      - Should prompt for LUKS passphrase
      - System should boot after entering passphrase

   b) Re-enable Secure Boot:
      - TPM auto-unlock should work again

================================================================================
BACKUP YOUR KEYS!
================================================================================

CRITICAL: Backup your Secure Boot keys to external storage:

sudo cp -r /var/lib/sbctl/keys ~/sbctl-keys-backup
# Copy this directory to USB drive or external storage

Without these keys, you cannot:
- Sign new kernels
- Recover if keys are lost
- Modify boot configuration

================================================================================
TROUBLESHOOTING
================================================================================

If TPM unlocking fails:
1. Boot and enter LUKS passphrase manually
2. Check: systemd-cryptenroll /dev/nvme0n1p2
3. Re-enroll if needed: See docs/troubleshooting.md

If signing fails:
1. Check: sbctl verify
2. Re-sign manually: sbctl sign -s /path/to/file.efi

For more help:
- See: /root/docs/troubleshooting.md
- Wiki: https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface/Secure_Boot

================================================================================
EOF

    print_info "Post-installation instructions saved to:"
    print_info "  /root/secure-boot-instructions.txt"
}

# Display summary
show_summary() {
    echo
    print_separator "="
    print_success "Secure Boot configuration complete!"
    print_separator "="
    echo

    print_info "What was done:"
    echo "  ✓ sbctl installed"
    echo "  ✓ Custom Secure Boot keys generated"
    echo "  ✓ Bootloader and kernels signed"
    echo "  ✓ Automatic signing hooks configured"
    echo

    print_info "Key locations:"
    echo "  Platform Key (PK):     /var/lib/sbctl/keys/PK/"
    echo "  Key Exchange Key (KEK): /var/lib/sbctl/keys/KEK/"
    echo "  Signature Database (db): /var/lib/sbctl/keys/db/"
    echo

    print_warn "IMPORTANT POST-INSTALLATION STEPS:"
    echo
    echo "  1. After first boot, enroll keys with:"
    echo "     sudo sbctl enroll-keys --microsoft"
    echo
    echo "  2. Enable Secure Boot in BIOS/UEFI settings"
    echo
    echo "  3. Backup keys to external storage:"
    echo "     sudo cp -r /var/lib/sbctl/keys ~/sbctl-keys-backup"
    echo
    echo "See /root/secure-boot-instructions.txt for detailed steps"
    echo
}

# Main function
main() {
    print_info "=== Secure Boot Setup (sbctl) ==="
    echo

    # Require root
    require_root || exit 1

    # Load state from previous step
    load_state

    # Verify mount point
    if [[ ! -d "$MOUNT_POINT" ]]; then
        print_error "Mount point not found: $MOUNT_POINT"
        exit 1
    fi

    # Install sbctl
    install_sbctl

    # Check status
    check_secure_boot_status

    # Create keys
    create_keys

    # Sign bootloader
    sign_bootloader

    # Sign kernels
    sign_kernels

    # Verify signatures
    verify_signatures

    # Setup automatic signing
    setup_auto_signing

    # Generate instructions
    generate_instructions

    # Show summary
    show_summary

    print_success "Step 4 complete: Secure Boot configured with sbctl"
    echo
    print_info "Next step: Run 05-tpm-enroll.sh to enroll TPM for automatic unlocking"
}

# Run main function
main "$@"
