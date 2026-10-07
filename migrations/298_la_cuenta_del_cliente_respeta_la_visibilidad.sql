-- #973 · obtener_resumen_cuenta_cliente: la cuenta sólo la lee quien ve al cliente
--
-- La RPC es SECURITY DEFINER, así que la RLS de `clientes` no la alcanza, y su
-- único chequeo era `auth.uid() IS NULL`: cualquier sesión, un preventista por
-- REST por ejemplo, leía saldo, crédito, total comprado y pagos de cualquier
-- cliente de cualquier sucursal pasando el id.
--
-- Ahora la función aplica adentro el mismo predicado que `mt_clientes_select`:
--   * sucursal actual (`current_sucursal_id()`);
--   * si el rol PRINCIPAL es preventista (`perfiles.rol`, igual que la política;
--     NO `es_preventista()`, que también da true para admin y encargado):
--       - asignado a él o sin asignar (sin asignar = visible para todos, mig 028), y
--       - `reservado_admin` sólo si ya le vendió (mig 214).
-- Si el cliente no es visible —o no existe— corta con 42501. El front ante un
-- error cae a leer por tablas, que sí pasan por la RLS, así que tampoco ahí ve
-- lo ajeno.
--
-- El predicado está copiado de la política, no compartido: si cambia uno, cambia
-- el otro. La copia `_bot` no se toca (sólo la ejecuta service_role).

CREATE OR REPLACE FUNCTION public.obtener_resumen_cuenta_cliente(p_cliente_id integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  resultado JSON;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN json_build_object('error', 'No autenticado');
  END IF;

  -- Mismo predicado que la política mt_clientes_select (ver cabecera).
  IF NOT EXISTS (
    SELECT 1 FROM clientes c
    WHERE c.id = p_cliente_id
      AND c.sucursal_id = current_sucursal_id()
      AND (
        NOT EXISTS (SELECT 1 FROM perfiles p WHERE p.id = auth.uid() AND p.rol = 'preventista')
        OR (
          (
            NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id)
            OR EXISTS (SELECT 1 FROM cliente_preventistas cp
                       WHERE cp.cliente_id = c.id AND cp.preventista_id = auth.uid())
          )
          AND (
            NOT c.reservado_admin
            OR EXISTS (SELECT 1 FROM pedidos pe
                       WHERE pe.cliente_id = c.id AND pe.usuario_id = auth.uid())
          )
        )
      )
  ) THEN
    RAISE EXCEPTION 'Cliente % no encontrado o sin permiso para ver su cuenta', p_cliente_id
      USING ERRCODE = '42501';
  END IF;

  SELECT json_build_object(
    'saldo_actual', COALESCE(c.saldo_cuenta, 0),
    'limite_credito', COALESCE(c.limite_credito, 0),
    'credito_disponible', COALESCE(c.limite_credito, 0) - COALESCE(c.saldo_cuenta, 0),
    'total_pedidos', (SELECT COUNT(*) FROM pedidos WHERE cliente_id = p_cliente_id),
    'total_compras', (SELECT COALESCE(SUM(total), 0) FROM pedidos WHERE cliente_id = p_cliente_id),
    'total_pagos', (SELECT COALESCE(SUM(monto), 0) FROM pagos WHERE cliente_id = p_cliente_id),
    'pedidos_pendientes_pago', (SELECT COUNT(*) FROM pedidos WHERE cliente_id = p_cliente_id AND estado_pago != 'pagado'),
    'ultimo_pedido', (SELECT MAX(created_at) FROM pedidos WHERE cliente_id = p_cliente_id),
    'ultimo_pago', (SELECT MAX(created_at) FROM pagos WHERE cliente_id = p_cliente_id)
  ) INTO resultado
  FROM clientes c
  WHERE c.id = p_cliente_id;

  RETURN resultado;
END;
$function$;

-- CREATE OR REPLACE conserva el ACL; se reafirma igual para que la migración
-- sea la fuente de verdad (hoy: postgres, authenticated, service_role).
REVOKE EXECUTE ON FUNCTION public.obtener_resumen_cuenta_cliente(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.obtener_resumen_cuenta_cliente(integer) TO authenticated;
