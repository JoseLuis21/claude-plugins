---
name: go-hexagonal-multitenant-skills
description: Estructura un microservicio o Lambda en Go con arquitectura hexagonal (core/domain, core/ports, core/services, adapters driving/driven, app/wire) y conexiones a bases de datos multi-tenant resueltas por número de nodo (BC_HOST_MYSQL_N + bd_name → pool cacheado por proceso), con las optimizaciones probadas en Bicom: pool por nodo+base con lifetime corto para Aurora/Lambda, DSN sin credenciales en texto, interpolateParams, streaming fila a fila con memoria constante, queries independientes en paralelo con errgroup, subida a S3 por io.Pipe, contexto con margen antes del deadline y WithoutCancel para escribir el estado de error, errores de negocio vs infraestructura (reintento SQS parcial), métricas EMF por query/nodo, FlexInt para JSON de PHP, decimal en vez de float, y cmd/local para paridad. Úsala cuando pidan: portar un servicio Node/TS/PHP a Go, "hexagonal" o "ports and adapters" en Go, conectarse a "el nodo N" / varias bases por tenant, pools de MySQL en Lambda, un consumidor SQS→Lambda en Go, generar reportes/archivos grandes sin cargar todo en memoria, subir a S3 en streaming, medir queries por tenant en CloudWatch, o revisar por qué un servicio Go se queda sin conexiones/memoria/tiempo.
---

# Go hexagonal + conexiones multi-tenant por nodo

Patrón probado en `bicom-report-stock-movements` (Lambda SQS → MySQL por nodo → PDF/XLSX →
S3 + Redis) heredando decisiones que `bicom-ms-stock-closing` ya pagó en producción.
Las plantillas en `templates/` se copian y se adaptan (son `.go.tmpl`: sustituir `<module>`
por la ruta del módulo y ajustar el nombre del paquete).

---

## 1. Layout hexagonal (el núcleo no importa adaptadores)

```
cmd/lambda                 binario real (SQS → servicio)
cmd/local                  misma lógica a disco: herramienta de paridad, NO escribe en Redis/S3
internal/core/domain       entidades y reglas puras (acumuladores, filtros, errores de negocio)
internal/core/ports        interfaces que el núcleo NECESITA del exterior (no "lo que el adapter ofrece")
internal/core/services     casos de uso; reciben ports, nunca *sql.DB ni clientes AWS
internal/adapters/driving  entrada: handler SQS/HTTP/cron
internal/adapters/driven   salida: mysql, redis, s3, xlsx, pdf, localfs
internal/app               wire.go: único lugar que conoce config + adapters + services
internal/config            Load() lee env; Validate() falla al arrancar con lista de faltantes
internal/platform          env, dates, metrics: utilidades sin dominio
```

Reglas que hacen que funcione:
- **`var _ ports.X = (*Impl)(nil)`** en cada adapter: el compilador verifica el contrato.
- **Los ports devuelven tipos del dominio** (`ValueMap`, `*domain.Company`), nunca `*sql.Rows`.
- **Streaming por callback en el port**: `StreamMovements(ctx, filters, yield func(*Row) error)`.
  El servicio no sabe que hay un cursor; el adapter no sabe qué se hace con la fila.
- **Fábrica de gateways por tenant** (`TenantGatewayFactory.ForTenant(ctx, node, dbName)`): el
  servicio pide "el tenant", no "la conexión".
- **`go test ./...` corre sin base**: los servicios se prueban con fakes de los ports (ver los
  `fakeGateway`/`fakeState` del repo de referencia). Cada fix de producción deja un test que
  reproduce el caso (p. ej. `TestMarkFailedSobreviveAlContextoVencido`).
- **Flags de comportamiento** (`mysql.Flags{...}`) se inyectan en el adapter desde `wire.go`;
  arrancan replicando el sistema anterior para poder validar paridad antes de encender nada.

## 2. Conexiones por número de nodo (`templates/mysql_pools.go.tmpl`)

El mensaje trae `{bd_id, host, bd_name}` donde **`host` es un índice de nodo (1..10), no un
hostname**. La configuración lo resuelve:

```
BC_HOST_MYSQL_{n}  BC_PORT_MYSQL_{n}  BC_USER_MYSQL_{n}  BC_PASSWORD_MYSQL_{n}
```

- `config.MysqlNode(n)` devuelve credenciales o un error claro (`nodo 7 sin configurar (falta
  BC_HOST_MYSQL_7)`); **nunca** fallback a localhost. El sufijo va siempre, incluido el `_1`.
- `Pools` guarda **un `*sql.DB` por `"{nodo}:{base}"`** en un mapa con mutex, vivo durante todo el
  proceso: en Lambda el entorno se reutiliza entre invocaciones y un tenant recurrente no vuelve
  a abrir conexiones. `Close()` solo lo usa `cmd/local`.
- Usar **endpoints reader** (`cluster-ro-…`) para reportes: nunca cargar agregaciones al writer.
- **Reserved concurrency de la Lambda (2–4) es el único freno por nodo RDS.** Los nodos son
  compartidos con la webapp; un pool grande por invocación multiplicado por N invocaciones los
  tumba.

DSN (decisiones que ya costaron un incidente cada una):

| Ajuste | Por qué |
|---|---|
| `cfg.User/Passwd` asignados al `driver.Config`, no en el string | el driver no desescapa la contraseña del DSN: un secreto con `+ / =` da "Access denied" indistinguible de credencial mala |
| `parseTime=false` | hay `'0000-00-00'` en fechas; con `parseTime=true` el `Scan` revienta. Leer fechas como texto |
| `interpolateParams=true` | un round-trip por query (sin prepare/execute/close); sigue siendo seguro |
| `readTimeout` ≥ timeout del job | si es menor, una query larga muere con `invalid connection` opaco |
| `charset=utf8&collation=utf8_general_ci` | igualar la conexión de la webapp |
| `SetMaxOpenConns(3–4)`, `SetMaxIdleConns(2)` | mínimo = número de queries que corren en paralelo |
| `SetConnMaxLifetime(5m)`, `SetConnMaxIdleTime(1m)` | Aurora corta conexiones en failover y Lambda congela el entorno: sin lifetime corto quedan conexiones muertas |

## 3. Flujo de un reporte con memoria constante

```
Q1 empresa ─┐
Q2 apertura ├─ errgroup.WithContext (cada una con su conexión del pool)
Q3 precios ─┘
Q4 detalle → cursor rows.Next() → acumulador por producto → sink.WriteRow → io.Pipe → S3 multipart
```

- **`errgroup`** para queries independientes; el pool tiene que tener ≥ ese número de conexiones o
  se serializan solas.
- **Cursor fila a fila** con una sola `struct` reutilizada entre iteraciones (cero allocs por
  fila). Log de `first_byte_ms` (tiempo hasta la primera fila = lo que tarda MySQL en planificar)
  vs. total (= transferencia + escritura): dice si el problema es la base o el reporte.
- **Cortar el cursor desde el callback** devolviendo error (p. ej. tope de filas para PDF): el
  costo queda acotado por el techo, no por el tamaño del resultado. `defer rows.Close()` aborta
  el cursor del lado del servidor.
- **Nunca un `COUNT(*)` previo** para "saber cuántas filas vienen": cuesta lo mismo que la query.
- **Excel con `StreamWriter`** (excelize) y **PDF en Go puro** (fpdf): sin Chromium, decenas de MB.
- **S3 por `io.Pipe`** (`templates/s3_pipe_store.go.tmpl`): el escritor produce en una goroutine,
  el uploader multipart consume. Un `io.Pipe` no tiene buffer: escribir y subir en la misma
  goroutine es deadlock inmediato. Si el escritor falla, `CloseWithError` aborta la subida y se
  devuelve la causa real. Bucket **en la misma región** que la Lambda (cross-region duplicó el
  tiempo de subida).
- **`decimal.Decimal` (shopspring) para cantidades y montos**, nunca `float64`: el port de
  Node/JS a Go es donde aparecen los centavos de diferencia. Redondear solo para presentar.

## 4. Contextos, deadlines y qué se reintenta

- El handler reserva **`DEADLINE_MARGIN_SECONDS`** antes del deadline real de la Lambda
  (`context.WithDeadline(parent, deadline.Add(-margin))`): hace falta tiempo para escribir el
  error en Redis; si no, el front queda en "procesando" para siempre.
- **El Save del estado de error usa `context.WithoutCancel(ctx)` + timeout propio (5 s)**: el
  fallo más común es que el contexto ya venció, y con ese contexto el Save también falla — justo
  cuando más importa.
- `QUERY_TIMEOUT_SECONDS` alineado con el timeout de la función.
- **Dos clases de error** (`templates/domain_errors.go.tmpl`):

| Error | Redis | SQS |
|---|---|---|
| `BusinessError` (rechazo que el usuario debe ver) | `state=2` + mensaje | eliminado: reintentar da lo mismo |
| Infraestructura (MySQL, S3, Redis) | `state=2` + error genérico | **vuelve a la cola** (`ReportBatchItemFailures`), DLQ tras 3 |
| Mensaje ilegible / llave inexistente | — | eliminado con log |

- Handler SQS (`templates/sqs_handler.go.tmpl`): batch size 1, fallos parciales por mensaje,
  `recover()` por mensaje para que un panic no se lleve el lote, visibility timeout ≥ 6× timeout.
- **`FlexInt`/`FlexString`** (`templates/domain_flex.go.tmpl`): el publisher es PHP y manda
  `"26"` o `26` indistintamente; el front compara `"2"`/`"3"` como texto.
- **El objeto de Redis se reescribe completo conservando los campos del front** (`raw
  map[string]any`): solo se tocan `state`, `start`, `end`, `response`, `url`. La llave
  `Report[{bd_id}][{QueueName}]` es un **contrato con el front**: renombrarla exige cambiar los
  dos lados (nos pasó: el front escribía en la vieja y la Lambda leía la nueva → "procesando"
  eterno con 0 mensajes en la cola).

## 5. Configuración y secretos

- **Un solo sitio llama `os.Getenv`** (`templates/env.go.tmpl`): `Get/Int/Bool/List` con
  defaults, y `LoadDotEnv` que **no pisa** variables ya definidas y busca el `.env` hacia arriba
  (los binarios corren desde subdirectorios).
- En Lambda la config son **variables de la función**, no un `.env` horneado (`.env` en
  `.dockerignore`). Rotar un secreto no exige reconstruir. Ojo al límite de **4 KB**: siete nodos
  con host/user/pass/port ≈ 2,5 KB; si crece, mover a Secrets Manager leído en el arranque.
- `Validate()` lista **todas** las faltantes de una vez, al arrancar, no a mitad de un reporte.
- Interruptores de dos niveles para rollouts por tenant: `X_TENANTS_ENABLED` /
  `X_TENANTS_DISABLED` mandan sobre el default global (`SnapshotEnabledFor(companyID)`).

## 6. Observabilidad sin salir a internet (VPC sin NAT)

- **EMF** (`templates/metrics_emf.go.tmpl`): la métrica va en la **misma línea** de log con el
  nodo `_aws`; CloudWatch la convierte en métrica real sin API, sin permisos, sin NAT.
- Dimensiones de **cardinalidad acotada**: `Query × Node` y `Query`. **`db_name` nunca es
  dimensión** (miles de tenants = miles de métricas cobradas); va como propiedad, buscable en
  Logs Insights y gratis. Se declaran dos juegos de dimensiones para poder agregar entre nodos.
- Cada query loguea: nombre (`Q3 unitary_values`), nodo, base, `duration_ms`, filas, SQL
  colapsado a una línea y args. Las queries fallidas también emiten métrica (`QueryErrors`): sin
  eso un tenant roto se ve como "sin tráfico".
- Desenlace del reporte como dimensión fija: `ok | rejected | error | invalid`.
- `EMF_METRICS=false` en local cae a log normal.
- **Cómo revisar una Lambda después de desplegar** (script de logs, métricas, "la base o la
  query", "quedó procesando", checklist): [`references/medir-rendimiento-lambdas.md`](references/medir-rendimiento-lambdas.md)
  y el script [`templates/lambda-perf.sh`](templates/lambda-perf.sh).
- Lambda Insights horneado en la imagen (copiar **todo `/opt`** del rpm, no solo `/opt/extensions`;
  sin el `.toml` el agente hace panic y marca cada invocación como `Extension.Crash`).

## 7. Paridad y despliegue

- **`cmd/local`** corre la misma lógica con salida a disco: lee filtros de Redis en modo
  `ReadOnly` (Save no-op) o de un JSON, y no escribe en S3. Es la herramienta para comparar
  contra el sistema anterior tenant por tenant antes de encender.
- Lambda de contenedor **arm64** (`provided.al2023`), 512 MB–1 GB, imagen por SHA en ECR;
  rollback = `update-function-code --image-uri :<sha-anterior>`.
- Ver `docker-golang-skills` y `github-actions-skills` para el build y el pipeline.

## 8. Checklist al arrancar un servicio nuevo

- [ ] `core/` no importa `database/sql`, AWS ni Redis; `go test ./...` sin infraestructura.
- [ ] Port de streaming por callback; una struct reutilizada por fila.
- [ ] Pool por `nodo:base` cacheado; DSN con credenciales fuera del string; lifetime corto.
- [ ] Reader endpoints + reserved concurrency baja.
- [ ] `errgroup` para queries independientes; pool ≥ paralelismo.
- [ ] Deadline con margen + `WithoutCancel` para el Save de error.
- [ ] `BusinessError` vs infraestructura → qué se reintenta en SQS.
- [ ] `decimal`, no `float64`; `FlexInt` para JSON de PHP.
- [ ] EMF por query/nodo; `db_name` como propiedad.
- [ ] `cmd/local` para paridad; flags que arrancan replicando el sistema viejo.
- [ ] Contratos externos (llave Redis, ACL S3, textos de error) documentados y con test.
