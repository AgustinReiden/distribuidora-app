-- Ensayo de #1044 / #1184: obtener_resumen_cuenta_cliente (la del front) dice lo
-- mismo que su copia _bot sobre los pedidos cancelados, ambas coinciden con
-- esperados que calcula el propio ensayo, y obtener_estadisticas_pedidos ya no
-- existe.
--
-- Ya no es un ensayo antes/después: la mig 335 está aplicada y esto corre como
-- regresión contra prod.
--
-- Corre contra prod SIN dejar rastro, pero NO es de sólo lectura: arma el dato
-- con un UPDATE de estado_pago de los cancelados de un cliente (en prod todos
-- los cancelados están 'pagado', con total 0 y monto_pagado 0, y por eso hay
-- que recrear el estado que la 335 corrigió). El UPDATE vive dentro del DO, que
-- termina SIEMPRE en RAISE EXCEPTION, y eso lo revierte. NO agregar COMMIT ni
-- RETURN antes del RAISE final: harían persistir el UPDATE.
--
-- Cobertura real: muerden total_pedidos, pedidos_pendientes_pago y
-- ultimo_pedido (mutando la RPC del front en un BEGIN..ROLLBACK, cada uno hace
-- fallar el ensayo). total_compras sólo queda cubierto por la comparación front
-- contra bot: un cancelado siempre tiene total 0 (invariante VENTA-I), así que
-- no se puede cubrir con datos reales y forzar total > 0 contradice ese
-- invariante. Por eso el OK final no dice "cobertura completa".
--
-- Cómo leer el resultado (el script termina siempre en excepción, así que el
-- código de salida de psql no distingue; mirar el prefijo del mensaje o el
-- SQLSTATE con \set VERBOSITY verbose):
--   'ENSAYO OK …'                      SQLSTATE ZZ000  todas las aserciones pasaron.
--   'ENSAYO FALLÓ · …'                 SQLSTATE ZZ001  lista de lo que no se cumplió.
--   'ENSAYO FALLÓ · SIN COBERTURA …'   SQLSTATE ZZ002  faltan datos para que el ensayo muerda.
--
-- Costo: el UPDATE toma locks de fila por milisegundos y los triggers de
-- historial y auditoría consumen secuencias que el rollback no devuelve
-- (huecos). No correrlo en horario de cierre de caja.
--
-- Para hacer un mutante por campo: en un único BEGIN ... ROLLBACK, redefinir
-- obtener_resumen_cuenta_cliente (EXECUTE sobre pg_get_functiondef con el filtro
-- de cancelados quitado sólo en ese campo) y correr este DO; tiene que dar ZZ001.
--
--   psql "$DATABASE_URL" -f scripts/test-resumen-cuenta-1044.sql

-- Predicados copiados de la mig 335 a propósito: total_pedidos, total_compras,
-- pedidos_pendientes_pago y ultimo_pedido excluyen SOLO cancelados y canal 'cambio';
-- NINGUNO excluye el vale blanco (VB). Por eso los esperados de vivos y de ultimo_pedido
-- cuentan los VB vivos. El filtro VB queda únicamente para los cancelados que el ensayo
-- fuerza a 'pendiente' (un VB está saldado por naturaleza y no se puede forzar).
-- Si la RPC cambia, hay que ajustar el ensayo.
DO $ensayo$
DECLARE
  v_fallas   text[] := '{}';
  v_cliente  bigint;
  v_suc      bigint;
  v_admin    uuid;
  v_ult_canc timestamptz;
  v_ult_vivo timestamptz;
  v_app      json;
  v_bot      json;
  k          text;
  v_canc     int;
  v_forzados int;
  v_vivos    int;
  v_pend_esp int;
  v_ult_esp  timestamptz;
BEGIN
  -- Cliente con cancelados reales (no canje, no VB) Y pedidos vivos (VB incluidos, como la RPC),
  -- con admin en su sucursal, sin mirar estado_pago. Se prefiere el que tiene un cancelado más
  -- nuevo que su último vivo.
  SELECT x.cliente_id, x.sucursal_id, x.ult_canc, x.ult_vivo
    INTO v_cliente, v_suc, v_ult_canc, v_ult_vivo
    FROM (
      SELECT p.cliente_id, p.sucursal_id,
             count(*) FILTER (WHERE p.estado = 'cancelado'
                                AND p.tipo_factura IS DISTINCT FROM 'VB')   AS canc,
             count(*) FILTER (WHERE p.estado IS DISTINCT FROM 'cancelado') AS vivos,
             max(p.created_at) FILTER (WHERE p.estado = 'cancelado'
                                       AND p.tipo_factura IS DISTINCT FROM 'VB') AS ult_canc,
             max(p.created_at) FILTER (WHERE p.estado IS DISTINCT FROM 'cancelado') AS ult_vivo
        FROM pedidos p
       WHERE p.canal <> 'cambio'
       GROUP BY p.cliente_id, p.sucursal_id
    ) x
   WHERE x.canc > 0 AND x.vivos > 0
     AND EXISTS (SELECT 1 FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
                  WHERE pf.rol = 'admin' AND COALESCE(pf.activo, true) AND us.sucursal_id = x.sucursal_id)
   ORDER BY (x.ult_canc > x.ult_vivo) DESC, x.canc DESC, x.cliente_id DESC
   LIMIT 1;

  IF v_cliente IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · SIN COBERTURA: ningún cliente con cancelados, pedidos vivos y un admin en su sucursal' USING ERRCODE = 'ZZ002';
  END IF;
  IF NOT (v_ult_canc > v_ult_vivo) THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · SIN COBERTURA: ningún cliente con un cancelado más nuevo que su último pedido vivo (ultimo_pedido no podría morder)' USING ERRCODE = 'ZZ002';
  END IF;

  SELECT pf.id INTO v_admin
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.rol = 'admin' AND COALESCE(pf.activo, true) AND us.sucursal_id = v_suc
   ORDER BY pf.id LIMIT 1;

  -- Se arma el dato: los cancelados de prod están 'pagado'; se los deja como los dejaba la 335.
  UPDATE pedidos SET estado_pago = 'pendiente'
   WHERE cliente_id = v_cliente AND sucursal_id = v_suc AND estado = 'cancelado'
     AND canal <> 'cambio' AND tipo_factura IS DISTINCT FROM 'VB';
  SELECT count(*), count(*) FILTER (WHERE estado_pago IS DISTINCT FROM 'pagado')
    INTO v_canc, v_forzados
    FROM pedidos
   WHERE cliente_id = v_cliente AND sucursal_id = v_suc AND estado = 'cancelado'
     AND canal <> 'cambio' AND tipo_factura IS DISTINCT FROM 'VB';
  IF v_forzados = 0 OR v_forzados <> v_canc THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · SIN COBERTURA: no se pudo dejar los cancelados (%) con estado_pago pendiente (forzados=%)', v_canc, v_forzados USING ERRCODE = 'ZZ002';
  END IF;

  -- Esperados calculados por el ensayo (mismo predicado que las RPCs, mig 335).
  SELECT count(*), max(created_at) INTO v_vivos, v_ult_esp
    FROM pedidos
   WHERE cliente_id = v_cliente AND sucursal_id = v_suc AND estado IS DISTINCT FROM 'cancelado'
     AND canal <> 'cambio';
  SELECT count(*) INTO v_pend_esp
    FROM pedidos
   WHERE cliente_id = v_cliente AND sucursal_id = v_suc AND estado IS DISTINCT FROM 'cancelado'
     AND canal <> 'cambio' AND estado_pago IS DISTINCT FROM 'pagado';

  -- La _bot es de servidor: se la llama como el dueño de la función.
  v_bot := public.obtener_resumen_cuenta_cliente_bot(v_cliente::int);

  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  v_app := public.obtener_resumen_cuenta_cliente(v_cliente::int);
  EXECUTE 'RESET ROLE';

  -- consumo_interno difiere a propósito (mig 332) y es_comodin es sólo del bot.
  FOREACH k IN ARRAY ARRAY['saldo_actual','limite_credito','credito_disponible','total_pedidos',
                           'total_compras','total_pagos','pedidos_pendientes_pago',
                           'ultimo_pedido','ultimo_pago'] LOOP
    IF (v_app ->> k) IS DISTINCT FROM (v_bot ->> k) THEN
      v_fallas := v_fallas || format('cliente %s · %s: front=%s, bot=%s', v_cliente, k, v_app ->> k, v_bot ->> k);
    END IF;
  END LOOP;
  IF (v_app ->> 'total_pedidos')::int IS DISTINCT FROM v_vivos THEN
    v_fallas := v_fallas || format('total_pedidos front=%s, esperado=%s', v_app ->> 'total_pedidos', v_vivos);
  END IF;
  IF (v_app ->> 'pedidos_pendientes_pago')::int IS DISTINCT FROM v_pend_esp THEN
    v_fallas := v_fallas || format('pedidos_pendientes_pago front=%s, esperado=%s', v_app ->> 'pedidos_pendientes_pago', v_pend_esp);
  END IF;
  IF (v_app ->> 'ultimo_pedido')::timestamptz IS DISTINCT FROM v_ult_esp THEN
    v_fallas := v_fallas || format('ultimo_pedido front=%s, esperado=%s', v_app ->> 'ultimo_pedido', v_ult_esp);
  END IF;

  IF to_regprocedure('public.obtener_estadisticas_pedidos(timestamp with time zone,timestamp with time zone,uuid)') IS NOT NULL THEN
    v_fallas := v_fallas || 'obtener_estadisticas_pedidos sigue existiendo'::text;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' | ') USING ERRCODE = 'ZZ001';
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · cliente % (sucursal %): vivos=%, cancelados forzados a pendiente=%, pendientes esperados=%; front y bot coinciden; obtener_estadisticas_pedidos no existe',
    v_cliente, v_suc, v_vivos, v_forzados, v_pend_esp USING ERRCODE = 'ZZ000';
END;
$ensayo$;
