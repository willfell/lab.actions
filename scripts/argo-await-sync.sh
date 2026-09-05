#!/usr/bin/env bash
# Request an Argo CD sync of a pinned revision and block until the operation
# this script initiated is the one that completed, and -- when REQUIRE_HOOK is
# set -- that the hook proving the migration ran is in its syncResult. Argo's
# own auto-sync can stamp automated: true onto the operation carrying our
# username, so the hook, not the initiator, is what makes the result
# trustworthy.
#
# Usage: argo-await-sync.sh   with everything supplied via env:
#   ARGO_APP        Application name (required)
#   BUMP_SHA        revision the operation must carry (required)
#   ARGO_NAMESPACE  namespace holding the Application (default argocd)
#   SYNC_USERNAME   initiatedBy.username stamped on the request (default ci)
#   REQUIRE_HOOK    hook type that must have run inside the operation, e.g.
#                   PreSync; empty disables the check
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

# Every field the decision depends on comes out of ONE read. Reading them with
# separate calls lets a Succeeded phase from the previous operation pair with
# the revision of the one just requested -- a state that never existed.
TEMPLATE='{.status.operationState.phase}'
TEMPLATE="$TEMPLATE|{.status.operationState.operation.initiatedBy.username}"
TEMPLATE="$TEMPLATE|{.status.operationState.operation.initiatedBy.automated}"
TEMPLATE="$TEMPLATE|{.status.operationState.operation.sync.revision}"
TEMPLATE="$TEMPLATE|{.status.operationState.startedAt}"
TEMPLATE="$TEMPLATE|{.status.operationState.finishedAt}"
TEMPLATE="$TEMPLATE|{.operation.sync.revision}"
TEMPLATE="$TEMPLATE|{range .status.operationState.syncResult.resources[*]}{.hookType}:{.hookPhase},{end}"

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
  # A JSON Patch add on /operation replaces the whole object. A merge patch
  # would fuse with an automated sync that claimed the slot after the last
  # read, producing an operation marked both automated and ours that Argo runs
  # without hooks. There is no window between the read and the patch in which
  # that can happen here.
  kubectl -n "$NAMESPACE" patch application "$APP" --type json -p \
    "[{\"op\":\"add\",\"path\":\"/operation\",\"value\":{\"initiatedBy\":{\"username\":\"$USERNAME\"},\"sync\":{\"revision\":\"$REVISION\"}}}]"
}

identity_of() {
  printf '%s' "$1" | cut -d'|' -f1-6
}

# The hookless syncs this wait exists to reject carry no entry for the hook at
# all -- their syncResult is the drifted workloads and nothing else. Presence
# alone is not proof either: an operation can finish with its hook frozen at
# Running in the syncResult, and travel's 2026-09-05 outage shipped behind
# exactly that kind of unproven hook. Only Succeeded is proof; Failed/Error
# and absence are fatal; anything else keeps polling until the deadline.
hook_state() {
  case ",$1" in
    *",$REQUIRE_HOOK:Failed,"* | *",$REQUIRE_HOOK:Error,"*) echo failed ;;
    *",$REQUIRE_HOOK:Succeeded,"*) echo succeeded ;;
    *",$REQUIRE_HOOK:"*) echo pending ;;
    *) echo absent ;;
  esac
}

if ! baseline=$(snapshot); then
  echo "could not read application $APP in namespace $NAMESPACE" >&2
  exit 1
fi
baseline_identity=$(identity_of "$baseline")
baseline_started=$(printf '%s' "$baseline" | cut -d'|' -f5)

deadline=$(($(date +%s) + TIMEOUT))

while :; do
  if snap=$(snapshot); then
    IFS='|' read -r phase user automated revision started finished slot hooks <<<"$snap"
    # startedAt must differ from the baseline operation's: the controller
    # writes operation adoption and the finished result separately, so a
    # single read can pair our freshly requested revision with the previous
    # operation's Succeeded phase and syncResult. That torn read carries the
    # previous startedAt, and a genuinely new operation never does
    # (travel 2026-09-05: such a read declared hook success 5s after the
    # request while the real convergence was a hookless selfHeal sync).
    if [ "$user" = "$USERNAME" ] && [ "$revision" = "$REVISION" ] &&
      [ "$(identity_of "$snap")" != "$baseline_identity" ] &&
      { [ -z "$baseline_started" ] || [ "$started" != "$baseline_started" ]; }; then
      case "$phase" in
        Succeeded)
          if [ -n "$finished" ]; then
            if [ -z "$REQUIRE_HOOK" ]; then
              echo "$USERNAME-initiated sync of $REVISION succeeded"
              exit 0
            fi
            case "$(hook_state "$hooks")" in
              succeeded)
                echo "$USERNAME-initiated sync of $REVISION succeeded with its $REQUIRE_HOOK hook"
                exit 0
                ;;
              failed | absent)
                echo "the $USERNAME-initiated sync of $REVISION ran no successful $REQUIRE_HOOK hook" >&2
                echo "syncResult hooks: ${hooks:-none}" >&2
                exit 1
                ;;
            esac
          fi
          ;;
        Failed | Error)
          echo "the $USERNAME-initiated sync of $REVISION ended in phase $phase" >&2
          exit 1
          ;;
      esac
    elif [ -z "$slot" ]; then
      echo "operation slot free, recorded operation is not ours (username=${user:-none} automated=${automated:-false} revision=${revision:-none} startedAt=${started:-none}); requesting"
      request_sync
    fi
  fi

  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "timed out after ${TIMEOUT}s waiting for the $USERNAME-initiated sync of $REVISION" >&2
    echo "an automated selfHeal sync can converge the Deployment without running hooks; this wait refuses to accept it" >&2
    echo "a hook still reported Running, or an operation carrying the previous startedAt, is likewise never accepted as proof" >&2
    exit 1
  fi
  sleep "$POLL_INTERVAL"
done
