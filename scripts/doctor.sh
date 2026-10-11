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

check_macos_app() {
    if dotfiles_macos_app_installed "$1"; then
        ok "$1.app"
    else
        fail "$1.app (rerun: bash scripts/install_packages.sh)"
    fi
}

check_mise_node() {
    local node_path
    if ! command -v mise >/dev/null 2>&1; then
        fail "Node.js via mise (mise is not installed)"
        return
    fi
    # A system Node.js must not hide a missing mise installation.
    if node_path="$(mise which node 2>/dev/null)" && [ -n "$node_path" ]; then
        ok "Node.js via mise ($node_path)"
    else
        fail "Node.js via mise (rerun: mise install)"
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
    check_readable "zsh-abbr" "$zinit_base/plugins/olets---zsh-abbr/zsh-abbr.plugin.zsh"
    check_readable "zsh-you-should-use" "$zinit_base/plugins/MichaelAquilina---zsh-you-should-use/you-should-use.plugin.zsh"
    if [ -x "$HOME/.tmux/plugins/tpm/bin/install_plugins" ]; then
        ok "TPM installer"
    else
        fail "TPM installer ($HOME/.tmux/plugins/tpm/bin/install_plugins)"
    fi
    check_readable "TPM" "$HOME/.tmux/plugins/tpm/tpm"
    check_readable "Catppuccin tmux theme" "$HOME/.tmux/plugins/tmux/catppuccin.tmux"
    local yazi_dir="${XDG_CONFIG_HOME:-$HOME/.config}/yazi"
    check_readable "yazi flavor catppuccin-macchiato" "$yazi_dir/flavors/catppuccin-macchiato.yazi/flavor.toml"
    check_readable "yazi flavor catppuccin-latte" "$yazi_dir/flavors/catppuccin-latte.yazi/flavor.toml"
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
    check_command carapace carapace
    check_command atuin atuin
    check_command mise mise
    check_command direnv direnv
    check_command vivid vivid
    check_command delta delta
    check_command lazygit lazygit
    check_command lazydocker lazydocker
    check_command yazi yazi
    check_command ya ya
    check_command ripgrep rg
    check_command fd fd fdfind
    check_command dust dust
    check_command duf duf
    check_command procs procs
    check_command sd sd
    check_command xh xh
    check_command hyperfine hyperfine
    check_command glow glow
    check_command tldr tldr
    check_command gum gum

    echo "Checking runtimes..."
    check_mise_node

    echo "Checking terminal capabilities..."
    check_terminfo tmux-256color
    check_bat_theme

    if [ "$(uname)" = "Darwin" ]; then
        echo "Checking font and terminal emulator..."
        check_macos_font
        check_macos_app Ghostty
    else
        echo "Nerd Font installation is manual on Linux; select it in your terminal after installation."
        echo "Ghostty has no Debian package; its configuration is linked for when it is installed."
    fi

    echo "Checking managed links..."
    check_link "$DOTFILES_DIR/home/.zshrc" "$HOME/.zshrc"
    check_link "$DOTFILES_DIR/home/.tmux.conf" "$HOME/.tmux.conf"
    check_link "$DOTFILES_DIR/config/eza" "$HOME/.config/eza"
    check_link "$DOTFILES_DIR/config/oh-my-posh/config.omp.json" "$HOME/.config/oh-my-posh/config.omp.json"
    check_link "$DOTFILES_DIR/config/bat/config" "$HOME/.config/bat/config"
    check_link "$DOTFILES_DIR/config/ghostty/config" "$HOME/.config/ghostty/config"
    check_link "$DOTFILES_DIR/config/git" "$HOME/.config/git"
    check_link "$DOTFILES_DIR/config/lazygit/config.yml" "$HOME/.config/lazygit/config.yml"
    check_link "$DOTFILES_DIR/config/yazi/yazi.toml" "$HOME/.config/yazi/yazi.toml"
    check_link "$DOTFILES_DIR/config/yazi/theme.toml" "$HOME/.config/yazi/theme.toml"
    check_link "$DOTFILES_DIR/config/atuin/config.toml" "$HOME/.config/atuin/config.toml"
    check_link "$DOTFILES_DIR/config/atuin/themes/catppuccin-macchiato-blue.toml" "$HOME/.config/atuin/themes/catppuccin-macchiato-blue.toml"
    check_link "$DOTFILES_DIR/config/mise/config.toml" "$HOME/.config/mise/config.toml"
    check_link "$DOTFILES_DIR/config/zsh-abbr/user-abbreviations" "$HOME/.config/zsh-abbr/user-abbreviations"
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
