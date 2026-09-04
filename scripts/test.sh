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
