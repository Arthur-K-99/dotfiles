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
    assert_equal macchiato "$(theme_current)"
    theme_main --check > "$test_dir/output"
    theme_main mocha > "$test_dir/output"
    assert_equal mocha "$(cat "$test_dir/repo/config/catppuccin/flavor")"
    grep -q "@catppuccin_flavor 'mocha'" "$test_dir/repo/config/tmux/tmux.conf"
    grep -q -- '--theme="Catppuccin Mocha"' "$test_dir/repo/config/bat/config"
    grep -q 'theme = light:Catppuccin Latte,dark:Catppuccin Mocha' "$test_dir/repo/config/ghostty/config"
    grep -q 'features = catppuccin-mocha' "$test_dir/repo/config/git/config"
    grep -q 'name = "catppuccin-mocha-blue"' "$test_dir/repo/config/atuin/config.toml"
    grep -q 'dark = "catppuccin-mocha"' "$test_dir/repo/config/yazi/theme.toml"
    grep -q 'light = "catppuccin-latte"' "$test_dir/repo/config/yazi/theme.toml"
    grep -q 'vivid generate catppuccin-mocha' "$test_dir/repo/home/.zshrc"
    grep -q '"name": "Catppuccin Mocha"' "$test_dir/repo/config/windows-terminal/fragment.json"
    grep -q '"background": "#1E1E2E"' "$test_dir/repo/config/windows-terminal/fragment.json"
    grep -q '"colorScheme": "Catppuccin Mocha"' "$test_dir/repo/config/windows-terminal/fragment.json"
    grep -q 'bg:#1e1e2e' "$test_dir/repo/home/.zshrc"
    grep -q 'bg:#1e1e2e' "$test_dir/repo/config/powershell/profile.ps1"
    grep -q '48;2;49;50;68' "$test_dir/repo/config/powershell/profile.ps1"
    grep -q '"blue": "#89B4FA"' "$test_dir/repo/config/oh-my-posh/config.omp.json"
    grep -q '"keys": "#89b4fa"' "$test_dir/repo/config/fastfetch/config.jsonc"
    grep -q 'Catppuccin Mocha hex values' "$test_dir/repo/config/fastfetch/config.jsonc"
    grep -q 'directory: { foreground: "#89B4FA" }' "$test_dir/repo/config/eza/theme.yml"
    grep -q "activeBorderColor:" "$test_dir/repo/config/lazygit/config.yml"
    grep -q "'#89b4fa'" "$test_dir/repo/config/lazygit/config.yml"
    grep -q 'themes-mergable/mocha/blue.yml' "$test_dir/repo/config/lazygit/config.yml"
    grep -q 'Catppuccin \*\*Mocha\*\*' "$test_dir/repo/docs/theming.md"
    grep -q '`#89B4FA`' "$test_dir/repo/docs/theming.md"
    # No Macchiato value survives anywhere the switcher manages, in either case.
    local file
    for file in $(theme_hex_files); do
        if grep -i -q -E '#(24273a|cad3f5|8aadf4|363a4f)' "$test_dir/repo/$file"; then
            echo "$file still carries Macchiato colors." >&2
            return 1
        fi
    done
    theme_main --check > "$test_dir/output"
    assert_contains "$(cat "$test_dir/output")" 'agrees on mocha'
    # Latte is also the light-mode flavor: Ghostty and yazi keep it there.
    theme_main latte > "$test_dir/output"
    grep -q 'theme = light:Catppuccin Latte,dark:Catppuccin Latte' "$test_dir/repo/config/ghostty/config"
    grep -q 'light = "catppuccin-latte"' "$test_dir/repo/config/yazi/theme.toml"
    grep -q 'dark = "catppuccin-latte"' "$test_dir/repo/config/yazi/theme.toml"
    grep -q '"background": "#EFF1F5"' "$test_dir/repo/config/windows-terminal/fragment.json"
    theme_main mocha > "$test_dir/output"
    grep -q 'theme = light:Catppuccin Latte,dark:Catppuccin Mocha' "$test_dir/repo/config/ghostty/config"
    grep -q 'light = "catppuccin-latte"' "$test_dir/repo/config/yazi/theme.toml"
    # Switching back restores every byte.
    theme_main macchiato > "$test_dir/output"
    diff -r "$test_dir/original" "$test_dir/repo"
    # Unknown flavors are refused and an inconsistent tree fails the check.
    local status=0
    theme_main mint > "$test_dir/output" 2>&1 || status=$?
    assert_equal 2 "$status"
    diff -r "$test_dir/original" "$test_dir/repo"
    printf 'mocha\n' > "$test_dir/repo/config/catppuccin/flavor"
    status=0
    theme_main --check > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" "does not contain"
    printf 'macchiato\n' > "$test_dir/repo/config/catppuccin/flavor"
    sed -e 's/#8AADF4/#89B4FA/' "$test_dir/original/config/eza/theme.yml" > "$test_dir/repo/config/eza/theme.yml"
    status=0
    theme_main --check > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'still carries a mocha color'
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
    install_github_release owner/multi 'multi_{version}_linux_{arch_go}_{arch_deb}_{arch_amd64}.zip' first second
    assert_equal 'https://github.com/owner/multi/releases/download/v1.2.3/multi_1.2.3_linux_x86_64_amd64_amd64.zip' "$(tail -n 1 "$test_dir/downloads")"
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
    install_github_release owner/arm 'arm-{arch}-{arch_go}-{arch_deb}-{arch_amd64}' armtool
    assert_contains "$(tail -n 1 "$test_dir/downloads")" 'arm-aarch64-arm64-arm64-aarch64'
    assert_equal bare "$("$test_dir/bin/armtool")"
    printf 'mips\n' > "$test_dir/arch"
    status=0
    install_github_release owner/other 'other-{arch}.tar.gz' othertool > "$test_dir/output" 2>&1 || status=$?
    assert_equal 1 "$status"
    assert_contains "$(cat "$test_dir/output")" 'Unsupported architecture: mips'
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
    # The flavors come from config/yazi/theme.toml: the dark one, then the light one.
    local dark light
    read -r dark light <<<"$(dotfiles_yazi_flavors "$TEST_REPO_DIR/config/yazi/theme.toml" | tr '\n' ' ')"
    assert_equal catppuccin-latte "$light"
    assert_equal "pkg add yazi-rs/flavors:$dark
pkg add yazi-rs/flavors:$light" "$(tail -n 2 "$test_dir/commands")"
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
    check_absent "legacy file" "$test_dir/wrong"
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
        mise_bootstrap_and_runtimes
        yazi_flavors_install_and_retry
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
