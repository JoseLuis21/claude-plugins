#!/usr/bin/env bash
# Resume las ultimas ejecuciones de una Lambda Go de reportes: etapas, queries,
# desenlace y la linea REPORT (duracion, memoria, init).
#
#   scripts/lambda-perf.sh <function-name> [minutos=60] [region=us-east-2]
#
# Requiere que la Lambda loguee en JSON (slog) con los campos del patron:
# msg, Query, QueryDurationMs, QueryRows, duration_ms, rows, first_byte_ms,
# Outcome, ReportDurationMs, db_name, company_id, error, reason, url.
set -euo pipefail
FN="${1:?function-name}"; MIN="${2:-60}"; REGION="${3:-us-east-2}"
START=$(( ($(date +%s) - MIN*60) * 1000 ))
aws logs filter-log-events --log-group-name "/aws/lambda/$FN" --region "$REGION" \
  --start-time "$START" --query 'events[].[timestamp,message]' --output text \
| python3 -c '
import sys, json, datetime, re
KEYS = ("Query","QueryDurationMs","QueryRows","duration_ms","rows","first_byte_ms",
        "unitary_rescues","opening_stock","db_name","company_id","error","reason","url",
        "Outcome","ReportDurationMs")
for line in sys.stdin:
    p = line.rstrip("\n").split("\t", 1)
    if len(p) < 2: continue
    ts = datetime.datetime.fromtimestamp(int(p[0]) / 1000).strftime("%H:%M:%S"); m = p[1]
    if m.startswith("REPORT"):
        d = re.search(r"Duration: ([\d.]+) ms", m); mem = re.search(r"Max Memory Used: (\d+)", m)
        init = re.search(r"Init Duration: ([\d.]+)", m)
        print(ts, "REPORT total=%sms mem=%sMB init=%s" % (d.group(1), mem.group(1), init.group(1) + "ms" if init else "-"))
        print("-" * 100); continue
    if m.startswith(("START", "END", "LOGS", "EXTENSION")): continue
    if "Task timed out" in m: print(ts, "!!! TIMEOUT", m[:160]); continue
    try: j = json.loads(m)
    except Exception: print(ts, m[:200]); continue
    keys = [k for k in KEYS if k in j]
    print(ts, j.get("level"), j.get("msg", ""), "|", " ".join("%s=%s" % (k, j[k]) for k in keys))
'
