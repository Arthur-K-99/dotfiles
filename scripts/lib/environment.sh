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

# dotfiles_login_shell: the shell new terminals start for this user, from
# the account database (getent on Linux, Directory Services on macOS), since
# SHELL can be unset (cron, containers) or stale after chsh until the next
# login; SHELL only when neither answers.
dotfiles_login_shell() {
    local user shell=""
    user="$(id -un 2>/dev/null)" || user=""
    if [ -n "$user" ] && command -v getent >/dev/null 2>&1; then
        shell="$(getent passwd "$user" 2>/dev/null | cut -d: -f7)" || shell=""
    elif [ -n "$user" ] && command -v dscl >/dev/null 2>&1; then
        shell="$(dscl . -read "/Users/$user" UserShell 2>/dev/null | sed -n 's/^UserShell: //p')" || shell=""
    fi
    printf '%s\n' "${shell:-${SHELL:-}}"
}

# dotfiles_curl <curl arguments>: curl as every download here runs it, into
# a file (-o). --retry 7 retries timeouts, names that do not resolve and
# HTTP 408, 429, 500, 502, 503 and 504 answers, waiting 1, 2, 4 ... 64
# seconds (about two minutes). --fail-with-body fails on an HTTP error as -f
# does, but macOS's curl 8.7.1 exits 56 for -f over HTTP/2, which --retry
# skips, and 22 for this. --connect-timeout 30 bounds a host that does not
# answer, which otherwise costs the system's limit a try (75 seconds on
# macOS, about 130 on Linux). --speed-limit 1 with --speed-time 60 ends a try
# that has averaged under a byte a second for a minute, waiting for the
# answer included. Both end as timeouts, so they are retried, and no retry
# starts after 180 seconds (--retry-max-time), which also caps a server's
# Retry-After. A retry starts a file over but appends to stdout, after what
# the stalled try wrote, so a caller that reads the answer reads a file.
dotfiles_curl() {
    curl --fail-with-body -sSL --connect-timeout 30 --speed-limit 1 \
        --speed-time 60 --retry 7 --retry-max-time 180 "$@"
}

# dotfiles_updating: scripts/update.sh exports DOTFILES_UPDATE=1 for the
# install stages, which then bring what they installed to the newest release
# they may take instead of keeping whatever is present.
dotfiles_updating() {
    [ "${DOTFILES_UPDATE:-0}" = 1 ]
}

# DOTFILES_MINIMUM_RELEASE_AGE: how long a GitHub release must have been
# public before the bootstrap installs it (see release_tag in
# bootstrap_tools.sh). A whole number with a unit, s, m, h, d or w, such as
# 12h or 3d; 0 turns the delay off. Unset or empty, it is a day.
DOTFILES_MINIMUM_RELEASE_AGE_DEFAULT=1d

# dotfiles_minimum_release_age_label: the setting in effect, as written.
dotfiles_minimum_release_age_label() {
    printf '%s\n' "${DOTFILES_MINIMUM_RELEASE_AGE:-$DOTFILES_MINIMUM_RELEASE_AGE_DEFAULT}"
}

# dotfiles_minimum_release_age: the setting in seconds; fails, saying what is
# accepted, on anything else.
dotfiles_minimum_release_age() {
    local value number unit
    value="$(dotfiles_minimum_release_age_label)"
    number="${value%[smhdw]}"
    unit="${value#"$number"}"
    # Up to nine digits, which no unit can overflow.
    case "$number" in
        ''|*[!0-9]*|??????????*) number="" ;;
    esac
    if [ "$value" = 0 ]; then
        echo 0
        return 0
    elif [ -z "$number" ] || [ -z "$unit" ]; then
        echo "DOTFILES_MINIMUM_RELEASE_AGE=$value is not a whole number with a unit (s, m, h, d or w), such as 12h or 3d; 0 turns the delay off." >&2
        return 1
    fi
    case "$unit" in
        s) echo $((10#$number)) ;;
        m) echo $((10#$number * 60)) ;;
        h) echo $((10#$number * 3600)) ;;
        d) echo $((10#$number * 86400)) ;;
        w) echo $((10#$number * 604800)) ;;
    esac
}

# dotfiles_utc_seconds <2026-10-14T08:00:00Z>: seconds since the epoch for a
# UTC time as the GitHub API writes it. Pure arithmetic (Howard Hinnant's
# days-from-civil), since GNU and BSD date parse dates differently; the
# release age then compares numbers, which no locale can reorder.
dotfiles_utc_seconds() {
    local year month day era year_of_era day_of_year day_of_era
    case "$1" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
        *) return 1 ;;
    esac
    year=$((10#${1:0:4}))
    month=$((10#${1:5:2}))
    day=$((10#${1:8:2}))
    [ "$month" -gt 2 ] || year=$((year - 1))
    era=$((year / 400))
    year_of_era=$((year - era * 400))
    day_of_year=$(((153 * ((month + 9) % 12) + 2) / 5 + day - 1))
    day_of_era=$((year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year))
    echo $(((era * 146097 + day_of_era - 719468) * 86400 + 10#${1:11:2} * 3600 + 10#${1:14:2} * 60 + 10#${1:17:2}))
}

# dotfiles_utc_time <seconds since the epoch>: the UTC time in the API's form,
# with GNU or BSD date.
dotfiles_utc_time() {
    date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

# dotfiles_apt_unheld <held packages> <package>: fails, saying so, when the
# package is in the list `apt-mark showhold` printed. apt-get install -y stops
# with "Held packages were changed" when a held package has an upgrade, so the
# installers leave held packages at the version the user chose.
dotfiles_apt_unheld() {
    if printf '%s\n' "$1" | grep -qxF -- "$2"; then
        echo "  held, left alone: $2 (sudo apt-mark unhold $2 to upgrade it)"
        return 1
    fi
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
