#!/bin/bash
# Prépare une session Claude Code cloud : Flutter (version de la CI) et dépendances
# Functions, pour que les agents puissent rejouer analyze, format, lint et tests.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# Même version que .github/workflows/ci.yml.
FLUTTER_VERSION="3.44.6"
FLUTTER_ROOT="$HOME/flutter"
PROJECT="$CLAUDE_PROJECT_DIR/kass_dalle"

if [ ! -x "$FLUTTER_ROOT/bin/flutter" ] \
  || ! grep -Eq "\"frameworkVersion\": *\"$FLUTTER_VERSION\"" "$FLUTTER_ROOT/bin/cache/flutter.version.json" 2>/dev/null; then
  rm -rf "$FLUTTER_ROOT"
  curl -fsSL "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
    | tar -xJ -C "$HOME"
fi

# Le tarball appartient à un autre utilisateur : git refuse le dépôt sans cette exception.
git config --global --get-all safe.directory | grep -qx "$FLUTTER_ROOT" \
  || git config --global --add safe.directory "$FLUTTER_ROOT"

export PATH="$FLUTTER_ROOT/bin:$PATH"
echo "export PATH=\"$FLUTTER_ROOT/bin:\$PATH\"" >> "$CLAUDE_ENV_FILE"

flutter config --no-analytics >/dev/null
flutter --disable-analytics >/dev/null 2>&1 || true
(cd "$PROJECT" && flutter pub get)
# npm ci : package-lock.json reste intact, comme en CI.
(cd "$PROJECT/functions" && npm ci --no-audit --no-fund)
