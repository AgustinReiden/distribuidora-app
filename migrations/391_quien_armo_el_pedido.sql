-- 391 · Quien armo el pedido (#1199).
--
-- Hasta hoy `pedidos` no guardaba quien lo preparo en deposito: un rechazo por
-- error de armado (faltante, producto equivocado, danado al armar) se atribuia
-- al sector y no a una persona. Decisiones del duenio (2026-10-26):
--   1) Se registra cuando el pedido se marca como armado: el paso "Marcar en
--      preparacion" (pendiente -> en_preparacion), que hacen admin y encargado.
--   2) Se guarda UNA persona: la que lo marco.
--   3) El reporte de rechazos suma un corte "por armador" con las dos formas:
--      cantidad de pedidos con error de armado y tasa sobre lo que armo.
--
-- 1) pedidos.armado_por / armado_at. Los pone un TRIGGER BEFORE UPDATE OF estado,
--    no el front: el front escribe `pedidos` por REST con un GRANT UPDATE por
--    columna, y una columna que se concede por REST es una columna que cualquiera
--    con sesion puede falsear. Las columnas nuevas NO se conceden para escribir
--    (el trigger no lo necesita) y se leen con el SELECT de tabla que ya existe.
--      - pendiente -> en_preparacion: anota auth.uid() y la hora.
--      - cualquier -> pendiente ("Volver a pendiente"): los borra, el pedido
--        vuelve a no estar armado.
--      - asignado -> en_preparacion (aplicar_orden_ruta deshace una ruta, mig
--        088) NO es un armado: no cambia nada. Un pedido que va de pendiente a
--        una ruta sin pasar por "en preparacion" queda sin armador.
--    Sin backfill: pedido_historial tiene el usuario solo en 54 de las 498
--    marcas viejas, asi que atribuir hacia atras seria inventar. Los pedidos
--    anteriores quedan con armado_por NULL y el reporte los muestra como
--    "sin dato".
--    Una funcion de trigger no necesita EXECUTE para nadie (CLAUDE.md): la
--    invoca el executor como parte del DML. Queda en postgres + service_role.
--
-- 2) reporte_rechazos suma `por_armador` (+ meta.motivos_error_armado). Es el
--    cuerpo de la 383 tal cual, con un CTE y una clave de salida nuevos. Un error
--    de armado es una salvedad o un rechazo entero con motivo faltante_stock,
--    error_pedido o producto_danado. La definicion es del reporte, no de la base:
--    cambiarla es cambiar `v_motivos_armado` y MOTIVOS_ERROR_DE_ARMADO a la vez.

ALTER TABLE public.pedidos
  ADD COLUMN IF NOT EXISTS armado_por uuid REFERENCES public.perfiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS armado_at  timestamptz;

COMMENT ON COLUMN public.pedidos.armado_por IS
  'Quien marco el pedido como "en preparacion" en deposito (pendiente -> en_preparacion). Lo escribe trg_pedidos_registrar_armado; NULL = nadie lo marco o es anterior a la 391. #1199.';
COMMENT ON COLUMN public.pedidos.armado_at IS
  'Cuando se marco el pedido como "en preparacion". Lo escribe trg_pedidos_registrar_armado. #1199.';

CREATE FUNCTION public.pedidos_registrar_armado()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.estado = 'en_preparacion' AND OLD.estado = 'pendiente' THEN
    NEW.armado_por := auth.uid();
    NEW.armado_at  := now();
  ELSIF NEW.estado = 'pendiente' THEN
    NEW.armado_por := NULL;
    NEW.armado_at  := NULL;
  END IF;
  RETURN NEW;
END;
$function$;

ALTER FUNCTION public.pedidos_registrar_armado() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.pedidos_registrar_armado() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pedidos_registrar_armado() TO service_role;

DROP TRIGGER IF EXISTS trg_pedidos_registrar_armado ON public.pedidos;
CREATE TRIGGER trg_pedidos_registrar_armado
  BEFORE UPDATE OF estado ON public.pedidos
  FOR EACH ROW
  WHEN (OLD.estado IS DISTINCT FROM NEW.estado)
  EXECUTE FUNCTION public.pedidos_registrar_armado();

-- ---------------------------------------------------------------------------
-- reporte_rechazos con el corte por armador
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.reporte_rechazos(
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
  -- Los motivos que son un error de ARMADO (decision del duenio, #1199): lo que
  -- falto, lo que se cargo mal y lo que se rompio al armar. Espejo de
  -- MOTIVOS_ERROR_DE_ARMADO (src/utils/rechazos.ts); lo vigila rechazos.test.ts.
  v_motivos_armado text[] := ARRAY['faltante_stock','error_pedido','producto_danado'];
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
    SELECT p.id, p.fecha, p.sucursal_id, p.cliente_id, p.usuario_id, p.transportista_id, p.armado_por,
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
  -- Quien armo el pedido (#1199): el denominador son los pedidos que salieron
  -- armados por cada uno y el numerador los que tuvieron algun error de armado
  -- (un pedido con dos lineas con error cuenta una vez). Los pedidos sin armador
  -- (anteriores a la 391, o que fueron de pendiente a una ruta sin pasar por
  -- "en preparacion") caen en la fila NULL.
  por_armador AS (
    SELECT a.armado_por, per.nombre,
           a.pedidos_salieron,
           COALESCE(e.pedidos_con_error_armado, 0) AS pedidos_con_error_armado,
           COALESCE(e.errores_armado, 0)           AS errores_armado,
           COALESCE(e.monto, 0)                    AS monto,
           COALESCE(e.venta_perdida, 0)            AS venta_perdida,
           COALESCE(e.perdida_real, 0)             AS perdida_real
      FROM (SELECT armado_por, COUNT(*) AS pedidos_salieron FROM base GROUP BY armado_por) a
      LEFT JOIN (SELECT p.armado_por,
                        COUNT(DISTINCT x.pedido_id) AS pedidos_con_error_armado,
                        COUNT(*)                    AS errores_armado,
                        SUM(x.monto) AS monto, SUM(x.venta_perdida) AS venta_perdida,
                        SUM(x.perdida_real) AS perdida_real
                   FROM ev x JOIN ped p ON p.id = x.pedido_id
                  WHERE x.motivo = ANY(v_motivos_armado)
                  GROUP BY p.armado_por) e ON e.armado_por IS NOT DISTINCT FROM a.armado_por
      LEFT JOIN perfiles per ON per.id = a.armado_por
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
      'motivos_error_armado', to_jsonb(v_motivos_armado),
      'criterio', 'Rechazo total: pedido cancelado con un motivo que no es administrativo (sin motivo cuenta). Rechazo parcial: salvedad vigente (no anulada; la resuelta sigue contando). Sin canal cambio ni vale blanco (VB). La salvedad cuenta solo si su pedido salio. Corte por fecha del pedido. Venta perdida: lo que volvio al stock, a precio de venta. Perdida real: lo mermado, a costo (mermas_valorizadas). Tasa: (rechazos totales + entregados con salvedad) / (entregados + rechazos totales). Cortes por preventista y chofer muestran causas; el corte por armador (quien marco el pedido en preparacion) cuenta los pedidos con algun error de armado (faltante, error en pedido o producto danado) sobre los que armo.'
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
    'por_armador', COALESCE((SELECT jsonb_agg(to_jsonb(x) || jsonb_build_object(
        'tasa_error_armado', round(x.pedidos_con_error_armado::numeric / NULLIF(x.pedidos_salieron, 0), 4))
        ORDER BY x.pedidos_con_error_armado DESC, x.pedidos_salieron DESC, x.nombre) FROM por_armador x), '[]'::jsonb),
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
  'Rechazos totales (cancelados no administrativos) y parciales (salvedades vigentes) del periodo por fecha del pedido, sin canal cambio ni vale blanco. Cortes por motivo, preventista, chofer, armador (quien marco el pedido en preparacion; #1199), cliente (inactivos incluidos) y producto; venta perdida (volvio al stock, a precio) y perdida real (mermado, a costo via mermas_valorizadas); tasa de rechazo. Solo admin/encargado. #1198.';

ALTER FUNCTION public.reporte_rechazos(date, date, bigint) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.reporte_rechazos(date, date, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reporte_rechazos(date, date, bigint) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Ensayo (se deshace solo): el trigger anota, no toca la ruta y limpia.
-- ---------------------------------------------------------------------------
DO $ensayo$
DECLARE
  v_ped bigint;
  v_adm uuid;
  v_ap  uuid;
  v_f   text := '';
BEGIN
  SELECT id INTO v_ped FROM pedidos WHERE estado = 'pendiente' ORDER BY id LIMIT 1;
  SELECT id INTO v_adm FROM perfiles WHERE rol = 'admin' ORDER BY id LIMIT 1;
  IF v_ped IS NULL OR v_adm IS NULL THEN
    RAISE NOTICE 'ensayo 391 omitido: no hay un pedido pendiente o un admin';
    RETURN;
  END IF;
  BEGIN
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);

    UPDATE pedidos SET estado = 'en_preparacion' WHERE id = v_ped;
    SELECT armado_por INTO v_ap FROM pedidos WHERE id = v_ped;
    IF v_ap IS DISTINCT FROM v_adm THEN
      v_f := v_f || ' marcar en preparacion no anoto a quien lo marco;';
    END IF;

    UPDATE pedidos SET estado = 'pendiente' WHERE id = v_ped;
    SELECT armado_por INTO v_ap FROM pedidos WHERE id = v_ped;
    IF v_ap IS NOT NULL THEN
      v_f := v_f || ' volver a pendiente no limpio al armador;';
    END IF;

    RAISE EXCEPTION 'ens391:%', v_f;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'ens391:' THEN
      RAISE EXCEPTION 'ensayo 391 fallo: %', SQLERRM;
    END IF;
  END;
END
$ensayo$;
