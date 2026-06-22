$dotfilesDir = Split-Path -Parent $PSScriptRoot
$packageList = Get-Content "$dotfilesDir\packages\winget.txt" `
    | Where-Object { $_ -notmatch '^\s*#' -and $_ -match '\S' }

Write-Host "Installing packages via winget..."
foreach ($pkg in $packageList) {
    Write-Host "  installing $pkg..."
    winget install --id $pkg --silent --accept-package-agreements --accept-source-agreements 2>&1 `
        | Select-String -NotMatch "No newer package"
}

# Font via oh-my-posh (after oh-my-posh is installed)
if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
    Write-Host "Installing CaskaydiaCove Nerd Font..."
    oh-my-posh font install CascadiaCode
}
