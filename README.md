# dotfiles

My personal machine setup and source of truth for rebuilding macOS, Debian/Ubuntu, WSL, and native Windows environments.

## Bootstrap

### macOS / Debian / Ubuntu / WSL

```sh
git clone https://github.com/Arthur-K-99/dotfiles.git ~/dotfiles && ~/dotfiles/install.sh
```

> **macOS:** if `git` is unavailable on a brand-new Mac, run `xcode-select --install` first.
>
> **WSL:** run this command inside the Linux distro, not in Windows PowerShell. WSL uses the same Linux packages and dotfiles as a regular Debian/Ubuntu machine.

### Windows (PowerShell)

```powershell
git clone https://github.com/Arthur-K-99/dotfiles $env:USERPROFILE\dotfiles
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
~\dotfiles\install.ps1
```

On a brand-new Windows machine, install Git first with `winget install --id Git.Git --exact`, then reopen PowerShell before cloning this repository.

The installers are designed to be safely rerunnable. Existing unmanaged files are preserved with timestamped `.bak` names before managed links are created.

## Windows and WSL

Windows and WSL share one repository but are separate environments:

| Environment | Installer | Managed shell |
|---|---|---|
| Native Windows | `install.ps1` | PowerShell |
| WSL Debian/Ubuntu | `install.sh` inside WSL | zsh |

Native Windows installs PowerShell, Windows Terminal, and command-line tools through winget. It manages PowerShell and oh-my-posh configuration. WSL reuses the Linux package list and Unix dotfiles. Installing or enabling WSL itself remains an explicit host action because it can require administrator approval and a restart: run `wsl --install`, restart if requested, then run the Unix bootstrap inside WSL.

## What gets installed

| Tool | macOS / Linux / WSL | Native Windows |
|---|---:|---:|
| Git and GitHub CLI | Yes | Yes |
| zsh + Zinit | Yes | No |
| PowerShell + Windows Terminal | No | Yes |
| oh-my-posh | Yes | Yes |
| tmux + TPM | Yes | No |
| eza | Yes | No |
| bat, fzf, zoxide, btop | Yes | Yes |
| Neovim | Yes | Yes |
| CaskaydiaCove Nerd Font | macOS; manual on Linux | Yes |

## After install

- **tmux plugins:** Open tmux and press `prefix + I` (Ctrl+A, I) if plugins aren't active.
- **Font:** Set your terminal font to `CaskaydiaCove NF Mono`. On Linux, download it manually from [nerdfonts.com](https://www.nerdfonts.com/font-downloads) and install to `~/.local/share/fonts/`.
- **Machine-specific config:** Add anything that shouldn't be in the repo to `~/.zshrc.local` (sourced automatically).
- **Windows machine-specific config:** Put private or machine-only PowerShell settings in `~/.powershell.local.ps1`.
- **Verify:** Run `scripts/doctor.sh` on Unix/WSL or `scripts\doctor.ps1` in PowerShell.
- **Repository checks:** Run `scripts/test.sh` before committing installer or configuration changes.
- **Secrets:** Do not store credentials, private keys, access tokens, or work-only settings in this repository. Restore those through a password manager or another private channel.

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

## Scope

The current baseline covers terminal tools, shell configuration, prompt configuration, and tmux. GUI applications and operating-system preferences should be added as opt-in profiles rather than silently changing every machine. Good future profiles include `development`, `personal`, and platform-specific OS settings.
