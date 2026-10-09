-- =============================================================================
-- 324 · El bot no cuenta canjes ni saca la deuda de copias propias
-- =============================================================================
--
-- Cierra dos issues del bot.
--
-- #983 · La deuda del resumen del admin salía de consultas propias de
--   `bot_metricas_admin_dia` (SUM de saldo_cuenta de clientes activos, y un
--   vencido por `fecha + dias_credito` sin mirar la entrega), no de la pantalla
--   Cuentas por cobrar. El issue decía "hoy coinciden por casualidad"; el
--   2026-10-08 ya no: el resumen decía $2.455.520 y la pantalla $2.468.070
--   (sucursal 1). Ahora las dos cifras salen de `reporte_cuentas_por_cobrar`
--   -> 'totales', y el par entra al mapa de BOT-B. El vencido pasa a contar
--   CLIENTES con algo vencido (la pantalla no cuenta pedidos):
--   `pedidos_vencidos` -> `clientes_vencidos`.
--
-- #1033 (la parte del bot) · Cuatro funciones del bot contaban los canjes
--   (`canal = 'cambio'`: la comanda de un canje, total 0 por CAMBIO-01) como
--   pedidos del cliente:
--     * bot_productos_recurrentes_cliente: el producto canjeado sumaba como
--       "lo que más lleva". Además filtraba por `created_at` (fecha de carga,
--       corte UTC) en vez de por `fecha` con día argentino (mig 241).
--     * bot_resumen_cliente_visita: un canje podía ser el "último pedido", en $0.
--     * bot_historico_pedidos_cliente: el canje aparecía en el historial.
--     * obtener_resumen_cuenta_cliente_bot: contaba en total de pedidos, en
--       pendientes de pago y en la fecha del último pedido.
--   Las del front (reporte_ventas_por_cliente, obtener_estadisticas_pedidos,
--   obtener_resumen_cuenta_cliente) quedan en #1033.
--
-- Cada cuerpo es el VIGENTE en prod (con el vale blanco de la 319); la premisa
-- de abajo frena la migración si alguna cambió desde que se copió.
-- =============================================================================

BEGIN;

-- 0 · Premisas: nada cambió en prod desde que se copiaron (md5 del 2026-10-09).
DO $premisas$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, md5(p.prosrc) AS md5_vivo
      FROM (VALUES
        ('public.bot_metricas_admin_dia(date,bigint)',                                        '0b44235c4287c16b880fb69bbb4af538'),
        ('public.bot_historico_pedidos_cliente(bigint,uuid,text,bigint,integer,integer)',     '215615c29f579e269909391472dff841'),
        ('public.bot_productos_recurrentes_cliente(bigint,uuid,text,bigint,integer,integer)', '7d0c0f9b70fd16d4e555daeefb41f762'),
        ('public.bot_resumen_cliente_visita(bigint,uuid,text,bigint)',                        '4b7774da4252880c441e2274c28e3773'),
        ('public.obtener_resumen_cuenta_cliente_bot(integer)',                                'c95791cb72b34c900fa5d8f4a8ee4446'),
        ('public.auditoria_bot_sin_funcion_canonica()',                                       '698c7c52f07effbae90336af59e08dd2')
      ) AS x(firma, md5)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION '324 · % cambió en prod desde que se copió (md5 %, esperado %): rehacer la copia sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;
END
$premisas$;


-- ---------------------------------------------------------------------------
-- 1 · #983: la deuda del resumen sale de Cuentas por cobrar
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_metricas_admin_dia(p_fecha date, p_sucursal_id bigint DEFAULT NULL::bigint)
 RETURNS json
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH
  pedidos_dia AS (
    SELECT id, total, cliente_id, sucursal_id
    FROM pedidos
    WHERE fecha = p_fecha
      AND estado <> 'cancelado'
      AND tipo_factura IS DISTINCT FROM 'VB'
      AND (p_sucursal_id IS NULL OR sucursal_id = p_sucursal_id)
  ),
  pedidos_7d AS (
    SELECT total
    FROM pedidos
    WHERE fecha >= p_fecha - INTERVAL '7 days'
      AND fecha <  p_fecha
      AND estado <> 'cancelado'
      AND tipo_factura IS DISTINCT FROM 'VB'
      AND (p_sucursal_id IS NULL OR sucursal_id = p_sucursal_id)
  ),
  ventas_dia AS (
    SELECT
      COUNT(*)                                                   AS pedidos,
      COALESCE(SUM(total), 0)::numeric(14,2)                     AS total,
      CASE
        WHEN COUNT(*) > 0 THEN (COALESCE(SUM(total), 0) / COUNT(*))::numeric(14,2)
        ELSE 0::numeric(14,2)
      END                                                        AS ticket_promedio
    FROM pedidos_dia
  ),
  entregado_dia AS (
    SELECT
      COUNT(*)                                                   AS pedidos,
      COALESCE(SUM(total), 0)::numeric(14,2)                     AS total
    FROM pedidos
    WHERE fecha = p_fecha
      AND estado = 'entregado' AND canal <> 'cambio'
      AND tipo_factura IS DISTINCT FROM 'VB'
      AND (p_sucursal_id IS NULL OR sucursal_id = p_sucursal_id)
  ),
  promedio_7d AS (
    SELECT
      ROUND(COUNT(*) / 7.0, 2)                                   AS pedidos_dia_avg,
      ROUND(COALESCE(SUM(total), 0) / 7.0, 2)                    AS total_dia_avg
    FROM pedidos_7d
  ),
  top_clientes AS (
    SELECT
      pd.cliente_id,
      COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social, '(sin nombre)') AS nombre,
      COALESCE(c.es_comodin, false)                              AS es_comodin,
      COUNT(*)                                                   AS pedidos,
      SUM(pd.total)::numeric(14,2)                               AS total
    FROM pedidos_dia pd
    LEFT JOIN clientes c ON c.id = pd.cliente_id
    GROUP BY pd.cliente_id, c.nombre_fantasia, c.razon_social, c.es_comodin
    ORDER BY SUM(pd.total) DESC
    LIMIT 5
  ),
  top_productos AS (
    SELECT
      pi.producto_id,
      pr.nombre,
      pr.codigo,
      SUM(pi.cantidad)::int                                      AS cantidad,
      SUM(pi.cantidad * pi.precio_unitario)::numeric(14,2)       AS monto
    FROM pedido_items pi
    JOIN pedidos_dia  pd ON pd.id = pi.pedido_id
    LEFT JOIN productos pr ON pr.id = pi.producto_id
    GROUP BY pi.producto_id, pr.nombre, pr.codigo
    ORDER BY SUM(pi.cantidad) DESC
    LIMIT 5
  ),
  pendientes_entrega AS (
    SELECT
      COUNT(*)::int                                              AS count,
      COALESCE(SUM(total), 0)::numeric(14,2)                     AS monto
    FROM pedidos
    WHERE estado IN ('pendiente', 'en_preparacion', 'asignado', 'en_reparto')
      AND fecha >= p_fecha - INTERVAL '14 days'
      AND (p_sucursal_id IS NULL OR sucursal_id = p_sucursal_id)
  ),
  pendientes_pago AS (
    SELECT
      COUNT(*)::int                                              AS count,
      COALESCE(SUM(total - COALESCE(monto_pagado, 0)), 0)::numeric(14,2) AS saldo
    FROM pedidos
    WHERE estado_pago IN ('pendiente', 'parcial')
      AND estado <> 'cancelado'
      AND total > COALESCE(monto_pagado, 0)
      AND (p_sucursal_id IS NULL OR sucursal_id = p_sucursal_id)
  ),
  stock_critico_base AS (
    SELECT
      id, codigo, nombre, stock, stock_minimo,
      ROW_NUMBER() OVER (
        ORDER BY (COALESCE(stock_minimo, 10) - COALESCE(stock, 0)) DESC, id ASC
      ) AS rn
    FROM productos
    WHERE COALESCE(stock, 0) <= COALESCE(stock_minimo, 10)
      AND (p_sucursal_id IS NULL OR sucursal_id = p_sucursal_id)
  ),
  stock_critico AS (
    SELECT
      (SELECT COUNT(*) FROM stock_critico_base)::int AS count,
      COALESCE(
        (SELECT json_agg(
          json_build_object(
            'id',           s.id,
            'codigo',       s.codigo,
            'nombre',       s.nombre,
            'stock',        s.stock,
            'stock_minimo', s.stock_minimo
          )
          ORDER BY s.rn
        )
        FROM stock_critico_base s
        WHERE s.rn <= 5),
        '[]'::json
      ) AS top
  ),
  -- #983: la deuda es la de la pantalla Cuentas por cobrar, no una copia.
  -- Por pedido, desde la entrega, con los inactivos que deben y sin netear
  -- saldos a favor. Con NULL, el reporte trae todas las sucursales.
  cxr AS (
    SELECT reporte_cuentas_por_cobrar(p_sucursal_id) AS r
  ),
  cxc AS (
    SELECT
      COALESCE((r -> 'totales' ->> 'clientes')::int, 0)          AS clientes_con_saldo,
      COALESCE((r -> 'totales' ->> 'saldo')::numeric, 0)::numeric(14,2) AS deuda_total
    FROM cxr
  ),
  cxc_vencido AS (
    SELECT
      (SELECT COUNT(*) FROM jsonb_array_elements(r -> 'clientes') x
        WHERE COALESCE((x -> 'aging' ->> 'vencido30')::numeric, 0)
            + COALESCE((x -> 'aging' ->> 'vencido60')::numeric, 0)
            + COALESCE((x -> 'aging' ->> 'vencido90')::numeric, 0) > 0)::int AS clientes_vencidos,
      (COALESCE((r -> 'totales' ->> 'vencido30')::numeric, 0)
       + COALESCE((r -> 'totales' ->> 'vencido60')::numeric, 0)
       + COALESCE((r -> 'totales' ->> 'vencido90')::numeric, 0))::numeric(14,2) AS monto_vencido
    FROM cxr
  ),
  rendiciones_pendientes AS (
    SELECT
      COUNT(*)::int                                              AS count,
      COALESCE(MAX(CURRENT_DATE - r.fecha), 0)::int              AS dias_mas_vieja
    FROM rendiciones r
    LEFT JOIN rendiciones_control rc
      ON  rc.fecha = r.fecha
      AND rc.transportista_id = r.transportista_id
      AND rc.sucursal_id = r.sucursal_id
    WHERE rc.id IS NULL
      AND r.fecha < CURRENT_DATE - INTERVAL '2 days'
      AND (p_sucursal_id IS NULL OR r.sucursal_id = p_sucursal_id)
  ),
  recorridos_hoy AS (
    SELECT
      COUNT(*)::int                                              AS count,
      COUNT(*) FILTER (WHERE estado = 'en_curso')::int           AS en_curso,
      COALESCE(SUM(total_pedidos), 0)::int                       AS total_paradas
    FROM recorridos
    WHERE fecha = CURRENT_DATE
      AND (p_sucursal_id IS NULL OR sucursal_id = p_sucursal_id)
  )
  SELECT json_build_object(
    'fecha',                  p_fecha,
    'sucursal_id',            p_sucursal_id,
    'ventas_dia',             (SELECT row_to_json(v) FROM ventas_dia v),
    'entregado_dia',          (SELECT row_to_json(e) FROM entregado_dia e),
    'promedio_7d',            (SELECT row_to_json(p) FROM promedio_7d p),
    'delta_pct',
      CASE
        WHEN (SELECT total_dia_avg FROM promedio_7d) > 0 THEN
          ROUND(
            (((SELECT total FROM ventas_dia) - (SELECT total_dia_avg FROM promedio_7d))
             / (SELECT total_dia_avg FROM promedio_7d) * 100)::numeric, 1
          )
        ELSE NULL
      END,
    'top_clientes',           COALESCE((SELECT json_agg(row_to_json(t)) FROM top_clientes t), '[]'::json),
    'top_productos',          COALESCE((SELECT json_agg(row_to_json(t)) FROM top_productos t), '[]'::json),
    'pendientes_entrega',     (SELECT row_to_json(x) FROM pendientes_entrega x),
    'pendientes_pago',        (SELECT row_to_json(x) FROM pendientes_pago x),
    'stock_critico',          (SELECT row_to_json(x) FROM stock_critico x),
    'cuentas_por_cobrar',     (SELECT row_to_json(x) FROM cxc x),
    'cxc_vencido',            (SELECT row_to_json(x) FROM cxc_vencido x),
    'rendiciones_pendientes', (SELECT row_to_json(x) FROM rendiciones_pendientes x),
    'recorridos_hoy',         (SELECT row_to_json(x) FROM recorridos_hoy x)
  );
$function$;


-- ---------------------------------------------------------------------------
-- 2 · #1033: historial sin canjes
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_historico_pedidos_cliente(p_cliente_id bigint, p_perfil_id uuid, p_rol text, p_sucursal_id bigint, p_dias integer DEFAULT 90, p_limit integer DEFAULT 20)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  resultado JSON;
  -- mt_pedidos_select: admin y encargado ven todos los pedidos de la sucursal;
  -- cualquier otro rol, solo los que cargo o reparte (296).
  v_ve_todo BOOLEAN := p_rol IN ('admin', 'encargado');
  -- Ultimos N dias = hoy y los N-1 anteriores.
  v_desde   DATE := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date - (p_dias - 1);
BEGIN
  IF p_rol = 'preventista' THEN
    IF NOT (
      EXISTS(SELECT 1 FROM cliente_preventistas
             WHERE cliente_id = p_cliente_id AND preventista_id = p_perfil_id)
      OR NOT EXISTS(SELECT 1 FROM cliente_preventistas
                    WHERE cliente_id = p_cliente_id)
    ) THEN
      RETURN json_build_object('cliente_id', p_cliente_id, 'pedidos_count', 0,
        'pedidos', '[]'::JSON, 'error', 'Cliente asignado a otro preventista');
    END IF;

    -- Reservado a administracion (mig 214). El historial propio SI se ve: es la
    -- excepcion que evita que sus pedidos viejos queden sin cliente.
    IF EXISTS(SELECT 1 FROM clientes c WHERE c.id = p_cliente_id AND c.reservado_admin)
       AND NOT EXISTS(SELECT 1 FROM pedidos pe
                      WHERE pe.cliente_id = p_cliente_id AND pe.usuario_id = p_perfil_id)
    THEN
      RETURN json_build_object('cliente_id', p_cliente_id, 'pedidos_count', 0,
        'pedidos', '[]'::JSON, 'error', 'Cliente reservado a administración');
    END IF;
  END IF;

  WITH ventana AS (
    SELECT id, fecha, total, estado, estado_pago, created_at
    FROM pedidos
    WHERE cliente_id = p_cliente_id AND sucursal_id = p_sucursal_id
      AND fecha >= v_desde
      AND COALESCE(estado, '') <> 'cancelado'
      -- Un canje (comanda de cambio, total 0) no es un pedido del cliente (324, #1033).
      AND canal <> 'cambio'
      AND tipo_factura IS DISTINCT FROM 'VB'
      AND (v_ve_todo OR usuario_id = p_perfil_id OR transportista_id = p_perfil_id)
  ),
  ultimos_pedidos AS (
    SELECT * FROM ventana ORDER BY fecha DESC, created_at DESC LIMIT p_limit
  ),
  pedidos_con_items AS (
    SELECT up.id, up.fecha, up.total, up.estado, up.estado_pago, up.created_at,
      (SELECT json_agg(json_build_object('producto_id', p.id, 'codigo', p.codigo,
        'nombre', p.nombre, 'cantidad', pi.cantidad, 'subtotal', pi.subtotal)
        ORDER BY pi.subtotal DESC)
       FROM pedido_items pi JOIN productos p ON p.id = pi.producto_id
       WHERE pi.pedido_id = up.id) AS items
    FROM ultimos_pedidos up
  )
  SELECT json_build_object(
    'cliente_id', p_cliente_id,
    'pedidos_count', (SELECT COUNT(*) FROM ventana),
    'pedidos_mostrados', (SELECT COUNT(*) FROM pedidos_con_items),
    'rango_dias', p_dias,
    'desde', v_desde,
    'total_periodo', (SELECT COALESCE(SUM(total), 0) FROM ventana),
    'criterio', 'Pedidos no cancelados (tomados y entregados), sin canjes, por fecha del pedido.',
    'alcance', CASE WHEN v_ve_todo THEN 'todos' ELSE 'propios' END,
    'pedidos', COALESCE(
      (SELECT json_agg(row_to_json(p.*) ORDER BY p.fecha DESC, p.created_at DESC) FROM pedidos_con_items p),
      '[]'::JSON
    )
  ) INTO resultado;
  RETURN resultado;
END;
$function$;


-- ---------------------------------------------------------------------------
-- 3 · #1033: lo que más lleva, sin canjes y por fecha (no por fecha de carga)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_productos_recurrentes_cliente(p_cliente_id bigint, p_perfil_id uuid, p_rol text, p_sucursal_id bigint, p_dias integer DEFAULT 90, p_limit integer DEFAULT 10)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  resultado JSON;
  -- Hechos si, montos no (296): cuantas veces el cliente llevo el producto sale
  -- de todos sus pedidos; unidades y facturado, solo de los que el ve en la app.
  v_ve_todo BOOLEAN := p_rol IN ('admin', 'encargado');
  -- Ultimos N dias = hoy y los N-1 anteriores, en dia argentino (324): antes
  -- era `created_at > now() - N dias`, la fecha de CARGA con corte UTC.
  v_desde   DATE := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date - (p_dias - 1);
BEGIN
  IF p_rol = 'preventista' THEN
    IF NOT (
      EXISTS(SELECT 1 FROM cliente_preventistas
             WHERE cliente_id = p_cliente_id AND preventista_id = p_perfil_id)
      OR NOT EXISTS(SELECT 1 FROM cliente_preventistas
                    WHERE cliente_id = p_cliente_id)
    ) THEN
      RETURN json_build_object('cliente_id', p_cliente_id, 'productos', '[]'::JSON,
        'error', 'Cliente asignado a otro preventista');
    END IF;

    -- Reservado a administracion (mig 214), con la misma excepcion de historial.
    IF EXISTS(SELECT 1 FROM clientes c WHERE c.id = p_cliente_id AND c.reservado_admin)
       AND NOT EXISTS(SELECT 1 FROM pedidos pe
                      WHERE pe.cliente_id = p_cliente_id AND pe.usuario_id = p_perfil_id)
    THEN
      RETURN json_build_object('cliente_id', p_cliente_id, 'productos', '[]'::JSON,
        'error', 'Cliente reservado a administración');
    END IF;
  END IF;

  WITH items_periodo AS (
    SELECT pi.producto_id, pi.cantidad, pi.subtotal, pe.id AS pedido_id,
      (v_ve_todo OR pe.usuario_id = p_perfil_id OR pe.transportista_id = p_perfil_id) AS visible
    FROM pedido_items pi JOIN pedidos pe ON pe.id = pi.pedido_id
    WHERE pe.cliente_id = p_cliente_id AND pe.sucursal_id = p_sucursal_id
      AND pe.fecha >= v_desde
      AND COALESCE(pe.estado, '') NOT IN ('cancelado', 'anulado')
      -- Lo que se le canjeó no es lo que lleva (324, #1033).
      AND pe.canal <> 'cambio'
      AND pe.tipo_factura IS DISTINCT FROM 'VB'
  ),
  ranked AS (
    SELECT p.id, p.codigo, p.nombre, p.precio,
      COUNT(DISTINCT ip.pedido_id) AS pedidos_con_producto,
      COALESCE(SUM(ip.cantidad) FILTER (WHERE ip.visible), 0) AS unidades_totales,
      COALESCE(SUM(ip.subtotal) FILTER (WHERE ip.visible), 0) AS facturado_total
    FROM items_periodo ip JOIN productos p ON p.id = ip.producto_id
    WHERE p.activo -- mig 284: un inactivo no se sugiere para volver a vender
    GROUP BY p.id, p.codigo, p.nombre, p.precio
    -- El desempate va por las unidades visibles: ordenar por las de todos
    -- dejaria inferir el volumen ajeno por el orden de la lista.
    ORDER BY COUNT(DISTINCT ip.pedido_id) DESC,
             COALESCE(SUM(ip.cantidad) FILTER (WHERE ip.visible), 0) DESC
    LIMIT p_limit
  )
  SELECT json_build_object(
    'cliente_id', p_cliente_id, 'rango_dias', p_dias,
    'montos', CASE WHEN v_ve_todo THEN 'todos' ELSE 'propios' END,
    'productos', COALESCE((SELECT json_agg(row_to_json(r.*)) FROM ranked r), '[]'::JSON)
  ) INTO resultado;
  RETURN resultado;
END;
$function$;


-- ---------------------------------------------------------------------------
-- 4 · #1033: el último pedido del resumen de visita no es un canje
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_resumen_cliente_visita(p_cliente_id bigint, p_perfil_id uuid, p_rol text, p_sucursal_id bigint)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_ritmo     json;
  v_top       json;
  v_dejados   json;
  v_ultimo    json;
  v_cliente   RECORD;
  v_ve_todo   BOOLEAN := p_rol IN ('admin', 'encargado');
BEGIN
  -- El gate es el mismo de recurrentes y dejados: si este rebota, rebota todo.
  v_top := bot_productos_recurrentes_cliente(p_cliente_id, p_perfil_id, p_rol, p_sucursal_id, 90, 5);
  IF v_top ->> 'error' IS NOT NULL THEN
    RETURN json_build_object('cliente_id', p_cliente_id, 'error', v_top ->> 'error');
  END IF;

  SELECT c.id, c.codigo, COALESCE(NULLIF(btrim(c.nombre_fantasia), ''), c.razon_social) AS nombre,
         c.direccion, c.telefono, c.saldo_cuenta, c.limite_credito, c.es_comodin, c.activo
    INTO v_cliente
    FROM clientes c
   WHERE c.id = p_cliente_id AND c.sucursal_id = p_sucursal_id;
  IF NOT FOUND THEN
    RETURN json_build_object('cliente_id', p_cliente_id, 'error', 'Cliente no encontrado en esta sucursal');
  END IF;

  -- El ritmo de ESTE cliente, con la misma definicion que la lista de atrasados.
  -- Se calcula sobre la sucursal entera (admin) para no depender de la cartera:
  -- el gate de arriba ya decidio si lo puede ver.
  SELECT row_to_json(r.*) INTO v_ritmo
    FROM clientes_ritmo_compra(p_sucursal_id, 'admin', p_perfil_id, NULL, p_cliente_id) r;

  v_dejados := bot_productos_dejados_cliente(p_cliente_id, p_perfil_id, p_rol, p_sucursal_id);

  -- Ultimo pedido: el propio para quien no ve todos (montos propios).
  SELECT json_build_object('fecha', pe.fecha, 'total', pe.total, 'estado', pe.estado,
                           'estado_pago', pe.estado_pago)
    INTO v_ultimo
    FROM pedidos pe
   WHERE pe.cliente_id = p_cliente_id AND pe.sucursal_id = p_sucursal_id
     AND pe.estado IS DISTINCT FROM 'cancelado'
     -- Un canje en $0 no es "su último pedido" (324, #1033).
     AND pe.canal <> 'cambio'
     AND pe.tipo_factura IS DISTINCT FROM 'VB'
     AND (v_ve_todo OR pe.usuario_id = p_perfil_id OR pe.transportista_id = p_perfil_id)
   ORDER BY pe.fecha DESC, pe.id DESC
   LIMIT 1;

  RETURN json_build_object(
    'cliente', json_build_object('id', v_cliente.id, 'codigo', v_cliente.codigo,
       'nombre', v_cliente.nombre, 'direccion', v_cliente.direccion,
       'telefono', v_cliente.telefono, 'es_comodin', v_cliente.es_comodin,
       'activo', v_cliente.activo),
    'saldo', v_cliente.saldo_cuenta,
    'limite_credito', v_cliente.limite_credito,
    'ritmo', CASE WHEN v_ritmo IS NULL THEN NULL ELSE json_build_object(
       'ultima_compra', v_ritmo ->> 'ultima_compra',
       'dias_sin_comprar', (v_ritmo ->> 'dias_sin_comprar')::int,
       'frecuencia_dias', (v_ritmo ->> 'frecuencia_dias')::numeric,
       'estado', v_ritmo ->> 'estado') END,
    'top_productos', v_top -> 'productos',
    'montos', CASE WHEN v_ve_todo THEN 'todos' ELSE 'propios' END,
    'dejados', v_dejados -> 'productos',
    'ultimo_pedido', v_ultimo,
    'ultimo_pedido_alcance', CASE WHEN v_ve_todo THEN 'todos' ELSE 'propios' END
  );
END;
$function$;


-- ---------------------------------------------------------------------------
-- 5 · #1033: el resumen de cuenta del bot no cuenta canjes
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_resumen_cuenta_cliente_bot(p_cliente_id integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  resultado JSON;
BEGIN
  -- Un canje (canal 'cambio', total 0) no es un pedido del cliente: no cuenta en
  -- pedidos, compras, pendientes de pago ni en la fecha del ultimo (324, #1033).
  SELECT json_build_object(
    'saldo_actual', COALESCE(c.saldo_cuenta, 0),
    'limite_credito', COALESCE(c.limite_credito, 0),
    'credito_disponible', COALESCE(c.limite_credito, 0) - COALESCE(c.saldo_cuenta, 0),
    'total_pedidos', (SELECT COUNT(*) FROM pedidos
                       WHERE cliente_id = p_cliente_id AND estado IS DISTINCT FROM 'cancelado'
                         AND canal <> 'cambio'
                         AND tipo_factura IS DISTINCT FROM 'VB'),
    'total_compras', (SELECT COALESCE(SUM(total), 0) FROM pedidos
                       WHERE cliente_id = p_cliente_id AND estado IS DISTINCT FROM 'cancelado'
                         AND canal <> 'cambio'
                         AND tipo_factura IS DISTINCT FROM 'VB'),
    'total_pagos', (SELECT COALESCE(SUM(monto), 0) FROM pagos WHERE cliente_id = p_cliente_id),
    'pedidos_pendientes_pago', (SELECT COUNT(*) FROM pedidos
                                 WHERE cliente_id = p_cliente_id
                                   AND estado IS DISTINCT FROM 'cancelado'
                                   AND canal <> 'cambio'
                                   AND estado_pago IS DISTINCT FROM 'pagado'),
    'ultimo_pedido', (SELECT MAX(created_at) FROM pedidos
                       WHERE cliente_id = p_cliente_id AND estado IS DISTINCT FROM 'cancelado'
                         AND canal <> 'cambio'
                         AND tipo_factura IS DISTINCT FROM 'VB'),
    'ultimo_pago', (SELECT MAX(created_at) FROM pagos WHERE cliente_id = p_cliente_id),
    'es_comodin', COALESCE(c.es_comodin, false),
    'consumo_interno', (SELECT json_build_object('monto', COALESCE(SUM(total), 0), 'pedidos', COUNT(*))
                          FROM pedidos
                         WHERE cliente_id = p_cliente_id AND tipo_factura = 'VB'
                           AND estado IS DISTINCT FROM 'cancelado')
  ) INTO resultado
  FROM clientes c
  WHERE c.id = p_cliente_id;

  RETURN resultado;
END;
$function$;

-- CREATE OR REPLACE conserva los permisos; se reafirman igual (server-only).
REVOKE EXECUTE ON FUNCTION public.bot_metricas_admin_dia(date, bigint) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.bot_historico_pedidos_cliente(bigint, uuid, text, bigint, integer, integer) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.bot_productos_recurrentes_cliente(bigint, uuid, text, bigint, integer, integer) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.bot_resumen_cliente_visita(bigint, uuid, text, bigint) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.obtener_resumen_cuenta_cliente_bot(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bot_metricas_admin_dia(date, bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.bot_historico_pedidos_cliente(bigint, uuid, text, bigint, integer, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.bot_productos_recurrentes_cliente(bigint, uuid, text, bigint, integer, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.bot_resumen_cliente_visita(bigint, uuid, text, bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.obtener_resumen_cuenta_cliente_bot(integer) TO service_role;


-- ---------------------------------------------------------------------------
-- 6 · BOT-B: la deuda del resumen consume Cuentas por cobrar
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.auditoria_bot_sin_funcion_canonica()
 RETURNS bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT count(*)
    FROM (VALUES
      ('public.bot_pendientes_pago(bigint,integer,integer)',                'reporte_cuentas_por_cobrar'),
      ('public.bot_ventas_por_preventista(date,date,bigint,boolean,integer)', 'reporte_ventas_por_preventista'),
      ('public.bot_ranking_clientes(date,date,bigint,text,uuid,uuid,text,integer)', 'reporte_ventas_por_cliente'),
      ('public.bot_clientes_atrasados(bigint,text,uuid,uuid,boolean,boolean,integer)', 'clientes_ritmo_compra'),
      ('public.bot_resumen_cliente_visita(bigint,uuid,text,bigint)',        'clientes_ritmo_compra'),
      ('public.bot_riesgo_por_preventista(bigint)',                         'clientes_ritmo_compra'),
      ('public.bot_digest_preventista(uuid,bigint,date)',                   'bot_clientes_atrasados'),
      ('public.bot_digest_preventista(uuid,bigint,date)',                   'bot_mis_ventas'),
      ('public.bot_metricas_admin_dia(date,bigint)',                        'reporte_cuentas_por_cobrar')
    ) AS m(funcion, canonica)
   WHERE to_regprocedure(m.funcion) IS NULL
      -- Sin comentarios: un "-- antes llamaba a reporte_x(" no cuenta como llamada.
      OR regexp_replace(pg_get_functiondef(to_regprocedure(m.funcion)), '--[^\n]*', '', 'g')
           NOT ILIKE '%' || m.canonica || '(%';
$function$;

COMMENT ON FUNCTION public.auditoria_bot_sin_funcion_canonica() IS
  'BOT-B (300, 308, 311, 324). Cada funcion del bot que da un numero de una pantalla consume la funcion de esa pantalla (deuda, ventas por preventista, ventas por cliente), y las que hablan de "atrasado" consumen clientes_ritmo_compra (una sola definicion). El resumen del preventista consume bot_mis_ventas y bot_clientes_atrasados; la deuda del resumen del admin, reporte_cuentas_por_cobrar.';


-- ---------------------------------------------------------------------------
-- 7 · Ensayo
-- ---------------------------------------------------------------------------
DO $ensayo$
DECLARE
  s       RECORD;
  v_m     json;
  v_r     jsonb;
  v_canje RECORD;
  v_j     json;
BEGIN
  -- 7a. La deuda del resumen es la de la pantalla, en cada sucursal y en todas.
  FOR s IN SELECT id FROM sucursales WHERE activa UNION ALL SELECT NULL LOOP
    v_m := bot_metricas_admin_dia((now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date - 1, s.id);
    v_r := reporte_cuentas_por_cobrar(s.id);
    IF (v_m -> 'cuentas_por_cobrar' ->> 'deuda_total')::numeric <> COALESCE((v_r -> 'totales' ->> 'saldo')::numeric, 0)
       OR (v_m -> 'cuentas_por_cobrar' ->> 'clientes_con_saldo')::int <> COALESCE((v_r -> 'totales' ->> 'clientes')::int, 0) THEN
      RAISE EXCEPTION 'ensayo 324: la deuda del resumen de la sucursal % no es la de Cuentas por cobrar', s.id;
    END IF;
    IF (v_m -> 'cxc_vencido' ->> 'monto_vencido')::numeric <>
       COALESCE((v_r -> 'totales' ->> 'vencido30')::numeric, 0) + COALESCE((v_r -> 'totales' ->> 'vencido60')::numeric, 0)
       + COALESCE((v_r -> 'totales' ->> 'vencido90')::numeric, 0) THEN
      RAISE EXCEPTION 'ensayo 324: el vencido del resumen de la sucursal % no es el de Cuentas por cobrar', s.id;
    END IF;
  END LOOP;

  -- 7b. Un canje no aparece en el historial ni como último pedido ni cuenta en
  --     el resumen de cuenta. Si prod no tiene canjes, se fabrica uno y se
  --     deshace con la excepción marcadora.
  FOR v_canje IN
    SELECT pe.id, pe.cliente_id, pe.sucursal_id FROM pedidos pe
     WHERE pe.canal = 'cambio' AND pe.estado <> 'cancelado'
     ORDER BY pe.id DESC LIMIT 1
  LOOP
    v_j := bot_historico_pedidos_cliente(v_canje.cliente_id, NULL, 'admin', v_canje.sucursal_id, 3650, 500);
    IF EXISTS (SELECT 1 FROM json_array_elements(v_j -> 'pedidos') p WHERE (p ->> 'id')::bigint = v_canje.id) THEN
      RAISE EXCEPTION 'ensayo 324: el canje % sigue en el historial', v_canje.id;
    END IF;
    IF (obtener_resumen_cuenta_cliente_bot(v_canje.cliente_id::int) ->> 'total_pedidos')::int
       <> (SELECT COUNT(*) FROM pedidos WHERE cliente_id = v_canje.cliente_id AND estado IS DISTINCT FROM 'cancelado'
             AND canal <> 'cambio' AND tipo_factura IS DISTINCT FROM 'VB') THEN
      RAISE EXCEPTION 'ensayo 324: el resumen de cuenta del cliente % cuenta canjes', v_canje.cliente_id;
    END IF;
  END LOOP;

  -- 7c. Recurrentes por fecha: para un cliente con historial, los pedidos que
  --     cuenta son los de la ventana por `fecha`, sin canjes.
  FOR s IN
    SELECT pe.cliente_id, pe.sucursal_id FROM pedidos pe
     WHERE pe.estado = 'entregado' GROUP BY 1, 2 ORDER BY COUNT(*) DESC LIMIT 1
  LOOP
    v_j := bot_productos_recurrentes_cliente(s.cliente_id, NULL, 'admin', s.sucursal_id, 90, 1);
    IF json_array_length(v_j -> 'productos') > 0 AND (v_j -> 'productos' -> 0 ->> 'pedidos_con_producto')::int >
       (SELECT COUNT(*) FROM pedidos WHERE cliente_id = s.cliente_id AND sucursal_id = s.sucursal_id
          AND fecha >= (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date - 89
          AND canal <> 'cambio' AND COALESCE(estado, '') NOT IN ('cancelado', 'anulado')) THEN
      RAISE EXCEPTION 'ensayo 324: recurrentes cuenta pedidos fuera de la ventana por fecha';
    END IF;
  END LOOP;

  -- 7d. BOT-B en verde con el par nuevo.
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(auditoria_integridad() -> 'checks') c
                  WHERE c ->> 'id' = 'BOT-B' AND (c ->> 'ok')::boolean) THEN
    RAISE EXCEPTION 'ensayo 324: BOT-B en rojo';
  END IF;

  RAISE NOTICE 'ensayo 324: deuda de Cuentas por cobrar, canjes fuera y BOT-B OK';
END;
$ensayo$;

COMMIT;
