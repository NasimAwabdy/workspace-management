# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/cmd_queue.sh — `workspaces queue`: one lightweight queue worker PER
# WORKSPACE, running the workspace's own (current) code against the
# workspace's own Redis namespace.
#
# WHY: every worktree used to share one Redis prefix, so main's Horizon (and any
# other workspace's worker) popped jobs a workspace dispatched and ran them on
# the WRONG code ("Class App\EntityActions\... does not exist" in failed_jobs).
# Agents worked around it by pausing main Horizon or forcing
# QUEUE_CONNECTION=sync — each stalling or skewing everybody else. With a
# per-workspace prefix (written by the backend-isolation post-serve hook) the
# workspace's jobs are invisible to every other worker, so it needs its own:
# this command.
#
# FAILS CLOSED: refuses to start unless the worktree .env sets
# $QUEUE_ISOLATION_KEY (default REDIS_PREFIX) to something other than main's —
# a worker on the shared namespace would itself steal other checkouts' jobs.
#
# State lives in <session-dir>/.ws/ (pid + log) and is deleted with the
# workspace; `ws remove` stops the worker first.
# -----------------------------------------------------------------------------

cmd_queue_usage() {
  cat <<'USAGE'
Usage:
  ws queue [status|start|stop|restart|logs] [SLUG] [options]

Manage the workspace's own queue worker (default action: status). The worker
runs QUEUE_WORKER_CMD in the backend worktree under a small supervisor that
restarts it gracefully whenever PHP code, .env or composer.lock change — so
jobs always run the code you just edited, without paying a full app boot per
poll. SLUG defaults to the workspace you're in.

Actions:
  status     Running? pid, uptime, pending jobs per queue, other workers found.
  start      Start the worker (no-op if already running; refuses if the
             workspace's Redis namespace isn't isolated from main).
  stop       Stop it (the current job finishes first).
  restart    stop + start.
  logs       Tail the worker log (-f to follow).

Options:
  -f            (logs) follow.
  --dry-run     Print what would happen.
  -h, --help    Show this help.

Never pause or stop MAIN Horizon for a workspace test: the workspace's jobs
don't reach it any more.
USAGE
}

# --- helpers (also used by cmd_remove / hooks) --------------------------------

_queue_state_dir() { printf '%s/%s/.ws' "$WORKSPACES_ROOT" "$1"; }
_queue_pid_file()  { printf '%s/queue.pid' "$(_queue_state_dir "$1")"; }
_queue_log_file()  { printf '%s/queue.log' "$(_queue_state_dir "$1")"; }

# Last assignment wins (phpdotenv lets a file override its own earlier keys).
_env_get() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  # `|| true`: no match must not trip the caller's set -e/pipefail.
  { grep -E "^${key}=" "$file" 2>/dev/null || true; } | tail -1 | cut -d= -f2- | sed -E 's/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/'
}

# PID of the running supervisor for SLUG, or empty. Guards against pid reuse by
# checking the command line is really our supervisor.
queue_worker_pid() {
  local pf pid
  pf="$(_queue_pid_file "$1")"
  [[ -f "$pf" ]] || return 0
  pid="$(cat "$pf" 2>/dev/null)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  if kill -0 "$pid" 2>/dev/null && ps -o args= -p "$pid" 2>/dev/null | grep -q 'queue-supervisor.sh'; then
    printf '%s' "$pid"
  fi
}

# Other queue processes (Horizon / queue:work / queue:listen) whose cwd is this
# backend worktree and that are NOT ours. Prints "pid<TAB>args" lines.
_queue_foreign_workers() {
  local backend="$1" own="${2:-}" pid cwd
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    # Skip our own supervisor's descendants.
    if [[ -n "$own" ]]; then
      local p="$pid" mine=false
      while [[ -n "$p" && "$p" != 1 && "$p" != 0 ]]; do
        [[ "$p" == "$own" ]] && { mine=true; break; }
        p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
      done
      "$mine" && continue
    fi
    cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')"
    [[ "$cwd" == "$backend" ]] || continue
    # Only report the top process of a tree (horizon master, not every child).
    local ppid pcwd
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    pcwd="$(lsof -a -p "$ppid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')"
    if [[ "$pcwd" == "$backend" ]] && ps -o args= -p "$ppid" 2>/dev/null | grep -qE 'artisan (horizon|queue:)'; then
      continue
    fi
    printf '%s\t%s\n' "$pid" "$(ps -o args= -p "$pid" 2>/dev/null | cut -c1-120)"
  done < <(pgrep -f 'artisan (horizon|queue:work|queue:listen)' 2>/dev/null)
}

# 0 = the worktree's queue namespace is isolated from main's.
_queue_isolated() {
  local backend="$1" wt main
  wt="$(_env_get "$backend/.env" "$QUEUE_ISOLATION_KEY")"
  main="$(_env_get "$BACKEND_REPO/.env" "$QUEUE_ISOLATION_KEY")"
  [[ -n "$wt" && "$wt" != "$main" ]]
}

queue_worker_stop() {
  local slug="$1" pid i
  pid="$(queue_worker_pid "$slug")"
  [[ -n "$pid" ]] || return 0
  if "${DRY_RUN:-false}"; then printf '[dry-run] kill -TERM %s (queue supervisor)\n' "$pid"; return 0; fi
  kill -TERM "$pid" 2>/dev/null || true
  # The current job finishes first; give it a while, then stop waiting (the
  # supervisor keeps shutting down on its own).
  for i in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
  if kill -0 "$pid" 2>/dev/null; then
    warn "Queue worker (pid $pid) still finishing a job after 30s — left to exit on its own."
  fi
  rm -f "$(_queue_pid_file "$slug")"
}

queue_worker_start() {
  local slug="$1" backend="$WORKSPACES_ROOT/$1/$BACKEND_DIR_NAME" pid state log
  [[ -d "$backend" ]] || { err "Backend worktree not found for '$slug'."; return 1; }

  pid="$(queue_worker_pid "$slug")"
  if [[ -n "$pid" ]]; then ok "Queue worker already running (pid $pid)."; return 0; fi

  if ! _queue_isolated "$backend"; then
    err "Refusing to start: $QUEUE_ISOLATION_KEY in $backend/.env is unset or equal to main's,"
    err "so this worker would take jobs from main and every other workspace."
    err "Run 'ws serve $slug' (its post-serve hook isolates the namespace) and retry."
    return 1
  fi
  [[ -f "$backend/vendor/autoload.php" ]] \
    || { err "No vendor/ in the worktree — run 'ws serve $slug' first."; return 1; }

  local foreign
  foreign="$(_queue_foreign_workers "$backend")"
  if [[ -n "$foreign" ]]; then
    warn "Another queue process already runs in this worktree (same namespace) — not starting a second one:"
    printf '%s\n' "$foreign" | sed 's/^/    /' >&2
    warn "Stop it if you want 'ws queue' to manage the worker (it would keep running stale code)."
    return 0
  fi

  state="$(_queue_state_dir "$slug")"; log="$(_queue_log_file "$slug")"
  if "${DRY_RUN:-false}"; then
    printf '[dry-run] (cd %s && nohup nice -n %s %s/bin/queue-supervisor.sh %s %s/queue.stamp %s >>%s 2>&1 &)\n' \
      "$backend" "$QUEUE_WORKER_NICE" "$WSM_HOME" "$backend" "$state" "$QUEUE_WORKER_CMD" "$log"
    return 0
  fi
  mkdir -p "$state"
  # Rotate a log that has grown past ~5 MB.
  if [[ -f "$log" && $(wc -c <"$log") -gt 5000000 ]]; then mv -f "$log" "$log.1"; fi

  # Detached: own stdin/stdout/stderr so the caller (a terminal, an agent's
  # tool call, a hook behind a spinner) returns immediately. nice: a burst of
  # jobs must not starve the dev servers / test runs of other agents.
  # shellcheck disable=SC2086  # QUEUE_WORKER_CMD is a command line, word-split on purpose
  (
    cd "$backend" || exit 1
    QUEUE_WATCH_PATHS="$QUEUE_WATCH_PATHS" nohup nice -n "$QUEUE_WORKER_NICE" \
      "$WSM_HOME/bin/queue-supervisor.sh" "$backend" "$state/queue.stamp" $QUEUE_WORKER_CMD \
      </dev/null >>"$log" 2>&1 &
    printf '%s' "$!" >"$state/queue.pid"
  )
  sleep 1
  pid="$(queue_worker_pid "$slug")"
  if [[ -z "$pid" ]]; then
    err "Queue worker failed to start — last log lines:"; tail -5 "$log" >&2; return 1
  fi
  ok "Queue worker started (pid $pid) — log: $log"
}

_queue_status() {
  local slug="$1" backend="$WORKSPACES_ROOT/$1/$BACKEND_DIR_NAME" pid prefix
  pid="$(queue_worker_pid "$slug")"
  prefix="$(_env_get "$backend/.env" "$QUEUE_ISOLATION_KEY")"
  if [[ -n "$pid" ]]; then
    ok "Worker running (pid $pid, up $(ps -o etime= -p "$pid" | tr -d ' '))"
  else
    log "Worker: not running   (start: ws queue start $slug)"
  fi
  if _queue_isolated "$backend"; then
    log "Namespace: $QUEUE_ISOLATION_KEY=$prefix (isolated from main)"
  else
    warn "Namespace NOT isolated ($QUEUE_ISOLATION_KEY='${prefix}') — jobs go to main's queues. Run 'ws serve $slug'."
  fi
  local foreign; foreign="$(_queue_foreign_workers "$backend" "$pid")"
  [[ -n "$foreign" ]] && { log "Other queue processes in this worktree:"; printf '%s\n' "$foreign" | sed 's/^/    /'; }

  # Pending jobs per queue (Laravel layout: <prefix>queues:<name>).
  if command -v redis-cli >/dev/null 2>&1 && [[ -n "$prefix" ]]; then
    local host port db queues q n line=""
    host="$(_env_get "$backend/.env" REDIS_HOST)"; port="$(_env_get "$backend/.env" REDIS_PORT)"
    db="$(_env_get "$backend/.env" REDIS_QUEUE_DB)"; [[ -n "$db" ]] || db="$(_env_get "$backend/.env" REDIS_DB)"
    queues="$(printf '%s' "$QUEUE_WORKER_CMD" | sed -nE 's/.*--queue=([^ ]+).*/\1/p' | tr ',' ' ')"
    for q in ${queues:-default}; do
      n="$(redis-cli -h "${host:-127.0.0.1}" -p "${port:-6379}" -n "${db:-0}" llen "${prefix}queues:$q" 2>/dev/null)"
      [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]] && line+="$q=$n "
    done
    log "Pending: ${line:-none}"
  fi
}

cmd_queue() {
  DRY_RUN=false
  local action="status" follow=false slug=""
  case "${1:-}" in
    status|start|stop|restart|logs) action="$1"; shift ;;
  esac
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f) follow=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      -v|--verbose) VERBOSE=true; shift ;;
      -h|--help) cmd_queue_usage; exit 0 ;;
      -*) err "Unknown option: $1"; cmd_queue_usage >&2; exit 1 ;;
      *) [[ -z "$slug" ]] || { err "Unexpected argument: $1"; exit 1; }; slug="$1"; shift ;;
    esac
  done

  if [[ -z "$QUEUE_WORKER_CMD" ]]; then
    err "Per-workspace queue workers are disabled (QUEUE_WORKER_CMD is empty in config.sh)."
    exit 1
  fi
  if [[ -z "$slug" ]]; then
    slug="$(slug_from_cwd)" || { err "Not inside a workspace — name one: ws queue $action <slug>"; exit 1; }
  fi
  [[ -d "$WORKSPACES_ROOT/$slug" ]] || { err "No workspace '$slug' (see 'ws list')."; exit 1; }

  case "$action" in
    status)  _queue_status "$slug" ;;
    start)   queue_worker_start "$slug" || exit 1 ;;
    stop)    queue_worker_stop "$slug"; ok "Queue worker stopped." ;;
    restart) queue_worker_stop "$slug"; queue_worker_start "$slug" || exit 1 ;;
    logs)
      local lf; lf="$(_queue_log_file "$slug")"
      [[ -f "$lf" ]] || { log "No log yet ($lf)."; exit 0; }
      if "$follow"; then exec tail -f "$lf"; else tail -40 "$lf"; fi
      ;;
  esac
}
