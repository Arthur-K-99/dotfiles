$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib/windows.ps1")

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-DotfilesRuntimeInstall
}
