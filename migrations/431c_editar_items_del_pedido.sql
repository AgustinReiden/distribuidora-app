-- 431c · actualizar_pedido_items: el pre-chequeo, la concurrencia, los canjes y la
-- foto (#1323, #1324, #1375). La firma cambia. El motivo está en 431a.

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
        ('public.actualizar_pedido_items(bigint,jsonb,uuid,text)',
         'c694376188531f8db4050466563d925c')
      ) AS x(firma, md5)
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION 'mig 431c · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer sobre la definición vigente',
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
('public.actualizar_pedido_items(bigint,jsonb,uuid,text)', 1,
$a$p_decision_envio text DEFAULT NULL::text)
 RETURNS jsonb
$a$,
$r$p_decision_envio text DEFAULT NULL::text, p_updated_at_esperado timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
$r$),

('public.actualizar_pedido_items(bigint,jsonb,uuid,text)', 2,
$a$  v_cantidad_original INT;
  v_cantidad_nueva INT;
  v_diferencia INT;
  v_es_bonificacion BOOLEAN;
  v_stock_actual INT;
  v_producto_nombre TEXT;
$a$,
$r$  v_cantidad_nueva INT;
  v_es_bonificacion BOOLEAN;
  v_producto_nombre TEXT;
$r$),

('public.actualizar_pedido_items(bigint,jsonb,uuid,text)', 3,
$a$  -- #1191: los productos de venta ya comparados en el pre-chequeo de stock.
  v_productos_vistos INT[] := '{}';
BEGIN
$a$,
$r$  -- #1323: lo que el pedido va a bajar de cada producto: {producto: cantidad}.
  v_consumo      JSONB := '{}'::jsonb;
  v_chequeo      RECORD;
  -- #1324: el factor de las lineas de otro modo, por promo.
  v_factores     JSONB;
  v_canal        TEXT;
  v_updated_at   TIMESTAMPTZ;
BEGIN
$r$),

('public.actualizar_pedido_items(bigint,jsonb,uuid,text)', 4,
$a$         cargo_envio_estado -- cargo_2_edicion
    INTO v_total_anterior, v_pedido_creator, v_pedido_created_at, v_tipo_factura, v_cargo_envio,
         v_cargo_estado
    FROM pedidos
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['Pedido no encontrado']);
  END IF;
$a$,
$r$         cargo_envio_estado, -- cargo_2_edicion
         canal, updated_at
    INTO v_total_anterior, v_pedido_creator, v_pedido_created_at, v_tipo_factura, v_cargo_envio,
         v_cargo_estado, v_canal, v_updated_at
    FROM pedidos
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['Pedido no encontrado']);
  END IF;

  -- #1323 · PED-5: la comanda de un canje no es una venta: va a total 0
  -- (CAMBIO-01) y sus lineas las arma el canje.
  IF v_canal = 'cambio' THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY[
      'Un canje no se edita: cancelalo y registralo de nuevo']);
  END IF;

  -- #1323 · PED-6: se compara con el pedido bloqueado, asi que de dos ediciones
  -- simultaneas la segunda ve el updated_at de la primera. Sin el parametro (un
  -- bundle viejo) no se compara. El front manda el valor tal como lo leyo.
  IF p_updated_at_esperado IS NOT NULL AND v_updated_at IS DISTINCT FROM p_updated_at_esperado THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY[
      'Otro usuario modificó este pedido mientras lo tenías abierto. Cerrá la edición y volvé a abrirlo para ver cómo quedó.'],
      'codigo', 'pedido_editado_por_otro');
  END IF;
$r$),

('public.actualizar_pedido_items(bigint,jsonb,uuid,text)', 5,
$a$      SELECT regalo_mueve_stock INTO v_regalo_mueve_stock FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
      IF NOT COALESCE(v_regalo_mueve_stock, FALSE) THEN CONTINUE; END IF;
$a$,
$r$      -- #1324: el modo de la foto del pedido.
      v_regalo_mueve_stock := public._regalo_modo_del_pedido(p_pedido_id, v_promocion_id, v_sucursal);
      IF NOT COALESCE(v_regalo_mueve_stock, FALSE) THEN CONTINUE; END IF;
$r$),

('public.actualizar_pedido_items(bigint,jsonb,uuid,text)', 6,
$a$    -- Un regalo se compara contra la linea de SU promo: dos promos cuyos
    -- regalos terminan en el mismo producto hacian que el INTO tomara
    -- cualquiera de las dos, y con la cantidad convertida eso puede frenar
    -- una edicion sin cambios.
    SELECT COALESCE(cantidad, 0) INTO v_cantidad_original
    FROM pedido_items
    WHERE pedido_id = p_pedido_id AND producto_id = v_producto_id
      AND COALESCE(es_bonificacion, false) = v_es_bonificacion
      AND (NOT v_es_bonificacion OR promocion_id IS NOT DISTINCT FROM v_promocion_id)
      -- mig 338 (#1057): un regalo con clave, contra SU linea. Dos lineas de
      -- la promo con el mismo producto (un reparto y un cambio) hacian que el
      -- INTO tomara cualquiera, y una diferencia fantasma frenaba la edicion.
      AND (v_item_nuevo->>'_cadena' IS NULL OR regalo_cadena_id = (v_item_nuevo->>'_cadena')::UUID)
      AND sucursal_id = v_sucursal;

    -- #1191: un producto puede venir en dos lineas de venta (la del combo y
    -- la suelta). Se compara la suma del producto, una sola vez: el SELECT de
    -- arriba tomaba una linea cualquiera.
    IF NOT v_es_bonificacion THEN
      IF v_producto_id = ANY(v_productos_vistos) THEN
        CONTINUE;
      END IF;
      v_productos_vistos := v_productos_vistos || v_producto_id;
      SELECT COALESCE(SUM((e->>'cantidad')::INT), 0) INTO v_cantidad_nueva
        FROM jsonb_array_elements(v_items) e
       WHERE NOT COALESCE((e->>'es_bonificacion')::BOOLEAN, false)
         AND (e->>'producto_id')::INT = v_producto_id;
      SELECT COALESCE(SUM(cantidad), 0) INTO v_cantidad_original
        FROM pedido_items
       WHERE pedido_id = p_pedido_id AND producto_id = v_producto_id
         AND NOT COALESCE(es_bonificacion, false) AND sucursal_id = v_sucursal;
    END IF;

    v_diferencia := v_cantidad_nueva - COALESCE(v_cantidad_original, 0);

    IF v_diferencia > 0 THEN
      SELECT stock, nombre INTO v_stock_actual, v_producto_nombre
      FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal FOR UPDATE;

      IF v_stock_actual IS NULL THEN
        v_errores := array_append(v_errores, 'Producto ID ' || v_producto_id || ' no encontrado');
      ELSIF v_stock_actual < v_diferencia THEN
        v_errores := array_append(v_errores, COALESCE(v_producto_nombre, 'Producto ' || v_producto_id)
          || ': stock insuficiente (disponible: ' || v_stock_actual || ', adicional: ' || v_diferencia || ')');
      END IF;
    END IF;
  END LOOP;
$a$,
$r$    -- #1191 / #1323: la suma del producto. Un producto puede venir en dos lineas
    -- de venta (la del combo y la suelta), y ademas en un regalo que mueve stock:
    -- comparar cada lado por separado dejaba pasar 8 de venta + 4 de regalo con
    -- 10 disponibles, y el stock quedaba en -2.
    v_consumo := jsonb_set(v_consumo, ARRAY[v_producto_id::text],
      to_jsonb(COALESCE((v_consumo->>(v_producto_id::text))::INT, 0) + v_cantidad_nueva));
  END LOOP;

  -- #1323: lo que el pedido ya tiene bajado de ese producto vuelve antes de la
  -- bajada, asi que se compara la diferencia. Los productos estan bloqueados
  -- arriba (#1296), el sustituto incluido: el stock que se lee es el vigente.
  FOR v_chequeo IN
    SELECT c.key::BIGINT AS producto_id,
           c.value::INT - COALESCE(ya.cantidad, 0) AS diferencia,
           pr.stock, pr.nombre
      FROM jsonb_each_text(v_consumo) c
      LEFT JOIN LATERAL (
        SELECT SUM(pi.cantidad)::INT AS cantidad
          FROM pedido_items pi
         WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
           AND pi.producto_id = c.key::BIGINT
           AND (NOT COALESCE(pi.es_bonificacion, false)
                OR (pi.promocion_id IS NOT NULL
                    AND COALESCE(public._regalo_modo_del_pedido(p_pedido_id, pi.promocion_id, v_sucursal), FALSE)))
      ) ya ON true
      LEFT JOIN productos pr ON pr.id = c.key::BIGINT AND pr.sucursal_id = v_sucursal
     ORDER BY 1
  LOOP
    IF v_chequeo.diferencia > 0 THEN
      IF v_chequeo.stock IS NULL THEN
        v_errores := array_append(v_errores, 'Producto ID ' || v_chequeo.producto_id || ' no encontrado');
      ELSIF v_chequeo.stock < v_chequeo.diferencia THEN
        v_errores := array_append(v_errores, COALESCE(v_chequeo.nombre, 'Producto ' || v_chequeo.producto_id)
          || ': stock insuficiente (disponible: ' || v_chequeo.stock || ', adicional: ' || v_chequeo.diferencia || ')');
      END IF;
    END IF;
  END LOOP;
$r$),

('public.actualizar_pedido_items(bigint,jsonb,uuid,text)', 7,
$a$    LEFT JOIN promociones pr ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
   WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
     AND (NOT COALESCE(pi.es_bonificacion, false)
          OR (pi.promocion_id IS NOT NULL AND COALESCE(pr.regalo_mueve_stock, FALSE)));
$a$,
$r$   WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
     AND (NOT COALESCE(pi.es_bonificacion, false)
          OR (pi.promocion_id IS NOT NULL
              AND COALESCE(public._regalo_modo_del_pedido(p_pedido_id, pi.promocion_id, v_sucursal), FALSE)));
$r$),

('public.actualizar_pedido_items(bigint,jsonb,uuid,text)', 8,
$a$          JOIN promociones pr ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
         WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
           AND COALESCE(pi.es_bonificacion, false) = true
           AND pi.promocion_id IS NOT NULL
           AND COALESCE(pr.regalo_mueve_stock, FALSE) = TRUE
$a$,
$r$         WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
           AND COALESCE(pi.es_bonificacion, false) = true
           AND pi.promocion_id IS NOT NULL
           -- #1324: lo que salio con el modo de la foto vuelve con ese modo.
           AND COALESCE(public._regalo_modo_del_pedido(p_pedido_id, pi.promocion_id, v_sucursal), FALSE) = TRUE
$r$),

('public.actualizar_pedido_items(bigint,jsonb,uuid,text)', 9,
$a$       AND COALESCE(pi.es_bonificacion, false) = true AND pi.promocion_id IS NOT NULL
     GROUP BY pi.promocion_id, pi.producto_id
$a$,
$r$       AND COALESCE(pi.es_bonificacion, false) = true AND pi.promocion_id IS NOT NULL
       -- #1324: una linea de otro modo no entro en la barra de la promo viva.
       AND public._regalo_barra_vale(p_pedido_id, pi.promocion_id, v_sucursal)
     GROUP BY pi.promocion_id, pi.producto_id
$r$),

('public.actualizar_pedido_items(bigint,jsonb,uuid,text)', 10,
$a$      SELECT regalo_mueve_stock INTO v_regalo_mueve_stock FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
      IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
$a$,
$r$      -- #1324: el modo de la foto. El INSERT de arriba rehace las reglas de la
      -- foto, no este modo (capturar_promo_del_pedido).
      v_regalo_mueve_stock := public._regalo_modo_del_pedido(p_pedido_id, v_promocion_id, v_sucursal);
      IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
$r$),

('public.actualizar_pedido_items(bigint,jsonb,uuid,text)', 11,
$a$      PERFORM public.aplicar_uso_promo_acumulador(
        v_promocion_id, v_producto_guardado, v_cantidad_guardada, v_producto_guardado,
        v_sucursal, p_usuario_id,
        'Auto-ajuste (Promo: '
          || COALESCE((SELECT nombre FROM promociones
                        WHERE id = v_promocion_id AND sucursal_id = v_sucursal), '?')
          || ', Pedido #' || p_pedido_id || ', edicion)');
$a$,
$r$      IF public._regalo_barra_vale(p_pedido_id, v_promocion_id, v_sucursal) THEN
        PERFORM public.aplicar_uso_promo_acumulador(
          v_promocion_id, v_producto_guardado, v_cantidad_guardada, v_producto_guardado,
          v_sucursal, p_usuario_id,
          'Auto-ajuste (Promo: '
            || COALESCE((SELECT nombre FROM promociones
                          WHERE id = v_promocion_id AND sucursal_id = v_sucursal), '?')
            || ', Pedido #' || p_pedido_id || ', edicion)');
      END IF;
$r$),

('public.actualizar_pedido_items(bigint,jsonb,uuid,text)', 12,
$a$                            'cargo_envio_estado', v_cargo_tras.estado);
END;
$a$,
$r$                            'cargo_envio_estado', v_cargo_tras.estado,
                            -- #1323: el valor con el que sigue la edicion si el
                            -- modal queda abierto (un guardado a medias).
                            'updated_at', (SELECT updated_at FROM pedidos
                                            WHERE id = p_pedido_id AND sucursal_id = v_sucursal));
END;
$r$),

('public.actualizar_pedido_items(bigint,jsonb,uuid,text)', 13,
$a$  -- producto que de verdad se descuenta). Los FOR UPDATE de abajo pasan a ser
  -- re-locks; los contenedores que mueve el motor de promos se siguen
  -- bloqueando donde los mueve.
$a$,
$r$  -- producto que de verdad se descuenta), y los contenedores que mueve el motor
  -- de promos (#1375). Los FOR UPDATE de abajo pasan a ser re-locks.
$r$),

('public.actualizar_pedido_items(bigint,jsonb,uuid,text)', 14,
$a$                 SELECT (e->>'producto_id')::bigint FROM jsonb_array_elements(v_items) e)
    ORDER BY id
      FOR UPDATE;
$a$,
$r$                 SELECT (e->>'producto_id')::bigint FROM jsonb_array_elements(v_items) e
                 UNION
                 SELECT c FROM public._contenedores_de_promos(
                   ARRAY(SELECT pi.promocion_id FROM pedido_items pi
                          WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
                            AND pi.promocion_id IS NOT NULL
                         UNION
                         SELECT (e->>'promocion_id')::bigint FROM jsonb_array_elements(v_items) e
                          WHERE e->>'promocion_id' IS NOT NULL), v_sucursal) c)
    ORDER BY id
      FOR UPDATE;
$r$),

('public.actualizar_pedido_items(bigint,jsonb,uuid,text)', 15,
$a$  -- #1296 · Los productos del pedido, en orden de id, todos antes del
$a$,
$r$  -- #1324: una foto sin regalo vivo no dice como salio nada (el trigger no borra
  -- fotos): si la edicion vuelve a agregar ese regalo, arranca con el modo vivo.
  UPDATE pedido_promo_reglas f
     SET regalo_mueve_stock = COALESCE(pr.regalo_mueve_stock, false)
    FROM promociones pr
   WHERE f.pedido_id = p_pedido_id
     AND pr.id = f.promocion_id AND pr.sucursal_id = v_sucursal
     AND f.regalo_mueve_stock IS DISTINCT FROM COALESCE(pr.regalo_mueve_stock, false)
     AND NOT EXISTS (SELECT 1 FROM pedido_items pi
                      WHERE pi.pedido_id = p_pedido_id AND pi.promocion_id = f.promocion_id
                        AND COALESCE(pi.es_bonificacion, false));

  -- #1324: si la promo cambio de tipo Y de regla, el modal manda el regalo de la
  -- regla nueva, en otra unidad: 12 botellas de la nueva serian 12 fardos con el
  -- modo de la foto. Con la regla de siempre, o con el regalo como estaba, sigue.
  IF EXISTS (
    SELECT 1
      FROM public.promos_del_pedido(p_pedido_id) f
     CROSS JOIN LATERAL public._promo_reglas_vigentes(f.promocion_id) v
     CROSS JOIN LATERAL (
       SELECT COALESCE(SUM((e->>'cantidad')::numeric), 0) AS cantidad
         FROM jsonb_array_elements(p_items_nuevos) e
        WHERE COALESCE((e->>'es_bonificacion')::BOOLEAN, false)
          AND (e->>'promocion_id')::BIGINT = f.promocion_id) j
     CROSS JOIN LATERAL (
       SELECT COALESCE(SUM(public.regalo_usos_de_linea(
                public.regalo_eslabones(p_pedido_id, pi.promocion_id, v_sucursal),
                pi.regalo_cadena_id, pi.cantidad)), 0) AS corte
         FROM pedido_items pi
        WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
          AND COALESCE(pi.es_bonificacion, false) AND pi.promocion_id = f.promocion_id) l
     WHERE NOT public._regalo_barra_vale(p_pedido_id, f.promocion_id, v_sucursal)
       AND (f.cantidad_compra, f.cantidad_bonificacion)
           IS DISTINCT FROM (v.cantidad_compra, v.cantidad_bonificacion)
       AND j.cantidad > 0 AND j.cantidad <> l.corte) THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY[
      'La promo de este regalo cambió de tipo y de regla desde que se armó el pedido: el regalo no se puede recalcular. Sacalo, o cancelá el pedido y cargalo de nuevo.'],
      'codigo', 'regalo_de_promo_cambiada');
  END IF;

  -- #1296 · Los productos del pedido, en orden de id, todos antes del
$r$),

('public.actualizar_pedido_items(bigint,jsonb,uuid,text)', 16,
$a$  DELETE FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;

  FOR v_item_nuevo IN SELECT * FROM jsonb_array_elements(v_items) LOOP
$a$,
$r$  -- #1324: el factor de una linea cuyo modo no es el vivo tambien es de su foto:
  -- con el de la promo de hoy, los reportes y la hoja de ruta dividen mal el regalo.
  SELECT COALESCE(jsonb_object_agg(x.promocion_id::text, x.fila), '{}'::jsonb)
    INTO v_factores
    FROM (SELECT DISTINCT ON (pi.promocion_id) pi.promocion_id,
                 jsonb_build_object('f', pi.unidades_por_bloque_al_crear,
                                    'o', pi.origen_unidades_por_bloque) AS fila
            FROM pedido_items pi
           WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
             AND COALESCE(pi.es_bonificacion, false) AND pi.promocion_id IS NOT NULL
             AND NOT public._regalo_barra_vale(p_pedido_id, pi.promocion_id, v_sucursal)
           ORDER BY pi.promocion_id, pi.id) x;

  DELETE FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;

  FOR v_item_nuevo IN SELECT * FROM jsonb_array_elements(v_items) LOOP
$r$),

('public.actualizar_pedido_items(bigint,jsonb,uuid,text)', 17,
$a$      combo_id, precio_sin_combo_unitario
    ) VALUES (
$a$,
$r$      combo_id, precio_sin_combo_unitario,
      unidades_por_bloque_al_crear, origen_unidades_por_bloque
    ) VALUES (
$r$),

('public.actualizar_pedido_items(bigint,jsonb,uuid,text)', 18,
$a$           THEN NULLIF(v_item_nuevo->>'precio_sin_combo_unitario', '')::NUMERIC END
    )
$a$,
$r$           THEN NULLIF(v_item_nuevo->>'precio_sin_combo_unitario', '')::NUMERIC END,
      -- #1324: NULL en la linea comun: lo completa el trigger.
      CASE WHEN v_es_bonificacion THEN (v_factores->(v_promocion_id::text)->>'f')::INT END,
      CASE WHEN v_es_bonificacion THEN v_factores->(v_promocion_id::text)->>'o' END
    )
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
        RAISE EXCEPTION 'mig 431c · % parche %: el ancla aparece % vez/veces y se esperaba %',
          v_f.firma, v_p.orden, v_n, v_p.veces;
      END IF;
      v_def := replace(v_def, v_p.ancla, v_p.reemplazo);
    END LOOP;
    -- #1323: la firma cambia. Con las dos, PostgREST no sabria cual llamar
    -- (PGRST203). Un bundle viejo no manda el parametro nuevo y resuelve igual.
    IF v_f.firma = 'public.actualizar_pedido_items(bigint,jsonb,uuid,text)' THEN
      EXECUTE 'DROP FUNCTION ' || v_f.firma;
    END IF;
    EXECUTE v_def;
  END LOOP;
END
$parches$;

REVOKE ALL ON FUNCTION public.actualizar_pedido_items(bigint, jsonb, uuid, text, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.actualizar_pedido_items(bigint, jsonb, uuid, text, timestamptz) TO authenticated, service_role;

COMMIT;
