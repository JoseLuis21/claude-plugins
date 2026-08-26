# backend

`backend@JoseLuis21`

Seis skills para el ciclo de un servicio backend: construir la imagen, desplegarla,
commitear y no dejar agujeros de seguridad por el camino.

| Skill | Se activa cuando pides | Trae |
| --- | --- | --- |
| `docker-golang-skills` | dockerizar un proyecto, acelerar un `docker build`, cachear dependencias, compilar para ARM/Graviton, empaquetar una Lambda como imagen, desplegar en Railway | `Dockerfile`, `Dockerfile.railway`, `Dockerfile.lambda`, `.dockerignore`, `railway.json`, workflows de build, snippet de Makefile |
| `github-actions-skills` | crear o migrar el `.github/workflows/*.yml` de deploy, clonar el deploy de otro repo, pasar a ARM64, arreglar un workflow viejo, notificar a Slack, inyectar secretos de Secrets Manager | workflows para servicio ECS, Lambda de contenedor e imagen base en ECR, más una guía de auditoría |
| `go-hexagonal-multitenant-skills` | estructurar un microservicio o Lambda en Go con arquitectura hexagonal, portar un servicio Node/TS/PHP a Go, conectarse a varias bases por tenant o "al nodo N", pools de MySQL en Lambda, un consumidor SQS, generar archivos grandes en streaming a S3, medir queries por tenant | layout `core` / `ports` / `adapters` / `app`, plantillas de pools por nodo, handler SQS, store en Redis, `io.Pipe` a S3, métricas EMF, y un runbook para medir Lambdas de reporte |
| `mysql-query-optimization-skills` | una query o un reporte "está lento" o "no termina", leer un EXPLAIN, proponer un índice, reescribir un JOIN o un GROUP BY, "el último valor por grupo", o que un cálculo deje de recorrer todo el histórico | método de medición con `EXPLAIN ANALYZE`, las reescrituras que pagan y las que no, y la estrategia de saldo acumulado por período + delta (diseño, invariantes, trampas y puerta de verificación) |
| `git-commit` | commitear cambios, generar el mensaje desde el diff, agrupar archivos en commits lógicos | convención Conventional Commits (tipos, scope, breaking changes) |
| `owasp-security` | revisar la seguridad de un servicio, auditar endpoints, arreglar IDOR / inyección SQL / SSRF, diseñar autenticación y permisos, revisar antes de producción | las diez categorías del OWASP Top 10:2021 aplicadas a un backend en Go, con el patrón que arregla cada una, los falsos arreglos, y un checklist de despliegue |

Las plantillas de las dos primeras usan `<placeholders>` para todo lo que cambia por
organización (región, cuenta, nombres de secrets y de recursos). Cada skill explica de
dónde sacar esos valores antes de escribir nada.

## Origen y créditos

| Skill | Origen | Licencia |
| --- | --- | --- |
| `docker-golang-skills` | [JoseLuis21/docker-golang-skills](https://github.com/JoseLuis21/docker-golang-skills) | propia |
| `github-actions-skills` | [JoseLuis21/github-actions-skills](https://github.com/JoseLuis21/github-actions-skills) | propia |
| `owasp-security` | propia, escrita sobre el estándar [OWASP Top 10:2021](https://owasp.org/Top10/) | propia |
| `go-hexagonal-multitenant-skills` | propia | propia |
| `mysql-query-optimization-skills` | propia | propia |
| `git-commit` | [github/awesome-copilot](https://github.com/github/awesome-copilot) `skills/git-commit` | MIT — se conserva el crédito porque la licencia lo exige |

Las cinco primeras se editan aquí o se traen de repos propios con
[`scripts/sync-skills.sh`](../../scripts/sync-skills.sh); ese script también re-trae
`git-commit` desde el repo de GitHub.
