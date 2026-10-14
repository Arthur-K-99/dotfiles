# dotfiles

My personal machine setup and source of truth for rebuilding macOS, Debian/Ubuntu, WSL and native Windows environments: one terminal setup in one Catppuccin flavor, with every tool declared in this repository.

Where it has been tried:

- **Debian 12 and 13, Ubuntu 24.04 and 26.04:** fresh installs in containers, on x86_64 (CI, every week) and arm64 (on a Mac).
- **macOS:** my Mac and CI's macOS runner.
- **WSL:** the Linux install inside a Debian or Ubuntu distribution; what differs there (the font, the clipboard) is covered by the mocked tests only.
- **Native Windows:** `install.ps1`, a rerun and the update on a clean Windows Server 2025 machine in CI (every week), plus the mocked installer tests under Windows PowerShell 5.1 and PowerShell 7; not yet on a desktop Windows 11.

## Try it first

The installer replaces your shell and tool configuration and installs packages. To see it without touching your machine:

- **Linux, unattended:** from a clone of this repository, `bash tests/fresh_install.sh ubuntu:24.04` (or `debian:12`, `debian:13`, `ubuntu:26.04`) installs the checkout in a new Docker container, reruns it, runs the update and starts zsh and tmux, then removes the container. On a Mac prefix `DOCKER_DEFAULT_PLATFORM=linux/arm64`; for repeated runs add `GITHUB_TOKEN="$(gh auth token)"` ([development](docs/development.md#fresh-install)).
- **Linux, to look around:** a container with a user that has sudo, as on a real machine. `docker start -ai dotfiles-try` returns to it as root (`su - dev` again), and `docker rm -f dotfiles-try` removes it. On a Mac add `--platform linux/arm64` to `docker run`, or an amd64 copy of the image pulled earlier runs emulated. This installs the `main` branch from GitHub; `tests/fresh_install.sh` installs your checkout.

  ```sh
  docker run -it --name dotfiles-try ubuntu:24.04
  # inside, as root
  apt-get update && apt-get install -y sudo git ca-certificates
  echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections
  echo LANG=C.UTF-8 > /etc/default/locale
  useradd -m -s /bin/bash dev && echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev
  su - dev
  git clone https://github.com/Arthur-K-99/dotfiles.git ~/dotfiles && ~/dotfiles/install.sh
  sudo chsh -s "$(command -v zsh)" dev && exit   # dev has no password for chsh
  su - dev                                        # back as root: now in zsh
  ```

- **WSL:** a second distribution, copied from yours, which `wsl --unregister dotfiles-try` removes: `wsl --export Ubuntu $env:TEMP\ubuntu.tar`, `wsl --import dotfiles-try $env:LOCALAPPDATA\dotfiles-try $env:TEMP\ubuntu.tar`, `Remove-Item $env:TEMP\ubuntu.tar`, then `wsl -d dotfiles-try -u <your user>` and install inside (it too installs GitHub's `main`). An imported distribution starts as root, so keep passing `-u <your user>`. `wsl -l` lists the distribution names.
- **macOS and Windows:** a virtual machine (UTM, Tart, Parallels, Hyper-V). A second macOS user is not isolated: Homebrew's prefix belongs to the first administrator and `/Applications` is shared. Windows Sandbox has no winget.

[Troubleshooting](docs/troubleshooting.md) says how to [undo an install](docs/troubleshooting.md#undo-an-install) and what to put in a [report](docs/troubleshooting.md#report-a-problem).

## Install

### Before you start

- **Debian and Ubuntu:** git (and `ca-certificates`, which minimal images lack) and a user with sudo. apt runs through sudo, which may ask again during the long bootstrap stage. Debian, Ubuntu and their derivatives only, on x86_64 or arm64.
- **WSL:** run the Linux install inside the distribution, not in Windows PowerShell. WSL itself comes from `wsl --install` in an administrator PowerShell and may need a restart. The font is the Windows one, which `install.ps1` installs (without `install.ps1`, see [Linux and WSL](docs/linux.md#wsl)).
- **macOS:** an administrator account, for Homebrew's installer, which asks for your password and for RETURN. git comes from the Command Line Tools: on a brand-new Mac run `xcode-select --install` first. They also bring the C compiler for Neovim's parsers.
- **Windows:** a working winget (App Installer), then Git with `winget install --id Git.Git --exact`, and a new PowerShell before cloning. Elevation is optional. The first run is in Windows PowerShell 5.1, which makes links only when elevated (Developer Mode helps only from PowerShell 7, and reruns keep matching copies); otherwise the installer copies the files, which stay stale until the next install or update ([Windows](docs/windows.md#links-or-copies)).
- **Existing configuration on Windows:** a `Microsoft.PowerShell_profile.ps1` still runs after the managed profile and can replace its prompt, and extra files in `%LOCALAPPDATA%\nvim` mix with the managed ones ([Windows](docs/windows.md#existing-configurations)).

### macOS / Debian / Ubuntu / WSL

```sh
git clone https://github.com/Arthur-K-99/dotfiles.git ~/dotfiles && ~/dotfiles/install.sh
```

### Windows (PowerShell)

```powershell
git clone https://github.com/Arthur-K-99/dotfiles $env:USERPROFILE\dotfiles
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
~\dotfiles\install.ps1
```

The installers can be rerun safely; the links point into the clone, so keep it where it is. Existing unmanaged files are preserved with timestamped `.bak` names before managed links are created; if replacement fails, the previous configuration is restored, and a backup that cannot be restored is kept and its location reported. On Windows a matching copy is used when symbolic links are unavailable. An install is complete only after verification (the doctor) passes, including the automated font and plugin installation. A failed step returns a nonzero status, keeps the completed work, and names the command to rerun once you have fixed the reported problem.

Native Windows and WSL are separate environments: `install.ps1` sets up PowerShell with winget packages, and `install.sh` inside WSL sets up zsh with the Linux packages ([Windows](docs/windows.md), [Linux and WSL](docs/linux.md)).

## First steps after install

- **Login shell:** on Linux and WSL, and wherever the installer prints it, run `chsh -s "$(command -v zsh)"`, then sign out and back in (WSL: open a new tab, or `wsl -d <distribution> -u <your user>`). New terminals and tmux panes start the login shell, so without this they skip the zsh configuration; `exec zsh` covers one terminal only.
- **Terminal:** on macOS open Ghostty, not Terminal.app: it carries the font and the theme. Elsewhere select `CaskaydiaCove Nerd Font Mono` in your terminal, or install Ghostty from [ghostty.org](https://ghostty.org/download), whose configuration is already linked.
- **Windows Terminal:** restart it. Make PowerShell the default profile, and give each WSL profile the font `CaskaydiaCove Nerd Font Mono` and the scheme `Catppuccin <flavor>`; the fragment cannot ([Windows](docs/windows.md#windows-terminal)).
- **Git identity:** `git config --global user.name …` and `user.email …` write to `~/.gitconfig`, which the installer creates when it is missing and which stays out of the repository.
- **Machine-local settings:** `~/.zshrc.local`, `~/.powershell.local.ps1`, `~/.config/ghostty/local` and `~/.config/tmux/local.conf`. The linked files are the repository's.
- **History:** `atuin import auto` brings your existing shell history into atuin's `Ctrl+R`.
- **Greeting:** `DOTFILES_FASTFETCH=0` in `~/.zshrc.local` (PowerShell: `$env:DOTFILES_FASTFETCH = '0'` in `~/.powershell.local.ps1`) turns fastfetch off.
- **Check:** `~/dotfiles/scripts/doctor.sh` (Windows: `~\dotfiles\scripts\doctor.ps1`). [Troubleshooting](docs/troubleshooting.md) explains the lines that look like errors.

## Update

```sh
git -C ~/dotfiles pull && ~/dotfiles/scripts/update.sh
```

```powershell
git -C $HOME\dotfiles pull; if ($LASTEXITCODE -eq 0) { ~\dotfiles\scripts\update.ps1 }
```

The update does not pull the repository, so `git pull` first. It runs the install stages again and also upgrades the declared packages, the release tools (once a release is a day old), the PowerShell modules, the zsh and tmux plugins, the yazi flavors, mise's runtimes, and Neovim's parsers and language servers, then runs the doctor. Neovim's plugins stay at the commits `lazy-lock.json` pins. It leaves alone what it did not install and what you pinned or held, and says so. A plain rerun adds what is missing and upgrades nothing but the listed apt packages on Linux. [Updating](docs/updating.md) has the details.

## What gets installed

| Tool | macOS / Linux / WSL | Native Windows |
|---|---:|---:|
| Git (macOS: the Command Line Tools') and GitHub CLI | Yes | Yes |
| Ghostty with Catppuccin, following the OS appearance | macOS; manual on Linux | No |
| zsh + Zinit | Yes | No |
| PowerShell + Windows Terminal with a Catppuccin fragment | No | Yes |
| PowerShell modules: Terminal-Icons, PSFzf, posh-git, CompletionPredictor | No | Yes |
| oh-my-posh | Yes | Yes |
| tmux + TPM: sensible, yank, vim-tmux-navigator, resurrect + continuum, tmux-fzf, floax, Catppuccin status line with tmux-cpu and tmux-battery | Yes | No |
| sesh session picker (zoxide and fzf) | Yes | No |
| eza | Yes | Yes |
| bat, fzf, zoxide, btop | Yes | Yes |
| fastfetch greeter in Catppuccin colors | Yes | Yes |
| carapace completion, atuin history, direnv | Yes | Yes (direnv in PowerShell 7.2+) |
| mise + Node.js LTS | Yes | Yes |
| git configuration with delta, lazygit, lazydocker | Yes | Yes |
| yazi with Catppuccin flavors | Yes | Yes |
| ripgrep, fd, dust, duf, procs, sd, xh, hyperfine, glow, tlrc, gum | Yes | Yes |
| vivid (Catppuccin `LS_COLORS`) | Yes | No |
| zsh-abbr, zsh-you-should-use | Yes | No |
| Neovim 0.12 with lazy.nvim: Catppuccin, Tree-sitter, LSP through Mason, fzf-lua, which-key, gitsigns, vim-tmux-navigator | Yes | Yes |
| tree-sitter CLI (compiles the Tree-sitter parsers) | Yes | Yes |
| CaskaydiaCove Nerd Font | Yes (WSL uses the Windows font) | Yes |

## Key bindings

| Where | Keys |
|---|---|
| zsh | `Tab` fzf completion menu · `Up` history · `Ctrl+P`/`Ctrl+N` history lines with the same first word · `Alt+W` cut back to the mark · `Ctrl+X Ctrl+E` edit the line in `$EDITOR` · `Space` or `Enter` expands an abbreviation (`g`, `gs`, `gc`, `lg`, …) |
| fzf, atuin | `Ctrl+R` atuin history search (`Enter` runs, `Tab` edits) · `Ctrl+T` insert files · `Alt+C` change directory |
| tmux, prefix `Ctrl+A` | `h j k l` panes · `Ctrl+h/j/k/l` panes and Neovim splits, no prefix · `r` reload · `Ctrl+L` clear the screen · `F` tmux-fzf · `` ` `` floating pane · `T` sesh picker, `L` last session · `Ctrl+S`/`Ctrl+R` save/restore sessions · `I` install plugins · `y` in copy mode copies |
| Neovim, leader `Space` | `Space Space` or `Space f f` files · `Space /` grep · `Space f b` buffers · `Space f .` resume picker · `Space ?` buffer keys · `gd` definition · `grr` references · `grn` rename · `gra` code action · `K` hover · `Space c f` format · `]d`/`[d` diagnostics, `Space x x` list · `]c`/`[c` hunks · `Space g s`/`Space g r` stage/reset hunk · `Space g p` preview · `Space g b` blame · `Space g g` status · `Ctrl+Y` accept completion |
| PowerShell | `Tab` menu · `Up`/`Down` prefix history · `Ctrl+R` history (atuin, or PSFzf) · `Ctrl+T` files · `Ctrl+D` exit · `Ctrl+W` delete word ([5.1 differs](docs/windows.md#powershell)) |
| Ghostty | `Cmd+Shift+,` reload (Linux `Ctrl+Shift+,`) · `` Cmd+` `` quick terminal (macOS) · `Shift+Enter` newline · left Option is Alt (macOS) |
| Aliases | `cd` zoxide · `ls`, `la`, `ll`, `tree` eza · `cat` bat · `vim` nvim · `c` clear · `y` yazi, changing to its directory on exit |

## More docs

- [docs/tools.md](docs/tools.md): what each tool does after install and where its configuration lives.
- [docs/linux.md](docs/linux.md) and [docs/windows.md](docs/windows.md): what differs by platform, WSL included.
- [docs/updating.md](docs/updating.md): everything the update upgrades and leaves alone.
- [docs/downloads.md](docs/downloads.md): verified downloads, the release age and `GITHUB_TOKEN`.
- [docs/troubleshooting.md](docs/troubleshooting.md): messages that are not errors, first-try problems, undoing an install, reporting.
- [docs/development.md](docs/development.md): repository checks, fresh installs and CI.
- [docs/theming.md](docs/theming.md): where every color lives and how to switch Catppuccin flavor.
- [docs/roadmap.md](docs/roadmap.md): what is planned, the checklist for adding a tool, and known issues.

## Structure

```
dotfiles/
├── home/           # Symlinked to $HOME/
├── config/         # Tool configuration: atuin, bat, catppuccin (flavor and palette), eza, fastfetch,
│                   # ghostty, git, lazygit, mise, nvim, oh-my-posh, powershell, tmux, windows-terminal,
│                   # yazi, zsh-abbr
├── packages/       # Declarative package lists (brew, apt, winget)
├── scripts/        # Install, symlink, bootstrap, update, doctor and theme-switch scripts
├── tests/          # Isolated installer regression tests and the fresh-install check
├── docs/           # Per-tool and per-platform notes, troubleshooting, theming and the roadmap
├── install.sh      # Unix entry point
└── install.ps1     # Windows entry point
```

## Scope

The current baseline covers the terminal emulators, terminal tools, shell configuration, prompt configuration, tmux and Neovim, all in one Catppuccin flavor. Other GUI applications and operating-system preferences should be added as opt-in profiles (`minimal`, `development`, `personal`) rather than silently changing every machine; [the roadmap](docs/roadmap.md) tracks them.

Do not store credentials, private keys, access tokens or work-only settings in this repository. Restore those through a password manager or another private channel.
