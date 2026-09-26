# i3-dotfiles

My personal i3 dotfiles for Arch Linux.

## Setup

`setup.sh` compares the host (actual state) with the repo (target state).
Run it from inside the repo directory:

```bash
./setup.sh              # report only, changes nothing
./setup.sh apply        # repo -> host: install missing packages, copy dotfiles
./setup.sh sync         # host -> repo: update package lists and changed dotfiles
./setup.sh add <path>   # copy a new file from $HOME into the repo
```

`-y` skips the prompts during `sync` (for cron/CI).

- Managed dotfiles: everything under `.config/` and `.local/bin/`
- Dotfiles are plain copies on the host, never symlinks
- `apply` backs up differing files as `<file>.bak.<timestamp>` before copying
- Package lists: `pkglist-repo.txt` (pacman), `pkglist-aur.txt` (AUR)
- AUR packages are **not** installed by `apply`, use an AUR helper:

```bash
yay -S --needed - < pkglist-aur.txt
```

## After install

1. Add wallpapers to `~/wallpaper/`
2. Generate color theme: `wal -i ~/wallpaper/`
3. Start i3: `startx`

## What's included

- i3 — window manager
- i3status — status bar
- kitty — terminal
- rofi — app launcher
- fastfetch — system info
- fcitx5 — input method
- lock — `~/.local/bin/lock`, i3lock-color with blur, clock and pywal colors

## Lockscreen

`~/.local/bin/lock` needs **i3lock-color** (plain `i3lock` lacks the options)
and the *JetBrainsMono Nerd Font*. Without pywal colors it uses built-in fallbacks.

- `$mod+l` — lock manually
- `xss-lock` — locks automatically before suspend (plain `i3lock --nofork`, without the styling)
