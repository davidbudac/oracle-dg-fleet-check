#!/usr/bin/env bash
# ============================================================
# Tests for dg_fleet_check.sh (the multi-target wrapper around
# dg_triage_sid.sh / dg_diag_sid.sh).
# ============================================================
# Usage: bash tests/test_fleet_check.sh
#
# No database, no network. The wrapper is copied into a scratch "repo" whose
# dg_triage_sid.sh / dg_diag_sid.sh are stubs that record their argv, their
# stdin and their environment and exit with a code chosen per TNS alias / SID;
# the stub ssh runs the remote command locally with `sh -c` (stdin passed
# through), so the shipped tar stream, the mktemp/oratab/env handling and the
# cleanup really execute.
#
# Covered:
#   - config parsing: comments, '#' inside a password, CRLF, duplicate
#     targets, unknown keys, key outside a section, missing/invalid fields,
#     auth inference, mode per target, --only, -n plan
#   - password target: -t alias, --peer-tns, password on stdin only (never
#     on argv), one tool invocation per target
#   - wallet target: stdin closed, no password
#   - ssh target: tar shipped and extracted, ORACLE_SID/ORACLE_HOME exported
#     (explicit and from oratab), LIBPATH, tool run with stdin closed, temp
#     dir removed, remote_dir used verbatim, BatchMode, ssh_opts word-split,
#     oratab miss -> rc 70 FAILED
#   - result aggregation: exit = worst of 0/1/2, FAILED for 64/70/255, -q
#     prints only non-OK reports, summary table
#   - --check / --review-config / scope: flag passed to the tool, per-target override, the
#     fleet VERDICT line; the engine's check-mode grading (config findings
#     listed as Info, running-state findings still graded)
#   - engine components: every standby member's broker lag, FSFO status,
#     observer pings to primary and target (Master stale = error, Backup
#     stale = warning, no observer = error), the compact --check output
# ============================================================

PASS=0
FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${TMPDIR:-/tmp}/dg_fleet_test.$$"
mkdir -p "$WORK/repo/common" "$WORK/bin" "$WORK/log" || { echo "FATAL: cannot create $WORK"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $name"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $name"; echo "    expected: '$expected'"; echo "    actual:   '$actual'"; FAIL=$((FAIL + 1))
    fi
}
assert_contains() {
    local name="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "  PASS: $name"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $name (missing: $needle)"; FAIL=$((FAIL + 1))
    fi
}
assert_not_contains() {
    local name="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "  FAIL: $name (unexpected: $needle)"; FAIL=$((FAIL + 1))
    else
        echo "  PASS: $name"; PASS=$((PASS + 1))
    fi
}

# ---- scratch repo: the real wrapper, stub tools -------------------------
cp "$ROOT/dg_fleet_check.sh" "$WORK/repo/"
: > "$WORK/repo/common/dg_local_status_common.sh"
: > "$WORK/repo/common/dg_render_common.sh"
# The stub tool: logs argv, stdin, env; exit code from STUB_RC_<alias|sid>
# (alias dots/@ mapped to _) - default 0.
for t in dg_triage_sid.sh dg_diag_sid.sh; do
    cat > "$WORK/repo/$t" <<'STUB'
#!/usr/bin/env bash
me="$(basename "$0")"
log="${STUB_LOG:?}"
key=""
args="$*"
while [[ $# -gt 0 ]]; do
    case "$1" in -t) key="$2"; shift 2 ;; *) shift ;; esac
done
[[ -z "$key" ]] && key="${ORACLE_SID:-nosid}"
stdin_data="$(cat)"
k="$(printf '%s' "$key" | tr '.@-' '___')"
rc_var="STUB_RC_${k}"
rc="${!rc_var:-0}"
{
    printf 'TOOL=%s\n' "$me"
    printf 'ARGS=%s\n' "$args"
    printf 'STDIN=%s\n' "$stdin_data"
    printf 'ORACLE_SID=%s ORACLE_HOME=%s LIBPATH=%s\n' "${ORACLE_SID:-}" "${ORACLE_HOME:-}" "${LIBPATH:-}"
    printf 'DIR=%s\n' "$(cd "$(dirname "$0")" && pwd)"
    printf 'RC=%s\n' "$rc"
} >> "$log"
printf 'REPORT from %s for %s (rc %s)\n' "$me" "$key" "$rc"
exit "$rc"
STUB
    chmod +x "$WORK/repo/$t"
done

# Stub ssh: record argv, run the last argument locally (stdin passes through).
cat > "$WORK/bin/ssh" <<'STUB'
#!/usr/bin/env bash
printf 'SSH_ARGS=%s\n' "$*" >> "${STUB_LOG:?}"
cmd="${!#}"
exec sh -c "$cmd"
STUB
chmod +x "$WORK/bin/ssh"
# No `timeout` on PATH in the stub environment: keeps the pipeline simple.
export PATH="$WORK/bin:/usr/bin:/bin"
export STUB_LOG="$WORK/log/stub.log"
export NO_COLOR=1
unset ORACLE_SID ORACLE_HOME LIBPATH DG_FLEET_TARGET_TIMEOUT

FLEET="$WORK/repo/dg_fleet_check.sh"
reset_log() { : > "$STUB_LOG"; }
run_fleet() { reset_log; OUT="$(bash "$FLEET" "$@" 2>&1)"; RC=$?; }

# ---- 1. config errors --------------------------------------------------
echo "Test 1: config validation"
printf '%s\n' '[a]' 'auth = ssh' '[a]' 'foo = 1' 'bar' '[b]' 'auth = magic' '[c]' 'auth = password' '[d]' 'auth=wallet' 'password=x' '[e]' 'auth = ssh' 'host = h' 'sid = cd b' 'peer_tns = x' > "$WORK/bad.conf"
run_fleet -c "$WORK/bad.conf" -n
assert_eq "config errors exit 64" 64 "$RC"
assert_contains "duplicate target" "$OUT" "duplicate target [a]"
assert_contains "unknown key" "$OUT" "unknown key 'foo'"
assert_contains "non key=value line" "$OUT" "expected 'key = value': bar"
assert_contains "ssh needs host" "$OUT" "[a]: auth = ssh needs a 'host' key"
assert_contains "bad auth" "$OUT" "[b]: auth must be password, wallet or ssh"
assert_contains "password needs password" "$OUT" "[c]: auth = password needs a 'password' key"
assert_contains "wallet refuses password" "$OUT" "[d]: auth = wallet does not take a password"
assert_contains "invalid sid" "$OUT" "[e]: invalid sid 'cd b'"
assert_contains "peer_tns not for ssh" "$OUT" "[e]: peer_tns only applies"
assert_eq "nothing ran on config error" "" "$(cat "$STUB_LOG")"
printf 'key = outside\n' > "$WORK/bad2.conf"
run_fleet -c "$WORK/bad2.conf"
assert_contains "key outside section" "$OUT" "key outside of a [target] section"
run_fleet
assert_eq "missing -c exits 64" 64 "$RC"
run_fleet -c "$WORK/nonexistent.conf"
assert_eq "unreadable config exits 64" 64 "$RC"
printf '[x]\nauth = wallet\n' > "$WORK/ok1.conf"
run_fleet -c "$WORK/ok1.conf" --only nope -n
assert_eq "--only unknown name exits 64" 64 "$RC"
assert_contains "--only unknown name message" "$OUT" "--only: no [nope] in the config"
run_fleet -c "$WORK/ok1.conf" --bogus
assert_eq "unknown option exits 64" 64 "$RC"
DG_FLEET_TARGET_TIMEOUT=abc bash "$FLEET" -c "$WORK/ok1.conf" >/dev/null 2>&1
assert_eq "bad DG_FLEET_TARGET_TIMEOUT exits 64" 64 "$?"

# ---- 2. the fleet config used below --------------------------------------
printf '%s\r\n' '# fleet' '[pri.world]' 'auth = password' "password = p#ss'w=ord x" 'peer_tns = stb.world' '' ';comment' '[STB]' 'tns = stb.world' 'auth = wallet' '  mode = diag ' '[host2]' 'host = oracle@dg2' 'sid = cdb1' '[host1]' 'auth = ssh' 'host = dg1' 'sid = cdb1' 'oracle_home = /u01/h19' 'remote_dir = REMOTE_DIR_PLACEHOLDER' 'ssh_opts = -p 2222 -i /k/dg key' > "$WORK/fleet.conf"
sed -i.bak "s|REMOTE_DIR_PLACEHOLDER|$WORK/repo|" "$WORK/fleet.conf" && rm -f "$WORK/fleet.conf.bak"
chmod 644 "$WORK/fleet.conf"

echo "Test 2: -n plan"
run_fleet -c "$WORK/fleet.conf" -n
assert_eq "-n exits 0" 0 "$RC"
assert_contains "plan password target" "$OUT" "pri.world                triage       tns/password pri.world"
assert_contains "plan wallet target with tns + mode" "$OUT" "STB                      diag         tns/wallet stb.world"
assert_contains "plan ssh inferred" "$OUT" "host2                    triage       ssh oracle@dg2 sid=cdb1"
assert_contains "plan count" "$OUT" "4 target(s) would be checked"
assert_contains "world-readable password warning" "$OUT" "readable by group/others"
assert_eq "-n runs nothing" "" "$(cat "$STUB_LOG")"
chmod 600 "$WORK/fleet.conf"
run_fleet -c "$WORK/fleet.conf" -n
assert_not_contains "no warning on 600 config" "$OUT" "readable by group/others"

# ---- 3. all OK run ----------------------------------------------------------
echo "Test 3: full run, every target OK"
# (the remote command reads the real /etc/oratab, so the oratab hit itself is
# proven on the lab; Test 5 covers the miss and the inherited ORACLE_HOME)
run_fleet -c "$WORK/fleet.conf" --only pri.world,STB,host1
assert_eq "all OK -> exit 0" 0 "$RC"
LOG="$(cat "$STUB_LOG")"
assert_contains "password target: -t alias" "$LOG" "ARGS=-t pri.world --peer-tns stb.world --no-color"
assert_contains "password on stdin, '#' and quote intact" "$LOG" "STDIN=p#ss'w=ord x"
assert_not_contains "password never on argv" "$LOG" "ARGS=-t pri.world --peer-tns stb.world --no-color p#ss"
assert_contains "wallet target: diag tool" "$LOG" "TOOL=dg_diag_sid.sh"
assert_contains "wallet target: -t from tns key" "$LOG" "ARGS=-t stb.world --no-color"
n_empty_stdin="$(printf '%s\n' "$LOG" | grep -c '^STDIN=$')"
assert_eq "wallet + ssh targets get empty stdin" 2 "$n_empty_stdin"
assert_contains "ssh: BatchMode and ssh_opts word-split" "$LOG" "SSH_ARGS=-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -p 2222 -i /k/dg key dg1 "
assert_contains "ssh: explicit ORACLE_HOME + LIBPATH" "$LOG" "ORACLE_SID=cdb1 ORACLE_HOME=/u01/h19 LIBPATH=/u01/h19/lib"
assert_contains "ssh: remote_dir used" "$LOG" "DIR=$WORK/repo"
assert_contains "ssh: tool run with host1 report" "$OUT" "REPORT from dg_triage_sid.sh for cdb1 (rc 0)"
assert_contains "summary header" "$OUT" "Fleet summary (3 target(s)"
assert_contains "summary OK row" "$OUT" "pri.world                tns/password pri.world"
n_tools="$(printf '%s\n' "$LOG" | grep -c '^TOOL=')"
assert_eq "one tool invocation per target" 3 "$n_tools"
n_ok="$(printf '%s\n' "$OUT" | grep -c '  OK$')"
assert_eq "three OK verdicts" 3 "$n_ok"

echo "Test 4: ssh shipping (tar + mktemp + cleanup)"
cat > "$WORK/ship.conf" <<EOC
[ship]
host = dg9
sid = cdb1
oracle_home = /u01/h19
EOC
before="$(ls -d "${TMPDIR:-/tmp}"/tmp.* /tmp/dg_fleet.* 2>/dev/null | sort)"
run_fleet -c "$WORK/ship.conf"
assert_eq "shipped run exit 0" 0 "$RC"
LOG="$(cat "$STUB_LOG")"
assert_contains "shipped tool ran from a temp dir" "$LOG" "TOOL=dg_triage_sid.sh"
dir_line="$(printf '%s\n' "$LOG" | sed -n 's/^DIR=//p')"
[[ "$dir_line" != "$WORK/repo" && -n "$dir_line" ]]
assert_eq "shipped copy ran, not the local repo" 0 "$?"
[[ ! -d "$dir_line" ]]
assert_eq "remote temp dir removed afterwards" 0 "$?"
after="$(ls -d "${TMPDIR:-/tmp}"/tmp.* /tmp/dg_fleet.* 2>/dev/null | sort)"
assert_eq "no temp dir left behind" "$before" "$after"
assert_contains "remote command exports ORACLE_SID" "$LOG" "ORACLE_SID=cdb1 ORACLE_HOME=/u01/h19"

echo "Test 5: ssh without oracle_home"
cat > "$WORK/nohome.conf" <<EOC
[nohome]
host = dg9
sid = zz_not_in_oratab
EOC
run_fleet -c "$WORK/nohome.conf"
if [[ -r /etc/oratab ]] && grep -q '^zz_not_in_oratab:' /etc/oratab; then
    echo "  SKIP: zz_not_in_oratab exists in /etc/oratab"
else
    assert_eq "oratab miss -> exit 2" 2 "$RC"
    assert_contains "oratab miss message" "$OUT" "ORACLE_HOME for zz_not_in_oratab not found in oratab"
    assert_contains "oratab miss -> FAILED (remote setup)" "$OUT" "FAILED (remote setup, rc 70)"
fi
# inherited ORACLE_HOME on the remote side is honoured before oratab
reset_log
OUT="$(ORACLE_HOME=/inherited/home bash "$FLEET" -c "$WORK/nohome.conf" 2>&1)"; RC=$?
assert_eq "inherited remote ORACLE_HOME -> exit 0" 0 "$RC"
assert_contains "inherited ORACLE_HOME used" "$(cat "$STUB_LOG")" "ORACLE_HOME=/inherited/home"

echo "Test 6: result aggregation and -q"
export STUB_RC_pri_world=1 STUB_RC_stb_world=2
run_fleet -c "$WORK/fleet.conf" --only pri.world,STB,host1
assert_eq "worst = CRITICAL -> exit 2" 2 "$RC"
assert_contains "WARNING row" "$OUT" "WARNING"
assert_contains "CRITICAL row" "$OUT" "CRITICAL"
unset STUB_RC_stb_world
run_fleet -c "$WORK/fleet.conf" --only pri.world,STB,host1
assert_eq "worst = WARNING -> exit 1" 1 "$RC"
run_fleet -c "$WORK/fleet.conf" --only pri.world,STB,host1 -q
assert_eq "-q keeps exit 1" 1 "$RC"
assert_contains "-q prints the WARNING report" "$OUT" "REPORT from dg_triage_sid.sh for pri.world (rc 1)"
assert_not_contains "-q hides OK reports" "$OUT" "REPORT from dg_diag_sid.sh for stb.world"
assert_not_contains "-q hides OK ssh report" "$OUT" "REPORT from dg_triage_sid.sh for cdb1"
assert_contains "-q still prints the summary" "$OUT" "Fleet summary"
export STUB_RC_cdb1=64
run_fleet -c "$WORK/fleet.conf" --only host1
assert_eq "rc 64 from the tool -> exit 2" 2 "$RC"
assert_contains "rc 64 shown as FAILED" "$OUT" "FAILED (usage/environment, rc 64)"
unset STUB_RC_pri_world STUB_RC_cdb1
# ssh connection failure (255)
cat > "$WORK/bin/ssh" <<'STUB'
#!/usr/bin/env bash
echo "ssh: connect to host dg1 port 22: Connection refused" >&2
exit 255
STUB
run_fleet -c "$WORK/fleet.conf" --only host1
assert_eq "ssh 255 -> exit 2" 2 "$RC"
assert_contains "ssh 255 -> FAILED (ssh connection)" "$OUT" "FAILED (ssh connection, rc 255)"
assert_contains "ssh stderr shown" "$OUT" "Connection refused"

echo "Test 7: --diag global and per-target mode override"
cat > "$WORK/mode.conf" <<EOC
[a.world]
auth = wallet
[b.world]
auth = wallet
mode = triage
EOC
run_fleet -c "$WORK/mode.conf" --diag
LOG="$(cat "$STUB_LOG")"
assert_contains "--diag -> dg_diag_sid.sh for a" "$LOG" "TOOL=dg_diag_sid.sh"
assert_contains "mode=triage overrides --diag for b" "$LOG" "TOOL=dg_triage_sid.sh"

echo "Test 8: --check / --review-config and per-target scope"
cat > "$WORK/scope.conf" <<EOC
[a.world]
auth = wallet
[b.world]
auth = wallet
scope = review-config
EOC
run_fleet -c "$WORK/scope.conf" --check -n
assert_contains "plan shows check mode" "$OUT" "a.world                  triage/check tns/wallet a.world"
assert_contains "plan shows scope=review-config override" "$OUT" "b.world                  triage       tns/wallet b.world"
run_fleet -c "$WORK/scope.conf" --check
LOG="$(cat "$STUB_LOG")"
assert_contains "--check passed to the tool" "$LOG" "ARGS=-t a.world --no-color --check"
assert_contains "scope=review-config target gets no --check" "$LOG" "ARGS=-t b.world --no-color"
assert_not_contains "no verdict line when a target ran review-config" "$OUT" "VERDICT:"
run_fleet -c "$WORK/scope.conf" --check --only a.world
assert_contains "check verdict: all OK" "$OUT" "VERDICT: Data Guard is running as configured (1 target(s))"
export STUB_RC_a_world=1
run_fleet -c "$WORK/scope.conf" --check --only a.world
assert_contains "check verdict: degraded" "$OUT" "VERDICT: Data Guard is running but DEGRADED (a.world)"
export STUB_RC_a_world=2
run_fleet -c "$WORK/scope.conf" --check --only a.world
assert_eq "check CRITICAL -> exit 2" 2 "$RC"
assert_contains "check verdict: not running" "$OUT" "VERDICT: Data Guard is NOT running correctly (problem or not checked: a.world)"
unset STUB_RC_a_world
printf '[a]\nauth = wallet\nscope = maybe\n' > "$WORK/badscope.conf"
run_fleet -c "$WORK/badscope.conf" -n
assert_eq "bad scope exits 64" 64 "$RC"
assert_contains "bad scope message" "$OUT" "[a]: scope must be check or review-config"
run_fleet -c "$WORK/scope.conf" --check --review-config --only a.world
assert_not_contains "--review-config after --check wins" "$(cat "$STUB_LOG")" "--check"
run_fleet -c "$WORK/scope.conf" --dry-run
assert_contains "--dry-run is the long form of -n" "$OUT" "nothing was connected (-n)"
assert_eq "--dry-run runs nothing" "" "$(cat "$STUB_LOG")"

echo "Test 9: engine grading in --check mode"
# Sourced in a subshell: feed collected values straight to the assess_*
# functions and count what is graded vs listed.
engine_grade() {
    (
        source "$ROOT/common/dg_local_status_common.sh"
        DG_SCOPE="$1"
        REMOTE_DATA_SOURCE=runtime
        FSFO_MODE="Enabled in Zero Data Loss Mode"; LOC_FSFO_OBSERVER_PRESENT=YES
        PRI_ROLE=PRIMARY; PRI_OPEN="READ WRITE"; PRI_SWITCH="TO STANDBY"; PRI_FORCE=NO; PRI_FLASH=NO
        PRI_DEST2_STATUS=VALID; PRI_SRL=0
        STB_ROLE="PHYSICAL STANDBY"; STB_OPEN=MOUNTED; STB_MRP_STATUS="${2:-APPLYING_LOG}"
        STB_RECOVERY_MODE="MANAGED REAL TIME APPLY"; STB_FLASH=NO; STB_SRL=0
        STB_LAST_APPLIED=10; STB_LAST_RECEIVED=10
        BROKER_OVERALL=WARNING
        DGMGRL_CONFIG="$(printf '%s\n' 'Configuration - c' '  Members:' '  cdb1      - Primary database' '    cdb1_stby - Physical standby database' '      Warning: ORA-16827: Flashback Database is disabled' '' 'Configuration Status:' 'WARNING')"
        SUMMARY_ERRORS=(); SUMMARY_WARNINGS=(); SUMMARY_INFOS=(); ERRORS=0; WARNINGS=0
        assess_primary; assess_standby; assess_broker
        printf '%s %s %s %s\n' "$ERRORS" "$WARNINGS" "$PRI_OK" "$STB_OK"
        printf '%s\n' "${SUMMARY_INFOS[@]}"
    ) 2>&1
}
G="$(engine_grade review)"
assert_eq "review-config grades config findings" "2 5 false false" "$(printf '%s\n' "$G" | head -1)"
G="$(engine_grade check)"
assert_eq "check mode: config findings not graded" "0 0 true true" "$(printf '%s\n' "$G" | head -1)"
assert_contains "check lists flashback as Info" "$G" "Not graded (--check): Standby flashback NO (FSFO needs it)"
assert_contains "check lists force logging as Info" "$G" "Not graded (--check): Primary force logging is NO"
assert_contains "check lists broker config warning as Info" "$G" "Not graded (--check): Broker overall status is WARNING (configuration diagnoses only)"
G="$(engine_grade check MRP0_NOT_RUNNING)"
assert_eq "check mode still grades a stopped MRP" "1 0 true false" "$(printf '%s\n' "$G" | head -1)"

echo "Test 10: engine components - standbys, FSFO status, observer pings"
# $1 = SHOW OBSERVER text, $2 = local FS_FAILOVER_STATUS, $3 = "render" to
# print the --check output instead of the counts.
engine_components() {
    (
        source "$ROOT/common/dg_local_status_common.sh"
        dg_render_init_colors 1
        OBS_TEXT="$1"
        run_dgmgrl() {
            case "$1" in
                "SHOW DATABASE 'cdb1_stby'") printf '%s\n' 'Database - cdb1_stby' '  Role:               PHYSICAL STANDBY' '  Intended State:     APPLY-ON' '  Transport Lag:      0 seconds (computed 1 second ago)' '  Apply Lag:          0 seconds (computed 1 second ago)' 'Database Status:' 'SUCCESS' ;;
                "SHOW DATABASE 'cdb1_stb2'") printf '%s\n' 'Database - cdb1_stb2' '  Role:               PHYSICAL STANDBY' '  Intended State:     APPLY-ON' '  Transport Lag:      0 seconds (computed 1 second ago)' '  Apply Lag:          5 minutes 3 seconds (computed 1 second ago)' 'Database Status:' 'SUCCESS' ;;
                "SHOW OBSERVER") printf '%s\n' "$OBS_TEXT" ;;
            esac
        }
        DG_SCOPE=check; TARGET_TNS=""; IS_PRIMARY=true; LOCAL_INSTANCE_AVAILABLE=true
        LOC_DBUNIQ=cdb1; LOC_HOST=dg1.example; LOC_LABEL=PRIMARY; PEER_DBUNIQ=""; DGMGRL_PEER=""
        DGMGRL_CONFIG="$(printf '%s\n' 'Configuration - cfg' '  Members:' '  cdb1      - Primary database' '    cdb1_stby - (*) Physical standby database' '    cdb1_stb2 - Physical standby database' '    cdb1_stb3 - Physical standby database (disabled)' 'Configuration Status:' 'SUCCESS')"
        DGMGRL_FSFO="$(printf '%s\n' 'Fast-Start Failover: Enabled in Zero Data Loss Mode' '  Threshold:          30 seconds' '  Active Target:      cdb1_stby')"
        LOC_FSFO_STATUS="$2"; LOC_FSFO_OBSERVER_PRESENT=YES
        BROKER_CFG_NAME=cfg; BROKER_OVERALL=SUCCESS; BROKER_STATE=OK
        PRI_ROLE=PRIMARY; PRI_OPEN="READ WRITE"; PRI_DEST2_STATUS=VALID; PRI_OK=true; PRI_DBUNIQ=cdb1
        collect_components
        parse_fsfo_fields
        SUMMARY_ERRORS=(); SUMMARY_WARNINGS=(); SUMMARY_INFOS=(); ERRORS=0; WARNINGS=0
        assess_components
        if [[ "${3:-}" == render ]]; then
            render_check_output
        else
            printf '%s %s\n' "$ERRORS" "$WARNINGS"
            printf '%s\n' "${SUMMARY_ERRORS[@]}" "${SUMMARY_WARNINGS[@]}"
        fi
    ) 2>&1
}
OBS_OK="$(printf '%s\n' 'Observer "obs1" - Master' '  Host Name:                    obs.example' '  Last Ping to Primary:         2 seconds ago' '  Last Ping to Target:          3 seconds ago')"
OBS_BAD="$(printf '%s\n' 'Observer "obs1" - Master' '  Host Name:                    obs.example' '  Last Ping to Primary:         2 seconds ago' '  Last Ping to Target:          95 seconds ago' '' 'Observer "obs2" - Backup' '  Host Name:                    obs2.example' '  Last Ping to Primary:         (unknown)' '  Last Ping to Target:          1 second ago')"
G="$(engine_components "$OBS_OK" SYNCHRONIZED)"
assert_eq "healthy observer: only the lagging 2nd standby is flagged" "0 1" "$(printf '%s\n' "$G" | head -1)"
assert_contains "second standby's apply lag graded" "$G" "Standby cdb1_stb2: apply lag 5 minutes 3 seconds"
assert_not_contains "disabled standby not graded" "$G" "cdb1_stb3"
# DGMGRL can include the observer version between the name and role.
# Keep both layouts covered: healthy pings alone must not imply Master.
for obs_version in '(19.3.0.0.0)' ' (19.48.0.0.0)'; do
    OBS_VERSION_OK="$(printf '%s\n' "$OBS_OK" | sed "s/\" -/\"${obs_version} -/")"
    G="$(engine_components "$OBS_VERSION_OK" SYNCHRONIZED)"
    assert_eq "healthy versioned Master ${obs_version}: no false error" "0 1" "$(printf '%s\n' "$G" | head -1)"
    G="$(engine_components "$OBS_VERSION_OK" SYNCHRONIZED render)"
    assert_contains "versioned Master ${obs_version}: rendered role and pings" "$G" "obs1 (Master) @ obs: last ping primary 2s, target 3s"
    OBS_VERSION_BAD="$(printf '%s\n' "$OBS_BAD" | sed "s/\" -/\"${obs_version} -/")"
    G="$(engine_components "$OBS_VERSION_BAD" SYNCHRONIZED)"
    assert_eq "versioned stale Master and Backup ${obs_version}: correct severity" "1 2" "$(printf '%s\n' "$G" | head -1)"
    assert_contains "versioned Master ${obs_version}: stale target is an error" "$G" "Observer obs1 (Master): last ping to the target 95 seconds ago (limit 30s)"
    assert_contains "versioned Backup ${obs_version}: unknown primary is a warning" "$G" "Observer obs2 (Backup): last ping to the primary (unknown) (limit 30s)"
done
OBS_BACKUP_ONLY="$(printf '%s\n' "$OBS_VERSION_OK" | sed 's/ - Master/ - Backup/')"
G="$(engine_components "$OBS_BACKUP_ONLY" SYNCHRONIZED)"
assert_eq "healthy Backup alone is not a Master" "1 1" "$(printf '%s\n' "$G" | head -1)"
assert_contains "Backup-only configuration still reports missing Master" "$G" "FSFO is enabled but no Master observer is registered"
G="$(engine_components "$OBS_BAD" SYNCHRONIZED)"
assert_eq "stale Master = error, stale Backup = warning" "1 2" "$(printf '%s\n' "$G" | head -1)"
assert_contains "Master lost the target" "$G" "Observer obs1 (Master): last ping to the target 95 seconds ago (limit 30s)"
assert_contains "Backup never reached the primary" "$G" "Observer obs2 (Backup): last ping to the primary (unknown) (limit 30s)"
G="$(DG_OBSERVER_PING_MAX=120 engine_components "$OBS_BAD" SYNCHRONIZED)"
assert_eq "DG_OBSERVER_PING_MAX raises the limit" "0 2" "$(printf '%s\n' "$G" | head -1)"
G="$(engine_components "" SYNCHRONIZED)"
assert_contains "FSFO enabled, no observer listed = error" "$G" "FSFO is enabled but the broker lists no observer"
G="$(engine_components "$OBS_OK" UNSYNCHRONIZED)"
assert_contains "FSFO UNSYNCHRONIZED = error" "$G" "FSFO status on cdb1 is UNSYNCHRONIZED (automatic failover is not ready)"
G="$(engine_components "$OBS_OK" "PRIMARY UNOBSERVED")"
assert_eq "PRIMARY UNOBSERVED = error" "1 1" "$(printf '%s\n' "$G" | head -1)"
G="$(engine_components "$OBS_BAD" SYNCHRONIZED render)"
assert_contains "check output: header with verdict" "$G" "cdb1 @ dg1 (PRIMARY)  NOT RUNNING CORRECTLY"
assert_contains "check output: one line per standby" "$G" "cdb1_stb2: APPLY-ON, transport 0s, apply 303s"
assert_contains "check output: disabled standby" "$G" "cdb1_stb3: disabled in the broker"
assert_contains "check output: observer pings" "$G" "obs1 (Master) @ obs: last ping primary 2s, target 95s"
assert_contains "check output: problems listed" "$G" "Problem  Observer obs1 (Master): last ping to the target"
n_lines="$(engine_components "$OBS_OK" SYNCHRONIZED render | grep -c .)"
assert_eq "check output is compact: header, one line per component, one per problem" 9 "$n_lines"

echo
echo "============================================================"
echo "Test Summary: $PASS passed, $FAIL failed"
echo "============================================================"
[[ $FAIL -eq 0 ]]
