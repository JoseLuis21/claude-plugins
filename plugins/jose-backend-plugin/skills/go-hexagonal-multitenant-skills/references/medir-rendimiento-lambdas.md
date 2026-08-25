# Medir el rendimiento de las Lambdas de reportes

Guía para revisar cualquier Lambda Go de Bicom (`bicom-lambda-report-*`) después de un
despliegue o cuando alguien dice "está lento". Sirve igual para las que vengan: todas usan el
mismo patrón de logs (slog JSON + métricas EMF), así que el mismo script y las mismas
consultas aplican.

Lambdas hoy:

| Función | Cola SQS | Llave Redis | Repo |
|---|---|---|---|
| `bicom-lambda-report-stock-movements` | `BICOM-SQS-REPORT-STOCK-MOVEMENTS` | `Report[{bd_id}][report_stock_movements_go]` | `bicom-report-stock-movements` |
| `bicom-lambda-report-stock-product-list` | `BICOM-SQS-REPORT-STOCK-PRODUCT-LIST` | `Report[{bd_id}][report_stock_product_list_go]` | `bicom-report-stock-product-list` |

---

## 1. El script: qué pasó en la última hora

```bash
scripts/lambda-perf.sh bicom-lambda-report-stock-product-list        # última hora
scripts/lambda-perf.sh bicom-lambda-report-stock-movements 180       # últimas 3 horas
```

Imprime, por invocación, las líneas que importan y termina con la línea `REPORT` de Lambda:

```
18:05:44 INFO pool MySQL creado | db_name=bicom_rbahamonde
18:05:44 INFO query ejecutada | Query=Q1 company QueryDurationMs=9 QueryRows=1
18:05:44 INFO cursor abierto | first_byte_ms=64
18:05:45 INFO query ejecutada | Query=Q3 products_stream QueryDurationMs=335 QueryRows=5352
18:05:45 INFO reporte procesado (metrica) | Outcome=ok ReportDurationMs=809
18:05:45 REPORT total=811.84ms mem=66MB init=710.00ms
```

### Cómo leer cada número

| Campo | Qué es | Qué esperar | Si está mal |
|---|---|---|---|
| `init=` | Arranque en frío del contenedor (ENI de VPC + imagen). Solo aparece en cold start | 0,5–1 s; hasta 5 s la primera vez tras un deploy | No es del handler; si molesta: provisioned concurrency o SnapStart no aplica a imagen |
| `pool MySQL creado` | Se abrió un pool nuevo para `nodo:base` | Solo en cold start o tenant nuevo | Si aparece en cada invocación, el entorno no se reutiliza (deploys seguidos, concurrencia alta) |
| `QueryDurationMs` por `Query` | Tiempo de cada consulta **desde la Lambda** (incluye red y transferencia) | Q1 < 50 ms; el resto depende del tenant | Ver §3: es la base o es la query |
| `first_byte_ms` | Tiempo hasta la primera fila del cursor = lo que MySQL tarda en **planificar y empezar a servir** | Decenas de ms | Alto = la query está mal (ordena/agrupa todo antes de servir). Total alto con first_byte bajo = transferencia + escritura del archivo |
| `etapa: ...` / `consultas previas` | Duración por etapa del servicio | Proporción sana: consultas ≫ serializar+subir | Subida a S3 lenta = bucket en otra región |
| `unitary_rescues` (movimientos) | Productos rescatados uno a uno fuera de la ventana de Q3 | Decenas | Cientos → subir `COST_LOOKBACK_MONTHS` |
| `Outcome` | `ok` / `rejected` (negocio, no se reintenta) / `error` (infra, vuelve a SQS) / `invalid` | `rejected` es normal (PDF grande) | `error` repetido → revisar `error=` y la DLQ |
| `REPORT total=` | Duración facturada del handler | < timeout − margen | Cerca de 300 s: va a haber `Task timed out` |
| `mem=` | Pico de memoria | 50–150 MB | Si supera ~70 % de `MemorySize`, subir memoria (también da más CPU) |
| `!!! TIMEOUT` | Lambda mató la función | Nunca | El mensaje vuelve a SQS; tras 3 va a la DLQ. El front ve el error solo si alcanzó a escribirse en Redis (margen `DEADLINE_MARGIN_SECONDS`) |

---

## 2. Métricas EMF en CloudWatch (namespace `Bicom/ReportStockMovements` o el del repo)

Sin leer logs, para gráficos y alarmas:

| Métrica | Dimensiones | Uso |
|---|---|---|
| `QueryDurationMs` | `Query`, `Query × Node` | p95 por consulta; qué nodo está lento |
| `QueryRows` | `Query`, `Query × Node` | una query que baja a 0 filas donde antes daba miles |
| `QueryErrors` | `Query`, `Query × Node` | alarma de tenant/nodo roto |
| `ReportDurationMs` | `Outcome` | tiempo que espera el usuario |
| `ReportCount` | `Outcome` | tasa de error: `error / (ok+rejected+error)` |

```bash
# p95 de cada query en las últimas 6 horas
aws cloudwatch get-metric-statistics --namespace Bicom/ReportStockMovements \
  --metric-name QueryDurationMs --dimensions Name=Query,Value="Q4 movements_stream" \
  --start-time $(date -u -v-6H +%FT%TZ) --end-time $(date -u +%FT%TZ) \
  --period 3600 --extended-statistics p95 --region us-east-2
```

Logs Insights (las 20 consultas más lentas con tenant y SQL):

```sql
fields @timestamp, Query, db_name, QueryDurationMs, QueryRows, sql
| filter ispresent(QueryDurationMs)
| sort QueryDurationMs desc
| limit 20
```

Reportes que se rechazaron o fallaron, con motivo:

```sql
fields @timestamp, company_id, db_name, rejected, retry, duration_ms
| filter msg = "mensaje procesado" and (rejected != "" or retry = 1)
| sort @timestamp desc
```

---

## 3. "Está lento": ¿la base o la query?

Orden de descarte, del más barato al más caro:

1. **¿Es un retry?** Mismo `message_id` en dos invocaciones = SQS reintentando un timeout
   anterior. Mirar la primera, no la última.
2. **¿Es cold start?** `init=` grande y `pool MySQL creado`. No es rendimiento del reporte.
3. **¿Qué query se lleva el tiempo?** `QueryDurationMs` por `Query`. Casi siempre es una sola.
4. **¿La base estaba cargada?** Aurora Serverless compartida con la webapp:
   ```bash
   for M in ServerlessDatabaseCapacity CPUUtilization ReadIOPS; do
     aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name $M \
       --dimensions Name=DBInstanceIdentifier,Value=prod-principal-v2 \
       --start-time $(date -u -v-2H +%FT%TZ) --end-time $(date -u +%FT%TZ) \
       --period 300 --statistics Average Maximum --region us-east-2 \
       --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Average,Maximum]' --output text
   done
   ```
   Picos de `ReadIOPS` coincidiendo con la ejecución = la query toca muchas páginas y el
   buffer pool estaba frío. **Una query que mide 2 s caliente puede tardar 60 s fría**; el
   número que importa es cuántas páginas toca (`loops × rows` en `EXPLAIN ANALYZE`), no el
   tiempo en tu sesión.
5. **Reproducir en la base con `EXPLAIN ANALYZE`** (nunca `time` desde el cliente) usando los
   `args` que deja el log. Estrategias y trampas: skill `mysql-query-optimization-skills` /
   `docs/optimizacion-queries-mysql.md`.

Conectarse a un nodo con las credenciales que ya tiene la Lambda, sin pegarlas en la shell:

```bash
aws lambda get-function-configuration --function-name <fn> --region us-east-2 \
  --query 'Environment.Variables' --output json | python3 -c "
import sys,json; d=json.load(sys.stdin); n='1'
open('/tmp/my.cnf','w').write('[client]\nhost=%s\nport=%s\nuser=%s\npassword=%s\n' % (
  d['BC_HOST_MYSQL_'+n], d.get('BC_PORT_MYSQL_'+n,'3306'), d['BC_USER_MYSQL_'+n], d['BC_PASSWORD_MYSQL_'+n]))"
chmod 600 /tmp/my.cnf
mysql --defaults-file=/tmp/my.cnf bicom_rbahamonde -e "EXPLAIN ANALYZE ..."
rm /tmp/my.cnf
```

---

## 4. "Quedó procesando": no es rendimiento

Si el front muestra "procesando" y el script no muestra **ninguna** invocación nueva:

```bash
# ¿Llegó algo a la cola?
aws sqs get-queue-attributes --queue-url <url> --region us-east-2 \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
aws cloudwatch get-metric-statistics --namespace AWS/SQS --metric-name NumberOfMessagesSent \
  --dimensions Name=QueueName,Value=<cola> --start-time $(date -u -v-1H +%FT%TZ) \
  --end-time $(date -u +%FT%TZ) --period 300 --statistics Sum --region us-east-2
```

- 0 mensajes enviados → **el front no publicó** o publicó a otra cola.
- Mensajes enviados pero sin invocación → event source mapping deshabilitado, o concurrencia
  reservada en 0.
- Invocación con `no existe la llave del reporte en Redis` → el front escribe en **otra llave**
  (nos pasó al renombrar `report_stock` → `report_stock_movements_go`: la Lambda leía la nueva
  y el front escribía la vieja).

Ver el estado en Redis (TLS, desde una máquina con acceso a la VPC):

```bash
redis-cli --tls --insecure -h <host> -a <pass> GET 'Report[146][report_stock_movements_go]'
```

---

## 5. Checklist post-despliegue

- [ ] `scripts/lambda-perf.sh <fn> 30` muestra la invocación nueva con `Outcome=ok`.
- [ ] `init=` presente una vez (cold start esperado) y luego ausente.
- [ ] Ningún `!!! TIMEOUT`, ningún `Outcome=error`.
- [ ] `QueryDurationMs` de la query principal comparable al despliegue anterior (misma hora,
      mismo tenant si se puede; recordar caché frío vs caliente).
- [ ] `mem=` < 70 % de la memoria configurada.
- [ ] URL generada apunta al bucket correcto y en la región de la Lambda.
- [ ] DLQ vacía: `aws sqs get-queue-attributes --queue-url <dlq> --attribute-names ApproximateNumberOfMessages`.
- [ ] Rollback listo si hace falta: `update-function-code --image-uri :<sha-anterior>`.

---

## Apéndice: valores de referencia (2026-08-25)

| Lambda | Caso | Query principal | Total | Memoria |
|---|---|---|---|---|
| stock-product-list | 5.352 productos, XLSX, frío | 335 ms (first byte 64) | 812 ms | 66 MB |
| stock-product-list | 535 productos, PDF, caliente | 42 ms | 165 ms | 66 MB |
| stock-product-list | > 1.000 en PDF → rechazado en la fila 1.001 | 111 ms | 161 ms | 66 MB |
| stock-movements | 17.698 filas, XLSX, base fría, **antes** del fix Q3 | Q3 67,8 s | 70,6 s | 116 MB |
| stock-movements | mismo caso, esperado **después** (ventana 12 m + rescate) | Q3 ~1–5 s | < 10 s | ~120 MB |
