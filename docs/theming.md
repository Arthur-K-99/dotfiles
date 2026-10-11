# Theming

Everything is Catppuccin **Macchiato**. This document says where the colors live, which tools carry explicit hex values and which follow the terminal palette, and what to change to switch flavor until the phase 4 switcher exists.

## Palette

The Macchiato colors used in this repository. The full palette with every flavor is at <https://github.com/catppuccin/catppuccin#-palette>.

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
| surface0 | `#363A4F` | fzf current line and border |
| base | `#24273A` | fzf background |

## Where each tool gets its colors

Two philosophies are in play. Explicit hex values look identical in every terminal but must be edited per tool. ANSI colors follow whatever palette the terminal emulator uses, so they switch with the emulator and need no per-tool edits. Since phase 2 the emulators are managed too, so the ANSI-based tools inherit Catppuccin on every platform. PSReadLine uses the same color names as this table; the mapping is commented in `config/powershell/profile.ps1`.

| Tool | Where | Style |
|---|---|---|
| Ghostty | `theme` in `config/ghostty/config` | named themes shipped with Ghostty: Latte when the OS is light, Macchiato when dark |
| Windows Terminal | `schemes` in `config/windows-terminal/fragment.json` | explicit hex, the official `catppuccin/windows-terminal` scheme, applied to the stock profiles by `colorScheme` |
| PSReadLine | `$readLineColors` in `config/powershell/profile.ps1` | explicit hex for foregrounds; the two backgrounds are RGB escape sequences |
| tmux | `@catppuccin_flavor` in `home/.tmux.conf` | named flavor via the Catppuccin tmux plugin |
| oh-my-posh | `palette` block in `config/oh-my-posh/config.omp.json` | explicit hex |
| eza | `config/eza/theme.yml` | explicit hex, every file kind and column |
| fzf, including fzf-tab | `FZF_DEFAULT_OPTS` in `home/.zshrc` and `config/powershell/profile.ps1` | explicit hex, two copies that must match |
| bat | `--theme` in `config/bat/config` | named theme shipped with bat 0.25+; older packages get the file from `scripts/bootstrap_tools.sh` |
| zsh completion menus | `LS_COLORS` default in `home/.zshrc` | ANSI, follows the terminal palette |
| zsh syntax highlighting, autosuggestions | plugin defaults | ANSI |
| btop, lazygit, delta, Neovim | not yet managed | see `docs/roadmap.md` |

## Switching flavor today

Pick a flavor (`latte`, `frappe`, `macchiato`, `mocha`) and change these, in order:

1. `home/.tmux.conf`: `set -g @catppuccin_flavor '<flavor>'`, then `prefix r` or a new tmux server.
2. `config/oh-my-posh/config.omp.json`: replace each `palette` hex value with the same-named color from the new flavor.
3. `config/eza/theme.yml`: replace every hex value with the same-named color. The header comment names the flavor; keep it accurate. A `sed` with one `-e` per color is the quickest route, which is how the Mocha-to-Macchiato move was done.
4. `home/.zshrc` and `config/powershell/profile.ps1`: the `--color=` lines in `FZF_DEFAULT_OPTS`. The official per-flavor lines are at <https://github.com/catppuccin/fzf>.
5. `config/bat/config`: `--theme="Catppuccin <Flavor>"` with the capitalised flavor name. On old bat packages, update the URL in `bootstrap_bat_theme` as well.
6. `config/ghostty/config`: the `dark:` half of the `theme` line, spelled as `ghostty +list-themes` prints it (`Catppuccin Mocha`, with the space). The `light:` half stays Latte unless you want a dark flavor in light mode too.
7. `config/windows-terminal/fragment.json`: replace the scheme with the flavor's file from <https://github.com/catppuccin/windows-terminal> and rename every `colorScheme` to match; restart Windows Terminal.
8. `config/powershell/profile.ps1`: the hex values in `$readLineColors` and the prediction colors below it, plus the two `48;2;R;G;B` background sequences (surface0 of the new flavor).
9. Run `bash scripts/test.sh` and `scripts/doctor.sh`, then open a new shell.

A script that does all of this from a single palette file is planned for phase 4.

## Fonts and glyphs

The prompt, eza icons and the fzf pointer use Nerd Font glyphs from CaskaydiaCove Nerd Font Mono (short name `CaskaydiaCove NFM`, the Nerd Fonts v3 build). Ghostty and the Windows Terminal fragment select it; if a glyph renders as a box elsewhere, that terminal is not using the Nerd Font. The PowerShell profile writes its glyphs as code points because Windows PowerShell 5.1 reads scripts without a byte-order mark as ANSI.
