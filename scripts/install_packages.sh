#!/usr/bin/env bash
DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/environment.sh
source "$DOTFILES_DIR/scripts/lib/environment.sh"

parse_list() {
    awk '!/^[[:space:]]*#/ && NF' "$1"
}

macos_cask_is_satisfied() {
    local package="$1"

    case "$package" in
        font-caskaydia-cove-nerd-font)
            compgen -G "$HOME/Library/Fonts/CaskaydiaCove*NerdFont*.ttf" >/dev/null || \
                compgen -G "$HOME/Library/Fonts/CaskaydiaCove*NerdFont*.otf" >/dev/null
            ;;
        ghostty)
            dotfiles_macos_app_installed Ghostty
            ;;
        *)
            brew list --cask "$package" &>/dev/null
            ;;
    esac
}

install_macos() {
    local installer package
    if ! command -v brew &>/dev/null; then
        echo "Installing Homebrew..."
        installer="$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || return
        /bin/bash -c "$installer" || return
        dotfiles_init_environment || return
    fi
    # The loops read the package lists from stdin; brew must not inherit that
    # stream, or an install step that reads input swallows the remaining names.
    echo "Installing Homebrew formulae..."
    while IFS= read -r package; do
        brew install "$package" </dev/null || return
    done < <(parse_list "$DOTFILES_DIR/packages/brew.txt")
    echo "Installing Homebrew casks..."
    while IFS= read -r package; do
        if macos_cask_is_satisfied "$package"; then
            echo "  already installed: $package"
        elif brew list --cask "$package" &>/dev/null; then
            echo "  repairing missing files: $package"
            brew reinstall --cask "$package" </dev/null || return
        else
            brew install --cask "$package" </dev/null || return
        fi
    done < <(parse_list "$DOTFILES_DIR/packages/brew-casks.txt")
}

check_linux_distribution() {
    if [ ! -r /etc/os-release ]; then
        echo "Cannot identify this Linux distribution." >&2
        return 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-} ${ID_LIKE:-}" in
        *debian*|*ubuntu*) ;;
        *)
            echo "Unsupported Linux distribution: ${PRETTY_NAME:-${ID:-unknown}}" >&2
            echo "Currently supported: Debian and Ubuntu (including WSL)." >&2
            return 1
            ;;
    esac
}

install_linux() {
    local package
    local packages=()
    check_linux_distribution || return
    echo "Updating apt..."
    sudo apt-get update -qq || return
    echo "Installing apt packages..."
    while IFS= read -r package; do
        packages+=("$package")
    done < <(parse_list "$DOTFILES_DIR/packages/apt.txt")
    sudo apt-get install -y "${packages[@]}" || return
}

install_packages_main() {
    dotfiles_init_environment || return
    case "$(uname)" in
        Darwin) install_macos ;;
        Linux)  install_linux ;;
        *)      echo "Unsupported OS: $(uname)" >&2; return 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
    set -euo pipefail
    install_packages_main "$@"
fi
