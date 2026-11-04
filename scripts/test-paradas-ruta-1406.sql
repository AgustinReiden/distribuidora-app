-- Ensayo de la migración que toca las paradas después de la ruta (#1406).
--
-- El 40P01 lo mide el arnés (scripts/concurrencia: C7k2, C7j2 y C7l), porque hacen falta dos
-- sesiones. Acá se prueba en una sola sesión que las tres funciones siguen haciendo lo mismo
-- (R pasa igual con y sin la migración) y que el lock de rutas quedó antes de la primera
-- parada (sólo L falla sin ella).
--
--   R1 · Entregar un pedido de la ruta: su parada queda entregada y la ruta cuenta 2/1.
--   R2 · Revertir esa entrega: la parada vuelve a pendiente y la ruta cuenta 2/0.
--   R3 · recalcular_recorrido, paso a: pedido entregado con la parada pendiente. La realinea
--        y cuenta 2/1.
--   R4 · recalcular_recorrido, paso b: parada entregada con el pedido sin entregar. La vuelve
--        a pendiente y cuenta 2/0.
--   R5 · quitar_pedido_de_recorridos_activos borra la parada en curso y la ruta cuenta 1/0.
--   R6 · cancelar_pedido_con_stock de un pedido en ruta: sale de la ruta por quitar y la ruta
--        cuenta 1/0.
--   L1 · Los cuerpos: cada uno bloquea las rutas antes de su primera escritura de paradas.
--
-- Corre contra prod sin dejar rastro (salvo valores de secuencia): un único DO que termina
-- siempre en una excepción, y cada caso en un sub-bloque que se revierte. Antes de aplicar la
-- migración se corre pegado detrás de su cuerpo, sin el BEGIN y el COMMIT; después, solo.
-- Solo y sin la migración tiene que dar 'ENSAYO FALLÓ', únicamente por L1.
--
-- Fixtures: una sucursal activa con un admin y un transportista base activos. El resto nace
-- en el ensayo. Las rutas van en 2099.

CREATE OR REPLACE FUNCTION pg_temp.t_cliente(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (p_nombre, p_nombre, 'Ensayo 1406', p_suc)
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
    'ensayo 1406');
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
  SELECT format('%s/%s', r.total_pedidos, r.pedidos_entregados)
         || CASE WHEN (r.total_pedidos, r.pedidos_entregados, r.total_facturado, r.total_cobrado)
                      IS DISTINCT FROM (c.total_pedidos, c.pedidos_entregados, c.total_facturado, c.total_cobrado)
                 THEN ' (desfasado)' ELSE '' END
    FROM public.recorridos r, public._recorrido_contadores(p_rec) c
   WHERE r.id = p_rec;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_parada(p_rec bigint, p_ped bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT COALESCE((SELECT estado_entrega FROM public.recorrido_pedidos
                    WHERE recorrido_id = p_rec AND pedido_id = p_ped), '(sin parada)');
$fn$;

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_tr     uuid;
  v_adm    uuid;
  v_prod   bigint;
  v_p1     bigint;
  v_p2     bigint;
  v_r      bigint;
  v_j      jsonb;
  v_txt    text;
  v_lock   int;
  v_fallas text[] := '{}';
  F CONSTANT date := DATE '2099-04-11';
BEGIN
  SELECT s.id, a.usuario_id, adm.usuario_id
    INTO v_suc, v_tr, v_adm
    FROM sucursales s
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'transportista'
                   ORDER BY us.usuario_id LIMIT 1) a ON true
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'admin'
                   ORDER BY us.usuario_id LIMIT 1) adm ON true
   WHERE s.activa
   ORDER BY s.id
   LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: ninguna sucursal activa con un admin y un transportista';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1406', 100, 1000, 60, v_suc)
  RETURNING id INTO v_prod;
  v_p1 := pg_temp.t_pedido(pg_temp.t_cliente(v_suc, 'ZZ ensayo 1406 uno'), v_adm, v_prod, 1);
  v_p2 := pg_temp.t_pedido(pg_temp.t_cliente(v_suc, 'ZZ ensayo 1406 dos'), v_adm, v_prod, 2);

  -- R1 y R2 · el trigger de la entrega: marcar y revertir la parada
  BEGIN
    v_r := pg_temp.t_ruta(v_tr, F, v_p1, v_p2);
    PERFORM pg_temp.t_entregar(v_p1, v_tr, F);
    IF pg_temp.t_parada(v_r, v_p1) IS DISTINCT FROM 'entregado' OR pg_temp.t_cuenta(v_r) IS DISTINCT FROM '2/1' THEN
      v_fallas := v_fallas || format('R1 tras entregar: parada %s, ruta %s', pg_temp.t_parada(v_r, v_p1), pg_temp.t_cuenta(v_r));
    END IF;

    UPDATE pedidos SET estado = 'asignado', fecha_entrega = NULL WHERE id = v_p1;
    IF pg_temp.t_parada(v_r, v_p1) IS DISTINCT FROM 'pendiente' OR pg_temp.t_cuenta(v_r) IS DISTINCT FROM '2/0' THEN
      v_fallas := v_fallas || format('R2 tras revertir: parada %s, ruta %s', pg_temp.t_parada(v_r, v_p1), pg_temp.t_cuenta(v_r));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ406';
  EXCEPTION
    WHEN SQLSTATE 'ZZ406' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R1-R2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- R3 · recalcular, paso a: el pedido está entregado y la parada no se enteró
  BEGIN
    v_r := pg_temp.t_ruta(v_tr, F, v_p1, v_p2);
    PERFORM pg_temp.t_entregar(v_p1, v_tr, F);
    UPDATE recorrido_pedidos SET estado_entrega = 'pendiente', hora_entrega = NULL
     WHERE recorrido_id = v_r AND pedido_id = v_p1;
    UPDATE recorridos SET pedidos_entregados = 0 WHERE id = v_r;
    v_j := public.recalcular_recorrido(v_r);
    IF v_j->>'paradas_realineadas' IS DISTINCT FROM '1' OR v_j->>'paradas_revertidas' IS DISTINCT FROM '0'
       OR pg_temp.t_parada(v_r, v_p1) IS DISTINCT FROM 'entregado' OR pg_temp.t_cuenta(v_r) IS DISTINCT FROM '2/1' THEN
      v_fallas := v_fallas || format('R3 recalcular dio %s, parada %s, ruta %s', v_j, pg_temp.t_parada(v_r, v_p1), pg_temp.t_cuenta(v_r));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ406';
  EXCEPTION
    WHEN SQLSTATE 'ZZ406' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R3 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- R4 · recalcular, paso b: la parada dice entregado y el pedido no lo está
  BEGIN
    v_r := pg_temp.t_ruta(v_tr, F, v_p1, v_p2);
    UPDATE recorrido_pedidos SET estado_entrega = 'entregado', hora_entrega = now()
     WHERE recorrido_id = v_r AND pedido_id = v_p1;
    UPDATE recorridos SET pedidos_entregados = 1 WHERE id = v_r;
    v_j := public.recalcular_recorrido(v_r);
    IF v_j->>'paradas_realineadas' IS DISTINCT FROM '0' OR v_j->>'paradas_revertidas' IS DISTINCT FROM '1'
       OR pg_temp.t_parada(v_r, v_p1) IS DISTINCT FROM 'pendiente' OR pg_temp.t_cuenta(v_r) IS DISTINCT FROM '2/0' THEN
      v_fallas := v_fallas || format('R4 recalcular dio %s, parada %s, ruta %s', v_j, pg_temp.t_parada(v_r, v_p1), pg_temp.t_cuenta(v_r));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ406';
  EXCEPTION
    WHEN SQLSTATE 'ZZ406' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R4 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- R5 · quitar el pedido de la ruta en curso
  BEGIN
    v_r := pg_temp.t_ruta(v_tr, F, v_p1, v_p2);
    v_j := public.quitar_pedido_de_recorridos_activos(v_p1);
    IF v_j->>'success' IS DISTINCT FROM 'true' OR v_j->>'paradas_eliminadas' IS DISTINCT FROM '1'
       OR pg_temp.t_parada(v_r, v_p1) IS DISTINCT FROM '(sin parada)' OR pg_temp.t_cuenta(v_r) IS DISTINCT FROM '1/0' THEN
      v_fallas := v_fallas || format('R5 quitar dio %s, parada %s, ruta %s', v_j, pg_temp.t_parada(v_r, v_p1), pg_temp.t_cuenta(v_r));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ406';
  EXCEPTION
    WHEN SQLSTATE 'ZZ406' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R5 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- R6 · cancelar un pedido en ruta: el trigger toma las rutas y quitar lo saca
  BEGIN
    v_r := pg_temp.t_ruta(v_tr, F, v_p1, v_p2);
    v_j := public.cancelar_pedido_con_stock(v_p2, 'ensayo 1406', v_adm, NULL);
    IF (SELECT estado FROM pedidos WHERE id = v_p2) IS DISTINCT FROM 'cancelado'
       OR pg_temp.t_parada(v_r, v_p2) IS DISTINCT FROM '(sin parada)' OR pg_temp.t_cuenta(v_r) IS DISTINCT FROM '1/0' THEN
      v_fallas := v_fallas || format('R6 cancelar dio %s, parada %s, ruta %s', v_j, pg_temp.t_parada(v_r, v_p2), pg_temp.t_cuenta(v_r));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ406';
  EXCEPTION
    WHEN SQLSTATE 'ZZ406' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R6 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- L1 · los cuerpos: el lock de rutas antes de la primera escritura de paradas
  v_txt := (SELECT prosrc FROM pg_proc WHERE oid = 'public.actualizar_recorrido_entrega()'::regprocedure);
  v_lock := position('FOR NO KEY UPDATE' IN v_txt);
  IF v_lock = 0 OR v_lock > position('UPDATE recorrido_pedidos' IN v_txt)
     OR v_lock > position('FROM recorrido_pedidos rp' || E'\n' || '  JOIN recorridos r' IN v_txt) THEN
    v_fallas := v_fallas || 'L1 actualizar_recorrido_entrega no bloquea las rutas antes de leer y tocar la parada'::text;
  END IF;

  v_txt := (SELECT prosrc FROM pg_proc WHERE oid = 'public.recalcular_recorrido(bigint)'::regprocedure);
  v_lock := position('FOR NO KEY UPDATE' IN v_txt);
  IF v_lock = 0 OR v_lock > position('UPDATE recorrido_pedidos' IN v_txt) THEN
    v_fallas := v_fallas || 'L1 recalcular_recorrido no bloquea la ruta antes de las paradas (a y b)'::text;
  END IF;

  v_txt := (SELECT prosrc FROM pg_proc WHERE oid = 'public.quitar_pedido_de_recorridos_activos(bigint)'::regprocedure);
  v_lock := position('FOR NO KEY UPDATE' IN v_txt);
  IF v_lock = 0 OR v_lock > position('DELETE FROM recorrido_pedidos' IN v_txt) THEN
    v_fallas := v_fallas || 'L1 quitar_pedido_de_recorridos_activos no bloquea sus rutas antes de borrar las paradas'::text;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · R1 R2 R3 R4 R5 R6 L1';
END
$ensayo$;
