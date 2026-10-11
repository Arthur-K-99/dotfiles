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

Native Windows installs PowerShell, Windows Terminal, and command-line tools through winget, PowerShell modules from the PowerShell Gallery, and Node.js through mise. It manages the PowerShell profile, oh-my-posh, git, the tool configurations and a Windows Terminal settings fragment. WSL reuses the Linux package list and Unix dotfiles. Installing or enabling WSL itself remains an explicit host action because it can require administrator approval and a restart: run `wsl --install`, restart if requested, then run the Unix bootstrap inside WSL.

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
| carapace completion, atuin history, direnv | Yes | Yes |
| mise + Node.js LTS | Yes | Yes |
| git configuration with delta, lazygit, lazydocker | Yes | Yes |
| yazi with Catppuccin flavors | Yes | Yes |
| ripgrep, fd, dust, duf, procs, sd, xh, hyperfine, glow, tlrc, gum | Yes | Yes |
| vivid (Catppuccin `LS_COLORS`) | Yes | No |
| zsh-abbr, zsh-you-should-use | Yes | No |
| Neovim | Yes | Yes |
| CaskaydiaCove Nerd Font | macOS; manual on Linux | Yes |

## After install

- **Ghostty:** The configuration is linked to `~/.config/ghostty/config`; reload it with `Cmd+Shift+,`. The theme follows the OS appearance (Latte in light mode, the flavor in `config/catppuccin/flavor` in dark), the left Option key acts as Alt for fzf's `Alt+C`, and `` Cmd+` `` opens a drop-down quick terminal from any app after macOS grants the Accessibility permission it asks for. Machine-local settings, shaders and extra themes go in `~/.config/ghostty/local`, which the managed file loads last when it exists; on macOS, `~/Library/Application Support/com.mitchellh.ghostty/config` is loaded after both. On Linux, install Ghostty from [ghostty.org](https://ghostty.org/download); the configuration is already in place.
- **Windows Terminal:** Restart Windows Terminal after installing, or save `settings.json` once: fragments are read only when settings load. A fragment under `%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\dotfiles\` adds the Catppuccin scheme of the current flavor and applies it, the Nerd Font, padding and acrylic to the PowerShell 7, Windows PowerShell and Command Prompt profiles without touching `settings.json`. Fragments cannot change global settings or WSL profiles: choose PowerShell as the default profile and the scheme for WSL profiles once in Settings, or set `"defaultProfile": "{574e775e-4f2a-5b96-ac1e-a2962a402336}"` in `settings.json`.
- **PowerShell keys:** `Tab` opens a completion menu, `Up`/`Down` search history by prefix, `Ctrl+R` searches history and `Ctrl+T` inserts files through fzf, and PowerShell 7 shows predictions from history and tab completion in a list. Windows PowerShell 5.1 gets the colors and the Tab, Up/Down, Ctrl+D and Ctrl+W keys; predictions, the fzf chords, posh-git and Terminal-Icons are PowerShell 7 only, because its PSReadLine is older and the modules are installed for PowerShell 7.
- **tmux:** The configuration is linked to `~/.config/tmux/tmux.conf` and TPM installs plugins under `~/.config/tmux/plugins/`. The bootstrap installs the plugins; press `prefix + I` (Ctrl+A, I) if one is missing after editing the plugin list. The linker removes the old `~/.tmux.conf` link, because tmux would load both files; a `~/.tmux/plugins` directory from before the move can be deleted.
- **tmux colors:** tmux identifies itself as `tmux-256color` for italics and forces true color through every host terminal, including Windows Terminal and WSL. Linux gets the terminfo from the `ncurses-term` package. If a remote host you `ssh` into from tmux lacks that terminfo, prefix the command with `TERM=screen-256color`.
- **Theme:** Every tool uses one Catppuccin flavor, recorded in `config/catppuccin/flavor`: tmux, the prompt, eza, bat and fzf, including tab-completion menus. `bash scripts/theme.sh <flavor>` switches all of them at once and [docs/theming.md](docs/theming.md) lists every location. bat 0.25+ ships the themes; the bootstrap installs the current one for older distribution packages.
- **fzf keys:** `Ctrl+T` inserts files, `Ctrl+R` searches history, `Alt+C` changes directory, and `Tab` completion opens the same fzf window.
- **Shell:** The Unix configuration is for zsh. If your default shell is Bash or another shell, run `exec zsh` to use it in the current terminal. To change your default shell, run `chsh -s "$(command -v zsh)"` yourself, then sign out and back in; the installer does not change it automatically.
- **Runtimes:** mise installs the Node.js LTS pinned in `config/mise/config.toml` and switches versions per project from `.tool-versions`, `.nvmrc` or `.node-version` files. zsh puts mise's shims directory on `PATH` rather than running `mise activate`, which keeps shell startup fast; project `[env]` sections in mise files are therefore not applied (use direnv). PowerShell runs `mise activate`. `mise use -g node@22` changes the global default, `mise use python@3.13` adds a runtime to a project, `mise ls` shows what is installed. An existing nvm installation is left alone and no longer loaded; remove `~/.nvm` when you are sure nothing else needs it.
- **Completion:** carapace completes over a thousand commands in zsh and PowerShell; `Tab` opens the menu in both shells. Run `carapace --clear-cache` after installing new tools.
- **History:** atuin owns `Ctrl+R` with fuzzy search over a local SQLite database; `Up` stays plain zsh history. Sync between machines is opt-in: `atuin register` or `atuin login`, then `atuin sync`. PowerShell support needs atuin 18.11 or newer, which winget installs.
- **Git:** `~/.config/git/config` holds the shared settings (delta as pager, zdiff3 conflicts, rebase on pull, autosquash, sorted branches, a global ignore in `~/.config/git/ignore`). Identity and credential helpers stay in `~/.gitconfig`, which git reads afterwards and which `git config --global` writes to; the linker creates an empty one when it is missing, so those writes never land in the managed file. `lazygit` and `lazydocker` use the same Catppuccin colors.
- **Abbreviations:** zsh-abbr expands `g`, `gs`, `gc`, `lg` and friends on `Space` or `Enter`; `abbr add name=command` adds one and rewrites the tracked `config/zsh-abbr/user-abbreviations` through the linked directory, so commit the change. you-should-use reminds you of an alias after a command runs.
- **Colors on Linux:** vivid 0.9 or newer carries the Catppuccin `LS_COLORS`; Debian 12 ships 0.8, so completion menus there fall back to the terminal palette until vivid is updated (`cargo install vivid` or the GitHub release).
- **Files:** `y` opens yazi and changes to the directory you quit in. `fd` and `rg` replace `find` and `grep` (Debian installs fd as `fdfind`; the shell aliases it). `Ctrl+T` and `Alt+C` use fd, so ignored files stay out of the way.
- **Font:** Ghostty and the Windows Terminal fragment select `CaskaydiaCove Nerd Font Mono` themselves (some pickers list it as `CaskaydiaCove NFM`); choose it by hand in any other terminal. On Linux, download it manually from [nerdfonts.com](https://www.nerdfonts.com/font-downloads) and install to `~/.local/share/fonts/`.
- **Machine-specific config:** Add anything that shouldn't be in the repo to `~/.zshrc.local` (sourced automatically).
- **SSH agent:** The shared configuration preserves `SSH_AUTH_SOCK`. To use Bitwarden on a particular machine, add `export SSH_AUTH_SOCK="$HOME/.bitwarden-ssh-agent.sock"` to that machine's `~/.zshrc.local`.
- **Tool binaries on Linux:** Tools that Debian and Ubuntu do not package come from signed apt repositories (eza, glow, gum) or from the latest GitHub release into `~/.local/bin` (lazygit, lazydocker, delta, atuin, carapace, yazi, dust, procs, xh, tlrc). Set `DOTFILES_LOCAL_BIN` before installing to use another directory; the installers put it on `PATH`. Rerunning the bootstrap does not upgrade release binaries; delete one from `~/.local/bin` and rerun to refresh it.
- **Windows machine-specific config:** Put private or machine-only PowerShell settings in `~/.powershell.local.ps1`.
- **Verify:** Run `scripts/doctor.sh` on Unix/WSL or `scripts\doctor.ps1` in PowerShell. Both installers also run verification before reporting success. Windows checks both PowerShell editions' actual profile locations, including redirected Documents folders, detects stale copied configurations, and confirms each PowerShell module is installed for PowerShell 7.
- **Repository checks:** Run `bash scripts/test.sh` before committing installer or configuration changes. The suite checks syntax and uses temporary destinations and mocked installation commands to exercise reruns and failures without installing packages or changing your configuration. Missing optional validation tools are reported as skipped checks. Run `pwsh -NoProfile -NonInteractive -File tests/windows.Tests.ps1` for the Windows behavioral suite alone. CI runs checks on macOS, Linux, and Windows, including Windows PowerShell 5.1 and PowerShell 7.
- **Secrets:** Do not store credentials, private keys, access tokens, or work-only settings in this repository. Restore those through a password manager or another private channel.

## Structure

```
dotfiles/
├── home/           # Symlinked to $HOME/
├── config/         # Tool configuration: atuin, bat, catppuccin (flavor and palette), eza, ghostty,
│                   # git, lazygit, mise, oh-my-posh, powershell, tmux, windows-terminal, yazi, zsh-abbr
├── packages/       # Declarative package lists (brew, apt, winget)
├── scripts/        # Install, symlink, bootstrap, doctor and theme-switch scripts
├── tests/          # Isolated installer regression tests
├── docs/           # Roadmap and theming notes
├── install.sh      # Unix entry point
└── install.ps1     # Windows entry point
```

## Scope

The current baseline covers the terminal emulators, terminal tools, shell configuration, prompt configuration, and tmux, all in one Catppuccin flavor. Other GUI applications and operating-system preferences should be added as opt-in profiles rather than silently changing every machine. Good future profiles include `development`, `personal`, and platform-specific OS settings. Planned work, including new tools and Neovim, is tracked in [docs/roadmap.md](docs/roadmap.md).
