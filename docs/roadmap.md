# Roadmap

The goal: one terminal experience that looks and behaves the same on macOS, Debian/Ubuntu/WSL and native Windows. Catppuccin Macchiato everywhere, fast shells, strong autocomplete, and every tool declared in this repository so a new machine is one command away.

Work lands in phases. Each phase is one pull request that leaves every platform in a working state, passes `bash scripts/test.sh`, and extends `doctor` so a rebuilt machine proves the phase is installed.

| Phase | Theme | Status |
|---|---|---|
| 1 | Foundations: one flavor, tmux capabilities, fast zsh, fzf, bat | Done ([#1](https://github.com/Arthur-K-99/dotfiles/pull/1)) |
| 2 | Terminal emulators and PowerShell parity | Done ([#3](https://github.com/Arthur-K-99/dotfiles/pull/3)) |
| 3 | New tools: completion engine, history, runtimes, git, TUIs | Done ([#4](https://github.com/Arthur-K-99/dotfiles/pull/4)) |
| 4 | tmux plugin suite, theme switcher, fastfetch | Done ([#6](https://github.com/Arthur-K-99/dotfiles/pull/6)) |
| 5 | Neovim | Done ([#7](https://github.com/Arthur-K-99/dotfiles/pull/7)) |

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

## Phase 3: New tools (done)

Autocomplete and shell quality of life on all three platforms, with the exceptions noted.

- **carapace** is the completion engine in zsh and PowerShell. In zsh it is sourced after `compinit` because its script calls `compdef`; fzf-tab keeps drawing the menu. **inshellisense** was evaluated and parked: it is a pty wrapper around the shell with open issues against zsh plugins and tmux, so it would compete with the rest of this setup. carapace can bridge its specs (`CARAPACE_BRIDGES`) if they are ever wanted.
- **atuin** replaces fzf's `Ctrl+R` in zsh (initialised after fzf so its binding wins; `Up` stays zsh's) and in PowerShell 7, where PSFzf then keeps only `Ctrl+T`. PowerShell support shipped in atuin 18.11.0 and is tier-2 upstream; winget installs a current build. Configuration and the vendored Catppuccin theme live in `config/atuin/`.
- **mise** replaces nvm: `config/mise/config.toml` pins Node.js LTS, the bootstrap runs `mise install`, and the doctor checks `mise which node` so a system Node cannot hide a missing one. The lazy-nvm block, the nvm bootstrap, `NVM_DIR` and their tests are gone. Windows gained a runtimes stage for the same `mise install`. In zsh the shims directory goes on `PATH` instead of `mise activate`: the activation hook cost about 115 ms per shell and 20 ms per prompt, while shims resolve the project version when a command runs.
- **git** moved to `config/git/` (XDG `config`, global `ignore`, the vendored `catppuccin/delta` include). Identity and credential helpers stay in `~/.gitconfig`, which git reads afterwards. delta, lazygit and lazydocker are installed everywhere; lazygit reads one path on every OS through `XDG_CONFIG_HOME` on Unix and `LG_CONFIG_FILE` on Windows.
- **yazi** with the Catppuccin Macchiato and Latte flavors. The flavors are packages that `ya pkg add` clones into `~/.config/yazi/flavors`, so only `yazi.toml` and `theme.toml` are linked; the bootstrap adds the flavors or restores them from `package.toml`. `y` changes directory on exit in both shells.
- **vivid** generates `LS_COLORS` for completion menus and fd on Unix. eza keeps its own `theme.yml`, which `LS_COLORS` would override, so an `eza` wrapper blanks the variable for that one command. Not installed on Windows, where nothing but eza reads `LS_COLORS`. Debian 12 ships vivid 0.8 without the Catppuccin themes; the shell checks for empty output and keeps the ANSI default there.
- **Modern CLI set**: ripgrep, fd, dust, duf, procs, sd, xh, hyperfine, glow, tlrc, gum. fd is the fzf backend. **tokei** was dropped: upstream has published no binaries since 12.1.2.
- **zsh extras**: zsh-abbr with a tracked abbreviation file (the `config/zsh-abbr` directory is linked, because zsh-abbr rewrites the file with `mv`, which would replace a file symlink) and zsh-you-should-use; direnv on every platform. **pay-respects** was parked: no Homebrew core formula, no apt or winget package, and the installer wants to edit shell files.
- **Startup time**: with every tool present an interactive zsh took about 320 ms, against 120 ms after phase 1. The init scripts of fzf, carapace, atuin, zoxide and direnv are now cached under `~/.cache/dotfiles/` and regenerated when the binary changes, and mise runs no hook, which brings a warm start to about 230 ms. What remains is oh-my-posh (about 75 ms across init and the first prompt), Homebrew's `shellenv` (25 ms) and zsh-abbr's initialisation (20 ms).
- **Linux installs** gained two generic helpers in `scripts/bootstrap_tools.sh`: `install_apt_repository` for signed third-party repositories (eza, charm) and `install_github_release` for static binaries from the latest release, with the per-project architecture spellings handled by template placeholders. atuin and yazi use their musl builds: the glibc builds need glibc 2.39, newer than Debian 12 and Ubuntu 22.04 provide. Both are tested with mocked network calls.

## Phase 4: tmux, theme switcher, fastfetch (done)

- **tmux moved** to `config/tmux/tmux.conf`, linked to `~/.config/tmux/tmux.conf`. tmux loads that file *and* `~/.tmux.conf` when both exist, so the linker retires the old link and the doctor reports anything left at the old path. TPM and the plugins live under `~/.config/tmux/plugins/`, the directory TPM itself chooses for an XDG configuration; the bootstrap clones TPM there and installs the plugins through a private server as before.
- **Plugins**, in the order TPM runs them: tmux-sensible, vim-tmux-navigator (`Ctrl+h/j/k/l` across panes and, in phase 5, Neovim splits), tmux-yank (`xsel` joins the apt list; `clip.exe` serves WSL and `pbcopy` macOS), tmux-fzf (`prefix F`), tmux-floax (`` prefix ` ``, mirroring Ghostty's quick terminal; the default `p` would shadow previous-window), `catppuccin/tmux#v2.3.1` (2.3.1 fixes a regression with tmux 3.7+) with the directory, session, cpu, battery and date_time modules, tmux-cpu and tmux-battery for the last two, then tmux-resurrect and tmux-continuum, which must be last because it hooks `status-right`. The theme runs once before the status modules are set and again from TPM; both run lines are guarded so the configuration loads without plugins, which lets `scripts/test.sh` source it into a private server and a test check the declaration order.
- **sesh** rather than tmux-sessionx: one static Go binary (Homebrew core, GitHub release on Linux) with zoxide and fzf, `prefix T` to pick or create a session and `prefix L` for the last one; `detach-on-destroy off` so killing a session switches instead of detaching. sessionx would have added bash, bat and a second fzf popup next to tmux-fzf.
- **`scripts/theme.sh <flavor>`** switches the whole repository. Named settings get the new name; files with hex values get each color replaced by the same-named color from the vendored `config/catppuccin/palette.txt`, in the case each file already uses (a value without letters, such as mocha's surface0, carries no case of its own). `config/catppuccin/flavor` records the result and `--check` verifies it. The bootstrap, the doctor and the tests read the bat theme, the yazi flavors and the fzf background from the configuration files, so a switched repository passes `bash scripts/test.sh` and is ready to commit; a test switches a copy through every flavor and back and expects the original bytes. All four atuin themes are vendored and the themes directory is linked, so only the name changes. Corrected along the way: Catppuccin ships with bat 0.26, not 0.25.
- **fastfetch** on every platform (Homebrew, winget, a GitHub release on Debian 12 and Ubuntu 24.04, which apt only covers from Debian 13 and Ubuntu 25.04). The config is `config/fastfetch/config.jsonc` with Catppuccin hex values, which fastfetch accepts directly, and a module list that avoids the slow detectors. zsh runs it in interactive shells outside tmux; PowerShell in the console host when the start arguments carry no `-Command`, `-File`, `-EncodedCommand` or `-NonInteractive`. `DOTFILES_FASTFETCH=0` turns it off. There is no official Catppuccin port for fastfetch; two submissions are open upstream.

## Phase 5: Neovim (done)

- **Base: a hand-rolled lazy.nvim configuration**, `config/nvim/init.lua` plus `lua/dotfiles/` (options, keymaps, autocommands, the lazy.nvim bootstrap) and one file per plugin under `lua/plugins/`. kickstart.nvim moved to Neovim 0.12's experimental `vim.pack` in 2026 and LazyVim is a distribution of dozens of plugins; neither is small enough to understand. Eleven plugins: catppuccin, nvim-treesitter, nvim-lspconfig, mason.nvim, mason-lspconfig.nvim, fzf-lua with nvim-web-devicons, which-key.nvim, gitsigns.nvim, vim-tmux-navigator, and lazy.nvim itself. No completion plugin: Neovim's own `vim.lsp.completion` triggers as you type. No statusline plugin: 0.12's default shows diagnostics and LSP progress.
- **Reproducible and quiet.** `lazy-lock.json` is committed and lazy.nvim's `install.missing` is off, so a start never reaches the network. `lua/dotfiles/bootstrap.lua` does the installing headless: `plugins()` clones missing plugins at the pinned commits and moves drifted ones back (lazy.nvim's `install` alone would clone branch heads and rewrite the lockfile with them; `restore` alone skips what is not installed, so the lock read at startup is put back between the two), `install()` adds the Tree-sitter parsers and Mason packages from `lua/dotfiles/tools.lua`, and `check()` reports every item, which the bootstrap uses as its offline gate and both doctors parse line by line.
- **Neovim 0.12 is the minimum**: nvim-treesitter's `main` branch, the only one that supports current Neovim, requires it. Debian 12 (0.7), Debian 13 (0.10), Ubuntu 24.04 (0.9) and Ubuntu 26.04 (0.11) are all too old, so `install_neovim_release` unpacks the release tarball whole into `~/.local/opt/nvim` and links `bin/nvim`; `install_github_release` would have kept only the binary without its runtime files. The tree-sitter CLI (0.26.1+, needed to compile parsers) comes from Homebrew (`tree-sitter-cli`), winget (`tree-sitter.tree-sitter-cli`) and, on Linux, the GitHub release zip, whose `x64` spelling added the `{arch_node}` template placeholder; `build-essential` joins the apt list for the C compiler. On Windows the compiler is a manual Visual Studio Build Tools install, so parsers there are reported as skipped, not missing, until it exists.
- **Theme:** `flavour = "auto"` with `background = { light = "latte", dark = "<flavor>" }`, so Neovim follows the terminal background like Ghostty and yazi do; `scripts/theme.sh` rewrites the `dark` line and the round-trip test covers it. Catppuccin's `auto_integrations` themes the installed plugins.
- **Language servers** through Mason: lua_ls, bashls, ts_ls, pyright (npm rather than basedpyright's pip, so Windows needs no Python), jsonls, yamlls, marksman, taplo, powershell_es (enabled only where `pwsh` exists, with Mason's bundle path). Mason runs npm from mise's Node.js, which the bootstrap puts on PATH for that step.
- **Windows:** `Get-DotfilesManagedFiles` enumerates every file of `config/nvim` into `%LOCALAPPDATA%\nvim`, so a new Lua file is managed without editing the list; the runtimes stage runs the same headless install and the doctor the same report.
- **Checks:** `scripts/test.sh` runs `tests/nvim_check.lua` through `nvim -l` (no configuration, no network): every Lua file parses and the plugin specs match the lockfile both ways. The Ubuntu CI job installs Neovim for it. Unix tests cover the Neovim and tree-sitter release installers (installed, too old, download failure, retry, bad archive, old release, file in the way, arm64), the bootstrap step, the doctor, and `plugins()` itself against local git repositories (a failed clone must leave the lockfile untouched); the Windows suite covers the install stage, the doctor's report parsing, the version and Node.js discovery, and pushes the Lua arguments through a real child process, because Windows PowerShell strips inner double quotes from native arguments.

## Repository structure

Not tied to a phase; pick up when convenient.

- Opt-in profiles (`minimal`, `development`, `personal`) as the README already proposes, so GUI apps and OS preferences never change every machine silently.
- A Brewfile so `brew bundle check` reports drift, if the current parsed lists become limiting.
- Linux font installation in the bootstrap (download to `~/.local/share/fonts` and run `fc-cache`), which is the one remaining manual step on Linux.

## Ideas parked

Considered and not scheduled, kept so they are not rediscovered.

- zellij as a tmux alternative: no Windows build, and the tmux investment is already large.
- Starship as a prompt: oh-my-posh already serves zsh and PowerShell from one file.
- zinit turbo mode: plugins cost about 25 ms in total after phase 1, so deferred loading buys little and adds ordering surprises.
- chezmoi or another dotfiles manager: the custom linker, doctor and tests cover the needs so far.
- inshellisense: a pty wrapper that fights the zsh plugins and tmux; carapace covers completion and can bridge its specs if needed.
- pay-respects: no Homebrew core, apt or winget package and an installer that edits shell files. Revisit when one package manager carries it.
- tokei: upstream has shipped no binaries since 12.1.2, so Linux would need cargo. `cargo install tokei` by hand if wanted.
