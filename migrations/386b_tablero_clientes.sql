-- Tablero de ventas: metas_cobertura_zona, helpers _tablero_* y las RPCs tablero_*.
--
-- Se aplicó directo en prod (ledger 20261022234917, name 'tablero_clientes') sin pasar por el repo.
-- Este archivo es el SQL de supabase_migrations.schema_migrations.statements, sin
-- tocar (md5 44c622b377163b9cb595e12d8ddc108f), para que el drift-check lo encuentre. El número 386x
-- lo ubica entre la 386 (2026-10-16) y la 387 (2026-10-26), que es cuando corrió.
-- El aislamiento de metas_cobertura_zona.zona_id lo arregla la 393.

CREATE TABLE IF NOT EXISTS public.metas_cobertura_zona (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sucursal_id       bigint NOT NULL REFERENCES public.sucursales(id),
  zona_id           bigint NOT NULL REFERENCES public.zonas(id) ON DELETE CASCADE,
  periodo           date   NOT NULL CHECK (periodo = date_trunc('month', periodo)::date),
  objetivo_pct      numeric(5,2) NOT NULL CHECK (objetivo_pct > 0 AND objetivo_pct <= 100),
  objetivo_clientes integer CHECK (objetivo_clientes IS NULL OR objetivo_clientes >= 0),
  usuario_id        uuid,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (zona_id, periodo)
);
COMMENT ON TABLE public.metas_cobertura_zona IS
  'Objetivo mensual de cobertura (% de clientes de la zona que compran en el mes). Sin fila para un mes = rige el ultimo objetivo anterior. Se escribe solo con tablero_guardar_meta_cobertura(); se lee via tablero_cobertura().';
CREATE INDEX IF NOT EXISTS idx_metas_cobertura_zona_sucursal ON public.metas_cobertura_zona (sucursal_id);
ALTER TABLE public.metas_cobertura_zona ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public._tablero_sucursales(p_sucursal_id bigint)
RETURNS bigint[]
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_rol  text;
  v_asig bigint[];
  v_res  bigint[];
BEGIN
  IF auth.uid() IS NOT NULL THEN
    SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid() AND COALESCE(activo, true);
    IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
      RAISE EXCEPTION 'Acceso denegado: se requiere rol admin o encargado';
    END IF;
    SELECT array_agg(sucursal_id) INTO v_asig FROM usuario_sucursales WHERE usuario_id = auth.uid();
    IF v_asig IS NULL THEN
      RAISE EXCEPTION 'Acceso denegado: el usuario no tiene sucursales asignadas';
    END IF;
  END IF;

  IF p_sucursal_id IS NULL THEN
    SELECT array_agg(id) INTO v_res FROM sucursales
     WHERE activa AND (v_asig IS NULL OR id = ANY(v_asig));
  ELSE
    IF v_asig IS NOT NULL AND NOT (p_sucursal_id = ANY(v_asig)) THEN
      RAISE EXCEPTION 'Acceso denegado: la sucursal % no esta asignada al usuario', p_sucursal_id;
    END IF;
    v_res := ARRAY[p_sucursal_id];
  END IF;

  IF v_res IS NULL OR array_length(v_res, 1) IS NULL THEN
    RAISE EXCEPTION 'Acceso denegado: sin sucursales disponibles para el usuario';
  END IF;
  RETURN v_res;
END;
$$;

CREATE OR REPLACE FUNCTION public._tablero_hoy()
RETURNS date LANGUAGE sql STABLE SET search_path TO 'public'
AS $$ SELECT (now() AT TIME ZONE 'America/Argentina/Tucuman')::date $$;

CREATE OR REPLACE FUNCTION public._tablero_ventas(p_sucs bigint[], p_desde date, p_hasta date)
RETURNS TABLE (pedido_id bigint, cliente_id bigint, fecha date, total numeric, sucursal_id bigint, zona_id bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT pe.id, pe.cliente_id, pe.fecha, pe.total, pe.sucursal_id, c.zona_id
  FROM pedidos pe
  LEFT JOIN clientes c ON c.id = pe.cliente_id
  WHERE pe.estado = 'entregado'
    AND COALESCE(pe.canal, 'app') <> 'cambio'
    AND pe.tipo_factura IS DISTINCT FROM 'VB'
    AND pe.fecha BETWEEN p_desde AND p_hasta
    AND pe.sucursal_id = ANY(p_sucs)
$$;

CREATE OR REPLACE FUNCTION public.tablero_contexto()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_sucs bigint[] := _tablero_sucursales(NULL);
BEGIN
  RETURN jsonb_build_object(
    'usuario', (SELECT jsonb_build_object('id', id, 'nombre', nombre, 'email', email, 'rol', rol)
                  FROM perfiles WHERE id = auth.uid()),
    'hoy', _tablero_hoy(),
    'sucursales', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', id, 'nombre', nombre) ORDER BY id)
                              FROM sucursales WHERE id = ANY(v_sucs)), '[]'::jsonb),
    'zonas', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id', z.id, 'nombre', z.nombre, 'sucursal_id', z.sucursal_id,
               'preventista_id', pz.perfil_id, 'preventista', pf.nombre) ORDER BY z.sucursal_id, z.nombre)
        FROM zonas z
        LEFT JOIN preventista_zonas pz ON pz.zona_id = z.id
        LEFT JOIN perfiles pf ON pf.id = pz.perfil_id
       WHERE z.sucursal_id = ANY(v_sucs) AND COALESCE(z.activo, true)), '[]'::jsonb)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.tablero_kpis(p_sucursal_id bigint DEFAULT NULL, p_anio int DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_sucs  bigint[] := _tablero_sucursales(p_sucursal_id);
  v_hoy   date := _tablero_hoy();
  v_anio  int  := COALESCE(p_anio, extract(year FROM _tablero_hoy())::int);
  v_corte date;
  v_ini   date;
  v_mes   date;
  v_corte_ant date;
  r jsonb;
BEGIN
  v_ini   := make_date(v_anio, 1, 1);
  v_corte := LEAST(v_hoy, make_date(v_anio, 12, 31));
  v_mes   := date_trunc('month', v_corte)::date;
  v_corte_ant := (v_corte - interval '1 year')::date;

  WITH v AS (SELECT * FROM _tablero_ventas(v_sucs, (v_ini - interval '1 year')::date, v_corte)),
  base_cli AS (
    SELECT c.id FROM clientes c
     WHERE c.sucursal_id = ANY(v_sucs) AND COALESCE(c.activo, true) AND c.zona_id IS NOT NULL
  ),
  ult AS (
    SELECT pe.cliente_id, max(pe.fecha) AS ultima
      FROM pedidos pe
     WHERE pe.estado = 'entregado' AND COALESCE(pe.canal, 'app') <> 'cambio'
       AND pe.tipo_factura IS DISTINCT FROM 'VB' AND pe.sucursal_id = ANY(v_sucs)
       AND pe.fecha <= v_corte
     GROUP BY pe.cliente_id
  )
  SELECT jsonb_build_object(
    'anio', v_anio, 'corte', v_corte,
    'mes_total',      (SELECT COALESCE(sum(total), 0) FROM v WHERE fecha BETWEEN v_mes AND v_corte),
    'mes_pedidos',    (SELECT count(*) FROM v WHERE fecha BETWEEN v_mes AND v_corte),
    'mes_clientes',   (SELECT count(DISTINCT cliente_id) FROM v WHERE fecha BETWEEN v_mes AND v_corte),
    'mes_ant_total',  (SELECT COALESCE(sum(total), 0) FROM v
                        WHERE fecha BETWEEN (v_mes - interval '1 year')::date AND v_corte_ant),
    'anio_total',     (SELECT COALESCE(sum(total), 0) FROM v WHERE fecha BETWEEN v_ini AND v_corte),
    'anio_pedidos',   (SELECT count(*) FROM v WHERE fecha BETWEEN v_ini AND v_corte),
    'anio_clientes',  (SELECT count(DISTINCT cliente_id) FROM v WHERE fecha BETWEEN v_ini AND v_corte),
    'anio_ant_total', (SELECT COALESCE(sum(total), 0) FROM v
                        WHERE fecha BETWEEN (v_ini - interval '1 year')::date AND v_corte_ant),
    'clientes_cartera',     (SELECT count(*) FROM base_cli),
    'clientes_activos_30',  (SELECT count(*) FROM base_cli b JOIN ult u ON u.cliente_id = b.id
                              WHERE u.ultima > v_corte - 30),
    'clientes_inactivos_14',(SELECT count(*) FROM base_cli b JOIN ult u ON u.cliente_id = b.id
                              WHERE u.ultima < v_corte - 14),
    'clientes_nunca',       (SELECT count(*) FROM base_cli b LEFT JOIN ult u ON u.cliente_id = b.id
                              WHERE u.cliente_id IS NULL),
    'clientes_sin_zona',    (SELECT count(*) FROM clientes c
                              WHERE c.sucursal_id = ANY(v_sucs) AND COALESCE(c.activo, true) AND c.zona_id IS NULL)
  ) INTO r;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION public.tablero_facturacion_mensual(p_sucursal_id bigint DEFAULT NULL, p_anio int DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_sucs bigint[] := _tablero_sucursales(p_sucursal_id);
  v_anio int := COALESCE(p_anio, extract(year FROM _tablero_hoy())::int);
  r jsonb;
BEGIN
  WITH v AS (SELECT * FROM _tablero_ventas(v_sucs, make_date(v_anio - 1, 1, 1), make_date(v_anio, 12, 31))),
  m AS (
    SELECT g.mes,
           COALESCE(sum(v.total) FILTER (WHERE extract(year FROM v.fecha) = v_anio), 0)     AS total,
           count(v.pedido_id) FILTER (WHERE extract(year FROM v.fecha) = v_anio)            AS pedidos,
           count(DISTINCT v.cliente_id) FILTER (WHERE extract(year FROM v.fecha) = v_anio)  AS clientes,
           COALESCE(sum(v.total) FILTER (WHERE extract(year FROM v.fecha) = v_anio - 1), 0) AS total_ant
      FROM generate_series(1, 12) AS g(mes)
      LEFT JOIN v ON extract(month FROM v.fecha) = g.mes
     GROUP BY g.mes
  ),
  w AS (
    SELECT m.*, sum(total) OVER (ORDER BY mes) AS acumulado, sum(total_ant) OVER (ORDER BY mes) AS acumulado_ant
      FROM m
  )
  SELECT jsonb_build_object(
    'anio', v_anio,
    'meses', jsonb_agg(jsonb_build_object(
      'mes', mes, 'total', total, 'pedidos', pedidos, 'clientes', clientes,
      'ticket', CASE WHEN pedidos > 0 THEN round(total / pedidos, 2) ELSE 0 END,
      'total_ant', total_ant, 'acumulado', acumulado, 'acumulado_ant', acumulado_ant
    ) ORDER BY mes)
  ) INTO r FROM w;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION public.tablero_categorias(
  p_sucursal_id bigint DEFAULT NULL, p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL, p_zona_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_sucs  bigint[] := _tablero_sucursales(p_sucursal_id);
  v_hasta date := COALESCE(p_hasta, _tablero_hoy());
  v_desde date := COALESCE(p_desde, make_date(extract(year FROM COALESCE(p_hasta, _tablero_hoy()))::int, 1, 1));
  r jsonb;
BEGIN
  WITH it AS (
    SELECT v.cliente_id, pi.cantidad, pi.subtotal, pi.es_bonificacion,
           pr.categoria_id, COALESCE(c.nombre, NULLIF(btrim(pr.categoria), ''), 'Sin categoria') AS cat_nombre
      FROM _tablero_ventas(v_sucs, v_desde, v_hasta) v
      JOIN pedido_items pi ON pi.pedido_id = v.pedido_id
      JOIN productos pr    ON pr.id = pi.producto_id
      LEFT JOIN categorias c ON c.id = pr.categoria_id
     WHERE p_zona_id IS NULL OR v.zona_id = p_zona_id
  ),
  g AS (
    SELECT categoria_id, cat_nombre,
           sum(subtotal) AS monto,
           sum(cantidad) FILTER (WHERE NOT COALESCE(es_bonificacion, false)) AS unidades,
           sum(cantidad) FILTER (WHERE COALESCE(es_bonificacion, false))     AS unidades_bonif,
           count(DISTINCT cliente_id) AS clientes
      FROM it GROUP BY categoria_id, cat_nombre
  ),
  t AS (SELECT COALESCE(sum(monto), 0) AS total FROM g)
  SELECT jsonb_build_object(
    'desde', v_desde, 'hasta', v_hasta, 'total', t.total,
    'clientes_compradores', (SELECT count(DISTINCT cliente_id) FROM it),
    'categorias', COALESCE(jsonb_agg(jsonb_build_object(
       'categoria_id', g.categoria_id, 'nombre', g.cat_nombre, 'monto', g.monto,
       'unidades', COALESCE(g.unidades, 0), 'unidades_bonif', COALESCE(g.unidades_bonif, 0),
       'clientes', g.clientes,
       'pct', CASE WHEN t.total > 0 THEN round(100 * g.monto / t.total, 2) ELSE 0 END
     ) ORDER BY g.monto DESC) FILTER (WHERE g.cat_nombre IS NOT NULL), '[]'::jsonb)
  ) INTO r
  FROM t LEFT JOIN g ON true
  GROUP BY t.total;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION public.tablero_productos_categoria(
  p_categoria_id uuid, p_categoria_nombre text DEFAULT NULL,
  p_sucursal_id bigint DEFAULT NULL, p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL, p_zona_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_sucs  bigint[] := _tablero_sucursales(p_sucursal_id);
  v_hasta date := COALESCE(p_hasta, _tablero_hoy());
  v_desde date := COALESCE(p_desde, make_date(extract(year FROM COALESCE(p_hasta, _tablero_hoy()))::int, 1, 1));
  r jsonb;
BEGIN
  WITH it AS (
    SELECT v.cliente_id, v.fecha, pi.producto_id, pi.cantidad, pi.subtotal, pi.es_bonificacion,
           pr.nombre AS producto, pr.codigo, sc.nombre AS subcategoria, m.nombre AS marca
      FROM _tablero_ventas(v_sucs, v_desde, v_hasta) v
      JOIN pedido_items pi ON pi.pedido_id = v.pedido_id
      JOIN productos pr    ON pr.id = pi.producto_id
      LEFT JOIN categorias sc ON sc.id = pr.subcategoria_id
      LEFT JOIN marcas m      ON m.id = pr.marca_id
     WHERE (p_zona_id IS NULL OR v.zona_id = p_zona_id)
       AND CASE WHEN p_categoria_id IS NOT NULL THEN pr.categoria_id = p_categoria_id
                ELSE pr.categoria_id IS NULL
                     AND COALESCE(NULLIF(btrim(pr.categoria), ''), 'Sin categoria') = COALESCE(p_categoria_nombre, 'Sin categoria')
           END
  ),
  pc AS (
    SELECT producto_id, cliente_id, sum(subtotal) AS monto, sum(cantidad) AS unidades, max(fecha) AS ultima
      FROM it GROUP BY producto_id, cliente_id
  ),
  top_cli AS (
    SELECT producto_id, jsonb_agg(jsonb_build_object(
             'cliente_id', x.cliente_id, 'nombre', x.nombre, 'zona', x.zona,
             'monto', x.monto, 'unidades', x.unidades, 'ultima', x.ultima) ORDER BY x.monto DESC) AS clientes
      FROM (
        SELECT pc.*, COALESCE(NULLIF(btrim(c.nombre_fantasia), ''), c.razon_social) AS nombre,
               COALESCE(z.nombre, 'SIN ZONA') AS zona,
               row_number() OVER (PARTITION BY pc.producto_id ORDER BY pc.monto DESC) AS rn
          FROM pc JOIN clientes c ON c.id = pc.cliente_id LEFT JOIN zonas z ON z.id = c.zona_id
      ) x
     WHERE x.rn <= 15
     GROUP BY producto_id
  ),
  g AS (
    SELECT producto_id, producto, codigo, subcategoria, marca,
           sum(subtotal) AS monto,
           sum(cantidad) FILTER (WHERE NOT COALESCE(es_bonificacion, false)) AS unidades,
           count(DISTINCT cliente_id) AS clientes,
           max(fecha) AS ultima_venta
      FROM it GROUP BY producto_id, producto, codigo, subcategoria, marca
  )
  SELECT jsonb_build_object(
    'desde', v_desde, 'hasta', v_hasta,
    'categoria_id', p_categoria_id,
    'nombre', COALESCE((SELECT nombre FROM categorias WHERE id = p_categoria_id), p_categoria_nombre, 'Sin categoria'),
    'total', (SELECT COALESCE(sum(monto), 0) FROM g),
    'clientes', (SELECT count(DISTINCT cliente_id) FROM it),
    'productos', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'producto_id', g.producto_id, 'nombre', g.producto, 'codigo', g.codigo,
               'subcategoria', g.subcategoria, 'marca', g.marca, 'monto', g.monto,
               'unidades', COALESCE(g.unidades, 0), 'clientes', g.clientes, 'ultima_venta', g.ultima_venta,
               'top_clientes', COALESCE(tc.clientes, '[]'::jsonb)) ORDER BY g.monto DESC)
        FROM g LEFT JOIN top_cli tc ON tc.producto_id = g.producto_id), '[]'::jsonb)
  ) INTO r;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION public.tablero_top_clientes_zona(
  p_sucursal_id bigint DEFAULT NULL, p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL,
  p_limit int DEFAULT 10, p_dias_alerta int DEFAULT 14)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_sucs  bigint[] := _tablero_sucursales(p_sucursal_id);
  v_hoy   date := _tablero_hoy();
  v_hasta date := COALESCE(p_hasta, _tablero_hoy());
  v_desde date := COALESCE(p_desde, make_date(extract(year FROM COALESCE(p_hasta, _tablero_hoy()))::int, 1, 1));
  r jsonb;
BEGIN
  WITH cli AS (
    SELECT c.id, c.zona_id, c.codigo, c.telefono,
           COALESCE(NULLIF(btrim(c.nombre_fantasia), ''), c.razon_social) AS nombre
      FROM clientes c
     WHERE c.sucursal_id = ANY(v_sucs) AND COALESCE(c.activo, true) AND c.zona_id IS NOT NULL
  ),
  per AS (
    SELECT cliente_id, sum(total) AS total, count(*) AS pedidos
      FROM _tablero_ventas(v_sucs, v_desde, v_hasta) GROUP BY cliente_id
  ),
  ult AS (
    SELECT cliente_id, max(fecha) AS ultima
      FROM _tablero_ventas(v_sucs, '2000-01-01', v_hoy) GROUP BY cliente_id
  ),
  rk AS (
    SELECT cli.*, per.total, per.pedidos, ult.ultima,
           (v_hoy - ult.ultima) AS dias,
           row_number() OVER (PARTITION BY cli.zona_id ORDER BY per.total DESC NULLS LAST, cli.nombre) AS rn
      FROM cli JOIN per ON per.cliente_id = cli.id
      LEFT JOIN ult ON ult.cliente_id = cli.id
  ),
  zs AS (
    SELECT z.id, z.nombre, z.sucursal_id, pf.nombre AS preventista,
           (SELECT count(*) FROM cli WHERE cli.zona_id = z.id) AS clientes_zona,
           (SELECT count(*) FROM rk WHERE rk.zona_id = z.id) AS compradores,
           (SELECT COALESCE(sum(total), 0) FROM rk WHERE rk.zona_id = z.id) AS total,
           (SELECT count(*) FROM cli LEFT JOIN ult ON ult.cliente_id = cli.id
             WHERE cli.zona_id = z.id AND (ult.ultima IS NULL OR v_hoy - ult.ultima > p_dias_alerta)) AS inactivos
      FROM zonas z
      LEFT JOIN preventista_zonas pz ON pz.zona_id = z.id
      LEFT JOIN perfiles pf ON pf.id = pz.perfil_id
     WHERE z.sucursal_id = ANY(v_sucs) AND COALESCE(z.activo, true)
  )
  SELECT jsonb_build_object(
    'desde', v_desde, 'hasta', v_hasta, 'hoy', v_hoy, 'dias_alerta', p_dias_alerta,
    'zonas', COALESCE(jsonb_agg(jsonb_build_object(
      'zona_id', zs.id, 'zona', zs.nombre, 'sucursal_id', zs.sucursal_id, 'preventista', zs.preventista,
      'clientes_zona', zs.clientes_zona, 'compradores', zs.compradores, 'total', zs.total, 'inactivos', zs.inactivos,
      'top', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                 'rank', rk.rn, 'cliente_id', rk.id, 'codigo', rk.codigo, 'nombre', rk.nombre,
                 'telefono', rk.telefono, 'total', rk.total, 'pedidos', rk.pedidos,
                 'ticket', round(rk.total / NULLIF(rk.pedidos, 0), 2),
                 'ultima_compra', rk.ultima, 'dias_sin_compra', rk.dias,
                 'alerta', (rk.ultima IS NULL OR rk.dias > p_dias_alerta)) ORDER BY rk.rn)
          FROM rk WHERE rk.zona_id = zs.id AND rk.rn <= p_limit), '[]'::jsonb)
    ) ORDER BY zs.total DESC), '[]'::jsonb)
  ) INTO r FROM zs;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION public.tablero_clientes_inactivos(
  p_sucursal_id bigint DEFAULT NULL, p_dias int DEFAULT 14, p_incluir_nunca boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_sucs bigint[] := _tablero_sucursales(p_sucursal_id);
  v_hoy  date := _tablero_hoy();
  r jsonb;
BEGIN
  WITH v AS (SELECT * FROM _tablero_ventas(v_sucs, '2000-01-01', v_hoy)),
  agg AS (
    SELECT cliente_id, max(fecha) AS ultima, count(*) AS pedidos_hist, sum(total) AS total_hist,
           COALESCE(sum(total) FILTER (WHERE fecha > v_hoy - 180), 0) / 6.0 AS promedio_mensual_6m,
           (array_agg(total ORDER BY fecha DESC, pedido_id DESC))[1] AS ultimo_monto
      FROM v GROUP BY cliente_id
  ),
  vis AS (
    SELECT cliente_id, max(created_at) AS ultima_visita
      FROM visitas_cliente WHERE sucursal_id = ANY(v_sucs) GROUP BY cliente_id
  ),
  x AS (
    SELECT c.id, c.codigo, COALESCE(NULLIF(btrim(c.nombre_fantasia), ''), c.razon_social) AS nombre,
           c.direccion, c.telefono, c.saldo_cuenta, c.zona_id, z.nombre AS zona, c.sucursal_id,
           COALESCE(pc.nombre, pz_pf.nombre) AS preventista,
           COALESCE(c.preventista_id, pz.perfil_id) AS preventista_id,
           a.ultima, (v_hoy - a.ultima) AS dias, a.pedidos_hist, a.total_hist,
           round(a.promedio_mensual_6m, 2) AS promedio_mensual_6m, a.ultimo_monto,
           vis.ultima_visita
      FROM clientes c
      JOIN zonas z ON z.id = c.zona_id
      LEFT JOIN agg a ON a.cliente_id = c.id
      LEFT JOIN vis ON vis.cliente_id = c.id
      LEFT JOIN perfiles pc ON pc.id = c.preventista_id
      LEFT JOIN preventista_zonas pz ON pz.zona_id = c.zona_id
      LEFT JOIN perfiles pz_pf ON pz_pf.id = pz.perfil_id
     WHERE c.sucursal_id = ANY(v_sucs) AND COALESCE(c.activo, true)
       AND ((a.ultima IS NOT NULL AND v_hoy - a.ultima > p_dias) OR (p_incluir_nunca AND a.ultima IS NULL))
  )
  SELECT jsonb_build_object(
    'hoy', v_hoy, 'dias', p_dias,
    'total', count(*),
    'nunca_compraron', count(*) FILTER (WHERE ultima IS NULL),
    'venta_en_riesgo_mensual', COALESCE(sum(promedio_mensual_6m), 0),
    'clientes', COALESCE(jsonb_agg(jsonb_build_object(
      'cliente_id', id, 'codigo', codigo, 'nombre', nombre, 'direccion', direccion, 'telefono', telefono,
      'saldo_cuenta', saldo_cuenta, 'zona_id', zona_id, 'zona', zona, 'sucursal_id', sucursal_id,
      'preventista_id', preventista_id, 'preventista', preventista,
      'ultima_compra', ultima, 'dias_sin_compra', dias, 'pedidos_hist', COALESCE(pedidos_hist, 0),
      'total_hist', COALESCE(total_hist, 0), 'promedio_mensual_6m', COALESCE(promedio_mensual_6m, 0),
      'ultimo_monto', ultimo_monto, 'ultima_visita', ultima_visita
    ) ORDER BY (ultima IS NULL), promedio_mensual_6m DESC NULLS LAST, dias DESC), '[]'::jsonb)
  ) INTO r FROM x;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION public.tablero_cobertura(p_sucursal_id bigint DEFAULT NULL, p_periodo date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_sucs bigint[] := _tablero_sucursales(p_sucursal_id);
  v_hoy  date := _tablero_hoy();
  v_ini  date := date_trunc('month', COALESCE(p_periodo, _tablero_hoy()))::date;
  v_fin  date;
  v_corte date;
  r jsonb;
BEGIN
  v_fin   := (v_ini + interval '1 month - 1 day')::date;
  v_corte := LEAST(v_fin, v_hoy);

  WITH cli AS (
    SELECT c.id, c.zona_id FROM clientes c
     WHERE c.sucursal_id = ANY(v_sucs) AND COALESCE(c.activo, true) AND c.zona_id IS NOT NULL
  ),
  v AS (SELECT * FROM _tablero_ventas(v_sucs, v_ini, v_fin) WHERE zona_id IS NOT NULL),
  vis AS (
    SELECT DISTINCT vc.cliente_id FROM visitas_cliente vc
     WHERE vc.sucursal_id = ANY(v_sucs)
       AND (vc.created_at AT TIME ZONE 'America/Argentina/Tucuman')::date BETWEEN v_ini AND v_fin
  ),
  zs AS (
    SELECT z.id, z.nombre, z.sucursal_id, pf.nombre AS preventista,
           (SELECT count(*) FROM cli WHERE cli.zona_id = z.id) AS clientes,
           (SELECT count(DISTINCT v.cliente_id) FROM v JOIN cli ON cli.id = v.cliente_id WHERE cli.zona_id = z.id) AS compradores,
           (SELECT COALESCE(sum(v.total), 0) FROM v WHERE v.zona_id = z.id) AS facturacion,
           (SELECT count(*) FROM vis JOIN cli ON cli.id = vis.cliente_id WHERE cli.zona_id = z.id) AS visitados,
           mt.objetivo_pct, mt.objetivo_clientes, mt.periodo AS objetivo_desde
      FROM zonas z
      LEFT JOIN preventista_zonas pz ON pz.zona_id = z.id
      LEFT JOIN perfiles pf ON pf.id = pz.perfil_id
      LEFT JOIN LATERAL (
        SELECT m.objetivo_pct, m.objetivo_clientes, m.periodo FROM metas_cobertura_zona m
         WHERE m.zona_id = z.id AND m.periodo <= v_ini ORDER BY m.periodo DESC LIMIT 1
      ) mt ON true
     WHERE z.sucursal_id = ANY(v_sucs) AND COALESCE(z.activo, true)
  ),
  calc AS (
    SELECT zs.*,
           CASE WHEN clientes > 0 THEN round(100.0 * compradores / clientes, 1) ELSE 0 END AS cobertura_pct,
           COALESCE(objetivo_clientes, CASE WHEN objetivo_pct IS NOT NULL THEN ceil(clientes * objetivo_pct / 100.0)::int END) AS meta_clientes
      FROM zs
  )
  SELECT jsonb_build_object(
    'periodo', v_ini, 'fin', v_fin, 'corte', v_corte,
    'avance_mes_pct', round(100.0 * (v_corte - v_ini + 1) / (v_fin - v_ini + 1), 1),
    'totales', jsonb_build_object(
       'clientes', COALESCE(sum(clientes), 0), 'compradores', COALESCE(sum(compradores), 0),
       'facturacion', COALESCE(sum(facturacion), 0),
       'cobertura_pct', CASE WHEN sum(clientes) > 0 THEN round(100.0 * sum(compradores) / sum(clientes), 1) ELSE 0 END,
       'meta_clientes', sum(meta_clientes)),
    'zonas', COALESCE(jsonb_agg(jsonb_build_object(
      'zona_id', id, 'zona', nombre, 'sucursal_id', sucursal_id, 'preventista', preventista,
      'clientes', clientes, 'compradores', compradores, 'visitados', visitados, 'facturacion', facturacion,
      'cobertura_pct', cobertura_pct, 'objetivo_pct', objetivo_pct, 'objetivo_clientes', objetivo_clientes,
      'objetivo_desde', objetivo_desde, 'meta_clientes', meta_clientes,
      'faltan', GREATEST(COALESCE(meta_clientes, 0) - compradores, 0),
      'estado', CASE WHEN meta_clientes IS NULL THEN 'sin_objetivo'
                     WHEN compradores >= meta_clientes THEN 'cumplido'
                     WHEN compradores >= 0.8 * meta_clientes THEN 'cerca'
                     ELSE 'lejos' END
    ) ORDER BY sucursal_id, nombre), '[]'::jsonb)
  ) INTO r FROM calc;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION public.tablero_guardar_meta_cobertura(
  p_zona_id bigint, p_periodo date, p_objetivo_pct numeric, p_objetivo_clientes int DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_suc  bigint;
  v_rol  text;
  v_per  date := date_trunc('month', p_periodo)::date;
  v_row  metas_cobertura_zona;
BEGIN
  SELECT sucursal_id INTO v_suc FROM zonas WHERE id = p_zona_id;
  IF v_suc IS NULL THEN RAISE EXCEPTION 'Zona % inexistente', p_zona_id; END IF;
  PERFORM _tablero_sucursales(v_suc);
  IF auth.uid() IS NOT NULL THEN
    SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();
    IF v_rol <> 'admin' THEN RAISE EXCEPTION 'Acceso denegado: solo un admin define objetivos'; END IF;
  END IF;
  IF p_objetivo_pct IS NULL OR p_objetivo_pct <= 0 OR p_objetivo_pct > 100 THEN
    RAISE EXCEPTION 'El objetivo debe estar entre 1 y 100%%';
  END IF;

  INSERT INTO metas_cobertura_zona (sucursal_id, zona_id, periodo, objetivo_pct, objetivo_clientes, usuario_id)
  VALUES (v_suc, p_zona_id, v_per, p_objetivo_pct, p_objetivo_clientes, auth.uid())
  ON CONFLICT (zona_id, periodo) DO UPDATE
     SET objetivo_pct = EXCLUDED.objetivo_pct, objetivo_clientes = EXCLUDED.objetivo_clientes,
         usuario_id = EXCLUDED.usuario_id, updated_at = now()
  RETURNING * INTO v_row;
  RETURN to_jsonb(v_row);
END;
$$;

CREATE OR REPLACE FUNCTION public.tablero_buscar_clientes(p_q text, p_sucursal_id bigint DEFAULT NULL, p_limit int DEFAULT 20)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_sucs bigint[] := _tablero_sucursales(p_sucursal_id);
  v_q    text := lower(f_unaccent(btrim(COALESCE(p_q, ''))));
BEGIN
  IF length(v_q) < 2 THEN RETURN '[]'::jsonb; END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(x ORDER BY x->>'nombre')
      FROM (
        SELECT jsonb_build_object('cliente_id', c.id, 'codigo', c.codigo,
                 'nombre', COALESCE(NULLIF(btrim(c.nombre_fantasia), ''), c.razon_social),
                 'razon_social', c.razon_social, 'zona', COALESCE(z.nombre, 'SIN ZONA'),
                 'direccion', c.direccion, 'activo', COALESCE(c.activo, true)) AS x
          FROM clientes c LEFT JOIN zonas z ON z.id = c.zona_id
         WHERE c.sucursal_id = ANY(v_sucs)
           AND (lower(f_unaccent(COALESCE(c.nombre_fantasia, ''))) LIKE '%' || v_q || '%'
             OR lower(f_unaccent(COALESCE(c.razon_social, ''))) LIKE '%' || v_q || '%'
             OR c.codigo::text = v_q
             OR c.cuit = v_q)
         LIMIT p_limit
      ) s), '[]'::jsonb);
END;
$$;

CREATE OR REPLACE FUNCTION public.tablero_ficha_cliente(p_cliente_id bigint)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_suc  bigint;
  v_sucs bigint[];
  v_hoy  date := _tablero_hoy();
  v_ini12 date := (date_trunc('month', _tablero_hoy()) - interval '11 months')::date;
  r jsonb;
BEGIN
  SELECT sucursal_id INTO v_suc FROM clientes WHERE id = p_cliente_id;
  IF v_suc IS NULL THEN RAISE EXCEPTION 'Cliente % inexistente', p_cliente_id; END IF;
  v_sucs := _tablero_sucursales(v_suc);

  WITH v AS (SELECT * FROM _tablero_ventas(v_sucs, '2000-01-01', v_hoy) WHERE cliente_id = p_cliente_id),
  it AS (
    SELECT v.fecha, pi.producto_id, pi.cantidad, pi.subtotal, pi.es_bonificacion,
           pr.nombre AS producto, pr.categoria_id,
           COALESCE(cat.nombre, NULLIF(btrim(pr.categoria), ''), 'Sin categoria') AS categoria
      FROM v JOIN pedido_items pi ON pi.pedido_id = v.pedido_id
      JOIN productos pr ON pr.id = pi.producto_id
      LEFT JOIN categorias cat ON cat.id = pr.categoria_id
     WHERE v.fecha >= v_ini12
  ),
  gaps AS (
    SELECT fecha - lag(fecha) OVER (ORDER BY fecha) AS gap
      FROM (SELECT DISTINCT fecha FROM v) d
  )
  SELECT jsonb_build_object(
    'hoy', v_hoy,
    'cliente', (
      SELECT jsonb_build_object(
        'id', c.id, 'codigo', c.codigo, 'razon_social', c.razon_social, 'nombre_fantasia', c.nombre_fantasia,
        'cuit', c.cuit, 'direccion', c.direccion, 'telefono', c.telefono, 'contacto', c.contacto,
        'rubro', c.rubro, 'horarios_atencion', c.horarios_atencion, 'dias_atencion', c.dias_atencion,
        'notas', c.notas, 'activo', COALESCE(c.activo, true), 'latitud', c.latitud, 'longitud', c.longitud,
        'limite_credito', c.limite_credito, 'saldo_cuenta', c.saldo_cuenta, 'dias_credito', c.dias_credito,
        'zona_id', c.zona_id, 'zona', z.nombre, 'sucursal', s.nombre, 'alta', c.created_at,
        'preventista', COALESCE(pc.nombre, pzf.nombre))
      FROM clientes c
      LEFT JOIN zonas z ON z.id = c.zona_id
      LEFT JOIN sucursales s ON s.id = c.sucursal_id
      LEFT JOIN perfiles pc ON pc.id = c.preventista_id
      LEFT JOIN preventista_zonas pz ON pz.zona_id = c.zona_id
      LEFT JOIN perfiles pzf ON pzf.id = pz.perfil_id
      WHERE c.id = p_cliente_id),
    'resumen', jsonb_build_object(
      'total_hist',    (SELECT COALESCE(sum(total), 0) FROM v),
      'pedidos_hist',  (SELECT count(*) FROM v),
      'total_12m',     (SELECT COALESCE(sum(total), 0) FROM v WHERE fecha >= v_ini12),
      'total_anio',    (SELECT COALESCE(sum(total), 0) FROM v WHERE fecha >= date_trunc('year', v_hoy)::date),
      'total_mes',     (SELECT COALESCE(sum(total), 0) FROM v WHERE fecha >= date_trunc('month', v_hoy)::date),
      'ticket',        (SELECT round(avg(total), 2) FROM v),
      'primera_compra',(SELECT min(fecha) FROM v),
      'ultima_compra', (SELECT max(fecha) FROM v),
      'dias_sin_compra', (SELECT v_hoy - max(fecha) FROM v),
      'frecuencia_dias', (SELECT round(avg(gap), 1) FROM gaps WHERE gap IS NOT NULL),
      'visitas_30d',   (SELECT count(*) FROM visitas_cliente WHERE cliente_id = p_cliente_id AND created_at > now() - interval '30 days')),
    'por_mes', (
      SELECT jsonb_agg(jsonb_build_object('mes', to_char(g.m, 'YYYY-MM'),
               'total', COALESCE((SELECT sum(total) FROM v WHERE date_trunc('month', v.fecha) = g.m), 0),
               'pedidos', (SELECT count(*) FROM v WHERE date_trunc('month', v.fecha) = g.m)) ORDER BY g.m)
        FROM generate_series(v_ini12::timestamp, date_trunc('month', v_hoy)::timestamp, interval '1 month') AS g(m)),
    'categorias', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('categoria_id', categoria_id, 'nombre', categoria,
               'monto', monto, 'unidades', unidades, 'pct', round(100 * monto / NULLIF(t, 0), 1)) ORDER BY monto DESC)
        FROM (SELECT categoria_id, categoria, sum(subtotal) AS monto, sum(cantidad) AS unidades,
                     sum(sum(subtotal)) OVER () AS t
                FROM it GROUP BY categoria_id, categoria) q), '[]'::jsonb),
    'productos', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('producto_id', producto_id, 'nombre', producto, 'categoria', categoria,
               'monto', monto, 'unidades', unidades, 'veces', veces, 'ultima', ultima) ORDER BY monto DESC)
        FROM (SELECT producto_id, producto, categoria, sum(subtotal) AS monto,
                     sum(cantidad) FILTER (WHERE NOT COALESCE(es_bonificacion, false)) AS unidades,
                     count(DISTINCT fecha) AS veces, max(fecha) AS ultima
                FROM it GROUP BY producto_id, producto, categoria
               ORDER BY sum(subtotal) DESC LIMIT 40) q), '[]'::jsonb),
    'pedidos', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('id', pe.id, 'fecha', pe.fecha, 'estado', pe.estado, 'total', pe.total,
               'estado_pago', pe.estado_pago, 'monto_pagado', pe.monto_pagado, 'tipo_factura', pe.tipo_factura,
               'items', (SELECT count(*) FROM pedido_items pi WHERE pi.pedido_id = pe.id)) ORDER BY pe.fecha DESC, pe.id DESC)
        FROM (SELECT * FROM pedidos WHERE cliente_id = p_cliente_id ORDER BY fecha DESC, id DESC LIMIT 20) pe), '[]'::jsonb),
    'visitas', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('fecha', vc.created_at, 'preventista', pf.nombre, 'gps', vc.gps_status) ORDER BY vc.created_at DESC)
        FROM (SELECT * FROM visitas_cliente WHERE cliente_id = p_cliente_id ORDER BY created_at DESC LIMIT 20) vc
        LEFT JOIN perfiles pf ON pf.id = vc.preventista_id), '[]'::jsonb),
    'pagos', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('fecha', COALESCE(pg.fecha, pg.created_at::date), 'monto', pg.monto,
               'forma_pago', pg.forma_pago, 'pedido_id', pg.pedido_id) ORDER BY pg.created_at DESC)
        FROM (SELECT * FROM pagos WHERE cliente_id = p_cliente_id ORDER BY created_at DESC LIMIT 15) pg), '[]'::jsonb)
  ) INTO r;
  RETURN r;
END;
$$;

REVOKE ALL ON FUNCTION public._tablero_sucursales(bigint)             FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._tablero_ventas(bigint[], date, date)   FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._tablero_hoy()                          FROM PUBLIC, anon;
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'tablero_contexto()',
    'tablero_kpis(bigint, int)',
    'tablero_facturacion_mensual(bigint, int)',
    'tablero_categorias(bigint, date, date, bigint)',
    'tablero_productos_categoria(uuid, text, bigint, date, date, bigint)',
    'tablero_top_clientes_zona(bigint, date, date, int, int)',
    'tablero_clientes_inactivos(bigint, int, boolean)',
    'tablero_cobertura(bigint, date)',
    'tablero_guardar_meta_cobertura(bigint, date, numeric, int)',
    'tablero_buscar_clientes(text, bigint, int)',
    'tablero_ficha_cliente(bigint)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', f);
  END LOOP;
END $$;
REVOKE ALL ON TABLE public.metas_cobertura_zona FROM anon, authenticated;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
                  WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'pedidos') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.pedidos;
  END IF;
END $$;
