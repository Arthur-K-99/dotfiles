#!/usr/bin/env bash
set -euo pipefail

# TPM (Tmux Plugin Manager)
if [ ! -d "$HOME/.tmux/plugins/tpm" ]; then
    echo "Installing TPM..."
    git clone --depth=1 https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
    # Install plugins headlessly (requires tmux not running in same session)
    "$HOME/.tmux/plugins/tpm/scripts/install_plugins.sh" 2>/dev/null || \
        echo "  Note: run prefix+I inside tmux to finish installing plugins"
else
    echo "TPM already installed"
fi

# Linux-only: tools not available in apt
if [[ "$(uname)" != "Linux" ]]; then
    exit 0
fi

# oh-my-posh
if ! command -v oh-my-posh &>/dev/null; then
    echo "Installing oh-my-posh..."
    curl -s https://ohmyposh.dev/install.sh | bash -s -- -d ~/.local/bin
else
    echo "oh-my-posh already installed"
fi

# eza (via official apt repo)
if ! command -v eza &>/dev/null; then
    echo "Installing eza..."
    sudo apt-get install -y gpg
    sudo mkdir -p /etc/apt/keyrings
    wget -qO- https://raw.githubusercontent.com/eza-community/eza/main/deb.asc \
        | sudo gpg --dearmor -o /etc/apt/keyrings/gierens.gpg
    echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" \
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
