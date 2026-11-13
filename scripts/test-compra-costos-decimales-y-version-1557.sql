-- Ensayo de la migración de la compra: costo real, rangos, costo al centavo, versión de la edición
-- y regalo legal (reauditoría completa del 12/11: CMP-3, CMP-5, FRG-1 y FRG-4 de #1557; tarjeta 3
-- de #1565).
--
-- Un único DO que termina SIEMPRE en una excepción: no deja rastro (salvo valores de secuencia).
-- Antes de aplicar la migración se corre pegado detrás de su cuerpo, sin el BEGIN y el COMMIT;
-- después, solo. Cada caso usa sus propios productos.
--
-- Personas (salen de la base): un admin activo de una sucursal activa. Las compras son ZZ salvo
-- donde se dice: el costo real es el costo unitario.
--
--   C3 · CMP-3 · 10 × 100 con una bonificación prorrateada de −2.000 se rechaza con su motivo (el
--        renglón y en cuánto queda), sin dejar la compra ni tocar el producto. Con −500 entra y el
--        costo real queda en 50. La edición con −2.000 también se rechaza.
--   R1 · los rangos en la edición: bonificación −50, costo −100 e II 'NaN' se rechazan con su motivo.
--   R2 · los rangos en el alta: el II del renglón −90 % en una FC A, la alícuota 150, un IVA de
--        cabecera 'NaN' y uno negativo se rechazan.
--   F1 · FRG-1 · el bulto de $10.000 con 2.400 unidades: con el costo sin redondear (4,1666…) y el
--        subtotal 10.000 se rechaza diciendo que da 10.008; con el costo al centavo (4,17) y su
--        subtotal entra, el renglón guardado cierra contra su subtotal, y editarlo sin cambios (los
--        renglones como se reabren) no mueve la cabecera.
--   F4 · FRG-4 · dos ediciones de la misma compra: la primera entra, la segunda (con los renglones
--        que vio antes de la primera) se rechaza con «alguien la cambió» y no pisa la primera. Sin
--        los renglones vistos, pide recargar.
--   Z5 · CMP-5 · un renglón a costo 0 sin bonificación del 100 % se rechaza; el regalo legal (costo 0
--        con bonificación 100) entra, y COMPRA-C y COMPRA-E no lo cuentan. Un renglón a costo 0 sin
--        bonificación puesto a mano sí lo cuenta COMPRA-C (control negativo del check).
--   L1 · los permisos: los dos helpers son de server, actualizar_compra_items tiene una sola firma
--        y conserva su EXECUTE para authenticated.
--
-- Sin la migración tiene que FALLAR en C3, R1, R2, F1, F4, Z5 y L1.
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ …' con la lista de fallas, siempre como excepción.
--
--   psql "$DATABASE_URL" -f scripts/test-compra-costos-decimales-y-version-1557.sql

DO $ensayo$
DECLARE
  v_s1     bigint;
  v_ua     uuid;
  v_p      bigint;
  v_q      bigint;
  v_c      bigint;
  v_j      jsonb;
  v_t      text;
  v_r      record;
  v_vistos bigint[];
  v_cc0    bigint;
  v_ce0    bigint;
  v_fallas text[] := '{}';
BEGIN
  SET LOCAL lock_timeout = '5s';

  SELECT us.usuario_id, us.sucursal_id INTO v_ua, v_s1
    FROM usuario_sucursales us
    JOIN perfiles p ON p.id = us.usuario_id AND p.activo AND p.rol = 'admin'
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.sucursal_id, us.usuario_id
   LIMIT 1;
  IF v_ua IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · no hay un admin activo de una sucursal activa';
  END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_ua, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_s1::text)::text, true);

  CREATE FUNCTION pg_temp.producto(p_suc bigint, p_nombre text) RETURNS bigint LANGUAGE sql AS $f$
    INSERT INTO public.productos (nombre, precio, stock, sucursal_id)
    VALUES (p_nombre || ' ' || gen_random_uuid(), 100, 0, p_suc) RETURNING id;
  $f$;

  -- un renglón ZZ; lo que traiga pisa el default
  CREATE FUNCTION pg_temp.renglon(p_prod bigint, p_cant numeric, p_costo numeric, p_extra jsonb DEFAULT '{}')
  RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'costo_unitario', p_costo,
             'bonificacion', 0, 'porcentaje_iva', 0, 'impuestos_internos', 0, 'condicion_iva', 'gravado',
             'subtotal', round(p_cant * p_costo * (1 - COALESCE((p_extra->>'bonificacion')::numeric, 0) / 100), 2))
           || p_extra;
  $f$;

  CREATE FUNCTION pg_temp.alta(p_ref text, p_items jsonb, p_cargos jsonb DEFAULT '[]', p_tipo text DEFAULT 'ZZ',
                               p_iva numeric DEFAULT 0) RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE v_sub numeric := (SELECT sum((e->>'subtotal')::numeric) FROM jsonb_array_elements(p_items) e);
  BEGIN
    RETURN public.registrar_compra_completa(
      NULL, 'ZZ ensayo 1557', 'ENS-1557-' || p_ref, public._tablero_hoy(), v_sub, p_iva, 0,
      v_sub + CASE WHEN p_iva = 'NaN'::numeric THEN 0 ELSE p_iva END, 'efectivo', 'ensayo 1557',
      (current_setting('request.jwt.claims')::json->>'sub')::uuid, p_items, p_tipo, p_cargos => p_cargos);
  END $f$;

  CREATE FUNCTION pg_temp.vistos(p_compra bigint) RETURNS bigint[] LANGUAGE sql AS $f$
    SELECT array_agg(id ORDER BY id) FROM public.compra_items WHERE compra_id = p_compra;
  $f$;

  CREATE FUNCTION pg_temp.editar(p_compra bigint, p_items jsonb, p_vistos bigint[], p_cargos jsonb DEFAULT '[]')
  RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE v_sub numeric := (SELECT sum((e->>'subtotal')::numeric) FROM jsonb_array_elements(p_items) e);
  BEGIN
    RETURN public.actualizar_compra_items(
      p_compra, p_items, v_sub, 0, v_sub, (current_setting('request.jwt.claims')::json->>'sub')::uuid,
      p_cargos => p_cargos, p_ii_declarado => '{}'::jsonb, p_renglones_vistos => p_vistos);
  END $f$;

  CREATE FUNCTION pg_temp.bonif(p_monto numeric) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_array(jsonb_build_object('concepto', 'bonif ensayo', 'monto', p_monto,
             'condicion_iva', 'no_gravado', 'en_factura', true, 'prorratea_al_costo', true,
             'base_prorrateo', 'unidades', 'pesos', jsonb_build_object('0', 10)));
  $f$;

  CREATE FUNCTION pg_temp.chk(p_id text) RETURNS bigint LANGUAGE sql AS $f$
    SELECT (c->>'violaciones')::bigint FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c
     WHERE c->>'id' = p_id;
  $f$;

  -- C3 · CMP-3
  BEGIN
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 1557 C3');
    v_j := pg_temp.alta('C3a', jsonb_build_array(pg_temp.renglon(v_p, 10, 100)), pg_temp.bonif(-2000));
    IF COALESCE((v_j->>'success')::boolean, false)
       OR v_j->>'error' NOT LIKE '%Los cargos dejan sin costo%renglón 1) queda en -100.00%' THEN
      v_fallas := v_fallas || ('C3 alta con -2000: ' || v_j::text);
    END IF;
    SELECT stock, costo_real, costo_promedio INTO v_r FROM public.productos WHERE id = v_p;
    IF v_r.stock <> 0 OR v_r.costo_real IS NOT NULL OR v_r.costo_promedio IS NOT NULL
       OR EXISTS (SELECT 1 FROM public.compras WHERE numero_factura = 'ENS-1557-C3a') THEN
      v_fallas := v_fallas || format('C3 el rechazo dejó rastro: stock %s real %s cpp %s', v_r.stock, v_r.costo_real, v_r.costo_promedio);
    END IF;
    v_j := pg_temp.alta('C3b', jsonb_build_array(pg_temp.renglon(v_p, 10, 100)), pg_temp.bonif(-500));
    v_c := (v_j->>'compra_id')::bigint;
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (SELECT costo_real FROM public.productos WHERE id = v_p) IS DISTINCT FROM 50.0000 THEN
      v_fallas := v_fallas || ('C3 alta con -500: ' || v_j::text);
    END IF;
    v_j := pg_temp.editar(v_c, jsonb_build_array(pg_temp.renglon(v_p, 10, 100)), pg_temp.vistos(v_c), pg_temp.bonif(-2000));
    IF COALESCE((v_j->>'success')::boolean, false) OR v_j->>'error' NOT LIKE '%Los cargos dejan sin costo%' THEN
      v_fallas := v_fallas || ('C3 edición con -2000: ' || v_j::text);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('C3 ' || SQLERRM);
  END;

  -- R1 · los rangos en la edición
  BEGIN
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 1557 R1');
    v_j := pg_temp.alta('R1', jsonb_build_array(pg_temp.renglon(v_p, 10, 100)));
    v_c := (v_j->>'compra_id')::bigint;
    v_vistos := pg_temp.vistos(v_c);
    v_j := pg_temp.editar(v_c, jsonb_build_array(pg_temp.renglon(v_p, 10, 100, '{"bonificacion": -50}')), v_vistos);
    IF COALESCE((v_j->>'success')::boolean, false) OR v_j->>'error' NOT LIKE '%la bonificación es un porcentaje, de 0 a 100%' THEN
      v_fallas := v_fallas || ('R1 bonificación -50: ' || v_j::text);
    END IF;
    v_j := pg_temp.editar(v_c, jsonb_build_array(pg_temp.renglon(v_p, 10, -100)), v_vistos);
    IF COALESCE((v_j->>'success')::boolean, false) OR v_j->>'error' NOT LIKE '%el costo no puede ser negativo%' THEN
      v_fallas := v_fallas || ('R1 costo -100: ' || v_j::text);
    END IF;
    v_j := pg_temp.editar(v_c, jsonb_build_array(pg_temp.renglon(v_p, 10, 100, '{"impuestos_internos": "NaN"}')), v_vistos);
    IF COALESCE((v_j->>'success')::boolean, false) OR v_j->>'error' NOT LIKE '%el impuesto interno no es un número%' THEN
      v_fallas := v_fallas || ('R1 II NaN: ' || v_j::text);
    END IF;
    IF (SELECT costo_unitario FROM public.compra_items WHERE compra_id = v_c) IS DISTINCT FROM 100.00 THEN
      v_fallas := v_fallas || 'R1 un rechazo cambió el renglón'::text;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('R1 ' || SQLERRM);
  END;

  -- R2 · los rangos en el alta, y la cabecera
  BEGIN
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 1557 R2');
    v_j := pg_temp.alta('R2a', jsonb_build_array(pg_temp.renglon(v_p, 10, 100,
             '{"porcentaje_iva": 21, "impuestos_internos": -90}')), p_tipo => 'FC', p_iva => 210);
    IF COALESCE((v_j->>'success')::boolean, false) OR v_j->>'error' NOT LIKE '%el impuesto interno es un porcentaje, de 0 a 100%' THEN
      v_fallas := v_fallas || ('R2 II -90: ' || v_j::text);
    END IF;
    v_j := pg_temp.alta('R2b', jsonb_build_array(pg_temp.renglon(v_p, 10, 100, '{"porcentaje_iva": 150}')),
             p_tipo => 'FC', p_iva => 1500);
    IF COALESCE((v_j->>'success')::boolean, false) OR v_j->>'error' NOT LIKE '%la alícuota de IVA es un porcentaje, de 0 a 100%' THEN
      v_fallas := v_fallas || ('R2 alícuota 150: ' || v_j::text);
    END IF;
    v_j := pg_temp.alta('R2c', jsonb_build_array(pg_temp.renglon(v_p, 10, 100, '{"porcentaje_iva": 21}')),
             p_tipo => 'FC', p_iva => 'NaN');
    IF COALESCE((v_j->>'success')::boolean, false) OR v_j->>'error' NOT LIKE '%importe de la cabecera que no es un número%' THEN
      v_fallas := v_fallas || ('R2 IVA NaN: ' || v_j::text);
    END IF;
    v_j := pg_temp.alta('R2d', jsonb_build_array(pg_temp.renglon(v_p, 10, 100, '{"porcentaje_iva": 21}')),
             p_tipo => 'FC', p_iva => -210);
    IF COALESCE((v_j->>'success')::boolean, false) OR v_j->>'error' NOT LIKE '%importe de la cabecera negativo%' THEN
      v_fallas := v_fallas || ('R2 IVA negativo: ' || v_j::text);
    END IF;
    IF (SELECT stock FROM public.productos WHERE id = v_p) <> 0 THEN
      v_fallas := v_fallas || 'R2 un rechazo movió el stock'::text;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('R2 ' || SQLERRM);
  END;

  -- F1 · FRG-1, el bulto de $10.000 con 2.400 unidades
  BEGIN
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 1557 F1');
    v_j := pg_temp.alta('F1a', jsonb_build_array(
             pg_temp.renglon(v_p, 2400, 10000.0 / 2400) || jsonb_build_object('subtotal', 10000)));
    IF COALESCE((v_j->>'success')::boolean, false) OR v_j->>'error' NOT LIKE '%dice 10000.00 y la cantidad por el costo con su bonificación da 10008.00%' THEN
      v_fallas := v_fallas || ('F1 sin redondear: ' || v_j::text);
    END IF;
    v_j := pg_temp.alta('F1b', jsonb_build_array(pg_temp.renglon(v_p, 2400, round(10000.0 / 2400, 2))));
    v_c := (v_j->>'compra_id')::bigint;
    SELECT ci.cantidad * ci.costo_unitario AS renglon, ci.subtotal, c.subtotal AS cab, c.total
      INTO v_r FROM public.compra_items ci JOIN public.compras c ON c.id = ci.compra_id WHERE ci.compra_id = v_c;
    IF NOT COALESCE((v_j->>'success')::boolean, false) OR v_r.renglon <> v_r.subtotal OR v_r.cab <> 10008.00 THEN
      v_fallas := v_fallas || format('F1 al centavo: %s · renglón %s subtotal %s cabecera %s', v_j, v_r.renglon, v_r.subtotal, v_r.cab);
    END IF;
    -- reabrir: los renglones como los arma la hidratación (cantidad × costo guardado)
    SELECT jsonb_agg(pg_temp.renglon(producto_id, cantidad, costo_unitario) ORDER BY id) INTO v_j
      FROM public.compra_items WHERE compra_id = v_c;
    v_j := pg_temp.editar(v_c, v_j, pg_temp.vistos(v_c));
    SELECT subtotal, total INTO v_r FROM public.compras WHERE id = v_c;
    IF NOT COALESCE((v_j->>'success')::boolean, false) OR v_r.subtotal <> 10008.00 OR v_r.total <> 10008.00 THEN
      v_fallas := v_fallas || format('F1 reabrir sin cambios: %s · cabecera %s / %s', v_j, v_r.subtotal, v_r.total);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('F1 ' || SQLERRM);
  END;

  -- F4 · FRG-4, dos ediciones de la misma compra
  BEGIN
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 1557 F4 p1');
    v_q := pg_temp.producto(v_s1, 'ZZ ensayo 1557 F4 p2');
    v_j := pg_temp.alta('F4', jsonb_build_array(pg_temp.renglon(v_p, 10, 100), pg_temp.renglon(v_q, 5, 200)));
    v_c := (v_j->>'compra_id')::bigint;
    v_vistos := pg_temp.vistos(v_c);          -- A y B abren la compra a la vez
    v_j := pg_temp.editar(v_c, jsonb_build_array(pg_temp.renglon(v_p, 12, 100), pg_temp.renglon(v_q, 5, 200)), v_vistos);
    IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
      v_fallas := v_fallas || ('F4 la primera edición: ' || v_j::text);
    END IF;
    v_j := pg_temp.editar(v_c, jsonb_build_array(pg_temp.renglon(v_p, 10, 100), pg_temp.renglon(v_q, 5, 210)), v_vistos);
    IF COALESCE((v_j->>'success')::boolean, false) OR v_j->>'error' NOT LIKE 'Alguien la cambió%' THEN
      v_fallas := v_fallas || ('F4 la segunda edición: ' || v_j::text);
    END IF;
    IF (SELECT cantidad FROM public.compra_items WHERE compra_id = v_c AND producto_id = v_p) IS DISTINCT FROM 12
       OR (SELECT stock FROM public.productos WHERE id = v_p) IS DISTINCT FROM 12
       OR (SELECT costo_unitario FROM public.compra_items WHERE compra_id = v_c AND producto_id = v_q) IS DISTINCT FROM 200.00 THEN
      v_fallas := v_fallas || 'F4 la segunda edición pisó la primera'::text;
    END IF;
    v_j := pg_temp.editar(v_c, jsonb_build_array(pg_temp.renglon(v_p, 12, 100), pg_temp.renglon(v_q, 5, 210)), NULL);
    IF COALESCE((v_j->>'success')::boolean, false) OR v_j->>'error' NOT LIKE '%recargá la página%' THEN
      v_fallas := v_fallas || ('F4 sin renglones vistos: ' || v_j::text);
    END IF;
    -- la misma, con la versión de hoy, entra
    v_j := pg_temp.editar(v_c, jsonb_build_array(pg_temp.renglon(v_p, 12, 100), pg_temp.renglon(v_q, 5, 210)), pg_temp.vistos(v_c));
    IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
      v_fallas := v_fallas || ('F4 con la versión de hoy: ' || v_j::text);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('F4 ' || SQLERRM);
  END;

  -- Z5 · CMP-5, el costo 0 y el regalo legal
  BEGIN
    v_cc0 := pg_temp.chk('COMPRA-C');
    v_ce0 := pg_temp.chk('COMPRA-E');
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 1557 Z5');
    v_j := pg_temp.alta('Z5a', jsonb_build_array(pg_temp.renglon(v_p, 10, 0)));
    IF COALESCE((v_j->>'success')::boolean, false) OR v_j->>'error' NOT LIKE '%el costo es 0: si viene sin cargo, cargalo con bonificación del 100 \%%' THEN
      v_fallas := v_fallas || ('Z5 costo 0 sin bonificación: ' || v_j::text);
    END IF;
    v_j := pg_temp.alta('Z5b', jsonb_build_array(pg_temp.renglon(v_p, 10, 100),
                                                pg_temp.renglon(v_p, 2, 0, '{"bonificacion": 100}'),
                                                pg_temp.renglon(v_p, 2, 100, '{"bonificacion": 100}')));
    v_c := (v_j->>'compra_id')::bigint;
    IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
      v_fallas := v_fallas || ('Z5 regalo legal: ' || v_j::text);
    END IF;
    IF pg_temp.chk('COMPRA-C') <> v_cc0 OR pg_temp.chk('COMPRA-E') <> v_ce0 THEN
      v_fallas := v_fallas || format('Z5 el regalo legal cuenta: COMPRA-C %s → %s, COMPRA-E %s → %s',
                                     v_cc0, pg_temp.chk('COMPRA-C'), v_ce0, pg_temp.chk('COMPRA-E'));
    END IF;
    -- control negativo: un renglón a costo 0 sin bonificación, puesto a mano, sí cuenta
    UPDATE public.compra_items SET costo_unitario = 0, subtotal = 0
     WHERE compra_id = v_c AND bonificacion = 0;
    IF pg_temp.chk('COMPRA-C') <> v_cc0 + 1 THEN
      v_fallas := v_fallas || format('Z5 COMPRA-C no cuenta el costo 0 sin bonificación: %s → %s', v_cc0, pg_temp.chk('COMPRA-C'));
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('Z5 ' || SQLERRM);
  END;

  -- L1 · los permisos
  BEGIN
    IF to_regprocedure('public._compra_renglones_fuera_de_rango(jsonb,bigint)') IS NULL
       OR to_regprocedure('public._compra_costo_real_sin_piso(jsonb,jsonb,bigint)') IS NULL
       OR has_function_privilege('authenticated', 'public._compra_renglones_fuera_de_rango(jsonb,bigint)', 'EXECUTE')
       OR has_function_privilege('anon', 'public._compra_renglones_fuera_de_rango(jsonb,bigint)', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public._compra_costo_real_sin_piso(jsonb,jsonb,bigint)', 'EXECUTE')
       OR has_function_privilege('anon', 'public._compra_costo_real_sin_piso(jsonb,jsonb,bigint)', 'EXECUTE') THEN
      v_fallas := v_fallas || 'L1 los helpers no existen o no son de server'::text;
    END IF;
    IF (SELECT count(*) FROM pg_proc WHERE proname = 'actualizar_compra_items' AND pronamespace = 'public'::regnamespace) <> 1
       OR to_regprocedure('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[])') IS NULL
       OR NOT has_function_privilege('authenticated', 'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[])', 'EXECUTE')
       OR has_function_privilege('anon', 'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[])', 'EXECUTE') THEN
      v_fallas := v_fallas || 'L1 actualizar_compra_items no tiene una sola firma con su EXECUTE'::text;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('L1 ' || SQLERRM);
  END;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · C3 R1 R2 F1 F4 Z5 L1';
END
$ensayo$;
