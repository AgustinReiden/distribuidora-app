-- Ensayo de la migración 463c: la boleta nueva absorbe el saldo a favor del cliente, y el alta sin líneas de venta
-- se rechaza (#1469, tarjeta 2 de #1477).
--
-- La 463c lo citaba y no llegó a main. Lo reconstruyó la tarjeta 15 (#1492) desde el cuerpo de la migración, como la
-- tarjeta 10 con scripts/concurrencia/controles-negativos-a2.sql. Los 40P01 del orden de locks los mide el arnés
-- (scripts/concurrencia, clave a2). Acá se prueba, en una sola sesión, qué hace el alta:
--
--   V1 · VTA-F-2 en crear_pedido_completo: sin líneas, o sólo con regalos, se rechaza con el texto de la edición y no
--        nace ningún pedido.
--   V2 · VTA-F-2 en crear_pedido_completo_bot: lo mismo con una confirmación del bot sólo con regalos.
--   S1 · Un cliente sin boletas impagas y con un crédito de 30: la boleta nueva de 100 lo absorbe entera. La respuesta
--        trae saldo_a_favor_aplicado 30 y saldo_a_favor_otras 0, la boleta queda 30/100, el crédito apunta a ella con
--        de_saldo_a_favor, y el cliente no queda con créditos sueltos.
--   S2 · FIFO: una boleta W de 20 impaga y anterior, y un crédito de 50. La boleta nueva de 100 recibe 30 y W los 20
--        (primero la más vieja). La respuesta trae aplicado 30 y otras 20, y los dos pagos tienen de_saldo_a_favor.
--   S3 · Un crédito de 150 contra una boleta nueva de 100: queda saldada (aplicado 100) y quedan 50 a favor, sin la
--        marca.
--   S4 · El bot hace lo mismo que S1.
--   S5 · Un vale blanco no absorbe nada: nace saldado y el crédito sigue suelto.
--   S6 · Con app.reimputacion_pagos = 'on' (una reimputación en curso) el alta no toma el crédito.
--   S7 · Pasar a C2, con 'pedido_nuevo', una boleta X de C1 cobrada 50, con un crédito de 30 en C2 y un total nuevo de
--        100. Entra todo (80 ≤ 100): el pedido nuevo queda 80/100, X cancelada sin pagos, y C2 sin créditos sueltos. El
--        caso con excedente lo ensaya la tarjeta 12 (#1489): depende de cómo quede cambiar_cliente_pedido.
--   M1 · La marca la pone el trigger y no quien escribe: un pago que nace en la boleta va en false aunque mande true;
--        un crédito que pasa a una boleta va en true; un pedazo de un pago de la misma boleta hereda la marca de su
--        padre; un pago que vuelve a suelto va en false.
--   En S1–S7, clientes.saldo_cuenta = Σ (total − monto_pagado) − Σ créditos (el predicado de CC-A) para cada cliente
--   que se toca, y las violaciones de CC-A de auditoria_integridad() en toda la base no cambian.
--   L1 · Los helpers del alta y la función del trigger no tienen EXECUTE para anon ni authenticated, el trigger está
--        prendido, y crear_pedido_completo y el bot llaman a _alta_aplicar_saldo_a_favor.
--
-- Corre contra prod sin dejar rastro (salvo valores de secuencia): un único DO que termina siempre en una excepción,
-- y cada caso en un sub-bloque que se revierte. La migración ya está aplicada: se corre solo.
--
-- Fixtures: una sucursal activa con un admin activo y la caja de hoy abierta. El resto nace en el ensayo.

CREATE OR REPLACE FUNCTION pg_temp.t_cliente(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (p_nombre, p_nombre, 'Ensayo 1469', p_suc)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_producto(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES (p_nombre, 1, 1000, 1, p_suc)
  RETURNING id;
$fn$;

-- Las líneas de p_monto unidades de $1.
CREATE OR REPLACE FUNCTION pg_temp.t_items(p_prod bigint, p_monto int)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_monto, 'precio_unitario', 1));
$fn$;

-- La respuesta entera del alta de una boleta de p_monto pesos, del día p_fecha.
CREATE OR REPLACE FUNCTION pg_temp.t_alta(p_cli bigint, p_admin uuid, p_prod bigint, p_monto int, p_fecha date,
                                          p_tipo text DEFAULT 'ZZ')
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.crear_pedido_completo(
    p_cli, p_monto, p_admin, pg_temp.t_items(p_prod, p_monto),
    'ensayo 1469', 'efectivo', 'pendiente', p_fecha, p_tipo);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  RETURN v_res;
END
$fn$;

-- Un crédito (pago a cuenta sin boleta).
CREATE OR REPLACE FUNCTION pg_temp.t_credito(p_cli bigint, p_suc bigint, p_adm uuid, p_monto numeric, p_fecha date)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha, usuario_id, notas, a_cuenta)
  VALUES (p_cli, NULL, p_suc, p_monto, 'efectivo', p_fecha, p_adm, '[saldo a favor]', true)
  RETURNING id;
$fn$;

-- '' si el saldo del cliente cierra contra sus boletas y sus créditos (el predicado de CC-A); si no, el detalle.
CREATE OR REPLACE FUNCTION pg_temp.t_saldo(p_cli bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT CASE WHEN abs(COALESCE(c.saldo_cuenta, 0) - (b.deuda - f.favor)) <= 0.01 THEN ''
              ELSE format(' saldo_cuenta de %s=%s esperado=%s', p_cli, c.saldo_cuenta, b.deuda - f.favor) END
    FROM public.clientes c,
         LATERAL (SELECT COALESCE(sum(total - COALESCE(monto_pagado, 0)), 0) AS deuda FROM public.pedidos
                   WHERE cliente_id = p_cli AND estado NOT IN ('cancelado', 'anulado')) b,
         LATERAL (SELECT COALESCE(sum(monto), 0) AS favor FROM public.pagos
                   WHERE cliente_id = p_cli AND pedido_id IS NULL) f
   WHERE c.id = p_cli;
$fn$;

-- Las violaciones de CC-A de toda la base, de auditoria_integridad().
CREATE OR REPLACE FUNCTION pg_temp.t_cca()
RETURNS int LANGUAGE sql AS $fn$
  SELECT (e->>'violaciones')::int
    FROM jsonb_array_elements(public.auditoria_integridad()->'checks') e
   WHERE e->>'id' = 'CC-A';
$fn$;

-- 'pagado/total' de una boleta, para comparar de una vez.
CREATE OR REPLACE FUNCTION pg_temp.t_estado(p_ped bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT COALESCE(monto_pagado, 0)::numeric(12,2)::text || '/' || total::numeric(12,2)::text FROM public.pedidos WHERE id = p_ped;
$fn$;

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_adm    uuid;
  v_hoy    date := public._tablero_hoy();
  v_prod   bigint;
  v_c1     bigint;
  v_c2     bigint;
  v_w      bigint;
  v_n      bigint;
  v_x      bigint;
  v_c      bigint;
  v_p      bigint;
  v_q      bigint;
  v_conf   uuid;
  v_antes  bigint;
  v_txt    text;
  v_j      jsonb;
  v_fallas text[] := '{}';
  v_cca    int;
  c_vtaf2  constant text := 'El pedido tiene que tener al menos un producto que no sea regalo. El pedido no se creó.';
BEGIN
 BEGIN
  SELECT s.id, adm.usuario_id
    INTO v_suc, v_adm
    FROM sucursales s
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'admin'
                   ORDER BY us.usuario_id LIMIT 1) adm ON true
   WHERE s.activa
     AND COALESCE(public.ultima_fecha_caja_cerrada(s.id), v_hoy - 1) < v_hoy
   ORDER BY s.id
   LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: ninguna sucursal activa con un admin y la caja de hoy abierta';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  v_prod := pg_temp.t_producto(v_suc, 'ZZ ensayo 1469');
  v_cca := pg_temp.t_cca();

  -- V1 · VTA-F-2 en el alta
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1469 V1');
    v_antes := (SELECT count(*) FROM pedidos WHERE cliente_id = v_c1);
    v_j := public.crear_pedido_completo(v_c1, 0, v_adm, '[]'::jsonb, 'ensayo 1469', 'efectivo', 'pendiente', v_hoy);
    IF COALESCE((v_j->>'success')::boolean, true) OR v_j->'errores'->>0 IS DISTINCT FROM c_vtaf2 THEN
      v_fallas := v_fallas || format('V1 sin líneas dio %s', v_j);
    END IF;
    v_j := public.crear_pedido_completo(
      v_c1, 0, v_adm,
      jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1, 'precio_unitario', 0, 'es_bonificacion', true)),
      'ensayo 1469', 'efectivo', 'pendiente', v_hoy);
    IF COALESCE((v_j->>'success')::boolean, true) OR v_j->'errores'->>0 IS DISTINCT FROM c_vtaf2 THEN
      v_fallas := v_fallas || format('V1 sólo regalos dio %s', v_j);
    END IF;
    IF (SELECT count(*) FROM pedidos WHERE cliente_id = v_c1) <> v_antes THEN
      v_fallas := v_fallas || 'V1 nació un pedido'::text;
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ469';
  EXCEPTION
    WHEN SQLSTATE 'ZZ469' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('V1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- V2 · VTA-F-2 en el bot
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1469 V2');
    INSERT INTO bot_pedidos_pendientes (perfil_id, sucursal_id, cliente_id, items, total)
    VALUES (v_adm, v_suc, v_c1,
            jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1, 'precio_unitario', 0, 'es_bonificacion', true)),
            0)
    RETURNING id INTO v_conf;
    v_j := public.crear_pedido_completo_bot(v_adm, v_conf);
    IF COALESCE((v_j->>'success')::boolean, true) OR v_j->>'error' IS DISTINCT FROM c_vtaf2
       OR EXISTS (SELECT 1 FROM pedidos WHERE cliente_id = v_c1) THEN
      v_fallas := v_fallas || format('V2 dio %s', v_j);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ469';
  EXCEPTION
    WHEN SQLSTATE 'ZZ469' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('V2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- S1 · la boleta nueva absorbe un crédito entero
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1469 S1');
    v_c := pg_temp.t_credito(v_c1, v_suc, v_adm, 30, v_hoy);
    v_j := pg_temp.t_alta(v_c1, v_adm, v_prod, 100, v_hoy);
    v_n := (v_j->>'pedido_id')::bigint;
    v_txt := pg_temp.t_saldo(v_c1);
    IF (v_j->>'saldo_a_favor_aplicado')::numeric IS DISTINCT FROM 30::numeric
       OR (v_j->>'saldo_a_favor_otras')::numeric IS DISTINCT FROM 0::numeric
       OR pg_temp.t_estado(v_n) IS DISTINCT FROM '30.00/100.00'
       OR (SELECT pedido_id::text || '/' || de_saldo_a_favor::text FROM pagos WHERE id = v_c) IS DISTINCT FROM v_n::text || '/true'
       OR EXISTS (SELECT 1 FROM pagos WHERE cliente_id = v_c1 AND pedido_id IS NULL)
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('S1 dio %s%s', v_j, v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ469';
  EXCEPTION
    WHEN SQLSTATE 'ZZ469' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('S1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- S2 · FIFO: primero la boleta más vieja
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1469 S2');
    v_w := (pg_temp.t_alta(v_c1, v_adm, v_prod, 20, v_hoy - 1)->>'pedido_id')::bigint;
    v_c := pg_temp.t_credito(v_c1, v_suc, v_adm, 50, v_hoy);
    v_j := pg_temp.t_alta(v_c1, v_adm, v_prod, 100, v_hoy);
    v_n := (v_j->>'pedido_id')::bigint;
    v_txt := pg_temp.t_saldo(v_c1);
    IF (v_j->>'saldo_a_favor_aplicado')::numeric IS DISTINCT FROM 30::numeric
       OR (v_j->>'saldo_a_favor_otras')::numeric IS DISTINCT FROM 20::numeric
       OR pg_temp.t_estado(v_n) IS DISTINCT FROM '30.00/100.00'
       OR pg_temp.t_estado(v_w) IS DISTINCT FROM '20.00/20.00'
       OR EXISTS (SELECT 1 FROM pagos WHERE pedido_id IN (v_w, v_n) AND NOT de_saldo_a_favor)
       OR (SELECT COALESCE(sum(monto), 0) FROM pagos WHERE pedido_id IN (v_w, v_n)) IS DISTINCT FROM 50::numeric
       OR EXISTS (SELECT 1 FROM pagos WHERE cliente_id = v_c1 AND pedido_id IS NULL)
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('S2 dio %s%s', v_j, v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ469';
  EXCEPTION
    WHEN SQLSTATE 'ZZ469' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('S2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- S3 · un crédito más grande que la boleta
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1469 S3');
    v_c := pg_temp.t_credito(v_c1, v_suc, v_adm, 150, v_hoy);
    v_j := pg_temp.t_alta(v_c1, v_adm, v_prod, 100, v_hoy);
    v_n := (v_j->>'pedido_id')::bigint;
    v_txt := pg_temp.t_saldo(v_c1);
    IF (v_j->>'saldo_a_favor_aplicado')::numeric IS DISTINCT FROM 100::numeric
       OR (v_j->>'saldo_a_favor_otras')::numeric IS DISTINCT FROM 0::numeric
       OR pg_temp.t_estado(v_n) IS DISTINCT FROM '100.00/100.00'
       OR (SELECT COALESCE(sum(monto), 0) FROM pagos WHERE cliente_id = v_c1 AND pedido_id IS NULL AND NOT de_saldo_a_favor)
          IS DISTINCT FROM 50::numeric
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('S3 dio %s%s', v_j, v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ469';
  EXCEPTION
    WHEN SQLSTATE 'ZZ469' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('S3 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- S4 · el bot
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1469 S4');
    v_c := pg_temp.t_credito(v_c1, v_suc, v_adm, 30, v_hoy);
    INSERT INTO bot_pedidos_pendientes (perfil_id, sucursal_id, cliente_id, items, total, total_neto)
    VALUES (v_adm, v_suc, v_c1, pg_temp.t_items(v_prod, 100), 100, 100)
    RETURNING id INTO v_conf;
    v_j := public.crear_pedido_completo_bot(v_adm, v_conf);
    v_n := (v_j->>'pedido_id')::bigint;
    v_txt := pg_temp.t_saldo(v_c1);
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (v_j->>'saldo_a_favor_aplicado')::numeric IS DISTINCT FROM 30::numeric
       OR pg_temp.t_estado(v_n) IS DISTINCT FROM '30.00/100.00'
       OR (SELECT pedido_id FROM pagos WHERE id = v_c) IS DISTINCT FROM v_n
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('S4 dio %s%s', v_j, v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ469';
  EXCEPTION
    WHEN SQLSTATE 'ZZ469' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('S4 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- S5 · un vale blanco no absorbe
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1469 S5');
    UPDATE clientes SET tipo_factura_default = 'VB' WHERE id = v_c1;
    v_c := pg_temp.t_credito(v_c1, v_suc, v_adm, 30, v_hoy);
    -- El vale blanco lo precia el server a costo: el front manda total y precios en 0.
    v_j := public.crear_pedido_completo(
      v_c1, 0, v_adm,
      jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 100, 'precio_unitario', 0)),
      'ensayo 1469', 'efectivo', 'pendiente', v_hoy, 'VB');
    v_n := (v_j->>'pedido_id')::bigint;
    v_txt := pg_temp.t_saldo(v_c1);
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR v_j ? 'saldo_a_favor_aplicado'
       OR (SELECT tipo_factura FROM pedidos WHERE id = v_n) IS DISTINCT FROM 'VB'
       OR EXISTS (SELECT 1 FROM pagos WHERE pedido_id = v_n)
       OR (SELECT pedido_id FROM pagos WHERE id = v_c) IS NOT NULL
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('S5 dio %s%s', v_j, v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ469';
  EXCEPTION
    WHEN SQLSTATE 'ZZ469' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('S5 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- S6 · con una reimputación en curso el alta no toma el crédito
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1469 S6');
    v_c := pg_temp.t_credito(v_c1, v_suc, v_adm, 30, v_hoy);
    PERFORM set_config('app.reimputacion_pagos', 'on', true);
    v_j := pg_temp.t_alta(v_c1, v_adm, v_prod, 100, v_hoy);
    PERFORM set_config('app.reimputacion_pagos', 'off', true);
    v_n := (v_j->>'pedido_id')::bigint;
    IF v_j ? 'saldo_a_favor_aplicado'
       OR pg_temp.t_estado(v_n) IS DISTINCT FROM '0.00/100.00'
       OR (SELECT pedido_id FROM pagos WHERE id = v_c) IS NOT NULL THEN
      v_fallas := v_fallas || format('S6 dio %s', v_j);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ469';
  EXCEPTION
    WHEN SQLSTATE 'ZZ469' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('S6 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- S7 · cambio de cliente a 'pedido_nuevo' con crédito en C2, sin excedente
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1469 S7 C1');
    v_c2 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1469 S7 C2');
    v_x := (pg_temp.t_alta(v_c1, v_adm, v_prod, 100, v_hoy)->>'pedido_id')::bigint;
    v_j := public.registrar_pagos_pedido_impl(v_x, '[{"monto":50,"forma_pago":"efectivo"}]'::jsonb, v_hoy);
    v_c := pg_temp.t_credito(v_c2, v_suc, v_adm, 30, v_hoy);
    v_j := public.cambiar_cliente_pedido(v_x, v_c2, v_adm, pg_temp.t_items(v_prod, 100), 100, NULL, 0,
                                         'ensayo 1469', 'pedido_nuevo');
    v_n := (v_j->>'nuevo_pedido_id')::bigint;
    v_txt := pg_temp.t_saldo(v_c1) || pg_temp.t_saldo(v_c2);
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (SELECT estado FROM pedidos WHERE id = v_x) IS DISTINCT FROM 'cancelado'
       OR EXISTS (SELECT 1 FROM pagos WHERE pedido_id = v_x)
       OR pg_temp.t_estado(v_n) IS DISTINCT FROM '80.00/100.00'
       OR EXISTS (SELECT 1 FROM pagos WHERE cliente_id IN (v_c1, v_c2) AND pedido_id IS NULL)
       OR (SELECT pedido_id FROM pagos WHERE id = v_c) IS DISTINCT FROM v_n
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('S7 dio %s%s', v_j, v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ469';
  EXCEPTION
    WHEN SQLSTATE 'ZZ469' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('S7 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- Ningún caso movió CC-A de la base (cada uno se revirtió; esto mira que el ensayo no deje nada a medias).
  IF pg_temp.t_cca() IS DISTINCT FROM v_cca THEN
    v_fallas := v_fallas || format('CC-A de la base: %s, antes %s', pg_temp.t_cca(), v_cca);
  END IF;

  -- M1 · la marca de_saldo_a_favor la pone el trigger
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1469 M1');
    v_n := (pg_temp.t_alta(v_c1, v_adm, v_prod, 100, v_hoy)->>'pedido_id')::bigint;
    -- un pago que nace en la boleta, aunque mande true
    INSERT INTO pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha, usuario_id, de_saldo_a_favor)
    VALUES (v_c1, v_n, v_suc, 10, 'efectivo', v_hoy, v_adm, true)
    RETURNING id INTO v_p;
    IF (SELECT de_saldo_a_favor FROM pagos WHERE id = v_p) THEN
      v_fallas := v_fallas || 'M1 un pago que nace en la boleta quedó con la marca'::text;
    END IF;
    -- un crédito que pasa a la boleta
    v_c := pg_temp.t_credito(v_c1, v_suc, v_adm, 10, v_hoy);
    UPDATE pagos SET pedido_id = v_n WHERE id = v_c;
    IF NOT (SELECT de_saldo_a_favor FROM pagos WHERE id = v_c) THEN
      v_fallas := v_fallas || 'M1 un crédito que pasó a la boleta quedó sin la marca'::text;
    END IF;
    -- un pedazo de un pago de la misma boleta hereda la marca de su padre
    UPDATE pagos SET monto = monto - 2 WHERE id IN (v_p, v_c);
    INSERT INTO pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha, usuario_id, pago_origen_id, pago_padre_id)
    VALUES (v_c1, v_n, v_suc, 2, 'efectivo', v_hoy, v_adm, v_p, v_p)
    RETURNING id INTO v_q;
    IF (SELECT de_saldo_a_favor FROM pagos WHERE id = v_q) THEN
      v_fallas := v_fallas || 'M1 el pedazo de un pago de la boleta quedó con la marca'::text;
    END IF;
    INSERT INTO pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha, usuario_id, pago_origen_id, pago_padre_id)
    VALUES (v_c1, v_n, v_suc, 2, 'efectivo', v_hoy, v_adm, v_c, v_c)
    RETURNING id INTO v_q;
    IF NOT (SELECT de_saldo_a_favor FROM pagos WHERE id = v_q) THEN
      v_fallas := v_fallas || 'M1 el pedazo de un crédito aplicado no heredó la marca'::text;
    END IF;
    -- un pago que vuelve a suelto
    UPDATE pagos SET pedido_id = NULL WHERE id = v_c;
    IF (SELECT de_saldo_a_favor FROM pagos WHERE id = v_c) THEN
      v_fallas := v_fallas || 'M1 un pago que volvió a suelto conservó la marca'::text;
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ469';
  EXCEPTION
    WHEN SQLSTATE 'ZZ469' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('M1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- L1 · EXECUTE, el trigger y las llamadas
  IF EXISTS (SELECT 1
               FROM unnest(ARRAY['public._alta_bloquea_boletas_credito(bigint,bigint)',
                                 'public._alta_bloquea_creditos(bigint,bigint,bigint[])',
                                 'public._alta_aplicar_saldo_a_favor(bigint,bigint,bigint)',
                                 'public.pagos_marcar_saldo_a_favor()']) f
              WHERE has_function_privilege('anon', f, 'EXECUTE')
                 OR has_function_privilege('authenticated', f, 'EXECUTE')) THEN
    v_fallas := v_fallas || 'L1 un helper del alta o la función del trigger tiene EXECUTE para anon o authenticated'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgname = 'trg_pagos_marcar_saldo_a_favor'
                    AND tgrelid = 'public.pagos'::regclass AND tgenabled = 'O') THEN
    v_fallas := v_fallas || 'L1 trg_pagos_marcar_saldo_a_favor no está prendido'::text;
  END IF;
  IF (SELECT prosrc FROM pg_proc
       WHERE oid = 'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)'::regprocedure)
       !~ '_alta_aplicar_saldo_a_favor'
     OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.crear_pedido_completo_bot(uuid,uuid)'::regprocedure)
       !~ '_alta_aplicar_saldo_a_favor' THEN
    v_fallas := v_fallas || 'L1 el alta o el bot no aplican el saldo a favor'::text;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · V1 V2 S1 S2 S3 S4 S5 S6 S7 M1 L1';
 END;
END
$ensayo$;
