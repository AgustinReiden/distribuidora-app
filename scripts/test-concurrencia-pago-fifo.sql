-- =========================================================================
-- Test de concurrencia de la imputacion FIFO (mig 230)
--
-- QUE PRUEBA
-- ----------
-- Que dos cobros simultaneos al MISMO cliente no pagan dos veces la misma
-- boleta. Antes de la mig 230 el bucle de registrar_pago_cliente_fifo_impl
-- recorria los pedidos sin `FOR UPDATE` e imputaba
-- `LEAST(v_restante, total - pagado)` sobre el snapshot del record: las dos
-- sesiones leian `pagado = 0` y las dos imputaban el total entero.
--
-- POR QUE ESTA EN UN ARCHIVO Y NO CORRIO EN LA MIGRACION
-- ------------------------------------------------------
-- Hace falta CONCURRENCIA REAL: dos conexiones a la vez. No se puede desde el
-- MCP de Supabase (una conexion por llamada), ni con dblink (pide password y el
-- rol no es superuser), ni con 2PC (`max_prepared_transactions = 0`).
-- Se corre a mano con dos psql.
--
-- COMO SE CORRE
-- -------------
-- Contra una BASE DE PRUEBA (una branch de Supabase o un Postgres local con el
-- schema), NUNCA contra produccion: escribe pagos y pedidos reales.
--
--   psql "$URL_DE_PRUEBA" -f scripts/test-concurrencia-pago-fifo.sql   # sesion A
--
-- y, en otra terminal, DENTRO de los 5 segundos que dura el pg_sleep de A:
--
--   psql "$URL_DE_PRUEBA" -c "SELECT _test_fifo_cobrar(2);"            # sesion B
--
-- QUE TIENE QUE PASAR
-- -------------------
--   · La sesion B QUEDA ESPERANDO mientras A tiene el lock (se ve porque su
--     salida tarda ~5 s, lo que dura el pg_sleep de A).
--   · Al final: un solo pedido de total 10.000 con monto_pagado = 10.000, y el
--     segundo cobro de 10.000 queda entero como SALDO A FAVOR (pedido_id NULL),
--     no encima de la misma boleta.
--   · Sin el `FOR UPDATE` de la mig 230 el mismo guion deja monto_pagado =
--     20.000 sobre un total de 10.000, y CC-B se pone en rojo.
-- =========================================================================

\set ON_ERROR_STOP on

-- -------------------------------------------------------------------------
-- Escenario: un cliente con UNA boleta de 10.000 sin pagar.
-- -------------------------------------------------------------------------
DROP SCHEMA IF EXISTS _test_fifo CASCADE;
CREATE SCHEMA _test_fifo;

CREATE OR REPLACE FUNCTION _test_fifo_preparar() RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
  v_suc bigint := 1;
  v_cli bigint;
  v_ped bigint;
BEGIN
  v_cli := (SELECT COALESCE(MAX(id),0)+1 FROM clientes);
  INSERT INTO clientes (id, razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (v_cli, 'TEST CONCURRENCIA 230', 'TEST CONCURRENCIA 230', 'x', v_suc);

  v_ped := (SELECT COALESCE(MAX(id),0)+1 FROM pedidos);
  INSERT INTO pedidos (id, cliente_id, sucursal_id, total, monto_pagado, estado, estado_pago, fecha)
  VALUES (v_ped, v_cli, v_suc, 10000, 0, 'pendiente', 'pendiente', current_date);

  CREATE TABLE IF NOT EXISTS _test_fifo.caso (cliente_id bigint, pedido_id bigint);
  DELETE FROM _test_fifo.caso;
  INSERT INTO _test_fifo.caso VALUES (v_cli, v_ped);
  RETURN v_cli;
END;
$$;

-- El cobro. `p_demora` son los segundos que la sesion se queda DENTRO de la
-- transaccion con el lock tomado, para que la otra llegue a chocar.
CREATE OR REPLACE FUNCTION _test_fifo_cobrar(p_demora int DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_cli bigint;
  v_res jsonb;
BEGIN
  SELECT cliente_id INTO v_cli FROM _test_fifo.caso;

  -- Hay que hacerse pasar por un admin: las RPC miran auth.uid().
  PERFORM set_config('request.jwt.claims',
    json_build_object(
      'sub', (SELECT p.id::text FROM perfiles p
               JOIN usuario_sucursales us ON us.usuario_id = p.id AND us.es_default
              WHERE p.rol = 'admin' LIMIT 1),
      'role', 'authenticated')::text, true);

  IF p_demora > 0 THEN
    -- Toma el mismo lock que toma la RPC y lo retiene, para que la otra sesion
    -- se lo encuentre ocupado.
    PERFORM 1 FROM pedidos
     WHERE cliente_id = v_cli AND COALESCE(estado,'') NOT IN ('cancelado','anulado')
       AND total > COALESCE(monto_pagado,0)
     FOR UPDATE;
    PERFORM pg_sleep(p_demora);
  END IF;

  v_res := public.registrar_pago_cliente_fifo(v_cli, 10000, 'efectivo');
  RETURN v_res;
END;
$$;

-- -------------------------------------------------------------------------
-- Sesion A
-- -------------------------------------------------------------------------
BEGIN;
SELECT _test_fifo_preparar() AS cliente_de_prueba;
COMMIT;

\echo '>>> Corré AHORA en otra terminal, dentro de 5 s:'
\echo '>>>   psql "$URL_DE_PRUEBA" -c "SELECT _test_fifo_cobrar(0);"'

BEGIN;
SELECT _test_fifo_cobrar(5) AS cobro_a;
COMMIT;

-- -------------------------------------------------------------------------
-- Resultado. Con el FOR UPDATE de la mig 230 esto tiene que dar:
--   monto_pagado = 10000, suma_pagos_del_pedido = 10000, saldo_a_favor = 10000
-- Sin el FOR UPDATE da monto_pagado = 20000 y saldo_a_favor = 0.
-- -------------------------------------------------------------------------
SELECT p.total,
       p.monto_pagado,
       (SELECT COALESCE(SUM(pg.monto),0) FROM pagos pg WHERE pg.pedido_id = p.id) AS suma_pagos_del_pedido,
       (SELECT COALESCE(SUM(pg.monto),0) FROM pagos pg
         WHERE pg.cliente_id = p.cliente_id AND pg.pedido_id IS NULL)              AS saldo_a_favor,
       CASE WHEN p.monto_pagado = p.total
             AND (SELECT COALESCE(SUM(pg.monto),0) FROM pagos pg WHERE pg.pedido_id = p.id) = p.total
            THEN 'OK - no se sobrepago'
            ELSE 'FALLO - la boleta se pago dos veces'
       END AS veredicto
  FROM pedidos p
  JOIN _test_fifo.caso c ON c.pedido_id = p.id;

-- -------------------------------------------------------------------------
-- Limpieza
-- -------------------------------------------------------------------------
DELETE FROM pagos  WHERE cliente_id IN (SELECT cliente_id FROM _test_fifo.caso);
DELETE FROM pedidos WHERE id        IN (SELECT pedido_id  FROM _test_fifo.caso);
DELETE FROM clientes WHERE id       IN (SELECT cliente_id FROM _test_fifo.caso);
DROP FUNCTION IF EXISTS _test_fifo_cobrar(int);
DROP FUNCTION IF EXISTS _test_fifo_preparar();
DROP SCHEMA IF EXISTS _test_fifo CASCADE;
