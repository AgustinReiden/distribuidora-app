-- =========================================================================
-- Test de concurrencia de monto_pagado (#1247, migracion cobros_2)
--
-- QUE PRUEBA
-- ----------
-- Que dos pagos que entran a la vez al MISMO pedido terminan los dos en
-- monto_pagado. recalcular_monto_pagado_pedido (AFTER INSERT en pagos) hacia
-- `UPDATE pedidos SET monto_pagado = (SELECT SUM(monto) FROM pagos ...)` sin
-- lock previo. En READ COMMITTED la segunda transaccion espera el lock de la
-- fila del pedido y, al seguir, re-evalua el WHERE contra la version nueva,
-- pero el subselect del SET sigue con la foto de su sentencia: no ve el pago de
-- la primera. Pedido de 80, A carga 50 y B carga 30: quedaba monto_pagado = 30
-- con pagos que suman 80.
--
-- Desde cobros_2 el trigger toma el lock del pedido en una sentencia propia
-- (`PERFORM 1 FROM pedidos WHERE id = v_id FOR UPDATE`) y recien despues suma:
-- esa sentencia arranca con una foto nueva, que ya ve el pago de A.
--
-- Las RPCs de pago lockean el pedido antes de insertar (181, 230 y
-- registrar_pagos_pedido), asi que entre ellas no se cruzaban. Este test inserta
-- directo, como postgres y sin lock previo: es el camino que el trigger tiene que
-- aguantar solo (un INSERT REST viejo, una funcion nueva que no lockee).
--
-- POR QUE ESTA EN UN ARCHIVO Y NO CORRIO EN LA MIGRACION
-- ------------------------------------------------------
-- Hace falta CONCURRENCIA REAL: dos conexiones a la vez (ver
-- test-concurrencia-pago-fifo.sql: ni el MCP, ni dblink, ni 2PC). Se corre a
-- mano con dos psql.
--
-- COMO SE CORRE
-- -------------
-- Contra una BASE DE PRUEBA (una branch de Supabase o un Postgres local con el
-- schema), NUNCA contra produccion: escribe un cliente, un pedido y pagos.
--
--   psql "$URL_DE_PRUEBA" -f scripts/test-concurrencia-monto-pagado-1247.sql   # sesion A
--
-- y, en otra terminal, DENTRO de los 5 segundos que dura el pg_sleep de A:
--
--   psql "$URL_DE_PRUEBA" -c "SELECT _test_1247_pagar(30);"                     # sesion B
--
-- Al final, en cualquiera de las dos:
--
--   psql "$URL_DE_PRUEBA" -c "SELECT * FROM _test_1247_veredicto();"
--   psql "$URL_DE_PRUEBA" -c "SELECT _test_1247_limpiar();"
--
-- QUE TIENE QUE PASAR
-- -------------------
--   · La sesion B QUEDA ESPERANDO mientras A tiene el lock (su salida tarda
--     ~5 s, lo que dura el pg_sleep de A).
--   · Al final: pedido de 80 con monto_pagado = 80 y estado_pago 'pagado', y
--     los pagos suman 80. El veredicto dice 'OK'.
--   · Sin el lock de cobros_2 el mismo guion deja monto_pagado = 30 (lo de B) y
--     el veredicto dice 'FALLO'.
-- =========================================================================

\set ON_ERROR_STOP on

-- -------------------------------------------------------------------------
-- Escenario: un cliente con UNA boleta de 80 sin pagar. Se guarda en
-- _test_1247_ids para que las otras funciones la encuentren.
-- -------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS _test_1247_ids (k text PRIMARY KEY, v bigint);

CREATE OR REPLACE FUNCTION _test_1247_preparar() RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
  v_suc bigint := (SELECT id FROM sucursales WHERE activa ORDER BY id LIMIT 1);
  v_cli bigint;
  v_ped bigint;
BEGIN
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('TEST CONCURRENCIA 1247', 'TEST CONCURRENCIA 1247', 'x', v_suc)
  RETURNING id INTO v_cli;

  INSERT INTO pedidos (cliente_id, sucursal_id, total, estado, estado_pago, fecha)
  VALUES (v_cli, v_suc, 80, 'pendiente', 'pendiente', (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date)
  RETURNING id INTO v_ped;

  DELETE FROM _test_1247_ids;
  INSERT INTO _test_1247_ids VALUES ('cliente', v_cli), ('pedido', v_ped), ('sucursal', v_suc);
  RETURN v_ped;
END
$$;

-- Un pago directo al pedido del test, sin lock previo: solo el del trigger.
CREATE OR REPLACE FUNCTION _test_1247_pagar(p_monto numeric) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
  v_pago bigint;
BEGIN
  INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, sucursal_id, notas,
                     fecha)
  VALUES ((SELECT v FROM _test_1247_ids WHERE k = 'cliente'),
          (SELECT v FROM _test_1247_ids WHERE k = 'pedido'),
          p_monto, 'efectivo',
          (SELECT v FROM _test_1247_ids WHERE k = 'sucursal'),
          'test concurrencia 1247',
          (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date + 400)
  RETURNING id INTO v_pago;
  RETURN v_pago;
END
$$;

CREATE OR REPLACE FUNCTION _test_1247_veredicto()
RETURNS TABLE (total numeric, monto_pagado numeric, estado_pago text, suma_pagos numeric, veredicto text)
LANGUAGE sql AS $$
  SELECT pd.total, pd.monto_pagado, pd.estado_pago::text, s.suma,
         CASE WHEN pd.monto_pagado = s.suma AND s.suma = 80
              THEN 'OK - monto_pagado no perdio ningun pago'
              ELSE 'FALLO - monto_pagado (' || pd.monto_pagado || ') no es la suma de los pagos (' || s.suma || ')'
         END
    FROM pedidos pd,
         LATERAL (SELECT COALESCE(SUM(monto), 0) AS suma FROM pagos WHERE pedido_id = pd.id) s
   WHERE pd.id = (SELECT v FROM _test_1247_ids WHERE k = 'pedido');
$$;

CREATE OR REPLACE FUNCTION _test_1247_limpiar() RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_cli bigint := (SELECT v FROM _test_1247_ids WHERE k = 'cliente');
BEGIN
  DELETE FROM pagos WHERE cliente_id = v_cli;
  DELETE FROM pedidos WHERE cliente_id = v_cli;
  DELETE FROM clientes WHERE id = v_cli;
  DROP FUNCTION IF EXISTS _test_1247_preparar();
  DROP FUNCTION IF EXISTS _test_1247_pagar(numeric);
  DROP FUNCTION IF EXISTS _test_1247_veredicto();
  DROP TABLE IF EXISTS _test_1247_ids;
END
$$;

-- -------------------------------------------------------------------------
-- Sesion A: prepara, y carga 50 con el lock tomado durante 5 s.
-- -------------------------------------------------------------------------
SELECT _test_1247_preparar() AS pedido_del_test;

BEGIN;
SELECT _test_1247_pagar(50) AS pago_de_a;   -- el trigger lockea el pedido aca
SELECT pg_sleep(5);                          -- ahora corre la sesion B
COMMIT;

SELECT * FROM _test_1247_veredicto();
