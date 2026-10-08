#!/usr/bin/env bash
# Recopie dans <dossier> l'APK et le manifeste actuellement en ligne.
#
# Le déploiement du hosting remplace tout le contenu en ligne par build/web.
# Sans cette copie, le lien de téléchargement passerait en 404 et le manifeste
# lu par l'application Android disparaîtrait.
#
# Un fichier absent ne rend pas 404 : la réécriture « ** » de firebase.json
# sert index.html à sa place, avec un code 200. Le contenu est donc jugé : un
# manifeste JSON qui porte une version, un APK qui commence par « PK ».
#
# Même règle que Publish-ApkPayload (deploy.ps1) :
#   - APK et manifeste cohérents : recopiés ;
#   - APK seul : recopié sans manifeste, aucune mise à jour annoncée ;
#   - ni l'un ni l'autre : rien n'est recopié ;
#   - manifeste seul, ou taille différente : échec, car le manifeste
#     annoncerait une version que le téléchargement ne rend pas.
#
# Usage : keep-online-apk.sh <dossier>
set -euo pipefail

dir="$1"
site="https://kassdale-6d948.web.app"
apk="$dir/app-release.apk"
manifest="$dir/apk_release.json"
mkdir -p "$dir"
curl -sS --fail -o "$apk" "$site/app-release.apk"
curl -sS --fail -o "$manifest" "$site/apk_release.json"

has_manifest=false
if jq -e '.version | strings' "$manifest" >/dev/null 2>&1; then has_manifest=true; fi
has_apk=false
if [ "$(head -c 2 "$apk")" = "PK" ]; then has_apk=true; fi

if $has_apk && $has_manifest; then
  version=$(jq -r .version "$manifest")
  size=$(jq -r .size_bytes "$manifest")
  actual=$(stat -c %s "$apk")
  if [ "$size" != "$actual" ]; then
    echo "::error::APK en ligne de $actual octets, manifeste annonçant $size : paire incohérente."
    exit 1
  fi
  echo "APK en ligne conservé : v$version ($actual octets)."
elif $has_apk; then
  rm -f "$manifest"
  echo "::warning::APK en ligne sans manifeste : publié sans rien annoncer aux téléphones."
elif ! $has_manifest; then
  rm -f "$apk" "$manifest"
  echo "::warning::Aucun APK en ligne : le site n'en proposera pas."
else
  echo "::error::Manifeste en ligne sans APK : il annoncerait une version absente."
  exit 1
fi
