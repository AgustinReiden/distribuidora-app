-- Ensayo de la migracion gastos_3_rendicion (entrega 2 de 5 de gastos: los
-- gastos pagados con la plata de una rendicion).
--
-- Corre contra prod SIN dejar rastro: un unico DO que termina SIEMPRE en RAISE
-- EXCEPTION, asi que todo lo que escribe (vehiculo, gastos, pedido, controles)
-- se deshace. Lo que tiene que fallar corre en un subbloque que se revierte solo.
--
--   'ENSAYO OK …'    -> todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' -> lista de lo que no se cumplio.
--
-- Antes de la migracion tiene que FALLAR (no existe obtener_gastos_rendiciones);
-- despues, pasar:
--
--   BEGIN; SET LOCAL lock_timeout = '5s';
--   <migrations/413_gastos_3_rendicion.sql>
--   <este archivo>
--   ROLLBACK;
--
-- Cada RPC se llama COMO EL FRONT (pg_temp.como): SET LOCAL ROLE authenticated,
-- los claims del usuario y el header x-sucursal-id, con los argumentos por
-- nombre como PostgREST y el payload que arman ModalGasto (todas las claves de
-- GuardarGastoPayload) y el cierre ({vistos, guardar, quitar}). Los vistos son
-- los pares {id, updated_at} que devuelve obtener_gastos_rendiciones, como los
-- toma el modal del cierre.
--
-- Todo corre en UNA transaccion, asi que now() es el mismo en cada escritura:
-- para que un updated_at o un cierre sea "de antes", el ensayo lo fuerza a mano
-- (pasos 9c y 11).
--
-- Usuarios elegidos en runtime (perfiles + usuario_sucursales):
--   A     · una sucursal activa con un admin activo que tiene SOLO esa sucursal,
--           un encargado activo y dos transportistas activos (de rol base o con
--           el rol extra en A: hoy Taco Pozo tiene uno de cada)
--   adm   · ese admin; enc, el encargado; t (de rol base) y t2, los transportistas
--   ajeno · un perfil activo sin la sucursal A
--   B     · otra sucursal activa
--   D     · el dia mas reciente antes de hoy en que t no tiene fila de control
--           ni nada en la grilla (sin pagos ni entregas)
--   D2    · otro dia sin fila de control para t
--
--   1  pendiente: un combustible de 8000 de la rendicion (t, D) anda; el
--      resumen da total_gastos 8000 y cantidad_gastos 1 sin pagos ese dia
--   1b otro dia, compartido y otra sucursal: un compartido de 2500 en (t, D2)
--      suma en D2 y no en D, y el encargado lo lee en la rendicion; un gasto de
--      (t, D) en B no suma en A
--   2  lectura: obtener_gastos_rendiciones como t lo trae con rubro, km_tablero
--      y updated_at; como t2 no; t pidiendo a t2 da 42501
--   3  validaciones: sin dia, dia futuro, transportista sin la sucursal y
--      'empleado' fallan con su mensaje; con oficina las columnas van en NULL
--   4  cierre: adm confirma con vistos [g1] y un gasto nuevo de 5000 ->
--      confirmada, 2 vivos, total_gastos 13000
--   5  cerrada, desde Gastos: editar, anular, mover a la oficina, cargar uno
--      nuevo y traer uno de la oficina fallan con el mensaje de «Editar cierre»
--   6  editar cierre: g1 a 9000 y g2 quitado -> g2 anulado con el motivo y
--      adm, total 9000, sigue confirmada, g1 conserva sus km
--   7  concurrencia: vistos sin el gasto que cargo otro -> 'cambiaron…' sin
--      tocar estado ni gastos; un gasto de otra rendicion en quitar, uno anulado
--      en guardar, uno repetido y cuatro formatos malos fallan. Mover un gasto
--      entre dos rendiciones pendientes (los dos locks) lo pasa de una a otra
--   8  encargado: reconfirma con guardar [] y gastos del admin vivos; si manda
--      o quita uno del admin, falla con el prefijo del rubro
--   8b el chofer perdio la sucursal: "Editar cierre" cambia su gasto viejo, y
--      uno nuevo falla con 'Ese transportista no es de la sucursal del gasto'
--   9  reapertura: en disconformidad g1 se edita desde Gastos; resuelta, no;
--      desmarcada, otra vez si, y sus gastos siguen restando
--   9b reapertura por un cambio de entrega (trg_pedidos_anular_control): con
--      la rendicion cerrada g1 no se edita; movida la entrega a otro dia, si
--   9c edicion entre la lectura y el cierre: el cierre con los vistos de antes
--      se rechaza sin cambios; y con un updated_at viejo, tambien
--   10 firmas y permisos: la firma vieja y rendicion_gastos no existen, ninguna
--      funcion la nombra, anon no ejecuta nada nuevo, authenticated no ejecuta
--      los helpers, SEG-A limpio
--   11 GASTO-A en 0 tras lo legitimo, y critical_high_en_rojo igual que al
--      empezar. Con las marcas forzadas (controlada hace 2 h, resuelta hace 1 h,
--      g1 cambiado hace 90 min y lo demas hace 3 h): resuelta da 0, confirmada 1
--
--   psql "$DATABASE_URL" -f scripts/test-gastos-3.sql

DO $ensayo$
DECLARE
  v_fallas  text[] := '{}';
  v_hoy     date := public._tablero_hoy();
  v_a       bigint;
  v_b       bigint;
  v_adm     uuid;
  v_enc     uuid;
  v_t       uuid;
  v_t2      uuid;
  v_ajeno   uuid;
  v_d       date;
  v_d2      date;
  r_comb    bigint;
  r_peaje   bigint;
  v_veh     bigint;
  g1        bigint;
  g2        bigint;
  g3        bigint;
  gx        bigint;
  g_of      bigint;
  g_comp    bigint;
  v_cli     bigint;
  v_prod    bigint;
  v_ped     bigint;
  v_base    jsonb;
  v_peaje   jsonb;
  v_vj      jsonb;
  v_txt     text;
  v_j       jsonb;
  v_n       int;
  v_ch_ini  int;
  v_ch_fin  int;
  g         record;
BEGIN
  SET LOCAL lock_timeout = '5s';

  IF to_regprocedure('public.obtener_gastos_rendiciones(date,date,uuid)') IS NULL
     OR to_regprocedure('public._guardar_gasto(jsonb,boolean)') IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · no existen obtener_gastos_rendiciones ni _guardar_gasto (falta la migracion gastos_3)';
  END IF;

  -- --------------------------------------------------------- contexto ---
  SELECT s.id INTO v_a FROM sucursales s
   WHERE s.activa
     AND EXISTS (SELECT 1 FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                  WHERE us.sucursal_id = s.id AND pf.rol = 'encargado' AND pf.activo)
     AND (SELECT count(*) FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
           WHERE us.sucursal_id = s.id AND pf.activo
             AND (pf.rol = 'transportista'
                  OR EXISTS (SELECT 1 FROM perfil_roles pr WHERE pr.usuario_id = pf.id AND pr.sucursal_id = s.id
                                AND pr.rol = 'transportista'))) >= 2
     AND EXISTS (SELECT 1 FROM perfiles pf WHERE pf.rol = 'admin' AND pf.activo
                  AND (SELECT array_agg(us.sucursal_id) FROM usuario_sucursales us WHERE us.usuario_id = pf.id) = ARRAY[s.id])
   ORDER BY s.id LIMIT 1;
  SELECT s.id INTO v_b FROM sucursales s WHERE s.activa AND s.id IS DISTINCT FROM v_a ORDER BY s.id LIMIT 1;
  SELECT pf.id INTO v_adm FROM perfiles pf WHERE pf.rol = 'admin' AND pf.activo
     AND (SELECT array_agg(us.sucursal_id) FROM usuario_sucursales us WHERE us.usuario_id = pf.id) = ARRAY[v_a]
   ORDER BY pf.id LIMIT 1;
  SELECT us.usuario_id INTO v_enc FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
   WHERE us.sucursal_id = v_a AND pf.rol = 'encargado' AND pf.activo ORDER BY us.usuario_id LIMIT 1;
  -- t de rol base; t2, otro de rol base o uno con el rol extra en A (#1179).
  SELECT us.usuario_id INTO v_t FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
   WHERE us.sucursal_id = v_a AND pf.rol = 'transportista' AND pf.activo ORDER BY us.usuario_id LIMIT 1;
  SELECT us.usuario_id INTO v_t2 FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
   WHERE us.sucursal_id = v_a AND pf.activo AND us.usuario_id <> v_t
     AND (pf.rol = 'transportista'
          OR EXISTS (SELECT 1 FROM perfil_roles pr WHERE pr.usuario_id = pf.id AND pr.sucursal_id = v_a
                        AND pr.rol = 'transportista'))
   ORDER BY (pf.rol = 'transportista') DESC, us.usuario_id LIMIT 1;
  SELECT pf.id INTO v_ajeno FROM perfiles pf
   WHERE pf.activo AND NOT EXISTS (SELECT 1 FROM usuario_sucursales us WHERE us.usuario_id = pf.id AND us.sucursal_id = v_a)
   ORDER BY pf.id LIMIT 1;
  SELECT id INTO r_comb FROM gasto_rubros WHERE nombre = 'Combustible' AND activo;
  SELECT id INTO r_peaje FROM gasto_rubros WHERE nombre = 'Peajes y estacionamiento' AND activo;
  IF v_a IS NULL OR v_b IS NULL OR v_adm IS NULL OR v_enc IS NULL OR v_t IS NULL OR v_t2 IS NULL OR v_ajeno IS NULL
     OR r_comb IS NULL OR r_peaje IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin contexto: A %, B %, adm %, enc %, t %, t2 %, ajeno %, rubros % %',
      v_a, v_b, v_adm, v_enc, v_t, v_t2, v_ajeno, r_comb, r_peaje;
  END IF;

  -- Como el front: rol authenticated, claims y header. Devuelve el resultado
  -- como texto; un error se propaga al subbloque que llama.
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

  -- Lo que tiene que fallar con un mensaje que contenga p_espera. Si anda, lo
  -- deshace (P0098) y lo anota.
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

  -- El SQLSTATE con que falla, o 'OK' (y lo deshace).
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

  CREATE FUNCTION pg_temp.gg(p jsonb)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.guardar_gasto(p_gasto => %L::jsonb)', p);
  $f$;

  CREATE FUNCTION pg_temp.ag(p_id bigint, p_motivo text)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.anular_gasto(p_gasto_id => %s, p_motivo => %L)', p_id, p_motivo);
  $f$;

  -- confirmar_rendicion como lo llama useRendiciones: por nombre.
  CREATE FUNCTION pg_temp.cr(p_fecha date, p_t uuid, p_estado text, p_cambios jsonb)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.confirmar_rendicion(p_fecha => %L::date, p_transportista_id => %L::uuid, '
                  || 'p_estado => %L, p_observaciones => NULL, p_gastos_rendicion => %L::jsonb)',
                  p_fecha, p_t, p_estado, p_cambios);
  $f$;

  CREATE FUNCTION pg_temp.lista(p_user uuid, p_suc bigint, p_fecha date, p_t uuid)
  RETURNS jsonb LANGUAGE sql AS $f$
    SELECT pg_temp.como(p_user, p_suc, format(
      'SELECT public.obtener_gastos_rendiciones(p_fecha_desde => %L::date, p_fecha_hasta => %L::date, '
      || 'p_transportista_id => %L::uuid)', p_fecha, p_fecha, p_t))::jsonb;
  $f$;

  -- Los vistos del modal del cierre: {id, updated_at} de lo que devuelve
  -- obtener_gastos_rendiciones, tal cual.
  CREATE FUNCTION pg_temp.vistos(p_user uuid, p_suc bigint, p_fecha date, p_t uuid)
  RETURNS jsonb LANGUAGE sql AS $f$
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', e->'id', 'updated_at', e->'updated_at')), '[]'::jsonb)
      FROM jsonb_array_elements(pg_temp.lista(p_user, p_suc, p_fecha, p_t)) e;
  $f$;

  -- Una fila del resumen como jsonb (o null).
  CREATE FUNCTION pg_temp.resumen(p_user uuid, p_suc bigint, p_fecha date, p_t uuid)
  RETURNS jsonb LANGUAGE sql AS $f$
    SELECT pg_temp.como(p_user, p_suc, format(
      'SELECT to_jsonb(x) FROM public.obtener_resumen_rendiciones(p_fecha_desde => %L::date, p_fecha_hasta => %L::date, '
      || 'p_transportista_id => %L::uuid) x', p_fecha, p_fecha, p_t))::jsonb;
  $f$;

  CREATE FUNCTION pg_temp.tot(p_user uuid, p_suc bigint, p_fecha date, p_t uuid)
  RETURNS numeric LANGUAGE sql AS $f$
    SELECT COALESCE((pg_temp.resumen(p_user, p_suc, p_fecha, p_t)->>'total_gastos')::numeric, 0);
  $f$;

  CREATE FUNCTION pg_temp.vivos(p_suc bigint, p_fecha date, p_t uuid)
  RETURNS bigint[] LANGUAGE sql AS $f$
    SELECT COALESCE(array_agg(id ORDER BY id), '{}') FROM public.gastos
     WHERE origen_pago = 'rendicion' AND sucursal_id = p_suc AND rendicion_fecha = p_fecha
       AND rendicion_transportista_id = p_t AND anulado_at IS NULL;
  $f$;

  CREATE FUNCTION pg_temp.estado_control(p_suc bigint, p_fecha date, p_t uuid)
  RETURNS text LANGUAGE sql AS $f$
    SELECT COALESCE((SELECT estado FROM public.rendiciones_control
                      WHERE sucursal_id = p_suc AND fecha = p_fecha AND transportista_id = p_t), 'pendiente');
  $f$;

  -- auditoria_integridad() pide un admin en los claims: los del ultimo como()
  -- pueden ser de otro.
  CREATE FUNCTION pg_temp.audit(p_adm uuid, p_suc bigint)
  RETURNS jsonb LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_adm, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
    RETURN public.auditoria_integridad();
  END
  $f$;

  CREATE FUNCTION pg_temp.gasto_a(p_adm uuid, p_suc bigint)
  RETURNS int LANGUAGE sql AS $f$
    SELECT (c->>'violaciones')::int FROM jsonb_array_elements(pg_temp.audit(p_adm, p_suc)->'checks') c
     WHERE c->>'id' = 'GASTO-A';
  $f$;

  -- Canarios de los helpers: sin esto, un falla() que no muerde daria un OK vacio.
  IF cardinality(pg_temp.falla('canario', v_enc, v_a, 'SELECT 1', 'x')) <> 1
     OR cardinality(pg_temp.falla('canario', v_enc, v_a, 'SELECT 1/0', 'by zero')) <> 0
     OR cardinality(pg_temp.falla('canario', v_enc, v_a, 'SELECT 1/0', 'otro mensaje')) <> 1
     OR pg_temp.estado(v_enc, v_a, 'SELECT 1/0') <> '22012'
     OR pg_temp.estado(v_enc, v_a, 'SELECT 1') <> 'OK'
     OR pg_temp.como(v_t, v_a, 'SELECT current_user || '' '' || auth.uid() || '' '' || public.current_sucursal_id()')
        IS DISTINCT FROM format('authenticated %s %s', v_t, v_a)
     OR current_user = 'authenticated' THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · los helpers del ensayo no hacen lo que dicen';
  END IF;

  v_ch_ini := (pg_temp.audit(v_adm, v_a)->>'critical_high_en_rojo')::int;

  -- El dia D: sin control para t y fuera de la grilla (sin pagos ni entregas).
  FOR v_n IN 1 .. 120 LOOP
    IF NOT EXISTS (SELECT 1 FROM rendiciones_control WHERE sucursal_id = v_a AND transportista_id = v_t AND fecha = v_hoy - v_n)
       AND pg_temp.resumen(v_adm, v_a, v_hoy - v_n, v_t) IS NULL THEN
      v_d := v_hoy - v_n;
      EXIT;
    END IF;
  END LOOP;
  -- D2: otro dia sin control para t (puede tener cobros).
  FOR v_n IN 1 .. 120 LOOP
    IF v_hoy - v_n <> v_d
       AND NOT EXISTS (SELECT 1 FROM rendiciones_control WHERE sucursal_id = v_a AND transportista_id = v_t AND fecha = v_hoy - v_n) THEN
      v_d2 := v_hoy - v_n;
      EXIT;
    END IF;
  END LOOP;
  IF v_d IS NULL OR v_d2 IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin contexto: D % y D2 % para t % en los ultimos 120 dias', v_d, v_d2, v_t;
  END IF;

  v_veh := pg_temp.como(v_adm, v_a,
             format('SELECT public.guardar_vehiculo(%L::jsonb)', '{"patente":"ENS3001","descripcion":"Ensayo gastos 3"}'))::bigint;

  -- Lo que arma ModalGasto: todas las claves de GuardarGastoPayload.
  v_base := jsonb_build_object(
    'fecha', v_d, 'rubro_id', r_comb, 'monto_total', 8000, 'comprobante', 'ticket', 'comprobante_numero', NULL,
    'alicuota_iva', NULL, 'iva', 0, 'percepcion_iva', 0, 'percepcion_iibb', 0, 'otros_impuestos', 0,
    'sucursal_id', v_a, 'compartido', false, 'vehiculo_id', v_veh, 'litros', 10, 'km_tablero', 184230,
    'mes_imputado', to_char(date_trunc('month', v_d), 'YYYY-MM-DD'), 'repartir_meses', 1,
    'origen_pago', 'rendicion', 'rendicion_transportista_id', v_t, 'rendicion_fecha', v_d, 'observacion', NULL);
  v_peaje := v_base || jsonb_build_object('rubro_id', r_peaje, 'monto_total', 5000, 'vehiculo_id', NULL,
                                          'litros', NULL, 'km_tablero', NULL);

  -- ======================================================= 1 · pendiente ===
  BEGIN
    g1 := pg_temp.como(v_adm, v_a, pg_temp.gg(v_base))::bigint;
    SELECT * INTO g FROM gastos WHERE id = g1;
    v_fallas := v_fallas || pg_temp.chk(g.origen_pago = 'rendicion' AND g.rendicion_transportista_id = v_t
                                        AND g.rendicion_fecha = v_d,
                  format('1 g1 quedo con %s / %s / %s', g.origen_pago, g.rendicion_transportista_id, g.rendicion_fecha));
    v_j := pg_temp.resumen(v_adm, v_a, v_d, v_t);
    v_fallas := v_fallas || pg_temp.chk((v_j->>'total_gastos')::numeric = 8000 AND (v_j->>'cantidad_gastos')::int = 1
                                        AND (v_j->>'total_general')::numeric = 0 AND v_j->>'estado' = 'pendiente',
                  format('1 resumen de (t, D): %s', v_j));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('1 · error: %s', SQLERRM);
  END;

  -- ================================= 1b · otro dia, compartido, otra sucursal ===
  BEGIN
    g_comp := pg_temp.como(v_adm, v_a, pg_temp.gg(v_peaje || jsonb_build_object(
                'compartido', true, 'monto_total', 2500, 'fecha', v_d2, 'rendicion_fecha', v_d2,
                'mes_imputado', to_char(date_trunc('month', v_d2), 'YYYY-MM-DD'))))::bigint;
    -- Un gasto de la rendicion (t, D) cargado en B: va directo, el transportista
    -- no es de B y la RPC lo rechazaria. Lo que se prueba es la lectura.
    INSERT INTO gastos (sucursal_id, compartido, fecha, rubro_id, monto_total, comprobante, iva, percepcion_iva,
                        percepcion_iibb, otros_impuestos, mes_imputado, repartir_meses, origen_pago,
                        rendicion_transportista_id, rendicion_fecha, creado_por)
    VALUES (v_b, false, v_d, r_peaje, 7000, 'ticket', 0, 0, 0, 0, date_trunc('month', v_d)::date, 1, 'rendicion',
            v_t, v_d, v_adm);
    v_fallas := v_fallas || pg_temp.chk(pg_temp.tot(v_adm, v_a, v_d, v_t) = 8000,
                  format('1b total_gastos de (t, D) da %s con un gasto de otro dia y uno de otra sucursal (esperado 8000)',
                         pg_temp.tot(v_adm, v_a, v_d, v_t)));
    v_j := pg_temp.resumen(v_adm, v_a, v_d2, v_t);
    v_fallas := v_fallas || pg_temp.chk((v_j->>'total_gastos')::numeric = 2500 AND (v_j->>'cantidad_gastos')::int = 1,
                  format('1b el compartido de (t, D2) no suma en su rendicion: %s', v_j));
    v_j := pg_temp.lista(v_enc, v_a, v_d2, NULL);
    v_fallas := v_fallas || pg_temp.chk(jsonb_array_length(v_j) = 1 AND (v_j->0->>'id')::bigint = g_comp
                                        AND (v_j->0->>'compartido')::boolean,
                  format('1b el encargado no ve el compartido en la rendicion: %s', v_j));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('1b · error: %s', SQLERRM);
  END;

  -- ========================================================= 2 · lectura ===
  BEGIN
    v_j := pg_temp.lista(v_t, v_a, v_d, NULL);
    v_fallas := v_fallas || pg_temp.chk(jsonb_array_length(v_j) = 1 AND (v_j->0->>'id')::bigint = g1
                                        AND v_j->0->'rubro'->>'nombre' = 'Combustible'
                                        AND (v_j->0->>'km_tablero')::int = 184230
                                        AND v_j->0->'vehiculo'->>'patente' = 'ENS3001'
                                        AND v_j->0->>'rendicion_transportista_id' = v_t::text
                                        AND v_j->0->>'rendicion_fecha' = v_d::text
                                        AND (v_j->0->>'monto_total')::numeric = 8000
                                        AND (v_j->0->>'updated_at')::timestamptz = (SELECT updated_at FROM gastos WHERE id = g1)
                                        AND v_j->0 ? 'mes_fin' AND v_j->0 ? 'creado_por',
                  format('2 t lee %s', v_j));
    v_j := pg_temp.lista(v_t2, v_a, v_d, NULL);
    v_fallas := v_fallas || pg_temp.chk(v_j = '[]'::jsonb, format('2 t2 lee %s (esperado [])', v_j));
    v_txt := pg_temp.estado(v_t, v_a, format(
             'SELECT public.obtener_gastos_rendiciones(p_fecha_desde => %L::date, p_fecha_hasta => %L::date, p_transportista_id => %L::uuid)',
             v_d, v_d, v_t2));
    v_fallas := v_fallas || pg_temp.chk(v_txt = '42501', format('2 t pidiendo los de t2 da %s (esperado 42501)', v_txt));
    v_j := pg_temp.como(v_enc, v_a, format(
             'SELECT public.obtener_gastos_rendiciones(p_fecha_desde => %L::date, p_fecha_hasta => %L::date)', v_d, v_d))::jsonb;
    v_fallas := v_fallas || pg_temp.chk(jsonb_array_length(v_j) = 1, format('2 el encargado lee %s gastos (esperado 1)', jsonb_array_length(v_j)));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('2 · error: %s', SQLERRM);
  END;

  -- ==================================================== 3 · validaciones ===
  BEGIN
    v_fallas := v_fallas || pg_temp.falla('3 rendicion sin dia', v_adm, v_a,
                  pg_temp.gg(v_base || '{"rendicion_fecha": null}'), 'Elegí de qué rendición salió la plata: el transportista y el día');
    v_fallas := v_fallas || pg_temp.falla('3 rendicion sin transportista', v_adm, v_a,
                  pg_temp.gg(v_base || '{"rendicion_transportista_id": null}'), 'Elegí de qué rendición salió la plata');
    v_fallas := v_fallas || pg_temp.falla('3 rendicion de mañana', v_adm, v_a,
                  pg_temp.gg(v_base || jsonb_build_object('rendicion_fecha', v_hoy + 1)),
                  'La rendición no puede ser de un día que todavía no llegó');
    v_fallas := v_fallas || pg_temp.falla('3 transportista sin la sucursal', v_adm, v_a,
                  pg_temp.gg(v_base || jsonb_build_object('rendicion_transportista_id', v_ajeno)),
                  'Ese transportista no es de la sucursal del gasto');
    v_fallas := v_fallas || pg_temp.falla('3 empleado', v_adm, v_a,
                  pg_temp.gg(v_base || '{"origen_pago": "empleado"}'),
                  'Todavía no se puede pagar un gasto con la plata de un empleado');
    -- La oficina descarta lo que venga de rendicion.
    g_of := pg_temp.como(v_adm, v_a, pg_temp.gg(v_base || '{"origen_pago": "oficina"}'))::bigint;
    SELECT * INTO g FROM gastos WHERE id = g_of;
    v_fallas := v_fallas || pg_temp.chk(g.origen_pago = 'oficina' AND g.rendicion_transportista_id IS NULL AND g.rendicion_fecha IS NULL,
                  format('3 un gasto de la oficina quedo con %s / %s', g.rendicion_transportista_id, g.rendicion_fecha));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('3 · error: %s', SQLERRM);
  END;

  -- ========================================================== 4 · cierre ===
  BEGIN
    PERFORM pg_temp.como(v_adm, v_a, pg_temp.cr(v_d, v_t, 'confirmada',
              jsonb_build_object('vistos', pg_temp.vistos(v_adm, v_a, v_d, v_t),
                                 'guardar', jsonb_build_array(v_peaje), 'quitar', '[]'::jsonb)));
    SELECT max(id) INTO g2 FROM gastos WHERE id <> g1 AND origen_pago = 'rendicion' AND rendicion_transportista_id = v_t
       AND rendicion_fecha = v_d AND sucursal_id = v_a;
    v_j := pg_temp.resumen(v_adm, v_a, v_d, v_t);
    v_fallas := v_fallas || pg_temp.chk(pg_temp.estado_control(v_a, v_d, v_t) = 'confirmada'
                                        AND pg_temp.vivos(v_a, v_d, v_t) = ARRAY[g1, g2]
                                        AND (v_j->>'total_gastos')::numeric = 13000 AND (v_j->>'cantidad_gastos')::int = 2,
                  format('4 tras el cierre: %s, vivos %s, resumen %s', pg_temp.estado_control(v_a, v_d, v_t),
                         pg_temp.vivos(v_a, v_d, v_t), v_j));
    SELECT * INTO g FROM gastos WHERE id = g2;
    v_fallas := v_fallas || pg_temp.chk(g.monto_total = 5000 AND g.rubro_id = r_peaje AND g.creado_por = v_adm,
                  format('4 el gasto nuevo del cierre quedo %s / %s / %s', g.monto_total, g.rubro_id, g.creado_por));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('4 · error: %s', SQLERRM);
  END;

  -- ========================================================= 5 · cerrada ===
  BEGIN
    v_fallas := v_fallas || pg_temp.falla('5 editar g1 desde Gastos', v_adm, v_a,
                  pg_temp.gg(v_base || jsonb_build_object('id', g1, 'monto_total', 8100)),
                  'Este gasto es de una rendición cerrada: se cambia desde «Editar cierre» en Rendiciones');
    v_fallas := v_fallas || pg_temp.falla('5 anular g1 desde Gastos', v_adm, v_a, pg_temp.ag(g1, 'ensayo'),
                  'Este gasto es de una rendición cerrada: se quita desde «Editar cierre» en Rendiciones');
    v_fallas := v_fallas || pg_temp.falla('5 mover g1 a la oficina', v_adm, v_a,
                  pg_temp.gg(v_base || jsonb_build_object('id', g1, 'origen_pago', 'oficina',
                                                          'rendicion_transportista_id', NULL, 'rendicion_fecha', NULL)),
                  'Este gasto es de una rendición cerrada: se cambia desde «Editar cierre» en Rendiciones');
    v_fallas := v_fallas || pg_temp.falla('5 cargar uno nuevo a (t, D)', v_adm, v_a, pg_temp.gg(v_peaje),
                  'Esa rendición ya está cerrada: el gasto se carga desde «Editar cierre» en Rendiciones');
    v_fallas := v_fallas || pg_temp.falla('5 mover el de la oficina a (t, D)', v_adm, v_a,
                  pg_temp.gg(v_base || jsonb_build_object('id', g_of)),
                  'Esa rendición ya está cerrada: el gasto se carga desde «Editar cierre» en Rendiciones');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('5 · error: %s', SQLERRM);
  END;

  -- ================================================== 6 · editar cierre ===
  BEGIN
    PERFORM pg_temp.como(v_adm, v_a, pg_temp.cr(v_d, v_t, 'confirmada',
              jsonb_build_object('vistos', pg_temp.vistos(v_adm, v_a, v_d, v_t),
                                 'guardar', jsonb_build_array(v_base || jsonb_build_object('id', g1, 'monto_total', 9000)),
                                 'quitar', jsonb_build_array(g2))));
    SELECT * INTO g FROM gastos WHERE id = g2;
    v_fallas := v_fallas || pg_temp.chk(g.anulado_at IS NOT NULL AND g.motivo_anulacion = 'Quitado en el cierre de la rendición'
                                        AND g.anulado_por = v_adm,
                  format('6 g2 quedo %s / %s / %s', g.anulado_at, g.motivo_anulacion, g.anulado_por));
    v_j := pg_temp.resumen(v_adm, v_a, v_d, v_t);
    v_fallas := v_fallas || pg_temp.chk((v_j->>'total_gastos')::numeric = 9000 AND (v_j->>'cantidad_gastos')::int = 1
                                        AND v_j->>'estado' = 'confirmada',
                  format('6 resumen tras editar el cierre: %s', v_j));
    v_fallas := v_fallas || pg_temp.chk((SELECT km FROM vehiculo_km WHERE gasto_id = g1) = 184230,
                  '6 g1 perdio su lectura de km al editarlo en el cierre');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('6 · error: %s', SQLERRM);
  END;

  -- ==================================================== 7 · concurrencia ===
  BEGIN
    -- El modal de este cierre leyo solo g1; otro agrega un gasto desde "Editar cierre".
    v_vj := pg_temp.vistos(v_adm, v_a, v_d, v_t);
    PERFORM pg_temp.como(v_adm, v_a, pg_temp.cr(v_d, v_t, 'confirmada',
              jsonb_build_object('vistos', v_vj,
                                 'guardar', jsonb_build_array(v_peaje || '{"monto_total": 3000}'))));
    g3 := (SELECT max(id) FROM gastos WHERE origen_pago = 'rendicion' AND rendicion_transportista_id = v_t
             AND rendicion_fecha = v_d AND sucursal_id = v_a AND anulado_at IS NULL AND id <> g1);
    v_fallas := v_fallas || pg_temp.falla('7 cierre con vistos viejos', v_adm, v_a,
                  pg_temp.cr(v_d, v_t, 'disconformidad',
                    jsonb_build_object('vistos', v_vj,
                                       'guardar', jsonb_build_array(v_base || jsonb_build_object('id', g1, 'monto_total', 9999)),
                                       'quitar', '[]'::jsonb)),
                  'Los gastos de esta rendición cambiaron mientras la cerrabas: tocá Refrescar y volvé a abrir el cierre');
    v_fallas := v_fallas || pg_temp.chk(pg_temp.estado_control(v_a, v_d, v_t) = 'confirmada'
                                        AND (SELECT monto_total FROM gastos WHERE id = g1) = 9000
                                        AND pg_temp.vivos(v_a, v_d, v_t) = ARRAY[g1, g3],
                  format('7 el cierre rechazado dejo %s, g1 en %s, vivos %s', pg_temp.estado_control(v_a, v_d, v_t),
                         (SELECT monto_total FROM gastos WHERE id = g1), pg_temp.vivos(v_a, v_d, v_t)));
    -- Un gasto de la rendicion de t2 del mismo dia.
    gx := pg_temp.como(v_adm, v_a, pg_temp.gg(v_peaje || jsonb_build_object('rendicion_transportista_id', v_t2)))::bigint;
    v_vj := pg_temp.vistos(v_adm, v_a, v_d, v_t);
    v_fallas := v_fallas || pg_temp.falla('7 quitar un gasto de otra rendicion', v_adm, v_a,
                  pg_temp.cr(v_d, v_t, 'confirmada', jsonb_build_object('vistos', v_vj, 'quitar', jsonb_build_array(gx))),
                  'Ese gasto no es de esta rendición o ya está anulado');
    v_fallas := v_fallas || pg_temp.falla('7 editar uno anulado', v_adm, v_a,
                  pg_temp.cr(v_d, v_t, 'confirmada',
                    jsonb_build_object('vistos', v_vj, 'guardar', jsonb_build_array(v_peaje || jsonb_build_object('id', g2)))),
                  'Ese gasto no es de esta rendición o ya está anulado');
    v_fallas := v_fallas || pg_temp.falla('7 un gasto en quitar y en guardar', v_adm, v_a,
                  pg_temp.cr(v_d, v_t, 'confirmada',
                    jsonb_build_object('vistos', v_vj, 'quitar', jsonb_build_array(g3),
                                       'guardar', jsonb_build_array(v_peaje || jsonb_build_object('id', g3)))),
                  'Un gasto viene dos veces en el cierre');
    v_fallas := v_fallas || pg_temp.falla('7 formato: una lista', v_adm, v_a,
                  pg_temp.cr(v_d, v_t, 'confirmada', '[]'::jsonb), 'Los gastos del cierre vienen con un formato inválido');
    v_fallas := v_fallas || pg_temp.falla('7 formato: vistos con texto', v_adm, v_a,
                  pg_temp.cr(v_d, v_t, 'confirmada', '{"vistos": ["x"]}'::jsonb), 'Los gastos del cierre vienen con un formato inválido');
    v_fallas := v_fallas || pg_temp.falla('7 formato: vistos solo con ids', v_adm, v_a,
                  pg_temp.cr(v_d, v_t, 'confirmada', jsonb_build_object('vistos', jsonb_build_array(g1, g3))),
                  'Los gastos del cierre vienen con un formato inválido');
    v_fallas := v_fallas || pg_temp.falla('7 formato: updated_at que no es fecha', v_adm, v_a,
                  pg_temp.cr(v_d, v_t, 'confirmada', jsonb_build_object('vistos',
                    jsonb_build_array(jsonb_build_object('id', g1, 'updated_at', 'ayer')))),
                  'Los gastos del cierre vienen con un formato inválido');
    v_fallas := v_fallas || pg_temp.chk((SELECT anulado_at FROM gastos WHERE id = gx) IS NULL,
                  '7 el gasto de la otra rendicion quedo anulado');
    -- Mover gx de (t2, D) a (t, D2), las dos pendientes: bloquea las dos.
    PERFORM pg_temp.como(v_adm, v_a, pg_temp.gg(v_peaje || jsonb_build_object(
              'id', gx, 'rendicion_transportista_id', v_t, 'rendicion_fecha', v_d2)));
    SELECT * INTO g FROM gastos WHERE id = gx;
    v_fallas := v_fallas || pg_temp.chk(g.rendicion_transportista_id = v_t AND g.rendicion_fecha = v_d2
                                        AND pg_temp.tot(v_adm, v_a, v_d2, v_t) = 7500
                                        AND pg_temp.tot(v_adm, v_a, v_d, v_t2) = 0,
                  format('7 mover gx entre rendiciones: quedo en %s / %s, (t, D2) suma %s, (t2, D) suma %s',
                         g.rendicion_transportista_id, g.rendicion_fecha, pg_temp.tot(v_adm, v_a, v_d2, v_t),
                         pg_temp.tot(v_adm, v_a, v_d, v_t2)));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('7 · error: %s', SQLERRM);
  END;

  -- ======================================================= 8 · encargado ===
  BEGIN
    v_vj := pg_temp.vistos(v_enc, v_a, v_d, v_t);
    PERFORM pg_temp.como(v_enc, v_a, pg_temp.cr(v_d, v_t, 'confirmada',
              jsonb_build_object('vistos', v_vj, 'guardar', '[]'::jsonb, 'quitar', '[]'::jsonb)));
    v_fallas := v_fallas || pg_temp.chk(pg_temp.estado_control(v_a, v_d, v_t) = 'confirmada'
                                        AND (SELECT controlada_por FROM rendiciones_control
                                              WHERE sucursal_id = v_a AND fecha = v_d AND transportista_id = v_t) = v_enc,
                  '8 el encargado no pudo reconfirmar sin tocar los gastos del admin');
    v_fallas := v_fallas || pg_temp.falla('8 el encargado manda un gasto del admin', v_enc, v_a,
                  pg_temp.cr(v_d, v_t, 'confirmada',
                    jsonb_build_object('vistos', v_vj,
                                       'guardar', jsonb_build_array(v_base || jsonb_build_object('id', g1, 'monto_total', 9500)))),
                  'En el gasto de Combustible: El encargado sólo edita los gastos que cargó');
    v_fallas := v_fallas || pg_temp.falla('8 el encargado quita un gasto del admin', v_enc, v_a,
                  pg_temp.cr(v_d, v_t, 'confirmada', jsonb_build_object('vistos', v_vj, 'quitar', jsonb_build_array(g3))),
                  'En el gasto de Peajes y estacionamiento: El encargado sólo anula los gastos que cargó');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('8 · error: %s', SQLERRM);
  END;

  -- ================================= 8b · el chofer perdio la sucursal ===
  -- En un subbloque que se deshace (P0097): t vuelve a tener la sucursal.
  BEGIN
    DELETE FROM usuario_sucursales WHERE usuario_id = v_t AND sucursal_id = v_a;
    PERFORM pg_temp.como(v_adm, v_a, pg_temp.cr(v_d, v_t, 'confirmada',
              jsonb_build_object('vistos', pg_temp.vistos(v_adm, v_a, v_d, v_t),
                                 'guardar', jsonb_build_array(v_base || jsonb_build_object('id', g1, 'monto_total', 9050)))));
    v_fallas := v_fallas || pg_temp.chk((SELECT monto_total FROM gastos WHERE id = g1) = 9050,
                  '8b "Editar cierre" no pudo cambiar el gasto viejo de un chofer sin la sucursal');
    v_fallas := v_fallas || pg_temp.falla('8b un gasto nuevo para un chofer sin la sucursal', v_adm, v_a,
                  pg_temp.cr(v_d, v_t, 'confirmada',
                    jsonb_build_object('vistos', pg_temp.vistos(v_adm, v_a, v_d, v_t), 'guardar', jsonb_build_array(v_peaje))),
                  'En el gasto de Peajes y estacionamiento: Ese transportista no es de la sucursal del gasto');
    RAISE EXCEPTION USING ERRCODE = 'P0097';
  EXCEPTION
    WHEN SQLSTATE 'P0097' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('8b · error: %s', SQLERRM);
  END;

  -- ====================================================== 9 · reapertura ===
  BEGIN
    PERFORM pg_temp.como(v_adm, v_a, pg_temp.cr(v_d, v_t, 'disconformidad',
              jsonb_build_object('vistos', pg_temp.vistos(v_adm, v_a, v_d, v_t))));
    PERFORM pg_temp.como(v_adm, v_a, pg_temp.gg(v_base || jsonb_build_object('id', g1, 'monto_total', 9100)));
    v_fallas := v_fallas || pg_temp.chk((SELECT monto_total FROM gastos WHERE id = g1) = 9100,
                  '9 en disconformidad g1 no se edito desde Gastos');
    PERFORM pg_temp.como(v_adm, v_a, format(
              'SELECT public.resolver_rendicion(p_fecha => %L::date, p_transportista_id => %L::uuid, p_observaciones => %L)',
              v_d, v_t, 'ensayo gastos 3'));
    v_fallas := v_fallas || pg_temp.falla('9 resuelta: editar g1 desde Gastos', v_adm, v_a,
                  pg_temp.gg(v_base || jsonb_build_object('id', g1, 'monto_total', 9200)),
                  'Este gasto es de una rendición cerrada: se cambia');
    PERFORM pg_temp.como(v_adm, v_a, format(
              'SELECT public.desmarcar_rendicion_controlada(p_fecha => %L::date, p_transportista_id => %L::uuid)', v_d, v_t));
    PERFORM pg_temp.como(v_adm, v_a, pg_temp.gg(v_base || jsonb_build_object('id', g1, 'monto_total', 9300)));
    v_j := pg_temp.resumen(v_adm, v_a, v_d, v_t);
    v_fallas := v_fallas || pg_temp.chk((SELECT monto_total FROM gastos WHERE id = g1) = 9300
                                        AND v_j->>'estado' = 'pendiente' AND (v_j->>'total_gastos')::numeric = 12300,
                  format('9 desmarcada: g1 en %s, resumen %s (esperado pendiente y 12300)',
                         (SELECT monto_total FROM gastos WHERE id = g1), v_j));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('9 · error: %s', SQLERRM);
  END;

  -- ====================== 9b · reapertura por un cambio de entrega (#1175) ===
  BEGIN
    -- Setup como postgres, con el molde de test-rendicion-congelada-1248.sql:
    -- una entrega de t el dia D.
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_a::text)::text, true);
    PERFORM set_config('app.omitir_minimo_pedido', '1', true);
    INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
    VALUES ('ZZ ensayo gastos 3', 'ZZ ensayo gastos 3', 'Ensayo gastos 3', v_a) RETURNING id INTO v_cli;
    INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
    VALUES ('ZZ ensayo gastos 3', 100, 1000, 60, v_a) RETURNING id INTO v_prod;
    v_j := public.crear_pedido_completo(v_cli, 100, v_adm,
             jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1, 'precio_unitario', 100)),
             'ensayo gastos 3');
    IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'no se pudo crear el pedido: %', v_j;
    END IF;
    v_ped := (v_j->>'pedido_id')::bigint;
    UPDATE pedidos SET estado = 'entregado', transportista_id = v_t,
                       fecha_entrega = (v_d::text || ' 12:00:00 America/Argentina/Buenos_Aires')::timestamptz
     WHERE id = v_ped;

    PERFORM pg_temp.como(v_adm, v_a, pg_temp.cr(v_d, v_t, 'confirmada',
              jsonb_build_object('vistos', pg_temp.vistos(v_adm, v_a, v_d, v_t))));
    v_fallas := v_fallas || pg_temp.falla('9b cerrada: editar g1 desde Gastos', v_adm, v_a,
                  pg_temp.gg(v_base || jsonb_build_object('id', g1, 'monto_total', 9350)),
                  'Este gasto es de una rendición cerrada: se cambia');
    -- La entrega pasa a otro dia: el trigger borra el control de D.
    UPDATE pedidos SET fecha_entrega = fecha_entrega - interval '1 day' WHERE id = v_ped;
    PERFORM pg_temp.como(v_adm, v_a, pg_temp.gg(v_base || jsonb_build_object('id', g1, 'monto_total', 9400)));
    v_fallas := v_fallas || pg_temp.chk(pg_temp.estado_control(v_a, v_d, v_t) = 'pendiente'
                                        AND (SELECT monto_total FROM gastos WHERE id = g1) = 9400
                                        AND pg_temp.tot(v_adm, v_a, v_d, v_t) = 12400,
                  format('9b reabierta por la entrega: %s, g1 en %s, total %s (esperado pendiente, 9400 y 12400)',
                         pg_temp.estado_control(v_a, v_d, v_t), (SELECT monto_total FROM gastos WHERE id = g1),
                         pg_temp.tot(v_adm, v_a, v_d, v_t)));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('9b · error: %s', SQLERRM);
  END;

  -- ============================ 9c · edicion entre la lectura y el cierre ===
  BEGIN
    -- g1 se escribio "antes" (en una transaccion now() no cambia).
    UPDATE gastos SET updated_at = now() - interval '1 hour' WHERE id = g1;
    v_vj := pg_temp.vistos(v_adm, v_a, v_d, v_t);
    -- Con el modal abierto, otro lo edita desde Gastos.
    PERFORM pg_temp.como(v_adm, v_a, pg_temp.gg(v_base || jsonb_build_object('id', g1, 'monto_total', 18000)));
    v_fallas := v_fallas || pg_temp.falla('9c cierre con un gasto editado despues de leerlo', v_enc, v_a,
                  pg_temp.cr(v_d, v_t, 'confirmada', jsonb_build_object('vistos', v_vj)),
                  'Los gastos de esta rendición cambiaron mientras la cerrabas: tocá Refrescar y volvé a abrir el cierre');
    v_fallas := v_fallas || pg_temp.chk(pg_temp.estado_control(v_a, v_d, v_t) = 'pendiente'
                                        AND (SELECT monto_total FROM gastos WHERE id = g1) = 18000,
                  format('9c el cierre rechazado dejo %s y g1 en %s', pg_temp.estado_control(v_a, v_d, v_t),
                         (SELECT monto_total FROM gastos WHERE id = g1)));
    -- Los vistos de ahora, pero con el updated_at de g1 viejo.
    v_vj := (SELECT jsonb_agg(CASE WHEN (e->>'id')::bigint = g1
                                   THEN jsonb_build_object('id', g1, 'updated_at', '2000-01-01T00:00:00+00:00')
                                   ELSE e END)
               FROM jsonb_array_elements(pg_temp.vistos(v_adm, v_a, v_d, v_t)) e);
    v_fallas := v_fallas || pg_temp.falla('9c cierre con un updated_at viejo', v_adm, v_a,
                  pg_temp.cr(v_d, v_t, 'confirmada', jsonb_build_object('vistos', v_vj)),
                  'Los gastos de esta rendición cambiaron mientras la cerrabas');
    v_fallas := v_fallas || pg_temp.chk(pg_temp.estado_control(v_a, v_d, v_t) = 'pendiente',
                  '9c el cierre con un updated_at viejo cerro la rendicion');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('9c · error: %s', SQLERRM);
  END;

  -- ============================================== 10 · firmas y permisos ===
  BEGIN
    v_fallas := v_fallas || pg_temp.chk(to_regprocedure('public.confirmar_rendicion(date,uuid,text,text,jsonb)') IS NULL
                                        AND (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
                                                AND proname = 'confirmar_rendicion') = 1,
                  '10 la firma vieja de confirmar_rendicion sigue o hay mas de una');
    v_fallas := v_fallas || pg_temp.chk(to_regclass('public.rendicion_gastos') IS NULL, '10 rendicion_gastos sigue existiendo');
    v_fallas := v_fallas || pg_temp.chk(NOT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace
                                                       AND prosrc ~ 'rendicion_gastos'),
                  '10 una funcion de public sigue nombrando rendicion_gastos');
    FOR g IN SELECT f FROM unnest(ARRAY['public._rendicion_clave(uuid,date,bigint)', 'public._rendicion_bloquear(bigint[])',
                                        'public._guardar_gasto(jsonb,boolean)', 'public._anular_gasto(bigint,text,boolean)',
                                        'public.confirmar_rendicion(date,uuid,text,jsonb,text)',
                                        'public.obtener_gastos_rendiciones(date,date,uuid)']) f LOOP
      IF has_function_privilege('anon', g.f, 'EXECUTE') THEN
        v_fallas := v_fallas || format('10 anon ejecuta %s', g.f);
      END IF;
      IF g.f ~ '^public\._' AND has_function_privilege('authenticated', g.f, 'EXECUTE') THEN
        v_fallas := v_fallas || format('10 authenticated ejecuta %s', g.f);
      END IF;
      IF g.f !~ '^public\._' AND NOT has_function_privilege('authenticated', g.f, 'EXECUTE') THEN
        v_fallas := v_fallas || format('10 authenticated no ejecuta %s', g.f);
      END IF;
    END LOOP;
    SELECT count(*) INTO v_n FROM public.auditoria_definer_sin_rol()
     WHERE firma ~ '^(confirmar_rendicion|resolver_rendicion|obtener_resumen_rendiciones|obtener_gastos_rendiciones|guardar_gasto|anular_gasto|_guardar_gasto|_anular_gasto|_rendicion_clave|_rendicion_bloquear)\(';
    v_fallas := v_fallas || pg_temp.chk(v_n = 0, format('10 %s funciones de esta migracion en rojo en SEG-A', v_n));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('10 · error: %s', SQLERRM);
  END;

  -- ========================================================= 11 · GASTO-A ===
  BEGIN
    PERFORM pg_temp.como(v_adm, v_a, pg_temp.cr(v_d, v_t, 'confirmada',
              jsonb_build_object('vistos', pg_temp.vistos(v_adm, v_a, v_d, v_t))));
    v_n := pg_temp.gasto_a(v_adm, v_a);
    v_fallas := v_fallas || pg_temp.chk(v_n = 0, format('11 GASTO-A da %s despues de todo lo legitimo (esperado 0)', v_n));
    v_ch_fin := (pg_temp.audit(v_adm, v_a)->>'critical_high_en_rojo')::int;
    v_fallas := v_fallas || pg_temp.chk(v_ch_fin = v_ch_ini,
                  format('11 critical_high_en_rojo paso de %s a %s', v_ch_ini, v_ch_fin));

    -- Resuelta: controlada hace 2 h, resuelta hace 1 h, g1 cambiado hace 90 min
    -- (en la disconformidad) y lo demas de la rendicion hace 3 h -> 0.
    PERFORM pg_temp.como(v_adm, v_a, pg_temp.cr(v_d, v_t, 'disconformidad',
              jsonb_build_object('vistos', pg_temp.vistos(v_adm, v_a, v_d, v_t))));
    PERFORM pg_temp.como(v_adm, v_a, format(
              'SELECT public.resolver_rendicion(p_fecha => %L::date, p_transportista_id => %L::uuid, p_observaciones => %L)',
              v_d, v_t, 'ensayo gastos 3'));
    UPDATE rendiciones_control SET controlada_at = now() - interval '2 hours', resuelta_at = now() - interval '1 hour'
     WHERE sucursal_id = v_a AND fecha = v_d AND transportista_id = v_t;
    UPDATE gastos SET updated_at = now() - interval '3 hours'
     WHERE origen_pago = 'rendicion' AND sucursal_id = v_a AND rendicion_transportista_id = v_t AND rendicion_fecha = v_d;
    UPDATE gastos SET updated_at = now() - interval '90 minutes' WHERE id = g1;
    v_n := pg_temp.gasto_a(v_adm, v_a);
    v_fallas := v_fallas || pg_temp.chk(v_n = 0, format('11 GASTO-A da %s en una resuelta con g1 anterior a resuelta_at (esperado 0)', v_n));

    -- Confirmada con controlada hace 2 h: g1 (hace 90 min) es posterior -> 1.
    PERFORM pg_temp.como(v_adm, v_a, pg_temp.cr(v_d, v_t, 'confirmada',
              jsonb_build_object('vistos', pg_temp.vistos(v_adm, v_a, v_d, v_t))));
    UPDATE rendiciones_control SET controlada_at = now() - interval '2 hours'
     WHERE sucursal_id = v_a AND fecha = v_d AND transportista_id = v_t;
    v_n := pg_temp.gasto_a(v_adm, v_a);
    v_fallas := v_fallas || pg_temp.chk(v_n = 1, format('11 GASTO-A da %s en una confirmada con g1 posterior al cierre (esperado 1)', v_n));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('11 · error: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------- veredicto --
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · gastos 3 (A=%, B=%, D=%, D2=%): pendiente con 8000 en la grilla sin pagos; otro dia, compartido y otra sucursal; lectura del transportista con rubro, km y updated_at y 42501 al pedir otro; validaciones de dia/futuro/sucursal/empleado; cierre con un gasto nuevo (13000); rendicion cerrada intocable desde Gastos; editar cierre (9000, quitado con motivo); vistos viejos rechazados sin cambios, ids ajenos/anulados/repetidos y formatos malos; mover entre dos pendientes; encargado reconfirma sin tocar lo del admin; chofer sin la sucursal; reapertura por disconformidad, desmarcar y cambio de entrega; edicion entre lectura y cierre y updated_at viejo rechazados; firmas y permisos; GASTO-A 0 legitimo, 0 resuelta y 1 confirmada con marcas forzadas; critical_high_en_rojo % al empezar y % al final',
    v_a, v_b, v_d, v_d2, v_ch_ini, v_ch_fin;
END
$ensayo$;
