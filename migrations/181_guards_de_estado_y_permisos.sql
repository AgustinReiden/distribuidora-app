-- =========================================================================
-- 181_guards_de_estado_y_permisos.sql
--
-- Las invariantes de negocio de pedidos y pagos vivian en el front.
--
-- Es el patron de fondo que dejo la auditoria adversarial: la UI esconde el
-- boton, filtra el pedido o desactiva la accion, y la base acepta cualquier
-- cosa. Alcanza con una carrera de dos usuarios, una pestaña con datos viejos o
-- la consola del navegador para saltearse todo.
--
-- 1 · EL CHOFER PODIA REESCRIBIR LA PLATA DE CUALQUIER PEDIDO SUYO
-- -----------------------------------------------------------------
-- `mt_pedidos_update` autoriza por `transportista_id = auth.uid()` y NO
-- restringe columnas; `authenticated` tiene UPDATE sobre las 34 columnas de
-- `pedidos`. Con la sesion de la PWA abierta y la consola del navegador, el
-- chofer podia bajarle el `total` a cualquier pedido que alguna vez llevo — y
-- bajar el total dispara `pedidos_reconciliar_pagos`, que BORRA filas de
-- `pagos`: podia hacer desaparecer la cobranza que tenia que rendir.
-- Ni siquiera hace falta rol 'transportista': la policy compara la columna, asi
-- que "Juan" (rol preventista) tiene 71 pedidos escribibles por esa via.
--
-- Las policies RLS de Postgres NO pueden restringir columnas, y un
-- `REVOKE`/`GRANT UPDATE (cols)` aplicaria tambien al admin y romperia la
-- edicion. El mecanismo correcto es un trigger guard, que ya existe en este
-- repo para `clientes` (`clientes_proteger_columnas_preventista`, mig 080).
--
-- La parte fina de ese patron son las dos exenciones:
--
--   IF current_user <> 'authenticated' THEN RETURN NEW; END IF;
--   IF pg_trigger_depth() > 1        THEN RETURN NEW; END IF;
--
-- La primera es la que hace que esto sea viable. Un trigger dispara AUNQUE la
-- funcion que escribe sea SECURITY DEFINER —eso saltea RLS, no triggers— asi
-- que sin la exencion romperia todo lo que el chofer hace legitimamente por RPC:
-- `marcar_no_entregado`, `registrar_salvedad`, `registrar_geolocalizacion_pedido`,
-- `aplicar_cambio_de_parada`. Dentro de una SECURITY DEFINER `current_user` es
-- el dueño (postgres), no 'authenticated', y por eso quedan exentas. Corolario:
-- esta funcion NO puede ser SECURITY DEFINER, o `current_user` seria siempre el
-- dueño y el guard no filtraria nada.
-- La segunda exime las cascadas: `recalcular_monto_pagado_pedido` escribe
-- `pedidos.monto_pagado` disparado por un INSERT en `pagos`.
--
-- Orden de disparo: los triggers BEFORE UPDATE corren alfabeticamente, y
-- `pedidos_proteger_columnas` < `trigger_actualizar_estado_pago`. Importa:
-- si corriera despues, veria el `estado_pago` que ese trigger acaba de calcular
-- sobre NEW y lo leeria como un cambio del cliente.
--
-- Al chofer se le deja una lista blanca de tres columnas, que es exactamente lo
-- que escribe `actualizarEstado` en el front (estado, fecha_entrega,
-- updated_at). Al resto de los no-admin se les aplica una lista NEGRA de plata e
-- identidad, a proposito: para el chofer el conjunto legitimo esta verificado y
-- cerrado, para el preventista no, y una lista blanca incompleta le romperia una
-- pantalla en vez de cerrar un agujero.
--
-- 2 · LAS TRES RPCs MASIVAS NO MIRABAN EL ESTADO
-- -----------------------------------------------
-- `marcar_entregas_masivo` no tiene ningun guard: pisa 'entregado' sobre un
-- cancelado o sobre un "no entregado" que el chofer acaba de marcar. Las otras
-- dos filtran para INSERTAR el pago pero no para el UPDATE final.
--
-- El unico guard real vivia en el filtro de la query del front, y la ventana es
-- todo el tiempo que el modal queda abierto: no hay realtime sobre `pedidos` ni
-- revalidacion al confirmar. Basta con que alguien cancele un pedido mientras el
-- encargado tiene el modal abierto.
--
-- 3 · EL COBRO MASIVO TAPABA UN COBRO CONCURRENTE
-- ------------------------------------------------
-- `marcar_pagos_masivo_impl` leia el saldo y despues escribia
-- `monto_pagado = total` a ciegas. Si el chofer cobraba el mismo pedido desde la
-- calle en esa ventana, quedaban dos filas en `pagos` y el pedido se veia
-- prolijamente saldado: el doble cobro solo aparecia auditando la tabla.
-- Ahora el lote se serializa con FOR UPDATE y `monto_pagado` se deja derivar por
-- el trigger desde SUM(pagos), que es la fuente de verdad.
--
-- 4 · EDITAR UN PEDIDO CANCELADO DUPLICABA EL STOCK
-- --------------------------------------------------
-- `actualizar_pedido_items` solo bloquea 'entregado'. Un cancelado ya tiene el
-- stock devuelto y el total en 0, y editarlo lo devuelve por segunda vez.
--
-- 5 · EDITAR UN PEDIDO YA CARGADO AL CAMION
-- ------------------------------------------
-- Un pedido 'asignado' esta impreso en la hoja de ruta y fisicamente arriba del
-- camion. La ventana del preventista (mismo dia, antes de las 15:30) no
-- contempla que la ruta ya salio. Paso 86 veces.
--
-- 6 · ANULAR UN PAGO NO RESPETABA LA CAJA CERRADA
-- ------------------------------------------------
-- Ya existia `trg_pagos_guard_fecha_cerrada`, pero es BEFORE INSERT OR UPDATE:
-- el DELETE quedaba libre. Se pudo vaciar plata de rendiciones confirmadas 15
-- veces, por $936.100.
--
-- El guard nuevo NO extiende esa funcion: `guard_pago_fecha_cerrada` es SECURITY
-- DEFINER, y ahi `current_user` es siempre el dueño. Se necesita una funcion sin
-- SECURITY DEFINER para poder distinguir el borrado directo desde la app del
-- borrado interno de `desafectar_sobrepago_pedido` — que es el que corre cuando
-- una salvedad baja el total de una boleta ya cobrada, y que NO hay que
-- bloquear. (El GUC `app.reimputacion_pagos` no sirve aca: `pedidos_reconciliar_pagos`
-- lo LEE como guarda de reentrada, no lo setea.)
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1 · El chofer solo confirma entregas
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pedidos_proteger_columnas()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $fn$
DECLARE
  v_bloqueadas text;
BEGIN
  -- RPCs SECURITY DEFINER, service_role, conexiones directas: exentas.
  -- Sin esto se romperia marcar_no_entregado / registrar_salvedad /
  -- registrar_geolocalizacion_pedido, que son del chofer y escriben otras columnas.
  IF current_user <> 'authenticated' THEN
    RETURN NEW;
  END IF;

  -- Cascadas desde otros triggers (monto_pagado desde pagos): exentas.
  IF pg_trigger_depth() > 1 THEN
    RETURN NEW;
  END IF;

  IF es_encargado_o_admin() THEN
    RETURN NEW;
  END IF;

  IF es_transportista() THEN
    -- Lista blanca: es exactamente lo que escribe `actualizarEstado` en el front.
    SELECT string_agg(o.key, ', ' ORDER BY o.key) INTO v_bloqueadas
    FROM jsonb_each(to_jsonb(OLD)) o
    JOIN jsonb_each(to_jsonb(NEW)) n ON n.key = o.key
    WHERE o.value IS DISTINCT FROM n.value
      AND o.key NOT IN ('estado', 'fecha_entrega', 'updated_at');

    IF v_bloqueadas IS NOT NULL THEN
      RAISE EXCEPTION 'Un transportista solo puede confirmar la entrega. Columnas rechazadas: %',
        v_bloqueadas
        USING ERRCODE = '42501';
    END IF;

    RETURN NEW;
  END IF;

  -- Resto de los no-admin (preventista): lista NEGRA de plata e identidad. Lo
  -- operativo (notas, fechas) sigue abierto porque es lo que la UI les ofrece.
  SELECT string_agg(o.key, ', ' ORDER BY o.key) INTO v_bloqueadas
  FROM jsonb_each(to_jsonb(OLD)) o
  JOIN jsonb_each(to_jsonb(NEW)) n ON n.key = o.key
  WHERE o.value IS DISTINCT FROM n.value
    AND o.key IN (
      'total', 'total_neto', 'total_iva', 'total_real', 'monto_pagado',
      'estado_pago', 'cliente_id', 'sucursal_id', 'usuario_id', 'creado_por',
      'preventista_id', 'tipo_factura', 'stock_descontado', 'offline_id'
    );

  IF v_bloqueadas IS NOT NULL THEN
    RAISE EXCEPTION 'No tenes permiso para modificar estas columnas de pedidos: %',
      v_bloqueadas
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$fn$;

COMMENT ON FUNCTION public.pedidos_proteger_columnas() IS
  'Acota que columnas de pedidos puede escribir cada rol por PostgREST. NO debe '
  'ser SECURITY DEFINER: necesita ver el current_user real para eximir a las '
  'RPCs SECURITY DEFINER del chofer (un trigger dispara igual dentro de ellas). '
  'Mig 181.';

-- El nombre importa: los BEFORE UPDATE corren alfabeticamente y este tiene que
-- ver NEW como lo mando el cliente, antes de trigger_actualizar_estado_pago.
DROP TRIGGER IF EXISTS pedidos_proteger_columnas ON public.pedidos;
CREATE TRIGGER pedidos_proteger_columnas
  BEFORE UPDATE ON public.pedidos
  FOR EACH ROW
  EXECUTE FUNCTION public.pedidos_proteger_columnas();

-- -------------------------------------------------------------------------
-- 2 · marcar_entregas_masivo: no revivir cancelados ni pisar entregas
-- -------------------------------------------------------------------------
DO $mig$
DECLARE
  v_def   text;
  v_ancla CONSTANT text := $a$   WHERE id = ANY(p_pedido_ids)
     AND sucursal_id = v_sucursal_id;$a$;
  v_nuevo CONSTANT text := $a$   WHERE id = ANY(p_pedido_ids)
     AND sucursal_id = v_sucursal_id
     -- mig 181: el unico guard vivia en el filtro de la query del front, y la
     -- ventana es todo el tiempo que el modal queda abierto (sin realtime sobre
     -- pedidos ni revalidacion al confirmar).
     AND COALESCE(estado, '') NOT IN ('entregado', 'cancelado', 'anulado');$a$;
  v_veces integer;
BEGIN
  v_def := pg_get_functiondef('public.marcar_entregas_masivo(bigint[],uuid,date)'::regprocedure);
  IF position('mig 181' in v_def) > 0 THEN
    RAISE NOTICE 'mig 181 . marcar_entregas_masivo ya parcheada, se omite';
    RETURN;
  END IF;
  v_veces := (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'mig 181 . el ancla de marcar_entregas_masivo aparece % veces (se esperaba 1). El cuerpo derivo.', v_veces;
  END IF;
  EXECUTE replace(v_def, v_ancla, v_nuevo);
END;
$mig$;

-- -------------------------------------------------------------------------
-- 3 · marcar_pagos_masivo_impl: lock del lote y no pisar monto_pagado
-- -------------------------------------------------------------------------
DO $mig$
DECLARE
  v_def    text;
  v_loop   CONSTANT text := $a$    FROM pedidos
    WHERE id = ANY(p_pedido_ids)
      AND sucursal_id = v_sucursal_id
      AND COALESCE(estado_pago, 'pendiente') <> 'pagado'
      AND total > COALESCE(monto_pagado, 0)
  LOOP$a$;
  v_loop_n CONSTANT text := $a$    FROM pedidos
    WHERE id = ANY(p_pedido_ids)
      AND sucursal_id = v_sucursal_id
      AND COALESCE(estado_pago, 'pendiente') <> 'pagado'
      AND COALESCE(estado, '') NOT IN ('cancelado', 'anulado')
      AND total > COALESCE(monto_pagado, 0)
    -- mig 181: serializa el lote. Sin el lock, un cobro del chofer en la misma
    -- ventana quedaba tapado por el UPDATE de abajo.
    FOR UPDATE
  LOOP$a$;
  v_upd    CONSTANT text := $a$  UPDATE pedidos
     SET monto_pagado = total,
         forma_pago = p_forma_pago,
         updated_at = now()
   WHERE id = ANY(p_pedido_ids)
     AND sucursal_id = v_sucursal_id;$a$;
  v_upd_n  CONSTANT text := $a$  -- mig 181: ya NO se escribe monto_pagado = total. El trigger
  -- recalcular_monto_pagado_pedido lo deriva de SUM(pagos) tras el INSERT de
  -- arriba; fijarlo a mano tapaba un cobro concurrente y el pedido se veia
  -- saldado con dos pagos encima.
  UPDATE pedidos
     SET forma_pago = p_forma_pago,
         updated_at = now()
   WHERE id = ANY(p_pedido_ids)
     AND sucursal_id = v_sucursal_id
     AND COALESCE(estado, '') NOT IN ('cancelado', 'anulado');$a$;
  v_veces integer;
BEGIN
  v_def := pg_get_functiondef('public.marcar_pagos_masivo_impl(bigint[],text,date)'::regprocedure);
  IF position('mig 181' in v_def) > 0 THEN
    RAISE NOTICE 'mig 181 . marcar_pagos_masivo_impl ya parcheada, se omite';
    RETURN;
  END IF;
  FOR v_veces IN
    SELECT (length(v_def) - length(replace(v_def, a, ''))) / length(a)
      FROM unnest(ARRAY[v_loop, v_upd]) a
  LOOP
    IF v_veces <> 1 THEN
      RAISE EXCEPTION 'mig 181 . un ancla de marcar_pagos_masivo_impl aparece % veces (se esperaba 1). El cuerpo derivo.', v_veces;
    END IF;
  END LOOP;
  v_def := replace(v_def, v_loop, v_loop_n);
  v_def := replace(v_def, v_upd,  v_upd_n);
  EXECUTE v_def;
END;
$mig$;

-- -------------------------------------------------------------------------
-- 4 · marcar_entrega_y_pago_masivo_impl: mismo guard de estado
-- -------------------------------------------------------------------------
DO $mig$
DECLARE
  v_def    text;
  v_loop   CONSTANT text := $a$    FROM pedidos
    WHERE id = ANY(p_pedido_ids)
      AND sucursal_id = v_sucursal_id
      AND COALESCE(estado_pago, 'pendiente') <> 'pagado'
      AND total > COALESCE(monto_pagado, 0)
  LOOP$a$;
  v_loop_n CONSTANT text := $a$    FROM pedidos
    WHERE id = ANY(p_pedido_ids)
      AND sucursal_id = v_sucursal_id
      AND COALESCE(estado_pago, 'pendiente') <> 'pagado'
      AND COALESCE(estado, '') NOT IN ('cancelado', 'anulado')
      AND total > COALESCE(monto_pagado, 0)
    FOR UPDATE
  LOOP$a$;
  v_upd    CONSTANT text := $a$  UPDATE pedidos
     SET estado = 'entregado',$a$;
  v_upd_n  CONSTANT text := $a$  -- mig 181: no revivir un pedido cancelado como entregado y pagado.
  UPDATE pedidos
     SET estado = 'entregado',$a$;
  v_where  CONSTANT text := $a$   WHERE id = ANY(p_pedido_ids)
     AND sucursal_id = v_sucursal_id;$a$;
  v_where_n CONSTANT text := $a$   WHERE id = ANY(p_pedido_ids)
     AND sucursal_id = v_sucursal_id
     AND COALESCE(estado, '') NOT IN ('cancelado', 'anulado');$a$;
  v_veces integer;
BEGIN
  v_def := pg_get_functiondef('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)'::regprocedure);
  IF position('mig 181' in v_def) > 0 THEN
    RAISE NOTICE 'mig 181 . marcar_entrega_y_pago_masivo_impl ya parcheada, se omite';
    RETURN;
  END IF;
  FOR v_veces IN
    SELECT (length(v_def) - length(replace(v_def, a, ''))) / length(a)
      FROM unnest(ARRAY[v_loop, v_upd, v_where]) a
  LOOP
    IF v_veces <> 1 THEN
      RAISE EXCEPTION 'mig 181 . un ancla de marcar_entrega_y_pago_masivo_impl aparece % veces (se esperaba 1). El cuerpo derivo.', v_veces;
    END IF;
  END LOOP;
  v_def := replace(v_def, v_loop,  v_loop_n);
  v_def := replace(v_def, v_upd,   v_upd_n);
  v_def := replace(v_def, v_where, v_where_n);
  EXECUTE v_def;
END;
$mig$;

-- -------------------------------------------------------------------------
-- 5 · actualizar_pedido_items: cancelado y ya-ruteado
-- -------------------------------------------------------------------------
DO $mig$
DECLARE
  v_def   text;
  v_ancla CONSTANT text := $a$ARRAY['No se puede editar un pedido ya entregado']);
  END IF;$a$;
  v_nuevo CONSTANT text := $a$ARRAY['No se puede editar un pedido ya entregado']);
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
  END IF;$a$;
  v_veces integer;
BEGIN
  v_def := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure);
  IF position('mig 181' in v_def) > 0 THEN
    RAISE NOTICE 'mig 181 . actualizar_pedido_items ya parcheada, se omite';
    RETURN;
  END IF;
  v_veces := (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'mig 181 . el ancla de actualizar_pedido_items aparece % veces (se esperaba 1). El cuerpo derivo.', v_veces;
  END IF;
  EXECUTE replace(v_def, v_ancla, v_nuevo);
END;
$mig$;

-- -------------------------------------------------------------------------
-- 6 · Anular un pago no puede tocar una caja cerrada
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pagos_guard_anulacion_caja_cerrada()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $fn$
DECLARE
  v_limite date;
BEGIN
  -- Solo el borrado directo desde la app. `desafectar_sobrepago_pedido` corre
  -- como el dueño (SECURITY DEFINER) y queda exenta: es la que baja el pago
  -- cuando una salvedad reduce el total de una boleta ya cobrada, y bloquearla
  -- romperia la salvedad sobre cualquier boleta vieja. Por eso esta funcion NO
  -- es SECURITY DEFINER.
  IF current_user <> 'authenticated' THEN
    RETURN OLD;
  END IF;
  IF pg_trigger_depth() > 1 THEN
    RETURN OLD;
  END IF;

  IF OLD.sucursal_id IS NULL OR OLD.fecha IS NULL THEN
    RETURN OLD;
  END IF;

  v_limite := public.ultima_fecha_caja_cerrada(OLD.sucursal_id);

  IF v_limite IS NOT NULL AND OLD.fecha <= v_limite THEN
    RAISE EXCEPTION 'La caja de la sucursal esta cerrada hasta el % (rendicion controlada). No se puede anular un pago con fecha %. Reabri la rendicion de ese dia para hacer cambios.',
      to_char(v_limite, 'DD/MM/YYYY'), to_char(OLD.fecha, 'DD/MM/YYYY')
      USING ERRCODE = '42501';
  END IF;

  RETURN OLD;
END;
$fn$;

COMMENT ON FUNCTION public.pagos_guard_anulacion_caja_cerrada() IS
  'Impide anular un pago de una caja ya cerrada. Complementa a '
  'guard_pago_fecha_cerrada (mig 165), que solo cubre INSERT/UPDATE. NO debe ser '
  'SECURITY DEFINER: necesita el current_user real para eximir el borrado '
  'interno de desafectar_sobrepago_pedido (salvedad sobre boleta cobrada). Mig 181.';

DROP TRIGGER IF EXISTS trg_pagos_guard_anulacion ON public.pagos;
CREATE TRIGGER trg_pagos_guard_anulacion
  BEFORE DELETE ON public.pagos
  FOR EACH ROW
  EXECUTE FUNCTION public.pagos_guard_anulacion_caja_cerrada();

COMMIT;

-- -------------------------------------------------------------------------
-- Verificacion
--
--   -- El chofer ya no puede tocar la plata (con su sesion, desde la consola):
--   UPDATE pedidos SET total = 1 WHERE id = <uno suyo>;  -- 42501
--
--   -- Y si puede entregar:
--   UPDATE pedidos SET estado='entregado', fecha_entrega=now(), updated_at=now()
--    WHERE id = <parada suya>;                            -- OK
--
--   -- Un pedido cancelado ya no entra en una accion masiva ni se edita.
-- -------------------------------------------------------------------------
