# Reglas de SQL: stock, costos, compras, regalos y combos

Se carga al trabajar con archivos de `migrations/`. Son reglas que sólo importan al escribir o
cambiar funciones SQL; el `CLAUDE.md` de la raíz deja una línea por cada una que apunta acá.
Si vas a escribir o aplicar SQL de estos temas sin abrir esta carpeta, leé este archivo antes.

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
    movimientos nuevos con `origen='auto'` sin referencia (mig 336), y es `high` desde la 402
    (#1256): antes era `info` y no hacía fallar nada. Cualquier camino que **suba o baje** stock sin
    etiquetar pone rojo el gate diario (`integridad.yml`) **cuando corre en prod**, no cuando se
    aplica la migración. Se arregla etiquetando el camino y subiendo, en la misma migración, el piso
    de id del check a la última fila `'auto'` que dejó. La edición de stock por REST desde la ficha no
    puede setear el GUC, así que `registrar_cambio_stock()` la asienta como `'ajuste_manual'` de
    `auth.uid()` cuando corre como `authenticated` a `pg_trigger_depth() = 1`. Corolario: una
    función que mueve stock **no puede ser `SECURITY INVOKER`**: sin etiqueta se confundiría con
    la ficha y STK-D no la vería.
  - **El orden de locks es producto antes que lote, y productos por id ascendente** (#1255): es el
    de la venta, que bloquea los productos y deja que el trigger baje después a sus lotes. Una
    función que toca un lote lee su `producto_id` sin lock, bloquea el producto `FOR UPDATE` y
    recién ahí relee el lote bloqueado (`dar_de_baja_lote`, `ajustar_lote`); una que mueve varios
    productos los bloquea todos juntos `ORDER BY id` antes del primer `UPDATE` o del primer lock de
    lotes (`aplicar_control_stock`, `sincronizar_lotes_compra`). Al revés, contra una venta con la
    bolsa en 0, es un 40P01.
  - **El último movimiento de un producto es el de mayor `id`, no el de `created_at` más nuevo**
    (STK-A, #1256): `created_at` es la hora de inicio de la transacción, y dos cajas en el mismo
    milisegundo quedan desordenadas. La excepción es lo importado de Taco Pozo (`tp_import_id`):
    tiene la fecha del sistema viejo y los ids al revés, y siempre precede a lo vivo.
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
  Desde la mig 407 (#1251/#1252) la base es la **foto del alta entera**: `stock_anterior` y
  `costo_promedio_anterior` de la primera línea del producto, no el stock de hoy, y la edición
  no la pisa. Editar o anular corrige el promedio **por diferencia**: lo que dejan las líneas
  nuevas menos lo que dejaban las viejas, desde la misma foto, arrastrado por las compras que
  entraron después (`_cpp_arrastrar`) y sumado al vivo, así una corrección a mano en la ficha
  sobrevive. La cuenta de una línea es **una** función, `_cpp_linea`, la del alta. El lugar de
  una línea en la cadena es su `created_at`: la edición y el clon de `cambiar_proveedor_compra`
  lo conservan, y un camino nuevo que rehaga líneas de compra también. "Más nueva" para la
  reposición es por `(fecha_compra, id)` y sin regalos (`_ninguna_compra_mas_nueva`), y una B o
  C deja `ultimo_tipo_compra = 'FC B'` / `'FC C'`, que la ficha costea como lo pagado.
- **Cancelar una compra le borra los lotes** (`borrar_lotes_compra_cancelada`, mig 224). Todo
  camino que cancele una compra decide **antes** qué hace con ellos: `anular_compra_atomica`
  cancela primero, para que la bajada de stock no consuma FEFO de lotes ajenos y encima borre
  los propios (229); `cambiar_proveedor_compra` los reapunta al clon antes de cancelar (236,
  #566). Reapuntar y no clonar-y-borrar: `producto_lotes.compra_id` apunta a la compra, no a la
  línea, y así se conserva `cantidad_restante` sin duplicar la suma ni por un instante.
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
- **El límite de usos de una promo cuenta unidades de regalo y lo hace cumplir un trigger**
  (#1261). `trg_limite_usos_promo`, constraint trigger diferido sobre `pedido_items`, suma al
  confirmar las unidades de regalo de la promo en los pedidos no cancelados (subunidades en una
  promo con fracción), con la promo bloqueada, y rechaza si pasan `limite_usos`; el admin no
  está exento. Un camino nuevo que escriba regalos no cuenta nada: lo cubre el trigger. El
  límite no se puede bajar por debajo de lo ya regalado (`trg_limite_usos_no_baja`): así el
  conteo nunca arranca pasado y sólo se rechaza lo que suma, nunca una salvedad o una edición
  que no agrega. Y `usos_pendientes` no es ese conteo: en una promo con fracción es el resto de
  la barra.
