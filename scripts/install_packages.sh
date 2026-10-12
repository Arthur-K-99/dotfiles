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

# brew_upgrade_declared <--formula|--cask> <list file>: upgrades the listed
# packages that Homebrew reports as outdated. Pinned ones are left alone
# (naming one makes `brew upgrade` fail), and casks that update themselves,
# such as Ghostty, are not reported as outdated, so their own updater keeps
# them current. Packages installed some other way are not Homebrew's to
# report either.
brew_upgrade_declared() {
    local kind="$1" list="$2" package outdated pinned
    local upgrades=()
    outdated="$(brew outdated "$kind" --quiet </dev/null)" || return
    pinned="$(brew list --pinned "$kind" </dev/null)" || return
    while IFS= read -r package; do
        printf '%s\n' "$outdated" | grep -qxF -- "$package" || continue
        if printf '%s\n' "$pinned" | grep -qxF -- "$package"; then
            echo "  pinned, left alone: $package (brew unpin $package to upgrade it)"
        else
            upgrades+=("$package")
        fi
    done < <(parse_list "$list")
    if [ "${#upgrades[@]}" -eq 0 ]; then
        echo "  nothing to upgrade"
        return 0
    fi
    brew upgrade "$kind" "${upgrades[@]}" </dev/null
}

install_macos() {
    local installer package
    if ! command -v brew &>/dev/null; then
        echo "Installing Homebrew..."
        installer="$(curl -fsSL --retry 5 https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || return
        /bin/bash -c "$installer" || return
        dotfiles_init_environment || return
    fi
    # A plain `brew install` upgrades an outdated formula as well, but not a
    # pinned one and never a cask the loop below finds in place, so the
    # update upgrades first and then only adds what is missing.
    if dotfiles_updating; then
        echo "Updating Homebrew..."
        brew update </dev/null || return
        echo "Upgrading Homebrew formulae..."
        brew_upgrade_declared --formula "$DOTFILES_DIR/packages/brew.txt" || return
        echo "Upgrading Homebrew casks..."
        brew_upgrade_declared --cask "$DOTFILES_DIR/packages/brew-casks.txt" || return
        export HOMEBREW_NO_INSTALL_UPGRADE=1
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

# apt-get install upgrades a listed package that is installed and has a newer
# candidate, so after the index refresh this both installs and updates the
# list. Held packages are left out: one with an upgrade fails the whole
# command.
install_linux() {
    local package held
    local packages=()
    check_linux_distribution || return
    echo "Updating apt..."
    sudo apt-get update -qq || return
    held="$(apt-mark showhold)" || return
    if dotfiles_updating; then
        echo "Installing and upgrading apt packages..."
    else
        echo "Installing apt packages..."
    fi
    while IFS= read -r package; do
        dotfiles_apt_unheld "$held" "$package" && packages+=("$package")
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
