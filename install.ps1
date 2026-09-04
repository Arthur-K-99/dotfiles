$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "scripts/lib/windows.ps1")

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-DotfilesInstall -DotfilesDir $PSScriptRoot -HomeDirectory $HOME
}
