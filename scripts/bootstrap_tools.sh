#!/usr/bin/env bash

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/environment.sh
source "$DOTFILES_DIR/scripts/lib/environment.sh"

bootstrap_zinit() {
    local zinit_home="${1:-${XDG_DATA_HOME:-$HOME/.local/share}/zinit/zinit.git}"
    if [ ! -r "$zinit_home/zinit.zsh" ]; then
        echo "Installing Zinit..."
        mkdir -p "$(dirname "$zinit_home")" || return
        git clone --depth=1 https://github.com/zdharma-continuum/zinit.git "$zinit_home" || return
    else
        echo "Zinit already installed"
    fi

    echo "Installing Zinit plugins..."
    ZINIT_HOME="$zinit_home" zsh -c '
        source "$ZINIT_HOME/zinit.zsh" || exit
        zinit light zsh-users/zsh-syntax-highlighting || exit
        zinit light zsh-users/zsh-completions || exit
        zinit light zsh-users/zsh-autosuggestions || exit
        zinit light Aloxaf/fzf-tab || exit
        zinit light olets/zsh-abbr || exit
        zinit light MichaelAquilina/zsh-you-should-use || exit
    '
}

bootstrap_tmux() (
    # TPM installs plugins beside itself. With the configuration at
    # ~/.config/tmux/tmux.conf, TPM itself defaults to this directory.
    local tpm_dir="${1:-${XDG_CONFIG_HOME:-$HOME/.config}/tmux/plugins/tpm}"
    local work_dir socket_path
    if [ ! -x "$tpm_dir/bin/install_plugins" ]; then
        echo "Installing TPM..."
        mkdir -p "$(dirname "$tpm_dir")" || return
        git clone --depth=1 https://github.com/tmux-plugins/tpm "$tpm_dir" || return
    else
        echo "TPM already installed"
    fi

    # TPM consults tmux's environment. A private, sessionless server avoids
    # altering existing user sessions and provides a stable installation path.
    work_dir="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-tmux.XXXXXX")" || return
    socket_path="$work_dir/socket"
    trap 'tmux -S "$socket_path" kill-server >/dev/null 2>&1 || :; rm -rf "$work_dir"' EXIT
    # TPM prefers an XDG config over ~/.tmux.conf. Point its read-only config
    # lookup at this repository so an unrelated user config cannot change it.
    mkdir -p "$work_dir/config/tmux" || return
    ln -s "$DOTFILES_DIR/config/tmux/tmux.conf" "$work_dir/config/tmux/tmux.conf" || return
    tmux -S "$socket_path" -f /dev/null start-server \; \
        set-option -g exit-empty off \; \
        set-environment -g TMUX_PLUGIN_MANAGER_PATH "$(dirname "$tpm_dir")/" || return
    echo "Installing tmux plugins..."
    XDG_CONFIG_HOME="$work_dir/config" TMUX="$socket_path,0,0" "$tpm_dir/bin/install_plugins"
)

bootstrap_oh_my_posh() {
    if ! command -v oh-my-posh &>/dev/null; then
        echo "Installing oh-my-posh..."
        curl -fsSL https://ohmyposh.dev/install.sh | bash -s -- -d "$HOME/.local/bin"
    else
        echo "oh-my-posh already installed"
    fi
}

bootstrap_zoxide() {
    if ! command -v zoxide &>/dev/null; then
        echo "Installing zoxide..."
        curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh
    else
        echo "zoxide already installed"
    fi
}

bootstrap_bat_theme() {
    local bat_command theme_dir theme_file status theme_name theme_url
    theme_name="$(dotfiles_bat_theme "$DOTFILES_DIR/config/bat/config")"
    if [ -z "$theme_name" ]; then
        echo "config/bat/config names no --theme." >&2
        return 1
    fi
    theme_url="https://raw.githubusercontent.com/catppuccin/bat/main/themes/${theme_name// /%20}.tmTheme"
    if command -v bat &>/dev/null; then
        bat_command=bat
    elif command -v batcat &>/dev/null; then
        bat_command=batcat
    else
        echo "bat is not installed; install packages first." >&2
        return 1
    fi
    # bat 0.26+ ships the Catppuccin themes; older distribution packages need the file.
    if "$bat_command" --list-themes 2>/dev/null | grep -q "$theme_name"; then
        echo "bat theme already available"
        return 0
    fi
    echo "Installing bat theme ($theme_name)..."
    theme_dir="$("$bat_command" --config-dir)/themes" || return
    theme_file="$theme_dir/$theme_name.tmTheme"
    mkdir -p "$theme_dir" || return
    curl -fsSL -o "$theme_file.part" "$theme_url" || {
        status=$?
        rm -f "$theme_file.part"
        return "$status"
    }
    mv "$theme_file.part" "$theme_file" || return
    "$bat_command" cache --build >/dev/null || return
    if ! "$bat_command" --list-themes 2>/dev/null | grep -q "$theme_name"; then
        echo "bat does not list '$theme_name' after rebuilding its cache." >&2
        return 1
    fi
}

# --- Linux installers --------------------------------------------------------
# Debian and Ubuntu lack packages for several tools. Three routes cover them,
# in order of preference: a signed third-party apt repository (updates arrive
# with apt), the project's own installer script, and a static binary from the
# latest GitHub release installed into ~/.local/bin (DOTFILES_LOCAL_BIN).

# install_apt_repository <name> <key url> <sources line> <package>...
# Package names double as command names. The sources line must reference
# /etc/apt/keyrings/<name>.gpg.
install_apt_repository() {
    local name="$1" key_url="$2" sources_line="$3"
    shift 3
    local package
    local missing=()
    for package in "$@"; do
        command -v "$package" &>/dev/null || missing+=("$package")
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        echo "$* already installed"
        return 0
    fi
    echo "Installing ${missing[*]} from the $name repository..."
    sudo mkdir -p /etc/apt/keyrings || return
    curl -fsSL "$key_url" | sudo gpg --dearmor --yes -o "/etc/apt/keyrings/$name.gpg" || return
    printf '%s\n' "$sources_line" | sudo tee "/etc/apt/sources.list.d/$name.list" >/dev/null || return
    sudo apt-get update -qq || return
    sudo apt-get install -y "${missing[@]}" || return
}

install_eza() {
    install_apt_repository gierens https://raw.githubusercontent.com/eza-community/eza/main/deb.asc \
        "deb [signed-by=/etc/apt/keyrings/gierens.gpg] https://deb.gierens.de stable main" eza
}

install_charm_tools() {
    install_apt_repository charm https://repo.charm.sh/apt/gpg.key \
        "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" glow gum
}

# Projects spell architectures differently. Prints four words: {arch}
# (x86_64|aarch64), {arch_go} (x86_64|arm64), {arch_deb} (amd64|arm64) and
# {arch_amd64} (amd64|aarch64).
dotfiles_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'x86_64 x86_64 amd64 amd64\n' ;;
        aarch64|arm64) printf 'aarch64 arm64 arm64 aarch64\n' ;;
        *) echo "Unsupported architecture: $(uname -m)" >&2; return 1 ;;
    esac
}

# GitHub redirects releases/latest to releases/tag/<tag>; following the
# redirect avoids the rate-limited API.
github_latest_tag() {
    local url
    url="$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest")" || return
    case "$url" in
        */releases/tag/?*) printf '%s\n' "${url##*/releases/tag/}" ;;
        *) echo "Could not resolve the latest release of $1: $url" >&2; return 1 ;;
    esac
}

# install_github_release <owner/repo> <asset template> <binary>...
# Downloads the latest release asset, extracts it (.tar.gz, .tgz, .tar.xz,
# .zip, or a bare executable) and installs every named binary found inside.
# Templates may use {tag}, {version} (the tag without a leading v), {arch},
# {arch_go}, {arch_deb} and {arch_amd64}. Already-present binaries are skipped.
install_github_release() (
    local repo="$1" template="$2"
    shift 2
    local binary tag version arch_words arch arch_go arch_deb arch_amd64 asset url work extract found bin_dir
    local missing=()
    for binary in "$@"; do
        command -v "$binary" &>/dev/null || missing+=("$binary")
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        echo "$* already installed"
        return 0
    fi
    echo "Installing ${missing[*]} from $repo..."
    tag="$(github_latest_tag "$repo")" || return
    version="${tag#v}"
    arch_words="$(dotfiles_arch)" || return
    read -r arch arch_go arch_deb arch_amd64 <<<"$arch_words"
    asset="${template//\{tag\}/$tag}"
    asset="${asset//\{version\}/$version}"
    asset="${asset//\{arch\}/$arch}"
    asset="${asset//\{arch_go\}/$arch_go}"
    asset="${asset//\{arch_deb\}/$arch_deb}"
    asset="${asset//\{arch_amd64\}/$arch_amd64}"
    url="https://github.com/$repo/releases/download/$tag/$asset"
    work="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-release.XXXXXX")" || return
    trap 'rm -rf "$work"' EXIT
    curl -fsSL -o "$work/$asset" "$url" || return
    extract="$work/extract"
    mkdir -p "$extract" || return
    case "$asset" in
        *.tar.gz|*.tgz) tar -xzf "$work/$asset" -C "$extract" || return ;;
        *.tar.xz) tar -xJf "$work/$asset" -C "$extract" || return ;;
        *.zip) unzip -q "$work/$asset" -d "$extract" || return ;;
        *) cp "$work/$asset" "$extract/${missing[0]}" || return ;;
    esac
    bin_dir="${DOTFILES_LOCAL_BIN:-$HOME/.local/bin}"
    mkdir -p "$bin_dir" || return
    for binary in "${missing[@]}"; do
        found="$(find "$extract" -type f -name "$binary" | head -n 1)"
        if [ -z "$found" ]; then
            echo "$asset does not contain $binary" >&2
            return 1
        fi
        install -m 755 "$found" "$bin_dir/$binary" || return
        [ -x "$bin_dir/$binary" ] || return 1
    done
)

bootstrap_mise_binary() {
    if command -v mise &>/dev/null; then
        echo "mise already installed"
        return 0
    fi
    echo "Installing mise..."
    # mise.run installs a single binary and does not edit shell files.
    curl -fsSL https://mise.run | MISE_INSTALL_PATH="${DOTFILES_LOCAL_BIN:-$HOME/.local/bin}/mise" sh
}

# Debian and Ubuntu install fd as fdfind. The zsh alias covers the shell, but
# tmux's run-shell (the sesh picker's ctrl-f) and scripts never see it, so a
# link named fd goes into the local bin directory when nothing provides fd.
install_fd_link() {
    local bin_dir="${DOTFILES_LOCAL_BIN:-$HOME/.local/bin}" fdfind_path
    if command -v fd &>/dev/null; then
        echo "fd already available"
        return 0
    fi
    if ! fdfind_path="$(command -v fdfind)"; then
        echo "fd-find is not installed; install packages first." >&2
        return 1
    fi
    if [ -e "$bin_dir/fd" ] && [ ! -L "$bin_dir/fd" ]; then
        echo "$bin_dir/fd exists and is not a link; remove it to let the bootstrap link fdfind there." >&2
        return 1
    fi
    echo "Linking fdfind as $bin_dir/fd..."
    mkdir -p "$bin_dir" || return
    ln -sf "$fdfind_path" "$bin_dir/fd" || return
    [ -x "$bin_dir/fd" ] || return 1
}

install_linux_tools() {
    install_eza || return
    install_fd_link || return
    install_charm_tools || return
    bootstrap_zoxide || return
    bootstrap_mise_binary || return
    install_github_release jesseduffield/lazygit 'lazygit_{version}_linux_{arch_go}.tar.gz' lazygit || return
    install_github_release jesseduffield/lazydocker 'lazydocker_{version}_Linux_{arch_go}.tar.gz' lazydocker || return
    install_github_release dandavison/delta 'delta-{version}-{arch}-unknown-linux-gnu.tar.gz' delta || return
    # atuin and yazi publish glibc builds that need glibc 2.39, newer than
    # Debian 12 and Ubuntu 22.04 ship; their musl builds run everywhere.
    install_github_release atuinsh/atuin 'atuin-{arch}-unknown-linux-musl.tar.gz' atuin || return
    install_github_release carapace-sh/carapace-bin 'carapace-bin_{version}_linux_{arch_deb}.tar.gz' carapace || return
    install_github_release sxyazi/yazi 'yazi-{arch}-unknown-linux-musl.zip' yazi ya || return
    install_github_release bootandy/dust 'dust-{tag}-{arch}-unknown-linux-musl.tar.gz' dust || return
    install_github_release dalance/procs 'procs-{tag}-{arch}-linux.zip' procs || return
    install_github_release ducaale/xh 'xh-{tag}-{arch}-unknown-linux-musl.tar.gz' xh || return
    install_github_release tldr-pages/tlrc 'tlrc-{tag}-{arch}-unknown-linux-musl.tar.gz' tldr || return
    install_github_release joshmedeski/sesh 'sesh_Linux_{arch_go}.tar.gz' sesh || return
    # The polyfilled build runs on glibc 2.17+, so Debian 12 is covered; the
    # archive holds usr/bin/fastfetch under a top-level directory.
    install_github_release fastfetch-cli/fastfetch 'fastfetch-linux-{arch_amd64}-polyfilled.tar.gz' fastfetch || return
}

# --- Runtimes and themes ------------------------------------------------------

# mise installs every runtime pinned in config/mise/config.toml (Node.js LTS),
# which the link stage placed at ~/.config/mise/config.toml. It replaces nvm.
bootstrap_runtimes() {
    if ! command -v mise &>/dev/null; then
        echo "mise is not installed; install packages first." >&2
        return 1
    fi
    echo "Installing runtimes with mise..."
    mise install --yes || return
    if ! mise which node >/dev/null 2>&1; then
        echo "mise does not provide node after installing; check ~/.config/mise/config.toml." >&2
        return 1
    fi
}

# yazi flavors are packages cloned by ya into ~/.config/yazi/flavors. The
# first add also records them in package.toml; later machines restore from it.
# The flavor names come from config/yazi/theme.toml, the file yazi reads.
bootstrap_yazi_flavors() {
    local yazi_dir="${XDG_CONFIG_HOME:-$HOME/.config}/yazi"
    local flavor flavors
    if ! command -v ya &>/dev/null; then
        echo "yazi is not installed; install packages first." >&2
        return 1
    fi
    flavors="$(dotfiles_yazi_flavors "$DOTFILES_DIR/config/yazi/theme.toml")"
    if [ -z "$flavors" ]; then
        echo "config/yazi/theme.toml names no flavors." >&2
        return 1
    fi
    for flavor in $flavors; do
        if [ -f "$yazi_dir/flavors/$flavor.yazi/flavor.toml" ]; then
            echo "yazi flavor $flavor already installed"
            continue
        fi
        echo "Installing yazi flavor $flavor..."
        if [ -f "$yazi_dir/package.toml" ] && grep -q "flavors:$flavor" "$yazi_dir/package.toml"; then
            ya pkg install || return
        else
            ya pkg add "yazi-rs/flavors:$flavor" || return
        fi
        if [ ! -f "$yazi_dir/flavors/$flavor.yazi/flavor.toml" ]; then
            echo "ya did not install the $flavor flavor into $yazi_dir/flavors." >&2
            return 1
        fi
    done
}

bootstrap_tools_main() {
    dotfiles_init_environment || return
    bootstrap_zinit || return
    bootstrap_tmux || return
    bootstrap_oh_my_posh || return
    bootstrap_bat_theme || return

    if [ "$(uname)" = "Linux" ]; then
        install_linux_tools || return
    fi
    bootstrap_runtimes || return
    bootstrap_yazi_flavors || return
}

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
    set -euo pipefail
    bootstrap_tools_main "$@"
fi
