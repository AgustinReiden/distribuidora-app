-- =========================================================================
-- 198_vendedores_del_periodo.sql
--
-- Corrige un agujero de la 197 detectado al cablear el front.
--
-- El selector de preventista del reporte se iba a llenar con
-- `usePreventistasQuery`, que filtra `perfiles.rol = 'preventista'`. Pero la
-- venta se atribuye a `pedidos.usuario_id`, y quien carga pedidos NO es sólo
-- quien tiene ese rol. Medido sobre 2026:
--
--     Juan        preventista   912 ped   $45.796.256
--     Christian   preventista  1164 ped   $40.198.490
--     Osvaldo     preventista  1035 ped   $30.427.603
--     Marcelo     preventista   787 ped   $24.452.008
--     Jony        ENCARGADO     287 ped   $16.630.570   <- no entraba en la lista
--     Nacho R     admin          48 ped    $6.102.760   <- tampoco
--     Virginia H  admin         197 ped    $5.925.140   <- tampoco
--     Agustín     admin          70 ped    $1.963.550
--     Pablo       admin          31 ped    $1.664.680
--     Emilia H    admin          24 ped      $487.520
--     Julio       admin           2 ped       $54.300
--
-- O sea: un desplegable por rol escondía $32,8M de venta real y no había forma
-- de pedirle al reporte las ventas de Jony. Es exactamente la misma familia de
-- bug que la 197 vino a cerrar (el dato existe y la pantalla no lo puede
-- alcanzar), así que la lista sale de los DATOS y no de los roles: quien tenga
-- una entrega en el período aparece, sea cual sea su rol hoy.
--
-- `vendedores` se calcula ignorando `p_preventista_id` a propósito: si se
-- filtrara junto con el resto, al elegir a alguien el desplegable se quedaría
-- con esa única opción y no habría manera de volver.
--
-- Quedan afuera los pedidos con `usuario_id IS NULL` (2 entregados en 2026):
-- no son de nadie, no se pueden ofrecer como filtro. Siguen contando dentro de
-- "Todos", así que el total no cambia.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.reporte_ventas_por_cliente(
  p_desde          date,
  p_hasta          date,
  p_preventista_id uuid   DEFAULT NULL,
  p_sucursal_id    bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursales   bigint[];
  v_asignadas    bigint[];
  v_nombre       text;
  v_prev_nombre  text;
  v_result       jsonb;
  v_es_servicio  boolean := (auth.uid() IS NULL);
  v_rol          text;
BEGIN
  IF p_desde IS NULL OR p_hasta IS NULL THEN
    RAISE EXCEPTION 'Se requieren las fechas desde y hasta';
  END IF;
  IF p_desde > p_hasta THEN
    RAISE EXCEPTION 'La fecha desde (%) es posterior a la fecha hasta (%)', p_desde, p_hasta;
  END IF;

  -- ---- Guard (idéntico a reporte_valuacion_inventario) -------------------
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

  IF p_sucursal_id IS NULL THEN
    SELECT array_agg(id) INTO v_sucursales FROM sucursales WHERE activa;
    IF NOT v_es_servicio THEN
      SELECT array_agg(s) INTO v_sucursales
        FROM unnest(v_sucursales) AS s WHERE s = ANY(v_asignadas);
    END IF;
    v_nombre := 'Red (consolidado)';
  ELSE
    IF NOT v_es_servicio AND NOT (p_sucursal_id = ANY(v_asignadas)) THEN
      RAISE EXCEPTION 'Acceso denegado: la sucursal % no está asignada al usuario', p_sucursal_id;
    END IF;
    v_sucursales := ARRAY[p_sucursal_id];
    SELECT nombre INTO v_nombre FROM sucursales WHERE id = p_sucursal_id;
  END IF;

  IF v_sucursales IS NULL OR array_length(v_sucursales, 1) IS NULL THEN
    RAISE EXCEPTION 'Acceso denegado: sin sucursales disponibles para el usuario';
  END IF;

  IF p_preventista_id IS NOT NULL THEN
    SELECT nombre INTO v_prev_nombre FROM perfiles WHERE id = p_preventista_id;
  END IF;

  -- ---- Datos --------------------------------------------------------------
  WITH ventana AS (
    -- El período/sucursal SIN el filtro de preventista. De acá sale la lista de
    -- vendedores del desplegable.
    SELECT pe.id, pe.cliente_id, pe.total, pe.fecha, pe.usuario_id
    FROM pedidos pe
    WHERE pe.estado = 'entregado'
      AND COALESCE(pe.canal, 'app') <> 'cambio'
      AND pe.fecha BETWEEN p_desde AND p_hasta
      AND pe.sucursal_id = ANY(v_sucursales)
  ),
  vendedores AS (
    SELECT v.usuario_id AS id,
           COALESCE(NULLIF(btrim(per.nombre), ''), '(sin nombre)') AS nombre,
           COUNT(*)::int AS pedidos,
           SUM(v.total)  AS total
    FROM ventana v
    JOIN perfiles per ON per.id = v.usuario_id
    GROUP BY v.usuario_id, per.nombre
  ),
  base AS (
    SELECT
      v.cliente_id,
      v.total,
      to_char(v.fecha, 'YYYY-MM') AS mes,
      CASE
        WHEN v.cliente_id IS NULL THEN '(sin cliente asignado)'
        ELSE COALESCE(
               NULLIF(btrim(c.nombre_fantasia), ''),
               NULLIF(btrim(c.razon_social), ''),
               '(sin nombre)')
      END AS nombre,
      c.codigo,
      COALESCE(z.nombre, NULLIF(btrim(c.zona), ''), 'SIN ZONA') AS zona
    FROM ventana v
    LEFT JOIN clientes c ON c.id = v.cliente_id
    LEFT JOIN zonas    z ON z.id = c.zona_id
    WHERE p_preventista_id IS NULL OR v.usuario_id = p_preventista_id
  ),
  por_cliente AS (
    SELECT cliente_id, nombre, codigo, zona,
           COUNT(*)::int AS pedidos,
           SUM(total)    AS total
    FROM base
    GROUP BY cliente_id, nombre, codigo, zona
  ),
  mes_por_cliente AS (
    SELECT cliente_id, jsonb_object_agg(mes, total) AS por_mes
    FROM (SELECT cliente_id, mes, SUM(total) AS total FROM base GROUP BY cliente_id, mes) t
    GROUP BY cliente_id
  ),
  -- por_zona se arma sobre por_cliente y no sobre base: así la fila
  -- "(sin cliente asignado)" cuenta como un cliente y los totales de las dos
  -- vistas dan exactamente lo mismo.
  por_zona AS (
    SELECT zona,
           COUNT(*)::int      AS clientes,
           SUM(pedidos)::int  AS pedidos,
           SUM(total)         AS total
    FROM por_cliente
    GROUP BY zona
  )
  SELECT jsonb_build_object(
    'meta', jsonb_build_object(
      'desde',              p_desde,
      'hasta',              p_hasta,
      'preventista_id',     p_preventista_id,
      'preventista_nombre', COALESCE(v_prev_nombre, 'Todos'),
      'sucursal_id',        p_sucursal_id,
      'sucursal_nombre',    v_nombre,
      'generado_at',        now(),
      'criterio',           'Pedidos entregados, por fecha de pedido, atribuidos a quien los cargó. Excluye cancelados y cambios/devoluciones.'
    ),
    'meses', COALESCE((SELECT jsonb_agg(m ORDER BY m) FROM (SELECT DISTINCT mes AS m FROM base) x), '[]'::jsonb),
    'vendedores', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id', vd.id, 'nombre', vd.nombre, 'pedidos', vd.pedidos, 'total', vd.total
             ) ORDER BY vd.total DESC)
      FROM vendedores vd
    ), '[]'::jsonb),
    'totales', jsonb_build_object(
      'clientes', (SELECT COUNT(*)::int                 FROM por_cliente),
      'pedidos',  (SELECT COALESCE(SUM(pedidos),0)::int FROM por_cliente),
      'total',    (SELECT COALESCE(SUM(total),0)        FROM por_cliente)
    ),
    'clientes', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'cliente_id', pc.cliente_id,
               'codigo',     pc.codigo,
               'nombre',     pc.nombre,
               'zona',       pc.zona,
               'pedidos',    pc.pedidos,
               'total',      pc.total,
               'por_mes',    COALESCE(mc.por_mes, '{}'::jsonb)
             ) ORDER BY pc.total DESC, pc.nombre)
      FROM por_cliente pc
      LEFT JOIN mes_por_cliente mc ON mc.cliente_id IS NOT DISTINCT FROM pc.cliente_id
    ), '[]'::jsonb),
    'zonas', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'zona',            pz.zona,
               'clientes',        pz.clientes,
               'pedidos',         pz.pedidos,
               'total',           pz.total,
               'ticket_promedio', CASE WHEN pz.pedidos > 0 THEN round(pz.total / pz.pedidos, 2) ELSE 0 END
             ) ORDER BY pz.total DESC)
      FROM por_zona pz
    ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$function$;

-- CREATE OR REPLACE conserva el ACL de la 197, pero el REVOKE/GRANT se repite
-- igual: es barato y no depende de que nadie haya tocado los permisos en el medio.
REVOKE ALL ON FUNCTION public.reporte_ventas_por_cliente(date, date, uuid, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reporte_ventas_por_cliente(date, date, uuid, bigint) TO authenticated;

DO $verif$
DECLARE
  v_acl text;
BEGIN
  SELECT array_to_string(proacl, ',') INTO v_acl
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'reporte_ventas_por_cliente';

  IF v_acl IS NULL THEN
    RAISE EXCEPTION 'reporte_ventas_por_cliente quedó con ACL default (PUBLIC ejecuta)';
  END IF;
  IF v_acl LIKE '=X/%' OR v_acl LIKE '%,=X/%' THEN
    RAISE EXCEPTION 'reporte_ventas_por_cliente quedó ejecutable por PUBLIC: %', v_acl;
  END IF;
  IF v_acl LIKE '%anon=%' THEN
    RAISE EXCEPTION 'reporte_ventas_por_cliente quedó ejecutable por anon: %', v_acl;
  END IF;
  IF v_acl NOT LIKE '%authenticated=X%' THEN
    RAISE EXCEPTION 'reporte_ventas_por_cliente no quedó ejecutable por authenticated: %', v_acl;
  END IF;
END
$verif$;
