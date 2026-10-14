# Installs this checkout on the Windows machine running it the way the README
# does, reruns the installer, runs the update and the doctor, and starts the
# configured shells: the Windows side of `bash tests/fresh_install.sh --here`.
# tests/windows.Tests.ps1 mocks winget and every download; this is the one
# check that reaches winget's repository, the PowerShell Gallery, mise's
# runtimes, Neovim's plugins and parsers and Mason's packages, so it catches
# upstream changes such as a package that moved to another installer type.
#
# It changes the machine beyond the install: before installing it puts in an
# older fzf and Carapace (the update must upgrade them) and placeholder
# profiles (the install must back them up), and before updating it pins sd
# with winget (the update must leave it alone). Run it only on a disposable
# machine such as a CI runner:
#
#   powershell -NoProfile -File tests\fresh_install.ps1 [-Stage <stage>] [-LogDirectory <directory>]
#
# The stages run in this order: Prepare, Install, Rerun, Update, Doctor and
# Shells; All, the default, runs them one after another and then Collect,
# which copies winget's and Neovim's logs. The Fresh install (Windows)
# workflow runs one stage per step. Each stage starts its shells with PATH
# read from the registry, as a newly opened terminal has it, and writes a
# transcript into the log directory ($env:RUNNER_TEMP\fresh-install on a
# runner, otherwise under the temporary directory).
param(
    [ValidateSet('All', 'Prepare', 'Install', 'Rerun', 'Update', 'Doctor', 'Shells', 'Collect')]
    [string]$Stage = 'All',
    [string]$LogDirectory
)
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
. (Join-Path $repository 'scripts/lib/windows.ps1')

if (-not $LogDirectory) {
    $base = $env:RUNNER_TEMP
    if (-not $base) { $base = [IO.Path]::GetTempPath() }
    $LogDirectory = Join-Path $base 'fresh-install'
}
New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
$stateFile = Join-Path $LogDirectory 'state.json'

# What the Prepare stage set up, for the stages that check it later. The
# older packages give the update something to upgrade: fzf through winget
# upgrade, Carapace by installing it again, since winget 1.11's upgrade cannot
# find it (see Get-DotfilesWingetListedVersions).
$seedProfileContent = '# A profile that was here before the dotfiles install.'
$olderPackages = @('junegunn.fzf', 'rsteube.Carapace')
$pinnedPackage = 'chmln.sd'

function Assert-FreshInstall {
    param($Condition, [string]$Message)
    if (-not $Condition) { throw "Fresh install check failed: $Message" }
}

# A terminal opened after an installer sees the PATH that installers
# registered, not the one this process started with.
function Reset-FreshInstallPath {
    $env:PATH = @(foreach ($scope in @('Machine', 'User')) {
        [Environment]::GetEnvironmentVariable('Path', $scope)
    }) -join ';'
}

function Get-FreshInstallState { Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json }

function Get-FreshInstallTranscript {
    param([string]$Name)
    @(Get-Content -LiteralPath (Join-Path $LogDirectory "$Name.log") | ForEach-Object { [string]$_ })
}

# Runs PowerShell commands in a new shell from a script file under the log
# directory, with its transcript beside it, and fails when the shell does.
# A script file rather than -Command keeps the commands free of the quoting
# that Windows PowerShell applies to native arguments.
function Invoke-FreshInstallShell {
    param([string]$Shell, [string]$Name, [string]$Command, [switch]$LoadProfile)
    $transcript = Join-Path $LogDirectory "$Name.log"
    $script = Join-Path $LogDirectory "$Name.ps1"
    [IO.File]::WriteAllText($script, @"
`$ErrorActionPreference = 'Stop'
Start-Transcript -LiteralPath '$($transcript.Replace("'", "''"))' -Force | Out-Null
try {
    $Command
} finally {
    Stop-Transcript | Out-Null
}
"@)
    $arguments = @('-NoLogo', '-NonInteractive')
    if (-not $LoadProfile) { $arguments += '-NoProfile' }
    $arguments += @('-File', $script)
    Reset-FreshInstallPath
    & $Shell @arguments
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "$Name failed in $Shell (exit code $code); see $transcript" }
}

# Runs a command the way a terminal would start it and returns its exit code
# and its stdout and stderr lines apart; the shells must print nothing on stderr.
function Invoke-FreshInstallCapture {
    param([string]$Command, [string[]]$Arguments)
    Reset-FreshInstallPath
    $ErrorActionPreference = 'Continue'
    $output = @(& $Command @Arguments 2>&1)
    $code = $LASTEXITCODE
    [pscustomobject]@{
        ExitCode = $code
        Output = @($output | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ })
        Errors = @($output | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ })
    }
}

function Get-FreshInstallWinget {
    $winget = Get-DotfilesCommandPath 'winget'
    if (-not $winget) { throw 'winget is not available on this machine.' }
    return $winget
}

# Lines of winget's output without the progress spinner that precedes them.
function Invoke-FreshInstallWinget {
    param([string[]]$Arguments)
    $result = Invoke-FreshInstallCapture (Get-FreshInstallWinget) $Arguments
    $result.Output = @($result.Output | ForEach-Object { ($_ -split "`r")[-1].TrimEnd() })
    return $result
}

# The installed version winget lists for a package, and whether it lists a newer one.
function Get-FreshInstallListedVersion {
    param([string]$Package)
    $listed = @(Get-DotfilesWingetListedVersions (Get-FreshInstallWinget) $Package)
    Assert-FreshInstall ($listed.Count -ge 2) "winget does not list $Package as installed."
    [pscustomobject]@{ Installed = [version]$listed[0]; Outdated = $listed.Count -ge 3 }
}

# The runner, winget and the packages that are already there, for the record;
# then older packages and placeholder profiles for the install to find.
function Invoke-FreshInstallPrepare {
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Host "Windows: $($os.Caption) $($os.Version) build $($os.BuildNumber)"
    Write-Host "Windows PowerShell: $($PSVersionTable.PSVersion)"
    Write-Host "User: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Write-Host "Execution policies:"
    Get-ExecutionPolicy -List | Out-Host
    Write-Host 'winget --info:'
    (Invoke-FreshInstallWinget @('--info')).Output | Out-Host
    Write-Host 'Packages behind winget and Windows Terminal:'
    Get-AppxPackage | Where-Object { $_.Name -match 'DesktopAppInstaller|WindowsTerminal|UI\.Xaml|VCLibs|WindowsAppRuntime' } |
        Sort-Object Name | Format-Table Name, Version, Architecture -AutoSize | Out-Host
    Write-Host 'Commands the doctor checks, before the install:'
    Reset-FreshInstallPath
    foreach ($name in Get-DotfilesDoctorCommands) {
        $path = Get-DotfilesCommandPath $name
        if ($path) { Write-Host "  $name`t$path" } else { Write-Host "  $name`t(absent)" }
    }

    # The newest version but one of each older package.
    $older = @(foreach ($package in $olderPackages) {
        $versions = Invoke-FreshInstallWinget @('show', '--id', $package, '--exact', '--versions', '--source', 'winget', '--accept-source-agreements')
        Assert-FreshInstall ($versions.ExitCode -eq 0) "winget show --versions failed for $package (exit code $($versions.ExitCode)): $($versions.Output -join ' | ')"
        $available = @($versions.Output | Where-Object { $_ -match '^\d+(\.\d+)+$' })
        Assert-FreshInstall ($available.Count -ge 2) "winget lists fewer than two versions of ${package}: $($versions.Output -join ' | ')"
        Write-Host "Installing $package $($available[1]), older than the latest $($available[0])..."
        $install = Invoke-FreshInstallWinget @('install', '--id', $package, '--exact', '--version', $available[1], '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements')
        $install.Output | Out-Host
        Assert-FreshInstall ($install.ExitCode -eq 0) "Installing $package $($available[1]) failed (exit code $($install.ExitCode))."
        $listed = Get-FreshInstallListedVersion $package
        Assert-FreshInstall ($listed.Installed -eq [version]$available[1] -and $listed.Outdated) "winget lists $package as $($listed.Installed), not as an outdated $($available[1])."
        [pscustomobject]@{ Id = $package; Version = $available[1] }
    })

    # A profile the user had before, in each edition, which the install must keep as a backup.
    $profiles = @(foreach ($shell in @('powershell.exe', 'pwsh.exe')) {
        $result = Invoke-FreshInstallCapture $shell @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', '$PROFILE.CurrentUserAllHosts')
        Assert-FreshInstall ($result.ExitCode -eq 0 -and $result.Output.Count -eq 1) "$shell did not name its profile: $($result.Output + $result.Errors)"
        $result.Output[0]
    })
    foreach ($profilePath in $profiles) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $profilePath) -Force | Out-Null
        [IO.File]::WriteAllText($profilePath, $seedProfileContent)
        Write-Host "Wrote a placeholder profile: $profilePath"
    }
    [pscustomobject]@{ Older = $older; Profiles = $profiles } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $stateFile
}

# From Windows PowerShell, after allowing local scripts, as the README says.
function Invoke-FreshInstallInstall {
    $state = Get-FreshInstallState
    $install = Join-Path $repository 'install.ps1'
    Invoke-FreshInstallShell 'powershell.exe' 'install' "Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force`n    & '$($install.Replace("'", "''"))'"
    $transcript = Get-FreshInstallTranscript 'install'
    foreach ($older in $state.Older) {
        Assert-FreshInstall ($transcript -contains "  already installed: $($older.Id)") "The install did not keep the $($older.Id) that was already installed."
    }
    foreach ($profilePath in $state.Profiles) {
        $backups = @(Get-ChildItem -Path "$profilePath.bak.*" -File -ErrorAction SilentlyContinue)
        Assert-FreshInstall ($backups.Count -eq 1) "Expected one backup of $profilePath, found $($backups.Count)."
        Assert-FreshInstall ([IO.File]::ReadAllText($backups[0].FullName) -eq $seedProfileContent) "The backup $($backups[0].FullName) does not hold the previous profile."
        Assert-FreshInstall (@($transcript | Where-Object { $_ -like "  backed up: $profilePath -> *" }).Count -eq 1) "The install did not report the backup of $profilePath."
        Assert-FreshInstall (Test-DotfilesManagedFile (Join-Path $repository 'config/powershell/profile.ps1') $profilePath) "$profilePath is not the managed profile."
    }
}

# The rerun starts from a Windows PowerShell that loads the new profile, as a
# reopened terminal would, and must change nothing.
function Invoke-FreshInstallRerun {
    $install = Join-Path $repository 'install.ps1'
    Invoke-FreshInstallShell 'powershell.exe' 'rerun' "& '$($install.Replace("'", "''"))'" -LoadProfile
    $changes = @(Get-FreshInstallTranscript 'rerun' | Where-Object { $_ -match '^  (installing|upgraded|linked|copied|backed up|created)\b|^Installing CaskaydiaCove' })
    Assert-FreshInstall ($changes.Count -eq 0) "The rerun changed the machine:`n$($changes -join "`n")"
}

# The update runs from PowerShell 7 without its profile: it must upgrade the
# older packages, leave the pinned package and the running PowerShell 7
# alone, and end with the doctor.
function Invoke-FreshInstallUpdate {
    $state = Get-FreshInstallState
    $pin = Invoke-FreshInstallWinget @('pin', 'add', '--id', $pinnedPackage, '--exact', '--source', 'winget', '--accept-source-agreements')
    $pin.Output | Out-Host
    Assert-FreshInstall ($pin.ExitCode -eq 0) "winget pin add failed (exit code $($pin.ExitCode))."
    $update = Join-Path $repository 'scripts/update.ps1'
    Invoke-FreshInstallShell 'pwsh.exe' 'update' "& '$($update.Replace("'", "''"))'"
    $transcript = Get-FreshInstallTranscript 'update'
    Assert-FreshInstall (@($transcript | Where-Object { $_ -like "  pinned, left alone: $pinnedPackage *" }).Count -eq 1) "The update did not leave the pinned $pinnedPackage alone."
    Assert-FreshInstall (@($transcript | Where-Object { $_ -like '  left alone: Microsoft.PowerShell runs this update*' }).Count -eq 1) 'The update did not leave the PowerShell 7 running it alone.'
    foreach ($older in $state.Older) {
        Assert-FreshInstall (@($transcript | Where-Object { $_ -like "  upgraded: $($older.Id)*" }).Count -eq 1) "The update did not report upgrading $($older.Id)."
        $listed = Get-FreshInstallListedVersion $older.Id
        Assert-FreshInstall ($listed.Installed -gt [version]$older.Version -and -not $listed.Outdated) "winget lists $($older.Id) as $($listed.Installed) after the update (was $($older.Version)), outdated: $($listed.Outdated)."
        Write-Host "$($older.Id) went from $($older.Version) to $($listed.Installed)."
    }
}

# The doctor on its own, in each edition, as after reopening the terminal.
function Invoke-FreshInstallDoctor {
    $doctor = Join-Path $repository 'scripts/doctor.ps1'
    foreach ($shell in @('powershell.exe', 'pwsh.exe')) {
        $name = 'doctor-' + [IO.Path]::GetFileNameWithoutExtension($shell)
        Invoke-FreshInstallShell $shell $name "& '$($doctor.Replace("'", "''"))'"
        Assert-FreshInstall ((Get-FreshInstallTranscript $name) -contains 'All checks passed.') "The doctor in $shell did not pass."
    }
}

# What the profile sets up when every tool is there. It runs after the profile,
# in a shell started with it or one that imports PSReadLine and then loads it.
$freshInstallProfileProbe = @'
$problems = @()
foreach ($pair in @(@('ls', 'eza'), @('cat', 'bat'), @('vim', 'nvim'))) {
    $alias = Get-Alias $pair[0] -ErrorAction SilentlyContinue
    if (-not $alias -or $alias.Definition -ne $pair[1]) { $problems += "$($pair[0]) is not $($pair[1])" }
}
foreach ($name in @('la', 'll', 'tree', 'y', '__zoxide_z')) {
    if (-not (Get-Command $name -CommandType Function -ErrorAction SilentlyContinue)) { $problems += "function $name is missing" }
}
if (-not (Get-Module oh-my-posh-core)) { $problems += 'oh-my-posh is not initialised' }
if ($env:MISE_SHELL -ne 'pwsh') { $problems += "mise is not activated (MISE_SHELL is '$env:MISE_SHELL')" }
if ($env:DOTFILES_PROBE_READLINE) {
    if ((Get-PSReadLineOption).BellStyle -ne 'None') { $problems += 'PSReadLine options were not applied' }
    if (-not (Get-PSReadLineKeyHandler | Where-Object { $_.Key -eq 'Tab' -and $_.Function -eq 'MenuComplete' })) { $problems += 'Tab is not bound to MenuComplete' }
}
if ($problems) { $problems | ForEach-Object { Write-Output "problem: $_" }; exit 3 }
Write-Output 'profile loaded'
'@

function Assert-FreshInstallQuietStart {
    param([string]$Label, [string]$Command, [string[]]$Arguments)
    Write-Host "==> Starting $Label"
    $result = Invoke-FreshInstallCapture $Command $Arguments
    $result.Output | Out-Host
    Assert-FreshInstall ($result.ExitCode -eq 0) "$Label failed (exit code $($result.ExitCode)):`n$(($result.Output + $result.Errors) -join "`n")"
    Assert-FreshInstall ($result.Errors.Count -eq 0) "$Label printed errors:`n$($result.Errors -join "`n")"
}

# Both editions load the managed profile without an error and with nothing on
# stderr, plainly and with PSReadLine imported first, as the console host does
# for a terminal. Neovim loads every parser tools.lua lists, and Windows
# Terminal's fragment is JSON.
function Invoke-FreshInstallShells {
    $probe = Join-Path $LogDirectory 'profile-probe.ps1'
    [IO.File]::WriteAllText($probe, $freshInstallProfileProbe)
    $readLineProbe = Join-Path $LogDirectory 'profile-probe-readline.ps1'
    [IO.File]::WriteAllText($readLineProbe, "Import-Module PSReadLine`n`$env:DOTFILES_PROBE_READLINE = '1'`n. `$PROFILE.CurrentUserAllHosts`n$freshInstallProfileProbe")
    foreach ($shell in @('pwsh.exe', 'powershell.exe')) {
        Assert-FreshInstallQuietStart "$shell with the profile" $shell @('-NoLogo', '-NonInteractive', '-File', $probe)
        Assert-FreshInstallQuietStart "$shell with PSReadLine and the profile" $shell @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $readLineProbe)
    }
    $lua = "lua local failed = 0; for _, lang in ipairs(require('dotfiles.tools').parsers) do " +
        "local ok, loaded, err = pcall(vim.treesitter.language.add, lang); " +
        "if ok and loaded then io.stdout:write('ok parser ', lang, '\n') else failed = failed + 1; io.stdout:write('failed parser ', lang, ': ', tostring(err or loaded), '\n') end end; " +
        "os.exit(failed > 0 and 1 or 0)"
    Assert-FreshInstallQuietStart 'Neovim, loading every parser' 'nvim' @('--headless', '-c', $lua, '-c', 'cquit 1')
    $fragment = Join-Path $env:LOCALAPPDATA 'Microsoft/Windows Terminal/Fragments/dotfiles/fragment.json'
    $parsed = Get-Content -Raw -LiteralPath $fragment | ConvertFrom-Json
    Assert-FreshInstall (@($parsed.schemes).Count -ge 1 -and @($parsed.profiles).Count -ge 1) "The Windows Terminal fragment at $fragment has no schemes or profiles."
    Write-Host "The Windows Terminal fragment parses: $(@($parsed.schemes).Count) scheme(s), $(@($parsed.profiles).Count) profile update(s)."
}

# winget's own logs and Neovim's, for a failed run.
function Invoke-FreshInstallCollect {
    $winget = Get-DotfilesCommandPath 'winget'
    if ($winget) { (Invoke-FreshInstallWinget @('--info')).Output | Set-Content -LiteralPath (Join-Path $LogDirectory 'winget-info.txt') }
    $sources = @(
        @((Join-Path $env:LOCALAPPDATA 'Packages/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe/LocalState/DiagOutputDir'), 'winget'),
        @((Join-Path $env:LOCALAPPDATA 'nvim-data/log'), 'nvim-log'),
        @((Join-Path $env:LOCALAPPDATA 'nvim-data/mason.log'), 'mason.log'))
    foreach ($source in $sources) {
        if (Test-Path -LiteralPath $source[0]) {
            Copy-Item -LiteralPath $source[0] -Destination (Join-Path $LogDirectory $source[1]) -Recurse -Force
            Write-Host "Collected $($source[0])"
        }
    }
}

function Invoke-FreshInstallStage {
    param([string]$Name)
    Write-Host "==> $Name"
    $clock = [Diagnostics.Stopwatch]::StartNew()
    & "Invoke-FreshInstall$Name"
    $elapsed = $clock.Elapsed
    $line = '{0} passed in {1}m {2:00}s' -f $Name, [int][math]::Floor($elapsed.TotalMinutes), $elapsed.Seconds
    Add-Content -LiteralPath (Join-Path $LogDirectory 'timings.txt') -Value $line
    Write-Host $line
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($Stage -ne 'All') { Invoke-FreshInstallStage $Stage }
    else {
        try {
            foreach ($name in @('Prepare', 'Install', 'Rerun', 'Update', 'Doctor', 'Shells')) { Invoke-FreshInstallStage $name }
            Write-Host 'Fresh install passed.'
        } finally { Invoke-FreshInstallCollect }
    }
}
