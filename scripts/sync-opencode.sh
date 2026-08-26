#!/usr/bin/env bash
# OpenCode no tiene concepto de plugin: lee skills sueltas de .opencode/skills/.
# Se enlazan en vez de copiarse, así no hay contenido duplicado que se desincronice.
# Reejecuta esto al añadir, quitar o renombrar una skill.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

rm -rf .opencode/skills && mkdir -p .opencode/skills
python3 - <<'PY'
import os, pathlib, sys
dest = pathlib.Path(".opencode/skills"); vistos = {}
for plug in sorted(pathlib.Path("plugins").iterdir()):
    for s in sorted((plug/"skills").iterdir()):
        if s.name in vistos:
            sys.exit(f"colisión: '{s.name}' está en {vistos[s.name]} y en {plug.name}. "
                     f"OpenCode aplana todas las skills en una carpeta, así que sus nombres "
                     f"tienen que ser únicos en todo el catálogo.")
        vistos[s.name] = plug.name
        os.symlink(os.path.relpath(s, dest), dest/s.name)
print(f"{len(vistos)} skills enlazadas en .opencode/skills/")
PY
