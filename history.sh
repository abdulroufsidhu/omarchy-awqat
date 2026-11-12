#!/bin/sh
# Prayer history for the abdulroufsidhu.awqat bar widget. The only writer of
# the history file, called by the panel and by check-in notification buttons.
#
#   history.sh set <YYYY-MM-DD> <fajr|dhuhr|asr|maghrib|isha> <jamaat|alone|late|missed|none>
#   history.sh path
#
# File: ${XDG_DATA_HOME:-~/.local/share}/abdulroufsidhu.awqat/history.json
#   { "version": 1, "days": { "2026-11-10": { "fajr": "jamaat", "asr": "late", ... } } }

set -u
data="${XDG_DATA_HOME:-$HOME/.local/share}/abdulroufsidhu.awqat"
file="$data/history.json"

case ${1:-} in
  path) echo "$file"; exit 0 ;;
  set) ;;
  *) echo "usage: history.sh set <date> <prayer> <status> | path" >&2; exit 1 ;;
esac

[ $# -eq 4 ] || { echo "history.sh set needs <date> <prayer> <status>" >&2; exit 1; }
date=$2 prayer=$3 status=$4

case $date in [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]) ;; *) echo "bad date: $date" >&2; exit 1 ;; esac
case $prayer in fajr | dhuhr | asr | maghrib | isha) ;; *) echo "bad prayer: $prayer" >&2; exit 1 ;; esac
case $status in jamaat | alone | late | missed | none) ;; *) echo "bad status: $status" >&2; exit 1 ;; esac

mkdir -p "$data" || exit 1
exec 9>"$data/.lock"
flock -w 5 9 || { echo "history is busy" >&2; exit 1; }

current='{"version":1,"days":{}}'
if [ -s "$file" ]; then
  if jq -e 'type == "object" and (.days | type == "object")' "$file" >/dev/null 2>&1; then
    current=$(cat "$file")
  else
    # Unreadable: keep it for the record and start a fresh one.
    mv "$file" "$file.broken.$(date +%s)"
  fi
fi

tmp="$file.tmp.$$"
printf '%s' "$current" | jq --arg d "$date" --arg p "$prayer" --arg s "$status" '
  .version = 1
  | if $s == "none" then del(.days[$d][$p]) else .days[$d][$p] = $s end
  | if (.days[$d] // {}) == {} then del(.days[$d]) else . end
' >"$tmp" && mv -f "$tmp" "$file" || { rm -f "$tmp"; exit 1; }
