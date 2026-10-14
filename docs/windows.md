# Windows

Windows and WSL share one repository but are separate environments:

| Environment | Installer | Managed shell |
|---|---|---|
| Native Windows | `install.ps1` | PowerShell |
| WSL Debian/Ubuntu | `install.sh` inside WSL | zsh |

WSL is a Linux install; [Linux and WSL](linux.md#wsl) covers it, and the [Windows Terminal](#windows-terminal) section below covers its profile. `install.ps1` is installed for real every week on a clean Windows Server 2025 machine in CI, with a rerun, the update and the doctor ([development](development.md#fresh-install)); a desktop Windows 11 has not been tried yet.

## What install.ps1 does

Native Windows installs PowerShell, Windows Terminal and the command-line tools through winget, PowerShell modules from the PowerShell Gallery, and Node.js through mise. It manages the PowerShell profile, oh-my-posh, git, the tool configurations and a Windows Terminal settings fragment. It prints one `==>` line per stage:

1. **Installing packages:** each package in `packages/winget.txt` that `winget list` does not find, then the Nerd Font: `oh-my-posh font install` with the archive's download URL from the latest Nerd Fonts release (a font name would make oh-my-posh ask GitHub's API, without a token).
2. **Installing PowerShell modules:** Terminal-Icons, PSFzf, posh-git and CompletionPredictor, for the current user and for PowerShell 7 only.
3. **Linking dotfiles:** the managed files below.
4. **Installing runtimes:** mise's runtimes (Node.js LTS), the yazi flavors, and Neovim's plugins, parsers and language servers.
5. **Verifying setup:** the doctor, `scripts\doctor.ps1`.

Each stage also runs alone: `scripts\install_packages.ps1`, `install_modules.ps1`, `link_dotfiles.ps1`, `install_runtimes.ps1` and `doctor.ps1`. The doctor checks both PowerShell editions' actual profile locations, including redirected Documents folders, detects stale copied configurations, and confirms each PowerShell module is installed for PowerShell 7.

## Before you start

- **winget** must work. The installer stops without it and asks you to install App Installer from the Microsoft Store. Windows Sandbox has none.
- **Git first:** `winget install --id Git.Git --exact`, then reopen PowerShell before cloning.
- **Script policy:** `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser`, once.
- **Elevation** is optional and decides only whether the managed files are links or copies (next section). Run the installer as your own account, since it installs into `$HOME`. winget may ask for administrator approval for packages that install for all users.

## Links or copies

The installer links each managed file where Windows allows symbolic links: in an elevated PowerShell, or with Developer Mode on (Settings > System > For developers) in PowerShell 7. Windows PowerShell 5.1, which runs the first install on a new machine, checks for elevation itself, so Developer Mode is not enough there. Where links fail for want of privilege, the installer copies the file and prints `copied (symbolic links unavailable)`.

- A copy does not follow the repository. After a `git pull` the doctor reports it as `[missing or stale]` until `install.ps1` or `scripts\update.ps1` replaces it, backing up the old copy first.
- `:Lazy update` and `mise use -g` change the copy of `lazy-lock.json` or `config.toml`, not the repository's: copy the file back before committing.
- A copy that still matches counts as installed, so a rerun keeps it. To switch to links, delete the copies and rerun elevated, or from PowerShell 7 with Developer Mode on.

The managed files:

- `profile.ps1` in `Documents\PowerShell` and `Documents\WindowsPowerShell` (each edition's `$PROFILE.CurrentUserAllHosts`, asked from the shell itself, so a redirected Documents folder is found);
- under `~\.config`: `oh-my-posh\config.omp.json`, `bat\config`, `eza\theme.yml`, `git\config`, `git\ignore`, `git\catppuccin.gitconfig`, `lazygit\config.yml`, `yazi\yazi.toml`, `yazi\theme.toml`, `atuin\config.toml`, the four `atuin\themes\*.toml`, `fastfetch\config.jsonc` and `mise\config.toml`;
- `fragment.json` in `%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\dotfiles\`;
- every file of `config/nvim`, one by one, in `%LOCALAPPDATA%\nvim`.

`~\.gitconfig` is created once, empty but for a comment, when it is missing.

## Existing configurations

- A file the installer replaces is moved to `<name>.bak.<timestamp>` beside it first.
- **`Microsoft.PowerShell_profile.ps1`** (`$PROFILE.CurrentUserCurrentHost`, beside the managed `profile.ps1`) is not managed and still runs after it, so a prompt, alias or key it sets wins. Move what you need into `~\.powershell.local.ps1` and remove the file.
- **`%LOCALAPPDATA%\nvim`** is not replaced as a whole: files there that the repository does not have stay and mix with the managed ones. A `lua\plugins\*.lua` there is loaded as a plugin spec, and an `init.vim` conflicts with the managed `init.lua`. Move such files away before installing.

## Windows Terminal

The fragment adds the Catppuccin scheme of the current flavor and applies it, the Nerd Font, padding and acrylic to the PowerShell 7, Windows PowerShell and Command Prompt profiles, without touching `settings.json`.

- Restart Windows Terminal after installing, or save `settings.json` once: fragments are read only when settings load.
- Fragments cannot change global settings or WSL profiles. Set these once in Settings:
  - **Default profile:** Startup > Default profile > PowerShell, or `"defaultProfile": "{574e775e-4f2a-5b96-ac1e-a2962a402336}"` in `settings.json`.
  - **WSL profiles:** in the distribution's profile (or Defaults, for every profile), Appearance > Color scheme > `Catppuccin <flavor>` (the flavor in `config/catppuccin/flavor`) and Font face > `CaskaydiaCove Nerd Font Mono`. Until then WSL keeps Cascadia Mono, where the prompt's and eza's icons show as boxes. The font is on Windows only after `install.ps1` ([Linux and WSL](linux.md#wsl) says how to get it without).

## PowerShell

- **Keys:** `Tab` opens a completion menu, `Up`/`Down` search history by prefix, `Ctrl+R` searches history with atuin (with PSFzf where atuin's PowerShell integration does not load), `Ctrl+T` inserts files through fzf, `Ctrl+D` exits on an empty line and `Ctrl+W` deletes a word. PowerShell 7 shows predictions from history and tab completion in a list.
- **Windows PowerShell 5.1** gets the colors and the Tab, Up/Down, Ctrl+D and Ctrl+W keys. Predictions, the fzf chords, posh-git and Terminal-Icons are PowerShell 7 only, because its PSReadLine is older and the modules are installed for PowerShell 7. atuin's PowerShell support needs atuin 18.11 or newer, which winget installs.
- **Aliases** as in zsh: `cd` is zoxide, `ls` is eza and `la`, `ll` and `tree` call it, `cat` is bat, `vim` is nvim, and `y` opens yazi and changes to the directory you quit in. There is no `c`; `cls` clears.
- **Completion:** carapace through the Tab menu.
- **mise:** PowerShell runs `mise activate`, so a project's `[env]` section applies here, unlike in zsh.
- **direnv** loads in PowerShell 7.2 and newer only; its hook throws in Windows PowerShell. Windows sets no `HOME`, which direnv needs for its own directories, so the profile sets it to your home directory when it is unset, and points `DIRENV_BASH` at Git for Windows' bash, which runs `.envrc` files and is not on `PATH` by default.
- **Non-interactive shells** (`pwsh -Command`, `pwsh -File`, editor tasks) skip the PSReadLine setup: keys, colors, predictions, carapace, atuin and PSFzf. In such a shell CompletionPredictor would deadlock PowerShell 7 as the command finishes, and oh-my-posh's init loads PSReadLine even there, so the profile notes before anything else whether the shell loaded PSReadLine itself.
- **Machine-local settings** go in `~\.powershell.local.ps1`, which the profile loads after its own settings.
- **fastfetch** greets the console host only, and not shells started with `-Command`, `-File`, `-EncodedCommand` or `-NonInteractive`. `$env:DOTFILES_FASTFETCH = '0'` in `~\.powershell.local.ps1` turns it off.
- One profile serves both editions and loads every tool and module only when it is present. It stays ASCII (glyphs as code points) because Windows PowerShell reads scripts without a byte-order mark as ANSI.

## Neovim

- The configuration is managed into `%LOCALAPPDATA%\nvim` and the plugins live in `%LOCALAPPDATA%\nvim-data`.
- Compiling a Tree-sitter parser needs a C compiler, which winget does not install for you. Without one the doctor marks the parsers as skipped and Neovim falls back to Vim's regex highlighting for those file types.
- To build them, install the Visual Studio Build Tools with the C++ workload, reopen the terminal and rerun `scripts\install_runtimes.ps1`:

  ```powershell
  winget install --id Microsoft.VisualStudio.2022.BuildTools --exact --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
  ```

## Font

`oh-my-posh font install` installs the whole CaskaydiaCove family, per user, from the latest Nerd Fonts release's `CascadiaCode.zip`. The update keeps it, since nothing records which release it came from, and nothing checks its download against a digest ([downloads](downloads.md#verified-downloads)); the [roadmap](roadmap.md) tracks both.
