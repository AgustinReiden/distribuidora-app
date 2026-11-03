-- Ensayo de la migración de los contadores del recorrido (#1397).
--
-- El lost update lo mide el arnés (scripts/concurrencia, C7h), porque hacen falta dos sesiones.
-- Acá se prueba en una sola sesión que el trigger sigue marcando y contando lo mismo:
-- R pasa igual con y sin la migración, y sólo L falla sin ella.
--
--   R1 · Entregar un pedido de la ruta: su parada queda entregada y la ruta cuenta 2 / 1.
--   R2 · Cobrar el entregado: total_cobrado lo suma; cobrar uno sin entregar no suma.
--   R3 · Bajar el total de una parada viva mueve total_facturado.
--   R4 · Un pedido con paradas en dos rutas (pasó de la de B a la de A): las dos quedan
--        con los contadores de _recorrido_contadores.
--   L1 · El cuerpo bloquea las rutas en su propia sentencia antes de recalcularlas.
--
-- Corre contra prod sin dejar rastro (salvo valores de secuencia): un único DO que termina
-- siempre en una excepción, y cada caso en un sub-bloque que se revierte. Antes de aplicar la
-- migración se corre pegado detrás de su cuerpo, sin el BEGIN y el COMMIT; después, solo.
-- Solo y sin la migración tiene que dar 'ENSAYO FALLÓ', únicamente por L1.
--
-- Fixtures: una sucursal activa con un admin y dos transportistas base activos. El resto nace
-- en el ensayo. Las rutas y los pagos van en 2099.

CREATE OR REPLACE FUNCTION pg_temp.t_cliente(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (p_nombre, p_nombre, 'Ensayo 1397', p_suc)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_pedido(p_cli bigint, p_admin uuid, p_prod bigint, p_cant int)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.crear_pedido_completo(
    p_cli, p_cant * 100, p_admin,
    jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 100)),
    'ensayo 1397');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_ruta(p_tr uuid, p_fecha date, VARIADIC p_peds bigint[])
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT public.aplicar_orden_ruta(
    p_tr,
    (SELECT jsonb_agg(jsonb_build_object('pedido_id', x, 'orden_entrega', o) ORDER BY o)
       FROM unnest(p_peds) WITH ORDINALITY AS t(x, o)),
    NULL, NULL, NULL, p_fecha);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_entregar(p_ped bigint, p_tr uuid, p_fecha date)
RETURNS void LANGUAGE sql AS $fn$
  UPDATE public.pedidos
     SET estado = 'entregado',
         fecha_entrega = (p_fecha::text || ' 12:00:00 America/Argentina/Buenos_Aires')::timestamptz,
         transportista_id = p_tr
   WHERE id = p_ped;
$fn$;

-- Los contadores guardados, y si difieren de los que da _recorrido_contadores hoy.
CREATE OR REPLACE FUNCTION pg_temp.t_cuenta(p_rec bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT format('%s/%s/%s/%s', r.total_pedidos, r.pedidos_entregados,
                r.total_facturado::bigint, r.total_cobrado::bigint)
         || CASE WHEN (r.total_pedidos, r.pedidos_entregados, r.total_facturado, r.total_cobrado)
                      IS DISTINCT FROM (c.total_pedidos, c.pedidos_entregados, c.total_facturado, c.total_cobrado)
                 THEN ' (desfasado)' ELSE '' END
    FROM public.recorridos r, public._recorrido_contadores(p_rec) c
   WHERE r.id = p_rec;
$fn$;

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_a      uuid;
  v_b      uuid;
  v_adm    uuid;
  v_prod   bigint;
  v_c1     bigint;
  v_c2     bigint;
  v_p1     bigint;
  v_p2     bigint;
  v_r1     bigint;
  v_r2     bigint;
  v_txt    text;
  v_fallas text[] := '{}';
  F CONSTANT date := DATE '2099-04-10';
BEGIN
  SELECT s.id, a.usuario_id, b.usuario_id, adm.usuario_id
    INTO v_suc, v_a, v_b, v_adm
    FROM sucursales s
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'transportista'
                   ORDER BY us.usuario_id LIMIT 1) a ON true
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'transportista'
                     AND pf.id <> a.usuario_id
                   ORDER BY us.usuario_id LIMIT 1) b ON true
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'admin'
                   ORDER BY us.usuario_id LIMIT 1) adm ON true
   WHERE s.activa
   ORDER BY s.id
   LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: ninguna sucursal activa con un admin y dos transportistas';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1397', 100, 1000, 60, v_suc)
  RETURNING id INTO v_prod;
  v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1397 uno');
  v_c2 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1397 dos');
  v_p1 := pg_temp.t_pedido(v_c1, v_adm, v_prod, 1);
  v_p2 := pg_temp.t_pedido(v_c2, v_adm, v_prod, 2);

  -- R1 a R3 · una ruta: entrega, cobro y baja de total
  BEGIN
    v_r1 := pg_temp.t_ruta(v_a, F, v_p1, v_p2);
    v_txt := pg_temp.t_cuenta(v_r1);
    IF v_txt IS DISTINCT FROM '2/0/300/0' THEN
      v_fallas := v_fallas || format('R1 la ruta nueva cuenta %s', v_txt);
    END IF;

    PERFORM pg_temp.t_entregar(v_p1, v_a, F);
    v_txt := pg_temp.t_cuenta(v_r1);
    IF v_txt IS DISTINCT FROM '2/1/300/0' THEN
      v_fallas := v_fallas || format('R1 tras entregar cuenta %s', v_txt);
    END IF;
    IF (SELECT estado_entrega FROM recorrido_pedidos WHERE recorrido_id = v_r1 AND pedido_id = v_p1)
       IS DISTINCT FROM 'entregado' THEN
      v_fallas := v_fallas || 'R1 la parada no quedó entregada'::text;
    END IF;

    INSERT INTO pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha)
    VALUES (v_c1, v_p1, v_suc, 100, 'efectivo', F);
    INSERT INTO pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha)
    VALUES (v_c2, v_p2, v_suc, 50, 'efectivo', F);
    v_txt := pg_temp.t_cuenta(v_r1);
    IF v_txt IS DISTINCT FROM '2/1/300/100' THEN
      v_fallas := v_fallas || format('R2 tras cobrar cuenta %s', v_txt);
    END IF;

    UPDATE pedidos SET total = 150 WHERE id = v_p2;
    v_txt := pg_temp.t_cuenta(v_r1);
    IF v_txt IS DISTINCT FROM '2/1/250/100' THEN
      v_fallas := v_fallas || format('R3 tras bajar el total cuenta %s', v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ397';
  EXCEPTION
    WHEN SQLSTATE 'ZZ397' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R1-R3 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- R4 · el pedido pasa de la ruta de B a la de A y se entrega
  BEGIN
    v_r2 := pg_temp.t_ruta(v_b, F, v_p2);
    v_r1 := pg_temp.t_ruta(v_a, F, v_p1, v_p2);
    PERFORM pg_temp.t_entregar(v_p2, v_a, F);
    v_txt := pg_temp.t_cuenta(v_r1);
    IF v_txt IS DISTINCT FROM '2/1/300/0' THEN
      v_fallas := v_fallas || format('R4 la ruta de A cuenta %s', v_txt);
    END IF;
    v_txt := pg_temp.t_cuenta(v_r2);
    IF v_txt IS DISTINCT FROM '0/0/0/0' THEN
      v_fallas := v_fallas || format('R4 la ruta de B cuenta %s', v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ397';
  EXCEPTION
    WHEN SQLSTATE 'ZZ397' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R4 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- R5 · recalcular_recorrido realinea una parada que no se enteró y deja los contadores
  BEGIN
    v_r1 := pg_temp.t_ruta(v_a, F, v_p1, v_p2);
    PERFORM pg_temp.t_entregar(v_p1, v_a, F);
    UPDATE recorrido_pedidos SET estado_entrega = 'pendiente', hora_entrega = NULL
     WHERE recorrido_id = v_r1 AND pedido_id = v_p1;
    UPDATE recorridos SET pedidos_entregados = 0 WHERE id = v_r1;
    v_txt := (public.recalcular_recorrido(v_r1))->>'paradas_realineadas';
    IF v_txt IS DISTINCT FROM '1' THEN
      v_fallas := v_fallas || format('R5 realineó %s paradas', v_txt);
    END IF;
    v_txt := pg_temp.t_cuenta(v_r1);
    IF v_txt IS DISTINCT FROM '2/1/300/0' THEN
      v_fallas := v_fallas || format('R5 tras recalcular cuenta %s', v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ397';
  EXCEPTION
    WHEN SQLSTATE 'ZZ397' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R5 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- L1 · los cuerpos
  v_txt := (SELECT prosrc FROM pg_proc WHERE oid = 'public.actualizar_recorrido_entrega()'::regprocedure);
  IF position('FOR NO KEY UPDATE' IN v_txt) = 0
     OR position('FOR NO KEY UPDATE' IN v_txt) > position('UPDATE recorridos r' IN v_txt) THEN
    v_fallas := v_fallas || 'L1 actualizar_recorrido_entrega no bloquea las rutas antes de recalcular'::text;
  END IF;
  -- recalcular_recorrido: el lock va después de las paradas (a y b) y antes de los contadores (c).
  v_txt := (SELECT prosrc FROM pg_proc WHERE oid = 'public.recalcular_recorrido(bigint)'::regprocedure);
  IF position('FOR NO KEY UPDATE' IN v_txt) = 0
     OR position('FOR NO KEY UPDATE' IN v_txt) > position('UPDATE recorridos r' IN v_txt)
     OR position('FOR NO KEY UPDATE' IN v_txt) < position('GET DIAGNOSTICS v_revertidas' IN v_txt) THEN
    v_fallas := v_fallas || 'L1 recalcular_recorrido no bloquea la ruta entre las paradas y los contadores'::text;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · R1 R2 R3 R4 R5 L1';
END
$ensayo$;
