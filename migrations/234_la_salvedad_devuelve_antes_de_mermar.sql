-- =========================================================================
-- 234_la_salvedad_devuelve_antes_de_mermar.sql
--
-- Tres agujeros de la entrega con salvedad, más una convergencia de firmas.
--
-- 1) La salvedad por dañado/vencido descontaba el stock DOS veces.
--    Las unidades ya habían salido de `productos.stock` al crear el pedido.
--    `registrar_salvedad` no las devuelve para esos dos motivos
--    (`v_stock_devuelto` queda en false) y además inserta la merma y hace
--    `UPDATE productos SET stock = GREATEST(stock - cantidad, 0)`. O sea que
--    la merma las descuenta de nuevo. En prod: 7 salvedades por dañado (16 u.)
--    y 2 por vencido (3 u.) = 19 unidades de stock fantasma.
--    Fix (decisión D-7 del plan): devolver primero y mermar después. Neto 0
--    sobre `productos.stock` y una fila de `mermas_stock` coherente con
--    MERMA-B, medida contra el stock ya devuelto.
--
--    Con una vuelta de tuerca sobre lo que decía el plan: la devolución **no**
--    se etiqueta con un origen de la lista blanca de `trg_lotes_sincronizar`.
--    Whitelistearla la manda al lote por FEFO, pero la bajada de la merma sale
--    de la bolsa primero, y el lote termina +N y la bolsa −N en cada salvedad
--    por rotura. Medido contra prod con un lote sintético (100 cargadas, 50
--    vivas, bolsa 40): con `'salvedad'` el lote va 50 → 53 → **53**; con el
--    origen de acá va 50 → 50 → **50**. Estas unidades no vuelven a la góndola,
--    se rompen en el mismo movimiento, así que las dos patas tienen que caer
--    del mismo lado del mostrador. Hoy `producto_lotes` está vacía en prod, así
--    que el desfase sería latente hasta el primer lote cargado.
--
-- 2) `anular_salvedad` no revierte lo que `registrar_salvedad` le hizo a la
--    promoción. Al crear la salvedad se llama hasta dos veces a
--    `revertir_bloques_auto_ajuste`, se recortan o borran las líneas de regalo
--    y se devuelve el stock del contenedor. Anular restituye la línea y los
--    totales y nada de eso: `usos_pendientes` queda bajo y el contenedor con un
--    fardo de más. Rehacerlo en sentido de alta es otra función.
--    Fix: la anulación que tocaría promociones se RECHAZA con un mensaje claro
--    en vez de descuadrar la promo en silencio. Ver §2 para el alcance real.
--
-- 3) Una salvedad que baja `pedidos.total` dejaba `/recorridos` mintiendo.
--    `recorridos.total_facturado` sólo lo escriben `aplicar_orden_ruta` (088) y
--    `recalcular_recorrido` (180, sin callers en el front). El trigger
--    `trigger_actualizar_recorrido_entrega` es `AFTER UPDATE OF estado,
--    monto_pagado`, así que un cambio de `total` no lo despierta, y
--    VistaRecorridos muestra "Pendiente" = facturado − cobrado inflado. Hoy hay
--    18 de 123 recorridos desfasados.
--    Fix: `total` entra en la lista del `UPDATE OF` y el cuerpo recalcula
--    `total_facturado` junto a los dos contadores que ya recalculaba.
--
-- 4) La sobrecarga de 7 args de `registrar_salvedad` ya no la usa nadie
--    (FE-15 borró el método de `useSalvedades`; el único caller,
--    PedidosContainer.tsx:1830, pasa los 8). Se dropea por si algún entorno la
--    tiene: dos sobrecargas con rangos [4,7] y [4,8] superpuestos son
--    `PGRST203` en runtime, invisible para `tsc` y para los tests (Trampa 5).
--    En prod ya hay una sola firma, así que el DROP es convergencia, no fix.
--
-- Parche por ancla sobre el cuerpo VIVO, como la 227: `migrations/` no es
-- espejo y estas funciones vienen parchadas por varias migraciones. Un
-- `CREATE OR REPLACE` armado desde el archivo del repo borraría esos parches en
-- silencio — de hecho el 174 del repo ya está 75 y 30 caracteres atrás de prod.
--
-- Idempotente salvo el DROP de la sobrecarga, que es `IF EXISTS`.
-- =========================================================================

CREATE OR REPLACE FUNCTION public._mig_salvedad_reemplazar_ancla(
  p_funcion regprocedure,
  p_ancla   text,
  p_nuevo   text
)
RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text;
  v_veces int;
BEGIN
  v_def := pg_get_functiondef(p_funcion);
  v_veces := (length(v_def) - length(replace(v_def, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El ancla aparece % veces en % (se esperaba exactamente 1). El cuerpo vivo cambio: revisar a mano.',
      v_veces, p_funcion;
  END IF;
  EXECUTE replace(v_def, p_ancla, p_nuevo);
END;
$fn$;

-- -------------------------------------------------------------------------
-- 1 · registrar_salvedad: devolver y despues mermar.
-- -------------------------------------------------------------------------
DO $patch$
DECLARE v_fn regprocedure;
BEGIN
  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace AND p.proname='registrar_salvedad'
     AND p.pronargs = 8;

  -- 1.a) una variable para el id de la merma: el ledger la necesita.
  PERFORM public._mig_salvedad_reemplazar_ancla(v_fn,
    E'  v_tipo_factura          TEXT;\nBEGIN\n',
    E'  v_tipo_factura          TEXT;\n'
    || E'  v_merma_id              BIGINT;\nBEGIN\n');

  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace AND p.proname='registrar_salvedad'
     AND p.pronargs = 8;

  -- 1.b) la devolucion, antes de leer el stock para la merma.
  PERFORM public._mig_salvedad_reemplazar_ancla(v_fn,
    E'  IF p_motivo IN (''producto_danado'', ''producto_vencido'') AND v_mueve_stock THEN\n'
    || E'    SELECT stock INTO v_stock_actual\n',
    E'  IF p_motivo IN (''producto_danado'', ''producto_vencido'') AND v_mueve_stock THEN\n'
    || E'    /* mig 234: las unidades ya habian salido del stock al crear el pedido.\n'
    || E'       La merma sola las descontaba una SEGUNDA vez (19 unidades de stock\n'
    || E'       fantasma en prod). Ahora se devuelven primero y se merman despues:\n'
    || E'       neto 0 sobre productos.stock y una fila de mermas_stock medida\n'
    || E'       contra el stock ya devuelto, que es lo que pide MERMA-B.\n'
    || E'\n'
    || E'       El origen de ESTA devolucion queda a proposito FUERA de la lista\n'
    || E'       blanca de trg_lotes_sincronizar (223/229). Con un origen\n'
    || E'       whitelisteado la devolucion vuelve al lote por FEFO, pero la bajada\n'
    || E'       de la merma sale de la bolsa primero, asi que el lote termina +N y\n'
    || E'       la bolsa -N en cada salvedad por rotura. Medido en prod con un lote\n'
    || E'       sintetico: 50 -> 53 -> 53 con ''salvedad'', 50 -> 50 -> 50 con este\n'
    || E'       origen. Estas unidades no vuelven a la gondola -- se rompen en el\n'
    || E'       mismo movimiento --, asi que las dos patas tienen que caer del mismo\n'
    || E'       lado del mostrador. La regla de CLAUDE.md (toda devolucion va\n'
    || E'       etiquetada) sigue valiendo para la devolucion que SI queda devuelta. */\n'
    || E'    PERFORM set_config(''app.stock_origen'', ''salvedad_merma'', true);\n'
    || E'\n'
    || E'    UPDATE productos\n'
    || E'       SET stock = stock + p_cantidad_afectada\n'
    || E'     WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;\n'
    || E'\n'
    || E'    SELECT stock INTO v_stock_actual\n');

  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace AND p.proname='registrar_salvedad'
     AND p.pronargs = 8;

  -- 1.c) la baja se etiqueta como merma, y despues se restaura la etiqueta.
  PERFORM public._mig_salvedad_reemplazar_ancla(v_fn,
    E'      v_stock_actual, GREATEST(v_stock_actual - p_cantidad_afectada, 0), v_usuario_id, v_sucursal\n'
    || E'    );\n'
    || E'\n'
    || E'    UPDATE productos\n'
    || E'       SET stock = GREATEST(stock - p_cantidad_afectada, 0)\n'
    || E'     WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;\n'
    || E'\n'
    || E'    v_merma_registrada := TRUE;\n',
    E'      v_stock_actual, GREATEST(v_stock_actual - p_cantidad_afectada, 0), v_usuario_id, v_sucursal\n'
    || E'    ) RETURNING id INTO v_merma_id;\n'
    || E'\n'
    || E'    -- La bajada es una merma, no una salvedad: el ledger tiene que decir eso\n'
    || E'    -- y apuntar a la fila de mermas_stock, igual que registrar_merma_manual\n'
    || E'    -- (mig 232).\n'
    || E'    PERFORM set_config(''app.stock_origen'',   ''merma'',          true);\n'
    || E'    PERFORM set_config(''app.stock_ref_tipo'', ''mermas_stock'',   true);\n'
    || E'    PERFORM set_config(''app.stock_ref_id'',   v_merma_id::TEXT,  true);\n'
    || E'\n'
    || E'    UPDATE productos\n'
    || E'       SET stock = GREATEST(stock - p_cantidad_afectada, 0)\n'
    || E'     WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;\n'
    || E'\n'
    || E'    -- set_config es por TRANSACCION, no por funcion (mig 229): dejar la\n'
    || E'    -- etiqueta en ''merma'' le mentiria a cualquier movimiento posterior de\n'
    || E'    -- este mismo caller. Se restaura la de la salvedad.\n'
    || E'    PERFORM set_config(''app.stock_origen'',   ''salvedad'',        true);\n'
    || E'    PERFORM set_config(''app.stock_ref_tipo'', ''pedido'',          true);\n'
    || E'    PERFORM set_config(''app.stock_ref_id'',   p_pedido_id::TEXT, true);\n'
    || E'\n'
    || E'    v_merma_registrada := TRUE;\n');
END
$patch$;

-- -------------------------------------------------------------------------
-- 2 · anular_salvedad: rechazar lo que descuadraria una promo.
--
--     registrar_salvedad toca estado de promociones en dos casos:
--       (a) la salvedad es sobre la linea de regalo misma, o
--       (b) al caer el disparador, la resincronizacion recorta o borra el
--           regalo, devuelve el stock del contenedor y baja usos_pendientes.
--     El (b) no queda anotado en salvedades_items, asi que al anular se
--     detecta por la via espejo: si restituir cantidad_afectada cambia la
--     cantidad de BLOQUES de alguna promo que incluye a este producto,
--     entonces el regalo habria que reponerlo y el contenedor volver a
--     consumirlo. Eso es aplicar_uso_promo_acumulador en sentido de alta mas
--     un re-sync hacia arriba, y no existe todavia.
--
--     Alcance medido en prod: 38 de 251 salvedades caen en la regla (15%).
--     Ninguna se anulo nunca (0 anulaciones en la vida del sistema) y
--     anular_salvedad no tiene ningun caller en src/ — el boton "Anulada" de
--     ModalResolverSalvedad va por resolver_salvedad, que solo cambia la
--     etiqueta. O sea que hoy el rechazo no le saca nada a nadie.
-- -------------------------------------------------------------------------
DO $patch$
DECLARE v_fn regprocedure;
BEGIN
  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace AND p.proname='anular_salvedad';

  PERFORM public._mig_salvedad_reemplazar_ancla(v_fn,
    E'  v_neto NUMERIC; v_iva NUMERIC; v_real NUMERIC;\nBEGIN\n',
    E'  v_neto NUMERIC; v_iva NUMERIC; v_real NUMERIC;\n'
    || E'  v_toca_promo BOOLEAN;\nBEGIN\n');

  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace AND p.proname='anular_salvedad';

  PERFORM public._mig_salvedad_reemplazar_ancla(v_fn,
    E'  IF v_salvedad.estado_resolucion = ''anulada'' THEN\n'
    || E'    RETURN jsonb_build_object(''success'', false, ''error'', ''Ya anulada'');\n'
    || E'  END IF;\n',
    E'  IF v_salvedad.estado_resolucion = ''anulada'' THEN\n'
    || E'    RETURN jsonb_build_object(''success'', false, ''error'', ''Ya anulada'');\n'
    || E'  END IF;\n'
    || E'\n'
    || E'  /* mig 234: registrar_salvedad toca estado de promociones (usos_pendientes,\n'
    || E'     stock del contenedor, la linea de regalo) y anular no lo revierte. Hasta\n'
    || E'     que exista el camino de alta, la anulacion que tocaria una promo se\n'
    || E'     rechaza: descuadrarla en silencio es peor que no poder anular. */\n'
    || E'  IF COALESCE(v_salvedad.es_bonificacion, FALSE) AND v_salvedad.promocion_id IS NOT NULL THEN\n'
    || E'    RETURN jsonb_build_object(\n'
    || E'      ''success'', false,\n'
    || E'      ''error'', ''Esta salvedad es sobre un regalo de promocion. Anularla tendria que reponer el regalo y volver a consumir el contenedor, y ese camino no existe todavia: corregir a mano.'',\n'
    || E'      ''codigo'', ''anulacion_toca_promociones''\n'
    || E'    );\n'
    || E'  END IF;\n'
    || E'\n'
    || E'  WITH promos AS (\n'
    || E'    SELECT pr.id,\n'
    || E'           MAX(CASE WHEN r.clave = ''cantidad_compra''       THEN r.valor END)::INT AS cant_compra,\n'
    || E'           MAX(CASE WHEN r.clave = ''cantidad_bonificacion'' THEN r.valor END)::INT AS cant_bonif\n'
    || E'      FROM promociones pr\n'
    || E'      JOIN promocion_productos pp\n'
    || E'        ON pp.promocion_id = pr.id AND pp.producto_id = v_salvedad.producto_id\n'
    || E'      LEFT JOIN promocion_reglas r ON r.promocion_id = pr.id\n'
    || E'     WHERE pr.sucursal_id = v_sucursal\n'
    || E'     GROUP BY pr.id\n'
    || E'  ), disparadores AS (\n'
    || E'    SELECT pm.cant_compra,\n'
    || E'           (SELECT COALESCE(SUM(pi.cantidad), 0)::INT\n'
    || E'              FROM pedido_items pi\n'
    || E'              JOIN promocion_productos pp2\n'
    || E'                ON pp2.producto_id = pi.producto_id\n'
    || E'               AND pp2.promocion_id = pm.id\n'
    || E'             WHERE pi.pedido_id   = v_salvedad.pedido_id\n'
    || E'               AND pi.sucursal_id = v_sucursal\n'
    || E'               AND COALESCE(pi.es_bonificacion, FALSE) = FALSE) AS qty\n'
    || E'      FROM promos pm\n'
    || E'     WHERE pm.cant_compra > 0 AND pm.cant_bonif > 0\n'
    || E'  )\n'
    || E'  SELECT EXISTS (\n'
    || E'    SELECT 1 FROM disparadores\n'
    || E'     WHERE (qty + v_salvedad.cantidad_afectada) / cant_compra <> qty / cant_compra\n'
    || E'  ) INTO v_toca_promo;\n'
    || E'\n'
    || E'  IF v_toca_promo THEN\n'
    || E'    RETURN jsonb_build_object(\n'
    || E'      ''success'', false,\n'
    || E'      ''error'', ''Restituir esta linea vuelve a dar derecho a un regalo de promocion que la salvedad habia recortado. Reponerlo y volver a consumir el contenedor no esta implementado: corregir a mano.'',\n'
    || E'      ''codigo'', ''anulacion_toca_promociones''\n'
    || E'    );\n'
    || E'  END IF;\n');
END
$patch$;

-- -------------------------------------------------------------------------
-- 3 · El recorrido se entera de que bajo el total.
--
--     No se llama a recalcular_recorrido(): esa funcion exige
--     es_encargado_o_admin() y el trigger corre en la transaccion del
--     transportista que marca la entrega, asi que la entrega entera reventaria
--     con 42501. Se recalcula total_facturado in situ, con la misma subconsulta
--     que el trigger ya usaba para los otros dos contadores.
--
--     total_pedidos queda afuera a proposito: lo mueve recorrido_pedidos, que
--     este trigger no observa. Para eso esta recalcular_recorrido, que ahora
--     tiene boton en /recorridos.
-- -------------------------------------------------------------------------
DO $patch$
DECLARE v_fn regprocedure;
BEGIN
  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace AND p.proname='actualizar_recorrido_entrega';

  PERFORM public._mig_salvedad_reemplazar_ancla(v_fn,
    E'    UPDATE recorridos r\n'
    || E'    SET pedidos_entregados = sub.entregados,\n'
    || E'        total_cobrado      = sub.cobrado\n'
    || E'    FROM (\n'
    || E'      SELECT COUNT(*) FILTER (WHERE p.estado = ''entregado'')                        AS entregados,\n'
    || E'             COALESCE(SUM(p.monto_pagado) FILTER (WHERE p.estado = ''entregado''), 0) AS cobrado\n',
    E'    UPDATE recorridos r\n'
    || E'    SET pedidos_entregados = sub.entregados,\n'
    || E'        total_cobrado      = sub.cobrado,\n'
    || E'        -- mig 234: una salvedad baja pedidos.total y el recorrido no se\n'
    || E'        -- enteraba, asi que /recorridos mostraba "Pendiente" inflado\n'
    || E'        -- (facturado - cobrado). Es recalculo desde las paradas, no delta.\n'
    || E'        total_facturado    = sub.facturado\n'
    || E'    FROM (\n'
    || E'      SELECT COUNT(*) FILTER (WHERE p.estado = ''entregado'')                        AS entregados,\n'
    || E'             COALESCE(SUM(p.monto_pagado) FILTER (WHERE p.estado = ''entregado''), 0) AS cobrado,\n'
    || E'             COALESCE(SUM(p.total), 0)                                              AS facturado\n');
END
$patch$;

-- `total` entra en la lista: un `UPDATE OF` no cubre lo que no nombra (Trampa 6).
DROP TRIGGER IF EXISTS trigger_actualizar_recorrido_entrega ON public.pedidos;
CREATE TRIGGER trigger_actualizar_recorrido_entrega
  AFTER UPDATE OF estado, monto_pagado, total ON public.pedidos
  FOR EACH ROW EXECUTE FUNCTION public.actualizar_recorrido_entrega();

-- -------------------------------------------------------------------------
-- 4 · Una sola firma de registrar_salvedad (Trampa 5).
-- -------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.registrar_salvedad(
  bigint, bigint, integer, character varying, text, text, boolean);

DROP FUNCTION public._mig_salvedad_reemplazar_ancla(regprocedure, text, text);

-- -------------------------------------------------------------------------
-- 5 · Permisos. Toda funcion de public nace con EXECUTE para PUBLIC y Supabase
--     se lo concede a anon por separado: hay que revocar las dos mitades.
--     `actualizar_recorrido_entrega` es funcion de TRIGGER: no necesita EXECUTE
--     para nadie, la invoca el executor como parte del DML.
-- -------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.registrar_salvedad(
  bigint, bigint, integer, character varying, text, text, boolean, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_salvedad(
  bigint, bigint, integer, character varying, text, text, boolean, uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.anular_salvedad(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.anular_salvedad(bigint, text) TO authenticated;

REVOKE ALL ON FUNCTION public.recalcular_recorrido(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.recalcular_recorrido(bigint) TO authenticated;

COMMENT ON FUNCTION public.registrar_salvedad(
  bigint, bigint, integer, character varying, text, text, boolean, uuid) IS
  'Registra una salvedad de entrega. Por dañado/vencido devuelve el stock y recién '
  'después lo merma: neto 0 sobre productos.stock y mermas_stock coherente con MERMA-B '
  '(mig 234). Acepta líneas de bonificación y libera usos_pendientes. Mig 174/227/234.';

COMMENT ON FUNCTION public.anular_salvedad(bigint, text) IS
  'Restituye la línea, los totales y el stock de una salvedad. Rechaza la anulación que '
  'volvería a dar derecho a un regalo de promoción: reponerlo no está implementado y '
  'descuadrar la promo en silencio es peor. Mig 174/227/234.';

-- -------------------------------------------------------------------------
-- 6 · Las 19 unidades históricas NO se corrigen acá. Es una decisión, no un
--     olvido: un `UPDATE` a ciegas estaría mal en 13 de las 19.
--
--       salv  producto                          u  fecha        stock hoy  conteo posterior
--         51  PLACER POMELO BLANCO 1,5 LT       1  2026-05-05           0  no
--         77  FIDEO COTELLA MOÑO MEDIANO 500G   7  2026-05-26           0  SÍ
--         90  MANAOS MANZANA 3000CC X 6         1  2026-06-04           1  SÍ
--         91  MANAOS MANZANA 3000CC X 6         1  2026-06-04           1  SÍ
--        134  CHIZITOS 200GRS X UND             4  2026-07-07         172  no
--        149  MAIZ INFLADO 1KG (TUTUCA)         1  2026-07-14          37  no
--        228  COCA COLA X 2.25LTS X 6UND        2  2026-08-11           0  no
--        230  COCA COLA X 2.25LTS X 6UND        1  2026-08-11           0  no
--        246  AZUCAR x 1 kg x 10 u              1  2026-08-18          48  no
--
--     Nueve unidades (77, 90, 91) tuvieron un conteo físico posterior, que ya
--     absorbió el desfase: sumarlas de nuevo lo rompe para el otro lado. Cuatro
--     más (51, 228, 230) están sobre productos que hoy están en cero, y
--     resucitarles stock inventa mercadería que nadie tiene en el depósito. Las
--     seis restantes son de productos con meses de movimiento encima, donde el
--     desfase también pudo haberse absorbido sin dejar rastro.
--     Quedan para el próximo conteo físico, que es el único que las puede
--     separar del resto de la deriva. Lo que sí queda arreglado es que desde
--     hoy no se generan más.
-- -------------------------------------------------------------------------

-- -------------------------------------------------------------------------
-- 7 · Verificacion.
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  v_def text;
  v_n   int;
BEGIN
  SELECT count(*) INTO v_n FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace AND p.proname='registrar_salvedad';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'registrar_salvedad tiene % firmas (se esperaba 1): riesgo PGRST203', v_n;
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace AND p.proname='registrar_salvedad';
  IF v_def NOT LIKE '%SET stock = stock + p_cantidad_afectada%RETURNING id INTO v_merma_id%' THEN
    RAISE EXCEPTION 'registrar_salvedad no quedo con la devolucion antes de la merma';
  END IF;
  -- La devolucion de la merma no puede estar whitelisteada en el trigger de
  -- lotes: si lo estuviera, el lote quedaria +N y la bolsa -N en cada rotura.
  IF v_def NOT LIKE '%''salvedad_merma''%' THEN
    RAISE EXCEPTION 'la devolucion previa a la merma perdio su origen propio';
  END IF;
  IF v_def NOT LIKE '%app.stock_origen%' THEN
    RAISE EXCEPTION 'registrar_salvedad sube stock sin declarar app.stock_origen: STK-F en rojo';
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace AND p.proname='anular_salvedad';
  IF v_def NOT LIKE '%anulacion_toca_promociones%' THEN
    RAISE EXCEPTION 'anular_salvedad no quedo con el rechazo por promociones';
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace AND p.proname='actualizar_recorrido_entrega';
  IF v_def NOT LIKE '%total_facturado    = sub.facturado%' THEN
    RAISE EXCEPTION 'actualizar_recorrido_entrega no recalcula total_facturado';
  END IF;

  SELECT count(*) INTO v_n FROM pg_trigger t
   WHERE t.tgrelid='public.pedidos'::regclass
     AND t.tgname='trigger_actualizar_recorrido_entrega'
     AND pg_get_triggerdef(t.oid) LIKE '%UPDATE OF estado, monto_pagado, total%';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'el trigger de recorrido no quedo con total en la lista del UPDATE OF';
  END IF;

  -- Ninguna de las tres alcanzable con la anon key (check-permisos.mjs).
  SELECT count(*) INTO v_n FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace
     AND p.proname IN ('registrar_salvedad','anular_salvedad','recalcular_recorrido')
     AND (has_function_privilege('anon', p.oid, 'EXECUTE')
          OR has_function_privilege('public', p.oid, 'EXECUTE'));
  IF v_n <> 0 THEN
    RAISE EXCEPTION '% funciones de salvedad/recorrido siguen alcanzables con la anon key', v_n;
  END IF;
END
$verif$;
