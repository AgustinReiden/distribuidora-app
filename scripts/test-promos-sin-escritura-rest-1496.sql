-- Ensayo de la migración que deja los productos y las reglas de una promo sin escritura REST, salvo el alta (#1496).
--
-- Todo lo que hace la app corre como authenticated: `set_config('role', 'authenticated', true)` (un SET LOCAL ROLE)
-- con request.jwt.claims del admin, dentro de un sub-bloque que siempre se revierte.
--
--   D1 · El DELETE REST de promocion_productos da 42501 (permission denied), no 0 filas.
--   D2 · El UPDATE REST de promocion_reglas, ídem.
--   D3 · El DELETE REST de promocion_reglas, ídem.
--   D4 · El upsert de las reglas del bundle viejo (INSERT … ON CONFLICT DO UPDATE, lo que manda PostgREST) da 42501:
--        pide UPDATE.
--   I1 · El alta de una promo como la hace createPromocion: INSERT de promociones, de sus productos y de sus reglas,
--        sin sucursal_id (la pone el trigger). Entra, y authenticated lo lee.
--   I2 · La policy del INSERT conserva su rama: el admin no inserta en otra sucursal y un preventista no inserta en la
--        suya. Las dos dan 42501 por RLS (new row violates row-level security), no por permisos.
--   G1 · Guardar una promo por cambiar_regalo_promocion con p_datos: un producto que entra, uno que sale, una regla
--        que cambia, una que entra y una que sale. Queda conciliada, y authenticated lo lee.
--   B1 · Borrar una promo por REST (promociones.DELETE) borra sus productos y sus reglas: el ON DELETE CASCADE no
--        pide el DELETE de authenticated.
--   P1 · Permisos y policies: authenticated tiene INSERT y SELECT en las dos tablas, ni UPDATE (tampoco por columna)
--        ni DELETE, y anon nada. Cada tabla tiene su policy de SELECT y una FOR INSERT TO authenticated con la rama
--        de admin y sucursal, y ninguna otra. Ninguna función INVOKER de public escribe estas tablas, y
--        cambiar_regalo_promocion es SECURITY DEFINER. El rol volvió a postgres después de cada caso.
--
-- Corre contra prod sin dejar rastro (salvo valores de secuencia): un único DO que termina siempre en una excepción, y
-- cada caso en un sub-bloque que se revierte. El veredicto es 'ENSAYO OK' o 'ENSAYO FALLÓ' en el mensaje. Antes de
-- aplicar la migración se corre pegado detrás de su cuerpo, sin el BEGIN y el COMMIT; después, solo. Solo y sin la
-- migración tiene que dar 'ENSAYO FALLÓ' por D1, D2, D3, D4 y P1; I1, I2, G1 y B1 pasan igual (son lo que no cambia).
--
-- Fixtures: una sucursal activa con un admin activo y un preventista activo, y otra sucursal activa. El resto nace en
-- el ensayo.

CREATE OR REPLACE FUNCTION pg_temp.t_producto(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES (p_nombre, 1, 1000, 1, p_suc)
  RETURNING id;
$fn$;

-- Una promo de bonificación (10 de A → 2 de regalo), sin contenedor. La crea postgres.
CREATE OR REPLACE FUNCTION pg_temp.t_promo(p_suc bigint, p_nombre text, p_a bigint, p_regalo bigint)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_id bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id)
  VALUES (p_nombre, 'bonificacion', public._tablero_hoy() - 1, p_suc, false, p_regalo)
  RETURNING id INTO v_id;
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v_id, 'cantidad_compra', 10, p_suc), (v_id, 'cantidad_bonificacion', 2, p_suc);
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id) VALUES (v_id, p_a, p_suc);
  RETURN v_id;
END
$fn$;

-- Corre p_sql como authenticated (con los claims de p_uid si viene) y lo revierte. Devuelve 'ok <filas>' o
-- '<SQLSTATE> <mensaje>'.
CREATE OR REPLACE FUNCTION pg_temp.t_como_app(p_sql text, p_uid uuid DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
  v_n bigint;
BEGIN
  BEGIN
    IF p_uid IS NOT NULL THEN
      PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
    END IF;
    PERFORM set_config('role', 'authenticated', true);
    EXECUTE p_sql;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RAISE EXCEPTION 'ok %', v_n USING ERRCODE = 'ZZ496';
  EXCEPTION
    WHEN SQLSTATE 'ZZ496' THEN RETURN SQLERRM;
    WHEN OTHERS THEN RETURN SQLSTATE || ' ' || SQLERRM;
  END;
END
$fn$;

-- Los productos y las reglas de una promo, como los ve quien llama. Con p_ids, los productos van por su letra.
CREATE OR REPLACE FUNCTION pg_temp.t_detalle(p_promo bigint, p_ids bigint[], p_letras text[])
RETURNS text LANGUAGE sql AS $fn$
  SELECT format('prods=[%s] reglas=[%s]',
                (SELECT string_agg(COALESCE(p_letras[array_position(p_ids, pp.producto_id)], pp.producto_id::text), ','
                                   ORDER BY pp.producto_id)
                   FROM public.promocion_productos pp WHERE pp.promocion_id = p_promo),
                (SELECT string_agg(r.clave || '=' || r.valor, ',' ORDER BY r.clave)
                   FROM public.promocion_reglas r WHERE r.promocion_id = p_promo));
$fn$;

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_otra   bigint;
  v_adm    uuid;
  v_prev   uuid;
  v_hoy    date := public._tablero_hoy();
  v_a      bigint;
  v_b      bigint;
  v_s      bigint;
  v_a_otra bigint;
  v_b_otra bigint;
  v_p      bigint;
  v_p_otra bigint;
  v_n      bigint;
  v_r      text;
  v_txt    text;
  v_txt2   text;
  v_j      jsonb;
  v_fallas text[] := '{}';
  c        record;
BEGIN
 BEGIN
  SELECT s.id, adm.usuario_id
    INTO v_suc, v_adm
    FROM sucursales s
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'admin'
                   ORDER BY us.usuario_id LIMIT 1) adm ON true
   WHERE s.activa
   ORDER BY s.id
   LIMIT 1;
  SELECT us.usuario_id INTO v_prev
    FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
   WHERE us.sucursal_id = v_suc AND pf.activo AND pf.rol = 'preventista'
   ORDER BY us.usuario_id LIMIT 1;
  SELECT id INTO v_otra FROM sucursales WHERE activa AND id IS DISTINCT FROM v_suc ORDER BY id LIMIT 1;
  IF v_suc IS NULL OR v_prev IS NULL OR v_otra IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: una sucursal activa con un admin y un preventista activos, y otra sucursal activa';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);

  v_a := pg_temp.t_producto(v_suc, 'ZZ ensayo 1496 A');
  v_b := pg_temp.t_producto(v_suc, 'ZZ ensayo 1496 B');
  v_s := pg_temp.t_producto(v_suc, 'ZZ ensayo 1496 S');
  v_a_otra := pg_temp.t_producto(v_otra, 'ZZ ensayo 1496 A otra');
  v_b_otra := pg_temp.t_producto(v_otra, 'ZZ ensayo 1496 B otra');
  v_p := pg_temp.t_promo(v_suc, 'ZZ ensayo 1496', v_a, v_s);
  v_p_otra := pg_temp.t_promo(v_otra, 'ZZ ensayo 1496 otra', v_a_otra, v_a_otra);

  -- D1 a D4 · las escrituras de la conciliación vieja, como authenticated (el admin de la sucursal)
  FOR c IN
    SELECT * FROM (VALUES
      ('D1', format('DELETE FROM public.promocion_productos WHERE promocion_id = %s', v_p), 'promocion_productos'),
      ('D2', format('UPDATE public.promocion_reglas SET valor = 11 WHERE promocion_id = %s AND clave = %L',
                    v_p, 'cantidad_compra'), 'promocion_reglas'),
      ('D3', format('DELETE FROM public.promocion_reglas WHERE promocion_id = %s', v_p), 'promocion_reglas'),
      ('D4', format('INSERT INTO public.promocion_reglas (promocion_id, clave, valor) VALUES (%s, %L, 11)'
                    || ' ON CONFLICT (promocion_id, clave) DO UPDATE SET valor = EXCLUDED.valor', v_p, 'cantidad_compra'),
       'promocion_reglas')
    ) AS x(caso, sql, tabla)
  LOOP
    v_r := pg_temp.t_como_app(c.sql);
    IF v_r NOT LIKE '42501 permission denied for table ' || c.tabla THEN
      v_fallas := v_fallas || format('%s dio «%s»', c.caso, v_r);
    END IF;
  END LOOP;

  -- I1 · el alta como createPromocion
  BEGIN
    PERFORM set_config('role', 'authenticated', true);
    INSERT INTO public.promociones (nombre, tipo, fecha_inicio, fecha_fin, limite_usos, producto_regalo_id, prioridad,
                                    regalo_mueve_stock, modo_exclusion, ajuste_automatico, ajuste_producto_id,
                                    unidades_por_bloque, stock_por_bloque, descripcion_regalo)
    VALUES ('ZZ ensayo 1496 I1', 'bonificacion', v_hoy, NULL, NULL, v_s, 0, false, 'acumulable', false, NULL, NULL,
            NULL, NULL)
    RETURNING id INTO v_n;
    INSERT INTO public.promocion_productos (promocion_id, producto_id) VALUES (v_n, v_a), (v_n, v_b);
    INSERT INTO public.promocion_reglas (promocion_id, clave, valor)
    VALUES (v_n, 'cantidad_compra', 10), (v_n, 'cantidad_bonificacion', 2);
    v_txt := pg_temp.t_detalle(v_n, ARRAY[v_a, v_b], ARRAY['A', 'B']);
    v_txt2 := (SELECT string_agg(DISTINCT sucursal_id::text, ',') FROM (
                 SELECT sucursal_id FROM public.promocion_productos WHERE promocion_id = v_n
                 UNION ALL SELECT sucursal_id FROM public.promocion_reglas WHERE promocion_id = v_n) x);
    IF current_user <> 'authenticated'
       OR v_txt IS DISTINCT FROM 'prods=[A,B] reglas=[cantidad_bonificacion=2,cantidad_compra=10]'
       OR v_txt2 IS DISTINCT FROM v_suc::text THEN
      v_fallas := v_fallas || format('I1 como %s: %s, sucursal %s', current_user, v_txt, v_txt2);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ496';
  EXCEPTION
    WHEN SQLSTATE 'ZZ496' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('I1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- I2 · la rama del INSERT: el admin en otra sucursal, el preventista en la suya
  FOR c IN
    SELECT * FROM (VALUES
      ('I2 admin en otra sucursal (productos)', NULL::uuid, 'promocion_productos',
       format('INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id) VALUES (%s, %s, %s)',
              v_p_otra, v_b_otra, v_otra)),
      ('I2 admin en otra sucursal (reglas)', NULL::uuid, 'promocion_reglas',
       format('INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id) VALUES (%s, %L, 1, %s)',
              v_p_otra, 'zz_ensayo', v_otra)),
      ('I2 preventista (productos)', v_prev, 'promocion_productos',
       format('INSERT INTO public.promocion_productos (promocion_id, producto_id) VALUES (%s, %s)', v_p, v_b)),
      ('I2 preventista (reglas)', v_prev, 'promocion_reglas',
       format('INSERT INTO public.promocion_reglas (promocion_id, clave, valor) VALUES (%s, %L, 1)', v_p, 'zz_ensayo'))
    ) AS x(caso, uid, tabla, sql)
  LOOP
    v_r := pg_temp.t_como_app(c.sql, c.uid);
    IF v_r NOT LIKE '42501 new row violates row-level security policy for table "' || c.tabla || '"' THEN
      v_fallas := v_fallas || format('%s dio «%s»', c.caso, v_r);
    END IF;
  END LOOP;
  -- Control: el admin sí inserta en su sucursal (lo que I2 le niega a los otros dos).
  v_r := pg_temp.t_como_app(format('INSERT INTO public.promocion_reglas (promocion_id, clave, valor) VALUES (%s, %L, 1)',
                                   v_p, 'zz_ensayo'));
  IF v_r <> 'ok 1' THEN
    v_fallas := v_fallas || format('I2 control: el admin no insertó en su sucursal: «%s»', v_r);
  END IF;

  -- G1 · guardar la promo por la RPC, como authenticated
  BEGIN
    INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id) VALUES (v_p, 'zz_sale', 1, v_suc);
    PERFORM set_config('role', 'authenticated', true);
    v_j := public.cambiar_regalo_promocion(v_p, v_s, NULL, false, jsonb_build_object(
      'nombre', 'ZZ ensayo 1496 G1', 'tipo', 'bonificacion', 'fecha_inicio', v_hoy - 1, 'fecha_fin', NULL,
      'limite_usos', NULL, 'prioridad', 0, 'regalo_mueve_stock', false, 'modo_exclusion', 'acumulable',
      'unidades_por_bloque', NULL, 'stock_por_bloque', NULL, 'descripcion_regalo', NULL,
      'producto_ids', jsonb_build_array(v_b),
      'reglas', jsonb_build_array(jsonb_build_object('clave', 'cantidad_compra', 'valor', 12),
                                  jsonb_build_object('clave', 'cantidad_bonificacion', 'valor', 2),
                                  jsonb_build_object('clave', 'zz_entra', 'valor', 7))));
    v_txt := pg_temp.t_detalle(v_p, ARRAY[v_a, v_b], ARRAY['A', 'B']);
    -- (`cambio` de la respuesta es el del regalo, que acá no cambia: no se mira.)
    IF current_user <> 'authenticated' OR NOT COALESCE((v_j->>'success')::boolean, false)
       OR (SELECT nombre FROM public.promociones WHERE id = v_p) IS DISTINCT FROM 'ZZ ensayo 1496 G1'
       OR v_txt IS DISTINCT FROM 'prods=[B] reglas=[cantidad_bonificacion=2,cantidad_compra=12,zz_entra=7]' THEN
      v_fallas := v_fallas || format('G1 como %s dio %s · %s', current_user, v_j, v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ496';
  EXCEPTION
    WHEN SQLSTATE 'ZZ496' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('G1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- B1 · borrar la promo por REST se lleva sus productos y sus reglas
  BEGIN
    PERFORM set_config('role', 'authenticated', true);
    v_txt := pg_temp.t_detalle(v_p, ARRAY[v_a, v_b], ARRAY['A', 'B']);
    DELETE FROM public.promociones WHERE id = v_p;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_txt2 := pg_temp.t_detalle(v_p, ARRAY[v_a, v_b], ARRAY['A', 'B']);
    IF current_user <> 'authenticated' OR v_n <> 1
       OR v_txt IS DISTINCT FROM 'prods=[A] reglas=[cantidad_bonificacion=2,cantidad_compra=10]'
       OR v_txt2 IS DISTINCT FROM 'prods=[] reglas=[]'
       OR EXISTS (SELECT 1 FROM public.promocion_productos WHERE promocion_id = v_p)
       OR EXISTS (SELECT 1 FROM public.promocion_reglas WHERE promocion_id = v_p) THEN
      v_fallas := v_fallas || format('B1 como %s borró %s promos · antes %s · después %s', current_user, v_n, v_txt, v_txt2);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ496';
  EXCEPTION
    WHEN SQLSTATE 'ZZ496' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('B1 dio %s: %s', SQLSTATE, SQLERRM);
  END;
  -- Ningún sub-bloque se llevó la promo de verdad.
  IF NOT EXISTS (SELECT 1 FROM public.promociones WHERE id = v_p) THEN
    v_fallas := v_fallas || 'B1 la promo no volvió después del sub-bloque'::text;
  END IF;

  -- P1 · permisos, policies y el rol
  FOR c IN SELECT unnest(ARRAY['promocion_productos', 'promocion_reglas']) AS tabla LOOP
    IF NOT has_table_privilege('authenticated', 'public.' || c.tabla, 'INSERT')
       OR NOT has_table_privilege('authenticated', 'public.' || c.tabla, 'SELECT')
       OR has_table_privilege('authenticated', 'public.' || c.tabla, 'UPDATE')
       OR has_table_privilege('authenticated', 'public.' || c.tabla, 'DELETE')
       OR has_any_column_privilege('authenticated', 'public.' || c.tabla, 'UPDATE')
       OR has_table_privilege('anon', 'public.' || c.tabla, 'SELECT, INSERT, UPDATE, DELETE')
       OR has_any_column_privilege('anon', 'public.' || c.tabla, 'SELECT, INSERT, UPDATE') THEN
      v_fallas := v_fallas || format('P1 los permisos de %s no son INSERT y SELECT para authenticated y nada para anon',
                                     c.tabla);
    END IF;
    v_txt := (SELECT string_agg(p.policyname || ' ' || p.cmd || ' ' || p.roles::text
                                || ' USING ' || COALESCE(p.qual, '-') || ' CHECK ' || COALESCE(p.with_check, '-'),
                                ' | ' ORDER BY p.policyname)
                FROM pg_policies p WHERE p.schemaname = 'public' AND p.tablename = c.tabla);
    IF v_txt IS DISTINCT FROM format(
         'mt_%1$s_insert INSERT {authenticated} USING - CHECK (es_admin() AND (sucursal_id = current_sucursal_id()))'
         || ' | mt_%1$s_select SELECT {authenticated} USING (sucursal_id = current_sucursal_id()) CHECK -', c.tabla) THEN
      v_fallas := v_fallas || format('P1 las policies de %s son: %s', c.tabla, v_txt);
    END IF;
  END LOOP;
  v_txt := (SELECT string_agg(p.oid::regprocedure::text, ', ')
              FROM pg_proc p
             WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f' AND NOT p.prosecdef
               AND pg_get_functiondef(p.oid) ~* '(update|delete\s+from|insert\s+into)\s+(public\.)?promocion_(reglas|productos)');
  IF v_txt IS NOT NULL THEN
    v_fallas := v_fallas || format('P1 funciones INVOKER que escriben estas tablas como quien llama: %s', v_txt);
  END IF;
  IF NOT (SELECT prosecdef FROM pg_proc
           WHERE oid = 'public.cambiar_regalo_promocion(bigint,bigint,bigint,boolean,jsonb)'::regprocedure) THEN
    v_fallas := v_fallas || 'P1 cambiar_regalo_promocion no es SECURITY DEFINER'::text;
  END IF;
  IF current_user = 'authenticated' THEN
    v_fallas := v_fallas || 'P1 el rol no volvió después de los sub-bloques'::text;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · D1 D2 D3 D4 I1 I2 G1 B1 P1';
 END;
END
$ensayo$;
