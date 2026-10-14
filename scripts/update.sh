#!/usr/bin/env bash
# Brings an installed machine up to date: the install stages run again with
# DOTFILES_UPDATE=1, so besides adding whatever is missing they upgrade the
# packages packages/*.txt declares, fetch a release tool again when a newer
# release is old enough (DOTFILES_MINIMUM_RELEASE_AGE), update zinit, TPM,
# the yazi flavors, mise's runtimes, the Neovim parsers and Mason packages,
# and finish with the doctor. Neovim plugins stay on lazy-lock.json, and
# whatever the dotfiles did not install (or the user pinned or held) is left
# alone. It does not pull this repository: `git pull` first to get its
# changes.
DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../install.sh
source "$DOTFILES_DIR/install.sh"

update_main() {
    export DOTFILES_UPDATE=1
    DOTFILES_RERUN="$DOTFILES_DIR/scripts/update.sh"
    install_main "$@"
}

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
    set -euo pipefail
    update_main "$@"
fi
