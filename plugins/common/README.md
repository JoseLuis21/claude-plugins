# common

`common@jl-stack` — se instala sola como dependencia de `backend` y `frontend`.

Skills que sirven igual en cualquier stack, así que viven aquí en vez de duplicarse en cada
plugin.

| Skill | Se activa cuando pides | Trae |
| --- | --- | --- |
| `git-commit` | commitear cambios, generar el mensaje desde el diff, agrupar archivos en commits lógicos | convención Conventional Commits (tipos, scope, breaking changes) |

Se invoca como `/common:git-commit`.

## Origen

`git-commit` viene de [github/awesome-copilot](https://github.com/github/awesome-copilot)
(`skills/git-commit`), bajo licencia MIT, con su autoría conservada en el
[`NOTICE`](../../NOTICE) de la raíz. La re-trae
[`scripts/sync-skills.sh`](../../scripts/sync-skills.sh).
