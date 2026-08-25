---
name: docker-golang-skills
description: Configura el build de Docker de un servicio o de una AWS Lambda de contenedor (Go por defecto) con cache de BuildKit y soporte multiplataforma amd64/arm64, de forma que el mismo repo sirva para local/docker-compose, GitHub Actions, Railway y ECR. Úsala cuando pidan dockerizar un proyecto, acelerar un `docker build` lento, cachear dependencias/compilación, publicar la imagen desde GitHub Actions (GHCR o ECR), desplegar en Railway, empaquetar una Lambda como imagen (provided.al2, bootstrap, Lambda Insights, Graviton), o compilar para ARM / Apple Silicon (platform, TARGETARCH, buildx).
---

# Docker build con cache + multiplataforma (local / GitHub Actions / Railway / Lambda)

Patrón probado en producción: build en dos etapas, cache mounts de
BuildKit, cross-compilación por arquitectura y un Dockerfile aparte para Railway.
Objetivo: un cambio incremental recompila en segundos en vez de ~155s.

La variante para **AWS Lambda como imagen de contenedor** (probada en una Lambda de cron
en producción) reusa el mismo esqueleto y cambia la etapa
final: ver *AWS Lambda*.

## Piezas

| Archivo                        | Para qué                                       | Cache mounts                     |
| ------------------------------ | ---------------------------------------------- | -------------------------------- |
| `Dockerfile`                   | local, docker-compose, GitHub Actions, VPS     | Sí                               |
| `Dockerfile.railway`           | solo Railway                                   | No (o con `id=s/<service-id>-…`) |
| `railway.json`                 | apunta Railway a `Dockerfile.railway`          | —                                |
| `.github/workflows/docker.yml` | build multi-arch + push a GHCR con cache `gha` | Sí (capas)                       |
| `.dockerignore`                | evita invalidar capas y engordar el contexto   | —                                |
| `Dockerfile.lambda`            | AWS Lambda como imagen de contenedor           | Sí                               |
| `.github/workflows/deploy.yml` | build 1 arch + push a ECR + update de Lambda   | Sí (capas)                       |

Las plantillas están en `templates/` de esta skill. Cópialas y sustituye
`<project>` por un slug del repo (los `id` de cache deben ser únicos por proyecto).

## Flujo

1. **Detecta el estado actual**: ¿ya hay `Dockerfile`, `railway.json`, workflows?
   Lee lo que exista antes de escribir; conserva puerto expuesto, `CMD`, versión
   de imagen base y paquetes del sistema que ya use el proyecto.
2. **Escribe el `Dockerfile`** desde `templates/Dockerfile` (si el artefacto es
   una Lambda, salta al paso 3). Ajusta:
   - versión de Go / imagen base (mantén la que ya usa el repo),
   - los `COPY` de código (`cmd`, `internal`, …) — copiar solo lo necesario, y
     **siempre después** de `go.mod go.sum` + `go mod download`,
   - `id=` de los cache mounts → `<project>-gomod`, `<project>-gobuild`,
   - `EXPOSE` y `CMD`.
3. **Si el artefacto es una Lambda**, usa `templates/Dockerfile.lambda` en vez del
   Dockerfile de servicio y salta los pasos de Railway. Lee la sección
   *AWS Lambda* antes de escribirlo: la imagen final cambia y hay tres errores
   que no perdonan (rpm de la arquitectura equivocada, `RUN` en la etapa final,
   attestations de buildx).
4. **Escribe `Dockerfile.railway`** (`templates/Dockerfile.railway`): idéntico pero
   **sin** `--mount=type=cache` y **sin** `COPY .env`.
5. **Escribe `railway.json`** (`templates/railway.json`) con
   `build.dockerfilePath = "Dockerfile.railway"`.
6. **Escribe el workflow**: `templates/docker.yml` (GHCR) para servicios,
   `templates/lambda-deploy.yml` (ECR + `update-function-code`) para Lambdas.
   Si el repo no publica imagen, omítelo y dilo.
7. **Revisa `.dockerignore`** (`templates/dockerignore`): sin él, cualquier archivo
   tocado invalida el `COPY` y tira el cache de capas.
8. **Añade targets al Makefile** si el repo tiene uno (`templates/Makefile.snippet`).
9. **Verifica** (ver abajo) y reporta tiempos reales, no estimados.

## Reglas que no se negocian

- **`go.mod`/`go.sum` se copian y descargan antes que el código.** Es la mitad del
  ahorro; los cache mounts son la otra mitad.
- **Nunca `COPY .env` en la imagen.** Es un secreto horneado en cada capa, y hace
  que el Dockerfile no sirva en CI ni en Railway (el archivo no existe ahí). Las
  variables entran por `env_file:` en compose, por el dashboard en Railway y por
  secrets en CI. Si un repo ya tiene ese `COPY`, señálalo y quítalo.
- **Un `id=` de cache por proyecto y por arquitectura.** Ids compartidos entre
  repos hacen que dos builds se pisen el cache. En multi-arch, incluye
  `$TARGETARCH` en el id o los dos builds concurrentes se bloquean entre sí.
- **BuildKit tiene que estar activo.** Docker ≥23 lo trae por defecto; en hosts
  viejos, `DOCKER_BUILDKIT=1 COMPOSE_DOCKER_CLI_BUILD=1`.
- **La imagen final es `alpine` + binario estático** (`CGO_ENABLED=0`), con
  `ca-certificates` y `tzdata` instalados: sin ellos fallan TLS y las zonas
  horarias en runtime. Excepción: en una Lambda la base la pone AWS y la etapa
  final no instala nada — ver *AWS Lambda*.

## Plataforma / ARM

```dockerfile
FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS builder
ARG TARGETOS TARGETARCH
RUN ... GOOS=$TARGETOS GOARCH=$TARGETARCH go build ...
```

- `--platform=$BUILDPLATFORM` hace que el builder corra **nativo** (arm64 en un
  Mac M-series, amd64 en el runner) y Go cross-compile al target. Sin eso, buildx
  emula el builder con QEMU y el build se vuelve lentísimo.
- Por eso **no hace falta `docker/setup-qemu-action`** con Go: no se ejecuta nada
  de la arquitectura ajena durante el build.
- La etapa final **no lleva `--platform`**: hereda `TARGETPLATFORM` y sale la
  imagen correcta. Solo pon `--platform=linux/amd64` explícito ahí si quieres
  forzar una imagen amd64 desde un Mac ARM (p. ej. el servidor de prod es Intel).
- Nunca dejes `GOARCH=amd64` fijo si vas a construir multi-arch: produce un
  binario amd64 dentro de una imagen etiquetada arm64.
- Un solo arch: `docker build --platform linux/arm64 .`
  Multi-arch (requiere push, no queda en el daemon local):
  `docker buildx build --platform linux/amd64,linux/arm64 --push -t <img> .`

## AWS Lambda (imagen de contenedor)

Mismo esquema de dos etapas, pero la imagen final es la base de Lambda y hay
reglas propias. Plantillas: `templates/Dockerfile.lambda` y
`templates/lambda-deploy.yml`.

```dockerfile
FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS builder
ARG TARGETOS TARGETARCH
RUN ... GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /out/bootstrap ./cmd/<lambda>

FROM public.ecr.aws/lambda/provided:al2          # sin --platform
COPY --from=builder /out/bootstrap ${LAMBDA_TASK_ROOT}/bootstrap
ENTRYPOINT ["/var/task/bootstrap"]
```

- **El binario se llama `bootstrap` y vive en `${LAMBDA_TASK_ROOT}` (`/var/task`)**:
  es lo que espera el runtime `provided`. `ENTRYPOINT` en exec form **no expande
  variables**, así que la ruta va literal.
- **La etapa final no puede tener ningún `RUN`.** Es lo que permite construir una
  imagen arm64 desde un runner amd64: solo se copian archivos, nada del target se
  ejecuta, no hace falta QEMU. Cualquier `RUN` ahí obliga a emular y el build se
  desploma (o revienta).
- **Una Lambda tiene UNA arquitectura: no publiques multi-arch.** Un manifest
  list solo agrega peso. Elige `arm64` (Graviton: más barato) o `amd64` y punto.
- **`--provenance=false --sbom=false` al hacer push.** Los manifests OCI con
  attestations que buildx adjunta por defecto los rechaza Lambda al desplegar:
  *"The image manifest, config or layer media type ... is not supported"*.
- **Despliega por tag SHA**, no por `:latest`, y encadena
  `aws lambda update-function-code --image-uri ... --architectures arm64` +
  `aws lambda wait function-updated`. Sin el wait, cualquier
  `update-function-configuration` posterior falla con `ResourceConflictException`.
  `--architectures` en `update-function-code` es lo que migra la función de
  x86_64 a Graviton; sin esa bandera la función sigue en la arquitectura vieja y
  la imagen nueva no arranca.
- **Sin `apk add tzdata` que valga**: en la etapa final no instalas nada. Si el
  código usa `time.LoadLocation`, empotra la base con `import _ "time/tzdata"`
  (~450 KB) y deja de depender de lo que traiga la imagen.
- **Si renombras el binario en un repo existente, revisa el override**:
  `aws lambda get-function-configuration --query ImageConfigResponse`. Si trae un
  `EntryPoint` apuntando al nombre viejo, el deploy arranca un ejecutable que ya
  no existe.
- `provided:al2023` es más chica y arranca antes, pero el rpm de Lambda Insights
  publicado es para AL2. Proponla como cambio aparte, no la mezcles con la
  migración a ARM.

### Extensiones (Lambda Insights)

**Las Lambdas de contenedor no admiten layers**, así que la extensión se hornea
en la imagen. Tres trampas:

1. **El rpm es distinto por arquitectura.** Un Dockerfile que dejó de ser amd64
   se lleva el rpm x86_64 puesto y la extensión queda muerta *en silencio*: la
   función corre, pero no hay métricas en CloudWatch.
   - x86_64: `https://lambda-insights-extension.s3-ap-northeast-1.amazonaws.com/amazon_linux/lambda-insights-extension.rpm`
   - arm64: `https://lambda-insights-extension-arm64.s3.ap-northeast-1.amazonaws.com/amazon_linux/lambda-insights-extension-arm64.rpm`
2. **Se EXTRAE, no se instala.** `rpm -U` valida la arquitectura del host y
   rechaza el paquete arm64 en un runner amd64; y si lo pones en la etapa final,
   rompes la regla del "sin RUN". Etapa aparte en `$BUILDPLATFORM`.
3. **Se copia TODO `/opt`, no solo `/opt/extensions`.** El rpm trae el binario
   *y* su configuración, en dos árboles distintos:

   ```
   ./opt/extensions/cloudwatch_lambda_agent        # binario (Rust)
   ./opt/cloudwatch/cloudwatch_lambda_agent.toml   # su config
   ./opt/cloudwatch/manifest.json
   ```

   Copiando solo `extensions`, el agente arranca sin config y hace panic:

   ```
   panicked at src/settings.rs:19:57: Failed to initialize settings.:
     configuration file "/opt/cloudwatch/cloudwatch_lambda_agent" not found
   INIT_REPORT ... Status: error   Error Type: Extension.Crash
   ```

   Y esto **no es cosmético**: una extensión que crashea marca la invocación
   entera como `Status: error`, aunque el handler haya corrido bien (verás
   `START`/`END` limpios y un `REPORT` en error). Es el fallo más confuso de
   toda esta sección, porque el stack trace apunta a Rust y el código es Go.

```dockerfile
FROM --platform=$BUILDPLATFORM public.ecr.aws/amazonlinux/amazonlinux:2 AS insights
ARG TARGETARCH
RUN yum install -y -q cpio && curl -fsSL "$URL_SEGUN_TARGETARCH" -o /tmp/i.rpm && \
    mkdir -p /insights && cd /insights && rpm2cpio /tmp/i.rpm | cpio -idm && \
    test -x /insights/opt/extensions/cloudwatch_lambda_agent && \
    test -f /insights/opt/cloudwatch/cloudwatch_lambda_agent.toml
# y en la final:
COPY --from=insights /insights/opt /opt
```

Los dos `test` valen su peso: sin ellos el build pasa verde y el error sale en
producción, una invocación después.

**Lado AWS**: el rol de ejecución necesita la policy gestionada
`CloudWatchLambdaInsightsExecutionRolePolicy`. Sin ella la extensión ya no
crashea, pero no puede publicar y las métricas no aparecen. Y si la función no
necesita Insights (un cron que corre en milisegundos, p. ej.), lo más sano es
borrar la etapa entera: es ~5 MB de binario y un proceso extra por cold start.

## Cache en GitHub Actions — la parte que engaña

`cache-from/to: type=gha` cachea **capas**, no los `--mount=type=cache`. En un
runner efímero, `go mod download` se salta por cache de capa, pero el cache de
compilación de Go (`/root/.cache/go-build`) **se pierde entre runs** salvo que
uses `reproducible-containers/buildkit-cache-dance` (ver
`templates/docker.yml`, sección comentada). Empieza sin el dance: `type=gha,mode=max`
ya suele bajar el build a la mitad. Si al usuario le importan los segundos
restantes, actívalo — pero dile que añade sincronización de directorios en cada run.

## Railway

Railway construye con su propio builder; los `--mount=type=cache` con `id` libre
**fallan o se ignoran**, por eso existe `Dockerfile.railway` sin ellos. Railway
soporta cache mounts únicamente si el id va namespaced con el service id
(`id=s/<service-id>-go-build`). Es una optimización opcional: propónsela al
usuario, no la apliques sola — hay que pegar el service id del dashboard y si se
equivoca el build revienta. El default seguro es el Dockerfile sin cache mounts.
Railway inyecta las env vars desde el dashboard: nada de `.env` en la imagen.

## Otros stacks

Mismo esquema, cambiando qué se cachea:

| Stack  | Manifiestos primero                           | Cache mounts                             |
| ------ | --------------------------------------------- | ---------------------------------------- |
| Go     | `go.mod go.sum`                               | `/go/pkg/mod`, `/root/.cache/go-build`   |
| Node   | `package.json package-lock.json`              | `/root/.npm` (o `/pnpm/store`)           |
| Python | `pyproject.toml uv.lock` / `requirements.txt` | `/root/.cache/pip` (o `/root/.cache/uv`) |
| Rust   | `Cargo.toml Cargo.lock`                       | `/usr/local/cargo/registry`, `target/`   |

Con lenguajes compilados nativos (Rust, CGO) el cross-compile no es gratis: ahí sí
puede hacer falta QEMU o un toolchain cruzado, y conviene decirlo antes de prometer
multi-arch.

## Verificación

```bash
docker build -t <img>:test .                 # 1ª vez: build completo
touch <un archivo .go> && time docker build -t <img>:test .   # 2ª: debe ser segundos
docker build -f Dockerfile.railway -t <img>:railway .          # Railway no puede romperse
docker buildx build --platform linux/arm64 -t <img>:arm .      # cross-compile
docker image inspect <img>:arm --format '{{.Architecture}}'    # -> arm64
docker run --rm <img>:test <cmd de health o --version>
```

Para una Lambda:

```bash
docker buildx build --platform linux/arm64 --provenance=false --sbom=false \
  --load -f Dockerfile.lambda -t <img>:local .
docker image inspect <img>:local --format '{{.Architecture}}'   # -> arm64
docker run --rm --entrypoint /bin/sh <img>:local \
  -c 'ls /opt/extensions /opt/cloudwatch'   # binario Y config, si usas Insights
# Invocación local con el RIE que ya trae la imagen base:
docker run --rm -p 9000:8080 --entrypoint /usr/local/bin/aws-lambda-rie \
  <img>:local /var/task/bootstrap
curl -XPOST "http://localhost:9000/2015-03-31/functions/function/invocations" -d '{}'
```

Tras el primer deploy, mira los logs de CloudWatch aunque la invocación
"funcione": un `Extension.Crash` deja el `REPORT` en `Status: error` sin tocar
la salida del handler, así que no se nota desde el lado de la aplicación.

Reporta el tiempo del segundo build medido de verdad. Si el Dockerfile de Railway
no se pudo probar por falta de contexto, dilo explícitamente. Si no había daemon
de Docker para verificar la arquitectura de la imagen, dilo: `Architecture:
amd64` en una función arm64 es un deploy que falla en producción, no un detalle.
