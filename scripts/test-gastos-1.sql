-- Ensayo de la migracion gastos_1_tablas_y_rpcs (entrega 1 de 5 de gastos:
-- vehiculos, rubros y gastos).
--
-- Corre contra prod SIN dejar rastro: un unico DO que termina SIEMPRE en RAISE
-- EXCEPTION, asi que todo lo que escribe (vehiculos, rubros, gastos, km) se
-- deshace. Lo que tiene que fallar corre en un subbloque que se revierte solo.
--
--   'ENSAYO OK …'    -> todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' -> lista de lo que no se cumplio.
--
-- Antes de la migracion tiene que FALLAR (no existen las tablas ni las RPCs);
-- despues, pasar:
--
--   BEGIN; SET LOCAL lock_timeout = '5s';
--   <migrations/411_gastos_1_tablas_y_rpcs.sql>
--   <este archivo>
--   ROLLBACK;
--
-- Cada RPC y cada lectura con RLS se llama COMO EL FRONT (pg_temp.como): SET
-- LOCAL ROLE authenticated, los claims del usuario y el header x-sucursal-id.
--
-- Usuarios elegidos en runtime (perfiles + usuario_sucursales):
--   A      · una sucursal activa con un encargado activo y un admin activo que
--            tiene SOLO esa sucursal (hoy, Taco Pozo)
--   adm_a  · admin de solo A; adm_a2, otro admin de solo A si lo hay
--   enc    · encargado activo de A
--   B      · otra sucursal activa con un admin de solo B (adm_b)
--   todas  · admin activo con todas las sucursales activas
--
--   1  semilla: los 18 rubros del spec con grupo y marcas
--   2  vehiculos: patente normalizada, repetida falla, RLS (el encargado de A
--      lee vehiculos y km; B no), km manual
--   3  gasto minimo: ticket de 8500 -> costo y neto 8500, mes_fin = mes
--   4  factura A: 50000 con IVA 8677,69 -> costo 41322,31; M con percepciones
--      y otros impuestos; ticket con IVA, neto <= 0 y negativos fallan
--   5  combustible con vehiculo, litros y km -> fila de vehiculo_km 'carga';
--      editar los km la actualiza; Libreria con litros falla
--   6  reparto: seguro 1.320.000 en 12 desde 10/2026 -> mes_fin 2027-09-01 y
--      12 cuotas de 110000; 100 en 3 desde 11/2026 -> 33,33 / 33,33 / 33,34
--      cruzando de año; referencia: 20,15 en 2 da 10,08 y 10,07
--   7  permisos: admin de una sucursal en otra, encargado compartido,
--      encargado edita/anula lo del admin -> fallan; lo suyo, anda. El
--      encargado lee el km de su combustible; editarlo con el mismo
--      km_tablero lo deja, sin km_tablero lo borra. adm_a no comparte un gasto
--      del encargado; uno suyo, si
--   8  compartido de adm_a: adm_b lo lee y no lo toca, adm_a2 no lo cambia,
--      el de todas si, el encargado no lo ve. Un compartido con vehiculo: el
--      de todas, en B, ve su km y lo conserva al editar; mandarlo a B falla.
--      El encargado no ve la lectura de un compartido de B
--   9  anulacion: sin motivo falla; anulado fuera de gastos_por_mes y sin km
--   10 origen: rendicion / empleado -> 'Todavía no se puede pagar…'
--   11 rubros: encargado, "Sueldos…", grupo con gastos, nombre repetido y
--      sacarle litros y km a Combustible fallan
--   12 permisos de funciones y tablas, SEG-A y auditoria_grants_tablas
--
--   psql "$DATABASE_URL" -f scripts/test-gastos-1.sql

DO $ensayo$
DECLARE
  v_fallas  text[] := '{}';
  v_a       bigint;
  v_b       bigint;
  v_adm_a   uuid;
  v_adm_a2  uuid;
  v_adm_b   uuid;
  v_todas   uuid;
  v_enc     uuid;
  v_prev    uuid;
  r_lib     bigint;
  r_comb    bigint;
  r_seg     bigint;
  r_var     bigint;
  r_hon     bigint;
  r_tel     bigint;
  r_nuevo   bigint;
  v_veh     bigint;
  g_lib     bigint;
  g_fa      bigint;
  g_fm      bigint;
  g_comb    bigint;
  g_seg     bigint;
  g_cien    bigint;
  g_comp    bigint;
  g_enc     bigint;
  g_enc_comb bigint;
  g_propio  bigint;
  g_comp_comb bigint;
  g_comp_b  bigint;
  v_veh_b   bigint;
  v_base    jsonb;
  v_txt     text;
  v_n       int;
  g         record;
  f         text;
  v_t       regclass;
  v_gr      jsonb;
BEGIN
  SET LOCAL lock_timeout = '5s';

  IF to_regclass('public.gastos') IS NULL OR to_regclass('public.gasto_rubros') IS NULL
     OR to_regclass('public.vehiculos') IS NULL OR to_regclass('public.vehiculo_km') IS NULL
     OR to_regprocedure('public.guardar_gasto(jsonb)') IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · no existen las tablas ni las RPCs de gastos (falta la migracion gastos_1)';
  END IF;

  -- --------------------------------------------------------- contexto ---
  SELECT s.id INTO v_a FROM sucursales s
   WHERE s.activa
     AND EXISTS (SELECT 1 FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                  WHERE us.sucursal_id = s.id AND pf.rol = 'encargado' AND pf.activo)
     AND EXISTS (SELECT 1 FROM perfiles pf WHERE pf.rol = 'admin' AND pf.activo
                  AND (SELECT array_agg(us.sucursal_id) FROM usuario_sucursales us WHERE us.usuario_id = pf.id) = ARRAY[s.id])
   ORDER BY s.id LIMIT 1;
  SELECT s.id INTO v_b FROM sucursales s
   WHERE s.activa AND s.id IS DISTINCT FROM v_a
     AND EXISTS (SELECT 1 FROM perfiles pf WHERE pf.rol = 'admin' AND pf.activo
                  AND (SELECT array_agg(us.sucursal_id) FROM usuario_sucursales us WHERE us.usuario_id = pf.id) = ARRAY[s.id])
   ORDER BY s.id LIMIT 1;
  SELECT pf.id INTO v_adm_a FROM perfiles pf WHERE pf.rol = 'admin' AND pf.activo
     AND (SELECT array_agg(us.sucursal_id) FROM usuario_sucursales us WHERE us.usuario_id = pf.id) = ARRAY[v_a]
   ORDER BY pf.id LIMIT 1;
  SELECT pf.id INTO v_adm_a2 FROM perfiles pf WHERE pf.rol = 'admin' AND pf.activo AND pf.id <> v_adm_a
     AND (SELECT array_agg(us.sucursal_id) FROM usuario_sucursales us WHERE us.usuario_id = pf.id) = ARRAY[v_a]
   ORDER BY pf.id LIMIT 1;
  SELECT pf.id INTO v_adm_b FROM perfiles pf WHERE pf.rol = 'admin' AND pf.activo
     AND (SELECT array_agg(us.sucursal_id) FROM usuario_sucursales us WHERE us.usuario_id = pf.id) = ARRAY[v_b]
   ORDER BY pf.id LIMIT 1;
  SELECT pf.id INTO v_todas FROM perfiles pf WHERE pf.rol = 'admin' AND pf.activo
     AND NOT EXISTS (SELECT 1 FROM sucursales s WHERE s.activa
                      AND NOT EXISTS (SELECT 1 FROM usuario_sucursales us WHERE us.usuario_id = pf.id AND us.sucursal_id = s.id))
   ORDER BY pf.id LIMIT 1;
  SELECT us.usuario_id INTO v_enc FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
   WHERE us.sucursal_id = v_a AND pf.rol = 'encargado' AND pf.activo ORDER BY us.usuario_id LIMIT 1;
  SELECT us.usuario_id INTO v_prev FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
   WHERE us.sucursal_id = v_a AND pf.rol = 'preventista' AND pf.activo ORDER BY us.usuario_id LIMIT 1;
  IF v_a IS NULL OR v_b IS NULL OR v_adm_a IS NULL OR v_adm_b IS NULL OR v_todas IS NULL OR v_enc IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin contexto: A %, B %, adm_a %, adm_b %, todas %, enc %',
      v_a, v_b, v_adm_a, v_adm_b, v_todas, v_enc;
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

  CREATE FUNCTION pg_temp.chk(p_ok boolean, p_que text)
  RETURNS text[] LANGUAGE sql AS $f$
    SELECT CASE WHEN p_ok IS TRUE THEN '{}'::text[] ELSE ARRAY[p_que] END;
  $f$;

  CREATE FUNCTION pg_temp.gg(p jsonb)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.guardar_gasto(%L::jsonb)', p);
  $f$;

  -- Canarios de los helpers: sin esto, un falla() que no muerde daria un OK vacio.
  IF cardinality(pg_temp.falla('canario', v_enc, v_a, 'SELECT 1', 'x')) <> 1
     OR cardinality(pg_temp.falla('canario', v_enc, v_a, 'SELECT 1/0', 'by zero')) <> 0
     OR cardinality(pg_temp.falla('canario', v_enc, v_a, 'SELECT 1/0', 'otro mensaje')) <> 1
     OR pg_temp.como(v_enc, v_a, 'SELECT current_user || '' '' || auth.uid() || '' '' || public.current_sucursal_id()')
        IS DISTINCT FROM format('authenticated %s %s', v_enc, v_a)
     OR current_user = 'authenticated' THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · los helpers del ensayo no hacen lo que dicen';
  END IF;

  -- ========================================================= 1 · semilla ===
  BEGIN
    SELECT count(*) INTO v_n FROM gasto_rubros;
    v_fallas := v_fallas || pg_temp.chk(v_n = 18, format('1 la semilla tiene %s rubros (esperado 18)', v_n));
    FOR g IN
      WITH esperado(nombre, grupo, litros, reparto, mes_ant, palabras) AS (VALUES
        ('Combustible', 'vehiculos', true, NULL::int, false, 'nafta gasoil gnc'),
        ('Seguro', 'vehiculos', false, 12, false, NULL),
        ('Patente', 'vehiculos', false, NULL, false, NULL),
        ('Mantenimiento y service', 'vehiculos', false, NULL, false, 'taller mecanico'),
        ('Peajes y estacionamiento', 'vehiculos', false, NULL, false, NULL),
        ('Alquiler', 'inmueble', false, NULL, false, NULL),
        ('Expensas', 'inmueble', false, NULL, false, NULL),
        ('Luz, agua y gas', 'inmueble', false, NULL, false, 'servicios'),
        ('Ingresos brutos', 'impuestos', false, NULL, true, 'iibb rentas dgr'),
        ('Tasa municipal', 'impuestos', false, NULL, false, 'cisi'),
        ('Librería', 'administracion', false, NULL, false, 'papeleria'),
        ('Teléfono e internet', 'administracion', false, NULL, false, 'celular'),
        ('Limpieza', 'administracion', false, NULL, false, NULL),
        ('Honorarios del contador', 'administracion', false, NULL, false, 'estudio contable'),
        ('Oficina central (parte de la distribuidora)', 'administracion', false, NULL, false, NULL),
        ('Vehículo', 'bienes_de_uso', false, 60, false, 'camioneta utilitario'),
        ('Equipos y muebles', 'bienes_de_uso', false, 36, false, 'heladera estanteria'),
        ('Varios', 'otros', false, NULL, false, NULL))
      SELECT e.nombre FROM esperado e
       WHERE NOT EXISTS (SELECT 1 FROM gasto_rubros r
                          WHERE r.nombre = e.nombre AND r.grupo = e.grupo AND r.pide_litros_km = e.litros
                            AND r.reparto_sugerido_meses IS NOT DISTINCT FROM e.reparto
                            AND r.sugiere_mes_anterior = e.mes_ant
                            AND r.palabras_busqueda IS NOT DISTINCT FROM e.palabras AND r.activo)
    LOOP
      v_fallas := v_fallas || format('1 el rubro %s no esta como dice el spec', g.nombre);
    END LOOP;
    SELECT id INTO r_lib FROM gasto_rubros WHERE nombre = 'Librería';
    SELECT id INTO r_comb FROM gasto_rubros WHERE nombre = 'Combustible';
    SELECT id INTO r_seg FROM gasto_rubros WHERE nombre = 'Seguro';
    SELECT id INTO r_var FROM gasto_rubros WHERE nombre = 'Varios';
    SELECT id INTO r_hon FROM gasto_rubros WHERE nombre = 'Honorarios del contador';
    SELECT id INTO r_tel FROM gasto_rubros WHERE nombre = 'Teléfono e internet';
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('1 · error: %s', SQLERRM);
  END;

  v_base := jsonb_build_object('fecha', '2026-10-28', 'rubro_id', r_lib, 'monto_total', 8500,
              'comprobante', 'ticket', 'sucursal_id', v_a, 'compartido', false,
              'mes_imputado', '2026-10-01', 'repartir_meses', 1, 'origen_pago', 'oficina');

  -- ======================================================= 2 · vehiculos ===
  BEGIN
    v_veh := pg_temp.como(v_adm_a, v_a,
               format('SELECT public.guardar_vehiculo(%L::jsonb)', '{"patente":" ac 456-ef","descripcion":"Partner"}'))::bigint;
    SELECT * INTO g FROM vehiculos WHERE id = v_veh;
    v_fallas := v_fallas || pg_temp.chk(g.patente = 'AC456EF' AND g.sucursal_id = v_a AND g.activo AND g.descripcion = 'Partner',
                  format('2 vehiculo guardado como %s / %s / %s (esperado AC456EF en la sucursal %s)', g.patente, g.sucursal_id, g.activo, v_a));
    v_fallas := v_fallas || pg_temp.falla('2 patente repetida', v_adm_a, v_a,
                  format('SELECT public.guardar_vehiculo(%L::jsonb)', '{"patente":"AC 456 EF","descripcion":"Otra"}'),
                  'Ya hay un vehículo con la patente AC456EF');
    v_fallas := v_fallas || pg_temp.falla('2 el encargado da de alta un vehiculo', v_enc, v_a,
                  format('SELECT public.guardar_vehiculo(%L::jsonb)', '{"patente":"AB123CD","descripcion":"Kangoo"}'),
                  'Sólo un admin');
    v_fallas := v_fallas || pg_temp.falla('2 adm_b edita un vehiculo de A', v_adm_b, v_b,
                  format('SELECT public.guardar_vehiculo(%L::jsonb)',
                         jsonb_build_object('id', v_veh, 'patente', 'AC456EF', 'descripcion', 'Robada')),
                  'no es de una de tus sucursales');
    v_txt := pg_temp.como(v_enc, v_a, format('SELECT count(*) FROM public.vehiculos WHERE id = %s', v_veh));
    v_fallas := v_fallas || pg_temp.chk(v_txt = '1', format('2 el encargado de A ve %s vehiculos (esperado 1)', v_txt));
    v_txt := pg_temp.como(v_adm_b, v_b, format('SELECT count(*) FROM public.vehiculos WHERE id = %s', v_veh));
    v_fallas := v_fallas || pg_temp.chk(v_txt = '0', format('2 adm_b ve %s vehiculos de A (esperado 0)', v_txt));
    -- km manual
    PERFORM pg_temp.como(v_adm_a, v_a, format('SELECT public.registrar_km_vehiculo(%s, %L, %s)', v_veh, '2026-10-01', 184000));
    SELECT count(*) INTO v_n FROM vehiculo_km
     WHERE vehiculo_id = v_veh AND origen = 'manual' AND km = 184000 AND gasto_id IS NULL AND sucursal_id = v_a;
    v_fallas := v_fallas || pg_temp.chk(v_n = 1, '2 registrar_km_vehiculo no dejo la lectura manual');
    v_fallas := v_fallas || pg_temp.falla('2 el encargado registra km', v_enc, v_a,
                  format('SELECT public.registrar_km_vehiculo(%s, %L, %s)', v_veh, '2026-10-02', 184100), 'Sólo un admin');
    v_fallas := v_fallas || pg_temp.falla('2 adm_b registra km de A', v_adm_b, v_b,
                  format('SELECT public.registrar_km_vehiculo(%s, %L, %s)', v_veh, '2026-10-02', 184100), 'no es de esta sucursal');
    v_txt := pg_temp.como(v_adm_a, v_a, format('SELECT count(*) FROM public.vehiculo_km WHERE vehiculo_id = %s', v_veh));
    v_fallas := v_fallas || pg_temp.chk(v_txt = '1', format('2 adm_a ve %s lecturas de km (esperado 1)', v_txt));
    v_txt := pg_temp.como(v_enc, v_a, format('SELECT count(*) FROM public.vehiculo_km WHERE vehiculo_id = %s', v_veh));
    v_fallas := v_fallas || pg_temp.chk(v_txt = '1', format('2 el encargado ve %s lecturas de km (esperado 1)', v_txt));
    v_txt := pg_temp.como(v_adm_b, v_b, format('SELECT count(*) FROM public.vehiculo_km WHERE vehiculo_id = %s', v_veh));
    v_fallas := v_fallas || pg_temp.chk(v_txt = '0', format('2 adm_b ve %s lecturas de km de A (esperado 0)', v_txt));
    v_txt := pg_temp.como(v_enc, v_a, 'SELECT count(*) FROM public.gasto_rubros');
    v_fallas := v_fallas || pg_temp.chk(v_txt = '18', format('2 el encargado ve %s rubros (esperado 18)', v_txt));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('2 · error: %s', SQLERRM);
  END;

  -- =================================================== 3 · gasto minimo ===
  BEGIN
    g_lib := pg_temp.como(v_adm_a, v_a, pg_temp.gg(v_base))::bigint;
    SELECT * INTO g FROM gastos WHERE id = g_lib;
    v_fallas := v_fallas || pg_temp.chk(
      g.costo = 8500 AND g.neto = 8500 AND g.mes_fin = g.mes_imputado AND g.mes_imputado = '2026-10-01'
      AND g.iva = 0 AND g.alicuota_iva IS NULL AND g.creado_por = v_adm_a AND g.sucursal_id = v_a
      AND NOT g.compartido AND g.origen_pago = 'oficina' AND g.anulado_at IS NULL,
      format('3 gasto minimo: costo %s, neto %s, mes %s, fin %s, creado_por %s', g.costo, g.neto, g.mes_imputado, g.mes_fin, g.creado_por));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('3 · error: %s', SQLERRM);
  END;

  -- ======================================================= 4 · factura A ===
  BEGIN
    g_fa := pg_temp.como(v_adm_a, v_a, pg_temp.gg(v_base || jsonb_build_object(
              'rubro_id', r_tel, 'monto_total', 50000, 'comprobante', 'factura_a', 'alicuota_iva', 21,
              'iva', 8677.69, 'comprobante_numero', '0003-00012345')))::bigint;
    SELECT * INTO g FROM gastos WHERE id = g_fa;
    v_fallas := v_fallas || pg_temp.chk(g.costo = 41322.31 AND g.neto = 41322.31 AND g.alicuota_iva = 21,
                  format('4 factura A: costo %s, neto %s (esperado 41322.31)', g.costo, g.neto));
    -- M con percepcion de IVA y otros impuestos (combustible con ITC)
    g_fm := pg_temp.como(v_adm_a, v_a, pg_temp.gg(v_base || jsonb_build_object(
              'rubro_id', r_tel, 'monto_total', 50000, 'comprobante', 'factura_m', 'alicuota_iva', 21,
              'iva', 8157.02, 'percepcion_iva', 1000, 'otros_impuestos', 2000)))::bigint;
    SELECT * INTO g FROM gastos WHERE id = g_fm;
    v_fallas := v_fallas || pg_temp.chk(g.costo = 40842.98 AND g.neto = 38842.98,
                  format('4 factura M: costo %s, neto %s (esperado 40842.98 y 38842.98)', g.costo, g.neto));
    v_fallas := v_fallas || pg_temp.falla('4 ticket con IVA', v_adm_a, v_a,
                  pg_temp.gg(v_base || '{"iva": 100}'), 'Sólo la factura A o M lleva IVA y percepciones');
    v_fallas := v_fallas || pg_temp.falla('4 factura A con neto 0', v_adm_a, v_a,
                  pg_temp.gg(v_base || '{"comprobante":"factura_a","monto_total":1000,"iva":1000}'),
                  'Con factura A o M el neto tiene que ser mayor a cero');
    v_fallas := v_fallas || pg_temp.falla('4 percepcion negativa', v_adm_a, v_a,
                  pg_temp.gg(v_base || '{"comprobante":"factura_a","percepcion_iibb":-5}'),
                  'Ningún importe puede ser negativo');
    v_fallas := v_fallas || pg_temp.falla('4 monto 0', v_adm_a, v_a,
                  pg_temp.gg(v_base || '{"monto_total":0}'), 'El monto tiene que ser mayor a cero');
    v_fallas := v_fallas || pg_temp.falla('4 alicuota 15', v_adm_a, v_a,
                  pg_temp.gg(v_base || '{"comprobante":"factura_a","alicuota_iva":15,"iva":100}'), 'alícuota');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('4 · error: %s', SQLERRM);
  END;

  -- ===================================================== 5 · combustible ===
  BEGIN
    g_comb := pg_temp.como(v_adm_a, v_a, pg_temp.gg(v_base || jsonb_build_object(
                'rubro_id', r_comb, 'monto_total', 60000, 'vehiculo_id', v_veh, 'litros', 38.5, 'km_tablero', 184230)))::bigint;
    SELECT count(*) INTO v_n FROM vehiculo_km
     WHERE gasto_id = g_comb AND vehiculo_id = v_veh AND km = 184230 AND origen = 'carga'
       AND fecha = '2026-10-28' AND sucursal_id = v_a;
    v_fallas := v_fallas || pg_temp.chk(v_n = 1, '5 el combustible no dejo su lectura de km (carga, 184230)');
    v_fallas := v_fallas || pg_temp.chk((SELECT litros FROM gastos WHERE id = g_comb) = 38.5, '5 los litros no quedaron en 38.5');
    -- editar los km actualiza la misma fila
    PERFORM pg_temp.como(v_adm_a, v_a, pg_temp.gg(v_base || jsonb_build_object(
              'id', g_comb, 'rubro_id', r_comb, 'monto_total', 60000, 'vehiculo_id', v_veh, 'litros', 38.5, 'km_tablero', 184300)));
    SELECT count(*) INTO v_n FROM vehiculo_km WHERE gasto_id = g_comb;
    v_fallas := v_fallas || pg_temp.chk(v_n = 1 AND (SELECT km FROM vehiculo_km WHERE gasto_id = g_comb) = 184300,
                  '5 editar los km no actualizo la lectura del gasto');
    v_fallas := v_fallas || pg_temp.falla('5 libreria con litros', v_adm_a, v_a,
                  pg_temp.gg(v_base || '{"litros": 10}'), 'Este rubro no lleva litros ni km');
    v_fallas := v_fallas || pg_temp.falla('5 km sin vehiculo', v_adm_a, v_a,
                  pg_temp.gg(v_base || jsonb_build_object('rubro_id', r_comb, 'km_tablero', 1000)), 'elegí el vehículo');
    -- un gasto sin km borra la lectura que tenia (y la vuelve a crear)
    PERFORM pg_temp.como(v_adm_a, v_a, pg_temp.gg(v_base || jsonb_build_object(
              'id', g_comb, 'rubro_id', r_comb, 'monto_total', 60000, 'vehiculo_id', v_veh, 'litros', 38.5)));
    v_fallas := v_fallas || pg_temp.chk(NOT EXISTS (SELECT 1 FROM vehiculo_km WHERE gasto_id = g_comb),
                  '5 sacar los km del gasto no borro su lectura');
    PERFORM pg_temp.como(v_adm_a, v_a, pg_temp.gg(v_base || jsonb_build_object(
              'id', g_comb, 'rubro_id', r_comb, 'monto_total', 60000, 'vehiculo_id', v_veh, 'litros', 38.5, 'km_tablero', 184300)));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('5 · error: %s', SQLERRM);
  END;

  -- ========================================================= 6 · reparto ===
  BEGIN
    g_seg := pg_temp.como(v_adm_a, v_a, pg_temp.gg(v_base || jsonb_build_object(
               'rubro_id', r_seg, 'monto_total', 1320000, 'comprobante', 'recibo', 'repartir_meses', 12)))::bigint;
    v_fallas := v_fallas || pg_temp.chk((SELECT mes_fin FROM gastos WHERE id = g_seg) = '2027-09-01',
                  '6 el seguro en 12 no termina en 2027-09-01');
    SELECT count(*) AS n, min(mes) AS desde, max(mes) AS hasta, sum(cuota) AS suma_k, count(DISTINCT mes) AS meses
      INTO g FROM public.gastos_por_mes('2026-10-01', '2027-09-30', ARRAY[v_a]) WHERE gasto_id = g_seg;
    v_fallas := v_fallas || pg_temp.chk(g.n = 12 AND g.meses = 12 AND g.desde = '2026-10-01' AND g.hasta = '2027-09-01'
                                         AND g.suma_k = 78,
                  format('6 seguro en gastos_por_mes: %s', row_to_json(g)));
    SELECT count(*) INTO v_n FROM public.gastos_por_mes('2026-10-01', '2027-09-30', ARRAY[v_a])
     WHERE gasto_id = g_seg AND costo = 110000 AND cuotas = 12 AND grupo = 'vehiculos' AND rubro_id = r_seg
       AND sucursal_id = v_a AND NOT compartido;
    v_fallas := v_fallas || pg_temp.chk(v_n = 12, format('6 el seguro tiene %s cuotas de 110000 bien formadas (esperado 12)', v_n));

    g_cien := pg_temp.como(v_adm_a, v_a, pg_temp.gg(v_base || jsonb_build_object(
                'rubro_id', r_var, 'monto_total', 100, 'mes_imputado', '2026-11-01', 'repartir_meses', 3)))::bigint;
    SELECT string_agg(format('%s:%s:%s', mes, cuota, costo), ' ' ORDER BY mes) INTO v_txt
      FROM public.gastos_por_mes('2026-10-01', '2027-12-31', ARRAY[v_a]) WHERE gasto_id = g_cien;
    v_fallas := v_fallas || pg_temp.chk(v_txt = '2026-11-01:1:33.33 2026-12-01:2:33.33 2027-01-01:3:33.34',
                  format('6 100 en 3 desde 11/2026 da %s', v_txt));
    -- la ventana arranca en el primer dia del mes de p_desde
    SELECT string_agg(format('%s:%s', mes, costo), ' ' ORDER BY mes) INTO v_txt
      FROM public.gastos_por_mes('2026-12-15', '2026-12-31', ARRAY[v_a]) WHERE gasto_id = g_cien;
    v_fallas := v_fallas || pg_temp.chk(v_txt = '2026-12-01:33.33', format('6 ventana de diciembre da %s', v_txt));
    -- la otra sucursal no lo ve; la pura da lo del front
    v_fallas := v_fallas || pg_temp.chk(NOT EXISTS (SELECT 1 FROM public.gastos_por_mes('2026-10-01', '2027-12-31', ARRAY[v_b])
                                                     WHERE gasto_id IN (g_seg, g_cien)),
                  '6 gastos_por_mes de B devuelve gastos no compartidos de A');
    v_fallas := v_fallas || pg_temp.chk(public._gasto_cuota(100, 3, 1) = 33.33 AND public._gasto_cuota(100, 3, 3) = 33.34
                                         AND public._gasto_cuota(1320000, 12, 12) = 110000 AND public._gasto_cuota(100, 3, 4) IS NULL,
                  '6 _gasto_cuota no da lo de cuotaDeGasto');
    -- Referencia para el front: el medio centavo redondea para arriba en la
    -- primera cuota (round de numeric) y la ultima absorbe la diferencia.
    v_fallas := v_fallas || pg_temp.chk(public._gasto_cuota(20.15, 2, 1) = 10.08 AND public._gasto_cuota(20.15, 2, 2) = 10.07,
                  format('6 20,15 en 2 cuotas da %s y %s (esperado 10.08 y 10.07)',
                         public._gasto_cuota(20.15, 2, 1), public._gasto_cuota(20.15, 2, 2)));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('6 · error: %s', SQLERRM);
  END;

  -- ======================================================== 7 · permisos ===
  BEGIN
    v_fallas := v_fallas || pg_temp.falla('7 adm_a carga en B', v_adm_a, v_a,
                  pg_temp.gg(v_base || jsonb_build_object('sucursal_id', v_b)), 'No tenés asignada esa sucursal');
    v_fallas := v_fallas || pg_temp.falla('7 el encargado carga un compartido', v_enc, v_a,
                  pg_temp.gg(v_base || '{"compartido": true}'), 'Sólo un admin puede cargar un gasto compartido');
    v_fallas := v_fallas || pg_temp.falla('7 el encargado edita un gasto del admin', v_enc, v_a,
                  pg_temp.gg(v_base || jsonb_build_object('id', g_lib, 'monto_total', 1)), 'El encargado sólo edita los gastos que cargó');
    v_fallas := v_fallas || pg_temp.falla('7 el encargado anula un gasto del admin', v_enc, v_a,
                  format('SELECT public.anular_gasto(%s, %L)', g_lib, 'no es mio'), 'El encargado sólo anula los gastos que cargó');
    g_enc := pg_temp.como(v_enc, v_a, pg_temp.gg(v_base || '{"monto_total": 1000}'))::bigint;
    PERFORM pg_temp.como(v_enc, v_a, pg_temp.gg(v_base || jsonb_build_object('id', g_enc, 'monto_total', 1200)));
    v_fallas := v_fallas || pg_temp.chk((SELECT monto_total FROM gastos WHERE id = g_enc) = 1200,
                  '7 el encargado no pudo editar su gasto');
    v_txt := pg_temp.como(v_enc, v_a, format('SELECT count(*) FROM public.gastos WHERE id IN (%s, %s)', g_lib, g_enc));
    v_fallas := v_fallas || pg_temp.chk(v_txt = '2', format('7 el encargado ve %s de los gastos no compartidos de A (esperado 2)', v_txt));
    PERFORM pg_temp.como(v_enc, v_a, format('SELECT public.anular_gasto(%s, %L)', g_enc, 'Cargado dos veces'));
    SELECT * INTO g FROM gastos WHERE id = g_enc;
    v_fallas := v_fallas || pg_temp.chk(g.anulado_at IS NOT NULL AND g.anulado_por = v_enc AND g.motivo_anulacion = 'Cargado dos veces',
                  '7 el encargado no pudo anular su gasto');
    -- El encargado lee la lectura de km de su combustible (el modal la precarga
    -- al editar): con el mismo km_tablero queda, sin km_tablero se borra.
    g_enc_comb := pg_temp.como(v_enc, v_a, pg_temp.gg(v_base || jsonb_build_object(
                    'rubro_id', r_comb, 'monto_total', 40000, 'vehiculo_id', v_veh, 'litros', 30, 'km_tablero', 150000)))::bigint;
    v_txt := pg_temp.como(v_enc, v_a, format('SELECT km FROM public.vehiculo_km WHERE gasto_id = %s', g_enc_comb));
    v_fallas := v_fallas || pg_temp.chk(v_txt = '150000', format('7 el encargado lee km %s de su combustible (esperado 150000)', v_txt));
    PERFORM pg_temp.como(v_enc, v_a, pg_temp.gg(v_base || jsonb_build_object(
              'id', g_enc_comb, 'rubro_id', r_comb, 'monto_total', 40000, 'vehiculo_id', v_veh, 'litros', 30,
              'km_tablero', v_txt::integer, 'observacion', 'editado')));
    v_txt := pg_temp.como(v_enc, v_a, format('SELECT km FROM public.vehiculo_km WHERE gasto_id = %s', g_enc_comb));
    v_fallas := v_fallas || pg_temp.chk(v_txt = '150000' AND (SELECT count(*) FROM vehiculo_km WHERE gasto_id = g_enc_comb) = 1,
                  format('7 el encargado edita con el mismo km y la lectura queda en %s (esperado 150000)', v_txt));
    PERFORM pg_temp.como(v_enc, v_a, pg_temp.gg(v_base || jsonb_build_object(
              'id', g_enc_comb, 'rubro_id', r_comb, 'monto_total', 40000, 'vehiculo_id', v_veh, 'litros', 30)));
    v_txt := pg_temp.como(v_enc, v_a, format('SELECT count(*) FROM public.vehiculo_km WHERE gasto_id = %s', g_enc_comb));
    v_fallas := v_fallas || pg_temp.chk(v_txt = '0' AND NOT EXISTS (SELECT 1 FROM vehiculo_km WHERE gasto_id = g_enc_comb),
                  '7 el encargado edita sin km_tablero y la lectura no se borra');
    -- Compartir lo que cargo otro: no (anularlo y cargarlo de nuevo); lo propio, si.
    v_fallas := v_fallas || pg_temp.falla('7 adm_a comparte un gasto del encargado', v_adm_a, v_a,
                  pg_temp.gg(v_base || jsonb_build_object('id', g_enc_comb, 'rubro_id', r_comb, 'monto_total', 40000,
                                                           'vehiculo_id', v_veh, 'litros', 30, 'compartido', true)),
                  'Para compartir un gasto que cargó otro, anulalo y cargalo de nuevo como compartido');
    g_propio := pg_temp.como(v_adm_a, v_a, pg_temp.gg(v_base || '{"monto_total": 700}'))::bigint;
    PERFORM pg_temp.como(v_adm_a, v_a, pg_temp.gg(v_base || jsonb_build_object('id', g_propio, 'monto_total', 700, 'compartido', true)));
    v_fallas := v_fallas || pg_temp.chk((SELECT compartido FROM gastos WHERE id = g_propio),
                  '7 adm_a no pudo compartir un gasto que cargo el');
    IF v_prev IS NOT NULL THEN
      v_fallas := v_fallas || pg_temp.falla('7 un preventista carga un gasto', v_prev, v_a, pg_temp.gg(v_base), 'Sólo un admin o el encargado');
      v_txt := pg_temp.como(v_prev, v_a, format('SELECT count(*) FROM public.gastos WHERE id = %s', g_lib));
      v_fallas := v_fallas || pg_temp.chk(v_txt = '0', format('7 un preventista ve %s gastos (esperado 0)', v_txt));
      v_txt := pg_temp.como(v_prev, v_a, 'SELECT count(*) FROM public.gasto_rubros');
      v_fallas := v_fallas || pg_temp.chk(v_txt = '0', format('7 un preventista ve %s rubros (esperado 0)', v_txt));
    END IF;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('7 · error: %s', SQLERRM);
  END;

  -- ===================================================== 8 · compartido ===
  BEGIN
    g_comp := pg_temp.como(v_adm_a, v_a, pg_temp.gg(v_base || jsonb_build_object(
                'rubro_id', r_hon, 'monto_total', 200000, 'comprobante', 'recibo', 'compartido', true)))::bigint;
    v_txt := pg_temp.como(v_adm_b, v_b, format('SELECT count(*) FROM public.gastos WHERE id = %s', g_comp));
    v_fallas := v_fallas || pg_temp.chk(v_txt = '1', format('8 adm_b ve %s veces el compartido de A (esperado 1)', v_txt));
    v_txt := pg_temp.como(v_adm_b, v_b, format('SELECT count(*) FROM public.gastos WHERE id = %s', g_lib));
    v_fallas := v_fallas || pg_temp.chk(v_txt = '0', format('8 adm_b ve %s gastos no compartidos de A (esperado 0)', v_txt));
    v_fallas := v_fallas || pg_temp.falla('8 adm_b edita el compartido de A', v_adm_b, v_b,
                  pg_temp.gg(v_base || jsonb_build_object('id', g_comp, 'rubro_id', r_hon, 'monto_total', 1,
                                                           'comprobante', 'recibo', 'compartido', true)),
                  'No tenés asignada esa sucursal');
    v_fallas := v_fallas || pg_temp.falla('8 adm_b anula el compartido de A', v_adm_b, v_b,
                  format('SELECT public.anular_gasto(%s, %L)', g_comp, 'no es mio'), 'No tenés asignada la sucursal de este gasto');
    IF v_adm_a2 IS NOT NULL THEN
      v_fallas := v_fallas || pg_temp.falla('8 adm_a2 edita el compartido de adm_a', v_adm_a2, v_a,
                    pg_temp.gg(v_base || jsonb_build_object('id', g_comp, 'rubro_id', r_hon, 'monto_total', 1,
                                                             'comprobante', 'recibo', 'compartido', true)),
                    'Este gasto compartido lo puede cambiar quien lo cargó o un admin de todas las sucursales');
      v_fallas := v_fallas || pg_temp.falla('8 adm_a2 anula el compartido de adm_a', v_adm_a2, v_a,
                    format('SELECT public.anular_gasto(%s, %L)', g_comp, 'no es mio'),
                    'Este gasto compartido lo puede anular quien lo cargó o un admin de todas las sucursales');
    END IF;
    PERFORM pg_temp.como(v_todas, v_b, pg_temp.gg(v_base || jsonb_build_object(
              'id', g_comp, 'rubro_id', r_hon, 'monto_total', 200000, 'comprobante', 'recibo', 'compartido', true,
              'observacion', 'corregido por el admin de todas')));
    SELECT * INTO g FROM gastos WHERE id = g_comp;
    v_fallas := v_fallas || pg_temp.chk(g.observacion = 'corregido por el admin de todas' AND g.creado_por = v_adm_a AND g.compartido,
                  '8 el admin de todas las sucursales no pudo editar el compartido');
    v_txt := pg_temp.como(v_enc, v_a, format('SELECT count(*) FROM public.gastos WHERE id = %s', g_comp));
    v_fallas := v_fallas || pg_temp.chk(v_txt = '0', format('8 el encargado de A ve %s veces el compartido (esperado 0)', v_txt));
    -- gastos_por_mes de B incluye el compartido de A
    v_fallas := v_fallas || pg_temp.chk(EXISTS (SELECT 1 FROM public.gastos_por_mes('2026-10-01', '2026-10-31', ARRAY[v_b])
                                                 WHERE gasto_id = g_comp AND compartido AND sucursal_id = v_a AND costo = 200000),
                  '8 gastos_por_mes de B no trae el compartido de A');
    -- Un compartido con vehiculo (el camion que mueve mercaderia entre las dos):
    -- el admin de todas, parado en B, ve su lectura de km y la conserva al editar.
    g_comp_comb := pg_temp.como(v_adm_a, v_a, pg_temp.gg(v_base || jsonb_build_object(
                     'rubro_id', r_comb, 'monto_total', 30000, 'vehiculo_id', v_veh, 'litros', 20,
                     'km_tablero', 160000, 'compartido', true)))::bigint;
    v_txt := pg_temp.como(v_todas, v_b, format('SELECT km FROM public.vehiculo_km WHERE gasto_id = %s', g_comp_comb));
    v_fallas := v_fallas || pg_temp.chk(v_txt = '160000',
                  format('8 el admin de todas, en B, lee km %s del compartido de A (esperado 160000)', v_txt));
    PERFORM pg_temp.como(v_todas, v_b, pg_temp.gg(v_base || jsonb_build_object(
              'id', g_comp_comb, 'rubro_id', r_comb, 'monto_total', 30000, 'vehiculo_id', v_veh, 'litros', 20,
              'km_tablero', v_txt::integer, 'compartido', true, 'observacion', 'editado desde B')));
    v_fallas := v_fallas || pg_temp.chk((SELECT km FROM vehiculo_km WHERE gasto_id = g_comp_comb) = 160000
                                         AND (SELECT observacion FROM gastos WHERE id = g_comp_comb) = 'editado desde B',
                  '8 el admin de todas edita el compartido desde B y la lectura de km no quedo');
    v_fallas := v_fallas || pg_temp.falla('8 el admin de todas manda el compartido de A a B', v_todas, v_b,
                  pg_temp.gg(v_base || jsonb_build_object('id', g_comp_comb, 'sucursal_id', v_b, 'rubro_id', r_comb,
                                                           'monto_total', 30000, 'vehiculo_id', v_veh, 'litros', 20,
                                                           'km_tablero', 160000, 'compartido', true)),
                  'Un gasto no cambia de sucursal');
    -- El encargado ve solo las lecturas de su sucursal: no la de un compartido de B.
    v_veh_b := pg_temp.como(v_adm_b, v_b,
                 format('SELECT public.guardar_vehiculo(%L::jsonb)', '{"patente":"AB123CD","descripcion":"Camion B"}'))::bigint;
    g_comp_b := pg_temp.como(v_adm_b, v_b, pg_temp.gg(v_base || jsonb_build_object(
                  'sucursal_id', v_b, 'rubro_id', r_comb, 'monto_total', 30000, 'vehiculo_id', v_veh_b, 'litros', 20,
                  'km_tablero', 90000, 'compartido', true)))::bigint;
    v_txt := pg_temp.como(v_enc, v_a, format('SELECT count(*) FROM public.vehiculo_km WHERE gasto_id = %s', g_comp_b));
    v_fallas := v_fallas || pg_temp.chk(v_txt = '0', format('8 el encargado de A ve %s lecturas de un compartido de B (esperado 0)', v_txt));
    v_txt := pg_temp.como(v_adm_a, v_a, format('SELECT count(*) FROM public.vehiculo_km WHERE gasto_id = %s', g_comp_b));
    v_fallas := v_fallas || pg_temp.chk(v_txt = '1', format('8 adm_a ve %s lecturas del compartido de B (esperado 1)', v_txt));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('8 · error: %s', SQLERRM);
  END;

  -- ======================================================= 9 · anulacion ===
  BEGIN
    v_fallas := v_fallas || pg_temp.falla('9 anular sin motivo', v_adm_a, v_a,
                  format('SELECT public.anular_gasto(%s, %L)', g_comb, '   '), 'Escribí por qué se anula');
    PERFORM pg_temp.como(v_adm_a, v_a, format('SELECT public.anular_gasto(%s, %L)', g_comb, 'Cargado dos veces'));
    SELECT * INTO g FROM gastos WHERE id = g_comb;
    v_fallas := v_fallas || pg_temp.chk(g.anulado_at IS NOT NULL AND g.anulado_por = v_adm_a AND g.motivo_anulacion = 'Cargado dos veces',
                  '9 la anulacion no quedo registrada');
    v_fallas := v_fallas || pg_temp.chk(NOT EXISTS (SELECT 1 FROM vehiculo_km WHERE gasto_id = g_comb),
                  '9 la lectura de km del gasto anulado sigue');
    v_fallas := v_fallas || pg_temp.chk(
      NOT EXISTS (SELECT 1 FROM public.gastos_por_mes('2026-10-01', '2026-10-31', ARRAY[v_a]) WHERE gasto_id IN (g_comb, g_enc))
      AND EXISTS (SELECT 1 FROM public.gastos_por_mes('2026-10-01', '2026-10-31', ARRAY[v_a]) WHERE gasto_id = g_lib),
      '9 gastos_por_mes trae un anulado o no trae los vivos');
    v_fallas := v_fallas || pg_temp.falla('9 anular dos veces', v_adm_a, v_a,
                  format('SELECT public.anular_gasto(%s, %L)', g_comb, 'otra vez'), 'Este gasto ya está anulado');
    v_fallas := v_fallas || pg_temp.falla('9 editar un anulado', v_adm_a, v_a,
                  pg_temp.gg(v_base || jsonb_build_object('id', g_comb, 'rubro_id', r_comb)), 'está anulado');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('9 · error: %s', SQLERRM);
  END;

  -- ========================================================== 10 · origen ===
  BEGIN
    v_fallas := v_fallas || pg_temp.falla('10 origen rendicion', v_adm_a, v_a,
                  pg_temp.gg(v_base || '{"origen_pago":"rendicion"}'), 'Todavía no se puede pagar un gasto con');
    v_fallas := v_fallas || pg_temp.falla('10 origen empleado', v_adm_a, v_a,
                  pg_temp.gg(v_base || '{"origen_pago":"empleado"}'), 'Todavía no se puede pagar un gasto con');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('10 · error: %s', SQLERRM);
  END;

  -- ========================================================== 11 · rubros ===
  BEGIN
    v_fallas := v_fallas || pg_temp.falla('11 el encargado crea un rubro', v_enc, v_a,
                  format('SELECT public.guardar_rubro_gasto(%L::jsonb)', '{"nombre":"Fletes","grupo":"otros"}'), 'Sólo un admin');
    v_fallas := v_fallas || pg_temp.falla('11 rubro de sueldos', v_adm_a, v_a,
                  format('SELECT public.guardar_rubro_gasto(%L::jsonb)', '{"nombre":"Sueldos administrativos","grupo":"administracion"}'),
                  'Los sueldos no son un gasto');
    v_fallas := v_fallas || pg_temp.falla('11 cambiar el grupo de un rubro con gastos', v_adm_a, v_a,
                  format('SELECT public.guardar_rubro_gasto(%L::jsonb)', jsonb_build_object('id', r_lib, 'nombre', 'Librería', 'grupo', 'otros')),
                  'Este rubro ya tiene gastos: no se le puede cambiar el grupo');
    r_nuevo := pg_temp.como(v_adm_a, v_a, format('SELECT public.guardar_rubro_gasto(%L::jsonb)',
                 '{"nombre":"  Fletes  ","grupo":"otros","palabras_busqueda":"flete camion","reparto_sugerido_meses":6}'))::bigint;
    SELECT * INTO g FROM gasto_rubros WHERE id = r_nuevo;
    v_fallas := v_fallas || pg_temp.chk(g.nombre = 'Fletes' AND g.grupo = 'otros' AND g.palabras_busqueda = 'flete camion'
                                         AND g.reparto_sugerido_meses = 6 AND g.activo,
                  format('11 rubro nuevo guardado como %s', row_to_json(g)));
    -- sin gastos el grupo si cambia; una edicion parcial conserva lo que no manda
    PERFORM pg_temp.como(v_adm_a, v_a, format('SELECT public.guardar_rubro_gasto(%L::jsonb)',
              jsonb_build_object('id', r_nuevo, 'grupo', 'vehiculos', 'activo', false)));
    SELECT * INTO g FROM gasto_rubros WHERE id = r_nuevo;
    v_fallas := v_fallas || pg_temp.chk(g.nombre = 'Fletes' AND g.grupo = 'vehiculos' AND g.palabras_busqueda = 'flete camion'
                                         AND g.reparto_sugerido_meses = 6 AND NOT g.activo,
                  format('11 la edicion parcial del rubro dejo %s', row_to_json(g)));
    v_fallas := v_fallas || pg_temp.falla('11 nombre repetido', v_adm_b, v_b,
                  format('SELECT public.guardar_rubro_gasto(%L::jsonb)', '{"nombre":"fletes","grupo":"otros"}'), 'Ya hay un rubro llamado');
    v_fallas := v_fallas || pg_temp.falla('11 gasto con rubro inactivo', v_adm_a, v_a,
                  pg_temp.gg(v_base || jsonb_build_object('rubro_id', r_nuevo)), 'dado de baja');
    -- pide_litros_km se protege como el grupo: Combustible ya tiene cargas con litros.
    v_fallas := v_fallas || pg_temp.falla('11 sacarle litros y km a Combustible', v_adm_a, v_a,
                  format('SELECT public.guardar_rubro_gasto(%L::jsonb)', jsonb_build_object('id', r_comb, 'pide_litros_km', false)),
                  'Este rubro ya tiene gastos con litros o km: no se le puede sacar');
    PERFORM pg_temp.como(v_adm_a, v_a, format('SELECT public.guardar_rubro_gasto(%L::jsonb)',
              jsonb_build_object('id', r_nuevo, 'pide_litros_km', true)));
    PERFORM pg_temp.como(v_adm_a, v_a, format('SELECT public.guardar_rubro_gasto(%L::jsonb)',
              jsonb_build_object('id', r_nuevo, 'pide_litros_km', false)));
    v_fallas := v_fallas || pg_temp.chk(NOT (SELECT pide_litros_km FROM gasto_rubros WHERE id = r_nuevo),
                  '11 un rubro sin cargas no pudo prender y apagar pide_litros_km');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('11 · error: %s', SQLERRM);
  END;

  -- ====================================== 12 · permisos de funciones y tablas ===
  BEGIN
    RESET ROLE;
    FOREACH f IN ARRAY ARRAY['public.guardar_vehiculo(jsonb)', 'public.registrar_km_vehiculo(bigint,date,integer)',
                             'public.guardar_rubro_gasto(jsonb)', 'public.guardar_gasto(jsonb)',
                             'public.anular_gasto(bigint,text)'] LOOP
      IF has_function_privilege('anon', f, 'EXECUTE') OR NOT has_function_privilege('authenticated', f, 'EXECUTE')
         OR NOT has_function_privilege('service_role', f, 'EXECUTE')
         OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = f::regprocedure AND a.grantee = 0)
         OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = f::regprocedure) THEN
        v_fallas := v_fallas || format('12 permisos de %s (anon/PUBLIC no, authenticated y service_role si, DEFINER)', f);
      END IF;
    END LOOP;
    FOREACH f IN ARRAY ARRAY['public.gastos_por_mes(date,date,bigint[])', 'public._gasto_cuota(numeric,integer,integer)',
                             'public._tiene_todas_las_sucursales()'] LOOP
      IF has_function_privilege('anon', f, 'EXECUTE') OR has_function_privilege('authenticated', f, 'EXECUTE')
         OR NOT has_function_privilege('service_role', f, 'EXECUTE')
         OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = f::regprocedure AND a.grantee = 0) THEN
        v_fallas := v_fallas || format('12 %s quedo alcanzable desde el front o sin service_role', f);
      END IF;
    END LOOP;
    SELECT count(*) INTO v_n FROM public.auditoria_definer_sin_rol()
     WHERE firma ~ '^(guardar_vehiculo|registrar_km_vehiculo|guardar_rubro_gasto|guardar_gasto|anular_gasto|gastos_por_mes|_gasto_cuota|_tiene_todas_las_sucursales)\(';
    v_fallas := v_fallas || pg_temp.chk(v_n = 0, format('12 %s funciones de gastos en rojo en SEG-A', v_n));

    FOREACH v_t IN ARRAY ARRAY['public.vehiculos', 'public.vehiculo_km', 'public.gasto_rubros', 'public.gastos']::regclass[] LOOP
      IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = v_t)
         OR has_table_privilege('anon', v_t, 'SELECT') OR NOT has_table_privilege('authenticated', v_t, 'SELECT')
         OR has_table_privilege('authenticated', v_t, 'INSERT') OR has_table_privilege('authenticated', v_t, 'UPDATE')
         OR has_table_privilege('authenticated', v_t, 'DELETE') THEN
        v_fallas := v_fallas || format('12 %s: RLS o privilegios distintos de lo pedido', v_t);
      END IF;
      IF NOT EXISTS (SELECT 1 FROM pg_policies p WHERE p.schemaname = 'public' AND p.tablename = v_t::text
                       AND p.policyname = v_t::text || '_select' AND p.cmd = 'SELECT' AND p.roles = ARRAY['authenticated']::name[])
         OR EXISTS (SELECT 1 FROM pg_policies p WHERE p.schemaname = 'public' AND p.tablename = v_t::text
                       AND (p.cmd <> 'SELECT' OR 'public' = ANY(p.roles))) THEN
        v_fallas := v_fallas || format('12 %s: policies distintas de una sola <tabla>_select TO authenticated', v_t);
      END IF;
    END LOOP;
    v_gr := public.auditoria_grants_tablas();
    SELECT count(*) INTO v_n
      FROM jsonb_array_elements((v_gr->'anon') || (v_gr->'authenticated_extras') || (v_gr->'authenticated_escrituras')) e
     WHERE COALESCE(e->>'relacion', e->>'tabla') IN ('vehiculos', 'vehiculo_km', 'gasto_rubros', 'gastos');
    v_fallas := v_fallas || pg_temp.chk(v_n = 0, format('12 auditoria_grants_tablas ve %s privilegios de mas en las tablas nuevas', v_n));
    SELECT count(*) INTO v_n
      FROM jsonb_array_elements_text((v_gr->'select_sin_policy') || (v_gr->'sin_rls')) e
     WHERE e IN ('vehiculos', 'vehiculo_km', 'gasto_rubros', 'gastos');
    v_fallas := v_fallas || pg_temp.chk(v_n = 0, '12 una tabla nueva sale en select_sin_policy o sin_rls');
    v_fallas := v_fallas || pg_temp.chk(jsonb_array_length(v_gr->'policies_public') = 0, '12 hay policies TO public');

    v_fallas := v_fallas || pg_temp.chk((public.auditoria_integridad()->>'critical_high_en_rojo')::int = 0,
                  format('12 critical_high_en_rojo = %s (antes 0)', public.auditoria_integridad()->>'critical_high_en_rojo'));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('12 · error: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------- veredicto --
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · gastos 1 (A=%, B=%): 18 rubros de semilla, vehiculo AC456EF unico, ticket 8500, factura A 41322,31 y M con percepciones, combustible con km de carga, seguro 12 x 110000 hasta 2027-09, 100 = 33,33+33,33+33,34 cruzando de año, permisos de admin/encargado/compartido%, anulacion sin km ni cuota, origen solo oficina, rubros sin sueldos ni cambio de grupo, permisos de funciones y tablas',
    v_a, v_b, CASE WHEN v_adm_a2 IS NULL THEN ' (sin segundo admin de A)' ELSE '' END;
END
$ensayo$;
