#!/usr/bin/env bash
#
# setup.sh - Vergleicht IST-Zustand (Host) mit SOLL-Zustand (Repo).
#
#   ./setup.sh              Nur Bericht. Aendert nichts.
#   ./setup.sh apply        Repo -> Host: Pakete nach, Dotfiles als Symlink.
#   ./setup.sh sync         Host -> Repo: Paketlisten UND geaenderte Dotfiles.
#   ./setup.sh add <pfad>   Neue Datei ins Repo aufnehmen und verlinken.
#
#   -y   bei sync nicht nachfragen (fuer Cron/CI)
#
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ASSUME_YES=0
ARGS=()
for a in "$@"; do
    case "$a" in
        -y|--yes) ASSUME_YES=1 ;;
        *) ARGS+=("$a") ;;
    esac
done
MODE="${ARGS[0]:-check}"
ARGS=("${ARGS[@]:1}")

PKGLIST_REPO="$REPO_DIR/pkglist-repo.txt"
PKGLIST_AUR="$REPO_DIR/pkglist-aur.txt"
CONFIG_SRC="$REPO_DIR/.config"

# --- Ausgabe -----------------------------------------------------------
if [[ -t 1 ]]; then
    R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[34m'; D=$'\e[2m'; N=$'\e[0m'
else
    R=''; G=''; Y=''; B=''; D=''; N=''
fi

ok()      { printf '  %s+%s %s\n'  "$G" "$N" "$1"; }
miss()    { printf '  %s-%s %s\n'  "$R" "$N" "$1"; }
warn()    { printf '  %s!%s %s\n'  "$Y" "$N" "$1"; }
info()    { printf '  %s.%s %s\n'  "$D" "$N" "$1"; }
section() { printf '\n%s== %s%s\n' "$B" "$1" "$N"; }

DRIFT=0
mark_drift() { DRIFT=1; }

# --- Pakete ------------------------------------------------------------
check_packages() {
    section "Pakete"

    if [[ ! -f "$PKGLIST_REPO" ]]; then
        warn "pkglist-repo.txt fehlt im Repo - mit './setup.sh sync' erzeugen"
        mark_drift
        return
    fi

    local installed missing extra
    installed="$(pacman -Qqen | sort)"
    missing="$(comm -23 <(sort -u "$PKGLIST_REPO") <(echo "$installed"))"
    extra="$(comm -13 <(sort -u "$PKGLIST_REPO") <(echo "$installed"))"

    if [[ -n "$missing" ]]; then
        mark_drift
        printf '  %sFehlen auf dem Host (SOLL, nicht IST):%s\n' "$R" "$N"
        while read -r p; do [[ -n "$p" ]] && miss "$p"; done <<< "$missing"
    fi

    if [[ -n "$extra" ]]; then
        mark_drift
        printf '  %sAuf dem Host, aber nicht im Repo (IST, nicht SOLL):%s\n' "$Y" "$N"
        while read -r p; do [[ -n "$p" ]] && warn "$p"; done <<< "$extra"
    fi

    [[ -z "$missing" && -z "$extra" ]] && ok "Repo-Pakete deckungsgleich"

    # AUR getrennt - pacman kann die nicht installieren
    if [[ -f "$PKGLIST_AUR" ]]; then
        local aur_installed aur_missing
        aur_installed="$(pacman -Qqem | sort)"
        aur_missing="$(comm -23 <(sort -u "$PKGLIST_AUR") <(echo "$aur_installed"))"
        if [[ -n "$aur_missing" ]]; then
            mark_drift
            printf '  %sAUR fehlt (Helper noetig, kein pacman):%s\n' "$R" "$N"
            while read -r p; do [[ -n "$p" ]] && miss "$p"; done <<< "$aur_missing"
        fi
    fi
}

# --- Dotfiles ----------------------------------------------------------
# Vier Zustaende pro Datei:
#   symlink ins Repo  -> ideal, kein Drift moeglich
#   fehlt             -> muss verlinkt werden
#   Kopie, identisch  -> Kopie, aber inhaltsgleich
#   Kopie, abweichend -> der eigentliche Drift-Fall
check_dotfiles() {
    section "Dotfiles"

    if [[ ! -d "$CONFIG_SRC" ]]; then
        warn ".config/ fehlt im Repo"
        return
    fi

    local rel target diverged=0
    while IFS= read -r -d '' src; do
        rel="${src#"$REPO_DIR"/}"
        target="$HOME/$rel"

        if [[ -L "$target" ]] && [[ "$(readlink -f "$target")" == "$(readlink -f "$src")" ]]; then
            ok "$rel ${D}(symlink)${N}"
        elif [[ ! -e "$target" ]]; then
            mark_drift
            miss "$rel ${D}(fehlt auf dem Host)${N}"
        elif cmp -s "$src" "$target"; then
            mark_drift
            info "$rel ${D}(Kopie, inhaltsgleich - Symlink waere sicherer)${N}"
        else
            mark_drift
            diverged=1
            warn "$rel ${D}(WEICHT AB)${N}"
        fi
    done < <(find "$CONFIG_SRC" -type f -print0)

    if (( diverged )); then
        printf '\n  %sDiff ansehen:%s\n' "$D" "$N"
        printf '    diff -u %s/.config/<pfad> ~/.config/<pfad>\n' "$REPO_DIR"
    fi
}

# --- Umgebung ----------------------------------------------------------
# Faengt genau die Faelle ab, die einen stillen Fehlstart verursachen.
check_environment() {
    section "Umgebung"

    local st="${XDG_SESSION_TYPE:-unbekannt}"
    info "Session: $st / ${XDG_CURRENT_DESKTOP:-unbekannt}"

    if [[ "$st" == "x11" ]] && pgrep -x xdg-desktop-portal >/dev/null 2>&1; then
        local ini="$HOME/.config/flameshot/flameshot.ini"
        if command -v flameshot >/dev/null 2>&1 \
           && ! grep -qs 'useX11LegacyScreenshot=true' "$ini"; then
            mark_drift
            warn "flameshot: Portal laeuft unter X11 -> useX11LegacyScreenshot=true setzen"
        fi
    fi

    # Locale muss generiert sein, sonst faellt alles auf C zurueck
    if ! locale -a 2>/dev/null | grep -qi '^de_DE.utf8$'; then
        mark_drift
        warn "Locale de_DE.UTF-8 nicht generiert"
    fi

    # Wallpaper-Setter: ohne den faellt pywal auf imagemagick zurueck
    if command -v wal >/dev/null 2>&1 && ! command -v feh >/dev/null 2>&1; then
        mark_drift
        warn "pywal ohne feh - Wallpaper bleibt unter picom schwarz"
    fi

    # exec-Zeilen der i3-config gegen tatsaechlich vorhandene Binaries
    local cfg="$HOME/.config/i3/config" bin
    if [[ -f "$cfg" ]]; then
        while read -r bin; do
            [[ -z "$bin" ]] && continue
            command -v "$bin" >/dev/null 2>&1 || {
                mark_drift
                warn "i3-config startet '$bin' - nicht installiert"
            }
        done < <(grep -oP '^\s*exec(_always)?\s+(--no-startup-id\s+)?\K[\w.-]+' "$cfg" | sort -u)
    fi
}

# --- Aktionen ----------------------------------------------------------
do_apply() {
    section "Anwenden"

    if [[ -f "$PKGLIST_REPO" ]]; then
        local missing
        missing="$(comm -23 <(sort -u "$PKGLIST_REPO") <(pacman -Qqen | sort))"
        if [[ -n "$missing" ]]; then
            echo "  Installiere fehlende Pakete..."
            # shellcheck disable=SC2086
            sudo pacman -S --needed --noconfirm $missing
        fi
    fi

    echo "  Verlinke Dotfiles..."
    local rel target
    while IFS= read -r -d '' src; do
        rel="${src#"$REPO_DIR"/}"
        target="$HOME/$rel"
        mkdir -p "$(dirname "$target")"

        if [[ -e "$target" && ! -L "$target" ]]; then
            mv "$target" "$target.bak.$(date +%Y%m%d%H%M%S)"
            info "Backup: $rel"
        fi
        ln -sfn "$src" "$target"
    done < <(find "$CONFIG_SRC" -type f -print0)

    ok "Fertig. './setup.sh' zur Kontrolle."
}

do_sync() {
    section "Sync: Pakete"
    pacman -Qqen | sort > "$PKGLIST_REPO"
    pacman -Qqem | sort > "$PKGLIST_AUR"
    ok "pkglist-repo.txt: $(wc -l < "$PKGLIST_REPO") Pakete"
    ok "pkglist-aur.txt:  $(wc -l < "$PKGLIST_AUR") Pakete"

    section "Sync: Dotfiles"

    if [[ ! -d "$CONFIG_SRC" ]]; then
        warn ".config/ fehlt im Repo - nichts zu synchronisieren"
        return
    fi

    local rel target copied=0 skipped=0 answer interactive=0

    # Der Loop unten liest per Process-Substitution, damit ist stdin im
    # Schleifenkoerper die find-Pipe - nicht das Terminal. Also das echte
    # Terminal separat als FD 3 oeffnen und von dort lesen.
    if exec 3</dev/tty 2>/dev/null; then
        interactive=1
    fi

    while IFS= read -r -d '' src; do
        rel="${src#"$REPO_DIR"/}"
        target="$HOME/$rel"

        # Symlink ins Repo: eine Datei, kein Drift moeglich
        if [[ -L "$target" ]] && [[ "$(readlink -f "$target")" == "$(readlink -f "$src")" ]]; then
            continue
        fi

        # Host-Datei fehlt: das ist ein apply-Fall, nicht sync.
        # Wuerde man hier etwas tun, loeschte man Repo-Inhalt.
        if [[ ! -e "$target" ]]; then
            info "$rel ${D}(fehlt auf dem Host - uebersprungen, siehe apply)${N}"
            ((skipped++))
            continue
        fi

        cmp -s "$src" "$target" && continue

        # Ab hier: echter Drift. Host gewinnt - aber nicht blind.
        printf '\n  %s%s%s\n' "$Y" "$rel" "$N"
        if (( ASSUME_YES )); then
            answer="j"
        elif (( ! interactive )); then
            warn "kein Terminal und kein -y - uebersprungen"
            ((skipped++))
            continue
        else
            while true; do
                printf '    [j] uebernehmen  [n] ueberspringen  [d] diff  [q] abbrechen > '
                read -r answer <&3 || { answer="q"; printf '\n'; }
                case "${answer,,}" in
                    d) diff -u --color=auto "$src" "$target" | sed 's/^/      /' ;;
                    j|n|q) break ;;
                    *) ;;
                esac
            done
        fi

        case "${answer,,}" in
            q) warn "abgebrochen"; break ;;
            n) ((skipped++)); continue ;;
        esac

        cp -- "$target" "$src"
        ok "$rel ${D}(Host -> Repo)${N}"
        ((copied++))
    done < <(find "$CONFIG_SRC" -type f -print0)

    (( interactive )) && exec 3<&-

    printf '\n'
    ok "$copied uebernommen, $skipped uebersprungen"

    if (( copied )); then
        info "Aenderungen pruefen und committen:"
        printf '    git -C %s diff\n' "$REPO_DIR"
        printf '    git -C %s add -A && git -C %s commit -m "sync: Ist-Stand vom Host"\n' \
               "$REPO_DIR" "$REPO_DIR"
    fi
}

# Nimmt eine Datei NEU ins Repo auf, die es dort noch nicht gibt.
# Bewusst getrennt von sync: sync fasst nur an, was das Repo kennt.
do_add() {
    section "Neu ins Repo aufnehmen"

    (( $# )) || die_usage "add braucht mindestens einen Pfad"

    local target rel src
    for target in "$@"; do
        target="$(readlink -f -- "$target" 2>/dev/null || echo "$target")"

        if [[ ! -f "$target" ]]; then
            warn "$target - keine Datei"
            continue
        fi
        if [[ "$target" != "$HOME/"* ]]; then
            warn "$target - liegt nicht unter \$HOME"
            continue
        fi

        rel="${target#"$HOME"/}"
        src="$REPO_DIR/$rel"

        mkdir -p "$(dirname "$src")"
        cp -- "$target" "$src"
        ln -sfn "$src" "$target"
        ok "$rel ${D}(kopiert + verlinkt)${N}"
    done
}

die_usage() {
    printf '%sFEHLER:%s %s\n\n' "$R" "$N" "$1" >&2
    printf 'Nutzung: %s [check|apply|sync|add <pfad>...] [-y]\n' "$0" >&2
    exit 2
}

# --- Main --------------------------------------------------------------
printf '%sRepo:%s %s\n' "$D" "$N" "$REPO_DIR"

case "$MODE" in
    check)
        check_packages
        check_dotfiles
        check_environment
        section "Ergebnis"
        if (( DRIFT )); then
            printf '  %sIST weicht von SOLL ab.%s\n\n' "$Y" "$N"
            printf '    ./setup.sh apply   Repo -> Host (Repo gewinnt)\n'
            printf '    ./setup.sh sync    Host -> Repo (Host gewinnt)\n'
            exit 1
        fi
        ok "IST == SOLL"
        ;;
    apply) do_apply ;;
    sync)  do_sync ;;
    add)   do_add "${ARGS[@]+"${ARGS[@]}"}" ;;
    *)     die_usage "unbekannter Modus: $MODE" ;;
esac
