#!/bin/sh
# py2iso installer for macOS and Linux.
set -eu

REPO="https://github.com/ksvij00/py2iso.git"
FILE="bin/p2i.py"
DIR="${PY2ISO_HOME:-$HOME/py2iso}"
CMD="p2i"
BEGIN="# >>> py2iso >>>"
END="# <<< py2iso <<<"

say() {
    printf '\033[1m==>\033[0m %s\n' "$*"
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

command -v git >/dev/null 2>&1 ||
    die "git is required"

command -v python3 >/dev/null 2>&1 ||
    die "python3 is required"

python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' ||
    die "Python 3.10 or newer is required"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/py2iso.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' 0

say "Cloning $REPO"

git clone --depth 1 "$REPO" "$TMP_DIR/repo" </dev/null ||
    die "Clone failed. Check network access and repository visibility."

[ -f "$TMP_DIR/repo/$FILE" ] ||
    die "$FILE not found in the repository"

mkdir -p "$DIR"
cp "$TMP_DIR/repo/$FILE" "$DIR/p2i.py"
chmod +x "$DIR/p2i.py"

say "Installed $DIR/p2i.py"

add_link() {
    rc=$1
    rc_tmp=
    touch "$rc"

    if grep -qF "$BEGIN" "$rc"; then
        rc_tmp="$(mktemp "${TMPDIR:-/tmp}/py2iso-rc.XXXXXX")" ||
            die "Could not create temporary file"

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
        printf '%s() { python3 "%s" "$@"; }\n' \
            "$CMD" "$DIR/p2i.py"
        printf '%s\n' "$END"
    } >> "$rc"

    say "Added '$CMD' to $rc"
}

first_target=

if [ -f "$HOME/.bashrc" ]; then
    add_link "$HOME/.bashrc"
    first_target="$HOME/.bashrc"
fi

if [ -f "$HOME/.zshrc" ]; then
    add_link "$HOME/.zshrc"

    if [ -z "$first_target" ]; then
        first_target="$HOME/.zshrc"
    fi
fi

if [ -z "$first_target" ]; then
    case "${SHELL:-}" in
        */zsh) first_target="$HOME/.zshrc" ;;
        *)     first_target="$HOME/.bashrc" ;;
    esac

    add_link "$first_target"
fi

say "Done. Open a new terminal or run: . \"$first_target\""
say "Try: $CMD cook ./myproj"
