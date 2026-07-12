#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DOTFILES_DIR"

echo "Checking Bash syntax..."
bash -n install.sh scripts/bootstrap_tools.sh scripts/install_packages.sh \
    scripts/link_dotfiles.sh scripts/doctor.sh scripts/test.sh

echo "Checking zsh syntax..."
zsh -n home/.zshrc

if command -v pwsh >/dev/null 2>&1; then
    echo "Checking PowerShell syntax..."
    pwsh -NoProfile -NonInteractive -Command '
        $parseErrors = @()
        Get-ChildItem -Path . -Recurse -Filter *.ps1 | ForEach-Object {
            $tokens = $null
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile(
                $_.FullName,
                [ref]$tokens,
                [ref]$errors
            ) > $null
            $parseErrors += $errors
        }
        if ($parseErrors.Count) {
            $parseErrors | Format-List
            exit 1
        }
    '
fi

if command -v oh-my-posh >/dev/null 2>&1; then
    echo "Checking oh-my-posh configuration..."
    oh-my-posh config export --config config/oh-my-posh/config.omp.json --format json >/dev/null
fi

echo "All static checks passed."
