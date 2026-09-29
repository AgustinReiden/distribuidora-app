-- actualizar_pedido_items serializa por pedido: dos ediciones concurrentes ya no
-- leen el mismo total anterior (#826).
--
-- El pedido 6414 registro 3 llamadas a actualizar_pedido_items en 2 s por UN
-- guardado (doble click en "Guardar Todo"; el front se corrige en el mismo
-- issue). La funcion lee `v_total_anterior` con un SELECT pelado, asi que las
-- llamadas concurrentes leian el MISMO total, cada una devolvia al stock lo que
-- veia y escribia su propio `pedido_historial` (filas 35416-35420 duplicadas).
--
-- El unico cambio es `FOR UPDATE` en ese primer SELECT. La segunda llamada se
-- queda esperando el candado hasta que la primera termina; como cada sentencia
-- posterior de plpgsql toma snapshot nuevo (READ COMMITTED), los chequeos de
-- estado de abajo (entregado / cancelado) y el `pedido_items` que restituye ya
-- ven lo que dejo la primera. Sin `FOR UPDATE` en el resto del cuerpo: el
-- candado del pedido es lo que ordena todo lo demas.
--
-- Cuerpo partido del vivo en prod (pg_get_functiondef). CREATE OR REPLACE
-- conserva los grants: no hace falta tocar REVOKE/GRANT.

CREATE OR REPLACE FUNCTION public.actualizar_pedido_items(p_pedido_id bigint, p_items_nuevos jsonb, p_usuario_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_item_nuevo JSONB;
  v_producto_id INT;
  v_cantidad_original INT;
  v_cantidad_nueva INT;
  v_diferencia INT;
  v_es_bonificacion BOOLEAN;
  v_stock_actual INT;
  v_producto_nombre TEXT;
  v_total_nuevo DECIMAL := 0;
  v_total_neto_nuevo DECIMAL := 0;
  v_total_iva_nuevo DECIMAL := 0;
  v_total_real_nuevo DECIMAL := 0;
  v_total_anterior DECIMAL;
  v_errores TEXT[] := '{}';
  v_items_originales JSONB;
  v_user_role TEXT;
  v_neto_unitario DECIMAL;
  v_iva_unitario DECIMAL;
  v_ingreso_real DECIMAL;
  v_porcentaje_iva DECIMAL;
  v_precio_unitario DECIMAL;
  v_promocion_id BIGINT;
  v_regalo_mueve_stock BOOLEAN;
  v_descripcion_regalo TEXT;
  v_bonif RECORD;
  v_promo RECORD;
  v_usos_pendientes_actual INT;
  v_bloques_completos INT;
  v_ajustar_usos INT;
  v_ajustar_stock INT;
  v_stock_ajuste_anterior INT;
  v_stock_ajuste_nuevo INT;
  v_ajuste_producto_nombre TEXT;
  v_merma_id BIGINT;
  v_container_id BIGINT;
  -- mig 252 (#653): lo que el trigger de sustituciones dejo REALMENTE en la
  -- fila. Todo lo que mueve stock de aca para abajo se cuelga de este valor,
  -- no del producto_id que vino en el JSON.
  v_producto_guardado BIGINT;
  v_producto_sustituto BIGINT;
  -- mig 257 (#673): el id del renglon que quedo, para poder valuarlo despues
  -- del INSERT --que es cuando recien se sabe de que producto habla--.
  v_pedido_item_guardado BIGINT;
  v_pedido_creator UUID;
  v_pedido_created_at TIMESTAMPTZ;
  v_tipo_factura TEXT;
  v_hora_corte CONSTANT TIME := TIME '15:30';
  v_precio_actual DECIMAL;
  v_costo_actual DECIMAL; v_imp_int_actual DECIMAL; v_costo_al_crear DECIMAL;
  v_costo_real_actual DECIMAL; v_pct_iva_actual DECIMAL;
  v_costo_promedio_actual DECIMAL;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['No se pudo determinar la sucursal activa']);
  END IF;
  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['ID de usuario no coincide con la sesion autenticada']);
  END IF;
  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado', 'preventista') THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['No autorizado']);
  END IF;

  -- mig 268 (#826): FOR UPDATE. Serializa las ediciones del mismo pedido: la
  -- segunda espera a la primera y lee SU total como "anterior".
  SELECT total, usuario_id, created_at, COALESCE(tipo_factura, 'ZZ')
    INTO v_total_anterior, v_pedido_creator, v_pedido_created_at, v_tipo_factura
    FROM pedidos
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal
     FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['Pedido no encontrado']);
  END IF;

  IF EXISTS (SELECT 1 FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal AND estado = 'entregado') THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['No se puede editar un pedido ya entregado']);
  END IF;

  -- mig 181: un cancelado ya tiene el stock devuelto y el total en 0. Editarlo
  -- lo devolvia por segunda vez y le resucitaba el total.
  IF EXISTS (SELECT 1 FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal
               AND estado IN ('cancelado', 'anulado')) THEN
    RETURN jsonb_build_object('success', false, 'errores',
      ARRAY['No se puede editar un pedido cancelado. Crea uno nuevo.']);
  END IF;

  -- mig 181: si la ruta ya salio, los fardos estan arriba del camion. El
  -- preventista no puede cambiarlo (paso 86 veces y deja stock fantasma: la RPC
  -- devuelve lo viejo y descuenta lo nuevo). Encargado/admin si, que son los que
  -- pueden avisarle al chofer.
  IF v_user_role NOT IN ('admin', 'encargado')
     AND EXISTS (SELECT 1 FROM recorrido_pedidos rp
                   JOIN recorridos r ON r.id = rp.recorrido_id
                  WHERE rp.pedido_id = p_pedido_id AND r.estado = 'en_curso') THEN
    RETURN jsonb_build_object('success', false, 'errores',
      ARRAY['El pedido ya esta en una hoja de ruta armada. Pedile a un encargado que lo modifique.']);
  END IF;

  IF v_user_role IN ('preventista') THEN
    IF v_pedido_creator IS DISTINCT FROM p_usuario_id THEN
      RETURN jsonb_build_object('success', false, 'errores',
        ARRAY['Solo el preventista que creo el pedido puede editarlo']);
    END IF;

    IF (v_pedido_created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
         IS DISTINCT FROM (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
       OR (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::time >= v_hora_corte
    THEN
      RETURN jsonb_build_object('success', false, 'errores',
        ARRAY['Como preventista solo puede editar pedidos del dia actual antes de las 15:30 (ARG)']);
    END IF;

    FOR v_item_nuevo IN SELECT * FROM jsonb_array_elements(p_items_nuevos) LOOP
      IF COALESCE((v_item_nuevo->>'es_bonificacion')::BOOLEAN, false) = true THEN
        CONTINUE;
      END IF;
      v_producto_id := (v_item_nuevo->>'producto_id')::INT;
      v_precio_unitario := (v_item_nuevo->>'precio_unitario')::DECIMAL;
      SELECT precio INTO v_precio_actual
        FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal;
      IF v_precio_actual IS NULL THEN
        RETURN jsonb_build_object('success', false, 'errores',
          ARRAY['Producto ID ' || v_producto_id || ' no encontrado']);
      END IF;
      IF v_precio_unitario IS NULL OR v_precio_unitario > v_precio_actual THEN
        RETURN jsonb_build_object('success', false, 'errores',
          ARRAY['Como preventista no puede aumentar precios (producto ID ' || v_producto_id || ')']);
      END IF;
    END LOOP;
  END IF;

  SELECT jsonb_agg(jsonb_build_object(
    'producto_id', producto_id, 'cantidad', cantidad,
    'precio_unitario', precio_unitario, 'es_bonificacion', COALESCE(es_bonificacion, false)))
  INTO v_items_originales FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;

  FOR v_item_nuevo IN SELECT * FROM jsonb_array_elements(p_items_nuevos) LOOP
    v_producto_id := (v_item_nuevo->>'producto_id')::INT;
    v_cantidad_nueva := (v_item_nuevo->>'cantidad')::INT;
    v_es_bonificacion := COALESCE((v_item_nuevo->>'es_bonificacion')::BOOLEAN, false);
    v_promocion_id := (v_item_nuevo->>'promocion_id')::BIGINT;

    IF v_es_bonificacion THEN
      IF v_promocion_id IS NULL THEN CONTINUE; END IF;
      SELECT regalo_mueve_stock INTO v_regalo_mueve_stock FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
      IF NOT COALESCE(v_regalo_mueve_stock, FALSE) THEN CONTINUE; END IF;
    END IF;

    -- mig 252 (#653): mismo criterio que aplicar_sustituciones_regalo_pre_insert.
    -- El pre-chequeo de stock tiene que mirar el producto que REALMENTE se va a
    -- descontar: si no, un regalo sustituido justamente porque el original se
    -- quedo sin stock hace fallar la edicion entera con "stock insuficiente" de
    -- un producto que nadie va a tocar. Pisar v_producto_id es seguro: los dos
    -- FOR lo releen del JSON en cada vuelta.
    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      v_producto_sustituto := NULL;
      SELECT producto_sustituto_id INTO v_producto_sustituto
        FROM pedido_item_sustituciones
       WHERE pedido_id = p_pedido_id
         AND promocion_id = v_promocion_id
         AND producto_original_id = v_producto_id
         AND sucursal_id = v_sucursal
       ORDER BY created_at DESC
       LIMIT 1;
      IF v_producto_sustituto IS NOT NULL THEN
        v_producto_id := v_producto_sustituto;
      END IF;
    END IF;

    SELECT COALESCE(cantidad, 0) INTO v_cantidad_original
    FROM pedido_items
    WHERE pedido_id = p_pedido_id AND producto_id = v_producto_id
      AND COALESCE(es_bonificacion, false) = v_es_bonificacion
      AND sucursal_id = v_sucursal;

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

  IF array_length(v_errores, 1) > 0 THEN
    RETURN jsonb_build_object('success', false, 'errores', to_jsonb(v_errores));
  END IF;

  -- mig 229: las dos restituciones de abajo devuelven stock. 'pedido_creado'
  -- es el origen que la 223 ya esperaba de esta funcion -- su comentario decia
  -- que la etiquetaba, y no era cierto hasta esta migracion.
  PERFORM set_config('app.stock_origen', 'pedido_creado', true);
  PERFORM set_config('app.stock_ref_tipo', 'pedido', true);
  PERFORM set_config('app.stock_ref_id', p_pedido_id::TEXT, true);
  PERFORM set_config('app.stock_user_id', COALESCE(p_usuario_id::TEXT, ''), true);

  UPDATE productos p
  SET stock = p.stock + pi.cantidad
  FROM pedido_items pi
  WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
    AND COALESCE(pi.es_bonificacion, false) = false
    AND p.id = pi.producto_id AND p.sucursal_id = v_sucursal;

  UPDATE productos p
  SET stock = p.stock + pi.cantidad
  FROM pedido_items pi
  JOIN promociones pr ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
  WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
    AND COALESCE(pi.es_bonificacion, false) = true
    AND pi.promocion_id IS NOT NULL
    AND COALESCE(pr.regalo_mueve_stock, FALSE) = TRUE
    AND p.id = pi.producto_id AND p.sucursal_id = v_sucursal;

  FOR v_bonif IN
    SELECT pi.promocion_id AS promocion_id,
           CASE WHEN pr.producto_regalo_id IS DISTINCT FROM pi.producto_id
                THEN pi.producto_id ELSE pr.ajuste_producto_id END AS contenedor_id,
           SUM(pi.cantidad)::INT AS total_cantidad
      FROM pedido_items pi
      LEFT JOIN promociones pr
        ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
     WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
       AND COALESCE(pi.es_bonificacion, false) = true AND pi.promocion_id IS NOT NULL
     GROUP BY 1, 2
  LOOP
    PERFORM public.revertir_bloques_auto_ajuste(
      v_bonif.promocion_id, v_bonif.total_cantidad, v_sucursal,
      p_usuario_id, 'Edicion pedido #' || p_pedido_id,
      v_bonif.contenedor_id
    );
  END LOOP;

  DELETE FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;

  FOR v_item_nuevo IN SELECT * FROM jsonb_array_elements(p_items_nuevos) LOOP
    v_producto_id := (v_item_nuevo->>'producto_id')::INT;
    v_cantidad_nueva := (v_item_nuevo->>'cantidad')::INT;
    v_precio_unitario := (v_item_nuevo->>'precio_unitario')::DECIMAL;
    v_es_bonificacion := COALESCE((v_item_nuevo->>'es_bonificacion')::BOOLEAN, false);
    v_promocion_id := (v_item_nuevo->>'promocion_id')::BIGINT;

    SELECT costo_promedio, costo_real, costo_sin_iva, COALESCE(impuestos_internos, 0), COALESCE(porcentaje_iva, 21)
      INTO v_costo_promedio_actual, v_costo_real_actual, v_costo_actual, v_imp_int_actual, v_pct_iva_actual
      FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal;
    -- mig 257 (#673): el costo NO se decide aca. El SELECT de arriba lee el
    -- producto del JSON --el ORIGINAL-- y el trigger de sustituciones puede
    -- reescribir producto_id unas lineas mas abajo. Del pre-INSERT sale el
    -- desglose de precio (IVA/II), que se cobra por el precio del JSON; el
    -- costo sale despues del INSERT, del producto que quedo en la fila.
    v_costo_al_crear := NULL;

    IF v_es_bonificacion THEN
      v_neto_unitario := 0; v_iva_unitario := 0; v_ingreso_real := 0; v_porcentaje_iva := 0;
    ELSE
      SELECT d.neto, d.iva, d.ingreso_real
        INTO v_neto_unitario, v_iva_unitario, v_ingreso_real
        FROM calcular_desglose_venta(v_precio_unitario, v_pct_iva_actual, v_imp_int_actual, v_tipo_factura) d;
      v_porcentaje_iva := v_pct_iva_actual;
    END IF;

    v_descripcion_regalo := NULL;
    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      SELECT descripcion_regalo INTO v_descripcion_regalo FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
    END IF;

    INSERT INTO pedido_items (
      pedido_id, producto_id, cantidad, precio_unitario, subtotal,
      es_bonificacion, promocion_id,
      neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva,
      ingreso_real_unitario,
      sucursal_id, descripcion_regalo, costo_unitario_al_crear
    ) VALUES (
      p_pedido_id, v_producto_id, v_cantidad_nueva, v_precio_unitario,
      v_cantidad_nueva * v_precio_unitario,
      v_es_bonificacion, v_promocion_id,
      v_neto_unitario, v_iva_unitario, 0, v_porcentaje_iva,
      v_ingreso_real,
      v_sucursal, v_descripcion_regalo, v_costo_al_crear
    )
    -- mig 252 (#653): aplicar_sustituciones_regalo_pre_insert puede haber
    -- reescrito producto_id al sustituto. Lo que sigue descuenta stock y elige
    -- contenedor: tiene que hablar del renglon que quedo, no del que se pidio.
    RETURNING id, producto_id INTO v_pedido_item_guardado, v_producto_guardado;

    -- mig 257 (#673): la valuacion sigue al renglon GUARDADO, igual que el
    -- stock y el contenedor desde la 252. Antes se calculaba antes del INSERT
    -- y con el producto del JSON: un regalo sustituido se guardaba con el costo
    -- del original --80 de 295 productos de prod tienen costo_real distinto de
    -- costo_promedio, asi que no es el mismo numero-- y solo se salvaba si el
    -- trigger lo reparaba.
    --
    -- La cascada es UNA sola y vive en costo_valuacion (mig 238): snapshot >
    -- promedio > real > reconstruccion desde sin_iva. Aca no hay snapshot
    -- previo --esto ES el snapshot--, asi que va NULL en el primer argumento.
    SELECT public.costo_valuacion(NULL, p.costo_promedio, p.costo_real,
                                  p.costo_sin_iva, COALESCE(p.impuestos_internos, 0))
      INTO v_costo_al_crear
      FROM productos p
     WHERE p.id = v_producto_guardado AND p.sucursal_id = v_sucursal;

    UPDATE pedido_items SET costo_unitario_al_crear = v_costo_al_crear
     WHERE id = v_pedido_item_guardado;

    IF NOT v_es_bonificacion THEN
      UPDATE productos SET stock = stock - v_cantidad_nueva WHERE id = v_producto_guardado AND sucursal_id = v_sucursal;
      v_total_nuevo := v_total_nuevo + (v_cantidad_nueva * v_precio_unitario);
      v_total_neto_nuevo := v_total_neto_nuevo + (v_cantidad_nueva * v_neto_unitario);
      v_total_iva_nuevo := v_total_iva_nuevo + (v_cantidad_nueva * v_iva_unitario);
      v_total_real_nuevo := v_total_real_nuevo + (v_cantidad_nueva * v_ingreso_real);
    ELSIF v_promocion_id IS NOT NULL THEN
      SELECT regalo_mueve_stock INTO v_regalo_mueve_stock FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
      IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
        UPDATE productos SET stock = stock - v_cantidad_nueva WHERE id = v_producto_guardado AND sucursal_id = v_sucursal;
      END IF;
      UPDATE promociones SET usos_pendientes = usos_pendientes + v_cantidad_nueva WHERE id = v_promocion_id AND sucursal_id = v_sucursal;

      SELECT id, nombre, ajuste_automatico, ajuste_producto_id, unidades_por_bloque,
             stock_por_bloque, usos_pendientes, producto_regalo_id
      INTO v_promo
      FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal FOR UPDATE;

      -- mig 252 (#653): el contenedor del que sale el fardo se decide con el
      -- producto GUARDADO, que es el mismo que van a leer las cuatro
      -- reversiones. Con v_producto_id el fardo salia de uno y volvia a otro.
      v_container_id := CASE WHEN v_promo.producto_regalo_id IS DISTINCT FROM v_producto_guardado
                             THEN v_producto_guardado ELSE v_promo.ajuste_producto_id END;

      IF v_promo.ajuste_automatico AND v_container_id IS NOT NULL
         AND COALESCE(v_promo.unidades_por_bloque, 0) > 0 AND COALESCE(v_promo.stock_por_bloque, 0) > 0 THEN
        v_usos_pendientes_actual := v_promo.usos_pendientes;
        v_bloques_completos := v_usos_pendientes_actual / v_promo.unidades_por_bloque;
        IF v_bloques_completos > 0 THEN
          v_ajustar_usos := v_bloques_completos * v_promo.unidades_por_bloque;
          v_ajustar_stock := v_bloques_completos * v_promo.stock_por_bloque;

          SELECT stock, nombre INTO v_stock_ajuste_anterior, v_ajuste_producto_nombre
          FROM productos WHERE id = v_container_id AND sucursal_id = v_sucursal FOR UPDATE;

          IF v_stock_ajuste_anterior IS NULL THEN
            RAISE EXCEPTION 'Auto-ajuste: producto destino no encontrado (promo %)', v_promocion_id;
          END IF;
          IF v_stock_ajuste_anterior < v_ajustar_stock THEN
            RAISE EXCEPTION 'Auto-ajuste: stock insuficiente en % (disponible: %, requerido: %)',
              v_ajuste_producto_nombre, v_stock_ajuste_anterior, v_ajustar_stock;
          END IF;

          v_stock_ajuste_nuevo := v_stock_ajuste_anterior - v_ajustar_stock;

          INSERT INTO mermas_stock (producto_id, cantidad, motivo, observaciones, stock_anterior, stock_nuevo, usuario_id, sucursal_id)
          VALUES (v_container_id, v_ajustar_stock, 'promociones',
            'Auto-ajuste (Promo: ' || v_promo.nombre || ', Pedido #' || p_pedido_id || ', edicion)',
            v_stock_ajuste_anterior, v_stock_ajuste_nuevo, p_usuario_id, v_sucursal)
          RETURNING id INTO v_merma_id;

          UPDATE productos SET stock = v_stock_ajuste_nuevo, updated_at = NOW()
          WHERE id = v_container_id AND sucursal_id = v_sucursal;

          INSERT INTO promo_ajustes (promocion_id, usos_ajustados, unidades_ajustadas, producto_id, merma_id, usuario_id, observaciones, sucursal_id)
          VALUES (v_promocion_id, v_ajustar_usos, v_ajustar_stock, v_container_id,
            v_merma_id, p_usuario_id, 'Auto-ajuste por edicion pedido #' || p_pedido_id, v_sucursal);

          UPDATE promociones SET usos_pendientes = GREATEST(usos_pendientes - v_ajustar_usos, 0)
          WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
        END IF;
      END IF;
    END IF;
  END LOOP;

  UPDATE pedidos SET total = v_total_nuevo, total_neto = round(v_total_neto_nuevo, 2), total_iva = round(v_total_iva_nuevo, 2), total_real = round(v_total_real_nuevo, 2), updated_at = NOW()
  WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
  VALUES (p_pedido_id, p_usuario_id, 'items', COALESCE(v_items_originales::TEXT, '[]'), p_items_nuevos::TEXT, v_sucursal);

  IF v_total_anterior IS DISTINCT FROM v_total_nuevo THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (p_pedido_id, p_usuario_id, 'total', v_total_anterior::TEXT, v_total_nuevo::TEXT, v_sucursal);
  END IF;

  RETURN jsonb_build_object('success', true, 'total_nuevo', v_total_nuevo);
END;
$function$;
