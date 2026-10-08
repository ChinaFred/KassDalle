#!/usr/bin/env bash
# Déploiement Firebase vérifié, pour le workflow « Déploiement ».
#
# Un code de sortie 0 ne prouve pas que la CLI a déployé. Elle s'arrête
# parfois après « Loading and analyzing source code » et rend 0 sans rien
# mettre en ligne. Elle peut aussi rendre 0 alors que des Functions ont
# échoué (« Functions deploy had errors »). Le succès exige donc les trois :
# code 0, « Deploy complete », et aucune ligne « Functions deploy had errors ».
#
# Usage : firebase-deploy.sh <cibles> [tentatives] [options de la CLI…]
#   firebase-deploy.sh functions 2 --force
#   firebase-deploy.sh hosting,firestore,storage
set -uo pipefail

targets="$1"
attempts="${2:-1}"
shift $(( $# > 1 ? 2 : 1 ))
project="kassdale-6d948"

for attempt in $(seq 1 "$attempts"); do
  log="$(mktemp)"
  echo "::group::firebase deploy --only $targets $* (tentative $attempt/$attempts)"
  firebase deploy --only "$targets" --project "$project" --non-interactive "$@" 2>&1 | tee "$log"
  status="${PIPESTATUS[0]}"
  echo "::endgroup::"

  if [ "$status" -eq 0 ] && grep -q "Deploy complete" "$log" \
    && ! grep -q "Functions deploy had errors" "$log"; then
    rm -f "$log"
    exit 0
  fi
  if grep -q "Functions deploy had errors" "$log"; then
    echo "::warning::firebase deploy $targets : des Functions ont échoué."
    grep -E "Failed to (update|create) function" "$log" | sed 's/^/::warning::/' || true
  elif [ "$status" -eq 0 ]; then
    echo "::warning::firebase deploy $targets a rendu 0 sans « Deploy complete »."
  else
    echo "::warning::firebase deploy $targets a échoué (code $status)."
  fi
  rm -f "$log"
done

echo "::error::firebase deploy $targets n'a pas abouti après $attempts tentative(s)."
exit 1
