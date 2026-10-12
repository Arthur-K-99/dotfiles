#!/usr/bin/env bash
# Switch every Catppuccin location in this repository to one flavor.
#
#   bash scripts/theme.sh <latte|frappe|macchiato|mocha>   rewrite the repository
#   bash scripts/theme.sh --check                          verify the locations agree
#
# docs/theming.md lists where a flavor lives. Locations that name the flavor
# (tmux, bat, Ghostty, git, atuin, yazi, Neovim, vivid, the Windows Terminal
# scheme, the PSReadLine background sequences) get the new name; files that carry hex
# values (oh-my-posh, eza, fzf in zsh and PowerShell, PSReadLine, the Windows
# Terminal scheme, lazygit, fastfetch and the palette table in docs/theming.md)
# get every color replaced by the same-named color of the new flavor, read
# from config/catppuccin/palette.txt. config/catppuccin/flavor records the
# result. The tests and the installers derive their expectations from these
# files, so the rewritten repository is ready to commit.

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THEME_FLAVORS="latte frappe macchiato mocha"

# Files whose hex values are mapped color by color.
theme_hex_files() {
    printf '%s\n' \
        config/oh-my-posh/config.omp.json \
        config/eza/theme.yml \
        config/windows-terminal/fragment.json \
        config/lazygit/config.yml \
        config/powershell/profile.ps1 \
        config/fastfetch/config.jsonc \
        home/.zshrc \
        docs/theming.md
}

# Locations that spell the flavor out. theme_location_file names the file and
# theme_location_text the exact text that must be there for a flavor.
theme_locations() {
    printf '%s\n' tmux bat ghostty git atuin yazi nvim vivid windows-terminal psreadline theming-doc
}

theme_location_file() {
    case "$1" in
        tmux) printf 'config/tmux/tmux.conf\n' ;;
        bat) printf 'config/bat/config\n' ;;
        ghostty) printf 'config/ghostty/config\n' ;;
        git) printf 'config/git/config\n' ;;
        atuin) printf 'config/atuin/config.toml\n' ;;
        yazi) printf 'config/yazi/theme.toml\n' ;;
        nvim) printf 'config/nvim/lua/plugins/colorscheme.lua\n' ;;
        vivid) printf 'home/.zshrc\n' ;;
        windows-terminal) printf 'config/windows-terminal/fragment.json\n' ;;
        psreadline) printf 'config/powershell/profile.ps1\n' ;;
        theming-doc) printf 'docs/theming.md\n' ;;
        *) echo "theme: unknown location $1" >&2; return 1 ;;
    esac
}

theme_location_text() {
    local flavor="$2" title
    title="$(theme_title "$flavor")"
    case "$1" in
        tmux) printf "@catppuccin_flavor '%s'\n" "$flavor" ;;
        bat) printf -- '--theme="Catppuccin %s"\n' "$title" ;;
        # Ghostty and yazi keep Latte for light mode; the flavor is the dark half.
        ghostty) printf 'dark:Catppuccin %s\n' "$title" ;;
        git) printf 'features = catppuccin-%s\n' "$flavor" ;;
        atuin) printf 'name = "catppuccin-%s-blue"\n' "$flavor" ;;
        yazi) printf 'dark = "catppuccin-%s"\n' "$flavor" ;;
        # Neovim follows the terminal background: Latte when light, the flavor when dark.
        nvim) printf 'dark = "%s"\n' "$flavor" ;;
        vivid) printf 'vivid generate catppuccin-%s\n' "$flavor" ;;
        windows-terminal) printf '"Catppuccin %s"\n' "$title" ;;
        # PSReadLine backgrounds are RGB escape sequences of surface0.
        psreadline) printf '48;2;%s\n' "$(theme_rgb "$(theme_color "$flavor" surface0)")" ;;
        theming-doc) printf 'Catppuccin **%s**\n' "$title" ;;
        *) echo "theme: unknown location $1" >&2; return 1 ;;
    esac
}

theme_title() {
    printf '%s%s\n' "$(printf '%s' "${1:0:1}" | tr '[:lower:]' '[:upper:]')" "${1:1}"
}

theme_upper() {
    printf '%s\n' "$1" | tr '[:lower:]' '[:upper:]'
}

theme_is_flavor() {
    case " $THEME_FLAVORS " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

theme_current() {
    local flavor
    read -r flavor < "$DOTFILES_DIR/config/catppuccin/flavor" || return 1
    if ! theme_is_flavor "$flavor"; then
        echo "theme: config/catppuccin/flavor names an unknown flavor: $flavor" >&2
        return 1
    fi
    printf '%s\n' "$flavor"
}

# theme_colors <flavor>: "<name> <hex>" lines in palette order.
theme_colors() {
    awk -v flavor="$1" '!/^#/ && $1 == flavor { print $2, $3 }' "$DOTFILES_DIR/config/catppuccin/palette.txt"
}

theme_color() {
    theme_colors "$1" | awk -v name="$2" '$1 == name { print $2 }'
}

# "r;g;b" of a hex color, the form the PSReadLine background sequences use.
theme_rgb() {
    local hex="${1#\#}"
    printf '%d;%d;%d\n' "0x${hex:0:2}" "0x${hex:2:2}" "0x${hex:4:2}"
}

# Regular-expression alternation of a flavor's hex digits, for grep -i -E.
theme_hex_pattern() {
    theme_colors "$1" | awk '{ printf "%s%s", (NR > 1 ? "|" : ""), substr($2, 2) }'
}

theme_escape() {
    printf '%s' "$1" | sed -e 's/[][\.*^$|?+(){}]/\\&/g'
}

# theme_edit <file> <sed arguments>...: rewrite a file through a temporary
# copy beside it. The content is copied back so the file keeps its mode.
theme_edit() {
    local file="$DOTFILES_DIR/$1" tmp
    shift
    tmp="$(mktemp "$file.XXXXXX")" || return 1
    if ! sed -E "$@" "$file" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    cat "$tmp" > "$file" && rm -f "$tmp"
}

theme_require_text() {
    if ! grep -F -q -- "$2" "$DOTFILES_DIR/$1"; then
        echo "theme: $1 does not contain '$2'" >&2
        return 1
    fi
}

# Named locations: the exact text of the old flavor becomes that of the new.
theme_apply_names() {
    local from="$1" to="$2" location file old new
    for location in $(theme_locations); do
        file="$(theme_location_file "$location")" || return 1
        old="$(theme_location_text "$location" "$from")" || return 1
        new="$(theme_location_text "$location" "$to")" || return 1
        theme_require_text "$file" "$old" || return 1
        theme_edit "$file" -e "s|$(theme_escape "$old")|$new|g" || return 1
    done
}

# Hex values: every color of the old flavor becomes the same-named color of
# the new one. A first pass turns each value, in either case, into a name
# token and a second writes the new value, so a value the new flavor also
# uses under another name cannot be mapped twice. Each file keeps its own
# case convention, detected from the hex values it already holds, because a
# value without letters (mocha's surface0 is #313244) carries no case itself.
theme_map_hex() {
    local from="$1" to="$2" upper lower name hex file script
    upper="$(mktemp "${TMPDIR:-/tmp}/dotfiles-theme.XXXXXX")" || return 1
    lower="$(mktemp "${TMPDIR:-/tmp}/dotfiles-theme.XXXXXX")" || return 1
    while read -r name hex; do
        printf 's|#%s|@@%s@@|g\n' "$(theme_upper "${hex#\#}")" "$name"
        printf 's|#%s|@@%s@@|g\n' "${hex#\#}" "$name"
    done < <(theme_colors "$from") | tee "$upper" > "$lower"
    while read -r name hex; do
        printf 's|@@%s@@|#%s|g\n' "$name" "$(theme_upper "${hex#\#}")" >> "$upper"
        printf 's|@@%s@@|#%s|g\n' "$name" "${hex#\#}" >> "$lower"
    done < <(theme_colors "$to")
    for file in $(theme_hex_files); do
        if ! grep -i -E -q "#($(theme_hex_pattern "$from"))" "$DOTFILES_DIR/$file"; then
            echo "theme: $file carries no $from color" >&2
            rm -f "$upper" "$lower"
            return 1
        fi
        script="$lower"
        if grep -E -q '#[0-9A-F]*[A-F][0-9A-F]*([^0-9A-Fa-f]|$)' "$DOTFILES_DIR/$file"; then
            script="$upper"
        fi
        theme_edit "$file" -f "$script" || { rm -f "$upper" "$lower"; return 1; }
    done
    rm -f "$upper" "$lower"
}

# Comments and documentation that mention the flavor by name follow along.
# Nothing is required here: these are labels, not settings. Latte doubles as
# the light-mode flavor in Ghostty and yazi, so those two entries are shielded
# while the old flavor's name is replaced.
theme_relabel() {
    local from="$1" to="$2" file
    local from_title to_title
    from_title="$(theme_title "$from")"
    to_title="$(theme_title "$to")"
    for file in $(theme_hex_files) $(for location in $(theme_locations); do theme_location_file "$location"; done); do
        theme_edit "$file" \
            -e 's|light:Catppuccin Latte|@@light-ghostty@@|g' \
            -e 's|light = "catppuccin-latte"|@@light-yazi@@|g' \
            -e "s|Catppuccin $from_title|Catppuccin $to_title|g" \
            -e "s|catppuccin-$from|catppuccin-$to|g" \
            -e "s|themes-mergable/$from/|themes-mergable/$to/|g" \
            -e 's|@@light-ghostty@@|light:Catppuccin Latte|g' \
            -e 's|@@light-yazi@@|light = "catppuccin-latte"|g' || return 1
    done
}

# theme_check <flavor>: every named location spells the flavor and no file
# carries a color that belongs to another flavor only.
theme_check() {
    local flavor="$1" location file other recorded status=0
    for location in $(theme_locations); do
        file="$(theme_location_file "$location")" || return 1
        theme_require_text "$file" "$(theme_location_text "$location" "$flavor")" || status=1
    done
    for file in $(theme_hex_files); do
        if ! grep -i -E -q "#($(theme_hex_pattern "$flavor"))" "$DOTFILES_DIR/$file"; then
            echo "theme: $file carries no $flavor color" >&2
            status=1
        fi
        for other in $THEME_FLAVORS; do
            [ "$other" = "$flavor" ] && continue
            if grep -i -E -q "#($(theme_hex_pattern "$other"))" "$DOTFILES_DIR/$file"; then
                echo "theme: $file still carries a $other color" >&2
                status=1
            fi
        done
    done
    read -r recorded < "$DOTFILES_DIR/config/catppuccin/flavor" || recorded=""
    if [ "$recorded" != "$flavor" ]; then
        echo "theme: config/catppuccin/flavor says '$recorded', not '$flavor'" >&2
        status=1
    fi
    return "$status"
}

theme_usage() {
    echo "Usage: bash scripts/theme.sh <latte|frappe|macchiato|mocha> | --check"
    echo "Current flavor: $(theme_current 2>/dev/null || echo unknown)"
}

theme_main() {
    local target="${1:-}" current
    case "$target" in
        --check)
            current="$(theme_current)" || return 1
            theme_check "$current" || return 1
            echo "Every location agrees on $current."
            ;;
        -h|--help|'')
            theme_usage
            [ -n "$target" ] || return 2
            ;;
        *)
            if ! theme_is_flavor "$target"; then
                echo "Unknown flavor '$target'. Choose one of: $THEME_FLAVORS" >&2
                return 2
            fi
            current="$(theme_current)" || return 1
            if [ "$current" = "$target" ]; then
                echo "Already $target; verifying."
                theme_check "$target" || return 1
                return 0
            fi
            theme_apply_names "$current" "$target" || return 1
            theme_map_hex "$current" "$target" || return 1
            theme_relabel "$current" "$target" || return 1
            printf '%s\n' "$target" > "$DOTFILES_DIR/config/catppuccin/flavor" || return 1
            theme_check "$target" || return 1
            echo "Switched $current -> $target. Review with git diff, run bash scripts/test.sh,"
            echo "then bash scripts/bootstrap_tools.sh (yazi flavor, bat theme on old packages),"
            echo "open a new shell and tmux server, and restart Windows Terminal on Windows."
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
    set -euo pipefail
    theme_main "$@"
fi
