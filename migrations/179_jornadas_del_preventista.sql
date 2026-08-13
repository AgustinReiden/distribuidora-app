-- =========================================================================
-- 179_jornadas_del_preventista.sql
--
-- El preventista carga el pedido y después no se entera de nada. Si el
-- cliente rechazó la mercadería, si el negocio estaba cerrado, si el chofer
-- entregó de menos con una salvedad — todo eso pasa después de que él cerró
-- la venta y hoy no tiene ninguna pantalla donde verlo. Se entera cuando el
-- cliente le reclama en la próxima visita, o no se entera nunca.
--
-- Dos funciones de lectura para el panel "Mis entregas": el resumen por día
-- y el detalle de un día.
--
-- Por qué RPC y no PostgREST desde el cliente:
--
-- 1) El día del reparto hay que DERIVARLO. `fecha_entrega_programada` no
--    sirve: coincide con la entrega real sólo el 52% de las veces. Para un
--    cancelado ni siquiera hay `fecha_entrega` (NULL en 266 de 271), así que
--    el día del rechazo sólo vive en `pedido_historial`. Cruzar eso desde el
--    cliente implica bajarse el historial entero.
--
-- 2) `pedido_items` y `pedido_historial` tienen RLS pensada para otra cosa
--    (`pedido_historial` es `sucursal_id = current_sucursal_id()` a secas).
--    Un SECURITY DEFINER con guard explícito es más chico y más auditable
--    que abrir policies nuevas.
--
-- 3) El embed que haría falta (pedidos → clientes → salvedades_items →
--    productos) es la forma exacta que dio PGRST201 y rompió "Armar ruta"
--    en prod. Un RPC no tiene embeds.
--
-- Dos decisiones de negocio que quedan escritas acá:
--
-- a) NO todo cancelado es un rechazo. De 271 cancelados, 67 son corrección
--    de oficina (error_de_carga 29, prueba 26, unifica_pedidos 8,
--    cambio_de_cliente 4). Mostrarle al preventista sus propios errores de
--    carga junto a los rechazos del cliente arruina el número que importa.
--
--    La lista de administrativos es NEGRA, no blanca, y eso es a propósito:
--    un motivo nuevo cae en 'rechazado' y se ve. Al revés se escondería solo,
--    que es exactamente la falla que este panel viene a arreglar. Por eso
--    'otro' (38) y los cancelados sin motivo también cuentan como rechazo:
--    uno de ellos dice "inconveniente entre fletero y clienta (observar)",
--    o sea calle pura. Y 'cliente_cancelo' (19) es de las cosas que el
--    preventista más necesita saber, no una corrección de oficina.
--    Reparto resultante: 204 rechazados / 67 administrativos.
--
-- b) El monto de un cancelado NO es `pedidos.total`: `cancelar_pedido_con_stock`
--    lo pone en cero (267 de 271 están en 0). El importe original se recupera
--    de `total_real` o, para los viejos que no lo tienen, de la suma de los
--    items — que sobrevive a la cancelación. Sin esto cada rechazo se muestra
--    en $0 y el panel no dice nada.
--
-- Nombres nuevos, UNA firma por función: la mig 176 documenta que dos
-- sobrecargas con aridades superpuestas dan PGRST203 en runtime, invisible
-- para tsc y para los tests.
--
-- Sólo lectura. No toca ninguna fila. Idempotente (CREATE OR REPLACE).
-- =========================================================================

-- -------------------------------------------------------------------------
-- 1. Resumen por día
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.jornadas_preventista(
  p_desde          date,
  p_hasta          date,
  p_preventista_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_target    uuid;
  v_nombre    text;
  v_sucursal  bigint;
  v_dias      jsonb;
  v_pend      jsonb;
  v_totales   jsonb;
BEGIN
  -- Mismo guard que `avance_metas_preventista` (mig 158): sin argumento se
  -- resuelve al usuario logueado; pedir el de otro requiere admin o encargado.
  v_target := COALESCE(p_preventista_id, auth.uid());

  IF v_target IS NULL THEN
    RAISE EXCEPTION 'Sin usuario' USING ERRCODE = '42501';
  END IF;

  IF auth.uid() IS NOT NULL AND v_target <> auth.uid() AND NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Acceso denegado' USING ERRCODE = '42501';
  END IF;

  IF p_desde IS NULL OR p_hasta IS NULL OR p_hasta < p_desde THEN
    RAISE EXCEPTION 'Rango de fechas inválido' USING ERRCODE = '22007';
  END IF;

  v_sucursal := current_sucursal_id();

  SELECT nombre INTO v_nombre FROM perfiles WHERE id = v_target;

  WITH resueltos AS (
    SELECT
      -- El día del reparto: cuándo se entregó o cuándo se cayó.
      --
      -- El `AT TIME ZONE` no es decorativo. La mig 136 tuvo que rehacer 1.380
      -- pedidos mal clasificados justamente por esto: el cast directo usa el
      -- TZ de la sesión (UTC en Supabase) y manda una entrega de las 22:00 AR
      -- al día siguiente.
      CASE
        WHEN p.estado = 'entregado' THEN
          -- 7 entregados no tienen fecha_entrega; el historial los rescata
          -- antes de caer a la fecha de toma, que sería el día equivocado.
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
          -- `LIKE 'cancelado%'` porque los bundles viejos escribían el motivo
          -- adentro del valor: 'cancelado - Motivo: CERRADO | Total original: $30600.00'.
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
        -- Lista NEGRA: el pedido no debía existir o fue reemplazado por otro.
        WHEN p.motivo_cancelacion_tipo IN
             ('error_de_carga','prueba','duplicado','unifica_pedidos','cambio_de_cliente')
          THEN 'administrativo'
        -- Todo el resto —incluido 'otro' y los que no tienen motivo— es el
        -- cliente que no recibió la mercadería.
        ELSE 'rechazado'
      END AS desenlace,

      -- `total` de un cancelado es 0 (lo pone cancelar_pedido_con_stock).
      CASE WHEN p.estado = 'cancelado'
        THEN COALESCE(NULLIF(p.total, 0), NULLIF(p.total_real, 0),
                      (SELECT COALESCE(SUM(pi.subtotal), 0) FROM pedido_items pi
                        WHERE pi.pedido_id = p.id))
        ELSE p.total
      END AS monto

    FROM pedidos p
    WHERE p.usuario_id  = v_target
      AND p.sucursal_id = v_sucursal
      AND p.canal <> 'cambio'          -- devoluciones: logística, no venta
      AND p.estado IN ('entregado','cancelado')
      -- El desenlace nunca es anterior a la carga, así que nada con
      -- fecha > p_hasta puede caer dentro del rango. El margen hacia atrás
      -- cubre la cola larga (el lag observado llega a 25 días).
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

  -- Los que no tienen desenlace todavía. Van aparte y SIN filtro de fecha: no
  -- pertenecen a ninguna jornada cerrada, y el punto es exactamente que hay
  -- pedidos colgados hace semanas que hoy no mira nadie.
  SELECT jsonb_build_object(
    'total',     COUNT(*),
    'monto',     COALESCE(SUM(p.total), 0),
    'mas_viejo', MIN(p.fecha)
  )
  INTO v_pend
  FROM pedidos p
  WHERE p.usuario_id  = v_target
    AND p.sucursal_id = v_sucursal
    AND p.canal <> 'cambio'
    AND p.estado NOT IN ('entregado','cancelado');

  RETURN jsonb_build_object(
    'preventista_id', v_target,
    'nombre',         v_nombre,
    'desde',          p_desde,
    'hasta',          p_hasta,
    'dias',           v_dias,
    'totales',        v_totales,
    'pendientes',     v_pend
  );
END;
$fn$;

COMMENT ON FUNCTION public.jornadas_preventista(date, date, uuid) IS
'Panel "Mis entregas": resumen por día de reparto de los pedidos que tomó un preventista (pedidos.usuario_id). Sin p_preventista_id devuelve los del usuario logueado; pedir el de otro requiere admin o encargado. Sólo lectura.';

GRANT EXECUTE ON FUNCTION public.jornadas_preventista(date, date, uuid) TO authenticated;


-- -------------------------------------------------------------------------
-- 2. Detalle de un día
--
-- Se llama al expandir una tarjeta, no al cargar la lista: son 8-14 pedidos
-- por día y traerlos todos de entrada multiplicaría por 30 el payload de una
-- pantalla que se usa desde el teléfono, en la calle.
--
-- p_dia NULL devuelve el bucket de pendientes, así el filtro "pendientes" del
-- front no necesita una tercera función.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.jornada_preventista_detalle(
  p_dia            date,
  p_preventista_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_target   uuid;
  v_sucursal bigint;
  v_out      jsonb;
BEGIN
  v_target := COALESCE(p_preventista_id, auth.uid());

  IF v_target IS NULL THEN
    RAISE EXCEPTION 'Sin usuario' USING ERRCODE = '42501';
  END IF;

  IF auth.uid() IS NOT NULL AND v_target <> auth.uid() AND NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Acceso denegado' USING ERRCODE = '42501';
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
    WHERE p.usuario_id  = v_target
      AND p.sucursal_id = v_sucursal
      AND p.canal <> 'cambio'
      AND (
        -- Un día concreto: sólo los que ya tienen desenlace.
        (p_dia IS NOT NULL
         AND p.estado IN ('entregado','cancelado')
         AND p.fecha BETWEEN (p_dia - 90) AND p_dia)
        -- Sin día: el bucket de colgados, sin filtro de fecha.
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
               ('error_de_carga','prueba','duplicado','unifica_pedidos','cambio_de_cliente')
        THEN 'administrativo'
      WHEN f.estado = 'cancelado' THEN 'rechazado'
      ELSE 'pendiente'
    END,
    'estado',        f.estado,
    'fecha_pedido',  f.fecha,
    'motivo_tipo',   f.motivo_cancelacion_tipo,
    'motivo_nota',   NULLIF(btrim(COALESCE(f.motivo_cancelacion, '')), ''),
    'transportista', tr.nombre,
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
  LEFT JOIN perfiles tr ON tr.id = f.transportista_id;

  RETURN v_out;
END;
$fn$;

COMMENT ON FUNCTION public.jornada_preventista_detalle(date, uuid) IS
'Panel "Mis entregas": detalle de un día de reparto (pedidos del preventista con su desenlace, motivo y salvedades). p_dia NULL devuelve los pedidos sin desenlace todavía. Sólo lectura.';

GRANT EXECUTE ON FUNCTION public.jornada_preventista_detalle(date, uuid) TO authenticated;


-- -------------------------------------------------------------------------
-- Chequeo anti-PGRST203 (mig 176): ninguna de las dos puede tener más de una
-- firma, o PostgREST no sabe cuál llamar y falla recién en runtime.
--
--   SELECT proname, count(*)
--     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname = 'public'
--      AND proname IN ('jornadas_preventista','jornada_preventista_detalle')
--    GROUP BY 1 HAVING count(*) > 1;
--
-- Tiene que devolver 0 filas.
-- -------------------------------------------------------------------------
