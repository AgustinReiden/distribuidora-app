-- Ensayo de #1044: obtener_resumen_cuenta_cliente (la del front) dice lo mismo
-- que su copia _bot sobre los pedidos cancelados, y obtener_estadisticas_pedidos
-- ya no existe.
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en RAISE
-- EXCEPTION. No escribe nada: sólo llama a las dos RPCs de lectura simulando
-- la sesión de PostgREST (SET LOCAL ROLE authenticated + request.jwt.claims +
-- x-sucursal-id).
--
--   'ENSAYO OK …'    → todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' → lista de lo que no se cumplió.
--
-- Antes de la migración tiene que FALLAR; después, pasar.
--
--   psql "$DATABASE_URL" -f scripts/test-resumen-cuenta-1044.sql

DO $ensayo$
DECLARE
  v_fallas  text[] := '{}';
  v_cliente bigint;  -- cliente con al menos un pedido cancelado que no es canje ni VB
  v_suc     bigint;
  v_admin   uuid;    -- admin de esa sucursal
  v_app     json;
  v_bot     json;
  k         text;
BEGIN
  SELECT p.cliente_id, p.sucursal_id INTO v_cliente, v_suc
    FROM pedidos p
   WHERE p.estado = 'cancelado' AND p.canal <> 'cambio'
     AND p.tipo_factura IS DISTINCT FROM 'VB'
     AND p.estado_pago IS DISTINCT FROM 'pagado'
   ORDER BY p.id DESC LIMIT 1;

  SELECT pf.id INTO v_admin
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.rol = 'admin' AND COALESCE(pf.activo, true) AND us.sucursal_id = v_suc
   ORDER BY pf.id LIMIT 1;

  IF v_cliente IS NULL OR v_admin IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · no hay datos: cliente con pedido cancelado (%), admin de su sucursal (%)',
      v_cliente, v_admin;
  END IF;

  -- La _bot es de servidor: se la llama como el dueño de la función.
  v_bot := public.obtener_resumen_cuenta_cliente_bot(v_cliente::int);

  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  v_app := public.obtener_resumen_cuenta_cliente(v_cliente::int);
  EXECUTE 'RESET ROLE';

  -- consumo_interno difiere a propósito (mig 332: el front lo recorta por
  -- quién cargó el vale) y es_comodin es sólo del bot.
  FOREACH k IN ARRAY ARRAY['saldo_actual','limite_credito','credito_disponible','total_pedidos',
                           'total_compras','total_pagos','pedidos_pendientes_pago',
                           'ultimo_pedido','ultimo_pago'] LOOP
    IF (v_app ->> k) IS DISTINCT FROM (v_bot ->> k) THEN
      v_fallas := v_fallas || format('cliente %s · %s: front=%s, bot=%s', v_cliente, k, v_app ->> k, v_bot ->> k);
    END IF;
  END LOOP;

  IF to_regprocedure('public.obtener_estadisticas_pedidos(timestamp with time zone,timestamp with time zone,uuid)') IS NOT NULL THEN
    v_fallas := v_fallas || 'obtener_estadisticas_pedidos sigue existiendo'::text;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · cliente % (sucursal %): front y bot coinciden; obtener_estadisticas_pedidos no existe',
    v_cliente, v_suc;
END;
$ensayo$;
