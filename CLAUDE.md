# CLAUDE.md

App de gestión para una distribuidora de alimentos. React 19 + Vite en el front,
Supabase (Postgres + Auth + RLS) en el back, edge functions en Deno.

## Correr y verificar

En un worktree, `npm ci` primero (ver Trampas). Antes de dar algo por terminado corré las
cuatro: `typecheck`, `lint`, `test:run`, `build`.
El pre-commit ya corre `check-secrets.sh`, `lint-staged` y los tests.

E2E: `npm run test:e2e` (Playwright, chromium).

`npm run check:migrations` **no corre localmente**: necesita `SUPABASE_URL` y
`SUPABASE_SERVICE_ROLE_KEY`, que no están en `.env`. Es un gate de CI
(`.github/workflows/integridad.yml`), no un comando de desarrollo.

Deploy: push a `main` → webhook de Coolify. La config de nginx de producción **vive en el
panel de Coolify**, no en el `nginx.conf` del repo — editar el repo no cambia nada.
Verificá siempre con `curl -I`, nunca leyendo el archivo.

## Dónde va cada cosa

Cada hecho vive en **un** solo lugar, elegido por quién lo verifica:

| Quién lo verifica | Dónde vive |
|---|---|
| Un script o CI | un test o un check |
| Regla que aplica siempre | este archivo |
| Algo por hacer | **issue de GitHub** |
| Por qué este código es así | comentario al lado del código |
| Hecho externo, no está en el repo | memoria |

Si no entra claro en una caja, probablemente no hace falta escribirlo.

## Estructura

- `src/components/containers/` — donde viven de verdad los handlers y los modales
- `src/hooks/queries/` — capa de datos (TanStack Query). Es la que se usa.

La política comercial configurable no vive en el código: está en la tabla
`politicas_comerciales` (una fila por sucursal) y se edita en `/configuracion`. Un
parámetro de negocio que cambia va ahí, no en una constante, una env var ni una columna
suelta en `sucursales`.

## Convenciones

- **Nada de refactors de paso.** Un bug que no es el que viniste a arreglar → issue.
- Lógica de negocio en `src/utils/` con tests, no adentro de los componentes.
- **Antes de escribir o aplicar SQL que toque stock, lotes, costos, compras, regalos o
  combos, leé `migrations/CLAUDE.md`**: ahí viven sus reglas completas, aunque no abras
  esa carpeta (una migración aplicada por MCP no la abre).
- Los schemas Zod de un modal lazy van **co-locados en el modal**, no importados de un
  chunk compartido: si no, un bundle viejo del PWA valida contra un schema desincronizado
  y tira "Invalid input" sin ningún error de chunk.
- El cuerpo de un PR cierra issues con `Closes #N` (en inglés): GitHub no reconoce
  `Cierra #N`, y un issue resuelto que queda abierto es un pendiente fantasma. Pasó con
  el #640.
- **Toda función nueva** de `public` nace con `EXECUTE` para `PUBLIC` — sea `SECURITY
  DEFINER` o no — y Supabase además se lo concede a `anon` por separado. Hay que
  **revocar las dos mitades en la misma migración** (`REVOKE ... FROM PUBLIC, anon`);
  `GRANT TO authenticated` no lo revierte. El gate de CI (`scripts/check-permisos.mjs`)
  falla ante **cualquier** función alcanzable con la anon key, no solo las definer.
  Una función de **trigger** no necesita `EXECUTE` para nadie: la invoca el executor como
  parte del DML, no el caller. Dejala en `postgres` + `service_role`, como
  `completar_origen_precio_item` (148) o `validar_precio_item_pedido`. Desde la 405 (#1245)
  `check-permisos.mjs` falla si una función `RETURNS trigger` tiene EXECUTE para `anon` o
  `authenticated`.
  Y una función que **sólo corre desde el server** —una edge function, un cron— se revoca a
  las **tres**: `REVOKE ... FROM PUBLIC, anon, authenticated`. La receta de dos mitades de
  arriba es para las RPCs que el frontend sí llama; aplicada a una función de server deja el
  `GRANT` default a `authenticated` en pie, y el gate **no lo ve** —`check-permisos.mjs`
  falla ante lo alcanzable con la **anon key**, no con una sesión—. Pasó con
  `bot_digest_destinatarios` (261, corregida en la 262): devolvía los `telegram_user_id` de
  todos los admins y cualquier preventista logueado podía enumerarlos.
- **El alta de un usuario no le cree al usuario, y el admin gestiona a los de sus sucursales**
  (migs 403b y 404, #1243 y #1244). `handle_new_user()` toma el rol y la sucursal de
  `raw_app_meta_data`: en la admin API, `app_metadata: {rol, sucursal_id}`; por SQL, la
  columna. Nunca los toma de `raw_user_meta_data`, que escribe el que se registra; de ahí sólo
  sale el nombre. Sin app_metadata (el alta del panel) nace preventista activo de la 1. El
  signup queda cerrado en el panel, y `scripts/check-auth.mjs` falla si se abre o si un trigger
  de `auth.users` lee el metadata del usuario para algo más. Para **ver** a un usuario, el admin
  tiene que compartir una sucursal con él (`admin_comparte_sucursal_con`). Para **cambiarle**
  el rol, el activo, el bot o sus sucursales (`asignar_usuario_sucursal`, #1291) tiene que estar
  en **todas** sus sucursales (`admin_abarca_sucursales_de`), porque el rol y el activo valen
  para todas (decisión del dueño). Nadie queda sin sucursal: un usuario sin ninguna no es de
  ningún admin. Toda rama admin de una policy mira la sucursal, y `scripts/check-rama-admin.mjs`
  lo vigila; sus excepciones van con su huella y su motivo. Una RPC SECURITY DEFINER no pasa por
  RLS: la que reciba un usuario o una sucursal lo acota, y `scripts/check-rpcs-definer.mjs` falla
  ante una que no esté en `scripts/rpcs-definer-permitidas.json`, que sólo se achica.
- **Toda tabla nueva** de `public` nace sin escritura REST y sin nada para `anon` (los
  defaults de la migración del barrido, #1135). Si el front la escribe por REST, o la escribe
  un trigger INVOKER como `authenticated`, la migración concede **el privilegio exacto** (por
  columna si alcanza) y lo suma a `scripts/grants-rest.json` en el mismo PR; nunca un `GRANT`
  a `anon`. Una RPC que escribe una tabla sin grant de escritura para `authenticated` es
  `SECURITY DEFINER` y valida el rol adentro; la excepción son los triggers de stock (STK-D),
  que usan el patrón policy + `pg_trigger_depth()` de `stock_historico` y `pedido_historial`.
  Y **un `REVOKE` de tabla borra también los grants por columna del mismo privilegio**: nunca
  "revocar todo y volver a conceder la lista", que ensancha a tabla entera lo que estaba por
  columna. Lo vigilan `src/test/grantsRest.contract.test.ts` y `scripts/check-grants-tablas.mjs`.
  Desde la 372 (#1151) hay dos obligaciones más, y el gate se pone rojo con cada una.
  **La lectura**: una tabla nueva con RLS nace con SELECT para `authenticated` (el default de
  postgres para tablas lo sigue dando). Si ninguna policy de SELECT le aplica, su misma migración
  le crea una `FOR SELECT TO authenticated` o le hace `REVOKE SELECT ... FROM authenticated`; si
  no, `select_sin_policy` queda rojo. Una tabla sólo de server va sin policy y sin SELECT, como
  `pedido_promo_reglas`. **Las secuencias**: el default ya no le da nada a `authenticated`. Una
  tabla con INSERT REST, o escrita por un trigger INVOKER, concede `GRANT USAGE ON SEQUENCE
  public.<t>_id_seq TO authenticated` (sólo USAGE, nunca UPDATE/`setval`) y la suma a
  `secuencias` de `grants-rest.json`; sin eso el INSERT da 42501 en runtime. Ninguna policy va
  `TO public`. Y `pedidos.UPDATE` y `recorridos.UPDATE` son por columna: una escritura REST
  nueva de esas tablas suma su columna al `GRANT UPDATE (...)` y al JSON.
- Los ids son `bigint` y llegan como `number` en runtime: usá `z.coerce.string()`, no
  `z.string()`.
- **Las RPCs de pago son wrappers**: la lógica vive en `<nombre>_impl` (mig 167, por la
  idempotencia). Si editás la RPC y no el `_impl`, no cambia nada y no falla nada. Son las
  cuatro de la 167 y `registrar_pagos_pedido` (405b).
- **Todo cobro pasa por una RPC** (#1246, migs 404b, 405b, 406 y 424).
  `pagos` no tiene INSERT REST: el cobro de una boleta va por `registrar_pagos_pedido` y el
  pago a cuenta por el FIFO de la ficha, que es sólo de admin y encargado. Lo que valida `registrar_pagos_pedido_impl`:
  - el rol y la cartera: el transportista cobra lo que tiene asignado y el preventista lo
    que vendió;
  - cada monto > 0 (además `CHECK pagos_monto_positivo`), y nunca más de lo que falta;
  - el cliente es el de la boleta, no un parámetro;
  - la fecha nunca es futura, y otra que hoy la carga sólo el admin.
  Un camino nuevo que inserte pagos lockea la boleta (`FOR UPDATE`) antes de mirar cuánto
  falta, y `recalcular_monto_pagado_pedido` también la lockea antes de sumar (#1247): en
  READ COMMITTED el subselect del `SET` no ve el pago de la transacción que esperó. **Las
  formas de pago son una sola lista**: `formas_pago()` (#1249). La usan el CHECK
  `pagos_forma_pago_valida`, las RPCs (por `_forma_pago_de_cobro`) y, con gate de espejo, el
  front (`src/constants/formasPago.espejo.json`). Una forma nueva cambia la función y el JSON
  en el mismo PR, nunca una lista suelta en una RPC. Al **partir** un pago (aplicar o imputar
  un crédito en parte, devolver un excedente), el pedazo lleva
  `pago_origen_id = COALESCE(pago_origen_id, id)`, y el pago que se parte se bloquea
  `FOR UPDATE` **antes** de insertar el pedazo: la foto de una rendición se fía de eso para
  saber si un pedazo nació antes o después de ella (`ultimo_pago_id`, #1292). **La rendición confirmada se congela**
  (#1248): al cerrarla, `trg_rendiciones_control_foto` guarda sus pagos en
  `rendicion_pagos_confirmados`, y un día cerrado se lee de esa foto. Reabrirla la descarta.
  Por eso reimputar ya no mueve la plata de una rendición cerrada a otro chofer. Una RPC
  nueva que lea los pagos de una rendición sale de `_rendicion_pagos`, no de `pagos` directo,
  o vuelve a leer lo vivo. Y `cambiar_cliente_pedido` recibe `p_destino_pagos`:
  `'pedido_nuevo'` (error de carga: el cobro viaja y lo que sobre queda a favor del cliente
  nuevo) o `'cliente_original'` (no tomó el pedido: lo que pagó le queda a favor).
- Una confirmación disparada desde un modal Radix tiene que renderizarse **dentro** del
  modal. Como hermano en el container queda detrás del overlay y falla en silencio.
- **Toda lectura nueva de `clientes` decide qué hace con los inactivos.** Un cliente con
  pedidos no se puede borrar (la FK es RESTRICT desde la mig 200), así que desactivarlo es la
  única salida y siempre va a haber inactivos. `fetchClientes` filtra `activo = true` por
  defecto (`includeInactivos` para el panel, que es desde donde se reactiva). Lo operativo
  —selectores, rutas, recorridos— los oculta; el historial —reportes, cuenta corriente y los
  embeds `cliente:clientes(*)`— **tiene** que seguir viéndolos, que es de lo que se trata la
  baja lógica. Una consulta que no elige está eligiendo mal por omisión.
- **El stock por lote lo lleva un trigger, no las RPCs** (y cómo devolver, etiquetar y lockear) → `migrations/CLAUDE.md`.
- **"Venta por vendedor" tiene UNA definición y se escribe siempre igual** (migs 241 y 318, #568):
  `estado = 'entregado'` · `canal <> 'cambio'` · `tipo_factura IS DISTINCT FROM 'VB'` · por
  `pedidos.fecha` · atribuida a `pedidos.usuario_id` · monto =
  **`GREATEST(total - cargo_envio, 0)`** (mig NNN cargo_4: el envío no es venta). Las seis partes importan. La venta se
  reconoce con la **entrega**, no con la carga: un pedido tomado y todavía no entregado no es
  venta ni comisiona. El canal se filtra **en negativo** —el dominio es `('app','cambio','bot')`
  y `'cambio'` es la comanda de un canje, con `total = 0` por `CAMBIO-01`—: escrito
  `canal = 'app'` hay que acordarse de agregar cada canal nuevo en cada lugar, que es
  exactamente cómo nacieron las cuatro definiciones que había. El vale blanco (`'VB'`) es
  consumo interno a costo, no venta: va aparte, como "consumo interno". `IS DISTINCT FROM` y
  no `<>` porque `tipo_factura` es nullable y un NULL es un comprobante común, no un vale. Y
  `created_at` no es fecha de venta: es fecha de carga, y encima corta el día en UTC. Todo
  reporte, RPC del bot o cálculo nuevo que conteste "cuánto vendió Fulano" copia esta línea;
  ya son **~25 funciones** de `public` (buscalas con `pg_get_functiondef ~ 'canal <> ''cambio'''`
  y con su otra forma, `COALESCE(pe.canal, 'app') <> 'cambio'`, como `_tablero_ventas`),
  y si la cambiás, el `DO $ensayo$` de la 241 (o el antes/después de la 318) es el molde para
  verificar que todas sigan dando el mismo número. `posicion_fiscal` también filtra
  `canal <> 'cambio'` (desde la 252: la venta del bot se factura igual), pero pregunta qué se
  facturó, no quién vendió: parte por `tipo_factura` y el VB va aparte, informativo (`vb_*`).
  En `auditoria_integridad()` el filtro VB va sólo en los checks que son de venta.
  **El envío vive en `pedidos.cargo_envio`, dentro de `total`** (migs 389 y NNN cargo_1–4), y su
  desglose (`cargo_envio_desglose`) dentro de `total_neto`/`total_iva`, no de `total_real`. La plata
  a cobrar (saldo, cobranza, deuda, recorridos, rendiciones, transportista) usa `total`; la venta, la
  sexta parte, y su neto resta el desglose del envío efectivo (`total - GREATEST(total - cargo_envio, 0)`:
  0 sin productos). `posicion_fiscal` no: el IVA del envío se declara.
- **Un vale blanco está saldado por naturaleza** (migs 317/318): `tipo_factura = 'VB'` ⇒
  `monto_pagado = total`, `estado_pago = 'pagado'` y **cero** filas en `pagos` (lo fuerza
  `actualizar_estado_pago_pedido` y el CHECK `pedidos_vb_coherente`). No es deuda, no se
  cobra, no comisiona (tampoco lo cobrado con `adelanto_sueldo`) y no cuenta para metas. Todo
  `UPDATE` que cambie `tipo_factura` —o el total de un VB— **nombra `total` y `monto_pagado`
  en el `SET`**, aunque un trigger BEFORE ya los ajuste: los AFTER `OF total, monto_pagado`
  (saldo, recorrido) disparan por la lista del `SET`, no por lo que cambió el BEFORE.
  Y `'vale_blanco'` **ya no es forma de pago**: un trigger lo rechaza al escribirlo en `pagos`
  y en `pedidos` (317), y los CHECK `pagos_sin_vale_blanco` y `pedidos_sin_vale_blanco` (320)
  lo cierran. No lo agregues a ninguna lista de formas de pago: el consumo interno es el
  comprobante VB, que nace por `crear_pedido_completo` o `cambiar_tipo_factura_pedido`.
- **El precio de venta lo decide el admin.** Para el resto, las RPCs que insertan líneas de
  venta llaman a `precio_fuera_de_politica`, que pone **piso y techo** (migs 363 y 369). Piso:
  lista o escala aplicable menos el descuento del cliente. Techo: la lista de hoy, sin escalas
  ni descuentos (sólo bajan el precio). Para el replay valen, en los dos, sólo el precio
  inmediatamente anterior, > 0, vigente al menos 15 minutos y dentro de
  `politicas_comerciales.ventana_precio_anterior_horas`; en la edición, el piso conserva el
  precio guardado si ningún grupo se achica, y el techo conserva siempre el máximo guardado.
  La ventana la edita **sólo el admin**, desde /configuracion
  (`actualizar_ventana_precio_anterior`, mig 368): afloja el piso y el techo del encargado, y
  la puede usar también quien está online (tras una suba, el precio viejo más barato; tras una
  baja, el viejo más caro). El check **PRECIO-A** de `auditoria_integridad()` se pone rojo si
  una función nueva inserta `pedido_items` sin llamarlo, y el piso tiene espejo con gate
  (`pisoPrecio.espejo.json`); el techo no, porque no depende de las escalas. El regalo va a
  precio 0 por CHECK (`pedido_items_regalo_a_precio_cero`).
- **El IVA de una venta sale de `condicion_iva`, nunca de `COALESCE(porcentaje_iva, 21)`**
  (#1258). La regla es `_alicuota_iva_venta(condicion, porcentaje)` —exento o no gravado → 0;
  gravado → su porcentaje, 21 si no tiene— y su espejo en el front, `alicuotaIvaVenta`. Un
  camino nuevo que inserte líneas de venta además normaliza el JSON al entrar con
  `_items_precio_redondeado`: `precio_unitario` es `numeric(10,2)`, y con el precio crudo el
  subtotal y el desglose no cierran contra el precio guardado. Lo que ya existe usa la **foto**
  de la línea (`pedido_items.porcentaje_iva`), no el IVA de hoy del producto
  (`cambiar_tipo_factura_pedido`). Una foto 0 en una línea de venta es ambigua —miles de líneas
  anteriores a julio 2026 la tienen por default— y cae al producto. La NC de venta guarda su
  `neto` e `iva` (la foto de lo que acredita) y `posicion_fiscal` los resta por la fecha de la
  nota (#1257). Por eso el ZZ↔FC exige que no haya NC vigente.
- **El criterio de merma y la cascada de costo viven en una función** (`mermas_valorizadas`, `costo_valuacion`) → `migrations/CLAUDE.md`.
- **`productos.costo_promedio` no puede ser base de sí mismo** (foto del alta, `_cpp_linea`) → `migrations/CLAUDE.md`.
- **Cancelar una compra le borra los lotes**: decidí antes qué hacer con ellos → `migrations/CLAUDE.md`.
- **`productos` se concede columna por columna y los costos no se leen por REST** (#974).
  `authenticated` y `anon` no tienen `SELECT` sobre la tabla sino sobre una lista de columnas
  sin `costo_real`/`costo_promedio`/`costo_sin_iva`/`costo_con_iva`; esos los da la RPC
  `costos_productos()` sólo a admin y encargado. Tres corolarios: (1) **un `*` sobre productos
  por PostgREST** —`select('*')`, un `.select()` pelado tras insert/update, `productos(*)` en un
  embed— **falla la consulta entera, para todos los roles**: se pide `PRODUCTO_COLUMNAS`
  (`src/lib/productoColumnas.ts`), y lo vigila su test; (2) **una columna nueva de productos nace
  invisible**: su migración la concede (`GRANT SELECT (col) ... TO authenticated`, sin `anon`) y se suma
  a `PRODUCTO_COLUMNAS`; (3) `REVOKE SELECT (col)` sobre un `GRANT` de tabla vigente no hace nada
  —por eso se revocó la tabla—. El depósito tampoco lee `compra_items` ni `nota_credito_items`
  (mig 405, #1245): cada línea es un costo, y sus policies de SELECT son de admin y encargado.
- **La cadena de sustituciones de un regalo es de la LÍNEA, no de la promo** → `migrations/CLAUDE.md`.
- **La asignación de un cliente tiene TRES estados, no dos**: sin asignar / asignado a X /
  `reservado_admin` (mig 214). Son excluyentes. Cuidado con que "sin asignar" significa
  **visible para todos los preventistas** (mig 028), o sea lo contrario de reservado. Y
  `reservado_admin` **no** es "solo lo ve admin": lo ven también encargado, transportista y
  depósito, y el preventista que ya le vendió —esa excepción es la que evita que sus pedidos
  viejos pierdan el cliente y desaparezcan por los `!inner` de `usePedidosQuery`—. Todo
  camino nuevo que ofrezca clientes *para operar* lo excluye; todo camino de *historial* lo
  sigue mostrando.
  Desde la 358 esa excepción de historial vale para **cualquier** cliente, no sólo el
  reservado: el preventista ve todo cliente al que ya le vendió aunque hoy lo atienda otro.
  O sea que `useClientesQuery` le devuelve clientes con los que **no** puede operar. Un
  listado, selector o contador nuevo usa `useClientesOperativosQuery` (o
  `esClienteOperable`); `useClientesQuery` queda para resolver por id.
  Ver no es editar: `mt_clientes_update` le pide al preventista la misma rama de operar.
  Desde la 378 (#1182/#1183), el que reparte un pedido (sin VB) ve su cliente sin poder
  operarlo, y sólo quien actúa como preventista en la sucursal (`_actua_como_preventista`) puede
  tener clientes asignados: el trigger de `cliente_preventistas` frena al transportista y al
  encargado; el admin y el server no pasan por ahí.
- **La zona manda la asignación** (mig 359). Cada zona tiene a lo sumo **un** preventista
  (`preventista_zonas`, UNIQUE por zona) y sus clientes son de él. Linkear la zona o cambiar
  el dueño pasa **todos** sus clientes al dueño (`asignar_preventista_zona`). Cambiarle la
  zona a un cliente lo pasa al dueño de la nueva (`trg_clientes_zona_asigna_duenio`). Quitar
  el link no toca a nadie. El reservado nunca recibe preventista. `preventista_zonas` **no se
  escribe a mano**: sin la RPC no se reasignan los clientes, y por eso no tiene policies de
  escritura. Un camino nuevo que cambie `clientes.zona_id` no tiene que reasignar: lo hace
  el trigger. Uno que asigne preventistas **en bloque** pasa por `_asignar_clientes_a`.
- **Un regalo se mide contra la promo con la que se armó** (`promos_del_pedido`) → `migrations/CLAUDE.md`.
- **Un combo son líneas comunes, y un producto puede ir en DOS líneas de venta** → `migrations/CLAUDE.md`.
- **La promo de un pedido se mide en `LEAST(fecha del pedido, hoy)`**, en el alta y en la
  edición, en el front y en el server (#1152). En el front lo calcula `fechaReferenciaPromo`
  (`src/utils/fechaReferenciaPromo.ts`): para hoy o una fecha futura devuelve `undefined`, que
  usa el cache de hoy. En el server, el `v_d` de `regalo_fuera_de_promo` y el de
  `combo_fuera_de_regla` (#1260), que aceptan además "o en hoy" a propósito, para no ser nunca
  más estricto que el front. Un camino nuevo que resuelva las promos o los combos de un pedido
  usa esa función, no `pedido.fecha` pelado ni `undefined` (`ModalCambiarCliente` usaba
  `pedido.fecha`). En el alta son dos llamadores (`ModalPedido` muestra, `PedidosContainer`
  guarda y encola), y tienen que pedir la misma fecha.
- **El límite de usos de una promo lo hace cumplir un trigger** (`trg_limite_usos_promo`) → `migrations/CLAUDE.md`.
- **El día es el argentino, no el del servidor** (#1250). La base corre en UTC: entre las 21 y
  las 24 de Argentina `CURRENT_DATE` ya es mañana, y la mora, las alertas y las metas corrían un
  día de noche sin que fallara nada. En una función va `_tablero_hoy()`; en un default de
  columna, `((now() AT TIME ZONE 'America/Argentina/Tucuman'))::date` inline (un default se
  evalúa con los permisos de quien inserta). `::date` sobre un timestamptz también corta en UTC:
  `(x AT TIME ZONE 'America/Argentina/Buenos_Aires')::date`. Lo vigila
  `scripts/check-fechas-utc.mjs` contra `scripts/fechas-utc-permitidas.json`, que sólo se achica.
  Desde #1298 mira también vistas, policies y CHECKs, y `CAST`, `date_trunc`, `to_char` y
  `extract` sobre `now()` o una columna timestamptz; las funciones van por **firma**, así que
  cambiarle los parámetros a una de la lista obliga a actualizarla en el mismo PR.
- **Un reporte cierra contra su propio total** (#1262, mig 410). Toda lectura de `pedido_items`
  para un reporte va con **LEFT JOIN a `productos`**: hay líneas de productos borrados
  (`producto_id` NULL, de antes de que la FK pasara a RESTRICT) y con JOIN se caen de la venta
  pero no de `pedidos.total`. Sin producto, `costo_valuacion` da el costo congelado o NULL, que
  es "sin costo". Lo mismo con `perfiles`: un pedido sin `usuario_id` va como "(sin vendedor)".
  Y "Red" (`p_sucursal_id` NULL) es **`_sucursales_red()`**: las activas que el usuario tiene
  asignadas, o todas las activas para el servidor. No una copia: con dos definiciones, dos
  números de la Red no cerraban entre sí.

## Trampas

**1. Corré los tests sin `.env`.** Tener `.env` local enmascara fallos de import que CI sí
detecta. La corrida sin `.env` es la que vale.

**2. Los worktrees nacen sin `.env` y sin `node_modules`.** La pantalla en blanco y la
pila de errores de typecheck en un worktree recién creado son **ambientales**, no del
código. Corré `npm ci` antes de diagnosticar nada.

**3. `migrations/` es una vista curada, no un espejo de producción.** La fuente de verdad
es el ledger de prod (`supabase_migrations.schema_migrations`). Y el número de una
migración **se reserva aplicándola, no escribiendo el archivo**: elegí el número al final,
justo antes de aplicar. Tres fuentes distintas pueden ocupar el mismo número —
`origin/main`, el ledger, y las ramas abiertas de otras sesiones— y a la tercera no se la
puede consultar. Ya falló tres veces. Detalle en `migrations/MANIFEST.md`.
Si tocás el MANIFEST §D, tocá también el mapa `CONSOLIDACIONES` de
`scripts/check-migrations.mjs`: son espejo, y desalinearlos deja el gate rojo para siempre.

**4. `es_preventista()` NO significa "es preventista".** Devuelve `true` también para
`admin` y `encargado` (y para quien tenga el rol extra en `perfil_roles`). Ídem
`es_transportista()`, que incluye a `admin`. Un `CREATE OR REPLACE` descuidado de esos
helpers revierte el multi-rol en silencio.
Para preguntar por un uuid que no es `auth.uid()` (un trigger sobre `NEW`, el bot con
service_role) está `_actua_como_preventista(uuid, sucursal)` (mig 377, #1179): rol base
preventista o el extra de esa sucursal, sin admin ni encargado. Es de server, sin EXECUTE
para authenticated.

**5. Un embed ambiguo de PostgREST rompe la consulta entera.** Dos FKs a la misma tabla ⇒
`PGRST201`, y falla **toda** la query, no sólo el embed. El `select` es un string: no lo
ven ni `tsc` ni eslint ni los tests. Probá todo embed nuevo antes de mergear. Ya rompió
"Armar ruta" en producción. Desde #1135 `anon` no lee nada, así que con `curl` + anon key una
query bien formada da `42501`: sirve sólo para ver `PGRST200`/`PGRST201`, que PostgREST
resuelve antes de ir a la base (un `42501` quiere decir que el embed resolvió). El caso
positivo se prueba con el JWT de una sesión, o en SQL con `SET LOCAL ROLE authenticated` +
`request.jwt.claims`.

Pariente de la misma familia: **dos sobrecargas SQL con rangos `[obligatorios, total]`
superpuestos** hacen que PostgREST no sepa cuál llamar y tire `PGRST203`, también en
runtime y también invisible para `tsc` y para los tests. Al cambiarle la firma a una
función, **dropeá la vieja** — no dejes las dos conviviendo "por compatibilidad".

Y el tercero de la familia: **los parámetros de una función que se llama por PostgREST van
en `INTEGER`, nunca en `SMALLINT`.** Todo lo que entra por ahí es un número de JSON, o sea
`integer`, y Postgres **no** hace el downcast implícito al resolver una función:
`bot_digest_destinatarios(7, 1)` contra una firma `(SMALLINT, SMALLINT)` da `42883 function
does not exist`. El tipo de la **columna** y el del **parámetro** son decisiones separadas —
la columna puede seguir en `SMALLINT` y el cast va adentro, en el `INSERT`—. Pasó en la 261,
corregida en la 263: ni `tsc`, ni los tests (que mockean la RPC), ni `deno task check` lo ven,
y el digest se habría quedado mudo sin que fallara nada.

**6. Antes de una migración de datos, fijate qué más depende de esa columna.** Dos cosas
que ya mordieron en la misma migración:
- `trigger_actualizar_saldo_pedido` es `AFTER UPDATE **OF total, monto_pagado**`. Esa
  lista de columnas hace que mover `cliente_id` **no** lo dispare: la reatribución se
  veía hecha y los saldos quedaban sin actualizar. Si tocás una columna, chequeá
  `pg_get_triggerdef` — un `UPDATE OF` no cubre lo que no nombra.
- Las FKs del aislamiento por sucursal son **compuestas** (`pedidos_cliente_id_fkey` es
  `(cliente_id, sucursal_id) → clientes(id, sucursal_id)`). Al recrear una, preservá las
  dos columnas: dejarla simple rompe el aislamiento y no falla nada visible.

**7. Nunca `npm audit fix --force`.** Degrada `exceljs` a 3.4.0 y rompe todos los exports
a Excel. El gate de CI es `--audit-level=high --omit=dev`; los `moderate` conviven a
propósito. Para arreglar un high: `npm audit fix --package-lock-only`.

**8. Un mínimo de pedido no puede ser un CHECK sobre `pedidos.total`.** Parece el lugar
obvio para la compra mínima (mig 204/205), y rompe la cancelación: `cancelar_pedido` pone
`total = 0` (mig 175) y el invariante `VENTA-I` de `auditoria_integridad()` **exige** que un
pedido cancelado tenga total 0 (mig 105). Las dos reglas se contradicen y ningún código lo
dice. Por eso se valida **al crear** —dentro de `crear_pedido_completo` y de
`crear_pedido_completo_bot`— y nunca como constraint ni como trigger sobre el `UPDATE` del
total. Corolario: la política rige el alta, no retroactivamente. Cuando el mínimo sube, los
pedidos viejos por debajo eran legales cuando se crearon y tienen que seguir siéndolo.

## Subagentes: calidad igual, costo mínimo

Al lanzar un subagente (Agent o un `agent()` dentro de un Workflow), el modelo y el esfuerzo se
eligen **por tarea**. Nunca todo en Opus por defecto. No se sacrifica calidad, pero no se paga
Opus por lo que Sonnet hace igual de bien.

- **Sonnet** es el default. Sirve para explorar y relevar, para lotes mecánicos y para escribir o
  revisar tests de caracterización. También para correcciones dirigidas (cuando los hallazgos ya
  dicen qué arreglar), para las lentes de revisión que chequean contra una lista (tests
  debilitados, compuertas, lint, contraste, z-index, archivos fuera de la lista) y para correr
  comandos y reportar.
- **Opus** queda para implementar un paquete estructural o lógica sutil (permisos, dinero,
  estado, varios archivos acoplados), para la lente adversarial de comportamiento y para
  diagnosticar lo que no se entiende o un panel que no converge.
- **Esfuerzo:** `low`/`medium` para lo mecánico, `high` para implementar y revisar, y más sólo si
  el caso lo justifica.
- Si una tarea en Sonnet sale floja, se repite **esa** tarea con Opus; no se sube el modelo de
  todo el flujo.

## Los pendientes van a issues

No crear `PENDIENTES.md` ni "estado del proyecto.md", y no anotar pendientes en memoria
ni en `docs/`. Ninguno de esos lugares tiene un "cerrar", así que nada se da de baja nunca
y terminan contradiciéndose. Un pendiente sin issue es un pendiente perdido.
