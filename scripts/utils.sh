#!/usr/bin/env bash
#
# Shared utility functions for Arch Linux installation scripts
#

# Prevent direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This script should be sourced, not executed directly"
    exit 1
fi

# Colors
readonly COLOR_RESET='\033[0m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_CYAN='\033[0;36m'

# Log levels
readonly LOG_DEBUG=0
readonly LOG_INFO=1
readonly LOG_WARN=2
readonly LOG_ERROR=3

# Default log level
LOG_LEVEL=${LOG_LEVEL:-$LOG_INFO}

# Print functions
print_info() {
    [[ $LOG_LEVEL -le $LOG_INFO ]] && echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET} $*"
}

print_success() {
    echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $*"
}

print_warn() {
    [[ $LOG_LEVEL -le $LOG_WARN ]] && echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*" >&2
}

print_error() {
    [[ $LOG_LEVEL -le $LOG_ERROR ]] && echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2
}

print_debug() {
    [[ $LOG_LEVEL -le $LOG_DEBUG ]] && echo -e "${COLOR_BLUE}[DEBUG]${COLOR_RESET} $*"
}

# Execute command with error handling
run_cmd() {
    local cmd="$*"
    print_debug "Running: $cmd"

    if ! eval "$cmd"; then
        print_error "Command failed: $cmd"
        return 1
    fi
    return 0
}

# Execute command silently
run_silent() {
    local cmd="$*"
    print_debug "Running: $cmd"

    if ! eval "$cmd" &> /dev/null; then
        print_error "Command failed: $cmd"
        return 1
    fi
    return 0
}

# Check if command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Check if running as root
require_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        return 1
    fi
    return 0
}

# Check if in chroot environment
is_chroot() {
    if [[ "$(stat -c %d:%i /)" != "$(stat -c %d:%i /proc/1/root/.)" ]]; then
        return 0  # In chroot
    fi
    return 1  # Not in chroot
}

# Get mount point (e.g., /mnt or /)
get_mount_point() {
    if is_chroot; then
        echo ""
    else
        echo "/mnt"
    fi
}

# Execute command in chroot if needed
chroot_cmd() {
    local mount_point
    mount_point=$(get_mount_point)

    if [[ -z "$mount_point" ]]; then
        # Already in chroot, run directly
        eval "$@"
    else
        # Not in chroot, use arch-chroot
        arch-chroot "$mount_point" bash -c "$*"
    fi
}

# Install packages (handles both chroot and non-chroot)
install_packages() {
    local packages=("$@")
    print_info "Installing packages: ${packages[*]}"

    if is_chroot; then
        pacman -S --noconfirm --needed "${packages[@]}"
    else
        chroot_cmd "pacman -S --noconfirm --needed ${packages[*]}"
    fi
}

# Prompt user for input
prompt() {
    local prompt_text="$1"
    local var_name="$2"
    local default="${3:-}"

    if [[ -n "$default" ]]; then
        read -rp "$prompt_text [$default]: " response
        response="${response:-$default}"
    else
        read -rp "$prompt_text: " response
    fi

    eval "$var_name=\"$response\""
}

# Prompt for confirmation (yes/no)
confirm() {
    local prompt_text="$1"
    local default="${2:-n}"

    local prompt_suffix
    if [[ "$default" == "y" ]]; then
        prompt_suffix="[Y/n]"
    else
        prompt_suffix="[y/N]"
    fi

    read -rp "$prompt_text $prompt_suffix " response
    response="${response:-$default}"

    [[ "$response" =~ ^[Yy]$ ]]
}

# Prompt for password (hidden input)
prompt_password() {
    local prompt_text="$1"
    local var_name="$2"

    local password
    local password_confirm

    while true; do
        read -rsp "$prompt_text: " password
        echo

        read -rsp "Confirm password: " password_confirm
        echo

        if [[ "$password" == "$password_confirm" ]]; then
            eval "$var_name=\"$password\""
            break
        else
            print_error "Passwords do not match. Please try again."
        fi
    done
}

# List block devices
list_block_devices() {
    lsblk -ndo NAME,SIZE,TYPE,TRAN | grep disk
}

# Get disk UUID
get_uuid() {
    local device="$1"
    blkid -s UUID -o value "$device"
}

# Get partition UUID
get_partuuid() {
    local device="$1"
    blkid -s PARTUUID -o value "$device"
}

# Wait for device to appear
wait_for_device() {
    local device="$1"
    local timeout="${2:-10}"
    local count=0

    while [[ ! -e "$device" ]] && [[ $count -lt $timeout ]]; do
        sleep 1
        ((count++))
    done

    if [[ ! -e "$device" ]]; then
        print_error "Device $device did not appear after ${timeout}s"
        return 1
    fi

    return 0
}

# Check if device is mounted
is_mounted() {
    local device="$1"
    grep -qs "$device" /proc/mounts
}

# Safely unmount device
safe_unmount() {
    local mount_point="$1"

    if is_mounted "$mount_point"; then
        print_info "Unmounting $mount_point"
        umount -R "$mount_point" 2>/dev/null || {
            print_warn "Failed to unmount $mount_point"
            return 1
        }
    fi
    return 0
}

# Check if LUKS device
is_luks() {
    local device="$1"
    cryptsetup isLuks "$device" 2>/dev/null
}

# Open LUKS device
luks_open() {
    local device="$1"
    local name="$2"

    if ! is_luks "$device"; then
        print_error "$device is not a LUKS device"
        return 1
    fi

    if [[ -e "/dev/mapper/$name" ]]; then
        print_info "LUKS device already opened: $name"
        return 0
    fi

    print_info "Opening LUKS device: $device"
    cryptsetup luksOpen "$device" "$name"
}

# Close LUKS device
luks_close() {
    local name="$1"

    if [[ -e "/dev/mapper/$name" ]]; then
        print_info "Closing LUKS device: $name"
        cryptsetup luksClose "$name"
    fi
}

# Get LUKS device UUID
luks_get_uuid() {
    local device="$1"
    cryptsetup luksUUID "$device"
}

# Check if TPM 2.0 is available
has_tpm2() {
    [[ -e /dev/tpm0 ]] && \
    [[ -e /sys/class/tpm/tpm0/tpm_version_major ]] && \
    [[ "$(cat /sys/class/tpm/tpm0/tpm_version_major)" == "2" ]]
}

# Get TPM device path
get_tpm_device() {
    if has_tpm2; then
        echo "/dev/tpm0"
    else
        print_error "TPM 2.0 not found"
        return 1
    fi
}

# Check if running in UEFI mode
is_uefi() {
    [[ -d /sys/firmware/efi/efivars ]]
}

# Get CPU vendor
get_cpu_vendor() {
    local vendor
    vendor=$(grep -m1 "vendor_id" /proc/cpuinfo | awk '{print $3}')

    case "$vendor" in
        GenuineIntel)
            echo "intel"
            ;;
        AuthenticAMD)
            echo "amd"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# Get microcode package name
get_microcode_package() {
    local vendor
    vendor=$(get_cpu_vendor)

    case "$vendor" in
        intel)
            echo "intel-ucode"
            ;;
        amd)
            echo "amd-ucode"
            ;;
        *)
            print_warn "Unknown CPU vendor, skipping microcode"
            return 1
            ;;
    esac
}

# Generate random string
random_string() {
    local length="${1:-32}"
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length"
}

# Create directory with parents
ensure_dir() {
    local dir="$1"
    local perms="${2:-755}"

    if [[ ! -d "$dir" ]]; then
        print_debug "Creating directory: $dir"
        mkdir -p "$dir"
        chmod "$perms" "$dir"
    fi
}

# Backup file if it exists
backup_file() {
    local file="$1"
    local backup="${file}.backup.$(date +%Y%m%d_%H%M%S)"

    if [[ -f "$file" ]]; then
        print_info "Backing up: $file -> $backup"
        cp "$file" "$backup"
    fi
}

# Write content to file
write_file() {
    local file="$1"
    local content="$2"
    local perms="${3:-644}"

    print_debug "Writing file: $file"
    echo "$content" > "$file"
    chmod "$perms" "$file"
}

# Append content to file
append_file() {
    local file="$1"
    local content="$2"

    print_debug "Appending to file: $file"
    echo "$content" >> "$file"
}

# Check if string contains substring
contains() {
    local string="$1"
    local substring="$2"
    [[ "$string" == *"$substring"* ]]
}

# Trim whitespace
trim() {
    local var="$1"
    # Remove leading whitespace
    var="${var#"${var%%[![:space:]]*}"}"
    # Remove trailing whitespace
    var="${var%"${var##*[![:space:]]}"}"
    echo "$var"
}

# Sleep with countdown
sleep_countdown() {
    local seconds="$1"
    local message="${2:-Continuing in}"

    for ((i=seconds; i>0; i--)); do
        echo -ne "\r$message $i seconds... "
        sleep 1
    done
    echo -e "\r${message} now!           "
}

# Print separator line
print_separator() {
    local char="${1:--}"
    local length="${2:-60}"
    printf '%*s\n' "$length" | tr ' ' "$char"
}

# Check minimum disk size
check_disk_size() {
    local device="$1"
    local min_size_gb="${2:-20}"

    local size_bytes
    size_bytes=$(blockdev --getsize64 "$device")
    local size_gb=$((size_bytes / 1024 / 1024 / 1024))

    if [[ $size_gb -lt $min_size_gb ]]; then
        print_error "Disk $device is too small: ${size_gb}GB (minimum: ${min_size_gb}GB)"
        return 1
    fi

    print_info "Disk size: ${size_gb}GB"
    return 0
}

# Validate disk device
validate_disk() {
    local device="$1"

    if [[ ! -b "$device" ]]; then
        print_error "Not a block device: $device"
        return 1
    fi

    if [[ ! "$device" =~ ^/dev/(sd|nvme|vd) ]]; then
        print_error "Invalid disk device: $device"
        return 1
    fi

    return 0
}

# Export functions for use in other scripts
export -f print_info print_success print_warn print_error print_debug
export -f run_cmd run_silent command_exists require_root
export -f is_chroot get_mount_point chroot_cmd install_packages
export -f prompt confirm prompt_password
export -f list_block_devices get_uuid get_partuuid wait_for_device
export -f is_mounted safe_unmount
export -f is_luks luks_open luks_close luks_get_uuid
export -f has_tpm2 get_tpm_device is_uefi
export -f get_cpu_vendor get_microcode_package
export -f random_string ensure_dir backup_file write_file append_file
export -f contains trim sleep_countdown print_separator
export -f check_disk_size validate_disk
