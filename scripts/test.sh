#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

check_bash_syntax() {
    local script
    # Bash parses only the first file after -n; check every script separately.
    while IFS= read -r -d '' script; do
        bash -n "$script" || return
    done < <(find "$1" -type d -name .git -prune -o -type f -name '*.sh' -print0)
}

check_config_syntax() {
    local file
    while IFS= read -r -d '' file; do
        case "$file" in
            *.toml) python3 -I -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' "$file" || return ;;
            *.json) python3 -I -c 'import sys, json; json.load(open(sys.argv[1]))' "$file" || return ;;
            # JSON with comments: the repository keeps comments on their own lines.
            *.jsonc) python3 -I -c 'import sys, json, re; json.loads(re.sub(r"^\s*//.*$", "", open(sys.argv[1]).read(), flags=re.M))' "$file" || return ;;
        esac
    done < <(find "$1" -type f \( -name '*.toml' -o -name '*.json' -o -name '*.jsonc' \) -print0)
}

# Loads the tmux configuration into a private server with an empty home, so
# the plugin lines (guarded by file checks) are skipped. source-file reports
# parse errors to the client; a configuration given with -f would only show
# them in the first attached window.
check_tmux_config() {
    local work status socket
    work="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-tmux-check.XXXXXX")" || return 1
    mkdir -p "$work/home"
    # A named socket stays short: socket paths are limited to about 100 bytes.
    socket="dotfiles-check-$$-${work##*.}"
    # The status is captured in a condition so errexit cannot skip the cleanup.
    if HOME="$work/home" tmux -L "$socket" -f /dev/null start-server \; \
        set-option -g exit-empty off \; source-file "$1" > "$work/output" 2>&1; then
        status=0
    else
        status=$?
    fi
    tmux -L "$socket" kill-server >/dev/null 2>&1 || :
    if [ "$status" -ne 0 ]; then
        cat "$work/output" >&2
        rm -rf "$work"
        return 1
    fi
    rm -rf "$work"
}

# Parses every Lua file of the Neovim configuration and compares the plugin
# specs with lazy-lock.json, without loading the configuration or any plugin:
# `nvim -l` runs a script with no user configuration, so no network is touched.
check_nvim_config() {
    nvim -l "$DOTFILES_DIR/tests/nvim_check.lua" "$1"
}

test_main() {
    echo "Checking Bash syntax..."
    check_bash_syntax "$DOTFILES_DIR"

    if command -v zsh >/dev/null 2>&1; then
        echo "Checking zsh syntax..."
        zsh -n "$DOTFILES_DIR/home/.zshrc"
    else
        echo "SKIP: zsh syntax and shell behavior checks (zsh is not installed)."
    fi

    echo "Checking Unix installer behavior..."
    bash "$DOTFILES_DIR/tests/unix.Tests.sh"

    if command -v pwsh >/dev/null 2>&1; then
        echo "Checking PowerShell syntax and installer behavior..."
        pwsh -NoProfile -NonInteractive -File "$DOTFILES_DIR/tests/windows.Tests.ps1"
    else
        echo "SKIP: PowerShell checks (pwsh is not installed; Windows CI runs both editions)."
    fi

    if command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' >/dev/null 2>&1; then
        echo "Checking TOML and JSON configuration files..."
        check_config_syntax "$DOTFILES_DIR/config"
    else
        echo "SKIP: TOML and JSON configuration check (python3 with tomllib is not installed)."
    fi

    if command -v tmux >/dev/null 2>&1; then
        echo "Checking tmux configuration..."
        check_tmux_config "$DOTFILES_DIR/config/tmux/tmux.conf"
    else
        echo "SKIP: tmux configuration check (tmux is not installed)."
    fi

    if command -v nvim >/dev/null 2>&1; then
        echo "Checking Neovim configuration..."
        check_nvim_config "$DOTFILES_DIR/config/nvim"
    else
        echo "SKIP: Neovim configuration check (nvim is not installed)."
    fi

    if command -v ghostty >/dev/null 2>&1; then
        echo "Checking Ghostty configuration..."
        ghostty +validate-config --config-file="$DOTFILES_DIR/config/ghostty/config"
    else
        echo "SKIP: Ghostty configuration check (ghostty is not installed)."
    fi

    if command -v oh-my-posh >/dev/null 2>&1; then
        echo "Checking oh-my-posh configuration..."
        oh-my-posh config export --config "$DOTFILES_DIR/config/oh-my-posh/config.omp.json" --format json >/dev/null
    else
        echo "SKIP: oh-my-posh configuration check (oh-my-posh is not installed)."
    fi

    echo "All available checks passed."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    test_main "$@"
fi
