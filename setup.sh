#!/bin/bash

PACKETMANAGER="pacman"
PARAMETER_PKG="-S --noconfirm"
CONFIG_DIR="$HOME/.config/"
XINITRC="$HOME/.xinitrc"
PACKAGES=('picom' 'kitty' 'i3' 'xterm' 'xorg' 'xorg-xinit' 'firefox')
echo "installing packages now...."
for e in "${PACKAGES[@]}"; do
	
	sudo $PACKETMANAGER $PARAMETER_PKG "$e"
done
echo "exec i3" > "$XINITRC"
startx
