#!/usr/bin/env bash
# Construction de l'APK signé, pour le workflow « Déploiement ».
#
# Deux sous-commandes, lancées depuis kass_dalle/ :
#
#   build-apk.sh decide <manifeste-en-ligne>
#     Écrit « build=true » dans $GITHUB_OUTPUT si la version de pubspec.yaml
#     est plus récente que celle de l'APK en ligne, ou s'il n'y a pas d'APK en
#     ligne. Sinon « build=false » : l'APK en ligne est conservé tel quel.
#     Une version plus ancienne que celle en ligne (un deploy.ps1 a publié plus
#     récent) ne reconstruit rien.
#
#   build-apk.sh build
#     Construit l'APK signé avec la clé du PC, posée en secrets GitHub, puis le
#     copie dans build/web avec son manifeste. La clé et key.properties sont
#     supprimés à la sortie, réussite ou échec.
#
# Le manifeste a les mêmes champs que celui de Write-ApkManifest (deploy.ps1) :
# l'application Android le lit pour savoir si une mise à jour existe, et la
# version qu'il porte est celle du binaire posé à côté.
set -euo pipefail

pubspec_version() {
  grep -m1 '^version:' pubspec.yaml | sed 's/^version:[[:space:]]*//' | tr -d '\r'
}

case "${1:-}" in
  decide)
    manifest="$2"
    raw=$(pubspec_version)
    version="${raw%%+*}"
    build="${raw#*+}"
    [ "$build" = "$raw" ] && build=0

    if [ ! -f "$manifest" ]; then
      echo "Aucun APK en ligne : construction de v$raw."
      echo "build=true" >> "$GITHUB_OUTPUT"
      exit 0
    fi

    online_version=$(jq -r '.version // ""' "$manifest")
    online_build=$(jq -r '.build_number // "" | tostring' "$manifest")
    [ -z "$online_build" ] && online_build=0

    newest=$(printf '%s\n%s\n' "$version" "$online_version" | sort -V | tail -1)
    if [ "$version" != "$online_version" ] && [ "$newest" = "$version" ]; then
      decision=true
    elif [ "$version" = "$online_version" ] && [ "$build" -gt "$online_build" ]; then
      decision=true
    else
      decision=false
    fi

    if $decision; then
      echo "APK en ligne v$online_version+$online_build, pubspec v$raw : construction."
    else
      echo "APK en ligne v$online_version+$online_build, pubspec v$raw : APK conservé."
    fi
    echo "build=$decision" >> "$GITHUB_OUTPUT"
    ;;

  build)
    for name in ANDROID_KEYSTORE_BASE64 ANDROID_STORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD; do
      if [ -z "${!name:-}" ]; then
        echo "::error::Secret $name absent : impossible de signer l'APK. Voir TechnicalRequirements.md, « Déploiement automatique »."
        exit 1
      fi
    done

    keystore="$RUNNER_TEMP/upload-keystore.jks"
    properties="android/key.properties"
    trap 'rm -f "$keystore" "$properties"' EXIT

    printf '%s' "$ANDROID_KEYSTORE_BASE64" | base64 --decode > "$keystore"
    {
      echo "storeFile=$keystore"
      echo "storePassword=$ANDROID_STORE_PASSWORD"
      echo "keyAlias=$ANDROID_KEY_ALIAS"
      echo "keyPassword=$ANDROID_KEY_PASSWORD"
    } > "$properties"

    flutter build apk --release

    apk="build/app/outputs/flutter-apk/app-release.apk"
    [ -f "$apk" ] || { echo "::error::flutter build apk n'a pas produit $apk."; exit 1; }

    raw=$(pubspec_version)
    version="${raw%%+*}"
    build="${raw#*+}"
    [ "$build" = "$raw" ] && build=""

    cp "$apk" build/web/app-release.apk
    jq -nc \
      --arg version "$version" \
      --arg build_number "$build" \
      --arg file "app-release.apk" \
      --argjson size_bytes "$(stat -c %s build/web/app-release.apk)" \
      --arg built_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{version: $version, build_number: $build_number, file: $file, size_bytes: $size_bytes, built_at: $built_at}' \
      > build/web/apk_release.json
    echo "APK v$raw construit et posé dans build/web avec son manifeste."

    # Les démons Gradle et Kotlin restent en mémoire après le build :
    # android/gradle.properties donne 4 Go de tas à Gradle. Le 8 octobre 2026,
    # deux tentatives du workflow se sont arrêtées à l'étape qui suit les
    # Functions, l'une sans journal. Hypothèse non vérifiée : mémoire ou disque
    # du runner saturés. On arrête les démons, on attend leur sortie (30 s au
    # plus), puis on publie la mémoire et le disque restants.
    pkill -f GradleDaemon || echo "Aucun démon Gradle à arrêter."
    pkill -f KotlinCompileDaemon || echo "Aucun démon Kotlin à arrêter."
    for _ in $(seq 30); do
      pgrep -f 'GradleDaemon|KotlinCompileDaemon' >/dev/null || break
      sleep 1
    done
    ../.github/scripts/runner-resources.sh "après le build de l'APK"
    ;;

  *)
    echo "Usage : build-apk.sh decide <manifeste> | build" >&2
    exit 2
    ;;
esac
