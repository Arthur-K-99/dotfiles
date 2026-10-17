#!/usr/bin/env bash
# Third-party dnf repositories that the Linux bootstrap adds on RHEL and the
# distributions built like it, for tools that neither they nor EPEL package,
# shared by install_packages.sh (which refreshes their keys while updating),
# bootstrap_tools.sh (which adds them) and doctor.sh (which checks their key
# files), each after lib/environment.sh, whose dotfiles_curl fetches the keys,
# and lib/apt_repositories.sh, whose key_fingerprints reads them.
#
# Each signing key goes to /etc/pki/rpm-gpg/RPM-GPG-KEY-dotfiles-<name> only
# when the file downloaded holds exactly the key whose fingerprint is pinned
# here. The repository's file names that file as its only key, and dnf
# checks the repository's metadata (repo_gpgcheck) and every package
# (gpgcheck) against it, importing it into rpm's keyring on first use.

DOTFILES_DNF_REPOSITORIES="charm"

# Where dnf reads repository files and the keys live; tests point them
# elsewhere.
DOTFILES_YUM_REPOS="${DOTFILES_YUM_REPOS:-/etc/yum.repos.d}"
DOTFILES_RPM_GPG="${DOTFILES_RPM_GPG:-/etc/pki/rpm-gpg}"

# dotfiles_dnf_repository <name>: prints the repository's key URL, the pinned
# fingerprint of that key, and its base URL, separated by spaces.
dotfiles_dnf_repository() {
    case "$1" in
        # glow and gum. The key is the one that signs Charm's apt repository
        # (lib/apt_repositories.sh) and expires on 2027-07-13.
        charm) echo "https://repo.charm.sh/yum/gpg.key ED927B38BE981E53CA09153D03BBF595D4DFD35C https://repo.charm.sh/yum/" ;;
        *) echo "Unknown dnf repository: $1" >&2; return 1 ;;
    esac
}

# dotfiles_dnf_repository_added <name>: the bootstrap wrote its repository file.
dotfiles_dnf_repository_added() {
    [ -e "$DOTFILES_YUM_REPOS/$1.repo" ]
}

# dotfiles_dnf_key_file <name>: where the repository's signing key goes.
dotfiles_dnf_key_file() {
    printf '%s/RPM-GPG-KEY-dotfiles-%s\n' "$DOTFILES_RPM_GPG" "$1"
}

# dotfiles_dnf_repository_file <name>: the repository's file for
# /etc/yum.repos.d.
dotfiles_dnf_repository_file() {
    local fields base_url
    fields="$(dotfiles_dnf_repository "$1")" || return
    read -r _ _ base_url <<<"$fields"
    printf '[%s]\nname=%s (added by the dotfiles)\nbaseurl=%s\nenabled=1\ngpgcheck=1\nrepo_gpgcheck=1\ngpgkey=file://%s\n' \
        "$1" "$1" "$base_url" "$(dotfiles_dnf_key_file "$1")"
}

# install_rpm_key <name> [refresh]: fetches the repository's signing key and
# installs it as its key file when it holds exactly the pinned key; a key
# file that already holds the same bytes is left alone. With "refresh", as
# the update passes, a key that cannot be downloaded leaves an existing key
# file in place with a warning instead of stopping. A key that does not
# match its pin stops either way.
install_rpm_key() (
    local name="$1" mode="${2:-}" fields key_url fingerprint work found key_file status
    fields="$(dotfiles_dnf_repository "$name")" || return
    read -r key_url fingerprint _ <<<"$fields"
    key_file="$(dotfiles_dnf_key_file "$name")"
    if ! command -v gpg >/dev/null 2>&1; then
        echo "gnupg is not installed; install packages first." >&2
        return 1
    fi
    work="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-key.XXXXXX")" || return
    trap 'rm -rf "$work"' EXIT
    status=0
    dotfiles_curl -o "$work/key" "$key_url" || status=$?
    if [ "$status" -ne 0 ]; then
        if [ "$mode" = refresh ] && [ -e "$key_file" ]; then
            echo "Could not fetch the $name repository's key from $key_url; its key file stays as it is." >&2
            return 0
        fi
        return "$status"
    fi
    found="$(key_fingerprints "$work/key")" || :
    if [ "$found" != "$fingerprint" ]; then
        printf 'The signing key at %s is not the one pinned for the %s repository:\n  expected %s\n  received %s\n' \
            "$key_url" "$name" "$fingerprint" "$(printf '%s' "${found:-no OpenPGP key}" | tr '\n' ' ')" >&2
        return 1
    fi
    if [ -e "$key_file" ] && cmp -s "$work/key" "$key_file"; then
        echo "The $name repository's signing key is current."
        return 0
    fi
    if [ -e "$key_file" ]; then
        echo "Replacing the $name repository's key file with the pinned key from $key_url..."
    else
        echo "Installing the $name repository's signing key from $key_url..."
    fi
    sudo install -d -m 755 "$DOTFILES_RPM_GPG" || return
    sudo install -m 644 "$work/key" "$key_file"
)
