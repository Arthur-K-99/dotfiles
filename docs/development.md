# Development

Checks to run before committing, and how CI tries the installers. Planned work, and the checklist for adding a tool, are in the [roadmap](roadmap.md#adding-a-tool-the-checklist); switching the Catppuccin flavor is in [theming](theming.md).

## Repository checks

Run `bash scripts/test.sh` before committing installer or configuration changes.

- It checks the syntax of every Bash script, `home/.zshrc`, the TOML and JSON configuration files, the tmux configuration (loaded into a private server), the Neovim configuration (every Lua file parses and the plugin specs match `lazy-lock.json`), the Ghostty configuration and the oh-my-posh configuration.
- `tests/unix.Tests.sh` and `tests/windows.Tests.ps1` use temporary destinations and mocked installation commands to exercise reruns and failures without installing packages or changing your configuration.
- Missing optional validation tools (zsh, pwsh, python3, tmux, nvim, ghostty, oh-my-posh) are reported as skipped checks.
- `pwsh -NoProfile -NonInteractive -File tests/windows.Tests.ps1` runs the Windows behavioral suite alone, and `bash tests/unix.Tests.sh <name>` one Unix test.
- CI runs the checks on macOS, Linux and Windows, including Windows PowerShell 5.1 and PowerShell 7.

## Fresh install

```sh
bash tests/fresh_install.sh debian:12    # or debian:13, ubuntu:24.04, ubuntu:26.04, rockylinux/rockylinux:9
```

- It installs the checkout in a new container as a user with sudo, with real downloads, then reruns the installer and runs `scripts/update.sh`, after setting every recorded release tag back so the update fetches each release again.
- It then types a few commands into an interactive zsh on a pseudo-terminal (under `script`), so zsh draws its prompt and runs every init script, the prompt hooks (oh-my-posh, atuin, direnv) and zoxide's `cd`. It loads tmux with its plugins as well, and fails on any error either prints.
- A stage that passes but prints a line that reads as an error fails too: `FRESH_INSTALL_NOISE` in `tests/fresh_install.sh` lists the patterns (`Plugin … is not installed`, lines starting with `Error` or `fatal:`, `tput:`, `can't change option`).
- It needs Docker and takes several minutes. The checkout is mounted read-only and copied into the container, and the container is removed afterwards.
- A Mac runs the arm64 images and should be told so with `DOCKER_DEFAULT_PLATFORM=linux/arm64`: pulling an image for linux/amd64 retags the local copy, and later runs then emulate x86_64 without saying so.
- An install and its update make about 35 GitHub API requests, against 60 an hour per address without a token; for several runs in a row pass `GITHUB_TOKEN="$(gh auth token)"`, which reaches the container ([downloads](downloads.md#the-github-api-limit)).
- `bash tests/fresh_install.sh --here` runs the same on the current machine, for a disposable one such as a CI runner.

The Fresh install workflow runs it for every image on x86_64, plus a macOS runner, on pull requests that touch the Unix install, every Monday, and on demand from the Actions tab, so upstream changes such as a renamed release asset show up before the next new machine. GitHub pauses the weekly run after 60 days without a commit; the Actions tab turns it back on.

**Windows:** `tests/fresh_install.ps1` does the same on a disposable Windows machine. It changes the machine beyond the install, so run it only where that does not matter.

- **Run it:** `powershell -NoProfile -File tests\fresh_install.ps1 -Disposable` from the checkout, or one stage with `-Stage Prepare|Install|Rerun|Update|Doctor|Shells|Collect` (default `All`). Outside GitHub Actions it refuses to run without `-Disposable`, and Prepare refuses a profile that is already a link, which it would write through.
- **What it does:** seeds older fzf and Carapace packages and placeholder profiles; installs from Windows PowerShell as the README says; checks that the rerun changes nothing; pins sd and updates from PowerShell 7; runs the doctor in both editions; starts both editions with the profile (nothing on stderr, a time limit) and Neovim with every parser.
- **CI:** the Fresh install (Windows) workflow runs it on a `windows-2025` runner on pull requests that touch the Windows install or the configuration, every Monday and on demand, in about 17 minutes, and uploads its transcripts. It can stop at the font with "The file cannot be accessed by the system" from winget's oh-my-posh (once in 13 runs); rerun the job ([roadmap](roadmap.md)).
