#!/usr/bin/env bash
# Request an Argo CD sync of a pinned revision and block until the operation
# this script initiated is the one that completed. The request is only made
# when the operation slot is free: a merge patch onto an occupied slot fuses
# with the automated sync holding it, which then runs without hooks.
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
  kubectl -n "$NAMESPACE" patch application "$APP" --type merge -p \
    "{\"operation\":{\"initiatedBy\":{\"username\":\"$USERNAME\"},\"sync\":{\"revision\":\"$REVISION\"}}}"
}

identity_of() {
  printf '%s' "$1" | cut -d'|' -f1-6
}

hook_ran() {
  case ",$1" in
    *",$REQUIRE_HOOK:Succeeded,"*) return 0 ;;
    *) return 1 ;;
  esac
}

if ! baseline=$(snapshot); then
  echo "could not read application $APP in namespace $NAMESPACE" >&2
  exit 1
fi
baseline_identity=$(identity_of "$baseline")

deadline=$(($(date +%s) + TIMEOUT))

while :; do
  if snap=$(snapshot); then
    IFS='|' read -r phase user automated revision started finished slot hooks <<<"$snap"
    if [ "$user" = "$USERNAME" ] && [ "$automated" != "true" ] && [ "$revision" = "$REVISION" ] &&
      [ "$(identity_of "$snap")" != "$baseline_identity" ]; then
      case "$phase" in
        Succeeded)
          if [ -n "$finished" ]; then
            if [ -n "$REQUIRE_HOOK" ] && ! hook_ran "$hooks"; then
              echo "the $USERNAME-initiated sync of $REVISION succeeded without a $REQUIRE_HOOK hook" >&2
              echo "syncResult hooks: ${hooks:-none}" >&2
              exit 1
            fi
            echo "$USERNAME-initiated sync of $REVISION succeeded${REQUIRE_HOOK:+ with its $REQUIRE_HOOK hook}"
            exit 0
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
    exit 1
  fi
  sleep "$POLL_INTERVAL"
done
