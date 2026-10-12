#!/usr/bin/env bash

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/environment.sh
source "$DOTFILES_DIR/scripts/lib/environment.sh"
failures=0

ok() { printf '  [ok] %s\n' "$1"; }
fail() { printf '  [missing] %s\n' "$1"; failures=$((failures + 1)); }
stale() { printf '  [stale] %s\n' "$1"; failures=$((failures + 1)); }
skip() { printf '  [skip] %s\n' "$1"; }

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

# WSL draws its text with the Windows font, which install.ps1 installs.
check_linux_font() {
    if dotfiles_is_wsl; then
        skip "$DOTFILES_FONT_FAMILY (WSL uses the Windows font, which install.ps1 installs)"
    elif ! command -v fc-list >/dev/null 2>&1; then
        fail "$DOTFILES_FONT_FAMILY (fontconfig is not installed; rerun: bash scripts/install_packages.sh)"
    elif dotfiles_linux_font_installed; then
        ok "$DOTFILES_FONT_FAMILY"
    else
        fail "$DOTFILES_FONT_FAMILY (rerun: bash scripts/bootstrap_tools.sh)"
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

# A leftover file at a retired location would be loaded alongside the
# managed one.
check_absent() {
    if [ -e "$2" ] || [ -L "$2" ]; then
        stale "$1"
    else
        ok "no $2"
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
    local bat_command theme_name
    theme_name="$(dotfiles_bat_theme "$DOTFILES_DIR/config/bat/config")"
    for bat_command in bat batcat; do
        command -v "$bat_command" >/dev/null 2>&1 || continue
        if [ -n "$theme_name" ] && "$bat_command" --list-themes 2>/dev/null | grep -q -F -- "$theme_name"; then
            ok "bat theme ($theme_name)"
        else
            fail "bat theme ${theme_name:-(none named in config/bat/config)} (rerun: bash scripts/bootstrap_tools.sh)"
        fi
        return
    done
}

check_tree_sitter() {
    local version glibc record
    if ! command -v tree-sitter >/dev/null 2>&1; then
        # The bootstrap leaves out, and records, a release that needs a newer
        # glibc; the record holds only while this glibc is the one it names.
        if record="$(cat "$(dotfiles_tree_sitter_record)" 2>/dev/null)" && glibc="$(dotfiles_glibc_version)" && \
            [ "${record#* }" = "$glibc" ]; then
            skip "tree-sitter CLI (${record%% *} needs a newer glibc than $glibc; Neovim skips compiling parsers)"
            return
        fi
        fail "tree-sitter CLI $DOTFILES_TREE_SITTER_MINIMUM or newer (tree-sitter is not installed)"
        return
    fi
    # One that starts with a warning about a newer glibc hangs installing parsers.
    if dotfiles_tree_sitter_glibc_error >/dev/null; then
        fail "tree-sitter CLI is built for a newer glibc than this system's (rerun: bash scripts/bootstrap_tools.sh)"
        return
    fi
    if ! version="$(dotfiles_tree_sitter_version)"; then
        fail "tree-sitter CLI version (tree-sitter --version did not report one)"
    elif dotfiles_version_at_least "$version" "$DOTFILES_TREE_SITTER_MINIMUM"; then
        ok "tree-sitter CLI $version"
    else
        fail "tree-sitter CLI $version is older than $DOTFILES_TREE_SITTER_MINIMUM (Linux: rerun bash scripts/bootstrap_tools.sh)"
    fi
}

check_nvim_version() {
    local version
    if ! command -v nvim >/dev/null 2>&1; then
        fail "Neovim $DOTFILES_NVIM_MINIMUM or newer (nvim is not installed)"
        return
    fi
    if ! version="$(dotfiles_nvim_version)"; then
        fail "Neovim version (nvim --version did not report one)"
    elif dotfiles_version_at_least "$version" "$DOTFILES_NVIM_MINIMUM"; then
        ok "Neovim $version"
    else
        fail "Neovim $version is older than $DOTFILES_NVIM_MINIMUM (Linux: rerun bash scripts/bootstrap_tools.sh)"
    fi
}

# lazy.nvim itself, then a headless start of the linked configuration, then
# lua/dotfiles/bootstrap.lua's report: each plugin pinned in lazy-lock.json at
# its commit, and each parser and language server from lua/dotfiles/tools.lua
# (skipped where no compiler exists). Plugins are never fetched at startup
# (install.missing is off), so none of this reaches the network; a clean start
# prints nothing and leaves v:errmsg empty.
check_nvim_plugins() {
    local lazy_dir="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy"
    local output line
    # Without lazy.nvim a start would clone it, so the doctor stops here.
    if [ ! -r "$lazy_dir/lazy.nvim/lua/lazy/init.lua" ]; then
        fail "lazy.nvim ($lazy_dir/lazy.nvim; rerun: bash scripts/bootstrap_tools.sh)"
        return 0
    fi
    ok "lazy.nvim"
    command -v nvim >/dev/null 2>&1 || return 0
    if output="$(nvim --headless -c 'lua if vim.v.errmsg ~= "" then os.exit(3) end' +qa 2>&1)" && [ -z "$output" ]; then
        ok "Neovim starts without errors"
    else
        fail "Neovim headless start reported errors: ${output:-exit status $?}"
        return 0
    fi
    output="$(nvim --headless -c 'lua require("dotfiles.bootstrap").check()' -c 'cquit 1' 2>&1)" || :
    if [ -z "$output" ]; then
        fail "Neovim plugins, parsers and language servers (the check printed nothing)"
        return 0
    fi
    while IFS= read -r line; do
        case "$line" in
            "ok plugin "*) ok "Neovim plugin ${line#ok plugin }" ;;
            "ok parser "*) ok "Neovim parser ${line#ok parser }" ;;
            "ok package "*) ok "Neovim language server ${line#ok package }" ;;
            "missing plugin "*) fail "Neovim plugin ${line#missing plugin } (rerun: bash scripts/bootstrap_tools.sh)" ;;
            "stale plugin "*) stale "Neovim plugin ${line#stale plugin } is not at the commit lazy-lock.json pins (rerun: bash scripts/bootstrap_tools.sh)" ;;
            "missing parser "*) fail "Neovim parser ${line#missing parser } (rerun: bash scripts/bootstrap_tools.sh)" ;;
            "missing package "*) fail "Neovim language server ${line#missing package } (rerun: bash scripts/bootstrap_tools.sh)" ;;
            "skipped parser "*) skip "Neovim parser ${line#skipped parser }" ;;
            *) fail "Neovim check: $line" ;;
        esac
    done <<<"$output"
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
    # TPM installs plugins beside itself under the XDG tmux directory.
    local tmux_plugins="${XDG_CONFIG_HOME:-$HOME/.config}/tmux/plugins"
    if [ -x "$tmux_plugins/tpm/bin/install_plugins" ]; then
        ok "TPM installer"
    else
        fail "TPM installer ($tmux_plugins/tpm/bin/install_plugins)"
    fi
    check_readable "TPM" "$tmux_plugins/tpm/tpm"
    # Each plugin declared in config/tmux/tmux.conf, by the file TPM executes.
    for plugin in tmux-sensible/sensible.tmux vim-tmux-navigator/vim-tmux-navigator.tmux \
        tmux-yank/yank.tmux tmux-fzf/main.tmux tmux-floax/floax.tmux tmux/catppuccin.tmux \
        tmux-cpu/cpu.tmux tmux-battery/battery.tmux tmux-resurrect/resurrect.tmux \
        tmux-continuum/continuum.tmux; do
        case "$plugin" in
            tmux/*) check_readable "Catppuccin tmux theme" "$tmux_plugins/$plugin" ;;
            *) check_readable "tmux plugin ${plugin%%/*}" "$tmux_plugins/$plugin" ;;
        esac
    done
    local yazi_dir="${XDG_CONFIG_HOME:-$HOME/.config}/yazi"
    local flavor
    for flavor in $(dotfiles_yazi_flavors "$DOTFILES_DIR/config/yazi/theme.toml"); do
        check_readable "yazi flavor $flavor" "$yazi_dir/flavors/$flavor.yazi/flavor.toml"
    done
    check_nvim_plugins
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
    check_command sesh sesh
    check_command fastfetch fastfetch
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
    check_nvim_version
    check_tree_sitter

    echo "Checking terminal capabilities..."
    check_terminfo tmux-256color
    check_bat_theme

    if [ "$(uname)" = "Darwin" ]; then
        echo "Checking font and terminal emulator..."
        check_macos_font
        check_macos_app Ghostty
    else
        echo "Checking font..."
        check_linux_font
        echo "Ghostty has no Debian package; its configuration is linked for when it is installed."
    fi

    echo "Checking managed links..."
    check_link "$DOTFILES_DIR/home/.zshrc" "$HOME/.zshrc"
    check_link "$DOTFILES_DIR/config/tmux/tmux.conf" "$HOME/.config/tmux/tmux.conf"
    check_absent "~/.tmux.conf (tmux loads it as well as ~/.config/tmux/tmux.conf; move its contents and remove it)" "$HOME/.tmux.conf"
    check_link "$DOTFILES_DIR/config/eza" "$HOME/.config/eza"
    check_link "$DOTFILES_DIR/config/oh-my-posh/config.omp.json" "$HOME/.config/oh-my-posh/config.omp.json"
    check_link "$DOTFILES_DIR/config/bat/config" "$HOME/.config/bat/config"
    check_link "$DOTFILES_DIR/config/ghostty/config" "$HOME/.config/ghostty/config"
    check_link "$DOTFILES_DIR/config/git" "$HOME/.config/git"
    check_link "$DOTFILES_DIR/config/lazygit/config.yml" "$HOME/.config/lazygit/config.yml"
    check_link "$DOTFILES_DIR/config/yazi/yazi.toml" "$HOME/.config/yazi/yazi.toml"
    check_link "$DOTFILES_DIR/config/yazi/theme.toml" "$HOME/.config/yazi/theme.toml"
    check_link "$DOTFILES_DIR/config/atuin/config.toml" "$HOME/.config/atuin/config.toml"
    check_link "$DOTFILES_DIR/config/atuin/themes" "$HOME/.config/atuin/themes"
    check_link "$DOTFILES_DIR/config/fastfetch/config.jsonc" "$HOME/.config/fastfetch/config.jsonc"
    check_link "$DOTFILES_DIR/config/mise/config.toml" "$HOME/.config/mise/config.toml"
    check_link "$DOTFILES_DIR/config/zsh-abbr" "$HOME/.config/zsh-abbr"
    check_link "$DOTFILES_DIR/config/nvim" "$HOME/.config/nvim"
    check_readable "~/.gitconfig for identity (rerun: bash scripts/link_dotfiles.sh)" "$HOME/.gitconfig"
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
