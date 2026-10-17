# dg_fleet_check - Data Guard health check for many databases

Runs a Data Guard triage (or deep diagnostics) against every database listed in a config file and prints one summary table. Each database is reached either over the network (TNS alias + SYS password or wallet) or by ssh to its host, where the check runs locally with `/ as sysdba`.

```
git clone https://github.com/davidbudac/oracle-dg-fleet-check.git
cd oracle-dg-fleet-check
cp templates/dg_fleet.conf.template fleet.conf && chmod 600 fleet.conf   # edit it
bash dg_fleet_check.sh -c fleet.conf -n                                  # plan only
bash dg_fleet_check.sh -c fleet.conf
```

## 1. Write the config

```ini
# over the network, SYS password stored here
[prod.world]                  # section name = TNS alias (or add: tns = ALIAS)
auth = password
password = secret             # no inline comments after it, so '#' is allowed
peer_tns = prod_stby.world    # optional: peer alias as THIS host resolves it

# over the network, this host's auto-login wallet
[prod_stby.world]
auth = wallet

# ssh to the DB host, then "/ as sysdba" there
[dg2-prod]                    # free label
host = oracle@dg2             # ssh must work without a prompt (keys/agent)
sid = prod                    # ORACLE_SID on that host
# oracle_home = /u01/app/oracle/product/19.0.0/dbhome_1   # default: oratab
# ssh_opts = -p 2222 -i ~/.ssh/dg_key
# remote_dir = /home/oracle/oracle-dg-fleet-check          # use an existing copy
# mode = diag                                              # per-target override
# scope = check                                            # per-target mode: check|review-config
```

`auth` is inferred when omitted: `host` set -> ssh, `password` set -> password, else wallet.

## 2. Run

```bash
bash dg_fleet_check.sh -c fleet.conf -n            # (--dry-run) validate config, print the plan, connect nowhere
bash dg_fleet_check.sh -c fleet.conf               # review configuration (default): full report per target + summary
bash dg_fleet_check.sh -c fleet.conf -q            # reports only for targets that are not OK
bash dg_fleet_check.sh -c fleet.conf --diag        # deep diagnostics instead of triage
bash dg_fleet_check.sh -c fleet.conf --check       # check: only "is Data Guard running as configured?"
bash dg_fleet_check.sh -c fleet.conf --only prod.world,dg2-prod
```

Requirements: for `password`/`wallet` targets an Oracle client with `sqlplus` on this host (`ORACLE_HOME` or `PATH`; `dgmgrl` optional) and TNS resolution of the alias; for `ssh` targets only ssh. The DB host needs nothing installed: the tool is shipped over the ssh connection into a private temp dir and removed afterwards.

## 3. Read the result

```
==== Fleet summary (3 target(s), 2026-10-16 09:48:43) ====
Target                   Method                                     Secs  Result
prod.world               tns/password prod.world                       4  OK
prod_stby.world          tns/wallet prod_stby.world                    5  WARNING
dg2-prod                 ssh oracle@dg2 sid=prod                       8  CRITICAL
```

| Result     | Meaning                                                                  |
|------------|--------------------------------------------------------------------------|
| OK         | no findings                                                              |
| WARNING    | warnings only (details in that target's report)                          |
| CRITICAL   | errors, or the tool could not log in                                     |
| FAILED     | not checked: tool usage/env error (64), remote setup (70), timeout (124), ssh (255) |

Exit code = worst target: `0` all OK, `1` warnings, `2` CRITICAL or FAILED, `64` bad config/usage. Use `-q` in cron and act on a non-zero exit.

### Two modes: review configuration and check

**Review configuration** (`--review-config`, the default) grades the running state and also flags configuration choices (Flashback Database off with FSFO, force logging off, no standby redo logs, FRA filling up). **Check** (`--check`) leaves those out of the grade and only answers whether Data Guard is running as it is configured. It is built for sweeping dozens of databases. It grades every component: the primary (open mode, redo transport, archive gaps), every standby in the broker configuration (redo apply, transport/apply lag), the FSFO status, and every observer. An observer counts only if it is actually pinging both the primary and the target within the FSFO threshold. The broker status is graded too. Configuration findings are not graded, and the output is a few lines per database:

```
 cdb1 @ ol9-19-dg1 (PRIMARY)  RUNNING AS CONFIGURED  2026-10-16 17:49:45
  Primary  cdb1: READ WRITE, redo transport VALID -> cdb1_stby                 OK
  Standby  cdb1_stby: APPLY-ON, transport 0s, apply 0s                         OK
  FSFO     Zero Data Loss, target cdb1_stby, SYNCHRONIZED                      OK
  Observer dg_observer (Master) @ ol9-19-dg3: last ping primary 3s, target 3s  OK
  Broker   my_dg_config: SUCCESS                                               OK
```

Anything wrong is added as a `Problem` line. Add `-q` to print only the databases that are not OK. When every target ran in check mode, the fleet summary ends with one line:

```
VERDICT: Data Guard is running as configured (2 target(s))
```

## Notes

- Passwords never appear on a command line: they are piped to the tool, which hands them to `sqlplus`/`dgmgrl` on stdin. ssh targets carry no password.
- The config is validated as a whole first; any error (duplicate section, unknown key, missing `host`/`sid`/`password`, `"` in a password) lists everything wrong and exits 64 before anything connects.
- `DG_FLEET_TARGET_TIMEOUT` (default 900 s) bounds each target; `DG_TARGET_TIMEOUT` (30 s) bounds each query; `DG_FRA_WARN_PCT`, `DG_LAG_WARN_SECONDS`, `DG_OBSERVER_PING_MAX` etc. pass through to the tools.
- What the triage/diag tools check, the `-t` network mode and the grading rules: [docs/DG_CHECK.md](docs/DG_CHECK.md).
- Tests: `bash tests/test_fleet_check.sh` (no database or network needed).

## Files

```
dg_fleet_check.sh                 the wrapper
dg_triage_sid.sh, dg_diag_sid.sh  the checks (also usable alone: on a DB host, or with -t ALIAS)
common/                           the engine and render library they source
templates/dg_fleet.conf.template  config template
```

The checks come from [oracle-dataguard-setup](https://github.com/davidbudac/oracle-dataguard-setup). MIT license.
