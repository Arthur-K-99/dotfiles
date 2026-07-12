# Variables
export XDG_CONFIG_HOME="$HOME/.config"
export EZA_CONFIG_DIR="$HOME/.config/eza"
typeset -U path PATH
path=("$HOME/.local/bin" $path)

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

# For macOS
if [[ -x "/opt/homebrew/bin/brew" ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# nvm (Node.js and npm)
export NVM_DIR="$HOME/.nvm"
[[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"
[[ -s "$NVM_DIR/bash_completion" ]] && source "$NVM_DIR/bash_completion"

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

# History
HISTSIZE=5000
HISTFILE=~/.zsh_history
SAVEHIST=$HISTSIZE
HISTDUP=erase
setopt appendhistory
setopt sharehistory
setopt hist_ignore_space
setopt hist_ignore_all_dups
setopt hist_save_no_dups
setopt hist_ignore_dups
setopt hist_find_no_dups

# Completion styling
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' menu no
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'ls --color $realpath'
zstyle ':fzf-tab:complete:__zoxide_z:*' fzf-preview 'ls --color $realpath'

# Aliases
if command -v bat &> /dev/null; then
    alias cat='bat'
    alias fzf='fzf --preview "bat --color=always --style=numbers --line-range=:500 {}"'
elif command -v batcat &> /dev/null; then
    alias cat='batcat'
    alias fzf='fzf --preview "batcat --color=always --style=numbers --line-range=:500 {}"'
fi
alias ls='eza'
alias la='eza -la --icons=always'
alias ll='eza -ll --icons=always'
alias tree='eza --tree --icons=always'
alias vim='nvim'
alias c='clear'

# Shell integrations
command -v zoxide &>/dev/null && eval "$(zoxide init --cmd cd zsh)"
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

# Machine-specific overrides (not tracked in repo)
[ -f "$HOME/.zshrc.local" ] && source "$HOME/.zshrc.local"
