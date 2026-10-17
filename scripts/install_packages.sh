#!/usr/bin/env bash
DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/environment.sh
source "$DOTFILES_DIR/scripts/lib/environment.sh"
# shellcheck source=lib/apt_repositories.sh
source "$DOTFILES_DIR/scripts/lib/apt_repositories.sh"
# shellcheck source=lib/dnf_repositories.sh
source "$DOTFILES_DIR/scripts/lib/dnf_repositories.sh"

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
    local installer installer_file package installed=""
    local declared=() present=() missing=()
    if ! command -v brew &>/dev/null; then
        echo "Installing Homebrew..."
        # Into a file: a retried download appends to stdout (dotfiles_curl).
        installer_file="$(mktemp "${TMPDIR:-/tmp}/dotfiles-brew.XXXXXX")" || return
        if ! dotfiles_curl -o "$installer_file" https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh ||
            ! installer="$(cat "$installer_file")"; then
            rm -f "$installer_file"
            return 1
        fi
        rm -f "$installer_file"
        /bin/bash -c "$installer" || return
        dotfiles_init_environment || return
    fi
    # The update upgrades the declared packages Homebrew reports outdated
    # first; the steps below only add what is missing.
    if dotfiles_updating; then
        echo "Updating Homebrew..."
        brew update </dev/null || return
        echo "Upgrading Homebrew formulae..."
        brew_upgrade_declared --formula "$DOTFILES_DIR/packages/brew.txt" || return
        echo "Upgrading Homebrew casks..."
        brew_upgrade_declared --cask "$DOTFILES_DIR/packages/brew-casks.txt" || return
        # A safeguard: brew install upgrades an installed formula it is
        # named, and the steps below name only missing ones.
        export HOMEBREW_NO_INSTALL_UPGRADE=1
    fi
    # Only the missing formulae go to one `brew install`: naming an installed
    # one costs about a second and prints a warning that it is installed, and
    # a rerun only adds what is missing. Names in packages/brew.txt are the
    # ones `brew list` prints, not aliases. The cask loop reads its list from
    # stdin; brew must not inherit that stream, or an install step that reads
    # input swallows the remaining names.
    echo "Installing Homebrew formulae..."
    while IFS= read -r package; do
        declared+=("$package")
    done < <(parse_list "$DOTFILES_DIR/packages/brew.txt")
    if [ "${#declared[@]}" -gt 0 ]; then
        installed="$(brew list --formula -1 </dev/null)" || return
    fi
    for package in ${declared[@]+"${declared[@]}"}; do
        if printf '%s\n' "$installed" | grep -qxF -- "$package"; then
            present+=("$package")
        else
            missing+=("$package")
        fi
    done
    if [ "${#present[@]}" -gt 0 ]; then
        echo "  already installed: ${present[*]}"
    fi
    if [ "${#missing[@]}" -gt 0 ]; then
        brew install "${missing[@]}" </dev/null || return
    fi
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

# check_linux_distribution: prints the distribution's family
# (dotfiles_linux_family), or says why it is not supported and fails. The
# RHEL family needs release 9 or newer: release 8 ships tmux 2.7, older than
# the configuration needs (3.2), and zsh 5.5.
check_linux_distribution() {
    local os_release="${DOTFILES_OS_RELEASE:-/etc/os-release}" family
    local ID="" ID_LIKE="" VERSION_ID="" PRETTY_NAME=""
    if [ ! -r "$os_release" ]; then
        echo "Cannot identify this Linux distribution." >&2
        return 1
    fi

    # shellcheck disable=SC1090
    . "$os_release"
    if ! family="$(dotfiles_linux_family)"; then
        echo "Unsupported Linux distribution: ${PRETTY_NAME:-${ID:-unknown}}" >&2
        echo "Currently supported: Debian and Ubuntu (including WSL), and RHEL 9 or newer with the distributions built like it (Rocky Linux, AlmaLinux, CentOS Stream)." >&2
        return 1
    fi
    case "$family ${VERSION_ID:-}" in
        "rhel "[0-8]|"rhel "[0-8].*)
            echo "Unsupported Linux distribution: ${PRETTY_NAME:-${ID:-unknown}}" >&2
            echo "The RHEL family is supported from release 9: release ${VERSION_ID} ships tmux and zsh too old for this configuration." >&2
            return 1
            ;;
    esac
    printf '%s\n' "$family"
}

# refresh_apt_keys: fetches the signing key of every repository in
# lib/apt_repositories.sh that the bootstrap added and checks it against its
# pin, before apt reads the repositories. An expired key makes apt-get update
# fail on fresh lists, and otherwise apt warns and keeps the old index, so a
# key whose expiry the project extended has to reach the keyring first; a
# keyring holding any other key, such as one from before the pins existed, is
# replaced. A key that no longer matches its pin stops the update; one that
# cannot be downloaded leaves the keyring as it is, with a warning. Without
# gnupg the keys cannot be checked, and the apt install below brings it back
# (packages/apt.txt), so the update goes on and checks them next time.
refresh_apt_keys() {
    local name
    for name in $DOTFILES_APT_REPOSITORIES; do
        dotfiles_apt_repository_added "$name" || continue
        if ! command -v gpg >/dev/null 2>&1; then
            echo "gnupg is not installed, so the apt repository keys are checked on the next update, after apt installs it."
            return 0
        fi
        install_apt_key "$name" refresh || return
    done
}

# Listed packages installed without the packages they recommend.
# wl-clipboard recommends xdg-utils, which brings Mesa, Vulkan, Perl's LWP
# and a terminal emulator that registers itself as x-terminal-emulator: a
# fresh install of the list added 241 packages on Debian 12 with it, 129
# without (Ubuntu 24.04: 227 and 121).
DOTFILES_APT_WITHOUT_RECOMMENDS="wl-clipboard"

# apt-get install upgrades a listed package that is installed and has a newer
# candidate, so after the index refresh this both installs and updates the
# list. Held packages are left out: one with an upgrade fails the whole
# command. Updating, the third-party repositories' keys are fetched again first.
install_linux() {
    local package held family
    local packages=() lean=()
    family="$(check_linux_distribution)" || return
    if [ "$family" = rhel ]; then
        install_linux_dnf
        return
    fi
    if dotfiles_updating; then
        refresh_apt_keys || return
    fi
    echo "Updating apt..."
    sudo apt-get update -qq || return
    held="$(apt-mark showhold)" || return
    if dotfiles_updating; then
        echo "Installing and upgrading apt packages..."
    else
        echo "Installing apt packages..."
    fi
    while IFS= read -r package; do
        dotfiles_apt_unheld "$held" "$package" || continue
        case " $DOTFILES_APT_WITHOUT_RECOMMENDS " in
            *" $package "*) lean+=("$package") ;;
            *) packages+=("$package") ;;
        esac
    done < <(parse_list "$DOTFILES_DIR/packages/apt.txt")
    if [ "${#packages[@]}" -gt 0 ]; then
        sudo apt-get install -y "${packages[@]}" || return
    fi
    if [ "${#lean[@]}" -gt 0 ]; then
        sudo apt-get install -y --no-install-recommends "${lean[@]}" || return
    fi
}

# --- RHEL and the distributions built like it -----------------------------

# refresh_dnf_keys: fetches the signing key of every repository in
# lib/dnf_repositories.sh that the bootstrap added and checks it against its
# pin before dnf reads the repositories, as refresh_apt_keys does for apt.
refresh_dnf_keys() {
    local name
    for name in $DOTFILES_DNF_REPOSITORIES; do
        dotfiles_dnf_repository_added "$name" || continue
        if ! command -v gpg >/dev/null 2>&1; then
            echo "gnupg is not installed, so the dnf repository keys are checked on the next update, after dnf installs it."
            return 0
        fi
        install_rpm_key "$name" refresh || return
    done
}

# enable_epel: EPEL carries most of packages/dnf.txt. Rocky Linux, AlmaLinux
# and CentOS Stream package its release file as epel-release; RHEL itself
# does not, and the message says what it takes there.
enable_epel() {
    if rpm -q --quiet epel-release; then
        return 0
    fi
    echo "Enabling EPEL (Extra Packages for Enterprise Linux)..."
    if sudo dnf install -y epel-release; then
        return 0
    fi
    echo "Could not install epel-release from this distribution's repositories. On RHEL itself, install it as https://docs.fedoraproject.org/en-US/epel/getting-started/ describes (it also enables CodeReady Builder there), then rerun." >&2
    return 1
}

# install_linux_dnf: installs the packages in packages/dnf.txt that rpm does
# not list as installed, after enabling EPEL. Updating, the keys of the
# repositories the bootstrap added are fetched again first, and dnf
# refreshes its metadata (EPEL keeps only each package's latest build, so a
# package added to the list could otherwise be fetched from a stale index)
# before it installs what is missing and upgrades every listed package. dnf
# itself leaves out packages the user locked (dnf versionlock), and excluded
# ones as long as the command names others.
install_linux_dnf() {
    local package
    local declared=() present=() missing=() refresh=()
    if dotfiles_updating; then
        refresh=(--refresh)
    fi
    if dotfiles_updating; then
        refresh_dnf_keys || return
    fi
    enable_epel || return
    echo "Installing dnf packages..."
    while IFS= read -r package; do
        declared+=("$package")
        if rpm -q --quiet "$package"; then
            present+=("$package")
        else
            missing+=("$package")
        fi
    done < <(parse_list "$DOTFILES_DIR/packages/dnf.txt")
    if [ "${#present[@]}" -gt 0 ]; then
        echo "  already installed: ${present[*]}"
    fi
    if [ "${#missing[@]}" -gt 0 ]; then
        sudo dnf install -y ${refresh[@]+"${refresh[@]}"} "${missing[@]}" || return
    fi
    if dotfiles_updating && [ "${#declared[@]}" -gt 0 ]; then
        echo "Upgrading dnf packages..."
        sudo dnf upgrade -y --refresh "${declared[@]}" || return
    fi
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
