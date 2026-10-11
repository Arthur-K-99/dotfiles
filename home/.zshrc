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
 --preview '[ -d {} ] && eza --tree --level=1 --color=always --icons=always {} || ${dotfiles_bat:-cat} --color=always --style=numbers --line-range=:500 {}'\
 --preview-window=right,60%,border-left --bind=ctrl-/:toggle-preview"
export FZF_ALT_C_OPTS="\
 --preview 'eza --tree --level=2 --color=always --icons=always {}'\
 --preview-window=right,60%,border-left"
unset dotfiles_bat

# fzf keybindings (Ctrl-T files, Ctrl-R history, Alt-C directories) and
# completion. This runs before the plugins so fzf-tab wraps fzf's own Tab
# widget instead of being replaced by it. `fzf --zsh` needs fzf 0.48+; older
# distribution packages install the scripts as files, and a git installation
# provides ~/.fzf.zsh.
if (( $+commands[fzf] )) && fzf --zsh &>/dev/null; then
    source <(fzf --zsh)
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

# Plugins
if (( $+functions[zinit] )); then
    zinit light zsh-users/zsh-syntax-highlighting
    zinit light zsh-users/zsh-completions
    zinit light zsh-users/zsh-autosuggestions
    zinit light Aloxaf/fzf-tab
fi

# nvm (Node.js and npm). Sourcing nvm.sh activates the default version on every
# shell start, which costs about 300 ms. Instead, follow nvm's alias files to the
# default version, put its bin directory on PATH, and load nvm on first use.
# When the chain cannot be resolved (for example "default -> 24"), nvm loads
# immediately so behaviour stays correct.
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
dotfiles_nvm_default_bin() {
    local alias_name="default" target
    repeat 8; do
        [[ -f "$NVM_DIR/alias/$alias_name" ]] || break
        target="$(<"$NVM_DIR/alias/$alias_name")"
        [[ -n "$target" ]] || return 1
        alias_name="$target"
    done
    [[ -d "$NVM_DIR/versions/node/$alias_name/bin" ]] || return 1
    REPLY="$NVM_DIR/versions/node/$alias_name/bin"
}
if [[ -s "$NVM_DIR/nvm.sh" ]]; then
    if dotfiles_nvm_default_bin; then
        path=("$REPLY" $path)
        nvm() {
            unfunction nvm
            source "$NVM_DIR/nvm.sh"
            [[ -s "$NVM_DIR/bash_completion" ]] && source "$NVM_DIR/bash_completion"
            nvm "$@"
        }
    else
        source "$NVM_DIR/nvm.sh"
        [[ -s "$NVM_DIR/bash_completion" ]] && source "$NVM_DIR/bash_completion"
    fi
fi

# oh-my-posh
if (( $+commands[oh-my-posh] )); then
    eval "$(oh-my-posh init zsh --config "$XDG_CONFIG_HOME/oh-my-posh/config.omp.json")"
fi

# Load completions
autoload -Uz compinit && compinit
(( $+functions[zinit] )) && zinit cdreplay -q

# Keybindings
bindkey -e
bindkey '^p' history-search-backward
bindkey '^n' history-search-forward
bindkey '^[w' kill-region
# Ctrl-X Ctrl-E edits the current command line in $EDITOR.
autoload -Uz edit-command-line
zle -N edit-command-line
bindkey '^x^e' edit-command-line

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

# Colors. macOS sets no LS_COLORS, which leaves completion menus uncolored. This
# default uses the terminal's own palette, so it follows the terminal theme.
export LS_COLORS="${LS_COLORS:-di=1;34:ln=36:so=35:pi=33:ex=1;32:bd=1;33:cd=1;33:su=1;31:sg=1;31:tw=1;34:ow=1;34}"

# Completion styling
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' menu no
zstyle ':completion:*:descriptions' format '[%d]'
zstyle ':fzf-tab:*' use-fzf-default-opts yes
zstyle ':fzf-tab:*' switch-group '<' '>'
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'eza -1 --color=always --icons=always $realpath'
zstyle ':fzf-tab:complete:__zoxide_z:*' fzf-preview 'eza -1 --color=always --icons=always $realpath'

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
command -v zoxide &>/dev/null && eval "$(zoxide init --cmd cd zsh)"

# Machine-specific overrides (not tracked in repo)
if [[ -f "$HOME/.zshrc.local" ]]; then
    source "$HOME/.zshrc.local"
fi
