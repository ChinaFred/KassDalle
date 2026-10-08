#!/usr/bin/env bash
# Publie la mémoire disponible et le disque libre du runner, en annotation du
# run.
#
# Une annotation « ::notice:: » reste sur la page du run une fois son étape
# terminée, même si le journal du job est perdu ensuite. C'est pourquoi le
# workflow l'appelle dans une étape à part.
#
# Un diagnostic n'arrête jamais un déploiement : pas de « set -e », et une
# mesure impossible devient un avertissement. Le script sort toujours en 0.
#
# Usage : runner-resources.sh <moment>
set -u

mem=$(free -m | awk '/^Mem:/ {print $7 " Mo disponibles sur " $2}') || mem=""
disk=$(df -h / | awk 'NR == 2 {print $4 " libres sur " $2}') || disk=""
if [ -z "$mem" ] || [ -z "$disk" ]; then
  echo "::warning::Runner, $1 : mesure de la mémoire ou du disque impossible."
else
  echo "::notice::Runner, $1 : mémoire $mem ; disque $disk."
fi
exit 0
