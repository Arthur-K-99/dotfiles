#!/usr/bin/env bash
# Installs this checkout on a fresh machine the way the README does, reruns the
# installer, runs the update, and starts the configured shells. tests/unix.Tests.sh mocks every
# download; this is the one check that reaches the real package archives,
# releases and plugin repositories, so it catches upstream changes such as a
# renamed release asset.
#
# Usage:
#   bash tests/fresh_install.sh [image]   a Debian, Ubuntu or Rocky Linux container (default: debian:12)
#   bash tests/fresh_install.sh --here    this machine, for a disposable one such as a CI runner
#
# The container form needs Docker and network access and takes several
# minutes. The checkout is mounted read-only and copied into the container
# user's home, so nothing on the host changes. A Mac runs the arm64 images;
# CI runs x86_64. An install and its update make about 35 requests to the
# GitHub API, one per release download plus one per release held back by the
# minimum release age; the API answers 60 an hour per address without a
# token, so for several runs in a row pass one with
# GITHUB_TOKEN="$(gh auth token)", which reaches the container.

# The user that commands run as; empty runs them as the current user.
FRESH_INSTALL_USER=""

# Runs as root inside the container. A new machine already has a user with
# sudo and git (the README clones with it); nothing else is installed here.
# The Rocky Linux image has neither, and dnf instead of apt.
fresh_install_prepare() {
    local home="/home/$1"
    if command -v dnf >/dev/null 2>&1; then
        dnf install -y -q sudo git >/dev/null || return
    else
        export DEBIAN_FRONTEND=noninteractive
        # A desktop install has answered debconf's questions (tzdata's time
        # zone) already; sudo drops DEBIAN_FRONTEND, so the installer's
        # apt-get would ask.
        echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections || return
        apt-get update -qq || return
        apt-get install -y -qq sudo git ca-certificates >/dev/null || return
    fi
    useradd --create-home --shell /bin/bash "$1" || return
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$1" > "/etc/sudoers.d/$1" || return
    chmod 440 "/etc/sudoers.d/$1" || return
    cp -R /dotfiles-source "$home/dotfiles" || return
    chown -R "$1:" "$home/dotfiles" || return
}

# as_user <command>...: runs a command from the home directory of
# FRESH_INSTALL_USER (or the current user) in a terminal-like environment.
# GITHUB_TOKEN, when set, reaches the installer, which reads each release's
# digest and age from the GitHub API (60 requests an hour without a token).
as_user() {
    if [ -n "$FRESH_INSTALL_USER" ]; then
        (cd "/home/$FRESH_INSTALL_USER" && sudo -u "$FRESH_INSTALL_USER" -H --preserve-env=GITHUB_TOKEN \
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

# A terminal emulator gives zsh a terminal, which turns its line editor on;
# without one, Debian 12's fzf 0.38 scripts fail to restore the zle option and
# print errors a real terminal never shows. script provides the terminal
# (util-linux's on Linux, BSD's on macOS), and zsh's stderr goes to a file so
# it does not mix with the terminal's output. Commands typed into it make zsh
# draw its prompt and run the prompt hooks (oh-my-posh, atuin, direnv) and
# zoxide's cd. BSD script ends the session as soon as its input does, before
# zsh reads a line, so the input stays open a few seconds.
FRESH_INSTALL_ZSH='errors="$(mktemp)" || exit 1
command="DOTFILES_FASTFETCH=0 zsh -i 2>\"$errors\""
input="true
cd /tmp
cd
exit
"
if [ "$(uname)" = Linux ]; then
    { printf %s "$input"; sleep 3; } | script -qec "$command" /dev/null >/dev/null
else
    { printf %s "$input"; sleep 3; } | script -q /dev/null sh -c "$command" >/dev/null
fi
status=$?
cat "$errors" >&2
rm -f "$errors"
exit "$status"'

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

# Sets every recorded release tag back to one that never existed, so the
# update fetches and verifies each release again as it would after upstream
# releases: the release binaries, Neovim's tree, the tree-sitter CLI and the
# font. Records live in the user's state directory.
FRESH_INSTALL_STALE_RECORDS='find "${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/releases" -type f 2>/dev/null | while IFS= read -r record; do
    echo v0.0.0-fresh-install > "$record"
    printf "%s\n" "${record##*/releases/}"
done'

# Prints each release record that still holds the fake tag.
FRESH_INSTALL_STILL_STALE='grep -rlx v0.0.0-fresh-install "${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/releases" 2>/dev/null || :'

# Lines that read as errors in a stage that passed: the harness fails on them,
# so what a new user would take for a failure does not creep back in. The
# container's own invoke-rc.d messages are not among them.
FRESH_INSTALL_NOISE="Plugin [^ ]+ is not installed|^Error|tput: |can't change option|^fatal: "

# run_stage <command>...: runs a stage as the user, showing its output, and
# fails when the stage fails or prints a line FRESH_INSTALL_NOISE matches.
run_stage() {
    local log status noise
    log="$(mktemp)" || return
    { as_user "$@" 2>&1; echo "$?" > "$log.status"; } | tee "$log"
    status="$(cat "$log.status")"
    noise="$(grep -E "$FRESH_INSTALL_NOISE" "$log")" || :
    rm -f "$log" "$log.status"
    [ "$status" -eq 0 ] || return "$status"
    if [ -n "$noise" ]; then
        printf 'The stage passed but printed what reads as errors:\n%s\n' "$noise" >&2
        return 1
    fi
}

# fresh_install_run <checkout>
fresh_install_run() {
    local stale left
    echo "==> Installing"
    run_stage bash "$1/install.sh" || return
    # A rerun must succeed, as the README says (on Linux it may upgrade the
    # listed apt packages).
    echo "==> Rerunning the installer"
    run_stage bash "$1/install.sh" || return
    # The update right after an install must succeed, end with the doctor,
    # and fetch again every release whose record was set back.
    echo "==> Updating"
    stale="$(as_user bash -c "$FRESH_INSTALL_STALE_RECORDS")" || return
    run_stage bash "$1/scripts/update.sh" || return
    left="$(as_user bash -c "$FRESH_INSTALL_STILL_STALE")" || return
    if [ -n "$left" ]; then
        printf 'The update did not fetch these releases again:\n%s\n' "$left" >&2
        return 1
    elif [ -z "$stale" ]; then
        echo "No release was recorded, so no tag was set back."
    else
        printf 'The update fetched these releases again:\n%s\n' "$stale"
    fi
    # Loading ~/.zshrc runs every tool's init script.
    check_quiet_start "an interactive zsh" bash -c "$FRESH_INSTALL_ZSH" || return
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
            docker run --rm --env GITHUB_TOKEN --volume "$repo:/dotfiles-source:ro" "${1:-debian:12}" \
                bash /dotfiles-source/tests/fresh_install.sh --inside
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
    set -euo pipefail
    fresh_install_main "$@"
fi
