#!/usr/bin/env bash
set -u

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0

ok() { printf '  [ok] %s\n' "$1"; }
fail() { printf '  [missing] %s\n' "$1"; failures=$((failures + 1)); }

check_command() {
    local label="$1"
    shift
    local command_name
    for command_name in "$@"; do
        if command -v "$command_name" >/dev/null 2>&1; then
            ok "$label ($command_name)"
            return
        fi
    done
    fail "$label"
}

check_link() {
    local src="$1"
    local dst="$2"
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
        ok "$dst"
    else
        fail "$dst -> $src"
    fi
}

check_macos_font() {
    if compgen -G "$HOME/Library/Fonts/CaskaydiaCove*NerdFont*.ttf" >/dev/null || \
        compgen -G "$HOME/Library/Fonts/CaskaydiaCove*NerdFont*.otf" >/dev/null; then
        ok "CaskaydiaCove Nerd Font"
    else
        fail "CaskaydiaCove Nerd Font"
    fi
}

echo "Checking commands..."
check_command git git
check_command zsh zsh
check_command tmux tmux
check_command bat bat batcat
check_command eza eza
check_command fzf fzf
check_command zoxide zoxide
check_command btop btop
check_command neovim nvim
check_command gh gh
check_command oh-my-posh oh-my-posh

if [ "$(uname)" = "Darwin" ]; then
    echo "Checking font..."
    check_macos_font
fi

echo "Checking managed links..."
check_link "$DOTFILES_DIR/home/.zshrc" "$HOME/.zshrc"
check_link "$DOTFILES_DIR/home/.tmux.conf" "$HOME/.tmux.conf"
check_link "$DOTFILES_DIR/config/eza" "$HOME/.config/eza"
check_link "$DOTFILES_DIR/config/oh-my-posh/config.omp.json" "$HOME/.config/oh-my-posh/config.omp.json"

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) need attention."
    exit 1
fi

echo "All checks passed."
