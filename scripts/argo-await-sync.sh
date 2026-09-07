#!/usr/bin/env bash
# Request an Argo CD sync of a pinned revision and block until the
# Application reports Synced at that revision.
#
# This wait no longer tries to prove that migration hooks ran by reading
# Argo's operation record. One week of production deploys showed that record
# lying three different ways: a requested full sync recorded as an automated
# selective selfHeal operation, hook phases frozen at Running in the
# syncResult of a finished operation, and completed hook Jobs deleted before
# they could be probed. The proof that migrations ran lives where it cannot
# be fooled: each app's health route compares its shipped migration journal
# against the database and reports db=behind with a 503, which fails the
# deploy's own Healthy wait and health-verify step (travel#35 is the
# pattern).
#
# Usage: argo-await-sync.sh   with everything supplied via env:
#   ARGO_APP        Application name (required)
#   BUMP_SHA        revision the app must reach, Synced (required)
#   ARGO_NAMESPACE  namespace holding the Application (default argocd)
#   SYNC_USERNAME   initiatedBy.username stamped on the request (default ci)
#   REQUIRE_HOOK    retired, accepted for compatibility and ignored
#   WAIT_TIMEOUT    seconds to wait before giving up (default 300)
#   POLL_INTERVAL   seconds between polls (default 5)
set -euo pipefail

APP="${ARGO_APP:?ARGO_APP is required}"
REVISION="${BUMP_SHA:?BUMP_SHA is required}"
NAMESPACE="${ARGO_NAMESPACE:-argocd}"
USERNAME="${SYNC_USERNAME:-ci}"
REQUIRE_HOOK="${REQUIRE_HOOK:-}"
TIMEOUT="${WAIT_TIMEOUT:-300}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"

if [ -n "$REQUIRE_HOOK" ]; then
  echo "require_hook is retired and ignored: migration proof is the app's schema-aware health route, not Argo's operation record"
fi

# One read per poll: sync status, synced revision, and whether the
# operation slot is occupied.
TEMPLATE='{.status.sync.status}|{.status.sync.revision}|{.operation.sync.revision}'

snapshot() {
  local attempt out
  for attempt in 1 2 3; do
    if out=$(kubectl -n "$NAMESPACE" get application "$APP" -o jsonpath="$TEMPLATE" 2>/dev/null); then
      printf '%s' "$out"
      return 0
    fi
    if [ "$attempt" -lt 3 ]; then
      sleep 2
    fi
  done
  return 1
}

request_sync() {
  # A JSON Patch add on /operation replaces the whole object, so the request
  # cannot fuse with an automated sync that claimed the slot after the last
  # read.
  kubectl -n "$NAMESPACE" patch application "$APP" --type json -p \
    "[{\"op\":\"add\",\"path\":\"/operation\",\"value\":{\"initiatedBy\":{\"username\":\"$USERNAME\"},\"sync\":{\"revision\":\"$REVISION\"}}}]"
}

deadline=$(($(date +%s) + TIMEOUT))
requested=""

while :; do
  if snap=$(snapshot); then
    IFS='|' read -r sync_status sync_revision slot <<<"$snap"
    if [ "$sync_status" = "Synced" ] && [ "$sync_revision" = "$REVISION" ]; then
      echo "application $APP is Synced at $REVISION"
      exit 0
    fi
    if [ -z "$slot" ]; then
      if [ -z "$requested" ]; then
        echo "sync status is ${sync_status:-unknown} at ${sync_revision:-none}; requesting a sync of $REVISION"
      fi
      requested=1
      request_sync
    fi
  fi

  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "timed out after ${TIMEOUT}s waiting for $APP to reach Synced at $REVISION" >&2
    echo "if the sync ran but pods never went Healthy, check the app's health route: db=behind means a migration is missing" >&2
    exit 1
  fi
  sleep "$POLL_INTERVAL"
done
