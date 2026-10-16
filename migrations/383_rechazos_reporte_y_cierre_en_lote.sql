-- 383 · Rechazos: el reporte de causas y el cierre en lote del atraso (#1198).
--
-- 1) reporte_rechazos(p_desde, p_hasta, p_sucursal_id)
--
--    Junta los dos rechazos que hoy viven en lugares distintos:
--      - total:   un pedido cancelado cuyo motivo_cancelacion_tipo NO es
--                 administrativo (la lista negra de la 179 + falta_stock de la
--                 269; espejo: MOTIVOS_ADMINISTRATIVOS en
--                 src/constants/desenlacePedido.ts, y un test lee este archivo
--                 para que no se separen). Un cancelado sin motivo cuenta como
--                 rechazo, igual que en jornadas_preventista.
--      - parcial: una salvedad vigente (estado_resolucion <> 'anulada'). La
--                 resuelta sigue siendo un rechazo: resolverla dice quien se hace
--                 cargo, no que no paso. Por eso el cierre en lote de abajo no
--                 mueve ningun numero de este reporte.
--    Fuera: canal 'cambio' (la comanda de un canje, total 0 por CAMBIO-01) y el
--    vale blanco ('VB': consumo interno a costo, no una entrega a un cliente; es
--    la misma exclusion de jornadas_preventista). Una salvedad cuenta SOLO si su
--    pedido salio (entregado o rechazado entero): la de un cancelado
--    administrativo ('prueba', 'error_de_carga'...) no es un rechazo.
--    Corte: pedidos.fecha (de la salvedad, la de su pedido).
--
--    El reporte muestra CAUSAS, no culpas (decision del duenio, 2026-10-15):
--    no hay responsable por motivo ni por rol. Dice que paso, donde y con quien
--    --motivo, preventista (pedidos.usuario_id), chofer
--    (pedidos.transportista_id), cliente y producto-- y el gerente decide.
--
--    Tres montos, que no se suman entre si:
--      - venta_perdida: lo rechazado que VOLVIO al stock, a precio de venta.
--          total:   SUM(cantidad * precio_unitario) de sus lineas (cancelar no
--                   toca pedido_items: quedan con su cantidad y su precio; si
--                   antes hubo una salvedad, la linea ya viene recortada y no
--                   se cuenta dos veces).
--          parcial: monto_afectado de la salvedad que devolvio stock y NO
--                   genero merma.
--      - perdida_real: lo mermado (danado, vencido, faltante), a COSTO. Sale de
--          mermas_valorizadas() --la unica implementacion de la cascada (mig
--          238)-- unida a mermas_stock por id y filtrada por salvedad_id. No hay
--          cascada nueva. Una merma sin costo cargado no suma y se cuenta en
--          mermas_sin_costo.
--      - monto: todo lo rechazado a precio de venta (informativo). La diferencia
--          entre monto y venta_perdida es lo mermado (a precio) mas lo que no
--          movio stock (una salvedad 'otro' vieja, una bonificacion que no
--          mueve stock).
--    Si una salvedad devolviera stock Y mermara a la vez (hoy ninguna: son
--    motivos distintos, #1127 las cancela entre si), cuenta como mermada: esas
--    unidades volvieron y se dieron de baja en el mismo movimiento.
--
--    Tasa de rechazo = (rechazos totales + pedidos entregados con salvedad) /
--    pedidos que salieron, con "salieron" = entregados + rechazos totales (el
--    denominador de jornadas_preventista, mig 179, que tambien deja afuera el
--    VB). Se da tambien partida: tasa_rechazo_total y tasa_con_salvedad. Espejo puro: src/utils/rechazos.ts.
--
--    Guard y sucursales calcados de reporte_mermas (367): admin o encargado,
--    p_sucursal_id NULL = la red (activas INTERSECT asignadas). Los clientes
--    inactivos se siguen viendo: es historial.
--
-- 2) cerrar_salvedades_en_lote(p_hasta, p_notas, p_solo_contar)
--
--    344 salvedades pendientes desde abril y ninguna resuelta: resolverlas de a
--    una son 344 llamadas a resolver_salvedad. Esta RPC las cierra de una vez,
--    SOLO admin, en la sucursal activa (current_sucursal_id(), como
--    resolver_salvedad), las que siguen 'pendiente' y se cargaron hasta p_hasta
--    (dia argentino de created_at, el mismo corte que los filtros del panel).
--    Estado 'resuelto_otro', con una nota que dice que fue un cierre en lote y
--    hasta que fecha, resolucion_fecha, resuelto_por y una fila de
--    salvedad_historial por cada una (como resolver_salvedad).
--    NO toca stock ni plata: el stock se movio al registrar la salvedad. NO pasa
--    por anular_salvedad (eso si mueve las dos cosas). El UPDATE no nombra
--    lotes_devueltos, asi que el trigger que lo protege no corre.
--    p_solo_contar = true devuelve cuantas cerraria sin cerrar nada: es lo que
--    muestra el modal antes de confirmar.
--
-- Las dos son SECURITY DEFINER de postgres, con REVOKE ... FROM PUBLIC, anon y
-- EXECUTE para authenticated y service_role (las llama el front). Parametros
-- en tipos que PostgREST resuelve (date, bigint, text, boolean).

-- ---------------------------------------------------------------------------
-- 1) reporte_rechazos
-- ---------------------------------------------------------------------------

CREATE FUNCTION public.reporte_rechazos(
  p_desde date,
  p_hasta date,
  p_sucursal_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursales  bigint[];
  v_asignadas   bigint[];
  v_es_servicio boolean := (auth.uid() IS NULL);
  v_rol         text;
  v_nombre      text;
  -- Espejo de MOTIVOS_ADMINISTRATIVOS (src/constants/desenlacePedido.ts): los
  -- cancelados con estos motivos no son un rechazo, son una correccion. Lo
  -- vigila src/utils/rechazos.test.ts leyendo esta linea.
  v_motivos_admin text[] := ARRAY['error_de_carga','prueba','duplicado','unifica_pedidos','cambio_de_cliente','falta_stock'];
  -- Tope del detalle. Los totales y los cortes van sobre el periodo COMPLETO.
  v_limite      integer := 3000;
  v_mdesde      date;
  v_mhasta      date;
  v_out         jsonb;
BEGIN
  IF p_desde IS NULL OR p_hasta IS NULL THEN
    RAISE EXCEPTION 'reporte_rechazos: el periodo (desde y hasta) es obligatorio';
  END IF;
  IF p_hasta < p_desde THEN
    RAISE EXCEPTION 'reporte_rechazos: el periodo termina antes de empezar (% > %)', p_desde, p_hasta;
  END IF;

  -- Guard identico al de reporte_mermas (367): la familia de /reportes.
  IF NOT v_es_servicio THEN
    SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();
    IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
      RAISE EXCEPTION 'Acceso denegado: se requiere rol admin o encargado';
    END IF;
    SELECT array_agg(sucursal_id) INTO v_asignadas
      FROM usuario_sucursales WHERE usuario_id = auth.uid();
    IF v_asignadas IS NULL THEN
      RAISE EXCEPTION 'Acceso denegado: el usuario no tiene sucursales asignadas';
    END IF;
  END IF;

  -- Resolucion de sucursales calcada de la 367 (activas INTERSECT asignadas).
  IF p_sucursal_id IS NULL THEN
    SELECT array_agg(id) INTO v_sucursales FROM sucursales WHERE activa;
    IF NOT v_es_servicio THEN
      SELECT array_agg(s) INTO v_sucursales FROM unnest(v_sucursales) AS s WHERE s = ANY(v_asignadas);
    END IF;
    v_nombre := 'Red (consolidado)';
  ELSE
    IF NOT v_es_servicio AND NOT (p_sucursal_id = ANY(v_asignadas)) THEN
      RAISE EXCEPTION 'Acceso denegado: la sucursal % no esta asignada al usuario', p_sucursal_id;
    END IF;
    v_sucursales := ARRAY[p_sucursal_id];
    SELECT nombre INTO v_nombre FROM sucursales WHERE id = p_sucursal_id;
  END IF;
  IF v_sucursales IS NULL OR array_length(v_sucursales, 1) IS NULL THEN
    RAISE EXCEPTION 'Acceso denegado: sin sucursales disponibles para el usuario';
  END IF;

  -- mermas_valorizadas corta por dia de CARGA de la merma; este reporte corta
  -- por la fecha del PEDIDO. Se le pide el rango de carga que cubre a las
  -- mermas de las salvedades del periodo, y se une por id.
  SELECT min((m.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date),
         max((m.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date)
    INTO v_mdesde, v_mhasta
    FROM mermas_stock m
    JOIN salvedades_items si ON si.id = m.salvedad_id
    JOIN pedidos p           ON p.id = si.pedido_id
   WHERE p.sucursal_id = ANY(v_sucursales)
     AND p.fecha BETWEEN p_desde AND p_hasta;

  WITH
  -- Los pedidos que salieron: entregados y rechazados enteros. Un cancelado
  -- administrativo no salio (no debia existir o lo reemplazo otro).
  ped AS (
    SELECT p.id, p.fecha, p.sucursal_id, p.cliente_id, p.usuario_id, p.transportista_id,
           p.motivo_cancelacion_tipo, p.motivo_cancelacion,
           (p.estado = 'cancelado') AS rechazo_total
      FROM pedidos p
     WHERE p.sucursal_id = ANY(v_sucursales)
       AND p.fecha BETWEEN p_desde AND p_hasta
       AND p.canal <> 'cambio'
       AND p.tipo_factura IS DISTINCT FROM 'VB'
       AND (p.estado = 'entregado'
            OR (p.estado = 'cancelado'
                AND (p.motivo_cancelacion_tipo IS NULL
                     OR NOT (p.motivo_cancelacion_tipo = ANY(v_motivos_admin)))))
  ),
  -- Las salvedades vigentes de los pedidos que salieron (los de `ped`): una
  -- salvedad sobre un cancelado administrativo o sobre un vale blanco no es un
  -- rechazo, y dejaria los cortes sin cerrar contra la base de la tasa.
  salv AS (
    SELECT si.id, si.pedido_id, si.producto_id, si.motivo, si.descripcion,
           si.cantidad_afectada, si.monto_afectado, si.stock_devuelto, si.estado_resolucion,
           p.fecha, p.sucursal_id, p.cliente_id, p.usuario_id, p.transportista_id
      FROM salvedades_items si
      JOIN ped p ON p.id = si.pedido_id
     WHERE si.estado_resolucion <> 'anulada'
  ),
  -- La merma de cada salvedad, valuada por mermas_valorizadas (mig 238): ni la
  -- cascada ni el filtro de anuladas se escriben aca. `costo_unitario IS NULL`
  -- de esa funcion ES el predicado sin_costo.
  merma AS (
    SELECT m.salvedad_id,
           COALESCE(SUM(mv.costo_total), 0)                AS costo,
           COUNT(*) FILTER (WHERE mv.costo_unitario IS NULL) AS sin_costo
      FROM public.mermas_valorizadas(v_mdesde, v_mhasta, v_sucursales) mv
      JOIN mermas_stock m ON m.id = mv.id
     WHERE m.salvedad_id IN (SELECT id FROM salv)
     GROUP BY m.salvedad_id
  ),
  -- Las lineas de los rechazos enteros (cancelar no toca pedido_items).
  lineas_total AS (
    SELECT pi.pedido_id, pi.producto_id, pi.cantidad,
           pi.cantidad * pi.precio_unitario AS monto
      FROM ped p
      JOIN pedido_items pi ON pi.pedido_id = p.id
     WHERE p.rechazo_total
  ),
  -- Un evento por rechazo: un pedido entero o una linea con salvedad.
  ev AS (
    SELECT 'total'::text AS tipo, p.id AS pedido_id, NULL::bigint AS salvedad_id,
           p.fecha, p.sucursal_id, p.cliente_id, p.usuario_id, p.transportista_id,
           COALESCE(NULLIF(p.motivo_cancelacion_tipo, ''), 'sin_motivo')::text AS motivo,
           p.motivo_cancelacion::text AS descripcion,
           NULL::bigint AS producto_id,
           COALESCE(l.lineas, 0)::integer AS lineas,
           COALESCE(l.unidades, 0)::numeric AS unidades,
           COALESCE(l.monto, 0)::numeric AS monto,
           COALESCE(l.monto, 0)::numeric AS venta_perdida,
           0::numeric AS perdida_real,
           0::integer AS mermas_sin_costo,
           'devuelto'::text AS destino,
           NULL::text AS estado_resolucion
      FROM ped p
      LEFT JOIN (SELECT pedido_id, COUNT(*) AS lineas, SUM(cantidad) AS unidades, SUM(monto) AS monto
                   FROM lineas_total GROUP BY pedido_id) l ON l.pedido_id = p.id
     WHERE p.rechazo_total
    UNION ALL
    SELECT 'parcial', s.pedido_id, s.id,
           s.fecha, s.sucursal_id, s.cliente_id, s.usuario_id, s.transportista_id,
           s.motivo::text, s.descripcion,
           s.producto_id,
           1,
           COALESCE(s.cantidad_afectada, 0)::numeric,
           COALESCE(s.monto_afectado, 0)::numeric,
           CASE WHEN mm.salvedad_id IS NULL AND s.stock_devuelto
                THEN COALESCE(s.monto_afectado, 0) ELSE 0 END::numeric,
           COALESCE(mm.costo, 0)::numeric,
           COALESCE(mm.sin_costo, 0)::integer,
           CASE WHEN mm.salvedad_id IS NOT NULL THEN 'mermado'
                WHEN s.stock_devuelto THEN 'devuelto'
                ELSE 'sin_movimiento' END,
           s.estado_resolucion::text
      FROM salv s
      LEFT JOIN merma mm ON mm.salvedad_id = s.id
  ),
  -- La base de la tasa: cada pedido que salio, y si se entrego con salvedad.
  base AS (
    SELECT p.*,
           (NOT p.rechazo_total AND EXISTS (SELECT 1 FROM salv s WHERE s.pedido_id = p.id)) AS con_salvedad
      FROM ped p
  ),
  -- Pedidos y eventos en una sola tira, para cortar por preventista y por chofer
  -- sin perder a los que no tienen (NULL agrupa como uno).
  dim AS (
    SELECT usuario_id, transportista_id,
           1 AS salieron, (NOT rechazo_total)::int AS entregados, rechazo_total::int AS rechazos_totales,
           con_salvedad::int AS pedidos_con_salvedad,
           0 AS lineas_salvedad, 0::numeric AS monto, 0::numeric AS venta_perdida, 0::numeric AS perdida_real
      FROM base
    UNION ALL
    SELECT usuario_id, transportista_id, 0, 0, 0, 0,
           (tipo = 'parcial')::int, monto, venta_perdida, perdida_real
      FROM ev
  ),
  por_preventista AS (
    SELECT d.usuario_id, per.nombre,
           SUM(salieron) AS pedidos_salieron, SUM(entregados) AS pedidos_entregados,
           SUM(rechazos_totales) AS rechazos_totales, SUM(pedidos_con_salvedad) AS pedidos_con_salvedad,
           SUM(lineas_salvedad) AS lineas_salvedad, SUM(monto) AS monto,
           SUM(venta_perdida) AS venta_perdida, SUM(perdida_real) AS perdida_real
      FROM dim d LEFT JOIN perfiles per ON per.id = d.usuario_id
     GROUP BY d.usuario_id, per.nombre
  ),
  por_chofer AS (
    SELECT d.transportista_id, per.nombre,
           SUM(salieron) AS pedidos_salieron, SUM(entregados) AS pedidos_entregados,
           SUM(rechazos_totales) AS rechazos_totales, SUM(pedidos_con_salvedad) AS pedidos_con_salvedad,
           SUM(lineas_salvedad) AS lineas_salvedad, SUM(monto) AS monto,
           SUM(venta_perdida) AS venta_perdida, SUM(perdida_real) AS perdida_real
      FROM dim d LEFT JOIN perfiles per ON per.id = d.transportista_id
     GROUP BY d.transportista_id, per.nombre
  ),
  por_motivo AS (
    SELECT tipo, motivo, COUNT(*) AS casos, SUM(unidades) AS unidades, SUM(monto) AS monto,
           SUM(venta_perdida) AS venta_perdida, SUM(perdida_real) AS perdida_real
      FROM ev GROUP BY tipo, motivo
  ),
  -- Historial: el cliente inactivo se sigue viendo (no se filtra activo).
  por_cliente AS (
    SELECT e.cliente_id, COALESCE(c.nombre_fantasia, c.razon_social) AS nombre, c.codigo, c.activo,
           COUNT(*) FILTER (WHERE e.tipo = 'total')   AS rechazos_totales,
           COUNT(*) FILTER (WHERE e.tipo = 'parcial') AS lineas_salvedad,
           SUM(e.monto) AS monto, SUM(e.venta_perdida) AS venta_perdida, SUM(e.perdida_real) AS perdida_real
      FROM ev e LEFT JOIN clientes c ON c.id = e.cliente_id
     GROUP BY e.cliente_id, c.nombre_fantasia, c.razon_social, c.codigo, c.activo
  ),
  prod_ev AS (
    SELECT producto_id, 'total'::text AS tipo, cantidad::numeric AS unidades, monto::numeric AS monto,
           monto::numeric AS venta_perdida, 0::numeric AS perdida_real
      FROM lineas_total
    UNION ALL
    SELECT producto_id, 'parcial', unidades, monto, venta_perdida, perdida_real
      FROM ev WHERE tipo = 'parcial'
  ),
  por_producto AS (
    SELECT pe.producto_id, pr.nombre, pr.codigo,
           COALESCE(SUM(pe.unidades) FILTER (WHERE pe.tipo = 'total'), 0)   AS unidades_total,
           COALESCE(SUM(pe.unidades) FILTER (WHERE pe.tipo = 'parcial'), 0) AS unidades_parcial,
           COUNT(*) FILTER (WHERE pe.tipo = 'parcial') AS lineas_salvedad,
           SUM(pe.monto) AS monto, SUM(pe.venta_perdida) AS venta_perdida, SUM(pe.perdida_real) AS perdida_real
      FROM prod_ev pe LEFT JOIN productos pr ON pr.id = pe.producto_id
     GROUP BY pe.producto_id, pr.nombre, pr.codigo
  ),
  tot AS (
    SELECT b.*, e.*
      FROM (SELECT COUNT(*) AS pedidos_salieron,
                   COUNT(*) FILTER (WHERE NOT rechazo_total) AS pedidos_entregados,
                   COUNT(*) FILTER (WHERE rechazo_total)     AS rechazos_totales,
                   COUNT(*) FILTER (WHERE con_salvedad)      AS pedidos_con_salvedad
              FROM base) b,
           (SELECT COUNT(*) FILTER (WHERE tipo = 'parcial') AS lineas_salvedad,
                   COUNT(*) FILTER (WHERE tipo = 'parcial' AND estado_resolucion = 'pendiente') AS salvedades_pendientes,
                   COALESCE(SUM(monto), 0)                                   AS monto,
                   COALESCE(SUM(venta_perdida), 0)                           AS venta_perdida,
                   COALESCE(SUM(venta_perdida) FILTER (WHERE tipo = 'total'), 0)   AS venta_perdida_total,
                   COALESCE(SUM(venta_perdida) FILTER (WHERE tipo = 'parcial'), 0) AS venta_perdida_parcial,
                   COALESCE(SUM(perdida_real), 0)                            AS perdida_real,
                   COALESCE(SUM(monto) FILTER (WHERE destino = 'mermado'), 0)        AS monto_mermado,
                   COALESCE(SUM(monto) FILTER (WHERE destino = 'sin_movimiento'), 0) AS monto_sin_movimiento,
                   COALESCE(SUM(mermas_sin_costo), 0)                        AS mermas_sin_costo
              FROM ev) e
  ),
  det AS (
    SELECT e.*, suc.nombre AS sucursal_nombre,
           COALESCE(c.nombre_fantasia, c.razon_social) AS cliente_nombre, c.activo AS cliente_activo,
           pv.nombre AS preventista_nombre, ch.nombre AS chofer_nombre,
           pr.nombre AS producto_nombre, pr.codigo AS producto_codigo
      FROM (SELECT * FROM ev
             ORDER BY fecha DESC, pedido_id DESC, salvedad_id NULLS FIRST
             LIMIT v_limite) e
      LEFT JOIN sucursales suc ON suc.id = e.sucursal_id
      LEFT JOIN clientes c     ON c.id = e.cliente_id
      LEFT JOIN perfiles pv    ON pv.id = e.usuario_id
      LEFT JOIN perfiles ch    ON ch.id = e.transportista_id
      LEFT JOIN productos pr   ON pr.id = e.producto_id
  )
  SELECT jsonb_build_object(
    'meta', jsonb_build_object(
      'sucursal_id', p_sucursal_id,
      'sucursal_nombre', COALESCE(v_nombre, 'Sucursal ' || p_sucursal_id),
      'desde', p_desde,
      'hasta', p_hasta,
      'generado_at', now(),
      'motivos_administrativos', to_jsonb(v_motivos_admin),
      'criterio', 'Rechazo total: pedido cancelado con un motivo que no es administrativo (sin motivo cuenta). Rechazo parcial: salvedad vigente (no anulada; la resuelta sigue contando). Sin canal cambio ni vale blanco (VB). La salvedad cuenta solo si su pedido salio. Corte por fecha del pedido. Venta perdida: lo que volvio al stock, a precio de venta. Perdida real: lo mermado, a costo (mermas_valorizadas). Tasa: (rechazos totales + entregados con salvedad) / (entregados + rechazos totales). Muestra causas, no responsables.'
    ),
    'totales', (SELECT to_jsonb(t) || jsonb_build_object(
        'tasa_rechazo', round((t.rechazos_totales + t.pedidos_con_salvedad)::numeric / NULLIF(t.pedidos_salieron, 0), 4),
        'tasa_rechazo_total', round(t.rechazos_totales::numeric / NULLIF(t.pedidos_salieron, 0), 4),
        'tasa_con_salvedad', round(t.pedidos_con_salvedad::numeric / NULLIF(t.pedidos_salieron, 0), 4))
      FROM tot t),
    'por_motivo', COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.monto DESC, x.tipo, x.motivo) FROM por_motivo x), '[]'::jsonb),
    'por_preventista', COALESCE((SELECT jsonb_agg(to_jsonb(x) || jsonb_build_object(
        'tasa_rechazo', round((x.rechazos_totales + x.pedidos_con_salvedad)::numeric / NULLIF(x.pedidos_salieron, 0), 4))
        ORDER BY x.monto DESC, x.nombre) FROM por_preventista x), '[]'::jsonb),
    'por_chofer', COALESCE((SELECT jsonb_agg(to_jsonb(x) || jsonb_build_object(
        'tasa_rechazo', round((x.rechazos_totales + x.pedidos_con_salvedad)::numeric / NULLIF(x.pedidos_salieron, 0), 4))
        ORDER BY x.monto DESC, x.nombre) FROM por_chofer x), '[]'::jsonb),
    'por_cliente', COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.monto DESC, x.nombre) FROM por_cliente x), '[]'::jsonb),
    'por_producto', COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.monto DESC, x.nombre) FROM por_producto x), '[]'::jsonb),
    'detalle', COALESCE((SELECT jsonb_agg(to_jsonb(d) ORDER BY d.fecha DESC, d.pedido_id DESC, d.salvedad_id NULLS FIRST) FROM det d), '[]'::jsonb),
    'detalle_total', (SELECT COUNT(*) FROM ev),
    'detalle_limite', v_limite,
    'detalle_truncado', ((SELECT COUNT(*) FROM ev) > v_limite)
  ) INTO v_out;

  RETURN v_out;
END;
$function$;

COMMENT ON FUNCTION public.reporte_rechazos(date, date, bigint) IS
  'Rechazos totales (cancelados no administrativos) y parciales (salvedades vigentes) del periodo por fecha del pedido, sin canal cambio ni vale blanco. Cortes por motivo, preventista, chofer, cliente (inactivos incluidos) y producto; venta perdida (volvio al stock, a precio) y perdida real (mermado, a costo via mermas_valorizadas); tasa de rechazo. Muestra causas, no responsables. Solo admin/encargado. #1198.';

ALTER FUNCTION public.reporte_rechazos(date, date, bigint) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.reporte_rechazos(date, date, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reporte_rechazos(date, date, bigint) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2) cerrar_salvedades_en_lote
-- ---------------------------------------------------------------------------

CREATE FUNCTION public.cerrar_salvedades_en_lote(
  p_hasta date,
  p_notas text DEFAULT NULL::text,
  p_solo_contar boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_usuario  UUID   := auth.uid();
  v_nota     TEXT;
  v_n        INTEGER;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;
  -- Solo admin: el encargado resuelve de a una (resolver_salvedad), pero cerrar
  -- el atraso entero de una sucursal es una decision del duenio.
  IF NOT es_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin puede cerrar salvedades en lote');
  END IF;
  IF p_hasta IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Falta la fecha hasta la que se cierra');
  END IF;

  IF p_solo_contar THEN
    SELECT COUNT(*) INTO v_n
      FROM salvedades_items
     WHERE sucursal_id = v_sucursal
       AND estado_resolucion = 'pendiente'
       AND (created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date <= p_hasta;
    RETURN jsonb_build_object('success', true, 'solo_contar', true, 'cerradas', v_n, 'hasta', p_hasta);
  END IF;

  v_nota := 'Cierre en lote del atraso: salvedades pendientes cargadas hasta el '
            || to_char(p_hasta, 'DD/MM/YYYY') || '.'
            || COALESCE(' ' || NULLIF(btrim(left(p_notas, 500)), ''), '');

  -- Mismas columnas que escribe resolver_salvedad. No nombra lotes_devueltos ni
  -- toca productos: cerrar no mueve stock ni plata.
  WITH cerradas AS (
    UPDATE salvedades_items SET
      estado_resolucion = 'resuelto_otro',
      resolucion_notas  = v_nota,
      resolucion_fecha  = NOW(),
      resuelto_por      = v_usuario,
      updated_at        = NOW()
    WHERE sucursal_id = v_sucursal
      AND estado_resolucion = 'pendiente'
      AND (created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date <= p_hasta
    RETURNING id
  )
  INSERT INTO salvedad_historial (salvedad_id, accion, estado_anterior, estado_nuevo, notas, usuario_id, sucursal_id)
  SELECT id, 'resolucion', 'pendiente', 'resuelto_otro', v_nota, v_usuario, v_sucursal
    FROM cerradas;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  RETURN jsonb_build_object('success', true, 'solo_contar', false, 'cerradas', v_n, 'hasta', p_hasta, 'nota', v_nota);
END;
$function$;

COMMENT ON FUNCTION public.cerrar_salvedades_en_lote(date, text, boolean) IS
  'Cierra como resuelto_otro las salvedades pendientes de la sucursal activa cargadas hasta p_hasta (dia argentino), con nota de cierre en lote e historial. Solo admin. No mueve stock ni plata ni pasa por anular_salvedad. p_solo_contar = true solo cuenta. #1198.';

ALTER FUNCTION public.cerrar_salvedades_en_lote(date, text, boolean) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.cerrar_salvedades_en_lote(date, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cerrar_salvedades_en_lote(date, text, boolean) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- Verificacion
-- ---------------------------------------------------------------------------

DO $verif$
DECLARE
  v_oid  oid;
  v_nom  text;
BEGIN
  FOREACH v_nom IN ARRAY ARRAY['reporte_rechazos', 'cerrar_salvedades_en_lote'] LOOP
    IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = v_nom) <> 1 THEN
      RAISE EXCEPTION '%: tiene que quedar una sola sobrecarga (PGRST203)', v_nom;
    END IF;
    SELECT oid INTO v_oid FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = v_nom;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid)
       OR (SELECT proowner::regrole::text FROM pg_proc WHERE oid = v_oid) <> 'postgres' THEN
      RAISE EXCEPTION '%: tiene que ser SECURITY DEFINER de postgres', v_nom;
    END IF;
    IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
      RAISE EXCEPTION '%: anon tiene EXECUTE', v_nom;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) x WHERE p.oid = v_oid AND x.grantee = 0) THEN
      RAISE EXCEPTION '%: PUBLIC tiene EXECUTE', v_nom;
    END IF;
    IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE')
       OR NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
      RAISE EXCEPTION '%: authenticated o service_role no tiene EXECUTE', v_nom;
    END IF;
    IF obj_description(v_oid, 'pg_proc') IS NULL THEN
      RAISE EXCEPTION '%: falta el COMMENT', v_nom;
    END IF;
  END LOOP;
END
$verif$;

-- ---------------------------------------------------------------------------
-- Ensayo: un caso armado, medido como diferencia contra el reporte de hoy
-- ---------------------------------------------------------------------------
--
-- En la sucursal de un admin, con un producto nuevo (precio 100, costo 60):
--   A: 3 u., cancelado 'cliente_rechaza'      -> rechazo total, venta perdida 300
--   B: 2 u., cancelado 'error_de_carga'       -> administrativo: no entra
--   C: 5 u., entregado, salvedad 'cliente_rechaza' de 2 (devuelve: 200 de venta
--      perdida) y 'producto_danado' de 1 (merma: 60 de perdida real, 100 de monto)
--   D: 4 u., entregado sin salvedad
--   E: 6 u., entregado con una salvedad y despues cancelado 'error_de_carga': ni
--      el pedido ni su salvedad entran
--   G: 7 u., vale blanco entregado: no entra en pedidos_salieron
-- El reporte de hoy, antes y despues, tiene que moverse exactamente eso. Despues
-- se cierra el atraso en lote: las dos salvedades quedan 'resuelto_otro' con la
-- nota, con historial, sin mover el stock, y el reporte NO cambia.
-- Todo corre en un subbloque que termina en una excepcion atrapada: no deja nada.

CREATE OR REPLACE FUNCTION pg_temp.ens1198_suma(p_rep jsonb, p_arr text, p_filtro jsonb, p_campo text)
RETURNS numeric LANGUAGE sql AS $fn$
  SELECT COALESCE(SUM((x->>p_campo)::numeric), 0)
    FROM jsonb_array_elements(COALESCE(p_rep->p_arr, '[]'::jsonb)) x
   WHERE x @> p_filtro;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ens1198_pedido(p_cli bigint, p_admin uuid, p_prod bigint, p_cant int)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
  v_ped bigint;
BEGIN
  v_res := public.crear_pedido_completo(p_cli, p_cant * 100, p_admin,
    jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 100)),
    'ensayo 1198');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  v_ped := (v_res->>'pedido_id')::bigint;
  RETURN jsonb_build_object('pedido', v_ped,
    'item', (SELECT id FROM public.pedido_items WHERE pedido_id = v_ped AND producto_id = p_prod LIMIT 1),
    'fecha', (SELECT fecha FROM public.pedidos WHERE id = v_ped));
END
$fn$;

DO $ensayo1198$
DECLARE
  v_admin   uuid;
  v_suc     bigint;
  v_cliente bigint;
  v_prod    bigint;
  a jsonb; b jsonb; c jsonb; d jsonb; e jsonb; g jsonb;
  v_fecha   date;
  v0 jsonb; v1 jsonb; v2 jsonb;
  v_res     jsonb;
  v_s1      bigint;
  v_s2      bigint;
  v_stock0  bigint;
  v_stock1  bigint;
  v_cuenta  integer;
  f         text[] := '{}';
  v_fallas  text[] := '{}';
  -- (campo de totales, delta esperado)
  r         record;
BEGIN
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'ens1198 · el ensayo necesita un admin activo con una sucursal activa';
  END IF;
  SELECT id INTO v_cliente FROM clientes WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;
  IF v_cliente IS NULL THEN
    RAISE EXCEPTION 'ens1198 · el ensayo necesita un cliente activo en la sucursal %', v_suc;
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  BEGIN
    INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
    VALUES ('ZZ ensayo 1198', 100, 100, 60, v_suc) RETURNING id INTO v_prod;

    a := pg_temp.ens1198_pedido(v_cliente, v_admin, v_prod, 3);
    b := pg_temp.ens1198_pedido(v_cliente, v_admin, v_prod, 2);
    c := pg_temp.ens1198_pedido(v_cliente, v_admin, v_prod, 5);
    d := pg_temp.ens1198_pedido(v_cliente, v_admin, v_prod, 4);
    e := pg_temp.ens1198_pedido(v_cliente, v_admin, v_prod, 6);
    g := pg_temp.ens1198_pedido(v_cliente, v_admin, v_prod, 7);
    v_fecha := (a->>'fecha')::date;

    -- La foto de antes se toma con los cuatro pedidos ya creados (pendientes:
    -- todavia no salieron), asi la diferencia es solo el desenlace.
    v0 := public.reporte_rechazos(v_fecha, v_fecha, v_suc);

    v_res := public.cancelar_pedido_con_stock((a->>'pedido')::bigint, 'ensayo 1198: no lo quiso', v_admin, 'cliente_rechaza');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN RAISE EXCEPTION 'cancelar A: %', v_res; END IF;
    v_res := public.cancelar_pedido_con_stock((b->>'pedido')::bigint, 'ensayo 1198: mal cargado', v_admin, 'error_de_carga');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN RAISE EXCEPTION 'cancelar B: %', v_res; END IF;
    IF public.marcar_entregas_masivo(ARRAY[(c->>'pedido')::bigint, (d->>'pedido')::bigint], v_admin, v_fecha) IS DISTINCT FROM 2 THEN
      RAISE EXCEPTION 'no se marcaron entregados C y D';
    END IF;
    v_res := public.registrar_salvedad((c->>'pedido')::bigint, (c->>'item')::bigint, 2, 'cliente_rechaza',
                                       'ensayo 1198', NULL, true, NULL);
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN RAISE EXCEPTION 'salvedad 1: %', v_res; END IF;
    v_s1 := (v_res->>'salvedad_id')::bigint;
    v_res := public.registrar_salvedad((c->>'pedido')::bigint, (c->>'item')::bigint, 1, 'producto_danado',
                                       'ensayo 1198', NULL, true, NULL);
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN RAISE EXCEPTION 'salvedad 2: %', v_res; END IF;
    v_s2 := (v_res->>'salvedad_id')::bigint;

    -- E: entregado, con una salvedad, y despues cancelado 'error_de_carga': ni el
    -- pedido ni su salvedad son un rechazo. G: vale blanco entregado: no sale.
    IF public.marcar_entregas_masivo(ARRAY[(e->>'pedido')::bigint], v_admin, v_fecha) IS DISTINCT FROM 1 THEN
      RAISE EXCEPTION 'no se marco entregado E';
    END IF;
    v_res := public.registrar_salvedad((e->>'pedido')::bigint, (e->>'item')::bigint, 1, 'cliente_rechaza',
                                       'ensayo 1198 E', NULL, true, NULL);
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN RAISE EXCEPTION 'salvedad E: %', v_res; END IF;
    UPDATE public.pedidos SET estado = 'cancelado', motivo_cancelacion_tipo = 'error_de_carga',
           motivo_cancelacion = 'ensayo 1198: mal cargado' WHERE id = (e->>'pedido')::bigint;
    -- El cliente tiene que estar habilitado para el vale blanco (lo deshace el ensayo).
    UPDATE public.clientes SET tipo_factura_default = 'VB' WHERE id = v_cliente;
    v_res := public.cambiar_tipo_factura_pedido((g->>'pedido')::bigint, 'VB', v_admin);
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN RAISE EXCEPTION 'VB en G: %', v_res; END IF;
    -- El masivo no entrega un vale blanco: se pasa a mano.
    UPDATE public.pedidos SET estado = 'entregado' WHERE id = (g->>'pedido')::bigint;

    v1 := public.reporte_rechazos(v_fecha, v_fecha, v_suc);

    FOR r IN SELECT * FROM (VALUES
        ('pedidos_salieron', 3), ('pedidos_entregados', 2), ('rechazos_totales', 1),
        ('pedidos_con_salvedad', 1), ('lineas_salvedad', 2), ('salvedades_pendientes', 2),
        ('monto', 600), ('venta_perdida', 500), ('venta_perdida_total', 300),
        ('venta_perdida_parcial', 200), ('perdida_real', 60), ('monto_mermado', 100),
        ('monto_sin_movimiento', 0), ('mermas_sin_costo', 0)) t(campo, esperado)
    LOOP
      IF (v1->'totales'->>r.campo)::numeric - (v0->'totales'->>r.campo)::numeric IS DISTINCT FROM r.esperado::numeric THEN
        f := f || format('totales.%s se movio %s, se esperaba %s', r.campo,
                         (v1->'totales'->>r.campo)::numeric - (v0->'totales'->>r.campo)::numeric, r.esperado);
      END IF;
    END LOOP;

    -- Cortes: el motivo administrativo no aparece; los otros con su plata.
    IF pg_temp.ens1198_suma(v1, 'por_motivo', '{"tipo":"total","motivo":"error_de_carga"}', 'casos') IS DISTINCT FROM 0 THEN
      f := f || 'por_motivo: un cancelado error_de_carga entro como rechazo'::text;
    END IF;
    IF pg_temp.ens1198_suma(v1, 'por_motivo', '{"tipo":"total","motivo":"cliente_rechaza"}', 'venta_perdida')
       - pg_temp.ens1198_suma(v0, 'por_motivo', '{"tipo":"total","motivo":"cliente_rechaza"}', 'venta_perdida') IS DISTINCT FROM 300 THEN
      f := f || 'por_motivo total/cliente_rechaza no sumo 300 de venta perdida'::text;
    END IF;
    IF pg_temp.ens1198_suma(v1, 'por_motivo', '{"tipo":"parcial","motivo":"producto_danado"}', 'perdida_real')
       - pg_temp.ens1198_suma(v0, 'por_motivo', '{"tipo":"parcial","motivo":"producto_danado"}', 'perdida_real') IS DISTINCT FROM 60 THEN
      f := f || 'por_motivo parcial/producto_danado no sumo 60 de perdida real'::text;
    END IF;
    IF pg_temp.ens1198_suma(v1, 'por_motivo', '{"tipo":"parcial","motivo":"producto_danado"}', 'venta_perdida')
       - pg_temp.ens1198_suma(v0, 'por_motivo', '{"tipo":"parcial","motivo":"producto_danado"}', 'venta_perdida') IS DISTINCT FROM 0 THEN
      f := f || 'la merma conto como venta perdida'::text;
    END IF;
    -- Preventista (el admin cargo los cuatro) y chofer (el admin repartio C y D;
    -- A no tenia chofer).
    IF pg_temp.ens1198_suma(v1, 'por_preventista', jsonb_build_object('usuario_id', v_admin), 'pedidos_salieron')
       - pg_temp.ens1198_suma(v0, 'por_preventista', jsonb_build_object('usuario_id', v_admin), 'pedidos_salieron') IS DISTINCT FROM 3
       OR pg_temp.ens1198_suma(v1, 'por_preventista', jsonb_build_object('usuario_id', v_admin), 'rechazos_totales')
       - pg_temp.ens1198_suma(v0, 'por_preventista', jsonb_build_object('usuario_id', v_admin), 'rechazos_totales') IS DISTINCT FROM 1 THEN
      f := f || 'por_preventista no conto 3 salidos y 1 rechazo total'::text;
    END IF;
    IF pg_temp.ens1198_suma(v1, 'por_chofer', jsonb_build_object('transportista_id', v_admin), 'pedidos_con_salvedad')
       - pg_temp.ens1198_suma(v0, 'por_chofer', jsonb_build_object('transportista_id', v_admin), 'pedidos_con_salvedad') IS DISTINCT FROM 1
       OR pg_temp.ens1198_suma(v1, 'por_chofer', '{"transportista_id":null}', 'rechazos_totales')
       - pg_temp.ens1198_suma(v0, 'por_chofer', '{"transportista_id":null}', 'rechazos_totales') IS DISTINCT FROM 1 THEN
      f := f || 'por_chofer no partio C (con chofer) y A (sin chofer)'::text;
    END IF;
    IF pg_temp.ens1198_suma(v1, 'por_producto', jsonb_build_object('producto_id', v_prod), 'monto') IS DISTINCT FROM 600
       OR pg_temp.ens1198_suma(v1, 'por_producto', jsonb_build_object('producto_id', v_prod), 'unidades_total') IS DISTINCT FROM 3
       OR pg_temp.ens1198_suma(v1, 'por_producto', jsonb_build_object('producto_id', v_prod), 'unidades_parcial') IS DISTINCT FROM 3 THEN
      f := f || format('por_producto del producto del ensayo: %s',
                       (SELECT x FROM jsonb_array_elements(v1->'por_producto') x WHERE x->>'producto_id' = v_prod::text));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v1->'detalle') x WHERE (x->>'salvedad_id')::bigint = v_s2
                      AND x->>'destino' = 'mermado' AND (x->>'perdida_real')::numeric = 60)
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v1->'detalle') x
                      WHERE (x->>'pedido_id')::bigint = (a->>'pedido')::bigint AND x->>'tipo' = 'total')
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v1->'detalle') x
                   WHERE (x->>'pedido_id')::bigint = (b->>'pedido')::bigint) THEN
      f := f || 'el detalle no trae A y la merma de C, o trae a B'::text;
    END IF;

    -- Cierre en lote: contar, cerrar, y que no se mueva ni el stock ni el reporte.
    v_res := public.cerrar_salvedades_en_lote(v_fecha, NULL, true);
    v_cuenta := (v_res->>'cerradas')::int;
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_cuenta < 2 THEN
      f := f || format('contar el lote: %s', v_res);
    END IF;
    SELECT COALESCE(SUM(stock), 0) INTO v_stock0 FROM public.productos WHERE sucursal_id = v_suc;
    v_res := public.cerrar_salvedades_en_lote(v_fecha, 'nota del ensayo', false);
    SELECT COALESCE(SUM(stock), 0) INTO v_stock1 FROM public.productos WHERE sucursal_id = v_suc;
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR (v_res->>'cerradas')::int IS DISTINCT FROM v_cuenta THEN
      f := f || format('cerrar el lote cerro distinto de lo que conto (%s): %s', v_cuenta, v_res);
    END IF;
    IF v_stock1 IS DISTINCT FROM v_stock0 THEN
      f := f || format('el cierre en lote movio el stock de la sucursal: %s -> %s', v_stock0, v_stock1);
    END IF;
    IF (SELECT count(*) FROM public.salvedades_items
         WHERE id IN (v_s1, v_s2) AND estado_resolucion = 'resuelto_otro'
           AND resuelto_por = v_admin AND resolucion_fecha IS NOT NULL
           AND resolucion_notas LIKE 'Cierre en lote del atraso: salvedades pendientes cargadas hasta el '
                                     || to_char(v_fecha, 'DD/MM/YYYY') || '. nota del ensayo') IS DISTINCT FROM 2 THEN
      f := f || 'las salvedades del ensayo no quedaron resuelto_otro con la nota del lote'::text;
    END IF;
    IF (SELECT count(*) FROM public.salvedad_historial
         WHERE salvedad_id IN (v_s1, v_s2) AND accion = 'resolucion'
           AND estado_anterior = 'pendiente' AND estado_nuevo = 'resuelto_otro') IS DISTINCT FROM 2 THEN
      f := f || 'el cierre en lote no dejo una fila de historial por salvedad'::text;
    END IF;
    IF EXISTS (SELECT 1 FROM public.salvedades_items
                WHERE sucursal_id = v_suc AND estado_resolucion = 'pendiente'
                  AND (created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date <= v_fecha) THEN
      f := f || 'quedaron pendientes anteriores al corte'::text;
    END IF;
    v2 := public.reporte_rechazos(v_fecha, v_fecha, v_suc);
    IF (v2->'totales') - 'salvedades_pendientes' IS DISTINCT FROM (v1->'totales') - 'salvedades_pendientes'
       OR (v2->'totales'->>'salvedades_pendientes')::int IS DISTINCT FROM 0 THEN
      f := f || format('el cierre en lote movio el reporte: %s -> %s', v1->'totales', v2->'totales');
    END IF;
    -- Una segunda pasada no encuentra nada (idempotente).
    v_res := public.cerrar_salvedades_en_lote(v_fecha, NULL, false);
    IF (v_res->>'cerradas')::int IS DISTINCT FROM 0 THEN
      f := f || format('la segunda pasada cerro %s', v_res->>'cerradas');
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION
    WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('error: %s', SQLERRM);
  END;
  v_fallas := v_fallas || f;

  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.headers', '', true);
  PERFORM set_config('app.omitir_minimo_pedido', '', true);

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ens1198 · el ensayo fallo (% fallas), la migracion no se aplica:\n- %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
END
$ensayo1198$;

-- Las auxiliares del ensayo no se quedan en la sesion.
DROP FUNCTION pg_temp.ens1198_suma(jsonb, text, jsonb, text);
DROP FUNCTION pg_temp.ens1198_pedido(bigint, uuid, bigint, int);
