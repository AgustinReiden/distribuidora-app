-- Ensayo de la migración de la rendición que no existe y el tope del IVA de un gasto
-- (reauditoría completa del 12/11: GTO-1 y GTO-2 de #1562, mig NNN).
--
-- Corre contra prod SIN dejar rastro (salvo valores de secuencia): un único DO que termina SIEMPRE
-- en una excepción. Antes de aplicar la migración se corre pegado detrás de su cuerpo, sin el BEGIN
-- y el COMMIT; después, solo. Lo complementa scripts/test-arrastre-nc-y-piso-de-fecha-1542-1545.sql
-- (G5 y G6: la rendición que existe por una fila en rendiciones_control).
--
-- Personas (salen de la base): un admin activo de una sucursal activa. El rubro, el cliente, los
-- choferes y el empleado los crea el ensayo. El cobro que hace existir una rendición vieja se
-- inserta como postgres, con `app.reimputacion_pagos` para pasar el guard de la caja cerrada (en
-- prod hay días cerrados): es un pago suelto del chofer, que `_rendicion_pagos` le cuenta a él.
--
-- GTO-1 · la fecha de una rendición queda exenta del piso sólo si la rendición existe.
--   R1 · un gasto de una rendición de hace 75 días, fechado ese día, de un chofer sin nada ese día,
--        no entra; con un cobro de ese chofer ese día (la rendición existe), entra.
--   R2 · un gasto de hace 75 días de una rendición que existe pero de otro día no entra: la
--        exención es para la fecha que es el día de la rendición.
--   R3 · un gasto de una rendición de hace 10 días que todavía no tiene nada entra (el caso de
--        todos los días: el combustible de la mañana, antes de los cobros).
--   R4 · liquidar pagando desde una rendición de hace 70 días que no existe no entra; desde la de R1,
--        el piso no lo frena.
--   R5 · una rendición de hace 80 días sin cobros existe con una entrega del chofer ese día.
--   R6 · una fila en rendiciones_control no alcanza (decisión del dueño, 12/11): cerrar vacía una
--        rendición de hace 85 días que no existe anda, pero «Editar cierre» con un gasto de ese día
--        no entra.
-- GTO-2 · el IVA de una factura A o M no pasa de (total − percepciones − otros) × 27/127.
--   I1 · sobre 1.210: IVA 210 entra, también con alícuota 10,5 (dos alícuotas son legales); 257,24
--        (el 27 %) entra; 257,25, 500, 999 y 999,99 no.
--   I2 · con percepción de IVA de 100 la base es 1.110: 235,98 entra y 235,99 no.
--   I3 · una factura B no cambia: sin IVA.
--   I4 · la posición fiscal suma sólo lo que entró.
--
-- Sin la migración tiene que FALLAR en R1, R4, R5, R6, I1 e I2.
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ …' con la lista de fallas, siempre como excepción.
--
--   psql "$DATABASE_URL" -f scripts/test-gastos-rendicion-e-iva-1562.sql

DO $ensayo$
DECLARE
  v_s1     bigint;
  v_ua     uuid;
  v_hoy    date := public._tablero_hoy();
  v_rubro  bigint;
  v_cli    bigint;
  v_tr     uuid;
  v_tr2    uuid;
  v_tr3    uuid;
  v_tr4    uuid;
  v_e      bigint;
  v_g      bigint;
  v_t      text;
  v_pf     jsonb;
  v_notas  text := '';
  v_piso   text := 'no puede ser anterior al ' || to_char(public._tablero_hoy() - 60, 'DD/MM/YYYY');
  v_tope   text := 'El IVA no puede pasar del 27 % del neto';
  v_fallas text[] := '{}';
BEGIN
  SET LOCAL lock_timeout = '5s';

  -- ------------------------------------------------------------- personas ---
  SELECT us.sucursal_id, us.usuario_id INTO v_s1, v_ua
    FROM usuario_sucursales us
    JOIN perfiles p   ON p.id = us.usuario_id AND p.activo AND p.rol = 'admin'
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.sucursal_id, us.usuario_id
   LIMIT 1;
  IF v_ua IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: hace falta un admin activo de una sucursal activa';
  END IF;
  INSERT INTO gasto_rubros (nombre, grupo) VALUES ('ZZ ensayo 1562 ' || gen_random_uuid(), 'otros')
  RETURNING id INTO v_rubro;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ ensayo 1562', 'ZZ ensayo 1562', 'ensayo', v_s1)
  RETURNING id INTO v_cli;
  v_tr := gen_random_uuid();
  v_tr2 := gen_random_uuid();
  v_tr3 := gen_random_uuid();
  v_tr4 := gen_random_uuid();
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  SELECT u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'e1562-' || u || '@ensayo.invalid',
         jsonb_build_object('rol', 'transportista', 'sucursal_id', v_s1), '{}', now(), now()
    FROM unnest(ARRAY[v_tr, v_tr2, v_tr3, v_tr4]) u;
  PERFORM set_config('e1562.ua', v_ua::text, true);
  PERFORM set_config('e1562.s1', v_s1::text, true);
  PERFORM set_config('e1562.rubro', v_rubro::text, true);

  -- ---------------------------------------------------------------- helpers -
  CREATE FUNCTION pg_temp.claims(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
  END $f$;

  -- Una RPC como el front: con el rol authenticated.
  CREATE FUNCTION pg_temp.como(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE
    v text;
  BEGIN
    PERFORM pg_temp.claims(current_setting('e1562.ua')::uuid, current_setting('e1562.s1')::bigint);
    SET LOCAL ROLE authenticated;
    EXECUTE p_sql INTO v;
    RESET ROLE;
    RETURN v;
  END $f$;

  -- '' si la RPC falla con el mensaje esperado; si no, lo que pasó.
  CREATE FUNCTION pg_temp.falla(p_que text, p_sql text, p_espera text) RETURNS text[] LANGUAGE plpgsql AS $f$
  BEGIN
    BEGIN
      PERFORM pg_temp.como(p_sql);
    EXCEPTION WHEN SQLSTATE 'P0098' THEN RAISE;
      WHEN OTHERS THEN
        IF position(p_espera IN SQLERRM) > 0 THEN
          RETURN '{}';
        END IF;
        RETURN ARRAY[format('%s: falló con otro mensaje: %s (esperado: %s)', p_que, SQLERRM, p_espera)];
    END;
    RAISE EXCEPTION USING ERRCODE = 'P0098';
  EXCEPTION WHEN SQLSTATE 'P0098' THEN
    RETURN ARRAY[format('%s: anduvo y tenía que fallar', p_que)];
  END $f$;

  -- '' si la RPC anda; si no, el error.
  CREATE FUNCTION pg_temp.anda(p_que text, p_sql text) RETURNS text[] LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.como(p_sql);
    RETURN '{}';
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RETURN ARRAY[format('%s: tenía que andar y falló: %s', p_que, SQLERRM)];
  END $f$;

  CREATE FUNCTION pg_temp.chk(p_ok boolean, p_que text) RETURNS text[] LANGUAGE sql AS $f$
    SELECT CASE WHEN p_ok IS TRUE THEN '{}'::text[] ELSE ARRAY[p_que] END;
  $f$;

  -- guardar_gasto como ModalGasto, con lo que cambie p.
  CREATE FUNCTION pg_temp.gg(p jsonb) RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.guardar_gasto(p_gasto => %L::jsonb)',
      jsonb_build_object('sucursal_id', current_setting('e1562.s1')::bigint, 'compartido', false,
                         'fecha', public._tablero_hoy(), 'rubro_id', current_setting('e1562.rubro')::bigint,
                         'monto_total', 1210, 'comprobante', 'ninguno', 'comprobante_numero', NULL,
                         'vehiculo_id', NULL, 'repartir_meses', 1, 'origen_pago', 'oficina',
                         'observacion', 'ensayo 1562') || p);
  $f$;

  -- El gasto de una rendición: fechado el día de la rendición, como lo manda el cierre.
  CREATE FUNCTION pg_temp.gr(p_tr uuid, p_dia date) RETURNS text LANGUAGE sql AS $f$
    SELECT pg_temp.gg(jsonb_build_object('fecha', p_dia, 'origen_pago', 'rendicion',
                                         'rendicion_transportista_id', p_tr, 'rendicion_fecha', p_dia));
  $f$;

  -- Una factura A sobre 1.210 con el IVA, la alícuota y la percepción de IVA dados.
  CREATE FUNCTION pg_temp.fa(p_iva numeric, p_alic numeric, p_piva numeric) RETURNS text LANGUAGE sql AS $f$
    SELECT pg_temp.gg(jsonb_build_object('comprobante', 'factura_a', 'iva', p_iva, 'alicuota_iva', p_alic,
                                         'percepcion_iva', p_piva));
  $f$;

  -- Liquida el próximo período como ModalLiquidar, pagando p_pago con la plata de la rendición dada.
  CREATE FUNCTION pg_temp.lq(p_emp bigint, p_pago numeric, p_tr uuid, p_dia date) RETURNS text LANGUAGE sql AS $f$
    SELECT format(
      'SELECT public.liquidar_empleado(p_empleado_id => %s, p_liquidacion => %L::jsonb)', p_emp,
      jsonb_build_object('desde', v#>>'{periodo,desde}', 'hasta', v#>>'{periodo,hasta}',
                         'sueldo', (v#>>'{sueldo,propuesto}')::numeric, 'motivo_sueldo', NULL, 'pago', p_pago,
                         'fecha_pago', p_dia, 'a_pagar_esperado', (v->>'a_pagar')::numeric,
                         'origen_pago', 'rendicion', 'rendicion_transportista_id', p_tr, 'rendicion_fecha', p_dia))
      FROM (SELECT pg_temp.como(format('SELECT public.previsualizar_liquidacion(p_empleado_id => %s)', p_emp))::jsonb AS v) x;
  $f$;

  IF cardinality(pg_temp.falla('canario', 'SELECT 1', 'x')) <> 1
     OR cardinality(pg_temp.falla('canario', 'SELECT 1/0', 'by zero')) <> 0
     OR cardinality(pg_temp.falla('canario', 'SELECT 1/0', 'otro mensaje')) <> 1
     OR cardinality(pg_temp.anda('canario', 'SELECT 1')) <> 0
     OR cardinality(pg_temp.anda('canario', 'SELECT 1/0')) <> 1
     OR pg_temp.como('SELECT current_user || '' '' || auth.uid() || '' '' || public.current_sucursal_id()')
        IS DISTINCT FROM format('authenticated %s %s', v_ua, v_s1)
     OR current_user = 'authenticated' THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · los helpers del ensayo no hacen lo que dicen';
  END IF;

  -- ================================================================ GTO-1 ===
  -- R1 · la rendición de hace 75 días existe sólo con el cobro
  BEGIN
    v_fallas := v_fallas || pg_temp.falla('R1 un gasto de una rendición de hace 75 días sin nada',
                  pg_temp.gr(v_tr, v_hoy - 75), 'La fecha del gasto ' || v_piso);
    RESET ROLE;
    PERFORM set_config('app.reimputacion_pagos', 'on', true);
    INSERT INTO pagos (cliente_id, monto, forma_pago, sucursal_id, fecha, usuario_id, notas)
    VALUES (v_cli, 100, 'efectivo', v_s1, v_hoy - 75, v_tr, 'ensayo 1562');
    PERFORM set_config('app.reimputacion_pagos', '', true);
    v_fallas := v_fallas || pg_temp.chk(
      EXISTS (SELECT 1 FROM public._rendicion_pagos(v_s1, v_hoy - 75, v_hoy - 75) x WHERE x.t_id = v_tr),
      'R1 _rendicion_pagos no le cuenta el cobro al chofer');
    v_fallas := v_fallas || pg_temp.anda('R1 el gasto de la rendición de hace 75 días con un cobro',
                  pg_temp.gr(v_tr, v_hoy - 75));
    v_fallas := v_fallas || pg_temp.chk(
      EXISTS (SELECT 1 FROM gastos WHERE rendicion_transportista_id = v_tr AND fecha = v_hoy - 75 AND anulado_at IS NULL),
      'R1 el gasto de la rendición con un cobro no quedó');
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    v_fallas := v_fallas || ('R1 ' || SQLERRM);
  END;

  -- R2 · la exención es para la fecha que es el día de la rendición
  BEGIN
    v_fallas := v_fallas || pg_temp.falla('R2 un gasto de hace 75 días de la rendición del día siguiente',
                  pg_temp.gg(jsonb_build_object('fecha', v_hoy - 75, 'origen_pago', 'rendicion',
                    'rendicion_transportista_id', v_tr, 'rendicion_fecha', v_hoy - 74)),
                  'La fecha del gasto ' || v_piso);
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    v_fallas := v_fallas || ('R2 ' || SQLERRM);
  END;

  -- R3 · dentro del piso no se pregunta nada
  v_fallas := v_fallas || pg_temp.anda('R3 un gasto de una rendición de hace 10 días sin nada',
                pg_temp.gr(v_tr2, v_hoy - 10));

  -- R4 · el pago de una liquidación
  BEGIN
    v_e := pg_temp.como(format('SELECT public.guardar_empleado(p_empleado => %L::jsonb)', jsonb_build_object(
      'nombre', 'ZZ e1562 ' || gen_random_uuid(), 'puesto', 'preventista',
      'sucursal_id', v_s1, 'de_las_dos', false,
      'cuil', NULL, 'fecha_ingreso', NULL, 'telefono', NULL, 'usuario_id', NULL, 'cliente_id', NULL, 'vehiculo_id', NULL,
      'arreglo', jsonb_build_object('vigente_desde', v_hoy - 14, 'sueldo', 70000, 'frecuencia', 'semanal', 'comisiona', false),
      'saldo_inicial', NULL)))::bigint;
    v_fallas := v_fallas || pg_temp.falla('R4 liquidar pagando de una rendición de hace 70 días que no existe',
                  pg_temp.lq(v_e, 100, v_tr2, v_hoy - 70), 'La fecha del pago ' || v_piso);
    BEGIN
      PERFORM pg_temp.como(pg_temp.lq(v_e, 100, v_tr, v_hoy - 75));
      v_fallas := v_fallas || pg_temp.chk(
        EXISTS (SELECT 1 FROM empleado_liquidaciones WHERE empleado_id = v_e AND fecha_pago = v_hoy - 75),
        'R4 la liquidación pagada de la rendición de R1 no quedó con su día');
    EXCEPTION WHEN OTHERS THEN
      RESET ROLE;
      IF position('no puede ser anterior al' IN SQLERRM) > 0 THEN
        v_fallas := v_fallas || ('R4 el piso frenó un pago de una rendición que existe: ' || SQLERRM);
      ELSE
        v_notas := v_notas || ' · R4 sin ensayar el caso que existe (' || SQLERRM || ')';
      END IF;
    END;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    v_fallas := v_fallas || ('R4 ' || SQLERRM);
  END;

  -- R5 · la rendición existe con una entrega, sin cobros
  BEGIN
    v_fallas := v_fallas || pg_temp.falla('R5 un gasto de una rendición de hace 80 días sin nada',
                  pg_temp.gr(v_tr3, v_hoy - 80), 'La fecha del gasto ' || v_piso);
    RESET ROLE;
    INSERT INTO pedidos (cliente_id, sucursal_id, estado, total, transportista_id, fecha, fecha_entrega, usuario_id)
    VALUES (v_cli, v_s1, 'entregado', 0, v_tr3, v_hoy - 80,
            ((v_hoy - 80)::timestamp + interval '15 hours') AT TIME ZONE 'America/Argentina/Buenos_Aires', v_ua);
    v_fallas := v_fallas || pg_temp.chk(
      EXISTS (SELECT 1 FROM public._rendicion_entregas(v_s1, v_hoy - 80, v_hoy - 80) x WHERE x.t_id = v_tr3),
      'R5 _rendicion_entregas no le cuenta la entrega al chofer');
    v_fallas := v_fallas || pg_temp.anda('R5 el gasto de la rendición de hace 80 días con una entrega',
                  pg_temp.gr(v_tr3, v_hoy - 80));
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    v_fallas := v_fallas || ('R5 ' || SQLERRM);
  END;

  -- R6 · la fila de control que crea confirmar_rendicion no hace existir la rendición
  BEGIN
    v_fallas := v_fallas || pg_temp.anda('R6 cerrar vacía una rendición de hace 85 días',
                  format('SELECT public.confirmar_rendicion(%L::date, %L::uuid, %L, %L::jsonb)::text',
                         v_hoy - 85, v_tr4, 'confirmada', '{}'));
    v_fallas := v_fallas || pg_temp.chk(
      EXISTS (SELECT 1 FROM rendiciones_control WHERE transportista_id = v_tr4 AND fecha = v_hoy - 85),
      'R6 confirmar_rendicion no dejó la fila de control');
    v_fallas := v_fallas || pg_temp.falla('R6 «Editar cierre» con un gasto de ese día',
                  format('SELECT public.confirmar_rendicion(%L::date, %L::uuid, %L, %L::jsonb)::text',
                         v_hoy - 85, v_tr4, 'confirmada',
                         jsonb_build_object('guardar', jsonb_build_array(jsonb_build_object(
                           'fecha', v_hoy - 85, 'rubro_id', v_rubro, 'monto_total', 500, 'comprobante', 'ninguno',
                           'repartir_meses', 1, 'observacion', 'ensayo 1562')))),
                  'La fecha del gasto ' || v_piso);
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    v_fallas := v_fallas || ('R6 ' || SQLERRM);
  END;

  -- ================================================================ GTO-2 ===
  BEGIN
    -- I1 · sobre 1.210
    v_fallas := v_fallas || pg_temp.anda('I1 IVA 210 al 21', pg_temp.fa(210, 21, 0));
    v_fallas := v_fallas || pg_temp.anda('I1 IVA 210 al 10,5', pg_temp.fa(210, 10.5, 0));
    v_fallas := v_fallas || pg_temp.anda('I1 IVA 257,24 (el 27 %)', pg_temp.fa(257.24, 27, 0));
    v_fallas := v_fallas || pg_temp.falla('I1 IVA 257,25', pg_temp.fa(257.25, 27, 0), v_tope);
    v_fallas := v_fallas || pg_temp.falla('I1 IVA 500', pg_temp.fa(500, 21, 0), v_tope);
    v_fallas := v_fallas || pg_temp.falla('I1 IVA 999', pg_temp.fa(999, 21, 0), v_tope);
    v_fallas := v_fallas || pg_temp.falla('I1 IVA 999,99 sin alícuota', pg_temp.fa(999.99, NULL, 0), v_tope);
    -- I2 · la percepción sale de la base
    v_fallas := v_fallas || pg_temp.anda('I2 IVA 235,98 con percepción 100', pg_temp.fa(235.98, 27, 100));
    v_fallas := v_fallas || pg_temp.falla('I2 IVA 235,99 con percepción 100', pg_temp.fa(235.99, 27, 100), v_tope);
    -- I3 · una factura B no lleva IVA, como siempre
    v_fallas := v_fallas || pg_temp.falla('I3 factura B con IVA',
                  pg_temp.gg(jsonb_build_object('comprobante', 'factura_b', 'iva', 10)),
                  'Sólo la factura A o M lleva IVA y percepciones');
    -- I4 · el crédito fiscal del mes: 210 + 210 + 257,24 + 235,98
    RESET ROLE;
    PERFORM pg_temp.claims(v_ua, v_s1);
    v_pf := public.posicion_fiscal(v_s1, date_trunc('month', v_hoy::timestamp)::date, v_hoy)->'gastos';
    v_fallas := v_fallas || pg_temp.chk(
      (SELECT COALESCE(sum(iva), 0) FROM gastos WHERE observacion = 'ensayo 1562' AND anulado_at IS NULL
          AND comprobante IN ('factura_a', 'factura_m')) = 913.22,
      'I4 los gastos con IVA del ensayo no suman 913,22');
    v_t := v_pf::text;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    v_fallas := v_fallas || ('I ' || SQLERRM);
  END;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · R1 R2 R3 R4 R5 R6 I1 I2 I3 I4 · posición fiscal del mes, gastos: %', v_t || v_notas;
END
$ensayo$;
