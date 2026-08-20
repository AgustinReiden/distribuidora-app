-- =========================================================================
-- 197_ventas_por_cliente_y_zona.sql
--
-- "Necesito todas las ventas de Cristian desde principio de año por cliente.
--  No el detalle sino el total por cada cliente. Para ver a quiénes le vendió.
--  NECESITO QUE AL LADO DE CADA CLIENTE SALGA A QUÉ ZONA PERTENECE SEGÚN LA
--  CLASIFICACIÓN QUE TIENE EN LA FICHA."
--
-- La pestaña "Por Cliente" de Reportes ya existía y no servía para eso. Hacía
-- `from('pedidos').select('*, cliente:clientes(*)')` desde el navegador, sin
-- filtro de estado y sin paginar:
--
--   * sumaba pedidos CANCELADOS (284 en lo que va de 2026);
--   * se cortaba en las 1.000 filas del default de PostgREST, y este año hay
--     4.558 pedidos entregados -> el total que mostraba estaba mal, en silencio
--     y sin ningún cartel;
--   * filtraba por `created_at` en vez de `pedidos.fecha`, que es la base que
--     usan `bot_mis_ventas` y `reporte_gerencial`;
--   * y arriba de todo eso la tabla hacía `slice(0, 30)`.
--
-- Los cuatro se arreglan moviendo la agregación acá. De paso el mismo payload
-- alimenta la pestaña "Por Zona", que tenía los mismos dos primeros bugs.
--
-- TRES DEFINICIONES DE NEGOCIO QUE QUEDAN ESCRITAS ACÁ
-- ----------------------------------------------------
--
-- 1) La venta se le atribuye a `pedidos.usuario_id` -- quién CARGÓ el pedido --
--    y no a `clientes.preventista_id` -- de quién es el cliente.
--
--    Es lo que se pidió ("para ver a quiénes le vendió") y es la convención que
--    ya usa `bot_mis_ventas`. La diferencia no es cosmética; medida sobre 2026:
--
--      por usuario_id            Christian 1.164 ped / $40.198.490
--      por clientes.preventista  Christian 1.180 ped / $37.210.720
--                                + 891 ped / $48.925.572 SIN preventista, que
--                                  por ese criterio no se le cuentan a nadie.
--
--    El cruce entre las dos lecturas es justamente lo que el informe muestra:
--    de los 1.164 pedidos de Christian, 78 ($3,5M) son a clientes de zonas de
--    MARCELO y 53 ($4,8M) a clientes sin zona cargada.
--
-- 2) `COALESCE(canal,'app') <> 'cambio'` en vez del `canal = 'app'` que usa el
--    bot. Los cambios/devoluciones son pedidos con total 0 (mig 089): sumarlos
--    no mueve el monto pero infla el conteo de pedidos y ensucia el ticket
--    promedio. La lista negra es a propósito: una lista blanca dejaría caer en
--    silencio un canal futuro que sí fuera venta real, que es exactamente la
--    familia de bug que esta migración viene a cerrar.
--
-- 3) La zona sale de `clientes.zona_id -> zonas.nombre`, con el texto libre
--    `clientes.zona` sólo como fallback. `zona_id` es la columna canónica (es
--    la que escribe el select de la ficha); `clientes.zona` está marcada
--    @deprecated en el front y hoy está 100% sincronizada (459 de 459), así que
--    el COALESCE es red de seguridad, no fuente.
--
-- EL LEFT JOIN A CLIENTES NO ES DECORATIVO
-- -----------------------------------------
-- Hay 7 pedidos entregados en 2026 con `cliente_id IS NULL` ($200.070; 3 de
-- ellos, $83.750, son de Christian). Con INNER JOIN desaparecían y el informe
-- cerraba $83.750 por debajo del total de ventas del preventista, sin avisar.
-- Van agrupados en una fila `(sin cliente asignado)` para que el total del
-- informe SIEMPRE reconcilie contra el total de ventas. No hay FKs rotas:
-- `cliente_id` es NULL de verdad, no apunta a un cliente borrado.
--
-- Guard: calcado de `reporte_valuacion_inventario` (mig 131) -- rol
-- admin/encargado, sucursales de `usuario_sucursales`, p_sucursal_id NULL =
-- consolidado de las asignadas, auth.uid() NULL = service role.
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
  WITH base AS (
    SELECT
      pe.cliente_id,
      pe.total,
      to_char(pe.fecha, 'YYYY-MM') AS mes,
      CASE
        WHEN pe.cliente_id IS NULL THEN '(sin cliente asignado)'
        ELSE COALESCE(
               NULLIF(btrim(c.nombre_fantasia), ''),
               NULLIF(btrim(c.razon_social), ''),
               '(sin nombre)')
      END AS nombre,
      c.codigo,
      COALESCE(z.nombre, NULLIF(btrim(c.zona), ''), 'SIN ZONA') AS zona
    FROM pedidos pe
    LEFT JOIN clientes c ON c.id = pe.cliente_id
    LEFT JOIN zonas    z ON z.id = c.zona_id
    WHERE pe.estado = 'entregado'
      AND COALESCE(pe.canal, 'app') <> 'cambio'
      AND pe.fecha BETWEEN p_desde AND p_hasta
      AND pe.sucursal_id = ANY(v_sucursales)
      AND (p_preventista_id IS NULL OR pe.usuario_id = p_preventista_id)
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
    'totales', jsonb_build_object(
      'clientes', (SELECT COUNT(*)::int             FROM por_cliente),
      'pedidos',  (SELECT COALESCE(SUM(pedidos),0)::int FROM por_cliente),
      'total',    (SELECT COALESCE(SUM(total),0)    FROM por_cliente)
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

COMMENT ON FUNCTION public.reporte_ventas_por_cliente(date, date, uuid, bigint) IS
  'Ventas por cliente (con la zona de la ficha) y por zona, filtrables por preventista. Entregados, por pedidos.fecha, atribuidos a pedidos.usuario_id.';

-- Permisos: el default privilege de PUBLIC no se puede sacar (ver mig 188), así
-- que cada función nueva tiene que revocarlo o `npm run check:permisos` se pone
-- rojo. El REVOKE necesita PUBLIC *y* anon: sacar sólo uno deja pasar al otro.
REVOKE ALL ON FUNCTION public.reporte_ventas_por_cliente(date, date, uuid, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reporte_ventas_por_cliente(date, date, uuid, bigint) TO authenticated;

-- ---- Verificación fail-closed, en la misma transacción --------------------
DO $verif$
DECLARE
  v_acl text;
BEGIN
  SELECT array_to_string(proacl, ',') INTO v_acl
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'reporte_ventas_por_cliente';

  -- proacl NULL = privilegios default = PUBLIC puede ejecutar. Es un fallo,
  -- no un "no hay nada que revisar".
  IF v_acl IS NULL THEN
    RAISE EXCEPTION 'reporte_ventas_por_cliente quedó con ACL default (PUBLIC ejecuta)';
  END IF;
  -- PUBLIC aparece como un elemento con grantee vacío: `=X/postgres`, al
  -- principio de la lista o después de una coma. Buscar `%=X/%` a secas daría
  -- falso positivo con `postgres=X/postgres`.
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
