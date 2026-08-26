# Estrategia de saldo acumulado: trampas y verificación

> Cada una de estas ya costó caro en algún proyecto. Léelas antes de escribir la consulta, no
> después de que los números no cuadren. El vocabulario (`documents`, `document_lines`,
> `period_balances`, `consolidated_at`) está en
> [`saldo-acumulado-lectura.md`](saldo-acumulado-lectura.md).

---

## 1. Las diez trampas

### 1.1 El piso del delta por calendario

`WHERE fecha >= inicio_del_período_actual` parece obvio y **hace desaparecer un período entero** si
el cierre se atrasó, falló, o el tenant es nuevo. Deriva el piso de `MAX(period)`.

### 1.2 Mezclar las dos poblaciones

El saldo se decide en la línea; la valoración, en el cabezal. Mezclarlos produce números plausibles
y falsos, que es la peor clase de error: nadie los revisa.

### 1.3 El desglose nulo

Si los saldos normalizan `NULL → 0`, el delta **debe** hacer lo mismo
(`COALESCE(location_id, 0)`) en el `SELECT` **y** en el `GROUP BY`. Si no, las claves no cuadran y
los totales se parten en dos.

### 1.4 Filtrar por la fecha del documento en vez de la de consolidación

Un documento con fecha vieja consolidado dentro del período abierto se contaría **dos veces**: una
en los saldos y otra en el delta.

Y si alguien necesita **"el saldo a una fecha arbitraria"**, esta estrategia **no lo resuelve**
salvo que la fecha coincida con un cierre. Deja ese caso con el cálculo anterior.

### 1.5 Criterios divergentes preexistentes

Antes de unificar consultas ad-hoc, compáralas. Es habitual encontrar variantes a las que:

- les falta el filtro de componente → **doble conteo**;
- leen el estado del cabezal en vez del de la línea;
- usan `= aprobado` en vez de `>= aprobado`.

Migrarlas **cambia números en producción**. Sepáralo del cambio transparente y valídalo con
negocio: es una corrección, no una optimización, y merece que alguien la firme.

### 1.6 Recalcular al editar el pasado

Si se modifica un documento de un período ya cerrado, hay que regenerar ese período **y todos los
posteriores**. Dos defensas complementarias: encolar el recálculo automáticamente, y **acotar
cuánto hacia atrás se puede editar** (p. ej. 3 períodos, medidos sobre `consolidated_at`).

La operación normal no dispara nada: un documento consolidado hoy cae en el período en curso, que
nunca está en la tabla de saldos (R4).

### 1.7 El delta conducido por la entidad en vez de por la fecha

Si el delta se escribe `FROM document_lines JOIN documents`, con un filtro de entidad selectivo el
motor entra por la línea, trae **todo el histórico de esas entidades** y va al cabezal fila por fila
para recién ahí evaluar la fecha — exactamente lo que la estrategia vino a eliminar.

La fecha vive en el cabezal, así que ningún índice de la línea puede podarla. **El delta tiene que
conducirse por el rango de fechas** (`FROM documents JOIN document_lines`), y conviene forzarlo: el
orden del `FROM` no obliga al optimizador.

El costo correcto es proporcional a la actividad del período abierto, no al histórico.

### 1.8 Agregar antes de filtrar

Toda subconsulta agregada (`GROUP BY`) se materializa entera: el motor **no puede** empujarle los
filtros de la consulta externa. Si el alcance de entidades se aplica afuera, se agrega el universo
completo y recién después se descarta.

El alcance tiene que ir **dentro** de la agregación — como lista de ids si es chica, o como
subconsulta unida por `JOIN` si sale de un filtro. Un `JOIN` a una subconsulta sin `GROUP BY` sí se
fusiona, y deja el filtro en el mismo `WHERE` que la agregación.

### 1.9 Normalizar el desglose en el filtro mata el índice

`COALESCE(location_id, 0) IN (...)` no es sargable. Normaliza la **salida** (en el `SELECT` y el
`GROUP BY`, que es donde hace falta para que las claves cuadren con los saldos) y deja el filtro en
su forma sargable: `location_id IN (...)`, más `OR location_id IS NULL` solo cuando se pidió el `0`.

### 1.10 Procesos de fondo y multi-tenant

Si la resolución de la base depende de la sesión del usuario, un job sin sesión puede caer a la
conexión por defecto **en silencio** y leer o escribir en la base equivocada. Resuelve el tenant por
parámetro explícito, nunca por estado implícito.

---

## 2. Consultas de sanidad — antes de encender

### (a) ¿Queda alguna línea que cuenta cuyo documento no tenga fecha de consolidación?

**Debe dar 0.** Si no, esas líneas desaparecen del cálculo nuevo y el saldo sale bajo.

```sql
SELECT COUNT(*)
FROM document_lines l
JOIN documents d ON d.id = l.document_id
WHERE <población de la línea>
  AND d.consolidated_at IS NULL;
```

### (b) ¿Hay líneas cuyo documento ya no existe?

```sql
SELECT COUNT(*), SUM(l.qty_in - l.qty_out)
FROM document_lines l
LEFT JOIN documents d ON d.id = l.document_id
WHERE <población de la línea>
  AND d.id IS NULL;
```

**Esta suele ser la causa #1 de diferencias.** Esas líneas hoy suman al saldo (el cálculo antiguo no
une con el cabezal) y con el modelo nuevo no, porque saldos y delta **sí** lo unen.

No las escondas metiendo un `LEFT JOIN` en el cálculo nuevo: son una decisión de negocio, y lo
correcto es un ajuste explícito.

---

## 3. Verificar el plan de ejecución

```sql
EXPLAIN SELECT COUNT(*)
FROM document_lines l
JOIN documents d ON d.id = l.document_id
WHERE d.consolidated_at >= '2026-08-01' AND d.consolidated_at < '2026-09-01';
```

Debe usar el índice de `consolidated_at` con **acceso por rango**. Si hace recorrido completo, el
índice falta o no se está usando, y el cálculo "nuevo" será **más lento** que el anterior.

---

## 4. Cómo traducir esto a tu dominio

| Concepto del patrón | Qué buscar en tu esquema |
|---|---|
| `documents` | el cabezal: factura, guía, asiento, parte de horas, pedido |
| `document_lines` | sus líneas |
| `movement_code` | el tipo de operación que decide si la línea suma, resta o no cuenta |
| `status` | el estado como **escala ordenada**, no como booleano (§5 de la referencia de lectura) |
| `component_of_id` | la marca de "esta línea es parte de otra": si existe, hay riesgo de doble conteo |
| `location_id` | el desglose opcional del saldo: bodega, sucursal, centro de costo |
| `consolidated_at` | el instante en que el documento pasó a contar. Si tu sistema no lo guarda, **hay que crearlo**: es el prerrequisito de toda la estrategia |
