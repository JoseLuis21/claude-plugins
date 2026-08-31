---
name: mysql-query-optimization-skills
description: Diagnostica y optimiza consultas MySQL/Aurora lentas con evidencia (EXPLAIN ANALYZE, loops × rows, páginas tocadas) en vez de con intuición, y aplica las reescrituras que sí pagan — ROW_NUMBER en vez de auto-join por máximo, STRAIGHT_JOIN condicionado al filtro, filtro selectivo primero, ventana acotada más rescate puntual, verificación de equivalencia por multiconjunto. Incluye la estrategia de saldo acumulado por período más delta, para cuando la query correcta es recorrer todo el histórico y el costo crece solo. Úsala siempre que una query o un reporte esté lento, no termine, o demore en la Lambda pero no en tu máquina; cuando haya que leer un EXPLAIN, proponer un índice, reescribir un JOIN, una subconsulta o un GROUP BY, obtener el último valor por grupo; o cuando el trabajo toque saldos, stock, existencias, inventario, costo promedio, cierres por período, o que un cálculo deje de recorrer todo el histórico.
---

# Optimización de queries MySQL + saldo acumulado por período

Dos cosas en una skill porque en la práctica van juntas: primero **medir y arreglar la query**
(§A) y, cuando la query correcta es "toda la historia", **cambiar la forma de leer** con una
ventana acotada (§A.6) o con la estrategia de saldo acumulado (§B).

El orden importa. §B es un cambio de modelo de datos, con job de cierre, backfill e interruptor:
no se empieza por ahí. Se empieza midiendo.

Referencias (leer la que aplique, no todas):

| Archivo | Cuándo |
|---|---|
| [`references/estrategias-completas.md`](references/estrategias-completas.md) | La guía completa de §A, con planes reales, tablas de medición y lo que NO funcionó. |
| [`references/saldo-acumulado-lectura.md`](references/saldo-acumulado-lectura.md) | La estrategia de §B: diseño, reglas invariantes y cómo se lee. |
| [`references/saldo-acumulado-escritura.md`](references/saldo-acumulado-escritura.md) | Solo si vas a GENERAR los saldos: fecha de consolidación, backfill, job de cierre. |
| [`references/saldo-acumulado-trampas.md`](references/saldo-acumulado-trampas.md) | Las 10 trampas de §B y las consultas de sanidad antes de encender. |

---

## A. Optimizar la query

### A.0 Medir bien o no medir (regla que manda sobre todas)

1. **`EXPLAIN ANALYZE`, nunca `time` desde el cliente.** El round-trip de red puede ser más que la
   query (1,3 s de overhead sobre una query de 195 ms).
2. **Alternar vieja/nueva en 3 rondas** para que ambas vean el mismo caché. Comparar "vieja fría vs
   nueva caliente" inventó una mejora de 51 s → 4,5 s que en realidad era **40 % peor**.
3. **El número que importa es cuántas páginas toca, no el tiempo caliente.** Una query de 2,3 s en
   sesión tardó 40–68 s en una Lambda: mismo plan, misma instancia, buffer pool frío (Aurora
   Serverless compartida). ~350k lookups aleatorios = 2 s en caché, 50 s en disco. Léelo en
   `loops × rows` de cada nodo del plan.
4. **Verificar equivalencia por multiconjunto** antes de declarar victoria:
   ```sql
   SELECT COUNT(*) FROM (
     SELECT k1, k2, SUM(src=1) a, SUM(src=2) b FROM (
       SELECT k1, k2, 1 src FROM (<vieja>) x UNION ALL SELECT k1, k2, 2 FROM (<nueva>) y
     ) u GROUP BY k1, k2 HAVING a<>b) d;      -- debe dar 0
   ```
   Agrupar sin contar por lado da falsos positivos con filas duplicadas legítimas.

> Antes de creerle a un 10x/100x, pregunta qué más cambió entre las dos mediciones.

### A.1 Leer el plan real

`EXPLAIN` a secas estima; `EXPLAIN ANALYZE` (MySQL 8) muestra `actual time`, `rows` y `loops`.
Buscar: `loops` alto × `rows` alto con pocas filas de salida = lees para tirar. `Materialize`
con cientos de miles de filas = el filtro selectivo llegó tarde.

### A.2 El filtro selectivo tiene que aplicarse primero

- **Falta la columna en el índice:** el rango de fechas se evalúa después de un lookup por otra
  clave → el índice tiene que incluir la columna del rango, o hay que entrar por otra tabla.
- **El optimizador entra por la tabla equivocada:** si el filtro selectivo vive en la tabla B
  (p. ej. la fecha, en el cabezal) pero un filtro de entidad lo lleva a A (las líneas), trae todo
  el histórico de esas entidades y recién ahí evalúa la fecha.
- **La tabla de catálogo como conductora falsa.** El caso más repetido y el más engañoso, porque
  el filtro selectivo **está en el `WHERE` y tiene índice**: el optimizador igual entra por una
  tabla de dimensión chica (formas de pago, sucursales, tipos de documento) y por cada una de sus
  pocas filas hace un lookup por FK sobre la tabla grande, dejando el `BETWEEN` de fecha como
  filtro posterior. Con 11 formas de pago o 13 sucursales, el `loops` del plan multiplica: se leen
  millones de filas para devolver miles.

  **Los dos síntomas que lo delatan sin tocar la base:**
  1. En los logs, el tiempo hasta la primera fila (`first_byte`) es **casi toda** la duración de
     la consulta, y el total **no sigue a las filas devueltas** — 509 filas tardando más que 663.
  2. En un `EXPLAIN` a secas —gratis, no ejecuta— el índice bueno aparece en `possible_keys` y
     **no** en `key`.

### A.3 `ROW_NUMBER()` para "el último valor por grupo"

Auto-join por `MAX(fecha)` + segundo join por desempate = 12.936 ms. Ventana = 123 ms (105x):

```sql
SELECT entity_id, unit_price FROM (
  SELECT l.entity_id, l.unit_price,
         ROW_NUMBER() OVER (PARTITION BY l.entity_id ORDER BY d.doc_date DESC, l.id DESC) rn
  FROM documents d JOIN document_lines l ON l.document_id = d.id
  WHERE <población> AND d.doc_date < ?
) t WHERE rn = 1;
```

El desempate (`l.id DESC`) es semántica de negocio: déjalo explícito y con test. Requiere
MySQL ≥ 8.0: verifica TODOS los nodos antes (`SELECT @@version`), no lo asumas.

### A.4 `STRAIGHT_JOIN` — condicionado

Fuerza el orden de tablas (no el índice) y solo con INNER JOIN. Úsalo cuando el optimizador entra
por la tabla equivocada, **pero condicionado al filtro**: sin filtro de entidad,
`FROM documents STRAIGHT_JOIN document_lines` (la fecha poda); con filtro de entidad, el orden
natural `FROM document_lines JOIN documents` es mejor. Medido: de "no termina en 4m40s" a 2.428 ms.

**`FORCE INDEX` casi nunca; hint casi siempre.** `/*+ INDEX(tabla idx) */` dirige el plan igual,
pero si el índice no existe en esa base deja solo un warning y el optimizador sigue. `FORCE INDEX`
tumba la consulta con el error **1176**. En un parque de bases por tenant, donde el esquema no
está garantizado idéntico en todas, esa diferencia es entre un informe lento y un informe caído.
Usa `FORCE INDEX` **solo cuando el 1176 es lo que buscas**: en una consulta auxiliar que detecta
si el índice existe para que el código decida.

**Crear el índice no alcanza: hay que decirle que lo use.** Un índice desplegado en casi todas las
bases no movió el plan — mismos conteos de filas que antes de crearlo, porque el optimizador
estimaba costos casi empatados (2054 vs 2063) y se quedaba con el equivocado. **Índice y hint son
una sola tarea, no dos**: medir después de crear el índice y antes de poner el hint da "no sirvió
de nada" y hace descartar un índice que sí servía.

Tres casos medidos con la misma forma y el mismo remedio:

| Conductora falsa | Sin hint | Con hint |
|---|---|---|
| Catálogo de formas de pago (11 filas) | 3.832.301 filas leídas | **134.260** (`loops=1`) |
| Índice por tipo de documento | 2.412 filas | **138** |
| Sucursales (13) × entidades (58) | ~34 M, **no termina** | **136.540**, 1,5 s |

Cuando el índice es **compuesto** (`tipo, a, b, fecha, id`), el hint solo no basta: MySQL lo usa
para el rango de fecha únicamente si la consulta trae **igualdad** en las columnas del medio. Hay
que agregarlas como predicados redundantes — y **no fijar sus valores a mano**: leerlos del propio
índice con un `SELECT DISTINCT ... FORCE INDEX`, para que la población sea idéntica por
construcción en cada base. Un valor inventado que no se cumpla borra filas en silencio.

### A.5 Medir la selectividad real antes de proponer un índice

`SELECT COUNT(*) ... WHERE <filtro>` sobre el universo vs. filtrado. Un filtro que "parece"
selectivo (entidades vigentes) dejaba el 95 % de las filas: el índice no pagaba.

### A.6 Ventana acotada + rescate puntual

Cuando la query correcta es "toda la historia" (el último precio de compra antes de una fecha),
pártela en dos:

1. **Lote reciente:** la misma query con `AND fecha >= date_ini − N meses` (7x menos páginas).
2. **Rescate por índice** para los pocos que faltan, uno a uno al abrir la entidad, entrando por
   un índice que empiece en `entity_id` (`WHERE l.entity_id = ? AND <población>
   ORDER BY d.doc_date DESC, l.id DESC LIMIT 1`), memorizando incluso el "no tiene".

Medido: 253k filas → 34k; 43 rescates de 1.341 entidades, 13 ms; 0 diferencias por multiconjunto.
`N` es configuración, nunca cambia el resultado. Si una columna de la línea espeja la del cabezal,
filtra por **ambas**: la copia habilita el índice, la original conserva la población.

### A.7 Lo que NO funcionó (no repetir)

- Subconsulta correlacionada por fila → `loops` = filas.
- "Acotar a registros vigentes" → 40 % más lento (el join extra costaba más que lo que podaba).
- Reutilizar una tabla agregada "que ya tiene el dato" → eran métricas distintas (promedio
  ponderado vs último precio): 12,4 % de diferencias, 380 entidades sin cobertura. **Compara fila
  por fila antes de sustituir una fuente.**
- **Acotar una derivada con los filtros del informe "para que agregue menos".** Sonaba obvio: una
  derivada agregaba la tabla de pagos entera, así que se le metió un `INNER JOIN` al cabezal con
  los filtros del informe. Resultado: **6x peor** — la derivada pasó de 55 s a 342 s y el total de
  290 s a 385 s. El filtro solo eliminaba el **8 %** de los grupos y a cambio obligaba a recorrer
  3,77 M de filas del cabezal dentro de la derivada (283 s). Es §A.5 otra vez: **mide cuánto poda
  ANTES de escribir el cambio**; un `COUNT(*)` del universo contra el filtrado lo dice en dos
  segundos.
- **Suponer que un filtro de baja cardinalidad acota.** En esa misma consulta, el filtro por tipo
  de documento estimaba 1.857.166 filas y sumarle tres condiciones más la dejaba en **1.857.163**:
  podaban 3 filas de 1,86 millones, porque casi todo registro cumple las tres. Ningún índice
  compuesto sobre esas columnas paga. **Compruébalo con `EXPLAIN` a secas, que es gratis**, antes
  de proponer el índice.

### A.8 Checklist

- [ ] `EXPLAIN ANALYZE` en servidor; 3 rondas alternadas; misma instancia.
- [ ] `loops × rows` ubicado; sé qué nodo lee de más y por qué.
- [ ] El cambio propuesto reduce **páginas tocadas**, no solo ms calientes.
- [ ] Equivalencia por multiconjunto = 0 diferencias en ≥ 2 rangos.
- [ ] Semántica (desempates, poblaciones) fijada en un test unitario del SQL.
- [ ] Hints (`STRAIGHT_JOIN`, `FORCE INDEX`) condicionados al filtro, nunca globales.
- [ ] Si el plan entra por una tabla de catálogo (§A.2), el índice **y** el hint van juntos:
      crear el índice sin el hint no mueve el plan.
- [ ] El hint es `/*+ INDEX(...) */`, no `FORCE INDEX`, salvo que el error 1176 sea lo buscado.
- [ ] Versión de MySQL verificada en todos los nodos si usas funciones nuevas.
- [ ] Log con duración por query en producción (métrica) para ver el caso frío real.

---

## B. Estrategia: saldo acumulado por período + delta

**No es una tabla que ya exista: es una que vas a diseñar.** El contrato completo está en
[`references/saldo-acumulado-lectura.md`](references/saldo-acumulado-lectura.md); esto es el
resumen para decidir si vale la pena.

Reemplaza `SUM(entradas) − SUM(salidas)` sobre todo el histórico por:

```
saldo_hoy = saldo_acumulado(último período cerrado) + Σ(movimientos del período abierto)
```

Le pone **techo** al costo: deja de depender de cuántos años de historia tenga el tenant.

**Aplica** si la magnitud es aditiva, el pasado no cambia en la operación normal, y lo que importa
es el valor de hoy. **No aplica** si necesitas el saldo a una fecha arbitraria — eso se queda con
el cálculo completo, o con §A.6.

Las cinco reglas invariantes (romper cualquiera da números incorrectos, no solo lentos):

- **R1** Los acumuladores son **corridos**: la fila de febrero es el total hasta el 28-feb.
- **R2** El movimiento pertenece al período en que **se consolidó**, no al de su documento. Sin
  fallback: si esa fecha falta, la línea desaparece de todos los períodos.
- **R3** Nunca guardes un promedio: numerador y denominador aparte, se divide al leer.
- **R4** El período en curso **nunca** está en la tabla; se calcula en vivo.
- **R5** La tabla es **caché**: se borra y se regenera. Todo detrás de un interruptor.

Lo que más caro sale, en orden:

1. **Piso del delta por calendario.** `WHERE fecha >= inicio_del_mes` parece obvio y hace
   desaparecer un período entero si el cierre se atrasó. Derívalo de `MAX(period)`.
2. **Mezclar poblaciones.** Si sacas dos magnitudes de la misma tabla (saldo y valoración), casi
   seguro se calculan sobre conjuntos de filas distintos: una se decide en la línea y otra en el
   cabezal. Mezclarlas da números plausibles y falsos.
3. **Filtrar por la fecha del documento** en vez de la de consolidación: un documento viejo
   consolidado en el período abierto se cuenta **dos veces**.

Y una puerta antes de encender nada: consulta de paridad viejo vs nuevo sin filas (tolerancia
0,001), consultas de sanidad, y `EXPLAIN` confirmando acceso por rango al índice de la fecha de
consolidación.
