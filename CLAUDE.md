# Project: dg_fleet_check - Oracle Data Guard health check for a fleet

`dg_fleet_check.sh` runs `dg_triage_sid.sh` / `dg_diag_sid.sh` for every `[target]` of an INI-style config: `auth = password` (`-t ALIAS`, SYS password piped on stdin), `auth = wallet` (`-t ALIAS`), `auth = ssh` (ship the tool as a tar over the ssh stdin into a private temp dir on the DB host, run it there with `ORACLE_SID=sid` and `/ as sysdba`, remove the dir). Whole-config validation before any connection (exit 64), `-q` prints only non-OK reports, two modes: review configuration (default, `--review-config`) and `--check` (fleet sweep: grades only the running state of every component incl. each standby member and each observer's pings to primary and target; compact one-line-per-component output, no log reads), `-n/--dry-run` validates only, exit = worst target (0/1/2; FAILED = tool rc 64, remote setup 70, timeout 124, ssh 255 -> 2).

Layout (the tool ships exactly these to a DB host - keep `SHIP_FILES` in sync):
```
dg_fleet_check.sh                 - the wrapper
dg_triage_sid.sh / dg_diag_sid.sh - thin entry points, source the engine
common/dg_local_status_common.sh  - the engine (local and -t network mode)
common/dg_render_common.sh        - render/threshold library
templates/dg_fleet.conf.template  - config template
tests/test_fleet_check.sh         - stub tools + stub ssh (runs the remote command locally with sh -c)
docs/DG_CHECK.md                  - reference for the two tools
```

Rules: Bash 3.2 / AIX 7.2 compatible (no `grep -P`, no BRE `\|`, no bash-4 syntax; `timeout`/`mktemp` behind `command -v`); passwords never on a command line (stdin CONNECT after `SET DEFINE OFF`); the engine's `-t` mode reads the alert log via `X$DBGALERTEXT` (V$DIAG_ALERT_EXT fails with ORA-01219 on a MOUNTED standby). Run `bash tests/test_fleet_check.sh` before committing. The engine files are shared with the parent project `oracle-dataguard-setup`; port fixes both ways.
