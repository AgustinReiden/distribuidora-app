# CLAUDE.md

App de gestión para una distribuidora de alimentos. React 19 + Vite en el front,
Supabase (Postgres + Auth + RLS) en el back, edge functions en Deno.

## Correr y verificar

```bash
npm ci                 # los worktrees nacen sin node_modules — ver Trampas
npm run dev            # Vite
npm run typecheck      # tsc --noEmit
npm run lint           # eslint
npm run test:run       # vitest (~100 archivos, ~1400 tests)
npm run build          # vite build + PWA
```

Antes de dar algo por terminado corré las cuatro: `typecheck`, `lint`, `test:run`, `build`.
El pre-commit ya corre `check-secrets.sh`, `lint-staged` y los tests.

Edge functions (Deno, desde `supabase/functions/`): `deno task check`, `deno task lint`,
`deno task test`.

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
- `src/hooks/supabase/`, `src/hooks/state/` — hooks de datos y de estado
- `src/lib/` — `supabase.ts`, `schemas.ts` (Zod), `offlineDb.ts` (Dexie), `permisos.ts`
- `src/utils/` — lógica pura, es donde van los cálculos testeables
- `migrations/` — SQL numerado. Ver Trampas.
- `supabase/functions/` — edge functions Deno (bot de Telegram, optimizar-ruta)

La política comercial configurable no vive en el código: está en la tabla
`politicas_comerciales` (una fila por sucursal) y se edita en `/configuracion`. Un
parámetro de negocio que cambia va ahí, no en una constante, una env var ni una columna
suelta en `sucursales`.

## Convenciones

- **Nada de refactors de paso.** Un bug que no es el que viniste a arreglar → issue.
- Lógica de negocio en `src/utils/` con tests, no adentro de los componentes.
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
  `completar_origen_precio_item` (148) o `validar_precio_item_pedido`.
  Y una función que **sólo corre desde el server** —una edge function, un cron— se revoca a
  las **tres**: `REVOKE ... FROM PUBLIC, anon, authenticated`. La receta de dos mitades de
  arriba es para las RPCs que el frontend sí llama; aplicada a una función de server deja el
  `GRANT` default a `authenticated` en pie, y el gate **no lo ve** —`check-permisos.mjs`
  falla ante lo alcanzable con la **anon key**, no con una sesión—. Pasó con
  `bot_digest_destinatarios` (261, corregida en la 262): devolvía los `telegram_user_id` de
  todos los admins y cualquier preventista logueado podía enumerarlos.
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
- **Las 4 RPCs de pago son wrappers**: la lógica vive en `<nombre>_impl` (mig 167, por la
  idempotencia). Si editás la RPC y no el `_impl`, no cambia nada y no falla nada.
- Una confirmación disparada desde un modal Radix tiene que renderizarse **dentro** del
  modal. Como hermano en el container queda detrás del overlay y falla en silencio.
- **Toda lectura nueva de `clientes` decide qué hace con los inactivos.** Un cliente con
  pedidos no se puede borrar (la FK es RESTRICT desde la mig 200), así que desactivarlo es la
  única salida y siempre va a haber inactivos. `fetchClientes` filtra `activo = true` por
  defecto (`includeInactivos` para el panel, que es desde donde se reactiva). Lo operativo
  —selectores, rutas, recorridos— los oculta; el historial —reportes, cuenta corriente y los
  embeds `cliente:clientes(*)`— **tiene** que seguir viéndolos, que es de lo que se trata la
  baja lógica. Una consulta que no elige está eligiendo mal por omisión.
- **El stock por lote lo lleva un trigger, no las RPCs.** `trg_lotes_sincronizar` (mig 223)
  consume FEFO y devuelve al lote en cada `UPDATE productos.stock`, leyendo el mismo
  `app.stock_origen` que ya usa el ledger. Un camino nuevo que **baje** stock no tiene que
  tocar `producto_lotes`: el trigger se encarga. Uno que lo **devuelva** —cancelación,
  salvedad, edición a la baja— sí tiene que etiquetarse con un origen de la lista blanca del
  trigger, o esas unidades vuelven a la bolsa "sin vencimiento" en vez de a su lote y el
  contador miente para abajo sin que falle nada. Cinco corolarios que ya mordieron (migs 229,
  234, 328, 331 y 338):
  - **La devolución que se cancela sola NO va etiquetada.** La salvedad por dañado o vencido
    devuelve las unidades y las merma en el mismo movimiento (mig 234). Si esa devolución lleva
    un origen de la lista blanca vuelve al lote por FEFO, pero la bajada de la merma sale de la
    **bolsa** primero —el camino de bajada del trigger no mira el origen—, así que el lote queda
    **+N** y la bolsa **−N** en cada rotura: el mismo contador mintiendo, para arriba. Medido
    con un lote de 100 con 50 vivas y bolsa 40, sobre una línea que salió del lote (con huella):
    con `'salvedad'` el lote termina en 53, con `'salvedad_merma'` en 50. Una línea sin huella
    vuelve a la bolsa desde #1114 con cualquiera de los dos orígenes, pero eso no hace sobrar
    `'salvedad_merma'`: la línea con huella sigue mordiendo. Las dos patas tienen que caer del
    mismo lado del mostrador. La regla de arriba rige la devolución que **queda** devuelta; ésta
    no lo está ni un renglón después. Lo que **sí** se mueve es la huella: la etiqueta no cambia
    y el contador del lote tampoco, pero el cliente ya no tiene esas unidades, así que la huella
    de la línea baja por lo mermado con la regla de la devolución (primero sus lotes, FEFO sobre
    su propia huella). Se anota en `lotes_devueltos` con `cantidad 0` y la huella real, y
    `anular_salvedad` la repone por la rama de #1085 (#1127). Rige para todo camino que devuelva
    y merme en el mismo movimiento: también la cancelación por falta de stock, que borra la
    huella del pedido.
  - `set_config` es **por transacción, no por función**. Una función que setea el origen y la
    llama otra que ya seteó el suyo le pisa la etiqueta al resto del cuerpo del caller. Si es
    un helper con varios llamadores —`revertir_bloques_auto_ajuste` es el caso— tiene que
    **guardar y restaurar** los cuatro GUCs alrededor de su `UPDATE`.
  - **Deshacer una devolución que quedó devuelta saca del lote al que volvió.** El camino de
    bajada del trigger no mira el origen tampoco al anular: un `UPDATE stock - N` pelado come la
    bolsa primero y deja el lote **+N** y la bolsa **−N** (#1050). Por eso `registrar_salvedad`
    anota en `salvedades_items.lotes_devueltos` a qué lote volvió cada unidad, y
    `anular_salvedad` resta de ahí **antes** de bajar el stock —el mismo orden que la 229 le
    dio a la compra cancelada— (migs 328 y 331). Y un ensayo de lotes con **bolsa 0 no prueba
    nada**: sin bolsa, la bajada cae en el lote por FEFO y da bien por casualidad (así se
    escondió el bug en la 316).
  - **Un lote es una identidad: se actualiza, no se borra y recrea.** Todo lo que apunta a un
    lote —la traza `pedido_item_lotes` (CASCADE), la de transferencias (SET NULL), las
    anotaciones de `lotes_devueltos`— se pierde si su fila muere. Hasta la 338
    `sincronizar_lotes_compra` borraba y recreaba los lotes en **cada** edición de la compra y
    se llevaba todo eso (#1054). Ahora actualiza el mismo lote aunque cambie la fecha, y el que
    de verdad desaparece pasa lo consumido, la traza y las anotaciones al lote que queda del
    mismo producto en la compra; si no queda ninguno y tiene traza, queda agotado (cantidad =
    lo que salió, restante 0). Un camino nuevo que "rehaga" lotes tiene que reapuntar así, no
    clonar y borrar. Corolario de la misma idea: la devolución vuelve **primero al lote de donde
    salió** la línea (su huella), y lo que excede la huella salió de la bolsa y vuelve a la
    bolsa (`_restaurar_lotes_fefo`, 338 y 342). FEFO queda sólo para la devolución que no dice
    su línea (a nivel pedido, o que no es de un pedido). Una línea de ese producto sin huella, o
    lo que excede su huella, salió de la bolsa y vuelve a la bolsa: la bajada come la bolsa
    primero, y desde la 349 toda bajada con línea deja huella (el alta desde la 256; la edición
    y el bot recién desde la 349) (#1114). Por eso `registrar_salvedad` devuelve antes de
    recortar o borrar la línea, que con la línea borrada ya no hay huella que mirar.
    Y un camino que **deshace y rehace líneas** —editar el pedido, sustituir o repartir un
    regalo— no devuelve "a su lote": esa devolución se cancela con la bajada que viene después,
    así que va **sin etiquetar** (`'pedido_editado'`, `'sustitucion_regalo_rehecha'`: a la
    bolsa), la bajada lleva **su** línea en `app.stock_pedido_item_id`, y al final
    `_rehacer_huella_lineas` (con la foto de `_foto_huella_lineas`, tomada antes de tocar nada)
    conserva la huella que la cantidad nueva sigue cubriendo y devuelve el resto a su lote
    (#1097): **primero por línea de origen** (bonif, promo, cadena) —una línea que no cambió
    conserva su huella aunque otra del mismo producto baje, aun con un solo lote— y el
    sobrante por producto. Etiquetada, lo que salió de la bolsa volvía a un lote y el lote
    quedaba +N en cada edición; a nivel pedido, le comía la huella a otra línea del mismo
    producto.
  - El gate es el check **STK-F** de `auditoria_integridad()`: falla si una función de `public`
    sube `productos.stock` de forma incremental sin mencionar `app.stock_origen`. Tiene dos
    excepciones listadas a propósito (`registrar_compra_completa`, `registrar_ingreso_sucursal`):
    suben mercadería nueva, que va a la bolsa por diseño. Si agregás una función que sube stock,
    etiquetala o el gate se pone rojo.
    Pero STK-F sólo ve **subidas** y sólo mira el código. En runtime, el check **STK-D** cuenta los
    movimientos nuevos con `origen='auto'` sin referencia (mig 336): cualquier camino que **suba o
    baje** stock sin etiquetar lo pone en rojo. La edición de stock por REST desde la ficha no
    puede setear el GUC, así que `registrar_cambio_stock()` la asienta como `'ajuste_manual'` de
    `auth.uid()` cuando corre como `authenticated` a `pg_trigger_depth() = 1`. Corolario: una
    función que mueve stock **no puede ser `SECURITY INVOKER`**: sin etiqueta se confundiría con
    la ficha y STK-D no la vería.
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
- **El criterio de merma y la cascada de costo viven en una función, no en cada reporte.**
  `mermas_valorizadas(desde, hasta, sucursales)` (mig 238) es la única implementación del
  corte por día argentino, la exclusión de `promociones`/`promociones_reversion` y la
  valuación; `reporte_gerencial` y `reporte_mermas` la **consumen**, y por eso
  `totales.costo == kpis.mermas` cierra por construcción. La cascada sola es
  `costo_valuacion(snapshot, promedio, real, sin_iva, ii)`, y **`IS NULL` sobre ella ES el
  predicado `sin_costo`** — no mires `costo_sin_iva` por tu cuenta, que fue justo el bug de
  #511. Un reporte nuevo que valorice mermas o decida "sin costo" llama a estas dos; si
  reescribís el criterio, el gate `scripts/check-integridad.mjs` se pone rojo.
  **Y no son sólo los reportes: el que ESCRIBE `pedido_items.costo_unitario_al_crear` también
  la llama** (migs 257/258, #673). Eran seis caminos con seis copias inline —y una,
  `sustituir_regalo_pedido`, con `costo_real` pelado, que es un número distinto: 80 de 295
  productos de prod tienen `costo_real <> costo_promedio`—. El gate es el check **COSTO-D** de
  `auditoria_integridad()`: cuenta funciones de `public` que escriben esa columna sin mencionar
  `costo_valuacion`. Corolario del mismo issue: en `actualizar_pedido_items` el costo se
  calcula **después** del `INSERT ... RETURNING producto_id`, con el producto que quedó, porque
  `aplicar_sustituciones_regalo_pre_insert` puede haberlo reescrito al sustituto —la misma
  regla que la 252 le aplicó al stock y al contenedor—.
  Y al agregar un check a `auditoria_integridad()`, **mirá qué ids ya están tomados**: la
  salida es una lista y no un mapa, así que un id repetido no falla ni se nota. La familia
  `COSTO-*` ya iba por la `D` cuando parecía libre desde la `A`.

- **`productos.costo_promedio` no puede ser base de sí mismo.** El promedio vivo ya incluye la
  compra que estás por recalcular; la base es `compra_items.costo_promedio_anterior`, el
  snapshot que guardan `registrar_compra_completa` y `actualizar_compra_items` (mig 236). Sin
  ese snapshot —líneas anteriores a la 236— no se toca el promedio y se avisa: moverlo sin
  saber de dónde arranca lo corre hacia el costo de la última factura en **cada** edición (100
  u. a 10 más 100 u. a 20 dan 15 al registrar y 17,50 tras una edición sin cambios). Y el costo
  de **reposición** (`costo_real` / `costo_sin_iva` / `costo_con_iva`) es otra cosa: sólo lo
  pisa la compra más nueva del producto (`v_es_mas_reciente`), mientras que el stock y el
  promedio suman siempre, venga la factura con la fecha que venga.
- **Cancelar una compra le borra los lotes** (`borrar_lotes_compra_cancelada`, mig 224). Todo
  camino que cancele una compra decide **antes** qué hace con ellos: `anular_compra_atomica`
  cancela primero, para que la bajada de stock no consuma FEFO de lotes ajenos y encima borre
  los propios (229); `cambiar_proveedor_compra` los reapunta al clon antes de cancelar (236,
  #566). Reapuntar y no clonar-y-borrar: `producto_lotes.compra_id` apunta a la compra, no a la
  línea, y así se conserva `cantidad_restante` sin duplicar la suma ni por un instante.
- **`productos` se concede columna por columna y los costos no se leen por REST** (#974).
  `authenticated` y `anon` no tienen `SELECT` sobre la tabla sino sobre una lista de columnas
  sin `costo_real`/`costo_promedio`/`costo_sin_iva`/`costo_con_iva`; esos los da la RPC
  `costos_productos()` sólo a admin y encargado. Tres corolarios: (1) **un `*` sobre productos
  por PostgREST** —`select('*')`, un `.select()` pelado tras insert/update, `productos(*)` en un
  embed— **falla la consulta entera, para todos los roles**: se pide `PRODUCTO_COLUMNAS`
  (`src/lib/productoColumnas.ts`), y lo vigila su test; (2) **una columna nueva de productos nace
  invisible**: su migración la concede (`GRANT SELECT (col) ... TO authenticated`, sin `anon`) y se suma
  a `PRODUCTO_COLUMNAS`; (3) `REVOKE SELECT (col)` sobre un `GRANT` de tabla vigente no hace nada
  —por eso se revocó la tabla—.
- **La cadena de sustituciones de un regalo es de la LÍNEA, no de la promo** (#1057). Cada
  línea de regalo tiene `pedido_items.regalo_cadena_id` y cada eslabón de
  `pedido_item_sustituciones` el `cadena_id` de su línea (NOT NULL, sin default: un camino nuevo
  que inserte un eslabón sin clave falla, a propósito). Las funciones de cadena reciben la clave;
  sin clave, una línea no tiene cadena. **La clave la decide el server**: `sustituir_regalo_pedido`
  la crea, `dividir_regalo_pedido` le da una nueva a cada parte, `crear_pedido_completo` le da una a
  cada parte de un reparto del alta (varias líneas de regalo de una promo) y registra sus filas de
  reparto (#1091), y `actualizar_pedido_items` la
  hereda (`regalo_elemento_con_cadena`) — una que mande el front se descarta. Una línea conservada
  de un reparto se reinserta tal cual (`app.regalo_linea_conservada`): recorrerla de nuevo desde su
  final reconvierte la cantidad. La marca "[Sustituido por: …]" va sólo si el producto no es el
  que describe el texto (`regalo_raiz_descrita`). Las puras tienen espejo en
  `src/utils/repartoRegalo.ts` y el gate de paridad (`cadenaSustitucion.espejo.json`) las corre a
  las dos: si cambiás una, cambiá la otra y sumá el caso.
  Un reparto se conserva al editar si la suma de las **cantidades de corte** de sus líneas
  (`regalo_cantidad_base` / `cantidadBaseDeLinea`: la de la raíz de la clave de cada parte) es lo
  que da la promo, no la suma de las líneas: una parte cambiada por valor queda en la unidad del
  sustituto (#1090). Por eso `dividir_regalo_pedido` no reparte una línea convertida por valor ni
  una parte cuya cantidad ya no es su corte. Y `PROMO-B` no cuenta filas de reparto ni eslabones de
  una cadena sin línea viva.
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
- **Un regalo se mide contra la promo con la que se armó, no contra la vigente** (mig 370,
  #1164). Todo lo que mide el regalo de un pedido que ya existe —la salvedad, su anulación y
  las dos simulaciones— lee `promos_del_pedido(pedido)`, no `promocion_reglas` ni
  `promocion_productos`: es la foto de `pedido_promo_reglas`, y sin foto cae en lo vigente. Si
  mira la promo vigente, editar la promo cambia de forma retroactiva cuántos regalos "le
  tocaban" a pedidos viejos. La foto la toma `trg_capturar_promo_del_pedido` al insertar el
  primer regalo de cada promo del pedido, y se rehace en cada edición (el modal recalcula el
  regalo con la regla vigente); no se rehace al dividir ni al sustituir. La tabla es sólo de
  server: RLS sin policies y sin grants.
- **Un combo son líneas comunes, y un producto puede ir en DOS líneas de venta** (#1191). El
  combo (`combos`, `combo_componentes`) no es un producto: en el pedido son líneas de cada
  producto con `combo_id`, `precio_sin_combo_unitario` y `origen_precio = 'combo'` (lo pone el
  trigger), con el total del combo prorrateado. Lo que queda suelto del mismo producto es otra
  línea. Todo código que asuma una línea de venta por producto tiene que sumar: el pre-chequeo
  de stock de `actualizar_pedido_items` ya suma, y la clave de huella incluye `combo_id`. **El
  front arma y el server valida**: `armarCombos` (`src/utils/combos.ts`) elige los combos y
  `combo_fuera_de_regla` comprueba que sean legítimos (estructura para todo rol; vigencia, tope,
  total y reparto exactos para quien no es admin). Las tres puras que recalcula el server
  (`_combo_total`, `_combo_prorrateo`, `_combo_cantidad`) tienen espejo con gate
  (`combos.espejo.json`): si cambiás una, cambiá la otra. `precio_fuera_de_politica` valida la
  línea de combo por su precio **sin** combo, y saca del conteo de escalas las unidades de un
  combo excluyente. La foto del combo de cada pedido es `pedido_combos`: al editar, un combo que
  el pedido ya tenía se mide contra su foto. Un lugar del combo puede ser una **categoría viva**
  (`combo_componentes.categoria_id`, mig 386): lo que vende lo resuelve `_combo_definicion`, así
  que nada lee `combo_componentes.producto_id` directo; en el front, `resolverLugares`. La
  prioridad es un orden: `guardar_combo` la reescribe con `orden` (`src/utils/comboOrden.ts`).
  La capa de combos va **encima** de
  `orquestarPrecios` (`src/utils/combosPedido.ts`) porque la orquestación es la del bot, que no
  arma combos.
  **La salvedad decide por el motivo** (#1192): con `cliente_rechaza` el combo se rompe
  y lo que se queda vuelve a su precio sin combo **de la foto** (`pedido_combos.precios`); con
  cualquier otro motivo mantiene el precio combo. Si romperlo sube el total, **sube sin tope**:
  es la única excepción a "rechazar sólo baja lo que se paga" (165-168), y por eso el total se
  escribe **una vez** al final (rechazo + recargo), o una boleta cobrada vería la baja y la suba
  por separado. Las unidades de un producto en un combo son un **pozo** de hasta dos líneas: la
  del combo y la que salió de él (`combo_roto_id`). `_combo_rehacer` es función del **estado**
  (armados, rechazos del cliente vivos, lo que hay), no de la historia: todo camino que cambie
  líneas de combo después del alta —salvedad, anulación— lo llama, y por eso anular en
  cualquier orden deja el pedido como si la salvedad no hubiera existido. El recargo va aparte
  de `monto_afectado` (`salvedades_items.recargo_combo`); el gate es **COMBO-B**.
- **La promo de un pedido se mide en `LEAST(fecha del pedido, hoy)`**, en el alta y en la
  edición, en el front y en el server (#1152). En el front lo calcula `fechaReferenciaPromo`
  (`src/utils/fechaReferenciaPromo.ts`): para hoy o una fecha futura devuelve `undefined`, que
  usa el cache de hoy. En el server, el `v_d` de `regalo_fuera_de_promo` y el de
  `combo_fuera_de_regla` (#1260), que aceptan además "o en hoy" a propósito, para no ser nunca
  más estricto que el front. Un camino nuevo que resuelva las promos o los combos de un pedido
  usa esa función, no `pedido.fecha` pelado ni `undefined` (`ModalCambiarCliente` usaba
  `pedido.fecha`). En el alta son dos llamadores (`ModalPedido` muestra, `PedidosContainer`
  guarda y encola), y tienen que pedir la misma fecha.
- **El límite de usos de una promo cuenta unidades de regalo y lo hace cumplir un trigger**
  (#1261). `trg_limite_usos_promo`, constraint trigger diferido sobre `pedido_items`, suma al
  confirmar las unidades de regalo de la promo en los pedidos no cancelados (subunidades en una
  promo con fracción), con la promo bloqueada, y rechaza si pasan `limite_usos`; el admin no
  está exento. Un camino nuevo que escriba regalos no cuenta nada: lo cubre el trigger. El
  límite no se puede bajar por debajo de lo ya regalado (`trg_limite_usos_no_baja`): así el
  conteo nunca arranca pasado y sólo se rechaza lo que suma, nunca una salvedad o una edición
  que no agrega. Y `usos_pendientes` no es ese conteo: en una promo con fracción es el resto de
  la barra.

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
