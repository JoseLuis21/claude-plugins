# syntax=docker/dockerfile:1.7
#
# Build en dos etapas para <project>.
# Sirve para: docker-compose (local y prod), VPS y GitHub Actions.
# Para Railway se usa Dockerfile.railway (su builder no soporta cache mounts).
#
# --platform=$BUILDPLATFORM: el builder corre NATIVO (arm64 en un Mac M-series,
# amd64 en un runner) y Go cross-compila hacia $TARGETARCH. Sin esto, buildx
# emularía el builder con QEMU y el build se volvería lentísimo.
FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS builder

WORKDIR /src

RUN apk add --no-cache ca-certificates tzdata

# Los manifiestos van antes que el código: mientras go.mod/go.sum no cambien,
# esta capa se reutiliza aunque cambie todo lo demás.
COPY go.mod go.sum ./
RUN --mount=type=cache,id=<project>-gomod,target=/go/pkg/mod,sharing=locked \
    go mod download

COPY cmd ./cmd
COPY internal ./internal

# Cache mounts (BuildKit): persisten el module cache y el build cache de Go entre
# builds, así un cambio incremental solo recompila los paquetes tocados
# (~155s -> segundos). Los `id` explícitos acotan el cache a este proyecto.
# $TARGETARCH en el id del build cache evita que los builds amd64 y arm64 se
# bloqueen y se invaliden entre sí al construir multi-arch.
ARG TARGETOS
ARG TARGETARCH
RUN --mount=type=cache,id=<project>-gomod,target=/go/pkg/mod,sharing=locked \
    --mount=type=cache,id=<project>-gobuild-${TARGETARCH},target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH:-amd64} \
    go build -ldflags="-s -w" -o /out/api ./cmd/api

# Sin --platform: esta etapa hereda $TARGETPLATFORM y produce la imagen de la
# arquitectura pedida. Solo fija --platform=linux/amd64 aquí si quieres forzar
# una imagen amd64 desde un Mac ARM (p. ej. el servidor de prod es Intel).
FROM alpine:3.22

WORKDIR /app

# ca-certificates: TLS hacia APIs externas. tzdata: fechas en hora local.
RUN apk add --no-cache ca-certificates tzdata

COPY --from=builder /out/api /app/api

# Nada de `COPY .env`: sería un secreto horneado en la imagen y rompería el build
# en CI y en Railway, donde ese archivo no existe. Las variables entran por
# `env_file:` en compose, por el dashboard en Railway y por secrets en CI.

EXPOSE 3000

CMD ["/app/api"]
