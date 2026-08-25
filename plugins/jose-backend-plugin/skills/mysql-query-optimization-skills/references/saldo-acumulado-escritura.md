# Estrategia de saldo acumulado: lado de escritura

> Solo hace falta si vas a **generar** los saldos o a poblar la fecha de consolidación. Quien
> únicamente lee tiene bastante con
> [`saldo-acumulado-lectura.md`](saldo-acumulado-lectura.md), que además fija el vocabulario que
> usa este documento (`documents`, `document_lines`, `period_balances`, `consolidated_at`).

---

## 1. La fecha de consolidación

Es el prerrequisito de todo. Sin `consolidated_at` poblado, los movimientos quedan fuera de todos
los períodos y el saldo sale **silenciosamente bajo**.

### 1.1 La regla: la marca es monotónica

```
estado pasa a >= mínimo  →  consolidated_at = COALESCE(consolidated_at, NOW())   -- solo si está vacía
estado baja del mínimo   →  no se toca
```

**`COALESCE`, nunca `NOW()` pelado.** La fecha se escribe en la **primera** consolidación y no se
pisa ni se borra nunca.

**Por qué.** Si en tu sistema anular no revierte el movimiento en su sitio sino que crea uno
compensatorio fechado hoy, la diferencia entre pisar la fecha y no pisarla es esta —documento
consolidado el 10-may y anulado el 20-ago:

| | Marca monotónica | Si se pisara la fecha |
|---|---|---|
| Líneas del documento (−10) | quedan en **mayo** | migran a **agosto** |
| Movimiento compensatorio (+10) | agosto | agosto |
| Saldos de mayo, junio, julio | **intactos** | **inválidos** → regenerar los tres |
| Saldo actual | −10 + 10 = 0 ✓ | −10 + 10 = 0 ✓ |

Ambas dan el saldo actual correcto; la diferencia es el costo de mantenimiento y la honestidad del
histórico (pisando, mayo pasaría a decir que esa mercadería nunca salió).

**Y borrar la fecha al bajar de estado perdería información.** Si un documento de mayo se rechaza en
agosto, hay que regenerar mayo — pero sin la fecha ya no se sabe cuál. Dejándola, el cierre la
ignora igual (filtra por estado) y si el documento se reconsolida vuelve a su período original.

### 1.2 Dónde interceptar

El objetivo es **un solo punto de escritura**, no N repartidos.

- **ORM con capa de consultas interceptable** → sobrescribe la operación de `UPDATE` de esa
  entidad. Un único archivo puede cubrir cientos de asignaciones repartidas por todo el código.
- **Sin esa capa** → un trigger en la base:

```sql
CREATE TRIGGER trg_documents_consolidated_at
BEFORE UPDATE ON documents
FOR EACH ROW
  SET NEW.consolidated_at =
      CASE WHEN NEW.status >= <mínimo que cuenta>
           THEN COALESCE(OLD.consolidated_at, NEW.consolidated_at, NOW())
           ELSE OLD.consolidated_at END;
```

- **Ojo con los INSERT.** Un documento que **nace** consolidado no pasa por el `UPDATE`. Necesita su
  propio hook (`BEFORE INSERT`, o el evento de creación del ORM).

> ⚠ **Los eventos de modelo del ORM no bastan** si el código hace actualizaciones masivas por
> constructor de consultas: en la mayoría de los ORM esas no disparan eventos por fila. Verifica
> por dónde pasan **todas** las escrituras antes de elegir el punto.

### 1.3 Rollout progresivo

Si el esquema se aplica base por base (multi-tenant), el código debe tolerar que la columna todavía
no exista: **si falta, no la escribas**, en vez de fallar. Cachea esa detección — una consulta al
catálogo por base y por proceso alcanza.

---

## 2. Backfill del histórico

```sql
-- Por ventanas de id, no en un solo UPDATE
UPDATE documents
SET consolidated_at = COALESCE(<fecha del documento>, created_at, updated_at)
WHERE consolidated_at IS NULL
  AND status >= <mínimo que cuenta>
  AND id BETWEEN :desde AND :hasta;
```

Y una segunda pasada para los **huérfanos de estado**: documentos con el cabezal pendiente cuyas
**líneas** sí cuentan. Esas líneas entran en el saldo, así que sin fecha en su cabezal
desaparecerían.

> La fecha del histórico es **necesariamente una aproximación**: el momento real de consolidación
> nunca se registró. Es aceptable porque los saldos son regenerables, y **para el total no cambia
> nada** (el cálculo antiguo no filtra por fecha). Lo que define es en qué período cae cada
> movimiento histórico.

**Orden de aplicación: columna → backfill → índice.** Crear el índice antes del `UPDATE` masivo
obliga a mantenerlo fila por fila; al final se construye de una pasada.

---

## 3. El job de cierre

### 3.1 Por qué no escribir el acumulado al consolidar

| | Escribir al consolidar | Job de cierre |
|---|---|---|
| Naturaleza del dato | estado mantenido a mano | **derivado**, recalculable |
| Si se pierde una escritura | diverge para siempre, en silencio | se regenera |
| Contención | alta en las entidades más activas | ninguna |
| Código en el flujo crítico | sí | **ninguno** |

Un total corrido mantenido a mano solo es correcto si **ninguna** escritura se pierde jamás — ni por
un rollback, ni por un crash, ni por un `UPDATE` manual. Y cuando se pierde una, no hay forma de
saberlo.

### 3.2 Algoritmo

Entrada: identificador del tenant/base + el período a cerrar.

```
1. Si el período pedido aún no terminó        → no hacer nada.
2. Buscar el último saldo ANTERIOR al período pedido.
   - Si no existe                             → arrancar desde el primer movimiento consolidado.
   - Si existe                                → partir de él.
3. Para cada período desde (base + 1) hasta el pedido:
      acumulado[entidad,desglose] += delta_del_período
      escribir el acumulado como fila del período
4. Si ya existían períodos POSTERIORES al pedido → regenerarlos también:
   los acumuladores son corridos (R1), así que tocar el período P invalida P y toda la cadena.
```

### 3.3 El delta de un período, en una sola pasada

Produce **todos los juegos de acumuladores a la vez**; si tienes dos poblaciones (§5 de la
referencia de lectura), cada una va en su propio `CASE`:

```sql
SELECT l.entity_id,
       COALESCE(l.location_id, 0) AS location_id,
       -- Población SALDO: se decide en la línea
       SUM(CASE WHEN <población de la línea> THEN l.qty_in  ELSE 0 END) AS qty_in,
       SUM(CASE WHEN <población de la línea> THEN l.qty_out ELSE 0 END) AS qty_out,
       -- Población VALORACIÓN: se decide en el cabezal
       SUM(CASE WHEN <población del cabezal> THEN l.qty_in                ELSE 0 END) AS avg_denominator,
       SUM(CASE WHEN <población del cabezal> THEN l.unit_price * l.qty_in ELSE 0 END) AS avg_numerator
FROM documents d
JOIN document_lines l ON l.document_id = d.id
WHERE d.consolidated_at >= :desde AND d.consolidated_at < :hasta   -- intervalo SEMIABIERTO
  AND l.entity_id IS NOT NULL
  AND ( <población de la línea> OR <población del cabezal> )
GROUP BY l.entity_id, COALESCE(l.location_id, 0);
```

El intervalo es **semiabierto** (`>= desde AND < hasta`): con `<=` sobre una columna que guarda
hora, se pierde el último día del período.

### 3.4 Escritura idempotente

Reescribe **el período completo** dentro de una transacción: `DELETE WHERE period = :p` seguido de
inserciones por lotes. El `DELETE` hace falta porque una combinación entidad×desglose puede haber
dejado de existir (si los movimientos se borran físicamente).

Reprocesar un período debe dar **exactamente** el mismo resultado.

### 3.5 Precisión

- Si vas a acumular 100+ períodos, **no uses coma flotante**: la deriva se nota.
- Cuidado con los enteros escalados: un entero de 64 bits a escala 10⁶ topa en 9,2·10¹², y un dato
  mal cargado lo desborda **en silencio**. Usa decimal de precisión arbitraria.
- **Verifica los topes antes de escribir**, nombrando la entidad que se desborda: la base solo
  diría "out of range en la fila 879".
- **Redondear, no truncar** — truncar sesga el acumulado hacia abajo período a período. Y redondea
  **el delta de cada período**, no el acumulado final: así un backfill completo y un cierre
  incremental dan exactamente el mismo número.

---

## 4. Orden de puesta en marcha

```
1. Esquema        : columna + índice + tabla de saldos             (sin efecto)
2. Escritura      : poblar consolidated_at de aquí en adelante     (sin efecto: nadie la lee)
3. Backfill       : rellenar el histórico                          (sin efecto)
4. Cálculo nuevo  : implementarlo detrás de un interruptor APAGADO (sin efecto)
5. Generar saldos : correr el cierre por tenant
6. Comparar       : viejo vs nuevo                                 ← la puerta
7. Encender       : tenant por tenant
```

Los pasos 1-4 son desplegables **sin cambio de comportamiento**. Esa es la propiedad que hace que
todo esto sea reversible.
