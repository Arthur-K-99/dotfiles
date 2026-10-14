#!/usr/bin/env bash

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/environment.sh
source "$DOTFILES_DIR/scripts/lib/environment.sh"
# shellcheck source=lib/apt_repositories.sh
source "$DOTFILES_DIR/scripts/lib/apt_repositories.sh"

# --- Release records ----------------------------------------------------------
# The tag each tool from a GitHub release was installed at, one file per
# project: ~/.local/state/dotfiles/releases/<owner>/<repo>.
# The update compares it with the latest tag instead of parsing every tool's
# --version. A tool installed before records existed has none, so the first
# update fetches it once.

release_record() {
    printf '%s/dotfiles/releases/%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}" "$1"
}

recorded_release() {
    cat "$(release_record "$1")" 2>/dev/null || :
}

record_release() {
    local record
    record="$(release_record "$1")"
    mkdir -p "$(dirname "$record")" || return
    printf '%s\n' "$2" > "$record"
}

# Updating, zinit updates itself and every plugin it has cloned. Its update
# returns 0 when a plugin fails and only warns ("update returned <status>"),
# so the output decides; --no-pager keeps it from waiting in less for a key.
bootstrap_zinit() {
    local zinit_home="${1:-${XDG_DATA_HOME:-$HOME/.local/share}/zinit/zinit.git}"
    local output status
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
    ' || return
    dotfiles_updating || return 0
    echo "Updating Zinit and its plugins..."
    if output="$(ZINIT_HOME="$zinit_home" zsh -c '
        source "$ZINIT_HOME/zinit.zsh" || exit
        zinit update --all --quiet --no-pager
    ' 2>&1)"; then
        status=0
    else
        status=$?
    fi
    printf '%s\n' "$output"
    [ "$status" -eq 0 ] || return "$status"
    case "$output" in
        *"update returned"*)
            echo "zinit could not update every plugin; see the warnings above." >&2
            return 1
            ;;
    esac
}

# dotfiles_tmux_plugins <tmux.conf>: each declared plugin, as written after
# @plugin ("owner/name" or "owner/name#tag").
dotfiles_tmux_plugins() {
    sed -n "s/^set -g @plugin '\([^']*\)'.*/\1/p" "$1"
}

# Updating, TPM pulls itself and every plugin except those pinned to a tag
# (catppuccin/tmux#v2.3.1): git pull fails on their detached checkout, and the
# tag is the point.
bootstrap_tmux() (
    # TPM installs plugins beside itself. With the configuration at
    # ~/.config/tmux/tmux.conf, TPM itself defaults to this directory.
    local tpm_dir="${1:-${XDG_CONFIG_HOME:-$HOME/.config}/tmux/plugins/tpm}"
    local work_dir socket_path plugin output status
    local names=()
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
    XDG_CONFIG_HOME="$work_dir/config" TMUX="$socket_path,0,0" "$tpm_dir/bin/install_plugins" || return
    dotfiles_updating || return 0
    while IFS= read -r plugin; do
        case "$plugin" in
            *'#'*) echo "tmux plugin ${plugin%%#*} is pinned to ${plugin#*#}; left alone" ;;
            *) names+=("${plugin##*/}") ;;
        esac
    done < <(dotfiles_tmux_plugins "$DOTFILES_DIR/config/tmux/tmux.conf")
    [ "${#names[@]}" -gt 0 ] || return 0
    echo "Updating TPM and the tmux plugins..."
    # TPM updates the plugins in background jobs, so a failed git pull never
    # reaches its exit status; its "update fail" line does.
    if output="$(XDG_CONFIG_HOME="$work_dir/config" TMUX="$socket_path,0,0" "$tpm_dir/bin/update_plugins" "${names[@]}" 2>&1)"; then
        status=0
    else
        status=$?
    fi
    printf '%s\n' "$output"
    [ "$status" -eq 0 ] || return "$status"
    case "$output" in
        *"update fail"*)
            echo "TPM could not update every plugin; see above." >&2
            return 1
            ;;
    esac
)

# bootstrap_owns <path>: a regular executable file. The bootstrap installs
# plain files into the local bin directory; pipx, uv and npm put links there,
# so a link with a managed name is not the bootstrap's to replace.
bootstrap_owns() {
    [ -x "$1" ] && [ -f "$1" ] && [ ! -L "$1" ]
}

# oh-my-posh's binary is the whole tool; the configuration is the repository's
# own, so the themes its installer script adds are not needed. Its static Go
# builds are named posh-<os>-<arch> on both, so one template covers macOS and
# Linux.
bootstrap_oh_my_posh() {
    install_github_release JanDeDobbeleer/oh-my-posh 'posh-{os}-{arch_deb}' oh-my-posh
}

# The Catppuccin themes for bat releases older than 0.26 come from a fixed
# commit of catppuccin/bat (v3.17.0 of the themes, 2025-06-29), so the file
# cannot change under the same URL. The repository has no tags.
DOTFILES_BAT_THEMES_COMMIT=6810349b28055dce54076712fc05fc68da4b8ec0

bootstrap_bat_theme() {
    local bat_command theme_dir theme_file status theme_name theme_url
    theme_name="$(dotfiles_bat_theme "$DOTFILES_DIR/config/bat/config")"
    if [ -z "$theme_name" ]; then
        echo "config/bat/config names no --theme." >&2
        return 1
    fi
    theme_url="https://raw.githubusercontent.com/catppuccin/bat/$DOTFILES_BAT_THEMES_COMMIT/themes/${theme_name// /%20}.tmTheme"
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
    curl -fsSL --retry 5 -o "$theme_file.part" "$theme_url" || {
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
# Debian and Ubuntu lack packages for several tools. Two routes cover them,
# in order of preference: a signed third-party apt repository (updates arrive
# with apt) and a static binary from the latest GitHub release, verified and
# installed into ~/.local/bin (DOTFILES_LOCAL_BIN). No installer script is
# piped into a shell: oh-my-posh's and zoxide's verified nothing they fetched.
# Every curl call here retries timeouts and HTTP 408, 429 and 5xx answers,
# five times over about 30 seconds (--retry 5): GitHub returns a 500 or 502
# now and then, at times for several seconds, and an update looks up the
# latest tag of every release tool.

# install_apt_repository <name> <package>...: installs packages from one of
# the repositories in lib/apt_repositories.sh, adding it with its pinned key
# when one of them is missing. Package names double as command names.
# Updating, installed packages are upgraded from the index the package stage
# has just refreshed (after fetching the keys again), except held ones.
install_apt_repository() {
    local name="$1" fields sources_line
    shift
    local package held
    fields="$(dotfiles_apt_repository "$name")" || return
    read -r _ _ sources_line <<<"$fields"
    local missing=() upgrades=()
    if dotfiles_updating; then
        held="$(apt-mark showhold)" || return
    fi
    for package in "$@"; do
        if ! command -v "$package" &>/dev/null; then
            missing+=("$package")
        elif dotfiles_updating && dotfiles_apt_unheld "$held" "$package"; then
            upgrades+=("$package")
        fi
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        if ! dotfiles_updating; then
            echo "$* already installed"
            return 0
        fi
        [ "${#upgrades[@]}" -gt 0 ] || return 0
        echo "Upgrading ${upgrades[*]} from the $name repository..."
        sudo apt-get install -y --only-upgrade "${upgrades[@]}"
        return
    fi
    echo "Installing ${missing[*]} from the $name repository..."
    install_apt_key "$name" || return
    printf '%s\n' "$sources_line" | sudo tee "$DOTFILES_APT_ETC/sources.list.d/$name.list" >/dev/null || return
    sudo apt-get update -qq || return
    # Updating, the installed packages of the repository come along.
    sudo apt-get install -y "${missing[@]}" ${upgrades[@]+"${upgrades[@]}"} || return
}

install_eza() {
    install_apt_repository gierens eza
}

install_charm_tools() {
    install_apt_repository charm glow gum
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
    url="$(curl -fsSL --retry 5 -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest")" || return
    case "$url" in
        */releases/tag/?*) printf '%s\n' "${url##*/releases/tag/}" ;;
        *) echo "Could not resolve the latest release of $1: $url" >&2; return 1 ;;
    esac
}

# --- Verified release downloads ----------------------------------------------
# GitHub computes the SHA-256 of every release asset when it is uploaded and
# lists it as the asset's digest in the releases API. Every download from a
# release is checked against it before anything is unpacked, so a file that
# differs from what the release holds (a broken transfer, a proxy or mirror
# that changed it) is never installed. The digest comes from the same release,
# so it cannot catch an asset that someone able to publish there replaced.
# About half of these projects publish checksum files as well; the digest
# covers every one of them the same way.

# github_api <path>: GET https://api.github.com/<path>. Without a token GitHub
# answers 60 requests an hour per address, which an install (one request per
# release download) stays well under. GITHUB_TOKEN raises the limit when set;
# it goes to curl on stdin, so it never shows in the process list. GitHub
# answers a token it does not accept (expired, or for another host) with 401
# instead of answering anonymously, so a failed request is made once more
# without it. Over the limit GitHub answers 403 or 429. curl retries a 429 and
# would wait as long as a Retry-After asks; with --retry-max-time, a longer
# one makes it give up at once instead.
github_api() {
    local args=(-fsSL --retry 5 --retry-max-time 120 -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28')
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        if printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN" | curl "${args[@]}" -H @- "https://api.github.com/$1"; then
            return 0
        fi
        echo "The GitHub API refused the request with GITHUB_TOKEN; trying once without it." >&2
    fi
    curl "${args[@]}" "https://api.github.com/$1"
}

# release_asset_digest <owner/repo> <tag> <asset>: prints the SHA-256 GitHub
# lists for the asset, without a JSON parser. Split at commas, brackets and
# braces, every key of the release arrives on a line of its own; quotes inside
# string values are escaped, so no value can pass for a key. An asset's digest
# precedes its browser_download_url, and its API url starts the asset, which
# keeps the digest of one asset from carrying over to the next. awk reads to
# the end rather than exiting at the match, which would break the pipe.
release_asset_digest() {
    local json found digest
    if ! json="$(github_api "repos/$1/releases/tags/$2")"; then
        echo "Could not read release $2 of $1 from the GitHub API to verify $3. Without a token GitHub answers 60 requests an hour per address; wait, or set GITHUB_TOKEN, and rerun." >&2
        return 1
    fi
    found="$(printf '%s\n' "$json" | tr ',[{' '\n\n\n' |
        sed -n 's/^[[:space:]]*"\([a-z_]*\)":[[:space:]]*"\([^"]*\)".*/\1 \2/p' |
        awk -v suffix="/$3" '
            $1 == "url" && $2 ~ /\/releases\/assets\// { digest = "" }
            $1 == "digest" { digest = $2 }
            $1 == "browser_download_url" && !found && length($2) >= length(suffix) &&
                substr($2, length($2) - length(suffix) + 1) == suffix { found = 1; result = digest }
            END { if (found) print "asset " result; else print "missing" }')"
    if [ "$found" = missing ]; then
        echo "Release $2 of $1 has no asset named $3; the project may have renamed it, or is still uploading." >&2
        return 1
    fi
    digest="${found#asset }"
    if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        echo "GitHub lists no SHA-256 digest for $3 in release $2 of $1, so it cannot be verified (assets uploaded before June 2025 have none)." >&2
        return 1
    fi
    printf '%s\n' "${digest#sha256:}"
}

# file_sha256 <file>: GNU coreutils on Linux; shasum on older macOS releases.
file_sha256() {
    local sum
    if command -v sha256sum >/dev/null 2>&1; then
        sum="$(sha256sum "$1")" || return
    else
        sum="$(shasum -a 256 "$1")" || return
    fi
    printf '%s\n' "${sum%% *}"
}

# download_release_asset <owner/repo> <tag> <asset> <file>: downloads a release
# asset to <file> and keeps it only when its SHA-256 matches the digest GitHub
# lists for it. The digest is read first, so an unreachable API costs no download.
download_release_asset() {
    local expected actual
    expected="$(release_asset_digest "$1" "$2" "$3")" || return
    curl -fsSL --retry 5 -o "$4" "https://github.com/$1/releases/download/$2/$3" || return
    actual="$(file_sha256 "$4")" || return
    if [ "$actual" != "$expected" ]; then
        rm -f "$4"
        printf '%s from %s %s does not match the SHA-256 GitHub lists for it:\n  expected %s\n  received %s\n' \
            "$3" "$1" "$2" "$expected" "$actual" >&2
        return 1
    fi
}

# install_github_release <owner/repo> <asset template> <binary>...
# Installs the named binaries from the latest release asset into the local bin
# directory when one of them is missing from PATH, and records the tag.
# Updating, binaries in the local bin directory are fetched again when the
# latest tag differs from the recorded one; a binary elsewhere on PATH belongs
# to whatever installed it and is left alone. Templates may use {tag},
# {version} (the tag without a leading v), {os} (linux|darwin), {arch},
# {arch_go}, {arch_deb}, {arch_amd64} and {arch_node}.
install_github_release() {
    local repo="$1" template="$2"
    shift 2
    local binary tag recorded bin_dir="${DOTFILES_LOCAL_BIN:-$HOME/.local/bin}"
    local missing=() managed=() elsewhere=()
    for binary in "$@"; do
        if bootstrap_owns "$bin_dir/$binary"; then
            managed+=("$binary")
        elif command -v "$binary" &>/dev/null; then
            elsewhere+=("$binary")
        else
            missing+=("$binary")
        fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        tag="$(github_latest_tag "$repo")" || return
        echo "Installing ${missing[*]} from $repo $tag..."
        # Binaries installed earlier from the same asset are replaced as well,
        # so the recorded tag holds for all of them.
        download_github_release "$repo" "$tag" "$template" "${missing[@]}" ${managed[@]+"${managed[@]}"} || return
        record_release "$repo" "$tag"
        return
    fi
    if ! dotfiles_updating; then
        echo "$* already installed"
        return 0
    fi
    if [ "${#elsewhere[@]}" -gt 0 ]; then
        echo "${elsewhere[*]} not installed by the bootstrap; left alone"
    fi
    [ "${#managed[@]}" -gt 0 ] || return 0
    tag="$(github_latest_tag "$repo")" || return
    recorded="$(recorded_release "$repo")"
    if [ "$recorded" = "$tag" ]; then
        echo "${managed[*]} $tag is current"
        return 0
    fi
    echo "Updating ${managed[*]} from $repo ${recorded:-(no recorded tag)} to $tag..."
    download_github_release "$repo" "$tag" "$template" "${managed[@]}" || return
    record_release "$repo" "$tag"
}

# download_github_release <owner/repo> <tag> <asset template> <binary>...
# Downloads a release asset, extracts it (.tar.gz, .tgz, .tar.xz, .zip, or a
# bare executable) and installs every named binary found inside into the
# local bin directory, whatever PATH already holds: callers such as
# install_tree_sitter_cli decide for themselves when a present binary is too
# old, and record the tag once the result is what they want.
download_github_release() (
    local repo="$1" tag="$2" template="$3"
    shift 3
    local binary version os arch_words arch arch_go arch_deb arch_amd64 arch_node asset work extract found bin_dir
    version="${tag#v}"
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch_words="$(dotfiles_arch)" || return
    read -r arch arch_go arch_deb arch_amd64 arch_node <<<"$arch_words"
    asset="${template//\{tag\}/$tag}"
    asset="${asset//\{version\}/$version}"
    asset="${asset//\{os\}/$os}"
    asset="${asset//\{arch\}/$arch}"
    asset="${asset//\{arch_go\}/$arch_go}"
    asset="${asset//\{arch_deb\}/$arch_deb}"
    asset="${asset//\{arch_amd64\}/$arch_amd64}"
    asset="${asset//\{arch_node\}/$arch_node}"
    work="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-release.XXXXXX")" || return
    trap 'rm -rf "$work"' EXIT
    download_release_asset "$repo" "$tag" "$asset" "$work/$asset" || return
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

# zoxide's musl build runs on every glibc. Its archive also carries man pages,
# which the bootstrap leaves out as it does for the other release tools.
bootstrap_zoxide() {
    install_github_release ajeetdsouza/zoxide 'zoxide-{version}-{arch}-unknown-linux-musl.tar.gz' zoxide
}

# mise is a single binary; the musl build runs on every glibc. Updating, a
# copy in the local bin directory updates itself: `mise self-update` checks
# the release's signature and skips releases younger than a day, so the
# bootstrap records no tag for it. A copy elsewhere on PATH (Homebrew's on
# macOS) is left alone.
bootstrap_mise_binary() {
    local bin_dir="${DOTFILES_LOCAL_BIN:-$HOME/.local/bin}" path tag
    if bootstrap_owns "$bin_dir/mise" && dotfiles_updating; then
        echo "Updating mise..."
        "$bin_dir/mise" self-update --yes
        return
    fi
    if path="$(command -v mise)"; then
        if dotfiles_updating; then
            echo "mise at $path was not installed by the bootstrap; left alone"
        else
            echo "mise already installed"
        fi
        return 0
    fi
    tag="$(github_latest_tag jdx/mise)" || return
    echo "Installing mise $tag..."
    download_github_release jdx/mise "$tag" 'mise-{tag}-linux-{arch_node}-musl' mise
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
# any source, is kept. Updating, the bootstrap's own tree is replaced when the
# latest tag differs from the recorded one.
install_neovim_release() (
    local opt_dir="${DOTFILES_LOCAL_OPT:-$HOME/.local/opt}/nvim"
    local bin_dir="${DOTFILES_LOCAL_BIN:-$HOME/.local/bin}"
    local version tag="" recorded arch_words arch_go asset work extracted errors
    if version="$(dotfiles_nvim_version)" && dotfiles_version_at_least "$version" "$DOTFILES_NVIM_MINIMUM"; then
        if ! dotfiles_updating; then
            echo "Neovim $version already installed"
            return 0
        fi
        if [ "$(readlink "$bin_dir/nvim" 2>/dev/null)" != "$opt_dir/bin/nvim" ]; then
            echo "Neovim $version was not installed by the bootstrap; left alone"
            return 0
        fi
        tag="$(github_latest_tag neovim/neovim)" || return
        recorded="$(recorded_release neovim/neovim)"
        if [ "$recorded" = "$tag" ]; then
            echo "Neovim $tag is current"
            return 0
        fi
        echo "Updating Neovim $version to $tag..."
    fi
    if [ -e "$bin_dir/nvim" ] && [ ! -L "$bin_dir/nvim" ]; then
        echo "$bin_dir/nvim exists and is not a link; remove it to let the bootstrap install Neovim there." >&2
        return 1
    fi
    if [ -z "$tag" ]; then
        echo "Installing Neovim from the GitHub release${version:+ (found $version, need $DOTFILES_NVIM_MINIMUM)}..."
        tag="$(github_latest_tag neovim/neovim)" || return
    fi
    arch_words="$(dotfiles_arch)" || return
    read -r _ arch_go _ <<<"$arch_words"
    asset="nvim-linux-$arch_go.tar.gz"
    work="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-nvim.XXXXXX")" || return
    trap 'rm -rf "$work"' EXIT
    download_release_asset neovim/neovim "$tag" "$asset" "$work/$asset" || return
    mkdir -p "$work/extract" || return
    tar -xzf "$work/$asset" -C "$work/extract" || return
    extracted="$(find "$work/extract" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    if [ -z "$extracted" ] || [ ! -x "$extracted/bin/nvim" ]; then
        echo "$asset does not contain bin/nvim" >&2
        return 1
    fi
    # The new tree must run before it replaces anything: the current one, which
    # works, stays when a release does not start here.
    if ! version="$(dotfiles_nvim_version "$extracted/bin/nvim")"; then
        errors="$("$extracted/bin/nvim" --version 2>&1)" || :
        printf 'Neovim from %s %s does not run here:\n%s\n' "$tag" "$asset" "$errors" >&2
        return 1
    fi
    if ! dotfiles_version_at_least "$version" "$DOTFILES_NVIM_MINIMUM"; then
        echo "The Neovim release $tag ($version) is older than $DOTFILES_NVIM_MINIMUM." >&2
        return 1
    fi
    # The previous tree goes only once the new one is complete beside it.
    mkdir -p "$(dirname "$opt_dir")" "$bin_dir" || return
    rm -rf "$opt_dir.new" || return
    mv "$extracted" "$opt_dir.new" || return
    rm -rf "$opt_dir" || return
    mv "$opt_dir.new" "$opt_dir" || return
    ln -sfn "$opt_dir/bin/nvim" "$bin_dir/nvim" || return
    record_release neovim/neovim "$tag" || return
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
# fails for want of a newer glibc is recorded (see dotfiles_tree_sitter_record)
# and left out, so Neovim skips the parsers instead of compiling with it; any
# other failure stops the bootstrap. Updating, the bootstrap's copy is
# replaced when the latest tag differs from the recorded one, and only by a
# release that runs: a working CLI is never traded for one that does not.
install_tree_sitter_cli() {
    local version glibc tag recorded record bin_dir="${DOTFILES_LOCAL_BIN:-$HOME/.local/bin}"
    record="$(dotfiles_tree_sitter_record)"
    if version="$(dotfiles_tree_sitter_version)" && dotfiles_version_at_least "$version" "$DOTFILES_TREE_SITTER_MINIMUM" && \
        ! dotfiles_tree_sitter_glibc_error >/dev/null; then
        if ! dotfiles_updating; then
            echo "tree-sitter $version already installed"
            return 0
        fi
        if ! bootstrap_owns "$bin_dir/tree-sitter"; then
            echo "tree-sitter $version was not installed by the bootstrap; left alone"
            return 0
        fi
        tag="$(github_latest_tag tree-sitter/tree-sitter)" || return
        recorded="$(recorded_release tree-sitter/tree-sitter)"
        if [ "$recorded" = "$tag" ]; then
            echo "tree-sitter $tag is current"
            return 0
        fi
        if glibc="$(dotfiles_glibc_version)" && [ "$(cat "$record" 2>/dev/null)" = "$tag $glibc" ]; then
            echo "tree-sitter $tag does not run on glibc $glibc; keeping $version"
            return 0
        fi
        echo "Updating tree-sitter $version to $tag..."
    else
        tag="$(github_latest_tag tree-sitter/tree-sitter)" || return
        if [ -r "$record" ] && glibc="$(dotfiles_glibc_version)" && [ "$(cat "$record")" = "$tag $glibc" ]; then
            echo "tree-sitter $tag does not run on glibc $glibc; Neovim keeps skipping the parsers"
            return 0
        fi
        echo "Installing tree-sitter $tag from tree-sitter/tree-sitter${version:+ (found $version, need $DOTFILES_TREE_SITTER_MINIMUM)}..."
    fi
    install_tree_sitter_release "$tag"
}

# install_tree_sitter_release <tag>: the release goes into a scratch directory
# first and into the local bin directory only once it runs. A copy already
# there stays unless it has the same glibc complaint.
install_tree_sitter_release() (
    local tag="$1" bin_dir="${DOTFILES_LOCAL_BIN:-$HOME/.local/bin}"
    local work errors glibc needed version record
    record="$(dotfiles_tree_sitter_record)"
    work="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-tree-sitter.XXXXXX")" || return
    trap 'rm -rf "$work"' EXIT
    DOTFILES_LOCAL_BIN="$work/bin" download_github_release tree-sitter/tree-sitter "$tag" \
        'tree-sitter-cli-linux-{arch_node}.zip' tree-sitter || return
    if errors="$(dotfiles_tree_sitter_glibc_error "$work/bin/tree-sitter")" && glibc="$(dotfiles_glibc_version)"; then
        needed="${errors#*GLIBC_}"
        needed="${needed%%[!0-9.]*}"
        if [ -e "$bin_dir/tree-sitter" ] && dotfiles_tree_sitter_glibc_error "$bin_dir/tree-sitter" >/dev/null; then
            rm -f "$bin_dir/tree-sitter" || return
        fi
        mkdir -p "$(dirname "$record")" || return
        printf '%s %s\n' "$tag" "$glibc" > "$record" || return
        if version="$(dotfiles_tree_sitter_version "$bin_dir/tree-sitter")"; then
            echo "tree-sitter $tag needs glibc ${needed:-newer than $glibc} and this system has $glibc; keeping tree-sitter $version."
        else
            echo "tree-sitter $tag needs glibc ${needed:-newer than $glibc} and this system has $glibc; Neovim will skip compiling parsers and highlight those file types with Vim's syntax files."
        fi
        return 0
    fi
    if ! version="$(dotfiles_tree_sitter_version "$work/bin/tree-sitter")"; then
        errors="$("$work/bin/tree-sitter" --version 2>&1)" || :
        printf 'The tree-sitter release %s does not report a version after installing:\n%s\n' "$tag" "$errors" >&2
        return 1
    fi
    if ! dotfiles_version_at_least "$version" "$DOTFILES_TREE_SITTER_MINIMUM"; then
        echo "The tree-sitter release ($version) is older than $DOTFILES_TREE_SITTER_MINIMUM." >&2
        return 1
    fi
    mkdir -p "$bin_dir" || return
    install -m 755 "$work/bin/tree-sitter" "$bin_dir/tree-sitter" || return
    rm -f "$record"
    record_release tree-sitter/tree-sitter "$tag"
)

# Ghostty and the Windows Terminal fragment select DOTFILES_FONT_FAMILY
# (lib/environment.sh); macOS installs it with a Homebrew cask and Windows with
# oh-my-posh. On Linux the Mono family alone, 33 MB of the 100 MB the release
# unpacks to, comes from the latest Nerd Fonts release into
# ~/.local/share/fonts/CaskaydiaCove, where fontconfig finds it. WSL skips it:
# Windows Terminal draws WSL's text with the font install.ps1 installs on
# Windows.
#
# The new copy is assembled in .CaskaydiaCove.new beside the directory, and
# the previous one waits in .CaskaydiaCove.old until fontconfig lists the
# family again: fontconfig skips hidden directories, so a copy cut short never
# counts as installed, and the renames stay on one file system. The marker
# file lets a later run replace the directory; one without it belongs to the
# user and is left alone. Updating, the bootstrap's directory is replaced when
# the latest Nerd Fonts tag differs from the recorded one.
install_nerd_font() (
    local fonts_dir="${XDG_DATA_HOME:-$HOME/.local/share}/fonts"
    local font_dir="$fonts_dir/CaskaydiaCove" staging="$fonts_dir/.CaskaydiaCove.new" previous="$fonts_dir/.CaskaydiaCove.old"
    local marker=.installed-by-dotfiles asset=CascadiaCode.tar.xz tag="" recorded work
    if dotfiles_is_wsl; then
        echo "WSL uses the Windows font; install.ps1 installs $DOTFILES_FONT_FAMILY there"
        return 0
    fi
    if ! command -v fc-cache >/dev/null 2>&1; then
        echo "fontconfig is not installed; install packages first." >&2
        return 1
    fi
    rm -rf "$staging" || return
    # A previous directory left aside by an interrupted run is still the font.
    if [ -e "$previous" ] && [ ! -e "$font_dir" ]; then
        mv "$previous" "$font_dir" || return
    fi
    if [ -e "$font_dir/$marker" ] && dotfiles_updating; then
        tag="$(github_latest_tag ryanoasis/nerd-fonts)" || return
        recorded="$(recorded_release ryanoasis/nerd-fonts)"
        if [ "$recorded" = "$tag" ] && dotfiles_linux_font_installed; then
            echo "$DOTFILES_FONT_FAMILY $tag is current"
            return 0
        fi
        echo "Updating $DOTFILES_FONT_FAMILY to $tag..."
    elif dotfiles_linux_font_installed; then
        if dotfiles_updating; then
            echo "$DOTFILES_FONT_FAMILY was not installed by the bootstrap; left alone"
        else
            echo "$DOTFILES_FONT_FAMILY already installed"
        fi
        return 0
    elif [ -e "$font_dir" ] && [ ! -e "$font_dir/$marker" ]; then
        echo "$font_dir exists and the bootstrap did not install it; move it away to let the bootstrap install $DOTFILES_FONT_FAMILY there." >&2
        return 1
    fi
    if [ -z "$tag" ]; then
        echo "Installing $DOTFILES_FONT_FAMILY into $font_dir..."
        tag="$(github_latest_tag ryanoasis/nerd-fonts)" || return
    fi
    work="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-font.XXXXXX")" || return
    trap 'rm -rf "$work"' EXIT
    download_release_asset ryanoasis/nerd-fonts "$tag" "$asset" "$work/$asset" || return
    mkdir -p "$work/extract" || return
    tar -xJf "$work/$asset" -C "$work/extract" || return
    if ! compgen -G "$work/extract/CaskaydiaCoveNerdFontMono-*.ttf" >/dev/null; then
        echo "$asset does not contain the $DOTFILES_FONT_FAMILY files" >&2
        return 1
    fi
    mkdir -p "$staging" || return
    cp "$work/extract"/CaskaydiaCoveNerdFontMono-*.ttf "$staging/" || return
    : > "$staging/$marker" || return
    # The previous directory steps aside, hidden, until fontconfig lists the
    # family from the new one, and comes back if it does not.
    rm -rf "$previous" || return
    if [ -e "$font_dir" ]; then
        mv "$font_dir" "$previous" || return
    fi
    mv "$staging" "$font_dir" || return
    fc-cache -f "$font_dir" || return
    if ! dotfiles_linux_font_installed; then
        if [ -e "$previous" ]; then
            rm -rf "$font_dir" && mv "$previous" "$font_dir" && fc-cache -f "$font_dir"
            echo "fontconfig does not list $DOTFILES_FONT_FAMILY after installing $asset; the previous fonts are back." >&2
        else
            echo "fontconfig does not list $DOTFILES_FONT_FAMILY after installing $asset." >&2
        fi
        return 1
    fi
    rm -rf "$previous"
    record_release ryanoasis/nerd-fonts "$tag"
)

# --- Runtimes and themes ------------------------------------------------------

# mise installs every runtime pinned in config/mise/config.toml (Node.js LTS),
# which the link stage placed at ~/.config/mise/config.toml. It replaces nvm.
# Updating, mise upgrades each runtime to the newest release the file allows
# ("lts" follows the current LTS line). It runs from the home directory so
# that a project's own mise file does not decide; a mise file in the home
# directory itself, such as ~/.tool-versions, is the user's global choice and
# counts. (`mise upgrade --global` would skip those, but only recent mise
# releases have it.)
bootstrap_runtimes() {
    if ! command -v mise &>/dev/null; then
        echo "mise is not installed; install packages first." >&2
        return 1
    fi
    echo "Installing runtimes with mise..."
    mise install --yes || return
    if dotfiles_updating; then
        echo "Upgrading runtimes with mise..."
        (cd "$HOME" && mise upgrade --yes) || return
    fi
    if ! mise which node >/dev/null 2>&1; then
        echo "mise does not provide node after installing; check ~/.config/mise/config.toml." >&2
        return 1
    fi
}

# yazi flavors are packages cloned by ya into ~/.config/yazi/flavors. The
# first add also records them in package.toml; later machines restore from it.
# The flavor names come from config/yazi/theme.toml, the file yazi reads.
# Updating, ya upgrades these flavors, and only these: other packages in
# package.toml are the user's. A flavor package.toml does not list was put in
# place by hand and is left alone.
bootstrap_yazi_flavors() {
    local yazi_dir="${XDG_CONFIG_HOME:-$HOME/.config}/yazi"
    local flavor flavors
    local upgrades=()
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
    dotfiles_updating || return 0
    for flavor in $flavors; do
        if grep -q "flavors:$flavor\"" "$yazi_dir/package.toml" 2>/dev/null; then
            upgrades+=("yazi-rs/flavors:$flavor")
        else
            echo "yazi flavor $flavor is not in $yazi_dir/package.toml; left alone"
        fi
    done
    [ "${#upgrades[@]}" -gt 0 ] || return 0
    echo "Upgrading yazi flavors..."
    ya pkg upgrade "${upgrades[@]}"
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
# a failure instead of leaving a headless Neovim waiting. Updating, the
# plugins stay at the commits lazy-lock.json pins; update() then brings the
# parsers to the revisions the pinned nvim-treesitter names and the Mason
# packages to their latest versions.
bootstrap_neovim() {
    local version report
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
    else
        case "$report" in
            *"missing plugin "*|*"stale plugin "*)
                echo "Installing Neovim plugins from lazy-lock.json..."
                nvim --headless -c 'lua require("dotfiles.bootstrap").plugins()' -c 'cquit 1' || return
                ;;
        esac
        case "$report" in
            *"missing parser "*|*"missing package "*)
                echo "Installing Neovim parsers and language servers..."
                nvim_with_mise_node --headless -c 'lua require("dotfiles.bootstrap").install()' -c 'cquit 1' || return
                ;;
        esac
        if ! report="$(nvim --headless -c 'lua require("dotfiles.bootstrap").check()' -c 'cquit 1' 2>&1)"; then
            printf '%s\n' "$report" >&2
            echo "Neovim is not fully set up after installing; see the report above." >&2
            return 1
        fi
    fi
    dotfiles_updating || return 0
    echo "Updating Neovim parsers and language servers..."
    nvim_with_mise_node --headless -c 'lua require("dotfiles.bootstrap").update()' -c 'cquit 1'
}

# nvim_with_mise_node <argument>...: runs nvim with the Node.js that mise
# installed first on PATH, for Mason's npm packages.
nvim_with_mise_node() {
    local node_path
    if node_path="$(mise which node 2>/dev/null)" && [ -n "$node_path" ]; then
        PATH="$(dirname "$node_path"):$PATH" nvim "$@"
    else
        nvim "$@"
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
