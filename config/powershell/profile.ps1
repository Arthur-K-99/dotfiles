# Shared profile for PowerShell 7 and Windows PowerShell.
$localBin = Join-Path $HOME ".local\bin"
if (Test-Path -LiteralPath $localBin) {
    $env:PATH = "$localBin$([IO.Path]::PathSeparator)$env:PATH"
}

$promptConfig = Join-Path $HOME ".config\oh-my-posh\config.omp.json"
if ((Get-Command oh-my-posh -ErrorAction SilentlyContinue) -and (Test-Path $promptConfig)) {
    oh-my-posh init pwsh --config $promptConfig | Invoke-Expression
}

if (Get-Command zoxide -ErrorAction SilentlyContinue) {
    zoxide init powershell --cmd cd | Out-String | Invoke-Expression
}

if (Get-Command nvim -ErrorAction SilentlyContinue) {
    Set-Alias vim nvim
}

# bat reads the same configuration file as the Unix shells.
$batConfig = Join-Path $HOME ".config\bat\config"
if (Test-Path -LiteralPath $batConfig) {
    $env:BAT_CONFIG_PATH = $batConfig
}
if (Get-Command bat -ErrorAction SilentlyContinue) {
    Set-Alias cat bat -Option AllScope
}

# fzf: the same Catppuccin Macchiato colors and layout as the Unix shells.
# Glyphs are code points so Windows PowerShell reads this file correctly.
$env:FZF_DEFAULT_OPTS = @(
    '--height=40% --layout=reverse --border=rounded --info=inline'
    "--prompt='$([char]0x276F) ' --pointer='$([char]0x25B6)' --marker='$([char]0x2713)'"
    '--color=bg+:#363a4f,bg:#24273a,spinner:#f4dbd6,hl:#ed8796'
    '--color=fg:#cad3f5,header:#ed8796,info:#c6a0f6,pointer:#f4dbd6'
    '--color=marker:#b7bdf8,fg+:#cad3f5,prompt:#c6a0f6,hl+:#ed8796'
    '--color=border:#363a4f,label:#cad3f5'
) -join ' '

# Keep machine-specific or private configuration outside the repository.
$localProfile = Join-Path $HOME ".powershell.local.ps1"
if (Test-Path -LiteralPath $localProfile) {
    . $localProfile
}
