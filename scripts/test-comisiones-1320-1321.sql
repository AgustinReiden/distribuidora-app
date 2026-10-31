-- Ensayo de comisiones y metas (#1320, #1321; mig 421_comisiones_meses_cerrados).
--
-- Corre contra prod SIN dejar rastro, igual que scripts/test-volver-a-pendiente-1313.sql:
-- un único DO que termina SIEMPRE en una excepción, y cada caso en su propio
-- bloque que se deshace (ZZ001). Antes de aplicar la migración se corre pegado
-- detrás de su cuerpo sin el BEGIN/COMMIT; después, solo.
--
-- "Mes cerrado" (M) es el mes anterior al de hoy (día argentino); P es el
-- preventista con más venta en M de la sucursal S.
--
--   C1 · COM-1: la comisión de M no cambia cuando el admin cambia el %; el %
--        nuevo rige desde el 1° del mes en curso; el encargado no puede.
--   C2 · COM-2: con una regla del 50 % que rige en M, la comisión de M no
--        cambia al darla de baja ni al editarla (la edición la corta en M y
--        crea otra desde el mes en curso); no se puede crear una regla que
--        rija en M ni cortar en M una que ya rigió.
--   C3 · COM-4: un adelanto de sueldo por el 25 % de un pedido del mes en curso
--        baja la base en el 25 % de sus líneas, no el pedido entero; uno
--        cargado hoy sobre un pedido de M también descuenta en M (cuentan todos
--        los adelantos del pedido: decisión del dueño, 29/10).
--   C4 · COM-5: con 10 % / 1 % en M, P comisiona 10 %; con el extra de
--        transportista en S, 10 % igual; pasado a transportista, 1 %. El caso
--        del chofer con el extra de preventista no se puede armar:
--        `perfil_roles_rol_check` sólo acepta 'transportista' hoy. El % sale de
--        `_actua_como_preventista`, que ya lo contempla.
--   C5 · COM-3: la meta de la Red sólo la carga el admin de todas; el admin de
--        una sucursal no da de baja ni edita una meta de otra; la meta del mismo
--        preventista en dos sucursales son dos metas; el vendedor de una regla
--        tiene que compartir sucursal con el admin.
--   C6 · comision_pct_vigencias sin grants para anon ni authenticated.
--   C7 · COM-4 en reporte_gerencial: en cada mes y sucursal con un pedido con
--        adelanto, `kpis.base_comision` cierra con la base de
--        calcular_comisiones, y `vendedores[].base_nc` con la de cada vendedor.

DO $ensayo$
DECLARE
  v_hoy      date := _tablero_hoy();
  v_corte    date := date_trunc('month', _tablero_hoy())::date;
  v_m_ini    date := (date_trunc('month', _tablero_hoy()) - interval '1 month')::date;
  v_m_fin    date := (date_trunc('month', _tablero_hoy()) - interval '1 day')::date;
  v_s        bigint;
  v_otra     bigint;
  v_adm      uuid;   -- admin con todas las sucursales activas
  v_adm1     uuid;   -- admin sólo de S
  v_enc      uuid;
  v_enc_suc  bigint;
  v_p        uuid;
  v_ajeno    uuid;   -- usuario que no comparte sucursal con v_adm1
  v_x1       numeric;
  v_x2       numeric;
  v_b1       numeric;
  v_b2       numeric;
  v_esp      numeric;
  v_id       bigint;
  v_id2      bigint;
  v_ped      record;
  v_rg       jsonb;
  v_cc       jsonb;
  v_txt      text;
  v_t        text;
  v_fallas   text[] := '{}';
  v_notas    text[] := '{}';
BEGIN
 BEGIN
  -- ------------------------------------------------------------- personas ---
  SELECT pf.id INTO v_adm
    FROM perfiles pf
   WHERE pf.activo AND pf.rol = 'admin'
     AND NOT EXISTS (SELECT 1 FROM sucursales s WHERE s.activa
                       AND NOT EXISTS (SELECT 1 FROM usuario_sucursales us
                                        WHERE us.usuario_id = pf.id AND us.sucursal_id = s.id))
   ORDER BY pf.id LIMIT 1;

  SELECT pf.id, us.sucursal_id INTO v_adm1, v_s
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.activo AND pf.rol = 'admin'
     AND (SELECT count(*) FROM usuario_sucursales x WHERE x.usuario_id = pf.id) = 1
     AND EXISTS (SELECT 1 FROM sucursales s WHERE s.id = us.sucursal_id AND s.activa)
   ORDER BY pf.id LIMIT 1;

  SELECT s.id INTO v_otra FROM sucursales s WHERE s.activa AND s.id <> v_s ORDER BY s.id LIMIT 1;

  SELECT pf.id, us.sucursal_id INTO v_enc, v_enc_suc
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.activo AND pf.rol = 'encargado'
   ORDER BY pf.id LIMIT 1;

  SELECT p.usuario_id INTO v_p
    FROM pedidos p JOIN perfiles pf ON pf.id = p.usuario_id
   WHERE pf.activo AND pf.rol = 'preventista'
     AND p.estado = 'entregado' AND p.canal <> 'cambio' AND p.tipo_factura IS DISTINCT FROM 'VB'
     AND p.sucursal_id = v_s AND p.fecha BETWEEN v_m_ini AND v_m_fin
   GROUP BY p.usuario_id ORDER BY sum(p.total) DESC LIMIT 1;

  SELECT us.usuario_id INTO v_ajeno
    FROM usuario_sucursales us
   WHERE NOT EXISTS (SELECT 1 FROM usuario_sucursales x WHERE x.usuario_id = us.usuario_id AND x.sucursal_id = v_s)
   ORDER BY us.usuario_id LIMIT 1;

  IF v_adm IS NULL OR v_adm1 IS NULL OR v_otra IS NULL OR v_enc IS NULL OR v_p IS NULL OR v_ajeno IS NULL THEN
    RAISE EXCEPTION 'ENSAYO · faltan personas: adm %, adm1 %, otra %, enc %, P %, ajeno %',
      v_adm, v_adm1, v_otra, v_enc, v_p, v_ajeno;
  END IF;

  v_notas := v_notas || format('S %s, otra %s, M %s..%s, ADM %s, ADM1 %s, ENC %s (suc %s), P %s',
                               v_s, v_otra, v_m_ini, v_m_fin, left(v_adm::text, 8), left(v_adm1::text, 8),
                               left(v_enc::text, 8), v_enc_suc, left(v_p::text, 8));

  -- ---------------------------------------------------------------- helpers -
  CREATE OR REPLACE FUNCTION pg_temp.como(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims',
                       CASE WHEN p_uid IS NULL THEN ''
                            ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
    PERFORM set_config('request.jwt.claim.sub', COALESCE(p_uid::text, ''), true);
    PERFORM set_config('request.headers',
                       CASE WHEN p_suc IS NULL THEN '' ELSE json_build_object('x-sucursal-id', p_suc::text)::text END, true);
    IF p_uid IS NULL THEN
      EXECUTE 'RESET ROLE';
    ELSE
      EXECUTE 'SET LOCAL ROLE authenticated';
    END IF;
  END $f$;
  CREATE OR REPLACE FUNCTION pg_temp.intenta(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  BEGIN
    EXECUTE p_sql;
    RETURN 'PASA';
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE || ' ' || SQLERRM;
  END $f$;
  -- Comisión calculada por un admin, de vuelta como postgres.
  CREATE OR REPLACE FUNCTION pg_temp.calc(p_uid uuid, p_suc bigint, p_desde date, p_hasta date) RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE v jsonb;
  BEGIN
    PERFORM pg_temp.como(p_uid, p_suc);
    v := calcular_comisiones(p_desde, p_hasta, ARRAY[p_suc]);
    PERFORM pg_temp.como(NULL, NULL);
    RETURN v;
  END $f$;
  CREATE OR REPLACE FUNCTION pg_temp.de(p_calc jsonb, p_uid uuid, p_campo text) RETURNS numeric LANGUAGE sql AS $f$
    SELECT COALESCE((SELECT (x->>p_campo)::numeric FROM jsonb_array_elements(p_calc->'preventistas') x
                      WHERE x->>'id' = p_uid::text), 0)
  $f$;

  -- ------------------------------------------------------------------- C1 ---
  BEGIN
    v_x1 := (pg_temp.calc(v_adm, v_s, v_m_ini, v_m_fin)->'totales'->>'comision')::numeric;
    v_b1 := (pg_temp.calc(v_adm, v_s, v_corte, v_hoy)->'totales'->>'comision')::numeric;
    PERFORM pg_temp.como(v_adm, v_s);
    PERFORM actualizar_comisiones_default(9, 4);
    PERFORM pg_temp.como(NULL, NULL);
    v_x2 := (pg_temp.calc(v_adm, v_s, v_m_ini, v_m_fin)->'totales'->>'comision')::numeric;
    v_b2 := (pg_temp.calc(v_adm, v_s, v_corte, v_hoy)->'totales'->>'comision')::numeric;
    IF v_x1 IS DISTINCT FROM v_x2 THEN
      v_fallas := v_fallas || format('C1 · la comisión de M cambió con el %%: %s → %s', v_x1, v_x2);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM comision_pct_vigencias
                    WHERE sucursal_id = v_s AND vigente_desde = v_corte
                      AND pct_preventista = 9 AND pct_otros = 4)
       OR NOT EXISTS (SELECT 1 FROM politicas_comerciales
                       WHERE sucursal_id = v_s AND comision_pct_preventista = 9 AND comision_pct_otros = 4) THEN
      v_fallas := v_fallas || 'C1 · el % nuevo no quedó en la vigencia del mes ni en el espejo'::text;
    END IF;
    v_notas := v_notas || format('C1 · M %s = %s; mes en curso %s → %s', v_x1, v_x2, v_b1, v_b2);

    PERFORM pg_temp.como(v_enc, v_enc_suc);
    v_txt := pg_temp.intenta('SELECT actualizar_comisiones_default(3, 3)');
    PERFORM pg_temp.como(NULL, NULL);
    IF v_txt NOT LIKE '42501%' THEN
      v_fallas := v_fallas || ('C1 · el encargado cambió el %: ' || v_txt);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('C1 · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------- C2 ---
  -- Una regla general del 50 % que rige en M (cargada a mano: la RPC ya no deja).
  BEGIN
    INSERT INTO comision_reglas (sucursal_id, porcentaje, vigente_desde, usuario_id)
    VALUES (v_s, 50, v_m_ini, v_adm) RETURNING id INTO v_id;
    v_x1 := (pg_temp.calc(v_adm, v_s, v_m_ini, v_m_fin)->'totales'->>'comision')::numeric;
    v_b1 := (pg_temp.calc(v_adm, v_s, v_m_ini, v_m_fin)->'totales'->>'base')::numeric;
    IF abs(v_x1 - v_b1 * 0.5) > 0.05 THEN
      v_fallas := v_fallas || format('C2 · la regla del 50 %% no rige en M: comisión %s, base %s', v_x1, v_b1);
    END IF;

    -- Editarla: la vieja se corta en M y rige una nueva desde el mes en curso.
    BEGIN
      PERFORM pg_temp.como(v_adm, v_s);
      v_id2 := guardar_comision_regla(v_id, v_s, NULL, NULL, 60, v_m_ini, NULL);
      PERFORM pg_temp.como(NULL, NULL);
      v_x2 := (pg_temp.calc(v_adm, v_s, v_m_ini, v_m_fin)->'totales'->>'comision')::numeric;
      IF v_x1 IS DISTINCT FROM v_x2 THEN
        v_fallas := v_fallas || format('C2 · editar la regla cambió M: %s → %s', v_x1, v_x2);
      END IF;
      IF v_id2 = v_id
         OR NOT EXISTS (SELECT 1 FROM comision_reglas WHERE id = v_id AND NOT activo
                          AND baja_desde = v_corte AND vigente_hasta = v_corte - 1 AND porcentaje = 50)
         OR NOT EXISTS (SELECT 1 FROM comision_reglas WHERE id = v_id2 AND activo
                          AND vigente_desde = v_corte AND porcentaje = 60) THEN
        v_fallas := v_fallas || format('C2 · la edición no partió la regla (vieja %s, nueva %s)', v_id, v_id2);
      END IF;
      RAISE EXCEPTION USING ERRCODE = 'ZZ001';
    EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || ('C2 · editar: error inesperado: ' || SQLERRM);
    END;

    -- Darla de baja.
    PERFORM pg_temp.como(v_adm, v_s);
    PERFORM desactivar_comision_regla(v_id);
    PERFORM pg_temp.como(NULL, NULL);
    v_x2 := (pg_temp.calc(v_adm, v_s, v_m_ini, v_m_fin)->'totales'->>'comision')::numeric;
    IF v_x1 IS DISTINCT FROM v_x2 THEN
      v_fallas := v_fallas || format('C2 · dar de baja la regla cambió M: %s → %s', v_x1, v_x2);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM comision_reglas WHERE id = v_id AND NOT activo AND baja_desde = v_hoy) THEN
      v_fallas := v_fallas || 'C2 · la baja no quedó con la fecha de hoy'::text;
    END IF;
    v_notas := v_notas || format('C2 · M con la regla del 50 %%: %s (base %s), tras editar y dar de baja %s', v_x1, v_b1, v_x2);
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('C2 · error inesperado: ' || SQLERRM);
  END;

  BEGIN
    PERFORM pg_temp.como(v_adm, v_s);
    v_txt := pg_temp.intenta(format('SELECT guardar_comision_regla(NULL, %s, NULL, NULL, 5, %L, NULL)', v_s, v_m_ini));
    PERFORM pg_temp.como(NULL, NULL);
    IF v_txt NOT LIKE '%cerraron%' THEN
      v_fallas := v_fallas || ('C2 · una regla nueva rige en M: ' || v_txt);
    END IF;
    INSERT INTO comision_reglas (sucursal_id, porcentaje, vigente_desde, usuario_id)
    VALUES (v_s, 50, v_m_ini, v_adm) RETURNING id INTO v_id;
    PERFORM pg_temp.como(v_adm, v_s);
    v_txt := pg_temp.intenta(format('SELECT guardar_comision_regla(%s, %s, NULL, NULL, 50, %L, %L)',
                                    v_id, v_s, v_m_ini, v_m_fin - 5));
    PERFORM pg_temp.como(NULL, NULL);
    IF v_txt NOT LIKE '%cerraron%' THEN
      v_fallas := v_fallas || ('C2 · una regla que rigió en M se cortó en M: ' || v_txt);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('C2 · rechazos: error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------- C3 ---
  BEGIN
    -- El guard de caja cerrada no es lo que se ensaya: la reimputación lo saltea.
    PERFORM set_config('app.reimputacion_pagos', 'on', true);

    SELECT p.id, p.usuario_id, p.cliente_id, p.total,
           (SELECT sum(pi.subtotal) FROM pedido_items pi
             WHERE pi.pedido_id = p.id AND COALESCE(pi.es_bonificacion, false) = false) AS lineas
      INTO v_ped
      FROM pedidos p JOIN perfiles pf ON pf.id = p.usuario_id
     WHERE p.estado = 'entregado' AND p.canal <> 'cambio' AND p.tipo_factura IS DISTINCT FROM 'VB'
       AND p.sucursal_id = v_s AND p.fecha BETWEEN v_corte AND v_hoy AND p.total > 0
       AND p.total - COALESCE(p.monto_pagado, 0) >= p.total * 0.25
       AND NOT EXISTS (SELECT 1 FROM pagos g WHERE g.pedido_id = p.id AND g.forma_pago = 'adelanto_sueldo')
     ORDER BY p.total DESC LIMIT 1;

    IF v_ped.id IS NULL THEN
      v_notas := v_notas || 'C3 · sin pedido del mes en curso con saldo: no se ensaya el parcial'::text;
    ELSE
      v_b1 := pg_temp.de(pg_temp.calc(v_adm, v_s, v_corte, v_hoy), v_ped.usuario_id, 'base');
      INSERT INTO pagos (pedido_id, cliente_id, monto, forma_pago, fecha, sucursal_id)
      VALUES (v_ped.id, v_ped.cliente_id, round(v_ped.total * 0.25, 2), 'adelanto_sueldo', v_hoy, v_s);
      v_b2 := pg_temp.de(pg_temp.calc(v_adm, v_s, v_corte, v_hoy), v_ped.usuario_id, 'base');
      v_esp := v_ped.lineas * round(v_ped.total * 0.25, 2) / v_ped.total;
      IF abs((v_b1 - v_b2) - v_esp) > 0.02 THEN
        v_fallas := v_fallas || format('C3 · un adelanto del 25 %% del pedido %s bajó la base %s (esperado %s)',
                                       v_ped.id, v_b1 - v_b2, round(v_esp, 2));
      END IF;
      v_notas := v_notas || format('C3 · pedido %s ($%s): base %s → %s', v_ped.id, v_ped.total, v_b1, v_b2);
    END IF;

    SELECT p.id, p.usuario_id, p.cliente_id, p.total,
           (SELECT sum(pi.subtotal) FROM pedido_items pi
             WHERE pi.pedido_id = p.id AND COALESCE(pi.es_bonificacion, false) = false) AS lineas
      INTO v_ped
      FROM pedidos p
     WHERE p.estado = 'entregado' AND p.canal <> 'cambio' AND p.tipo_factura IS DISTINCT FROM 'VB'
       AND p.sucursal_id = v_s AND p.fecha BETWEEN v_m_ini AND v_m_fin AND p.usuario_id = v_p
       AND p.total > 0
       AND NOT EXISTS (SELECT 1 FROM pagos g WHERE g.pedido_id = p.id AND g.forma_pago = 'adelanto_sueldo')
     ORDER BY p.total DESC LIMIT 1;
    v_b1 := pg_temp.de(pg_temp.calc(v_adm, v_s, v_m_ini, v_m_fin), v_p, 'base');
    INSERT INTO pagos (pedido_id, cliente_id, monto, forma_pago, fecha, sucursal_id)
    VALUES (v_ped.id, v_ped.cliente_id, round(v_ped.total * 0.25, 2), 'adelanto_sueldo', v_hoy, v_s);
    v_b2 := pg_temp.de(pg_temp.calc(v_adm, v_s, v_m_ini, v_m_fin), v_p, 'base');
    v_esp := v_ped.lineas * round(v_ped.total * 0.25, 2) / v_ped.total;
    IF abs((v_b1 - v_b2) - v_esp) > 0.02 THEN
      v_fallas := v_fallas || format('C3 · un adelanto de hoy sobre el pedido %s de M bajó la base de M %s (esperado %s)',
                                     v_ped.id, v_b1 - v_b2, round(v_esp, 2));
    END IF;
    v_notas := v_notas || format('C3 · pedido %s de M: base de P %s → %s', v_ped.id, v_b1, v_b2);
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('C3 · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------- C4 ---
  BEGIN
    IF EXISTS (SELECT 1 FROM comision_reglas WHERE baja_desde IS NULL OR baja_desde > v_m_ini) THEN
      v_notas := v_notas || 'C4 · hay reglas vivas: el % efectivo puede no ser el default'::text;
    END IF;
    INSERT INTO comision_pct_vigencias (sucursal_id, vigente_desde, pct_preventista, pct_otros)
    VALUES (v_s, v_m_ini, 10, 1)
    ON CONFLICT (sucursal_id, vigente_desde) DO UPDATE SET pct_preventista = 10, pct_otros = 1;

    v_x1 := pg_temp.de(pg_temp.calc(v_adm, v_s, v_m_ini, v_m_fin), v_p, 'comision')
          / NULLIF(pg_temp.de(pg_temp.calc(v_adm, v_s, v_m_ini, v_m_fin), v_p, 'base'), 0);

    INSERT INTO perfil_roles (usuario_id, sucursal_id, rol) VALUES (v_p, v_s, 'transportista')
    ON CONFLICT DO NOTHING;
    v_esp := pg_temp.de(pg_temp.calc(v_adm, v_s, v_m_ini, v_m_fin), v_p, 'comision')
           / NULLIF(pg_temp.de(pg_temp.calc(v_adm, v_s, v_m_ini, v_m_fin), v_p, 'base'), 0);
    DELETE FROM perfil_roles WHERE usuario_id = v_p;

    UPDATE perfiles SET rol = 'transportista' WHERE id = v_p;
    v_x2 := pg_temp.de(pg_temp.calc(v_adm, v_s, v_m_ini, v_m_fin), v_p, 'comision')
          / NULLIF(pg_temp.de(pg_temp.calc(v_adm, v_s, v_m_ini, v_m_fin), v_p, 'base'), 0);

    IF abs(v_x1 - 0.10) > 0.0005 OR abs(v_esp - 0.10) > 0.0005 OR abs(v_x2 - 0.01) > 0.0005 THEN
      v_fallas := v_fallas || format('C4 · %% de P: preventista %s, con el extra de transportista %s, transportista %s (esperado 0.10, 0.10, 0.01)',
                                     round(v_x1, 4), round(v_esp, 4), round(v_x2, 4));
    END IF;
    v_notas := v_notas || format('C4 · %% de P: %s / %s / %s', round(v_x1, 4), round(v_esp, 4), round(v_x2, 4));
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('C4 · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------- C5 ---
  BEGIN
    PERFORM pg_temp.como(v_adm1, v_s);
    v_txt := pg_temp.intenta(format('SELECT guardar_meta_gerencial(NULL, %L, ''venta'', 1)', v_m_ini));
    IF v_txt NOT LIKE '42501%' THEN
      v_fallas := v_fallas || ('C5 · el admin de una sucursal cargó la meta de la Red: ' || v_txt);
    END IF;
    PERFORM pg_temp.como(v_adm, v_s);
    v_txt := pg_temp.intenta(format('SELECT guardar_meta_gerencial(NULL, %L, ''venta'', 1)', v_m_ini));
    IF v_txt <> 'PASA' THEN
      v_fallas := v_fallas || ('C5 · el admin de todas no cargó la meta de la Red: ' || v_txt);
    END IF;

    -- Una meta de la otra sucursal, vista por el admin de S.
    SELECT id INTO v_id FROM metas_preventista WHERE sucursal_id = v_otra AND activo ORDER BY id LIMIT 1;
    IF v_id IS NULL THEN
      v_notas := v_notas || 'C5 · la otra sucursal no tiene metas activas: no se ensaya el cruce por id'::text;
    ELSE
      PERFORM pg_temp.como(v_adm1, v_s);
      v_txt := pg_temp.intenta(format('SELECT desactivar_meta_preventista(%s)', v_id));
      IF v_txt NOT LIKE '42501%' THEN
        v_fallas := v_fallas || ('C5 · el admin de S dio de baja una meta de otra sucursal: ' || v_txt);
      END IF;
      v_txt := pg_temp.intenta(format(
        'SELECT guardar_meta_preventista(%s, %s, %L, %L, ''facturacion'', 1)', v_id, v_s, v_p, v_m_ini));
      IF v_txt NOT LIKE '42501%' THEN
        v_fallas := v_fallas || ('C5 · el admin de S editó una meta de otra sucursal: ' || v_txt);
      END IF;
      PERFORM pg_temp.como(NULL, NULL);
      IF NOT EXISTS (SELECT 1 FROM metas_preventista WHERE id = v_id AND activo AND sucursal_id = v_otra) THEN
        v_fallas := v_fallas || 'C5 · la meta de la otra sucursal cambió'::text;
      END IF;
    END IF;
    PERFORM pg_temp.como(NULL, NULL);

    -- El mismo preventista en dos sucursales: dos metas.
    INSERT INTO usuario_sucursales (usuario_id, sucursal_id) VALUES (v_p, v_otra) ON CONFLICT DO NOTHING;
    PERFORM pg_temp.como(v_adm, v_s);
    v_id  := guardar_meta_preventista(NULL, v_s,    v_p, DATE '2099-01-01', 'facturacion', 100);
    v_id2 := guardar_meta_preventista(NULL, v_otra, v_p, DATE '2099-01-01', 'facturacion', 200);
    PERFORM pg_temp.como(NULL, NULL);
    IF v_id = v_id2
       OR NOT EXISTS (SELECT 1 FROM metas_preventista WHERE id = v_id  AND sucursal_id = v_s    AND valor_objetivo = 100)
       OR NOT EXISTS (SELECT 1 FROM metas_preventista WHERE id = v_id2 AND sucursal_id = v_otra AND valor_objetivo = 200) THEN
      v_fallas := v_fallas || format('C5 · la meta de una sucursal pisó la de la otra (%s, %s)', v_id, v_id2);
    END IF;

    -- El vendedor de una regla tiene que compartir sucursal con el admin.
    PERFORM pg_temp.como(v_adm1, v_s);
    v_txt := pg_temp.intenta(format('SELECT guardar_comision_regla(NULL, %s, %L, NULL, 5)', v_s, v_ajeno));
    PERFORM pg_temp.como(NULL, NULL);
    IF v_txt NOT LIKE '42501%' THEN
      v_fallas := v_fallas || ('C5 · regla para un vendedor de otra sucursal: ' || v_txt);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('C5 · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------- C7 ---
  BEGIN
    FOR v_ped IN
      SELECT DISTINCT p.sucursal_id AS suc, date_trunc('month', p.fecha)::date AS mes
        FROM pedidos p
       WHERE EXISTS (SELECT 1 FROM pagos g WHERE g.pedido_id = p.id AND g.forma_pago = 'adelanto_sueldo')
       ORDER BY 1, 2
    LOOP
      PERFORM pg_temp.como(v_adm, v_ped.suc);
      v_rg := reporte_gerencial(v_ped.suc, v_ped.mes, LEAST((v_ped.mes + interval '1 month - 1 day')::date, v_hoy));
      v_cc := calcular_comisiones(v_ped.mes, LEAST((v_ped.mes + interval '1 month - 1 day')::date, v_hoy), ARRAY[v_ped.suc]);
      PERFORM pg_temp.como(NULL, NULL);
      IF abs((v_rg->'kpis'->>'base_comision')::numeric - (v_cc->'totales'->>'base')::numeric) > 0.05 THEN
        v_fallas := v_fallas || format('C7 · suc %s %s: base_comision %s, calcular_comisiones %s',
                                       v_ped.suc, v_ped.mes, v_rg->'kpis'->>'base_comision', v_cc->'totales'->>'base');
      END IF;
      SELECT string_agg(left(x->>'id', 8), ', ') INTO v_txt
        FROM jsonb_array_elements(v_cc->'preventistas') x
       WHERE abs(COALESCE((SELECT (r->>'base_nc')::numeric FROM jsonb_array_elements(v_rg->'vendedores') r
                            WHERE r->>'id' = x->>'id'), -1) - (x->>'base')::numeric) > 0.05;
      IF v_txt IS NOT NULL THEN
        v_fallas := v_fallas || format('C7 · suc %s %s: base_nc no cierra para %s', v_ped.suc, v_ped.mes, v_txt);
      END IF;
      -- Y al revés: un vendedor del reporte con base_nc que calcular_comisiones no
      -- tiene (el que sólo vendió pagado con adelanto caía a su venta entera).
      SELECT string_agg(left(r->>'id', 8), ', ') INTO v_txt
        FROM jsonb_array_elements(v_rg->'vendedores') r
       WHERE r->>'id' IS NOT NULL AND (r->>'base_nc')::numeric > 0.05
         AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_cc->'preventistas') x WHERE x->>'id' = r->>'id');
      IF v_txt IS NOT NULL THEN
        v_fallas := v_fallas || format('C7 · suc %s %s: base_nc sin comisión para %s', v_ped.suc, v_ped.mes, v_txt);
      END IF;
      v_notas := v_notas || format('C7 · suc %s %s: base %s = %s', v_ped.suc, v_ped.mes,
                                   v_rg->'kpis'->>'base_comision', v_cc->'totales'->>'base');
    END LOOP;
    PERFORM pg_temp.como(NULL, NULL);
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('C7 · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------- C6 ---
  IF has_table_privilege('anon', 'public.comision_pct_vigencias', 'SELECT')
     OR has_table_privilege('authenticated', 'public.comision_pct_vigencias', 'SELECT')
     OR has_table_privilege('authenticated', 'public.comision_pct_vigencias', 'INSERT,UPDATE,DELETE') THEN
    v_fallas := v_fallas || 'C6 · comision_pct_vigencias alcanzable por REST'::text;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA', MESSAGE = format(E'ENSAYO FALLO (%s fallas, todo revertido):\n- %s\nnotas: %s',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), array_to_string(v_notas, ' | '));
  END IF;
  RAISE EXCEPTION USING ERRCODE = 'ZZ0OK', MESSAGE = format('ENSAYO OK (todo revertido) · notas: %s', array_to_string(v_notas, ' | '));
 EXCEPTION WHEN SQLSTATE 'ZZ0OK' OR SQLSTATE 'ZZ0FA' THEN
  -- Se relanza afuera del bloque que escribió.
  GET STACKED DIAGNOSTICS v_t = MESSAGE_TEXT;
  RAISE EXCEPTION '%', v_t;
 END;
END
$ensayo$;
