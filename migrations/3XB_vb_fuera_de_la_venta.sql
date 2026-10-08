-- ============================================================================
-- 3XB — el vale blanco sale de la venta (reportes, comisiones, metas)
-- ============================================================================
-- El número real se pone al aplicar (Trampa 3 del CLAUDE.md): hoy la última en
-- prod es la 310 y otras sesiones tienen su propio 3XA/3XC/3XD. Va JUNTO con
-- la 3XA (lógica + esquema del VB) y ANTES del backfill (3XC). Nunca después
-- del front: la premisa de abajo corta si ya existe algún pedido VB (el front
-- nuevo los puede cargar apenas un admin habilita un cliente). Orden completo:
-- 3XA → 3XB y 3XD (en cualquier orden entre sí) → front → 3XC.
--
-- QUÉ ES ESTO
-- -----------
-- El vale blanco (VB) deja de ser forma de pago y pasa a ser el tercer valor de
-- `pedidos.tipo_factura` ('FC', 'ZZ', 'VB'): consumo interno hacia una empresa
-- propia, a costo, nace entregado, no es deuda, NO es venta y no comisiona.
-- La definición de "venta por vendedor" de la 241 gana una pata:
--
--     estado = 'entregado'
--     AND canal <> 'cambio'
--     AND tipo_factura IS DISTINCT FROM 'VB'   -- <- nueva
--     por pedidos.fecha, atribuida a pedidos.usuario_id
--
-- `IS DISTINCT FROM` y no `<>`: `pedidos.tipo_factura` es nullable (default
-- 'ZZ', sin NOT NULL; hoy 0 nulos). Un `<> 'VB'` pelado sacaría también un
-- NULL, que es un comprobante común sin tipo, no un vale. Es el mismo
-- predicado que usa la 3XD para el resto de las funciones.
--
-- QUÉ SE TOCA (8 funciones; las otras ~17 de venta están en la 3XD)
-- -----------------------------------------------------------------
--   · reporte_gerencial ............ VB fuera de `ped` (venta, CMV, márgenes,
--                                    bonif, rankings, ticket, serie, cobranza),
--                                    de la base de comisión, de clientes nuevos
--                                    y de la alerta de clientes inactivos.
--                                    Línea propia kpis.consumo_interno
--                                    {monto, pedidos}; el comparativo la trae
--                                    sola porque es `v_prev->'kpis'`.
--   · posicion_fiscal .............. ventas.vb_pedidos / ventas.vb_monto,
--                                    informativos. El VB ya quedaba fuera de
--                                    fc_* y zz_* por los FILTER explícitos.
--   · reporte_rentabilidad ......... VB fuera + rama VB explícita en el CASE
--                                    de ingreso (no un ELSE por accidente).
--   · calcular_comisiones .......... N16: fuera el VB y los pedidos con algún
--                                    pago 'adelanto_sueldo'. Los filtros de la
--                                    309 por 'vale_blanco' se CONSERVAN como red
--                                    hasta el backfill; los quita la 3XC.
--   · reporte_ventas_por_preventista  VB fuera de totalVentas y de totalPagado.
--   · obtener_estadisticas_pedidos . total_ventas y promedio_ticket sin VB;
--                                    línea nueva consumo_interno {monto, pedidos}.
--   · avance_metas_preventista ..... el VB no suma a ninguna meta ni hace
--                                    "cliente nuevo".
--   · reporte_ventas_por_cliente ... VB fuera del ranking de clientes y de la
--                                    lista de vendedores.
--
-- Las que delegan en estas (check BOT-B): bot_ventas_por_preventista →
-- reporte_ventas_por_preventista y bot_ranking_clientes →
-- reporte_ventas_por_cliente heredan el filtro; no se duplica inline.
--
-- La deuda (`total - monto_pagado`) no necesita filtro: un VB tiene
-- monto_pagado = total por construcción (invariante de la 3XA), así que la
-- alerta de cobranza vencida del gerencial no lo ve.
--
-- REGLAS DE ESCRITURA
-- -------------------
-- Cada función es copia LITERAL de pg_get_functiondef de prod (2026-10-08,
-- md5 verificado) más el cambio mínimo, marcado con "3XB". El primer bloque
-- frena la migración si alguna cambió en prod desde entonces. CREATE OR REPLACE
-- conserva dueño, SECURITY DEFINER, search_path y la ACL; ninguna cambia de
-- firma ni de RETURNS (todas devuelven jsonb), así que no hay DROP ni re-grant.
-- Las claves nuevas de los jsonb son aditivas: un front viejo las ignora.
--
-- ENSAYO (molde de la 241)
-- ------------------------
-- Hoy no hay ningún pedido VB (el CHECK de tipo_factura recién lo admite con la
-- 3XA), así que cambiar la definición NO puede mover ningún número. Se prueba:
-- se sacan fotos de las 8 funciones ANTES de reemplazarlas, en varios rangos
-- (mes cerrado, mes en curso, año, última semana) y por sucursal y Red, y se
-- comparan con las de DESPUÉS. Tienen que dar idénticas salvo las claves
-- nuevas (que tienen que estar y en cero) y salvo la comisión de los pedidos
-- cobrados con adelanto de sueldo (hoy 0): si los hubiera, la base tiene que
-- bajar exactamente lo que suman esos pedidos.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 0 · Premisas: nada cambió en prod desde que se copiaron las definiciones, y
--     todavía no hay ningún VB (si no, el ensayo "antes = después" no prueba
--     nada: esta migración va con la 3XA, antes de que se cargue el primero).
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, md5(pg_get_functiondef(x.firma::regprocedure)) AS md5_vivo
      FROM (VALUES
        ('public.reporte_gerencial(bigint,date,date,boolean,boolean)',            'ea52d77eedcd7b70a134f4aae2fe0218'),
        ('public.posicion_fiscal(bigint,date,date)',                               'fce575343e4531443c2ab6b3bd238bf7'),
        ('public.reporte_rentabilidad(date,date,bigint)',                          '20a8a8fbc67af049b2f81c337ed0eb69'),
        ('public.calcular_comisiones(date,date,bigint[])',                         'bd77ac5ce57da05e3531f414b6631846'),
        ('public.reporte_ventas_por_preventista(date,date,bigint)',                '2b34b47d6707800035de8effabbc69dc'),
        ('public.obtener_estadisticas_pedidos(timestamp with time zone,timestamp with time zone,uuid)', '5d13c0106af5125d3fbc6749e5da1d56'),
        ('public.avance_metas_preventista(uuid,date)',                             'f03d2a33295b1978fd7344f224c63d21'),
        ('public.reporte_ventas_por_cliente(date,date,uuid,bigint)',               '7d7e58989fe1a926fa14a4946d2d8daf')
      ) AS x(firma, md5)
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION '3XB · % cambió en prod desde que se copió (md5 %, esperado %): rehacer la copia sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;

  IF EXISTS (SELECT 1 FROM pedidos WHERE tipo_factura = 'VB') THEN
    RAISE EXCEPTION '3XB · ya hay pedidos VB: el ensayo antes/después supone que no hay ninguno. Aplicar junto con la 3XA, o rehacer el ensayo';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 1 · Andamio del ensayo: una tabla temporal para las fotos y dos funciones en
--     pg_temp (no quedan en `public`, no hay EXECUTE que revocar; se borran al
--     final).
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _vb_foto (
  etapa  text   NOT NULL,          -- 'antes' | 'despues'
  fn     text   NOT NULL,
  rango  text   NOT NULL,
  desde  date,
  hasta  date,
  suc    bigint,                   -- NULL = Red / sucursales del admin
  extra  text   NOT NULL DEFAULT '',
  valor  jsonb
);

-- Normaliza un jsonb para comparar contenido y no orden: los arrays se ordenan
-- por su texto. Un ORDER BY con empates (top 10, formas de pago, margen por
-- producto) puede salir en otro orden con otro plan, y eso no es un cambio.
CREATE FUNCTION pg_temp._vb_norm(j jsonb) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $f$
DECLARE
  r jsonb;
BEGIN
  CASE jsonb_typeof(j)
    WHEN 'object' THEN
      SELECT COALESCE(jsonb_object_agg(e.k, pg_temp._vb_norm(e.v)), '{}'::jsonb)
        INTO r FROM jsonb_each(j) AS e(k, v);
    WHEN 'array' THEN
      SELECT COALESCE(jsonb_agg(s.x ORDER BY s.x::text), '[]'::jsonb)
        INTO r FROM (SELECT pg_temp._vb_norm(a.v) AS x
                       FROM jsonb_array_elements(j) AS a(v)) s;
    ELSE
      r := j;
  END CASE;
  RETURN r;
END
$f$;

-- Saca la foto de las 8 funciones. Corre como el admin con más sucursales
-- activas (como la 241): así cada llamada pasa los guards de rol y de
-- pertenencia en vez de chocarlos.
CREATE FUNCTION pg_temp._vb_fotografiar(p_etapa text) RETURNS integer
LANGUAGE plpgsql AS $f$
DECLARE
  v_admin   uuid;
  v_claims  text := current_setting('request.jwt.claims', true);
  v_headers text := current_setting('request.headers', true);
  v_r       record;
  v_suc     bigint;
  v_prev    uuid;
  v_per     date;
  v_n       integer;
BEGIN
  SELECT us.usuario_id INTO v_admin
    FROM usuario_sucursales us
    JOIN perfiles pf   ON pf.id = us.usuario_id AND pf.rol = 'admin'
    JOIN sucursales s  ON s.id = us.sucursal_id AND s.activa
   GROUP BY us.usuario_id
   ORDER BY count(*) DESC, us.usuario_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION '3XB · el ensayo necesita un admin con al menos una sucursal activa asignada';
  END IF;
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  FOR v_r IN
    SELECT * FROM (VALUES
      ('mes_cerrado',  (date_trunc('month', CURRENT_DATE) - interval '1 month')::date,
                       (date_trunc('month', CURRENT_DATE) - interval '1 day')::date),
      ('mes_en_curso', date_trunc('month', CURRENT_DATE)::date, CURRENT_DATE),
      ('anio',         date_trunc('year', CURRENT_DATE)::date,  CURRENT_DATE),
      ('semana',       CURRENT_DATE - 6,                        CURRENT_DATE)
    ) AS t(rango, desde, hasta)
  LOOP
    FOR v_suc IN
      SELECT NULL::bigint
      UNION ALL
      (SELECT s.id FROM sucursales s
         JOIN usuario_sucursales us ON us.sucursal_id = s.id AND us.usuario_id = v_admin
        WHERE s.activa ORDER BY s.id)
    LOOP
      INSERT INTO _vb_foto (etapa, fn, rango, desde, hasta, suc, extra, valor) VALUES
        (p_etapa, 'reporte_gerencial', v_r.rango, v_r.desde, v_r.hasta, v_suc, 'comparar',
           public.reporte_gerencial(v_suc, v_r.desde, v_r.hasta, false, true)),
        (p_etapa, 'reporte_gerencial', v_r.rango, v_r.desde, v_r.hasta, v_suc, 'no_entregados',
           public.reporte_gerencial(v_suc, v_r.desde, v_r.hasta, true, false)),
        (p_etapa, 'posicion_fiscal', v_r.rango, v_r.desde, v_r.hasta, v_suc, '',
           public.posicion_fiscal(v_suc, v_r.desde, v_r.hasta)),
        (p_etapa, 'reporte_rentabilidad', v_r.rango, v_r.desde, v_r.hasta, v_suc, '',
           public.reporte_rentabilidad(v_r.desde, v_r.hasta, v_suc)),
        (p_etapa, 'reporte_ventas_por_preventista', v_r.rango, v_r.desde, v_r.hasta, v_suc, '',
           public.reporte_ventas_por_preventista(v_r.desde, v_r.hasta, v_suc)),
        (p_etapa, 'reporte_ventas_por_cliente', v_r.rango, v_r.desde, v_r.hasta, v_suc, '',
           public.reporte_ventas_por_cliente(v_r.desde, v_r.hasta, NULL, v_suc)),
        (p_etapa, 'calcular_comisiones', v_r.rango, v_r.desde, v_r.hasta, v_suc, '',
           public.calcular_comisiones(v_r.desde, v_r.hasta,
                                      CASE WHEN v_suc IS NULL THEN NULL ELSE ARRAY[v_suc] END));

      -- obtener_estadisticas_pedidos toma la sucursal del header (current_sucursal_id)
      -- y corta por created_at: el rango va como [desde, hasta+1) en hora ARG.
      IF v_suc IS NOT NULL THEN
        PERFORM set_config('request.headers',
                           json_build_object('x-sucursal-id', v_suc::text)::text, true);
        INSERT INTO _vb_foto (etapa, fn, rango, desde, hasta, suc, extra, valor) VALUES
          (p_etapa, 'obtener_estadisticas_pedidos', v_r.rango, v_r.desde, v_r.hasta, v_suc, '',
             public.obtener_estadisticas_pedidos(
               (v_r.desde::timestamp AT TIME ZONE 'America/Argentina/Buenos_Aires'),
               ((v_r.hasta + 1)::timestamp AT TIME ZONE 'America/Argentina/Buenos_Aires'),
               NULL));
      END IF;
    END LOOP;
  END LOOP;

  -- Estadísticas de toda la historia, por sucursal.
  FOR v_suc IN
    SELECT s.id FROM sucursales s
      JOIN usuario_sucursales us ON us.sucursal_id = s.id AND us.usuario_id = v_admin
     WHERE s.activa ORDER BY s.id
  LOOP
    PERFORM set_config('request.headers',
                       json_build_object('x-sucursal-id', v_suc::text)::text, true);
    INSERT INTO _vb_foto (etapa, fn, rango, desde, hasta, suc, extra, valor) VALUES
      (p_etapa, 'obtener_estadisticas_pedidos', 'todo', NULL, NULL, v_suc, '',
         public.obtener_estadisticas_pedidos(NULL, NULL, NULL));
  END LOOP;

  -- Metas: cada preventista con metas activas, este mes y los dos anteriores.
  FOR v_prev IN
    SELECT DISTINCT preventista_id FROM metas_preventista WHERE activo ORDER BY 1
  LOOP
    FOR v_per IN
      SELECT (date_trunc('month', CURRENT_DATE) - make_interval(months => k))::date
        FROM generate_series(0, 2) AS k
    LOOP
      INSERT INTO _vb_foto (etapa, fn, rango, desde, hasta, suc, extra, valor) VALUES
        (p_etapa, 'avance_metas_preventista', 'periodo', v_per, NULL, NULL, v_prev::text,
           public.avance_metas_preventista(v_prev, v_per));
    END LOOP;
  END LOOP;

  PERFORM set_config('request.jwt.claims', COALESCE(v_claims, ''), true);
  PERFORM set_config('request.headers',    COALESCE(v_headers, ''), true);

  SELECT count(*) INTO v_n FROM _vb_foto WHERE etapa = p_etapa;
  RETURN v_n;
END
$f$;

SELECT pg_temp._vb_fotografiar('antes');

-- ---------------------------------------------------------------------------
-- 2 · reporte_gerencial
-- ---------------------------------------------------------------------------
-- VB fuera de `ped` y de todo lo que cuelga de ahí (incluida la cobranza:
-- el monto_pagado de un VB no es plata cobrada), de la base de comisión, de
-- clientes nuevos y de la alerta de clientes inactivos (N17). Línea propia
-- kpis.consumo_interno {monto, pedidos}; el comparativo la hereda.
CREATE OR REPLACE FUNCTION public.reporte_gerencial(p_sucursal_id bigint, p_desde date, p_hasta date, p_incluir_no_entregados boolean DEFAULT false, p_comparar boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursales bigint[]; v_asignadas bigint[]; v_nombre text; v_result jsonb;
  v_es_servicio boolean := (auth.uid() IS NULL);
  v_estados text[] := CASE WHEN p_incluir_no_entregados
                           THEN ARRAY['entregado','asignado','pendiente','en_preparacion']
                           ELSE ARRAY['entregado'] END;
  v_dias int := (p_hasta - p_desde) + 1;
  v_prev_hasta date := p_desde - 1;
  v_prev_desde date := (p_desde - 1) - ((p_hasta - p_desde));
  v_comparativo jsonb := NULL;
  v_prev jsonb;
  v_alertas jsonb := '[]'::jsonb;
  v_cat_neg int;
  v_cli_inact int;
  v_cob_venc numeric;
  v_cob_venc_cli int;
  v_venta numeric;
  v_prev_venta numeric;
  v_mermas numeric;
  v_prev_mermas numeric;
  -- mig 290 (#845): formas que cancelan deuda pero no son plata. Espejo de
  -- FORMAS_PAGO_NO_DINERARIAS (src/constants/formasPago.ts) y de rendiciones (273/276).
  v_formas_no_din text[] := ARRAY['nota_credito', 'adelanto_sueldo'];
BEGIN
  IF NOT v_es_servicio THEN
    IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin') THEN
      RAISE EXCEPTION 'Acceso denegado: se requiere rol admin'; END IF;
    SELECT array_agg(sucursal_id) INTO v_asignadas FROM usuario_sucursales WHERE usuario_id = auth.uid();
    IF v_asignadas IS NULL THEN RAISE EXCEPTION 'Acceso denegado: el usuario no tiene sucursales asignadas'; END IF;
  END IF;
  IF p_sucursal_id IS NULL THEN
    SELECT array_agg(id) INTO v_sucursales FROM sucursales WHERE activa;
    IF NOT v_es_servicio THEN
      SELECT array_agg(s) INTO v_sucursales FROM unnest(v_sucursales) AS s WHERE s = ANY(v_asignadas); END IF;
    v_nombre := 'Red (consolidado)';
  ELSE
    IF NOT v_es_servicio AND NOT (p_sucursal_id = ANY(v_asignadas)) THEN
      RAISE EXCEPTION 'Acceso denegado: la sucursal % no está asignada al usuario', p_sucursal_id; END IF;
    v_sucursales := ARRAY[p_sucursal_id];
    SELECT nombre INTO v_nombre FROM sucursales WHERE id = p_sucursal_id;
  END IF;
  IF v_sucursales IS NULL OR array_length(v_sucursales,1) IS NULL THEN
    RAISE EXCEPTION 'Acceso denegado: sin sucursales disponibles para el usuario'; END IF;

  WITH
  ped AS (
    SELECT id, cliente_id, usuario_id, total, monto_pagado, fecha, forma_pago, estado_pago,
           COALESCE(total_neto, total) AS total_neto, COALESCE(total_iva, 0) AS total_iva,
           COALESCE(tipo_factura, 'ZZ') AS tipo_factura,
           COALESCE(total_real,
             CASE WHEN COALESCE(tipo_factura, 'ZZ') = 'FC' THEN COALESCE(total_neto, total) ELSE total END
           ) AS total_real
    FROM pedidos WHERE estado = ANY(v_estados) AND canal <> 'cambio'
      -- 3XB: el vale blanco no es venta. Fuera de `ped`, sale de todo lo que
      -- cuelga de aca: venta, CMV, margenes, bonif, rankings, ticket, serie y la
      -- cobranza (su monto_pagado = total por construccion no es plata cobrada).
      -- Va aparte, en `k_ci` -> kpis.consumo_interno.
      AND tipo_factura IS DISTINCT FROM 'VB'
      AND fecha BETWEEN p_desde AND p_hasta AND sucursal_id = ANY(v_sucursales)
  ),
  it AS (
    SELECT p.id AS pedido_id, p.usuario_id, p.fecha,
           pi.cantidad, pi.subtotal, pi.es_bonificacion,
           public.costo_valuacion(pi.costo_unitario_al_crear, prod.costo_promedio, prod.costo_real,
                                  prod.costo_sin_iva, prod.impuestos_internos) AS costo_unit,
           pi.cantidad * COALESCE(pi.ingreso_real_unitario,
             CASE WHEN p.tipo_factura = 'FC' THEN COALESCE(pi.neto_unitario, pi.precio_unitario)
                  ELSE pi.precio_unitario END) AS ingreso_real,
           prod.nombre AS prod_nombre,
           COALESCE(NULLIF(prod.categoria,''),'(sin categoría)') AS categoria,
           -- #511: sin_costo es "la cascada COMPLETA no encontro nada", no "falta
           -- costo_sin_iva". Un producto con costo_promedio cargado se valua bien
           -- y por lo tanto NO infla ningun margen.
           (public.costo_valuacion(pi.costo_unitario_al_crear, prod.costo_promedio, prod.costo_real,
                                   prod.costo_sin_iva, prod.impuestos_internos) IS NULL) AS sin_costo,
           pr.nombre AS promo_nombre,
           (public.factor_bonificacion(pi.unidades_por_bloque_al_crear, pr.regalo_mueve_stock, pr.unidades_por_bloque) > 1) AS es_fraccion,
           public.factor_bonificacion(pi.unidades_por_bloque_al_crear, pr.regalo_mueve_stock, pr.unidades_por_bloque) AS unidades_por_bloque,
           COALESCE(prod.precio,0) AS precio_lista,
           -- `factor_bonificacion` devuelve >= 1 siempre, asi que la division cubre
           -- los dos casos que antes eran dos ramas de un CASE (227).
           CASE WHEN pi.es_bonificacion THEN
             pi.cantidad * public.costo_valuacion(pi.costo_unitario_al_crear, prod.costo_promedio,
                                                  prod.costo_real, prod.costo_sin_iva, prod.impuestos_internos)
             / public.factor_bonificacion(pi.unidades_por_bloque_al_crear, pr.regalo_mueve_stock, pr.unidades_por_bloque)
           ELSE 0 END AS costo_bonif
    FROM ped p
    JOIN pedido_items pi ON pi.pedido_id = p.id
    JOIN productos prod ON prod.id = pi.producto_id
    LEFT JOIN promociones pr ON pr.id = pi.promocion_id
  ),
  nc AS (
    SELECT usuario_id, total FROM pedidos
    WHERE estado='entregado' AND canal <> 'cambio'
      AND tipo_factura IS DISTINCT FROM 'VB'  -- 3XB: no comisiona
      AND fecha BETWEEN p_desde AND p_hasta AND sucursal_id = ANY(v_sucursales)
      AND usuario_id IN (SELECT id FROM perfiles)
  ),
  -- 3XB: consumo interno (vale blanco) aparte de la venta: monto a costo y
  -- cantidad, con el mismo corte de estado/canal/fecha que `ped`.
  k_ci AS (SELECT COUNT(*) AS pedidos, COALESCE(SUM(total),0) AS monto FROM pedidos
    WHERE estado = ANY(v_estados) AND canal <> 'cambio' AND tipo_factura = 'VB'
      AND fecha BETWEEN p_desde AND p_hasta AND sucursal_id = ANY(v_sucursales)),
  k_ped AS (SELECT COUNT(*) AS pedidos, COALESCE(SUM(total),0) AS venta,
            COUNT(DISTINCT cliente_id) AS clientes, COALESCE(ROUND(AVG(total)),0) AS ticket,
            COALESCE(SUM(total_neto),0) AS venta_neta,
            COALESCE(SUM(total_iva),0) AS iva_debito,
            COALESCE(SUM(total_real),0) AS venta_real,
            COALESCE(SUM(total) FILTER (WHERE tipo_factura='FC'),0) AS fc_venta,
            COUNT(*) FILTER (WHERE tipo_factura='FC') AS fc_pedidos,
            COALESCE(SUM(total) FILTER (WHERE tipo_factura='ZZ'),0) AS zz_venta,
            COUNT(*) FILTER (WHERE tipo_factura='ZZ') AS zz_pedidos
            FROM ped),
  k_it AS (
    SELECT COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS cmv,
      COALESCE(SUM(costo_bonif),0) AS bonif,
      COALESCE(SUM(cantidad) FILTER (WHERE NOT es_bonificacion),0) AS unidades,
      COALESCE(SUM(cantidad) FILTER (WHERE es_bonificacion),0) AS unidades_bonif,
      COALESCE(SUM(subtotal) FILTER (WHERE sin_costo AND NOT es_bonificacion),0) AS ingreso_sin_costo
    FROM it
  ),
  k_nc AS (SELECT COALESCE(SUM(total),0) AS base_comision FROM nc),
  -- #570: el criterio de merma ya no se escribe aca; se consume.
  -- `clasificacion <> 'promocion'` es EXACTAMENTE el viejo
  -- `COALESCE(motivo,'') NOT IN ('promociones','promociones_reversion')`.
  mv AS (
    SELECT * FROM public.mermas_valorizadas(p_desde, p_hasta, v_sucursales)
    WHERE clasificacion <> 'promocion'
  ),
  k_merma AS (
    SELECT COALESCE(SUM(costo_total),0) AS mermas,
      COALESCE(SUM(costo_total) FILTER (WHERE clasificacion = 'perdida'),0) AS mermas_perdida,
      COALESCE(SUM(costo_total) FILTER (WHERE clasificacion = 'ajuste'),0)  AS mermas_ajuste,
      COALESCE(SUM(costo_total) FILTER (WHERE clasificacion = 'muestra'),0) AS mermas_muestra
    FROM mv
  ),
  -- mig 287: compras = facturas de proveedores + neto de transferencias entre
  -- sucursales (aceptadas, a costo c/IVA del origen, por dia ARG de aceptacion).
  -- En la Red el neto es 0 por construccion.
  k_compra AS (SELECT f.compras_facturas + t.compras_transferencias AS compras,
      f.compras_facturas, t.compras_transferencias
    FROM (SELECT COALESCE(SUM(total),0) AS compras_facturas FROM compras
      WHERE sucursal_id = ANY(v_sucursales) AND fecha_compra BETWEEN p_desde AND p_hasta
        AND COALESCE(estado,'') <> 'cancelada') f,
    (SELECT COALESCE(SUM(ct.monto),0) AS compras_transferencias
       FROM public.compras_transferencias_netas(p_desde, p_hasta, v_sucursales) ct) t),
  -- mig 280 (#867): notas de credito de compra SIN mercaderia (descuentos,
  -- diferencias de precio, II mal liquidado), en el mes de la nota. Restan
  -- del lado del costo: suman a los margenes, no tocan cmv.
  --   FC: neto + II que acredita (el IVA es credito fiscal, no costo).
  --   ZZ: el total (en ZZ lo pagado ya es el costo final).
  desc_nc AS (
    SELECT nc.fecha,
           CASE WHEN COALESCE(c.tipo_factura, 'FC') = 'ZZ'
                  OR c.letra_comprobante IN ('B', 'C') THEN nc.total  /* mig 293 */
                ELSE nc.subtotal + nc.impuestos_internos END AS monto
    FROM notas_credito nc
    JOIN compras c ON c.id = nc.compra_id AND c.sucursal_id = nc.sucursal_id
    WHERE nc.tipo = 'ajuste' AND nc.sucursal_id = ANY(v_sucursales)
      AND nc.fecha BETWEEN p_desde AND p_hasta
      AND COALESCE(c.estado, '') <> 'cancelada'
  ),
  k_desc AS (SELECT COALESCE(SUM(monto), 0) AS descuentos FROM desc_nc),
  m_desc AS (SELECT to_char(fecha, 'YYYY-MM') AS mes, SUM(monto) AS descuentos FROM desc_nc GROUP BY 1),
  -- mig 290 (#845): notas de credito de VENTA vigentes, por la fecha de la nota.
  -- No tocan los margenes: la contribucion (front) las resta. (`nc` mas arriba
  -- es la base de comision, no esto.)
  ncv AS (SELECT fecha, total FROM notas_credito_venta
    WHERE NOT anulada AND sucursal_id = ANY(v_sucursales) AND fecha BETWEEN p_desde AND p_hasta),
  k_ncv AS (SELECT COALESCE(SUM(total), 0) AS monto, COUNT(*) AS n FROM ncv),
  m_ncv AS (SELECT to_char(fecha, 'YYYY-MM') AS mes, SUM(total) AS monto FROM ncv GROUP BY 1),
  k_nuevos AS (SELECT COUNT(*) AS nuevos FROM (
      SELECT cliente_id, MIN(fecha) AS pc FROM pedidos
      WHERE estado='entregado' AND canal <> 'cambio' AND sucursal_id = ANY(v_sucursales)
        AND tipo_factura IS DISTINCT FROM 'VB'  -- 3XB: un vale no hace cliente nuevo
      GROUP BY cliente_id
    ) t WHERE pc BETWEEN p_desde AND p_hasta),
  m_ped AS (SELECT to_char(fecha,'YYYY-MM') AS mes, COUNT(*) AS pedidos, SUM(total) AS venta,
            SUM(total_real) AS venta_real,
            COUNT(DISTINCT cliente_id) AS clientes, ROUND(AVG(total)) AS ticket FROM ped GROUP BY 1),
  m_it AS (SELECT to_char(fecha,'YYYY-MM') AS mes,
           COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS cmv,
           COALESCE(SUM(costo_bonif),0) AS bonif FROM it GROUP BY 1),
  m_merma AS (SELECT to_char(fecha_local,'YYYY-MM') AS mes,
              COALESCE(SUM(costo_total),0) AS mermas FROM mv GROUP BY 1),
  m_compra AS (SELECT mes, COALESCE(SUM(fact),0) + COALESCE(SUM(transf),0) AS compras,
      COALESCE(SUM(transf),0) AS compras_transferencias FROM (
      SELECT to_char(fecha_compra,'YYYY-MM') AS mes, total AS fact, 0::numeric AS transf
      FROM compras WHERE sucursal_id = ANY(v_sucursales) AND fecha_compra BETWEEN p_desde AND p_hasta
        AND COALESCE(estado,'') <> 'cancelada'
      UNION ALL
      SELECT to_char(ct.fecha_local,'YYYY-MM'), 0::numeric, ct.monto
      FROM public.compras_transferencias_netas(p_desde, p_hasta, v_sucursales) ct
    ) x GROUP BY 1),
  mensual AS (SELECT mp.mes, mp.pedidos, mp.venta, mp.venta_real, mp.clientes, mp.ticket,
      COALESCE(mi.cmv,0) AS cmv, COALESCE(mi.bonif,0) AS bonif,
      (mp.venta_real - COALESCE(mi.cmv,0) + COALESCE(md.descuentos,0)) AS margen_real,
      COALESCE(md.descuentos,0) AS descuentos_proveedores,
      COALESCE(mm.mermas,0) AS mermas, COALESCE(mc.compras,0) AS compras,
      COALESCE(mc.compras_transferencias,0) AS compras_transferencias,
      COALESCE(mnv.monto,0) AS notas_credito_venta
    FROM m_ped mp LEFT JOIN m_it mi ON mi.mes=mp.mes LEFT JOIN m_merma mm ON mm.mes=mp.mes LEFT JOIN m_compra mc ON mc.mes=mp.mes LEFT JOIN m_desc md ON md.mes=mp.mes LEFT JOIN m_ncv mnv ON mnv.mes=mp.mes),
  v_ent AS (SELECT usuario_id, COUNT(DISTINCT pedido_id) AS pedidos, SUM(subtotal) AS venta,
      SUM(ingreso_real) AS venta_real,
      SUM(subtotal) - COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS margen_comercial,
      SUM(ingreso_real) - COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS margen_real,
      COALESCE(SUM(costo_bonif),0) AS bonif FROM it GROUP BY usuario_id),
  v_nc AS (SELECT usuario_id, SUM(total) AS base_nc FROM nc GROUP BY usuario_id),
  vendedores AS (SELECT pf.id, pf.nombre, pf.rol, e.pedidos, e.venta, e.venta_real, e.margen_comercial, e.margen_real, e.bonif,
      COALESCE(n.base_nc, e.venta) AS base_nc
    FROM v_ent e JOIN perfiles pf ON pf.id=e.usuario_id LEFT JOIN v_nc n ON n.usuario_id=e.usuario_id),
  categorias AS (SELECT categoria, SUM(subtotal) AS venta,
      SUM(ingreso_real) AS venta_real,
      SUM(subtotal) - COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS margen_comercial,
      SUM(ingreso_real) - COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS margen_real,
      COALESCE(SUM(costo_bonif),0) AS bonif, bool_or(sin_costo) AS sin_costo
    FROM it GROUP BY categoria),
  top_prod AS (SELECT prod_nombre AS nombre,
      COALESCE(SUM(cantidad) FILTER (WHERE NOT es_bonificacion),0) AS unidades, SUM(subtotal) AS venta,
      SUM(ingreso_real) AS venta_real,
      SUM(subtotal) - COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS margen,
      SUM(ingreso_real) - COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS margen_real
    FROM it GROUP BY prod_nombre ORDER BY venta DESC LIMIT 10),
  top_cli AS (SELECT COALESCE(NULLIF(c.nombre_fantasia,''), c.razon_social) AS cliente,
      COUNT(DISTINCT p.id) AS pedidos, SUM(p.total) AS venta
    FROM ped p JOIN clientes c ON c.id=p.cliente_id GROUP BY 1 ORDER BY venta DESC LIMIT 10),
  bonif_promos AS (SELECT COALESCE(promo_nombre,'(sin promoción)') AS promocion, prod_nombre AS producto,
      SUM(cantidad) AS unidades, bool_or(es_fraccion) AS es_fraccion,
      COALESCE(SUM(costo_bonif),0) AS costo,
      SUM(CASE WHEN es_fraccion THEN cantidad * precio_lista / unidades_por_bloque
               ELSE cantidad * precio_lista END) AS valor_venta
    FROM it WHERE es_bonificacion GROUP BY 1, 2 HAVING SUM(cantidad) > 0),
  mermas_motivo AS (SELECT motivo, clasificacion,
      SUM(cantidad) AS unidades, COALESCE(SUM(costo_total),0) AS costo
    FROM mv GROUP BY 1, 2),
  -- mig 290 (#845): `cobrado` es solo plata. Por pedido, lo cubierto
  -- (LEAST(monto_pagado, total)) se parte: lo no dinerario cuenta PRIMERO hasta
  -- lo cubierto y el resto es plata. Un sobrepago con mezcla no infla `cobrado`.
  -- cobrado + credito_aplicado + pendiente = Σ total, pedido por pedido.
  cobr_ped AS (
    SELECT LEAST(COALESCE(p.monto_pagado,0), p.total) AS cubierto,
           GREATEST(p.total - COALESCE(p.monto_pagado,0), 0) AS pendiente,
           COALESCE((SELECT SUM(pg.monto) FROM pagos pg
                      WHERE pg.pedido_id = p.id AND pg.forma_pago = ANY(v_formas_no_din)), 0) AS no_din
    FROM ped p),
  cobr AS (SELECT COALESCE(SUM(cubierto),0) AS cubierto,
      COALESCE(SUM(GREATEST(LEAST(no_din, cubierto), 0)),0) AS credito_aplicado,
      COALESCE(SUM(cubierto - GREATEST(LEAST(no_din, cubierto), 0)),0) AS cobrado,
      COALESCE(SUM(pendiente),0) AS pendiente FROM cobr_ped),
  pagos_ped AS (SELECT COALESCE(NULLIF(pg.forma_pago,''),'(sin dato)') AS forma_pago, SUM(pg.monto) AS monto
    FROM pagos pg JOIN ped ON ped.id = pg.pedido_id GROUP BY 1),
  formas AS (SELECT forma_pago, monto, (forma_pago = ANY(v_formas_no_din)) AS no_dineraria FROM pagos_ped
    UNION ALL
    SELECT '(sin registro de pago)', c.cubierto - COALESCE((SELECT SUM(monto) FROM pagos_ped),0), false
    FROM cobr c
    WHERE c.cubierto - COALESCE((SELECT SUM(monto) FROM pagos_ped),0) > 0.01),
  serie AS (SELECT to_char(fecha,'DD/MM') AS dia, SUM(total) AS venta FROM ped GROUP BY fecha ORDER BY fecha)
  SELECT jsonb_build_object(
    'meta', jsonb_build_object('sucursal_id', p_sucursal_id, 'sucursal_nombre', COALESCE(v_nombre,'?'),
      'desde', p_desde, 'hasta', p_hasta, 'generado_at', now(),
      'incluye_no_entregados', p_incluir_no_entregados),
    'kpis', (SELECT jsonb_build_object('venta', kp.venta, 'pedidos', kp.pedidos, 'clientes', kp.clientes, 'ticket', kp.ticket,
        'clientes_nuevos', kn.nuevos, 'cmv', ki.cmv, 'bonif', ki.bonif, 'unidades', ki.unidades,
        'unidades_bonif', ki.unidades_bonif, 'margen_comercial', kp.venta - ki.cmv + kd.descuentos,
        'margen_neto', kp.venta - ki.cmv - ki.bonif + kd.descuentos, 'base_comision', kc.base_comision, 'comision_pct_default', 2,
        'mermas', km.mermas, 'mermas_perdida', km.mermas_perdida, 'mermas_ajuste', km.mermas_ajuste,
        'mermas_muestra', km.mermas_muestra, 'compras', kcp.compras, 'compras_facturas', kcp.compras_facturas,
        'compras_transferencias', kcp.compras_transferencias, 'ingreso_sin_costo', ki.ingreso_sin_costo,
        'venta_neta', kp.venta_neta, 'iva_debito', kp.iva_debito,
        'margen_comercial_neto', kp.venta_neta - ki.cmv + kd.descuentos,
        'venta_real', kp.venta_real,
        'margen_real', kp.venta_real - ki.cmv + kd.descuentos,
        'margen_real_neto', kp.venta_real - ki.cmv - ki.bonif + kd.descuentos,
        'descuentos_proveedores', kd.descuentos,
        'notas_credito_venta', kncv.monto, 'notas_credito_venta_n', kncv.n,
        'fc_venta', kp.fc_venta, 'fc_pedidos', kp.fc_pedidos,
        'zz_venta', kp.zz_venta, 'zz_pedidos', kp.zz_pedidos,
        -- 3XB: fuera de `venta`; fc_venta + zz_venta siguen cerrando contra venta.
        -- Como el comparativo es `v_prev->'kpis'`, ahi aparece igual.
        'consumo_interno', jsonb_build_object('monto', kci.monto, 'pedidos', kci.pedidos))
      FROM k_ped kp, k_it ki, k_nc kc, k_merma km, k_compra kcp, k_nuevos kn, k_desc kd, k_ncv kncv, k_ci kci),
    'mensual', (SELECT COALESCE(jsonb_agg(to_jsonb(m) ORDER BY m.mes),'[]') FROM mensual m),
    'vendedores', (SELECT COALESCE(jsonb_agg(to_jsonb(v) ORDER BY v.venta DESC),'[]') FROM vendedores v),
    'categorias', (SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.venta DESC),'[]') FROM categorias c),
    'top_productos', (SELECT COALESCE(jsonb_agg(to_jsonb(t)),'[]') FROM top_prod t),
    'top_clientes', (SELECT COALESCE(jsonb_agg(to_jsonb(t)),'[]') FROM top_cli t),
    'bonif_promos', (SELECT COALESCE(jsonb_agg(to_jsonb(b) ORDER BY b.valor_venta DESC),'[]') FROM bonif_promos b),
    'mermas_motivo', (SELECT COALESCE(jsonb_agg(to_jsonb(mm) ORDER BY mm.costo DESC),'[]') FROM mermas_motivo mm),
    'cobranza', jsonb_build_object('formas', (SELECT COALESCE(jsonb_agg(to_jsonb(f) ORDER BY f.monto DESC),'[]') FROM formas f),
      'cobrado', (SELECT cobrado FROM cobr), 'credito_aplicado', (SELECT credito_aplicado FROM cobr),
      'pendiente', (SELECT pendiente FROM cobr)),
    'serie_diaria', (SELECT COALESCE(jsonb_agg(jsonb_build_array(s.dia, s.venta)),'[]') FROM serie s),
    'flags', (SELECT jsonb_build_object('ingreso_sin_costo', ki.ingreso_sin_costo,
        'pct_sin_costo', CASE WHEN kp.venta > 0 THEN round(100.0*ki.ingreso_sin_costo/kp.venta,1) ELSE 0 END)
      FROM k_it ki, k_ped kp)
  ) INTO v_result;

  IF p_comparar THEN
    v_prev := public.reporte_gerencial(p_sucursal_id, v_prev_desde, v_prev_hasta, p_incluir_no_entregados, false);
    v_comparativo := (v_prev->'kpis') || jsonb_build_object('desde', v_prev_desde, 'hasta', v_prev_hasta);
  END IF;

  v_venta := (v_result->'kpis'->>'venta')::numeric;
  v_mermas := (v_result->'kpis'->>'mermas')::numeric;
  v_prev_venta := (v_comparativo->>'venta')::numeric;
  v_prev_mermas := (v_comparativo->>'mermas')::numeric;

  IF p_comparar AND COALESCE(v_prev_venta,0) > 0 AND v_venta < v_prev_venta * 0.9 THEN
    v_alertas := v_alertas || jsonb_build_object(
      'severidad', CASE WHEN v_venta < v_prev_venta*0.8 THEN 'critical' ELSE 'warning' END,
      'codigo','venta_caida','titulo','Venta en baja',
      'detalle','Cayó '||round((1 - v_venta/v_prev_venta)*100)::text||'% vs período anterior',
      'valor', v_venta - v_prev_venta, 'seccion','evolucion');
  END IF;

  SELECT COALESCE(SUM(total - COALESCE(monto_pagado,0)),0), COUNT(DISTINCT cliente_id)
    INTO v_cob_venc, v_cob_venc_cli
  FROM pedidos
  WHERE estado='entregado' AND canal <> 'cambio' AND sucursal_id = ANY(v_sucursales)
    AND COALESCE(estado_pago,'pendiente') IN ('pendiente','parcial')
    AND fecha < CURRENT_DATE - 30 AND total > COALESCE(monto_pagado,0);
  IF v_cob_venc > 0 THEN
    v_alertas := v_alertas || jsonb_build_object('severidad','critical','codigo','cobranza_vencida','titulo','Cobranza vencida',
      'detalle', v_cob_venc_cli::text||' cliente(s) con saldo impago hace +30 días',
      'valor', v_cob_venc, 'seccion','cobranza');
  END IF;

  SELECT COUNT(*) INTO v_cli_inact FROM (
    SELECT p.cliente_id FROM pedidos p
    WHERE p.estado='entregado' AND p.canal <> 'cambio' AND p.sucursal_id = ANY(v_sucursales)
      AND p.tipo_factura IS DISTINCT FROM 'VB'  -- 3XB: el vale no es compra (N17)
    GROUP BY p.cliente_id
    HAVING MAX(p.fecha) < CURRENT_DATE - 30 AND MAX(p.fecha) >= CURRENT_DATE - 90
  ) t;
  IF v_cli_inact > 0 THEN
    v_alertas := v_alertas || jsonb_build_object('severidad','warning','codigo','clientes_inactivos','titulo','Clientes que dejaron de comprar',
      'detalle', v_cli_inact::text||' cliente(s) sin comprar hace +30 días (compraban hasta hace poco)',
      'valor', v_cli_inact, 'seccion','clientes');
  END IF;

  IF p_comparar AND COALESCE(v_prev_mermas,0) > 0 AND v_mermas > v_prev_mermas*1.3 AND v_mermas > 50000 THEN
    v_alertas := v_alertas || jsonb_build_object('severidad','warning','codigo','mermas_alza','titulo','Mermas en alza',
      'detalle','Subieron '||round((v_mermas/v_prev_mermas - 1)*100)::text||'% vs período anterior',
      'valor', v_mermas, 'seccion','mermas');
  END IF;

  SELECT COUNT(*) INTO v_cat_neg FROM jsonb_array_elements(v_result->'categorias') c WHERE (c->>'margen_comercial')::numeric < 0;
  IF v_cat_neg > 0 THEN
    v_alertas := v_alertas || jsonb_build_object('severidad','warning','codigo','margen_categoria_negativo','titulo','Categorías con margen negativo',
      'detalle', v_cat_neg::text||' categoría(s) con margen comercial negativo',
      'valor', v_cat_neg, 'seccion','categorias');
  END IF;

  IF (v_result->'flags'->>'pct_sin_costo')::numeric >= 1 THEN
    v_alertas := v_alertas || jsonb_build_object('severidad','info','codigo','productos_sin_costo','titulo','Productos sin costo',
      'detalle', (v_result->'flags'->>'pct_sin_costo')::text||'% de la venta es de productos sin costo (margen sobreestimado)',
      'valor', (v_result->'flags'->>'ingreso_sin_costo')::numeric, 'seccion','categorias');
  END IF;

  SELECT COALESCE(jsonb_agg(a ORDER BY array_position(ARRAY['critical','warning','info'], a->>'severidad')), '[]'::jsonb)
    INTO v_alertas FROM jsonb_array_elements(v_alertas) a;

  v_result := v_result || jsonb_build_object('comparativo', COALESCE(v_comparativo,'null'::jsonb), 'alertas', v_alertas);
  RETURN v_result;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3 · posicion_fiscal
-- ---------------------------------------------------------------------------
-- El VB no se factura. Ya quedaba fuera de fc_* y zz_* (y de pct_fc) por los
-- FILTER explícitos; se agrega vb_pedidos / vb_monto, informativo.
CREATE OR REPLACE FUNCTION public.posicion_fiscal(p_sucursal_id bigint, p_desde date, p_hasta date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursales bigint[]; v_asignadas bigint[]; v_nombre text; v_result jsonb;
  v_es_servicio boolean := (auth.uid() IS NULL);
BEGIN
  IF NOT v_es_servicio THEN
    IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin') THEN
      RAISE EXCEPTION 'Acceso denegado: se requiere rol admin'; END IF;
    SELECT array_agg(sucursal_id) INTO v_asignadas FROM usuario_sucursales WHERE usuario_id = auth.uid();
    IF v_asignadas IS NULL THEN RAISE EXCEPTION 'Acceso denegado: el usuario no tiene sucursales asignadas'; END IF;
  END IF;
  IF p_sucursal_id IS NULL THEN
    SELECT array_agg(id) INTO v_sucursales FROM sucursales WHERE activa;
    IF NOT v_es_servicio THEN
      SELECT array_agg(s) INTO v_sucursales FROM unnest(v_sucursales) AS s WHERE s = ANY(v_asignadas); END IF;
    v_nombre := 'Red (consolidado)';
  ELSE
    IF NOT v_es_servicio AND NOT (p_sucursal_id = ANY(v_asignadas)) THEN
      RAISE EXCEPTION 'Acceso denegado: la sucursal % no está asignada al usuario', p_sucursal_id; END IF;
    v_sucursales := ARRAY[p_sucursal_id];
    SELECT nombre INTO v_nombre FROM sucursales WHERE id = p_sucursal_id;
  END IF;
  IF v_sucursales IS NULL OR array_length(v_sucursales,1) IS NULL THEN
    RAISE EXCEPTION 'Acceso denegado: sin sucursales disponibles para el usuario'; END IF;

  WITH
  ped AS (
    SELECT id, total, COALESCE(total_neto, total) AS total_neto,
           COALESCE(total_iva, 0) AS total_iva, COALESCE(tipo_factura, 'ZZ') AS tipo_factura
    FROM pedidos
    -- mig 252 (#632): canal EN NEGATIVO, como la 241. La venta del bot se factura igual.
    WHERE estado = 'entregado' AND canal <> 'cambio'
      AND fecha BETWEEN p_desde AND p_hasta AND sucursal_id = ANY(v_sucursales)
  ),
  v_fc AS (
    SELECT COALESCE(SUM(pi.cantidad * COALESCE(pi.impuestos_internos_unitario, 0)), 0) AS ii_ventas
    FROM ped p JOIN pedido_items pi ON pi.pedido_id = p.id
    WHERE p.tipo_factura = 'FC' AND NOT COALESCE(pi.es_bonificacion, false)
  ),
  ventas AS (
    SELECT COUNT(*) FILTER (WHERE tipo_factura='FC') AS fc_pedidos,
           COALESCE(SUM(total) FILTER (WHERE tipo_factura='FC'), 0) AS fc_venta,
           COALESCE(SUM(total_neto) FILTER (WHERE tipo_factura='FC'), 0) AS fc_neto,
           COALESCE(SUM(total_iva) FILTER (WHERE tipo_factura='FC'), 0) AS iva_debito,
           COUNT(*) FILTER (WHERE tipo_factura='ZZ') AS zz_pedidos,
           COALESCE(SUM(total) FILTER (WHERE tipo_factura='ZZ'), 0) AS zz_venta,
           -- 3XB: el vale blanco no se factura ni es venta. Ya quedaba fuera de
           -- fc_* y zz_* por los FILTER; se informa aparte (a costo, sin IVA) y
           -- no entra en pct_fc ni en el debito fiscal.
           COUNT(*) FILTER (WHERE tipo_factura='VB') AS vb_pedidos,
           COALESCE(SUM(total) FILTER (WHERE tipo_factura='VB'), 0) AS vb_monto
    FROM ped
  ),
  compras_p AS (
    SELECT COALESCE(tipo_factura, 'FC') AS tipo_factura, subtotal, iva,
           -- mig 293: solo A y M (o FC sin letra, legado) dan credito fiscal.
           (COALESCE(tipo_factura, 'FC') = 'FC'
            AND COALESCE(letra_comprobante, 'A') IN ('A', 'M')) AS iva_computable,
           COALESCE(impuestos_internos, 0) AS impuestos_internos,
           COALESCE(percepcion_iva, 0) AS percepcion_iva,
           COALESCE(percepcion_iibb, 0) AS percepcion_iibb, total
    FROM compras
    WHERE sucursal_id = ANY(v_sucursales)
      AND fecha_compra BETWEEN p_desde AND p_hasta
      AND COALESCE(estado, '') <> 'cancelada'
  ),
  -- mig 280 (#867): notas de credito de compra por la fecha de la NOTA.
  -- IVA solo de compras FC (una ZZ no tiene IVA que acreditar); el II de
  -- todas, igual que ii_compras.
  nc_k AS (
    SELECT COALESCE(SUM(nc.iva) FILTER (WHERE COALESCE(c.tipo_factura, 'FC') = 'FC'
                                         AND COALESCE(c.letra_comprobante, 'A') IN ('A', 'M')), 0) AS iva_nc,  /* mig 293 */
           COALESCE(SUM(nc.impuestos_internos), 0) AS ii_nc
    FROM notas_credito nc
    JOIN compras c ON c.id = nc.compra_id AND c.sucursal_id = nc.sucursal_id
    WHERE nc.sucursal_id = ANY(v_sucursales)
      AND nc.fecha BETWEEN p_desde AND p_hasta
      AND COALESCE(c.estado, '') <> 'cancelada'
  ),
  -- mig 281 (#866): IVA de cargos con factura de un tercero (el flete del
  -- transportista), por la fecha de la COMPRA y sin mirar tipo_factura: la
  -- factura del transportista no depende de la del proveedor.
  fletes_k AS (
    SELECT COALESCE(SUM(cc.iva_monto), 0) AS iva_fletes
    FROM compra_cargos cc
    JOIN compras c ON c.id = cc.compra_id AND c.sucursal_id = cc.sucursal_id
    WHERE cc.comprobante_tercero
      AND c.sucursal_id = ANY(v_sucursales)
      AND c.fecha_compra BETWEEN p_desde AND p_hasta
      AND COALESCE(c.estado, '') <> 'cancelada'
  ),
  compras_k AS (
    SELECT COUNT(*) FILTER (WHERE tipo_factura='FC') AS fc_compras,
           COALESCE(SUM(total) FILTER (WHERE tipo_factura='FC'), 0) AS fc_total,
           COALESCE(SUM(subtotal) FILTER (WHERE tipo_factura='FC'), 0) AS fc_neto,
           COALESCE(SUM(iva) FILTER (WHERE iva_computable), 0) - (SELECT iva_nc FROM nc_k) + (SELECT iva_fletes FROM fletes_k) AS iva_credito,
           COALESCE(SUM(impuestos_internos), 0) - (SELECT ii_nc FROM nc_k) AS ii_compras,
           COALESCE(SUM(percepcion_iva), 0) AS percepcion_iva,
           COALESCE(SUM(percepcion_iibb), 0) AS percepcion_iibb,
           COUNT(*) FILTER (WHERE tipo_factura='ZZ') AS zz_compras,
           COALESCE(SUM(total) FILTER (WHERE tipo_factura='ZZ'), 0) AS zz_total
    FROM compras_p
  )
  SELECT jsonb_build_object(
    'meta', jsonb_build_object('sucursal_id', p_sucursal_id, 'sucursal_nombre', COALESCE(v_nombre, '?'),
      'desde', p_desde, 'hasta', p_hasta, 'generado_at', now(),
      'nota', 'Estimación de gestión; no reemplaza la liquidación del contador. II es costo; percepciones son créditos.'),
    'ventas', (SELECT jsonb_build_object(
        'fc_pedidos', v.fc_pedidos, 'fc_venta', v.fc_venta, 'fc_neto', v.fc_neto,
        'iva_debito', v.iva_debito, 'ii_ventas_fc', f.ii_ventas,
        'zz_pedidos', v.zz_pedidos, 'zz_venta', v.zz_venta,
        'vb_pedidos', v.vb_pedidos, 'vb_monto', v.vb_monto,
        'pct_fc', CASE WHEN v.fc_venta + v.zz_venta > 0
                       THEN round(100.0 * v.fc_venta / (v.fc_venta + v.zz_venta), 1) ELSE 0 END)
      FROM ventas v, v_fc f),
    'compras', (SELECT jsonb_build_object(
        'fc_compras', c.fc_compras, 'fc_total', c.fc_total, 'fc_neto', c.fc_neto,
        'iva_credito', c.iva_credito, 'ii_compras', c.ii_compras,
        'iva_fletes', (SELECT iva_fletes FROM fletes_k),
        'iva_notas_credito', (SELECT iva_nc FROM nc_k), 'ii_notas_credito', (SELECT ii_nc FROM nc_k),
        'percepcion_iva', c.percepcion_iva, 'percepcion_iibb', c.percepcion_iibb,
        'zz_compras', c.zz_compras, 'zz_total', c.zz_total,
        'pct_fc', CASE WHEN c.fc_total + c.zz_total > 0
                       THEN round(100.0 * c.fc_total / (c.fc_total + c.zz_total), 1) ELSE 0 END)
      FROM compras_k c),
    'posicion', (SELECT jsonb_build_object(
        'saldo_tecnico', v.iva_debito - c.iva_credito - c.percepcion_iva,
        'iva_debito', v.iva_debito,
        'iva_credito', c.iva_credito,
        'percepciones_a_favor', c.percepcion_iva + c.percepcion_iibb)
      FROM ventas v, compras_k c)
  ) INTO v_result;

  RETURN v_result;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4 · reporte_rentabilidad
-- ---------------------------------------------------------------------------
-- VB fuera de `ped` y rama VB explícita en el CASE del ingreso.
CREATE OR REPLACE FUNCTION public.reporte_rentabilidad(p_desde date DEFAULT NULL::date, p_hasta date DEFAULT NULL::date, p_sucursal_id bigint DEFAULT NULL::bigint)
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
  v_out         jsonb;
BEGIN
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
    v_sucursales := COALESCE(v_asignadas, ARRAY(SELECT id FROM sucursales));
  ELSE
    v_sucursales := ARRAY[p_sucursal_id];
  END IF;

  WITH ped AS (
    SELECT p.id, p.tipo_factura
    FROM pedidos p
    WHERE p.estado = 'entregado'
      AND p.canal <> 'cambio'
      -- 3XB: el vale blanco va a costo; no es venta ni deja margen.
      AND p.tipo_factura IS DISTINCT FROM 'VB'
      AND p.sucursal_id = ANY(v_sucursales)
      AND (p_desde IS NULL OR p.fecha >= p_desde)
      AND (p_hasta IS NULL OR p.fecha <= p_hasta)
  ),
  it AS (
    SELECT pi.producto_id,
           prod.nombre,
           prod.codigo,
           pi.cantidad,
           COALESCE(pi.subtotal, pi.cantidad * pi.precio_unitario) AS subtotal,
           pi.cantidad * COALESCE(
             pi.ingreso_real_unitario,
             CASE WHEN ped.tipo_factura = 'FC'
                  THEN COALESCE(pi.neto_unitario, pi.precio_unitario)
                  -- 3XB: rama VB explicita, no un ELSE por accidente. Sin IVA:
                  -- el precio ES el ingreso (y el costo). Hoy `ped` ya lo excluye.
                  WHEN ped.tipo_factura = 'VB'
                  THEN pi.precio_unitario
                  ELSE pi.precio_unitario END
           ) AS ingreso_real,
           pi.cantidad * COALESCE(pi.iva_unitario, 0)                AS iva,
           pi.cantidad * COALESCE(pi.impuestos_internos_unitario, 0) AS imp_internos,
           pi.cantidad * COALESCE(pi.neto_unitario,
             COALESCE(pi.ingreso_real_unitario, pi.precio_unitario)) AS neto,
           pi.cantidad * COALESCE(
             pi.costo_unitario_al_crear,
             prod.costo_promedio,
             prod.costo_real,
             ROUND(prod.costo_sin_iva * (1 + COALESCE(prod.impuestos_internos,0)/100), 4)
           ) AS costo
    FROM ped
    JOIN pedido_items pi ON pi.pedido_id = ped.id
    JOIN productos prod ON prod.id = pi.producto_id
  ),
  por_producto AS (
    SELECT it.producto_id, it.nombre, it.codigo,
           SUM(it.cantidad)     AS cantidad_vendida,
           SUM(it.ingreso_real) AS ingresos,
           SUM(COALESCE(it.costo,0)) AS costos
    FROM it GROUP BY it.producto_id, it.nombre, it.codigo
  )
  SELECT jsonb_build_object(
    'productos', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id',               pp.producto_id,
        'nombre',           pp.nombre,
        'codigo',           pp.codigo,
        'cantidadVendida',  pp.cantidad_vendida,
        'ingresos',         ROUND(pp.ingresos,2),
        'costos',           ROUND(pp.costos,2),
        'margen',           ROUND(pp.ingresos - pp.costos,2),
        'margenPorcentaje', CASE WHEN pp.ingresos > 0
                                 THEN ROUND((pp.ingresos - pp.costos) / pp.ingresos * 100, 2)
                                 ELSE 0 END
      ) ORDER BY (pp.ingresos - pp.costos) DESC)
      FROM por_producto pp
    ), '[]'::jsonb),
    'totales', (
      SELECT jsonb_build_object(
        'ingresosTotales',   COALESCE(ROUND(SUM(ingresos),2),0),
        'costosTotales',     COALESCE(ROUND(SUM(costos),2),0),
        'margenTotal',       COALESCE(ROUND(SUM(ingresos) - SUM(costos),2),0),
        'margenPorcentaje',  CASE WHEN COALESCE(SUM(ingresos),0) > 0
                                  THEN ROUND((SUM(ingresos)-SUM(costos))/SUM(ingresos)*100, 2)
                                  ELSE 0 END,
        'cantidadPedidos',   (SELECT COUNT(*) FROM ped),
        'ventasBrutas',      (SELECT COALESCE(ROUND(SUM(subtotal),2),0) FROM it),
        'ivaDiscriminado',   (SELECT COALESCE(ROUND(SUM(iva),2),0) FROM it),
        'impuestosInternos', (SELECT COALESCE(ROUND(SUM(imp_internos),2),0) FROM it),
        'ventasNetas',       (SELECT COALESCE(ROUND(SUM(neto),2),0) FROM it)
      ) FROM por_producto
    )
  ) INTO v_out;

  RETURN v_out;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 5 · calcular_comisiones (N16)
-- ---------------------------------------------------------------------------
-- Copia de la 309 (= prod) + VB + adelanto de sueldo. Los filtros de la 309 se
-- quedan hasta el backfill (3XC).
CREATE OR REPLACE FUNCTION public.calcular_comisiones(p_desde date, p_hasta date, p_sucursal_ids bigint[] DEFAULT NULL::bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursales bigint[];
  v_pct_prev   numeric;
  v_pct_otros  numeric;
  v_out        jsonb;
BEGIN
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Solo un admin puede ver el calculo de comisiones' USING ERRCODE = '42501';
  END IF;

  IF p_desde IS NULL OR p_hasta IS NULL OR p_hasta < p_desde THEN
    RAISE EXCEPTION 'Rango de fechas invalido';
  END IF;

  v_sucursales := COALESCE(
    p_sucursal_ids,
    ARRAY(SELECT sucursal_id FROM usuario_sucursales WHERE usuario_id = auth.uid())
  );
  IF v_sucursales IS NULL OR array_length(v_sucursales, 1) IS NULL THEN
    v_sucursales := ARRAY(SELECT id FROM sucursales);
  END IF;

  SELECT COALESCE(MAX(pc.comision_pct_preventista), 2),
         COALESCE(MAX(pc.comision_pct_otros), 0)
    INTO v_pct_prev, v_pct_otros
    FROM politicas_comerciales pc
   WHERE pc.sucursal_id = ANY(v_sucursales);
  v_pct_prev  := COALESCE(v_pct_prev, 2);
  v_pct_otros := COALESCE(v_pct_otros, 0);

  WITH ped AS (
    SELECT p.id, p.usuario_id, p.fecha, p.sucursal_id
    FROM pedidos p
    WHERE p.estado = 'entregado'
      AND p.canal <> 'cambio'
      AND p.fecha BETWEEN p_desde AND p_hasta
      AND p.sucursal_id = ANY(v_sucursales)
      AND p.usuario_id IN (SELECT id FROM perfiles)
      -- Vale blanco: consumo interno, no comisiona (mig 309).
      AND COALESCE(p.forma_pago, '') <> 'vale_blanco'
      AND NOT EXISTS (
        SELECT 1 FROM pagos g
        WHERE g.pedido_id = p.id AND g.forma_pago = 'vale_blanco'
      )
      -- 3XB (N16): el vale blanco pasa a ser tipo de comprobante. Los dos
      -- filtros de arriba (309) quedan como red mientras los 193 pedidos
      -- historicos sigan siendo ZZ con pago 'vale_blanco'; se quitan en la
      -- migracion del backfill (3XC), que convierte esos pedidos a VB.
      AND p.tipo_factura IS DISTINCT FROM 'VB'
      -- Y lo que se cobra con adelanto de sueldo es consumo de un empleado,
      -- no una venta que alguien salio a hacer. Sin esto, cuando el backfill
      -- pase los 2 pagos de Fede de 'vale_blanco' a 'adelanto_sueldo', esos
      -- pedidos volverian a comisionar. Pedido entero, como en la 309.
      AND NOT EXISTS (
        SELECT 1 FROM pagos g
        WHERE g.pedido_id = p.id AND g.forma_pago = 'adelanto_sueldo'
      )
  ),
  it AS (
    SELECT ped.usuario_id, ped.fecha, ped.sucursal_id,
           pi.subtotal,
           pi.producto_id,
           pi.origen_precio,
           prod.categoria_id,
           perf.rol AS rol_vendedor
    FROM ped
    JOIN pedido_items pi ON pi.pedido_id = ped.id
    LEFT JOIN productos prod ON prod.id = pi.producto_id
    LEFT JOIN perfiles perf ON perf.id = ped.usuario_id
    WHERE COALESCE(pi.es_bonificacion, false) = false
  ),
  con_pct AS (
    SELECT it.*,
      COALESCE((
        SELECT r.porcentaje FROM comision_reglas r
        WHERE r.activo
          AND (r.sucursal_id    IS NULL OR r.sucursal_id    = it.sucursal_id)
          AND (r.preventista_id IS NULL OR r.preventista_id = it.usuario_id)
          AND (r.origen_precio  IS NULL OR r.origen_precio  = it.origen_precio)
          AND (r.producto_id    IS NULL OR r.producto_id    = it.producto_id)
          AND (r.categoria_id   IS NULL OR r.categoria_id   = it.categoria_id)
          AND r.vigente_desde <= it.fecha
          AND (r.vigente_hasta IS NULL OR r.vigente_hasta >= it.fecha)
        ORDER BY
          (CASE WHEN r.preventista_id IS NOT NULL THEN 8 ELSE 0 END
         + CASE WHEN r.producto_id    IS NOT NULL THEN 4 ELSE 0 END
         + CASE WHEN r.categoria_id   IS NOT NULL THEN 2 ELSE 0 END
         + CASE WHEN r.origen_precio  IS NOT NULL THEN 1 ELSE 0 END) DESC,
          (r.sucursal_id IS NOT NULL) DESC,
          r.vigente_desde DESC,
          r.id DESC
        LIMIT 1
      ),
      CASE WHEN it.rol_vendedor = 'preventista'
           THEN COALESCE(pc.comision_pct_preventista, 2)
           ELSE COALESCE(pc.comision_pct_otros, 0)
      END) AS pct
    FROM it
    LEFT JOIN politicas_comerciales pc ON pc.sucursal_id = it.sucursal_id
  ),
  por_origen AS (
    SELECT usuario_id,
           COALESCE(origen_precio, 'sin_dato') AS origen,
           SUM(subtotal)                 AS base,
           SUM(subtotal * pct / 100.0)   AS comision,
           COUNT(*)                      AS items
    FROM con_pct
    GROUP BY usuario_id, COALESCE(origen_precio, 'sin_dato')
  ),
  por_preventista AS (
    SELECT c.usuario_id,
           COALESCE(pf.nombre, 'Sin nombre')                                  AS nombre,
           pf.email,
           SUM(c.subtotal)                                                    AS base,
           SUM(c.subtotal * c.pct / 100.0)                                    AS comision,
           COUNT(*)                                                           AS items,
           COUNT(*) FILTER (WHERE c.origen_precio IS NULL)                    AS items_sin_desglose,
           COALESCE(SUM(c.subtotal) FILTER (WHERE c.origen_precio IS NULL),0) AS base_sin_desglose
    FROM con_pct c
    LEFT JOIN perfiles pf ON pf.id = c.usuario_id
    GROUP BY c.usuario_id, pf.nombre, pf.email
  )
  SELECT jsonb_build_object(
    'desde', p_desde,
    'hasta', p_hasta,
    'comision_default', v_pct_prev,
    'comision_pct_preventista', v_pct_prev,
    'comision_pct_otros', v_pct_otros,
    'preventistas', COALESCE((
      SELECT jsonb_agg(x ORDER BY (x->>'base')::numeric DESC)
      FROM (
        SELECT jsonb_build_object(
          'id', pp.usuario_id,
          'nombre', pp.nombre,
          'email', pp.email,
          'base', ROUND(pp.base, 2),
          'comision', ROUND(pp.comision, 2),
          'items', pp.items,
          'items_sin_desglose', pp.items_sin_desglose,
          'base_sin_desglose', ROUND(pp.base_sin_desglose, 2),
          'por_origen', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
              'origen', po.origen,
              'base', ROUND(po.base, 2),
              'comision', ROUND(po.comision, 2),
              'items', po.items
            ) ORDER BY po.base DESC)
            FROM por_origen po WHERE po.usuario_id = pp.usuario_id
          ), '[]'::jsonb)
        ) AS x
        FROM por_preventista pp
      ) s
    ), '[]'::jsonb),
    'totales', (
      SELECT jsonb_build_object(
        'base', COALESCE(ROUND(SUM(base), 2), 0),
        'comision', COALESCE(ROUND(SUM(comision), 2), 0),
        'items', COALESCE(SUM(items), 0),
        'items_sin_desglose', COALESCE(SUM(items_sin_desglose), 0),
        'base_sin_desglose', COALESCE(ROUND(SUM(base_sin_desglose), 2), 0)
      ) FROM por_preventista
    )
  ) INTO v_out;

  RETURN v_out;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 6 · reporte_ventas_por_preventista
-- ---------------------------------------------------------------------------
-- VB fuera de totalVentas y de totalPagado.
CREATE OR REPLACE FUNCTION public.reporte_ventas_por_preventista(p_desde date DEFAULT NULL::date, p_hasta date DEFAULT NULL::date, p_sucursal_id bigint DEFAULT NULL::bigint)
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
  v_out         jsonb;
BEGIN
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
    v_sucursales := COALESCE(v_asignadas, ARRAY(SELECT id FROM sucursales));
  ELSE
    v_sucursales := ARRAY[p_sucursal_id];
  END IF;

  WITH ped AS (
    SELECT p.usuario_id, p.total, p.estado,
           COALESCE(p.monto_pagado,0) AS monto_pagado
    FROM pedidos p
    WHERE p.estado = 'entregado'
      AND p.canal <> 'cambio'
      -- 3XB: el vale blanco no es venta, y su monto_pagado (= total por
      -- construccion) tampoco es plata cobrada: fuera de totalVentas y de
      -- totalPagado juntos. bot_ventas_por_preventista lo hereda (BOT-B).
      AND p.tipo_factura IS DISTINCT FROM 'VB'
      AND p.sucursal_id = ANY(v_sucursales)
      AND (p_desde IS NULL OR p.fecha >= p_desde)
      AND (p_hasta IS NULL OR p.fecha <= p_hasta)
      AND p.usuario_id IS NOT NULL
  ),
  por_usuario AS (
    SELECT ped.usuario_id,
           SUM(ped.total)                                  AS total_ventas,
           COUNT(*)                                        AS cantidad_pedidos,
           SUM(ped.monto_pagado)                           AS total_pagado,
           SUM(GREATEST(0, ped.total - ped.monto_pagado))  AS total_pendiente
    FROM ped GROUP BY ped.usuario_id
  )
  SELECT COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'id',                pu.usuario_id,
      'nombre',            COALESCE(pf.nombre, 'Usuario desconocido'),
      'email',             COALESCE(pf.email, 'N/A'),
      'totalVentas',       ROUND(pu.total_ventas,2),
      'cantidadPedidos',   pu.cantidad_pedidos,
      'totalPagado',       ROUND(pu.total_pagado,2),
      'totalPendiente',    ROUND(pu.total_pendiente,2)
    ) ORDER BY pu.total_ventas DESC)
    FROM por_usuario pu
    LEFT JOIN perfiles pf ON pf.id = pu.usuario_id
  ), '[]'::jsonb) INTO v_out;

  RETURN v_out;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 7 · obtener_estadisticas_pedidos
-- ---------------------------------------------------------------------------
-- total_ventas y promedio_ticket sin VB; consumo_interno {monto, pedidos} aparte.
-- No mira canal (otro bug, va a issue): acá sólo se agrega el VB.
CREATE OR REPLACE FUNCTION public.obtener_estadisticas_pedidos(p_fecha_desde timestamp with time zone DEFAULT NULL::timestamp with time zone, p_fecha_hasta timestamp with time zone DEFAULT NULL::timestamp with time zone, p_usuario_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal_id BIGINT;
  v_result JSONB;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'total', COUNT(*)::int,
    'pendientes', COUNT(*) FILTER (WHERE estado = 'pendiente')::int,
    'en_preparacion', COUNT(*) FILTER (WHERE estado = 'en_preparacion')::int,
    'en_reparto', COUNT(*) FILTER (WHERE estado IN ('en_reparto', 'asignado'))::int,
    'entregados', COUNT(*) FILTER (WHERE estado = 'entregado')::int,
    'cancelados', COUNT(*) FILTER (WHERE estado = 'cancelado')::int,
    -- 3XB: el vale blanco no es venta ni ticket; va aparte, a costo. Los
    -- conteos por estado no cambian: son operativos, no venta.
    'total_ventas', COALESCE(SUM(total) FILTER (WHERE estado = 'entregado' AND tipo_factura IS DISTINCT FROM 'VB'), 0)::numeric(12,2),
    'promedio_ticket', COALESCE(AVG(total) FILTER (WHERE estado = 'entregado' AND tipo_factura IS DISTINCT FROM 'VB'), 0)::numeric(12,2),
    'consumo_interno', jsonb_build_object(
      'monto', COALESCE(SUM(total) FILTER (WHERE estado = 'entregado' AND tipo_factura = 'VB'), 0)::numeric(12,2),
      'pedidos', COUNT(*) FILTER (WHERE estado = 'entregado' AND tipo_factura = 'VB')::int
    ),
    'por_estado', COALESCE(
      (SELECT jsonb_object_agg(estado, cnt)
       FROM (
         SELECT p.estado, COUNT(*)::int AS cnt
         FROM pedidos p
         WHERE p.sucursal_id = v_sucursal_id
           AND (p_fecha_desde IS NULL OR p.created_at >= p_fecha_desde)
           AND (p_fecha_hasta IS NULL OR p.created_at <= p_fecha_hasta)
           AND (p_usuario_id IS NULL OR p.usuario_id = p_usuario_id)
         GROUP BY p.estado
       ) s),
      '{}'::jsonb
    )
  ) INTO v_result
  FROM pedidos p
  WHERE p.sucursal_id = v_sucursal_id
    AND (p_fecha_desde IS NULL OR p.created_at >= p_fecha_desde)
    AND (p_fecha_hasta IS NULL OR p.created_at <= p_fecha_hasta)
    AND (p_usuario_id IS NULL OR p.usuario_id = p_usuario_id);

  IF v_result IS NULL THEN
    v_result := jsonb_build_object(
      'total', 0,
      'pendientes', 0,
      'en_preparacion', 0,
      'en_reparto', 0,
      'entregados', 0,
      'cancelados', 0,
      'total_ventas', 0,
      'promedio_ticket', 0,
      'consumo_interno', jsonb_build_object('monto', 0, 'pedidos', 0),
      'por_estado', '{}'::jsonb
    );
  END IF;

  RETURN v_result;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 8 · avance_metas_preventista
-- ---------------------------------------------------------------------------
-- El VB no suma a ninguna meta ni cuenta como primer pedido de un cliente.
CREATE OR REPLACE FUNCTION public.avance_metas_preventista(p_preventista_id uuid DEFAULT NULL::uuid, p_periodo date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_target      uuid;
  v_mes_desde   date;
  v_mes_hasta   date;
  v_min         date;
  v_max         date;
  v_nombre      text;
  v_sucursales  bigint[];
  v_result      jsonb;
  v_sin_marca   integer := 0;
  v_hay_marca   boolean := false;
BEGIN
  v_target    := COALESCE(p_preventista_id, auth.uid());
  v_mes_desde := date_trunc('month', COALESCE(p_periodo, current_date))::date;
  v_mes_hasta := (v_mes_desde + interval '1 month - 1 day')::date;

  IF v_target IS NULL THEN
    RAISE EXCEPTION 'Sin usuario' USING ERRCODE = '42501';
  END IF;

  IF auth.uid() IS NOT NULL AND v_target <> auth.uid() AND NOT es_admin() THEN
    RAISE EXCEPTION 'Acceso denegado' USING ERRCODE = '42501';
  END IF;

  SELECT nombre INTO v_nombre FROM perfiles WHERE id = v_target;

  SELECT array_agg(DISTINCT sucursal_id), min(periodo), max(periodo_fin)
    INTO v_sucursales, v_min, v_max
  FROM metas_preventista
  WHERE preventista_id = v_target AND activo
    AND periodo <= v_mes_hasta AND periodo_fin >= v_mes_desde;

  IF v_sucursales IS NULL THEN
    RETURN jsonb_build_object(
      'preventista_id', v_target,
      'nombre', v_nombre,
      'periodo', v_mes_desde,
      'dias_transcurridos', LEAST(EXTRACT(DAY FROM current_date)::int, EXTRACT(DAY FROM v_mes_hasta)::int),
      'dias_periodo', EXTRACT(DAY FROM v_mes_hasta)::int,
      'metas', '[]'::jsonb,
      'resumen', jsonb_build_object('total', 0, 'cumplidas', 0, 'en_riesgo', 0),
      'productos_sin_marca', 0
    );
  END IF;

  WITH
  metas AS (
    SELECT * FROM metas_preventista
    WHERE preventista_id = v_target AND activo
      AND periodo <= v_mes_hasta AND periodo_fin >= v_mes_desde
  ),
  ped AS MATERIALIZED (
    SELECT id, cliente_id, sucursal_id, fecha
    FROM pedidos
    WHERE usuario_id = v_target
      AND estado = 'entregado'
      AND canal <> 'cambio'
      -- 3XB: el vale blanco no cuenta para ninguna meta (facturacion,
      -- unidades ni cobertura).
      AND tipo_factura IS DISTINCT FROM 'VB'
      AND fecha BETWEEN v_min AND v_max
      AND sucursal_id = ANY(v_sucursales)
  ),
  it AS MATERIALIZED (
    SELECT p.sucursal_id, p.fecha, pi.cantidad, pi.subtotal,
           pi.producto_id, prod.categoria_id, prod.marca_id
    FROM ped p
    JOIN pedido_items pi ON pi.pedido_id = p.id
    JOIN productos prod  ON prod.id = pi.producto_id
    WHERE pi.es_bonificacion IS NOT TRUE
  ),
  primer_pedido AS (
    SELECT DISTINCT ON (p.cliente_id, p.sucursal_id)
           p.cliente_id, p.sucursal_id, p.usuario_id, p.fecha
    FROM pedidos p
    WHERE p.estado = 'entregado' AND p.canal <> 'cambio'
      AND p.tipo_factura IS DISTINCT FROM 'VB'  -- 3XB: un vale no hace cliente nuevo
      AND p.sucursal_id = ANY(v_sucursales)
    ORDER BY p.cliente_id, p.sucursal_id, p.fecha, p.id
  ),
  logrado AS (
    SELECT m.*,
      (m.periodo_fin - m.periodo + 1) AS dias_periodo,
      GREATEST(0, LEAST(current_date - m.periodo + 1, m.periodo_fin - m.periodo + 1)) AS dias_trans,
      CASE m.tipo_meta
        WHEN 'facturacion' THEN (
          SELECT COALESCE(SUM(i.subtotal), 0) FROM it i
          WHERE i.sucursal_id = m.sucursal_id
            AND i.fecha BETWEEN m.periodo AND m.periodo_fin
            AND (m.marca_id     IS NULL OR i.marca_id     = m.marca_id)
            AND (m.categoria_id IS NULL OR i.categoria_id = m.categoria_id)
            AND (m.producto_ids IS NULL OR i.producto_id  = ANY(m.producto_ids))
        )
        WHEN 'unidades' THEN (
          SELECT COALESCE(SUM(i.cantidad), 0) FROM it i
          WHERE i.sucursal_id = m.sucursal_id
            AND i.fecha BETWEEN m.periodo AND m.periodo_fin
            AND (m.marca_id     IS NULL OR i.marca_id     = m.marca_id)
            AND (m.categoria_id IS NULL OR i.categoria_id = m.categoria_id)
            AND (m.producto_ids IS NULL OR i.producto_id  = ANY(m.producto_ids))
        )
        WHEN 'cobertura' THEN (
          SELECT COUNT(DISTINCT p.cliente_id) FROM ped p
          WHERE p.sucursal_id = m.sucursal_id
            AND p.fecha BETWEEN m.periodo AND m.periodo_fin
        )
        WHEN 'clientes_nuevos' THEN (
          SELECT COUNT(*) FROM primer_pedido pp
          WHERE pp.sucursal_id = m.sucursal_id
            AND pp.usuario_id = v_target
            AND pp.fecha BETWEEN m.periodo AND m.periodo_fin
        )
      END AS logrado
    FROM metas m
  ),
  calc AS (
    SELECT l.*,
      ROUND(l.valor_objetivo * l.dias_trans / NULLIF(l.dias_periodo, 0), 2) AS objetivo_prorrateado,
      ROUND(100 * l.logrado / NULLIF(l.valor_objetivo, 0), 1) AS pct,
      (l.dias_trans::numeric / NULLIF(l.dias_periodo, 0)) AS avance_periodo
    FROM logrado l
  ),
  estados AS (
    SELECT c.*,
      CASE
        WHEN c.logrado >= c.valor_objetivo THEN 'cumplida'
        WHEN c.logrado >= COALESCE(c.objetivo_prorrateado, 0) THEN 'adelantado'
        WHEN c.avance_periodo < 0.25 THEN 'en_curso'
        WHEN c.logrado >= 0.8 * COALESCE(c.objetivo_prorrateado, 0) THEN 'en_curso'
        ELSE 'en_riesgo'
      END AS estado
    FROM calc c
  )
  SELECT jsonb_build_object(
    'preventista_id', v_target,
    'nombre', v_nombre,
    'periodo', v_mes_desde,
    'dias_transcurridos', LEAST(EXTRACT(DAY FROM current_date)::int, EXTRACT(DAY FROM v_mes_hasta)::int),
    'dias_periodo', EXTRACT(DAY FROM v_mes_hasta)::int,
    'metas', COALESCE(jsonb_agg(jsonb_build_object(
        'id', c.id,
        'tipo_meta', c.tipo_meta,
        'unidad', CASE c.tipo_meta
                    WHEN 'facturacion' THEN '$'
                    WHEN 'unidades'    THEN 'u'
                    ELSE 'clientes' END,
        'alcance', CASE
          WHEN c.marca_id IS NOT NULL THEN jsonb_build_object(
            'tipo', 'marca', 'id', c.marca_id,
            'nombre', (SELECT nombre FROM marcas WHERE id = c.marca_id))
          WHEN c.categoria_id IS NOT NULL THEN jsonb_build_object(
            'tipo', 'categoria', 'id', c.categoria_id,
            'nombre', (SELECT nombre FROM categorias WHERE id = c.categoria_id))
          WHEN c.producto_ids IS NOT NULL THEN jsonb_build_object(
            'tipo', 'productos', 'id', NULL,
            'nombre', CASE WHEN cardinality(c.producto_ids) = 1
              THEN (SELECT nombre FROM productos WHERE id = c.producto_ids[1])
              ELSE cardinality(c.producto_ids) || ' productos' END,
            'productos', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', p.id, 'nombre', p.nombre) ORDER BY p.nombre), '[]'::jsonb)
                          FROM productos p WHERE p.id = ANY(c.producto_ids)))
          ELSE jsonb_build_object('tipo', 'global', 'id', NULL, 'nombre', NULL)
        END,
        'desde', c.periodo,
        'hasta', c.periodo_fin,
        'dias_periodo', c.dias_periodo,
        'dias_transcurridos', c.dias_trans,
        'periodo_personalizado', (c.periodo <> date_trunc('month', c.periodo)::date
                                  OR c.periodo_fin <> (date_trunc('month', c.periodo) + interval '1 month - 1 day')::date),
        'marca_id', c.marca_id,
        'categoria_id', c.categoria_id,
        'producto_ids', c.producto_ids,
        'objetivo', c.valor_objetivo,
        'logrado', c.logrado,
        'pct', COALESCE(c.pct, 0),
        'objetivo_prorrateado', COALESCE(c.objetivo_prorrateado, 0),
        'estado', c.estado
      ) ORDER BY c.tipo_meta, c.id), '[]'::jsonb),
    'resumen', jsonb_build_object(
      'total', COUNT(*),
      'cumplidas', COUNT(*) FILTER (WHERE c.estado = 'cumplida'),
      'en_riesgo', COUNT(*) FILTER (WHERE c.estado = 'en_riesgo')
    )
  ) INTO v_result
  FROM estados c;

  SELECT EXISTS (
    SELECT 1 FROM metas_preventista
    WHERE preventista_id = v_target AND activo
      AND periodo <= v_mes_hasta AND periodo_fin >= v_mes_desde
      AND marca_id IS NOT NULL
  ) INTO v_hay_marca;

  IF v_hay_marca THEN
    SELECT COUNT(*) INTO v_sin_marca
    FROM productos WHERE marca_id IS NULL AND sucursal_id = ANY(v_sucursales);
  END IF;

  RETURN v_result || jsonb_build_object('productos_sin_marca', v_sin_marca);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 9 · reporte_ventas_por_cliente
-- ---------------------------------------------------------------------------
-- VB fuera del ranking de clientes, de zonas y de la lista de vendedores.
CREATE OR REPLACE FUNCTION public.reporte_ventas_por_cliente(p_desde date, p_hasta date, p_preventista_id uuid DEFAULT NULL::uuid, p_sucursal_id bigint DEFAULT NULL::bigint)
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
      -- 3XB: el vale blanco (consumo interno) no entra al ranking de clientes
      -- ni al de vendedores. bot_ranking_clientes lo hereda (BOT-B).
      AND pe.tipo_factura IS DISTINCT FROM 'VB'
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
      'criterio',           'Pedidos entregados, por fecha de pedido, atribuidos a quien los cargó. Excluye cancelados, cambios/devoluciones y vales blancos (consumo interno).'
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


-- ---------------------------------------------------------------------------
-- 10 · Ensayo: la foto de DESPUÉS tiene que dar la de ANTES.
-- ---------------------------------------------------------------------------
SELECT pg_temp._vb_fotografiar('despues');

DO $ensayo$
DECLARE
  v_cero    constant jsonb := '{"monto": 0, "pedidos": 0}'::jsonb;
  v_admin   uuid;
  v_sucs    bigint[];
  v_r       record;
  v_a       jsonb;
  v_d       jsonb;
  v_hay     boolean;
  v_delta   numeric;
  v_comp    int := 0;
  v_adel    int := 0;
  v_fallas  text := '';
BEGIN
  -- Cada foto de antes tiene su par de después, y viceversa.
  IF EXISTS (
    SELECT 1
      FROM (SELECT * FROM _vb_foto WHERE etapa = 'antes') a
      FULL JOIN (SELECT * FROM _vb_foto WHERE etapa = 'despues') d
        ON d.fn = a.fn AND d.rango = a.rango AND d.extra = a.extra
       AND d.desde IS NOT DISTINCT FROM a.desde AND d.hasta IS NOT DISTINCT FROM a.hasta
       AND d.suc IS NOT DISTINCT FROM a.suc
     WHERE a.fn IS NULL OR d.fn IS NULL
  ) THEN
    RAISE EXCEPTION '3XB · las fotos de antes y de después no tienen las mismas llamadas';
  END IF;

  -- El mismo admin que usó la foto (para el universo de sucursales de la Red
  -- en calcular_comisiones, que sale de usuario_sucursales).
  SELECT us.usuario_id INTO v_admin
    FROM usuario_sucursales us
    JOIN perfiles pf   ON pf.id = us.usuario_id AND pf.rol = 'admin'
    JOIN sucursales s  ON s.id = us.sucursal_id AND s.activa
   GROUP BY us.usuario_id
   ORDER BY count(*) DESC, us.usuario_id
   LIMIT 1;

  FOR v_r IN
    SELECT a.fn, a.rango, a.desde, a.hasta, a.suc, a.extra, a.valor AS antes, d.valor AS despues
      FROM _vb_foto a
      JOIN _vb_foto d
        ON d.etapa = 'despues' AND d.fn = a.fn AND d.rango = a.rango AND d.extra = a.extra
       AND d.desde IS NOT DISTINCT FROM a.desde AND d.hasta IS NOT DISTINCT FROM a.hasta
       AND d.suc IS NOT DISTINCT FROM a.suc
     WHERE a.etapa = 'antes'
     ORDER BY a.fn, a.rango, a.suc NULLS FIRST, a.extra
  LOOP
    v_comp := v_comp + 1;
    v_a := v_r.antes;
    v_d := v_r.despues;

    IF v_r.fn = 'reporte_gerencial' THEN
      -- La línea nueva tiene que estar, en cero (hoy no hay VB), y viajar al comparativo.
      IF v_d->'kpis'->'consumo_interno' IS DISTINCT FROM v_cero THEN
        v_fallas := v_fallas || format(' [gerencial %s suc %s %s: kpis.consumo_interno = %s]',
          v_r.rango, v_r.suc, v_r.extra, v_d->'kpis'->'consumo_interno');
      END IF;
      IF v_r.extra = 'comparar' AND v_d->'comparativo'->'consumo_interno' IS DISTINCT FROM v_cero THEN
        v_fallas := v_fallas || format(' [gerencial %s suc %s: comparativo.consumo_interno = %s]',
          v_r.rango, v_r.suc, v_d->'comparativo'->'consumo_interno');
      END IF;
      v_d := v_d #- '{kpis,consumo_interno}' #- '{comparativo,consumo_interno}';
      -- Los top 10 (ORDER BY venta DESC LIMIT 10) pueden dejar afuera a uno u
      -- otro de dos empatados en el puesto 10 si cambia el plan: de esos se
      -- compara sólo la columna de venta, que en un empate es la misma.
      v_a := jsonb_set(jsonb_set(v_a,
               '{top_productos}', COALESCE((SELECT jsonb_agg(e->'venta') FROM jsonb_array_elements(v_a->'top_productos') e), '[]'::jsonb)),
               '{top_clientes}',  COALESCE((SELECT jsonb_agg(e->'venta') FROM jsonb_array_elements(v_a->'top_clientes') e), '[]'::jsonb));
      v_d := jsonb_set(jsonb_set(v_d,
               '{top_productos}', COALESCE((SELECT jsonb_agg(e->'venta') FROM jsonb_array_elements(v_d->'top_productos') e), '[]'::jsonb)),
               '{top_clientes}',  COALESCE((SELECT jsonb_agg(e->'venta') FROM jsonb_array_elements(v_d->'top_clientes') e), '[]'::jsonb));

    ELSIF v_r.fn = 'posicion_fiscal' THEN
      IF COALESCE((v_d->'ventas'->>'vb_pedidos')::numeric, -1) <> 0
         OR COALESCE((v_d->'ventas'->>'vb_monto')::numeric, -1) <> 0 THEN
        v_fallas := v_fallas || format(' [posicion_fiscal %s suc %s: vb_pedidos %s vb_monto %s]',
          v_r.rango, v_r.suc, v_d->'ventas'->'vb_pedidos', v_d->'ventas'->'vb_monto');
      END IF;
      v_d := v_d #- '{ventas,vb_pedidos}' #- '{ventas,vb_monto}';

    ELSIF v_r.fn = 'obtener_estadisticas_pedidos' THEN
      IF v_d->'consumo_interno' IS DISTINCT FROM v_cero THEN
        v_fallas := v_fallas || format(' [estadisticas %s suc %s: consumo_interno = %s]',
          v_r.rango, v_r.suc, v_d->'consumo_interno');
      END IF;
      v_d := v_d - 'consumo_interno';

    ELSIF v_r.fn = 'reporte_ventas_por_cliente' THEN
      -- El texto del criterio cambió a propósito (ahora nombra el vale blanco).
      v_a := v_a #- '{meta,criterio}';
      v_d := v_d #- '{meta,criterio}';

    ELSIF v_r.fn = 'calcular_comisiones' THEN
      -- N16: lo único que puede bajar es la base de los pedidos VB (hoy 0) o
      -- cobrados con adelanto de sueldo (hoy 0), que la 309 todavía no sacaba.
      v_sucs := CASE WHEN v_r.suc IS NULL
                     THEN ARRAY(SELECT sucursal_id FROM usuario_sucursales WHERE usuario_id = v_admin)
                     ELSE ARRAY[v_r.suc] END;
      SELECT count(*) > 0, COALESCE(SUM(pi.subtotal) FILTER (WHERE COALESCE(pi.es_bonificacion, false) = false), 0)
        INTO v_hay, v_delta
        FROM pedidos p
        JOIN pedido_items pi ON pi.pedido_id = p.id
       WHERE p.estado = 'entregado' AND p.canal <> 'cambio'
         AND p.fecha BETWEEN v_r.desde AND v_r.hasta
         AND p.sucursal_id = ANY(v_sucs)
         AND p.usuario_id IN (SELECT id FROM perfiles)
         AND COALESCE(p.forma_pago, '') <> 'vale_blanco'
         AND NOT EXISTS (SELECT 1 FROM pagos g WHERE g.pedido_id = p.id AND g.forma_pago = 'vale_blanco')
         AND (p.tipo_factura = 'VB'
              OR EXISTS (SELECT 1 FROM pagos g WHERE g.pedido_id = p.id AND g.forma_pago = 'adelanto_sueldo'));
      IF v_hay THEN
        v_adel := v_adel + 1;
        IF abs(  COALESCE((v_a->'totales'->>'base')::numeric, 0)
               - COALESCE((v_d->'totales'->>'base')::numeric, 0)
               - v_delta) > 0.02 THEN
          v_fallas := v_fallas || format(' [comisiones %s suc %s: base antes %s, después %s, esperado bajar %s]',
            v_r.rango, v_r.suc, v_a->'totales'->'base', v_d->'totales'->'base', round(v_delta, 2));
        END IF;
        CONTINUE;  -- con adelantos el resto del jsonb cambia a propósito
      END IF;
    END IF;

    IF pg_temp._vb_norm(v_a) IS DISTINCT FROM pg_temp._vb_norm(v_d) THEN
      v_fallas := v_fallas || format(' [%s %s suc %s %s: el resultado cambió]',
        v_r.fn, v_r.rango, COALESCE(v_r.suc::text, 'red'), v_r.extra);
    END IF;
  END LOOP;

  IF v_comp = 0 THEN
    RAISE EXCEPTION '3XB · el ensayo no comparó ninguna llamada: sin datos para verificar';
  END IF;
  IF v_fallas <> '' THEN
    RAISE EXCEPTION '3XB · sin ningún VB, los reportes no tendrían que moverse y se movieron:%', v_fallas;
  END IF;

  RAISE NOTICE '3XB · ensayo OK: % llamadas comparadas antes/después, idénticas (% de comisiones con adelanto de sueldo, verificadas por diferencia)',
    v_comp, v_adel;
END
$ensayo$;

-- ---------------------------------------------------------------------------
-- 11 · Los permisos siguen como estaban: CREATE OR REPLACE conserva la ACL, pero
--      se verifica (gate de check-permisos.mjs): ninguna alcanzable por PUBLIC
--      ni por anon, y las ocho siguen abiertas a authenticated (las llama el front).
-- ---------------------------------------------------------------------------
DO $permisos$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT p.oid, p.oid::regprocedure::text AS firma, p.proacl, p.proowner, p.prosecdef
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('reporte_gerencial','posicion_fiscal','reporte_rentabilidad',
                         'calcular_comisiones','reporte_ventas_por_preventista',
                         'obtener_estadisticas_pedidos','avance_metas_preventista',
                         'reporte_ventas_por_cliente')
  LOOP
    IF has_function_privilege('anon', v_f.oid, 'EXECUTE')
       OR EXISTS (SELECT 1 FROM aclexplode(COALESCE(v_f.proacl, acldefault('f', v_f.proowner))) a
                   WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE') THEN
      RAISE EXCEPTION '3XB · % quedó alcanzable por anon o PUBLIC', v_f.firma;
    END IF;
    IF NOT has_function_privilege('authenticated', v_f.oid, 'EXECUTE') THEN
      RAISE EXCEPTION '3XB · % perdió el EXECUTE de authenticated', v_f.firma;
    END IF;
    IF NOT v_f.prosecdef THEN
      RAISE EXCEPTION '3XB · % dejó de ser SECURITY DEFINER', v_f.firma;
    END IF;
  END LOOP;
END
$permisos$;

-- ---------------------------------------------------------------------------
-- 12 · Se saca el andamio.
-- ---------------------------------------------------------------------------
DROP FUNCTION pg_temp._vb_fotografiar(text);
DROP FUNCTION pg_temp._vb_norm(jsonb);
DROP TABLE _vb_foto;

COMMIT;
