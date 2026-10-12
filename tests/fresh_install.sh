#!/usr/bin/env bash
# Installs this checkout on a fresh machine the way the README does, reruns the
# installer, and starts the configured shells. tests/unix.Tests.sh mocks every
# download; this is the one check that reaches the real package archives,
# releases and plugin repositories, so it catches upstream changes such as a
# renamed release asset.
#
# Usage:
#   bash tests/fresh_install.sh [image]   a Debian or Ubuntu container (default: debian:12)
#   bash tests/fresh_install.sh --here    this machine, for a disposable one such as a CI runner
#
# The container form needs Docker and network access and takes several
# minutes. The checkout is mounted read-only and copied into the container
# user's home, so nothing on the host changes. A Mac runs the arm64 images;
# CI runs x86_64.

# The user that commands run as; empty runs them as the current user.
FRESH_INSTALL_USER=""

# Runs as root inside the container. A new machine already has a user with
# sudo and git (the README clones with it); nothing else is installed here.
fresh_install_prepare() {
    local home="/home/$1"
    export DEBIAN_FRONTEND=noninteractive
    # A desktop install has answered debconf's questions (tzdata's time zone)
    # already; sudo drops DEBIAN_FRONTEND, so the installer's apt-get would ask.
    echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections || return
    apt-get update -qq || return
    apt-get install -y -qq sudo git ca-certificates >/dev/null || return
    useradd --create-home --shell /bin/bash "$1" || return
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$1" > "/etc/sudoers.d/$1" || return
    chmod 440 "/etc/sudoers.d/$1" || return
    cp -R /dotfiles-source "$home/dotfiles" || return
    chown -R "$1:" "$home/dotfiles" || return
}

# as_user <command>...: runs a command from the home directory of
# FRESH_INSTALL_USER (or the current user) in a terminal-like environment.
as_user() {
    if [ -n "$FRESH_INSTALL_USER" ]; then
        (cd "/home/$FRESH_INSTALL_USER" && sudo -u "$FRESH_INSTALL_USER" -H \
            env LANG="${LANG:-C.UTF-8}" TERM=xterm-256color "$@")
    else
        (cd "$HOME" && env LANG="${LANG:-C.UTF-8}" TERM=xterm-256color "$@")
    fi
}

# check_quiet_start <label> <command>...: the command must succeed and print
# nothing on stderr, where a new shell's errors would otherwise only show.
check_quiet_start() {
    local label="$1" errors
    shift
    echo "==> Starting $label"
    if ! errors="$(as_user "$@" 2>&1 >/dev/null)"; then
        printf '%s failed:\n%s\n' "$label" "$errors" >&2
        return 1
    fi
    if [ -n "$errors" ]; then
        printf '%s printed errors:\n%s\n' "$label" "$errors" >&2
        return 1
    fi
}

# tmux reports configuration errors to the client that sources the file, and
# run-shell output, such as a failing plugin manager, to its stdout; both must
# stay empty. TPM silences the plugins themselves, so the last one,
# tmux-continuum, must have added its save hook to status-right. -f /dev/null
# keeps the server from loading the configuration a second time.
FRESH_INSTALL_TMUX='output="$(tmux -L fresh-install -f /dev/null start-server \; \
    set-option -g exit-empty off \; source-file "$HOME/.config/tmux/tmux.conf" 2>&1)"
status=$?
status_right="$(tmux -L fresh-install show-options -gv status-right 2>&1)"
tmux -L fresh-install kill-server >/dev/null 2>&1
if [ -n "$output" ]; then
    printf "%s\n" "$output" >&2
    exit 1
fi
case "$status_right" in
    *continuum_save*) ;;
    *) echo "The tmux plugins did not all load; status-right is: $status_right" >&2; exit 1 ;;
esac
exit "$status"'

# fresh_install_run <checkout>
fresh_install_run() {
    echo "==> Installing"
    as_user bash "$1/install.sh" || return
    # A rerun must succeed without changes, as the README promises.
    echo "==> Rerunning the installer"
    as_user bash "$1/install.sh" || return
    # Loading ~/.zshrc runs every tool's init script. The prompt hooks need a
    # terminal: run by hand without one, Debian 12's fzf scripts fail to
    # restore the zle option, which a real terminal never shows.
    check_quiet_start "an interactive zsh" env DOTFILES_FASTFETCH=0 zsh -i -c exit || return
    check_quiet_start "tmux with its plugins" bash -c "$FRESH_INSTALL_TMUX" || return
    echo "Fresh install passed."
}

fresh_install_main() {
    local repo
    repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || return
    case "${1:-debian:12}" in
        --inside)
            FRESH_INSTALL_USER=dev
            fresh_install_prepare "$FRESH_INSTALL_USER" || return
            fresh_install_run "/home/$FRESH_INSTALL_USER/dotfiles"
            ;;
        --here)
            fresh_install_run "$repo"
            ;;
        *)
            echo "Installing $repo on a fresh ${1:-debian:12} container..."
            docker run --rm --volume "$repo:/dotfiles-source:ro" "${1:-debian:12}" \
                bash /dotfiles-source/tests/fresh_install.sh --inside
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
    set -euo pipefail
    fresh_install_main "$@"
fi
