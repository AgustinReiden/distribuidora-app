-- 431b · La salvedad, su anulación y la cancelación leen la foto y miran la caja
-- (#1324, #1325, #1327, #1375). El motivo de cada cambio está en 431a.

BEGIN;

-- ---------------------------------------------------------------------------
-- Premisas: nada cambió en prod desde que se leyeron los cuerpos
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, md5(pg_get_functiondef(x.firma::regprocedure)) AS md5_vivo
      FROM (VALUES
        ('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)',
         'b4ef24fd069587ef38b39cb9a7837df3'),
        ('public.anular_salvedad(bigint,text)',
         'ca3168c465cb4e15104747359f1edf2c'),
        ('public.cancelar_pedido_con_stock(bigint,text,uuid,text)',
         'fbeda96edc1b739286897aef87b36f8b'),
        ('public.eliminar_pedido_completo(bigint,uuid,text,boolean)',
         'd00b89816c48e52e795d113c5b0493a2')
      ) AS x(firma, md5)
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION 'mig 431b · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- Parches por ancla
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _n_parche (firma text, orden int, ancla text, reemplazo text, veces int DEFAULT 1) ON COMMIT DROP;

INSERT INTO _n_parche (firma, orden, ancla, reemplazo) VALUES
('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)', 1,
$a$  v_recargo_combo         NUMERIC;
BEGIN
$a$,
$r$  v_recargo_combo         NUMERIC;
  -- #1327: el mensaje del guard de caja.
  v_caja_cerrada          TEXT;
BEGIN
$r$),

('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)', 2,
$a$  SELECT pi.id, pi.producto_id, pi.cantidad, pi.precio_unitario, pi.subtotal,
         COALESCE(pi.es_bonificacion, FALSE) AS es_bonificacion, pi.promocion_id,
         pi.combo_id, pi.combo_roto_id
    INTO v_item
    FROM pedido_items pi
   WHERE pi.id = p_pedido_item_id
     AND pi.pedido_id = p_pedido_id
$a$,
$r$  -- #1327: un dia con la caja cerrada no cambia: ni el total, ni el stock. Va
  -- despues del reintento idempotente: la salvedad que entro antes del cierre
  -- sigue contestando lo que hizo.
  v_caja_cerrada := public._pedido_en_caja_cerrada(p_pedido_id, v_sucursal);
  IF v_caja_cerrada IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error', v_caja_cerrada, 'codigo', 'caja_cerrada');
  END IF;

  SELECT pi.id, pi.producto_id, pi.cantidad, pi.precio_unitario, pi.subtotal,
         COALESCE(pi.es_bonificacion, FALSE) AS es_bonificacion, pi.promocion_id,
         pi.combo_id, pi.combo_roto_id
    INTO v_item
    FROM pedido_items pi
   WHERE pi.id = p_pedido_item_id
     AND pi.pedido_id = p_pedido_id
$r$),

('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)', 3,
$a$    SELECT COALESCE(pr.regalo_mueve_stock, FALSE) INTO v_mueve_stock
      FROM promociones pr
     WHERE pr.id = v_item.promocion_id AND pr.sucursal_id = v_sucursal;
    v_mueve_stock := COALESCE(v_mueve_stock, FALSE);
$a$,
$r$    -- #1324: el modo con el que salio de este pedido, no el de la promo de hoy.
    v_mueve_stock := COALESCE(public._regalo_modo_del_pedido(p_pedido_id, v_item.promocion_id, v_sucursal), FALSE);
$r$),

('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)', 4,
$a$  IF v_es_bonif AND v_item.promocion_id IS NOT NULL THEN
    -- mig 294 (#840): las botellas restan de la barra de ESE sabor.
$a$,
$r$  IF v_es_bonif AND v_item.promocion_id IS NOT NULL
     AND public._regalo_barra_vale(p_pedido_id, v_item.promocion_id, v_sucursal) THEN
    -- mig 294 (#840): las botellas restan de la barra de ESE sabor.
$r$),

('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)', 5,
$a$    SELECT pi.promocion_id, SUM(pi.cantidad)::INT AS total_bonif,
$a$,
$r$    -- #1325: en cortes, la unidad de la promo. Una linea cambiada por valor esta
    -- en la unidad del sustituto, y comparar P×19 contra lo que da la promo dejaba
    -- de mas.
    SELECT pi.promocion_id,
           SUM(public.regalo_usos_de_linea(
                 CASE WHEN pi.regalo_cadena_id IS NOT NULL
                      THEN public.regalo_eslabones(p_pedido_id, pi.promocion_id, v_sucursal) END,
                 pi.regalo_cadena_id, pi.cantidad))::INT AS total_bonif,
$r$),

('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)', 6,
$a$      FOR v_bonif IN
        SELECT pi.id, pi.producto_id, pi.cantidad, pi.promocion_id
          FROM pedido_items pi
         WHERE pi.pedido_id = p_pedido_id
           AND pi.sucursal_id = v_sucursal
           AND COALESCE(pi.es_bonificacion, FALSE) = TRUE
           AND pi.promocion_id = v_promo_sync.promocion_id
         ORDER BY pi.id DESC
      LOOP
        EXIT WHEN v_exceso <= 0;
        v_diff   := LEAST(v_bonif.cantidad, v_exceso);
        v_exceso := v_exceso - v_diff;
$a$,
$r$      -- #1325: el exceso esta en cortes y v_diff en la unidad de la linea: lo que
      -- devuelve stock y resta de la barra.
      FOR v_bonif IN
        SELECT r.pedido_item_id AS id, r.producto_id, r.cantidad, v_promo_sync.promocion_id AS promocion_id
               , r.cantidad_final
          FROM public._regalo_recorte(p_pedido_id, v_promo_sync.promocion_id, v_sucursal, v_exceso) r
      LOOP
        v_diff := v_bonif.cantidad - v_bonif.cantidad_final;
$r$),

('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)', 7,
$a$        PERFORM public.aplicar_uso_promo_acumulador(
          v_bonif.promocion_id, v_bonif.producto_id, -v_diff,
          v_bonif.producto_id, v_sucursal, v_usuario_id,
          'Salvedad pedido #' || p_pedido_id);
$a$,
$r$        IF public._regalo_barra_vale(p_pedido_id, v_bonif.promocion_id, v_sucursal) THEN
          PERFORM public.aplicar_uso_promo_acumulador(
            v_bonif.promocion_id, v_bonif.producto_id, -v_diff,
            v_bonif.producto_id, v_sucursal, v_usuario_id,
            'Salvedad pedido #' || p_pedido_id);
        END IF;
$r$),

('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)', 8,
$a$  -- locks sigue siendo pedido, linea, producto.
  IF v_stock_devuelto THEN
    PERFORM 1 FROM productos
     WHERE id = v_item.producto_id AND sucursal_id = v_sucursal
       FOR UPDATE;
$a$,
$r$  -- locks sigue siendo pedido, linea, producto.
  --
  -- #1375: todos los productos juntos y por id, antes de mover el primero: el de
  -- la linea, los regalos que la resincronizacion puede devolver y sus
  -- contenedores. Es el orden de la venta (#1255).
  PERFORM 1 FROM productos
   WHERE sucursal_id = v_sucursal
     AND id IN (SELECT v_item.producto_id
                UNION
                SELECT pi.producto_id FROM pedido_items pi
                 WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
                   AND COALESCE(pi.es_bonificacion, FALSE)
                UNION
                SELECT c FROM public._contenedores_de_promos(
                  ARRAY(SELECT pi.promocion_id FROM pedido_items pi
                         WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
                           AND pi.promocion_id IS NOT NULL), v_sucursal) c)
   ORDER BY id
     FOR UPDATE;

  IF v_stock_devuelto THEN
    PERFORM 1 FROM productos
     WHERE id = v_item.producto_id AND sucursal_id = v_sucursal
       FOR UPDATE;
$r$),

('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)', 9,
$a$    SELECT id, monto_afectado, cantidad_entregada, stock_devuelto, pedido_id, recargo_combo
      INTO v_existing
$a$,
$r$    SELECT id, monto_afectado, cantidad_entregada, stock_devuelto, pedido_id, recargo_combo,
           cantidad_afectada, motivo
      INTO v_existing
$r$),

('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)', 10,
$a$    IF FOUND THEN
      RETURN jsonb_build_object(
        'success', true,
        'salvedad_id', v_existing.id,
$a$,
$r$    -- #1327: la clave es de la salvedad, no de su contenido. Si la respuesta se
    -- perdio y el chofer corrigio antes de reintentar, hay que decirle que quedo
    -- la primera: contestar que salio bien daria por hecho lo que no se hizo.
    IF FOUND AND (v_existing.cantidad_afectada IS DISTINCT FROM p_cantidad_afectada
                  OR v_existing.motivo IS DISTINCT FROM p_motivo) THEN
      RETURN jsonb_build_object('success', false, 'codigo', 'salvedad_ya_registrada', 'error',
        format('Esta salvedad ya se registró con %s unidad(es) y motivo %s: volvé a esos datos para seguir, o pedile a un admin que la anule.',
               v_existing.cantidad_afectada, v_existing.motivo));
    END IF;

    IF FOUND THEN
      RETURN jsonb_build_object(
        'success', true,
        'salvedad_id', v_existing.id,
$r$),

('public.anular_salvedad(bigint,text)', 1,
$a$  v_precio_combo  JSONB;
BEGIN
$a$,
$r$  v_precio_combo  JSONB;
  -- #1327: el mensaje del guard de caja.
  v_caja_cerrada  TEXT;
BEGIN
$r$),

('public.anular_salvedad(bigint,text)', 2,
$a$  -- #1163: lo mismo que registrar_salvedad (mig 276). Despues del lock del
$a$,
$r$  -- #1327: un dia con la caja cerrada no cambia: ni el total, ni el stock.
  v_caja_cerrada := public._pedido_en_caja_cerrada(v_salvedad.pedido_id, v_sucursal);
  IF v_caja_cerrada IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error', v_caja_cerrada, 'codigo', 'caja_cerrada');
  END IF;

  -- #1163: lo mismo que registrar_salvedad (mig 276). Despues del lock del
$r$),

('public.cancelar_pedido_con_stock(bigint,text,uuid,text)', 1,
$a$     AND v_pedido.fecha_entrega::date <= public.ultima_fecha_caja_cerrada(v_sucursal) THEN
$a$,
$r$     AND (v_pedido.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
           <= public.ultima_fecha_caja_cerrada(v_sucursal) THEN
$r$),

('public.cancelar_pedido_con_stock(bigint,text,uuid,text)', 2,
$a$to_char(v_pedido.fecha_entrega::date, 'DD/MM/YYYY')
$a$,
$r$to_char((v_pedido.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date, 'DD/MM/YYYY')
$r$),

('public.cancelar_pedido_con_stock(bigint,text,uuid,text)', 3,
$a$             pi.promocion_id, COALESCE(pr.regalo_mueve_stock, FALSE) AS regalo_mueve_stock
      FROM pedido_items pi
      LEFT JOIN promociones pr ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
      WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
$a$,
$r$             pi.promocion_id,
             -- #1324: el modo de la foto del pedido.
             COALESCE(public._regalo_modo_del_pedido(p_pedido_id, pi.promocion_id, v_sucursal), FALSE) AS regalo_mueve_stock
      FROM pedido_items pi
      WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
$r$),

('public.cancelar_pedido_con_stock(bigint,text,uuid,text)', 4,
$a$        LEFT JOIN promociones pr ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
       WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
         AND (NOT COALESCE(pi.es_bonificacion, false) OR COALESCE(pr.regalo_mueve_stock, FALSE))
$a$,
$r$       WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
         AND (NOT COALESCE(pi.es_bonificacion, false)
              OR COALESCE(public._regalo_modo_del_pedido(p_pedido_id, pi.promocion_id, v_sucursal), FALSE))
$r$),

('public.cancelar_pedido_con_stock(bigint,text,uuid,text)', 5,
$a$       AND COALESCE(pi.es_bonificacion, false) = true
       AND pi.promocion_id IS NOT NULL
     GROUP BY 1, 2, 3
$a$,
$r$       AND COALESCE(pi.es_bonificacion, false) = true
       AND pi.promocion_id IS NOT NULL
       -- #1324: una linea de otro modo no entro en la barra de la promo viva, y
       -- deshacerla devolveria un fardo que nunca salio.
       AND public._regalo_barra_vale(p_pedido_id, pi.promocion_id, v_sucursal)
     GROUP BY 1, 2, 3
$r$),

('public.cancelar_pedido_con_stock(bigint,text,uuid,text)', 6,
$a$  -- motor de promos más abajo se siguen bloqueando ahí.
  PERFORM 1
     FROM productos
    WHERE sucursal_id = v_sucursal
      AND id IN (SELECT pi.producto_id FROM pedido_items pi
                  WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal)
    ORDER BY id
      FOR UPDATE;
$a$,
$r$  -- motor de promos más abajo también entran acá (#1375).
  PERFORM 1
     FROM productos
    WHERE sucursal_id = v_sucursal
      AND id IN (SELECT pi.producto_id FROM pedido_items pi
                  WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
                 UNION
                 SELECT c FROM public._contenedores_de_promos(
                   ARRAY(SELECT pi.promocion_id FROM pedido_items pi
                          WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
                            AND pi.promocion_id IS NOT NULL), v_sucursal) c)
    ORDER BY id
      FOR UPDATE;
$r$),

('public.eliminar_pedido_completo(bigint,uuid,text,boolean)', 1,
$a$             pi.promocion_id, COALESCE(pr.regalo_mueve_stock, FALSE) AS regalo_mueve_stock
      FROM pedido_items pi
      LEFT JOIN promociones pr ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
      WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
$a$,
$r$             pi.promocion_id,
             COALESCE(public._regalo_modo_del_pedido(p_pedido_id, pi.promocion_id, v_sucursal), FALSE) AS regalo_mueve_stock
      FROM pedido_items pi
      WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
$r$),

('public.eliminar_pedido_completo(bigint,uuid,text,boolean)', 2,
$a$      IF v_item.es_bonificacion AND v_item.promocion_id IS NOT NULL THEN
        -- mig 294 (#840): contra la barra del sabor de la linea.
$a$,
$r$      IF v_item.es_bonificacion AND v_item.promocion_id IS NOT NULL
         AND public._regalo_barra_vale(p_pedido_id, v_item.promocion_id, v_sucursal) THEN
        -- mig 294 (#840): contra la barra del sabor de la linea.
$r$);

DO $parches$
DECLARE
  v_f   record;
  v_p   record;
  v_def text;
  v_n   int;
BEGIN
  FOR v_f IN SELECT DISTINCT firma FROM _n_parche ORDER BY firma LOOP
    v_def := pg_get_functiondef(v_f.firma::regprocedure);
    FOR v_p IN SELECT * FROM _n_parche WHERE firma = v_f.firma ORDER BY orden LOOP
      v_n := (length(v_def) - length(replace(v_def, v_p.ancla, ''))) / length(v_p.ancla);
      IF v_n <> v_p.veces THEN
        RAISE EXCEPTION 'mig 431b · % parche %: el ancla aparece % vez/veces y se esperaba %',
          v_f.firma, v_p.orden, v_n, v_p.veces;
      END IF;
      v_def := replace(v_def, v_p.ancla, v_p.reemplazo);
    END LOOP;
    EXECUTE v_def;
  END LOOP;
END
$parches$;

COMMIT;
