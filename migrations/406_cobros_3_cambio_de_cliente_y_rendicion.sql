-- Cobros 3 · #1248 · Cambiar el cliente sin dejar sobrepago atrapado, y la
-- rendicion confirmada congelada.
--
-- `cambiar_cliente_pedido` decide a donde van los pagos (`p_destino_pagos`) y
-- desafecta el excedente. Al confirmar una rendicion se guarda su foto y un dia
-- cerrado se lee de ahi (decision del duenio, 2026-10-28).
--
-- Tarjeta 2 de #1268 (cobros y cuenta corriente), en cuatro migraciones que se
-- aplican en orden: 1 formas de pago (#1249), 2 cobro por RPC (#1246, #1247),
-- 3 cambio de cliente y rendicion congelada (#1248), 4 sin INSERT REST (#1246).
-- La 4 va despues de que el front nuevo este en prod: hasta entonces el bundle
-- viejo cobra por REST, y sin el INSERT no podria cobrar.
--
-- Prod antes de esto: 0 pagos con monto <= 0, 0 con cliente distinto del de su
-- pedido, 0 pedidos sobrepagados, 0 pagos con fecha futura. Formas en `pagos`:
-- las seis de la lista mas 5 'combinado' y 1 'cuenta_corriente' heredados, todos
-- de abril de 2026.
--
-- Ensayo: scripts/test-rendicion-congelada-1248.sql.

-- =============================================================================
-- 8 · #1248 · Cambiar el cliente: a donde van los pagos
-- =============================================================================

-- Lo que una boleta cobro de mas pasa a saldo a favor de su cliente, sin
-- perderse: desde el pago mas nuevo, partiendo el ultimo si hace falta. Es
-- reimputacion (la misma plata, otra boleta), asi que lleva el GUC de la 165.
-- Distinto de desafectar_sobrepago_pedido, que BAJA el pago: ahi el cliente no
-- pago lo que rechazo; aca si pago, y la plata le queda a favor.
CREATE OR REPLACE FUNCTION public._pagos_excedente_a_favor(p_pedido_id bigint)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_pedido    RECORD;
  v_pago      RECORD;
  v_excedente numeric;
  v_mover     numeric;
  v_movido    numeric := 0;
  v_guc       text;
  v_marca     text;
BEGIN
  SELECT id, total, COALESCE(monto_pagado, 0) AS pagado
    INTO v_pedido
    FROM pedidos
   WHERE id = p_pedido_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  v_excedente := v_pedido.pagado - v_pedido.total;
  IF v_excedente <= 0.005 THEN
    RETURN 0;
  END IF;

  v_marca := ' [excedente del pedido #' || p_pedido_id || '] [saldo a favor]';
  v_guc := current_setting('app.reimputacion_pagos', true);
  PERFORM set_config('app.reimputacion_pagos', 'on', true);

  FOR v_pago IN
    SELECT id, monto
      FROM pagos
     WHERE pedido_id = p_pedido_id
     ORDER BY fecha DESC, id DESC
     FOR UPDATE
  LOOP
    EXIT WHEN v_excedente <= 0.005;

    v_mover := LEAST(v_pago.monto, v_excedente);

    IF v_mover >= v_pago.monto - 0.005 THEN
      UPDATE pagos
         SET pedido_id = NULL,
             notas = trim(COALESCE(notas, '') || v_marca)
       WHERE id = v_pago.id;
      v_mover := v_pago.monto;
    ELSE
      UPDATE pagos SET monto = monto - v_mover WHERE id = v_pago.id;

      INSERT INTO pagos (
        cliente_id, pedido_id, monto, forma_pago, fecha,
        referencia, notas, usuario_id, sucursal_id, nota_credito_id, pago_origen_id
      )
      SELECT cliente_id, NULL, v_mover, forma_pago, fecha, referencia,
             trim(COALESCE(notas, '') || v_marca),
             usuario_id, sucursal_id, nota_credito_id, COALESCE(pago_origen_id, id)
        FROM pagos
       WHERE id = v_pago.id;
    END IF;

    v_excedente := v_excedente - v_mover;
    v_movido    := v_movido + v_mover;
  END LOOP;

  PERFORM set_config('app.reimputacion_pagos', COALESCE(v_guc, ''), true);
  RETURN v_movido;
END;
$function$;

REVOKE ALL ON FUNCTION public._pagos_excedente_a_favor(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._pagos_excedente_a_favor(bigint) TO service_role;

-- p_destino_pagos (decision del duenio, 2026-10-28; el front lo pregunta):
--   'pedido_nuevo'      fue un error de carga: los pagos pasan al pedido nuevo,
--                       y lo que exceda su total queda a favor del cliente nuevo.
--                       Es lo que hacia hasta ahora, salvo el excedente, que
--                       quedaba atrapado en la boleta (COB-3).
--   'cliente_original'  el cliente no tomo el pedido y se le paso a otro: lo que
--                       el original pago queda a su favor (la desimputacion de
--                       la 235) y el pedido nuevo nace impago.
-- Firma nueva: se dropea la vieja para que PostgREST no tenga dos sobrecargas
-- superpuestas (trampa 5). El default deja andar a un bundle viejo del PWA.
DROP FUNCTION IF EXISTS public.cambiar_cliente_pedido(bigint, bigint, uuid, jsonb, numeric, numeric, numeric, text);

CREATE OR REPLACE FUNCTION public.cambiar_cliente_pedido(p_pedido_id bigint, p_nuevo_cliente_id bigint, p_usuario_id uuid, p_items jsonb, p_total numeric, p_total_neto numeric DEFAULT NULL::numeric, p_total_iva numeric DEFAULT 0, p_motivo text DEFAULT 'Cambio de cliente'::text, p_destino_pagos text DEFAULT 'pedido_nuevo'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal     BIGINT := current_sucursal_id();
  v_acting       UUID := auth.uid();
  v_role         TEXT;
  v_pedido       RECORD;
  v_prev_role    TEXT;
  v_preventista  UUID := NULL;
  v_preventista_fallback BOOLEAN := false;
  v_cancel       JSONB;
  v_crear        JSONB;
  v_nuevo_id     BIGINT;
  -- envio_historial_y_rol (#1231): el cargo con que nacio el pedido nuevo.
  v_cargo_nuevo  NUMERIC;
  v_estado_nuevo TEXT;
  -- #1248: lo que el pedido nuevo cobro de mas y quedo a favor del cliente nuevo.
  v_excedente    NUMERIC := 0;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No hay sucursal activa');
  END IF;

  IF p_usuario_id IS DISTINCT FROM v_acting THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesion autenticada');
  END IF;

  SELECT rol INTO v_role FROM perfiles WHERE id = v_acting;
  IF v_role IS NULL OR v_role <> 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin puede cambiar el cliente de un pedido');
  END IF;

  IF p_destino_pagos IS NULL OR p_destino_pagos NOT IN ('pedido_nuevo', 'cliente_original') THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Destino de los pagos invalido: ' || COALESCE(p_destino_pagos, 'NULL')
      || '. Tiene que ser pedido_nuevo o cliente_original.');
  END IF;

  -- La reatribucion no es una venta nueva: el pedido ya cumplio (o no) el
  -- minimo cuando se creo. Ver mig 205.
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  -- mig 389 (#1220): la reatribucion conserva el cargo que el pedido ya tenia.
  PERFORM set_config('app.cargo_envio_forzado',
    COALESCE((SELECT cargo_envio::text FROM pedidos WHERE id = p_pedido_id), '0'), true);
  -- cargo_1_base: y su estado (un no_aplica o un bonificado no renacen gratis).
  PERFORM set_config('app.cargo_envio_estado_forzado',
    COALESCE((SELECT cargo_envio_estado FROM pedidos WHERE id = p_pedido_id), ''), true);

  -- Con 'pedido_nuevo' los pagos NO se desimputan al cancelar el viejo: mas
  -- abajo se reapuntan al pedido nuevo, para que el cobro viaje con la venta.
  -- Sin esto, la desimputacion de la mig 235 se los lleva antes y el UPDATE de
  -- mas abajo no encuentra nada. Con 'cliente_original' esa desimputacion es
  -- justo lo que se quiere: el cobro queda a favor del cliente que pago.
  IF p_destino_pagos = 'pedido_nuevo' THEN
    PERFORM set_config('app.cancelacion_conserva_pagos', '1', true);
  END IF;


  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'El pedido nuevo no tiene items');
  END IF;

  SELECT * INTO v_pedido FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pedido no encontrado');
  END IF;

  IF COALESCE(v_pedido.tipo_factura, 'ZZ') = 'VB' THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Un vale blanco no cambia de cliente: cancelalo y cargalo de nuevo al cliente correcto');
  END IF;

  IF v_pedido.estado IN ('entregado', 'cancelado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se puede cambiar el cliente de un pedido ' || v_pedido.estado);
  END IF;

  IF p_nuevo_cliente_id = v_pedido.cliente_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'El cliente nuevo es el mismo que el actual');
  END IF;

  -- mig 276 (#833): con 'pedido_nuevo' los pagos se reapuntan al cliente nuevo.
  -- Un credito de NC es del cliente de la NC: no viaja. Con 'cliente_original'
  -- no viaja nada, y el credito vuelve a saldo a favor de su cliente.
  IF p_destino_pagos = 'pedido_nuevo'
     AND EXISTS (SELECT 1 FROM pagos WHERE pedido_id = p_pedido_id AND nota_credito_id IS NOT NULL) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'El pedido esta pagado en parte con credito de la nota de credito #'
      || (SELECT min(nota_credito_id) FROM pagos WHERE pedido_id = p_pedido_id AND nota_credito_id IS NOT NULL)
      || ', que es de este cliente: no se puede pasar a otro. Elegi que los pagos queden a favor del cliente original, o cancelalo y carga el pedido nuevo.');
  END IF;

  PERFORM 1 FROM clientes WHERE id = p_nuevo_cliente_id AND sucursal_id = v_sucursal;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'El cliente nuevo no existe en esta sucursal');
  END IF;

  IF v_pedido.usuario_id IS DISTINCT FROM p_usuario_id THEN
    SELECT p.rol INTO v_prev_role
    FROM perfiles p
    WHERE p.id = v_pedido.usuario_id
      AND p.activo = true
      AND EXISTS (SELECT 1 FROM usuario_sucursales us WHERE us.usuario_id = p.id AND us.sucursal_id = v_sucursal);
    IF v_prev_role IN ('admin', 'preventista') THEN
      v_preventista := v_pedido.usuario_id;
    ELSE
      v_preventista_fallback := true;
    END IF;
  END IF;

  v_cancel := cancelar_pedido_con_stock(p_pedido_id, p_motivo, p_usuario_id, 'cambio_de_cliente');
  IF NOT COALESCE((v_cancel->>'success')::boolean, false) THEN
    RETURN v_cancel;
  END IF;

  PERFORM quitar_pedido_de_recorridos_activos(p_pedido_id);

  v_crear := crear_pedido_completo(
    p_nuevo_cliente_id,
    p_total,
    p_usuario_id,
    p_items,
    v_pedido.notas,
    v_pedido.forma_pago,
    'pendiente',
    v_pedido.fecha,
    v_pedido.tipo_factura,
    p_total_neto,
    COALESCE(p_total_iva, 0),
    v_pedido.fecha_entrega_programada,
    v_preventista
  );
  IF NOT COALESCE((v_crear->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'No se pudo crear el pedido nuevo: %',
      COALESCE(v_crear->>'errores', v_crear->>'error', 'error desconocido');
  END IF;
  v_nuevo_id := (v_crear->>'pedido_id')::bigint;

  IF p_destino_pagos = 'pedido_nuevo' THEN
    UPDATE pagos
       SET pedido_id = v_nuevo_id,
           cliente_id = p_nuevo_cliente_id
     WHERE pedido_id = p_pedido_id
       AND sucursal_id = v_sucursal;

    -- #1248 (COB-3): si el total nuevo es menor, lo cobrado de mas pasa a saldo
    -- a favor del cliente nuevo y se aplica a sus otras boletas. Sin esto
    -- quedaba atrapado en la boleta: zzz_pedidos_reconciliar_pagos es OF total
    -- y aca solo cambia monto_pagado (trampa 6).
    v_excedente := public._pagos_excedente_a_favor(v_nuevo_id);
    IF v_excedente > 0 THEN
      PERFORM public.aplicar_credito_cliente(p_nuevo_cliente_id, v_sucursal);
    END IF;
  END IF;

  UPDATE pedidos
     SET motivo_cancelacion = COALESCE(motivo_cancelacion, p_motivo) || ' -> pedido #' || v_nuevo_id
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
  VALUES (
    v_nuevo_id,
    v_acting,
    'cliente_id',
    v_pedido.cliente_id::text,
    p_nuevo_cliente_id::text || ' (cambio de cliente desde pedido #' || p_pedido_id || ')',
    v_sucursal
  );

  -- envio_historial_y_rol (#1231): la reatribucion conserva cargo y estado;
  -- si el pedido nuevo nacio con otros (p. ej. sin productos: cargo 0,
  -- 'gratis'), queda anotado en el nuevo, contra lo que tenia el viejo.
  SELECT cargo_envio, cargo_envio_estado INTO v_cargo_nuevo, v_estado_nuevo
    FROM pedidos WHERE id = v_nuevo_id AND sucursal_id = v_sucursal;
  IF COALESCE(v_pedido.cargo_envio, 0) IS DISTINCT FROM COALESCE(v_cargo_nuevo, 0) THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (v_nuevo_id, v_acting, 'cargo_envio', round(COALESCE(v_pedido.cargo_envio, 0), 2)::TEXT,
            round(COALESCE(v_cargo_nuevo, 0), 2)::TEXT, v_sucursal);
  END IF;
  IF v_pedido.cargo_envio_estado IS DISTINCT FROM v_estado_nuevo THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (v_nuevo_id, v_acting, 'cargo_envio_estado', v_pedido.cargo_envio_estado, v_estado_nuevo, v_sucursal);
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'nuevo_pedido_id', v_nuevo_id,
    'pedido_cancelado_id', p_pedido_id,
    'preventista_fallback', v_preventista_fallback,
    'destino_pagos', p_destino_pagos,
    'excedente_a_favor', v_excedente
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.cambiar_cliente_pedido(bigint, bigint, uuid, jsonb, numeric, numeric, numeric, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cambiar_cliente_pedido(bigint, bigint, uuid, jsonb, numeric, numeric, numeric, text, text)
  TO authenticated, service_role;

-- =============================================================================
-- 9 · #1248 · La rendicion confirmada se congela
-- =============================================================================

-- La foto: cada pago que la rendicion rindio, como estaba al confirmarla.
-- Solo de server: la leen las RPCs de rendicion, que son DEFINER.
CREATE TABLE IF NOT EXISTS public.rendicion_pagos_confirmados (
  rendicion_id       bigint      NOT NULL REFERENCES public.rendiciones_control(id) ON DELETE CASCADE,
  pago_id            bigint      NOT NULL,
  cliente_id         bigint      NOT NULL,
  usuario_id         uuid,
  monto              numeric     NOT NULL,
  forma_pago         text        NOT NULL,
  referencia         text,
  notas              text,
  pedido_id          bigint,
  pedido_fecha       date,
  pedido_estado      text,
  pedido_total       numeric,
  es_entrega_del_dia boolean     NOT NULL,
  pago_created_at    timestamptz,
  PRIMARY KEY (rendicion_id, pago_id)
);
CREATE INDEX IF NOT EXISTS rendicion_pagos_confirmados_pago_id_idx
  ON public.rendicion_pagos_confirmados (pago_id);
ALTER TABLE public.rendicion_pagos_confirmados ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.rendicion_pagos_confirmados FROM PUBLIC, anon, authenticated;
COMMENT ON TABLE public.rendicion_pagos_confirmados IS
  'Foto de los pagos de una rendicion confirmada o resuelta (#1248). La toma '
  'rendicion_control_foto al cerrarla y la borra al reabrirla. Solo de server.';

-- Y la otra mitad de la linea: lo entregado ese dia, que tambien se mueve
-- despues (una salvedad, una cancelacion).
ALTER TABLE public.rendiciones_control
  ADD COLUMN IF NOT EXISTS total_entregado_confirmado numeric,
  ADD COLUMN IF NOT EXISTS cantidad_pedidos_confirmada bigint;

-- Lo entregado por chofer y dia: el entregas_agg de obtener_resumen_rendiciones,
-- en un solo lugar para que la foto y el resumen no se separen.
CREATE OR REPLACE FUNCTION public._rendicion_entregas(p_sucursal_id bigint, p_desde date, p_hasta date)
 RETURNS TABLE (t_id uuid, f date, tot_entregado numeric, cant bigint)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT pd.transportista_id,
         pd.fecha_entrega::date,
         SUM(pd.total)::numeric,
         COUNT(*)::bigint
    FROM pedidos pd
   WHERE pd.estado = 'entregado'
     AND pd.fecha_entrega IS NOT NULL
     AND pd.transportista_id IS NOT NULL
     AND pd.fecha_entrega::date BETWEEN p_desde AND p_hasta
     AND pd.sucursal_id = p_sucursal_id
     -- 3XA (N12): el vale blanco no es mercadería que el transportista tenga que
     -- rendir. Los 75 VB históricos con transportista salen de lo entregado igual
     -- que su pago sale de lo cobrado, así los dos lados bajan juntos.
     AND COALESCE(pd.tipo_factura, 'ZZ') <> 'VB'
   GROUP BY pd.transportista_id, pd.fecha_entrega::date;
$function$;

-- Los pagos de las rendiciones de un rango, con la regla de la foto:
--   · la rendicion cerrada (confirmada o resuelta) lee su foto;
--   · todo pago que ninguna foto rindio se lee vivo, atribuido como siempre
--     (COALESCE(pd.transportista_id, pg.usuario_id)). La pertenencia va por la
--     raiz (pago_origen_id): un pedazo de un pago rendido sigue rendido.
-- Asi la plata de una rendicion cerrada no cambia ni se va a otra. Lo unico que
-- se le puede sumar es un pago que ninguna rendicion cerrada rindio (p. ej. un
-- cobro del preventista cuya boleta se le asigna despues a ese chofer). No se
-- pierde ni se cuenta dos veces: o esta en una foto, o esta vivo.
-- Sin nota_credito: no es plata de la rendicion (276). El adelanto de sueldo si
-- viene: el resumen lo muestra aparte (273) y el detalle lo filtra.
CREATE OR REPLACE FUNCTION public._rendicion_pagos(p_sucursal_id bigint, p_desde date, p_hasta date)
 RETURNS TABLE (
   t_id uuid, f date, pago_id bigint, cliente_id bigint, usuario_id uuid,
   monto numeric, forma_pago text, referencia text, notas text,
   pedido_id bigint, pedido_fecha date, pedido_estado text, pedido_total numeric,
   es_entrega_del_dia boolean, pago_created_at timestamptz, congelado boolean
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT rc.transportista_id, rc.fecha, fo.pago_id, fo.cliente_id, fo.usuario_id,
         fo.monto, fo.forma_pago, fo.referencia, fo.notas,
         fo.pedido_id, fo.pedido_fecha, fo.pedido_estado, fo.pedido_total,
         fo.es_entrega_del_dia, fo.pago_created_at, true
    FROM rendiciones_control rc
    JOIN rendicion_pagos_confirmados fo ON fo.rendicion_id = rc.id
   WHERE rc.sucursal_id = p_sucursal_id
     AND rc.fecha BETWEEN p_desde AND p_hasta
     AND rc.estado IN ('confirmada', 'resuelta')
  UNION ALL
  SELECT COALESCE(pd.transportista_id, pg.usuario_id), pg.fecha, pg.id::bigint,
         pg.cliente_id::bigint, pg.usuario_id,
         pg.monto, pg.forma_pago::text, pg.referencia::text, pg.notas,
         pg.pedido_id::bigint, pd.fecha, pd.estado::text, pd.total,
         COALESCE(pg.pedido_id IS NOT NULL
                  AND pd.estado = 'entregado'
                  AND COALESCE(pd.fecha_entrega::date, pg.fecha) = pg.fecha, false),
         pg.created_at, false
    FROM pagos pg
    LEFT JOIN pedidos pd ON pd.id = pg.pedido_id
   WHERE pg.sucursal_id = p_sucursal_id
     AND pg.fecha BETWEEN p_desde AND p_hasta
     AND COALESCE(pg.forma_pago, '') <> 'nota_credito'
     AND NOT EXISTS (
       SELECT 1
         FROM rendicion_pagos_confirmados fo
         JOIN rendiciones_control rc ON rc.id = fo.rendicion_id
        WHERE fo.pago_id = COALESCE(pg.pago_origen_id, pg.id)
          AND rc.estado IN ('confirmada', 'resuelta'));
$function$;

CREATE OR REPLACE FUNCTION public._rendicion_tomar_foto(p_rendicion_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  r RECORD;
BEGIN
  SELECT id, fecha, transportista_id, sucursal_id
    INTO r
    FROM rendiciones_control
   WHERE id = p_rendicion_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  -- Primero se suelta la foto propia (si la habia): sus pagos vuelven a estar
  -- vivos y entran de nuevo si siguen siendo de esta rendicion.
  DELETE FROM rendicion_pagos_confirmados WHERE rendicion_id = r.id;

  INSERT INTO rendicion_pagos_confirmados (
    rendicion_id, pago_id, cliente_id, usuario_id, monto, forma_pago, referencia, notas,
    pedido_id, pedido_fecha, pedido_estado, pedido_total, es_entrega_del_dia, pago_created_at
  )
  SELECT r.id, v.pago_id, v.cliente_id, v.usuario_id, v.monto, v.forma_pago, v.referencia, v.notas,
         v.pedido_id, v.pedido_fecha, v.pedido_estado, v.pedido_total, v.es_entrega_del_dia,
         v.pago_created_at
    FROM public._rendicion_pagos(r.sucursal_id, r.fecha, r.fecha) v
   WHERE v.t_id = r.transportista_id
     AND NOT v.congelado;

  UPDATE rendiciones_control rc
     SET total_entregado_confirmado  = COALESCE(e.tot_entregado, 0),
         cantidad_pedidos_confirmada = COALESCE(e.cant, 0)
    FROM (SELECT 1) x
    LEFT JOIN public._rendicion_entregas(r.sucursal_id, r.fecha, r.fecha) e
      ON e.t_id = r.transportista_id
   WHERE rc.id = r.id;
END;
$function$;

-- Al cerrar (pendiente o disconformidad -> confirmada o resuelta) se toma la
-- foto; al reabrir (-> disconformidad) se descarta. Reconfirmar una ya cerrada
-- no la rehace: la foto es la del cierre. desmarcar_rendicion_controlada borra
-- la fila y la foto se va por el CASCADE.
CREATE OR REPLACE FUNCTION public.rendicion_control_foto()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cerrada_antes boolean := false;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    v_cerrada_antes := OLD.estado IN ('confirmada', 'resuelta');
  END IF;

  IF NEW.estado IN ('confirmada', 'resuelta') THEN
    IF NOT v_cerrada_antes THEN
      PERFORM public._rendicion_tomar_foto(NEW.id);
    END IF;
  ELSIF v_cerrada_antes THEN
    DELETE FROM rendicion_pagos_confirmados WHERE rendicion_id = NEW.id;
    UPDATE rendiciones_control
       SET total_entregado_confirmado = NULL,
           cantidad_pedidos_confirmada = NULL
     WHERE id = NEW.id;
  END IF;
  RETURN NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public._rendicion_entregas(bigint, date, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._rendicion_pagos(bigint, date, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._rendicion_tomar_foto(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rendicion_control_foto() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._rendicion_entregas(bigint, date, date) TO service_role;
GRANT EXECUTE ON FUNCTION public._rendicion_pagos(bigint, date, date) TO service_role;
GRANT EXECUTE ON FUNCTION public._rendicion_tomar_foto(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.rendicion_control_foto() TO service_role;

DROP TRIGGER IF EXISTS trg_rendiciones_control_foto ON public.rendiciones_control;
CREATE TRIGGER trg_rendiciones_control_foto
  AFTER INSERT OR UPDATE OF estado ON public.rendiciones_control
  FOR EACH ROW EXECUTE FUNCTION public.rendicion_control_foto();

-- Las cerradas que ya hay: foto de hoy, en el orden en que se cerraron (la
-- primera que rindio un pago se lo queda). Entre la confirmacion y hoy no se
-- movio nada: en las 15 reimputaciones auditadas desde junio, ninguna toco un
-- dia cerrado.
DO $$
DECLARE
  v RECORD;
BEGIN
  FOR v IN
    SELECT id FROM public.rendiciones_control
     WHERE estado IN ('confirmada', 'resuelta')
     ORDER BY COALESCE(resuelta_at, controlada_at), id
  LOOP
    PERFORM public._rendicion_tomar_foto(v.id);
  END LOOP;
END
$$;

CREATE OR REPLACE FUNCTION public.obtener_detalle_rendicion(p_fecha date, p_transportista_id uuid)
 RETURNS TABLE(cliente_id bigint, cliente_nombre text, cobrado_por_id uuid, cobrado_por text, total numeric, total_entregas numeric, total_ctascte numeric, efectivo numeric, transferencia numeric, cheque numeric, tarjeta numeric, cuenta_corriente numeric, otros numeric, cantidad_pagos bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal_id bigint;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no seleccionada';
  END IF;
  IF NOT es_encargado_o_admin() THEN
    -- #724: el transportista sólo abre su propia rendición.
    IF NOT es_transportista() THEN
      RAISE EXCEPTION 'No autorizado';
    END IF;
    IF p_transportista_id IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION 'Acceso denegado' USING ERRCODE = '42501';
    END IF;
  END IF;

  -- #1248: de _rendicion_pagos, que para una rendicion cerrada lee su foto.
  RETURN QUERY
  SELECT
    rp.cliente_id AS cliente_id,
    COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social, 'Cliente #' || rp.cliente_id)::text AS cliente_nombre,
    rp.usuario_id AS cobrado_por_id,
    COALESCE(u.nombre, 'Sin usuario')::text AS cobrado_por,
    SUM(rp.monto)::numeric AS total,
    SUM(CASE WHEN rp.es_entrega_del_dia THEN rp.monto ELSE 0 END)::numeric AS total_entregas,
    SUM(CASE WHEN rp.es_entrega_del_dia THEN 0 ELSE rp.monto END)::numeric AS total_ctascte,
    SUM(CASE WHEN rp.forma_pago = 'efectivo' THEN rp.monto ELSE 0 END)::numeric AS efectivo,
    SUM(CASE WHEN rp.forma_pago = 'transferencia' THEN rp.monto ELSE 0 END)::numeric AS transferencia,
    SUM(CASE WHEN rp.forma_pago = 'cheque' THEN rp.monto ELSE 0 END)::numeric AS cheque,
    SUM(CASE WHEN rp.forma_pago = 'tarjeta' THEN rp.monto ELSE 0 END)::numeric AS tarjeta,
    SUM(CASE WHEN rp.forma_pago = 'cuenta_corriente' THEN rp.monto ELSE 0 END)::numeric AS cuenta_corriente,
    SUM(CASE WHEN rp.forma_pago NOT IN ('efectivo','transferencia','cheque','tarjeta','cuenta_corriente')
              OR rp.forma_pago IS NULL THEN rp.monto ELSE 0 END)::numeric AS otros,
    COUNT(*)::bigint AS cantidad_pagos
  FROM public._rendicion_pagos(v_sucursal_id, p_fecha, p_fecha) rp
  LEFT JOIN clientes c ON c.id = rp.cliente_id
  LEFT JOIN perfiles u ON u.id = rp.usuario_id
  WHERE rp.t_id = p_transportista_id
    -- migs 273/276 (#832, #833): las formas no dinerarias no son plata de la rendicion.
    AND COALESCE(rp.forma_pago, '') <> 'adelanto_sueldo'
  GROUP BY rp.cliente_id, c.nombre_fantasia, c.razon_social, rp.usuario_id, u.nombre
  ORDER BY SUM(rp.monto) DESC;
END;
$function$;

CREATE OR REPLACE FUNCTION public.obtener_pagos_rendicion_cliente(p_fecha date, p_transportista_id uuid, p_cliente_id bigint)
 RETURNS TABLE(pago_id bigint, created_at timestamp with time zone, monto numeric, forma_pago text, referencia text, notas text, pedido_id bigint, pedido_fecha date, pedido_estado text, pedido_total numeric, cobrado_por text, es_entrega_del_dia boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal_id bigint;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no seleccionada';
  END IF;
  IF NOT es_encargado_o_admin() THEN
    -- #724: el transportista sólo abre su propia rendición.
    IF NOT es_transportista() THEN
      RAISE EXCEPTION 'No autorizado';
    END IF;
    IF p_transportista_id IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION 'Acceso denegado' USING ERRCODE = '42501';
    END IF;
  END IF;

  -- #1248: de _rendicion_pagos, que para una rendicion cerrada lee su foto.
  RETURN QUERY
  SELECT
    rp.pago_id,
    rp.pago_created_at,
    rp.monto::numeric,
    rp.forma_pago::text,
    rp.referencia::text,
    rp.notas::text,
    rp.pedido_id,
    rp.pedido_fecha,
    rp.pedido_estado::text,
    rp.pedido_total::numeric,
    COALESCE(u.nombre, 'Sin usuario')::text,
    rp.es_entrega_del_dia
  FROM public._rendicion_pagos(v_sucursal_id, p_fecha, p_fecha) rp
  LEFT JOIN perfiles u ON u.id = rp.usuario_id
  WHERE rp.t_id = p_transportista_id
    AND rp.cliente_id = p_cliente_id
    -- migs 273/276 (#832, #833): las formas no dinerarias no son plata de la rendicion.
    AND COALESCE(rp.forma_pago, '') <> 'adelanto_sueldo'
  ORDER BY rp.pago_created_at ASC, rp.pago_id ASC;
END;
$function$;

CREATE OR REPLACE FUNCTION public.obtener_resumen_rendiciones(p_fecha_desde date DEFAULT ((((now() AT TIME ZONE 'America/Argentina/Buenos_Aires'::text))::date - '30 days'::interval))::date, p_fecha_hasta date DEFAULT ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires'::text))::date, p_transportista_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(fecha date, transportista_id uuid, transportista_nombre text, total_efectivo numeric, total_transferencia numeric, total_cheque numeric, total_cuenta_corriente numeric, total_tarjeta numeric, total_otros numeric, total_adelanto_sueldo numeric, total_general numeric, total_entregas numeric, total_ctascte numeric, cantidad_pedidos bigint, total_entregado numeric, total_gastos numeric, cantidad_gastos bigint, estado text, observaciones text, controlada boolean, controlada_at timestamp with time zone, controlada_por_nombre text, resuelta_at timestamp with time zone, resuelta_por_nombre text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal_id BIGINT;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no seleccionada';
  END IF;
  IF NOT es_encargado_o_admin() THEN
    -- #724: el transportista ve sólo su propia fila (null = yo, como
    -- avance_metas_preventista). es_transportista() incluye admin y rol
    -- extra (trampa 4); el admin ya entró por la rama de arriba.
    IF NOT es_transportista() THEN
      RAISE EXCEPTION 'No autorizado';
    END IF;
    IF p_transportista_id IS NOT NULL AND p_transportista_id <> auth.uid() THEN
      RAISE EXCEPTION 'Acceso denegado' USING ERRCODE = '42501';
    END IF;
    p_transportista_id := auth.uid();
  END IF;

  RETURN QUERY
  WITH rp AS (
    -- #1248: de _rendicion_pagos, que para una rendicion cerrada lee su foto.
    SELECT x.*
      FROM public._rendicion_pagos(v_sucursal_id, p_fecha_desde, p_fecha_hasta) x
     WHERE x.t_id IS NOT NULL
       AND (p_transportista_id IS NULL OR x.t_id = p_transportista_id)
  ),
  pagos_agg AS (
    SELECT
      rp.t_id,
      rp.f,
      SUM(CASE WHEN rp.forma_pago = 'efectivo' THEN rp.monto ELSE 0 END)::numeric AS tot_ef,
      SUM(CASE WHEN rp.forma_pago = 'transferencia' THEN rp.monto ELSE 0 END)::numeric AS tot_tr,
      SUM(CASE WHEN rp.forma_pago = 'cheque' THEN rp.monto ELSE 0 END)::numeric AS tot_ch,
      SUM(CASE WHEN rp.forma_pago = 'cuenta_corriente' THEN rp.monto ELSE 0 END)::numeric AS tot_cc,
      SUM(CASE WHEN rp.forma_pago = 'tarjeta' THEN rp.monto ELSE 0 END)::numeric AS tot_tj,
      SUM(CASE WHEN rp.forma_pago NOT IN ('efectivo','transferencia','cheque','cuenta_corriente','tarjeta')
                OR rp.forma_pago IS NULL THEN rp.monto ELSE 0 END)::numeric AS tot_ot,
      SUM(rp.monto)::numeric AS tot_gen,
      SUM(CASE WHEN rp.es_entrega_del_dia THEN rp.monto ELSE 0 END)::numeric AS tot_entregas,
      SUM(CASE WHEN rp.es_entrega_del_dia THEN 0 ELSE rp.monto END)::numeric AS tot_ctascte
    FROM rp
    -- migs 273/276 (#832, #833): las formas no dinerarias no son plata de la rendicion.
    WHERE COALESCE(rp.forma_pago, '') <> 'adelanto_sueldo'
    GROUP BY rp.t_id, rp.f
  ),
  /* mig 273 (#832) · informativo: mismo criterio de atribucion que pagos_agg, pero NO
     aporta filas a fechas_activas (ver el encabezado de la migracion). */
  adelantos_agg AS (
    SELECT rp.t_id, rp.f, SUM(rp.monto)::numeric AS tot_adel
      FROM rp
     WHERE rp.forma_pago = 'adelanto_sueldo'
     GROUP BY rp.t_id, rp.f
  ),
  entregas_agg AS (
    SELECT e.t_id, e.f, e.tot_entregado, e.cant
      FROM public._rendicion_entregas(v_sucursal_id, p_fecha_desde, p_fecha_hasta) e
     WHERE (p_transportista_id IS NULL OR e.t_id = p_transportista_id)
  ),
  gastos_agg AS (
    SELECT
      rg.transportista_id AS t_id,
      rg.fecha AS f,
      SUM(rg.monto)::numeric AS tot_g,
      COUNT(*)::bigint AS cant_g
    FROM rendicion_gastos rg
    WHERE rg.fecha BETWEEN p_fecha_desde AND p_fecha_hasta
      AND rg.sucursal_id = v_sucursal_id
      AND (p_transportista_id IS NULL OR rg.transportista_id = p_transportista_id)
    GROUP BY rg.transportista_id, rg.fecha
  ),
  /* #1248 · una rendicion cerrada esta siempre en la grilla, aunque lo vivo de
     su dia ya no le deje pagos ni entregas. */
  cerradas AS (
    SELECT rc0.transportista_id AS t_id, rc0.fecha AS f
      FROM rendiciones_control rc0
     WHERE rc0.sucursal_id = v_sucursal_id
       AND rc0.estado IN ('confirmada', 'resuelta')
       AND rc0.fecha BETWEEN p_fecha_desde AND p_fecha_hasta
       AND (p_transportista_id IS NULL OR rc0.transportista_id = p_transportista_id)
  ),
  /* mig 245 (#639) · fechas_activas es el esqueleto de la grilla. gastos_agg ya
     estaba calculado y LEFT-JOINeado abajo, pero no aportaba filas: un
     transportista que un dia solo cargo gastos --sin cobrar ni entregar-- no
     aparecia, y su rendicion de ese dia era invisible para el control. */
  fechas_activas AS (
    SELECT pa.t_id, pa.f FROM pagos_agg pa
    UNION
    SELECT ea.t_id, ea.f FROM entregas_agg ea
    UNION
    SELECT ga.t_id, ga.f FROM gastos_agg ga
    UNION
    SELECT ce.t_id, ce.f FROM cerradas ce
  )
  SELECT
    fa.f::date AS fecha,
    fa.t_id AS transportista_id,
    tr.nombre::text AS transportista_nombre,
    COALESCE(pagos_agg.tot_ef, 0)::numeric AS total_efectivo,
    COALESCE(pagos_agg.tot_tr, 0)::numeric AS total_transferencia,
    COALESCE(pagos_agg.tot_ch, 0)::numeric AS total_cheque,
    COALESCE(pagos_agg.tot_cc, 0)::numeric AS total_cuenta_corriente,
    COALESCE(pagos_agg.tot_tj, 0)::numeric AS total_tarjeta,
    COALESCE(pagos_agg.tot_ot, 0)::numeric AS total_otros,
    COALESCE(adelantos_agg.tot_adel, 0)::numeric AS total_adelanto_sueldo,
    COALESCE(pagos_agg.tot_gen, 0)::numeric AS total_general,
    COALESCE(pagos_agg.tot_entregas, 0)::numeric AS total_entregas,
    COALESCE(pagos_agg.tot_ctascte, 0)::numeric AS total_ctascte,
    -- #1248: lo entregado de un dia cerrado tambien sale de la foto.
    (CASE WHEN rc.estado IN ('confirmada', 'resuelta') AND rc.cantidad_pedidos_confirmada IS NOT NULL
          THEN rc.cantidad_pedidos_confirmada
          ELSE COALESCE(entregas_agg.cant, 0) END)::bigint AS cantidad_pedidos,
    (CASE WHEN rc.estado IN ('confirmada', 'resuelta') AND rc.total_entregado_confirmado IS NOT NULL
          THEN rc.total_entregado_confirmado
          ELSE COALESCE(entregas_agg.tot_entregado, 0) END)::numeric AS total_entregado,
    COALESCE(gastos_agg.tot_g, 0)::numeric AS total_gastos,
    COALESCE(gastos_agg.cant_g, 0)::bigint AS cantidad_gastos,
    COALESCE(rc.estado, 'pendiente')::text AS estado,
    rc.observaciones,
    (rc.id IS NOT NULL AND COALESCE(rc.estado, 'pendiente') IN ('confirmada','resuelta')) AS controlada,
    rc.controlada_at,
    cp.nombre::text AS controlada_por_nombre,
    rc.resuelta_at,
    rp2.nombre::text AS resuelta_por_nombre
  FROM fechas_activas fa
  JOIN perfiles tr ON tr.id = fa.t_id
  LEFT JOIN pagos_agg ON pagos_agg.t_id = fa.t_id AND pagos_agg.f = fa.f
  LEFT JOIN adelantos_agg ON adelantos_agg.t_id = fa.t_id AND adelantos_agg.f = fa.f
  LEFT JOIN entregas_agg ON entregas_agg.t_id = fa.t_id AND entregas_agg.f = fa.f
  LEFT JOIN gastos_agg ON gastos_agg.t_id = fa.t_id AND gastos_agg.f = fa.f
  LEFT JOIN rendiciones_control rc
    ON rc.fecha = fa.f
   AND rc.transportista_id = fa.t_id
   AND rc.sucursal_id = v_sucursal_id
  LEFT JOIN perfiles cp ON cp.id = rc.controlada_por
  LEFT JOIN perfiles rp2 ON rp2.id = rc.resuelta_por
  ORDER BY fa.f DESC, tr.nombre ASC;
END;
$function$;

-- El comentario de la 165 decia que reimputar "no altera la rendicion". Alteraba
-- su desglose (a que chofer y a que renglon iba cada pago, COB-4); desde la foto
-- de #1248 la confirmada ya no cambia.
CREATE OR REPLACE FUNCTION public.guard_pago_fecha_cerrada()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_limite date;
BEGIN
  IF NEW.sucursal_id IS NULL OR NEW.fecha IS NULL THEN
    RETURN NEW;
  END IF;

  -- Reimputacion interna (mig 165): mover plata ya cobrada entre boletas del
  -- mismo cliente no cambia el total del dia, solo a que boleta se aplica. El
  -- desglose por chofer de una rendicion confirmada tampoco cambia: se lee de su
  -- foto (rendicion_pagos_confirmados, #1248). El GUC es transaction-scoped y lo
  -- setean unicamente las funciones de reimputacion (aplicar_credito_cliente,
  -- imputar_credito_a_pedido_impl, _pagos_excedente_a_favor).
  IF current_setting('app.reimputacion_pagos', true) = 'on' THEN
    RETURN NEW;
  END IF;

  -- mig 276 (#833): un credito de NC no es plata de la rendicion (las RPCs de
  -- rendiciones lo excluyen), asi que emitirlo un dia con la caja controlada
  -- no la desbalancea. Quien lo puede crear lo decide pagos_guard_nota_credito.
  IF NEW.forma_pago = 'nota_credito' THEN
    RETURN NEW;
  END IF;

  -- #1150 (molde: pagos_rechazar_pedido_de_baja, mig 360). Reintento de un pago
  -- que ya entro (mig 167): se deja seguir hasta idx_pagos_client_request_id,
  -- que da el 23505 con el que el front devuelve la fila existente. Si la caja
  -- se cerro entre los dos intentos (o el reintento sin fecha cruzo medianoche
  -- y cayo en un dia cerrado), rechazarlo con 42501 invita a cargarlo de nuevo
  -- con otra fecha y duplica el cobro. No deja entrar ninguna fila: con el UUID
  -- ya presente el indice parcial lo rechaza siempre; solo cambia el codigo.
  -- Solo en INSERT: en un UPDATE de fecha o monto el client_request_id es el de
  -- la propia fila, y la caja manda.
  IF TG_OP = 'INSERT' AND NEW.client_request_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM pagos WHERE client_request_id = NEW.client_request_id) THEN
    RETURN NEW;
  END IF;

  v_limite := public.ultima_fecha_caja_cerrada(NEW.sucursal_id);

  IF v_limite IS NOT NULL AND NEW.fecha <= v_limite THEN
    RAISE EXCEPTION 'La caja de la sucursal esta cerrada hasta el % (rendicion controlada). No se puede registrar/editar un pago con fecha %. Reabri la rendicion de ese dia para hacer cambios.',
      to_char(v_limite, 'DD/MM/YYYY'), to_char(NEW.fecha, 'DD/MM/YYYY')
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$function$;
