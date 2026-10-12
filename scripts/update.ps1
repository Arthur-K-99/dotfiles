# Brings an installed Windows machine up to date: install.ps1's stages run
# again with -Update, so besides adding whatever is missing they upgrade the
# packages packages/winget.txt declares and the PowerShell modules, upgrade
# mise's runtimes, the yazi flavors and the Neovim parsers and language
# servers, and finish with the doctor. Neovim plugins stay on lazy-lock.json.
# It does not pull this repository: `git pull` first to get its changes.
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib/windows.ps1")

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-DotfilesInstall -DotfilesDir (Split-Path -Parent $PSScriptRoot) -HomeDirectory $HOME -Update
}
