# Triage / Diagnostics Reference

This file documents the two tools `dg_fleet_check.sh` drives. They originate from the [oracle-dataguard-setup](https://github.com/davidbudac/oracle-dataguard-setup) project.


The local status flow is now split into two commands that run directly on a DB host, using `sqlplus / as sysdba` locally and DGMGRL-based peer discovery:

- `dg_triage_sid.sh` for fast operator triage
- `dg_diag_sid.sh` for deeper diagnostics

## Quick Start

```bash
# Fast triage - wallet only by default, non-blocking when remote runtime is unavailable
export ORACLE_SID=cdb1
bash dg_triage_sid.sh

# Deep diagnostics - prompts for SYS password if wallet auth fails
bash dg_diag_sid.sh

# Skip remote SQL entirely (local + broker view only)
bash dg_triage_sid.sh -L
bash dg_diag_sid.sh -L

# Force password prompt for remote runtime checks
bash dg_triage_sid.sh -P
bash dg_diag_sid.sh -P

# Disable colored output (for logs/pipes; NO_COLOR is also honored,
# and color is off automatically when stdout is not a terminal)
bash dg_triage_sid.sh --no-color

# Over the network, from any host with an Oracle client (no ORACLE_SID needed)
bash dg_triage_sid.sh -t cdb1.world
bash dg_diag_sid.sh -t cdb1_stby.world --peer-tns cdb1.world
```

## Running Over the Network (`-t` / `--tns`)

Both commands accept `-t ALIAS` (`--tns ALIAS`, `--tns=ALIAS`): the database
named by the alias becomes the "local" side, reached over SQL*Net instead of
`sqlplus / as sysdba`, so the tools run from a jump host or a DBA workstation.
What changes:

- **Prerequisites**: an Oracle client with `sqlplus` (`ORACLE_HOME` or `PATH`),
  TNS resolution for the alias, no `ORACLE_SID`. `dgmgrl` is optional (see
  below). Every query is bounded by `DG_TARGET_TIMEOUT` seconds (default 30).
- **Login**: the wallet first (`/@ALIAS AS SYSDBA`, through the external
  password store in effect), then a SYS password prompt (echo off; stdin is
  read, so it can be piped). A name-resolution or listener error
  (`ORA-12154`, `ORA-12514`, `ORA-12541`, `TNS-`) is fatal straight away -
  no password can fix it. A wrong password, an empty one, or one containing
  `"` exits `2` with the ORA- line; nothing is collected without a login. The
  password goes to `sqlplus` and `dgmgrl` on **stdin** (`CONNECT` after
  `SET DEFINE OFF`), never on a command line.
- **Peer**: discovered from the broker as usual and opened with the wallet, or
  with the **same SYS password** (Data Guard keeps the password files identical,
  so there is no second prompt); `-P` still forces a separate prompt. The
  broker's `DGConnectIdentifier` is resolvable on the DB hosts but not
  necessarily where you run the tool - `--peer-tns ALIAS` names the peer as
  this host knows it. With neither, the peer is graded from the broker view
  (`OK (broker)`), exactly as in a wallet-less local run.
- **Broker**: `dgmgrl /@ALIAS` or `dgmgrl` with `CONNECT` on stdin. Without a
  `dgmgrl` binary (Instant Client) the configuration is rebuilt from
  `V$DG_BROKER_CONFIG` (members, roles, connect identifiers, per-member status
  code: a non-zero code is a `Warning: ORA-nnnnn (see dgmgrl on a DB host)`)
  and `V$DATABASE`'s `FS_FAILOVER_*` columns, flagged by an `Info` line
  `Broker from V$DG_BROKER_CONFIG (no dgmgrl)`.
- **Events**: the alert log is read through the fixed table `X$DBGALERTEXT`
  (rdbms component, last 24 hours, newest 2000 entries) and filtered with the
  same Data Guard patterns as the file. The fixed table rather than
  `V$DIAG_ALERT_EXT` because on a MOUNTED standby the view fails with
  `ORA-01219` (queries allowed on fixed tables or views only) while the X$
  table answers (verified on 19.27); the broker log `drc<SID>.log` has no SQL view
  and is reported as a host file not readable over the network.
- **Title line**: `Target: ALIAS via wallet|password -> host (instance: X,
  role: PRIMARY|STANDBY)`.

Warning/critical thresholds (FRA %, sequence gaps, lag seconds) are
env-overridable via `DG_FRA_WARN_PCT`, `DG_FRA_CRIT_PCT`, `DG_SEQ_GAP_WARN`,
`DG_SEQ_GAP_CRIT`, `DG_LAG_WARN_SECONDS` -- see
[DG_STATUS.md](DG_STATUS.md#thresholds) for defaults and meaning. A value that
is not a non-negative integer (`80%`) is a usage error (exit `64`).

## Checking a Whole Fleet: `dg_fleet_check.sh`

`dg_fleet_check.sh` runs the triage (or, with `--diag`, the diagnostics) check
against every database listed in a config file and prints one summary table at
the end. Each `[target]` names how it is reached:

| `auth`     | What happens                                                                                   |
|------------|------------------------------------------------------------------------------------------------|
| `password` | `dg_triage_sid.sh -t ALIAS` from this host; the SYS `password` from the config is fed on stdin  |
| `wallet`   | `dg_triage_sid.sh -t ALIAS` from this host; the auto-login wallet in effect supplies SYS        |
| `ssh`      | `ssh host`, ship the tool (tar over the ssh stdin into a private temp dir), run it there with `ORACLE_SID=sid` and `/ as sysdba`, remove the temp dir |

```ini
[cdb1.world]                 # section name = TNS alias (or set tns = ...)
auth = password
password = secret            # no inline comments, so '#' is allowed in it
peer_tns = cdb1_stby.world   # optional, same meaning as --peer-tns

[cdb1_stby.world]
auth = wallet

[dg2-cdb1]
auth = ssh                   # inferred when 'host' is present
host = oracle@dg2            # keys/agent: ssh runs with BatchMode=yes
sid = cdb1
# oracle_home = ...          # default: looked up in /etc/oratab on the host
# ssh_opts = -p 2222 -i ~/.ssh/dg
# remote_dir = /home/oracle/dataguard_setup   # existing copy instead of shipping
# mode = diag                # per-target override
```

A complete template is in `templates/dg_fleet.conf.template`.

```bash
bash dg_fleet_check.sh -c fleet.conf             # all targets, full reports + summary
bash dg_fleet_check.sh -c fleet.conf --diag -q   # deep check, print only the reports that are not OK
bash dg_fleet_check.sh -c fleet.conf --only cdb1.world,dg2-cdb1
bash dg_fleet_check.sh -c fleet.conf -n          # validate the config, print the plan, connect nowhere
```

Rules:

- The config is validated as a whole before anything connects: a duplicate
  section, an unknown key, a missing `password`/`host`/`sid`, a password or
  alias containing `"`, or an `--only` name that does not exist exits `64`
  with every error listed. A config holding passwords that is readable by
  group/others gets a warning (`chmod 600`).
- The password never reaches a command line: it is piped to the tool, which
  passes it to `sqlplus`/`dgmgrl` on stdin (see the network-mode section). The
  `ssh` targets carry no password at all. The `wallet` and `ssh` targets run
  with stdin closed, so a prompt the tool would otherwise show (diag mode's
  peer password) is skipped, never hung on.
- On the DB host the tool needs `ORACLE_SID` and `ORACLE_HOME`: `sid` is
  required, `oracle_home` defaults to the login shell's `ORACLE_HOME`, then the
  `oratab` entry (`/etc/oratab`, `/var/opt/oracle/oratab`); none found is a
  `FAILED (remote setup, rc 70)`. `LIBPATH` is exported for AIX. ssh runs with
  `BatchMode=yes`, `ConnectTimeout=15` and server-alive probes; `ssh_opts`
  adds options (word-split).
- Each target is bounded by `DG_FLEET_TARGET_TIMEOUT` seconds (default 900,
  needs the `timeout` binary) on top of the tools' own `DG_TARGET_TIMEOUT`.
  All `DG_*` thresholds are passed through.
- Exit code: the worst target - `0` all OK, `1` at least one WARNING, `2` at
  least one CRITICAL or a target that could not be checked at all (`FAILED`:
  the tool's `64`, remote setup `70`, timeout `124`, ssh `255`); `64` for a
  usage or config error. Suitable for cron with `-q` (reports only for targets
  that are not OK, the summary always).

## Command Roles

### `dg_triage_sid.sh`

Optimized for quick health confirmation:

- leads with top findings
- shows concise primary / standby / broker state
- makes degraded peer visibility explicit
- keeps recent DG events compressed to the newest few lines

Default remote behavior:

1. try wallet authentication
2. if wallet fails, do **not** prompt
3. continue in broker-only degraded mode unless `-P` was specified

Exit codes:

- `0` healthy
- `1` warning
- `2` in network mode when the target cannot be opened (unreachable alias,
  wrong or missing password); `64` for a bad flag (`-t` without a value,
  `--peer-tns` without `-t`, a quote in an alias)
- `0` also when the peer is only visible through the broker (no wallet/password):
  that is an `Info` line, not a warning, as long as the broker reports the peer
- `2` error (including a local instance that is down — see below)
- `64` usage or preflight failure (unknown flag, `ORACLE_SID`/`ORACLE_HOME`
  unset, malformed threshold variable)

### `dg_diag_sid.sh`

Optimized for deeper investigation:

- keeps the same local collection path and broker discovery
- shows richer runtime detail
- includes more verbose log excerpts
- includes connection provenance and peer-data interpretation

Default remote behavior:

1. try wallet authentication
2. if wallet fails, prompt for SYS password unless `-L`

Exit codes are the same as `dg_triage_sid.sh`.

### `dg_check_sid.sh` (deprecated)

Compatibility behavior:

- prints `DEPRECATED: Use dg_triage_sid.sh` to stderr
- forwards flags unchanged
- always exits `0`

## Local Instance Availability

Before anything else, both commands read `V$DATABASE` locally. If that returns
no role at all — `ORA-01034` (instance not started), `ORA-01109` (not open), a
wrong `ORACLE_SID`, a bad `ORACLE_HOME` — the tool says so explicitly:

```
  Error   Local instance cdb1 is DOWN or not open: ORA-01034: ORACLE not available
  Info    Check: ps -ef | grep ora_pmon_cdb1 ; then 'sqlplus / as sysdba' and STARTUP MOUNT
```

and exits `2`, with a `Local Instance ... DOWN` row in AT A GLANCE. Previously
every field parsed empty, every check was skipped because it was gated on a
non-empty role, and the tool most likely to be run *because* the database is
down reported `WARNING` / exit `1` without ever saying "down".

## What The Scripts Check

Both commands use the same shared collector and grading rules. The difference is presentation depth.

### Primary-side checks

- Database role and open mode
- Protection mode
- Switchover status -- anything other than `TO STANDBY` / `SESSIONS ACTIVE` is a
  **warning**, as in `dg_status.sh`
- Force logging
- Flashback -- **informational** (`Info`) unless Fast-Start Failover is enabled;
  with FSFO on, Flashback Database is what makes reinstating the old primary
  possible, so `NO` is then a warning
- `dg_broker_start` -- **only when the command is running on the primary.**
  This parameter is read from the local `V$PARAMETER`; the peer connection
  never queries it. When you run the tools on the *standby*, the primary's
  `DG Broker` row reads `unknown (dg_broker_start is only readable on the local
  instance)` in the diagnostics output (the triage output simply omits the
  row) and the standby section shows the standby's own value instead.
  (It used to publish the standby's local value as the primary's, producing a
  "dg_broker_start is FALSE" finding pointed at the wrong host.)
- Services
- Online redo and standby redo counts
- Archive destination 2 status; a dest 2 that targets a member other than the
  peer shown is informational only (legitimate with several standbys - the
  broker grades the real transport state)
- Archive gaps
- FRA usage and thresholds

### Standby-side checks

- Database role and open mode
- Protection mode
- Switchover status
- MRP status and sequence
- `dg_broker_start` (only when running on the standby -- see the primary list)
- Recovery mode -- anything other than real-time apply is **informational**
  (`Info` line, plain row): a standby without `USING CURRENT LOGFILE`, or with
  a configured `DelayMins`, is a valid configuration (`dg_status.sh` still
  flags it with `!!`)
- Transport lag
- Apply lag
- Apply finish time
- Sequence lag
- Replication state (`Redo Apply` row) -- derived by the same function
  `dg_status.sh` uses (`dg_repl_state` in `common/dg_render_common.sh`). When
  the standby returned no transport lag, apply lag *and* no sequence data the
  row reads `UNKNOWN` and a warning is raised; it is never a green `IN SYNC`
  by default. A missing `APPLYINFO` row (the apply-info SQL errored) is graded
  the same way even when lag rows came back: the `Sequences` row shows
  `no applied/received data returned`, the state is `UNKNOWN` and the run exits
  `1`. More generally, a local batch that lacks any of its always-present rows
  (`DBSTATUS`, `REDOLOG`, `SRLCOUNT`, `ARCHGAP`, `UNNAMEDDF`, `APPLYINFO`) raises
  `Local SQL result incomplete: no <TAG> row returned (<first ORA-/SP2- line>)`
  (warning, exit `1`) instead of reading as healthy
- Standby redo count
- Archive gaps
- FRA usage and thresholds
- Flashback state (same rule as on the primary: informational unless FSFO is on)

### Broker / FSFO checks

- Configuration presence
- Overall broker status (`ERROR` -> error/exit 2, red; `WARNING` -> warning/exit 1,
  amber -- the same colours and icons `dg_status.sh` uses)
- Member warnings / errors. 19c prints a member's diagnosis on the line *after*
  the member line:

  ```
    cdb1      - Primary database
      Error: ORA-16810: multiple errors or warnings detected for the member
  ```

  The tools remember the last member line and attribute the following
  `Error:` / `Warning:` line to it, so the finding reads
  `Broker member cdb1: ORA-16810: ...` and reaches the summary and the exit
  code. The member line itself is graded by its own diagnosis lines, so it can
  never show a green `OK` directly above its own `Error:`. `Error: 0` is
  DGMGRL's healthy value and is not treated as a finding.
- Fast-Start Failover mode -- **disabled is informational**, not a warning:
  FSFO is an optional add-on (step 9) and a manual-failover configuration is
  complete without it. The row reads `Disabled (optional)` with no icon
- FSFO target
- Observer presence / host. `V$DATABASE.FS_FAILOVER_OBSERVER_PRESENT` is the
  authority on whether an observer is actually connected. **FSFO enabled with
  no observer present is an error** (automatic failover will not happen) -- the
  same grade `dg_status.sh` gives it. With FSFO disabled, no observer is
  expected and the row carries no icon at all.

## Data Source Modes

The scripts now make the peer data source explicit:

- `remote runtime via wallet`
- `remote runtime via password`
- `broker-only degraded mode`
- `local+broker only (-L)`

When remote runtime SQL is unavailable, peer details fall back to broker data
(`SHOW DATABASE '<peer>'`: role, intended state, lags, database status). As long
as the broker can show the peer this is an `Info` line, not a warning - running
without a wallet is the default - and the peer's AT A GLANCE state is graded
from the broker's `Database Status` (`OK (broker)` / `WARNING (broker)` /
`ERROR (broker)`), never a red `CHECK` just because no runtime SQL reached it.
Only a peer the broker cannot show either (`Peer unavailable: no runtime SQL
and no broker view`) is a warning.

The triage output states the peer data source once, in the title line
(`Source: ...`), and its verdict once, in the `Overall` row of AT A GLANCE.

Explanatory `Info` lines (for example "Peer runtime skipped by request (-L)")
are rendered under TOP FINDINGS and in the diagnostics FINAL SUMMARY. They
carry no severity and never affect the exit code -- they exist so that a `-L`
run's red `CHECK` state has a visible reason next to it.

## Recent DG Events

Both commands inspect the local alert log and broker log:

- `dg_triage_sid.sh` shows compressed recent events only
- `dg_diag_sid.sh` shows longer excerpts

The **path that was actually read is always printed** (it used to be hidden
behind `DG_DEBUG=1`), and three outcomes are rendered distinctly:

- `(log path unknown: V$DIAG_INFO 'Diag Trace' returned nothing)`
- `(file not found)` -- the usual symptom of a non-default `diagnostic_dest`
  or an `ORACLE_SID` that does not match the log file name
- `(0 matched - file read, no Data Guard entries)` -- a genuinely quiet log

Previously the last two both printed `(none)`, so "I am looking in the wrong
place" and "nothing happened" were indistinguishable.

## Wallet Usage

These commands work best with wallet-based peer authentication configured via [WALLET_SETUP.md](WALLET_SETUP.md). With a wallet in place, peer runtime queries can use:

```bash
sqlplus /@peer_tns_alias as sysdba
```

The wallet probe connects with the alias **exactly as the broker reports it**
(`/@alias`). (Confirmed on a 19c lab: a credential stored under the alias
connects as `/@alias` but fails with ORA-01017 when the same address is given
as an inline `(DESCRIPTION=...)`.) The external password store matches
credentials on the connect string text, and `common/setup_dg_wallet.sh` stores them under the alias, so
the alias is never rewritten into a descriptor for this connect. The probe is
time-bounded from outside instead (`REMOTE_TEST_TIMEOUT`, default 5 s): the
`timeout` binary when present, otherwise a portable background-and-kill
watchdog (AIX has no `timeout`). Descriptor-level connect timeouts are used
only on the SYS-password path, where there is no stored-credential match to
break.

### Password prompt

`dg_diag_sid.sh` (and `-P`) prompt for the peer SYS password with echo off; Ctrl-C
or a termination signal restores the terminal. The password is sent to
`sqlplus` on stdin after `SET DEFINE OFF`, so a `&` in it is not treated as a
substitution variable. A password containing a double quote (`"`) cannot be
passed in a quoted `CONNECT` and is rejected with a message; the tool then
continues in broker-only mode.

