#!/usr/bin/env bash
# Publie la mémoire et le disque libres du runner, en annotation du run.
#
# Une annotation « ::notice:: » reste visible sur la page du run même quand le
# journal du job est perdu, ce qui arrive quand le runner ne répond plus.
#
# Usage : runner-resources.sh <moment>
set -euo pipefail

mem=$(free -m | awk '/^Mem:/ {print $7 " Mo libres sur " $2}')
disk=$(df -h / | awk 'NR == 2 {print $4 " libres sur " $2}')
echo "::notice::Runner, $1 : mémoire $mem ; disque $disk."
