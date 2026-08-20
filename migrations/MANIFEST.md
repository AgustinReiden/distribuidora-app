# MANIFEST de migraciones — mapeo repo ↔ producción

> **Fechado: 2026-08-20** · Proyecto prod `hmuchlzmuqqxcldbzkgc` (ManaosApp) · región `sa-east-1`.

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

> Las tres consolidaciones que están **por encima del snapshot** (`123`, `139`, `165`) viven
> además declaradas en `CONSOLIDACIONES`, adentro de `scripts/check-migrations.mjs`. Si tocás
> una, tocá las dos. El script exime esas filas del ledger; sin la declaración el drift-check
> queda **rojo para siempre** por migraciones perfectamente sanas — que fue exactamente lo que
> pasó en su primera corrida real (9 de 10 hallazgos eran esto).

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

**La próxima migración es la 197** — la última numerada en el repo es
`196_espejo_del_motor_de_compras`.

La **195** le da a la cabecera la columna `compras.bonificaciones`, que es donde se resta
una bonificación general: el `subtotal` es el neto de los RENGLONES y lo clava `COMPRA-A2`
contra `SUM(compra_items.subtotal)`, así que un cargo gravado que no es un renglón de
producto no tenía dónde ir y dejaba `compras.total` por encima del papel.

La **196** es el **espejo del motor**: `espejo_motor_compras(jsonb, integer)` recibe un lote
de casos con la salida que dio el motor de TypeScript, corre el de SQL sobre la MISMA entrada
y devuelve las celdas donde no coinciden, comparando con `IS DISTINCT FROM` sobre `numeric`
—así `500` y `500.00` son el mismo número y un centavo no—. Que sólo una de las dos LANCE
también cuenta como divergencia. La consume `scripts/espejo-motor-compras.mjs` desde el gate
de integridad, que es el único lugar con credenciales de servicio. Es la única función de
este bloque que **no** se le da a `authenticated`: no la llama ni el front ni el bot.

La **193** es el motor de cálculo de esos cargos, en SQL, y va entero adentro de un solo
`BEGIN/COMMIT` porque el motor a medias no sirve para nada. Trae tres cosas:
`prorratear_cargo(numeric, jsonb)` reparte UN cargo sobre un vector `{id_de_línea: peso}` y
manda el residuo del redondeo a la línea de mayor peso, para que la suma dé el monto EXACTO;
`costo_real_unitario` gana un 4º argumento aditivo para los cargos —y se **dropea** la de 3
en vez de dejar las dos, porque dos sobrecargas con aridades superpuestas dan `PGRST203` en
runtime, invisible para `tsc` y para los tests (la trampa de la mig 176)—; y
`calcular_costos_compra(jsonb, jsonb, jsonb)` arma las tres bases (IVA de factura, costo,
impuesto interno), ajusta el II al declarado por alícuota y devuelve los unitarios por línea
más los totales. Es **espejo exacto** de `src/utils/prorrateoCompra.ts`: si cambiás una,
cambiá la otra. Los tres llamadores de `costo_real_unitario` se parchean en la MISMA
transacción leyendo su cuerpo del **catálogo vivo** con `pg_get_functiondef` —nunca copiando
el del archivo, que puede estar viejo— y exigiendo que el ancla aparezca exactamente una vez.
Hoy los tres pasan `0`, así que **ningún costo se mueve**: los cargos de verdad entran en la
194. **Aplicada a producción el 2026-08-19**, igual que la 192 y la 194.

Verificada contra la factura testigo `A0005-00461415` (21 renglones, 13,3 M) con un ensayo
sobre prod que termina en `RAISE EXCEPTION` para garantizar el rollback: **126 celdas
comparadas** (21 líneas × 6 campos) con `IS DISTINCT FROM` sobre `numeric` contra la salida
del TS, **0 divergencias**, y el factor de ajuste del impuesto interno da **1,000000 en las
dos alícuotas** (8,6956 y 4,1667) — que es el corazón del rediseño: el Excel del gerente
necesita un 1,0496 puesto a mano, y modelando `afecta_base_ii` cuadra solo.

La **192** es el esqueleto de datos de los cargos de compra: `compra_cargos` (flete,
pallets, separadores, bonificaciones; monto negativo = bonificación) y
`compra_cargo_repartos` (el vector de pesos, donde un peso 0 excluye la línea y por
eso el "alcance" no existe como concepto aparte), más el snapshot
`compra_items.cargos_unitarios`. Todavía **sin funciones**: el motor vive por ahora
sólo en `src/utils/prorrateoCompra.ts` y las RPC llegan en las migraciones
siguientes: la **193** trae el motor de cálculo y la **194** las RPCs y el check de
integridad. Van en archivos separados a propósito — appendearlas a la 192 las dejaría
fuera de su `BEGIN/COMMIT` y un fallo a mitad daría tablas creadas con RPCs a medias.
**Aplicada a producción el 2026-08-19**, junto con la 193 y la 194: las tres se aplicaron
seguidas y verificando entre una y otra (firmas, gate de integridad y que ningún costo ya
guardado se moviera).

**El rollback deja de ser gratis apenas haya cargos.** Mientras no exista ninguno,
dropear las dos tablas y la columna devuelve el costo exacto (Σ cargos = 0). En cuanto
los cargos entren al `costo_real_unitario` y al costo promedio, dropearlas borra CUÁLES
fueron los cargos pero no los saca de los costos ya calculados: quedan costos que los
incluyen sin registro de su origen. Desde ahí no es reversible sino
reversible-con-recálculo, y hay que recomputar antes de dropear. El plan de rollback
está escrito al pie del archivo.

Tres decisiones de esa 192 que no son obvias leyendo el DDL. Las policies de
`compra_cargo_repartos` son **cuatro**, no una `FOR ALL`: un reparto es la plata (mueve
el costo de los productos), así que replica el permiso de `mt_compra_items_*` —depósito
lee y carga, admin corrige y borra—; una `FOR ALL` que sólo mirara la sucursal le habría
dado escritura a preventistas y transportistas. Y `compra_cargo_repartos` lleva
`compra_id` **denormalizado** para poder atar sus dos FK como compuestas contra
`compra_cargos(id, compra_id)` y `compra_items(id, compra_id)`: sin eso nada impedía que
un reparto apuntara a la línea de otra compra o de otra sucursal, y no queremos que esa
garantía dependa de que la RPC se porte bien. De ahí los `UNIQUE (id, compra_id)` en las
dos tablas padre, redundantes por construcción pero necesarios como destino de la FK.

Y el mismo truco un nivel más arriba: `compra_cargos` referencia
`compras(id, sucursal_id)`, no `compras(id)`. Cierra un hueco concreto — `es_admin()` es
global y `current_sucursal_id()` sale del header, así que un admin parado en la sucursal
A podía colgar un cargo con `sucursal_id = A` sobre una compra de B; la policy de INSERT
chequea la fila y pasa, y una FK simple no mira la sucursal. Lo peor era que el cargo
quedaba **invisible** para los usuarios de B, porque la policy de SELECT filtra por la
sucursal del cargo. El hueco equivalente en `compra_items` (nada ata su `sucursal_id` al
de `compras`) es preexistente y queda para un trabajo aparte.

La **182** (`182_pagos_fecha_en_hora_argentina`) no es de esta tanda: entró por `main`
mientras la rama de compras estaba abierta. Cambia el default de `pagos.fecha` a hora
argentina porque la base corre en UTC y entre las 21:00 y las 24:00 ART `CURRENT_DATE`
fechaba el cobro al día siguiente. 0 casos en prod; no reescribe filas.

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

**Antes de elegir el número de una migración nueva hay que mirar TRES cosas**, y ninguna
alcanza sola:

1. **el ledger** — es la fuente de verdad de lo aplicado, pero no siempre lleva el prefijo
   `NNN_`, así que por sí solo no dice qué números están gastados;
2. **`ls migrations/` sobre `origin/main`** — tapa el agujero anterior, pero sólo ve lo
   mergeado;
3. **las ramas abiertas** — que es donde la numeración choca de verdad, porque dos ramas
   paralelas eligen el mismo número el mismo día y ninguna se entera hasta el merge. Ya pasó
   con el `167` duplicado (sección A) y volvió a pasar con la 183.

Barrido rápido de lo que se están comiendo las ramas abiertas:

```bash
for b in $(git branch -a --format='%(refname:short)'); do
  git ls-tree --name-only "$b" migrations/ | grep -oE '^migrations/[0-9]+' | sort -u |
    tail -3 | sed "s|^|$b :: |"
done | sort -u
```

Y si mergeaste `main` en el medio, volvé a mirar las tres — los números que estaban libres
pueden haberse ocupado.

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

**Y `ls migrations/` tampoco alcanza solo: hay que preguntarle al ledger.** La tanda de
cargos de compra nació como 182 y terminó siendo 183. El worktree venía de un commit de 6
atrás, y desde adentro `ls migrations/` mostraba la 181 como última: la 182 ya existía en
`origin/main` y estaba aplicada en prod desde hacía un día, pero el árbol local no la veía.
Un worktree o una rama larga esconden exactamente este choque, y no lo detecta ningún test
—dos migraciones con el mismo número no rompen nada hasta que hay que aplicarlas—.

**Y le volvió a pasar a la misma tanda, DOS veces más, así que la regla de arriba no era
suficiente.** Con el motor ya escrito como 184, otras tres ramas aplicaron
`183_cerrar_recorridos_terminados` y las 186–189; el ledger llegó a 189 y las tres pasaron a
**190** (tablas), **191** (funciones) y **192** (RPCs). Y ahí se las volvieron a comer:
antes de aplicarlas entraron `190_guards_de_estado_y_cobranza`,
`190b_pagos_forzar_usuario_no_definer` y `191_pagos_forzar_usuario_sin_public`, así que
terminaron en **192** (tablas), **193** (funciones) y **194** (RPCs), que es donde están
aplicadas. A la tercera la regla se siguió al pie: se reconfirmó contra el ledger en el
minuto anterior a aplicar. Son **TRES** las fuentes que pueden ocupar un número —
`origin/main`, el ledger de prod y **las ramas abiertas de los demás**— y a la tercera no se
la puede consultar de forma confiable. Por eso la regla ya no es a quién preguntarle sino
**cuándo**: elegí el número **al final, justo antes de aplicar**. Numerar al empezar es
reservar algo que no se puede reservar, y el costo de renumerar después no es `git mv` — es
la prosa, que ningún reemplazo mecánico agarra.

---

## Mantenimiento

- Toda migración nueva: archivo `migrations/NNN_descripcion.sql` **y** aplicar por
  `apply_migration` con `name = NNN_descripcion` (así repo y ledger quedan alineados, sin
  excepción que documentar).
- Si aplicás algo por SQL editor, agregalo a la sección C y backfilleá la fila del ledger.
- Si volvés a tocar este archivo, **actualizá la fecha** del encabezado.
