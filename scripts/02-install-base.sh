#!/usr/bin/env bash
#
# Step 2: Base System Installation
#
# This script:
# - Installs base Arch Linux system with pacstrap
# - Generates fstab
# - Sets timezone, locale, hostname
# - Configures basic system settings
# - Installs essential packages
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
        print_error "State file not found. Did you run 01-partition.sh first?"
        exit 1
    fi

    # shellcheck source=/dev/null
    source "$STATE_FILE"
}

# Update pacman mirrorlist
update_mirrorlist() {
    print_info "Updating pacman mirrorlist..."

    # Backup original mirrorlist
    cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup

    # Update mirrorlist using reflector if available
    if command_exists reflector; then
        print_info "Using reflector to find fastest mirrors..."
        reflector --country US,DE,FR,GB --age 12 --protocol https --sort rate \
                  --save /etc/pacman.d/mirrorlist
    else
        print_warn "reflector not found, using default mirrorlist"
    fi

    print_success "Mirrorlist updated"
}

# Install base system
install_base_system() {
    print_info "Installing base system with pacstrap..."
    echo
    print_info "This will take several minutes depending on network speed..."
    echo

    # Determine microcode package
    local microcode
    microcode=$(get_microcode_package) || microcode=""

    # Base packages
    local packages=(
        base
        base-devel
        linux
        linux-firmware
        "$microcode"
    )

    # Remove empty elements
    packages=("${packages[@]}")

    print_info "Installing: ${packages[*]}"

    # Run pacstrap
    if ! pacstrap -K "$MOUNT_POINT" "${packages[@]}"; then
        print_error "pacstrap failed"
        return 1
    fi

    print_success "Base system installed"
}

# Generate fstab
generate_fstab() {
    print_info "Generating fstab..."

    genfstab -U "$MOUNT_POINT" >> "${MOUNT_POINT}/etc/fstab"

    print_info "Generated fstab:"
    cat "${MOUNT_POINT}/etc/fstab"

    print_success "fstab generated"
}

# Configure timezone
configure_timezone() {
    print_info "Configuring timezone..."

    local timezone
    prompt "Enter timezone (e.g., America/New_York, Europe/Berlin)" timezone "UTC"

    # Validate timezone
    if [[ ! -f "${MOUNT_POINT}/usr/share/zoneinfo/${timezone}" ]]; then
        print_warn "Invalid timezone: $timezone, using UTC"
        timezone="UTC"
    fi

    # Set timezone in chroot
    chroot_cmd "ln -sf /usr/share/zoneinfo/${timezone} /etc/localtime"
    chroot_cmd "hwclock --systohc"

    print_success "Timezone set to: $timezone"
}

# Configure locale
configure_locale() {
    print_info "Configuring locale..."

    local locale
    prompt "Enter locale (e.g., en_US.UTF-8)" locale "en_US.UTF-8"

    # Uncomment locale in locale.gen
    local locale_gen="${MOUNT_POINT}/etc/locale.gen"
    if grep -q "^#${locale}" "$locale_gen"; then
        sed -i "s/^#${locale}/${locale}/" "$locale_gen"
    else
        # Add locale if not present
        echo "${locale} UTF-8" >> "$locale_gen"
    fi

    # Generate locales
    chroot_cmd "locale-gen"

    # Set system locale
    write_file "${MOUNT_POINT}/etc/locale.conf" "LANG=${locale}"

    print_success "Locale set to: $locale"
}

# Configure hostname
configure_hostname() {
    print_info "Configuring hostname..."

    local hostname
    prompt "Enter hostname" hostname "archlinux"

    # Set hostname
    write_file "${MOUNT_POINT}/etc/hostname" "$hostname"

    # Configure hosts file
    cat > "${MOUNT_POINT}/etc/hosts" <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${hostname}.localdomain ${hostname}
EOF

    print_success "Hostname set to: $hostname"
}

# Set root password
set_root_password() {
    print_info "Setting root password..."
    echo

    chroot_cmd "passwd"

    print_success "Root password set"
}

# Install essential packages
install_essential_packages() {
    print_info "Installing essential packages..."

    local packages=(
        # Networking
        networkmanager
        iwd
        dhcpcd

        # System utilities
        sudo
        vim
        nano
        git
        wget
        curl

        # Compression tools
        unzip
        zip
        tar
        gzip
        bzip2

        # File system tools
        dosfstools
        e2fsprogs
        ntfs-3g

        # Hardware tools
        usbutils
        pciutils
        sof-firmware

        # Man pages
        man-db
        man-pages
        texinfo
    )

    chroot_cmd "pacman -S --noconfirm --needed ${packages[*]}"

    print_success "Essential packages installed"
}

# Install cryptsetup and TPM tools
install_crypto_tools() {
    print_info "Installing cryptography and TPM tools..."

    local packages=(
        cryptsetup
        tpm2-tss
        tpm2-tools
    )

    chroot_cmd "pacman -S --noconfirm --needed ${packages[*]}"

    print_success "Crypto tools installed"
}

# Configure mkinitcpio hooks (for reference, dracut will be primary)
configure_mkinitcpio() {
    print_info "Configuring mkinitcpio as fallback..."

    local config="${MOUNT_POINT}/etc/mkinitcpio.conf"
    backup_file "$config"

    # Add TPM modules
    sed -i 's/^MODULES=.*/MODULES=(tpm_tis tpm_crb)/' "$config"

    # Update hooks for systemd-based initramfs
    sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' "$config"

    print_success "mkinitcpio configured"
}

# Enable essential services
enable_services() {
    print_info "Enabling essential services..."

    # NetworkManager for network connectivity
    chroot_cmd "systemctl enable NetworkManager"

    # systemd-timesyncd for time synchronization
    chroot_cmd "systemctl enable systemd-timesyncd"

    print_success "Services enabled"
}

# Create crypttab for automatic LUKS unlock
create_crypttab() {
    print_info "Creating crypttab configuration..."

    local crypttab="${MOUNT_POINT}/etc/crypttab"

    cat > "$crypttab" <<EOF
# <name>       <device>                                    <password>  <options>
${LUKS_NAME}   UUID=${LUKS_UUID}                           none        tpm2-device=auto,discard
EOF

    print_info "Created crypttab:"
    cat "$crypttab"

    print_success "crypttab configured"
}

# Display system information
show_system_info() {
    echo
    print_separator "="
    print_success "Base system installation complete!"
    print_separator "="
    echo

    print_info "Installed kernel:"
    chroot_cmd "pacman -Q linux"

    echo
    print_info "System configuration:"
    echo "  Timezone: $(readlink "${MOUNT_POINT}/etc/localtime" | sed 's|.*/zoneinfo/||')"
    echo "  Locale:   $(grep '^LANG=' "${MOUNT_POINT}/etc/locale.conf" | cut -d= -f2)"
    echo "  Hostname: $(cat "${MOUNT_POINT}/etc/hostname")"
    echo
}

# Main function
main() {
    print_info "=== Base System Installation ==="
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

    # Update mirrorlist
    update_mirrorlist

    # Install base system
    install_base_system

    # Generate fstab
    generate_fstab

    # Configure system
    configure_timezone
    configure_locale
    configure_hostname

    # Set root password
    set_root_password

    # Install essential packages
    install_essential_packages

    # Install crypto tools
    install_crypto_tools

    # Configure initramfs
    configure_mkinitcpio

    # Create crypttab
    create_crypttab

    # Enable services
    enable_services

    # Show information
    show_system_info

    print_success "Step 2 complete: Base system installed and configured"
    echo
    print_info "Next step: Run 03-setup-dracut.sh to configure initramfs"
}

# Run main function
main "$@"
