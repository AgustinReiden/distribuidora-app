-- =============================================================================
-- 326 · Los canjes quedan fuera de las RPCs de venta del front
-- =============================================================================
--
-- Cierra lo que quedaba de #1033 (la parte del bot fue la 324). Un canje es la
-- comanda de un cambio (`canal = 'cambio'`, total 0 por CAMBIO-01): no es una
-- venta ni un pedido del cliente.
--
--   * reporte_ventas_por_cliente: NO se toca. Ya filtraba el canal desde antes
--     (`COALESCE(pe.canal, 'app') <> 'cambio'`; el COALESCE sobra porque
--     `pedidos.canal` es NOT NULL DEFAULT 'app', pero da lo mismo). El ensayo
--     verifica igual que sus totales son los de la definición canónica, porque
--     `bot_ranking_clientes` los hereda (BOT-B).
--
--   * obtener_resumen_cuenta_cliente: contaba el canje en total de pedidos,
--     total de compras, pendientes de pago y fecha del último pedido. Se le
--     agrega `canal <> 'cambio'` en esas cuatro lecturas, igual que la 324 hizo
--     con la copia `_bot`. El consumo interno (VB) no cambia. Hoy el front sólo
--     lee `saldo_actual` de esta RPC (ficha del cliente y registrar pago), que no
--     se toca: el cambio no mueve ningún número visible.
--     No se le agrega el filtro de cancelados que sí tiene la `_bot`: es otro
--     cambio (los cancelados tienen total 0 y suman en `total_pedidos` desde
--     siempre) y no es de #1033.
--
--   * obtener_estadisticas_pedidos: el canje (entregado, $0) bajaba el ticket
--     promedio. Se le agrega `canal <> 'cambio'` en las dos cifras de venta
--     (`total_ventas`, `promedio_ticket`), al lado del filtro VB. Los conteos por
--     estado NO cambian, por la misma razón que dejó escrita la 3XB: son
--     operativos (el canje se prepara y se reparte), no venta. `consumo_interno`
--     queda como está, igual que en la 324.
--     El issue también marca que filtra por `created_at`. NO se cambia acá: la
--     función no tiene caller (la 314 la dejó sólo para service_role y con
--     service_role `current_sucursal_id()` da NULL, así que hoy no corre desde
--     ningún lado), sus parámetros son `timestamptz` y pasar a `fecha` cambia su
--     contrato, y lo que mide sobre todo son conteos operativos por carga. Si
--     alguna vez vuelve a tener un caller, el rango tiene que pasar a `fecha`
--     con día argentino (mig 241); mientras tanto lo que corresponde es borrarla.
--
-- Cada cuerpo es el VIGENTE en prod (con el vale blanco de la 318/319); la
-- premisa de abajo frena la migración si alguno cambió desde que se copió.
-- =============================================================================

BEGIN;

-- 0 · Premisas: nada cambió en prod desde que se copiaron (md5 del 2026-10-09).
DO $premisas$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, md5(p.prosrc) AS md5_vivo
      FROM (VALUES
        ('public.obtener_resumen_cuenta_cliente(integer)',                                   'cc9a7a6627709c8c2537a8865058da97'),
        ('public.obtener_estadisticas_pedidos(timestamp with time zone,timestamp with time zone,uuid)', '894729074507f3f246d44a78cdad0bca'),
        -- No se reemplaza, pero el ensayo asume que ya filtra el canal.
        ('public.reporte_ventas_por_cliente(date,date,uuid,bigint)',                         'f718308494e51626a7baf545fb7f9bc2')
      ) AS x(firma, md5)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION '326 · % cambió en prod desde que se copió (md5 %, esperado %): rehacer la copia sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;
END
$premisas$;


-- 0b · Foto del ANTES, para que el ensayo compare contra la función vieja y no
--      contra una reescritura. Va en un GUC de la transacción: no deja nada.
DO $antes$
DECLARE
  v_canje        RECORD;
  v_admin        uuid;
  v_claims_prev  text := current_setting('request.jwt.claims', true);
  v_headers_prev text := current_setting('request.headers', true);
  v_foto         jsonb := '{}'::jsonb;
BEGIN
  FOR v_canje IN
    SELECT pe.id, pe.cliente_id, pe.sucursal_id, pe.usuario_id FROM pedidos pe
     WHERE pe.canal = 'cambio' AND pe.estado = 'entregado'
     ORDER BY pe.id DESC LIMIT 1
  LOOP
    SELECT us.usuario_id INTO v_admin
      FROM usuario_sucursales us
      JOIN perfiles pf ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
     WHERE us.sucursal_id = v_canje.sucursal_id
     ORDER BY us.usuario_id LIMIT 1;
    IF v_admin IS NULL THEN
      RAISE EXCEPTION 'ensayo 326: no hay un admin activo en la sucursal % para mirar el antes', v_canje.sucursal_id;
    END IF;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_canje.sucursal_id::text)::text, true);

    v_foto := jsonb_build_object(
      'canje_id',   v_canje.id,
      'admin',      v_admin,
      'cuenta',     obtener_resumen_cuenta_cliente(v_canje.cliente_id::int)::jsonb,
      'stats',      obtener_estadisticas_pedidos(NULL, NULL, NULL),
      'stats_prev', obtener_estadisticas_pedidos(NULL, NULL, v_canje.usuario_id)
    );
  END LOOP;

  PERFORM set_config('request.jwt.claims', COALESCE(v_claims_prev, ''), true);
  PERFORM set_config('request.headers', COALESCE(v_headers_prev, ''), true);
  PERFORM set_config('ensayo326.antes', v_foto::text, true);
END
$antes$;


-- ---------------------------------------------------------------------------
-- 1 · El resumen de cuenta del front no cuenta canjes
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_resumen_cuenta_cliente(p_cliente_id integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  resultado JSON;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN json_build_object('error', 'No autenticado');
  END IF;

  -- Mismo predicado que la política mt_clientes_select (migs 298 y #999).
  IF NOT EXISTS (
    SELECT 1 FROM clientes c
    WHERE c.id = p_cliente_id
      AND c.sucursal_id = current_sucursal_id()
      AND (
        NOT EXISTS (SELECT 1 FROM perfiles p WHERE p.id = auth.uid() AND p.rol = 'preventista')
        OR (
          (
            NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id)
            OR EXISTS (SELECT 1 FROM cliente_preventistas cp
                       WHERE cp.cliente_id = c.id AND cp.preventista_id = auth.uid())
          )
          AND (
            NOT c.reservado_admin
            OR EXISTS (SELECT 1 FROM pedidos pe
                       WHERE pe.cliente_id = c.id AND pe.usuario_id = auth.uid())
          )
        )
      )
      AND NOT EXISTS (SELECT 1 FROM perfiles pd WHERE pd.id = auth.uid() AND pd.rol = 'deposito')
  ) THEN
    RAISE EXCEPTION 'Cliente % no encontrado o sin permiso para ver su cuenta', p_cliente_id
      USING ERRCODE = '42501';
  END IF;

  -- Un canje (canal 'cambio', total 0) no es un pedido del cliente: no cuenta en
  -- pedidos, compras, pendientes de pago ni en la fecha del ultimo (326, #1033).
  SELECT json_build_object(
    'saldo_actual', COALESCE(c.saldo_cuenta, 0),
    'limite_credito', COALESCE(c.limite_credito, 0),
    'credito_disponible', COALESCE(c.limite_credito, 0) - COALESCE(c.saldo_cuenta, 0),
    'total_pedidos', (SELECT COUNT(*) FROM pedidos
                       WHERE cliente_id = p_cliente_id AND canal <> 'cambio'
                         AND tipo_factura IS DISTINCT FROM 'VB'),
    'total_compras', (SELECT COALESCE(SUM(total), 0) FROM pedidos
                       WHERE cliente_id = p_cliente_id AND canal <> 'cambio'
                         AND tipo_factura IS DISTINCT FROM 'VB'),
    'total_pagos', (SELECT COALESCE(SUM(monto), 0) FROM pagos WHERE cliente_id = p_cliente_id),
    'pedidos_pendientes_pago', (SELECT COUNT(*) FROM pedidos WHERE cliente_id = p_cliente_id
                                  AND canal <> 'cambio' AND estado_pago != 'pagado'),
    'ultimo_pedido', (SELECT MAX(created_at) FROM pedidos
                       WHERE cliente_id = p_cliente_id AND canal <> 'cambio'
                         AND tipo_factura IS DISTINCT FROM 'VB'),
    'ultimo_pago', (SELECT MAX(created_at) FROM pagos WHERE cliente_id = p_cliente_id),
    'consumo_interno', (SELECT json_build_object('monto', COALESCE(SUM(total), 0), 'pedidos', COUNT(*))
                          FROM pedidos
                         WHERE cliente_id = p_cliente_id AND tipo_factura = 'VB'
                           AND estado IS DISTINCT FROM 'cancelado')
  ) INTO resultado
  FROM clientes c
  WHERE c.id = p_cliente_id;

  RETURN resultado;
END;
$function$;


-- ---------------------------------------------------------------------------
-- 2 · Las cifras de venta de las estadísticas no cuentan canjes
-- ---------------------------------------------------------------------------
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
    -- 326 (#1033): el canje tampoco es venta; con total 0 bajaba el ticket.
    'total_ventas', COALESCE(SUM(total) FILTER (WHERE estado = 'entregado' AND canal <> 'cambio' AND tipo_factura IS DISTINCT FROM 'VB'), 0)::numeric(12,2),
    'promedio_ticket', COALESCE(AVG(total) FILTER (WHERE estado = 'entregado' AND canal <> 'cambio' AND tipo_factura IS DISTINCT FROM 'VB'), 0)::numeric(12,2),
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

-- CREATE OR REPLACE conserva los permisos; se reafirman igual.
-- obtener_resumen_cuenta_cliente la llama el front (usePagos): las dos mitades.
REVOKE EXECUTE ON FUNCTION public.obtener_resumen_cuenta_cliente(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.obtener_resumen_cuenta_cliente(integer) TO authenticated, service_role;
-- obtener_estadisticas_pedidos es sólo de servidor desde la 314: las tres.
REVOKE EXECUTE ON FUNCTION public.obtener_estadisticas_pedidos(timestamp with time zone, timestamp with time zone, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_estadisticas_pedidos(timestamp with time zone, timestamp with time zone, uuid) TO service_role;


-- ---------------------------------------------------------------------------
-- 3 · Ensayo
-- ---------------------------------------------------------------------------
DO $ensayo$
DECLARE
  s              RECORD;
  v_antes        jsonb := NULLIF(current_setting('ensayo326.antes', true), '')::jsonb;
  v_canje        RECORD;
  v_r            jsonb;
  v_j            jsonb;
  v_n            bigint;
  v_monto        numeric;
  v_avg          numeric;
  v_ult          timestamptz;
  v_hoy          date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_claims_prev  text := current_setting('request.jwt.claims', true);
  v_headers_prev text := current_setting('request.headers', true);
BEGIN
  -- 3a. reporte_ventas_por_cliente (no se tocó) da la venta canónica en cada
  --     sucursal: entregado · canal <> 'cambio' · sin VB · por fecha. Corre en
  --     modo servicio (sin claims), como la llama bot_ranking_clientes.
  PERFORM set_config('request.jwt.claims', '', true);
  FOR s IN SELECT id FROM sucursales WHERE activa LOOP
    v_r := reporte_ventas_por_cliente(DATE '2000-01-01', v_hoy, NULL, s.id);
    SELECT COUNT(*), COALESCE(SUM(total), 0) INTO v_n, v_monto
      FROM pedidos
     WHERE estado = 'entregado' AND canal <> 'cambio' AND tipo_factura IS DISTINCT FROM 'VB'
       AND fecha BETWEEN DATE '2000-01-01' AND v_hoy AND sucursal_id = s.id;
    IF (v_r -> 'totales' ->> 'pedidos')::bigint <> v_n OR (v_r -> 'totales' ->> 'total')::numeric <> v_monto THEN
      RAISE EXCEPTION 'ensayo 326: reporte_ventas_por_cliente de la sucursal % da % pedidos / $%, la definición canónica % / $%',
        s.id, v_r -> 'totales' ->> 'pedidos', v_r -> 'totales' ->> 'total', v_n, v_monto;
    END IF;
  END LOOP;

  -- 3b. Con un canje en prod: antes y después de las dos RPCs reemplazadas.
  FOR v_canje IN
    SELECT pe.id, pe.cliente_id, pe.sucursal_id, pe.usuario_id FROM pedidos pe
     WHERE pe.id = (v_antes ->> 'canje_id')::bigint
  LOOP
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_antes ->> 'admin')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_canje.sucursal_id::text)::text, true);

    -- Resumen de cuenta: el canje sale de total_pedidos y lo demás cierra con
    -- la consulta directa; el saldo (lo único que lee el front) no se mueve.
    v_j := obtener_resumen_cuenta_cliente(v_canje.cliente_id::int)::jsonb;
    SELECT COUNT(*) INTO v_n FROM pedidos
     WHERE cliente_id = v_canje.cliente_id AND canal = 'cambio' AND tipo_factura IS DISTINCT FROM 'VB';
    IF (v_j ->> 'total_pedidos')::bigint <> (v_antes -> 'cuenta' ->> 'total_pedidos')::bigint - v_n THEN
      RAISE EXCEPTION 'ensayo 326: total_pedidos del cliente % pasó de % a %, esperaba restar % canjes',
        v_canje.cliente_id, v_antes -> 'cuenta' ->> 'total_pedidos', v_j ->> 'total_pedidos', v_n;
    END IF;
    IF (v_j ->> 'saldo_actual')::numeric <> (v_antes -> 'cuenta' ->> 'saldo_actual')::numeric
       OR (v_j ->> 'total_compras')::numeric <> (v_antes -> 'cuenta' ->> 'total_compras')::numeric THEN
      RAISE EXCEPTION 'ensayo 326: el saldo o las compras del cliente % cambiaron por sacar canjes de $0', v_canje.cliente_id;
    END IF;
    SELECT COUNT(*) INTO v_n FROM pedidos
     WHERE cliente_id = v_canje.cliente_id AND canal <> 'cambio' AND estado_pago != 'pagado';
    SELECT MAX(created_at) INTO v_ult FROM pedidos
     WHERE cliente_id = v_canje.cliente_id AND canal <> 'cambio' AND tipo_factura IS DISTINCT FROM 'VB';
    IF (v_j ->> 'pedidos_pendientes_pago')::bigint <> v_n
       OR (v_j ->> 'ultimo_pedido')::timestamptz IS DISTINCT FROM v_ult THEN
      RAISE EXCEPTION 'ensayo 326: pendientes de pago o último pedido del cliente % no cierran sin canjes', v_canje.cliente_id;
    END IF;

    -- Estadísticas: los conteos operativos no cambian; total_ventas no cambia
    -- (el canje es $0) y el ticket es el de la venta canónica, sin el canje.
    v_j := obtener_estadisticas_pedidos(NULL, NULL, NULL);
    IF (v_j - 'total_ventas' - 'promedio_ticket') <> ((v_antes -> 'stats') - 'total_ventas' - 'promedio_ticket') THEN
      RAISE EXCEPTION 'ensayo 326: cambiaron los conteos operativos de las estadísticas: antes %, después %',
        v_antes -> 'stats', v_j;
    END IF;
    SELECT COALESCE(SUM(total), 0)::numeric(12,2), COALESCE(AVG(total), 0)::numeric(12,2) INTO v_monto, v_avg
      FROM pedidos
     WHERE sucursal_id = v_canje.sucursal_id
       AND estado = 'entregado' AND canal <> 'cambio' AND tipo_factura IS DISTINCT FROM 'VB';
    IF (v_j ->> 'total_ventas')::numeric <> v_monto OR (v_j ->> 'promedio_ticket')::numeric <> v_avg
       OR (v_j ->> 'total_ventas')::numeric <> (v_antes -> 'stats' ->> 'total_ventas')::numeric THEN
      RAISE EXCEPTION 'ensayo 326: venta de las estadísticas % / ticket %, la canónica % / %',
        v_j ->> 'total_ventas', v_j ->> 'promedio_ticket', v_monto, v_avg;
    END IF;
    -- Con el vendedor del canje el ticket tiene que subir (o quedar igual por redondeo).
    v_j := obtener_estadisticas_pedidos(NULL, NULL, v_canje.usuario_id);
    IF (v_j ->> 'promedio_ticket')::numeric < (v_antes -> 'stats_prev' ->> 'promedio_ticket')::numeric THEN
      RAISE EXCEPTION 'ensayo 326: el ticket del vendedor % bajó al sacar el canje', v_canje.usuario_id;
    END IF;

    RAISE NOTICE 'ensayo 326: cliente % total_pedidos % -> %; ticket sucursal % % -> %; ticket vendedor % -> %',
      v_canje.cliente_id,
      v_antes -> 'cuenta' ->> 'total_pedidos', (obtener_resumen_cuenta_cliente(v_canje.cliente_id::int)::jsonb ->> 'total_pedidos'),
      v_canje.sucursal_id, v_antes -> 'stats' ->> 'promedio_ticket', v_avg,
      v_antes -> 'stats_prev' ->> 'promedio_ticket', v_j ->> 'promedio_ticket';
  END LOOP;
  IF v_antes IS NULL OR v_antes = '{}'::jsonb THEN
    RAISE NOTICE 'ensayo 326: prod no tiene canjes entregados; sólo se verificó la venta canónica del reporte';
  END IF;

  PERFORM set_config('request.jwt.claims', COALESCE(v_claims_prev, ''), true);
  PERFORM set_config('request.headers', COALESCE(v_headers_prev, ''), true);

  RAISE NOTICE 'ensayo 326: canjes fuera del resumen de cuenta y del ticket; reporte_ventas_por_cliente canónico OK';
END;
$ensayo$;

COMMIT;
