# Gastos, entrega 7: roturas a cargo del empleado — Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Al cargar una baja de stock o al resolver una salvedad de mercadería dañada, vencida o
faltante, el admin puede cargarle el costo a uno o más empleados. A cada uno le entra un movimiento
`rotura` (−) en su cuenta, que la liquidación descuenta.

**Architecture:**
- **El cargo es un movimiento `rotura`** de `empleado_movimientos`, negativo, que apunta a la merma
  (`merma_id`) o a la salvedad (`salvedad_id`), exactamente a una. No hay tabla nueva: las líneas
  de un cargo son los movimientos con el mismo `merma_id` o `salvedad_id`.
- **Viaja en la misma llamada** que crea la pérdida: `registrar_merma_manual` y `resolver_salvedad`
  suman `p_cargos jsonb DEFAULT NULL` y escriben las líneas en su transacción, con un helper común
  `_cargar_roturas`. Se dropean las firmas viejas (PGRST203).
- **Deshacer:** `anular_salvedad` revierte las `rotura` vivas de su salvedad. La de merma manual se
  revierte desde la cuenta con `revertir_movimiento_empleado`, que pasa a aceptarla; la de salvedad
  la rechaza.
- **Front:** una sección «A cargo de empleados» (componente compartido) en `ModalMermaStock` y en
  `ModalResolverSalvedad`; la opción `descuento_transportista` se etiqueta «A cargo de empleados» y
  sólo la ve el admin.

**Tech Stack:** React 19 + Vite + TanStack Query + Zod + vitest/testing-library; Supabase Postgres
(plpgsql, `migrations/`).

**Spec:** `docs/superpowers/specs/2026-11-04-roturas-a-cargo-del-empleado-design.md`, aprobado por el
dueño el 2026-11-04. Amplía la §4.5 de `2026-10-28-gastos-y-cuentas-del-personal-design.md` (#1332).
Molde: `docs/superpowers/plans/2026-11-03-gastos-6-faltantes-de-rendicion.md`.

**Base de la rama:** `claude/gastos-7-roturas`, cortada de `main` en `850d0426`, con las
migraciones hasta la 448 en prod.

**Ejecución:** la Tarea 2 (SQL) la hace la sesión que escribió el plan, con Opus. Las Tareas 1 y 3 a
5 (front) van a un subagente Sonnet en la misma rama, en paralelo: sólo dependen de las firmas de la
sección Interfaces. La Tarea 6 junta, verifica y abre el PR. Aplicar la migración y mergear piden el
OK del dueño.

## Lo que hay hoy (relevado en prod el 2026-11-04, sólo lectura)

`md5(prosrc)`; se re-consultan antes de escribir la guarda.

| Función | md5(prosrc) | CRLF |
|---|---|---|
| `registrar_merma_manual(bigint,integer,text,text,bigint)` | `8b9d03b14baf86cd171e4c3b856d09d2` | no |
| `resolver_salvedad(bigint,character varying,text,bigint)` | `8528b9e2c7819615261084e99e5c00ce` | no |
| `anular_salvedad(bigint,text)` | `da097db9642be74e4853dccaab948941` | no |
| `revertir_movimiento_empleado(bigint,text)` | `77ac954dddc9753fce5a6c5968f20c39` | no |
| `_movimiento_origen_json(empleado_movimientos)` | `791da0c0e11600728a6b57f9f248b3ba` | sí |

- `registrar_merma_manual` ya es sólo de admin; lockea el producto y el costo lo congela
  `trg_mermas_snapshot_costo`. No es idempotente y no tiene camino offline.
- `resolver_salvedad` es de admin o encargado, devuelve `{success, error}` en vez de `RAISE`, y sólo
  resuelve una `pendiente`.
- `registrar_salvedad` deja la merma (con `salvedad_id`) de `producto_danado`, `producto_vencido` y
  `faltante_stock`, salvo el faltante sobre un regalo (#847). `anular_salvedad` le pone `anulada_at`.
- `empleado_movimientos.tipo` tiene CHECK de dominio; hay un CHECK por tipo para su signo y su
  referencia (ver `faltante`, `reintegro`). `revierte_id` es UNIQUE.
- `revertir_movimiento_empleado` acepta sólo `adelanto`, `ajuste` y `pago`, y su fila de reversión no
  copia las referencias del original.
- `empleados_para_elegir()` (admin o encargado) da id, nombre, usuario_id, vehiculo_id y activo de la
  sucursal actual y los de las dos.
- `descuento_transportista`: 0 filas en `salvedades_items`. 48 salvedades pendientes.

## Interfaces (las comparten la Tarea 2 y el front)

```text
registrar_merma_manual(p_producto_id bigint, p_cantidad integer, p_motivo text,
                       p_observaciones text DEFAULT NULL, p_sucursal_id bigint DEFAULT NULL,
                       p_cargos jsonb DEFAULT NULL) RETURNS jsonb   -- igual que hoy + 'cargos': [ids]
resolver_salvedad(p_salvedad_id bigint, p_estado_resolucion varchar, p_notas text DEFAULT NULL,
                  p_pedido_reprogramado_id bigint DEFAULT NULL, p_cargos jsonb DEFAULT NULL) RETURNS jsonb
p_cargos = [{"empleado_id": number, "monto": number}]   -- monto > 0, lo que se descuenta
obtener_cuenta_empleado: cada movimiento suma 'merma_id' y 'salvedad_id' (number | null)
```

## Decisiones de este plan

1. **Errores:** `registrar_merma_manual` hace `RAISE` como hoy; `resolver_salvedad` devuelve
   `{success:false, error}` como hoy, también para los errores del cargo.
2. **Validación del cargo** (en `_cargar_roturas(p_cargos, p_merma_id, p_salvedad_id, p_fecha,
   p_obs)`, sin EXECUTE para nadie):
   - sólo admin; arreglo no vacío; cada `monto` numérico, > 0, ≤ 9.999.999.999,99, redondeado a 2;
   - empleado existente, activo, visible (`_empleado_visible`), de la sucursal de la pérdida o de
     las dos; nunca el vinculado a `auth.uid()`; sin repetir empleado;
   - lockea los empleados `FOR UPDATE` ordenados por id (el orden de `registrar_movimiento_empleado`).
   - Sin tope contra el costo.
3. **`resolver_salvedad`:** con `p_cargos` no nulo exige `p_estado_resolucion =
   'descuento_transportista'`; y `descuento_transportista` exige admin, `p_cargos` con al menos una
   línea y motivo en (`producto_danado`, `producto_vencido`, `faltante_stock`).
4. **La línea:** `tipo='rotura'`, `monto = -monto`, `fecha = _tablero_hoy()`, `observacion` =
   «Rotura: N u. de <producto>» (+ « · salvedad #id»), `creado_por = auth.uid()`.
5. **CHECKs nuevos:** `tipo` suma `'rotura'`; `rotura_negativa` (`tipo <> 'rotura' OR revierte_id IS
   NOT NULL OR monto < 0`); `rotura_origen` (`(tipo = 'rotura') = (num_nonnulls(merma_id,
   salvedad_id) = 1)`). FKs a `mermas_stock(id)` y `salvedades_items(id)`. Índices parciales por
   `merma_id` y `salvedad_id`.
6. **Reversión:** `revertir_movimiento_empleado` acepta `rotura` con `merma_id`, rechaza la de
   `salvedad_id` («se deshace anulando la salvedad»), y la fila que revierte copia `merma_id` y
   `salvedad_id` (si no, el CHECK `rotura_origen` la rechaza). Una `rotura` liquidada se revierte
   igual: la compensación cae en la liquidación siguiente.
7. **`anular_salvedad`:** después de anular la merma, inserta una reversión por cada `rotura` viva
   (sin reversión) de esa salvedad, lockeando los empleados como en (2).
8. **Origen en la cuenta y la liquidación:** `_movimiento_origen_json` suma `merma_id` y
   `salvedad_id`, así lo leen `obtener_cuenta_empleado` y la vista previa sin tocarlas.
9. **Lo que no se toca:** `cerrar_salvedades_en_lote`, `mermas_valorizadas`, las vistas de mermas y
   salvedades (no muestran el cargo), `auditoria_integridad()` (los checks van a #1426).

## Global Constraints

- `CLAUDE.md`: REVOKE `FROM PUBLIC, anon` en cada función nueva o recreada y `GRANT EXECUTE ... TO
  authenticated` sólo a las dos RPCs; el helper sin EXECUTE para `authenticated`. El día es
  `_tablero_hoy()`. Parámetros PostgREST en `integer`/`bigint`, nunca `smallint`.
- `migrations/CLAUDE.md` para lo que toca mermas: no se cambia cómo se mueve el stock.
- Guarda md5 sobre el `prosrc` vivo de las cinco funciones al principio de la migración.
- El número de migración se elige al final, contra el ledger. El archivo nace `NNN_gastos_7_roturas.sql`.
- Montos en el front con `InputMonto`; los ids con `z.coerce`.

## Review Focus

1. **Revertir una `rotura` de salvedad desde la cuenta**: tiene que fallar con el mensaje de (6).
2. **Anular una salvedad con una `rotura` ya revertida a mano**: imposible por (6), pero el bucle de
   (7) salta las que ya tienen reversión y no choca con el UNIQUE de `revierte_id`.
3. **El encargado manda `descuento_transportista` o `p_cargos`** con el bundle nuevo o a mano:
   rechazado; con el bundle viejo (4 args) sigue resolviendo lo demás.
4. **Dos líneas al mismo empleado o un empleado de otra sucursal**: rechazado.
5. **Una merma sin cargos**: idéntica a hoy (mismo JSON más `cargos: []`).

---

### Task 1: Reparto y tipos (front, Sonnet)

**Files:** Modify `src/utils/personal.ts`, `src/utils/personal.test.ts`, `src/types/personal.ts`.

- [ ] Test `repartirCosto(total, n)`: `repartirCosto(1000, 3)` → `[333.34, 333.33, 333.33]`;
  `repartirCosto(0, 2)` → `[0, 0]`; `repartirCosto(100, 1)` → `[100]`; la suma siempre da `total`.
- [ ] Implementar `export function repartirCosto(total: number, n: number): number[]` (centavos, el
  resto a la primera).
- [ ] `TipoMovimientoEmpleado` suma `'rotura'`; `MovimientoEmpleado` suma `merma_id: number | null` y
  `salvedad_id: number | null`.
- [ ] `conceptoDeMovimiento`: `rotura` → `{ titulo: 'Rotura a su cargo', detalle: observacion }`;
  `TITULO_REVERSION.rotura = 'Revierte una rotura'`. Tests de los dos.
- [ ] `npx vitest run src/utils/personal.test.ts` pasa; commit.

### Task 2: Migración (SQL, Opus)

**Files:** Create `migrations/NNN_gastos_7_roturas.sql`, `scripts/test-gastos-7.sql`; modify
`scripts/rpcs-definer-permitidas.json` si el gate lo pide.

- [ ] Guarda md5 (tabla de arriba) y ensayo `DO $ensayo$ ... RAISE EXCEPTION` que cubre: merma con
  dos cargos (saldo de los dos baja), merma sin cargos, cargo a sí mismo / repetido / otra sucursal /
  inactivo / monto ≤ 0 (rechazados), salvedad dañada con cargo por admin, encargado con cargo
  (rechazado), `descuento_transportista` sin cargos o sobre `cliente_rechaza` (rechazado), anular la
  salvedad (las dos `rotura` revertidas, saldo vuelve), revertir `rotura` de merma (ok) y de salvedad
  (rechazado), `critical_high_en_rojo` 0 antes y después.
- [ ] Columnas, CHECKs, FKs e índices de la decisión 5.
- [ ] `_cargar_roturas` (decisiones 2 y 4); recrear las dos RPCs con `p_cargos` (decisiones 1 y 3),
  dropeando las firmas viejas; `revertir_movimiento_empleado` (6); `anular_salvedad` (7) partiendo del
  cuerpo vivo; `_movimiento_origen_json` (8). REVOKE/GRANT de Global Constraints.
- [ ] Correr `scripts/test-gastos-7.sql` en prod (termina en el `RAISE` del ensayo, todo vuelve
  atrás) y pegar el resultado en el PR. No aplicar.
- [ ] Commit.

### Task 3: Sección «A cargo de empleados» (front, Sonnet)

**Files:** Create `src/components/personal/CargoEmpleados.tsx` y su test.

**Props:** `{ costo: number | null; value: LineaCargo[]; onChange(v: LineaCargo[]): void }`, con
`LineaCargo = { empleado_id: number | null; monto: string }`.

- [ ] Tests: arranca sin líneas; «+ Empleado» agrega una línea y reparte `costo` con `repartirCosto`
  entre todas mientras ningún monto fue tocado a mano; con `costo` null o 0 el monto queda vacío; la
  lista de empleados sale de `useEmpleadosParaElegirQuery` sólo con activos y sin los ya elegidos;
  suma > costo muestra el aviso «Cargás más que el costo de la mercadería ($X)» y no bloquea.
- [ ] Implementar con `InputMonto` y el `Lista`/select con flecha del modal de gasto; commit.

### Task 4: Baja de stock y salvedad (front, Sonnet)

**Files:** Modify `ModalMermaStock.tsx`, `useMermasQuery.ts`, `ModalResolverSalvedad.tsx`,
`useSalvedadesQuery.ts`, `src/lib/schemas.ts`, `src/types/hooks.ts`, y sus tests.

- [ ] `ModalMermaStock`: `CargoEmpleados` debajo de observaciones, con `costo = cantidad ×
  costo del producto` si el modal lo tiene; si no, `null`. Al guardar manda `p_cargos` sólo con las
  líneas completas; una línea a medias (sin empleado o sin monto válido por `parseMonto`) bloquea con
  error. Sin líneas manda `p_cargos: null`.
- [ ] `ESTADOS_RESOLUCION_LABELS.descuento_transportista = 'A cargo de empleados'`. En
  `ModalResolverSalvedad` la opción sólo aparece si el rol es admin y el motivo es uno de los tres;
  elegirla muestra `CargoEmpleados` con el costo de la merma de la salvedad si viene en los datos
  (si no, `null`) y exige al menos una línea completa. `resolverSalvedad` manda `p_cargos`.
- [ ] Tests: el payload de las dos RPCs con y sin cargos; el encargado no ve la opción; motivo
  `cliente_rechaza` no la ofrece. Commit.

### Task 5: La cuenta del empleado (front, Sonnet)

**Files:** Modify `ModalCuentaEmpleado.tsx` y su test.

- [ ] «Revertir» aparece en una `rotura` con `merma_id` (no revertida, no reversión, no propia) y no
  en la de `salvedad_id`, que dice «Se deshace anulando la salvedad». Tests de los dos. Commit.

### Task 6: Cierre (Opus, esta sesión)

- [ ] `npm run typecheck`, `lint`, `test:run`, `build` (con el turno `refs/turno/pesado`).
- [ ] Pedir al dueño el OK para aplicar; elegir el número contra el ledger; aplicar; verificar md5 de
  `statements[1]` y `auditoria_integridad()`.
- [ ] PR con `Closes` de lo que cierre, comentario en #1332, y el OK del dueño para mergear.
