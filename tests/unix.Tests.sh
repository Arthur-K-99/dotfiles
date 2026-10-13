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
# check is covered by test_release_download_verification.
trust_release_downloads() {
    release_asset_digest() { printf 'fixture\n'; }
    file_sha256() { printf 'fixture\n'; }
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
    [ ! -L "$test_dir/stale" ] && [ ! -e "$test_dir/stale" ]
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
    [ ! -e "$test_dir/empty" ] && [ -f "$test_dir/full/file" ] && [ -L "$test_dir/dir-link" ]
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
    assert_equal 'install git' "$(cat "$test_dir/commands")"
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
            'list --cask '*) return 1 ;;
            *) cat >/dev/null ;;
        esac
    }
    install_macos
    assert_equal $'install first\ninstall second\ninstall third\nlist --cask ghostty\ninstall --cask ghostty' "$(cat "$test_dir/commands")"
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
    assert_equal $'install git\ninstall neovim\ninstall lazygit' "$(cat "$test_dir/commands")"
    assert_equal unset "$(sort -u "$test_dir/no-install-upgrade")"
    # Current: the index is refreshed and nothing is upgraded.
    export DOTFILES_UPDATE=1
    : > "$test_dir/commands"
    : > "$test_dir/no-install-upgrade"
    install_macos > "$test_dir/output"
    assert_equal $'update\noutdated --formula --quiet\nlist --pinned --formula\noutdated --cask --quiet\nlist --pinned --cask\ninstall git\ninstall neovim\ninstall lazygit' "$(cat "$test_dir/commands")"
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
    install_main > "$test_dir/output" 2>&1
    assert_contains "$(cat "$test_dir/output")" 'All setup checks passed.'
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
            gpg|tee) cat >/dev/null ;;
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
    assert_equal 'install_apt_key gierens https://raw.githubusercontent.com/eza-community/eza/main/deb.asc 1548BC8A4B4D2688F9B0DAF7EC29E2090CE3FD43' "$(cat "$test_dir/commands")"
    rm "$test_dir/wrong-key"
    status=0
    install_eza > "$test_dir/output" 2>&1 || status=$?
    assert_equal 44 "$status"
    assert_equal 'apt-get update -qq' "$(tail -n 1 "$test_dir/commands")"
    : > "$test_dir/retry"
    install_eza
    assert_equal 'apt-get install -y eza' "$(tail -n 1 "$test_dir/commands")"
    assert_contains "$(cat "$test_dir/commands")" 'tee /etc/apt/sources.list.d/gierens.list'
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
    assert_contains "$(cat "$test_dir/commands")" 'install_apt_key charm https://repo.charm.sh/apt/gpg.key ED927B38BE981E53CA09153D03BBF595D4DFD35C'
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
# exactly the pinned key. The fingerprints come from gpg --show-keys in a
# throwaway home, so no ~/.gnupg appears; where gpg is installed, real keys
# check that, and that a second key or no key at all is refused.
test_apt_key_pinning() {
    source "$TEST_REPO_DIR/scripts/bootstrap_tools.sh"
    export DOTFILES_TEST_FIXTURE="$test_dir"
    export TMPDIR="$test_dir/tmp"
    mkdir -p "$TMPDIR"
    local pinned=1548BC8A4B4D2688F9B0DAF7EC29E2090CE3FD43
    curl() {
        local output="" url=""
        printf '%s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/commands"
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -o) output="$2"; shift ;;
                -*) ;;
                *) url="$1" ;;
            esac
            shift
        done
        [ ! -f "$DOTFILES_TEST_FIXTURE/offline" ] || return 22
        printf 'key from %s\n' "$url" > "$output"
    }
    sudo() {
        printf 'sudo %s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/commands"
        case "$1" in
            gpg) cat > "$DOTFILES_TEST_FIXTURE/dearmored" ;;
        esac
    }
    gpg() { echo 'gpg runs only through the mocked key_fingerprints here' >&2; return 99; }
    key_fingerprints() { cat "$DOTFILES_TEST_FIXTURE/fingerprints"; }
    # The pinned key: dearmored into the repository's keyring from the file checked.
    printf '%s\n' "$pinned" > "$test_dir/fingerprints"
    install_apt_key gierens https://example.invalid/deb.asc "$pinned"
    assert_equal 'key from https://example.invalid/deb.asc' "$(cat "$test_dir/dearmored")"
    assert_contains "$(cat "$test_dir/commands")" 'sudo gpg --dearmor --yes -o /etc/apt/keyrings/gierens.gpg'
    assert_contains "$(head -n 1 "$test_dir/commands")" '--retry 5'
    assert_equal 0 "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
    # Another key, a second key beside the pinned one, or none: nothing reaches apt.
    local found status
    for found in 0123456789ABCDEF0123456789ABCDEF01234567 "$pinned"$'\n'0123456789ABCDEF0123456789ABCDEF01234567 ''; do
        printf '%s' "$found" > "$test_dir/fingerprints"
        : > "$test_dir/commands"
        status=0
        install_apt_key gierens https://example.invalid/deb.asc "$pinned" > "$test_dir/output" 2>&1 || status=$?
        assert_equal 1 "$status"
        assert_contains "$(cat "$test_dir/output")" 'is not the one pinned for the gierens repository'
        assert_contains "$(cat "$test_dir/output")" "expected $pinned"
        assert_equal 0 "$(grep -c '^sudo' "$test_dir/commands" || :)"
    done
    assert_contains "$(cat "$test_dir/output")" 'received no OpenPGP key'
    # A failed download and a missing gpg stop before sudo as well.
    printf '%s\n' "$pinned" > "$test_dir/fingerprints"
    : > "$test_dir/offline"
    : > "$test_dir/commands"
    status=0
    install_apt_key gierens https://example.invalid/deb.asc "$pinned" > "$test_dir/output" 2>&1 || status=$?
    assert_equal 22 "$status"
    assert_equal 0 "$(grep -c '^sudo' "$test_dir/commands" || :)"
    rm "$test_dir/offline"
    unset -f gpg
    command() {
        case "$*" in
            '-v gpg') return 1 ;;
            *) builtin command "$@" ;;
        esac
    }
    status=0
    install_apt_key gierens https://example.invalid/deb.asc "$pinned" > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'gnupg is not installed'
    unset -f command
    # Sourcing again brings back the real key_fingerprints.
    source "$TEST_REPO_DIR/scripts/bootstrap_tools.sh"
    if ! command -v gpg >/dev/null 2>&1; then
        echo "  (gpg is not installed; skipped the real-key part)"
        return 0
    fi
    # Real keys: one fingerprint per key, primaries only, and no keyring left behind.
    local keyring="$test_dir/keyring" fpr_one fpr_two
    mkdir -m 700 "$keyring"
    GNUPGHOME="$keyring" gpg --batch --quiet --passphrase '' --quick-gen-key 'Fixture One <one@example.invalid>' ed25519 cert,sign never 2>/dev/null
    GNUPGHOME="$keyring" gpg --batch --quiet --passphrase '' --quick-gen-key 'Fixture Two <two@example.invalid>' ed25519 cert,sign never 2>/dev/null
    fpr_one="$(GNUPGHOME="$keyring" gpg --batch --with-colons --list-keys one@example.invalid | awk -F: '$1 == "fpr" { print $10; exit }')"
    fpr_two="$(GNUPGHOME="$keyring" gpg --batch --with-colons --list-keys two@example.invalid | awk -F: '$1 == "fpr" { print $10; exit }')"
    GNUPGHOME="$keyring" gpg --batch --armor --export one@example.invalid > "$test_dir/one.asc"
    GNUPGHOME="$keyring" gpg --batch --armor --export one@example.invalid two@example.invalid > "$test_dir/both.asc"
    printf 'not a key\n' > "$test_dir/garbage.asc"
    local home="$test_dir/home"
    mkdir -p "$home"
    assert_equal "$fpr_one" "$(HOME="$home" key_fingerprints "$test_dir/one.asc")"
    assert_equal "$fpr_one"$'\n'"$fpr_two" "$(HOME="$home" key_fingerprints "$test_dir/both.asc")"
    assert_equal '' "$(HOME="$home" key_fingerprints "$test_dir/garbage.asc" 2>/dev/null || :)"
    GNUPGHOME="$keyring" gpgconf --kill all 2>/dev/null || :
    [ ! -e "$home/.gnupg" ]
    assert_equal 0 "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
}

# Held packages are left out of every apt-get install: one with an upgrade
# makes the whole command fail. Updating, the package list is installed the
# same way, which upgrades it, and the repository packages are upgraded in place.
test_apt_held_packages_left_alone() {
    source "$TEST_REPO_DIR/scripts/install_packages.sh"
    export DOTFILES_TEST_FIXTURE="$test_dir"
    check_linux_distribution() { return 0; }
    parse_list() { printf 'tmux\nbat\nfzf\n'; }
    apt-mark() { [ "$1" = showhold ] && cat "$DOTFILES_TEST_FIXTURE/held"; }
    sudo() {
        printf '%s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/commands"
        case "$1" in
            gpg|tee) cat >/dev/null ;;
        esac
        case "$*" in
            *--only-upgrade*) [ -f "$DOTFILES_TEST_FIXTURE/retry" ] || return 57 ;;
        esac
    }
    printf 'bat\nunrelated\n' > "$test_dir/held"
    install_linux > "$test_dir/output"
    assert_equal $'apt-get update -qq\napt-get install -y tmux fzf' "$(cat "$test_dir/commands")"
    assert_contains "$(cat "$test_dir/output")" 'held, left alone: bat (sudo apt-mark unhold bat to upgrade it)'
    : > "$test_dir/commands"
    export DOTFILES_UPDATE=1
    install_linux > "$test_dir/output"
    assert_equal $'apt-get update -qq\napt-get install -y tmux fzf' "$(cat "$test_dir/commands")"
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
    install_apt_key() { :; }
    printf '\n' > "$test_dir/held"
    : > "$test_dir/commands"
    install_charm_tools > "$test_dir/output"
    assert_equal 'apt-get install -y glow gum' "$(tail -n 1 "$test_dir/commands")"
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
    : > "$test_dir/update-retry"
    bootstrap_tmux "$test_dir/tpm" > "$test_dir/output"
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
    : > "$test_dir/update-retry"
    bootstrap_zinit "$test_dir/zinit" > "$test_dir/output"
    assert_equal 2 "$(wc -l < "$test_dir/update-runs" | tr -d ' ')"
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
    [ -x "$test_dir/bin/first" ] && [ -x "$test_dir/bin/second" ]
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
    # A helper from elsewhere on PATH is left alone; only the bootstrap's copy is replaced.
    printf 'v1.0.0\n' > "$test_dir/latest"
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
        local output="" url="" write_out=""
        printf '%s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/calls"
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -o) output="$2"; shift ;;
                -w) write_out="$2"; shift ;;
                -H)
                    # A header read from stdin is how a token arrives.
                    if [ "$2" = @- ]; then
                        cat > "$DOTFILES_TEST_FIXTURE/stdin"
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
        for asset in nodigest.tar.gz sha512.tar.gz absent.tar.gz; do
            status=0
            release_asset_digest owner/tool v1.2.3 "$asset" > "$test_dir/output" 2>&1 || status=$?
            assert_equal 1 "$status"
            assert_contains "$(cat "$test_dir/output")" "lists no SHA-256 digest for $asset"
        done
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
    # The release binary records its self-updates.
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$DOTFILES_TEST_FIXTURE/self-updates"\n[ -f "$DOTFILES_TEST_FIXTURE/self-update-ok" ] || exit 62\n' > "$test_dir/mise-release"
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
    cmp -s "$test_dir/mise-release" "$test_dir/bin/mise" && [ -x "$test_dir/bin/mise" ]
    # mise updates itself, so no tag is recorded for it.
    [ ! -e "$XDG_STATE_HOME/dotfiles/releases/jdx/mise" ] && [ ! -e "$test_dir/shells" ]
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
    assert_equal $'self-update --yes\nself-update --yes' "$(cat "$test_dir/self-updates")"
    rm "$test_dir/bin/mise"
    : > "$test_dir/mise-present"
    bootstrap_mise_binary > "$test_dir/output"
    assert_contains "$(cat "$test_dir/output")" 'mise at /opt/homebrew/bin/mise was not installed by the bootstrap; left alone'
    assert_equal 2 "$(wc -l < "$test_dir/self-updates" | tr -d ' ')"
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
        printf '%s in %s\n' "$*" "$PWD" >> "$DOTFILES_TEST_FIXTURE/mise-commands"
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
    [ ! -e "$test_dir/opt" ] && [ ! -e "$test_dir/bin/nvim" ]
    assert_equal 0 "$(find "$TMPDIR" -maxdepth 1 -name 'dotfiles-nvim.*' | wc -l | tr -d ' ')"
    : > "$test_dir/retry"
    install_neovim_release > "$test_dir/output"
    assert_equal 'https://github.com/neovim/neovim/releases/download/v0.12.6/nvim-linux-x86_64.tar.gz' "$(cat "$test_dir/downloads")"
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
    [ ! -e "$test_dir/opt/nvim/stale-file" ] && [ -x "$test_dir/opt/nvim/bin/nvim" ]
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
    install_tree_sitter_cli > "$test_dir/output"
    assert_contains "$(cat "$test_dir/output")" 'Neovim keeps skipping the parsers'
    assert_equal 1 "$(wc -l < "$test_dir/downloads" | tr -d ' ')"
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
    [ -x "$test_dir/bin/tree-sitter" ] && [ ! -e "$record" ]
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
    [ ! -e "$font_dir" ] && [ ! -e "$test_dir/data/fonts/.CaskaydiaCove.new" ]
    assert_equal 0 "$(find "$TMPDIR" -maxdepth 1 -name 'dotfiles-font.*' | wc -l | tr -d ' ')"
    : > "$test_dir/retry"
    install_nerd_font > "$test_dir/output"
    assert_equal 'https://github.com/ryanoasis/nerd-fonts/releases/download/v3.4.0/CascadiaCode.tar.xz' "$(cat "$test_dir/downloads")"
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
    [ -f "$font_dir/stale.ttf" ] && [ -f "$font_dir/.installed-by-dotfiles" ] && [ ! -e "$test_dir/data/fonts/.CaskaydiaCove.old" ]
    rm "$test_dir/cache-broken"
    install_nerd_font > "$test_dir/output"
    [ ! -e "$font_dir/stale.ttf" ] && [ -f "$font_dir/CaskaydiaCoveNerdFontMono-Bold.ttf" ] && [ ! -e "$test_dir/data/fonts/.CaskaydiaCove.old" ]
    # A previous directory an interrupted run left aside is put back.
    mv "$font_dir" "$test_dir/data/fonts/.CaskaydiaCove.old"
    install_nerd_font > "$test_dir/output"
    assert_contains "$(cat "$test_dir/output")" 'already installed'
    [ -f "$font_dir/CaskaydiaCoveNerdFontMono-Bold.ttf" ] && [ ! -e "$test_dir/data/fonts/.CaskaydiaCove.old" ]
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
    [ -f "$font_dir/.installed-by-dotfiles" ] && [ ! -e "$test_dir/data/fonts/.CaskaydiaCove.new" ]
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
    # Both plugins are cloned at the pinned (older) commit, not at the branch head.
    run_plugins
    assert_equal "${first[alpha]}" "$(git -C "$fx/data/nvim/lazy/alpha" rev-parse HEAD)"
    assert_equal "${first[beta]}" "$(git -C "$fx/data/nvim/lazy/beta" rev-parse HEAD)"
    assert_contains "$(cat "$fx/output")" 'ok plugin beta'
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
                    printf 'missing plugin gitsigns.nvim\nstale plugin which-key.nvim\nmissing parser yaml\nmissing package marksman\nskipped parser python (no C compiler or tree-sitter CLI; see the README)\n'
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
    [ -s "$test_dir/cache/dotfiles/carapace.zsh" ] && [ -s "$test_dir/cache/dotfiles/atuin.zsh" ] && [ -s "$test_dir/cache/dotfiles/direnv.zsh" ]
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
        gitconfig_guard_creates_once
        link_backups_and_collisions
        link_broken_wrong_and_relocated
        link_retires_moved_sources
        link_failed_replacement
        theme_switch_round_trip
        environment_discovery
        package_index_failure
        macos_font_install_and_repair
        macos_formulae_survive_stdin_consumers
        macos_app_cask_detection
        install_stages_and_failure_reporting
        update_stages_and_failure_reporting
        eza_index_and_download_failures
        apt_held_packages_left_alone
        apt_key_pinning
        macos_update_upgrades_declared
        script_installers_install_and_update
        github_release_install
        github_release_update
        release_download_verification
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
    if command -v tmux >/dev/null 2>&1; then
        tests+=(tmux_config_loads_and_errors_are_reported)
    else
        echo "  SKIP tmux_config_loads_and_errors_are_reported (tmux is not installed)."
    fi
    if command -v nvim >/dev/null 2>&1; then
        tests+=(nvim_config_check nvim_bootstrap_update)
    else
        echo "  SKIP nvim_config_check and nvim_bootstrap_update (nvim is not installed)."
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
    # each test chooses for itself whether it updates.
    export XDG_STATE_HOME="$test_dir/state"
    unset DOTFILES_UPDATE
    "test_$1"
fi
