#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# backup_path <path>: where a file the linker moves out of the way goes,
# <path>.bak.<timestamp>, with .1 appended until the name is free.
backup_path() {
    local backup
    backup="${1}.bak.$(date +%Y%m%d%H%M%S)"
    while [ -e "$backup" ] || [ -L "$backup" ]; do
        backup="${backup}.1"
    done
    printf '%s\n' "$backup"
}

# link <source> <destination>: links the destination to the source, moving
# whatever was there to a backup first. LINK_BACKUP names that backup; it is
# empty when nothing was moved or the link failed.
link() {
    local src="$1"
    local dst="$2"
    local backup=""
    local staging
    LINK_BACKUP=""

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
        backup="$(backup_path "$dst")"
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
    LINK_BACKUP="$backup"
    echo "  linked: $dst"
}

main() {
    echo "Linking dotfiles..."
    link "$DOTFILES_DIR/home/.zshrc" "$HOME/.zshrc" || return 1
    # A link into another copy of this repository holds nothing of the user's.
    if [ -n "$LINK_BACKUP" ]; then
        case "$(readlink "$LINK_BACKUP" 2>/dev/null)" in
            */home/.zshrc) ;;
            *) echo "  Your previous ~/.zshrc is in $LINK_BACKUP; move what you still need into ~/.zshrc.local, which the new one loads last." ;;
        esac
    fi
    # tmux reads ~/.tmux.conf as well as the XDG file when both exist, so the
    # link from before the move is retired, and any other file there is backed
    # up like a replaced one; the doctor fails while one is left.
    link "$DOTFILES_DIR/config/tmux/tmux.conf" "$HOME/.config/tmux/tmux.conf" || return 1
    retire_link "$DOTFILES_DIR/home/.tmux.conf" "$HOME/.tmux.conf" || return 1
    move_aside "$HOME/.tmux.conf" "tmux would load it as well as ~/.config/tmux/tmux.conf" || return 1
    link "$DOTFILES_DIR/config/eza" "$HOME/.config/eza" || return 1
    link "$DOTFILES_DIR/config/oh-my-posh/config.omp.json" "$HOME/.config/oh-my-posh/config.omp.json" || return 1
    link "$DOTFILES_DIR/config/bat/config" "$HOME/.config/bat/config" || return 1
    # The file is linked rather than the directory so machine-local shaders and
    # themes can live beside it.
    link "$DOTFILES_DIR/config/ghostty/config" "$HOME/.config/ghostty/config" || return 1
    # git reads ~/.config/git/config before ~/.gitconfig, so identity and
    # credential helpers stay in the latter and win.
    link "$DOTFILES_DIR/config/git" "$HOME/.config/git" || return 1
    link "$DOTFILES_DIR/config/lazygit/config.yml" "$HOME/.config/lazygit/config.yml" || return 1
    # yazi and atuin write their own files beside these, so only the managed
    # files are linked, not the directories.
    link "$DOTFILES_DIR/config/yazi/yazi.toml" "$HOME/.config/yazi/yazi.toml" || return 1
    link "$DOTFILES_DIR/config/yazi/theme.toml" "$HOME/.config/yazi/theme.toml" || return 1
    link "$DOTFILES_DIR/config/atuin/config.toml" "$HOME/.config/atuin/config.toml" || return 1
    # Every flavor's atuin theme is vendored, so the themes directory is linked
    # whole; atuin only reads it. Phase 3 linked one file inside a real
    # directory, which is retired first so no backup of an empty directory is left.
    retire_link "$DOTFILES_DIR/config/atuin/themes/catppuccin-macchiato-blue.toml" "$HOME/.config/atuin/themes/catppuccin-macchiato-blue.toml" || return 1
    remove_empty_directory "$HOME/.config/atuin/themes" || return 1
    link "$DOTFILES_DIR/config/atuin/themes" "$HOME/.config/atuin/themes" || return 1
    link "$DOTFILES_DIR/config/fastfetch/config.jsonc" "$HOME/.config/fastfetch/config.jsonc" || return 1
    link "$DOTFILES_DIR/config/mise/config.toml" "$HOME/.config/mise/config.toml" || return 1
    # zsh-abbr rewrites its file with mv, which would replace a file symlink;
    # through a directory link the rewrite lands in the repository.
    link "$DOTFILES_DIR/config/zsh-abbr" "$HOME/.config/zsh-abbr" || return 1
    # Neovim reads the whole directory (init.lua, lua/, lazy-lock.json), and
    # lazy.nvim writes the lockfile beside init.lua, so the directory is linked
    # and a `:Lazy update` lands in the repository, ready to commit.
    link "$DOTFILES_DIR/config/nvim" "$HOME/.config/nvim" || return 1
    ensure_gitconfig "$HOME/.gitconfig" || return 1
}

# A destination that still links to a source this repository no longer
# provides is removed. Regular files and links elsewhere belong to the user
# and stay.
retire_link() {
    local retired_src="$1"
    local dst="$2"
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$retired_src" ]; then
        rm "$dst" || return 1
        echo "  retired: $dst"
    fi
}

# move_aside <path> <reason>: moves a file, link or directory that must not
# stay where it is to a backup, as link does with what it replaces.
move_aside() {
    local dst="$1" backup
    [ -e "$dst" ] || [ -L "$dst" ] || return 0
    backup="$(backup_path "$dst")" || return 1
    echo "  backing up $dst -> $backup ($2)"
    mv "$dst" "$backup"
}

# An empty real directory in the way of a directory link is removed; anything
# with content is left for the linker to back up.
remove_empty_directory() {
    local dir="$1"
    if [ -d "$dir" ] && [ ! -L "$dir" ] && [ -z "$(ls -A "$dir")" ]; then
        rmdir "$dir" || return 1
        echo "  removed empty: $dir"
    fi
}

# Git writes `git config --global` to ~/.config/git/config, the managed file,
# whenever ~/.gitconfig is missing. An empty one keeps identity and credential
# helpers out of the repository.
ensure_gitconfig() {
    local gitconfig="$1"
    if [ -e "$gitconfig" ] || [ -L "$gitconfig" ]; then
        echo "  present: $gitconfig"
        return 0
    fi
    printf '# Identity and credential helpers belong here; this file is not managed by the dotfiles repository.\n# Shared settings live in ~/.config/git/config.\n' > "$gitconfig" || return 1
    echo "  created: $gitconfig"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
