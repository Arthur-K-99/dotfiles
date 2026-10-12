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

# The oh-my-posh and zoxide installers write into the local bin directory like
# the release installers below. oh-my-posh's refuses a directory that does not
# exist yet, which is the case on a new Linux account.
bootstrap_oh_my_posh() {
    local bin_dir="${DOTFILES_LOCAL_BIN:-$HOME/.local/bin}"
    if ! command -v oh-my-posh &>/dev/null; then
        echo "Installing oh-my-posh..."
        mkdir -p "$bin_dir" || return
        curl -fsSL https://ohmyposh.dev/install.sh | bash -s -- -d "$bin_dir"
    else
        echo "oh-my-posh already installed"
    fi
}

bootstrap_zoxide() {
    if ! command -v zoxide &>/dev/null; then
        echo "Installing zoxide..."
        curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | \
            sh -s -- --bin-dir "${DOTFILES_LOCAL_BIN:-$HOME/.local/bin}"
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

# Projects spell architectures differently. Prints five words: {arch}
# (x86_64|aarch64), {arch_go} (x86_64|arm64), {arch_deb} (amd64|arm64),
# {arch_amd64} (amd64|aarch64) and {arch_node} (x64|arm64).
dotfiles_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'x86_64 x86_64 amd64 amd64 x64\n' ;;
        aarch64|arm64) printf 'aarch64 arm64 arm64 aarch64 arm64\n' ;;
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
# Installs every named binary that is not on PATH from the latest release
# asset. Templates may use {tag}, {version} (the tag without a leading v),
# {arch}, {arch_go}, {arch_deb}, {arch_amd64} and {arch_node}.
install_github_release() {
    local repo="$1" template="$2"
    shift 2
    local binary
    local missing=()
    for binary in "$@"; do
        command -v "$binary" &>/dev/null || missing+=("$binary")
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        echo "$* already installed"
        return 0
    fi
    echo "Installing ${missing[*]} from $repo..."
    download_github_release "$repo" "$template" "${missing[@]}"
}

# download_github_release <owner/repo> <asset template> <binary>...
# Downloads the latest release asset, extracts it (.tar.gz, .tgz, .tar.xz,
# .zip, or a bare executable) and installs every named binary found inside
# into the local bin directory, whatever PATH already holds: callers such as
# install_tree_sitter_cli decide for themselves when a present binary is too old.
download_github_release() (
    local repo="$1" template="$2"
    shift 2
    local binary tag version arch_words arch arch_go arch_deb arch_amd64 arch_node asset url work extract found bin_dir
    tag="$(github_latest_tag "$repo")" || return
    version="${tag#v}"
    arch_words="$(dotfiles_arch)" || return
    read -r arch arch_go arch_deb arch_amd64 arch_node <<<"$arch_words"
    asset="${template//\{tag\}/$tag}"
    asset="${asset//\{version\}/$version}"
    asset="${asset//\{arch\}/$arch}"
    asset="${asset//\{arch_go\}/$arch_go}"
    asset="${asset//\{arch_deb\}/$arch_deb}"
    asset="${asset//\{arch_amd64\}/$arch_amd64}"
    asset="${asset//\{arch_node\}/$arch_node}"
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
        *) cp "$work/$asset" "$extract/$1" || return ;;
    esac
    bin_dir="${DOTFILES_LOCAL_BIN:-$HOME/.local/bin}"
    mkdir -p "$bin_dir" || return
    for binary in "$@"; do
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

# Debian 12 packages Neovim 0.7, Debian 13 0.10 and Ubuntu 24.04 0.9; the
# configuration needs DOTFILES_NVIM_MINIMUM (lib/environment.sh). The release
# tarball carries the runtime files beside the binary
# (nvim-linux-<arch>/{bin,lib,share}), which install_github_release would
# leave behind, so the tree is unpacked whole into ~/.local/opt/nvim
# (DOTFILES_LOCAL_OPT) and bin/nvim is linked into the local bin directory,
# which precedes /usr/bin on PATH. A Neovim that is already new enough, from
# any source, is kept.
install_neovim_release() (
    local opt_dir="${DOTFILES_LOCAL_OPT:-$HOME/.local/opt}/nvim"
    local bin_dir="${DOTFILES_LOCAL_BIN:-$HOME/.local/bin}"
    local version tag arch_words arch_go asset url work extracted
    if version="$(dotfiles_nvim_version)" && dotfiles_version_at_least "$version" "$DOTFILES_NVIM_MINIMUM"; then
        echo "Neovim $version already installed"
        return 0
    fi
    if [ -e "$bin_dir/nvim" ] && [ ! -L "$bin_dir/nvim" ]; then
        echo "$bin_dir/nvim exists and is not a link; remove it to let the bootstrap install Neovim there." >&2
        return 1
    fi
    echo "Installing Neovim from the GitHub release${version:+ (found $version, need $DOTFILES_NVIM_MINIMUM)}..."
    tag="$(github_latest_tag neovim/neovim)" || return
    arch_words="$(dotfiles_arch)" || return
    read -r _ arch_go _ <<<"$arch_words"
    asset="nvim-linux-$arch_go.tar.gz"
    url="https://github.com/neovim/neovim/releases/download/$tag/$asset"
    work="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-nvim.XXXXXX")" || return
    trap 'rm -rf "$work"' EXIT
    curl -fsSL -o "$work/$asset" "$url" || return
    mkdir -p "$work/extract" || return
    tar -xzf "$work/$asset" -C "$work/extract" || return
    extracted="$(find "$work/extract" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    if [ -z "$extracted" ] || [ ! -x "$extracted/bin/nvim" ]; then
        echo "$asset does not contain bin/nvim" >&2
        return 1
    fi
    # The previous tree goes only once the new one is complete beside it.
    mkdir -p "$(dirname "$opt_dir")" "$bin_dir" || return
    rm -rf "$opt_dir.new" || return
    mv "$extracted" "$opt_dir.new" || return
    rm -rf "$opt_dir" || return
    mv "$opt_dir.new" "$opt_dir" || return
    ln -sfn "$opt_dir/bin/nvim" "$bin_dir/nvim" || return
    if ! version="$(dotfiles_nvim_version "$bin_dir/nvim")"; then
        echo "$bin_dir/nvim does not run after installing $asset." >&2
        return 1
    fi
    if ! dotfiles_version_at_least "$version" "$DOTFILES_NVIM_MINIMUM"; then
        echo "The Neovim release $tag ($version) is older than $DOTFILES_NVIM_MINIMUM." >&2
        return 1
    fi
    echo "Installed Neovim $version into $opt_dir"
)

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
    install_neovim_release || return
    install_tree_sitter_cli || return
    install_nerd_font || return
}

# nvim-treesitter compiles parsers with the tree-sitter CLI and needs
# DOTFILES_TREE_SITTER_MINIMUM (lib/environment.sh); Debian 13 packages 0.22
# and Ubuntu 24.04 0.20. A CLI that is too old is left where it is and the
# release goes into the local bin directory, which precedes /usr/bin on PATH.
# The zip holds the one binary (the .gz assets hold it bare). A release that
# fails for want of a newer glibc is removed again and recorded (see
# dotfiles_tree_sitter_record), so Neovim skips the parsers instead of
# compiling with it; any other failure stops the bootstrap.
install_tree_sitter_cli() {
    local version glibc errors tag needed record bin_dir="${DOTFILES_LOCAL_BIN:-$HOME/.local/bin}"
    record="$(dotfiles_tree_sitter_record)"
    if version="$(dotfiles_tree_sitter_version)" && dotfiles_version_at_least "$version" "$DOTFILES_TREE_SITTER_MINIMUM" && \
        ! dotfiles_tree_sitter_glibc_error >/dev/null; then
        echo "tree-sitter $version already installed"
        return 0
    fi
    if [ -r "$record" ] && glibc="$(dotfiles_glibc_version)" && tag="$(github_latest_tag tree-sitter/tree-sitter)" && \
        [ "$(cat "$record")" = "$tag $glibc" ]; then
        echo "tree-sitter $tag does not run on glibc $glibc; Neovim keeps skipping the parsers"
        return 0
    fi
    echo "Installing tree-sitter from tree-sitter/tree-sitter${version:+ (found $version, need $DOTFILES_TREE_SITTER_MINIMUM)}..."
    download_github_release tree-sitter/tree-sitter 'tree-sitter-cli-linux-{arch_node}.zip' tree-sitter || return
    if errors="$(dotfiles_tree_sitter_glibc_error "$bin_dir/tree-sitter")" && glibc="$(dotfiles_glibc_version)" && \
        tag="$(github_latest_tag tree-sitter/tree-sitter)"; then
        needed="${errors#*GLIBC_}"
        needed="${needed%%[!0-9.]*}"
        rm -f "$bin_dir/tree-sitter" || return
        mkdir -p "$(dirname "$record")" || return
        printf '%s %s\n' "$tag" "$glibc" > "$record" || return
        echo "tree-sitter $tag needs glibc ${needed:-newer than $glibc} and this system has $glibc; Neovim will skip compiling parsers and highlight those file types with Vim's syntax files."
        return 0
    fi
    if ! version="$(dotfiles_tree_sitter_version "$bin_dir/tree-sitter")"; then
        errors="$("$bin_dir/tree-sitter" --version 2>&1)" || :
        printf '%s does not report a version after installing:\n%s\n' "$bin_dir/tree-sitter" "$errors" >&2
        return 1
    fi
    if ! dotfiles_version_at_least "$version" "$DOTFILES_TREE_SITTER_MINIMUM"; then
        echo "The tree-sitter release ($version) is older than $DOTFILES_TREE_SITTER_MINIMUM." >&2
        return 1
    fi
    rm -f "$record"
}

# Ghostty and the Windows Terminal fragment select DOTFILES_FONT_FAMILY
# (lib/environment.sh); macOS installs it with a Homebrew cask and Windows with
# oh-my-posh. On Linux the Mono family alone, 33 MB of the 100 MB the release
# unpacks to, comes from the latest Nerd Fonts release into
# ~/.local/share/fonts/CaskaydiaCove, where fontconfig finds it. WSL skips it:
# Windows Terminal draws WSL's text with the font install.ps1 installs on
# Windows.
#
# The new copy is assembled in .CaskaydiaCove.new beside the directory:
# fontconfig skips hidden directories, so a copy cut short never counts as
# installed, and the rename into place stays on one file system. The marker
# file lets a later run replace the directory; one without it belongs to the
# user and is left alone.
install_nerd_font() (
    local fonts_dir="${XDG_DATA_HOME:-$HOME/.local/share}/fonts"
    local font_dir="$fonts_dir/CaskaydiaCove" staging="$fonts_dir/.CaskaydiaCove.new"
    local marker=.installed-by-dotfiles asset=CascadiaCode.tar.xz tag work
    if dotfiles_is_wsl; then
        echo "WSL uses the Windows font; install.ps1 installs $DOTFILES_FONT_FAMILY there"
        return 0
    fi
    if ! command -v fc-cache >/dev/null 2>&1; then
        echo "fontconfig is not installed; install packages first." >&2
        return 1
    fi
    rm -rf "$staging" || return
    if dotfiles_linux_font_installed; then
        echo "$DOTFILES_FONT_FAMILY already installed"
        return 0
    fi
    if [ -e "$font_dir" ] && [ ! -e "$font_dir/$marker" ]; then
        echo "$font_dir exists and the bootstrap did not install it; move it away to let the bootstrap install $DOTFILES_FONT_FAMILY there." >&2
        return 1
    fi
    echo "Installing $DOTFILES_FONT_FAMILY into $font_dir..."
    tag="$(github_latest_tag ryanoasis/nerd-fonts)" || return
    work="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-font.XXXXXX")" || return
    trap 'rm -rf "$work"' EXIT
    curl -fsSL -o "$work/$asset" "https://github.com/ryanoasis/nerd-fonts/releases/download/$tag/$asset" || return
    mkdir -p "$work/extract" || return
    tar -xJf "$work/$asset" -C "$work/extract" || return
    if ! compgen -G "$work/extract/CaskaydiaCoveNerdFontMono-*.ttf" >/dev/null; then
        echo "$asset does not contain the $DOTFILES_FONT_FAMILY files" >&2
        return 1
    fi
    mkdir -p "$staging" || return
    cp "$work/extract"/CaskaydiaCoveNerdFontMono-*.ttf "$staging/" || return
    : > "$staging/$marker" || return
    # The previous directory goes only once the new one is complete beside it.
    rm -rf "$font_dir" || return
    mv "$staging" "$font_dir" || return
    fc-cache -f "$font_dir" || return
    if ! dotfiles_linux_font_installed; then
        echo "fontconfig does not list $DOTFILES_FONT_FAMILY after installing $asset." >&2
        return 1
    fi
)

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

# Neovim plugins come from config/nvim/lazy-lock.json; lua/dotfiles/bootstrap.lua
# clones the missing ones at their pinned commits and moves drifted ones back
# (the first start clones lazy.nvim itself; nothing is fetched at an
# interactive start), then, in a fresh process so the plugins are loaded,
# installs the Tree-sitter parsers and Mason packages from
# lua/dotfiles/tools.lua. Its report decides which of the two steps runs and
# verifies the result. Mason installs most servers with npm, so the Node.js
# that mise installed joins PATH for that step; the shell does the same later.
# Every Lua command is followed by cquit so a Lua error ends the process with
# a failure instead of leaving a headless Neovim waiting.
bootstrap_neovim() {
    local version node_path report
    if ! command -v nvim >/dev/null 2>&1; then
        echo "Neovim is not installed; install packages first." >&2
        return 1
    fi
    if ! version="$(dotfiles_nvim_version)" || ! dotfiles_version_at_least "$version" "$DOTFILES_NVIM_MINIMUM"; then
        echo "Neovim ${version:-(unknown version)} is older than $DOTFILES_NVIM_MINIMUM; upgrade it (macOS: brew upgrade neovim) and rerun." >&2
        return 1
    fi
    if report="$(nvim --headless -c 'lua require("dotfiles.bootstrap").check()' -c 'cquit 1' 2>&1)"; then
        echo "Neovim plugins, parsers and language servers already installed"
        return 0
    fi
    case "$report" in
        *"missing plugin "*|*"stale plugin "*)
            echo "Installing Neovim plugins from lazy-lock.json..."
            nvim --headless -c 'lua require("dotfiles.bootstrap").plugins()' -c 'cquit 1' || return
            ;;
    esac
    case "$report" in
        *"missing parser "*|*"missing package "*)
            echo "Installing Neovim parsers and language servers..."
            if node_path="$(mise which node 2>/dev/null)" && [ -n "$node_path" ]; then
                PATH="$(dirname "$node_path"):$PATH" nvim --headless -c 'lua require("dotfiles.bootstrap").install()' -c 'cquit 1' || return
            else
                nvim --headless -c 'lua require("dotfiles.bootstrap").install()' -c 'cquit 1' || return
            fi
            ;;
    esac
    if ! report="$(nvim --headless -c 'lua require("dotfiles.bootstrap").check()' -c 'cquit 1' 2>&1)"; then
        printf '%s\n' "$report" >&2
        echo "Neovim is not fully set up after installing; see the report above." >&2
        return 1
    fi
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
    bootstrap_neovim || return
}

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
    set -euo pipefail
    bootstrap_tools_main "$@"
fi
