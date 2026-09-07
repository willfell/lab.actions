#!/usr/bin/env bash
# Scenario tests for argo-await-sync.sh, driven by a fake kubectl that replays
# a scripted sequence of Application snapshots -- one line per read.
#
# The wait's whole job: make sure a sync of the pinned revision gets
# requested, and block until the Application reports Synced at that
# revision. Proving that migrations ran is NOT this script's job any more:
# Argo's operation record proved unreliable three different ways in one week
# (operations fused into selective selfHeal syncs, hook phases frozen at
# Running on finished operations, hook jobs deleted after completion), and
# the suite's apps carry schema-aware health routes that fail the deploy's
# own health-verify step with certainty when a migration is missing.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$HERE/../argo-await-sync.sh"
NEW=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OLD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

failures=0
workdir=""

setup() {
  workdir="$(mktemp -d)"
  mkdir -p "$workdir/bin"
  printf '0' >"$workdir/reads"
  : >"$workdir/patches"
  : >"$workdir/patch_args"
  cat >"$workdir/bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  if [ "$arg" = "patch" ]; then
    echo patched >>"$FAKE_STATE/patches"
    printf '%s\n' "$*" >>"$FAKE_STATE/patch_args"
    exit 0
  fi
done
count=$(cat "$FAKE_STATE/reads")
count=$((count + 1))
printf '%s' "$count" >"$FAKE_STATE/reads"
total=$(wc -l <"$FAKE_STATE/snapshots")
if [ "$count" -gt "$total" ]; then
  count=$total
fi
sed -n "${count}p" "$FAKE_STATE/snapshots"
FAKE
  chmod +x "$workdir/bin/kubectl"
}

teardown() {
  [ -n "$workdir" ] && rm -rf "$workdir"
}

# snapshot syncStatus syncRevision slot
snapshot() {
  printf '%s|%s|%s\n' "$1" "$2" "$3" >>"$workdir/snapshots"
}

run_subject() {
  FAKE_STATE="$workdir" PATH="$workdir/bin:$PATH" \
    ARGO_APP=travel BUMP_SHA="$NEW" WAIT_TIMEOUT="${TIMEOUT_OVERRIDE:-60}" \
    POLL_INTERVAL=0 REQUIRE_HOOK="${HOOK_OVERRIDE-PreSync}" \
    bash "$SUBJECT" >"$workdir/out" 2>&1
}

reads() { cat "$workdir/reads"; }
patches() { wc -l <"$workdir/patches" | tr -d ' '; }

check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ok: $label"
  else
    echo "  FAIL: $label -- expected $expected, got $actual"
    failures=$((failures + 1))
  fi
}

contains() {
  local label="$1" needle="$2"
  if grep -qF "$needle" "$workdir/out"; then
    echo "  ok: $label"
  else
    echo "  FAIL: $label -- output lacks '$needle'"
    sed 's/^/      /' "$workdir/out"
    failures=$((failures + 1))
  fi
}

echo "already synced at the pinned revision exits immediately without patching"
setup
snapshot Synced "$NEW" ""
status=0
run_subject || status=$?
check "exits 0" 0 "$status"
check "never patched" 0 "$(patches)"
contains "names the revision" "$NEW"
teardown

echo "an out-of-date app gets one sync request, then converges"
setup
snapshot Synced "$OLD" ""
snapshot OutOfSync "$OLD" "$NEW"
snapshot Synced "$NEW" ""
status=0
run_subject || status=$?
check "exits 0" 0 "$status"
check "patched exactly once" 1 "$(patches)"
if grep -q -- "--type json" "$workdir/patch_args" && grep -qF '"op":"add","path":"/operation"' "$workdir/patch_args"; then
  echo "  ok: patches with a JSON Patch add on /operation"
else
  echo "  FAIL: patch is not a wholesale replace of /operation"
  sed 's/^/      /' "$workdir/patch_args"
  failures=$((failures + 1))
fi
teardown

echo "the wait never patches an occupied operation slot"
setup
snapshot Synced "$OLD" "$OLD"
snapshot Synced "$OLD" "$OLD"
snapshot Synced "$OLD" ""
snapshot OutOfSync "$OLD" "$NEW"
snapshot Synced "$NEW" ""
status=0
run_subject || status=$?
check "exits 0" 0 "$status"
check "patched once, only after the slot cleared" 1 "$(patches)"
teardown

echo "synced at the wrong revision keeps requesting rather than accepting"
setup
snapshot Synced "$OLD" ""
status=0
TIMEOUT_OVERRIDE=1 run_subject || status=$?
check "exits 1" 1 "$status"
contains "names the timeout" "timed out"
teardown

echo "out of sync at the pinned revision waits for Synced"
setup
snapshot OutOfSync "$NEW" ""
snapshot OutOfSync "$NEW" "$NEW"
snapshot Synced "$NEW" ""
status=0
run_subject || status=$?
check "exits 0 only once Synced" 0 "$status"
check "read three times" 3 "$(reads)"
teardown

echo "a never-converging app times out"
setup
snapshot OutOfSync "$OLD" "$OLD"
status=0
TIMEOUT_OVERRIDE=1 run_subject || status=$?
check "exits 1" 1 "$status"
contains "points at the health guard" "health"
teardown

echo "require_hook is accepted for compatibility and noted as retired"
setup
snapshot Synced "$NEW" ""
status=0
run_subject || status=$?
check "exits 0" 0 "$status"
contains "notes the retired input" "require_hook is retired"
teardown

if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all scenarios passed"
