-- 442 · Regalos: "Vendido" sin regalos (#1363), la versión del pedido al repartir un
-- regalo y el modo de la foto para el front (#1376, puntos 1 y 2).
--
-- 1. reporte_rentabilidad (#1363). "Vendido" sumaba `cantidad` de todas las líneas,
--    regalos incluidos, y la de un regalo fraccionado son partes de un bloque. Decisión
--    del dueño (02/11): "Vendido" va sin regalos, como `unidades` de reporte_gerencial,
--    y el regalo va aparte y en bloques (`cantidadRegalada`, `unidadesRegaladas`): la
--    cantidad se divide por el mismo factor que ya divide su costo (#1297). Fuera y
--    dentro de combo también dejan afuera el regalo, así suman "Vendido". La plata no
--    se toca: el ensayo de abajo compara ingresos, costos y márgenes antes y después.
--
-- 2. sustituir_regalo_pedido y dividir_regalo_pedido mueven `pedidos.updated_at`
--    (#1376 punto 1). Sin eso, una edición abierta en otra pestaña guardaba sin rechazo
--    y disolvía el reparto. Devuelven la versión de antes y la nueva: el front adopta la
--    nueva sólo si la edición que corre por debajo tenía la de antes (si no, otro editó
--    en el medio y el rechazo tiene que llegar igual). El replay idempotente no las
--    devuelve: esa llamada no movió nada.
--
-- 3. regalo_mueve_stock_foto(pedido_items) (#1376 punto 2): columna computada de
--    PostgREST con el modo de la foto (`_regalo_modo_del_pedido`), el mismo que usa el
--    server. El front leía `promociones.regalo_mueve_stock` en vivo para la cancelación
--    por falta de stock, el modal de sustitución y la boleta. `pedido_promo_reglas` es
--    sólo de server, así que va SECURITY DEFINER, como deuda_previa_detalle (218): del
--    caller sólo se usa `id`, la línea se relee, y sólo contesta si el que llama puede
--    leer el pedido (`puede_leer_pedido`, que además mira la sucursal activa).
--
-- Revertir: reaplicar los cuerpos de la 434 (reporte_rentabilidad) y de la 431d
-- (sustituir y dividir) y `DROP FUNCTION public.regalo_mueve_stock_foto(public.pedido_items)`.
--
-- Se aplica en LF: las anclas de los parches tienen saltos de línea.

-- REPEATABLE READ, como la 318: la foto de antes y la de después ven el mismo
-- snapshot. En READ COMMITTED una entrega entre las dos movería Rentabilidad y el
-- ensayo abortaría por un falso positivo. La migración no escribe ninguna tabla
-- de negocio, así que no hay conflicto de serialización posible. Con el MCP
-- (execute_sql o apply_migration) queda en REPEATABLE READ (probado en la 318).
BEGIN ISOLATION LEVEL REPEATABLE READ;

-- ---------------------------------------------------------------------------
-- Premisas: nada cambió en prod desde que se leyeron los cuerpos (03/11)
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, md5(p.prosrc) AS md5_vivo
      FROM (VALUES
        ('public.reporte_rentabilidad(date,date,bigint,text)',                     '3e565c06d9e91979e63d410ec28a7ef0'),
        ('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)', '394ac566b572eb2962fd01391dde4798'),
        ('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)',                   '3f6169c57d4fe6ff61548ade30cf45fa'),
        ('public._regalo_modo_del_pedido(bigint,bigint,bigint)',                   'a6b34b20f9cb25e88c1c78746309da41')
      ) AS x(firma, md5)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION 'mig 442 · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;
  IF to_regprocedure('public.regalo_mueve_stock_foto(public.pedido_items)') IS NOT NULL THEN
    RAISE EXCEPTION 'mig 442 · regalo_mueve_stock_foto ya existe';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- Foto de Rentabilidad antes del parche, para comparar la plata
-- ---------------------------------------------------------------------------
-- Como servidor (auth.uid() NULL): la Red son todas las activas.
SELECT set_config('request.jwt.claims', '', true);

CREATE TEMP TABLE _nnn_casos ON COMMIT DROP AS
WITH s AS (SELECT NULL::bigint AS suc UNION ALL SELECT id FROM sucursales WHERE activa),
     c AS (SELECT unnest(ARRAY['incluir', 'excluir', 'solo']) AS combos)
SELECT s.suc, NULL::date AS desde, NULL::date AS hasta, c.combos FROM s, c
UNION ALL
SELECT s.suc, DATE '2026-01-01', public._tablero_hoy(), c.combos FROM s, c
UNION ALL
SELECT s.suc, m::date, (m + interval '1 month - 1 day')::date, 'incluir'
  FROM s, generate_series(DATE '2026-01-01', date_trunc('month', public._tablero_hoy()), interval '1 month') m;

CREATE TEMP TABLE _nnn_antes ON COMMIT DROP AS
SELECT k.*, public.reporte_rentabilidad(k.desde, k.hasta, k.suc, k.combos) AS r FROM _nnn_casos k;

-- ---------------------------------------------------------------------------
-- Parches por ancla
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _nnn_parche (firma text, orden int, ancla text, reemplazo text, veces int DEFAULT 1) ON COMMIT DROP;

INSERT INTO _nnn_parche (firma, orden, ancla, reemplazo) VALUES
-- 1 · reporte_rentabilidad --------------------------------------------------
('public.reporte_rentabilidad(date,date,bigint,text)', 1,
$a$           (pi.combo_id IS NOT NULL) AS en_combo,
           pi.cantidad,
$a$,
$r$           (pi.combo_id IS NOT NULL) AS en_combo,
           COALESCE(pi.es_bonificacion, false) AS es_regalo,
           pi.cantidad,
           -- #1363: el regalo en bloques. Un fraccionado guarda partes de un bloque;
           -- se dividen por el mismo factor que divide su costo (#1297).
           CASE WHEN pi.es_bonificacion
                THEN pi.cantidad::numeric / public.factor_bonificacion(pi.unidades_por_bloque_al_crear,
                       public._regalo_modo_del_pedido(pi.pedido_id, pi.promocion_id, pi.sucursal_id), pr.unidades_por_bloque)
                ELSE 0 END AS bloques_regalo,
$r$),

('public.reporte_rentabilidad(date,date,bigint,text)', 2,
$a$           SUM(it.cantidad)     AS cantidad_vendida,
$a$,
$r$           -- #1363: "Vendido" sin regalos, como `unidades` de reporte_gerencial. El
           -- regalo va aparte, en bloques; su costo sigue en `costos`.
           SUM(it.cantidad)     FILTER (WHERE NOT it.es_regalo) AS cantidad_vendida,
           SUM(it.bloques_regalo) AS bloques_regalo,
$r$),

('public.reporte_rentabilidad(date,date,bigint,text)', 3,
$a$           SUM(it.cantidad)     FILTER (WHERE it.en_combo)     AS cant_combo,
$a$,
$r$           SUM(it.cantidad)     FILTER (WHERE it.en_combo AND NOT it.es_regalo)     AS cant_combo,
$r$),

('public.reporte_rentabilidad(date,date,bigint,text)', 4,
$a$           SUM(it.cantidad)     FILTER (WHERE NOT it.en_combo) AS cant_fuera,
$a$,
$r$           SUM(it.cantidad)     FILTER (WHERE NOT it.en_combo AND NOT it.es_regalo) AS cant_fuera,
$r$),

('public.reporte_rentabilidad(date,date,bigint,text)', 5,
$a$        'cantidadVendida',  pp.cantidad_vendida,
$a$,
$r$        'cantidadVendida',  COALESCE(pp.cantidad_vendida, 0),
        'cantidadRegalada', ROUND(pp.bloques_regalo, 2),
$r$),

('public.reporte_rentabilidad(date,date,bigint,text)', 6,
$a$        'ingresosSinCosto',  COALESCE(ROUND(SUM(ing_sin_costo),2),0)
$a$,
$r$        'ingresosSinCosto',  COALESCE(ROUND(SUM(ing_sin_costo),2),0),
        'unidadesVendidas',  COALESCE(SUM(cantidad_vendida),0),
        'unidadesRegaladas', COALESCE(ROUND(SUM(bloques_regalo),2),0)
$r$),

-- 2 · sustituir_regalo_pedido -----------------------------------------------
('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)', 1,
$a$p.estado AS pedido_estado, pi.regalo_cadena_id
    INTO v_item
$a$,
$r$p.estado AS pedido_estado, pi.regalo_cadena_id,
         p.updated_at AS pedido_updated_at
    INTO v_item
$r$),

('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)', 2,
$a$  RETURN jsonb_build_object('success', true, 'sustitucion_id', v_sust_id,
$a$,
$r$  -- #1376: la sustitución cambia el pedido. Sin mover la versión, una edición
  -- abierta en otra pestaña guardaba sin rechazo y la deshacía. El pedido está
  -- bloqueado desde el principio, así que la de antes es la que leyó el SELECT.
  UPDATE pedidos SET updated_at = now() WHERE id = v_item.pedido_id;
  RETURN jsonb_build_object('success', true, 'sustitucion_id', v_sust_id,
    'updated_at_anterior', v_item.pedido_updated_at, 'updated_at', now(),
$r$),

-- 3 · dividir_regalo_pedido -------------------------------------------------
('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)', 1,
$a$p.estado AS pedido_estado, pi.regalo_cadena_id
    INTO v_item
$a$,
$r$p.estado AS pedido_estado, pi.regalo_cadena_id,
         p.updated_at AS pedido_updated_at
    INTO v_item
$r$),

('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)', 2,
$a$  RETURN jsonb_build_object('success', true,
    'sustitucion_id', v_sust_ids[1],
$a$,
$r$  -- #1376: el reparto cambia el pedido; ver sustituir_regalo_pedido.
  UPDATE pedidos SET updated_at = now() WHERE id = v_item.pedido_id;
  RETURN jsonb_build_object('success', true,
    'updated_at_anterior', v_item.pedido_updated_at, 'updated_at', now(),
    'sustitucion_id', v_sust_ids[1],
$r$);

DO $parches$
DECLARE
  v_f   record;
  v_p   record;
  v_def text;
  v_n   int;
BEGIN
  FOR v_f IN SELECT DISTINCT firma FROM _nnn_parche ORDER BY firma LOOP
    v_def := pg_get_functiondef(v_f.firma::regprocedure);
    FOR v_p IN SELECT * FROM _nnn_parche WHERE firma = v_f.firma ORDER BY orden LOOP
      v_n := (length(v_def) - length(replace(v_def, v_p.ancla, ''))) / length(v_p.ancla);
      IF v_n <> v_p.veces THEN
        RAISE EXCEPTION 'mig 442 · % parche %: el ancla aparece % vez/veces y se esperaba %',
          v_f.firma, v_p.orden, v_n, v_p.veces;
      END IF;
      v_def := replace(v_def, v_p.ancla, v_p.reemplazo);
    END LOOP;
    EXECUTE v_def;
  END LOOP;
END
$parches$;

-- ---------------------------------------------------------------------------
-- 4 · El modo de la foto, para el front
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.regalo_mueve_stock_foto(p public.pedido_items)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  -- Una línea de venta no tiene modo. Del caller sólo se usa `id` (y los dos
  -- campos que deciden si vale la pena mirar): la línea se relee, y contesta sólo
  -- si el que llama puede leer su pedido en la sucursal activa. Una fila
  -- inventada por RPC devuelve NULL.
  SELECT CASE WHEN p.es_bonificacion AND p.promocion_id IS NOT NULL THEN (
    SELECT public._regalo_modo_del_pedido(i.pedido_id, i.promocion_id, i.sucursal_id)
      FROM pedido_items i
     WHERE i.id = p.id
       AND public.puede_leer_pedido(i.pedido_id)
  ) END;
$$;

COMMENT ON FUNCTION public.regalo_mueve_stock_foto(public.pedido_items) IS
  'Columna computada de PostgREST (#1376): si el regalo de esta línea mueve stock, según la foto de la promo del pedido (_regalo_modo_del_pedido), no según la promo de hoy. NULL en una línea de venta, o si el que llama no puede leer el pedido (puede_leer_pedido).';

REVOKE ALL ON FUNCTION public.regalo_mueve_stock_foto(public.pedido_items) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.regalo_mueve_stock_foto(public.pedido_items) TO authenticated;

-- ---------------------------------------------------------------------------
-- Ensayo: la plata no se movió, y "Vendido" cierra contra el gerencial
-- ---------------------------------------------------------------------------
DO $ensayo$
DECLARE
  v_fallas text[] := '{}';
  v_k      record;
  v_g      jsonb;
  v_x      numeric;
BEGIN
  FOR v_k IN
    SELECT a.suc, a.desde, a.hasta, a.combos, a.r AS antes,
           public.reporte_rentabilidad(a.desde, a.hasta, a.suc, a.combos) AS despues
      FROM _nnn_antes a
  LOOP
    -- La plata, producto por producto: todo menos las cantidades.
    IF (SELECT jsonb_agg(e - 'cantidadVendida'
                         || jsonb_build_object('fueraDeCombo', (e->'fueraDeCombo') - 'cantidad',
                                               'dentroDeCombo', (e->'dentroDeCombo') - 'cantidad')
                         ORDER BY e->>'nombre', e->>'id')
          FROM jsonb_array_elements(v_k.antes->'productos') e)
       IS DISTINCT FROM
       (SELECT jsonb_agg(e - 'cantidadVendida' - 'cantidadRegalada'
                         || jsonb_build_object('fueraDeCombo', (e->'fueraDeCombo') - 'cantidad',
                                               'dentroDeCombo', (e->'dentroDeCombo') - 'cantidad')
                         ORDER BY e->>'nombre', e->>'id')
          FROM jsonb_array_elements(v_k.despues->'productos') e) THEN
      v_fallas := v_fallas || format('%s %s..%s %s · cambió la plata de algún producto',
        COALESCE('suc ' || v_k.suc, 'Red'), v_k.desde, v_k.hasta, v_k.combos);
    END IF;
    IF v_k.antes->'totales' IS DISTINCT FROM
       (v_k.despues->'totales') - 'unidadesVendidas' - 'unidadesRegaladas' THEN
      v_fallas := v_fallas || format('%s %s..%s %s · cambiaron los totales: %s -> %s',
        COALESCE('suc ' || v_k.suc, 'Red'), v_k.desde, v_k.hasta, v_k.combos,
        v_k.antes->'totales', v_k.despues->'totales');
    END IF;

    -- "Vendido" = `unidades` del gerencial, con fecha (el gerencial no va sin rango).
    IF v_k.combos = 'incluir' AND v_k.desde IS NOT NULL THEN
      v_g := public.reporte_gerencial(v_k.suc, v_k.desde, v_k.hasta, false, false);
      v_x := (SELECT COALESCE(sum((e->>'cantidadVendida')::numeric), 0)
                FROM jsonb_array_elements(v_k.despues->'productos') e);
      IF v_x <> (v_g->'kpis'->>'unidades')::numeric
         OR (v_k.despues->'totales'->>'unidadesVendidas')::numeric <> (v_g->'kpis'->>'unidades')::numeric THEN
        v_fallas := v_fallas || format('%s %s..%s · Vendido %s / %s <> unidades %s',
          COALESCE('suc ' || v_k.suc, 'Red'), v_k.desde, v_k.hasta, v_x,
          v_k.despues->'totales'->>'unidadesVendidas', v_g->'kpis'->>'unidades');
      END IF;
    END IF;
  END LOOP;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'mig 442 · el parche movió números (% fallas):\n- %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
END
$ensayo$;

NOTIFY pgrst, 'reload schema';

COMMIT;
