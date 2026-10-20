#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# queue-supervisor.sh — keep ONE workspace's queue worker alive and on the
# workspace's CURRENT code. Started (detached) by `ws queue start`; not meant to
# be run by hand.
#
#   queue-supervisor.sh <backend-dir> <stamp-file> <worker command...>
#
# WHY NOT `queue:listen`: it boots the whole app for every poll (~0.4s CPU on
# bookings-api), i.e. ~12% of a core per IDLE workspace. WHY NOT a bare
# `queue:work` / Horizon: they load the code once, so an agent that edits a job
# keeps testing the old one until somebody restarts the worker — the classic
# "my fix doesn't work" loop. This runs a resident worker (cheap when idle) and
# restarts it GRACEFULLY (SIGTERM = finish the current job, then exit) as soon
# as a watched file changes. Change detection is a `find -newer` over
# $QUEUE_WATCH_PATHS every few seconds — a few ms, no fs-watcher daemon.
#
# Env: QUEUE_WATCH_PATHS (space-separated, relative to the backend dir),
#      QUEUE_WATCH_INTERVAL (seconds, default 3).
# ---------------------------------------------------------------------------
set -uo pipefail

backend="$1"; stamp="$2"; shift 2
watch_paths="${QUEUE_WATCH_PATHS:-app config routes bootstrap database .env composer.lock}"
interval="${QUEUE_WATCH_INTERVAL:-3}"

cd "$backend" || { echo "queue-supervisor: no backend dir $backend" >&2; exit 1; }

wpid=""
stopping=false
stop_worker() {
  [[ -n "$wpid" ]] || return 0
  kill -TERM "$wpid" 2>/dev/null
  # Graceful: let the current job finish (the worker's own --timeout bounds it).
  wait "$wpid" 2>/dev/null
  wpid=""
}
on_term() { stopping=true; stop_worker; exit 0; }
trap on_term TERM INT HUP

# Only files that exist; a missing optional path must not make find fail.
existing_paths() {
  local p; for p in $watch_paths; do [[ -e "$p" ]] && printf '%s\n' "$p"; done
}

changed_since_stamp() {
  local -a paths=()
  while IFS= read -r p; do paths+=("$p"); done < <(existing_paths)
  [[ ${#paths[@]} -gt 0 ]] || return 1
  # .php anywhere under the dirs, plus the plain files themselves (.env, lock).
  find "${paths[@]}" -newer "$stamp" \( -name '*.php' -o -name '.env' -o -name 'composer.lock' \) \
    -print -quit 2>/dev/null | grep -q .
}

backoff=1
while ! "$stopping"; do
  touch "$stamp"
  started=$(date +%s)
  printf '[%s] queue-supervisor: starting worker: %s\n' "$(date '+%F %T')" "$*"
  "$@" &
  wpid=$!

  reason="exited"
  while kill -0 "$wpid" 2>/dev/null; do
    sleep "$interval" &
    wait $! 2>/dev/null   # interruptible by the TERM trap
    if changed_since_stamp; then reason="code changed"; stop_worker; break; fi
  done
  [[ -n "$wpid" ]] && { wait "$wpid" 2>/dev/null; wpid=""; }
  printf '[%s] queue-supervisor: worker stopped (%s) — restarting\n' "$(date '+%F %T')" "$reason"

  # A worker that dies right after boot (syntax error mid-edit, DB down) must
  # not spin a core: back off up to 30s until it stays up for a while.
  if [[ "$reason" == exited && $(( $(date +%s) - started )) -lt 10 ]]; then
    sleep "$backoff"; backoff=$(( backoff * 2 > 30 ? 30 : backoff * 2 ))
  else
    backoff=1
  fi
done
