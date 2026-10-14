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
    # The profile points EZA_CONFIG_DIR at this directory.
    [pscustomobject]@{
        Source = Join-Path $DotfilesDir 'config/eza/theme.yml'
        Destination = Join-Path $HomeDirectory '.config/eza/theme.yml'
    }
    # Git for Windows reads $HOME/.config/git/config before ~/.gitconfig, so the
    # shared settings live here and identity stays in ~/.gitconfig, which wins.
    foreach ($name in @('config', 'ignore', 'catppuccin.gitconfig')) {
        [pscustomobject]@{
            Source = Join-Path $DotfilesDir "config/git/$name"
            Destination = Join-Path $HomeDirectory ".config/git/$name"
        }
    }
    # The profile points LG_CONFIG_FILE, YAZI_CONFIG_HOME and ATUIN_CONFIG_DIR at
    # these, and runs fastfetch with --config. yazi and atuin write their own
    # files beside them, so the files are managed one by one rather than their
    # directories. Every flavor's atuin theme is vendored; config.toml names one.
    foreach ($relative in @('lazygit/config.yml', 'yazi/yazi.toml', 'yazi/theme.toml', 'atuin/config.toml',
            'atuin/themes/catppuccin-latte-blue.toml', 'atuin/themes/catppuccin-frappe-blue.toml',
            'atuin/themes/catppuccin-macchiato-blue.toml', 'atuin/themes/catppuccin-mocha-blue.toml',
            'fastfetch/config.jsonc')) {
        [pscustomobject]@{
            Source = Join-Path $DotfilesDir "config/$relative"
            Destination = Join-Path $HomeDirectory ".config/$relative"
        }
    }
    # mise reads %USERPROFILE%\.config\mise\config.toml on Windows as well.
    [pscustomobject]@{
        Source = Join-Path $DotfilesDir 'config/mise/config.toml'
        Destination = Join-Path $HomeDirectory '.config/mise/config.toml'
    }
    # Windows Terminal merges fragments from %LOCALAPPDATA% at startup, so the
    # user's settings.json is never rewritten.
    [pscustomobject]@{
        Source = Join-Path $DotfilesDir 'config/windows-terminal/fragment.json'
        Destination = Join-Path (Get-DotfilesLocalAppData $HomeDirectory) 'Microsoft/Windows Terminal/Fragments/dotfiles/fragment.json'
    }
    # Neovim reads %LOCALAPPDATA%\nvim (its stdpath("config") on Windows). The
    # files are managed one by one, so the list follows config/nvim without a
    # hand-kept index: init.lua, lua/**/*.lua and lazy-lock.json, which lazy.nvim
    # rewrites through the link on `:Lazy update`.
    Get-DotfilesNeovimFiles $DotfilesDir $HomeDirectory
}

function Get-DotfilesNeovimConfigDirectory {
    param([string]$HomeDirectory)
    Join-Path (Get-DotfilesLocalAppData $HomeDirectory) 'nvim'
}

function Get-DotfilesNeovimFiles {
    param([string]$DotfilesDir, [string]$HomeDirectory)
    $source = (Get-Item -LiteralPath (Join-Path $DotfilesDir 'config/nvim') -ErrorAction Stop).FullName
    $destination = Get-DotfilesNeovimConfigDirectory $HomeDirectory
    foreach ($file in @(Get-ChildItem -LiteralPath $source -Recurse -File -Force | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($source.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        [pscustomobject]@{ Source = $file.FullName; Destination = Join-Path $destination $relative }
    }
}

function Get-DotfilesLocalAppData {
    param([string]$HomeDirectory)
    # A redirected %LOCALAPPDATA% is honoured for the real profile directory.
    # Any other home directory (the tests use temporary ones) derives the
    # default location so nothing escapes the fixture.
    if ($env:LOCALAPPDATA -and $env:USERPROFILE) {
        $comparison = [StringComparison]::Ordinal
        if ($env:OS -eq 'Windows_NT') { $comparison = [StringComparison]::OrdinalIgnoreCase }
        $home_ = [IO.Path]::GetFullPath($HomeDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $profile_ = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        if ([string]::Equals($home_, $profile_, $comparison)) { return $env:LOCALAPPDATA }
    }
    return Join-Path $HomeDirectory 'AppData/Local'
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

# Given a font name, oh-my-posh looks the Nerd Fonts release up through
# GitHub's API, which ignores GITHUB_TOKEN there and allows 60 requests an hour
# per address, so shared addresses get refused. The release's download URL
# names the same archive without an API request.
$script:DotfilesNerdFontUrl = 'https://github.com/ryanoasis/nerd-fonts/releases/latest/download/CascadiaCode.zip'

function Invoke-DotfilesFontInstall {
    if (Test-DotfilesNerdFont) { Write-Host '  already installed: CaskaydiaCove Nerd Font'; return }
    $promptCommand = Get-DotfilesCommandPath 'oh-my-posh'
    if (-not $promptCommand) { throw 'oh-my-posh is unavailable after package installation. Reopen PowerShell and rerun install.ps1 to install the font.' }
    Write-Host 'Installing CaskaydiaCove Nerd Font...'
    $code = Invoke-DotfilesNativeCommand $promptCommand @('font', 'install', $script:DotfilesNerdFontUrl)
    if ($code -ne 0) { throw "Font installation failed (exit code $code). Rerun install.ps1 to retry." }
    if (-not (Test-DotfilesNerdFont)) { throw 'CaskaydiaCove Nerd Font was not found after installation. Rerun install.ps1 to retry.' }
}

# Modules are installed for PowerShell 7, the shell Windows Terminal opens by
# default. Windows PowerShell has a separate module path, so the profile imports
# each module only when it is available.
function Get-DotfilesPowerShellModules {
    @('Terminal-Icons', 'PSFzf', 'posh-git', 'CompletionPredictor')
}

function Get-DotfilesPowerShell7 {
    $shellPath = Get-DotfilesCommandPath 'pwsh.exe'
    if (-not $shellPath) { throw 'pwsh is unavailable after package installation. Reopen PowerShell and rerun install.ps1 to install the PowerShell modules.' }
    return $shellPath
}

function Test-DotfilesPowerShellModule {
    param([string]$Name)
    $shellPath = Get-DotfilesPowerShell7
    $check = "if (Get-Module -ListAvailable -Name '$Name') { exit 0 } else { exit 3 }"
    $code = Invoke-DotfilesNativeCommand $shellPath @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $check) -Quiet
    if ($code -eq 0) { return $true }
    if ($code -eq 3) { return $false }
    throw "pwsh could not check the $Name module (exit code $code). Rerun install.ps1 after correcting the error."
}

function Install-DotfilesPowerShellModule {
    param([string]$Name)
    $shellPath = Get-DotfilesPowerShell7
    $install = "Install-Module -Name '$Name' -Scope CurrentUser -Repository PSGallery -Force -AllowClobber -ErrorAction Stop"
    $code = Invoke-DotfilesNativeCommand $shellPath @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $install)
    if ($code -ne 0) { throw "Install-Module failed for $Name (exit code $code). Rerun install.ps1 to retry." }
}

# Updating installs the gallery's newest version beside the old one when it
# is newer than the newest installed; the script exits 4 when it is not.
function Update-DotfilesPowerShellModule {
    param([string]$Name)
    $shellPath = Get-DotfilesPowerShell7
    $update = "`$installed = Get-Module -ListAvailable -Name '$Name' | Sort-Object Version -Descending | Select-Object -First 1; " +
        "`$latest = Find-Module -Name '$Name' -Repository PSGallery -ErrorAction Stop; " +
        "if ([version]`$latest.Version -le `$installed.Version) { exit 4 }; " +
        "Install-Module -Name '$Name' -Scope CurrentUser -Repository PSGallery -Force -AllowClobber -ErrorAction Stop"
    $code = Invoke-DotfilesNativeCommand $shellPath @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $update)
    if ($code -eq 4) { return $false }
    if ($code -ne 0) { throw "Updating the $Name module failed (exit code $code). Rerun scripts\update.ps1 to retry." }
    return $true
}

function Invoke-DotfilesModuleInstall {
    param([switch]$Update)
    Write-Host 'Installing PowerShell modules from the PowerShell Gallery...'
    foreach ($name in Get-DotfilesPowerShellModules) {
        if (Test-DotfilesPowerShellModule $name) {
            if (-not $Update) { Write-Host "  already installed: $name"; continue }
            if (Update-DotfilesPowerShellModule $name) { Write-Host "  updated: $name" }
            else { Write-Host "  up to date: $name" }
            continue
        }
        Write-Host "  installing: $name"
        Install-DotfilesPowerShellModule $name
        if (-not (Test-DotfilesPowerShellModule $name)) { throw "$name was not found after installation. Rerun install.ps1 to retry." }
    }
}

# winget exit codes the installers act on, from winget's returnCodes.md.
$script:WingetNoApplicationsFound = -1978335212       # 0x8A150014 APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND
$script:WingetUpdateNotApplicable = -1978335189       # 0x8A15002B: no newer version
$script:WingetUpgradeVersionUnknown = -1978335152     # 0x8A150050: the installed version is unknown
$script:WingetPackageIsPinned = -1978335128           # 0x8A150068: a pin prevents the upgrade
$script:WingetInstallTechnologyMismatch = -1978335090 # 0x8A15008E: the upgrade uses another installer type
$script:WingetRebootRequiredToFinish = -1978334967    # 0x8A150109

# Packages that host the running update: replacing Windows Terminal or
# PowerShell 7 while it runs the script would close it or fail on files in
# use, so the update names the command to run from another shell instead.
function Get-DotfilesRunningHostPackages {
    if ($env:WT_SESSION) { 'Microsoft.WindowsTerminal' }
    if ($PSVersionTable.PSEdition -eq 'Core') { 'Microsoft.PowerShell' }
}

# A plain `winget pin add` only keeps a package out of `winget upgrade --all`;
# an upgrade by id goes ahead, so the update asks for the package's pin first.
# The pin table names the package by id on its row; any other answer ("There
# are no pins configured.", no matching package) does not.
function Test-DotfilesWingetPinned {
    param([string]$WingetCommand, [string]$Package)
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $lines = @(& $WingetCommand pin list --id $Package --exact --accept-source-agreements 2>$null | ForEach-Object { [string]$_ })
    $pattern = "(^|\s)$([regex]::Escape($Package))(\s|$)"
    return @($lines | Where-Object { $_ -match $pattern }).Count -gt 0
}

# winget 1.11 cannot find some packages it installed itself by their exact
# id: rsteube.Carapace, a portable zip, is missing from `winget list --id
# rsteube.Carapace --exact` and from `winget upgrade --id` with or without
# --exact, while `winget list --id rsteube.Carapace` lists it under that id.
# This reads that listing and returns the words after the id on the row that
# names it (the installed version, an available version when there is a newer
# one, the source), or nothing when no row does. Column headers are localized,
# so the row is found by the id alone.
function Get-DotfilesWingetListedVersions {
    param([string]$WingetCommand, [string]$Package)
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $lines = @(& $WingetCommand list --id $Package --accept-source-agreements 2>$null | ForEach-Object { [string]$_ })
    $pattern = "(^|\s)$([regex]::Escape($Package))\s+(\S.*)$"
    foreach ($line in $lines) {
        # The progress spinner precedes the first line, separated by carriage returns.
        if ((($line -split "`r")[-1]) -match $pattern) { return @($Matches[2].Trim() -split '\s+') }
    }
}

# Whether winget lists the package as installed, by its exact id or else by
# the listing above. Any answer but installed or not found stops the install.
function Test-DotfilesWingetInstalled {
    param([string]$WingetCommand, [string]$Package)
    $code = Invoke-DotfilesNativeCommand $WingetCommand @('list', '--id', $Package, '--exact', '--accept-source-agreements') -Quiet
    if ($code -eq 0) { return $true }
    if ($code -ne $script:WingetNoApplicationsFound) { throw "winget could not check $Package (exit code $code). Rerun install.ps1 after correcting the error." }
    return $null -ne (Get-DotfilesWingetListedVersions $WingetCommand $Package)
}

# A blocking or gating pin that the check above missed, a package whose
# installed version winget cannot tell, and one whose upgrade needs another
# installer type are left as they are and reported. A package that winget
# upgrade cannot find is installed again by id when the listing shows a
# newer version, which replaces it.
function Update-DotfilesWingetPackage {
    param([string]$WingetCommand, [string]$Package)
    $code = Invoke-DotfilesNativeCommand $WingetCommand @('upgrade', '--id', $Package, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements')
    if ($code -eq $script:WingetNoApplicationsFound) {
        if (@(Get-DotfilesWingetListedVersions $WingetCommand $Package).Count -lt 3) { Write-Host "  up to date: $Package"; return }
        $code = Invoke-DotfilesNativeCommand $WingetCommand @('install', '--id', $Package, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements')
        if ($code -eq 0 -or $code -eq $script:WingetRebootRequiredToFinish) { Write-Host "  upgraded: $Package (installed again: winget upgrade cannot find it)" }
        else { throw "winget failed to install the newer $Package (exit code $code). Rerun scripts\update.ps1 to retry." }
    }
    elseif ($code -eq 0) { Write-Host "  upgraded: $Package" }
    elseif ($code -eq $script:WingetUpdateNotApplicable) { Write-Host "  up to date: $Package" }
    elseif ($code -eq $script:WingetRebootRequiredToFinish) { Write-Host "  upgraded: $Package (restart Windows to finish)" }
    elseif ($code -eq $script:WingetPackageIsPinned) { Write-Host "  pinned, left alone: $Package (winget pin remove --id $Package to upgrade it)" }
    elseif ($code -eq $script:WingetUpgradeVersionUnknown) { Write-Host "  left alone: $Package (winget cannot tell its installed version; winget upgrade --id $Package --exact --include-unknown)" }
    elseif ($code -eq $script:WingetInstallTechnologyMismatch) { Write-Host "  left alone: $Package (the upgrade uses another installer type; reinstall it with winget to change)" }
    else { throw "winget failed to upgrade $Package (exit code $code). Rerun scripts\update.ps1 to retry." }
}

function Invoke-DotfilesPackageInstall {
    param([string]$DotfilesDir, [switch]$Update)
    $wingetCommand = Get-DotfilesCommandPath 'winget'
    if (-not $wingetCommand) { throw 'winget is required. Install App Installer from the Microsoft Store and rerun install.ps1.' }
    $packages = Get-Content -LiteralPath (Join-Path $DotfilesDir 'packages/winget.txt') |
        ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^#' }
    $hosts = @()
    if ($Update) { $hosts = @(Get-DotfilesRunningHostPackages); Write-Host 'Installing and upgrading packages via winget...' }
    else { Write-Host 'Installing packages via winget...' }
    foreach ($package in $packages) {
        if (Test-DotfilesWingetInstalled $wingetCommand $package) {
            if (-not $Update) { Write-Host "  already installed: $package" }
            elseif ($hosts -contains $package) { Write-Host "  left alone: $package runs this update (from another shell: winget upgrade --id $package --exact)" }
            elseif (Test-DotfilesWingetPinned $wingetCommand $package) { Write-Host "  pinned, left alone: $package (winget pin remove --id $package to upgrade it)" }
            else { Update-DotfilesWingetPackage $wingetCommand $package }
            continue
        }
        Write-Host "  installing: $package"
        $code = Invoke-DotfilesNativeCommand $wingetCommand @('install', '--id', $package, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements')
        # The package is in place, as for an upgrade; the doctor finds out whether it already works.
        if ($code -eq $script:WingetRebootRequiredToFinish) { Write-Host "  installed: $package (restart Windows to finish)" }
        elseif ($code -ne 0) { throw "winget failed to install $package (exit code $code). Rerun install.ps1 to retry." }
    }
    Update-DotfilesProcessPath
    Invoke-DotfilesFontInstall
}

# The managed theme.toml names the flavors. They are packages that ya installs
# into ~/.config/yazi/flavors beside the managed files, so they are not linked.
# Reading the managed copy keeps the installers in step with scripts/theme.sh.
function Get-DotfilesYaziFlavors {
    param([string]$HomeDirectory)
    $themeFile = Join-Path $HomeDirectory '.config/yazi/theme.toml'
    if (-not (Test-Path -LiteralPath $themeFile -PathType Leaf)) { throw "The yazi theme file is missing at $themeFile. Rerun install.ps1 so the link stage provides it." }
    # Latte serves both halves after `scripts/theme.sh latte`, so names are unique.
    $flavors = @([regex]::Matches([IO.File]::ReadAllText($themeFile), '(?m)^(?:dark|light) = "([^"]+)"[ \t\r]*$') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    if ($flavors.Count -eq 0) { throw "No flavor is named in $themeFile." }
    return $flavors
}

function Get-DotfilesYaziFlavorFile {
    param([string]$HomeDirectory, [string]$Flavor)
    Join-Path $HomeDirectory ".config/yazi/flavors/$Flavor.yazi/flavor.toml"
}

# Updating, ya upgrades these flavors by name, so the user's other packages in
# package.toml stay as they are; a flavor package.toml does not list was put
# in place by hand and is left alone.
function Install-DotfilesYaziFlavors {
    param([string]$HomeDirectory, [switch]$Update)
    $yaziConfig = Join-Path $HomeDirectory '.config/yazi'
    $packageFile = Join-Path $yaziConfig 'package.toml'
    # ya reads YAZI_CONFIG_HOME like yazi does; the profile points it at the same
    # directory, and the previous value is restored once the packages are in place.
    $savedConfigHome = $env:YAZI_CONFIG_HOME
    $env:YAZI_CONFIG_HOME = $yaziConfig
    try {
        $flavors = @(Get-DotfilesYaziFlavors $HomeDirectory)
        foreach ($flavor in $flavors) {
            $flavorFile = Get-DotfilesYaziFlavorFile $HomeDirectory $flavor
            if (Test-Path -LiteralPath $flavorFile -PathType Leaf) { Write-Host "  already installed: yazi flavor $flavor"; continue }
            $yaCommand = Get-DotfilesCommandPath 'ya'
            if (-not $yaCommand) { throw 'ya is unavailable after package installation. Reopen PowerShell and rerun install.ps1 to install the yazi flavors.' }
            # A flavor that package.toml already declares is installed from there;
            # ya pkg add would reject it as a duplicate.
            $arguments = @('pkg', 'add', "yazi-rs/flavors:$flavor")
            if ((Test-Path -LiteralPath $packageFile -PathType Leaf) -and [IO.File]::ReadAllText($packageFile).Contains("flavors:$flavor")) {
                $arguments = @('pkg', 'install')
            }
            Write-Host "  installing: yazi flavor $flavor"
            $code = Invoke-DotfilesNativeCommand $yaCommand $arguments
            if ($code -ne 0) { throw "ya $($arguments -join ' ') failed (exit code $code). Rerun install.ps1 to retry." }
            if (-not (Test-Path -LiteralPath $flavorFile -PathType Leaf)) { throw "yazi flavor $flavor was not installed. Rerun install.ps1 to retry." }
        }
        if (-not $Update) { return }
        $declared = ''
        if (Test-Path -LiteralPath $packageFile -PathType Leaf) { $declared = [IO.File]::ReadAllText($packageFile) }
        $upgrades = @(foreach ($flavor in $flavors) {
            if ($declared.Contains("flavors:$flavor`"")) { "yazi-rs/flavors:$flavor" }
            else { Write-Host "  left alone: yazi flavor $flavor (not in $packageFile)" }
        })
        if (-not $upgrades.Count) { return }
        $yaCommand = Get-DotfilesCommandPath 'ya'
        if (-not $yaCommand) { throw 'ya is unavailable after package installation. Reopen PowerShell and rerun scripts\update.ps1.' }
        Write-Host '  upgrading: yazi flavors'
        $code = Invoke-DotfilesNativeCommand $yaCommand (@('pkg', 'upgrade') + $upgrades)
        if ($code -ne 0) { throw "ya pkg upgrade failed (exit code $code). Rerun scripts\update.ps1 to retry." }
    } finally {
        $env:YAZI_CONFIG_HOME = $savedConfigHome
    }
}

# --- Neovim -------------------------------------------------------------------
# The configuration needs Neovim 0.12 (the nvim-treesitter main branch);
# winget installs the current stable release. lua/dotfiles/bootstrap.lua in the
# managed configuration installs the plugins pinned in lazy-lock.json into
# %LOCALAPPDATA%\nvim-data (Neovim's data directory on Windows), then the
# Tree-sitter parsers and Mason packages, and reports on all of them. Its check
# is offline and fast; the installs are the only steps that reach the network.
$script:DotfilesNeovimMinimum = [version]'0.12.0'
# The Lua passed to nvim -c. Windows PowerShell hands native commands their
# arguments with inner double quotes intact only by luck of the legacy
# quoting, so the Lua uses single quotes and the tests push these strings
# through a real process. cquit follows each one so a Lua error ends the
# process with a failure instead of leaving a headless Neovim waiting.
$script:DotfilesNeovimStartLua = "lua if vim.v.errmsg ~= '' then os.exit(3) end"
$script:DotfilesNeovimCheckLua = "lua require('dotfiles.bootstrap').check()"
$script:DotfilesNeovimPluginsLua = "lua require('dotfiles.bootstrap').plugins()"
$script:DotfilesNeovimInstallLua = "lua require('dotfiles.bootstrap').install()"
$script:DotfilesNeovimUpdateLua = "lua require('dotfiles.bootstrap').update()"

function Get-DotfilesNeovimDataDirectory {
    param([string]$HomeDirectory)
    Join-Path (Get-DotfilesLocalAppData $HomeDirectory) 'nvim-data'
}

# The three readers below run native commands whose stderr is discarded or
# returned as data. Windows PowerShell turns redirected native stderr into a
# terminating error under Stop, so each relaxes the preference for its own scope.
function Get-DotfilesNeovimVersion {
    param([string]$Command)
    # The first line reads "NVIM v0.12.6", or "NVIM v0.12.0-dev-123+g..." for a
    # development build, whose suffix is dropped.
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $firstLine = [string](@(& $Command --version 2>$null | ForEach-Object { [string]$_ }) | Select-Object -First 1)
    if ($firstLine -match '^NVIM v(\d+(?:\.\d+){1,2})') { return [version]$Matches[1] }
    return $null
}

# One line per plugin, parser and package ("ok", "missing", "stale" or
# "skipped", the kind, the name) and the exit status, zero when nothing is
# missing or stale.
function Get-DotfilesNeovimCheck {
    param([string]$Command)
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $lines = @(& $Command --headless -c $script:DotfilesNeovimCheckLua -c 'cquit 1' 2>&1 | ForEach-Object { [string]$_ })
    return [pscustomobject]@{ Lines = $lines; ExitCode = $LASTEXITCODE }
}

# Mason installs most language servers with npm, which comes from the Node.js
# that mise installed; the directory is found through mise, not the profile.
function Get-DotfilesMiseNodeDirectory {
    $miseCommand = Get-DotfilesCommandPath 'mise'
    if (-not $miseCommand) { return $null }
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $nodePath = [string](@(& $miseCommand which node 2>$null | ForEach-Object { [string]$_ }) | Select-Object -First 1)
    if ($LASTEXITCODE -eq 0 -and $nodePath) { return Split-Path -Parent $nodePath }
    return $null
}

function Get-DotfilesNeovimCommand {
    $nvimCommand = Get-DotfilesCommandPath 'nvim'
    if (-not $nvimCommand) { throw 'nvim is unavailable after package installation. Reopen PowerShell and rerun install.ps1 to set up Neovim.' }
    $version = Get-DotfilesNeovimVersion $nvimCommand
    if (-not $version -or $version -lt $script:DotfilesNeovimMinimum) {
        throw "Neovim $($script:DotfilesNeovimMinimum) or newer is required (found $version). Run 'winget upgrade --id Neovim.Neovim --exact' and rerun install.ps1."
    }
    return $nvimCommand
}

# Runs nvim headless with one Lua command, mise's Node.js first on PATH for
# Mason's npm packages, and returns the exit status.
function Invoke-DotfilesNeovimWithNode {
    param([string]$NvimCommand, [string]$Lua)
    $savedPath = $env:PATH
    $nodeDirectory = Get-DotfilesMiseNodeDirectory
    if ($nodeDirectory) { $env:PATH = "$nodeDirectory$([IO.Path]::PathSeparator)$env:PATH" }
    try {
        return Invoke-DotfilesNativeCommand $NvimCommand @('--headless', '-c', $Lua, '-c', 'cquit 1')
    } finally { $env:PATH = $savedPath }
}

# The report decides which of the two installs runs and verifies the result.
# Updating, the plugins stay at the commits lazy-lock.json pins; update()
# then brings the parsers to the revisions the pinned nvim-treesitter names
# and the Mason packages to their latest versions.
function Install-DotfilesNeovim {
    param([switch]$Update)
    $nvimCommand = Get-DotfilesNeovimCommand
    $check = Get-DotfilesNeovimCheck $nvimCommand
    if ($check.ExitCode -eq 0) { Write-Host '  already installed: Neovim plugins, parsers and language servers' }
    else {
        if (@($check.Lines | Where-Object { $_ -match '^(missing|stale) plugin ' }).Count) {
            Write-Host '  installing: Neovim plugins from lazy-lock.json'
            $code = Invoke-DotfilesNativeCommand $nvimCommand @('--headless', '-c', $script:DotfilesNeovimPluginsLua, '-c', 'cquit 1')
            if ($code -ne 0) { throw "The Neovim plugin install failed (exit code $code). Rerun install.ps1 to retry." }
        }
        if (@($check.Lines | Where-Object { $_ -match '^missing (parser|package) ' }).Count) {
            Write-Host '  installing: Neovim parsers and language servers'
            $code = Invoke-DotfilesNeovimWithNode $nvimCommand $script:DotfilesNeovimInstallLua
            if ($code -ne 0) { throw "The Neovim parser and language server install failed (exit code $code). Rerun install.ps1 to retry." }
        }
        $check = Get-DotfilesNeovimCheck $nvimCommand
        if ($check.ExitCode -ne 0) { throw "Neovim is not fully set up after installing: $(($check.Lines | Where-Object { $_ -notmatch '^ok ' }) -join '; '). Rerun install.ps1 to retry." }
    }
    if (-not $Update) { return }
    Write-Host '  updating: Neovim parsers and language servers'
    $code = Invoke-DotfilesNeovimWithNode $nvimCommand $script:DotfilesNeovimUpdateLua
    if ($code -ne 0) { throw "The Neovim parser and language server update failed (exit code $code). Rerun scripts\update.ps1 to retry." }
}

# mise installs the runtimes declared in config/mise/config.toml, ya the yazi
# flavors and Neovim its plugins; all read files the link stage placed, so
# this stage runs after it. Updating, mise also upgrades each runtime to the
# newest release the file allows, from the home directory so that a project's
# own mise file does not decide.
function Invoke-DotfilesRuntimeInstall {
    param([string]$HomeDirectory, [switch]$Update)
    $miseCommand = Get-DotfilesCommandPath 'mise'
    if (-not $miseCommand) { throw 'mise is unavailable after package installation. Reopen PowerShell and rerun install.ps1 to install the runtimes.' }
    Write-Host 'Installing runtimes declared in the mise configuration...'
    $code = Invoke-DotfilesNativeCommand $miseCommand @('install', '--yes')
    if ($code -ne 0) { throw "mise install failed (exit code $code). Rerun install.ps1 to retry." }
    if ($Update) {
        Write-Host 'Upgrading runtimes with mise...'
        Push-Location -LiteralPath $HomeDirectory
        try { $code = Invoke-DotfilesNativeCommand $miseCommand @('upgrade', '--yes') }
        finally { Pop-Location }
        if ($code -ne 0) { throw "mise upgrade failed (exit code $code). Rerun scripts\update.ps1 to retry." }
    }
    Write-Host 'Installing yazi flavors...'
    Install-DotfilesYaziFlavors $HomeDirectory -Update:$Update
    Write-Host 'Installing Neovim plugins, parsers and language servers...'
    Install-DotfilesNeovim -Update:$Update
}

function Invoke-DotfilesLink {
    param([string]$DotfilesDir, [string]$HomeDirectory)
    Write-Host 'Linking native Windows configuration...'
    $files = @(Get-DotfilesManagedFiles $DotfilesDir $HomeDirectory)
    foreach ($file in $files) { Set-DotfilesManagedFile $file.Source $file.Destination }
    # Without ~/.gitconfig, `git config --global` writes into ~/.config/git/config,
    # the managed file. The seed is created once and never touched again.
    $gitConfig = Join-Path $HomeDirectory '.gitconfig'
    if (-not (Get-DotfilesPathItem $gitConfig)) {
        $seed = @(
            '# Identity and credential helpers belong here; this file is not managed by the dotfiles repository.'
            '# Shared settings live in ~/.config/git/config.'
            ''
        ) -join [Environment]::NewLine
        [IO.File]::WriteAllText($gitConfig, $seed)
        Write-Host "  created: $gitConfig"
    }
}

function Get-DotfilesDoctorCommands {
    @('git', 'pwsh', 'oh-my-posh', 'bat', 'eza', 'fzf', 'zoxide', 'btop', 'nvim', 'tree-sitter', 'gh', 'wt', 'fastfetch',
        'carapace', 'atuin', 'mise', 'delta', 'lazygit', 'lazydocker', 'yazi',
        'rg', 'fd', 'dust', 'duf', 'procs', 'sd', 'xh', 'hyperfine', 'glow', 'tldr', 'gum', 'direnv')
}

function Invoke-DotfilesDoctor {
    param([string]$DotfilesDir, [string]$HomeDirectory)
    $failures = 0
    Write-Host 'Checking commands...'
    foreach ($name in Get-DotfilesDoctorCommands) {
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
    Write-Host 'Checking runtimes...'
    try {
        $miseCommand = Get-DotfilesCommandPath 'mise'
        if ($miseCommand -and (Invoke-DotfilesNativeCommand $miseCommand @('which', 'node') -Quiet) -eq 0) { Write-Host '  [ok] Node.js via mise' }
        else { Write-Host '  [missing] Node.js via mise (rerun: scripts\install_runtimes.ps1)'; $failures++ }
        foreach ($flavor in Get-DotfilesYaziFlavors $HomeDirectory) {
            if (Test-Path -LiteralPath (Get-DotfilesYaziFlavorFile $HomeDirectory $flavor) -PathType Leaf) { Write-Host "  [ok] yazi flavor $flavor" }
            else { Write-Host "  [missing] yazi flavor $flavor (rerun: scripts\install_runtimes.ps1)"; $failures++ }
        }
    } catch { Write-Host "  [failed] $($_.Exception.Message)"; $failures++ }
    Write-Host 'Checking Neovim...'
    try {
        $nvimCommand = Get-DotfilesCommandPath 'nvim'
        $version = $null
        if ($nvimCommand) { $version = Get-DotfilesNeovimVersion $nvimCommand }
        $lazyFile = Join-Path (Get-DotfilesNeovimDataDirectory $HomeDirectory) 'lazy/lazy.nvim/lua/lazy/init.lua'
        if (-not ($version -and $version -ge $script:DotfilesNeovimMinimum)) {
            Write-Host "  [missing] Neovim $($script:DotfilesNeovimMinimum) or newer (found: $version; winget upgrade --id Neovim.Neovim --exact)"; $failures++
        } elseif (-not (Test-Path -LiteralPath $lazyFile -PathType Leaf)) {
            # Without lazy.nvim a start would clone it, so the doctor stops here.
            Write-Host "  [ok] Neovim $version"
            Write-Host "  [missing] lazy.nvim ($lazyFile; rerun: scripts\install_runtimes.ps1)"; $failures++
        } else {
            Write-Host "  [ok] Neovim $version"
            Write-Host '  [ok] lazy.nvim'
            # A clean headless start prints nothing and leaves v:errmsg empty; plugins
            # are never fetched at startup, so neither this nor the report reaches the network.
            $code = Invoke-DotfilesNativeCommand $nvimCommand @('--headless', '-c', $script:DotfilesNeovimStartLua, '+qa') -Quiet
            if ($code -ne 0) { Write-Host "  [missing] Neovim headless start reported errors (exit code $code)"; $failures++ }
            else {
                Write-Host '  [ok] Neovim starts without errors'
                $check = Get-DotfilesNeovimCheck $nvimCommand
                if ($check.Lines.Count -eq 0) { Write-Host '  [missing] Neovim plugins, parsers and language servers (the check printed nothing)'; $failures++ }
                foreach ($line in $check.Lines) {
                    if ($line -match '^(ok|missing|stale|skipped) (plugin|parser|package) (\S+)(.*)$') {
                        $label = "Neovim $($Matches[2]) $($Matches[3])"
                        if ($Matches[2] -eq 'package') { $label = "Neovim language server $($Matches[3])" }
                        switch ($Matches[1]) {
                            'ok' { Write-Host "  [ok] $label" }
                            'skipped' { Write-Host "  [skip] $label$($Matches[4])" }
                            'stale' { Write-Host "  [stale] $label is not at the commit lazy-lock.json pins (rerun: scripts\install_runtimes.ps1)"; $failures++ }
                            default { Write-Host "  [missing] $label (rerun: scripts\install_runtimes.ps1)"; $failures++ }
                        }
                    } else { Write-Host "  [missing] Neovim check: $line"; $failures++ }
                }
            }
        }
    } catch { Write-Host "  [failed] $($_.Exception.Message)"; $failures++ }
    Write-Host 'Checking PowerShell modules...'
    try {
        foreach ($name in Get-DotfilesPowerShellModules) {
            if (Test-DotfilesPowerShellModule $name) { Write-Host "  [ok] $name" }
            else { Write-Host "  [missing] $name"; $failures++ }
        }
    } catch { Write-Host "  [failed] $($_.Exception.Message)"; $failures++ }
    if (Test-DotfilesNerdFont) { Write-Host '  [ok] CaskaydiaCove Nerd Font' }
    else { Write-Host '  [missing] CaskaydiaCove Nerd Font'; $failures++ }
    if ($failures) { throw "$failures check(s) need attention. Rerun install.ps1 to repair the setup, then run scripts/doctor.ps1 again." }
    Write-Host 'All checks passed.'
}

# With -Update (scripts/update.ps1) the same stages also bring what they
# installed to the latest release: winget packages, PowerShell modules, mise's
# runtimes, the yazi flavors and the Neovim parsers and language servers.
function Invoke-DotfilesInstall {
    param([string]$DotfilesDir, [string]$HomeDirectory, [switch]$Update)
    $verb = 'Installing'
    $entrypoint = Join-Path $DotfilesDir 'install.ps1'
    if ($Update) { $verb = 'Updating'; $entrypoint = Join-Path $DotfilesDir 'scripts/update.ps1' }
    $stage = "$verb packages"
    try {
        Write-Host "==> $stage"
        Invoke-DotfilesPackageInstall $DotfilesDir -Update:$Update
        $stage = "$verb PowerShell modules"
        Write-Host "==> $stage"
        Invoke-DotfilesModuleInstall -Update:$Update
        $stage = 'Linking dotfiles'
        Write-Host "==> $stage"
        Invoke-DotfilesLink $DotfilesDir $HomeDirectory
        $stage = "$verb runtimes"
        Write-Host "==> $stage"
        Invoke-DotfilesRuntimeInstall $HomeDirectory -Update:$Update
        $stage = 'Verifying setup'
        Write-Host "==> $stage"
        Invoke-DotfilesDoctor $DotfilesDir $HomeDirectory
    } catch {
        throw "$stage failed: $($_.Exception.Message) Completed setup remains in place. Fix the reported issue, then rerun: & '$($entrypoint.Replace("'", "''"))'"
    }
    Write-Host ''
    if ($Update) { Write-Host 'Done. Everything is up to date and all setup checks passed.' }
    else { Write-Host "Done. Restart Windows Terminal: the Catppuccin fragment sets the font and colors for the PowerShell and Command Prompt profiles." }
}
