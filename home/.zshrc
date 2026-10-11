# Variables
export XDG_CONFIG_HOME="$HOME/.config"
export EZA_CONFIG_DIR="$HOME/.config/eza"

# Discover Homebrew before loading plugins and keep user-installed tools first.
if [[ -x "/opt/homebrew/bin/brew" ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x "/usr/local/bin/brew" ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
fi
typeset -U path PATH
path=("$HOME/.local/bin" $path)

# Tools that print an init script cost 20-50 ms each per shell, and the output
# changes only when the binary does. dotfiles_cached_init <name> <tool> <cmd...>
# runs the command once, keeps the result in the cache and re-sources it until
# the tool is upgraded. Nothing happens when the tool is absent.
# The first line of a cache file records the binary's resolved path, size and
# modification time plus the command, so upgrades (Homebrew keeps versions in
# the path, packages change size) and changed arguments regenerate it.
dotfiles_cached_init() {
    local name="$1" tool="$2"
    local cache="${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles/$name.zsh"
    local binary key first_line tmp
    local -A stat_fields
    shift 2
    (( $+commands[$tool] )) || return 1
    binary="${commands[$tool]:A}"
    zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
    zstat -H stat_fields "$binary" 2>/dev/null || return 1
    key="# dotfiles-cache $binary $stat_fields[size] $stat_fields[mtime] $*"
    { IFS= read -r first_line < "$cache"; } 2>/dev/null
    if [[ "$first_line" != "$key" ]]; then
        mkdir -p "${cache:h}" || return 1
        tmp="$(mktemp "$cache.XXXXXX")" || return 1
        if ! { print -r -- "$key"; "$@"; } > "$tmp"; then
            rm -f "$tmp"
            return 1
        fi
        mv -f "$tmp" "$cache" || return 1
    fi
    source "$cache"
}

# fzf. One Catppuccin Macchiato palette and layout for every fzf window,
# including fzf-tab. Previews belong to specific keybindings rather than to an
# alias of fzf itself, so pipelines such as `history | fzf` stay clean.
export FZF_DEFAULT_OPTS="\
 --height=40% --layout=reverse --border=rounded --info=inline\
 --prompt='❯ ' --pointer='▶' --marker='✓'\
 --color=bg+:#363a4f,bg:#24273a,spinner:#f4dbd6,hl:#ed8796\
 --color=fg:#cad3f5,header:#ed8796,info:#c6a0f6,pointer:#f4dbd6\
 --color=marker:#b7bdf8,fg+:#cad3f5,prompt:#c6a0f6,hl+:#ed8796\
 --color=border:#363a4f,label:#cad3f5"
# Ctrl-T (files) and Alt-C (directories) previews. Ctrl-T also lists
# directories, so the file preview branches on the entry type. Debian and
# Ubuntu install bat as batcat. Ctrl-/ hides the preview pane.
dotfiles_bat="$(command -v bat || command -v batcat)"
export FZF_CTRL_T_OPTS="\
 --preview '[ -d {} ] && LS_COLORS= eza --tree --level=1 --color=always --icons=always {} || ${dotfiles_bat:-cat} --color=always --style=numbers --line-range=:500 {}'\
 --preview-window=right,60%,border-left --bind=ctrl-/:toggle-preview"
export FZF_ALT_C_OPTS="\
 --preview 'LS_COLORS= eza --tree --level=2 --color=always --icons=always {}'\
 --preview-window=right,60%,border-left"
unset dotfiles_bat
# fd feeds fzf: it honours .gitignore and skips .git, so Ctrl-T and Alt-C
# list what matters. Debian installs it as fdfind; the alias restores the name.
if (( $+commands[fd] )); then
    dotfiles_fd=fd
elif (( $+commands[fdfind] )); then
    dotfiles_fd=fdfind
    alias fd='fdfind'
fi
if [[ -n ${dotfiles_fd:-} ]]; then
    export FZF_DEFAULT_COMMAND="$dotfiles_fd --type f --hidden --follow --exclude .git"
    export FZF_CTRL_T_COMMAND="$dotfiles_fd --hidden --follow --exclude .git"
    export FZF_ALT_C_COMMAND="$dotfiles_fd --type d --hidden --follow --exclude .git"
fi
unset dotfiles_fd

# fzf keybindings (Ctrl-T files, Ctrl-R history, Alt-C directories) and
# completion. This runs before the plugins so fzf-tab wraps fzf's own Tab
# widget instead of being replaced by it. `fzf --zsh` needs fzf 0.48+ and is
# cached like the other init scripts; older distribution packages install the
# scripts as files, and a git installation provides ~/.fzf.zsh.
if dotfiles_cached_init fzf fzf fzf --zsh 2>/dev/null; then
    :
elif [[ -r /usr/share/doc/fzf/examples/key-bindings.zsh ]]; then
    source /usr/share/doc/fzf/examples/key-bindings.zsh
    [[ -r /usr/share/doc/fzf/examples/completion.zsh ]] && source /usr/share/doc/fzf/examples/completion.zsh
elif [[ -r ~/.fzf.zsh ]]; then
    source ~/.fzf.zsh
fi

# Zinit installation
ZINIT_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/zinit/zinit.git"
if [[ -r "$ZINIT_HOME/zinit.zsh" ]]; then
    source "$ZINIT_HOME/zinit.zsh"
fi

# Plugins. zsh-abbr expands abbreviations from the tracked file on Space and
# Enter; you-should-use reminds about aliases after the command has run.
export ABBR_USER_ABBREVIATIONS_FILE="$XDG_CONFIG_HOME/zsh-abbr/user-abbreviations"
export YSU_MESSAGE_POSITION="after"
if (( $+functions[zinit] )); then
    zinit light zsh-users/zsh-syntax-highlighting
    zinit light zsh-users/zsh-completions
    zinit light zsh-users/zsh-autosuggestions
    zinit light Aloxaf/fzf-tab
    zinit light olets/zsh-abbr
    zinit light MichaelAquilina/zsh-you-should-use
fi

# mise manages runtimes (Node.js LTS from config/mise/config.toml, more on
# request) and replaces nvm. The shims directory goes on PATH directly: each
# shim resolves the version for the current project when it runs, which is
# what `mise activate --shims` prints, without running mise at startup or the
# 20 ms hook on every prompt that `mise activate` installs. Project [env]
# sections are not applied this way; direnv covers that need.
dotfiles_mise_shims="${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}/shims"
[[ -d "$dotfiles_mise_shims" ]] && path=("$dotfiles_mise_shims" $path)
unset dotfiles_mise_shims

# oh-my-posh
if (( $+commands[oh-my-posh] )); then
    eval "$(oh-my-posh init zsh --config "$XDG_CONFIG_HOME/oh-my-posh/config.omp.json")"
fi

# Load completions
autoload -Uz compinit && compinit
(( $+functions[zinit] )) && zinit cdreplay -q
# carapace: one completion engine for over a thousand commands. Its script
# calls compdef, so it runs after compinit; fzf-tab still draws the menu.
dotfiles_cached_init carapace carapace carapace _carapace zsh

# Keybindings
bindkey -e
bindkey '^p' history-search-backward
bindkey '^n' history-search-forward
bindkey '^[w' kill-region
# Ctrl-X Ctrl-E edits the current command line in $EDITOR.
autoload -Uz edit-command-line
zle -N edit-command-line
bindkey '^x^e' edit-command-line
# atuin: searchable, synced history on Ctrl-R. It is initialised after fzf,
# so its Ctrl-R binding wins; fzf keeps Ctrl-T and Alt-C. Up arrow stays zsh's.
dotfiles_cached_init atuin atuin atuin init zsh --disable-up-arrow

# History
HISTSIZE=100000
HISTFILE=~/.zsh_history
SAVEHIST=$HISTSIZE
HISTDUP=erase
setopt appendhistory
setopt sharehistory
setopt extended_history
setopt hist_ignore_space
setopt hist_ignore_all_dups
setopt hist_save_no_dups
setopt hist_ignore_dups
setopt hist_find_no_dups

# Navigation
setopt auto_cd
setopt interactive_comments

# Colors. vivid generates a Catppuccin LS_COLORS for completion menus, fd and
# everything else that reads it. eza has its own theme.yml, which LS_COLORS
# would override, so the wrapper blanks the variable for eza alone. Without
# vivid, a small default uses the terminal's own palette.
# vivid 0.9 added the Catppuccin themes; Debian 12 still ships 0.8.
if (( $+commands[vivid] )) && dotfiles_ls_colors="$(vivid generate catppuccin-macchiato 2>/dev/null)" && [[ -n "$dotfiles_ls_colors" ]]; then
    export LS_COLORS="$dotfiles_ls_colors"
else
    export LS_COLORS="${LS_COLORS:-di=1;34:ln=36:so=35:pi=33:ex=1;32:bd=1;33:cd=1;33:su=1;31:sg=1;31:tw=1;34:ow=1;34}"
fi
unset dotfiles_ls_colors
eza() { LS_COLORS= command eza "$@"; }

# Completion styling
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' menu no
zstyle ':completion:*:descriptions' format '[%d]'
zstyle ':fzf-tab:*' use-fzf-default-opts yes
zstyle ':fzf-tab:*' switch-group '<' '>'
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'LS_COLORS= eza -1 --color=always --icons=always $realpath'
zstyle ':fzf-tab:complete:__zoxide_z:*' fzf-preview 'LS_COLORS= eza -1 --color=always --icons=always $realpath'

# Aliases
if command -v bat &> /dev/null; then
    alias cat='bat'
elif command -v batcat &> /dev/null; then
    alias cat='batcat'
fi
alias ls='eza'
alias la='eza -la --icons=always'
alias ll='eza -ll --icons=always'
alias tree='eza --tree --icons=always'
alias vim='nvim'
alias c='clear'

# Shell integrations
dotfiles_cached_init zoxide zoxide zoxide init --cmd cd zsh
dotfiles_cached_init direnv direnv direnv hook zsh
# y opens yazi and changes to the directory it was quit in.
y() {
    local tmp cwd
    tmp="$(mktemp -t "yazi-cwd.XXXXXX")" || return
    command yazi "$@" --cwd-file="$tmp"
    if cwd="$(<"$tmp")" && [[ -n "$cwd" && "$cwd" != "$PWD" && -d "$cwd" ]]; then
        builtin cd -- "$cwd"
    fi
    command rm -f -- "$tmp"
}

# Machine-specific overrides (not tracked in repo)
if [[ -f "$HOME/.zshrc.local" ]]; then
    source "$HOME/.zshrc.local"
fi

# fastfetch greets interactive shells with the machine summary. tmux opens a
# shell for every pane, so it stays quiet there, and DOTFILES_FASTFETCH=0 in
# ~/.zshrc.local turns it off on a machine. The config is the linked
# ~/.config/fastfetch/config.jsonc, named so Windows reads the same file.
if [[ -o interactive && -z "${TMUX:-}" && "${DOTFILES_FASTFETCH:-1}" != 0 ]] && (( $+commands[fastfetch] )); then
    fastfetch --config "$XDG_CONFIG_HOME/fastfetch/config.jsonc"
fi
