-- Ensayo de la tarjeta T1 de la ola 3 (plan #1677): los checks de integridad del personal y de
-- las rendiciones en auditoria_integridad(). #1392 (LIQ-A, LIQ-B, LIQ-C) y #1426 (FALT-A,
-- FALT-B, FALT-C). Migración: NNN_ola3_checks_personal_rendiciones.
--
-- Un único DO con datos propios que termina SIEMPRE en una excepción: no deja rastro (salvo
-- valores de secuencia). Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ' con la lista. Sin la migración
-- falla en el caso 0: los seis checks no existen.
--
--   0 · los seis checks existen, son `high` y, antes de armar nada, dan 0 (sobre la semilla
--       limpia: el ensayo exige 0).
--   1 · LIQ-A · cuatro liquidaciones: una que cuadra (sueldo 1.000, pagado 400, movimientos
--       +1.000 y −400), una con el movimiento de sueldo por 900, una sin movimientos y una
--       anulada descuadrada. Ve 2 (las dos vigentes que no cuadran).
--   2 · LIQ-B · sin el índice único empleado_liquidacion_lineas_key (se cae dentro del ensayo,
--       que se deshace): la misma línea dos veces vigente y no-ajuste para el mismo vendedor, más
--       un ajuste de esa línea, la misma línea de otro vendedor y otra línea con una fila no
--       vigente. Ve 1. Y dos claves aparte que dan 0: una con una sola fila no-ajuste más un
--       ajuste de esa línea (muerde el filtro tipo <> 'ajuste') y otra con una fila de cada
--       uno de dos vendedores (muerde el usuario_id del GROUP BY).
--   3 · LIQ-C · tres rendiciones del mismo chofer: confirmada, resuelta y en disconformidad.
--       En la confirmada, un pago de antes del cierre, otro de después y la reversión (después)
--       del primero; en la resuelta, uno de cuando estaba en disconformidad y otro de después de
--       resolverla; en la que sigue en disconformidad, uno cualquiera; y un pago de la oficina.
--       Y un pago cargado después del cierre de la sucursal 1, pero de la rendición de la
--       sucursal 2 (mismo chofer y día, en disconformidad): no cuenta (muerde la sucursal del
--       JOIN). Ve 3 (los de después del cierre, la reversión incluida).
--   4 · FALT-A · líneas vivas: una con su movimiento bien y otra con su gasto bien (no cuentan);
--       una cuyo movimiento tiene compensación, una cuyo gasto está anulado y una cuyo
--       movimiento es por otro monto; y, cada una con una sola cosa mal, una cuyo gasto vivo es
--       por otro monto, una cuyo movimiento es de otro empleado, y una cuyo gasto es de la rendición
--       de otro día. (Un gasto con otro origen_pago no se arma: gastos_rendicion_check lo ata a
--       tener o no la rendición, y sin rendición no coincide con la línea por el chofer.) Ve 6.
--   5 · FALT-B · un faltante sin línea. La compensación de un faltante (sin línea propia) no
--       cuenta. Ve 1.
--   6 · FALT-C · líneas anuladas: una con el movimiento compensado y otra con el gasto anulado
--       (no cuentan); una con el movimiento sin compensar, una con el gasto vivo y una con la
--       compensación por otro monto. Ve 3.
--
-- Arma todo como postgres, directo en las tablas: lo que se prueba es que el check ve lo que
-- las RPCs no dejan armar. Las líneas de comisión van con session_replication_role = replica
-- (apuntan a un pedido que no existe). El DROP INDEX del caso 2 toma la tabla de líneas de
-- comisión hasta el final del ensayo (lock_timeout 5 s).
--
--   docker exec -i <contenedor> psql -U postgres -h localhost -d postgres -f - < scripts/test-ola3-checks-personal-rendiciones.sql

DO $ensayo$
DECLARE
  v_hoy    date := public._tablero_hoy();
  v_adm    uuid;
  v_tra    uuid;
  v_pre    uuid;
  v_pre2   uuid;
  v_e      bigint;
  v_e2     bigint;
  v_rubro  bigint;
  v_l1     bigint;
  v_l2     bigint;
  v_l3     bigint;
  v_l4     bigint;
  v_m      bigint;
  v_m2     bigint;
  v_g      bigint;
  v_aud    jsonb;
  v_id     text;
  v_esp    jsonb := '{"LIQ-A": 2, "LIQ-B": 1, "LIQ-C": 3, "FALT-A": 6, "FALT-B": 1, "FALT-C": 3}';
  v_fallas text[] := '{}';
BEGIN
 BEGIN
  SET LOCAL lock_timeout = '5s';

  CREATE FUNCTION pg_temp.u(p_rol text, p_suc bigint) RETURNS uuid LANGUAGE plpgsql AS $f$
  DECLARE v uuid := gen_random_uuid();
  BEGIN
    INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't1-' || v || '@ensayo.invalid',
            jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), jsonb_build_object('nombre', 'T1 ' || p_rol), now(), now());
    RETURN v;
  END $f$;
  -- Las violaciones de un check de auditoria_integridad() (NULL si el check no existe).
  CREATE FUNCTION pg_temp.check_de(p_aud jsonb, p_id text) RETURNS bigint LANGUAGE sql AS $f$
    SELECT (c->>'violaciones')::bigint FROM jsonb_array_elements(p_aud->'checks') c WHERE c->>'id' = p_id
  $f$;
  -- Un movimiento a mano. p_dias_atras: la rendición (NULL: sin rendición).
  CREATE FUNCTION pg_temp.mov(p_e bigint, p_tipo text, p_monto numeric, p_tra uuid, p_dias_atras int,
                              p_revierte bigint, p_liq bigint, p_creado timestamptz, p_por uuid)
  RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v bigint;
  BEGIN
    INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, observacion, revierte_id, liquidacion_id, creado_por,
                                      created_at, rendicion_transportista_id, rendicion_fecha, rendicion_sucursal_id)
    VALUES (p_e, public._tablero_hoy(), p_tipo, p_monto, 'T1 ensayo', p_revierte, p_liq, p_por, COALESCE(p_creado, now()),
            CASE WHEN p_dias_atras IS NOT NULL THEN p_tra END,
            CASE WHEN p_dias_atras IS NOT NULL THEN public._tablero_hoy() - p_dias_atras END,
            CASE WHEN p_dias_atras IS NOT NULL THEN 1 END)
    RETURNING id INTO v;
    RETURN v;
  END $f$;
  -- Un gasto de la rendición de hace 5 días (anulado o no).
  CREATE FUNCTION pg_temp.gasto(p_tra uuid, p_monto numeric, p_anulado boolean, p_rubro bigint, p_por uuid,
                                p_dias_rend int DEFAULT 5)
  RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v bigint;
  BEGIN
    INSERT INTO gastos (sucursal_id, fecha, rubro_id, monto_total, comprobante, mes_imputado, origen_pago,
                        rendicion_transportista_id, rendicion_fecha, creado_por, anulado_at, anulado_por, motivo_anulacion)
    VALUES (1, public._tablero_hoy() - 5, p_rubro, p_monto, 'ninguno', date_trunc('month', public._tablero_hoy() - 5)::date,
            'rendicion', p_tra, public._tablero_hoy() - p_dias_rend, p_por,
            CASE WHEN p_anulado THEN now() END, CASE WHEN p_anulado THEN p_por END, CASE WHEN p_anulado THEN 'T1 ensayo' END)
    RETURNING id INTO v;
    RETURN v;
  END $f$;
  -- Una línea de faltante de la rendición de hace 5 días.
  CREATE FUNCTION pg_temp.linea(p_tra uuid, p_causal text, p_monto numeric, p_e bigint, p_mov bigint, p_gasto bigint,
                                p_anulada boolean, p_por uuid)
  RETURNS void LANGUAGE sql AS $f$
    INSERT INTO rendicion_faltantes (rendicion_transportista_id, rendicion_fecha, rendicion_sucursal_id, causal, monto,
                                     empleado_id, movimiento_id, gasto_id, observacion, creado_por,
                                     anulada_at, anulada_por, motivo_anulacion)
    VALUES (p_tra, public._tablero_hoy() - 5, 1, p_causal, p_monto, p_e, p_mov, p_gasto, 'T1 ensayo', p_por,
            CASE WHEN p_anulada THEN now() END, CASE WHEN p_anulada THEN p_por END, CASE WHEN p_anulada THEN 'T1 ensayo' END)
  $f$;

  -- ----------------------------------------------------------------- caso 0 -
  v_aud := public.auditoria_integridad();
  FOR v_id IN SELECT jsonb_object_keys(v_esp) LOOP
    IF pg_temp.check_de(v_aud, v_id) IS NULL THEN
      v_fallas := v_fallas || format('0 · %s no está en auditoria_integridad()', v_id);
    ELSE
      IF (SELECT count(*) FROM jsonb_array_elements(v_aud->'checks') c WHERE c->>'id' = v_id) <> 1 THEN
        v_fallas := v_fallas || format('0 · %s aparece más de una vez', v_id);
      END IF;
      IF (SELECT c->>'severidad' FROM jsonb_array_elements(v_aud->'checks') c WHERE c->>'id' = v_id LIMIT 1) <> 'high' THEN
        v_fallas := v_fallas || format('0 · %s no es high', v_id);
      END IF;
      IF pg_temp.check_de(v_aud, v_id) <> 0 THEN
        v_fallas := v_fallas || format('0 · %s da %s antes de armar nada (esperado 0)', v_id, pg_temp.check_de(v_aud, v_id));
      END IF;
    END IF;
  END LOOP;
  IF (SELECT count(*) FROM jsonb_array_elements(v_aud->'checks') c)
     <> (SELECT count(DISTINCT c->>'id') FROM jsonb_array_elements(v_aud->'checks') c) THEN
    v_fallas := v_fallas || '0 · auditoria_integridad() tiene ids repetidos'::text;
  END IF;
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ (%):%', cardinality(v_fallas), E'\n  ' || array_to_string(v_fallas, E'\n  ')
      USING ERRCODE = 'P0001';
  END IF;

  -- --------------------------------------------------------------- fixtures -
  v_adm  := pg_temp.u('admin', 1);
  v_tra  := pg_temp.u('transportista', 1);
  v_pre  := pg_temp.u('preventista', 1);
  v_pre2 := pg_temp.u('preventista', 1);
  INSERT INTO empleados (sucursal_id, nombre, puesto, creado_por)
  VALUES (1, 'T1 empleado', 'transportista', v_adm) RETURNING id INTO v_e;
  INSERT INTO empleados (sucursal_id, nombre, puesto, creado_por)
  VALUES (1, 'T1 otro empleado', 'transportista', v_adm) RETURNING id INTO v_e2;
  SELECT id INTO v_rubro FROM gasto_rubros WHERE clave = 'faltantes_caja';
  IF v_rubro IS NULL THEN
    SELECT id INTO v_rubro FROM gasto_rubros ORDER BY id LIMIT 1;
  END IF;

  -- ----------------------------------------------------------------- caso 1 -
  INSERT INTO empleado_liquidaciones (empleado_id, desde, hasta, frecuencia, sucursal_al_liquidar, de_las_dos,
                                      saldo_anterior, a_pagar, pagado, fecha_pago, creado_por)
  VALUES (v_e, v_hoy - 37, v_hoy - 31, 'semanal', 1, false, 0, 1000, 400, v_hoy - 30, v_adm) RETURNING id INTO v_l1;
  INSERT INTO empleado_liquidacion_conceptos (liquidacion_id, concepto, monto, detalle) VALUES (v_l1, 'sueldo', 1000, '{}');
  PERFORM pg_temp.mov(v_e, 'sueldo', 1000, NULL, NULL, NULL, v_l1, NULL, v_adm);
  PERFORM pg_temp.mov(v_e, 'pago', -400, NULL, NULL, NULL, v_l1, NULL, v_adm);
  INSERT INTO empleado_liquidaciones (empleado_id, desde, hasta, frecuencia, sucursal_al_liquidar, de_las_dos,
                                      saldo_anterior, a_pagar, pagado, fecha_pago, creado_por)
  VALUES (v_e, v_hoy - 30, v_hoy - 24, 'semanal', 1, false, 0, 1000, 0, v_hoy - 23, v_adm) RETURNING id INTO v_l2;
  INSERT INTO empleado_liquidacion_conceptos (liquidacion_id, concepto, monto, detalle) VALUES (v_l2, 'sueldo', 1000, '{}');
  PERFORM pg_temp.mov(v_e, 'sueldo', 900, NULL, NULL, NULL, v_l2, NULL, v_adm);
  INSERT INTO empleado_liquidaciones (empleado_id, desde, hasta, frecuencia, sucursal_al_liquidar, de_las_dos,
                                      saldo_anterior, a_pagar, pagado, fecha_pago, creado_por)
  VALUES (v_e, v_hoy - 23, v_hoy - 17, 'semanal', 1, false, 0, 500, 0, v_hoy - 16, v_adm) RETURNING id INTO v_l3;
  INSERT INTO empleado_liquidacion_conceptos (liquidacion_id, concepto, monto, detalle) VALUES (v_l3, 'sueldo', 500, '{}');
  INSERT INTO empleado_liquidaciones (empleado_id, desde, hasta, frecuencia, sucursal_al_liquidar, de_las_dos,
                                      saldo_anterior, a_pagar, pagado, fecha_pago, creado_por,
                                      anulada_at, anulada_por, motivo_anulacion)
  VALUES (v_e, v_hoy - 16, v_hoy - 10, 'semanal', 1, false, 0, 700, 0, v_hoy - 9, v_adm, now(), v_adm, 'T1 ensayo')
  RETURNING id INTO v_l4;
  INSERT INTO empleado_liquidacion_conceptos (liquidacion_id, concepto, monto, detalle) VALUES (v_l4, 'sueldo', 700, '{}');

  -- ----------------------------------------------------------------- caso 2 -
  DROP INDEX public.empleado_liquidacion_lineas_key;
  SET LOCAL session_replication_role = replica;
  INSERT INTO empleado_liquidacion_lineas (liquidacion_id, empleado_id, pedido_id, usuario_id, clave, pct, base, comision,
                                           tipo, motivo, entregado_el, vigente)
  VALUES (v_l1, v_e, -1, v_pre,  'T1|x', 5, 1000, 50, 'inicial',     NULL,        v_hoy - 35, true),
         (v_l2, v_e, -1, v_pre,  'T1|x', 5, 1000, 50, 'linea_nueva', 'T1 ensayo', v_hoy - 35, true),
         (v_l2, v_e, -1, v_pre,  'T1|x', 5, 1000, 50, 'ajuste',      'T1 ensayo', v_hoy - 35, true),
         (v_l2, v_e, -1, v_pre2, 'T1|x', 5, 1000, 50, 'inicial',     NULL,        v_hoy - 35, true),
         (v_l1, v_e, -2, v_pre,  'T1|x', 5, 1000, 50, 'inicial',     NULL,        v_hoy - 35, false),
         (v_l2, v_e, -2, v_pre,  'T1|x', 5, 1000, 50, 'inicial',     NULL,        v_hoy - 35, true),
         -- una sola fila no-ajuste y el ajuste de esa línea: no es un duplicado (tipo <> 'ajuste')
         (v_l1, v_e, -3, v_pre,  'T1|x', 5, 1000, 50, 'inicial',     NULL,        v_hoy - 35, true),
         (v_l2, v_e, -3, v_pre,  'T1|x', 5, 1000, 50, 'ajuste',      'T1 ensayo', v_hoy - 35, true),
         -- una fila de cada vendedor: no es un duplicado (usuario_id en el GROUP BY)
         (v_l1, v_e, -4, v_pre,  'T1|x', 5, 1000, 50, 'inicial',     NULL,        v_hoy - 35, true),
         (v_l2, v_e, -4, v_pre2, 'T1|x', 5, 1000, 50, 'inicial',     NULL,        v_hoy - 35, true);
  SET LOCAL session_replication_role = origin;

  -- ----------------------------------------------------------------- caso 3 -
  INSERT INTO rendiciones_control (fecha, transportista_id, sucursal_id, estado, controlada_at, controlada_por,
                                   total_entregado_confirmado, cantidad_pedidos_confirmada)
  VALUES (v_hoy - 2, v_tra, 1, 'confirmada', now() - interval '2 hours', v_adm, 0, 0);
  INSERT INTO rendiciones_control (fecha, transportista_id, sucursal_id, estado, controlada_at, controlada_por,
                                   resuelta_at, resuelta_por, total_entregado_confirmado, cantidad_pedidos_confirmada)
  VALUES (v_hoy - 3, v_tra, 1, 'resuelta', now() - interval '5 hours', v_adm, now() - interval '2 hours', v_adm, 0, 0);
  INSERT INTO rendiciones_control (fecha, transportista_id, sucursal_id, estado, controlada_at, controlada_por)
  VALUES (v_hoy - 4, v_tra, 1, 'disconformidad', now() - interval '5 hours', v_adm);
  -- confirmada: antes del cierre (no), después (sí) y la reversión del de antes, después (sí)
  v_m := pg_temp.mov(v_e, 'pago', -100, v_tra, 2, NULL, NULL, now() - interval '3 hours', v_adm);
  PERFORM pg_temp.mov(v_e, 'pago', -110, v_tra, 2, NULL, NULL, now() - interval '1 hour', v_adm);
  PERFORM pg_temp.mov(v_e, 'pago', 100, v_tra, 2, v_m, NULL, now() - interval '1 hour', v_adm);
  -- resuelta: en disconformidad (no) y después de resolverla (sí)
  PERFORM pg_temp.mov(v_e, 'pago', -120, v_tra, 3, NULL, NULL, now() - interval '3 hours', v_adm);
  PERFORM pg_temp.mov(v_e, 'pago', -130, v_tra, 3, NULL, NULL, now() - interval '1 hour', v_adm);
  -- en disconformidad (no) y de la oficina (no)
  PERFORM pg_temp.mov(v_e, 'pago', -140, v_tra, 4, NULL, NULL, now() - interval '1 hour', v_adm);
  PERFORM pg_temp.mov(v_e, 'pago', -150, NULL, NULL, NULL, NULL, now(), v_adm);
  -- sucursal 2: misma clave de chofer y día que la confirmada de la 1, pero su rendición sigue en
  -- disconformidad: un pago de después del cierre de la 1 no es de una rendición cerrada
  INSERT INTO rendiciones_control (fecha, transportista_id, sucursal_id, estado, controlada_at, controlada_por)
  VALUES (v_hoy - 2, v_tra, 2, 'disconformidad', now() - interval '5 hours', v_adm);
  INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, observacion, creado_por, created_at,
                                    rendicion_transportista_id, rendicion_fecha, rendicion_sucursal_id)
  VALUES (v_e, v_hoy, 'pago', -160, 'T1 ensayo', v_adm, now() - interval '1 hour', v_tra, v_hoy - 2, 2);

  -- ---------------------------------------------------- casos 4, 5 y 6 -
  -- vivas que están bien
  v_m := pg_temp.mov(v_e, 'faltante', -100, v_tra, 5, NULL, NULL, NULL, v_adm);
  PERFORM pg_temp.linea(v_tra, 'empleado', 100, v_e, v_m, NULL, false, v_adm);
  v_g := pg_temp.gasto(v_tra, 50, false, v_rubro, v_adm);
  PERFORM pg_temp.linea(v_tra, 'robo_perdida', 50, NULL, NULL, v_g, false, v_adm);
  -- FALT-A: el movimiento compensado (la compensación, sin línea, no es de FALT-B)
  v_m := pg_temp.mov(v_e, 'faltante', -70, v_tra, 5, NULL, NULL, NULL, v_adm);
  PERFORM pg_temp.mov(v_e, 'faltante', 70, v_tra, 5, v_m, NULL, NULL, v_adm);
  PERFORM pg_temp.linea(v_tra, 'empleado', 70, v_e, v_m, NULL, false, v_adm);
  -- FALT-A: el gasto anulado
  v_g := pg_temp.gasto(v_tra, 60, true, v_rubro, v_adm);
  PERFORM pg_temp.linea(v_tra, 'gasto_no_cargado', 60, NULL, NULL, v_g, false, v_adm);
  -- FALT-A: el movimiento por otro monto
  v_m := pg_temp.mov(v_e, 'faltante', -80, v_tra, 5, NULL, NULL, NULL, v_adm);
  PERFORM pg_temp.linea(v_tra, 'empleado', 90, v_e, v_m, NULL, false, v_adm);
  -- FALT-A, una sola cosa mal cada una: el gasto vivo por otro monto
  v_g := pg_temp.gasto(v_tra, 45, false, v_rubro, v_adm);
  PERFORM pg_temp.linea(v_tra, 'robo_perdida', 46, NULL, NULL, v_g, false, v_adm);
  -- el movimiento de otro empleado
  v_m := pg_temp.mov(v_e2, 'faltante', -85, v_tra, 5, NULL, NULL, NULL, v_adm);
  PERFORM pg_temp.linea(v_tra, 'empleado', 85, v_e, v_m, NULL, false, v_adm);
  -- el gasto es de la rendición de otro día
  v_g := pg_temp.gasto(v_tra, 48, false, v_rubro, v_adm, 6);
  PERFORM pg_temp.linea(v_tra, 'gasto_no_cargado', 48, NULL, NULL, v_g, false, v_adm);
  -- FALT-B: un faltante sin línea
  PERFORM pg_temp.mov(v_e, 'faltante', -30, v_tra, 5, NULL, NULL, NULL, v_adm);
  -- anuladas que están bien
  v_m := pg_temp.mov(v_e, 'faltante', -60, v_tra, 5, NULL, NULL, NULL, v_adm);
  PERFORM pg_temp.mov(v_e, 'faltante', 60, v_tra, 5, v_m, NULL, NULL, v_adm);
  PERFORM pg_temp.linea(v_tra, 'empleado', 60, v_e, v_m, NULL, true, v_adm);
  v_g := pg_temp.gasto(v_tra, 40, true, v_rubro, v_adm);
  PERFORM pg_temp.linea(v_tra, 'robo_perdida', 40, NULL, NULL, v_g, true, v_adm);
  -- FALT-C: el movimiento sin compensar
  v_m := pg_temp.mov(v_e, 'faltante', -40, v_tra, 5, NULL, NULL, NULL, v_adm);
  PERFORM pg_temp.linea(v_tra, 'empleado', 40, v_e, v_m, NULL, true, v_adm);
  -- FALT-C: el gasto vivo
  v_g := pg_temp.gasto(v_tra, 35, false, v_rubro, v_adm);
  PERFORM pg_temp.linea(v_tra, 'gasto_no_cargado', 35, NULL, NULL, v_g, true, v_adm);
  -- FALT-C: la compensación por otro monto
  v_m := pg_temp.mov(v_e, 'faltante', -25, v_tra, 5, NULL, NULL, NULL, v_adm);
  v_m2 := pg_temp.mov(v_e, 'faltante', 20, v_tra, 5, v_m, NULL, NULL, v_adm);
  PERFORM pg_temp.linea(v_tra, 'empleado', 25, v_e, v_m, NULL, true, v_adm);

  -- -------------------------------------------------------------- veredicto -
  v_aud := public.auditoria_integridad();
  FOR v_id IN SELECT jsonb_object_keys(v_esp) LOOP
    IF pg_temp.check_de(v_aud, v_id) IS DISTINCT FROM (v_esp->>v_id)::bigint THEN
      v_fallas := v_fallas || format('%s · ve %s de más (esperado %s)', v_id,
                                     pg_temp.check_de(v_aud, v_id), v_esp->>v_id);
    END IF;
  END LOOP;

  IF cardinality(v_fallas) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK · LIQ-A %, LIQ-B %, LIQ-C %, FALT-A %, FALT-B %, FALT-C % (hoy %)',
      pg_temp.check_de(v_aud, 'LIQ-A'), pg_temp.check_de(v_aud, 'LIQ-B'), pg_temp.check_de(v_aud, 'LIQ-C'),
      pg_temp.check_de(v_aud, 'FALT-A'), pg_temp.check_de(v_aud, 'FALT-B'), pg_temp.check_de(v_aud, 'FALT-C'), v_hoy
      USING ERRCODE = 'P0001';
  END IF;
  RAISE EXCEPTION 'ENSAYO FALLÓ (%):%', cardinality(v_fallas), E'\n  ' || array_to_string(v_fallas, E'\n  ')
    USING ERRCODE = 'P0001';
 END;
END
$ensayo$;
