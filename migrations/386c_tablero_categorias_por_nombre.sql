-- Tablero: categorías agrupadas por nombre (_tablero_cat_nombre) y el último monto > 0 en inactivos.
--
-- Se aplicó directo en prod (ledger 20261023000214, name 'tablero_categorias_por_nombre') sin pasar por el repo.
-- Este archivo es el SQL de supabase_migrations.schema_migrations.statements, sin
-- tocar (md5 363b0d5e12cb3cd922f02fc8430a79c2), para que el drift-check lo encuentre. El número 386x
-- lo ubica entre la 386 (2026-10-16) y la 387 (2026-10-26), que es cuando corrió.
-- El aislamiento de metas_cobertura_zona.zona_id lo arregla la 393.

CREATE OR REPLACE FUNCTION public._tablero_cat_nombre(p_nombre text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO 'public'
AS $$ SELECT upper(btrim(COALESCE(NULLIF(btrim(p_nombre), ''), 'Sin categoria'))) $$;

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
           _tablero_cat_nombre(COALESCE(c.nombre, pr.categoria)) AS cat_nombre
      FROM _tablero_ventas(v_sucs, v_desde, v_hasta) v
      JOIN pedido_items pi ON pi.pedido_id = v.pedido_id
      JOIN productos pr    ON pr.id = pi.producto_id
      LEFT JOIN categorias c ON c.id = pr.categoria_id
     WHERE p_zona_id IS NULL OR v.zona_id = p_zona_id
  ),
  g AS (
    SELECT cat_nombre,
           sum(subtotal) AS monto,
           sum(cantidad) FILTER (WHERE NOT COALESCE(es_bonificacion, false)) AS unidades,
           sum(cantidad) FILTER (WHERE COALESCE(es_bonificacion, false))     AS unidades_bonif,
           count(DISTINCT cliente_id) AS clientes
      FROM it GROUP BY cat_nombre
  ),
  t AS (SELECT COALESCE(sum(monto), 0) AS total FROM g)
  SELECT jsonb_build_object(
    'desde', v_desde, 'hasta', v_hasta, 'total', t.total,
    'clientes_compradores', (SELECT count(DISTINCT cliente_id) FROM it),
    'categorias', COALESCE(jsonb_agg(jsonb_build_object(
       'categoria_id', NULL, 'nombre', g.cat_nombre, 'monto', g.monto,
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
      LEFT JOIN categorias c  ON c.id = pr.categoria_id
      LEFT JOIN categorias sc ON sc.id = pr.subcategoria_id
      LEFT JOIN marcas m      ON m.id = pr.marca_id
     WHERE (p_zona_id IS NULL OR v.zona_id = p_zona_id)
       AND CASE WHEN p_categoria_nombre IS NOT NULL
                  THEN _tablero_cat_nombre(COALESCE(c.nombre, pr.categoria)) = _tablero_cat_nombre(p_categoria_nombre)
                ELSE pr.categoria_id = p_categoria_id
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
    'nombre', COALESCE(_tablero_cat_nombre(p_categoria_nombre), (SELECT nombre FROM categorias WHERE id = p_categoria_id), 'Sin categoria'),
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

REVOKE ALL ON FUNCTION public._tablero_cat_nombre(text) FROM PUBLIC, anon;

DO $$
DECLARE d text;
BEGIN
  d := pg_get_functiondef('public.tablero_clientes_inactivos(bigint, int, boolean)'::regprocedure);
  d := replace(d, '(array_agg(total ORDER BY fecha DESC, pedido_id DESC))[1]',
                  '(array_agg(total ORDER BY fecha DESC, pedido_id DESC) FILTER (WHERE total > 0))[1]');
  EXECUTE d;
END $$;
