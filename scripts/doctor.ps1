$ErrorActionPreference = "Stop"
$failures = 0

function Test-Command {
    param([string]$Name)
    if (Get-Command $Name -ErrorAction SilentlyContinue) {
        Write-Host "  [ok] $Name"
    } else {
        Write-Host "  [missing] $Name" -ForegroundColor Yellow
        $script:failures++
    }
}

function Test-ManagedFile {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Write-Host "  [ok] $Path"
    } else {
        Write-Host "  [missing] $Path" -ForegroundColor Yellow
        $script:failures++
    }
}

Write-Host "Checking commands..."
@("git", "pwsh", "oh-my-posh", "bat", "fzf", "zoxide", "btop", "nvim", "gh") |
    ForEach-Object { Test-Command $_ }

Write-Host "Checking managed configuration..."
Test-ManagedFile (Join-Path $HOME "Documents/PowerShell/profile.ps1")
Test-ManagedFile (Join-Path $HOME ".config/oh-my-posh/config.omp.json")

if ($failures -gt 0) {
    throw "$failures check(s) need attention."
}

Write-Host "All checks passed."
