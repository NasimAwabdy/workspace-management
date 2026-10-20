#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# post-serve hook: give the workspace backend its OWN Redis / Horizon / cache
# namespace, turn Telescope off, and start the workspace's own queue worker.
#
# WHY: `ws serve` copies main's .env, so every worktree shared main's
# REDIS_PREFIX. Laravel queues live under <prefix>queues:<name>, so main's
# Horizon (and every other workspace's worker) popped jobs dispatched by a
# workspace and ran them on the WRONG code — failed_jobs showed
# `Class "App\EntityActions\AddOns\SetAddOnsFeatured" does not exist in
# workspaces/community-members-bulk/...`. Agents then paused main Horizon or
# forced QUEUE_CONNECTION=sync, stalling/skewing everybody else. Caches and
# locks collided the same way. Telescope wrote every request/query of every
# workspace into the shared dev DB (47 GB of telescope_entries).
#
# WHAT (idempotent, on every `ws serve`):
#   REDIS_PREFIX   = <slug>_database_   (queues, locks, everything on Redis)
#   HORIZON_PREFIX = <slug>_horizon:    (if someone runs Horizon in the worktree)
#   CACHE_PREFIX   = <slug>_cache_
#     -> only ADDED when missing; an existing value is kept.
#   TELESCOPE_ENABLED=false
#     -> only on the FIRST run (marker line below). Turn it back on in the
#        worktree .env if you need it; later serves leave your choice alone.
#   then `ws queue start <slug>` (no-op if a worker already runs there).
#
# ENABLE: copy to hooks/post-serve/ and chmod +x, and add these keys to
# ENV_DIFF_IGNORE_KEYS in config.sh so `ws envdiff` / `ws remove` don't report
# them as hand-made changes to port into MAIN:
#     ENV_DIFF_IGNORE_KEYS="REDIS_PREFIX HORIZON_PREFIX CACHE_PREFIX TELESCOPE_ENABLED"
# Runs behind ws serve's spinner: must never prompt.
# ---------------------------------------------------------------------------
set -euo pipefail

backend="${WS_BACKEND:?WS_BACKEND not set}"
slug="${WS_SLUG:?WS_SLUG not set}"
env_file="$backend/.env"
marker="# >>> ws backend isolation (hooks/post-serve/isolate-backend.sh)"

[[ -f "$env_file" ]] || { echo "isolate-backend: no $env_file — skipped" >&2; exit 0; }
if [[ "${WS_DRY_RUN:-false}" == true ]]; then
  echo "[dry-run] isolate-backend: would namespace Redis/Horizon/cache in $env_file and start the queue worker"
  exit 0
fi

# Redis key prefix: lowercase, [a-z0-9_] only.
ns="$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//')"

tmp="$(mktemp "$env_file.XXXXXX")"
cp "$env_file" "$tmp"
first_run=true
grep -qF "$marker" "$tmp" && first_run=false

added=()
if "$first_run"; then
  printf '\n%s\n# Keys are only added when missing — edit the values freely.\n' "$marker" >>"$tmp"
  # Telescope off: replace in place so there's no duplicate key to confuse.
  if grep -qE '^TELESCOPE_ENABLED=' "$tmp"; then
    sed -i '' -E 's/^TELESCOPE_ENABLED=.*/TELESCOPE_ENABLED=false/' "$tmp"
  else
    echo 'TELESCOPE_ENABLED=false' >>"$tmp"
  fi
  added+=(TELESCOPE_ENABLED=false)
fi
for kv in "REDIS_PREFIX=${ns}_database_" "HORIZON_PREFIX=${ns}_horizon:" "CACHE_PREFIX=${ns}_cache_"; do
  key="${kv%%=*}"
  grep -qE "^${key}=" "$tmp" && continue
  echo "$kv" >>"$tmp"; added+=("$kv")
done

if cmp -s "$tmp" "$env_file"; then
  rm -f "$tmp"
else
  # Atomic: php-fpm reads .env on every request.
  chmod "$(stat -f '%Lp' "$env_file")" "$tmp"
  mv -f "$tmp" "$env_file"
  echo "isolate-backend: ${added[*]:-}"
fi

# A cached config would ignore every .env change above.
if [[ -f "$backend/bootstrap/cache/config.php" ]]; then
  echo "isolate-backend: WARNING bootstrap/cache/config.php exists — run 'php artisan config:clear' in $backend" >&2
fi

# The workspace's jobs now go to its own namespace: give it its own worker.
ws_bin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/workspaces"
if [[ -x "$ws_bin" ]]; then
  "$ws_bin" queue start "$slug" || echo "isolate-backend: queue worker not started — run 'ws queue start $slug'" >&2
fi
