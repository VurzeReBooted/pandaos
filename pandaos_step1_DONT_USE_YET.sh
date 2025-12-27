#!/bin/bash

# Function to detect hardware
detect_hardware() {
    echo "--- Detecting Hardware ---"
    
    # Detect CPU vendor
    if grep -qi "GenuineIntel" /proc/cpuinfo; then
        CPU_VENDOR="intel"
        CPU_MICROCODE="intel-ucode"
        echo "CPU detected: Intel"
    elif grep -qi "AuthenticAMD" /proc/cpuinfo; then
        CPU_VENDOR="amd"
        CPU_MICROCODE="amd-ucode"
        echo "CPU detected: AMD"
    else
        CPU_VENDOR="unknown"
        CPU_MICROCODE=""
        echo "CPU vendor unknown"
    fi
    
    # Detect GPU vendor(s)
    GPU_VENDORS=()
    GPU_DRIVERS=()
    
    if lspci -nn | grep -qi "VGA.*NVIDIA\|3D.*NVIDIA"; then
        GPU_VENDORS+=("nvidia")
        GPU_DRIVERS+=("nvidia" "nvidia-utils" "nvidia-settings" "lib32-nvidia-utils")
        echo "GPU detected: NVIDIA"
    fi
    
    if lspci -nn | grep -qi "VGA.*AMD\|VGA.*ATI\|VGA.*Advanced Micro Devices"; then
        GPU_VENDORS+=("amd")
        GPU_DRIVERS+=("mesa" "vulkan-radeon" "lib32-mesa" "lib32-vulkan-radeon")
        echo "GPU detected: AMD"
    fi
    
    if lspci -nn | grep -qi "VGA.*Intel"; then
        GPU_VENDORS+=("intel")
        GPU_DRIVERS+=("mesa" "vulkan-intel" "lib32-mesa" "lib32-vulkan-intel")
        echo "GPU detected: Intel"
    fi
    
    # Handle multiple GPUs (e.g., Intel + NVIDIA in laptops)
    if [ ${#GPU_VENDORS[@]} -gt 1 ]; then
        echo "Multiple GPUs detected: ${GPU_VENDORS[*]}"
        # For hybrid systems, prioritize discrete GPU
        if [[ " ${GPU_VENDORS[*]} " =~ " nvidia " ]]; then
            echo "Will install NVIDIA drivers for hybrid graphics"
        fi
    fi
    
    # Determine which kernel to install
    read -p "Install linux-zen kernel (recommended for desktop) or linux-lts (more stable)? (zen/lts): " KERNEL_CHOICE
    if [[ "$KERNEL_CHOICE" == "lts" ]]; then
        KERNEL_PACKAGES="linux-lts linux-lts-headers"
        INITRAMFS_NAME="initramfs-linux-lts.img"
    else
        KERNEL_PACKAGES="linux linux-zen linux-zen-headers"
        INITRAMFS_NAME="initramfs-linux-zen.img"
    fi
}

# --- 1. USER CONFIGURATION ---
echo "--- Arch Linux Setup Configuration ---"
echo

# Detect hardware first
detect_hardware

# Get Wi-Fi SSID
read -p "Enter Wi-Fi SSID: " WIFI_SSID

# Get Wi-Fi Password
read -s -p "Enter Wi-Fi Password: " WIFI_PASS
echo

# Get Root Password
read -s -p "Enter desired ROOT Password: " ROOT_PASS
echo

# Get Timezone
echo "Examples: America/Los_Angeles, Europe/London, Asia/Tokyo"
read -p "Enter your timezone: " TIMEZONE

# Get Disk to use
echo
echo "Available disks:"
lsblk
echo
echo "Examples: /dev/nvme0n1, /dev/sda, /dev/vda"
read -p "Enter the disk to install to (WARNING: This will erase all data on it!): " DISK

# Get Hostname
read -p "Enter desired hostname: " HOSTNAME

# Get Locale
echo "Common locales: en_US.UTF-8 UTF-8, en_GB.UTF-8 UTF-8, fr_FR.UTF-8 UTF-8"
read -p "Enter your locale (format: xx_XX.UTF-8 UTF-8): " LOCALE
LOCALE_CODE=$(echo $LOCALE | awk '{print $1}')

# Confirm installation
echo
echo "--- Installation Summary ---"
echo "CPU: $CPU_VENDOR (will install $CPU_MICROCODE)"
echo "GPU: ${GPU_VENDORS[*]}"
echo "Kernel: $KERNEL_CHOICE"
echo "Disk: $DISK"
echo "Hostname: $HOSTNAME"
echo "Timezone: $TIMEZONE"
echo
read -p "Proceed with installation? (y/n): " CONFIRM_INSTALL
if [[ ! "$CONFIRM_INSTALL" =~ ^[Yy]$ ]]; then
    echo "Installation cancelled."
    exit 0
fi

# --- 2. CONNECT TO INTERNET ---
echo
echo "--- Connecting to Wi-Fi ---"
iwctl station wlan0 scan
sleep 4
iwctl --passphrase "$WIFI_PASS" station wlan0 connect "$WIFI_SSID"
sleep 6

if ! ping -c 1 archlinux.org > /dev/null; then
    echo "Internet connection failed. Please check your Wi-Fi credentials."
    exit 1
fi
echo "Internet connection successful."

# --- 3. PREPARE ENVIRONMENT ---
loadkeys us
setfont ter-v18b
timedatectl set-timezone "$TIMEZONE"

# --- 4. DISK PARTITIONING ---
echo
echo "--- Partitioning disk $DISK ---"
echo "WARNING: This will erase all data on $DISK!"
read -p "Press Enter to continue or Ctrl+C to abort..."

# Clear existing partition table
wipefs -a "$DISK"

# Create new partition table and partitions
cat <<EOF | sfdisk "$DISK"
label: gpt
size=1GiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
size=100GiB, type=0657FD6D-A4AB-43C4-84E5-0933C84B4F4F
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
EOF

# Define partition names based on disk type
if [[ "$DISK" == *"nvme"* ]]; then
    EFI_PART="${DISK}p1"
    SWAP_PART="${DISK}p2"
    ROOT_PART="${DISK}p3"
else
    EFI_PART="${DISK}1"
    SWAP_PART="${DISK}2"
    ROOT_PART="${DISK}3"
fi

# --- 5. FORMAT AND MOUNT ---
echo "--- Formatting partitions ---"
mkfs.fat -F 32 -n "BOOT" "$EFI_PART"
mkswap -f -L "SWAP" "$SWAP_PART"
mkfs.btrfs -f -L "SYSTEM" "$ROOT_PART"

echo "--- Mounting partitions ---"
swapon "$SWAP_PART"
mount "$ROOT_PART" /mnt
mount --mkdir "$EFI_PART" /mnt/boot

# --- PRE-PACSTRAP CONFIG ---
mkdir -p /mnt/etc
echo "KEYMAP=us" > /mnt/etc/vconsole.conf

# --- 6. PACSTRAP ---
echo
echo "--- Installing base system ---"
pacman -Sy --noconfirm archlinux-keyring

# Base package list
BASE_PACKAGES="base $KERNEL_PACKAGES linux-firmware btrfs-progs \
e2fsprogs exfatprogs ntfs-3g networkmanager nano man-db man-pages \
texinfo git base-devel refind sudo"

# Add microcode based on CPU
if [ -n "$CPU_MICROCODE" ]; then
    BASE_PACKAGES="$BASE_PACKAGES $CPU_MICROCODE"
fi

pacstrap -K /mnt $BASE_PACKAGES

# --- 7. GENERATE FSTAB AND CHROOT ---
genfstab -U /mnt >> /mnt/etc/fstab

# Create hardware info file for post-install script
cat <<EOF > /mnt/hardware_info
CPU_VENDOR=$CPU_VENDOR
CPU_MICROCODE=$CPU_MICROCODE
GPU_VENDORS=${GPU_VENDORS[*]}
KERNEL_CHOICE=$KERNEL_CHOICE
INITRAMFS_NAME=$INITRAMFS_NAME
EOF

# Create the chroot script with user variables
cat <<EOF > /mnt/step2_chroot.sh
#!/bin/bash
# Source hardware info
if [ -f /hardware_info ]; then
    source /hardware_info
fi

# Set timezone
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Set locale
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
if [[ "$LOCALE" != "en_US.UTF-8 UTF-8" ]]; then
    echo "$LOCALE" >> /etc/locale.gen
fi
locale-gen
echo "LANG=$LOCALE_CODE" > /etc/locale.conf

# Set hostname
echo "$HOSTNAME" > /etc/hostname

# Enable NetworkManager
systemctl enable NetworkManager

# Set root password
echo "root:$ROOT_PASS" | chpasswd

# Ensure images are built correctly
mkinitcpio -P

# Install rEFInd
refind-install --usedefault "$EFI_PART"

# Generate rEFInd config with correct PARTUUID
PARTUUID=\$(blkid -s PARTUUID -o value "$ROOT_PART")
echo "\"Boot with standard options\" \"root=PARTUUID=\$PARTUUID rw rootflags=subvol=/ initrd=\\\\${CPU_MICROCODE}.img initrd=\\\\${INITRAMFS_NAME}\"" > /boot/refind_linux.conf

# Clean up
rm -f /hardware_info

exit
EOF

chmod +x /mnt/step2_chroot.sh
arch-chroot /mnt ./step2_chroot.sh

# --- 8. FINISH ---
echo
echo "--- Setup complete! ---"
umount -R /mnt
echo "Remove installation media and press Enter to reboot..."
read
reboot
