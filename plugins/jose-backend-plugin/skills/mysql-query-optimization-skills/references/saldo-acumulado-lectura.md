# Estrategia: saldo acumulado por período + delta del período abierto

> **Qué es esto.** Un patrón de diseño para cuando una magnitud se calcula recorriendo todo el
> histórico (stock, saldo contable, puntos acumulados, horas imputadas) y el costo crece solo:
> cada mes que pasa hay un mes más que sumar, aunque el negocio no crezca.
>
> **No describe una tabla que ya exista.** Describe una que vas a diseñar y crear. Los nombres de
> aquí son propuestas coherentes entre sí; adapta el vocabulario a tu dominio y **conserva la
> estructura**, que es lo que hace que los números salgan bien.
>
> El lado de escritura (job de cierre, backfill) está en
> [`saldo-acumulado-escritura.md`](saldo-acumulado-escritura.md); las trampas y las consultas de
> verificación, en [`saldo-acumulado-trampas.md`](saldo-acumulado-trampas.md).

## Vocabulario que usa este documento

| En el documento | En tu dominio |
|---|---|
| `documents` (`d`) | el cabezal del documento: factura, guía, asiento, parte de horas |
| `document_lines` (`l`) | las líneas de ese documento |
| `period_balances` | la tabla de saldos que vas a crear |
| `consolidated_at` | el instante en que el documento pasó a contar. **No** es la fecha del documento |
| `status` | el estado del documento o de la línea, como escala ordenada |
| `entity_id` / `location_id` | la clave por la que acumulas (producto, cuenta, empleado) y su desglose opcional |

---

## 1. Cuándo aplica (y cuándo no)

Aplica si se cumplen las tres:

1. La magnitud es **aditiva**: el total es la suma de los movimientos.
2. Los movimientos del pasado **no cambian** en la operación normal.
3. Te interesa sobre todo **el valor de hoy**, no el de una fecha arbitraria.

No la apliques si necesitas "el saldo a cualquier fecha": el patrón solo responde bien en las
fechas que coinciden con un cierre. Ese caso se queda con el cálculo completo.

Y no la apliques antes de haber medido. Si la query lenta lo es por un índice que falta o por un
join mal ordenado, arregla eso primero (§A del `SKILL.md`): esta estrategia es un cambio de modelo
de datos, con job de cierre, backfill e interruptor. Es cara.

## 2. La idea

```
saldo_hoy = saldo_acumulado(último período cerrado) + Σ(movimientos del período abierto)
                  ↑ una fila leída                          ↑ calculado al momento
```

Lo que ganas no es solo velocidad hoy: le pones **techo** al costo. Deja de depender de cuántos
años de historia tenga el tenant.

## 3. Las cinco reglas invariantes

Romper cualquiera produce números **incorrectos**, no solo lentos. Son la parte del patrón que no
se negocia.

| # | Regla | Por qué |
|---|---|---|
| **R1** | Los acumuladores son **corridos**, no del período | La fila de febrero es el total desde el origen hasta el 28-feb, no lo que pasó en febrero. Por eso leer cuesta una fila y no N |
| **R2** | Un movimiento pertenece al período en que **se consolidó**, no al de su documento | Y sin fallback: si esa fecha falta, la línea queda fuera de todos los períodos y el saldo sale bajo en silencio |
| **R3** | Nunca guardes un promedio ya calculado | Numerador y denominador por separado, la división al leer. El promedio de promedios da números creíbles y falsos |
| **R4** | El período en curso **nunca** está en la tabla | Se calcula en vivo, así que un movimiento de hace tres segundos ya aparece |
| **R5** | La tabla es un **caché**, no fuente de verdad | Se borra entera y se regenera. De ahí que todo pueda apagarse con un interruptor |

## 4. El diseño

```sql
CREATE TABLE period_balances (
  id             INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  entity_id      INT UNSIGNED  NOT NULL,                  -- producto, cuenta, empleado…
  location_id    INT UNSIGNED  NOT NULL DEFAULT 0,        -- desglose opcional; 0 = "sin desglose"
  period         DATE          NOT NULL,                  -- primer día del período CERRADO
  qty_in         DECIMAL(16,3) NOT NULL DEFAULT 0,
  qty_out        DECIMAL(16,3) NOT NULL DEFAULT 0,
  final_balance  DECIMAL(16,3) NOT NULL DEFAULT 0,        -- qty_in - qty_out, corrido (R1)
  value_in       DECIMAL(16,6) NOT NULL DEFAULT 0,
  -- si además derivas un promedio, sus dos mitades por separado (R3)
  avg_numerator  DECIMAL(16,6) NOT NULL DEFAULT 0,
  avg_denominator DECIMAL(16,3) NOT NULL DEFAULT 0,
  created_at     TIMESTAMP     NULL DEFAULT NULL,
  updated_at     TIMESTAMP     NULL DEFAULT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_pb_entity_location_period (entity_id, location_id, period),
  KEY idx_pb_period (period, entity_id)
);

ALTER TABLE documents ADD COLUMN consolidated_at TIMESTAMP NULL DEFAULT NULL;
ALTER TABLE documents ADD INDEX idx_doc_consolidated_at (consolidated_at);
```

**El índice sobre `consolidated_at` no es opcional.** Sin él, el delta del período abierto recorre
la tabla entera de documentos y el cálculo "nuevo" sale más lento que el que reemplazas.

`DECIMAL`, no coma flotante: vas a acumular cientos de períodos y la deriva se nota (§5 de
`saldo-acumulado-escritura.md`).

En una arquitectura multi-tenant con base por cliente, la tabla se crea **en cada base**.

## 5. Poblaciones: el error más caro

Si de la misma tabla de movimientos sacas **dos magnitudes distintas** (p. ej. cuántas unidades hay
y a qué precio entraron), casi seguro **no se calculan sobre el mismo conjunto de filas**.
Mezclarlas produce números plausibles y equivocados.

El patrón que se repite:

| | Magnitud de saldo | Magnitud de valoración |
|---|---|---|
| Qué responde | ¿cuánto hay? | ¿a qué precio entró? |
| Filtra por | columnas de la **línea** | columnas del **cabezal** |
| Excluye | líneas que son componente de otra (evita doble conteo) | movimientos internos: traslados, devoluciones |

```sql
-- Población SALDO: se decide en la línea
  l.movement_code IN (<códigos que mueven inventario>)
  AND l.status    >= <mínimo que cuenta>
  AND l.component_of_id IS NULL          -- no contar componentes de un compuesto

-- Población VALORACIÓN: se decide en el cabezal
  d.movement_code = <código de entrada>
  AND d.status    >= <mínimo que cuenta>
  AND d.movement_subtype NOT IN (<traslado>, <devolución interna>)
```

Escribe cada población **una vez**, en un sitio, con un test que la fije. La causa habitual de
diferencias no es la query nueva: son las variantes ad-hoc que ya existían y filtraban distinto.

### El estado es una escala, no un booleano

Un detalle que casi siempre se modela mal: `status` suele ser un enum ordenado (pendiente,
aprobado, anulado, rechazado) y la condición correcta es **`>= aprobado`, no `= aprobado`**.

La razón es de negocio: en la mayoría de los sistemas **anular no revierte el movimiento en su
sitio** — crea un movimiento nuevo, compensatorio, fechado hoy. Si excluyes los anulados con
`= aprobado`, el original desaparece pero el compensatorio se queda, y el saldo se descuadra en el
doble. Averigua cuál de los dos modelos usa tu sistema antes de escribir el filtro, y déjalo
comentado en el código.

## 6. Cómo se lee

### 6.1 Resolver el período (siempre primero)

```sql
SELECT MAX(period) AS last_closed
FROM period_balances
WHERE period < DATE_FORMAT(CURRENT_DATE, '%Y-%m-01');
```

El piso del delta es **`last_closed` + 1 período**.

> ⚠ **El piso NO es "el primer día del período en curso".** Si el cierre no corrió —falló, se
> atrasó, el tenant es nuevo—, un piso por calendario hace **desaparecer un período entero** de
> movimientos. Derivándolo de `MAX(period)`, un cierre atrasado solo significa un delta más largo,
> nunca un número incorrecto.
>
> `last_closed IS NULL` → no hay saldos utilizables → camino de respaldo (§6.4).

### 6.2 El saldo

```sql
SELECT s.entity_id, SUM(s.balance) AS balance
FROM (
    -- Acumulado hasta el último cierre: una fila por entidad×desglose
    SELECT entity_id, final_balance AS balance
    FROM period_balances
    WHERE period = :last_closed
      -- [opcional] AND location_id IN (:locations)
      -- [opcional] AND entity_id   IN (:entities)

    UNION ALL

    -- Lo que va del período abierto, línea por línea
    SELECT l.entity_id, (l.qty_in - l.qty_out)
    FROM documents d
    JOIN document_lines l ON l.document_id = d.id
    WHERE d.consolidated_at >= :delta_floor          -- ← el piso de §6.1
      AND l.movement_code IN (<códigos que mueven inventario>)
      AND l.status >= <mínimo que cuenta>
      AND l.component_of_id IS NULL
      -- [opcional] AND l.entity_id IN (:entities)
) s
GROUP BY s.entity_id;
```

Tres cosas que no son opcionales:

- **`UNION ALL`, no dos `LEFT JOIN`.** Una entidad que solo tuvo movimientos en el período en curso
  **no está** en la tabla de saldos; con joins se perdería.
- **Los filtros van DENTRO de cada rama.** Una subconsulta agregada se materializa entera: el motor
  no puede empujarle los filtros de afuera.
- **`FROM documents JOIN document_lines`, en ese orden.** La fecha vive en el cabezal; si entras
  por la línea, el motor trae todo el histórico de esas entidades y recién ahí evalúa la fecha —
  justo lo que esta migración vino a eliminar.

### 6.3 Desglose y promedios

Para abrir por `location_id`, añádelo al `SELECT` y al `GROUP BY` **de las dos ramas**, y normaliza
el nulo igual en ambas (`COALESCE(location_id, 0)`) o las claves no cuadran y los totales se parten
en dos. Pero normaliza **la salida, no el filtro**: `COALESCE(location_id,0) IN (...)` no es
sargable y mata el índice. Filtra `location_id IN (...)`, y añade `OR location_id IS NULL` solo
cuando se pidió el `0`.

Para un promedio, misma estructura con la población de valoración, y **la división al final** (R3):

```sql
SELECT c.entity_id, SUM(c.val) / NULLIF(SUM(c.qty), 0) AS average_value
FROM ( /* rama saldos: avg_numerator, avg_denominator */
       /* UNION ALL rama delta con la población del cabezal */ ) c
GROUP BY c.entity_id;
```

`NULLIF(...,0)` conserva el `NULL` al dividir por cero: distinguir "no tengo dato" de "el valor es
cero" le importa a quien consume.

### 6.4 El camino de respaldo (obligatorio)

Cuando `last_closed` es `NULL`, usa **el cálculo anterior**, el que recorre todo el histórico.
Consérvalo **palabra por palabra**: es a la vez el respaldo cuando no hay saldos y la referencia
contra la que se compara el resultado nuevo.

## 7. El interruptor

Dos niveles, y el específico manda sobre el global:

| Marca por tenant | Default global | ¿Hay período cerrado? | Cálculo |
|---|---|---|---|
| **existe** | *ignorado* | sí | **nuevo** |
| **existe** | *ignorado* | no | anterior |
| *no existe* | activado | sí | **nuevo** |
| *no existe* | activado | no | anterior |
| *no existe* | desactivado | — | anterior ← estado inicial |

Permite encender de a un tenant y **apagar sin desplegar**. Si el almacén de la marca no responde,
cae al default: quedarse sin interruptor no puede dejar una pantalla en blanco.

La marca es **binaria — existe o no existe**, no un valor de tres estados. Al terminar el rollout
se borran todas de una pasada y no cambia nada, porque el global ya está activado.

## 8. La puerta: no encender sin esto

Una consulta de paridad que compara viejo contra nuevo y **no debe devolver ninguna fila**:

```sql
SELECT e.id,
       COALESCE(old.balance, 0)                                AS legacy,
       COALESCE(snap.balance, 0) + COALESCE(delta.balance, 0)  AS nuevo,
       COALESCE(old.balance, 0) - (COALESCE(snap.balance,0) + COALESCE(delta.balance,0)) AS diff
FROM entities e
LEFT JOIN ( /* §6.4, el histórico completo */ ) old   ON old.entity_id   = e.id
LEFT JOIN ( /* rama de saldos de §6.2      */ ) snap  ON snap.entity_id  = e.id
LEFT JOIN ( /* rama de delta de §6.2       */ ) delta ON delta.entity_id = e.id
HAVING ABS(diff) > 0.001
ORDER BY ABS(diff) DESC
LIMIT 50;
```

**La tolerancia no puede ser 0** si las columnas de origen son de coma flotante y los saldos son
decimales: sumar en órdenes distintos difiere en el último bit.

Las consultas de sanidad y el `EXPLAIN` obligatorio, en
[`saldo-acumulado-trampas.md`](saldo-acumulado-trampas.md).

## 9. Checklist de quien lee

- [ ] Piso derivado de `MAX(period)`, nunca del calendario
- [ ] `UNION ALL`, no joins, para no perder entidades nuevas
- [ ] Filtros empujados a las dos ramas, dentro de la agregación
- [ ] Delta conducido por el cabezal (donde vive la fecha), no por la línea
- [ ] Desglose nulo normalizado igual en ambas ramas; filtro en forma sargable
- [ ] Promedios: población del cabezal, división al final, `NULLIF` en el denominador
- [ ] Camino de respaldo idéntico al cálculo anterior, palabra por palabra
- [ ] Interruptor con override por tenant y default global apagado
- [ ] Consulta de paridad sin filas, en ≥ 2 rangos
- [ ] `EXPLAIN` usando el índice de `consolidated_at` por rango
- [ ] Rollback probado: apagar el override devuelve el cálculo anterior
