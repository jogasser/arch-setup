#!/usr/bin/env bash
#
# Step 1: Disk Partitioning & LUKS Encryption Setup
#
# This script:
# - Selects target disk
# - Creates GPT partition table
# - Creates EFI system partition (1GB)
# - Creates LUKS2 encrypted root partition
# - Opens encrypted container
# - Creates filesystem
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/utils.sh
source "${SCRIPT_DIR}/utils.sh"

# Configuration
readonly EFI_SIZE="1G"
readonly LUKS_NAME="cryptroot"
readonly MOUNT_POINT="/mnt"

# State file to pass information to next scripts
readonly STATE_FILE="/tmp/arch-install-state"

# Save state for next scripts
save_state() {
    local key="$1"
    local value="$2"

    if [[ ! -f "$STATE_FILE" ]]; then
        touch "$STATE_FILE"
    fi

    # Remove existing key and append new value
    sed -i "/^${key}=/d" "$STATE_FILE"
    echo "${key}=${value}" >> "$STATE_FILE"
}

# Display available disks
show_available_disks() {
    print_info "Available disks:"
    echo
    lsblk -ndo NAME,SIZE,TYPE,MODEL | grep disk | while read -r line; do
        echo "  /dev/$line"
    done
    echo
}

# Select target disk
select_disk() {
    local disk

    while true; do
        show_available_disks

        prompt "Enter target disk (e.g., sda, nvme0n1)" disk

        # Add /dev/ prefix if not present
        if [[ ! "$disk" =~ ^/dev/ ]]; then
            disk="/dev/$disk"
        fi

        # Validate disk
        if ! validate_disk "$disk"; then
            print_error "Invalid disk: $disk"
            continue
        fi

        # Check if disk is in use
        if is_mounted "$disk"; then
            print_error "Disk $disk is currently mounted"
            if ! confirm "Force unmount and continue?" n; then
                continue
            fi
        fi

        # Show disk information
        echo
        print_info "Selected disk: $disk"
        lsblk "$disk"
        echo

        # Confirm selection
        print_warn "ALL DATA ON $disk WILL BE PERMANENTLY ERASED!"
        if confirm "Are you absolutely sure you want to continue?" n; then
            echo "$disk"
            return 0
        fi
    done
}

# Wipe disk signatures
wipe_disk() {
    local disk="$1"

    print_info "Wiping existing signatures on $disk..."

    # Unmount any mounted partitions
    for part in "${disk}"*; do
        [[ -b "$part" ]] && safe_unmount "$part" || true
    done

    # Close any open LUKS containers
    for mapper in /dev/mapper/*; do
        if [[ -b "$mapper" ]] && cryptsetup status "$mapper" 2>/dev/null | grep -q "$disk"; then
            local name
            name=$(basename "$mapper")
            print_info "Closing LUKS container: $name"
            cryptsetup luksClose "$name" || true
        fi
    done

    # Wipe filesystem and partition signatures
    wipefs --all --force "$disk" 2>/dev/null || true

    # Zero out first and last megabytes
    dd if=/dev/zero of="$disk" bs=1M count=1 status=none 2>/dev/null || true
    dd if=/dev/zero of="$disk" bs=1M seek=$(($(blockdev --getsize64 "$disk") / 1024 / 1024 - 1)) count=1 status=none 2>/dev/null || true

    print_success "Disk wiped successfully"
}

# Create partition table
create_partitions() {
    local disk="$1"

    print_info "Creating GPT partition table..."

    # Create GPT partition table
    parted -s "$disk" mklabel gpt

    # Create EFI system partition (1GB)
    print_info "Creating EFI system partition (${EFI_SIZE})..."
    parted -s "$disk" mkpart ESP fat32 1MiB "$EFI_SIZE"
    parted -s "$disk" set 1 esp on

    # Create root partition (remaining space)
    print_info "Creating root partition..."
    parted -s "$disk" mkpart primary "$EFI_SIZE" 100%

    # Wait for kernel to recognize partitions
    print_info "Waiting for partitions to settle..."
    sleep 2
    partprobe "$disk"
    sleep 1

    print_success "Partitions created successfully"
}

# Get partition device names
get_partition_names() {
    local disk="$1"
    local efi_part
    local root_part

    # Handle different naming schemes
    if [[ "$disk" =~ nvme|loop|mmcblk ]]; then
        efi_part="${disk}p1"
        root_part="${disk}p2"
    else
        efi_part="${disk}1"
        root_part="${disk}2"
    fi

    # Wait for partitions to appear
    wait_for_device "$efi_part" 10 || {
        print_error "EFI partition did not appear"
        return 1
    }

    wait_for_device "$root_part" 10 || {
        print_error "Root partition did not appear"
        return 1
    }

    echo "$efi_part $root_part"
}

# Format EFI partition
format_efi() {
    local efi_part="$1"

    print_info "Formatting EFI partition: $efi_part"
    mkfs.fat -F 32 -n ESP "$efi_part"

    print_success "EFI partition formatted"
}

# Setup LUKS encryption
setup_luks() {
    local root_part="$1"
    local passphrase

    print_info "Setting up LUKS2 encryption on $root_part"
    echo

    # Prompt for passphrase
    prompt_password "Enter encryption passphrase" passphrase

    print_info "Creating LUKS2 container (this may take a moment)..."

    # Create LUKS2 container
    echo -n "$passphrase" | cryptsetup luksFormat \
        --type luks2 \
        --cipher aes-xts-plain64 \
        --key-size 512 \
        --hash sha256 \
        --pbkdf argon2id \
        --use-random \
        "$root_part" -

    print_success "LUKS2 container created"

    # Open LUKS container
    print_info "Opening LUKS container as $LUKS_NAME..."
    echo -n "$passphrase" | cryptsetup luksOpen "$root_part" "$LUKS_NAME" -

    # Verify container is open
    if [[ ! -e "/dev/mapper/$LUKS_NAME" ]]; then
        print_error "Failed to open LUKS container"
        return 1
    fi

    print_success "LUKS container opened: /dev/mapper/$LUKS_NAME"
}

# Format root partition
format_root() {
    local luks_device="/dev/mapper/$LUKS_NAME"

    print_info "Formatting root partition: $luks_device"

    # Create ext4 filesystem
    mkfs.ext4 -L "ArchRoot" "$luks_device"

    print_success "Root partition formatted"
}

# Mount filesystems
mount_filesystems() {
    local efi_part="$1"
    local luks_device="/dev/mapper/$LUKS_NAME"

    print_info "Mounting filesystems..."

    # Create mount point
    ensure_dir "$MOUNT_POINT"

    # Mount root
    if ! is_mounted "$luks_device"; then
        mount "$luks_device" "$MOUNT_POINT"
        print_info "Mounted root: $luks_device -> $MOUNT_POINT"
    fi

    # Create and mount EFI partition
    local boot_dir="${MOUNT_POINT}/boot"
    ensure_dir "$boot_dir"

    if ! is_mounted "$efi_part"; then
        mount "$efi_part" "$boot_dir"
        print_info "Mounted EFI: $efi_part -> $boot_dir"
    fi

    print_success "Filesystems mounted"
}

# Display partition information
show_partition_info() {
    local disk="$1"
    local efi_part="$2"
    local root_part="$3"

    echo
    print_separator "="
    print_success "Disk partitioning complete!"
    print_separator "="
    echo

    print_info "Partition layout:"
    lsblk "$disk"
    echo

    print_info "UUID information:"
    echo "  EFI partition:  $(get_uuid "$efi_part")"
    echo "  LUKS container: $(luks_get_uuid "$root_part")"
    echo "  Root device:    /dev/mapper/$LUKS_NAME"
    echo

    print_info "Mount points:"
    echo "  /               -> /dev/mapper/$LUKS_NAME"
    echo "  /boot           -> $efi_part"
    echo
}

# Main function
main() {
    print_info "=== Disk Partitioning & LUKS Encryption Setup ==="
    echo

    # Require root
    require_root || exit 1

    # Select disk
    local disk
    disk=$(select_disk)

    # Wipe disk
    wipe_disk "$disk"

    # Create partitions
    create_partitions "$disk"

    # Get partition names
    read -r efi_part root_part <<< "$(get_partition_names "$disk")"
    print_info "Partitions: EFI=$efi_part, Root=$root_part"

    # Format EFI partition
    format_efi "$efi_part"

    # Setup LUKS encryption
    setup_luks "$root_part"

    # Format root filesystem
    format_root

    # Mount filesystems
    mount_filesystems "$efi_part"

    # Save state for next scripts
    save_state "DISK" "$disk"
    save_state "EFI_PART" "$efi_part"
    save_state "ROOT_PART" "$root_part"
    save_state "LUKS_NAME" "$LUKS_NAME"
    save_state "LUKS_UUID" "$(luks_get_uuid "$root_part")"
    save_state "MOUNT_POINT" "$MOUNT_POINT"

    # Show information
    show_partition_info "$disk" "$efi_part" "$root_part"

    print_success "Step 1 complete: Disk is partitioned, encrypted, and mounted"
}

# Run main function
main "$@"
