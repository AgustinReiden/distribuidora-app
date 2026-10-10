-- #1044 · El resumen de cuenta del front no cuenta los cancelados, y
-- obtener_estadisticas_pedidos se va.
--
-- 1 · obtener_resumen_cuenta_cliente (la del front) contaba los pedidos
--     cancelados en total_pedidos, total_compras, pedidos_pendientes_pago y
--     ultimo_pedido; su copia _bot (324) ya los excluía. Hoy el front sólo lee
--     saldo_actual, así que no se veía en ninguna pantalla, pero las dos copias
--     decían cosas distintas del mismo cliente (cliente 253: 35 pedidos contra
--     32). Se copia el predicado de la _bot, también el `IS DISTINCT FROM` de
--     estado_pago. consumo_interno sigue distinto a propósito (332).
--
-- 2 · obtener_estadisticas_pedidos no tiene caller. La 314 la dejó sólo para
--     service_role, y con service_role current_sucursal_id() da NULL, así que
--     tiraba "No hay sucursal activa" y no corría desde ningún lado. Se borra.
--
-- Ensayo: scripts/test-resumen-cuenta-1044.sql (falla antes, pasa después).

BEGIN;

CREATE OR REPLACE FUNCTION public._mig1044_ancla(
  p_funcion regprocedure, p_ancla text, p_nuevo text
) RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text;
  v_veces int;
BEGIN
  v_def := pg_get_functiondef(p_funcion);
  v_veces := (length(v_def) - length(replace(v_def, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El ancla aparece % veces en % (se esperaba exactamente 1). El cuerpo vivo cambio: revisar a mano. Ancla: %',
      v_veces, p_funcion, left(p_ancla, 120);
  END IF;
  EXECUTE replace(v_def, p_ancla, p_nuevo);
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 1 · obtener_resumen_cuenta_cliente: los cancelados no cuentan.
-- ---------------------------------------------------------------------------
SELECT public._mig1044_ancla('public.obtener_resumen_cuenta_cliente(integer)'::regprocedure,
$ancla$  -- Un canje (canal 'cambio', total 0) no es un pedido del cliente: no cuenta en
  -- pedidos, compras, pendientes de pago ni en la fecha del ultimo (326, #1033).$ancla$,
$nuevo$  -- Un canje (canal 'cambio', total 0) no es un pedido del cliente: no cuenta en
  -- pedidos, compras, pendientes de pago ni en la fecha del ultimo (326, #1033).
  -- Un pedido cancelado tampoco, igual que en la copia _bot (#1044).$nuevo$);

SELECT public._mig1044_ancla('public.obtener_resumen_cuenta_cliente(integer)'::regprocedure,
$ancla$    'total_pedidos', (SELECT COUNT(*) FROM pedidos
                       WHERE cliente_id = p_cliente_id AND canal <> 'cambio'$ancla$,
$nuevo$    'total_pedidos', (SELECT COUNT(*) FROM pedidos
                       WHERE cliente_id = p_cliente_id AND estado IS DISTINCT FROM 'cancelado'
                         AND canal <> 'cambio'$nuevo$);

SELECT public._mig1044_ancla('public.obtener_resumen_cuenta_cliente(integer)'::regprocedure,
$ancla$    'total_compras', (SELECT COALESCE(SUM(total), 0) FROM pedidos
                       WHERE cliente_id = p_cliente_id AND canal <> 'cambio'$ancla$,
$nuevo$    'total_compras', (SELECT COALESCE(SUM(total), 0) FROM pedidos
                       WHERE cliente_id = p_cliente_id AND estado IS DISTINCT FROM 'cancelado'
                         AND canal <> 'cambio'$nuevo$);

SELECT public._mig1044_ancla('public.obtener_resumen_cuenta_cliente(integer)'::regprocedure,
$ancla$    'pedidos_pendientes_pago', (SELECT COUNT(*) FROM pedidos WHERE cliente_id = p_cliente_id
                                  AND canal <> 'cambio' AND estado_pago != 'pagado'),$ancla$,
$nuevo$    'pedidos_pendientes_pago', (SELECT COUNT(*) FROM pedidos WHERE cliente_id = p_cliente_id
                                  AND estado IS DISTINCT FROM 'cancelado'
                                  AND canal <> 'cambio' AND estado_pago IS DISTINCT FROM 'pagado'),$nuevo$);

SELECT public._mig1044_ancla('public.obtener_resumen_cuenta_cliente(integer)'::regprocedure,
$ancla$    'ultimo_pedido', (SELECT MAX(created_at) FROM pedidos
                       WHERE cliente_id = p_cliente_id AND canal <> 'cambio'$ancla$,
$nuevo$    'ultimo_pedido', (SELECT MAX(created_at) FROM pedidos
                       WHERE cliente_id = p_cliente_id AND estado IS DISTINCT FROM 'cancelado'
                         AND canal <> 'cambio'$nuevo$);

-- CREATE OR REPLACE conserva los privilegios; se reafirman igual.
REVOKE ALL ON FUNCTION public.obtener_resumen_cuenta_cliente(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.obtener_resumen_cuenta_cliente(integer) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2 · obtener_estadisticas_pedidos: sin caller, se borra.
-- ---------------------------------------------------------------------------
DROP FUNCTION public.obtener_estadisticas_pedidos(timestamp with time zone, timestamp with time zone, uuid);

DROP FUNCTION public._mig1044_ancla(regprocedure, text, text);

COMMIT;
