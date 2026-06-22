# dotfiles

My personal machine setup — installs tools and applies configs in one command.

## Bootstrap

### macOS / Linux

```sh
git clone https://github.com/Arthur-K-99/dotfiles.git ~/dotfiles && ~/dotfiles/install.sh
```

> **macOS only:** if `git` is not available on a brand-new Mac, run `xcode-select --install` first.

### Windows (PowerShell)

```powershell
git clone https://github.com/Arthur-K-99/dotfiles $env:USERPROFILE\dotfiles
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
~\dotfiles\install.ps1
```

The script is idempotent — safe to run again to update or repair.

## What gets installed

| Tool | Purpose |
|---|---|
| zsh + zinit | Shell and plugin manager |
| oh-my-posh | Prompt (Catppuccin Macchiato theme) |
| tmux + TPM | Terminal multiplexer |
| eza | `ls` replacement with icons |
| bat | `cat` replacement with syntax highlighting |
| fzf | Fuzzy finder |
| zoxide | Smart `cd` |
| btop | Resource monitor |
| neovim | Editor |
| gh | GitHub CLI |
| CaskaydiaCove NF | Nerd Font (required for icons and prompt) |

## After install

- **tmux plugins:** Open tmux and press `prefix + I` (Ctrl+A, I) if plugins aren't active.
- **Font:** Set your terminal font to `CaskaydiaCove NF Mono`. On Linux, download it manually from [nerdfonts.com](https://www.nerdfonts.com/font-downloads) and install to `~/.local/share/fonts/`.
- **Machine-specific config:** Add anything that shouldn't be in the repo to `~/.zshrc.local` (sourced automatically).

## Structure

```
dotfiles/
├── home/           # Symlinked to $HOME/
├── config/         # Symlinked into $HOME/.config/
├── packages/       # Declarative package lists (brew, apt, winget)
├── scripts/        # Install and symlink scripts
├── install.sh      # Unix entry point
└── install.ps1     # Windows entry point
```
