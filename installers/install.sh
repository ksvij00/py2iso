#!/bin/sh
# py2iso installer for macOS and Linux.
set -eu

REPO="https://github.com/ksvij00/py2iso.git"
FILE="bin/p2i.py"
DIR="${PY2ISO_HOME:-$HOME/py2iso}"
CMD="p2i"
BEGIN="# >>> py2iso >>>"
END="# <<< py2iso <<<"

# ─────────────────────────────────────────────
# Logo
# ─────────────────────────────────────────────

printf '\n'
printf '██████╗ ██╗   ██╗██████╗ ██╗███████╗ ██████╗\n'
printf '██╔══██╗╚██╗ ██╔╝╚════██╗██║██╔════╝██╔═══██╗\n'
printf '██████╔╝ ╚████╔╝  █████╔╝██║███████╗██║   ██║\n'
printf '██╔═══╝   ╚██╔╝  ██╔═══╝ ██║╚════██║██║   ██║\n'
printf '██║        ██║   ███████╗██║███████║╚██████╔╝\n'
printf '╚═╝        ╚═╝   ╚══════╝╚═╝╚══════╝ ╚═════╝\n'
printf '\n'

say() {
    printf '\033[1;32m[PY2ISO]\033[0m %s\n' "$*"
}

die() {
    printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
    exit 1
}

# ─────────────────────────────────────────────
# Requirements
# ─────────────────────────────────────────────

command -v git >/dev/null 2>&1 ||
    die "Git is required."

command -v python3 >/dev/null 2>&1 ||
    die "Python 3 is required."

python3 -c \
    'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' \
    >/dev/null 2>&1 ||
    die "Python 3.10 or newer is required."

# ─────────────────────────────────────────────
# Progress bar
# ─────────────────────────────────────────────

progress() {
    current=$1
    total=$2
    label=$3

    width=30
    filled=$((current * width / total))
    empty=$((width - filled))

    bar=$(printf '%*s' "$filled" '' | tr ' ' '#')
    rest=$(printf '%*s' "$empty" '' | tr ' ' '-')
    percent=$((current * 100 / total))

    printf '\r\033[1;32m[%s%s]\033[0m %3s%% %s' \
        "$bar" "$rest" "$percent" "$label"

    if [ "$current" -ge "$total" ]; then
        printf '\n'
    fi
}

# ─────────────────────────────────────────────
# Download
# ─────────────────────────────────────────────

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/py2iso.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' 0
trap 'exit 1' HUP INT TERM

progress 1 5 "Cloning repository"

if ! git clone --depth 1 "$REPO" "$TMP_DIR/repo" \
    >/dev/null 2>&1; then
    die "Clone failed. Check network access and repository visibility."
fi

[ -f "$TMP_DIR/repo/$FILE" ] ||
    die "$FILE not found in the repository."

# ─────────────────────────────────────────────
# Install
# ─────────────────────────────────────────────

progress 2 5 "Preparing installation"

mkdir -p "$DIR" ||
    die "Could not create installation directory."

cp "$TMP_DIR/repo/$FILE" "$DIR/p2i.py" \
    >/dev/null 2>&1 ||
    die "Could not install p2i.py."

chmod +x "$DIR/p2i.py" \
    >/dev/null 2>&1 ||
    die "Could not set executable permissions."

progress 3 5 "Configuring shell"

add_link() {
    rc=$1
    rc_tmp=""

    touch "$rc" ||
        die "Could not access $rc."

    if grep -qF "$BEGIN" "$rc"; then
        rc_tmp="$(mktemp "${TMPDIR:-/tmp}/py2iso-rc.XXXXXX")" ||
            die "Could not create temporary file."

        awk -v b="$BEGIN" -v e="$END" '
            $0 == b { inside = 1; next }
            $0 == e { inside = 0; next }
            !inside { print }
        ' "$rc" > "$rc_tmp"

        cat "$rc_tmp" > "$rc"
        rm -f "$rc_tmp"
    fi

    {
        printf '\n%s\n' "$BEGIN"
        printf '%s() { python3 "%s" "$@"; }\n' "$CMD" "$DIR/p2i.py"
        printf '%s\n' "$END"
    } >> "$rc" ||
        die "Could not update $rc."
}

# Select the appropriate shell configuration.
case "${SHELL:-}" in
    */zsh)
        RC="$HOME/.zshrc"
        ;;
    */bash)
        RC="$HOME/.bashrc"
        ;;
    *)
        if [ -f "$HOME/.zshrc" ] && [ ! -f "$HOME/.bashrc" ]; then
            RC="$HOME/.zshrc"
        else
            RC="$HOME/.bashrc"
        fi
        ;;
esac

add_link "$RC"

# Also configure the other shell if its configuration already exists.
case "$RC" in
    */.bashrc)
        [ ! -f "$HOME/.zshrc" ] || add_link "$HOME/.zshrc"
        ;;
    */.zshrc)
        [ ! -f "$HOME/.bashrc" ] || add_link "$HOME/.bashrc"
        ;;
esac

progress 4 5 "Loading configuration"

# Load the configured function into this installer shell.
. "$RC" >/dev/null 2>&1 || true

progress 5 5 "Installation complete"

printf '\n'
say "PY2ISO installed successfully."
say "Command: p2i"
printf '\n'

# ─────────────────────────────────────────────
# Attempt to load the command into the parent
# shell when sourced; otherwise explain the limit.
# ─────────────────────────────────────────────

case "${0##*/}" in
    sh|bash|zsh)
        ;;
esac

say "Run: . \"$RC\""
say "Try: p2i cook ./myproj"
printf '\n'
