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
    (cd "$TEST_REPO_DIR" && tar -cf - config home docs) | tar -xf - -C "$test_dir/repo"
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

test_eza_index_and_download_failures() {
    source "$TEST_REPO_DIR/scripts/bootstrap_tools.sh"
    command() {
        case "$*" in
            '-v eza'|'-v oh-my-posh'|'-v zoxide') return 1 ;;
            *) builtin command "$@" ;;
        esac
    }
    curl() { printf 'fixture signing key\n'; }
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
    local status=0
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
    assert_contains "$(cat "$test_dir/commands")" 'gpg --dearmor --yes -o /etc/apt/keyrings/charm.gpg'
    command() {
        case "$*" in
            '-v glow'|'-v gum') return 0 ;;
            '-v oh-my-posh'|'-v zoxide') return 1 ;;
            *) builtin command "$@" ;;
        esac
    }
    : > "$test_dir/commands"
    install_charm_tools
    assert_equal '' "$(cat "$test_dir/commands")"
    curl() { return 45; }
    # Consume only fixture content: never execute downloaded commands in tests.
    bash() { cat >/dev/null; }
    sh() { cat >/dev/null; }
    status=0
    bootstrap_oh_my_posh > "$test_dir/output" 2>&1 || status=$?
    assert_equal 45 "$status"
    status=0
    bootstrap_zoxide > "$test_dir/output" 2>&1 || status=$?
    assert_equal 45 "$status"
    # A new account has no local bin directory yet, and the oh-my-posh
    # installer refuses a missing one; both installers get the directory.
    export DOTFILES_LOCAL_BIN="$test_dir/new/bin"
    curl() { printf 'echo fixture installer\n'; }
    bash() { cat >/dev/null; printf 'bash %s\n' "$*" >> "$test_dir/installers"; }
    sh() { cat >/dev/null; printf 'sh %s\n' "$*" >> "$test_dir/installers"; }
    bootstrap_oh_my_posh > "$test_dir/output"
    [ -d "$test_dir/new/bin" ]
    bootstrap_zoxide > "$test_dir/output"
    assert_equal "bash -s -- -d $test_dir/new/bin
sh -s -- --bin-dir $test_dir/new/bin" "$(cat "$test_dir/installers")"
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
}

test_zinit_plugin_failure_and_retry() {
    source "$TEST_REPO_DIR/scripts/bootstrap_tools.sh"
    mkdir -p "$test_dir/zinit"
    export DOTFILES_TEST_FIXTURE="$test_dir"
    cat > "$test_dir/zinit/zinit.zsh" <<'ZINIT'
zinit() {
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
}

test_github_release_install() {
    source "$TEST_REPO_DIR/scripts/bootstrap_tools.sh"
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
    export DOTFILES_TEST_FIXTURE="$test_dir"
    export DOTFILES_LOCAL_BIN="$test_dir/bin"
    command() {
        case "$*" in
            '-v mise') [ -f "$DOTFILES_TEST_FIXTURE/mise-present" ] ;;
            *) builtin command "$@" ;;
        esac
    }
    curl() {
        printf '%s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/commands"
        [ -f "$DOTFILES_TEST_FIXTURE/retry" ] || return 45
        printf 'installer script\n'
    }
    # Consume the fixture only: downloaded content is never executed in tests.
    sh() {
        local input
        input="$(cat)"
        [ -n "$input" ] || return 0
        printf '%s\n' "$MISE_INSTALL_PATH" > "$DOTFILES_TEST_FIXTURE/install-path"
        : > "$DOTFILES_TEST_FIXTURE/mise-present"
    }
    local status=0
    bootstrap_mise_binary > "$test_dir/output" 2>&1 || status=$?
    assert_equal 45 "$status"
    [ ! -f "$test_dir/mise-present" ]
    : > "$test_dir/retry"
    bootstrap_mise_binary
    assert_equal "$test_dir/bin/mise" "$(cat "$test_dir/install-path")"
    : > "$test_dir/commands"
    bootstrap_mise_binary
    assert_equal '' "$(cat "$test_dir/commands")"
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
}

test_neovim_release_install() {
    source "$TEST_REPO_DIR/scripts/bootstrap_tools.sh"
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
        esac
    }
    mise() { [ "$1 $2" = 'which node' ] && [ -f "$DOTFILES_TEST_FIXTURE/node-present" ] && printf '%s/node/bin/node\n' "$DOTFILES_TEST_FIXTURE"; }
    local check='--headless -c lua require("dotfiles.bootstrap").check() -c cquit 1'
    local plugins='--headless -c lua require("dotfiles.bootstrap").plugins() -c cquit 1'
    local install='--headless -c lua require("dotfiles.bootstrap").install() -c cquit 1'
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
    # No CLI at all is installed too; a release that is still too old is refused.
    rm "$test_dir/cli-on-path" "$test_dir/bin/tree-sitter"
    install_tree_sitter_cli > "$test_dir/output"
    [ -x "$test_dir/bin/tree-sitter" ]
    printf 'old-asset.zip\n' > "$test_dir/serve"
    local status=0
    install_tree_sitter_cli > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" '(0.25.9) is older than 0.26.1'
    assert_equal 0.25.9 "$(dotfiles_tree_sitter_version "$test_dir/bin/tree-sitter")"
    printf '#!/bin/sh\necho "not a cli"\n' > "$test_dir/bin/tree-sitter"
    if dotfiles_tree_sitter_version "$test_dir/bin/tree-sitter"; then
        echo "A version was read from unrelated output." >&2
        return 1
    fi
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
        eza_index_and_download_failures
        github_release_install
        fd_link_for_debian
        mise_bootstrap_and_runtimes
        yazi_flavors_install_and_retry
        neovim_release_install
        tree_sitter_cli_install
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
        tests+=(nvim_config_check)
    else
        echo "  SKIP nvim_config_check (nvim is not installed)."
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
    "test_$1"
fi
