#!/usr/bin/env bash

# Keep command discovery consistent in installers and the standalone doctor.
dotfiles_find_homebrew() {
    local brew_path
    if brew_path="$(command -v brew)"; then
        printf '%s\n' "$brew_path"
        return 0
    fi
    if [ "$#" -eq 0 ]; then
        set -- /opt/homebrew/bin/brew /usr/local/bin/brew
    fi
    for brew_path in "$@"; do
        if [ -x "$brew_path" ]; then
            printf '%s\n' "$brew_path"
            return 0
        fi
    done
    return 1
}

# GUI apps may be installed without Homebrew; the cask then fails with "already
# an App at /Applications". Installers and the doctor share this detection.
dotfiles_macos_app_installed() {
    [ -d "/Applications/$1.app" ] || [ -d "$HOME/Applications/$1.app" ]
}

dotfiles_init_environment() {
    local brew_path brew_environment
    if [ "$(uname)" = "Darwin" ] && brew_path="$(dotfiles_find_homebrew)"; then
        brew_environment="$("$brew_path" shellenv)" || return
        eval "$brew_environment" || return
    fi
    # Release binaries land in DOTFILES_LOCAL_BIN (default ~/.local/bin).
    local local_bin="${DOTFILES_LOCAL_BIN:-$HOME/.local/bin}"
    case ":${PATH:-}:" in
        *":$local_bin:"*) ;;
        *) export PATH="$local_bin${PATH:+:$PATH}" ;;
    esac
}
