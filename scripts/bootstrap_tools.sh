#!/usr/bin/env bash
set -euo pipefail

# Zinit
ZINIT_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/zinit/zinit.git"
if [ ! -d "$ZINIT_HOME/.git" ]; then
    echo "Installing Zinit..."
    mkdir -p "$(dirname "$ZINIT_HOME")"
    git clone --depth=1 https://github.com/zdharma-continuum/zinit.git "$ZINIT_HOME"
else
    echo "Zinit already installed"
fi

echo "Installing Zinit plugins..."
ZINIT_HOME="$ZINIT_HOME" zsh -c '
    source "$ZINIT_HOME/zinit.zsh"
    zinit light zsh-users/zsh-syntax-highlighting
    zinit light zsh-users/zsh-completions
    zinit light zsh-users/zsh-autosuggestions
    zinit light Aloxaf/fzf-tab
'

# TPM (Tmux Plugin Manager)
if [ ! -d "$HOME/.tmux/plugins/tpm" ]; then
    echo "Installing TPM..."
    git clone --depth=1 https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
else
    echo "TPM already installed"
fi

"$HOME/.tmux/plugins/tpm/bin/install_plugins" || \
    echo "  Note: run prefix+I inside tmux to finish installing plugins"

# oh-my-posh is installed directly so legacy Homebrew taps cannot shadow it.
if ! command -v oh-my-posh &>/dev/null; then
    echo "Installing oh-my-posh..."
    curl -fsSL https://ohmyposh.dev/install.sh | bash -s -- -d "$HOME/.local/bin"
else
    echo "oh-my-posh already installed"
fi

# nvm, plus a default LTS release of Node.js (which includes npm)
NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    echo "Installing nvm..."
    nvm_checkout="$(mktemp -d "${TMPDIR:-/tmp}/nvm.XXXXXX")"
    trap 'rm -rf "$nvm_checkout"' EXIT
    git clone --branch v0.40.5 --depth=1 https://github.com/nvm-sh/nvm.git "$nvm_checkout"
    mkdir -p "$NVM_DIR"

    # Homebrew may leave these pointing into its Cellar after `brew uninstall nvm`.
    for nvm_file in nvm.sh nvm-exec bash_completion; do
        if [ -L "$NVM_DIR/$nvm_file" ] && [ ! -e "$NVM_DIR/$nvm_file" ]; then
            rm -f "$NVM_DIR/$nvm_file"
        fi
    done

    # Merge the manager into the existing data directory without removing versions or aliases.
    cp -R "$nvm_checkout"/. "$NVM_DIR"/
    rm -rf "$nvm_checkout"
    trap - EXIT
else
    echo "nvm already installed"
fi

# shellcheck disable=SC1091
source "$NVM_DIR/nvm.sh"
if [ "$(nvm version default)" = "N/A" ]; then
    echo "Installing the latest LTS release of Node.js..."
    nvm install --lts
    nvm alias default 'lts/*'
else
    echo "Default Node.js already installed ($(nvm version default))"
fi

# Linux-only: tools not available in apt
if [[ "$(uname)" != "Linux" ]]; then
    exit 0
fi

# eza (via official apt repo)
if ! command -v eza &>/dev/null; then
    echo "Installing eza..."
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://raw.githubusercontent.com/eza-community/eza/main/deb.asc \
        | sudo gpg --dearmor --yes -o /etc/apt/keyrings/gierens.gpg
    echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] https://deb.gierens.de stable main" \
        | sudo tee /etc/apt/sources.list.d/gierens.list
    sudo apt-get update -qq && sudo apt-get install -y eza
else
    echo "eza already installed"
fi

# zoxide
if ! command -v zoxide &>/dev/null; then
    echo "Installing zoxide..."
    curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh
else
    echo "zoxide already installed"
fi
