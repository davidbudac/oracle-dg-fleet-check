#!/usr/bin/env bash
# Shared local Data Guard status collection and rendering.

if [[ -n "${DG_LOCAL_STATUS_COMMON_SH_LOADED:-}" ]]; then
    return 0
fi
DG_LOCAL_STATUS_COMMON_SH_LOADED=1

DG_LOCAL_STATUS_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DG_LOCAL_STATUS_ROOT="$(dirname "$DG_LOCAL_STATUS_COMMON_DIR")"

# Colors, layout, configurable thresholds, lag parsing, and the generic
# text/box rendering primitives (repeat_char/fit_text/wrap_text/row/header/
# subheader/status_icon/warn_icon/short_hostname/extract_first_status/
# format_services/compute_fra_*) all live in dg_render_common.sh now -
# shared with dg_status.sh (WS4.2/4.3/4.4). NO_COLOR_FLAG below is wired
# through parse_args and re-invokes dg_render_init_colors before any output.
source "${DG_LOCAL_STATUS_COMMON_DIR}/dg_render_common.sh"

NO_COLOR_FLAG=false

# -- Shared state -------------------------------------------------------------
declare -a SUMMARY_ERRORS=()
declare -a SUMMARY_WARNINGS=()
declare -a SUMMARY_INFOS=()

ERRORS=0
WARNINGS=0

PROMPT_PASSWORD=false
LOCAL_ONLY=false
SHOW_HELP=false

DG_STATUS_MODE=""
DG_SCRIPT_NAME=""
# Two modes: "review" (default, --review-config) grades the running state
# AND the configuration; "check" (--check) grades only whether Data Guard is
# running as configured
# (roles, transport, apply, lag, gaps, broker, observer). Configuration
# choices (flashback, force logging, standby redo logs, FRA headroom,
# broker property mismatches) are listed as Info and never change the result.
DG_SCOPE="review"
REMOTE_DEFAULT_PROMPT=false

REMOTE_SQL=""
REMOTE_CONNECTED=false
REMOTE_CONNECT=""
REMOTE_AUTH_METHOD="none"
REMOTE_CONNECTION_RESULT=""
REMOTE_DATA_SOURCE="broker"
REMOTE_DATA_SOURCE_LABEL=""
REMOTE_TEST_TIMEOUT="${REMOTE_TEST_TIMEOUT:-5}"

# Network mode (-t/--tns ALIAS): the "local" side is reached over SQL*Net
# instead of `sqlplus / as sysdba`. TARGET_CONNECT is the CONNECT string
# that worked (wallet /@alias, else sys/"pw"@alias with the password kept
# in SYS_PASS for the peer); every query that would have run locally goes
# through run_remote_sql_timeout with TARGET_TIMEOUT.
TARGET_TNS=""
TARGET_CONNECT=""
TARGET_AUTH_METHOD=""
TARGET_TIMEOUT="${DG_TARGET_TIMEOUT:-30}"
PEER_TNS_OVERRIDE=""
SYS_PASS=""
LOC_INSTANCE=""
LOC_HOST=""
DGMGRL_AVAILABLE=true

LOC_ALERT_MATCHES=""
LOC_DRC_MATCHES=""
LOC_ALERT_MATCH_COUNT=0
LOC_DRC_MATCH_COUNT=0
LOC_ALERT_FILE=""
LOC_DRC_FILE=""

IS_PRIMARY=false
LOC_LABEL=""
PEER_LABEL=""

# H12: set to false when the local instance cannot be identified at all
# (ORA-01034 "not available", ORA-12547, idle instance, wrong ORACLE_SID).
LOCAL_INSTANCE_AVAILABLE=true
LOCAL_INSTANCE_ERROR=""

# L20: whether the alert/broker log files were actually found, so a missing
# file is not rendered the same way as a file that simply had no matches.
LOC_ALERT_FILE_FOUND=false
LOC_DRC_FILE_FOUND=false

# -- Generic helpers ----------------------------------------------------------
# repeat_char/strip_ansi/fit_text/wrap_text/row/header/subheader/
# short_hostname/extract_first_status/status_icon/warn_icon/format_services
# now live in dg_render_common.sh (sourced above), shared with dg_status.sh.
# format_event_limit/print_event_block/is_error_event stay here: dg_status.sh
# renders alert/broker log entries differently (no "N matched, newest M
# shown" heading), so these are not genuinely shared - see WS4.4 notes.

format_event_limit() {
    local raw="$1" limit="$2"
    printf '%s\n' "$raw" | sed '/^$/d' | awk -v max="$limit" '
        NF { lines[++n] = $0 }
        END {
            if (n == 0) {
                exit
            }
            start = n
            end = n - max + 1
            if (end < 1) {
                end = 1
            }
            for (i = start; i >= end; i--) {
                print lines[i]
            }
        }
    '
}

# L20: the file that was actually inspected is ALWAYS printed (it used to be
# hidden behind DG_DEBUG=1), and "the file isn't there" - the symptom of a
# non-default diagnostic_dest or a SID mismatch - is rendered differently
# from "the file was read and nothing matched". Both used to show "(none)".
# $6 = "true" when the file exists.
print_event_block() {
    local label="$1" raw="$2" count="$3" limit="$4" filepath="$5" found="${6:-true}"
    local heading entries line ts msg
    heading="${label}: ${count} matched"
    if (( count > 0 )); then
        heading="${heading}, newest ${limit} shown"
    fi
    printf "  ${DIM}%s${NC}\n" "$heading"
    if [[ -z "$filepath" ]]; then
        printf "    ${YELLOW}(log path unknown: V\$DIAG_INFO 'Diag Trace' returned nothing)${NC}\n"
        return
    fi
    printf "    ${DIM}%s${NC}\n" "$filepath"
    case "$found" in
        true) ;;
        remote)
            printf "    ${DIM}(host file - not readable over the network; run the tool on the database host for broker log entries)${NC}\n"
            return
            ;;
        unavailable)
            printf "    ${YELLOW}(not readable: the X\$DBGALERTEXT query failed or timed out)${NC}\n"
            return
            ;;
        *)
            printf "    ${YELLOW}(file not found)${NC}\n"
            return
            ;;
    esac
    if (( count == 0 )); then
        printf "    ${DIM}(0 matched - read, no Data Guard entries)${NC}\n"
        return
    fi

    entries=$(format_event_limit "$raw" "$limit")
    while IFS= read -r line || [[ -n "$line" ]]; do
        ts=""
        msg="$line"
        if printf '%s' "$line" | grep -q '^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] '; then
            ts="${line:0:19}"
            msg="${line:21}"
        fi
        if is_error_event "$msg"; then
            if [[ -n "$ts" ]]; then
                printf "    ${DIM}%s${NC}  ${RED}%s${NC}\n" "$ts" "$msg"
            else
                printf "    ${RED}%s${NC}\n" "$msg"
            fi
        else
            if [[ -n "$ts" ]]; then
                printf "    ${DIM}%s${NC}  %s\n" "$ts" "$msg"
            else
                printf "    %s\n" "$msg"
            fi
        fi
    done <<< "$entries"
}

is_error_event() {
    local msg="$1"
    if printf '%s' "$msg" | grep -qiE 'ORA-(00000|0([^0-9]|$))'; then
        return 1
    fi
    printf '%s' "$msg" | grep -qiE 'ORA-|error|failed|failure'
}

add_summary_error() {
    local message="$1"
    SUMMARY_ERRORS+=("$message")
    ERRORS=$((ERRORS + 1))
}

add_summary_warning() {
    local message="$1"
    SUMMARY_WARNINGS+=("$message")
    WARNINGS=$((WARNINGS + 1))
}

add_summary_info() {
    local message="$1"
    SUMMARY_INFOS+=("$message")
}

dg_check_scope() {
    [[ "$DG_SCOPE" == "check" ]]
}

# A configuration finding: graded normally ($1 = error|warning), but under
# --check it is only listed, so it cannot turn a running setup red/amber.
add_config_finding() {
    local severity="$1" message="$2"
    if dg_check_scope; then
        add_summary_info "Not graded (--check): ${message}"
    elif [[ "$severity" == "error" ]]; then
        add_summary_error "$message"
    else
        add_summary_warning "$message"
    fi
}

# Broker diagnoses that describe a configuration choice rather than the
# running state: ORA-16714 / ORA-16792 (property inconsistent with the
# member setting), ORA-16789 (standby redo logs configured incorrectly),
# ORA-16827 (Flashback Database disabled).
dg_broker_config_diagnosis() {
    printf '%s' "$1" | grep -qE 'ORA-(16714|16789|16792|16827)([^0-9]|$)'
}

# True when the broker's WARNING comes only from configuration diagnoses:
# every Warning: line is one of the codes above and nothing is an Error:.
broker_warnings_all_config() {
    local line sev found=false
    while IFS= read -r line; do
        dg_is_broker_member_line "$line" && continue
        sev=$(dg_broker_diagnosis_severity "$line")
        [[ -z "$sev" ]] && continue
        [[ "$sev" == "error" ]] && return 1
        dg_broker_config_diagnosis "$line" || return 1
        found=true
    done <<< "$DGMGRL_CONFIG"
    $found
}

# Infos raised while collecting (before assess_all resets the lists).
declare -a COLLECT_INFOS=()
add_collect_info() {
    COLLECT_INFOS+=("$1")
}

show_usage() {
    local script_name="$1"
    printf "Usage: bash %s [-P] [-L] [--check|--review-config] [-t ALIAS [--peer-tns ALIAS]] [--no-color]\n" "$script_name"
    printf "  -P, --password   Prompt for SYS password for remote connection\n"
    printf "  -L, --local      Skip remote SQL checks (local + broker only)\n"
    printf "  -t, --tns ALIAS  Run over the network against ALIAS (wallet /@ALIAS, else a SYS\n"
    printf "                   password prompt) instead of the local ORACLE_SID instance;\n"
    printf "                   needs only an Oracle client (dgmgrl optional)\n"
    printf "  --peer-tns ALIAS Connect identifier for the peer as seen from THIS host (default:\n"
    printf "                   the broker's DGConnectIdentifier, which may only resolve on the DB hosts)\n"
    printf "  --check          Check mode: only answer \"is Data Guard running as configured?\";\n"
    printf "                   configuration findings (flashback, force logging, SRLs, FRA headroom)\n"
    printf "                   are listed, not graded\n"
    printf "  --review-config  Review-configuration mode (default): grade the running state and the\n"
    printf "                   configuration\n"
    printf "  --no-color       Disable colored output (also honors NO_COLOR)\n"
    printf "  -h, --help       Show this help\n"
}

parse_args() {
    local script_name="$1"
    shift
    PROMPT_PASSWORD=false
    LOCAL_ONLY=false
    SHOW_HELP=false
    NO_COLOR_FLAG=false
    TARGET_TNS=""
    PEER_TNS_OVERRIDE=""
    DG_SCOPE="review"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -P|--password)
                PROMPT_PASSWORD=true
                shift
                ;;
            -L|--local)
                LOCAL_ONLY=true
                shift
                ;;
            --check)
                DG_SCOPE="check"
                shift
                ;;
            --review-config)
                DG_SCOPE="review"
                shift
                ;;
            -t|--tns)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    printf "Option %s requires a TNS alias\n" "$1" >&2
                    show_usage "$script_name" >&2
                    return 64
                fi
                TARGET_TNS="$2"
                shift 2
                ;;
            --tns=*)
                TARGET_TNS="${1#--tns=}"
                shift
                ;;
            --peer-tns)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    printf "Option %s requires a TNS alias\n" "$1" >&2
                    show_usage "$script_name" >&2
                    return 64
                fi
                PEER_TNS_OVERRIDE="$2"
                shift 2
                ;;
            --peer-tns=*)
                PEER_TNS_OVERRIDE="${1#--peer-tns=}"
                shift
                ;;
            --no-color)
                NO_COLOR_FLAG=true
                shift
                ;;
            -h|--help)
                SHOW_HELP=true
                shift
                ;;
            *)
                printf "Unknown option: %s\n" "$1" >&2
                show_usage "$script_name" >&2
                return 64
                ;;
        esac
    done

    # Re-initialize colors now that --no-color has been parsed, and BEFORE
    # any output is produced (show_usage below is the first possible output
    # in this call path) - satisfies WS4.2's "before any output" requirement.
    $NO_COLOR_FLAG && dg_render_init_colors 1

    if $SHOW_HELP; then
        show_usage "$script_name"
        return 0
    fi
    if [[ -z "$TARGET_TNS" && -n "$PEER_TNS_OVERRIDE" ]]; then
        printf "--peer-tns only applies together with -t/--tns\n" >&2
        return 64
    fi
    if [[ "$TARGET_TNS" == *\"* || "$PEER_TNS_OVERRIDE" == *\"* ]]; then
        printf "A TNS alias cannot contain a double quote\n" >&2
        return 64
    fi
}

verify_oracle_env() {
    if [[ -n "$TARGET_TNS" ]]; then
        # Network mode: any Oracle client will do. ORACLE_SID is irrelevant,
        # ORACLE_HOME optional (a client on PATH is enough); dgmgrl may be
        # missing (Instant Client) - the broker is then read from
        # V$DG_BROKER_CONFIG instead.
        [[ -n "${ORACLE_HOME:-}" ]] && export PATH="${ORACLE_HOME}/bin:${PATH}"
        if ! command -v sqlplus >/dev/null 2>&1; then
            printf "ERROR: sqlplus not found - set ORACLE_HOME or put an Oracle client on PATH\n" >&2
            return 64
        fi
        command -v dgmgrl >/dev/null 2>&1 || DGMGRL_AVAILABLE=false
        return 0
    fi
    if [[ -z "${ORACLE_SID:-}" ]]; then
        printf "ERROR: ORACLE_SID is not set\n" >&2
        return 64
    fi
    if [[ -z "${ORACLE_HOME:-}" ]]; then
        printf "ERROR: ORACLE_HOME is not set\n" >&2
        return 64
    fi
    export PATH="${ORACLE_HOME}/bin:${PATH}"
}

# Run "$@" under the timeout binary when there is one (stdin passes
# through); otherwise run it as is.
_dg_bounded() {
    local secs="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "${secs}"s "$@"
    else
        "$@"
    fi
}

# Every dgmgrl call goes through here: locally `dgmgrl / <cmd>`; in network
# mode `/@alias` for a wallet login, else CONNECT fed on stdin so the SYS
# password never reaches the command line. Returns 1 (no output) when dgmgrl
# is not installed on this client.
run_dgmgrl() {
    local cmd="$1"
    if [[ -z "$TARGET_TNS" ]]; then
        dgmgrl -silent / "$cmd" 2>&1
        return
    fi
    $DGMGRL_AVAILABLE || return 1
    if [[ "$TARGET_AUTH_METHOD" == "wallet" ]]; then
        _dg_bounded "$TARGET_TIMEOUT" dgmgrl -silent "/@${TARGET_TNS}" "$cmd" 2>&1
    else
        _dg_bounded "$TARGET_TIMEOUT" dgmgrl -silent 2>&1 <<DGM
CONNECT sys/"${SYS_PASS}"@${TARGET_TNS}
${cmd}
DGM
    fi
}

run_local_sql() {
    if [[ -n "$TARGET_TNS" ]]; then
        run_remote_sql_timeout "$TARGET_TIMEOUT" "$TARGET_CONNECT" "$1"
        return
    fi
    sqlplus -s / as sysdba <<SQL
SET HEADING OFF FEEDBACK OFF LINESIZE 300 PAGESIZE 0 TRIMSPOOL ON
$1
EXIT;
SQL
}

run_remote_sql() {
    local connect="$1" query="$2"
    # CONNECT is fed via stdin (sqlplus -s /nolog) rather than on the
    # sqlplus command line, so a password-based connect string (sys/pw@tns)
    # never appears in `ps -ef`. Works the same for wallet-based connects
    # (/@tns) - no password involved there either way.
    # SET DEFINE OFF comes first: with DEFINE on, an '&' in the password makes
    # SQL*Plus try to substitute a variable inside the CONNECT line.
    sqlplus -s /nolog <<SQL
SET DEFINE OFF
CONNECT ${connect} AS SYSDBA
SET HEADING OFF FEEDBACK OFF LINESIZE 300 PAGESIZE 0 TRIMSPOOL ON
${query}
EXIT;
SQL
}

# Portable time bound for hosts without the `timeout` binary (stock AIX):
# run run_remote_sql in the background, poll with `sleep 1`, kill it when the
# deadline passes. `exec` makes the background PID the sqlplus process itself,
# so one kill reaches it. Output is captured in a private temp file and
# printed afterwards, as a plain `$(...)` capture would see it.
run_remote_sql_watchdog() {
    local timeout_secs="$1" connect="$2" query="$3"
    local out pid waited=0 script
    out="${TMPDIR:-/tmp}/dg_rsql.$$.${RANDOM:-0}"
    ( umask 077; : > "$out" ) 2>/dev/null || return 1
    script="SET DEFINE OFF
CONNECT ${connect} AS SYSDBA
SET HEADING OFF FEEDBACK OFF LINESIZE 300 PAGESIZE 0 TRIMSPOOL ON
${query}
EXIT;"
    ( exec sqlplus -s /nolog ) > "$out" 2>&1 <<SQL &
${script}
SQL
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if (( waited >= timeout_secs )); then
            kill "$pid" 2>/dev/null
            sleep 1
            kill -9 "$pid" 2>/dev/null
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    { wait "$pid"; } 2>/dev/null
    cat "$out" 2>/dev/null
    rm -f "$out"
}

# Inject CONNECT_TIMEOUT/TRANSPORT_CONNECT_TIMEOUT/RETRY_COUNT into a TNS
# connect identifier (a full DESCRIPTION, or a plain tnsnames.ora alias) so
# the network connect itself is time-bounded at the SQL*Net layer. This is
# the ONLY timeout mechanism on hosts without the GNU `timeout` binary
# (stock AIX has none), which is why it does not simply defer to the
# `timeout`-binary fast path in run_remote_sql_timeout below.
# Usage: identifier=$(build_timeout_connect_string 5 "$PEER_TNS")
build_timeout_connect_string() {
    local timeout_secs="$1" identifier="$2" resolved

    if printf '%s' "$identifier" | grep -qi 'DESCRIPTION[[:space:]]*='; then
        # Already a full descriptor - inject the timeout params right after
        # the opening DESCRIPTION=(
        # Note: real TNS descriptors have exactly one paren pair enclosing
        # "DESCRIPTION=" together with all its children - there is no
        # separate opening paren strictly for "DESCRIPTION" itself, so the
        # match/replace below must only consume "DESCRIPTION[ ]*=" and leave
        # the following "(" (the first child's own opening paren) untouched.
        printf '%s' "$identifier" | sed "s/DESCRIPTION[[:space:]]*=/DESCRIPTION=(CONNECT_TIMEOUT=${timeout_secs})(TRANSPORT_CONNECT_TIMEOUT=3)(RETRY_COUNT=0)/"
        return
    fi

    # Plain TNS alias - resolve it to a descriptor via tnsping so the timeout
    # params can be embedded. If tnsping is unavailable or resolution fails,
    # fall back to the bare alias (no descriptor-level timeout in that case;
    # the `timeout`-binary fast path, when present, is the only guard).
    # tnsping also tries to CONTACT the listener and waits for the answer -
    # 120 s against an unreachable host (lab, 2026-10-16: an alias that fell
    # through to EZconnect and a public DNS name) - so it is bounded: the
    # "Attempting to contact" line is printed before the wait.
    if command -v tnsping >/dev/null 2>&1; then
        resolved=$(_dg_bounded 10 tnsping "$identifier" 2>/dev/null | sed -n 's/^Attempting to contact[[:space:]]*//p' | tail -1)
        if [[ "$resolved" == *DESCRIPTION* ]]; then
            printf '%s' "$resolved" | sed "s/DESCRIPTION[[:space:]]*=/DESCRIPTION=(CONNECT_TIMEOUT=${timeout_secs})(TRANSPORT_CONNECT_TIMEOUT=3)(RETRY_COUNT=0)/"
            return
        fi
    fi

    printf '%s' "$identifier"
}

run_remote_sql_timeout() {
    local timeout_secs="$1" connect="$2" query="$3"
    local auth identifier

    # Wallet connects (/@alias) must keep the alias TEXT exactly as given. The
    # secure external password store matches credentials on the connect string
    # as written (common/setup_dg_wallet.sh stores them under the alias), so
    # rewriting /@alias into /@(DESCRIPTION=...) never finds the credential
    # and every wallet probe would fail. Those connects are bounded from
    # outside instead (timeout binary, else the background-and-kill watchdog).
    #
    # Only the password path (user/pw@alias) has no such constraint, so it
    # gets connect-time timeouts embedded in the descriptor (see
    # build_timeout_connect_string) - the SQL*Net-level bound that works
    # even where neither timeout nor a watchdog helps a hung connect.
    if [[ "$connect" != /@* && "$connect" == *@* ]]; then
        auth="${connect%@*}"
        identifier="${connect##*@}"
        connect="${auth}@$(build_timeout_connect_string "$timeout_secs" "$identifier")"
    fi

    # CONNECT is fed via stdin (sqlplus -s /nolog), not the sqlplus command
    # line, so a password-based connect string never appears in `ps -ef`.
    # identifier may be a full (DESCRIPTION=...) descriptor produced by
    # build_timeout_connect_string above - CONNECT accepts that the same way
    # a command-line logon does.
    if command -v timeout >/dev/null 2>&1; then
        timeout "${timeout_secs}"s sqlplus -s /nolog <<SQL
SET DEFINE OFF
CONNECT ${connect} AS SYSDBA
SET HEADING OFF FEEDBACK OFF LINESIZE 300 PAGESIZE 0 TRIMSPOOL ON
${query}
EXIT;
SQL
    else
        run_remote_sql_watchdog "$timeout_secs" "$connect" "$query" \
            || run_remote_sql "$connect" "$query"
    fi
}

collect_identity() {
    LOCAL_ID_SQL=$(run_local_sql "
SELECT 'IDENT|' || d.DATABASE_ROLE || '|' || d.DB_UNIQUE_NAME || '|' || i.INSTANCE_NAME || '|' || i.HOST_NAME FROM V\$DATABASE d, V\$INSTANCE i;
" 2>&1)

    LOC_ID_STATUS=$(printf '%s\n' "$LOCAL_ID_SQL" | grep '^IDENT|' | head -1 | sed 's/^IDENT|//')
    LOC_ROLE=$(printf '%s' "$LOC_ID_STATUS" | awk -F'|' '{print $1}' | dg_trim)
    LOC_DBUNIQ=$(printf '%s' "$LOC_ID_STATUS" | awk -F'|' '{print $2}' | dg_trim)
    LOC_INSTANCE=$(printf '%s' "$LOC_ID_STATUS" | awk -F'|' '{print $3}' | dg_trim)
    LOC_HOST=$(printf '%s' "$LOC_ID_STATUS" | awk -F'|' '{print $4}' | dg_trim)
    [[ -z "$LOC_INSTANCE" && -z "$TARGET_TNS" ]] && LOC_INSTANCE="${ORACLE_SID:-}"
    [[ -z "$LOC_HOST" && -z "$TARGET_TNS" ]] && LOC_HOST=$(short_hostname)

    # H12: with the instance down, every field parses empty, every
    # assessment below is gated on a non-empty role so none of them fire,
    # and the tool that exists to answer "is the database OK?" used to
    # answer "WARNING" (exit 1). Detect it explicitly here instead.
    if [[ -z "$LOC_ROLE" ]]; then
        LOCAL_INSTANCE_AVAILABLE=false
        # Keep the first ORA-/TNS- diagnostic sqlplus printed; it is the
        # single most useful line for the operator (ORA-01034 = not started,
        # ORA-01109 = not open, TNS-/ORA-12547 = bad ORACLE_HOME/SID).
        LOCAL_INSTANCE_ERROR=$(printf '%s\n' "$LOCAL_ID_SQL" \
            | grep -E 'ORA-[0-9]|TNS-[0-9]|SP2-[0-9]' | head -1 | sed 's/^[[:space:]]*//')
        IS_PRIMARY=false
        LOC_LABEL="UNKNOWN"
        PEER_LABEL="PEER"
        return
    fi

    LOCAL_INSTANCE_AVAILABLE=true
    if printf '%s' "$LOC_ROLE" | grep -qi "PRIMARY"; then
        IS_PRIMARY=true
        LOC_LABEL="PRIMARY"
        PEER_LABEL="STANDBY"
    else
        IS_PRIMARY=false
        LOC_LABEL="STANDBY"
        PEER_LABEL="PRIMARY"
    fi
}

# Network mode without dgmgrl on the client: rebuild the broker picture from
# V$DG_BROKER_CONFIG (members, roles, connect identifiers, per-member status
# code) and V$DATABASE's FS_FAILOVER_* columns, in the text shape the dgmgrl
# parsers below expect. A member whose STATUS is not 0 is shown as a
# Warning with its ORA- code (the code alone does not say warning vs error;
# dgmgrl on a DB host has the full diagnosis).
collect_broker_data_sql() {
    local rows row name ident role enabled status members="" diags="" overall="SUCCESS" fsfo
    rows=$(run_local_sql "
SELECT 'DGCFG|' || DATABASE || '|' || CONNECT_IDENTIFIER || '|' || DATAGUARD_ROLE || '|' || ENABLED || '|' || STATUS FROM V\$DG_BROKER_CONFIG ORDER BY DECODE(DATAGUARD_ROLE, 'PRIMARY', 0, 1), DATABASE;
SELECT 'FSFO|' || FS_FAILOVER_STATUS || '|' || FS_FAILOVER_CURRENT_TARGET || '|' || FS_FAILOVER_THRESHOLD || '|' || FS_FAILOVER_OBSERVER_HOST FROM V\$DATABASE;
" 2>&1)
    DGMGRL_CONFIG=""
    DGMGRL_FSFO=""
    DGMGRL_PEER=""
    PEER_DBUNIQ=""
    PEER_TNS=""
    if ! printf '%s\n' "$rows" | grep -q '^DGCFG|'; then
        if printf '%s\n' "$rows" | grep -qE 'ORA-16532|no rows'; then
            DGMGRL_CONFIG="ORA-16532: Oracle Data Guard broker configuration does not exist"
        fi
        return
    fi
    while IFS='|' read -r _ name ident role enabled status; do
        [[ -z "$name" ]] && continue
        case "$role" in
            PRIMARY)          members="${members}  ${name} - Primary database"$'\n' ;;
            "PHYSICAL STANDBY") members="${members}    ${name} - Physical standby database"$'\n' ;;
            "LOGICAL STANDBY")  members="${members}    ${name} - Logical standby database"$'\n' ;;
            *)                members="${members}    ${name} - $(printf '%s' "$role" | tr 'A-Z' 'a-z') database"$'\n' ;;
        esac
        if [[ "${status:-0}" != "0" ]]; then
            members="${members}      Warning: ORA-$(printf '%05d' "$((10#${status}))") (see dgmgrl on a DB host)"$'\n'
            overall="WARNING"
        fi
        if [[ "$name" != "$LOC_DBUNIQ" && -z "$PEER_DBUNIQ" ]]; then
            if { $IS_PRIMARY && [[ "$role" != "PRIMARY" ]]; } || { ! $IS_PRIMARY && [[ "$role" == "PRIMARY" ]]; }; then
                PEER_DBUNIQ="$name"
                PEER_TNS="$ident"
            fi
        fi
    done <<< "$(printf '%s\n' "$rows" | grep '^DGCFG|')"
    DGMGRL_CONFIG="Configuration - (read from V\$DG_BROKER_CONFIG: dgmgrl is not installed on this client)

  Members:
${members}
Configuration Status:
${overall}"
    BROKER_CFG_NAME="V\$DG_BROKER_CONFIG (no dgmgrl here)"
    BROKER_OVERALL="$overall"
    fsfo=$(printf '%s\n' "$rows" | grep '^FSFO|' | head -1 | sed 's/^FSFO|//')
    if [[ -n "$fsfo" ]]; then
        case "$(printf '%s' "$fsfo" | awk -F'|' '{print $1}')" in
            DISABLED|"") DGMGRL_FSFO="Fast-Start Failover: Disabled" ;;
            *) DGMGRL_FSFO="Fast-Start Failover: Enabled
  Threshold:          $(printf '%s' "$fsfo" | awk -F'|' '{print $3}') seconds
  Target:             $(printf '%s' "$fsfo" | awk -F'|' '{print $2}')
  Observer:           $(printf '%s' "$fsfo" | awk -F'|' '{print $4}')" ;;
        esac
    fi
}

collect_broker_data() {
    if [[ -n "$TARGET_TNS" ]] && ! $DGMGRL_AVAILABLE; then
        collect_broker_data_sql
        [[ -n "$PEER_TNS_OVERRIDE" ]] && PEER_TNS="$PEER_TNS_OVERRIDE"
        add_collect_info "Broker from V\$DG_BROKER_CONFIG (no dgmgrl)"
        return
    fi
    DGMGRL_CONFIG=$(run_dgmgrl 'SHOW CONFIGURATION')
    DGMGRL_FSFO=$(run_dgmgrl 'SHOW FAST_START FAILOVER')

    BROKER_CFG_NAME=$(printf '%s\n' "$DGMGRL_CONFIG" | grep 'Configuration -' | sed 's/.*Configuration - //' | dg_trim)
    BROKER_OVERALL=$(printf '%s\n' "$DGMGRL_CONFIG" | tail -5 | extract_first_status)

    if $IS_PRIMARY; then
        PEER_DBUNIQ=$(printf '%s\n' "$DGMGRL_CONFIG" | grep -i 'Physical standby' | head -1 | awk '{print $1}')
    else
        PEER_DBUNIQ=$(printf '%s\n' "$DGMGRL_CONFIG" | grep -i 'Primary database' | head -1 | awk '{print $1}')
    fi

    PEER_TNS=""
    if [[ -n "${PEER_DBUNIQ:-}" ]]; then
        PEER_TNS_RAW=$(run_dgmgrl "SHOW DATABASE '${PEER_DBUNIQ}' 'DGConnectIdentifier'")
        PEER_TNS=$(printf '%s\n' "$PEER_TNS_RAW" | grep 'DGConnectIdentifier' | sed "s/.*= *'//" | sed "s/'.*//")
        # The broker's identifier resolves on the DB hosts; from another
        # host the operator may have to name the peer alias explicitly.
        [[ -n "$PEER_TNS_OVERRIDE" ]] && PEER_TNS="$PEER_TNS_OVERRIDE"
        DGMGRL_PEER=$(run_dgmgrl "SHOW DATABASE '${PEER_DBUNIQ}'")
    else
        DGMGRL_PEER=""
    fi
}

_dg_restore_echo() {
    stty echo 2>/dev/null || true
}

attempt_remote_connection() {
    REMOTE_SQL=""
    REMOTE_CONNECTED=false
    REMOTE_CONNECT=""
    REMOTE_AUTH_METHOD="none"
    REMOTE_CONNECTION_RESULT=""
    REMOTE_DATA_SOURCE="broker"
    PEER_PASS_ERROR=""

    if $LOCAL_ONLY; then
        REMOTE_CONNECTION_RESULT="remote SQL skipped by -L"
        REMOTE_DATA_SOURCE="local-only"
        REMOTE_DATA_SOURCE_LABEL="local+broker (-L)"
        return
    fi

    if [[ -z "${PEER_TNS:-}" ]]; then
        REMOTE_CONNECTION_RESULT="peer TNS alias could not be discovered from broker"
        REMOTE_DATA_SOURCE="broker"
        REMOTE_DATA_SOURCE_LABEL="broker-only degraded mode"
        return
    fi

    WALLET_TEST=$(run_remote_sql_timeout "$REMOTE_TEST_TIMEOUT" "/@${PEER_TNS}" "
SELECT 'WALLET_OK' FROM DUAL;
" 2>&1)
    if printf '%s' "$WALLET_TEST" | grep -q 'WALLET_OK'; then
        REMOTE_CONNECT="/@${PEER_TNS}"
        REMOTE_CONNECTED=true
        REMOTE_AUTH_METHOD="wallet"
        REMOTE_CONNECTION_RESULT="wallet authentication succeeded"
        REMOTE_DATA_SOURCE="runtime"
        REMOTE_DATA_SOURCE_LABEL="remote runtime via wallet"
        return
    fi

    # Network mode: the SYS password that opened the target normally opens
    # the peer too (Data Guard needs identical password files), so try it
    # before asking for another one.
    if [[ -n "$TARGET_TNS" && -n "$SYS_PASS" ]]; then
        REMOTE_CONNECT="sys/\"${SYS_PASS}\"@${PEER_TNS}"
        PASS_TEST=$(run_remote_sql_timeout "$REMOTE_TEST_TIMEOUT" "$REMOTE_CONNECT" "SELECT 'PASS_OK' FROM DUAL;" 2>&1)
        if printf '%s' "$PASS_TEST" | grep -q 'PASS_OK'; then
            REMOTE_CONNECTED=true
            REMOTE_AUTH_METHOD="password"
            REMOTE_CONNECTION_RESULT="SYS password of the target accepted by the peer"
            REMOTE_DATA_SOURCE="runtime"
            REMOTE_DATA_SOURCE_LABEL="remote runtime via password"
            return
        fi
        REMOTE_CONNECT=""
        PEER_PASS_ERROR=$(printf '%s\n' "$PASS_TEST" | grep -E 'ORA-[0-9]|TNS-[0-9]' | head -1 | sed 's/^[[:space:]]*//')
    fi

    if $PROMPT_PASSWORD || $REMOTE_DEFAULT_PROMPT; then
        prompt_sys_password " Enter SYS password for remote connection (or press Enter to skip): "

        if [[ "$SYS_PASS" == *\"* ]]; then
            # A double quote cannot be embedded in a quoted CONNECT password.
            printf " ERROR: the SYS password contains a double quote (\"), which cannot be passed in a quoted CONNECT; skipping the password connection.\n" >&2
            REMOTE_CONNECTION_RESULT="SYS password contains a double quote and cannot be used; continuing with broker-only view"
        elif [[ -n "$SYS_PASS" ]]; then
            # Quote the password inside the connect string (handles most
            # special characters an operator might type, '&' included -
            # SET DEFINE OFF is the first line of the CONNECT script);
            # run_remote_sql and run_remote_sql_timeout feed this whole
            # string to sqlplus via a CONNECT statement on stdin, never on
            # the command line.
            REMOTE_CONNECT="sys/\"${SYS_PASS}\"@${PEER_TNS}"
            PASS_TEST=$(run_remote_sql_timeout "$REMOTE_TEST_TIMEOUT" "$REMOTE_CONNECT" "SELECT 'PASS_OK' FROM DUAL;" 2>&1)
            if printf '%s' "$PASS_TEST" | grep -q 'PASS_OK'; then
                REMOTE_CONNECTED=true
                REMOTE_AUTH_METHOD="password"
                REMOTE_CONNECTION_RESULT="SYS password authentication succeeded"
                REMOTE_DATA_SOURCE="runtime"
                REMOTE_DATA_SOURCE_LABEL="remote runtime via password"
                return
            fi
            REMOTE_CONNECTION_RESULT="password authentication failed; continuing with broker-only view"
        else
            REMOTE_CONNECTION_RESULT="password prompt skipped; continuing with broker-only view"
        fi
    else
        REMOTE_CONNECTION_RESULT="wallet authentication failed or timed out; continuing with broker-only view"
        if [[ -n "$TARGET_TNS" ]]; then
            REMOTE_CONNECTION_RESULT="peer ${PEER_TNS} not reachable from this host${PEER_PASS_ERROR:+ (${PEER_PASS_ERROR})}; if the broker identifier does not resolve here, pass --peer-tns ALIAS"
        fi
    fi

    REMOTE_DATA_SOURCE="broker"
    REMOTE_DATA_SOURCE_LABEL="broker-only degraded mode"
}

# Read the SYS password into SYS_PASS with echo off. Ctrl-C or a
# termination signal restores the terminal (C12). On EOF/closed stdin the
# password is empty (WS4.6) - callers treat that as "skipped". Deliberately
# not gated on `[ -t 0 ]`: the E2E suite pipes real answers in.
prompt_sys_password() {
    printf '%s' "$1"
    trap '_dg_restore_echo' EXIT
    trap '_dg_restore_echo; printf "\n"; trap - EXIT; exit 130' INT
    trap '_dg_restore_echo; printf "\n"; trap - EXIT; exit 143' TERM
    stty -echo 2>/dev/null || true
    read -r SYS_PASS || SYS_PASS=""
    _dg_restore_echo
    trap - EXIT INT TERM
    printf "\n"
}

# Network mode: open the target. Wallet (/@alias) first, then a SYS password
# prompt; without a working login nothing can be collected, so a failure is
# fatal (return 2) with the first ORA-/TNS- line sqlplus printed.
connect_target() {
    local out err
    TARGET_CONNECT=""
    TARGET_AUTH_METHOD=""
    out=$(run_remote_sql_timeout "$TARGET_TIMEOUT" "/@${TARGET_TNS}" "SELECT 'WALLET_OK' FROM DUAL;" 2>&1)
    if printf '%s' "$out" | grep -q 'WALLET_OK'; then
        TARGET_CONNECT="/@${TARGET_TNS}"
        TARGET_AUTH_METHOD="wallet"
        return 0
    fi
    err=$(printf '%s\n' "$out" | grep -E 'ORA-[0-9]|TNS-[0-9]|SP2-[0-9]' | head -1 | sed 's/^[[:space:]]*//')
    case "$err" in
        *ORA-12154*|*ORA-12514*|*ORA-12541*|*ORA-12170*|*ORA-12543*|*ORA-12545*|*TNS-*)
            # Not an authentication problem - a password will not help.
            printf "ERROR: cannot reach %s: %s\n" "$TARGET_TNS" "$err" >&2
            return 2
            ;;
    esac
    prompt_sys_password " Enter SYS password for ${TARGET_TNS} (wallet login ${err:-failed}): "
    if [[ -z "$SYS_PASS" ]]; then
        printf "ERROR: cannot connect to %s AS SYSDBA: wallet login %s and no password given\n" "$TARGET_TNS" "${err:-failed}" >&2
        return 2
    fi
    if [[ "$SYS_PASS" == *\"* ]]; then
        printf "ERROR: the SYS password contains a double quote (\"), which cannot be passed in a quoted CONNECT\n" >&2
        return 2
    fi
    TARGET_CONNECT="sys/\"${SYS_PASS}\"@${TARGET_TNS}"
    out=$(run_remote_sql_timeout "$TARGET_TIMEOUT" "$TARGET_CONNECT" "SELECT 'PASS_OK' FROM DUAL;" 2>&1)
    if printf '%s' "$out" | grep -q 'PASS_OK'; then
        TARGET_AUTH_METHOD="password"
        return 0
    fi
    err=$(printf '%s\n' "$out" | grep -E 'ORA-[0-9]|TNS-[0-9]|SP2-[0-9]' | head -1 | sed 's/^[[:space:]]*//')
    printf "ERROR: cannot connect to %s AS SYSDBA: %s\n" "$TARGET_TNS" "${err:-no response within ${TARGET_TIMEOUT}s}" >&2
    return 2
}

collect_remote_sql() {
    if [[ "$REMOTE_CONNECTED" != true ]]; then
        return
    fi

    REMOTE_SQL=$(run_remote_sql "$REMOTE_CONNECT" "
${DG_SQL_SELECT_DBSTATUS_FULL}
${DG_SQL_SELECT_REDOLOG}
${DG_SQL_SELECT_SRLCOUNT}
${DG_SQL_SELECT_ARCHGAP}
SELECT 'UNNAMEDDF|' || COUNT(*) FROM V\$DATAFILE WHERE NAME LIKE '%UNNAMED%';
${DG_SQL_SELECT_FRA}
${DG_SQL_SELECT_SERVICE}
${DG_SQL_SELECT_MRP}
${DG_SQL_SELECT_DGSTATS}
${DG_SQL_SELECT_APPLYINFO}
${DG_SQL_SELECT_RECMODE}
" 2>&1)
}

collect_local_sql() {
    LOCAL_SQL=$(run_local_sql "
${DG_SQL_SELECT_DBSTATUS_FULL}
${DG_SQL_SELECT_DGPARAMS}
${DG_SQL_SELECT_REDOLOG}
${DG_SQL_SELECT_SRLCOUNT}
${DG_SQL_SELECT_ARCHGAP}
SELECT 'UNNAMEDDF|' || COUNT(*) FROM V\$DATAFILE WHERE NAME LIKE '%UNNAMED%';
SELECT 'ARCHDEST|' || DEST_ID || '|' || STATUS || '|' || DB_UNIQUE_NAME || '|' || ERROR FROM V\$ARCHIVE_DEST WHERE DEST_ID IN (1,2);
${DG_SQL_SELECT_FSFODB}
${DG_SQL_SELECT_FRA}
${DG_SQL_SELECT_SERVICE}
${DG_SQL_SELECT_MRP}
${DG_SQL_SELECT_DGSTATS}
${DG_SQL_SELECT_APPLYINFO}
${DG_SQL_SELECT_RECMODE}
")
}

parse_local_sql() {
    LOC_DBSTATUS=$(printf '%s\n' "$LOCAL_SQL" | grep '^DBSTATUS|' | head -1 | sed 's/^DBSTATUS|//')
    LOC_ROLE=$(printf '%s' "$LOC_DBSTATUS" | awk -F'|' '{print $1}' | dg_trim)
    LOC_OPEN=$(printf '%s' "$LOC_DBSTATUS" | awk -F'|' '{print $2}' | dg_trim)
    LOC_PROTECT=$(printf '%s' "$LOC_DBSTATUS" | awk -F'|' '{print $3}' | dg_trim)
    LOC_SWITCH=$(printf '%s' "$LOC_DBSTATUS" | awk -F'|' '{print $4}' | dg_trim)
    LOC_FORCE=$(printf '%s' "$LOC_DBSTATUS" | awk -F'|' '{print $5}' | dg_trim)
    LOC_FLASH=$(printf '%s' "$LOC_DBSTATUS" | awk -F'|' '{print $6}' | dg_trim)
    LOC_DBUNIQ=$(printf '%s' "$LOC_DBSTATUS" | awk -F'|' '{print $7}' | dg_trim)

    LOC_BROKER=$(printf '%s\n' "$LOCAL_SQL" | grep 'dg_broker_start' | awk -F'|' '{print $3}' | dg_trim)
    LOC_ARCHGAP=$(printf '%s\n' "$LOCAL_SQL" | grep '^ARCHGAP|' | awk -F'|' '{print $2}' | dg_trim)
    LOC_UNNAMED=$(printf '%s\n' "$LOCAL_SQL" | grep '^UNNAMEDDF|' | awk -F'|' '{print $2}' | dg_trim)
    case "$LOC_UNNAMED" in ''|*[!0-9]*) LOC_UNNAMED="" ;; esac
    LOC_REDO=$(printf '%s\n' "$LOCAL_SQL" | grep '^REDOLOG|' | sed 's/^REDOLOG|//')
    LOC_REDO_CNT=$(printf '%s' "$LOC_REDO" | awk -F'|' '{print $1}' | dg_trim)
    LOC_REDO_MB=$(printf '%s' "$LOC_REDO" | awk -F'|' '{print $2}' | dg_trim)
    LOC_SRL=$(printf '%s\n' "$LOCAL_SQL" | grep '^SRLCOUNT|' | awk -F'|' '{print $2}' | dg_trim)

    LOC_DEST2_STATUS=$(printf '%s\n' "$LOCAL_SQL" | grep '^ARCHDEST|2|' | awk -F'|' '{print $3}' | dg_trim)
    LOC_DEST2_DBUNIQ=$(printf '%s\n' "$LOCAL_SQL" | grep '^ARCHDEST|2|' | awk -F'|' '{print $4}' | dg_trim)
    LOC_DEST2_ERROR=$(printf '%s\n' "$LOCAL_SQL" | grep '^ARCHDEST|2|' | awk -F'|' '{print $5}' | dg_trim)

    LOC_FSFODB=$(printf '%s\n' "$LOCAL_SQL" | grep '^FSFODB|' | head -1 | sed 's/^FSFODB|//')
    LOC_FSFO_STATUS=$(printf '%s' "$LOC_FSFODB" | awk -F'|' '{print $1}' | dg_trim)
    LOC_FSFO_OBSERVER_PRESENT=$(printf '%s' "$LOC_FSFODB" | awk -F'|' '{print $2}' | dg_trim)
    LOC_FSFO_OBSERVER_HOST=$(printf '%s' "$LOC_FSFODB" | awk -F'|' '{print $3}' | dg_trim)

    LOC_FRA=$(printf '%s\n' "$LOCAL_SQL" | grep '^FRA|' | head -1 | sed 's/^FRA|//')
    LOC_FRA_PATH=$(printf '%s' "$LOC_FRA" | awk -F'|' '{print $1}' | dg_trim)
    LOC_FRA_SIZE=$(printf '%s' "$LOC_FRA" | awk -F'|' '{print $2}' | dg_trim)
    LOC_FRA_USED=$(printf '%s' "$LOC_FRA" | awk -F'|' '{print $3}' | dg_trim)
    LOC_FRA_RECLAIM=$(printf '%s' "$LOC_FRA" | awk -F'|' '{print $4}' | dg_trim)
    LOC_FRA_FILES=$(printf '%s' "$LOC_FRA" | awk -F'|' '{print $5}' | dg_trim)

    LOC_SERVICES=$(format_services "$(printf '%s\n' "$LOCAL_SQL" | grep '^SERVICE|' | sed 's/^SERVICE|//')")

    LOC_MRP=$(printf '%s\n' "$LOCAL_SQL" | grep '^MRP|' | head -1 | sed 's/^MRP|//')
    LOC_MRP_STATUS=$(printf '%s' "$LOC_MRP" | awk -F'|' '{print $2}' | dg_trim)
    LOC_MRP_SEQ=$(printf '%s' "$LOC_MRP" | awk -F'|' '{print $3}' | dg_trim)

    LOC_TRANSPORT_LAG=$(printf '%s\n' "$LOCAL_SQL" | grep 'transport lag' | awk -F'|' '{print $3}' | dg_trim)
    LOC_APPLY_LAG=$(printf '%s\n' "$LOCAL_SQL" | grep 'apply lag' | awk -F'|' '{print $3}' | dg_trim)
    LOC_APPLY_FINISH=$(printf '%s\n' "$LOCAL_SQL" | grep 'apply finish time' | awk -F'|' '{print $3}' | dg_trim)

    LOC_APPLYINFO=$(printf '%s\n' "$LOCAL_SQL" | grep '^APPLYINFO|' | sed 's/^APPLYINFO|//')
    LOC_LAST_APPLIED=$(printf '%s' "$LOC_APPLYINFO" | awk -F'|' '{print $1}' | dg_trim)
    LOC_LAST_RECEIVED=$(printf '%s' "$LOC_APPLYINFO" | awk -F'|' '{print $2}' | dg_trim)
    LOC_RECOVERY_MODE=$(printf '%s\n' "$LOCAL_SQL" | grep '^RECMODE|' | head -1 | awk -F'|' '{print $2}' | dg_trim)
}

parse_remote_sql() {
    REM_ROLE=""
    REM_OPEN=""
    REM_PROTECT=""
    REM_SWITCH=""
    REM_FORCE=""
    REM_FLASH=""
    REM_DBUNIQ=""
    REM_REDO_CNT=""
    REM_REDO_MB=""
    REM_SRL=""
    REM_ARCHGAP=""
    REM_UNNAMED=""
    REM_FRA_PATH=""
    REM_FRA_SIZE=""
    REM_FRA_USED=""
    REM_FRA_RECLAIM=""
    REM_FRA_FILES=""
    REM_MRP_STATUS=""
    REM_MRP_SEQ=""
    REM_TRANSPORT_LAG=""
    REM_APPLY_LAG=""
    REM_APPLY_FINISH=""
    REM_LAST_APPLIED=""
    REM_LAST_RECEIVED=""
    REM_RECOVERY_MODE=""
    REM_SERVICES=""

    if [[ -z "$REMOTE_SQL" ]]; then
        return
    fi

    REM_DBSTATUS=$(printf '%s\n' "$REMOTE_SQL" | grep '^DBSTATUS|' | head -1 | sed 's/^DBSTATUS|//')
    REM_ROLE=$(printf '%s' "$REM_DBSTATUS" | awk -F'|' '{print $1}' | dg_trim)
    REM_OPEN=$(printf '%s' "$REM_DBSTATUS" | awk -F'|' '{print $2}' | dg_trim)
    REM_PROTECT=$(printf '%s' "$REM_DBSTATUS" | awk -F'|' '{print $3}' | dg_trim)
    REM_SWITCH=$(printf '%s' "$REM_DBSTATUS" | awk -F'|' '{print $4}' | dg_trim)
    REM_FORCE=$(printf '%s' "$REM_DBSTATUS" | awk -F'|' '{print $5}' | dg_trim)
    REM_FLASH=$(printf '%s' "$REM_DBSTATUS" | awk -F'|' '{print $6}' | dg_trim)
    REM_DBUNIQ=$(printf '%s' "$REM_DBSTATUS" | awk -F'|' '{print $7}' | dg_trim)

    REM_REDO=$(printf '%s\n' "$REMOTE_SQL" | grep '^REDOLOG|' | sed 's/^REDOLOG|//')
    REM_REDO_CNT=$(printf '%s' "$REM_REDO" | awk -F'|' '{print $1}' | dg_trim)
    REM_REDO_MB=$(printf '%s' "$REM_REDO" | awk -F'|' '{print $2}' | dg_trim)
    REM_SRL=$(printf '%s\n' "$REMOTE_SQL" | grep '^SRLCOUNT|' | awk -F'|' '{print $2}' | dg_trim)
    REM_ARCHGAP=$(printf '%s\n' "$REMOTE_SQL" | grep '^ARCHGAP|' | awk -F'|' '{print $2}' | dg_trim)
    REM_UNNAMED=$(printf '%s\n' "$REMOTE_SQL" | grep '^UNNAMEDDF|' | awk -F'|' '{print $2}' | dg_trim)
    case "$REM_UNNAMED" in ''|*[!0-9]*) REM_UNNAMED="" ;; esac

    REM_FRA=$(printf '%s\n' "$REMOTE_SQL" | grep '^FRA|' | head -1 | sed 's/^FRA|//')
    REM_FRA_PATH=$(printf '%s' "$REM_FRA" | awk -F'|' '{print $1}' | dg_trim)
    REM_FRA_SIZE=$(printf '%s' "$REM_FRA" | awk -F'|' '{print $2}' | dg_trim)
    REM_FRA_USED=$(printf '%s' "$REM_FRA" | awk -F'|' '{print $3}' | dg_trim)
    REM_FRA_RECLAIM=$(printf '%s' "$REM_FRA" | awk -F'|' '{print $4}' | dg_trim)
    REM_FRA_FILES=$(printf '%s' "$REM_FRA" | awk -F'|' '{print $5}' | dg_trim)

    REM_SERVICES=$(format_services "$(printf '%s\n' "$REMOTE_SQL" | grep '^SERVICE|' | sed 's/^SERVICE|//')")

    REM_MRP=$(printf '%s\n' "$REMOTE_SQL" | grep '^MRP|' | head -1 | sed 's/^MRP|//')
    REM_MRP_STATUS=$(printf '%s' "$REM_MRP" | awk -F'|' '{print $2}' | dg_trim)
    REM_MRP_SEQ=$(printf '%s' "$REM_MRP" | awk -F'|' '{print $3}' | dg_trim)

    REM_TRANSPORT_LAG=$(printf '%s\n' "$REMOTE_SQL" | grep 'transport lag' | awk -F'|' '{print $3}' | dg_trim)
    REM_APPLY_LAG=$(printf '%s\n' "$REMOTE_SQL" | grep 'apply lag' | awk -F'|' '{print $3}' | dg_trim)
    REM_APPLY_FINISH=$(printf '%s\n' "$REMOTE_SQL" | grep 'apply finish time' | awk -F'|' '{print $3}' | dg_trim)

    REM_APPLYINFO=$(printf '%s\n' "$REMOTE_SQL" | grep '^APPLYINFO|' | sed 's/^APPLYINFO|//')
    REM_LAST_APPLIED=$(printf '%s' "$REM_APPLYINFO" | awk -F'|' '{print $1}' | dg_trim)
    REM_LAST_RECEIVED=$(printf '%s' "$REM_APPLYINFO" | awk -F'|' '{print $2}' | dg_trim)
    REM_RECOVERY_MODE=$(printf '%s\n' "$REMOTE_SQL" | grep '^RECMODE|' | head -1 | awk -F'|' '{print $2}' | dg_trim)
}

# Network mode: the alert log is read through X$DBGALERTEXT (last 24 h,
# newest 2000 entries, rdbms component), emitted as timestamp line + message
# line so the same awk filter applies; the broker log drc<SID>.log is a host
# file with no SQL view and is reported as not readable from here. The fixed
# table, not V$DIAG_ALERT_EXT: on a MOUNTED standby the view fails with
# ORA-01219 (queries allowed on fixed tables only), the X$ table answers
# (19.27 lab, 2026-10-16). One alert entry spans several rows with the same
# timestamp, so INDX keeps them in log order.
collect_log_matches_sql() {
    local raw
    LOC_ALERT_MATCHES=""
    LOC_DRC_MATCHES=""
    LOC_ALERT_MATCH_COUNT=0
    LOC_DRC_MATCH_COUNT=0
    LOC_ALERT_FILE="X\$DBGALERTEXT on ${LOC_HOST:-$TARGET_TNS} (alert log, last 24 h)"
    LOC_DRC_FILE="drc${LOC_INSTANCE:-<sid>}.log on ${LOC_HOST:-the database host}"
    LOC_ALERT_FILE_FOUND=unavailable
    LOC_DRC_FILE_FOUND=remote
    raw=$(run_local_sql "
SELECT 'ALERTTS|' || TO_CHAR(ORIGINATING_TIMESTAMP, 'YYYY-MM-DD\"T\"HH24:MI:SS') || CHR(10) || 'ALERTMSG|' || SUBSTR(REPLACE(REPLACE(MESSAGE_TEXT, CHR(13), ' '), CHR(10), ' '), 1, 250)
FROM (SELECT ORIGINATING_TIMESTAMP, INDX, MESSAGE_TEXT FROM X\$DBGALERTEXT
      WHERE COMPONENT_ID = 'rdbms' AND ORIGINATING_TIMESTAMP > SYSTIMESTAMP - INTERVAL '1' DAY
      ORDER BY ORIGINATING_TIMESTAMP DESC, INDX DESC)
WHERE ROWNUM <= 2000
ORDER BY ORIGINATING_TIMESTAMP, INDX;
" 2>/dev/null)
    if printf '%s\n' "$raw" | grep -q '^ALERTTS|'; then
        LOC_ALERT_FILE_FOUND=true
        LOC_ALERT_MATCHES=$(printf '%s\n' "$raw" | grep -E '^ALERT(TS|MSG)[|]' | sed 's/^ALERTTS|//; s/^ALERTMSG|//' | awk "$DG_ALERT_LOG_AWK_FILTER" 2>/dev/null)
        LOC_ALERT_MATCH_COUNT=$(printf '%s\n' "$LOC_ALERT_MATCHES" | sed '/^$/d' | wc -l | tr -d ' ')
    elif [[ -n "$raw" ]] && ! printf '%s\n' "$raw" | grep -qE 'ORA-|SP2-'; then
        # Query ran, nothing in the last 24 hours.
        LOC_ALERT_FILE_FOUND=true
    fi
}

collect_log_matches() {
    if [[ -n "$TARGET_TNS" ]]; then
        collect_log_matches_sql
        return
    fi
    LOC_ALERT_TRACE=$(run_local_sql "SELECT VALUE FROM V\$DIAG_INFO WHERE NAME = 'Diag Trace';" 2>/dev/null | dg_trim)
    # Guard against an empty/failed V$DIAG_INFO query producing paths like
    # "/alert_cdb1.log" that would look like a plain "file not found".
    if [[ -z "$LOC_ALERT_TRACE" ]]; then
        LOC_ALERT_FILE=""
        LOC_DRC_FILE=""
    else
        LOC_ALERT_FILE="${LOC_ALERT_TRACE}/alert_${ORACLE_SID}.log"
        LOC_DRC_FILE="${LOC_ALERT_TRACE}/drc${ORACLE_SID}.log"
    fi

    LOC_ALERT_MATCHES=""
    LOC_DRC_MATCHES=""
    LOC_ALERT_MATCH_COUNT=0
    LOC_DRC_MATCH_COUNT=0
    LOC_ALERT_FILE_FOUND=false
    LOC_DRC_FILE_FOUND=false

    if [[ -n "$LOC_ALERT_FILE" && -f "$LOC_ALERT_FILE" ]]; then
        LOC_ALERT_FILE_FOUND=true
        LOC_ALERT_MATCHES=$(tail -2000 "$LOC_ALERT_FILE" | awk "$DG_ALERT_LOG_AWK_FILTER" 2>/dev/null)
        LOC_ALERT_MATCH_COUNT=$(printf '%s\n' "$LOC_ALERT_MATCHES" | sed '/^$/d' | wc -l | tr -d ' ')
    fi

    if [[ -n "$LOC_DRC_FILE" && -f "$LOC_DRC_FILE" ]]; then
        LOC_DRC_FILE_FOUND=true
        LOC_DRC_MATCHES=$(tail -500 "$LOC_DRC_FILE" | awk "$DG_BROKER_LOG_AWK_FILTER" 2>/dev/null)
        LOC_DRC_MATCH_COUNT=$(printf '%s\n' "$LOC_DRC_MATCHES" | sed '/^$/d' | wc -l | tr -d ' ')
    fi
}

assign_role_views() {
    if $IS_PRIMARY; then
        PRI_ROLE="$LOC_ROLE"
        PRI_OPEN="$LOC_OPEN"
        PRI_PROTECT="$LOC_PROTECT"
        PRI_SWITCH="$LOC_SWITCH"
        PRI_FORCE="$LOC_FORCE"
        PRI_FLASH="$LOC_FLASH"
        PRI_DBUNIQ="$LOC_DBUNIQ"
        PRI_BROKER="$LOC_BROKER"
        PRI_REDO_CNT="$LOC_REDO_CNT"
        PRI_REDO_MB="$LOC_REDO_MB"
        PRI_SRL="$LOC_SRL"
        PRI_DEST2_STATUS="$LOC_DEST2_STATUS"
        PRI_DEST2_DBUNIQ="$LOC_DEST2_DBUNIQ"
        PRI_DEST2_ERROR="${LOC_DEST2_ERROR:-}"
        PRI_ARCHGAP="$LOC_ARCHGAP"
        PRI_UNNAMED="$LOC_UNNAMED"
        PRI_FRA_PATH="$LOC_FRA_PATH"
        PRI_FRA_SIZE="$LOC_FRA_SIZE"
        PRI_FRA_USED="$LOC_FRA_USED"
        PRI_FRA_RECLAIM="$LOC_FRA_RECLAIM"
        PRI_FRA_FILES="$LOC_FRA_FILES"
        PRI_SERVICES="$LOC_SERVICES"
        PRI_HOST="${LOC_HOST:-$(short_hostname)}"

        # L17: dg_broker_start is only ever read locally (V$PARAMETER on
        # this instance). Attribute it to the side we actually queried.
        STB_BROKER=""

        STB_ROLE="$REM_ROLE"
        STB_OPEN="$REM_OPEN"
        STB_PROTECT="$REM_PROTECT"
        STB_SWITCH="$REM_SWITCH"
        STB_FORCE="$REM_FORCE"
        STB_FLASH="$REM_FLASH"
        STB_DBUNIQ="${REM_DBUNIQ:-${PEER_DBUNIQ:-?}}"
        STB_REDO_CNT="$REM_REDO_CNT"
        STB_REDO_MB="$REM_REDO_MB"
        STB_SRL="$REM_SRL"
        STB_ARCHGAP="$REM_ARCHGAP"
        STB_UNNAMED="$REM_UNNAMED"
        STB_MRP_STATUS="$REM_MRP_STATUS"
        STB_MRP_SEQ="$REM_MRP_SEQ"
        STB_TRANSPORT_LAG="$REM_TRANSPORT_LAG"
        STB_APPLY_LAG="$REM_APPLY_LAG"
        STB_APPLY_FINISH="$REM_APPLY_FINISH"
        STB_LAST_APPLIED="$REM_LAST_APPLIED"
        STB_LAST_RECEIVED="$REM_LAST_RECEIVED"
        STB_RECOVERY_MODE="$REM_RECOVERY_MODE"
        STB_FRA_PATH="$REM_FRA_PATH"
        STB_FRA_SIZE="$REM_FRA_SIZE"
        STB_FRA_USED="$REM_FRA_USED"
        STB_FRA_RECLAIM="$REM_FRA_RECLAIM"
        STB_FRA_FILES="$REM_FRA_FILES"
        STB_SERVICES="$REM_SERVICES"
        STB_HOST="${PEER_TNS:-unknown}"
    else
        STB_ROLE="$LOC_ROLE"
        STB_OPEN="$LOC_OPEN"
        STB_PROTECT="$LOC_PROTECT"
        STB_SWITCH="$LOC_SWITCH"
        STB_FORCE="$LOC_FORCE"
        STB_FLASH="$LOC_FLASH"
        STB_DBUNIQ="$LOC_DBUNIQ"
        STB_REDO_CNT="$LOC_REDO_CNT"
        STB_REDO_MB="$LOC_REDO_MB"
        STB_SRL="$LOC_SRL"
        STB_ARCHGAP="$LOC_ARCHGAP"
        STB_UNNAMED="$LOC_UNNAMED"
        STB_MRP_STATUS="$LOC_MRP_STATUS"
        STB_MRP_SEQ="$LOC_MRP_SEQ"
        STB_TRANSPORT_LAG="$LOC_TRANSPORT_LAG"
        STB_APPLY_LAG="$LOC_APPLY_LAG"
        STB_APPLY_FINISH="$LOC_APPLY_FINISH"
        STB_LAST_APPLIED="$LOC_LAST_APPLIED"
        STB_LAST_RECEIVED="$LOC_LAST_RECEIVED"
        STB_RECOVERY_MODE="$LOC_RECOVERY_MODE"
        STB_FRA_PATH="$LOC_FRA_PATH"
        STB_FRA_SIZE="$LOC_FRA_SIZE"
        STB_FRA_USED="$LOC_FRA_USED"
        STB_FRA_RECLAIM="$LOC_FRA_RECLAIM"
        STB_FRA_FILES="$LOC_FRA_FILES"
        STB_SERVICES="$LOC_SERVICES"
        STB_HOST="${LOC_HOST:-$(short_hostname)}"
        # L17: this is the STANDBY's own dg_broker_start (we are running on
        # the standby). It used to be published as PRI_BROKER, so the tool
        # reported "dg_broker_start is FALSE" against the primary - the
        # wrong host entirely. The remote SQL never queries V$PARAMETER, so
        # the primary's value is genuinely unknown from here.
        STB_BROKER="$LOC_BROKER"

        PRI_ROLE="$REM_ROLE"
        PRI_OPEN="$REM_OPEN"
        PRI_PROTECT="$REM_PROTECT"
        PRI_SWITCH="$REM_SWITCH"
        PRI_FORCE="$REM_FORCE"
        PRI_FLASH="$REM_FLASH"
        PRI_DBUNIQ="${REM_DBUNIQ:-${PEER_DBUNIQ:-?}}"
        PRI_BROKER=""
        PRI_REDO_CNT="$REM_REDO_CNT"
        PRI_REDO_MB="$REM_REDO_MB"
        PRI_SRL="$REM_SRL"
        PRI_DEST2_STATUS=""
        PRI_DEST2_DBUNIQ=""
        PRI_DEST2_ERROR=""
        PRI_ARCHGAP="$REM_ARCHGAP"
        PRI_UNNAMED="$REM_UNNAMED"
        PRI_FRA_PATH="$REM_FRA_PATH"
        PRI_FRA_SIZE="$REM_FRA_SIZE"
        PRI_FRA_USED="$REM_FRA_USED"
        PRI_FRA_RECLAIM="$REM_FRA_RECLAIM"
        PRI_FRA_FILES="$REM_FRA_FILES"
        PRI_SERVICES="$REM_SERVICES"
        PRI_HOST="${PEER_TNS:-unknown}"
    fi
}

# compute_fra_pct/compute_fra_effective now live in dg_render_common.sh.
# Lag display text uses the shared dg_display_lag_value ("none" for a
# truly-zero lag, raw value otherwise); the WARN/OK *decision* uses
# dg_parse_lag_seconds against DG_LAG_WARN_SECONDS instead of an
# any-nonzero check (WS4.3). See dg_render_common.sh.

# H12: the loudest possible statement that the instance this tool was
# pointed at is not answering. Runs first so it heads the findings list.
assess_local_instance() {
    if $LOCAL_INSTANCE_AVAILABLE; then
        return
    fi
    local detail="${LOCAL_INSTANCE_ERROR:-sqlplus returned no rows from V\$DATABASE}"
    if [[ -n "$TARGET_TNS" ]]; then
        add_summary_error "Target ${TARGET_TNS} answered but is not open or not identifiable: ${detail}"
        return
    fi
    add_summary_error "Local instance ${ORACLE_SID} is DOWN or not open: ${detail}"
    add_summary_info "Check: ps -ef | grep ora_pmon_${ORACLE_SID} ; then 'sqlplus / as sysdba' and STARTUP MOUNT"
}

# A row that should always come back from the local batch but did not means
# the SQL errored (or was cut short): grade it as a warning instead of letting
# the empty field read as "nothing wrong". DBSTATUS/REDOLOG/SRLCOUNT/ARCHGAP/
# UNNAMEDDF are unconditional single-row queries; APPLYINFO is an aggregate
# that always yields exactly one row (standby only matters, but the query runs
# on both roles).
assess_local_sql_rows() {
    $LOCAL_INSTANCE_AVAILABLE || return 0
    local missing="" tag detail
    for tag in DBSTATUS REDOLOG SRLCOUNT ARCHGAP UNNAMEDDF APPLYINFO; do
        printf '%s\n' "$LOCAL_SQL" | grep -q "^${tag}|" || missing="${missing:+$missing, }${tag}"
    done
    [[ -z "$missing" ]] && return 0
    detail=$(printf '%s\n' "$LOCAL_SQL" | grep -E 'ORA-[0-9]|SP2-[0-9]' | head -1 | sed 's/^[[:space:]]*//')
    add_summary_warning "Local SQL result incomplete: no ${missing} row returned${detail:+ (${detail})}; affected checks are UNKNOWN, not OK"
    LOCAL_SQL_INCOMPLETE=true
}

# FSFO fields are parsed before the per-side assessments: flashback is only
# a requirement when FSFO is enabled (reinstating the failed primary needs
# it), so assess_primary/assess_standby consult fsfo_enabled.
parse_fsfo_fields() {
    FSFO_MODE=$(printf '%s\n' "$DGMGRL_FSFO" | grep -i 'Fast-Start Failover:' | head -1 | sed 's/.*: *//' | dg_trim)
    FSFO_TARGET=$(printf '%s\n' "$DGMGRL_FSFO" | grep -i 'Target:' | sed 's/.*: *//' | dg_trim)
    FSFO_OBS=$(printf '%s\n' "$DGMGRL_FSFO" | grep -i 'Observer:' | sed 's/.*: *//' | dg_trim)
    FSFO_THRESHOLD=$(printf '%s\n' "$DGMGRL_FSFO" | grep -i 'Threshold:' | sed 's/.*: *//' | dg_trim)
}

fsfo_enabled() {
    printf '%s' "${FSFO_MODE:-}" | grep -qi "Enabled"
}

# Flashback Database is optional unless FSFO is enabled: YES is a check mark,
# NO is a warning only with FSFO (reinstate needs it), otherwise plain.
flashback_icon() {
    local value="$1"
    if printf '%s' "$value" | grep -qi "YES"; then
        printf '%b' "$CHK"
    elif fsfo_enabled; then
        printf '%b' "$WARN"
    fi
}

# Non-real-time apply (no USING CURRENT LOGFILE / a configured DelayMins) is
# a legitimate choice, so it is informational: plain icon, no warning.
recovery_mode_icon() {
    if printf '%s' "$1" | grep -qi "REAL TIME"; then
        printf '%b' "$CHK"
    fi
}

assess_primary() {
    PRI_OK=unknown

    if [[ -n "${PRI_ROLE:-}" ]]; then
        PRI_OK=true
        printf '%s' "$PRI_ROLE" | grep -qi "PRIMARY" || {
            PRI_OK=false
            add_summary_error "Primary role is ${PRI_ROLE:-unknown}"
        }
    fi

    if [[ -n "${PRI_OPEN:-}" ]]; then
        printf '%s' "$PRI_OPEN" | grep -qi "READ WRITE" || {
            PRI_OK=false
            add_summary_error "Primary open mode is ${PRI_OPEN}"
        }
    fi

    # M12: dg_status.sh has always graded this; the local engine now does too
    # (same accepted values as the dashboard's warn_icon).
    if [[ -n "${PRI_SWITCH:-}" ]] && ! printf '%s' "$PRI_SWITCH" | grep -qiE "TO STANDBY|SESSIONS ACTIVE"; then
        add_summary_warning "Primary switchover status is ${PRI_SWITCH}"
    fi

    if [[ -n "${PRI_FORCE:-}" ]] && ! printf '%s' "$PRI_FORCE" | grep -qi "YES"; then
        dg_check_scope || PRI_OK=false
        add_config_finding error "Primary force logging is ${PRI_FORCE}"
    fi

    if [[ -n "${PRI_FLASH:-}" ]] && ! printf '%s' "$PRI_FLASH" | grep -qi "YES"; then
        if fsfo_enabled; then
            add_config_finding warning "Primary flashback ${PRI_FLASH} (FSFO needs it)"
        else
            add_summary_info "Primary flashback ${PRI_FLASH} (optional without FSFO)"
        fi
    fi

    # L17: this only ever holds a value when we are RUNNING on the primary
    # (dg_broker_start is read from the local V$PARAMETER). The message now
    # names the host it refers to.
    if [[ -n "${PRI_BROKER:-}" ]] && ! printf '%s' "$PRI_BROKER" | grep -qi "TRUE"; then
        PRI_OK=false
        add_summary_error "Primary dg_broker_start is ${PRI_BROKER}"
    fi

    if [[ -n "${PRI_DEST2_STATUS:-}" ]] && [[ "${PRI_DEST2_STATUS}" != "VALID" ]]; then
        PRI_OK=false
        add_summary_error "Archive Dest 2 is ${PRI_DEST2_STATUS} ${PRI_DEST2_ERROR:-}"
    fi

    # Informational only: with more than one standby, dest 2 may legitimately
    # point at another member; the broker grades the real transport state.
    if [[ -n "${PRI_DEST2_DBUNIQ:-}" ]] && [[ -n "${PEER_DBUNIQ:-}" ]] && [[ "${PRI_DEST2_DBUNIQ}" != "${PEER_DBUNIQ}" ]]; then
        add_summary_info "Archive Dest 2 targets ${PRI_DEST2_DBUNIQ}, not ${PEER_DBUNIQ} (ok with several standbys)"
    fi

    if [[ -n "${PRI_ARCHGAP:-}" ]] && [[ "${PRI_ARCHGAP:-0}" -gt 0 ]]; then
        PRI_OK=false
        add_summary_error "Primary reports ${PRI_ARCHGAP} archive gap(s)"
    fi

    if [[ -n "${PRI_UNNAMED:-}" ]] && [[ "${PRI_UNNAMED:-0}" -gt 0 ]]; then
        PRI_OK=false
        add_summary_error "Primary has ${PRI_UNNAMED} UNNAMED datafile(s) (ORA-01274: datafile path not covered by DB_FILE_NAME_CONVERT pairs; repair with ALTER DATABASE CREATE DATAFILE)"
    fi

    if [[ -n "${PRI_SRL:-}" ]] && [[ "${PRI_SRL:-0}" -le 0 ]]; then
        add_config_finding warning "Primary standby redo log count is ${PRI_SRL:-0}"
    fi

    if [[ -n "${PRI_FRA_SIZE:-}" ]]; then
        PRI_FRA_PCT=$(compute_fra_pct "$PRI_FRA_SIZE" "$PRI_FRA_USED" "$PRI_FRA_RECLAIM")
        PRI_FRA_EFFECTIVE_USED=$(compute_fra_effective "$PRI_FRA_USED" "$PRI_FRA_RECLAIM")
        if [[ "$PRI_FRA_PCT" -ge "$DG_FRA_CRIT_PCT" ]]; then
            PRI_OK=false
            add_summary_error "Primary FRA usage is ${PRI_FRA_PCT}%"
        elif [[ "$PRI_FRA_PCT" -ge "$DG_FRA_WARN_PCT" ]]; then
            add_config_finding warning "Primary FRA usage is ${PRI_FRA_PCT}%"
        fi
    else
        PRI_FRA_PCT=0
        PRI_FRA_EFFECTIVE_USED=0.0
    fi
}

assess_standby() {
    STB_OK=unknown
    SEQ_LAG=""
    SEQ_DATA_MISSING=false

    if [[ -n "${STB_ROLE:-}" ]]; then
        STB_OK=true
        printf '%s' "$STB_ROLE" | grep -qi "PHYSICAL STANDBY" || {
            STB_OK=false
            add_summary_error "Standby role is ${STB_ROLE:-unknown}"
        }
    elif [[ "$REMOTE_DATA_SOURCE" == "runtime" ]]; then
        STB_OK=false
        add_summary_error "Standby runtime data is missing"
    fi

    if [[ -n "${STB_OPEN:-}" ]] && ! printf '%s' "$STB_OPEN" | grep -qiE "MOUNTED|READ ONLY"; then
        add_summary_warning "Standby open mode is ${STB_OPEN}"
    fi

    if [[ -n "${STB_MRP_STATUS:-}" ]]; then
        printf '%s' "$STB_MRP_STATUS" | grep -qiE "APPLYING_LOG|WAIT_FOR_LOG" || {
            STB_OK=false
            add_summary_error "Standby MRP status is ${STB_MRP_STATUS}"
        }
    elif [[ -n "${STB_ROLE:-}" ]]; then
        STB_OK=false
        add_summary_error "Standby MRP is not running"
    fi

    if [[ -n "${STB_RECOVERY_MODE:-}" ]] && ! printf '%s' "$STB_RECOVERY_MODE" | grep -qi "REAL TIME"; then
        add_summary_info "Standby apply is not real-time (${STB_RECOVERY_MODE})"
    fi

    if [[ -n "${STB_TRANSPORT_LAG:-}" ]] && (( $(dg_parse_lag_seconds "$STB_TRANSPORT_LAG") > DG_LAG_WARN_SECONDS )); then
        add_summary_warning "Standby transport lag is ${STB_TRANSPORT_LAG}"
    fi

    if [[ -n "${STB_APPLY_LAG:-}" ]] && (( $(dg_parse_lag_seconds "$STB_APPLY_LAG") > DG_LAG_WARN_SECONDS )); then
        add_summary_warning "Standby apply lag is ${STB_APPLY_LAG}"
    fi

    if [[ -n "${STB_ROLE:-}" ]] && { [[ -z "${STB_LAST_APPLIED:-}" ]] || [[ -z "${STB_LAST_RECEIVED:-}" ]]; }; then
        # Missing APPLYINFO must never read as "no sequence lag".
        SEQ_DATA_MISSING=true
        if ! ${LOCAL_SQL_INCOMPLETE:-false}; then
            add_summary_warning "Standby sequence lag unknown: no applied/received sequence data returned"
        fi
    fi

    if [[ -n "${STB_LAST_APPLIED:-}" ]] && [[ -n "${STB_LAST_RECEIVED:-}" ]] && [[ "${STB_LAST_RECEIVED:-0}" -gt 0 ]]; then
        SEQ_LAG=$((STB_LAST_RECEIVED - STB_LAST_APPLIED))
        if (( SEQ_LAG > DG_SEQ_GAP_CRIT )); then
            STB_OK=false
            add_summary_error "Standby sequence lag is ${SEQ_LAG}"
        elif (( SEQ_LAG > DG_SEQ_GAP_WARN )); then
            add_summary_warning "Standby sequence lag is ${SEQ_LAG}"
        fi
    fi

    if [[ -n "${STB_SRL:-}" ]] && [[ "${STB_SRL:-0}" -le 0 ]]; then
        dg_check_scope || STB_OK=false
        add_config_finding error "Standby redo log count is ${STB_SRL:-0}"
    fi

    if [[ -n "${STB_ARCHGAP:-}" ]] && [[ "${STB_ARCHGAP:-0}" -gt 0 ]]; then
        STB_OK=false
        add_summary_error "Standby reports ${STB_ARCHGAP} archive gap(s)"
    fi

    if [[ -n "${STB_UNNAMED:-}" ]] && [[ "${STB_UNNAMED:-0}" -gt 0 ]]; then
        STB_OK=false
        add_summary_error "Standby has ${STB_UNNAMED} UNNAMED datafile(s) (ORA-01274: datafile path not covered by DB_FILE_NAME_CONVERT pairs; repair with ALTER DATABASE CREATE DATAFILE)"
    fi

    if [[ -n "${STB_FLASH:-}" ]] && ! printf '%s' "$STB_FLASH" | grep -qi "YES"; then
        if fsfo_enabled; then
            add_config_finding warning "Standby flashback ${STB_FLASH} (FSFO needs it)"
        else
            add_summary_info "Standby flashback ${STB_FLASH} (optional without FSFO)"
        fi
    fi

    # L17: only populated when we are running ON the standby.
    if [[ -n "${STB_BROKER:-}" ]] && ! printf '%s' "$STB_BROKER" | grep -qi "TRUE"; then
        STB_OK=false
        add_summary_error "Standby dg_broker_start is ${STB_BROKER}"
    fi

    if [[ -n "${STB_FRA_SIZE:-}" ]]; then
        STB_FRA_PCT=$(compute_fra_pct "$STB_FRA_SIZE" "$STB_FRA_USED" "$STB_FRA_RECLAIM")
        STB_FRA_EFFECTIVE_USED=$(compute_fra_effective "$STB_FRA_USED" "$STB_FRA_RECLAIM")
        if [[ "$STB_FRA_PCT" -ge "$DG_FRA_CRIT_PCT" ]]; then
            STB_OK=false
            add_summary_error "Standby FRA usage is ${STB_FRA_PCT}%"
        elif [[ "$STB_FRA_PCT" -ge "$DG_FRA_WARN_PCT" ]]; then
            add_config_finding warning "Standby FRA usage is ${STB_FRA_PCT}%"
        fi
    else
        STB_FRA_PCT=0
        STB_FRA_EFFECTIVE_USED=0.0
    fi
}

assess_broker() {
    BROKER_CONFIGURED=true
    if printf '%s' "$DGMGRL_CONFIG" | grep -qE "ORA-16532|not yet available|not exist"; then
        BROKER_CONFIGURED=false
        add_summary_error "Broker configuration is not configured"
        return
    fi

    if [[ -n "${BROKER_OVERALL:-}" ]]; then
        if [[ "$BROKER_OVERALL" == "ERROR" ]]; then
            add_summary_error "Broker overall status is ERROR"
        elif [[ "$BROKER_OVERALL" == "WARNING" ]]; then
            if dg_check_scope && broker_warnings_all_config; then
                add_summary_info "Not graded (--check): Broker overall status is WARNING (configuration diagnoses only)"
            else
                add_summary_warning "Broker overall status is WARNING"
            fi
        fi
    else
        add_summary_warning "Broker status could not be determined"
    fi

    # M20: 19c prints a member's diagnosis on the line AFTER the member
    # line ("  cdb1 - Primary database" / "    Error: ORA-16810: ..."), so
    # the old member-line grep for Error/Warning could never fire and real
    # member failures never reached the summary or the exit code. Carry the
    # last member name forward and attribute the diagnosis to it.
    local last_member="" diag_sev diag_text
    while IFS= read -r line; do
        line_trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
        if dg_is_broker_member_line "$line"; then
            last_member=$(dg_broker_member_name "$line")
            if printf '%s' "$line_trimmed" | grep -qi "Error"; then
                add_summary_error "Broker member issue: $line_trimmed"
            elif printf '%s' "$line_trimmed" | grep -qi "Warning"; then
                add_summary_warning "Broker member warning: $line_trimmed"
            fi
            continue
        fi
        diag_sev=$(dg_broker_diagnosis_severity "$line_trimmed")
        [[ -z "$diag_sev" ]] && continue
        diag_text=$(dg_broker_diagnosis_text "$line_trimmed")
        if [[ "$diag_sev" == "error" ]]; then
            add_summary_error "Broker member ${last_member:-configuration}: ${diag_text}"
        elif dg_broker_config_diagnosis "$diag_text"; then
            add_config_finding warning "Broker member ${last_member:-configuration}: ${diag_text}"
        else
            add_summary_warning "Broker member ${last_member:-configuration}: ${diag_text}"
        fi
    done <<< "$DGMGRL_CONFIG"

    if [[ -n "${FSFO_MODE:-}" ]]; then
        if fsfo_enabled; then
            # M17: FSFO enabled with no observer connected means automatic
            # failover cannot happen - that is an error, not a warning, and
            # dg_status.sh now grades it identically.
            if [[ -n "${LOC_FSFO_OBSERVER_PRESENT:-}" && "${LOC_FSFO_OBSERVER_PRESENT}" != "YES" ]]; then
                add_summary_error "FSFO is enabled but no observer is present (automatic failover will not happen)"
            elif [[ -z "${LOC_FSFO_OBSERVER_PRESENT:-}" ]]; then
                add_summary_warning "FSFO is enabled but observer presence could not be determined"
            fi
        else
            # FSFO is an optional add-on; a manual-failover configuration
            # is complete without it.
            add_summary_info "Fast-Start Failover disabled (optional)"
        fi
    fi
}

assess_data_source() {
    if [[ "$REMOTE_DATA_SOURCE" == "broker" ]]; then
        # No wallet (or no password) for the peer is the normal default; as
        # long as the broker reports the peer, its role, lag and status are
        # still graded. Only a peer the broker cannot show either is a warning.
        if printf '%s\n' "$DGMGRL_PEER" | grep -q 'Role:'; then
            add_summary_info "Peer seen via broker only (no wallet: use -P or common/setup_dg_wallet.sh)"
        else
            add_summary_warning "Peer unavailable: no runtime SQL and no broker view of ${PEER_DBUNIQ:-the peer}"
        fi
    elif [[ "$REMOTE_DATA_SOURCE" == "local-only" ]]; then
        add_summary_info "Peer runtime skipped by request (-L)"
    fi
}

# DGMGRL prints lags as "0 seconds", "2 minutes 10 seconds (computed 5
# seconds ago)" or "(unknown)". Convert to the "+D HH:MM:SS" form the shared
# lag parser reads; print nothing when the broker has no value.
dg_broker_lag_value() {
    local text="${1:-}" total=0 n unit
    text="${text%%(*}"
    [[ "$text" == *[0-9]* ]] || return 0
    set -- $text
    while [[ $# -ge 2 ]]; do
        n="$1"; unit="$2"; shift 2
        [[ "$n" =~ ^[0-9]+$ ]] || return 0
        case "$unit" in
            day*)    total=$((total + n * 86400)) ;;
            hour*)   total=$((total + n * 3600)) ;;
            minute*) total=$((total + n * 60)) ;;
            second*) total=$((total + n)) ;;
            *) return 0 ;;
        esac
    done
    printf '+%02d %02d:%02d:%02d' $((total / 86400)) $((total % 86400 / 3600)) $((total % 3600 / 60)) $((total % 60))
}

# Display text for a lag that may be absent: "n/a" instead of feeding an
# empty/non-lag value into the parser.
lag_or_na() {
    if [[ -n "${1:-}" ]]; then
        dg_display_lag_value "$1"
    else
        printf 'n/a'
    fi
}

# State of the peer when no runtime SQL reached it: graded from the
# broker's SHOW DATABASE status (SUCCESS -> OK) instead of a red CHECK.
# The broker's "Database Status:" value for the peer: SUCCESS/WARNING/ERROR,
# or ERROR when the section holds only a DGM-/ORA- line (e.g. DGM-17016
# "failed to retrieve status" + ORA-16664 - the broker could not even reach
# the member), nothing when there is no such section.
peer_broker_status() {
    local section st
    section=$(printf '%s\n' "$DGMGRL_PEER" | sed -n '/Database Status:/,$p')
    [[ -z "$section" ]] && section=$(printf '%s\n' "$DGMGRL_PEER" | tail -3)
    st=$(printf '%s\n' "$section" | extract_first_status)
    if [[ -z "$st" ]] && printf '%s' "$section" | grep -qE 'ORA-[0-9]|DGM-[0-9]'; then
        st="ERROR"
    fi
    printf '%s' "$st"
}

peer_broker_state() {
    local st
    st=$(peer_broker_status)
    case "$st" in
        SUCCESS) printf '%b' "${GREEN}OK (broker)${NC}" ;;
        WARNING) printf '%b' "${YELLOW}WARNING (broker)${NC}" ;;
        ERROR)   printf '%b' "${RED}ERROR (broker)${NC}" ;;
        *)       printf '%b' "${YELLOW}UNKNOWN${NC}" ;;
    esac
}

compute_state_labels() {
    # M12: the replication state is derived first because "no lag data"
    # raises a warning, and OVERALL_STATE / the headline counts below must
    # agree with it. The derivation itself is the shared dg_repl_state.
    REPL_STATE_TOKEN=""
    BROKER_TLAG=""
    BROKER_ALAG=""
    if ! $LOCAL_INSTANCE_AVAILABLE; then
        REPL_STATE="${RED}UNKNOWN${NC}"
    elif $IS_PRIMARY && [[ "$REMOTE_DATA_SOURCE" != "runtime" ]]; then
        # No runtime SQL on the standby: the broker's SHOW DATABASE lags are
        # still authoritative (computed by the standby itself), so grade them
        # instead of printing the data source in the state column.
        BROKER_TLAG=$(dg_broker_lag_value "$(printf '%s\n' "$DGMGRL_PEER" | grep 'Transport Lag:' | sed 's/.*Transport Lag: *//')")
        BROKER_ALAG=$(dg_broker_lag_value "$(printf '%s\n' "$DGMGRL_PEER" | grep 'Apply Lag:' | sed 's/.*Apply Lag: *//')")
        if [[ -n "$BROKER_TLAG" || -n "$BROKER_ALAG" ]]; then
            REPL_STATE_TOKEN=$(dg_repl_state "$BROKER_TLAG" "$BROKER_ALAG" "")
            REPL_STATE="$(dg_repl_state_text "$REPL_STATE_TOKEN") ${DIM}(broker)${NC}"
        else
            REPL_STATE="PEER_SOURCE"
        fi
    else
        REPL_DOWNGRADED=false
        REPL_STATE_TOKEN=$(dg_repl_state "${STB_TRANSPORT_LAG:-}" "${STB_APPLY_LAG:-}" "${SEQ_LAG:-}")
        # Lag rows alone cannot prove IN SYNC when the sequence row is gone.
        if ${SEQ_DATA_MISSING:-false} && [[ "$REPL_STATE_TOKEN" == "IN_SYNC" ]]; then
            REPL_STATE_TOKEN="UNKNOWN"
            REPL_DOWNGRADED=true
        fi
        REPL_STATE=$(dg_repl_state_text "$REPL_STATE_TOKEN")
        if [[ "$REPL_STATE_TOKEN" == "UNKNOWN" ]] && ! $REPL_DOWNGRADED; then
            add_summary_warning "Replication state unknown: no transport lag, apply lag or sequence data returned for the standby"
        fi
    fi

    # H12
    if $LOCAL_INSTANCE_AVAILABLE; then
        LOCAL_INSTANCE_STATE="${GREEN}UP${NC}"
    else
        LOCAL_INSTANCE_STATE="${RED}DOWN${NC}"
    fi

    if [[ $ERRORS -gt 0 ]]; then
        OVERALL_STATE="${RED}CRITICAL${NC}"
    elif [[ $WARNINGS -gt 0 ]]; then
        OVERALL_STATE="${YELLOW}ATTENTION${NC}"
    else
        OVERALL_STATE="${GREEN}HEALTHY${NC}"
    fi

    if [[ "$PRI_OK" == true ]]; then
        PRIMARY_STATE="${GREEN}OK${NC}"
    elif [[ -n "${PRI_ROLE:-}" ]]; then
        PRIMARY_STATE="${RED}CHECK${NC}"
    elif ! $IS_PRIMARY; then
        PRIMARY_STATE=$(peer_broker_state)
    else
        PRIMARY_STATE="${YELLOW}UNKNOWN${NC}"
    fi

    if [[ "$STB_OK" == true ]]; then
        STANDBY_STATE="${GREEN}OK${NC}"
    elif [[ -n "${STB_ROLE:-}" ]]; then
        STANDBY_STATE="${RED}CHECK${NC}"
    elif $IS_PRIMARY; then
        STANDBY_STATE=$(peer_broker_state)
    else
        STANDBY_STATE="${YELLOW}UNKNOWN${NC}"
    fi

    if [[ "$BROKER_CONFIGURED" != true ]]; then
        BROKER_STATE="${RED}NOT CONFIGURED${NC}"
    elif [[ "${BROKER_OVERALL:-}" == "SUCCESS" ]]; then
        BROKER_STATE="${GREEN}SUCCESS${NC}"
    elif [[ "${BROKER_OVERALL:-}" == "WARNING" ]]; then
        BROKER_STATE="${YELLOW}WARNING${NC}"
    elif [[ -n "${BROKER_OVERALL:-}" ]]; then
        # M12: ERROR is red here exactly as in dg_status.sh.
        BROKER_STATE="${RED}${BROKER_OVERALL}${NC}"
    else
        BROKER_STATE="${YELLOW}UNKNOWN${NC}"
    fi

    if [[ "$REMOTE_DATA_SOURCE" == "broker" ]]; then
        PEER_SOURCE_STATE="${CYAN}BROKER ONLY${NC}"
    elif [[ "$REMOTE_DATA_SOURCE" == "local-only" ]]; then
        PEER_SOURCE_STATE="${CYAN}LOCAL ONLY${NC}"
    else
        PEER_SOURCE_STATE="${GREEN}RUNTIME SQL${NC}"
    fi

    # Placeholder resolved now that PEER_SOURCE_STATE exists.
    [[ "$REPL_STATE" == "PEER_SOURCE" ]] && REPL_STATE="$PEER_SOURCE_STATE"
}

# -- Components: every broker member and every observer ----------------------
# CHK_MEMBER_*: one entry per member line of SHOW CONFIGURATION (kind =
# primary|standby|other, the per-member SHOW DATABASE for standbys).
# CHK_OBS_*: one entry per observer block of SHOW OBSERVER.
CHK_MEMBER_NAME=(); CHK_MEMBER_KIND=(); CHK_MEMBER_DISABLED=(); CHK_MEMBER_SHOW=(); CHK_MEMBER_STATUS=()
CHK_OBS_NAME=(); CHK_OBS_ROLE=(); CHK_OBS_HOST=(); CHK_OBS_PPRI=(); CHK_OBS_PTGT=()
DGMGRL_OBSERVER=""

collect_components() {
    local line name type n show
    CHK_MEMBER_NAME=(); CHK_MEMBER_KIND=(); CHK_MEMBER_DISABLED=(); CHK_MEMBER_SHOW=(); CHK_MEMBER_STATUS=()
    CHK_OBS_NAME=(); CHK_OBS_ROLE=(); CHK_OBS_HOST=(); CHK_OBS_PPRI=(); CHK_OBS_PTGT=()
    DGMGRL_OBSERVER=""
    # Without dgmgrl (network mode, V$DG_BROKER_CONFIG) there is no SHOW
    # DATABASE / SHOW OBSERVER: the peer view and V$DATABASE stay the source.
    if [[ -n "$TARGET_TNS" ]] && ! $DGMGRL_AVAILABLE; then
        return
    fi
    $LOCAL_INSTANCE_AVAILABLE || return
    while IFS= read -r line; do
        dg_is_broker_member_line "$line" || continue
        name=$(dg_broker_member_name "$line")
        type=$(printf '%s' "$line" | sed 's/^[[:space:]]*[^[:space:]]*[[:space:]]*-[[:space:]]*//')
        n=${#CHK_MEMBER_NAME[@]}
        CHK_MEMBER_NAME[n]="$name"
        case "$type" in
            *[Pp]rimary\ database*) CHK_MEMBER_KIND[n]="primary" ;;
            *[Ss]tandby\ database*) CHK_MEMBER_KIND[n]="standby" ;;
            *) CHK_MEMBER_KIND[n]="other" ;;
        esac
        case "$type" in *disabled*) CHK_MEMBER_DISABLED[n]=true ;; *) CHK_MEMBER_DISABLED[n]=false ;; esac
        show=""
        if [[ "${CHK_MEMBER_KIND[$n]}" == "standby" && "${CHK_MEMBER_DISABLED[$n]}" == false ]]; then
            if [[ "$name" == "${PEER_DBUNIQ:-}" && -n "${DGMGRL_PEER:-}" ]]; then
                show="$DGMGRL_PEER"
            else
                show=$(run_dgmgrl "SHOW DATABASE '${name}'")
            fi
        fi
        CHK_MEMBER_SHOW[n]="$show"
        CHK_MEMBER_STATUS[n]=$(printf '%s\n' "$show" | sed -n '/Database Status:/,$p' | extract_first_status)
    done <<< "$DGMGRL_CONFIG"

    printf '%s\n' "$DGMGRL_FSFO" | grep -qi 'Fast-Start Failover:.*Enabled' || return
    DGMGRL_OBSERVER=$(run_dgmgrl 'SHOW OBSERVER')
    parse_observers
}

# SHOW OBSERVER (19c):
#   Observer "dg_observer" - Master
#   Observer "dg_observer"(19.3.0.0.0) - Master
#     Host Name:                    ol9-19-dg3.localdomain
#     Last Ping to Primary:         2 seconds ago
#     Last Ping to Target:          2 seconds ago
parse_observers() {
    local line t n=-1
    while IFS= read -r line; do
        t=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        case "$t" in
            Observer\ \"*)
                n=${#CHK_OBS_NAME[@]}
                CHK_OBS_NAME[n]=$(printf '%s' "$t" | sed 's/^Observer "\([^"]*\)".*/\1/')
                # Some clients include a parenthesized version after the
                # name. Strip it before reading the role, otherwise a live
                # Master has an empty role and is reported as missing.
                CHK_OBS_ROLE[n]=$(printf '%s' "$t" | sed -n '
                    s/^Observer "[^"]*"[[:space:]]*//
                    s/^([^)]*)[[:space:]]*//
                    s/^-[[:space:]]*//p
                ')
                CHK_OBS_HOST[n]=""; CHK_OBS_PPRI[n]=""; CHK_OBS_PTGT[n]=""
                ;;
            "Host Name:"*)            [[ $n -ge 0 ]] && CHK_OBS_HOST[n]=$(printf '%s' "$t" | sed 's/^Host Name:[[:space:]]*//') ;;
            "Last Ping to Primary:"*) [[ $n -ge 0 ]] && CHK_OBS_PPRI[n]=$(printf '%s' "$t" | sed 's/^Last Ping to Primary:[[:space:]]*//') ;;
            "Last Ping to Target:"*)  [[ $n -ge 0 ]] && CHK_OBS_PTGT[n]=$(printf '%s' "$t" | sed 's/^Last Ping to Target:[[:space:]]*//') ;;
        esac
    done <<< "$DGMGRL_OBSERVER"
}

# Seconds since an observer's last ping ("2 seconds ago", "1 minute 5
# seconds ago"); nothing for "(unknown)" or an empty value.
observer_ping_age() {
    local v
    v=$(dg_broker_lag_value "${1:-}")
    [[ -n "$v" ]] && dg_parse_lag_seconds "$v"
}

# A ping is fresh when it is known and not older than the FSFO threshold
# (DG_OBSERVER_PING_MAX overrides; 30 s when the threshold is unknown):
# past the threshold the observer has lost that database.
observer_ping_max() {
    local t
    t=$(printf '%s' "${FSFO_THRESHOLD:-}" | sed 's/[^0-9].*//')
    printf '%s' "${DG_OBSERVER_PING_MAX:-${t:-30}}"
}

observer_ping_ok() {
    local age
    age=$(observer_ping_age "${1:-}")
    [[ -n "$age" ]] && (( age <= $(observer_ping_max) ))
}

# OK when observer $1 pings both databases in time; a stale Master is a
# failure (no automatic failover), a stale Backup only a warning.
observer_icon() {
    if observer_ping_ok "${CHK_OBS_PPRI[$1]}" && observer_ping_ok "${CHK_OBS_PTGT[$1]}"; then
        printf '%b' "$CHK"
    elif [[ "${CHK_OBS_ROLE[$1]}" == "Master" ]]; then
        printf '%b' "$FAIL"
    else
        printf '%b' "$WARN"
    fi
}

check_lag_over() {
    [[ -n "${1:-}" ]] && (( $(dg_parse_lag_seconds "$1") > DG_LAG_WARN_SECONDS ))
}

# V$DATABASE.FS_FAILOVER_STATUS with FSFO enabled: ok | warning | error.
fsfo_status_grade() {
    case "$(printf '%s' "${1:-}" | tr 'a-z' 'A-Z')" in
        SYNCHRONIZED|"TARGET UNDER LAG LIMIT"|BYSTANDER) printf 'ok' ;;
        SUSPENDED|"LOADING DICTIONARY") printf 'warning' ;;
        "") printf 'warning' ;;
        UNSYNCHRONIZED|STALLED|"PRIMARY UNOBSERVED"|"TARGET OVER LAG LIMIT"|REINSTATE*|DISABLED) printf 'error' ;;
        *) printf 'warning' ;;
    esac
}

assess_components() {
    local i name tlag alag sev role age what
    i=0
    while [[ $i -lt ${#CHK_MEMBER_NAME[@]} ]]; do
        name="${CHK_MEMBER_NAME[$i]}"
        # The local standby is graded from its own V$ views (assess_standby);
        # member diagnoses already come from SHOW CONFIGURATION (assess_broker).
        if [[ "${CHK_MEMBER_KIND[$i]}" == "standby" && "${CHK_MEMBER_DISABLED[$i]}" == false && "$name" != "${LOC_DBUNIQ:-}" ]]; then
            tlag=$(printf '%s\n' "${CHK_MEMBER_SHOW[$i]}" | grep 'Transport Lag:' | sed 's/.*Transport Lag: *//' | dg_trim)
            alag=$(printf '%s\n' "${CHK_MEMBER_SHOW[$i]}" | grep 'Apply Lag:' | sed 's/.*Apply Lag: *//' | dg_trim)
            if [[ -z "${CHK_MEMBER_SHOW[$i]}" ]] || ! printf '%s\n' "${CHK_MEMBER_SHOW[$i]}" | grep -q 'Role:'; then
                add_summary_warning "Standby ${name}: no broker view (SHOW DATABASE returned nothing usable)"
            else
                if [[ -z "$(dg_broker_lag_value "$tlag")" ]]; then
                    add_summary_warning "Standby ${name}: transport lag unknown (${tlag:-no value})"
                elif check_lag_over "$(dg_broker_lag_value "$tlag")"; then
                    add_summary_warning "Standby ${name}: transport lag ${tlag%%(*}"
                fi
                if [[ -z "$(dg_broker_lag_value "$alag")" ]]; then
                    add_summary_warning "Standby ${name}: apply lag unknown (${alag:-no value})"
                elif check_lag_over "$(dg_broker_lag_value "$alag")"; then
                    add_summary_warning "Standby ${name}: apply lag ${alag%%(*}"
                fi
            fi
        fi
        i=$((i + 1))
    done

    fsfo_enabled || return 0
    sev=$(fsfo_status_grade "${LOC_FSFO_STATUS:-}")
    if [[ "$sev" == "error" ]]; then
        add_summary_error "FSFO status on ${LOC_DBUNIQ:-this database} is ${LOC_FSFO_STATUS} (automatic failover is not ready)"
    elif [[ "$sev" == "warning" ]]; then
        add_summary_warning "FSFO status on ${LOC_DBUNIQ:-this database} is ${LOC_FSFO_STATUS:-unknown}"
    fi

    # SHOW OBSERVER unavailable (no dgmgrl): V$DATABASE observer presence,
    # graded in assess_broker, is all there is.
    [[ -n "$TARGET_TNS" ]] && ! $DGMGRL_AVAILABLE && return 0
    if [[ ${#CHK_OBS_NAME[@]} -eq 0 ]]; then
        add_summary_error "FSFO is enabled but the broker lists no observer"
        return 0
    fi
    local master_seen=false
    i=0
    while [[ $i -lt ${#CHK_OBS_NAME[@]} ]]; do
        role="${CHK_OBS_ROLE[$i]:-?}"
        [[ "$role" == "Master" ]] && master_seen=true
        for what in Primary Target; do
            if [[ "$what" == Primary ]]; then age="${CHK_OBS_PPRI[$i]}"; else age="${CHK_OBS_PTGT[$i]}"; fi
            observer_ping_ok "$age" && continue
            if [[ "$role" == "Master" ]]; then
                add_summary_error "Observer ${CHK_OBS_NAME[$i]} (Master): last ping to the $(printf '%s' "$what" | tr 'A-Z' 'a-z') ${age:-unknown} (limit $(observer_ping_max)s)"
            else
                add_summary_warning "Observer ${CHK_OBS_NAME[$i]} (${role}): last ping to the $(printf '%s' "$what" | tr 'A-Z' 'a-z') ${age:-unknown} (limit $(observer_ping_max)s)"
            fi
        done
        i=$((i + 1))
    done
    $master_seen || add_summary_error "FSFO is enabled but no Master observer is registered"
}

assess_all() {
    SUMMARY_ERRORS=()
    SUMMARY_WARNINGS=()
    SUMMARY_INFOS=("${COLLECT_INFOS[@]+"${COLLECT_INFOS[@]}"}")
    ERRORS=0
    WARNINGS=0
    LOCAL_SQL_INCOMPLETE=false

    parse_fsfo_fields
    assess_local_instance
    assess_local_sql_rows
    assess_primary
    assess_standby
    assess_broker
    assess_components
    assess_data_source
    compute_state_labels
}

print_title() {
    local title="$1"
    printf "\n ${BOLD}${CYAN}%s${NC}  ${DIM}%s${NC}\n" "$title" "$(date '+%Y-%m-%d %H:%M:%S')"
    if [[ -n "$TARGET_TNS" ]]; then
        printf " ${DIM}Target: %s via %s -> %s (instance: %s, role: %s)  |  Peer: %s  |  Source: %s${NC}\n" \
            "${TARGET_TNS}" "${TARGET_AUTH_METHOD}" "${LOC_HOST:-?}" "${LOC_INSTANCE:-?}" "${LOC_LABEL}" "${PEER_DBUNIQ:-unknown}" "${REMOTE_DATA_SOURCE_LABEL}"
    else
        printf " ${DIM}Local: %s (SID: %s, role: %s)  |  Peer: %s  |  Source: %s${NC}\n" \
            "$(short_hostname)" "${ORACLE_SID}" "${LOC_LABEL}" "${PEER_DBUNIQ:-unknown}" "${REMOTE_DATA_SOURCE_LABEL}"
    fi
}

# L18: SUMMARY_INFOS was populated (that's where the "-L skipped the peer"
# explanation lives) but never rendered, so a `-L` run showed a red CHECK
# with nothing explaining it. Printed dimmed, below errors/warnings, and
# NOT subject to the top-findings cutoff - an info line that explains the
# state is useless if it is the one that gets truncated away.
print_summary_infos() {
    local item
    [[ ${#SUMMARY_INFOS[@]} -eq 0 ]] && return
    for item in "${SUMMARY_INFOS[@]}"; do
        row "Info" "$item" "${DIM}--${NC}"
    done
}

print_top_findings() {
    local limit=5 count=0 item
    header "TOP FINDINGS"
    if [[ ${#SUMMARY_ERRORS[@]} -eq 0 && ${#SUMMARY_WARNINGS[@]} -eq 0 ]]; then
        row "Status" "No findings" "$CHK"
        print_summary_infos
        return
    fi

    if [[ ${#SUMMARY_ERRORS[@]} -gt 0 ]]; then
        for item in "${SUMMARY_ERRORS[@]}"; do
            row "Error" "$item" "$FAIL"
            count=$((count + 1))
            if (( count >= limit )); then
                print_summary_infos
                return
            fi
        done
    fi
    if [[ ${#SUMMARY_WARNINGS[@]} -gt 0 ]]; then
        for item in "${SUMMARY_WARNINGS[@]}"; do
            row "Warning" "$item" "$WARN"
            count=$((count + 1))
            if (( count >= limit )); then
                print_summary_infos
                return
            fi
        done
    fi
    print_summary_infos
}

render_primary_triage() {
    header "PRIMARY"
    if [[ -n "${PRI_ROLE:-}" ]]; then
        row "Role" "${PRI_ROLE:-?}" "$(status_icon "${PRI_ROLE:-}" "PRIMARY")"
        row "Open Mode" "${PRI_OPEN:-?}" "$(status_icon "${PRI_OPEN:-}" "READ WRITE")"
        row "Switchover" "${PRI_SWITCH:-?}" "$(warn_icon "${PRI_SWITCH:-}" "TO STANDBY" "SESSIONS ACTIVE")"
        row "Force Logging" "${PRI_FORCE:-?}" "$(status_icon "${PRI_FORCE:-}" "YES")"
        row "Flashback" "${PRI_FLASH:-?}" "$(flashback_icon "${PRI_FLASH:-}")"
        # L17: dg_broker_start comes from the LOCAL V$PARAMETER only, so the
        # row is shown only when we run on the primary (diag spells out why).
        [[ -n "${PRI_BROKER:-}" ]] && row "DG Broker" "${PRI_BROKER}" "$(status_icon "${PRI_BROKER}" "TRUE")"
        if [[ -n "${PRI_DEST2_STATUS:-}" ]]; then
            if [[ "${PRI_DEST2_STATUS}" == "VALID" ]]; then
                row "Archive Dest 2" "${PRI_DEST2_STATUS}" "$CHK"
            else
                row "Archive Dest 2" "${PRI_DEST2_STATUS} ${PRI_DEST2_ERROR:-}" "$FAIL"
            fi
        fi
        if [[ -n "${PRI_DEST2_DBUNIQ:-}" ]]; then
            if [[ -n "${PEER_DBUNIQ:-}" && "${PRI_DEST2_DBUNIQ}" != "${PEER_DBUNIQ}" ]]; then
                row "Dest 2 Target" "${PRI_DEST2_DBUNIQ} (peer here is ${PEER_DBUNIQ})"
            else
                row "Dest 2 Target" "${PRI_DEST2_DBUNIQ}" "$CHK"
            fi
        fi
        row "Redo Logs" "${PRI_REDO_CNT:-?} groups (${PRI_REDO_MB:-?} MB total)"
        if [[ -n "${PRI_SRL:-}" ]] && [[ "${PRI_SRL:-0}" -gt 0 ]]; then
            row "Standby Redo" "${PRI_SRL} groups" "$CHK"
        else
            row "Standby Redo" "${PRI_SRL:-0} groups" "$WARN"
        fi
        if [[ -n "${PRI_FRA_PATH:-}" ]]; then
            row "FRA Usage" "${PRI_FRA_EFFECTIVE_USED}/${PRI_FRA_SIZE} GB effective (${PRI_FRA_PCT}%)" "$(dg_fra_icon "${PRI_FRA_PCT:-0}")"
        fi
    else
        row "Peer View" "from broker (no runtime SQL)"
        render_peer_broker_view "PRIMARY"
    fi
}

render_standby_triage() {
    header "STANDBY"
    if [[ -n "${STB_ROLE:-}" ]]; then
        row "Role" "${STB_ROLE:-?}" "$(status_icon "${STB_ROLE:-}" "PHYSICAL STANDBY")"
        row "Open Mode" "${STB_OPEN:-?}" "$(warn_icon "${STB_OPEN:-}" "MOUNTED" "READ ONLY")"
        row "Switchover" "${STB_SWITCH:-?}" "$(warn_icon "${STB_SWITCH:-}" "NOT ALLOWED" "SWITCHOVER PENDING")"
        # L17: populated only when this tool runs ON the standby.
        [[ -n "${STB_BROKER:-}" ]] && row "DG Broker" "${STB_BROKER}" "$(status_icon "${STB_BROKER}" "TRUE")"
        if [[ -n "${STB_MRP_STATUS:-}" ]]; then
            row "MRP Status" "${STB_MRP_STATUS} (seq# ${STB_MRP_SEQ:-?})" "$(status_icon "${STB_MRP_STATUS:-}" "APPLYING_LOG" "WAIT_FOR_LOG")"
        else
            row "MRP Status" "NOT RUNNING" "$FAIL"
        fi
        if [[ -n "${STB_RECOVERY_MODE:-}" ]]; then
            row "Recovery Mode" "${STB_RECOVERY_MODE}" "$(recovery_mode_icon "${STB_RECOVERY_MODE:-}")"
        fi

        if [[ -n "${STB_TRANSPORT_LAG:-}" ]]; then
            row "Transport Lag" "$(dg_display_lag_value "$STB_TRANSPORT_LAG")" "$(dg_lag_icon "$STB_TRANSPORT_LAG")"
        fi
        if [[ -n "${STB_APPLY_LAG:-}" ]]; then
            row "Apply Lag" "$(dg_display_lag_value "$STB_APPLY_LAG")" "$(dg_lag_icon "$STB_APPLY_LAG")"
            if [[ -n "${STB_APPLY_FINISH:-}" ]] && (( $(dg_parse_lag_seconds "$STB_APPLY_LAG") > DG_LAG_WARN_SECONDS )); then
                row "Apply Finish ETA" "${STB_APPLY_FINISH}"
            fi
        fi
        if [[ -n "${STB_LAST_APPLIED:-}" ]] && [[ -n "${STB_LAST_RECEIVED:-}" ]] && [[ "${STB_LAST_RECEIVED:-0}" -gt 0 ]]; then
            if [[ -n "${SEQ_LAG:-}" ]] && (( SEQ_LAG > DG_SEQ_GAP_WARN )); then
                row "Sequences" "applied=${STB_LAST_APPLIED} received=${STB_LAST_RECEIVED} (lag ${SEQ_LAG})" "$(dg_seq_gap_icon "${SEQ_LAG:-0}")"
            else
                row "Sequences" "applied=${STB_LAST_APPLIED} received=${STB_LAST_RECEIVED}" "$(dg_seq_gap_icon "${SEQ_LAG:-0}")"
            fi
        fi
        if ${SEQ_DATA_MISSING:-false}; then
            row "Sequences" "no applied/received data returned" "$WARN"
        fi
        if [[ -n "${STB_SRL:-}" ]] && [[ "${STB_SRL:-0}" -gt 0 ]]; then
            row "Standby Redo" "${STB_SRL} groups" "$CHK"
        else
            row "Standby Redo" "${STB_SRL:-0} groups" "$FAIL"
        fi
        if [[ -n "${STB_ARCHGAP:-}" ]] && [[ "${STB_ARCHGAP:-0}" -gt 0 ]]; then
            row "Archive Gaps" "${STB_ARCHGAP} gap(s)" "$FAIL"
        fi
        if [[ -n "${STB_UNNAMED:-}" ]] && [[ "${STB_UNNAMED:-0}" -gt 0 ]]; then
            row "UNNAMED Datafiles" "${STB_UNNAMED} UNNAMED datafile(s)" "$FAIL"
        fi
        if [[ -n "${STB_FRA_PATH:-}" ]]; then
            row "FRA Usage" "${STB_FRA_EFFECTIVE_USED}/${STB_FRA_SIZE} GB effective (${STB_FRA_PCT}%)" "$(dg_fra_icon "${STB_FRA_PCT:-0}")"
        fi
    else
        row "Peer View" "from broker (no runtime SQL)"
        render_peer_broker_view "STANDBY"
    fi
}

render_peer_broker_view() {
    local expected="$1"
    local peer_role peer_state peer_tlag peer_alag peer_db_status
    peer_role=$(printf '%s\n' "$DGMGRL_PEER" | grep 'Role:' | sed 's/.*Role: *//' | dg_trim)
    peer_state=$(printf '%s\n' "$DGMGRL_PEER" | grep 'Intended State:' | sed 's/.*Intended State: *//' | dg_trim)
    peer_tlag=$(printf '%s\n' "$DGMGRL_PEER" | grep 'Transport Lag:' | sed 's/.*Transport Lag: *//' | dg_trim)
    peer_alag=$(printf '%s\n' "$DGMGRL_PEER" | grep 'Apply Lag:' | sed 's/.*Apply Lag: *//' | dg_trim)
    peer_db_status=$(peer_broker_status)

    if [[ -n "$peer_role" ]]; then
        if [[ "$expected" == "PRIMARY" ]]; then
            row "Role" "$peer_role" "$(status_icon "$peer_role" "PRIMARY")"
        else
            row "Role" "$peer_role" "$(status_icon "$peer_role" "PHYSICAL STANDBY" "PRIMARY")"
        fi
    fi
    [[ -n "$peer_state" ]] && row "Intended State" "$peer_state"
    [[ -n "$peer_tlag" ]] && row "Transport Lag" "$peer_tlag"
    [[ -n "$peer_alag" ]] && row "Apply Lag" "$peer_alag"
    [[ -n "$peer_db_status" ]] && row "Broker Status" "$peer_db_status" "$(status_icon "$peer_db_status" "SUCCESS")"
}

render_broker_triage() {
    header "BROKER / FSFO"
    if [[ "$BROKER_CONFIGURED" != true ]]; then
        row "Configuration" "NOT CONFIGURED" "$FAIL"
        return
    fi

    row "Configuration" "${BROKER_CFG_NAME:-unknown}"
    [[ -n "${BROKER_OVERALL:-}" ]] && row "Overall Status" "${BROKER_OVERALL}" "$(dg_broker_overall_icon "${BROKER_OVERALL:-}")"

    if [[ -n "${FSFO_MODE:-}" ]]; then
        if fsfo_enabled; then
            row "Fast-Start Failover" "$FSFO_MODE" "$CHK"
        else
            row "Fast-Start Failover" "$FSFO_MODE (optional)"
        fi
    fi
    [[ -n "${FSFO_TARGET:-}" && "${FSFO_TARGET}" != "(none)" ]] && row "Target" "${FSFO_TARGET}"
    if [[ -n "${LOC_FSFO_OBSERVER_PRESENT:-}" ]]; then
        if [[ "${LOC_FSFO_OBSERVER_PRESENT}" == "YES" ]]; then
            row "Observer Present" "YES" "$CHK"
        else
            # M17: red only when FSFO is actually enabled - with FSFO
            # disabled, "no observer" is the expected state.
            row "Observer Present" "${LOC_FSFO_OBSERVER_PRESENT}" "$(fsfo_observer_icon)"
        fi
    fi
    [[ -n "${LOC_FSFO_OBSERVER_HOST:-}" ]] && row "Observer Host" "${LOC_FSFO_OBSERVER_HOST}"
    render_observer_ping_rows
}

# One row per observer from SHOW OBSERVER: is it still reaching both the
# primary and the FSFO target?
render_observer_ping_rows() {
    local i st
    i=0
    while [[ $i -lt ${#CHK_OBS_NAME[@]} ]]; do
        st=$(observer_icon "$i")
        row "Observer Pings" "${CHK_OBS_NAME[$i]} (${CHK_OBS_ROLE[$i]:-?}): primary ${CHK_OBS_PPRI[$i]:-unknown}, target ${CHK_OBS_PTGT[$i]:-unknown}" "$st"
        i=$((i + 1))
    done
}

# Severity icon for a missing observer: an error while FSFO is enabled
# (automatic failover cannot happen), otherwise none - no observer is the
# expected state of a configuration without FSFO.
fsfo_observer_icon() {
    if fsfo_enabled; then
        printf '%b' "$FAIL"
    fi
}

render_recent_events_triage() {
    header "RECENT DG EVENTS"
    print_event_block "Recent Alert Events" "$LOC_ALERT_MATCHES" "${LOC_ALERT_MATCH_COUNT:-0}" 3 "${LOC_ALERT_FILE}" "$LOC_ALERT_FILE_FOUND"
    printf "\n"
    print_event_block "Recent Broker Events" "$LOC_DRC_MATCHES" "${LOC_DRC_MATCH_COUNT:-0}" 3 "${LOC_DRC_FILE}" "$LOC_DRC_FILE_FOUND"
}

render_triage_output() {
    local pri_summary_mode stb_summary_mode
    if [[ -n "${PRI_OPEN:-}" ]]; then
        pri_summary_mode="$PRI_OPEN"
    else
        pri_summary_mode="broker view"
    fi
    if [[ -n "${STB_MRP_STATUS:-}" ]]; then
        stb_summary_mode="MRP ${STB_MRP_STATUS}"
    else
        stb_summary_mode="broker view"
    fi

    print_title "Data Guard Triage"
    print_top_findings

    header "AT A GLANCE"
    row "Overall" "errors=${ERRORS} warnings=${WARNINGS}" "$OVERALL_STATE"
    if ! $LOCAL_INSTANCE_AVAILABLE; then
        row "Local Instance" "${TARGET_TNS:-$ORACLE_SID} - ${LOCAL_INSTANCE_ERROR:-no response from V\$DATABASE}" "$LOCAL_INSTANCE_STATE"
    fi
    row "Primary" "${PRI_DBUNIQ:-?} / ${pri_summary_mode}" "$PRIMARY_STATE"
    row "Standby" "${STB_DBUNIQ:-?} / ${stb_summary_mode}" "$STANDBY_STATE"
    row "Broker" "${BROKER_CFG_NAME:-not configured}" "$BROKER_STATE"
    row "Redo Apply" "transport=$(lag_or_na "${STB_TRANSPORT_LAG:-${BROKER_TLAG:-}}"), apply=$(lag_or_na "${STB_APPLY_LAG:-${BROKER_ALAG:-}}")" "$REPL_STATE"
    # The peer data source is already in the title line ("Source:"), and the
    # verdict is the Overall row above - no second copy of either at the end.

    render_primary_triage
    render_standby_triage
    render_broker_triage
    render_recent_events_triage
    printf "\n"
}

render_primary_diag() {
    header "PRIMARY DATABASE  (${PRI_DBUNIQ:-?})"
    if [[ -n "${PRI_ROLE:-}" ]]; then
        subheader "Identity"
        row "Role" "$PRI_ROLE" "$(status_icon "$PRI_ROLE" "PRIMARY")"
        row "Open Mode" "$PRI_OPEN" "$(status_icon "$PRI_OPEN" "READ WRITE")"
        row "Protection Mode" "$PRI_PROTECT"
        row "Switchover Status" "$PRI_SWITCH" "$(warn_icon "$PRI_SWITCH" "TO STANDBY" "SESSIONS ACTIVE")"
        row "Force Logging" "$PRI_FORCE" "$(status_icon "$PRI_FORCE" "YES")"
        row "Flashback" "$PRI_FLASH" "$(flashback_icon "$PRI_FLASH")"

        subheader "Services"
        # L17: see render_primary_triage.
        if [[ -n "${PRI_BROKER:-}" ]]; then
            row "DG Broker" "${PRI_BROKER}" "$(status_icon "${PRI_BROKER}" "TRUE")"
        else
            row "DG Broker" "unknown (dg_broker_start is only readable on the local instance)"
        fi
        row "Running Services" "${PRI_SERVICES:-NONE}"

        subheader "Redo / Archive"
        row "Online Redo Logs" "${PRI_REDO_CNT:-?} groups (${PRI_REDO_MB:-?} MB total)"
        if [[ -n "${PRI_SRL:-}" ]] && [[ "${PRI_SRL:-0}" -gt 0 ]]; then
            row "Standby Redo Logs" "${PRI_SRL} groups" "$CHK"
        else
            row "Standby Redo Logs" "${PRI_SRL:-NONE}" "$WARN"
        fi
        if [[ -n "${PRI_DEST2_STATUS:-}" ]]; then
            if [[ "${PRI_DEST2_STATUS}" == "VALID" ]]; then
                row "Archive Dest 2" "${PRI_DEST2_STATUS}" "$CHK"
            else
                row "Archive Dest 2" "${PRI_DEST2_STATUS} ${PRI_DEST2_ERROR:-}" "$FAIL"
            fi
        fi
        [[ -n "${PRI_DEST2_DBUNIQ:-}" ]] && row "Dest 2 Target" "${PRI_DEST2_DBUNIQ}"
        if [[ -n "${PRI_ARCHGAP:-}" ]] && [[ "${PRI_ARCHGAP:-0}" -gt 0 ]]; then
            row "Archive Gaps" "${PRI_ARCHGAP} gap(s)" "$FAIL"
        fi
        if [[ -n "${PRI_UNNAMED:-}" ]] && [[ "${PRI_UNNAMED:-0}" -gt 0 ]]; then
            row "UNNAMED Datafiles" "${PRI_UNNAMED} UNNAMED datafile(s)" "$FAIL"
        fi

        subheader "Recovery Area"
        if [[ -n "${PRI_FRA_PATH:-}" ]]; then
            row "FRA Usage" "${PRI_FRA_EFFECTIVE_USED}/${PRI_FRA_SIZE} GB effective (${PRI_FRA_PCT}%), reclaimable ${PRI_FRA_RECLAIM} GB" "$(dg_fra_icon "${PRI_FRA_PCT:-0}")"
            row "FRA Location" "${PRI_FRA_PATH} (${PRI_FRA_FILES:-0} files)"
        fi
    else
        subheader "Broker View"
        render_peer_broker_view "PRIMARY"
        printf "  ${DIM}%-24s${NC} %s\n" "" "(runtime SQL unavailable)"
    fi
}

render_standby_diag() {
    header "STANDBY DATABASE  (${STB_DBUNIQ:-?})"
    if [[ -n "${STB_ROLE:-}" ]]; then
        subheader "Identity"
        row "Role" "$STB_ROLE" "$(status_icon "$STB_ROLE" "PHYSICAL STANDBY")"
        row "Open Mode" "$STB_OPEN" "$(warn_icon "$STB_OPEN" "MOUNTED" "READ ONLY")"
        row "Protection Mode" "${STB_PROTECT:-$LOC_PROTECT}"
        row "Switchover Status" "$STB_SWITCH" "$(warn_icon "$STB_SWITCH" "NOT ALLOWED" "SWITCHOVER PENDING")"
        row "Flashback" "${STB_FLASH:-unknown}" "$(flashback_icon "${STB_FLASH:-}")"

        subheader "Services"
        # L17: populated only when this tool runs ON the standby.
        [[ -n "${STB_BROKER:-}" ]] && row "DG Broker" "${STB_BROKER}" "$(status_icon "${STB_BROKER}" "TRUE")"
        row "Running Services" "${STB_SERVICES:-NONE}"

        subheader "Recovery / Apply"
        if [[ -n "${STB_MRP_STATUS:-}" ]]; then
            row "MRP Status" "${STB_MRP_STATUS} (seq# ${STB_MRP_SEQ:-?})" "$(status_icon "$STB_MRP_STATUS" "APPLYING_LOG" "WAIT_FOR_LOG")"
        else
            row "MRP Status" "NOT RUNNING" "$FAIL"
        fi
        if [[ -n "${STB_RECOVERY_MODE:-}" ]]; then
            row "Recovery Mode" "$STB_RECOVERY_MODE" "$(recovery_mode_icon "$STB_RECOVERY_MODE")"
        fi

        if [[ -n "${STB_TRANSPORT_LAG:-}" ]]; then
            row "Transport Lag" "$(dg_display_lag_value "$STB_TRANSPORT_LAG")" "$(dg_lag_icon "$STB_TRANSPORT_LAG")"
        fi
        if [[ -n "${STB_APPLY_LAG:-}" ]]; then
            row "Apply Lag" "$(dg_display_lag_value "$STB_APPLY_LAG")" "$(dg_lag_icon "$STB_APPLY_LAG")"
        fi
        if [[ -n "${STB_APPLY_FINISH:-}" ]] && (( $(dg_parse_lag_seconds "$STB_APPLY_LAG") > DG_LAG_WARN_SECONDS )); then
            row "Apply Finish Time" "${STB_APPLY_FINISH}"
        fi

        if [[ -n "${STB_LAST_APPLIED:-}" ]] && [[ -n "${STB_LAST_RECEIVED:-}" ]] && [[ "${STB_LAST_RECEIVED:-0}" -gt 0 ]]; then
            if [[ -n "${SEQ_LAG:-}" ]] && (( SEQ_LAG > DG_SEQ_GAP_WARN )); then
                row "Sequences" "applied=${STB_LAST_APPLIED}  received=${STB_LAST_RECEIVED}  (lag: ${SEQ_LAG})" "$(dg_seq_gap_icon "${SEQ_LAG:-0}")"
            else
                row "Sequences" "applied=${STB_LAST_APPLIED}  received=${STB_LAST_RECEIVED}" "$(dg_seq_gap_icon "${SEQ_LAG:-0}")"
            fi
        fi
        if ${SEQ_DATA_MISSING:-false}; then
            row "Sequences" "no applied/received data returned" "$WARN"
        fi

        subheader "Redo / Archive"
        if [[ -n "${STB_SRL:-}" ]] && [[ "${STB_SRL:-0}" -gt 0 ]]; then
            row "Standby Redo Logs" "${STB_SRL} groups" "$CHK"
        else
            row "Standby Redo Logs" "${STB_SRL:-NONE}" "$FAIL"
        fi
        if [[ -n "${STB_ARCHGAP:-}" ]] && [[ "${STB_ARCHGAP:-0}" -gt 0 ]]; then
            row "Archive Gaps" "${STB_ARCHGAP} gap(s)" "$FAIL"
        fi
        if [[ -n "${STB_UNNAMED:-}" ]] && [[ "${STB_UNNAMED:-0}" -gt 0 ]]; then
            row "UNNAMED Datafiles" "${STB_UNNAMED} UNNAMED datafile(s)" "$FAIL"
        fi

        subheader "Recovery Area"
        if [[ -n "${STB_FRA_PATH:-}" ]]; then
            row "FRA Usage" "${STB_FRA_EFFECTIVE_USED}/${STB_FRA_SIZE} GB effective (${STB_FRA_PCT}%), reclaimable ${STB_FRA_RECLAIM} GB" "$(dg_fra_icon "${STB_FRA_PCT:-0}")"
            row "FRA Location" "${STB_FRA_PATH} (${STB_FRA_FILES:-0} files)"
        fi
    else
        subheader "Broker View"
        render_peer_broker_view "STANDBY"
        printf "  ${DIM}%-24s${NC} %s\n" "" "(runtime SQL unavailable)"
    fi
}

render_broker_diag() {
    header "DATA GUARD BROKER"
    if [[ "$BROKER_CONFIGURED" != true ]]; then
        row "Configuration" "NOT CONFIGURED" "$FAIL"
        return
    fi

    row "Configuration" "${BROKER_CFG_NAME:-unknown}"
    [[ -n "${BROKER_OVERALL:-}" ]] && row "Overall Status" "${BROKER_OVERALL}" "$(dg_broker_overall_icon "${BROKER_OVERALL:-}")"

    # M20: attribute a following Error:/Warning: line to the member it
    # belongs to (19c never puts the diagnosis on the member line itself).
    local render_last_member="" render_diag_sev render_member_sev
    while IFS= read -r line; do
        line_trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
        if dg_is_broker_member_line "$line"; then
            render_last_member=$(dg_broker_member_name "$line")
            # Grade the member line by the diagnosis lines that follow it,
            # so it never shows a green OK directly above its own
            # "Error: ORA-16810" line.
            render_member_sev=$(dg_broker_member_severity "$DGMGRL_CONFIG" "$render_last_member")
            if [[ "$render_member_sev" == "error" ]] || printf '%s' "$line_trimmed" | grep -qi "Error"; then
                row "" "$line_trimmed" "$FAIL"
            elif [[ "$render_member_sev" == "warning" ]] || printf '%s' "$line_trimmed" | grep -qi "Warning"; then
                row "" "$line_trimmed" "$WARN"
            else
                row "" "$line_trimmed" "$CHK"
            fi
            continue
        fi
        render_diag_sev=$(dg_broker_diagnosis_severity "$line_trimmed")
        if [[ "$render_diag_sev" == "error" ]]; then
            row "  ${render_last_member:-config}" "$line_trimmed" "$FAIL"
        elif [[ "$render_diag_sev" == "warning" ]]; then
            row "  ${render_last_member:-config}" "$line_trimmed" "$WARN"
        elif is_error_event "$line_trimmed"; then
            printf "  ${DIM}%-24s${NC} ${RED}%s${NC}\n" "" "$line_trimmed"
        fi
    done <<< "$DGMGRL_CONFIG"

    if [[ -n "${FSFO_MODE:-}" ]]; then
        if fsfo_enabled; then
            row "Fast-Start Failover" "$FSFO_MODE" "$CHK"
        else
            row "Fast-Start Failover" "$FSFO_MODE (optional)"
        fi
    fi
    [[ -n "${FSFO_TARGET:-}" && "${FSFO_TARGET}" != "(none)" ]] && row "Target" "$FSFO_TARGET"
    [[ -n "${FSFO_OBS:-}" && "${FSFO_OBS}" != "(none)" ]] && row "Observer" "$FSFO_OBS"
    [[ -n "${FSFO_THRESHOLD:-}" ]] && row "Threshold" "$FSFO_THRESHOLD"
    if [[ -n "${LOC_FSFO_STATUS:-}" ]]; then
        row "Local FSFO Status" "$LOC_FSFO_STATUS"
    fi
    if [[ -n "${LOC_FSFO_OBSERVER_PRESENT:-}" ]]; then
        if [[ "${LOC_FSFO_OBSERVER_PRESENT}" == "YES" ]]; then
            row "Observer Present" "$LOC_FSFO_OBSERVER_PRESENT" "$CHK"
        else
            row "Observer Present" "$LOC_FSFO_OBSERVER_PRESENT" "$(fsfo_observer_icon)"
        fi
    fi
    [[ -n "${LOC_FSFO_OBSERVER_HOST:-}" ]] && row "Observer Host" "$LOC_FSFO_OBSERVER_HOST"
    render_observer_ping_rows
}

render_events_diag() {
    header "RECENT ALERT LOG (DATA GUARD)"
    print_event_block "Alert Log" "$LOC_ALERT_MATCHES" "${LOC_ALERT_MATCH_COUNT:-0}" 15 "${LOC_ALERT_FILE}" "$LOC_ALERT_FILE_FOUND"
    printf "\n"
    print_event_block "Broker Log" "$LOC_DRC_MATCHES" "${LOC_DRC_MATCH_COUNT:-0}" 10 "${LOC_DRC_FILE}" "$LOC_DRC_FILE_FOUND"
}

render_interpretation_diag() {
    header "INTERPRETATION"
    row "Peer Data Source" "${REMOTE_DATA_SOURCE_LABEL}" "$PEER_SOURCE_STATE"
    row "Remote Auth" "${REMOTE_AUTH_METHOD}"
    row "Remote Result" "${REMOTE_CONNECTION_RESULT}"
    row "Remote Timeout" "${REMOTE_TEST_TIMEOUT}s"
}

render_diag_output() {
    local pri_summary_mode stb_summary_mode
    if [[ -n "${PRI_OPEN:-}" ]]; then
        pri_summary_mode="$PRI_OPEN"
    else
        pri_summary_mode="broker view"
    fi
    if [[ -n "${STB_MRP_STATUS:-}" ]]; then
        stb_summary_mode="MRP ${STB_MRP_STATUS}"
    else
        stb_summary_mode="broker view"
    fi

    print_title "Data Guard Diagnostics"

    header "AT A GLANCE"
    row "Overall" "errors=${ERRORS} warnings=${WARNINGS}" "$OVERALL_STATE"
    if ! $LOCAL_INSTANCE_AVAILABLE; then
        row "Local Instance" "${TARGET_TNS:-$ORACLE_SID} - ${LOCAL_INSTANCE_ERROR:-no response from V\$DATABASE}" "$LOCAL_INSTANCE_STATE"
    fi
    row "Primary" "${PRI_DBUNIQ:-?} / ${pri_summary_mode}" "$PRIMARY_STATE"
    row "Standby" "${STB_DBUNIQ:-?} / ${stb_summary_mode}" "$STANDBY_STATE"
    row "Broker" "${BROKER_CFG_NAME:-not configured}" "$BROKER_STATE"
    row "Redo Apply" "transport=$(lag_or_na "${STB_TRANSPORT_LAG:-${BROKER_TLAG:-}}"), apply=$(lag_or_na "${STB_APPLY_LAG:-${BROKER_ALAG:-}}")" "$REPL_STATE"
    row "Peer Data" "${REMOTE_DATA_SOURCE_LABEL}" "$PEER_SOURCE_STATE"

    render_interpretation_diag
    render_primary_diag
    render_standby_diag
    render_broker_diag
    render_events_diag

    header "FINAL SUMMARY"
    if [[ $ERRORS -eq 0 ]] && [[ $WARNINGS -eq 0 ]]; then
        row "Status" "No problems detected" "$CHK"
    else
        local item
        if [[ ${#SUMMARY_ERRORS[@]} -gt 0 ]]; then
            for item in "${SUMMARY_ERRORS[@]}"; do
                row "Error" "$item" "$FAIL"
            done
        fi
        if [[ ${#SUMMARY_WARNINGS[@]} -gt 0 ]]; then
            for item in "${SUMMARY_WARNINGS[@]}"; do
                row "Warning" "$item" "$WARN"
            done
        fi
    fi
    print_summary_infos
    printf "\n"
}

# --check output: one header line with the verdict, then one line per
# component (primary, every standby, FSFO, every observer, broker), then the
# problems - and nothing else. Built to be read for dozens of databases.
check_host() {
    printf '%s' "${1%%.*}"
}

# A lag as plain seconds ("0s", "303s"); "n/a" when there is no value.
check_lag_text() {
    if [[ -n "${1:-}" ]]; then
        printf '%ss' "$(dg_parse_lag_seconds "$1")"
    else
        printf 'n/a'
    fi
}

render_check_primary_line() {
    local st
    if [[ -n "${PRI_ROLE:-}" ]]; then
        if [[ "$PRI_OK" == true ]]; then st="$CHK"; else st="$FAIL"; fi
        row "Primary" "${PRI_DBUNIQ:-?}: ${PRI_OPEN:-?}, redo transport ${PRI_DEST2_STATUS:-?}${PRI_DEST2_DBUNIQ:+ -> ${PRI_DEST2_DBUNIQ}}" "$st"
    else
        case "$(peer_broker_status)" in
            SUCCESS) st="$CHK" ;;
            WARNING) st="$WARN" ;;
            *) st="$FAIL" ;;
        esac
        row "Primary" "${PRI_DBUNIQ:-?}: broker status $(peer_broker_status)" "$st"
    fi
}

render_check_standby_lines() {
    local i name show state tlag alag st detail
    if [[ ${#CHK_MEMBER_NAME[@]} -eq 0 ]]; then
        # No broker member list (no dgmgrl): the local/peer view only.
        if [[ -n "${STB_ROLE:-}" ]]; then
            if [[ "$STB_OK" == true ]]; then st="$CHK"; else st="$FAIL"; fi
            row "Standby" "${STB_DBUNIQ:-?}: MRP ${STB_MRP_STATUS:-NOT RUNNING}, transport $(check_lag_text "${STB_TRANSPORT_LAG:-}"), apply $(check_lag_text "${STB_APPLY_LAG:-}")" "$st"
        else
            row "Standby" "${STB_DBUNIQ:-?}: $(lag_or_na "${BROKER_TLAG:-}") / $(lag_or_na "${BROKER_ALAG:-}")" "$STANDBY_STATE"
        fi
        return
    fi
    i=0
    while [[ $i -lt ${#CHK_MEMBER_NAME[@]} ]]; do
        name="${CHK_MEMBER_NAME[$i]}"
        if [[ "${CHK_MEMBER_KIND[$i]}" != "standby" ]]; then
            i=$((i + 1)); continue
        fi
        if [[ "${CHK_MEMBER_DISABLED[$i]}" == true ]]; then
            row "Standby" "${name}: disabled in the broker"
        elif [[ "$name" == "${LOC_DBUNIQ:-}" && -n "${STB_ROLE:-}" ]]; then
            if [[ "$STB_OK" == true ]] && ! check_lag_over "${STB_TRANSPORT_LAG:-}" && ! check_lag_over "${STB_APPLY_LAG:-}"; then st="$CHK"
            elif [[ "$STB_OK" == true ]]; then st="$WARN"
            else st="$FAIL"; fi
            row "Standby" "${name} (local): MRP ${STB_MRP_STATUS:-NOT RUNNING}, transport $(check_lag_text "${STB_TRANSPORT_LAG:-}"), apply $(check_lag_text "${STB_APPLY_LAG:-}")" "$st"
        else
            show="${CHK_MEMBER_SHOW[$i]}"
            state=$(printf '%s\n' "$show" | grep 'Intended State:' | sed 's/.*Intended State: *//' | dg_trim)
            tlag=$(dg_broker_lag_value "$(printf '%s\n' "$show" | grep 'Transport Lag:' | sed 's/.*Transport Lag: *//')")
            alag=$(dg_broker_lag_value "$(printf '%s\n' "$show" | grep 'Apply Lag:' | sed 's/.*Apply Lag: *//')")
            detail="${state:-?}, transport $(check_lag_text "$tlag"), apply $(check_lag_text "$alag")"
            case "${CHK_MEMBER_STATUS[$i]}" in
                ERROR|"") st="$FAIL" ;;
                WARNING) st="$WARN" ;;
                *) if [[ -z "$tlag" || -z "$alag" ]] || check_lag_over "$tlag" || check_lag_over "$alag"; then st="$WARN"; else st="$CHK"; fi ;;
            esac
            [[ "${CHK_MEMBER_STATUS[$i]}" != "SUCCESS" ]] && detail="${detail}, broker ${CHK_MEMBER_STATUS[$i]:-no status}"
            row "Standby" "${name}: ${detail}" "$st"
        fi
        i=$((i + 1))
    done
}

render_check_fsfo_lines() {
    local i st grade
    if ! fsfo_enabled; then
        row "FSFO" "${FSFO_MODE:-not configured} (no observer expected)"
        return
    fi
    grade=$(fsfo_status_grade "${LOC_FSFO_STATUS:-}")
    case "$grade" in ok) st="$CHK" ;; warning) st="$WARN" ;; *) st="$FAIL" ;; esac
    row "FSFO" "$(printf '%s' "$FSFO_MODE" | sed 's/^Enabled in //; s/ Mode$//'), target ${FSFO_TARGET:-?}, ${LOC_FSFO_STATUS:-status unknown}" "$st"
    if [[ ${#CHK_OBS_NAME[@]} -eq 0 ]]; then
        if [[ "${LOC_FSFO_OBSERVER_PRESENT:-}" == "YES" ]]; then st="$CHK"; else st="$FAIL"; fi
        row "Observer" "$(check_host "${LOC_FSFO_OBSERVER_HOST:-?}"): connected to this database ${LOC_FSFO_OBSERVER_PRESENT:-?} (no SHOW OBSERVER)" "$st"
        return
    fi
    i=0
    while [[ $i -lt ${#CHK_OBS_NAME[@]} ]]; do
        st=$(observer_icon "$i")
        row "Observer" "${CHK_OBS_NAME[$i]} (${CHK_OBS_ROLE[$i]:-?}) @ $(check_host "${CHK_OBS_HOST[$i]:-?}"): last ping primary $(check_ping_text "${CHK_OBS_PPRI[$i]}"), target $(check_ping_text "${CHK_OBS_PTGT[$i]}")" "$st"
        i=$((i + 1))
    done
}

# "2 seconds ago" -> "2s", "1 minute 5 seconds ago" -> "65s", else as is.
check_ping_text() {
    local age
    age=$(observer_ping_age "${1:-}")
    if [[ -n "$age" ]]; then printf '%ss' "$age"; else printf '%s' "${1:-unknown}"; fi
}

render_check_output() {
    local verdict item
    # Narrow label column: the component lines carry the detail.
    LABEL_W=8
    ROW_VALUE_W=$((TERM_WIDTH - LABEL_W - STATUS_W - 6))
    if ! $LOCAL_INSTANCE_AVAILABLE || [[ $ERRORS -gt 0 ]]; then
        verdict="${RED}NOT RUNNING CORRECTLY${NC}"
    elif [[ $WARNINGS -gt 0 ]]; then
        verdict="${YELLOW}DEGRADED${NC}"
    else
        verdict="${GREEN}RUNNING AS CONFIGURED${NC}"
    fi

    printf "\n ${BOLD}%s${NC} @ %s (%s)  %b  ${DIM}%s${NC}\n" \
        "${LOC_DBUNIQ:-${TARGET_TNS:-$ORACLE_SID}}" "$(check_host "${LOC_HOST:-$(short_hostname)}")" "${LOC_LABEL}" "$verdict" "$(date '+%Y-%m-%d %H:%M:%S')"
    if ! $LOCAL_INSTANCE_AVAILABLE; then
        row "Instance" "${TARGET_TNS:-$ORACLE_SID} - ${LOCAL_INSTANCE_ERROR:-no response from V\$DATABASE}" "$FAIL"
    else
        render_check_primary_line
        render_check_standby_lines
        render_check_fsfo_lines
        if [[ "${BROKER_OVERALL:-}" == "SUCCESS" ]]; then
            row "Broker" "${BROKER_CFG_NAME}: SUCCESS" "$CHK"
        else
            row "Broker" "${BROKER_CFG_NAME:-not configured}: ${BROKER_OVERALL:-unknown}" "$BROKER_STATE"
        fi
    fi
    if [[ ${#SUMMARY_ERRORS[@]} -gt 0 ]]; then
        for item in "${SUMMARY_ERRORS[@]}"; do
            row "Problem" "$item" "$FAIL"
        done
    fi
    if [[ ${#SUMMARY_WARNINGS[@]} -gt 0 ]]; then
        for item in "${SUMMARY_WARNINGS[@]}"; do
            row "Problem" "$item" "$WARN"
        done
    fi
}

collect_all_status_data() {
    COLLECT_INFOS=()
    collect_identity
    collect_broker_data
    attempt_remote_connection
    collect_remote_sql
    collect_local_sql
    parse_local_sql
    parse_remote_sql
    # --check reports state, not history: no alert/broker log reads.
    dg_check_scope || collect_log_matches
    assign_role_views
    collect_components
    assess_all
}

dg_local_status_exit_code() {
    if [[ $ERRORS -gt 0 ]]; then
        return 2
    fi
    if [[ $WARNINGS -gt 0 ]]; then
        return 1
    fi
    return 0
}

dg_local_status_main() {
    local mode="$1"
    shift

    DG_STATUS_MODE="$mode"
    DG_SCRIPT_NAME="$(basename "${BASH_SOURCE[1]}")"

    case "$mode" in
        triage)
            REMOTE_DEFAULT_PROMPT=false
            ;;
        diag)
            REMOTE_DEFAULT_PROMPT=true
            ;;
        *)
            printf "Unknown local status mode: %s\n" "$mode" >&2
            return 64
            ;;
    esac

    parse_args "$DG_SCRIPT_NAME" "$@" || return $?
    $SHOW_HELP && return 0

    dg_validate_thresholds || return 64
    verify_oracle_env || return $?
    if [[ -n "$TARGET_TNS" ]]; then
        connect_target || return $?
    fi
    collect_all_status_data

    if dg_check_scope; then
        render_check_output
    else
        case "$mode" in
            triage) render_triage_output ;;
            diag) render_diag_output ;;
        esac
    fi

    dg_local_status_exit_code
}
