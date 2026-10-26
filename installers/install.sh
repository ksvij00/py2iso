#!/usr/bin/env bash
# py2iso installer for macOS and Linux.
#   curl -fsSL https://raw.githubusercontent.com/ksvij00/py2iso/main/install.sh | bash
# Optional: PY2ISO_HOME=/some/dir  (default: ~/py2iso)
set -euo pipefail

REPO="https://github.com/ksvij00/py2iso.git"
FILE="bin/p2i.py"
DIR="${PY2ISO_HOME:-$HOME/py2iso}"
CMD="p2i"
BEGIN="# >>> py2iso >>>"
END="# <<< py2iso <<<"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || die "git is required (macOS: xcode-select --install | Debian/Ubuntu: sudo apt install git)"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' || die "Python 3.10 or newer is required"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say "Cloning $REPO"
git clone --depth 1 "$REPO" "$TMP/repo" </dev/null \
    || die "clone failed (while the repo is private, git asks for your GitHub username and a personal access token)"
[ -f "$TMP/repo/$FILE" ] || die "$FILE not found in the repository"

mkdir -p "$DIR"
cp "$TMP/repo/$FILE" "$DIR/p2i.py"
chmod +x "$DIR/p2i.py"
say "Installed $DIR/p2i.py"

add_link() {   # $1 = shell rc file; replaces an older py2iso block if present
    local rc="$1" tmp
    touch "$rc"
    if grep -qF "$BEGIN" "$rc"; then
        tmp="$(mktemp)"
        awk -v b="$BEGIN" -v e="$END" '$0==b{s=1} !s{print} $0==e{s=0}' "$rc" > "$tmp"
        cat "$tmp" > "$rc"
        rm -f "$tmp"
    fi
    {
        printf '\n%s\n' "$BEGIN"
        printf '%s() { python3 "%s" "$@"; }\n' "$CMD" "$DIR/p2i.py"
        printf '%s\n' "$END"
    } >> "$rc"
    say "Added '$CMD' to $rc"
}

targets=()
[ -f "$HOME/.bashrc" ] && targets+=("$HOME/.bashrc")
[ -f "$HOME/.zshrc" ] && targets+=("$HOME/.zshrc")
if [ "${#targets[@]}" -eq 0 ]; then
    case "${SHELL:-}" in
        */zsh) targets+=("$HOME/.zshrc") ;;
        *)     targets+=("$HOME/.bashrc") ;;
    esac
fi
for rc in "${targets[@]}"; do add_link "$rc"; done

say "Done. Open a new terminal (or run: source ${targets[0]}), then try:  $CMD cook ./myproj"
