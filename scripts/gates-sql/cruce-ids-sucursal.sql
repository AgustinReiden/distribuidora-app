-- Gate del cruce por ids de otra sucursal (#1564, 1564-g2). Lo corre scripts/check-cruce-ids.mjs.
--
-- Qué hace: arma dos sucursales (A = la 1, B = la 2) con un usuario de cada rol en A y, en B,
-- un cliente, un pedido, un pago y una compra con un nombre-marca. Después llama, COMO CADA
-- USUARIO DE A (con `SET LOCAL ROLE authenticated`, los claims y la cabecera de sucursal que
-- pone PostgREST), a cada RPC que recibe un id de pedido, cliente, pago o compra, pasándole el
-- id de B. Una llamada es un hallazgo si, sin rechazarse:
--   · cambia una sola fila de B (el hash de todas las tablas con sucursal_id antes y después), o
--   · devuelve la marca de B (lee lo que no es suyo).
-- Cada llamada va en un sub-bloque que se deshace, y el DO entero termina en una excepción:
-- NADA queda en la base. El resultado vuelve en el mensaje de esa excepción (GATE_RESULT:{json}).
--
-- Lo que NO prueba (el resto de #1564-g2): sólo las RPC con un parámetro p_pedido_id,
-- p_pedido_ids, p_pedido_item_id, p_cliente_id, p_nuevo_cliente_id, p_pago_id o p_compra_id;
-- los demás argumentos son de relleno por tipo (jsonb '[]', texto 'x', números 1…), así que
-- una RPC que los rechaza antes de llegar a mirar la sucursal queda como «rechazada por los
-- argumentos» y no prueba nada sobre su aislamiento (el resultado cuenta cuántas son). No
-- prueba las lecturas por REST (eso lo hacen las policies y check-rama-admin), ni ids de
-- producto, proveedor, ruta o recorrido, ni al actor desactivado.
--
-- Necesita una base DESCARTABLE con las sucursales 1 y 2 (la semilla de docker-local.mjs) y
-- corre como postgres. NO se corre contra prod: check-cruce-ids.mjs se niega.
DO $gate$
DECLARE
  c_a CONSTANT bigint := 1;
  c_b CONSTANT bigint := 2;
  c_marca CONSTANT text := 'ZZGATE-MARCA-B';
  v_n bigint; v_j jsonb; v_u uuid;
  v_actores text[] := ARRAY['admin', 'encargado', 'preventista', 'transportista', 'deposito'];
  v_uids jsonb := '{}'::jsonb;
  v_adm_b uuid; v_tra_a uuid;
  v_prod_a bigint; v_prod_b bigint; v_cli_a bigint; v_cli_b bigint; v_cli_b2 bigint;
  v_ped_b bigint; v_item_b bigint; v_pago_b bigint; v_compra_b bigint;
  v_snap_sql text; v_antes text; v_despues text;
  f record; a text; v_cab text;
  v_ids jsonb;
  v_args text; v_call text; v_sql text; v_sql_base text; v_res text;
  v_hallazgos jsonb := '[]'::jsonb;
  v_probadas int := 0; v_funcs int := 0; v_aceptadas int := 0; v_rech_acceso int := 0; v_rech_previa int := 0;
  v_previas jsonb := '[]'::jsonb;
  v_estado text; v_msg text; v_state text; v_marca_vista boolean; v_cambio boolean;
BEGIN
  SET LOCAL lock_timeout = '5s';
  SET LOCAL statement_timeout = '30s';

  IF NOT EXISTS (SELECT 1 FROM public.sucursales WHERE id = c_a) OR NOT EXISTS (SELECT 1 FROM public.sucursales WHERE id = c_b) THEN
    RAISE EXCEPTION 'GATE_FIXTURE: hacen falta las sucursales 1 y 2 (docker-local.mjs semilla)';
  END IF;

  -- ===== personas =====
  FOREACH a IN ARRAY v_actores LOOP
    v_u := gen_random_uuid();
    INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    VALUES (v_u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'gate-cruce-' || a || '-' || v_u || '@ensayo.invalid',
            jsonb_build_object('rol', a, 'sucursal_id', c_a), jsonb_build_object('nombre', 'GATE ' || a), now(), now());
    v_uids := v_uids || jsonb_build_object(a, v_u);
  END LOOP;
  v_adm_b := gen_random_uuid();
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  VALUES (v_adm_b, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'gate-cruce-admB-' || v_adm_b || '@ensayo.invalid',
          jsonb_build_object('rol', 'admin', 'sucursal_id', c_b), jsonb_build_object('nombre', 'GATE admin B'), now(), now());
  v_tra_a := (v_uids ->> 'transportista')::uuid;

  -- ===== catálogo, clientes y entidades =====
  INSERT INTO public.politicas_comerciales (sucursal_id)
  SELECT s FROM unnest(ARRAY[c_a, c_b]) s
   WHERE NOT EXISTS (SELECT 1 FROM public.politicas_comerciales p WHERE p.sucursal_id = s);
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id) VALUES ('GATE P-A', 100, 1000, 60, c_a) RETURNING id INTO v_prod_a;
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id) VALUES ('GATE P-B', 100, 1000, 60, c_b) RETURNING id INTO v_prod_b;
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id) VALUES ('GATE C-A', 'GATE C-A', 'calle a', c_a) RETURNING id INTO v_cli_a;
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id) VALUES (c_marca, c_marca, 'calle b', c_b) RETURNING id INTO v_cli_b;
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id) VALUES (c_marca || '-2', c_marca || '-2', 'calle b2', c_b) RETURNING id INTO v_cli_b2;

  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm_b, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', c_b::text)::text, true);
  v_j := public.crear_pedido_completo(v_cli_b, 100, v_adm_b,
           jsonb_build_array(jsonb_build_object('producto_id', v_prod_b, 'cantidad', 1, 'precio_unitario', 100)), c_marca || ' pedido');
  IF NOT COALESCE((v_j ->> 'success')::boolean, false) THEN
    RAISE EXCEPTION 'GATE_FIXTURE: no pude crear el pedido de la sucursal B: %', v_j;
  END IF;
  v_ped_b := (v_j ->> 'pedido_id')::bigint;
  PERFORM set_config('request.jwt.claims', '{}', true);
  PERFORM set_config('request.headers', '{}', true);
  SELECT id INTO v_item_b FROM public.pedido_items WHERE pedido_id = v_ped_b ORDER BY id LIMIT 1;

  INSERT INTO public.pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha)
  VALUES (v_cli_b, v_ped_b, c_b, 40, 'efectivo', (now() AT TIME ZONE 'America/Argentina/Tucuman')::date) RETURNING id INTO v_pago_b;
  INSERT INTO public.compras (sucursal_id, subtotal, total, notas) VALUES (c_b, 600, 600, c_marca || ' compra') RETURNING id INTO v_compra_b;
  INSERT INTO public.compra_items (compra_id, producto_id, cantidad, costo_unitario, subtotal, sucursal_id)
  VALUES (v_compra_b, v_prod_b, 10, 60, 600, c_b);

  v_ids := jsonb_build_object(
    'p_pedido_id', v_ped_b, 'p_pedido_reprogramado_id', v_ped_b, 'p_pedido_ids', v_ped_b,
    'p_pedido_item_id', v_item_b, 'p_cliente_id', v_cli_b, 'p_nuevo_cliente_id', v_cli_b2,
    'p_pago_id', v_pago_b, 'p_compra_id', v_compra_b);

  -- ===== el hash de todo lo de B =====
  SELECT 'SELECT md5(COALESCE(string_agg(t || h, ''|'' ORDER BY t), '''')) FROM (' ||
         string_agg(format('SELECT %L AS t, md5(COALESCE(string_agg(md5(x::text), '','' ORDER BY md5(x::text)), '''')) AS h FROM public.%I x WHERE x.sucursal_id = %s',
                           c.relname, c.relname, c_b), ' UNION ALL ' ORDER BY c.relname) || ') s'
    INTO v_snap_sql
    FROM pg_class c
    JOIN pg_attribute at ON at.attrelid = c.oid AND at.attname = 'sucursal_id' AND NOT at.attisdropped
   WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p');
  EXECUTE v_snap_sql INTO v_antes;

  -- ===== las RPC con un id de entidad =====
  FOR f IN
    SELECT p.oid, p.oid::regprocedure::text AS firma, p.proname, p.prorettype, p.proretset, p.pronargdefaults,
           (SELECT jsonb_agg(jsonb_build_object('n', n, 't', t) ORDER BY o)
              FROM (SELECT x.n, x.t, x.o
                      FROM unnest(COALESCE(p.proallargtypes::oid[], p.proargtypes::oid[]),
                                  COALESCE(p.proargmodes::text[], array_fill('i'::text, ARRAY[cardinality(COALESCE(p.proallargtypes::oid[], p.proargtypes::oid[]))])),
                                  p.proargnames) WITH ORDINALITY AS x(t, m, n, o)
                     WHERE x.m IN ('i', 'b', 'v')) q) AS entradas
      FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'
       AND p.prorettype <> 'trigger'::regtype
       AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
     ORDER BY p.oid::regprocedure::text
  LOOP
    -- Los parámetros de la RPC: el id de B donde el nombre lo pide, relleno por tipo en el resto.
    IF f.entradas IS NULL OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(f.entradas) e WHERE v_ids ? (e ->> 'n')) THEN CONTINUE; END IF;
    DECLARE
      v_total int := jsonb_array_length(f.entradas);
      v_i int := 0; e jsonb; v_t text; v_val text; v_partes text[] := '{}';
    BEGIN
      FOR e IN SELECT value FROM jsonb_array_elements(f.entradas) LOOP
        v_i := v_i + 1;
        v_t := format_type((e ->> 't')::oid, NULL);
        IF v_ids ? (e ->> 'n') THEN
          IF v_t LIKE '%[]' THEN v_val := format('ARRAY[%s]::%s', v_ids ->> (e ->> 'n'), v_t);
          ELSE v_val := format('%s::%s', v_ids ->> (e ->> 'n'), v_t);
          END IF;
        ELSIF v_i > v_total - f.pronargdefaults THEN
          CONTINUE;  -- tiene DEFAULT: no se pasa
        ELSIF v_t IN ('bigint', 'integer', 'smallint', 'numeric') THEN v_val := format('1::%s', v_t);
        ELSIF v_t IN ('text', 'character varying') THEN v_val := format('%L::%s', 'x', v_t);
        ELSIF v_t = 'uuid' THEN v_val := '''@UID@''::uuid';  -- el propio actor: la RPC que compara con auth.uid() no corta por eso
        ELSIF v_t IN ('jsonb', 'json') THEN v_val := format('%L::%s', '[]', v_t);
        ELSIF v_t = 'date' THEN v_val := 'current_date';
        ELSIF v_t LIKE 'timestamp%' THEN v_val := format('now()::%s', v_t);
        ELSIF v_t = 'boolean' THEN v_val := 'false';
        ELSIF v_t LIKE '%[]' THEN v_val := format('%L::%s', '{}', v_t);
        ELSE v_val := format('NULL::%s', v_t);
        END IF;
        v_partes := v_partes || format('%I => %s', e ->> 'n', v_val);
      END LOOP;
      v_args := array_to_string(v_partes, ', ');
    END;
    v_funcs := v_funcs + 1;
    v_call := format('public.%I(%s)', f.proname, v_args);
    v_sql_base := CASE
      WHEN f.prorettype = 'void'::regtype THEN format('SELECT (%s)::text', v_call)
      WHEN f.proretset THEN format('SELECT COALESCE(jsonb_agg(to_jsonb(t)), ''[]''::jsonb)::text FROM %s t', v_call)
      ELSE format('SELECT to_jsonb(%s)::text', v_call) END;

    FOREACH a IN ARRAY v_actores LOOP
      FOREACH v_cab IN ARRAY ARRAY[c_a::text, c_b::text] LOOP
        -- Cabecera de B sólo para el admin: «ajena» para quien no pertenece a B.
        IF v_cab = c_b::text AND a <> 'admin' THEN CONTINUE; END IF;
        v_probadas := v_probadas + 1;
        v_sql := replace(v_sql_base, '@UID@', v_uids ->> a);
        v_estado := NULL; v_msg := NULL; v_marca_vista := false; v_cambio := false;
        BEGIN
          PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uids ->> a, 'role', 'authenticated')::text, true);
          PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_cab)::text, true);
          EXECUTE 'SET LOCAL ROLE authenticated';
          EXECUTE v_sql INTO v_res;
          EXECUTE 'RESET ROLE';
          EXECUTE v_snap_sql INTO v_despues;
          v_cambio := v_despues IS DISTINCT FROM v_antes;
          v_marca_vista := position(c_marca IN COALESCE(v_res, '')) > 0;
          v_estado := 'aceptada';
          -- Muchas RPC rechazan devolviendo {"success": false, "error": …} en vez de levantar.
          IF COALESCE(v_res, '') ~ '"success": ?false' THEN
            v_estado := 'rechazada'; v_state := NULL; v_msg := v_res;
          END IF;
          RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ001';
        EXCEPTION
          WHEN SQLSTATE 'ZZ001' THEN NULL;
          WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
            v_estado := 'rechazada';
        END;
        IF v_cambio OR v_marca_vista THEN
          v_hallazgos := v_hallazgos || jsonb_build_object('firma', f.firma, 'actor', a, 'cabecera', v_cab,
            'que', CASE WHEN v_cambio AND v_marca_vista THEN 'cambia y devuelve datos de B'
                        WHEN v_cambio THEN 'cambia filas de B' ELSE 'devuelve datos de B' END);
        ELSIF v_estado = 'aceptada' THEN
          v_aceptadas := v_aceptadas + 1;
        ELSIF v_state = '42501' OR COALESCE(v_msg, '') ~* '(sucursal|permiso|acceso|autoriz|rol|no encontrad|no existe|no pertenece|ajen|s[oó]lo un|solo un|administrador|encargado|denied)' THEN
          v_rech_acceso := v_rech_acceso + 1;
        ELSE
          v_rech_previa := v_rech_previa + 1;
          v_previas := v_previas || jsonb_build_object('firma', f.firma, 'actor', a, 'estado', v_state, 'mensaje', left(v_msg, 80));
        END IF;
      END LOOP;
    END LOOP;
  END LOOP;

  RAISE EXCEPTION 'GATE_RESULT:%', jsonb_build_object(
    'probadas', v_probadas, 'aceptadas', v_aceptadas,
    'rechazadas_por_acceso', v_rech_acceso, 'rechazadas_por_los_argumentos', v_rech_previa,
    'funciones', v_funcs,
    'hallazgos', v_hallazgos, 'previas', v_previas)::text;
END
$gate$;
