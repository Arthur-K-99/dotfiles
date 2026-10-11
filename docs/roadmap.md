# Roadmap

The goal: one terminal experience that looks and behaves the same on macOS, Debian/Ubuntu/WSL and native Windows. Catppuccin Macchiato everywhere, fast shells, strong autocomplete, and every tool declared in this repository so a new machine is one command away.

Work lands in phases. Each phase is one pull request that leaves every platform in a working state, passes `bash scripts/test.sh`, and extends `doctor` so a rebuilt machine proves the phase is installed.

| Phase | Theme | Status |
|---|---|---|
| 1 | Foundations: one flavor, tmux capabilities, fast zsh, fzf, bat | Done ([#1](https://github.com/Arthur-K-99/dotfiles/pull/1)) |
| 2 | Terminal emulators and PowerShell parity | Done ([#3](https://github.com/Arthur-K-99/dotfiles/pull/3)) |
| 3 | New tools: completion engine, history, runtimes, git, TUIs | Next |
| 4 | tmux plugin suite, theme switcher, fastfetch | Planned |
| 5 | Neovim | Planned |

## Adding a tool: the checklist

Every new tool touches the same places. Skipping one means `doctor` lies on the next machine.

1. Package entries in `packages/brew.txt`, `packages/apt.txt` and `packages/winget.txt`. If a platform has no package, add an installer to `scripts/bootstrap_tools.sh` that is safe to rerun and returns a nonzero status on failure.
2. Configuration under `config/<tool>/`, linked by `scripts/link_dotfiles.sh` and, when the tool exists on Windows, by `Get-DotfilesManagedFiles` in `scripts/lib/windows.ps1`. Destinations derive from the home directory so the tests stay isolated.
3. A `doctor` check in `scripts/doctor.sh` (and `Invoke-DotfilesDoctor` on Windows) for the command, the link and any theme or plugin the tool needs.
4. A test in `tests/unix.Tests.sh` for any bootstrap logic: the already-installed path, a failure, and the retry.
5. A line in the README's "What gets installed" table and, if there is anything to know after install, an "After install" bullet.

## Phase 1: Foundations (done)

- One Catppuccin flavor (Macchiato) across tmux, oh-my-posh, eza, fzf and bat.
- tmux: `tmux-256color` for italics, forced RGB, no automatic renaming, renumbered windows, focus events, 50k scrollback, splits in the current path.
- zsh: nvm's default Node on `PATH` without loading nvm (startup 470 ms to 120 ms), fzf keybindings and previews, colored completion menus, larger history, `Ctrl-X Ctrl-E`.
- bat configuration shared across platforms; bootstrap installs the theme for old distribution packages.
- Prompt: git status, execution time, exit status, transient prompt.

## Phase 2: Emulators and PowerShell parity (done)

The emulator is the outermost layer; with it managed, every ANSI-based tool inherits Catppuccin on every platform.

- **Ghostty** (macOS and Linux): `config/ghostty/config`, linked to `~/.config/ghostty/config`, installed by the `ghostty` cask on macOS and by hand on Linux. The theme follows the OS appearance (`theme = light:Catppuccin Latte,dark:Catppuccin Macchiato`; Ghostty wants the names as `+list-themes` prints them, not dashed), CaskaydiaCove Nerd Font Mono, bar cursor, padding, opacity and blur, titlebar tabs, left Option as Alt, Shift+Enter as a newline, and the global quick-terminal hotkey. Ghostty's default keybinds already cover splits and tabs. Cursor shaders and other machine-local settings go in an optional `~/.config/ghostty/local` loaded by `config-file = ?local`. `scripts/test.sh` runs `ghostty +validate-config` on the file wherever Ghostty is installed.
- **Windows Terminal**: a JSON fragment, `config/windows-terminal/fragment.json`, managed into `%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\dotfiles\`. Evaluation result: fragments add color schemes and modify the stock profiles (PowerShell 7, Windows PowerShell, Command Prompt) without rewriting `settings.json`, but cannot set global settings such as the default profile or touch WSL profiles, whose GUIDs are derived per distribution. Those two remain a one-time manual setting documented in the README; owning the whole `settings.json` was not worth losing the user's own edits.
- **PSReadLine**: history predictions in the list view plus CompletionPredictor on PowerShell 7, Catppuccin Macchiato colors written directly as hex (no dependency on the `catppuccin/powershell` module, which is not on the Gallery), zsh-like keys (Tab menu, prefix history search, Ctrl+D, Ctrl+W) and `Ctrl+R`/`Ctrl+T` through PSFzf. Everything degrades by feature detection so the same profile loads in Windows PowerShell 5.1 and in non-interactive shells.
- **PowerShell modules**: `Terminal-Icons`, `PSFzf`, `posh-git`, `CompletionPredictor`, installed for PowerShell 7 by a new `install.ps1` stage that runs `pwsh -NoProfile`, verified by `doctor.ps1`, with tests for the installed, failed and retried paths.
- **eza on Windows** (`eza-community.eza`) with the zsh aliases and the shared `theme.yml` through `EZA_CONFIG_DIR`.
- Decision: Ghostty on macOS/Linux and Windows Terminal on Windows. One WezTerm Lua file for three OSes did not outweigh Ghostty's speed and native feel, and the fragment keeps the Windows side small.

## Phase 3: New tools (next)

Autocomplete and shell quality of life. Everything here exists on all three platforms unless noted.

- **carapace**: one completion engine for over a thousand commands, usable from zsh and PowerShell. This is the single largest autocomplete upgrade and it is the same on every OS.
- **inshellisense** (Microsoft): IDE-style dropdown completion with descriptions for zsh, bash and pwsh. Evaluate alongside carapace; they solve different halves of the problem.
- **atuin**: synced, encrypted, searchable shell history with statistics. Replaces plain `Ctrl+R`. First-class on zsh; PowerShell support is community-maintained, so verify before promising parity.
- **mise**: replaces nvm. Faster, handles Node, Python, Go and more, works on Windows. Removes the lazy-nvm block from `.zshrc` and the nvm bootstrap, doctor and tests.
- **git**: move the global git config into `config/git/` with delta (or difftastic) as pager, aliases, a global ignore file, `rerere`, `push.autoSetupRemote`, and Catppuccin colors for delta.
- **lazygit** and **lazydocker**: both are installed on the Mac already but not declared here. Add packages and Catppuccin configs.
- **yazi**: terminal file manager with image previews and Catppuccin flavors. Works on Windows.
- **vivid**: generated Catppuccin `LS_COLORS`, replacing the hand-written ANSI default in `.zshrc`, with `EZA_COLORS` kept consistent.
- **Modern CLI set**: ripgrep, fd (also the fzf backend through `FZF_DEFAULT_COMMAND`), dust, duf, procs, sd, xh, hyperfine, tokei, glow, tlrc, gum. Debian names fd `fdfind` and bat `batcat`; aliases and the fzf command need both names.
- **Ghostty on Linux**: an installer in `scripts/bootstrap_tools.sh` once a dependable Debian/Ubuntu package exists (the community `.deb` builds or the snap), so the doctor can check the command on Linux as it does on macOS.
- **zsh extras**: zsh-abbr for inline-expanding abbreviations, zsh-you-should-use, pay-respects for command correction, direnv.
- Each tool follows the checklist above; the doctor and tests grow with it.

## Phase 4: tmux, theme switcher, fastfetch

- tmux plugins: tmux-sensible, tmux-yank, vim-tmux-navigator, tmux-resurrect with tmux-continuum, tmux-fzf, tmux-floax for a floating pane, and sessionx or sesh with zoxide for session jumping. Catppuccin status modules for directory, date, CPU and battery.
- Move the tmux config to `~/.config/tmux/tmux.conf`; TPM already prefers that location.
- A `scripts/theme.sh <flavor>` that flips every tool at once. See `docs/theming.md` for the list of places a flavor lives today; the switcher should read one palette file and write the rest, or at least edit every location in one run and leave the repo in a committable state.
- fastfetch with a Catppuccin-colored configuration on new shells, skipped inside tmux and in non-interactive shells so panes stay fast.

## Phase 5: Neovim

Neovim is installed on every platform with no configuration anywhere. This is the largest visual upgrade and its own project.

- Start from LazyVim or kickstart.nvim with the Catppuccin colorscheme matching the terminal flavor.
- `config/nvim/` linked to `~/.config/nvim` on Unix and `%LOCALAPPDATA%\nvim` on Windows.
- Treesitter, LSP for the languages in use, telescope or fzf-lua, which-key, gitsigns, and the tmux navigator keybinds that phase 4 introduces.
- Keep the first version small enough to understand; plugins can be added once the base is stable.

## Repository structure

Not tied to a phase; pick up when convenient.

- Opt-in profiles (`minimal`, `development`, `personal`) as the README already proposes, so GUI apps and OS preferences never change every machine silently.
- A Brewfile so `brew bundle check` reports drift, if the current parsed lists become limiting.
- A tmux configuration load check in `scripts/test.sh` using a private server, tolerant of TPM being absent in CI.
- Linux font installation in the bootstrap (download to `~/.local/share/fonts` and run `fc-cache`), which is the one remaining manual step on Linux.

## Ideas parked

Considered and not scheduled, kept so they are not rediscovered.

- zellij as a tmux alternative: no Windows build, and the tmux investment is already large.
- Starship as a prompt: oh-my-posh already serves zsh and PowerShell from one file.
- zinit turbo mode: plugins cost about 25 ms in total after phase 1, so deferred loading buys little and adds ordering surprises.
- chezmoi or another dotfiles manager: the custom linker, doctor and tests cover the needs so far.
