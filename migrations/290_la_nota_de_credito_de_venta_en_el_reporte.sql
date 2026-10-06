-- =========================================================================
-- mig 290 · LA NOTA DE CREDITO DE VENTA EN EL REPORTE (#845)
--
-- Desde la nota de credito de venta (#833, migs 276/283) el credito que se le
-- reconoce al cliente se registra como un pago con forma `nota_credito` y se
-- imputa a pedidos. En `reporte_gerencial` eso tenia dos efectos:
--   * ningun KPI descontaba la NC: la contribucion quedaba sobreestimada por
--     el monto de las notas;
--   * `cobranza.cobrado` sumaba `monto_pagado`, asi que el credito aplicado
--     (y el adelanto de sueldo, #832) contaba como plata cobrada.
--
-- Decisiones del dueño:
--   1. KPI propio: `kpis.notas_credito_venta` (monto) y
--      `kpis.notas_credito_venta_n` (cantidad), NO anuladas, por
--      `notas_credito_venta.fecha` en el rango y en las sucursales del reporte;
--      en `mensual[]`, `notas_credito_venta` por mes (mismo criterio que
--      mermas y descuentos de proveedores: solo los meses con venta tienen
--      fila). Los margenes (comercial / neto / real / real_neto) NO cambian:
--      la NC no se resta aca. La que la resta es la CONTRIBUCION, que se
--      calcula en el front (src/utils/contribucionGerencial.ts):
--        contribucion = margen_neto − mermas − comision − notas_credito_venta
--      El comparativo hereda las claves nuevas (v_prev->'kpis').
--   2. Cobranza: `cobrado` es SOLO plata. Clave nueva `credito_aplicado` (NC y
--      adelantos de sueldo imputados a pedidos del universo) y cada fila de
--      `formas` lleva `no_dineraria` true/false.
--   3. La lista de formas no dinerarias se escribe UNA vez dentro de la
--      funcion (v_formas_no_din). Es espejo de FORMAS_PAGO_NO_DINERARIAS
--      (src/constants/formasPago.ts) y de la que excluyen las rendiciones
--      (273/276).
--
-- REPARTO DENTRO DEL LEAST(monto_pagado, total)
-- --------------------------------------------
-- Por pedido, lo cubierto sigue siendo LEAST(monto_pagado, total) y lo
-- pendiente GREATEST(total − monto_pagado, 0), como antes. Lo cubierto se
-- parte asi:
--     credito_aplicado = LEAST(no_dinerario_imputado, cubierto)
--     cobrado          = cubierto − credito_aplicado
-- Es decir, LO NO DINERARIO CUENTA PRIMERO hasta el total. En un pedido
-- sobrepagado con mezcla (total 500, efectivo 400 + NC 300) el excedente se
-- le atribuye a la plata: cobrado 200, credito 300, pendiente 0. Es la lectura
-- conservadora: `cobrado` nunca se infla con plata que en realidad quedo como
-- saldo a favor del cliente mientras el credito si cancelo deuda. Y cierra por
-- construccion, pedido por pedido:
--     cobrado + credito_aplicado + pendiente = Σ total = venta del universo.
-- La fila "(sin registro de pago)" (monto_pagado sin filas en `pagos`, legado)
-- se sigue calculando contra lo cubierto y se trata como plata.
--
-- Cirugia por anclas sobre el cuerpo VIVO (patron 278/280/287): cada ancla
-- tiene que aparecer exactamente una vez o la migracion falla. No cambia
-- firma, SECURITY, search_path ni ACL.
--
-- Numero PROVISORIO: se reserva al aplicar (ver MANIFEST).
-- =========================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._mig845_ancla(p_ancla text, p_nuevo text)
RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text := pg_get_functiondef('public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure);
  v_veces int;
BEGIN
  v_veces := (length(v_def) - length(replace(v_def, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El ancla aparece % veces (se esperaba exactamente 1). El cuerpo vivo cambio: revisar a mano. Ancla: %',
      v_veces, left(p_ancla, 120);
  END IF;
  EXECUTE replace(v_def, p_ancla, p_nuevo);
END;
$fn$;

-- 1 · la lista de formas no dinerarias, una sola vez
SELECT public._mig845_ancla(
  E'  v_prev_mermas numeric;\nBEGIN\n',
  E'  v_prev_mermas numeric;\n'
  || E'  -- mig 290 (#845): formas que cancelan deuda pero no son plata. Espejo de\n'
  || E'  -- FORMAS_PAGO_NO_DINERARIAS (src/constants/formasPago.ts) y de rendiciones (273/276).\n'
  || E'  v_formas_no_din text[] := ARRAY[''nota_credito'', ''adelanto_sueldo''];\n'
  || E'BEGIN\n');

-- 2 · CTEs de notas de credito de venta (por fecha de la NC, no anuladas)
SELECT public._mig845_ancla(
  E'  m_desc AS (SELECT to_char(fecha, ''YYYY-MM'') AS mes, SUM(monto) AS descuentos FROM desc_nc GROUP BY 1),\n',
  E'  m_desc AS (SELECT to_char(fecha, ''YYYY-MM'') AS mes, SUM(monto) AS descuentos FROM desc_nc GROUP BY 1),\n'
  || E'  -- mig 290 (#845): notas de credito de VENTA vigentes, por la fecha de la nota.\n'
  || E'  -- No tocan los margenes: la contribucion (front) las resta. (`nc` mas arriba\n'
  || E'  -- es la base de comision, no esto.)\n'
  || E'  ncv AS (SELECT fecha, total FROM notas_credito_venta\n'
  || E'    WHERE NOT anulada AND sucursal_id = ANY(v_sucursales) AND fecha BETWEEN p_desde AND p_hasta),\n'
  || E'  k_ncv AS (SELECT COALESCE(SUM(total), 0) AS monto, COUNT(*) AS n FROM ncv),\n'
  || E'  m_ncv AS (SELECT to_char(fecha, ''YYYY-MM'') AS mes, SUM(total) AS monto FROM ncv GROUP BY 1),\n');

-- 3 · mensual
SELECT public._mig845_ancla(
  E'      COALESCE(mc.compras_transferencias,0) AS compras_transferencias\n    FROM m_ped mp',
  E'      COALESCE(mc.compras_transferencias,0) AS compras_transferencias,\n'
  || E'      COALESCE(mnv.monto,0) AS notas_credito_venta\n    FROM m_ped mp');

SELECT public._mig845_ancla(
  ' LEFT JOIN m_desc md ON md.mes=mp.mes),',
  ' LEFT JOIN m_desc md ON md.mes=mp.mes LEFT JOIN m_ncv mnv ON mnv.mes=mp.mes),');

-- 4 · cobranza: lo cubierto se parte en plata y credito (no dinerario primero)
SELECT public._mig845_ancla(
  E'  cobr AS (SELECT COALESCE(SUM(LEAST(COALESCE(monto_pagado,0), total)),0) AS cobrado,\n'
  || E'      COALESCE(SUM(GREATEST(total - COALESCE(monto_pagado,0), 0)),0) AS pendiente FROM ped),\n',
  E'  -- mig 290 (#845): `cobrado` es solo plata. Por pedido, lo cubierto\n'
  || E'  -- (LEAST(monto_pagado, total)) se parte: lo no dinerario cuenta PRIMERO hasta\n'
  || E'  -- lo cubierto y el resto es plata. Un sobrepago con mezcla no infla `cobrado`.\n'
  || E'  -- cobrado + credito_aplicado + pendiente = Σ total, pedido por pedido.\n'
  || E'  cobr_ped AS (\n'
  || E'    SELECT LEAST(COALESCE(p.monto_pagado,0), p.total) AS cubierto,\n'
  || E'           GREATEST(p.total - COALESCE(p.monto_pagado,0), 0) AS pendiente,\n'
  || E'           COALESCE((SELECT SUM(pg.monto) FROM pagos pg\n'
  || E'                      WHERE pg.pedido_id = p.id AND pg.forma_pago = ANY(v_formas_no_din)), 0) AS no_din\n'
  || E'    FROM ped p),\n'
  || E'  cobr AS (SELECT COALESCE(SUM(cubierto),0) AS cubierto,\n'
  || E'      COALESCE(SUM(GREATEST(LEAST(no_din, cubierto), 0)),0) AS credito_aplicado,\n'
  || E'      COALESCE(SUM(cubierto - GREATEST(LEAST(no_din, cubierto), 0)),0) AS cobrado,\n'
  || E'      COALESCE(SUM(pendiente),0) AS pendiente FROM cobr_ped),\n');

SELECT public._mig845_ancla(
  E'  formas AS (SELECT forma_pago, monto FROM pagos_ped\n'
  || E'    UNION ALL\n'
  || E'    SELECT ''(sin registro de pago)'', c.cobrado - COALESCE((SELECT SUM(monto) FROM pagos_ped),0)\n'
  || E'    FROM cobr c\n'
  || E'    WHERE c.cobrado - COALESCE((SELECT SUM(monto) FROM pagos_ped),0) > 0.01),\n',
  E'  formas AS (SELECT forma_pago, monto, (forma_pago = ANY(v_formas_no_din)) AS no_dineraria FROM pagos_ped\n'
  || E'    UNION ALL\n'
  || E'    SELECT ''(sin registro de pago)'', c.cubierto - COALESCE((SELECT SUM(monto) FROM pagos_ped),0), false\n'
  || E'    FROM cobr c\n'
  || E'    WHERE c.cubierto - COALESCE((SELECT SUM(monto) FROM pagos_ped),0) > 0.01),\n');

SELECT public._mig845_ancla(
  '''cobrado'', (SELECT cobrado FROM cobr), ''pendiente'', (SELECT pendiente FROM cobr)),',
  '''cobrado'', (SELECT cobrado FROM cobr), ''credito_aplicado'', (SELECT credito_aplicado FROM cobr),'
  || E'\n      ''pendiente'', (SELECT pendiente FROM cobr)),');

-- 5 · kpis
SELECT public._mig845_ancla(
  '''descuentos_proveedores'', kd.descuentos,',
  '''descuentos_proveedores'', kd.descuentos,'
  || E'\n        ''notas_credito_venta'', kncv.monto, ''notas_credito_venta_n'', kncv.n,');

SELECT public._mig845_ancla(
  'k_nuevos kn, k_desc kd),',
  'k_nuevos kn, k_desc kd, k_ncv kncv),');

DROP FUNCTION public._mig845_ancla(text, text);

-- -------------------------------------------------------------------------
-- Verificacion estatica
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  v_def text := pg_get_functiondef('public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure);
  v_n   integer;
BEGIN
  -- El literal de la lista aparece una sola vez.
  SELECT count(*) INTO v_n FROM regexp_matches(v_def, '''adelanto_sueldo''', 'g');
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'reporte_gerencial: la lista no dineraria aparece % veces (se esperaba 1)', v_n;
  END IF;
  IF v_def NOT LIKE '%''notas_credito_venta'', kncv.monto%'
     OR v_def NOT LIKE '%''credito_aplicado'', (SELECT credito_aplicado FROM cobr)%'
     OR v_def NOT LIKE '%COALESCE(mnv.monto,0) AS notas_credito_venta%' THEN
    RAISE EXCEPTION 'reporte_gerencial no quedo con las notas de credito de venta';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = 'public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure AND prosecdef)
     OR has_function_privilege('anon', 'public.reporte_gerencial(bigint,date,date,boolean,boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'reporte_gerencial perdio SECURITY DEFINER o quedo alcanzable por anon';
  END IF;
END
$verif$;

-- -------------------------------------------------------------------------
-- Ensayo funcional (subtransaccion que se revierte; molde 283)
-- -------------------------------------------------------------------------
-- Admin con sucursal por defecto. Se mide reporte_gerencial de esa sucursal
-- para HOY, antes y despues de insertar:
--   * P1 total 1000: efectivo 700 + credito de NC1 (250) imputado
--       → cubierto 950: cobrado 700, credito 250, pendiente 50
--   * P2 total 500, SOBREPAGADO con mezcla: efectivo 400 + credito de NC2 (300)
--       → cubierto 500: credito 300 (primero), cobrado 200, pendiente 0
--   * NC3 ANULADA de 999 con fecha de hoy (no cuenta)
-- Esperado (deltas): venta +1500, notas_credito_venta +550, _n +2,
-- cobrado +900, credito_aplicado +550, pendiente +50; los margenes se mueven
-- exactamente lo que la venta (P1/P2 no tienen items: cmv 0) — la NC no los
-- toca; y en el reporte de despues cobrado + credito + pendiente = venta.
DO $ensayo$
DECLARE
  v_uid    uuid;
  v_suc    bigint;
  v_obs    jsonb := '{}'::jsonb;
  v_esp    jsonb;
  v_fallas text := '';
  k        text;
BEGIN
  SELECT p.id, us.sucursal_id INTO v_uid, v_suc
    FROM perfiles p
    JOIN usuario_sucursales us ON us.usuario_id = p.id AND us.es_default
   WHERE p.rol = 'admin'
   ORDER BY p.id
   LIMIT 1;

  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'mig290: no hay ningun admin con sucursal por defecto; el ensayo no puede correr.';
  END IF;

  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);

    DECLARE
      v_hoy date := current_date;
      v_cli bigint; v_p1 bigint; v_p2 bigint; v_nc1 bigint; v_nc2 bigint;
      a jsonb; d jsonb; ak jsonb; dk jsonb; ac jsonb; dc jsonb;
    BEGIN
      a  := public.reporte_gerencial(v_suc, v_hoy, v_hoy, false, false);
      ak := a->'kpis'; ac := a->'cobranza';

      INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
        VALUES ('ZZZ mig290', 'ZZZ mig290', 'ZZZ', v_suc) RETURNING id INTO v_cli;
      INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha)
        VALUES (v_cli, v_suc, v_uid, 1000, 'entregado', v_hoy) RETURNING id INTO v_p1;
      INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha)
        VALUES (v_cli, v_suc, v_uid, 500, 'entregado', v_hoy) RETURNING id INTO v_p2;

      INSERT INTO notas_credito_venta (sucursal_id, cliente_id, pedido_id, motivo, total, usuario_id, fecha)
        VALUES (v_suc, v_cli, v_p1, 'producto_vencido', 250, v_uid, v_hoy) RETURNING id INTO v_nc1;
      INSERT INTO notas_credito_venta (sucursal_id, cliente_id, pedido_id, motivo, total, usuario_id, fecha)
        VALUES (v_suc, v_cli, v_p2, 'producto_danado', 300, v_uid, v_hoy) RETURNING id INTO v_nc2;
      INSERT INTO notas_credito_venta (sucursal_id, cliente_id, pedido_id, motivo, total, usuario_id, fecha,
                                       anulada, anulada_at, anulada_por, motivo_anulacion)
        VALUES (v_suc, v_cli, v_p1, 'otro', 999, v_uid, v_hoy, true, now(), v_uid, 'ZZZ mig290');

      INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, notas, usuario_id, sucursal_id)
        VALUES (v_cli, v_p1, 700, 'efectivo', v_hoy, 'ZZZ mig290', v_uid, v_suc);
      INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, referencia, notas,
                         usuario_id, sucursal_id, nota_credito_id)
        VALUES (v_cli, v_p1, 250, 'nota_credito', v_hoy, 'NC-' || v_nc1, 'ZZZ mig290', v_uid, v_suc, v_nc1);
      INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, notas, usuario_id, sucursal_id)
        VALUES (v_cli, v_p2, 400, 'efectivo', v_hoy, 'ZZZ mig290', v_uid, v_suc);
      INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, referencia, notas,
                         usuario_id, sucursal_id, nota_credito_id)
        VALUES (v_cli, v_p2, 300, 'nota_credito', v_hoy, 'NC-' || v_nc2, 'ZZZ mig290', v_uid, v_suc, v_nc2);

      d  := public.reporte_gerencial(v_suc, v_hoy, v_hoy, false, false);
      dk := d->'kpis'; dc := d->'cobranza';

      v_obs := jsonb_build_object(
        'venta',            (dk->>'venta')::numeric - (ak->>'venta')::numeric,
        'ncv',              (dk->>'notas_credito_venta')::numeric - (ak->>'notas_credito_venta')::numeric,
        'ncv_n',            (dk->>'notas_credito_venta_n')::numeric - (ak->>'notas_credito_venta_n')::numeric,
        'ncv_mes',          (SELECT (m->>'notas_credito_venta')::numeric FROM jsonb_array_elements(d->'mensual') m)
                          - COALESCE((SELECT (m->>'notas_credito_venta')::numeric FROM jsonb_array_elements(a->'mensual') m), 0),
        'cobrado',          (dc->>'cobrado')::numeric - (ac->>'cobrado')::numeric,
        'credito_aplicado', (dc->>'credito_aplicado')::numeric - (ac->>'credito_aplicado')::numeric,
        'pendiente',        (dc->>'pendiente')::numeric - (ac->>'pendiente')::numeric,
        'cierra',           (dc->>'cobrado')::numeric + (dc->>'credito_aplicado')::numeric + (dc->>'pendiente')::numeric
                            = (dk->>'venta')::numeric,
        'mg_comercial',     (dk->>'margen_comercial')::numeric - (ak->>'margen_comercial')::numeric,
        'mg_neto',          (dk->>'margen_neto')::numeric - (ak->>'margen_neto')::numeric,
        'mg_real',          (dk->>'margen_real')::numeric - (ak->>'margen_real')::numeric,
        'mg_real_neto',     (dk->>'margen_real_neto')::numeric - (ak->>'margen_real_neto')::numeric,
        'forma_nc',         (SELECT jsonb_build_object('monto', (f->>'monto')::numeric, 'no_din', f->'no_dineraria')
                               FROM jsonb_array_elements(dc->'formas') f WHERE f->>'forma_pago' = 'nota_credito'),
        'forma_ef_no_din',  (SELECT f->'no_dineraria' FROM jsonb_array_elements(dc->'formas') f
                              WHERE f->>'forma_pago' = 'efectivo'));
    END;

    RAISE EXCEPTION 'mig290_rollback_del_ensayo';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'mig290_rollback_del_ensayo' THEN
      RAISE EXCEPTION 'mig290 · el ensayo funcional exploto: %', SQLERRM;
    END IF;
  END;

  v_esp := jsonb_build_object(
    'venta', 1500, 'ncv', 550, 'ncv_n', 2, 'ncv_mes', 550,
    'cobrado', 900, 'credito_aplicado', 550, 'pendiente', 50, 'cierra', true,
    'mg_comercial', 1500, 'mg_neto', 1500, 'mg_real', 1500, 'mg_real_neto', 1500,
    -- forma_nc: el monto puede incluir otros creditos de NC de hoy; solo se
    -- compara el flag (abajo se chequea que el monto haya subido 550).
    'forma_ef_no_din', false);

  FOR k IN SELECT jsonb_object_keys(v_esp) LOOP
    IF (v_obs->k) IS DISTINCT FROM (v_esp->k) THEN
      v_fallas := v_fallas || format(' [%s: esperado %s, obtenido %s]', k, v_esp->k, COALESCE(v_obs->k, 'null'::jsonb));
    END IF;
  END LOOP;
  IF (v_obs->'forma_nc'->'no_din') IS DISTINCT FROM 'true'::jsonb
     OR (v_obs->'forma_nc'->>'monto')::numeric < 550 THEN
    v_fallas := v_fallas || format(' [forma_nc: esperado no_din=true y monto>=550, obtenido %s]', v_obs->'forma_nc');
  END IF;

  IF v_fallas <> '' THEN
    RAISE EXCEPTION 'mig290 · el ensayo funcional encontro:% · observado=%', v_fallas, v_obs;
  END IF;

  PERFORM set_config('mig290.ensayo', v_obs::text, true);
  RAISE NOTICE 'mig290 · ensayo funcional OK: %', v_obs;
END
$ensayo$;

COMMIT;
