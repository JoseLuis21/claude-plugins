#!/usr/bin/env bash
# Valida cada plugin contra los dos formatos, y cada skill contra Agent Skills.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "== Claude Code =="
claude plugin validate . | tail -1
for p in plugins/*/; do claude plugin validate "$p" --strict | tail -1; done

echo
echo "== Agent Plugins 1.1.0 + Agent Skills =="
python3 - <<'PY'
import json, pathlib, re, sys, urllib.request
import yaml  # PyYAML: pip install pyyaml

# El $id canónico (agent-plugins.org/schemas/...) todavía devuelve 404; se baja del repo de la spec.
url = "https://raw.githubusercontent.com/agentplugins/agent-plugins-spec/main/schemas/1.1.0/plugin.schema.json"
try:
    schema = json.load(urllib.request.urlopen(url, timeout=10))
except Exception as e:
    sys.exit(f"no se pudo bajar el esquema ({e}); revisa la conexión")

allowed, required = set(schema["properties"]), set(schema["required"])
name_ok = lambda n: re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?", n or "") and not re.search(r"--|\.\.", n) and len(n) <= 64
fails = 0

for plug in sorted(pathlib.Path("plugins").iterdir()):
    d = json.loads((plug / "plugin.json").read_text())
    errs  = [f"faltan {required - set(d)}"] if not required <= set(d) else []
    errs += [f"campos no permitidos {set(d) - allowed}"] if set(d) - allowed else []
    errs += ["$schema incorrecto"] if d.get("$schema") != schema["properties"]["$schema"]["const"] else []
    errs += [f"name inválido: {d.get('name')}"] if not name_ok(d.get("name")) else []
    cc = json.loads((plug / ".claude-plugin" / "plugin.json").read_text())
    errs += [f"versión desalineada: {d.get('version')} vs {cc.get('version')}"] if d.get("version") != cc.get("version") else []
    print(f"  {plug.name}/plugin.json {'✔' if not errs else '✘ ' + '; '.join(errs)}")
    fails += bool(errs)

    for s in sorted((plug / "skills").iterdir()):
        raw = re.match(r"^---\n(.*?)\n---\n", (s / "SKILL.md").read_text(), re.S)
        if not raw:
            print(f"    {s.name}: ✘ sin frontmatter"); fails += 1; continue
        try:
            fm = yaml.safe_load(raw.group(1)) or {}
        except yaml.YAMLError as ex:
            line = getattr(getattr(ex, "problem_mark", None), "line", "?")
            print(f"    {s.name}: ✘ frontmatter no es YAML válido (línea {line}) — "
                  f"suele ser un ':' sin comillas en description"); fails += 1; continue
        desc = fm.get("description") or ""
        e  = [f"name '{fm.get('name')}' != directorio"] if fm.get("name") != s.name else []
        e += ["description ausente"] if not desc else []
        e += [f"description de {len(desc)} car. (max 1024)"] if len(desc) > 1024 else []
        if e:
            print(f"    {s.name}: ✘ {'; '.join(e)}"); fails += 1

print("\nTodo conforme." if not fails else f"\n{fails} problema(s).")
sys.exit(1 if fails else 0)
PY
