#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

link() {
    local src="$1"
    local dst="$2"
    local backup=""
    local staging

    if [ ! -e "$src" ]; then
        echo "  missing source: $src" >&2
        return 1
    fi

    if [ -L "$dst" ]; then
        if [ "$(readlink "$dst")" = "$src" ]; then
            echo "  already linked: $dst"
            return
        fi
    fi

    # Prepare the replacement beside its destination before moving any user data.
    mkdir -p "$(dirname "$dst")" || return 1
    staging="$(mktemp -d "$(dirname "$dst")/.dotfiles-link.XXXXXX")" || return 1
    if ! ln -s "$src" "$staging/link"; then
        rm -rf "$staging"
        return 1
    fi

    if [ -e "$dst" ] || [ -L "$dst" ]; then
        backup="${dst}.bak.$(date +%Y%m%d%H%M%S)"
        while [ -e "$backup" ] || [ -L "$backup" ]; do
            backup="${backup}.1"
        done
        echo "  backing up $dst -> $backup"
        if ! mv "$dst" "$backup"; then
            rm -rf "$staging"
            return 1
        fi
    fi

    if ! mv "$staging/link" "$dst"; then
        echo "  failed to link: $dst" >&2
        if [ -n "$backup" ]; then
            if [ ! -e "$dst" ] && [ ! -L "$dst" ]; then
                if ! mv "$backup" "$dst"; then
                    echo "  restore failed; original preserved at: $backup" >&2
                fi
            else
                echo "  destination changed; original preserved at: $backup" >&2
            fi
        fi
        rm -rf "$staging"
        return 1
    fi
    rm -rf "$staging"
    echo "  linked: $dst"
}

main() {
    echo "Linking dotfiles..."
    link "$DOTFILES_DIR/home/.zshrc" "$HOME/.zshrc" || return 1
    link "$DOTFILES_DIR/home/.tmux.conf" "$HOME/.tmux.conf" || return 1
    link "$DOTFILES_DIR/config/eza" "$HOME/.config/eza" || return 1
    link "$DOTFILES_DIR/config/oh-my-posh/config.omp.json" "$HOME/.config/oh-my-posh/config.omp.json" || return 1
    link "$DOTFILES_DIR/config/bat/config" "$HOME/.config/bat/config" || return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
