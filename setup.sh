#!/bin/bash

PACKAGEMANAGER="pacman"
PARAMETER_PKG="-S --noconfirm"
XINITRC="$HOME/.xinitrc"
PACKAGES=(
    'i3' 'picom' 'kitty' 'rofi'
    'xorg' 'xorg-xinit' 'xterm'
    'firefox'
    'python-pywal' 'flameshot'
    'dex' 'xss-lock' 'network-manager-applet'
    'fastfetch' 'cava' 'btop' 'fcitx5'
)

echo "Installing packages..."
for e in "${PACKAGES[@]}"; do
    sudo $PACKAGEMANAGER $PARAMETER_PKG "$e"
done

echo "Deploying configs..."
cp -r .config/* "$HOME/.config/"

echo "Building and installing lockscreen..."
make -C lockscreen
sudo make -C lockscreen install

echo "exec i3" > "$XINITRC"

echo "Done. Run 'startx' to start i3."
