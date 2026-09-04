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

    Invoke-Test 'Doctor validates both editions, copied contents and fonts' {
        $fixture = New-Fixture
        function Get-DotfilesProfilePaths {
            [ordered]@{ PowerShell = Join-Path $fixture.Directory 'modern/profile.ps1'; WindowsPowerShell = Join-Path $fixture.Directory 'legacy/profile.ps1' }
        }
        function Get-DotfilesCommandPath { param($Name) 'mock-command' }
        function Test-DotfilesNerdFont { $fontPresent }
        $fontPresent = $true
        $files = @(Get-DotfilesManagedFiles $repository $fixture.Directory)
        foreach ($file in $files) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $file.Destination) -Force | Out-Null
            Copy-Item -LiteralPath $file.Source -Destination $file.Destination
        }
        Invoke-DotfilesDoctor $repository $fixture.Directory
        foreach ($file in $files) {
            [IO.File]::WriteAllText($file.Destination, 'stale configuration')
            Assert-Throws { Invoke-DotfilesDoctor $repository $fixture.Directory } 'check\(s\) need attention'
            Copy-Item -LiteralPath $file.Source -Destination $file.Destination -Force
        }
        $fontPresent = $false
        Assert-Throws { Invoke-DotfilesDoctor $repository $fixture.Directory } 'check\(s\) need attention'
    }

    Invoke-Test 'Setup verifies before its completion message and propagates verification failures' {
        $events = [Collections.Generic.List[string]]::new()
        function Invoke-DotfilesPackageInstall { param($DotfilesDir) $events.Add('packages') }
        function Invoke-DotfilesLink { param($DotfilesDir, $HomeDirectory) $events.Add('links') }
        function Invoke-DotfilesDoctor { param($DotfilesDir, $HomeDirectory) $events.Add('verified') }
        function Write-Host { param($Object) if ([string]$Object -match '^Done\.') { $events.Add('done') } }
        Invoke-DotfilesInstall $repository $testRoot
        Assert-True (($events -join ',') -eq 'packages,links,verified,done') 'Completion must follow successful verification'
        $events.Clear()
        function Invoke-DotfilesDoctor { param($DotfilesDir, $HomeDirectory) throw 'simulated verification failure' }
        Assert-Throws { Invoke-DotfilesInstall $repository $testRoot } 'Verifying setup failed: simulated verification failure.*Completed setup remains in place.*rerun:.*install.ps1'
        Assert-True (-not $events.Contains('done')) 'Failed verification must suppress completion'
        $events.Clear()
        function Invoke-DotfilesDoctor { param($DotfilesDir, $HomeDirectory) $events.Add('verified') }
        Invoke-DotfilesInstall $repository $testRoot
        Assert-True (($events -join ',') -eq 'packages,links,verified,done') 'Retry should complete after verification succeeds'
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
