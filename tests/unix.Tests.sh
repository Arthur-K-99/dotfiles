#!/usr/bin/env bash
set -euo pipefail

TEST_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_SCRIPT="$TEST_REPO_DIR/tests/unix.Tests.sh"

assert_equal() {
    if [ "$1" != "$2" ]; then
        printf 'Expected <%s>, got <%s>\n' "$1" "$2" >&2
        return 1
    fi
}

assert_contains() {
    case "$1" in
        *"$2"*) ;;
        *) printf 'Expected output to contain <%s>:\n%s\n' "$2" "$1" >&2; return 1 ;;
    esac
}

# Tests of the release installers serve their own fixture files; the digest
# check is covered by test_release_download_verification and the release age
# by test_release_age. Each asset that would be verified is listed in
# $test_dir/verified, every release is old enough, and each release whose age
# is checked is listed in $test_dir/aged.
trust_release_downloads() {
    release_asset_digest() {
        printf '%s\n' "$*" >> "$test_dir/verified"
        printf 'fixture\n'
    }
    file_sha256() { printf 'fixture\n'; }
    release_published() {
        printf '%s\n' "$*" >> "$test_dir/aged"
        printf '2020-01-01T00:00:00Z\n'
    }
}

test_syntax_every_file() {
    source "$TEST_REPO_DIR/scripts/test.sh"
    printf '#!/bin/bash\necho valid\n' > "$test_dir/first.sh"
    mkdir -p "$test_dir/scripts"
    printf '#!/bin/bash\nif then\n' > "$test_dir/scripts/second.sh"
    if check_bash_syntax "$test_dir" > "$test_dir/output" 2>&1; then
        echo "A syntax error in a later script was ignored." >&2
        return 1
    fi
    assert_contains "$(cat "$test_dir/output")" "second.sh"
    printf '#!/bin/bash\necho valid\n' > "$test_dir/scripts/second.sh"
    bash() {
        assert_equal 2 "$#" || return
        assert_equal -n "$1" || return
        printf '%s\n' "$2" >> "$test_dir/parsed-files"
        command bash "$@"
    }
    check_bash_syntax "$test_dir"
    assert_equal 2 "$(wc -l < "$test_dir/parsed-files" | tr -d ' ')"
}

test_link_fresh_and_repeat() {
    source "$TEST_REPO_DIR/scripts/link_dotfiles.sh"
    printf 'managed\n' > "$test_dir/source"
    link "$test_dir/source" "$test_dir/nested/destination"
    assert_equal "$test_dir/source" "$(readlink "$test_dir/nested/destination")"
    link "$test_dir/source" "$test_dir/nested/destination"
    assert_equal 0 "$(find "$test_dir" -name '*.bak.*' | wc -l | tr -d ' ')"
}

# The whole link stage on a home that already has a shell setup: the user's
# ~/.zshrc is backed up with a pointer to ~/.zshrc.local, and a ~/.tmux.conf
# of their own is moved aside, since tmux would load it as well and the
# doctor would fail; a rerun moves nothing. LINK_BACKUP names each backup.
test_link_main_moves_old_files_aside() {
    source "$TEST_REPO_DIR/scripts/link_dotfiles.sh"
    local home="$test_dir/home" backup
    mkdir -p "$home"
    printf 'my zshrc\n' > "$home/.zshrc"
    printf 'set -g mouse on\n' > "$home/.tmux.conf"
    HOME="$home" main > "$test_dir/output"
    assert_contains "$(cat "$test_dir/output")" "move what you still need into ~/.zshrc.local"
    assert_contains "$(cat "$test_dir/output")" "(tmux would load it as well as ~/.config/tmux/tmux.conf)"
    [ ! -e "$home/.tmux.conf" ]
    backup="$(find "$home" -maxdepth 1 -name '.tmux.conf.bak.*')"
    assert_equal 'set -g mouse on' "$(cat "$backup")"
    backup="$(find "$home" -maxdepth 1 -name '.zshrc.bak.*')"
    assert_equal 'my zshrc' "$(cat "$backup")"
    assert_equal "$TEST_REPO_DIR/home/.zshrc" "$(readlink "$home/.zshrc")"
    HOME="$home" main > "$test_dir/output"
    case "$(cat "$test_dir/output")" in
        *'backing up'*|*'zshrc.local'*) echo "A rerun moved files again." >&2; cat "$test_dir/output" >&2; return 1 ;;
    esac
    assert_equal 2 "$(find "$home" -maxdepth 1 -name '*.bak.*' | wc -l | tr -d ' ')"
    # The link earlier versions made at ~/.tmux.conf is retired, not backed
    # up; a ~/.zshrc that linked into another copy of this repository gets no
    # advice.
    ln -s "$TEST_REPO_DIR/home/.tmux.conf" "$home/.tmux.conf"
    rm "$home/.zshrc"
    ln -s /elsewhere/dotfiles/home/.zshrc "$home/.zshrc"
    HOME="$home" main > "$test_dir/output"
    assert_contains "$(cat "$test_dir/output")" "retired: $home/.tmux.conf"
    assert_equal 1 "$(find "$home" -maxdepth 1 -name '.tmux.conf.bak.*' | wc -l | tr -d ' ')"
    case "$(cat "$test_dir/output")" in
        *'zshrc.local'*) echo "A ~/.zshrc linked into the repository got advice." >&2; return 1 ;;
    esac
    # move_aside ignores a missing path and moves directories and links too.
    move_aside "$home/absent" test > "$test_dir/output"
    assert_equal '' "$(cat "$test_dir/output")"
    mkdir "$home/dir"
    ln -s "$home/nowhere" "$home/dangling"
    move_aside "$home/dir" test > /dev/null
    move_aside "$home/dangling" test > /dev/null
    [ ! -e "$home/dir" ]
    [ ! -L "$home/dangling" ]
    backup="$(find "$home" -maxdepth 1 -name 'dangling.bak.*')"
    [ -L "$backup" ]
    assert_equal 1 "$(find "$home" -maxdepth 1 -name 'dir.bak.*' -type d | wc -l | tr -d ' ')"
    printf 'managed\n' > "$test_dir/source"
    LINK_BACKUP=stale
    link "$test_dir/source" "$test_dir/fresh" > /dev/null
    assert_equal '' "$LINK_BACKUP"
    printf 'old\n' > "$test_dir/replaced"
    link "$test_dir/source" "$test_dir/replaced" > /dev/null
    assert_equal old "$(cat "$LINK_BACKUP")"
}

test_gitconfig_guard_creates_once() {
    source "$TEST_REPO_DIR/scripts/link_dotfiles.sh"
    ensure_gitconfig "$test_dir/.gitconfig"
    assert_contains "$(cat "$test_dir/.gitconfig")" 'not managed by the dotfiles repository'
    printf '[user]\n\tname = Someone\n' > "$test_dir/.gitconfig"
    ensure_gitconfig "$test_dir/.gitconfig"
    assert_equal $'[user]\n\tname = Someone' "$(cat "$test_dir/.gitconfig")"
    ln -s "$test_dir/elsewhere" "$test_dir/linked-gitconfig"
    ensure_gitconfig "$test_dir/linked-gitconfig"
    assert_equal "$test_dir/elsewhere" "$(readlink "$test_dir/linked-gitconfig")"
}

test_link_backups_and_collisions() {
    source "$TEST_REPO_DIR/scripts/link_dotfiles.sh"
    printf 'managed\n' > "$test_dir/source"
    printf 'original\n' > "$test_dir/destination"
    printf 'older backup\n' > "$test_dir/destination.bak.fixed"
    ln -s "$test_dir/missing" "$test_dir/destination.bak.fixed.1"
    date() { printf 'fixed\n'; }
    link "$test_dir/source" "$test_dir/destination"
    assert_equal original "$(cat "$test_dir/destination.bak.fixed.1.1")"
    assert_equal 'older backup' "$(cat "$test_dir/destination.bak.fixed")"
    assert_equal "$test_dir/missing" "$(readlink "$test_dir/destination.bak.fixed.1")"
    assert_equal managed "$(cat "$test_dir/destination")"
}

test_link_broken_wrong_and_relocated() {
    source "$TEST_REPO_DIR/scripts/link_dotfiles.sh"
    printf 'managed\n' > "$test_dir/source"
    printf 'unrelated\n' > "$test_dir/other"
    ln -s "$test_dir/absent" "$test_dir/broken"
    ln -s "$test_dir/other" "$test_dir/wrong"
    date() { printf 'fixed\n'; }
    link "$test_dir/source" "$test_dir/broken"
    link "$test_dir/source" "$test_dir/wrong"
    assert_equal "$test_dir/absent" "$(readlink "$test_dir/broken.bak.fixed")"
    assert_equal "$test_dir/other" "$(readlink "$test_dir/wrong.bak.fixed")"
    assert_equal unrelated "$(cat "$test_dir/other")"
    mkdir "$test_dir/old-repo"
    printf 'moved\n' > "$test_dir/old-repo/config"
    link "$test_dir/old-repo/config" "$test_dir/relocated"
    mv "$test_dir/old-repo" "$test_dir/new-repo"
    link "$test_dir/new-repo/config" "$test_dir/relocated"
    assert_equal "$test_dir/new-repo/config" "$(readlink "$test_dir/relocated")"
    assert_equal moved "$(cat "$test_dir/relocated")"
}

test_link_retires_moved_sources() {
    source "$TEST_REPO_DIR/scripts/link_dotfiles.sh"
    printf 'moved\n' > "$test_dir/old-source"
    ln -s "$test_dir/old-source" "$test_dir/stale"
    printf 'user content\n' > "$test_dir/user-file"
    ln -s "$test_dir/elsewhere" "$test_dir/foreign"
    retire_link "$test_dir/old-source" "$test_dir/stale"
    [ ! -L "$test_dir/stale" ]
    [ ! -e "$test_dir/stale" ]
    assert_equal moved "$(cat "$test_dir/old-source")"
    # Only a link to the retired source goes: the user's own files and links stay.
    retire_link "$test_dir/old-source" "$test_dir/user-file"
    assert_equal 'user content' "$(cat "$test_dir/user-file")"
    retire_link "$test_dir/old-source" "$test_dir/foreign"
    assert_equal "$test_dir/elsewhere" "$(readlink "$test_dir/foreign")"
    retire_link "$test_dir/old-source" "$test_dir/absent"
    [ ! -e "$test_dir/absent" ]
    # An emptied real directory goes; one with content or a directory link stays.
    mkdir "$test_dir/empty" "$test_dir/full"
    printf 'keep\n' > "$test_dir/full/file"
    ln -s "$test_dir/full" "$test_dir/dir-link"
    remove_empty_directory "$test_dir/empty"
    remove_empty_directory "$test_dir/full"
    remove_empty_directory "$test_dir/dir-link"
    remove_empty_directory "$test_dir/no-such-dir"
    [ ! -e "$test_dir/empty" ]
    [ -f "$test_dir/full/file" ]
    [ -L "$test_dir/dir-link" ]
    ln -s "$test_dir/old-source" "$test_dir/stuck"
    rm() { return 33; }
    if retire_link "$test_dir/old-source" "$test_dir/stuck"; then
        echo "A failed removal was reported as success." >&2
        return 1
    fi
    unset -f rm
    assert_equal "$test_dir/old-source" "$(readlink "$test_dir/stuck")"
}

test_tmux_config_declares_plugins_in_order() {
    local conf="$TEST_REPO_DIR/config/tmux/tmux.conf"
    local plugins catppuccin_line status_line tpm_line last_line
    plugins="$(sed -n "s/^set -g @plugin '\([^']*\)'.*/\1/p" "$conf")"
    assert_equal tmux-plugins/tpm "$(printf '%s\n' "$plugins" | head -n 1)"
    # continuum hooks status-right, so it runs last; resurrect must precede it.
    assert_equal tmux-plugins/tmux-continuum "$(printf '%s\n' "$plugins" | tail -n 1)"
    assert_equal tmux-plugins/tmux-resurrect "$(printf '%s\n' "$plugins" | tail -n 2 | head -n 1)"
    for plugin in tmux-plugins/tmux-sensible christoomey/vim-tmux-navigator tmux-plugins/tmux-yank \
        sainnhe/tmux-fzf omerxx/tmux-floax 'catppuccin/tmux#v' tmux-plugins/tmux-cpu tmux-plugins/tmux-battery; do
        assert_contains "$plugins" "$plugin"
    done
    assert_equal 1 "$(grep -c '^set -g @plugin .catppuccin/tmux#v2' "$conf")"
    # The theme runs before the status modules are set, and TPM is the last line.
    catppuccin_line="$(grep -n 'plugins/tmux/catppuccin.tmux' "$conf" | head -n 1 | cut -d: -f1)"
    status_line="$(grep -n '^set -g status-right ' "$conf" | head -n 1 | cut -d: -f1)"
    tpm_line="$(grep -n 'plugins/tpm/tpm' "$conf" | tail -n 1 | cut -d: -f1)"
    last_line="$(grep -c '' "$conf")"
    [ "$catppuccin_line" -lt "$status_line" ] || return 1
    [ "$status_line" -lt "$tpm_line" ] || return 1
    assert_equal "$last_line" "$tpm_line"
    # cpu and battery expand through -F so their plugins can fill in the numbers.
    grep -q '^set -agF status-right "#{E:@catppuccin_status_cpu}"$' "$conf"
    grep -q '^set -agF status-right "#{E:@catppuccin_status_battery}"$' "$conf"
    grep -q "^set -g @catppuccin_flavor '$(cat "$TEST_REPO_DIR/config/catppuccin/flavor")'$" "$conf"
    # The plugin files the doctor checks are the ones declared here.
    for plugin in $(printf '%s\n' "$plugins" | sed -e 's|#.*||' -e 's|.*/||'); do
        [ "$plugin" = tpm ] && continue
        grep -q "$plugin/" "$TEST_REPO_DIR/scripts/doctor.sh" || { echo "doctor.sh does not check $plugin" >&2; return 1; }
    done
}

# oh-my-posh exports its built-in theme, with status 0, for a configuration it
# cannot read; the check compares the export's palette and segments with the
# file's.
test_oh_my_posh_config_check() {
    source "$TEST_REPO_DIR/scripts/test.sh"
    local status
    printf '{"palette": {"os": "#A5ADCB"}, "blocks": [{"type": "prompt", "segments": [{"type": "os"}, {"type": "path"}]}]}\n' > "$test_dir/config.json"
    oh-my-posh() {
        [ "$*" = "config export --config $test_dir/config.json --format json" ] || return 98
        # Filled-in defaults, as the real export adds, must not matter.
        printf '{"palette": {"os": "#A5ADCB"}, "version": 3, "blocks": [{"type": "prompt", "alignment": "left", "segments": [{"type": "os", "style": "plain"}, {"type": "path"}]}]}\n'
    }
    check_oh_my_posh_config "$test_dir/config.json"
    oh-my-posh() { printf '{"palette": {"black": "#262B44"}, "blocks": [{"segments": [{"type": "session"}]}]}\n'; }
    status=0
    check_oh_my_posh_config "$test_dir/config.json" > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'it cannot read the file'
    status=0
    check_oh_my_posh_config "$test_dir/absent.json" > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'Cannot read'
    oh-my-posh() { return 9; }
    status=0
    check_oh_my_posh_config "$test_dir/config.json" > "$test_dir/output" 2>&1 || status=$?
    assert_equal 9 "$status"
}

test_tmux_config_loads_and_errors_are_reported() {
    source "$TEST_REPO_DIR/scripts/test.sh"
    export TMPDIR="$test_dir/tmp"
    mkdir -p "$TMPDIR"
    check_tmux_config "$TEST_REPO_DIR/config/tmux/tmux.conf"
    printf 'set -g base-index 1\nbind\n' > "$test_dir/broken.conf"
    local status=0
    check_tmux_config "$test_dir/broken.conf" > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'broken.conf'
    # Both runs clean up their private server directories.
    assert_equal 0 "$(find "$TMPDIR" -maxdepth 1 -name 'dotfiles-tmux-check.*' | wc -l | tr -d ' ')"
    # A machine-local file is loaded when it exists.
    local socket="dotfiles-local-$$" value
    mkdir -p "$test_dir/home/.config/tmux"
    printf 'set -g @dotfiles-local-test loaded\n' > "$test_dir/home/.config/tmux/local.conf"
    HOME="$test_dir/home" tmux -L "$socket" -f /dev/null start-server \; set-option -g exit-empty off \; \
        source-file "$TEST_REPO_DIR/config/tmux/tmux.conf" > "$test_dir/output" 2>&1 || :
    value="$(tmux -L "$socket" show-options -gqv @dotfiles-local-test 2>&1)" || :
    tmux -L "$socket" kill-server >/dev/null 2>&1 || :
    assert_equal '' "$(cat "$test_dir/output")"
    assert_equal loaded "$value"
}

test_theme_switch_round_trip() {
    source "$TEST_REPO_DIR/scripts/theme.sh"
    mkdir -p "$test_dir/repo"
    cp -R "$TEST_REPO_DIR/config" "$TEST_REPO_DIR/home" "$TEST_REPO_DIR/docs" "$test_dir/repo/"
    cp -R "$test_dir/repo" "$test_dir/original"
    DOTFILES_DIR="$test_dir/repo"
    local repo="$test_dir/repo"
    local start to other title base blue surface0 file
    # The repository may record any flavor: the test starts from it, visits
    # every other one and expects the original bytes back at the end.
    start="$(theme_current)"
    theme_main --check > "$test_dir/output"
    for to in $THEME_FLAVORS; do
        [ "$to" = "$start" ] && continue
        theme_main "$to" > "$test_dir/output"
        title="$(theme_title "$to")"
        base="$(theme_color "$to" base)"
        blue="$(theme_color "$to" blue)"
        surface0="$(theme_color "$to" surface0)"
        assert_equal "$to" "$(cat "$repo/config/catppuccin/flavor")"
        grep -q "^set -g @catppuccin_flavor '$to'$" "$repo/config/tmux/tmux.conf"
        grep -q -- "^--theme=\"Catppuccin $title\"$" "$repo/config/bat/config"
        grep -q "^theme = light:Catppuccin Latte,dark:Catppuccin $title$" "$repo/config/ghostty/config"
        grep -q "features = catppuccin-$to$" "$repo/config/git/config"
        grep -q "^name = \"catppuccin-$to-blue\"$" "$repo/config/atuin/config.toml"
        grep -q "^dark = \"catppuccin-$to\"$" "$repo/config/yazi/theme.toml"
        grep -q '^light = "catppuccin-latte"$' "$repo/config/yazi/theme.toml"
        grep -q "background = { light = \"latte\", dark = \"$to\" }," "$repo/config/nvim/lua/plugins/colorscheme.lua"
        grep -q "vivid generate catppuccin-$to " "$repo/home/.zshrc"
        grep -q "\"name\": \"Catppuccin $title\"" "$repo/config/windows-terminal/fragment.json"
        grep -q "\"background\": \"$(theme_upper "$base")\"" "$repo/config/windows-terminal/fragment.json"
        grep -q "\"colorScheme\": \"Catppuccin $title\"" "$repo/config/windows-terminal/fragment.json"
        grep -q "bg:$base" "$repo/home/.zshrc"
        grep -q "bg:$base" "$repo/config/powershell/profile.ps1"
        grep -q "48;2;$(theme_rgb "$surface0")" "$repo/config/powershell/profile.ps1"
        grep -q "\"blue\": \"$(theme_upper "$blue")\"" "$repo/config/oh-my-posh/config.omp.json"
        grep -q "directory: { foreground: \"$(theme_upper "$blue")\" }" "$repo/config/eza/theme.yml"
        grep -q "'$blue'" "$repo/config/lazygit/config.yml"
        grep -q "themes-mergable/$to/blue.yml" "$repo/config/lazygit/config.yml"
        grep -q "\"keys\": \"$blue\"" "$repo/config/fastfetch/config.jsonc"
        grep -q "Catppuccin $title hex values" "$repo/config/fastfetch/config.jsonc"
        grep -q "Catppuccin \*\*$title\*\*" "$repo/docs/theming.md"
        grep -q "\`$(theme_upper "$blue")\`" "$repo/docs/theming.md"
        # No value of the starting flavor survives anywhere the switcher manages.
        for file in $(theme_hex_files); do
            if grep -i -q -E "#($(theme_hex_pattern "$start"))" "$repo/$file"; then
                echo "$file still carries $start colors after switching to $to." >&2
                return 1
            fi
        done
        theme_main --check > "$test_dir/output"
        assert_contains "$(cat "$test_dir/output")" "agrees on $to"
    done
    # Switching back restores every byte.
    theme_main "$start" > "$test_dir/output"
    diff -r "$test_dir/original" "$repo"
    # Unknown flavors are refused and an inconsistent tree fails the check.
    local status=0
    theme_main mint > "$test_dir/output" 2>&1 || status=$?
    assert_equal 2 "$status"
    diff -r "$test_dir/original" "$repo"
    other=mocha
    [ "$start" != mocha ] || other=macchiato
    printf '%s\n' "$other" > "$repo/config/catppuccin/flavor"
    status=0
    theme_main --check > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" "does not contain"
    printf '%s\n' "$start" > "$repo/config/catppuccin/flavor"
    sed -e "s/$(theme_upper "$(theme_color "$start" blue | cut -c2-)")/$(theme_upper "$(theme_color "$other" blue | cut -c2-)")/" \
        "$test_dir/original/config/eza/theme.yml" > "$repo/config/eza/theme.yml"
    status=0
    theme_main --check > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" "still carries a $other color"
}

test_link_failed_replacement() {
    source "$TEST_REPO_DIR/scripts/link_dotfiles.sh"
    printf 'managed\n' > "$test_dir/source"
    printf 'original\n' > "$test_dir/destination"
    ln() { return 31; }
    if link "$test_dir/source" "$test_dir/destination"; then
        echo "Symlink creation failure was ignored." >&2
        return 1
    fi
    unset -f ln
    assert_equal original "$(cat "$test_dir/destination")"
    assert_equal 0 "$(find "$test_dir" -name '*.bak.*' | wc -l | tr -d ' ')"
    mv() {
        case "$1" in
            */.dotfiles-link.*/link) return 32 ;;
            *) command mv "$@" ;;
        esac
    }
    if link "$test_dir/source" "$test_dir/destination"; then
        echo "Replacement failure was ignored." >&2
        return 1
    fi
    unset -f mv
    assert_equal original "$(cat "$test_dir/destination")"
    [ ! -L "$test_dir/destination" ]
    assert_equal 0 "$(find "$test_dir" -name '.dotfiles-link.*' | wc -l | tr -d ' ')"
    if link "$test_dir/missing-source" "$test_dir/destination"; then
        echo "A missing source was linked." >&2
        return 1
    fi
    assert_equal original "$(cat "$test_dir/destination")"
    link "$test_dir/source" "$test_dir/destination"
    assert_equal managed "$(cat "$test_dir/destination")"
}

test_environment_discovery() {
    source "$TEST_REPO_DIR/scripts/lib/environment.sh"
    mkdir -p "$test_dir/apple/bin" "$test_dir/intel/bin"
    cat > "$test_dir/apple/bin/brew" <<'BREW'
#!/bin/sh
[ "$1" = shellenv ] || exit 1
printf 'export PATH="%s:$PATH"\n' "$DOTFILES_TEST_BREW_BIN"
BREW
    cp "$test_dir/apple/bin/brew" "$test_dir/intel/bin/brew"
    printf '#!/bin/sh\nexit 0\n' > "$test_dir/apple/bin/dotfiles-fixture-command"
    chmod +x "$test_dir/apple/bin/"* "$test_dir/intel/bin/brew"
    command() {
        if [ "$*" = '-v brew' ]; then
            return 1
        fi
        builtin command "$@"
    }
    assert_equal "$test_dir/apple/bin/brew" "$(dotfiles_find_homebrew "$test_dir/apple/bin/brew" "$test_dir/intel/bin/brew")"
    chmod -x "$test_dir/apple/bin/brew"
    assert_equal "$test_dir/intel/bin/brew" "$(dotfiles_find_homebrew "$test_dir/apple/bin/brew" "$test_dir/intel/bin/brew")"
    chmod +x "$test_dir/apple/bin/brew"
    command() {
        if [ "$*" = '-v brew' ]; then
            printf '/existing/brew\n'
            return 0
        fi
        builtin command "$@"
    }
    assert_equal /existing/brew "$(dotfiles_find_homebrew "$test_dir/apple/bin/brew" "$test_dir/intel/bin/brew")"
    unset -f command
    uname() { printf 'Darwin\n'; }
    dotfiles_find_homebrew() { printf '%s/brew\n' "$DOTFILES_TEST_BREW_BIN"; }
    export DOTFILES_TEST_BREW_BIN="$test_dir/apple/bin"
    PATH=/usr/bin:/bin
    dotfiles_init_environment
    assert_equal "$test_dir/apple/bin/dotfiles-fixture-command" "$(command -v dotfiles-fixture-command)"
    assert_contains ":$PATH:" ":$HOME/.local/bin:"
    # Later installer stages can discover both newly installed Homebrew tools and local tools.
    assert_equal "$test_dir/apple/bin/dotfiles-fixture-command" "$(/bin/bash -c 'command -v dotfiles-fixture-command')"
    export DOTFILES_TEST_BREW_BIN="$test_dir/intel/bin"
    PATH=/usr/bin:/bin
    dotfiles_init_environment
    assert_contains ":$PATH:" ":$test_dir/intel/bin:"
    assert_contains ":$PATH:" ":$HOME/.local/bin:"
}

# The login shell comes from the account database, getent on Linux and
# Directory Services on macOS, and from SHELL only when neither answers.
test_login_shell_discovery() {
    source "$TEST_REPO_DIR/scripts/lib/environment.sh"
    id() { printf 'dev\n'; }
    getent() { [ "$1 $2" = 'passwd dev' ] && printf 'dev:x:1000:1000::/home/dev:/usr/bin/zsh\n'; }
    assert_equal /usr/bin/zsh "$(SHELL=/bin/bash dotfiles_login_shell)"
    unset -f getent
    command() {
        case "$*" in
            '-v getent') return 1 ;;
            *) builtin command "$@" ;;
        esac
    }
    dscl() { [ "$*" = '. -read /Users/dev UserShell' ] && printf 'UserShell: /bin/zsh\n'; }
    assert_equal /bin/zsh "$(SHELL=/bin/bash dotfiles_login_shell)"
    dscl() { return 56; }
    assert_equal /bin/bash "$(SHELL=/bin/bash dotfiles_login_shell)"
    assert_equal '' "$(unset SHELL; dotfiles_login_shell)"
}

test_package_index_failure() {
    source "$TEST_REPO_DIR/scripts/install_packages.sh"
    check_linux_distribution() { return 0; }
    sudo() {
        printf '%s\n' "$*" >> "$test_dir/commands"
        if [ "$*" = 'apt-get update -qq' ] && [ ! -f "$test_dir/retry" ]; then
            return 42
        fi
    }
    apt-mark() { :; }
    local status=0
    install_linux > "$test_dir/output" 2>&1 || status=$?
    assert_equal 42 "$status"
    assert_equal 'apt-get update -qq' "$(cat "$test_dir/commands")"
    : > "$test_dir/retry"
    install_linux
    assert_contains "$(cat "$test_dir/commands")" 'apt-get install -y'
}

test_macos_font_install_and_repair() {
    source "$TEST_REPO_DIR/scripts/install_packages.sh"
    parse_list() {
        case "$1" in
            */brew-casks.txt) printf 'font-caskaydia-cove-nerd-font\n' ;;
            *) printf 'git\n' ;;
        esac
    }
    compgen() { [ -f "$test_dir/font-present" ]; }
    brew() {
        printf '%s\n' "$*" >> "$test_dir/commands"
        case "$*" in
            'list --cask '*) [ -f "$test_dir/registered" ] ;;
            'install --cask '*|'reinstall --cask '*)
                [ ! -f "$test_dir/fail-font" ] || return 49
                : > "$test_dir/registered"
                : > "$test_dir/font-present"
                ;;
        esac
    }
    install_macos
    assert_contains "$(cat "$test_dir/commands")" 'install --cask font-caskaydia-cove-nerd-font'
    : > "$test_dir/commands"
    install_macos
    assert_equal $'list --formula -1\ninstall git' "$(cat "$test_dir/commands")"
    rm "$test_dir/font-present"
    : > "$test_dir/fail-font"
    local status=0
    install_macos > "$test_dir/output" 2>&1 || status=$?
    assert_equal 49 "$status"
    assert_contains "$(cat "$test_dir/commands")" 'reinstall --cask font-caskaydia-cove-nerd-font'
    rm "$test_dir/fail-font"
    install_macos
    [ -f "$test_dir/font-present" ]
}

test_macos_formulae_survive_stdin_consumers() {
    source "$TEST_REPO_DIR/scripts/install_packages.sh"
    parse_list() {
        case "$1" in
            */brew.txt) printf 'first\nsecond\nthird\n' ;;
            *) printf 'ghostty\n' ;;
        esac
    }
    dotfiles_macos_app_installed() { return 1; }
    # Homebrew's install steps can read stdin, which is the loop's package list.
    brew() {
        printf '%s\n' "$*" >> "$test_dir/commands"
        case "$*" in
            'list --formula -1') printf 'second\nsecond-helper\n' ;;
            'list --cask '*) return 1 ;;
            *) cat >/dev/null ;;
        esac
    }
    install_macos > "$test_dir/output"
    # Only the missing formulae are named, in one install.
    assert_equal $'list --formula -1\ninstall first third\nlist --cask ghostty\ninstall --cask ghostty' "$(cat "$test_dir/commands")"
    assert_contains "$(cat "$test_dir/output")" '  already installed: second'
    # With everything installed, brew install is not run at all.
    brew() {
        printf '%s\n' "$*" >> "$test_dir/commands"
        case "$*" in
            'list --formula -1') printf 'first\nsecond\nthird\n' ;;
            'list --cask '*) return 0 ;;
            *) cat >/dev/null ;;
        esac
    }
    dotfiles_macos_app_installed() { return 0; }
    : > "$test_dir/commands"
    install_macos > "$test_dir/output"
    assert_equal 'list --formula -1' "$(cat "$test_dir/commands")"
    assert_contains "$(cat "$test_dir/output")" '  already installed: first second third'
    # A failed listing stops the stage.
    brew() { [ "$*" != 'list --formula -1' ]; }
    local status=0
    install_macos > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
}

# Updating, Homebrew refreshes its index and upgrades the declared formulae
# and casks it reports as outdated; pinned ones and undeclared ones stay.
# A plain rerun neither refreshes nor upgrades on its own.
test_macos_update_upgrades_declared() {
    source "$TEST_REPO_DIR/scripts/install_packages.sh"
    export DOTFILES_TEST_FIXTURE="$test_dir"
    parse_list() {
        case "$1" in
            */brew-casks.txt) printf 'ghostty\nfont-caskaydia-cove-nerd-font\n' ;;
            *) printf 'git\nneovim\nlazygit\n' ;;
        esac
    }
    macos_cask_is_satisfied() { return 0; }
    brew() {
        printf '%s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/commands"
        case "$*" in
            'outdated --formula --quiet') cat "$DOTFILES_TEST_FIXTURE/outdated-formulae" 2>/dev/null || : ;;
            'outdated --cask --quiet') cat "$DOTFILES_TEST_FIXTURE/outdated-casks" 2>/dev/null || : ;;
            'list --pinned --formula') cat "$DOTFILES_TEST_FIXTURE/pinned" 2>/dev/null || : ;;
            'list --pinned --cask') : ;;
            upgrade*) [ -f "$DOTFILES_TEST_FIXTURE/retry" ] || return 58 ;;
            install*) printf '%s\n' "${HOMEBREW_NO_INSTALL_UPGRADE:-unset}" >> "$DOTFILES_TEST_FIXTURE/no-install-upgrade" ;;
        esac
    }
    install_macos > "$test_dir/output"
    assert_equal $'list --formula -1\ninstall git neovim lazygit' "$(cat "$test_dir/commands")"
    assert_equal unset "$(sort -u "$test_dir/no-install-upgrade")"
    # Current: the index is refreshed and nothing is upgraded.
    export DOTFILES_UPDATE=1
    : > "$test_dir/commands"
    : > "$test_dir/no-install-upgrade"
    install_macos > "$test_dir/output"
    assert_equal $'update\noutdated --formula --quiet\nlist --pinned --formula\noutdated --cask --quiet\nlist --pinned --cask\nlist --formula -1\ninstall git neovim lazygit' "$(cat "$test_dir/commands")"
    # The install loop only adds what is missing; the upgrades above decide.
    assert_equal 1 "$(sort -u "$test_dir/no-install-upgrade")"
    # Newer releases: a pinned formula and an undeclared one stay; a failed
    # upgrade stops the stage and the retry finishes it.
    printf 'neovim\nlazygit\nruff\n' > "$test_dir/outdated-formulae"
    printf 'lazygit\n' > "$test_dir/pinned"
    printf 'font-caskaydia-cove-nerd-font\nfirefox\n' > "$test_dir/outdated-casks"
    local status=0
    install_macos > "$test_dir/output" 2>&1 || status=$?
    assert_equal 58 "$status"
    assert_equal 'upgrade --formula neovim' "$(tail -n 1 "$test_dir/commands")"
    : > "$test_dir/retry"
    : > "$test_dir/commands"
    install_macos > "$test_dir/output"
    assert_equal 'upgrade --formula neovim' "$(grep '^upgrade --formula' "$test_dir/commands")"
    assert_equal 'upgrade --cask font-caskaydia-cove-nerd-font' "$(grep '^upgrade --cask' "$test_dir/commands")"
    assert_contains "$(cat "$test_dir/output")" 'pinned, left alone: lazygit (brew unpin lazygit to upgrade it)'
}

test_macos_app_cask_detection() {
    source "$TEST_REPO_DIR/scripts/install_packages.sh"
    parse_list() {
        case "$1" in
            */brew-casks.txt) printf 'ghostty\n' ;;
            *) : ;;
        esac
    }
    dotfiles_macos_app_installed() {
        assert_equal Ghostty "$1" || exit 1
        [ -f "$test_dir/app-present" ]
    }
    brew() {
        printf '%s\n' "$*" >> "$test_dir/commands"
        case "$*" in
            'list --cask '*) [ -f "$test_dir/registered" ] ;;
            'install --cask '*|'reinstall --cask '*)
                : > "$test_dir/registered"
                : > "$test_dir/app-present"
                ;;
        esac
    }
    # An app installed by hand satisfies the cask without calling brew.
    : > "$test_dir/app-present"
    install_macos
    [ ! -f "$test_dir/commands" ]
    rm "$test_dir/app-present"
    install_macos
    assert_equal 1 "$(grep -c 'install --cask ghostty' "$test_dir/commands")"
    [ -f "$test_dir/app-present" ]
    : > "$test_dir/commands"
    install_macos
    assert_equal '' "$(cat "$test_dir/commands")"
    # A registered cask whose app was removed is repaired, not reinstalled.
    rm "$test_dir/app-present"
    install_macos
    assert_equal 'reinstall --cask ghostty' "$(tail -n 1 "$test_dir/commands")"
}

test_install_stages_and_failure_reporting() {
    source "$TEST_REPO_DIR/install.sh"
    dotfiles_init_environment() { return 0; }
    bash() {
        local stage="${1##*/}"
        printf '%s\n' "$stage" >> "$test_dir/stages"
        if [ "$stage" = "$failed_stage" ]; then
            return 43
        fi
    }
    local failed_stage=''
    local status=0
    install_main > "$test_dir/output" 2>&1
    assert_equal $'install_packages.sh\nlink_dotfiles.sh\nbootstrap_tools.sh\ndoctor.sh' "$(cat "$test_dir/stages")"
    assert_contains "$(cat "$test_dir/output")" 'Done.'
    for failed_stage in install_packages.sh bootstrap_tools.sh doctor.sh; do
        : > "$test_dir/stages"
        status=0
        install_main > "$test_dir/output" 2>&1 || status=$?
        assert_equal 43 "$status"
        assert_equal "$failed_stage" "$(tail -n 1 "$test_dir/stages")"
        assert_contains "$(cat "$test_dir/output")" 'Setup stopped during:'
        assert_contains "$(cat "$test_dir/output")" 'rerun:'
        case "$(cat "$test_dir/output")" in
            *Done.*) echo 'A failed installation printed success.' >&2; return 1 ;;
        esac
    done
    failed_stage=''
    # The closing advice depends on the login shell, not on SHELL.
    dotfiles_login_shell() { printf '/bin/bash\n'; }
    SHELL=/bin/zsh install_main > "$test_dir/output" 2>&1
    assert_contains "$(cat "$test_dir/output")" 'All setup checks passed.'
    assert_contains "$(cat "$test_dir/output")" 'Your login shell is /bin/bash'
    assert_contains "$(cat "$test_dir/output")" '  chsh -s '
    dotfiles_login_shell() { printf '/usr/bin/zsh\n'; }
    SHELL=/bin/bash install_main > "$test_dir/output" 2>&1
    assert_contains "$(cat "$test_dir/output")" 'Open a new zsh session'
    case "$(cat "$test_dir/output")" in
        *chsh*) echo "A zsh login shell was told to run chsh." >&2; return 1 ;;
    esac
    unset -f dotfiles_login_shell
    # A minimum release age the bootstrap could not read stops every stage.
    : > "$test_dir/stages"
    status=0
    DOTFILES_MINIMUM_RELEASE_AGE=tomorrow install_main > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'DOTFILES_MINIMUM_RELEASE_AGE=tomorrow is not a whole number with a unit'
    assert_equal '' "$(cat "$test_dir/stages")"
}

# scripts/update.sh runs the install stages with DOTFILES_UPDATE=1 and names
# itself in the rerun advice.
test_update_stages_and_failure_reporting() {
    source "$TEST_REPO_DIR/scripts/update.sh"
    dotfiles_init_environment() { return 0; }
    bash() {
        local stage="${1##*/}"
        printf '%s %s\n' "$stage" "${DOTFILES_UPDATE:-unset}" >> "$test_dir/stages"
        if [ "$stage" = "$failed_stage" ]; then
            return 43
        fi
    }
    local failed_stage=bootstrap_tools.sh
    local status=0
    update_main > "$test_dir/output" 2>&1 || status=$?
    assert_equal 43 "$status"
    assert_equal $'install_packages.sh 1\nlink_dotfiles.sh 1\nbootstrap_tools.sh 1' "$(cat "$test_dir/stages")"
    assert_contains "$(cat "$test_dir/output")" 'Setup stopped during: Updating tools (exit 43).'
    assert_contains "$(cat "$test_dir/output")" "rerun:
  bash $TEST_REPO_DIR/scripts/update.sh"
    failed_stage=''
    : > "$test_dir/stages"
    update_main > "$test_dir/output" 2>&1
    assert_equal $'install_packages.sh 1\nlink_dotfiles.sh 1\nbootstrap_tools.sh 1\ndoctor.sh 1' "$(cat "$test_dir/stages")"
    assert_contains "$(cat "$test_dir/output")" '==> Updating packages'
    assert_contains "$(cat "$test_dir/output")" 'Done. Everything is up to date and all setup checks passed.'
}

test_eza_index_and_download_failures() {
    source "$TEST_REPO_DIR/scripts/bootstrap_tools.sh"
    export DOTFILES_LOCAL_BIN="$test_dir/bin"
    export DOTFILES_APT_ETC="$test_dir/etc-apt"
    command() {
        case "$*" in
            '-v eza') return 1 ;;
            *) builtin command "$@" ;;
        esac
    }
    # test_apt_key_pinning covers the key itself.
    install_apt_key() {
        printf 'install_apt_key %s\n' "$*" >> "$test_dir/commands"
        [ ! -f "$test_dir/wrong-key" ] || return 1
    }
    sudo() {
        printf '%s\n' "$*" >> "$test_dir/commands"
        case "$1" in
            tee) cat >/dev/null ;;
            apt-get)
                if [ "$2" = update ] && [ ! -f "$test_dir/retry" ]; then
                    return 44
                fi
                ;;
        esac
    }
    # A key that is not the pinned one adds no repository.
    : > "$test_dir/wrong-key"
    local status=0
    install_eza > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_equal 'install_apt_key gierens' "$(cat "$test_dir/commands")"
    rm "$test_dir/wrong-key"
    status=0
    install_eza > "$test_dir/output" 2>&1 || status=$?
    assert_equal 44 "$status"
    assert_equal 'apt-get update -qq' "$(tail -n 1 "$test_dir/commands")"
    : > "$test_dir/retry"
    install_eza
    assert_equal 'apt-get install -y eza' "$(tail -n 1 "$test_dir/commands")"
    assert_contains "$(cat "$test_dir/commands")" "tee $test_dir/etc-apt/sources.list.d/gierens.list"
    # The shared helper installs only the missing packages of a repository.
    command() {
        case "$*" in
            '-v glow') return 1 ;;
            '-v gum') return 0 ;;
            *) builtin command "$@" ;;
        esac
    }
    : > "$test_dir/commands"
    install_charm_tools
    assert_equal 'apt-get install -y glow' "$(tail -n 1 "$test_dir/commands")"
    assert_equal 'install_apt_key charm' "$(grep '^install_apt_key' "$test_dir/commands")"
    assert_contains "$(cat "$test_dir/commands")" "tee $test_dir/etc-apt/sources.list.d/charm.list"
    command() {
        case "$*" in
            '-v glow'|'-v gum') return 0 ;;
            *) builtin command "$@" ;;
        esac
    }
    : > "$test_dir/commands"
    install_charm_tools
    assert_equal '' "$(cat "$test_dir/commands")"
}

# A repository's signing key is installed only when the downloaded file holds
# exactly the pinned key. A keyring that already holds the pinned key gets
# the download merged into it in throwaway gpg homes, so an extended key
# keeps its older self-signature beside the new one; it needs no sudo when
# the download adds nothing. A keyring holding anything else is replaced.
# The update's refresh keeps an existing keyring when the key cannot be
# downloaded, but not when it fails its pin.
# The mocked gpg models a home as the lines imported into it: an export is a
# marker line and the sorted union of that key's lines, so a merge shows.
# Where gpg and curl are installed, real keys check key_details on armored
# and binary files without leaving a ~/.gnupg, and a real extension goes
# through the whole install. The gpg homes live in a short directory under
# /tmp, as an agent's socket path inside a home under a long TMPDIR (macOS)
# would be too long.
test_apt_key_pinning() {
    source "$TEST_REPO_DIR/scripts/lib/apt_repositories.sh"
    export DOTFILES_TEST_FIXTURE="$test_dir"
    export TMPDIR="$test_dir/tmp"
    export DOTFILES_APT_ETC="$test_dir/etc-apt"
    mkdir -p "$TMPDIR"
    DOTFILES_GPG_TMPDIR="$(mktemp -d /tmp/dk.XXXXXX)"
    export DOTFILES_GPG_TMPDIR
    trap '{ dotfiles_gpg_home_remove "$DOTFILES_GPG_TMPDIR"/* || :; } 2>/dev/null; rm -rf "$test_dir" "$DOTFILES_GPG_TMPDIR"' EXIT
    local pinned=1548BC8A4B4D2688F9B0DAF7EC29E2090CE3FD43
    local other=0123456789ABCDEF0123456789ABCDEF01234567
    local keyring="$DOTFILES_APT_ETC/keyrings/gierens.gpg"
    local found mode status
    dotfiles_apt_repository() {
        [ "$1" = gierens ] || return 1
        echo "https://example.invalid/deb.asc $pinned deb [signed-by=/etc/apt/keyrings/gierens.gpg] https://example.invalid stable main"
    }
    curl() {
        local output=''
        printf 'curl %s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/commands"
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -o) output="$2"; shift ;;
            esac
            shift
        done
        [ ! -f "$DOTFILES_TEST_FIXTURE/offline" ] || return 22
        cp "$DOTFILES_TEST_FIXTURE/served" "$output"
    }
    # A key file here is lines of "key <fingerprint> <material>".
    key_details() { awk '$1 == "key" && !seen[$2]++ { print $2 }' "$1"; }
    gpg() {
        local mode='' file='' fpr=''
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --batch|--quiet) ;;
                --import) mode=import ;;
                --export) mode=export; fpr="$2"; shift ;;
                --) file="$2"; shift ;;
                *) echo "unexpected gpg argument: $1" >&2; return 99 ;;
            esac
            shift
        done
        case "${GNUPGHOME:-}" in
            "$DOTFILES_GPG_TMPDIR"/*) [ -d "$GNUPGHOME" ] || { echo "gpg home $GNUPGHOME does not exist" >&2; return 99; } ;;
            *) echo "gpg ran outside a throwaway home: ${GNUPGHOME:-unset}" >&2; return 99 ;;
        esac
        case "$mode" in
            import)
                if [ -f "$DOTFILES_TEST_FIXTURE/import-fails" ]; then
                    echo 'gpg: no valid OpenPGP data found.' >&2
                    return 2
                fi
                cat "$file" >> "$GNUPGHOME/imported"
                ;;
            export)
                echo "exported $fpr"
                if [ ! -f "$DOTFILES_TEST_FIXTURE/export-nothing" ]; then
                    { grep "^key $fpr " "$GNUPGHOME/imported" || :; } | sort -u
                fi
                ;;
            *) echo 'gpg was asked neither to import nor to export' >&2; return 99 ;;
        esac
    }
    gpgconf() { printf '%s %s\n' "${GNUPGHOME:-unset}" "$*" >> "$DOTFILES_TEST_FIXTURE/gpgconf"; }
    # sudo runs the two commands that install the keyring, within the test directory.
    sudo() {
        printf '%s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/sudo"
        case "$*" in
            "install -d -m 755 $DOTFILES_APT_ETC/keyrings"|"install -m 644 $TMPDIR/"*" $DOTFILES_APT_ETC/keyrings/gierens.gpg") "$@" ;;
            *) echo "unexpected sudo $*" >&2; return 98 ;;
        esac
    }
    # No keyring yet: the pinned key is installed, and both throwaway homes
    # lose their agents and go away.
    printf 'key %s signed-2024\n' "$pinned" > "$test_dir/served"
    : > "$test_dir/sudo"
    install_apt_key gierens > "$test_dir/output"
    assert_equal "Installing the gierens repository's signing key from https://example.invalid/deb.asc..." "$(cat "$test_dir/output")"
    assert_equal "exported $pinned"$'\n'"key $pinned signed-2024" "$(cat "$keyring")"
    assert_equal "install -d -m 755 $DOTFILES_APT_ETC/keyrings" "$(sed -n 1p "$test_dir/sudo")"
    assert_contains "$(sed -n 2p "$test_dir/sudo")" "install -m 644 $TMPDIR/"
    assert_equal "$keyring" "$(sed -n 2p "$test_dir/sudo" | awk '{ print $NF }')"
    assert_equal 2 "$(wc -l < "$test_dir/sudo" | tr -d ' ')"
    assert_equal $'--kill all\n--remove-socketdir\n--kill all\n--remove-socketdir' "$(cut -d ' ' -f 2- "$test_dir/gpgconf")"
    assert_equal 2 "$(cut -d ' ' -f 1 "$test_dir/gpgconf" | sort -u | grep -cF "$DOTFILES_GPG_TMPDIR/dotfiles-gpg.")"
    assert_contains "$(cat "$test_dir/commands")" '--retry 5'
    assert_contains "$(cat "$test_dir/commands")" 'https://example.invalid/deb.asc'
    assert_equal 0 "$(find "$TMPDIR" "$DOTFILES_GPG_TMPDIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
    # The same key again: the keyring is current and needs no sudo.
    : > "$test_dir/sudo"
    install_apt_key gierens > "$test_dir/output"
    assert_equal "The gierens repository's signing key is current." "$(cat "$test_dir/output")"
    assert_equal '' "$(cat "$test_dir/sudo")"
    # The project extended the key: the new copy is merged into the keyring,
    # which keeps the old material beside it, and then the update's refresh
    # finds it current.
    printf 'key %s signed-2026\n' "$pinned" > "$test_dir/served"
    : > "$test_dir/sudo"
    install_apt_key gierens > "$test_dir/output"
    assert_equal "Merging the gierens repository's key from https://example.invalid/deb.asc into its keyring..." "$(cat "$test_dir/output")"
    assert_equal "exported $pinned"$'\n'"key $pinned signed-2024"$'\n'"key $pinned signed-2026" "$(cat "$keyring")"
    assert_equal 2 "$(wc -l < "$test_dir/sudo" | tr -d ' ')"
    : > "$test_dir/sudo"
    install_apt_key gierens refresh > "$test_dir/output"
    assert_equal "The gierens repository's signing key is current." "$(cat "$test_dir/output")"
    assert_equal '' "$(cat "$test_dir/sudo")"
    # A keyring holding another key is replaced, and none of it is kept.
    printf 'key %s from-before-the-pins\n' "$other" > "$keyring"
    : > "$test_dir/sudo"
    install_apt_key gierens > "$test_dir/output"
    assert_equal "Replacing the gierens repository's keyring with the pinned key from https://example.invalid/deb.asc..." "$(cat "$test_dir/output")"
    assert_equal "exported $pinned"$'\n'"key $pinned signed-2026" "$(cat "$keyring")"
    assert_equal 2 "$(wc -l < "$test_dir/sudo" | tr -d ' ')"
    # Another key, a second key beside the pinned one, or none, refreshing or
    # not: the keyring stays as it was, and sudo is not needed.
    printf 'key %s from-before-the-pins\n' "$other" > "$keyring"
    for mode in '' refresh; do
        for found in "key $other signed" "key $pinned signed"$'\n'"key $other signed" 'not a key'; do
            printf '%s\n' "$found" > "$test_dir/served"
            : > "$test_dir/sudo"
            status=0
            install_apt_key gierens ${mode:+"$mode"} > "$test_dir/output" 2>&1 || status=$?
            assert_equal 1 "$status"
            assert_contains "$(cat "$test_dir/output")" 'is not the one pinned for the gierens repository'
            assert_contains "$(cat "$test_dir/output")" "expected $pinned"
            assert_equal '' "$(cat "$test_dir/sudo")"
            assert_equal "key $other from-before-the-pins" "$(cat "$keyring")"
        done
        assert_contains "$(cat "$test_dir/output")" 'received no OpenPGP key'
    done
    # A failed import shows what gpg said, and an export without the pinned
    # key is refused; neither reaches sudo.
    printf 'key %s signed-2026\n' "$pinned" > "$test_dir/served"
    : > "$test_dir/import-fails"
    status=0
    install_apt_key gierens > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(sed -n 1p "$test_dir/output")" "gpg could not import $TMPDIR/dotfiles-key."
    assert_equal 'key:' "$(sed -n 1p "$test_dir/output" | sed 's|.*/||')"
    assert_equal 'gpg: no valid OpenPGP data found.' "$(sed -n 2p "$test_dir/output")"
    assert_equal 2 "$(wc -l < "$test_dir/output" | tr -d ' ')"
    assert_equal '' "$(cat "$test_dir/sudo")"
    assert_equal "key $other from-before-the-pins" "$(cat "$keyring")"
    rm "$test_dir/import-fails"
    : > "$test_dir/export-nothing"
    status=0
    install_apt_key gierens > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_equal "gpg did not export the gierens repository's key $pinned." "$(cat "$test_dir/output")"
    assert_equal '' "$(cat "$test_dir/sudo")"
    assert_equal "key $other from-before-the-pins" "$(cat "$keyring")"
    rm "$test_dir/export-nothing"
    # A failed download stops the install with curl's status. Refreshing, it
    # leaves an existing keyring as it is, with a warning; without a keyring
    # it stops all the same.
    : > "$test_dir/offline"
    status=0
    install_apt_key gierens > "$test_dir/output" 2>&1 || status=$?
    assert_equal 22 "$status"
    assert_equal '' "$(cat "$test_dir/sudo")"
    assert_equal "key $other from-before-the-pins" "$(cat "$keyring")"
    install_apt_key gierens refresh > "$test_dir/output" 2>&1
    assert_equal "Could not fetch the gierens repository's key from https://example.invalid/deb.asc; its keyring stays as it is." "$(cat "$test_dir/output")"
    assert_equal '' "$(cat "$test_dir/sudo")"
    assert_equal "key $other from-before-the-pins" "$(cat "$keyring")"
    rm "$keyring"
    status=0
    install_apt_key gierens refresh > "$test_dir/output" 2>&1 || status=$?
    assert_equal 22 "$status"
    assert_equal '' "$(cat "$test_dir/sudo")"
    [ ! -e "$keyring" ]
    rm "$test_dir/offline"
    # A missing gpg stops before the download.
    unset -f gpg
    command() {
        case "$*" in
            '-v gpg') return 1 ;;
            *) builtin command "$@" ;;
        esac
    }
    : > "$test_dir/commands"
    status=0
    install_apt_key gierens > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'gnupg is not installed'
    assert_equal '' "$(cat "$test_dir/commands")"
    assert_equal '' "$(cat "$test_dir/sudo")"
    unset -f command
    assert_equal 0 "$(find "$TMPDIR" "$DOTFILES_GPG_TMPDIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
    # Sourcing again brings back the real table, key_details and
    # key_fingerprints; the real curl and gpgconf come back as well.
    source "$TEST_REPO_DIR/scripts/lib/apt_repositories.sh"
    unset -f curl gpgconf
    # Every repository's key comes over HTTPS under a full fingerprint, and its
    # sources line trusts that keyring alone.
    local name key_url pin sources_line
    for name in $DOTFILES_APT_REPOSITORIES; do
        read -r key_url pin sources_line <<<"$(dotfiles_apt_repository "$name")"
        assert_equal 'https://' "${key_url:0:8}"
        assert_equal 40 "${#pin}"
        assert_equal '' "$(printf '%s' "$pin" | tr -d '0-9A-F')"
        assert_contains "$sources_line" "deb [signed-by=/etc/apt/keyrings/$name.gpg] https://"
    done
    if ! command -v gpg >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
        echo "  (gpg or curl is not installed; skipped the real-key part)"
        return 0
    fi
    # Real keys: one expiring in a year, one that never expires, made and
    # exported in a throwaway home, which then goes away with its agent even
    # when something failed.
    local gen home="$test_dir/home" fpr_one='' fpr_two='' expiry_one='' now
    mkdir -p "$home"
    gen="$(dotfiles_gpg_home)"
    status=0
    {
        GNUPGHOME="$gen" gpg --batch --quiet --passphrase '' --quick-gen-key 'Fixture One <one@example.invalid>' ed25519 cert,sign 1y 2>/dev/null &&
            GNUPGHOME="$gen" gpg --batch --quiet --passphrase '' --quick-gen-key 'Fixture Two <two@example.invalid>' ed25519 cert,sign never 2>/dev/null &&
            fpr_one="$(GNUPGHOME="$gen" gpg --batch --with-colons --list-keys one@example.invalid 2>/dev/null | awk -F: '$1 == "fpr" && !n++ { print $10 }')" &&
            fpr_two="$(GNUPGHOME="$gen" gpg --batch --with-colons --list-keys two@example.invalid 2>/dev/null | awk -F: '$1 == "fpr" && !n++ { print $10 }')" &&
            expiry_one="$(GNUPGHOME="$gen" gpg --batch --with-colons --list-keys one@example.invalid 2>/dev/null | awk -F: '$1 == "pub" && !n++ { print $7 }')" &&
            GNUPGHOME="$gen" gpg --batch --armor --export one@example.invalid > "$test_dir/one.asc" &&
            GNUPGHOME="$gen" gpg --batch --armor --export two@example.invalid > "$test_dir/two.asc" &&
            GNUPGHOME="$gen" gpg --batch --armor --export one@example.invalid two@example.invalid > "$test_dir/both.asc" &&
            GNUPGHOME="$gen" gpg --batch --dearmor -o "$test_dir/both.gpg" -- "$test_dir/both.asc"
    } || status=$?
    dotfiles_gpg_home_remove "$gen" || :
    assert_equal 0 "$status"
    printf 'not a key\n' > "$test_dir/garbage.asc"
    # One fingerprint per key, primaries only.
    assert_equal "$fpr_one" "$(HOME="$home" key_fingerprints "$test_dir/one.asc")"
    assert_equal "$fpr_one"$'\n'"$fpr_two" "$(HOME="$home" key_fingerprints "$test_dir/both.asc")"
    assert_equal '' "$(HOME="$home" key_fingerprints "$test_dir/garbage.asc" 2>/dev/null || :)"
    # key_details adds the expiry gpg lists, about a year away, and nothing
    # for a key that never expires; a binary keyring reads the same.
    now="$(date +%s)"
    if ! { [ "$expiry_one" -gt $((now + 300 * 86400)) ] && [ "$expiry_one" -lt $((now + 400 * 86400)) ]; } 2>/dev/null; then
        echo "Expected an expiry about a year away, got <$expiry_one>." >&2
        return 1
    fi
    assert_equal "$fpr_one $expiry_one" "$(HOME="$home" key_details "$test_dir/one.asc")"
    assert_equal "$fpr_two" "$(HOME="$home" key_details "$test_dir/two.asc")"
    assert_equal "$fpr_one $expiry_one"$'\n'"$fpr_two" "$(HOME="$home" key_details "$test_dir/both.gpg")"
    # A real extension: a key made on 2024-01-01 to expire after three years,
    # exported, then extended to five years from now and exported again. The
    # second copy carries only the new self-signature.
    local ext fpr_ext=''
    ext="$(dotfiles_gpg_home)"
    status=0
    {
        GNUPGHOME="$ext" gpg --batch --quiet --passphrase '' --faked-system-time '20240101T000000!' \
            --quick-gen-key 'Fixture Repository <repository@example.invalid>' rsa3072 sign 3y 2>/dev/null &&
            fpr_ext="$(GNUPGHOME="$ext" gpg --batch --with-colons --list-keys repository@example.invalid 2>/dev/null | awk -F: '$1 == "fpr" && !n++ { print $10 }')" &&
            GNUPGHOME="$ext" gpg --batch --armor --export "$fpr_ext" > "$test_dir/extended-old.asc" &&
            GNUPGHOME="$ext" gpg --batch --quiet --passphrase '' --pinentry-mode loopback --quick-set-expire "$fpr_ext" 5y 2>/dev/null &&
            GNUPGHOME="$ext" gpg --batch --armor --export "$fpr_ext" > "$test_dir/extended-new.asc"
    } || status=$?
    dotfiles_gpg_home_remove "$ext" || :
    assert_equal 0 "$status"
    # The real install_apt_key fetches it over file:// through the real curl:
    # installed, current, merged with the extension, then current again.
    pinned="$fpr_ext"
    dotfiles_apt_repository() {
        echo "file://$DOTFILES_TEST_FIXTURE/served.asc $pinned deb [signed-by=/etc/apt/keyrings/gierens.gpg] https://example.invalid stable main"
    }
    cp "$test_dir/extended-old.asc" "$test_dir/served.asc"
    : > "$test_dir/sudo"
    HOME="$home" install_apt_key gierens > "$test_dir/output" 2>&1
    assert_equal "Installing the gierens repository's signing key from file://$test_dir/served.asc..." "$(cat "$test_dir/output")"
    assert_equal 2 "$(wc -l < "$test_dir/sudo" | tr -d ' ')"
    : > "$test_dir/sudo"
    HOME="$home" install_apt_key gierens > "$test_dir/output" 2>&1
    assert_equal "The gierens repository's signing key is current." "$(cat "$test_dir/output")"
    assert_equal '' "$(cat "$test_dir/sudo")"
    cp "$test_dir/extended-new.asc" "$test_dir/served.asc"
    HOME="$home" install_apt_key gierens refresh > "$test_dir/output" 2>&1
    assert_equal "Merging the gierens repository's key from file://$test_dir/served.asc into its keyring..." "$(cat "$test_dir/output")"
    assert_equal 2 "$(wc -l < "$test_dir/sudo" | tr -d ' ')"
    : > "$test_dir/sudo"
    HOME="$home" install_apt_key gierens refresh > "$test_dir/output" 2>&1
    assert_equal "The gierens repository's signing key is current." "$(cat "$test_dir/output")"
    assert_equal '' "$(cat "$test_dir/sudo")"
    # The keyring holds one key with both user ID self-signatures, where the
    # new copy had one, and the expiry read from it is the extended one; the
    # old copy expired sooner.
    local list packets new_packets details
    list="$(dotfiles_gpg_home)"
    packets="$(GNUPGHOME="$list" gpg --batch --list-packets "$keyring" 2>/dev/null || :)"
    new_packets="$(GNUPGHOME="$list" gpg --batch --list-packets "$test_dir/extended-new.asc" 2>/dev/null || :)"
    dotfiles_gpg_home_remove "$list" || :
    assert_equal 1 "$(printf '%s\n' "$new_packets" | grep -c 'sigclass 0x13' || :)"
    assert_equal 1 "$(printf '%s\n' "$packets" | grep -c '^:public key packet:' || :)"
    assert_equal 2 "$(printf '%s\n' "$packets" | grep -c 'sigclass 0x13' || :)"
    details="$(HOME="$home" key_details "$keyring")"
    assert_equal "$fpr_ext" "${details%% *}"
    if ! [ "${details#* }" -gt $((now + 4 * 365 * 86400)) ] 2>/dev/null; then
        echo "Expected the extended expiry, more than four years away, got <$details>." >&2
        return 1
    fi
    details="$(HOME="$home" key_details "$test_dir/extended-old.asc")"
    if ! [ "${details#* }" -lt $((now + 4 * 365 * 86400)) ] 2>/dev/null; then
        echo "Expected the old copy to expire within four years, got <$details>." >&2
        return 1
    fi
    # A real file with a second key is refused, and one that cannot be
    # fetched leaves the keyring to the refresh.
    cp "$test_dir/both.asc" "$test_dir/served.asc"
    status=0
    HOME="$home" install_apt_key gierens > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" "received $fpr_one $fpr_two"
    rm "$test_dir/served.asc"
    HOME="$home" install_apt_key gierens refresh > "$test_dir/output" 2>&1
    assert_contains "$(cat "$test_dir/output")" "Could not fetch the gierens repository's key from file://$test_dir/served.asc; its keyring stays as it is."
    assert_equal '' "$(cat "$test_dir/sudo")"
    [ ! -e "$home/.gnupg" ]
    assert_equal 0 "$(find "$TMPDIR" "$DOTFILES_GPG_TMPDIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
}

# Held packages are left out of every apt-get install: one with an upgrade
# makes the whole command fail. Updating, the package list is installed the
# same way, which upgrades it, and the repository packages are upgraded in place.
test_apt_held_packages_left_alone() {
    source "$TEST_REPO_DIR/scripts/install_packages.sh"
    export DOTFILES_TEST_FIXTURE="$test_dir"
    # No repository has been added here, so updating refreshes no keys;
    # test_apt_keys_refreshed_before_updating covers that.
    export DOTFILES_APT_ETC="$test_dir/etc-apt"
    check_linux_distribution() { return 0; }
    parse_list() { printf 'tmux\nbat\nwl-clipboard\nfzf\n'; }
    apt-mark() { [ "$1" = showhold ] && cat "$DOTFILES_TEST_FIXTURE/held"; }
    sudo() {
        printf '%s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/commands"
        case "$1" in
            tee) cat >/dev/null ;;
        esac
        case "$*" in
            *--only-upgrade*) [ -f "$DOTFILES_TEST_FIXTURE/retry" ] || return 57 ;;
        esac
    }
    printf 'bat\nunrelated\n' > "$test_dir/held"
    install_linux > "$test_dir/output"
    # wl-clipboard comes without its recommends (a desktop stack on Debian 13).
    assert_equal $'apt-get update -qq\napt-get install -y tmux fzf\napt-get install -y --no-install-recommends wl-clipboard' "$(cat "$test_dir/commands")"
    assert_contains "$(cat "$test_dir/output")" 'held, left alone: bat (sudo apt-mark unhold bat to upgrade it)'
    : > "$test_dir/commands"
    export DOTFILES_UPDATE=1
    install_linux > "$test_dir/output"
    assert_equal $'apt-get update -qq\napt-get install -y tmux fzf\napt-get install -y --no-install-recommends wl-clipboard' "$(cat "$test_dir/commands")"
    assert_contains "$(cat "$test_dir/output")" 'Installing and upgrading apt packages'
    source "$TEST_REPO_DIR/scripts/bootstrap_tools.sh"
    command() {
        case "$*" in
            '-v glow'|'-v gum') return 0 ;;
            *) builtin command "$@" ;;
        esac
    }
    printf 'gum\n' > "$test_dir/held"
    : > "$test_dir/commands"
    local status=0
    install_charm_tools > "$test_dir/output" 2>&1 || status=$?
    assert_equal 57 "$status"
    : > "$test_dir/retry"
    install_charm_tools > "$test_dir/output"
    assert_equal 'apt-get install -y --only-upgrade glow' "$(tail -n 1 "$test_dir/commands")"
    assert_contains "$(cat "$test_dir/output")" 'held, left alone: gum'
    # With one package missing, the installed one comes along unless held.
    command() {
        case "$*" in
            '-v glow') return 1 ;;
            '-v gum') return 0 ;;
            *) builtin command "$@" ;;
        esac
    }
    install_apt_key() { printf 'install_apt_key %s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/commands"; }
    printf '\n' > "$test_dir/held"
    : > "$test_dir/commands"
    install_charm_tools > "$test_dir/output"
    assert_equal 'apt-get install -y glow gum' "$(tail -n 1 "$test_dir/commands")"
    assert_equal 'install_apt_key charm' "$(grep '^install_apt_key' "$test_dir/commands")"
    assert_contains "$(cat "$test_dir/commands")" "tee $test_dir/etc-apt/sources.list.d/charm.list"
    printf 'gum\n' > "$test_dir/held"
    install_charm_tools > "$test_dir/output"
    assert_equal 'apt-get install -y glow' "$(tail -n 1 "$test_dir/commands")"
    command() {
        case "$*" in
            '-v glow'|'-v gum') return 0 ;;
            *) builtin command "$@" ;;
        esac
    }
    # Nothing to upgrade when every package is held; a plain rerun upgrades nothing.
    printf 'glow\ngum\n' > "$test_dir/held"
    : > "$test_dir/commands"
    install_charm_tools > "$test_dir/output"
    unset DOTFILES_UPDATE
    install_charm_tools > "$test_dir/output"
    assert_equal '' "$(cat "$test_dir/commands")"
}

# Updating, the signing key of every apt repository the bootstrap added is
# fetched again before apt reads the repositories, so a key whose expiry the
# project extended reaches the keyring first. A key that fails its pin stops
# the update before apt runs. A plain install leaves the keys alone.
test_apt_keys_refreshed_before_updating() {
    source "$TEST_REPO_DIR/scripts/install_packages.sh"
    export DOTFILES_TEST_FIXTURE="$test_dir"
    export DOTFILES_APT_ETC="$test_dir/etc-apt"
    mkdir -p "$DOTFILES_APT_ETC/sources.list.d"
    : > "$DOTFILES_APT_ETC/sources.list.d/charm.list"
    check_linux_distribution() { return 0; }
    parse_list() { printf 'tmux\n'; }
    apt-mark() { :; }
    sudo() { printf 'sudo %s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/commands"; }
    install_apt_key() {
        printf 'install_apt_key %s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/commands"
        [ ! -f "$DOTFILES_TEST_FIXTURE/wrong-key" ] || return 1
    }
    # The refresh needs gpg, which the mocked install_apt_key never runs.
    gpg() { return 99; }
    install_linux > "$test_dir/output"
    assert_equal $'sudo apt-get update -qq\nsudo apt-get install -y tmux' "$(cat "$test_dir/commands")"
    # Only the repositories added have their keys fetched, in refresh mode
    # (test_apt_key_pinning covers it), before apt-get update.
    export DOTFILES_UPDATE=1
    : > "$test_dir/commands"
    install_linux > "$test_dir/output"
    assert_equal $'install_apt_key charm refresh\nsudo apt-get update -qq\nsudo apt-get install -y tmux' "$(cat "$test_dir/commands")"
    : > "$DOTFILES_APT_ETC/sources.list.d/gierens.list"
    : > "$test_dir/commands"
    install_linux > "$test_dir/output"
    assert_equal $'install_apt_key gierens refresh\ninstall_apt_key charm refresh\nsudo apt-get update -qq\nsudo apt-get install -y tmux' "$(cat "$test_dir/commands")"
    # The first key that fails stops the update: no other key, and no apt.
    : > "$test_dir/wrong-key"
    : > "$test_dir/commands"
    local status=0
    install_linux > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_equal 'install_apt_key gierens refresh' "$(cat "$test_dir/commands")"
    rm "$DOTFILES_APT_ETC/sources.list.d/gierens.list"
    : > "$test_dir/commands"
    status=0
    install_linux > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_equal 'install_apt_key charm refresh' "$(cat "$test_dir/commands")"
    # Without gnupg the keys wait for the next update; apt installs it meanwhile.
    unset -f gpg
    command() {
        case "$*" in
            '-v gpg') return 1 ;;
            *) builtin command "$@" ;;
        esac
    }
    : > "$test_dir/commands"
    install_linux > "$test_dir/output"
    assert_equal $'sudo apt-get update -qq\nsudo apt-get install -y tmux' "$(cat "$test_dir/commands")"
    assert_contains "$(cat "$test_dir/output")" 'checked on the next update, after apt installs it'
}

# oh-my-posh and zoxide come from GitHub releases like the other release tools,
# whose installing and updating test_github_release_install and _update cover:
# oh-my-posh as a bare binary built for the system, zoxide from an archive
# whose man pages stay out of the bin directory.
test_script_installers_install_and_update() {
    source "$TEST_REPO_DIR/scripts/bootstrap_tools.sh"
    trust_release_downloads
    export DOTFILES_TEST_FIXTURE="$test_dir"
    # A new account has no local bin directory yet.
    export DOTFILES_LOCAL_BIN="$test_dir/new/bin"
    export TMPDIR="$test_dir/tmp"
    local records="$XDG_STATE_HOME/dotfiles/releases"
    mkdir -p "$TMPDIR" "$test_dir/payload/man/man1"
    printf '#!/bin/sh\necho zoxide\n' > "$test_dir/payload/zoxide"
    printf 'manual\n' > "$test_dir/payload/man/man1/zoxide.1"
    tar -czf "$test_dir/zoxide.tar.gz" -C "$test_dir/payload" .
    printf 'v1.0.0\n' > "$test_dir/latest"
    printf 'Linux\n' > "$test_dir/os"
    printf 'x86_64\n' > "$test_dir/arch"
    uname() {
        case "${1:-}" in
            -m) cat "$DOTFILES_TEST_FIXTURE/arch" ;;
            -s) cat "$DOTFILES_TEST_FIXTURE/os" ;;
            *) command uname "$@" ;;
        esac
    }
    # Copies on this machine's PATH must not decide.
    command() {
        case "$*" in
            '-v oh-my-posh'|'-v zoxide') [ -f "$DOTFILES_TEST_FIXTURE/elsewhere-$2" ] ;;
            *) builtin command "$@" ;;
        esac
    }
    curl() {
        local output="" url=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -o|-w) output="$2"; shift ;;
                -*) ;;
                *) url="$1" ;;
            esac
            shift
        done
        printf '%s\n' "$url" >> "$DOTFILES_TEST_FIXTURE/requests"
        case "$url" in
            */releases/latest) printf '%s/tag/%s' "${url%/latest}" "$(cat "$DOTFILES_TEST_FIXTURE/latest")" ;;
            */releases/download/*.tar.gz) cp "$DOTFILES_TEST_FIXTURE/zoxide.tar.gz" "$output" ;;
            */releases/download/*) printf '#!/bin/sh\necho oh-my-posh\n' > "$output" ;;
            *) echo "unexpected URL $url" >&2; return 99 ;;
        esac
    }
    bootstrap_oh_my_posh > "$test_dir/output"
    bootstrap_zoxide > "$test_dir/output"
    assert_equal "https://github.com/JanDeDobbeleer/oh-my-posh/releases/latest
https://github.com/JanDeDobbeleer/oh-my-posh/releases/download/v1.0.0/posh-linux-amd64
https://github.com/ajeetdsouza/zoxide/releases/latest
https://github.com/ajeetdsouza/zoxide/releases/download/v1.0.0/zoxide-1.0.0-x86_64-unknown-linux-musl.tar.gz" "$(cat "$test_dir/requests")"
    # Only the binaries land in the bin directory, executable.
    assert_equal $'oh-my-posh\nzoxide' "$(ls "$test_dir/new/bin")"
    assert_equal oh-my-posh "$("$test_dir/new/bin/oh-my-posh")"
    assert_equal zoxide "$("$test_dir/new/bin/zoxide")"
    assert_equal '' "$(find "$test_dir/new" -name zoxide.1)"
    assert_equal v1.0.0 "$(cat "$records/JanDeDobbeleer/oh-my-posh")"
    assert_equal v1.0.0 "$(cat "$records/ajeetdsouza/zoxide")"
    # A plain rerun makes no request; updating while current looks once each.
    : > "$test_dir/requests"
    bootstrap_oh_my_posh > "$test_dir/output"
    bootstrap_zoxide > "$test_dir/output"
    assert_equal '' "$(cat "$test_dir/requests")"
    export DOTFILES_UPDATE=1
    bootstrap_oh_my_posh > "$test_dir/output"
    bootstrap_zoxide >> "$test_dir/output"
    assert_equal "https://github.com/JanDeDobbeleer/oh-my-posh/releases/latest
https://github.com/ajeetdsouza/zoxide/releases/latest" "$(cat "$test_dir/requests")"
    assert_contains "$(cat "$test_dir/output")" 'oh-my-posh v1.0.0 is current'
    # A newer tag is downloaded again.
    printf 'v1.1.0\n' > "$test_dir/latest"
    bootstrap_oh_my_posh > "$test_dir/output"
    bootstrap_zoxide > "$test_dir/output"
    assert_contains "$(cat "$test_dir/requests")" '/oh-my-posh/releases/download/v1.1.0/posh-linux-amd64'
    assert_contains "$(cat "$test_dir/requests")" '/zoxide/releases/download/v1.1.0/zoxide-1.1.0-x86_64-unknown-linux-musl.tar.gz'
    assert_equal v1.1.0 "$(cat "$records/JanDeDobbeleer/oh-my-posh")"
    assert_equal v1.1.0 "$(cat "$records/ajeetdsouza/zoxide")"
    # macOS takes the same route with its own build.
    unset DOTFILES_UPDATE
    printf 'Darwin\n' > "$test_dir/os"
    printf 'arm64\n' > "$test_dir/arch"
    rm "$test_dir/new/bin/oh-my-posh"
    bootstrap_oh_my_posh > "$test_dir/output"
    assert_equal 'https://github.com/JanDeDobbeleer/oh-my-posh/releases/download/v1.1.0/posh-darwin-arm64' "$(tail -n 1 "$test_dir/requests")"
    assert_equal oh-my-posh "$("$test_dir/new/bin/oh-my-posh")"
    # A copy elsewhere on PATH is left alone.
    rm "$test_dir/new/bin/zoxide"
    : > "$test_dir/elsewhere-zoxide"
    printf 'v1.2.0\n' > "$test_dir/latest"
    export DOTFILES_UPDATE=1
    : > "$test_dir/requests"
    bootstrap_zoxide > "$test_dir/output"
    assert_contains "$(cat "$test_dir/output")" 'zoxide not installed by the bootstrap; left alone'
    assert_equal '' "$(cat "$test_dir/requests")"
    [ ! -e "$test_dir/new/bin/zoxide" ]
}

test_tmux_plugin_failure_and_retry() {
    source "$TEST_REPO_DIR/scripts/bootstrap_tools.sh"
    mkdir -p "$test_dir/tpm/bin"
    export DOTFILES_TEST_FIXTURE="$test_dir"
    cat > "$test_dir/tpm/bin/install_plugins" <<'TPM'
#!/bin/sh
[ -n "$TMUX" ] || exit 99
printf '%s\n' "$TMUX" >> "$DOTFILES_TEST_FIXTURE/plugin-runs"
[ -f "$DOTFILES_TEST_FIXTURE/retry" ] || exit 46
TPM
    chmod +x "$test_dir/tpm/bin/install_plugins"
    tmux() { printf '%s\n' "$*" >> "$test_dir/tmux-commands"; }
    git() { echo 'Unexpected clone of an existing TPM installation.' >&2; return 99; }
    local status=0
    bootstrap_tmux "$test_dir/tpm" > "$test_dir/output" 2>&1 || status=$?
    assert_equal 46 "$status"
    assert_contains "$(tail -n 1 "$test_dir/tmux-commands")" 'kill-server'
    : > "$test_dir/retry"
    bootstrap_tmux "$test_dir/tpm"
    assert_equal 2 "$(wc -l < "$test_dir/plugin-runs" | tr -d ' ')"
    assert_contains "$(tail -n 1 "$test_dir/tmux-commands")" 'kill-server'
    # Updating, TPM updates itself and every plugin but the ones pinned to a tag.
    cat > "$test_dir/tpm/bin/update_plugins" <<'TPM'
#!/bin/sh
[ -n "$TMUX" ] || exit 99
printf '%s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/update-runs"
# Like TPM itself: a failed git pull is reported, and the status stays 0.
[ -f "$DOTFILES_TEST_FIXTURE/update-retry" ] || echo '  "tmux-yank" update fail' >&2
echo '  "tpm" update success'
echo '    | Already up to date.'
echo '  "tmux-sensible" update success'
echo '    | Already up to date.'
exit 0
TPM
    chmod +x "$test_dir/tpm/bin/update_plugins"
    local conf="$TEST_REPO_DIR/config/tmux/tmux.conf" expected pinned
    expected="$(sed -n "s/^set -g @plugin '\([^'#]*\)'.*/\1/p" "$conf" | sed 's|.*/||' | tr '\n' ' ')"
    pinned="$(sed -n "s/^set -g @plugin '\([^']*#[^']*\)'.*/\1/p" "$conf")"
    assert_contains "$pinned" 'catppuccin/tmux#v'
    export DOTFILES_UPDATE=1
    status=0
    bootstrap_tmux "$test_dir/tpm" > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'TPM could not update every plugin'
    assert_equal "${expected% }" "$(cat "$test_dir/update-runs")"
    assert_contains "$(cat "$test_dir/output")" "tmux plugin ${pinned%%#*} is pinned to ${pinned#*#}; left alone"
    assert_contains "$(tail -n 1 "$test_dir/tmux-commands")" 'kill-server'
    assert_contains "$(cat "$test_dir/output")" 'Already up to date.'
    : > "$test_dir/update-retry"
    bootstrap_tmux "$test_dir/tpm" > "$test_dir/output"
    # A success is one line.
    assert_contains "$(cat "$test_dir/output")" '  TPM and its plugins pulled: 2 succeeded'
    case "$(cat "$test_dir/output")" in
        *'Already up to date'*) echo "TPM's per-plugin output was printed on success." >&2; return 1 ;;
    esac
    assert_equal 4 "$(wc -l < "$test_dir/plugin-runs" | tr -d ' ')"
    assert_equal 2 "$(wc -l < "$test_dir/update-runs" | tr -d ' ')"
    case " $(tail -n 1 "$test_dir/update-runs") " in
        *" tmux "*) echo "The pinned catppuccin/tmux was updated." >&2; return 1 ;;
    esac
}

test_zinit_plugin_failure_and_retry() {
    source "$TEST_REPO_DIR/scripts/bootstrap_tools.sh"
    mkdir -p "$test_dir/zinit"
    export DOTFILES_TEST_FIXTURE="$test_dir"
    cat > "$test_dir/zinit/zinit.zsh" <<'ZINIT'
zinit() {
    if [[ $1 == update ]]; then
        # Like zinit itself: a failed plugin update is a warning and status 0.
        print -r -- "$*" >> "$DOTFILES_TEST_FIXTURE/update-runs"
        [[ -f $DOTFILES_TEST_FIXTURE/update-retry ]] || print -r -- "Warning: zsh-users/zsh-completions update returned 1"
        # Like zinit: a dot per plugin, then an updated plugin's header after a
        # carriage return, its git log, and its own changelog when it updates.
        print -rn -- ".."
        print -r -- $'\e[1mUpdating zsh-users/zsh-autosuggestions\e[0m'
        print -r -- "Updating 0e810e5..85919cd"
        print -r -- "Fast-forward"
        print -r -- $'\r..Updating Aloxaf/fzf-tab'
        print -r -- "[self-update] updating zinit repository"
        return 0
    fi
    printf '%s\n' "$2" >> "$DOTFILES_TEST_FIXTURE/plugin-runs"
    [ -f "$DOTFILES_TEST_FIXTURE/retry" ] || return 47
}
ZINIT
    local status=0
    bootstrap_zinit "$test_dir/zinit" > "$test_dir/output" 2>&1 || status=$?
    assert_equal 47 "$status"
    assert_equal 1 "$(wc -l < "$test_dir/plugin-runs" | tr -d ' ')"
    : > "$test_dir/retry"
    bootstrap_zinit "$test_dir/zinit"
    assert_equal 7 "$(wc -l < "$test_dir/plugin-runs" | tr -d ' ')"
    assert_equal MichaelAquilina/zsh-you-should-use "$(tail -n 1 "$test_dir/plugin-runs")"
    assert_contains "$(cat "$test_dir/plugin-runs")" olets/zsh-abbr
    [ ! -f "$test_dir/update-runs" ]
    # Updating, zinit updates itself and every plugin after loading them,
    # without a pager; the warning it prints for a failed plugin is a failure.
    export DOTFILES_UPDATE=1
    status=0
    bootstrap_zinit "$test_dir/zinit" > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'zinit could not update every plugin'
    assert_equal 'update --all --quiet --no-pager' "$(cat "$test_dir/update-runs")"
    assert_equal 13 "$(wc -l < "$test_dir/plugin-runs" | tr -d ' ')"
    assert_contains "$(cat "$test_dir/output")" 'Fast-forward'
    : > "$test_dir/update-retry"
    bootstrap_zinit "$test_dir/zinit" > "$test_dir/output"
    assert_equal 2 "$(wc -l < "$test_dir/update-runs" | tr -d ' ')"
    # A success names the updated plugins and leaves out their git logs.
    assert_equal "  Updating zsh-users/zsh-autosuggestions
  Updating Aloxaf/fzf-tab
  zinit updated itself" "$(sed -n '/^Updating Zinit and its plugins/,$p' "$test_dir/output" | sed 1d)"
}

test_github_release_install() {
    source "$TEST_REPO_DIR/scripts/bootstrap_tools.sh"
    trust_release_downloads
    export DOTFILES_TEST_FIXTURE="$test_dir"
    export DOTFILES_LOCAL_BIN="$test_dir/bin"
    export TMPDIR="$test_dir/tmp"
    mkdir -p "$TMPDIR" "$test_dir/payload/tool-v1.2.3-x86_64-unknown-linux-musl" "$test_dir/payload2"
    printf '#!/bin/sh\necho from-release\n' > "$test_dir/payload/tool-v1.2.3-x86_64-unknown-linux-musl/tool"
    tar -czf "$test_dir/asset.tar.gz" -C "$test_dir/payload" .
    printf '#!/bin/sh\n' > "$test_dir/payload2/first"
    printf '#!/bin/sh\n' > "$test_dir/payload2/second"
    (cd "$test_dir/payload2" && zip -q "$test_dir/asset.zip" first second)
    uname() { if [ "${1:-}" = -m ]; then cat "$DOTFILES_TEST_FIXTURE/arch"; else command uname "$@"; fi; }
    printf 'x86_64\n' > "$test_dir/arch"
    curl() {
        local output="" url=""
        printf '%s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/commands"
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -o|-w) output="$2"; shift ;;
                -*) ;;
                *) url="$1" ;;
            esac
            shift
        done
        case "$url" in
            */releases/latest)
                [ -f "$DOTFILES_TEST_FIXTURE/resolve" ] || return 22
                local repo="${url#https://github.com/}"
                repo="${repo%/releases/latest}"
                if [ -f "$DOTFILES_TEST_FIXTURE/bad-redirect" ]; then
                    printf 'https://github.com/%s/releases' "$repo"
                else
                    printf 'https://github.com/%s/releases/tag/v1.2.3' "$repo"
                fi
                ;;
            */releases/download/v1.2.3/*)
                [ -f "$DOTFILES_TEST_FIXTURE/retry" ] || return 56
                printf '%s\n' "$url" >> "$DOTFILES_TEST_FIXTURE/downloads"
                case "$url" in
                    *.tar.gz) cp "$DOTFILES_TEST_FIXTURE/asset.tar.gz" "$output" ;;
                    *.zip) cp "$DOTFILES_TEST_FIXTURE/asset.zip" "$output" ;;
                    *) printf '#!/bin/sh\necho bare\n' > "$output" ;;
                esac
                ;;
            *) echo "unexpected URL $url" >&2; return 99 ;;
        esac
    }
    local status=0
    install_github_release owner/tool 'tool-{tag}-{arch}-unknown-linux-musl.tar.gz' tool > "$test_dir/output" 2>&1 || status=$?
    assert_equal 22 "$status"
    [ ! -f "$test_dir/downloads" ]
    : > "$test_dir/resolve"
    : > "$test_dir/bad-redirect"
    status=0
    install_github_release owner/tool 'tool-{tag}-{arch}-unknown-linux-musl.tar.gz' tool > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'Could not resolve the latest release of owner/tool'
    rm "$test_dir/bad-redirect"
    status=0
    install_github_release owner/tool 'tool-{tag}-{arch}-unknown-linux-musl.tar.gz' tool > "$test_dir/output" 2>&1 || status=$?
    assert_equal 56 "$status"
    [ ! -e "$test_dir/bin/tool" ]
    assert_equal 0 "$(find "$TMPDIR" -maxdepth 1 -name 'dotfiles-release.*' | wc -l | tr -d ' ')"
    : > "$test_dir/retry"
    install_github_release owner/tool 'tool-{tag}-{arch}-unknown-linux-musl.tar.gz' tool
    assert_equal 'https://github.com/owner/tool/releases/download/v1.2.3/tool-v1.2.3-x86_64-unknown-linux-musl.tar.gz' "$(tail -n 1 "$test_dir/downloads")"
    # The tag lookup and the download both retry transient HTTP failures.
    assert_equal 0 "$(grep -c -v -- '--retry 5' "$test_dir/commands")"
    assert_equal from-release "$("$test_dir/bin/tool")"
    assert_equal 0 "$(find "$TMPDIR" -maxdepth 1 -name 'dotfiles-release.*' | wc -l | tr -d ' ')"
    # Several binaries from one zip; {version} drops the v, Go and Debian spellings differ.
    install_github_release owner/multi 'multi_{version}_linux_{arch_go}_{arch_deb}_{arch_amd64}_{arch_node}.zip' first second
    assert_equal 'https://github.com/owner/multi/releases/download/v1.2.3/multi_1.2.3_linux_x86_64_amd64_amd64_x64.zip' "$(tail -n 1 "$test_dir/downloads")"
    [ -x "$test_dir/bin/first" ]
    [ -x "$test_dir/bin/second" ]
    status=0
    install_github_release owner/multi 'multi_{version}_linux_{arch_go}_{arch_deb}.zip' absent > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'does not contain absent'
    # Installed binaries are skipped without any network access.
    PATH="$test_dir/bin:$PATH"
    : > "$test_dir/commands"
    install_github_release owner/tool 'tool-{tag}-{arch}-unknown-linux-musl.tar.gz' tool
    install_github_release owner/multi 'multi_{version}_linux_{arch_go}_{arch_deb}.zip' first second
    assert_equal '' "$(cat "$test_dir/commands")"
    printf 'aarch64\n' > "$test_dir/arch"
    install_github_release owner/arm 'arm-{arch}-{arch_go}-{arch_deb}-{arch_amd64}-{arch_node}' armtool
    assert_contains "$(tail -n 1 "$test_dir/downloads")" 'arm-aarch64-arm64-arm64-aarch64-arm64'
    assert_equal bare "$("$test_dir/bin/armtool")"
    printf 'mips\n' > "$test_dir/arch"
    status=0
    install_github_release owner/other 'other-{arch}.tar.gz' othertool > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'Unsupported architecture: mips'
}

# Release binaries record the tag they came from. Updating, the bootstrap's
# copies are fetched again only when the latest tag differs, a failed download
# leaves them and the record alone, and a copy from elsewhere stays.
test_github_release_update() {
    source "$TEST_REPO_DIR/scripts/bootstrap_tools.sh"
    trust_release_downloads
    export DOTFILES_TEST_FIXTURE="$test_dir"
    export DOTFILES_LOCAL_BIN="$test_dir/bin"
    export TMPDIR="$test_dir/tmp"
    local record="$XDG_STATE_HOME/dotfiles/releases/owner/tool" tag
    mkdir -p "$TMPDIR"
    for tag in v1.0.0 v1.1.0; do
        mkdir -p "$test_dir/payload-$tag"
        printf '#!/bin/sh\necho "tool %s"\n' "$tag" > "$test_dir/payload-$tag/tool"
        printf '#!/bin/sh\necho "helper %s"\n' "$tag" > "$test_dir/payload-$tag/helper"
        chmod +x "$test_dir/payload-$tag/tool" "$test_dir/payload-$tag/helper"
        tar -czf "$test_dir/asset-$tag.tar.gz" -C "$test_dir/payload-$tag" .
    done
    printf 'v1.0.0\n' > "$test_dir/latest"
    uname() { if [ "${1:-}" = -m ]; then printf 'x86_64\n'; else command uname "$@"; fi; }
    curl() {
        local output="" url="" release
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -o|-w) output="$2"; shift ;;
                -*) ;;
                *) url="$1" ;;
            esac
            shift
        done
        printf '%s\n' "$url" >> "$DOTFILES_TEST_FIXTURE/requests"
        case "$url" in
            https://github.com/owner/tool/releases/latest) printf 'https://github.com/owner/tool/releases/tag/%s' "$(cat "$DOTFILES_TEST_FIXTURE/latest")" ;;
            https://github.com/owner/tool/releases/download/*)
                [ ! -f "$DOTFILES_TEST_FIXTURE/offline" ] || return 56
                release="${url#https://github.com/owner/tool/releases/download/}"
                cp "$DOTFILES_TEST_FIXTURE/asset-${release%%/*}.tar.gz" "$output"
                ;;
            *) echo "unexpected URL $url" >&2; return 99 ;;
        esac
    }
    install_github_release owner/tool 'tool-{tag}.tar.gz' tool helper > "$test_dir/output"
    assert_equal 'tool v1.0.0' "$("$test_dir/bin/tool")"
    assert_equal v1.0.0 "$(cat "$record")"
    # A plain rerun never looks; updating while current looks once and downloads nothing.
    : > "$test_dir/requests"
    install_github_release owner/tool 'tool-{tag}.tar.gz' tool helper > "$test_dir/output"
    assert_equal '' "$(cat "$test_dir/requests")"
    export DOTFILES_UPDATE=1
    install_github_release owner/tool 'tool-{tag}.tar.gz' tool helper > "$test_dir/output"
    assert_equal 'https://github.com/owner/tool/releases/latest' "$(cat "$test_dir/requests")"
    assert_contains "$(cat "$test_dir/output")" 'tool helper v1.0.0 is current'
    # A newer release that fails to download changes nothing; the retry replaces both.
    printf 'v1.1.0\n' > "$test_dir/latest"
    : > "$test_dir/offline"
    local status=0
    install_github_release owner/tool 'tool-{tag}.tar.gz' tool helper > "$test_dir/output" 2>&1 || status=$?
    assert_equal 56 "$status"
    assert_equal 'tool v1.0.0' "$("$test_dir/bin/tool")"
    assert_equal v1.0.0 "$(cat "$record")"
    assert_equal 0 "$(find "$TMPDIR" -maxdepth 1 -name 'dotfiles-release.*' | wc -l | tr -d ' ')"
    rm "$test_dir/offline"
    install_github_release owner/tool 'tool-{tag}.tar.gz' tool helper > "$test_dir/output"
    assert_contains "$(cat "$test_dir/output")" 'Updating tool helper from owner/tool v1.0.0 to v1.1.0'
    assert_equal 'tool v1.1.0' "$("$test_dir/bin/tool")"
    assert_equal 'helper v1.1.0' "$("$test_dir/bin/helper")"
    assert_equal v1.1.0 "$(cat "$record")"
    # Binaries installed before tags were recorded are fetched once.
    rm "$record"
    : > "$test_dir/requests"
    install_github_release owner/tool 'tool-{tag}.tar.gz' tool helper > "$test_dir/output"
    assert_contains "$(cat "$test_dir/requests")" 'releases/download/v1.1.0/tool-v1.1.0.tar.gz'
    assert_equal v1.1.0 "$(cat "$record")"
    # A latest release older than the recorded one, as after a project deleted
    # its newest, replaces nothing.
    printf 'v1.0.0\n' > "$test_dir/latest"
    : > "$test_dir/requests"
    install_github_release owner/tool 'tool-{tag}.tar.gz' tool helper > "$test_dir/output" 2>&1
    assert_contains "$(cat "$test_dir/output")" 'owner/tool v1.1.0 is newer than its latest release, v1.0.0; keeping it.'
    assert_equal 'https://github.com/owner/tool/releases/latest' "$(cat "$test_dir/requests")"
    assert_equal 'tool v1.1.0' "$("$test_dir/bin/tool")"
    assert_equal v1.1.0 "$(cat "$record")"
    # A helper from elsewhere on PATH is left alone; only the bootstrap's copy
    # is replaced (without a record, by whatever release is latest).
    rm "$record"
    rm "$test_dir/bin/helper"
    mkdir -p "$test_dir/elsewhere"
    printf '#!/bin/sh\necho "helper elsewhere"\n' > "$test_dir/elsewhere/helper"
    chmod +x "$test_dir/elsewhere/helper"
    PATH="$test_dir/elsewhere:$PATH"
    install_github_release owner/tool 'tool-{tag}.tar.gz' tool helper > "$test_dir/output"
    assert_contains "$(cat "$test_dir/output")" 'helper not installed by the bootstrap; left alone'
    assert_equal 'tool v1.0.0' "$("$test_dir/bin/tool")"
    [ ! -e "$test_dir/bin/helper" ]
    # So is a link in the bin directory, as pipx, uv and npm make, even without a record.
    ln -s "$test_dir/elsewhere/helper" "$test_dir/bin/helper"
    rm "$record"
    install_github_release owner/tool 'tool-{tag}.tar.gz' tool helper > "$test_dir/output"
    assert_equal 'helper elsewhere' "$("$test_dir/bin/helper")"
    [ -L "$test_dir/bin/helper" ]
    assert_equal 'tool v1.0.0' "$("$test_dir/bin/tool")"
    rm "$test_dir/bin/helper"
    # A missing binary brings its installed sibling along, so the record holds for both.
    printf 'v1.1.0\n' > "$test_dir/latest"
    rm "$test_dir/elsewhere/helper"
    unset DOTFILES_UPDATE
    install_github_release owner/tool 'tool-{tag}.tar.gz' tool helper > "$test_dir/output"
    assert_equal 'tool v1.1.0' "$("$test_dir/bin/tool")"
    assert_equal 'helper v1.1.0' "$("$test_dir/bin/helper")"
    assert_equal v1.1.0 "$(cat "$record")"
}

# Every release download is checked against the SHA-256 that GitHub's releases
# API lists for the asset. The digest is read from pretty-printed and minified
# JSON alike, and never from a neighbouring asset, a nested object or a quoted
# string. An asset without a digest, an unreadable release or a file that does
# not match installs and records nothing. A token reaches curl on stdin, never
# in its arguments. file_sha256 agrees with the standard test vector and with
# sha256sum and shasum where they exist.
test_release_download_verification() {
    source "$TEST_REPO_DIR/scripts/bootstrap_tools.sh"
    export DOTFILES_TEST_FIXTURE="$test_dir"
    export DOTFILES_LOCAL_BIN="$test_dir/bin"
    export TMPDIR="$test_dir/tmp"
    unset GITHUB_TOKEN
    local record="$XDG_STATE_HOME/dotfiles/releases/owner/tool" status sum fixture asset
    local abc_sum=ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
    local list_sum other_sum fake_sum
    list_sum="$(printf '%064d' 0 | tr 0 a)"
    other_sum="$(printf '%064d' 0 | tr 0 b)"
    fake_sum="$(printf '%064d' 0 | tr 0 f)"
    mkdir -p "$TMPDIR" "$test_dir/payload"
    printf '#!/bin/sh\necho verified-release\n' > "$test_dir/payload/tool"
    chmod +x "$test_dir/payload/tool"
    tar -czf "$test_dir/asset.tar.gz" -C "$test_dir/payload" .
    printf abc > "$test_dir/abc"
    assert_equal "$abc_sum" "$(file_sha256 "$test_dir/abc")"
    sum="$(file_sha256 "$test_dir/asset.tar.gz")"
    if command -v sha256sum >/dev/null 2>&1; then
        assert_equal "$sum" "$(sha256sum "$test_dir/asset.tar.gz" | cut -d ' ' -f 1)"
    fi
    if command -v shasum >/dev/null 2>&1; then
        assert_equal "$sum" "$(shasum -a 256 "$test_dir/asset.tar.gz" | cut -d ' ' -f 1)"
        # Without sha256sum, file_sha256 falls back to shasum.
        command() { case "$*" in '-v sha256sum') return 1 ;; *) builtin command "$@" ;; esac; }
        shasum() { : > "$DOTFILES_TEST_FIXTURE/shasum-used"; builtin command shasum "$@"; }
        assert_equal "$abc_sum" "$(file_sha256 "$test_dir/abc")"
        assert_equal "$sum" "$(file_sha256 "$test_dir/asset.tar.gz")"
        unset -f command shasum
        [ -f "$test_dir/shasum-used" ]
    fi
    # The release as the API lists it. A checksum file and an asset whose name
    # ends in the same characters come before the tarball; an asset without a
    # digest follows it, labelled with text that quotes one, as the body does.
    cat > "$test_dir/release-pretty.json" <<JSON
{
  "url": "https://api.github.com/repos/owner/tool/releases/1",
  "assets_url": "https://api.github.com/repos/owner/tool/releases/1/assets",
  "upload_url": "https://uploads.github.com/repos/owner/tool/releases/1/assets{?name,label}",
  "html_url": "https://github.com/owner/tool/releases/tag/v1.2.3",
  "id": 1,
  "author": {
    "login": "someone",
    "id": 7,
    "node_id": "U_kgDOAAAABw",
    "avatar_url": "https://avatars.githubusercontent.com/u/7?v=4",
    "gravatar_id": "",
    "url": "https://api.github.com/users/someone",
    "html_url": "https://github.com/someone",
    "type": "User",
    "site_admin": false
  },
  "node_id": "RE_kwDOAAAAAc4AAAAB",
  "tag_name": "v1.2.3",
  "target_commitish": "main",
  "name": "v1.2.3",
  "draft": false,
  "immutable": false,
  "prerelease": false,
  "created_at": "2026-10-01T12:00:00Z",
  "updated_at": "2026-10-01T12:10:00Z",
  "published_at": "2026-10-01T12:10:00Z",
  "assets": [
    {
      "url": "https://api.github.com/repos/owner/tool/releases/assets/11",
      "id": 11,
      "node_id": "RA_kwDOAAAAAc4AAAAL",
      "name": "tool-v1.2.3.tar.gz.sha256",
      "label": "",
      "uploader": {
        "login": "someone",
        "id": 7,
        "url": "https://api.github.com/users/someone",
        "type": "User",
        "site_admin": false
      },
      "content_type": "text/plain",
      "state": "uploaded",
      "size": 84,
      "digest": "sha256:$list_sum",
      "download_count": 12,
      "created_at": "2026-10-01T12:05:00Z",
      "updated_at": "2026-10-01T12:05:00Z",
      "browser_download_url": "https://github.com/owner/tool/releases/download/v1.2.3/tool-v1.2.3.tar.gz.sha256"
    },
    {
      "url": "https://api.github.com/repos/owner/tool/releases/assets/12",
      "id": 12,
      "node_id": "RA_kwDOAAAAAc4AAAAM",
      "name": "x-tool-v1.2.3.tar.gz",
      "label": "",
      "uploader": {
        "login": "someone",
        "id": 7,
        "url": "https://api.github.com/users/someone",
        "type": "User",
        "site_admin": false
      },
      "content_type": "application/gzip",
      "state": "uploaded",
      "size": 4096,
      "digest": "sha256:$other_sum",
      "download_count": 5,
      "created_at": "2026-10-01T12:05:00Z",
      "updated_at": "2026-10-01T12:05:00Z",
      "browser_download_url": "https://github.com/owner/tool/releases/download/v1.2.3/x-tool-v1.2.3.tar.gz"
    },
    {
      "url": "https://api.github.com/repos/owner/tool/releases/assets/13",
      "id": 13,
      "node_id": "RA_kwDOAAAAAc4AAAAN",
      "name": "tool-v1.2.3.tar.gz",
      "label": "",
      "uploader": {
        "login": "someone",
        "id": 7,
        "url": "https://api.github.com/users/someone",
        "type": "User",
        "site_admin": false
      },
      "content_type": "application/gzip",
      "state": "uploaded",
      "size": 2048,
      "digest": "sha256:$sum",
      "download_count": 40,
      "created_at": "2026-10-01T12:05:00Z",
      "updated_at": "2026-10-01T12:05:00Z",
      "browser_download_url": "https://github.com/owner/tool/releases/download/v1.2.3/tool-v1.2.3.tar.gz"
    },
    {
      "url": "https://api.github.com/repos/owner/tool/releases/assets/14",
      "id": 14,
      "node_id": "RA_kwDOAAAAAc4AAAAO",
      "name": "nodigest.tar.gz",
      "label": "Built,\"digest\":\"sha256:$fake_sum\"",
      "uploader": {
        "login": "someone",
        "id": 7,
        "url": "https://api.github.com/users/someone",
        "type": "User",
        "site_admin": false
      },
      "content_type": "application/gzip",
      "state": "uploaded",
      "size": 1024,
      "digest": null,
      "download_count": 0,
      "created_at": "2026-10-01T12:05:00Z",
      "updated_at": "2026-10-01T12:05:00Z",
      "browser_download_url": "https://github.com/owner/tool/releases/download/v1.2.3/nodigest.tar.gz"
    },
    {
      "url": "https://api.github.com/repos/owner/tool/releases/assets/15",
      "id": 15,
      "node_id": "RA_kwDOAAAAAc4AAAAP",
      "name": "sha512.tar.gz",
      "label": "",
      "uploader": {
        "login": "someone",
        "id": 7,
        "url": "https://api.github.com/users/someone",
        "type": "User",
        "site_admin": false
      },
      "content_type": "application/gzip",
      "state": "uploaded",
      "size": 1024,
      "digest": "sha512:$fake_sum$fake_sum",
      "download_count": 0,
      "created_at": "2026-10-01T12:06:00Z",
      "updated_at": "2026-10-01T12:06:00Z",
      "browser_download_url": "https://github.com/owner/tool/releases/download/v1.2.3/sha512.tar.gz"
    }
  ],
  "tarball_url": "https://api.github.com/repos/owner/tool/tarball/v1.2.3",
  "zipball_url": "https://api.github.com/repos/owner/tool/zipball/v1.2.3",
  "body": "Checksums, see \"digest\": \"sha256:$fake_sum\", below"
}
JSON
    # The same release minified: indentation and the space after each key go,
    # and so do the line breaks.
    sed 's/^[[:space:]]*//; s/": /":/' "$test_dir/release-pretty.json" | tr -d '\n' > "$test_dir/release-min.json"
    assert_equal 0 "$(tr -cd '\n' < "$test_dir/release-min.json" | wc -c | tr -d ' ')"
    assert_contains "$(cat "$test_dir/release-min.json")" '"assets":[{"url":"https://api.github.com/repos/owner/tool/releases/assets/11","id":11,'
    uname() { if [ "${1:-}" = -m ]; then printf 'x86_64\n'; else command uname "$@"; fi; }
    curl() {
        local output="" url="" write_out="" token=""
        printf '%s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/calls"
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -o) output="$2"; shift ;;
                -w) write_out="$2"; shift ;;
                -H)
                    # A header read from stdin is how a token arrives.
                    if [ "$2" = @- ]; then
                        cat > "$DOTFILES_TEST_FIXTURE/stdin"
                        token=1
                    fi
                    shift
                    ;;
                --retry|--retry-max-time) shift ;;
                -*) ;;
                *) url="$1" ;;
            esac
            shift
        done
        case "$url" in
            https://github.com/owner/tool/releases/latest)
                [ "$write_out" = '%{url_effective}' ] || return 98
                printf 'https://github.com/owner/tool/releases/tag/v1.2.3'
                ;;
            https://api.github.com/repos/owner/tool/releases/tags/v1.2.3)
                [ ! -f "$DOTFILES_TEST_FIXTURE/api-down" ] || return 22
                [ -z "$token" ] || [ ! -f "$DOTFILES_TEST_FIXTURE/token-rejected" ] || return 22
                cat "$DOTFILES_TEST_FIXTURE/release.json"
                ;;
            https://github.com/owner/tool/releases/download/v1.2.3/tool-v1.2.3.tar.gz)
                printf '%s\n' "$url" >> "$DOTFILES_TEST_FIXTURE/downloads"
                if [ -f "$DOTFILES_TEST_FIXTURE/corrupt" ]; then
                    printf 'not the release\n' > "$output"
                else
                    cp "$DOTFILES_TEST_FIXTURE/asset.tar.gz" "$output"
                fi
                ;;
            *) echo "unexpected URL $url" >&2; return 99 ;;
        esac
    }
    for fixture in release-pretty.json release-min.json; do
        cp "$test_dir/$fixture" "$test_dir/release.json"
        assert_equal "$sum" "$(release_asset_digest owner/tool v1.2.3 tool-v1.2.3.tar.gz)"
        assert_equal "$list_sum" "$(release_asset_digest owner/tool v1.2.3 tool-v1.2.3.tar.gz.sha256)"
        assert_equal "$other_sum" "$(release_asset_digest owner/tool v1.2.3 x-tool-v1.2.3.tar.gz)"
        # A digest in another algorithm cannot be compared either.
        for asset in nodigest.tar.gz sha512.tar.gz; do
            status=0
            release_asset_digest owner/tool v1.2.3 "$asset" > "$test_dir/output" 2>&1 || status=$?
            assert_equal 1 "$status"
            assert_contains "$(cat "$test_dir/output")" "lists no SHA-256 digest for $asset"
        done
        # An asset the release lacks, such as one renamed upstream, says so.
        status=0
        release_asset_digest owner/tool v1.2.3 absent.tar.gz > "$test_dir/output" 2>&1 || status=$?
        assert_equal 1 "$status"
        assert_contains "$(cat "$test_dir/output")" 'Release v1.2.3 of owner/tool has no asset named absent.tar.gz'
    done
    # Without a token curl reads nothing from stdin; with one, the header
    # arrives there and the arguments never hold it.
    assert_equal 0 "$(grep -c -- '@-' "$test_dir/calls")"
    [ ! -e "$test_dir/stdin" ]
    export GITHUB_TOKEN=fixture-secret-token
    assert_equal "$sum" "$(release_asset_digest owner/tool v1.2.3 tool-v1.2.3.tar.gz)"
    assert_contains "$(tail -n 1 "$test_dir/calls")" 'https://api.github.com/repos/owner/tool/releases/tags/v1.2.3'
    assert_contains "$(tail -n 1 "$test_dir/calls")" '-H @-'
    assert_equal 'Authorization: Bearer fixture-secret-token' "$(cat "$test_dir/stdin")"
    assert_equal 0 "$(grep -c fixture-secret-token "$test_dir/calls")"
    unset GITHUB_TOKEN
    rm "$test_dir/stdin"
    assert_equal "$sum" "$(release_asset_digest owner/tool v1.2.3 tool-v1.2.3.tar.gz)"
    assert_equal 1 "$(grep -c -- '@-' "$test_dir/calls")"
    [ ! -e "$test_dir/stdin" ]
    # GitHub answers a token it does not accept with 401 instead of answering
    # anonymously, so one more request goes without it.
    export GITHUB_TOKEN=fixture-secret-token
    : > "$test_dir/token-rejected"
    local calls_before
    calls_before="$(wc -l < "$test_dir/calls" | tr -d ' ')"
    assert_equal "$sum" "$(release_asset_digest owner/tool v1.2.3 tool-v1.2.3.tar.gz 2> "$test_dir/output")"
    assert_contains "$(cat "$test_dir/output")" 'trying once without it'
    assert_equal "$((calls_before + 2))" "$(wc -l < "$test_dir/calls" | tr -d ' ')"
    assert_contains "$(tail -n 2 "$test_dir/calls" | head -n 1)" '-H @-'
    assert_equal 0 "$(tail -n 1 "$test_dir/calls" | grep -c -- '@-' || :)"
    unset GITHUB_TOKEN
    rm "$test_dir/token-rejected" "$test_dir/stdin"
    # An unreadable release stops the install before anything is downloaded.
    : > "$test_dir/api-down"
    status=0
    install_github_release owner/tool 'tool-{tag}.tar.gz' tool > "$test_dir/output" 2>&1 || status=$?
    [ "$status" -ne 0 ]
    assert_contains "$(cat "$test_dir/output")" 'Could not read release v1.2.3 of owner/tool'
    [ ! -e "$test_dir/downloads" ]
    [ ! -e "$DOTFILES_LOCAL_BIN/tool" ]
    [ ! -e "$record" ]
    rm "$test_dir/api-down"
    # A download that differs from the listed digest is deleted before it is
    # unpacked, and nothing is installed or recorded; the intact file installs.
    : > "$test_dir/corrupt"
    status=0
    install_github_release owner/tool 'tool-{tag}.tar.gz' tool > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'does not match the SHA-256 GitHub lists for it'
    assert_contains "$(cat "$test_dir/output")" "expected $sum"
    assert_equal https://github.com/owner/tool/releases/download/v1.2.3/tool-v1.2.3.tar.gz "$(cat "$test_dir/downloads")"
    [ ! -e "$DOTFILES_LOCAL_BIN/tool" ]
    [ ! -e "$record" ]
    assert_equal 0 "$(find "$TMPDIR" -maxdepth 1 -name 'dotfiles-release.*' | wc -l | tr -d ' ')"
    rm "$test_dir/corrupt"
    install_github_release owner/tool 'tool-{tag}.tar.gz' tool > "$test_dir/output"
    assert_equal verified-release "$("$DOTFILES_LOCAL_BIN/tool")"
    assert_equal v1.2.3 "$(cat "$record")"
    assert_equal 0 "$(find "$TMPDIR" -maxdepth 1 -name 'dotfiles-release.*' | wc -l | tr -d ' ')"
    # Every call, the API's included, retries transient failures.
    assert_equal 0 "$(grep -c -v -- '--retry 5' "$test_dir/calls")"
}

# A release is installed once it is DOTFILES_MINIMUM_RELEASE_AGE old, a day
# unless set. Its age is read from the API's release, and an asset updated
# later counts from then. While the latest release is younger, the highest
# version among the recent releases that is old enough, no higher than the
# latest and has the asset is taken instead (never a prerelease, a draft or a
# tag without a version), unless the installed release is at least as new;
# no release ever replaces a newer installed one. A release that is old enough
# costs no request beyond the one its digest needs, and a younger one one
# more, the list, which also serves the older release's digest.
test_release_age() {
    source "$TEST_REPO_DIR/scripts/bootstrap_tools.sh"
    export DOTFILES_TEST_FIXTURE="$test_dir"
    export DOTFILES_LOCAL_BIN="$test_dir/bin"
    export TMPDIR="$test_dir/tmp"
    unset GITHUB_TOKEN DOTFILES_MINIMUM_RELEASE_AGE DOTFILES_GITHUB_API_CACHE
    local record="$XDG_STATE_HOME/dotfiles/releases/owner/tool" status now value sum young old older oldest future
    mkdir -p "$TMPDIR" "$test_dir/api" "$test_dir/payload"
    # The setting: a whole number with a unit, or 0; a day when unset or empty.
    assert_equal 86400 "$(dotfiles_minimum_release_age)"
    assert_equal 86400 "$(DOTFILES_MINIMUM_RELEASE_AGE='' dotfiles_minimum_release_age)"
    for value in 0=0 0d=0 45s=45 30m=1800 12h=43200 08h=28800 3d=259200 2w=1209600; do
        assert_equal "${value#*=}" "$(DOTFILES_MINIMUM_RELEASE_AGE="${value%%=*}" dotfiles_minimum_release_age)"
    done
    assert_equal 604799999395200 "$(DOTFILES_MINIMUM_RELEASE_AGE=999999999w dotfiles_minimum_release_age)"
    for value in 1 d 1.5d -1d 1D 1dd ' 1d' P1D 1000000000w; do
        status=0
        DOTFILES_MINIMUM_RELEASE_AGE="$value" dotfiles_minimum_release_age > "$test_dir/output" 2>&1 || status=$?
        assert_equal 1 "$status"
        assert_contains "$(cat "$test_dir/output")" "DOTFILES_MINIMUM_RELEASE_AGE=$value is not a whole number with a unit"
    done
    # Times as the API writes them, converted without date's parser.
    assert_equal 0 "$(dotfiles_utc_seconds 1970-01-01T00:00:00Z)"
    assert_equal 951782400 "$(dotfiles_utc_seconds 2000-02-29T00:00:00Z)"
    assert_equal 1760000000 "$(dotfiles_utc_seconds 2025-10-09T08:53:20Z)"
    assert_equal 2025-10-09T08:53:20Z "$(dotfiles_utc_time 1760000000)"
    now="$(date -u +%s)"
    assert_equal "$now" "$(dotfiles_utc_seconds "$(dotfiles_utc_time "$now")")"
    for value in '' null - 2025-10-09 '2025-10-09 08:53:20' 2025-10-09T08:53:20+02:00; do
        if dotfiles_utc_seconds "$value" >/dev/null; then
            echo "dotfiles_utc_seconds accepted <$value>" >&2
            return 1
        fi
    done
    young="$(dotfiles_utc_time $((now - 3600)))"
    old="$(dotfiles_utc_time $((now - 2 * 86400)))"
    older="$(dotfiles_utc_time $((now - 3 * 86400)))"
    oldest="$(dotfiles_utc_time $((now - 10 * 86400)))"
    future="$(dotfiles_utc_time $((now + 7 * 86400)))"
    printf '#!/bin/sh\necho aged-release\n' > "$test_dir/payload/tool"
    chmod +x "$test_dir/payload/tool"
    tar -czf "$test_dir/asset.tar.gz" -C "$test_dir/payload" .
    sum="$(file_sha256 "$test_dir/asset.tar.gz")"
    # release_fixture <id> <tag> <published> <asset updated> <prerelease> <draft>
    # [asset]: a release as the API pretty-prints it. The release itself was
    # edited just now, which must not count; its one asset, tool-<tag>.tar.gz
    # unless named, has the digest $sum.
    release_fixture() {
        local published="\"$3\""
        [ "$3" != null ] || published=null
        cat <<JSON
{
  "url": "https://api.github.com/repos/owner/tool/releases/$1",
  "html_url": "https://github.com/owner/tool/releases/tag/$2",
  "id": $1,
  "author": {
    "login": "someone",
    "url": "https://api.github.com/users/someone",
    "type": "User"
  },
  "tag_name": "$2",
  "draft": $6,
  "prerelease": $5,
  "created_at": "$oldest",
  "updated_at": "$young",
  "published_at": $published,
  "assets": [
    {
      "url": "https://api.github.com/repos/owner/tool/releases/assets/${1}1",
      "name": "${7:-tool-$2.tar.gz}",
      "uploader": {
        "login": "someone",
        "url": "https://api.github.com/users/someone"
      },
      "digest": "sha256:$sum",
      "created_at": "$oldest",
      "updated_at": "$4",
      "browser_download_url": "https://github.com/owner/tool/releases/download/$2/${7:-tool-$2.tar.gz}"
    }
  ],
  "body": "Fixes, see \"published_at\": \"$oldest\""
}
JSON
    }
    # Newest first, as the API lists them: a nightly prerelease rebuilt just
    # now, a draft, a release the project did not mark latest, the latest
    # release (an hour old), a release candidate not flagged as a prerelease,
    # a backport of an older line, Neovim-style "stable", a release whose
    # builds failed, one uploaded before GitHub listed digests, then the
    # releases before.
    write_release_fixtures() {
        release_fixture 11 nightly 2024-08-07T00:43:43Z "$young" true false > "$test_dir/api/nightly.json"
        release_fixture 10 v2.2.0 null "$young" false true > "$test_dir/api/v2.2.0.json"
        release_fixture 9 v3.0.0 "$old" "$old" false false > "$test_dir/api/v3.0.0.json"
        release_fixture 8 v2.1.0 "$young" "$young" false false > "$test_dir/api/v2.1.0.json"
        release_fixture 13 v2.1.0-rc.1 "$old" "$old" false false > "$test_dir/api/v2.1.0-rc.1.json"
        release_fixture 7 v1.9.5 "$old" "$old" false false > "$test_dir/api/v1.9.5.json"
        release_fixture 6 stable "$old" "$old" false false > "$test_dir/api/stable.json"
        release_fixture 5 v2.0.2 "$old" "$old" false false checksums.txt > "$test_dir/api/v2.0.2.json"
        release_fixture 12 v2.0.1.1 "$old" "$old" false false |
            sed 's/"digest": "sha256:[0-9a-f]*"/"digest": null/' > "$test_dir/api/v2.0.1.1.json"
        release_fixture 4 v2.0.1 "$older" "${1:-$older}" false false > "$test_dir/api/v2.0.1.json"
        release_fixture 3 v2.0.0 "$oldest" "$oldest" false false > "$test_dir/api/v2.0.0.json"
        {
            printf '[\n'
            for value in nightly v2.2.0 v3.0.0 v2.1.0 v2.1.0-rc.1 v1.9.5 stable v2.0.2 v2.0.1.1 v2.0.1; do
                cat "$test_dir/api/$value.json"
                printf ',\n'
            done
            cat "$test_dir/api/v2.0.0.json"
            printf ']\n'
        } > "$test_dir/api/list.json"
    }
    write_release_fixtures
    # Records come from pretty-printed and minified JSON alike.
    assert_equal "nightly false true $young
v2.2.0 true false -
v3.0.0 false false $old
v2.1.0 false false $young
v2.1.0-rc.1 false false $old
v1.9.5 false false $old
stable false false $old
v2.0.2 false false $old
v2.0.1.1 false false $old
v2.0.1 false false $older
v2.0.0 false false $oldest" "$(release_records < "$test_dir/api/list.json")"
    # Each asset of the list, keyed by tag and name, with its digest.
    assert_equal "v2.0.2/checksums.txt sha256:$sum" "$(release_asset_digests < "$test_dir/api/list.json" | grep '^v2.0.2/')"
    assert_equal "v2.0.1.1/tool-v2.0.1.1.tar.gz -" "$(release_asset_digests < "$test_dir/api/list.json" | grep '^v2.0.1.1/')"
    assert_equal 11 "$(release_asset_digests < "$test_dir/api/list.json" | wc -l | tr -d ' ')"
    # Only plain version numbers count as versions.
    for value in v1.2.3=1.2.3 1.2.3=1.2.3 v2026.10.9=2026.10.9 v0.27=0.27; do
        assert_equal "${value#*=}" "$(release_version "${value%%=*}")"
    done
    for value in stable nightly v0.21.0-pre-release-1 v0.8.1-alpha.1 v2.1.0-rc.1 v1.0.0+k3s1 v v1. v1..2 .1; do
        if release_version "$value" >/dev/null; then
            echo "release_version accepted <$value>" >&2
            return 1
        fi
    done
    assert_equal "$(release_records < "$test_dir/api/list.json")" \
        "$(sed 's/^[[:space:]]*//; s/": /":/' "$test_dir/api/list.json" | tr -d '\n' | release_records)"
    uname() { if [ "${1:-}" = -m ]; then printf 'x86_64\n'; else command uname "$@"; fi; }
    curl() {
        local output="" url=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -o) output="$2"; shift ;;
                -w|-H|--retry|--retry-max-time) shift ;;
                -*) ;;
                *) url="$1" ;;
            esac
            shift
        done
        printf '%s\n' "$url" >> "$DOTFILES_TEST_FIXTURE/requests"
        case "$url" in
            https://github.com/owner/tool/releases/latest)
                printf 'https://github.com/owner/tool/releases/tag/%s' "$(cat "$DOTFILES_TEST_FIXTURE/latest")"
                ;;
            https://api.github.com/repos/owner/tool/releases/tags/*)
                [ -f "$DOTFILES_TEST_FIXTURE/api/${url##*/}.json" ] || return 22
                cat "$DOTFILES_TEST_FIXTURE/api/${url##*/}.json"
                ;;
            'https://api.github.com/repos/owner/tool/releases?per_page=30')
                [ ! -f "$DOTFILES_TEST_FIXTURE/list-down" ] || return 22
                cat "$DOTFILES_TEST_FIXTURE/api/list.json"
                ;;
            https://github.com/owner/tool/releases/download/*) cp "$DOTFILES_TEST_FIXTURE/asset.tar.gz" "$output" ;;
            *) echo "unexpected URL $url" >&2; return 99 ;;
        esac
    }
    local template='tool-{tag}.tar.gz'
    printf 'v2.1.0\n' > "$test_dir/latest"
    # A digest is found by the release's tag, which the download URL holds
    # percent-encoded.
    release_fixture 2 'v1.0.0+k3s1' "$oldest" "$oldest" false false |
        sed 's#/download/v1.0.0+k3s1/#/download/v1.0.0%2Bk3s1/#' > "$test_dir/api/v1.0.0+k3s1.json"
    assert_contains "$(cat "$test_dir/api/v1.0.0+k3s1.json")" '/download/v1.0.0%2Bk3s1/tool-v1.0.0+k3s1.tar.gz'
    assert_equal "$sum" "$(release_asset_digest owner/tool 'v1.0.0+k3s1' 'tool-v1.0.0+k3s1.tar.gz')"
    : > "$test_dir/requests"
    # Turned off, the latest release is taken without asking the API.
    assert_equal v2.1.0 "$(DOTFILES_MINIMUM_RELEASE_AGE=0 release_tag owner/tool "$template")"
    assert_equal https://github.com/owner/tool/releases/latest "$(cat "$test_dir/requests")"
    # A latest release that is old enough costs one request.
    printf 'v2.0.1\n' > "$test_dir/latest"
    : > "$test_dir/requests"
    assert_equal v2.0.1 "$(release_tag owner/tool "$template" 2> "$test_dir/output")"
    assert_equal "https://github.com/owner/tool/releases/latest
https://api.github.com/repos/owner/tool/releases/tags/v2.0.1" "$(cat "$test_dir/requests")"
    assert_equal '' "$(cat "$test_dir/output")"
    # A younger one: the highest version old enough that has the asset with a
    # digest, which is neither the release above the latest, nor the release
    # candidate, the backport listed before it, "stable", v2.0.2 without
    # builds or v2.0.1.1 without a digest. It says so.
    printf 'v2.1.0\n' > "$test_dir/latest"
    : > "$test_dir/requests"
    assert_equal v2.0.1 "$(release_tag owner/tool "$template" 2> "$test_dir/output")"
    assert_equal "https://github.com/owner/tool/releases/latest
https://api.github.com/repos/owner/tool/releases/tags/v2.1.0
https://api.github.com/repos/owner/tool/releases?per_page=30" "$(cat "$test_dir/requests")"
    assert_equal "owner/tool v2.1.0 dates from $young, less than 1d ago; taking v2.0.1." "$(cat "$test_dir/output")"
    # A template that v2.0.2 does have takes it.
    assert_equal v2.0.2 "$(release_tag owner/tool checksums.txt 2>/dev/null)"
    assert_equal v2.0.0 "$(DOTFILES_MINIMUM_RELEASE_AGE=4d release_tag owner/tool "$template" 2>/dev/null)"
    assert_equal v2.0.0 "$(DOTFILES_MINIMUM_RELEASE_AGE=73h release_tag owner/tool "$template" 2>/dev/null)"
    # Exactly as old as the setting is old enough.
    assert_equal v2.0.1 "$(DOTFILES_MINIMUM_RELEASE_AGE=72h release_tag owner/tool "$template" 2>/dev/null)"
    # The installed release decides when it is at least as new; the latest
    # release itself, once installed, is never looked up again.
    : > "$test_dir/requests"
    assert_equal v2.1.0 "$(release_tag owner/tool "$template" v2.1.0)"
    assert_equal https://github.com/owner/tool/releases/latest "$(cat "$test_dir/requests")"
    assert_equal v2.0.1 "$(release_tag owner/tool "$template" v2.0.0 2>/dev/null)"
    assert_equal v2.0.1 "$(release_tag owner/tool "$template" custom-build 2>/dev/null)"
    assert_equal v2.0.1 "$(release_tag owner/tool "$template" v2.0.1 2> "$test_dir/output")"
    assert_equal "owner/tool v2.1.0 dates from $young, less than 1d ago; keeping v2.0.1." "$(cat "$test_dir/output")"
    assert_equal v2.0.5 "$(release_tag owner/tool "$template" v2.0.5 2>/dev/null)"
    # No release replaces a newer installed one, as when a project deletes
    # its newest releases, whatever the setting and without a request.
    : > "$test_dir/requests"
    assert_equal v2.4.0 "$(DOTFILES_MINIMUM_RELEASE_AGE=0 release_tag owner/tool "$template" v2.4.0 2> "$test_dir/output")"
    assert_equal 'owner/tool v2.4.0 is newer than its latest release, v2.1.0; keeping it.' "$(cat "$test_dir/output")"
    assert_equal https://github.com/owner/tool/releases/latest "$(cat "$test_dir/requests")"
    printf 'v2.0.0\n' > "$test_dir/latest"
    assert_equal v2.0.1 "$(release_tag owner/tool "$template" v2.0.1 2>/dev/null)"
    # The same version spelled differently is not newer.
    printf 'v2.1.0\n' > "$test_dir/latest"
    assert_equal v2.1.0 "$(DOTFILES_MINIMUM_RELEASE_AGE=0 release_tag owner/tool "$template" 2.1.0 2> "$test_dir/output")"
    assert_equal '' "$(cat "$test_dir/output")"
    printf 'v2.1.0\n' > "$test_dir/latest"
    # Nothing old enough: a first install stops and says how to go ahead; an
    # installed release stays.
    status=0
    DOTFILES_MINIMUM_RELEASE_AGE=2w release_tag owner/tool "$template" > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" "No release of owner/tool among the 30 most recent is older than 2w and lists its asset (for v2.1.0, tool-v2.1.0.tar.gz) with a SHA-256 digest; the latest, v2.1.0, dates from $young."
    assert_contains "$(cat "$test_dir/output")" 'Rerun with DOTFILES_MINIMUM_RELEASE_AGE=0 to install v2.1.0 anyway.'
    case "$(cat "$test_dir/output")" in
        *'system time'*) echo "A release in the past blamed the clock." >&2; return 1 ;;
    esac
    assert_equal v2.0.0 "$(DOTFILES_MINIMUM_RELEASE_AGE=2w release_tag owner/tool "$template" v2.0.0 2>/dev/null)"
    # A release dated after this machine's clock points at the clock.
    release_fixture 8 v2.1.0 "$future" "$future" false false > "$test_dir/api/v2.1.0.json"
    status=0
    DOTFILES_MINIMUM_RELEASE_AGE=2w release_tag owner/tool "$template" > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" "That is later than this machine's clock"
    # An asset updated after its release was published (a replaced file)
    # makes the release that young.
    write_release_fixtures "$young"
    assert_equal "$young" "$(release_published owner/tool v2.0.1)"
    assert_equal v2.0.0 "$(release_tag owner/tool "$template" 2>/dev/null)"
    write_release_fixtures
    # A wrong setting stops before the API is asked; so does an unreadable
    # release or list, saying which.
    : > "$test_dir/requests"
    status=0
    DOTFILES_MINIMUM_RELEASE_AGE=soon release_tag owner/tool "$template" > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'DOTFILES_MINIMUM_RELEASE_AGE=soon is not'
    assert_equal https://github.com/owner/tool/releases/latest "$(cat "$test_dir/requests")"
    mv "$test_dir/api/v2.1.0.json" "$test_dir/api/v2.1.0.away"
    status=0
    release_tag owner/tool "$template" > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'Could not read release v2.1.0 of owner/tool from the GitHub API to check its age.'
    mv "$test_dir/api/v2.1.0.away" "$test_dir/api/v2.1.0.json"
    : > "$test_dir/list-down"
    status=0
    release_tag owner/tool "$template" > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'Could not list the releases of owner/tool from the GitHub API to find one older than 1d.'
    rm "$test_dir/list-down"
    # A run keeps each answer: the age check and the digest check share a
    # request, and a young latest release costs the list, which also holds
    # the older release's digest.
    export DOTFILES_GITHUB_API_CACHE="$test_dir/cache"
    mkdir -p "$DOTFILES_GITHUB_API_CACHE"
    : > "$test_dir/requests"
    install_github_release owner/tool "$template" tool > "$test_dir/output" 2>&1
    assert_equal "https://github.com/owner/tool/releases/latest
https://api.github.com/repos/owner/tool/releases/tags/v2.1.0
https://api.github.com/repos/owner/tool/releases?per_page=30
https://github.com/owner/tool/releases/download/v2.0.1/tool-v2.0.1.tar.gz" "$(cat "$test_dir/requests")"
    assert_contains "$(cat "$test_dir/output")" 'taking v2.0.1'
    assert_contains "$(cat "$test_dir/output")" 'Installing tool from owner/tool v2.0.1...'
    assert_equal aged-release "$("$DOTFILES_LOCAL_BIN/tool")"
    assert_equal v2.0.1 "$(cat "$record")"
    # Updating keeps it while the latest release is young...
    export DOTFILES_UPDATE=1
    : > "$test_dir/requests"
    install_github_release owner/tool "$template" tool > "$test_dir/output" 2>&1
    assert_contains "$(cat "$test_dir/output")" 'keeping v2.0.1'
    assert_contains "$(cat "$test_dir/output")" 'tool v2.0.1 is current'
    assert_equal 0 "$(grep -c /releases/download/ "$test_dir/requests" || :)"
    # ...and takes it once it is old enough, with one request in a new run.
    release_fixture 8 v2.1.0 "$old" "$old" false false > "$test_dir/api/v2.1.0.json"
    rm -rf "$DOTFILES_GITHUB_API_CACHE"
    mkdir -p "$DOTFILES_GITHUB_API_CACHE"
    : > "$test_dir/requests"
    install_github_release owner/tool "$template" tool > "$test_dir/output" 2>&1
    assert_equal "https://github.com/owner/tool/releases/latest
https://api.github.com/repos/owner/tool/releases/tags/v2.1.0
https://github.com/owner/tool/releases/download/v2.1.0/tool-v2.1.0.tar.gz" "$(cat "$test_dir/requests")"
    assert_contains "$(cat "$test_dir/output")" 'Updating tool from owner/tool v2.0.1 to v2.1.0...'
    assert_equal v2.1.0 "$(cat "$record")"
}

# bootstrap_tools_main keeps the GitHub API's answers in one directory for the
# whole run, under TMPDIR, and removes it when the run ends, failed or not; a
# setting it cannot read stops it before any stage.
test_bootstrap_tools_api_cache() {
    source "$TEST_REPO_DIR/scripts/bootstrap_tools.sh"
    export TMPDIR="$test_dir/tmp"
    mkdir -p "$TMPDIR"
    local stage cache status
    dotfiles_init_environment() { return 0; }
    for stage in bootstrap_zinit bootstrap_tmux bootstrap_oh_my_posh bootstrap_bat_theme install_linux_tools \
        bootstrap_runtimes bootstrap_yazi_flavors bootstrap_neovim; do
        eval "$stage() { [ -d \"\$DOTFILES_GITHUB_API_CACHE\" ] && printf '%s\n' \"\$DOTFILES_GITHUB_API_CACHE\" >> \"\$test_dir/caches\"; }"
    done
    (bootstrap_tools_main)
    assert_equal 1 "$(sort -u "$test_dir/caches" | wc -l | tr -d ' ')"
    cache="$(head -n 1 "$test_dir/caches")"
    case "$cache" in
        "$TMPDIR"/dotfiles-github-api.*) ;;
        *) echo "The cache directory $cache is not under TMPDIR." >&2; return 1 ;;
    esac
    [ ! -e "$cache" ]
    bootstrap_runtimes() { printf '%s\n' "$DOTFILES_GITHUB_API_CACHE" > "$test_dir/failed-run"; return 7; }
    status=0
    (bootstrap_tools_main) || status=$?
    assert_equal 7 "$status"
    [ -s "$test_dir/failed-run" ]
    [ ! -e "$(cat "$test_dir/failed-run")" ]
    : > "$test_dir/caches"
    status=0
    (DOTFILES_MINIMUM_RELEASE_AGE=soon bootstrap_tools_main) > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'DOTFILES_MINIMUM_RELEASE_AGE=soon is not'
    assert_equal '' "$(cat "$test_dir/caches")"
    assert_equal 0 "$(find "$TMPDIR" -maxdepth 1 -name 'dotfiles-github-api.*' | wc -l | tr -d ' ')"
}

test_fd_link_for_debian() {
    source "$TEST_REPO_DIR/scripts/bootstrap_tools.sh"
    export DOTFILES_TEST_FIXTURE="$test_dir"
    export DOTFILES_LOCAL_BIN="$test_dir/bin"
    printf '#!/bin/sh\necho fdfind\n' > "$test_dir/fdfind"
    chmod +x "$test_dir/fdfind"
    command() {
        case "$*" in
            '-v fd') [ -f "$DOTFILES_TEST_FIXTURE/fd-present" ] ;;
            '-v fdfind') [ -f "$DOTFILES_TEST_FIXTURE/fdfind-present" ] && printf '%s/fdfind\n' "$DOTFILES_TEST_FIXTURE" ;;
            *) builtin command "$@" ;;
        esac
    }
    local status=0
    install_fd_link > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'fd-find is not installed'
    : > "$test_dir/fdfind-present"
    install_fd_link
    assert_equal "$test_dir/fdfind" "$(readlink "$test_dir/bin/fd")"
    assert_equal fdfind "$("$test_dir/bin/fd")"
    install_fd_link
    # A real file in the way is reported rather than replaced, and a present fd needs nothing.
    rm "$test_dir/bin/fd"
    printf 'user script\n' > "$test_dir/bin/fd"
    status=0
    install_fd_link > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_equal 'user script' "$(cat "$test_dir/bin/fd")"
    : > "$test_dir/fd-present"
    install_fd_link
    assert_equal 'user script' "$(cat "$test_dir/bin/fd")"
}

test_mise_bootstrap_and_runtimes() {
    source "$TEST_REPO_DIR/scripts/bootstrap_tools.sh"
    trust_release_downloads
    export DOTFILES_TEST_FIXTURE="$test_dir"
    export DOTFILES_LOCAL_BIN="$test_dir/bin"
    export TMPDIR="$test_dir/tmp"
    mkdir -p "$TMPDIR"
    # The local bin directory is on PATH; mise-present stands for Homebrew's copy.
    command() {
        case "$*" in
            '-v mise')
                if [ -x "$DOTFILES_LOCAL_BIN/mise" ]; then
                    printf '%s/mise\n' "$DOTFILES_LOCAL_BIN"
                elif [ -f "$DOTFILES_TEST_FIXTURE/mise-present" ]; then
                    printf '/opt/homebrew/bin/mise\n'
                else
                    return 1
                fi
                ;;
            *) builtin command "$@" ;;
        esac
    }
    uname() { if [ "${1:-}" = -m ]; then printf 'x86_64\n'; else command uname "$@"; fi; }
    # The release binary records its self-updates and the minimum release age
    # they were given.
    printf '#!/bin/sh\nprintf "%%s %%s\\n" "$MISE_MINIMUM_RELEASE_AGE" "$*" >> "$DOTFILES_TEST_FIXTURE/self-updates"\n[ -f "$DOTFILES_TEST_FIXTURE/self-update-ok" ] || exit 62\n' > "$test_dir/mise-release"
    curl() {
        local output="" url=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -o|-w) output="$2"; shift ;;
                -*) ;;
                *) url="$1" ;;
            esac
            shift
        done
        printf '%s\n' "$url" >> "$DOTFILES_TEST_FIXTURE/requests"
        [ -f "$DOTFILES_TEST_FIXTURE/retry" ] || return 45
        case "$url" in
            https://github.com/jdx/mise/releases/latest) printf 'https://github.com/jdx/mise/releases/tag/v2026.10.1' ;;
            https://github.com/jdx/mise/releases/download/*) cp "$DOTFILES_TEST_FIXTURE/mise-release" "$output" ;;
            *) echo "unexpected URL $url" >&2; return 99 ;;
        esac
    }
    # Nothing downloaded may reach a shell.
    sh() { printf 'sh %s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/shells"; cat >/dev/null; }
    bash() { printf 'bash %s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/shells"; cat >/dev/null; }
    local status=0
    bootstrap_mise_binary > "$test_dir/output" 2>&1 || status=$?
    assert_equal 45 "$status"
    [ ! -e "$test_dir/bin/mise" ]
    : > "$test_dir/retry"
    : > "$test_dir/requests"
    bootstrap_mise_binary > "$test_dir/output"
    assert_equal 'https://github.com/jdx/mise/releases/latest
https://github.com/jdx/mise/releases/download/v2026.10.1/mise-v2026.10.1-linux-x64-musl' "$(cat "$test_dir/requests")"
    cmp -s "$test_dir/mise-release" "$test_dir/bin/mise"
    [ -x "$test_dir/bin/mise" ]
    # mise updates itself, so no tag is recorded for it.
    [ ! -e "$XDG_STATE_HOME/dotfiles/releases/jdx/mise" ]
    [ ! -e "$test_dir/shells" ]
    : > "$test_dir/requests"
    bootstrap_mise_binary > "$test_dir/output"
    assert_contains "$(cat "$test_dir/output")" 'mise already installed'
    assert_equal '' "$(cat "$test_dir/requests")"
    [ ! -e "$test_dir/self-updates" ]
    # Updating: the bootstrap's own copy updates itself, a failed self-update
    # can be retried, and a mise from elsewhere is left alone.
    export DOTFILES_UPDATE=1
    status=0
    bootstrap_mise_binary > "$test_dir/output" 2>&1 || status=$?
    assert_equal 62 "$status"
    : > "$test_dir/self-update-ok"
    bootstrap_mise_binary > "$test_dir/output"
    assert_equal $' self-update --yes\n self-update --yes' "$(cat "$test_dir/self-updates")"
    # Given DOTFILES_MINIMUM_RELEASE_AGE, it waits as long as that says, unless
    # mise's own setting is in the environment; a wrong setting stops it.
    DOTFILES_MINIMUM_RELEASE_AGE=0 bootstrap_mise_binary > "$test_dir/output"
    MISE_MINIMUM_RELEASE_AGE=3d DOTFILES_MINIMUM_RELEASE_AGE=12h bootstrap_mise_binary > "$test_dir/output"
    status=0
    DOTFILES_MINIMUM_RELEASE_AGE=1 bootstrap_mise_binary > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_equal $'0s self-update --yes\n3d self-update --yes' "$(tail -n 2 "$test_dir/self-updates")"
    rm "$test_dir/bin/mise"
    : > "$test_dir/mise-present"
    bootstrap_mise_binary > "$test_dir/output"
    assert_contains "$(cat "$test_dir/output")" 'mise at /opt/homebrew/bin/mise was not installed by the bootstrap; left alone'
    assert_equal 4 "$(wc -l < "$test_dir/self-updates" | tr -d ' ')"
    assert_equal '' "$(cat "$test_dir/requests")"
    unset DOTFILES_UPDATE
    # Runtimes: a failed install reports, a retry finishes, a missing node is not success.
    mise() {
        printf '%s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/mise-commands"
        case "$1" in
            install) [ -f "$DOTFILES_TEST_FIXTURE/runtime-retry" ] || return 53; : > "$DOTFILES_TEST_FIXTURE/node-installed" ;;
            which) [ -f "$DOTFILES_TEST_FIXTURE/node-installed" ] && printf '%s/node\n' "$DOTFILES_TEST_FIXTURE" ;;
        esac
    }
    status=0
    bootstrap_runtimes > "$test_dir/output" 2>&1 || status=$?
    assert_equal 53 "$status"
    : > "$test_dir/runtime-retry"
    bootstrap_runtimes
    assert_equal $'install --yes\nwhich node' "$(tail -n 2 "$test_dir/mise-commands")"
    rm "$test_dir/node-installed"
    mise() {
        case "$1" in
            install) return 0 ;;
            which) return 1 ;;
        esac
    }
    status=0
    bootstrap_runtimes > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'does not provide node'
    # Updating, mise also upgrades the runtimes, from the home directory so a
    # project's mise file does not decide; a failed upgrade can be retried.
    : > "$test_dir/node-installed"
    mise() {
        printf '%s in %s%s\n' "$*" "$PWD" "${MISE_MINIMUM_RELEASE_AGE:+ after $MISE_MINIMUM_RELEASE_AGE}" >> "$DOTFILES_TEST_FIXTURE/mise-commands"
        case "$1" in
            upgrade) [ -f "$DOTFILES_TEST_FIXTURE/upgrade-retry" ] || return 63 ;;
            which) printf '%s/node\n' "$DOTFILES_TEST_FIXTURE" ;;
        esac
    }
    export DOTFILES_UPDATE=1
    cd "$test_dir"
    status=0
    bootstrap_runtimes > "$test_dir/output" 2>&1 || status=$?
    assert_equal 63 "$status"
    : > "$test_dir/upgrade-retry"
    bootstrap_runtimes > "$test_dir/output"
    assert_equal "install --yes in $PWD
upgrade --yes in $HOME
which node in $PWD" "$(tail -n 3 "$test_dir/mise-commands")"
    DOTFILES_MINIMUM_RELEASE_AGE=2w bootstrap_runtimes > "$test_dir/output"
    assert_equal "install --yes in $PWD after 1209600s
upgrade --yes in $HOME after 1209600s" "$(tail -n 3 "$test_dir/mise-commands" | head -n 2)"
    unset DOTFILES_UPDATE
    rm "$test_dir/mise-present"
    status=0
    bootstrap_runtimes > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'mise is not installed'
}

test_yazi_flavors_install_and_retry() {
    source "$TEST_REPO_DIR/scripts/bootstrap_tools.sh"
    export DOTFILES_TEST_FIXTURE="$test_dir"
    export XDG_CONFIG_HOME="$test_dir/config"
    mkdir -p "$XDG_CONFIG_HOME/yazi"
    command() {
        case "$*" in
            '-v ya') [ -f "$DOTFILES_TEST_FIXTURE/ya-present" ] ;;
            *) builtin command "$@" ;;
        esac
    }
    ya() {
        local flavor
        printf '%s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/commands"
        [ -f "$DOTFILES_TEST_FIXTURE/retry" ] || return 52
        case "$1 $2" in
            'pkg add')
                flavor="${3#yazi-rs/flavors:}"
                printf '[[flavor]]\nuse = "%s"\n' "$3" >> "$XDG_CONFIG_HOME/yazi/package.toml"
                mkdir -p "$XDG_CONFIG_HOME/yazi/flavors/$flavor.yazi"
                : > "$XDG_CONFIG_HOME/yazi/flavors/$flavor.yazi/flavor.toml"
                ;;
            'pkg install')
                for flavor in $(sed -n 's/^use = "yazi-rs\/flavors:\(.*\)"$/\1/p' "$XDG_CONFIG_HOME/yazi/package.toml"); do
                    mkdir -p "$XDG_CONFIG_HOME/yazi/flavors/$flavor.yazi"
                    : > "$XDG_CONFIG_HOME/yazi/flavors/$flavor.yazi/flavor.toml"
                done
                ;;
            'pkg upgrade') [ -f "$DOTFILES_TEST_FIXTURE/upgrade-retry" ] || return 64 ;;
        esac
    }
    local status=0
    bootstrap_yazi_flavors > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'yazi is not installed'
    : > "$test_dir/ya-present"
    status=0
    bootstrap_yazi_flavors > "$test_dir/output" 2>&1 || status=$?
    assert_equal 52 "$status"
    [ ! -d "$XDG_CONFIG_HOME/yazi/flavors" ]
    : > "$test_dir/retry"
    bootstrap_yazi_flavors
    # The flavors come from config/yazi/theme.toml: the dark one, then the
    # light one, which is Latte; a Latte tree names it once.
    local flavors dark light expected flavor
    flavors="$(dotfiles_yazi_flavors "$TEST_REPO_DIR/config/yazi/theme.toml")"
    dark="$(printf '%s\n' "$flavors" | head -n 1)"
    light="$(printf '%s\n' "$flavors" | tail -n 1)"
    assert_equal catppuccin-latte "$light"
    assert_equal "$(printf '%s\n' "$flavors" | sort -u | wc -l | tr -d ' ')" "$(printf '%s\n' "$flavors" | wc -l | tr -d ' ')"
    expected=""
    for flavor in $flavors; do expected="${expected:+$expected
}pkg add yazi-rs/flavors:$flavor"; done
    assert_equal "$expected" "$(tail -n "$(printf '%s\n' "$flavors" | wc -l | tr -d ' ')" "$test_dir/commands")"
    [ -f "$XDG_CONFIG_HOME/yazi/flavors/$light.yazi/flavor.toml" ]
    : > "$test_dir/commands"
    bootstrap_yazi_flavors
    assert_equal '' "$(cat "$test_dir/commands")"
    # A new machine with package.toml restored uses install rather than add.
    rm -rf "$XDG_CONFIG_HOME/yazi/flavors"
    bootstrap_yazi_flavors
    assert_equal 'pkg install' "$(cat "$test_dir/commands")"
    [ -f "$XDG_CONFIG_HOME/yazi/flavors/$dark.yazi/flavor.toml" ]
    # Updating, ya upgrades these flavors by name, so other packages in
    # package.toml stay as they are; a failed upgrade can be retried.
    printf '[[plugin.deps]]\nuse = "someone/plugin"\n' >> "$XDG_CONFIG_HOME/yazi/package.toml"
    export DOTFILES_UPDATE=1
    : > "$test_dir/commands"
    status=0
    bootstrap_yazi_flavors > "$test_dir/output" 2>&1 || status=$?
    assert_equal 64 "$status"
    expected="pkg upgrade"
    for flavor in $flavors; do expected="$expected yazi-rs/flavors:$flavor"; done
    assert_equal "$expected" "$(cat "$test_dir/commands")"
    : > "$test_dir/upgrade-retry"
    bootstrap_yazi_flavors > "$test_dir/output"
    assert_equal "$expected" "$(tail -n 1 "$test_dir/commands")"
    # A flavor that package.toml does not list was put there by hand and stays.
    grep -v "flavors:$dark\"" "$XDG_CONFIG_HOME/yazi/package.toml" > "$test_dir/package.toml"
    cp "$test_dir/package.toml" "$XDG_CONFIG_HOME/yazi/package.toml"
    : > "$test_dir/commands"
    bootstrap_yazi_flavors > "$test_dir/output"
    assert_contains "$(cat "$test_dir/output")" "yazi flavor $dark is not in $XDG_CONFIG_HOME/yazi/package.toml; left alone"
    assert_equal "pkg upgrade yazi-rs/flavors:$light" "$(cat "$test_dir/commands")"
}

test_neovim_release_install() {
    source "$TEST_REPO_DIR/scripts/bootstrap_tools.sh"
    trust_release_downloads
    export DOTFILES_TEST_FIXTURE="$test_dir"
    export DOTFILES_LOCAL_BIN="$test_dir/bin"
    export DOTFILES_LOCAL_OPT="$test_dir/opt"
    export TMPDIR="$test_dir/tmp"
    mkdir -p "$TMPDIR" "$test_dir/payload/nvim-linux-x86_64/bin" "$test_dir/payload/nvim-linux-x86_64/share/nvim/runtime" \
        "$test_dir/old-payload/nvim-linux-x86_64/bin" "$test_dir/bad-payload/nvim-linux-x86_64/share"
    printf '#!/bin/sh\necho "NVIM v0.12.6"\n' > "$test_dir/payload/nvim-linux-x86_64/bin/nvim"
    printf 'runtime\n' > "$test_dir/payload/nvim-linux-x86_64/share/nvim/runtime/filetype.lua"
    printf '#!/bin/sh\necho "NVIM v0.11.6"\n' > "$test_dir/old-payload/nvim-linux-x86_64/bin/nvim"
    chmod +x "$test_dir/payload/nvim-linux-x86_64/bin/nvim" "$test_dir/old-payload/nvim-linux-x86_64/bin/nvim"
    tar -czf "$test_dir/asset.tar.gz" -C "$test_dir/payload" .
    tar -czf "$test_dir/old-asset.tar.gz" -C "$test_dir/old-payload" .
    tar -czf "$test_dir/bad-asset.tar.gz" -C "$test_dir/bad-payload" .
    # The nvim on PATH is whatever the fixture says; the installed link is run by path.
    nvim() {
        if [ -f "$DOTFILES_TEST_FIXTURE/nvim-on-path" ]; then
            cat "$DOTFILES_TEST_FIXTURE/nvim-on-path"
            return 0
        fi
        return 127
    }
    uname() { if [ "${1:-}" = -m ]; then cat "$DOTFILES_TEST_FIXTURE/arch"; else command uname "$@"; fi; }
    printf 'x86_64\n' > "$test_dir/arch"
    curl() {
        local output="" url=""
        printf '%s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/commands"
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -o|-w) output="$2"; shift ;;
                -*) ;;
                *) url="$1" ;;
            esac
            shift
        done
        case "$url" in
            https://github.com/neovim/neovim/releases/latest) printf 'https://github.com/neovim/neovim/releases/tag/v0.12.6' ;;
            https://github.com/neovim/neovim/releases/download/v0.12.6/*)
                [ -f "$DOTFILES_TEST_FIXTURE/retry" ] || return 56
                printf '%s\n' "$url" >> "$DOTFILES_TEST_FIXTURE/downloads"
                cp "$DOTFILES_TEST_FIXTURE/$(cat "$DOTFILES_TEST_FIXTURE/serve")" "$output"
                ;;
            *) echo "unexpected URL $url" >&2; return 99 ;;
        esac
    }
    printf 'asset.tar.gz\n' > "$test_dir/serve"
    # A Neovim that is new enough, from any source, needs nothing.
    printf 'NVIM v0.12.0\n' > "$test_dir/nvim-on-path"
    install_neovim_release > "$test_dir/output"
    assert_contains "$(cat "$test_dir/output")" 'Neovim 0.12.0 already installed'
    [ ! -f "$test_dir/commands" ]
    # An old distribution package triggers the download; a failed download leaves nothing behind.
    printf 'NVIM v0.9.5\n' > "$test_dir/nvim-on-path"
    local status=0
    install_neovim_release > "$test_dir/output" 2>&1 || status=$?
    assert_equal 56 "$status"
    assert_contains "$(cat "$test_dir/output")" 'found 0.9.5, need'
    [ ! -e "$test_dir/opt" ]
    [ ! -e "$test_dir/bin/nvim" ]
    assert_equal 0 "$(find "$TMPDIR" -maxdepth 1 -name 'dotfiles-nvim.*' | wc -l | tr -d ' ')"
    : > "$test_dir/retry"
    install_neovim_release > "$test_dir/output"
    assert_equal 'https://github.com/neovim/neovim/releases/download/v0.12.6/nvim-linux-x86_64.tar.gz' "$(cat "$test_dir/downloads")"
    assert_equal 'neovim/neovim v0.12.6 nvim-linux-x86_64.tar.gz' "$(tail -n 1 "$test_dir/verified")"
    assert_equal "$test_dir/opt/nvim/bin/nvim" "$(readlink "$test_dir/bin/nvim")"
    assert_equal 'NVIM v0.12.6' "$("$test_dir/bin/nvim" --version)"
    [ -f "$test_dir/opt/nvim/share/nvim/runtime/filetype.lua" ]
    [ ! -e "$test_dir/opt/nvim.new" ]
    assert_contains "$(cat "$test_dir/output")" "Installed Neovim 0.12.6 into $test_dir/opt/nvim"
    assert_equal 0 "$(find "$TMPDIR" -maxdepth 1 -name 'dotfiles-nvim.*' | wc -l | tr -d ' ')"
    # Without any nvim the release is installed too, replacing a previous tree whole.
    rm "$test_dir/nvim-on-path"
    printf 'stale\n' > "$test_dir/opt/nvim/stale-file"
    install_neovim_release > "$test_dir/output"
    assert_equal 2 "$(wc -l < "$test_dir/downloads" | tr -d ' ')"
    [ ! -e "$test_dir/opt/nvim/stale-file" ]
    [ -x "$test_dir/opt/nvim/bin/nvim" ]
    # An archive without bin/nvim, or with a Neovim that is still too old, is refused and the current tree stays.
    printf 'bad-asset.tar.gz\n' > "$test_dir/serve"
    status=0
    install_neovim_release > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'does not contain bin/nvim'
    assert_equal 'NVIM v0.12.6' "$("$test_dir/bin/nvim" --version)"
    printf 'old-asset.tar.gz\n' > "$test_dir/serve"
    status=0
    install_neovim_release > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'is older than'
    assert_equal 'NVIM v0.12.6' "$("$test_dir/bin/nvim" --version)"
    printf 'asset.tar.gz\n' > "$test_dir/serve"
    # A real file where the link belongs is reported, never replaced.
    rm "$test_dir/bin/nvim"
    printf 'user script\n' > "$test_dir/bin/nvim"
    status=0
    install_neovim_release > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'is not a link'
    assert_equal 'user script' "$(cat "$test_dir/bin/nvim")"
    rm "$test_dir/bin/nvim"
    # arm64 machines get the arm64 asset.
    printf 'aarch64\n' > "$test_dir/arch"
    install_neovim_release > "$test_dir/output"
    assert_equal 'https://github.com/neovim/neovim/releases/download/v0.12.6/nvim-linux-arm64.tar.gz' "$(tail -n 1 "$test_dir/downloads")"
    # The version helpers behind the decision.
    assert_equal 0.12.6 "$(dotfiles_nvim_version "$test_dir/bin/nvim")"
    dotfiles_version_at_least 0.12 0.12.0
    dotfiles_version_at_least 0.12.6 0.12.0
    dotfiles_version_at_least 1.0 0.12.0
    if dotfiles_version_at_least 0.11.6 0.12.0 || dotfiles_version_at_least 0.12.0 0.12.1; then
        echo "An older version passed the minimum." >&2
        return 1
    fi
}

# Updating replaces the bootstrap's Neovim tree when the latest tag differs
# from the recorded one, keeps it when a download fails, and leaves a Neovim
# from another source alone.
test_neovim_release_update() {
    source "$TEST_REPO_DIR/scripts/bootstrap_tools.sh"
    trust_release_downloads
    export DOTFILES_TEST_FIXTURE="$test_dir"
    export DOTFILES_LOCAL_BIN="$test_dir/bin"
    export DOTFILES_LOCAL_OPT="$test_dir/opt"
    export TMPDIR="$test_dir/tmp"
    local record="$XDG_STATE_HOME/dotfiles/releases/neovim/neovim" tag
    mkdir -p "$TMPDIR"
    for tag in v0.12.6 v0.12.7 v0.12.8; do
        mkdir -p "$test_dir/payload-$tag/nvim-linux-x86_64/bin"
        printf '#!/bin/sh\necho "NVIM %s"\n' "$tag" > "$test_dir/payload-$tag/nvim-linux-x86_64/bin/nvim"
    done
    printf '#!/bin/sh\necho "nvim: /lib/libc.so.6: version GLIBC_2.41 not found" >&2\nexit 1\n' > "$test_dir/payload-v0.12.8/nvim-linux-x86_64/bin/nvim"
    for tag in v0.12.6 v0.12.7 v0.12.8; do
        chmod +x "$test_dir/payload-$tag/nvim-linux-x86_64/bin/nvim"
        tar -czf "$test_dir/asset-$tag.tar.gz" -C "$test_dir/payload-$tag" .
    done
    printf 'v0.12.6\n' > "$test_dir/latest"
    # The nvim on PATH is the bootstrap's link when it exists, else the fixture's.
    nvim() {
        if [ -x "$DOTFILES_LOCAL_BIN/nvim" ]; then
            "$DOTFILES_LOCAL_BIN/nvim" "$@"
        elif [ -f "$DOTFILES_TEST_FIXTURE/nvim-on-path" ]; then
            cat "$DOTFILES_TEST_FIXTURE/nvim-on-path"
        else
            return 127
        fi
    }
    uname() { if [ "${1:-}" = -m ]; then printf 'x86_64\n'; else command uname "$@"; fi; }
    curl() {
        local output="" url="" release
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -o|-w) output="$2"; shift ;;
                -*) ;;
                *) url="$1" ;;
            esac
            shift
        done
        printf '%s\n' "$url" >> "$DOTFILES_TEST_FIXTURE/requests"
        case "$url" in
            https://github.com/neovim/neovim/releases/latest) printf 'https://github.com/neovim/neovim/releases/tag/%s' "$(cat "$DOTFILES_TEST_FIXTURE/latest")" ;;
            https://github.com/neovim/neovim/releases/download/*)
                [ ! -f "$DOTFILES_TEST_FIXTURE/offline" ] || return 56
                release="${url#https://github.com/neovim/neovim/releases/download/}"
                cp "$DOTFILES_TEST_FIXTURE/asset-${release%%/*}.tar.gz" "$output"
                ;;
            *) echo "unexpected URL $url" >&2; return 99 ;;
        esac
    }
    export DOTFILES_UPDATE=1
    # A new enough Neovim from another source is not the bootstrap's to replace.
    printf 'NVIM v0.12.3\n' > "$test_dir/nvim-on-path"
    install_neovim_release > "$test_dir/output"
    assert_contains "$(cat "$test_dir/output")" 'Neovim 0.12.3 was not installed by the bootstrap; left alone'
    [ ! -f "$test_dir/requests" ]
    # One that is too old is replaced as on a first install, and the tag recorded.
    printf 'NVIM v0.9.5\n' > "$test_dir/nvim-on-path"
    install_neovim_release > "$test_dir/output"
    assert_equal 'NVIM v0.12.6' "$("$test_dir/bin/nvim")"
    assert_equal v0.12.6 "$(cat "$record")"
    # Current: one lookup, no download.
    : > "$test_dir/requests"
    install_neovim_release > "$test_dir/output"
    assert_equal 'https://github.com/neovim/neovim/releases/latest' "$(cat "$test_dir/requests")"
    assert_contains "$(cat "$test_dir/output")" 'Neovim v0.12.6 is current'
    # A newer release that fails to download keeps the installed tree and record.
    printf 'v0.12.7\n' > "$test_dir/latest"
    : > "$test_dir/offline"
    local status=0
    install_neovim_release > "$test_dir/output" 2>&1 || status=$?
    assert_equal 56 "$status"
    assert_equal 'NVIM v0.12.6' "$("$test_dir/bin/nvim")"
    assert_equal v0.12.6 "$(cat "$record")"
    rm "$test_dir/offline"
    install_neovim_release > "$test_dir/output"
    assert_contains "$(cat "$test_dir/output")" 'Updating Neovim 0.12.6 to v0.12.7'
    assert_equal 'NVIM v0.12.7' "$("$test_dir/bin/nvim")"
    assert_equal v0.12.7 "$(cat "$record")"
    [ ! -e "$test_dir/opt/nvim.new" ]
    # A tree installed before tags were recorded is fetched once.
    rm "$record"
    install_neovim_release > "$test_dir/output"
    assert_equal v0.12.7 "$(cat "$record")"
    # A release that does not start here never replaces the one that does.
    printf 'v0.12.8\n' > "$test_dir/latest"
    status=0
    install_neovim_release > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'Neovim from v0.12.8 nvim-linux-x86_64.tar.gz does not run here:'
    assert_contains "$(cat "$test_dir/output")" 'GLIBC_2.41 not found'
    assert_equal 'NVIM v0.12.7' "$("$test_dir/bin/nvim")"
    assert_equal v0.12.7 "$(cat "$record")"
    printf 'v0.12.7\n' > "$test_dir/latest"
    # Without updating, an installed Neovim is kept whatever the latest release.
    unset DOTFILES_UPDATE
    : > "$test_dir/requests"
    install_neovim_release > "$test_dir/output"
    assert_equal '' "$(cat "$test_dir/requests")"
}

test_neovim_plugins_install_and_retry() {
    source "$TEST_REPO_DIR/scripts/bootstrap_tools.sh"
    export DOTFILES_TEST_FIXTURE="$test_dir"
    mkdir -p "$test_dir/node/bin"
    printf 'NVIM v0.12.6\n' > "$test_dir/version"
    # The report names what is missing; plugins() and install() each need their
    # own retry file to succeed and record what they fixed.
    nvim() {
        printf '%s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/nvim-args"
        case "$*" in
            --version) cat "$DOTFILES_TEST_FIXTURE/version" ;;
            *'bootstrap").check()'*)
                case "$*" in *' -c cquit 1') ;; *) echo 'the check must be followed by cquit' >&2; return 99 ;; esac
                echo 'ok plugin fzf-lua'
                [ -f "$DOTFILES_TEST_FIXTURE/plugins-installed" ] || echo 'missing plugin catppuccin'
                [ -f "$DOTFILES_TEST_FIXTURE/tools-installed" ] || echo 'missing package marksman'
                [ -f "$DOTFILES_TEST_FIXTURE/plugins-installed" ] && [ -f "$DOTFILES_TEST_FIXTURE/tools-installed" ] && [ ! -f "$DOTFILES_TEST_FIXTURE/stay-broken" ]
                ;;
            *'bootstrap").plugins()'*)
                case "$*" in *' -c cquit 1') ;; *) return 99 ;; esac
                [ -f "$DOTFILES_TEST_FIXTURE/plugins-ok" ] || { echo 'missing plugin catppuccin'; return 1; }
                : > "$DOTFILES_TEST_FIXTURE/plugins-installed"
                ;;
            *'bootstrap").install()'*)
                case "$*" in *' -c cquit 1') ;; *) return 99 ;; esac
                printf '%s\n' "$PATH" > "$DOTFILES_TEST_FIXTURE/install-path"
                [ -f "$DOTFILES_TEST_FIXTURE/install-ok" ] || { echo 'missing package marksman'; return 1; }
                : > "$DOTFILES_TEST_FIXTURE/tools-installed"
                ;;
            *'bootstrap").update()'*)
                case "$*" in *' -c cquit 1') ;; *) return 99 ;; esac
                printf '%s\n' "$PATH" > "$DOTFILES_TEST_FIXTURE/update-path"
                [ -f "$DOTFILES_TEST_FIXTURE/update-ok" ] || { echo 'failed package marksman'; return 1; }
                ;;
        esac
    }
    mise() { [ "$1 $2" = 'which node' ] && [ -f "$DOTFILES_TEST_FIXTURE/node-present" ] && printf '%s/node/bin/node\n' "$DOTFILES_TEST_FIXTURE"; }
    local check='--headless -c lua require("dotfiles.bootstrap").check() -c cquit 1'
    local plugins='--headless -c lua require("dotfiles.bootstrap").plugins() -c cquit 1'
    local install='--headless -c lua require("dotfiles.bootstrap").install() -c cquit 1'
    local update='--headless -c lua require("dotfiles.bootstrap").update() -c cquit 1'
    local status=0
    bootstrap_neovim > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_equal "$(printf '%s\n' --version "$check" "$plugins")" "$(cat "$test_dir/nvim-args")"
    assert_contains "$(cat "$test_dir/output")" 'missing plugin catppuccin'
    [ ! -f "$test_dir/plugins-installed" ]
    # The retry installs the plugins; the parsers and servers fail and are retried in turn.
    : > "$test_dir/plugins-ok"
    : > "$test_dir/nvim-args"
    status=0
    bootstrap_neovim > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    [ -f "$test_dir/plugins-installed" ]
    assert_equal "$(printf '%s\n' --version "$check" "$plugins" "$install")" "$(cat "$test_dir/nvim-args")"
    assert_contains "$(cat "$test_dir/output")" 'missing package marksman'
    # Without mise's Node.js the install runs with the current PATH; with it, that directory comes first.
    assert_equal "$PATH" "$(cat "$test_dir/install-path")"
    : > "$test_dir/install-ok"
    : > "$test_dir/node-present"
    : > "$test_dir/nvim-args"
    bootstrap_neovim > "$test_dir/output"
    # Only what the report names is installed: the plugins were already in place.
    assert_equal "$(printf '%s\n' --version "$check" "$install" "$check")" "$(cat "$test_dir/nvim-args")"
    assert_equal "$test_dir/node/bin:$PATH" "$(cat "$test_dir/install-path")"
    [ -f "$test_dir/tools-installed" ]
    # Everything installed: one offline check and nothing else.
    : > "$test_dir/nvim-args"
    bootstrap_neovim > "$test_dir/output"
    assert_equal "$(printf '%s\n' --version "$check")" "$(cat "$test_dir/nvim-args")"
    assert_contains "$(cat "$test_dir/output")" 'already installed'
    # A stale plugin alone runs the plugin step alone, then the report confirms.
    rm "$test_dir/plugins-installed"
    : > "$test_dir/nvim-args"
    bootstrap_neovim > "$test_dir/output"
    assert_equal "$(printf '%s\n' --version "$check" "$plugins" "$check")" "$(cat "$test_dir/nvim-args")"
    # Updating, the plugins stay pinned and update() refreshes the parsers and
    # language servers with mise's Node.js first on PATH; a failure can be retried.
    export DOTFILES_UPDATE=1
    : > "$test_dir/nvim-args"
    status=0
    bootstrap_neovim > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_equal "$(printf '%s\n' --version "$check" "$update")" "$(cat "$test_dir/nvim-args")"
    assert_contains "$(cat "$test_dir/output")" 'failed package marksman'
    : > "$test_dir/update-ok"
    bootstrap_neovim > "$test_dir/output"
    assert_equal "$test_dir/node/bin:$PATH" "$(cat "$test_dir/update-path")"
    unset DOTFILES_UPDATE
    # A report that still finds gaps after the installs is a failure, with the report shown.
    rm "$test_dir/tools-installed"
    : > "$test_dir/stay-broken"
    status=0
    bootstrap_neovim > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'not fully set up'
    assert_contains "$(cat "$test_dir/output")" 'ok plugin fzf-lua'
    rm "$test_dir/stay-broken"
    # An old or absent Neovim stops before anything runs.
    printf 'NVIM v0.11.6\n' > "$test_dir/version"
    status=0
    bootstrap_neovim > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" '0.11.6 is older than'
    unset -f nvim
    command() {
        if [ "$*" = '-v nvim' ]; then return 1; fi
        builtin command "$@"
    }
    status=0
    bootstrap_neovim > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'Neovim is not installed'
}

test_tree_sitter_cli_install() {
    source "$TEST_REPO_DIR/scripts/bootstrap_tools.sh"
    trust_release_downloads
    export DOTFILES_TEST_FIXTURE="$test_dir"
    export DOTFILES_LOCAL_BIN="$test_dir/bin"
    export TMPDIR="$test_dir/tmp"
    mkdir -p "$TMPDIR" "$test_dir/payload" "$test_dir/old-payload"
    printf '#!/bin/sh\necho "tree-sitter 0.27.1"\n' > "$test_dir/payload/tree-sitter"
    printf '#!/bin/sh\necho "tree-sitter 0.25.9"\n' > "$test_dir/old-payload/tree-sitter"
    chmod +x "$test_dir/payload/tree-sitter" "$test_dir/old-payload/tree-sitter"
    (cd "$test_dir/payload" && zip -q "$test_dir/asset.zip" tree-sitter)
    (cd "$test_dir/old-payload" && zip -q "$test_dir/old-asset.zip" tree-sitter)
    printf 'asset.zip\n' > "$test_dir/serve"
    tree-sitter() {
        if [ -f "$DOTFILES_TEST_FIXTURE/cli-on-path" ]; then
            if [ -f "$DOTFILES_TEST_FIXTURE/cli-warns" ]; then
                echo "tree-sitter: /lib/x86_64-linux-gnu/libc.so.6: weak version \`GLIBC_2.39' not found (required by tree-sitter)" >&2
            fi
            cat "$DOTFILES_TEST_FIXTURE/cli-on-path"
            return 0
        fi
        return 127
    }
    uname() { if [ "${1:-}" = -m ]; then printf 'x86_64\n'; else command uname "$@"; fi; }
    curl() {
        local output="" url=""
        printf '%s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/commands"
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -o|-w) output="$2"; shift ;;
                -*) ;;
                *) url="$1" ;;
            esac
            shift
        done
        case "$url" in
            https://github.com/tree-sitter/tree-sitter/releases/latest) printf 'https://github.com/tree-sitter/tree-sitter/releases/tag/v0.27.1' ;;
            https://github.com/tree-sitter/tree-sitter/releases/download/v0.27.1/*)
                printf '%s\n' "$url" >> "$DOTFILES_TEST_FIXTURE/downloads"
                cp "$DOTFILES_TEST_FIXTURE/$(cat "$DOTFILES_TEST_FIXTURE/serve")" "$output"
                ;;
            *) echo "unexpected URL $url" >&2; return 99 ;;
        esac
    }
    # A CLI that is new enough needs nothing; an old distribution package is not good enough.
    printf 'tree-sitter 0.26.1\n' > "$test_dir/cli-on-path"
    install_tree_sitter_cli > "$test_dir/output"
    assert_contains "$(cat "$test_dir/output")" 'tree-sitter 0.26.1 already installed'
    [ ! -f "$test_dir/commands" ]
    printf 'tree-sitter 0.22.6\n' > "$test_dir/cli-on-path"
    install_tree_sitter_cli > "$test_dir/output"
    assert_contains "$(cat "$test_dir/output")" 'found 0.22.6, need 0.26.1'
    assert_equal 'https://github.com/tree-sitter/tree-sitter/releases/download/v0.27.1/tree-sitter-cli-linux-x64.zip' "$(cat "$test_dir/downloads")"
    assert_equal 'tree-sitter/tree-sitter v0.27.1 tree-sitter-cli-linux-x64.zip' "$(cat "$test_dir/verified")"
    assert_equal 'tree-sitter 0.27.1' "$("$test_dir/bin/tree-sitter" --version)"
    # No CLI at all is installed too; a release that is still too old is
    # refused and never replaces the installed one.
    rm "$test_dir/cli-on-path" "$test_dir/bin/tree-sitter"
    install_tree_sitter_cli > "$test_dir/output"
    [ -x "$test_dir/bin/tree-sitter" ]
    printf 'old-asset.zip\n' > "$test_dir/serve"
    local status=0
    install_tree_sitter_cli > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" '(0.25.9) is older than 0.26.1'
    assert_equal 0.27.1 "$(dotfiles_tree_sitter_version "$test_dir/bin/tree-sitter")"
    assert_equal 0 "$(find "$TMPDIR" -maxdepth 1 -name 'dotfiles-tree-sitter.*' | wc -l | tr -d ' ')"
    printf '#!/bin/sh\necho "not a cli"\n' > "$test_dir/bin/tree-sitter"
    if dotfiles_tree_sitter_version "$test_dir/bin/tree-sitter"; then
        echo "A version was read from unrelated output." >&2
        return 1
    fi
    # A release that fails for want of a newer glibc is removed and recorded,
    # so Neovim skips the parsers and a rerun fetches nothing; any other
    # failure stands and shows why.
    export XDG_STATE_HOME="$test_dir/state"
    local record="$test_dir/state/dotfiles/tree-sitter-unsupported"
    mkdir -p "$test_dir/glibc-payload" "$test_dir/crash-payload"
    printf '#!/bin/sh\necho "tree-sitter: /lib/aarch64-linux-gnu/libc.so.6: version \\`GLIBC_2.39'"'"' not found" >&2\nexit 1\n' > "$test_dir/glibc-payload/tree-sitter"
    printf '#!/bin/sh\necho "Segmentation fault" >&2\nexit 139\n' > "$test_dir/crash-payload/tree-sitter"
    chmod +x "$test_dir/glibc-payload/tree-sitter" "$test_dir/crash-payload/tree-sitter"
    (cd "$test_dir/glibc-payload" && zip -q "$test_dir/glibc-asset.zip" tree-sitter)
    (cd "$test_dir/crash-payload" && zip -q "$test_dir/crash-asset.zip" tree-sitter)
    getconf() { [ "$1" = GNU_LIBC_VERSION ] && [ -f "$DOTFILES_TEST_FIXTURE/glibc" ] && cat "$DOTFILES_TEST_FIXTURE/glibc"; }
    printf 'glibc 2.36\n' > "$test_dir/glibc"
    rm -f "$test_dir/bin/tree-sitter" "$test_dir/downloads"
    printf 'glibc-asset.zip\n' > "$test_dir/serve"
    install_tree_sitter_cli > "$test_dir/output"
    assert_contains "$(cat "$test_dir/output")" 'tree-sitter v0.27.1 needs glibc 2.39 and this system has 2.36'
    [ ! -e "$test_dir/bin/tree-sitter" ]
    assert_equal 'v0.27.1 2.36' "$(cat "$record")"
    # A rerun then looks up the latest tag and asks the API nothing more.
    rm -f "$test_dir/aged"
    install_tree_sitter_cli > "$test_dir/output"
    assert_contains "$(cat "$test_dir/output")" 'Neovim keeps skipping the parsers'
    assert_equal 1 "$(wc -l < "$test_dir/downloads" | tr -d ' ')"
    [ ! -e "$test_dir/aged" ]
    # A record from another release or another glibc is fetched again.
    printf 'v0.27.0 2.36\n' > "$record"
    install_tree_sitter_cli > "$test_dir/output"
    assert_equal 2 "$(wc -l < "$test_dir/downloads" | tr -d ' ')"
    assert_equal 'v0.27.1 2.36' "$(cat "$record")"
    # One that starts but warns about a weak glibc symbol is left out as well:
    # with it, parser installs hung on Debian 12. So is such a CLI on PATH.
    mkdir -p "$test_dir/weak-payload"
    printf '#!/bin/sh\necho "tree-sitter: libc.so.6: weak version \\`GLIBC_2.39'"'"' not found" >&2\necho "tree-sitter 0.27.1"\n' > "$test_dir/weak-payload/tree-sitter"
    chmod +x "$test_dir/weak-payload/tree-sitter"
    (cd "$test_dir/weak-payload" && zip -q "$test_dir/weak-asset.zip" tree-sitter)
    printf 'weak-asset.zip\n' > "$test_dir/serve"
    rm "$record"
    printf 'tree-sitter 0.27.1\n' > "$test_dir/cli-on-path"
    : > "$test_dir/cli-warns"
    install_tree_sitter_cli > "$test_dir/output"
    assert_contains "$(cat "$test_dir/output")" 'tree-sitter v0.27.1 needs glibc 2.39 and this system has 2.36'
    [ ! -e "$test_dir/bin/tree-sitter" ]
    assert_equal 'v0.27.1 2.36' "$(cat "$record")"
    assert_equal 3 "$(wc -l < "$test_dir/downloads" | tr -d ' ')"
    rm "$test_dir/cli-on-path" "$test_dir/cli-warns"
    # A copy in the bin directory with the same complaint goes as well.
    cp "$test_dir/weak-payload/tree-sitter" "$test_dir/bin/tree-sitter"
    rm "$record"
    install_tree_sitter_cli > "$test_dir/output"
    [ ! -e "$test_dir/bin/tree-sitter" ]
    assert_equal 'v0.27.1 2.36' "$(cat "$record")"
    # A crash is no glibc mismatch, whatever the glibc.
    printf 'crash-asset.zip\n' > "$test_dir/serve"
    rm "$record"
    status=0
    install_tree_sitter_cli > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'does not report a version after installing:'
    assert_contains "$(cat "$test_dir/output")" 'Segmentation fault'
    [ ! -e "$record" ]
    [ ! -e "$test_dir/bin/tree-sitter" ]
    # A release that runs clears the record.
    printf 'v0.27.0 2.36\n' > "$record"
    printf 'asset.zip\n' > "$test_dir/serve"
    install_tree_sitter_cli > "$test_dir/output"
    [ -x "$test_dir/bin/tree-sitter" ]
    [ ! -e "$record" ]
    assert_equal 2.36 "$(dotfiles_glibc_version)"
    printf 'NPTL 2.36\n' > "$test_dir/glibc"
    if dotfiles_glibc_version; then
        echo "A glibc version was read from unrelated output." >&2
        return 1
    fi
}

# Updating replaces the bootstrap's tree-sitter CLI when the latest tag
# differs from the recorded one, but only with a release that runs here: a
# newer one that wants a newer glibc is recorded and the working CLI stays.
test_tree_sitter_cli_update() {
    source "$TEST_REPO_DIR/scripts/bootstrap_tools.sh"
    trust_release_downloads
    export DOTFILES_TEST_FIXTURE="$test_dir"
    export DOTFILES_LOCAL_BIN="$test_dir/bin"
    export TMPDIR="$test_dir/tmp"
    local record="$XDG_STATE_HOME/dotfiles/releases/tree-sitter/tree-sitter"
    local unsupported="$XDG_STATE_HOME/dotfiles/tree-sitter-unsupported" tag
    mkdir -p "$TMPDIR" "$test_dir/bin"
    for tag in v0.27.1 v0.27.2; do
        mkdir -p "$test_dir/payload-$tag"
        printf '#!/bin/sh\necho "tree-sitter %s"\n' "${tag#v}" > "$test_dir/payload-$tag/tree-sitter"
    done
    mkdir -p "$test_dir/payload-v0.28.0"
    printf '#!/bin/sh\necho "tree-sitter: libc.so.6: version \\`GLIBC_2.41'"'"' not found" >&2\nexit 1\n' > "$test_dir/payload-v0.28.0/tree-sitter"
    for tag in v0.27.1 v0.27.2 v0.28.0; do
        chmod +x "$test_dir/payload-$tag/tree-sitter"
        (cd "$test_dir/payload-$tag" && zip -q "$test_dir/asset-$tag.zip" tree-sitter)
    done
    cp "$test_dir/payload-v0.27.1/tree-sitter" "$test_dir/bin/tree-sitter"
    PATH="$test_dir/bin:$PATH"
    printf 'v0.27.1\n' > "$test_dir/latest"
    getconf() { [ "$1" = GNU_LIBC_VERSION ] && printf 'glibc 2.39\n'; }
    uname() { if [ "${1:-}" = -m ]; then printf 'x86_64\n'; else command uname "$@"; fi; }
    curl() {
        local output="" url="" release
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -o|-w) output="$2"; shift ;;
                -*) ;;
                *) url="$1" ;;
            esac
            shift
        done
        printf '%s\n' "$url" >> "$DOTFILES_TEST_FIXTURE/requests"
        case "$url" in
            https://github.com/tree-sitter/tree-sitter/releases/latest) printf 'https://github.com/tree-sitter/tree-sitter/releases/tag/%s' "$(cat "$DOTFILES_TEST_FIXTURE/latest")" ;;
            https://github.com/tree-sitter/tree-sitter/releases/download/*)
                [ ! -f "$DOTFILES_TEST_FIXTURE/offline" ] || return 56
                release="${url#https://github.com/tree-sitter/tree-sitter/releases/download/}"
                cp "$DOTFILES_TEST_FIXTURE/asset-${release%%/*}.zip" "$output"
                ;;
            *) echo "unexpected URL $url" >&2; return 99 ;;
        esac
    }
    export DOTFILES_UPDATE=1
    # A copy without a record (installed before records existed) is fetched once.
    install_tree_sitter_cli > "$test_dir/output"
    assert_equal v0.27.1 "$(cat "$record")"
    # Current: one lookup and no download.
    : > "$test_dir/requests"
    install_tree_sitter_cli > "$test_dir/output"
    assert_equal 'https://github.com/tree-sitter/tree-sitter/releases/latest' "$(cat "$test_dir/requests")"
    assert_contains "$(cat "$test_dir/output")" 'tree-sitter v0.27.1 is current'
    # A newer release: a failed download keeps the CLI and record, the retry replaces it.
    printf 'v0.27.2\n' > "$test_dir/latest"
    : > "$test_dir/offline"
    local status=0
    install_tree_sitter_cli > "$test_dir/output" 2>&1 || status=$?
    assert_equal 56 "$status"
    assert_equal 'tree-sitter 0.27.1' "$(tree-sitter --version)"
    assert_equal v0.27.1 "$(cat "$record")"
    rm "$test_dir/offline"
    install_tree_sitter_cli > "$test_dir/output"
    assert_contains "$(cat "$test_dir/output")" 'Updating tree-sitter 0.27.1 to v0.27.2'
    assert_equal 'tree-sitter 0.27.2' "$(tree-sitter --version)"
    assert_equal v0.27.2 "$(cat "$record")"
    # A release that wants a newer glibc is recorded; the working CLI stays and
    # later updates do not fetch it again.
    printf 'v0.28.0\n' > "$test_dir/latest"
    : > "$test_dir/requests"
    install_tree_sitter_cli > "$test_dir/output"
    assert_contains "$(cat "$test_dir/output")" 'tree-sitter v0.28.0 needs glibc 2.41 and this system has 2.39; keeping tree-sitter 0.27.2'
    assert_equal 'tree-sitter 0.27.2' "$(tree-sitter --version)"
    assert_equal 'v0.28.0 2.39' "$(cat "$unsupported")"
    assert_equal v0.27.2 "$(cat "$record")"
    : > "$test_dir/requests"
    install_tree_sitter_cli > "$test_dir/output"
    assert_contains "$(cat "$test_dir/output")" 'tree-sitter v0.28.0 does not run on glibc 2.39; keeping 0.27.2'
    assert_equal 'https://github.com/tree-sitter/tree-sitter/releases/latest' "$(cat "$test_dir/requests")"
    # A CLI from elsewhere is not the bootstrap's to replace.
    mkdir -p "$test_dir/elsewhere"
    mv "$test_dir/bin/tree-sitter" "$test_dir/elsewhere/tree-sitter"
    PATH="$test_dir/elsewhere:$PATH"
    : > "$test_dir/requests"
    install_tree_sitter_cli > "$test_dir/output"
    assert_contains "$(cat "$test_dir/output")" 'tree-sitter 0.27.2 was not installed by the bootstrap; left alone'
    assert_equal '' "$(cat "$test_dir/requests")"
}

test_linux_font_install() {
    source "$TEST_REPO_DIR/scripts/bootstrap_tools.sh"
    trust_release_downloads
    export DOTFILES_TEST_FIXTURE="$test_dir"
    export XDG_DATA_HOME="$test_dir/data"
    export TMPDIR="$test_dir/tmp"
    local name font_dir="$test_dir/data/fonts/CaskaydiaCove"
    mkdir -p "$TMPDIR" "$test_dir/payload" "$test_dir/bad-payload"
    for name in CaskaydiaCoveNerdFontMono-Regular CaskaydiaCoveNerdFontMono-Bold \
        CaskaydiaCoveNerdFont-Regular CaskaydiaCoveNerdFontPropo-Regular; do
        printf 'font\n' > "$test_dir/payload/$name.ttf"
    done
    printf 'license\n' > "$test_dir/payload/LICENSE"
    cp "$test_dir/payload/CaskaydiaCoveNerdFont-Regular.ttf" "$test_dir/bad-payload/"
    tar -cJf "$test_dir/asset.tar.xz" -C "$test_dir/payload" .
    tar -cJf "$test_dir/bad-asset.tar.xz" -C "$test_dir/bad-payload" .
    printf 'asset.tar.xz\n' > "$test_dir/serve"
    uname() { if [ "${1:-}" = -r ]; then cat "$DOTFILES_TEST_FIXTURE/kernel"; else command uname "$@"; fi; }
    command() {
        case "$*" in
            '-v fc-cache') [ -f "$DOTFILES_TEST_FIXTURE/fontconfig" ] ;;
            *) builtin command "$@" ;;
        esac
    }
    # fontconfig lists the family once fc-cache has scanned a directory holding it.
    fc-cache() {
        printf 'fc-cache %s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/commands"
        if [ ! -f "$DOTFILES_TEST_FIXTURE/cache-broken" ] && compgen -G "$2/CaskaydiaCoveNerdFontMono-*.ttf" >/dev/null; then
            : > "$DOTFILES_TEST_FIXTURE/registered"
        fi
    }
    fc-list() { [ "$1" = -q ] && [ "$2" = 'CaskaydiaCove Nerd Font Mono' ] && [ -f "$DOTFILES_TEST_FIXTURE/registered" ]; }
    curl() {
        local output="" url=""
        printf 'curl %s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/commands"
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -o|-w) output="$2"; shift ;;
                -*) ;;
                *) url="$1" ;;
            esac
            shift
        done
        case "$url" in
            https://github.com/ryanoasis/nerd-fonts/releases/latest) printf 'https://github.com/ryanoasis/nerd-fonts/releases/tag/v3.4.0' ;;
            https://github.com/ryanoasis/nerd-fonts/releases/download/v3.4.0/*)
                [ -f "$DOTFILES_TEST_FIXTURE/retry" ] || return 56
                printf '%s\n' "$url" >> "$DOTFILES_TEST_FIXTURE/downloads"
                cp "$DOTFILES_TEST_FIXTURE/$(cat "$DOTFILES_TEST_FIXTURE/serve")" "$output"
                ;;
            *) echo "unexpected URL $url" >&2; return 99 ;;
        esac
    }
    # WSL draws its text with the Windows font: nothing is checked or fetched.
    printf '6.6.87.2-microsoft-standard-WSL2\n' > "$test_dir/kernel"
    install_nerd_font > "$test_dir/output"
    assert_contains "$(cat "$test_dir/output")" 'WSL uses the Windows font'
    [ ! -f "$test_dir/commands" ]
    printf '4.4.0-19041-Microsoft\n' > "$test_dir/kernel"
    dotfiles_is_wsl
    printf '6.1.0-25-amd64\n' > "$test_dir/kernel"
    if dotfiles_is_wsl; then
        echo "A Debian kernel was taken for WSL." >&2
        return 1
    fi
    # fontconfig comes from the package list.
    local status=0
    install_nerd_font > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'fontconfig is not installed'
    : > "$test_dir/fontconfig"
    # A family fontconfig already lists, from any directory, needs nothing.
    : > "$test_dir/registered"
    install_nerd_font > "$test_dir/output"
    assert_contains "$(cat "$test_dir/output")" 'CaskaydiaCove Nerd Font Mono already installed'
    [ ! -f "$test_dir/commands" ]
    rm "$test_dir/registered"
    # A directory the bootstrap did not create is the user's and stays.
    mkdir -p "$font_dir"
    printf 'mine\n' > "$font_dir/MyFont.ttf"
    status=0
    install_nerd_font > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'exists and the bootstrap did not install it'
    assert_equal mine "$(cat "$font_dir/MyFont.ttf")"
    [ ! -f "$test_dir/commands" ]
    rm -r "$font_dir"
    # A failed download leaves nothing behind, and a copy cut short earlier,
    # hidden from fontconfig, is cleared; the retry installs the Mono family alone.
    mkdir -p "$test_dir/data/fonts/.CaskaydiaCove.new"
    printf 'partial\n' > "$test_dir/data/fonts/.CaskaydiaCove.new/CaskaydiaCoveNerdFontMono-Regular.ttf"
    status=0
    install_nerd_font > "$test_dir/output" 2>&1 || status=$?
    assert_equal 56 "$status"
    [ ! -e "$font_dir" ]
    [ ! -e "$test_dir/data/fonts/.CaskaydiaCove.new" ]
    assert_equal 0 "$(find "$TMPDIR" -maxdepth 1 -name 'dotfiles-font.*' | wc -l | tr -d ' ')"
    : > "$test_dir/retry"
    install_nerd_font > "$test_dir/output"
    assert_equal 'https://github.com/ryanoasis/nerd-fonts/releases/download/v3.4.0/CascadiaCode.tar.xz' "$(cat "$test_dir/downloads")"
    assert_equal 'ryanoasis/nerd-fonts v3.4.0 CascadiaCode.tar.xz' "$(tail -n 1 "$test_dir/verified")"
    assert_equal 'CaskaydiaCoveNerdFontMono-Bold.ttf CaskaydiaCoveNerdFontMono-Regular.ttf' "$(cd "$font_dir" && echo *)"
    [ -f "$font_dir/.installed-by-dotfiles" ]
    assert_equal "fc-cache -f $font_dir" "$(tail -n 1 "$test_dir/commands")"
    [ ! -e "$test_dir/data/fonts/.CaskaydiaCove.new" ]
    assert_equal 0 "$(find "$TMPDIR" -maxdepth 1 -name 'dotfiles-font.*' | wc -l | tr -d ' ')"
    : > "$test_dir/commands"
    install_nerd_font > "$test_dir/output"
    assert_equal '' "$(cat "$test_dir/commands")"
    # An archive without the Mono family is refused and the installed fonts stay.
    rm "$test_dir/registered"
    printf 'bad-asset.tar.xz\n' > "$test_dir/serve"
    status=0
    install_nerd_font > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'does not contain the CaskaydiaCove Nerd Font Mono files'
    [ -f "$font_dir/CaskaydiaCoveNerdFontMono-Regular.ttf" ]
    # A family fontconfig does not list after the swap is an error, and the
    # previous directory comes back; once it works the directory is replaced whole.
    printf 'asset.tar.xz\n' > "$test_dir/serve"
    printf 'stale\n' > "$font_dir/stale.ttf"
    : > "$test_dir/cache-broken"
    status=0
    install_nerd_font > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'fontconfig does not list CaskaydiaCove Nerd Font Mono after installing CascadiaCode.tar.xz; the previous fonts are back.'
    [ -f "$font_dir/stale.ttf" ]
    [ -f "$font_dir/.installed-by-dotfiles" ]
    [ ! -e "$test_dir/data/fonts/.CaskaydiaCove.old" ]
    rm "$test_dir/cache-broken"
    install_nerd_font > "$test_dir/output"
    [ ! -e "$font_dir/stale.ttf" ]
    [ -f "$font_dir/CaskaydiaCoveNerdFontMono-Bold.ttf" ]
    [ ! -e "$test_dir/data/fonts/.CaskaydiaCove.old" ]
    # A previous directory an interrupted run left aside is put back.
    mv "$font_dir" "$test_dir/data/fonts/.CaskaydiaCove.old"
    install_nerd_font > "$test_dir/output"
    assert_contains "$(cat "$test_dir/output")" 'already installed'
    [ -f "$font_dir/CaskaydiaCoveNerdFontMono-Bold.ttf" ]
    [ ! -e "$test_dir/data/fonts/.CaskaydiaCove.old" ]
}

# Updating replaces the bootstrap's font directory (the one with its marker)
# when Nerd Fonts has a newer tag, and leaves a family installed by other
# means alone.
test_linux_font_update() {
    source "$TEST_REPO_DIR/scripts/bootstrap_tools.sh"
    trust_release_downloads
    export DOTFILES_TEST_FIXTURE="$test_dir"
    export XDG_DATA_HOME="$test_dir/data"
    export TMPDIR="$test_dir/tmp"
    local font_dir="$test_dir/data/fonts/CaskaydiaCove" record="$XDG_STATE_HOME/dotfiles/releases/ryanoasis/nerd-fonts" tag
    mkdir -p "$TMPDIR"
    for tag in v3.4.0 v3.5.0; do
        mkdir -p "$test_dir/payload-$tag"
        printf '%s\n' "$tag" > "$test_dir/payload-$tag/CaskaydiaCoveNerdFontMono-Regular.ttf"
        tar -cJf "$test_dir/asset-$tag.tar.xz" -C "$test_dir/payload-$tag" .
    done
    printf 'v3.4.0\n' > "$test_dir/latest"
    uname() { if [ "${1:-}" = -r ]; then printf '6.1.0-25-amd64\n'; else command uname "$@"; fi; }
    fc-cache() { : > "$DOTFILES_TEST_FIXTURE/registered"; }
    fc-list() { [ -f "$DOTFILES_TEST_FIXTURE/registered" ]; }
    curl() {
        local output="" url="" release
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -o|-w) output="$2"; shift ;;
                -*) ;;
                *) url="$1" ;;
            esac
            shift
        done
        printf '%s\n' "$url" >> "$DOTFILES_TEST_FIXTURE/requests"
        case "$url" in
            https://github.com/ryanoasis/nerd-fonts/releases/latest) printf 'https://github.com/ryanoasis/nerd-fonts/releases/tag/%s' "$(cat "$DOTFILES_TEST_FIXTURE/latest")" ;;
            https://github.com/ryanoasis/nerd-fonts/releases/download/*)
                [ ! -f "$DOTFILES_TEST_FIXTURE/offline" ] || return 56
                release="${url#https://github.com/ryanoasis/nerd-fonts/releases/download/}"
                cp "$DOTFILES_TEST_FIXTURE/asset-${release%%/*}.tar.xz" "$output"
                ;;
            *) echo "unexpected URL $url" >&2; return 99 ;;
        esac
    }
    # The family from elsewhere: left alone, nothing fetched.
    : > "$test_dir/registered"
    export DOTFILES_UPDATE=1
    install_nerd_font > "$test_dir/output"
    assert_contains "$(cat "$test_dir/output")" 'CaskaydiaCove Nerd Font Mono was not installed by the bootstrap; left alone'
    [ ! -f "$test_dir/requests" ]
    rm "$test_dir/registered"
    # Missing: installed as on a first run, with the tag recorded.
    install_nerd_font > "$test_dir/output"
    assert_equal v3.4.0 "$(cat "$font_dir/CaskaydiaCoveNerdFontMono-Regular.ttf")"
    assert_equal v3.4.0 "$(cat "$record")"
    # Current: one lookup and no download.
    : > "$test_dir/requests"
    install_nerd_font > "$test_dir/output"
    assert_equal 'https://github.com/ryanoasis/nerd-fonts/releases/latest' "$(cat "$test_dir/requests")"
    assert_contains "$(cat "$test_dir/output")" 'CaskaydiaCove Nerd Font Mono v3.4.0 is current'
    # Newer: a failed download keeps the fonts and record; the retry replaces them.
    printf 'v3.5.0\n' > "$test_dir/latest"
    : > "$test_dir/offline"
    local status=0
    install_nerd_font > "$test_dir/output" 2>&1 || status=$?
    assert_equal 56 "$status"
    assert_equal v3.4.0 "$(cat "$font_dir/CaskaydiaCoveNerdFontMono-Regular.ttf")"
    assert_equal v3.4.0 "$(cat "$record")"
    rm "$test_dir/offline"
    install_nerd_font > "$test_dir/output"
    assert_contains "$(cat "$test_dir/output")" 'Updating CaskaydiaCove Nerd Font Mono to v3.5.0'
    assert_equal v3.5.0 "$(cat "$font_dir/CaskaydiaCoveNerdFontMono-Regular.ttf")"
    [ -f "$font_dir/.installed-by-dotfiles" ]
    [ ! -e "$test_dir/data/fonts/.CaskaydiaCove.new" ]
    assert_equal v3.5.0 "$(cat "$record")"
    # Without updating, the installed fonts are kept.
    unset DOTFILES_UPDATE
    : > "$test_dir/requests"
    install_nerd_font > "$test_dir/output"
    assert_equal '' "$(cat "$test_dir/requests")"
}

test_doctor_linux_font() {
    source "$TEST_REPO_DIR/scripts/doctor.sh"
    export DOTFILES_TEST_FIXTURE="$test_dir"
    uname() { if [ "${1:-}" = -r ]; then cat "$DOTFILES_TEST_FIXTURE/kernel"; else command uname "$@"; fi; }
    fc-list() { [ "$1" = -q ] && [ "$2" = 'CaskaydiaCove Nerd Font Mono' ] && [ -f "$DOTFILES_TEST_FIXTURE/registered" ]; }
    printf '6.1.0-25-amd64\n' > "$test_dir/kernel"
    failures=0
    check_linux_font > "$test_dir/output"
    assert_equal 1 "$failures"
    assert_contains "$(cat "$test_dir/output")" '[missing] CaskaydiaCove Nerd Font Mono (rerun: bash scripts/bootstrap_tools.sh)'
    : > "$test_dir/registered"
    failures=0
    check_linux_font > "$test_dir/output"
    assert_equal 0 "$failures"
    assert_contains "$(cat "$test_dir/output")" '[ok] CaskaydiaCove Nerd Font Mono'
    # WSL draws with the Windows font, so no Linux copy is needed.
    rm "$test_dir/registered"
    printf '5.15.153.1-microsoft-standard-WSL2\n' > "$test_dir/kernel"
    check_linux_font > "$test_dir/output"
    assert_equal 0 "$failures"
    assert_contains "$(cat "$test_dir/output")" '[skip] CaskaydiaCove Nerd Font Mono (WSL'
    # Without fontconfig the package step is the one to rerun.
    command() {
        case "$*" in
            '-v fc-list') return 1 ;;
            *) builtin command "$@" ;;
        esac
    }
    printf '6.1.0-25-amd64\n' > "$test_dir/kernel"
    check_linux_font > "$test_dir/output"
    assert_equal 1 "$failures"
    assert_contains "$(cat "$test_dir/output")" 'fontconfig is not installed; rerun: bash scripts/install_packages.sh'
}

# Every apt repository the bootstrap added needs its pinned key, alone, in its
# keyring, and that key must not have expired: apt-get update fails on an
# expired key. One expiring within 30 days passes with its date named. Dates
# print in UTC whatever the time zone, with GNU or BSD date; "now" is
# 2027-07-13 here. Each case below varies gierens's keyring, while charm's
# holds its pinned key, which never expires.
test_doctor_apt_keys() {
    source "$TEST_REPO_DIR/scripts/doctor.sh"
    export DOTFILES_TEST_FIXTURE="$test_dir"
    export DOTFILES_APT_ETC="$test_dir/etc-apt"
    assert_equal 2027-07-13 "$(dotfiles_date 1815436800)"
    assert_equal 2027-07-13 "$(TZ=WEST+10 dotfiles_date 1815436800)"
    assert_equal 2027-07-13 "$(TZ=EAST-14 dotfiles_date $((1815436800 + 86399)))"
    local now=1815436800 gierens charm found
    local other=0123456789ABCDEF0123456789ABCDEF01234567
    local keyring="$DOTFILES_APT_ETC/keyrings/gierens.gpg"
    read -r _ gierens _ <<<"$(dotfiles_apt_repository gierens)"
    read -r _ charm _ <<<"$(dotfiles_apt_repository charm)"
    # check_apt_keys has a "now" of its own, so the mock spells the time out.
    date() { if [ "$*" = +%s ]; then echo 1815436800; else command date "$@"; fi; }
    gpg() { echo 'gpg runs only through the mocked key_details here' >&2; return 99; }
    # A keyring's details come from keys/<name>; without that file there are none.
    key_details() {
        local name="${1#"$DOTFILES_APT_ETC/keyrings/"}"
        cat "$DOTFILES_TEST_FIXTURE/keys/${name%.gpg}" 2>/dev/null
    }
    mkdir -p "$test_dir/keys" "$DOTFILES_APT_ETC/sources.list.d"
    printf '%s\n' "$charm" > "$test_dir/keys/charm"
    # No repository added: nothing to check.
    failures=0
    check_apt_keys > "$test_dir/output"
    assert_equal '' "$(cat "$test_dir/output")"
    assert_equal 0 "$failures"
    : > "$DOTFILES_APT_ETC/sources.list.d/gierens.list"
    : > "$DOTFILES_APT_ETC/sources.list.d/charm.list"
    failures=0
    check_apt_keys > "$test_dir/output"
    assert_equal 1 "$failures"
    assert_equal "  [missing] gierens apt repository key ($keyring is missing or holds no key; run: bash scripts/update.sh)" "$(grep -F ' gierens apt ' "$test_dir/output")"
    assert_equal '  [ok] charm apt repository key' "$(grep -F ' charm apt ' "$test_dir/output")"
    # A keyring nobody may read fails whatever it holds. Root reads it all
    # the same, so only another user can check this.
    if [ "$(id -u)" -ne 0 ]; then
        mkdir -p "$DOTFILES_APT_ETC/keyrings"
        : > "$keyring"
        chmod 000 "$keyring"
        printf '%s\n' "$gierens" > "$test_dir/keys/gierens"
        failures=0
        check_apt_keys > "$test_dir/output"
        assert_equal 1 "$failures"
        assert_equal "  [missing] gierens apt repository key ($keyring is not readable, so apt cannot read it either; run: bash scripts/update.sh)" "$(grep -F ' gierens apt ' "$test_dir/output")"
        rm -f "$keyring"
    fi
    # Another key, or a second key beside the pinned one.
    for found in "$other" "$gierens"$'\n'"$other"; do
        printf '%s\n' "$found" > "$test_dir/keys/gierens"
        failures=0
        check_apt_keys > "$test_dir/output"
        assert_equal 1 "$failures"
        assert_equal "  [stale] gierens apt repository key ($keyring does not hold exactly the pinned key $gierens; run: bash scripts/update.sh)" "$(grep -F ' gierens apt ' "$test_dir/output")"
    done
    # Expired yesterday.
    printf '%s %s\n' "$gierens" $((now - 86400)) > "$test_dir/keys/gierens"
    failures=0
    check_apt_keys > "$test_dir/output"
    assert_equal 1 "$failures"
    assert_equal '  [stale] gierens apt repository key (expired on 2027-07-12; run: bash scripts/update.sh, which fetches it again)' "$(grep -F ' gierens apt ' "$test_dir/output")"
    # Expiring in 10 days.
    printf '%s %s\n' "$gierens" $((now + 10 * 86400)) > "$test_dir/keys/gierens"
    failures=0
    check_apt_keys > "$test_dir/output"
    assert_equal 0 "$failures"
    assert_equal '  [ok] gierens apt repository key (expires on 2027-07-23; scripts/update.sh fetches it again)' "$(grep -F ' gierens apt ' "$test_dir/output")"
    # Expiring in two years, or never.
    for found in "$gierens $((now + 2 * 365 * 86400))" "$gierens"; do
        printf '%s\n' "$found" > "$test_dir/keys/gierens"
        failures=0
        check_apt_keys > "$test_dir/output"
        assert_equal 0 "$failures"
        assert_equal '  [ok] gierens apt repository key' "$(grep -F ' gierens apt ' "$test_dir/output")"
    done
    # Without gnupg no keyring can be read; the package step installs it.
    unset -f gpg
    command() {
        case "$*" in
            '-v gpg') return 1 ;;
            *) builtin command "$@" ;;
        esac
    }
    failures=0
    check_apt_keys > "$test_dir/output"
    assert_equal 2 "$failures"
    assert_equal '  [missing] gierens apt repository key (gnupg is not installed; rerun: bash scripts/install_packages.sh)' "$(grep -F ' gierens apt ' "$test_dir/output")"
    assert_equal '  [missing] charm apt repository key (gnupg is not installed; rerun: bash scripts/install_packages.sh)' "$(grep -F ' charm apt ' "$test_dir/output")"
}

# plugins() against local repositories: missing plugins are cloned at the
# pinned commit, drifted ones return to it, a failed clone fails the run, and
# the lockfile bytes never change. Needs an installed lazy.nvim to copy.
# lazy.nvim adds itself to the plugins with its GitHub URL whatever the spec
# says, so git.url_format points every "owner/name" at the fixture.
test_nvim_bootstrap_plugins_keeps_lockfile() {
    local real_lazy="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy/lazy.nvim"
    local fx="$test_dir" plugin lazy_commit status
    local -A first second
    # lazy.nvim clones itself with blobs filtered, so a bare clone of it would
    # reach for GitHub; a fresh repository of its files stays local.
    mkdir -p "$fx/lazy-src" "$fx/data/nvim/lazy" "$fx/config/nvim" "$fx/state" "$fx/cache" "$fx/repos/folke" "$fx/repos/fixture"
    (cd "$real_lazy" && tar -cf - --exclude=.git .) | tar -xf - -C "$fx/lazy-src"
    git init -q -b main "$fx/lazy-src"
    git -C "$fx/lazy-src" add -A
    git -C "$fx/lazy-src" -c user.name=fixture -c user.email=fixture@example.com commit -q -m lazy
    git clone -q --bare "$fx/lazy-src" "$fx/repos/folke/lazy.nvim.git"
    git clone -q "file://$fx/repos/folke/lazy.nvim.git" "$fx/data/nvim/lazy/lazy.nvim"
    lazy_commit="$(git -C "$fx/data/nvim/lazy/lazy.nvim" rev-parse HEAD)"
    for plugin in alpha beta; do
        git init -q -b main "$fx/src/$plugin"
        printf 'one\n' > "$fx/src/$plugin/plugin.lua"
        git -C "$fx/src/$plugin" add plugin.lua
        git -C "$fx/src/$plugin" -c user.name=fixture -c user.email=fixture@example.com commit -q -m one
        first[$plugin]="$(git -C "$fx/src/$plugin" rev-parse HEAD)"
        printf 'two\n' > "$fx/src/$plugin/plugin.lua"
        git -C "$fx/src/$plugin" -c user.name=fixture -c user.email=fixture@example.com commit -q -am two
        second[$plugin]="$(git -C "$fx/src/$plugin" rev-parse HEAD)"
        git clone -q --bare "$fx/src/$plugin" "$fx/repos/fixture/$plugin.git"
    done
    cat > "$fx/config/nvim/init.lua" <<INIT
vim.opt.rtp:prepend("$TEST_REPO_DIR/config/nvim")
vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/lazy/lazy.nvim")
require("lazy").setup({
  spec = { { "fixture/alpha" }, { "fixture/beta" } },
  git = { url_format = "file://$fx/repos/%s.git" },
  install = { missing = false },
  checker = { enabled = false },
  change_detection = { notify = false },
  rocks = { enabled = false },
})
INIT
    printf '{\n  "alpha": { "branch": "main", "commit": "%s" },\n  "beta": { "branch": "main", "commit": "%s" },\n  "lazy.nvim": { "branch": "main", "commit": "%s" }\n}\n' \
        "${first[alpha]}" "${first[beta]}" "$lazy_commit" > "$fx/config/nvim/lazy-lock.json"
    cp "$fx/config/nvim/lazy-lock.json" "$fx/lock-original.json"
    run_plugins() {
        XDG_CONFIG_HOME="$fx/config" XDG_DATA_HOME="$fx/data" XDG_STATE_HOME="$fx/state" XDG_CACHE_HOME="$fx/cache" \
            nvim --headless -c 'lua require("dotfiles.bootstrap").plugins()' -c 'cquit 1' > "$fx/output" 2>&1
    }
    # Both plugins are cloned at the pinned (older) commit, not at the branch
    # head, without git's detached-HEAD advice for each checkout.
    run_plugins
    assert_equal "${first[alpha]}" "$(git -C "$fx/data/nvim/lazy/alpha" rev-parse HEAD)"
    assert_equal "${first[beta]}" "$(git -C "$fx/data/nvim/lazy/beta" rev-parse HEAD)"
    assert_contains "$(cat "$fx/output")" 'ok plugin beta'
    case "$(cat "$fx/output")" in
        *'detached HEAD'*) echo "git's detached-HEAD advice was printed." >&2; cat "$fx/output" >&2; return 1 ;;
    esac
    cmp -s "$fx/lock-original.json" "$fx/config/nvim/lazy-lock.json"
    # alpha drifts and beta's clone goes while its repository is unreachable: the
    # run fails, alpha is back on its commit, and beta stays pinned in the lockfile.
    git -C "$fx/data/nvim/lazy/alpha" checkout -q "${second[alpha]}"
    rm -rf "$fx/data/nvim/lazy/beta"
    mv "$fx/repos/fixture/beta.git" "$fx/repos/fixture/beta.git.away"
    status=0
    run_plugins || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$fx/output")" 'missing plugin beta'
    assert_equal "${first[alpha]}" "$(git -C "$fx/data/nvim/lazy/alpha" rev-parse HEAD)"
    cmp -s "$fx/lock-original.json" "$fx/config/nvim/lazy-lock.json"
    # Once reachable again, beta is cloned at the pinned commit.
    mv "$fx/repos/fixture/beta.git.away" "$fx/repos/fixture/beta.git"
    run_plugins
    assert_equal "${first[beta]}" "$(git -C "$fx/data/nvim/lazy/beta" rev-parse HEAD)"
    assert_contains "$(cat "$fx/output")" 'ok plugin lazy.nvim'
    cmp -s "$fx/lock-original.json" "$fx/config/nvim/lazy-lock.json"
}

test_nvim_config_check() {
    source "$TEST_REPO_DIR/scripts/test.sh"
    # The real configuration passes; the checker runs without the user's configuration.
    XDG_CONFIG_HOME="$test_dir/no-config" check_nvim_config "$TEST_REPO_DIR/config/nvim" > "$test_dir/output"
    assert_contains "$(cat "$test_dir/output")" 'plugins pinned'
    # A copy with a syntax error, an unpinned plugin and a stale lockfile entry fails on each.
    cp -R "$TEST_REPO_DIR/config/nvim" "$test_dir/nvim"
    printf 'return { "owner/new-plugin", opts = {} }\n' > "$test_dir/nvim/lua/plugins/new.lua"
    printf 'local broken = {\n' > "$test_dir/nvim/lua/dotfiles/broken.lua"
    printf '{\n  "lazy.nvim": { "branch": "main", "commit": "aaa" },\n  "gone.nvim": { "branch": "main", "commit": "bbb" }\n}\n' > "$test_dir/nvim/lazy-lock.json"
    local status=0
    check_nvim_config "$test_dir/nvim" > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'broken.lua'
    assert_contains "$(cat "$test_dir/output")" "lacks the declared plugin 'new-plugin'"
    assert_contains "$(cat "$test_dir/output")" "pins 'gone.nvim', which no plugin file declares"
    assert_contains "$(cat "$test_dir/output")" "lacks the declared plugin 'catppuccin'"
}

# missing() and install() against a PATH with and without a tree-sitter CLI
# (see tests/nvim_bootstrap_missing.lua): on macOS and Linux parsers count as
# skipped, not missing, exactly when the CLI is not on PATH (as on Debian 12,
# whose glibc 2.36 the current releases do not run on).
test_nvim_bootstrap_missing() {
    if ! nvim -l "$TEST_REPO_DIR/tests/nvim_bootstrap_missing.lua" "$TEST_REPO_DIR/config/nvim" > "$test_dir/output" 2>&1; then
        cat "$test_dir/output" >&2
        return 1
    fi
    assert_contains "$(cat "$test_dir/output")" '2 parser skip cases pass.'
}

# update() against stand-ins for mason-registry and nvim-treesitter (see
# tests/nvim_bootstrap_update.lua): current, newer, failed and retried,
# missing, and the parser update with and without a compiler.
test_nvim_bootstrap_update() {
    if ! nvim -l "$TEST_REPO_DIR/tests/nvim_bootstrap_update.lua" "$TEST_REPO_DIR/config/nvim" > "$test_dir/output" 2>&1; then
        cat "$test_dir/output" >&2
        return 1
    fi
    assert_contains "$(cat "$test_dir/output")" '6 update cases pass.'
}

test_doctor_neovim_checks() {
    source "$TEST_REPO_DIR/scripts/doctor.sh"
    export DOTFILES_TEST_FIXTURE="$test_dir"
    export XDG_DATA_HOME="$test_dir/data"
    nvim() {
        printf '%s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/nvim-args"
        case "$*" in
            --version) cat "$DOTFILES_TEST_FIXTURE/version" ;;
            *'bootstrap").check()'*)
                case "$*" in *' -c cquit 1') ;; *) echo 'the check must be followed by cquit' >&2; return 99 ;; esac
                printf 'ok plugin catppuccin\nok parser bash\nok package lua-language-server\n'
                if [ -f "$DOTFILES_TEST_FIXTURE/tools-missing" ]; then
                    printf 'missing plugin gitsigns.nvim\nstale plugin which-key.nvim\nmissing parser yaml\nmissing package marksman\nskipped parser python (no C compiler or tree-sitter CLI; see docs/troubleshooting.md in the dotfiles repository)\n'
                    return 1
                fi
                ;;
            --headless*)
                if [ -f "$DOTFILES_TEST_FIXTURE/start-error" ]; then
                    echo 'E5113: Lua chunk: init.lua:2: boom' >&2
                    return 3
                fi
                ;;
        esac
    }
    tree-sitter() { cat "$DOTFILES_TEST_FIXTURE/ts-version"; }
    printf 'NVIM v0.12.6\n' > "$test_dir/version"
    failures=0
    check_nvim_version > "$test_dir/output"
    assert_equal 0 "$failures"
    assert_contains "$(cat "$test_dir/output")" '[ok] Neovim 0.12.6'
    printf 'NVIM v0.9.5\n' > "$test_dir/version"
    check_nvim_version > "$test_dir/output"
    assert_equal 1 "$failures"
    assert_contains "$(cat "$test_dir/output")" '0.9.5 is older than'
    printf 'VIM - Vi IMproved 9.1\n' > "$test_dir/version"
    check_nvim_version > "$test_dir/output"
    assert_equal 2 "$failures"
    assert_contains "$(cat "$test_dir/output")" 'did not report one'
    # The tree-sitter CLI must be present and new enough to compile parsers.
    printf 'tree-sitter 0.27.1\n' > "$test_dir/ts-version"
    failures=0
    check_tree_sitter > "$test_dir/output"
    assert_equal 0 "$failures"
    assert_contains "$(cat "$test_dir/output")" '[ok] tree-sitter CLI 0.27.1'
    printf 'tree-sitter 0.22.6\n' > "$test_dir/ts-version"
    check_tree_sitter > "$test_dir/output"
    assert_equal 1 "$failures"
    assert_contains "$(cat "$test_dir/output")" '0.22.6 is older than 0.26.1'
    printf 'something else\n' > "$test_dir/ts-version"
    check_tree_sitter > "$test_dir/output"
    assert_equal 2 "$failures"
    assert_contains "$(cat "$test_dir/output")" 'did not report one'
    # Without lazy.nvim a start would clone it, so nothing is started.
    failures=0
    : > "$test_dir/nvim-args"
    check_nvim_plugins > "$test_dir/output"
    assert_equal 1 "$failures"
    assert_contains "$(cat "$test_dir/output")" '[missing] lazy.nvim ('
    assert_equal '' "$(cat "$test_dir/nvim-args")"
    # With it: a clean start, then the report of plugins, parsers and servers.
    mkdir -p "$XDG_DATA_HOME/nvim/lazy/lazy.nvim/lua/lazy"
    : > "$XDG_DATA_HOME/nvim/lazy/lazy.nvim/lua/lazy/init.lua"
    failures=0
    check_nvim_plugins > "$test_dir/output"
    assert_equal 0 "$failures"
    assert_contains "$(cat "$test_dir/output")" '[ok] lazy.nvim'
    assert_contains "$(cat "$test_dir/output")" '[ok] Neovim starts without errors'
    assert_contains "$(cat "$test_dir/output")" '[ok] Neovim plugin catppuccin'
    assert_contains "$(cat "$test_dir/output")" '[ok] Neovim parser bash'
    assert_contains "$(cat "$test_dir/output")" '[ok] Neovim language server lua-language-server'
    assert_contains "$(tail -n 2 "$test_dir/nvim-args" | head -n 1)" 'vim.v.errmsg'
    assert_contains "$(tail -n 1 "$test_dir/nvim-args")" 'bootstrap").check() -c cquit 1'
    # Missing or stale plugins, parsers and servers fail and name the bootstrap; skipped parsers do not count.
    : > "$test_dir/tools-missing"
    failures=0
    check_nvim_plugins > "$test_dir/output"
    assert_equal 4 "$failures"
    assert_contains "$(cat "$test_dir/output")" '[missing] Neovim plugin gitsigns.nvim (rerun: bash scripts/bootstrap_tools.sh)'
    assert_contains "$(cat "$test_dir/output")" '[stale] Neovim plugin which-key.nvim is not at the commit lazy-lock.json pins'
    assert_contains "$(cat "$test_dir/output")" '[missing] Neovim parser yaml (rerun: bash scripts/bootstrap_tools.sh)'
    assert_contains "$(cat "$test_dir/output")" '[missing] Neovim language server marksman (rerun: bash scripts/bootstrap_tools.sh)'
    assert_contains "$(cat "$test_dir/output")" '[skip] Neovim parser python (no C compiler'
    rm "$test_dir/tools-missing"
    # A failing start is reported once and the report is not attempted.
    : > "$test_dir/start-error"
    : > "$test_dir/nvim-args"
    failures=0
    check_nvim_plugins > "$test_dir/output" 2>&1
    assert_equal 1 "$failures"
    assert_contains "$(cat "$test_dir/output")" 'E5113'
    assert_equal 1 "$(wc -l < "$test_dir/nvim-args" | tr -d ' ')"
    # Without nvim or tree-sitter the versions are missing and nothing is started.
    unset -f nvim tree-sitter
    getconf() { return 1; }
    command() {
        case "$*" in
            '-v nvim'|'-v tree-sitter') return 1 ;;
            *) builtin command "$@" ;;
        esac
    }
    failures=0
    : > "$test_dir/nvim-args"
    check_nvim_version > "$test_dir/output"
    check_tree_sitter > "$test_dir/output"
    check_nvim_plugins > "$test_dir/output"
    assert_equal 2 "$failures"
    assert_equal '' "$(cat "$test_dir/nvim-args")"
    # A CLI that warns about a newer glibc hangs installing parsers.
    unset -f command
    tree-sitter() {
        echo "tree-sitter: libc.so.6: weak version \`GLIBC_2.39' not found" >&2
        echo "tree-sitter 0.27.1"
    }
    failures=0
    check_tree_sitter > "$test_dir/output"
    assert_equal 1 "$failures"
    assert_contains "$(cat "$test_dir/output")" 'built for a newer glibc than this system'"'"'s (rerun: bash scripts/bootstrap_tools.sh)'
    unset -f tree-sitter
    command() {
        case "$*" in
            '-v nvim'|'-v tree-sitter') return 1 ;;
            *) builtin command "$@" ;;
        esac
    }
    # A CLI the bootstrap left out for this glibc is skipped, as Neovim skips
    # the parsers; without the record, or after a glibc upgrade, it is missing.
    export XDG_STATE_HOME="$test_dir/state"
    getconf() { [ "$1" = GNU_LIBC_VERSION ] && cat "$DOTFILES_TEST_FIXTURE/glibc"; }
    printf 'glibc 2.36\n' > "$test_dir/glibc"
    failures=0
    check_tree_sitter > "$test_dir/output"
    assert_equal 1 "$failures"
    mkdir -p "$test_dir/state/dotfiles"
    printf 'v0.27.1 2.36\n' > "$test_dir/state/dotfiles/tree-sitter-unsupported"
    failures=0
    check_tree_sitter > "$test_dir/output"
    assert_equal 0 "$failures"
    assert_contains "$(cat "$test_dir/output")" '[skip] tree-sitter CLI (v0.27.1 needs a newer glibc than 2.36'
    printf 'glibc 2.41\n' > "$test_dir/glibc"
    check_tree_sitter > "$test_dir/output"
    assert_equal 1 "$failures"
}

test_doctor_rejects_stale_configuration() {
    source "$TEST_REPO_DIR/scripts/doctor.sh"
    printf 'managed\n' > "$test_dir/source"
    printf 'other\n' > "$test_dir/other"
    ln -s "$test_dir/source" "$test_dir/correct"
    ln -s "$test_dir/other" "$test_dir/wrong"
    ln -s "$test_dir/absent" "$test_dir/broken"
    check_link "$test_dir/source" "$test_dir/correct"
    assert_equal 0 "$failures"
    check_link "$test_dir/source" "$test_dir/wrong"
    check_link "$test_dir/source" "$test_dir/broken"
    assert_equal 2 "$failures"
    rm "$test_dir/source"
    check_link "$test_dir/source" "$test_dir/correct"
    assert_equal 3 "$failures"
    # A file at a retired location is reported whatever it is; its absence passes.
    failures=0
    check_absent "legacy file" "$test_dir/wrong" > "$test_dir/output"
    assert_contains "$(cat "$test_dir/output")" '[stale] legacy file'
    check_absent "legacy file" "$test_dir/broken"
    check_absent "legacy file" "$test_dir/absent"
    assert_equal 2 "$failures"
    # A system-wide Node.js must not hide a missing mise-managed one.
    node() { return 0; }
    mise() { return 1; }
    failures=0
    check_mise_node
    assert_equal 1 "$failures"
    mise() {
        [ "$1 $2" = 'which node' ] || return 1
        printf '%s/mise/node\n' "$test_dir"
    }
    failures=0
    check_mise_node > "$test_dir/output"
    assert_equal 0 "$failures"
    assert_contains "$(cat "$test_dir/output")" "$test_dir/mise/node"
    unset -f mise
    command() {
        if [ "$*" = '-v mise' ]; then return 1; fi
        builtin command "$@"
    }
    failures=0
    check_mise_node > "$test_dir/output"
    assert_equal 1 "$failures"
    assert_contains "$(cat "$test_dir/output")" 'mise is not installed'
}

test_bat_theme_install_and_skip() {
    source "$TEST_REPO_DIR/scripts/bootstrap_tools.sh"
    export DOTFILES_TEST_FIXTURE="$test_dir"
    # The theme name comes from config/bat/config, so the mock reads it too.
    DOTFILES_TEST_BAT_THEME="$(dotfiles_bat_theme "$TEST_REPO_DIR/config/bat/config")"
    export DOTFILES_TEST_BAT_THEME
    assert_contains "$DOTFILES_TEST_BAT_THEME" 'Catppuccin '
    command() {
        case "$*" in
            '-v bat') return 0 ;;
            *) builtin command "$@" ;;
        esac
    }
    bat() {
        case "$*" in
            '--list-themes')
                printf 'Dracula\n'
                if [ -f "$DOTFILES_TEST_FIXTURE/theme-built" ]; then
                    printf '%s\n' "$DOTFILES_TEST_BAT_THEME"
                fi
                ;;
            '--config-dir') printf '%s/bat-config\n' "$DOTFILES_TEST_FIXTURE" ;;
            'cache --build')
                [ -f "$DOTFILES_TEST_FIXTURE/bat-config/themes/$DOTFILES_TEST_BAT_THEME.tmTheme" ] || return 50
                : > "$DOTFILES_TEST_FIXTURE/theme-built"
                ;;
        esac
    }
    curl() {
        local output=""
        printf '%s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/commands"
        [ -f "$DOTFILES_TEST_FIXTURE/retry" ] || return 51
        while [ "$#" -gt 0 ]; do
            if [ "$1" = -o ]; then
                output="$2"
                shift
            fi
            shift
        done
        printf '<plist/>\n' > "$output"
    }
    : > "$test_dir/theme-built"
    bootstrap_bat_theme
    [ ! -f "$test_dir/commands" ]
    rm "$test_dir/theme-built"
    local status=0
    bootstrap_bat_theme > "$test_dir/output" 2>&1 || status=$?
    assert_equal 51 "$status"
    assert_equal 0 "$(find "$test_dir/bat-config" -name '*.tmTheme*' | wc -l | tr -d ' ')"
    : > "$test_dir/retry"
    bootstrap_bat_theme
    [ -f "$test_dir/bat-config/themes/$DOTFILES_TEST_BAT_THEME.tmTheme" ]
    assert_contains "$(cat "$test_dir/commands")" "themes/${DOTFILES_TEST_BAT_THEME// /%20}.tmTheme"
    [ -f "$test_dir/theme-built" ]
    : > "$test_dir/commands"
    bootstrap_bat_theme
    assert_equal '' "$(cat "$test_dir/commands")"
}

render_portable_profile() {
    # Redirect only filesystem references in a copy of the actual profile. HOME is
    # never reassigned, and the test cannot source the user's local configuration.
    awk '{
        gsub(/\$\{HOME\}/, "${DOTFILES_TEST_HOME}")
        gsub(/\$HOME/, "$DOTFILES_TEST_HOME")
        gsub(/~\//, "${DOTFILES_TEST_HOME}/")
        gsub(/\/opt\/homebrew\/bin\/brew/, "${DOTFILES_TEST_HOME}/brew-arm")
        gsub(/\/usr\/local\/bin\/brew/, "${DOTFILES_TEST_HOME}/brew-intel")
        print
    }' "$TEST_REPO_DIR/home/.zshrc" > "$1"
}

test_zsh_portable_overrides() {
    local zsh_binary
    zsh_binary="$(command -v zsh)"
    mkdir -p "$test_dir/fixture" "$test_dir/zdot" "$test_dir/data"
    render_portable_profile "$test_dir/profile.zsh"
    DOTFILES_TEST_HOME="$test_dir/fixture" DOTFILES_TEST_PROFILE="$test_dir/profile.zsh" \
        XDG_DATA_HOME="$test_dir/data" ZDOTDIR="$test_dir/zdot" \
        SSH_AUTH_SOCK="$test_dir/original-agent" PATH=/usr/bin:/bin \
        "$zsh_binary" -df -c '
            autoload() { :; }
            compinit() { :; }
            source "$DOTFILES_TEST_PROFILE" || exit 1
            [[ "$SSH_AUTH_SOCK" == "${DOTFILES_TEST_HOME:h}/original-agent" ]] || exit 1
            [[ "$EZA_CONFIG_DIR" == "$DOTFILES_TEST_HOME/.config/eza" ]] || exit 1
            [[ "$ABBR_USER_ABBREVIATIONS_FILE" == "$DOTFILES_TEST_HOME/.config/zsh-abbr/user-abbreviations" ]] || exit 1
        '
    cat > "$test_dir/fixture/.zshrc.local" <<'LOCAL'
export SSH_AUTH_SOCK="$DOTFILES_TEST_HOME/local-agent"
export EZA_CONFIG_DIR="$DOTFILES_TEST_HOME/local-eza"
LOCAL
    DOTFILES_TEST_HOME="$test_dir/fixture" DOTFILES_TEST_PROFILE="$test_dir/profile.zsh" \
        XDG_DATA_HOME="$test_dir/data" ZDOTDIR="$test_dir/zdot" \
        SSH_AUTH_SOCK="$test_dir/original-agent" PATH=/usr/bin:/bin \
        "$zsh_binary" -df -c '
            autoload() { :; }
            compinit() { :; }
            source "$DOTFILES_TEST_PROFILE" || exit 1
            [[ "$SSH_AUTH_SOCK" == "$DOTFILES_TEST_HOME/local-agent" ]] || exit 1
            [[ "$EZA_CONFIG_DIR" == "$DOTFILES_TEST_HOME/local-eza" ]] || exit 1
        '
    # The bootstrap's bin directory leads PATH; another one, given from
    # ~/.zshenv, goes first and ~/.local/bin stays.
    DOTFILES_TEST_HOME="$test_dir/fixture" DOTFILES_TEST_PROFILE="$test_dir/profile.zsh" \
        XDG_DATA_HOME="$test_dir/data" ZDOTDIR="$test_dir/zdot" PATH=/usr/bin:/bin \
        "$zsh_binary" -df -c '
            autoload() { :; }
            compinit() { :; }
            source "$DOTFILES_TEST_PROFILE" || exit 1
            [[ "${path[1]}" == "$DOTFILES_TEST_HOME/.local/bin" ]] || exit 1
            [[ "${path[(I)$DOTFILES_TEST_HOME/.local/bin]}" -eq 1 ]] || exit 1
        '
    DOTFILES_TEST_HOME="$test_dir/fixture" DOTFILES_TEST_PROFILE="$test_dir/profile.zsh" \
        XDG_DATA_HOME="$test_dir/data" ZDOTDIR="$test_dir/zdot" PATH=/usr/bin:/bin \
        DOTFILES_LOCAL_BIN="$test_dir/custom-bin" \
        "$zsh_binary" -df -c '
            autoload() { :; }
            compinit() { :; }
            source "$DOTFILES_TEST_PROFILE" || exit 1
            [[ "${path[1]}" == "$DOTFILES_LOCAL_BIN" ]] || exit 1
            [[ "${path[2]}" == "$DOTFILES_TEST_HOME/.local/bin" ]] || exit 1
        '
}

test_zsh_tool_hooks() {
    local zsh_binary
    zsh_binary="$(command -v zsh)"
    mkdir -p "$test_dir/fixture" "$test_dir/zdot" "$test_dir/data/mise/shims" "$test_dir/bin"
    render_portable_profile "$test_dir/profile.zsh"
    export DOTFILES_TEST_FIXTURE="$test_dir"
    # Each mock records its arguments and prints what the real tool would: a
    # shell snippet to eval, or an LS_COLORS string. mise itself must never run
    # at startup; only its shims directory joins PATH.
    cat > "$test_dir/bin/mise" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/mise-args"
MOCK
    cat > "$test_dir/bin/atuin" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/atuin-args"
echo 'export DOTFILES_TEST_ATUIN=yes'
MOCK
    cat > "$test_dir/bin/carapace" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/carapace-args"
echo 'export DOTFILES_TEST_CARAPACE=yes'
MOCK
    cat > "$test_dir/bin/direnv" <<'MOCK'
#!/bin/sh
echo 'export DOTFILES_TEST_DIRENV=yes'
MOCK
    cat > "$test_dir/bin/vivid" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/vivid-args"
echo 'di=1;34:*.vivid=35'
MOCK
    cat > "$test_dir/bin/fastfetch" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/fastfetch-args"
MOCK
    printf '#!/bin/sh\nexit 0\n' > "$test_dir/bin/fdfind"
    chmod +x "$test_dir/bin/"*
    local tool_probe='
            autoload() { :; }
            compinit() { :; }
            source "$DOTFILES_TEST_PROFILE" || exit 1
            [[ "$path[1]" == "$XDG_DATA_HOME/mise/shims" ]] || { print "mise shims not first on PATH: $path[1]"; exit 1; }
            [[ "$DOTFILES_TEST_ATUIN" == yes ]] || { print "atuin was not initialised"; exit 1; }
            [[ "$DOTFILES_TEST_CARAPACE" == yes ]] || { print "carapace was not sourced"; exit 1; }
            [[ "$DOTFILES_TEST_DIRENV" == yes ]] || { print "direnv hook missing"; exit 1; }
        '
    DOTFILES_TEST_HOME="$test_dir/fixture" DOTFILES_TEST_PROFILE="$test_dir/profile.zsh" \
        XDG_DATA_HOME="$test_dir/data" XDG_CACHE_HOME="$test_dir/cache" ZDOTDIR="$test_dir/zdot" PATH="$test_dir/bin:/usr/bin:/bin" \
        "$zsh_binary" -df -c '
            autoload() { :; }
            compinit() { :; }
            source "$DOTFILES_TEST_PROFILE" || exit 1
            [[ "$path[1]" == "$XDG_DATA_HOME/mise/shims" ]] || { print "mise shims not first on PATH: $path[1]"; exit 1; }
            [[ ! -f "$DOTFILES_TEST_FIXTURE/mise-args" ]] || { print "mise ran at startup"; exit 1; }
            [[ "$DOTFILES_TEST_ATUIN" == yes ]] || { print "atuin was not initialised"; exit 1; }
            [[ "$DOTFILES_TEST_CARAPACE" == yes ]] || { print "carapace was not sourced"; exit 1; }
            [[ "$DOTFILES_TEST_DIRENV" == yes ]] || { print "direnv hook missing"; exit 1; }
            [[ "$LS_COLORS" == "di=1;34:*.vivid=35" ]] || { print "LS_COLORS: $LS_COLORS"; exit 1; }
            [[ "$aliases[fd]" == fdfind ]] || { print "fd alias: $aliases[fd]"; exit 1; }
            [[ "$FZF_DEFAULT_COMMAND" == "fdfind --type f"* ]] || { print "FZF_DEFAULT_COMMAND: $FZF_DEFAULT_COMMAND"; exit 1; }
            [[ "$(whence -w eza)" == "eza: function" ]] || { print "eza wrapper missing"; exit 1; }
            [[ "$(whence -w y)" == "y: function" ]] || { print "y function missing"; exit 1; }
            [[ "$YSU_MESSAGE_POSITION" == after ]] || exit 1
        '
    [ ! -f "$test_dir/mise-args" ]
    assert_equal 'init zsh --disable-up-arrow' "$(cat "$test_dir/atuin-args")"
    assert_equal '_carapace zsh' "$(cat "$test_dir/carapace-args")"
    assert_equal "generate catppuccin-$(cat "$TEST_REPO_DIR/config/catppuccin/flavor")" "$(cat "$test_dir/vivid-args")"
    [ -s "$test_dir/cache/dotfiles/carapace.zsh" ]
    [ -s "$test_dir/cache/dotfiles/atuin.zsh" ]
    [ -s "$test_dir/cache/dotfiles/direnv.zsh" ]
    # The second shell sources the cached scripts and does not run the tools again.
    DOTFILES_TEST_HOME="$test_dir/fixture" DOTFILES_TEST_PROFILE="$test_dir/profile.zsh" \
        XDG_DATA_HOME="$test_dir/data" XDG_CACHE_HOME="$test_dir/cache" ZDOTDIR="$test_dir/zdot" PATH="$test_dir/bin:/usr/bin:/bin" \
        "$zsh_binary" -df -c "$tool_probe"
    assert_equal 1 "$(wc -l < "$test_dir/atuin-args" | tr -d ' ')"
    assert_equal 1 "$(wc -l < "$test_dir/carapace-args" | tr -d ' ')"
    # An upgraded binary (new size, path or mtime) invalidates its cache.
    printf '# upgraded build\n' >> "$test_dir/bin/atuin"
    DOTFILES_TEST_HOME="$test_dir/fixture" DOTFILES_TEST_PROFILE="$test_dir/profile.zsh" \
        XDG_DATA_HOME="$test_dir/data" XDG_CACHE_HOME="$test_dir/cache" ZDOTDIR="$test_dir/zdot" PATH="$test_dir/bin:/usr/bin:/bin" \
        "$zsh_binary" -df -c "$tool_probe"
    assert_equal 2 "$(wc -l < "$test_dir/atuin-args" | tr -d ' ')"
    assert_equal 1 "$(wc -l < "$test_dir/carapace-args" | tr -d ' ')"
    # A failing generator leaves no cache behind and the shell still loads.
    printf '#!/bin/sh\nexit 7\n' > "$test_dir/bin/direnv"
    rm "$test_dir/cache/dotfiles/direnv.zsh"
    DOTFILES_TEST_HOME="$test_dir/fixture" DOTFILES_TEST_PROFILE="$test_dir/profile.zsh" \
        XDG_DATA_HOME="$test_dir/data" XDG_CACHE_HOME="$test_dir/cache" ZDOTDIR="$test_dir/zdot" PATH="$test_dir/bin:/usr/bin:/bin" \
        "$zsh_binary" -df -c '
            autoload() { :; }
            compinit() { :; }
            source "$DOTFILES_TEST_PROFILE" || exit 1
            [[ -z "$DOTFILES_TEST_DIRENV" ]] || exit 1
        '
    [ ! -e "$test_dir/cache/dotfiles/direnv.zsh" ]
    assert_equal 0 "$(find "$test_dir/cache/dotfiles" -name 'direnv.zsh.*' | wc -l | tr -d ' ')"
    # vivid 0.8 (Debian 12) has no Catppuccin theme: the ANSI default must survive.
    printf '#!/bin/sh\necho "Error: theme not found" >&2\nexit 1\n' > "$test_dir/bin/vivid"
    DOTFILES_TEST_HOME="$test_dir/fixture" DOTFILES_TEST_PROFILE="$test_dir/profile.zsh" \
        XDG_DATA_HOME="$test_dir/data" XDG_CACHE_HOME="$test_dir/cache" ZDOTDIR="$test_dir/zdot" PATH="$test_dir/bin:/usr/bin:/bin" \
        "$zsh_binary" -df -c '
            autoload() { :; }
            compinit() { :; }
            source "$DOTFILES_TEST_PROFILE" 2>/dev/null || exit 1
            [[ "$LS_COLORS" == di=1\;34:* ]] || { print "LS_COLORS: $LS_COLORS"; exit 1; }
        '
    # Without the tools the profile still loads, with the ANSI color default and no fd alias.
    DOTFILES_TEST_HOME="$test_dir/fixture" DOTFILES_TEST_PROFILE="$test_dir/profile.zsh" \
        XDG_DATA_HOME="$test_dir/data" ZDOTDIR="$test_dir/zdot" PATH=/usr/bin:/bin \
        "$zsh_binary" -df -c '
            autoload() { :; }
            compinit() { :; }
            source "$DOTFILES_TEST_PROFILE" || exit 1
            [[ -z "$DOTFILES_TEST_ATUIN$DOTFILES_TEST_CARAPACE$DOTFILES_TEST_DIRENV" ]] || exit 1
            [[ "$LS_COLORS" == di=1\;34:* ]] || { print "LS_COLORS: $LS_COLORS"; exit 1; }
            [[ -z "${aliases[fd]:-}" ]] || exit 1
            [[ -z "${FZF_DEFAULT_COMMAND:-}" ]] || exit 1
        '
    # fastfetch greets interactive shells only, outside tmux, unless opted out.
    [ ! -f "$test_dir/fastfetch-args" ]
    local greeter_probe='
            autoload() { :; }
            compinit() { :; }
            source "$DOTFILES_TEST_PROFILE" || exit 1
        '
    DOTFILES_TEST_HOME="$test_dir/fixture" DOTFILES_TEST_PROFILE="$test_dir/profile.zsh" \
        XDG_DATA_HOME="$test_dir/data" XDG_CACHE_HOME="$test_dir/cache" ZDOTDIR="$test_dir/zdot" PATH="$test_dir/bin:/usr/bin:/bin" \
        "$zsh_binary" -df -i -c "$greeter_probe" < /dev/null
    assert_equal "--config $test_dir/fixture/.config/fastfetch/config.jsonc" "$(cat "$test_dir/fastfetch-args")"
    TMUX="$test_dir/socket,1,0" DOTFILES_TEST_HOME="$test_dir/fixture" DOTFILES_TEST_PROFILE="$test_dir/profile.zsh" \
        XDG_DATA_HOME="$test_dir/data" XDG_CACHE_HOME="$test_dir/cache" ZDOTDIR="$test_dir/zdot" PATH="$test_dir/bin:/usr/bin:/bin" \
        "$zsh_binary" -df -i -c "$greeter_probe" < /dev/null
    DOTFILES_FASTFETCH=0 DOTFILES_TEST_HOME="$test_dir/fixture" DOTFILES_TEST_PROFILE="$test_dir/profile.zsh" \
        XDG_DATA_HOME="$test_dir/data" XDG_CACHE_HOME="$test_dir/cache" ZDOTDIR="$test_dir/zdot" PATH="$test_dir/bin:/usr/bin:/bin" \
        "$zsh_binary" -df -i -c "$greeter_probe" < /dev/null
    assert_equal 1 "$(wc -l < "$test_dir/fastfetch-args" | tr -d ' ')"
}

run_tests() {
    local test_name output
    local passed=0
    local failed=0
    local tests=(
        syntax_every_file
        link_fresh_and_repeat
        link_main_moves_old_files_aside
        gitconfig_guard_creates_once
        link_backups_and_collisions
        link_broken_wrong_and_relocated
        link_retires_moved_sources
        link_failed_replacement
        theme_switch_round_trip
        environment_discovery
        login_shell_discovery
        package_index_failure
        macos_font_install_and_repair
        macos_formulae_survive_stdin_consumers
        macos_app_cask_detection
        install_stages_and_failure_reporting
        update_stages_and_failure_reporting
        eza_index_and_download_failures
        apt_held_packages_left_alone
        apt_key_pinning
        apt_keys_refreshed_before_updating
        macos_update_upgrades_declared
        script_installers_install_and_update
        github_release_install
        github_release_update
        release_download_verification
        release_age
        bootstrap_tools_api_cache
        fd_link_for_debian
        mise_bootstrap_and_runtimes
        yazi_flavors_install_and_retry
        neovim_release_install
        neovim_release_update
        tree_sitter_cli_install
        tree_sitter_cli_update
        linux_font_install
        linux_font_update
        doctor_linux_font
        doctor_apt_keys
        neovim_plugins_install_and_retry
        doctor_neovim_checks
        tmux_plugin_failure_and_retry
        tmux_config_declares_plugins_in_order
        bat_theme_install_and_skip
        doctor_rejects_stale_configuration
    )
    if command -v zsh >/dev/null 2>&1; then
        tests+=(zinit_plugin_failure_and_retry zsh_portable_overrides zsh_tool_hooks)
    else
        echo "  SKIP zinit_plugin_failure_and_retry, zsh_portable_overrides and zsh_tool_hooks (zsh is not installed)."
    fi
    if command -v python3 >/dev/null 2>&1; then
        tests+=(oh_my_posh_config_check)
    else
        echo "  SKIP oh_my_posh_config_check (python3 is not installed)."
    fi
    if command -v tmux >/dev/null 2>&1; then
        tests+=(tmux_config_loads_and_errors_are_reported)
    else
        echo "  SKIP tmux_config_loads_and_errors_are_reported (tmux is not installed)."
    fi
    if command -v nvim >/dev/null 2>&1; then
        tests+=(nvim_config_check nvim_bootstrap_update nvim_bootstrap_missing)
    else
        echo "  SKIP nvim_config_check, nvim_bootstrap_update and nvim_bootstrap_missing (nvim is not installed)."
    fi
    # The plugin bootstrap runs against local repositories but needs a copy of
    # lazy.nvim, which only a machine that applied the configuration has.
    if command -v nvim >/dev/null 2>&1 && command -v git >/dev/null 2>&1 && \
        [ -r "${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy/lazy.nvim/lua/lazy/init.lua" ]; then
        tests+=(nvim_bootstrap_plugins_keeps_lockfile)
    else
        echo "  SKIP nvim_bootstrap_plugins_keeps_lockfile (needs nvim, git and an installed lazy.nvim)."
    fi
    for test_name in "${tests[@]}"; do
        # A separate shell keeps errexit active inside each case and isolates mocks.
        if output="$(bash "$TEST_SCRIPT" "$test_name" 2>&1)"; then
            printf '  PASS %s\n' "$test_name"
            passed=$((passed + 1))
        else
            printf '  FAIL %s\n%s\n' "$test_name" "$output" >&2
            failed=$((failed + 1))
        fi
    done
    printf '%s Unix behavior checks passed; %s failed.\n' "$passed" "$failed"
    [ "$failed" -eq 0 ]
}

if [ "$#" -eq 0 ]; then
    run_tests
else
    test_dir="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-tests.XXXXXX")"
    trap 'rm -rf "$test_dir"' EXIT
    # Release records and other state never reach the real home directory, and
    # each test chooses for itself whether it updates and how old a release
    # must be.
    export XDG_STATE_HOME="$test_dir/state"
    unset DOTFILES_UPDATE DOTFILES_MINIMUM_RELEASE_AGE MISE_MINIMUM_RELEASE_AGE DOTFILES_LOCAL_BIN
    "test_$1"
fi
