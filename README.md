# dotfiles

My personal machine setup and source of truth for rebuilding macOS, Debian/Ubuntu, WSL, and native Windows environments.

- [docs/roadmap.md](docs/roadmap.md): what is planned, phase by phase, and the checklist for adding a tool.
- [docs/theming.md](docs/theming.md): where every color lives and how to switch Catppuccin flavor.

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

Native Windows installs PowerShell, Windows Terminal, and command-line tools through winget, and PowerShell modules from the PowerShell Gallery. It manages the PowerShell profile, oh-my-posh, and a Windows Terminal settings fragment. WSL reuses the Linux package list and Unix dotfiles. Installing or enabling WSL itself remains an explicit host action because it can require administrator approval and a restart: run `wsl --install`, restart if requested, then run the Unix bootstrap inside WSL.

## What gets installed

| Tool | macOS / Linux / WSL | Native Windows |
|---|---:|---:|
| Git and GitHub CLI | Yes | Yes |
| Ghostty with Catppuccin, following the OS appearance | macOS; manual on Linux | No |
| zsh + Zinit | Yes | No |
| PowerShell + Windows Terminal with a Catppuccin fragment | No | Yes |
| PowerShell modules: Terminal-Icons, PSFzf, posh-git, CompletionPredictor | No | Yes |
| oh-my-posh | Yes | Yes |
| tmux + TPM | Yes | No |
| eza | Yes | Yes |
| bat, fzf, zoxide, btop | Yes | Yes |
| Neovim | Yes | Yes |
| nvm + Node.js LTS + npm | Yes | No |
| CaskaydiaCove Nerd Font | macOS; manual on Linux | Yes |

## After install

- **Ghostty:** The configuration is linked to `~/.config/ghostty/config`; reload it with `Cmd+Shift+,`. The theme follows the OS appearance (Latte in light mode, Macchiato in dark), the left Option key acts as Alt for fzf's `Alt+C`, and `Cmd+`` ` opens a drop-down quick terminal from any app after macOS grants the Accessibility permission it asks for. Machine-local settings, shaders and extra themes belong beside the linked file or, on macOS, in `~/Library/Application Support/com.mitchellh.ghostty/config`, which Ghostty loads afterwards. On Linux, install Ghostty from [ghostty.org](https://ghostty.org/download); the configuration is already in place.
- **Windows Terminal:** Restart Windows Terminal after installing. A fragment under `%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\dotfiles\` adds the Catppuccin Macchiato scheme and applies it, the Nerd Font, padding and acrylic to the PowerShell 7, Windows PowerShell and Command Prompt profiles without touching `settings.json`. Fragments cannot change global settings or WSL profiles: choose PowerShell as the default profile and the scheme for WSL profiles once in Settings, or set `"defaultProfile": "{574e775e-4f2a-5b96-ac1e-a2962a402336}"` in `settings.json`.
- **PowerShell keys:** `Tab` opens a completion menu, `Up`/`Down` search history by prefix, `Ctrl+R` searches history and `Ctrl+T` inserts files through fzf, and PowerShell 7 shows predictions from history and tab completion in a list. Windows PowerShell 5.1 gets the same colors and keys without predictions, because its PSReadLine is older.
- **tmux plugins:** Open tmux and press `prefix + I` (Ctrl+A, I) if plugins aren't active.
- **tmux colors:** tmux identifies itself as `tmux-256color` for italics and forces true color through every host terminal, including Windows Terminal and WSL. Linux gets the terminfo from the `ncurses-term` package. If a remote host you `ssh` into from tmux lacks that terminfo, prefix the command with `TERM=screen-256color`.
- **Theme:** Every tool uses Catppuccin Macchiato: tmux, the prompt, eza, bat and fzf, including tab-completion menus. bat 0.25+ ships the theme; the bootstrap installs it for older distribution packages.
- **fzf keys:** `Ctrl+T` inserts files, `Ctrl+R` searches history, `Alt+C` changes directory, and `Tab` completion opens the same fzf window.
- **Shell:** The Unix configuration is for zsh. If your default shell is Bash or another shell, run `exec zsh` to use it in the current terminal. To change your default shell, run `chsh -s "$(command -v zsh)"` yourself, then sign out and back in; the installer does not change it automatically.
- **Node.js:** The Unix installer installs the current LTS release as the `nvm` default. Use `nvm install <version>` and `nvm use <version>` to manage other releases. The shell puts the default version on `PATH` immediately and loads `nvm` itself on first use, which keeps startup fast; open a new shell after changing the default with `nvm alias default`.
- **Font:** Ghostty and the Windows Terminal fragment select `CaskaydiaCove Nerd Font Mono` themselves (some pickers list it as `CaskaydiaCove NFM`); choose it by hand in any other terminal. On Linux, download it manually from [nerdfonts.com](https://www.nerdfonts.com/font-downloads) and install to `~/.local/share/fonts/`.
- **Machine-specific config:** Add anything that shouldn't be in the repo to `~/.zshrc.local` (sourced automatically).
- **SSH agent:** The shared configuration preserves `SSH_AUTH_SOCK`. To use Bitwarden on a particular machine, add `export SSH_AUTH_SOCK="$HOME/.bitwarden-ssh-agent.sock"` to that machine's `~/.zshrc.local`.
- **Custom Node-manager location:** An exported `NVM_DIR` is respected by the installer, doctor, and shell. Make it available before installing and before opening zsh if you use a location other than `~/.nvm`.
- **Windows machine-specific config:** Put private or machine-only PowerShell settings in `~/.powershell.local.ps1`.
- **Verify:** Run `scripts/doctor.sh` on Unix/WSL or `scripts\doctor.ps1` in PowerShell. Both installers also run verification before reporting success. Windows checks both PowerShell editions' actual profile locations, including redirected Documents folders, detects stale copied configurations, and confirms each PowerShell module is installed for PowerShell 7.
- **Repository checks:** Run `bash scripts/test.sh` before committing installer or configuration changes. The suite checks syntax and uses temporary destinations and mocked installation commands to exercise reruns and failures without installing packages or changing your configuration. Missing optional validation tools are reported as skipped checks. Run `pwsh -NoProfile -NonInteractive -File tests/windows.Tests.ps1` for the Windows behavioral suite alone. CI runs checks on macOS, Linux, and Windows, including Windows PowerShell 5.1 and PowerShell 7.
- **Secrets:** Do not store credentials, private keys, access tokens, or work-only settings in this repository. Restore those through a password manager or another private channel.

## Structure

```
dotfiles/
├── home/           # Symlinked to $HOME/
├── config/         # Tool configuration: bat, eza, ghostty, oh-my-posh, powershell, windows-terminal
├── packages/       # Declarative package lists (brew, apt, winget)
├── scripts/        # Install, symlink, bootstrap and doctor scripts
├── tests/          # Isolated installer regression tests
├── docs/           # Roadmap and theming notes
├── install.sh      # Unix entry point
└── install.ps1     # Windows entry point
```

## Scope

The current baseline covers the terminal emulators, terminal tools, shell configuration, prompt configuration, and tmux, all in one Catppuccin flavor. Other GUI applications and operating-system preferences should be added as opt-in profiles rather than silently changing every machine. Good future profiles include `development`, `personal`, and platform-specific OS settings. Planned work, including new tools and Neovim, is tracked in [docs/roadmap.md](docs/roadmap.md).
