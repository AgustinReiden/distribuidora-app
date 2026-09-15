# MANIFEST de migraciones — mapeo repo ↔ producción

> **Fechado: 2026-09-15** · Proyecto prod `hmuchlzmuqqxcldbzkgc` (ManaosApp) · región `sa-east-1`.

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

**La próxima migración es la 242.** El ledger de prod llega hasta
`241_la_venta_del_vendedor_tiene_una_sola_definicion`.
Confirmá el número contra las tres fuentes justo antes de aplicar: el número se
reserva **aplicando**, no escribiendo el archivo.

(Esta línea decía 206 hasta el 2026-09-08, con las 206–209 ya aplicadas: la
numeración del repo avanzó cuatro veces sin que nadie la corrigiera. Volvió a pasar el
2026-09-09: decía 215 con la 215 y la 216 ya aplicadas y sus archivos en `main`, así que
quien fue a escribir la 217 leyó "escribí la 215" y habría pisado dos migraciones vivas.
Y otra vez el mismo día: la 218 se aplicó desde otra sesión **mientras** se escribía la que
terminó siendo la 219 — que salió con el número correcto sólo porque se confirmó contra el
ledger en el último momento, no porque esta línea estuviera al día. Moraleja: esta línea es
una ayuda, el ledger es la verdad. Si aplicás una migración, actualizá también esta línea.
Y pasó de nuevo el 2026-09-10: decía 220 con la 220, la 221 y la 222 ya en el ledger — la
222 desde otra rama, sin archivo en el repo en ese momento. Quien fue a escribir las de
vencimientos leyó "escribí la 220" y habría pisado tres migraciones vivas.
Y de nuevo el 2026-09-13: decía 226 con la 226 y la 227 ya aplicadas y sus archivos en
`main`. Van cinco veces.
Y una sexta vez, de otra forma, con la 239: el archivo se escribió el 2026-09-13 como
`228_...` confirmando el ledger (iba por la 227) y se **mergeó sin aplicar**. Dos días
después el 228 ya era de otra migración y la cadena iba por la 238, así que hubo que
renumerarlo al aplicarlo. Moraleja adicional: un archivo que espera en `main` no reserva
nada. Si no lo vas a aplicar ahora, no le pongas número todavía.
Última actualización: 241, el 2026-09-15.)

### 223–225 · Vencimientos por lote

Las tres van juntas y en ese orden: la **223** pone el modelo (`producto_lotes`, el motor de
consumo y el trigger sobre `productos`), la **224** las cinco operaciones (los lotes de una
compra, etiquetar la bolsa a mano, corregir un contador, dar de baja y el reporte del panel),
y la **225** los invariantes `LOTE-A/B/C` de `auditoria_integridad()`.

Dos decisiones que no se ven leyendo el SQL:

- **El consumo se engancha en UN trigger sobre `productos`, no en las ~20 RPCs que mueven
  stock.** Todas pasan por `UPDATE productos SET stock` y ya hay un trigger hermano
  (`trg_stock_historico`, mig 038) que lee `current_setting('app.stock_origen')`. El trigger
  nuevo usa el mismo canal: por eso cubre de una sola vez pedidos, bot, mermas —que ni
  siquiera pasan por una RPC—, movimientos entre sucursales y control de stock.
- **Los lotes de una compra NO se escriben dentro de `registrar_compra_completa`.** Esa
  función, `actualizar_compra_items` y `anular_compra_atomica` son las tres más parcheadas del
  repo (128, 177, 194, 195, todas por ancla sobre el cuerpo vivo). `sincronizar_lotes_compra`
  es idempotente y la llama el cliente después de guardar; la anulación se detecta con un
  trigger sobre `compras.estado`. Si esa segunda llamada falla, la compra queda bien y los
  vencimientos sin cargar — el mismo estado que si el usuario los hubiera dejado en blanco.

La bolsa "sin vencimiento" (`productos.stock` − Σ `cantidad_restante`) **no es una fila**: es
lo que hace que la feature no necesite backfill ni inventario inicial. El invariante `LOTE-A`
es esa resta escrita como check.

Las 197–202 no tienen prosa acá (quedaron sin documentar en su momento). Las 203, 204,
205, 212, 213 y 214 sí:

- **203** `bot_buscar_cliente` pasa a filtrar `activo = TRUE`. Era el único camino
  del bot que no lo hacía, y es la puerta de entrada: un cliente dado de baja
  seguía siendo encontrable desde Telegram aunque en la web ya no apareciera.
  `CREATE OR REPLACE` puro: **no toca ninguna fila**.
- **204** crea `politicas_comerciales` (una fila por sucursal) con
  `monto_minimo_pedido`, más `monto_minimo_pedido()` y
  `actualizar_monto_minimo_pedido()`. **Sí toca filas**: inserta una por sucursal
  (3 al aplicarla), todas con el mínimo en 0 — o sea que aplicarla no cambia
  ningún comportamiento hasta que alguien cargue un número.
- **205** hace cumplir ese mínimo. Parchea `crear_pedido_completo` y
  `crear_pedido_completo_bot` leyendo del catálogo vivo, y le prende el escape
  hatch `app.omitir_minimo_pedido` a `cambiar_cliente_pedido`.
  **El mínimo se valida SOLO al crear**, nunca como CHECK sobre `pedidos.total`:
  cancelar un pedido lo pone en 0 (mig 175) y el invariante `VENTA-I` exige que
  así sea (mig 105), así que un CHECK haría imposible cancelar.
  Sólo redefine funciones: **no toca ninguna fila**. El rollback está al pie del
  archivo y es gratis mientras los mínimos sigan en 0; si alguien ya cargó uno,
  revertirla apaga la validación sin avisar.

Las 206–209 tampoco tienen prosa acá. Las 210 y 211 sí:

- **210** crea `reporte_stock_red(bigint)`: stock, costo y precio de **todas** las
  sucursales activas, solo lectura, gate de admin por rol crudo. Es el único RPC que
  **no** intersecta contra `usuario_sucursales` — a propósito: 5 de los 7 admins están
  asignados a una sola sucursal y no veían la otra por ningún lado. No se relajó
  `mt_productos_select` porque `fetchProductos` no filtra por sucursal en ningún call
  site y la policy es sobre la fila entera. Nombre nuevo en vez de un parámetro en la
  131, para no dejar dos sobrecargas ambiguas (PGRST203, ver mig 176).
  **No toca ninguna fila.**
- **211** parchea `aceptar_movimiento_sucursal` para que el producto que se CREA en el
  destino se lleve `costo_real`, `costo_promedio` y `ultimo_tipo_compra` del origen.
  Sin eso nacía con los tres en NULL y la cascada de costo caía al último escalón, que
  tiene semántica FC (neto + impuestos internos): con un origen ZZ eso suma dos veces
  el impuesto interno. El parche es **quirúrgico sobre la definición viva** (mismo
  patrón que la 177, que ya la había parcheado in situ: un `CREATE OR REPLACE` armado
  desde `migrations/139` revertiría `condicion_iva` en silencio).
  **No toca ninguna fila** — no backfillea los 5 productos que ya quedaron sin costo
  (el costo del origen HOY no es el de aquellas unidades y el CPP es forward-only).
  La regla `GREATEST(origen, destino)` del camino "match con un producto existente"
  queda **igual**: es una decisión comercial de la 076, no un olvido.
- **212** congela por ítem el factor de fracción de las bonificaciones en
  `pedido_items.unidades_por_bloque_al_crear` + `origen_unidades_por_bloque`, y parchea
  `reporte_gerencial` para leer de ahí vía `factor_bonificacion(...)`. Un **solo** número
  colapsa gate y divisor (1 = no fraccionar): congelar solo el divisor dejaba abierto que
  un flip de `regalo_mueve_stock` en el modal multiplicara por 6 o 12 el costo de todas las
  bonificaciones históricas de esa promo. El histórico **se reconstruyó**, no se congeló con
  el valor de hoy porque sí: se midió desde `promo_ajustes` (toda fila con
  `|unidades_ajustadas| = 1` fuerza `bloques = stock_por_bloque = 1`, así que
  `|usos_ajustados|` **es** el factor vivo de ese instante) y las 5 promos que fraccionan
  dan `min = max = valor vivo` en las 651 mediciones exactas. **Sí toca filas**: 1.243 de
  1.313 bonificaciones. Las 70 restantes son anteriores a la primera medición de su promo y
  quedan en NULL a propósito — caen al valor vivo, igual que antes. El parche es sobre la
  definición **viva** (la 130 fue redefinida 10 veces). Verificado corriendo el reporte de
  los 6 meses × 4 sucursales antes y después: **cero diferencias**, que es lo que tiene que
  pasar si el factor nunca cambió. Rollback al pie del archivo.
- **213** le cierra el ACL a `completar_unidades_por_bloque_item()`, la función del trigger
  de la 212, que había quedado ejecutable por `anon`. La 212 le puso el `REVOKE` al helper
  `factor_bonificacion` pero no a ésta, razonando que la regla de la casa habla de funciones
  `SECURITY DEFINER` y ésta es invoker. **Ese razonamiento es equivocado**: el gate
  `scripts/check-permisos.mjs` falla ante *cualquier* función de `public` alcanzable con la
  anon key. Una función de trigger no necesita `EXECUTE` para nadie —la invoca el executor
  como parte del INSERT, no el caller—, así que queda con `postgres` + `service_role`, igual
  que `completar_origen_precio_item` (148) y `validar_precio_item_pedido`. Verificado que el
  trigger sigue disparando después del revoke. **No toca ninguna fila.**
- **214** agrega el tercer estado de asignación de clientes: `clientes.reservado_admin`
  ("Solo administradores"). No es "invisible para todos menos admin" — admin, encargado,
  transportista y depósito lo ven entero, y el preventista que **ya le vendió** también,
  porque si no el embed `cliente:clientes(*)` devuelve NULL y los `!inner` de
  `usePedidosQuery` / `usePedidoStatsQuery` le hacen **desaparecer** los pedidos viejos de
  la lista y del count, en silencio. Lo que cierra es que un preventista lo tome como
  cliente nuevo. No se pudo modelar como ausencia de asignación porque "sin preventista
  asignado" ya significa *visible para todos* (mig 028), ni dentro de
  `cliente_preventistas` porque `cp_insert` (002) deja auto-asignarse a cualquiera. Es
  **excluyente** con las asignaciones, enforceado en las dos direcciones. Toca las tres
  policies de `clientes` (select, update e insert — la de update es independiente de la de
  select y por eso también la lleva), 4 triggers nuevos, y repite el filtro a mano en
  `bot_buscar_cliente`, `bot_historico_pedidos_cliente`, `bot_productos_recurrentes_cliente`
  y `registrar_visita_cliente` porque el bot corre con `service_role` y bypassea la RLS
  (misma familia que la 203). `bot_mis_clientes` y `bot_sugerir_visitas_rfm` no hacen falta:
  hacen INNER JOIN contra `cliente_preventistas`. El trigger sobre `pedidos` cubre
  `crear_pedido_completo` y `crear_pedido_completo_bot` sin tocarles el cuerpo vivo (la 205
  le inyecta código al primero). **No toca ninguna fila**: la columna nace en `false` y todo
  el predicado nuevo es una tautología mientras nadie marque a nadie. Verificado contra prod
  con un usuario de cada rol.

- **217** hace que el detector de duplicados por ubicación de `createCliente` vea por
  encima de la RLS (issue #543). Corría **como el usuario**, o sea que a un preventista le
  ocultaba los clientes de OTRO preventista: la consulta volvía vacía, no avisaba nada y
  se creaba un CLON. Es la misma forma de fail-open que la 214 documenta en
  `cliente_preventistas_no_reservado` —un guard que consulta bajo la policy que le tapa la
  fila no falla, **aprueba**—, y por eso `existe_cliente_en_ubicacion` es SECURITY DEFINER.
  Verificado impersonando: el cliente 22 existe en esas coordenadas y la consulta del
  detector con el JWT de Osvaldo devolvía 0 filas. Importó más con el tiempo sin que nadie
  tocara el código: cuando se escribió el detector la base era casi toda huérfanos (401 vs
  26, mig 028) y hoy es al revés (598 asignados vs 124). **Devuelve un booleano**, nunca la
  fila: si devolviera el nombre estaríamos filtrando por la ventana lo que la policy tapa
  por la puerta, y el front por eso muestra un mensaje sin identidad y avisa a admin y
  encargado por `_notificar_sucursal_roles` (con dedupe de 24 h, porque el alta se
  reintenta). El front conserva su consulta con RLS y llama a la RPC **solo si aquella no
  encontró nada**: así el caso visible no cambia en nada y la función nunca tiene que
  contestar "¿este usuario puede verlo?", que obligaría a copiar `mt_clientes_select` aden-
  tro y a mantener las dos sincronizadas. Mira a los **inactivos** a propósito (migs
  199/200). Un `reservado_admin` (214) cae en la rama de "no lo ve": bloquea el clon sin
  delatar que está reservado. **El detector por RAZÓN SOCIAL se deja ciego a propósito**:
  ahí el mismo booleano sería fácil de sondear probando nombres, así que el clon por nombre
  contra un cliente ajeno se sigue pudiendo crear —decisión tomada, no olvido—.

- **219** cierra el forjado de la atribución en el ALTA de pedidos (issue #549).
  `mt_pedidos_insert` es `(es_preventista() AND sucursal_id = current_sucursal_id())` y **no
  mira `usuario_id`**, así que por PostgREST se podía insertar un pedido atribuido a
  cualquiera —y como `es_preventista()` incluye admin y encargado (trampa 4), el predicado
  no acotaba casi nada—. Importa porque `calcular_comisiones` agrupa por `pedidos.usuario_id`:
  una atribución forjada mueve plata de una liquidación a otra. **El UPDATE ya estaba
  tapado** por `pedidos_proteger_columnas`, que bloquea `usuario_id` y otras para todo el que
  no sea encargado ni admin; faltaba lo mismo en el alta, y esa asimetría INSERT/UPDATE fue
  justamente lo que dejó pasar el agujero. Por eso el guard va **adentro de esa misma
  función** —que ahora corre `BEFORE INSERT OR UPDATE`— y no en una nueva: partir la regla en
  dos lugares reproduce el problema. El bloque nuevo va DESPUÉS del `RETURN NEW` de
  `es_encargado_o_admin()`, así el flujo real de "admin carga a nombre de un preventista"
  (55 de los 5.628 pedidos del último año) queda cubierto sin escribir una línea, y ANTES de
  todo lo que usa `OLD`. **La identidad sale de `auth.uid()`, no del COALESCE de la 216**: acá
  el bloque solo se alcanza con `current_user = 'authenticated'`, donde `auth.uid()` nunca es
  NULL, y el fallback a `NEW.creado_por` sería **fail-open** porque en un INSERT directo lo
  manda el atacante. La función **sigue siendo INVOKER** a propósito: adentro de una SECURITY
  DEFINER `current_user` es el dueño, su primera línea daría siempre true y toda la
  protección de columnas se apagaría en silencio (hay un check en la migración que lo
  impide). Los RPC y el bot **no pasan por acá** —son DEFINER, salen por esa primera
  línea— y ya validan lo mismo por su cuenta. Verificado impersonando contra prod los 7
  casos, incluidos los dos RPC punta a punta y el camino del bot. **No cierra** el INSERT
  directo con `usuario_id NULL`: no es atribuírsela a otro sino a nadie, y la columna es
  nullable con 2 pedidos así en el último año.

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

### 228 · Cuatro policies que dejaban leer de más

Mapea 1:1 al ledger; va acá por lo que **no** se ve leyendo el SQL. Las tres trampas que
aparecieron al escribirla, las tres medidas en prod antes de aplicar:

- **Las subconsultas de una policy corren con la RLS de la tabla que tocan.** El
  `EXISTS (SELECT 1 FROM usuario_sucursales ...)` dentro de una policy de `perfiles` ve sólo
  lo que el caller ve de `usuario_sucursales`, y un preventista sólo ve SU fila: devolvía
  1 perfil en vez de los 11 de la sucursal. Por eso el chequeo vive en dos helpers
  SECURITY DEFINER (`perfil_de_sucursal_activa`, `cliente_de_sucursal_activa`) y no inline.
- **Y si la tabla referenciada te referencia a vos, recursa.** `mt_clientes_select` ya
  subconsulta `cliente_preventistas`, así que una `cp_select` que mire `clientes` cierra el
  ciclo: `42P17: infinite recursion detected in policy for relation "clientes"`, o sea toda
  lectura de clientes caída. Mismo helper definer, mismo motivo.
- **Restringir `cp_select` por preventista AFLOJA `clientes` en vez de apretarlo.**
  `mt_clientes_select` decide "no es de nadie, lo ven todos" (mig 028) con un
  `NOT EXISTS` sobre `cliente_preventistas`; si un preventista deja de ver las filas de sus
  colegas, los clientes ajenos se le vuelven huérfanos. Medido: pasaba de ver 209 clientes a
  588. El recorte quedó sólo por sucursal.

Trae además el gate que faltaba: `auditoria_tablas_anon()` +
`scripts/check-tablas-anon.mjs`. El de la 189 mira **funciones**; éste mira **tablas**, que
es por donde se filtró `perfiles` durante meses sin que nada se pusiera rojo. Es la única
función de auditoría en SECURITY **INVOKER**: Postgres prohíbe `SET ROLE` dentro de un
definer, y el permiso de `SET ROLE anon` se resuelve contra el session_user (`authenticator`,
que sí es miembro de anon).

---

### 229 · La devolución dice de dónde viene

Mapea 1:1 al ledger. Va acá por el método y por dos cosas que no se ven leyendo el SQL.

**Se parchea por ancla sobre el cuerpo VIVO, no se reescribe el archivo.** Las nueve funciones
que toca vienen de siete migraciones distintas y ninguna coincide con su archivo en
`migrations/` — el cuerpo vivo de `sincronizar_lotes_stock`, por ejemplo, no tiene ni uno de
los comentarios que sí tiene la 223. Se usa el andamio `_mig229_reemplazar_ancla` (el idiom
de la 220): exige que el ancla aparezca **exactamente una vez** en `pg_get_functiondef` y si
no, aborta. Leer el archivo en vez del cuerpo vivo habría producido anclas que no matchean.

- **`set_config` es por transacción, no por función.** `revertir_bloques_auto_ajuste` la
  llaman tres funciones (`actualizar_pedido_items`, `registrar_salvedad`,
  `eliminar_pedido_completo`) y las tres ya declaran su propio origen antes. Etiquetarla sin
  devolver el GUC le habría pisado la etiqueta al resto del cuerpo del caller — rompiendo de
  rebote a `registrar_salvedad` y `eliminar_pedido_completo`, que hoy etiquetan bien. Por eso
  guarda y restaura los cuatro GUCs alrededor de su `UPDATE`.
- **El check STK-F arranca con dos excepciones listadas a mano**
  (`registrar_compra_completa`, `registrar_ingreso_sucursal`). Las dos suben stock sin
  etiquetar, pero lo que suben es mercadería **nueva**, que por diseño va a la bolsa "sin
  vencimiento" y no a un lote: lo que les falta es trazabilidad del ledger (STK-D), no lotes.
  Tocarlas era meterse con RPCs de compras, fuera del alcance. Están en la lista para que el
  gate arranque en verde y lo que se ponga rojo sea siempre algo nuevo.

`anular_compra_atomica` cambia de **orden**, no de lógica: cancela la compra (lo que dispara
`borrar_lotes_compra_cancelada`) y recién después descuenta el stock. Al revés, el trigger de
lotes consumía FEFO de un lote **ajeno** que venciera antes y después se borraban además los
propios: doble descuento en el ledger de lotes.

---

### 230 · El cobro se serializa y la fecha es de acá

Mapea 1:1 al ledger. Tres cosas que no se ven leyendo el SQL:

- **`CREATE OR REPLACE` SÍ cambia el default de un parámetro.** La creencia de que hace falta
  `DROP` + `CREATE` es falsa: Postgres sólo prohíbe cambiar nombre, tipos y tipo de retorno.
  Probado en prod dentro de una transacción con `ROLLBACK` antes de escribir la migración —
  queda **una sola** firma, con el default nuevo. Importa porque el `DROP` era el camino
  peligroso: dejaba una ventana sin la función y, si algo salía mal, dos firmas conviviendo
  (`PGRST203`, Trampa 5). Como la identidad de los argumentos no cambia, la Trampa 5 ni siquiera
  aplica.
- **Eran cuatro guards, no tres.** Además de los dos de la `165` y el de la `100`,
  `marcar_pagos_masivo_impl` también comparaba `p_fecha <> CURRENT_DATE`. Arreglar tres dejaba
  el camino de cobro masivo —el más usado— rechazando la fecha correcta entre las 21:00 y las
  24:00 ART. El barrido se hizo con `pg_get_functiondef` sobre las 4, no leyendo los archivos.
- **`p_fecha: null` desde el front NO aplica el default.** Un default de parámetro sólo vale
  cuando el argumento se **omite**; mandarlo explícitamente en `null` lo pone en NULL y el
  `INSERT` choca contra el `NOT NULL` de `pagos.fecha`. `usePagos` mandaba `input.fecha ?? null`.
  Los callers masivos de `usePedidosQuery`, en cambio, **omiten** `p_fecha`, y por eso sí caían
  en el default —y por eso les pegaba el bug de UTC—.

El check nuevo **CC-B** es un centinela de 30 días, no de 2 horas: el gate corre una vez por
día, así que una ventana de 2 h sólo ve lo creado en las 2 h previas a la corrida y se le escapa
casi cualquier regresión. Se midió antes de elegirla: el último pedido divergente es del
2026-05-05 y las ventanas de 7, 30, 60, 90 y 120 días dan todas 0, así que 30 días deja 100 días
de margen contra la cohorte histórica y aun así mantiene una regresión visible un mes entero.

Los **69 pedidos** con `monto_pagado` por encima de sus pagos (abril–mayo 2026, $2.459.670,02)
**no se tocaron**: corregirlos es una decisión de negocio, no de esquema.

El test de concurrencia de las dos sesiones vive en `scripts/test-concurrencia-pago-fifo.sql` y
**no corre en CI**: necesita dos conexiones simultáneas, y ni el MCP (una conexión por llamada),
ni `dblink` (pide password, el rol no es superuser), ni 2PC (`max_prepared_transactions = 0`)
lo permiten desde un agente. Se corre a mano contra una branch, nunca contra prod.

---

### 231 · La fecha de acá, en las siete que faltaban

Cola de la `230`. Censo completo con `pg_get_function_arguments` sobre `public`: quedaban **siete**
funciones con `DEFAULT CURRENT_DATE`, que en una base en UTC devuelve la fecha de mañana entre las
21:00 y las 24:00 ART. Ninguna lo tenía en el cuerpo — sólo en la firma, verificado.

**El único bug vivo demostrado era `marcar_entregas_masivo`**: `usePedidosQuery` hace
`if (fecha) rpcArgs.p_fecha = fecha`, así que cuando el usuario no elige fecha el argumento se
**omite**, el default se evalúa y la entrega queda fechada mañana al mediodía. De las otras seis,
tres tienen callers que siempre mandan la fecha (`bot_mi_recorrido` manda `hoyEnArgentina()`,
`obtener_resumen_rendiciones` manda las dos, `bot_recorrido_resumen` manda `null` explícito) y
tres no tienen caller vivo en el front.

Se tocaron **las siete igual**, porque un default sólo se evalúa cuando el argumento se **omite**:
para las que hoy nunca lo omiten el cambio es un no-op comprobable, y les saca la trampa de encima.
Es exactamente así como este bug llegó hasta acá — la `182` arregló el default de la **columna**,
la `230` el de los **parámetros de pago**, y estas siete quedaron porque nadie había hecho el censo.

La verificación de la migración es **global a propósito**: falla si queda *cualquier*
`DEFAULT CURRENT_DATE` en `public`, no sólo en las siete. Hoy no queda ninguno.

---

### 232 · La merma baja el stock en una transacción

Issue #518. La merma manual salía del navegador en **tres requests**: `INSERT` en
`mermas_stock`, `UPDATE productos SET stock = <absoluto>` con el valor que el modal había
calculado sobre su snapshot, y un `DELETE` compensatorio a mano si el segundo fallaba. Dos
mermas de 10 sobre stock 100 escribían las dos `stock = 90` — dos filas por 20 unidades y el
stock bajo 10, o sea `STK-A` roto. Es el mismo bug del incidente de la ficha de producto del
19/08, en otro camino. Y había una **segunda copia idéntica** en `useMermas.ts`, la cableada
al replay offline, donde el absoluto podía tener horas de viejo.

`registrar_merma_manual(p_producto_id, p_cantidad, p_motivo, p_observaciones, p_sucursal_id)`
hace lo que ya hacía `dar_de_baja_lote` (mig 224) al lado: `FOR UPDATE` sobre el producto,
`INSERT` con `stock_anterior`/`stock_nuevo` calculados **server-side**, `usuario_id =
auth.uid()`, y `UPDATE productos SET stock = stock - p_cantidad` etiquetado
`app.stock_origen = 'merma'`. Los dos hooks del front llaman a esta única RPC.

Tres cosas que no son obvias:

- **No toca `producto_lotes`.** Una merma **baja** stock y `sincronizar_lotes_stock` (223)
  consume FEFO en toda bajada, mire o no el origen; la lista blanca de orígenes es sólo para
  el camino que **devuelve** unidades.
- **El `app.stock_origen` igual va**, y es la otra mitad del arreglo: hasta acá toda merma
  manual entraba al ledger como `origen = 'auto'` y sin usuario, porque el `UPDATE` salía
  crudo desde el navegador.
- **El gate es `admin`**, que es la intersección de las dos políticas que el camino viejo
  tocaba (`mt_mermas_stock_insert` = admin/transportista ∩ `mt_productos_update` =
  admin/depósito). Encargado queda afuera a propósito: hoy tampoco puede. Al ser
  `SECURITY DEFINER` la función **es** el gate, así que ampliarlo es decisión de producto.

También rechaza los motivos `promociones` y `promociones_reversion`, que los escribe el motor
de promociones y el reporte gerencial excluye (130): cargados a mano hacen desaparecer una
pérdida real de todos los KPIs. Eso vivía sólo en un comentario del modal.

Verificado contra prod en una transacción con `ROLLBACK`: dos bajas de 10 sobre 100 dejan
**80 y dos filas** (100→90, 90→80), el ledger queda `origen=merma ref=mermas_stock/<id>` con
usuario, y los cuatro rechazos (motivo de promo, stock negativo, sucursal ajena, no-admin)
cortan. `MERMA-B` y `STK-A` en verde.

### 233 · Cada uno escribe lo suyo

Issue #549 (los residuales que la 219 dejó anotados) más cinco agujeros de escritura de la
misma familia. Todos son el mismo error: **la policy autoriza por rol y por sucursal, nunca
por pertenencia**, y como `es_preventista()` incluye a admin y encargado, el rol casi no
acota. Ninguno de estos caminos lo ofrece la UI; todos los habilita el token por PostgREST.

- **`pedido_items`**: el SELECT ya miraba el pedido padre, el INSERT y el UPDATE no. Un
  preventista podía editar `cantidad` y `precio_unitario` de items de pedidos entregados de
  otro vendedor. Se acota la RLS con el molde de la 190 §4 y se agrega
  `pedido_items_proteger_columnas` (INVOKER, deny-list) para que tampoco pueda reescribir el
  precio de los suyos ya cerrados.
- **`pedido_historial`**: el INSERT era `sucursal_id` a secas — cualquiera sembraba auditoría
  a nombre de otro. **La primera versión de esta migración dropeaba la policy y estaba mal**:
  `registrar_creacion_pedido` y `registrar_cambio_pedido` son SECURITY **INVOKER**, así que
  pasan por la RLS y sin policy todo INSERT/UPDATE de `pedidos` desde el navegador se caía.
  Lo detectó la corrida adversarial con ROLLBACK, no el repo. Queda acotada a
  `pg_trigger_depth() > 0 AND usuario_id = auth.uid()`: por PostgREST la profundidad es 0. El
  SELECT se acota como `mt_pedido_items_select`.
- **`cliente_preventistas`**: `cp_insert` (mig 002) dejaba auto-asignarse *cualquier* cliente,
  y desde ahí se pasaba el guard de la 216 y se veía la ficha. La 214 ya lo había dicho con
  todas las letras y sólo tapó el caso `reservado_admin`. Trigger DEFINER nuevo
  (`cliente_preventistas_no_ajeno`): rechaza el cliente que ya atiende otro y el de otra
  sucursal; deja intacto el caso que motivó la 002 (auto-asignarse el cliente recién creado).
- **`productos`**: el rol `deposito` era dueño de la fila entera — `precio`, `costo_promedio`,
  `costo_real` incluidos. Hoy no hay usuarios `deposito` en prod: se abre solo el día que se
  cree el primero. Lista blanca `stock`, `stock_minimo`, `etiqueta_bulto`, `updated_at`.
- **`pedidos_proteger_columnas`**: los dos residuales de la 219. `creado_por` ajeno ahora se
  rechaza también en el alta, y `usuario_id NULL` se **asigna** (molde de `pagos_forzar_usuario`,
  190b) en vez de fallar. **No** se pone `usuario_id NOT NULL`: las 2 filas históricas de marzo
  no tienen autor recuperable, y con la asignación el agujero ya no existe hacia adelante.
- **`clientes`**: `place_id` (mig 151) faltaba en la lista blanca de la 157. No era un agujero
  sino el guard mordiendo a quien tenía que dejar pasar: un preventista que corregía una
  dirección con el autocompletado recibía 42501 y no podía guardar.
- **`recorridos` / `recorrido_pedidos`**: el SELECT era `es_admin() OR transportista_id`, pero
  la UI le habilita `/recorridos` y "Armar ruta del día" al encargado y `aplicar_orden_ruta`
  (DEFINER) lo acepta. O sea que **podía escribir y no leer**: armaba una segunda ruta sin ver
  la primera y `aplicar_orden_ruta` se la borraba, sin un error en pantalla. Sólo se extiende
  el SELECT; la escritura sigue gobernada por la RPC.

Verificado contra prod en tres transacciones con `ROLLBACK`, con JWT de preventista, de
encargado, de admin y de un `deposito` temporal: el UPDATE a items ajenos devuelve 0 filas, el
de columnas propias de plata 42501, el INSERT en `pedido_historial` 42501 aun a nombre propio,
la auto-asignación sobre cliente ajeno y sobre otra sucursal 42501, el `creado_por` ajeno
42501, y siguen pasando el alta sin `usuario_id` (queda atribuida), el alta del admin a nombre
de otro con su fila de historial, `crear_pedido_completo`, `registrar_merma_manual`, el
guardado de `place_id` por un preventista y el movimiento de stock del depósito.

### 234 · La salvedad devuelve antes de mermar

Tres agujeros del mismo camino (la entrega con salvedad) más una convergencia de firmas.
Parche por ancla sobre el cuerpo vivo, como la 227: el `174` del repo está **75 y 30
caracteres atrás** de prod, así que un `CREATE OR REPLACE` desde el archivo habría borrado
en silencio lo que le agregó la 227.

**La merma descontaba el stock dos veces.** Las unidades ya salieron de `productos.stock` al
crear el pedido. Para `producto_danado` y `producto_vencido`, `registrar_salvedad` **no** las
devuelve (`v_stock_devuelto` sólo se prende con `cliente_rechaza`, `error_pedido` y
`diferencia_precio`) pero igual inserta la merma y baja el stock: se descuentan de nuevo. En
prod quedaron 19 unidades de stock fantasma (7 salvedades por dañado = 16 u., 2 por vencido =
3 u.). Ahora devuelve primero y merma después: neto 0 sobre `productos.stock`, y la fila de
`mermas_stock` se mide contra el stock **ya devuelto**, que es lo que pide `MERMA-B`.

Lo que no era obvio: **la devolución previa a la merma queda a propósito fuera de la lista
blanca de `trg_lotes_sincronizar`**, y usa su propio origen `salvedad_merma`. Con un origen
whitelisteado la devolución vuelve al lote por FEFO, pero la bajada de la merma sale de la
bolsa primero (el camino de bajada del trigger no mira el origen), así que el lote termina
**+N** y la bolsa **−N** en cada rotura. Medido contra prod con un lote sintético (100
cargadas, 50 vivas, bolsa 40): con `'salvedad'` el lote va 50 → 53 → **53**; con
`'salvedad_merma'` va 50 → 50 → **50**. Estas unidades no vuelven a la góndola —se rompen en
el mismo movimiento—, así que las dos patas tienen que caer del mismo lado del mostrador. La
regla de `CLAUDE.md` (toda devolución va etiquetada con un origen de la lista) sigue valiendo
para la devolución que **sí queda** devuelta. Hoy `producto_lotes` está vacía en prod, así que
el desfase habría sido latente hasta el primer lote cargado.

**`anular_salvedad` no revertía las promociones.** Al crear la salvedad se llama hasta dos
veces a `revertir_bloques_auto_ajuste`, se recortan o borran las líneas de regalo y se
devuelve el stock del contenedor; anular restituye la línea y los totales y **nada de eso**.
Rehacerlo en sentido de alta es otra función (`aplicar_uso_promo_acumulador` con delta
positivo más un re-sync hacia arriba). Hasta que exista, la anulación que tocaría una promo se
**rechaza** con `codigo = 'anulacion_toca_promociones'`. La detección es la vía espejo: si
restituir `cantidad_afectada` cambia la cantidad de **bloques** de alguna promo que incluye al
producto, el regalo habría que reponerlo. Alcance medido: **38 de 251** salvedades (15%), y
cuesta cero — nunca se anuló ninguna, y `anular_salvedad` **no tiene un solo caller en
`src/`**: el botón "Anulada" de `ModalResolverSalvedad` va por `resolver_salvedad`, que sólo
cambia la etiqueta y no revierte nada (issue aparte).

**El recorrido no se enteraba de que bajaba el total.** `recorridos.total_facturado` lo
escriben `aplicar_orden_ruta` (088) y `recalcular_recorrido` (180), y el trigger de entrega
era `AFTER UPDATE OF estado, monto_pagado`: un `UPDATE` de `total` no lo despertaba (Trampa
6). `/recorridos` mostraba "Pendiente" = facturado − cobrado inflado en **18 de 123** rutas.
Ahora `total` está en la lista y el cuerpo recalcula `total_facturado` con la misma subconsulta
que ya usaba. **No** llama a `recalcular_recorrido()` aunque calcule los cuatro contadores:
esa función exige `es_encargado_o_admin()` y el trigger corre en la transacción del
**transportista** que marca la entrega, así que la entrega entera reventaría con 42501.
`total_pedidos` queda afuera por la misma lógica: lo mueve `recorrido_pedidos`, que este
trigger no observa. Para las 18 rutas viejas hay ahora un botón de admin en `/recorridos` que
llama a `recalcular_recorrido` (era la única RPC de esa familia sin ningún caller en el front).

**Una sola firma.** La sobrecarga de 7 args de `registrar_salvedad` se dropea: rangos `[4,7]`
y `[4,8]` superpuestos son `PGRST203` en runtime, invisible para `tsc` y para los tests
(Trampa 5). En prod ya había una sola firma, así que el `DROP IF EXISTS` es convergencia, no
fix — el único caller (`PedidosContainer.tsx`) pasa los 8.

**Las 19 unidades históricas no se tocan, y es una decisión.** Un `UPDATE` a ciegas estaría mal
en 13 de las 19: nueve (salvedades 77, 90, 91) tuvieron un **conteo físico posterior** que ya
absorbió el desfase, y cuatro más (51, 228, 230) son de productos que hoy están en cero, donde
sumar inventa mercadería que nadie tiene. Quedan para el próximo conteo, que es lo único que
las puede separar del resto de la deriva. El detalle por salvedad está en el §6 del archivo.

Verificado contra prod en cuatro transacciones con `ROLLBACK` antes de aplicar: los seis
anclajes aparecen exactamente una vez; pedido de 6 con stock fijado en 90 y salvedad de 3
dañadas deja **stock 90**, una merma **3 / 93 / 90** y el ledger en `salvedad_merma: 90→93`
seguido de `merma: 93→90`; con un lote sintético el lote queda en **50** (neto 0); la ruta 130
queda con `total_facturado` = Σ `pedidos.total`; y el guard de anulación rechaza la salvedad 43
(`anulacion_toca_promociones`) y deja pasar la 28. Post-aplicación: `STK-F` en 0,
`auditoria_integridad()` con `overall_ok = true` y 0 en rojo.

### 235 · El total lo dice el servidor, y cancelar deja todo en cero

Tres agujeros del alta y la baja de un pedido con la misma forma: el servidor le creía al
caller un número que podía calcular solo. Parche por ancla sobre el cuerpo vivo (molde de la
205), porque `crear_pedido_completo` es la mig 132 más los parches de 205/214/216 y copiarla
del archivo habría borrado esos tres.

**El total venía del cliente y nadie lo miraba.** `crear_pedido_completo` insertaba `p_total`
tal cual en `pedidos.total` y `total_real`. Al cierre recalculaba `total_neto`, `total_iva` y
`total_real` desde los items, pero `total` nunca se comparaba contra
`SUM(cantidad × precio_unitario)`. Items por $80.000 con `p_total = 1` descontaban el stock de
verdad, salteaban la compra mínima (la 205 validaba sobre ese mismo `p_total` sin verificar) y
le dejaban al cliente una deuda de $1; `VENTA-A` lo veía recién en el gate del día siguiente.
Ahora se compara, **no se pisa**: `p_total` sigue siendo el contrato y sigue siendo lo que se
inserta, con la tolerancia de un centavo que ya usa `VENTA-A`. La compra mínima pasa a
evaluarse contra el total calculado. Mismo tratamiento en `crear_pedido_completo_bot` con
`v_pendiente.total`, respetando su contrato de error (`error` string, no `errores` array).

**La idempotencia del replay offline no se serializaba.** `crear_pedido_idempotente` (071)
buscaba el `offline_id` sin lock y lo sellaba *después* de crear. Dos llamadas solapadas —el
reintento del PWA cuando vuelve la señal es exactamente eso— pasaban las dos por el lookup
vacío: la segunda creaba el pedido entero y moría con `23505`, que PostgREST devuelve como 409
y el front no reintenta. Ahora `pg_advisory_xact_lock(hashtextextended(p_offline_id, 0))` antes
del lookup, mismo molde que `pago_solicitud_abrir` (230). El hit idempotente además sólo cuenta
si la fila es de la sucursal activa; **el lookup sigue leyendo global a propósito**, porque
`uq_pedidos_offline_id` también es global (índice parcial sobre `offline_id`, sin
`sucursal_id`): filtrarlo de verdad haría que el caso cruzado volviera a crear el pedido y a
morir con `23505` después de descontar stock. Se corta antes, con mensaje propio. Y
`p_offline_id` nulo sigue siendo legal pero deja un `RAISE LOG`.

**Cancelar dejaba tres cosas colgadas**, las tres medidas en prod antes de tocar nada:

- El regalo no devolvía el fardo: había un `GREATEST(usos_pendientes - cantidad, 0)` a mano en
  vez de `revertir_bloques_auto_ajuste`, y el clamp se comía el negativo, así que el bloque que
  se mermó al completarse no volvía nunca. Los otros tres caminos ya la llamaban. 79 pedidos
  cancelados con 396 unidades de regalo en promos con auto-ajuste. Ahora se llama **agrupado
  por promoción**: dos renglones de la misma promo son un solo delta y un solo `promo_ajustes`.
- El cobro se evaporaba: `monto_pagado = 0` sin tocar `pagos`, así que el pago quedaba imputado
  a un pedido cancelado, no reducía ninguna boleta viva ni contaba como crédito.
  `CC-PAGOS-CANCEL` daba 0 sólo porque todavía no había pasado. Ahora se desimputa
  (`pedido_id = NULL`), que es la representación de saldo a favor que ya usan
  `registrar_pago_cliente_fifo_impl` y `aplicar_credito_cliente` y la que `CC-A` cuenta como
  crédito. El guard de caja cerrada es `BEFORE UPDATE OF fecha, monto` y no se dispara: está
  bien, porque el monto, la fecha y la forma de pago no cambian — la caja de ese día cierra por
  el mismo número, sólo cambia a qué boleta se imputa.
- `total_real` no se cereaba: 113 pedidos cancelados con `total_real <> 0`, hasta $198.800, y
  197 con `total_neto <> 0`. Es la base del margen y del CMV. Se agrega al `UPDATE`, se extiende
  `VENTA-I` a las cuatro columnas y se backfillean las filas viejas.

**`cambiar_cliente_pedido` necesitó el escape hatch, y no es cosmético.** Cancela el pedido
viejo y *después* hace `UPDATE pagos SET pedido_id = <nuevo>` para que el cobro viaje con la
venta. Con la desimputación puesta, ese `UPDATE` no encuentra nada: medido en prod, el cobro
quedaba de crédito en el cliente **equivocado** y el pedido nuevo en `monto_pagado = 0`.
`app.cancelacion_conserva_pagos` es el mismo GUC por transacción que `app.omitir_minimo_pedido`
(205) y `app.omitir_minimo_venta` (174), por el mismo motivo: una reatribución es una
corrección administrativa, no una cancelación.

Los **4 pedidos de abril con `total <> 0`** que `VENTA-I` ya documentaba quedan con su total:
son anteriores al camino actual de cancelación y tocarlos reescribiría la facturación de abril.
Se les cerea neto/iva/real como a todos, así que `VENTA-I` sigue dando exactamente esos 4.

Verificado contra prod en tres transacciones con `ROLLBACK` antes de aplicar: `p_total = 1` con
items por $80.000 **rechazado** con los dos números en el mensaje y el mismo pedido con total
correcto creado igual que antes; dos llamadas con el mismo `offline_id` devuelven el mismo
`pedido_id` con `idempotente = true`, una sola fila con esa clave y el advisory lock presente en
`pg_locks` con la clave exacta; cancelar un pedido con $30.000 imputados deja el pago en
`pedido_id = NULL` y el `saldo_cuenta` del cliente $30.000 abajo (crédito), con las cuatro
columnas del pedido en 0; cancelar un pedido con regalo de la promo 13 devuelve el contenedor
`163 → 162 → 163` y los usos `4 → 0 → 4`; y el cambio de cliente, con el hatch, deja el pago en
el pedido nuevo y en el cliente nuevo (sin el hatch, medido, el cobro se perdía).
Post-aplicación: `VENTA-A`, `CC-A`, `CC-PAGOS-CANCEL`, `CC-B`, `VENTA-M` y `STK-F` en 0,
`VENTA-I` en sus 4 de abril, `auditoria_integridad()` con `overall_ok = true` y 0 en rojo.

> El archivo del repo lleva además un encabezado de comentarios que no quedó en el `statements`
> del ledger (se aplicó desde `BEGIN;`). El SQL ejecutable es idéntico: mismo md5 del texto sin
> espacios, `86abc2a8bfd460091399bd5cf8cd2e2c`.

### 236 · La compra se acuerda del promedio que había

Cinco agujeros de la cadena de RPCs de compras (`000 → 046 → 048 → 104 → 111 → 114 → 115 → 125
→ 126 → 127 → 128 → 177 → 178 → 192-196 → 224 → 227`), los cinco forward-only. Parche por ancla
sobre el cuerpo vivo, con un helper extra que reemplaza una **región** delimitada por dos marcas
cortas en vez de un ancla transcripta: el bloque del promedio son cuarenta líneas y alcanza con
que un espacio no coincida para que el parche no entre.

**El promedio se re-derivaba desde el promedio que ya incluía la compra.**
`actualizar_compra_items` mezclaba `productos.costo_promedio` leído tal cual —el promedio de
*después*— con `v_stock_previo_map`, que sí resta las unidades de la compra: un stock de *antes*.
Medido en prod con `ROLLBACK`: 100 u. a CPP 10 más una compra de 100 u. a 20 dejan **15** al
registrar y **17,50** después de una edición sin un solo cambio (la siguiente, 18,75).
`reporte_gerencial` y `reporte_valuacion_inventario` leen esa columna. El promedio previo no se
puede reconstruir después, así que se guarda cuando todavía se sabe:
`compra_items.costo_promedio_anterior`, análoga a `stock_anterior`, escrita por las dos RPCs. Las
compras ya cargadas no lo tienen: para esas la edición **no toca** el promedio y devuelve
`warning_costo_promedio` con `motivo = 'sin_cpp_previo'` (el costo de reposición sí se actualiza,
que no depende del promedio).

**Una factura traspapelada pisaba el costo de reposición.** `registrar_compra_completa` escribía
`costo_sin_iva` / `costo_con_iva` / `costo_real` / `ultimo_tipo_compra` sin mirar si había una
compra posterior; una factura de tres semanas atrás cargada con su fecha real devolvía el costo
de reposición a esa fecha, y de ahí salen los precios de venta. Se portó `v_es_mas_reciente`,
que `actualizar_compra_items` ya tenía desde la 128: el stock y el promedio suman igual, el costo
de reposición no se pisa, y vuelve `costo_actualizado = false` por ítem más un
`warning_costo_reposicion` de cabecera.

**La 227 había parcheado una sola de las dos.** El `#539` (la mercadería regalada diluye el
promedio) entró sólo en el alta. Se aplica el mismo parche a la edición, con `v_stock_previo` de
base, y el post-check de la 227 pasa a mirar las dos funciones. De paso, `v_stock_previo_map`
ahora avanza en **todas** las ramas: un regalo seguido de una línea paga del mismo producto
volvía a contar el mismo stock.

**La nota de crédito no tenía tope en la base.** `registrar_nota_credito` (viva desde el
baseline) no validaba que el `producto_id` perteneciera a la compra ni que la cantidad cupiera en
lo comprado menos lo ya acreditado; el único tope vivía en `ModalNotaCredito` (`maxCreditable`,
`staleTime` 5 min). El corte va **por producto**, igual que el del modal, y el `FOR UPDATE` sobre
las líneas de la compra serializa las notas simultáneas.

**issue #566 — el clon se quedaba sin lotes.** `cambiar_proveedor_compra` cancelaba la compra
vieja con un `UPDATE` directo, que dispara `borrar_lotes_compra_cancelada` (224): el clon nacía
sin un solo vencimiento y la mercadería que seguía en el depósito volvía a la bolsa "sin fecha".
`producto_lotes.compra_id` apunta a la **compra**, no a la línea, así que no hay nada que clonar:
se **reapuntan** antes de cancelar. Reapuntar y no `INSERT ... SELECT` + `DELETE` preserva
`cantidad_restante` —lo que FEFO ya consumió— y no duplica la suma de lotes ni por un instante
(invariante `LOTE-A`).

No se tocó `src/utils/prorrateoCompra.ts` ni `calcular_costos_compra` / `prorratear_cargo`: son
el motor de prorrateo de cargos, están espejados por `scripts/espejo-motor-compras.mjs` y ninguno
menciona `costo_promedio` (el bloque de verificación lo vuelve a comprobar). El orden de
`anular_compra_atomica` ya lo había arreglado la 229 —cancela antes de bajar el stock— y se
verificó sobre el cuerpo vivo: no había nada que hacer, sólo quedó un guard de regresión.

La migración **es su propia prueba de aceptación**: además de la verificación estática trae un
ensayo funcional dentro de una subtransacción que se revierte siempre (las variables de plpgsql
no son transaccionales, así que lo medido sobrevive al rollback). Antes de aplicar se corrió el
mismo ensayo contra el código sin parchear y devolvió los cinco bugs: `A edicion=17,50`,
`B costo_real=50` con `costo_actualizado=true`, las NC de 11 / de un producto ajeno / 6+6+4 sobre
una compra de 10 **todas aceptadas**, y `lotes_clon=0`. Después de aplicar, el mismo ensayo pasa
en verde. El md5 del archivo del repo es idéntico al `statements` del ledger:
`61a71769eb68eeae99be8cfab99099b0`.

### 237 · El bot mira el perfil en vivo

`canjear_codigo_vinculacion_bot` (014) copiaba `perfiles.rol` y la sucursal a `bot_usuarios` al
vincular, y de ahí en adelante el bot no volvía a mirar `perfiles`: `resolveUserByTelegramId` era
un SELECT plano con `activo = true` y sin un solo JOIN. La **206** cerró la puerta de la web con
`perfiles.activo` y no tocó ésta, así que dar de baja a un empleado —o bajarlo de admin a
preventista— no le cortaba ni le cambiaba nada por Telegram: seguía creando pedidos y viendo
saldos con el rol del día que se vinculó, hasta que un admin se acordara del segundo interruptor,
el del panel del bot.

`bot_resolver_usuario(telegram_user_id)` resuelve ahora contra `perfiles` y `usuario_sucursales`
**en cada mensaje**, y es lo único que el edge llama para saber quién le escribe. En
`bot_usuarios` queda sólo lo que es del bot: el mapping, su propio interruptor (`activo`, el de
`bot_admin_toggle_usuario` y `/desvincular`) y la **sucursal activa** que el usuario eligió con
`/sucursal`. Esa sucursal es un override, no un snapshot: el resolver la valida contra
`usuario_sucursales` y cae a la default si se la desasignaron o si la sucursal se desactivó —
antes quedaba pegada para siempre.

**`bot_usuarios.rol` no se dropea, y es a propósito.** La edge function desplegada sigue
seleccionando esa columna y el deploy de las functions va al **mergear**, no al aplicar la
migración: dropearla ahora deja el bot caído en esa ventana. Queda como dato histórico ("con qué
rol se vinculó"), con el `COMMENT` que lo dice. Los dos lectores que decidían algo con ella pasan
a leer `perfiles` en vivo: `bot_admin_listar_vinculados` (acá) y el cargador de admins de
`telegram-digest` (en la edge function, con `perfiles!inner(rol, activo)` — `bot_usuarios` tiene
una sola FK a `perfiles`, así que no hay `PGRST201` posible; verificado igual con `curl` + anon
key antes de mergear). Ese digest le mandaba el resumen de ventas del día a quien hubiera sido
admin alguna vez.

**El OTP era hexadecimal.** `upper(substring(encode(gen_random_bytes(4),'hex') FROM 1 FOR 6))`
tiene 16 símbolos de alfabeto, no 36: 16,8 millones de combinaciones, TTL de 10 minutos y un canje
que no contaba los fallos. Y los mensajes del bot decían "letras mayúsculas y números" sobre un
código que nunca tuvo una letra arriba de la F. Ahora son **8 caracteres de un alfabeto de 32**
(`23456789ABCDEFGHJKLMNPQRSTUVWXYZ`, sin 0/O ni 1/I para que no se lean mal al dictarlos): 32
divide a 256, así que el `% 32` sobre cada byte del CSPRNG sale uniforme, sin sesgo de módulo. El
regex del bot sigue aceptando `[A-Z0-9]{8}`: validar la forma es para no gastar un intento, no
para adivinar el código.

**El canje lleva contador**: `bot_intentos_vinculacion` (RLS sin policies, como las otras cuatro
`bot_*`) cuenta fallos por `telegram_user_id` en una ventana de 15 minutos; al quinto fallo
bloquea 15 minutos y el sexto intento no llega a mirar el código. Un canje bueno borra la fila.
Todas las ramas de error pasan por un solo punto de salida para que ninguna se olvide de contar.
Los códigos de 6 caracteres que estaban vivos se invalidaron en la migración (era 1): el bot nuevo
no los acepta y dejarlos abiertos era hacerle gastar un intento a alguien.

La migración **es su propia prueba de aceptación**: además de la verificación estática (ACLs,
firma única, RLS de la tabla nueva) trae un ensayo funcional dentro de una subtransacción que se
revierte siempre. Vincula dos chats inventados (`telegram_user_id` negativo) a perfiles reales y
mide: el resolver devuelve el rol **vivo** y no el snapshot que se le puso distinto a propósito,
un perfil con `activo = false` devuelve `motivo = perfil_inactivo`, `bot_usuarios.activo = false`
devuelve `bot_desactivado`, un override de sucursal ajeno cae a la default, y los seis canjes
seguidos dan `no_encontrado ×5` y `bloqueado` el sexto. Para el perfil dado de baja usa uno que ya
esté inactivo si lo hay: tocar `perfiles.activo` dispara `perfiles_sync_acceso_auth` (206), que
banea al usuario y le borra las sesiones.

**La primera corrida salió roja y estuvo bien.** Una función nueva de `public` no nace sólo con
`EXECUTE` para `PUBLIC` y `anon`: Supabase también se lo concede a **`authenticated`** por default
privileges, y `REVOKE ... FROM PUBLIC, anon` no lo saca. La verificación estática lo cazó antes de
que quedara aplicado (`bot_resolver_usuario quedo ejecutable por authenticated`), así que las dos
`bot_*` que sólo llama el edge con la service_role key revocan las **tres** mitades y la
verificación las mira a las dos. Post-aplicación: ACL de `bot_resolver_usuario` y
`canjear_codigo_vinculacion_bot` en `postgres` + `service_role` y nada más, `auditoria_integridad()`
con `overall_ok = true`, y cero filas del ensayo. El md5 del archivo del repo sin espacios es
idéntico al `statements` del ledger: `30802b65fa32cd7ab44dc84eb6847ec6`.

### 238 · El criterio de merma vive en un solo lugar

Tres síntomas, una sola causa: una regla de negocio escrita más de una vez sin nadie que
verifique que las copias sigan diciendo lo mismo.

**#570 — el criterio de merma estaba copiado verbatim.** La cascada de costo, el corte del día
argentino y la exclusión de `promociones`/`promociones_reversion` vivían dos veces: en los CTEs
`k_merma` / `m_merma` / `mermas_motivo` de `reporte_gerencial` (130) y en el CTE `base` de
`reporte_mermas` (226). La 226 lo dice en su propia cabecera —"se copian VERBATIM de la 130"— y
pide **a mano** que si tocás una toques la otra. La invariante que las une
(`reporte_mermas.totales.costo == reporte_gerencial.kpis.mermas`) se sostenía sobre un
comentario. Ahora hay **una** implementación, `mermas_valorizadas(desde, hasta, sucursales)`, y
las dos la consumen: el gerencial filtrando `clasificacion <> 'promocion'` —que es exactamente el
viejo `NOT IN ('promociones','promociones_reversion')`— y el reporte dejándolas entrar para
informarlas aparte. El cruce pasa a cerrar **por construcción**, no por coincidencia.

**#511 — `sin_costo` era tres predicados distintos.** El gerencial VALÚA con la cascada completa
pero decidía `sin_costo` mirando una sola pata (`costo_sin_iva IS NULL OR = 0`): un producto con
`costo_promedio` cargado se valuaba bien y encima disparaba la alerta "productos sin costo", que
dice que el margen está inflado cuando no lo está. `reporte_alerta_detalle` repetía ese predicado
a mano, **sin filtro de fecha y con `estado='entregado'` fijo**, así que la lista detrás de la
alerta no podía cuadrar con el KPI ni por casualidad. Y `reporte_mermas` usaba
`COALESCE(promedio, real, costo_sin_iva) IS NULL`, que no captura `costo_sin_iva = 0`. Ahora las
tres preguntan lo mismo: `costo_valuacion(...) IS NULL`, con `NULLIF(costo_sin_iva, 0)` adentro
—un cero no es un costo—. `reporte_alerta_detalle` **cambia de firma** (gana `p_desde`, `p_hasta`
y `p_incluir_no_entregados`) y la de dos argumentos se dropea en la misma transacción: dejarlas
conviviendo daba `PGRST203`.

**Los números de mermas y de CMV no se movieron, y está medido.** El `NULLIF` hace que un costo
de `0` pase a ser `NULL`, pero `SUM` ignora los NULL y `cantidad * 0` es 0: las dos formas suman
igual. Verificado en seco (transacción revertida) sobre **todo** el historial antes de aplicar:
107 filas de merma con costo idéntico al centavo (`1748511.5549`), 18.441 ítems de pedido con CMV
idéntico (`134676364.6281`) e `ingreso_sin_costo` idéntico (`8600.00`). Después de aplicar, las 9
combinaciones de 3 períodos × (2 sucursales + Red) dan exactamente los mismos números que antes y
`kpis.mermas == totales.costo` en las 9. Lo que sí se mueve a propósito es a quién cuenta
`ingreso_sin_costo`: hoy hay 3 productos sin ninguna pata de costo y **0** "rescatados" por el
cambio, así que el número es el mismo — la diferencia aparece el día que se venda un producto con
promedio y sin `costo_sin_iva`, que es cuando importa.

**D-8 — el límite de usos miraba un pico intermedio.** `check_promo_limite_usos` apagaba la promo
con `usos_pendientes >= limite_usos`. Desde las migs 220/221 `usos_pendientes` es el **resto** de
la barra en `[0, N)` para las promos con fracción, y `crear_pedido_completo` lo sube en
**subunidades** antes de que el auto-ajuste lo baje a ese resto. Una boleta con 392 subunidades de
regalo pasaba por `392 >= 100` y desactivaba una promo de 100 usos un instante antes de que el
mismo statement la dejara en 2. El trigger se acota a `regalo_mueve_stock` (las promos sin
fracción, donde `usos_pendientes` sigue contando lo que el nombre dice) y el chip de
`VistaPromociones` deja de mostrar "N/M usos" en las de fracción. Para las de fracción el tope
real es el stock del producto de ajuste, que el auto-ajuste ya verifica.

**La migración es su propia prueba de aceptación.** Verificación estática (una sola firma por
función, ACLs) más un ensayo funcional en una subtransacción que se revierte siempre: los casos
fijos de la cascada y de la clasificación, una grilla de 81 combinaciones que verifica que
`costo_valuacion(...) IS NULL` sea exactamente `costo_valuacion_origen(...) = 'sin_costo'`,
cuatro filas de merma sintéticas (una con `costo_promedio` y sin `costo_sin_iva` —el caso de
#511—, una con **cantidad negativa**, una de promoción que no cuenta) con el cruce medido **con
esas filas adentro**, y las dos mitades de D-8: 392 subunidades no apagan una promo con fracción,
100 usos sí apagan una sin fracción. Cierra con el cruce sobre datos reales en 9 combinaciones.

Las cuatro funciones nuevas (`costo_valuacion`, `costo_valuacion_origen`, `merma_clasificacion`,
`mermas_valorizadas`) revocan las **tres** mitades —PUBLIC, `anon` y `authenticated`— y sólo
tienen `service_role`: no las llama el front, las llaman las SECURITY DEFINER de `postgres`, que
corren como su owner. `mermas_valorizadas` además es SECURITY INVOKER y recibe el array de
sucursales **sin validar**, así que dejarla alcanzable por `authenticated` sería regalar el scope.
Post-aplicación: `auditoria_permisos_execute()` con `expuestas_a_anon = 0` sobre 264 funciones, y
las cinco RPCs responden `42501 permission denied` con la anon key. El md5 del archivo del repo
sin espacios es idéntico al `statements` del ledger: `f6bbdaa945e98993a380895e0d339554`.

**Lo que NO se tocó, a propósito:** `mermas_stock_snapshot_costo`, el trigger BEFORE INSERT que
congela el costo de la merma, repite la cascada una cuarta vez y además redondea a 4 decimales.
Es un camino de **escritura**, no de lectura —las dos funciones de reporte leen el mismo
`m.costo_unitario` ya escrito—, así que la invariante no depende de él; unificarlo cambiaría los
snapshots futuros y va por issue aparte. Tampoco se tocaron los criterios de venta por vendedor
ni el filtro de canal (SQL-13 / D-1).

### 239 · El bucket de facturas deja de ser público (nació como 228)

Archivo escrito el 2026-09-13 y mergeado a `main` **sin aplicar**, con `[SQL - NO APLICADA]`
en el mensaje del commit (`4780a58`). Para cuando se aplicó, el 2026-09-15, el número 228 ya
se lo había llevado `228_cada_uno_ve_lo_de_su_sucursal` (ledger `20260913212201`, ese mismo
día a las 21:22) y la cadena iba por la 238 — así que se renumeró a **239**. Es la trampa 3
de CLAUDE.md en su versión menos obvia: no chocaron dos sesiones escribiendo a la vez, chocó
un archivo con su propio yo de dos días antes.

**Lo encontró el drift-check, no una persona.** `scripts/check-migrations.mjs` venía rojo en
`main` desde el 2026-09-14 con "archivo en `migrations/` pero NO aplicado en prod"; el último
verde de `integridad.yml` fue el 2026-09-13, justo antes de ese commit. Vale la pena anotarlo
porque es exactamente para esto que existe el gate: un archivo sin aplicar es invisible en
code review y no lo ve ni `tsc` ni los tests.

**La mitad del código ya estaba en producción.** `ModalCompra.tsx` usa
`createSignedUrl(fileName, 300)` desde el 2026-09-13. Las signed URLs funcionan igual sobre un
bucket público, así que nada se rompió — pero el beneficio de seguridad no existió hasta esta
migración: el front estuvo dos días listo para un bucket privado que seguía siendo público, y
las 17 facturas ya subidas seguían servibles por URL a cualquiera que la tuviera, sin login.

Qué cambió: bucket privado, tope de 8 MB (el `MAX_IMAGE_SIZE` del modal) y sólo imagen o PDF;
INSERT pasa de "cualquier `authenticated`" a `es_encargado_o_admin()`; SELECT **también** a
`es_encargado_o_admin()` —no sólo admin— porque `createSignedUrl` corre bajo la RLS de quien
acaba de subir la foto, y si sólo admin tuviera SELECT el escaneo se le rompería a un
encargado; DELETE sólo admin.

Verificado después de aplicar: `storage.buckets` con `public=false`, `file_size_limit=8388608`
y los cinco mime types; las tres policies nuevas vivas y la vieja `Allow authenticated uploads`
dropeada (lo chequea el propio `DO $verif$` de la migración). Y la prueba que importa, con
`curl` sobre una factura real ya subida: la ruta pública devuelve `NoSuchBucket` tanto para el
objeto que existe como para uno inventado —indistinguibles desde afuera, sin enumeración—
cuando antes devolvía el PNG. El md5 del archivo del repo sin espacios es idéntico al
`statements` del ledger: `daf6602e97c368b445f1d5aa72f2f2bb`.

### 241 · La venta del vendedor tiene una sola definición

Cierra #568 y #569. Hasta acá "cuánto vendió Fulano" tenía **cuatro** respuestas —una por
pantalla— y el canal partía el universo en dos: un pedido del bot de Telegram (`canal='bot'`)
no sumaba al gerencial, no comisionaba y ni siquiera `bot_mis_ventas` se lo contaba al
preventista que lo había cargado, mientras que `/reportes` y `jornadas_preventista` sí.

**La decisión (D-1 del plan de auditoría, tomada por el dueño):** venta = `estado='entregado'`
· `canal <> 'cambio'` (todo canal de venta: `app` y `bot`) · por `pedidos.fecha` · atribuida a
`pedidos.usuario_id`.

**Se escribe en negativo a propósito.** El dominio de `canal` es `('app','cambio','bot')` —lo
fija el check `VENTA-D`— y `'cambio'` no es una venta: es la comanda de un canje, con `total=0`
por el invariante `CAMBIO-01`. Con `canal <> 'cambio'`, el canal que venga después cuenta solo;
con `canal = 'app'` habría que acordarse de agregarlo en once lugares, que es exactamente cómo
nació este bug.

**No cambió ningún número pasado.** Medido contra prod antes de aplicar: en los ocho meses
cerrados de 2026 "comprometida" y "entregada" dan diferencia **exacta 0.00** (un pedido termina
entregado o cancelado, y `cancelar_pedido` pone `total = 0`, mig 175), y no existe ni un pedido
con `canal='bot'` en la base. Lo único que se mueve es el período **abierto**, que es justo
donde la venta todavía no es venta. Ninguna comisión ya liquidada cambia, así que no hizo falta
fecha de corte.

**Once funciones, parcheadas por ancla sobre el cuerpo vivo.** Ocho son las del issue
(`reporte_ventas_por_preventista`, `reporte_gerencial`, `calcular_comisiones`, las tres
`bot_ventas_*`/`bot_mis_ventas`, `bot_ranking_preventistas_por_producto` y
`reporte_rentabilidad`); las otras tres entran porque contestan la misma pregunta con otro
nombre y dejarlas afuera haría falsa la premisa: `avance_metas_preventista` y
`rendimiento_preventistas` son venta por vendedor, y `reporte_alerta_detalle` dice en su propio
comentario que usa "mismos estados, mismo canal y mismo predicado que el KPI" —moverle el KPI y
no el detalle es el bug que la 238 acababa de arreglar para mermas—.

`reporte_ventas_por_preventista` además dejó de devolver `pedidosPendientes`, `pedidosAsignados`
y `pedidosEntregados`: con el universo acotado a entregados quedaban en 0, 0 y "todos", y un
cero que significa "no aplica" se lee como "no hay ninguno". No los renderizaba ninguna
pantalla.

**Lo que NO se tocó, a propósito:** `jornadas_preventista` (179) ya usaba `canal <> 'cambio'` —
era la única del lado correcto—; `posicion_fiscal` sigue en `canal='app'` porque la posición
fiscal es otra pregunta (qué se facturó, no quién vendió) y moverla es una decisión impositiva;
y cuatro checks de `auditoria_integridad()` siguen acotados a `canal='app'`. Los dos últimos van
por issue.

**El gate es el propio `DO $ensayo$` de la migración**, que corre contra los datos reales del
último mes cerrado, por sucursal, y compara vendedor por vendedor las cuatro definiciones más
`reporte_rentabilidad.ventasBrutas` contra `reporte_gerencial.kpis.venta`. Si alguna se despega,
la migración no entra — y de hecho frenó el primer intento, por otra razón (el ensayo pedía un
admin con *todas* las sucursales y la 4, "TACO POZO", está inactiva y sin asignar). Verificado
después de aplicar sobre agosto 2026: los 10 vendedores de las dos sucursales dan el mismo
número en las cuatro. El md5 del archivo del repo sin espacios es idéntico al `statements`
del ledger: `6ad2a998987385aa001b409528a22330`.

## Mantenimiento

- Toda migración nueva: archivo `migrations/NNN_descripcion.sql` **y** aplicar por
  `apply_migration` con `name = NNN_descripcion` (así repo y ledger quedan alineados, sin
  excepción que documentar).
- Si aplicás algo por SQL editor, agregalo a la sección C y backfilleá la fila del ledger.
- Si volvés a tocar este archivo, **actualizá la fecha** del encabezado.
