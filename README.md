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
| [`backend`](plugins/backend) | `backend@jl-stack` | `go-hexagonal-multitenant-skills`, `mysql-query-optimization-skills`, `mysql`, `docker-golang-skills`, `github-actions-skills`, `owasp-security` |
| [`frontend`](plugins/frontend) | `frontend@jl-stack` | `shadcn`, `vercel-react-best-practices`, `owasp-security-frontend` |
| [`common`](plugins/common) | *(dependencia)* | `git-commit` |

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

# operar Railway: proyectos, servicios, bases, dominios, variables
/plugin marketplace add railwayapp/railway-skills
/plugin install railway@railway-skills

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

El de Railway complementa a `docker-golang-skills`, que cubre el otro lado: esa skill **prepara**
el despliegue (`Dockerfile.railway`, `railway.json`, targets de Makefile) y el plugin de Railway
**opera** la plataforma una vez desplegada.

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

## Compatibilidad entre clientes

Un mismo paquete, cuatro clientes, sin duplicar una sola skill. Cada especificación busca su
manifiesto en un sitio distinto, pero todas leen las skills de `skills/<nombre>/SKILL.md`:

```
plugins/<plugin>/
├── plugin.json                    ← Agent Plugins 1.1.0 (raíz del plugin)
├── .claude-plugin/plugin.json     ← Claude Code
├── .cursor-plugin/plugin.json     ← Cursor
├── .codex-plugin/plugin.json      ← Codex
└── skills/<nombre>/SKILL.md       ← todas leen de aquí
```

**OpenCode va aparte**: no tiene concepto de plugin, lee skills sueltas de `.opencode/skills/`
en la raíz del repo. Ahí van **enlaces simbólicos** a las skills reales, no copias, para que no
haya contenido duplicado que se desincronice. Regenéralos con
[`scripts/sync-opencode.sh`](scripts/sync-opencode.sh) al añadir, quitar o renombrar una skill.

Tres consecuencias de esto que conviene tener presentes:

- **Los nombres de las skills deben ser únicos en todo el catálogo**, no solo dentro de su
  plugin, porque OpenCode las aplana en una carpeta. Por eso la de seguridad del frontend se
  llama `owasp-security-frontend` y no `owasp-security`. `check-conformance.sh` lo verifica.
- **Los enlaces simbólicos pueden no resolverse en Windows** según la configuración de git. Si
  te afecta, cambia el script para que copie en vez de enlazar.
- **`dependencies` solo lo entiende Claude Code.** En los demás clientes, `frontend` carga sin
  `common`: sus skills funcionan, pero `git-commit` hay que cargarla aparte.

Al tocar la versión de un plugin, **súbela en los cuatro manifiestos** — `check-conformance.sh`
comprueba que no se desalineen.

## Estructura

```
.claude-plugin/marketplace.json     el catálogo: qué plugins hay y dónde viven
plugins/<plugin>/
  .claude-plugin/plugin.json        manifiesto del plugin
  skills/<skill>/SKILL.md           una skill por carpeta
scripts/sync-skills.sh              re-trae las skills que se mantienen fuera de este repo
scripts/check-conformance.sh        valida los dos formatos y la spec de Agent Skills
scripts/measure.sh                  peso en disco y coste de contexto por plugin
scripts/sync-opencode.sh            regenera los enlaces de .opencode/skills/
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
