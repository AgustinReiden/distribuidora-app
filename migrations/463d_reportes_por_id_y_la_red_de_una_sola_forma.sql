-- 463 · Reportes: los rankings van por id, un pedido sin venta no es un pedido, y la Red se
-- escribe de una sola forma (#1472, tarjeta 5 de #1477).
--
-- QUÉ PASABA
--   REP-F-1 · "Mayores clientes" (`top_cli`) y `top_prod` de reporte_gerencial agrupaban por
--     el NOMBRE. En octubre la fila "Kiosco " sumaba 9 clientes distintos ($1,07 M en 32
--     pedidos) y salía tercera; "Kiosco" juntaba 7, "Despensa" 4. reporte_ventas_por_cliente
--     agrupa por id, así que los dos reportes no coincidían en quién es el mayor cliente.
--   REP-F-2 · kpis.pedidos y el ticket contaban los pedidos entregados con venta 0 (el rechazo
--     total: sin líneas). En octubre 1 de 1.310: Σ vendedores.pedidos daba 1.309.
--   REP-F-3 · _tablero_sucursales, reporte_combos, reporte_combos_rotacion, reporte_rechazos,
--     reporte_valuacion_inventario y comision_regla_alcanzable escribían la "Red" a mano, sin
--     `_sucursales_red()`. Hoy dan lo mismo. Además reporte_combos y reporte_combos_rotacion
--     rechazaban al servidor (auth.uid() NULL), al revés del resto de /reportes.
--
-- QUÉ CAMBIA
--   reporte_gerencial
--   · `top_cli` agrupa por cliente y devuelve `cliente_id` y `razon_social` además del nombre,
--     para que el front distinga a dos que se llaman igual. `top_prod` agrupa por producto y
--     devuelve `producto_id` y `sucursal` (en la Red, el mismo artículo de dos sucursales son
--     dos productos). Las líneas de productos borrados siguen yendo juntas. Los dos ordenan
--     por venta y, en un empate, por id: el puesto 10 ya no depende del plan.
--   · Un pedido cuenta como pedido si tiene venta (`venta_prod > 0`, el mismo corte que ya
--     usaba k_env): kpis.pedidos, fc_pedidos, zz_pedidos y ticket, sus pares de `mensual` y
--     los pedidos de cada fila de top_cli. Así kpis.pedidos = Σ vendedores.pedidos, que salen
--     de las líneas. La venta no se mueve (esos pedidos suman 0). `clientes` y `clientes_nuevos`
--     no cambian: #1472 pide pedidos y ticket.
--   Las otras seis
--   · Con p_sucursal_id NULL la Red es `_sucursales_red()`. reporte_combos y
--     reporte_combos_rotacion dejan pasar al servidor como reporte_rechazos (sin usuario no hay
--     sucursales asignadas que mirar). En comision_regla_alcanzable, una regla de la Red la
--     alcanza quien tiene la Red entera: su `_sucursales_red()` son todas las activas. El
--     servidor sigue sin alcanzarla (no tiene usuario, como antes). Una sucursal con `activa`
--     NULL ya no cuenta para esa pregunta, igual que para `_sucursales_red()`; hoy no hay
--     ninguna.
--
-- QUÉ NO CAMBIA
--   Las firmas, los EXECUTE, SECURITY DEFINER y el resto de cada cuerpo. "Venta por vendedor"
--   (las seis partes) no se toca: vendedores sale igual. Todo número que no sea uno de los de
--   arriba da igual: lo prueba el ensayo de abajo, antes y después en la misma transacción.
--   reporte_stock_red es global a propósito (#1334) y no se toca.
--
-- Aplicar desde el contenido LF.

-- REPEATABLE READ: las fotos de antes y de después ven el mismo snapshot (molde de la 318).
-- Esta migración no escribe ninguna tabla de negocio.
BEGIN ISOLATION LEVEL REPEATABLE READ;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- 1 · Premisas: los cuerpos vivos son los que se leyeron el 06/11
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _r5_funcs (firma text PRIMARY KEY, md5 text, acl text, definer boolean) ON COMMIT DROP;
INSERT INTO _r5_funcs (firma, md5) VALUES
  ('public.reporte_gerencial(bigint,date,date,boolean,boolean)',    '99f728cbdd7cda81d212119836112dac'),
  ('public._tablero_sucursales(bigint)',                            '8a16730b76f69875b3af3f29d18e249d'),
  ('public.reporte_combos(bigint,date,date,boolean,boolean)',       '8009914990b7ee207c1b40d2044bfe97'),
  ('public.reporte_combos_rotacion(bigint,date,date,boolean)',      'd20dd97b703fe75991163a66d551f53e'),
  ('public.reporte_rechazos(date,date,bigint)',                     '4736898ea1c4d6a32e3aab9b962e49df'),
  ('public.reporte_valuacion_inventario(bigint)',                   'd1cfe090dfdc1d4f6d38a038f0758f49'),
  ('public.comision_regla_alcanzable(bigint)',                      'abc314ad6873872eb4366ce4cbb36318');

DO $premisas$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT f.firma, f.md5, md5(p.prosrc) AS md5_vivo
      FROM _r5_funcs f JOIN pg_proc p ON p.oid = f.firma::regprocedure
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION 'mig 463 · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;
  -- La ACL y SECURITY DEFINER de antes: la poscondición exige que no cambien.
  UPDATE _r5_funcs f SET acl = p.proacl::text, definer = p.prosecdef
    FROM pg_proc p WHERE p.oid = f.firma::regprocedure;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 2 · Andamio del ensayo (pg_temp: no queda nada en public)
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _r5_foto (
  etapa  text   NOT NULL,          -- 'antes' | 'despues'
  quien  text   NOT NULL,          -- uuid del usuario o 'servidor'
  fn     text   NOT NULL,
  rango  text   NOT NULL DEFAULT '',
  desde  date,
  hasta  date,
  suc    bigint,                   -- NULL = la Red
  extra  text   NOT NULL DEFAULT '',
  sucs   bigint[],                 -- la Red del que llama, para recalcular aparte
  valor  jsonb
) ON COMMIT DROP;

-- Arrays ordenados por su texto: un ORDER BY con empates no es un cambio (molde de la 318).
CREATE FUNCTION pg_temp._r5_norm(j jsonb) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $f$
DECLARE
  r jsonb;
BEGIN
  CASE jsonb_typeof(j)
    WHEN 'object' THEN
      SELECT COALESCE(jsonb_object_agg(e.k, pg_temp._r5_norm(e.v)), '{}'::jsonb)
        INTO r FROM jsonb_each(j) AS e(k, v);
    WHEN 'array' THEN
      SELECT COALESCE(jsonb_agg(s.x ORDER BY s.x::text), '[]'::jsonb)
        INTO r FROM (SELECT pg_temp._r5_norm(a.v) AS x FROM jsonb_array_elements(j) AS a(v)) s;
    ELSE
      r := j;
  END CASE;
  RETURN r;
END
$f$;

-- Una llamada; si tira excepción, la foto guarda el mensaje (así se ve el cambio de combos
-- con el servidor y que ningún guard cambió de respuesta).
CREATE FUNCTION pg_temp._r5_llamar(p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE
  v jsonb;
BEGIN
  EXECUTE p_sql INTO v;
  RETURN v;
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('_error', SQLERRM);
END
$f$;

CREATE FUNCTION pg_temp._r5_como(p_quien uuid) RETURNS void
LANGUAGE sql AS $f$
  SELECT set_config('request.jwt.claims',
                    CASE WHEN p_quien IS NULL THEN ''
                         ELSE json_build_object('sub', p_quien, 'role', 'authenticated')::text END,
                    true);
$f$;

CREATE FUNCTION pg_temp._r5_fotografiar(p_etapa text) RETURNS integer
LANGUAGE plpgsql AS $f$
DECLARE
  v_claims text := current_setting('request.jwt.claims', true);
  v_hoy    date := public._tablero_hoy();
  -- El mes cerrado: octubre si se aplica en noviembre (el de "Kiosco " y del pedido 7604).
  v_mc_d   date := (date_trunc('month', v_hoy::timestamp) - interval '1 month')::date;
  v_mc_h   date := (date_trunc('month', v_hoy::timestamp) - interval '1 day')::date;
  v_admin  uuid;
  v_u      record;
  v_r      record;
  v_suc    bigint;
  v_sucs   bigint[];
  v_q      text;
  v_n      integer;
BEGIN
  -- El admin con más sucursales activas (molde de la 241/318).
  SELECT us.usuario_id INTO v_admin
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND COALESCE(pf.activo, true)
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   GROUP BY us.usuario_id
   ORDER BY count(*) DESC, us.usuario_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'mig 463 · el ensayo necesita un admin con al menos una sucursal activa asignada';
  END IF;

  -- a) Ese admin: los cinco reportes en cinco rangos, para la Red y cada sucursal suya.
  PERFORM pg_temp._r5_como(v_admin);
  v_q := v_admin::text;
  FOR v_r IN
    SELECT * FROM (VALUES
      ('mes_cerrado',  v_mc_d, v_mc_h),
      ('abril',        DATE '2026-04-01', DATE '2026-04-30'),  -- el otro pedido con venta 0 (652)
      ('mes_en_curso', date_trunc('month', v_hoy::timestamp)::date, v_hoy),
      ('anio',         date_trunc('year', v_hoy::timestamp)::date,  v_hoy),
      ('semana',       v_hoy - 6,                        v_hoy)
    ) AS t(rango, desde, hasta)
  LOOP
    FOR v_suc IN
      SELECT NULL::bigint
      UNION ALL
      (SELECT s.id FROM sucursales s
         JOIN usuario_sucursales us ON us.sucursal_id = s.id AND us.usuario_id = v_admin
        WHERE s.activa ORDER BY s.id)
    LOOP
      v_sucs := CASE WHEN v_suc IS NULL THEN public._sucursales_red() ELSE ARRAY[v_suc] END;
      INSERT INTO _r5_foto (etapa, quien, fn, rango, desde, hasta, suc, extra, sucs, valor) VALUES
        (p_etapa, v_q, 'reporte_gerencial', v_r.rango, v_r.desde, v_r.hasta, v_suc, 'comparar', v_sucs,
           pg_temp._r5_llamar(format('SELECT public.reporte_gerencial(%L::bigint, %L::date, %L::date, false, true)', v_suc, v_r.desde, v_r.hasta))),
        (p_etapa, v_q, 'reporte_gerencial', v_r.rango, v_r.desde, v_r.hasta, v_suc, 'no_entregados', v_sucs,
           pg_temp._r5_llamar(format('SELECT public.reporte_gerencial(%L::bigint, %L::date, %L::date, true, false)', v_suc, v_r.desde, v_r.hasta))),
        (p_etapa, v_q, 'reporte_combos', v_r.rango, v_r.desde, v_r.hasta, v_suc, 'comparar', v_sucs,
           pg_temp._r5_llamar(format('SELECT public.reporte_combos(%L::bigint, %L::date, %L::date, false, true)', v_suc, v_r.desde, v_r.hasta))),
        (p_etapa, v_q, 'reporte_combos', v_r.rango, v_r.desde, v_r.hasta, v_suc, 'no_entregados', v_sucs,
           pg_temp._r5_llamar(format('SELECT public.reporte_combos(%L::bigint, %L::date, %L::date, true, false)', v_suc, v_r.desde, v_r.hasta))),
        (p_etapa, v_q, 'reporte_combos_rotacion', v_r.rango, v_r.desde, v_r.hasta, v_suc, '', v_sucs,
           pg_temp._r5_llamar(format('SELECT public.reporte_combos_rotacion(%L::bigint, %L::date, %L::date, false)', v_suc, v_r.desde, v_r.hasta))),
        (p_etapa, v_q, 'reporte_rechazos', v_r.rango, v_r.desde, v_r.hasta, v_suc, '', v_sucs,
           pg_temp._r5_llamar(format('SELECT public.reporte_rechazos(%L::date, %L::date, %L::bigint)', v_r.desde, v_r.hasta, v_suc)));
    END LOOP;
  END LOOP;
  FOR v_suc IN
    SELECT NULL::bigint
    UNION ALL
    (SELECT s.id FROM sucursales s
       JOIN usuario_sucursales us ON us.sucursal_id = s.id AND us.usuario_id = v_admin
      WHERE s.activa ORDER BY s.id)
  LOOP
    INSERT INTO _r5_foto (etapa, quien, fn, suc, valor) VALUES
      (p_etapa, v_q, 'reporte_valuacion_inventario', v_suc,
         pg_temp._r5_llamar(format('SELECT public.reporte_valuacion_inventario(%L::bigint)', v_suc))),
      (p_etapa, v_q, 'tablero_kpis', v_suc,
         pg_temp._r5_llamar(format('SELECT public.tablero_kpis(%L::bigint, NULL)', v_suc))),
      (p_etapa, v_q, 'tablero_clientes_inactivos', v_suc,
         pg_temp._r5_llamar(format('SELECT public.tablero_clientes_inactivos(%L::bigint)', v_suc)));
  END LOOP;

  -- b) Cada admin y encargado activo: la Red del mes cerrado de los reportes, el helper del
  --    tablero y la regla alcanzable, para la Red y para cada sucursal (con las ajenas).
  FOR v_u IN
    SELECT pf.id FROM perfiles pf
     WHERE pf.rol IN ('admin', 'encargado') AND COALESCE(pf.activo, true)
     ORDER BY pf.id
  LOOP
    PERFORM pg_temp._r5_como(v_u.id);
    v_q := v_u.id::text;
    INSERT INTO _r5_foto (etapa, quien, fn, rango, suc, valor) VALUES
      (p_etapa, v_q, 'tablero_contexto', '', NULL, pg_temp._r5_llamar('SELECT public.tablero_contexto()')),
      (p_etapa, v_q, 'reporte_combos_rotacion', 'red_usuario', NULL,
         pg_temp._r5_llamar(format('SELECT public.reporte_combos_rotacion(NULL, %L::date, %L::date, false)', v_mc_d, v_mc_h))),
      (p_etapa, v_q, 'reporte_rechazos', 'red_usuario', NULL,
         pg_temp._r5_llamar(format('SELECT public.reporte_rechazos(%L::date, %L::date, NULL)', v_mc_d, v_mc_h))),
      (p_etapa, v_q, 'reporte_valuacion_inventario', 'red_usuario', NULL,
         pg_temp._r5_llamar('SELECT public.reporte_valuacion_inventario(NULL)'));
    FOR v_suc IN SELECT NULL::bigint UNION ALL (SELECT s.id FROM sucursales s ORDER BY s.id) LOOP
      INSERT INTO _r5_foto (etapa, quien, fn, suc, valor) VALUES
        (p_etapa, v_q, '_tablero_sucursales', v_suc,
           pg_temp._r5_llamar(format('SELECT to_jsonb(ARRAY(SELECT x FROM unnest(public._tablero_sucursales(%L::bigint)) x ORDER BY x))', v_suc))),
        (p_etapa, v_q, 'comision_regla_alcanzable', v_suc,
           pg_temp._r5_llamar(format('SELECT to_jsonb(public.comision_regla_alcanzable(%L::bigint))', v_suc)));
    END LOOP;
  END LOOP;

  -- c) El servidor (sin usuario): la Red.
  PERFORM pg_temp._r5_como(NULL);
  v_sucs := public._sucursales_red();
  INSERT INTO _r5_foto (etapa, quien, fn, rango, desde, hasta, suc, extra, sucs, valor)
  SELECT p_etapa, 'servidor', x.fn, 'mes_cerrado', v_mc_d, v_mc_h, NULL, x.extra, v_sucs,
         pg_temp._r5_llamar(format(x.q, v_mc_d, v_mc_h))
    FROM (VALUES
      ('reporte_gerencial',       'comparar',      'SELECT public.reporte_gerencial(NULL, %L::date, %L::date, false, true)'),
      ('reporte_combos',          'comparar',      'SELECT public.reporte_combos(NULL, %L::date, %L::date, false, true)'),
      ('reporte_combos_rotacion', '',              'SELECT public.reporte_combos_rotacion(NULL, %L::date, %L::date, false)'),
      ('reporte_rechazos',        '',              'SELECT public.reporte_rechazos(%L::date, %L::date, NULL)')
    ) AS x(fn, extra, q);
  INSERT INTO _r5_foto (etapa, quien, fn, suc, valor) VALUES
    (p_etapa, 'servidor', 'reporte_valuacion_inventario', NULL, pg_temp._r5_llamar('SELECT public.reporte_valuacion_inventario(NULL)')),
    (p_etapa, 'servidor', '_tablero_sucursales', NULL,
       pg_temp._r5_llamar('SELECT to_jsonb(ARRAY(SELECT x FROM unnest(public._tablero_sucursales(NULL)) x ORDER BY x))')),
    (p_etapa, 'servidor', 'comision_regla_alcanzable', NULL,
       pg_temp._r5_llamar('SELECT to_jsonb(public.comision_regla_alcanzable(NULL))'));

  PERFORM set_config('request.jwt.claims', COALESCE(v_claims, ''), true);
  SELECT count(*) INTO v_n FROM _r5_foto WHERE etapa = p_etapa;
  RETURN v_n;
END
$f$;

-- Los pedidos que el gerencial mira (el corte de `ped`), con su venta de productos.
CREATE FUNCTION pg_temp._r5_ped(p_desde date, p_hasta date, p_sucs bigint[], p_todos boolean)
RETURNS TABLE (id bigint, cliente_id bigint, fecha date, tipo text, venta numeric)
LANGUAGE sql STABLE AS $f$
  SELECT p.id, p.cliente_id, p.fecha, COALESCE(p.tipo_factura, 'ZZ'), GREATEST(p.total - p.cargo_envio, 0)
    FROM pedidos p
   WHERE p.estado = ANY(CASE WHEN p_todos THEN ARRAY['entregado','asignado','pendiente','en_preparacion']
                             ELSE ARRAY['entregado'] END)
     AND p.canal <> 'cambio' AND p.tipo_factura IS DISTINCT FROM 'VB'
     AND p.fecha BETWEEN p_desde AND p_hasta AND p.sucursal_id = ANY(p_sucs);
$f$;

-- Los cuatro números de pedidos de un período, recalculados aparte y con la regla nueva.
CREATE FUNCTION pg_temp._r5_pedidos(p_desde date, p_hasta date, p_sucs bigint[], p_todos boolean)
RETURNS jsonb LANGUAGE sql STABLE AS $f$
  SELECT jsonb_build_object(
           'pedidos',    count(*) FILTER (WHERE venta > 0),
           'fc_pedidos', count(*) FILTER (WHERE venta > 0 AND tipo = 'FC'),
           'zz_pedidos', count(*) FILTER (WHERE venta > 0 AND tipo = 'ZZ'),
           'ticket',     COALESCE(round(sum(venta) / NULLIF(count(*) FILTER (WHERE venta > 0), 0)), 0))
    FROM pg_temp._r5_ped(p_desde, p_hasta, p_sucs, p_todos);
$f$;

-- Lo que el gerencial nuevo tiene que dar en lo que cambia; '' si da, si no el detalle.
CREATE FUNCTION pg_temp._r5_chequear_gerencial(d jsonb, p_desde date, p_hasta date, p_sucs bigint[], p_todos boolean)
RETURNS text LANGUAGE plpgsql STABLE AS $f$
DECLARE
  v_f   text := '';
  v_esp jsonb;
  v_m   record;
  v_cli jsonb;
  v_pro jsonb;
BEGIN
  -- kpis
  v_esp := pg_temp._r5_pedidos(p_desde, p_hasta, p_sucs, p_todos);
  IF (d->'kpis') @> v_esp IS NOT TRUE THEN
    v_f := v_f || format(' kpis %s, esperado %s;', jsonb_build_object('pedidos', d->'kpis'->'pedidos',
             'fc_pedidos', d->'kpis'->'fc_pedidos', 'zz_pedidos', d->'kpis'->'zz_pedidos', 'ticket', d->'kpis'->'ticket'), v_esp);
  END IF;
  -- kpis.pedidos = Σ vendedores.pedidos
  IF (d->'kpis'->>'pedidos')::numeric IS DISTINCT FROM
     (SELECT COALESCE(sum((e->>'pedidos')::numeric), 0) FROM jsonb_array_elements(d->'vendedores') e) THEN
    v_f := v_f || ' kpis.pedidos <> Σ vendedores.pedidos;';
  END IF;
  -- mensual
  FOR v_m IN SELECT e FROM jsonb_array_elements(d->'mensual') e LOOP
    v_esp := pg_temp._r5_pedidos(GREATEST(p_desde, to_date(v_m.e->>'mes' || '-01', 'YYYY-MM-DD')),
                                 LEAST(p_hasta, (to_date(v_m.e->>'mes' || '-01', 'YYYY-MM-DD') + interval '1 month' - interval '1 day')::date),
                                 p_sucs, p_todos) - 'fc_pedidos' - 'zz_pedidos';
    IF v_m.e @> v_esp IS NOT TRUE THEN
      v_f := v_f || format(' mensual %s: %s/%s, esperado %s;', v_m.e->>'mes', v_m.e->'pedidos', v_m.e->'ticket', v_esp);
    END IF;
  END LOOP;
  -- comparativo (el período anterior, que sale de la misma función)
  IF d ? 'comparativo' AND jsonb_typeof(d->'comparativo') = 'object' THEN
    v_esp := pg_temp._r5_pedidos((d->'comparativo'->>'desde')::date, (d->'comparativo'->>'hasta')::date, p_sucs, p_todos);
    IF (d->'comparativo') @> v_esp IS NOT TRUE THEN
      v_f := v_f || format(' comparativo %s/%s, esperado %s;', d->'comparativo'->'pedidos', d->'comparativo'->'ticket', v_esp);
    END IF;
  END IF;
  -- top_clientes: por id, recalculado aparte
  SELECT COALESCE(jsonb_agg(jsonb_build_object('cliente_id', t.cliente_id, 'cliente', t.cliente,
           'razon_social', t.razon_social, 'pedidos', t.pedidos, 'venta', t.venta) ORDER BY t.venta DESC, t.cliente_id), '[]'::jsonb)
    INTO v_cli
    FROM (SELECT c.id AS cliente_id, COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social) AS cliente,
                 c.razon_social, count(*) FILTER (WHERE p.venta > 0) AS pedidos, sum(p.venta) AS venta
            FROM pg_temp._r5_ped(p_desde, p_hasta, p_sucs, p_todos) p JOIN clientes c ON c.id = p.cliente_id
           GROUP BY c.id ORDER BY sum(p.venta) DESC, c.id LIMIT 10) t;
  IF (d->'top_clientes') IS DISTINCT FROM v_cli THEN
    v_f := v_f || format(' top_clientes %s, esperado %s;', d->'top_clientes', v_cli);
  END IF;
  -- top_productos: por id, recalculado aparte (venta y unidades)
  SELECT COALESCE(jsonb_agg(jsonb_build_object('producto_id', t.producto_id, 'venta', t.venta, 'unidades', t.unidades)
           ORDER BY t.venta DESC, t.producto_id NULLS LAST), '[]'::jsonb)
    INTO v_pro
    FROM (SELECT pr.id AS producto_id, sum(pi.subtotal) AS venta,
                 COALESCE(sum(pi.cantidad) FILTER (WHERE NOT pi.es_bonificacion), 0) AS unidades
            FROM pg_temp._r5_ped(p_desde, p_hasta, p_sucs, p_todos) p
            JOIN pedido_items pi ON pi.pedido_id = p.id
            LEFT JOIN productos pr ON pr.id = pi.producto_id
           GROUP BY pr.id ORDER BY sum(pi.subtotal) DESC, pr.id NULLS LAST LIMIT 10) t;
  IF (SELECT COALESCE(jsonb_agg(jsonb_build_object('producto_id', e->'producto_id', 'venta', e->'venta', 'unidades', e->'unidades')), '[]'::jsonb)
        FROM jsonb_array_elements(d->'top_productos') e) IS DISTINCT FROM v_pro THEN
    v_f := v_f || format(' top_productos %s, esperado %s;', d->'top_productos', v_pro);
  END IF;
  RETURN v_f;
END
$f$;

-- Lo que el ensayo deja de comparar en el gerencial porque cambia a propósito (y ya lo
-- chequeó _r5_chequear_gerencial).
CREATE FUNCTION pg_temp._r5_sin_lo_que_cambia(j jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $f$
  SELECT jsonb_set((j #- '{kpis,pedidos}' #- '{kpis,ticket}' #- '{kpis,fc_pedidos}' #- '{kpis,zz_pedidos}'
                      #- '{comparativo,pedidos}' #- '{comparativo,ticket}' #- '{comparativo,fc_pedidos}' #- '{comparativo,zz_pedidos}')
                     - 'top_clientes' - 'top_productos',
                   '{mensual}',
                   COALESCE((SELECT jsonb_agg(e - 'pedidos' - 'ticket') FROM jsonb_array_elements(j->'mensual') e), '[]'::jsonb))
$f$;

SELECT pg_temp._r5_fotografiar('antes');

-- ---------------------------------------------------------------------------
-- 3 · Parches por ancla sobre el cuerpo vivo
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _r5_parche (firma text, orden int, ancla text, reemplazo text, veces int DEFAULT 1) ON COMMIT DROP;

INSERT INTO _r5_parche (firma, orden, ancla, reemplazo) VALUES
-- reporte_gerencial · REP-F-1: `it` lleva el producto y su sucursal
('public.reporte_gerencial(bigint,date,date,boolean,boolean)', 1,
$a$           COALESCE(prod.nombre, '(producto borrado)') AS prod_nombre,
$a$,
$r$           COALESCE(prod.nombre, '(producto borrado)') AS prod_nombre,
           -- #1472 (REP-F-1): top_prod agrupa por producto, no por nombre.
           prod.id AS producto_id, prod.sucursal_id AS prod_sucursal_id,
$r$),
-- reporte_gerencial · REP-F-2: pedidos y ticket de los kpis
('public.reporte_gerencial(bigint,date,date,boolean,boolean)', 2,
$a$  k_ped AS (SELECT COUNT(*) AS pedidos, COALESCE(SUM(venta_prod),0) AS venta, -- cargo_4
            COUNT(DISTINCT cliente_id) AS clientes, COALESCE(ROUND(AVG(venta_prod)),0) AS ticket,
$a$,
$r$  -- #1472 (REP-F-2): un pedido sin venta (el rechazo total, que no tiene líneas) no es un
  -- pedido: no está en vendedores y diluía el ticket. Pedidos, ticket y su partición FC/ZZ
  -- cuentan venta_prod > 0, el corte de k_env; así kpis.pedidos = Σ vendedores.pedidos. La
  -- venta no cambia (suman 0), y `clientes` tampoco: #1472 pide pedidos y ticket.
  k_ped AS (SELECT COUNT(*) FILTER (WHERE venta_prod > 0) AS pedidos, COALESCE(SUM(venta_prod),0) AS venta, -- cargo_4
            COUNT(DISTINCT cliente_id) AS clientes, COALESCE(ROUND(AVG(venta_prod) FILTER (WHERE venta_prod > 0)),0) AS ticket,
$r$),
('public.reporte_gerencial(bigint,date,date,boolean,boolean)', 3,
$a$            COUNT(*) FILTER (WHERE tipo_factura='FC') AS fc_pedidos,
$a$,
$r$            COUNT(*) FILTER (WHERE tipo_factura='FC' AND venta_prod > 0) AS fc_pedidos,
$r$),
('public.reporte_gerencial(bigint,date,date,boolean,boolean)', 4,
$a$            COUNT(*) FILTER (WHERE tipo_factura='ZZ') AS zz_pedidos
$a$,
$r$            COUNT(*) FILTER (WHERE tipo_factura='ZZ' AND venta_prod > 0) AS zz_pedidos
$r$),
-- reporte_gerencial · REP-F-2: lo mismo por mes, para que Σ mensual cierre contra kpis
('public.reporte_gerencial(bigint,date,date,boolean,boolean)', 5,
$a$  m_ped AS (SELECT to_char(fecha,'YYYY-MM') AS mes, COUNT(*) AS pedidos, SUM(venta_prod) AS venta, -- cargo_4
            SUM(total_real) AS venta_real,
            COUNT(DISTINCT cliente_id) AS clientes, ROUND(AVG(venta_prod)) AS ticket FROM ped GROUP BY 1),
$a$,
$r$  m_ped AS (SELECT to_char(fecha,'YYYY-MM') AS mes, COUNT(*) FILTER (WHERE venta_prod > 0) AS pedidos, SUM(venta_prod) AS venta, -- cargo_4, #1472
            SUM(total_real) AS venta_real,
            COUNT(DISTINCT cliente_id) AS clientes, ROUND(AVG(venta_prod) FILTER (WHERE venta_prod > 0)) AS ticket FROM ped GROUP BY 1),
$r$),
-- reporte_gerencial · REP-F-1: top_prod y top_cli por id
('public.reporte_gerencial(bigint,date,date,boolean,boolean)', 6,
$a$  top_prod AS (SELECT prod_nombre AS nombre,
      COALESCE(SUM(cantidad) FILTER (WHERE NOT es_bonificacion),0) AS unidades, SUM(subtotal) AS venta,
      SUM(ingreso_real) AS venta_real,
      SUM(subtotal) - COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS margen,
      SUM(ingreso_real) - COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS margen_real
    FROM it GROUP BY prod_nombre ORDER BY venta DESC LIMIT 10),
  top_cli AS (SELECT COALESCE(NULLIF(c.nombre_fantasia,''), c.razon_social) AS cliente,
      COUNT(DISTINCT p.id) AS pedidos, SUM(p.venta_prod) AS venta -- cargo_4
    FROM ped p JOIN clientes c ON c.id=p.cliente_id GROUP BY 1 ORDER BY venta DESC LIMIT 10),
$a$,
$r$  -- #1472 (REP-F-1): por producto y por cliente, no por nombre. Por nombre, "Kiosco " juntaba
  -- 9 clientes en octubre. Las líneas de productos borrados (producto_id NULL) van juntas. En la
  -- Red, el mismo artículo de dos sucursales son dos productos: `sucursal` los distingue. El
  -- empate se desempata por id para que el puesto 10 no dependa del plan. Los pedidos de un
  -- cliente cuentan los que tienen venta, como kpis.pedidos (REP-F-2).
  top_prod AS (SELECT t.producto_id, t.nombre, s.nombre AS sucursal,
      t.unidades, t.venta, t.venta_real, t.margen, t.margen_real
    FROM (SELECT producto_id, MIN(prod_nombre) AS nombre, MIN(prod_sucursal_id) AS sucursal_id,
        COALESCE(SUM(cantidad) FILTER (WHERE NOT es_bonificacion),0) AS unidades, SUM(subtotal) AS venta,
        SUM(ingreso_real) AS venta_real,
        SUM(subtotal) - COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS margen,
        SUM(ingreso_real) - COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS margen_real
      FROM it GROUP BY producto_id ORDER BY venta DESC, producto_id NULLS LAST LIMIT 10) t
    LEFT JOIN sucursales s ON s.id = t.sucursal_id
    ORDER BY t.venta DESC, t.producto_id NULLS LAST),
  top_cli AS (SELECT c.id AS cliente_id, COALESCE(NULLIF(c.nombre_fantasia,''), c.razon_social) AS cliente,
      c.razon_social,
      COUNT(DISTINCT p.id) FILTER (WHERE p.venta_prod > 0) AS pedidos, SUM(p.venta_prod) AS venta -- cargo_4
    FROM ped p JOIN clientes c ON c.id=p.cliente_id GROUP BY c.id ORDER BY venta DESC, c.id LIMIT 10),
$r$),
('public.reporte_gerencial(bigint,date,date,boolean,boolean)', 7,
$a$    'top_productos', (SELECT COALESCE(jsonb_agg(to_jsonb(t)),'[]') FROM top_prod t),
    'top_clientes', (SELECT COALESCE(jsonb_agg(to_jsonb(t)),'[]') FROM top_cli t),
$a$,
$r$    'top_productos', (SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.venta DESC, t.producto_id NULLS LAST),'[]') FROM top_prod t),
    'top_clientes', (SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.venta DESC, t.cliente_id),'[]') FROM top_cli t),
$r$),

-- _tablero_sucursales · REP-F-3
('public._tablero_sucursales(bigint)', 1,
$a$  IF p_sucursal_id IS NULL THEN
    SELECT array_agg(id) INTO v_res FROM sucursales
     WHERE activa AND (v_asig IS NULL OR id = ANY(v_asig));
  ELSE
$a$,
$r$  IF p_sucursal_id IS NULL THEN
    v_res := public._sucursales_red();  -- #1472 (REP-F-3)
  ELSE
$r$),

-- reporte_combos · REP-F-3: el servidor pasa, y la Red es _sucursales_red()
('public.reporte_combos(bigint,date,date,boolean,boolean)', 1,
$a$  IF auth.uid() IS NULL OR NOT public.es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin o encargado';
  END IF;
  SELECT array_agg(sucursal_id) INTO v_asignadas
    FROM usuario_sucursales WHERE usuario_id = auth.uid();
  IF v_asignadas IS NULL THEN
    RAISE EXCEPTION 'Acceso denegado: el usuario no tiene sucursales asignadas';
  END IF;
$a$,
$r$  -- #1472 (REP-F-3): el servidor (sin usuario) pasa, como en reporte_rechazos.
  IF auth.uid() IS NOT NULL THEN
    IF NOT public.es_encargado_o_admin() THEN
      RAISE EXCEPTION 'Acceso denegado: se requiere rol admin o encargado';
    END IF;
    SELECT array_agg(sucursal_id) INTO v_asignadas
      FROM usuario_sucursales WHERE usuario_id = auth.uid();
    IF v_asignadas IS NULL THEN
      RAISE EXCEPTION 'Acceso denegado: el usuario no tiene sucursales asignadas';
    END IF;
  END IF;
$r$),
('public.reporte_combos(bigint,date,date,boolean,boolean)', 2,
$a$    SELECT array_agg(s.id) INTO v_sucursales
      FROM sucursales s WHERE s.activa AND s.id = ANY(v_asignadas);
$a$,
$r$    v_sucursales := public._sucursales_red();  -- #1472 (REP-F-3)
$r$),
('public.reporte_combos(bigint,date,date,boolean,boolean)', 3,
$a$    IF NOT (p_sucursal_id = ANY(v_asignadas)) THEN
$a$,
$r$    IF auth.uid() IS NOT NULL AND NOT (p_sucursal_id = ANY(v_asignadas)) THEN
$r$),

-- reporte_combos_rotacion · lo mismo
('public.reporte_combos_rotacion(bigint,date,date,boolean)', 1,
$a$  IF auth.uid() IS NULL OR NOT public.es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin o encargado';
  END IF;
  SELECT array_agg(sucursal_id) INTO v_asignadas
    FROM usuario_sucursales WHERE usuario_id = auth.uid();
  IF v_asignadas IS NULL THEN
    RAISE EXCEPTION 'Acceso denegado: el usuario no tiene sucursales asignadas';
  END IF;
$a$,
$r$  -- #1472 (REP-F-3): el servidor (sin usuario) pasa, como en reporte_rechazos.
  IF auth.uid() IS NOT NULL THEN
    IF NOT public.es_encargado_o_admin() THEN
      RAISE EXCEPTION 'Acceso denegado: se requiere rol admin o encargado';
    END IF;
    SELECT array_agg(sucursal_id) INTO v_asignadas
      FROM usuario_sucursales WHERE usuario_id = auth.uid();
    IF v_asignadas IS NULL THEN
      RAISE EXCEPTION 'Acceso denegado: el usuario no tiene sucursales asignadas';
    END IF;
  END IF;
$r$),
('public.reporte_combos_rotacion(bigint,date,date,boolean)', 2,
$a$    SELECT array_agg(s.id) INTO v_sucursales
      FROM sucursales s WHERE s.activa AND s.id = ANY(v_asignadas);
$a$,
$r$    v_sucursales := public._sucursales_red();  -- #1472 (REP-F-3)
$r$),
('public.reporte_combos_rotacion(bigint,date,date,boolean)', 3,
$a$    IF NOT (p_sucursal_id = ANY(v_asignadas)) THEN
$a$,
$r$    IF auth.uid() IS NOT NULL AND NOT (p_sucursal_id = ANY(v_asignadas)) THEN
$r$),

-- reporte_rechazos · REP-F-3
('public.reporte_rechazos(date,date,bigint)', 1,
$a$    SELECT array_agg(id) INTO v_sucursales FROM sucursales WHERE activa;
    IF NOT v_es_servicio THEN
      SELECT array_agg(s) INTO v_sucursales FROM unnest(v_sucursales) AS s WHERE s = ANY(v_asignadas);
    END IF;
$a$,
$r$    v_sucursales := public._sucursales_red();  -- #1472 (REP-F-3)
$r$),

-- reporte_valuacion_inventario · REP-F-3
('public.reporte_valuacion_inventario(bigint)', 1,
$a$    SELECT array_agg(id) INTO v_sucursales FROM sucursales WHERE activa;
    IF NOT v_es_servicio THEN
      SELECT array_agg(s) INTO v_sucursales FROM unnest(v_sucursales) AS s WHERE s = ANY(v_asignadas); END IF;
$a$,
$r$    v_sucursales := public._sucursales_red();  -- #1472 (REP-F-3)
$r$),

-- comision_regla_alcanzable · REP-F-3
('public.comision_regla_alcanzable(bigint)', 1,
$a$    WHEN p_sucursal_id IS NULL THEN
      NOT EXISTS (
        SELECT 1 FROM sucursales s
         WHERE COALESCE(s.activa, true)
           AND NOT EXISTS (SELECT 1 FROM usuario_sucursales us
                            WHERE us.usuario_id = auth.uid() AND us.sucursal_id = s.id))
$a$,
$r$    -- #1472 (REP-F-3): una regla de la Red la alcanza quien tiene la Red entera: su Red
    -- (_sucursales_red(), las activas que tiene asignadas) son todas las activas. El servidor
    -- no tiene usuario y no la alcanza, como antes.
    WHEN p_sucursal_id IS NULL THEN
      auth.uid() IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM sucursales s
         WHERE s.activa
           AND NOT (s.id = ANY(COALESCE(public._sucursales_red(), '{}'::bigint[]))))
$r$);

DO $parches$
DECLARE
  v_f   record;
  v_p   record;
  v_def text;
  v_n   int;
BEGIN
  FOR v_f IN SELECT DISTINCT firma FROM _r5_parche ORDER BY firma LOOP
    v_def := pg_get_functiondef(v_f.firma::regprocedure);
    FOR v_p IN SELECT * FROM _r5_parche WHERE firma = v_f.firma ORDER BY orden LOOP
      v_n := (length(v_def) - length(replace(v_def, v_p.ancla, ''))) / length(v_p.ancla);
      IF v_n <> v_p.veces THEN
        RAISE EXCEPTION 'mig 463 · % parche %: el ancla aparece % vez/veces y se esperaba %',
          v_f.firma, v_p.orden, v_n, v_p.veces;
      END IF;
      v_def := replace(v_def, v_p.ancla, v_p.reemplazo);
    END LOOP;
    EXECUTE v_def;
  END LOOP;
END
$parches$;

-- ---------------------------------------------------------------------------
-- 4 · Ensayo: antes y después
-- ---------------------------------------------------------------------------
SELECT pg_temp._r5_fotografiar('despues');

DO $ensayo$
DECLARE
  v_r      record;
  v_a      jsonb;
  v_d      jsonb;
  v_falla  text;
  v_fallas text[] := '{}';
  v_comp   int := 0;
  v_red    jsonb;
BEGIN
  IF EXISTS (
    SELECT 1 FROM (SELECT * FROM _r5_foto WHERE etapa = 'antes') a
      FULL JOIN (SELECT * FROM _r5_foto WHERE etapa = 'despues') d
        ON d.quien = a.quien AND d.fn = a.fn AND d.rango = a.rango AND d.extra = a.extra
       AND d.suc IS NOT DISTINCT FROM a.suc
     WHERE a.fn IS NULL OR d.fn IS NULL) THEN
    RAISE EXCEPTION 'mig 463 · las fotos de antes y de después no tienen las mismas llamadas';
  END IF;

  FOR v_r IN
    SELECT a.quien, a.fn, a.rango, a.desde, a.hasta, a.suc, a.extra, a.sucs, a.valor AS antes, d.valor AS despues
      FROM _r5_foto a
      JOIN _r5_foto d
        ON d.etapa = 'despues' AND d.quien = a.quien AND d.fn = a.fn AND d.rango = a.rango
       AND d.extra = a.extra AND d.suc IS NOT DISTINCT FROM a.suc
     WHERE a.etapa = 'antes'
     ORDER BY a.quien, a.fn, a.rango, a.suc NULLS FIRST, a.extra
  LOOP
    v_comp := v_comp + 1;
    v_a := v_r.antes;
    v_d := v_r.despues;

    IF v_r.fn = 'reporte_gerencial' AND NOT (v_d ? '_error') THEN
      v_falla := pg_temp._r5_chequear_gerencial(v_d, v_r.desde, v_r.hasta, v_r.sucs, v_r.extra = 'no_entregados');
      IF v_falla <> '' THEN
        v_fallas := v_fallas || format('[gerencial %s %s suc %s %s:%s]', v_r.quien, v_r.rango, v_r.suc, v_r.extra, v_falla);
      END IF;
      v_a := pg_temp._r5_sin_lo_que_cambia(v_a);
      v_d := pg_temp._r5_sin_lo_que_cambia(v_d);
    ELSIF v_r.quien = 'servidor' AND v_r.fn IN ('reporte_combos', 'reporte_combos_rotacion') THEN
      -- Antes el servidor chocaba con el guard; ahora tiene que dar la Red entera, que es la
      -- del admin del punto (a) si ese admin tiene todas las activas.
      IF NOT (v_a ? '_error') THEN
        v_fallas := v_fallas || format('[%s servidor: antes no tiraba excepción: %s]', v_r.fn, left(v_a::text, 200));
      END IF;
      IF v_d ? '_error' THEN
        v_fallas := v_fallas || format('[%s servidor: después sigue fallando: %s]', v_r.fn, v_d->>'_error');
      END IF;
      SELECT f.valor INTO v_red FROM _r5_foto f
       WHERE f.etapa = 'despues' AND f.quien <> 'servidor' AND f.fn = v_r.fn AND f.rango = 'mes_cerrado'
         AND f.suc IS NULL AND f.extra = v_r.extra AND f.sucs = v_r.sucs
       LIMIT 1;
      IF v_red IS NOT NULL AND pg_temp._r5_norm(v_red) IS DISTINCT FROM pg_temp._r5_norm(v_d) THEN
        v_fallas := v_fallas || format('[%s servidor: no da lo mismo que la Red del admin]', v_r.fn);
      END IF;
      CONTINUE;
    END IF;

    IF pg_temp._r5_norm(v_a) IS DISTINCT FROM pg_temp._r5_norm(v_d) THEN
      v_fallas := v_fallas || format('[%s %s %s suc %s %s: antes %s, después %s]', v_r.fn, v_r.quien, v_r.rango,
        v_r.suc, v_r.extra, left(v_a::text, 300), left(v_d::text, 300));
    END IF;
  END LOOP;

  IF v_comp < 50 THEN
    RAISE EXCEPTION 'mig 463 · el ensayo comparó sólo % llamadas', v_comp;
  END IF;
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'mig 463 · el ensayo falló (% de % llamadas): %', cardinality(v_fallas), v_comp,
      left(array_to_string(v_fallas, ' '), 6000);
  END IF;
  RAISE NOTICE 'mig 463 · ensayo OK: % llamadas comparadas antes/después', v_comp;
END
$ensayo$;

-- ---------------------------------------------------------------------------
-- 5 · Poscondición: los cuerpos quedaron como en el repo, con la misma ACL y DEFINER
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT f.firma, f.acl, f.definer, x.hash, md5(p.prosrc) AS h, p.proacl::text AS a, p.prosecdef AS def
      FROM _r5_funcs f
      JOIN (VALUES
        ('public.reporte_gerencial(bigint,date,date,boolean,boolean)',    '040b57b910cd2121a9ae19766d7b083e'),
        ('public._tablero_sucursales(bigint)',                            '34448f7a8626333dad63f7dd2bbaa8f5'),
        ('public.reporte_combos(bigint,date,date,boolean,boolean)',       '6ad4c0ddb8e103f451f6a0c76663418a'),
        ('public.reporte_combos_rotacion(bigint,date,date,boolean)',      'f51d1898183202aed128586ef8e453ea'),
        ('public.reporte_rechazos(date,date,bigint)',                     '7057482d5d636ca095c7003b0136aa29'),
        ('public.reporte_valuacion_inventario(bigint)',                   '2f6db6bbb250f7876ddea8f94b146dde'),
        ('public.comision_regla_alcanzable(bigint)',                      'f0997c1abd0b445492a70d81de583d6e')
      ) AS x(firma, hash) ON x.firma = f.firma
      JOIN pg_proc p ON p.oid = f.firma::regprocedure
  LOOP
    IF r.h <> r.hash OR r.a IS DISTINCT FROM r.acl OR r.def IS DISTINCT FROM r.definer THEN
      RAISE EXCEPTION 'mig 463 · % no quedó como en el repo (md5 %, esperado %; acl %, antes %; definer %, antes %)',
        r.firma, r.h, r.hash, r.a, r.acl, r.def, r.definer;
    END IF;
  END LOOP;
END
$post$;

DROP FUNCTION pg_temp._r5_norm(jsonb), pg_temp._r5_llamar(text), pg_temp._r5_como(uuid),
  pg_temp._r5_fotografiar(text), pg_temp._r5_ped(date,date,bigint[],boolean),
  pg_temp._r5_pedidos(date,date,bigint[],boolean),
  pg_temp._r5_chequear_gerencial(jsonb,date,date,bigint[],boolean), pg_temp._r5_sin_lo_que_cambia(jsonb);

COMMIT;
