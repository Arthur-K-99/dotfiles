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

# mise puts the runtimes from ~/.config/mise/config.toml on PATH and refreshes
# them on directory changes. It runs after oh-my-posh so its prompt hook wraps
# the prompt instead of being replaced by it; that hook is what refreshes PATH
# in Windows PowerShell, whose lack of a directory-change event mise would
# otherwise warn about on every start.
if (Get-Command mise -ErrorAction SilentlyContinue) {
    if ($PSVersionTable.PSVersion.Major -lt 7) { $env:MISE_PWSH_CHPWD_WARNING = '0' }
    (& mise activate pwsh) | Out-String | Invoke-Expression
}

# direnv loads and unloads .envrc files on directory changes (direnv 2.33+).
if (Get-Command direnv -ErrorAction SilentlyContinue) {
    Invoke-Expression "$(direnv hook pwsh)"
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

# atuin, lazygit and yazi look for their configuration elsewhere on Windows, so
# they are pointed at the managed files under ~/.config, as on the Unix shells.
$env:ATUIN_CONFIG_DIR = Join-Path $HOME ".config\atuin"
$env:LG_CONFIG_FILE = Join-Path $HOME ".config\lazygit\config.yml"
$env:YAZI_CONFIG_HOME = Join-Path $HOME ".config\yazi"
# yazi detects file types with file(1), which Git for Windows ships.
if ($env:ProgramFiles) {
    $fileCommand = Join-Path $env:ProgramFiles "Git\usr\bin\file.exe"
    if (Test-Path -LiteralPath $fileCommand) { $env:YAZI_FILE_ONE = $fileCommand }
}
# y opens yazi and leaves the shell in the directory yazi exited from: the
# PowerShell recipe from the yazi quick-start.
if (Get-Command yazi -ErrorAction SilentlyContinue) {
    function y {
        $tmp = (New-TemporaryFile).FullName
        yazi @args --cwd-file="$tmp"
        $cwd = Get-Content -Path $tmp -Encoding UTF8
        if ($cwd -and $cwd -ne $PWD.Path -and (Test-Path -LiteralPath $cwd -PathType Container)) {
            Set-Location -LiteralPath (Resolve-Path -LiteralPath $cwd).Path
        }
        Remove-Item -Path $tmp
    }
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
    # carapace completes over a thousand commands through the Tab menu above.
    if (Get-Command carapace -ErrorAction SilentlyContinue) {
        carapace _carapace | Out-String | Invoke-Expression
    }
    # atuin takes over Ctrl+R with searchable, synced history. Up and Down stay
    # with PSReadLine so the prediction list and prefix search keep working.
    # The PowerShell integration needs atuin 18.11+; older builds are skipped.
    $atuinActive = $false
    if (Get-Command atuin -ErrorAction SilentlyContinue) {
        try {
            $atuinInit = atuin init powershell --disable-up-arrow | Out-String
            if ($LASTEXITCODE -eq 0) {
                Invoke-Expression $atuinInit
                $atuinActive = $true
            }
        } catch { }
    }
    # PSFzf: Ctrl+T inserts files and, unless atuin has it, Ctrl+R searches history.
    if (Get-Command fzf -ErrorAction SilentlyContinue) {
        Import-Module PSFzf -ErrorAction SilentlyContinue
        if (Get-Module PSFzf) {
            $fzfOptions = @{ PSReadlineChordProvider = 'Ctrl+t' }
            if (-not $atuinActive) { $fzfOptions['PSReadlineChordReverseHistory'] = 'Ctrl+r' }
            Set-PsFzfOption @fzfOptions
        }
    }
}

# Keep machine-specific or private configuration outside the repository.
$localProfile = Join-Path $HOME ".powershell.local.ps1"
if (Test-Path -LiteralPath $localProfile) {
    . $localProfile
}
