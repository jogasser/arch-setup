#!/usr/bin/env bash
#
# Step 7: Desktop Environment Installation
#
# This script:
# - Installs XFCE desktop environment
# - Installs LightDM display manager with Slick Greeter
# - Configures LightDM
# - Enables display manager service
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

    # Check if mount point exists
    if [[ ! -d "$MOUNT_POINT" ]]; then
        print_error "Mount point not found: $MOUNT_POINT"
        return 1
    fi

    # Check if we can run commands in chroot
    if ! chroot_cmd "command -v pacman" &>/dev/null; then
        print_error "Cannot execute commands in chroot"
        return 1
    fi

    print_success "Prerequisites verified"
}

install_drivers() {
    print_info "Installing XFCE desktop environment..."

    local packages=(
        mesa
    )

    if chroot_cmd "pacman -S --noconfirm --needed ${packages[*]}"; then
        print_success "XFCE installed successfully"
    else
        print_error "Failed to install XFCE"
        return 1
    fi

}

# Install XFCE desktop environment
install_xfce() {
    print_info "Installing XFCE desktop environment..."

    local packages=(
        xfce4
        xfce4-goodies
    )

    if chroot_cmd "pacman -S --noconfirm --needed ${packages[*]}"; then
        print_success "XFCE installed successfully"
    else
        print_error "Failed to install XFCE"
        return 1
    fi
}

# Install LightDM and Slick Greeter
install_display_manager() {
    print_info "Installing LightDM display manager..."

    local packages=(
        lightdm
        lightdm-slick-greeter
    )

    if chroot_cmd "pacman -S --noconfirm --needed ${packages[*]}"; then
        print_success "LightDM and Slick Greeter installed successfully"
    else
        print_error "Failed to install LightDM"
        return 1
    fi
}

# Configure LightDM
configure_lightdm() {
    print_info "Configuring LightDM..."

    local lightdm_conf="${MOUNT_POINT}/etc/lightdm/lightdm.conf"
    local source_conf="${SCRIPT_DIR}/lightdm.conf"

    # Check if source config exists
    if [[ ! -f "$source_conf" ]]; then
        print_error "LightDM configuration file not found: $source_conf"
        return 1
    fi

    # Copy configuration
    if cp "$source_conf" "$lightdm_conf"; then
        print_success "LightDM configuration copied to $lightdm_conf"
    else
        print_error "Failed to copy LightDM configuration"
        return 1
    fi

    # Show configuration
    print_info "LightDM configuration:"
    echo
    cat "$lightdm_conf"
    echo
}

# Enable LightDM service
enable_services() {
    print_info "Enabling LightDM service..."

    if chroot_cmd "systemctl enable lightdm.service"; then
        print_success "LightDM service enabled"
    else
        print_error "Failed to enable LightDM service"
        return 1
    fi
}

# Show summary
show_summary() {
    print_separator "="
    print_success "Desktop Environment Installation Complete"
    print_separator "="
    echo
    print_info "Installed components:"
    echo "  • XFCE desktop environment"
    echo "  • LightDM display manager"
    echo "  • Slick Greeter"
    echo
    print_info "Configuration:"
    echo "  • LightDM configured with Slick Greeter"
    echo "  • Default session: XFCE"
    echo "  • Service: lightdm.service (enabled)"
    echo
    print_info "After reboot:"
    echo "  • LightDM will start automatically"
    echo "  • You will be greeted with a graphical login screen"
    echo "  • Log in with your user account to start XFCE"
    echo
    print_separator "="
}

# Main function
main() {
    print_info "=== Desktop Environment Installation ==="
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

    # Install Graphics Drivers
    install_drivers

    # Install XFCE
    install_xfce

    # Install display manager
    install_display_manager

    # Configure LightDM
    configure_lightdm

    # Enable services
    enable_services

    # Show summary
    show_summary

    print_success "Step 7 complete: Desktop environment installed and configured"
}

# Run main function
main "$@"
