#!/usr/bin/env bash
# ============================================================
# dg_fleet_check.sh - run the Data Guard triage/diag check against a
# list of targets described in a config file.
#
# Each [target] is reached in one of three ways:
#   auth = password   over the network: dg_triage_sid.sh -t <alias>, the
#                     SYS password from the config fed to the tool on stdin
#   auth = wallet     over the network: dg_triage_sid.sh -t <alias>, the
#                     auto-login wallet of THIS host supplies the credentials
#   auth = ssh        on the DB host: ssh <host>, ship the tool, run it there
#                     with ORACLE_SID=<sid> and "/ as sysdba"
#
# Config format (INI-like; blank lines and lines starting with # or ; are
# comments; no inline comments, so a password may contain '#'):
#
#   [cdb1.world]                     # section name = TNS alias (or a label)
#   auth = password
#   password = secret
#   peer_tns = cdb1_stby.world       # optional: --peer-tns
#
#   [cdb1_stby]
#   auth = ssh
#   host = oracle@dg2                # ssh destination ([user@]host)
#   sid = cdb1                       # ORACLE_SID on that host
#   oracle_home = /u01/app/...       # optional; else looked up in oratab
#   ssh_opts = -i ~/.ssh/dg -p 2222  # optional; word-split
#   remote_dir = /home/oracle/dg     # optional; existing repo copy to run
#                                    # instead of shipping the tool
#
# Optional keys for every target: tns (alias when the section name is a
# label), peer_tns, mode = triage|diag (overrides --diag for one target),
# scope = check|review-config (overrides --check/--review-config for one target).
#
# Two modes: review-config (default) grades the running state and the
# configuration; --check answers only "is Data Guard running as configured?": roles,
# transport, apply, lag, gaps, broker and observer are graded; configuration
# findings (flashback, force logging, standby redo logs, FRA headroom) are
# listed but never change the result.
#
# Exit code: the worst per-target result - 0 all OK, 1 warnings, 2 at least
# one CRITICAL or a target that could not be checked; 64 usage/config error.
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_TARGET_TIMEOUT="${DG_FLEET_TARGET_TIMEOUT:-900}"
SSH_BASE_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
SHIP_FILES=(dg_triage_sid.sh dg_diag_sid.sh common/dg_local_status_common.sh common/dg_render_common.sh)

CONFIG_FILE=""
GLOBAL_MODE="triage"
GLOBAL_SCOPE="review-config"
QUIET=false
DRY_RUN=false
NO_COLOR_FLAG=false
ONLY_LIST=""

usage() {
    cat <<USAGE
Usage: $(basename "$0") -c CONFIG [--diag] [--check|--review-config] [--only NAME[,NAME...]] [-q] [-n] [--no-color]

  -c, --config FILE  targets file (see the header of this script for the format)
      --diag         run dg_diag_sid.sh instead of dg_triage_sid.sh
      --check        check mode: only answer "is Data Guard running as configured?";
                     config findings (flashback, force logging, SRLs, FRA) are not graded
      --review-config
                     review-configuration mode (default): grade the running state
                     and the configuration
      --only NAMES   check only these [targets] (comma separated, repeatable)
  -q, --quiet        print a target's report only when it is not OK
  -n, --dry-run      parse and validate the config, print the plan, connect nowhere
      --no-color     disable colored output
  -h, --help         this help

Environment: DG_FLEET_TARGET_TIMEOUT (default 900) bounds each target's wall
clock when the timeout binary exists; DG_TARGET_TIMEOUT, DG_* thresholds are
passed through to the tools.
USAGE
}

die_usage() {
    printf 'ERROR: %s\n' "$1" >&2
    usage >&2
    exit 64
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)
            [[ $# -ge 2 && -n "$2" ]] || die_usage "option $1 requires a file"
            CONFIG_FILE="$2"; shift 2 ;;
        --config=*) CONFIG_FILE="${1#--config=}"; shift ;;
        --diag) GLOBAL_MODE="diag"; shift ;;
        --check) GLOBAL_SCOPE="check"; shift ;;
        --review-config) GLOBAL_SCOPE="review-config"; shift ;;
        --only)
            [[ $# -ge 2 && -n "$2" ]] || die_usage "option $1 requires a target name"
            ONLY_LIST="${ONLY_LIST:+${ONLY_LIST},}$2"; shift 2 ;;
        --only=*) ONLY_LIST="${ONLY_LIST:+${ONLY_LIST},}${1#--only=}"; shift ;;
        -q|--quiet) QUIET=true; shift ;;
        -n|--dry-run) DRY_RUN=true; shift ;;
        --no-color) NO_COLOR_FLAG=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die_usage "unknown option: $1" ;;
    esac
done
[[ -n "$CONFIG_FILE" ]] || die_usage "-c CONFIG is required"
[[ -r "$CONFIG_FILE" ]] || { printf 'ERROR: cannot read config file %s\n' "$CONFIG_FILE" >&2; exit 64; }
case "$FLEET_TARGET_TIMEOUT" in
    ''|*[!0-9]*) printf 'ERROR: DG_FLEET_TARGET_TIMEOUT must be a non-negative integer\n' >&2; exit 64 ;;
esac

if $NO_COLOR_FLAG || [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]]; then
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BOLD=''; C_NC=''
else
    C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[1;33m'; C_BOLD=$'\033[1m'; C_NC=$'\033[0m'
fi

# ------------------------------------------------------------------
# Config parsing (Bash 3.2: parallel indexed arrays, no declare -A)
# ------------------------------------------------------------------
T_NAME=(); T_AUTH=(); T_TNS=(); T_PASS=(); T_HOST=(); T_SID=(); T_HOME=()
T_SSHOPTS=(); T_PEER=(); T_RDIR=(); T_MODE=(); T_SCOPE=()
NT=0
CONFIG_ERRORS=0

cfg_error() {
    printf 'CONFIG ERROR (%s:%s): %s\n' "$CONFIG_FILE" "$1" "$2" >&2
    CONFIG_ERRORS=$((CONFIG_ERRORS + 1))
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

new_target() {
    T_NAME[NT]="$1"; T_AUTH[NT]=""; T_TNS[NT]=""; T_PASS[NT]=""; T_HOST[NT]=""
    T_SID[NT]=""; T_HOME[NT]=""; T_SSHOPTS[NT]=""; T_PEER[NT]=""; T_RDIR[NT]=""; T_MODE[NT]=""; T_SCOPE[NT]=""
    NT=$((NT + 1))
}

lineno=0
cur=-1
while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"
    t="$(trim "$line")"
    [[ -z "$t" || "${t:0:1}" == "#" || "${t:0:1}" == ";" ]] && continue
    if [[ "${t:0:1}" == "[" ]]; then
        if [[ "$t" != *"]" ]]; then
            cfg_error "$lineno" "unterminated section header: $t"
            continue
        fi
        name="$(trim "${t:1:${#t}-2}")"
        if [[ -z "$name" ]]; then
            cfg_error "$lineno" "empty section name"
            continue
        fi
        i=0
        while [[ $i -lt $NT ]]; do
            [[ "${T_NAME[$i]}" == "$name" ]] && cfg_error "$lineno" "duplicate target [$name]"
            i=$((i + 1))
        done
        cur=$NT
        new_target "$name"
        continue
    fi
    if [[ "$t" != *=* ]]; then
        cfg_error "$lineno" "expected 'key = value': $t"
        continue
    fi
    if [[ $cur -lt 0 ]]; then
        cfg_error "$lineno" "key outside of a [target] section: ${t%%=*}"
        continue
    fi
    key="$(trim "${t%%=*}")"
    val="$(trim "${t#*=}")"
    # tolerate the common lower/upper mix
    key="$(printf '%s' "$key" | tr 'A-Z' 'a-z')"
    case "$key" in
        auth)        T_AUTH[cur]="$(printf '%s' "$val" | tr 'A-Z' 'a-z')" ;;
        tns)         T_TNS[cur]="$val" ;;
        password)    T_PASS[cur]="$val" ;;
        host)        T_HOST[cur]="$val" ;;
        sid)         T_SID[cur]="$val" ;;
        oracle_home) T_HOME[cur]="$val" ;;
        ssh_opts)    T_SSHOPTS[cur]="$val" ;;
        peer_tns)    T_PEER[cur]="$val" ;;
        remote_dir)  T_RDIR[cur]="$val" ;;
        mode)        T_MODE[cur]="$(printf '%s' "$val" | tr 'A-Z' 'a-z')" ;;
        scope)       T_SCOPE[cur]="$(printf '%s' "$val" | tr 'A-Z' 'a-z')" ;;
        *)           cfg_error "$lineno" "unknown key '$key' in [${T_NAME[$cur]}]" ;;
    esac
done < "$CONFIG_FILE"

[[ $NT -gt 0 ]] || cfg_error 0 "no [target] section found"

# ------------------------------------------------------------------
# Validation
# ------------------------------------------------------------------
PASSWORD_IN_CONFIG=false
i=0
while [[ $i -lt $NT ]]; do
    n="${T_NAME[$i]}"
    [[ -z "${T_TNS[$i]}" ]] && T_TNS[i]="$n"
    if [[ -z "${T_AUTH[$i]}" ]]; then
        if [[ -n "${T_HOST[$i]}" ]]; then T_AUTH[i]="ssh"
        elif [[ -n "${T_PASS[$i]}" ]]; then T_AUTH[i]="password"
        else T_AUTH[i]="wallet"; fi
    fi
    case "${T_AUTH[$i]}" in
        password)
            [[ -n "${T_PASS[$i]}" ]] || cfg_error 0 "[$n]: auth = password needs a 'password' key"
            [[ "${T_PASS[$i]}" == *\"* ]] && cfg_error 0 "[$n]: the password may not contain a double quote"
            [[ -n "${T_HOST[$i]}" ]] && cfg_error 0 "[$n]: 'host' only applies to auth = ssh"
            PASSWORD_IN_CONFIG=true
            ;;
        wallet)
            [[ -n "${T_PASS[$i]}" ]] && cfg_error 0 "[$n]: auth = wallet does not take a password"
            [[ -n "${T_HOST[$i]}" ]] && cfg_error 0 "[$n]: 'host' only applies to auth = ssh"
            ;;
        ssh)
            [[ -n "${T_HOST[$i]}" ]] || cfg_error 0 "[$n]: auth = ssh needs a 'host' key"
            [[ -n "${T_SID[$i]}" ]] || cfg_error 0 "[$n]: auth = ssh needs a 'sid' key"
            [[ -n "${T_PASS[$i]}" ]] && cfg_error 0 "[$n]: auth = ssh uses '/ as sysdba' and takes no password"
            [[ -n "${T_PEER[$i]}" ]] && cfg_error 0 "[$n]: peer_tns only applies to auth = password|wallet (the DB host resolves its own peer)"
            [[ "${T_SID[$i]}" == *[!A-Za-z0-9_\$]* ]] && cfg_error 0 "[$n]: invalid sid '${T_SID[$i]}'"
            ;;
        *) cfg_error 0 "[$n]: auth must be password, wallet or ssh (got '${T_AUTH[$i]}')" ;;
    esac
    case "${T_TNS[$i]}${T_PEER[$i]}" in *\"*) cfg_error 0 "[$n]: a TNS alias cannot contain a double quote" ;; esac
    case "${T_MODE[$i]}" in ''|triage|diag) ;; *) cfg_error 0 "[$n]: mode must be triage or diag" ;; esac
    case "${T_SCOPE[$i]}" in ''|check|review-config) ;; *) cfg_error 0 "[$n]: scope must be check or review-config" ;; esac
    i=$((i + 1))
done

if [[ -n "$ONLY_LIST" ]]; then
    IFS=',' read -r -a only_names <<< "$ONLY_LIST"
    for o in "${only_names[@]}"; do
        o="$(trim "$o")"
        [[ -z "$o" ]] && continue
        found=false
        i=0
        while [[ $i -lt $NT ]]; do
            [[ "${T_NAME[$i]}" == "$o" ]] && found=true
            i=$((i + 1))
        done
        $found || cfg_error 0 "--only: no [$o] in the config"
    done
fi

[[ $CONFIG_ERRORS -eq 0 ]] || exit 64

if $PASSWORD_IN_CONFIG; then
    perms="$(ls -ld "$CONFIG_FILE" 2>/dev/null | cut -c5-10)"
    case "$perms" in
        *[rwx]*) printf '%sWARNING:%s %s holds SYS passwords but is readable by group/others (chmod 600)\n' "$C_YELLOW" "$C_NC" "$CONFIG_FILE" >&2 ;;
    esac
fi

selected() {
    [[ -z "$ONLY_LIST" ]] && return 0
    local o
    for o in "${only_names[@]}"; do
        [[ "$(trim "$o")" == "$1" ]] && return 0
    done
    return 1
}

# ------------------------------------------------------------------
# Running
# ------------------------------------------------------------------
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

bounded() {
    if [[ "$FLEET_TARGET_TIMEOUT" -gt 0 ]] && command -v timeout >/dev/null 2>&1; then
        timeout "${FLEET_TARGET_TIMEOUT}"s "$@"
    else
        "$@"
    fi
}

tool_for_mode() { [[ "$1" == "diag" ]] && printf 'dg_diag_sid.sh' || printf 'dg_triage_sid.sh'; }

# The command the remote login shell runs. Values are single-quoted for it;
# $d, $$ and $RANDOM are meant for the REMOTE shell. Exit 70 = could not
# set up; the tool's own code otherwise.
build_remote_command() {
    local idx="$1" tool="$2" flags="$3"
    local cmd=""
    if [[ -n "${T_RDIR[$idx]}" ]]; then
        cmd="d=$(shq "${T_RDIR[$idx]}"); [ -f \"\$d/$tool\" ] || { echo \"ERROR: \$d/$tool not found on \$(hostname)\" >&2; exit 70; }; "
    else
        cmd='d=$(mktemp -d 2>/dev/null) || { d="/tmp/dg_fleet.$$.$RANDOM"; mkdir -m 700 "$d" || exit 70; }; '
        cmd+='tar xf - -C "$d" || { rm -rf "$d"; exit 70; }; '
    fi
    cmd+="export ORACLE_SID=$(shq "${T_SID[$idx]}"); "
    if [[ -n "${T_HOME[$idx]}" ]]; then
        cmd+="export ORACLE_HOME=$(shq "${T_HOME[$idx]}"); "
    else
        cmd+='[ -n "${ORACLE_HOME:-}" ] || ORACLE_HOME=$(awk -F: -v s="$ORACLE_SID" '"'"'$1==s && $2!="" {print $2; exit}'"'"' /etc/oratab /var/opt/oracle/oratab 2>/dev/null); '
        cmd+='[ -n "$ORACLE_HOME" ] || { echo "ERROR: ORACLE_HOME for $ORACLE_SID not found in oratab on $(hostname); set oracle_home in the config" >&2; exit 70; }; export ORACLE_HOME; '
    fi
    cmd+='export PATH="$ORACLE_HOME/bin:$PATH"; export LIBPATH="$ORACLE_HOME/lib${LIBPATH:+:$LIBPATH}"; '
    cmd+="bash \"\$d/$tool\" $flags </dev/null; rc=\$?; "
    [[ -z "${T_RDIR[$idx]}" ]] && cmd+='rm -rf "$d"; '
    cmd+='exit $rc'
    printf '%s' "$cmd"
}

pass_through_flags() {
    local f="--no-color"
    $NO_COLOR_FLAG || [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]] || $QUIET || f=""
    [[ "$1" == "check" ]] && f="${f:+$f }--check"
    printf '%s' "$f"
}

run_target() {
    local idx="$1" mode tool flags rc out_file
    mode="${T_MODE[$idx]:-$GLOBAL_MODE}"
    tool="$(tool_for_mode "$mode")"
    flags="$(pass_through_flags "${T_SCOPE[$idx]:-$GLOBAL_SCOPE}")"
    out_file=""
    if $QUIET; then
        out_file="${TMPDIR:-/tmp}/dg_fleet.$$.$idx"
        exec 3>"$out_file" || { printf 'ERROR: cannot write %s\n' "$out_file" >&2; return 2; }
    else
        exec 3>&1
    fi

    case "${T_AUTH[$idx]}" in
        password)
            printf '%s\n' "${T_PASS[$idx]}" | bounded bash "$SCRIPT_DIR/$tool" -t "${T_TNS[$idx]}" ${T_PEER[$idx]:+--peer-tns "${T_PEER[$idx]}"} $flags >&3 2>&1
            rc=$?
            ;;
        wallet)
            bounded bash "$SCRIPT_DIR/$tool" -t "${T_TNS[$idx]}" ${T_PEER[$idx]:+--peer-tns "${T_PEER[$idx]}"} $flags >&3 2>&1 </dev/null
            rc=$?
            ;;
        ssh)
            local ssh_args=("${SSH_BASE_OPTS[@]}")
            if [[ -n "${T_SSHOPTS[$idx]}" ]]; then
                local extra
                read -r -a extra <<< "${T_SSHOPTS[$idx]}"
                ssh_args+=("${extra[@]}")
            fi
            local remote_cmd
            remote_cmd="$(build_remote_command "$idx" "$tool" "$flags")"
            if [[ -n "${T_RDIR[$idx]}" ]]; then
                bounded ssh "${ssh_args[@]}" "${T_HOST[$idx]}" "$remote_cmd" >&3 2>&1 </dev/null
                rc=$?
            else
                (cd "$SCRIPT_DIR" && tar cf - "${SHIP_FILES[@]}") | bounded ssh "${ssh_args[@]}" "${T_HOST[$idx]}" "$remote_cmd" >&3 2>&1
                rc=$?
            fi
            ;;
    esac
    exec 3>&-
    if $QUIET; then
        if [[ $rc -ne 0 ]]; then cat "$out_file"; fi
        rm -f "$out_file"
    fi
    return $rc
}

method_label() {
    case "${T_AUTH[$1]}" in
        password) printf 'tns/password %s' "${T_TNS[$1]}" ;;
        wallet)   printf 'tns/wallet %s' "${T_TNS[$1]}" ;;
        ssh)      printf 'ssh %s sid=%s' "${T_HOST[$1]}" "${T_SID[$1]}" ;;
    esac
}

verdict_of() {
    case "$1" in
        0) printf '%sOK%s' "$C_GREEN" "$C_NC" ;;
        1) printf '%sWARNING%s' "$C_YELLOW" "$C_NC" ;;
        2) printf '%sCRITICAL%s' "$C_RED" "$C_NC" ;;
        64) printf '%sFAILED%s (usage/environment, rc 64)' "$C_RED" "$C_NC" ;;
        70) printf '%sFAILED%s (remote setup, rc 70)' "$C_RED" "$C_NC" ;;
        124) printf '%sFAILED%s (timed out after %ss)' "$C_RED" "$C_NC" "$FLEET_TARGET_TIMEOUT" ;;
        255) printf '%sFAILED%s (ssh connection, rc 255)' "$C_RED" "$C_NC" ;;
        *) printf '%sFAILED%s (rc %s)' "$C_RED" "$C_NC" "$1" ;;
    esac
}

R_NAME=(); R_METHOD=(); R_VERDICT=(); R_SECS=(); R_RC=()
WORST=0
NRUN=0
ALL_CHECK=true

i=0
while [[ $i -lt $NT ]]; do
    if ! selected "${T_NAME[$i]}"; then i=$((i + 1)); continue; fi
    mode="${T_MODE[$i]:-$GLOBAL_MODE}"
    scope="${T_SCOPE[$i]:-$GLOBAL_SCOPE}"
    [[ "$scope" == "check" ]] && mode="${mode}/check" || ALL_CHECK=false
    label="$(method_label "$i")"
    if $DRY_RUN; then
        printf '%-24s %-12s %s\n' "${T_NAME[$i]}" "$mode" "$label"
        i=$((i + 1)); NRUN=$((NRUN + 1))
        continue
    fi
    printf '\n%s==== [%s] %s (%s) ====%s\n' "$C_BOLD" "${T_NAME[$i]}" "$label" "$mode" "$C_NC"
    start=$SECONDS
    run_target "$i"
    rc=$?
    R_NAME[NRUN]="${T_NAME[$i]}"
    R_METHOD[NRUN]="$label"
    R_VERDICT[NRUN]="$(verdict_of "$rc")"
    R_SECS[NRUN]=$((SECONDS - start))
    R_RC[NRUN]=$rc
    NRUN=$((NRUN + 1))
    case "$rc" in
        0) ;;
        1) [[ $WORST -lt 1 ]] && WORST=1 ;;
        *) WORST=2 ;;
    esac
    i=$((i + 1))
done

if $DRY_RUN; then
    printf '\n%s target(s) would be checked; nothing was connected (-n).\n' "$NRUN"
    exit 0
fi

printf '\n%s==== Fleet summary (%s target(s), %s) ====%s\n' "$C_BOLD" "$NRUN" "$(date '+%Y-%m-%d %H:%M:%S')" "$C_NC"
printf '%-24s %-40s %6s  %s\n' "Target" "Method" "Secs" "Result"
i=0
while [[ $i -lt $NRUN ]]; do
    printf '%-24s %-40s %6s  %s\n' "${R_NAME[$i]}" "${R_METHOD[$i]}" "${R_SECS[$i]}" "${R_VERDICT[$i]}"
    i=$((i + 1))
done

# --check: one plain answer for the whole fleet.
if $ALL_CHECK && [[ $NRUN -gt 0 ]]; then
    bad=""; degraded=""
    i=0
    while [[ $i -lt $NRUN ]]; do
        case "${R_RC[$i]}" in
            0) ;;
            1) degraded="${degraded:+$degraded, }${R_NAME[$i]}" ;;
            *) bad="${bad:+$bad, }${R_NAME[$i]}" ;;
        esac
        i=$((i + 1))
    done
    printf '\n'
    if [[ -n "$bad" ]]; then
        printf '%sVERDICT: Data Guard is NOT running correctly%s (problem or not checked: %s)\n' "$C_RED" "$C_NC" "$bad"
        [[ -n "$degraded" ]] && printf '         degraded: %s\n' "$degraded"
    elif [[ -n "$degraded" ]]; then
        printf '%sVERDICT: Data Guard is running but DEGRADED%s (%s)\n' "$C_YELLOW" "$C_NC" "$degraded"
    else
        printf '%sVERDICT: Data Guard is running as configured%s (%s target(s))\n' "$C_GREEN" "$C_NC" "$NRUN"
    fi
fi
exit $WORST
