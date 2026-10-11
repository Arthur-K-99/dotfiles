#!/usr/bin/env bash

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/environment.sh
source "$DOTFILES_DIR/scripts/lib/environment.sh"
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
    if [ -e "$src" ] && [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
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

check_nvm_default() {
    local default_version
    if [ ! -s "$NVM_DIR/nvm.sh" ]; then
        fail "nvm ($NVM_DIR/nvm.sh)"
        return
    fi
    # shellcheck disable=SC1091
    if ! source "$NVM_DIR/nvm.sh" --no-use || ! command -v nvm >/dev/null 2>&1; then
        fail "nvm could not be loaded"
        return
    fi
    ok "nvm"
    if default_version="$(nvm version default)" && [ "$default_version" != "N/A" ] && \
        nvm use --silent default >/dev/null 2>&1; then
        ok "default Node.js ($default_version)"
        check_command node node
        check_command npm npm
    else
        fail "nvm default Node.js (run: nvm install --lts && nvm alias default 'lts/*')"
    fi
}

check_readable() {
    if [ -r "$2" ]; then
        ok "$1"
    else
        fail "$1 ($2)"
    fi
}

check_terminfo() {
    if infocmp "$1" >/dev/null 2>&1; then
        ok "$1 terminfo"
    else
        fail "$1 terminfo (Linux: sudo apt-get install ncurses-term)"
    fi
}

check_bat_theme() {
    local bat_command
    for bat_command in bat batcat; do
        command -v "$bat_command" >/dev/null 2>&1 || continue
        if "$bat_command" --list-themes 2>/dev/null | grep -q "Catppuccin Macchiato"; then
            ok "bat theme (Catppuccin Macchiato)"
        else
            fail "bat theme Catppuccin Macchiato (rerun: bash scripts/bootstrap_tools.sh)"
        fi
        return
    done
}

check_plugins() {
    local zinit_base="${XDG_DATA_HOME:-$HOME/.local/share}/zinit"
    local plugin
    check_readable "Zinit" "$zinit_base/zinit.git/zinit.zsh"
    for plugin in zsh-syntax-highlighting zsh-completions zsh-autosuggestions; do
        check_readable "$plugin" "$zinit_base/plugins/zsh-users---$plugin/$plugin.plugin.zsh"
    done
    check_readable "fzf-tab" "$zinit_base/plugins/Aloxaf---fzf-tab/fzf-tab.plugin.zsh"
    if [ -x "$HOME/.tmux/plugins/tpm/bin/install_plugins" ]; then
        ok "TPM installer"
    else
        fail "TPM installer ($HOME/.tmux/plugins/tpm/bin/install_plugins)"
    fi
    check_readable "TPM" "$HOME/.tmux/plugins/tpm/tpm"
    check_readable "Catppuccin tmux theme" "$HOME/.tmux/plugins/tmux/catppuccin.tmux"
}

doctor_main() {
    failures=0
    if ! dotfiles_init_environment; then
        fail "Homebrew environment"
    fi
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
    check_nvm_default

    echo "Checking terminal capabilities..."
    check_terminfo tmux-256color
    check_bat_theme

    if [ "$(uname)" = "Darwin" ]; then
        echo "Checking font..."
        check_macos_font
    else
        echo "Nerd Font installation is manual on Linux; select it in your terminal after installation."
    fi

    echo "Checking managed links..."
    check_link "$DOTFILES_DIR/home/.zshrc" "$HOME/.zshrc"
    check_link "$DOTFILES_DIR/home/.tmux.conf" "$HOME/.tmux.conf"
    check_link "$DOTFILES_DIR/config/eza" "$HOME/.config/eza"
    check_link "$DOTFILES_DIR/config/oh-my-posh/config.omp.json" "$HOME/.config/oh-my-posh/config.omp.json"
    check_link "$DOTFILES_DIR/config/bat/config" "$HOME/.config/bat/config"
    echo "Checking plugins..."
    check_plugins

    if [ "$failures" -gt 0 ]; then
        echo "$failures check(s) need attention."
        return 1
    fi
    echo "All checks passed."
}

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
    set -uo pipefail
    doctor_main "$@"
fi
