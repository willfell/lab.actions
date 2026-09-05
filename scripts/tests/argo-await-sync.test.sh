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

# snapshot phase user automated revision started finished slot hooks
snapshot() {
  printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" >>"$workdir/snapshots"
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
snapshot Succeeded ci "" "$OLD" t1 t2 "" "PreSync:Succeeded,:Synced,"
snapshot Succeeded ci "" "$OLD" t1 t2 "$NEW" "PreSync:Succeeded,:Synced,"
snapshot Running ci "" "$NEW" t3 "" "$NEW" ""
snapshot Succeeded ci "" "$NEW" t3 t4 "" "PreSync:Succeeded,:Synced,"
status=0
run_subject || status=$?
check "exits 0 once its own operation finishes" 0 "$status"
check "kept polling past the pre-adoption snapshot" 4 "$(reads)"
contains "names the hook it verified" "with its PreSync hook"
teardown

echo "the request replaces the operation rather than merging into it"
setup
snapshot Succeeded ci "" "$OLD" t1 t2 "" "PreSync:Succeeded,:Synced,"
snapshot Succeeded "" true "$OLD" t2 t2 "" ":Synced,"
snapshot Succeeded ci "" "$NEW" t3 t4 "" "PreSync:Succeeded,:Synced,"
status=0
run_subject || status=$?
check "exits 0" 0 "$status"
if grep -q -- "--type json" "$workdir/patch_args" && grep -qF '"op":"add","path":"/operation"' "$workdir/patch_args"; then
  echo "  ok: patches with a JSON Patch add on /operation"
else
  echo "  FAIL: patch is not a wholesale replace of /operation"
  sed 's/^/      /' "$workdir/patch_args"
  failures=$((failures + 1))
fi
if grep -q -- "--type merge" "$workdir/patch_args"; then
  echo "  FAIL: still uses a merge patch, which fuses with an automated sync"
  failures=$((failures + 1))
else
  echo "  ok: never uses a merge patch"
fi
teardown

echo "an operation fused with an automated sync still counts when its hook ran"
setup
snapshot Succeeded ci "" "$OLD" t1 t2 "" "PreSync:Succeeded,:Synced,"
snapshot Succeeded ci true "$NEW" t3 t4 "" "PreSync:Succeeded,:Synced,"
status=0
run_subject || status=$?
check "exits 0" 0 "$status"
contains "names the hook it verified" "with its PreSync hook"
teardown

echo "a fused operation that skipped the hook is still rejected"
setup
snapshot Succeeded ci "" "$OLD" t1 t2 "" "PreSync:Succeeded,:Synced,"
snapshot Succeeded ci true "$NEW" t3 t4 "" ":Synced,"
status=0
run_subject || status=$?
check "exits 1" 1 "$status"
contains "names the missing hook" "ran no successful PreSync hook"
teardown

echo "the wait never patches an occupied operation slot"
setup
snapshot Running "" true "$OLD" t1 "" "$OLD" ""
snapshot Running "" true "$OLD" t1 "" "$OLD" ""
snapshot Succeeded "" true "$OLD" t1 t2 "" ":Synced,"
snapshot Running ci "" "$NEW" t3 "" "$NEW" ""
snapshot Succeeded ci "" "$NEW" t3 t4 "" "PreSync:Succeeded,:Synced,"
status=0
run_subject || status=$?
check "exits 0" 0 "$status"
check "patched once, only after the slot cleared" 1 "$(patches)"
teardown

echo "a hookless automated selfHeal sync must not satisfy the wait"
setup
snapshot Succeeded ci "" "$OLD" t1 t2 "" "PreSync:Succeeded,:Synced,"
snapshot Succeeded "" "" "$NEW" t3 t3 "" ":Synced,"
snapshot Running ci "" "$NEW" t4 "" "$NEW" ""
snapshot Succeeded ci "" "$NEW" t4 t5 "" "PreSync:Succeeded,:Synced,"
status=0
run_subject || status=$?
check "exits 0 only after the ci operation runs" 0 "$status"
check "requested only after the selfHeal released the slot" 1 "$(patches)"
contains "reports the displaced operation" "recorded operation is not ours"
teardown

echo "a ci operation that converged without the hook must fail"
setup
snapshot Succeeded ci "" "$OLD" t1 t2 "" "PreSync:Succeeded,:Synced,"
snapshot Succeeded ci "" "$NEW" t3 t4 "" ":Synced,"
status=0
run_subject || status=$?
check "exits 1" 1 "$status"
contains "names the missing hook" "ran no successful PreSync hook"
teardown

echo "a finished operation whose hook is frozen at Running is not proof; the wait times out"
setup
snapshot Succeeded ci "" "$OLD" t1 t2 "" "PreSync:Succeeded,:Synced,"
snapshot Succeeded ci "" "$NEW" t3 t4 "" "PreSync:Running,:Running,"
status=0
TIMEOUT_OVERRIDE=1 run_subject || status=$?
check "exits 1" 1 "$status"
contains "explains the frozen hook" "timed out"
teardown

echo "a hook that resolves to Succeeded on a later read is accepted"
setup
snapshot Succeeded ci "" "$OLD" t1 t2 "" "PreSync:Succeeded,:Synced,"
snapshot Succeeded ci "" "$NEW" t3 t4 "" "PreSync:Running,:Running,"
snapshot Succeeded ci "" "$NEW" t3 t4 "" "PreSync:Succeeded,:Synced,"
status=0
run_subject || status=$?
check "exits 0" 0 "$status"
contains "names the hook it verified" "with its PreSync hook"
teardown

echo "a torn read pairing our revision with the previous operation's timestamps is rejected"
setup
snapshot Succeeded ci "" "$OLD" t1 t2 "" "PreSync:Succeeded,:Synced,"
snapshot Succeeded ci "" "$OLD" t1 t2 "" "PreSync:Succeeded,:Synced,"
snapshot Succeeded ci true "$NEW" t1 t2 "" "PreSync:Succeeded,:Synced,"
snapshot Running ci "" "$NEW" t3 "" "" ""
snapshot Succeeded ci "" "$NEW" t3 t4 "" "PreSync:Succeeded,:Synced,"
status=0
run_subject || status=$?
check "exits 0 only once a genuinely new operation succeeds" 0 "$status"
check "kept polling past the torn read" 5 "$(reads)"
teardown

echo "a torn read that never resolves into a fresh operation times out"
setup
snapshot Succeeded ci "" "$OLD" t1 t2 "" "PreSync:Succeeded,:Synced,"
snapshot Succeeded ci true "$NEW" t1 t2 "" "PreSync:Succeeded,:Synced,"
status=0
TIMEOUT_OVERRIDE=1 run_subject || status=$?
check "exits 1" 1 "$status"
contains "refuses the stale result" "timed out"
teardown

echo "an operation whose hook failed is rejected"
setup
snapshot Succeeded ci "" "$OLD" t1 t2 "" "PreSync:Succeeded,:Synced,"
snapshot Succeeded ci "" "$NEW" t3 t4 "" "PreSync:Failed,:Synced,"
status=0
run_subject || status=$?
check "exits 1" 1 "$status"
contains "names the hook" "ran no successful PreSync hook"
teardown

echo "a failed operation fails the deploy immediately"
setup
snapshot Succeeded ci "" "$OLD" t1 t2 "" "PreSync:Succeeded,:Synced,"
snapshot Failed ci "" "$NEW" t3 t4 "" "PreSync:Failed,"
status=0
run_subject || status=$?
check "exits 1" 1 "$status"
contains "names the phase" "ended in phase Failed"
teardown

echo "an operation that never becomes ours times out"
setup
snapshot Succeeded ci "" "$OLD" t1 t2 "" "PreSync:Succeeded,:Synced,"
snapshot Running "" "" "$NEW" t3 "" "$NEW" ""
status=0
TIMEOUT_OVERRIDE=0 run_subject || status=$?
check "exits 1" 1 "$status"
contains "names the selfHeal race" "without running hooks"
teardown

echo "an app with no hooks still deploys when no hook is required"
setup
snapshot Succeeded ci "" "$OLD" t1 t2 "" ":Synced,"
snapshot Succeeded ci "" "$NEW" t3 t4 "" ":Synced,"
status=0
HOOK_OVERRIDE="" run_subject || status=$?
check "exits 0" 0 "$status"
teardown

if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all scenarios passed"
