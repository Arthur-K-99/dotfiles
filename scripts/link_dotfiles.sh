#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

link() {
    local src="$1"
    local dst="$2"
    if [ -L "$dst" ]; then
        echo "  already linked: $dst"
    elif [ -e "$dst" ]; then
        echo "  backing up $dst -> $dst.bak"
        mv "$dst" "$dst.bak"
        ln -s "$src" "$dst"
        echo "  linked: $dst"
    else
        mkdir -p "$(dirname "$dst")"
        ln -s "$src" "$dst"
        echo "  linked: $dst"
    fi
}

echo "Linking dotfiles..."
link "$DOTFILES_DIR/home/.zshrc"     "$HOME/.zshrc"
link "$DOTFILES_DIR/home/.tmux.conf" "$HOME/.tmux.conf"
link "$DOTFILES_DIR/config/eza"      "$HOME/.config/eza"
