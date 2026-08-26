# claude-plugins

Marketplace de plugins de Claude Code. Un plugin por área de trabajo: instalas el que te sirve.

## Instalar

```bash
/plugin marketplace add JoseLuis21/claude-plugins
/plugin install backend@jl-stack
/plugin install frontend@jl-stack
```

En local, mientras lo desarrollas:

```bash
/plugin marketplace add /Users/joseluis/Desktop/projects/jose/claude-plugins
```

## Plugins

| Plugin | Instalar | Skills |
| --- | --- | --- |
| [`backend`](plugins/backend) | `backend@jl-stack` | `go-hexagonal-multitenant-skills`, `mysql-query-optimization-skills`, `docker-golang-skills`, `github-actions-skills`, `git-commit`, `owasp-security` |
| [`frontend`](plugins/frontend) | `frontend@jl-stack` | `shadcn`, `vercel-react-best-practices`, `owasp-security`, `git-commit` |

## El resto del stack

Estos no están en el catálogo — se publican por su cuenta y no son de un área concreta — pero
son lo que uso alrededor de estos plugins. Se instalan desde su propio marketplace:

```bash
# memoria persistente entre sesiones y compactaciones
/plugin marketplace add Gentleman-Programming/engram
/plugin install engram@engram

# lenguaje de diseño para frontend: 1 skill + 23 comandos
/plugin marketplace add pbakaus/impeccable
/plugin install impeccable@impeccable

# integración con la terminal Warp
/plugin marketplace add warpdotdev/claude-code-warp
/plugin install warp@claude-code-warp

# del marketplace oficial, ya registrado de fábrica
/plugin install gopls-lsp@claude-plugins-official       # diagnósticos y navegación en Go
/plugin install vercel@claude-plugins-official          # despliegue, AI SDK, Next.js
/plugin install mongodb@claude-plugins-official         # consultas, esquemas, índices
/plugin install skill-creator@claude-plugins-official   # crear, medir y afinar skills
/plugin install atlassian@claude-plugins-official       # Jira y Confluence
/plugin install aws-core@claude-plugins-official        # IaC, servicios base, tareas comunes
/plugin install aws-serverless@claude-plugins-official  # diseñar, desplegar y depurar Lambdas

# Workers, Wrangler, D1, R2, Durable Objects, Agents SDK
/plugin marketplace add cloudflare/skills
/plugin install cloudflare@cloudflare
```

Además de estos, mantengo skills sueltas por proveedor en `~/.claude/skills/`. Esas son locales
y no se distribuyen desde aquí; si alguna madura y deja de ser específica de un proyecto, acaba
en uno de los plugins de este catálogo.

El catálogo oficial trae además `deploy-on-aws` y `databases-on-aws`. No los uso porque compiten
por los mismos disparos que `github-actions-skills` y `mysql-query-optimization-skills` de este
repo, que llevan las convenciones concretas en vez de recomendaciones genéricas. Si no tienes
esas dos skills, sí valen la pena.

### Herramientas externas

Los plugins escriben configuración y comandos, pero **no instalan binarios**. Hay dos listas
distintas: lo que asumen las skills de este catálogo, y lo que necesitan los plugins de arriba.

**Para las skills de este repo:**

| Binario | Lo usan | Para qué |
| --- | --- | --- |
| `docker` + `buildx` | `docker-golang-skills` | build multi-arch y cache de BuildKit |
| `aws` | `github-actions-skills`, `go-hexagonal-multitenant-skills` | ECR, ECS, Lambda, CloudWatch |
| `go` | las de backend | compilar y `go test` |
| `govulncheck` | `owasp-security` | escaneo de vulnerabilidades en CI |
| `mysql` | `mysql-query-optimization-skills` | `EXPLAIN ANALYZE` contra el servidor |
| `npx` / `npm` (o `pnpm`, `bun`) | `shadcn`, `vercel-react-best-practices` | CLI de shadcn, build y auditoría |
| `gh` | `git-commit` y el flujo de PRs | operaciones sobre GitHub |

**Para los plugins del stack:**

| Plugin | Necesita | Nota |
| --- | --- | --- |
| `cloudflare@cloudflare` | `npm` | **no hace falta instalar Wrangler a mano**: la skill lo detecta y lo añade al proyecto con `npm install -D wrangler@latest`. El plugin además conecta 5 servidores MCP remotos por HTTP, sin binarios locales |
| `aws-core` | `uv` (aporta `uvx`) | su MCP arranca con `uvx mcp-proxy-for-aws`. Sin `uv` el servidor no levanta y el fallo sale en la pestaña **Errors** de `/plugin`. `brew install uv` |
| `gopls-lsp` | `gopls` | el plugin no lo trae |

El `aws` CLI aparece solo en la primera tabla a propósito: los plugins de AWS operan sobre todo
por MCP, pero los workflows y los runbooks que escriben las skills de este repo se ejecutan con
el CLI.

## Qué entra en este catálogo

Solo plugins propios. Los de terceros se instalan desde su origen, como los de la sección
anterior: así se actualizan cuando su autor publica, y no hay que redistribuir su código ni
cumplir con su licencia.

Técnicamente el catálogo *podría* referenciarlos sin copiarlos, con una fuente `git-subdir`:

```json
{
  "name": "impeccable",
  "source": { "source": "git-subdir", "url": "https://github.com/pbakaus/impeccable.git", "path": "plugin" }
}
```

Pero declarar ahí una `version` **fija** esa versión para todo el que instale desde aquí, hasta
que se edite el número a mano. Convertirse en el cuello de botella de las actualizaciones de un
plugin ajeno no compensa salvo que lo estés curando de verdad.

Vendorizar sí tiene sentido en el caso contrario: cuando el origen es una skill suelta dentro de
un repo que **no** publica plugin. Es lo que pasa con `shadcn`, `vercel-react-best-practices` y
`git-commit`, que están copiadas aquí y las re-trae [`scripts/sync-skills.sh`](scripts/sync-skills.sh).

## Compatibilidad universal

Cada plugin cumple a la vez con **Claude Code** y con el estándar
[Agent Plugins 1.1.0](https://agent-plugins.org/), sin duplicar nada: las skills viven en
`skills/<nombre>/SKILL.md`, que es la ruta que ambos usan, y solo el manifiesto está por
duplicado porque cada especificación lo busca en un sitio distinto.

```
plugins/backend/
├── plugin.json                    ← Agent Plugins 1.1.0 (raíz del plugin)
├── .claude-plugin/plugin.json     ← Claude Code
└── skills/<nombre>/SKILL.md       ← las dos leen de aquí
```

Un cliente que implemente Agent Plugins carga el directorio del plugin tal cual. Claude Code
ignora el `plugin.json` de la raíz y lee el suyo. Al tocar la versión de un plugin, **súbela en
los dos manifiestos**.

Las skills cumplen además la [especificación de Agent Skills](https://agentskills.io/specification):
`name` en minúsculas y coincidiendo con el directorio, `description` de menos de 1024 caracteres,
y frontmatter YAML válido.

## Estructura

```
.claude-plugin/marketplace.json     el catálogo: qué plugins hay y dónde viven
plugins/<plugin>/
  .claude-plugin/plugin.json        manifiesto del plugin
  skills/<skill>/SKILL.md           una skill por carpeta
scripts/sync-skills.sh              re-trae las skills que se mantienen fuera de este repo
scripts/check-conformance.sh        valida los dos formatos y la spec de Agent Skills
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
