#!/bin/bash

# Function to detect hardware (if not already detected)
detect_hardware() {
    echo "--- Detecting Hardware ---"
    
    # Try to read hardware info from previous step
    if [ -f /hardware_info ]; then
        source /hardware_info
        echo "Using hardware info from installation"
    else
        # Fallback detection
        echo "Performing hardware detection..."
        
        # Detect CPU vendor
        if grep -qi "GenuineIntel" /proc/cpuinfo; then
            CPU_VENDOR="intel"
            CPU_MICROCODE="intel-ucode"
        elif grep -qi "AuthenticAMD" /proc/cpuinfo; then
            CPU_VENDOR="amd"
            CPU_MICROCODE="amd-ucode"
        else
            CPU_VENDOR="unknown"
            CPU_MICROCODE=""
        fi
        
        # Detect GPU vendor(s)
        GPU_VENDORS=()
        if lspci -nn | grep -qi "VGA.*NVIDIA\|3D.*NVIDIA"; then
            GPU_VENDORS+=("nvidia")
        fi
        if lspci -nn | grep -qi "VGA.*AMD\|VGA.*ATI"; then
            GPU_VENDORS+=("amd")
        fi
        if lspci -nn | grep -qi "VGA.*Intel"; then
            GPU_VENDORS+=("intel")
        fi
        
        # Determine kernel
        if [ -f /boot/initramfs-linux-lts.img ]; then
            KERNEL_CHOICE="lts"
            INITRAMFS_NAME="initramfs-linux-lts.img"
        else
            KERNEL_CHOICE="zen"
            INITRAMFS_NAME="initramfs-linux-zen.img"
        fi
    fi
    
    # Build GPU driver packages list
    GPU_DRIVER_PACKAGES=""
    
    if [[ " ${GPU_VENDORS[*]} " =~ " nvidia " ]]; then
        echo "NVIDIA GPU detected"
        
        # Ask about NVIDIA driver type
        echo
        echo "NVIDIA driver options:"
        echo "1) nvidia (stable, recommended)"
        echo "2) nvidia-dkms (dynamic kernel module, more compatible)"
        echo "3) nvidia-open (open-source kernel modules)"
        read -p "Select NVIDIA driver (1-3, default: 1): " NVIDIA_DRIVER_CHOICE
        
        case $NVIDIA_DRIVER_CHOICE in
            2)
                GPU_DRIVER_PACKAGES+="nvidia-dkms nvidia-utils nvidia-settings lib32-nvidia-utils "
                NVIDIA_DRIVER="nvidia-dkms"
                ;;
            3)
                GPU_DRIVER_PACKAGES+="nvidia-open nvidia-utils nvidia-settings lib32-nvidia-utils "
                NVIDIA_DRIVER="nvidia-open"
                ;;
            *)
                GPU_DRIVER_PACKAGES+="nvidia nvidia-utils nvidia-settings lib32-nvidia-utils "
                NVIDIA_DRIVER="nvidia"
                ;;
        esac
        
        # Additional NVIDIA tools
        GPU_DRIVER_PACKAGES+="cuda cudnn "
    fi
    
    if [[ " ${GPU_VENDORS[*]} " =~ " amd " ]]; then
        echo "AMD GPU detected"
        GPU_DRIVER_PACKAGES+="mesa vulkan-radeon lib32-mesa lib32-vulkan-radeon "
        
        # Ask about AMD ROCm
        read -p "Install AMD ROCm for GPU computing? (y/n): " INSTALL_ROCM
        if [[ "$INSTALL_ROCM" =~ ^[Yy]$ ]]; then
            GPU_DRIVER_PACKAGES+="rocm-hip-sdk rocm-opencl-runtime "
        fi
    fi
    
    if [[ " ${GPU_VENDORS[*]} " =~ " intel " ]]; then
        echo "Intel GPU detected"
        GPU_DRIVER_PACKAGES+="mesa vulkan-intel lib32-mesa lib32-vulkan-intel intel-media-driver "
        
        # For newer Intel GPUs (Arc)
        if lspci -nn | grep -qi "Arc\|DG2"; then
            echo "Intel Arc GPU detected, installing additional drivers"
            GPU_DRIVER_PACKAGES+="intel-compute-runtime "
        fi
    fi
    
    # If no GPU detected or only unknown
    if [ -z "$GPU_DRIVER_PACKAGES" ] && [ ${#GPU_VENDORS[@]} -eq 0 ]; then
        echo "No dedicated GPU detected or using unknown GPU"
        echo "Installing basic graphics drivers"
        GPU_DRIVER_PACKAGES="mesa lib32-mesa "
    fi
    
    echo "GPU driver packages: $GPU_DRIVER_PACKAGES"
}

# --- 0. USER CONFIGURATION ---
echo "--- Post-Installation Configuration ---"
echo

# Detect hardware
detect_hardware

# Get Wi-Fi credentials for permanent connection
read -p "Enter Wi-Fi SSID for permanent connection: " WIFI_SSID
read -s -p "Enter Wi-Fi Password: " WIFI_PASS
echo

# Get user account details
read -p "Enter desired username: " USERNAME
read -s -p "Enter password for $USERNAME: " USER_PASS
echo
read -p "Enter user's real name (optional, press Enter to skip): " REAL_NAME

# Ask if user wants to create a sudo group
echo
echo "Create sudo group? (y/n)"
read -p "This will allow members of this group to use sudo: " CREATE_SUDO_GROUP

if [[ "$CREATE_SUDO_GROUP" =~ ^[Yy]$ ]]; then
    read -p "Enter sudo group name (default: normies): " SUDO_GROUP
    SUDO_GROUP=${SUDO_GROUP:-normies}
else
    SUDO_GROUP=""
fi

# Ask about package selection
echo
echo "Select packages to install:"
echo "1) Full KDE Plasma desktop"
echo "2) Hyprland (Wayland compositor)"
echo "3) Both KDE and Hyprland (recommended)"
echo "4) Minimal (just base system)"
read -p "Enter choice (1-4): " PACKAGE_CHOICE

echo
echo "Install multimedia and development tools? (y/n)"
read -p "Includes pipewire, ffmpeg, git, go, etc.: " INSTALL_MULTIMEDIA

echo
echo "Install AUR packages via yay? (y/n)"
echo "Includes Steam, Firefox, Signal, Telegram, etc."
read -p "Note: This will take some time: " INSTALL_AUR

# --- 1. PERMANENT WI-FI CONNECTION ---
echo
echo "--- Setting up permanent Wi-Fi connection ---"
nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASS"

# --- 2. PERMISSIONS & USERS ---
echo
echo "--- Creating user account ---"

# Create sudo group if requested
if [[ -n "$SUDO_GROUP" ]]; then
    groupadd "$SUDO_GROUP"
    echo "%$SUDO_GROUP ALL=(ALL:ALL) ALL" >> /etc/sudoers
    echo "Created sudo group: $SUDO_GROUP"
fi

# Create user with optional real name
if [[ -n "$REAL_NAME" ]]; then
    useradd -m -G "$SUDO_GROUP" -s /usr/bin/bash -c "$REAL_NAME" "$USERNAME"
else
    useradd -m -G "$SUDO_GROUP" -s /usr/bin/bash "$USERNAME"
fi

# Set user password
echo "$USERNAME:$USER_PASS" | chpasswd
echo "Created user: $USERNAME"

# --- 3. MULTILIB & BASE-DEVEL ---
echo
echo "--- Enabling multilib repository ---"
sed -i '/\[multilib\]/,/Include/s/^#//' /etc/pacman.conf
pacman -Sy --noconfirm base-devel git

# --- 4. GUI & DRIVERS ---
if [[ "$PACKAGE_CHOICE" != "4" ]]; then
    echo
    echo "--- Installing desktop environment and drivers ---"
    
    # Common desktop packages
    DESKTOP_PACKAGES="alacritty"
    
    case $PACKAGE_CHOICE in
        1)
            # KDE Plasma only
            DESKTOP_PACKAGES+=" sddm plasma-meta kde-applications"
            ;;
        2)
            # Hyprland only
            DESKTOP_PACKAGES+=" hyprland"
            ;;
        3)
            # Both KDE and Hyprland
            DESKTOP_PACKAGES+=" sddm plasma-meta hyprland evince"
            ;;
        *)
            echo "Invalid choice, installing both KDE and Hyprland"
            DESKTOP_PACKAGES+=" sddm plasma-meta hyprland evince"
            ;;
    esac
    
    # Install desktop and GPU drivers
    pacman -S --noconfirm $DESKTOP_PACKAGES $GPU_DRIVER_PACKAGES
    
    # Configure SDDM for Wayland if we installed KDE
    if [[ "$PACKAGE_CHOICE" =~ ^[13]$ ]] || [[ "$PACKAGE_CHOICE" = "" ]]; then
        echo
        echo "--- Configuring SDDM for Wayland ---"
        mkdir -p /etc/sddm.conf.d/
        cat <<EOF > /etc/sddm.conf.d/10-wayland.conf
[General]
DisplayServer=wayland
GreeterEnvironment=QT_WAYLAND_SHELL_INTEGRATION=layer-shell

[Wayland]
CompositorCommand=kwin_wayland --drm --no-lockscreen --no-global-shortcuts --locale1
EOF
        systemctl enable sddm
    fi
    
    # Handle NVIDIA-specific configuration
    if [[ " ${GPU_VENDORS[*]} " =~ " nvidia " ]]; then
        echo
        echo "--- Configuring NVIDIA drivers ---"
        
        # Check for NVIDIA DRM kernel modesetting
        if [ -f /etc/modprobe.d/nvidia.conf ]; then
            echo "options nvidia-drm modeset=1" >> /etc/modprobe.d/nvidia.conf
        else
            echo "options nvidia-drm modeset=1" > /etc/modprobe.d/nvidia.conf
        fi
        
        # Regenerate initramfs for NVIDIA modules
        mkinitcpio -P
        
        # Ask about NVIDIA persistence mode
        read -p "Enable NVIDIA persistence mode? (Keeps GPU initialized when not in use) (y/n): " ENABLE_NVIDIA_PERSISTENCE
        if [[ "$ENABLE_NVIDIA_PERSISTENCE" =~ ^[Yy]$ ]]; then
            systemctl enable nvidia-persistenced
        fi
    fi
fi

# --- 5. MULTIMEDIA AND EXTRA PACKAGES ---
if [[ "$INSTALL_MULTIMEDIA" =~ ^[Yy]$ ]]; then
    echo
    echo "--- Installing multimedia packages ---"
    pacman -S --noconfirm pipewire pipewire-alsa pipewire-pulse \
        pipewire-jack wireplumber pavucontrol sof-firmware alsa-utils \
        gwenview gimp ffmpeg dolphin vlc tar tmux go wget curl
    
    # Install additional codecs based on GPU
    if [[ " ${GPU_VENDORS[*]} " =~ " nvidia " ]]; then
        echo "Installing NVIDIA accelerated codecs"
        pacman -S --noconfirm nvidia-codec-headers
    elif [[ " ${GPU_VENDORS[*]} " =~ " intel " ]]; then
        echo "Installing Intel accelerated codecs"
        pacman -S --noconfirm intel-media-sdk
    fi
fi

# --- 6. INSTALL YAY (AUR HELPER) ---
if [[ "$INSTALL_AUR" =~ ^[Yy]$ ]]; then
    echo
    echo "--- Installing yay AUR helper ---"
    
    # Install as the regular user
    sudo -u "$USERNAME" bash <<EOF
cd /home/$USERNAME
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si --noconfirm
EOF

    # --- 7. INSTALL AUR PACKAGES ---
    echo
    echo "--- Installing AUR packages ---"
    echo "This will take some time..."
    
    # Basic AUR packages
    sudo -u "$USERNAME" yay -S --noconfirm --answerdiff None --answerclean All \
        firefox torbrowser-launcher
    
    # GPU-specific AUR packages
    if [[ " ${GPU_VENDORS[*]} " =~ " nvidia " ]]; then
        echo "Installing NVIDIA-related AUR packages"
        sudo -u "$USERNAME" yay -S --noconfirm --answerdiff None --answerclean All \
            nvidia-container-toolkit
    fi
    
    # Ask about gaming packages
    echo
    read -p "Install gaming packages (Steam, Lutris, etc.)? (y/n): " INSTALL_GAMING
    if [[ "$INSTALL_GAMING" =~ ^[Yy]$ ]]; then
        GAMING_PACKAGES="steam protonup-qt lutris protontricks qbittorrent"
        
        # Add GPU-specific gaming tools
        if [[ " ${GPU_VENDORS[*]} " =~ " nvidia " ]]; then
            GAMING_PACKAGES+=" goverlay mangohud"
        fi
        
        sudo -u "$USERNAME" yay -S --noconfirm --answerdiff None --answerclean All $GAMING_PACKAGES
    fi
    
    # Ask about communication apps
    echo
    read -p "Install communication apps (Signal, Telegram, etc.)? (y/n): " INSTALL_COMMS
    if [[ "$INSTALL_COMMS" =~ ^[Yy]$ ]]; then
        sudo -u "$USERNAME" yay -S --noconfirm --answerdiff None --answerclean All \
            signal-desktop telegram-desktop vesktop
    fi
    
    # Ask about productivity tools
    echo
    read -p "Install productivity tools (Audacity, JDownloader, etc.)? (y/n): " INSTALL_PRODUCTIVITY
    if [[ "$INSTALL_PRODUCTIVITY" =~ ^[Yy]$ ]]; then
        sudo -u "$USERNAME" yay -S --noconfirm --answerdiff None --answerclean All \
            audacity jdownloader2
    fi
    
    # Ask about development/AI tools
    echo
    read -p "Install development/AI tools (Python, LM Studio)? (y/n): " INSTALL_DEV
    if [[ "$INSTALL_DEV" =~ ^[Yy]$ ]]; then
        sudo -u "$USERNAME" yay -S --noconfirm --answerdiff None --answerclean All \
            python311 python312 lmstudio
    fi
fi

# --- 8. FINAL SETUP ---
echo
echo "--- Final system configuration ---"

# Set up default shell for user
chsh -s /usr/bin/bash "$USERNAME"

# Enable essential services
systemctl enable NetworkManager

# Create a setup completion flag
echo "Setup completed on $(date)" > /etc/arch-setup-complete
echo "Hardware detected:" >> /etc/arch-setup-complete
echo "CPU: $CPU_VENDOR" >> /etc/arch-setup-complete
echo "GPU: ${GPU_VENDORS[*]}" >> /etc/arch-setup-complete
echo "Kernel: $KERNEL_CHOICE" >> /etc/arch-setup-complete

# Create hardware optimization script
cat <<EOF > /home/$USERNAME/optimize_hardware.sh
#!/bin/bash
echo "Hardware optimization for:"
echo "CPU: $CPU_VENDOR"
echo "GPU: ${GPU_VENDORS[*]}"

# CPU optimization
if [[ "$CPU_VENDOR" == "intel" ]]; then
    echo "For Intel CPU, consider installing:"
    echo "  intel-gpu-tools (for Intel GPU monitoring)"
    echo "  thermald (for thermal management)"
elif [[ "$CPU_VENDOR" == "amd" ]]; then
    echo "For AMD CPU, consider installing:"
    echo "  amdctl (for AMD CPU monitoring)"
    echo "  zenpower (for Zen CPU monitoring)"
fi

# GPU optimization
if [[ " ${GPU_VENDORS[*]} " =~ " nvidia " ]]; then
    echo "For NVIDIA GPU, you can:"
    echo "  Run 'nvidia-settings' to configure GPU"
    echo "  Check 'nvidia-smi' for GPU status"
fi
EOF

chmod +x /home/$USERNAME/optimize_hardware.sh
chown $USERNAME:$USERNAME /home/$USERNAME/optimize_hardware.sh

echo
echo "========================================"
echo "Installation finished!"
echo
echo "Summary:"
echo "- User account: $USERNAME"
echo "- CPU: $CPU_VENDOR"
echo "- GPU: ${GPU_VENDORS[*]}"
echo "- Kernel: $KERNEL_CHOICE"
if [[ -n "$SUDO_GROUP" ]]; then
    echo "- Sudo group: $SUDO_GROUP"
fi
if [[ "$PACKAGE_CHOICE" != "4" ]]; then
    echo "- Desktop environment installed"
fi
if [[ "$INSTALL_MULTIMEDIA" =~ ^[Yy]$ ]]; then
    echo "- Multimedia packages installed"
fi
if [[ "$INSTALL_AUR" =~ ^[Yy]$ ]]; then
    echo "- AUR packages installed"
fi
echo
echo "Hardware-specific drivers and optimizations have been applied."
echo "Check /home/$USERNAME/optimize_hardware.sh for additional optimization tips."
echo "========================================"

# Ask before rebooting
echo
read -p "Reboot now? (y/n): " REBOOT_NOW
if [[ "$REBOOT_NOW" =~ ^[Yy]$ ]]; then
    echo "Rebooting in 5 seconds..."
    sleep 5
    reboot
else
    echo "You can reboot manually with: sudo reboot"
fi
