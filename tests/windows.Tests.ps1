# Dependency-free tests. All filesystem changes stay under a unique temporary directory.
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
. (Join-Path $repository 'scripts/lib/windows.ps1')

$parseFailures = @()
Get-ChildItem -LiteralPath $repository -Recurse -Filter '*.ps1' | ForEach-Object {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    $parseFailures += $errors
}
if ($parseFailures.Count) { throw ($parseFailures | Out-String) }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('dotfiles-windows-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$testCount = 0

function Assert-True {
    param($Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}
function Assert-Throws {
    param([scriptblock]$Body, [string]$MessagePattern)
    $failure = $null
    try { & $Body } catch { $failure = $_ }
    Assert-True ($null -ne $failure) 'Expected a terminating error'
    Assert-True ($failure.Exception.Message -match $MessagePattern) "Unexpected failure: $failure"
}
function New-Fixture {
    $directory = Join-Path $testRoot ([guid]::NewGuid().ToString('N') + ' fixture with spaces')
    Microsoft.PowerShell.Management\New-Item -ItemType Directory -Path $directory | Out-Null
    $source = Join-Path $directory 'source.ps1'
    [IO.File]::WriteAllText($source, 'managed content')
    [pscustomobject]@{ Directory = $directory; Source = $source; Destination = Join-Path $directory 'profile.ps1' }
}
function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    & $Body
    $script:testCount++
    Write-Host "PASS: $Name"
}

try {
    $probe = New-Fixture
    $canCreateSymlinks = $true
    try { New-Item -ItemType SymbolicLink -Path $probe.Destination -Target $probe.Source | Out-Null }
    catch {
        if (-not (Test-DotfilesSymlinkUnavailable $_)) { throw }
        $canCreateSymlinks = $false
        Write-Host 'SKIP: actual symbolic-link cases require Developer Mode or symlink permission; fallback and rollback cases still run.'
    }

    Invoke-Test 'Existing identical copies are accepted without creating backups' {
        $fixture = New-Fixture
        Copy-Item -LiteralPath $fixture.Source -Destination $fixture.Destination
        Set-DotfilesManagedFile $fixture.Source $fixture.Destination
        Assert-True (Test-DotfilesManagedFile $fixture.Source $fixture.Destination) 'Copy should be valid'
        Assert-True (@(Get-ChildItem -LiteralPath $fixture.Directory -Filter '*.bak.*').Count -eq 0) 'Rerun should not create backups'
    }

    Invoke-Test 'Regular files and directories are preserved and reruns are idempotent' {
        foreach ($kind in @('file', 'directory')) {
            $fixture = New-Fixture
            if ($kind -eq 'file') { [IO.File]::WriteAllText($fixture.Destination, 'original content') }
            else {
                New-Item -ItemType Directory -Path $fixture.Destination | Out-Null
                [IO.File]::WriteAllText((Join-Path $fixture.Destination 'keep.txt'), 'original content')
            }
            Set-DotfilesManagedFile $fixture.Source $fixture.Destination
            Set-DotfilesManagedFile $fixture.Source $fixture.Destination
            $backups = @(Get-ChildItem -LiteralPath $fixture.Directory -Filter '*.bak.*')
            Assert-True ($backups.Count -eq 1) 'One preserved original should exist'
            $savedFile = $backups[0].FullName
            if ($kind -eq 'directory') { $savedFile = Join-Path $savedFile 'keep.txt' }
            Assert-True ([IO.File]::ReadAllText($savedFile) -eq 'original content') 'Original must remain intact'
        }
    }

    if ($canCreateSymlinks) {
        Invoke-Test 'Broken and wrong links are repaired even when content matches' {
            foreach ($targetKind in @('missing', 'same-content')) {
                $fixture = New-Fixture
                $target = Join-Path $fixture.Directory 'old-repository.ps1'
                Copy-Item -LiteralPath $fixture.Source -Destination $target
                New-Item -ItemType SymbolicLink -Path $fixture.Destination -Target $target | Out-Null
                if ($targetKind -eq 'missing') { Remove-Item -LiteralPath $target }
                Assert-True (-not (Test-DotfilesManagedFile $fixture.Source $fixture.Destination)) 'Wrong target must be rejected'
                Set-DotfilesManagedFile $fixture.Source $fixture.Destination
                Assert-True (Test-DotfilesManagedFile $fixture.Source $fixture.Destination) 'Link should be repaired'
                Assert-True (@(Get-ChildItem -LiteralPath $fixture.Directory -Filter '*.bak.*').Count -eq 1) 'Original link should be saved'
            }
        }

        Invoke-Test 'Backups do not collide with regular files or dangling links' {
            function Get-Date { param($Format) '20000101000000' }
            $fixture = New-Fixture
            [IO.File]::WriteAllText($fixture.Destination, 'original')
            $base = $fixture.Destination + '.bak.20000101000000'
            [IO.File]::WriteAllText($base, 'older backup')
            $missingTarget = Join-Path $fixture.Directory 'missing'
            [IO.File]::WriteAllText($missingTarget, 'temporary target')
            New-Item -ItemType SymbolicLink -Path ($base + '.1') -Target $missingTarget | Out-Null
            Remove-Item -LiteralPath $missingTarget
            Set-DotfilesManagedFile $fixture.Source $fixture.Destination
            Assert-True ([IO.File]::ReadAllText($base) -eq 'older backup') 'Existing backup must remain intact'
            Assert-True ((Get-DotfilesPathItem ($base + '.1')).LinkType -eq 'SymbolicLink') 'Dangling backup must remain intact'
            Assert-True ([IO.File]::ReadAllText($base + '.2') -eq 'original') 'New backup should use a free suffix'
        }
    }

    Invoke-Test 'Missing sources are rejected before changing an existing destination' {
        $fixture = New-Fixture
        [IO.File]::WriteAllText($fixture.Destination, 'keep')
        Assert-Throws { Set-DotfilesManagedFile ($fixture.Source + '.missing') $fixture.Destination } 'source is missing'
        Assert-True ([IO.File]::ReadAllText($fixture.Destination) -eq 'keep') 'Destination must not be touched'
    }

    Invoke-Test 'Literal brackets in source and destination paths remain supported' {
        $fixture = New-Fixture
        $literalDirectory = Join-Path $fixture.Directory 'redirected [documents]'
        New-Item -ItemType Directory -Path $literalDirectory | Out-Null
        $literalSource = Join-Path $literalDirectory 'source [managed].ps1'
        $literalDestination = Join-Path $literalDirectory 'profile [user].ps1'
        [IO.File]::WriteAllText($literalSource, 'managed literal content')
        [IO.File]::WriteAllText($literalDestination, 'original literal content')
        Set-DotfilesManagedFile $literalSource $literalDestination
        Set-DotfilesManagedFile $literalSource $literalDestination
        Assert-True (Test-DotfilesManagedFile $literalSource $literalDestination) 'Literal paths should create a valid link or verified fallback copy'
        $backups = @(Get-ChildItem -LiteralPath $literalDirectory -Filter '*.bak.*')
        Assert-True ($backups.Count -eq 1) 'Rerun must retain exactly one original backup'
        Assert-True ([IO.File]::ReadAllText($backups[0].FullName) -eq 'original literal content') 'Original literal file must be preserved'
    }

    Invoke-Test 'Symlink permission failures use a verified, rerunnable copy' {
        function New-Item {
            [CmdletBinding()] param($ItemType, $Path, $Target, [switch]$Force)
            if ($ItemType -eq 'SymbolicLink') { throw [System.ComponentModel.Win32Exception]::new(1314) }
            Microsoft.PowerShell.Management\New-Item @PSBoundParameters
        }
        $fixture = New-Fixture
        Set-DotfilesManagedFile $fixture.Source $fixture.Destination
        Set-DotfilesManagedFile $fixture.Source $fixture.Destination
        Assert-True ((Get-Item -LiteralPath $fixture.Destination).LinkType -ne 'SymbolicLink') 'Fallback should copy'
        Assert-True (Test-DotfilesManagedFile $fixture.Source $fixture.Destination) 'Fallback copy should match'
        Assert-True (@(Get-ChildItem -LiteralPath $fixture.Directory -Filter '*.bak.*').Count -eq 0) 'Copy reruns should not back up identical content'
    }

    Invoke-Test 'Literal paths use copy fallback for unsupported APIs and .NET privilege errors' {
        function New-DotfilesSymbolicLink { param($Source, $Destination) throw $linkFailure }
        foreach ($linkFailure in @([NotSupportedException]::new('simulated legacy API limitation'),
                [IO.IOException]::new('simulated .NET symlink privilege error', [int]0x80070522))) {
            $fixture = New-Fixture
            $literalSource = Join-Path $fixture.Directory 'source [managed].ps1'
            $literalDestination = Join-Path $fixture.Directory 'profile [user].ps1'
            [IO.File]::WriteAllText($literalSource, 'literal content')
            Set-DotfilesManagedFile $literalSource $literalDestination
            Set-DotfilesManagedFile $literalSource $literalDestination
            Assert-True (Test-DotfilesManagedFile $literalSource $literalDestination) 'Fallback must preserve literal contents'
            Assert-True ((Get-Item -LiteralPath $literalDestination).LinkType -ne 'SymbolicLink') 'Permission/API fallback must copy'
        }
    }

    Invoke-Test 'Unrelated link failures restore the original without attempting a copy' {
        function New-Item {
            [CmdletBinding()] param($ItemType, $Path, $Target, [switch]$Force)
            if ($ItemType -eq 'SymbolicLink') { throw [IO.IOException]::new('simulated disk failure') }
            Microsoft.PowerShell.Management\New-Item @PSBoundParameters
        }
        function Copy-Item { throw 'Unexpected copy fallback' }
        $fixture = New-Fixture
        [IO.File]::WriteAllText($fixture.Destination, 'original')
        Assert-Throws { Set-DotfilesManagedFile $fixture.Source $fixture.Destination } 'simulated disk failure'
        Assert-True ([IO.File]::ReadAllText($fixture.Destination) -eq 'original') 'Original must be restored'
    }

    Invoke-Test 'Partial failed copies are removed and previous files are restored' {
        function New-Item {
            [CmdletBinding()] param($ItemType, $Path, $Target, [switch]$Force)
            if ($ItemType -eq 'SymbolicLink') { throw [PlatformNotSupportedException]::new('simulated unsupported links') }
            Microsoft.PowerShell.Management\New-Item @PSBoundParameters
        }
        function Copy-Item {
            [CmdletBinding()] param($LiteralPath, $Destination)
            [IO.File]::WriteAllText($Destination, 'partial write')
            throw [IO.IOException]::new('simulated copy failure')
        }
        foreach ($hasOriginal in @($true, $false)) {
            $fixture = New-Fixture
            if ($hasOriginal) { [IO.File]::WriteAllText($fixture.Destination, 'original') }
            Assert-Throws { Set-DotfilesManagedFile $fixture.Source $fixture.Destination } 'simulated copy failure'
            if ($hasOriginal) { Assert-True ([IO.File]::ReadAllText($fixture.Destination) -eq 'original') 'Original must be restored' }
            else { Assert-True (-not (Get-DotfilesPathItem $fixture.Destination)) 'Partial new destination must be removed' }
        }
    }

    Invoke-Test 'Both profile paths come from shells started without profiles' {
        $fixture = New-Fixture
        function Get-DotfilesCommandPath { param($Name) if ($Name -eq 'pwsh.exe') { 'Test-Pwsh' } else { 'Test-WindowsPowerShell' } }
        function Test-Pwsh {
            param([switch]$NoLogo, [switch]$NoProfile, [switch]$NonInteractive, $Command)
            Assert-True ($NoProfile -and $NonInteractive -and $Command -eq '$PROFILE.CurrentUserAllHosts') 'Discovery must bypass profiles'
            $global:LASTEXITCODE = 0
            Join-Path $fixture.Directory 'OneDrive/PowerShell/profile.ps1'
        }
        function Test-WindowsPowerShell {
            param([switch]$NoLogo, [switch]$NoProfile, [switch]$NonInteractive, $Command)
            Assert-True ($NoProfile -and $NonInteractive) 'Legacy shell must bypass profiles'
            $global:LASTEXITCODE = 0
            Join-Path $fixture.Directory 'Redirected/WindowsPowerShell/profile.ps1'
        }
        $paths = Get-DotfilesProfilePaths
        Assert-True ($paths.Count -eq 2) 'Both editions must be discovered'
        Assert-True ($paths.PowerShell -match 'OneDrive') 'Redirected modern profile must be preserved'
        Assert-True ($paths.WindowsPowerShell -match 'Redirected') 'Redirected legacy profile must be preserved'
    }

    Invoke-Test 'Failed shell discovery is actionable' {
        function Get-DotfilesCommandPath { param($Name) $null }
        Assert-Throws { Get-DotfilesProfilePaths } 'Cannot discover.*Reopen PowerShell'
    }

    Invoke-Test 'Package installation uses corrected IDs and refreshes discovery before fonts' {
        $events = [Collections.Generic.List[string]]::new()
        function Get-DotfilesCommandPath { param($Name) $Name }
        function Invoke-DotfilesNativeCommand {
            param($Command, $Arguments, [switch]$Quiet)
            $events.Add(($Arguments -join ' '))
            if ($Arguments[0] -eq 'list') { return -1978335212 }
            return 0
        }
        function Update-DotfilesProcessPath { $events.Add('refresh') }
        function Invoke-DotfilesFontInstall { $events.Add('font') }
        Invoke-DotfilesPackageInstall $repository
        Assert-True (($events -join "`n") -match 'install --id aristocratos.btop4win --exact') 'Correct package ID must be installed'
        Assert-True ($events[$events.Count - 2] -eq 'refresh' -and $events[$events.Count - 1] -eq 'font') 'Refresh must precede font discovery'
    }

    Invoke-Test 'WinGet failures stop before font setup' {
        function Get-DotfilesCommandPath { param($Name) $Name }
        function Invoke-DotfilesFontInstall { throw 'Unexpected font installation' }
        function Invoke-DotfilesNativeCommand { param($Command, $Arguments, [switch]$Quiet) 5 }
        Assert-Throws { Invoke-DotfilesPackageInstall $repository } 'could not check.*exit code 5'
        function Invoke-DotfilesNativeCommand {
            param($Command, $Arguments, [switch]$Quiet)
            if ($Arguments[0] -eq 'list') { return -1978335212 }; return 7
        }
        Assert-Throws { Invoke-DotfilesPackageInstall $repository } 'failed to install.*exit code 7'
    }

    Invoke-Test 'Registered package paths become discoverable in the current process' {
        $fixture = New-Fixture
        $commandName = 'dotfiles-discovery-' + [guid]::NewGuid().ToString('N')
        $commandFile = Join-Path $fixture.Directory $commandName
        if ($env:OS -eq 'Windows_NT') { $commandFile += '.cmd' }
        [IO.File]::WriteAllText($commandFile, 'exit 0')
        if ($env:OS -ne 'Windows_NT') { & chmod +x $commandFile }
        Assert-True (-not (Get-DotfilesCommandPath $commandName)) 'Fixture command should start outside PATH'
        $savedPath = $env:PATH
        try {
            Update-DotfilesProcessPath -RegisteredPaths @($fixture.Directory, $fixture.Directory)
            Assert-True ((Get-DotfilesCommandPath $commandName) -eq $commandFile) 'Newly registered executable must be discoverable'
            $matches = @($env:PATH -split [regex]::Escape([string][IO.Path]::PathSeparator) | Where-Object { $_ -eq $fixture.Directory })
            Assert-True ($matches.Count -eq 1) 'Registered directories must not be duplicated'
        } finally { $env:PATH = $savedPath }
    }

    Invoke-Test 'Font failures and missing executable discovery cannot report success' {
        function Test-DotfilesNerdFont { $false }
        function Get-DotfilesCommandPath { param($Name) 'mock-oh-my-posh' }
        function Invoke-DotfilesNativeCommand { param($Command, $Arguments) 1 }
        Assert-Throws { Invoke-DotfilesFontInstall } 'Font installation failed.*exit code 1'
        function Invoke-DotfilesNativeCommand { param($Command, $Arguments) 0 }
        Assert-Throws { Invoke-DotfilesFontInstall } 'was not found after installation'
        function Get-DotfilesCommandPath { param($Name) $null }
        Assert-Throws { Invoke-DotfilesFontInstall } 'unavailable after package installation'
    }

    Invoke-Test 'Already installed fonts are not reinstalled' {
        function Test-DotfilesNerdFont { $true }
        function Invoke-DotfilesNativeCommand { throw 'Unexpected font installation' }
        Invoke-DotfilesFontInstall
    }

    Invoke-Test 'A failed font attempt can be retried successfully' {
        $fontState = @{ Installed = $false; ExitCode = 1; Attempts = 0 }
        function Test-DotfilesNerdFont { $fontState.Installed }
        function Get-DotfilesCommandPath { param($Name) 'mock-oh-my-posh' }
        function Invoke-DotfilesNativeCommand {
            param($Command, $Arguments)
            $fontState.Attempts++
            if ($fontState.ExitCode -eq 0) { $fontState.Installed = $true }
            $fontState.ExitCode
        }
        Assert-Throws { Invoke-DotfilesFontInstall } 'Font installation failed'
        $fontState.ExitCode = 0
        Invoke-DotfilesFontInstall
        Invoke-DotfilesFontInstall
        Assert-True ($fontState.Installed -and $fontState.Attempts -eq 2) 'Retry should finish and subsequent runs should skip the installed font'
    }

    Invoke-Test 'PowerShell modules are checked and installed through PowerShell 7 without profiles' {
        $moduleState = @{ Installed = @{}; InstallExitCode = 0; InstallRegisters = $true; CheckExitCode = $null; Commands = [Collections.Generic.List[string]]::new() }
        function Get-DotfilesCommandPath { param($Name) if ($Name -eq 'pwsh.exe') { 'mock-pwsh' } }
        function Invoke-DotfilesNativeCommand {
            param($Command, $Arguments, [switch]$Quiet)
            Assert-True ($Command -eq 'mock-pwsh' -and ($Arguments -contains '-NoProfile') -and ($Arguments -contains '-NonInteractive')) 'Modules must be managed by pwsh without profiles'
            $script = [string]$Arguments[-1]
            $moduleState.Commands.Add($script)
            if ($script -match "^Install-Module -Name '([^']+)' -Scope CurrentUser") {
                if ($moduleState.InstallExitCode -eq 0 -and $moduleState.InstallRegisters) { $moduleState.Installed[$Matches[1]] = $true }
                return $moduleState.InstallExitCode
            }
            Assert-True ($script -match "Get-Module -ListAvailable -Name '([^']+)'") "Unexpected pwsh command: $script"
            if ($null -ne $moduleState.CheckExitCode) { return $moduleState.CheckExitCode }
            if ($moduleState.Installed.ContainsKey($Matches[1])) { return 0 }
            return 3
        }
        $expected = @(Get-DotfilesPowerShellModules)
        Assert-True (($expected -contains 'PSFzf') -and ($expected -contains 'CompletionPredictor') -and ($expected -contains 'Terminal-Icons') -and ($expected -contains 'posh-git')) 'Phase 2 modules must be declared'
        $moduleState.Installed['posh-git'] = $true
        Invoke-DotfilesModuleInstall
        $installs = @($moduleState.Commands | Where-Object { $_ -match '^Install-Module' })
        Assert-True ($installs.Count -eq ($expected.Count - 1)) 'Only missing modules are installed'
        Assert-True (@($installs | Where-Object { $_ -match 'posh-git' }).Count -eq 0) 'Installed modules are skipped'
        $moduleState.Commands.Clear()
        Invoke-DotfilesModuleInstall
        Assert-True (@($moduleState.Commands | Where-Object { $_ -match '^Install-Module' }).Count -eq 0) 'Reruns must not reinstall'
        $moduleState.Installed.Clear()
        $moduleState.InstallExitCode = 1
        Assert-Throws { Invoke-DotfilesModuleInstall } 'Install-Module failed for Terminal-Icons \(exit code 1\).*Rerun install.ps1'
        Assert-True ($moduleState.Installed.Count -eq 0) 'A failed installation registers nothing'
        $moduleState.InstallExitCode = 0
        $moduleState.InstallRegisters = $false
        Assert-Throws { Invoke-DotfilesModuleInstall } 'Terminal-Icons was not found after installation'
        $moduleState.InstallRegisters = $true
        Invoke-DotfilesModuleInstall
        Assert-True ($moduleState.Installed.Count -eq $expected.Count) 'The retry installs every module'
        $moduleState.CheckExitCode = 5
        Assert-Throws { Invoke-DotfilesModuleInstall } 'could not check the Terminal-Icons module \(exit code 5\)'
    }

    Invoke-Test 'Module installation requires a discoverable PowerShell 7' {
        function Get-DotfilesCommandPath { param($Name) $null }
        function Invoke-DotfilesNativeCommand { throw 'Unexpected native command' }
        Assert-Throws { Invoke-DotfilesModuleInstall } 'pwsh is unavailable.*Reopen PowerShell'
    }

    Invoke-Test 'A redirected LOCALAPPDATA is honoured only for the real profile directory' {
        $saved = @{ USERPROFILE = $env:USERPROFILE; LOCALAPPDATA = $env:LOCALAPPDATA }
        $realHome = Join-Path $testRoot 'real-home'
        $otherHome = Join-Path $testRoot 'other-home'
        try {
            [Environment]::SetEnvironmentVariable('USERPROFILE', $realHome)
            [Environment]::SetEnvironmentVariable('LOCALAPPDATA', (Join-Path $testRoot 'redirected-local'))
            Assert-True ((Get-DotfilesLocalAppData $realHome) -eq $env:LOCALAPPDATA) 'The real home must use the redirected LOCALAPPDATA'
            Assert-True ((Get-DotfilesLocalAppData ($realHome + [IO.Path]::DirectorySeparatorChar)) -eq $env:LOCALAPPDATA) 'A trailing separator must not matter'
            Assert-True ((Get-DotfilesLocalAppData $otherHome) -eq (Join-Path $otherHome 'AppData/Local')) 'Other home directories derive the default'
            [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $null)
            Assert-True ((Get-DotfilesLocalAppData $realHome) -eq (Join-Path $realHome 'AppData/Local')) 'Without LOCALAPPDATA the default applies'
        } finally {
            [Environment]::SetEnvironmentVariable('USERPROFILE', $saved.USERPROFILE)
            [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $saved.LOCALAPPDATA)
        }
    }

    Invoke-Test 'Managed files include the Windows Terminal fragment, the eza theme and the phase 3 tool configuration' {
        function Get-DotfilesProfilePaths {
            [ordered]@{ PowerShell = Join-Path $testRoot 'modern/profile.ps1'; WindowsPowerShell = Join-Path $testRoot 'legacy/profile.ps1' }
        }
        $files = @(Get-DotfilesManagedFiles $repository $testRoot)
        foreach ($file in $files) { Assert-True (Test-Path -LiteralPath $file.Source -PathType Leaf) "Managed source must exist: $($file.Source)" }
        $destinations = @($files | ForEach-Object { $_.Destination })
        Assert-True ($destinations -contains (Join-Path $testRoot 'AppData/Local/Microsoft/Windows Terminal/Fragments/dotfiles/fragment.json')) 'The fragment must land in the Fragments folder under the home directory'
        Assert-True ($destinations -contains (Join-Path $testRoot '.config/eza/theme.yml')) 'The eza theme must be managed'
        # Git for Windows, lazygit, yazi, atuin and mise all read these from ~/.config.
        foreach ($relative in @('git/config', 'git/ignore', 'git/catppuccin.gitconfig', 'lazygit/config.yml', 'yazi/yazi.toml', 'yazi/theme.toml',
                'atuin/config.toml', 'atuin/themes/catppuccin-macchiato-blue.toml', 'mise/config.toml')) {
            $expected = Join-Path $testRoot ".config/$relative"
            $match = @($files | Where-Object { $_.Destination -eq $expected })
            Assert-True ($match.Count -eq 1) "$relative must be managed under .config"
            Assert-True ($match[0].Source -eq (Join-Path $repository "config/$relative")) "$relative must come from config/$relative"
        }
        Assert-True (@($destinations | Select-Object -Unique).Count -eq $destinations.Count) 'Destinations must be unique'
    }

    Invoke-Test 'The winget list declares every phase 3 tool exactly once' {
        $packages = @(Get-Content -LiteralPath (Join-Path $repository 'packages/winget.txt') |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^#' })
        # winget --exact compares IDs case-sensitively, so the spelling must match the manifests.
        foreach ($id in @('rsteube.Carapace', 'Atuinsh.Atuin', 'jdx.mise', 'dandavison.delta', 'JesseDuffield.lazygit', 'JesseDuffield.Lazydocker',
                'sxyazi.yazi', 'BurntSushi.ripgrep.MSVC', 'sharkdp.fd', 'bootandy.dust', 'muesli.duf', 'dalance.procs', 'chmln.sd', 'ducaale.xh',
                'sharkdp.hyperfine', 'charmbracelet.glow', 'tldr-pages.tlrc', 'charmbracelet.gum', 'direnv.direnv')) {
            Assert-True ($packages -ccontains $id) "winget.txt must declare $id"
        }
        foreach ($package in $packages) { Assert-True ($package -match '^[A-Za-z0-9][A-Za-z0-9.+_-]*$') "Not a bare winget ID: $package" }
        $lowered = @($packages | ForEach-Object { $_.ToLowerInvariant() })
        Assert-True (@($lowered | Select-Object -Unique).Count -eq $lowered.Count) 'winget IDs must be unique'
    }

    Invoke-Test 'The Windows Terminal fragment carries the Macchiato scheme to the stock profiles' {
        $fragment = Get-Content -Raw -LiteralPath (Join-Path $repository 'config/windows-terminal/fragment.json') | ConvertFrom-Json
        $schemes = @($fragment.schemes | Where-Object { $_.name -eq 'Catppuccin Macchiato' })
        Assert-True ($schemes.Count -eq 1) 'Exactly one Catppuccin Macchiato scheme'
        foreach ($key in @('background', 'foreground', 'cursorColor', 'selectionBackground', 'black', 'red', 'green', 'yellow', 'blue', 'purple', 'cyan', 'white',
                'brightBlack', 'brightRed', 'brightGreen', 'brightYellow', 'brightBlue', 'brightPurple', 'brightCyan', 'brightWhite')) {
            Assert-True ([string]$schemes[0].$key -match '^#[0-9A-F]{6}$') "$key must be an uppercase hex color"
        }
        Assert-True ($schemes[0].background -eq '#24273A' -and $schemes[0].foreground -eq '#CAD3F5') 'Scheme must be Macchiato base and text'
        $profiles = @($fragment.profiles)
        $updates = @($profiles | ForEach-Object { $_.updates })
        # PowerShell 7, Windows PowerShell and Command Prompt: the stock profiles a fragment may modify.
        foreach ($guid in @('{574e775e-4f2a-5b96-ac1e-a2962a402336}', '{61c54bbd-c2c6-5271-96e7-009a87ff44bf}', '{0caa0dad-35be-5f56-a8ff-afceeeaa6101}')) {
            Assert-True ($updates -contains $guid) "Fragment must update profile $guid"
        }
        foreach ($profile in $profiles) {
            Assert-True ($profile.colorScheme -eq 'Catppuccin Macchiato') 'Every profile update must select the scheme'
            Assert-True ([string]$profile.font.face -match 'CaskaydiaCove Nerd Font Mono') 'Every profile update must select the Nerd Font'
        }
    }

    Invoke-Test 'The shared profile is ASCII, portable, and loads with no tools and with PSReadLine' {
        $profilePath = Join-Path $repository 'config/powershell/profile.ps1'
        $source = [IO.File]::ReadAllText($profilePath)
        Assert-True (-not ($source -match '[^\x00-\x7F]')) 'The profile must stay ASCII for Windows PowerShell'
        Assert-True (-not ($source -match '\$env:USERPROFILE|\$env:HOME\b')) 'The profile must locate files through $HOME only'
        $fixture = New-Fixture
        $portable = Join-Path $fixture.Directory 'portable-profile.ps1'
        [IO.File]::WriteAllText($portable, ($source -replace '\$HOME\b', '$$env:DOTFILES_TEST_HOME'))
        # Stub tools make the alias branches run: on Windows, ls and cat are built-in read-only aliases.
        # The shell-integration stubs print a PowerShell statement recording their arguments, so the
        # probe can tell that the profile evaluated each integration with the expected command line.
        $stubBin = Join-Path $fixture.Directory 'bin'
        New-Item -ItemType Directory -Path $stubBin | Out-Null
        $integrations = @('mise', 'carapace', 'atuin', 'direnv', 'yazi')
        foreach ($tool in @('eza', 'bat', 'fzf') + $integrations) {
            if ($env:OS -eq 'Windows_NT') {
                $body = "@echo off`r`n"
                if ($tool -in $integrations) { $body += "echo `$env:DOTFILES_TEST_CALLS += '$tool %*;'`r`n" }
                [IO.File]::WriteAllText((Join-Path $stubBin "$tool.cmd"), $body + "exit 0`r`n")
            } else {
                $body = "#!/bin/sh`n"
                if ($tool -in $integrations) { $body += "echo `"\`$env:DOTFILES_TEST_CALLS += '$tool `$*;'`"`n" }
                $stub = Join-Path $stubBin $tool
                [IO.File]::WriteAllText($stub, $body + "exit 0`n")
                & chmod +x $stub
            }
        }
        $probe = @'
$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
$env:PATH = $env:DOTFILES_TEST_BIN
if ($env:DOTFILES_TEST_READLINE -eq 'yes') {
    try { Import-Module PSReadLine } catch { Write-Output 'SKIP-READLINE'; exit 0 }
}
. $env:DOTFILES_TEST_PROFILE
if ((Get-Alias ls).Definition -ne 'eza') { throw "ls resolves to $((Get-Alias ls).Definition), not eza" }
if ((Get-Alias cat).Definition -ne 'bat') { throw "cat resolves to $((Get-Alias cat).Definition), not bat" }
foreach ($name in @('la', 'll', 'tree')) {
    if (-not (Get-Command $name -CommandType Function -ErrorAction SilentlyContinue)) { throw "$name function is missing" }
}
if ($env:EZA_CONFIG_DIR -ne (Join-Path $env:DOTFILES_TEST_HOME '.config\eza')) { throw "EZA_CONFIG_DIR is $env:EZA_CONFIG_DIR" }
foreach ($pair in @(@('ATUIN_CONFIG_DIR', '.config\atuin'), @('LG_CONFIG_FILE', '.config\lazygit\config.yml'), @('YAZI_CONFIG_HOME', '.config\yazi'))) {
    $expected = Join-Path $env:DOTFILES_TEST_HOME $pair[1]
    $actual = [Environment]::GetEnvironmentVariable($pair[0])
    if ($actual -ne $expected) { throw "$($pair[0]) is '$actual', expected '$expected'" }
}
if ($env:ProgramFiles) {
    $fileCommand = Join-Path $env:ProgramFiles 'Git\usr\bin\file.exe'
    if ((Test-Path -LiteralPath $fileCommand) -and $env:YAZI_FILE_ONE -ne $fileCommand) { throw "YAZI_FILE_ONE is '$env:YAZI_FILE_ONE', expected '$fileCommand'" }
}
if (-not (Get-Command y -CommandType Function -ErrorAction SilentlyContinue)) { throw 'y function is missing' }
$calls = [string]$env:DOTFILES_TEST_CALLS
$expectedCalls = @('mise activate pwsh;', 'direnv hook pwsh;')
if (Get-Module PSReadLine) { $expectedCalls += @('carapace _carapace;', 'atuin init powershell --disable-up-arrow;') }
foreach ($call in $expectedCalls) {
    if (-not $calls.Contains($call)) { throw "The profile did not evaluate '$call'. Recorded: $calls" }
}
if ($calls -match 'yazi') { throw "yazi must not run while the profile loads. Recorded: $calls" }
if ($env:DOTFILES_TEST_EXPECTED_FZF) {
    if ($env:FZF_DEFAULT_OPTS -ne $env:DOTFILES_TEST_EXPECTED_FZF) { throw "The local profile did not override FZF_DEFAULT_OPTS: $env:FZF_DEFAULT_OPTS" }
} elseif ($env:FZF_DEFAULT_OPTS -notmatch 'bg\+:#363a4f') {
    throw "FZF_DEFAULT_OPTS lacks the Macchiato palette: $env:FZF_DEFAULT_OPTS"
}
if ($env:DOTFILES_TEST_READLINE -eq 'yes') {
    if ((Get-PSReadLineOption).BellStyle -ne 'None') { throw 'PSReadLine options were not applied' }
    # PSReadLine 2.0 (Windows PowerShell) has no -Key parameter; filter the full list instead.
    if (-not (Get-PSReadLineKeyHandler | Where-Object { $_.Key -eq 'Tab' -and $_.Function -eq 'MenuComplete' })) { throw 'Tab is not bound to MenuComplete' }
}
exit 0
'@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
        $shell = (Get-Process -Id $PID).Path
        # Windows PowerShell turns redirected native stderr into terminating errors under
        # Stop, which would hide the child's diagnostics; relax it around the call only.
        function Invoke-ProfileProbe {
            $savedPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $lines = @(& $shell -NoLogo -NoProfile -NonInteractive -EncodedCommand $encoded 2>&1 | ForEach-Object { [string]$_ })
                $code = $LASTEXITCODE
            } finally { $ErrorActionPreference = $savedPreference }
            return [pscustomobject]@{ Lines = $lines; ExitCode = $code }
        }
        $env:DOTFILES_TEST_HOME = $fixture.Directory
        $env:DOTFILES_TEST_PROFILE = $portable
        $env:DOTFILES_TEST_BIN = $stubBin
        $env:DOTFILES_TEST_EXPECTED_FZF = ''
        try {
            foreach ($readLine in @('no', 'yes')) {
                $env:DOTFILES_TEST_READLINE = $readLine
                $probeResult = Invoke-ProfileProbe
                $output = $probeResult.Lines
                Assert-True ($probeResult.ExitCode -eq 0) "Profile failed (PSReadLine: $readLine): $($output -join "`n")"
                if ($output -contains 'SKIP-READLINE') { Write-Host 'SKIP: PSReadLine cannot be imported in this non-interactive host; the bare profile load passed.' }
                elseif ($readLine -eq 'no') { Assert-True (-not ($output -join "`n" -match '\S')) "Profile wrote unexpected output: $($output -join "`n")" }
            }
            # The local profile runs last so it can override anything above it.
            [IO.File]::WriteAllText((Join-Path $fixture.Directory '.powershell.local.ps1'), '$env:FZF_DEFAULT_OPTS = "local override"')
            $env:DOTFILES_TEST_READLINE = 'no'
            $env:DOTFILES_TEST_EXPECTED_FZF = 'local override'
            $probeResult = Invoke-ProfileProbe
            Assert-True ($probeResult.ExitCode -eq 0) "Local override failed: $($probeResult.Lines -join "`n")"
        } finally {
            foreach ($name in @('DOTFILES_TEST_HOME', 'DOTFILES_TEST_PROFILE', 'DOTFILES_TEST_BIN', 'DOTFILES_TEST_READLINE', 'DOTFILES_TEST_EXPECTED_FZF')) {
                [Environment]::SetEnvironmentVariable($name, $null)
            }
        }
    }

    Invoke-Test 'Doctor validates both editions, copied contents, fonts and runtimes' {
        $fixture = New-Fixture
        function Get-DotfilesProfilePaths {
            [ordered]@{ PowerShell = Join-Path $fixture.Directory 'modern/profile.ps1'; WindowsPowerShell = Join-Path $fixture.Directory 'legacy/profile.ps1' }
        }
        function Get-DotfilesCommandPath { param($Name) 'mock-command' }
        function Test-DotfilesNerdFont { $fontPresent }
        function Test-DotfilesPowerShellModule { param($Name) $modulePresent }
        $report = [Collections.Generic.List[string]]::new()
        function Write-Host { param($Object) $report.Add([string]$Object) }
        function Invoke-DotfilesNativeCommand {
            param($Command, $Arguments, [switch]$Quiet)
            Assert-True ($Command -eq 'mock-command' -and ($Arguments -join ' ') -eq 'which node' -and $Quiet) 'The doctor asks mise for node quietly'
            $runtimeExitCode
        }
        $fontPresent = $true
        $modulePresent = $true
        $runtimeExitCode = 0
        $files = @(Get-DotfilesManagedFiles $repository $fixture.Directory)
        foreach ($file in $files) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $file.Destination) -Force | Out-Null
            Copy-Item -LiteralPath $file.Source -Destination $file.Destination
        }
        $latteFlavor = Join-Path $fixture.Directory '.config/yazi/flavors/catppuccin-latte.yazi/flavor.toml'
        foreach ($flavorFile in @((Join-Path $fixture.Directory '.config/yazi/flavors/catppuccin-macchiato.yazi/flavor.toml'), $latteFlavor)) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $flavorFile) -Force | Out-Null
            [IO.File]::WriteAllText($flavorFile, '# flavor')
        }
        Invoke-DotfilesDoctor $repository $fixture.Directory
        foreach ($name in @('carapace', 'atuin', 'mise', 'delta', 'lazygit', 'lazydocker', 'yazi', 'rg', 'fd', 'dust', 'duf', 'procs', 'sd', 'xh', 'hyperfine', 'glow', 'tldr', 'gum', 'direnv')) {
            Assert-True ($report -contains "  [ok] $name") "The doctor must check the $name command"
        }
        Assert-True ($report -contains '  [ok] Node.js via mise') 'A runtime mise can locate passes'
        Assert-True (($report -contains '  [ok] yazi flavor catppuccin-macchiato') -and ($report -contains '  [ok] yazi flavor catppuccin-latte')) 'Installed yazi flavors pass'
        foreach ($file in $files) {
            [IO.File]::WriteAllText($file.Destination, 'stale configuration')
            Assert-Throws { Invoke-DotfilesDoctor $repository $fixture.Directory } 'check\(s\) need attention'
            Copy-Item -LiteralPath $file.Source -Destination $file.Destination -Force
        }
        $fontPresent = $false
        Assert-Throws { Invoke-DotfilesDoctor $repository $fixture.Directory } 'check\(s\) need attention'
        $fontPresent = $true
        $modulePresent = $false
        Assert-Throws { Invoke-DotfilesDoctor $repository $fixture.Directory } 'check\(s\) need attention'
        $modulePresent = $true
        $runtimeExitCode = 1
        $report.Clear()
        Assert-Throws { Invoke-DotfilesDoctor $repository $fixture.Directory } '1 check\(s\) need attention'
        Assert-True ($report -contains '  [missing] Node.js via mise (rerun: scripts\install_runtimes.ps1)') 'A missing runtime names the stage that installs it'
        $runtimeExitCode = 0
        Invoke-DotfilesDoctor $repository $fixture.Directory
        Remove-Item -LiteralPath $latteFlavor
        $report.Clear()
        Assert-Throws { Invoke-DotfilesDoctor $repository $fixture.Directory } '1 check\(s\) need attention'
        Assert-True ($report -contains '  [missing] yazi flavor catppuccin-latte (rerun: scripts\install_runtimes.ps1)') 'A missing yazi flavor names the stage that installs it'
        [IO.File]::WriteAllText($latteFlavor, '# flavor')
        Invoke-DotfilesDoctor $repository $fixture.Directory
        # Without mise the runtime is missing too, and nothing is executed to find out.
        function Get-DotfilesCommandPath { param($Name) if ($Name -ne 'mise') { 'mock-command' } }
        function Invoke-DotfilesNativeCommand { throw 'Unexpected native command' }
        $report.Clear()
        Assert-Throws { Invoke-DotfilesDoctor $repository $fixture.Directory } '2 check\(s\) need attention'
        Assert-True (($report -contains '  [missing] mise') -and ($report -contains '  [missing] Node.js via mise (rerun: scripts\install_runtimes.ps1)')) 'Both mise and its runtime are reported'
    }

    Invoke-Test 'Runtime installation runs mise, then installs the missing yazi flavors, and can be retried' {
        $fixture = New-Fixture
        $yaziConfig = Join-Path $fixture.Directory '.config/yazi'
        $flavorsDirectory = Join-Path $yaziConfig 'flavors'
        $runtimeState = @{ MiseExitCode = 1; YaExitCode = 0; YaInstalls = $true; Calls = [Collections.Generic.List[string]]::new(); ConfigHomes = [Collections.Generic.List[string]]::new() }
        function Get-DotfilesCommandPath { param($Name) if ($Name -in @('mise', 'ya')) { "mock-$Name" } }
        function Invoke-DotfilesNativeCommand {
            param($Command, $Arguments, [switch]$Quiet)
            Assert-True (-not $Quiet) 'Installation output stays visible'
            $runtimeState.Calls.Add("$Command $($Arguments -join ' ')")
            if ($Command -eq 'mock-mise') { return $runtimeState.MiseExitCode }
            Assert-True ($Command -eq 'mock-ya' -and $Arguments[0] -eq 'pkg') "Unexpected native command: $Command $Arguments"
            $runtimeState.ConfigHomes.Add([string]$env:YAZI_CONFIG_HOME)
            if ($runtimeState.YaExitCode -eq 0 -and $runtimeState.YaInstalls) {
                # ya pkg install installs what package.toml declares; ya pkg add installs the named flavor.
                if ($Arguments[1] -eq 'install') {
                    $flavors = @([regex]::Matches([IO.File]::ReadAllText((Join-Path $yaziConfig 'package.toml')), 'flavors:([a-z-]+)') | ForEach-Object { $_.Groups[1].Value })
                } else { $flavors = @(($Arguments[2] -split ':')[1]) }
                foreach ($flavor in $flavors) {
                    $flavorFile = Join-Path $flavorsDirectory "$flavor.yazi/flavor.toml"
                    New-Item -ItemType Directory -Path (Split-Path -Parent $flavorFile) -Force | Out-Null
                    [IO.File]::WriteAllText($flavorFile, '# flavor')
                }
            }
            return $runtimeState.YaExitCode
        }
        $savedConfigHome = $env:YAZI_CONFIG_HOME
        $env:YAZI_CONFIG_HOME = 'previous value'
        try {
            Assert-Throws { Invoke-DotfilesRuntimeInstall $fixture.Directory } 'mise install failed \(exit code 1\)\. Rerun install.ps1 to retry'
            Assert-True (($runtimeState.Calls -join "`n") -eq 'mock-mise install --yes') 'A mise failure stops before the flavors'
            $runtimeState.MiseExitCode = 0
            $runtimeState.YaExitCode = 2
            Assert-Throws { Invoke-DotfilesRuntimeInstall $fixture.Directory } 'ya pkg add yazi-rs/flavors:catppuccin-macchiato failed \(exit code 2\)\. Rerun install.ps1 to retry'
            $runtimeState.YaExitCode = 0
            $runtimeState.YaInstalls = $false
            Assert-Throws { Invoke-DotfilesRuntimeInstall $fixture.Directory } 'yazi flavor catppuccin-macchiato was not installed'
            Assert-True ($env:YAZI_CONFIG_HOME -eq 'previous value') 'YAZI_CONFIG_HOME is restored after a failure'
            $runtimeState.YaInstalls = $true
            $runtimeState.Calls.Clear()
            Invoke-DotfilesRuntimeInstall $fixture.Directory
            Assert-True (($runtimeState.Calls -join "`n") -eq "mock-mise install --yes`nmock-ya pkg add yazi-rs/flavors:catppuccin-macchiato`nmock-ya pkg add yazi-rs/flavors:catppuccin-latte") "The retry adds every missing flavor: $($runtimeState.Calls -join ' | ')"
            Assert-True (@($runtimeState.ConfigHomes | Where-Object { $_ -ne $yaziConfig }).Count -eq 0) 'ya must see the yazi configuration under the home directory'
            Assert-True ($env:YAZI_CONFIG_HOME -eq 'previous value') 'YAZI_CONFIG_HOME is restored after success'
            $runtimeState.Calls.Clear()
            Invoke-DotfilesRuntimeInstall $fixture.Directory
            Assert-True (($runtimeState.Calls -join "`n") -eq 'mock-mise install --yes') 'Installed flavors are skipped'
            # A flavor that package.toml already declares is installed from it; the other is still added.
            Remove-Item -LiteralPath $flavorsDirectory -Recurse -Force
            [IO.File]::WriteAllText((Join-Path $yaziConfig 'package.toml'), "[[flavor.deps]]`nuse = `"yazi-rs/flavors:catppuccin-macchiato`"`n")
            $runtimeState.Calls.Clear()
            Invoke-DotfilesRuntimeInstall $fixture.Directory
            Assert-True (($runtimeState.Calls -join "`n") -eq "mock-mise install --yes`nmock-ya pkg install`nmock-ya pkg add yazi-rs/flavors:catppuccin-latte") "Declared flavors come from package.toml: $($runtimeState.Calls -join ' | ')"
            # ya is needed only while a flavor is missing.
            function Get-DotfilesCommandPath { param($Name) if ($Name -eq 'mise') { 'mock-mise' } }
            Invoke-DotfilesRuntimeInstall $fixture.Directory
            Remove-Item -LiteralPath $flavorsDirectory -Recurse -Force
            Assert-Throws { Invoke-DotfilesRuntimeInstall $fixture.Directory } 'ya is unavailable.*Reopen PowerShell and rerun install.ps1'
            function Get-DotfilesCommandPath { param($Name) $null }
            $runtimeState.Calls.Clear()
            Assert-Throws { Invoke-DotfilesRuntimeInstall $fixture.Directory } 'mise is unavailable.*Reopen PowerShell and rerun install.ps1'
            Assert-True ($runtimeState.Calls.Count -eq 0) 'Nothing runs without a discoverable mise'
        } finally { $env:YAZI_CONFIG_HOME = $savedConfigHome }
    }

    Invoke-Test 'Linking seeds an unmanaged .gitconfig once and never rewrites it' {
        $fixture = New-Fixture
        function Get-DotfilesManagedFiles { param($DotfilesDir, $HomeDirectory) [pscustomobject]@{ Source = $fixture.Source; Destination = $fixture.Destination } }
        $gitConfig = Join-Path $fixture.Directory '.gitconfig'
        Invoke-DotfilesLink $repository $fixture.Directory
        Assert-True (Test-DotfilesManagedFile $fixture.Source $fixture.Destination) 'Managed files are still set up'
        $seed = [IO.File]::ReadAllText($gitConfig)
        $seedLines = @($seed -split '\r?\n')
        Assert-True (($seedLines -ccontains '# Identity and credential helpers belong here; this file is not managed by the dotfiles repository.') -and
            ($seedLines -ccontains '# Shared settings live in ~/.config/git/config.')) 'A missing .gitconfig is created with the two comment lines'
        Assert-True (@($seedLines | Where-Object { $_ -notmatch '^(#|$)' }).Count -eq 0) 'The seed holds comments only'
        Invoke-DotfilesLink $repository $fixture.Directory
        Assert-True ([IO.File]::ReadAllText($gitConfig) -eq $seed) 'Reruns leave the seed alone'
        $identity = "[user]`n`tname = Example`n"
        [IO.File]::WriteAllText($gitConfig, $identity)
        Invoke-DotfilesLink $repository $fixture.Directory
        Assert-True ([IO.File]::ReadAllText($gitConfig) -eq $identity) 'An existing .gitconfig is never touched'
        Assert-True (@(Get-ChildItem -LiteralPath $fixture.Directory -Filter '*.bak.*' -Force).Count -eq 0) 'No backup is made of .gitconfig'
        if ($canCreateSymlinks) {
            Remove-Item -LiteralPath $gitConfig -Force
            # Windows PowerShell refuses a link to a missing target: create it, link, then remove it.
            $missingTarget = Join-Path $fixture.Directory 'missing-gitconfig'
            [IO.File]::WriteAllText($missingTarget, 'temporary target')
            New-Item -ItemType SymbolicLink -Path $gitConfig -Target $missingTarget | Out-Null
            Remove-Item -LiteralPath $missingTarget
            Invoke-DotfilesLink $repository $fixture.Directory
            $link = Get-DotfilesPathItem $gitConfig
            Assert-True ($link.LinkType -eq 'SymbolicLink' -and ([string]$link.Target) -match 'missing-gitconfig$') 'A dangling .gitconfig link is left for the user to fix'
        }
    }

    Invoke-Test 'Setup verifies before its completion message and propagates verification failures' {
        $events = [Collections.Generic.List[string]]::new()
        function Invoke-DotfilesPackageInstall { param($DotfilesDir) $events.Add('packages') }
        function Invoke-DotfilesModuleInstall { $events.Add('modules') }
        function Invoke-DotfilesLink { param($DotfilesDir, $HomeDirectory) $events.Add('links') }
        function Invoke-DotfilesRuntimeInstall { param($HomeDirectory) Assert-True ($HomeDirectory -eq $testRoot) 'The runtimes stage receives the home directory'; $events.Add('runtimes') }
        function Invoke-DotfilesDoctor { param($DotfilesDir, $HomeDirectory) $events.Add('verified') }
        function Write-Host { param($Object) if ([string]$Object -match '^Done\.') { $events.Add('done') } }
        Invoke-DotfilesInstall $repository $testRoot
        # mise reads the linked configuration, so runtimes follow the links and precede verification.
        Assert-True (($events -join ',') -eq 'packages,modules,links,runtimes,verified,done') 'Completion must follow successful verification'
        $events.Clear()
        function Invoke-DotfilesRuntimeInstall { throw 'simulated runtime failure' }
        Assert-Throws { Invoke-DotfilesInstall $repository $testRoot } 'Installing runtimes failed: simulated runtime failure.*Completed setup remains in place.*rerun:.*install.ps1'
        Assert-True (($events -join ',') -eq 'packages,modules,links') 'A runtime failure stops before verification'
        $events.Clear()
        function Invoke-DotfilesRuntimeInstall { $events.Add('runtimes') }
        function Invoke-DotfilesDoctor { param($DotfilesDir, $HomeDirectory) throw 'simulated verification failure' }
        Assert-Throws { Invoke-DotfilesInstall $repository $testRoot } 'Verifying setup failed: simulated verification failure.*Completed setup remains in place.*rerun:.*install.ps1'
        Assert-True (-not $events.Contains('done')) 'Failed verification must suppress completion'
        $events.Clear()
        function Invoke-DotfilesDoctor { param($DotfilesDir, $HomeDirectory) $events.Add('verified') }
        Invoke-DotfilesInstall $repository $testRoot
        Assert-True (($events -join ',') -eq 'packages,modules,links,runtimes,verified,done') 'Retry should complete after verification succeeds'
    }

    Invoke-Test 'Native exit statuses are returned even with native error promotion enabled' {
        $PSNativeCommandUseErrorActionPreference = $true
        $shell = (Get-Process -Id $PID).Path
        $code = Invoke-DotfilesNativeCommand $shell @('-NoProfile', '-NonInteractive', '-Command', 'exit 7') -Quiet
        Assert-True ($code -eq 7) 'Caller must receive nonzero exit code'
    }

    if ($env:OS -eq 'Windows_NT') {
        Invoke-Test 'Native Windows discovers both actual profile locations without executing them' {
            $paths = Get-DotfilesProfilePaths
            Assert-True ($paths.Count -eq 2) 'Both Windows editions must resolve'
            Assert-True ($paths.Values -contains $PROFILE.CurrentUserAllHosts) 'Current edition should match its actual profile path'
        }
    } else { Write-Host 'SKIP: native Windows profile discovery requires Windows; mocked redirected-profile discovery passed.' }
    Write-Host "All $testCount Windows behavioral tests passed."
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
