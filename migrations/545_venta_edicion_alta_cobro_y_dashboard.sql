-- =========================================================================
-- NNN · LA EDICIÓN CON LA BARRA EN 0, EL ALTA SIN PRODUCTO, EL COBRO COMBINADO
--       Y EL DASHBOARD DEL PREVENTISTA (plan #1603, tanda 6 bis, tarjeta H)
--
-- Ensayo: scripts/test-venta-tanda6bis-1603.sql (falla sin esta migración en
-- H1a, H3a, H3b, H4 y H5; ENSAYO OK con ella). Se aplica en LF. Sólo cambia
-- cuerpos de funciones y crea una RPC: no toca tablas ni toma sus locks.
-- Ninguna firma cambia: un bundle viejo del PWA sigue llamando igual.
--
-- 1 · stock-STK-2: la edición rechazaba un cambio de neto 0 sobre el
--     contenedor de una barra en 0. A×20 + S×4 cierra dos bloques y deja C en
--     0; editar a A×10 + S×2 + C×1 devuelve un fardo (la barra baja) y vende
--     uno, pero el pre-chequeo no contaba el fardo y, aun sin él, la bajada de
--     la línea iba antes que la barra (_barra_mover_neto, al final) y chocaba
--     con productos_stock_no_negativo. Ahora, si todo lo que le falta al
--     pre-chequeo es stock de un contenedor con bloques vivos de una promo cuya
--     barra el pedido tiene, la edición no se rechaza ahí: las bajadas de las
--     líneas van DESPUÉS de mover la barra, cada una con su línea (la huella) y
--     con las etiquetas de siempre, y si aun así falta stock se rechaza con el
--     mismo «stock insuficiente» (y no se escribe nada). Toda edición que hoy
--     pasa el pre-chequeo sigue por el orden de siempre: su resultado no cambia.
--     actualizar_pedido_items va por ancla.
-- 2 · residual de promos-B6: no hacía falta. El segundo chequeo de la edición
--     (la línea cambiada por valor mandada tal como está) mide el corte
--     guardado de esa línea, que es exactamente lo que el paso 4 de
--     regalo_fuera_de_promo conserva: con la promo apagada, «corte > tope» es
--     «corte > LEAST(tope, conservado)». El ensayo lo deja como regresión (H2).
-- 3 · venta-B4 en el alta: crear_pedido_completo y crear_pedido_completo_bot
--     contestaban «key must not be null» a un renglón sin producto. Ahora
--     success=false con el motivo de la edición (542), antes de escribir nada.
--     El bot va por ancla y sin md5 (es de la otra sesión: sólo esta guarda).
-- 4 · gemelo de cobros-B4: registrar_pago_combinado_cliente_fifo_impl con un
--     cliente de otra sucursal terminaba en el 23503 de la FK; ahora «Cliente
--     no encontrado» (P0002) antes de tomar nada, como el FIFO simple (542).
-- 5 · Dashboard del preventista neto (decisión del dueño del 24/11: «que vea
--     $ 700, neto»). RPC nueva notas_credito_venta_del_vendedor(desde, hasta,
--     cliente): a quien actúa como preventista (no admin ni encargado, que leen
--     por REST) le da la fecha, el cliente y el total de cada nota de crédito de
--     venta vigente de una boleta que es venta (la de _ventas_nc) y que ÉL
--     vendió, en la sucursal activa. Nada más: ni motivo, ni renglones, ni quién
--     la emitió. DEFINER, search_path con pg_temp, el rol por los helpers (un
--     desactivado no ve nada), REVOKE de PUBLIC y anon.
--
-- Revertir: volver los cuatro cuerpos a los md5 de la premisa (o el bot, a su
-- texto sin la guarda) y DROP FUNCTION public.notas_credito_venta_del_vendedor.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos de producción en la 544.
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', '03e674c56d0ba2a6842c4c950ca732dc'),
    ('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)', '8b0db4fcd010599185a1aee539b58dac'),
    ('public.registrar_pago_combinado_cliente_fifo_impl(bigint,jsonb,date,text,text)', 'e3cdf655997c7f79ee15418fc34683e5'),
    -- Por ancla, sin md5: es del bot (otra sesión puede tocar otro tramo).
    ('public.crear_pedido_completo_bot(uuid,uuid)', NULL)
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    IF r.h IS NULL THEN CONTINUE; END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;
  IF to_regprocedure('public.notas_credito_venta_del_vendedor(date,date,bigint)') IS NOT NULL
     OR EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace
                   AND proname = 'notas_credito_venta_del_vendedor') THEN
    RAISE EXCEPTION 'mig NNN · notas_credito_venta_del_vendedor ya existe: rehacer sobre lo vigente';
  END IF;
END
$premisas$;

-- Reemplaza un ancla que tiene que aparecer exactamente p_n veces.
CREATE FUNCTION pg_temp.parche(p_def text, p_ancla text, p_nuevo text, p_n int, p_que text)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v_n int := (length(p_def) - length(replace(p_def, p_ancla, ''))) / length(p_ancla);
BEGIN
  IF v_n <> p_n THEN
    RAISE EXCEPTION 'mig NNN · %: el ancla aparece % vez/veces y se esperaba %', p_que, v_n, p_n;
  END IF;
  RETURN replace(p_def, p_ancla, p_nuevo);
END
$f$;

-- =========================================================================
-- 1 · stock-STK-2: actualizar_pedido_items
-- =========================================================================
DO $stk2$
DECLARE
  v_def text := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  v_barra_neto   JSONB := '{}'::jsonb;
BEGIN$a$,
$a$  v_barra_neto   JSONB := '{}'::jsonb;
  -- stock-STK-2 (tanda 6 bis de #1603): las bajadas de las líneas van después de la
  -- barra cuando lo único que le falta al pre-chequeo es lo que la barra puede devolver.
  v_n_contenedor  INT := 0;
  v_barra_primero BOOLEAN := false;
  v_bajadas       JSONB := '[]'::jsonb;
  v_bajada        RECORD;
  v_gucs          TEXT[];
  v_stock_hoy     INT;
  v_nombre_hoy    TEXT;
BEGIN$a$,
    1, 'actualizar_pedido_items (STK-2, variables)');

  v_def := pg_temp.parche(v_def,
$a$      ELSIF v_chequeo.stock < v_chequeo.diferencia THEN
        v_errores := array_append(v_errores, COALESCE(v_chequeo.nombre, 'Producto ' || v_chequeo.producto_id)
          || ': stock insuficiente (disponible: ' || v_chequeo.stock || ', adicional: ' || v_chequeo.diferencia || ')');
      END IF;
    END IF;
  END LOOP;

  IF array_length(v_errores, 1) > 0 THEN$a$,
$a$      ELSIF v_chequeo.stock < v_chequeo.diferencia THEN
        v_errores := array_append(v_errores, COALESCE(v_chequeo.nombre, 'Producto ' || v_chequeo.producto_id)
          || ': stock insuficiente (disponible: ' || v_chequeo.stock || ', adicional: ' || v_chequeo.diferencia || ')');
        -- stock-STK-2 (tanda 6 bis de #1603): el contenedor de una barra que el pedido
        -- tiene, con bloques vivos. Bajar esa barra le devuelve fardos que el pre-chequeo
        -- no cuenta (los devuelve _barra_mover_neto, al final).
        IF EXISTS (SELECT 1 FROM promo_ajustes pa
                    WHERE pa.sucursal_id = v_sucursal AND pa.producto_id = v_chequeo.producto_id
                      AND pa.bloques_vivos > 0
                      AND pa.promocion_id IN (SELECT pi.promocion_id FROM pedido_items pi
                                               WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
                                                 AND COALESCE(pi.es_bonificacion, false) AND pi.promocion_id IS NOT NULL
                                                 AND public._regalo_barra_vale(p_pedido_id, pi.promocion_id, v_sucursal))) THEN
          v_n_contenedor := v_n_contenedor + 1;
        END IF;
      END IF;
    END IF;
  END LOOP;

  -- stock-STK-2 (tanda 6 bis de #1603): si TODO lo que falta es stock de esos
  -- contenedores, la edición no se rechaza acá: las bajadas de las líneas van después de
  -- mover la barra (abajo), que es cuando el fardo volvió. Si aun así no alcanza, se
  -- rechaza ahí con el mismo motivo y no queda nada escrito. Cualquier otro faltante (o
  -- un producto desactivado) se rechaza acá como siempre, y una edición que pasa el
  -- pre-chequeo sigue por el orden de siempre: su resultado no cambia.
  IF array_length(v_errores, 1) > 0 AND array_length(v_errores, 1) = v_n_contenedor THEN
    v_barra_primero := true;
    v_errores := '{}';
  END IF;

  IF array_length(v_errores, 1) > 0 THEN$a$,
    1, 'actualizar_pedido_items (STK-2, pre-chequeo)');

  v_def := pg_temp.parche(v_def,
$a$      PERFORM set_config('app.stock_pedido_item_id', v_pedido_item_guardado::text, true);
      UPDATE productos SET stock = stock - v_cantidad_nueva WHERE id = v_producto_guardado AND sucursal_id = v_sucursal;$a$,
$a$      PERFORM set_config('app.stock_pedido_item_id', v_pedido_item_guardado::text, true);
      IF v_barra_primero THEN
        -- stock-STK-2: después de la barra, con su línea (abajo).
        v_bajadas := v_bajadas || jsonb_build_object('item', v_pedido_item_guardado,
                                                     'producto', v_producto_guardado, 'cantidad', v_cantidad_nueva);
      ELSE
        UPDATE productos SET stock = stock - v_cantidad_nueva WHERE id = v_producto_guardado AND sucursal_id = v_sucursal;
      END IF;$a$,
    1, 'actualizar_pedido_items (STK-2, bajada de venta)');

  v_def := pg_temp.parche(v_def,
$a$        UPDATE productos SET stock = stock - v_cantidad_guardada WHERE id = v_producto_guardado AND sucursal_id = v_sucursal;$a$,
$a$        IF v_barra_primero THEN
          -- stock-STK-2: después de la barra, con su línea (abajo).
          v_bajadas := v_bajadas || jsonb_build_object('item', v_pedido_item_guardado,
                                                       'producto', v_producto_guardado, 'cantidad', v_cantidad_guardada);
        ELSE
          UPDATE productos SET stock = stock - v_cantidad_guardada WHERE id = v_producto_guardado AND sucursal_id = v_sucursal;
        END IF;$a$,
    1, 'actualizar_pedido_items (STK-2, bajada de regalo)');

  v_def := pg_temp.parche(v_def,
$a$    v_sucursal, p_usuario_id);

  -- 1559-b3: el precio conservado vale sólo para la reinserción.$a$,
$a$    v_sucursal, p_usuario_id);

  -- stock-STK-2 (tanda 6 bis de #1603): las bajadas que esperaron a la barra, en el orden
  -- de las líneas, cada una con su línea (la huella) y con las etiquetas de la bajada de
  -- arriba; el motor deja las suyas, así que se guardan y se reponen. Los productos están
  -- tomados (#1296): el stock que se lee es el vigente. Si no alcanza, el RAISE deshace la
  -- edición entera (como la red final de la 289).
  IF v_barra_primero THEN
    v_gucs := ARRAY[current_setting('app.stock_origen', true), current_setting('app.stock_ref_tipo', true),
                    current_setting('app.stock_ref_id', true), current_setting('app.stock_user_id', true),
                    current_setting('app.stock_pedido_item_id', true)];
    PERFORM set_config('app.stock_origen', 'pedido_creado', true);
    PERFORM set_config('app.stock_ref_tipo', 'pedido', true);
    PERFORM set_config('app.stock_ref_id', p_pedido_id::TEXT, true);
    PERFORM set_config('app.stock_user_id', COALESCE(p_usuario_id::TEXT, ''), true);
    FOR v_bajada IN
      SELECT (b.x->>'item')::BIGINT AS item, (b.x->>'producto')::BIGINT AS producto,
             (b.x->>'cantidad')::INT AS cantidad
        FROM jsonb_array_elements(v_bajadas) WITH ORDINALITY AS b(x, o)
       ORDER BY b.o
    LOOP
      SELECT stock, nombre INTO v_stock_hoy, v_nombre_hoy
        FROM productos WHERE id = v_bajada.producto AND sucursal_id = v_sucursal;
      IF COALESCE(v_stock_hoy, 0) < v_bajada.cantidad THEN
        RAISE EXCEPTION '%: stock insuficiente (disponible: %, hacen falta: %), contando lo que devuelve la barra de la promo. El pedido no se modificó.',
          COALESCE(v_nombre_hoy, 'Producto ' || v_bajada.producto), COALESCE(v_stock_hoy, 0), v_bajada.cantidad;
      END IF;
      PERFORM set_config('app.stock_pedido_item_id', v_bajada.item::TEXT, true);
      UPDATE productos SET stock = stock - v_bajada.cantidad WHERE id = v_bajada.producto AND sucursal_id = v_sucursal;
    END LOOP;
    PERFORM set_config('app.stock_origen', COALESCE(v_gucs[1], ''), true);
    PERFORM set_config('app.stock_ref_tipo', COALESCE(v_gucs[2], ''), true);
    PERFORM set_config('app.stock_ref_id', COALESCE(v_gucs[3], ''), true);
    PERFORM set_config('app.stock_user_id', COALESCE(v_gucs[4], ''), true);
    PERFORM set_config('app.stock_pedido_item_id', COALESCE(v_gucs[5], ''), true);
  END IF;

  -- 1559-b3: el precio conservado vale sólo para la reinserción.$a$,
    1, 'actualizar_pedido_items (STK-2, bajadas después de la barra)');
  EXECUTE v_def;
END
$stk2$;

-- =========================================================================
-- 3 · venta-B4 en el alta: crear_pedido_completo y crear_pedido_completo_bot
-- =========================================================================
DO $b4$
DECLARE
  v_def text;
BEGIN
  v_def := pg_get_functiondef('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)'::regprocedure);
  v_def := pg_temp.parche(v_def,
$a$  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista', 'encargado') THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No tiene permisos para crear pedidos')); END IF;
$a$,
$a$  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista', 'encargado') THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No tiene permisos para crear pedidos')); END IF;

  -- venta-B4 (tanda 6 bis de #1603): un renglón sin producto contestaba con el error crudo
  -- del jsonb_build_object de las cantidades («key must not be null»). El motivo de la
  -- edición (542), antes de escribir nada.
  IF EXISTS (SELECT 1
               FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_items) = 'array' THEN p_items ELSE '[]'::jsonb END) e
              WHERE NULLIF(e->>'producto_id', '') IS NULL) THEN
    RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
      'Hay un renglón sin producto: elegí el producto o sacá el renglón. El pedido no se creó.'));
  END IF;
$a$,
    1, 'crear_pedido_completo (venta-B4)');
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.crear_pedido_completo_bot(uuid,uuid)'::regprocedure);
  v_def := pg_temp.parche(v_def,
$a$  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado', 'preventista') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No tiene permisos para crear pedidos');
  END IF;
$a$,
$a$  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado', 'preventista') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No tiene permisos para crear pedidos');
  END IF;

  -- venta-B4 (tanda 6 bis de #1603): un renglón sin producto, como crear_pedido_completo,
  -- en la clave 'error' que muestra la edge function. La confirmación no se consume.
  IF EXISTS (SELECT 1
               FROM jsonb_array_elements(CASE WHEN jsonb_typeof(v_pendiente.items) = 'array'
                                              THEN v_pendiente.items ELSE '[]'::jsonb END) e
              WHERE NULLIF(e->>'producto_id', '') IS NULL) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Hay un renglón sin producto. Hacé el pedido de nuevo. El pedido no se creó.');
  END IF;
$a$,
    1, 'crear_pedido_completo_bot (venta-B4)');
  EXECUTE v_def;
END
$b4$;

-- =========================================================================
-- 4 · gemelo de cobros-B4: registrar_pago_combinado_cliente_fifo_impl
-- =========================================================================
DO $cob4$
DECLARE
  v_def text := pg_get_functiondef('public.registrar_pago_combinado_cliente_fifo_impl(bigint,jsonb,date,text,text)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$    RAISE EXCEPTION 'No autorizado: solo admin o encargado pueden registrar pagos desde ficha de cliente'
      USING ERRCODE = '42501';
  END IF;
$a$,
$a$    RAISE EXCEPTION 'No autorizado: solo admin o encargado pueden registrar pagos desde ficha de cliente'
      USING ERRCODE = '42501';
  END IF;

  -- Gemelo de cobros-B4 (tanda 6 bis de #1603): un cliente de otra sucursal (o que no
  -- existe) terminaba en el 23503 de la FK de pagos. Antes de tomar nada, como
  -- registrar_pago_cliente_fifo_impl (542).
  IF NOT EXISTS (SELECT 1 FROM clientes WHERE id = p_cliente_id AND sucursal_id = v_sucursal_id) THEN
    RAISE EXCEPTION 'Cliente no encontrado' USING ERRCODE = 'P0002';
  END IF;
$a$,
    1, 'registrar_pago_combinado_cliente_fifo_impl (cobros-B4)');
  EXECUTE v_def;
END
$cob4$;

-- =========================================================================
-- 5 · El Dashboard del preventista: sus notas de crédito de venta
-- =========================================================================
CREATE FUNCTION public.notas_credito_venta_del_vendedor(
  p_desde date DEFAULT NULL,
  p_hasta date DEFAULT NULL,
  p_cliente_id bigint DEFAULT NULL
)
RETURNS TABLE(fecha date, cliente_id bigint, total numeric)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
  -- Decisión del dueño del 24/11 («que vea $ 700, neto»): el Dashboard y el «Total
  -- comprado» de la ficha del preventista son netos de las notas de crédito de venta, como
  -- los de admin y encargado. mt_notas_credito_venta_select no le deja leerlas por REST, y
  -- abrírsela le mostraría motivos, renglones y notas de otros vendedores. Esto le da, de
  -- cada nota que resta (la de _ventas_nc: vigente, con plata, de una boleta entregada que
  -- no es canje ni vale blanco) de una boleta que ÉL vendió, en la sucursal activa, sólo lo
  -- que el front resta: la fecha de la nota (la de su boleta, B16), el cliente y el total.
  -- Admin y encargado no reciben nada (leen por REST: el front suma las dos fuentes sin
  -- repetir); quien no actúa como preventista, tampoco. Un desactivado no tiene rol (#1474).
  SELECT n.fecha, n.cliente_id, n.total
    FROM notas_credito_venta n
    JOIN pedidos pe ON pe.id = n.pedido_id AND pe.sucursal_id = n.sucursal_id
   WHERE public.es_preventista()
     AND NOT public.es_encargado_o_admin()
     AND n.sucursal_id = public.current_sucursal_id()
     AND pe.usuario_id = auth.uid()
     AND NOT n.anulada
     AND n.total > 0
     AND pe.estado = 'entregado'
     AND COALESCE(pe.canal, 'app') <> 'cambio'
     AND pe.tipo_factura IS DISTINCT FROM 'VB'
     AND (p_desde IS NULL OR n.fecha >= p_desde)
     AND (p_hasta IS NULL OR n.fecha <= p_hasta)
     AND (p_cliente_id IS NULL OR n.cliente_id = p_cliente_id)
   ORDER BY n.fecha, n.id
$fn$;

REVOKE ALL ON FUNCTION public.notas_credito_venta_del_vendedor(date, date, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.notas_credito_venta_del_vendedor(date, date, bigint) TO authenticated, service_role;

COMMENT ON FUNCTION public.notas_credito_venta_del_vendedor(date, date, bigint) IS
  'Dashboard y ficha del preventista (tanda 6 bis de #1603): fecha, cliente y total de las notas de crédito de venta vigentes de las boletas que vendió quien llama, en la sucursal activa. Vacío para admin y encargado (leen por REST).';

-- ---------------------------------------------------------------------------
-- Poscondiciones
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'v_barra_primero', 5, true),
    ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'contando lo que devuelve la barra de la promo', 1, true),
    ('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)', 'Hay un renglón sin producto', 1, true),
    ('public.crear_pedido_completo_bot(uuid,uuid)', 'Hay un renglón sin producto', 1, true),
    ('public.registrar_pago_combinado_cliente_fifo_impl(bigint,jsonb,date,text,text)', 'Cliente no encontrado', 1, true),
    ('public.notas_credito_venta_del_vendedor(date,date,bigint)', 'pe.usuario_id = auth.uid()', 1, true)
  ) AS t(f, marca, n, definer) LOOP
    IF (SELECT (length(prosrc) - length(replace(prosrc, r.marca, ''))) / length(r.marca)
          FROM pg_proc WHERE oid = r.f::regprocedure) <> r.n
       OR (SELECT prosecdef FROM pg_proc WHERE oid = r.f::regprocedure) <> r.definer THEN
      RAISE EXCEPTION 'mig NNN · el parche de % no entró (% debía aparecer % veces)', r.f, r.marca, r.n;
    END IF;
  END LOOP;
  -- Todas con su search_path terminado en pg_temp (B15).
  FOR r IN SELECT unnest(ARRAY[
      'public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)',
      'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)',
      'public.crear_pedido_completo_bot(uuid,uuid)',
      'public.registrar_pago_combinado_cliente_fifo_impl(bigint,jsonb,date,text,text)',
      'public.notas_credito_venta_del_vendedor(date,date,bigint)']) AS f LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = r.f::regprocedure
                    AND proconfig @> ARRAY['search_path=public, pg_temp']) THEN
      RAISE EXCEPTION 'mig NNN · % quedó sin pg_temp en su search_path', r.f;
    END IF;
  END LOOP;
  -- Los permisos: las RPCs del front, para authenticated; el bot y el _impl, sólo server; nada para anon.
  FOR r IN SELECT * FROM (VALUES
      ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', true),
      ('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)', true),
      ('public.notas_credito_venta_del_vendedor(date,date,bigint)', true),
      ('public.crear_pedido_completo_bot(uuid,uuid)', false),
      ('public.registrar_pago_combinado_cliente_fifo_impl(bigint,jsonb,date,text,text)', false)
    ) AS t(f, api) LOOP
    IF has_function_privilege('anon', r.f, 'EXECUTE')
       OR has_function_privilege('authenticated', r.f, 'EXECUTE') IS DISTINCT FROM r.api THEN
      RAISE EXCEPTION 'mig NNN · los permisos de % no son los esperados', r.f;
    END IF;
  END LOOP;
  -- La RPC nueva devuelve sólo fecha, cliente y total.
  IF pg_get_function_result('public.notas_credito_venta_del_vendedor(date,date,bigint)'::regprocedure)
     IS DISTINCT FROM 'TABLE(fecha date, cliente_id bigint, total numeric)' THEN
    RAISE EXCEPTION 'mig NNN · notas_credito_venta_del_vendedor no devuelve lo esperado';
  END IF;
  -- SEG-A no ve ninguna de las funciones de esta migración (lee sólo el catálogo).
  IF EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol() x
              WHERE row_to_json(x)::text ~ '(actualizar_pedido_items|crear_pedido_completo|registrar_pago_combinado_cliente_fifo_impl|notas_credito_venta_del_vendedor)\(') THEN
    RAISE EXCEPTION 'mig NNN · SEG-A ve una función de esta migración';
  END IF;
END
$post$;

COMMIT;
