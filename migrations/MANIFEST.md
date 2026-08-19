# MANIFEST de migraciones — mapeo repo ↔ producción

> **Fechado: 2026-08-19** · Proyecto prod `hmuchlzmuqqxcldbzkgc` (ManaosApp) · región `sa-east-1`.

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

**La próxima migración es la 192.** Estado al 2026-08-19 (todo lo de abajo está
aplicado, salvo donde se aclara):

| NN | estado |
|----|--------|
| 182 | `182_pagos_fecha_en_hora_argentina` |
| 183 | `183_cerrar_recorridos_terminados` |
| 184–185 | **libres en `main`, pero reservadas** por la rama de cargos de compra (ver abajo) |
| 186 | `186_quien_cruza_de_sucursal` |
| 187 | `187_la_hija_no_cruza_de_sucursal` |
| 188 | `188_anon_deja_de_ejecutar_rpcs` |
| 189 | `189_auditoria_de_permisos_execute` |
| 190 | `190_guards_de_estado_y_cobranza` |
| 190b | `190b_pagos_forzar_usuario_no_definer` — aplicada sin archivo; el archivo se escribió después, leyendo el catálogo |
| 191 | `191_pagos_forzar_usuario_sin_public` |

> ⚠️ **La rama de cargos de compra (`claude/invoice-cost-calculation-370b62`)
> tiene `183_compra_cargos_prorrateo.sql` y `184_compra_cargos_funciones.sql`, y
> la 183 ya la ocupó `183_cerrar_recorridos_terminados` en `main`.** Esa rama hay
> que renumerarla a 192+ antes de mergear. Es la tercera vez que pasa lo mismo
> (el `167` duplicado, la 183 que nació 182, y ahora ésta): **el número no se
> reserva escribiendo el archivo, se reserva aplicando la migración.** Mientras
> la rama esté abierta el número no es de nadie.

Al elegir número hay que mirar las tres cosas: el ledger, `origin/main` y las
ramas abiertas.

Las **186** y **187** cierran un agujero de RLS preexistente, encontrado de paso
al revisar la 183. Las policies de las tablas hijas validan `sucursal_id =
current_sucursal_id()` sobre la propia fila y **nadie valida que el padre
referenciado sea de esa misma sucursal**; las FK no pasan por RLS, así que una
línea podía colgarse de la compra de la otra sucursal, quedar invisible para su
dueña —la policy de SELECT filtra por el `sucursal_id` de la línea— y moverle el
costo igual. **Medido contra prod el 2026-08-19: 69 pares y 0 filas cruzadas.**
Era latente, no un incidente.

La **186** es sólo lectura: `auditoria_sucursal_cruzada()` y sus helpers
`_pares_sucursal_cruzada()` y `_tenant_col_por_tabla()`, que descubren los pares
hija→padre **del catálogo**, no de una lista. La **187** convierte cada FK de una
columna en compuesta `(columna, tenant) → padre(id, tenant)`, el mismo patrón
estructural que la 183 estrena para `compra_cargos`. No toca ni una fila y aborta
con la lista completa si encuentra alguna cruzada.

Seis cosas que conviene no volver a descubrir:

- **Se eligió FK y no un `EXISTS` en las policies** porque casi toda la escritura
  de esta base entra por RPCs `SECURITY DEFINER`, que saltean RLS por definición:
  una policy no las ve pasar. La FK sí. Refuerza el argumento que cinco de estas
  hijas (`recorrido_cambios`, `promo_acumuladores`, `pedido_item_sustituciones`,
  `comision_reglas`, `metas_preventista`) tengan **sólo policies de SELECT**: el
  default-deny de RLS ya les cierra PostgREST, así que su único camino de
  escritura es justo el que ninguna policy vigila.
- **El tenant no siempre se llama `sucursal_id`.** `transferencias_stock` tiene
  las dos columnas: `tenant_sucursal_id` es el tenant (es la que usa su policy de
  escritura) y `sucursal_id` es **la otra punta del traslado**. Comparar contra la
  segunda daba 4 de 13 filas "cruzadas" que son historia correcta —un traslado
  tiene las dos puntas distintas por definición—; contra la primera dan 0. Si
  alguien las "arreglaba", rompía datos buenos. De ahí `_tenant_col_por_tabla()`.
- **`ON DELETE SET NULL` sobre una FK compuesta anula TODAS las columnas
  referenciantes**, el tenant incluido, que es NOT NULL en 68 de los 69 pares ⇒ el
  borrado del padre pasaría a fallar con un 23502. Hay que escribirlo
  `ON DELETE SET NULL (columna)`, que existe recién en **PostgreSQL 15**. Prod
  corre 17.6, así que el guard de versión de la 187 no va a saltar; queda igual.
- **Que el tenant sea NOT NULL no es un detalle**: la FK es MATCH SIMPLE y se da
  por satisfecha si CUALQUIERA de las columnas referenciantes es NULL. Aflojar ese
  NOT NULL apaga media protección en silencio. El único caso hoy es
  `comision_reglas.sucursal_id`, nullable a propósito (una regla sin sucursal es
  global): el reporte lo marca `parcial` en vez de contarlo como cubierto.
- **Un tenant NULL es "global", no "cruzada".** La primera versión contaba la
  divergencia con `IS DISTINCT FROM` y una regla de comisión global —tenant NULL
  contra un producto de otra sucursal— salía como violación, dejando el preflight
  de la 187 abortando para siempre por una fila legal. El reporte tiene que contar
  **exactamente** lo que la FK rechaza, o los dos dejan de decir lo mismo.
- **El reporte cuenta los pares protegidos, no sólo los rotos.** La primera
  versión sólo miraba FK de una columna y después de la 187 el tablero quedaba
  vacío: un gate que se apaga solo justo cuando empieza a tener algo que vigilar.

**Resultado de aplicarlas (2026-08-19):** 69 pares, **69 protegidos**, 0 sin
proteger, 0 filas cruzadas, 2 parciales (`comision_reglas`). 69 FK compuestas y
19 UNIQUE nuevas; ningún `SET NULL` quedó sin su lista de columnas.
`auditoria_integridad()` siguió en `overall_ok = true` con 0 critical/high, y los
advisors de Supabase no sumaron ningún ERROR. Verificado además en vivo, dentro de
un bloque que se revierte: el INSERT cruzado y el item de traslado mal etiquetado
se rechazan con 23503, y el INSERT coherente sigue entrando.

Y la razón de fondo para que todo salga del catálogo: **el repo predecía 60 pares
y prod tiene 69.** Los 9 que faltaban (`comision_reglas`,
`grupo_precio_escala_minimos`, `metas_preventista`, `productos.categoria_id`,
`productos.marca_id`, `pedido_item_sustituciones.ajuste_producto_id_nuevo`) los
encuentra `pg_constraint` y los habría perdido una lista escrita leyendo
`migrations/`. Es la regla de oro de este archivo, cobrándose una más.

El gate permanente es `scripts/check-sucursal-cruzada.mjs`, un paso más del
workflow `integridad.yml`: una tabla nueva con `sucursal_id` y FK simple sale en
rojo al día siguiente. Ése es el punto — el hallazgo no fue "compra_items está
mal", fue "hay una clase de tabla que está mal y nadie la miraba".

`movimiento_sucursal_items` **no** está en la lista y no es un olvido: no tiene
columna de tenant propia, la resuelve por join con el movimiento. Lo que no se
copia no puede contradecirse. Igual `compra_cargo_repartos` (183), y por eso
`movimientos_sucursal` —que sólo tiene `sucursal_origen_id` y
`sucursal_destino_id`— ni siquiera entra al análisis.

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

---

## Mantenimiento

- Toda migración nueva: archivo `migrations/NNN_descripcion.sql` **y** aplicar por
  `apply_migration` con `name = NNN_descripcion` (así repo y ledger quedan alineados, sin
  excepción que documentar).
- Si aplicás algo por SQL editor, agregalo a la sección C y backfilleá la fila del ledger.
- Si volvés a tocar este archivo, **actualizá la fecha** del encabezado.
