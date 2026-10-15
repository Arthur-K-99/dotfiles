# Troubleshooting

The installer prints a `==>` line per stage and stops at the first stage that fails, with `Setup stopped during: <stage>` (Windows: `<stage> failed:`) and the command to rerun; completed steps and backups stay. The doctor (`~/dotfiles/scripts/doctor.sh`, Windows `~\dotfiles\scripts\doctor.ps1`) lists every check as `[ok]`, `[skip]` or a failure (`[missing]`, `[stale]`; Windows also `[missing or stale]` and `[failed]`), with a hint for most failures; a hint that names a script gives its full path.

Behaviour that is not fully explained, or caused upstream, is under [Known issues](roadmap.md#known-issues) in the roadmap.

## Messages that look like errors

None of these is a failure.

- **The doctor's `[skip]` lines** mark what a platform does without on purpose:
  - `[skip] tree-sitter CLI (… needs a newer glibc than 2.36; …)` and `[skip] Neovim parser …` on Debian 12, whose glibc is too old for the tree-sitter releases ([Linux](linux.md#neovim-and-the-tree-sitter-cli));
  - `[skip] Neovim parser … (no C compiler or tree-sitter CLI; …)` on Windows without the Visual Studio Build Tools ([Windows](windows.md#neovim));
  - `[skip] CaskaydiaCove Nerd Font Mono (WSL uses the Windows font, …)` under WSL.
- **The doctor on Linux** always says `Ghostty has no Debian package; its configuration is linked for when it is installed.`
- **Release age notes** while installing or updating ([release age](downloads.md#release-age)):
  - `<project> <tag> dates from <time>, less than 1d ago; taking <older tag>.` The latest release is younger than a day, so an older one was installed.
  - `…; keeping <installed tag>.` The update keeps the installed release until a newer one is old enough.
  - `<project> <tag> is newer than its latest release, <tag>; keeping it.` The project deleted or unmarked its newest release.
  - mise's own `Selected mise <version> (minimum release age: 86400s)` during the update.
  - On Debian 12: `tree-sitter <tag> needs glibc 2.39 and this system has 2.36; Neovim will skip compiling parsers …`, and on later runs `tree-sitter <tag> does not run on glibc 2.36; Neovim keeps skipping the parsers`.
- **The update's "left alone" lines** ([updating](updating.md#what-it-leaves-alone)): `… not installed by the bootstrap; left alone`, `pinned, left alone: …`, `held, left alone: …`, and on every update `tmux plugin catppuccin/tmux is pinned to v2.3.1; left alone`. On Windows, `left alone: Microsoft.PowerShell runs this update (from another shell: …)`, `upgraded: <id> (installed again: winget upgrade cannot find it)` for Carapace on winget 1.11, and `installed: <id> (restart Windows to finish)` or `upgraded: <id> (restart Windows to finish)`, after which the doctor tells whether the package already works.
- **apt repository keys:**
  - `Could not fetch the <name> repository's key from …; its keyring stays as it is.` during an update: the download failed and the doctor checks the existing keyring.
  - `[ok] charm apt repository key (expires on <date>; scripts/update.sh fetches it again)` within 30 days of the expiry.
- **`The GitHub API refused GITHUB_TOKEN (HTTP <401 or 403>); trying once without it.`** The token has expired or is for another host (401), or is over its limit or kept out of an organization (403); the request goes on without it.
- **`curl: (22) The requested URL returned error: 502`, `curl: (28) ...` or `curl: (6) Could not resolve host`,** one line per failed try, with pauses between them: curl is retrying ([timeouts and retries](downloads.md#timeouts-and-retries)). The run fails only when the last try fails.
- **Without a terminal** (cron, some IDE tasks and agent shells), zsh-you-should-use prints `tput: No value for $TERM`, and on Debian 12 fzf 0.38 prints `can't change option: zle`. A real terminal never shows either.
- **`Warning: The following taps are not trusted:`** when a macOS update upgrades a Homebrew formula. It names taps you added yourself, such as `hashicorp/tap`. Homebrew 7 ignores their formulae until you trust them (`brew trust --formula <tap>/<formula>`); the dotfiles install nothing from a tap, so the update is unaffected.
- **In a container,** dbus's package script prints `invoke-rc.d: could not determine current runlevel`; that comes from the container, not the installer.
- **Backups:** `backing up <file> -> <file>.bak.<timestamp>` (Windows: `backed up: <file> -> <backup>`) and `Your previous ~/.zshrc is in …` are the linker keeping your files. On Windows, `copied (symbolic links unavailable)` means a copy instead of a link ([Windows](windows.md#links-or-copies)).

## First-try problems

- **New terminals or tmux panes start without the configuration:** your login shell is not zsh. Run `chsh -s "$(command -v zsh)"`, then sign out and back in; the installer prints this command when it applies.
- **Icons show as boxes:** the terminal is not using the Nerd Font. On macOS open Ghostty rather than Terminal.app; in Windows Terminal set the WSL profile's font ([Windows](windows.md#windows-terminal)); elsewhere select `CaskaydiaCove Nerd Font Mono`.
- **Windows Terminal looks unchanged:** restart it, since it reads the fragment only when settings load. WSL profiles never get the fragment.
- **PowerShell shows another prompt or other keys:** a `Microsoft.PowerShell_profile.ps1` runs after the managed profile ([Windows](windows.md#existing-configurations)).
- **"running scripts is disabled on this system":** run `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser` once.
- **"winget is required":** install App Installer from the Microsoft Store; Windows Sandbox has no winget.
- **"… is unavailable after package installation. Reopen PowerShell and rerun install.ps1":** the running shell does not see what winget just installed; open a new one and rerun.
- **"Program 'oh-my-posh.exe' failed to run: The file cannot be accessed by the system":** winget's oh-my-posh, an MSIX package, could not be started at the font step. It happened once in 13 CI installs, and the next attempt, on a new machine, passed; whether a rerun on the same machine clears it is untested. Open a new PowerShell and rerun `install.ps1`. If oh-my-posh still will not start, the prompt will not either ([roadmap](roadmap.md), [oh-my-posh#7833](https://github.com/JanDeDobbeleer/oh-my-posh/issues/7833)).
- **"Without a token GitHub answers 60 requests an hour per address":** wait an hour, or set `GITHUB_TOKEN` and rerun ([downloads](downloads.md#the-github-api-limit)). The same message ends a run whose connection failed or timed out (`curl: (6)` or `curl: (28)` lines before it); then check the connection instead ([timeouts and retries](downloads.md#timeouts-and-retries)).
- **"No release of … among the 30 most recent is older than 1d":** a tool that is not installed yet has no release old enough, or the clock is behind (the message then says so). Fix the clock, or rerun with `DOTFILES_MINIMUM_RELEASE_AGE=0`.
- **`ssh host cmd` prints `Setting up xterm-ghostty terminfo on <host>...` and the output twice:** the 1.0.0 configuration turned on Ghostty's `ssh-terminfo`, which in Ghostty 1.3.1 runs the command on a first connection too. Update, then open a new Ghostty window or tab; shells already open keep the old setting ([Ghostty](tools.md#ghostty)).
- **Something of yours is in the way:** `~/.local/bin/nvim exists and is not a link` or `~/.local/share/fonts/CaskaydiaCove exists and the bootstrap did not install it`. Move it away and rerun.
- **sudo asks for the password again** during the bootstrap: it remembers it only for some minutes ([Linux](linux.md#sudo)).
- **"Unsupported Linux distribution":** only Debian, Ubuntu and their derivatives are supported.
- **The doctor reports `~/.tmux.conf`:** run the `link_dotfiles.sh` command it names, which backs the file up, and keep what you need in `~/.config/tmux/local.conf`.
- **tmux shows "TPM is missing":** run `bash ~/dotfiles/scripts/bootstrap_tools.sh`, with your clone's path if it is elsewhere.
- **"Could not initialize the tool environment. Check Homebrew":** `brew shellenv` failed; check that Homebrew runs, then rerun.
- **Neovim is older than 0.12 on macOS:** `brew upgrade neovim`, then rerun.
- **An old oh-my-posh stays on macOS:** the update says `oh-my-posh not installed by the bootstrap; left alone` and `oh-my-posh version` prints an old release. A copy from Homebrew's former `jandedobbeleer/oh-my-posh` tap, which Homebrew 7 refuses to load, still sits in `/opt/homebrew/bin`. Remove that file, then `brew uninstall --formula --force oh-my-posh` (plain `brew uninstall oh-my-posh` stops at the same refusal), `brew untap jandedobbeleer/oh-my-posh`, and rerun `bash ~/dotfiles/scripts/update.sh`, which installs the current release into `~/.local/bin`.
- **git ignores a shared setting:** `~/.gitconfig` is read after `~/.config/git/config`, so an old setting there wins, such as a `core.pager` that hides delta.

## Undo an install

On a machine you want back as it was. Run the listing commands first and look at what they print. An earlier Neovim, zinit or mise setup uses some of the same directories, so keep whatever you had before the install.

**macOS and Linux:**

- **The links and the files they replaced.** Each replaced file sits beside its link as `<name>.bak.<timestamp>`:

  ```sh
  # The links into the repository, then the backups to rename back. Only the
  # home directory itself and ~/.config are searched: on macOS, reading
  # Documents or Library triggers privacy prompts.
  find ~ -maxdepth 1 -type l -lname "$HOME/dotfiles/*"; find ~/.config -maxdepth 2 -type l -lname "$HOME/dotfiles/*"
  find ~ -maxdepth 1 -type l -lname "$HOME/dotfiles/*" -delete; find ~/.config -maxdepth 2 -type l -lname "$HOME/dotfiles/*" -delete
  find ~ -maxdepth 1 -name '*.bak.[0-9]*'; find ~/.config -maxdepth 2 -name '*.bak.[0-9]*'
  ```

  `~/.gitconfig` was created only if it was missing, with two comment lines.
- **The downloaded state:**

  ```sh
  rm -rf ~/.local/share/zinit ~/.local/share/nvim ~/.local/share/mise ~/.local/share/fonts/CaskaydiaCove \
      ~/.config/tmux/plugins ~/.config/yazi/flavors ~/.local/opt/nvim ~/.local/state/dotfiles ~/.cache/dotfiles \
      ~/.local/state/nvim ~/.cache/nvim ~/.local/state/mise ~/.cache/mise ~/.cache/zinit
  fc-cache -f                    # Linux: forget the removed font
  ```

  Also `~/.config/yazi/package.toml`, which ya wrote; the bat theme the bootstrap added for bat older than 0.26 (`~/.config/bat/themes/Catppuccin *.tmTheme`, then `bat cache --clear`; Debian and Ubuntu name it `batcat`); `~/.npm`, where Mason's npm installs left a cache, if nothing else of yours uses npm; and the tools the bootstrap put in `~/.local/bin`: on Linux `oh-my-posh`, `zoxide`, `mise`, `lazygit`, `lazydocker`, `delta`, `atuin`, `carapace`, `yazi`, `ya`, `dust`, `procs`, `xh`, `tldr`, `sesh`, `fastfetch`, `tree-sitter` and the `nvim` and `fd` links; on macOS `oh-my-posh`. Tools you used keep data of their own, such as atuin's history in `~/.local/share/atuin`.
- **Linux, the apt repositories and packages:**

  ```sh
  sudo rm /etc/apt/sources.list.d/gierens.list /etc/apt/sources.list.d/charm.list \
      /etc/apt/keyrings/gierens.gpg /etc/apt/keyrings/charm.gpg
  sudo apt-get update
  ```

  Then `sudo apt-get remove` whatever you did not have before: eza, glow, gum and the packages in `packages/apt.txt`.
- **macOS, Homebrew:** `brew uninstall` the formulae in `packages/brew.txt` and `brew uninstall --cask` the casks in `packages/brew-casks.txt` (Ghostty and the font) that you did not have before.
- **The login shell:** `chsh -s /bin/bash`, or whichever shell you had.

**Windows:**

- **The profiles and the other replaced files,** each beside its destination as `<name>.bak.<timestamp>`:

  ```powershell
  $docs = [Environment]::GetFolderPath('MyDocuments')
  Get-ChildItem -Recurse -Force -Filter '*.bak.*' "$docs\PowerShell", "$docs\WindowsPowerShell", "$HOME\.config", "$env:LOCALAPPDATA\nvim" -ErrorAction SilentlyContinue
  ```

  Remove the managed files ([Windows](windows.md#links-or-copies) lists them) and rename each backup back.
- **The Windows Terminal fragment:** the folder `%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\dotfiles`.
- **Neovim:** `%LOCALAPPDATA%\nvim-data`, and `%LOCALAPPDATA%\nvim` only if it held nothing of yours before; otherwise remove just the managed files, as above.
- **yazi and mise:** `~\.config\yazi\flavors` and `~\.config\yazi\package.toml`, and `%LOCALAPPDATA%\mise`.
- **The font:** CaskaydiaCove Nerd Font, under Settings > Personalization > Fonts.
- **The modules,** in PowerShell 7: `Uninstall-Module Terminal-Icons, PSFzf, posh-git, CompletionPredictor -AllVersions`.
- **The packages:** `winget uninstall --id <id> --exact` for those in `packages/winget.txt` that you did not have before.

## Report a problem

Keep a log of the run:

```sh
~/dotfiles/install.sh 2>&1 | tee ~/dotfiles-install.log
```

```powershell
Start-Transcript ~\dotfiles-install.log
~\dotfiles\install.ps1
Stop-Transcript
```

A report needs:

- the operating system, its version and the architecture (`cat /etc/os-release`, `sw_vers` or `cmd /c ver`, and `uname -m`);
- the commit: `git -C ~/dotfiles rev-parse --short HEAD`;
- the `==>` stage where it stopped, with the lines before the failure message;
- the doctor's output: `~/dotfiles/scripts/doctor.sh` or `~\dotfiles\scripts\doctor.ps1`.
