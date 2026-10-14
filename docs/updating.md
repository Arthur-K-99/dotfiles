# Updating

```sh
git -C ~/dotfiles pull && ~/dotfiles/scripts/update.sh
```

```powershell
git -C $HOME\dotfiles pull; ~\dotfiles\scripts\update.ps1
```

The update does not pull this repository: run `git pull` first to take its changes, and settle any local changes or diverged branches yourself. It then runs the install stages again with `DOTFILES_UPDATE=1` (Windows: `-Update`), so besides adding whatever is missing they upgrade what they installed, and it finishes with the same verification as the installer (the doctor).

## A rerun and an update

A rerun of the installer adds what is missing. What it upgrades depends on the platform:

- **macOS:** none of the declared packages. One `brew install` adds the missing formulae (Homebrew may upgrade their dependencies), and oh-my-posh's release is kept.
- **Debian and Ubuntu:** the packages `packages/apt.txt` lists, since apt refreshes its index and `apt-get install` upgrades a listed package that has a newer candidate. Held packages are left out. eza, glow and gum, from their own apt repositories, are skipped once present, and the release tools are kept.
- **Windows:** nothing; winget skips every package `winget list` finds.

## What the update upgrades

- **Packages:** the ones `packages/*.txt` declares, after Homebrew refreshes its index. On Linux apt refreshes its index after the signing keys of the eza and Charm repositories are fetched again and checked against their pins ([downloads](downloads.md#verified-downloads)). Homebrew may also upgrade the formulae a declared one depends on and the installed formulae that depend on it; nothing else is touched. Windows upgrades each declared winget package by id; one that `winget upgrade` cannot find (Carapace on winget 1.11) is installed again when winget lists a newer version.
- **Release tools (Linux, and oh-my-posh on macOS):** each tool the bootstrap fetched from a GitHub release, when a newer release exists and is old enough ([release age](downloads.md#release-age)). The installed tag is recorded under `~/.local/state/dotfiles/releases/`; a tool installed before those records existed is fetched once. mise in `~/.local/bin` updates itself with `mise self-update`.
- **Neovim, the tree-sitter CLI and the font on Linux:** replaced when a newer release is old enough. The new one must work before the old one goes: the Neovim tree has to run, the tree-sitter release is staged first, and the previous font directory waits hidden until fontconfig lists the family again. macOS upgrades the font cask when Homebrew installed it; Windows keeps the installed font.
- **Plugins:** zinit and TPM with their plugins, and the yazi flavors (only those the repository names).
- **PowerShell modules (Windows):** the gallery's newest version is installed beside the old one when it is newer.
- **Runtimes:** mise's runtimes (`mise upgrade`, run from the home directory so a project's mise file does not decide).
- **Neovim:** the parsers and the Mason language servers. The plugins stay at the commits `lazy-lock.json` pins.

`DOTFILES_UPDATE=1` also works on a single stage, such as `DOTFILES_UPDATE=1 bash scripts/bootstrap_tools.sh` from `~/dotfiles`.

## What it leaves alone

It says so for each of these:

- tools it did not install, such as a binary on `PATH` from another source. In `~/.local/bin` a plain file with a tool's name counts as the bootstrap's, but a link (pipx, uv and npm make links there) does not;
- a Neovim that the bootstrap did not link, and a font directory without the bootstrap's marker file;
- whatever you pinned or held (`brew pin`, `apt-mark hold`, `winget pin`, a tmux plugin pinned to a tag, which `catppuccin/tmux` is);
- a release tool whose installed release is newer than the one its project now marks latest, as after a project deletes its newest releases;
- a yazi flavor that `~/.config/yazi/package.toml` does not list (put in place by hand);
- on Windows, the PowerShell 7 or Windows Terminal that is running it. Upgrade those from another shell with the `winget upgrade` command it prints. It also leaves packages whose installed version winget cannot tell, and those whose upgrade needs another installer type.

Casks that update themselves, such as Ghostty, are not reported as outdated by Homebrew, so the update leaves them to their own updater without a word.

The "left alone", "pinned" and "keeping" lines are information, not failures; [troubleshooting](troubleshooting.md#messages-that-look-like-errors) lists them.
