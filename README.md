# jose-backend-plugin

Plugin de Claude Code para trabajo de backend, distribuido como marketplace de un solo plugin.

## Instalar

```bash
/plugin marketplace add JoseLuis21/jose-backend-plugin
/plugin install jose-backend-plugin@jose-backend-plugin
```

Mientras lo desarrollas en local, apunta el marketplace a esta carpeta:

```bash
/plugin marketplace add /Users/joseluis/Desktop/projects/jose/jose-backend-plugin
```

## Plugins

| Plugin | Skills | Para qué |
| --- | --- | --- |
| [`jose-backend-plugin`](plugins/jose-backend-plugin) | `docker-golang-skills`, `github-actions-skills`, `go-hexagonal-multitenant-skills`, `git-commit`, `owasp-security` | Estructurar el servicio en Go, dockerizarlo, desplegarlo en AWS, commitear con Conventional Commits y revisar seguridad OWASP |

## Estructura

```
.claude-plugin/marketplace.json     catálogo: qué plugins hay y dónde viven
plugins/<plugin>/
  .claude-plugin/plugin.json        manifiesto del plugin
  skills/<skill>/SKILL.md           una skill por carpeta
scripts/sync-skills.sh              re-trae las skills desde sus repos de origen
```

## Añadir un plugin nuevo

1. `mkdir -p plugins/<nombre>/skills/<skill>` y pon ahí el `SKILL.md`.
2. Crea `plugins/<nombre>/.claude-plugin/plugin.json` con `name`, `version` y `description`.
3. Añade la entrada al array `plugins` de `.claude-plugin/marketplace.json`.
4. Sube la `version` en los dos sitios — Claude Code usa ese campo para ofrecer la actualización.
