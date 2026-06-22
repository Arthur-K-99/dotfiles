$dotfilesDir = Split-Path -Parent $PSScriptRoot

function Link-File {
    param($src, $dst)
    if (Test-Path $dst -PathType SymbolicLink) {
        Write-Host "  already linked: $dst"
        return
    }
    if (Test-Path $dst) {
        Write-Host "  backing up $dst -> $dst.bak"
        Move-Item $dst "$dst.bak"
    }
    $parent = Split-Path -Parent $dst
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    try {
        New-Item -ItemType SymbolicLink -Path $dst -Target $src -ErrorAction Stop | Out-Null
        Write-Host "  linked: $dst"
    } catch {
        # Fallback to copy if symlinks aren't available (no Developer Mode/admin)
        Copy-Item $src $dst
        Write-Host "  copied (no symlink permission): $dst"
    }
}

Write-Host "Linking dotfiles..."
Link-File "$dotfilesDir\home\.zshrc"       "$env:USERPROFILE\.zshrc"
Link-File "$dotfilesDir\home\.tmux.conf"   "$env:USERPROFILE\.tmux.conf"
Link-File "$dotfilesDir\config\eza"        "$env:USERPROFILE\.config\eza"
