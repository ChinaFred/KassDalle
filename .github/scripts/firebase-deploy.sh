#!/usr/bin/env bash
# Déploiement Firebase vérifié, pour le workflow « Déploiement ».
#
# Un code de sortie 0 ne prouve pas que la CLI a déployé. Elle s'arrête
# parfois après « Loading and analyzing source code » et rend 0 sans rien
# mettre en ligne. Elle peut aussi rendre 0 alors que des Functions ont
# échoué (« Functions deploy had errors »). Le succès exige donc les trois :
# code 0, « Deploy complete », et aucune ligne « Functions deploy had errors ».
#
# La relance vise les fonctions en échec, comme deploy.ps1. Une relance
# complète saute les fonctions dont le code n'a pas changé (« Skipped (No
# changes detected) ») : une fonction dont le code est parti mais dont la file
# Cloud Tasks a échoué serait sautée, et la relance annoncerait un succès.
# Une fonction nommée par --only functions:<nom> n'est jamais sautée.
#
# Usage : firebase-deploy.sh <cibles> [tentatives] [options de la CLI…]
#   firebase-deploy.sh functions 2 --force
#   firebase-deploy.sh hosting,firestore,storage
set -uo pipefail

targets="$1"
attempts="${2:-1}"
shift $(( $# > 1 ? 2 : 1 ))
project="kassdale-6d948"

# deploy <cibles> : lance la CLI, écrit son journal dans $log, rend son code.
deploy() {
  echo "::group::firebase deploy --only $1 ${*:2}"
  firebase deploy --only "$1" --project "$project" --non-interactive "${@:2}" 2>&1 | tee "$log"
  local status="${PIPESTATUS[0]}"
  echo "::endgroup::"
  return "$status"
}

succeeded() {
  [ "$1" -eq 0 ] && grep -q "Deploy complete" "$log" && ! grep -q "Functions deploy had errors" "$log"
}

log="$(mktemp)"
trap 'rm -f "$log"' EXIT
current="$targets"

for attempt in $(seq 1 "$attempts"); do
  echo "Tentative $attempt/$attempts : $current"
  deploy "$current" "$@"
  status=$?
  if succeeded "$status"; then
    exit 0
  fi

  if grep -q "Functions deploy had errors" "$log"; then
    # Liste écrite par la CLI : une ligne « <tab>nom(région) » par fonction.
    failed=$(sed -n '/Functions deploy had errors with the following functions:/,/^[^[:space:]]/p' "$log" \
      | grep -E $'^\t[A-Za-z0-9_-]+\\(' | sed -E $'s/^\t([A-Za-z0-9_-]+)\\(.*/\\1/' | sort -u)
    echo "::warning::firebase deploy $current : des Functions ont échoué : ${failed//$'\n'/, }"
    grep -E "lacks IAM permission|HTTP Error: 403|Permission denied" "$log" | sed 's/^/::warning::/' || true
    if [ -n "$failed" ]; then
      current=$(printf 'functions:%s,' $failed)
      current="${current%,}"
    fi
  elif [ "$status" -eq 0 ]; then
    echo "::warning::firebase deploy $current a rendu 0 sans « Deploy complete »."
  else
    echo "::warning::firebase deploy $current a échoué (code $status)."
  fi
done

echo "::error::firebase deploy $targets n'a pas abouti après $attempts tentative(s)."
exit 1
