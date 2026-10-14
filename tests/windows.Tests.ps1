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
        function Get-DotfilesWingetListedVersions { param($WingetCommand, $Package) }
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
        function Get-DotfilesWingetListedVersions { param($WingetCommand, $Package) }
        function Invoke-DotfilesNativeCommand { param($Command, $Arguments, [switch]$Quiet) 5 }
        Assert-Throws { Invoke-DotfilesPackageInstall $repository } 'could not check.*exit code 5'
        function Invoke-DotfilesNativeCommand {
            param($Command, $Arguments, [switch]$Quiet)
            if ($Arguments[0] -eq 'list') { return -1978335212 }; return 7
        }
        Assert-Throws { Invoke-DotfilesPackageInstall $repository } 'failed to install.*exit code 7'
    }

    Invoke-Test 'An install that needs a restart to finish counts as installed, as an upgrade does' {
        $report = [Collections.Generic.List[string]]::new()
        $calls = [Collections.Generic.List[string]]::new()
        function Get-DotfilesCommandPath { param($Name) $Name }
        function Get-DotfilesWingetListedVersions { param($WingetCommand, $Package) }
        function Update-DotfilesProcessPath { }
        function Invoke-DotfilesFontInstall { $calls.Add('font') }
        function Write-Host { param($Object) $report.Add([string]$Object) }
        function Invoke-DotfilesNativeCommand {
            param($Command, $Arguments, [switch]$Quiet)
            if ($Arguments[0] -eq 'list') { return $WingetNoApplicationsFound }
            $calls.Add("install $($Arguments[2])")
            if ($Arguments[2] -eq 'Git.Git') { return $WingetRebootRequiredToFinish }
            return 0
        }
        Invoke-DotfilesPackageInstall $repository
        Assert-True ($report -contains '  installed: Git.Git (restart Windows to finish)') "The restart is reported: $($report -join ' | ')"
        Assert-True ($calls[-1] -eq 'font' -and $calls.Count -gt 2) 'The remaining packages and the font follow'
    }

    Invoke-Test 'Updating upgrades installed winget packages and leaves pinned, unknown and running ones alone' {
        $fixture = New-Fixture
        New-Item -ItemType Directory -Path (Join-Path $fixture.Directory 'packages') | Out-Null
        [IO.File]::WriteAllLines((Join-Path $fixture.Directory 'packages/winget.txt'),
            [string[]]@('# fixture', 'Test.Current', 'Test.Newer', 'Test.Pinned', 'Test.Blocked', 'Test.Unknown', 'Test.Missing', 'Microsoft.WindowsTerminal'))
        # Test.Pinned has a plain pin, which winget would let an upgrade by id
        # through; Test.Blocked has a blocking pin the pin check did not see.
        $upgradeCodes = @{ 'Test.Current' = $WingetUpdateNotApplicable; 'Test.Newer' = 0; 'Test.Pinned' = 0; 'Test.Blocked' = $WingetPackageIsPinned; 'Test.Unknown' = $WingetUpgradeVersionUnknown }
        $calls = [Collections.Generic.List[string]]::new()
        $report = [Collections.Generic.List[string]]::new()
        function Get-DotfilesCommandPath { param($Name) $Name }
        function Get-DotfilesRunningHostPackages { 'Microsoft.WindowsTerminal' }
        function Get-DotfilesWingetListedVersions { param($WingetCommand, $Package) }
        function Test-DotfilesWingetPinned { param($WingetCommand, $Package) $Package -eq 'Test.Pinned' }
        function Update-DotfilesProcessPath { }
        function Invoke-DotfilesFontInstall { $calls.Add('font') }
        function Write-Host { param($Object) $report.Add([string]$Object) }
        function Invoke-DotfilesNativeCommand {
            param($Command, $Arguments, [switch]$Quiet)
            $calls.Add("$($Arguments[0]) $($Arguments[2])")
            if ($Arguments[0] -eq 'list') {
                if ($Arguments[2] -eq 'Test.Missing') { return $WingetNoApplicationsFound }
                return 0
            }
            if ($Arguments[0] -eq 'upgrade') {
                Assert-True (($Arguments -contains '--exact') -and ($Arguments -contains '--silent')) 'Upgrades name the exact package and run silently'
                return $upgradeCodes[$Arguments[2]]
            }
            return 0
        }
        Invoke-DotfilesPackageInstall $fixture.Directory
        Assert-True (@($calls | Where-Object { $_ -like 'upgrade *' }).Count -eq 0) 'A plain install upgrades nothing'
        $calls.Clear(); $report.Clear()
        Invoke-DotfilesPackageInstall $fixture.Directory -Update
        $upgrades = @($calls | Where-Object { $_ -like 'upgrade *' }) -join ','
        Assert-True ($upgrades -eq 'upgrade Test.Current,upgrade Test.Newer,upgrade Test.Blocked,upgrade Test.Unknown') "Every installed package but the pinned one and the running terminal is upgraded: $upgrades"
        Assert-True (($calls -contains 'install Test.Missing') -and ($calls[-1] -eq 'font')) 'A missing package is installed and the font check still follows'
        Assert-True (($report -contains '  up to date: Test.Current') -and ($report -contains '  upgraded: Test.Newer')) "Current and upgraded packages are reported: $($report -join ' | ')"
        Assert-True (@($report | Where-Object { $_ -like '  pinned, left alone: Test.Pinned (winget pin remove*' }).Count -eq 1) 'A pinned package is left alone'
        Assert-True (@($report | Where-Object { $_ -like '  pinned, left alone: Test.Blocked (winget pin remove*' }).Count -eq 1) 'A package winget refuses for its pin is left alone'
        Assert-True (@($report | Where-Object { $_ -like '  left alone: Test.Unknown (*--include-unknown)' }).Count -eq 1) 'A package of unknown version is left alone'
        Assert-True (@($report | Where-Object { $_ -like '  left alone: Microsoft.WindowsTerminal runs this update*' }).Count -eq 1) 'The terminal running the update is left alone'
        $upgradeCodes['Test.Newer'] = 5
        $calls.Clear()
        Assert-Throws { Invoke-DotfilesPackageInstall $fixture.Directory -Update } 'failed to upgrade Test\.Newer \(exit code 5\)\. Rerun scripts\\update\.ps1'
        Assert-True (-not $calls.Contains('font')) 'A failed upgrade stops before the font'
        $upgradeCodes['Test.Newer'] = 0
        Invoke-DotfilesPackageInstall $fixture.Directory -Update
        Assert-True ((Get-DotfilesRunningHostPackages) -eq 'Microsoft.WindowsTerminal') 'The mock stands in for host detection'
    }

    Invoke-Test 'A winget pin is found by the package id on its row of the pin table' {
        $pinState = @{ Lines = @(); Arguments = $null }
        function Invoke-Fake-Winget { $pinState.Arguments = $args -join ' '; $pinState.Lines }
        $pinState.Lines = @('Name       Id               Version Source Pin type', '-------------------------------------------------', 'PowerShell Microsoft.PowerShell 7.5.0 winget Pinning')
        Assert-True (Test-DotfilesWingetPinned 'Invoke-Fake-Winget' 'Microsoft.PowerShell') 'A pinned package is found'
        Assert-True ($pinState.Arguments -eq 'pin list --id Microsoft.PowerShell --exact --accept-source-agreements') "winget is asked for that package's pin: $($pinState.Arguments)"
        Assert-True (-not (Test-DotfilesWingetPinned 'Invoke-Fake-Winget' 'Microsoft.Power')) 'A longer id does not match a shorter one'
        $pinState.Lines = @('PowerShell Preview Microsoft.PowerShell.Preview 7.6.0 winget Blocking')
        Assert-True (-not (Test-DotfilesWingetPinned 'Invoke-Fake-Winget' 'Microsoft.PowerShell')) 'A pin of another package does not count'
        $pinState.Lines = @('There are no pins configured.')
        Assert-True (-not (Test-DotfilesWingetPinned 'Invoke-Fake-Winget' 'Microsoft.PowerShell')) 'No pins means not pinned'
    }

    Invoke-Test 'A package winget finds only without --exact counts as installed, and the update installs a newer one again' {
        $fixture = New-Fixture
        New-Item -ItemType Directory -Path (Join-Path $fixture.Directory 'packages') | Out-Null
        [IO.File]::WriteAllLines((Join-Path $fixture.Directory 'packages/winget.txt'), [string[]]@('Test.Portable', 'Test.Missing'))
        # Like rsteube.Carapace on winget 1.11: listed without --exact only, and unknown to winget upgrade.
        $state = @{ Listed = @('1.0.6', '1.8.0', 'winget'); InstallCode = 0; Calls = [Collections.Generic.List[string]]::new() }
        $report = [Collections.Generic.List[string]]::new()
        function Get-DotfilesCommandPath { param($Name) $Name }
        function Get-DotfilesRunningHostPackages { }
        function Test-DotfilesWingetPinned { param($WingetCommand, $Package) $false }
        function Update-DotfilesProcessPath { }
        function Invoke-DotfilesFontInstall { }
        function Write-Host { param($Object) $report.Add([string]$Object) }
        function Get-DotfilesWingetListedVersions { param($WingetCommand, $Package) if ($Package -eq 'Test.Portable') { $state.Listed } }
        function Invoke-DotfilesNativeCommand {
            param($Command, $Arguments, [switch]$Quiet)
            $state.Calls.Add("$($Arguments[0]) $($Arguments[2])")
            if ($Arguments[0] -in @('list', 'upgrade')) { return $WingetNoApplicationsFound }
            Assert-True ($Arguments -contains '--exact') 'The install names the exact package'
            return $state.InstallCode
        }
        Invoke-DotfilesPackageInstall $fixture.Directory
        Assert-True ($report -contains '  already installed: Test.Portable') "The listing counts as installed: $($report -join ' | ')"
        Assert-True (($state.Calls -join ',') -eq 'list Test.Portable,list Test.Missing,install Test.Missing') "Only the missing package is installed: $($state.Calls -join ',')"
        $state.Calls.Clear(); $report.Clear()
        Invoke-DotfilesPackageInstall $fixture.Directory -Update
        Assert-True ($report -contains '  upgraded: Test.Portable (installed again: winget upgrade cannot find it)') "A newer version is installed again: $($report -join ' | ')"
        Assert-True (($state.Calls -join ',') -match '^list Test\.Portable,upgrade Test\.Portable,install Test\.Portable,') "The install follows the failed upgrade: $($state.Calls -join ',')"
        $state.Listed = @('1.8.0', 'winget')
        $state.Calls.Clear(); $report.Clear()
        Invoke-DotfilesPackageInstall $fixture.Directory -Update
        Assert-True (($report -contains '  up to date: Test.Portable') -and -not ($state.Calls -contains 'install Test.Portable')) "Without a newer version nothing is installed: $($report -join ' | ')"
        $state.Listed = @('1.0.6', '1.8.0', 'winget')
        $state.InstallCode = 9
        Assert-Throws { Invoke-DotfilesPackageInstall $fixture.Directory -Update } 'failed to install the newer Test\.Portable \(exit code 9\)\. Rerun scripts\\update\.ps1'
    }

    Invoke-Test 'The listing without --exact is read from the row that names the package id' {
        $listState = @{ Lines = @(); Arguments = $null }
        function Invoke-Fake-Winget { $listState.Arguments = $args -join ' '; $listState.Lines }
        # winget draws a spinner before the table, separated by carriage returns.
        $listState.Lines = @("   - `r   \ `rName     Id               Version Available Source", '-----------------------------------------------------', 'Carapace rsteube.Carapace 1.0.6   1.8.0     winget')
        $versions = @(Get-DotfilesWingetListedVersions 'Invoke-Fake-Winget' 'rsteube.Carapace')
        Assert-True (($versions -join ' ') -eq '1.0.6 1.8.0 winget') "The row's installed and available versions and source are read: $versions"
        Assert-True ($listState.Arguments -eq 'list --id rsteube.Carapace --accept-source-agreements') "winget lists the id without --exact: $($listState.Arguments)"
        $listState.Lines = @("`r-`rsd - search & displace chmln.sd 1.1.0 winget")
        Assert-True ((@(Get-DotfilesWingetListedVersions 'Invoke-Fake-Winget' 'chmln.sd') -join ' ') -eq '1.1.0 winget') 'A name with spaces and a spinner before the row do not matter'
        $listState.Lines = @('Carapace Bin rsteube.CarapaceBin 2.0.0 winget')
        Assert-True ($null -eq (Get-DotfilesWingetListedVersions 'Invoke-Fake-Winget' 'rsteube.Carapace')) 'A longer id does not match a shorter one'
        $listState.Lines = @('No installed package found matching input criteria.')
        Assert-True ($null -eq (Get-DotfilesWingetListedVersions 'Invoke-Fake-Winget' 'rsteube.Carapace')) 'Nothing listed returns nothing'
    }

    Invoke-Test 'The update leaves PowerShell 7 and Windows Terminal to another shell only while they run it' {
        $savedSession = $env:WT_SESSION
        try {
            $env:WT_SESSION = 'fixture-session'
            $hosts = @(Get-DotfilesRunningHostPackages)
            Assert-True ($hosts -contains 'Microsoft.WindowsTerminal') 'Inside Windows Terminal the terminal is a host'
            Assert-True (($hosts -contains 'Microsoft.PowerShell') -eq ($PSVersionTable.PSEdition -eq 'Core')) 'PowerShell 7 is a host only when it runs the update'
            $env:WT_SESSION = $null
            Assert-True (-not (@(Get-DotfilesRunningHostPackages) -contains 'Microsoft.WindowsTerminal')) 'Outside Windows Terminal the terminal can be upgraded'
        } finally { $env:WT_SESSION = $savedSession }
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
        # A font name would make oh-my-posh ask GitHub's API without a token; the release URL does not.
        function Invoke-DotfilesNativeCommand {
            param($Command, $Arguments)
            Assert-True (($Arguments -join ' ') -eq 'font install https://github.com/ryanoasis/nerd-fonts/releases/latest/download/CascadiaCode.zip') "The font comes from the Nerd Fonts release URL: $Arguments"
            1
        }
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

    Invoke-Test 'Updating installs a newer gallery version of each module and nothing else' {
        $moduleState = @{ Exit = @{ 'Terminal-Icons' = 4; 'PSFzf' = 0; 'posh-git' = 4; 'CompletionPredictor' = 4 }; Updates = [Collections.Generic.List[string]]::new(); Script = $null }
        $report = [Collections.Generic.List[string]]::new()
        function Get-DotfilesCommandPath { param($Name) if ($Name -eq 'pwsh.exe') { 'mock-pwsh' } }
        function Write-Host { param($Object) $report.Add([string]$Object) }
        function Invoke-DotfilesNativeCommand {
            param($Command, $Arguments, [switch]$Quiet)
            Assert-True ($Command -eq 'mock-pwsh' -and ($Arguments -contains '-NoProfile') -and ($Arguments -contains '-NonInteractive')) 'Modules are updated by pwsh without profiles'
            $script = [string]$Arguments[-1]
            if ($script -notmatch "Find-Module -Name '([^']+)'") { return 0 }
            $name = $Matches[1]
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseInput($script, [ref]$null, [ref]$errors) | Out-Null
            Assert-True ($errors.Count -eq 0) "The update script parses: $script"
            Assert-True ($script -notmatch '"') 'The update script has no double quotes for native argument passing'
            Assert-True ($script -match "Install-Module -Name '$name' -Scope CurrentUser -Repository PSGallery -Force") 'A newer version is installed for the current user'
            $moduleState.Updates.Add($name)
            $moduleState.Script = $script
            return $moduleState.Exit[$name]
        }
        Invoke-DotfilesModuleInstall
        Assert-True ($moduleState.Updates.Count -eq 0) 'A plain install does not look for newer versions'
        Invoke-DotfilesModuleInstall -Update
        Assert-True ($moduleState.Updates.Count -eq @(Get-DotfilesPowerShellModules).Count) 'Every module is checked'
        Assert-True (($report -contains '  updated: PSFzf') -and ($report -contains '  up to date: posh-git')) "Updated and current modules are reported: $($report -join ' | ')"
        $moduleState.Exit['PSFzf'] = 1
        Assert-Throws { Invoke-DotfilesModuleInstall -Update } 'Updating the PSFzf module failed \(exit code 1\)\. Rerun scripts\\update\.ps1'
        $moduleState.Exit['PSFzf'] = 0
        Invoke-DotfilesModuleInstall -Update
        # The script itself, run in a child shell against stand-ins for the
        # gallery: an older installed version is replaced, a current one exits 4.
        $shell = (Get-Process -Id $PID).Path
        foreach ($case in @(@{ Latest = '2.1.0'; Exit = 0 }, @{ Latest = '2.0.0'; Exit = 4 }, @{ Latest = '1.9.0'; Exit = 4 })) {
            $stubs = "function Get-Module { [pscustomobject]@{ Version = [version]'1.5.0' }; [pscustomobject]@{ Version = [version]'2.0.0' } }; " +
                "function Find-Module { [pscustomobject]@{ Version = '$($case.Latest)' } }; function Install-Module { }; "
            & $shell -NoProfile -NonInteractive -Command ($stubs + $moduleState.Script) | Out-Null
            Assert-True ($LASTEXITCODE -eq $case.Exit) "Gallery $($case.Latest) against installed 2.0.0 exits $($case.Exit), not $LASTEXITCODE"
        }
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

    Invoke-Test 'Managed files include the Windows Terminal fragment, the eza theme and every tool configuration' {
        function Get-DotfilesProfilePaths {
            [ordered]@{ PowerShell = Join-Path $testRoot 'modern/profile.ps1'; WindowsPowerShell = Join-Path $testRoot 'legacy/profile.ps1' }
        }
        $files = @(Get-DotfilesManagedFiles $repository $testRoot)
        foreach ($file in $files) { Assert-True (Test-Path -LiteralPath $file.Source -PathType Leaf) "Managed source must exist: $($file.Source)" }
        $destinations = @($files | ForEach-Object { $_.Destination })
        Assert-True ($destinations -contains (Join-Path $testRoot 'AppData/Local/Microsoft/Windows Terminal/Fragments/dotfiles/fragment.json')) 'The fragment must land in the Fragments folder under the home directory'
        Assert-True ($destinations -contains (Join-Path $testRoot '.config/eza/theme.yml')) 'The eza theme must be managed'
        # Git for Windows, lazygit, yazi, atuin, mise and fastfetch all read these from ~/.config.
        foreach ($relative in @('git/config', 'git/ignore', 'git/catppuccin.gitconfig', 'lazygit/config.yml', 'yazi/yazi.toml', 'yazi/theme.toml',
                'atuin/config.toml', 'atuin/themes/catppuccin-latte-blue.toml', 'atuin/themes/catppuccin-frappe-blue.toml',
                'atuin/themes/catppuccin-macchiato-blue.toml', 'atuin/themes/catppuccin-mocha-blue.toml', 'mise/config.toml',
                'fastfetch/config.jsonc')) {
            $expected = Join-Path $testRoot ".config/$relative"
            $match = @($files | Where-Object { $_.Destination -eq $expected })
            Assert-True ($match.Count -eq 1) "$relative must be managed under .config"
            Assert-True ($match[0].Source -eq (Join-Path $repository "config/$relative")) "$relative must come from config/$relative"
        }
        Assert-True (@($destinations | Select-Object -Unique).Count -eq $destinations.Count) 'Destinations must be unique'
        # Neovim reads %LOCALAPPDATA%\nvim; every file of config/nvim is managed there, one by one.
        $nvimSource = Join-Path $repository 'config/nvim'
        $nvimFiles = @(Get-ChildItem -LiteralPath $nvimSource -Recurse -File -Force)
        Assert-True ($nvimFiles.Count -ge 3) 'config/nvim holds the Neovim configuration'
        foreach ($nvimFile in $nvimFiles) {
            $relative = $nvimFile.FullName.Substring((Get-Item -LiteralPath $nvimSource).FullName.Length).TrimStart('\', '/')
            $expected = Join-Path $testRoot "AppData/Local/nvim/$relative"
            $match = @($files | Where-Object { $_.Destination -eq $expected })
            Assert-True ($match.Count -eq 1) "config/nvim/$relative must be managed under AppData/Local/nvim"
            Assert-True ($match[0].Source -eq $nvimFile.FullName) "$relative must come from config/nvim"
        }
        foreach ($name in @('init.lua', 'lazy-lock.json', '.luarc.json', 'lua/dotfiles/options.lua')) {
            Assert-True ($destinations -contains (Join-Path $testRoot "AppData/Local/nvim/$name")) "Neovim $name must be managed"
        }
        # atuin selects its theme by file name, so the named theme must be among the managed files.
        $atuinConfig = [IO.File]::ReadAllText((Join-Path $repository 'config/atuin/config.toml'))
        Assert-True ($atuinConfig -match '(?m)^name = "([^"]+)"') 'atuin config names a theme'
        Assert-True ($destinations -contains (Join-Path $testRoot ".config/atuin/themes/$($Matches[1]).toml")) "The atuin theme $($Matches[1]) must be managed"
    }

    Invoke-Test 'The winget list declares every tool exactly once' {
        $packages = @(Get-Content -LiteralPath (Join-Path $repository 'packages/winget.txt') |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^#' })
        # winget --exact compares IDs case-sensitively, so the spelling must match the manifests.
        foreach ($id in @('rsteube.Carapace', 'Atuinsh.Atuin', 'jdx.mise', 'dandavison.delta', 'JesseDuffield.lazygit', 'JesseDuffield.Lazydocker',
                'sxyazi.yazi', 'BurntSushi.ripgrep.MSVC', 'sharkdp.fd', 'bootandy.dust', 'muesli.duf', 'dalance.procs', 'chmln.sd', 'ducaale.xh',
                'sharkdp.hyperfine', 'charmbracelet.glow', 'tldr-pages.tlrc', 'charmbracelet.gum', 'direnv.direnv', 'Fastfetch-cli.Fastfetch')) {
            Assert-True ($packages -ccontains $id) "winget.txt must declare $id"
        }
        foreach ($package in $packages) { Assert-True ($package -match '^[A-Za-z0-9][A-Za-z0-9.+_-]*$') "Not a bare winget ID: $package" }
        $lowered = @($packages | ForEach-Object { $_.ToLowerInvariant() })
        Assert-True (@($lowered | Select-Object -Unique).Count -eq $lowered.Count) 'winget IDs must be unique'
    }

    Invoke-Test 'The Windows Terminal fragment carries the current flavor to the stock profiles' {
        # scripts/theme.sh records the flavor and vendors the palette; the test follows both.
        $flavorName = (Get-Content -LiteralPath (Join-Path $repository 'config/catppuccin/flavor') -First 1).Trim()
        $flavorTitle = $flavorName.Substring(0, 1).ToUpperInvariant() + $flavorName.Substring(1)
        $palette = @{}
        foreach ($line in Get-Content -LiteralPath (Join-Path $repository 'config/catppuccin/palette.txt')) {
            if ($line -match "^$flavorName (\S+) (#[0-9a-f]{6})$") { $palette[$Matches[1]] = $Matches[2].ToUpperInvariant() }
        }
        Assert-True ($palette.Count -eq 26) "The palette must list every $flavorName color"
        $fragment = Get-Content -Raw -LiteralPath (Join-Path $repository 'config/windows-terminal/fragment.json') | ConvertFrom-Json
        $schemes = @($fragment.schemes | Where-Object { $_.name -eq "Catppuccin $flavorTitle" })
        Assert-True ($schemes.Count -eq 1) "Exactly one Catppuccin $flavorTitle scheme"
        foreach ($key in @('background', 'foreground', 'cursorColor', 'selectionBackground', 'black', 'red', 'green', 'yellow', 'blue', 'purple', 'cyan', 'white',
                'brightBlack', 'brightRed', 'brightGreen', 'brightYellow', 'brightBlue', 'brightPurple', 'brightCyan', 'brightWhite')) {
            Assert-True ([string]$schemes[0].$key -match '^#[0-9A-F]{6}$') "$key must be an uppercase hex color"
        }
        Assert-True ($schemes[0].background -eq $palette['base'] -and $schemes[0].foreground -eq $palette['text']) "Scheme must be $flavorName base and text"
        $profiles = @($fragment.profiles)
        $updates = @($profiles | ForEach-Object { $_.updates })
        # PowerShell 7, Windows PowerShell and Command Prompt: the stock profiles a fragment may modify.
        foreach ($guid in @('{574e775e-4f2a-5b96-ac1e-a2962a402336}', '{61c54bbd-c2c6-5271-96e7-009a87ff44bf}', '{0caa0dad-35be-5f56-a8ff-afceeeaa6101}')) {
            Assert-True ($updates -contains $guid) "Fragment must update profile $guid"
        }
        foreach ($profile in $profiles) {
            Assert-True ($profile.colorScheme -eq "Catppuccin $flavorTitle") 'Every profile update must select the scheme'
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
        # oh-my-posh's init imports PSReadLine for the transient prompt's keys, interactive or not.
        $promptConfig = Join-Path $fixture.Directory '.config/oh-my-posh/config.omp.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $promptConfig) -Force | Out-Null
        [IO.File]::WriteAllText($promptConfig, '{}')
        $prefixes = @{ 'oh-my-posh' = 'Import-Module PSReadLine -ErrorAction SilentlyContinue; ' }
        $integrations = @('oh-my-posh', 'mise', 'carapace', 'atuin', 'direnv', 'yazi', 'fastfetch')
        foreach ($tool in @('eza', 'bat', 'fzf') + $integrations) {
            if ($env:OS -eq 'Windows_NT') {
                $body = "@echo off`r`n"
                if ($tool -in $integrations) { $body += "echo $($prefixes[$tool])`$env:DOTFILES_TEST_CALLS += '$tool %*;'`r`n" }
                [IO.File]::WriteAllText((Join-Path $stubBin "$tool.cmd"), $body + "exit 0`r`n")
            } else {
                $body = "#!/bin/sh`n"
                if ($tool -in $integrations) { $body += "echo `"$($prefixes[$tool])\`$env:DOTFILES_TEST_CALLS += '$tool `$*;'`"`n" }
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
$homeBefore = [Environment]::GetEnvironmentVariable('HOME')
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
if (-not $calls.Contains('oh-my-posh init pwsh --config')) { throw "The profile did not initialise oh-my-posh. Recorded: $calls" }
$expectedCalls = @('mise activate pwsh;')
# direnv's hook throws below PowerShell 7.2; where it runs, direnv gets HOME and Git's bash.
if ($PSVersionTable.PSVersion.Major -gt 7 -or ($PSVersionTable.PSVersion.Major -eq 7 -and $PSVersionTable.PSVersion.Minor -ge 2)) {
    $expectedCalls += 'direnv hook pwsh;'
    if ($homeBefore -and $env:HOME -ne $homeBefore) { throw "The profile changed HOME from '$homeBefore' to '$env:HOME'" }
    if (-not $homeBefore -and $env:HOME -ne $env:DOTFILES_TEST_HOME) { throw "HOME is '$env:HOME', expected the home directory for direnv" }
    if ($env:ProgramFiles) {
        $gitBash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
        if ((Test-Path -LiteralPath $gitBash) -and $env:DIRENV_BASH -ne $gitBash) { throw "DIRENV_BASH is '$env:DIRENV_BASH', expected '$gitBash'" }
    }
} elseif ($calls -match 'direnv') { throw "direnv's hook must not run in PowerShell $($PSVersionTable.PSVersion). Recorded: $calls" }
# The PSReadLine block follows the host's PSReadLine, not the one oh-my-posh's init imported:
# CompletionPredictor would deadlock PowerShell 7 at the end of a non-interactive command.
if ($env:DOTFILES_TEST_READLINE -eq 'yes') { $expectedCalls += @('carapace _carapace;', 'atuin init powershell --disable-up-arrow;') }
elseif ($calls -match 'carapace|atuin') { throw "The PSReadLine block ran in a shell whose host had not loaded PSReadLine. Recorded: $calls" }
foreach ($call in $expectedCalls) {
    if (-not $calls.Contains($call)) { throw "The profile did not evaluate '$call'. Recorded: $calls" }
}
if ($calls -match 'yazi') { throw "yazi must not run while the profile loads. Recorded: $calls" }
# This probe runs with -NonInteractive and -EncodedCommand, so the greeter stays quiet; the decision itself is checked directly.
if ($calls -match 'fastfetch') { throw "fastfetch must not run in a non-interactive shell. Recorded: $calls" }
if (-not (Test-DotfilesGreeting -Arguments @() -HostName 'ConsoleHost')) { throw 'A plain console start must greet' }
if (-not (Test-DotfilesGreeting -Arguments @('-NoLogo', '-ExecutionPolicy', 'Bypass') -HostName 'ConsoleHost')) { throw 'NoLogo and ExecutionPolicy must still greet' }
foreach ($quiet in @(@('-NonInteractive'), @('-noni'), @('-Command', 'ls'), @('-c', 'ls'), @('-File', 'x.ps1'), @('-f', 'x.ps1'), @('-EncodedCommand', 'AA=='), @('-e', 'AA=='))) {
    if (Test-DotfilesGreeting -Arguments $quiet -HostName 'ConsoleHost') { throw "Start arguments $quiet must not greet" }
}
if (Test-DotfilesGreeting -Arguments @() -HostName 'Visual Studio Code Host') { throw 'Other hosts must not greet' }
$env:DOTFILES_FASTFETCH = '0'
if (Test-DotfilesGreeting -Arguments @() -HostName 'ConsoleHost') { throw 'DOTFILES_FASTFETCH=0 must not greet' }
$env:DOTFILES_FASTFETCH = $null
$env:TMUX = 'socket,1,0'
if (Test-DotfilesGreeting -Arguments @() -HostName 'ConsoleHost') { throw 'tmux panes must not greet' }
$env:TMUX = $null
if ($env:DOTFILES_TEST_EXPECTED_FZF) {
    if ($env:FZF_DEFAULT_OPTS -ne $env:DOTFILES_TEST_EXPECTED_FZF) { throw "The local profile did not override FZF_DEFAULT_OPTS: $env:FZF_DEFAULT_OPTS" }
} elseif (-not $env:FZF_DEFAULT_OPTS.Contains("bg+:$env:DOTFILES_TEST_EXPECTED_BG")) {
    throw "FZF_DEFAULT_OPTS lacks the flavor's surface0 $env:DOTFILES_TEST_EXPECTED_BG: $env:FZF_DEFAULT_OPTS"
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
        # fzf's bg+ is surface0 of the recorded flavor, as scripts/theme.sh writes it.
        $flavorName = (Get-Content -LiteralPath (Join-Path $repository 'config/catppuccin/flavor') -First 1).Trim()
        $surface0 = $null
        foreach ($line in Get-Content -LiteralPath (Join-Path $repository 'config/catppuccin/palette.txt')) {
            if ($line -match "^$flavorName surface0 (#[0-9a-f]{6})$") { $surface0 = $Matches[1] }
        }
        Assert-True ([bool]$surface0) "The palette must list $flavorName surface0"
        $env:DOTFILES_TEST_EXPECTED_BG = $surface0
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
            foreach ($name in @('DOTFILES_TEST_HOME', 'DOTFILES_TEST_PROFILE', 'DOTFILES_TEST_BIN', 'DOTFILES_TEST_READLINE', 'DOTFILES_TEST_EXPECTED_FZF', 'DOTFILES_TEST_EXPECTED_BG')) {
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
        function Get-DotfilesNeovimVersion { param($Command) $neovimVersion }
        $neovimVersion = [version]'0.12.6'
        $neovimStartExitCode = 0
        $neovimCheck = @{ Lines = @('ok plugin catppuccin', 'ok parser bash', 'ok package lua-language-server'); ExitCode = 0 }
        $neovimStarts = 0
        $lazyFile = Join-Path $fixture.Directory 'AppData/Local/nvim-data/lazy/lazy.nvim/lua/lazy/init.lua'
        New-Item -ItemType Directory -Path (Split-Path -Parent $lazyFile) -Force | Out-Null
        [IO.File]::WriteAllText($lazyFile, '-- lazy')
        function Get-DotfilesNeovimCheck { param($Command) Assert-True ($Command -eq 'mock-command') 'The report comes from the discovered nvim'; [pscustomobject]$neovimCheck }
        function Invoke-DotfilesNativeCommand {
            param($Command, $Arguments, [switch]$Quiet)
            if ($Arguments[0] -eq '--headless') {
                $script:neovimStarts++
                Assert-True ($Command -eq 'mock-command' -and $Quiet -and $Arguments[2] -eq $DotfilesNeovimStartLua -and $Arguments[-1] -eq '+qa') 'The doctor starts Neovim headless, quietly, and checks v:errmsg'
                return $neovimStartExitCode
            }
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
        # theme.toml names a dark flavor and Latte for light mode; a Latte tree names it once.
        $yaziFlavors = @(Get-DotfilesYaziFlavors $fixture.Directory)
        Assert-True ($yaziFlavors.Count -in @(1, 2) -and $yaziFlavors[-1] -eq 'catppuccin-latte') "theme.toml names the flavors once each: $yaziFlavors"
        $latteFlavor = Get-DotfilesYaziFlavorFile $fixture.Directory $yaziFlavors[-1]
        foreach ($flavorFile in @($yaziFlavors | ForEach-Object { Get-DotfilesYaziFlavorFile $fixture.Directory $_ })) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $flavorFile) -Force | Out-Null
            [IO.File]::WriteAllText($flavorFile, '# flavor')
        }
        Invoke-DotfilesDoctor $repository $fixture.Directory
        foreach ($name in @('carapace', 'atuin', 'mise', 'delta', 'lazygit', 'lazydocker', 'yazi', 'rg', 'fd', 'dust', 'duf', 'procs', 'sd', 'xh', 'hyperfine', 'glow', 'tldr', 'gum', 'direnv')) {
            Assert-True ($report -contains "  [ok] $name") "The doctor must check the $name command"
        }
        Assert-True ($report -contains '  [ok] Node.js via mise') 'A runtime mise can locate passes'
        foreach ($flavor in $yaziFlavors) { Assert-True ($report -contains "  [ok] yazi flavor $flavor") "Installed yazi flavor $flavor passes" }
        Assert-True ($report -contains '  [ok] Neovim 0.12.6') 'A new enough Neovim passes'
        Assert-True ($report -contains '  [ok] lazy.nvim') 'An installed lazy.nvim passes'
        Assert-True ($report -contains '  [ok] Neovim starts without errors') 'A clean headless start passes'
        foreach ($line in @('  [ok] Neovim plugin catppuccin', '  [ok] Neovim parser bash', '  [ok] Neovim language server lua-language-server')) {
            Assert-True ($report -contains $line) "The report line is shown: $line"
        }
        # An old Neovim is one failure that names the upgrade and skips the start and the report.
        $neovimVersion = [version]'0.9.5'
        $report.Clear()
        Assert-Throws { Invoke-DotfilesDoctor $repository $fixture.Directory } '1 check\(s\) need attention'
        Assert-True (@($report | Where-Object { $_ -match '^  \[missing\] Neovim 0\.12\.0 or newer \(found: 0\.9\.5; winget upgrade' }).Count -eq 1) 'An old Neovim names the upgrade'
        Assert-True (-not ($report -contains '  [ok] Neovim starts without errors')) 'An old Neovim is not started'
        $neovimVersion = [version]'0.12.6'
        # Without lazy.nvim a start would clone it, so the doctor reports and stops.
        Remove-Item -LiteralPath $lazyFile
        $startsBefore = $script:neovimStarts
        $report.Clear()
        Assert-Throws { Invoke-DotfilesDoctor $repository $fixture.Directory } '1 check\(s\) need attention'
        Assert-True (@($report | Where-Object { $_ -match '^  \[missing\] lazy\.nvim \(.*rerun: scripts\\install_runtimes\.ps1\)$' }).Count -eq 1) 'A missing lazy.nvim names the stage that installs it'
        Assert-True ($script:neovimStarts -eq $startsBefore) 'Neovim is not started without lazy.nvim'
        [IO.File]::WriteAllText($lazyFile, '-- lazy')
        # Missing and stale items fail and name the stage; skipped parsers do not count.
        $neovimCheck = @{ Lines = @('ok plugin catppuccin', 'missing plugin gitsigns.nvim', 'stale plugin which-key.nvim', 'missing parser yaml', 'missing package marksman', 'skipped parser python (no C compiler or tree-sitter CLI; see docs/troubleshooting.md in the dotfiles repository)'); ExitCode = 1 }
        $report.Clear()
        Assert-Throws { Invoke-DotfilesDoctor $repository $fixture.Directory } '4 check\(s\) need attention'
        foreach ($line in @('  [missing] Neovim plugin gitsigns.nvim (rerun: scripts\install_runtimes.ps1)',
                '  [stale] Neovim plugin which-key.nvim is not at the commit lazy-lock.json pins (rerun: scripts\install_runtimes.ps1)',
                '  [missing] Neovim parser yaml (rerun: scripts\install_runtimes.ps1)',
                '  [missing] Neovim language server marksman (rerun: scripts\install_runtimes.ps1)',
                '  [skip] Neovim parser python (no C compiler or tree-sitter CLI; see docs/troubleshooting.md in the dotfiles repository)')) {
            Assert-True ($report -contains $line) "The report line is shown: $line"
        }
        $neovimCheck = @{ Lines = @(); ExitCode = 0 }
        $report.Clear()
        Assert-Throws { Invoke-DotfilesDoctor $repository $fixture.Directory } '1 check\(s\) need attention'
        Assert-True ($report -contains '  [missing] Neovim plugins, parsers and language servers (the check printed nothing)') 'An empty report is a failure'
        $neovimCheck = @{ Lines = @('ok plugin catppuccin'); ExitCode = 0 }
        $neovimStartExitCode = 3
        $report.Clear()
        Assert-Throws { Invoke-DotfilesDoctor $repository $fixture.Directory } '1 check\(s\) need attention'
        Assert-True ($report -contains '  [missing] Neovim headless start reported errors (exit code 3)') 'A failing start is reported'
        Assert-True (-not ($report -contains '  [ok] Neovim plugin catppuccin')) 'The report is not read after a failing start'
        $neovimStartExitCode = 0
        Invoke-DotfilesDoctor $repository $fixture.Directory
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
        # Without mise the runtime is missing too, and nothing is executed to find out;
        # without nvim the version is missing and no headless start is attempted.
        function Get-DotfilesCommandPath { param($Name) if ($Name -notin @('mise', 'nvim')) { 'mock-command' } }
        function Invoke-DotfilesNativeCommand { throw 'Unexpected native command' }
        function Get-DotfilesNeovimVersion { throw 'Unexpected version query' }
        function Get-DotfilesNeovimCheck { throw 'Unexpected report' }
        $report.Clear()
        Assert-Throws { Invoke-DotfilesDoctor $repository $fixture.Directory } '4 check\(s\) need attention'
        Assert-True (($report -contains '  [missing] mise') -and ($report -contains '  [missing] Node.js via mise (rerun: scripts\install_runtimes.ps1)')) 'Both mise and its runtime are reported'
        Assert-True (($report -contains '  [missing] nvim') -and (@($report | Where-Object { $_ -match '^  \[missing\] Neovim 0\.12\.0 or newer \(found: ;' }).Count -eq 1)) 'Both nvim and its version are reported'
    }

    Invoke-Test 'Neovim plugins, parsers and servers are installed headless as the report requires, and can be retried' {
        $fixture = New-Fixture
        # The mocked report resolves a line once the step that fixes it has succeeded,
        # as the real report would; StayBroken keeps every line as it is.
        $neovimState = @{ Version = [version]'0.12.6'; Report = @('ok plugin fzf-lua', 'missing plugin catppuccin', 'missing package marksman'); PluginsDone = $false; InstallDone = $false; StayBroken = $false
            PluginsExitCode = 1; InstallExitCode = 1; NodeDirectory = $null; Calls = [Collections.Generic.List[string]]::new(); InstallPath = $null }
        function Get-DotfilesCommandPath { param($Name) if ($Name -eq 'nvim') { 'mock-nvim' } }
        function Get-DotfilesNeovimVersion { param($Command) Assert-True ($Command -eq 'mock-nvim') 'The version comes from the discovered nvim'; $neovimState.Version }
        function Get-DotfilesNeovimCheck {
            param($Command)
            Assert-True ($Command -eq 'mock-nvim') 'The report comes from the discovered nvim'
            $lines = @(foreach ($line in $neovimState.Report) {
                if ($neovimState.StayBroken) { $line }
                elseif ($neovimState.PluginsDone -and $line -match '^(missing|stale) plugin (.*)$') { "ok plugin $($Matches[2])" }
                elseif ($neovimState.InstallDone -and $line -match '^missing (parser|package) (.*)$') { "ok $($Matches[1]) $($Matches[2])" }
                else { $line }
            })
            $code = 0
            if (@($lines | Where-Object { $_ -notmatch '^(ok|skipped) ' }).Count) { $code = 1 }
            [pscustomobject]@{ Lines = $lines; ExitCode = $code }
        }
        function Get-DotfilesMiseNodeDirectory { $neovimState.NodeDirectory }
        function Invoke-DotfilesNativeCommand {
            param($Command, $Arguments, [switch]$Quiet)
            Assert-True ($Command -eq 'mock-nvim' -and -not $Quiet -and $Arguments[0] -eq '--headless' -and $Arguments[-2] -eq '-c' -and $Arguments[-1] -eq 'cquit 1') 'Installation runs nvim headless, visibly, with cquit after the Lua'
            $neovimState.Calls.Add($Arguments[2])
            if ($Arguments[2] -eq $DotfilesNeovimPluginsLua) {
                if ($neovimState.PluginsExitCode -eq 0) { $neovimState.PluginsDone = $true }
                return $neovimState.PluginsExitCode
            }
            Assert-True ($Arguments[2] -eq $DotfilesNeovimInstallLua) "Unexpected nvim command: $Arguments"
            $neovimState.InstallPath = $env:PATH
            if ($neovimState.InstallExitCode -eq 0) { $neovimState.InstallDone = $true }
            return $neovimState.InstallExitCode
        }
        $savedPath = $env:PATH
        try {
            Assert-Throws { Install-DotfilesNeovim } 'Neovim plugin install failed \(exit code 1\)\. Rerun install.ps1 to retry'
            Assert-True (($neovimState.Calls -join "`n") -eq $DotfilesNeovimPluginsLua) "A failed plugin install stops before the parsers: $($neovimState.Calls -join ' | ')"
            $neovimState.PluginsExitCode = 0
            $neovimState.Calls.Clear()
            Assert-Throws { Install-DotfilesNeovim } 'parser and language server install failed \(exit code 1\)\. Rerun install.ps1 to retry'
            Assert-True ($neovimState.Calls.Count -eq 2 -and $neovimState.Calls[1] -eq $DotfilesNeovimInstallLua) "The parsers follow the plugins: $($neovimState.Calls -join ' | ')"
            Assert-True ($neovimState.InstallPath -eq $savedPath) 'Without a mise Node.js the install runs with the current PATH'
            Assert-True ($env:PATH -eq $savedPath) 'PATH is restored after a failure'
            # The retry installs only what is still missing: the plugins are in place.
            $neovimState.InstallExitCode = 0
            $neovimState.NodeDirectory = Join-Path $fixture.Directory 'node'
            $neovimState.Calls.Clear()
            Install-DotfilesNeovim
            Assert-True (($neovimState.Calls -join "`n") -eq $DotfilesNeovimInstallLua) "The retry runs the remaining install: $($neovimState.Calls -join ' | ')"
            Assert-True ($neovimState.InstallPath -eq "$($neovimState.NodeDirectory)$([IO.Path]::PathSeparator)$savedPath") "mise's Node.js leads PATH while Mason installs: $($neovimState.InstallPath)"
            Assert-True ($env:PATH -eq $savedPath) 'PATH is restored after success'
            $neovimState.Calls.Clear()
            Install-DotfilesNeovim
            Assert-True ($neovimState.Calls.Count -eq 0) 'A passing report installs nothing'
            # Only what the report names runs: a missing package alone, then a stale plugin alone.
            $neovimState.PluginsDone = $false; $neovimState.InstallDone = $false
            $neovimState.Report = @('ok plugin catppuccin', 'missing package marksman')
            Install-DotfilesNeovim
            Assert-True (($neovimState.Calls -join "`n") -eq $DotfilesNeovimInstallLua) "A missing package runs the package install alone: $($neovimState.Calls -join ' | ')"
            $neovimState.PluginsDone = $false; $neovimState.InstallDone = $false
            $neovimState.Calls.Clear()
            $neovimState.Report = @('stale plugin which-key.nvim', 'ok package marksman')
            Install-DotfilesNeovim
            Assert-True (($neovimState.Calls -join "`n") -eq $DotfilesNeovimPluginsLua) "A stale plugin runs the plugin install alone: $($neovimState.Calls -join ' | ')"
            # A report that still finds gaps after the installs is a failure that shows them.
            $neovimState.PluginsDone = $false; $neovimState.InstallDone = $false
            $neovimState.StayBroken = $true
            Assert-Throws { Install-DotfilesNeovim } 'not fully set up after installing: stale plugin which-key.nvim\. Rerun install.ps1'
            $neovimState.StayBroken = $false
            # An old or missing Neovim stops before the report.
            $neovimState.Calls.Clear()
            $neovimState.Version = [version]'0.11.6'
            Assert-Throws { Install-DotfilesNeovim } "Neovim 0.12.0 or newer is required \(found 0.11.6\).*winget upgrade --id Neovim.Neovim --exact"
            $neovimState.Version = $null
            Assert-Throws { Install-DotfilesNeovim } 'Neovim 0.12.0 or newer is required \(found \)'
            function Get-DotfilesCommandPath { param($Name) $null }
            Assert-Throws { Install-DotfilesNeovim } 'nvim is unavailable.*Reopen PowerShell and rerun install.ps1'
            Assert-True ($neovimState.Calls.Count -eq 0) 'Nothing runs without a usable Neovim'
        } finally { $env:PATH = $savedPath }
    }

    Invoke-Test 'Updating Neovim runs update() once the report passes, with mise Node.js first, and can be retried' {
        $state = @{ Calls = [Collections.Generic.List[string]]::new(); Exit = 1; Path = $null }
        function Get-DotfilesCommandPath { param($Name) if ($Name -eq 'nvim') { 'mock-nvim' } }
        function Get-DotfilesNeovimVersion { param($Command) [version]'0.12.6' }
        function Get-DotfilesNeovimCheck { param($Command) [pscustomobject]@{ Lines = @('ok plugin catppuccin', 'ok package marksman'); ExitCode = 0 } }
        function Get-DotfilesMiseNodeDirectory { 'node-directory' }
        function Invoke-DotfilesNativeCommand {
            param($Command, $Arguments, [switch]$Quiet)
            Assert-True ($Command -eq 'mock-nvim' -and $Arguments[0] -eq '--headless' -and $Arguments[-1] -eq 'cquit 1') 'The update runs nvim headless with cquit after the Lua'
            $state.Calls.Add($Arguments[2])
            $state.Path = $env:PATH
            return $state.Exit
        }
        $savedPath = $env:PATH
        try {
            Install-DotfilesNeovim
            Assert-True ($state.Calls.Count -eq 0) 'A plain install with a passing report runs nothing'
            Assert-Throws { Install-DotfilesNeovim -Update } 'parser and language server update failed \(exit code 1\)\. Rerun scripts\\update\.ps1'
            Assert-True (($state.Calls -join ',') -eq $DotfilesNeovimUpdateLua) "The update runs update(): $($state.Calls -join ',')"
            Assert-True ($state.Path -eq "node-directory$([IO.Path]::PathSeparator)$savedPath") 'mise Node.js leads PATH during the update'
            Assert-True ($env:PATH -eq $savedPath) 'PATH is restored after a failure'
            $state.Exit = 0
            Install-DotfilesNeovim -Update
            Assert-True ($state.Calls.Count -eq 2) 'The retry runs the update again'
        } finally { $env:PATH = $savedPath }
    }

    Invoke-Test 'Updating upgrades the mise runtimes from home and only the declared yazi flavors' {
        $fixture = New-Fixture
        $yaziConfig = Join-Path $fixture.Directory '.config/yazi'
        New-Item -ItemType Directory -Path $yaziConfig -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $repository 'config/yazi/theme.toml') -Destination (Join-Path $yaziConfig 'theme.toml')
        $flavors = @(Get-DotfilesYaziFlavors $fixture.Directory)
        foreach ($flavor in $flavors) {
            $flavorFile = Get-DotfilesYaziFlavorFile $fixture.Directory $flavor
            New-Item -ItemType Directory -Path (Split-Path -Parent $flavorFile) -Force | Out-Null
            [IO.File]::WriteAllText($flavorFile, '')
        }
        $packageFile = Join-Path $yaziConfig 'package.toml'
        $declared = @('[[plugin.deps]]', 'use = "someone/plugin"') + @(foreach ($flavor in $flavors) { '[[flavor.deps]]'; "use = `"yazi-rs/flavors:$flavor`"" })
        [IO.File]::WriteAllLines($packageFile, [string[]]$declared)
        $state = @{ Calls = [Collections.Generic.List[string]]::new(); Location = $null; YaziHome = $null; Fail = '' }
        function Get-DotfilesCommandPath { param($Name) "mock-$Name" }
        function Install-DotfilesNeovim { param([switch]$Update) $state.Calls.Add("neovim $([bool]$Update)") }
        function Invoke-DotfilesNativeCommand {
            param($Command, $Arguments, [switch]$Quiet)
            $line = "$Command $($Arguments -join ' ')"
            $state.Calls.Add($line)
            if ($line -eq 'mock-mise upgrade --yes') { $state.Location = (Get-Location).Path }
            if ($Command -eq 'mock-ya') { $state.YaziHome = $env:YAZI_CONFIG_HOME }
            if ($state.Fail -and $line -like $state.Fail) { return 9 }
            return 0
        }
        $savedLocation = (Get-Location).Path
        Invoke-DotfilesRuntimeInstall $fixture.Directory
        Assert-True (($state.Calls -join ',') -eq 'mock-mise install --yes,neovim False') "A plain install upgrades nothing: $($state.Calls -join ',')"
        $state.Calls.Clear()
        Invoke-DotfilesRuntimeInstall $fixture.Directory -Update
        $upgrade = 'mock-ya pkg upgrade ' + (@($flavors | ForEach-Object { "yazi-rs/flavors:$_" }) -join ' ')
        Assert-True (($state.Calls -join ',') -eq "mock-mise install --yes,mock-mise upgrade --yes,$upgrade,neovim True") "Updating upgrades the runtimes, the declared flavors and the Neovim tools: $($state.Calls -join ',')"
        Assert-True ($state.Location.TrimEnd('/', '\') -eq $fixture.Directory.TrimEnd('/', '\')) "mise upgrades from the home directory: $($state.Location)"
        Assert-True ((Get-Location).Path -eq $savedLocation) 'The location is restored'
        Assert-True ($state.YaziHome -eq $yaziConfig) 'ya upgrades the managed yazi directory'
        $state.Fail = 'mock-mise upgrade*'
        Assert-Throws { Invoke-DotfilesRuntimeInstall $fixture.Directory -Update } 'mise upgrade failed \(exit code 9\)\. Rerun scripts\\update\.ps1'
        Assert-True ((Get-Location).Path -eq $savedLocation) 'The location is restored after a failure'
        $state.Fail = 'mock-ya pkg upgrade*'
        Assert-Throws { Invoke-DotfilesRuntimeInstall $fixture.Directory -Update } 'ya pkg upgrade failed \(exit code 9\)\. Rerun scripts\\update\.ps1'
        $state.Fail = ''
        # A flavor package.toml does not list was put there by hand and stays.
        [IO.File]::WriteAllLines($packageFile, [string[]]@('[[flavor.deps]]', "use = `"yazi-rs/flavors:$($flavors[-1])`""))
        $state.Calls.Clear()
        Invoke-DotfilesRuntimeInstall $fixture.Directory -Update
        Assert-True ($state.Calls -contains "mock-ya pkg upgrade yazi-rs/flavors:$($flavors[-1])") "Only the listed flavor is upgraded: $($state.Calls -join ',')"
    }

    Invoke-Test 'The Lua handed to nvim survives native argument passing in this PowerShell edition' {
        # Windows PowerShell passes a native argument with inner double quotes
        # unescaped, which turned the Lua into a syntax error; the strings use
        # single quotes and a real child process proves they arrive intact.
        $fixture = New-Fixture
        $echo = Join-Path $fixture.Directory 'echo-argument.ps1'
        [IO.File]::WriteAllText($echo, 'param([string]$Argument) Write-Output $Argument')
        $shell = (Get-Process -Id $PID).Path
        foreach ($lua in @($DotfilesNeovimStartLua, $DotfilesNeovimCheckLua, $DotfilesNeovimPluginsLua, $DotfilesNeovimInstallLua, $DotfilesNeovimUpdateLua)) {
            Assert-True ($lua -notmatch '"') "No double quotes in the Lua: $lua"
            $received = [string](@(& $shell -NoProfile -NonInteractive -File $echo $lua) | Select-Object -First 1)
            Assert-True ($received -eq $lua) "The child received '$received', not '$lua'"
        }
    }

    Invoke-Test 'Neovim version and mise Node.js discovery read the first line of the command output' {
        $fixture = New-Fixture
        $shell = (Get-Process -Id $PID).Path
        # The version parser reads the first line of nvim --version and ignores development suffixes.
        $versionScript = Join-Path $fixture.Directory 'fake-nvim.ps1'
        [IO.File]::WriteAllText($versionScript, 'Write-Output "NVIM v0.12.0-dev-123+gabcdef"; Write-Output "Build type: Release"')
        Assert-True ($null -eq (Get-DotfilesNeovimVersion $shell)) 'A shell is not Neovim'
        function Invoke-Fake-Nvim { param($Switch) & $shell -NoProfile -NonInteractive -File $versionScript }
        Assert-True ((Get-DotfilesNeovimVersion 'Invoke-Fake-Nvim') -eq [version]'0.12.0') 'Development builds parse to their base version'
        # The mise Node.js directory is the parent of what `mise which node` prints, and absent without mise or node.
        function Get-DotfilesCommandPath { param($Name) if ($Name -eq 'mise') { 'Invoke-Fake-Mise' } }
        $nodeFile = Join-Path $fixture.Directory 'runtimes/node/bin/node'
        function Invoke-Fake-Mise { param($Which, $Tool) Assert-True ("$Which $Tool" -eq 'which node') 'mise is asked where node is'; $global:LASTEXITCODE = 0; Write-Output $nodeFile }
        Assert-True ((Get-DotfilesMiseNodeDirectory) -eq (Split-Path -Parent $nodeFile)) 'The node directory is the parent of what mise reports'
        function Invoke-Fake-Mise { param($Which, $Tool) $global:LASTEXITCODE = 1 }
        Assert-True ($null -eq (Get-DotfilesMiseNodeDirectory)) 'Without node there is no directory'
        function Get-DotfilesCommandPath { param($Name) $null }
        Assert-True ($null -eq (Get-DotfilesMiseNodeDirectory)) 'Without mise there is no directory'
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

    Invoke-Test 'Updating runs every stage with -Update and names update.ps1 in the rerun advice' {
        $events = [Collections.Generic.List[string]]::new()
        function Invoke-DotfilesPackageInstall { param($DotfilesDir, [switch]$Update) $events.Add("packages $([bool]$Update)") }
        function Invoke-DotfilesModuleInstall { param([switch]$Update) $events.Add("modules $([bool]$Update)") }
        function Invoke-DotfilesLink { param($DotfilesDir, $HomeDirectory) $events.Add('links') }
        function Invoke-DotfilesRuntimeInstall { param($HomeDirectory, [switch]$Update) $events.Add("runtimes $([bool]$Update)") }
        function Invoke-DotfilesDoctor { param($DotfilesDir, $HomeDirectory) $events.Add('verified') }
        function Write-Host { param($Object) if ([string]$Object -match '^(==>|Done\.)') { $events.Add([string]$Object) } }
        Invoke-DotfilesInstall $repository $testRoot -Update
        $expected = '==> Updating packages,packages True,==> Updating PowerShell modules,modules True,==> Linking dotfiles,links,==> Updating runtimes,runtimes True,==> Verifying setup,verified,Done. Everything is up to date and all setup checks passed.'
        Assert-True (($events -join ',') -eq $expected) "Every stage updates and verification precedes completion: $($events -join ',')"
        $events.Clear()
        Invoke-DotfilesInstall $repository $testRoot
        Assert-True (($events -join ',') -match '^==> Installing packages,packages False,.*runtimes False,') "A plain install passes no update: $($events -join ',')"
        function Invoke-DotfilesRuntimeInstall { param($HomeDirectory, [switch]$Update) throw 'simulated runtime failure' }
        Assert-Throws { Invoke-DotfilesInstall $repository $testRoot -Update } 'Updating runtimes failed: simulated runtime failure.*rerun: .*scripts[/\\]update\.ps1'
        Assert-Throws { Invoke-DotfilesInstall $repository $testRoot } 'Installing runtimes failed: simulated runtime failure.*rerun: .*install\.ps1'
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
