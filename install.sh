#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Installing packages"
bash "$DOTFILES_DIR/scripts/install_packages.sh"

echo "==> Linking dotfiles"
bash "$DOTFILES_DIR/scripts/link_dotfiles.sh"

echo "==> Bootstrapping tools"
bash "$DOTFILES_DIR/scripts/bootstrap_tools.sh"

echo ""
echo "Done. Open a new shell to apply changes."
echo "Run '$DOTFILES_DIR/scripts/doctor.sh' to verify the setup."
