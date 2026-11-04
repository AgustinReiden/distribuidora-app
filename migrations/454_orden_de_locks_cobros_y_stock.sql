-- 454 · Cobros, créditos y stock toman los locks en el orden global (#1439, #1424, #1440 punto 1).
--
-- QUÉ PASABA
--   El orden global es pedidos por id → recorridos por id → paradas → pagos por id (439, 441,
--   447, 449), con la rendición compartida antes de los pedidos en las masivas (443). Quedaban
--   caminos que lo invertían. Lo peor que daban era un 40P01: la transacción volvía atrás y
--   alguien veía un error, sin datos rotos.
--   · imputar_credito_a_pedido_impl tomaba el crédito y después la boleta; una edición de la
--     boleta la toma primero y llega a los créditos por pedidos_reconciliar_pagos. Lo mismo
--     actualizar_forma_pago_pago (el pago, y después el UPDATE de la boleta) y el DELETE REST
--     de un pago (el pago, y después la boleta en recalcular_monto_pagado_pedido) contra la
--     cancelación, que toma la boleta y después sus pagos.
--   · aplicar_credito_cliente tomaba los créditos por fecha y después las boletas, y los FIFO
--     las boletas por fecha. marcar_pagos_masivo_impl, sin ORDER BY ni los recorridos. Cada
--     pago llega a la ruta por el trigger de monto_pagado.
--   · eliminar_pedido_completo desimputaba los pagos por la FK (orden físico) y
--     anular_nota_credito_venta los tomaba sin orden: contra la foto de la rendición (por id).
--   · registrar_ingreso_sucursal y aceptar_movimiento_sucursal tomaban los productos de a uno
--     dentro del bucle (#1255 pide todos juntos y por id).
--   Medido en el arnés (scripts/concurrencia, clave t10): ver #1439.
--
-- QUÉ CAMBIA (el orden de los locks, y la fecha futura)
--   · Un pre-bloqueo por id antes de la primera sentencia que toma filas, como la 439 y la 447.
--     Los bucles siguen eligiendo en su orden de negocio (fecha, id) y vuelven a tomar lo que ya
--     está bloqueado.
--   · aplicar_credito_cliente, sólo si el cliente tiene créditos: las boletas que los créditos
--     alcanzan a pagar (las que el bucle iba a tomar) por id, sus recorridos por id y los créditos
--     por id. Con sólo los créditos, imputar un crédito a una boleta vieja se cruzaba con la
--     edición de otra del mismo cliente.
--   · El DELETE REST de un pago: un trigger BEFORE DELETE corre con la fila del pago ya
--     bloqueada, así que no puede tomar la boleta antes. Lo hace la policy mt_pagos_delete, que
--     se evalúa al recorrer la tabla, antes del lock de la fila: llama a
--     _pago_borrado_bloquea_pedido, que bloquea la boleta y devuelve true. Va SECURITY INVOKER
--     (el admin ya puede bloquear su boleta) y con COST alto, para que corra después de
--     es_admin() y de la sucursal. recalcular_monto_pagado_pedido no cambia, ni en los inserts.
--   · #1440 punto 1: los FIFO y las dos masivas de cobro rechazan un pago con fecha futura, como
--     registrar_pagos_pedido_impl. Antes lo dejaban pasar si cargaba un admin. Decisión del
--     dueño (04/11).
--
-- QUÉ NO CAMBIA
--   Qué se cobra, se imputa, se borra o se mueve, los mensajes, las firmas y los EXECUTE.
--   cancelar_pedido_con_stock no se toca: no se midió un ciclo (ver #1439). Tampoco la edición
--   que cambia el total, que toma el cliente antes que los créditos y las otras boletas (#1446).
--
-- Ensayo: scripts/test-orden-locks-1439.sql (corre en prod sin dejar rastro).
-- Se aplica en LF: las anclas de los parches tienen saltos de línea.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos son los que se leyeron de prod (04/11)
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, md5(p.prosrc) AS md5_vivo
      FROM (VALUES
        ('public.imputar_credito_a_pedido_impl(bigint,bigint,numeric)',                     '36e41f3925471bf701247b3df9f62e68'),
        ('public.actualizar_forma_pago_pago(bigint,text)',                                  '2385010f7ca30a930626826ca67b6c6c'),
        ('public.aplicar_credito_cliente(bigint,bigint)',                                   '7ce9aa2b32d4a892217b9e7ed0fd4647'),
        ('public.registrar_pago_cliente_fifo_impl(bigint,numeric,text,date,text,text)',     'a84e709ed987d379940203e2d5eba713'),
        ('public.registrar_pago_combinado_cliente_fifo_impl(bigint,jsonb,date,text,text)',  '9b56240f13a2eef40f9d5f92f45e49d4'),
        ('public.marcar_pagos_masivo_impl(bigint[],text,date)',                             '016ec74e88272ba5bd18a3af98cb740f'),
        ('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)',               '3467c13d5f725090ae7542921548f47e'),
        ('public.eliminar_pedido_completo(bigint,uuid,text,boolean)',                       'ba104e016ae2d62b08ae80f9ddfe69b4'),
        ('public.anular_nota_credito_venta(bigint,text)',                                   '7c339abc4762f464eb57a9ed345f8bc3'),
        ('public.registrar_ingreso_sucursal(bigint,date,text,numeric,uuid,jsonb)',          'f1e249c76ebb5956b6a4e7efaf16ad4a'),
        ('public.aceptar_movimiento_sucursal(bigint,jsonb)',                                '27ad1372d3c7a2b0378af518c567d0bd')
      ) AS x(firma, md5)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION 'mig 454 · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;

  IF (SELECT pg_get_expr(polqual, polrelid) FROM pg_policy
       WHERE polrelid = 'public.pagos'::regclass AND polname = 'mt_pagos_delete')
     IS DISTINCT FROM '(es_admin() AND (sucursal_id = current_sucursal_id()))' THEN
    RAISE EXCEPTION 'mig 454 · la policy mt_pagos_delete cambió en prod desde que se leyó';
  END IF;
  IF to_regprocedure('public._pago_borrado_bloquea_pedido(bigint)') IS NOT NULL THEN
    RAISE EXCEPTION 'mig 454 · _pago_borrado_bloquea_pedido ya existe';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- Parches por ancla
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _nnn_parche (firma text, orden int, ancla text, reemplazo text, veces int DEFAULT 1) ON COMMIT DROP;

INSERT INTO _nnn_parche (firma, orden, ancla, reemplazo) VALUES
-- 1 · imputar_credito_a_pedido_impl: la boleta antes que el crédito ----------
('public.imputar_credito_a_pedido_impl(bigint,bigint,numeric)', 1,
$a$  -- Lock: primero el pago, despues el pedido (mismo orden que el cobro FIFO,
  -- donde aplicar_credito_cliente toca pagos antes del FOR UPDATE de pedidos).
  SELECT id, cliente_id, pedido_id, monto, forma_pago, fecha, nota_credito_id
$a$,
$r$  -- #1439: la boleta antes que el credito, el orden global (pedidos, rutas,
  -- pagos) de la cancelacion, del recorte y de aplicar_credito_cliente. Al reves
  -- se cruzaba con una edicion de la boleta, que la toma primero y llega a los
  -- creditos por pedidos_reconciliar_pagos. Si no existe, lo dice el SELECT de
  -- mas abajo.
  PERFORM 1 FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal_id FOR UPDATE;

  SELECT id, cliente_id, pedido_id, monto, forma_pago, fecha, nota_credito_id
$r$),

-- 2 · actualizar_forma_pago_pago: la boleta antes que el pago ---------------
('public.actualizar_forma_pago_pago(bigint,text)', 1,
$a$  SELECT id, pedido_id, fecha, forma_pago
    INTO v_pago
$a$,
$r$  -- #1439: la boleta antes que el pago, como el cobro y la cancelacion. El
  -- UPDATE de pedidos de abajo la tomaba con el pago ya bloqueado. Se lee sin
  -- lock; si el pago cambia de boleta en el medio, el UPDATE toma la nueva.
  PERFORM 1
     FROM pedidos
    WHERE id = (SELECT pedido_id FROM pagos WHERE id = p_pago_id AND sucursal_id = v_sucursal_id)
      AND sucursal_id = v_sucursal_id
      FOR UPDATE;

  SELECT id, pedido_id, fecha, forma_pago
    INTO v_pago
$r$),

-- 3 · aplicar_credito_cliente: boletas, rutas y créditos por id --------------
('public.aplicar_credito_cliente(bigint,bigint)', 1,
$a$  v_excluir   bigint;
BEGIN
$a$,
$r$  v_excluir   bigint;
  v_alcanza   bigint[];
BEGIN
$r$),
('public.aplicar_credito_cliente(bigint,bigint)', 2,
$a$  PERFORM set_config('app.reimputacion_pagos', 'on', true);

  FOR v_credito IN
$a$,
$r$  PERFORM set_config('app.reimputacion_pagos', 'on', true);

  -- #1424/#1439: el orden global antes del primer lock, si hay creditos. Las
  -- boletas que los creditos alcanzan a pagar en el orden del bucle (fecha, id),
  -- por id; sus recorridos por id (cada reimputacion llega a la ruta por el
  -- trigger de monto_pagado), y los creditos por id, como la foto de la
  -- rendicion. Son las filas que el bucle iba a tomar: sigue eligiendo por fecha
  -- y las vuelve a tomar ya bloqueadas. Si llega mas lejos (el credito de una NC
  -- no va a su boleta), toma esa en su orden, como antes. Antes tomaba los
  -- creditos y despues las boletas, al reves que imputar_credito_a_pedido.
  IF EXISTS (SELECT 1 FROM pagos
              WHERE cliente_id = p_cliente_id
                AND sucursal_id = p_sucursal_id
                AND pedido_id IS NULL) THEN
    v_alcanza := ARRAY(
      SELECT b.id
        FROM (SELECT p.id,
                     sum(p.total - COALESCE(p.monto_pagado, 0)) OVER (ORDER BY p.fecha, p.id)
                       - (p.total - COALESCE(p.monto_pagado, 0)) AS antes
                FROM pedidos p
               WHERE p.cliente_id = p_cliente_id
                 AND p.sucursal_id = p_sucursal_id
                 AND p.estado NOT IN ('cancelado', 'anulado')
                 AND p.total > COALESCE(p.monto_pagado, 0)) b
       WHERE b.antes < (SELECT sum(monto) FROM pagos
                         WHERE cliente_id = p_cliente_id
                           AND sucursal_id = p_sucursal_id
                           AND pedido_id IS NULL));

    PERFORM 1
       FROM pedidos
      WHERE id = ANY(v_alcanza)
      ORDER BY id
        FOR UPDATE;

    PERFORM 1
       FROM recorridos
      WHERE id IN (SELECT rp.recorrido_id
                     FROM recorrido_pedidos rp
                    WHERE rp.pedido_id = ANY(v_alcanza))
      ORDER BY id
        FOR NO KEY UPDATE;

    PERFORM 1
       FROM pagos
      WHERE cliente_id = p_cliente_id
        AND sucursal_id = p_sucursal_id
        AND pedido_id IS NULL
      ORDER BY id
        FOR UPDATE;
  END IF;

  FOR v_credito IN
$r$),

-- 4 · registrar_pago_cliente_fifo_impl: fecha futura y el orden global -------
('public.registrar_pago_cliente_fifo_impl(bigint,numeric,text,date,text,text)', 1,
$a$  IF v_rol = 'encargado' THEN
$a$,
$r$  -- #1440: la fecha nunca es futura, como en registrar_pagos_pedido_impl.
  IF p_fecha > public._tablero_hoy() THEN
    RAISE EXCEPTION 'La fecha del pago (%) no puede ser futura', to_char(p_fecha, 'DD/MM/YYYY')
      USING ERRCODE = '22023';
  END IF;

  IF v_rol = 'encargado' THEN
$r$),
('public.registrar_pago_cliente_fifo_impl(bigint,numeric,text,date,text,text)', 2,
$a$  v_credito_aplicado := public.aplicar_credito_cliente(p_cliente_id, v_sucursal_id);
$a$,
$r$  -- #1439: el orden global (pedidos por id, recorridos por id, pagos) antes del
  -- primer lock: el credito y el bucle toman las boletas por fecha, y cada pago
  -- llega a la ruta por el trigger de monto_pagado. Son las boletas que los dos
  -- pueden tocar; las vuelven a tomar en su orden, ya bloqueadas.
  PERFORM 1
     FROM pedidos
    WHERE cliente_id = p_cliente_id
      AND sucursal_id = v_sucursal_id
      AND COALESCE(estado, '') NOT IN ('cancelado', 'anulado')
      AND total > COALESCE(monto_pagado, 0)
    ORDER BY id
      FOR UPDATE;

  PERFORM 1
     FROM recorridos
    WHERE id IN (SELECT rp.recorrido_id
                   FROM recorrido_pedidos rp
                   JOIN pedidos p ON p.id = rp.pedido_id
                  WHERE p.cliente_id = p_cliente_id
                    AND p.sucursal_id = v_sucursal_id
                    AND COALESCE(p.estado, '') NOT IN ('cancelado', 'anulado')
                    AND p.total > COALESCE(p.monto_pagado, 0))
    ORDER BY id
      FOR NO KEY UPDATE;

  v_credito_aplicado := public.aplicar_credito_cliente(p_cliente_id, v_sucursal_id);
$r$),

-- 5 · registrar_pago_combinado_cliente_fifo_impl: lo mismo ------------------
('public.registrar_pago_combinado_cliente_fifo_impl(bigint,jsonb,date,text,text)', 1,
$a$  IF v_rol = 'encargado' THEN
$a$,
$r$  -- #1440: la fecha nunca es futura, como en registrar_pagos_pedido_impl.
  IF p_fecha > public._tablero_hoy() THEN
    RAISE EXCEPTION 'La fecha del pago (%) no puede ser futura', to_char(p_fecha, 'DD/MM/YYYY')
      USING ERRCODE = '22023';
  END IF;

  IF v_rol = 'encargado' THEN
$r$),
('public.registrar_pago_combinado_cliente_fifo_impl(bigint,jsonb,date,text,text)', 2,
$a$  v_credito_aplicado := public.aplicar_credito_cliente(p_cliente_id, v_sucursal_id);
$a$,
$r$  -- #1439: el orden global antes del primer lock, como en
  -- registrar_pago_cliente_fifo_impl.
  PERFORM 1
     FROM pedidos
    WHERE cliente_id = p_cliente_id
      AND sucursal_id = v_sucursal_id
      AND COALESCE(estado, '') NOT IN ('cancelado', 'anulado')
      AND total > COALESCE(monto_pagado, 0)
    ORDER BY id
      FOR UPDATE;

  PERFORM 1
     FROM recorridos
    WHERE id IN (SELECT rp.recorrido_id
                   FROM recorrido_pedidos rp
                   JOIN pedidos p ON p.id = rp.pedido_id
                  WHERE p.cliente_id = p_cliente_id
                    AND p.sucursal_id = v_sucursal_id
                    AND COALESCE(p.estado, '') NOT IN ('cancelado', 'anulado')
                    AND p.total > COALESCE(p.monto_pagado, 0))
    ORDER BY id
      FOR NO KEY UPDATE;

  v_credito_aplicado := public.aplicar_credito_cliente(p_cliente_id, v_sucursal_id);
$r$),

-- 6 · marcar_pagos_masivo_impl: fecha futura y el orden de la 439 -------------
('public.marcar_pagos_masivo_impl(bigint[],text,date)', 1,
$a$  IF v_rol = 'encargado' THEN
$a$,
$r$  -- #1440: la fecha nunca es futura, como en registrar_pagos_pedido_impl.
  IF p_fecha > public._tablero_hoy() THEN
    RAISE EXCEPTION 'La fecha del pago (%) no puede ser futura', to_char(p_fecha, 'DD/MM/YYYY')
      USING ERRCODE = '22023';
  END IF;

  IF v_rol = 'encargado' THEN
$r$),
('public.marcar_pagos_masivo_impl(bigint[],text,date)', 2,
$a$  FOR v_pedido IN
    SELECT id, cliente_id, total, COALESCE(monto_pagado, 0) AS ya_pagado
    FROM pedidos
$a$,
$r$  -- #1439: el orden de la 439 (marcar_entrega_y_pago_masivo_impl), pedidos por
  -- id y despues recorridos por id, antes del primer pago: cada INSERT llega a la
  -- ruta por el trigger de monto_pagado. No entrega, asi que no toma rendiciones.
  PERFORM 1
     FROM pedidos
    WHERE id = ANY(p_pedido_ids)
      AND sucursal_id = v_sucursal_id
    ORDER BY id
      FOR UPDATE;

  PERFORM 1
     FROM recorridos
    WHERE id IN (SELECT rp.recorrido_id
                   FROM recorrido_pedidos rp
                  WHERE rp.pedido_id = ANY(p_pedido_ids))
    ORDER BY id
      FOR NO KEY UPDATE;

  FOR v_pedido IN
    SELECT id, cliente_id, total, COALESCE(monto_pagado, 0) AS ya_pagado
    FROM pedidos
$r$),
('public.marcar_pagos_masivo_impl(bigint[],text,date)', 3,
$a$    -- ventana quedaba tapado por el UPDATE de abajo.
    FOR UPDATE
$a$,
$r$    -- ventana quedaba tapado por el UPDATE de abajo.
    ORDER BY id
    FOR UPDATE
$r$),

-- 7 · marcar_entrega_y_pago_masivo_impl: sólo la fecha futura ---------------
('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)', 1,
$a$  IF v_rol = 'encargado' THEN
$a$,
$r$  -- #1440: la fecha nunca es futura, como en registrar_pagos_pedido_impl.
  IF p_fecha > public._tablero_hoy() THEN
    RAISE EXCEPTION 'La fecha del pago (%) no puede ser futura', to_char(p_fecha, 'DD/MM/YYYY')
      USING ERRCODE = '22023';
  END IF;

  IF v_rol = 'encargado' THEN
$r$),

-- 8 · eliminar_pedido_completo: los pagos por id antes del DELETE ------------
('public.eliminar_pedido_completo(bigint,uuid,text,boolean)', 1,
$a$  DELETE FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal;
$a$,
$r$  -- #1424: la FK pagos_pedido_id_fkey (ON DELETE SET NULL) desimputa los pagos
  -- en el orden de idx_pagos_pedido_id, que para la misma boleta es el fisico.
  -- Se toman antes por id, como la foto de la rendicion y la cancelacion (447).
  PERFORM 1
     FROM pagos
    WHERE pedido_id = p_pedido_id
      AND sucursal_id = v_sucursal
    ORDER BY id
      FOR NO KEY UPDATE;

  DELETE FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal;
$r$),

-- 9 · anular_nota_credito_venta: los pedazos por id --------------------------
('public.anular_nota_credito_venta(bigint,text)', 1,
$a$  PERFORM 1 FROM pagos WHERE nota_credito_id = p_nota_credito_id FOR UPDATE;
$a$,
$r$  -- #1424: por id, como la foto de la rendicion.
  PERFORM 1 FROM pagos WHERE nota_credito_id = p_nota_credito_id ORDER BY id FOR UPDATE;
$r$),

-- 10 · registrar_ingreso_sucursal: los productos juntos y por id -------------
('public.registrar_ingreso_sucursal(bigint,date,text,numeric,uuid,jsonb)', 1,
$a$  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
$a$,
$r$  -- #1255/#1439: los productos juntos y por id, antes del bucle, que los toma
  -- en el orden del JSON.
  PERFORM 1
     FROM productos
    WHERE sucursal_id = v_tenant
      AND id IN (SELECT (e->>'producto_id')::bigint FROM jsonb_array_elements(p_items) e)
    ORDER BY id
      FOR UPDATE;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
$r$),

-- 11 · aceptar_movimiento_sucursal: los productos de los dos lados por id ----
('public.aceptar_movimiento_sucursal(bigint,jsonb)', 1,
$a$  FOR v_item IN SELECT * FROM movimiento_sucursal_items WHERE movimiento_id = p_movimiento_id ORDER BY producto_origen_id LOOP
$a$,
$r$  -- #1255/#1439: los productos de los dos lados juntos y por id, antes del
  -- bucle, que toma el de origen y el de destino de cada item de a uno.
  PERFORM 1
     FROM productos
    WHERE (NOT v_mov.stock_descontado
           AND sucursal_id = v_mov.sucursal_origen_id
           AND id IN (SELECT producto_origen_id FROM movimiento_sucursal_items WHERE movimiento_id = p_movimiento_id))
       OR (sucursal_id = v_destino
           AND id IN (SELECT (r->>'producto_destino_id')::bigint
                        FROM jsonb_array_elements(p_resoluciones) r
                       WHERE r->>'accion' IS DISTINCT FROM 'crear_nuevo'))
    ORDER BY id
      FOR UPDATE;

  FOR v_item IN SELECT * FROM movimiento_sucursal_items WHERE movimiento_id = p_movimiento_id ORDER BY producto_origen_id LOOP
$r$);

DO $parches$
DECLARE
  v_f   record;
  v_p   record;
  v_def text;
  v_n   int;
BEGIN
  FOR v_f IN SELECT DISTINCT firma FROM _nnn_parche ORDER BY firma LOOP
    v_def := pg_get_functiondef(v_f.firma::regprocedure);
    FOR v_p IN SELECT * FROM _nnn_parche WHERE firma = v_f.firma ORDER BY orden LOOP
      v_n := (length(v_def) - length(replace(v_def, v_p.ancla, ''))) / length(v_p.ancla);
      IF v_n <> v_p.veces THEN
        RAISE EXCEPTION 'mig 454 · % parche %: el ancla aparece % vez/veces y se esperaba %',
          v_f.firma, v_p.orden, v_n, v_p.veces;
      END IF;
      v_def := replace(v_def, v_p.ancla, v_p.reemplazo);
    END LOOP;
    EXECUTE v_def;
  END LOOP;
END
$parches$;

-- ---------------------------------------------------------------------------
-- 12 · El DELETE REST de un pago toma la boleta antes que el pago
-- ---------------------------------------------------------------------------
CREATE FUNCTION public._pago_borrado_bloquea_pedido(p_pedido_id bigint)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
COST 10000
SET search_path TO 'public'
AS $$
BEGIN
  -- #1439: la llama la policy mt_pagos_delete, que se evalua al recorrer pagos,
  -- antes de que el DELETE bloquee la fila. Un trigger BEFORE DELETE ya corre con
  -- el pago bloqueado, y recalcular_monto_pagado_pedido pedia la boleta despues:
  -- al reves que la cancelacion, que toma la boleta y despues sus pagos. INVOKER:
  -- el admin ya puede bloquear su boleta (mt_pedidos_update). El COST la deja
  -- despues de es_admin() y de la sucursal. Siempre devuelve true.
  IF p_pedido_id IS NOT NULL THEN
    PERFORM 1 FROM pedidos WHERE id = p_pedido_id FOR UPDATE;
  END IF;
  RETURN true;
END
$$;

REVOKE ALL ON FUNCTION public._pago_borrado_bloquea_pedido(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._pago_borrado_bloquea_pedido(bigint) TO authenticated, service_role;

ALTER POLICY mt_pagos_delete ON public.pagos
  USING (es_admin() AND sucursal_id = current_sucursal_id() AND public._pago_borrado_bloquea_pedido(pedido_id));

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos son los del repo, y los EXECUTE como estaban
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, x.acl, md5(p.prosrc) AS md5_vivo, p.proacl::text AS acl_viva
      FROM (VALUES
        ('public.imputar_credito_a_pedido_impl(bigint,bigint,numeric)',                    '8f5768b8269401dee69e05ab6c9622bd',   '{postgres=X/postgres,service_role=X/postgres}'),
        ('public.actualizar_forma_pago_pago(bigint,text)',                                 '635b6cb520d332bd543fec2043414500',     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public.aplicar_credito_cliente(bigint,bigint)',                                  'c56c4200f0ca10c4920629e8e552f21f',   '{postgres=X/postgres,service_role=X/postgres}'),
        ('public.registrar_pago_cliente_fifo_impl(bigint,numeric,text,date,text,text)',    '1d8f2a4a23c249bdbc5ad21b6ca06f7a',      '{postgres=X/postgres,service_role=X/postgres}'),
        ('public.registrar_pago_combinado_cliente_fifo_impl(bigint,jsonb,date,text,text)', 'e7036637cb189259839094415247ae1f', '{postgres=X/postgres,service_role=X/postgres}'),
        ('public.marcar_pagos_masivo_impl(bigint[],text,date)',                            '7dfde9f7b5f42e8bb1214e3649e28e09',    '{postgres=X/postgres,service_role=X/postgres}'),
        ('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)',              '9a32b73da6395bb29075c00d8c3b5469',   '{postgres=X/postgres,service_role=X/postgres}'),
        ('public.eliminar_pedido_completo(bigint,uuid,text,boolean)',                      '1ece000e6c6adcd5c863531a2ec5f31b',  '{postgres=X/postgres,service_role=X/postgres}'),
        ('public.anular_nota_credito_venta(bigint,text)',                                  'dc8a13efc7f6ce3f53a25a832c3165e3',    '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public.registrar_ingreso_sucursal(bigint,date,text,numeric,uuid,jsonb)',         'f49054b3fe4297f86a09394c3ccb43e4',   '{postgres=X/postgres,service_role=X/postgres}'),
        ('public.aceptar_movimiento_sucursal(bigint,jsonb)',                               '0221bbc3dc860f6f9aedc4e1aeac3d92',   '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public._pago_borrado_bloquea_pedido(bigint)',                                    '2dc240f5c332d5616a93454fed2d3f77',   '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}')
      ) AS x(firma, md5, acl)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF v_f.md5_vivo <> v_f.md5 OR v_f.acl_viva <> v_f.acl THEN
      RAISE EXCEPTION 'mig 454 · % no quedó como en el repo (md5 %, acl %)', v_f.firma, v_f.md5_vivo, v_f.acl_viva;
    END IF;
  END LOOP;

  IF (SELECT pg_get_expr(polqual, polrelid) FROM pg_policy
       WHERE polrelid = 'public.pagos'::regclass AND polname = 'mt_pagos_delete')
     IS DISTINCT FROM '(es_admin() AND (sucursal_id = current_sucursal_id()) AND _pago_borrado_bloquea_pedido((pedido_id)::bigint))' THEN
    RAISE EXCEPTION 'mig 454 · la policy mt_pagos_delete no quedó como en el repo';
  END IF;
END
$post$;

COMMIT;
