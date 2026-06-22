#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

parse_list() {
    grep -v '^#' "$1" | grep -v '^$'
}

install_macos() {
    if ! command -v brew &>/dev/null; then
        echo "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    echo "Installing Homebrew formulae..."
    parse_list "$DOTFILES_DIR/packages/brew.txt" | xargs brew install
    echo "Installing Homebrew casks..."
    parse_list "$DOTFILES_DIR/packages/brew-casks.txt" | xargs brew install --cask
}

install_linux() {
    echo "Updating apt..."
    sudo apt-get update -qq
    echo "Installing apt packages..."
    parse_list "$DOTFILES_DIR/packages/apt.txt" | xargs sudo apt-get install -y
}

case "$(uname)" in
    Darwin) install_macos ;;
    Linux)  install_linux ;;
    *)      echo "Unsupported OS: $(uname)"; exit 1 ;;
esac
