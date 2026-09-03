#!/usr/bin/env bash
# Scenario tests for argo-await-sync.sh, driven by a fake kubectl that replays
# a scripted sequence of Application snapshots -- one line per read.
#
# The scenarios are the three production failures this wait exists to stop:
# a hookless selfHeal sync satisfying the wait, a stale Succeeded phase pairing
# with a freshly requested revision, and a sync that converges without ever
# running the migration hook.
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
  cat >"$workdir/bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  if [ "$arg" = "patch" ]; then
    echo patched >>"$FAKE_STATE/patches"
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

# snapshot phase user revision started finished slot hooks
snapshot() {
  printf '%s|%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" >>"$workdir/snapshots"
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

echo "a stale Succeeded phase must not pair with the requested revision"
setup
snapshot Succeeded ci "$OLD" t1 t2 "" "PreSync:Succeeded,:Synced,"
snapshot Succeeded ci "$OLD" t1 t2 "$NEW" "PreSync:Succeeded,:Synced,"
snapshot Running ci "$NEW" t3 "" "$NEW" ""
snapshot Succeeded ci "$NEW" t3 t4 "" "PreSync:Succeeded,:Synced,"
status=0
run_subject || status=$?
check "exits 0 once its own operation finishes" 0 "$status"
check "kept polling past the pre-adoption snapshot" 4 "$(reads)"
contains "names the hook it verified" "with its PreSync hook"
teardown

echo "a hookless automated selfHeal sync must not satisfy the wait"
setup
snapshot Succeeded ci "$OLD" t1 t2 "" "PreSync:Succeeded,:Synced,"
snapshot Succeeded "" "$NEW" t3 t3 "" ":Synced,"
snapshot Running ci "$NEW" t4 "" "$NEW" ""
snapshot Succeeded ci "$NEW" t4 t5 "" "PreSync:Succeeded,:Synced,"
status=0
run_subject || status=$?
check "exits 0 only after the ci operation runs" 0 "$status"
check "re-requested the sync the selfHeal displaced" 2 "$(patches)"
contains "reports the displaced operation" "re-requesting"
teardown

echo "a ci operation that converged without the hook must fail"
setup
snapshot Succeeded ci "$OLD" t1 t2 "" "PreSync:Succeeded,:Synced,"
snapshot Succeeded ci "$NEW" t3 t4 "" ":Synced,"
status=0
run_subject || status=$?
check "exits 1" 1 "$status"
contains "names the missing hook" "succeeded without a PreSync hook"
teardown

echo "a failed operation fails the deploy immediately"
setup
snapshot Succeeded ci "$OLD" t1 t2 "" "PreSync:Succeeded,:Synced,"
snapshot Failed ci "$NEW" t3 t4 "" "PreSync:Failed,"
status=0
run_subject || status=$?
check "exits 1" 1 "$status"
contains "names the phase" "ended in phase Failed"
teardown

echo "an operation that never becomes ours times out"
setup
snapshot Succeeded ci "$OLD" t1 t2 "" "PreSync:Succeeded,:Synced,"
snapshot Running "" "$NEW" t3 "" "$NEW" ""
status=0
TIMEOUT_OVERRIDE=0 run_subject || status=$?
check "exits 1" 1 "$status"
contains "names the selfHeal race" "without running hooks"
teardown

echo "an app with no hooks still deploys when no hook is required"
setup
snapshot Succeeded ci "$OLD" t1 t2 "" ":Synced,"
snapshot Succeeded ci "$NEW" t3 t4 "" ":Synced,"
status=0
HOOK_OVERRIDE="" run_subject || status=$?
check "exits 0" 0 "$status"
teardown

if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all scenarios passed"
