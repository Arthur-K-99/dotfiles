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

# The Nerd Font family that Ghostty and the Windows Terminal fragment select.
DOTFILES_FONT_FAMILY="CaskaydiaCove Nerd Font Mono"

# dotfiles_linux_font_installed: fontconfig finds DOTFILES_FONT_FAMILY in one
# of its font directories, the user's or the system's.
dotfiles_linux_font_installed() {
    fc-list -q "$DOTFILES_FONT_FAMILY" 2>/dev/null
}

# dotfiles_is_wsl: WSL kernels name themselves in the release, such as
# 6.6.87.2-microsoft-standard-WSL2 (WSL 1: 4.4.0-19041-Microsoft). Containers
# share the host's kernel, so Docker on a Windows host counts as WSL too.
dotfiles_is_wsl() {
    case "$(uname -r)" in
        *[Mm]icrosoft*) return 0 ;;
    esac
    return 1
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

# Flavor-dependent names come from the configuration files themselves, so
# scripts/theme.sh can switch flavor without touching the installers.
# dotfiles_bat_theme <bat config>: the theme bat is told to use.
dotfiles_bat_theme() {
    sed -n 's/^--theme="\(.*\)"$/\1/p' "$1" | head -n 1
}

# dotfiles_yazi_flavors <theme.toml>: the dark and light flavor packages, once
# each (Latte serves both halves after `scripts/theme.sh latte`).
dotfiles_yazi_flavors() {
    sed -E -n 's/^(dark|light) = "([^"]*)"[[:space:]]*$/\2/p' "$1" | awk '!seen[$0]++'
}

# The Neovim configuration needs the nvim-treesitter main branch, which
# requires Neovim 0.12 (vim.lsp.config, the other 0.11 feature it relies on,
# is older). Debian 12 (0.7), Debian 13 (0.10), Ubuntu 24.04 (0.9) and Ubuntu
# 26.04 (0.11) package older releases, so the Linux bootstrap installs from
# the GitHub release when the installed version is below this.
DOTFILES_NVIM_MINIMUM="0.12.0"

# dotfiles_nvim_version [nvim]: the version of a Neovim binary, from the first
# line of --version ("NVIM v0.12.6", or "NVIM v0.12.0-dev-123+g..." for a
# development build, whose suffix is dropped).
dotfiles_nvim_version() {
    local first_line
    first_line="$("${1:-nvim}" --version 2>/dev/null | head -n 1)" || return 1
    case "$first_line" in
        "NVIM v"*) ;;
        *) return 1 ;;
    esac
    first_line="${first_line#NVIM v}"
    first_line="${first_line%%[^0-9.]*}"
    [ -n "$first_line" ] || return 1
    printf '%s\n' "$first_line"
}

# dotfiles_version_at_least <version> <minimum>: dotted numeric versions,
# missing components count as zero.
dotfiles_version_at_least() {
    local have="$1" want="$2" have_part want_part
    while [ -n "$have" ] || [ -n "$want" ]; do
        have_part="${have%%.*}"
        want_part="${want%%.*}"
        [ "$have" = "${have#*.}" ] && have="" || have="${have#*.}"
        [ "$want" = "${want#*.}" ] && want="" || want="${want#*.}"
        if [ "${have_part:-0}" -gt "${want_part:-0}" ]; then
            return 0
        elif [ "${have_part:-0}" -lt "${want_part:-0}" ]; then
            return 1
        fi
    done
    return 0
}

# nvim-treesitter compiles parsers with the tree-sitter CLI, 0.26.1 or newer.
# Debian 13 packages 0.22 and Ubuntu 24.04 0.20, so the Linux bootstrap
# installs the GitHub release when the installed version is below this.
DOTFILES_TREE_SITTER_MINIMUM="0.26.1"

# The tree-sitter CLI releases for Linux are built against glibc 2.39. On an
# older glibc, such as Debian 12's 2.36, a release does not start at all
# (arm64 since 0.26) or starts with a "weak version" warning (x86_64 0.27.1),
# and with the latter every Debian 12 test hung installing a parser. The
# bootstrap leaves out a release the loader complains about and records
# "<tag> <glibc>"
# in this file, so a rerun does not fetch the same release again and the
# doctor can tell a CLI left out on purpose from a missing one. Neovim then
# skips compiling parsers, as on Windows without a C compiler.
dotfiles_tree_sitter_record() {
    printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/tree-sitter-unsupported"
}

# dotfiles_tree_sitter_glibc_error [tree-sitter]: prints the loader's
# complaint, and succeeds, when the binary wants a newer glibc than this one.
dotfiles_tree_sitter_glibc_error() {
    local errors
    errors="$("${1:-tree-sitter}" --version 2>&1 >/dev/null)" || :
    case "$errors" in
        *"GLIBC_"*" not found"*) printf '%s\n' "$errors" ;;
        *) return 1 ;;
    esac
}

# dotfiles_glibc_version: the C library version of a glibc system ("2.36");
# fails on macOS and musl systems.
dotfiles_glibc_version() {
    local version
    version="$(getconf GNU_LIBC_VERSION 2>/dev/null)" || return 1
    case "$version" in
        "glibc "?*) printf '%s\n' "${version#glibc }" ;;
        *) return 1 ;;
    esac
}

# dotfiles_tree_sitter_version [tree-sitter]: the version of a tree-sitter CLI
# binary, from "tree-sitter 0.27.1".
dotfiles_tree_sitter_version() {
    local first_line
    first_line="$("${1:-tree-sitter}" --version 2>/dev/null | head -n 1)" || return 1
    case "$first_line" in
        "tree-sitter "*) ;;
        *) return 1 ;;
    esac
    first_line="${first_line#tree-sitter }"
    first_line="${first_line%%[^0-9.]*}"
    [ -n "$first_line" ] || return 1
    printf '%s\n' "$first_line"
}
