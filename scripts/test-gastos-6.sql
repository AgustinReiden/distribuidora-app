-- Ensayo de la migracion gastos_6_faltantes_rendicion (entrega 6 de gastos:
-- faltantes de rendicion).
--
-- Corre contra prod SIN dejar rastro: un unico DO que termina SIEMPRE en RAISE
-- EXCEPTION, asi que todo lo que escribe se deshace.
--
--   'ENSAYO OK …'    -> todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' -> lista de lo que no se cumplio.
--
-- Antes de la migracion tiene que FALLAR; despues, pasar:
--
--   BEGIN; SET LOCAL lock_timeout = '5s';
--   <migrations/NNN_gastos_6_faltantes_rendicion.sql>
--   <este archivo>
--   ROLLBACK;
--
-- Las RPCs se llaman COMO EL FRONT (pg_temp.como). Los pedidos y los cobros que
-- dan el efectivo de cada rendicion se arman como postgres sobre las tablas.
--
-- a1 es un admin real de Tucuman (con su ficha de empleado, si la tiene), y ad
-- uno de las dos. El encargado y los choferes los crea el ensayo en auth.users.
-- Las rendiciones son de Tucuman, que todavia no controla rendiciones, en los
-- dias de hace 2 a 7.
--
--   R3  (hoy-2) sólo texto                     casos 3 y 13e
--   R4  (hoy-3) una línea de cada causal       casos 2, 4-6, 8-12 y 14
--   R7  (hoy-4) varias líneas y el tope        casos 7 y 13
--   R16 (hoy-5) el bundle viejo                caso 16
--   R15 (hoy-6) pendiente sin nada             caso 15
--   RC  (hoy-7) confirmada                     caso 8
--   T3  (hoy-3) de otro chofer                 caso 17
--
--   1  guarda           8  validaciones        15 nada para deshacer
--   2  quién            9  lo visto            16 bundle viejo
--   3  sólo texto       10 personal            17 lecturas
--   4  deuda            11 la guarda de gastos 18 lo de antes sigue igual
--   5  robo o pérdida   12 editar cierre       19 permisos
--   6  gasto no cargado 13 deshacer            20 invariantes
--   7  varias y tope    14 reabierta sola

DO $ensayo$
DECLARE
  v_fallas text[] := '{}';
  v_hoy    date := public._tablero_hoy();
  v_l      date := date_trunc('week', public._tablero_hoy()::timestamp)::date - 28;
  v_t      bigint := 1;
  v_tp     bigint := 2;
  d3       date := public._tablero_hoy() - 2;
  d4       date := public._tablero_hoy() - 3;
  d7       date := public._tablero_hoy() - 4;
  d16      date := public._tablero_hoy() - 5;
  d15      date := public._tablero_hoy() - 6;
  dc       date := public._tablero_hoy() - 7;
  v_a1     uuid;
  v_ad     uuid;
  v_en     uuid;
  v_tr     uuid;
  v_tr2    uuid;
  v_tr3    uuid;
  c1       bigint;
  v_prod   bigint;
  v_ped    bigint;
  v_peaje  bigint;
  v_rubro  bigint;
  e1       bigint;
  e2       bigint;
  e_baja   bigint;
  e_tp     bigint;
  e_a1     bigint;
  g_r4     bigint;
  g_r7     bigint;
  g_robo   bigint;
  g_nc     bigint;
  v_mov    bigint;
  v_rc     bigint;
  v_n      bigint;
  v_m      numeric;
  v_m2     numeric;
  v_s0     numeric;
  v_j      jsonb;
  v_k      jsonb;
  v_res    jsonb;
  v_txt    text;
  v_hu     text;
  v_nom    text;
  v_ch_ini int;
  v_ch_fin int;
  g        record;
BEGIN
  SET LOCAL lock_timeout = '5s';

  IF to_regclass('public.rendicion_faltantes') IS NULL
     OR to_regprocedure('public.deshacer_resolucion_rendicion(date,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · no existen rendicion_faltantes ni deshacer_resolucion_rendicion (falta la migracion gastos_6)';
  END IF;

  -- --------------------------------------------------------- contexto ---
  SELECT pf.id INTO v_a1 FROM perfiles pf WHERE pf.rol = 'admin' AND pf.activo
     AND (SELECT array_agg(us.sucursal_id ORDER BY us.sucursal_id) FROM usuario_sucursales us WHERE us.usuario_id = pf.id) = ARRAY[v_t]
   ORDER BY pf.id LIMIT 1;
  SELECT pf.id INTO v_ad FROM perfiles pf WHERE pf.rol = 'admin' AND pf.activo
     AND (SELECT array_agg(us.sucursal_id ORDER BY us.sucursal_id) FROM usuario_sucursales us WHERE us.usuario_id = pf.id) = ARRAY[v_t, v_tp]
   ORDER BY pf.id LIMIT 1;
  SELECT id INTO v_peaje FROM gasto_rubros WHERE lower(btrim(nombre)) = 'peajes y estacionamiento' AND activo;
  SELECT id INTO v_rubro FROM gasto_rubros WHERE lower(btrim(nombre)) = 'faltantes de caja' AND activo;
  IF v_a1 IS NULL OR v_ad IS NULL OR v_peaje IS NULL OR v_rubro IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin contexto: a1 %, ad %, rubro peajes %, rubro faltantes %', v_a1, v_ad, v_peaje, v_rubro;
  END IF;

  CREATE FUNCTION pg_temp.como(p_user uuid, p_suc bigint, p_sql text)
  RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE
    v text;
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
    SET LOCAL ROLE authenticated;
    EXECUTE p_sql INTO v;
    RESET ROLE;
    RETURN v;
  END
  $f$;

  CREATE FUNCTION pg_temp.falla(p_que text, p_user uuid, p_suc bigint, p_sql text, p_espera text)
  RETURNS text[] LANGUAGE plpgsql AS $f$
  BEGIN
    BEGIN
      PERFORM pg_temp.como(p_user, p_suc, p_sql);
    EXCEPTION WHEN SQLSTATE 'P0098' THEN RAISE;
      WHEN OTHERS THEN
        IF position(p_espera IN SQLERRM) > 0 THEN
          RETURN '{}';
        END IF;
        RETURN ARRAY[format('%s: fallo con otro mensaje: %s (esperado: %s)', p_que, SQLERRM, p_espera)];
    END;
    RAISE EXCEPTION USING ERRCODE = 'P0098';
  EXCEPTION WHEN SQLSTATE 'P0098' THEN
    RETURN ARRAY[format('%s: anduvo y tenia que fallar', p_que)];
  END
  $f$;

  CREATE FUNCTION pg_temp.estado(p_user uuid, p_suc bigint, p_sql text)
  RETURNS text LANGUAGE plpgsql AS $f$
  BEGIN
    BEGIN
      PERFORM pg_temp.como(p_user, p_suc, p_sql);
    EXCEPTION WHEN OTHERS THEN
      RETURN SQLSTATE;
    END;
    RAISE EXCEPTION USING ERRCODE = 'P0098';
  EXCEPTION WHEN SQLSTATE 'P0098' THEN
    RETURN 'OK';
  END
  $f$;

  CREATE FUNCTION pg_temp.chk(p_ok boolean, p_que text)
  RETURNS text[] LANGUAGE sql AS $f$
    SELECT CASE WHEN p_ok IS TRUE THEN '{}'::text[] ELSE ARRAY[p_que] END;
  $f$;

  -- Lo que corre como postgres, con los claims de un usuario.
  CREATE FUNCTION pg_temp.claims(p_user uuid, p_suc bigint)
  RETURNS void LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
    SELECT set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
  $f$;

  CREATE FUNCTION pg_temp.adm()
  RETURNS void LANGUAGE sql AS $f$
    SELECT pg_temp.claims(current_setting('g6.a1')::uuid, 1);
  $f$;

  CREATE FUNCTION pg_temp.u(p_rol text, p_suc bigint)
  RETURNS uuid LANGUAGE plpgsql AS $f$
  DECLARE
    v uuid := gen_random_uuid();
  BEGIN
    INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'g6-' || v || '@ensayo.invalid',
            jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), '{}', now(), now());
    RETURN v;
  END
  $f$;

  CREATE FUNCTION pg_temp.alta(p_adm uuid, p_suc bigint, p_usr uuid, p_desde date)
  RETURNS bigint LANGUAGE sql AS $f$
    SELECT pg_temp.como(p_adm, p_suc, format('SELECT public.guardar_empleado(p_empleado => %L::jsonb)', jsonb_build_object(
      'nombre', 'ZZ g6 ' || gen_random_uuid(), 'puesto', 'preventista', 'sucursal_id', p_suc, 'de_las_dos', false,
      'cuil', NULL, 'fecha_ingreso', NULL, 'telefono', NULL, 'usuario_id', p_usr, 'cliente_id', NULL, 'vehiculo_id', NULL,
      'arreglo', jsonb_build_object('vigente_desde', p_desde, 'sueldo', 70000, 'frecuencia', 'semanal', 'comisiona', false),
      'saldo_inicial', NULL)))::bigint;
  $f$;

  -- Un cobro en efectivo del chofer, ese dia, sobre el pedido del ensayo.
  CREATE FUNCTION pg_temp.cobro(p_t uuid, p_d date, p_monto numeric)
  RETURNS void LANGUAGE sql AS $f$
    SELECT pg_temp.adm();
    INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id)
    VALUES (current_setting('g6.c1')::bigint, current_setting('g6.ped')::bigint, p_monto, 'efectivo', p_d, p_t, 1);
  $f$;

  CREATE FUNCTION pg_temp.gg(p jsonb)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.guardar_gasto(p_gasto => %L::jsonb)', p);
  $f$;

  CREATE FUNCTION pg_temp.ag(p_id bigint, p_motivo text)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.anular_gasto(p_gasto_id => %s, p_motivo => %L)', p_id, p_motivo);
  $f$;

  -- Un gasto de la rendicion (dia y chofer), como el ModalGasto del cierre.
  CREATE FUNCTION pg_temp.gp(p_d date, p_monto numeric, p_obs text DEFAULT 'peaje ruta 9')
  RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('fecha', p_d, 'rubro_id', current_setting('g6.peaje')::bigint, 'monto_total', p_monto,
                              'comprobante', 'ninguno', 'comprobante_numero', NULL, 'vehiculo_id', NULL,
                              'compartido', false, 'observacion', p_obs);
  $f$;

  CREATE FUNCTION pg_temp.plata(p_t uuid, p_d date)
  RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('origen_pago', 'rendicion', 'rendicion_transportista_id', p_t, 'rendicion_fecha', p_d);
  $f$;

  -- Lo que vio el modal: los gastos vivos de la rendicion, (id, updated_at).
  CREATE FUNCTION pg_temp.vis(p_d date, p_t uuid)
  RETURNS jsonb LANGUAGE sql AS $f$
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', g.id, 'updated_at', g.updated_at) ORDER BY g.id), '[]'::jsonb)
      FROM gastos g
     WHERE g.origen_pago = 'rendicion' AND g.sucursal_id = 1 AND g.rendicion_transportista_id = p_t
       AND g.rendicion_fecha = p_d AND g.anulado_at IS NULL;
  $f$;

  -- La resolucion que manda el modal: las lineas y lo visto ahora.
  CREATE FUNCTION pg_temp.rs(p_d date, p_t uuid, p_lineas jsonb, p_pp numeric DEFAULT 0)
  RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('lineas', p_lineas, 'vistos', pg_temp.vis(p_d, p_t), 'pagos_personal_visto', p_pp);
  $f$;

  CREATE FUNCTION pg_temp.le(p_e bigint, p_monto numeric, p_obs text DEFAULT NULL)
  RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('causal', 'empleado', 'monto', p_monto, 'empleado_id', p_e, 'observacion', p_obs);
  $f$;

  CREATE FUNCTION pg_temp.lr(p_monto numeric, p_obs text DEFAULT NULL)
  RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('causal', 'robo_perdida', 'monto', p_monto, 'observacion', p_obs);
  $f$;

  CREATE FUNCTION pg_temp.lg(p_monto numeric, p_gasto jsonb)
  RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('causal', 'gasto_no_cargado', 'monto', p_monto, 'gasto', p_gasto);
  $f$;

  -- resolver_rendicion como useRendiciones: por nombre. Sin resolucion, con
  -- tres argumentos, como el bundle de hoy.
  CREATE FUNCTION pg_temp.rr(p_d date, p_t uuid, p_res jsonb, p_obs text DEFAULT 'ensayo gastos 6')
  RETURNS text LANGUAGE sql AS $f$
    SELECT CASE WHEN p_res IS NULL
      THEN format('SELECT public.resolver_rendicion(p_fecha => %L::date, p_transportista_id => %L::uuid, p_observaciones => %L)',
                  p_d, p_t, p_obs)
      ELSE format('SELECT public.resolver_rendicion(p_fecha => %L::date, p_transportista_id => %L::uuid, p_observaciones => %L, '
                  || 'p_resolucion => %L::jsonb)', p_d, p_t, p_obs, p_res) END;
  $f$;

  CREATE FUNCTION pg_temp.dz(p_d date, p_t uuid, p_motivo text)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.deshacer_resolucion_rendicion(p_fecha => %L::date, p_transportista_id => %L::uuid, p_motivo => %L)',
                  p_d, p_t, p_motivo);
  $f$;

  CREATE FUNCTION pg_temp.cr(p_d date, p_t uuid, p_estado text, p_cambios jsonb)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.confirmar_rendicion(p_fecha => %L::date, p_transportista_id => %L::uuid, '
                  || 'p_estado => %L, p_observaciones => NULL, p_gastos_rendicion => %L::jsonb)', p_d, p_t, p_estado, p_cambios);
  $f$;

  CREATE FUNCTION pg_temp.mov(p_emp bigint, p jsonb)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.registrar_movimiento_empleado(p_empleado_id => %s, p_movimiento => %L::jsonb)', p_emp, p);
  $f$;

  CREATE FUNCTION pg_temp.rev(p_mov bigint)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.revertir_movimiento_empleado(p_movimiento_id => %s, p_motivo => %L)', p_mov, 'Ensayo');
  $f$;

  CREATE FUNCTION pg_temp.pv(p_emp bigint)
  RETURNS jsonb LANGUAGE sql AS $f$
    SELECT pg_temp.como(current_setting('g6.a1')::uuid, 1,
                        format('SELECT public.previsualizar_liquidacion(p_empleado_id => %s)', p_emp))::jsonb;
  $f$;

  -- Liquida el proximo periodo, sin pagar nada, como ModalLiquidar.
  CREATE FUNCTION pg_temp.lq(p_emp bigint)
  RETURNS bigint LANGUAGE sql AS $f$
    SELECT pg_temp.como(current_setting('g6.a1')::uuid, 1, format(
      'SELECT public.liquidar_empleado(p_empleado_id => %s, p_liquidacion => %L::jsonb)', p_emp,
      jsonb_build_object('desde', v#>>'{periodo,desde}', 'hasta', v#>>'{periodo,hasta}',
                         'sueldo', (v#>>'{sueldo,propuesto}')::numeric, 'motivo_sueldo', NULL, 'pago', 0,
                         'fecha_pago', public._tablero_hoy(), 'a_pagar_esperado', (v->>'a_pagar')::numeric,
                         'origen_pago', 'oficina', 'rendicion_transportista_id', NULL, 'rendicion_fecha', NULL)))::bigint
      FROM (SELECT pg_temp.pv(p_emp) AS v) x;
  $f$;

  CREATE FUNCTION pg_temp.saldo(p_emp bigint)
  RETURNS numeric LANGUAGE sql AS $f$
    SELECT COALESCE(sum(monto), 0) FROM public.empleado_movimientos WHERE empleado_id = p_emp;
  $f$;

  CREATE FUNCTION pg_temp.res(p_user uuid, p_suc bigint, p_d date, p_t uuid)
  RETURNS jsonb LANGUAGE sql AS $f$
    SELECT pg_temp.como(p_user, p_suc, format(
      'SELECT COALESCE(jsonb_agg(to_jsonb(r)), ''[]'') FROM public.obtener_resumen_rendiciones(p_fecha_desde => %L::date, p_fecha_hasta => %L::date, p_transportista_id => %s) r',
      p_d, p_d, COALESCE(quote_literal(p_t::text) || '::uuid', 'NULL')))::jsonb;
  $f$;

  -- La fila de la rendicion en el resumen, vista por a1.
  CREATE FUNCTION pg_temp.fila(p_d date, p_t uuid)
  RETURNS jsonb LANGUAGE sql AS $f$
    SELECT pg_temp.res(current_setting('g6.a1')::uuid, 1, p_d, p_t)->0;
  $f$;

  CREATE FUNCTION pg_temp.ctl(p_d date, p_t uuid)
  RETURNS text LANGUAGE sql AS $f$
    SELECT estado FROM rendiciones_control WHERE fecha = p_d AND transportista_id = p_t AND sucursal_id = 1;
  $f$;

  CREATE FUNCTION pg_temp.vivas(p_d date, p_t uuid)
  RETURNS bigint LANGUAGE sql AS $f$
    SELECT count(*) FROM rendicion_faltantes
     WHERE rendicion_fecha = p_d AND rendicion_transportista_id = p_t AND rendicion_sucursal_id = 1 AND anulada_at IS NULL;
  $f$;

  -- Todo lo que una resolucion escribe de una rendicion: si una rechazada lo
  -- cambia, quedo algo escrito.
  CREATE FUNCTION pg_temp.huella(p_d date, p_t uuid)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('lineas %s, anuladas %s, movimientos %s, gastos %s (anulados %s), control %s %s',
      (SELECT count(*) FROM rendicion_faltantes WHERE rendicion_fecha = p_d AND rendicion_transportista_id = p_t),
      (SELECT count(*) FROM rendicion_faltantes WHERE rendicion_fecha = p_d AND rendicion_transportista_id = p_t AND anulada_at IS NOT NULL),
      (SELECT count(*) FROM empleado_movimientos WHERE rendicion_fecha = p_d AND rendicion_transportista_id = p_t),
      (SELECT count(*) FROM gastos WHERE rendicion_fecha = p_d AND rendicion_transportista_id = p_t),
      (SELECT count(*) FROM gastos WHERE rendicion_fecha = p_d AND rendicion_transportista_id = p_t AND anulado_at IS NOT NULL),
      (SELECT estado || ' ' || md5(COALESCE(observaciones, '')) FROM rendiciones_control
        WHERE fecha = p_d AND transportista_id = p_t AND sucursal_id = 1),
      (SELECT max(updated_at)::text FROM gastos WHERE rendicion_fecha = p_d AND rendicion_transportista_id = p_t));
  $f$;

  CREATE FUNCTION pg_temp.audit(p_adm uuid, p_suc bigint)
  RETURNS jsonb LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.claims(p_adm, p_suc);
    RETURN public.auditoria_integridad();
  END
  $f$;

  CREATE FUNCTION pg_temp.gasto_a()
  RETURNS int LANGUAGE sql AS $f$
    SELECT (c->>'violaciones')::int FROM jsonb_array_elements(pg_temp.audit(current_setting('g6.a1')::uuid, 1)->'checks') c
     WHERE c->>'id' = 'GASTO-A';
  $f$;

  -- obtener_resumen_rendiciones de la 437, tal cual (sin SECURITY DEFINER: corre
  -- como postgres con los claims puestos). El caso 18 compara contra esta.
  CREATE FUNCTION pg_temp.resumen_437(p_fecha_desde date, p_fecha_hasta date, p_transportista_id uuid)
  RETURNS TABLE(fecha date, transportista_id uuid, transportista_nombre text, total_efectivo numeric,
                total_transferencia numeric, total_cheque numeric, total_cuenta_corriente numeric,
                total_tarjeta numeric, total_otros numeric, total_adelanto_sueldo numeric, total_general numeric,
                total_entregas numeric, total_ctascte numeric, cantidad_pedidos bigint, total_entregado numeric,
                total_gastos numeric, cantidad_gastos bigint, estado text, observaciones text, controlada boolean,
                controlada_at timestamptz, controlada_por_nombre text, resuelta_at timestamptz,
                resuelta_por_nombre text, total_pagos_personal numeric)
  LANGUAGE plpgsql SET search_path = public AS $f$
  DECLARE
    v_sucursal_id BIGINT;
  BEGIN
    v_sucursal_id := current_sucursal_id();
    IF NOT es_encargado_o_admin() THEN
      RAISE EXCEPTION 'resumen_437: sólo admin o encargado';
    END IF;
    RETURN QUERY
    WITH rp AS (
      SELECT x.*
        FROM public._rendicion_pagos(v_sucursal_id, p_fecha_desde, p_fecha_hasta) x
       WHERE x.t_id IS NOT NULL
         AND (p_transportista_id IS NULL OR x.t_id = p_transportista_id)
    ),
    pagos_agg AS (
      SELECT
        rp.t_id,
        rp.f,
        SUM(CASE WHEN rp.forma_pago = 'efectivo' THEN rp.monto ELSE 0 END)::numeric AS tot_ef,
        SUM(CASE WHEN rp.forma_pago = 'transferencia' THEN rp.monto ELSE 0 END)::numeric AS tot_tr,
        SUM(CASE WHEN rp.forma_pago = 'cheque' THEN rp.monto ELSE 0 END)::numeric AS tot_ch,
        SUM(CASE WHEN rp.forma_pago = 'cuenta_corriente' THEN rp.monto ELSE 0 END)::numeric AS tot_cc,
        SUM(CASE WHEN rp.forma_pago = 'tarjeta' THEN rp.monto ELSE 0 END)::numeric AS tot_tj,
        SUM(CASE WHEN rp.forma_pago NOT IN ('efectivo','transferencia','cheque','cuenta_corriente','tarjeta')
                  OR rp.forma_pago IS NULL THEN rp.monto ELSE 0 END)::numeric AS tot_ot,
        SUM(rp.monto)::numeric AS tot_gen,
        SUM(CASE WHEN rp.es_entrega_del_dia THEN rp.monto ELSE 0 END)::numeric AS tot_entregas,
        SUM(CASE WHEN rp.es_entrega_del_dia THEN 0 ELSE rp.monto END)::numeric AS tot_ctascte
      FROM rp
      WHERE COALESCE(rp.forma_pago, '') <> 'adelanto_sueldo'
      GROUP BY rp.t_id, rp.f
    ),
    adelantos_agg AS (
      SELECT rp.t_id, rp.f, SUM(rp.monto)::numeric AS tot_adel
        FROM rp
       WHERE rp.forma_pago = 'adelanto_sueldo'
       GROUP BY rp.t_id, rp.f
    ),
    entregas_agg AS (
      SELECT e.t_id, e.f, e.tot_entregado, e.cant
        FROM public._rendicion_entregas(v_sucursal_id, p_fecha_desde, p_fecha_hasta) e
       WHERE (p_transportista_id IS NULL OR e.t_id = p_transportista_id)
    ),
    gastos_agg AS (
      SELECT g.rendicion_transportista_id AS t_id, g.rendicion_fecha AS f,
             SUM(g.monto_total)::numeric AS tot_g, COUNT(*)::bigint AS cant_g
        FROM gastos g
       WHERE g.origen_pago = 'rendicion' AND g.anulado_at IS NULL
         AND g.sucursal_id = v_sucursal_id
         AND g.rendicion_fecha BETWEEN p_fecha_desde AND p_fecha_hasta
         AND (p_transportista_id IS NULL OR g.rendicion_transportista_id = p_transportista_id)
       GROUP BY 1, 2
    ),
    pagos_personal_agg AS (
      SELECT m.rendicion_transportista_id AS t_id, m.rendicion_fecha AS f,
             (-SUM(m.monto))::numeric AS tot_pp
        FROM empleado_movimientos m
       WHERE m.rendicion_sucursal_id = v_sucursal_id
         AND m.rendicion_fecha BETWEEN p_fecha_desde AND p_fecha_hasta
         AND (p_transportista_id IS NULL OR m.rendicion_transportista_id = p_transportista_id)
       GROUP BY 1, 2
      HAVING SUM(m.monto) <> 0
    ),
    cerradas AS (
      SELECT rc0.transportista_id AS t_id, rc0.fecha AS f
        FROM rendiciones_control rc0
       WHERE rc0.sucursal_id = v_sucursal_id
         AND rc0.estado IN ('confirmada', 'resuelta')
         AND rc0.fecha BETWEEN p_fecha_desde AND p_fecha_hasta
         AND (p_transportista_id IS NULL OR rc0.transportista_id = p_transportista_id)
    ),
    fechas_activas AS (
      SELECT pa.t_id, pa.f FROM pagos_agg pa
      UNION
      SELECT ea.t_id, ea.f FROM entregas_agg ea
      UNION
      SELECT ga.t_id, ga.f FROM gastos_agg ga
      UNION
      SELECT pp.t_id, pp.f FROM pagos_personal_agg pp
      UNION
      SELECT ce.t_id, ce.f FROM cerradas ce
    )
    SELECT
      fa.f::date AS fecha,
      fa.t_id AS transportista_id,
      tr.nombre::text AS transportista_nombre,
      COALESCE(pagos_agg.tot_ef, 0)::numeric AS total_efectivo,
      COALESCE(pagos_agg.tot_tr, 0)::numeric AS total_transferencia,
      COALESCE(pagos_agg.tot_ch, 0)::numeric AS total_cheque,
      COALESCE(pagos_agg.tot_cc, 0)::numeric AS total_cuenta_corriente,
      COALESCE(pagos_agg.tot_tj, 0)::numeric AS total_tarjeta,
      COALESCE(pagos_agg.tot_ot, 0)::numeric AS total_otros,
      COALESCE(adelantos_agg.tot_adel, 0)::numeric AS total_adelanto_sueldo,
      COALESCE(pagos_agg.tot_gen, 0)::numeric AS total_general,
      COALESCE(pagos_agg.tot_entregas, 0)::numeric AS total_entregas,
      COALESCE(pagos_agg.tot_ctascte, 0)::numeric AS total_ctascte,
      (CASE WHEN rc.estado IN ('confirmada', 'resuelta') AND rc.cantidad_pedidos_confirmada IS NOT NULL
            THEN rc.cantidad_pedidos_confirmada
            ELSE COALESCE(entregas_agg.cant, 0) END)::bigint AS cantidad_pedidos,
      (CASE WHEN rc.estado IN ('confirmada', 'resuelta') AND rc.total_entregado_confirmado IS NOT NULL
            THEN rc.total_entregado_confirmado
            ELSE COALESCE(entregas_agg.tot_entregado, 0) END)::numeric AS total_entregado,
      COALESCE(gastos_agg.tot_g, 0)::numeric AS total_gastos,
      COALESCE(gastos_agg.cant_g, 0)::bigint AS cantidad_gastos,
      COALESCE(rc.estado, 'pendiente')::text AS estado,
      rc.observaciones,
      (rc.id IS NOT NULL AND COALESCE(rc.estado, 'pendiente') IN ('confirmada','resuelta')) AS controlada,
      rc.controlada_at,
      cp.nombre::text AS controlada_por_nombre,
      rc.resuelta_at,
      rp2.nombre::text AS resuelta_por_nombre,
      COALESCE(pagos_personal_agg.tot_pp, 0)::numeric AS total_pagos_personal
    FROM fechas_activas fa
    JOIN perfiles tr ON tr.id = fa.t_id
    LEFT JOIN pagos_agg ON pagos_agg.t_id = fa.t_id AND pagos_agg.f = fa.f
    LEFT JOIN adelantos_agg ON adelantos_agg.t_id = fa.t_id AND adelantos_agg.f = fa.f
    LEFT JOIN entregas_agg ON entregas_agg.t_id = fa.t_id AND entregas_agg.f = fa.f
    LEFT JOIN gastos_agg ON gastos_agg.t_id = fa.t_id AND gastos_agg.f = fa.f
    LEFT JOIN pagos_personal_agg ON pagos_personal_agg.t_id = fa.t_id AND pagos_personal_agg.f = fa.f
    LEFT JOIN rendiciones_control rc
      ON rc.fecha = fa.f
     AND rc.transportista_id = fa.t_id
     AND rc.sucursal_id = v_sucursal_id
    LEFT JOIN perfiles cp ON cp.id = rc.controlada_por
    LEFT JOIN perfiles rp2 ON rp2.id = rc.resuelta_por
    ORDER BY fa.f DESC, tr.nombre ASC;
  END;
  $f$;

  IF cardinality(pg_temp.falla('canario', v_a1, v_t, 'SELECT 1', 'x')) <> 1
     OR cardinality(pg_temp.falla('canario', v_a1, v_t, 'SELECT 1/0', 'by zero')) <> 0
     OR cardinality(pg_temp.falla('canario', v_a1, v_t, 'SELECT 1/0', 'otro mensaje')) <> 1
     OR pg_temp.estado(v_a1, v_t, 'SELECT 1/0') <> '22012'
     OR pg_temp.estado(v_a1, v_t, 'SELECT 1') <> 'OK'
     OR pg_temp.como(v_a1, v_t, 'SELECT current_user || '' '' || auth.uid() || '' '' || public.current_sucursal_id()')
        IS DISTINCT FROM format('authenticated %s %s', v_a1, v_t)
     OR current_user = 'authenticated' THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · los helpers del ensayo no hacen lo que dicen';
  END IF;

  v_ch_ini := (pg_temp.audit(v_a1, v_t)->>'critical_high_en_rojo')::int;

  PERFORM set_config('g6.a1', v_a1::text, true);
  PERFORM set_config('g6.peaje', v_peaje::text, true);
  PERFORM pg_temp.adm();
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ g6 C1', 'ZZ g6 C1', 'Ensayo', v_t) RETURNING id INTO c1;
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ g6 A', 100, 100000, 60, v_t) RETURNING id INTO v_prod;
  INSERT INTO pedidos (cliente_id, sucursal_id, fecha, total, usuario_id, creado_por)
  VALUES (c1, v_t, v_hoy - 10, 0, v_a1, v_a1) RETURNING id INTO v_ped;
  INSERT INTO pedido_items (pedido_id, sucursal_id, producto_id, cantidad, precio_unitario, subtotal, costo_unitario_al_crear)
  VALUES (v_ped, v_t, v_prod, 10000, 100, 1000000, 60);
  UPDATE pedidos SET total = 1000000 WHERE id = v_ped;
  UPDATE pedidos SET estado = 'entregado', retiro_deposito = true,
                     fecha_entrega = ((v_hoy - 10) + time '12:00') AT TIME ZONE 'America/Argentina/Buenos_Aires'
   WHERE id = v_ped;
  PERFORM set_config('g6.c1', c1::text, true);
  PERFORM set_config('g6.ped', v_ped::text, true);

  v_en := pg_temp.u('encargado', v_t);
  v_tr := pg_temp.u('transportista', v_t);
  v_tr2 := pg_temp.u('transportista', v_tp);
  v_tr3 := pg_temp.u('transportista', v_t);
  SELECT COALESCE(nombre, 'transportista') INTO v_nom FROM perfiles WHERE id = v_tr;

  -- Todos los cobros antes de cerrar nada: un dia cerrado mueve los de antes.
  PERFORM pg_temp.cobro(v_tr, d3, 20000);
  PERFORM pg_temp.cobro(v_tr, d4, 50000);
  PERFORM pg_temp.cobro(v_tr, d7, 50000);
  PERFORM pg_temp.cobro(v_tr, d16, 10000);
  PERFORM pg_temp.cobro(v_tr3, d4, 5000);

  -- E1 es el vinculado al chofer; E2 no tiene usuario.
  e1 := pg_temp.alta(v_a1, v_t, v_tr, v_l);
  e2 := pg_temp.alta(v_a1, v_t, NULL, v_l);
  e_baja := pg_temp.alta(v_a1, v_t, NULL, v_l);
  e_tp := pg_temp.alta(v_ad, v_tp, NULL, v_l);
  PERFORM pg_temp.adm();
  UPDATE empleados SET activo = false, fecha_baja = v_hoy WHERE id = e_baja;
  -- La ficha de a1, si ya tiene una activa en T (desde el 02/11 la tienen todos).
  SELECT id INTO e_a1 FROM empleados WHERE usuario_id = v_a1 AND activo AND sucursal_id = v_t ORDER BY id LIMIT 1;
  IF e_a1 IS NULL THEN
    INSERT INTO empleados (sucursal_id, nombre, puesto, usuario_id, creado_por)
    VALUES (v_t, 'ZZ g6 la de a1', 'preventista', v_a1, v_ad) RETURNING id INTO e_a1;
  END IF;

  g_r4 := pg_temp.como(v_a1, v_t, pg_temp.gg(pg_temp.gp(d4, 10000) || pg_temp.plata(v_tr, d4)))::bigint;
  g_r7 := pg_temp.como(v_a1, v_t, pg_temp.gg(pg_temp.gp(d7, 10000) || pg_temp.plata(v_tr, d7)))::bigint;

  -- R3, R4, R7 y R16 en disconformidad: R4 y R7 las marca el encargado.
  PERFORM pg_temp.como(v_a1, v_t, pg_temp.cr(d3, v_tr, 'disconformidad', jsonb_build_object('vistos', pg_temp.vis(d3, v_tr))));
  PERFORM pg_temp.como(v_en, v_t, pg_temp.cr(d4, v_tr, 'disconformidad', jsonb_build_object('vistos', pg_temp.vis(d4, v_tr))));
  PERFORM pg_temp.como(v_en, v_t, pg_temp.cr(d7, v_tr, 'disconformidad', jsonb_build_object('vistos', pg_temp.vis(d7, v_tr))));
  PERFORM pg_temp.como(v_a1, v_t, pg_temp.cr(d16, v_tr, 'disconformidad', jsonb_build_object('vistos', pg_temp.vis(d16, v_tr))));
  PERFORM pg_temp.como(v_a1, v_t, pg_temp.cr(d4, v_tr3, 'disconformidad', jsonb_build_object('vistos', pg_temp.vis(d4, v_tr3))));
  PERFORM pg_temp.adm();
  INSERT INTO rendiciones_control (fecha, transportista_id, sucursal_id, estado, controlada_por)
  VALUES (dc, v_tr, v_t, 'confirmada', v_a1);
  IF pg_temp.ctl(d4, v_tr) IS DISTINCT FROM 'disconformidad' OR pg_temp.ctl(d7, v_tr) IS DISTINCT FROM 'disconformidad'
     OR (pg_temp.fila(d4, v_tr)->>'total_efectivo')::numeric IS DISTINCT FROM 50000 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · el armado no dejo R4 y R7 en disconformidad con 50000: %', pg_temp.fila(d4, v_tr);
  END IF;

  -- ============================================================ 2 · quien ===
  BEGIN
    v_hu := pg_temp.huella(d4, v_tr);
    v_res := pg_temp.rs(d4, v_tr, '[]');
    v_fallas := v_fallas || pg_temp.falla('2 encargado', v_en, v_t, pg_temp.rr(d4, v_tr, v_res), 'Sólo un admin resuelve una disconformidad');
    v_fallas := v_fallas || pg_temp.chk(pg_temp.estado(v_en, v_t, pg_temp.rr(d4, v_tr, v_res)) = '42501', '2 encargado sin 42501');
    v_fallas := v_fallas || pg_temp.falla('2 chofer', v_tr, v_t, pg_temp.rr(d4, v_tr, v_res), 'Sólo un admin resuelve una disconformidad');
    v_fallas := v_fallas || pg_temp.falla('2 encargado deshace', v_en, v_t, pg_temp.dz(d4, v_tr, 'x'), 'Sólo un admin deshace una resolución');
    v_fallas := v_fallas || pg_temp.chk(pg_temp.huella(d4, v_tr) = v_hu, format('2 quedo escrito: %s', pg_temp.huella(d4, v_tr)));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('2 · error: %s', SQLERRM);
  END;

  -- ===================================================== 8 · validaciones ===
  BEGIN
    v_hu := pg_temp.huella(d4, v_tr);
    v_fallas := v_fallas || pg_temp.falla('8 sin texto', v_a1, v_t, pg_temp.rr(d4, v_tr, pg_temp.rs(d4, v_tr, '[]'), '   '), 'Escribí cómo se resolvió');
    v_fallas := v_fallas || pg_temp.falla('8 monto 0', v_a1, v_t, pg_temp.rr(d4, v_tr, pg_temp.rs(d4, v_tr, jsonb_build_array(pg_temp.lr(0)))), 'Cada línea lleva un monto mayor a 0');
    v_fallas := v_fallas || pg_temp.falla('8 monto negativo', v_a1, v_t, pg_temp.rr(d4, v_tr, pg_temp.rs(d4, v_tr, jsonb_build_array(pg_temp.le(e1, -5)))), 'Cada línea lleva un monto mayor a 0');
    v_fallas := v_fallas || pg_temp.falla('8 causal', v_a1, v_t, pg_temp.rr(d4, v_tr, pg_temp.rs(d4, v_tr, '[{"causal":"sobrante","monto":10}]')), 'La resolución viene con un formato inválido');
    v_fallas := v_fallas || pg_temp.falla('8 monto texto', v_a1, v_t, pg_temp.rr(d4, v_tr, pg_temp.rs(d4, v_tr, '[{"causal":"robo_perdida","monto":"10"}]')), 'La resolución viene con un formato inválido');
    v_fallas := v_fallas || pg_temp.falla('8 sin lineas', v_a1, v_t, pg_temp.rr(d4, v_tr, '{"vistos":[],"pagos_personal_visto":0}'), 'La resolución viene con un formato inválido');
    v_fallas := v_fallas || pg_temp.falla('8 sin empleado', v_a1, v_t, pg_temp.rr(d4, v_tr, pg_temp.rs(d4, v_tr, '[{"causal":"empleado","monto":10,"empleado_id":null}]')), 'Elegí a qué empleado se le carga el faltante');
    v_fallas := v_fallas || pg_temp.falla('8 empleado inexistente', v_a1, v_t, pg_temp.rr(d4, v_tr, pg_temp.rs(d4, v_tr, jsonb_build_array(pg_temp.le(999999999999, 10)))), 'Ese empleado no existe o no lo podés ver');
    v_fallas := v_fallas || pg_temp.falla('8 empleado de baja', v_a1, v_t, pg_temp.rr(d4, v_tr, pg_temp.rs(d4, v_tr, jsonb_build_array(pg_temp.le(e_baja, 10)))), 'Ese empleado está dado de baja');
    -- El de Taco Pozo no es visible para a1 (_empleado_visible): no llega a
    -- "no es de esta sucursal".
    v_fallas := v_fallas || pg_temp.falla('8 empleado de TP', v_a1, v_t, pg_temp.rr(d4, v_tr, pg_temp.rs(d4, v_tr, jsonb_build_array(pg_temp.le(e_tp, 10)))), 'Ese empleado no existe o no lo podés ver');
    v_fallas := v_fallas || pg_temp.falla('8 el propio', v_a1, v_t, pg_temp.rr(d4, v_tr, pg_temp.rs(d4, v_tr, jsonb_build_array(pg_temp.le(e_a1, 10)))), 'Tu propia cuenta la maneja otro admin: no podés cargarte un faltante');
    v_fallas := v_fallas || pg_temp.falla('8 confirmada', v_a1, v_t, pg_temp.rr(dc, v_tr, pg_temp.rs(dc, v_tr, '[]')), 'Solo se pueden resolver rendiciones en disconformidad (estado actual: confirmada)');
    v_fallas := v_fallas || pg_temp.falla('8 pendiente', v_a1, v_t, pg_temp.rr(d15, v_tr, pg_temp.rs(d15, v_tr, '[]')), 'No existe rendicion para');
    v_fallas := v_fallas || pg_temp.falla('8 otra sucursal', v_a1, v_t, pg_temp.rr(d4, v_tr2, pg_temp.rs(d4, v_tr2, '[]')), 'Ese transportista no es de esta sucursal');
    v_fallas := v_fallas || pg_temp.chk(pg_temp.huella(d4, v_tr) = v_hu, format('8 quedo escrito: %s', pg_temp.huella(d4, v_tr)));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('8 · error: %s', SQLERRM);
  END;

  -- ========================================================== 9 · lo visto ===
  BEGIN
    -- Un gasto cargado desde Gastos despues de abrir el modal.
    v_res := pg_temp.rs(d4, v_tr, jsonb_build_array(pg_temp.lr(100)));
    v_n := pg_temp.como(v_a1, v_t, pg_temp.gg(pg_temp.gp(d4, 700) || pg_temp.plata(v_tr, d4)))::bigint;
    v_hu := pg_temp.huella(d4, v_tr);
    v_fallas := v_fallas || pg_temp.falla('9 gastos', v_a1, v_t, pg_temp.rr(d4, v_tr, v_res),
                  'Los gastos de esta rendición cambiaron mientras la resolvías: tocá Refrescar y volvé a abrir');
    v_fallas := v_fallas || pg_temp.chk(pg_temp.huella(d4, v_tr) = v_hu, '9 gastos: quedo escrito');
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.ag(v_n, 'Ensayo'));
    -- Un pago suelto al personal con la plata de la rendicion (queda: caso 18).
    v_res := pg_temp.rs(d4, v_tr, jsonb_build_array(pg_temp.lr(100)));
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.mov(e2, '{"tipo":"pago","monto":2000}'::jsonb || pg_temp.plata(v_tr, d4)));
    v_hu := pg_temp.huella(d4, v_tr);
    v_fallas := v_fallas || pg_temp.falla('9 pagos', v_a1, v_t, pg_temp.rr(d4, v_tr, v_res),
                  'Los pagos al personal de esta rendición cambiaron mientras la resolvías: tocá Refrescar y volvé a abrir');
    v_fallas := v_fallas || pg_temp.chk(pg_temp.huella(d4, v_tr) = v_hu, '9 pagos: quedo escrito');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('9 · error: %s', SQLERRM);
  END;

  -- ======================================================== 3 · solo texto ===
  BEGIN
    v_rc := pg_temp.como(v_a1, v_t, pg_temp.rr(d3, v_tr, pg_temp.rs(d3, v_tr, '[]'), 'la plata aparecio'))::bigint;
    v_fallas := v_fallas || pg_temp.chk(
      (SELECT estado = 'resuelta' AND resuelta_por = v_a1 AND observaciones LIKE '%[Resuelta por % el %]: la plata aparecio'
         FROM rendiciones_control WHERE id = v_rc)
      AND EXISTS (SELECT 1 FROM rendicion_pagos_confirmados WHERE rendicion_id = v_rc)
      AND pg_temp.huella(d3, v_tr) LIKE 'lineas 0, anuladas 0, movimientos 0, gastos 0 %',
      format('3 solo texto: %s', (SELECT to_jsonb(rc) FROM rendiciones_control rc WHERE id = v_rc)));
    v_fallas := v_fallas || pg_temp.chk(pg_temp.gasto_a() = 0, '3 GASTO-A');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('3 · error: %s', SQLERRM);
  END;

  -- ================================================== 4, 5 y 6 · las causales ===
  BEGIN
    v_hu := pg_temp.huella(d4, v_tr);
    v_fallas := v_fallas || pg_temp.falla('6 monto distinto del gasto', v_a1, v_t,
                  pg_temp.rr(d4, v_tr, pg_temp.rs(d4, v_tr, jsonb_build_array(pg_temp.lg(600, pg_temp.gp(d4, 500))), 2000)),
                  'La resolución viene con un formato inválido');
    v_fallas := v_fallas || pg_temp.falla('6 un gasto que ya existe', v_a1, v_t,
                  pg_temp.rr(d4, v_tr, pg_temp.rs(d4, v_tr, jsonb_build_array(pg_temp.lg(500, pg_temp.gp(d4, 500) || jsonb_build_object('id', g_r4))), 2000)),
                  'La resolución viene con un formato inválido');
    v_fallas := v_fallas || pg_temp.chk(pg_temp.huella(d4, v_tr) = v_hu, '6 quedo escrito');

    v_j := pg_temp.pv(e1);
    v_m := (v_j->>'a_pagar')::numeric;
    v_s0 := pg_temp.saldo(e1);
    SELECT COALESCE(max(id), 0) INTO v_n FROM empleado_movimientos WHERE empleado_id = e1;
    PERFORM set_config('g6.mov0', v_n::text, true);

    v_rc := pg_temp.como(v_a1, v_t, pg_temp.rr(d4, v_tr, pg_temp.rs(d4, v_tr, jsonb_build_array(
              pg_temp.le(e1, 3000, 'no aparecio'), pg_temp.lr(1000, 'se cayo del camion'),
              pg_temp.lg(500, pg_temp.gp(d4, 500))), 2000)))::bigint;

    -- 4 · la deuda
    SELECT m.* INTO g FROM empleado_movimientos m WHERE m.empleado_id = e1 AND m.tipo = 'faltante' AND m.rendicion_fecha = d4;
    v_mov := g.id;
    v_fallas := v_fallas || pg_temp.chk(g.monto = -3000 AND g.fecha = v_hoy AND g.creado_por = v_a1 AND g.revierte_id IS NULL
                                        AND g.rendicion_transportista_id = v_tr AND g.rendicion_sucursal_id = v_t
                                        AND g.observacion = 'no aparecio', format('4 movimiento: %s', to_jsonb(g)));
    v_fallas := v_fallas || pg_temp.chk(EXISTS (SELECT 1 FROM rendicion_faltantes WHERE movimiento_id = v_mov AND causal = 'empleado'
                                                  AND empleado_id = e1 AND monto = 3000 AND gasto_id IS NULL AND creado_por = v_a1
                                                  AND observacion = 'no aparecio' AND anulada_at IS NULL), '4 linea');
    v_j := pg_temp.fila(d4, v_tr);
    v_fallas := v_fallas || pg_temp.chk((v_j->>'total_faltantes_empleados')::numeric = 3000
                                        AND (v_j->>'total_pagos_personal')::numeric = 2000
                                        AND (v_j->>'total_gastos')::numeric = 11500 AND v_j->>'estado' = 'resuelta',
                                        format('4 resumen: %s', v_j));
    v_fallas := v_fallas || pg_temp.chk((SELECT estado = 'resuelta' AND observaciones LIKE '%[Resuelta por % el %]: ensayo gastos 6'
                                           FROM rendiciones_control WHERE id = v_rc)
                                        AND EXISTS (SELECT 1 FROM rendicion_pagos_confirmados WHERE rendicion_id = v_rc), '4 control');

    -- 5 · robo o perdida
    SELECT gs.* INTO g FROM gastos gs JOIN rendicion_faltantes f ON f.gasto_id = gs.id
     WHERE f.causal = 'robo_perdida' AND f.rendicion_fecha = d4 AND f.rendicion_transportista_id = v_tr;
    g_robo := g.id;
    v_fallas := v_fallas || pg_temp.chk(g.rubro_id = v_rubro AND g.comprobante = 'ninguno' AND g.fecha = d4 AND g.monto_total = 1000
                                        AND g.origen_pago = 'rendicion' AND g.rendicion_transportista_id = v_tr AND g.rendicion_fecha = d4
                                        AND g.sucursal_id = v_t AND g.anulado_at IS NULL
                                        AND g.observacion = format('Robo o pérdida · diferencia de la rendición de %s del %s · se cayo del camion',
                                                                   v_nom, to_char(d4, 'DD/MM/YYYY')),
                                        format('5 gasto: %s', to_jsonb(g)));

    -- 6 · gasto que no se cargo
    SELECT gs.* INTO g FROM gastos gs JOIN rendicion_faltantes f ON f.gasto_id = gs.id
     WHERE f.causal = 'gasto_no_cargado' AND f.rendicion_fecha = d4 AND f.rendicion_transportista_id = v_tr;
    g_nc := g.id;
    v_fallas := v_fallas || pg_temp.chk(g.rubro_id = v_peaje AND g.monto_total = 500 AND g.origen_pago = 'rendicion'
                                        AND g.rendicion_transportista_id = v_tr AND g.rendicion_fecha = d4 AND g.fecha = d4
                                        AND g.observacion = 'peaje ruta 9 · Diferencia de la rendición del ' || to_char(d4, 'DD/MM/YYYY'),
                                        format('6 gasto: %s', to_jsonb(g)));
    v_fallas := v_fallas || pg_temp.chk(pg_temp.vivas(d4, v_tr) = 3, '4-6 no son tres lineas');
    v_fallas := v_fallas || pg_temp.chk(pg_temp.gasto_a() = 0, '4-6 GASTO-A');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('4-6 · error: %s', SQLERRM);
  END;

  -- ========================================================= 10 · personal ===
  BEGIN
    v_fallas := v_fallas || pg_temp.falla('10 revertir', v_a1, v_t, pg_temp.rev(v_mov),
                  'Un faltante de rendición se deshace desde la rendición, con «Deshacer resolución»');
    v_j := pg_temp.pv(e1);
    v_fallas := v_fallas || pg_temp.chk((v_j->>'a_pagar')::numeric = v_m - 3000
                                        AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_j->'movimientos') x
                                                     WHERE x->>'tipo' = 'faltante' AND (x->>'id')::bigint = v_mov),
                                        format('10 vista previa (antes %s): %s', v_m, v_j));
    v_fallas := v_fallas || pg_temp.falla('10 a mano', v_a1, v_t, pg_temp.mov(e1, '{"tipo":"faltante","monto":10}'), 'Un movimiento a mano es');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('10 · error: %s', SQLERRM);
  END;

  -- =================================================== 12 · editar cierre ===
  BEGIN
    v_hu := pg_temp.huella(d4, v_tr);
    v_k := jsonb_build_object('vistos', pg_temp.vis(d4, v_tr), 'pagos_personal_visto', 2000);
    v_fallas := v_fallas || pg_temp.falla('12 faltantes viejo', v_a1, v_t, pg_temp.cr(d4, v_tr, 'confirmada', v_k || '{"faltantes_visto":0}'),
                  'Los faltantes de esta rendición cambiaron mientras la cerrabas: tocá Refrescar y volvé a abrir el cierre');
    v_fallas := v_fallas || pg_temp.falla('12 faltantes sin la clave', v_a1, v_t, pg_temp.cr(d4, v_tr, 'confirmada', v_k),
                  'Los faltantes de esta rendición cambiaron mientras la cerrabas');
    v_fallas := v_fallas || pg_temp.falla('12 faltantes con otro formato', v_a1, v_t, pg_temp.cr(d4, v_tr, 'confirmada', v_k || '{"faltantes_visto":"x"}'),
                  'Los gastos del cierre vienen con un formato inválido');
    v_fallas := v_fallas || pg_temp.falla('12 disconformidad', v_a1, v_t, pg_temp.cr(d4, v_tr, 'disconformidad', v_k || '{"faltantes_visto":3000}'),
                  'Esta rendición tiene una diferencia imputada: para volver a disconformidad, deshacé la resolución');
    -- 11 · quitar desde Editar cierre un gasto de la resolucion
    v_fallas := v_fallas || pg_temp.falla('11 quitar en el cierre', v_a1, v_t,
                  pg_temp.cr(d4, v_tr, 'confirmada', v_k || jsonb_build_object('faltantes_visto', 3000, 'quitar', jsonb_build_array(g_robo))),
                  'En el gasto de Faltantes de caja: Este gasto es de la resolución de una diferencia: se deshace con «Deshacer resolución» en Rendiciones');
    v_fallas := v_fallas || pg_temp.falla('11 editar en el cierre', v_a1, v_t,
                  pg_temp.cr(d4, v_tr, 'confirmada', v_k || jsonb_build_object('faltantes_visto', 3000,
                    'guardar', jsonb_build_array(pg_temp.gp(d4, 900) || jsonb_build_object('id', g_nc)))),
                  'En el gasto de Peajes y estacionamiento: Este gasto es de la resolución de una diferencia');
    v_fallas := v_fallas || pg_temp.chk(pg_temp.huella(d4, v_tr) = v_hu, format('12 quedo escrito: %s', pg_temp.huella(d4, v_tr)));
    -- estado() deshace lo que prueba: el cierre que queda va por como().
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.cr(d4, v_tr, 'confirmada', v_k || '{"faltantes_visto":3000}'));
    v_fallas := v_fallas || pg_temp.chk(pg_temp.ctl(d4, v_tr) = 'confirmada' AND pg_temp.vivas(d4, v_tr) = 3,
                  format('12 con lo que vio queda %s con %s lineas', pg_temp.ctl(d4, v_tr), pg_temp.vivas(d4, v_tr)));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('12 · error: %s', SQLERRM);
  END;

  -- ============================================= 11 · la guarda de gastos ===
  BEGIN
    PERFORM pg_temp.como(v_a1, v_t, format('SELECT public.desmarcar_rendicion_controlada(p_fecha => %L::date, p_transportista_id => %L::uuid)', d4, v_tr));
    v_hu := pg_temp.huella(d4, v_tr);
    v_fallas := v_fallas || pg_temp.falla('11 editar desde Gastos', v_a1, v_t,
                  pg_temp.gg((SELECT jsonb_build_object('id', id, 'fecha', fecha, 'rubro_id', rubro_id, 'monto_total', 1500,
                                                        'comprobante', comprobante, 'observacion', observacion)
                                FROM gastos WHERE id = g_robo) || pg_temp.plata(v_tr, d4)),
                  'Este gasto es de la resolución de una diferencia: se deshace con «Deshacer resolución» en Rendiciones');
    v_fallas := v_fallas || pg_temp.chk(pg_temp.estado(v_a1, v_t, pg_temp.ag(g_robo, 'Ensayo')) = '42501', '11 anular sin 42501');
    v_fallas := v_fallas || pg_temp.falla('11 anular desde Gastos', v_a1, v_t, pg_temp.ag(g_nc, 'Ensayo'),
                  'Este gasto es de la resolución de una diferencia');
    BEGIN
      DELETE FROM gastos WHERE id = g_robo;
      v_fallas := v_fallas || '11 un DELETE paso la guarda'::text;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.huella(d4, v_tr) = v_hu, format('11 quedo escrito: %s', pg_temp.huella(d4, v_tr)));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('11 · error: %s', SQLERRM);
  END;

  -- ================================================== 14 · reabierta sola ===
  BEGIN
    v_j := pg_temp.fila(d4, v_tr);
    v_fallas := v_fallas || pg_temp.chk(pg_temp.ctl(d4, v_tr) IS NULL AND v_j->>'estado' = 'pendiente'
                                        AND (v_j->>'total_faltantes_empleados')::numeric = 3000
                                        AND (v_j->>'total_gastos')::numeric = 11500, format('14 pendiente: %s', v_j));
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.dz(d4, v_tr, 'la rendicion se reabrio'));
    v_j := pg_temp.fila(d4, v_tr);
    v_fallas := v_fallas || pg_temp.chk(pg_temp.ctl(d4, v_tr) IS NULL AND pg_temp.vivas(d4, v_tr) = 0
                                        AND (v_j->>'total_faltantes_empleados')::numeric = 0
                                        AND (v_j->>'total_gastos')::numeric = 10000
                                        AND (SELECT count(*) FROM gastos WHERE id IN (g_robo, g_nc) AND anulado_at IS NOT NULL
                                               AND motivo_anulacion = 'Se deshizo la resolución de la diferencia: la rendicion se reabrio') = 2
                                        AND EXISTS (SELECT 1 FROM empleado_movimientos WHERE revierte_id = v_mov AND tipo = 'faltante'
                                                      AND monto = 3000 AND fecha = v_hoy AND rendicion_fecha = d4
                                                      AND rendicion_transportista_id = v_tr AND rendicion_sucursal_id = v_t),
                                        format('14 deshacer: %s / %s', v_j, pg_temp.huella(d4, v_tr)));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('14 · error: %s', SQLERRM);
  END;

  -- ================================================== 7 · varias y el tope ===
  BEGIN
    -- 50000 de efectivo - 10000 de gastos: entran 40000.
    v_hu := pg_temp.huella(d7, v_tr);
    v_fallas := v_fallas || pg_temp.falla('7 tope', v_a1, v_t,
                  pg_temp.rr(d7, v_tr, pg_temp.rs(d7, v_tr, jsonb_build_array(pg_temp.le(e1, 3000), pg_temp.le(e2, 2000),
                                                                             pg_temp.lr(1000), pg_temp.lr(34000.01)))),
                  'Lo imputado supera lo que había para entregar');
    v_fallas := v_fallas || pg_temp.chk(pg_temp.huella(d7, v_tr) = v_hu AND pg_temp.ctl(d7, v_tr) = 'disconformidad',
                  format('7 tope: quedo escrito %s', pg_temp.huella(d7, v_tr)));
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.rr(d7, v_tr, pg_temp.rs(d7, v_tr, jsonb_build_array(
              pg_temp.le(e1, 3000), pg_temp.le(e2, 2000), pg_temp.lr(1000)))));
    v_fallas := v_fallas || pg_temp.chk(pg_temp.vivas(d7, v_tr) = 3 AND pg_temp.ctl(d7, v_tr) = 'resuelta'
                                        AND (pg_temp.fila(d7, v_tr)->>'total_faltantes_empleados')::numeric = 5000,
                  format('7 tres lineas: %s', pg_temp.fila(d7, v_tr)));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('7 · error: %s', SQLERRM);
  END;

  -- ========================================================= 13 · deshacer ===
  BEGIN
    -- c · E1 liquidado entre resolver y deshacer
    PERFORM pg_temp.lq(e1);
    v_m2 := (pg_temp.pv(e1)->>'a_pagar')::numeric;

    v_fallas := v_fallas || pg_temp.falla('13a sin motivo', v_a1, v_t, pg_temp.dz(d7, v_tr, '  '), 'Escribí por qué se deshace');
    v_rc := (SELECT id FROM rendiciones_control WHERE fecha = d7 AND transportista_id = v_tr AND sucursal_id = v_t);
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.dz(d7, v_tr, 'ensayo deshacer'));
    v_j := pg_temp.fila(d7, v_tr);
    v_fallas := v_fallas || pg_temp.chk(
      pg_temp.vivas(d7, v_tr) = 0
      AND (SELECT count(*) FROM rendicion_faltantes WHERE rendicion_fecha = d7 AND rendicion_transportista_id = v_tr
             AND anulada_at IS NOT NULL AND anulada_por = v_a1 AND motivo_anulacion = 'ensayo deshacer') = 3
      AND (SELECT count(*) FROM empleado_movimientos m JOIN rendicion_faltantes f ON f.movimiento_id = m.revierte_id
            WHERE f.rendicion_fecha = d7 AND f.rendicion_transportista_id = v_tr AND m.tipo = 'faltante' AND m.monto = f.monto
              AND m.fecha = v_hoy AND m.rendicion_fecha = d7 AND m.rendicion_transportista_id = v_tr
              AND m.empleado_id = f.empleado_id AND m.observacion = 'ensayo deshacer' AND m.creado_por = v_a1) = 2
      AND (SELECT count(*) FROM gastos gs JOIN rendicion_faltantes f ON f.gasto_id = gs.id
            WHERE f.rendicion_fecha = d7 AND f.rendicion_transportista_id = v_tr AND gs.anulado_at IS NOT NULL
              AND gs.motivo_anulacion = 'Se deshizo la resolución de la diferencia: ensayo deshacer') = 1
      AND (SELECT estado = 'disconformidad' AND resuelta_at IS NULL AND resuelta_por IS NULL
                  AND observaciones LIKE '%[Deshecha por % el __/__/____ __:__]: ensayo deshacer'
             FROM rendiciones_control WHERE id = v_rc)
      AND NOT EXISTS (SELECT 1 FROM rendicion_pagos_confirmados WHERE rendicion_id = v_rc)
      AND (v_j->>'total_faltantes_empleados')::numeric = 0 AND (v_j->>'total_gastos')::numeric = 10000,
      format('13b: %s / %s', v_j, pg_temp.huella(d7, v_tr)));

    v_j := pg_temp.pv(e1);
    v_fallas := v_fallas || pg_temp.chk((v_j->>'a_pagar')::numeric = v_m2 + 3000
                                        AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_j->'movimientos') x
                                                     WHERE x->>'tipo' = 'faltante' AND (x->>'monto')::numeric = 3000),
                                        format('13c la liquidacion siguiente (antes %s): %s', v_m2, v_j));
    v_fallas := v_fallas || pg_temp.chk(
      (SELECT COALESCE(sum(monto), 0) FROM empleado_movimientos WHERE empleado_id = e1 AND tipo = 'faltante') = 0
      AND pg_temp.saldo(e1) = v_s0 + (SELECT COALESCE(sum(monto), 0) FROM empleado_movimientos
                                       WHERE empleado_id = e1 AND tipo <> 'faltante' AND id > current_setting('g6.mov0')::bigint),
      format('13c saldo de E1: %s (antes %s)', pg_temp.saldo(e1), v_s0));

    -- d · se resuelve otra vez
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.rr(d7, v_tr, pg_temp.rs(d7, v_tr, jsonb_build_array(pg_temp.le(e2, 1000), pg_temp.lr(500)))));
    v_fallas := v_fallas || pg_temp.chk(pg_temp.vivas(d7, v_tr) = 2 AND pg_temp.ctl(d7, v_tr) = 'resuelta'
                                        AND (SELECT count(*) FROM rendicion_faltantes WHERE rendicion_fecha = d7 AND rendicion_transportista_id = v_tr) = 5,
                  format('13d: %s', pg_temp.huella(d7, v_tr)));

    -- e · deshacer una resuelta solo con texto
    v_hu := pg_temp.huella(d3, v_tr);
    v_rc := (SELECT id FROM rendiciones_control WHERE fecha = d3 AND transportista_id = v_tr AND sucursal_id = v_t);
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.dz(d3, v_tr, 'era otra cosa'));
    v_fallas := v_fallas || pg_temp.chk(
      pg_temp.ctl(d3, v_tr) = 'disconformidad' AND NOT EXISTS (SELECT 1 FROM rendicion_pagos_confirmados WHERE rendicion_id = v_rc)
      AND pg_temp.huella(d3, v_tr) LIKE 'lineas 0, anuladas 0, movimientos 0, gastos 0 %'
      AND (SELECT observaciones LIKE '%: la plata aparecio' || E'\n\n' || '[Deshecha por % el %]: era otra cosa' FROM rendiciones_control WHERE id = v_rc),
      format('13e: %s', (SELECT to_jsonb(rc) FROM rendiciones_control rc WHERE id = v_rc)));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('13 · error: %s', SQLERRM);
  END;

  -- ============================================== 15 · nada para deshacer ===
  BEGIN
    v_fallas := v_fallas || pg_temp.falla('15 pendiente sin lineas', v_a1, v_t, pg_temp.dz(d15, v_tr, 'x'), 'No hay nada para deshacer en esta rendición');
    v_fallas := v_fallas || pg_temp.falla('15 confirmada sin lineas', v_a1, v_t, pg_temp.dz(dc, v_tr, 'x'), 'No hay nada para deshacer en esta rendición');
    v_fallas := v_fallas || pg_temp.falla('15 otra sucursal', v_a1, v_t, pg_temp.dz(d4, v_tr2, 'x'), 'Ese transportista no es de esta sucursal');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('15 · error: %s', SQLERRM);
  END;

  -- ===================================================== 16 · bundle viejo ===
  BEGIN
    v_fallas := v_fallas || pg_temp.falla('16 encargado', v_en, v_t, pg_temp.rr(d16, v_tr, NULL), 'Sólo un admin resuelve una disconformidad');
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.rr(d16, v_tr, NULL));
    v_fallas := v_fallas || pg_temp.chk(pg_temp.ctl(d16, v_tr) = 'resuelta' AND pg_temp.vivas(d16, v_tr) = 0,
                  format('16 tres argumentos deja %s', pg_temp.ctl(d16, v_tr)));
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.cr(d16, v_tr, 'confirmada', jsonb_build_object('vistos', pg_temp.vis(d16, v_tr), 'pagos_personal_visto', 0)));
    v_fallas := v_fallas || pg_temp.chk(pg_temp.ctl(d16, v_tr) = 'confirmada', format('16 cierre sin faltantes_visto deja %s', pg_temp.ctl(d16, v_tr)));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('16 · error: %s', SQLERRM);
  END;

  -- ========================================================= 17 · lecturas ===
  BEGIN
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.rr(d4, v_tr3, pg_temp.rs(d4, v_tr3, jsonb_build_array(pg_temp.lr(100)))));
    v_txt := format('SELECT public.obtener_faltantes_rendiciones(p_fecha_desde => %L::date, p_fecha_hasta => %L::date, p_transportista_id => NULL)',
                    v_hoy - 10, v_hoy);
    v_j := pg_temp.como(v_a1, v_t, v_txt)::jsonb;
    v_fallas := v_fallas || pg_temp.chk(
      jsonb_array_length(v_j) = 3
      AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) x JOIN rendicion_faltantes f ON f.id = (x->>'id')::bigint
                       WHERE f.anulada_at IS NOT NULL)
      AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) x
                   WHERE x->>'causal' = 'empleado' AND (x#>>'{empleado,id}')::bigint = e2 AND x#>>'{empleado,nombre}' LIKE 'ZZ g6 %'
                     AND (x->>'transportista_id')::uuid = v_tr AND (x->>'fecha')::date = d7 AND (x->>'monto')::numeric = 1000
                     AND x->'gasto_id' = 'null' AND x->'rubro_nombre' = 'null' AND x->>'creado_por_nombre' IS NOT NULL)
      AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) x
                   WHERE x->>'causal' = 'robo_perdida' AND x->>'rubro_nombre' = 'Faltantes de caja' AND x->'empleado' = 'null'
                     AND (x->>'gasto_id')::bigint IS NOT NULL AND (x->>'transportista_id')::uuid = v_tr3)
      AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) x
                       WHERE NOT (x ?& ARRAY['id', 'transportista_id', 'fecha', 'causal', 'monto', 'observacion', 'empleado',
                                             'gasto_id', 'rubro_nombre', 'creado_por_nombre', 'created_at'])),
      format('17 a1: %s', v_j));
    v_k := pg_temp.como(v_en, v_t, v_txt)::jsonb;
    v_fallas := v_fallas || pg_temp.chk(jsonb_array_length(v_k) = 3, format('17 encargado: %s', v_k));
    v_k := pg_temp.como(v_tr, v_t, v_txt)::jsonb;
    v_fallas := v_fallas || pg_temp.chk(jsonb_array_length(v_k) = 2
                                        AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_k) x WHERE (x->>'transportista_id')::uuid <> v_tr),
                  format('17 chofer: %s', v_k));
    v_txt := pg_temp.estado(v_tr, v_t, format(
      'SELECT public.obtener_faltantes_rendiciones(p_fecha_desde => %L::date, p_fecha_hasta => %L::date, p_transportista_id => %L::uuid)',
      v_hoy - 10, v_hoy, v_tr3));
    v_fallas := v_fallas || pg_temp.chk(v_txt = '42501', format('17 el chofer pide otro: %s', v_txt));
    v_txt := pg_temp.estado(v_tr2, v_tp, format(
      'SELECT public.obtener_faltantes_rendiciones(p_fecha_desde => %L::date, p_fecha_hasta => %L::date)', v_hoy - 10, v_hoy));
    v_k := pg_temp.como(v_tr2, v_tp, format(
      'SELECT public.obtener_faltantes_rendiciones(p_fecha_desde => %L::date, p_fecha_hasta => %L::date)', v_hoy - 10, v_hoy))::jsonb;
    v_fallas := v_fallas || pg_temp.chk(v_txt = 'OK' AND jsonb_array_length(v_k) = 0, format('17 chofer de TP: %s %s', v_txt, v_k));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('17 · error: %s', SQLERRM);
  END;

  -- ========================================= 18 · lo de antes sigue igual ===
  BEGIN
    -- El pago suelto del caso 9 sigue en total_pagos_personal (caso 4), y el
    -- resumen de octubre es el de la 437 en cada columna de antes, sin las
    -- rendiciones del ensayo.
    FOR g IN SELECT * FROM (VALUES (v_a1, v_t), (v_ad, v_tp)) AS x(u, s) LOOP
      PERFORM pg_temp.claims(g.u, g.s);
      SELECT count(*) INTO v_n FROM (
        (SELECT to_jsonb(r) - 'total_faltantes_empleados' AS j
           FROM public.obtener_resumen_rendiciones('2026-10-01', '2026-10-31', NULL) r
          WHERE r.transportista_id NOT IN (v_tr, v_tr3)
         EXCEPT ALL
         SELECT to_jsonb(o) FROM pg_temp.resumen_437('2026-10-01', '2026-10-31', NULL) o
          WHERE o.transportista_id NOT IN (v_tr, v_tr3))
        UNION ALL
        (SELECT to_jsonb(o) FROM pg_temp.resumen_437('2026-10-01', '2026-10-31', NULL) o
          WHERE o.transportista_id NOT IN (v_tr, v_tr3)
         EXCEPT ALL
         SELECT to_jsonb(r) - 'total_faltantes_empleados'
           FROM public.obtener_resumen_rendiciones('2026-10-01', '2026-10-31', NULL) r
          WHERE r.transportista_id NOT IN (v_tr, v_tr3))) x;
      v_m := (SELECT count(*) FROM pg_temp.resumen_437('2026-10-01', '2026-10-31', NULL) o WHERE o.transportista_id NOT IN (v_tr, v_tr3));
      v_fallas := v_fallas || pg_temp.chk(v_n = 0 AND (g.s = v_t OR v_m > 0),
                    format('18 octubre de la sucursal %s: %s filas distintas de %s', g.s, v_n, v_m));
      v_fallas := v_fallas || pg_temp.chk(NOT EXISTS (SELECT 1 FROM public.obtener_resumen_rendiciones('2026-10-01', '2026-10-31', NULL) r
                                                       WHERE r.transportista_id NOT IN (v_tr, v_tr3) AND r.total_faltantes_empleados <> 0),
                    format('18 octubre de la sucursal %s tiene faltantes', g.s));
    END LOOP;
    PERFORM pg_temp.adm();
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('18 · error: %s', SQLERRM);
  END;

  -- ========================================================= 19 · permisos ===
  BEGIN
    v_fallas := v_fallas || pg_temp.chk(to_regprocedure('public.resolver_rendicion(date,uuid,text)') IS NULL
                                        AND (SELECT count(*) FROM pg_proc WHERE proname = 'resolver_rendicion'
                                               AND pronamespace = 'public'::regnamespace) = 1, '19 quedo la firma vieja de resolver_rendicion');
    FOR g IN SELECT f FROM unnest(ARRAY['public._rendicion_cambio_visto(bigint,uuid,date,jsonb,numeric,numeric)',
                                        'public.rendicion_faltantes_guarda_gasto()']) f LOOP
      IF has_function_privilege('anon', g.f, 'EXECUTE') OR has_function_privilege('authenticated', g.f, 'EXECUTE') THEN
        v_fallas := v_fallas || format('19 alcanzable: %s', g.f);
      END IF;
    END LOOP;
    FOR g IN SELECT f FROM unnest(ARRAY['public.resolver_rendicion(date,uuid,text,jsonb)',
                                        'public.deshacer_resolucion_rendicion(date,uuid,text)',
                                        'public.obtener_faltantes_rendiciones(date,date,uuid)',
                                        'public.obtener_resumen_rendiciones(date,date,uuid)',
                                        'public.confirmar_rendicion(date,uuid,text,jsonb,text)',
                                        'public.revertir_movimiento_empleado(bigint,text)']) f LOOP
      IF has_function_privilege('anon', g.f, 'EXECUTE') OR NOT has_function_privilege('authenticated', g.f, 'EXECUTE') THEN
        v_fallas := v_fallas || format('19 EXECUTE de %s', g.f);
      END IF;
    END LOOP;
    IF has_table_privilege('anon', 'public.rendicion_faltantes', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
       OR has_table_privilege('authenticated', 'public.rendicion_faltantes', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
       OR has_any_column_privilege('authenticated', 'public.rendicion_faltantes', 'SELECT,INSERT,UPDATE,REFERENCES')
       OR NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.rendicion_faltantes'::regclass)
       OR EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'public.rendicion_faltantes'::regclass) THEN
      v_fallas := v_fallas || '19 tabla rendicion_faltantes'::text;
    END IF;
    SELECT count(*) INTO v_n FROM public.auditoria_definer_sin_rol()
     WHERE firma ~ '^(resolver_rendicion|deshacer_resolucion_rendicion|obtener_faltantes_rendiciones|_rendicion_cambio_visto|rendicion_faltantes_guarda_gasto|confirmar_rendicion|obtener_resumen_rendiciones|revertir_movimiento_empleado)\(';
    v_fallas := v_fallas || pg_temp.chk(v_n = 0, format('19 %s funciones en auditoria_definer_sin_rol', v_n));
    v_j := public.auditoria_rpcs_definer()->'parametros';
    v_fallas := v_fallas || pg_temp.chk(
      (SELECT count(*) FROM jsonb_array_elements(v_j) x
        WHERE x->>'nombre' IN ('resolver_rendicion', 'deshacer_resolucion_rendicion', 'obtener_faltantes_rendiciones')
          AND x->>'parametro' = 'p_transportista_id' AND (x->>'acotado')::boolean) = 3
      AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) x
                       WHERE x->>'nombre' IN ('resolver_rendicion', 'deshacer_resolucion_rendicion', 'obtener_faltantes_rendiciones',
                                              'confirmar_rendicion', 'obtener_resumen_rendiciones')
                         AND NOT (x->>'acotado')::boolean),
      format('19 auditoria_rpcs_definer: %s', (SELECT jsonb_agg(x) FROM jsonb_array_elements(v_j) x
                                                WHERE x->>'nombre' ~ 'rendicion')));
    SELECT count(*) INTO v_n FROM public.auditoria_sucursal_cruzada() WHERE hija ~ '^rendicion_faltantes';
    v_fallas := v_fallas || pg_temp.chk(v_n = 0, format('19 %s pares nuevos en auditoria_sucursal_cruzada', v_n));
    v_k := public.auditoria_fechas_utc();
    v_fallas := v_fallas || pg_temp.chk(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_k->'funciones') f
                                                     WHERE f->>'nombre' ~ '(faltante|resolver_rendicion|deshacer_resolucion|_rendicion_cambio_visto|confirmar_rendicion|obtener_resumen_rendiciones)'),
                  format('19 auditoria_fechas_utc: %s', v_k->'funciones'));
    v_fallas := v_fallas || pg_temp.chk(EXISTS (SELECT 1 FROM gasto_rubros WHERE id = v_rubro AND grupo = 'otros' AND activo),
                  '19 el rubro Faltantes de caja');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('19 · error: %s', SQLERRM);
  END;

  -- ====================================================== 20 · invariantes ===
  BEGIN
    v_fallas := v_fallas || pg_temp.chk(pg_temp.gasto_a() = 0, format('20 GASTO-A da %s', pg_temp.gasto_a()));
    SELECT count(*) INTO v_n FROM rendicion_faltantes f
     WHERE f.anulada_at IS NULL
       AND NOT CASE WHEN f.causal = 'empleado'
                    THEN EXISTS (SELECT 1 FROM empleado_movimientos m
                                  WHERE m.id = f.movimiento_id AND m.tipo = 'faltante' AND m.monto = -f.monto
                                    AND m.empleado_id = f.empleado_id AND m.rendicion_fecha = f.rendicion_fecha
                                    AND m.rendicion_transportista_id = f.rendicion_transportista_id
                                    AND m.rendicion_sucursal_id = f.rendicion_sucursal_id)
                         AND NOT EXISTS (SELECT 1 FROM empleado_movimientos r WHERE r.revierte_id = f.movimiento_id)
                    ELSE EXISTS (SELECT 1 FROM gastos gs
                                  WHERE gs.id = f.gasto_id AND gs.anulado_at IS NULL AND gs.monto_total = f.monto
                                    AND gs.origen_pago = 'rendicion' AND gs.rendicion_fecha = f.rendicion_fecha
                                    AND gs.rendicion_transportista_id = f.rendicion_transportista_id
                                    AND gs.sucursal_id = f.rendicion_sucursal_id) END;
    v_fallas := v_fallas || pg_temp.chk(v_n = 0, format('20 %s lineas vivas sin su movimiento o su gasto', v_n));
    SELECT count(*) INTO v_n FROM rendicion_faltantes f
     WHERE f.anulada_at IS NOT NULL
       AND NOT CASE WHEN f.causal = 'empleado'
                    THEN EXISTS (SELECT 1 FROM empleado_movimientos r WHERE r.revierte_id = f.movimiento_id AND r.monto = f.monto)
                    ELSE EXISTS (SELECT 1 FROM gastos gs WHERE gs.id = f.gasto_id AND gs.anulado_at IS NOT NULL) END;
    v_fallas := v_fallas || pg_temp.chk(v_n = 0, format('20 %s lineas anuladas con lo suyo vivo', v_n));
    SELECT count(*) INTO v_n FROM empleado_movimientos m
     WHERE m.tipo = 'faltante' AND m.revierte_id IS NULL
       AND NOT EXISTS (SELECT 1 FROM rendicion_faltantes f WHERE f.movimiento_id = m.id);
    v_fallas := v_fallas || pg_temp.chk(v_n = 0, format('20 %s faltantes sin linea', v_n));
    SELECT count(*) INTO v_n FROM rendicion_faltantes;
    v_fallas := v_fallas || pg_temp.chk(v_n >= 9, format('20 el ensayo dejo solo %s lineas: algun caso no corrio', v_n));
    v_j := pg_temp.audit(v_a1, v_t);
    v_ch_fin := (v_j->>'critical_high_en_rojo')::int;
    v_fallas := v_fallas || pg_temp.chk(v_ch_fin = v_ch_ini, format('20 critical_high_en_rojo paso de %s a %s: %s', v_ch_ini, v_ch_fin,
                  (SELECT array_agg(c->>'id') FROM jsonb_array_elements(v_j->'checks') c
                    WHERE (c->>'ok')::boolean IS FALSE AND c->>'severidad' IN ('critical', 'high'))));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('20 · error: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------- veredicto --
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · gastos 6 (hoy %, lineas %, anuladas %): casos 1 a 20; critical_high_en_rojo % al empezar y % al final',
    v_hoy, (SELECT count(*) FROM rendicion_faltantes), (SELECT count(*) FROM rendicion_faltantes WHERE anulada_at IS NOT NULL),
    v_ch_ini, v_ch_fin;
END
$ensayo$;
