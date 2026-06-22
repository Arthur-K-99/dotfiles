$ErrorActionPreference = "Stop"
$dotfilesDir = $PSScriptRoot

Write-Host "==> Installing packages"
& "$dotfilesDir\scripts\install_packages.ps1"

Write-Host "==> Linking dotfiles"
& "$dotfilesDir\scripts\link_dotfiles.ps1"

Write-Host ""
Write-Host "Done. Open a new terminal to apply changes."
Write-Host "Set your terminal font to 'CaskaydiaCove NF Mono'."
