-- Ensayo de la migración del orden de locks (#1375): cambia cómo se bloquea, no qué se hace.
--
-- Los deadlocks los mide el arnés (scripts/concurrencia, C6 y C7), porque hacen falta dos
-- sesiones. Acá se prueba, en una sola sesión, que las funciones siguen dando lo mismo. Por eso
-- los casos R, P y F pasan igual con y sin la migración, y sólo L falla sin ella:
--
--   R1 · aplicar_orden_ruta: el que sale vuelve a preparación, el orden nuevo queda en las paradas
--        y en los pedidos, y la ruta cuenta lo que tiene.
--   R2 · Un pedido en la ruta de otro chofer pasa a esta: sale de la otra, y las dos recalculan.
--   R3 · marcar_entregas_masivo: el resultado no depende del orden del arreglo, y un entregado
--        no se vuelve a entregar.
--   R4 · marcar_entrega_y_pago_masivo: cobra sólo lo que falta y entrega el lote entero.
--   P1 · Qué pago se recorta: desde la fecha más nueva, aunque tenga el id más viejo.
--   P2 · cambiar_cliente_pedido: los pagos viajan al pedido nuevo, y lo que sobra lo recorta
--        desde el más nuevo y queda a favor del cliente nuevo.
--   F1 · La foto: entran los pagos del día del chofer, y el corte es el último pago.
--   L1 · Los cuerpos: el pre-bloqueo va antes de la primera escritura, y la foto sigue por id.
--
-- Corre contra prod sin dejar rastro (salvo valores de secuencia): un único DO que termina
-- siempre en una excepción, y cada caso en un sub-bloque que se revierte. Antes de aplicar la
-- migración se corre pegado detrás de su cuerpo, sin el BEGIN y el COMMIT; después, solo.
-- Solo y sin la migración tiene que dar 'ENSAYO FALLÓ', únicamente por L1.
--
-- Fixtures: una sucursal activa con un admin y dos transportistas base activos. El resto (clientes,
-- producto, pedidos) nace en el ensayo. Las rutas y los pagos van en 2099, para no chocar con
-- uq_recorrido_vigente ni con una caja cerrada.

CREATE OR REPLACE FUNCTION pg_temp.t_cliente(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (p_nombre, p_nombre, 'Ensayo 1375', p_suc)
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
    'ensayo 1375');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_pago(p_cli bigint, p_ped bigint, p_suc bigint, p_monto numeric, p_fecha date)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha)
  VALUES (p_cli, p_ped, p_suc, p_monto, 'efectivo', p_fecha)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_ruta(p_tr uuid, p_fecha date, VARIADIC p_peds bigint[])
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT public.aplicar_orden_ruta(
    p_tr,
    (SELECT jsonb_agg(jsonb_build_object('pedido_id', x, 'orden_entrega', o) ORDER BY o)
       FROM unnest(p_peds) WITH ORDINALITY AS t(x, o)),
    NULL, NULL, NULL, p_fecha);
$fn$;

-- La ruta, leída: paradas en orden y contadores.
CREATE OR REPLACE FUNCTION pg_temp.t_ver_ruta(p_rec bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT format('%s|%s|%s|%s',
                (SELECT string_agg(rp.pedido_id || ':' || rp.orden_entrega || ':' || rp.estado_entrega,
                                   ',' ORDER BY rp.orden_entrega)
                   FROM public.recorrido_pedidos rp WHERE rp.recorrido_id = p_rec),
                r.total_pedidos, r.pedidos_entregados, r.total_cobrado::bigint)
    FROM public.recorridos r WHERE r.id = p_rec;
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
  v_c3     bigint;
  v_p1     bigint;
  v_p2     bigint;
  v_p3     bigint;
  v_r1     bigint;
  v_r2     bigint;
  v_pa     bigint;
  v_pb     bigint;
  v_pc     bigint;
  v_n      bigint;
  v_num    numeric;
  v_txt    text;
  v_j      jsonb;
  v_ped    public.pedidos%ROWTYPE;
  v_fallas text[] := '{}';
  F CONSTANT date := DATE '2099-03-10';
  G CONSTANT date := DATE '2099-03-11';
BEGIN
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
  VALUES ('ZZ ensayo 1375', 100, 1000, 60, v_suc)
  RETURNING id INTO v_prod;
  v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1375 uno');
  v_c2 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1375 dos');
  v_c3 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1375 tres');
  v_p1 := pg_temp.t_pedido(v_c1, v_adm, v_prod, 1);
  v_p2 := pg_temp.t_pedido(v_c2, v_adm, v_prod, 1);
  v_p3 := pg_temp.t_pedido(v_c3, v_adm, v_prod, 1);

  -- R1 · reordenar y sacar uno
  BEGIN
    v_r1 := pg_temp.t_ruta(v_a, F, v_p1, v_p2);
    IF pg_temp.t_ruta(v_a, F, v_p3, v_p1) IS DISTINCT FROM v_r1 THEN
      v_fallas := v_fallas || 'R1 el reorden no devolvió la misma ruta'::text;
    END IF;
    v_txt := pg_temp.t_ver_ruta(v_r1);
    IF v_txt IS DISTINCT FROM format('%s:1:pendiente,%s:2:pendiente|2|0|0', v_p3, v_p1) THEN
      v_fallas := v_fallas || format('R1 la ruta quedó %s', v_txt);
    END IF;
    SELECT * INTO v_ped FROM pedidos WHERE id = v_p2;
    IF v_ped.estado IS DISTINCT FROM 'en_preparacion' OR v_ped.transportista_id IS NOT NULL
       OR v_ped.orden_entrega IS NOT NULL THEN
      v_fallas := v_fallas || format('R1 el que sale quedó %s, chofer %s, orden %s',
                                     v_ped.estado, v_ped.transportista_id, v_ped.orden_entrega);
    END IF;
    IF (SELECT orden_entrega FROM pedidos WHERE id = v_p3) IS DISTINCT FROM 1
       OR (SELECT estado FROM pedidos WHERE id = v_p3) IS DISTINCT FROM 'asignado' THEN
      v_fallas := v_fallas || 'R1 el que entra no quedó asignado y primero'::text;
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ375';
  EXCEPTION
    WHEN SQLSTATE 'ZZ375' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- R2 · dos rutas: el pedido pasa de la de B a la de A
  BEGIN
    v_r1 := pg_temp.t_ruta(v_a, F, v_p1);
    v_r2 := pg_temp.t_ruta(v_b, F, v_p2, v_p3);
    PERFORM pg_temp.t_ruta(v_a, F, v_p3, v_p1);
    v_txt := pg_temp.t_ver_ruta(v_r1);
    IF v_txt IS DISTINCT FROM format('%s:1:pendiente,%s:2:pendiente|2|0|0', v_p3, v_p1) THEN
      v_fallas := v_fallas || format('R2 la ruta de A quedó %s', v_txt);
    END IF;
    v_txt := pg_temp.t_ver_ruta(v_r2);
    IF v_txt IS DISTINCT FROM format('%s:1:pendiente|1|0|0', v_p2) THEN
      v_fallas := v_fallas || format('R2 la ruta de B quedó %s', v_txt);
    END IF;
    IF (SELECT transportista_id FROM pedidos WHERE id = v_p3) IS DISTINCT FROM v_a THEN
      v_fallas := v_fallas || 'R2 el pedido no pasó al chofer A'::text;
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ375';
  EXCEPTION
    WHEN SQLSTATE 'ZZ375' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- R3 · entrega masiva, con los ids al revés y uno ya entregado
  BEGIN
    v_r1 := pg_temp.t_ruta(v_a, F, v_p1, v_p2, v_p3);
    IF public.marcar_entregas_masivo(ARRAY[v_p1], v_a, F) IS DISTINCT FROM 1 THEN
      v_fallas := v_fallas || 'R3 la primera entrega no dio 1'::text;
    END IF;
    v_n := public.marcar_entregas_masivo(ARRAY[v_p3, v_p2, v_p1], v_a, F);
    IF v_n IS DISTINCT FROM 2 THEN
      v_fallas := v_fallas || format('R3 el lote dio %s, tenía que dar 2', v_n);
    END IF;
    v_txt := pg_temp.t_ver_ruta(v_r1);
    IF v_txt IS DISTINCT FROM format('%s:1:entregado,%s:2:entregado,%s:3:entregado|3|3|0', v_p1, v_p2, v_p3) THEN
      v_fallas := v_fallas || format('R3 la ruta quedó %s', v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ375';
  EXCEPTION
    WHEN SQLSTATE 'ZZ375' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R3 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- R4 y F1 · entrega y pago masivo, con uno ya pagado, y la foto de ese día
  BEGIN
    v_r1 := pg_temp.t_ruta(v_a, F, v_p1, v_p2);
    v_pa := pg_temp.t_pago(v_c2, v_p2, v_suc, 100, F);
    v_n := public.marcar_entrega_y_pago_masivo(ARRAY[v_p2, v_p1], v_a, 'efectivo', F, NULL);
    IF v_n IS DISTINCT FROM 2 THEN
      v_fallas := v_fallas || format('R4 el lote dio %s, tenía que dar 2', v_n);
    END IF;
    SELECT count(*), COALESCE(sum(monto), 0) INTO v_n, v_num FROM pagos WHERE pedido_id = v_p1;
    IF v_n <> 1 OR v_num <> 100 THEN
      v_fallas := v_fallas || format('R4 el que faltaba tiene %s pagos por %s', v_n, v_num);
    END IF;
    SELECT count(*) INTO v_n FROM pagos WHERE pedido_id = v_p2;
    IF v_n <> 1 THEN
      v_fallas := v_fallas || format('R4 el ya pagado tiene %s pagos', v_n);
    END IF;
    IF EXISTS (SELECT 1 FROM pedidos WHERE id IN (v_p1, v_p2)
                AND (estado <> 'entregado' OR monto_pagado <> total OR estado_pago <> 'pagado')) THEN
      v_fallas := v_fallas || 'R4 el lote no quedó entregado y saldado'::text;
    END IF;
    v_txt := pg_temp.t_ver_ruta(v_r1);
    IF v_txt IS DISTINCT FROM format('%s:1:entregado,%s:2:entregado|2|2|200', v_p1, v_p2) THEN
      v_fallas := v_fallas || format('R4 la ruta quedó %s', v_txt);
    END IF;

    v_n := public.confirmar_rendicion(F, v_a, 'confirmada', '{}'::jsonb, 'ensayo 1375');
    SELECT jsonb_build_object('pagos', count(*), 'distintos', count(DISTINCT pago_id),
                              'suma', sum(monto), 'corte', max(ultimo_pago_id))
      INTO v_j
      FROM rendicion_pagos_confirmados WHERE rendicion_id = v_n;
    IF (v_j->>'pagos')::int <> 2 OR (v_j->>'distintos')::int <> 2 OR (v_j->>'suma')::numeric <> 200
       OR (v_j->>'corte')::bigint IS DISTINCT FROM (SELECT max(id) FROM pagos) THEN
      v_fallas := v_fallas || format('F1 la foto quedó %s', v_j);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ375';
  EXCEPTION
    WHEN SQLSTATE 'ZZ375' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R4/F1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- P1 · qué pago se recorta. pc tiene el id más viejo y la fecha más nueva.
  BEGIN
    v_pc := pg_temp.t_pago(v_c1, v_p1, v_suc, 10, G);
    v_pa := pg_temp.t_pago(v_c1, v_p1, v_suc, 60, F);
    v_pb := pg_temp.t_pago(v_c1, v_p1, v_suc, 30, F);
    -- Baja a 65: se va entero el de 10 (fecha más nueva), al de 30 le sacan 25 y el de 60 no se toca.
    UPDATE pedidos SET total = 65 WHERE id = v_p1;
    IF EXISTS (SELECT 1 FROM pagos WHERE id = v_pc) THEN
      v_fallas := v_fallas || 'P1 el pago de fecha más nueva sigue vivo'::text;
    END IF;
    IF (SELECT monto FROM pagos WHERE id = v_pb) IS DISTINCT FROM 5::numeric THEN
      v_fallas := v_fallas || format('P1 el segundo quedó en %s', (SELECT monto FROM pagos WHERE id = v_pb));
    END IF;
    IF (SELECT monto FROM pagos WHERE id = v_pa) IS DISTINCT FROM 60::numeric THEN
      v_fallas := v_fallas || format('P1 el más viejo quedó en %s', (SELECT monto FROM pagos WHERE id = v_pa));
    END IF;
    IF (SELECT monto_pagado FROM pedidos WHERE id = v_p1) IS DISTINCT FROM 65::numeric THEN
      v_fallas := v_fallas || 'P1 monto_pagado no quedó en 65'::text;
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ375';
  EXCEPTION
    WHEN SQLSTATE 'ZZ375' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('P1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- P2 · cambiar el cliente: 100 cobrados en dos pagos, el pedido nuevo vale 70.
  BEGIN
    v_pa := pg_temp.t_pago(v_c1, v_p1, v_suc, 60, F);
    v_pb := pg_temp.t_pago(v_c1, v_p1, v_suc, 40, F);
    v_j := public.cambiar_cliente_pedido(
      v_p1, v_c2, v_adm,
      jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1, 'precio_unitario', 70)),
      70);
    IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('P2 dio %s', v_j);
    ELSE
      v_n := (v_j->>'nuevo_pedido_id')::bigint;
      IF (v_j->>'excedente_a_favor')::numeric IS DISTINCT FROM 30::numeric THEN
        v_fallas := v_fallas || format('P2 el excedente dio %s', v_j->>'excedente_a_favor');
      END IF;
      -- El de 60 viaja entero; el de 40 se parte en 10 para la boleta y 30 a favor o imputados.
      IF (SELECT monto FROM pagos WHERE id = v_pa) IS DISTINCT FROM 60::numeric
         OR (SELECT pedido_id FROM pagos WHERE id = v_pa) IS DISTINCT FROM v_n THEN
        v_fallas := v_fallas || 'P2 el pago viejo no viajó entero'::text;
      END IF;
      IF (SELECT monto FROM pagos WHERE id = v_pb) IS DISTINCT FROM 10::numeric THEN
        v_fallas := v_fallas || format('P2 el pago nuevo quedó en %s', (SELECT monto FROM pagos WHERE id = v_pb));
      END IF;
      IF EXISTS (SELECT 1 FROM pagos WHERE id IN (v_pa, v_pb) AND cliente_id <> v_c2) THEN
        v_fallas := v_fallas || 'P2 un pago no pasó al cliente nuevo'::text;
      END IF;
      IF (SELECT monto_pagado FROM pedidos WHERE id = v_n) IS DISTINCT FROM 70::numeric THEN
        v_fallas := v_fallas || 'P2 el pedido nuevo no quedó en 70 pagados'::text;
      END IF;
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ375';
  EXCEPTION
    WHEN SQLSTATE 'ZZ375' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('P2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- L1 · los cuerpos. Es lo único que falla sin la migración.
  v_txt := (SELECT prosrc FROM pg_proc WHERE oid = 'public.aplicar_orden_ruta(uuid,jsonb,numeric,integer,jsonb,date)'::regprocedure);
  IF position('FOR NO KEY UPDATE' IN v_txt) = 0
     OR position('FOR NO KEY UPDATE' IN v_txt) > position('UPDATE pedidos p' IN v_txt) THEN
    v_fallas := v_fallas || 'L1 aplicar_orden_ruta no bloquea antes de escribir'::text;
  END IF;
  v_txt := (SELECT prosrc FROM pg_proc WHERE oid = 'public.marcar_entregas_masivo(bigint[],uuid,date)'::regprocedure);
  IF v_txt !~ 'ORDER BY id\s+FOR NO KEY UPDATE' THEN
    v_fallas := v_fallas || 'L1 marcar_entregas_masivo no bloquea por id'::text;
  END IF;
  v_txt := (SELECT prosrc FROM pg_proc WHERE oid = 'public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)'::regprocedure);
  IF position('FOR NO KEY UPDATE' IN v_txt) = 0
     OR position('FOR NO KEY UPDATE' IN v_txt) > position('INSERT INTO pagos' IN v_txt) THEN
    v_fallas := v_fallas || 'L1 marcar_entrega_y_pago_masivo_impl no bloquea antes del primer pago'::text;
  END IF;
  v_txt := (SELECT prosrc FROM pg_proc WHERE oid = 'public.desafectar_sobrepago_pedido(bigint)'::regprocedure);
  IF v_txt !~ 'ORDER BY id\s+FOR UPDATE' OR v_txt !~ 'ORDER BY fecha DESC, id DESC\s+FOR UPDATE' THEN
    v_fallas := v_fallas || 'L1 desafectar_sobrepago_pedido no bloquea por id, o perdió el orden del recorte'::text;
  END IF;
  v_txt := (SELECT prosrc FROM pg_proc WHERE oid = 'public._rendicion_tomar_foto(bigint)'::regprocedure);
  IF v_txt !~ 'ORDER BY id\s+FOR SHARE' THEN
    v_fallas := v_fallas || 'L1 la foto dejó de bloquear por id'::text;
  END IF;
  v_txt := (SELECT prosrc FROM pg_proc WHERE oid = 'public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)'::regprocedure);
  IF v_txt !~ 'ORDER BY id\s+FOR UPDATE\s*;\s+UPDATE pagos' THEN
    v_fallas := v_fallas || 'L1 cambiar_cliente_pedido no bloquea los pagos por id'::text;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · R1 R2 R3 R4 P1 P2 F1 L1';
 END;
END
$ensayo$;
