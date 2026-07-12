#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

parse_list() {
    awk '!/^[[:space:]]*#/ && NF' "$1"
}

macos_cask_is_satisfied() {
    local package="$1"

    if brew list --cask "$package" &>/dev/null; then
        return 0
    fi

    case "$package" in
        font-caskaydia-cove-nerd-font)
            compgen -G "$HOME/Library/Fonts/CaskaydiaCove*NerdFont*.ttf" >/dev/null || \
                compgen -G "$HOME/Library/Fonts/CaskaydiaCove*NerdFont*.otf" >/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

install_macos() {
    if ! command -v brew &>/dev/null; then
        echo "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

        if [ -x /opt/homebrew/bin/brew ]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        elif [ -x /usr/local/bin/brew ]; then
            eval "$(/usr/local/bin/brew shellenv)"
        fi
    fi
    echo "Installing Homebrew formulae..."
    while IFS= read -r package; do
        brew install "$package"
    done < <(parse_list "$DOTFILES_DIR/packages/brew.txt")
    echo "Installing Homebrew casks..."
    while IFS= read -r package; do
        if macos_cask_is_satisfied "$package"; then
            echo "  already installed: $package"
        else
            brew install --cask "$package"
        fi
    done < <(parse_list "$DOTFILES_DIR/packages/brew-casks.txt")
}

install_linux() {
    if [ ! -r /etc/os-release ]; then
        echo "Cannot identify this Linux distribution." >&2
        exit 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-} ${ID_LIKE:-}" in
        *debian*|*ubuntu*) ;;
        *)
            echo "Unsupported Linux distribution: ${PRETTY_NAME:-${ID:-unknown}}" >&2
            echo "Currently supported: Debian and Ubuntu (including WSL)." >&2
            exit 1
            ;;
    esac

    echo "Updating apt..."
    sudo apt-get update -qq
    echo "Installing apt packages..."
    packages=()
    while IFS= read -r package; do
        packages+=("$package")
    done < <(parse_list "$DOTFILES_DIR/packages/apt.txt")
    sudo apt-get install -y "${packages[@]}"
}

case "$(uname)" in
    Darwin) install_macos ;;
    Linux)  install_linux ;;
    *)      echo "Unsupported OS: $(uname)"; exit 1 ;;
esac
