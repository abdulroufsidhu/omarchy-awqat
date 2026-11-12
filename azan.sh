#!/bin/sh
# Azan alarm for the abdulroufsidhu.awqat bar widget.
#
#   azan.sh fire <marker> <sound> <maxSeconds> <notification args...>
#       Shows a critical notification and loops <sound> until stopped, the
#       notification is dismissed, or <maxSeconds> pass (0 = no limit).
#   azan.sh notify <marker> <notification args...>
#       A plain notification (used for "prayer soon" reminders).
#   azan.sh ask <marker> <glyph> <title> <body> <date> <prayer> <4 button labels>
#       "Did you pray X?" with Jamaat / Alone / Late / Missed buttons; a
#       listener records the answer via history.sh.
#   azan.sh stop       Stops the azan and closes its notification.
#   azan.sh status     Prints "playing" while the azan plays.
#
# <marker> names a directory created once per event, so when one widget copy
# per monitor fires the same event only the first one goes through.
# All values arrive as separate arguments; none is evaluated by the shell.

set -u
dir="${XDG_RUNTIME_DIR:-/tmp}/abdulroufsidhu.awqat"
self=$(readlink -f "$0")

claim() {
  case $1 in *[!A-Za-z0-9-]* | "") exit 0 ;; esac
  mkdir -p "$dir" || exit 0
  find "$dir" -mindepth 1 -maxdepth 1 -type d -mmin +1440 -exec rmdir {} + 2>/dev/null
  mkdir "$dir/$1" 2>/dev/null || exit 0
}

close_notification() {
  id=$(cat "$dir/notification.id" 2>/dev/null)
  rm -f "$dir/notification.id"
  case $id in '' | *[!0-9]*) return ;; esac
  busctl --user call org.freedesktop.Notifications /org/freedesktop/Notifications \
    org.freedesktop.Notifications CloseNotification u "$id" >/dev/null 2>&1
}

# Closes the notification before killing the player's process group: when
# the time limit runs out, stop runs inside that group and would end itself.
stop() {
  pid=$(cat "$dir/player.pid" 2>/dev/null)
  rm -f "$dir/player.pid"
  close_notification
  case $pid in '' | *[!0-9]*) ;; *) kill -TERM -- "-$pid" 2>/dev/null ;; esac
}

cmd=${1:-}
[ $# -gt 0 ] && shift

case $cmd in
  fire)
    [ $# -ge 4 ] || exit 1
    claim "$1"
    sound=$2 max=$3
    shift 3
    stop
    id=$(omarchy-notification-send -p -u critical "$@" 2>/dev/null)
    printf '%s\n' "$id" >"$dir/notification.id"
    if [ -f "$sound" ] && [ -r "$sound" ]; then
      setsid sh "$self" play "$sound" "$max" "$id" </dev/null >/dev/null 2>&1 &
    fi
    ;;

  notify)
    [ $# -ge 2 ] || exit 1
    claim "$1"
    shift
    exec omarchy-notification-send "$@"
    ;;

  ask)
    # azan.sh ask <marker> <glyph> <title> <body> <date> <prayer> <jamaat label> <alone label> <late label> <missed label>
    # "Did you pray X?" with four buttons. Omarchy's own command buttons stop
    # at three, so these are standard notification actions: the shell signals
    # which one was pressed, and a listener (azan.sh listen) records it. A
    # click on the card itself only closes it. It stays until answered.
    [ $# -eq 10 ] || exit 1
    claim "$1"
    glyph=$2 title=$3 body=$4 date=$5 prayer=$6
    case $date in [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]) ;; *) exit 1 ;; esac
    case $prayer in fajr | dhuhr | asr | maghrib | isha) ;; *) exit 1 ;; esac
    reply=$(busctl --user -- call org.freedesktop.Notifications /org/freedesktop/Notifications \
      org.freedesktop.Notifications Notify 'susssasa{sv}i' \
      "Awqat" 0 "" "$title" "$body" \
      8 jamaat "$7" alone "$8" late "$9" missed "${10}" \
      2 urgency y 1 omarchy-glyph s "$glyph" \
      0) || exit 1
    id=${reply#u }
    case $id in '' | *[!0-9]*) exit 1 ;; esac
    setsid sh "$self" listen "$id" "$date" "$prayer" </dev/null >/dev/null 2>&1 &
    ;;

  listen)
    # azan.sh listen <notification id> <date> <prayer>: records the button
    # pressed on a check-in, then ends; also ends when it closes unanswered,
    # or after 12 hours.
    [ $# -eq 3 ] || exit 1
    id=$1 date=$2 prayer=$3
    hist="$(dirname "$self")/history.sh"
    timeout 43200 gdbus monitor --session --dest org.freedesktop.Notifications \
      --object-path /org/freedesktop/Notifications 2>/dev/null |
      while read -r line; do
        case $line in
          *"ActionInvoked (uint32 $id, 'jamaat')"*) sh "$hist" set "$date" "$prayer" jamaat; break ;;
          *"ActionInvoked (uint32 $id, 'alone')"*) sh "$hist" set "$date" "$prayer" alone; break ;;
          *"ActionInvoked (uint32 $id, 'late')"*) sh "$hist" set "$date" "$prayer" late; break ;;
          *"ActionInvoked (uint32 $id, 'missed')"*) sh "$hist" set "$date" "$prayer" missed; break ;;
          *"NotificationClosed (uint32 $id,"*) break ;;
        esac
      done
    ;;

  play)
    # Runs as its own process group (setsid), so stop can end it all at once.
    sound=$1 max=$2 id=$3
    case $max in '' | *[!0-9]*) max=1800 ;; esac
    echo $$ >"$dir/player.pid"
    case $id in
      '' | *[!0-9]*) ;;
      *)
        # Dismissing the notification (or clicking Stop) ends the azan.
        gdbus monitor --session --dest org.freedesktop.Notifications \
          --object-path /org/freedesktop/Notifications 2>/dev/null |
          while read -r line; do
            case $line in
              *"NotificationClosed (uint32 $id,"*) sh "$self" stop; break ;;
            esac
          done &
        ;;
    esac
    if [ "$max" -gt 0 ]; then
      timeout --foreground "$max" mpv --no-terminal --no-video --loop-file=inf --audio-client-name="Awqat" -- "$sound"
    else
      mpv --no-terminal --no-video --loop-file=inf --audio-client-name="Awqat" -- "$sound"
    fi
    # Reached the time limit: tidy up as if stopped.
    sh "$self" stop
    ;;

  stop) stop ;;

  status)
    pid=$(cat "$dir/player.pid" 2>/dev/null)
    case $pid in '' | *[!0-9]*) ;; *) kill -0 "$pid" 2>/dev/null && echo playing ;; esac
    ;;

  *)
    echo "usage: azan.sh fire|notify|stop|status ..." >&2
    exit 1
    ;;
esac
