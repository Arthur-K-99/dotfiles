# Shared profile for PowerShell 7 and Windows PowerShell. Every tool and module
# is optional, so the file also loads in Windows PowerShell, whose module path
# and PSReadLine version differ. It stays ASCII (glyphs as code points) because
# Windows PowerShell reads scripts without a byte-order mark as ANSI.
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
    Set-Alias cat bat -Option AllScope -Force
}

# eza with the zsh aliases and the shared Catppuccin theme. Functions rather
# than aliases carry the extra arguments. cat and ls are built-in aliases on
# Windows (read-only and AllScope in Windows PowerShell), so replacing them
# needs both the AllScope option and Force.
if (Get-Command eza -ErrorAction SilentlyContinue) {
    $env:EZA_CONFIG_DIR = Join-Path $HOME ".config\eza"
    Set-Alias ls eza -Option AllScope -Force
    function la { eza -la --icons=always @args }
    function ll { eza -ll --icons=always @args }
    function tree { eza --tree --icons=always @args }
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

# Modules installed by install.ps1 for PowerShell 7. Terminal-Icons decorates
# Get-ChildItem output; posh-git completes git subcommands, branches and remotes.
Import-Module Terminal-Icons -ErrorAction SilentlyContinue
Import-Module posh-git -ErrorAction SilentlyContinue

# PSReadLine. The console host imports it before the profile runs, so this block
# is skipped in non-interactive shells such as `pwsh -Command`.
if (Get-Module PSReadLine) {
    $esc = [char]27
    # Catppuccin Macchiato. Foregrounds are hex strings; the two backgrounds
    # need the escape-sequence form.
    $readLineColors = @{
        Command            = '#8aadf4' # blue
        Comment            = '#6e738d' # overlay0
        ContinuationPrompt = '#8bd5ca' # teal
        Default            = '#cad3f5' # text
        Emphasis           = '#ed8796' # red
        Error              = '#ed8796' # red
        Keyword            = '#c6a0f6' # mauve
        Member             = '#f4dbd6' # rosewater
        Number             = '#f5a97f' # peach
        Operator           = '#91d7e3' # sky
        Parameter          = '#f5bde6' # pink
        Selection          = "$esc[48;2;54;58;79m" # surface0 background
        String             = '#a6da95' # green
        Type               = '#eed49f' # yellow
        Variable           = '#b7bdf8' # lavender
    }
    $readLineOptions = @{
        BellStyle                     = 'None'
        HistorySearchCursorMovesToEnd = $true
        Colors                        = $readLineColors
    }
    # Predictive IntelliSense with the list view needs PSReadLine 2.2+, which
    # Windows PowerShell does not ship. CompletionPredictor (PowerShell 7.2+)
    # adds suggestions from tab completion to those from history.
    $predictionOptions = @{}
    if ((Get-Command Set-PSReadLineOption).Parameters.ContainsKey('PredictionViewStyle')) {
        $readLineColors['InlinePrediction'] = '#6e738d' # overlay0
        $readLineColors['ListPrediction'] = '#c6a0f6' # mauve
        $readLineColors['ListPredictionSelected'] = "$esc[48;2;54;58;79m" # surface0 background
        $predictionOptions['PredictionSource'] = 'History'
        $predictionOptions['PredictionViewStyle'] = 'ListView'
        Import-Module CompletionPredictor -ErrorAction SilentlyContinue
        if (Get-Module CompletionPredictor) {
            $predictionOptions['PredictionSource'] = 'HistoryAndPlugin'
        }
    }
    Set-PSReadLineOption @readLineOptions
    # PSReadLine refuses predictions when its output is redirected or lacks
    # virtual terminal support; the rest of the configuration must survive that.
    if ($predictionOptions.Count) {
        try { Set-PSReadLineOption @predictionOptions } catch { }
    }
    # Keys shared with zsh: Tab opens a completion menu, Up and Down search
    # history by prefix, Ctrl+D exits an empty line, Ctrl+W deletes a word.
    Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
    Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
    Set-PSReadLineKeyHandler -Key Ctrl+d -Function DeleteCharOrExit
    Set-PSReadLineKeyHandler -Key Ctrl+w -Function BackwardKillWord
    # PSFzf: Ctrl+T inserts files and Ctrl+R searches history, as in zsh.
    if (Get-Command fzf -ErrorAction SilentlyContinue) {
        Import-Module PSFzf -ErrorAction SilentlyContinue
        if (Get-Module PSFzf) {
            Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r'
        }
    }
}

# Keep machine-specific or private configuration outside the repository.
$localProfile = Join-Path $HOME ".powershell.local.ps1"
if (Test-Path -LiteralPath $localProfile) {
    . $localProfile
}
