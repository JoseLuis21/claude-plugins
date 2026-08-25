# Estrategias de optimización de queries MySQL

Recopilación de lo que funcionó (y lo que no) optimizando el reporte de
movimientos de stock sobre Aurora MySQL 8.0. Sirve como guía para otros repos:
el orden de los capítulos es el orden en que conviene atacar un problema.

Contexto de las mediciones: Aurora MySQL 8.0.42, dos bases del mismo esquema con
escalas muy distintas — una de 80k filas de detalle y otra de 6,5M — lo que
resultó clave para descubrir que un plan bueno en una es catastrófico en la otra.

---

## 0. Primero: medir bien, o no medir

**Esta es la lección más cara del ejercicio.** Dos optimizaciones "confirmadas"
resultaron falsas por medir mal, y una de ellas casi se sube a producción
empeorando las cosas un 40%.

### Los dos errores que cometimos

**Medir desde el cliente.** Un `time mysql -e "..."` desde una máquina remota
incluye el round-trip de red y la transferencia de resultados. En nuestro caso
eran ~1,3 s de overhead — más que la query completa. Una query de 195 ms
aparecía como 1.550 ms.

**Comparar contra un caché frío.** La primera corrida de una query lee de disco;
la segunda ya tiene el buffer pool caliente. Si medís la versión vieja primero y
la nueva después, la nueva gana siempre. Así "demostramos" que una query pasaba
de 51 s a 4,5 s cuando en realidad era **40% más lenta**.

### Cómo medir de verdad

```sql
EXPLAIN ANALYZE <query>
```

Mide tiempo de servidor y no transfiere el resultado. Y **alternar las versiones
en varias rondas**, para que ambas vean el mismo estado de caché:

```
ronda 1  VIEJA 2263 ms  |  NUEVA 3198 ms
ronda 2  VIEJA 2243 ms  |  NUEVA 3132 ms
ronda 3  VIEJA 2230 ms  |  NUEVA 3134 ms
```

Tres rondas consistentes es evidencia. Una corrida de cada una no es nada.

> Antes de creerle a una mejora espectacular (10x, 100x), preguntate qué más
> cambió entre las dos mediciones además del código.

### El tercer error: creer que "2 segundos" es el número de producción

La misma Q3 que medía 2,3 s con `EXPLAIN ANALYZE` tardó **40 y 68 s** en dos
ejecuciones reales de la Lambda, con el mismo plan y la misma instancia. La
diferencia era el buffer pool: en mi sesión las páginas ya estaban en memoria;
en producción la base (Aurora Serverless compartida con toda la app, ACU
oscilando entre 15 y 35) las había desalojado. La query hacía ~350.000 lookups
aleatorios (`loops=34.639` × `rows=7,31` en `document_lines` más 95.000 en
`documents`): con todo en caché son 2 s; a ~0,15 ms por página fría son 50 s.

Por eso el número que importa no es el tiempo caliente sino **cuántas páginas
toca la query**. `EXPLAIN ANALYZE` lo dice en `loops × rows` de cada nodo; el
tiempo caliente solo mide CPU. Una query que toca 7x menos páginas es 7x más
rápida cuando importa (fría), aunque caliente mida "casi lo mismo".

> Si la Lambda tarda 30x más que tu medición, no es la Lambda: es que vos
> mediste con caché caliente. Reducí páginas tocadas, no milisegundos calientes.

### Verificar equivalencia, no solo velocidad

Una query más rápida que devuelve otra cosa no es una optimización, es un bug.
Comparar los conteos no alcanza: hay que comparar los **multiconjuntos**,
contando ocurrencias de cada fila en cada lado para no tropezar con duplicados
legítimos.

```sql
SELECT COUNT(*) AS grupos_con_conteo_distinto FROM (
  SELECT col1, col2, ...,
         SUM(src = 1) AS n_vieja,
         SUM(src = 2) AS n_nueva
  FROM ( SELECT 1 AS src, a.* FROM (<VIEJA>) a
         UNION ALL
         SELECT 2 AS src, b.* FROM (<NUEVA>) b ) u
  GROUP BY col1, col2, ...
  HAVING n_vieja <> n_nueva
) d;
```

Resultado 0 = idénticas. Ambas subconsultas corren en la misma sentencia, así
que ven el mismo snapshot aunque los datos estén cambiando.

---

## 1. Leer el plan real, no el estimado

`EXPLAIN FORMAT=TREE` da el plan y los costos estimados. `EXPLAIN ANALYZE` agrega
lo que **realmente pasó**. La diferencia entre ambos suele ser el diagnóstico.

Lo que hay que buscar en cada nodo:

```
-> Filter: (l.entity_id = last.entity_id)  (cost=0.698 rows=0.05)
   (actual time=0.385..0.721 rows=0.369 loops=17046)
                                   ^^^^^^^^^^^^^^^^
```

- **`loops` × `rows`** = filas realmente leídas en ese nodo. Acá: 17.046 × 227 =
  ~3,9 millones.
- **`rows` del Filter muy por debajo del `rows` de su hijo** = estás leyendo para
  tirar. Acá sobrevivía el 0,16%.
- **`actual time` acumulado**: el salto entre un nodo y su padre te dice dónde se
  fue el tiempo. `109..596` en el hijo y `110..12892` en el padre = 12,3 s en ese
  join.
- **`rows` estimado vs real muy distintos** = estadísticas malas, y el
  optimizador va a elegir mal.

---

## 2. El filtro selectivo tiene que aplicarse primero

El error más común y más caro. Si el filtro que descarta el 99% se evalúa
**después** de leer millones de filas, no importa cuán barato sea.

### Síntoma A: falta una columna en el índice

```
-> Filter: (l.entity_id = last.entity_id)  (rows=0.369 loops=17046)
    -> Index lookup on l using document_lines_document_id_foreign
       (document_id = d.id)  (rows=227 loops=17046)
```

El índice tenía sólo `document_id`. MySQL traía **todos** los detalles del
movimiento y filtraba `entity_id` en memoria. Con movimientos de hasta 2.628
líneas, eran 3,9M de filas leídas para quedarse con 6.296.

**Arreglo posible:** índice compuesto `(document_id, entity_id)`. En InnoDB los
índices secundarios incluyen la PK, así que ese índice también cubre `MAX(id)`.

**Arreglo que elegimos:** reescribir la query para no necesitar ese join
(ver §3). Cero DDL, y en un entorno multi-tenant con mil bases eso importa.

### Síntoma B: el optimizador entra por la tabla equivocada

Misma query, distinto rango de fechas, plan completamente distinto:

```
-- 7 días: bien
-> Index range scan on d using documents_doc_date  (9.155 filas)
     -> lookup l por document_id  -> lookup p por PRIMARY

-- 30 días: catastrófico
-> Index lookup on e using idx_entities_active  (2.445 productos)
     -> lookup l por entity_id  (~360 c/u = ~880.000 filas)
         -> lookup d por PRIMARY  <- recién acá filtra la fecha
```

880.000 lookups aleatorios contra una tabla de 12 GB. La primera versión tardaba
1,6 s; la segunda no terminaba en 4 minutos 40.

**Que una query ande bien en pruebas no dice nada si el volumen de entrada
cambia el plan.** Probá siempre con el rango más grande que el usuario pueda
pedir.

---

## 3. `ROW_NUMBER()` en vez de auto-join por máximo

Patrón clásico "la última fila de cada grupo". La forma vieja (obligatoria en
MySQL 5.7) recorre la tabla dos veces:

```sql
-- ANTES: 12.936 ms, ~3,9M filas leídas
SELECT l.entity_id, l.unit_price
FROM ( SELECT l.entity_id, MAX(l.id) AS detail_id
       FROM documents d
       INNER JOIN document_lines l ON l.document_id = d.id
       INNER JOIN ( SELECT l.entity_id, MAX(d.doc_date) AS last_date
                    FROM documents d
                    INNER JOIN document_lines l ON l.document_id = d.id
                    WHERE <filtros> AND d.doc_date < ?
                    GROUP BY l.entity_id ) last
              ON last.entity_id = l.entity_id
             AND d.doc_date = last.last_date
       WHERE <filtros>
       GROUP BY l.entity_id ) pick
INNER JOIN document_lines l ON l.id = pick.detail_id
```

```sql
-- DESPUÉS: 123 ms, 14.781 filas leídas — resultado idéntico
SELECT t.entity_id, t.unit_price
FROM ( SELECT l.entity_id, l.unit_price,
              ROW_NUMBER() OVER (
                PARTITION BY l.entity_id
                ORDER BY d.doc_date DESC, l.id DESC ) AS rn
       FROM documents d
       INNER JOIN document_lines l ON l.document_id = d.id
       WHERE <filtros> AND d.doc_date < ? ) t
WHERE t.rn = 1
```

**105x, una sola pasada.** El `ORDER BY` del `OVER` es la regla de desempate: es
semántica, no estilo. Conviene fijarla en un test — si alguien la reordena, el
reporte valoriza con otra compra y nada más falla.

> Antes de aplicarlo, verificá la versión de **todos** los nodos. En el proyecto de referencia el
> comentario que prohibía funciones de ventana citaba nodos en MySQL 5.7 que
> hacía rato corrían 8.0. Un comentario desactualizado costó meses de query lenta.

---

## 4. Fijar el orden de join con `STRAIGHT_JOIN` — condicionado

Cuando el optimizador elige mal por estadísticas pobres, se le puede imponer el
orden. **Pero no de forma incondicional**: el orden correcto depende de qué
filtro sea selectivo en cada caso.

```go
// Sin filtro de entidad lo único selectivo es el rango de fechas: hay que
// entrar por documents y acotar ANTES de tocar el detalle.
// Con filtro de entidad es al revés: entities es lo selectivo y conviene
// que mande, así que ahí no se fuerza nada.
if f.HasEntityScope() {
    builder.WriteString(`FROM document_lines l
INNER JOIN documents d ON l.document_id = d.id AND d.status >= 1`)
} else {
    builder.WriteString(`FROM documents d
STRAIGHT_JOIN document_lines l ON l.document_id = d.id AND d.status >= 1`)
}
```

Resultado: de **no terminar (>4m40s) a 2,4 s**, con el plan bueno conservado en el
caso con filtro.

Notas prácticas:

- `STRAIGHT_JOIN` fuerza **orden de tablas**, no elección de índice. Para eso es
  `FORCE INDEX`.
- Sólo aplica a `INNER JOIN`; los `LEFT JOIN` quedan como estén.
- Es una decisión de rendimiento que parece de estilo. Sin un test que la fije,
  el próximo refactor la borra sin que nadie se entere.

---

## 5. Medir la selectividad real antes de proponer un índice

No adivines cuál filtro poda. Contalos, todos de una:

```sql
SELECT COUNT(*)                                        AS total,
       SUM(doc_date < '2026-07-27')                AS pasa_fecha,
       SUM(status >= 1)                           AS pasa_consolidado,
       SUM(movement_subtype NOT IN (3,4))                    AS pasa_concepto,
       SUM(doc_date < '2026-07-27'
           AND status >= 1
           AND movement_subtype NOT IN (3,4))                AS pasa_todo
FROM documents WHERE movement_code = '<entrada>';
```

```
total   pasa_fecha  pasa_consolidado  pasa_concepto  pasa_todo
94867   93443       93663             35476          34545
```

Traducción: fecha y consolidado **no podan nada**; el único filtro selectivo es
`movement_subtype NOT IN (3,4)`. Un índice `(movement_code, doc_date)` —el candidato
"obvio"— habría servido de poco.

Ojo con dos trampas de las estadísticas:

- `information_schema.tables.table_rows` es **estimado** (nos dio 4.802 productos
  donde había más de 5.250). Para decisiones, `COUNT(*)`.
- El `rows` del `EXPLAIN` también es estimado, y puede errar por múltiplos:
  estimaba 1,86 detalles por movimiento donde el real era 7,3.

También conviene mirar la **distribución**, no sólo el promedio:

```sql
SELECT ROUND(AVG(n),1) promedio, MAX(n) maximo,
       SUM(n > 100) con_mas_de_100
FROM (SELECT document_id, COUNT(*) n FROM document_lines GROUP BY document_id) t;
```

Promedio 2,6 y máximo 2.628. **El promedio escondía el problema**: unos pocos
registros gigantes visitados miles de veces eran todo el costo.

---

## 6. Ventana acotada + rescate puntual

Para "último valor de X por producto antes de una fecha" la query natural mira
**toda la historia** (§3): el `ROW_NUMBER()` es lineal, pero lineal sobre 250.000
filas dispersas en disco. En cambio, casi todos los productos que aparecen en
el reporte tuvieron una compra reciente. Medido en un tenant real:

| | |
|---|---|
| Filas GE en toda la historia | 253.260 |
| Filas GE en los últimos 12 meses | 34.343 (**7x menos**) |
| Productos del reporte (1.341) sin compra en 12 meses | **43** |
| … y que sí tienen alguna compra más antigua | 12 |

Entonces se parte en dos:

1. **La ventana acotada** hace el grueso: la misma query con
   `AND d.doc_date >= date_ini − 12 meses`. Mismo plan, 7x menos páginas.
2. **El rescate puntual** para los pocos que faltan, uno a uno, **entrando por
   un índice que empiece por `entity_id`**:

```sql
SELECT l.unit_price
FROM document_lines l
INNER JOIN documents d ON d.id = l.document_id
WHERE l.entity_id = ?
  AND l.movement_code = '<entrada>'      -- columna del índice (entity_id, movement_code, ...)
  AND d.movement_code = '<entrada>' AND d.status >= 1 AND d.movement_subtype NOT IN (3, 4)
  AND d.doc_date < ?
ORDER BY d.doc_date DESC, l.id DESC
LIMIT 1
```

El rescate solo toca las filas GE de ese producto: 13 ms para 43 productos en
lote; 27 ms el peor caso individual (un producto con 714 compras). Se dispara
desde el código al abrir cada producto sin precio, y se memoriza el resultado
(incluso "no tiene compra") para no repetirlo.

Detalles que importan:

- **La equivalencia se verifica igual que en §0**: `full` contra `ventana ∪
  rescate` por multiconjunto. Dio 0 diferencias en dos rangos (5.285 y 4.969
  productos).
- `l.movement_code` es una copia de `d.movement_code` (0 diferencias en 82.000
  filas). Filtrar por la copia es lo que habilita el índice de `l`; se dejan
  **ambos** filtros para no cambiar la población si la copia algún día
  divergiera.
- El tamaño de la ventana es configuración (`COST_LOOKBACK_MONTHS`, 0 = historia
  completa): si un tenant tiene muchos rescates, se agranda; nunca cambia el
  resultado, solo cuánto va en lote y cuánto uno a uno.
- Con `ORDER BY doc_date` no se puede cortar temprano recorriendo el índice
  de `l` (la fecha está en `documents`), por eso el rescate lee todas las GE
  del producto. Es barato porque son pocas por producto, no porque el índice
  la ordene.

> Cuando la query correcta es "toda la historia", partila en "lo reciente en
> lote" + "lo antiguo bajo demanda por índice". Es la misma idea que el
> snapshot de cierre mensual (§7, tabla agregada), pero sin necesitar una tabla
> nueva ni otro proceso que la mantenga.

---

## 7. Lo que NO funcionó

Igual de útil que lo que sí.

### Subconsulta correlacionada por fila

Reemplazar la ventana por un `LIMIT 1` correlacionado parecía elegante: en vez de
ordenar 252.705 filas, un lookup por producto.

```sql
SELECT e.id,
  (SELECT l.unit_price FROM documents d
     INNER JOIN document_lines l ON l.document_id = d.id
    WHERE l.entity_id = e.id AND <filtros>
    ORDER BY d.doc_date DESC, l.id DESC LIMIT 1)
FROM entities e
```

**No terminó en 4m40s.** Con miles de productos, la correlacionada se ejecuta una
vez por fila y cada una hace su propio sort. Peor que ordenar todo junto.

### Filtrar por "registros vigentes" para reducir el conjunto

Descubrimos que la query valorizaba 5.250 productos cuando el reporte sólo
mostraba 2.429 activos. Recortar a los vigentes parecía gratis, y la primera
medición dio 51.568 ms → 4.532 ms.

Era falso (§0). Server-side y alternando: **2.245 ms → 3.155 ms, 40% más lenta**.
El motivo es aritmética simple: agregaba 252.705 lookups a `entities` para
ahorrar 67.000 filas de `Sort`. El sort era barato; los lookups no.

**Menos filas en el resultado no implica menos trabajo.** El costo está en lo que
se lee para llegar ahí.

### Reutilizar una tabla agregada que "ya tiene el dato"

Había una tabla de cierres mensuales con columnas de costo, y la idea de usarla
en vez de calcular el último precio era tentadora. Los datos dijeron que no:

| | |
|---|---|
| Productos comparables | 5.124 |
| Coinciden (±0,01) | 4.486 (87,5%) |
| **Difieren** | **637 (12,4%)** |
| Sin cobertura en la tabla | **380** |

Eran métricas distintas: **promedio ponderado** contra **último precio de
compra**. Coincidían en los productos comprados una sola vez, que son la mayoría
— por eso parecía equivalente a simple vista.

> Que dos columnas se llamen "costo" no las hace la misma métrica. Antes de
> sustituir una fuente por otra, comparalas fila por fila y mirá la cobertura.

---

## 8. Checklist

**Diagnóstico**
1. `EXPLAIN ANALYZE`, no `EXPLAIN` a secas.
2. Buscar `loops × rows` alto con `rows` de salida bajo → leés para tirar.
3. Comparar estimado vs real → si difieren mucho, el optimizador está ciego.
4. Contar la selectividad real de cada filtro con `SUM(condición)`.
5. Mirar la distribución (`MAX`, percentiles), no sólo el promedio.
6. Probar con el rango de entrada **más grande** que el usuario pueda pedir.

**Arreglo, en orden de preferencia**
1. Reescribir la query (`ROW_NUMBER()`, eliminar auto-joins). Cero DDL.
2. Fijar el orden de join con `STRAIGHT_JOIN`, condicionado al caso.
3. Índice compuesto, con las columnas de igualdad primero y la de rango al final.
4. Tabla materializada — sólo si la semántica es exactamente la misma.

**Antes de dar por buena una optimización**
1. ¿Medí server-side con `EXPLAIN ANALYZE`?
2. ¿Alterné las dos versiones en 3+ rondas?
3. ¿Comparé los resultados como multiconjuntos, no sólo los conteos?
4. ¿Probé el caso con filtros **y** el caso sin filtros?
5. ¿Dejé un test que fije la decisión de rendimiento?
6. ¿La mejora sigue siendo real en la base chica **y** en la grande?

---

## Apéndice: resultados medidos

| Query | Antes | Después | Método |
|---|---|---|---|
| Q3 `unitary_values` | 12.936 ms | **123 ms** | `ROW_NUMBER()` (§3) |
| Q4 `movements_stream` (30 d, 6,5M filas) | no termina (>4m40s) | **2.428 ms** | `STRAIGHT_JOIN` condicional (§4) |
| Q3 "acotar a vigentes" | 2.245 ms | 3.155 ms | **revertido** (§7) |
| Q3 `unitary_values` en Lambda (caché frío) | 40.244 – 67.782 ms | ventana 12 m: 7x menos páginas + rescate 13 ms | ventana + rescate (§6) |

Ambas mejoras verificadas fila por fila contra la versión original.
