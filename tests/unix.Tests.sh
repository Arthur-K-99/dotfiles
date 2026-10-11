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
    export NVM_DIR="$test_dir/custom-nvm"
    PATH=/usr/bin:/bin
    dotfiles_init_environment
    assert_equal "$test_dir/apple/bin/dotfiles-fixture-command" "$(command -v dotfiles-fixture-command)"
    assert_contains ":$PATH:" ":$HOME/.local/bin:"
    assert_equal "$test_dir/custom-nvm" "$NVM_DIR"
    assert_equal "$test_dir/custom-nvm" "$(/bin/bash -c 'printf %s "$NVM_DIR"')"
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
    assert_equal 5 "$(wc -l < "$test_dir/plugin-runs" | tr -d ' ')"
    assert_equal Aloxaf/fzf-tab "$(tail -n 1 "$test_dir/plugin-runs")"
}

test_nvm_custom_directory_and_retry() {
    source "$TEST_REPO_DIR/scripts/bootstrap_tools.sh"
    mkdir -p "$test_dir/custom-nvm"
    export NVM_DIR="$test_dir/custom-nvm"
    export DOTFILES_TEST_FIXTURE="$test_dir"
    cat > "$NVM_DIR/nvm.sh" <<'NVM'
nvm() {
    printf '%s\n' "$*" >> "$DOTFILES_TEST_FIXTURE/nvm-commands"
    case "$1" in
        version)
            if [ -f "$DOTFILES_TEST_FIXTURE/default" ]; then
                printf 'v22.0.0\n'
            else
                printf 'N/A\n'
                return 3
            fi
            ;;
        install) [ -f "$DOTFILES_TEST_FIXTURE/retry" ] || return 48 ;;
        alias) : > "$DOTFILES_TEST_FIXTURE/default" ;;
        use) [ -f "$DOTFILES_TEST_FIXTURE/default" ] ;;
    esac
}
NVM
    git() { echo 'Unexpected download with existing nvm manager.' >&2; return 99; }
    local status=0
    bootstrap_nvm > "$test_dir/output" 2>&1 || status=$?
    assert_equal 48 "$status"
    [ ! -f "$test_dir/default" ]
    : > "$test_dir/retry"
    bootstrap_nvm
    assert_contains "$(cat "$test_dir/nvm-commands")" 'alias default lts/*'
    : > "$test_dir/nvm-commands"
    bootstrap_nvm
    assert_equal $'version default\nuse --silent default' "$(cat "$test_dir/nvm-commands")"
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
    mkdir "$test_dir/nvm"
    export NVM_DIR="$test_dir/nvm"
    cat > "$NVM_DIR/nvm.sh" <<'NVM'
nvm() { printf 'N/A\n'; return 3; }
NVM
    # A system-wide Node.js must not hide a missing nvm default.
    node() { return 0; }
    npm() { return 0; }
    failures=0
    check_nvm_default
    assert_equal 1 "$failures"
    cat > "$NVM_DIR/nvm.sh" <<'NVM'
nvm() {
    if [ "$1" = version ]; then printf 'v22.0.0\n'; fi
    return 0
}
NVM
    failures=0
    check_nvm_default
    assert_equal 0 "$failures"
}

test_bat_theme_install_and_skip() {
    source "$TEST_REPO_DIR/scripts/bootstrap_tools.sh"
    export DOTFILES_TEST_FIXTURE="$test_dir"
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
                    printf 'Catppuccin Macchiato\n'
                fi
                ;;
            '--config-dir') printf '%s/bat-config\n' "$DOTFILES_TEST_FIXTURE" ;;
            'cache --build')
                [ -f "$DOTFILES_TEST_FIXTURE/bat-config/themes/Catppuccin Macchiato.tmTheme" ] || return 50
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
    [ -f "$test_dir/bat-config/themes/Catppuccin Macchiato.tmTheme" ]
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

test_zsh_nvm_lazy_load() {
    local zsh_binary
    zsh_binary="$(command -v zsh)"
    mkdir -p "$test_dir/fixture" "$test_dir/nvm/alias/lts" "$test_dir/nvm/versions/node/v24.0.0/bin" \
        "$test_dir/zdot" "$test_dir/data"
    printf 'lts/*\n' > "$test_dir/nvm/alias/default"
    printf 'lts/krypton\n' > "$test_dir/nvm/alias/lts/*"
    printf 'v24.0.0\n' > "$test_dir/nvm/alias/lts/krypton"
    cat > "$test_dir/nvm/nvm.sh" <<'NVM'
export DOTFILES_TEST_NVM_LOADED=yes
nvm() { printf 'real nvm %s\n' "$*" > "$DOTFILES_TEST_FIXTURE/nvm-call"; }
NVM
    render_portable_profile "$test_dir/profile.zsh"
    export DOTFILES_TEST_FIXTURE="$test_dir"
    # A resolvable default: Node is on PATH at once and nvm itself loads on first use.
    DOTFILES_TEST_HOME="$test_dir/fixture" DOTFILES_TEST_PROFILE="$test_dir/profile.zsh" \
        NVM_DIR="$test_dir/nvm" XDG_DATA_HOME="$test_dir/data" ZDOTDIR="$test_dir/zdot" PATH=/usr/bin:/bin \
        "$zsh_binary" -df -c '
            autoload() { :; }
            compinit() { :; }
            source "$DOTFILES_TEST_PROFILE" || exit 1
            [[ "$path[1]" == "$NVM_DIR/versions/node/v24.0.0/bin" ]] || { print "unexpected PATH head: $path[1]"; exit 1; }
            [[ -z "$DOTFILES_TEST_NVM_LOADED" ]] || { print "nvm was loaded eagerly"; exit 1; }
            [[ "$(whence -w nvm)" == "nvm: function" ]] || { print "nvm wrapper is missing"; exit 1; }
            nvm ls --no-colors
            [[ "$DOTFILES_TEST_NVM_LOADED" == yes ]] || { print "nvm did not load on first use"; exit 1; }
        '
    assert_equal 'real nvm ls --no-colors' "$(cat "$test_dir/nvm-call")"
    # An unresolvable default (a partial version) loads nvm immediately instead.
    printf '24\n' > "$test_dir/nvm/alias/default"
    DOTFILES_TEST_HOME="$test_dir/fixture" DOTFILES_TEST_PROFILE="$test_dir/profile.zsh" \
        NVM_DIR="$test_dir/nvm" XDG_DATA_HOME="$test_dir/data" ZDOTDIR="$test_dir/zdot" PATH=/usr/bin:/bin \
        "$zsh_binary" -df -c '
            autoload() { :; }
            compinit() { :; }
            source "$DOTFILES_TEST_PROFILE" || exit 1
            [[ "$DOTFILES_TEST_NVM_LOADED" == yes ]] || { print "nvm was not loaded for an unresolved alias"; exit 1; }
            [[ "$path[1]" != "$NVM_DIR/versions/node/v24.0.0/bin" ]] || { print "unresolved alias still changed PATH"; exit 1; }
        '
}

test_zsh_portable_overrides() {
    local zsh_binary
    zsh_binary="$(command -v zsh)"
    mkdir -p "$test_dir/fixture" "$test_dir/nvm" "$test_dir/zdot" "$test_dir/data"
    printf 'export DOTFILES_TEST_NVM_LOADED=yes\n' > "$test_dir/nvm/nvm.sh"
    render_portable_profile "$test_dir/profile.zsh"
    DOTFILES_TEST_HOME="$test_dir/fixture" DOTFILES_TEST_PROFILE="$test_dir/profile.zsh" \
        NVM_DIR="$test_dir/nvm" XDG_DATA_HOME="$test_dir/data" ZDOTDIR="$test_dir/zdot" \
        SSH_AUTH_SOCK="$test_dir/original-agent" PATH=/usr/bin:/bin \
        "$zsh_binary" -df -c '
            autoload() { :; }
            compinit() { :; }
            source "$DOTFILES_TEST_PROFILE"
            [[ "$SSH_AUTH_SOCK" == "${DOTFILES_TEST_HOME:h}/original-agent" ]] || exit 1
            [[ "$NVM_DIR" == "${DOTFILES_TEST_HOME:h}/nvm" ]] || exit 1
            [[ "$DOTFILES_TEST_NVM_LOADED" == yes ]] || exit 1
        '
    cat > "$test_dir/fixture/.zshrc.local" <<'LOCAL'
[[ "$DOTFILES_TEST_NVM_LOADED" == yes ]] || return 1
export SSH_AUTH_SOCK="$DOTFILES_TEST_HOME/local-agent"
export NVM_DIR="$DOTFILES_TEST_HOME/local-nvm"
export EZA_CONFIG_DIR="$DOTFILES_TEST_HOME/local-eza"
LOCAL
    DOTFILES_TEST_HOME="$test_dir/fixture" DOTFILES_TEST_PROFILE="$test_dir/profile.zsh" \
        NVM_DIR="$test_dir/nvm" XDG_DATA_HOME="$test_dir/data" ZDOTDIR="$test_dir/zdot" \
        SSH_AUTH_SOCK="$test_dir/original-agent" PATH=/usr/bin:/bin \
        "$zsh_binary" -df -c '
            autoload() { :; }
            compinit() { :; }
            source "$DOTFILES_TEST_PROFILE" || exit 1
            [[ "$SSH_AUTH_SOCK" == "$DOTFILES_TEST_HOME/local-agent" ]] || exit 1
            [[ "$NVM_DIR" == "$DOTFILES_TEST_HOME/local-nvm" ]] || exit 1
            [[ "$EZA_CONFIG_DIR" == "$DOTFILES_TEST_HOME/local-eza" ]] || exit 1
        '
}

run_tests() {
    local test_name output
    local passed=0
    local failed=0
    local tests=(
        syntax_every_file
        link_fresh_and_repeat
        link_backups_and_collisions
        link_broken_wrong_and_relocated
        link_failed_replacement
        environment_discovery
        package_index_failure
        macos_font_install_and_repair
        install_stages_and_failure_reporting
        eza_index_and_download_failures
        tmux_plugin_failure_and_retry
        nvm_custom_directory_and_retry
        bat_theme_install_and_skip
        doctor_rejects_stale_configuration
    )
    if command -v zsh >/dev/null 2>&1; then
        tests+=(zinit_plugin_failure_and_retry zsh_nvm_lazy_load zsh_portable_overrides)
    else
        echo "  SKIP zinit_plugin_failure_and_retry, zsh_nvm_lazy_load and zsh_portable_overrides (zsh is not installed)."
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
