-- =========================================================================
-- mig 286 · LOS VENCIMIENTOS Y EL COSTO VIAJAN CON EL MOVIMIENTO
--
-- Hasta aca un movimiento entre sucursales movia unidades y nada mas:
--
--   * El ORIGEN consumia sus lotes FEFO (el trigger `trg_lotes_sincronizar`
--     se lleva la parte que excede la bolsa, como en cualquier bajada), pero
--     nadie anotaba QUE lotes salieron. El DESTINO recibia todo con
--     'movimiento_ingreso', que no esta en la lista blanca del trigger: las
--     unidades caian a su bolsa "sin vencimiento" y el vencimiento se perdia
--     en el viaje.
--   * El destino tomaba GREATEST de costo_con_iva/costo_sin_iva y no tocaba
--     `costo_promedio` ni `costo_real`: el promedio del destino quedaba como
--     si la mercaderia no hubiera llegado.
--
-- Decisiones del dueño:
--
--   1. Los vencimientos viajan. El origen consume FEFO como hoy y el destino
--      recibe lotes con los mismos vencimientos.
--   2. Costo destino (match_existente):
--        costo_promedio = (stock_previo × promedio_destino + n × promedio_origen)
--                         / (stock_previo + n), round 4;
--        si stock_previo <= 0 o el destino no tiene promedio → promedio_origen.
--        promedio_origen = snapshot `movimiento_sucursal_items.origen_costo_promedio`
--        (columna nueva, la llenan crear y editar). Sin snapshot (items
--        anteriores a esta migracion) se lee el vivo del origen.
--        costo_con_iva, costo_sin_iva Y costo_real = GREATEST(destino, origen).
--        crear_nuevo sigue copiando la valuacion del origen (mig 211), con una
--        diferencia: el costo_promedio tambien sale del snapshot del item
--        (COALESCE(snapshot, vivo)), igual que en match_existente. Si no, un
--        cambio del promedio del origen entre el envio y la aceptacion se
--        colaba solo en los productos nuevos.
--      Si el origen no tiene promedio, el del destino no se toca (no hay base
--      para mezclar). `costo_promedio <= 0` cuenta como "sin promedio", igual
--      que en registrar_compra_completa.
--
-- COMO SE SABE QUE LOTES SALIERON. Tabla nueva `movimiento_sucursal_item_lotes`:
-- una fila por (item, lote) con el vencimiento y las unidades. La escriben
-- crear y editar con una FOTO de `cantidad_restante` de los lotes del
-- producto origen antes y despues de su UPDATE de stock: lo que bajo es lo que
-- consumio el trigger para ese item. No se toca `_consumir_lotes_fefo` ni la
-- lista blanca del trigger. Las unidades que salieron de la BOLSA del origen
-- no tienen fila: item.cantidad − Σ filas = unidades sin vencimiento.
-- `fecha_vencimiento` se guarda aparte del `lote_id` porque el lote puede
-- desaparecer mientras el envio esta pendiente (cancelar la compra le borra
-- los lotes, mig 224): el FK es ON DELETE SET NULL y el vencimiento sigue.
--
-- ACEPTAR. Despues del UPDATE de stock del destino ('movimiento_ingreso', como
-- hoy, va a la bolsa), por cada vencimiento registrado del item se crea o se
-- suma un lote en el producto destino: `compra_id NULL`, origen 'movimiento'.
-- Es exactamente lo que hace `crear_lote_manual`: etiquetar unidades de la
-- bolsa, que acaban de entrar. Σ cantidad_restante <= stock se conserva por
-- construccion: se etiqueta a lo sumo
--   LEAST(item.cantidad, GREATEST(stock_previo_destino + item.cantidad, 0))
-- es decir, lo que entro y nunca mas que el stock resultante. El GREATEST
-- cubre un destino con stock negativo (STK-B lo prohibe, pero si pasara, las
-- unidades que "tapan el agujero" no pueden quedar etiquetadas o LOTE-A se
-- pone rojo). Asi LOTE-A/B/C no se mueven. Si ya hay un lote 'movimiento' sin compra con ese vencimiento en el
-- producto destino, se le suman cantidad y cantidad_restante.
-- Item sin registro (el movimiento #18, pendiente desde antes de esta
-- migracion, o cualquier unidad que salio de la bolsa) → todo a la bolsa del
-- destino, sin error: es el comportamiento de hoy.
--
-- POR QUE ORIGEN 'movimiento' Y NO 'manual'. 'manual' dice "alguien lo cargo a
-- mano" y no lo es; la ficha le pone la marca "a mano" (ProductoLotes.tsx).
-- El CHECK suma un valor; ningun lector lo filtra por igualdad salvo esa marca
-- del front (el tipo TS `'compra' | 'manual'` hay que ampliarlo; no rompe nada
-- en runtime: no hay Zod sobre lotes). Como `compra_id` es NULL,
-- `registrar_nota_credito_lote` lo trata como lote sin compra: solo baja, sin
-- nota al proveedor (la compra es de otra sucursal), que es lo correcto.
-- `crear_lote_manual` suma a cualquier lote sin compra del mismo vencimiento,
-- incluido uno 'movimiento': aceptable, el vencimiento es el mismo.
--
-- EDITAR. Restaura con 'movimiento_editado' (lista blanca) cuando baja la
-- cantidad y consume FEFO cuando la sube. La restauracion FEFO rellena los
-- huecos MAS TEMPRANOS del producto, que pueden no ser los lotes que salieron
-- con este envio (un hueco de una venta anterior, por ejemplo). Por eso el
-- registro se reconstruye con la foto de lo que efectivamente paso:
--   * cantidad sube: la foto dice que lotes consumio la re-bajada; se agregan.
--   * cantidad baja en d: se quitan d unidades del registro del item, en este
--     orden: (1) de los lotes que la foto dice que recibieron la devolucion
--     y que estaban en el registro (ese vencimiento volvio al origen, no puede
--     seguir viajando: si no, se duplica); (2) de las unidades SIN registro
--     (bolsa): si la devolucion relleno un hueco ajeno, el origen "gano" ese
--     vencimiento y lo que deja de viajar es lo que no tenia vencimiento
--     conocido; (3) del registro, vencimiento mas LEJANO primero, para que al
--     destino le llegue lo mas proximo a vencer (el error queda del lado de
--     avisar antes).
--   Los items se recrean como hoy (re-snapshot de precios y costos), asi que
--   las filas del registro se re-apuntan del item viejo al nuevo del mismo
--   producto antes de borrar los viejos. Un producto que sale del envio se
--   lleva sus filas por el CASCADE.
--
-- CANCELAR / DENEGAR. La devolucion al origen queda como hoy: restauracion
-- FEFO por la lista blanca. Se evaluo devolver a los lotes exactos del
-- registro y se descarto: habria que sacar 'movimiento_cancelado' /
-- 'movimiento_denegado' de la lista blanca (cambia el comportamiento de los
-- envios viejos sin registro) y resolver aparte el lote que ya no existe. La
-- FEFO, en el peor caso, devuelve a un vencimiento MAS TEMPRANO que el real:
-- el contador miente del lado de avisar antes. Las filas del registro se
-- borran (el envio ya no lleva nada).
--
-- Lista blanca de `sincronizar_lotes_stock`: sin cambios. STK-F sigue verde:
-- el unico `stock = stock +` nuevo vive en aceptar, que ya declaraba origen.
--
-- Permisos: tabla nueva con RLS (lectura para quien ve el movimiento, mismo
-- predicado que `mov_items_select`), sin escritura para nadie fuera de las
-- funciones definer; anon sin nada. Los helpers `_mov_lotes_*` son de server:
-- REVOKE PUBLIC, anon, authenticated (los llaman funciones SECURITY DEFINER).
-- Las RPCs reemplazadas conservan firma y ACL (CREATE OR REPLACE).
--
-- Numero PROVISORIO: se reserva al aplicar (ver MANIFEST).
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1 · Esquema
-- -------------------------------------------------------------------------
ALTER TABLE public.producto_lotes DROP CONSTRAINT producto_lotes_origen_check;
ALTER TABLE public.producto_lotes ADD CONSTRAINT producto_lotes_origen_check
  CHECK (origen = ANY (ARRAY['compra'::text, 'manual'::text, 'movimiento'::text]));

ALTER TABLE public.movimiento_sucursal_items ADD COLUMN origen_costo_promedio numeric;
COMMENT ON COLUMN public.movimiento_sucursal_items.origen_costo_promedio IS
  'costo_promedio del producto origen al crear/editar el envio. Base del promedio ponderado del destino al aceptar. mig 286.';

-- El unico envio pendiente al aplicar (#18) no tiene snapshot: se toma el
-- promedio vivo de hoy, que es lo mas cercano al de su creacion. Los
-- aceptados no se tocan (su costo ya se aplico).
UPDATE public.movimiento_sucursal_items i
   SET origen_costo_promedio = p.costo_promedio
  FROM public.movimientos_sucursal m, public.productos p
 WHERE m.id = i.movimiento_id
   AND m.estado = 'pendiente'
   AND p.id = i.producto_origen_id
   AND p.sucursal_id = m.sucursal_origen_id
   AND i.origen_costo_promedio IS NULL;

-- sucursal_id = sucursal ORIGEN (la del lote). FK compuesta al lote, como
-- pedido_item_lotes (Trampa 6): el lote tiene que ser de esa sucursal. El
-- SET NULL es solo de lote_id: el vencimiento y la sucursal quedan.
CREATE TABLE public.movimiento_sucursal_item_lotes (
  id                bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  item_id           bigint  NOT NULL REFERENCES public.movimiento_sucursal_items(id) ON DELETE CASCADE,
  sucursal_id       bigint  NOT NULL REFERENCES public.sucursales(id),
  lote_id           bigint,
  fecha_vencimiento date    NOT NULL,
  cantidad          integer NOT NULL CHECK (cantidad > 0),
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT movimiento_sucursal_item_lotes_lote_fk
    FOREIGN KEY (lote_id, sucursal_id) REFERENCES public.producto_lotes(id, sucursal_id)
    ON DELETE SET NULL (lote_id)
);
CREATE INDEX idx_mov_item_lotes_item ON public.movimiento_sucursal_item_lotes (item_id);
CREATE INDEX idx_mov_item_lotes_lote ON public.movimiento_sucursal_item_lotes (lote_id);

COMMENT ON TABLE public.movimiento_sucursal_item_lotes IS
  'Que lotes (vencimientos) del origen consumio cada item de un movimiento entre sucursales. item.cantidad - SUM(cantidad) = unidades que salieron de la bolsa. Lo escriben crear/editar; aceptar lo replica como lotes origen=movimiento en el destino. mig 286.';

ALTER TABLE public.movimiento_sucursal_item_lotes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.movimiento_sucursal_item_lotes FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.movimiento_sucursal_item_lotes TO authenticated;
GRANT ALL ON public.movimiento_sucursal_item_lotes TO service_role;

CREATE POLICY mov_item_lotes_select ON public.movimiento_sucursal_item_lotes
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1
      FROM public.movimiento_sucursal_items i
      JOIN public.movimientos_sucursal m ON m.id = i.movimiento_id
     WHERE i.id = movimiento_sucursal_item_lotes.item_id
       AND (m.sucursal_origen_id = public.current_sucursal_id()
            OR m.sucursal_destino_id = public.current_sucursal_id())
  ));

-- -------------------------------------------------------------------------
-- 2 · Helpers (server-only)
-- -------------------------------------------------------------------------
-- Foto de los contadores: {"<lote_id>": cantidad_restante}.
CREATE OR REPLACE FUNCTION public._mov_lotes_foto(p_producto_id bigint, p_sucursal_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(jsonb_object_agg(l.id::text, l.cantidad_restante), '{}'::jsonb)
    FROM public.producto_lotes l
   WHERE l.producto_id = p_producto_id
     AND l.sucursal_id = p_sucursal_id;
$function$;

-- Diferencia contra la foto: p_signo = -1 → lo que BAJO (salida);
-- p_signo = 1 → lo que SUBIO (devolucion). Solo lotes que estaban en la foto.
-- [{lote_id, fecha_vencimiento, cantidad}] en orden FEFO.
CREATE OR REPLACE FUNCTION public._mov_lotes_diff(p_producto_id bigint, p_sucursal_id bigint,
                                                 p_foto jsonb, p_signo integer)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'lote_id', l.id, 'fecha_vencimiento', l.fecha_vencimiento, 'cantidad', d.cant)
           ORDER BY l.fecha_vencimiento, l.id), '[]'::jsonb)
    FROM public.producto_lotes l
    CROSS JOIN LATERAL (
      SELECT p_signo * (l.cantidad_restante - (p_foto->>l.id::text)::integer) AS cant
    ) d
   WHERE l.producto_id = p_producto_id
     AND l.sucursal_id = p_sucursal_id
     AND p_foto ? l.id::text
     AND d.cant > 0;
$function$;

-- Registra en el item lo que la foto dice que salio. Devuelve lo registrado.
CREATE OR REPLACE FUNCTION public._mov_lotes_registrar_salida(p_item_id bigint, p_producto_id bigint,
                                                             p_sucursal_id bigint, p_foto jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_n integer;
BEGIN
  INSERT INTO public.movimiento_sucursal_item_lotes (item_id, sucursal_id, lote_id, fecha_vencimiento, cantidad)
  SELECT p_item_id, p_sucursal_id, x.lote_id, x.fecha_vencimiento, x.cantidad
    FROM jsonb_to_recordset(public._mov_lotes_diff(p_producto_id, p_sucursal_id, p_foto, -1))
         AS x(lote_id bigint, fecha_vencimiento date, cantidad integer);
  SELECT COALESCE(SUM(cantidad), 0) INTO v_n
    FROM public.movimiento_sucursal_item_lotes WHERE item_id = p_item_id;
  RETURN v_n;
END;
$function$;

-- Quita p_quitar unidades del registro de un item cuya cantidad baja (editar).
-- Orden: (1) lotes que recibieron la devolucion (p_devueltos, foto de la
-- restauracion) y estaban registrados; (2) unidades sin registro (bolsa);
-- (3) registro restante, vencimiento mas lejano primero. Ver encabezado.
CREATE OR REPLACE FUNCTION public._mov_lotes_descontar(p_item_id bigint, p_cantidad_item integer,
                                                      p_quitar integer, p_devueltos jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rest       integer := p_quitar;
  v_viaja      integer := p_cantidad_item;
  v_g          integer;
  v_q          integer;
  v_registrado integer;
  g            record;
  r            record;
BEGIN
  -- (1)
  FOR g IN SELECT x.lote_id, x.cantidad
             FROM jsonb_to_recordset(COALESCE(p_devueltos, '[]'::jsonb)) AS x(lote_id bigint, cantidad integer)
  LOOP
    EXIT WHEN v_rest <= 0;
    v_g := g.cantidad;
    FOR r IN SELECT id, cantidad FROM public.movimiento_sucursal_item_lotes
              WHERE item_id = p_item_id AND lote_id = g.lote_id
              ORDER BY id FOR UPDATE
    LOOP
      EXIT WHEN v_g <= 0 OR v_rest <= 0;
      v_q := LEAST(r.cantidad, v_g, v_rest);
      IF v_q >= r.cantidad THEN
        DELETE FROM public.movimiento_sucursal_item_lotes WHERE id = r.id;
      ELSE
        UPDATE public.movimiento_sucursal_item_lotes SET cantidad = cantidad - v_q WHERE id = r.id;
      END IF;
      v_g := v_g - v_q;
      v_rest := v_rest - v_q;
      v_viaja := v_viaja - v_q;
    END LOOP;
  END LOOP;

  -- (2)
  IF v_rest > 0 THEN
    SELECT COALESCE(SUM(cantidad), 0) INTO v_registrado
      FROM public.movimiento_sucursal_item_lotes WHERE item_id = p_item_id;
    v_rest := v_rest - LEAST(v_rest, GREATEST(v_viaja - v_registrado, 0));
  END IF;

  -- (3)
  IF v_rest > 0 THEN
    FOR r IN SELECT id, cantidad FROM public.movimiento_sucursal_item_lotes
              WHERE item_id = p_item_id
              ORDER BY fecha_vencimiento DESC, id DESC FOR UPDATE
    LOOP
      EXIT WHEN v_rest <= 0;
      v_q := LEAST(r.cantidad, v_rest);
      IF v_q >= r.cantidad THEN
        DELETE FROM public.movimiento_sucursal_item_lotes WHERE id = r.id;
      ELSE
        UPDATE public.movimiento_sucursal_item_lotes SET cantidad = cantidad - v_q WHERE id = r.id;
      END IF;
      v_rest := v_rest - v_q;
    END LOOP;
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public._mov_lotes_foto(bigint, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._mov_lotes_diff(bigint, bigint, jsonb, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._mov_lotes_registrar_salida(bigint, bigint, bigint, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._mov_lotes_descontar(bigint, integer, integer, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._mov_lotes_foto(bigint, bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public._mov_lotes_diff(bigint, bigint, jsonb, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public._mov_lotes_registrar_salida(bigint, bigint, bigint, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public._mov_lotes_descontar(bigint, integer, integer, jsonb) TO service_role;

-- -------------------------------------------------------------------------
-- 3 · crear_movimiento_sucursal
-- -------------------------------------------------------------------------
-- Cuerpo VIVO + foto alrededor del UPDATE de stock, RETURNING del item,
-- registro de lotes y snapshot de costo_promedio. Nada mas cambia.
CREATE OR REPLACE FUNCTION public.crear_movimiento_sucursal(p_sucursal_destino_id bigint, p_notas text DEFAULT NULL::text, p_items jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_origen bigint; v_mov_id bigint; v_agg record; v_prod productos%ROWTYPE;
  v_total numeric := 0; v_count integer := 0; v_unidades integer := 0;
  v_errores text[] := ARRAY[]::text[]; v_stock_prev integer;
  v_foto jsonb; v_item_id bigint;
BEGIN
  v_origen := current_sucursal_id();
  IF v_origen IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Sucursal no seleccionada'); END IF;
  IF p_sucursal_destino_id = v_origen THEN RETURN jsonb_build_object('success', false, 'error', 'El destino debe ser distinto al origen'); END IF;
  IF public._rol_en_sucursal(auth.uid(), v_origen) NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado'); END IF;
  IF NOT EXISTS (SELECT 1 FROM sucursales WHERE id = p_sucursal_destino_id AND activa IS NOT FALSE) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Sucursal destino inválida'); END IF;

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

  FOR v_agg IN
    SELECT (e->>'producto_id')::bigint AS pid, SUM(COALESCE((e->>'cantidad')::int, 0))::int AS cant
    FROM jsonb_array_elements(p_items) e
    WHERE COALESCE((e->>'cantidad')::int, 0) > 0
    GROUP BY 1 ORDER BY 1
  LOOP
    SELECT * INTO v_prod FROM productos WHERE id = v_agg.pid AND sucursal_id = v_origen;
    v_stock_prev := v_prod.stock;

    -- mig 286: foto de los lotes antes de la bajada; el trigger consume FEFO.
    v_foto := public._mov_lotes_foto(v_agg.pid, v_origen);

    UPDATE productos SET stock = stock - v_agg.cant, updated_at = now()
      WHERE id = v_agg.pid AND sucursal_id = v_origen;

    INSERT INTO movimiento_sucursal_items (
      movimiento_id, producto_origen_id, cantidad,
      origen_nombre, origen_codigo, origen_tp_import_id, origen_categoria,
      origen_precio, origen_precio_sin_iva, origen_costo_sin_iva, origen_costo_con_iva,
      origen_impuestos_internos, origen_ii_encuadre_id, origen_porcentaje_iva, origen_condicion_iva, origen_stock_minimo,
      origen_unidades_por_fardo, origen_etiqueta_bulto,
      stock_origen_anterior, stock_origen_nuevo, origen_costo_promedio
    ) VALUES (
      v_mov_id, v_prod.id, v_agg.cant,
      v_prod.nombre, v_prod.codigo, v_prod.tp_import_id, v_prod.categoria,
      v_prod.precio, v_prod.precio_sin_iva, v_prod.costo_sin_iva, v_prod.costo_con_iva,
      v_prod.impuestos_internos, v_prod.ii_encuadre_id, v_prod.porcentaje_iva, v_prod.condicion_iva, v_prod.stock_minimo,
      v_prod.unidades_de_venta_por_fardo, v_prod.etiqueta_bulto,
      v_stock_prev, v_stock_prev - v_agg.cant, v_prod.costo_promedio
    ) RETURNING id INTO v_item_id;

    -- mig 286: que lotes (vencimientos) se llevo este item.
    PERFORM public._mov_lotes_registrar_salida(v_item_id, v_agg.pid, v_origen, v_foto);

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
END; $function$;

-- -------------------------------------------------------------------------
-- 4 · editar_movimiento_sucursal
-- -------------------------------------------------------------------------
-- Cuerpo VIVO + foto por producto en el loop de stock, reconstruccion del
-- registro (ver encabezado) y snapshot de costo_promedio. El DELETE de los
-- items viejos pasa a DESPUES del INSERT de los nuevos, para re-apuntarles
-- el registro; el resultado visible (items recreados) es el mismo.
CREATE OR REPLACE FUNCTION public.editar_movimiento_sucursal(p_movimiento_id bigint, p_notas text DEFAULT NULL::text, p_items jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_mov movimientos_sucursal%ROWTYPE; v_origen bigint; v_agg record; v_prod productos%ROWTYPE;
  v_errores text[] := ARRAY[]::text[]; v_rows integer;
  v_total numeric := 0; v_count integer := 0; v_unidades integer := 0;
  v_foto jsonb; v_altas jsonb := '[]'::jsonb; v_viejos bigint[]; v_item_viejo record;
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

  -- mig 286: los items de antes de la edicion (se borran al final).
  SELECT COALESCE(array_agg(id), '{}') INTO v_viejos
    FROM movimiento_sucursal_items WHERE movimiento_id = p_movimiento_id;

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
    v_foto := public._mov_lotes_foto(v_agg.pid, v_origen);
    UPDATE productos SET stock = stock - v_agg.delta, updated_at = now()
      WHERE id = v_agg.pid AND sucursal_id = v_origen;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows = 0 THEN
      RAISE EXCEPTION 'El producto % ya no existe en la sucursal origen', v_agg.pid;
    END IF;

    -- mig 286: lo que efectivamente paso con los lotes en este UPDATE.
    IF v_agg.delta > 0 THEN
      -- Sale mas: se agrega lo que consumio la re-bajada (al item nuevo, abajo).
      SELECT v_altas || COALESCE(jsonb_agg(d || jsonb_build_object('pid', v_agg.pid)), '[]'::jsonb)
        INTO v_altas
        FROM jsonb_array_elements(public._mov_lotes_diff(v_agg.pid, v_origen, v_foto, -1)) d;
    ELSE
      -- Sale menos: se descuenta del registro del item viejo.
      SELECT id, cantidad INTO v_item_viejo
        FROM movimiento_sucursal_items
       WHERE movimiento_id = p_movimiento_id AND producto_origen_id = v_agg.pid
       ORDER BY id LIMIT 1;
      IF FOUND THEN
        PERFORM public._mov_lotes_descontar(v_item_viejo.id, v_item_viejo.cantidad, -v_agg.delta,
                                            public._mov_lotes_diff(v_agg.pid, v_origen, v_foto, 1));
      END IF;
    END IF;
  END LOOP;

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
      origen_impuestos_internos, origen_ii_encuadre_id, origen_porcentaje_iva, origen_condicion_iva, origen_stock_minimo,
      origen_unidades_por_fardo, origen_etiqueta_bulto,
      stock_origen_anterior, stock_origen_nuevo, origen_costo_promedio
    ) VALUES (
      p_movimiento_id, v_prod.id, v_agg.cant,
      v_prod.nombre, v_prod.codigo, v_prod.tp_import_id, v_prod.categoria,
      v_prod.precio, v_prod.precio_sin_iva, v_prod.costo_sin_iva, v_prod.costo_con_iva,
      v_prod.impuestos_internos, v_prod.ii_encuadre_id, v_prod.porcentaje_iva, v_prod.condicion_iva, v_prod.stock_minimo,
      v_prod.unidades_de_venta_por_fardo, v_prod.etiqueta_bulto,
      v_prod.stock + v_agg.cant, v_prod.stock, v_prod.costo_promedio
    );
    v_total := v_total + COALESCE(v_prod.costo_con_iva, v_prod.costo_sin_iva, 0) * v_agg.cant;
    v_count := v_count + 1;
    v_unidades := v_unidades + v_agg.cant;
  END LOOP;

  -- mig 286: el registro del item viejo pasa al nuevo del mismo producto; lo
  -- agregado por la re-bajada se cuelga del nuevo; los viejos se borran (un
  -- producto que salio del envio se lleva sus filas por el CASCADE).
  UPDATE movimiento_sucursal_item_lotes l
     SET item_id = n.id
    FROM movimiento_sucursal_items o
    JOIN movimiento_sucursal_items n
      ON n.movimiento_id = o.movimiento_id
     AND n.producto_origen_id = o.producto_origen_id
     AND NOT (n.id = ANY(v_viejos))
   WHERE l.item_id = o.id
     AND o.id = ANY(v_viejos);

  DELETE FROM movimiento_sucursal_items WHERE id = ANY(v_viejos);

  INSERT INTO movimiento_sucursal_item_lotes (item_id, sucursal_id, lote_id, fecha_vencimiento, cantidad)
  SELECT n.id, v_origen, a.lote_id, a.fecha_vencimiento, a.cantidad
    FROM jsonb_to_recordset(v_altas) AS a(pid bigint, lote_id bigint, fecha_vencimiento date, cantidad integer)
    JOIN movimiento_sucursal_items n
      ON n.movimiento_id = p_movimiento_id AND n.producto_origen_id = a.pid;

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
END; $function$;

-- -------------------------------------------------------------------------
-- 5 · aceptar_movimiento_sucursal
-- -------------------------------------------------------------------------
-- Cuerpo VIVO + (a) el costo del origen se lee en los dos caminos; (b)
-- match_existente pondera costo_promedio y lleva costo_real a GREATEST;
-- (c) los vencimientos registrados se replican como lotes del destino; (d)
-- el camino viejo sin descuento preventivo tambien registra lo que consume.
CREATE OR REPLACE FUNCTION public.aceptar_movimiento_sucursal(p_movimiento_id bigint, p_resoluciones jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_mov movimientos_sucursal%ROWTYPE;
  v_destino bigint; v_item movimiento_sucursal_items%ROWTYPE;
  v_res jsonb; v_accion text; v_dest_id bigint;
  v_stock_o integer; v_stock_d integer;
  v_costo_dest numeric; v_costo_dest_neto numeric;
  v_items_count integer;
  v_orig_costo_real numeric; v_orig_costo_promedio numeric; v_orig_tipo_compra varchar;
  v_dest_promedio numeric; v_dest_real numeric; v_po numeric;
  v_promedio_nuevo numeric; v_real_nuevo numeric;
  v_foto jsonb; v_venc record; v_lote_dest bigint; v_por_etiquetar integer; v_toma integer;
BEGIN
  SELECT * INTO v_mov FROM movimientos_sucursal WHERE id = p_movimiento_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Movimiento no encontrado'); END IF;
  IF v_mov.estado <> 'pendiente' THEN RETURN jsonb_build_object('success', false, 'error', 'El movimiento ya fue resuelto'); END IF;
  v_destino := v_mov.sucursal_destino_id;
  IF current_sucursal_id() <> v_destino THEN
    RETURN jsonb_build_object('success', false, 'error', 'Tenés que estar en la sucursal destino para aceptar'); END IF;
  IF public._rol_en_sucursal(auth.uid(), v_destino) NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado'); END IF;

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

    IF NOT v_mov.stock_descontado THEN
      SELECT stock INTO v_stock_o FROM productos
        WHERE id = v_item.producto_origen_id AND sucursal_id = v_mov.sucursal_origen_id FOR UPDATE;
      IF NOT FOUND THEN RAISE EXCEPTION 'El producto "%" ya no existe en la sucursal origen', v_item.origen_nombre; END IF;
      IF v_stock_o < v_item.cantidad THEN
        RAISE EXCEPTION 'Stock insuficiente en origen para "%": disponible %, solicitado %', v_item.origen_nombre, v_stock_o, v_item.cantidad;
      END IF;
    END IF;

    -- mig 211: valuacion del origen. mig 286: se lee para los dos caminos.
    SELECT o.costo_real, o.costo_promedio, o.ultimo_tipo_compra
      INTO v_orig_costo_real, v_orig_costo_promedio, v_orig_tipo_compra
      FROM productos o
      WHERE o.id = v_item.producto_origen_id AND o.sucursal_id = v_mov.sucursal_origen_id;
    -- mig 286: el promedio del origen sale del snapshot del item (vivo si no
    -- hay), en las dos ramas.
    v_po := COALESCE(v_item.origen_costo_promedio, v_orig_costo_promedio);

    IF v_accion = 'crear_nuevo' THEN
      -- mig 211: el producto nace en el destino con la valuacion del origen.
      INSERT INTO productos (
        nombre, codigo, categoria, precio, precio_sin_iva, costo_sin_iva, costo_con_iva,
        impuestos_internos, ii_encuadre_id, porcentaje_iva, condicion_iva, stock, stock_minimo, proveedor_id,
        unidades_de_venta_por_fardo, etiqueta_bulto, tp_import_id, sucursal_id,
        costo_real, costo_promedio, ultimo_tipo_compra
      ) VALUES (
        v_item.origen_nombre, v_item.origen_codigo, v_item.origen_categoria,
        COALESCE(v_item.origen_precio, 0), v_item.origen_precio_sin_iva, v_item.origen_costo_sin_iva, v_item.origen_costo_con_iva,
        v_item.origen_impuestos_internos, v_item.origen_ii_encuadre_id, v_item.origen_porcentaje_iva,
        COALESCE(v_item.origen_condicion_iva, 'gravado'), 0, v_item.origen_stock_minimo, NULL,
        v_item.origen_unidades_por_fardo, v_item.origen_etiqueta_bulto, v_item.origen_tp_import_id, v_destino,
        v_orig_costo_real, v_po, v_orig_tipo_compra
      ) RETURNING id, stock INTO v_dest_id, v_stock_d;
      v_costo_dest := v_item.origen_costo_con_iva;
      v_costo_dest_neto := v_item.origen_costo_sin_iva;
      -- La copia de la 211 se mantiene (el UPDATE de abajo reescribe lo mismo),
      -- con el promedio del snapshot.
      v_promedio_nuevo := v_po;
      v_real_nuevo := v_orig_costo_real;
    ELSE
      v_dest_id := (v_res->>'producto_destino_id')::bigint;
      SELECT stock, costo_con_iva, costo_sin_iva, costo_promedio, costo_real
        INTO v_stock_d, v_costo_dest, v_costo_dest_neto, v_dest_promedio, v_dest_real
        FROM productos WHERE id = v_dest_id AND sucursal_id = v_destino FOR UPDATE;
      IF NOT FOUND THEN RAISE EXCEPTION 'El producto destino elegido no existe en la sucursal'; END IF;
      v_costo_dest := GREATEST(COALESCE(v_costo_dest, 0), COALESCE(v_item.origen_costo_con_iva, 0));
      v_costo_dest_neto := GREATEST(COALESCE(v_costo_dest_neto, 0), COALESCE(v_item.origen_costo_sin_iva, 0));

      -- mig 286: promedio ponderado con el stock PREVIO del destino (leido
      -- arriba con FOR UPDATE, antes del UPDATE de stock). Base del origen:
      -- el snapshot del item; sin snapshot, el vivo (v_po, arriba).
      IF v_po IS NULL OR v_po <= 0 THEN
        v_promedio_nuevo := v_dest_promedio;
      ELSIF v_stock_d <= 0 OR v_dest_promedio IS NULL OR v_dest_promedio <= 0 THEN
        v_promedio_nuevo := v_po;
      ELSE
        v_promedio_nuevo := round(
          (v_stock_d::numeric * v_dest_promedio + v_item.cantidad * v_po)
          / (v_stock_d + v_item.cantidad), 4);
      END IF;
      -- GREATEST ignora NULL: si uno solo tiene costo_real, queda ese.
      v_real_nuevo := GREATEST(v_dest_real, v_orig_costo_real);
    END IF;

    IF NOT v_mov.stock_descontado THEN
      PERFORM set_config('app.stock_origen', 'movimiento_salida', true);
      PERFORM set_config('app.stock_ref_tipo', 'movimiento_sucursal', true);
      PERFORM set_config('app.stock_ref_id', p_movimiento_id::text, true);
      PERFORM set_config('app.stock_user_id', COALESCE(auth.uid()::text, ''), true);
      v_foto := public._mov_lotes_foto(v_item.producto_origen_id, v_mov.sucursal_origen_id);
      UPDATE productos SET stock = stock - v_item.cantidad, updated_at = now()
        WHERE id = v_item.producto_origen_id AND sucursal_id = v_mov.sucursal_origen_id;
      PERFORM public._mov_lotes_registrar_salida(v_item.id, v_item.producto_origen_id,
                                                 v_mov.sucursal_origen_id, v_foto);
    END IF;

    PERFORM set_config('app.stock_origen', 'movimiento_ingreso', true);
    PERFORM set_config('app.stock_ref_tipo', 'movimiento_sucursal', true);
    PERFORM set_config('app.stock_ref_id', p_movimiento_id::text, true);
    PERFORM set_config('app.stock_user_id', COALESCE(auth.uid()::text, ''), true);

    UPDATE productos SET stock = stock + v_item.cantidad,
        costo_con_iva = v_costo_dest, costo_sin_iva = v_costo_dest_neto,
        costo_promedio = v_promedio_nuevo, costo_real = v_real_nuevo, updated_at = now()
      WHERE id = v_dest_id AND sucursal_id = v_destino;

    -- mig 286: las unidades entraron a la bolsa del destino ('movimiento_ingreso'
    -- no esta en la lista blanca). Se etiquetan con los vencimientos que
    -- salieron del origen, como crear_lote_manual: nunca mas que lo que entro
    -- ni que el stock resultante (destino con stock negativo → LOTE-A).
    v_por_etiquetar := LEAST(v_item.cantidad, GREATEST(v_stock_d + v_item.cantidad, 0));
    FOR v_venc IN
      SELECT fecha_vencimiento, SUM(cantidad)::integer AS cant
        FROM movimiento_sucursal_item_lotes
       WHERE item_id = v_item.id
       GROUP BY fecha_vencimiento
       ORDER BY fecha_vencimiento
    LOOP
      EXIT WHEN v_por_etiquetar <= 0;
      v_toma := LEAST(v_venc.cant, v_por_etiquetar);
      SELECT id INTO v_lote_dest
        FROM producto_lotes
       WHERE producto_id = v_dest_id AND sucursal_id = v_destino
         AND fecha_vencimiento = v_venc.fecha_vencimiento
         AND compra_id IS NULL AND origen = 'movimiento'
       ORDER BY id LIMIT 1
       FOR UPDATE;
      IF v_lote_dest IS NOT NULL THEN
        UPDATE producto_lotes
           SET cantidad = cantidad + v_toma, cantidad_restante = cantidad_restante + v_toma
         WHERE id = v_lote_dest;
      ELSE
        INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante,
                                    compra_id, origen, usuario_id)
        VALUES (v_dest_id, v_destino, v_venc.fecha_vencimiento, v_toma, v_toma, NULL, 'movimiento', auth.uid());
      END IF;
      v_por_etiquetar := v_por_etiquetar - v_toma;
    END LOOP;

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
END; $function$;

-- -------------------------------------------------------------------------
-- 6 · cancelar / denegar: la devolucion queda FEFO, el registro se borra
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancelar_movimiento_sucursal(p_movimiento_id bigint, p_motivo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  -- mig 286: el envio ya no lleva nada; la devolucion a los lotes la hizo el
  -- trigger (FEFO, 'movimiento_cancelado' esta en la lista blanca).
  DELETE FROM movimiento_sucursal_item_lotes
   WHERE item_id IN (SELECT id FROM movimiento_sucursal_items WHERE movimiento_id = p_movimiento_id);

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
END; $function$;

CREATE OR REPLACE FUNCTION public.denegar_movimiento_sucursal(p_movimiento_id bigint, p_motivo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  -- mig 286: idem cancelar.
  DELETE FROM movimiento_sucursal_item_lotes
   WHERE item_id IN (SELECT id FROM movimiento_sucursal_items WHERE movimiento_id = p_movimiento_id);

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
END; $function$;

-- -------------------------------------------------------------------------
-- 7 · Ensayo funcional (subtransaccion que se revierte; molde 283)
-- -------------------------------------------------------------------------
-- Un admin con rol admin en dos sucursales activas (O → D). Productos
-- sinteticos en O con lotes (dias = vencimiento - hoy):
--   PA: stock 30, lotes 30d×10 y 60d×10, bolsa 10, promedio 100
--   PB: stock 8, sin lotes, promedio 50                (crear_nuevo)
--   PG: stock 10, lote 20d×5, promedio 70               (envio "sin registro")
--   PH: stock 20, lotes 10d×10 y 40d×5, bolsa 5         (cancelar / denegar)
-- y en D: PD (stock 20, promedio 200, real 150, c/IVA 100, s/IVA 80, con un
-- lote 'movimiento' 30d×2 para ver la fusion) y PGd (stock 0, sin costos).
--   a · crear {PA 25, PB 8}: PA se lleva bolsa 10 + 30d×10 + 60d×5
--   b · editar PA 25→20: la devolucion FEFO rellena 30d; registro 30d×5 60d×5
--   c · editar PA 20→22: la re-bajada consume 30d×2; registro 30d×7 60d×5
--   d · aceptar (con el promedio vivo de PA y PB en 999: manda el snapshot)
--       PD: stock 42, lotes 30d 9/9 (fusion) y 60d 5/5, promedio 147.619,
--       real 150, c/IVA 121, s/IVA 100. PB nace en D: stock 8, sin lotes, prom 50
--   e · crear {PG 8} + se borra su registro (= envio viejo) + aceptar → PGd:
--       stock 8, sin lotes, promedio 70 (stock previo 0 → el del origen)
--   f · el #18 real, si sigue pendiente: aceptar con match por codigo (o
--       crear_nuevo) no falla y no le crea lotes a nadie
--   g · crear {PH 12} + cancelar: stock 20, lotes 10d 10/10 40d 5/5, registro 0
--   h · crear {PH 8} + denegar: idem
--   i · STK-A/B/E/F y LOTE-A/B/C sin violaciones
DO $ensayo$
DECLARE
  v_uid    uuid;
  v_o      bigint;
  v_d      bigint;
  v_obs    jsonb := '{}'::jsonb;
  v_esp    jsonb;
  v_fallas text := '';
  k        text;
BEGIN
  SELECT a.usuario_id, a.sucursal_id, b.sucursal_id INTO v_uid, v_o, v_d
    FROM usuario_sucursales a
    JOIN usuario_sucursales b ON b.usuario_id = a.usuario_id AND b.sucursal_id <> a.sucursal_id
    JOIN sucursales sa ON sa.id = a.sucursal_id AND sa.activa
    JOIN sucursales sb ON sb.id = b.sucursal_id AND sb.activa
   WHERE public._rol_en_sucursal(a.usuario_id, a.sucursal_id) = 'admin'
     AND public._rol_en_sucursal(a.usuario_id, b.sucursal_id) = 'admin'
   ORDER BY a.sucursal_id, b.sucursal_id, a.usuario_id
   LIMIT 1;

  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'mig286: no hay un admin con dos sucursales activas; el ensayo no puede correr.';
  END IF;

  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_o::text)::text, true);

    DECLARE
      v_hoy date := current_date;
      v_pa bigint; v_pb bigint; v_pg bigint; v_ph bigint; v_pd bigint; v_pgd bigint;
      v_m1 bigint; v_m2 bigint; v_m3 bigint; v_m4 bigint;
      v_r jsonb; v_res jsonb; v_it_a bigint; v_it_b bigint; v_it bigint;
      v_pb_dest bigint; v_aud jsonb; v_lotes_18 text;
    BEGIN
      -- Origen
      INSERT INTO productos (nombre, codigo, precio, stock, sucursal_id, costo_sin_iva, costo_con_iva, costo_real, costo_promedio)
        VALUES ('ZZ mig286 A', 'ZZMIGXXX-A', 1000, 30, v_o, 100, 121, 100, 100) RETURNING id INTO v_pa;
      INSERT INTO productos (nombre, codigo, precio, stock, sucursal_id, costo_sin_iva, costo_con_iva, costo_real, costo_promedio)
        VALUES ('ZZ mig286 B', 'ZZMIGXXX-B', 1000, 8, v_o, 40, 48.4, 45, 50) RETURNING id INTO v_pb;
      INSERT INTO productos (nombre, codigo, precio, stock, sucursal_id, costo_sin_iva, costo_con_iva, costo_real, costo_promedio)
        VALUES ('ZZ mig286 G', 'ZZMIGXXX-G', 1000, 10, v_o, 60, 72.6, 70, 70) RETURNING id INTO v_pg;
      INSERT INTO productos (nombre, codigo, precio, stock, sucursal_id, costo_sin_iva, costo_con_iva, costo_real, costo_promedio)
        VALUES ('ZZ mig286 H', 'ZZMIGXXX-H', 1000, 20, v_o, 30, 36.3, 30, 30) RETURNING id INTO v_ph;
      INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, compra_id, origen, usuario_id)
        VALUES (v_pa, v_o, v_hoy + 30, 10, 10, NULL, 'manual', v_uid),
               (v_pa, v_o, v_hoy + 60, 10, 10, NULL, 'manual', v_uid),
               (v_pg, v_o, v_hoy + 20, 5, 5, NULL, 'manual', v_uid),
               (v_ph, v_o, v_hoy + 10, 10, 10, NULL, 'manual', v_uid),
               (v_ph, v_o, v_hoy + 40, 5, 5, NULL, 'manual', v_uid);
      -- Destino
      INSERT INTO productos (nombre, codigo, precio, stock, sucursal_id, costo_sin_iva, costo_con_iva, costo_real, costo_promedio)
        VALUES ('ZZ mig286 D', 'ZZMIGXXX-D', 1000, 20, v_d, 80, 100, 150, 200) RETURNING id INTO v_pd;
      INSERT INTO productos (nombre, codigo, precio, stock, sucursal_id)
        VALUES ('ZZ mig286 Gd', 'ZZMIGXXX-Gd', 1000, 0, v_d) RETURNING id INTO v_pgd;
      INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, compra_id, origen, usuario_id)
        VALUES (v_pd, v_d, v_hoy + 30, 2, 2, NULL, 'movimiento', v_uid);

      -- a · crear
      v_r := crear_movimiento_sucursal(v_d, 'ensayo mig286',
               jsonb_build_array(jsonb_build_object('producto_id', v_pa, 'cantidad', 25),
                                 jsonb_build_object('producto_id', v_pb, 'cantidad', 8)));
      IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 'a crear: %', v_r; END IF;
      v_m1 := (v_r->>'movimiento_id')::bigint;
      v_obs := v_obs || jsonb_build_object(
        'a_reg_A', (SELECT string_agg(d || ':' || c, ',' ORDER BY d) FROM (
                      SELECT l.fecha_vencimiento - v_hoy AS d, SUM(l.cantidad) AS c
                        FROM movimiento_sucursal_item_lotes l JOIN movimiento_sucursal_items i ON i.id = l.item_id
                       WHERE i.movimiento_id = v_m1 AND i.producto_origen_id = v_pa GROUP BY 1) x),
        'a_lotes_A', (SELECT string_agg(d || ':' || r || '/' || c, ',' ORDER BY d) FROM (
                      SELECT fecha_vencimiento - v_hoy AS d, SUM(cantidad_restante) AS r, SUM(cantidad) AS c
                        FROM producto_lotes WHERE producto_id = v_pa AND sucursal_id = v_o GROUP BY 1) x),
        'a_stock_A', (SELECT stock FROM productos WHERE id = v_pa),
        'a_snap_A', (SELECT origen_costo_promedio FROM movimiento_sucursal_items WHERE movimiento_id = v_m1 AND producto_origen_id = v_pa));

      -- b · editar a la baja
      v_r := editar_movimiento_sucursal(v_m1, 'ensayo b',
               jsonb_build_array(jsonb_build_object('producto_id', v_pa, 'cantidad', 20),
                                 jsonb_build_object('producto_id', v_pb, 'cantidad', 8)));
      IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 'b editar: %', v_r; END IF;
      v_obs := v_obs || jsonb_build_object(
        'b_reg_A', (SELECT string_agg(d || ':' || c, ',' ORDER BY d) FROM (
                      SELECT l.fecha_vencimiento - v_hoy AS d, SUM(l.cantidad) AS c
                        FROM movimiento_sucursal_item_lotes l JOIN movimiento_sucursal_items i ON i.id = l.item_id
                       WHERE i.movimiento_id = v_m1 AND i.producto_origen_id = v_pa GROUP BY 1) x),
        'b_lotes_A', (SELECT string_agg(d || ':' || r || '/' || c, ',' ORDER BY d) FROM (
                      SELECT fecha_vencimiento - v_hoy AS d, SUM(cantidad_restante) AS r, SUM(cantidad) AS c
                        FROM producto_lotes WHERE producto_id = v_pa AND sucursal_id = v_o GROUP BY 1) x),
        'b_stock_A', (SELECT stock FROM productos WHERE id = v_pa));

      -- c · editar al alza
      v_r := editar_movimiento_sucursal(v_m1, 'ensayo c',
               jsonb_build_array(jsonb_build_object('producto_id', v_pa, 'cantidad', 22),
                                 jsonb_build_object('producto_id', v_pb, 'cantidad', 8)));
      IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 'c editar: %', v_r; END IF;
      v_obs := v_obs || jsonb_build_object(
        'c_reg_A', (SELECT string_agg(d || ':' || c, ',' ORDER BY d) FROM (
                      SELECT l.fecha_vencimiento - v_hoy AS d, SUM(l.cantidad) AS c
                        FROM movimiento_sucursal_item_lotes l JOIN movimiento_sucursal_items i ON i.id = l.item_id
                       WHERE i.movimiento_id = v_m1 AND i.producto_origen_id = v_pa GROUP BY 1) x),
        'c_lotes_A', (SELECT string_agg(d || ':' || r || '/' || c, ',' ORDER BY d) FROM (
                      SELECT fecha_vencimiento - v_hoy AS d, SUM(cantidad_restante) AS r, SUM(cantidad) AS c
                        FROM producto_lotes WHERE producto_id = v_pa AND sucursal_id = v_o GROUP BY 1) x),
        'c_stock_A', (SELECT stock FROM productos WHERE id = v_pa),
        'c_items', (SELECT count(*) FROM movimiento_sucursal_items WHERE movimiento_id = v_m1),
        'c_huerfanas', (SELECT count(*) FROM movimiento_sucursal_item_lotes l
                         WHERE NOT EXISTS (SELECT 1 FROM movimiento_sucursal_items i WHERE i.id = l.item_id)));

      -- d · aceptar (el snapshot manda sobre el vivo)
      UPDATE productos SET costo_promedio = 999 WHERE id IN (v_pa, v_pb);
      SELECT id INTO v_it_a FROM movimiento_sucursal_items WHERE movimiento_id = v_m1 AND producto_origen_id = v_pa;
      SELECT id INTO v_it_b FROM movimiento_sucursal_items WHERE movimiento_id = v_m1 AND producto_origen_id = v_pb;
      PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_d::text)::text, true);
      v_r := aceptar_movimiento_sucursal(v_m1, jsonb_build_array(
               jsonb_build_object('item_id', v_it_a, 'accion', 'match_existente', 'producto_destino_id', v_pd),
               jsonb_build_object('item_id', v_it_b, 'accion', 'crear_nuevo')));
      IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 'd aceptar: %', v_r; END IF;
      SELECT producto_destino_id INTO v_pb_dest FROM movimiento_sucursal_items WHERE id = v_it_b;
      v_obs := v_obs || jsonb_build_object(
        'd_lotes_D', (SELECT string_agg(d || ':' || r || '/' || c || ':' || n, ',' ORDER BY d) FROM (
                      SELECT fecha_vencimiento - v_hoy AS d, SUM(cantidad_restante) AS r, SUM(cantidad) AS c, count(*) AS n
                        FROM producto_lotes WHERE producto_id = v_pd AND sucursal_id = v_d AND origen = 'movimiento' GROUP BY 1) x),
        'd_D', (SELECT jsonb_build_object('stock', stock, 'prom', costo_promedio, 'real', costo_real,
                                          'civa', costo_con_iva, 'siva', costo_sin_iva)
                  FROM productos WHERE id = v_pd),
        'd_Bnuevo', (SELECT jsonb_build_object('stock', p.stock, 'prom', p.costo_promedio,
                                               'lotes', (SELECT count(*) FROM producto_lotes l WHERE l.producto_id = p.id))
                       FROM productos p WHERE p.id = v_pb_dest),
        'd_reg_queda', (SELECT COALESCE(SUM(cantidad), 0) FROM movimiento_sucursal_item_lotes WHERE item_id = v_it_a));

      -- e · envio sin registro
      PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_o::text)::text, true);
      v_r := crear_movimiento_sucursal(v_d, 'ensayo e', jsonb_build_array(jsonb_build_object('producto_id', v_pg, 'cantidad', 8)));
      IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 'e crear: %', v_r; END IF;
      v_m2 := (v_r->>'movimiento_id')::bigint;
      SELECT id INTO v_it FROM movimiento_sucursal_items WHERE movimiento_id = v_m2;
      v_obs := v_obs || jsonb_build_object('e_reg_G', (SELECT string_agg((fecha_vencimiento - v_hoy) || ':' || cantidad, ',')
                                                         FROM movimiento_sucursal_item_lotes WHERE item_id = v_it));
      DELETE FROM movimiento_sucursal_item_lotes WHERE item_id = v_it;
      PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_d::text)::text, true);
      v_r := aceptar_movimiento_sucursal(v_m2, jsonb_build_array(
               jsonb_build_object('item_id', v_it, 'accion', 'match_existente', 'producto_destino_id', v_pgd)));
      IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 'e aceptar: %', v_r; END IF;
      v_obs := v_obs || jsonb_build_object(
        'e_Gd', (SELECT jsonb_build_object('stock', stock, 'prom', costo_promedio, 'real', costo_real,
                                           'lotes', (SELECT count(*) FROM producto_lotes l WHERE l.producto_id = v_pgd))
                   FROM productos WHERE id = v_pgd));

      -- f · el #18 real (si sigue pendiente)
      IF EXISTS (SELECT 1 FROM movimientos_sucursal WHERE id = 18 AND estado = 'pendiente') THEN
        PERFORM set_config('request.headers',
          json_build_object('x-sucursal-id', (SELECT sucursal_destino_id FROM movimientos_sucursal WHERE id = 18)::text)::text, true);
        SELECT jsonb_agg(CASE WHEN dp.id IS NULL
                              THEN jsonb_build_object('item_id', i.id, 'accion', 'crear_nuevo')
                              ELSE jsonb_build_object('item_id', i.id, 'accion', 'match_existente', 'producto_destino_id', dp.id) END)
          INTO v_res
          FROM movimiento_sucursal_items i
          JOIN movimientos_sucursal m ON m.id = i.movimiento_id
          LEFT JOIN LATERAL (SELECT p.id FROM productos p
                              WHERE p.sucursal_id = m.sucursal_destino_id AND p.codigo = i.origen_codigo
                              ORDER BY p.id LIMIT 1) dp ON true
         WHERE i.movimiento_id = 18;
        SELECT string_agg(p.id || ':' || COALESCE((SELECT SUM(cantidad_restante) FROM producto_lotes l WHERE l.producto_id = p.id), 0), ',' ORDER BY p.id)
          INTO v_lotes_18
          FROM productos p WHERE p.id IN (SELECT (x->>'producto_destino_id')::bigint FROM jsonb_array_elements(v_res) x);
        v_r := aceptar_movimiento_sucursal(18, v_res);
        v_obs := v_obs || jsonb_build_object(
          'f_18', COALESCE((v_r->>'success')::boolean, false),
          'f_18_err', v_r->>'error',
          'f_18_lotes_iguales', v_lotes_18 IS NOT DISTINCT FROM (
             SELECT string_agg(p.id || ':' || COALESCE((SELECT SUM(cantidad_restante) FROM producto_lotes l WHERE l.producto_id = p.id), 0), ',' ORDER BY p.id)
               FROM productos p WHERE p.id IN (SELECT (x->>'producto_destino_id')::bigint FROM jsonb_array_elements(v_res) x)),
          'f_18_lotes_nuevos', (SELECT count(*) FROM producto_lotes l JOIN movimiento_sucursal_items i ON i.producto_destino_id = l.producto_id
                                 WHERE i.movimiento_id = 18 AND l.origen = 'movimiento'));
      ELSE
        v_obs := v_obs || jsonb_build_object('f_18', true, 'f_18_err', NULL, 'f_18_lotes_iguales', true,
                                             'f_18_lotes_nuevos', 0, 'f_18_nota', 'el #18 ya no esta pendiente');
      END IF;

      -- g · cancelar
      PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_o::text)::text, true);
      v_r := crear_movimiento_sucursal(v_d, 'ensayo g', jsonb_build_array(jsonb_build_object('producto_id', v_ph, 'cantidad', 12)));
      IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 'g crear: %', v_r; END IF;
      v_m3 := (v_r->>'movimiento_id')::bigint;
      v_obs := v_obs || jsonb_build_object(
        'g_reg_H', (SELECT string_agg((l.fecha_vencimiento - v_hoy) || ':' || l.cantidad, ',')
                      FROM movimiento_sucursal_item_lotes l JOIN movimiento_sucursal_items i ON i.id = l.item_id
                     WHERE i.movimiento_id = v_m3));
      v_r := cancelar_movimiento_sucursal(v_m3, 'ensayo');
      IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 'g cancelar: %', v_r; END IF;
      v_obs := v_obs || jsonb_build_object(
        'g_stock_H', (SELECT stock FROM productos WHERE id = v_ph),
        'g_lotes_H', (SELECT string_agg(d || ':' || r || '/' || c, ',' ORDER BY d) FROM (
                      SELECT fecha_vencimiento - v_hoy AS d, SUM(cantidad_restante) AS r, SUM(cantidad) AS c
                        FROM producto_lotes WHERE producto_id = v_ph AND sucursal_id = v_o GROUP BY 1) x),
        'g_reg', (SELECT count(*) FROM movimiento_sucursal_item_lotes l JOIN movimiento_sucursal_items i ON i.id = l.item_id
                   WHERE i.movimiento_id = v_m3));

      -- h · denegar
      v_r := crear_movimiento_sucursal(v_d, 'ensayo h', jsonb_build_array(jsonb_build_object('producto_id', v_ph, 'cantidad', 8)));
      IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 'h crear: %', v_r; END IF;
      v_m4 := (v_r->>'movimiento_id')::bigint;
      v_obs := v_obs || jsonb_build_object(
        'h_reg_H', (SELECT string_agg((l.fecha_vencimiento - v_hoy) || ':' || l.cantidad, ',')
                      FROM movimiento_sucursal_item_lotes l JOIN movimiento_sucursal_items i ON i.id = l.item_id
                     WHERE i.movimiento_id = v_m4));
      PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_d::text)::text, true);
      v_r := denegar_movimiento_sucursal(v_m4, 'ensayo');
      IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 'h denegar: %', v_r; END IF;
      v_obs := v_obs || jsonb_build_object(
        'h_stock_H', (SELECT stock FROM productos WHERE id = v_ph),
        'h_lotes_H', (SELECT string_agg(d || ':' || r || '/' || c, ',' ORDER BY d) FROM (
                      SELECT fecha_vencimiento - v_hoy AS d, SUM(cantidad_restante) AS r, SUM(cantidad) AS c
                        FROM producto_lotes WHERE producto_id = v_ph AND sucursal_id = v_o GROUP BY 1) x),
        'h_reg', (SELECT count(*) FROM movimiento_sucursal_item_lotes l JOIN movimiento_sucursal_items i ON i.id = l.item_id
                   WHERE i.movimiento_id = v_m4));

      -- i · integridad
      v_aud := public.auditoria_integridad();
      v_obs := v_obs || jsonb_build_object(
        'i_checks', (SELECT string_agg((c->>'id') || '=' || (c->>'violaciones'), ' ' ORDER BY c->>'id')
                       FROM jsonb_array_elements(v_aud->'checks') c
                      WHERE c->>'id' IN ('STK-A','STK-B','STK-E','STK-F','LOTE-A','LOTE-B','LOTE-C')),
        'i_stkf', public.auditoria_funciones_stock_sin_origen());
    END;

    RAISE EXCEPTION 'mig286_rollback_del_ensayo';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'mig286_rollback_del_ensayo' THEN
      RAISE EXCEPTION 'mig286 · el ensayo funcional exploto: %', SQLERRM;
    END IF;
  END;

  v_esp := jsonb_build_object(
    'a_reg_A', '30:10,60:5', 'a_lotes_A', '30:0/10,60:5/10', 'a_stock_A', 5, 'a_snap_A', 100,
    'b_reg_A', '30:5,60:5',  'b_lotes_A', '30:5/10,60:5/10', 'b_stock_A', 10,
    'c_reg_A', '30:7,60:5',  'c_lotes_A', '30:3/10,60:5/10', 'c_stock_A', 8, 'c_items', 2, 'c_huerfanas', 0,
    'd_lotes_D', '30:9/9:1,60:5/5:1',
    'd_D', jsonb_build_object('stock', 42, 'prom', 147.6190, 'real', 150, 'civa', 121, 'siva', 100),
    'd_Bnuevo', jsonb_build_object('stock', 8, 'prom', 50, 'lotes', 0),
    'd_reg_queda', 12,
    'e_reg_G', '20:3',
    'e_Gd', jsonb_build_object('stock', 8, 'prom', 70, 'real', 70, 'lotes', 0),
    'f_18', true, 'f_18_lotes_iguales', true, 'f_18_lotes_nuevos', 0,
    'g_reg_H', '10:7', 'g_stock_H', 20, 'g_lotes_H', '10:10/10,40:5/5', 'g_reg', 0,
    'h_reg_H', '10:3', 'h_stock_H', 20, 'h_lotes_H', '10:10/10,40:5/5', 'h_reg', 0,
    'i_checks', 'LOTE-A=0 LOTE-B=0 LOTE-C=0 STK-A=0 STK-B=0 STK-E=0 STK-F=0', 'i_stkf', 0);

  FOR k IN SELECT jsonb_object_keys(v_esp) LOOP
    IF (v_obs->k) IS DISTINCT FROM (v_esp->k) THEN
      v_fallas := v_fallas || format(' [%s: esperado %s, obtenido %s]', k, v_esp->k, COALESCE(v_obs->k, 'null'::jsonb));
    END IF;
  END LOOP;

  IF v_fallas <> '' THEN
    RAISE EXCEPTION 'mig286 · el ensayo funcional encontro:% · observado=%', v_fallas, v_obs;
  END IF;

  PERFORM set_config('mig286.ensayo', v_obs::text, true);
  RAISE NOTICE 'mig286 · ensayo funcional OK: %', v_obs;
END
$ensayo$;

COMMIT;
