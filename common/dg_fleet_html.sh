#!/usr/bin/env bash
# =============================================================================
# HTML report for dg_fleet_check.sh (--html). Sourced by the wrapper only; it
# runs on the host that runs the fleet check and is NOT shipped to DB hosts.
#
# The per-target reports are the tools' own --no-color text. They are parsed
# back into structure here (section headers = the line above a rule of "─",
# rows = label column / value / trailing status, "Error"/"Warning"/"Info"/
# "Problem" rows = findings) so the engine stays untouched and an older engine
# copy (remote_dir) still renders. Anything that does not parse is kept as a
# plain message line, and every card carries the raw text as well.
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

# One target's text report -> card body HTML on stdout. -v lw = the label
# column width (24, or 8 in --check), -v meta = file that receives one line
# "errors<TAB>warnings<TAB>infos<TAB>first-severity<TAB>first-finding".
DG_HTML_AWK=$(cat <<'AWKEOF'
function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
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
    if (u == "!!") return "WARN"
    if (u == "XX") return "FAIL"
    if (u == "--") return "INFO"
    return u
}
function pill(st) { return "<span class=\"pill " sevclass(st) "\">" esc(stlabel(st)) "</span>" }
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
    out = out "<section class=\"sec\"><h3>" esc(title) "</h3>"
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
    open_table()
    sev = (P_ST == "") ? "none" : sevclass(P_ST)
    out = out "<tr class=\"r-" sev "\"><th>" esc(P_LAB) "</th><td>" esc(P_VAL) "</td><td>" (P_ST == "" ? "" : pill(P_ST)) "</td></tr>"
}
function misc_line(s) {
    s = trim(s)
    if (s == "") return
    nmisc++
    misc = misc esc(s) "\n"
    if (first_misc == "") first_misc = s
}
{
    sub(/\r$/, "")
    gsub("\033\\[[0-9;]*m", "")
    L[++n] = $0
}
END {
    implicit = "Components"
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
            else if (t ~ /^\(/ || t ~ /^\//) cls = "ln dim"
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
            flush_row(); ensure_section()
            havepend = 1; P_LAB = lab; P_VAL = val; P_ST = st
            continue
        }
        misc_line(s)
    }
    close_section()

    if (title != "" || meta_line != "") {
        printf "<div class=\"tmeta\">"
        if (title != "") {
            np = split(title, tp, "  ")
            printf "<strong>%s</strong>", esc(trim(tp[1]))
            for (j = 2; j <= np; j++) if (trim(tp[j]) != "") printf "<span class=\"chip\">%s</span>", esc(trim(tp[j]))
        }
        if (meta_line != "") {
            np = split(meta_line, tp, "  [|]  ")
            for (j = 1; j <= np; j++) printf "<span class=\"chip\">%s</span>", esc(trim(tp[j]))
        }
        printf "</div>\n"
    }
    if (nf > 0) {
        printf "<ul class=\"findings\">\n"
        for (pass = 1; pass <= 3; pass++) {
            want = (pass == 1) ? "crit" : (pass == 2) ? "warn" : "info"
            for (j = 1; j <= nf; j++) if (F_SEV[j] == want)
                printf "<li class=\"f-%s\"><span class=\"pill %s\">%s</span><span>%s</span></li>\n", want, want, (want == "crit") ? "ERROR" : (want == "warn") ? "WARNING" : "INFO", esc(F_TXT[j])
        }
        printf "</ul>\n"
    }
    if (nmisc > 0) printf "<pre class=\"msgs\">%s</pre>\n", misc
    if (out != "") printf "<div class=\"secs\">%s</div>\n", out

    first_sev = ""; first_txt = ""
    for (pass = 1; pass <= 2 && first_txt == ""; pass++) {
        want = (pass == 1) ? "crit" : "warn"
        for (j = 1; j <= nf; j++) if (F_SEV[j] == want) { first_sev = want; first_txt = F_TXT[j]; break }
    }
    if (first_txt == "" && first_misc != "") { first_sev = "misc"; first_txt = first_misc }
    if (have_ov) { ncrit = ov_err; nwarn = ov_warn }
    gsub(/\t/, " ", first_txt)
    printf "%d\t%d\t%d\t%s\t%s\n", ncrit, nwarn, ninfo, first_sev, first_txt > meta
}
AWKEOF
)

# $1 = report text file, $2 = label width, $3 = meta output file
html_render_target_body() {
    LC_ALL=C awk -v lw="$2" -v hc="─" -v meta="$3" "$DG_HTML_AWK" "$1"
}

html_css() {
    cat <<'CSS'
*, *::before, *::after { box-sizing: border-box; min-width: 0; }
:root {
  color-scheme: light dark;
  --bg: light-dark(oklch(0.975 0.003 250), oklch(0.17 0.006 250));
  --surface: light-dark(oklch(1 0 none), oklch(0.215 0.006 250));
  --sunken: light-dark(oklch(0.965 0.003 250), oklch(0.19 0.006 250));
  --fg: light-dark(oklch(0.24 0.01 250), oklch(0.93 0.005 250));
  --muted: light-dark(oklch(0.52 0.01 250), oklch(0.7 0.01 250));
  --line: light-dark(oklch(0.91 0.004 250), oklch(0.3 0.008 250));
  --ok: light-dark(oklch(0.53 0.13 155), oklch(0.76 0.15 155));
  --warn: light-dark(oklch(0.6 0.13 70), oklch(0.82 0.14 80));
  --crit: light-dark(oklch(0.55 0.19 27), oklch(0.72 0.17 25));
  --info: light-dark(oklch(0.53 0.1 250), oklch(0.76 0.1 250));
  --radius: 0.75rem;
  --mono: ui-monospace, "SF Mono", "Cascadia Mono", Menlo, Consolas, "Liberation Mono", monospace;
  --ease-out: cubic-bezier(0.23, 1, 0.32, 1);
  text-wrap: pretty;
  overflow-wrap: break-word;
  -webkit-text-size-adjust: 100%;
}
body {
  margin: 0;
  min-height: 100svh;
  background: var(--bg);
  color: var(--fg);
  font: 15px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  -webkit-font-smoothing: antialiased;
}
h1, h2, h3 { text-wrap: balance; margin: 0; }
:focus-visible { outline: 2px solid var(--info); outline-offset: 2px; border-radius: 4px; }
.wrap { max-inline-size: 78rem; margin-inline: auto; padding: clamp(1rem, 0.4rem + 2.4vw, 2.75rem); }

header.top { display: flex; flex-wrap: wrap; align-items: end; justify-content: space-between; gap: 0.75rem 2rem; margin-block-end: 1.5rem; }
.eyebrow { color: var(--muted); font-size: 0.85rem; font-weight: 500; display: flex; align-items: center; gap: 0.5rem; }
.eyebrow svg { flex: none; inline-size: 1.1em; block-size: 1.1em; }
h1 { font-size: clamp(1.5rem, 1.1rem + 1.6vw, 2.25rem); line-height: 1.15; font-weight: 650; letter-spacing: -0.015em; margin-block-start: 0.25rem; }
.runmeta { display: flex; flex-wrap: wrap; gap: 0.25rem 1.25rem; color: var(--muted); font-size: 0.85rem; }
.runmeta b { color: var(--fg); font-weight: 550; }

.verdict {
  --c: var(--ok);
  display: flex; align-items: center; gap: 1rem;
  padding: 1rem 1.25rem; border-radius: var(--radius);
  background: color-mix(in oklch, var(--c) 10%, var(--surface));
  border: 1px solid color-mix(in oklch, var(--c) 30%, transparent);
  margin-block-end: 1rem;
}
.verdict.warn { --c: var(--warn); }
.verdict.crit { --c: var(--crit); }
.verdict .dot { flex: none; inline-size: 0.8rem; block-size: 0.8rem; border-radius: 50%; background: var(--c); box-shadow: 0 0 0 0.3rem color-mix(in oklch, var(--c) 22%, transparent); }
.verdict strong { font-size: 1.1rem; font-weight: 650; }
.verdict span { color: var(--muted); }

.stats { display: grid; gap: 0.75rem; grid-template-columns: repeat(auto-fit, minmax(min(100%, 9rem), 1fr)); margin-block-end: 1.75rem; }
.stat { background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius); padding: 0.85rem 1rem; }
.stat .n { font-size: 1.9rem; font-weight: 650; line-height: 1.1; font-variant-numeric: tabular-nums; }
.stat .l { color: var(--muted); font-size: 0.85rem; display: flex; align-items: center; gap: 0.4rem; }
.stat .l i { inline-size: 0.55rem; block-size: 0.55rem; border-radius: 50%; background: var(--muted); flex: none; }
.stat.ok .l i { background: var(--ok); } .stat.warn .l i { background: var(--warn); }
.stat.crit .l i { background: var(--crit); } .stat.fail .l i { background: var(--crit); }
.stat.zero .n { color: var(--muted); font-weight: 500; }

h2 { font-size: 1.05rem; font-weight: 650; }
.bar { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 0.75rem; margin-block: 0 0.75rem; }
.controls { display: flex; gap: 0.5rem; flex-wrap: wrap; }
.controls button {
  font: inherit; font-size: 0.85rem; color: var(--fg); cursor: pointer;
  background: var(--surface); border: 1px solid var(--line); border-radius: 999px; padding: 0.3rem 0.85rem;
  user-select: none; -webkit-user-select: none; touch-action: manipulation;
}
.controls button[aria-pressed="true"] { background: var(--fg); color: var(--surface); border-color: var(--fg); }
.controls button:active { transform: scale(0.97); }
@media (hover: hover) and (pointer: fine) {
  .controls button:hover { border-color: color-mix(in oklch, var(--fg) 40%, var(--line)); }
  table.fleet tbody tr:hover { background: var(--sunken); }
}
@media (prefers-reduced-motion: no-preference) {
  .controls button { transition: transform 160ms var(--ease-out); }
}

.tablebox { background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius); overflow-x: auto; margin-block-end: 2rem; }
table.fleet { inline-size: 100%; border-collapse: collapse; font-size: 0.9rem; }
table.fleet th { text-align: start; font-weight: 550; color: var(--muted); font-size: 0.8rem; padding: 0.6rem 0.9rem; border-block-end: 1px solid var(--line); white-space: nowrap; }
table.fleet td { padding: 0.6rem 0.9rem; border-block-end: 1px solid var(--line); vertical-align: top; }
table.fleet tbody tr:last-child td { border-block-end: 0; }
table.fleet td.num { text-align: end; font-variant-numeric: tabular-nums; white-space: nowrap; color: var(--muted); }
table.fleet td.name a { color: var(--fg); font-weight: 600; text-decoration: none; }
table.fleet td.name a:focus-visible { outline-offset: 2px; }
table.fleet td.method { font-family: var(--mono); font-size: 0.8rem; color: var(--muted); }
table.fleet td.key { color: var(--muted); max-inline-size: 34rem; }
table.fleet td.key .t { display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 2; line-clamp: 2; overflow: clip; }
.cnt { display: inline-flex; gap: 0.35rem; font-variant-numeric: tabular-nums; font-size: 0.8rem; white-space: nowrap; }
.cnt b { font-weight: 600; } .cnt .e { color: var(--crit); } .cnt .w { color: var(--warn); }

.pill {
  --c: var(--info);
  display: inline-block; white-space: nowrap;
  font-size: 0.72rem; font-weight: 650; letter-spacing: 0.02em; line-height: 1;
  padding: 0.3rem 0.5rem; border-radius: 999px;
  color: var(--c); background: color-mix(in oklch, var(--c) 13%, transparent);
  border: 1px solid color-mix(in oklch, var(--c) 28%, transparent);
}
.pill.ok { --c: var(--ok); } .pill.warn { --c: var(--warn); } .pill.crit { --c: var(--crit); } .pill.fail { --c: var(--crit); }
.pill.fail { color: var(--surface); background: var(--crit); }
.pill.lg { font-size: 0.8rem; padding: 0.38rem 0.65rem; }
.why { display: block; color: var(--muted); font-size: 0.75rem; margin-block-start: 0.25rem; white-space: nowrap; }

details.target { background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius); margin-block-end: 0.85rem; scroll-margin-block-start: 1rem; }
details.target > summary {
  list-style: none; cursor: pointer; display: flex; flex-wrap: wrap; align-items: center; gap: 0.5rem 0.9rem;
  padding: 0.9rem 1.1rem; border-radius: var(--radius);
}
details.target > summary::-webkit-details-marker { display: none; }
details.target > summary::before {
  content: ""; flex: none; inline-size: 0.5rem; block-size: 0.5rem;
  border-inline-end: 2px solid var(--muted); border-block-end: 2px solid var(--muted);
  transform: rotate(-45deg); margin-inline-end: 0.15rem;
}
details.target[open] > summary::before { transform: rotate(45deg); }
@media (prefers-reduced-motion: no-preference) {
  details.target > summary::before { transition: transform 200ms var(--ease-out); }
}
details.target[open] > summary { border-block-end: 1px solid var(--line); border-end-start-radius: 0; border-end-end-radius: 0; }
details.target > summary .tname { font-weight: 650; font-size: 1.02rem; }
details.target > summary .tm { color: var(--muted); font-family: var(--mono); font-size: 0.8rem; }
details.target > summary .push { margin-inline-start: auto; display: flex; gap: 0.9rem; align-items: center; color: var(--muted); font-size: 0.85rem; font-variant-numeric: tabular-nums; }
.tbody { padding: 1rem 1.1rem 1.1rem; display: grid; gap: 1rem; }
.tmeta { display: flex; flex-wrap: wrap; gap: 0.4rem; align-items: center; }
.tmeta strong { margin-inline-end: 0.35rem; }
.chip { font-size: 0.78rem; color: var(--muted); background: var(--sunken); border: 1px solid var(--line); border-radius: 0.4rem; padding: 0.12rem 0.5rem; }

ul.findings { list-style: none; margin: 0; padding: 0; border: 1px solid var(--line); border-radius: 0.6rem; overflow: clip; }
ul.findings li { display: flex; gap: 0.75rem; align-items: baseline; padding: 0.55rem 0.8rem; border-block-end: 1px solid var(--line); }
ul.findings li:last-child { border-block-end: 0; }
ul.findings li .pill { flex: none; inline-size: 5.6rem; text-align: center; }
ul.findings li.f-crit { background: color-mix(in oklch, var(--crit) 6%, transparent); }
ul.findings li.f-warn { background: color-mix(in oklch, var(--warn) 6%, transparent); }
ul.findings li.f-info { color: var(--muted); }

pre.msgs, pre.raw { margin: 0; font: 0.8rem/1.5 var(--mono); background: var(--sunken); border: 1px solid var(--line); border-radius: 0.6rem; padding: 0.75rem 0.9rem; overflow-x: auto; white-space: pre; }
pre.msgs { white-space: pre-wrap; border-color: color-mix(in oklch, var(--crit) 30%, var(--line)); }

.secs { display: grid; gap: 1rem; grid-template-columns: repeat(auto-fill, minmax(min(100%, 27rem), 1fr)); align-items: start; }
section.sec { border: 1px solid var(--line); border-radius: 0.6rem; overflow: clip; }
section.sec h3 { font-size: 0.8rem; font-weight: 650; letter-spacing: 0.03em; color: var(--muted); padding: 0.5rem 0.8rem; background: var(--sunken); border-block-end: 1px solid var(--line); }
table.kv { inline-size: 100%; border-collapse: collapse; font-size: 0.85rem; }
table.kv th { text-align: start; font-weight: 500; color: var(--muted); padding: 0.38rem 0.8rem; inline-size: 38%; vertical-align: top; }
table.kv td { padding: 0.38rem 0.8rem; font-family: var(--mono); font-size: 0.8rem; vertical-align: top; }
table.kv td:last-child { text-align: end; inline-size: 1%; white-space: nowrap; padding-inline-start: 0; }
table.kv tr + tr > * { border-block-start: 1px solid color-mix(in oklch, var(--line) 60%, transparent); }
table.kv tr.r-crit { background: color-mix(in oklch, var(--crit) 6%, transparent); }
table.kv tr.r-warn { background: color-mix(in oklch, var(--warn) 6%, transparent); }
table.kv tr.sub { background: var(--sunken); }
table.kv tr.sub th { inline-size: auto; color: var(--fg); font-weight: 600; font-size: 0.78rem; padding-block-start: 0.65rem; }
.log { padding: 0.5rem 0.8rem; font: 0.78rem/1.55 var(--mono); }
.log .lh { font-family: system-ui, sans-serif; font-size: 0.82rem; font-weight: 600; margin-block-start: 0.25rem; }
.log .ln { padding-inline-start: 0.75rem; white-space: pre-wrap; }
.log .dim { color: var(--muted); }
.log .bad { color: var(--crit); }
.log time { color: var(--muted); margin-inline-end: 0.75rem; }
.log .gap { block-size: 0.4rem; }
details.rawbox > summary { cursor: pointer; color: var(--muted); font-size: 0.85rem; inline-size: fit-content; }
details.rawbox[open] > summary { margin-block-end: 0.5rem; }

body.problems-only .is-ok { display: none; }
footer { color: var(--muted); font-size: 0.8rem; margin-block-start: 2rem; padding-block-start: 1rem; border-block-start: 1px solid var(--line); display: flex; flex-wrap: wrap; gap: 0.25rem 1.5rem; }
@media print {
  .controls { display: none; }
  body { background: white; }
  details.target, .tablebox, .stat { break-inside: avoid; }
}
CSS
}

html_js() {
    cat <<'JS'
(function () {
  var body = document.body;
  function press(group, btn) {
    var bs = document.querySelectorAll('[data-group="' + group + '"]');
    for (var i = 0; i < bs.length; i++) bs[i].setAttribute('aria-pressed', bs[i] === btn ? 'true' : 'false');
  }
  document.addEventListener('click', function (ev) {
    var b = ev.target.closest('button[data-act]');
    if (!b) return;
    var act = b.getAttribute('data-act');
    if (act === 'all' || act === 'problems') {
      body.classList.toggle('problems-only', act === 'problems');
      press('filter', b);
    } else if (act === 'expand' || act === 'collapse') {
      var ds = document.querySelectorAll('details.target');
      for (var i = 0; i < ds.length; i++) ds[i].open = act === 'expand';
    }
  });
  document.addEventListener('click', function (ev) {
    var a = ev.target.closest('a[href^="#t"]');
    if (!a) return;
    var d = document.getElementById(a.getAttribute('href').slice(1));
    if (d) d.open = true;
  });
  window.addEventListener('beforeprint', function () {
    var ds = document.querySelectorAll('details');
    for (var i = 0; i < ds.length; i++) ds[i].open = true;
  });
})();
JS
}

# rc -> "class<TAB>label<TAB>detail" for a target's result pill.
html_result_of() {
    case "$1" in
        0) printf 'ok\tOK\t' ;;
        1) printf 'warn\tWARNING\t' ;;
        2) printf 'crit\tCRITICAL\t' ;;
        *) printf 'fail\tFAILED\t%s' "$(printf '%s' "$2" | sed 's/^FAILED *//; s/^(//; s/)$//')" ;;
    esac
}

# Writes the report from the wrapper's run state: NRUN, R_* (per result),
# T_NAME, ALL_CHECK, WORST, CONFIG_FILE, RUN_STARTED, HTML_WORK (holds
# out.<target index>). $1 = output file (written via a temp file + mv).
html_write_report() {
    local dest="$1" tmp="$1.tmp.$$" i idx lw cls label detail sev_e sev_w sev_i fsev ftxt
    local n_ok=0 n_warn=0 n_crit=0 n_fail=0 vcls vhead vtext bad="" degraded="" open
    local generated host html_mode html_any_check=false
    generated="$(date '+%Y-%m-%d %H:%M:%S %Z')"
    host="$(hostname 2>/dev/null || uname -n 2>/dev/null || printf 'unknown')"

    # Pass 1: render every card body and its meta line.
    i=0
    while [[ $i -lt $NRUN ]]; do
        idx="${R_IDX[$i]}"
        case "${R_MODE[$i]}" in */check) lw=8; html_any_check=true ;; *) lw=24 ;; esac
        [[ -f "$HTML_WORK/out.$idx" ]] || : > "$HTML_WORK/out.$idx"
        html_render_target_body "$HTML_WORK/out.$idx" "$lw" "$HTML_WORK/meta.$idx" > "$HTML_WORK/body.$idx" || return 1
        case "${R_RC[$i]}" in
            0) n_ok=$((n_ok + 1)) ;;
            1) n_warn=$((n_warn + 1)); degraded="${degraded:+$degraded, }${R_NAME[$i]}" ;;
            2) n_crit=$((n_crit + 1)); bad="${bad:+$bad, }${R_NAME[$i]}" ;;
            *) n_fail=$((n_fail + 1)); bad="${bad:+$bad, }${R_NAME[$i]}" ;;
        esac
        i=$((i + 1))
    done

    if $ALL_CHECK; then html_mode="check (running state)"
    elif [[ "$html_any_check" == true ]]; then html_mode="mixed (check + review configuration)"
    else html_mode="review configuration"; fi
    if [[ -n "$bad" ]]; then vcls="crit"; elif [[ -n "$degraded" ]]; then vcls="warn"; else vcls="ok"; fi
    if $ALL_CHECK; then
        case "$vcls" in
            crit) vhead="Data Guard is NOT running correctly"; vtext="Problem or not checked: $bad${degraded:+ · degraded: $degraded}" ;;
            warn) vhead="Data Guard is running but DEGRADED"; vtext="Degraded: $degraded" ;;
            ok)   vhead="Data Guard is running as configured"; vtext="$NRUN target(s) checked" ;;
        esac
    else
        case "$vcls" in
            crit) vhead="Problems on $((n_crit + n_fail)) of $NRUN target(s)"; vtext="$bad${degraded:+ · warnings: $degraded}" ;;
            warn) vhead="Warnings on $n_warn of $NRUN target(s)"; vtext="$degraded" ;;
            ok)   vhead="All $NRUN target(s) healthy"; vtext="No errors or warnings" ;;
        esac
    fi

    {
        printf '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
        printf '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        printf '<meta name="color-scheme" content="light dark">\n'
        printf '<title>DG fleet %s · %s</title>\n' "$(html_esc_s "$(basename "$CONFIG_FILE")")" "$(html_esc_s "$generated")"
        printf '<style>\n'; html_css; printf '</style>\n</head>\n<body>\n<div class="wrap">\n'

        printf '<header class="top"><div>'
        printf '<div class="eyebrow"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" aria-hidden="true"><ellipse cx="12" cy="5.5" rx="7.5" ry="2.8"/><path d="M4.5 5.5v6.5c0 1.5 3.4 2.8 7.5 2.8s7.5-1.3 7.5-2.8V5.5"/><path d="M4.5 12v6.5c0 1.5 3.4 2.8 7.5 2.8s7.5-1.3 7.5-2.8V12"/></svg>Data Guard fleet report</div>'
        printf '<h1>%s</h1></div>' "$(html_esc_s "$(basename "$CONFIG_FILE")")"
        printf '<div class="runmeta"><span>Mode <b>%s</b></span><span>Started <b>%s</b></span><span>Finished <b>%s</b></span><span>From <b>%s</b></span></div>' \
            "$html_mode" \
            "$(html_esc_s "$RUN_STARTED")" "$(html_esc_s "$generated")" "$(html_esc_s "$host")"
        printf '</header>\n'

        printf '<div class="verdict %s" role="status"><span class="dot"></span><div><strong>%s</strong><br><span>%s</span></div></div>\n' \
            "$vcls" "$(html_esc_s "$vhead")" "$(html_esc_s "$vtext")"

        printf '<div class="stats">'
        printf '<div class="stat"><div class="n">%s</div><div class="l"><i></i>Targets</div></div>' "$NRUN"
        for cls in ok warn crit fail; do
            case "$cls" in
                ok) label="OK"; i=$n_ok ;; warn) label="Warning"; i=$n_warn ;;
                crit) label="Critical"; i=$n_crit ;; fail) label="Not checked"; i=$n_fail ;;
            esac
            printf '<div class="stat %s%s"><div class="n">%s</div><div class="l"><i></i>%s</div></div>' "$cls" "$([[ $i -eq 0 ]] && printf ' zero')" "$i" "$label"
        done
        printf '</div>\n'

        printf '<div class="bar"><h2>Targets</h2><div class="controls">'
        printf '<button type="button" data-act="all" data-group="filter" aria-pressed="true">All</button>'
        printf '<button type="button" data-act="problems" data-group="filter" aria-pressed="false">Needs attention</button>'
        printf '<button type="button" data-act="expand">Expand all</button><button type="button" data-act="collapse">Collapse all</button>'
        printf '</div></div>\n'

        printf '<div class="tablebox"><table class="fleet"><thead><tr><th>Result</th><th>Target</th><th>Method</th><th>Mode</th><th>Findings</th><th>Key finding</th><th class="num">Time</th></tr></thead><tbody>\n'
        i=0
        while [[ $i -lt $NRUN ]]; do
            idx="${R_IDX[$i]}"
            IFS=$'\t' read -r cls label detail <<< "$(html_result_of "${R_RC[$i]}" "${R_PLAIN[$i]}")"
            IFS=$'\t' read -r sev_e sev_w sev_i fsev ftxt < "$HTML_WORK/meta.$idx" || { sev_e=0; sev_w=0; sev_i=0; fsev=""; ftxt=""; }
            printf '<tr class="%s"><td><span class="pill lg %s">%s</span>%s</td>' \
                "$([[ "$cls" == ok ]] && printf 'is-ok')" "$cls" "$label" \
                "$([[ -n "$detail" ]] && printf '<span class="why">%s</span>' "$(html_esc_s "$detail")")"
            printf '<td class="name"><a href="#t%s">%s</a></td><td class="method">%s</td><td>%s</td>' \
                "$idx" "$(html_esc_s "${R_NAME[$i]}")" "$(html_esc_s "${R_METHOD[$i]}")" "$(html_esc_s "${R_MODE[$i]}")"
            printf '<td><span class="cnt"><span class="%s"><b>%s</b> err</span><span class="%s"><b>%s</b> warn</span></span></td>' \
                "$([[ ${sev_e:-0} -gt 0 ]] && printf e)" "${sev_e:-0}" "$([[ ${sev_w:-0} -gt 0 ]] && printf w)" "${sev_w:-0}"
            printf '<td class="key"><span class="t">%s</span></td><td class="num">%ss</td></tr>\n' "$(html_esc_s "${ftxt:-—}")" "${R_SECS[$i]}"
            i=$((i + 1))
        done
        printf '</tbody></table></div>\n'

        i=0
        while [[ $i -lt $NRUN ]]; do
            idx="${R_IDX[$i]}"
            IFS=$'\t' read -r cls label detail <<< "$(html_result_of "${R_RC[$i]}" "${R_PLAIN[$i]}")"
            IFS=$'\t' read -r sev_e sev_w sev_i fsev ftxt < "$HTML_WORK/meta.$idx" || { sev_e=0; sev_w=0; }
            [[ "$cls" == ok ]] && open="" || open=" open"
            printf '<details class="target%s" id="t%s"%s><summary>' "$([[ "$cls" == ok ]] && printf ' is-ok')" "$idx" "$open"
            printf '<span class="pill lg %s">%s</span><span class="tname">%s</span><span class="tm">%s · %s</span>' \
                "$cls" "$label" "$(html_esc_s "${R_NAME[$i]}")" "$(html_esc_s "${R_METHOD[$i]}")" "$(html_esc_s "${R_MODE[$i]}")"
            printf '<span class="push">%s<span class="cnt"><span class="%s"><b>%s</b> err</span><span class="%s"><b>%s</b> warn</span></span><span>%ss</span></span>' \
                "$([[ -n "$detail" ]] && printf '<span>%s</span>' "$(html_esc_s "$detail")")" \
                "$([[ ${sev_e:-0} -gt 0 ]] && printf e)" "${sev_e:-0}" "$([[ ${sev_w:-0} -gt 0 ]] && printf w)" "${sev_w:-0}" "${R_SECS[$i]}"
            printf '</summary>\n<div class="tbody">\n'
            cat "$HTML_WORK/body.$idx"
            if [[ -s "$HTML_WORK/out.$idx" ]]; then
                printf '<details class="rawbox"><summary>Raw output</summary><pre class="raw">'
                sed $'s/\033\\[[0-9;]*m//g; s/\r$//' "$HTML_WORK/out.$idx" | html_esc
                printf '</pre></details>\n'
            else
                printf '<pre class="msgs">(no output)</pre>\n'
            fi
            printf '</div></details>\n'
            i=$((i + 1))
        done

        printf '<footer><span>dg_fleet_check.sh · exit code %s</span><span>Config %s</span><span>Per-target timeout %ss</span></footer>\n' \
            "$WORST" "$(html_esc_s "$CONFIG_FILE")" "$FLEET_TARGET_TIMEOUT"
        printf '</div>\n<script>\n'; html_js; printf '</script>\n</body>\n</html>\n'
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
}
