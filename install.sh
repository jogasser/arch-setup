#!/usr/bin/env bash
#
# Arch Linux Installation with TPM, Secure Boot & Full Disk Encryption
# Main orchestration script
#
# This script coordinates the complete installation process by calling
# individual installation scripts in the correct order.
#

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"

# Source utilities
# shellcheck source=scripts/utils.sh
source "${SCRIPTS_DIR}/utils.sh"

# Colors for output
readonly COLOR_RESET='\033[0m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_RED='\033[0;31m'

# Print banner
print_banner() {
    echo -e "${COLOR_BLUE}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║   Arch Linux Installation with TPM, Secure Boot & Encryption ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${COLOR_RESET}"
}

# Print section header
print_section() {
    local title="$1"
    echo
    echo -e "${COLOR_BLUE}═══════════════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "${COLOR_BLUE}  ${title}${COLOR_RESET}"
    echo -e "${COLOR_BLUE}═══════════════════════════════════════════════════════════${COLOR_RESET}"
    echo
}

# Print step
print_step() {
    local step="$1"
    local description="$2"
    echo -e "${COLOR_GREEN}[${step}]${COLOR_RESET} ${description}"
}

# Print warning
print_warning() {
    echo -e "${COLOR_YELLOW}WARNING:${COLOR_RESET} $1"
}

# Print error
print_error() {
    echo -e "${COLOR_RED}ERROR:${COLOR_RESET} $1"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

# Check if running in UEFI mode
check_uefi() {
    if [[ ! -d /sys/firmware/efi/efivars ]]; then
        print_error "System is not booted in UEFI mode"
        print_error "Please boot the installation media in UEFI mode"
        exit 1
    fi
}

# Check for TPM 2.0
check_tpm() {
    if [[ ! -e /sys/class/tpm/tpm0/tpm_version_major ]]; then
        print_error "TPM device not found"
        print_error "Please enable TPM in your BIOS/UEFI settings"
        exit 1
    fi

    local tpm_version
    tpm_version=$(cat /sys/class/tpm/tpm0/tpm_version_major)
    if [[ "$tpm_version" != "2" ]]; then
        print_error "TPM 2.0 required, found version: $tpm_version"
        exit 1
    fi
}

# Check internet connection
check_internet() {
    if ! ping -c 1 -W 2 archlinux.org &> /dev/null; then
        print_error "No internet connection detected"
        print_error "Please configure network before running this script"
        echo
        echo "For wireless: iwctl"
        echo "  [iwd]# station wlan0 connect \"SSID\""
        exit 1
    fi
}

# Check if Secure Boot is disabled
check_secure_boot() {
    if [[ -f /sys/firmware/efi/efivars/SecureBoot-* ]]; then
        local sb_enabled
        sb_enabled=$(od -An -t u1 /sys/firmware/efi/efivars/SecureBoot-* | awk '{print $NF}')
        if [[ "$sb_enabled" == "1" ]]; then
            print_warning "Secure Boot is currently enabled"
            print_warning "It should be disabled during installation"
            echo
            read -rp "Continue anyway? [y/N] " response
            if [[ ! "$response" =~ ^[Yy]$ ]]; then
                exit 1
            fi
        fi
    fi
}

# Verify all required scripts exist
verify_scripts() {
    local required_scripts=(
        "utils.sh"
        "01-partition.sh"
        "02-install-base.sh"
        "03-setup-dracut.sh"
        "04-secure-boot.sh"
        "05-tpm-enroll.sh"
        "06-bootloader.sh"
        "07-ui.sh"
    )

    for script in "${required_scripts[@]}"; do
        if [[ ! -f "${SCRIPTS_DIR}/${script}" ]]; then
            print_error "Required script not found: ${script}"
            exit 1
        fi
    done
}

# Display pre-installation checklist
show_checklist() {
    print_section "PRE-INSTALLATION CHECKLIST"

    echo "Before proceeding, ensure:"
    echo
    echo "  [1] You have backed up all important data"
    echo "  [2] You are booted from Arch Linux installation media"
    echo "  [3] System is booted in UEFI mode (checked automatically)"
    echo "  [4] TPM 2.0 is enabled in BIOS (checked automatically)"
    echo "  [5] Secure Boot is DISABLED temporarily in BIOS"
    echo "  [6] You have internet connection (checked automatically)"
    echo "  [7] You know which disk to install to"
    echo
    print_warning "This installation will ERASE the selected disk!"
    echo
    read -rp "Have you completed the checklist above? [y/N] " response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo "Installation cancelled"
        exit 0
    fi
}

# Show installation summary
show_summary() {
    print_section "INSTALLATION SUMMARY"

    echo "The following will be installed and configured:"
    echo
    echo "  • Arch Linux base system"
    echo "  • dracut initramfs with Unified Kernel Image (UKI)"
    echo "  • LUKS2 full disk encryption"
    echo "  • TPM 2.0 automatic unlocking (PCR 7 binding)"
    echo "  • Secure Boot with custom keys (sbctl)"
    echo "  • systemd-boot bootloader"
    echo "  • XFCE desktop environment with LightDM"
    echo
    echo "Installation steps:"
    echo
    echo "  [1/7] Partition disk and setup LUKS encryption"
    echo "  [2/7] Install base system with pacstrap"
    echo "  [3/7] Configure dracut initramfs"
    echo "  [4/7] Setup Secure Boot keys and signing"
    echo "  [5/7] Enroll TPM for automatic disk unlocking"
    echo "  [6/7] Install and configure systemd-boot"
    echo "  [7/7] Install desktop environment"
    echo
    read -rp "Proceed with installation? [y/N] " response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo "Installation cancelled"
        exit 0
    fi
}

# Run installation step
run_step() {
    local step_num="$1"
    local step_total="$2"
    local script_name="$3"
    local description="$4"

    print_section "STEP ${step_num}/${step_total}: ${description}"

    if [[ ! -f "${SCRIPTS_DIR}/${script_name}" ]]; then
        print_error "Script not found: ${script_name}"
        exit 1
    fi

    if ! bash "${SCRIPTS_DIR}/${script_name}"; then
        print_error "Step ${step_num} failed: ${description}"
        print_error "Check the error messages above for details"
        exit 1
    fi

    echo
    print_step "${step_num}/${step_total}" "Completed successfully"

    # Pause between steps for user to review
    if [[ "$step_num" != "$step_total" ]]; then
        echo
        read -rp "Press Enter to continue to next step..."
    fi
}

# Main installation function
main() {
    print_banner

    # Pre-flight checks
    print_section "SYSTEM CHECKS"

    print_step "✓" "Checking root privileges..."
    check_root

    print_step "✓" "Verifying UEFI mode..."
    check_uefi

    print_step "✓" "Detecting TPM 2.0..."
    check_tpm

    print_step "✓" "Checking internet connection..."
    check_internet

    print_step "✓" "Checking Secure Boot status..."
    check_secure_boot

    print_step "✓" "Verifying installation scripts..."
    verify_scripts

    echo
    print_step "✓" "All system checks passed"

    # Show checklist and get confirmation
    show_checklist
    show_summary

    # Execute installation steps
    echo
    echo "Starting installation..."
    sleep 2

    run_step 1 7 "01-partition.sh" "Disk Partitioning & LUKS Encryption"
    run_step 2 7 "02-install-base.sh" "Base System Installation"
    run_step 3 7 "03-setup-dracut.sh" "dracut Initramfs Configuration"
    run_step 4 7 "04-secure-boot.sh" "Secure Boot Setup (sbctl)"
    run_step 5 7 "05-tpm-enroll.sh" "TPM Key Enrollment"
    run_step 6 7 "06-bootloader.sh" "systemd-boot Installation"
    run_step 7 7 "07-ui.sh" "Desktop Environment Installation"

    # Installation complete
    print_section "INSTALLATION COMPLETE"

    echo -e "${COLOR_GREEN}✓ Arch Linux installation successful!${COLOR_RESET}"
    echo
    echo "Next steps:"
    echo
    echo "  1. Exit the installation environment:"
    echo "     $ exit"
    echo "     $ umount -R /mnt"
    echo "     $ reboot"
    echo
    echo "  2. In BIOS/UEFI settings:"
    echo "     • Enable Secure Boot"
    echo "     • Set to 'Setup Mode' or 'Custom Keys' if prompted"
    echo "     • Save and boot from the installed disk"
    echo
    echo "  3. On first boot:"
    echo "     • TPM should automatically unlock the disk"
    echo "     • Verify with: sbctl status"
    echo
    echo "  4. Test recovery:"
    echo "     • Disable Secure Boot in BIOS"
    echo "     • System should prompt for LUKS passphrase"
    echo "     • Re-enable Secure Boot"
    echo "     • TPM auto-unlock should work again"
    echo
    print_warning "IMPORTANT: Keep your LUKS passphrase and recovery key safe!"
    echo
    echo "Documentation:"
    echo "  • See docs/troubleshooting.md for common issues"
    echo "  • See docs/references.md for additional resources"
    echo
}

# Run main function
main "$@"
