# MANIFEST de migraciones — mapeo repo ↔ producción

> **Fechado: 2026-07-10** · Proyecto prod `hmuchlzmuqqxcldbzkgc` (ManaosApp) · región `sa-east-1`.

## Regla de oro

`migrations/` es una **vista curada y consolidada**, **NO** un espejo 1:1 del historial
aplicado. La **fuente de verdad es producción** (`supabase_migrations.schema_migrations`,
"el ledger"). Concretamente:

- `000_baseline.sql` es fiel **al 2026-04-21**. Del `001` en adelante son cambios post-baseline.
- Los archivos a veces **consolidan** varias filas del ledger en una sola, **renombran**, o
  **renumeran**. Por eso comparar nombres de archivo contra el ledger da falsos positivos.
- **Antes de asumir que algo "falta" o "está pendiente", verificá en vivo** (abajo).

**Regla práctica:** todo `NNN_<stem>.sql` que **no** aparezca en la tabla de excepciones de
abajo mapea **1:1** a una fila del ledger con el mismo `stem` (el ledger a veces no lleva el
prefijo `NNN_`, es normal: guarda el `name` que se pasó al `apply_migration`).

## Cómo verificar drift (en vivo)

- **Agente con MCP de Supabase:** `list_migrations` y comparar con `ls migrations/`. Es lo más
  directo; no requiere nada más.
- **CI / humano:** `node scripts/check-migrations.mjs` (env `SUPABASE_URL` +
  `SUPABASE_SERVICE_ROLE_KEY`). Lee el ledger vía el RPC `public.migraciones_aplicadas()`
  (creado en `109`) porque el schema `supabase_migrations` no está expuesto por PostgREST.

## Cómo se aplican las migraciones

Hoy se aplican vía **MCP `apply_migration`** (queda registrada en el ledger con su `name`) o,
ocasionalmente, por el **SQL editor / `execute_sql`** (NO queda en el ledger → "out-of-band";
ver excepciones). El `db push` por CLI del README es el método histórico/manual.

---

## Excepciones (lo que NO es 1:1)

Convenciones: **consolidado** = varias filas del ledger (iteraciones `CREATE OR REPLACE` o
hotfixes) plegadas en 1 archivo con el estado final · **out-of-band** = aplicado sin pasar por
`apply_migration`; backfilleado al ledger el 2026-06-30 con `version` sintética · **dup-NN** =
número de archivo repetido en el repo (el orden real lo da `version`).

### A. Números de archivo duplicados (mismo `NN`, dos archivos)

| `NN` | archivos en el repo | orden real (por `version` del ledger) |
|------|---------------------|----------------------------------------|
| 030 | `030_bot_tomar_pedido.sql`, `030_fix_fraccion_producto_regalo.sql` | `bot_tomar_pedido` (05-01) → `fix_fraccion_producto_regalo` (05-04) |
| 040 | `040_perfiles_rol_check_encargado.sql`, `040_pedidos_geolocalizacion.sql` | `perfiles_rol_check_encargado` (05-11 19:35) → `pedidos_geolocalizacion` (05-11 21:51) |
| 080 | `080_clientes_guard_update_preventista.sql`, `080_clientes_proteger_columnas_preventista.sql` | `clientes_guard_update_preventista` (06-10 15:22) → `proteger_columnas_preventista` (06-10 15:27) |
| 081 | `081_clientes_horario_entrega.sql`, `081_aplicar_orden_ruta.sql` | `clientes_horario_entrega` (06-12 00:56) → `aplicar_orden_ruta` (06-12 17:50) |
| 091 | `091_fix_promo_acumuladores_resto_y_clamp.sql`, `091_cambio_motivo_mal_estado.sql` | `fix_promo_acumuladores_resto_y_clamp` (06-23) → `cambio_motivo_mal_estado` (06-24) |
| 100 | `100_costo_snapshot_y_creado_por_columnas.sql`, `100_marcar_entrega_y_pago_masivo.sql` | `costo_snapshot` (06-29, ver C) → `marcar_entrega_y_pago_masivo` (06-30) |

### B. Offset de numeración (repo va +1 respecto del ledger en 098–100)

El repo gastó `098` en `fix_bonif_fraccion`, así que de ahí los números repo y ledger se
desfasan y **se realinean en `101`**:

| archivo repo | fila(s) del ledger |
|--------------|--------------------|
| `098_reporte_gerencial_fix_bonif_fraccion.sql` | `reporte_gerencial_fix_bonif_fraccion` (sin prefijo) |
| `099_bot_ventas_entregado.sql` | `098_bot_ventas_entregado` |
| `100_costo_snapshot_y_creado_por_columnas.sql` | `099_costo_snapshot_y_vendedor_id` **+** `100_creado_por_descarta_vendedor_id` (ver C) |
| `101_crear_pedido_costo_snapshot_creado_por.sql` | `101_crear_pedido_costo_snapshot_creado_por` ✓ realineado |

### C. Out-of-band (vivos en prod, aplicados por SQL editor; backfilleados al ledger el 2026-06-30)

| archivo repo | `version` sintética en el ledger | objeto vivo confirmado |
|--------------|----------------------------------|------------------------|
| `085_registrar_pago_combinado_cliente_fifo.sql` | `20260616000085` | fn `registrar_pago_combinado_cliente_fifo` |
| `086_saldo_a_favor_reduce_saldo_cuenta.sql` | `20260616000086` | trigger `trigger_actualizar_saldo_pago` (UPDATE) |
| `097_reporte_gerencial_revoke_public.sql` | `20260629000097` | `anon` sin EXECUTE en `reporte_gerencial` |

> Las `version` sintéticas (`…0000NN`) los ordenan entre sus vecinos del repo. El `name` en el
> ledger lleva el sufijo `(backfill out-of-band 2026-06-30)`.

### D. Consolidaciones (N filas del ledger → 1 archivo)

| archivo repo | filas del ledger consolidadas |
|--------------|-------------------------------|
| `011_promo_descripcion_regalo_y_reversion_bloques.sql` | `011a` … `011e` (5 filas) |
| `012_categorias_activa_y_promo_bundle_pedidos.sql` | `012a`, `012b`, `012c` |
| `060_preventista_asignable.sql` | `060_preventista_asignable` (×2) + `060_drop_old_crear_pedido_completo_signature` |
| `061_sustitucion_regalo_fixes.sql` | `060_sustitucion_regalo_fixes` |
| `064_registrar_salvedad_total_neto_iva.sql` | `064_…` + `064_registrar_salvedad_idempotente_total_neto_iva` |
| `076_movimientos_sucursal_y_notificaciones.sql` | `076_…` + `076b_revoke_helpers_internos` |
| `078_control_stock_planilla.sql` | `control_stock_sesiones_y_rpc_aplicar` + `…_fk_usuario` + `fix_aplicar_control_stock_diferencia_generada` |
| `095_reporte_gerencial.sql` | `reporte_gerencial` + `reporte_gerencial_fix_base_comision` |
| `105_auditoria_integridad.sql` | `105_…` + `105_…_ventana_2h` + `105_…_fix_cc_saldo_a_favor` |
| `123_terna_ingresos_pedidos.sql` | `123_…` (DDL+backfill+función) + `123_…_rpcs` (crear/bot) + `123_…_rpcs2` (editar/salvedades/cambiar tipo) — aplicado en 3 tandas por tamaño |
| (bot 014–020) | hotfix `020_bot_fix_pgcrypto_schema` plegado en la tanda, sin archivo propio |

**Cadena `reporte_gerencial`** (reescrita ~9 veces por `CREATE OR REPLACE`): el repo versiona
los hitos (`095`, `097` grants, `098`, `103`, `106`, `107`, `110`). Los intermedios del ledger
`reporte_gerencial_restringir_por_sucursal_asignada` y `reporte_gerencial_desglose_bonif_mermas`
**no tienen archivo dedicado**: su lógica (p.ej. el gate `v_asignadas`) **sobrevive en el body
vivo**, que equivale al último archivo (`110`: cobranza desde `pagos`, parciales por monto,
compras sin canceladas, split de mermas, `bonif_promos`).

---

## Mantenimiento

- Toda migración nueva: archivo `migrations/NNN_descripcion.sql` **y** aplicar por
  `apply_migration` con `name = NNN_descripcion` (así repo y ledger quedan alineados, sin
  excepción que documentar).
- Si aplicás algo por SQL editor, agregalo a la sección C y backfilleá la fila del ledger.
- Si volvés a tocar este archivo, **actualizá la fecha** del encabezado.
