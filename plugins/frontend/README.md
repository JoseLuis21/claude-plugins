# frontend

`frontend@jl-stack`

Tres skills para aplicaciones React/Next.js: construir la UI, que vaya rápida, que no tenga
agujeros y commitear con criterio.

| Skill | Se activa cuando pides | Trae |
| --- | --- | --- |
| `shadcn` | añadir, buscar, arreglar o componer componentes de shadcn/ui, `shadcn init`, presets, registries, o al trabajar en un proyecto con `components.json` | docs del CLI, registries, personalización, y reglas por tema (formularios, composición, estilos, iconos, chat, base vs radix) |
| `vercel-react-best-practices` | escribir, revisar o refactorizar React/Next.js pensando en rendimiento: waterfalls, tamaño del bundle, re-renders, data fetching | 70 reglas de Vercel Engineering en 8 categorías, priorizadas por impacto, cada una con ejemplo correcto e incorrecto |
| `owasp-security-frontend` | revisar la seguridad del cliente, prevenir XSS, configurar una CSP, decidir dónde guardar el token, evitar secretos en el bundle, revisar Server Actions | el Top 10 aplicado al navegador, con el reparto de responsabilidad cliente/servidor y un checklist de salida a producción |

## Notas

**La de seguridad existe en los dos plugins y no son la misma.** Se llaman distinto — `owasp-security-frontend` aquí y `owasp-security` en `backend`— para que no haya duda de cuál se invoca cuando los dos están instalados. La de aquí cubre
navegador y la capa de servidor del framework (Server Actions, route handlers, middleware); la
de `backend` cubre API, base de datos y servicio a servicio. Si instalas los dos plugins tendrás
`/frontend:owasp-security-frontend` y `/backend:owasp-security`, cada una con su ámbito.

**`git-commit` no está aquí**: vive en el plugin `common`, que se instala solo como dependencia
de este. Se invoca con `/common:git-commit`.

## Origen y créditos

| Skill | Origen | Licencia |
| --- | --- | --- |
| `owasp-security-frontend` | propia, escrita sobre el estándar [OWASP Top 10:2021](https://owasp.org/Top10/) | propia |
| `shadcn` | [shadcn/ui](https://github.com/shadcn/ui) `skills/shadcn` | MIT |
| `vercel-react-best-practices` | [vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills) `skills/react-best-practices` | MIT (declarada en el frontmatter de la skill) |

Las tres de terceros se re-traen con [`scripts/sync-skills.sh`](../../scripts/sync-skills.sh).
De `shadcn` se omiten `evals/` (fixtures de test) y `agents/` (configuración de otra
plataforma); de `react-best-practices`, el `README.md`, que son instrucciones de build del repo
de origen.
