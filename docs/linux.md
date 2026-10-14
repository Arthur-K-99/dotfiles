# Linux and WSL

The Unix installer accepts Debian, Ubuntu and distributions whose `/etc/os-release` names either of them (`ID` or `ID_LIKE`), on x86_64 and arm64. Debian 12 and 13 and Ubuntu 24.04 and 26.04 are tested in containers; other derivatives are not. WSL runs the same install inside a Debian or Ubuntu distribution.

## sudo

- The package stage runs `apt-get update` and `apt-get install` through sudo.
- The bootstrap uses sudo again to add the eza and Charm apt repositories (their keys, sources lists and packages), a few minutes later, and the update to refresh their keys.
- sudo remembers a password only for some minutes, so it may ask again during the bootstrap.

## Where each tool comes from

- **apt:** `packages/apt.txt`, including `build-essential` (the C compiler for Neovim's parsers), `fontconfig`, `ncurses-term`, `wl-clipboard` and `xsel`. `wl-clipboard` is installed without its recommended packages, which would bring Mesa and a terminal emulator.
- **Signed apt repositories:** eza from `deb.gierens.de`, glow and gum from `repo.charm.sh`. Each is added only with its pinned key ([downloads](downloads.md#verified-downloads)): `/etc/apt/sources.list.d/{gierens,charm}.list` and `/etc/apt/keyrings/{gierens,charm}.gpg`.
- **GitHub releases into `~/.local/bin`:** tools that Debian and Ubuntu do not package, or package too old: oh-my-posh, zoxide, mise, lazygit, lazydocker, delta, atuin, carapace, yazi (with `ya`), dust, procs, xh, tlrc (`tldr`), sesh, fastfetch and tree-sitter, plus Neovim as below. Each is the latest release old enough ([release age](downloads.md#release-age)) and is checked against its SHA-256 digest. oh-my-posh comes from its release on macOS as well.
- **Reruns** keep the tools. `scripts/update.sh` fetches a tool again when its project has a newer release than the tag recorded under `~/.local/state/dotfiles/releases/` and that release is old enough. A tool installed before those records existed is fetched once. mise in `~/.local/bin` updates itself with `mise self-update`, and a tool found elsewhere on `PATH` is left to whatever installed it ([updating](updating.md)).
- **Another directory:** set `DOTFILES_LOCAL_BIN` before installing to use another directory than `~/.local/bin`; the installers put it on `PATH`. Export it from `~/.zshenv` too (`~/.zshrc.local` loads after `PATH` is built), so `~/.zshrc` puts it before `~/.local/bin`.

## Neovim and the tree-sitter CLI

- Debian 12 (0.7), Debian 13 (0.10), Ubuntu 24.04 (0.9) and Ubuntu 26.04 (0.11) package older releases than the configuration needs (0.12). The bootstrap unpacks the GitHub release into `~/.local/opt/nvim` (`DOTFILES_LOCAL_OPT` chooses another directory) and links `~/.local/bin/nvim`. A Neovim that is new enough, from any source, is kept.
- The tree-sitter CLI, which compiles the parsers, comes from its GitHub release; `build-essential` from apt.
- Rerunning the bootstrap keeps them. `scripts/update.sh` replaces them when a newer release is out and old enough, and never replaces a working tree-sitter CLI with a release that does not run on this glibc.
- **Debian 12:** the tree-sitter releases are built against glibc 2.39, newer than Debian 12's 2.36. There a release either does not start (arm64) or starts with a glibc warning and then hangs Neovim's parser install (x86_64). So where the loader complains about glibc:
  - the bootstrap leaves the release out and records that in `~/.local/state/dotfiles/tree-sitter-unsupported`;
  - reruns fetch only a newer release;
  - the doctor marks the CLI and the parsers as skipped;
  - Neovim highlights those file types with Vim's syntax files, as on Windows without a compiler.

## Command names

- Debian and Ubuntu install fd as `fdfind`. The shell aliases it, and the bootstrap links it as `~/.local/bin/fd` for tmux and scripts.
- bat installs as `batcat`; the `cat` alias and the fzf previews use whichever name exists.

## Font

The bootstrap installs CaskaydiaCove Nerd Font Mono from the latest Nerd Fonts release old enough into `~/.local/share/fonts/CaskaydiaCove` and registers it with fontconfig, unless fontconfig already lists the family from another directory.

- A rerun keeps the installed copy; `scripts/update.sh` replaces it when Nerd Fonts publishes a newer release and it is old enough.
- A `CaskaydiaCove` directory without the bootstrap's marker file belongs to you: the bootstrap stops and asks you to move it away, and the update leaves it alone.
- The doctor fails without the font, also on a server reached only over SSH, where the client draws the text ([roadmap](roadmap.md) to-do).
- Select the font in your terminal unless it is Ghostty, which selects it itself.

## Colors

vivid 0.9 or newer carries the Catppuccin `LS_COLORS`. Debian 12 ships 0.8, so completion menus there fall back to the terminal palette until vivid is updated (`cargo install vivid` or the GitHub release).

## Clipboard

tmux-yank and Neovim copy to the system clipboard with `wl-copy` on Wayland and `xsel` on X11, both from the apt list. Under WSL tmux-yank uses `clip.exe`, and so does Neovim when no display is set (it pastes through `powershell.exe` then).

## Ghostty

There is no Debian or Ubuntu package. Install Ghostty from [ghostty.org](https://ghostty.org/download); the configuration is already linked, which the doctor says on every run. It reloads with `Ctrl+Shift+,` on Linux. Without Ghostty, choose `CaskaydiaCove Nerd Font Mono` in your terminal.

## WSL

- **Installing WSL** is a host action, because it can need administrator approval and a restart: run `wsl --install` in an administrator PowerShell, restart if asked, then run `install.sh` inside the distribution, not in Windows PowerShell.
- WSL uses the same Linux packages and dotfiles as a regular Debian or Ubuntu machine.
- **Font:** Windows Terminal draws WSL's text with a Windows font, so the bootstrap skips the Linux font and the doctor prints `[skip]` for it. Only `install.ps1` installs the Nerd Font on Windows; without it, download `CascadiaCode` from the [Nerd Fonts releases](https://github.com/ryanoasis/nerd-fonts/releases) and install the `CaskaydiaCoveNerdFontMono` files on Windows.
- **Windows Terminal:** its fragment cannot change WSL profiles, so a WSL profile keeps Cascadia Mono and the default colors until you set them ([Windows](windows.md#windows-terminal)).
- **Login shell:** after `chsh -s "$(command -v zsh)"`, a new WSL tab starts zsh.
- Docker on a Windows host counts as WSL too, since containers share the WSL2 kernel ([known issue](roadmap.md#known-issues)).
