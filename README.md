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

An install is complete only after setup verification passes, including automated font and plugin installation. A failed step returns a nonzero status and gives rerun instructions; completed work is preserved. Fix the reported problem and rerun the same installer to finish.

### Update

```sh
~/dotfiles/scripts/update.sh
```

```powershell
~\dotfiles\scripts\update.ps1
```

A rerun of the installer only adds what is missing. The update runs the same stages and also upgrades, then finishes with the same verification:

- **Packages:** the ones `packages/*.txt` declares, after Homebrew refreshes its index. On Linux the signing keys of the eza and Charm repositories are fetched again and checked against their pins first. Homebrew may also upgrade the formulae a declared one depends on and the installed formulae that depend on it; nothing else is touched.
- **Release tools:** each tool the bootstrap fetched from a GitHub release, when a newer tag exists.
- **Plugins:** zinit and TPM with their plugins, and the yazi flavors.
- **Runtimes:** mise's runtimes.
- **Neovim:** the parsers and the Mason language servers. The plugins stay at the commits `lazy-lock.json` pins.

It leaves some things alone and says so:

- tools it did not install, such as a binary on `PATH` from another source. In `~/.local/bin` a plain file with a tool's name counts as the bootstrap's, but a link (pipx, uv and npm make links there) does not;
- whatever you pinned or held (`brew pin`, `apt-mark hold`, `winget pin`, a tmux plugin pinned to a tag);
- on Windows, the PowerShell 7 or Windows Terminal that is running it. Upgrade those from another shell with the `winget upgrade` command it prints.

Casks that update themselves, such as Ghostty, are not reported as outdated by Homebrew, so the update leaves them to their own updater without a word.

It does not pull this repository: run `git pull` first to take its changes.

### Verified downloads

The files the Unix bootstrap downloads with curl are checked or pinned before they are used:

- **GitHub releases:** the release tools (including oh-my-posh, zoxide and mise), Neovim, the tree-sitter CLI and the Linux Nerd Font. Each file must match the SHA-256 digest GitHub lists for that asset; a file that does not is deleted before anything is unpacked or replaced. No installer script is piped into a shell.
- **apt repositories:** eza's and Charm's are added only when the downloaded signing key has the fingerprint pinned in `scripts/lib/apt_repositories.sh`. The update fetches both keys again before apt reads the repositories and checks them against the pins. A changed copy of the pinned key is merged into the keyring, so an expiry the project extends reaches the machine without invalidating what the key signed before (Charm's key expires on 2027-07-13). A keyring holding any other key is replaced. The doctor reports a keyring that does not hold its pinned key, a key that has expired, and one that expires within 30 days. This matters because apt only warns about an expired key once a repository's lists exist, and keeps the old ones.
- **bat themes:** bat releases older than 0.26 get the Catppuccin theme from a fixed commit of catppuccin/bat, so the file cannot change under its URL.

The digest comes from the same release as the file, so it proves the file is what the release holds, not that the release itself is genuine. Package managers check their own downloads: apt against its signed indexes, Homebrew bottles and casks against the SHA-256 in their formula or cask, and winget each installer against the SHA-256 in its manifest. Plugins come from git: Neovim's at the commits `lazy-lock.json` pins; zinit's, TPM's and the yazi flavors at their branch heads. Two downloads are not checked yet: Homebrew's installer script (from `HEAD`, as Homebrew's instructions say), and on Windows the Nerd Font that `oh-my-posh font install` fetches.

GitHub's API answers 60 requests an hour per address without a token, and a Linux install makes one per release download, about 18. Repeated installs behind one address can exceed that; set `GITHUB_TOKEN` (for example `GITHUB_TOKEN="$(gh auth token)"`) to raise the limit. A token GitHub does not accept is dropped with a warning.

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
| tmux + TPM: sensible, yank, vim-tmux-navigator, resurrect + continuum, tmux-fzf, floax, Catppuccin status line with tmux-cpu and tmux-battery | Yes | No |
| sesh session picker (zoxide and fzf) | Yes | No |
| eza | Yes | Yes |
| bat, fzf, zoxide, btop | Yes | Yes |
| fastfetch greeter in Catppuccin colors | Yes | Yes |
| carapace completion, atuin history, direnv | Yes | Yes |
| mise + Node.js LTS | Yes | Yes |
| git configuration with delta, lazygit, lazydocker | Yes | Yes |
| yazi with Catppuccin flavors | Yes | Yes |
| ripgrep, fd, dust, duf, procs, sd, xh, hyperfine, glow, tlrc, gum | Yes | Yes |
| vivid (Catppuccin `LS_COLORS`) | Yes | No |
| zsh-abbr, zsh-you-should-use | Yes | No |
| Neovim 0.12 with lazy.nvim: Catppuccin, Tree-sitter, LSP through Mason, fzf-lua, which-key, gitsigns, vim-tmux-navigator | Yes | Yes |
| tree-sitter CLI (compiles the Tree-sitter parsers) | Yes | Yes |
| CaskaydiaCove Nerd Font | Yes (WSL uses the Windows font) | Yes |

## After install

- **Ghostty:** The configuration is linked to `~/.config/ghostty/config`; reload it with `Cmd+Shift+,`. The theme follows the OS appearance (Latte in light mode, the flavor in `config/catppuccin/flavor` in dark), the left Option key acts as Alt for fzf's `Alt+C`, and `` Cmd+` `` opens a drop-down quick terminal from any app after macOS grants the Accessibility permission it asks for. Machine-local settings, shaders and extra themes go in `~/.config/ghostty/local`, which the managed file loads last when it exists; on macOS, `~/Library/Application Support/com.mitchellh.ghostty/config` is loaded after both. On Linux, install Ghostty from [ghostty.org](https://ghostty.org/download); the configuration is already in place.
- **Windows Terminal:** Restart Windows Terminal after installing, or save `settings.json` once: fragments are read only when settings load. A fragment under `%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\dotfiles\` adds the Catppuccin scheme of the current flavor and applies it, the Nerd Font, padding and acrylic to the PowerShell 7, Windows PowerShell and Command Prompt profiles without touching `settings.json`. Fragments cannot change global settings or WSL profiles: choose PowerShell as the default profile and the scheme for WSL profiles once in Settings, or set `"defaultProfile": "{574e775e-4f2a-5b96-ac1e-a2962a402336}"` in `settings.json`.
- **PowerShell keys:** `Tab` opens a completion menu, `Up`/`Down` search history by prefix, `Ctrl+R` searches history and `Ctrl+T` inserts files through fzf, and PowerShell 7 shows predictions from history and tab completion in a list. Windows PowerShell 5.1 gets the colors and the Tab, Up/Down, Ctrl+D and Ctrl+W keys; predictions, the fzf chords, posh-git and Terminal-Icons are PowerShell 7 only, because its PSReadLine is older and the modules are installed for PowerShell 7.
- **tmux:** The configuration is linked to `~/.config/tmux/tmux.conf` and TPM installs plugins under `~/.config/tmux/plugins/`. The bootstrap installs the plugins; press `prefix + I` (Ctrl+A, I) if one is missing after editing the plugin list. The linker removes the old `~/.tmux.conf` link, because tmux would load both files; a `~/.tmux/plugins` directory from before the move can be deleted.
- **tmux keys** (prefix is Ctrl+A): `h j k l` select panes and `Ctrl+h/j/k/l` do so without the prefix, across tmux panes and Neovim splits alike; `y` in copy mode and mouse selections copy to the system clipboard (`wl-clipboard` on Wayland and `xsel` on X11 come from the apt list; `clip.exe` serves WSL); `F` opens tmux-fzf over sessions, windows and panes; `` ` `` toggles a floating scratch pane (floax), the tmux counterpart of Ghostty's quick terminal; `T` opens sesh to jump to or create a session from zoxide directories and `L` returns to the last one; `Ctrl+S` saves and `Ctrl+R` restores the session layout, and continuum does both automatically. The status line shows the directory, session, CPU, battery and time in Catppuccin.
- **Neovim:** The configuration is `config/nvim`, linked whole to `~/.config/nvim` (Windows: every file managed into `%LOCALAPPDATA%\nvim`). Plugins are pinned in `lazy-lock.json` and installed by the bootstrap at exactly those commits; nothing is fetched when Neovim starts. After `:Lazy update` commit the lockfile, and run the bootstrap or the update (or `scripts\install_runtimes.ps1`) on other machines to follow it. The update also brings the parsers to the revisions the pinned nvim-treesitter names and the language servers to their latest versions. Tree-sitter parsers and language servers (Lua, Bash, TypeScript, Python, JSON, YAML, TOML, Markdown, PowerShell) are listed in `config/nvim/lua/dotfiles/tools.lua`; the bootstrap installs them headless through nvim-treesitter and Mason, and `doctor` reports each one. Completion is Neovim's own (`Ctrl+Y` accepts); `:Mason` and `:checkhealth` show the tooling state.
- **Neovim keys:** the leader is `Space`. `Space Space` or `Space f f` finds files, `Space /` greps, `Space f b` lists buffers, `Space f .` resumes the last picker, `Space ?` shows the keys that apply in the current buffer and `Space` alone waits to show the groups (find, git, search, diagnostics, buffer). LSP: `gd` goes to the definition, `grr` lists references, `grn` renames, `gra` offers code actions, `K` hovers, `Space c f` formats; `]d`/`[d` step through diagnostics and `Space x x` lists them. Git: `]c`/`[c` step through hunks, `Space g s`/`Space g r` stage or reset one, `Space g p` previews it, `Space g b` blames the line, `Space g g` opens the status picker. `Ctrl+h/j/k/l` move between splits and on into tmux panes.
- **Neovim on Linux:** Debian 12 (0.7), Debian 13 (0.10), Ubuntu 24.04 (0.9) and Ubuntu 26.04 (0.11) package older releases than the configuration needs, so the bootstrap unpacks the GitHub release into `~/.local/opt/nvim` (`DOTFILES_LOCAL_OPT` chooses another directory) and links `~/.local/bin/nvim`; the tree-sitter CLI comes from its GitHub release and `build-essential` from apt. Rerunning the bootstrap keeps them; `scripts/update.sh` replaces them when a newer release is out, and never replaces a working tree-sitter CLI with a release that does not run on this glibc. The tree-sitter releases are built against glibc 2.39, newer than Debian 12's 2.36: on Debian 12 a release either does not start (arm64) or starts with a glibc warning and then hangs Neovim's parser install (x86_64), so where the loader complains about glibc the bootstrap leaves the release out and records that in `~/.local/state/dotfiles/tree-sitter-unsupported`, reruns fetch only a newer release, the doctor marks the CLI and the parsers as skipped, and Neovim highlights those file types with Vim's syntax files as on Windows without a compiler.
- **Neovim on Windows:** compiling a Tree-sitter parser needs a C compiler, which winget does not install for you. Without one the doctor marks the parsers as skipped and Neovim falls back to Vim's regex highlighting for those file types. To build them, install the Visual Studio Build Tools with the C++ workload (`winget install --id Microsoft.VisualStudio.2022.BuildTools --exact --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"`), reopen the terminal and rerun `scripts\install_runtimes.ps1`. If the files under `%LOCALAPPDATA%\nvim` are copies rather than links (symbolic links unavailable), `:Lazy update` changes the copy of `lazy-lock.json`; copy it back to the repository before committing.
- **fastfetch:** New interactive shells start with a machine summary in Catppuccin colors; tmux panes and non-interactive shells skip it. Set `DOTFILES_FASTFETCH=0` in `~/.zshrc.local` (or `$env:DOTFILES_FASTFETCH = '0'` in `~/.powershell.local.ps1`) to turn it off; the modules are in `config/fastfetch/config.jsonc`.
- **tmux colors:** tmux identifies itself as `tmux-256color` for italics and forces true color through every host terminal, including Windows Terminal and WSL. Linux gets the terminfo from the `ncurses-term` package. If a remote host you `ssh` into from tmux lacks that terminfo, prefix the command with `TERM=screen-256color`.
- **Theme:** Every tool uses one Catppuccin flavor, recorded in `config/catppuccin/flavor`: tmux, the prompt, eza, bat and fzf, including tab-completion menus. `bash scripts/theme.sh <flavor>` switches all of them at once and [docs/theming.md](docs/theming.md) lists every location. bat 0.26+ ships the themes; the bootstrap installs the current one for older distribution packages.
- **fzf keys:** `Ctrl+T` inserts files, `Ctrl+R` searches history, `Alt+C` changes directory, and `Tab` completion opens the same fzf window.
- **Shell:** The Unix configuration is for zsh. If your default shell is Bash or another shell, run `exec zsh` to use it in the current terminal. To change your default shell, run `chsh -s "$(command -v zsh)"` yourself, then sign out and back in; the installer does not change it automatically.
- **Runtimes:** mise installs the Node.js LTS pinned in `config/mise/config.toml` and switches versions per project from `.tool-versions`, `.nvmrc` or `.node-version` files. zsh puts mise's shims directory on `PATH` rather than running `mise activate`, which keeps shell startup fast; project `[env]` sections in mise files are therefore not applied (use direnv). PowerShell runs `mise activate`. `mise use -g node@22` changes the global default, `mise use python@3.13` adds a runtime to a project, `mise ls` shows what is installed. An existing nvm installation is left alone and no longer loaded; remove `~/.nvm` when you are sure nothing else needs it.
- **Completion:** carapace completes over a thousand commands in zsh and PowerShell; `Tab` opens the menu in both shells. Run `carapace --clear-cache` after installing new tools.
- **History:** atuin owns `Ctrl+R` in the shell (tmux has its own `prefix Ctrl+R` for restoring sessions) with fuzzy search over a local SQLite database; `Up` stays plain zsh history. Sync between machines is opt-in: `atuin register` or `atuin login`, then `atuin sync`. PowerShell support needs atuin 18.11 or newer, which winget installs.
- **Git:** `~/.config/git/config` holds the shared settings (delta as pager, zdiff3 conflicts, rebase on pull, autosquash, sorted branches, a global ignore in `~/.config/git/ignore`). Identity and credential helpers stay in `~/.gitconfig`, which git reads afterwards and which `git config --global` writes to; the linker creates an empty one when it is missing, so those writes never land in the managed file. `lazygit` and `lazydocker` use the same Catppuccin colors.
- **Abbreviations:** zsh-abbr expands `g`, `gs`, `gc`, `lg` and friends on `Space` or `Enter`; `abbr add name=command` adds one and rewrites the tracked `config/zsh-abbr/user-abbreviations` through the linked directory, so commit the change. you-should-use reminds you of an alias after a command runs.
- **Colors on Linux:** vivid 0.9 or newer carries the Catppuccin `LS_COLORS`; Debian 12 ships 0.8, so completion menus there fall back to the terminal palette until vivid is updated (`cargo install vivid` or the GitHub release).
- **Files:** `y` opens yazi and changes to the directory you quit in. `fd` and `rg` replace `find` and `grep` (Debian installs fd as `fdfind`; the shell aliases it and the bootstrap links it as `fd` in `~/.local/bin` for tmux and scripts). `Ctrl+T` and `Alt+C` use fd, so ignored files stay out of the way.
- **Font:** Ghostty and the Windows Terminal fragment select `CaskaydiaCove Nerd Font Mono` themselves (some pickers list it as `CaskaydiaCove NFM`); choose it by hand in any other terminal. On Linux the bootstrap installs the Mono family from the latest Nerd Fonts release into `~/.local/share/fonts/CaskaydiaCove` and registers it with fontconfig, unless fontconfig already lists the family from another directory. A rerun keeps the installed copy; `scripts/update.sh` replaces it when Nerd Fonts publishes a newer release (macOS: when Homebrew installed the cask). On Windows the update keeps the installed font. WSL skips it, because Windows Terminal draws WSL's text with the font `install.ps1` installs on Windows.
- **Machine-specific config:** Add anything that shouldn't be in the repo to `~/.zshrc.local` (sourced automatically).
- **SSH agent:** The shared configuration preserves `SSH_AUTH_SOCK`. To use Bitwarden on a particular machine, add `export SSH_AUTH_SOCK="$HOME/.bitwarden-ssh-agent.sock"` to that machine's `~/.zshrc.local`.
- **Tool binaries on Linux:** Tools that Debian and Ubuntu do not package, or package too old, come from signed apt repositories (eza, glow, gum) or from the latest GitHub release into `~/.local/bin` (oh-my-posh, zoxide, mise, lazygit, lazydocker, delta, atuin, carapace, yazi, dust, procs, xh, tlrc, sesh, fastfetch, tree-sitter, and Neovim as described above), each checked against its SHA-256 digest (see Verified downloads). oh-my-posh comes from its release on macOS as well. Set `DOTFILES_LOCAL_BIN` before installing to use another directory; the installers put it on `PATH`. Rerunning the bootstrap keeps them. `scripts/update.sh` fetches a tool again when its project has a newer release than the tag recorded under `~/.local/state/dotfiles/releases/`. A tool installed before those records existed is fetched once. mise in `~/.local/bin` updates itself with `mise self-update`, and a tool found elsewhere on `PATH` is left to whatever installed it.
- **Windows machine-specific config:** Put private or machine-only PowerShell settings in `~/.powershell.local.ps1`.
- **Verify:** Run `scripts/doctor.sh` on Unix/WSL or `scripts\doctor.ps1` in PowerShell. Both installers also run verification before reporting success. Windows checks both PowerShell editions' actual profile locations, including redirected Documents folders, detects stale copied configurations, and confirms each PowerShell module is installed for PowerShell 7.
- **Repository checks:** Run `bash scripts/test.sh` before committing installer or configuration changes. The suite checks syntax and uses temporary destinations and mocked installation commands to exercise reruns and failures without installing packages or changing your configuration. Missing optional validation tools are reported as skipped checks. Run `pwsh -NoProfile -NonInteractive -File tests/windows.Tests.ps1` for the Windows behavioral suite alone. CI runs checks on macOS, Linux, and Windows, including Windows PowerShell 5.1 and PowerShell 7.
- **Fresh install:** `bash tests/fresh_install.sh debian:12` (or `debian:13`, `ubuntu:24.04`, `ubuntu:26.04`) installs the checkout in a new container as a user with sudo, with real downloads, then reruns the installer, runs `scripts/update.sh` (after setting every recorded release tag back, so the update fetches each release again), starts an interactive zsh on a pseudo-terminal (which loads every tool's init script) and loads tmux with its plugins, failing on any error they report. It needs Docker and takes several minutes; a Mac runs the arm64 images, and should be told so with `DOCKER_DEFAULT_PLATFORM=linux/arm64`: pulling an image for linux/amd64 retags the local copy, and later runs then emulate x86_64 without saying so. The Fresh install workflow runs it for every image on x86_64, plus a macOS runner, on pull requests that touch the Unix install, every Monday, and on demand from the Actions tab, so upstream changes such as a renamed release asset show up before the next new machine. GitHub pauses the weekly run after 60 days without a commit; the Actions tab turns it back on.
- **Secrets:** Do not store credentials, private keys, access tokens, or work-only settings in this repository. Restore those through a password manager or another private channel.

## Structure

```
dotfiles/
├── home/           # Symlinked to $HOME/
├── config/         # Tool configuration: atuin, bat, catppuccin (flavor and palette), eza, fastfetch,
│                   # ghostty, git, lazygit, mise, nvim, oh-my-posh, powershell, tmux, windows-terminal,
│                   # yazi, zsh-abbr
├── packages/       # Declarative package lists (brew, apt, winget)
├── scripts/        # Install, symlink, bootstrap, update, doctor and theme-switch scripts
├── tests/          # Isolated installer regression tests
├── docs/           # Roadmap and theming notes
├── install.sh      # Unix entry point
└── install.ps1     # Windows entry point
```

## Scope

The current baseline covers the terminal emulators, terminal tools, shell configuration, prompt configuration, tmux and Neovim, all in one Catppuccin flavor. Other GUI applications and operating-system preferences should be added as opt-in profiles rather than silently changing every machine. Good future profiles include `development`, `personal`, and platform-specific OS settings. Planned work is tracked in [docs/roadmap.md](docs/roadmap.md).
