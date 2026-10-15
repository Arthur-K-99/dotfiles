# Tools

What each managed tool does after install and where its configuration lives. The keys are in the README's [Key bindings](../README.md#key-bindings) table; [Linux and WSL](linux.md) and [Windows](windows.md) cover what differs by platform.

## zsh

- **Configuration:** `home/.zshrc`, linked to `~/.zshrc`. New terminals and tmux panes start your login shell, so zsh has to be it (`chsh`, see the README's [first steps](../README.md#first-steps-after-install)). `~/.zshenv` and `~/.zprofile` are not managed and still load.
- **Machine-local settings** go in `~/.zshrc.local`, which `~/.zshrc` sources after everything but the fastfetch greeting. A replaced `~/.zshrc` is in `~/.zshrc.bak.<timestamp>`; the installer says so.
- **Plugins** through zinit: zsh-syntax-highlighting, zsh-completions, zsh-autosuggestions, fzf-tab, zsh-abbr and zsh-you-should-use.
- **Startup:** the init scripts of fzf, carapace, atuin, zoxide and direnv are cached under `~/.cache/dotfiles/` and regenerated when the binary changes.
- **Aliases:** `cd` is zoxide (`cdi` picks a directory interactively), `ls` is eza and `la`, `ll` and `tree` call it with icons, `cat` is bat (`batcat` on Debian), `vim` is nvim and `c` clears the screen. you-should-use reminds you of an alias after a command runs.
- **Abbreviations:** zsh-abbr expands `g`, `gs`, `gc`, `gco`, `gd`, `gl`, `gp`, `gpl`, `gsw`, `ga`, `lg` and `ld` on `Space` or `Enter`. `abbr add name=command` adds one and rewrites the tracked `config/zsh-abbr/user-abbreviations` through the linked directory, so commit the change.
- **Completion:** carapace completes over a thousand commands in zsh and PowerShell; `Tab` opens the menu in both shells, drawn by fzf-tab in zsh. Run `carapace --clear-cache` after installing new tools.
- **History:** atuin owns `Ctrl+R` with fuzzy search over a local SQLite database; `Up` stays plain zsh history, and tmux has its own `prefix Ctrl+R` for restoring sessions. In atuin's list, `Enter` runs the command and `Tab` puts it on the line to edit.
  - `atuin import auto` brings in your existing shell history, once.
  - Sync between machines is opt-in: `atuin register` or `atuin login`, then `atuin sync`. Without it atuin makes no network requests.
  - PowerShell support needs atuin 18.11 or newer, which winget installs.
- **fzf:** `Ctrl+T` inserts files and `Alt+C` changes directory, both from fd, so ignored files stay out of the way; `Tab` completion opens the same fzf window. `Ctrl+/` hides `Ctrl+T`'s preview.
- **Directories and files:** `y` opens yazi and changes to the directory you quit in. `fd` and `rg` replace `find` and `grep`.
- **Editor:** both shells set `EDITOR` to `nvim` when Neovim is installed and `EDITOR` is not set already. `Ctrl+X Ctrl+E` and git use it unless `VISUAL` is set, which they read first. To use another editor, set `EDITOR` in `~/.zshrc.local` (Windows: `~\.powershell.local.ps1`).
- **SSH agent:** the shared configuration leaves `SSH_AUTH_SOCK` alone. To use Bitwarden on a particular machine, add `export SSH_AUTH_SOCK="$HOME/.bitwarden-ssh-agent.sock"` to that machine's `~/.zshrc.local`.

## fastfetch

New interactive shells start with a machine summary in Catppuccin colors; tmux panes and non-interactive shells skip it. Set `DOTFILES_FASTFETCH=0` in `~/.zshrc.local` (or `$env:DOTFILES_FASTFETCH = '0'` in `~/.powershell.local.ps1`) to turn it off. The modules are in `config/fastfetch/config.jsonc`.

## Ghostty

- The configuration is linked to `~/.config/ghostty/config`; reload it with `Cmd+Shift+,` (Linux: `Ctrl+Shift+,`).
- The theme follows the OS appearance: Latte in light mode, the flavor in `config/catppuccin/flavor` in dark.
- The left Option key acts as Alt for fzf's `Alt+C` and zsh's `Alt+W`; the right one keeps typing special characters. `Shift+Enter` inserts a newline in programs that otherwise take Enter as the end of input.
- `` Cmd+` `` opens a drop-down quick terminal from any app on macOS, after macOS grants the Accessibility permission it asks for.
- Machine-local settings, shaders and extra themes go in `~/.config/ghostty/local`, which the managed file loads when it exists. On macOS Ghostty also reads `~/Library/Application Support/com.mitchellh.ghostty/config`; keep a setting in one of the two places, since which one wins was not checked ([roadmap](roadmap.md#known-issues)).
- On Linux, install Ghostty from [ghostty.org](https://ghostty.org/download); the configuration is already in place.
- `ssh` from a Ghostty shell tells the host the terminal is `xterm-256color`, a name nearly every host knows, and sends `COLORTERM=truecolor` to hosts whose sshd accepts it (`AcceptEnv COLORTERM`). Ghostty can also copy its own terminal description (`xterm-ghostty`) to each host; that option, `ssh-terminfo`, is off because in Ghostty 1.3.1 it runs a command given to `ssh` twice ([roadmap](roadmap.md)).

## tmux

- **Configuration:** `config/tmux/tmux.conf`, linked to `~/.config/tmux/tmux.conf`. TPM installs the plugins under `~/.config/tmux/plugins/`; the bootstrap does that, and `prefix I` (`Ctrl+A`, then `I`) installs one that is missing after you edit the plugin list.
- **Old files:** tmux would load a `~/.tmux.conf` as well, so the linker removes the link earlier versions of this repository made there and backs up any other `~/.tmux.conf` beside it. A `~/.tmux/plugins` directory from before the move can be deleted.
- **Machine-local settings,** such as those from an old `~/.tmux.conf`, go in `~/.config/tmux/local.conf`, which the configuration loads after its own settings, before TPM runs the plugins.
- **Plugins:**
  - vim-tmux-navigator: `Ctrl+h/j/k/l` move across tmux panes and Neovim splits alike, so clearing the screen moves to `prefix Ctrl+L`;
  - tmux-fzf (`prefix F`) over sessions, windows and panes;
  - tmux-floax (`` prefix ` ``): a floating scratch pane, the tmux counterpart of Ghostty's quick terminal;
  - tmux-resurrect (`prefix Ctrl+S` saves and `prefix Ctrl+R` restores the session layout) and tmux-continuum, which saves every 15 minutes and restores the last save when the server starts;
  - tmux-sensible, tmux-yank, and the Catppuccin status line (pinned to a tag) with tmux-cpu and tmux-battery.
- **Sessions:** `prefix T` opens sesh to jump to or create a session from tmux sessions and zoxide directories; `prefix L` returns to the last one.
- **Clipboard:** `y` in copy mode and mouse selections copy to the system clipboard (pbcopy on macOS; [Linux and WSL](linux.md#clipboard)).
- **Status line:** directory, session, CPU, battery and time, in Catppuccin.
- **Colors:** tmux identifies itself as `tmux-256color` for italics and forces true color through every host terminal, including Windows Terminal and WSL. Linux gets the terminfo from the `ncurses-term` package. If a remote host you `ssh` into from tmux lacks that terminfo, prefix the command with `TERM=screen-256color`.

## Neovim

- **Configuration:** `config/nvim`, linked whole to `~/.config/nvim` (Windows: every file managed into `%LOCALAPPDATA%\nvim`).
- **Plugins** are pinned in `lazy-lock.json` and installed by the bootstrap at exactly those commits; nothing is fetched when Neovim starts. After `:Lazy update` commit the lockfile, and run the bootstrap or the update (or `scripts\install_runtimes.ps1`) on other machines to follow it.
- **Languages** are listed in `config/nvim/lua/dotfiles/tools.lua`; the bootstrap installs them headless through nvim-treesitter and Mason, and the doctor reports each one:
  - language servers for Lua, Bash, TypeScript and JavaScript, Python, JSON, YAML, TOML, Markdown and PowerShell (the last installed everywhere, started only where `pwsh` exists);
  - Tree-sitter parsers for bash, diff, dockerfile, the git file types, javascript, json, powershell, python, regex, toml, tsx, typescript and yaml. Neovim bundles c, lua, markdown, markdown_inline, query, vim and vimdoc.
- **The update** brings the parsers to the revisions the pinned nvim-treesitter names and the language servers to their latest versions.
- **Keys:** the leader is `Space`. `Space` alone waits, then which-key shows the groups (find, git, search, diagnostics, buffer, code); `Space ?` shows the keys of the current buffer. `Ctrl+h/j/k/l` move between splits and on into tmux panes. The README's [Key bindings](../README.md#key-bindings) table has the rest.
- **Completion** is Neovim's own and starts as you type (`Ctrl+Y` accepts). `:Mason` and `:checkhealth` show the tooling state.
- **Platforms:** Linux needs Neovim from its GitHub release and the tree-sitter CLI ([Linux](linux.md#neovim-and-the-tree-sitter-cli)); Windows needs a C compiler for the parsers ([Windows](windows.md#neovim)).

## Runtimes: mise

- mise installs the Node.js LTS pinned in `config/mise/config.toml` and switches versions per project from `mise.toml` or `.tool-versions` files.
- mise reads `.nvmrc` and `.node-version` only when told to, for example with `export MISE_IDIOMATIC_VERSION_FILE_ENABLE_TOOLS=node` in `~/.zshrc.local`. Then a project's `package.json` `devEngines` chooses Node.js as well, and a `~/.nvmrc` applies under your whole home directory.
- zsh puts mise's shims directory on `PATH` rather than running `mise activate`, which keeps shell startup fast; project `[env]` sections in mise files are therefore not applied (use direnv). PowerShell runs `mise activate`.
- `mise use -g node@22` changes the global default; it rewrites the tracked `config/mise/config.toml` through the link, so commit it or undo it. `mise use python@3.13` adds a runtime to a project, `mise ls` shows what is installed.
- An existing nvm installation is left alone and no longer loaded; remove `~/.nvm` when you are sure nothing else needs it.

## Git

- `~/.config/git/config` holds the shared settings: delta as pager, zdiff3 conflicts, rebase on pull, autosquash, sorted branches and a global ignore in `~/.config/git/ignore`.
- Identity and credential helpers stay in `~/.gitconfig`, which git reads afterwards and which `git config --global` writes to. The linker creates an empty one when it is missing, so those writes never land in the managed file. A setting in an older `~/.gitconfig` overrides the shared one, such as a `core.pager` that hides delta.
- On macOS git is the one from the Command Line Tools; Linux and Windows install it as a package.
- `lazygit` and `lazydocker` use the same Catppuccin colors.

## Theme

Every tool uses one Catppuccin flavor, recorded in `config/catppuccin/flavor`: tmux, the prompt, eza, bat and fzf, including tab-completion menus, as well as Ghostty, the Windows Terminal fragment, PSReadLine, delta, lazygit, atuin, yazi, fastfetch and Neovim. `bash scripts/theme.sh <flavor>` switches all of them at once, and [theming](theming.md) lists every location. bat 0.26+ ships the themes; the bootstrap installs the current one for older distribution packages.

## Font

Ghostty and the Windows Terminal fragment select `CaskaydiaCove Nerd Font Mono` themselves (some pickers list it as `CaskaydiaCove NFM`); choose it by hand in any other terminal. macOS installs it with a Homebrew cask, Linux from the Nerd Fonts release ([Linux](linux.md#font)), Windows with oh-my-posh ([Windows](windows.md#font)). WSL uses the Windows font.
