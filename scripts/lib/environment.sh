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

dotfiles_init_environment() {
    local brew_path brew_environment
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    if [ "$(uname)" = "Darwin" ] && brew_path="$(dotfiles_find_homebrew)"; then
        brew_environment="$("$brew_path" shellenv)" || return
        eval "$brew_environment" || return
    fi
    case ":${PATH:-}:" in
        *":$HOME/.local/bin:"*) ;;
        *) export PATH="$HOME/.local/bin${PATH:+:$PATH}" ;;
    esac
}
