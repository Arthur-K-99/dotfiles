#!/usr/bin/env bash
DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/environment.sh
source "$DOTFILES_DIR/scripts/lib/environment.sh"

# The command that finishes an interrupted run; scripts/update.sh names itself.
DOTFILES_RERUN="$DOTFILES_DIR/install.sh"

run_step() {
    local label="$1"
    local script_path="$2"
    local status
    echo "==> $label"
    if bash "$script_path"; then
        return 0
    else
        status=$?
        printf '\nSetup stopped during: %s (exit %s).\n' "$label" "$status" >&2
        printf 'Completed steps and backups have been preserved. Resolve the error above, then rerun:\n  bash %q\n' "$DOTFILES_RERUN" >&2
        return "$status"
    fi
}

# With DOTFILES_UPDATE=1 (scripts/update.sh) the same stages also bring what
# they installed to the latest release.
install_main() {
    local packages="Installing packages" tools="Bootstrapping tools" finished="Done. All setup checks passed."
    if dotfiles_updating; then
        packages="Updating packages"
        tools="Updating tools"
        finished="Done. Everything is up to date and all setup checks passed."
    fi
    if ! dotfiles_init_environment; then
        echo "Could not initialize the tool environment. Check Homebrew, then rerun ${DOTFILES_RERUN##*/}." >&2
        return 1
    fi
    # The bootstrap stage reads it; a wrong value stops the run before any stage.
    dotfiles_minimum_release_age >/dev/null || return
    run_step "$packages" "$DOTFILES_DIR/scripts/install_packages.sh" || return
    run_step "Linking dotfiles" "$DOTFILES_DIR/scripts/link_dotfiles.sh" || return
    run_step "$tools" "$DOTFILES_DIR/scripts/bootstrap_tools.sh" || return
    run_step "Verifying the setup" "$DOTFILES_DIR/scripts/doctor.sh" || return
    echo ""
    echo "$finished"
    case "${SHELL:-}" in
        */zsh) echo "Open a new zsh session to apply changes." ;;
        *) echo "Your default shell is not zsh. Run 'zsh' to use this configuration." ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
    set -euo pipefail
    install_main "$@"
fi
