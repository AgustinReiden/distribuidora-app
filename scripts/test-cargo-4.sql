-- Ensayo de la migracion cargo_4_reportes (la venta de los reportes es de
-- productos: GREATEST(total - cargo_envio, 0); lo que falta de #1220, spec §2).
--
-- Corre contra prod SIN dejar rastro: todo va dentro de una transaccion que
-- termina en ROLLBACK, y el DO final termina SIEMPRE en RAISE EXCEPTION.
--
--   'ENSAYO OK …'    -> todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' -> lista de lo que no se cumplio.
--
-- Tiene DOS PARTES, separadas por la linea que EMPIEZA con la marca: la parte 1 va
-- ANTES de la migracion y la parte 2 DESPUES (la foto de antes/despues del
-- molde de la 241/318, que necesita las dos definiciones en la misma
-- transaccion). Ensayo acumulado, en seco:
--
--   BEGIN ISOLATION LEVEL REPEATABLE READ;
--   SET LOCAL lock_timeout = '5s';
--   <migrations/394_cargo_1_base.sql>
--   <migrations/395_cargo_2_edicion.sql>
--   <migrations/396_cargo_3_bot.sql>
--   <este archivo hasta la marca>        (sed -n '1,/^-- @@ MIGRACION/p')
--   <migrations/397_cargo_4_reportes.sql>
--   <este archivo desde la marca>        (sed -n '/^-- @@ MIGRACION/,$p')
--   ROLLBACK;
--
-- Ensayo solo (sin la migracion): las dos partes seguidas. La parte (a) da
-- igual trivialmente y la (b) tiene que FALLAR: los reportes de hoy suman el
-- envio como venta.
--
-- REPEATABLE READ: las fotos de antes y despues ven el mismo snapshot; un
-- pedido que la app crea o entrega entre las dos moveria un reporte.
--
-- (a) Antes / despues. Los pedidos que ya tienen cargo (sucursal 1 cobra desde
--     el 2026-10-27) se NEUTRALIZAN primero (total -= cargo efectivo, cargo 0,
--     estado 'no_aplica'; se deshace con el ROLLBACK): con cargo 0 la
--     migracion no puede mover ningun numero. Se fotografia cada funcion
--     migrada, 90 dias, Red y cada sucursal (y cada preventista con ventas),
--     y la foto de despues tiene que dar la de antes.
-- (b) A un pedido entregado real (FC si hay, de un preventista activo) se le
--     fuerza un envio de $500 como lo cobraria el alta: cargo_envio 500,
--     total += 500 y el desglose fiscal en total_neto/total_iva (FC 413,22 +
--     86,78; ZZ 500 + 0). La venta de cada funcion migrada NO cambia
--     (gerencial: kpis, mensual, vendedores, serie, top; ventas por cliente,
--     por preventista, bot, jornadas, ritmo) y la plata a cobrar SI sube $500
--     (saldo del cliente, cobranza.pendiente del gerencial, totalPendiente del
--     preventista). (b2) idem sobre el ultimo pedido de un cliente que dejo de
--     comprar: la alerta de inactivos no cambia (si no hay ninguno, se avisa).
--     (b3) idem sobre un pedido FC de la ventana (de cualquier vendedor): los
--     kpis del gerencial (venta_neta, iva_debito, fc_venta) no cambian con el
--     desglose 413,22 + 86,78 y la cobranza pendiente sube 500.
--     (b4) un pedido PENDIENTE de un preventista: en_curso de bot_ventas_periodo,
--     los pendientes de jornadas_preventista y lo tomado del digest no cambian;
--     pendientes_entrega del bot admin (lo que cobra el chofer) sube 500.
--     (b5) el ticket del gerencial de un dia con envio en TODOS sus pedidos (asi
--     el redondeo no lo tapa) no cambia. En (b) tambien _tablero_ventas y el
--     promedio de 7 dias del bot admin (llamado al dia siguiente).
-- (c) La invariante de mermas: reporte_mermas.totales.costo ==
--     reporte_gerencial.kpis.mermas (Red y cada sucursal, 90 dias), y
--     auditoria_integridad().critical_high_en_rojo igual que antes.
--
--   psql "$DATABASE_URL" -f scripts/test-cargo-4.sql   (ensayo solo)

-- ============================================================ PARTE 1 =====
DROP TABLE IF EXISTS pg_temp._cargo4_foto;
CREATE TEMP TABLE _cargo4_foto (
  etapa text  NOT NULL,            -- 'antes' | 'despues'
  fn    text  NOT NULL,
  clave text  NOT NULL,
  valor jsonb
);
DROP TABLE IF EXISTS pg_temp._cargo4_ctx;
CREATE TEMP TABLE _cargo4_ctx (k text PRIMARY KEY, v text);

-- Normaliza un jsonb para comparar contenido y no orden (molde de la 318).
CREATE OR REPLACE FUNCTION pg_temp._cargo4_norm(j jsonb) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $f$
DECLARE
  r jsonb;
BEGIN
  CASE jsonb_typeof(j)
    WHEN 'object' THEN
      SELECT COALESCE(jsonb_object_agg(e.k, pg_temp._cargo4_norm(e.v)), '{}'::jsonb)
        INTO r FROM jsonb_each(j) AS e(k, v);
    WHEN 'array' THEN
      SELECT COALESCE(jsonb_agg(s.x ORDER BY s.x::text), '[]'::jsonb)
        INTO r FROM (SELECT pg_temp._cargo4_norm(a.v) AS x FROM jsonb_array_elements(j) AS a(v)) s;
    ELSE
      r := j;
  END CASE;
  RETURN r;
END
$f$;

-- Fija o limpia la sesion que ven auth.uid() y current_sucursal_id().
CREATE OR REPLACE FUNCTION pg_temp._cargo4_como(p_uid uuid, p_suc bigint) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claims',
    CASE WHEN p_uid IS NULL THEN '' ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
  PERFORM set_config('request.headers',
    CASE WHEN p_suc IS NULL THEN '' ELSE json_build_object('x-sucursal-id', p_suc::text)::text END, true);
END
$f$;

-- La foto de las 12 funciones migradas. Los reportes de admin corren como
-- servicio (auth.uid() NULL: Red = todas las sucursales activas); las jornadas,
-- como el preventista en su sucursal.
CREATE OR REPLACE FUNCTION pg_temp._cargo4_fotografiar(p_etapa text) RETURNS integer
LANGUAGE plpgsql AS $f$
DECLARE
  d     date := CURRENT_DATE - 89;
  h     date := CURRENT_DATE;
  v_suc bigint;
  v_k   text;
  v_dia date;
  r     record;
  v_n   integer;
BEGIN
  PERFORM pg_temp._cargo4_como(NULL, NULL);

  FOR v_suc IN SELECT NULL::bigint UNION ALL (SELECT id FROM sucursales WHERE activa ORDER BY id) LOOP
    v_k := COALESCE(v_suc::text, 'red');
    INSERT INTO _cargo4_foto VALUES
      (p_etapa, 'reporte_gerencial', v_k || '|comparar', public.reporte_gerencial(v_suc, d, h, false, true)),
      (p_etapa, 'reporte_gerencial', v_k || '|no_entregados', public.reporte_gerencial(v_suc, d, h, true, false)),
      (p_etapa, 'reporte_ventas_por_cliente', v_k, public.reporte_ventas_por_cliente(d, h, NULL, v_suc)),
      (p_etapa, 'reporte_ventas_por_preventista', v_k, public.reporte_ventas_por_preventista(d, h, v_suc)),
      (p_etapa, 'reporte_alerta_detalle', v_k || '|clientes_inactivos',
         public.reporte_alerta_detalle(v_suc, 'clientes_inactivos', d, h, false)),
      (p_etapa, 'reporte_alerta_detalle', v_k || '|cobranza_vencida',
         public.reporte_alerta_detalle(v_suc, 'cobranza_vencida', d, h, false));
    FOR v_dia IN SELECT g::date FROM generate_series(h - 6, h, interval '1 day') g LOOP
      INSERT INTO _cargo4_foto VALUES
        (p_etapa, 'bot_metricas_admin_dia', v_k || '|' || v_dia, to_jsonb(public.bot_metricas_admin_dia(v_dia, v_suc)));
    END LOOP;
    INSERT INTO _cargo4_foto VALUES
      (p_etapa, '_tablero_ventas', v_k,
         (SELECT jsonb_agg(to_jsonb(x) ORDER BY x.pedido_id)
            FROM public._tablero_ventas(CASE WHEN v_suc IS NULL THEN ARRAY(SELECT id FROM sucursales WHERE activa)
                                             ELSE ARRAY[v_suc] END, d, h) x));
    IF v_suc IS NOT NULL THEN
      INSERT INTO _cargo4_foto VALUES
        (p_etapa, 'bot_ventas_periodo', v_k, to_jsonb(public.bot_ventas_periodo(d, h, v_suc, 10))),
        (p_etapa, 'clientes_ritmo_compra', v_k,
           (SELECT jsonb_agg(to_jsonb(x) ORDER BY x.cliente_id)
              FROM public.clientes_ritmo_compra(v_suc, 'admin', NULL, NULL, NULL) x));
    END IF;
  END LOOP;

  -- Cada vendedor con ventas en la ventana, en su sucursal.
  FOR r IN
    SELECT DISTINCT p.usuario_id, p.sucursal_id
      FROM pedidos p
     WHERE p.estado = 'entregado' AND p.canal <> 'cambio' AND p.tipo_factura IS DISTINCT FROM 'VB'
       AND p.fecha BETWEEN d AND h AND p.usuario_id IS NOT NULL
     ORDER BY 1, 2
  LOOP
    v_k := r.usuario_id || '|' || r.sucursal_id;
    INSERT INTO _cargo4_foto VALUES
      (p_etapa, 'bot_mis_ventas', v_k, to_jsonb(public.bot_mis_ventas(r.usuario_id, d, h, r.sucursal_id, 10)));
    IF EXISTS (SELECT 1 FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
                WHERE pf.id = r.usuario_id AND pf.rol = 'preventista' AND pf.activo
                  AND us.sucursal_id = r.sucursal_id) THEN
      INSERT INTO _cargo4_foto VALUES
        (p_etapa, 'bot_digest_preventista', v_k,
           to_jsonb(public.bot_digest_preventista(r.usuario_id, r.sucursal_id, h - 1)));
    END IF;
    PERFORM pg_temp._cargo4_como(r.usuario_id, r.sucursal_id);
    INSERT INTO _cargo4_foto VALUES
      (p_etapa, 'jornadas_preventista', v_k, public.jornadas_preventista(d, h, NULL)),
      (p_etapa, 'jornada_preventista_detalle', v_k || '|pendientes', public.jornada_preventista_detalle(NULL, NULL));
    FOR v_dia IN SELECT g::date FROM generate_series(h - 6, h, interval '1 day') g LOOP
      INSERT INTO _cargo4_foto VALUES
        (p_etapa, 'jornada_preventista_detalle', v_k || '|' || v_dia, public.jornada_preventista_detalle(v_dia, NULL));
    END LOOP;
    PERFORM pg_temp._cargo4_como(NULL, NULL);
  END LOOP;

  SELECT count(*) INTO v_n FROM _cargo4_foto WHERE etapa = p_etapa;
  RETURN v_n;
END
$f$;

DO $antes$
DECLARE
  v_n       int;
  v_hay_est boolean := EXISTS (SELECT 1 FROM information_schema.columns
                                WHERE table_schema = 'public' AND table_name = 'pedidos'
                                  AND column_name = 'cargo_envio_estado');
BEGIN
  -- Los pedidos que ya pagan envio quedan como si no lo pagaran (se deshace con
  -- el ROLLBACK): total -= cargo efectivo, cargo 0. El estado va en el mismo
  -- UPDATE por el CHECK cobrado <=> cargo > 0 (si la columna ya existe).
  EXECUTE format(
    'UPDATE pedidos SET total = GREATEST(total - cargo_envio, 0), cargo_envio = 0,
                        monto_pagado = monto_pagado%s
      WHERE cargo_envio > 0',
    CASE WHEN v_hay_est THEN ', cargo_envio_estado = ''no_aplica''' ELSE '' END);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  INSERT INTO _cargo4_ctx VALUES ('neutralizados', v_n::text);

  INSERT INTO _cargo4_ctx VALUES
    ('critical_high_antes', (public.auditoria_integridad() ->> 'critical_high_en_rojo'));

  INSERT INTO _cargo4_ctx VALUES ('fotos_antes', pg_temp._cargo4_fotografiar('antes')::text);
END
$antes$;

-- @@ MIGRACION @@ ============================================ PARTE 2 =====

DO $ensayo$
DECLARE
  v_fallas  text[] := '{}';
  d         date := CURRENT_DATE - 89;
  h         date := CURRENT_DATE;
  v_n       int;
  v_dif     int;
  r         record;
  v_p       record;
  v_q       record;
  v_hay_est boolean := EXISTS (SELECT 1 FROM information_schema.columns
                                WHERE table_schema = 'public' AND table_name = 'pedidos'
                                  AND column_name = 'cargo_envio_estado');
  v_neto    numeric;
  v_iva     numeric;
  v_dia     date;
  g0 jsonb; g1 jsonb; c0 jsonb; c1 jsonb; vp0 jsonb; vp1 jsonb; mv0 jsonb; mv1 jsonb;
  pe0 jsonb; pe1 jsonb; me0 jsonb; me1 jsonb; dg0 jsonb; dg1 jsonb; ri0 jsonb; ri1 jsonb;
  jo0 jsonb; jo1 jsonb; de0 jsonb; de1 jsonb; al0 jsonb; al1 jsonb;
  s0 numeric; s1 numeric;
  v_ger     jsonb;
  v_mer     jsonb;
  v_suc     bigint;
  v_ch      text;
  v_b2      text := 'sin cliente inactivo para (b2)';
  v_fc      record;
  v_b3      text := 'sin pedido FC para (b3)';
  v_r       record;
  tv0 jsonb; tv1 jsonb; mf0 jsonb; mf1 jsonb;
BEGIN
  SET LOCAL lock_timeout = '5s';

  -- ------------------------------------------- (a) la foto de despues -----
  PERFORM pg_temp._cargo4_fotografiar('despues');
  SELECT count(*) INTO v_n FROM _cargo4_foto WHERE etapa = 'antes';
  IF v_n = 0 THEN
    v_fallas := v_fallas || 'sin foto de antes: falta la parte 1'::text;
  END IF;
  SELECT count(*) INTO v_dif
    FROM (SELECT fn, clave FROM _cargo4_foto WHERE etapa = 'antes'
          EXCEPT SELECT fn, clave FROM _cargo4_foto WHERE etapa = 'despues') x;
  IF v_dif > 0 OR (SELECT count(*) FROM _cargo4_foto WHERE etapa = 'despues') <> v_n THEN
    v_fallas := v_fallas || format('las fotos de antes (%s) y despues no tienen las mismas llamadas', v_n);
  END IF;
  FOR r IN
    SELECT a.fn, a.clave
      FROM _cargo4_foto a JOIN _cargo4_foto b ON b.fn = a.fn AND b.clave = a.clave AND b.etapa = 'despues'
     WHERE a.etapa = 'antes'
       AND pg_temp._cargo4_norm(a.valor) IS DISTINCT FROM pg_temp._cargo4_norm(b.valor)
     ORDER BY 1, 2 LIMIT 10
  LOOP
    v_fallas := v_fallas || format('(a) %s [%s] cambio sin ningun cargo', r.fn, r.clave);
  END LOOP;

  -- ------------------------------------------- (b) un envio forzado ------
  SELECT p.* INTO v_p
    FROM pedidos p
    JOIN perfiles pf ON pf.id = p.usuario_id AND pf.rol = 'preventista' AND pf.activo
    JOIN usuario_sucursales us ON us.usuario_id = p.usuario_id AND us.sucursal_id = p.sucursal_id
    JOIN clientes c ON c.id = p.cliente_id AND c.activo
   WHERE p.estado = 'entregado' AND p.canal <> 'cambio' AND p.tipo_factura IS DISTINCT FROM 'VB'
     AND p.fecha BETWEEN h - 29 AND h - 1 AND p.total > 0 AND p.cargo_envio = 0
     AND COALESCE(p.monto_pagado, 0) <= p.total
     AND NOT EXISTS (SELECT 1 FROM pagos g WHERE g.pedido_id = p.id AND g.forma_pago = 'adelanto_sueldo')
   ORDER BY (p.tipo_factura = 'FC') DESC, p.fecha DESC, p.id DESC
   LIMIT 1;

  IF v_p.id IS NULL THEN
    v_fallas := v_fallas || 'sin blanco para (b): ningun pedido entregado de un preventista en 30 dias'::text;
  ELSE
    -- El dia de la jornada del pedido, como lo calcula jornada_preventista_detalle.
    v_dia := COALESCE((v_p.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date,
                      (SELECT (hh.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
                         FROM pedido_historial hh
                        WHERE hh.pedido_id = v_p.id AND hh.campo_modificado = 'estado'
                          AND hh.valor_nuevo = 'entregado'
                        ORDER BY hh.created_at DESC LIMIT 1),
                      v_p.fecha);
    -- El desglose como lo hace cargo_envio_desglose (inline: antes de
    -- cargo_1_base la funcion no existe).
    IF v_p.tipo_factura = 'FC' THEN
      v_neto := round(500 / 1.21, 2); v_iva := 500 - v_neto;
    ELSE
      v_neto := 500; v_iva := 0;
    END IF;

    BEGIN
      PERFORM pg_temp._cargo4_como(NULL, NULL);
      g0  := public.reporte_gerencial(v_p.sucursal_id, d, h, false, false);
      c0  := public.reporte_ventas_por_cliente(d, h, NULL, v_p.sucursal_id);
      vp0 := (SELECT x FROM jsonb_array_elements(public.reporte_ventas_por_preventista(d, h, v_p.sucursal_id)) x
               WHERE x->>'id' = v_p.usuario_id::text);
      mv0 := to_jsonb(public.bot_mis_ventas(v_p.usuario_id, d, h, v_p.sucursal_id, 10));
      pe0 := to_jsonb(public.bot_ventas_periodo(d, h, v_p.sucursal_id, 10));
      me0 := to_jsonb(public.bot_metricas_admin_dia(v_p.fecha, v_p.sucursal_id));
      dg0 := to_jsonb(public.bot_digest_preventista(v_p.usuario_id, v_p.sucursal_id, v_p.fecha));
      ri0 := (SELECT to_jsonb(x) FROM public.clientes_ritmo_compra(v_p.sucursal_id, 'admin', NULL, NULL, v_p.cliente_id) x);
      tv0 := (SELECT jsonb_agg(to_jsonb(x) ORDER BY x.pedido_id) FROM public._tablero_ventas(ARRAY[v_p.sucursal_id], d, h) x);
      -- Al dia siguiente el pedido cae en el promedio de 7 dias (pedidos_7d).
      mf0 := to_jsonb(public.bot_metricas_admin_dia(v_p.fecha + 1, v_p.sucursal_id));
      SELECT saldo_cuenta INTO s0 FROM clientes WHERE id = v_p.cliente_id;
      PERFORM pg_temp._cargo4_como(v_p.usuario_id, v_p.sucursal_id);
      jo0 := public.jornadas_preventista(d, h, NULL);
      de0 := public.jornada_preventista_detalle(v_dia, NULL);
      PERFORM pg_temp._cargo4_como(NULL, NULL);

      -- El envio, como lo cobraria el alta (trampa 6: total y monto_pagado en el SET).
      EXECUTE format(
        'UPDATE pedidos SET cargo_envio = 500, total = total + 500, monto_pagado = monto_pagado,
                            total_neto = total_neto + %s, total_iva = total_iva + %s%s
          WHERE id = %s',
        v_neto, v_iva, CASE WHEN v_hay_est THEN ', cargo_envio_estado = ''cobrado''' ELSE '' END, v_p.id);

      g1  := public.reporte_gerencial(v_p.sucursal_id, d, h, false, false);
      c1  := public.reporte_ventas_por_cliente(d, h, NULL, v_p.sucursal_id);
      vp1 := (SELECT x FROM jsonb_array_elements(public.reporte_ventas_por_preventista(d, h, v_p.sucursal_id)) x
               WHERE x->>'id' = v_p.usuario_id::text);
      mv1 := to_jsonb(public.bot_mis_ventas(v_p.usuario_id, d, h, v_p.sucursal_id, 10));
      pe1 := to_jsonb(public.bot_ventas_periodo(d, h, v_p.sucursal_id, 10));
      me1 := to_jsonb(public.bot_metricas_admin_dia(v_p.fecha, v_p.sucursal_id));
      dg1 := to_jsonb(public.bot_digest_preventista(v_p.usuario_id, v_p.sucursal_id, v_p.fecha));
      ri1 := (SELECT to_jsonb(x) FROM public.clientes_ritmo_compra(v_p.sucursal_id, 'admin', NULL, NULL, v_p.cliente_id) x);
      tv1 := (SELECT jsonb_agg(to_jsonb(x) ORDER BY x.pedido_id) FROM public._tablero_ventas(ARRAY[v_p.sucursal_id], d, h) x);
      mf1 := to_jsonb(public.bot_metricas_admin_dia(v_p.fecha + 1, v_p.sucursal_id));
      SELECT saldo_cuenta INTO s1 FROM clientes WHERE id = v_p.cliente_id;
      PERFORM pg_temp._cargo4_como(v_p.usuario_id, v_p.sucursal_id);
      jo1 := public.jornadas_preventista(d, h, NULL);
      de1 := public.jornada_preventista_detalle(v_dia, NULL);
      PERFORM pg_temp._cargo4_como(NULL, NULL);

      -- La venta no cambia...
      FOR r IN SELECT k FROM unnest(ARRAY['kpis', 'mensual', 'vendedores', 'categorias', 'top_productos',
                                          'top_clientes', 'serie_diaria']) k LOOP
        IF pg_temp._cargo4_norm(g0 -> r.k) IS DISTINCT FROM pg_temp._cargo4_norm(g1 -> r.k) THEN
          v_fallas := v_fallas || format('(b) reporte_gerencial.%s cambio con el envio%s', r.k,
            CASE WHEN r.k = 'kpis' THEN format(' (venta %s -> %s, venta_neta %s -> %s, base_comision %s -> %s)',
                   g0->'kpis'->>'venta', g1->'kpis'->>'venta', g0->'kpis'->>'venta_neta', g1->'kpis'->>'venta_neta',
                   g0->'kpis'->>'base_comision', g1->'kpis'->>'base_comision') ELSE '' END);
        END IF;
      END LOOP;
      IF pg_temp._cargo4_norm(c0) IS DISTINCT FROM pg_temp._cargo4_norm(c1) THEN
        v_fallas := v_fallas || format('(b) reporte_ventas_por_cliente cambio (total %s -> %s)',
                                       c0->'totales'->>'total', c1->'totales'->>'total');
      END IF;
      IF vp0->'totalVentas' IS DISTINCT FROM vp1->'totalVentas' OR vp0->'totalPagado' IS DISTINCT FROM vp1->'totalPagado' THEN
        v_fallas := v_fallas || format('(b) reporte_ventas_por_preventista.totalVentas cambio (%s -> %s)',
                                       vp0->>'totalVentas', vp1->>'totalVentas');
      END IF;
      IF pg_temp._cargo4_norm(mv0) IS DISTINCT FROM pg_temp._cargo4_norm(mv1) THEN
        v_fallas := v_fallas || format('(b) bot_mis_ventas cambio (total_ventas %s -> %s)',
                                       mv0->>'total_ventas', mv1->>'total_ventas');
      END IF;
      IF pg_temp._cargo4_norm(pe0) IS DISTINCT FROM pg_temp._cargo4_norm(pe1) THEN
        v_fallas := v_fallas || format('(b) bot_ventas_periodo cambio (total_ventas %s -> %s)',
                                       pe0->>'total_ventas', pe1->>'total_ventas');
      END IF;
      IF pg_temp._cargo4_norm(me0 - ARRAY['pendientes_pago', 'cuentas_por_cobrar', 'cxc_vencido', 'pendientes_entrega'])
         IS DISTINCT FROM pg_temp._cargo4_norm(me1 - ARRAY['pendientes_pago', 'cuentas_por_cobrar', 'cxc_vencido', 'pendientes_entrega']) THEN
        v_fallas := v_fallas || format('(b) bot_metricas_admin_dia cambio la venta (ventas_dia %s -> %s, entregado_dia %s -> %s)',
                                       me0->'ventas_dia'->>'total', me1->'ventas_dia'->>'total',
                                       me0->'entregado_dia'->>'total', me1->'entregado_dia'->>'total');
      END IF;
      IF mf0->'promedio_7d' IS DISTINCT FROM mf1->'promedio_7d' OR mf0->'delta_pct' IS DISTINCT FROM mf1->'delta_pct' THEN
        v_fallas := v_fallas || format('(b) bot_metricas_admin_dia(%s).promedio_7d cambio (%s -> %s)',
                                       v_p.fecha + 1, mf0->'promedio_7d'->>'total_dia_avg', mf1->'promedio_7d'->>'total_dia_avg');
      END IF;
      IF tv0 IS DISTINCT FROM tv1 THEN
        v_fallas := v_fallas || '(b) _tablero_ventas cambio con el envio'::text;
      END IF;
      IF dg0->'mis_ventas' IS DISTINCT FROM dg1->'mis_ventas' THEN
        v_fallas := v_fallas || format('(b) bot_digest_preventista.mis_ventas cambio (dia %s -> %s, mes %s -> %s)',
                                       dg0->'mis_ventas'->>'dia_tomados_total', dg1->'mis_ventas'->>'dia_tomados_total',
                                       dg0->'mis_ventas'->>'mes_total', dg1->'mis_ventas'->>'mes_total');
      END IF;
      IF ri0->'monto_mensual' IS DISTINCT FROM ri1->'monto_mensual' THEN
        v_fallas := v_fallas || format('(b) clientes_ritmo_compra.monto_mensual cambio (%s -> %s)',
                                       ri0->>'monto_mensual', ri1->>'monto_mensual');
      END IF;
      IF pg_temp._cargo4_norm(jo0) IS DISTINCT FROM pg_temp._cargo4_norm(jo1) THEN
        v_fallas := v_fallas || '(b) jornadas_preventista cambio con el envio'::text;
      END IF;
      IF pg_temp._cargo4_norm(de0) IS DISTINCT FROM pg_temp._cargo4_norm(de1) THEN
        v_fallas := v_fallas || format('(b) jornada_preventista_detalle(%s) cambio con el envio', v_dia);
      END IF;
      -- ...y la plata a cobrar sube $500.
      IF s1 - s0 <> 500 THEN
        v_fallas := v_fallas || format('(b) el saldo del cliente %s subio %s (esperado 500)', v_p.cliente_id, s1 - s0);
      END IF;
      IF (ri1->>'saldo')::numeric - (ri0->>'saldo')::numeric <> 500 THEN
        v_fallas := v_fallas || format('(b) clientes_ritmo_compra.saldo subio %s (esperado 500)',
                                       (ri1->>'saldo')::numeric - (ri0->>'saldo')::numeric);
      END IF;
      IF (g1->'cobranza'->>'pendiente')::numeric - (g0->'cobranza'->>'pendiente')::numeric <> 500 THEN
        v_fallas := v_fallas || format('(b) reporte_gerencial.cobranza.pendiente subio %s (esperado 500)',
          (g1->'cobranza'->>'pendiente')::numeric - (g0->'cobranza'->>'pendiente')::numeric);
      END IF;
      IF (vp1->>'totalPendiente')::numeric - (vp0->>'totalPendiente')::numeric <> 500 THEN
        v_fallas := v_fallas || format('(b) reporte_ventas_por_preventista.totalPendiente subio %s (esperado 500)',
          (vp1->>'totalPendiente')::numeric - (vp0->>'totalPendiente')::numeric);
      END IF;

      RAISE EXCEPTION USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('(b) saltado: %s', SQLERRM);
    END;
    PERFORM pg_temp._cargo4_como(NULL, NULL);
  END IF;

  -- (b2) La alerta de clientes inactivos: el ultimo pedido de un cliente que
  -- compraba hasta hace 30-90 dias.
  SELECT p.* INTO v_q
    FROM pedidos p JOIN clientes c ON c.id = p.cliente_id AND c.activo
   WHERE p.estado = 'entregado' AND p.canal <> 'cambio' AND p.tipo_factura IS DISTINCT FROM 'VB'
     AND p.total > 0 AND p.cargo_envio = 0
     AND p.fecha = (SELECT max(p2.fecha) FROM pedidos p2
                     WHERE p2.cliente_id = p.cliente_id AND p2.estado = 'entregado' AND p2.canal <> 'cambio'
                       AND p2.tipo_factura IS DISTINCT FROM 'VB')
     AND p.fecha < CURRENT_DATE - 30 AND p.fecha >= CURRENT_DATE - 89
   ORDER BY p.fecha DESC, p.id DESC LIMIT 1;
  IF v_q.id IS NOT NULL THEN
    BEGIN
      al0 := public.reporte_alerta_detalle(v_q.sucursal_id, 'clientes_inactivos', d, h, false);
      EXECUTE format(
        'UPDATE pedidos SET cargo_envio = 500, total = total + 500, monto_pagado = monto_pagado,
                            total_neto = total_neto + %s, total_iva = total_iva + %s%s
          WHERE id = %s',
        CASE WHEN v_q.tipo_factura = 'FC' THEN round(500 / 1.21, 2) ELSE 500 END,
        CASE WHEN v_q.tipo_factura = 'FC' THEN 500 - round(500 / 1.21, 2) ELSE 0 END,
        CASE WHEN v_hay_est THEN ', cargo_envio_estado = ''cobrado''' ELSE '' END, v_q.id);
      al1 := public.reporte_alerta_detalle(v_q.sucursal_id, 'clientes_inactivos', d, h, false);
      IF pg_temp._cargo4_norm(al0) IS DISTINCT FROM pg_temp._cargo4_norm(al1) THEN
        v_fallas := v_fallas || format('(b2) reporte_alerta_detalle(clientes_inactivos) cambio con el envio del pedido %s', v_q.id);
      END IF;
      v_b2 := format('(b2) pedido %s', v_q.id);
      RAISE EXCEPTION USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('(b2) saltado: %s', SQLERRM);
    END;
  END IF;

  -- (b3) El desglose FC (21 % incluido): un pedido FC entregado de la ventana,
  -- de cualquier vendedor. venta_neta, iva_debito, fc_venta y el resto de los
  -- kpis del gerencial no cambian; la cobranza pendiente sube 500.
  SELECT p.* INTO v_fc
    FROM pedidos p
   WHERE p.estado = 'entregado' AND p.canal <> 'cambio' AND p.tipo_factura = 'FC'
     AND p.fecha BETWEEN d AND h AND p.total > 0 AND p.cargo_envio = 0
     AND p.total_neto IS NOT NULL AND p.total_iva IS NOT NULL
     AND COALESCE(p.monto_pagado, 0) <= p.total
   ORDER BY p.fecha DESC, p.id DESC LIMIT 1;
  IF v_fc.id IS NOT NULL THEN
    BEGIN
      g0 := public.reporte_gerencial(v_fc.sucursal_id, d, h, false, false);
      EXECUTE format(
        'UPDATE pedidos SET cargo_envio = 500, total = total + 500, monto_pagado = monto_pagado,
                            total_neto = total_neto + %s, total_iva = total_iva + %s%s
          WHERE id = %s',
        round(500 / 1.21, 2), 500 - round(500 / 1.21, 2),
        CASE WHEN v_hay_est THEN ', cargo_envio_estado = ''cobrado''' ELSE '' END, v_fc.id);
      g1 := public.reporte_gerencial(v_fc.sucursal_id, d, h, false, false);
      IF pg_temp._cargo4_norm(g0 -> 'kpis') IS DISTINCT FROM pg_temp._cargo4_norm(g1 -> 'kpis') THEN
        v_fallas := v_fallas || format('(b3) FC pedido %s: kpis del gerencial cambiaron (venta_neta %s -> %s, iva_debito %s -> %s, fc_venta %s -> %s)',
          v_fc.id, g0->'kpis'->>'venta_neta', g1->'kpis'->>'venta_neta', g0->'kpis'->>'iva_debito',
          g1->'kpis'->>'iva_debito', g0->'kpis'->>'fc_venta', g1->'kpis'->>'fc_venta');
      END IF;
      IF (g1->'cobranza'->>'pendiente')::numeric - (g0->'cobranza'->>'pendiente')::numeric <> 500 THEN
        v_fallas := v_fallas || format('(b3) FC pedido %s: cobranza.pendiente subio %s (esperado 500)', v_fc.id,
          (g1->'cobranza'->>'pendiente')::numeric - (g0->'cobranza'->>'pendiente')::numeric);
      END IF;
      v_b3 := format('(b3) FC pedido %s', v_fc.id);
      RAISE EXCEPTION USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('(b3) saltado: %s', SQLERRM);
    END;
  END IF;

  -- (b4) Un pedido PENDIENTE de un preventista (venta en curso, lo tomado):
  -- en_curso de bot_ventas_periodo, los pendientes de jornadas_preventista y su
  -- detalle y lo tomado del digest no cambian; lo que el chofer va a cobrar
  -- (pendientes_entrega del bot admin) sube 500.
  SELECT p.* INTO v_r
    FROM pedidos p
    JOIN perfiles pf ON pf.id = p.usuario_id AND pf.rol = 'preventista' AND pf.activo
    JOIN usuario_sucursales us ON us.usuario_id = p.usuario_id AND us.sucursal_id = p.sucursal_id
   WHERE p.estado IN ('pendiente', 'asignado') AND p.canal <> 'cambio' AND p.tipo_factura IS DISTINCT FROM 'VB'
     AND p.fecha BETWEEN GREATEST(d, h - 14) AND h AND p.total > 0 AND p.cargo_envio = 0
   ORDER BY p.fecha DESC, p.id DESC LIMIT 1;
  IF v_r.id IS NULL THEN
    v_fallas := v_fallas || 'sin blanco para (b4): ningun pedido pendiente de un preventista en 14 dias'::text;
  ELSE
    BEGIN
      PERFORM pg_temp._cargo4_como(NULL, NULL);
      pe0 := to_jsonb(public.bot_ventas_periodo(d, h, v_r.sucursal_id, 10));
      me0 := to_jsonb(public.bot_metricas_admin_dia(h, v_r.sucursal_id));
      dg0 := to_jsonb(public.bot_digest_preventista(v_r.usuario_id, v_r.sucursal_id, v_r.fecha));
      PERFORM pg_temp._cargo4_como(v_r.usuario_id, v_r.sucursal_id);
      jo0 := public.jornadas_preventista(d, h, NULL);
      de0 := public.jornada_preventista_detalle(NULL, NULL);
      PERFORM pg_temp._cargo4_como(NULL, NULL);

      EXECUTE format(
        'UPDATE pedidos SET cargo_envio = 500, total = total + 500, monto_pagado = monto_pagado,
                            total_neto = total_neto + %s, total_iva = total_iva + %s%s
          WHERE id = %s',
        CASE WHEN v_r.tipo_factura = 'FC' THEN round(500 / 1.21, 2) ELSE 500 END,
        CASE WHEN v_r.tipo_factura = 'FC' THEN 500 - round(500 / 1.21, 2) ELSE 0 END,
        CASE WHEN v_hay_est THEN ', cargo_envio_estado = ''cobrado''' ELSE '' END, v_r.id);

      pe1 := to_jsonb(public.bot_ventas_periodo(d, h, v_r.sucursal_id, 10));
      me1 := to_jsonb(public.bot_metricas_admin_dia(h, v_r.sucursal_id));
      dg1 := to_jsonb(public.bot_digest_preventista(v_r.usuario_id, v_r.sucursal_id, v_r.fecha));
      PERFORM pg_temp._cargo4_como(v_r.usuario_id, v_r.sucursal_id);
      jo1 := public.jornadas_preventista(d, h, NULL);
      de1 := public.jornada_preventista_detalle(NULL, NULL);
      PERFORM pg_temp._cargo4_como(NULL, NULL);

      IF pe0->'en_curso_monto' IS DISTINCT FROM pe1->'en_curso_monto' THEN
        v_fallas := v_fallas || format('(b4) bot_ventas_periodo.en_curso_monto cambio (%s -> %s)',
                                       pe0->>'en_curso_monto', pe1->>'en_curso_monto');
      END IF;
      IF jo0->'pendientes' IS DISTINCT FROM jo1->'pendientes' THEN
        v_fallas := v_fallas || format('(b4) jornadas_preventista.pendientes.monto cambio (%s -> %s)',
                                       jo0->'pendientes'->>'monto', jo1->'pendientes'->>'monto');
      END IF;
      IF pg_temp._cargo4_norm(de0) IS DISTINCT FROM pg_temp._cargo4_norm(de1) THEN
        v_fallas := v_fallas || '(b4) jornada_preventista_detalle(pendientes) cambio con el envio'::text;
      END IF;
      IF dg0->'mis_ventas' IS DISTINCT FROM dg1->'mis_ventas' THEN
        v_fallas := v_fallas || format('(b4) bot_digest_preventista.dia_tomados_total cambio (%s -> %s)',
                                       dg0->'mis_ventas'->>'dia_tomados_total', dg1->'mis_ventas'->>'dia_tomados_total');
      END IF;
      IF pg_temp._cargo4_norm(me0 - ARRAY['pendientes_pago', 'cuentas_por_cobrar', 'cxc_vencido', 'pendientes_entrega'])
         IS DISTINCT FROM pg_temp._cargo4_norm(me1 - ARRAY['pendientes_pago', 'cuentas_por_cobrar', 'cxc_vencido', 'pendientes_entrega']) THEN
        v_fallas := v_fallas || '(b4) bot_metricas_admin_dia cambio la venta con un pendiente'::text;
      END IF;
      IF (me1->'pendientes_entrega'->>'monto')::numeric - (me0->'pendientes_entrega'->>'monto')::numeric <> 500 THEN
        v_fallas := v_fallas || format('(b4) pendientes_entrega.monto subio %s (esperado 500)',
          (me1->'pendientes_entrega'->>'monto')::numeric - (me0->'pendientes_entrega'->>'monto')::numeric);
      END IF;
      RAISE EXCEPTION USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('(b4) saltado: %s', SQLERRM);
    END;
    PERFORM pg_temp._cargo4_como(NULL, NULL);
  END IF;

  -- (b5) El ticket del gerencial, sin que lo tape el redondeo: un envio en
  -- TODOS los pedidos de un dia de la sucursal sube el promedio exactamente 500
  -- si se lo cuenta como venta. El ticket de kpis y el de mensual no cambian.
  IF v_p.id IS NOT NULL THEN
    BEGIN
      g0 := public.reporte_gerencial(v_p.sucursal_id, v_p.fecha, v_p.fecha, false, false);
      EXECUTE format(
        'UPDATE pedidos SET cargo_envio = 500, total = total + 500, monto_pagado = monto_pagado%s
          WHERE sucursal_id = %s AND fecha = %L AND estado = ''entregado'' AND canal <> ''cambio''
            AND tipo_factura IS DISTINCT FROM ''VB'' AND total > 0 AND cargo_envio = 0',
        CASE WHEN v_hay_est THEN ', cargo_envio_estado = ''cobrado''' ELSE '' END, v_p.sucursal_id, v_p.fecha);
      g1 := public.reporte_gerencial(v_p.sucursal_id, v_p.fecha, v_p.fecha, false, false);
      IF g0->'kpis'->'ticket' IS DISTINCT FROM g1->'kpis'->'ticket'
         OR g0->'mensual'->0->'ticket' IS DISTINCT FROM g1->'mensual'->0->'ticket' THEN
        v_fallas := v_fallas || format('(b5) ticket del gerencial (%s, suc %s) cambio con el envio: kpis %s -> %s, mensual %s -> %s',
          v_p.fecha, v_p.sucursal_id, g0->'kpis'->>'ticket', g1->'kpis'->>'ticket',
          g0->'mensual'->0->>'ticket', g1->'mensual'->0->>'ticket');
      END IF;
      RAISE EXCEPTION USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('(b5) saltado: %s', SQLERRM);
    END;
  END IF;

  -- ------------------------------------- (c) mermas e integridad ---------
  FOR v_suc IN SELECT NULL::bigint UNION ALL (SELECT id FROM sucursales WHERE activa ORDER BY id) LOOP
    v_ger := public.reporte_gerencial(v_suc, d, h, false, false);
    v_mer := public.reporte_mermas(p_desde => d, p_hasta => h, p_sucursal_id => v_suc);
    IF (v_ger->'kpis'->>'mermas')::numeric IS DISTINCT FROM (v_mer->'totales'->>'costo')::numeric THEN
      v_fallas := v_fallas || format('(c) mermas %s: gerencial %s, reporte_mermas %s',
        COALESCE(v_suc::text, 'red'), v_ger->'kpis'->>'mermas', v_mer->'totales'->>'costo');
    END IF;
  END LOOP;
  v_ch := public.auditoria_integridad() ->> 'critical_high_en_rojo';
  IF v_ch IS DISTINCT FROM (SELECT v FROM _cargo4_ctx WHERE k = 'critical_high_antes') THEN
    v_fallas := v_fallas || format('(c) critical_high_en_rojo %s -> %s',
                                   (SELECT v FROM _cargo4_ctx WHERE k = 'critical_high_antes'), v_ch);
  END IF;

  -- ------------------------------------------------------------ veredicto --
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · (a) % llamadas identicas antes/despues (% pedidos con cargo neutralizados) · (b) pedido % (%, suc %): venta igual en las 12, saldo/cobranza/pendiente +500 · % · % · (b4) pendiente % · (b5) ticket de % · (c) mermas = gerencial, critical_high % -> %',
    v_n, (SELECT v FROM _cargo4_ctx WHERE k = 'neutralizados'), v_p.id, v_p.tipo_factura, v_p.sucursal_id, v_b2, v_b3,
    v_r.id, v_p.fecha,
    (SELECT v FROM _cargo4_ctx WHERE k = 'critical_high_antes'), v_ch;
END
$ensayo$;
