#!/usr/bin/env bash
# Mide cada plugin: peso en disco y coste de contexto.
#   siempre activo = name + description de cada skill, se carga en cada arranque
#   bajo demanda   = cuerpo del SKILL.md + referencias, entra solo si la skill se dispara
# Regenera con esto la tabla del README cuando cambien las skills.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - <<'PY'
import pathlib, re, subprocess, yaml

def du(p):
    return subprocess.run(["du","-sh",str(p)],capture_output=True,text=True).stdout.split()[0]

rows, ta, td = [], 0, 0
for plug in sorted(pathlib.Path("plugins").iterdir()):
    a = d = 0
    for s in sorted((plug/"skills").iterdir()):
        raw = (s/"SKILL.md").read_text()
        fm = yaml.safe_load(re.match(r"^---\n(.*?)\n---\n", raw, re.S).group(1))
        a += (len(fm["name"]) + len(fm["description"])) // 4
        d += len(raw)//4 + sum(f.stat().st_size for f in s.rglob("*")
                               if f.is_file() and f.name != "SKILL.md") // 4
    n = len(list(plug.rglob("*"))) - len([x for x in plug.rglob("*") if x.is_dir()])
    rows.append((plug.name, len(list((plug/"skills").iterdir())), du(plug), n, a, d))
    ta += a; td += d

print(f"| Plugin | Skills | Disco | Archivos | Siempre activo | Bajo demanda |")
print(f"| --- | ---: | ---: | ---: | ---: | ---: |")
for n, sk, sz, f, a, d in rows:
    print(f"| `{n}` | {sk} | {sz} | {f} | **~{a:,} tok** | ~{d:,} tok |")
print(f"| **los tres** | **{sum(r[1] for r in rows)}** | | | **~{ta:,} tok** | ~{td:,} tok |")
PY
