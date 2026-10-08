#!/usr/bin/env bash
# Déploiement Firebase vérifié, pour le workflow « Déploiement ».
#
# Même défiance que deploy.ps1 : un code de sortie 0 ne prouve pas que la CLI
# a déployé. Elle s'arrête parfois après « Loading and analyzing source code »
# et rend 0 sans rien mettre en ligne. Seule la ligne « Deploy complete! » dit
# que le travail est fait.
#
# Usage : firebase-deploy.sh <cibles> [tentatives]
#   firebase-deploy.sh functions 2
#   firebase-deploy.sh hosting,firestore,storage
set -uo pipefail

targets="$1"
attempts="${2:-1}"
project="kassdale-6d948"

for attempt in $(seq 1 "$attempts"); do
  log="$(mktemp)"
  echo "::group::firebase deploy --only $targets (tentative $attempt/$attempts)"
  firebase deploy --only "$targets" --project "$project" --non-interactive --force 2>&1 | tee "$log"
  status="${PIPESTATUS[0]}"
  echo "::endgroup::"

  if [ "$status" -eq 0 ] && grep -q "Deploy complete" "$log"; then
    rm -f "$log"
    exit 0
  fi
  if [ "$status" -eq 0 ]; then
    echo "::warning::firebase deploy $targets a rendu 0 sans « Deploy complete »."
  else
    echo "::warning::firebase deploy $targets a échoué (code $status)."
  fi
  rm -f "$log"
done

echo "::error::firebase deploy $targets n'a pas abouti après $attempts tentative(s)."
exit 1
