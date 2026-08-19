# MANIFEST de migraciones — mapeo repo ↔ producción

> **Fechado: 2026-08-08** · Proyecto prod `hmuchlzmuqqxcldbzkgc` (ManaosApp) · región `sa-east-1`.

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
- **Permisos:** `node scripts/check-permisos.mjs` (mismos env). Falla si alguna función de
  `public` quedó ejecutable con la anon key. No es drift de migraciones, pero corre en el mismo
  workflow y detecta lo mismo que la `188` cerró. Ver `README.md § Permisos`.

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
| 139 | `139_movimientos_stock_preventivo.sql`, `139_guarda_precio_venta.sql` | `movimientos_stock_preventivo_*` (07-27 15:40, 5 filas, ver D) → `139_guarda_precio_venta` (07-27 17:22) |
| 140 | `140_clientes_horario_canonico.sql`, `140_detalle_rendicion_cobrado_por.sql` | `140_clientes_horario_canonico` (07-27 18:27) → `detalle_rendicion_cobrado_por` (07-27 19:48, entre `144` y `145`) |
| 167 | `167_pagos_idempotencia_client_request_id.sql`, `167_baja_de_total_reduce_el_pago.sql` | `167_pagos_idempotencia_client_request_id` (08-06 02:15) → `167_baja_de_total_reduce_el_pago` (08-06 04:08) — dos ramas en paralelo tomaron el mismo número el mismo día |

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
| `139_movimientos_stock_preventivo.sql` | `movimientos_stock_preventivo_ddl` + `_crear` + `_aceptar` + `_denegar_cancelar` + `_editar` (5 filas, sin prefijo) |
| `165_saldo_a_favor_no_queda_atrapado.sql` | `165_…` (guard + helpers + trigger) + `165_…_rpcs_fifo` (las 2 RPCs FIFO) — aplicado en 2 tandas por tamaño |
| (bot 014–020) | hotfix `020_bot_fix_pgcrypto_schema` plegado en la tanda, sin archivo propio |

**Cadena `reporte_gerencial`** (reescrita ~9 veces por `CREATE OR REPLACE`): el repo versiona
los hitos (`095`, `097` grants, `098`, `103`, `106`, `107`, `110`). Los intermedios del ledger
`reporte_gerencial_restringir_por_sucursal_asignada` y `reporte_gerencial_desglose_bonif_mermas`
**no tienen archivo dedicado**: su lógica (p.ej. el gate `v_asignadas`) **sobrevive en el body
vivo**, que equivale al último archivo (`110`: cobranza desde `pagos`, parciales por monto,
compras sin canceladas, split de mermas, `bonif_promos`).

---

## Numeración: la tanda del 2026-07-27 arranca en 139

Las migraciones de rendiciones ocupan **133–138** en el repo, pero en el ledger quedaron
**sin prefijo numérico** (`fix_fecha_entrega_desde_historial`, `detalle_rendicion_formas_pago`,
`pedidos_ctacte_pendientes`). Por eso, al consultar solo el ledger, los números 136–138
parecían libres y la tanda de ruteo/rechazos/categorías se numeró ahí, colisionando con
los archivos de rendiciones.

Se corrigió renumerando esa tanda a **139–147** (archivos y ledger), preservando el orden
cronológico.

**La renumeración dejó una colisión residual.** Al mergear `main` después de renumerar
entraron dos archivos que ya ocupaban 139 y 140 en otra rama:

| `NN` | de esta tanda | de `main` |
|------|---------------|-----------|
| 139 | `139_guarda_precio_venta.sql` | `139_movimientos_stock_preventivo.sql` |
| 140 | `140_clientes_horario_canonico.sql` | `140_detalle_rendicion_cobrado_por.sql` |

Las cuatro están aplicadas en prod con `name` distinto en el ledger, así que **no hay riesgo
funcional** y no se renombran los archivos: renombrarlos los desalinearía del ledger. El orden
real lo da `version` y está en la sección A: en los dos casos el archivo de `main` quedó
cronológicamente **fuera** del bloque 139–147 (uno antes, otro entre la 144 y la 145).

**La próxima migración es la 182** — la última numerada en el repo es
`181_guards_de_estado_y_permisos` (aplicada).

La **181** cierra la otra mitad de la auditoría adversarial: las invariantes que
vivían en el front. Trigger `pedidos_proteger_columnas` (el chofer sólo escribe
`estado`/`fecha_entrega`/`updated_at`; el resto de los no-admin no toca plata ni
identidad), guards de estado en las tres RPCs masivas, `FOR UPDATE` en el cobro
masivo, guards de cancelado y de ruta-en-curso en `actualizar_pedido_items`, y
trigger `trg_pagos_guard_anulacion` para el DELETE de pagos sobre caja cerrada.
No toca filas.

**Los dos triggers nuevos NO son `SECURITY DEFINER`, y es a propósito.** Un
trigger dispara aunque la función que escribe sea SECURITY DEFINER —eso saltea
RLS, no triggers— así que la exención se hace con `current_user <> 'authenticated'`,
que dentro de una SECURITY DEFINER es el dueño. Si alguien los redefine con
SECURITY DEFINER, `current_user` pasa a ser siempre el dueño y **el guard deja de
filtrar sin fallar**. Mismo patrón que `clientes_proteger_columnas_preventista`
(mig 080). El orden alfabético también importa: `pedidos_proteger_columnas` tiene
que correr antes que `trigger_actualizar_estado_pago`.

Las **174**
(`174_salvedad_regalos_y_minimo_de_venta`), **175**, **176**, **177**, **178**, **179** y
**180** mapean 1:1 con el ledger.

La **180** es de la tanda de la auditoría adversarial de pedidos/entregas/pagos. Saca el
filtro `r.fecha = CURRENT_DATE` de `actualizar_recorrido_entrega()` —que la 173 había dejado
a propósito y resultó ser el 79% del volumen—, agrega `recalcular_recorrido(id)` (idempotente,
invocable: **no existía ninguna forma de reparar un contador desalineado**), impide que
`aplicar_orden_ruta` devuelva a `'asignado'` un pedido ya entregado o cancelado, y hace que
`cancelar_pedido_con_stock` baje la parada del camión. **Sí toca filas**: realineó 1.455
paradas, borró 118 de pedidos cancelados y recalculó los 86 recorridos. Deja los checks
`RUTA-A/B/C` en `auditoria_integridad()`.

Ojo con dos cosas que se descubrieron al aplicarla: `CURRENT_DATE` se evalúa en **UTC**
(`TimeZone = 'UTC'`), así que cualquier comparación de fecha en la base se corre 3 horas y
después de las 21:00 ART ya es "mañana"; y el gate diario de integridad **ya venía en rojo**
por `CC-PAGOS-CANCEL` (pago 2944 sobre el pedido cancelado 3262, del 05/07), así que no estaba
protegiendo nada. Eso se aborda en el PR de guards de estado, no acá.

La **179** agrega dos funciones de lectura para el panel "Mis entregas" del preventista
(`jornadas_preventista` y `jornada_preventista_detalle`). No toca ninguna fila. Deja escrita
una decisión de negocio que conviene no invertir: **la lista de motivos de cancelación
administrativos es NEGRA, no blanca**, así que un motivo nuevo cuenta como rechazo y se ve.
Al revés se escondería solo, que es exactamente la falla que el panel vino a arreglar.
De paso documenta que `marcar_no_entregado` (mig 144) está prácticamente sin uso —2 filas en
toda la base—: el pedido que no se entrega se cancela con motivo tipificado o se queda
colgado en `asignado`, así que **`recorrido_pedidos` no sirve como fuente del "no entregado"**
(y encima su RLS es admin-o-chofer, invisible para el preventista).

La **176** deja una regla que conviene no volver a romper: **dos sobrecargas cuyas aridades
se superponen por defaults hacen que PostgREST no pueda elegir** y devuelva HTTP 300
`PGRST203`, sin que lo vea ni `tsc` ni los tests. Antes de dejar una firma vieja como
wrapper, contar los obligatorios de cada una; si los rangos `[obligatorios, total]` se
tocan, hay que dropear la vieja en vez de conservarla. Consulta para auditarlo en
`migrations/176_sobrecargas_ambiguas.sql`.

Las **148–166** (origen del precio, reglas de
comisión, `place_id`, horarios masivos, barridas, roles extra por sucursal, horario obligatorio
al cargar pedido, marcas y objetivos por preventista, saldo a favor que no queda atrapado)
mapean **1:1** con el ledger, así que no agregan ninguna excepción a las tablas de arriba.
Ojo con el **167 duplicado** (ver sección A): al elegir número no alcanza con mirar el más
alto, hay que confirmar que no esté tomado por otra rama.

La **169** elimina `grupo_precio_productos.cantidad_minima_pedido`. Tiene una dependencia de
orden que no se ve en el SQL: `supabase/functions/_shared/pricing/index.ts` seleccionaba esa
columna por nombre, y PostgREST devuelve 400 si no existe. **Desplegar las edge functions
antes de aplicarla**, o el bot deja de tomar pedidos.

Las **170**, **171** y **172** solo agregan funciones: no modifican ni una fila. Todo su SQL
corre adentro de la RPC, o sea únicamente cuando el usuario dispara la acción desde la UI.

La **172** agrega `cambiar_transportista_recorrido()`, que reasigna una ruta ya armada a otro
chofer sin rearmarla. Hace falta porque para `aplicar_orden_ruta` el transportista es parte de
la **identidad** de la ruta (la busca por `transportista_id + fecha + estado + sucursal_id`),
así que elegir otro chofer y volver a armar no la mueve: crea una segunda y deja la original
viva con sus pedidos en `asignado`. Rechaza si la ruta ya tiene entregas hechas (partiría la
rendición entre dos personas) o si el destino ya tiene ruta ese día (`uq_recorrido_vigente`).

La **170** agrega `consolidar_condiciones()`, que fusiona condiciones mayoristas duplicadas.
Mueve las escalas conservando su `id` y solo repunta `pedido_items.grupo_precio_escala_id`
cuando hay dos escalas equivalentes, para no perder el rastro del descuento por volumen.
Rechaza la fusión si algún precio cambiaría. La dispara el usuario desde la pestaña de
condiciones, caso por caso; no corre sola.

La **173** es la primera de esta tanda que **sí toca filas**: arregla
`actualizar_recorrido_entrega()` y repara la ruta 82. El trigger no era `SECURITY DEFINER`,
así que sus UPDATE pasaban por la RLS del chofer y `mt_recorrido_pedidos_update` es admin-only:
el UPDATE de `recorrido_pedidos` se descartaba **en silencio** (RLS filtra, no falla) mientras
el de `recorridos` sí entraba. Resultado: contador de la ruta avanzando y paradas en
'pendiente', para todo chofer no admin desde siempre (1.331 paradas históricas). Además los
contadores pasan de sumar deltas a recalcularse desde las paradas, y el trigger ahora escucha
`monto_pagado`: antes `total_cobrado` se congelaba en el valor del instante en que se marcaba
entregado, que casi siempre era 0 porque el cobro entra después.

La **167** renombra 4 RPCs de pago a `<nombre>_impl` y las deja detrás de un wrapper
idempotente del mismo nombre. Es a propósito: `migrations/` no es 1:1 con prod y esas RPCs ya
habían driftado (ver la nota de la 100), así que el cuerpo real no se reescribe, se envuelve.
Al leer el catálogo, la lógica de negocio de esas 4 vive en la función `_impl`.

**Antes de elegir el número de una migración nueva, mirar `ls migrations/` además del
ledger**: el ledger no siempre lleva el prefijo, así que por sí solo no alcanza. Y si mergeaste
`main` en el medio, volvé a mirarlo — los números que estaban libres pueden haberse ocupado.

### E. La 188/189 quedó intercalada con la 186/187 (2026-08-19)

El ledger tiene, por `version`, este orden:

| hora (UTC) | ledger | rama |
| --- | --- | --- |
| 16:56:50 | `186_quien_cruza_de_sucursal` | aislamiento por sucursal |
| 16:57:07 | `188_anon_deja_de_ejecutar_rpcs` | permisos EXECUTE |
| 16:58:04 | `189_auditoria_de_permisos_execute` | permisos EXECUTE |
| 16:58:07 | `187_la_hija_no_cruza_de_sucursal` | aislamiento por sucursal |

O sea que **el número de archivo no refleja el orden de aplicación**: dos ramas aplicaron a
prod con minutos de diferencia. No rompe nada (el ledger ordena por `version`, y ninguna de
las cuatro depende de otra), pero si mirás sólo los números vas a suponer un orden que no fue.

Vale la pena por lo que dejó demostrado: la **187 se aplicó después del barrido de la 188** y
aun así no quedó nada abierto a `anon`, porque no creó funciones. Si hubiera creado una, habría
nacido con `=X/postgres` (PUBLIC) y el gate `scripts/check-permisos.mjs` la habría marcado al
día siguiente. Ese es exactamente el escenario para el que existe el gate: el paso 0 de la 188
saca a `anon` del default privilege, pero **a PUBLIC no lo puede sacar** (medido, ver la
migración), así que toda función nueva sigue naciendo con PUBLIC y **cada migración tiene que
revocarlo**. Ver `README.md § Permisos`.

---

## Mantenimiento

- Toda migración nueva: archivo `migrations/NNN_descripcion.sql` **y** aplicar por
  `apply_migration` con `name = NNN_descripcion` (así repo y ledger quedan alineados, sin
  excepción que documentar).
- Si aplicás algo por SQL editor, agregalo a la sección C y backfilleá la fila del ledger.
- Si volvés a tocar este archivo, **actualizá la fecha** del encabezado.
