#!/usr/bin/env bash
set -euo pipefail

# Check dependencies
for cmd in curl jq nix-prefetch-url sed grep; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: '$cmd' is required but not found in PATH." >&2
        exit 1
    fi
done

# Get the latest version from npm
echo "Checking latest version of opencode-linux-x64..."
NPM_RESPONSE=$(curl -sf https://registry.npmjs.org/opencode-linux-x64/latest) || {
    echo "Error: Failed to fetch latest version from npm registry." >&2
    echo "Check your internet connection and try again." >&2
    exit 1
}

LATEST_VERSION=$(echo "$NPM_RESPONSE" | jq -r '.version') || {
    echo "Error: Failed to parse version from npm response." >&2
    exit 1
}

if [ -z "$LATEST_VERSION" ] || [ "$LATEST_VERSION" = "null" ]; then
    echo "Error: npm returned an empty or null version." >&2
    exit 1
fi
echo "Latest version: $LATEST_VERSION"

# Get current version from default.nix
if [ ! -f default.nix ]; then
    echo "Error: default.nix not found. Run this script from the project root." >&2
    exit 1
fi

CURRENT_VERSION=$(grep -oP 'version = "\K[^"]*' default.nix) || {
    echo "Error: Could not read current version from default.nix." >&2
    exit 1
}
echo "Current version: $CURRENT_VERSION"

if [ "$LATEST_VERSION" = "$CURRENT_VERSION" ]; then
    echo "Already up to date!"
    exit 0
fi

echo "Updating $CURRENT_VERSION -> $LATEST_VERSION"

# Prefetch the tarball to get its hash
TARBALL_URL="https://registry.npmjs.org/opencode-linux-x64/-/opencode-linux-x64-${LATEST_VERSION}.tgz"
echo "Fetching hash for $TARBALL_URL..."
NEW_HASH=$(nix-prefetch-url --type sha256 "$TARBALL_URL" 2>/dev/null) || {
    echo "Error: Failed to download tarball or compute hash." >&2
    echo "URL: $TARBALL_URL" >&2
    exit 1
}

if [ -z "$NEW_HASH" ]; then
    echo "Error: nix-prefetch-url returned an empty hash." >&2
    exit 1
fi

# Update default.nix
sed -i "s/version = \".*\";/version = \"$LATEST_VERSION\";/" default.nix
sed -i "s/sha256 = \".*\";/sha256 = \"$NEW_HASH\";/" default.nix

# Verify the substitution worked
WRITTEN_VERSION=$(grep -oP 'version = "\K[^"]*' default.nix)
if [ "$WRITTEN_VERSION" != "$LATEST_VERSION" ]; then
    echo "Error: default.nix was not updated correctly (version mismatch)." >&2
    exit 1
fi

echo "default.nix updated."

echo "Running nix flake update..."
nix flake update

if [ -z "$(git status --porcelain)" ]; then
    echo "No changes to commit."
else
    echo "Committing changes..."
    git add -A
    git commit -m "chore: update to v${LATEST_VERSION}"
fi

if git rev-parse "v${LATEST_VERSION}" >/dev/null 2>&1; then
    echo "Tag v${LATEST_VERSION} already exists."
else
    echo "Tagging v${LATEST_VERSION}..."
    git tag "v${LATEST_VERSION}"
fi

echo "Pushing to origin..."
git push -f origin main
git push -f origin "v${LATEST_VERSION}"
