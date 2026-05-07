#!/bin/bash

PACKAGEMANAGER="pacman"
PARAMETER_PKG="-S --noconfirm"
CONFIG_DIR="$HOME/.config/"
XINITRC="$HOME/.xinitrc"
PACKAGES=('picom' 'kitty' 'i3' 'xterm' 'xorg' 'xorg-xinit' 'firefox' 'rofi' 'fastfetch' 'cava' 'btop' 'fcitx5')
echo "installing packages now...."
for e in "${PACKAGES[@]}"; do
	
	sudo $PACKAGEMANAGER $PARAMETER_PKG "$e"
done
echo "exec i3" > "$XINITRC"
startx
