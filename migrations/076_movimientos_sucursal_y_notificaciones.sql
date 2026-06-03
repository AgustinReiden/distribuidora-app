-- Migración 076: Movimientos entre sucursales con aprobación + notificaciones (DB)
--
-- Reemplaza el flujo viejo de transferencias (un solo lado, inmediato) por un
-- traslado A→B con estado: la sucursal ORIGEN crea un movimiento "pendiente"
-- (NO mueve stock), y la sucursal DESTINO lo ACEPTA o DENIEGA. Al aceptar se
-- mueve el stock atómicamente (baja A, sube B), con matching de productos y
-- regla de costo = max(origen, destino). Precios no se tocan (salvo al crear un
-- producto nuevo en destino, que copia el de origen).
--
-- Notificaciones: tabla DB con fan-out por usuario (admins/encargados de la
-- sucursal destinataria). La campanita las lee por polling.
--
-- Las tablas viejas transferencias_stock / transferencia_items NO se tocan
-- (quedan como histórico). Forward-only.

BEGIN;

-- =========================================================================
-- TABLAS
-- =========================================================================

CREATE TABLE IF NOT EXISTS public.movimientos_sucursal (
  id BIGSERIAL PRIMARY KEY,
  sucursal_origen_id BIGINT NOT NULL REFERENCES public.sucursales(id),
  sucursal_destino_id BIGINT NOT NULL REFERENCES public.sucursales(id),
  estado VARCHAR(20) NOT NULL DEFAULT 'pendiente'
    CHECK (estado IN ('pendiente', 'aceptada', 'denegada')),
  total_costo NUMERIC NOT NULL DEFAULT 0,
  notas TEXT,
  motivo_rechazo TEXT,
  creado_por UUID NOT NULL REFERENCES public.perfiles(id),
  resuelto_por UUID REFERENCES public.perfiles(id),
  created_at TIMESTAMPTZ DEFAULT now(),
  resuelto_at TIMESTAMPTZ,
  CONSTRAINT mov_suc_distintas CHECK (sucursal_origen_id <> sucursal_destino_id)
);

CREATE TABLE IF NOT EXISTS public.movimiento_sucursal_items (
  id BIGSERIAL PRIMARY KEY,
  movimiento_id BIGINT NOT NULL REFERENCES public.movimientos_sucursal(id) ON DELETE CASCADE,
  producto_origen_id BIGINT NOT NULL REFERENCES public.productos(id),
  cantidad INTEGER NOT NULL CHECK (cantidad > 0),
  -- Snapshot del producto origen al crear (inmutable: sobrevive si origen edita/borra,
  -- y permite a destino verlo aunque la RLS de productos oculte las filas de origen).
  origen_nombre TEXT NOT NULL,
  origen_codigo VARCHAR(50),
  origen_tp_import_id BIGINT,
  origen_categoria TEXT,
  origen_precio NUMERIC,
  origen_precio_sin_iva NUMERIC,
  origen_costo_sin_iva NUMERIC,
  origen_costo_con_iva NUMERIC,
  origen_impuestos_internos NUMERIC,
  origen_porcentaje_iva NUMERIC,
  origen_stock_minimo INTEGER,
  origen_unidades_por_fardo NUMERIC,
  origen_etiqueta_bulto TEXT,
  -- Resolución al aceptar
  producto_destino_id BIGINT REFERENCES public.productos(id),
  resolucion VARCHAR(20) CHECK (resolucion IN ('match_existente', 'creado_nuevo')),
  costo_aplicado_destino NUMERIC,
  stock_origen_anterior INTEGER,
  stock_origen_nuevo INTEGER,
  stock_destino_anterior INTEGER,
  stock_destino_nuevo INTEGER,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.notificaciones (
  id BIGSERIAL PRIMARY KEY,
  usuario_id UUID NOT NULL REFERENCES public.perfiles(id),
  sucursal_id BIGINT REFERENCES public.sucursales(id),
  tipo VARCHAR(40) NOT NULL,
  titulo TEXT NOT NULL,
  mensaje TEXT,
  entidad_tipo VARCHAR(40),
  entidad_id BIGINT,
  payload JSONB DEFAULT '{}'::jsonb,
  leida BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now(),
  leida_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_mov_suc_origen ON public.movimientos_sucursal (sucursal_origen_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_mov_suc_destino ON public.movimientos_sucursal (sucursal_destino_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_mov_suc_estado ON public.movimientos_sucursal (estado);
CREATE INDEX IF NOT EXISTS idx_mov_items_mov ON public.movimiento_sucursal_items (movimiento_id);
CREATE INDEX IF NOT EXISTS idx_notif_usuario_unread ON public.notificaciones (usuario_id, leida, created_at DESC);

-- =========================================================================
-- RLS
-- =========================================================================

ALTER TABLE public.movimientos_sucursal ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS mov_suc_select ON public.movimientos_sucursal;
CREATE POLICY mov_suc_select ON public.movimientos_sucursal FOR SELECT TO authenticated
  USING (sucursal_origen_id = current_sucursal_id() OR sucursal_destino_id = current_sucursal_id());

ALTER TABLE public.movimiento_sucursal_items ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS mov_items_select ON public.movimiento_sucursal_items;
CREATE POLICY mov_items_select ON public.movimiento_sucursal_items FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.movimientos_sucursal m
    WHERE m.id = movimiento_sucursal_items.movimiento_id
      AND (m.sucursal_origen_id = current_sucursal_id() OR m.sucursal_destino_id = current_sucursal_id())
  ));

ALTER TABLE public.notificaciones ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS notif_select ON public.notificaciones;
CREATE POLICY notif_select ON public.notificaciones FOR SELECT TO authenticated
  USING (usuario_id = auth.uid());
DROP POLICY IF EXISTS notif_update ON public.notificaciones;
CREATE POLICY notif_update ON public.notificaciones FOR UPDATE TO authenticated
  USING (usuario_id = auth.uid()) WITH CHECK (usuario_id = auth.uid());

GRANT SELECT ON public.movimientos_sucursal TO authenticated;
GRANT SELECT ON public.movimiento_sucursal_items TO authenticated;
GRANT SELECT ON public.notificaciones TO authenticated;
GRANT UPDATE (leida, leida_at) ON public.notificaciones TO authenticated;

-- =========================================================================
-- HELPERS
-- =========================================================================

-- Rol efectivo del usuario en una sucursal (resuelve 'mismo' → rol global).
CREATE OR REPLACE FUNCTION public._rol_en_sucursal(p_uid uuid, p_suc bigint)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT CASE WHEN us.rol = 'mismo' THEN p.rol ELSE us.rol END
  FROM usuario_sucursales us
  JOIN perfiles p ON p.id = us.usuario_id
  WHERE us.usuario_id = p_uid AND us.sucursal_id = p_suc
  LIMIT 1;
$$;
ALTER FUNCTION public._rol_en_sucursal(uuid, bigint) OWNER TO postgres;

-- Fan-out de una notificación a todos los admin/encargado de una sucursal,
-- excluyendo al actor. Dedup por usuario.
CREATE OR REPLACE FUNCTION public._notificar_sucursal_roles(
  p_sucursal_id bigint, p_excluir_uid uuid, p_tipo varchar, p_titulo text,
  p_mensaje text, p_entidad_tipo varchar, p_entidad_id bigint, p_payload jsonb
) RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$
  INSERT INTO notificaciones (usuario_id, sucursal_id, tipo, titulo, mensaje, entidad_tipo, entidad_id, payload)
  SELECT DISTINCT us.usuario_id, p_sucursal_id, p_tipo, p_titulo, p_mensaje, p_entidad_tipo, p_entidad_id, p_payload
  FROM usuario_sucursales us
  JOIN perfiles p ON p.id = us.usuario_id
  WHERE us.sucursal_id = p_sucursal_id
    AND (CASE WHEN us.rol = 'mismo' THEN p.rol ELSE us.rol END) IN ('admin', 'encargado')
    AND p.activo IS NOT FALSE
    AND us.usuario_id <> COALESCE(p_excluir_uid, '00000000-0000-0000-0000-000000000000'::uuid);
$$;
ALTER FUNCTION public._notificar_sucursal_roles(bigint, uuid, varchar, text, text, varchar, bigint, jsonb) OWNER TO postgres;

CREATE OR REPLACE FUNCTION public.marcar_notificacion_leida(p_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  UPDATE notificaciones SET leida = true, leida_at = now()
  WHERE id = p_id AND usuario_id = auth.uid();
  RETURN jsonb_build_object('success', true);
END; $$;
ALTER FUNCTION public.marcar_notificacion_leida(bigint) OWNER TO postgres;

CREATE OR REPLACE FUNCTION public.marcar_todas_notificaciones_leidas()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  UPDATE notificaciones SET leida = true, leida_at = now()
  WHERE usuario_id = auth.uid() AND leida = false;
  RETURN jsonb_build_object('success', true);
END; $$;
ALTER FUNCTION public.marcar_todas_notificaciones_leidas() OWNER TO postgres;

-- =========================================================================
-- RPC: crear movimiento (origen). NO mueve stock.
-- =========================================================================
CREATE OR REPLACE FUNCTION public.crear_movimiento_sucursal(
  p_sucursal_destino_id bigint, p_notas text DEFAULT NULL, p_items jsonb DEFAULT '[]'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_origen bigint; v_mov_id bigint; v_item jsonb; v_prod productos%ROWTYPE;
  v_cant integer; v_total numeric := 0; v_count integer := 0;
BEGIN
  v_origen := current_sucursal_id();
  IF v_origen IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Sucursal no seleccionada'); END IF;
  IF p_sucursal_destino_id = v_origen THEN RETURN jsonb_build_object('success', false, 'error', 'El destino debe ser distinto al origen'); END IF;
  IF public._rol_en_sucursal(auth.uid(), v_origen) NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado'); END IF;
  IF NOT EXISTS (SELECT 1 FROM sucursales WHERE id = p_sucursal_destino_id AND activa IS NOT FALSE) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Sucursal destino inválida'); END IF;

  INSERT INTO movimientos_sucursal (sucursal_origen_id, sucursal_destino_id, estado, notas, creado_por)
  VALUES (v_origen, p_sucursal_destino_id, 'pendiente', p_notas, auth.uid())
  RETURNING id INTO v_mov_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_cant := COALESCE((v_item->>'cantidad')::int, 0);
    IF v_cant <= 0 THEN CONTINUE; END IF;
    SELECT * INTO v_prod FROM productos WHERE id = (v_item->>'producto_id')::bigint AND sucursal_id = v_origen;
    IF NOT FOUND THEN RAISE EXCEPTION 'Producto % no encontrado en la sucursal origen', (v_item->>'producto_id'); END IF;

    INSERT INTO movimiento_sucursal_items (
      movimiento_id, producto_origen_id, cantidad,
      origen_nombre, origen_codigo, origen_tp_import_id, origen_categoria,
      origen_precio, origen_precio_sin_iva, origen_costo_sin_iva, origen_costo_con_iva,
      origen_impuestos_internos, origen_porcentaje_iva, origen_stock_minimo,
      origen_unidades_por_fardo, origen_etiqueta_bulto
    ) VALUES (
      v_mov_id, v_prod.id, v_cant,
      v_prod.nombre, v_prod.codigo, v_prod.tp_import_id, v_prod.categoria,
      v_prod.precio, v_prod.precio_sin_iva, v_prod.costo_sin_iva, v_prod.costo_con_iva,
      v_prod.impuestos_internos, v_prod.porcentaje_iva, v_prod.stock_minimo,
      v_prod.unidades_de_venta_por_fardo, v_prod.etiqueta_bulto
    );
    v_total := v_total + COALESCE(v_prod.costo_con_iva, v_prod.costo_sin_iva, 0) * v_cant;
    v_count := v_count + 1;
  END LOOP;

  IF v_count = 0 THEN RAISE EXCEPTION 'El movimiento no tiene items válidos'; END IF;

  UPDATE movimientos_sucursal SET total_costo = v_total WHERE id = v_mov_id;

  PERFORM public._notificar_sucursal_roles(
    p_sucursal_destino_id, auth.uid(), 'movimiento_pendiente',
    'Nuevo movimiento de stock para aceptar',
    COALESCE((SELECT nombre FROM sucursales WHERE id = v_origen), 'Otra sucursal') || ' envió ' || v_count || ' producto(s).',
    'movimiento_sucursal', v_mov_id,
    jsonb_build_object('origen_id', v_origen, 'items', v_count)
  );

  RETURN jsonb_build_object('success', true, 'movimiento_id', v_mov_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END; $$;
ALTER FUNCTION public.crear_movimiento_sucursal(bigint, text, jsonb) OWNER TO postgres;

-- =========================================================================
-- RPC: aceptar movimiento (destino). Mueve stock atómicamente.
--   p_resoluciones: [{item_id, accion: 'match_existente'|'crear_nuevo', producto_destino_id?}]
-- =========================================================================
CREATE OR REPLACE FUNCTION public.aceptar_movimiento_sucursal(
  p_movimiento_id bigint, p_resoluciones jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_mov movimientos_sucursal%ROWTYPE;
  v_destino bigint; v_item movimiento_sucursal_items%ROWTYPE;
  v_res jsonb; v_accion text; v_dest_id bigint;
  v_stock_o integer; v_stock_d integer;
  v_costo_dest numeric; v_costo_dest_neto numeric;
BEGIN
  SELECT * INTO v_mov FROM movimientos_sucursal WHERE id = p_movimiento_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Movimiento no encontrado'); END IF;
  IF v_mov.estado <> 'pendiente' THEN RETURN jsonb_build_object('success', false, 'error', 'El movimiento ya fue resuelto'); END IF;
  v_destino := v_mov.sucursal_destino_id;
  IF current_sucursal_id() <> v_destino THEN
    RETURN jsonb_build_object('success', false, 'error', 'Tenés que estar en la sucursal destino para aceptar'); END IF;
  IF public._rol_en_sucursal(auth.uid(), v_destino) NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado'); END IF;

  FOR v_item IN SELECT * FROM movimiento_sucursal_items WHERE movimiento_id = p_movimiento_id ORDER BY producto_origen_id LOOP
    SELECT r INTO v_res FROM jsonb_array_elements(p_resoluciones) r WHERE (r->>'item_id')::bigint = v_item.id LIMIT 1;
    IF v_res IS NULL THEN RAISE EXCEPTION 'Falta resolver el producto "%"', v_item.origen_nombre; END IF;
    v_accion := v_res->>'accion';

    SELECT stock INTO v_stock_o FROM productos
      WHERE id = v_item.producto_origen_id AND sucursal_id = v_mov.sucursal_origen_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'El producto "%" ya no existe en la sucursal origen', v_item.origen_nombre; END IF;
    IF v_stock_o < v_item.cantidad THEN
      RAISE EXCEPTION 'Stock insuficiente en origen para "%": disponible %, solicitado %', v_item.origen_nombre, v_stock_o, v_item.cantidad;
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

    UPDATE productos SET stock = stock - v_item.cantidad, updated_at = now()
      WHERE id = v_item.producto_origen_id AND sucursal_id = v_mov.sucursal_origen_id;
    UPDATE productos SET stock = stock + v_item.cantidad,
        costo_con_iva = v_costo_dest, costo_sin_iva = v_costo_dest_neto, updated_at = now()
      WHERE id = v_dest_id AND sucursal_id = v_destino;

    UPDATE movimiento_sucursal_items SET
      producto_destino_id = v_dest_id,
      resolucion = CASE WHEN v_accion = 'crear_nuevo' THEN 'creado_nuevo' ELSE 'match_existente' END,
      costo_aplicado_destino = v_costo_dest,
      stock_origen_anterior = v_stock_o, stock_origen_nuevo = v_stock_o - v_item.cantidad,
      stock_destino_anterior = v_stock_d, stock_destino_nuevo = v_stock_d + v_item.cantidad
    WHERE id = v_item.id;
  END LOOP;

  UPDATE movimientos_sucursal SET estado = 'aceptada', resuelto_por = auth.uid(), resuelto_at = now()
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

-- =========================================================================
-- RPC: denegar movimiento (destino). No mueve stock.
-- =========================================================================
CREATE OR REPLACE FUNCTION public.denegar_movimiento_sucursal(
  p_movimiento_id bigint, p_motivo text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_mov movimientos_sucursal%ROWTYPE; v_destino bigint;
BEGIN
  SELECT * INTO v_mov FROM movimientos_sucursal WHERE id = p_movimiento_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Movimiento no encontrado'); END IF;
  IF v_mov.estado <> 'pendiente' THEN RETURN jsonb_build_object('success', false, 'error', 'El movimiento ya fue resuelto'); END IF;
  v_destino := v_mov.sucursal_destino_id;
  IF current_sucursal_id() <> v_destino THEN
    RETURN jsonb_build_object('success', false, 'error', 'Tenés que estar en la sucursal destino'); END IF;
  IF public._rol_en_sucursal(auth.uid(), v_destino) NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado'); END IF;

  UPDATE movimientos_sucursal SET estado = 'denegada', motivo_rechazo = p_motivo,
      resuelto_por = auth.uid(), resuelto_at = now()
    WHERE id = p_movimiento_id;

  PERFORM public._notificar_sucursal_roles(
    v_mov.sucursal_origen_id, auth.uid(), 'movimiento_denegado',
    'Movimiento denegado',
    COALESCE((SELECT nombre FROM sucursales WHERE id = v_destino), 'La sucursal destino') || ' denegó tu movimiento #' || p_movimiento_id || COALESCE('. Motivo: ' || p_motivo, ''),
    'movimiento_sucursal', p_movimiento_id, jsonb_build_object('destino_id', v_destino, 'motivo', p_motivo)
  );

  RETURN jsonb_build_object('success', true, 'movimiento_id', p_movimiento_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END; $$;
ALTER FUNCTION public.denegar_movimiento_sucursal(bigint, text) OWNER TO postgres;

-- Grants de ejecución (RPCs de cara al cliente).
GRANT EXECUTE ON FUNCTION public.crear_movimiento_sucursal(bigint, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.aceptar_movimiento_sucursal(bigint, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.denegar_movimiento_sucursal(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.marcar_notificacion_leida(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.marcar_todas_notificaciones_leidas() TO authenticated;

COMMIT;
