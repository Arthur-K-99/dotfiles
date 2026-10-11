# Shared Windows installer functions. Importing this file performs no setup.

function Get-DotfilesPathItem {
    param([string]$Path)
    try {
        Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    } catch {
        if ($_.CategoryInfo.Category -ne 'ObjectNotFound') { throw }
    }
}

function Test-DotfilesManagedFile {
    param([string]$Source, [string]$Destination)
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { return $false }
    $item = Get-DotfilesPathItem $Destination
    if (-not $item -or $item.PSIsContainer) { return $false }
    if ($item.LinkType -eq 'SymbolicLink') {
        $target = [string]$item.Target
        if (-not [IO.Path]::IsPathRooted($target)) { $target = Join-Path $item.DirectoryName $target }
        $comparison = [StringComparison]::Ordinal
        if ($env:OS -eq 'Windows_NT') { $comparison = [StringComparison]::OrdinalIgnoreCase }
        return [string]::Equals([IO.Path]::GetFullPath($target), [IO.Path]::GetFullPath($Source), $comparison) -and
            (Test-Path -LiteralPath $Destination -PathType Leaf)
    }
    # Broken or different links must never be mistaken for fallback copies.
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    return (Get-FileHash -LiteralPath $Source -Algorithm SHA256 -ErrorAction Stop).Hash -eq
        (Get-FileHash -LiteralPath $Destination -Algorithm SHA256 -ErrorAction Stop).Hash
}

function Move-DotfilesToBackup {
    param([string]$Path)
    $base = "$Path.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
    $backup = $base
    $suffix = 1
    while (Get-DotfilesPathItem $backup) { $backup = "$base.$suffix"; $suffix++ }
    Move-Item -LiteralPath $Path -Destination $backup -ErrorAction Stop
    Write-Host "  backed up: $Path -> $backup"
    return $backup
}

function Test-DotfilesSymlinkUnavailable {
    param([System.Management.Automation.ErrorRecord]$Failure)
    if ($Failure.FullyQualifiedErrorId -match 'NewItemSymbolicLinkElevationRequired|SymbolicLinkNotSupported') { return $true }
    $exception = $Failure.Exception
    while ($exception) {
        if ($exception -is [PlatformNotSupportedException] -or $exception -is [NotSupportedException]) { return $true }
        if ($exception -is [System.ComponentModel.Win32Exception] -and $exception.NativeErrorCode -in @(1, 50, 1314)) { return $true }
        if ($exception -is [IO.IOException] -and ($exception.HResult -band 0xFFFF) -in @(1, 50, 1314)) { return $true }
        $exception = $exception.InnerException
    }
    return $false
}

function Remove-DotfilesCreatedPath {
    param([string]$Path)
    $item = Get-DotfilesPathItem $Path
    if (-not $item) { return }
    if ($item.PSIsContainer -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    } else { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
}

function New-DotfilesSymbolicLink {
    param([string]$Source, [string]$Destination)
    if ([System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($Source) -or
        [System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($Destination)) {
        # New-Item interprets wildcard characters in Target, even when the file exists literally.
        if ([IO.File].GetMethod('CreateSymbolicLink', [type[]]@([string], [string]))) {
            [IO.File]::CreateSymbolicLink($Destination, $Source) | Out-Null
            return
        }
        throw [NotSupportedException]::new('This PowerShell edition cannot create symbolic links for literal wildcard-containing paths. Using a copy instead.')
    }
    New-Item -ItemType SymbolicLink -Path $Destination -Target $Source -ErrorAction Stop | Out-Null
}

function Set-DotfilesManagedFile {
    param([string]$Source, [string]$Destination)
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "Managed source is missing or is not a file: $Source" }
    if (Test-DotfilesManagedFile $Source $Destination) { Write-Host "  already managed: $Destination"; return }
    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    }
    $backup = $null
    if (Get-DotfilesPathItem $Destination) { $backup = Move-DotfilesToBackup $Destination }
    try {
        try {
            New-DotfilesSymbolicLink $Source $Destination
            Write-Host "  linked: $Destination"
        } catch {
            if (-not (Test-DotfilesSymlinkUnavailable $_)) { throw }
            Remove-DotfilesCreatedPath $Destination
            Copy-Item -LiteralPath $Source -Destination $Destination -ErrorAction Stop
            Write-Host "  copied (symbolic links unavailable): $Destination"
        }
        if (-not (Test-DotfilesManagedFile $Source $Destination)) { throw "Managed file verification failed: $Destination" }
    } catch {
        $originalFailure = $_
        try {
            Remove-DotfilesCreatedPath $Destination
            if ($backup) { Move-Item -LiteralPath $backup -Destination $Destination -ErrorAction Stop }
        } catch {
            throw "Could not restore '$Destination'. Backup: '$backup'. Setup error: $($originalFailure.Exception.Message). Restore error: $($_.Exception.Message)"
        }
        throw $originalFailure
    }
}

function Get-DotfilesCommandPath {
    param([string]$Name)
    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
}

function Update-DotfilesProcessPath {
    param([string[]]$RegisteredPaths = @([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User')))
    $paths = @($env:PATH) + $RegisteredPaths
    $seen = @{}
    $entries = foreach ($pathValue in $paths) {
        foreach ($entry in ($pathValue -split [regex]::Escape([string][IO.Path]::PathSeparator))) {
            if ($entry -and -not $seen.ContainsKey($entry)) { $seen[$entry] = $true; $entry }
        }
    }
    $env:PATH = $entries -join [IO.Path]::PathSeparator
}

function Get-DotfilesProfilePaths {
    $result = [ordered]@{}
    foreach ($edition in @('PowerShell', 'WindowsPowerShell')) {
        $shellName = 'pwsh.exe'
        if ($edition -eq 'WindowsPowerShell') { $shellName = 'powershell.exe' }
        $shellPath = Get-DotfilesCommandPath $shellName
        if (-not $shellPath) { throw "Cannot discover $edition profile: $shellName is unavailable. Reopen PowerShell and rerun install.ps1." }
        $profileOutput = @(& $shellPath -NoLogo -NoProfile -NonInteractive -Command '$PROFILE.CurrentUserAllHosts')
        if ($LASTEXITCODE -ne 0 -or $profileOutput.Count -ne 1 -or -not [IO.Path]::IsPathRooted([string]$profileOutput[0])) {
            throw "Cannot discover the current user's $edition profile with $shellName."
        }
        $result[$edition] = ([string]$profileOutput[0]).Trim()
    }
    return $result
}

function Get-DotfilesManagedFiles {
    param([string]$DotfilesDir, [string]$HomeDirectory)
    $profiles = Get-DotfilesProfilePaths
    foreach ($profilePath in $profiles.Values) {
        [pscustomobject]@{ Source = Join-Path $DotfilesDir 'config/powershell/profile.ps1'; Destination = $profilePath }
    }
    [pscustomobject]@{
        Source = Join-Path $DotfilesDir 'config/oh-my-posh/config.omp.json'
        Destination = Join-Path $HomeDirectory '.config/oh-my-posh/config.omp.json'
    }
    # The profile points BAT_CONFIG_PATH at this copy of the shared bat configuration.
    [pscustomobject]@{
        Source = Join-Path $DotfilesDir 'config/bat/config'
        Destination = Join-Path $HomeDirectory '.config/bat/config'
    }
}

function Invoke-DotfilesNativeCommand {
    param([string]$Command, [string[]]$Arguments, [switch]$Quiet)
    # Expected nonzero statuses are interpreted by the caller, independently of user preferences.
    $PSNativeCommandUseErrorActionPreference = $false
    if ($Quiet) { & $Command @Arguments | Out-Null }
    else { & $Command @Arguments | Out-Host }
    return $LASTEXITCODE
}

function Test-DotfilesNerdFont {
    foreach ($key in @('HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts', 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts')) {
        if (-not (Test-Path -LiteralPath $key)) { continue }
        $fontEntries = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
        foreach ($property in $fontEntries.PSObject.Properties) {
            if ($property.Name -match 'CaskaydiaCove' -and $property.Value -is [string]) {
                $fontPath = $property.Value
                if ([IO.Path]::IsPathRooted($fontPath)) {
                    if (Test-Path -LiteralPath $fontPath -PathType Leaf) { return $true }
                } else {
                    foreach ($fontDirectory in @((Join-Path $env:WINDIR 'Fonts'), (Join-Path $env:LOCALAPPDATA 'Microsoft/Windows/Fonts'))) {
                        if (Test-Path -LiteralPath (Join-Path $fontDirectory $fontPath) -PathType Leaf) { return $true }
                    }
                }
            }
        }
    }
    return $false
}

function Invoke-DotfilesFontInstall {
    if (Test-DotfilesNerdFont) { Write-Host '  already installed: CaskaydiaCove Nerd Font'; return }
    $promptCommand = Get-DotfilesCommandPath 'oh-my-posh'
    if (-not $promptCommand) { throw 'oh-my-posh is unavailable after package installation. Reopen PowerShell and rerun install.ps1 to install the font.' }
    Write-Host 'Installing CaskaydiaCove Nerd Font...'
    $code = Invoke-DotfilesNativeCommand $promptCommand @('font', 'install', 'CascadiaCode')
    if ($code -ne 0) { throw "Font installation failed (exit code $code). Rerun install.ps1 to retry." }
    if (-not (Test-DotfilesNerdFont)) { throw 'CaskaydiaCove Nerd Font was not found after installation. Rerun install.ps1 to retry.' }
}

function Invoke-DotfilesPackageInstall {
    param([string]$DotfilesDir)
    $wingetCommand = Get-DotfilesCommandPath 'winget'
    if (-not $wingetCommand) { throw 'winget is required. Install App Installer from the Microsoft Store and rerun install.ps1.' }
    $packages = Get-Content -LiteralPath (Join-Path $DotfilesDir 'packages/winget.txt') |
        ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^#' }
    Write-Host 'Installing packages via winget...'
    foreach ($package in $packages) {
        $code = Invoke-DotfilesNativeCommand $wingetCommand @('list', '--id', $package, '--exact', '--accept-source-agreements') -Quiet
        if ($code -eq 0) { Write-Host "  already installed: $package"; continue }
        # APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND (0x8A150014).
        if ($code -ne -1978335212) { throw "winget could not check $package (exit code $code). Rerun install.ps1 after correcting the error." }
        Write-Host "  installing: $package"
        $code = Invoke-DotfilesNativeCommand $wingetCommand @('install', '--id', $package, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements')
        if ($code -ne 0) { throw "winget failed to install $package (exit code $code). Rerun install.ps1 to retry." }
    }
    Update-DotfilesProcessPath
    Invoke-DotfilesFontInstall
}

function Invoke-DotfilesLink {
    param([string]$DotfilesDir, [string]$HomeDirectory)
    Write-Host 'Linking native Windows configuration...'
    $files = @(Get-DotfilesManagedFiles $DotfilesDir $HomeDirectory)
    foreach ($file in $files) { Set-DotfilesManagedFile $file.Source $file.Destination }
}

function Invoke-DotfilesDoctor {
    param([string]$DotfilesDir, [string]$HomeDirectory)
    $failures = 0
    Write-Host 'Checking commands...'
    foreach ($name in @('git', 'pwsh', 'oh-my-posh', 'bat', 'fzf', 'zoxide', 'btop', 'nvim', 'gh', 'wt')) {
        if (Get-DotfilesCommandPath $name) { Write-Host "  [ok] $name" }
        else { Write-Host "  [missing] $name"; $failures++ }
    }
    Write-Host 'Checking managed configuration...'
    try {
        $files = @(Get-DotfilesManagedFiles $DotfilesDir $HomeDirectory)
        foreach ($file in $files) {
            if (Test-DotfilesManagedFile $file.Source $file.Destination) { Write-Host "  [ok] $($file.Destination)" }
            else { Write-Host "  [missing or stale] $($file.Destination)"; $failures++ }
        }
    } catch { Write-Host "  [failed] $($_.Exception.Message)"; $failures++ }
    if (Test-DotfilesNerdFont) { Write-Host '  [ok] CaskaydiaCove Nerd Font' }
    else { Write-Host '  [missing] CaskaydiaCove Nerd Font'; $failures++ }
    if ($failures) { throw "$failures check(s) need attention. Rerun install.ps1 to repair the setup, then run scripts/doctor.ps1 again." }
    Write-Host 'All checks passed.'
}

function Invoke-DotfilesInstall {
    param([string]$DotfilesDir, [string]$HomeDirectory)
    $stage = 'Installing packages'
    try {
        Write-Host "==> $stage"
        Invoke-DotfilesPackageInstall $DotfilesDir
        $stage = 'Linking dotfiles'
        Write-Host "==> $stage"
        Invoke-DotfilesLink $DotfilesDir $HomeDirectory
        $stage = 'Verifying setup'
        Write-Host "==> $stage"
        Invoke-DotfilesDoctor $DotfilesDir $HomeDirectory
    } catch {
        $entrypoint = Join-Path $DotfilesDir 'install.ps1'
        throw "$stage failed: $($_.Exception.Message) Completed setup remains in place. Fix the reported issue, then rerun: & '$($entrypoint.Replace("'", "''"))'"
    }
    Write-Host ''
    Write-Host "Done. Open a new terminal and set its font to 'CaskaydiaCove NF Mono'."
}
