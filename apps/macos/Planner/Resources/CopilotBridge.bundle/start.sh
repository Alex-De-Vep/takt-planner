#!/bin/bash
set -euo pipefail
umask 077
if ! command -v node >/dev/null || ! command -v npm >/dev/null; then
    printf '%s\n' 'GitHub Copilot requires Node.js 22.12 or later. https://nodejs.org/'
    exit 1
fi
node -e 'const [major, minor] = process.versions.node.split(".").map(Number); if (major < 22 || major === 22 && minor < 12) { console.error("GitHub Copilot requires Node.js 22.12 or later."); process.exit(1); }'
source_dir="$(cd "$(dirname "$0")" && pwd)"
runtime_dir="$HOME/Library/Application Support/Tasks Copilot/1.0.0"
mkdir -p "$runtime_dir"
cd "$runtime_dir"
if ! cmp -s "$source_dir/package-lock.json" package-lock.json || [ ! -x node_modules/.bin/copilot ]; then
    cp "$source_dir/package.json" "$source_dir/package-lock.json" .
    npm ci --omit=dev --no-audit --no-fund
fi
cp "$source_dir/bridge.mjs" .
mkdir -p workspace
# Отдельный каталог настроек CLI. Не наследуем сторонние токены и режим BYOK.
export COPILOT_HOME="$runtime_dir/account"
unset COPILOT_GITHUB_TOKEN GH_TOKEN GITHUB_TOKEN GITHUB_COPILOT_API_TOKEN COPILOT_API_URL COPILOT_PROVIDERS_CONFIG
unset COPILOT_PROVIDER_BASE_URL COPILOT_PROVIDER_API_KEY COPILOT_PROVIDER_TYPE COPILOT_PROVIDER_MODEL
if node bridge.mjs; then
    exit 0
else
    status=$?
    [ "$status" = 42 ] || exit "$status"
fi
./node_modules/.bin/copilot login --web-flow
exec node bridge.mjs
