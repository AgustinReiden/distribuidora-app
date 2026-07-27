-- ============================================================================
-- 139 · Envios entre sucursales: descuento preventivo de stock + editar/cancelar
-- ============================================================================
-- PROBLEMA (reportado por Agustin, caso real en prod):
--   La sucursal origen carga un envio, la mercaderia SALE fisicamente, pero el
--   stock recien se descontaba cuando el destino ACEPTABA. En el medio el origen
--   seguia mostrando (y vendiendo) stock que ya no tenia.
--   Movimiento #6: 39,3 horas pendiente con 160 unidades fantasma en Tucuman.
--   Ademas, al no existir forma de editar ni cancelar un envio pendiente, lo
--   denegaron y lo recrearon (#7) un minuto despues.
--
-- SOLUCION:
--   1) crear_  -> valida y DESCUENTA el stock del origen en el acto.
--   2) aceptar_-> NO vuelve a descontar del origen (solo ingresa al destino).
--   3) denegar_-> RESTITUYE el stock al origen.
--   4) cancelar_ (NUEVA) -> el origen se retracta y recupera el stock.
--   5) editar_   (NUEVA) -> el origen corrige el envio ajustando el stock por delta.
--
-- IDEMPOTENCIA / LEGADO — columna `stock_descontado`:
--   Significa "el origen tiene estas unidades descontadas AHORA" (estado vivo,
--   no historico). Es lo que evita el doble descuento: aceptar solo descuenta
--   del origen si el flag esta en false (movimiento creado con la logica vieja).
--   Los pendientes que existan al momento del deploy quedan en false -> aceptar
--   usa el camino viejo y denegar no restituye. El deploy es seguro aun con
--   envios en vuelo, sin downtime.
--
--   Invariantes auditables:
--     estado='aceptada'                  => stock_descontado = true
--     estado IN ('denegada','cancelada') => stock_descontado = false
--
-- TRAZABILIDAD: la 076 nunca seteaba `app.stock_*`, asi que estos movimientos
-- caian en stock_historico como origen='auto' sin referencia (pendiente P1
-- STK-D de la mig 105). Ahora cada UPDATE de stock setea el contexto y el
-- trigger trg_stock_historico lo registra. NO se inserta a mano en
-- stock_historico (eso duplicaria filas).
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1) DDL + backfill
-- ----------------------------------------------------------------------------
ALTER TABLE public.movimientos_sucursal
  ADD COLUMN IF NOT EXISTS stock_descontado BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS total_unidades   INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS editado_por      UUID REFERENCES public.perfiles(id),
  ADD COLUMN IF NOT EXISTS editado_at       TIMESTAMPTZ;

COMMENT ON COLUMN public.movimientos_sucursal.stock_descontado IS
  'true = el origen tiene estas unidades descontadas AHORA. Evita el doble descuento al aceptar.';
COMMENT ON COLUMN public.movimientos_sucursal.motivo_rechazo IS
  'Motivo del rechazo (denegada) o de la retractacion (cancelada).';

ALTER TABLE public.movimientos_sucursal DROP CONSTRAINT IF EXISTS movimientos_sucursal_estado_check;
ALTER TABLE public.movimientos_sucursal ADD CONSTRAINT movimientos_sucursal_estado_check
  CHECK (estado IN ('pendiente', 'aceptada', 'denegada', 'cancelada'));

-- Historicos: las aceptadas ya movieron el stock (respeta el invariante).
UPDATE public.movimientos_sucursal SET stock_descontado = true WHERE estado = 'aceptada';
UPDATE public.movimientos_sucursal m SET total_unidades = COALESCE(
  (SELECT SUM(i.cantidad) FROM public.movimiento_sucursal_items i WHERE i.movimiento_id = m.id), 0);

-- ----------------------------------------------------------------------------
-- 2) crear_movimiento_sucursal — misma firma, ahora valida y descuenta
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crear_movimiento_sucursal(
  p_sucursal_destino_id bigint, p_notas text DEFAULT NULL, p_items jsonb DEFAULT '[]'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_origen bigint; v_mov_id bigint; v_agg record; v_prod productos%ROWTYPE;
  v_total numeric := 0; v_count integer := 0; v_unidades integer := 0;
  v_errores text[] := ARRAY[]::text[]; v_stock_prev integer;
BEGIN
  v_origen := current_sucursal_id();
  IF v_origen IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Sucursal no seleccionada'); END IF;
  IF p_sucursal_destino_id = v_origen THEN RETURN jsonb_build_object('success', false, 'error', 'El destino debe ser distinto al origen'); END IF;
  IF public._rol_en_sucursal(auth.uid(), v_origen) NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado'); END IF;
  IF NOT EXISTS (SELECT 1 FROM sucursales WHERE id = p_sucursal_destino_id AND activa IS NOT FALSE) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Sucursal destino inválida'); END IF;

  -- Pasada 1: validar TODO antes de tocar nada. Agrega por producto (dos lineas
  -- del mismo producto se validarian por separado contra el mismo stock) y
  -- bloquea en orden de id para no cruzarse con otro envio simultaneo.
  FOR v_agg IN
    SELECT (e->>'producto_id')::bigint AS pid, SUM(COALESCE((e->>'cantidad')::int, 0))::int AS cant
    FROM jsonb_array_elements(p_items) e
    WHERE COALESCE((e->>'cantidad')::int, 0) > 0
    GROUP BY 1 ORDER BY 1
  LOOP
    SELECT * INTO v_prod FROM productos WHERE id = v_agg.pid AND sucursal_id = v_origen FOR UPDATE;
    IF NOT FOUND THEN
      v_errores := array_append(v_errores, 'Producto ' || v_agg.pid || ' no existe en la sucursal origen');
    ELSIF v_prod.stock < v_agg.cant THEN
      v_errores := array_append(v_errores,
        v_prod.nombre || ': stock insuficiente (disponible ' || v_prod.stock || ', solicitado ' || v_agg.cant || ')');
    ELSE
      v_count := v_count + 1;
      v_unidades := v_unidades + v_agg.cant;
    END IF;
  END LOOP;

  IF array_length(v_errores, 1) > 0 THEN
    RETURN jsonb_build_object('success', false, 'error', array_to_string(v_errores, ' · '), 'errores', to_jsonb(v_errores));
  END IF;
  IF v_count = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'El movimiento no tiene items válidos');
  END IF;

  INSERT INTO movimientos_sucursal (sucursal_origen_id, sucursal_destino_id, estado, notas, creado_por, stock_descontado)
  VALUES (v_origen, p_sucursal_destino_id, 'pendiente', p_notas, auth.uid(), true)
  RETURNING id INTO v_mov_id;

  PERFORM set_config('app.stock_origen', 'movimiento_salida', true);
  PERFORM set_config('app.stock_ref_tipo', 'movimiento_sucursal', true);
  PERFORM set_config('app.stock_ref_id', v_mov_id::text, true);
  PERFORM set_config('app.stock_user_id', COALESCE(auth.uid()::text, ''), true);

  -- Pasada 2: descontar y snapshotear. Las filas siguen bloqueadas por la pasada 1.
  FOR v_agg IN
    SELECT (e->>'producto_id')::bigint AS pid, SUM(COALESCE((e->>'cantidad')::int, 0))::int AS cant
    FROM jsonb_array_elements(p_items) e
    WHERE COALESCE((e->>'cantidad')::int, 0) > 0
    GROUP BY 1 ORDER BY 1
  LOOP
    SELECT * INTO v_prod FROM productos WHERE id = v_agg.pid AND sucursal_id = v_origen;
    v_stock_prev := v_prod.stock;

    UPDATE productos SET stock = stock - v_agg.cant, updated_at = now()
      WHERE id = v_agg.pid AND sucursal_id = v_origen;

    INSERT INTO movimiento_sucursal_items (
      movimiento_id, producto_origen_id, cantidad,
      origen_nombre, origen_codigo, origen_tp_import_id, origen_categoria,
      origen_precio, origen_precio_sin_iva, origen_costo_sin_iva, origen_costo_con_iva,
      origen_impuestos_internos, origen_porcentaje_iva, origen_stock_minimo,
      origen_unidades_por_fardo, origen_etiqueta_bulto,
      stock_origen_anterior, stock_origen_nuevo
    ) VALUES (
      v_mov_id, v_prod.id, v_agg.cant,
      v_prod.nombre, v_prod.codigo, v_prod.tp_import_id, v_prod.categoria,
      v_prod.precio, v_prod.precio_sin_iva, v_prod.costo_sin_iva, v_prod.costo_con_iva,
      v_prod.impuestos_internos, v_prod.porcentaje_iva, v_prod.stock_minimo,
      v_prod.unidades_de_venta_por_fardo, v_prod.etiqueta_bulto,
      v_stock_prev, v_stock_prev - v_agg.cant
    );
    v_total := v_total + COALESCE(v_prod.costo_con_iva, v_prod.costo_sin_iva, 0) * v_agg.cant;
  END LOOP;

  UPDATE movimientos_sucursal SET total_costo = v_total, total_unidades = v_unidades WHERE id = v_mov_id;

  PERFORM public._notificar_sucursal_roles(
    p_sucursal_destino_id, auth.uid(), 'movimiento_pendiente',
    'Nuevo movimiento de stock para aceptar',
    COALESCE((SELECT nombre FROM sucursales WHERE id = v_origen), 'Otra sucursal')
      || ' envió ' || v_count || ' producto(s), ' || v_unidades || ' unidades. Ya salió del depósito.',
    'movimiento_sucursal', v_mov_id,
    jsonb_build_object('origen_id', v_origen, 'items', v_count, 'unidades', v_unidades)
  );

  RETURN jsonb_build_object('success', true, 'movimiento_id', v_mov_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END; $$;
ALTER FUNCTION public.crear_movimiento_sucursal(bigint, text, jsonb) OWNER TO postgres;

-- ----------------------------------------------------------------------------
-- 3) aceptar_movimiento_sucursal — no vuelve a descontar del origen
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.aceptar_movimiento_sucursal(
  p_movimiento_id bigint, p_resoluciones jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_mov movimientos_sucursal%ROWTYPE;
  v_destino bigint; v_item movimiento_sucursal_items%ROWTYPE;
  v_res jsonb; v_accion text; v_dest_id bigint;
  v_stock_o integer; v_stock_d integer;
  v_costo_dest numeric; v_costo_dest_neto numeric;
  v_items_count integer;
BEGIN
  SELECT * INTO v_mov FROM movimientos_sucursal WHERE id = p_movimiento_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Movimiento no encontrado'); END IF;
  IF v_mov.estado <> 'pendiente' THEN RETURN jsonb_build_object('success', false, 'error', 'El movimiento ya fue resuelto'); END IF;
  v_destino := v_mov.sucursal_destino_id;
  IF current_sucursal_id() <> v_destino THEN
    RETURN jsonb_build_object('success', false, 'error', 'Tenés que estar en la sucursal destino para aceptar'); END IF;
  IF public._rol_en_sucursal(auth.uid(), v_destino) NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado'); END IF;

  -- El origen pudo haber editado el envio despues de que el destino abrio el
  -- modal: los item_id de p_resoluciones serian viejos.
  SELECT COUNT(*) INTO v_items_count FROM movimiento_sucursal_items WHERE movimiento_id = p_movimiento_id;
  IF v_items_count <> jsonb_array_length(COALESCE(p_resoluciones, '[]'::jsonb)) THEN
    RETURN jsonb_build_object('success', false,
      'error', 'El envío fue modificado por la sucursal origen. Cerrá y volvé a abrirlo.');
  END IF;

  FOR v_item IN SELECT * FROM movimiento_sucursal_items WHERE movimiento_id = p_movimiento_id ORDER BY producto_origen_id LOOP
    SELECT r INTO v_res FROM jsonb_array_elements(p_resoluciones) r WHERE (r->>'item_id')::bigint = v_item.id LIMIT 1;
    IF v_res IS NULL THEN
      RAISE EXCEPTION 'Falta resolver el producto "%". Si el envío fue modificado, cerrá y volvé a abrirlo.', v_item.origen_nombre;
    END IF;
    v_accion := v_res->>'accion';

    -- Camino LEGADO (movimientos creados antes de la 139): el stock del origen
    -- todavia no se descontó, hay que hacerlo aca como antes.
    IF NOT v_mov.stock_descontado THEN
      SELECT stock INTO v_stock_o FROM productos
        WHERE id = v_item.producto_origen_id AND sucursal_id = v_mov.sucursal_origen_id FOR UPDATE;
      IF NOT FOUND THEN RAISE EXCEPTION 'El producto "%" ya no existe en la sucursal origen', v_item.origen_nombre; END IF;
      IF v_stock_o < v_item.cantidad THEN
        RAISE EXCEPTION 'Stock insuficiente en origen para "%": disponible %, solicitado %', v_item.origen_nombre, v_stock_o, v_item.cantidad;
      END IF;
    END IF;

    IF v_accion = 'crear_nuevo' THEN
      INSERT INTO productos (
        nombre, codigo, categoria, precio, precio_sin_iva, costo_sin_iva, costo_con_iva,
        impuestos_internos, porcentaje_iva, stock, stock_minimo, proveedor_id,
        unidades_de_venta_por_fardo, etiqueta_bulto, tp_import_id, sucursal_id
      ) VALUES (
        v_item.origen_nombre, v_item.origen_codigo, v_item.origen_categoria,
        COALESCE(v_item.origen_precio, 0), v_item.origen_precio_sin_iva, v_item.origen_costo_sin_iva, v_item.origen_costo_con_iva,
        v_item.origen_impuestos_internos, v_item.origen_porcentaje_iva, 0, v_item.origen_stock_minimo, NULL,
        v_item.origen_unidades_por_fardo, v_item.origen_etiqueta_bulto, v_item.origen_tp_import_id, v_destino
      ) RETURNING id, stock INTO v_dest_id, v_stock_d;
      v_costo_dest := v_item.origen_costo_con_iva;
      v_costo_dest_neto := v_item.origen_costo_sin_iva;
    ELSE
      v_dest_id := (v_res->>'producto_destino_id')::bigint;
      SELECT stock, costo_con_iva, costo_sin_iva INTO v_stock_d, v_costo_dest, v_costo_dest_neto
        FROM productos WHERE id = v_dest_id AND sucursal_id = v_destino FOR UPDATE;
      IF NOT FOUND THEN RAISE EXCEPTION 'El producto destino elegido no existe en la sucursal'; END IF;
      -- Regla de costo: queda el mayor entre origen y destino.
      v_costo_dest := GREATEST(COALESCE(v_costo_dest, 0), COALESCE(v_item.origen_costo_con_iva, 0));
      v_costo_dest_neto := GREATEST(COALESCE(v_costo_dest_neto, 0), COALESCE(v_item.origen_costo_sin_iva, 0));
    END IF;

    IF NOT v_mov.stock_descontado THEN
      PERFORM set_config('app.stock_origen', 'movimiento_salida', true);
      PERFORM set_config('app.stock_ref_tipo', 'movimiento_sucursal', true);
      PERFORM set_config('app.stock_ref_id', p_movimiento_id::text, true);
      PERFORM set_config('app.stock_user_id', COALESCE(auth.uid()::text, ''), true);
      UPDATE productos SET stock = stock - v_item.cantidad, updated_at = now()
        WHERE id = v_item.producto_origen_id AND sucursal_id = v_mov.sucursal_origen_id;
    END IF;

    -- set_config es transaction-local: re-setear porque el camino legado de
    -- arriba deja 'movimiento_salida' y este UPDATE es un ingreso.
    PERFORM set_config('app.stock_origen', 'movimiento_ingreso', true);
    PERFORM set_config('app.stock_ref_tipo', 'movimiento_sucursal', true);
    PERFORM set_config('app.stock_ref_id', p_movimiento_id::text, true);
    PERFORM set_config('app.stock_user_id', COALESCE(auth.uid()::text, ''), true);

    UPDATE productos SET stock = stock + v_item.cantidad,
        costo_con_iva = v_costo_dest, costo_sin_iva = v_costo_dest_neto, updated_at = now()
      WHERE id = v_dest_id AND sucursal_id = v_destino;

    -- stock_origen_anterior/nuevo ya los escribio crear_/editar_ cuando el flag
    -- esta en true: NO se pisan.
    UPDATE movimiento_sucursal_items SET
      producto_destino_id = v_dest_id,
      resolucion = CASE WHEN v_accion = 'crear_nuevo' THEN 'creado_nuevo' ELSE 'match_existente' END,
      costo_aplicado_destino = v_costo_dest,
      stock_origen_anterior = CASE WHEN v_mov.stock_descontado THEN stock_origen_anterior ELSE v_stock_o END,
      stock_origen_nuevo    = CASE WHEN v_mov.stock_descontado THEN stock_origen_nuevo ELSE v_stock_o - v_item.cantidad END,
      stock_destino_anterior = v_stock_d, stock_destino_nuevo = v_stock_d + v_item.cantidad
    WHERE id = v_item.id;
  END LOOP;

  UPDATE movimientos_sucursal
    SET estado = 'aceptada', stock_descontado = true, resuelto_por = auth.uid(), resuelto_at = now()
    WHERE id = p_movimiento_id;

  PERFORM public._notificar_sucursal_roles(
    v_mov.sucursal_origen_id, auth.uid(), 'movimiento_aceptado',
    'Movimiento aceptado',
    COALESCE((SELECT nombre FROM sucursales WHERE id = v_destino), 'La sucursal destino') || ' aceptó tu movimiento #' || p_movimiento_id || '.',
    'movimiento_sucursal', p_movimiento_id, jsonb_build_object('destino_id', v_destino)
  );

  RETURN jsonb_build_object('success', true, 'movimiento_id', p_movimiento_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END; $$;
ALTER FUNCTION public.aceptar_movimiento_sucursal(bigint, jsonb) OWNER TO postgres;

-- ----------------------------------------------------------------------------
-- 4) denegar_movimiento_sucursal — restituye el stock al origen
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.denegar_movimiento_sucursal(
  p_movimiento_id bigint, p_motivo text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_mov movimientos_sucursal%ROWTYPE; v_destino bigint;
  v_item movimiento_sucursal_items%ROWTYPE; v_rows integer;
BEGIN
  SELECT * INTO v_mov FROM movimientos_sucursal WHERE id = p_movimiento_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Movimiento no encontrado'); END IF;
  IF v_mov.estado <> 'pendiente' THEN RETURN jsonb_build_object('success', false, 'error', 'El movimiento ya fue resuelto'); END IF;
  v_destino := v_mov.sucursal_destino_id;
  IF current_sucursal_id() <> v_destino THEN
    RETURN jsonb_build_object('success', false, 'error', 'Tenés que estar en la sucursal destino'); END IF;
  IF public._rol_en_sucursal(auth.uid(), v_destino) NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado'); END IF;

  IF v_mov.stock_descontado THEN
    PERFORM set_config('app.stock_origen', 'movimiento_denegado', true);
    PERFORM set_config('app.stock_ref_tipo', 'movimiento_sucursal', true);
    PERFORM set_config('app.stock_ref_id', p_movimiento_id::text, true);
    PERFORM set_config('app.stock_user_id', COALESCE(auth.uid()::text, ''), true);

    FOR v_item IN SELECT * FROM movimiento_sucursal_items WHERE movimiento_id = p_movimiento_id ORDER BY producto_origen_id LOOP
      UPDATE productos SET stock = stock + v_item.cantidad, updated_at = now()
        WHERE id = v_item.producto_origen_id AND sucursal_id = v_mov.sucursal_origen_id;
      GET DIAGNOSTICS v_rows = ROW_COUNT;
      IF v_rows = 0 THEN
        RAISE EXCEPTION 'No se puede devolver "%" al origen: el producto ya no existe ahí', v_item.origen_nombre;
      END IF;
    END LOOP;
  END IF;

  UPDATE movimientos_sucursal SET estado = 'denegada', stock_descontado = false, motivo_rechazo = p_motivo,
      resuelto_por = auth.uid(), resuelto_at = now()
    WHERE id = p_movimiento_id;

  PERFORM public._notificar_sucursal_roles(
    v_mov.sucursal_origen_id, auth.uid(), 'movimiento_denegado',
    'Movimiento denegado',
    COALESCE((SELECT nombre FROM sucursales WHERE id = v_destino), 'La sucursal destino') || ' denegó tu movimiento #' || p_movimiento_id
      || CASE WHEN v_mov.stock_descontado THEN '. Se devolvió el stock.' ELSE '' END
      || COALESCE(' Motivo: ' || p_motivo, ''),
    'movimiento_sucursal', p_movimiento_id, jsonb_build_object('destino_id', v_destino, 'motivo', p_motivo)
  );

  RETURN jsonb_build_object('success', true, 'movimiento_id', p_movimiento_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END; $$;
ALTER FUNCTION public.denegar_movimiento_sucursal(bigint, text) OWNER TO postgres;

-- ----------------------------------------------------------------------------
-- 5) cancelar_movimiento_sucursal (NUEVA) — el origen se retracta
-- ----------------------------------------------------------------------------
-- Sin esto, con el descuento preventivo un envio cargado por error dejaria el
-- stock descontado indefinidamente: el origen no tenia NINGUNA accion posible.
CREATE OR REPLACE FUNCTION public.cancelar_movimiento_sucursal(
  p_movimiento_id bigint, p_motivo text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_mov movimientos_sucursal%ROWTYPE; v_origen bigint;
  v_item movimiento_sucursal_items%ROWTYPE; v_rows integer;
BEGIN
  SELECT * INTO v_mov FROM movimientos_sucursal WHERE id = p_movimiento_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Movimiento no encontrado'); END IF;
  IF v_mov.estado <> 'pendiente' THEN RETURN jsonb_build_object('success', false, 'error', 'El movimiento ya fue resuelto'); END IF;
  v_origen := v_mov.sucursal_origen_id;
  IF current_sucursal_id() <> v_origen THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo la sucursal que creó el envío puede cancelarlo'); END IF;
  IF public._rol_en_sucursal(auth.uid(), v_origen) <> 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo un admin puede cancelar un envío'); END IF;

  IF v_mov.stock_descontado THEN
    PERFORM set_config('app.stock_origen', 'movimiento_cancelado', true);
    PERFORM set_config('app.stock_ref_tipo', 'movimiento_sucursal', true);
    PERFORM set_config('app.stock_ref_id', p_movimiento_id::text, true);
    PERFORM set_config('app.stock_user_id', COALESCE(auth.uid()::text, ''), true);

    FOR v_item IN SELECT * FROM movimiento_sucursal_items WHERE movimiento_id = p_movimiento_id ORDER BY producto_origen_id LOOP
      UPDATE productos SET stock = stock + v_item.cantidad, updated_at = now()
        WHERE id = v_item.producto_origen_id AND sucursal_id = v_origen;
      GET DIAGNOSTICS v_rows = ROW_COUNT;
      IF v_rows = 0 THEN
        RAISE EXCEPTION 'No se puede devolver "%" al stock: el producto ya no existe', v_item.origen_nombre;
      END IF;
    END LOOP;
  END IF;

  UPDATE movimientos_sucursal SET estado = 'cancelada', stock_descontado = false, motivo_rechazo = p_motivo,
      resuelto_por = auth.uid(), resuelto_at = now()
    WHERE id = p_movimiento_id;

  PERFORM public._notificar_sucursal_roles(
    v_mov.sucursal_destino_id, auth.uid(), 'movimiento_cancelado',
    'Movimiento cancelado por el origen',
    COALESCE((SELECT nombre FROM sucursales WHERE id = v_origen), 'La sucursal origen')
      || ' canceló el movimiento #' || p_movimiento_id || COALESCE('. Motivo: ' || p_motivo, ''),
    'movimiento_sucursal', p_movimiento_id, jsonb_build_object('origen_id', v_origen, 'motivo', p_motivo)
  );

  RETURN jsonb_build_object('success', true, 'movimiento_id', p_movimiento_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END; $$;
ALTER FUNCTION public.cancelar_movimiento_sucursal(bigint, text) OWNER TO postgres;

-- ----------------------------------------------------------------------------
-- 6) editar_movimiento_sucursal (NUEVA) — corregir un envio pendiente
-- ----------------------------------------------------------------------------
-- Ajusta el stock por DELTA por producto (no restituye-todo-y-reaplica): un
-- producto cuya cantidad no cambia no genera UPDATE ni fila en stock_historico.
-- El destino NO es editable: cambiarlo es semanticamente otro envio (cancelar +
-- crear) y obligaria a "des-notificar" al destino original.
CREATE OR REPLACE FUNCTION public.editar_movimiento_sucursal(
  p_movimiento_id bigint, p_notas text DEFAULT NULL, p_items jsonb DEFAULT '[]'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_mov movimientos_sucursal%ROWTYPE; v_origen bigint; v_agg record; v_prod productos%ROWTYPE;
  v_errores text[] := ARRAY[]::text[]; v_rows integer;
  v_total numeric := 0; v_count integer := 0; v_unidades integer := 0;
BEGIN
  SELECT * INTO v_mov FROM movimientos_sucursal WHERE id = p_movimiento_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Movimiento no encontrado'); END IF;
  IF v_mov.estado <> 'pendiente' THEN RETURN jsonb_build_object('success', false, 'error', 'Solo se puede editar un envío pendiente'); END IF;
  v_origen := v_mov.sucursal_origen_id;
  IF current_sucursal_id() <> v_origen THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo la sucursal que creó el envío puede editarlo'); END IF;
  IF public._rol_en_sucursal(auth.uid(), v_origen) <> 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo un admin puede editar un envío'); END IF;
  IF NOT v_mov.stock_descontado THEN
    RETURN jsonb_build_object('success', false,
      'error', 'Este envío es anterior al descuento preventivo. Cancelalo y creá uno nuevo.'); END IF;

  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) e
    WHERE COALESCE((e->>'cantidad')::int, 0) > 0
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'El envío no puede quedar sin productos. Usá Cancelar.');
  END IF;

  -- Pasada 1: validar los deltas positivos (lo que sale de mas).
  FOR v_agg IN
    WITH nuevas AS (
      SELECT (e->>'producto_id')::bigint AS pid, SUM(COALESCE((e->>'cantidad')::int, 0))::int AS cant
      FROM jsonb_array_elements(p_items) e WHERE COALESCE((e->>'cantidad')::int, 0) > 0 GROUP BY 1
    ), viejas AS (
      SELECT producto_origen_id AS pid, SUM(cantidad)::int AS cant
      FROM movimiento_sucursal_items WHERE movimiento_id = p_movimiento_id GROUP BY 1
    )
    SELECT COALESCE(n.pid, v.pid) AS pid,
           COALESCE(n.cant, 0) - COALESCE(v.cant, 0) AS delta
    FROM nuevas n FULL OUTER JOIN viejas v ON v.pid = n.pid
    ORDER BY 1
  LOOP
    CONTINUE WHEN v_agg.delta = 0;
    SELECT * INTO v_prod FROM productos WHERE id = v_agg.pid AND sucursal_id = v_origen FOR UPDATE;
    IF NOT FOUND THEN
      v_errores := array_append(v_errores, 'Producto ' || v_agg.pid || ' no existe en la sucursal origen');
    ELSIF v_agg.delta > 0 AND v_prod.stock < v_agg.delta THEN
      v_errores := array_append(v_errores,
        v_prod.nombre || ': stock insuficiente para agregar ' || v_agg.delta || ' (disponible ' || v_prod.stock || ')');
    END IF;
  END LOOP;

  IF array_length(v_errores, 1) > 0 THEN
    RETURN jsonb_build_object('success', false, 'error', array_to_string(v_errores, ' · '), 'errores', to_jsonb(v_errores));
  END IF;

  PERFORM set_config('app.stock_origen', 'movimiento_editado', true);
  PERFORM set_config('app.stock_ref_tipo', 'movimiento_sucursal', true);
  PERFORM set_config('app.stock_ref_id', p_movimiento_id::text, true);
  PERFORM set_config('app.stock_user_id', COALESCE(auth.uid()::text, ''), true);

  -- Pasada 2: aplicar solo los deltas != 0.
  FOR v_agg IN
    WITH nuevas AS (
      SELECT (e->>'producto_id')::bigint AS pid, SUM(COALESCE((e->>'cantidad')::int, 0))::int AS cant
      FROM jsonb_array_elements(p_items) e WHERE COALESCE((e->>'cantidad')::int, 0) > 0 GROUP BY 1
    ), viejas AS (
      SELECT producto_origen_id AS pid, SUM(cantidad)::int AS cant
      FROM movimiento_sucursal_items WHERE movimiento_id = p_movimiento_id GROUP BY 1
    )
    SELECT COALESCE(n.pid, v.pid) AS pid,
           COALESCE(n.cant, 0) - COALESCE(v.cant, 0) AS delta
    FROM nuevas n FULL OUTER JOIN viejas v ON v.pid = n.pid
    ORDER BY 1
  LOOP
    CONTINUE WHEN v_agg.delta = 0;
    -- delta > 0: salen mas unidades (resta). delta < 0: vuelven al stock (suma).
    UPDATE productos SET stock = stock - v_agg.delta, updated_at = now()
      WHERE id = v_agg.pid AND sucursal_id = v_origen;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows = 0 THEN
      RAISE EXCEPTION 'El producto % ya no existe en la sucursal origen', v_agg.pid;
    END IF;
  END LOOP;

  -- Reemplazar los items: mientras esta pendiente no hay resoluciones que
  -- preservar (producto_destino_id es NULL).
  DELETE FROM movimiento_sucursal_items WHERE movimiento_id = p_movimiento_id;

  FOR v_agg IN
    SELECT (e->>'producto_id')::bigint AS pid, SUM(COALESCE((e->>'cantidad')::int, 0))::int AS cant
    FROM jsonb_array_elements(p_items) e
    WHERE COALESCE((e->>'cantidad')::int, 0) > 0
    GROUP BY 1 ORDER BY 1
  LOOP
    SELECT * INTO v_prod FROM productos WHERE id = v_agg.pid AND sucursal_id = v_origen;
    IF NOT FOUND THEN RAISE EXCEPTION 'El producto % ya no existe en la sucursal origen', v_agg.pid; END IF;

    INSERT INTO movimiento_sucursal_items (
      movimiento_id, producto_origen_id, cantidad,
      origen_nombre, origen_codigo, origen_tp_import_id, origen_categoria,
      origen_precio, origen_precio_sin_iva, origen_costo_sin_iva, origen_costo_con_iva,
      origen_impuestos_internos, origen_porcentaje_iva, origen_stock_minimo,
      origen_unidades_por_fardo, origen_etiqueta_bulto,
      stock_origen_anterior, stock_origen_nuevo
    ) VALUES (
      p_movimiento_id, v_prod.id, v_agg.cant,
      v_prod.nombre, v_prod.codigo, v_prod.tp_import_id, v_prod.categoria,
      v_prod.precio, v_prod.precio_sin_iva, v_prod.costo_sin_iva, v_prod.costo_con_iva,
      v_prod.impuestos_internos, v_prod.porcentaje_iva, v_prod.stock_minimo,
      v_prod.unidades_de_venta_por_fardo, v_prod.etiqueta_bulto,
      -- el stock ya quedo descontado arriba: "anterior" es el de antes de este envio
      v_prod.stock + v_agg.cant, v_prod.stock
    );
    v_total := v_total + COALESCE(v_prod.costo_con_iva, v_prod.costo_sin_iva, 0) * v_agg.cant;
    v_count := v_count + 1;
    v_unidades := v_unidades + v_agg.cant;
  END LOOP;

  UPDATE movimientos_sucursal
    SET notas = p_notas, total_costo = v_total, total_unidades = v_unidades,
        editado_por = auth.uid(), editado_at = now()
    WHERE id = p_movimiento_id;

  PERFORM public._notificar_sucursal_roles(
    v_mov.sucursal_destino_id, auth.uid(), 'movimiento_editado',
    'Movimiento modificado por el origen',
    COALESCE((SELECT nombre FROM sucursales WHERE id = v_origen), 'La sucursal origen')
      || ' modificó el movimiento #' || p_movimiento_id || ': ahora son ' || v_count || ' producto(s), ' || v_unidades || ' unidades.',
    'movimiento_sucursal', p_movimiento_id,
    jsonb_build_object('origen_id', v_origen, 'items', v_count, 'unidades', v_unidades)
  );

  RETURN jsonb_build_object('success', true, 'movimiento_id', p_movimiento_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END; $$;
ALTER FUNCTION public.editar_movimiento_sucursal(bigint, text, jsonb) OWNER TO postgres;

GRANT EXECUTE ON FUNCTION public.cancelar_movimiento_sucursal(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.editar_movimiento_sucursal(bigint, text, jsonb) TO authenticated;

COMMIT;
