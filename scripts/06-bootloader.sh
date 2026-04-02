#!/usr/bin/env bash
#
# Step 6: systemd-boot Installation & Configuration
#
# This script:
# - Installs systemd-boot to the EFI system partition
# - Configures loader.conf
# - Verifies UKI detection
# - Signs the installed bootloader
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

# Verify prerequisites
verify_prerequisites() {
    print_info "Verifying prerequisites..."

    # Check if ESP is mounted
    if [[ ! -d "${MOUNT_POINT}/boot" ]]; then
        print_error "Boot directory not found: ${MOUNT_POINT}/boot"
        print_error "Is the ESP mounted?"
        return 1
    fi

    if ! mountpoint -q "${MOUNT_POINT}/boot" 2>/dev/null; then
        print_warn "ESP may not be mounted at ${MOUNT_POINT}/boot"
        print_info "Continuing anyway..."
    else
        print_success "ESP is mounted at ${MOUNT_POINT}/boot"
    fi

    # Check if UKI directory exists
    local uki_dir="${MOUNT_POINT}/boot/EFI/Linux"
    if [[ ! -d "$uki_dir" ]]; then
        print_warn "UKI directory not found: $uki_dir"
        print_info "Creating UKI directory..."
        mkdir -p "$uki_dir"
    fi

    # Check if UKI files exist
    local uki_count
    uki_count=$(find "$uki_dir" -name "*.efi" -type f 2>/dev/null | wc -l)
    if [[ $uki_count -eq 0 ]]; then
        print_warn "No UKI files found in $uki_dir"
        print_warn "Did you run 03-setup-dracut.sh?"
        print_info "systemd-boot will have no kernels to boot!"
    else
        print_success "Found $uki_count UKI file(s)"
    fi

    # Check if sbctl keys exist
    local keys_dir="${MOUNT_POINT}/var/lib/sbctl/keys"
    if [[ ! -d "$keys_dir" ]]; then
        print_warn "sbctl keys not found in $keys_dir"
        print_warn "Did you run 04-secure-boot.sh?"
        print_info "Bootloader files will not be signed"
    else
        print_success "sbctl keys found"
    fi

    # Check if systemd is installed (provides bootctl)
    if ! chroot_cmd "command -v bootctl" &>/dev/null; then
        print_error "bootctl not found in chroot"
        print_error "Is systemd installed?"
        return 1
    fi

    print_success "Prerequisites verified"
}

# Install systemd-boot
install_bootloader() {
    print_info "Installing systemd-boot to ESP..."

    if chroot_cmd "bootctl install"; then
        print_success "systemd-boot installed successfully"
    else
        print_error "Failed to install systemd-boot"
        return 1
    fi
}

# Configure systemd-boot
configure_bootloader() {
    print_info "Configuring systemd-boot loader.conf..."

    local loader_conf="${MOUNT_POINT}/boot/loader/loader.conf"

    # Create loader.conf
    # Since we are using UKI, we don't need entry files.
    # systemd-boot will automatically find UKIs in EFI/Linux/
    cat > "$loader_conf" <<EOF
# systemd-boot configuration
# UKIs in EFI/Linux/ are detected automatically

timeout 3
console-mode max
editor no
EOF

    print_success "loader.conf configured"
}

# Sign the installed bootloader
sign_installed_bootloader() {
    print_info "Signing installed bootloader files..."

    local signed_count=0
    local failed_count=0

    # Find all EFI binaries installed by bootctl
    # systemd-boot typically installs to:
    # - /boot/EFI/systemd/systemd-bootx64.efi
    # - /boot/EFI/BOOT/BOOTX64.EFI
    while IFS= read -r -d '' efi_file; do
        # Convert absolute path to relative path for chroot
        local rel_path="${efi_file#${MOUNT_POINT}}"

        print_info "Signing: $rel_path"
        if chroot_cmd "sbctl sign -s ${rel_path}"; then
            print_success "Signed: $rel_path"
            ((signed_count++))
        else
            print_warn "Failed to sign: $rel_path"
            ((failed_count++))
        fi
    done < <(find "${MOUNT_POINT}/boot/EFI" -name "*.efi" -type f -print0 2>/dev/null)

    if [[ $signed_count -eq 0 ]]; then
        print_warn "No bootloader files found to sign"
        print_info "Files will be signed automatically after generation"
    else
        print_success "Signed $signed_count bootloader file(s)"
        if [[ $failed_count -gt 0 ]]; then
            print_warn "$failed_count file(s) failed to sign"
        fi
    fi
}

# Verify bootloader status
verify_bootloader() {
    print_info "Verifying bootloader status..."
    echo

    if chroot_cmd "bootctl status" 2>/dev/null; then
        echo
    else
        print_warn "Could not verify bootloader status in chroot"
    fi

    # Check for UKI files
    print_info "Checking for UKI files in ESP..."
    local uki_dir="${MOUNT_POINT}/boot/EFI/Linux"
    if [[ -d "$uki_dir" ]]; then
        ls -lh "$uki_dir"/*.efi 2>/dev/null || print_warn "No UKI files found in $uki_dir"
    else
        print_warn "UKI directory not found: $uki_dir"
    fi
}

# Main function
main() {
    print_info "=== systemd-boot Installation ==="
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

    # Verify prerequisites
    verify_prerequisites || exit 1

    # Install bootloader
    install_bootloader

    # Configure bootloader
    configure_bootloader

    # Sign the installed binaries
    sign_installed_bootloader

    # Verify
    verify_bootloader

    print_success "Step 6 complete: systemd-boot installed and configured"
}

# Run main function
main "$@"
