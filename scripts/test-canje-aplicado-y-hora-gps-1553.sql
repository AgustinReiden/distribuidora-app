-- Ensayo de #1553 (mig 510_canje_aplicado_no_se_cancela_y_hora_del_gps): un canje ya
-- aplicado no se cancela (RUT-3) y la hora de captura del GPS tiene piso y techo (VAR-01).
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en una excepción
-- (`ENSAYO OK …` o `ENSAYO FALLO …`). Sin la migración falla en C0.
--
-- Arma su contexto adentro de la transacción: dos comandas de canje nuevas de un admin,
-- con un cliente activo y dos productos con stock de su sucursal.
--
--   C0 · `_gps_hora_de_captura` existe, sin EXECUTE para anon ni authenticated.
--   C1 · Un canje SIN aplicar se cancela como antes.
--   C2 · Un canje aplicado no se cancela: `success` false con el motivo, la comanda
--        sigue viva y el stock queda como lo dejó el cambio (no se toca de nuevo).
--   H1 · La regla: nula, +10 minutos y −61 días dan la hora del servidor; +2 minutos
--        y −59 días se conservan.
--   H2 · Por las RPC: un GPS de pedido con hora de 2099 queda con la del servidor, y
--        uno de hace 2 horas la conserva; una visita con hora de 1990 queda con la
--        del servidor.

DO $ensayo$
DECLARE
  v_suc   bigint;
  v_adm   uuid;
  v_cli   bigint;
  v_dev   bigint;
  v_ent   bigint;
  v_c1    bigint;
  v_c2    bigint;
  v_r     jsonb;
  v_antes record;
  v_desp  record;
  v_fin   record;
  v_ts    timestamptz;
  v_estado text;
  v_fallas text[] := '{}';
  F_HORA CONSTANT text := 'public._gps_hora_de_captura(timestamp with time zone)';
BEGIN
 BEGIN
  -- ------------------------------------------------------------------- C0 ---
  IF to_regprocedure(F_HORA) IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA',
      MESSAGE = 'ENSAYO FALLO · C0: no existe _gps_hora_de_captura (falta la migración)';
  END IF;
  IF has_function_privilege('anon', F_HORA, 'EXECUTE') OR has_function_privilege('authenticated', F_HORA, 'EXECUTE') THEN
    v_fallas := v_fallas || 'C0 · _gps_hora_de_captura quedó ejecutable por anon o authenticated'::text;
  END IF;

  -- ------------------------------------------------------------- contexto ---
  SELECT s.id, a.id INTO v_suc, v_adm
    FROM sucursales s
    JOIN LATERAL (SELECT pf.id FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'admin'
                   ORDER BY pf.id LIMIT 1) a ON true
   WHERE s.activa
     AND (SELECT count(*) FROM productos p WHERE p.sucursal_id = s.id AND p.activo AND p.stock >= 10) >= 2
     AND EXISTS (SELECT 1 FROM clientes c WHERE c.sucursal_id = s.id AND c.activo)
   ORDER BY s.id LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA',
      MESSAGE = 'ENSAYO FALLO · sin contexto: no hay una sucursal activa con un admin, un cliente y dos productos con stock';
  END IF;
  SELECT id INTO v_cli FROM clientes WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;
  SELECT id INTO v_dev FROM productos WHERE sucursal_id = v_suc AND activo AND stock >= 10 ORDER BY id DESC LIMIT 1;
  SELECT id INTO v_ent FROM productos WHERE sucursal_id = v_suc AND activo AND stock >= 10 AND id <> v_dev ORDER BY id DESC LIMIT 1;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);

  SET LOCAL ROLE authenticated;
  v_c1 := public.crear_pedido_cambio_en_ruta(v_cli::int, v_dev, 2, v_ent, 2, 'ensayo 1553 sin aplicar', 'erroneo');
  v_c2 := public.crear_pedido_cambio_en_ruta(v_cli::int, v_dev, 3, v_ent, 3, 'ensayo 1553 aplicado', 'erroneo');
  RESET ROLE;

  -- ------------------------------------------------------------------- H2 ---
  -- Antes de cancelar nada: las dos comandas sirven de pedido para el GPS (el admin
  -- registra el de cualquier pedido de su sucursal).
  SET LOCAL ROLE authenticated;
  v_r := public.registrar_geolocalizacion_pedido(p_pedido_id => v_c1, p_status => 'ok', p_lat => -26.8, p_lng => -65.2,
                                                 p_accuracy => 10, p_capturado_at => TIMESTAMPTZ '2099-01-01 12:00+00');
  RESET ROLE;
  SELECT gps_capturado_at INTO v_ts FROM pedidos WHERE id = v_c1;
  IF NOT COALESCE((v_r->>'success')::boolean, false) OR v_ts IS DISTINCT FROM now() THEN
    v_fallas := v_fallas || format('H2 · un GPS con hora de 2099 quedó con %s (se esperaba la del servidor): %s', v_ts, v_r)::text;
  END IF;
  SET LOCAL ROLE authenticated;
  v_r := public.registrar_geolocalizacion_pedido(p_pedido_id => v_c2, p_status => 'ok', p_lat => -26.8, p_lng => -65.2,
                                                 p_accuracy => 10, p_capturado_at => now() - interval '2 hours');
  RESET ROLE;
  SELECT gps_capturado_at INTO v_ts FROM pedidos WHERE id = v_c2;
  IF NOT COALESCE((v_r->>'success')::boolean, false) OR v_ts IS DISTINCT FROM now() - interval '2 hours' THEN
    v_fallas := v_fallas || format('H2 · un GPS de hace 2 horas no conservó su hora: %s / %s', v_ts, v_r)::text;
  END IF;
  SET LOCAL ROLE authenticated;
  v_r := public.registrar_visita_cliente(p_cliente_id => v_cli, p_status => 'ok', p_lat => -26.8, p_lng => -65.2,
                                         p_accuracy => 10, p_capturado_at => TIMESTAMPTZ '1990-01-01 12:00+00');
  RESET ROLE;
  SELECT gps_capturado_at INTO v_ts FROM visitas_cliente WHERE id = (v_r->>'visita_id')::bigint;
  IF NOT COALESCE((v_r->>'success')::boolean, false) OR v_ts IS DISTINCT FROM now() THEN
    v_fallas := v_fallas || format('H2 · una visita con hora de 1990 quedó con %s (se esperaba la del servidor): %s', v_ts, v_r)::text;
  END IF;

  -- ------------------------------------------------------------------- H1 ---
  IF public._gps_hora_de_captura(NULL) IS DISTINCT FROM now()
     OR public._gps_hora_de_captura(now() + interval '10 minutes') IS DISTINCT FROM now()
     OR public._gps_hora_de_captura(now() - interval '61 days') IS DISTINCT FROM now() THEN
    v_fallas := v_fallas || 'H1 · una hora nula, +10 minutos o −61 días no dio la del servidor'::text;
  END IF;
  IF public._gps_hora_de_captura(now() + interval '2 minutes') IS DISTINCT FROM now() + interval '2 minutes'
     OR public._gps_hora_de_captura(now() - interval '59 days') IS DISTINCT FROM now() - interval '59 days' THEN
    v_fallas := v_fallas || 'H1 · una hora creíble (+2 minutos, −59 días) no se conservó'::text;
  END IF;

  -- ------------------------------------------------------------------- C1 ---
  SET LOCAL ROLE authenticated;
  v_r := public.cancelar_pedido_con_stock(v_c1, 'ensayo 1553', NULL, NULL);
  RESET ROLE;
  SELECT estado INTO v_estado FROM pedidos WHERE id = v_c1;
  IF NOT COALESCE((v_r->>'success')::boolean, false) OR v_estado IS DISTINCT FROM 'cancelado' THEN
    v_fallas := v_fallas || format('C1 · un canje sin aplicar no se pudo cancelar: %s (estado %s)', v_r, v_estado)::text;
  END IF;

  -- ------------------------------------------------------------------- C2 ---
  SELECT (SELECT stock FROM productos WHERE id = v_dev) AS dev, (SELECT stock FROM productos WHERE id = v_ent) AS ent INTO v_antes;
  SET LOCAL ROLE authenticated;
  PERFORM public.aplicar_cambio_de_parada(v_c2, NULL, NULL);
  RESET ROLE;
  SELECT (SELECT stock FROM productos WHERE id = v_dev) AS dev, (SELECT stock FROM productos WHERE id = v_ent) AS ent INTO v_desp;
  IF v_desp.dev IS NOT DISTINCT FROM v_antes.dev AND v_desp.ent IS NOT DISTINCT FROM v_antes.ent THEN
    v_fallas := v_fallas || format('C2 · el cambio no movió el stock (%s/%s): el caso no prueba nada', v_desp.dev, v_desp.ent)::text;
  END IF;
  SET LOCAL ROLE authenticated;
  v_r := public.cancelar_pedido_con_stock(v_c2, 'ensayo 1553', NULL, NULL);
  RESET ROLE;
  SELECT estado INTO v_estado FROM pedidos WHERE id = v_c2;
  SELECT (SELECT stock FROM productos WHERE id = v_dev) AS dev, (SELECT stock FROM productos WHERE id = v_ent) AS ent INTO v_fin;
  IF COALESCE((v_r->>'success')::boolean, true) OR v_r->>'error' !~ 'ya se aplicó' THEN
    v_fallas := v_fallas || format('C2 · cancelar un canje aplicado no se rechazó con su motivo: %s', v_r)::text;
  END IF;
  IF v_estado = 'cancelado' THEN
    v_fallas := v_fallas || 'C2 · la comanda del canje aplicado quedó cancelada'::text;
  END IF;
  IF v_fin.dev IS DISTINCT FROM v_desp.dev OR v_fin.ent IS DISTINCT FROM v_desp.ent THEN
    v_fallas := v_fallas || format('C2 · el intento de cancelar movió el stock: %s/%s → %s/%s', v_desp.dev, v_desp.ent, v_fin.dev, v_fin.ent)::text;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA',
      MESSAGE = 'ENSAYO FALLO · ' || array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION USING ERRCODE = 'ZZ0OK',
    MESSAGE = format('ENSAYO OK · C0–C2, H1–H2 (sucursal %s, canjes %s y %s; stock %s/%s → %s/%s tras el cambio, igual tras el rechazo)',
                     v_suc, v_c1, v_c2, v_antes.dev, v_antes.ent, v_desp.dev, v_desp.ent);
 END;
END
$ensayo$;
