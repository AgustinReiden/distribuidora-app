-- ============================================================================
-- 410 · Reportes y fechas (#1262, #1250)
-- ============================================================================
-- El número es provisorio (el 403 al 409 ya están tomados en el ledger): se confirma contra el ledger y origin/main justo
-- antes de aplicar (Trampa 3 del CLAUDE.md). Aplicar desde el contenido LF.
--
-- QUÉ ES ESTO
-- -----------
-- #1262 · los reportes no cerraban contra su propio total.
--   · REP-1. `reporte_gerencial` y `reporte_rentabilidad` hacían JOIN (inner) a
--     `productos`, y `pedido_items_producto_id_fkey` es ON DELETE SET NULL: las
--     líneas de productos borrados (32 en prod, de enero a abril) salían de
--     categorías, top, CMV, unidades, "sin costo" y vendedores, pero
--     `kpis.venta` (que sale de `pedidos`) las seguía contando. En la Red 2026
--     faltaban 303.910 en Σ categorías, y ese ingreso contaba en los márgenes a
--     costo 0 sin que lo viera `pct_sin_costo`. Ahora son LEFT JOIN y la línea
--     aparece como "(producto borrado)". Ninguna tiene costo congelado, así que
--     entran como "sin costo": el CMV y los márgenes no se mueven, lo que se
--     mueve es que ahora se ve. Lo mismo en `rendimiento_preventistas`,
--     `avance_metas_preventista` y la lista de `reporte_alerta_detalle`
--     ('productos_sin_costo'), que tiene que sumar lo mismo que el KPI.
--   · REP-2. La CTE `vendedores` hacía JOIN a `perfiles`: los 2 pedidos de
--     marzo sin `usuario_id` (75.400) quedaban fuera. Ahora va una fila
--     "(sin vendedor)" con id NULL y base de comisión 0.
--   · REP-6. `mensual` salía de los meses con venta: un mes con compras pero
--     sin ventas desaparecía y Σ mensual.compras dejaba de cerrar contra
--     kpis.compras. Ahora sale de un calendario.
--   · REP-7. `reporte_rentabilidad` y `rendimiento_preventistas` repetían la
--     cascada de costo en vez de llamar a `costo_valuacion` y no marcaban
--     "sin costo". Medido: ninguna línea de prod da distinto con una u otra.
--   · REP-8. "Red" se resolvía de dos formas. Ahora todos los reportes llaman
--     a `_sucursales_red()`: activas ∩ asignadas, o todas las activas para el
--     servidor. Hoy no cambia nada: la única sucursal inactiva (4) está vacía.
-- #1250 · `CURRENT_DATE` es el día en UTC: entre las 21 y las 24 de Argentina
--   ya es mañana. Las 7 funciones de la tarjeta pasan a `_tablero_hoy()`, y
--   `obtener_deudores_mora` además corta `fecha_entrega` en hora argentina
--   (`::date` sobre un timestamptz también corta en UTC), como ya lo hace
--   `reporte_cuentas_por_cobrar`. El default de `pedidos.fecha` pasa al día
--   argentino: ninguna alta depende de él (las tres RPCs que insertan pedidos
--   pasan la fecha), pero el próximo INSERT que la omita no va a caer mañana.
--   El gate nuevo, `auditoria_fechas_utc()` + scripts/check-fechas-utc.mjs,
--   falla ante cualquier función o default de `public` que use CURRENT_DATE y
--   no esté en scripts/fechas-utc-permitidas.json (lo que queda, con su issue).
--
-- QUÉ SE TOCA
-- -----------
-- Nuevas, sólo de servidor (sin EXECUTE para PUBLIC, anon ni authenticated):
--   · _sucursales_red() ........ la Red de los reportes.
--   · auditoria_fechas_utc() ... el gate, para CI con service_role.
-- Parcheadas por ancla sobre el cuerpo vivo (md5 verificado abajo):
--   reporte_gerencial, reporte_alerta_detalle, reporte_rentabilidad,
--   rendimiento_preventistas, avance_metas_preventista,
--   reporte_cuentas_por_cobrar, obtener_deudores_mora, bot_metricas_admin_dia,
--   reporte_ventas_por_preventista, reporte_ventas_por_cliente, reporte_mermas
--   (de esta última, sólo la Red).
-- Tablas: el default de pedidos.fecha. [Y la FK de pedido_items.producto_id,
--   si el dueño dice RESTRICT: ver el paso 12.]
-- No se toca `posicion_fiscal` (tarjeta 5) ni `auditoria_integridad()`
-- (tarjeta 4).
--
-- Ninguna cambia de firma ni de RETURNS: CREATE OR REPLACE conserva dueño,
-- SECURITY DEFINER, search_path y ACL (el paso 10 lo verifica). Las claves
-- nuevas de los jsonb (`sinCosto`, `ingresosSinCosto`, `venta_sin_costo`) son
-- aditivas.
--
-- ENSAYO (molde de la 318)
-- ------------------------
-- Fotos de las 11 funciones antes y después, en una sola transacción
-- REPEATABLE READ, en seis rangos, por sucursal y por Red, como el admin con
-- más sucursales y como servidor. Lo que no tiene que moverse no se mueve, y
-- lo que se mueve tiene que ser EXACTAMENTE lo de #1262: cada delta se
-- recalcula de las tablas (las líneas sin producto y los pedidos sin vendedor
-- del rango) y se compara contra la diferencia de las dos fotos. Sale un
-- resumen con los números de antes y de después.
-- ============================================================================

-- REPEATABLE READ: las dos fotos ven el mismo snapshot. Ver la 318.
BEGIN ISOLATION LEVEL REPEATABLE READ;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'mig 410 · el texto de la migración trae CRLF: aplicarla desde la versión LF (git show HEAD:migrations/<archivo>)';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- 0 · Premisas
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_f record;
BEGIN
  -- Nada cambió en prod desde que se leyeron los cuerpos (2026-10-28, después
  -- de la 401 y la 402, que no tocan ninguna).
  FOR v_f IN
    SELECT x.firma, x.md5, md5(pg_get_functiondef(x.firma::regprocedure)) AS md5_vivo
      FROM (VALUES
        ('public.reporte_gerencial(bigint,date,date,boolean,boolean)',             '0a07fb75062ef4a8c302724c785f490b'),
        ('public.reporte_alerta_detalle(bigint,text,date,date,boolean)',           '7230ac42d6ac40fc76a70afe1bbb57c7'),
        ('public.reporte_rentabilidad(date,date,bigint,text)',                     '357eb50535863538175d8fe9e0ccf829'),
        ('public.rendimiento_preventistas(bigint,date)',                           '74e8d2eb3b733e8ed22a1dead0fd6d26'),
        ('public.avance_metas_preventista(uuid,date)',                             '39b64a5ddb26ce67b33fb4c67cd34521'),
        ('public.reporte_cuentas_por_cobrar(bigint)',                              '4c9dcab13949a622d9ecb944a8324645'),
        ('public.obtener_deudores_mora(integer)',                                  '90833170d54d8007837a617a4ef8f401'),
        ('public.bot_metricas_admin_dia(date,bigint)',                             '6b55cc45a14f985c50b357139c75ab87'),
        ('public.reporte_ventas_por_preventista(date,date,bigint)',                'e6f2f5105c85d788643632836a3d9d08'),
        ('public.reporte_ventas_por_cliente(date,date,uuid,bigint)',               '958d7df31e00f251630f1ae15a852452'),
        ('public.reporte_mermas(date,date,bigint,text,integer,integer,text)',      'f13d3b7fab3c10bb15b30e4378494d37'),
        ('public.costo_valuacion(numeric,numeric,numeric,numeric,numeric)',        '3daa7b6a6ecc13d60864e49cc329c86b')
      ) AS x(firma, md5)
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION 'mig 410 · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer los parches sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;

  -- Las alertas y la antigüedad de deuda se miden contra el día. Entre las 21
  -- y las 24 de Argentina CURRENT_DATE ya es mañana y el cambio de #1250 SÍ
  -- mueve esos números (es el arreglo): el ensayo, que exige que no se muevan,
  -- se corre fuera de esa franja.
  IF CURRENT_DATE <> public._tablero_hoy() THEN
    RAISE EXCEPTION 'mig 410 · son entre las 21 y las 24 de Argentina (CURRENT_DATE % y el día argentino %): aplicarla fuera de esa franja',
      CURRENT_DATE, public._tablero_hoy();
  END IF;

  -- Las fórmulas del ensayo suponen lo que se midió: las líneas sin producto
  -- no tienen costo congelado (entran como "sin costo" y no mueven el CMV), no
  -- son bonificación y tienen subtotal; todo pedido con usuario_id tiene
  -- perfil; y ningún pedido con saldo se entregó entre las 21 y las 24 (el
  -- corte nuevo de `fecha_entrega` en obtener_deudores_mora no mueve nada hoy).
  IF EXISTS (SELECT 1 FROM pedido_items
              WHERE producto_id IS NULL
                AND (costo_unitario_al_crear IS NOT NULL OR es_bonificacion OR subtotal IS NULL)) THEN
    RAISE EXCEPTION 'mig 410 · hay líneas sin producto con costo congelado, bonificadas o sin subtotal: rehacer el ensayo';
  END IF;
  IF EXISTS (SELECT 1 FROM pedidos p
              WHERE p.usuario_id IS NOT NULL
                AND NOT EXISTS (SELECT 1 FROM perfiles pf WHERE pf.id = p.usuario_id)) THEN
    RAISE EXCEPTION 'mig 410 · hay pedidos con usuario_id sin perfil: rehacer el ensayo';
  END IF;
  IF EXISTS (SELECT 1 FROM pedidos p
              WHERE p.estado = 'entregado' AND COALESCE(p.estado_pago, 'pendiente') <> 'pagado'
                AND (p.total - COALESCE(p.monto_pagado, 0)) > 0
                AND p.fecha_entrega::date <> (p.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date) THEN
    RAISE EXCEPTION 'mig 410 · hay pedidos con saldo entregados entre las 21 y las 24: el ensayo de obtener_deudores_mora supone que no';
  END IF;

  -- La Red nueva (activas) es la vieja (asignadas o todas) sólo si ninguna
  -- sucursal inactiva tiene datos.
  IF EXISTS (SELECT 1 FROM sucursales s
              WHERE NOT s.activa
                AND (EXISTS (SELECT 1 FROM pedidos WHERE sucursal_id = s.id)
                     OR EXISTS (SELECT 1 FROM compras WHERE sucursal_id = s.id)
                     OR EXISTS (SELECT 1 FROM mermas_stock WHERE sucursal_id = s.id)
                     OR EXISTS (SELECT 1 FROM metas_preventista WHERE sucursal_id = s.id)
                     OR EXISTS (SELECT 1 FROM usuario_sucursales WHERE sucursal_id = s.id))) THEN
    RAISE EXCEPTION 'mig 410 · una sucursal inactiva tiene datos: la Red nueva los deja fuera y el ensayo supone que no hay';
  END IF;
END
$premisas$;

CREATE TEMP TABLE _rf_acl ON COMMIT DROP AS
SELECT p.oid, p.proacl::text AS acl
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname IN ('reporte_gerencial','reporte_alerta_detalle','reporte_rentabilidad',
                     'rendimiento_preventistas','avance_metas_preventista',
                     'reporte_cuentas_por_cobrar','obtener_deudores_mora','bot_metricas_admin_dia',
                     'reporte_ventas_por_preventista','reporte_ventas_por_cliente','reporte_mermas');

-- ---------------------------------------------------------------------------
-- 1 · Andamio del ensayo (pg_temp: no queda en public y se borra al final)
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _rf_foto (
  etapa  text   NOT NULL,          -- 'antes' | 'despues'
  fn     text   NOT NULL,
  rango  text   NOT NULL,
  desde  date,
  hasta  date,
  suc    bigint,                   -- NULL = Red
  extra  text   NOT NULL DEFAULT '',
  valor  jsonb
) ON COMMIT DROP;

CREATE TEMP TABLE _rf_resumen (orden serial, linea text) ON COMMIT DROP;

-- Compara contenido y no orden (ver la 318).
CREATE FUNCTION pg_temp._rf_norm(j jsonb) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $f$
DECLARE
  r jsonb;
BEGIN
  CASE jsonb_typeof(j)
    WHEN 'object' THEN
      SELECT COALESCE(jsonb_object_agg(e.k, pg_temp._rf_norm(e.v)), '{}'::jsonb)
        INTO r FROM jsonb_each(j) AS e(k, v);
    WHEN 'array' THEN
      SELECT COALESCE(jsonb_agg(s.x ORDER BY s.x::text), '[]'::jsonb)
        INTO r FROM (SELECT pg_temp._rf_norm(a.v) AS x
                       FROM jsonb_array_elements(j) AS a(v)) s;
    ELSE
      r := j;
  END CASE;
  RETURN r;
END
$f$;

-- El admin con más sucursales activas (como la 241 y la 318).
CREATE FUNCTION pg_temp._rf_admin() RETURNS uuid
LANGUAGE sql STABLE AS $f$
  SELECT us.usuario_id
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin'
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   GROUP BY us.usuario_id
   ORDER BY count(*) DESC, us.usuario_id
   LIMIT 1
$f$;

-- Las sucursales que mira una llamada: la pedida, o la Red (activas del admin,
-- o todas las activas si llama el servidor).
CREATE FUNCTION pg_temp._rf_sucs(p_suc bigint, p_servicio boolean) RETURNS bigint[]
LANGUAGE sql STABLE AS $f$
  SELECT CASE WHEN p_suc IS NOT NULL THEN ARRAY[p_suc]
              ELSE ARRAY(SELECT s.id FROM sucursales s
                          WHERE s.activa
                            AND (p_servicio OR s.id IN (SELECT us.sucursal_id FROM usuario_sucursales us
                                                         WHERE us.usuario_id = pg_temp._rf_admin()))
                          ORDER BY s.id)
         END
$f$;

CREATE FUNCTION pg_temp._rf_rangos() RETURNS TABLE (rango text, desde date, hasta date)
LANGUAGE sql STABLE AS $f$
  SELECT * FROM (VALUES
    ('mes_cerrado',   (date_trunc('month', public._tablero_hoy()) - interval '1 month')::date,
                      (date_trunc('month', public._tablero_hoy()) - interval '1 day')::date),
    ('mes_en_curso',  date_trunc('month', public._tablero_hoy())::date, public._tablero_hoy()),
    ('anio',          date_trunc('year', public._tablero_hoy())::date,  public._tablero_hoy()),
    ('semana',        public._tablero_hoy() - 6,                        public._tablero_hoy()),
    -- Tiene líneas sin producto (Tucumán) y los dos pedidos sin vendedor (Taco Pozo).
    ('marzo_2026',    DATE '2026-03-01',                                DATE '2026-03-31'),
    -- Con meses por venir: el calendario de `mensual` no los pinta en cero.
    ('anio_completo', date_trunc('year', public._tablero_hoy())::date,
                      (date_trunc('year', public._tablero_hoy()) + interval '1 year - 1 day')::date)
  ) AS t(rango, desde, hasta)
$f$;

-- Las líneas sin producto que entran a un rango, por vendedor, con los mismos
-- filtros que `ped` en los reportes (estado, canal, VB, fecha, sucursal).
CREATE FUNCTION pg_temp._rf_huerfanas(p_desde date, p_hasta date, p_sucs bigint[], p_estados text[])
RETURNS TABLE (usuario_id uuid, lineas bigint, cantidad numeric, subtotal numeric, ingreso_real numeric,
               iva numeric, ii numeric, neto numeric, pedidos_solo bigint)
LANGUAGE sql STABLE AS $f$
  SELECT p.usuario_id, count(*),
         COALESCE(sum(pi.cantidad), 0),
         COALESCE(sum(pi.subtotal), 0),
         COALESCE(sum(pi.cantidad * COALESCE(pi.ingreso_real_unitario,
           CASE WHEN COALESCE(p.tipo_factura, 'ZZ') = 'FC' THEN COALESCE(pi.neto_unitario, pi.precio_unitario)
                ELSE pi.precio_unitario END)), 0),
         COALESCE(sum(pi.cantidad * COALESCE(pi.iva_unitario, 0)), 0),
         COALESCE(sum(pi.cantidad * COALESCE(pi.impuestos_internos_unitario, 0)), 0),
         COALESCE(sum(pi.cantidad * COALESCE(pi.neto_unitario, COALESCE(pi.ingreso_real_unitario, pi.precio_unitario))), 0),
         count(DISTINCT p.id) FILTER (WHERE NOT EXISTS (SELECT 1 FROM pedido_items x
                                                         WHERE x.pedido_id = p.id AND x.producto_id IS NOT NULL))
    FROM pedidos p
    JOIN pedido_items pi ON pi.pedido_id = p.id
   WHERE pi.producto_id IS NULL
     AND p.estado = ANY(p_estados) AND p.canal <> 'cambio' AND p.tipo_factura IS DISTINCT FROM 'VB'
     AND p.fecha BETWEEN p_desde AND p_hasta AND p.sucursal_id = ANY(p_sucs)
   GROUP BY p.usuario_id
$f$;

-- Las líneas sin costo (costo_valuacion IS NULL, con o sin producto) de un rango.
CREATE FUNCTION pg_temp._rf_sin_costo(p_desde date, p_hasta date, p_sucs bigint[], p_sin_bonif boolean)
RETURNS TABLE (usuario_id uuid, productos bigint, subtotal numeric, ingreso_real numeric)
LANGUAGE sql STABLE AS $f$
  SELECT p.usuario_id, count(DISTINCT COALESCE(pi.producto_id, -1)),
         COALESCE(sum(pi.subtotal), 0),
         COALESCE(sum(pi.cantidad * COALESCE(pi.ingreso_real_unitario,
           CASE WHEN COALESCE(p.tipo_factura, 'ZZ') = 'FC' THEN COALESCE(pi.neto_unitario, pi.precio_unitario)
                ELSE pi.precio_unitario END)), 0)
    FROM pedidos p
    JOIN pedido_items pi ON pi.pedido_id = p.id
    LEFT JOIN productos prod ON prod.id = pi.producto_id
   WHERE p.estado = 'entregado' AND p.canal <> 'cambio' AND p.tipo_factura IS DISTINCT FROM 'VB'
     AND p.fecha BETWEEN p_desde AND p_hasta AND p.sucursal_id = ANY(p_sucs)
     AND (NOT p_sin_bonif OR pi.es_bonificacion IS NOT TRUE)
     AND public.costo_valuacion(pi.costo_unitario_al_crear, prod.costo_promedio, prod.costo_real,
                                prod.costo_sin_iva, prod.impuestos_internos) IS NULL
   GROUP BY p.usuario_id
$f$;

-- Saca la foto de las 11 funciones.
CREATE FUNCTION pg_temp._rf_fotografiar(p_etapa text) RETURNS integer
LANGUAGE plpgsql AS $f$
DECLARE
  v_admin   uuid := pg_temp._rf_admin();
  v_claims  text := current_setting('request.jwt.claims', true);
  v_headers text := current_setting('request.headers', true);
  v_hoy     date := public._tablero_hoy();
  v_r       record;
  v_suc     bigint;
  v_per     date;
  v_prev    uuid;
  v_cod     text;
  v_n       integer;
BEGIN
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'mig 410 · el ensayo necesita un admin con al menos una sucursal activa asignada';
  END IF;
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  FOR v_r IN SELECT * FROM pg_temp._rf_rangos() LOOP
    FOR v_suc IN
      SELECT NULL::bigint
      UNION ALL
      (SELECT s.id FROM sucursales s
         JOIN usuario_sucursales us ON us.sucursal_id = s.id AND us.usuario_id = v_admin
        WHERE s.activa ORDER BY s.id)
    LOOP
      INSERT INTO _rf_foto (etapa, fn, rango, desde, hasta, suc, extra, valor) VALUES
        (p_etapa, 'reporte_gerencial', v_r.rango, v_r.desde, v_r.hasta, v_suc, 'comparar',
           public.reporte_gerencial(v_suc, v_r.desde, v_r.hasta, false, true)),
        (p_etapa, 'reporte_gerencial', v_r.rango, v_r.desde, v_r.hasta, v_suc, 'no_entregados',
           public.reporte_gerencial(v_suc, v_r.desde, v_r.hasta, true, false)),
        (p_etapa, 'reporte_rentabilidad', v_r.rango, v_r.desde, v_r.hasta, v_suc, '',
           public.reporte_rentabilidad(v_r.desde, v_r.hasta, v_suc)),
        (p_etapa, 'reporte_ventas_por_preventista', v_r.rango, v_r.desde, v_r.hasta, v_suc, '',
           public.reporte_ventas_por_preventista(v_r.desde, v_r.hasta, v_suc)),
        (p_etapa, 'reporte_ventas_por_cliente', v_r.rango, v_r.desde, v_r.hasta, v_suc, '',
           public.reporte_ventas_por_cliente(v_r.desde, v_r.hasta, NULL, v_suc)),
        (p_etapa, 'reporte_mermas', v_r.rango, v_r.desde, v_r.hasta, v_suc, '',
           public.reporte_mermas(v_r.desde, v_r.hasta, v_suc)),
        (p_etapa, 'reporte_alerta_detalle', v_r.rango, v_r.desde, v_r.hasta, v_suc, 'productos_sin_costo',
           public.reporte_alerta_detalle(v_suc, 'productos_sin_costo', v_r.desde, v_r.hasta, false));
    END LOOP;
  END LOOP;

  FOR v_suc IN
    SELECT NULL::bigint
    UNION ALL
    (SELECT s.id FROM sucursales s
       JOIN usuario_sucursales us ON us.sucursal_id = s.id AND us.usuario_id = v_admin
      WHERE s.activa ORDER BY s.id)
  LOOP
    -- Las dos alertas que miran el día, no el rango.
    FOREACH v_cod IN ARRAY ARRAY['cobranza_vencida', 'clientes_inactivos'] LOOP
      INSERT INTO _rf_foto (etapa, fn, rango, desde, hasta, suc, extra, valor) VALUES
        (p_etapa, 'reporte_alerta_detalle', 'hoy', NULL, NULL, v_suc, v_cod,
           public.reporte_alerta_detalle(v_suc, v_cod, NULL, NULL, false));
    END LOOP;
    INSERT INTO _rf_foto (etapa, fn, rango, desde, hasta, suc, extra, valor) VALUES
      (p_etapa, 'reporte_cuentas_por_cobrar', 'hoy', NULL, NULL, v_suc, '',
         public.reporte_cuentas_por_cobrar(v_suc));
    FOR v_per IN
      SELECT x FROM unnest(ARRAY[date_trunc('month', v_hoy)::date,
                                 (date_trunc('month', v_hoy) - interval '1 month')::date,
                                 DATE '2026-03-01']) AS x
    LOOP
      INSERT INTO _rf_foto (etapa, fn, rango, desde, hasta, suc, extra, valor) VALUES
        (p_etapa, 'rendimiento_preventistas', 'periodo', v_per,
           (v_per + interval '1 month - 1 day')::date, v_suc, '',
           public.rendimiento_preventistas(v_suc, v_per));
    END LOOP;
    -- Sin período: el mes de hoy.
    INSERT INTO _rf_foto (etapa, fn, rango, desde, hasta, suc, extra, valor) VALUES
      (p_etapa, 'rendimiento_preventistas', 'sin_periodo', date_trunc('month', v_hoy)::date,
         (date_trunc('month', v_hoy) + interval '1 month - 1 day')::date, v_suc, '',
         public.rendimiento_preventistas(v_suc, NULL));
  END LOOP;

  -- Deudores en mora: por la sucursal del header.
  FOR v_suc IN
    SELECT s.id FROM sucursales s
      JOIN usuario_sucursales us ON us.sucursal_id = s.id AND us.usuario_id = v_admin
     WHERE s.activa ORDER BY s.id
  LOOP
    PERFORM set_config('request.headers',
                       json_build_object('x-sucursal-id', v_suc::text)::text, true);
    INSERT INTO _rf_foto (etapa, fn, rango, desde, hasta, suc, extra, valor) VALUES
      (p_etapa, 'obtener_deudores_mora', 'hoy', NULL, NULL, v_suc, '',
         (SELECT COALESCE(jsonb_agg(to_jsonb(m)), '[]'::jsonb) FROM public.obtener_deudores_mora(1) m));
  END LOOP;

  -- Metas: cada preventista con metas activas, este mes y los dos anteriores,
  -- y sin período.
  FOR v_prev IN
    SELECT DISTINCT preventista_id FROM metas_preventista WHERE activo ORDER BY 1
  LOOP
    FOR v_per IN
      SELECT (date_trunc('month', v_hoy) - make_interval(months => k))::date
        FROM generate_series(0, 2) AS k
    LOOP
      INSERT INTO _rf_foto (etapa, fn, rango, desde, hasta, suc, extra, valor) VALUES
        (p_etapa, 'avance_metas_preventista', 'periodo', v_per, NULL, NULL, v_prev::text,
           public.avance_metas_preventista(v_prev, v_per));
    END LOOP;
    INSERT INTO _rf_foto (etapa, fn, rango, desde, hasta, suc, extra, valor) VALUES
      (p_etapa, 'avance_metas_preventista', 'sin_periodo', NULL, NULL, NULL, v_prev::text,
         public.avance_metas_preventista(v_prev, NULL));
  END LOOP;

  -- Como servidor (auth.uid() NULL): el bot, el cron y los gates de CI.
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.headers', '', true);
  INSERT INTO _rf_foto (etapa, fn, rango, desde, hasta, suc, extra, valor)
  SELECT p_etapa, 'reporte_gerencial', r.rango, r.desde, r.hasta, NULL, 'servicio',
         public.reporte_gerencial(NULL, r.desde, r.hasta, false, true)
    FROM pg_temp._rf_rangos() r WHERE r.rango IN ('anio', 'marzo_2026');
  INSERT INTO _rf_foto (etapa, fn, rango, desde, hasta, suc, extra, valor) VALUES
    (p_etapa, 'reporte_cuentas_por_cobrar', 'hoy', NULL, NULL, NULL, 'servicio',
       public.reporte_cuentas_por_cobrar(NULL)),
    (p_etapa, 'rendimiento_preventistas', 'periodo', DATE '2026-03-01', DATE '2026-03-31', NULL, 'servicio',
       public.rendimiento_preventistas(NULL, DATE '2026-03-01')),
    (p_etapa, 'bot_metricas_admin_dia', 'hoy', v_hoy, NULL, NULL, 'servicio',
       to_jsonb(public.bot_metricas_admin_dia(v_hoy, NULL))),
    (p_etapa, 'bot_metricas_admin_dia', 'ayer', v_hoy - 1, NULL, NULL, 'servicio',
       to_jsonb(public.bot_metricas_admin_dia(v_hoy - 1, NULL)));
  INSERT INTO _rf_foto (etapa, fn, rango, desde, hasta, suc, extra, valor)
  SELECT p_etapa, 'bot_metricas_admin_dia', 'hoy', v_hoy, NULL, s.id, 'servicio',
         to_jsonb(public.bot_metricas_admin_dia(v_hoy, s.id))
    FROM sucursales s WHERE s.activa;

  PERFORM set_config('request.jwt.claims', COALESCE(v_claims, ''), true);
  PERFORM set_config('request.headers',    COALESCE(v_headers, ''), true);

  SELECT count(*) INTO v_n FROM _rf_foto WHERE etapa = p_etapa;
  RETURN v_n;
END
$f$;

SELECT pg_temp._rf_fotografiar('antes');

-- ---------------------------------------------------------------------------
-- 2 · _sucursales_red(): la Red de los reportes (#1262, REP-8)
-- ---------------------------------------------------------------------------
-- "Red" es UNA sola cosa en todos los reportes: las sucursales ACTIVAS que el
-- usuario tiene asignadas; para el servidor (auth.uid() NULL: bot, cron, CI),
-- todas las activas. Antes la mitad de los reportes usaba "las asignadas,
-- activas o no" (o todas las sucursales, para el servidor) y la otra mitad
-- esto, y dos números de la Red podían no cerrar entre sí sin que ninguno
-- estuviera mal. Un reporte que acepte p_sucursal_id NULL como Red llama a
-- esta función; el guard de rol y de pertenencia sigue siendo de cada reporte.
CREATE FUNCTION public._sucursales_red()
RETURNS bigint[]
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
  SELECT array_agg(s.id ORDER BY s.id)
    FROM sucursales s
   WHERE s.activa
     AND (auth.uid() IS NULL
          OR s.id IN (SELECT us.sucursal_id FROM usuario_sucursales us
                       WHERE us.usuario_id = auth.uid()));
$function$;

REVOKE ALL ON FUNCTION public._sucursales_red() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._sucursales_red() TO service_role;

-- ---------------------------------------------------------------------------
-- 3 · Los parches. Cada ancla tiene que aparecer exactamente las veces
--     indicadas en el cuerpo vivo (verificado por md5 en el paso 0).
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _rf_parche (
  firma     text NOT NULL,
  orden     int  NOT NULL,
  veces     int  NOT NULL DEFAULT 1,
  ancla     text NOT NULL,
  reemplazo text NOT NULL
) ON COMMIT DROP;

-- 3.1 · reporte_gerencial ---------------------------------------------------
INSERT INTO _rf_parche (firma, orden, ancla, reemplazo) VALUES
('public.reporte_gerencial(bigint,date,date,boolean,boolean)', 1,
$a$  v_formas_no_din text[] := ARRAY['nota_credito', 'adelanto_sueldo'];
BEGIN
$a$,
$r$  v_formas_no_din text[] := ARRAY['nota_credito', 'adelanto_sueldo'];
  -- #1250: el día argentino. CURRENT_DATE es UTC: pasadas las 21 ya es mañana.
  v_hoy date := public._tablero_hoy();
BEGIN
$r$),
('public.reporte_gerencial(bigint,date,date,boolean,boolean)', 2,
$a$    SELECT array_agg(id) INTO v_sucursales FROM sucursales WHERE activa;
    IF NOT v_es_servicio THEN
      SELECT array_agg(s) INTO v_sucursales FROM unnest(v_sucursales) AS s WHERE s = ANY(v_asignadas); END IF;
$a$,
$r$    v_sucursales := public._sucursales_red();  -- #1262 (REP-8)
$r$),
('public.reporte_gerencial(bigint,date,date,boolean,boolean)', 3,
$a$           prod.nombre AS prod_nombre,
           COALESCE(NULLIF(prod.categoria,''),'(sin categoría)') AS categoria,
$a$,
$r$           -- #1262 (REP-1): la línea de un producto borrado sigue siendo venta.
           COALESCE(prod.nombre, '(producto borrado)') AS prod_nombre,
           CASE WHEN prod.id IS NULL THEN '(producto borrado)'
                ELSE COALESCE(NULLIF(prod.categoria,''),'(sin categoría)') END AS categoria,
$r$),
('public.reporte_gerencial(bigint,date,date,boolean,boolean)', 4,
$a$    JOIN productos prod ON prod.id = pi.producto_id
    LEFT JOIN promociones pr ON pr.id = pi.promocion_id
$a$,
$r$    -- #1262 (REP-1): LEFT. Con la FK en ON DELETE SET NULL quedaron líneas sin
    -- producto, y con JOIN salían de categorías, CMV, unidades, sin costo y
    -- vendedores mientras kpis.venta (de `pedidos`) las seguía contando: su
    -- ingreso entraba a los márgenes a costo 0 y sin la marca de "sin costo".
    -- Sin producto, la cascada da el costo congelado de la línea o NULL.
    LEFT JOIN productos prod ON prod.id = pi.producto_id
    LEFT JOIN promociones pr ON pr.id = pi.promocion_id
$r$),
('public.reporte_gerencial(bigint,date,date,boolean,boolean)', 5,
$a$  mensual AS (SELECT mp.mes, mp.pedidos, mp.venta, mp.venta_real, mp.clientes, mp.ticket,
      COALESCE(mi.cmv,0) AS cmv, COALESCE(mi.bonif,0) AS bonif,
      (mp.venta_real - COALESCE(mi.cmv,0) + COALESCE(md.descuentos,0)) AS margen_real,
$a$,
$r$  -- #1262 (REP-6): los meses salen de un calendario, no de los meses con venta.
  -- Un mes con compras, mermas o notas de crédito pero sin ventas entregadas
  -- desaparecía y Σ mensual.compras (la hoja "Compras" del Excel) dejaba de
  -- cerrar contra kpis.compras. El calendario llega hasta hoy (los meses que
  -- ya empezaron, aunque estén vacíos); después de hoy entra sólo el mes que
  -- tenga algo, para no pintar en cero los meses que todavía no llegaron.
  meses AS (SELECT to_char(m, 'YYYY-MM') AS mes
      FROM generate_series(date_trunc('month', p_desde::timestamp),
                           date_trunc('month', LEAST(p_hasta, v_hoy)::timestamp),
                           interval '1 month') AS m
    UNION SELECT mes FROM m_ped UNION SELECT mes FROM m_merma UNION SELECT mes FROM m_compra
    UNION SELECT mes FROM m_desc UNION SELECT mes FROM m_ncv),
  mensual AS (SELECT ms.mes, COALESCE(mp.pedidos,0) AS pedidos, COALESCE(mp.venta,0) AS venta,
      COALESCE(mp.venta_real,0) AS venta_real, COALESCE(mp.clientes,0) AS clientes,
      COALESCE(mp.ticket,0) AS ticket,
      COALESCE(mi.cmv,0) AS cmv, COALESCE(mi.bonif,0) AS bonif,
      (COALESCE(mp.venta_real,0) - COALESCE(mi.cmv,0) + COALESCE(md.descuentos,0)) AS margen_real,
$r$),
('public.reporte_gerencial(bigint,date,date,boolean,boolean)', 6,
$a$    FROM m_ped mp LEFT JOIN m_it mi ON mi.mes=mp.mes LEFT JOIN m_merma mm ON mm.mes=mp.mes LEFT JOIN m_compra mc ON mc.mes=mp.mes LEFT JOIN m_desc md ON md.mes=mp.mes LEFT JOIN m_ncv mnv ON mnv.mes=mp.mes),
$a$,
$r$    FROM meses ms LEFT JOIN m_ped mp ON mp.mes=ms.mes LEFT JOIN m_it mi ON mi.mes=ms.mes LEFT JOIN m_merma mm ON mm.mes=ms.mes LEFT JOIN m_compra mc ON mc.mes=ms.mes LEFT JOIN m_desc md ON md.mes=ms.mes LEFT JOIN m_ncv mnv ON mnv.mes=ms.mes),
$r$),
('public.reporte_gerencial(bigint,date,date,boolean,boolean)', 7,
$a$  vendedores AS (SELECT pf.id, pf.nombre, pf.rol, e.pedidos, e.venta, e.venta_real, e.margen_comercial, e.margen_real, e.bonif,
      COALESCE(n.base_nc, e.venta) AS base_nc
    FROM v_ent e JOIN perfiles pf ON pf.id=e.usuario_id LEFT JOIN v_nc n ON n.usuario_id=e.usuario_id),
$a$,
$r$  -- #1262 (REP-2): LEFT. Un pedido sin usuario_id (hay dos de marzo) quedaba
  -- fuera de la lista y Σ vendedores no cerraba contra la venta. Va como
  -- "(sin vendedor)", con id NULL y base de comisión 0: nadie cobra por él
  -- (`nc` ya lo dejaba fuera de kpis.base_comision).
  vendedores AS (SELECT e.usuario_id AS id, COALESCE(pf.nombre, '(sin vendedor)') AS nombre, pf.rol,
      e.pedidos, e.venta, e.venta_real, e.margen_comercial, e.margen_real, e.bonif,
      CASE WHEN pf.id IS NULL THEN 0 ELSE COALESCE(n.base_nc, e.venta) END AS base_nc
    FROM v_ent e LEFT JOIN perfiles pf ON pf.id=e.usuario_id LEFT JOIN v_nc n ON n.usuario_id=e.usuario_id),
$r$),
('public.reporte_gerencial(bigint,date,date,boolean,boolean)', 8,
$a$    AND fecha < CURRENT_DATE - 30 AND total > COALESCE(monto_pagado,0);
$a$,
$r$    AND fecha < v_hoy - 30 AND total > COALESCE(monto_pagado,0);  -- #1250
$r$),
('public.reporte_gerencial(bigint,date,date,boolean,boolean)', 9,
$a$    HAVING MAX(p.fecha) < CURRENT_DATE - 30 AND MAX(p.fecha) >= CURRENT_DATE - 90
$a$,
$r$    HAVING MAX(p.fecha) < v_hoy - 30 AND MAX(p.fecha) >= v_hoy - 90  -- #1250
$r$);

-- 3.2 · reporte_alerta_detalle ----------------------------------------------
INSERT INTO _rf_parche (firma, orden, ancla, reemplazo) VALUES
('public.reporte_alerta_detalle(bigint,text,date,date,boolean)', 1,
$a$  v_result jsonb;
BEGIN
$a$,
$r$  v_result jsonb;
  v_hoy date := public._tablero_hoy();  -- #1250: el día argentino, no el de UTC
BEGIN
$r$),
('public.reporte_alerta_detalle(bigint,text,date,date,boolean)', 2,
$a$    SELECT array_agg(id) INTO v_sucursales FROM sucursales WHERE activa;
    IF NOT v_es_servicio THEN
      SELECT array_agg(s) INTO v_sucursales FROM unnest(v_sucursales) AS s WHERE s = ANY(v_asignadas); END IF;
$a$,
$r$    v_sucursales := public._sucursales_red();  -- #1262 (REP-8)
$r$),
('public.reporte_alerta_detalle(bigint,text,date,date,boolean)', 3,
$a$    -- Sin filtro de periodo a proposito: la alerta es contra CURRENT_DATE - 30.
$a$,
$r$    -- Sin filtro de periodo a proposito: la alerta es contra hoy - 30.
$r$),
('public.reporte_alerta_detalle(bigint,text,date,date,boolean)', 4,
$a$'hace ' || MAX(CURRENT_DATE - p.fecha) || ' días' AS detalle
$a$,
$r$'hace ' || MAX(v_hoy - p.fecha) || ' días' AS detalle
$r$),
('public.reporte_alerta_detalle(bigint,text,date,date,boolean)', 5,
$a$        AND p.fecha < CURRENT_DATE - 30 AND p.total > COALESCE(p.monto_pagado,0)
$a$,
$r$        AND p.fecha < v_hoy - 30 AND p.total > COALESCE(p.monto_pagado,0)
$r$),
('public.reporte_alerta_detalle(bigint,text,date,date,boolean)', 6,
$a$    -- Idem: la alerta es contra CURRENT_DATE - 30/90.
$a$,
$r$    -- Idem: la alerta es contra hoy - 30/90.
$r$),
('public.reporte_alerta_detalle(bigint,text,date,date,boolean)', 7,
$a$FILTER (WHERE p.fecha >= CURRENT_DATE - 90)$a$,
$r$FILTER (WHERE p.fecha >= v_hoy - 90)$r$),
('public.reporte_alerta_detalle(bigint,text,date,date,boolean)', 8,
$a$'sin comprar hace ' || (CURRENT_DATE - MAX(p.fecha)) || ' días' AS detalle
$a$,
$r$'sin comprar hace ' || (v_hoy - MAX(p.fecha)) || ' días' AS detalle
$r$),
('public.reporte_alerta_detalle(bigint,text,date,date,boolean)', 9,
$a$         AND MAX(p.fecha) < CURRENT_DATE - 30 AND MAX(p.fecha) >= CURRENT_DATE - 90
$a$,
$r$         AND MAX(p.fecha) < v_hoy - 30 AND MAX(p.fecha) >= v_hoy - 90
$r$),
('public.reporte_alerta_detalle(bigint,text,date,date,boolean)', 10,
$a$      SELECT prod.nombre AS nombre, SUM(pi.subtotal) AS valor, 'sin costo cargado' AS detalle
      FROM pedido_items pi JOIN pedidos p ON p.id = pi.pedido_id JOIN productos prod ON prod.id = pi.producto_id
$a$,
$r$      -- #1262: LEFT, como el `it` de reporte_gerencial. La línea de un producto
      -- borrado sin costo congelado está en el KPI y tiene que estar acá.
      SELECT COALESCE(prod.nombre, '(producto borrado)') AS nombre, SUM(pi.subtotal) AS valor,
             CASE WHEN prod.id IS NULL THEN 'producto borrado' ELSE 'sin costo cargado' END AS detalle
      FROM pedido_items pi JOIN pedidos p ON p.id = pi.pedido_id LEFT JOIN productos prod ON prod.id = pi.producto_id
$r$);

-- 3.3 · reporte_rentabilidad ------------------------------------------------
INSERT INTO _rf_parche (firma, orden, ancla, reemplazo) VALUES
('public.reporte_rentabilidad(date,date,bigint,text)', 1,
$a$    v_sucursales := COALESCE(v_asignadas, ARRAY(SELECT id FROM sucursales));
$a$,
$r$    v_sucursales := public._sucursales_red();  -- #1262 (REP-8)
$r$),
('public.reporte_rentabilidad(date,date,bigint,text)', 2,
$a$           prod.nombre,
           prod.codigo,
$a$,
$r$           COALESCE(prod.nombre, '(producto borrado)') AS nombre,  -- #1262 (REP-1)
           prod.codigo,
$r$),
('public.reporte_rentabilidad(date,date,bigint,text)', 3,
$a$           pi.cantidad * COALESCE(
             pi.costo_unitario_al_crear,
             prod.costo_promedio,
             prod.costo_real,
             ROUND(prod.costo_sin_iva * (1 + COALESCE(prod.impuestos_internos,0)/100), 4)
           ) AS costo
$a$,
$r$           -- #1262 (REP-7): la cascada es costo_valuacion, no una copia (a la
           -- copia le faltaba el NULLIF de costo_sin_iva = 0). NULL = sin costo.
           pi.cantidad * public.costo_valuacion(pi.costo_unitario_al_crear, prod.costo_promedio,
             prod.costo_real, prod.costo_sin_iva, prod.impuestos_internos) AS costo
$r$),
('public.reporte_rentabilidad(date,date,bigint,text)', 4,
$a$    JOIN productos prod ON prod.id = pi.producto_id
$a$,
$r$    LEFT JOIN productos prod ON prod.id = pi.producto_id  -- #1262 (REP-1)
$r$),
('public.reporte_rentabilidad(date,date,bigint,text)', 5,
$a$           SUM(COALESCE(it.costo,0)) FILTER (WHERE NOT it.en_combo) AS cos_fuera
$a$,
$r$           SUM(COALESCE(it.costo,0)) FILTER (WHERE NOT it.en_combo) AS cos_fuera,
           -- #1262 (REP-7): "sin costo" es costo_valuacion IS NULL. Su costo
           -- sigue contando 0, pero ahora se marca.
           bool_or(it.costo IS NULL) AS sin_costo,
           SUM(it.ingreso_real) FILTER (WHERE it.costo IS NULL) AS ing_sin_costo
$r$),
('public.reporte_rentabilidad(date,date,bigint,text)', 6,
$a$        'codigo',           pp.codigo,
$a$,
$r$        'codigo',           pp.codigo,
        'sinCosto',         pp.sin_costo,
$r$),
('public.reporte_rentabilidad(date,date,bigint,text)', 7,
$a$        'ventasNetas',       (SELECT COALESCE(ROUND(SUM(neto),2),0) FROM it)
$a$,
$r$        'ventasNetas',       (SELECT COALESCE(ROUND(SUM(neto),2),0) FROM it),
        'ingresosSinCosto',  COALESCE(ROUND(SUM(ing_sin_costo),2),0)
$r$);

-- 3.4 · rendimiento_preventistas --------------------------------------------
INSERT INTO _rf_parche (firma, orden, ancla, reemplazo) VALUES
('public.rendimiento_preventistas(bigint,date)', 1,
$a$COALESCE(p_periodo, current_date)$a$,
$r$COALESCE(p_periodo, public._tablero_hoy())$r$),  -- #1250
('public.rendimiento_preventistas(bigint,date)', 2,
$a$  IF p_sucursal_id IS NULL THEN
    v_sucursales := v_asignadas;
$a$,
$r$  IF p_sucursal_id IS NULL THEN
    v_sucursales := public._sucursales_red();  -- #1262 (REP-8)
$r$),
('public.rendimiento_preventistas(bigint,date)', 3,
$a$pi.cantidad * COALESCE(pi.costo_unitario_al_crear, prod.costo_promedio, prod.costo_real,
             prod.costo_sin_iva * (1 + COALESCE(prod.impuestos_internos, 0) / 100)) AS costo,
$a$,
$r$-- #1262 (REP-7): costo_valuacion, no una copia. NULL = sin costo.
           pi.cantidad * public.costo_valuacion(pi.costo_unitario_al_crear, prod.costo_promedio,
             prod.costo_real, prod.costo_sin_iva, prod.impuestos_internos) AS costo,
$r$),
('public.rendimiento_preventistas(bigint,date)', 4,
$a$COALESCE(NULLIF(prod.categoria, ''), '(sin categoría)') AS categoria
$a$,
$r$CASE WHEN prod.id IS NULL THEN '(producto borrado)'
                ELSE COALESCE(NULLIF(prod.categoria, ''), '(sin categoría)') END AS categoria
$r$),
('public.rendimiento_preventistas(bigint,date)', 5,
$a$    JOIN productos prod  ON prod.id = pi.producto_id
$a$,
$r$    LEFT JOIN productos prod ON prod.id = pi.producto_id  -- #1262 (REP-1)
$r$),
('public.rendimiento_preventistas(bigint,date)', 6,
$a$           COALESCE(SUM(i.subtotal - i.costo), 0) AS margen_comercial
$a$,
$r$           COALESCE(SUM(i.subtotal - i.costo), 0) AS margen_comercial,
           -- #1262 (REP-7): la venta sin costo, que el margen deja fuera.
           COALESCE(SUM(i.subtotal) FILTER (WHERE i.costo IS NULL), 0) AS venta_sin_costo
$r$),
('public.rendimiento_preventistas(bigint,date)', 7,
$a$      'margen_comercial', COALESCE(i.margen_comercial, 0),
$a$,
$r$      'margen_comercial', COALESCE(i.margen_comercial, 0),
      'venta_sin_costo', COALESCE(i.venta_sin_costo, 0),
$r$);

-- 3.5 · avance_metas_preventista --------------------------------------------
INSERT INTO _rf_parche (firma, orden, veces, ancla, reemplazo) VALUES
('public.avance_metas_preventista(uuid,date)', 1, 1,
$a$  v_hay_marca   boolean := false;
BEGIN
$a$,
$r$  v_hay_marca   boolean := false;
  v_hoy         date := public._tablero_hoy();  -- #1250: el día argentino
BEGIN
$r$),
('public.avance_metas_preventista(uuid,date)', 2, 1,
$a$COALESCE(p_periodo, current_date)$a$,
$r$COALESCE(p_periodo, v_hoy)$r$),
('public.avance_metas_preventista(uuid,date)', 3, 2,
$a$LEAST(EXTRACT(DAY FROM current_date)::int,$a$,
$r$LEAST(EXTRACT(DAY FROM v_hoy)::int,$r$),
('public.avance_metas_preventista(uuid,date)', 4, 1,
$a$LEAST(current_date - m.periodo + 1,$a$,
$r$LEAST(v_hoy - m.periodo + 1,$r$),
('public.avance_metas_preventista(uuid,date)', 5, 1,
$a$    JOIN productos prod  ON prod.id = pi.producto_id
$a$,
$r$    -- #1262: LEFT. La línea de un producto borrado suma a las metas globales.
    LEFT JOIN productos prod ON prod.id = pi.producto_id
$r$);

-- 3.6 · reporte_cuentas_por_cobrar ------------------------------------------
INSERT INTO _rf_parche (firma, orden, veces, ancla, reemplazo) VALUES
('public.reporte_cuentas_por_cobrar(bigint)', 1, 1,
$a$  v_out         jsonb;
BEGIN
$a$,
$r$  v_out         jsonb;
  v_hoy         date := public._tablero_hoy();  -- #1250: el día argentino
BEGIN
$r$),
('public.reporte_cuentas_por_cobrar(bigint)', 2, 1,
$a$    v_sucursales := COALESCE(v_asignadas, ARRAY(SELECT id FROM sucursales));
$a$,
$r$    v_sucursales := public._sucursales_red();  -- #1262 (REP-8)
$r$),
('public.reporte_cuentas_por_cobrar(bigint)', 3, 3,
$a$(CURRENT_DATE - (cs.base_mora$a$,
$r$(v_hoy - (cs.base_mora$r$);

-- 3.7 · obtener_deudores_mora -----------------------------------------------
INSERT INTO _rf_parche (firma, orden, ancla, reemplazo) VALUES
('public.obtener_deudores_mora(integer)', 1,
$a$  v_sucursal_id bigint;
BEGIN
$a$,
$r$  v_sucursal_id bigint;
  v_hoy         date := public._tablero_hoy();  -- #1250
BEGIN
$r$),
('public.obtener_deudores_mora(integer)', 2,
$a$      COALESCE(p.fecha_entrega::date, p.fecha) AS base_date,
      (CURRENT_DATE
        - (COALESCE(p.fecha_entrega::date, p.fecha) + COALESCE(c.dias_credito, 30)))::int AS dias_mora
$a$,
$r$      -- #1250: el día argentino de los dos lados. `fecha_entrega::date` corta en
      -- UTC (una entrega a las 22 caía al día siguiente) y CURRENT_DATE también.
      -- El mismo corte que reporte_cuentas_por_cobrar.
      COALESCE((p.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date, p.fecha) AS base_date,
      (v_hoy
        - (COALESCE((p.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date, p.fecha)
           + COALESCE(c.dias_credito, 30)))::int AS dias_mora
$r$);

-- 3.8 · bot_metricas_admin_dia (SQL: sin variables, se llama a la función) ---
INSERT INTO _rf_parche (firma, orden, ancla, reemplazo) VALUES
('public.bot_metricas_admin_dia(date,bigint)', 1,
$a$MAX(CURRENT_DATE - r.fecha)$a$,
$r$MAX(public._tablero_hoy() - r.fecha)$r$),
('public.bot_metricas_admin_dia(date,bigint)', 2,
$a$      AND r.fecha < CURRENT_DATE - INTERVAL '2 days'
$a$,
$r$      AND r.fecha < public._tablero_hoy() - INTERVAL '2 days'  -- #1250: el día argentino
$r$),
('public.bot_metricas_admin_dia(date,bigint)', 3,
$a$    WHERE fecha = CURRENT_DATE
$a$,
$r$    WHERE fecha = public._tablero_hoy()  -- #1250
$r$);

-- 3.9 · La Red de los otros tres ---------------------------------------------
INSERT INTO _rf_parche (firma, orden, ancla, reemplazo) VALUES
('public.reporte_ventas_por_preventista(date,date,bigint)', 1,
$a$    v_sucursales := COALESCE(v_asignadas, ARRAY(SELECT id FROM sucursales));
$a$,
$r$    v_sucursales := public._sucursales_red();  -- #1262 (REP-8)
$r$),
('public.reporte_ventas_por_cliente(date,date,uuid,bigint)', 1,
$a$    SELECT array_agg(id) INTO v_sucursales FROM sucursales WHERE activa;
    IF NOT v_es_servicio THEN
      SELECT array_agg(s) INTO v_sucursales
        FROM unnest(v_sucursales) AS s WHERE s = ANY(v_asignadas);
    END IF;
$a$,
$r$    v_sucursales := public._sucursales_red();  -- #1262 (REP-8)
$r$),
('public.reporte_mermas(date,date,bigint,text,integer,integer,text)', 1,
$a$    SELECT array_agg(id) INTO v_sucursales FROM sucursales WHERE activa;
    IF NOT v_es_servicio THEN
      SELECT array_agg(s) INTO v_sucursales FROM unnest(v_sucursales) AS s WHERE s = ANY(v_asignadas);
    END IF;
$a$,
$r$    -- #1262 (REP-8): la misma función que usa el gerencial, no una copia.
    v_sucursales := public._sucursales_red();
$r$);

DO $parches$
DECLARE
  v_f   record;
  v_p   record;
  v_def text;
  v_n   int;
BEGIN
  FOR v_f IN SELECT DISTINCT firma FROM _rf_parche ORDER BY firma LOOP
    v_def := pg_get_functiondef(v_f.firma::regprocedure);
    FOR v_p IN SELECT * FROM _rf_parche WHERE firma = v_f.firma ORDER BY orden LOOP
      v_n := (length(v_def) - length(replace(v_def, v_p.ancla, ''))) / length(v_p.ancla);
      IF v_n <> v_p.veces THEN
        RAISE EXCEPTION 'mig 410 · % parche %: el ancla aparece % vez/veces y se esperaba %',
          v_f.firma, v_p.orden, v_n, v_p.veces;
      END IF;
      v_def := replace(v_def, v_p.ancla, v_p.reemplazo);
    END LOOP;
    EXECUTE v_def;
  END LOOP;
END
$parches$;

-- ---------------------------------------------------------------------------
-- 4 · auditoria_fechas_utc(): el gate de #1250
-- ---------------------------------------------------------------------------
-- Las funciones y los defaults de columna de `public` que miran el día del
-- servidor (UTC) en vez del argentino: CURRENT_DATE, LOCALTIMESTAMP,
-- LOCALTIME, now()::date, CURRENT_TIMESTAMP::date. Se buscan en el código, sin
-- comentarios ni literales de texto (un comentario que explica por qué NO se
-- usa no cuenta). Lo llama scripts/check-fechas-utc.mjs con service_role, que
-- falla ante lo que no esté en scripts/fechas-utc-permitidas.json. El día
-- argentino es `_tablero_hoy()`; en un default de columna, el mismo
-- `(now() AT TIME ZONE 'America/Argentina/Tucuman')::date` inline.
CREATE FUNCTION public.auditoria_fechas_utc()
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  WITH pat(nombre, re) AS (VALUES
    ('CURRENT_DATE',            '\mcurrent_date\M'),
    ('LOCALTIMESTAMP',          '\mlocaltimestamp\M'),
    ('LOCALTIME',               '\mlocaltime\M'),
    ('now()::date',             'now\(\)\s*::\s*date\M'),
    ('CURRENT_TIMESTAMP::date', '\mcurrent_timestamp\s*::\s*date\M')
  ),
  fn AS (
    -- Sin comentarios de bloque, de línea ni literales, en ese orden. El de
    -- línea se escribe -{2} para que este mismo cuerpo no se corte solo.
    SELECT p.proname::text AS nombre, p.oid::regprocedure::text AS firma,
           regexp_replace(
             regexp_replace(
               regexp_replace(p.prosrc, '/\*.*?\*/', ' ', 'g'),
               '-{2}[^\n]*', ' ', 'g'),
             '''[^'']*''', ' ', 'g') AS src
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      JOIN pg_language l ON l.oid = p.prolang
     WHERE n.nspname = 'public' AND p.prokind IN ('f', 'p')
       AND l.lanname IN ('sql', 'plpgsql')
       AND NOT EXISTS (SELECT 1 FROM pg_depend d
                        WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
  ),
  hallazgos AS (
    SELECT fn.nombre, fn.firma, array_agg(pat.nombre ORDER BY pat.nombre) AS patrones
      FROM fn JOIN pat ON fn.src ~* pat.re
     GROUP BY fn.nombre, fn.firma
  ),
  defaults AS (
    SELECT c.relname || '.' || a.attname AS columna, pg_get_expr(ad.adbin, ad.adrelid) AS expr
      FROM pg_attrdef ad
      JOIN pg_class c ON c.oid = ad.adrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_attribute a ON a.attrelid = ad.adrelid AND a.attnum = ad.adnum
     WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
       AND EXISTS (SELECT 1 FROM pat WHERE pg_get_expr(ad.adbin, ad.adrelid) ~* pat.re)
  )
  SELECT jsonb_build_object(
    'generado_at', now(),
    'total_funciones', (SELECT count(*) FROM fn),
    'funciones', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                    'nombre', h.nombre, 'firma', h.firma, 'patrones', to_jsonb(h.patrones))
                    ORDER BY h.nombre, h.firma) FROM hallazgos h), '[]'::jsonb),
    'defaults', COALESCE((SELECT jsonb_agg(jsonb_build_object('columna', d.columna, 'default', d.expr)
                    ORDER BY d.columna) FROM defaults d), '[]'::jsonb)
  );
$function$;

REVOKE ALL ON FUNCTION public.auditoria_fechas_utc() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auditoria_fechas_utc() TO service_role;

-- ---------------------------------------------------------------------------
-- 5 · Ensayo: lo que no tiene que moverse no se mueve, y lo que se mueve es
--     exactamente lo de #1262.
-- ---------------------------------------------------------------------------
SELECT pg_temp._rf_fotografiar('despues');

-- Suma un campo numérico de los elementos de un array jsonb.
CREATE FUNCTION pg_temp._rf_suma(j jsonb, campo text) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $f$
  SELECT COALESCE(sum((e->>campo)::numeric), 0) FROM jsonb_array_elements(COALESCE(j, '[]'::jsonb)) e
$f$;

-- Los elementos de un array jsonb cuyo `campo` NO es `valor`, en su orden.
CREATE FUNCTION pg_temp._rf_sin(j jsonb, campo text, valor text) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $f$
  SELECT COALESCE(jsonb_agg(e ORDER BY o), '[]'::jsonb)
    FROM jsonb_array_elements(COALESCE(j, '[]'::jsonb)) WITH ORDINALITY t(e, o)
   WHERE (e->>campo) IS DISTINCT FROM valor
$f$;

-- El elemento de un array jsonb cuyo `campo` es `valor` (NULL = el de campo nulo).
CREATE FUNCTION pg_temp._rf_uno(j jsonb, campo text, valor text) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $f$
  SELECT e FROM jsonb_array_elements(COALESCE(j, '[]'::jsonb)) e
   WHERE (e->>campo) IS NOT DISTINCT FROM valor
   LIMIT 1
$f$;

CREATE FUNCTION pg_temp._rf_dif(a jsonb, b jsonb, campo text) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $f$
  SELECT COALESCE((b->>campo)::numeric, 0) - COALESCE((a->>campo)::numeric, 0)
$f$;

-- reporte_gerencial: una llamada.
CREATE FUNCTION pg_temp._rf_ver_gerencial(p_rango text, p_desde date, p_hasta date, p_suc bigint,
                                          p_extra text, a jsonb, d jsonb)
RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE
  v_tol  constant numeric := 0.005;
  v_tag  text := format('[gerencial %s %s %s]', p_rango, COALESCE(p_suc::text, 'red'), p_extra);
  v_est  text[] := CASE WHEN p_extra = 'no_entregados'
                        THEN ARRAY['entregado','asignado','pendiente','en_preparacion']
                        ELSE ARRAY['entregado'] END;
  v_sucs bigint[] := pg_temp._rf_sucs(p_suc, p_extra = 'servicio');
  f      text := '';
  o      record;
  op     record;
  sv     record;
  u      record;
  e      jsonb;
  x      jsonb;
  y      jsonb;
  v_isc  numeric;
  v_pct  numeric;
BEGIN
  SELECT COALESCE(sum(h.lineas), 0) AS lineas, COALESCE(sum(h.cantidad), 0) AS cantidad,
         COALESCE(sum(h.subtotal), 0) AS subtotal, COALESCE(sum(h.ingreso_real), 0) AS ingreso_real
    INTO o FROM pg_temp._rf_huerfanas(p_desde, p_hasta, v_sucs, v_est) h;
  SELECT count(DISTINCT p.id) AS pedidos, COALESCE(sum(pi.subtotal), 0) AS venta
    INTO sv
    FROM pedidos p JOIN pedido_items pi ON pi.pedido_id = p.id
   WHERE p.usuario_id IS NULL
     AND p.estado = ANY(v_est) AND p.canal <> 'cambio' AND p.tipo_factura IS DISTINCT FROM 'VB'
     AND p.fecha BETWEEN p_desde AND p_hasta AND p.sucursal_id = ANY(v_sucs);

  -- kpis: suben las unidades y la venta sin costo, y nada más.
  IF abs(pg_temp._rf_dif(a->'kpis', d->'kpis', 'unidades') - o.cantidad) > v_tol THEN
    f := f || format(' %s kpis.unidades %s -> %s, esperado +%s', v_tag, a->'kpis'->'unidades', d->'kpis'->'unidades', o.cantidad);
  END IF;
  IF abs(pg_temp._rf_dif(a->'kpis', d->'kpis', 'ingreso_sin_costo') - o.subtotal) > v_tol THEN
    f := f || format(' %s kpis.ingreso_sin_costo %s -> %s, esperado +%s', v_tag,
                     a->'kpis'->'ingreso_sin_costo', d->'kpis'->'ingreso_sin_costo', o.subtotal);
  END IF;
  IF (a->'kpis') - 'unidades' - 'ingreso_sin_costo' IS DISTINCT FROM (d->'kpis') - 'unidades' - 'ingreso_sin_costo' THEN
    f := f || format(' %s kpis cambió fuera de unidades / ingreso_sin_costo', v_tag);
  END IF;

  -- comparativo: lo mismo, con las huérfanas del período anterior.
  IF jsonb_typeof(a->'comparativo') = 'object' THEN
    SELECT COALESCE(sum(h.cantidad), 0) AS cantidad, COALESCE(sum(h.subtotal), 0) AS subtotal
      INTO op FROM pg_temp._rf_huerfanas((p_desde - 1) - (p_hasta - p_desde), p_desde - 1, v_sucs, v_est) h;
    IF abs(pg_temp._rf_dif(a->'comparativo', d->'comparativo', 'unidades') - op.cantidad) > v_tol
       OR abs(pg_temp._rf_dif(a->'comparativo', d->'comparativo', 'ingreso_sin_costo') - op.subtotal) > v_tol THEN
      f := f || format(' %s comparativo: unidades / sin costo no subieron lo de las huérfanas del período anterior', v_tag);
    END IF;
    IF (a->'comparativo') - 'unidades' - 'ingreso_sin_costo' IS DISTINCT FROM (d->'comparativo') - 'unidades' - 'ingreso_sin_costo' THEN
      f := f || format(' %s comparativo cambió fuera de unidades / ingreso_sin_costo', v_tag);
    END IF;
  ELSIF (a->'comparativo') IS DISTINCT FROM (d->'comparativo') THEN
    f := f || format(' %s comparativo cambió', v_tag);
  END IF;

  -- flags: los del KPI, recalculados.
  v_isc := (d->'kpis'->>'ingreso_sin_costo')::numeric;
  v_pct := CASE WHEN (d->'kpis'->>'venta')::numeric > 0
                THEN round(100.0 * v_isc / (d->'kpis'->>'venta')::numeric, 1) ELSE 0 END;
  IF (d->'flags'->>'ingreso_sin_costo')::numeric <> v_isc OR (d->'flags'->>'pct_sin_costo')::numeric <> v_pct THEN
    f := f || format(' %s flags %s no son los del KPI (%s, %s%%)', v_tag, d->'flags', v_isc, v_pct);
  END IF;

  -- alertas: la de productos sin costo aparece si y sólo si pct >= 1; el resto igual.
  IF pg_temp._rf_norm(pg_temp._rf_sin(a->'alertas', 'codigo', 'productos_sin_costo'))
     IS DISTINCT FROM pg_temp._rf_norm(pg_temp._rf_sin(d->'alertas', 'codigo', 'productos_sin_costo')) THEN
    f := f || format(' %s alertas cambiaron (fuera de productos_sin_costo)', v_tag);
  END IF;
  e := pg_temp._rf_uno(d->'alertas', 'codigo', 'productos_sin_costo');
  IF (e IS NOT NULL) <> (v_pct >= 1) OR (e IS NOT NULL AND (e->>'valor')::numeric <> v_isc) THEN
    f := f || format(' %s alerta productos_sin_costo %s con pct %s%%', v_tag, e, v_pct);
  END IF;

  -- categorías: las de antes, más "(producto borrado)" con las huérfanas.
  IF pg_temp._rf_uno(a->'categorias', 'categoria', '(producto borrado)') IS NOT NULL THEN
    f := f || format(' %s ya había una categoría "(producto borrado)" antes', v_tag);
  END IF;
  IF pg_temp._rf_norm(a->'categorias')
     IS DISTINCT FROM pg_temp._rf_norm(pg_temp._rf_sin(d->'categorias', 'categoria', '(producto borrado)')) THEN
    f := f || format(' %s categorías cambiaron fuera de "(producto borrado)"', v_tag);
  END IF;
  e := pg_temp._rf_uno(d->'categorias', 'categoria', '(producto borrado)');
  IF o.lineas = 0 THEN
    IF e IS NOT NULL THEN f := f || format(' %s "(producto borrado)" sin huérfanas en el rango', v_tag); END IF;
  ELSIF e IS NULL
     OR abs((e->>'venta')::numeric - o.subtotal) > v_tol
     OR abs((e->>'venta_real')::numeric - o.ingreso_real) > v_tol
     OR abs((e->>'margen_comercial')::numeric - o.subtotal) > v_tol
     OR abs((e->>'margen_real')::numeric - o.ingreso_real) > v_tol
     OR (e->>'bonif')::numeric <> 0
     OR (e->>'sin_costo')::boolean IS NOT TRUE THEN
    f := f || format(' %s categoría "(producto borrado)" = %s, esperado venta %s, venta_real %s, sin costo', v_tag, e, o.subtotal, o.ingreso_real);
  END IF;

  -- top productos (sólo la venta, por los empates; ver la 318): los de antes,
  -- con "(producto borrado)" metido en su lugar si entra en los 10.
  x := COALESCE((SELECT jsonb_agg((t.e->>'venta')::numeric ORDER BY t.o)
                   FROM jsonb_array_elements(a->'top_productos') WITH ORDINALITY t(e, o)), '[]'::jsonb);
  y := COALESCE((SELECT jsonb_agg((t.e->>'venta')::numeric ORDER BY t.o)
                   FROM jsonb_array_elements(d->'top_productos') WITH ORDINALITY t(e, o)), '[]'::jsonb);
  e := pg_temp._rf_uno(d->'top_productos', 'nombre', '(producto borrado)');
  IF e IS NULL THEN
    IF x IS DISTINCT FROM y THEN f := f || format(' %s top_productos cambió', v_tag); END IF;
  ELSIF abs((e->>'venta')::numeric - o.subtotal) > v_tol
     -- Las ventas de después son las de antes más la del borrado, ordenadas y
     -- cortadas en 10.
     OR y IS DISTINCT FROM COALESCE((SELECT jsonb_agg(s.v ORDER BY s.v DESC)
                                       FROM (SELECT (t.v)::text::numeric AS v
                                               FROM jsonb_array_elements(x || to_jsonb(o.subtotal)) t(v)
                                              ORDER BY 1 DESC LIMIT 10) s), '[]'::jsonb) THEN
    f := f || format(' %s top_productos: después %s, esperado antes %s más %s', v_tag, y, x, o.subtotal);
  END IF;

  -- mensual: cada mes de antes, igual; los meses nuevos, sin venta; y ahora
  -- Σ mensual.compras = kpis.compras.
  FOR e IN SELECT * FROM jsonb_array_elements(a->'mensual') LOOP
    IF pg_temp._rf_norm(e) IS DISTINCT FROM pg_temp._rf_norm(pg_temp._rf_uno(d->'mensual', 'mes', e->>'mes')) THEN
      f := f || format(' %s mensual %s cambió', v_tag, e->>'mes');
    END IF;
  END LOOP;
  FOR e IN SELECT * FROM jsonb_array_elements(d->'mensual') LOOP
    IF pg_temp._rf_uno(a->'mensual', 'mes', e->>'mes') IS NULL
       AND ((e->>'pedidos')::numeric <> 0 OR (e->>'venta')::numeric <> 0) THEN
      f := f || format(' %s mensual: el mes nuevo %s tiene venta', v_tag, e->>'mes');
    END IF;
  END LOOP;
  IF abs(pg_temp._rf_suma(d->'mensual', 'compras') - (d->'kpis'->>'compras')::numeric) > v_tol THEN
    f := f || format(' %s Σ mensual.compras %s <> kpis.compras %s', v_tag,
                     pg_temp._rf_suma(d->'mensual', 'compras'), d->'kpis'->'compras');
  END IF;

  -- vendedores: cada uno sube lo de sus huérfanas; aparece "(sin vendedor)"
  -- con los pedidos sin usuario_id; y Σ vendedores = Σ categorías.
  FOR e IN SELECT * FROM jsonb_array_elements(a->'vendedores') LOOP
    x := pg_temp._rf_uno(d->'vendedores', 'id', e->>'id');
    SELECT COALESCE(sum(h.subtotal), 0) AS subtotal, COALESCE(sum(h.ingreso_real), 0) AS ingreso_real,
           COALESCE(sum(h.pedidos_solo), 0) AS pedidos_solo
      INTO u FROM pg_temp._rf_huerfanas(p_desde, p_hasta, v_sucs, v_est) h
     WHERE h.usuario_id = (e->>'id')::uuid;
    IF x IS NULL THEN
      f := f || format(' %s vendedor %s desapareció', v_tag, e->>'nombre');
    ELSIF x->'nombre' IS DISTINCT FROM e->'nombre' OR x->'rol' IS DISTINCT FROM e->'rol'
       OR x->'bonif' IS DISTINCT FROM e->'bonif'
       OR abs(pg_temp._rf_dif(e, x, 'venta') - u.subtotal) > v_tol
       OR abs(pg_temp._rf_dif(e, x, 'margen_comercial') - u.subtotal) > v_tol
       OR abs(pg_temp._rf_dif(e, x, 'venta_real') - u.ingreso_real) > v_tol
       OR abs(pg_temp._rf_dif(e, x, 'margen_real') - u.ingreso_real) > v_tol
       OR pg_temp._rf_dif(e, x, 'pedidos') <> u.pedidos_solo
       OR ((x->>'base_nc')::numeric <> (e->>'base_nc')::numeric
           AND NOT ((e->>'base_nc')::numeric = (e->>'venta')::numeric
                    AND (x->>'base_nc')::numeric = (x->>'venta')::numeric)) THEN
      f := f || format(' %s vendedor %s: %s -> %s, esperado venta +%s', v_tag, e->>'nombre', e, x, u.subtotal);
    END IF;
  END LOOP;
  FOR e IN SELECT * FROM jsonb_array_elements(d->'vendedores') LOOP
    CONTINUE WHEN e->>'id' IS NOT NULL AND pg_temp._rf_uno(a->'vendedores', 'id', e->>'id') IS NOT NULL;
    IF e->>'id' IS NULL THEN
      IF e->>'nombre' <> '(sin vendedor)' OR e->>'rol' IS NOT NULL OR (e->>'base_nc')::numeric <> 0
         OR (e->>'pedidos')::numeric <> sv.pedidos OR abs((e->>'venta')::numeric - sv.venta) > v_tol THEN
        f := f || format(' %s "(sin vendedor)" = %s, esperado %s pedidos y venta %s', v_tag, e, sv.pedidos, sv.venta);
      END IF;
    ELSE
      SELECT COALESCE(sum(h.subtotal), 0) AS subtotal, COALESCE(sum(h.pedidos_solo), 0) AS pedidos_solo
        INTO u FROM pg_temp._rf_huerfanas(p_desde, p_hasta, v_sucs, v_est) h
       WHERE h.usuario_id = (e->>'id')::uuid;
      IF u.pedidos_solo = 0 OR abs((e->>'venta')::numeric - u.subtotal) > v_tol THEN
        f := f || format(' %s vendedor nuevo %s que no es de huérfanas', v_tag, e);
      END IF;
    END IF;
  END LOOP;
  IF (sv.pedidos > 0) <> (pg_temp._rf_uno(d->'vendedores', 'id', NULL) IS NOT NULL) THEN
    f := f || format(' %s "(sin vendedor)": hay %s pedidos sin vendedor y la fila %s', v_tag, sv.pedidos,
                     CASE WHEN pg_temp._rf_uno(d->'vendedores', 'id', NULL) IS NULL THEN 'no está' ELSE 'está' END);
  END IF;
  IF abs(pg_temp._rf_suma(d->'vendedores', 'venta') - pg_temp._rf_suma(d->'categorias', 'venta')) > v_tol THEN
    f := f || format(' %s Σ vendedores %s <> Σ categorías %s', v_tag,
                     pg_temp._rf_suma(d->'vendedores', 'venta'), pg_temp._rf_suma(d->'categorias', 'venta'));
  END IF;

  -- El resto, idéntico (los top de clientes, por su venta).
  x := a - 'kpis' - 'comparativo' - 'flags' - 'alertas' - 'categorias' - 'top_productos' - 'mensual' - 'vendedores';
  y := d - 'kpis' - 'comparativo' - 'flags' - 'alertas' - 'categorias' - 'top_productos' - 'mensual' - 'vendedores';
  x := jsonb_set(x, '{top_clientes}', COALESCE((SELECT jsonb_agg(t->'venta') FROM jsonb_array_elements(x->'top_clientes') t), '[]'::jsonb));
  y := jsonb_set(y, '{top_clientes}', COALESCE((SELECT jsonb_agg(t->'venta') FROM jsonb_array_elements(y->'top_clientes') t), '[]'::jsonb));
  IF pg_temp._rf_norm(x) IS DISTINCT FROM pg_temp._rf_norm(y) THEN
    f := f || format(' %s cambió fuera de lo de #1262 (%s)', v_tag,
                     (SELECT string_agg(k, ', ') FROM jsonb_object_keys(x) k
                       WHERE pg_temp._rf_norm(x->k) IS DISTINCT FROM pg_temp._rf_norm(y->k)));
  END IF;
  RETURN f;
END
$f$;

-- reporte_rentabilidad: una llamada.
CREATE FUNCTION pg_temp._rf_ver_rentabilidad(p_rango text, p_desde date, p_hasta date, p_suc bigint, a jsonb, d jsonb)
RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE
  v_tol  constant numeric := 0.011;  -- los dos lados vienen redondeados a 2
  v_tag  text := format('[rentabilidad %s %s]', p_rango, COALESCE(p_suc::text, 'red'));
  v_sucs bigint[] := pg_temp._rf_sucs(p_suc, false);
  f      text := '';
  o      record;
  sc     record;
  e      jsonb;
  ta     jsonb := a->'totales';
  td     jsonb := d->'totales';
  v_ing  numeric;
  v_cos  numeric;
  v_nsc  bigint;
BEGIN
  SELECT COALESCE(sum(h.lineas), 0) AS lineas, COALESCE(sum(h.cantidad), 0) AS cantidad,
         COALESCE(sum(h.subtotal), 0) AS subtotal, COALESCE(sum(h.ingreso_real), 0) AS ingreso_real,
         COALESCE(sum(h.iva), 0) AS iva, COALESCE(sum(h.ii), 0) AS ii, COALESCE(sum(h.neto), 0) AS neto
    INTO o FROM pg_temp._rf_huerfanas(p_desde, p_hasta, v_sucs, ARRAY['entregado']) h;
  SELECT COALESCE(sum(s.ingreso_real), 0) AS ingreso_real
    INTO sc FROM pg_temp._rf_sin_costo(p_desde, p_hasta, v_sucs, false) s;
  -- Los productos (el borrado cuenta como uno) con alguna línea sin costo.
  SELECT count(DISTINCT COALESCE(pi.producto_id, -1)) INTO v_nsc
    FROM pedidos p
    JOIN pedido_items pi ON pi.pedido_id = p.id
    LEFT JOIN productos prod ON prod.id = pi.producto_id
   WHERE p.estado = 'entregado' AND p.canal <> 'cambio' AND p.tipo_factura IS DISTINCT FROM 'VB'
     AND p.fecha BETWEEN p_desde AND p_hasta AND p.sucursal_id = ANY(v_sucs)
     AND public.costo_valuacion(pi.costo_unitario_al_crear, prod.costo_promedio, prod.costo_real,
                                prod.costo_sin_iva, prod.impuestos_internos) IS NULL;
  IF (SELECT count(*) FROM jsonb_array_elements(d->'productos') t(e) WHERE (t.e->>'sinCosto')::boolean) <> v_nsc THEN
    f := f || format(' %s productos con sinCosto: %s, esperado %s', v_tag,
                     (SELECT count(*) FROM jsonb_array_elements(d->'productos') t(e) WHERE (t.e->>'sinCosto')::boolean), v_nsc);
  END IF;

  -- productos: los de antes (sin la marca nueva), más la fila del borrado.
  IF pg_temp._rf_uno(a->'productos', 'id', NULL) IS NOT NULL THEN
    f := f || format(' %s ya había un producto sin id antes', v_tag);
  END IF;
  IF pg_temp._rf_norm(a->'productos') IS DISTINCT FROM pg_temp._rf_norm(
       COALESCE((SELECT jsonb_agg(t.e - 'sinCosto') FROM jsonb_array_elements(d->'productos') t(e)
                  WHERE t.e->>'id' IS NOT NULL), '[]'::jsonb)) THEN
    f := f || format(' %s productos cambiaron fuera del borrado', v_tag);
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(d->'productos') t(e) WHERE NOT (t.e ? 'sinCosto')) THEN
    f := f || format(' %s hay productos sin la clave sinCosto', v_tag);
  END IF;
  e := pg_temp._rf_uno(d->'productos', 'id', NULL);
  IF o.lineas = 0 THEN
    IF e IS NOT NULL THEN f := f || format(' %s fila de borrado sin huérfanas', v_tag); END IF;
  ELSIF e IS NULL OR e->>'nombre' <> '(producto borrado)'
     OR (e->>'cantidadVendida')::numeric <> o.cantidad
     OR abs((e->>'ingresos')::numeric - o.ingreso_real) > v_tol
     OR (e->>'costos')::numeric <> 0 OR (e->>'sinCosto')::boolean IS NOT TRUE THEN
    f := f || format(' %s fila del borrado = %s, esperado %s u., ingresos %s', v_tag, e, o.cantidad, o.ingreso_real);
  END IF;

  -- totales: suben los ingresos y las ventas de las huérfanas; el costo y los
  -- pedidos, iguales; ingresosSinCosto es la venta sin costo del rango.
  IF abs(pg_temp._rf_dif(ta, td, 'ingresosTotales') - o.ingreso_real) > v_tol
     OR abs(pg_temp._rf_dif(ta, td, 'margenTotal') - o.ingreso_real) > v_tol
     OR abs(pg_temp._rf_dif(ta, td, 'ventasBrutas') - o.subtotal) > v_tol
     OR abs(pg_temp._rf_dif(ta, td, 'ivaDiscriminado') - o.iva) > v_tol
     OR abs(pg_temp._rf_dif(ta, td, 'impuestosInternos') - o.ii) > v_tol
     OR abs(pg_temp._rf_dif(ta, td, 'ventasNetas') - o.neto) > v_tol
     OR td->'costosTotales' IS DISTINCT FROM ta->'costosTotales'
     OR td->'cantidadPedidos' IS DISTINCT FROM ta->'cantidadPedidos'
     OR abs((td->>'ingresosSinCosto')::numeric - sc.ingreso_real) > v_tol THEN
    f := f || format(' %s totales %s -> %s, esperado ingresos +%s y sin costo %s', v_tag, ta, td, o.ingreso_real, sc.ingreso_real);
  END IF;
  v_ing := (td->>'ingresosTotales')::numeric;
  v_cos := (td->>'costosTotales')::numeric;
  IF abs((td->>'margenPorcentaje')::numeric
         - CASE WHEN v_ing > 0 THEN round((v_ing - v_cos) / v_ing * 100, 2) ELSE 0 END) > v_tol THEN
    f := f || format(' %s margenPorcentaje %s no es el de los totales', v_tag, td->'margenPorcentaje');
  END IF;
  RETURN f;
END
$f$;

-- rendimiento_preventistas: una llamada.
CREATE FUNCTION pg_temp._rf_ver_rendimiento(p_rango text, p_desde date, p_hasta date, p_suc bigint,
                                            p_extra text, a jsonb, d jsonb)
RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE
  v_tol  constant numeric := 0.005;
  v_tag  text := format('[rendimiento %s %s %s %s]', p_rango, p_desde, COALESCE(p_suc::text, 'red'), p_extra);
  v_sucs bigint[] := pg_temp._rf_sucs(p_suc, p_extra = 'servicio');
  f      text := '';
  e      jsonb;
  x      jsonb;
  ma     jsonb;
  md     jsonb;
  u      record;
  sc     numeric;
BEGIN
  IF a->'periodo' IS DISTINCT FROM d->'periodo'
     OR jsonb_array_length(a->'preventistas') <> jsonb_array_length(d->'preventistas') THEN
    f := f || format(' %s cambió el período o la lista de preventistas', v_tag);
  END IF;
  FOR e IN SELECT * FROM jsonb_array_elements(a->'preventistas') LOOP
    x := pg_temp._rf_uno(d->'preventistas', 'preventista_id', e->>'preventista_id');
    SELECT COALESCE(sum(h.lineas), 0) AS lineas, COALESCE(sum(h.cantidad), 0) AS cantidad,
           COALESCE(sum(h.subtotal), 0) AS subtotal
      INTO u FROM pg_temp._rf_huerfanas(p_desde, p_hasta, v_sucs, ARRAY['entregado']) h
     WHERE h.usuario_id = (e->>'preventista_id')::uuid;
    SELECT COALESCE(sum(s.subtotal), 0) INTO sc
      FROM pg_temp._rf_sin_costo(p_desde, p_hasta, v_sucs, true) s
     WHERE s.usuario_id = (e->>'preventista_id')::uuid;
    IF x IS NULL THEN
      f := f || format(' %s %s desapareció', v_tag, e->>'nombre');
      CONTINUE;
    END IF;
    IF abs(pg_temp._rf_dif(e, x, 'venta') - u.subtotal) > v_tol
       OR pg_temp._rf_dif(e, x, 'unidades') <> u.cantidad
       OR x->'margen_comercial' IS DISTINCT FROM e->'margen_comercial'
       OR (x->'ticket' IS DISTINCT FROM e->'ticket'
           AND (x->>'ticket')::numeric IS DISTINCT FROM round((x->>'venta')::numeric / NULLIF((x->>'pedidos')::numeric, 0), 2))
       OR abs((x->>'venta_sin_costo')::numeric - sc) > v_tol THEN
      f := f || format(' %s %s: venta %s -> %s (esperado +%s), sin costo %s (esperado %s)', v_tag, e->>'nombre',
                       e->'venta', x->'venta', u.subtotal, x->'venta_sin_costo', sc);
    END IF;
    -- Por categoría: las de antes, más "(producto borrado)".
    IF pg_temp._rf_norm(e->'por_categoria')
       IS DISTINCT FROM pg_temp._rf_norm(pg_temp._rf_sin(x->'por_categoria', 'categoria', '(producto borrado)'))
       OR (u.lineas > 0) <> (pg_temp._rf_uno(x->'por_categoria', 'categoria', '(producto borrado)') IS NOT NULL)
       OR (u.lineas > 0 AND abs((pg_temp._rf_uno(x->'por_categoria', 'categoria', '(producto borrado)')->>'venta')::numeric - u.subtotal) > v_tol) THEN
      f := f || format(' %s %s: por_categoria no cuadra', v_tag, e->>'nombre');
    END IF;
    -- Por marca: igual salvo "(sin marca)", que suma las huérfanas.
    ma := pg_temp._rf_uno(e->'por_marca', 'marca', '(sin marca)');
    md := pg_temp._rf_uno(x->'por_marca', 'marca', '(sin marca)');
    IF pg_temp._rf_norm(pg_temp._rf_sin(e->'por_marca', 'marca', '(sin marca)'))
       IS DISTINCT FROM pg_temp._rf_norm(pg_temp._rf_sin(x->'por_marca', 'marca', '(sin marca)'))
       OR abs(COALESCE((md->>'venta')::numeric, 0) - COALESCE((ma->>'venta')::numeric, 0) - u.subtotal) > v_tol
       OR COALESCE((md->>'unidades')::numeric, 0) - COALESCE((ma->>'unidades')::numeric, 0) <> u.cantidad THEN
      f := f || format(' %s %s: por_marca no cuadra', v_tag, e->>'nombre');
    END IF;
    IF (e - 'venta' - 'unidades' - 'ticket' - 'por_categoria' - 'por_marca')
       IS DISTINCT FROM (x - 'venta' - 'unidades' - 'ticket' - 'por_categoria' - 'por_marca' - 'venta_sin_costo') THEN
      f := f || format(' %s %s cambió fuera de lo de #1262', v_tag, e->>'nombre');
    END IF;
  END LOOP;
  RETURN f;
END
$f$;

DO $ensayo$
DECLARE
  v_r      record;
  v_a      jsonb;
  v_d      jsonb;
  o        record;
  e        jsonb;
  v_comp   int := 0;
  v_mov    int := 0;
  v_fallas text := '';
  v_f      text;
BEGIN
  IF EXISTS (
    SELECT 1
      FROM (SELECT * FROM _rf_foto WHERE etapa = 'antes') a
      FULL JOIN (SELECT * FROM _rf_foto WHERE etapa = 'despues') d
        ON d.fn = a.fn AND d.rango = a.rango AND d.extra = a.extra
       AND d.desde IS NOT DISTINCT FROM a.desde AND d.hasta IS NOT DISTINCT FROM a.hasta
       AND d.suc IS NOT DISTINCT FROM a.suc
     WHERE a.fn IS NULL OR d.fn IS NULL
  ) THEN
    RAISE EXCEPTION 'mig 410 · las fotos de antes y de después no tienen las mismas llamadas';
  END IF;

  FOR v_r IN
    SELECT a.fn, a.rango, a.desde, a.hasta, a.suc, a.extra, a.valor AS antes, d.valor AS despues
      FROM _rf_foto a
      JOIN _rf_foto d
        ON d.etapa = 'despues' AND d.fn = a.fn AND d.rango = a.rango AND d.extra = a.extra
       AND d.desde IS NOT DISTINCT FROM a.desde AND d.hasta IS NOT DISTINCT FROM a.hasta
       AND d.suc IS NOT DISTINCT FROM a.suc
     WHERE a.etapa = 'antes'
     ORDER BY a.fn, a.rango, a.desde, a.suc NULLS FIRST, a.extra
  LOOP
    v_comp := v_comp + 1;
    v_a := v_r.antes;
    v_d := v_r.despues;
    IF pg_temp._rf_norm(v_a) IS DISTINCT FROM pg_temp._rf_norm(v_d) THEN
      v_mov := v_mov + 1;
    END IF;

    IF v_r.fn = 'reporte_gerencial' THEN
      v_f := pg_temp._rf_ver_gerencial(v_r.rango, v_r.desde, v_r.hasta, v_r.suc, v_r.extra, v_a, v_d);
    ELSIF v_r.fn = 'reporte_rentabilidad' THEN
      v_f := pg_temp._rf_ver_rentabilidad(v_r.rango, v_r.desde, v_r.hasta, v_r.suc, v_a, v_d);
    ELSIF v_r.fn = 'rendimiento_preventistas' THEN
      v_f := pg_temp._rf_ver_rendimiento(v_r.rango, v_r.desde, v_r.hasta, v_r.suc, v_r.extra, v_a, v_d);
    ELSIF v_r.fn = 'reporte_alerta_detalle' AND v_r.extra = 'productos_sin_costo' THEN
      -- La lista: la de antes, más el borrado con lo que sumó al KPI.
      v_f := '';
      SELECT COALESCE(sum(h.lineas), 0) AS lineas, COALESCE(sum(h.subtotal), 0) AS subtotal
        INTO o FROM pg_temp._rf_huerfanas(v_r.desde, v_r.hasta, pg_temp._rf_sucs(v_r.suc, false), ARRAY['entregado']) h;
      e := pg_temp._rf_uno(v_d, 'nombre', '(producto borrado)');
      IF jsonb_array_length(v_a) >= 100 THEN
        v_f := format(' [alerta productos_sin_costo %s %s: la lista de antes está en el LIMIT]', v_r.rango, COALESCE(v_r.suc::text, 'red'));
      ELSIF pg_temp._rf_norm(v_a) IS DISTINCT FROM pg_temp._rf_norm(pg_temp._rf_sin(v_d, 'nombre', '(producto borrado)'))
         OR (o.lineas > 0) <> (e IS NOT NULL)
         OR (e IS NOT NULL AND abs((e->>'valor')::numeric - o.subtotal) > 0.005) THEN
        v_f := format(' [alerta productos_sin_costo %s %s: %s -> %s, esperado borrado %s]',
                      v_r.rango, COALESCE(v_r.suc::text, 'red'), v_a, v_d, o.subtotal);
      END IF;
    ELSE
      -- El resto no tiene por qué moverse: ni la Red (la inactiva está vacía),
      -- ni el día (CURRENT_DATE = el día argentino a esta hora), ni la mora.
      v_f := CASE WHEN pg_temp._rf_norm(v_a) IS DISTINCT FROM pg_temp._rf_norm(v_d)
                  THEN format(' [%s %s %s %s %s: el resultado cambió]', v_r.fn, v_r.rango, v_r.desde,
                              COALESCE(v_r.suc::text, 'red'), v_r.extra)
                  ELSE '' END;
    END IF;
    v_fallas := v_fallas || v_f;
  END LOOP;

  IF v_comp = 0 THEN
    RAISE EXCEPTION 'mig 410 · el ensayo no comparó ninguna llamada';
  END IF;
  IF v_fallas <> '' THEN
    RAISE EXCEPTION 'mig 410 · el antes/después no es el esperado:%', v_fallas;
  END IF;

  INSERT INTO _rf_resumen (linea)
  VALUES (format('ensayo OK: %s llamadas comparadas; %s cambiaron y todas por exactamente lo de #1262', v_comp, v_mov));
END
$ensayo$;

-- El resumen de antes/después que va al PR: Red y cada sucursal, en el año y en marzo.
INSERT INTO _rf_resumen (linea)
SELECT format('gerencial %s %s · venta %s · Σ categorías %s → %s · Σ vendedores %s → %s · sin costo %s → %s (%s%% → %s%%) · unidades %s → %s · CMV %s → %s · margen comercial %s → %s · Σ mensual.compras %s → %s (kpis.compras %s) · meses %s → %s',
              a.rango, COALESCE(s.nombre, 'Red'),
              d.valor->'kpis'->>'venta',
              pg_temp._rf_suma(a.valor->'categorias', 'venta'), pg_temp._rf_suma(d.valor->'categorias', 'venta'),
              pg_temp._rf_suma(a.valor->'vendedores', 'venta'), pg_temp._rf_suma(d.valor->'vendedores', 'venta'),
              a.valor->'kpis'->>'ingreso_sin_costo', d.valor->'kpis'->>'ingreso_sin_costo',
              a.valor->'flags'->>'pct_sin_costo', d.valor->'flags'->>'pct_sin_costo',
              a.valor->'kpis'->>'unidades', d.valor->'kpis'->>'unidades',
              a.valor->'kpis'->>'cmv', d.valor->'kpis'->>'cmv',
              a.valor->'kpis'->>'margen_comercial', d.valor->'kpis'->>'margen_comercial',
              pg_temp._rf_suma(a.valor->'mensual', 'compras'), pg_temp._rf_suma(d.valor->'mensual', 'compras'),
              d.valor->'kpis'->>'compras',
              jsonb_array_length(a.valor->'mensual'), jsonb_array_length(d.valor->'mensual'))
  FROM _rf_foto a
  JOIN _rf_foto d ON d.etapa = 'despues' AND d.fn = a.fn AND d.rango = a.rango AND d.extra = a.extra
                 AND d.suc IS NOT DISTINCT FROM a.suc
  LEFT JOIN sucursales s ON s.id = a.suc
 WHERE a.etapa = 'antes' AND a.fn = 'reporte_gerencial' AND a.extra = 'comparar'
   AND a.rango IN ('anio', 'marzo_2026', 'anio_completo')
 ORDER BY a.rango, a.suc NULLS FIRST;

INSERT INTO _rf_resumen (linea)
SELECT format('gerencial %s %s · vendedores: %s',
              a.rango, COALESCE(s.nombre, 'Red'),
              (SELECT string_agg(format('%s %s → %s', x->>'nombre',
                                        COALESCE(pg_temp._rf_uno(a.valor->'vendedores', 'id', x->>'id')->>'venta', '—'),
                                        x->>'venta'), '; ' ORDER BY (x->>'venta')::numeric DESC)
                 FROM jsonb_array_elements(d.valor->'vendedores') x
                WHERE x->>'id' IS NULL
                   OR pg_temp._rf_uno(a.valor->'vendedores', 'id', x->>'id') IS DISTINCT FROM x))
  FROM _rf_foto a
  JOIN _rf_foto d ON d.etapa = 'despues' AND d.fn = a.fn AND d.rango = a.rango AND d.extra = a.extra
                 AND d.suc IS NOT DISTINCT FROM a.suc
  LEFT JOIN sucursales s ON s.id = a.suc
 WHERE a.etapa = 'antes' AND a.fn = 'reporte_gerencial' AND a.extra = 'comparar'
   AND a.rango IN ('anio', 'marzo_2026')
 ORDER BY a.rango, a.suc NULLS FIRST;

INSERT INTO _rf_resumen (linea)
SELECT format('rentabilidad %s %s · ingresos %s → %s · costos %s → %s · margen %s → %s (%s%% → %s%%) · ventas brutas %s → %s · ingresos sin costo %s · productos %s → %s',
              a.rango, COALESCE(s.nombre, 'Red'),
              a.valor->'totales'->>'ingresosTotales', d.valor->'totales'->>'ingresosTotales',
              a.valor->'totales'->>'costosTotales', d.valor->'totales'->>'costosTotales',
              a.valor->'totales'->>'margenTotal', d.valor->'totales'->>'margenTotal',
              a.valor->'totales'->>'margenPorcentaje', d.valor->'totales'->>'margenPorcentaje',
              a.valor->'totales'->>'ventasBrutas', d.valor->'totales'->>'ventasBrutas',
              d.valor->'totales'->>'ingresosSinCosto',
              jsonb_array_length(a.valor->'productos'), jsonb_array_length(d.valor->'productos'))
  FROM _rf_foto a
  JOIN _rf_foto d ON d.etapa = 'despues' AND d.fn = a.fn AND d.rango = a.rango AND d.extra = a.extra
                 AND d.suc IS NOT DISTINCT FROM a.suc
  LEFT JOIN sucursales s ON s.id = a.suc
 WHERE a.etapa = 'antes' AND a.fn = 'reporte_rentabilidad' AND a.rango IN ('anio', 'marzo_2026')
 ORDER BY a.rango, a.suc NULLS FIRST;

-- ---------------------------------------------------------------------------
-- 10 · Permisos: las once conservan la ACL y siguen siendo DEFINER; las dos
--      nuevas son sólo de servidor.
-- ---------------------------------------------------------------------------
DO $permisos$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT p.oid, p.oid::regprocedure::text AS firma, p.proacl, p.proowner, p.prosecdef
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('reporte_gerencial','reporte_alerta_detalle','reporte_rentabilidad',
                         'rendimiento_preventistas','avance_metas_preventista',
                         'reporte_cuentas_por_cobrar','obtener_deudores_mora','bot_metricas_admin_dia',
                         'reporte_ventas_por_preventista','reporte_ventas_por_cliente','reporte_mermas')
  LOOP
    IF (SELECT a.acl FROM _rf_acl a WHERE a.oid = v_f.oid) IS DISTINCT FROM v_f.proacl::text THEN
      RAISE EXCEPTION 'mig 410 · % cambió de ACL (antes %, ahora %)', v_f.firma,
        (SELECT a.acl FROM _rf_acl a WHERE a.oid = v_f.oid), v_f.proacl::text;
    END IF;
    IF NOT v_f.prosecdef THEN
      RAISE EXCEPTION 'mig 410 · % dejó de ser SECURITY DEFINER', v_f.firma;
    END IF;
  END LOOP;
  IF (SELECT count(*) FROM _rf_acl) <> 11 THEN
    RAISE EXCEPTION 'mig 410 · se esperaban 11 funciones en la foto de ACL';
  END IF;

  FOR v_f IN
    SELECT p.oid, p.oid::regprocedure::text AS firma, p.proacl, p.proowner
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname IN ('_sucursales_red', 'auditoria_fechas_utc')
  LOOP
    IF has_function_privilege('anon', v_f.oid, 'EXECUTE')
       OR has_function_privilege('authenticated', v_f.oid, 'EXECUTE')
       OR EXISTS (SELECT 1 FROM aclexplode(COALESCE(v_f.proacl, acldefault('f', v_f.proowner))) a
                   WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
       OR NOT has_function_privilege('service_role', v_f.oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'mig 410 · % tiene que ser sólo de servidor (acl %)', v_f.firma, v_f.proacl;
    END IF;
  END LOOP;
END
$permisos$;

-- ---------------------------------------------------------------------------
-- 11 · Tablas, al final: el ALTER toma ACCESS EXCLUSIVE sobre la tabla y lo
--      tiene hasta el COMMIT. Acá son milisegundos; arriba, el ensayo entero.
--      Si alguien la tiene tomada más de 5 s, la migración aborta entera en
--      vez de dejar la app esperando.
-- ---------------------------------------------------------------------------
SET LOCAL lock_timeout = '5s';

-- #1250: el día con que nace un pedido que no dice su fecha. Hoy ninguna alta
-- depende de este default (crear_pedido_completo, crear_pedido_completo_bot y
-- crear_pedido_cambio_en_ruta pasan la fecha), pero con CURRENT_DATE el
-- próximo INSERT que la omita entre las 21 y las 24 nacería mañana. Inline y
-- no _tablero_hoy(): un default se evalúa con los permisos de quien inserta.
ALTER TABLE public.pedidos
  ALTER COLUMN fecha SET DEFAULT ((now() AT TIME ZONE 'America/Argentina/Tucuman'))::date;

-- 12 · [Decisión del dueño] pedido_items_producto_id_fkey pasa a RESTRICT.
-- Desde que existe el trigger productos_rechazar_borrado_con_historial, un
-- producto con ventas no se puede borrar, así que el SET NULL no se dispara
-- nunca: las 32 líneas sin producto son de antes (la última, de abril).
-- RESTRICT deja escrito en la FK lo mismo que dice el trigger, y lo sostiene
-- aunque el trigger no corra (session_replication_role = replica, un DISABLE
-- TRIGGER, un DROP). Las líneas que ya están en NULL no se tocan: una FK no
-- mira las filas con la columna en NULL. La FK sigue compuesta (Trampa 6).
ALTER TABLE public.pedido_items DROP CONSTRAINT pedido_items_producto_id_fkey;
ALTER TABLE public.pedido_items
  ADD CONSTRAINT pedido_items_producto_id_fkey
  FOREIGN KEY (producto_id, sucursal_id) REFERENCES public.productos(id, sucursal_id) ON DELETE RESTRICT;

-- ---------------------------------------------------------------------------
-- 13 · El gate ya no ve ninguna de las de esta tarjeta, ni el default.
-- ---------------------------------------------------------------------------
DO $gate$
DECLARE
  v_g   jsonb := public.auditoria_fechas_utc();
  v_mal text;
BEGIN
  SELECT string_agg(f->>'firma', ', ') INTO v_mal
    FROM jsonb_array_elements(v_g->'funciones') f
   WHERE f->>'nombre' IN ('reporte_gerencial','reporte_alerta_detalle','reporte_rentabilidad',
                          'rendimiento_preventistas','avance_metas_preventista',
                          'reporte_cuentas_por_cobrar','obtener_deudores_mora','bot_metricas_admin_dia',
                          'reporte_ventas_por_preventista','reporte_ventas_por_cliente','reporte_mermas',
                          '_sucursales_red','auditoria_fechas_utc');
  IF v_mal IS NOT NULL THEN
    RAISE EXCEPTION 'mig 410 · todavía usan el día UTC: %', v_mal;
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_g->'defaults') d WHERE d->>'columna' = 'pedidos.fecha') THEN
    RAISE EXCEPTION 'mig 410 · pedidos.fecha sigue con un default UTC';
  END IF;
  IF pg_get_constraintdef((SELECT oid FROM pg_constraint
                            WHERE conname = 'pedido_items_producto_id_fkey'
                              AND conrelid = 'public.pedido_items'::regclass))
     <> 'FOREIGN KEY (producto_id, sucursal_id) REFERENCES productos(id, sucursal_id) ON DELETE RESTRICT' THEN
    RAISE EXCEPTION 'mig 410 · la FK de pedido_items.producto_id no quedó como se esperaba';
  END IF;
  INSERT INTO _rf_resumen (linea)
  VALUES (format('gate: quedan %s funciones y %s defaults con el día UTC (scripts/fechas-utc-permitidas.json): %s | %s',
                 jsonb_array_length(v_g->'funciones'), jsonb_array_length(v_g->'defaults'),
                 (SELECT string_agg(f->>'nombre', ', ') FROM jsonb_array_elements(v_g->'funciones') f),
                 (SELECT string_agg(d->>'columna', ', ') FROM jsonb_array_elements(v_g->'defaults') d)));
END
$gate$;

DO $resumen$
BEGIN
  RAISE NOTICE E'mig 410 · resumen\n%', (SELECT string_agg(linea, E'\n' ORDER BY orden) FROM _rf_resumen);
END
$resumen$;

-- ---------------------------------------------------------------------------
-- 14 · Se saca el andamio (las tablas temporales se van con el COMMIT).
-- ---------------------------------------------------------------------------
DROP FUNCTION pg_temp._rf_ver_rendimiento(text, date, date, bigint, text, jsonb, jsonb);
DROP FUNCTION pg_temp._rf_ver_rentabilidad(text, date, date, bigint, jsonb, jsonb);
DROP FUNCTION pg_temp._rf_ver_gerencial(text, date, date, bigint, text, jsonb, jsonb);
DROP FUNCTION pg_temp._rf_dif(jsonb, jsonb, text);
DROP FUNCTION pg_temp._rf_uno(jsonb, text, text);
DROP FUNCTION pg_temp._rf_sin(jsonb, text, text);
DROP FUNCTION pg_temp._rf_suma(jsonb, text);
DROP FUNCTION pg_temp._rf_fotografiar(text);
DROP FUNCTION pg_temp._rf_sin_costo(date, date, bigint[], boolean);
DROP FUNCTION pg_temp._rf_huerfanas(date, date, bigint[], text[]);
DROP FUNCTION pg_temp._rf_rangos();
DROP FUNCTION pg_temp._rf_sucs(bigint, boolean);
DROP FUNCTION pg_temp._rf_admin();
DROP FUNCTION pg_temp._rf_norm(jsonb);

COMMIT;
