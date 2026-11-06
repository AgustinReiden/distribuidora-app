-- Ensayo de la migración de reportes de #1472 (tarjeta 5 de #1477): los rankings del gerencial
-- van por id, un pedido sin venta no es un pedido, y la Red es `_sucursales_red()`.
--
-- El antes y después contra los datos de prod (todo número que no es de estos arreglos da
-- igual) está adentro de la migración. Acá se prueba con fixtures propios, en un único DO que
-- termina siempre en una excepción (no deja rastro salvo valores de secuencia):
--
--   L1 · Dos clientes que se llaman igual, con distinta razón social, son dos filas de
--        top_clientes, cada una con su cliente_id y su razón social.
--   E2 · Un pedido sin venta (sin líneas, total 0) cuenta como pedido, como en las otras ~28
--        funciones que cuentan pedidos de venta (la 468 revirtió el REP-F-2 de la 463d):
--        kpis.pedidos = Σ vendedores.pedidos + los pedidos sin líneas, da lo mismo que
--        reporte_ventas_por_cliente y que su mes, y cuenta en los pedidos de su cliente.
--   L3 · top_productos va por producto: trae producto_id y la sucursal.
--   L4 · reporte_combos y reporte_combos_rotacion corren para el servidor (sin usuario) y dan
--        la Red entera.
--   L5 · Las seis funciones de la Red llaman a _sucursales_red(), y sus EXECUTE no cambiaron.
--   E1 · _tablero_sucursales(NULL) da _sucursales_red() para el admin y para el servidor, y
--        comision_regla_alcanzable(NULL) es "el admin tiene todas las activas" (el servidor no).
--
-- L* falla sin la 463d; E1 pasa con y sin ella; E2 es lo de antes de la 463d y lo de después
-- de la 468. Con las dos aplicadas tiene que dar 'ENSAYO OK'.
--
-- Fixtures: un admin activo con al menos una sucursal activa asignada. El resto nace en el
-- ensayo, con pedidos de hoy por montos que los ponen primeros en el ranking del día.

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_adm    uuid;
  v_hoy    date := public._tablero_hoy();
  v_prod   bigint;
  v_c1     bigint;
  v_c2     bigint;
  v_c0     bigint;
  v_p1     bigint;
  v_p2     bigint;
  v_p0     bigint;
  v_res    jsonb;
  v_j      jsonb;
  v_m      jsonb;
  v_n      numeric;
  v_txt    text;
  v_fallas text[] := '{}';
  v_f      record;
BEGIN
 BEGIN
  -- El admin con más sucursales activas, y la primera de ellas.
  SELECT us.usuario_id INTO v_adm
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND COALESCE(pf.activo, true)
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   GROUP BY us.usuario_id
   ORDER BY count(*) DESC, us.usuario_id
   LIMIT 1;
  SELECT min(us.sucursal_id) INTO v_suc
    FROM usuario_sucursales us JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   WHERE us.usuario_id = v_adm;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: ningún admin activo con una sucursal activa';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1472', 1000000, 1000, 1, v_suc) RETURNING id INTO v_prod;
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ ensayo 1472 Pérez', 'ZZ Kiosco 1472', 'Ensayo 1472', v_suc) RETURNING id INTO v_c1;
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ ensayo 1472 Gómez', 'ZZ Kiosco 1472', 'Ensayo 1472', v_suc) RETURNING id INTO v_c2;
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ ensayo 1472 Cero', 'ZZ Cero 1472', 'Ensayo 1472', v_suc) RETURNING id INTO v_c0;

  -- Dos boletas de $50 M y $45 M (más que cualquier cliente real en un día) y una sin venta.
  v_res := public.crear_pedido_completo(
    v_c1, 50000000, v_adm,
    jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 50, 'precio_unitario', 1000000)),
    'ensayo 1472', 'efectivo', 'pendiente', v_hoy);
  v_p1 := (v_res->>'pedido_id')::bigint;
  v_res := public.crear_pedido_completo(
    v_c2, 45000000, v_adm,
    jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 45, 'precio_unitario', 1000000)),
    'ensayo 1472', 'efectivo', 'pendiente', v_hoy);
  v_p2 := (v_res->>'pedido_id')::bigint;
  IF v_p1 IS NULL OR v_p2 IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · no se pudieron crear los pedidos: %', v_res;
  END IF;
  INSERT INTO public.pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, canal)
  VALUES (v_c0, v_suc, v_adm, 0, 'pendiente', v_hoy, 'app') RETURNING id INTO v_p0;

  -- Con "todos" (p_incluir_no_entregados) para que entren los pendientes de hoy.
  v_j := public.reporte_gerencial(v_suc, v_hoy, v_hoy, true, false);

  -- L1
  IF (SELECT count(*) FROM jsonb_array_elements(v_j->'top_clientes') e
       WHERE (e->>'cliente_id')::bigint IN (v_c1, v_c2)) <> 2
     OR (v_j->'top_clientes'->0->>'cliente_id')::bigint IS DISTINCT FROM v_c1
     OR (v_j->'top_clientes'->0->>'razon_social') IS DISTINCT FROM 'ZZ ensayo 1472 Pérez'
     OR (v_j->'top_clientes'->0->>'venta')::numeric IS DISTINCT FROM 50000000
     OR (v_j->'top_clientes'->1->>'cliente_id')::bigint IS DISTINCT FROM v_c2
     OR (v_j->'top_clientes'->1->>'venta')::numeric IS DISTINCT FROM 45000000 THEN
    v_fallas := v_fallas || format('L1 los dos "ZZ Kiosco 1472" no son dos filas por id: %s', v_j->'top_clientes');
  END IF;

  -- E2
  v_n := (SELECT COALESCE(sum((e->>'pedidos')::numeric), 0) FROM jsonb_array_elements(v_j->'vendedores') e)
       + (SELECT count(*) FROM pedidos p
           WHERE p.sucursal_id = v_suc AND p.fecha = v_hoy AND p.canal <> 'cambio' AND p.tipo_factura IS DISTINCT FROM 'VB'
             AND p.estado IN ('entregado','asignado','pendiente','en_preparacion')
             AND NOT EXISTS (SELECT 1 FROM pedido_items pi WHERE pi.pedido_id = p.id));
  IF (v_j->'kpis'->>'pedidos')::numeric IS DISTINCT FROM v_n THEN
    v_fallas := v_fallas || format('E2 kpis.pedidos %s <> Σ vendedores.pedidos + sin líneas %s', v_j->'kpis'->>'pedidos', v_n);
  END IF;
  v_res := public.reporte_gerencial(v_suc, v_hoy, v_hoy, false, false);
  v_m := public.reporte_ventas_por_cliente(v_hoy, v_hoy, NULL, v_suc);
  IF (v_m->'totales'->>'pedidos')::numeric IS DISTINCT FROM (v_res->'kpis'->>'pedidos')::numeric THEN
    v_fallas := v_fallas || format('E2 pedidos por cliente %s <> gerencial %s', v_m->'totales'->>'pedidos', v_res->'kpis'->>'pedidos');
  END IF;
  IF (v_j->'kpis'->>'ticket')::numeric IS DISTINCT FROM
     round((v_j->'kpis'->>'venta')::numeric / NULLIF((v_j->'kpis'->>'pedidos')::numeric, 0)) THEN
    v_fallas := v_fallas || format('E2 el ticket %s no es venta / pedidos (%s / %s)',
      v_j->'kpis'->>'ticket', v_j->'kpis'->>'venta', v_j->'kpis'->>'pedidos');
  END IF;
  SELECT e INTO v_m FROM jsonb_array_elements(v_j->'mensual') e WHERE e->>'mes' = to_char(v_hoy, 'YYYY-MM');
  IF (v_m->>'pedidos') IS DISTINCT FROM (v_j->'kpis'->>'pedidos') OR (v_m->>'ticket') IS DISTINCT FROM (v_j->'kpis'->>'ticket') THEN
    v_fallas := v_fallas || format('E2 el mes %s no da lo mismo que los kpis', v_m);
  END IF;
  -- El cliente sin venta, si aparece en el ranking, va con su pedido.
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j->'top_clientes') e
              WHERE (e->>'cliente_id')::bigint = v_c0 AND (e->>'pedidos')::int <> 1) THEN
    v_fallas := v_fallas || 'E2 el pedido sin venta no cuenta en los pedidos de su cliente'::text;
  END IF;

  -- L3
  IF (v_j->'top_productos'->0->>'producto_id')::bigint IS DISTINCT FROM v_prod
     OR (v_j->'top_productos'->0->>'sucursal') IS DISTINCT FROM (SELECT nombre FROM sucursales WHERE id = v_suc)
     OR (v_j->'top_productos'->0->>'venta')::numeric IS DISTINCT FROM 95000000 THEN
    v_fallas := v_fallas || format('L3 top_productos no va por producto: %s', v_j->'top_productos'->0);
  END IF;

  -- E1 (como el admin)
  IF ARRAY(SELECT x FROM unnest(public._tablero_sucursales(NULL)) x ORDER BY x) IS DISTINCT FROM public._sucursales_red() THEN
    v_fallas := v_fallas || 'E1 _tablero_sucursales(NULL) del admin no es _sucursales_red()'::text;
  END IF;
  IF public.comision_regla_alcanzable(NULL) IS DISTINCT FROM
     NOT EXISTS (SELECT 1 FROM sucursales s WHERE s.activa
                  AND s.id NOT IN (SELECT us.sucursal_id FROM usuario_sucursales us WHERE us.usuario_id = v_adm)) THEN
    v_fallas := v_fallas || 'E1 comision_regla_alcanzable(NULL) del admin no es "tiene todas las activas"'::text;
  END IF;

  -- L4 y E1 (como el servidor)
  PERFORM set_config('request.jwt.claims', '', true);
  BEGIN
    v_res := public.reporte_combos(NULL, v_hoy - 30, v_hoy, false, false);
    IF (v_res->'meta'->>'sucursal_id') IS NOT NULL THEN
      v_fallas := v_fallas || format('L4 reporte_combos del servidor no es la Red: %s', v_res->'meta');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('L4 reporte_combos tira excepción con el servidor: %s', SQLERRM);
  END;
  BEGIN
    v_res := public.reporte_combos_rotacion(NULL, v_hoy - 30, v_hoy, false);
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('L4 reporte_combos_rotacion tira excepción con el servidor: %s', SQLERRM);
  END;
  IF ARRAY(SELECT x FROM unnest(public._tablero_sucursales(NULL)) x ORDER BY x)
     IS DISTINCT FROM ARRAY(SELECT id FROM sucursales WHERE activa ORDER BY id) THEN
    v_fallas := v_fallas || 'E1 _tablero_sucursales(NULL) del servidor no son todas las activas'::text;
  END IF;
  IF public.comision_regla_alcanzable(NULL) IS NOT FALSE THEN
    v_fallas := v_fallas || 'E1 el servidor alcanza una regla de la Red'::text;
  END IF;

  -- L5
  FOR v_f IN
    SELECT x.firma, x.acl, p.prosrc, p.proacl::text AS a
      FROM (VALUES
        ('public._tablero_sucursales(bigint)',                       '{postgres=X/postgres,service_role=X/postgres}'),
        ('public.reporte_combos(bigint,date,date,boolean,boolean)',  '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public.reporte_combos_rotacion(bigint,date,date,boolean)', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public.reporte_rechazos(date,date,bigint)',                '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public.reporte_valuacion_inventario(bigint)',              '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public.comision_regla_alcanzable(bigint)',                 '{postgres=X/postgres,service_role=X/postgres}')
      ) AS x(firma, acl)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF v_f.prosrc !~ '_sucursales_red\(\)' THEN
      v_fallas := v_fallas || format('L5 %s no usa _sucursales_red()', v_f.firma);
    END IF;
    IF v_f.a IS DISTINCT FROM v_f.acl THEN
      v_fallas := v_fallas || format('L5 %s cambió de EXECUTE: %s', v_f.firma, v_f.a);
    END IF;
  END LOOP;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · L1 L3 L4 L5 E1 E2';
 END;
END
$ensayo$;
