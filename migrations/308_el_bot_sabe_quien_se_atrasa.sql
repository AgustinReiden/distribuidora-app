-- =============================================================================
-- 308 · El bot sabe quien se atrasa
-- =============================================================================
--
-- Herramientas comerciales del bot (#978, PR 2a). Lo que admins y preventistas
-- le pidieron y el bot no tenia:
--
--   * clientes_ritmo_compra(): UNA definicion del ritmo de compra de cada
--     cliente. Antes habia dos (la alerta "clientes inactivos" del reporte
--     gerencial, 30-90 dias fijos, y la RFM del bot, con promedio y 21 dias por
--     defecto). Esta mide a cada cliente contra SU frecuencia (la mediana entre
--     entregas): un cliente semanal con 18 dias sin comprar esta peor que uno
--     mensual con 35. La consumen bot_clientes_atrasados y
--     bot_resumen_cliente_visita (y la van a consumir los digests del PR 2b).
--   * bot_clientes_atrasados: reemplaza a la RFM (bot_sugerir_visitas_rfm queda
--     sin herramienta que la llame). Informa ademas el numero de la alerta de la
--     app con su etiqueta, para que el admin no vea dos cifras sin explicacion.
--   * bot_ranking_clientes: consume reporte_ventas_por_cliente (la pantalla de
--     ventas por cliente) para el periodo y el anterior: mayores, menores y
--     quien viene cayendo.
--   * bot_productos_sin_venta_con_stock y bot_stock_y_ventas: lo que el admin
--     pregunto y el bot resolvia producto por producto (16 llamadas a
--     ficha_producto en una tarde).
--   * bot_productos_dejados_cliente: lo que el cliente llevaba seguido y dejo de
--     llevar (en general, porque se lo vende otro).
--   * bot_resumen_cliente_visita: la ficha para entrar al comercio, en una sola
--     llamada.
--
-- Reglas comunes (decisiones del dueño, 2026-10-07):
--   * Venta = mig 241: entregado, canal <> 'cambio', por `fecha`, dia argentino.
--   * "Mis clientes" de un preventista para listas proactivas: los asignados a
--     el mas los huerfanos donde vendio en los ultimos 180 dias. Nunca un
--     reservado_admin al que no le vendio. Solo activos (lista operativa).
--   * Hechos si, montos no: cuando compro, cada cuanto, que lleva, salen de
--     todos los pedidos del cliente; la plata, de los propios del preventista.
--   * Todas son server-only: REVOKE a PUBLIC, anon y authenticated (CLAUDE.md).
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1 · clientes_ritmo_compra: el ritmo de cada cliente, una sola vez
-- ---------------------------------------------------------------------------
-- p_rol / p_perfil_id: quien pregunta (lo resuelve el bot en el servidor).
-- p_preventista_id: para admin/encargado, filtrar la cartera de un preventista
-- (NULL = toda la sucursal). Para un preventista se ignora: es el mismo.
--
-- estado:
--   sin_compras  sin entregas en 365 dias
--   perdido      la ultima entrega fue hace mas de 180 dias
--   inactivo     entre 91 y 180 dias sin comprar
--   ocasional    menos de 3 entregas en el anio (no tiene ritmo propio) y 45 o
--                mas dias sin comprar
--   atrasado     con ritmo propio: >= 2 veces su frecuencia y >= 14 dias
--   por_vencer   con ritmo propio: >= 1,5 veces su frecuencia y >= 7 dias
-- Medido en prod (2026-10-07): con un solo "atrasado" que mezclaba todo,
-- Tucuman daba 235 de 614 (119 eran clientes de una o dos compras hace meses
-- y 80 llevaban mas de 60 dias). Separados, "atrasado" son ~70: una lista
-- para salir a visitar, no ruido.
--   al_dia       el resto
-- monto_mensual: lo entregado en 180 dias / 6. Para un preventista, solo lo
-- propio (usuario_id = el).
CREATE OR REPLACE FUNCTION public.clientes_ritmo_compra(
  p_sucursal_id    BIGINT,
  p_rol            TEXT,
  p_perfil_id      UUID,
  p_preventista_id UUID DEFAULT NULL,
  -- Para leer UN cliente (el resumen de visita) sin calcular la sucursal entera.
  p_cliente_id     BIGINT DEFAULT NULL
)
RETURNS TABLE (
  cliente_id        BIGINT,
  codigo            INTEGER,
  nombre            TEXT,
  zona              TEXT,
  es_comodin        BOOLEAN,
  saldo             NUMERIC,
  ultima_compra     DATE,
  dias_sin_comprar  INTEGER,
  entregas_365      INTEGER,
  frecuencia_dias   NUMERIC,
  ratio             NUMERIC,
  estado            TEXT,
  monto_mensual     NUMERIC
)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  WITH params AS (
    SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date AS hoy,
           CASE WHEN p_rol IN ('admin', 'encargado') THEN p_preventista_id
                ELSE p_perfil_id END AS prev,
           p_rol NOT IN ('admin', 'encargado') AS solo_propio
  ),
  universo AS (
    SELECT c.id, c.codigo,
           COALESCE(NULLIF(btrim(c.nombre_fantasia), ''), NULLIF(btrim(c.razon_social), ''), '(sin nombre)') AS nombre,
           -- La zona como la muestra la app (reporte_ventas_por_cliente): la de
           -- la tabla zonas, y el texto viejo sólo si no hay zona asignada.
           COALESCE(z.nombre, NULLIF(btrim(c.zona), ''), 'SIN ZONA') AS zona,
           c.es_comodin, c.saldo_cuenta
      FROM clientes c
      LEFT JOIN zonas z ON z.id = c.zona_id
      CROSS JOIN params pr
     WHERE c.sucursal_id = p_sucursal_id
       AND c.activo
       AND (p_cliente_id IS NULL OR c.id = p_cliente_id)
       AND (
             -- Toda la sucursal: solo admin/encargado sin filtro de preventista.
             (pr.prev IS NULL AND NOT pr.solo_propio)
             OR (pr.prev IS NOT NULL AND (
                  EXISTS (SELECT 1 FROM cliente_preventistas cp
                           WHERE cp.cliente_id = c.id AND cp.preventista_id = pr.prev)
                  OR (NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id)
                      AND EXISTS (SELECT 1 FROM pedidos pe
                                   WHERE pe.cliente_id = c.id AND pe.usuario_id = pr.prev
                                     AND pe.estado = 'entregado' AND pe.canal <> 'cambio'
                                     AND pe.fecha >= pr.hoy - 179))
                ))
           )
       -- Reservado a administracion: fuera de la cartera de un preventista,
       -- salvo que ya le haya vendido (mig 214).
       AND (NOT c.reservado_admin OR pr.prev IS NULL
            OR EXISTS (SELECT 1 FROM pedidos pe WHERE pe.cliente_id = c.id AND pe.usuario_id = pr.prev))
  ),
  ventas AS (
    SELECT pe.cliente_id, pe.fecha, pe.total, pe.usuario_id
      FROM pedidos pe JOIN universo u ON u.id = pe.cliente_id, params pr
     WHERE pe.sucursal_id = p_sucursal_id
       AND pe.estado = 'entregado' AND pe.canal <> 'cambio'
       AND pe.fecha >= pr.hoy - 364
  ),
  fechas AS (
    SELECT DISTINCT cliente_id, fecha FROM ventas
  ),
  gaps AS (
    SELECT cliente_id, (fecha - LAG(fecha) OVER (PARTITION BY cliente_id ORDER BY fecha)) AS gap
      FROM fechas
  ),
  -- Agrupado y no una subconsulta correlacionada: con 600 clientes la
  -- correlacionada recorria todas las fechas por cliente (255 ms contra 20).
  med AS (
    SELECT cliente_id, percentile_cont(0.5) WITHIN GROUP (ORDER BY gap)::numeric AS frecuencia
      FROM gaps WHERE gap IS NOT NULL GROUP BY cliente_id
  ),
  ritmo AS (
    SELECT f.cliente_id,
           MAX(f.fecha) AS ultima,
           -- Dias distintos con entrega, no pedidos: dos pedidos el mismo dia son una visita.
           COUNT(*)::int AS entregas,
           MAX(m.frecuencia) AS frecuencia
      FROM fechas f LEFT JOIN med m ON m.cliente_id = f.cliente_id
     GROUP BY f.cliente_id
  ),
  montos AS (
    SELECT v.cliente_id, SUM(v.total) / 6 AS mensual
      FROM ventas v, params pr
     WHERE v.fecha >= pr.hoy - 179
       AND (NOT pr.solo_propio OR v.usuario_id = p_perfil_id)
     GROUP BY v.cliente_id
  )
  SELECT u.id, u.codigo, u.nombre, u.zona, u.es_comodin, u.saldo_cuenta,
         r.ultima,
         (pr.hoy - r.ultima)::int,
         COALESCE(r.entregas, 0),
         ROUND(r.frecuencia, 1),
         CASE WHEN r.frecuencia > 0 THEN ROUND((pr.hoy - r.ultima) / r.frecuencia, 2) END,
         CASE
           WHEN r.ultima IS NULL THEN 'sin_compras'
           WHEN pr.hoy - r.ultima > 180 THEN 'perdido'
           WHEN pr.hoy - r.ultima > 90 THEN 'inactivo'
           WHEN r.entregas < 3 OR r.frecuencia IS NULL OR r.frecuencia = 0 THEN
             CASE WHEN pr.hoy - r.ultima >= 45 THEN 'ocasional' ELSE 'al_dia' END
           WHEN pr.hoy - r.ultima >= GREATEST(2 * r.frecuencia, 14) THEN 'atrasado'
           WHEN pr.hoy - r.ultima >= GREATEST(1.5 * r.frecuencia, 7) THEN 'por_vencer'
           ELSE 'al_dia'
         END,
         ROUND(COALESCE(m.mensual, 0), 2)
    FROM universo u
    CROSS JOIN params pr
    LEFT JOIN ritmo r  ON r.cliente_id = u.id
    LEFT JOIN montos m ON m.cliente_id = u.id;
$function$;

COMMENT ON FUNCTION public.clientes_ritmo_compra(BIGINT, TEXT, UUID, UUID, BIGINT) IS
  'Ritmo de compra de cada cliente contra su propia frecuencia (mig 308). Unica definicion de "atrasado": la consumen las herramientas del bot y sus digests.';


-- ---------------------------------------------------------------------------
-- 2 · bot_clientes_atrasados
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_clientes_atrasados(
  p_sucursal_id    BIGINT,
  p_rol            TEXT,
  p_perfil_id      UUID,
  p_preventista_id UUID DEFAULT NULL,
  p_incluir_por_vencer BOOLEAN DEFAULT false,
  p_incluir_inactivos  BOOLEAN DEFAULT false,
  p_limit          INTEGER DEFAULT 15
)
RETURNS json
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_alerta jsonb;
BEGIN
  IF p_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'bot_clientes_atrasados: sucursal requerida';
  END IF;

  -- La alerta "clientes inactivos" del reporte gerencial es de toda la
  -- sucursal: solo para quien ve la sucursal entera.
  IF p_rol IN ('admin', 'encargado') AND p_preventista_id IS NULL THEN
    v_alerta := reporte_alerta_detalle(p_sucursal_id, 'clientes_inactivos');
  END IF;

  RETURN (
    WITH r AS (
      SELECT * FROM clientes_ritmo_compra(p_sucursal_id, p_rol, p_perfil_id, p_preventista_id)
    ),
    lista AS (
      SELECT * FROM r
       WHERE estado = 'atrasado'
          OR (p_incluir_por_vencer AND estado = 'por_vencer')
          OR (p_incluir_inactivos AND estado IN ('inactivo', 'ocasional'))
    )
    SELECT json_build_object(
      'cartera', CASE
                   WHEN p_rol IN ('admin', 'encargado') AND p_preventista_id IS NULL THEN 'sucursal'
                   ELSE 'preventista' END,
      'montos', CASE WHEN p_rol IN ('admin', 'encargado') THEN 'todos' ELSE 'propios' END,
      'clientes_en_cartera', (SELECT COUNT(*) FROM r),
      'por_estado', (SELECT json_object_agg(estado, n) FROM (SELECT estado, COUNT(*) n FROM r GROUP BY estado) e),
      'atrasados', (SELECT COUNT(*) FROM r WHERE estado = 'atrasado'),
      'monto_mensual_en_riesgo', (SELECT COALESCE(SUM(monto_mensual), 0) FROM r WHERE estado = 'atrasado'),
      'criterio', 'Atrasado: cliente con ritmo propio (3 o mas entregas en el anio) que lleva al menos el doble de su frecuencia habitual sin comprar (mediana entre entregas), con un minimo de 14 dias y un maximo de 90. Aparte: inactivo (91 a 180 dias), ocasional (menos de 3 entregas en el anio, 45 dias o mas) y perdido (mas de 180). Monto en riesgo: lo que compra por mes (promedio de 180 dias).',
      'alerta_app_clientes_inactivos', CASE WHEN v_alerta IS NULL THEN NULL ELSE json_build_object(
          'cantidad', jsonb_array_length(v_alerta),
          'criterio', 'Alerta del reporte gerencial: ultima entrega hace entre 30 y 90 dias, sin mirar la frecuencia de cada cliente.')
        END,
      'clientes', COALESCE((
        SELECT json_agg(row_to_json(t.*))
          FROM (SELECT cliente_id, codigo, nombre, zona, es_comodin, saldo, ultima_compra,
                       dias_sin_comprar, frecuencia_dias, ratio, estado, monto_mensual
                  FROM lista
                 ORDER BY monto_mensual DESC, ratio DESC NULLS LAST, cliente_id
                 LIMIT p_limit) t
      ), '[]'::json)
    )
  );
END;
$function$;


-- ---------------------------------------------------------------------------
-- 3 · bot_ranking_clientes: consume reporte_ventas_por_cliente
-- ---------------------------------------------------------------------------
-- Periodo pedido y el anterior de igual largo. p_orden: 'mayores', 'menores'
-- (de los que compraron en el periodo) o 'caidas' (los que mas bajaron contra
-- el periodo anterior, incluidos los que dejaron de comprar).
CREATE OR REPLACE FUNCTION public.bot_ranking_clientes(
  p_desde          DATE,
  p_hasta          DATE,
  p_sucursal_id    BIGINT,
  p_rol            TEXT,
  p_perfil_id      UUID,
  p_preventista_id UUID DEFAULT NULL,
  p_orden          TEXT DEFAULT 'mayores',
  p_limit          INTEGER DEFAULT 10
)
RETURNS json
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_prev    UUID := CASE WHEN p_rol IN ('admin', 'encargado') THEN p_preventista_id ELSE p_perfil_id END;
  v_largo   INTEGER := p_hasta - p_desde + 1;
  v_actual  jsonb;
  v_anterior jsonb;
BEGIN
  IF p_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'bot_ranking_clientes: sucursal requerida';
  END IF;
  IF p_orden NOT IN ('mayores', 'menores', 'caidas') THEN
    RAISE EXCEPTION 'bot_ranking_clientes: orden invalido %', p_orden;
  END IF;
  -- Sin perfil, un rol que no ve todo caeria en "toda la sucursal": se corta.
  IF (p_rol IS NULL OR p_rol NOT IN ('admin', 'encargado')) AND p_perfil_id IS NULL THEN
    RAISE EXCEPTION 'bot_ranking_clientes: falta el perfil para el rol %', p_rol;
  END IF;

  -- La pantalla Reportes > Ventas por cliente, dos veces. Corre como servicio.
  v_actual   := reporte_ventas_por_cliente(p_desde, p_hasta, v_prev, p_sucursal_id);
  v_anterior := reporte_ventas_por_cliente(p_desde - v_largo, p_desde - 1, v_prev, p_sucursal_id);

  RETURN (
    WITH act AS (
      SELECT (x ->> 'cliente_id')::bigint AS cliente_id, x ->> 'nombre' AS nombre,
             x ->> 'zona' AS zona, (x ->> 'pedidos')::int AS pedidos, (x ->> 'total')::numeric AS total
        FROM jsonb_array_elements(v_actual -> 'clientes') x
       WHERE x ->> 'cliente_id' IS NOT NULL
    ),
    ant AS (
      SELECT (x ->> 'cliente_id')::bigint AS cliente_id, x ->> 'nombre' AS nombre,
             x ->> 'zona' AS zona, (x ->> 'total')::numeric AS total
        FROM jsonb_array_elements(v_anterior -> 'clientes') x
       WHERE x ->> 'cliente_id' IS NOT NULL
    ),
    juntos AS (
      SELECT COALESCE(a.cliente_id, b.cliente_id) AS cliente_id,
             COALESCE(a.nombre, b.nombre) AS nombre,
             COALESCE(a.zona, b.zona) AS zona,
             COALESCE(a.pedidos, 0) AS pedidos,
             COALESCE(a.total, 0) AS total,
             COALESCE(b.total, 0) AS total_anterior,
             COALESCE(a.total, 0) - COALESCE(b.total, 0) AS variacion
        FROM act a FULL JOIN ant b ON b.cliente_id = a.cliente_id
    ),
    elegidos AS (
      SELECT j.*, COALESCE(c.es_comodin, false) AS es_comodin, c.activo
        FROM juntos j LEFT JOIN clientes c ON c.id = j.cliente_id
       WHERE CASE p_orden
               WHEN 'caidas' THEN j.total_anterior > 0 AND j.variacion < 0
               ELSE j.total > 0
             END
       ORDER BY CASE p_orden WHEN 'mayores' THEN -j.total
                             WHEN 'menores' THEN j.total
                             ELSE j.variacion END,
                j.nombre, j.cliente_id
       LIMIT p_limit
    )
    SELECT json_build_object(
      'desde', p_desde, 'hasta', p_hasta,
      'anterior_desde', p_desde - v_largo, 'anterior_hasta', p_desde - 1,
      'sucursal', v_actual -> 'meta' ->> 'sucursal_nombre',
      'preventista', v_actual -> 'meta' ->> 'preventista_nombre',
      'orden', p_orden,
      'criterio', v_actual -> 'meta' ->> 'criterio',
      'total_periodo', (v_actual -> 'totales' ->> 'total')::numeric,
      'total_anterior', (v_anterior -> 'totales' ->> 'total')::numeric,
      'clientes_periodo', (v_actual -> 'totales' ->> 'clientes')::int,
      'clientes', COALESCE((SELECT json_agg(row_to_json(e.*)) FROM elegidos e), '[]'::json)
    )
  );
END;
$function$;


-- ---------------------------------------------------------------------------
-- 4 · bot_productos_sin_venta_con_stock (admin / encargado)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_productos_sin_venta_con_stock(
  p_sucursal_id BIGINT,
  p_dias        INTEGER DEFAULT 30,
  p_limit       INTEGER DEFAULT 30
)
RETURNS json
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  WITH params AS (
    SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date - (p_dias - 1) AS desde
  ),
  ultima AS (
    SELECT pi.producto_id, MAX(pe.fecha) AS ultima_venta,
           BOOL_OR(pe.fecha >= pr.desde) AS vendio_en_ventana
      FROM pedido_items pi
      JOIN pedidos pe ON pe.id = pi.pedido_id, params pr
     WHERE pe.sucursal_id = p_sucursal_id
       AND pe.estado = 'entregado' AND pe.canal <> 'cambio'
       AND NOT COALESCE(pi.es_bonificacion, false)
     GROUP BY pi.producto_id
  ),
  lista AS (
    SELECT p.id, p.codigo, p.nombre, p.categoria, pv.nombre AS proveedor,
           p.stock, p.precio, (p.stock * COALESCE(p.precio, 0)) AS valor_a_precio_venta,
           u.ultima_venta
      FROM productos p
      LEFT JOIN ultima u ON u.producto_id = p.id
      LEFT JOIN proveedores pv ON pv.id = p.proveedor_id
     WHERE p.sucursal_id = p_sucursal_id
       AND p.activo
       AND COALESCE(p.stock, 0) > 0
       AND COALESCE(u.vendio_en_ventana, false) = false
  )
  SELECT json_build_object(
    'dias', p_dias,
    'criterio', 'Productos activos con stock y sin ninguna unidad entregada (venta, sin regalos) en la ventana. Valor a precio de venta.',
    'productos_count', (SELECT COUNT(*) FROM lista),
    'valor_total_a_precio_venta', (SELECT COALESCE(SUM(valor_a_precio_venta), 0) FROM lista),
    'productos', COALESCE((
      SELECT json_agg(row_to_json(t.*))
        FROM (SELECT * FROM lista ORDER BY valor_a_precio_venta DESC, nombre LIMIT p_limit) t
    ), '[]'::json)
  );
$function$;


-- ---------------------------------------------------------------------------
-- 5 · bot_stock_y_ventas: lista filtrable (proveedor, categoria o texto)
-- ---------------------------------------------------------------------------
-- Para quien no es admin ni encargado: stock y precio, sin volumen de ventas
-- (296: el volumen de la sucursal no lo ve en la app).
CREATE OR REPLACE FUNCTION public.bot_stock_y_ventas(
  p_sucursal_id BIGINT,
  p_rol         TEXT,
  p_texto       TEXT DEFAULT NULL,
  p_proveedor   TEXT DEFAULT NULL,
  p_categoria   TEXT DEFAULT NULL,
  p_limit       INTEGER DEFAULT 30
)
RETURNS json
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  WITH params AS (
    SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date - 29 AS desde,
           p_rol IN ('admin', 'encargado') AS ve_ventas,
           -- El texto del usuario va literal: % y _ no son comodines.
           replace(replace(replace(p_texto, '\', '\\'), '%', '\%'), '_', '\_') AS t,
           replace(replace(replace(p_proveedor, '\', '\\'), '%', '\%'), '_', '\_') AS pv,
           replace(replace(replace(p_categoria, '\', '\\'), '%', '\%'), '_', '\_') AS ca
  ),
  candidatos AS (
    SELECT p.id, p.codigo, p.nombre, p.categoria, pv.nombre AS proveedor,
           p.stock, p.stock_minimo, p.precio
      FROM productos p
      LEFT JOIN proveedores pv ON pv.id = p.proveedor_id
      CROSS JOIN params f
     WHERE p.sucursal_id = p_sucursal_id
       AND p.activo
       AND (f.t IS NULL OR p.nombre ILIKE '%' || f.t || '%' OR p.codigo ILIKE '%' || f.t || '%')
       AND (f.pv IS NULL OR pv.nombre ILIKE '%' || f.pv || '%')
       AND (f.ca IS NULL OR p.categoria ILIKE '%' || f.ca || '%')
  ),
  ventas AS (
    SELECT pi.producto_id,
           SUM(pi.cantidad) FILTER (WHERE NOT COALESCE(pi.es_bonificacion, false)) AS vendidas,
           SUM(pi.cantidad) FILTER (WHERE COALESCE(pi.es_bonificacion, false))     AS regaladas
      FROM pedido_items pi
      JOIN pedidos pe ON pe.id = pi.pedido_id
      JOIN candidatos ca ON ca.id = pi.producto_id, params pr
     WHERE pe.sucursal_id = p_sucursal_id
       AND pe.estado = 'entregado' AND pe.canal <> 'cambio'
       AND pe.fecha >= pr.desde
     GROUP BY pi.producto_id
  ),
  filas AS (
    SELECT ca.*,
           CASE WHEN pr.ve_ventas THEN COALESCE(v.vendidas, 0) END AS vendidas_30d,
           CASE WHEN pr.ve_ventas THEN COALESCE(v.regaladas, 0) END AS regaladas_30d,
           CASE WHEN pr.ve_ventas AND COALESCE(v.vendidas, 0) > 0
                THEN ROUND(ca.stock / (v.vendidas / 30.0), 0) END AS cobertura_dias
      FROM candidatos ca CROSS JOIN params pr
      LEFT JOIN ventas v ON v.producto_id = ca.id
  )
  SELECT json_build_object(
    'filtro', json_build_object('texto', p_texto, 'proveedor', p_proveedor, 'categoria', p_categoria),
    'ventas_visibles', (SELECT ve_ventas FROM params),
    'criterio', 'Ventas: unidades entregadas en los ultimos 30 dias, sin regalos (aparte). Cobertura: dias de stock al ritmo de esas ventas.',
    'productos_count', (SELECT COUNT(*) FROM filas),
    'productos', COALESCE((
      SELECT json_agg(row_to_json(t.*))
        FROM (SELECT * FROM filas ORDER BY vendidas_30d DESC NULLS LAST, nombre LIMIT p_limit) t
    ), '[]'::json)
  );
$function$;


-- ---------------------------------------------------------------------------
-- 6 · bot_productos_dejados_cliente: lo que llevaba y dejo de llevar
-- ---------------------------------------------------------------------------
-- Ultimas 10 entregas del cliente (todos los vendedores: es un hecho). Un
-- producto es "habitual" si estuvo en al menos la mitad de las 7 anteriores a
-- las ultimas 3, y "dejado" si no aparece en ninguna de esas ultimas 3. Hace
-- falta un historial minimo de 6 entregas. Sin montos.
CREATE OR REPLACE FUNCTION public.bot_productos_dejados_cliente(
  p_cliente_id  BIGINT,
  p_perfil_id   UUID,
  p_rol         TEXT,
  p_sucursal_id BIGINT
)
RETURNS json
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_entregas INT;
BEGIN
  IF p_rol = 'preventista' THEN
    IF NOT (
      EXISTS(SELECT 1 FROM cliente_preventistas
             WHERE cliente_id = p_cliente_id AND preventista_id = p_perfil_id)
      OR NOT EXISTS(SELECT 1 FROM cliente_preventistas WHERE cliente_id = p_cliente_id)
    ) THEN
      RETURN json_build_object('cliente_id', p_cliente_id, 'productos', '[]'::json,
        'error', 'Cliente asignado a otro preventista');
    END IF;
    IF EXISTS(SELECT 1 FROM clientes c WHERE c.id = p_cliente_id AND c.reservado_admin)
       AND NOT EXISTS(SELECT 1 FROM pedidos pe
                      WHERE pe.cliente_id = p_cliente_id AND pe.usuario_id = p_perfil_id)
    THEN
      RETURN json_build_object('cliente_id', p_cliente_id, 'productos', '[]'::json,
        'error', 'Cliente reservado a administración');
    END IF;
  END IF;

  SELECT COUNT(*) INTO v_entregas
    FROM pedidos
   WHERE cliente_id = p_cliente_id AND sucursal_id = p_sucursal_id
     AND estado = 'entregado' AND canal <> 'cambio';

  IF v_entregas < 6 THEN
    RETURN json_build_object('cliente_id', p_cliente_id, 'entregas', v_entregas,
      'productos', '[]'::json,
      'nota', 'Historial corto: hacen falta al menos 6 entregas para saber que dejo de llevar.');
  END IF;

  RETURN (
    WITH ult AS (
      SELECT id, fecha, row_number() OVER (ORDER BY fecha DESC, id DESC) AS n
        FROM pedidos
       WHERE cliente_id = p_cliente_id AND sucursal_id = p_sucursal_id
         AND estado = 'entregado' AND canal <> 'cambio'
       ORDER BY fecha DESC, id DESC
       LIMIT 10
    ),
    items AS (
      SELECT DISTINCT u.n, u.fecha, pi.producto_id
        FROM ult u JOIN pedido_items pi ON pi.pedido_id = u.id
       WHERE NOT COALESCE(pi.es_bonificacion, false)
    ),
    cuenta AS (
      SELECT producto_id,
             COUNT(*) FILTER (WHERE n > 3) AS veces_antes,
             COUNT(*) FILTER (WHERE n <= 3) AS veces_ultimas,
             MAX(fecha) AS ultima_vez
        FROM items GROUP BY producto_id
    ),
    base AS (SELECT COUNT(*) FILTER (WHERE n > 3) AS antes FROM ult)
    SELECT json_build_object(
      'cliente_id', p_cliente_id,
      'entregas', v_entregas,
      'criterio', 'Habitual: estuvo en al menos la mitad de las entregas 4 a 10 (contando desde la ultima). Dejado: no aparece en las ultimas 3.',
      'productos', COALESCE((
        SELECT json_agg(json_build_object(
                 'producto_id', p.id, 'codigo', p.codigo, 'nombre', p.nombre,
                 'veces_en_entregas_anteriores', c.veces_antes,
                 'entregas_anteriores', b.antes,
                 'ultima_vez', c.ultima_vez,
                 'activo', p.activo)
               ORDER BY c.veces_antes DESC, p.nombre)
          FROM cuenta c CROSS JOIN base b JOIN productos p ON p.id = c.producto_id
         WHERE c.veces_ultimas = 0 AND c.veces_antes * 2 >= b.antes AND p.activo
      ), '[]'::json)
    )
  );
END;
$function$;


-- ---------------------------------------------------------------------------
-- 7 · bot_resumen_cliente_visita: la ficha para entrar al comercio
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_resumen_cliente_visita(
  p_cliente_id  BIGINT,
  p_perfil_id   UUID,
  p_rol         TEXT,
  p_sucursal_id BIGINT
)
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
-- 8 · Permisos: todas server-only (las tres mitades)
-- ---------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.clientes_ritmo_compra(BIGINT, TEXT, UUID, UUID, BIGINT) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.bot_clientes_atrasados(BIGINT, TEXT, UUID, UUID, BOOLEAN, BOOLEAN, INTEGER) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.bot_ranking_clientes(DATE, DATE, BIGINT, TEXT, UUID, UUID, TEXT, INTEGER) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.bot_productos_sin_venta_con_stock(BIGINT, INTEGER, INTEGER) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.bot_stock_y_ventas(BIGINT, TEXT, TEXT, TEXT, TEXT, INTEGER) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.bot_productos_dejados_cliente(BIGINT, UUID, TEXT, BIGINT) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.bot_resumen_cliente_visita(BIGINT, UUID, TEXT, BIGINT) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.clientes_ritmo_compra(BIGINT, TEXT, UUID, UUID, BIGINT) TO service_role;
GRANT EXECUTE ON FUNCTION public.bot_clientes_atrasados(BIGINT, TEXT, UUID, UUID, BOOLEAN, BOOLEAN, INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.bot_ranking_clientes(DATE, DATE, BIGINT, TEXT, UUID, UUID, TEXT, INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.bot_productos_sin_venta_con_stock(BIGINT, INTEGER, INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.bot_stock_y_ventas(BIGINT, TEXT, TEXT, TEXT, TEXT, INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.bot_productos_dejados_cliente(BIGINT, UUID, TEXT, BIGINT) TO service_role;
GRANT EXECUTE ON FUNCTION public.bot_resumen_cliente_visita(BIGINT, UUID, TEXT, BIGINT) TO service_role;


-- ---------------------------------------------------------------------------
-- 8b · La RFM se va: clientes_atrasados la reemplaza y nada mas la llama
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.bot_sugerir_visitas_rfm(uuid, bigint, integer);


-- ---------------------------------------------------------------------------
-- 9 · BOT-B: el ranking de clientes tambien consume su pantalla
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
      ('public.bot_resumen_cliente_visita(bigint,uuid,text,bigint)',        'clientes_ritmo_compra')
    ) AS m(funcion, canonica)
   WHERE to_regprocedure(m.funcion) IS NULL
      -- Sin comentarios: un "-- antes llamaba a reporte_x(" no cuenta como llamada.
      OR regexp_replace(pg_get_functiondef(to_regprocedure(m.funcion)), '--[^\n]*', '', 'g')
           NOT ILIKE '%' || m.canonica || '(%';
$function$;

COMMENT ON FUNCTION public.auditoria_bot_sin_funcion_canonica() IS
  'BOT-B (300, 308). Cada funcion del bot que da un numero de una pantalla consume la funcion de esa pantalla (deuda, ventas por preventista, ventas por cliente), y las que hablan de "atrasado" consumen clientes_ritmo_compra (una sola definicion). Las que todavia copian la definicion de venta (bot_ventas_periodo, bot_mis_ventas, bot_ficha_producto, bot_historico_pedidos_cliente, obtener_resumen_cuenta_cliente_bot) no estan: no hay funcion canonica que consumir.';


-- ---------------------------------------------------------------------------
-- 10 · El ensayo
-- ---------------------------------------------------------------------------
DO $ensayo$
DECLARE
  s         RECORD;
  pv        RECORD;
  v_j       json;
  v_hoy     date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_esperado numeric;
  v_obt     numeric;
  v_cli     bigint;
  v_otro    bigint;
BEGIN
  FOR s IN SELECT id FROM sucursales WHERE activa LOOP
    -- 10a. El ranking de "mayores" suma lo mismo que la pantalla.
    v_j := bot_ranking_clientes(v_hoy - 29, v_hoy, s.id, 'admin', NULL, NULL, 'mayores', 100000);
    SELECT COALESCE(SUM((x ->> 'total')::numeric), 0) INTO v_esperado
      FROM jsonb_array_elements(reporte_ventas_por_cliente(v_hoy - 29, v_hoy, NULL, s.id) -> 'clientes') x
     WHERE x ->> 'cliente_id' IS NOT NULL;
    SELECT COALESCE(SUM((c ->> 'total')::numeric), 0) INTO v_obt FROM json_array_elements(v_j -> 'clientes') c;
    IF abs(v_obt - v_esperado) > 1 THEN
      RAISE EXCEPTION 'ensayo 308: ranking de la sucursal %: % vs pantalla %', s.id, v_obt, v_esperado;
    END IF;

    -- 10b. Atrasados: la lista son clientes atrasados de verdad.
    v_j := bot_clientes_atrasados(s.id, 'admin', NULL, NULL, false, false, 50);
    IF EXISTS (SELECT 1 FROM json_array_elements(v_j -> 'clientes') c WHERE c ->> 'estado' <> 'atrasado') THEN
      RAISE EXCEPTION 'ensayo 308: la lista de atrasados de la sucursal % trae otros estados', s.id;
    END IF;

    -- 10c. Un preventista: su cartera no tiene clientes de otro preventista, ni
    --      reservados ajenos, y los montos son solo los suyos.
    FOR pv IN SELECT pf.id FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
               WHERE pf.rol = 'preventista' AND pf.activo AND us.sucursal_id = s.id LOOP
      IF EXISTS (
        SELECT 1 FROM clientes_ritmo_compra(s.id, 'preventista', pv.id, NULL) r
         WHERE EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = r.cliente_id)
           AND NOT EXISTS (SELECT 1 FROM cliente_preventistas cp
                            WHERE cp.cliente_id = r.cliente_id AND cp.preventista_id = pv.id)
      ) THEN
        RAISE EXCEPTION 'ensayo 308: la cartera del preventista % trae clientes de otro', pv.id;
      END IF;
      -- Ni reservados a los que no les vendio, ni huerfanos sin venta suya en 180 dias.
      IF EXISTS (
        SELECT 1 FROM clientes_ritmo_compra(s.id, 'preventista', pv.id, NULL) r
          JOIN clientes c ON c.id = r.cliente_id
         WHERE (c.reservado_admin AND NOT EXISTS (SELECT 1 FROM pedidos pe WHERE pe.cliente_id = c.id AND pe.usuario_id = pv.id))
            OR (NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id)
                AND NOT EXISTS (SELECT 1 FROM pedidos pe WHERE pe.cliente_id = c.id AND pe.usuario_id = pv.id
                                  AND pe.estado = 'entregado' AND pe.canal <> 'cambio' AND pe.fecha >= v_hoy - 179))
      ) THEN
        RAISE EXCEPTION 'ensayo 308: la cartera del preventista % trae reservados o huerfanos ajenos', pv.id;
      END IF;
      -- Su ranking es el de la pantalla filtrada por el: solo lo suyo.
      v_j := bot_ranking_clientes(v_hoy - 29, v_hoy, s.id, 'preventista', pv.id, NULL, 'mayores', 100000);
      SELECT COALESCE(SUM((x ->> 'total')::numeric), 0) INTO v_esperado
        FROM jsonb_array_elements(reporte_ventas_por_cliente(v_hoy - 29, v_hoy, pv.id, s.id) -> 'clientes') x
       WHERE x ->> 'cliente_id' IS NOT NULL;
      SELECT COALESCE(SUM((c ->> 'total')::numeric), 0) INTO v_obt FROM json_array_elements(v_j -> 'clientes') c;
      IF abs(v_obt - v_esperado) > 1 THEN
        RAISE EXCEPTION 'ensayo 308: ranking del preventista %: % vs pantalla %', pv.id, v_obt, v_esperado;
      END IF;
      -- Un cliente asignado a OTRO preventista: resumen y dejados rebotan.
      SELECT cp.cliente_id INTO v_otro
        FROM cliente_preventistas cp JOIN clientes c ON c.id = cp.cliente_id
       WHERE c.sucursal_id = s.id AND cp.preventista_id <> pv.id
         AND NOT EXISTS (SELECT 1 FROM cliente_preventistas cp2 WHERE cp2.cliente_id = cp.cliente_id AND cp2.preventista_id = pv.id)
       LIMIT 1;
      IF v_otro IS NOT NULL THEN
        IF bot_resumen_cliente_visita(v_otro, pv.id, 'preventista', s.id) ->> 'error' IS NULL
           OR bot_productos_dejados_cliente(v_otro, pv.id, 'preventista', s.id) ->> 'error' IS NULL THEN
          RAISE EXCEPTION 'ensayo 308: el preventista % ve el resumen de un cliente ajeno (%)', pv.id, v_otro;
        END IF;
      END IF;
      -- Un cliente suyo con historial: el ultimo pedido del resumen es propio.
      SELECT r.cliente_id INTO v_cli
        FROM clientes_ritmo_compra(s.id, 'preventista', pv.id, NULL) r
       WHERE r.entregas_365 >= 3 LIMIT 1;
      IF v_cli IS NOT NULL THEN
        v_j := bot_resumen_cliente_visita(v_cli, pv.id, 'preventista', s.id);
        IF v_j -> 'ultimo_pedido' IS NOT NULL AND json_typeof(v_j -> 'ultimo_pedido') = 'object' AND NOT EXISTS (
             SELECT 1 FROM pedidos pe
              WHERE pe.cliente_id = v_cli AND pe.fecha = (v_j -> 'ultimo_pedido' ->> 'fecha')::date
                AND (pe.usuario_id = pv.id OR pe.transportista_id = pv.id)) THEN
          RAISE EXCEPTION 'ensayo 308: el resumen le muestra al preventista % un ultimo pedido ajeno (cliente %)', pv.id, v_cli;
        END IF;
      END IF;
      SELECT r.cliente_id INTO v_cli
        FROM clientes_ritmo_compra(s.id, 'preventista', pv.id, NULL) r
       WHERE r.monto_mensual > 0
       LIMIT 1;
      IF v_cli IS NOT NULL THEN
        SELECT ROUND(COALESCE(SUM(total), 0) / 6, 2) INTO v_esperado
          FROM pedidos
         WHERE cliente_id = v_cli AND sucursal_id = s.id AND usuario_id = pv.id
           AND estado = 'entregado' AND canal <> 'cambio' AND fecha >= v_hoy - 179;
        IF (SELECT monto_mensual FROM clientes_ritmo_compra(s.id, 'preventista', pv.id, NULL)
             WHERE cliente_id = v_cli) <> v_esperado THEN
          RAISE EXCEPTION 'ensayo 308: monto mensual del cliente % para el preventista % no es el propio', v_cli, pv.id;
        END IF;
      END IF;
      -- Las otras herramientas corren para un preventista.
      PERFORM bot_clientes_atrasados(s.id, 'preventista', pv.id, NULL, true, true, 5);
      PERFORM bot_ranking_clientes(v_hoy - 29, v_hoy, s.id, 'preventista', pv.id, NULL, 'caidas', 5);
      PERFORM bot_stock_y_ventas(s.id, 'preventista', 'manaos', NULL, NULL, 5);
    END LOOP;

    -- 10d. Las de producto corren y no traen ventas a un preventista.
    PERFORM bot_productos_sin_venta_con_stock(s.id, 30, 5);
    FOR pv IN SELECT unnest(ARRAY['preventista', 'transportista', 'deposito']) AS rol LOOP
      v_j := bot_stock_y_ventas(s.id, pv.rol, 'a', NULL, NULL, 20);
      IF EXISTS (SELECT 1 FROM json_array_elements(v_j -> 'productos') p
                  WHERE p ->> 'vendidas_30d' IS NOT NULL OR p ->> 'cobertura_dias' IS NOT NULL) THEN
        RAISE EXCEPTION 'ensayo 308: stock_y_ventas le muestra ventas al rol %', pv.rol;
      END IF;
    END LOOP;
    -- Un % del usuario es literal, no un comodin.
    IF (bot_stock_y_ventas(s.id, 'admin', '%%', NULL, NULL, 5) ->> 'productos_count')::int > 0 THEN
      RAISE EXCEPTION 'ensayo 308: stock_y_ventas toma %% como comodin';
    END IF;

    -- 10e. Resumen de visita y dejados corren sobre un cliente con historial.
    SELECT cliente_id INTO v_cli FROM pedidos
     WHERE sucursal_id = s.id AND estado = 'entregado' AND canal <> 'cambio'
     GROUP BY cliente_id HAVING COUNT(*) >= 10 ORDER BY COUNT(*) DESC LIMIT 1;
    IF v_cli IS NOT NULL THEN
      v_j := bot_resumen_cliente_visita(v_cli, NULL, 'admin', s.id);
      IF v_j ->> 'error' IS NOT NULL OR v_j -> 'ritmo' IS NULL THEN
        RAISE EXCEPTION 'ensayo 308: resumen de visita del cliente %: %', v_cli, v_j;
      END IF;
    END IF;
  END LOOP;

  -- 10f. BOT-B sigue en verde con los pares nuevos.
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(auditoria_integridad() -> 'checks') c
                  WHERE c ->> 'id' = 'BOT-B' AND (c ->> 'ok')::boolean) THEN
    RAISE EXCEPTION 'ensayo 308: BOT-B en rojo';
  END IF;

  RAISE NOTICE 'ensayo 308: ritmo, atrasados, ranking, stock, dejados y resumen OK';
END;
$ensayo$;

COMMIT;
