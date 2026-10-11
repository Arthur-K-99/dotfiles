#!/usr/bin/env bash

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/environment.sh
source "$DOTFILES_DIR/scripts/lib/environment.sh"

bootstrap_zinit() {
    local zinit_home="${1:-${XDG_DATA_HOME:-$HOME/.local/share}/zinit/zinit.git}"
    if [ ! -r "$zinit_home/zinit.zsh" ]; then
        echo "Installing Zinit..."
        mkdir -p "$(dirname "$zinit_home")" || return
        git clone --depth=1 https://github.com/zdharma-continuum/zinit.git "$zinit_home" || return
    else
        echo "Zinit already installed"
    fi

    echo "Installing Zinit plugins..."
    ZINIT_HOME="$zinit_home" zsh -c '
        source "$ZINIT_HOME/zinit.zsh" || exit
        zinit light zsh-users/zsh-syntax-highlighting || exit
        zinit light zsh-users/zsh-completions || exit
        zinit light zsh-users/zsh-autosuggestions || exit
        zinit light Aloxaf/fzf-tab || exit
    '
}

bootstrap_tmux() (
    local tpm_dir="${1:-$HOME/.tmux/plugins/tpm}"
    local work_dir socket_path
    if [ ! -x "$tpm_dir/bin/install_plugins" ]; then
        echo "Installing TPM..."
        mkdir -p "$(dirname "$tpm_dir")" || return
        git clone --depth=1 https://github.com/tmux-plugins/tpm "$tpm_dir" || return
    else
        echo "TPM already installed"
    fi

    # TPM consults tmux's environment. A private, sessionless server avoids
    # altering existing user sessions and provides a stable installation path.
    work_dir="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-tmux.XXXXXX")" || return
    socket_path="$work_dir/socket"
    trap 'tmux -S "$socket_path" kill-server >/dev/null 2>&1 || :; rm -rf "$work_dir"' EXIT
    # TPM prefers an XDG config over ~/.tmux.conf. Point its read-only config
    # lookup at this repository so an unrelated user config cannot change it.
    mkdir -p "$work_dir/config/tmux" || return
    ln -s "$DOTFILES_DIR/home/.tmux.conf" "$work_dir/config/tmux/tmux.conf" || return
    tmux -S "$socket_path" -f /dev/null start-server \; \
        set-option -g exit-empty off \; \
        set-environment -g TMUX_PLUGIN_MANAGER_PATH "$(dirname "$tpm_dir")/" || return
    echo "Installing tmux plugins..."
    XDG_CONFIG_HOME="$work_dir/config" TMUX="$socket_path,0,0" "$tpm_dir/bin/install_plugins"
)

bootstrap_oh_my_posh() {
    if ! command -v oh-my-posh &>/dev/null; then
        echo "Installing oh-my-posh..."
        curl -fsSL https://ohmyposh.dev/install.sh | bash -s -- -d "$HOME/.local/bin"
    else
        echo "oh-my-posh already installed"
    fi
}

bootstrap_nvm() (
    local nvm_checkout nvm_file default_version
    if [ ! -s "$NVM_DIR/nvm.sh" ]; then
        echo "Installing nvm..."
        nvm_checkout="$(mktemp -d "${TMPDIR:-/tmp}/nvm.XXXXXX")" || return
        trap 'rm -rf "$nvm_checkout"' EXIT
        git clone --branch v0.40.5 --depth=1 https://github.com/nvm-sh/nvm.git "$nvm_checkout" || return
        mkdir -p "$NVM_DIR" || return

        # Preserve versions and aliases when replacing broken Homebrew links.
        for nvm_file in nvm.sh nvm-exec bash_completion; do
            if [ -L "$NVM_DIR/$nvm_file" ] && [ ! -e "$NVM_DIR/$nvm_file" ]; then
                rm -f "$NVM_DIR/$nvm_file" || return
            fi
        done
        cp -R "$nvm_checkout"/. "$NVM_DIR"/ || return
        rm -rf "$nvm_checkout" || return
        trap - EXIT
    else
        echo "nvm already installed"
    fi

    # Load the manager first; an absent default is expected on a fresh install.
    # shellcheck disable=SC1091
    source "$NVM_DIR/nvm.sh" --no-use || return
    if default_version="$(nvm version default)" && [ "$default_version" != "N/A" ]; then
        echo "Default Node.js already installed ($default_version)"
    else
        echo "Installing the latest LTS release of Node.js..."
        nvm install --lts || return
        nvm alias default 'lts/*' || return
    fi
    nvm use --silent default || return
)

install_eza() {
    if ! command -v eza &>/dev/null; then
        echo "Installing eza..."
        sudo mkdir -p /etc/apt/keyrings || return
        curl -fsSL https://raw.githubusercontent.com/eza-community/eza/main/deb.asc \
            | sudo gpg --dearmor --yes -o /etc/apt/keyrings/gierens.gpg || return
        echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] https://deb.gierens.de stable main" \
            | sudo tee /etc/apt/sources.list.d/gierens.list || return
        sudo apt-get update -qq || return
        sudo apt-get install -y eza || return
    else
        echo "eza already installed"
    fi
}

bootstrap_zoxide() {
    if ! command -v zoxide &>/dev/null; then
        echo "Installing zoxide..."
        curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh
    else
        echo "zoxide already installed"
    fi
}

bootstrap_bat_theme() {
    local bat_command theme_dir theme_file status
    local theme_name="Catppuccin Macchiato"
    local theme_url="https://raw.githubusercontent.com/catppuccin/bat/main/themes/Catppuccin%20Macchiato.tmTheme"
    if command -v bat &>/dev/null; then
        bat_command=bat
    elif command -v batcat &>/dev/null; then
        bat_command=batcat
    else
        echo "bat is not installed; install packages first." >&2
        return 1
    fi
    # bat 0.25+ ships the Catppuccin themes; older distribution packages need the file.
    if "$bat_command" --list-themes 2>/dev/null | grep -q "$theme_name"; then
        echo "bat theme already available"
        return 0
    fi
    echo "Installing bat theme ($theme_name)..."
    theme_dir="$("$bat_command" --config-dir)/themes" || return
    theme_file="$theme_dir/$theme_name.tmTheme"
    mkdir -p "$theme_dir" || return
    curl -fsSL -o "$theme_file.part" "$theme_url" || {
        status=$?
        rm -f "$theme_file.part"
        return "$status"
    }
    mv "$theme_file.part" "$theme_file" || return
    "$bat_command" cache --build >/dev/null || return
    if ! "$bat_command" --list-themes 2>/dev/null | grep -q "$theme_name"; then
        echo "bat does not list '$theme_name' after rebuilding its cache." >&2
        return 1
    fi
}

bootstrap_tools_main() {
    dotfiles_init_environment || return
    bootstrap_zinit || return
    bootstrap_tmux || return
    bootstrap_oh_my_posh || return
    bootstrap_nvm || return
    bootstrap_bat_theme || return

    if [ "$(uname)" = "Linux" ]; then
        install_eza || return
        bootstrap_zoxide || return
    fi
}

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
    set -euo pipefail
    bootstrap_tools_main "$@"
fi
