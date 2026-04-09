#!/usr/bin/env bash
# Install Terragrunt binary.
# Usage: install-terragrunt.sh <version>
set -euo pipefail

VERSION="${1:?Usage: install-terragrunt.sh <version>}"
ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
URL="https://github.com/gruntwork-io/terragrunt/releases/download/v${VERSION}/terragrunt_linux_${ARCH}"

echo "Installing Terragrunt v${VERSION} (${ARCH})..."
curl -sLo /usr/local/bin/terragrunt "$URL"
chmod +x /usr/local/bin/terragrunt
terragrunt --version
