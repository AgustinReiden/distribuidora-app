-- Adelanto de sueldo: una forma de pago que cancela deuda pero no es dinero (#832)
--
-- Un empleado (p. ej. un transportista) se lleva mercaderia; el sueldo no se lleva
-- en el sistema, asi que se registra el pago como `adelanto_sueldo` para saber a quien
-- hay que descontarle. Es un pago comun para el cliente (FIFO, saldo, monto_pagado:
-- todo eso mira `pagos.monto`, no la forma), pero NO es plata: no puede entrar a la
-- rendicion del transportista ni al control de efectivo, y tampoco puede caer en el
-- bucket `otros`, donde una forma desconocida termina por omision.
--
-- `pagos.forma_pago` es texto y su unico CHECK (pagos_forma_pago_no_cuenta_corriente)
-- excluye solo `cuenta_corriente`: el valor nuevo entra sin tocar el esquema. Las
-- RPCs de pago (registrar_pago_cliente_fifo_impl / registrar_pago_combinado_..._impl)
-- validan solo "no vacio", por eso tampoco cambian.
--
-- Lo que SI cambia son las tres RPCs de rendiciones, que agrupan `pagos` por forma:
--   * obtener_resumen_rendiciones: los adelantos salen de `pagos_agg` (ni total_general
--     ni ningun bucket) y se informan aparte en `total_adelanto_sueldo`. Cambia el tipo
--     de retorno (columna nueva) => DROP + CREATE, y se repite el grant (authenticated
--     + service_role, sin PUBLIC/anon, igual que la vigente).
--     La grilla (`fechas_activas`) NO se alimenta de los adelantos: un dia con solo
--     adelantos no genera fila de rendicion (los registra un admin/encargado, no el
--     transportista, y sino aparecerian filas fantasma a nombre de quien los cargo).
--     La columna informativa se ve en las filas que ya existen.
--   * obtener_detalle_rendicion y obtener_pagos_rendicion_cliente: excluyen los
--     adelantos, para que el detalle siga sumando el mismo total que la tarjeta.
--
-- Deliberadamente NO cambia:
--   * actualizar_forma_pago_pago: la lista blanca no incluye el valor nuevo. Cambiar a
--     mano un pago a adelanto lo sacaria de una rendicion ya controlada; se ofrece
--     solo al registrar, desde la ficha del cliente.
--   * reporte_gerencial: su `cobranza.formas` agrupa por la forma real y el adelanto
--     aparece como su propia linea (como vale_blanco), no dentro de efectivo.
--   * crear_rendicion_por_fecha / crear_rendicion_recorrido: leen pedidos.forma_pago,
--     que los pagos FIFO no tocan.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) obtener_resumen_rendiciones: excluye adelantos e informa el total aparte
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.obtener_resumen_rendiciones(date, date, uuid);

CREATE FUNCTION public.obtener_resumen_rendiciones(
  p_fecha_desde date DEFAULT ((((now() AT TIME ZONE 'America/Argentina/Buenos_Aires'::text))::date - '30 days'::interval))::date,
  p_fecha_hasta date DEFAULT (((now() AT TIME ZONE 'America/Argentina/Buenos_Aires'::text))::date),
  p_transportista_id uuid DEFAULT NULL::uuid
)
 RETURNS TABLE(fecha date, transportista_id uuid, transportista_nombre text, total_efectivo numeric, total_transferencia numeric, total_cheque numeric, total_cuenta_corriente numeric, total_tarjeta numeric, total_vale_blanco numeric, total_otros numeric, total_adelanto_sueldo numeric, total_general numeric, total_entregas numeric, total_ctascte numeric, cantidad_pedidos bigint, total_entregado numeric, total_gastos numeric, cantidad_gastos bigint, estado text, observaciones text, controlada boolean, controlada_at timestamp with time zone, controlada_por_nombre text, resuelta_at timestamp with time zone, resuelta_por_nombre text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal_id BIGINT;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no seleccionada';
  END IF;
  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  RETURN QUERY
  WITH pagos_agg AS (
    SELECT
      COALESCE(pd.transportista_id, pg.usuario_id) AS t_id,
      pg.fecha AS f,
      SUM(CASE WHEN pg.forma_pago = 'efectivo' THEN pg.monto ELSE 0 END)::numeric AS tot_ef,
      SUM(CASE WHEN pg.forma_pago = 'transferencia' THEN pg.monto ELSE 0 END)::numeric AS tot_tr,
      SUM(CASE WHEN pg.forma_pago = 'cheque' THEN pg.monto ELSE 0 END)::numeric AS tot_ch,
      SUM(CASE WHEN pg.forma_pago = 'cuenta_corriente' THEN pg.monto ELSE 0 END)::numeric AS tot_cc,
      SUM(CASE WHEN pg.forma_pago = 'tarjeta' THEN pg.monto ELSE 0 END)::numeric AS tot_tj,
      SUM(CASE WHEN pg.forma_pago = 'vale_blanco' THEN pg.monto ELSE 0 END)::numeric AS tot_vb,
      SUM(CASE WHEN pg.forma_pago NOT IN ('efectivo','transferencia','cheque','cuenta_corriente','tarjeta','vale_blanco')
                OR pg.forma_pago IS NULL THEN pg.monto ELSE 0 END)::numeric AS tot_ot,
      SUM(pg.monto)::numeric AS tot_gen,
      SUM(CASE
        WHEN pg.pedido_id IS NOT NULL
         AND pd.estado = 'entregado'
         AND COALESCE(pd.fecha_entrega::date, pg.fecha) = pg.fecha
        THEN pg.monto ELSE 0 END)::numeric AS tot_entregas,
      SUM(CASE
        WHEN pg.pedido_id IS NULL
          OR pd.estado IS DISTINCT FROM 'entregado'
          OR COALESCE(pd.fecha_entrega::date, pg.fecha) IS DISTINCT FROM pg.fecha
        THEN pg.monto ELSE 0 END)::numeric AS tot_ctascte
    FROM pagos pg
    LEFT JOIN pedidos pd ON pd.id = pg.pedido_id
    WHERE pg.fecha BETWEEN p_fecha_desde AND p_fecha_hasta
      AND pg.sucursal_id = v_sucursal_id
      -- mig 273 (#832): el adelanto de sueldo no es plata de la rendicion.
      AND pg.forma_pago IS DISTINCT FROM 'adelanto_sueldo'
      AND COALESCE(pd.transportista_id, pg.usuario_id) IS NOT NULL
      AND (p_transportista_id IS NULL
           OR COALESCE(pd.transportista_id, pg.usuario_id) = p_transportista_id)
    GROUP BY COALESCE(pd.transportista_id, pg.usuario_id), pg.fecha
  ),
  /* mig 273 (#832) · informativo: mismo criterio de atribucion que pagos_agg, pero NO
     aporta filas a fechas_activas (ver el encabezado de la migracion). */
  adelantos_agg AS (
    SELECT
      COALESCE(pd.transportista_id, pg.usuario_id) AS t_id,
      pg.fecha AS f,
      SUM(pg.monto)::numeric AS tot_adel
    FROM pagos pg
    LEFT JOIN pedidos pd ON pd.id = pg.pedido_id
    WHERE pg.fecha BETWEEN p_fecha_desde AND p_fecha_hasta
      AND pg.sucursal_id = v_sucursal_id
      AND pg.forma_pago = 'adelanto_sueldo'
      AND COALESCE(pd.transportista_id, pg.usuario_id) IS NOT NULL
      AND (p_transportista_id IS NULL
           OR COALESCE(pd.transportista_id, pg.usuario_id) = p_transportista_id)
    GROUP BY COALESCE(pd.transportista_id, pg.usuario_id), pg.fecha
  ),
  entregas_agg AS (
    SELECT
      pd.transportista_id AS t_id,
      pd.fecha_entrega::date AS f,
      SUM(pd.total)::numeric AS tot_entregado,
      COUNT(*)::bigint AS cant
    FROM pedidos pd
    WHERE pd.estado = 'entregado'
      AND pd.fecha_entrega IS NOT NULL
      AND pd.transportista_id IS NOT NULL
      AND pd.fecha_entrega::date BETWEEN p_fecha_desde AND p_fecha_hasta
      AND pd.sucursal_id = v_sucursal_id
      AND (p_transportista_id IS NULL OR pd.transportista_id = p_transportista_id)
    GROUP BY pd.transportista_id, pd.fecha_entrega::date
  ),
  gastos_agg AS (
    SELECT
      rg.transportista_id AS t_id,
      rg.fecha AS f,
      SUM(rg.monto)::numeric AS tot_g,
      COUNT(*)::bigint AS cant_g
    FROM rendicion_gastos rg
    WHERE rg.fecha BETWEEN p_fecha_desde AND p_fecha_hasta
      AND rg.sucursal_id = v_sucursal_id
      AND (p_transportista_id IS NULL OR rg.transportista_id = p_transportista_id)
    GROUP BY rg.transportista_id, rg.fecha
  ),
  /* mig 245 (#639) · fechas_activas es el esqueleto de la grilla. gastos_agg ya
     estaba calculado y LEFT-JOINeado abajo, pero no aportaba filas: un
     transportista que un dia solo cargo gastos --sin cobrar ni entregar-- no
     aparecia, y su rendicion de ese dia era invisible para el control. */
  fechas_activas AS (
    SELECT t_id, f FROM pagos_agg
    UNION
    SELECT t_id, f FROM entregas_agg
    UNION
    SELECT t_id, f FROM gastos_agg
  )
  SELECT
    fa.f::date AS fecha,
    fa.t_id AS transportista_id,
    tr.nombre::text AS transportista_nombre,
    COALESCE(pagos_agg.tot_ef, 0)::numeric AS total_efectivo,
    COALESCE(pagos_agg.tot_tr, 0)::numeric AS total_transferencia,
    COALESCE(pagos_agg.tot_ch, 0)::numeric AS total_cheque,
    COALESCE(pagos_agg.tot_cc, 0)::numeric AS total_cuenta_corriente,
    COALESCE(pagos_agg.tot_tj, 0)::numeric AS total_tarjeta,
    COALESCE(pagos_agg.tot_vb, 0)::numeric AS total_vale_blanco,
    COALESCE(pagos_agg.tot_ot, 0)::numeric AS total_otros,
    COALESCE(adelantos_agg.tot_adel, 0)::numeric AS total_adelanto_sueldo,
    COALESCE(pagos_agg.tot_gen, 0)::numeric AS total_general,
    COALESCE(pagos_agg.tot_entregas, 0)::numeric AS total_entregas,
    COALESCE(pagos_agg.tot_ctascte, 0)::numeric AS total_ctascte,
    COALESCE(entregas_agg.cant, 0)::bigint AS cantidad_pedidos,
    COALESCE(entregas_agg.tot_entregado, 0)::numeric AS total_entregado,
    COALESCE(gastos_agg.tot_g, 0)::numeric AS total_gastos,
    COALESCE(gastos_agg.cant_g, 0)::bigint AS cantidad_gastos,
    COALESCE(rc.estado, 'pendiente')::text AS estado,
    rc.observaciones,
    (rc.id IS NOT NULL AND COALESCE(rc.estado, 'pendiente') IN ('confirmada','resuelta')) AS controlada,
    rc.controlada_at,
    cp.nombre::text AS controlada_por_nombre,
    rc.resuelta_at,
    rp.nombre::text AS resuelta_por_nombre
  FROM fechas_activas fa
  JOIN perfiles tr ON tr.id = fa.t_id
  LEFT JOIN pagos_agg ON pagos_agg.t_id = fa.t_id AND pagos_agg.f = fa.f
  LEFT JOIN adelantos_agg ON adelantos_agg.t_id = fa.t_id AND adelantos_agg.f = fa.f
  LEFT JOIN entregas_agg ON entregas_agg.t_id = fa.t_id AND entregas_agg.f = fa.f
  LEFT JOIN gastos_agg ON gastos_agg.t_id = fa.t_id AND gastos_agg.f = fa.f
  LEFT JOIN rendiciones_control rc
    ON rc.fecha = fa.f
   AND rc.transportista_id = fa.t_id
   AND rc.sucursal_id = v_sucursal_id
  LEFT JOIN perfiles cp ON cp.id = rc.controlada_por
  LEFT JOIN perfiles rp ON rp.id = rc.resuelta_por
  ORDER BY fa.f DESC, tr.nombre ASC;
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_resumen_rendiciones(date, date, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.obtener_resumen_rendiciones(date, date, uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2) obtener_detalle_rendicion: los adelantos no son parte del detalle
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_detalle_rendicion(p_fecha date, p_transportista_id uuid)
 RETURNS TABLE(cliente_id bigint, cliente_nombre text, cobrado_por_id uuid, cobrado_por text, total numeric, total_entregas numeric, total_ctascte numeric, efectivo numeric, transferencia numeric, cheque numeric, tarjeta numeric, vale_blanco numeric, cuenta_corriente numeric, otros numeric, cantidad_pagos bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal_id bigint;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no seleccionada';
  END IF;
  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  RETURN QUERY
  SELECT
    pg.cliente_id::bigint AS cliente_id,
    COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social, 'Cliente #' || pg.cliente_id)::text AS cliente_nombre,
    pg.usuario_id AS cobrado_por_id,
    COALESCE(u.nombre, 'Sin usuario')::text AS cobrado_por,
    SUM(pg.monto)::numeric AS total,
    SUM(CASE
      WHEN pg.pedido_id IS NOT NULL
       AND pd.estado = 'entregado'
       AND COALESCE(pd.fecha_entrega::date, pg.fecha) = pg.fecha
      THEN pg.monto ELSE 0 END)::numeric AS total_entregas,
    SUM(CASE
      WHEN pg.pedido_id IS NULL
        OR pd.estado IS DISTINCT FROM 'entregado'
        OR COALESCE(pd.fecha_entrega::date, pg.fecha) IS DISTINCT FROM pg.fecha
      THEN pg.monto ELSE 0 END)::numeric AS total_ctascte,
    SUM(CASE WHEN pg.forma_pago = 'efectivo' THEN pg.monto ELSE 0 END)::numeric AS efectivo,
    SUM(CASE WHEN pg.forma_pago = 'transferencia' THEN pg.monto ELSE 0 END)::numeric AS transferencia,
    SUM(CASE WHEN pg.forma_pago = 'cheque' THEN pg.monto ELSE 0 END)::numeric AS cheque,
    SUM(CASE WHEN pg.forma_pago = 'tarjeta' THEN pg.monto ELSE 0 END)::numeric AS tarjeta,
    SUM(CASE WHEN pg.forma_pago = 'vale_blanco' THEN pg.monto ELSE 0 END)::numeric AS vale_blanco,
    SUM(CASE WHEN pg.forma_pago = 'cuenta_corriente' THEN pg.monto ELSE 0 END)::numeric AS cuenta_corriente,
    SUM(CASE WHEN pg.forma_pago NOT IN ('efectivo','transferencia','cheque','tarjeta','vale_blanco','cuenta_corriente')
              OR pg.forma_pago IS NULL THEN pg.monto ELSE 0 END)::numeric AS otros,
    COUNT(*)::bigint AS cantidad_pagos
  FROM pagos pg
  LEFT JOIN pedidos pd ON pd.id = pg.pedido_id
  LEFT JOIN clientes c ON c.id = pg.cliente_id
  LEFT JOIN perfiles u ON u.id = pg.usuario_id
  WHERE pg.fecha = p_fecha
    AND pg.sucursal_id = v_sucursal_id
    -- mig 273 (#832): el adelanto de sueldo no es plata de la rendicion.
    AND pg.forma_pago IS DISTINCT FROM 'adelanto_sueldo'
    AND COALESCE(pd.transportista_id, pg.usuario_id) = p_transportista_id
  GROUP BY pg.cliente_id, c.nombre_fantasia, c.razon_social, pg.usuario_id, u.nombre
  ORDER BY SUM(pg.monto) DESC;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3) obtener_pagos_rendicion_cliente: idem, para que el drill-down cierre con el detalle
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_pagos_rendicion_cliente(p_fecha date, p_transportista_id uuid, p_cliente_id bigint)
 RETURNS TABLE(pago_id bigint, created_at timestamp with time zone, monto numeric, forma_pago text, referencia text, notas text, pedido_id bigint, pedido_fecha date, pedido_estado text, pedido_total numeric, cobrado_por text, es_entrega_del_dia boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal_id bigint;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no seleccionada';
  END IF;
  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  RETURN QUERY
  SELECT
    pg.id::bigint AS pago_id,
    pg.created_at,
    pg.monto::numeric AS monto,
    pg.forma_pago::text AS forma_pago,
    pg.referencia::text AS referencia,
    pg.notas::text AS notas,
    pg.pedido_id::bigint AS pedido_id,
    pd.fecha AS pedido_fecha,
    pd.estado::text AS pedido_estado,
    pd.total::numeric AS pedido_total,
    COALESCE(u.nombre, 'Sin usuario')::text AS cobrado_por,
    (pg.pedido_id IS NOT NULL
     AND pd.estado = 'entregado'
     AND COALESCE(pd.fecha_entrega::date, pg.fecha) = pg.fecha) AS es_entrega_del_dia
  FROM pagos pg
  LEFT JOIN pedidos pd ON pd.id = pg.pedido_id
  LEFT JOIN perfiles u ON u.id = pg.usuario_id
  WHERE pg.fecha = p_fecha
    AND pg.sucursal_id = v_sucursal_id
    AND pg.cliente_id = p_cliente_id
    -- mig 273 (#832): el adelanto de sueldo no es plata de la rendicion.
    AND pg.forma_pago IS DISTINCT FROM 'adelanto_sueldo'
    AND COALESCE(pd.transportista_id, pg.usuario_id) = p_transportista_id
  ORDER BY pg.created_at ASC, pg.id ASC;
END;
$function$;

COMMIT;
