# jose-plugins

Marketplace de plugins de Claude Code. Un plugin por área de trabajo: instalas el que te sirve.

## Instalar

```bash
/plugin marketplace add JoseLuis21/jose-plugins
/plugin install backend@JoseLuis21
/plugin install frontend@JoseLuis21
```

En local, mientras lo desarrollas:

```bash
/plugin marketplace add /Users/joseluis/Desktop/projects/jose/jose-plugins
```

## Plugins

| Plugin | Instalar | Skills |
| --- | --- | --- |
| [`backend`](plugins/backend) | `backend@JoseLuis21` | `go-hexagonal-multitenant-skills`, `mysql-query-optimization-skills`, `docker-golang-skills`, `github-actions-skills`, `git-commit`, `owasp-security` |
| [`frontend`](plugins/frontend) | `frontend@JoseLuis21` | `shadcn`, `vercel-react-best-practices`, `owasp-security`, `git-commit` |

## Estructura

```
.claude-plugin/marketplace.json     el catálogo: qué plugins hay y dónde viven
plugins/<plugin>/
  .claude-plugin/plugin.json        manifiesto del plugin
  skills/<skill>/SKILL.md           una skill por carpeta
scripts/sync-skills.sh              re-trae las skills que se mantienen fuera de este repo
```

## Añadir un plugin nuevo

1. `mkdir -p plugins/<nombre>/skills/<skill>` y pon ahí el `SKILL.md`.
2. Crea `plugins/<nombre>/.claude-plugin/plugin.json` con `name`, `version` y `description`.
3. Añade la entrada al array `plugins` de `.claude-plugin/marketplace.json`.
4. Sube la `version` en los dos sitios — Claude Code usa ese campo para ofrecer la actualización.

El nombre del plugin es el que va a la izquierda del `@` al instalar, y el que prefija sus skills
(`/backend:git-commit`). Elígelo corto y por área, no por repo.

## Convención de las skills

Las skills son **genéricas**: sin nombres de cliente, de repos internos, de colas, de funciones ni
de bases de datos. Donde hace falta un identificador va un placeholder. Antes de publicar:

```bash
grep -rniE 'nombre-de-cliente|nombre-de-repo-interno' . --exclude-dir=.git
```
