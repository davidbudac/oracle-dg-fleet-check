#!/usr/bin/env bash
# =============================================================================
# HTML report for dg_fleet_check.sh (--html). Sourced by the wrapper only; it
# runs on the host that runs the fleet check and is NOT shipped to DB hosts.
#
# The per-target reports are the tools' own --no-color text. They are parsed
# back into structure here (section headers = the line above a rule of "─",
# rows = label column / value / trailing status, "Error"/"Warning"/"Info"/
# "Problem" rows = findings; in --check the Primary/Standby/FSFO/Observer/
# Broker rows become database and observer tables) so the engine stays
# untouched and an older engine copy (remote_dir) still renders. Anything
# that does not parse is kept as a plain message line, and every target
# carries the raw text as well.
#
# Bash 3.2 / POSIX awk (AIX 7.2): no gensub, no regex intervals, LC_ALL=C so
# the multibyte rule character is matched as plain bytes.
# =============================================================================

if [[ -n "${DG_FLEET_HTML_SH_LOADED:-}" ]]; then
    return 0
fi
DG_FLEET_HTML_SH_LOADED=1

html_esc() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }
html_esc_s() { printf '%s' "$1" | html_esc; }

# One target's text report -> detail body HTML on stdout.
#   -v lw    = the label column width (24, or 8 in --check)
#   -v meta  = file that receives one tab-separated line (empty = "-"):
#              errors warnings infos first-sev databases standbys standbys-ok
#              max-apply-lag max-lag-sev observers observers-ok fsfo(0/1)
#              first-finding
#   -v findf = file that receives one "sev<TAB>text" line per finding
DG_HTML_AWK=$(cat <<'AWKEOF'
function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function nz(s) { return (s == "") ? "-" : s }
function is_hline(s,  t) {
    if (index(s, hc) == 0) return 0
    t = s; gsub(hc, "", t)
    return t ~ /^ *$/
}
function sevclass(u) {
    if (u == "OK" || u == "HEALTHY" || u == "SUCCESS" || u == "UP" || u == "RUNTIME SQL" || u ~ /^IN SYNC/) return "ok"
    if (u == "XX" || u == "CRITICAL" || u == "CHECK" || u == "ERROR" || u == "DOWN" || u == "NOT CONFIGURED" || u ~ /FAIL/) return "crit"
    if (u == "!!" || u == "ATTENTION" || u == "WARNING" || u == "LAGGING" || u == "UNKNOWN" || u ~ /^BEHIND/) return "warn"
    return "info"
}
function stlabel(u) {
    if (u == "OK") return "OK"
    if (u == "!!") return "Warning"
    if (u == "XX") return "Fail"
    if (u == "--") return "Info"
    if (u == "@OFF") return "Disabled"
    return u
}
function badge(st,  c) {
    if (st == "") return ""
    c = (st == "@OFF") ? "" : sevclass(st)
    if (c == "info") c = ""
    return "<span class=\"badge" (c == "" ? "" : " " c) "\">" esc(stlabel(st)) "</span>"
}
# "303s" -> 303, anything else -> -1
function secs(x) { return (x ~ /^[0-9]+s$/) ? x + 0 : -1 }
function two(n) { return (n < 10) ? "0" n : n }
function fmt_lag(x,  n, h, m) {
    if (x == "") return "&mdash;"
    if (x == "(unknown)") x = "unknown"
    n = secs(x)
    if (n < 0) return esc(x)
    if (n < 60) return n "s"
    if (n < 3600) { m = int(n / 60); return m "m " two(n - m * 60) "s" }
    h = int(n / 3600); m = int((n - h * 3600) / 60)
    return h "h " two(m) "m"
}
# Which of two lag/ping values to highlight on a degraded row: 1, 2 or 0.
function worse(a, b,  x, y) {
    x = secs(a); y = secs(b)
    if (a != "" && x < 0) return 1
    if (b != "" && y < 0) return 2
    if (x <= 0 && y <= 0) return 0
    return (x >= y) ? 1 : 2
}
function cell(v, hot, sev, raw) { return "<td class=\"num" (hot ? " v-" sev : "") "\">" (raw && v != "" ? esc(v == "(unknown)" ? "unknown" : v) : fmt_lag(v)) "</td>" }
function add_finding(sev, text) {
    nf++; F_SEV[nf] = sev; F_TXT[nf] = text
    if (sev == "crit") ncrit++
    else if (sev == "warn") nwarn++
    else ninfo++
}
function open_section(title) {
    close_section()
    findsec = (title == "TOP FINDINGS" || title == "FINAL SUMMARY")
    logsec = (title ~ /EVENTS/ || title ~ /ALERT LOG/)
    if (findsec) return
    out = out "<section class=\"sec\"><h4>" esc(title) "</h4>"
    insec = 1
}
function close_section() {
    flush_row(); close_table(); close_log()
    if (insec) out = out "</section>"
    insec = 0; findsec = 0; logsec = 0
}
function ensure_section() { if (!insec && !findsec) open_section(implicit) }
function open_table() { close_log(); if (!intable) { out = out "<table class=\"kv\">"; intable = 1 } }
function close_table() { flush_row(); if (intable) out = out "</table>"; intable = 0 }
function open_log() { close_table(); if (!inlog) { out = out "<div class=\"log\">"; inlog = 1 } }
function close_log() { if (inlog) out = out "</div>"; inlog = 0 }
# "name: rest" -> NM, REST
function split_name(v,  k) {
    k = index(v, ": ")
    if (k > 0) { NM = substr(v, 1, k - 1); REST = substr(v, k + 2) } else { NM = v; REST = "" }
}
function add_db(name, role, state, t, a, st,  sev, w) {
    sev = (st == "" || st == "@OFF") ? "none" : sevclass(st)
    w = (sev == "warn" || sev == "crit") ? worse(t, a) : 0
    ndb++
    DB[ndb] = "<tr class=\"r-" sev "\"><td class=\"mono" (st == "@OFF" ? " muted" : "") "\">" esc(name) "</td><td>" esc(role) "</td><td>" (state == "" ? "<span class=\"muted\">&mdash;</span>" : esc(state)) "</td>" \
        cell(t, w == 1, sev) cell(a, w == 2, sev) "<td>" badge(st) "</td></tr>"
}
# The --check component rows. Returns 1 when the row was taken.
function comp_row(  v, sev, role, state, t, a, k, n, parts, j, head, host, pp, pt, name, w) {
    v = P_VAL
    sev = (P_ST == "") ? "none" : sevclass(P_ST)
    if (P_LAB == "Primary") {
        split_name(v); add_db(NM, "Primary", REST, "", "", P_ST); return 1
    }
    if (P_LAB == "Standby") {
        split_name(v); role = "Standby"
        if (NM ~ / \(local\)$/) { sub(/ \(local\)$/, "", NM); role = "Standby (checked host)" }
        if (REST == "disabled in the broker") { add_db(NM, role, "disabled in the broker", "", "", "@OFF"); return 1 }
        state = REST; t = ""; a = ""
        k = index(REST, ", transport ")
        if (k > 0) {
            state = substr(REST, 1, k - 1); t = substr(REST, k + 12)
            k = index(t, ", apply ")
            if (k > 0) { a = substr(t, k + 8); t = substr(t, 1, k - 1) }
            k = index(a, ", ")
            if (k > 0) { state = state substr(a, k); a = substr(a, 1, k - 1) }
        } else if ((k = index(REST, " / ")) > 0) {
            state = ""; t = substr(REST, 1, k - 1); a = substr(REST, k + 3)
        }
        add_db(NM, role, state, t, a, P_ST)
        nsb++
        if (sev == "ok") nsbok++
        if (secs(a) >= 0 && (maxlag == "" || secs(a) > secs(maxlag))) { maxlag = a; maxsev = sev }
        else if (a != "" && secs(a) < 0 && maxlag == "") { maxlag = a; maxsev = sev }
        return 1
    }
    if (P_LAB == "FSFO") {
        n = split(v, parts, ", ")
        if (n >= 2 && parts[2] ~ /^target /) {
            fsfo = 1
            KV = KV kvitem("Fast-start failover", parts[1])
            KV = KV kvitem("Failover target", substr(parts[2], 8))
            state = ""
            for (j = 3; j <= n; j++) state = state (state == "" ? "" : ", ") parts[j]
            if (state != "") KV = KV kvitem("FSFO status", state, sev)
        } else {
            fsfo = 0
            KV = KV kvitem("Fast-start failover", v)
        }
        return 1
    }
    if (P_LAB == "Observer") {
        nobs++
        if (sev == "ok") nobsok++
        k = index(v, " @ ")
        if (k > 0 && match(v, /: last ping primary /)) {
            head = substr(v, 1, k - 1); host = substr(v, k + 3, RSTART - k - 3)
            pp = substr(v, RSTART + RLENGTH); pt = ""
            j = index(pp, ", target ")
            if (j > 0) { pt = substr(pp, j + 9); pp = substr(pp, 1, j - 1) }
            name = head; role = ""
            j = index(head, " (")
            if (j > 0) { name = substr(head, 1, j - 1); role = substr(head, j + 2); sub(/\)$/, "", role) }
            w = (sev == "warn" || sev == "crit") ? worse(pp, pt) : 0
            OB[nobs] = "<tr class=\"r-" sev "\"><td class=\"mono\">" esc(name) "</td><td>" esc(role) "</td><td>" esc(host) "</td>" \
                cell(pp, w == 1, sev, 1) cell(pt, w == 2, sev, 1) "<td>" badge(P_ST) "</td></tr>"
        } else {
            OB[nobs] = "<tr class=\"r-" sev "\"><td colspan=\"5\">" esc(v) "</td><td>" badge(P_ST) "</td></tr>"
        }
        return 1
    }
    if (P_LAB == "Broker") {
        KV = KV kvitem("Broker", v, sev)
        return 1
    }
    return 0
}
function kvitem(label, value, sev) {
    return "<span>" esc(label) " <b" ((sev == "warn" || sev == "crit") ? " class=\"v-" sev "\"" : "") ">" esc(value) "</b></span>"
}
function flush_row(  sev, c) {
    if (!havepend) return
    havepend = 0
    if (P_LAB == "Overall" && P_VAL ~ /^errors=[0-9]+ warnings=[0-9]+$/) {
        c = P_VAL; sub(/^errors=/, "", c); ov_err = c + 0
        c = P_VAL; sub(/.*warnings=/, "", c); ov_warn = c + 0
        have_ov = 1
    }
    if (findsec || P_LAB == "Problem") {
        if (P_LAB == "Error") sev = "crit"
        else if (P_LAB == "Warning") sev = "warn"
        else if (P_LAB == "Info") sev = "info"
        else if (P_LAB == "Problem") sev = sevclass(P_ST)
        else sev = ""
        if (sev != "") { add_finding(sev, P_VAL); return }
        if (findsec) return
    }
    if (check && comp_row()) return
    ensure_section()
    open_table()
    sev = (P_ST == "") ? "none" : sevclass(P_ST)
    out = out "<tr class=\"r-" sev "\"><th>" esc(P_LAB) "</th><td>" esc(P_VAL) "</td><td>" badge(P_ST) "</td></tr>"
}
function misc_line(s) {
    s = trim(s)
    if (s == "") return
    nmisc++
    misc = misc esc(s) "\n"
    if (first_misc == "") first_misc = s
}
# "Label: value" -> kv item, anything else -> bold text
function kvpiece(s,  k) {
    s = trim(s)
    if (s == "") return ""
    k = index(s, ": ")
    if (k > 0 && substr(s, 1, k - 1) ~ /^[A-Za-z][A-Za-z ]*$/) return kvitem(substr(s, 1, k - 1), substr(s, k + 2))
    return "<span><b>" esc(s) "</b></span>"
}
{
    sub(/\r$/, "")
    gsub("\033\\[[0-9;]*m", "")
    L[++n] = $0
}
END {
    check = (lw == 8)
    implicit = check ? "Other" : "Components"
    for (i = 1; i <= n; i++) {
        s = L[i]
        if (s ~ /^[ \t]*$/) { if (inlog) out = out "<div class=\"gap\"></div>"; continue }
        if (is_hline(s)) continue
        # Header: the line right above a rule.
        if (i < n && is_hline(L[i + 1])) { open_section(trim(s)); continue }
        # Title / identity / diag subheader: exactly one leading blank.
        if (substr(s, 1, 1) == " " && substr(s, 2, 1) != " ") {
            t = trim(s)
            if (t ~ /^(Target|Local): /) { meta_line = t; continue }
            if (!insec && !findsec && title == "") { title = t; continue }
            if (insec && !logsec) {
                flush_row(); open_table()
                out = out "<tr class=\"sub\"><th colspan=\"3\">" esc(t) "</th></tr>"
                continue
            }
            misc_line(s); continue
        }
        if (substr(s, 1, 1) != " ") { misc_line(s); continue }
        if (logsec) {
            flush_row(); open_log()
            t = trim(s)
            cls = "ln"
            if (substr(s, 3, 1) != " ") cls = "lh"
            else if (t ~ /^\(/ || t ~ /^\//) cls = "ln muted"
            else if (tolower(t) ~ /ora-|error|fail/) cls = "ln bad"
            if (match(t, /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]/))
                t = "<time>" esc(substr(t, 1, 19)) "</time>" esc(trim(substr(t, 20)))
            else t = esc(t)
            out = out "<div class=\"" cls "\">" t "</div>"
            continue
        }
        # A row: label column, one blank, value, padding, status.
        if (length(s) >= lw + 4 && substr(s, lw + 3, 1) == " " && substr(s, lw + 4, 1) != " ") {
            lab = trim(substr(s, 3, lw))
            rest = substr(s, lw + 4)
            k = index(rest, "  ")
            if (k > 0) { val = substr(rest, 1, k - 1); st = trim(substr(rest, k)) }
            else {
                val = rest; st = ""
                if (match(rest, / (OK|!!|XX|--)$/)) { val = substr(rest, 1, RSTART - 1); st = substr(rest, RSTART + 1) }
            }
            val = trim(val)
            if (lab == "" && st == "" && havepend) { P_VAL = P_VAL " " val; continue }
            flush_row()
            havepend = 1; P_LAB = lab; P_VAL = val; P_ST = st
            continue
        }
        misc_line(s)
    }
    close_section()

    # Identity strip: title words, the Target/Local line, FSFO and broker.
    head = ""
    if (title != "") {
        np = split(title, tp, "  ")
        for (j = 1; j <= np; j++) {
            t = trim(tp[j])
            if (t == "") continue
            if (j == 1) head = head "<span class=\"who\">" esc(t) "</span>"
            else if (t ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) head = head kvitem("At", t)
            else if (check) head = head kvitem("State", t, (t ~ /^NOT /) ? "crit" : (t == "DEGRADED") ? "warn" : "")
            else head = head "<span>" esc(t) "</span>"
        }
    }
    if (meta_line != "") {
        np = split(meta_line, tp, "  [|]  ")
        for (j = 1; j <= np; j++) head = head kvpiece(tp[j])
    }
    head = head KV
    if (head != "") printf "<div class=\"kvline\">%s</div>\n", head
    if (!check && nf > 0) {
        printf "<ul class=\"tfind\">\n"
        for (pass = 1; pass <= 3; pass++) {
            want = (pass == 1) ? "crit" : (pass == 2) ? "warn" : "info"
            for (j = 1; j <= nf; j++) if (F_SEV[j] == want)
                printf "<li><span class=\"badge%s\">%s</span><span>%s</span></li>\n", (want == "info") ? "" : " " want, (want == "crit") ? "Error" : (want == "warn") ? "Warning" : "Info", esc(F_TXT[j])
        }
        printf "</ul>\n"
    }
    if (nmisc > 0) printf "<pre class=\"msgs\">%s</pre>\n", misc
    if (ndb > 0) {
        printf "<div><p class=\"subhead\">Databases</p><div class=\"subtable\"><table><thead><tr><th>Database</th><th>Role</th><th>State</th><th class=\"num\">Transport lag</th><th class=\"num\">Apply lag</th><th>Status</th></tr></thead><tbody>\n"
        for (j = 1; j <= ndb; j++) printf "%s\n", DB[j]
        printf "</tbody></table></div></div>\n"
    }
    if (nobs > 0) {
        printf "<div><p class=\"subhead\">Observers</p><div class=\"subtable\"><table><thead><tr><th>Observer</th><th>Role</th><th>Host</th><th class=\"num\">Ping primary</th><th class=\"num\">Ping target</th><th>Status</th></tr></thead><tbody>\n"
        for (j = 1; j <= nobs; j++) printf "%s\n", OB[j]
        printf "</tbody></table></div></div>\n"
    }
    if (out != "") printf "<div class=\"secs\">%s</div>\n", out

    for (j = 1; j <= nf; j++) { t = F_TXT[j]; gsub(/\t/, " ", t); printf "%s\t%s\n", F_SEV[j], t > findf }
    first_sev = ""; first_txt = ""
    for (pass = 1; pass <= 2 && first_txt == ""; pass++) {
        want = (pass == 1) ? "crit" : "warn"
        for (j = 1; j <= nf; j++) if (F_SEV[j] == want) { first_sev = want; first_txt = F_TXT[j]; break }
    }
    if (first_txt == "" && first_misc != "") { first_sev = "misc"; first_txt = first_misc }
    if (have_ov) { ncrit = ov_err; nwarn = ov_warn }
    gsub(/\t/, " ", first_txt)
    if (check && ndb > 0) {
        f_db = ndb; f_sb = nsb + 0; f_sbok = nsbok + 0; f_lag = (maxlag == "") ? "" : fmt_lag(maxlag); f_lsev = (maxlag == "") ? "" : maxsev
        f_obs = nobs + 0; f_obsok = nobsok + 0; f_fsfo = (fsfo == "") ? "" : fsfo
    } else { f_db = ""; f_sb = ""; f_sbok = ""; f_lag = ""; f_lsev = ""; f_obs = ""; f_obsok = ""; f_fsfo = "" }
    printf "%d\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", ncrit, nwarn, ninfo, nz(first_sev), nz(f_db), nz(f_sb), nz(f_sbok), nz(f_lag), nz(f_lsev), nz(f_obs), nz(f_obsok), nz(f_fsfo), first_txt > meta
}
AWKEOF
)
# $1 = report text file, $2 = label width, $3 = meta output file,
# $4 = findings output file (optional)
html_render_target_body() {
    LC_ALL=C awk -v lw="$2" -v hc="─" -v meta="$3" -v findf="${4:-/dev/null}" "$DG_HTML_AWK" "$1"
}

html_css() {
    cat <<'CSS'
*, *::before, *::after { box-sizing: border-box; min-width: 0; }
:root {
  color-scheme: light dark;
  --background: #ffffff; --foreground: #09090b;
  --card: #ffffff; --muted: #f4f4f5; --muted-foreground: #71717a;
  --border: #e4e4e7; --ring: #a1a1aa;
  --ok: #16a34a; --ok-bg: #f0fdf4; --ok-border: #bbf7d0; --ok-fg: #15803d;
  --warn: #f59e0b; --warn-bg: #fffbeb; --warn-border: #fde68a; --warn-fg: #b45309;
  --crit: #dc2626; --crit-bg: #fef2f2; --crit-border: #fecaca; --crit-fg: #b91c1c;
  --none-bg: #f4f4f5; --none-border: #e4e4e7; --none-fg: #52525b;
  --shadow: 0 1px 2px 0 rgb(0 0 0 / 0.05);
  --radius: 0.625rem;
  --sans: "Geist", "Inter", ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  --mono: "Geist Mono", ui-monospace, "SF Mono", "Cascadia Mono", Menlo, Consolas, "Liberation Mono", monospace;
}
@media (prefers-color-scheme: dark) {
  :root {
    --background: #09090b; --foreground: #fafafa;
    --card: #09090b; --muted: #18181b; --muted-foreground: #a1a1aa;
    --border: #27272a; --ring: #52525b;
    --ok: #22c55e; --ok-bg: rgb(34 197 94 / 0.1); --ok-border: rgb(34 197 94 / 0.25); --ok-fg: #4ade80;
    --warn: #f59e0b; --warn-bg: rgb(245 158 11 / 0.1); --warn-border: rgb(245 158 11 / 0.25); --warn-fg: #fbbf24;
    --crit: #ef4444; --crit-bg: rgb(239 68 68 / 0.1); --crit-border: rgb(239 68 68 / 0.3); --crit-fg: #f87171;
    --none-bg: #18181b; --none-border: #27272a; --none-fg: #a1a1aa;
    --shadow: none;
  }
}
html { -webkit-text-size-adjust: 100%; }
body { margin: 0; background: var(--background); color: var(--foreground); font: 14px/1.5 var(--sans); -webkit-font-smoothing: antialiased; }
a { color: inherit; text-decoration: none; }
:focus-visible { outline: 2px solid var(--ring); outline-offset: 2px; border-radius: 6px; }
.container { max-inline-size: 72rem; margin-inline: auto; padding: 32px 24px 64px; display: grid; gap: 24px; }
@media (max-width: 640px) { .container { padding: 20px 16px 48px; gap: 20px; } }
.mono { font-family: var(--mono); font-size: 13px; }
.muted { color: var(--muted-foreground); }
svg.i { inline-size: 16px; block-size: 16px; flex: none; }

.page-head { display: flex; flex-wrap: wrap; justify-content: space-between; align-items: flex-end; gap: 12px 24px; }
h1 { font-size: 24px; line-height: 32px; font-weight: 600; letter-spacing: -0.025em; margin: 0; }
.page-head p { margin: 4px 0 0; color: var(--muted-foreground); }
.meta { display: flex; flex-wrap: wrap; gap: 8px; }

.badge { display: inline-flex; align-items: center; gap: 6px; border: 1px solid var(--none-border); background: var(--none-bg); color: var(--none-fg); border-radius: 6px; padding: 2px 8px; font-size: 12px; font-weight: 500; line-height: 16px; white-space: nowrap; }
.badge .dot { inline-size: 6px; block-size: 6px; border-radius: 50%; background: currentColor; }
.badge.ok { background: var(--ok-bg); border-color: var(--ok-border); color: var(--ok-fg); }
.badge.warn { background: var(--warn-bg); border-color: var(--warn-border); color: var(--warn-fg); }
.badge.crit, .badge.fail { background: var(--crit-bg); border-color: var(--crit-border); color: var(--crit-fg); }
.badge.outline { background: transparent; border-color: var(--border); color: var(--foreground); }

.alert { --a-bg: var(--crit-bg); --a-border: var(--crit-border); --a-fg: var(--crit-fg);
  display: grid; grid-template-columns: 16px 1fr; gap: 2px 12px; padding: 14px 16px; border: 1px solid var(--a-border); border-radius: var(--radius); background: var(--a-bg); color: var(--a-fg); }
.alert.warn { --a-bg: var(--warn-bg); --a-border: var(--warn-border); --a-fg: var(--warn-fg); }
.alert.ok { --a-bg: var(--ok-bg); --a-border: var(--ok-border); --a-fg: var(--ok-fg); }
.alert svg { margin-block-start: 2px; }
.alert h2 { font-size: 14px; font-weight: 600; margin: 0; line-height: 20px; }
.alert p { grid-column: 2; margin: 0; font-size: 14px; color: color-mix(in srgb, var(--a-fg) 85%, var(--foreground)); }

.card { background: var(--card); border: 1px solid var(--border); border-radius: var(--radius); box-shadow: var(--shadow); }
.card-head { padding: 20px 24px 0; display: flex; justify-content: space-between; align-items: flex-start; gap: 12px; flex-wrap: wrap; }
.card-head h3 { font-size: 16px; font-weight: 600; line-height: 24px; margin: 0; letter-spacing: -0.01em; }
.card-head p { margin: 2px 0 0; color: var(--muted-foreground); font-size: 14px; }
.card-body { padding: 16px 24px 24px; }
.card-body.flush { padding: 16px 0 8px; }
@media (max-width: 640px) { .card-head { padding: 16px 16px 0; } .card-body { padding: 12px 16px 16px; } .card-body.flush { padding: 12px 0 4px; } }

.stats { display: grid; gap: 16px; grid-template-columns: repeat(4, 1fr); }
@media (max-width: 860px) { .stats { grid-template-columns: repeat(2, 1fr); gap: 12px; } }
.stat { padding: 20px 24px; }
.stat .top { display: flex; justify-content: space-between; align-items: center; font-size: 14px; font-weight: 500; }
.stat .top svg { color: var(--muted-foreground); }
.stat .val { font-size: 24px; line-height: 32px; font-weight: 700; margin-block-start: 6px; font-variant-numeric: tabular-nums; }
.stat .sub { font-size: 12px; color: var(--muted-foreground); }
.stat.ok .top svg { color: var(--ok); } .stat.warn .top svg { color: var(--warn); } .stat.crit .top svg { color: var(--crit); }
.stat.zero .val { color: var(--muted-foreground); }
@media (max-width: 640px) { .stat { padding: 16px; } }

.toolbar { display: flex; flex-wrap: wrap; justify-content: space-between; gap: 12px; align-items: center; margin-block-end: 12px; }
.toolbar h3 { margin: 0; font-size: 16px; font-weight: 600; }
.tabs { display: inline-flex; background: var(--muted); border-radius: 8px; padding: 3px; }
.tabs button { font: 500 14px var(--sans); color: var(--muted-foreground); background: none; border: 0; border-radius: 6px; padding: 4px 12px; cursor: pointer; }
.tabs button[aria-selected="true"] { background: var(--background); color: var(--foreground); box-shadow: 0 1px 3px rgb(0 0 0 / 0.1); }
.btns { display: flex; gap: 8px; }
.btn { font: 500 14px var(--sans); display: inline-flex; align-items: center; gap: 8px; color: var(--foreground); background: var(--background); border: 1px solid var(--border); border-radius: 8px; padding: 6px 12px; cursor: pointer; box-shadow: var(--shadow); }
.btn:hover { background: var(--muted); }

.table-wrap { overflow-x: auto; }
table { inline-size: 100%; border-collapse: collapse; font-size: 14px; }
th { text-align: start; font-weight: 500; color: var(--muted-foreground); padding: 0 12px; block-size: 40px; white-space: nowrap; border-block-end: 1px solid var(--border); }
td { padding: 12px; border-block-end: 1px solid var(--border); vertical-align: middle; }
tbody tr:last-child td { border-block-end: 0; }
td.num, th.num { text-align: end; font-variant-numeric: tabular-nums; white-space: nowrap; }
.fleet th:first-child, .fleet td:first-child { padding-inline-start: 24px; }
.fleet th:last-child, .fleet td:last-child { padding-inline-end: 24px; }
.fleet tbody tr { cursor: pointer; }
.fleet tbody tr:hover { background: color-mix(in srgb, var(--muted) 60%, transparent); }
.fleet .tname { font-weight: 500; }
.fleet .tsub { font-size: 12px; color: var(--muted-foreground); }
.fleet td.key { color: var(--muted-foreground); max-inline-size: 26rem; }
.fleet td.key span { display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 2; line-clamp: 2; overflow: hidden; }
.v-warn { color: var(--warn-fg); font-weight: 500; }
.v-crit { color: var(--crit-fg); font-weight: 500; }
@media (max-width: 760px) { .fleet .hide-sm { display: none; } .fleet th:first-child, .fleet td:first-child { padding-inline-start: 16px; } .fleet th:last-child, .fleet td:last-child { padding-inline-end: 16px; } }

.findings { list-style: none; margin: 0; padding: 0; }
.findings li { display: grid; grid-template-columns: 84px minmax(64px, max-content) 1fr; gap: 12px; align-items: baseline; padding: 12px 0; border-block-end: 1px solid var(--border); }
.findings li:first-child { padding-block-start: 0; }
.findings li:last-child { border-block-end: 0; padding-block-end: 0; }
.findings li .badge { justify-self: start; }
.findings li .t { font-weight: 500; }
.findings li .t:hover { text-decoration: underline; text-underline-offset: 3px; }
.findings li p { margin: 0; overflow-wrap: anywhere; }
.findings li p span { display: block; color: var(--muted-foreground); font-size: 13px; }
@media (max-width: 560px) { .findings li { grid-template-columns: auto 1fr; } .findings li p { grid-column: 1 / -1; } }
.empty { margin: 0; color: var(--muted-foreground); }

details.acc { overflow: clip; scroll-margin-block-start: 16px; }
details.acc + details.acc { margin-block-start: 12px; }
details.acc > summary { list-style: none; cursor: pointer; display: flex; align-items: center; gap: 8px 12px; padding: 16px 24px; flex-wrap: wrap; }
details.acc > summary::-webkit-details-marker { display: none; }
details.acc > summary .chev { color: var(--muted-foreground); transition: transform .2s; }
details.acc[open] > summary .chev { transform: rotate(180deg); }
details.acc > summary .name { font-weight: 600; font-size: 15px; }
details.acc > summary .right { margin-inline-start: auto; display: flex; gap: 16px; align-items: center; color: var(--muted-foreground); font-size: 13px; font-variant-numeric: tabular-nums; }
details.acc[open] > summary { border-block-end: 1px solid var(--border); }
details.acc .inner { padding: 20px 24px 24px; display: grid; gap: 20px; }
@media (max-width: 640px) { details.acc > summary { padding: 14px 16px; } details.acc .inner { padding: 16px; } }
@media (prefers-reduced-motion: reduce) { details.acc > summary .chev { transition: none; } }

.kvline { display: flex; flex-wrap: wrap; gap: 8px 24px; font-size: 13px; color: var(--muted-foreground); }
.kvline b { font-weight: 500; color: var(--foreground); }
.kvline b.v-warn { color: var(--warn-fg); } .kvline b.v-crit { color: var(--crit-fg); }
.kvline .who { color: var(--foreground); font-weight: 600; }
.subhead { font-size: 14px; font-weight: 600; margin: 0 0 8px; }
.subtable { border: 1px solid var(--border); border-radius: 8px; overflow-x: auto; }
.subtable th { block-size: 36px; background: var(--muted); font-size: 13px; }
.subtable td { padding-block: 10px; }
.subtable th:first-child, .subtable td:first-child { padding-inline-start: 12px; }
.subtable th:last-child, .subtable td:last-child { padding-inline-end: 12px; }

ul.tfind { list-style: none; margin: 0; padding: 0; border: 1px solid var(--border); border-radius: 8px; overflow: hidden; }
ul.tfind li { display: flex; gap: 12px; align-items: baseline; padding: 10px 12px; border-block-end: 1px solid var(--border); }
ul.tfind li:last-child { border-block-end: 0; }
ul.tfind li .badge { flex: none; min-inline-size: 64px; justify-content: center; }

.secs { display: grid; gap: 16px; grid-template-columns: repeat(auto-fill, minmax(min(100%, 26rem), 1fr)); align-items: start; }
section.sec { border: 1px solid var(--border); border-radius: 8px; overflow: hidden; }
section.sec h4 { margin: 0; font-size: 13px; font-weight: 600; padding: 8px 12px; background: var(--muted); border-block-end: 1px solid var(--border); }
table.kv { font-size: 13px; }
table.kv th { block-size: auto; padding: 8px 12px; font-weight: 400; inline-size: 38%; vertical-align: top; white-space: normal; border-block-end: 1px solid var(--border); }
table.kv td { padding: 8px 12px; vertical-align: top; overflow-wrap: anywhere; }
table.kv td:last-child { inline-size: 1%; text-align: end; white-space: nowrap; padding-inline-start: 0; }
table.kv tr:last-child > * { border-block-end: 0; }
table.kv tr.sub th { background: var(--muted); color: var(--foreground); font-weight: 600; }
table.kv tr.r-crit td:nth-child(2) { color: var(--crit-fg); }
table.kv tr.r-warn td:nth-child(2) { color: var(--warn-fg); }
.log { padding: 8px 12px; font: 12.5px/1.6 var(--mono); }
.log .lh { font-family: var(--sans); font-size: 13px; font-weight: 600; margin-block-start: 4px; }
.log .ln { padding-inline-start: 12px; white-space: pre-wrap; overflow-wrap: anywhere; }
.log .bad { color: var(--crit-fg); }
.log time { color: var(--muted-foreground); margin-inline-end: 12px; }
.log .gap { block-size: 6px; }

.error-box { border: 1px solid var(--crit-border); background: var(--crit-bg); color: var(--crit-fg); border-radius: 8px; padding: 12px 16px; }
.error-box p { margin: 0; font-weight: 500; }
pre.msgs { margin: 0; padding: 12px 16px; border: 1px solid var(--border); border-radius: 8px; background: var(--muted); font: 12.5px/1.6 var(--mono); white-space: pre-wrap; overflow-wrap: anywhere; }
details.raw > summary { cursor: pointer; color: var(--muted-foreground); font-size: 13px; font-weight: 500; inline-size: fit-content; display: inline-flex; gap: 6px; align-items: center; }
details.raw > summary::-webkit-details-marker { display: none; }
details.raw[open] > summary svg { transform: rotate(90deg); }
details.raw pre { margin: 10px 0 0; padding: 14px 16px; background: var(--muted); border-radius: 8px; font: 12.5px/1.6 var(--mono); overflow-x: auto; }

body.attn .is-ok { display: none; }
footer { color: var(--muted-foreground); font-size: 13px; border-block-start: 1px solid var(--border); padding-block-start: 16px; display: flex; flex-wrap: wrap; gap: 4px 24px; }
@media print {
  .tabs, .btns { display: none; }
  details.acc, .card { break-inside: avoid; box-shadow: none; }
}
CSS
}

html_js() {
    cat <<'JS'
(function () {
  var body = document.body;
  function open(sel, scroll) {
    var d = document.querySelector(sel);
    if (!d) return;
    d.open = true;
    if (scroll) d.scrollIntoView({ block: 'start' });
  }
  document.addEventListener('click', function (ev) {
    var t = ev.target.closest('button[data-f]');
    if (t) {
      body.classList.toggle('attn', t.getAttribute('data-f') === 'attn');
      var bs = t.parentNode.querySelectorAll('button');
      for (var i = 0; i < bs.length; i++) bs[i].setAttribute('aria-selected', bs[i] === t ? 'true' : 'false');
      return;
    }
    var x = ev.target.closest('button[data-x]');
    if (x) {
      var ds = document.querySelectorAll('details.acc');
      for (var j = 0; j < ds.length; j++) ds[j].open = x.getAttribute('data-x') === '1';
      return;
    }
    var a = ev.target.closest('a[href^="#t"]');
    if (a) { open(a.getAttribute('href'), false); return; }
    var r = ev.target.closest('tr[data-href]');
    if (r) open(r.getAttribute('data-href'), true);
  });
  window.addEventListener('beforeprint', function () {
    var ds = document.querySelectorAll('details');
    for (var i = 0; i < ds.length; i++) ds[i].open = true;
  });
})();
JS
}

# Inline icons (24x24 stroke paths).
html_icon() {
    local p
    case "$1" in
        alert)  p='<circle cx="12" cy="12" r="10"/><path d="M12 8v4"/><path d="M12 16h.01"/>' ;;
        check)  p='<circle cx="12" cy="12" r="10"/><path d="m9 12 2 2 4-4"/>' ;;
        warn)   p='<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/><path d="M12 9v4"/><path d="M12 17h.01"/>' ;;
        x)      p='<circle cx="12" cy="12" r="10"/><path d="m15 9-6 6"/><path d="m9 9 6 6"/>' ;;
        db)     p='<ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M3 5v14a9 3 0 0 0 18 0V5"/><path d="M3 12a9 3 0 0 0 18 0"/>' ;;
        down)   p='<path d="m6 9 6 6 6-6"/>' ;;
        right)  p='<path d="m9 18 6-6-6-6"/>' ;;
    esac
    printf '<svg class="i%s" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">%s</svg>' "${2:+ $2}" "$p"
}

# rc -> "class<TAB>label<TAB>detail" for a target's result badge.
html_result_of() {
    case "$1" in
        0) printf 'ok\tHealthy\t' ;;
        1) printf 'warn\tWarning\t' ;;
        2) printf 'crit\tCritical\t' ;;
        *) printf 'fail\tNot checked\t%s' "$(printf '%s' "$2" | sed 's/^FAILED *//; s/^(//; s/)$//')" ;;
    esac
}

# "n thing" / "n things"
html_plural() { if [[ "$1" -eq 1 ]]; then printf '%s %s' "$1" "$2"; else printf '%s %ss' "$1" "$2"; fi; }

# Writes the report from the wrapper's run state: NRUN, R_* (per result),
# ALL_CHECK, WORST, CONFIG_FILE, RUN_STARTED, FLEET_TARGET_TIMEOUT, HTML_WORK
# (holds out.<target index>). $1 = output file (written via a temp file + mv).
html_write_report() {
    local dest="$1" tmp="$1.tmp.$$" i k idx lw cls label detail open rank
    local sev_e sev_w sev_i fsev ndb nsb nsbok mlag mlsev nobs nobsok fsfo ftxt
    local n_ok=0 n_warn=0 n_crit=0 n_fail=0 n_attn vcls vhead vtext bad="" degraded=""
    local generated host html_mode any_check=false any_review=false tot_db=0 tot_obs=0
    local ORDER=() fsev_l ftext_l n_find=0 n_find_t=0 find_html="" seen=""
    generated="$(date '+%Y-%m-%d %H:%M:%S %Z')"
    host="$(hostname 2>/dev/null || uname -n 2>/dev/null || printf 'unknown')"

    # Pass 1: render every detail body, its meta line and its findings.
    i=0
    while [[ $i -lt $NRUN ]]; do
        idx="${R_IDX[$i]}"
        case "${R_MODE[$i]}" in */check) lw=8; any_check=true ;; *) lw=24; any_review=true ;; esac
        [[ -f "$HTML_WORK/out.$idx" ]] || : > "$HTML_WORK/out.$idx"
        html_render_target_body "$HTML_WORK/out.$idx" "$lw" "$HTML_WORK/meta.$idx" "$HTML_WORK/find.$idx" > "$HTML_WORK/body.$idx" || return 1
        IFS=$'\t' read -r sev_e sev_w sev_i fsev ndb nsb nsbok mlag mlsev nobs nobsok fsfo ftxt < "$HTML_WORK/meta.$idx" || true
        [[ "$ndb" =~ ^[0-9]+$ ]] && tot_db=$((tot_db + ndb))
        [[ "$nobs" =~ ^[0-9]+$ ]] && tot_obs=$((tot_obs + nobs))
        case "${R_RC[$i]}" in
            0) n_ok=$((n_ok + 1)) ;;
            1) n_warn=$((n_warn + 1)); degraded="${degraded:+$degraded, }${R_NAME[$i]}" ;;
            2) n_crit=$((n_crit + 1)); bad="${bad:+$bad, }${R_NAME[$i]}" ;;
            *) n_fail=$((n_fail + 1)); bad="${bad:+$bad, }${R_NAME[$i]}" ;;
        esac
        i=$((i + 1))
    done
    n_attn=$((NRUN - n_ok))

    # Worst first: critical and not checked, then warnings, then healthy;
    # config order within a group.
    for rank in 0 1 2; do
        i=0
        while [[ $i -lt $NRUN ]]; do
            case "${R_RC[$i]}" in 0) k=2 ;; 1) k=1 ;; *) k=0 ;; esac
            [[ $k -eq $rank ]] && ORDER+=("$i")
            i=$((i + 1))
        done
    done

    # Fleet-wide findings: failures and errors first, then warnings.
    for rank in crit warn; do
        for i in ${ORDER[@]+"${ORDER[@]}"}; do
            idx="${R_IDX[$i]}"
            if [[ "$rank" == crit ]]; then
                case "${R_RC[$i]}" in 0|1|2) ;; *)
                    IFS=$'\t' read -r cls label detail <<< "$(html_result_of "${R_RC[$i]}" "${R_PLAIN[$i]}")"
                    IFS=$'\t' read -r sev_e sev_w sev_i fsev ndb nsb nsbok mlag mlsev nobs nobsok fsfo ftxt < "$HTML_WORK/meta.$idx" || true
                    find_html="$find_html<li class=\"f-crit\"><span class=\"badge crit\">Failed</span><a class=\"t\" href=\"#t$idx\">$(html_esc_s "${R_NAME[$i]}")</a><p>$(html_esc_s "$detail")$([[ "$fsev" == misc ]] && printf '<span class="mono">%s</span>' "$(html_esc_s "$ftxt")")</p></li>"$'\n'
                    n_find=$((n_find + 1)); seen="$seen $idx" ;;
                esac
            fi
            [[ -s "$HTML_WORK/find.$idx" ]] || continue
            while IFS=$'\t' read -r fsev_l ftext_l; do
                [[ "$fsev_l" == "$rank" ]] || continue
                find_html="$find_html<li><span class=\"badge $rank\">$([[ "$rank" == crit ]] && printf Error || printf Warning)</span><a class=\"t\" href=\"#t$idx\">$(html_esc_s "${R_NAME[$i]}")</a><p>$(html_esc_s "$ftext_l")</p></li>"$'\n'
                n_find=$((n_find + 1))
                case " $seen " in *" $idx "*) ;; *) seen="$seen $idx" ;; esac
            done < "$HTML_WORK/find.$idx"
        done
    done
    for k in $seen; do n_find_t=$((n_find_t + 1)); done

    if $ALL_CHECK; then html_mode="running-state check"
    elif [[ "$any_check" == true ]]; then html_mode="check and configuration review"
    else html_mode="configuration review"; fi
    if [[ -n "$bad" ]]; then vcls="crit"; elif [[ -n "$degraded" ]]; then vcls="warn"; else vcls="ok"; fi
    if $ALL_CHECK; then
        case "$vcls" in
            crit) vhead="Data Guard is NOT running correctly on $((n_crit + n_fail)) of $NRUN target(s)"; vtext="Problem or not checked: $bad${degraded:+. Degraded: $degraded}" ;;
            warn) vhead="Data Guard is running but DEGRADED"; vtext="Degraded: $degraded" ;;
            ok)   vhead="Data Guard is running as configured"; vtext="All $NRUN target(s) checked, no errors or warnings." ;;
        esac
    else
        case "$vcls" in
            crit) vhead="Problems on $((n_crit + n_fail)) of $NRUN target(s)"; vtext="$bad${degraded:+. Warnings: $degraded}" ;;
            warn) vhead="Warnings on $n_warn of $NRUN target(s)"; vtext="$degraded" ;;
            ok)   vhead="All $NRUN target(s) healthy"; vtext="No errors or warnings." ;;
        esac
    fi

    {
        printf '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
        printf '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        printf '<meta name="color-scheme" content="light dark">\n'
        printf '<title>Data Guard fleet report · %s · %s</title>\n' "$(html_esc_s "$(basename "$CONFIG_FILE")")" "$(html_esc_s "$generated")"
        printf '<style>\n'; html_css; printf '</style>\n</head>\n<body>\n<div class="container">\n'

        printf '<header class="page-head"><div><h1>Data Guard fleet report</h1>'
        printf '<p>%s · %s · started %s, finished %s</p></div>' "$(html_esc_s "$(basename "$CONFIG_FILE")")" "$html_mode" "$(html_esc_s "$RUN_STARTED")" "$(date '+%H:%M:%S')"
        printf '<div class="meta"><span class="badge outline">host %s</span><span class="badge outline">exit code %s</span></div></header>\n' \
            "$(html_esc_s "$host")" "$WORST"

        printf '<div class="alert %s" role="%s">%s<h2>%s</h2><p>%s</p></div>\n' \
            "$vcls" "$([[ "$vcls" == ok ]] && printf status || printf alert)" \
            "$(case "$vcls" in ok) html_icon check ;; warn) html_icon warn ;; *) html_icon alert ;; esac)" \
            "$(html_esc_s "$vhead")" "$(html_esc_s "$vtext")"

        printf '<div class="stats">\n'
        printf '<div class="card stat"><div class="top">Targets %s</div><div class="val">%s</div><div class="sub">%s</div></div>\n' \
            "$(html_icon db)" "$NRUN" \
            "$(if [[ "$any_check" == true ]]; then printf '%s, %s' "$(html_plural "$tot_db" database)" "$(html_plural "$tot_obs" observer)"; else printf '%s' "$html_mode"; fi)"
        printf '<div class="card stat ok%s"><div class="top">Healthy %s</div><div class="val">%s</div><div class="sub">no errors or warnings</div></div>\n' \
            "$([[ $n_ok -eq 0 ]] && printf ' zero')" "$(html_icon check)" "$n_ok"
        printf '<div class="card stat warn%s"><div class="top">Warning %s</div><div class="val">%s</div><div class="sub">degraded, still running</div></div>\n' \
            "$([[ $n_warn -eq 0 ]] && printf ' zero')" "$(html_icon warn)" "$n_warn"
        printf '<div class="card stat crit%s"><div class="top">Critical %s</div><div class="val">%s</div><div class="sub">%s failing, %s not checked</div></div>\n' \
            "$([[ $((n_crit + n_fail)) -eq 0 ]] && printf ' zero')" "$(html_icon x)" "$((n_crit + n_fail))" "$n_crit" "$n_fail"
        printf '</div>\n'

        # Targets table
        printf '<div class="card"><div class="card-head"><div><h3>Targets</h3><p>One row per target, worst first.</p></div>'
        printf '<div class="tabs" role="tablist"><button type="button" role="tab" data-f="all" aria-selected="true">All (%s)</button><button type="button" role="tab" data-f="attn" aria-selected="false">Needs attention (%s)</button></div></div>\n' "$NRUN" "$n_attn"
        printf '<div class="card-body flush"><div class="table-wrap"><table class="fleet"><thead><tr><th>Status</th><th>Target</th>'
        [[ "$any_check" == true ]] && printf '<th class="hide-sm">Standbys</th><th class="hide-sm">Max apply lag</th><th class="hide-sm">Observers</th>'
        [[ "$any_review" == true ]] && printf '<th class="hide-sm">Findings</th>'
        printf '<th class="hide-sm">Key finding</th><th class="num">Time</th></tr></thead><tbody>\n'
        for i in ${ORDER[@]+"${ORDER[@]}"}; do
            idx="${R_IDX[$i]}"
            IFS=$'\t' read -r cls label detail <<< "$(html_result_of "${R_RC[$i]}" "${R_PLAIN[$i]}")"
            IFS=$'\t' read -r sev_e sev_w sev_i fsev ndb nsb nsbok mlag mlsev nobs nobsok fsfo ftxt < "$HTML_WORK/meta.$idx" || { sev_e=0; sev_w=0; ndb=-; ftxt=""; }
            printf '<tr class="%s" data-href="#t%s"><td><span class="badge %s"><span class="dot"></span>%s</span></td>' \
                "$([[ "$cls" == ok ]] && printf 'is-ok')" "$idx" "$cls" "$label"
            printf '<td><a href="#t%s" class="tname">%s</a><div class="tsub">%s</div></td>' \
                "$idx" "$(html_esc_s "${R_NAME[$i]}")" "$(html_esc_s "${R_METHOD[$i]}")"
            if [[ "$any_check" == true ]]; then
                if [[ "$ndb" == "-" || "$cls" == fail ]]; then
                    printf '<td class="hide-sm muted">&mdash;</td><td class="hide-sm muted">&mdash;</td><td class="hide-sm muted">&mdash;</td>'
                else
                    printf '<td class="hide-sm%s">%s</td>' "$([[ "$nsb" != "$nsbok" ]] && printf ' v-warn')" \
                        "$([[ "$nsb" == 0 ]] && printf 'none' || printf '%s / %s OK' "$nsbok" "$nsb")"
                    printf '<td class="hide-sm%s">%s</td>' "$(case "$mlsev" in warn|crit) printf ' v-%s' "$mlsev" ;; esac)" \
                        "$([[ "$mlag" == "-" ]] && printf '&mdash;' || printf '%s' "$mlag")"
                    if [[ "$fsfo" == 0 && "$nobs" == 0 ]]; then
                        printf '<td class="hide-sm muted">no FSFO</td>'
                    else
                        printf '<td class="hide-sm%s">%s / %s OK</td>' "$([[ "$nobs" != "$nobsok" ]] && printf ' v-crit')" "$nobsok" "$nobs"
                    fi
                fi
            fi
            if [[ "$any_review" == true ]]; then
                if [[ "$cls" == fail || "${R_MODE[$i]}" == */check ]]; then
                    printf '<td class="hide-sm muted">&mdash;</td>'
                else
                    printf '<td class="hide-sm"><span class="%s">%s</span>, <span class="%s">%s</span></td>' \
                        "$([[ ${sev_e:-0} -gt 0 ]] && printf v-crit)" "$(html_plural "${sev_e:-0}" error)" \
                        "$([[ ${sev_w:-0} -gt 0 ]] && printf v-warn)" "$(html_plural "${sev_w:-0}" warning)"
                fi
            fi
            if [[ "$cls" == fail ]]; then
                ftxt="$detail${ftxt:+: $ftxt}"
            elif [[ "$cls" == ok ]]; then
                ftxt=""
            fi
            printf '<td class="key hide-sm"><span>%s</span></td><td class="num">%ss</td></tr>\n' "$(html_esc_s "${ftxt:-—}")" "${R_SECS[$i]}"
        done
        printf '</tbody></table></div></div></div>\n'

        # Findings
        printf '<div class="card"><div class="card-head"><div><h3>Findings</h3><p>%s</p></div></div><div class="card-body">' \
            "$(if [[ $n_find -gt 0 ]]; then printf '%s on %s, most serious first.' "$(html_plural "$n_find" finding)" "$(html_plural "$n_find_t" target)"; else printf 'Errors and warnings from every target.'; fi)"
        if [[ $n_find -gt 0 ]]; then
            printf '<ul class="findings">\n%s</ul>' "$find_html"
        else
            printf '<p class="empty">No errors or warnings.</p>'
        fi
        printf '</div></div>\n'

        # Details
        printf '<div><div class="toolbar"><h3>Details</h3><div class="btns"><button class="btn" type="button" data-x="1">Expand all</button><button class="btn" type="button" data-x="0">Collapse all</button></div></div>\n'
        for i in ${ORDER[@]+"${ORDER[@]}"}; do
            idx="${R_IDX[$i]}"
            IFS=$'\t' read -r cls label detail <<< "$(html_result_of "${R_RC[$i]}" "${R_PLAIN[$i]}")"
            IFS=$'\t' read -r sev_e sev_w sev_i fsev ndb nsb nsbok mlag mlsev nobs nobsok fsfo ftxt < "$HTML_WORK/meta.$idx" || { sev_e=0; sev_w=0; }
            [[ "$cls" == ok ]] && open="" || open=" open"
            printf '<details class="card acc%s" id="t%s"%s><summary>' "$([[ "$cls" == ok ]] && printf ' is-ok')" "$idx" "$open"
            printf '<span class="badge %s"><span class="dot"></span>%s</span><span class="name">%s</span><span class="muted">%s · %s</span>' \
                "$cls" "$label" "$(html_esc_s "${R_NAME[$i]}")" "$(html_esc_s "${R_METHOD[$i]}")" "$(html_esc_s "${R_MODE[$i]}")"
            printf '<span class="right">'
            if [[ "$cls" == fail ]]; then
                printf '<span>%s</span>' "$(html_esc_s "$detail")"
            elif [[ ${sev_e:-0} -gt 0 || ${sev_w:-0} -gt 0 ]]; then
                printf '<span>%s · %s</span>' "$(html_plural "${sev_e:-0}" error)" "$(html_plural "${sev_w:-0}" warning)"
            fi
            printf '<span>%ss</span>%s</span></summary>\n<div class="inner">\n' "${R_SECS[$i]}" "$(html_icon down chev)"
            [[ "$cls" == fail ]] && printf '<div class="error-box"><p>The check did not complete: %s</p></div>\n' "$(html_esc_s "$detail")"
            cat "$HTML_WORK/body.$idx"
            if [[ -s "$HTML_WORK/out.$idx" ]]; then
                printf '<details class="raw"><summary>%sRaw output</summary><pre>' "$(html_icon right)"
                sed $'s/\033\\[[0-9;]*m//g; s/\r$//' "$HTML_WORK/out.$idx" | html_esc
                printf '</pre></details>\n'
            else
                printf '<pre class="msgs">(no output)</pre>\n'
            fi
            printf '</div></details>\n'
        done
        printf '</div>\n'

        printf '<footer><span>Generated by dg_fleet_check.sh, exit code %s</span><span>Config %s</span><span>Per-target timeout %ss</span></footer>\n' \
            "$WORST" "$(html_esc_s "$CONFIG_FILE")" "$FLEET_TARGET_TIMEOUT"
        printf '</div>\n<script>\n'; html_js; printf '</script>\n</body>\n</html>\n'
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
}
