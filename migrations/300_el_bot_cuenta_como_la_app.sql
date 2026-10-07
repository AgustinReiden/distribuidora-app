-- =============================================================================
-- 300 · El bot cuenta como la app
-- =============================================================================
--
-- La auditoria del 2026-10-07 (#977) comparo cada numero del bot contra la
-- pantalla de la app que muestra lo mismo. Las ventas ya cuadraban al peso
-- (mig 241). Lo que no:
--
--   * bot_pendientes_pago sumaba `p.total` sin restar `monto_pagado`: la deuda
--     de Tucuman salia $2,39M (51%) mas alta que en Cuentas por cobrar. Ahora
--     CONSUME reporte_cuentas_por_cobrar, la funcion de esa pantalla.
--   * bot_ventas_por_preventista tenia su propia copia de la definicion de venta.
--     Ahora consume reporte_ventas_por_preventista, la de Reportes, y dice
--     cuanto suman los que dejo afuera (por defecto, admins y encargados).
--   * bot_historico_pedidos_cliente sumaba `total_periodo` DESPUES del LIMIT
--     (con limit 1 daba 110.400 contra 416.350) y cortaba la ventana por
--     created_at en UTC. Ahora el total es de toda la ventana, por `fecha`.
--   * bot_ficha_producto contaba cancelados, pendientes y regalos por
--     created_at: +11%. Ahora es venta de la mig 241, y lo regalado va aparte
--     (decision del dueño: vendidas y regaladas por separado).
--   * obtener_resumen_cuenta_cliente_bot contaba los cancelados en la cantidad de
--     pedidos; la ficha de la app (useFichaCliente) no. Ahora, igual que la app.
--   * El digest llamaba "ventas" a los pedidos tomados. Se suma lo entregado
--     (la venta de la 241) al lado, y el prompt dice cual es cual.
--   * "Cliente extra" es un cliente comodin de mostrador que encabeza rankings.
--     Decision del dueño: mostrarlo con etiqueta, no excluirlo (excluirlo haria
--     que el bot no cuadre con los reportes de la app). Columna nueva
--     `clientes.es_comodin`.
--   * RFM y mis_clientes contaban la comanda de un cambio (canal 'cambio',
--     total 0) como compra.
--
-- Y el gate para que no vuelva: BOT-B en auditoria_integridad() cuenta las
-- funciones del bot que dejaron de consumir su funcion canonica.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 0 · Andamio: parche por ancla (molde de la 241/252/254).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._mig300_ancla(
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
-- 1 · Cliente comodin
-- ---------------------------------------------------------------------------
ALTER TABLE public.clientes
  ADD COLUMN IF NOT EXISTS es_comodin BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN public.clientes.es_comodin IS
  'Cliente generico de mostrador, no un comercio real (300). Los reportes lo siguen sumando; el bot lo etiqueta para que no se lea como "el mejor cliente".';

UPDATE public.clientes
   SET es_comodin = true
 WHERE lower(btrim(COALESCE(nombre_fantasia, ''))) = 'cliente extra'
   AND NOT es_comodin;


-- ---------------------------------------------------------------------------
-- 2 · bot_pendientes_pago: consume reporte_cuentas_por_cobrar
-- ---------------------------------------------------------------------------
-- Misma firma. `p_dias_atraso` cambia de significado: antes eran dias desde la
-- carga del pedido; ahora son dias de MORA (vencido desde la entrega + los dias
-- de credito del cliente), que es como cuenta la pantalla. Se resuelve con los
-- tramos de la pantalla: 0 = todos con saldo; 1-29 = con algo vencido;
-- 30-59 = vencido a mas de 30 dias; 60 o mas = vencido a mas de 60.
CREATE OR REPLACE FUNCTION public.bot_pendientes_pago(p_sucursal_id bigint, p_dias_atraso integer DEFAULT 0, p_limit integer DEFAULT 50)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rep jsonb;
BEGIN
  -- Con NULL el reporte devuelve TODAS las sucursales. Antes esto no matcheaba
  -- nada; no puede pasar a significar "todo".
  IF p_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'bot_pendientes_pago: sucursal requerida';
  END IF;
  -- La pantalla Cuentas por cobrar. Corre como servicio (auth.uid() NULL).
  v_rep := reporte_cuentas_por_cobrar(p_sucursal_id);

  RETURN (
    WITH filas AS (
      SELECT
        (x -> 'cliente' ->> 'id')::bigint                 AS cliente_id,
        c.codigo                                          AS cliente_codigo,
        x -> 'cliente' ->> 'nombre_fantasia'              AS nombre_fantasia,
        x -> 'cliente' ->> 'razon_social'                 AS razon_social,
        (x -> 'cliente' ->> 'activo')::boolean            AS activo,
        COALESCE(c.es_comodin, false)                     AS es_comodin,
        (x ->> 'pedidosPendientes')::int                  AS pedidos_pendientes,
        (x ->> 'saldoPendiente')::numeric                 AS total_adeudado,
        (x -> 'aging' ->> 'corriente')::numeric           AS corriente,
        (x -> 'aging' ->> 'vencido30')::numeric           AS vencido_1_30,
        (x -> 'aging' ->> 'vencido60')::numeric           AS vencido_31_60,
        (x -> 'aging' ->> 'vencido90')::numeric           AS vencido_mas_60
      FROM jsonb_array_elements(v_rep -> 'clientes') x
      LEFT JOIN clientes c ON c.id = (x -> 'cliente' ->> 'id')::bigint
    ),
    filtradas AS (
      SELECT f.*, (f.vencido_1_30 + f.vencido_31_60 + f.vencido_mas_60) AS vencido
        FROM filas f
       WHERE p_dias_atraso <= 0
          OR (p_dias_atraso < 30 AND f.vencido_1_30 + f.vencido_31_60 + f.vencido_mas_60 > 0)
          OR (p_dias_atraso >= 30 AND p_dias_atraso < 60 AND f.vencido_31_60 + f.vencido_mas_60 > 0)
          OR (p_dias_atraso >= 60 AND f.vencido_mas_60 > 0)
    )
    SELECT json_build_object(
      'sucursal_id',      p_sucursal_id,
      'dias_atraso_min',  p_dias_atraso,
      'criterio',         v_rep -> 'meta' ->> 'criterio',
      'total_sucursal',   (v_rep -> 'totales' ->> 'saldo')::numeric,
      'total_global',     (SELECT COALESCE(SUM(total_adeudado), 0) FROM filtradas),
      'vencido_global',   (SELECT COALESCE(SUM(vencido), 0) FROM filtradas),
      'clientes_count',   (SELECT COUNT(*) FROM filtradas),
      'clientes', COALESCE((
        SELECT json_agg(row_to_json(t.*) ORDER BY t.vencido DESC, t.total_adeudado DESC)
          FROM (SELECT * FROM filtradas
                 ORDER BY vencido DESC, total_adeudado DESC
                 LIMIT p_limit) t
      ), '[]'::json)
    )
  );
END;
$function$;


-- ---------------------------------------------------------------------------
-- 3 · bot_ventas_por_preventista: consume reporte_ventas_por_preventista
-- ---------------------------------------------------------------------------
-- Misma firma. `p_solo_preventistas` sigue filtrando por rol, pero ahora la
-- respuesta trae el total de TODOS los roles y cuanto quedo afuera, para que
-- el bot no presente como "total de la sucursal" lo que es un recorte.
CREATE OR REPLACE FUNCTION public.bot_ventas_por_preventista(p_desde date, p_hasta date, p_sucursal_id bigint, p_solo_preventistas boolean DEFAULT true, p_limit integer DEFAULT 25)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rep jsonb;
BEGIN
  IF p_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'bot_ventas_por_preventista: sucursal requerida';
  END IF;
  -- La pantalla Reportes > Ventas por preventista. Corre como servicio.
  v_rep := reporte_ventas_por_preventista(p_desde, p_hasta, p_sucursal_id);

  RETURN (
    WITH todos AS (
      SELECT (x ->> 'id')::uuid               AS usuario_id,
             x ->> 'nombre'                   AS nombre,
             pf.rol                           AS rol,
             (x ->> 'totalVentas')::numeric   AS total_vendido,
             (x ->> 'cantidadPedidos')::int   AS pedidos
        FROM jsonb_array_elements(v_rep) x
        LEFT JOIN perfiles pf ON pf.id = (x ->> 'id')::uuid
    ),
    filtrados AS (
      SELECT * FROM todos
       WHERE NOT p_solo_preventistas OR rol = 'preventista'
    ),
    top AS (
      SELECT usuario_id, nombre, rol, pedidos, total_vendido,
             CASE WHEN pedidos > 0 THEN ROUND(total_vendido / pedidos, 2) ELSE 0 END AS ticket_promedio
        FROM filtrados
       ORDER BY total_vendido DESC
       LIMIT p_limit
    )
    SELECT json_build_object(
      'desde', p_desde, 'hasta', p_hasta,
      'sucursal_id', p_sucursal_id,
      'sucursal', (SELECT nombre FROM sucursales WHERE id = p_sucursal_id),
      'solo_preventistas', p_solo_preventistas,
      'total_ventas',  (SELECT COALESCE(SUM(total_vendido), 0) FROM filtrados),
      'pedidos_count', (SELECT COALESCE(SUM(pedidos), 0) FROM filtrados),
      'total_todos_los_roles',   (SELECT COALESCE(SUM(total_vendido), 0) FROM todos),
      'pedidos_todos_los_roles', (SELECT COALESCE(SUM(pedidos), 0) FROM todos),
      'excluidos', COALESCE((
        SELECT json_agg(json_build_object('nombre', t.nombre, 'rol', t.rol,
                                          'total_vendido', t.total_vendido)
                        ORDER BY t.total_vendido DESC)
          FROM todos t
         WHERE p_solo_preventistas AND t.rol IS DISTINCT FROM 'preventista'
      ), '[]'::json),
      'preventistas_count', (SELECT COUNT(*) FROM top),
      'preventistas', COALESCE((SELECT json_agg(row_to_json(t.*) ORDER BY t.total_vendido DESC) FROM top t), '[]'::json)
    )
  );
END;
$function$;


-- ---------------------------------------------------------------------------
-- 4 · bot_historico_pedidos_cliente: el total es de la ventana, no del LIMIT
-- ---------------------------------------------------------------------------
-- Mismo alcance por rol que la 296. La ventana va por `fecha` (dia argentino),
-- como todo reporte; los cancelados siguen afuera. `pedidos_count` y
-- `total_periodo` son de TODA la ventana; `pedidos` trae los ultimos p_limit.
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
    'criterio', 'Pedidos no cancelados (tomados y entregados), por fecha del pedido.',
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
-- 5 · bot_ficha_producto: venta de la 241, regalado aparte
-- ---------------------------------------------------------------------------
-- Misma firma. Ultimos 30 dias argentinos por `fecha`, entregado y no cambio.
-- `ultima_venta` pasa a ser la fecha (dia) de la ultima venta, no un timestamp
-- de carga.
CREATE OR REPLACE FUNCTION public.bot_ficha_producto(p_producto_id bigint, p_sucursal_id bigint)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  resultado JSON;
  -- Ultimos 30 dias = hoy y los 29 anteriores.
  v_desde   DATE := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date - 29;
BEGIN
  WITH ventas AS (
    SELECT pi.cantidad, COALESCE(pi.es_bonificacion, false) AS regalo, pe.fecha
      FROM pedido_items pi
      JOIN pedidos pe ON pe.id = pi.pedido_id
     WHERE pi.producto_id = p_producto_id
       AND pe.sucursal_id = p_sucursal_id
       AND pe.estado = 'entregado' AND pe.canal <> 'cambio'
  )
  SELECT json_build_object(
    'producto', json_build_object(
      'id', p.id,
      'codigo', p.codigo,
      'nombre', p.nombre,
      'precio', p.precio,
      'precio_sin_iva', p.precio_sin_iva,
      'stock', p.stock,
      'stock_minimo', p.stock_minimo,
      'categoria', p.categoria,
      'proveedor_id', p.proveedor_id
    ),
    'ventas_30d_cantidad',
      (SELECT COALESCE(SUM(cantidad), 0)::INTEGER FROM ventas WHERE NOT regalo AND fecha >= v_desde),
    'regaladas_30d_cantidad',
      (SELECT COALESCE(SUM(cantidad), 0)::INTEGER FROM ventas WHERE regalo AND fecha >= v_desde),
    'ultima_venta', (SELECT MAX(fecha) FROM ventas WHERE NOT regalo),
    'criterio', 'Unidades entregadas (venta), ultimos 30 dias por fecha del pedido. Las regaladas van aparte.'
  ) INTO resultado
  FROM productos p
  WHERE p.id = p_producto_id
    AND p.sucursal_id = p_sucursal_id;
  RETURN resultado;
END;
$function$;


-- ---------------------------------------------------------------------------
-- 6 · obtener_resumen_cuenta_cliente_bot: como la ficha de la app
-- ---------------------------------------------------------------------------
-- useFichaCliente excluye los cancelados de la cantidad, del total y del ultimo
-- pedido. La copia del bot los contaba.
CREATE OR REPLACE FUNCTION public.obtener_resumen_cuenta_cliente_bot(p_cliente_id integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  resultado JSON;
BEGIN
  SELECT json_build_object(
    'saldo_actual', COALESCE(c.saldo_cuenta, 0),
    'limite_credito', COALESCE(c.limite_credito, 0),
    'credito_disponible', COALESCE(c.limite_credito, 0) - COALESCE(c.saldo_cuenta, 0),
    'total_pedidos', (SELECT COUNT(*) FROM pedidos
                       WHERE cliente_id = p_cliente_id AND estado IS DISTINCT FROM 'cancelado'),
    'total_compras', (SELECT COALESCE(SUM(total), 0) FROM pedidos
                       WHERE cliente_id = p_cliente_id AND estado IS DISTINCT FROM 'cancelado'),
    'total_pagos', (SELECT COALESCE(SUM(monto), 0) FROM pagos WHERE cliente_id = p_cliente_id),
    'pedidos_pendientes_pago', (SELECT COUNT(*) FROM pedidos
                                 WHERE cliente_id = p_cliente_id
                                   AND estado IS DISTINCT FROM 'cancelado'
                                   AND estado_pago IS DISTINCT FROM 'pagado'),
    'ultimo_pedido', (SELECT MAX(created_at) FROM pedidos
                       WHERE cliente_id = p_cliente_id AND estado IS DISTINCT FROM 'cancelado'),
    'ultimo_pago', (SELECT MAX(created_at) FROM pagos WHERE cliente_id = p_cliente_id),
    'es_comodin', COALESCE(c.es_comodin, false)
  ) INTO resultado
  FROM clientes c
  WHERE c.id = p_cliente_id;

  RETURN resultado;
END;
$function$;


-- ---------------------------------------------------------------------------
-- 7 · Top clientes con la etiqueta de comodin (ventas_periodo, mis_ventas)
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._mig300_ancla('public.bot_ventas_periodo(date,date,bigint,integer)'::regprocedure,
$a$    SELECT c.id, c.codigo, c.nombre_fantasia, c.razon_social,
      SUM(v.total) AS total_comprado, COUNT(*) AS pedidos
    FROM ventas_filtradas v JOIN clientes c ON c.id = v.cliente_id
    GROUP BY c.id, c.codigo, c.nombre_fantasia, c.razon_social$a$,
$n$    SELECT c.id, c.codigo, c.nombre_fantasia, c.razon_social, c.es_comodin,
      SUM(v.total) AS total_comprado, COUNT(*) AS pedidos
    FROM ventas_filtradas v JOIN clientes c ON c.id = v.cliente_id
    GROUP BY c.id, c.codigo, c.nombre_fantasia, c.razon_social, c.es_comodin$n$);

  PERFORM public._mig300_ancla('public.bot_mis_ventas(uuid,date,date,bigint,integer)'::regprocedure,
$a$    SELECT c.id AS cliente_id, c.codigo AS cliente_codigo,
      c.nombre_fantasia, c.razon_social,
      SUM(v.total) AS total_comprado, COUNT(*) AS pedidos
    FROM ventas_filtradas v JOIN clientes c ON c.id = v.cliente_id
    GROUP BY c.id, c.codigo, c.nombre_fantasia, c.razon_social$a$,
$n$    SELECT c.id AS cliente_id, c.codigo AS cliente_codigo,
      c.nombre_fantasia, c.razon_social, c.es_comodin,
      SUM(v.total) AS total_comprado, COUNT(*) AS pedidos
    FROM ventas_filtradas v JOIN clientes c ON c.id = v.cliente_id
    GROUP BY c.id, c.codigo, c.nombre_fantasia, c.razon_social, c.es_comodin$n$);
END
$patch$;


-- ---------------------------------------------------------------------------
-- 8 · Digest: lo entregado al lado de lo tomado, y el comodin etiquetado
-- ---------------------------------------------------------------------------
-- `ventas_dia` queda como esta (pedidos no cancelados del dia: es lo que
-- muestra el Dashboard). `entregado_dia` es la venta de la 241 por fecha.
DO $patch$
BEGIN
  PERFORM public._mig300_ancla('public.bot_metricas_admin_dia(date,bigint)'::regprocedure,
$a$  promedio_7d AS ($a$,
$n$  entregado_dia AS (
    SELECT
      COUNT(*)                                                   AS pedidos,
      COALESCE(SUM(total), 0)::numeric(14,2)                     AS total
    FROM pedidos
    WHERE fecha = p_fecha
      AND estado = 'entregado' AND canal <> 'cambio'
      AND (p_sucursal_id IS NULL OR sucursal_id = p_sucursal_id)
  ),
  promedio_7d AS ($n$);

  PERFORM public._mig300_ancla('public.bot_metricas_admin_dia(date,bigint)'::regprocedure,
$a$      COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social, '(sin nombre)') AS nombre,
      COUNT(*)                                                   AS pedidos,
      SUM(pd.total)::numeric(14,2)                               AS total
    FROM pedidos_dia pd
    LEFT JOIN clientes c ON c.id = pd.cliente_id
    GROUP BY pd.cliente_id, c.nombre_fantasia, c.razon_social$a$,
$n$      COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social, '(sin nombre)') AS nombre,
      COALESCE(c.es_comodin, false)                              AS es_comodin,
      COUNT(*)                                                   AS pedidos,
      SUM(pd.total)::numeric(14,2)                               AS total
    FROM pedidos_dia pd
    LEFT JOIN clientes c ON c.id = pd.cliente_id
    GROUP BY pd.cliente_id, c.nombre_fantasia, c.razon_social, c.es_comodin$n$);

  PERFORM public._mig300_ancla('public.bot_metricas_admin_dia(date,bigint)'::regprocedure,
$a$    'ventas_dia',             (SELECT row_to_json(v) FROM ventas_dia v),$a$,
$n$    'ventas_dia',             (SELECT row_to_json(v) FROM ventas_dia v),
    'entregado_dia',          (SELECT row_to_json(e) FROM entregado_dia e),$n$);
END
$patch$;


-- ---------------------------------------------------------------------------
-- 9 · RFM y mis_clientes: la comanda de un cambio no es una compra
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._mig300_ancla('public.bot_sugerir_visitas_rfm(uuid,bigint,integer)'::regprocedure,
$a$    WHERE p.fecha >= CURRENT_DATE - INTERVAL '180 days'
      AND p.estado <> 'cancelado'$a$,
$n$    WHERE p.fecha >= CURRENT_DATE - INTERVAL '180 days'
      AND p.estado <> 'cancelado'
      AND p.canal <> 'cambio' -- 300: la comanda de un canje tiene total 0$n$);

  PERFORM public._mig300_ancla('public.bot_mis_clientes(uuid,bigint,boolean,integer,integer)'::regprocedure,
$a$        WHERE p.cliente_id = c.id
          AND p.estado <> 'cancelado'$a$,
$n$        WHERE p.cliente_id = c.id
          AND p.estado <> 'cancelado'
          AND p.canal <> 'cambio' -- 300: la comanda de un canje no es una compra$n$);
END
$patch$;


-- ---------------------------------------------------------------------------
-- 10 · BOT-B: cada funcion del bot que da un numero de la app consume la
--      funcion de esa pantalla
-- ---------------------------------------------------------------------------
-- Mapa explicito: si alguien reescribe una de estas con su propia consulta,
-- vuelve el riesgo de que el bot y la pantalla digan numeros distintos sin que
-- falle nada. Al agregar un par nuevo, sumarlo aca.
CREATE OR REPLACE FUNCTION public.auditoria_bot_sin_funcion_canonica()
 RETURNS bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT count(*)
    FROM (VALUES
      ('public.bot_pendientes_pago(bigint,integer,integer)',                'reporte_cuentas_por_cobrar'),
      ('public.bot_ventas_por_preventista(date,date,bigint,boolean,integer)', 'reporte_ventas_por_preventista')
    ) AS m(funcion, canonica)
   WHERE to_regprocedure(m.funcion) IS NULL
      -- Sin comentarios: un "-- antes llamaba a reporte_x(" no cuenta como llamada.
      OR regexp_replace(pg_get_functiondef(to_regprocedure(m.funcion)), '--[^\n]*', '', 'g')
           NOT ILIKE '%' || m.canonica || '(%';
$function$;

COMMENT ON FUNCTION public.auditoria_bot_sin_funcion_canonica() IS
  'BOT-B (300). Cubre las funciones del bot que ya consumen la de la pantalla. Las que todavia copian la definicion de venta (bot_ventas_periodo, bot_mis_ventas, bot_ficha_producto, bot_historico_pedidos_cliente, obtener_resumen_cuenta_cliente_bot) no estan aca: no hay una funcion canonica que consumir.';

-- Solo la llama auditoria_integridad (SECURITY DEFINER): las tres mitades.
REVOKE EXECUTE ON FUNCTION public.auditoria_bot_sin_funcion_canonica() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auditoria_bot_sin_funcion_canonica() TO service_role;

DO $patch$
BEGIN
  PERFORM public._mig300_ancla('public.auditoria_integridad()'::regprocedure,
$a$    ('COSTO-D','high',$a$,
$n$    ('BOT-B','high','funciones del bot que dejaron de consumir la funcion de la pantalla que muestra el mismo numero (mig 300, #977)',
      (SELECT public.auditoria_bot_sin_funcion_canonica())),
    ('COSTO-D','high',$n$);
END
$patch$;


-- ---------------------------------------------------------------------------
-- 11 · El ensayo: los numeros del bot son los de la pantalla
-- ---------------------------------------------------------------------------
DO $ensayo$
DECLARE
  s          RECORD;
  v_bot      json;
  v_rep      jsonb;
  v_hasta    date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_desde    date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date - 30;
  v_esperado numeric;
  v_obtenido numeric;
  v_cli      RECORD;
  v_aud      jsonb;
BEGIN
  FOR s IN SELECT id FROM sucursales WHERE activa LOOP
    -- 11a. Deuda: el bot == Cuentas por cobrar.
    v_bot := bot_pendientes_pago(s.id, 0, 100);
    v_rep := reporte_cuentas_por_cobrar(s.id);
    -- Tolerancia de centavos: la pantalla redondea el total y cada cliente por
    -- separado, y el bot suma los clientes redondeados.
    IF abs((v_bot ->> 'total_global')::numeric - (v_rep -> 'totales' ->> 'saldo')::numeric) > 1 THEN
      RAISE EXCEPTION 'ensayo 300: deuda de la sucursal %: bot % vs pantalla %',
        s.id, v_bot ->> 'total_global', v_rep -> 'totales' ->> 'saldo';
    END IF;

    -- 11b. Ventas por preventista con todos los roles == Reportes.
    v_bot := bot_ventas_por_preventista(v_desde, v_hasta, s.id, false, 100);
    SELECT COALESCE(SUM((x ->> 'totalVentas')::numeric), 0) INTO v_esperado
      FROM jsonb_array_elements(reporte_ventas_por_preventista(v_desde, v_hasta, s.id)) x;
    IF (v_bot ->> 'total_ventas')::numeric <> v_esperado
       OR (v_bot ->> 'total_todos_los_roles')::numeric <> v_esperado THEN
      RAISE EXCEPTION 'ensayo 300: ventas por preventista de la sucursal %: bot % vs pantalla %',
        s.id, v_bot ->> 'total_ventas', v_esperado;
    END IF;

    -- 11c. Solo preventistas + excluidos == todos.
    v_bot := bot_ventas_por_preventista(v_desde, v_hasta, s.id, true, 100);
    SELECT COALESCE(SUM((e ->> 'total_vendido')::numeric), 0) INTO v_obtenido
      FROM json_array_elements(v_bot -> 'excluidos') e;
    IF (v_bot ->> 'total_ventas')::numeric + v_obtenido <> v_esperado THEN
      RAISE EXCEPTION 'ensayo 300: preventistas (%) + excluidos (%) no da el total (%) en la sucursal %',
        v_bot ->> 'total_ventas', v_obtenido, v_esperado, s.id;
    END IF;
  END LOOP;

  -- 11d. Historial: el total es de la ventana, aunque se muestre un pedido.
  FOR v_cli IN
    SELECT cliente_id, sucursal_id, COUNT(*) n, SUM(total) total
      FROM pedidos
     WHERE fecha >= (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date - 364
       AND COALESCE(estado, '') <> 'cancelado'
     GROUP BY cliente_id, sucursal_id
    HAVING COUNT(*) > 3
     ORDER BY COUNT(*) DESC
     LIMIT 10
  LOOP
    v_bot := bot_historico_pedidos_cliente(v_cli.cliente_id, NULL, 'admin', v_cli.sucursal_id, 365, 1);
    IF (v_bot ->> 'total_periodo')::numeric <> v_cli.total
       OR (v_bot ->> 'pedidos_count')::int <> v_cli.n
       OR (v_bot ->> 'pedidos_mostrados')::int <> 1 THEN
      RAISE EXCEPTION 'ensayo 300: historial del cliente %: total % (esperado %), pedidos % (esperado %), mostrados %',
        v_cli.cliente_id, v_bot ->> 'total_periodo', v_cli.total,
        v_bot ->> 'pedidos_count', v_cli.n, v_bot ->> 'pedidos_mostrados';
    END IF;
  END LOOP;

  -- 11e. Ficha del cliente == useFichaCliente (no cancelados).
  FOR v_cli IN
    SELECT cliente_id,
           COUNT(*) FILTER (WHERE estado IS DISTINCT FROM 'cancelado') n,
           COALESCE(SUM(total) FILTER (WHERE estado IS DISTINCT FROM 'cancelado'), 0) total
      FROM pedidos
     GROUP BY cliente_id
    HAVING COUNT(*) FILTER (WHERE estado = 'cancelado') > 0
     LIMIT 10
  LOOP
    v_bot := obtener_resumen_cuenta_cliente_bot(v_cli.cliente_id::integer);
    IF (v_bot ->> 'total_pedidos')::int <> v_cli.n OR (v_bot ->> 'total_compras')::numeric <> v_cli.total THEN
      RAISE EXCEPTION 'ensayo 300: ficha del cliente %: % pedidos / $% (esperado % / $%)',
        v_cli.cliente_id, v_bot ->> 'total_pedidos', v_bot ->> 'total_compras', v_cli.n, v_cli.total;
    END IF;
  END LOOP;

  -- 11e2. Los cuerpos parchados por ancla corren (plpgsql se resuelve recien
  --       al ejecutar), y la ficha de producto suma lo mismo que la definicion.
  FOR s IN SELECT id FROM sucursales WHERE activa LOOP
    PERFORM bot_ventas_periodo(v_desde, v_hasta, s.id, 5);
    PERFORM bot_metricas_admin_dia(v_hasta - 1, s.id);
    PERFORM bot_sugerir_visitas_rfm(pf.id, s.id, 5)
       FROM perfiles pf WHERE pf.rol = 'preventista' AND pf.activo LIMIT 1;
    PERFORM bot_mis_clientes(pf.id, s.id, false, NULL, 5)
       FROM perfiles pf WHERE pf.rol = 'preventista' AND pf.activo LIMIT 1;
    PERFORM bot_mis_ventas(pf.id, v_desde, v_hasta, s.id, 5)
       FROM perfiles pf WHERE pf.rol = 'preventista' AND pf.activo LIMIT 1;
  END LOOP;
  FOR v_cli IN
    SELECT pi.producto_id, pe.sucursal_id,
           SUM(pi.cantidad) FILTER (WHERE NOT COALESCE(pi.es_bonificacion, false)) AS vendidas,
           SUM(pi.cantidad) FILTER (WHERE COALESCE(pi.es_bonificacion, false))     AS regaladas
      FROM pedido_items pi JOIN pedidos pe ON pe.id = pi.pedido_id
     WHERE pe.estado = 'entregado' AND pe.canal <> 'cambio'
       AND pe.fecha >= (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date - 29
     GROUP BY pi.producto_id, pe.sucursal_id
     ORDER BY SUM(pi.cantidad) DESC
     LIMIT 10
  LOOP
    v_bot := bot_ficha_producto(v_cli.producto_id, v_cli.sucursal_id);
    IF (v_bot ->> 'ventas_30d_cantidad')::numeric <> COALESCE(v_cli.vendidas, 0)
       OR (v_bot ->> 'regaladas_30d_cantidad')::numeric <> COALESCE(v_cli.regaladas, 0) THEN
      RAISE EXCEPTION 'ensayo 300: ficha del producto %: % vendidas / % regaladas (esperado % / %)',
        v_cli.producto_id, v_bot ->> 'ventas_30d_cantidad', v_bot ->> 'regaladas_30d_cantidad',
        v_cli.vendidas, v_cli.regaladas;
    END IF;
  END LOOP;

  -- 11f. El comodin quedo marcado y aparece etiquetado.
  IF NOT EXISTS (SELECT 1 FROM clientes WHERE es_comodin) THEN
    RAISE NOTICE 'ensayo 300: no hay ningun cliente comodin marcado (no se encontro "Cliente extra")';
  END IF;

  -- 11g. BOT-B existe, esta en verde y es high.
  v_aud := auditoria_integridad();
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_aud -> 'checks') c
     WHERE c ->> 'id' = 'BOT-B' AND (c ->> 'ok')::boolean AND c ->> 'severidad' = 'high'
  ) THEN
    RAISE EXCEPTION 'ensayo 300: BOT-B no esta en verde: %',
      (SELECT c FROM jsonb_array_elements(v_aud -> 'checks') c WHERE c ->> 'id' = 'BOT-B');
  END IF;
  IF (SELECT count(*) FROM jsonb_array_elements(v_aud -> 'checks') c WHERE c ->> 'id' = 'BOT-B') <> 1 THEN
    RAISE EXCEPTION 'ensayo 300: el id BOT-B aparece mas de una vez en auditoria_integridad';
  END IF;

  RAISE NOTICE 'ensayo 300: deuda, ventas por preventista, historial, ficha y BOT-B, OK';
END;
$ensayo$;

-- ---------------------------------------------------------------------------
-- 12 · Se saca el andamio.
-- ---------------------------------------------------------------------------
DROP FUNCTION public._mig300_ancla(regprocedure, text, text);

COMMIT;
