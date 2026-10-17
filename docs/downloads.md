# Downloads

What the Unix bootstrap downloads, how each file is checked, what happens on a slow network, and how long a new GitHub release waits before it is installed. The code is in `scripts/bootstrap_tools.sh`, `scripts/lib/apt_repositories.sh` and `scripts/lib/dnf_repositories.sh`.

## Verified downloads

The files the Unix bootstrap downloads with curl are checked or pinned before they are used:

- **GitHub releases:** the release tools (including oh-my-posh, zoxide and mise), Neovim, the tree-sitter CLI and the Linux Nerd Font. Each file must match the SHA-256 digest GitHub lists for that asset; a file that does not is deleted before anything is unpacked or replaced. No installer script is piped into a shell.
- **apt repositories:** eza's and Charm's are added only when the downloaded signing key has the fingerprint pinned in `scripts/lib/apt_repositories.sh`. The update fetches both keys again before apt reads the repositories and checks them against the pins.
  - A changed copy of the pinned key is merged into the keyring, so an expiry the project extends reaches the machine without invalidating what the key signed before (Charm's key expires on 2027-07-13).
  - A keyring holding any other key is replaced.
  - When a key cannot be downloaded, the update keeps the keyring and says so.
  - The doctor reports a keyring that does not hold its pinned key and a key that has expired; a key that expires within 30 days passes, with its date shown. This matters because an expired key makes `apt-get update` fail only on fresh lists; once a repository's lists exist, apt warns and keeps the old ones.
- **dnf repository (RHEL family):** Charm's is added only when the downloaded key has the same pinned fingerprint, from `scripts/lib/dnf_repositories.sh`. The key file goes to `/etc/pki/rpm-gpg/RPM-GPG-KEY-dotfiles-charm`, the repository's file names it as its only key, and dnf checks the repository's signed metadata (`repo_gpgcheck`) and each package (`gpgcheck`) against it. The update fetches the key again, replaces the file when its bytes changed, and the doctor checks the file as it checks apt keyrings. rpm and dnf keep the copy they imported the first time ([roadmap](roadmap.md)).
- **bat themes:** bat releases older than 0.26 get the Catppuccin theme from a fixed commit of catppuccin/bat, so the file cannot change under its URL.

What this proves, and what it does not:

- The digest comes from the same release as the file, so it proves the file is what the release holds, not that the release itself is genuine.
- Package managers check their own downloads: apt against its signed indexes, dnf against the repositories' keys (EPEL's comes with epel-release), Homebrew bottles and casks against the SHA-256 in their formula or cask, and winget each installer against the SHA-256 in its manifest.
- Plugins come from git: Neovim's at the commits `lazy-lock.json` pins; zinit's, TPM's and the yazi flavors at their branch heads.
- Two downloads are not checked yet: Homebrew's installer script (from `HEAD`, as Homebrew's instructions say), and on Windows the Nerd Font that `oh-my-posh font install` fetches. [The roadmap](roadmap.md) tracks both.

## The GitHub API limit

GitHub's API answers 60 requests an hour per address without a token. A Linux install makes one per release download, about 18 (22 on the RHEL family), plus one for each latest release that is too young to install (see [Release age](#release-age)). Repeated installs behind one address, such as several `tests/fresh_install.sh` runs, can exceed that.

Set `GITHUB_TOKEN` to raise the limit, for example `GITHUB_TOKEN="$(gh auth token)" ~/dotfiles/install.sh`. The token goes to curl on stdin, so it never shows in the process list. A token GitHub refuses (HTTP 401, or 403 for one over its limit or kept out of an organization) is dropped with a warning and the request is made once more without it; any other failure (an outage, a missing repository) is not repeated without the token.

## Timeouts and retries

Every download the Unix bootstrap makes with curl (the releases and their tag lookups, the GitHub API, the apt and dnf keys, the bat theme, the Homebrew installer) has limits, so a bad network ends in an error, not a hang:

- **Limits:** a connection not made in 30 seconds, or a try that averages under a byte a second for a minute, ends as a timeout.
- **Retries:** a timeout, a name that does not resolve, or an HTTP 408, 429, 500, 502, 503 or 504 answer is tried again up to seven times, 1, 2, 4 ... 64 seconds apart (about two minutes of waiting), and no try starts after three minutes. Each failed try prints a `curl: (<number>) ...` line; the run fails only when the last one fails.
- **Worst case:** a download that cannot get through gives up within about 4 minutes, a GitHub API request within about 2. A transfer that keeps moving, however slowly, is left alone.
- **At once:** a refused connection, and HTTP errors such as 401, 403 and 404.
- **Not covered:** git clones (zinit, TPM, lazy.nvim, the yazi flavors), apt, dnf, Homebrew, mise, Mason and the whole Windows install, which does not use curl. They wait as their own tools do.

## Release age

The Unix bootstrap installs a GitHub release only once it has been public for a day: a bad or hijacked release is usually noticed and pulled within hours, and its digest cannot tell (see [Verified downloads](#verified-downloads)). This covers the release tools (oh-my-posh, zoxide and mise among them), Neovim, the tree-sitter CLI and the Linux Nerd Font, on a first install and in the update.

- **Which release:** the one the project marks latest, once it is old enough. Until then, the highest version among the project's 30 most recent releases that is old enough and lists the file this machine needs with a SHA-256 digest; the bootstrap says which release it passed over. Prereleases, drafts and tags that are not plain version numbers (`stable`, `nightly`, `v1.0-rc.1`) never count.
- **Updates:** the update keeps the installed release until a newer one is old enough, and never moves a tool to a release older than the one recorded (Neovim and the tree-sitter CLI also compare the version they run), even when a project deletes its newest releases.
- **Late changes:** a release whose files changed after it was published counts from the change.
- **The setting:** `DOTFILES_MINIMUM_RELEASE_AGE` is a whole number with a unit, `s`, `m` (minutes), `h`, `d` or `w`, such as `12h` or `3d`, the form mise's installer reads; `0` takes every release at once. Set it for one run (`DOTFILES_MINIMUM_RELEASE_AGE=3d ~/dotfiles/scripts/update.sh`) or export it from `~/.zshrc.local`. A value the bootstrap cannot read stops the installer before it changes anything.
- **mise:** when `DOTFILES_MINIMUM_RELEASE_AGE` is set, the bootstrap passes it to mise as `MISE_MINIMUM_RELEASE_AGE`, unless that is already in the environment. mise's self-update and its runtime installs (Node.js) honour it ahead of a `minimum_release_age` in mise's configuration, though behind mise's own self-update setting (`MISE_SELF_UPDATE_MINIMUM_RELEASE_AGE` or `self_update.minimum_release_age`). Unset, mise decides: a day by default.
- **The clock:** ages are measured against this machine's clock. A clock that runs ahead shortens the delay. One far behind makes every release look young: a tool that is not installed yet then stops the run, saying so.
- **Not covered:** packages from Homebrew, apt (the eza and Charm repositories included), dnf (EPEL and Charm's repository included) and winget, plugins from git, the language servers Mason installs, and on Windows the PowerShell modules and the Nerd Font that `oh-my-posh font install` fetches. There mise comes from winget, and only its runtime installs wait mise's own day. [The roadmap](roadmap.md) tracks these.

The notes the bootstrap prints about releases it passed over are not errors; [troubleshooting](troubleshooting.md#messages-that-look-like-errors) lists them.
