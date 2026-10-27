-- Ensayo de la migracion cargo_5_gerencial (metricas de envio en el reporte
-- gerencial; lo que falta de #1220, spec §2).
--
-- Corre contra prod SIN dejar rastro: todo va dentro de una transaccion que
-- termina en ROLLBACK, y el DO final termina SIEMPRE en RAISE EXCEPTION.
--
--   'ENSAYO OK …'    -> todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' -> lista de lo que no se cumplio.
--
-- Tiene DOS PARTES, separadas por la linea que EMPIEZA con la marca: la parte 1
-- va ANTES de la migracion (foto de critical_high) y la parte 2 DESPUES.
-- Ensayo acumulado, en seco:
--
--   BEGIN;
--   SET LOCAL lock_timeout = '5s';
--   <migrations/NNN_cargo_1_base.sql>
--   <migrations/NNN_cargo_2_edicion.sql>
--   <migrations/NNN_cargo_3_bot.sql>
--   <migrations/NNN_cargo_4_reportes.sql>
--   <este archivo hasta la marca>        (sed -n '1,/^-- @@ MIGRACION/p')
--   <migrations/NNN_cargo_5_gerencial.sql>
--   <este archivo desde la marca>        (sed -n '/^-- @@ MIGRACION/,$p')
--   ROLLBACK;
--
-- Ensayo solo (sin la migracion): las dos partes seguidas. Tiene que FALLAR:
-- el gerencial de hoy no tiene la clave envios.
--
-- No depende de los pedidos con cargo que ya haya en prod (la sucursal 1
-- cobra desde el 2026-10-27): arma sus fixtures sobre un dia y una sucursal
-- con al menos 5 pedidos entregados de venta, adentro de un subbloque que se
-- deshace solo.
--   1. NEUTRALIZA ese dia: todo pedido con cargo o con estado distinto de
--      no_aplica queda sin cargo y no_aplica  -> envios = null.
--   2. A un pedido le hace un rechazo total con cargo cobrado (total 0, cargo
--      500, estado cobrado)                  -> envios sigue null (sin productos
--      no hay venta ni envio cobrado).
--   3. Dos pedidos cobrado de 500 (total += 500 y el desglose fiscal como el
--      alta), uno gratis y uno bonificado    -> recaudado 1000, cobrados 2,
--      gratis 1, bonificados 1, pct_cobrado 0.5, venta_productos = kpis.venta,
--      venta_total = kpis.venta + 1000, y kpis.venta igual que antes del paso 3.
-- Despues (fixtures deshechos): la invariante de mermas
-- reporte_mermas.totales.costo == reporte_gerencial.kpis.mermas (Red y cada
-- sucursal, 90 dias) y auditoria_integridad().critical_high_en_rojo igual que
-- en la parte 1.
--
--   psql "$DATABASE_URL" -f scripts/test-cargo-5.sql   (ensayo solo)

-- ============================================================ PARTE 1 =====
DROP TABLE IF EXISTS pg_temp._cargo5_ctx;
CREATE TEMP TABLE _cargo5_ctx (k text PRIMARY KEY, v text);

DO $antes$
BEGIN
  INSERT INTO _cargo5_ctx VALUES
    ('critical_high_antes', (public.auditoria_integridad() ->> 'critical_high_en_rojo'));
END
$antes$;

-- @@ MIGRACION @@ ============================================ PARTE 2 =====

DO $ensayo$
DECLARE
  v_fallas  text[] := '{}';
  d         date := CURRENT_DATE - 89;
  h         date := CURRENT_DATE;
  v_hay_est boolean := EXISTS (SELECT 1 FROM information_schema.columns
                                WHERE table_schema = 'public' AND table_name = 'pedidos'
                                  AND column_name = 'cargo_envio_estado');
  v_dia     record;
  v_ids     bigint[];
  v_tf      text;
  v_neto    numeric;
  v_iva     numeric;
  v_neutr   int;
  g         jsonb;
  e         jsonb;
  v_venta0  numeric;
  v_venta1  numeric;
  v_fix     text := 'fixtures no corridos';
  v_suc     bigint;
  v_ger     jsonb;
  v_mer     jsonb;
  v_ch      text;
BEGIN
  -- El dia mas reciente de los ultimos 90 con al menos 5 pedidos entregados de
  -- venta (no VB, no canje, con total) en una misma sucursal.
  SELECT sucursal_id, fecha INTO v_dia
    FROM pedidos
   WHERE estado = 'entregado' AND canal <> 'cambio' AND tipo_factura IS DISTINCT FROM 'VB'
     AND total > 0 AND fecha BETWEEN d AND h
   GROUP BY sucursal_id, fecha
  HAVING count(*) >= 5
   ORDER BY fecha DESC, sucursal_id
   LIMIT 1;
  IF v_dia IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin un dia con 5 pedidos entregados en 90 dias';
  END IF;

  SELECT array_agg(id ORDER BY id) INTO v_ids FROM (
    SELECT id FROM pedidos
     WHERE sucursal_id = v_dia.sucursal_id AND fecha = v_dia.fecha
       AND estado = 'entregado' AND canal <> 'cambio' AND tipo_factura IS DISTINCT FROM 'VB'
       AND total > 0
     ORDER BY id LIMIT 5) t;

  BEGIN
    IF NOT v_hay_est THEN
      v_fallas := v_fallas || 'no existe pedidos.cargo_envio_estado (falta cargo_1_base): no se pueden armar los fixtures'::text;
      -- Sin la columna igual se mira la respuesta: tiene que tener envios = null.
      g := public.reporte_gerencial(v_dia.sucursal_id, v_dia.fecha, v_dia.fecha, false, false);
      IF NOT (g ? 'envios') THEN
        v_fallas := v_fallas || 'reporte_gerencial no tiene la clave envios'::text;
      END IF;
      RAISE EXCEPTION USING ERRCODE = 'P0099';
    END IF;

    -- 1 · Neutralizar el dia (trampa 6: total y monto_pagado en el SET; el
    -- estado en el mismo UPDATE por el CHECK cobrado <=> cargo > 0).
    EXECUTE 'UPDATE pedidos SET total = GREATEST(total - cargo_envio, 0), cargo_envio = 0,
                                monto_pagado = monto_pagado, cargo_envio_estado = ''no_aplica''
              WHERE sucursal_id = $1 AND fecha = $2
                AND (cargo_envio > 0 OR cargo_envio_estado <> ''no_aplica'')'
      USING v_dia.sucursal_id, v_dia.fecha;
    GET DIAGNOSTICS v_neutr = ROW_COUNT;

    g := public.reporte_gerencial(v_dia.sucursal_id, v_dia.fecha, v_dia.fecha, false, false);
    IF NOT (g ? 'envios') THEN
      v_fallas := v_fallas || '(1) reporte_gerencial no tiene la clave envios'::text;
    ELSIF g->'envios' <> 'null'::jsonb THEN
      v_fallas := v_fallas || format('(1) sin pedidos con cargo, envios = %s; esperado null', g->'envios');
    END IF;

    -- 2 · Rechazo total con el cargo cobrado: sin productos no cuenta.
    EXECUTE 'UPDATE pedidos SET total = 0, cargo_envio = 500, monto_pagado = monto_pagado,
                                cargo_envio_estado = ''cobrado'' WHERE id = $1'
      USING v_ids[5];
    g := public.reporte_gerencial(v_dia.sucursal_id, v_dia.fecha, v_dia.fecha, false, false);
    IF (g ? 'envios') AND g->'envios' <> 'null'::jsonb THEN
      v_fallas := v_fallas || format('(2) solo un rechazo total con cargo: envios = %s; esperado null', g->'envios');
    END IF;
    v_venta0 := (g->'kpis'->>'venta')::numeric;

    -- 3 · Dos cobrado de 500 (como el alta: total += 500 y el desglose fiscal),
    -- un gratis y un bonificado.
    FOR i IN 1..2 LOOP
      SELECT COALESCE(tipo_factura, 'ZZ') INTO v_tf FROM pedidos WHERE id = v_ids[i];
      IF v_tf = 'FC' THEN
        v_neto := round(500 / 1.21, 2); v_iva := 500 - v_neto;
      ELSE
        v_neto := 500; v_iva := 0;
      END IF;
      EXECUTE 'UPDATE pedidos SET cargo_envio = 500, total = total + 500, monto_pagado = monto_pagado,
                                  total_neto = total_neto + $2, total_iva = COALESCE(total_iva, 0) + $3,
                                  cargo_envio_estado = ''cobrado'' WHERE id = $1'
        USING v_ids[i], v_neto, v_iva;
    END LOOP;
    EXECUTE 'UPDATE pedidos SET cargo_envio_estado = ''gratis'' WHERE id = $1' USING v_ids[3];
    EXECUTE 'UPDATE pedidos SET cargo_envio_estado = ''bonificado'' WHERE id = $1' USING v_ids[4];

    g := public.reporte_gerencial(v_dia.sucursal_id, v_dia.fecha, v_dia.fecha, false, false);
    e := g->'envios';
    v_venta1 := (g->'kpis'->>'venta')::numeric;
    IF v_venta1 IS DISTINCT FROM v_venta0 THEN
      v_fallas := v_fallas || format('(3) kpis.venta cambio con el envio: %s -> %s', v_venta0, v_venta1);
    END IF;
    IF e IS NULL OR e = 'null'::jsonb THEN
      v_fallas := v_fallas || format('(3) envios = %s; esperado el bloque', COALESCE(e::text, 'sin clave'));
    ELSE
      IF (e->>'recaudado')::numeric IS DISTINCT FROM 1000 THEN
        v_fallas := v_fallas || format('(3) recaudado %s; esperado 1000', e->>'recaudado');
      END IF;
      IF (e->>'cobrados')::int IS DISTINCT FROM 2 THEN
        v_fallas := v_fallas || format('(3) cobrados %s; esperado 2', e->>'cobrados');
      END IF;
      IF (e->>'gratis')::int IS DISTINCT FROM 1 THEN
        v_fallas := v_fallas || format('(3) gratis %s; esperado 1', e->>'gratis');
      END IF;
      IF (e->>'bonificados')::int IS DISTINCT FROM 1 THEN
        v_fallas := v_fallas || format('(3) bonificados %s; esperado 1', e->>'bonificados');
      END IF;
      IF (e->>'pct_cobrado')::numeric IS DISTINCT FROM 0.5 THEN
        v_fallas := v_fallas || format('(3) pct_cobrado %s; esperado 0.5', e->>'pct_cobrado');
      END IF;
      IF (e->>'venta_productos')::numeric IS DISTINCT FROM v_venta1 THEN
        v_fallas := v_fallas || format('(3) venta_productos %s; esperado kpis.venta %s', e->>'venta_productos', v_venta1);
      END IF;
      IF (e->>'venta_total')::numeric IS DISTINCT FROM v_venta1 + 1000 THEN
        v_fallas := v_fallas || format('(3) venta_total %s; esperado %s', e->>'venta_total', v_venta1 + 1000);
      END IF;
    END IF;
    v_fix := format('suc %s, %s, pedidos %s (%s neutralizados), venta %s, envios %s',
                    v_dia.sucursal_id, v_dia.fecha, array_to_string(v_ids, ','), v_neutr, v_venta1, e);
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('fixtures: %s', SQLERRM);
  END;

  -- ------------------------------------- mermas e integridad (sin fixtures) --
  FOR v_suc IN SELECT NULL::bigint UNION ALL (SELECT id FROM sucursales WHERE activa ORDER BY id) LOOP
    v_ger := public.reporte_gerencial(v_suc, d, h, false, false);
    v_mer := public.reporte_mermas(p_desde => d, p_hasta => h, p_sucursal_id => v_suc);
    IF (v_ger->'kpis'->>'mermas')::numeric IS DISTINCT FROM (v_mer->'totales'->>'costo')::numeric THEN
      v_fallas := v_fallas || format('mermas %s: gerencial %s, reporte_mermas %s',
        COALESCE(v_suc::text, 'red'), v_ger->'kpis'->>'mermas', v_mer->'totales'->>'costo');
    END IF;
  END LOOP;
  v_ch := public.auditoria_integridad() ->> 'critical_high_en_rojo';
  IF v_ch IS DISTINCT FROM (SELECT v FROM _cargo5_ctx WHERE k = 'critical_high_antes') THEN
    v_fallas := v_fallas || format('critical_high_en_rojo %s -> %s',
                                   (SELECT v FROM _cargo5_ctx WHERE k = 'critical_high_antes'), v_ch);
  END IF;

  -- ------------------------------------------------------------ veredicto --
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · (1) null sin cargo · (2) null con solo un rechazo total · (3) % · mermas = gerencial, critical_high % -> %',
    v_fix, (SELECT v FROM _cargo5_ctx WHERE k = 'critical_high_antes'), v_ch;
END
$ensayo$;
