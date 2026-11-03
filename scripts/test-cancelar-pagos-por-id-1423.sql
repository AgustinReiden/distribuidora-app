-- Ensayo de la migración que pre-bloquea por id los pagos de cancelar_pedido_con_stock (#1423):
-- cambia cómo se bloquea, no qué se hace.
--
-- El 40P01 lo mide el arnés (scripts/concurrencia, C6g y C6h), porque hacen falta tres
-- sesiones. Acá se prueba, en una sola, que la cancelación sigue dando lo mismo. Por eso los
-- casos C pasan igual con y sin la migración, y sólo L falla sin ella:
--
--   C1 · Una boleta cobrada en tres pagos, el más viejo editado: los tres quedan a favor del
--        cliente (sin pedido, con la nota), con los mismos montos; la boleta queda cancelada en
--        0 y el saldo del cliente baja lo cobrado.
--   C2 · Con app.cancelacion_conserva_pagos = '1' la cancelación no toca los pagos.
--   C3 · cambiar_cliente_pedido con 'pedido_nuevo': los pagos viajan al pedido nuevo.
--   C4 · cambiar_cliente_pedido con 'cliente_original': los pagos quedan a favor del cliente
--        original, desimputados por la cancelación.
--   L1 · El cuerpo: el pre-bloqueo va adentro del IF, justo antes del UPDATE, con el mismo
--        filtro y por id.
--
-- Corre contra prod sin dejar rastro (salvo valores de secuencia): un único DO que termina
-- siempre en una excepción, y cada caso en un sub-bloque que se revierte. Antes de aplicar la
-- migración se corre pegado detrás de su cuerpo, sin el BEGIN y el COMMIT; después, solo.
-- Solo y sin la migración tiene que dar 'ENSAYO FALLÓ', únicamente por L1.
--
-- Fixtures: una sucursal activa con un admin activo. El resto (clientes, producto, pedidos,
-- pagos) nace en el ensayo. Los pagos van en 2099, para no chocar con una caja cerrada.

CREATE OR REPLACE FUNCTION pg_temp.t_cliente(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (p_nombre, p_nombre, 'Ensayo 1423', p_suc)
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
    'ensayo 1423');
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

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_adm    uuid;
  v_prod   bigint;
  v_c1     bigint;
  v_c2     bigint;
  v_p1     bigint;
  v_pa     bigint;
  v_pb     bigint;
  v_pc     bigint;
  v_n      bigint;
  v_num    numeric;
  v_saldo  numeric;
  v_txt    text;
  v_j      jsonb;
  v_fallas text[] := '{}';
  F CONSTANT date := DATE '2099-04-10';
BEGIN
 BEGIN
  SELECT s.id, adm.usuario_id
    INTO v_suc, v_adm
    FROM sucursales s
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'admin'
                   ORDER BY us.usuario_id LIMIT 1) adm ON true
   WHERE s.activa
   ORDER BY s.id
   LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: ninguna sucursal activa con un admin';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1423', 100, 1000, 60, v_suc)
  RETURNING id INTO v_prod;
  v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1423 uno');
  v_c2 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1423 dos');

  -- C1 · tres pagos, el más viejo editado
  BEGIN
    v_p1 := pg_temp.t_pedido(v_c1, v_adm, v_prod, 1);
    v_pa := pg_temp.t_pago(v_c1, v_p1, v_suc, 50, F);
    v_pb := pg_temp.t_pago(v_c1, v_p1, v_suc, 30, F);
    v_pc := pg_temp.t_pago(v_c1, v_p1, v_suc, 20, F);
    UPDATE pagos SET notas = 'editado' WHERE id = v_pa;
    v_saldo := (SELECT saldo_cuenta FROM clientes WHERE id = v_c1);
    v_j := public.cancelar_pedido_con_stock(v_p1, 'ensayo 1423', v_adm, NULL);
    IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('C1 dio %s', v_j);
    ELSE
      SELECT count(*), COALESCE(sum(monto), 0) INTO v_n, v_num
        FROM pagos
       WHERE id IN (v_pa, v_pb, v_pc) AND pedido_id IS NULL AND cliente_id = v_c1
         AND notas LIKE '%[saldo a favor por cancelacion]';
      IF v_n <> 3 OR v_num <> 100 THEN
        v_fallas := v_fallas || format('C1 quedaron a favor %s pagos por %s', v_n, v_num);
      END IF;
      IF (SELECT notas FROM pagos WHERE id = v_pa) IS DISTINCT FROM 'editado [saldo a favor por cancelacion]' THEN
        v_fallas := v_fallas || format('C1 la nota del editado quedó %s', (SELECT notas FROM pagos WHERE id = v_pa));
      END IF;
      IF EXISTS (SELECT 1 FROM pedidos WHERE id = v_p1
                  AND (estado <> 'cancelado' OR total <> 0 OR monto_pagado <> 0)) THEN
        v_fallas := v_fallas || 'C1 la boleta no quedó cancelada en 0'::text;
      END IF;
      IF (SELECT saldo_cuenta FROM clientes WHERE id = v_c1) - v_saldo IS DISTINCT FROM -100::numeric THEN
        v_fallas := v_fallas || format('C1 el saldo se movió %s, tenía que bajar 100',
                                       (SELECT saldo_cuenta FROM clientes WHERE id = v_c1) - v_saldo);
      END IF;
      IF (SELECT stock FROM productos WHERE id = v_prod) IS DISTINCT FROM 1000 THEN
        v_fallas := v_fallas || 'C1 el stock no volvió'::text;
      END IF;
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ423';
  EXCEPTION
    WHEN SQLSTATE 'ZZ423' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('C1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- C2 · con el escape de cambiar_cliente_pedido, la cancelación no toca los pagos
  BEGIN
    v_p1 := pg_temp.t_pedido(v_c1, v_adm, v_prod, 1);
    v_pa := pg_temp.t_pago(v_c1, v_p1, v_suc, 60, F);
    v_pb := pg_temp.t_pago(v_c1, v_p1, v_suc, 40, F);
    PERFORM set_config('app.cancelacion_conserva_pagos', '1', true);
    v_j := public.cancelar_pedido_con_stock(v_p1, 'ensayo 1423', v_adm, NULL);
    PERFORM set_config('app.cancelacion_conserva_pagos', '', true);
    IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('C2 dio %s', v_j);
    ELSIF (SELECT count(*) FROM pagos
            WHERE id IN (v_pa, v_pb) AND pedido_id = v_p1 AND notas IS NULL) <> 2 THEN
      v_fallas := v_fallas || 'C2 la cancelación tocó los pagos con el escape puesto'::text;
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ423';
  EXCEPTION
    WHEN SQLSTATE 'ZZ423' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('C2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- C3 · cambiar el cliente, los pagos viajan
  BEGIN
    v_p1 := pg_temp.t_pedido(v_c1, v_adm, v_prod, 1);
    v_pa := pg_temp.t_pago(v_c1, v_p1, v_suc, 60, F);
    v_pb := pg_temp.t_pago(v_c1, v_p1, v_suc, 40, F);
    UPDATE pagos SET notas = 'editado' WHERE id = v_pa;
    v_j := public.cambiar_cliente_pedido(
      v_p1, v_c2, v_adm,
      jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1, 'precio_unitario', 100)),
      100);
    IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('C3 dio %s', v_j);
    ELSE
      v_n := (v_j->>'nuevo_pedido_id')::bigint;
      IF (SELECT count(*) FROM pagos
           WHERE id IN (v_pa, v_pb) AND pedido_id = v_n AND cliente_id = v_c2) <> 2 THEN
        v_fallas := v_fallas || 'C3 los pagos no viajaron al pedido nuevo'::text;
      END IF;
      IF (SELECT monto_pagado FROM pedidos WHERE id = v_n) IS DISTINCT FROM 100::numeric THEN
        v_fallas := v_fallas || 'C3 el pedido nuevo no quedó en 100 pagados'::text;
      END IF;
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ423';
  EXCEPTION
    WHEN SQLSTATE 'ZZ423' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('C3 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- C4 · cambiar el cliente, los pagos quedan a favor del original
  BEGIN
    v_p1 := pg_temp.t_pedido(v_c1, v_adm, v_prod, 1);
    v_pa := pg_temp.t_pago(v_c1, v_p1, v_suc, 60, F);
    v_pb := pg_temp.t_pago(v_c1, v_p1, v_suc, 40, F);
    v_j := public.cambiar_cliente_pedido(
      v_p1, v_c2, v_adm,
      jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1, 'precio_unitario', 100)),
      100, NULL, 0, 'ensayo 1423', 'cliente_original');
    IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('C4 dio %s', v_j);
    ELSE
      v_n := (v_j->>'nuevo_pedido_id')::bigint;
      IF (SELECT count(*) FROM pagos
           WHERE id IN (v_pa, v_pb) AND pedido_id IS NULL AND cliente_id = v_c1
             AND notas LIKE '%[saldo a favor por cancelacion]') <> 2 THEN
        v_fallas := v_fallas || 'C4 los pagos no quedaron a favor del cliente original'::text;
      END IF;
      IF (SELECT monto_pagado FROM pedidos WHERE id = v_n) IS DISTINCT FROM 0::numeric THEN
        v_fallas := v_fallas || 'C4 el pedido nuevo nació con pagos'::text;
      END IF;
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ423';
  EXCEPTION
    WHEN SQLSTATE 'ZZ423' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('C4 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- L1 · el cuerpo. Es lo único que falla sin la migración.
  v_txt := (SELECT prosrc FROM pg_proc WHERE oid = 'public.cancelar_pedido_con_stock(bigint,text,uuid,text)'::regprocedure);
  IF v_txt !~ 'PERFORM 1\s+FROM pagos\s+WHERE pedido_id = p_pedido_id\s+AND sucursal_id = v_sucursal\s+ORDER BY id\s+FOR NO KEY UPDATE;\s+UPDATE pagos\s+SET pedido_id = NULL'
     OR position('FOR NO KEY UPDATE' IN v_txt) < position('cancelacion_conserva_pagos'', true' IN v_txt) THEN
    v_fallas := v_fallas || 'L1 cancelar_pedido_con_stock no bloquea los pagos por id adentro del IF, antes del UPDATE'::text;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · C1 C2 C3 C4 L1';
 END;
END
$ensayo$;
