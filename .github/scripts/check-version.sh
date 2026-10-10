#!/usr/bin/env bash
# Vérifie qu'un changement de version ne réutilise pas un numéro déjà pris.
#
# Usage, depuis la racine du dépôt :
#   check-version.sh <base> <tête>
#
#   <base>  la tête de master avant ce changement (CI d'un push : le commit
#           d'avant le push ; CI d'une PR et PC avant un push : origin/master)
#   <tête>  le commit à vérifier
#
# Deux contrôles.
#
# 1. Doublon dans l'historique, toujours. Le nom de version de <tête> (avant
#    le « + ») ne doit avoir été introduit que par un seul commit ordinaire
#    de son historique. Ce contrôle ne dépend pas de la plage poussée : après
#    un push refusé pour doublon, un push suivant qui ne touche pas la
#    version échoue encore, et la CI annulée d'un push ne laisse pas passer
#    son doublon.
#
# 2. Hausse par rapport à <base>, quand le changement touche la version :
#    l'un de ses commits ordinaires modifie la ligne `version:` de
#    pubspec.yaml par rapport à son parent, ou <tête> descend de <base> et
#    n'a pas sa version (hausse faite dans un commit de fusion). Les commits
#    de fusion ne comptent pas comme hausse : fusionner master dans une
#    branche y apporte la version de master sans que la branche l'ait
#    choisie. Le nom de <tête> doit alors être strictement supérieur à celui
#    de <base>.
#
# Et dans tous les cas, CHANGELOG.md doit porter au moins une entrée
# « ### v<nom> — fonctionnel » ou « ### v<nom> — technique » pour la version
# de <tête>, au plus une de chaque type, et aucun autre titre « ### v<nom> ».
# Quand il y en a deux, un seul commit ordinaire doit les avoir ajoutés :
# deux livraisons au même numéro, intégrées par rebase, laissent un titre par
# livraison, chacun ajouté par son propre commit.
#
set -euo pipefail

base="$1"
head="$2"
pubspec="kass_dalle/pubspec.yaml"
changelog="documentation/CHANGELOG.md"

version_at() {
  git show "$1:$pubspec" 2>/dev/null | grep -m1 '^version:' | sed 's/^version:[[:space:]]*//' | tr -d '\r' || true
}

if ! git cat-file -e "$head^{commit}" 2>/dev/null; then
  echo "::error::Commit $head introuvable."
  exit 1
fi

name_of() {
  local raw
  raw=$(version_at "$1")
  echo "${raw%%+*}"
}

status=0
head_name=$(name_of "$head")

# 1. Doublon dans l'historique.
introductions=""
pubspec_commits=$(git log --full-history --no-merges --format=%H -G'^version:' "$head" -- "$pubspec")
for commit in $pubspec_commits; do
  if [ "$(name_of "$commit")" = "$head_name" ] && [ "$(name_of "$commit^")" != "$head_name" ]; then
    introductions="$introductions $(git rev-parse --short "$commit")"
  fi
done
count=$(echo "$introductions" | wc -w)
if [ "$count" -gt 1 ]; then
  echo "::error file=$pubspec::v$head_name a été introduite par $count commits ($introductions ) : deux livraisons portent ce numéro. Intégrer origin/master, qui porte peut-être déjà la correction ; si le doublon vient de ce changement, reprendre la version de master + 1 dans pubspec.yaml et dans les titres de CHANGELOG.md pour cette version."
  status=1
fi

# Les entrées du CHANGELOG pour la version de la tête, toujours : un rebase
# sur une hausse identique vide le changement de pubspec.yaml, et seul le
# CHANGELOG garde alors la trace des deux livraisons.
prefix="### v$head_name "
titles_at() {
  git show "$1:$changelog" 2>/dev/null | tr -d '\r' | awk -v p="$prefix" 'index($0, p) == 1' || true
}
titles=$(titles_at "$head")
entries=$(printf '%s' "$titles" | grep -c . || true)
kinds=$(printf '%s\n' "$titles" | sed -n 's/^### v[^ ]* — \(fonctionnel\|technique\)[[:space:]]*$/\1/p')
valid=$(printf '%s' "$kinds" | grep -c . || true)
repeated=$(printf '%s\n' "$kinds" | grep . | sort | uniq -d || true)
if [ "$entries" = "0" ]; then
  echo "::error file=$changelog::CHANGELOG.md n'a aucune entrée « ### v$head_name — fonctionnel » ni « — technique »."
  status=1
elif [ "$valid" != "$entries" ]; then
  echo "::error file=$changelog::CHANGELOG.md porte un titre « ### v$head_name » qui ne se termine ni par « — fonctionnel » ni par « — technique »."
  status=1
elif [ -n "$repeated" ]; then
  echo "::error file=$changelog::CHANGELOG.md porte deux titres « ### v$head_name — $repeated » : deux livraisons portent ce numéro. Reprendre la version de master + 1."
  status=1
elif [ "$entries" = "2" ]; then
  adders=""
  changelog_commits=$(git log --full-history --no-merges --format=%H -S"$prefix" "$head" -- "$changelog")
  for commit in $changelog_commits; do
    now=$(titles_at "$commit" | grep -c . || true)
    before=$(titles_at "$commit^" | grep -c . || true)
    if [ "$now" -gt "$before" ]; then
      adders="$adders $(git rev-parse --short "$commit")"
    fi
  done
  if [ "$(echo "$adders" | wc -w)" -gt 1 ]; then
    echo "::error file=$changelog::Les deux titres « ### v$head_name » ont été ajoutés par des commits distincts ($adders ) : deux livraisons portent peut-être ce numéro. Reprendre la version de master + 1 ; s'il s'agit d'une seule livraison, ajouter les deux titres dans le même commit."
    status=1
  fi
fi

# 2. Hausse par rapport à la base.
if ! git cat-file -e "$base^{commit}" 2>/dev/null; then
  echo "Base $base introuvable (premier push, ou historique réécrit) : hausse non vérifiée."
  exit "$status"
fi

touched=""
range_commits=$(git rev-list --no-merges "$base..$head")
for commit in $range_commits; do
  mine=$(version_at "$commit")
  parent=$(version_at "$commit^")
  if [ -n "$mine" ] && [ "$mine" != "$parent" ]; then
    touched="$(git rev-parse --short "$commit")"
    break
  fi
done
if [ -z "$touched" ] && git merge-base --is-ancestor "$base" "$head" &&
  [ "$(version_at "$base")" != "$(version_at "$head")" ]; then
  touched="un commit de fusion"
fi

if [ -z "$touched" ]; then
  [ "$status" = 0 ] && echo "Aucun commit ne change la version, v$head_name n'a qu'une origine, son entrée au CHANGELOG est correcte."
  exit "$status"
fi

base_raw=$(version_at "$base")
head_raw=$(version_at "$head")
base_name="${base_raw%%+*}"
echo "Version changée par $touched : master v$base_raw, ce changement v$head_raw."

newest=$(printf '%s\n%s\n' "$base_name" "$head_name" | sort -V | tail -1)
if [ "$head_name" = "$base_name" ] || [ "$newest" != "$head_name" ]; then
  echo "::error file=$pubspec::La version v$head_name n'est pas supérieure à celle de master (v$base_name). Une autre livraison a pris ce numéro : reprendre v$base_name + 1 dans pubspec.yaml et dans les titres de CHANGELOG.md pour cette version."
  status=1
fi


[ "$status" = 0 ] && echo "v$head_name suit v$base_name, entrée au CHANGELOG correcte."
exit "$status"
