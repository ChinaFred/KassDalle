#!/bin/bash
# Prépare une session Claude Code cloud : Flutter (version de la CI), dépendances
# Functions et tests des règles, pour que les agents puissent rejouer analyze,
# format, lint et tests.
set -euo pipefail

# Agents et skills : un en-tête YAML invalide les retire de la session sans
# message. L'avertissement part sur stdout, que la session lit. Sur le poste
# comme dans le cloud ; n'échoue jamais.
check_agents() {
  if command -v node >/dev/null 2>&1; then
    node "$CLAUDE_PROJECT_DIR/.github/scripts/check-agents.mjs" --warn || true
  else
    echo "session-start : node absent, agents et skills non vérifiés."
  fi
}

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  check_agents
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
# Tests des règles : leurs dépendances s'installent toujours ; les émulateurs,
# eux, exigent Java 21 (firebase-tools 15). Son absence n'empêche pas la
# session de démarrer : seul `npm test` dans rules-tests échouera.
(cd "$PROJECT/rules-tests" && npm ci --no-audit --no-fund) \
  || echo "session-start : npm ci a échoué dans kass_dalle/rules-tests ; les tests des règles ne tourneront pas." >&2
java_major=$(java -version 2>&1 | sed -nE 's/.*version "([0-9]+).*/\1/p' | head -n 1)
if [ -z "$java_major" ]; then
  echo "session-start : Java absent, les tests des règles (kass_dalle/rules-tests) ne pourront pas lancer les émulateurs." >&2
elif [ "$java_major" -lt 21 ]; then
  echo "session-start : Java $java_major trouvé, les émulateurs des tests des règles exigent Java 21." >&2
fi
# Après npm ci : js-yaml vient de kass_dalle/functions/node_modules.
check_agents
