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

The installers are designed to be safely rerunnable. Existing unmanaged files are preserved with timestamped `.bak` names before managed links are created. If replacement fails, the previous configuration is restored; any backup that cannot be restored is retained and its location is reported. On Windows, a matching file copy is used when symlink creation is unavailable.

An install is complete only after setup verification passes, including automated font and plugin installation. A failed step returns a nonzero status and gives rerun instructions; completed work is preserved. Fix the reported problem and rerun the same installer to finish. Linux font installation remains manual.

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
| nvm + Node.js LTS + npm | Yes | No |
| CaskaydiaCove Nerd Font | macOS; manual on Linux | Yes |

## After install

- **tmux plugins:** Open tmux and press `prefix + I` (Ctrl+A, I) if plugins aren't active.
- **Shell:** The Unix configuration is for zsh. If your default shell is Bash or another shell, run `exec zsh` to use it in the current terminal. To change your default shell, run `chsh -s "$(command -v zsh)"` yourself, then sign out and back in; the installer does not change it automatically.
- **Node.js:** The Unix installer installs the current LTS release as the `nvm` default. Use `nvm install <version>` and `nvm use <version>` to manage other releases.
- **Font:** Set your terminal font to `CaskaydiaCove NF Mono`. On Linux, download it manually from [nerdfonts.com](https://www.nerdfonts.com/font-downloads) and install to `~/.local/share/fonts/`.
- **Machine-specific config:** Add anything that shouldn't be in the repo to `~/.zshrc.local` (sourced automatically).
- **SSH agent:** The shared configuration preserves `SSH_AUTH_SOCK`. To use Bitwarden on a particular machine, add `export SSH_AUTH_SOCK="$HOME/.bitwarden-ssh-agent.sock"` to that machine's `~/.zshrc.local`.
- **Custom Node-manager location:** An exported `NVM_DIR` is respected by the installer, doctor, and shell. Make it available before installing and before opening zsh if you use a location other than `~/.nvm`.
- **Windows machine-specific config:** Put private or machine-only PowerShell settings in `~/.powershell.local.ps1`.
- **Verify:** Run `scripts/doctor.sh` on Unix/WSL or `scripts\doctor.ps1` in PowerShell. Both installers also run verification before reporting success. Windows checks both PowerShell editions' actual profile locations, including redirected Documents folders, and detects stale copied configurations.
- **Repository checks:** Run `bash scripts/test.sh` before committing installer or configuration changes. The suite checks syntax and uses temporary destinations and mocked installation commands to exercise reruns and failures without installing packages or changing your configuration. Missing optional validation tools are reported as skipped checks. Run `pwsh -NoProfile -NonInteractive -File tests/windows.Tests.ps1` for the Windows behavioral suite alone. CI runs checks on macOS, Linux, and Windows, including Windows PowerShell 5.1 and PowerShell 7.
- **Secrets:** Do not store credentials, private keys, access tokens, or work-only settings in this repository. Restore those through a password manager or another private channel.

## Structure

```
dotfiles/
├── home/           # Symlinked to $HOME/
├── config/         # Symlinked into $HOME/.config/
├── packages/       # Declarative package lists (brew, apt, winget)
├── scripts/        # Install and symlink scripts
├── tests/          # Isolated installer regression tests
├── install.sh      # Unix entry point
└── install.ps1     # Windows entry point
```

## Scope

The current baseline covers terminal tools, shell configuration, prompt configuration, and tmux. GUI applications and operating-system preferences should be added as opt-in profiles rather than silently changing every machine. Good future profiles include `development`, `personal`, and platform-specific OS settings.
