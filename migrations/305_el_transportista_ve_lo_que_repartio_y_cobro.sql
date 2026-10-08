-- =========================================================================
-- 305_el_transportista_ve_lo_que_repartio_y_cobro.sql   (#723, #724)
--
-- Un transportista puro hoy no tiene pantalla propia fuera del mapa de la
-- ruta: "Mis entregas" le sale vacía y "Rendiciones" le contesta 'No
-- autorizado'. Esta migración le da las dos lecturas, sin cambiar lo que
-- ven admin, encargado y preventista.
--
-- 1) "Mis entregas" del transportista (#723): dos funciones NUEVAS,
--    `jornadas_transportista` y `jornada_transportista_detalle`, gemelas de
--    `jornadas_preventista` / `jornada_preventista_detalle` (mig 179, con el
--    ajuste de 'falta_stock' de la 269). Misma forma de salida, así la
--    pantalla reutiliza tarjetas y filas. Lo único que cambia es QUIÉN es el
--    dueño del pedido: `pedidos.transportista_id` en lugar de `usuario_id`.
--
--    Por qué `pedidos.transportista_id` y no `recorrido_pedidos`:
--    - `recorrido_pedidos` no guarda los rechazos. En prod, de 154 cancelados
--      de los últimos 90 días, NINGUNO está en un recorrido (los estados de
--      `recorrido_pedidos.estado_entrega` son sólo 'entregado' y
--      'pendiente'); 130 de esos 154 sí tienen `transportista_id`. Un panel
--      cuyo punto es "qué no llegó a destino" no puede salir de una tabla
--      que no tiene los que no llegaron.
--    - Cuando un pedido cambia de chofer después de armar el recorrido, el
--      recorrido queda con el chofer viejo y `transportista_id` con el que lo
--      llevó: 54 entregados de nachovir figuran en recorridos de Marcos, con
--      124 cambios de `transportista_id` en el historial.
--    - Es el mismo criterio con el que `obtener_resumen_rendiciones` le
--      atribuye las entregas a cada transportista (`entregas_agg`), así que
--      "lo que repartí" y "lo que rindo" cuentan los mismos pedidos.
--
--    Guard de rol: además del contrato de 179 (null = yo; otro id sólo para
--    admin/encargado), quien pregunta tiene que ser transportista o
--    admin/encargado. Ojo, trampa 4 de CLAUDE.md: `es_transportista()` es
--    true también para admin y para quien tiene el rol extra en
--    `perfil_roles`. Acá eso es lo que se quiere (el admin entra igual por
--    `es_encargado_o_admin()`, y el preventista que acompaña al camión ve lo
--    que repartió); lo que el guard deja afuera es al preventista puro y a
--    depósito.
--
--    El detalle trae `vendedor` (quién tomó el pedido) en lugar de
--    `transportista`, que acá sería siempre uno mismo.
--
-- 2) Cobros del transportista (#724): `obtener_resumen_rendiciones`,
--    `obtener_detalle_rendicion` y `obtener_pagos_rendicion_cliente` ganan
--    una rama "si sos transportista, sólo tu propia fila", con el patrón de
--    `avance_metas_preventista`: `p_transportista_id` null = yo; otro id da
--    42501. Para admin y encargado el cuerpo es el de producción, renglón
--    por renglón: la rama sólo corre cuando `es_encargado_o_admin()` es
--    false. El resto de los roles sigue recibiendo el 'No autorizado' de
--    siempre. Las RPC que ESCRIBEN (marcar/confirmar/resolver) no se tocan.
--
--    La fila del transportista es la misma que ve el admin para él: la
--    atribución de cada pago (`COALESCE(pd.transportista_id, pg.usuario_id)`)
--    no cambia.
--
-- Funciones nuevas: `REVOKE ... FROM PUBLIC, anon` en esta misma migración
-- (CLAUDE.md). Las reemplazadas conservan sus grants (CREATE OR REPLACE no
-- los toca). Una firma por función: nada de sobrecargas (PGRST203).
--
-- Sólo lectura. No toca ninguna fila. Idempotente (CREATE OR REPLACE).
-- =========================================================================

-- -------------------------------------------------------------------------
-- 1a. Resumen por día de lo que repartió el transportista
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.jornadas_transportista(
  p_desde            date,
  p_hasta            date,
  p_transportista_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_target    uuid;
  v_nombre    text;
  v_sucursal  bigint;
  v_dias      jsonb;
  v_pend      jsonb;
  v_totales   jsonb;
BEGIN
  v_target := COALESCE(p_transportista_id, auth.uid());

  IF v_target IS NULL THEN
    RAISE EXCEPTION 'Sin usuario' USING ERRCODE = '42501';
  END IF;

  IF auth.uid() IS NOT NULL THEN
    IF v_target <> auth.uid() AND NOT es_encargado_o_admin() THEN
      RAISE EXCEPTION 'Acceso denegado' USING ERRCODE = '42501';
    END IF;
    -- es_transportista() incluye admin y rol extra (trampa 4): ver encabezado.
    IF NOT (es_transportista() OR es_encargado_o_admin()) THEN
      RAISE EXCEPTION 'Acceso denegado' USING ERRCODE = '42501';
    END IF;
  END IF;

  IF p_desde IS NULL OR p_hasta IS NULL OR p_hasta < p_desde THEN
    RAISE EXCEPTION 'Rango de fechas invalido' USING ERRCODE = '22007';
  END IF;

  v_sucursal := current_sucursal_id();

  SELECT nombre INTO v_nombre FROM perfiles WHERE id = v_target;

  -- Mismo cálculo de día, desenlace y monto que jornadas_preventista (179).
  WITH resueltos AS (
    SELECT
      CASE
        WHEN p.estado = 'entregado' THEN
          COALESCE((p.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date,
                   (SELECT (h.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
                      FROM pedido_historial h
                     WHERE h.pedido_id = p.id
                       AND h.campo_modificado = 'estado'
                       AND h.valor_nuevo = 'entregado'
                     ORDER BY h.created_at DESC
                     LIMIT 1),
                   p.fecha)
        ELSE
          COALESCE((SELECT (h.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
                      FROM pedido_historial h
                     WHERE h.pedido_id = p.id
                       AND h.campo_modificado = 'estado'
                       AND h.valor_nuevo LIKE 'cancelado%'
                     ORDER BY h.created_at DESC
                     LIMIT 1),
                   p.fecha)
      END AS dia,
      CASE
        WHEN p.estado = 'entregado'
             AND EXISTS (SELECT 1 FROM salvedades_items s
                          WHERE s.pedido_id = p.id
                            AND s.estado_resolucion <> 'anulada')
          THEN 'entregado_con_salvedad'
        WHEN p.estado = 'entregado' THEN 'entregado'
        WHEN p.motivo_cancelacion_tipo IN
             ('error_de_carga','prueba','duplicado','unifica_pedidos','cambio_de_cliente','falta_stock')
          THEN 'administrativo'
        ELSE 'rechazado'
      END AS desenlace,
      CASE WHEN p.estado = 'cancelado'
        THEN COALESCE(NULLIF(p.total, 0), NULLIF(p.total_real, 0),
                      (SELECT COALESCE(SUM(pi.subtotal), 0) FROM pedido_items pi
                        WHERE pi.pedido_id = p.id))
        ELSE p.total
      END AS monto
    FROM pedidos p
    WHERE p.transportista_id = v_target
      AND p.sucursal_id      = v_sucursal
      AND p.canal <> 'cambio'
      AND p.estado IN ('entregado','cancelado')
      AND p.fecha >= (p_desde - 90)
      AND p.fecha <= p_hasta
  ),
  del_rango AS (
    SELECT * FROM resueltos WHERE dia BETWEEN p_desde AND p_hasta
  ),
  por_dia AS (
    SELECT
      dia,
      COUNT(*)                                                        AS total,
      COUNT(*) FILTER (WHERE desenlace LIKE 'entregado%')             AS entregados,
      COUNT(*) FILTER (WHERE desenlace = 'entregado_con_salvedad')    AS con_salvedad,
      COUNT(*) FILTER (WHERE desenlace = 'rechazado')                 AS rechazados,
      COUNT(*) FILTER (WHERE desenlace = 'administrativo')            AS administrativos,
      COALESCE(SUM(monto) FILTER (WHERE desenlace LIKE 'entregado%'), 0) AS monto_entregado,
      COALESCE(SUM(monto) FILTER (WHERE desenlace = 'rechazado'), 0)     AS monto_rechazado
    FROM del_rango
    GROUP BY dia
  )
  SELECT
    COALESCE(jsonb_agg(jsonb_build_object(
      'dia',             d.dia,
      'total',           d.total,
      'entregados',      d.entregados,
      'con_salvedad',    d.con_salvedad,
      'rechazados',      d.rechazados,
      'administrativos', d.administrativos,
      'monto_entregado', d.monto_entregado,
      'monto_rechazado', d.monto_rechazado
    ) ORDER BY d.dia DESC), '[]'::jsonb),
    jsonb_build_object(
      'entregados',  COALESCE(SUM(d.entregados), 0),
      'rechazados',  COALESCE(SUM(d.rechazados), 0),
      'pct_rechazo', CASE
        WHEN COALESCE(SUM(d.entregados), 0) + COALESCE(SUM(d.rechazados), 0) = 0 THEN 0
        ELSE ROUND(100.0 * SUM(d.rechazados) / (SUM(d.entregados) + SUM(d.rechazados)), 1)
      END,
      'monto_rechazado', COALESCE(SUM(d.monto_rechazado), 0)
    )
  INTO v_dias, v_totales
  FROM por_dia d;

  -- Pendientes: asignados a él y todavía sin desenlace.
  SELECT jsonb_build_object(
    'total',     COUNT(*),
    'monto',     COALESCE(SUM(p.total), 0),
    'mas_viejo', MIN(p.fecha)
  )
  INTO v_pend
  FROM pedidos p
  WHERE p.transportista_id = v_target
    AND p.sucursal_id      = v_sucursal
    AND p.canal <> 'cambio'
    AND p.estado NOT IN ('entregado','cancelado');

  RETURN jsonb_build_object(
    'transportista_id', v_target,
    'nombre',           v_nombre,
    'desde',            p_desde,
    'hasta',            p_hasta,
    'dias',             v_dias,
    'totales',          v_totales,
    'pendientes',       v_pend
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.jornadas_transportista(date, date, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.jornadas_transportista(date, date, uuid) TO authenticated;

-- -------------------------------------------------------------------------
-- 1b. Detalle de un día (p_dia null = los asignados sin desenlace)
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.jornada_transportista_detalle(
  p_dia              date,
  p_transportista_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_target   uuid;
  v_sucursal bigint;
  v_out      jsonb;
BEGIN
  v_target := COALESCE(p_transportista_id, auth.uid());

  IF v_target IS NULL THEN
    RAISE EXCEPTION 'Sin usuario' USING ERRCODE = '42501';
  END IF;

  IF auth.uid() IS NOT NULL THEN
    IF v_target <> auth.uid() AND NOT es_encargado_o_admin() THEN
      RAISE EXCEPTION 'Acceso denegado' USING ERRCODE = '42501';
    END IF;
    -- es_transportista() incluye admin y rol extra (trampa 4): ver encabezado.
    IF NOT (es_transportista() OR es_encargado_o_admin()) THEN
      RAISE EXCEPTION 'Acceso denegado' USING ERRCODE = '42501';
    END IF;
  END IF;

  v_sucursal := current_sucursal_id();

  WITH candidatos AS (
    SELECT
      p.*,
      CASE
        WHEN p.estado = 'entregado' THEN
          COALESCE((p.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date,
                   (SELECT (h.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
                      FROM pedido_historial h
                     WHERE h.pedido_id = p.id
                       AND h.campo_modificado = 'estado'
                       AND h.valor_nuevo = 'entregado'
                     ORDER BY h.created_at DESC
                     LIMIT 1),
                   p.fecha)
        WHEN p.estado = 'cancelado' THEN
          COALESCE((SELECT (h.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
                      FROM pedido_historial h
                     WHERE h.pedido_id = p.id
                       AND h.campo_modificado = 'estado'
                       AND h.valor_nuevo LIKE 'cancelado%'
                     ORDER BY h.created_at DESC
                     LIMIT 1),
                   p.fecha)
        ELSE NULL
      END AS dia
    FROM pedidos p
    WHERE p.transportista_id = v_target
      AND p.sucursal_id      = v_sucursal
      AND p.canal <> 'cambio'
      AND (
        (p_dia IS NOT NULL
         AND p.estado IN ('entregado','cancelado')
         AND p.fecha BETWEEN (p_dia - 90) AND p_dia)
        OR (p_dia IS NULL AND p.estado NOT IN ('entregado','cancelado'))
      )
  ),
  filtrados AS (
    SELECT * FROM candidatos
    WHERE (p_dia IS NULL AND dia IS NULL) OR dia = p_dia
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'pedido_id', f.id,
    'cliente',   COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social, 'Cliente'),
    'monto',     CASE WHEN f.estado = 'cancelado'
                   THEN COALESCE(NULLIF(f.total, 0), NULLIF(f.total_real, 0),
                                 (SELECT COALESCE(SUM(pi.subtotal), 0) FROM pedido_items pi
                                   WHERE pi.pedido_id = f.id))
                   ELSE f.total END,
    'desenlace', CASE
      WHEN f.estado = 'entregado'
           AND EXISTS (SELECT 1 FROM salvedades_items s
                        WHERE s.pedido_id = f.id AND s.estado_resolucion <> 'anulada')
        THEN 'entregado_con_salvedad'
      WHEN f.estado = 'entregado' THEN 'entregado'
      WHEN f.estado = 'cancelado'
           AND f.motivo_cancelacion_tipo IN
               ('error_de_carga','prueba','duplicado','unifica_pedidos','cambio_de_cliente','falta_stock')
        THEN 'administrativo'
      WHEN f.estado = 'cancelado' THEN 'rechazado'
      ELSE 'pendiente'
    END,
    'estado',        f.estado,
    'fecha_pedido',  f.fecha,
    'motivo_tipo',   f.motivo_cancelacion_tipo,
    'motivo_nota',   NULLIF(btrim(COALESCE(f.motivo_cancelacion, '')), ''),
    -- Acá el transportista es uno mismo: lo que informa es quién vendió.
    'transportista', NULL,
    'vendedor',      ve.nombre,
    'salvedades', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'producto',          pr.nombre,
        'cantidad_afectada', s.cantidad_afectada,
        'cantidad_original', s.cantidad_original,
        'motivo',            s.motivo,
        'descripcion',       NULLIF(btrim(COALESCE(s.descripcion, '')), ''),
        'monto_afectado',    s.monto_afectado
      ) ORDER BY pr.nombre), '[]'::jsonb)
      FROM salvedades_items s
      JOIN productos pr ON pr.id = s.producto_id
      WHERE s.pedido_id = f.id AND s.estado_resolucion <> 'anulada'
    )
  ) ORDER BY f.id DESC), '[]'::jsonb)
  INTO v_out
  FROM filtrados f
  LEFT JOIN clientes c ON c.id = f.cliente_id
  LEFT JOIN perfiles ve ON ve.id = f.usuario_id;

  RETURN v_out;
END;
$function$;

REVOKE ALL ON FUNCTION public.jornada_transportista_detalle(date, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.jornada_transportista_detalle(date, uuid) TO authenticated;

-- -------------------------------------------------------------------------
-- 2a. Resumen de rendiciones: rama del transportista (#724)
--     Cuerpo de producción (migs 245/273/276) sin cambios debajo del guard.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_resumen_rendiciones(p_fecha_desde date DEFAULT ((((now() AT TIME ZONE 'America/Argentina/Buenos_Aires'::text))::date - '30 days'::interval))::date, p_fecha_hasta date DEFAULT ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires'::text))::date, p_transportista_id uuid DEFAULT NULL::uuid)
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
    -- #724: el transportista ve sólo su propia fila (null = yo, como
    -- avance_metas_preventista). es_transportista() incluye admin y rol
    -- extra (trampa 4); el admin ya entró por la rama de arriba.
    IF NOT es_transportista() THEN
      RAISE EXCEPTION 'No autorizado';
    END IF;
    IF p_transportista_id IS NOT NULL AND p_transportista_id <> auth.uid() THEN
      RAISE EXCEPTION 'Acceso denegado' USING ERRCODE = '42501';
    END IF;
    p_transportista_id := auth.uid();
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
      -- migs 273/276 (#832, #833): las formas no dinerarias no son plata de la rendicion.
      AND COALESCE(pg.forma_pago, '') NOT IN ('adelanto_sueldo', 'nota_credito')
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

-- -------------------------------------------------------------------------
-- 2b. Detalle por cliente de una rendición: rama del transportista
-- -------------------------------------------------------------------------
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
    -- #724: el transportista sólo abre su propia rendición.
    IF NOT es_transportista() THEN
      RAISE EXCEPTION 'No autorizado';
    END IF;
    IF p_transportista_id IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION 'Acceso denegado' USING ERRCODE = '42501';
    END IF;
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
    -- migs 273/276 (#832, #833): las formas no dinerarias no son plata de la rendicion.
    AND COALESCE(pg.forma_pago, '') NOT IN ('adelanto_sueldo', 'nota_credito')
    AND COALESCE(pd.transportista_id, pg.usuario_id) = p_transportista_id
  GROUP BY pg.cliente_id, c.nombre_fantasia, c.razon_social, pg.usuario_id, u.nombre
  ORDER BY SUM(pg.monto) DESC;
END;
$function$;

-- -------------------------------------------------------------------------
-- 2c. Pagos de un cliente dentro de una rendición: rama del transportista
-- -------------------------------------------------------------------------
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
    -- #724: el transportista sólo abre su propia rendición.
    IF NOT es_transportista() THEN
      RAISE EXCEPTION 'No autorizado';
    END IF;
    IF p_transportista_id IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION 'Acceso denegado' USING ERRCODE = '42501';
    END IF;
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
    -- migs 273/276 (#832, #833): las formas no dinerarias no son plata de la rendicion.
    AND COALESCE(pg.forma_pago, '') NOT IN ('adelanto_sueldo', 'nota_credito')
    AND COALESCE(pd.transportista_id, pg.usuario_id) = p_transportista_id
  ORDER BY pg.created_at ASC, pg.id ASC;
END;
$function$;
