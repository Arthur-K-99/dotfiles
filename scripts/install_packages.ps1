$ErrorActionPreference = "Stop"
$dotfilesDir = Split-Path -Parent $PSScriptRoot
$packageList = Get-Content "$dotfilesDir\packages\winget.txt" `
    | Where-Object { $_ -notmatch '^\s*#' -and $_ -match '\S' }

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "winget is required. Install App Installer from the Microsoft Store and run this script again."
}

Write-Host "Installing packages via winget..."
foreach ($pkg in $packageList) {
    winget list --id $pkg --exact --accept-source-agreements | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  already installed: $pkg"
        continue
    }

    Write-Host "  installing $pkg..."
    winget install --id $pkg --exact --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "winget failed to install $pkg (exit code $LASTEXITCODE)"
    }
}

# Font via oh-my-posh (after oh-my-posh is installed)
if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
    Write-Host "Installing CaskaydiaCove Nerd Font..."
    oh-my-posh font install CascadiaCode
}
