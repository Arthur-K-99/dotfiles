# Theming

Everything is Catppuccin **Macchiato**. `config/catppuccin/flavor` records the flavor and `bash scripts/theme.sh <flavor>` switches the whole repository to another one (see "Switching flavor"). This document says where the colors live, which tools carry explicit hex values and which follow the terminal palette.

## Palette

The colors of the current flavor used in this repository. `config/catppuccin/palette.txt` carries all four flavors, copied from <https://github.com/catppuccin/palette>; `scripts/theme.sh` reads it.

| Name | Hex | Used for |
|---|---|---|
| rosewater | `#F4DBD6` | fzf spinner and pointer |
| pink | `#F5BDE6` | prompt path |
| mauve | `#C6A0F6` | eza special files, fzf prompt and info |
| red | `#ED8796` | errors, exit status, fzf highlights |
| maroon | `#EE99A0` | eza device files |
| peach | `#F5A97F` | prompt git segment when dirty |
| yellow | `#EED49F` | execution time, eza write permissions and dates |
| green | `#A6DA95` | eza executables and git additions |
| teal | `#8BD5CA` | eza octal and renames |
| sky | `#91D7E3` | eza symlinks |
| sapphire | `#7DC4E4` | eza mount points |
| blue | `#8AADF4` | directories, prompt session |
| lavender | `#B7BDF8` | prompt git branch, fzf marker |
| text | `#CAD3F5` | default foreground |
| subtext1 | `#B8C0E0` | eza normal files |
| subtext0 | `#A5ADCB` | prompt OS icon and closer |
| overlay2 | `#939AB7` | eza block counts |
| overlay0 | `#6E738D` | PSReadLine comments and inline predictions |
| overlay1 | `#8087A2` | eza punctuation |
| surface2 | `#5B6078` | eza sockets and build files |
| surface1 | `#494D64` | fzf selected background (reserved for fzf 0.55+) |
| surface0 | `#363A4F` | fzf current line and border, PSReadLine selection and selected prediction |
| base | `#24273A` | fzf background |

## Where each tool gets its colors

Two philosophies are in play. Explicit hex values look identical in every terminal but must be edited per tool. ANSI colors follow whatever palette the terminal emulator uses, so they switch with the emulator and need no per-tool edits. Since phase 2 the emulators are managed too, so the ANSI-based tools inherit Catppuccin on every platform. PSReadLine uses the same color names as this table; the mapping is commented in `config/powershell/profile.ps1`.

| Tool | Where | Style |
|---|---|---|
| Ghostty | `theme` in `config/ghostty/config` | named themes shipped with Ghostty: Latte when the OS is light, the flavor above when dark |
| Windows Terminal | `schemes` in `config/windows-terminal/fragment.json` | explicit hex, the official `catppuccin/windows-terminal` scheme, applied to the stock profiles by `colorScheme` |
| PSReadLine | `$readLineColors` in `config/powershell/profile.ps1` | explicit hex for foregrounds; the two backgrounds are RGB escape sequences of surface0 |
| tmux | `@catppuccin_flavor` in `config/tmux/tmux.conf` | named flavor via the Catppuccin tmux plugin |
| oh-my-posh | `palette` block in `config/oh-my-posh/config.omp.json` | explicit hex |
| eza | `config/eza/theme.yml` | explicit hex, every file kind and column |
| fzf, including fzf-tab | `FZF_DEFAULT_OPTS` in `home/.zshrc` and `config/powershell/profile.ps1` | explicit hex, two copies that must match |
| bat | `--theme` in `config/bat/config` | named theme shipped with bat 0.26+; older packages get the file from `scripts/bootstrap_tools.sh`, which reads the name from the same line |
| delta (git pager) | `features = catppuccin-macchiato` in `config/git/config`, colors in the vendored `config/git/catppuccin.gitconfig` | explicit hex from `catppuccin/delta`; all four flavors are included |
| lazygit | `gui.theme` in `config/lazygit/config.yml` | explicit hex from `catppuccin/lazygit` (blue accent) |
| atuin | `[theme] name` in `config/atuin/config.toml`, colors in `config/atuin/themes/` | explicit hex from `catppuccin/atuin`; all four flavors are vendored and linked, the name selects one |
| yazi | `[flavor]` in `config/yazi/theme.toml` | named flavors installed as packages by `ya pkg add`; the bootstrap and the doctor read the names from this file |
| fastfetch | `config/fastfetch/config.jsonc` | explicit hex for keys, title, separator, output and the logo; the `colors` module shows the terminal's own palette |
| tmux-floax | `@floax-border-color` in `config/tmux/tmux.conf` | ANSI |
| zsh completion menus, fd | `vivid generate catppuccin-macchiato` in `home/.zshrc` | named vivid theme; a small ANSI default applies without vivid |
| zsh syntax highlighting, autosuggestions | plugin defaults | ANSI |
| Neovim | `background` in `config/nvim/lua/plugins/colorscheme.lua` | the `catppuccin/nvim` plugin with `flavour = "auto"`: Latte when the terminal background is light, the flavor above when dark, like Ghostty and yazi |
| btop | not yet managed | btop's own default theme; the roadmap's "btop in Catppuccin" to-do |

## Switching flavor

```bash
bash scripts/theme.sh mocha
```

The flavors are `latte`, `frappe`, `macchiato` and `mocha`. The script reads the current flavor from `config/catppuccin/flavor` and rewrites every location in the table above:

- **Named locations** get the new name: the tmux flavor, the bat theme, the `dark:` half of the Ghostty theme, the delta feature, the atuin theme name, the yazi and Neovim `dark` flavors, the vivid theme, the Windows Terminal scheme name, and the PSReadLine background sequences. Each must be present, so a missing one fails the run instead of being forgotten.
- **Hex values** in oh-my-posh, eza, the fzf options of both shells, PSReadLine, the Windows Terminal scheme, lazygit, fastfetch and the palette table above are replaced color by color with the same-named color of the new flavor. Each file keeps its own upper- or lowercase convention.
- **Labels**: comments and this document's mentions of the flavor follow along. The `light` halves of Ghostty, yazi and Neovim stay Latte.
- `bash scripts/theme.sh --check` then verifies that every location agrees; the test suite runs the same check and a round trip through every flavor, so the rewritten repository is ready to commit.

After switching: review `git diff`, run `bash scripts/test.sh`, then `bash scripts/bootstrap_tools.sh` (installs the new yazi flavor, and the bat theme on old packages), start a new tmux server or press `prefix r`, and open a new shell. On Windows, rerun `install.ps1` or `scripts\install_runtimes.ps1` for the yazi flavor and restart Windows Terminal so the fragment is read again.

Not touched: the README and the other documents under `docs/` (they say "the flavor" rather than naming it, except the roadmap's history), and tools that follow the terminal palette.

## Adding a themed location

- A setting that names the flavor: add a location to `theme_locations`, `theme_location_file` and `theme_location_text` in `scripts/theme.sh`.
- A file with hex values: add it to `theme_hex_files`, use palette values only, and keep one case convention in the file.
- Run `bash tests/unix.Tests.sh theme_switch_round_trip`: it switches a copy of the repository through every flavor and back and expects the original bytes.

## Fonts and glyphs

The prompt, eza icons and the fzf pointer use Nerd Font glyphs from CaskaydiaCove Nerd Font Mono (short name `CaskaydiaCove NFM`, the Nerd Fonts v3 build). Ghostty and the Windows Terminal fragment select it; if a glyph renders as a box elsewhere, that terminal is not using the Nerd Font. The PowerShell profile writes its glyphs as code points because Windows PowerShell 5.1 reads scripts without a byte-order mark as ANSI.
