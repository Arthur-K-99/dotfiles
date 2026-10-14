#!/usr/bin/env bash
# Third-party apt repositories that the Linux bootstrap adds for tools Debian
# and Ubuntu do not package, shared by install_packages.sh (which refreshes
# their keys while updating), bootstrap_tools.sh (which adds them) and
# doctor.sh (which checks their keyrings).
#
# Each signing key goes to /etc/apt/keyrings/<name>.gpg only when the file
# downloaded holds exactly the key whose fingerprint is pinned here, and apt
# trusts it for that repository alone (signed-by). Neither project publishes
# its fingerprint; each pin is the key that signs the repository's InRelease.

DOTFILES_APT_REPOSITORIES="gierens charm"

# Where apt keeps the sources lists and keyrings; tests point it elsewhere.
# The sources lines below name the real keyrings, which is what apt reads.
DOTFILES_APT_ETC="${DOTFILES_APT_ETC:-/etc/apt}"

# dotfiles_apt_repository <name>: prints the repository's key URL, the pinned
# fingerprint of that key, and its sources line, separated by spaces.
dotfiles_apt_repository() {
    case "$1" in
        # eza
        gierens) echo "https://raw.githubusercontent.com/eza-community/eza/main/deb.asc 1548BC8A4B4D2688F9B0DAF7EC29E2090CE3FD43 deb [signed-by=/etc/apt/keyrings/gierens.gpg] https://deb.gierens.de stable main" ;;
        # glow and gum. The key expires on 2027-07-13; the update fetches it
        # again, so an extended expiry reaches the keyring.
        charm) echo "https://repo.charm.sh/apt/gpg.key ED927B38BE981E53CA09153D03BBF595D4DFD35C deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" ;;
        *) echo "Unknown apt repository: $1" >&2; return 1 ;;
    esac
}

# dotfiles_apt_repository_added <name>: the bootstrap wrote its sources list.
dotfiles_apt_repository_added() {
    [ -e "$DOTFILES_APT_ETC/sources.list.d/$1.list" ]
}

# key_details <key file>: one line per OpenPGP key in the file, armored or a
# binary keyring: its primary fingerprint, then its expiry in seconds since
# the epoch when it has one. Nothing is imported. gpg wants a writable home
# even for --show-keys (it would create ~/.gnupg), so it gets an empty one
# that goes away afterwards, after gpgconf stops the agent gpg 2.4 starts in
# it.
key_details() (
    local home
    home="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-gnupg.XXXXXX")" || return
    trap 'GNUPGHOME="$home" gpgconf --kill all >/dev/null 2>&1; rm -rf "$home"' EXIT
    GNUPGHOME="$home" gpg --batch --quiet --show-keys --with-colons -- "$1" |
        awk -F: '$1 == "pub" { expiry = $7; primary = 1; next }
            primary && $1 == "fpr" { print $10 (expiry == "" ? "" : " " expiry); primary = 0 }'
)

# key_fingerprints <key file>: the primary fingerprint of every key in it.
key_fingerprints() {
    key_details "$1" | cut -d ' ' -f 1
}

# dotfiles_date <seconds since the epoch>: the UTC date, with GNU or BSD date.
dotfiles_date() {
    date -u -d "@$1" +%F 2>/dev/null || date -u -r "$1" +%F
}

# install_apt_key <name>: fetches the repository's signing key and installs
# it as its keyring when it holds exactly the pinned key.
#
# A keyring that already holds the pinned key gets the download merged into
# it rather than replaced. When a project extends its key, the new copy
# carries only the new self-signature, and Debian 13's verifier (sqv) judges
# a signature by the bindings valid when it was made: with the new copy
# alone, the repository's index signed before the extension stops verifying
# until the project signs it again. gpg keeps both self-signatures when it
# imports the two, and exports both unless told export-minimal or
# export-clean; gpgv on Debian 12 and Ubuntu uses the newest. Concatenating
# the two files would not do: gpgv reads only the first copy.
#
# The keyring is left alone when the download adds nothing to it. One that
# holds any other key, such as one from before the pins existed, is replaced.
# The gpg homes are throwaway, and gpgconf stops any agent or keyboxd that
# gpg 2.4 starts in them.
install_apt_key() (
    local name="$1" fields key_url fingerprint work found keyring
    fields="$(dotfiles_apt_repository "$name")" || return
    read -r key_url fingerprint _ <<<"$fields"
    if ! command -v gpg >/dev/null 2>&1; then
        echo "gnupg is not installed; install packages first." >&2
        return 1
    fi
    work="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-key.XXXXXX")" || return
    trap 'GNUPGHOME="$work/before" gpgconf --kill all >/dev/null 2>&1; GNUPGHOME="$work/after" gpgconf --kill all >/dev/null 2>&1; rm -rf "$work"' EXIT
    curl -fsSL --retry 5 -o "$work/key" "$key_url" || return
    found="$(key_fingerprints "$work/key")" || :
    if [ "$found" != "$fingerprint" ]; then
        printf 'The signing key at %s is not the one pinned for the %s repository:\n  expected %s\n  received %s\n' \
            "$key_url" "$name" "$fingerprint" "$(printf '%s' "${found:-no OpenPGP key}" | tr '\n' ' ')" >&2
        return 1
    fi
    keyring="$DOTFILES_APT_ETC/keyrings/$name.gpg"
    mkdir -m 700 "$work/before" "$work/after" || return
    if [ -r "$keyring" ] && [ "$(key_fingerprints "$keyring" 2>/dev/null)" = "$fingerprint" ]; then
        GNUPGHOME="$work/before" gpg --batch --quiet --import -- "$keyring" 2>/dev/null || return
        GNUPGHOME="$work/before" gpg --batch --export "$fingerprint" > "$work/before.gpg" || return
        GNUPGHOME="$work/after" gpg --batch --quiet --import -- "$keyring" 2>/dev/null || return
    fi
    GNUPGHOME="$work/after" gpg --batch --quiet --import -- "$work/key" 2>/dev/null || return
    GNUPGHOME="$work/after" gpg --batch --export "$fingerprint" > "$work/keyring" || return
    if [ "$(key_fingerprints "$work/keyring")" != "$fingerprint" ]; then
        echo "gpg did not export the $name repository's key $fingerprint." >&2
        return 1
    fi
    if [ -e "$work/before.gpg" ] && cmp -s "$work/before.gpg" "$work/keyring"; then
        echo "The $name repository's signing key is current."
        return 0
    fi
    if [ -e "$work/before.gpg" ]; then
        echo "Merging the $name repository's key from $key_url into its keyring..."
    elif [ -e "$keyring" ]; then
        echo "Replacing the $name repository's keyring with the pinned key from $key_url..."
    else
        echo "Installing the $name repository's signing key from $key_url..."
    fi
    sudo mkdir -p "$DOTFILES_APT_ETC/keyrings" || return
    sudo install -m 644 "$work/keyring" "$keyring"
)
