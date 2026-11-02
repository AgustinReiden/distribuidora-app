-- Ensayo de #1277 (tarjeta 4 del plan #1378): lo último que cortaba el día en UTC.
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en una
-- excepción. Tiene que terminar en ENSAYO OK. Sin la migración falla en todos los
-- casos menos D7; antes de aplicarla se corre pegado detrás de su cuerpo.
--
-- El reloj. A las 22 de Argentina CURRENT_DATE ya es mañana. now() no se puede
-- mover, pero CURRENT_DATE sale de la zona horaria de la sesión: el ensayo la pone
-- donde el servidor esté en otro día que Argentina, que es lo que pasa a esa hora,
-- y así corre igual a cualquier hora. Lo bien escrito no se entera de la zona; lo
-- que usa CURRENT_DATE da otro día.
--
--   D1 · Los cuatro defaults dan el día argentino.
--   D2 · Una compra cargada a las 22 nace con el día argentino.
--   D3 · La comanda de un canje a las 22 nace con el día argentino.
--   D4 · El recorrido nace con el día argentino.
--   D5 · Una boleta entregada anoche a las 22:30 tiene un día de deuda.
--   D6 · El bot cuenta los días sin compra, y filtra, con el día argentino.
--   D7 · La ficha del cliente y la deuda previa leen la fecha de la columna.
--   D8 · El gate ya no ve nada de esto.
--
-- Lo que el reloj no alcanza a mostrar: el COALESCE de registrar_compra_completa
-- (con NULL el INSERT choca antes contra el NOT NULL) y el created_at de D7
-- (fecha es NOT NULL). De esos responde D8.

DO $ensayo$
DECLARE
  v_hoy    date := public._tablero_hoy();
  v_zona   text;
  v_suc    bigint;
  v_adm    uuid;
  v_chofer uuid;
  v_prev   uuid;
  v_cli    bigint;
  v_prod1  bigint;
  v_prod2  bigint;
  v_pd     bigint;
  v_id     bigint;
  v_n      bigint;
  v_d      date;
  v_j      jsonb;
  v_t      text;
  r        record;
  v_fallas text[] := '{}';
  v_notas  text[] := '{}';
BEGIN
 BEGIN
  -- ---------------------------------------------------------------- reloj ---
  v_zona := CASE WHEN (now() AT TIME ZONE 'Etc/GMT-14')::date <> v_hoy THEN 'Etc/GMT-14' ELSE 'Etc/GMT+12' END;
  PERFORM set_config('TimeZone', v_zona, true);
  IF CURRENT_DATE = v_hoy THEN
    RAISE EXCEPTION 'con % el servidor sigue en el dia argentino: el ensayo no probaria nada', v_zona;
  END IF;
  v_notas := v_notas || format('servidor en %s, Argentina en %s', CURRENT_DATE, v_hoy);

  -- ------------------------------------------------------------- fixtures ---
  SELECT p.sucursal_id, adm.usuario_id INTO v_suc, v_adm
    FROM pedidos p
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = p.sucursal_id AND pf.activo AND pf.rol = 'admin'
                   ORDER BY us.usuario_id LIMIT 1) adm ON true
   WHERE p.estado = 'entregado'
     AND COALESCE(p.estado_pago, 'pendiente') IN ('pendiente', 'parcial')
     AND p.total > COALESCE(p.monto_pagado, 0)
     AND EXISTS (SELECT 1 FROM cliente_preventistas cp JOIN clientes c ON c.id = cp.cliente_id
                  WHERE c.sucursal_id = p.sucursal_id)
   ORDER BY p.id DESC
   LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'faltan fixtures: ninguna boleta entregada con saldo en una sucursal con admin y cartera';
  END IF;

  SELECT min(c.id) INTO v_cli FROM clientes c WHERE c.sucursal_id = v_suc AND c.activo;
  SELECT min(pr.id), max(pr.id) INTO v_prod1, v_prod2 FROM productos pr WHERE pr.sucursal_id = v_suc;
  SELECT pf.id INTO v_chofer
    FROM perfiles pf
    JOIN usuario_sucursales us ON us.usuario_id = pf.id AND us.sucursal_id = v_suc
   WHERE pf.activo AND pf.rol = 'transportista'
     AND NOT EXISTS (SELECT 1 FROM recorridos rc
                      WHERE rc.transportista_id = pf.id AND rc.sucursal_id = v_suc
                        AND rc.fecha = v_hoy AND rc.estado = 'en_curso')
   ORDER BY pf.id
   LIMIT 1;
  SELECT cp.preventista_id INTO v_prev
    FROM cliente_preventistas cp
    JOIN clientes c ON c.id = cp.cliente_id AND c.sucursal_id = v_suc AND c.activo
    JOIN pedidos pe ON pe.cliente_id = c.id AND pe.estado <> 'cancelado' AND pe.canal <> 'cambio'
                   AND pe.tipo_factura IS DISTINCT FROM 'VB'
   WHERE c.tipo_factura_default <> 'VB'
   GROUP BY cp.preventista_id
   ORDER BY count(DISTINCT c.id) DESC, cp.preventista_id
   LIMIT 1;
  IF v_cli IS NULL OR v_prod1 IS NULL OR v_chofer IS NULL OR v_prev IS NULL THEN
    RAISE EXCEPTION 'faltan fixtures en la sucursal %: cliente %, producto %, chofer %, preventista %',
      v_suc, v_cli, v_prod1, v_chofer, v_prev;
  END IF;

  -- ------------------------------------------------------------------- D1 ---
  v_n := 0;
  FOR r IN
    SELECT c.relname || '.' || a.attname AS col, pg_get_expr(d.adbin, d.adrelid) AS expr
      FROM pg_attrdef d
      JOIN pg_class c ON c.oid = d.adrelid
      JOIN pg_namespace ns ON ns.oid = c.relnamespace AND ns.nspname = 'public'
      JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
     WHERE c.relname || '.' || a.attname IN ('compras.fecha_compra', 'notas_credito.fecha',
                                             'rendiciones.fecha', 'transferencias_stock.fecha')
  LOOP
    v_n := v_n + 1;
    EXECUTE 'SELECT ' || r.expr INTO v_d;
    IF v_d IS DISTINCT FROM v_hoy THEN
      v_fallas := v_fallas || format('D1 · el default de %s da %s', r.col, v_d);
    END IF;
  END LOOP;
  -- rendiciones puede irse con #1368; las otras tres, no.
  IF v_n < 3 THEN
    v_fallas := v_fallas || format('D1 · se miraron %s defaults', v_n);
  END IF;

  -- ------------------------------------------------------------------- D2 ---
  INSERT INTO compras (sucursal_id) VALUES (v_suc) RETURNING fecha_compra INTO v_d;
  IF v_d IS DISTINCT FROM v_hoy THEN
    v_fallas := v_fallas || format('D2 · la compra nacio el %s', v_d);
  END IF;

  -- ------------------------------------------------------------------- D5 ---
  -- Antes de entrar como admin: lo mueve el server, no la pantalla.
  SELECT p.id INTO v_pd
    FROM pedidos p
   WHERE p.sucursal_id = v_suc AND p.estado = 'entregado'
     AND COALESCE(p.estado_pago, 'pendiente') IN ('pendiente', 'parcial')
     AND p.total > COALESCE(p.monto_pagado, 0)
   ORDER BY p.id DESC
   LIMIT 1;
  UPDATE pedidos
     SET fecha_entrega = ((v_hoy - 1) + time '22:30') AT TIME ZONE 'America/Argentina/Buenos_Aires'
   WHERE id = v_pd;

  -- --------------------------------------------------------- entra el admin ---
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_adm::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);

  SELECT t.dias, t.fecha_entrega INTO v_n, v_d
    FROM public.obtener_pedidos_ctacte_pendientes(NULL, NULL, NULL) t
   WHERE t.pedido_id = v_pd;
  IF v_n IS DISTINCT FROM 1 OR v_d IS DISTINCT FROM v_hoy - 1 THEN
    v_fallas := v_fallas || format('D5 · la boleta de anoche a las 22:30 dio %s dias, entregada el %s', v_n, v_d);
  END IF;

  -- ------------------------------------------------------------------- D3 ---
  v_id := public.crear_pedido_cambio_en_ruta(v_cli::integer, v_prod1, 1, v_prod2, 1, 'ensayo 1277', 'erroneo');
  SELECT fecha INTO v_d FROM pedidos WHERE id = v_id;
  IF v_d IS DISTINCT FROM v_hoy THEN
    v_fallas := v_fallas || format('D3 · la comanda del canje nacio el %s', v_d);
  END IF;

  -- ------------------------------------------------------------------- D4 ---
  v_id := public.crear_recorrido(v_chofer, '[]'::jsonb, NULL, NULL);
  SELECT fecha INTO v_d FROM recorridos WHERE id = v_id;
  IF v_d IS DISTINCT FROM v_hoy THEN
    v_fallas := v_fallas || format('D4 · el recorrido nacio el %s', v_d);
  END IF;

  -- ------------------------------------------------------------------- D6 ---
  v_j := public.bot_mis_clientes(v_prev, v_suc, false, NULL, 100000)::jsonb;
  SELECT count(*) FILTER (WHERE (x->>'dias_desde_ultima')::int <> v_hoy - (x->>'ultima_compra')::date),
         max((x->>'ultima_compra')::date)
    INTO v_n, v_d
    FROM jsonb_array_elements(v_j->'clientes') x
   WHERE x->>'ultima_compra' IS NOT NULL;
  IF v_d IS NULL THEN
    v_fallas := v_fallas || 'D6 · el preventista no tiene ningun cliente con compra'::text;
  ELSIF v_n > 0 THEN
    v_fallas := v_fallas || format('D6 · %s clientes con los dias corridos', v_n);
  END IF;

  -- El mas reciente lleva v_hoy - v_d dias: pedir uno mas tiene que dejarlo afuera.
  v_j := public.bot_mis_clientes(v_prev, v_suc, false, (v_hoy - v_d) + 1, 100000)::jsonb;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j->'clientes') x
              WHERE (x->>'ultima_compra')::date = v_d) THEN
    v_fallas := v_fallas || format('D6 · el filtro dejo pasar a un cliente que compro el %s', v_d);
  END IF;

  -- ------------------------------------------------------------------- D7 ---
  SELECT pg.cliente_id INTO v_id
    FROM pagos pg
    JOIN clientes c ON c.id = pg.cliente_id AND c.sucursal_id = v_suc
   WHERE pg.created_at::date <> (pg.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
   ORDER BY pg.id DESC
   LIMIT 1;
  IF v_id IS NULL THEN
    v_notas := v_notas || 'D7 · ningun pago de 21 a 24 en esta sucursal'::text;
  ELSE
    v_j := public.tablero_ficha_cliente(v_id);
    SELECT count(*) INTO v_n
      FROM jsonb_array_elements(v_j->'pagos') x
     WHERE NOT EXISTS (SELECT 1 FROM pagos pg
                        WHERE pg.cliente_id = v_id AND pg.fecha = (x->>'fecha')::date);
    IF v_n > 0 OR jsonb_array_length(v_j->'pagos') = 0 THEN
      v_fallas := v_fallas || format('D7 · la ficha del cliente %s muestra pagos en un dia que no es el suyo: %s', v_id, v_j->'pagos');
    END IF;
  END IF;

  SELECT count(*) INTO v_n
    FROM (SELECT public.deuda_previa_detalle(pe) AS j
            FROM pedidos pe
           WHERE pe.sucursal_id = v_suc
           ORDER BY pe.id DESC
           LIMIT 50) q,
         jsonb_array_elements(q.j) x
   WHERE NOT EXISTS (SELECT 1 FROM pedidos p2
                      WHERE p2.id = (x->>'id')::bigint AND p2.fecha = (x->>'fecha')::date);
  IF v_n > 0 THEN
    v_fallas := v_fallas || format('D7 · %s boletas de la deuda previa con otra fecha que la suya', v_n);
  END IF;

  -- ------------------------------------------------------------------- D8 ---
  v_j := public.auditoria_fechas_utc();
  SELECT string_agg(x->>'firma', ', ') INTO v_t
    FROM jsonb_array_elements(v_j->'funciones') x
   WHERE x->>'nombre' IN ('bot_mis_clientes', 'crear_pedido_cambio_en_ruta', 'crear_recorrido',
                          'deuda_previa_detalle', 'obtener_pedidos_ctacte_pendientes',
                          'registrar_compra_completa', 'tablero_ficha_cliente');
  IF v_t IS NOT NULL THEN
    v_fallas := v_fallas || ('D8 · el gate sigue viendo: ' || v_t);
  END IF;
  SELECT string_agg(x->>'columna', ', ') INTO v_t
    FROM jsonb_array_elements(v_j->'defaults') x
   WHERE x->>'columna' IN ('compras.fecha_compra', 'notas_credito.fecha',
                           'rendiciones.fecha', 'transferencias_stock.fecha');
  IF v_t IS NOT NULL THEN
    v_fallas := v_fallas || ('D8 · el gate sigue viendo los defaults: ' || v_t);
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA', MESSAGE = format(E'ENSAYO FALLO (%s fallas, todo revertido):\n- %s\nnotas: %s',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), array_to_string(v_notas, ' | '));
  END IF;
  RAISE EXCEPTION USING ERRCODE = 'ZZ0OK', MESSAGE = format('ENSAYO OK (todo revertido) · notas: %s', array_to_string(v_notas, ' | '));
 EXCEPTION WHEN SQLSTATE 'ZZ0OK' OR SQLSTATE 'ZZ0FA' THEN
  -- Se relanza afuera del bloque que escribió.
  GET STACKED DIAGNOSTICS v_t = MESSAGE_TEXT;
  RAISE EXCEPTION '%', v_t;
 END;
END
$ensayo$;
