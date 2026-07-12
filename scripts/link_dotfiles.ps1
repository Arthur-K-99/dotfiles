$ErrorActionPreference = "Stop"
$dotfilesDir = Split-Path -Parent $PSScriptRoot

function Move-ToBackup {
    param([string]$Path)

    $timestamp = Get-Date -Format "yyyyMMddHHmmss"
    $backup = "$Path.bak.$timestamp"
    $suffix = 1
    while (Test-Path -LiteralPath $backup) {
        $backup = "$Path.bak.$timestamp.$suffix"
        $suffix++
    }

    Write-Host "  backing up $Path -> $backup"
    Move-Item -LiteralPath $Path -Destination $backup
}

function Link-File {
    param([string]$src, [string]$dst)

    $existing = Get-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
    if ($existing -and $existing.LinkType -eq "SymbolicLink") {
        $linkTarget = [string]$existing.Target
        if ([System.IO.Path]::IsPathRooted($linkTarget)) {
            $resolvedTarget = [System.IO.Path]::GetFullPath($linkTarget)
        } else {
            $resolvedTarget = [System.IO.Path]::GetFullPath((Join-Path $existing.DirectoryName $linkTarget))
        }
        $resolvedSource = (Resolve-Path -LiteralPath $src).Path
        $resolvedTargetItem = Resolve-Path -LiteralPath $resolvedTarget -ErrorAction SilentlyContinue
        if ($resolvedTargetItem -and [string]::Equals($resolvedTargetItem.Path, $resolvedSource, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Host "  already linked: $dst"
            return
        }
    }

    if ($existing -and -not $existing.PSIsContainer -and (Test-Path -LiteralPath $src -PathType Leaf)) {
        $sourceHash = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash
        $destinationHash = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash
        if ($sourceHash -eq $destinationHash) {
            Write-Host "  already copied: $dst"
            return
        }
    }

    if ($existing) {
        Move-ToBackup $dst
    }

    $parent = Split-Path -Parent $dst
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    try {
        New-Item -ItemType SymbolicLink -Path $dst -Target $src | Out-Null
        Write-Host "  linked: $dst"
    } catch {
        # Fallback to copy if symlinks aren't available (no Developer Mode/admin)
        if (Test-Path -LiteralPath $src -PathType Container) {
            Copy-Item -LiteralPath $src -Destination $dst -Recurse
        } else {
            Copy-Item -LiteralPath $src -Destination $dst
        }
        Write-Host "  copied (no symlink permission): $dst"
    }
}

Write-Host "Linking native Windows configuration..."
$powerShellProfile = Join-Path $dotfilesDir "config/powershell/profile.ps1"
$promptConfig = Join-Path $dotfilesDir "config/oh-my-posh/config.omp.json"
Link-File $powerShellProfile (Join-Path $HOME "Documents/PowerShell/profile.ps1")
Link-File $powerShellProfile (Join-Path $HOME "Documents/WindowsPowerShell/profile.ps1")
Link-File $promptConfig (Join-Path $HOME ".config/oh-my-posh/config.omp.json")
