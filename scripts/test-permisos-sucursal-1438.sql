-- Ensayo de la migración que acota los precios masivos a la sucursal, deja la auditoría para el
-- servidor y le enseña al gate las definer que no nombran la sucursal (#1438).
--
--   P1 · Un admin de una sola sucursal le cambia el precio a un producto suyo.
--   P2 · El mismo admin, a un producto de la otra sucursal: no lo toca y cuenta un error.
--   P3 · Un lote mezclado (suyo, de la otra, inexistente): toca el suyo, y el de la otra
--        sucursal da el mismo error que el que no existe.
--   P4 · Con el header de una sucursal que no es suya, current_sucursal_id() da NULL: no toca
--        nada, ni el producto de la otra, y lo dice.
--   P5 · Un usuario que no es admin: 'No autorizado' y no toca nada.
--   A1 · get_audit_history y get_suspicious_activity no son ejecutables por PUBLIC, anon ni
--        authenticated; service_role sí.
--   G1 · auditoria_rpcs_definer() devuelve 'tablas_sucursal', con actualizar_precios_masivo
--        nombrando la sucursal y sin las dos de auditoría.
--   G2 · Control negativo del gate: una definer nueva que escribe productos sin nombrar la
--        sucursal aparece con nombra_sucursal false; una que sólo lee audit_logs, también; la
--        misma con `AND sucursal_id = current_sucursal_id()`, en true; y una que el API no
--        alcanza, afuera.
--
-- Corre contra prod sin dejar rastro (salvo valores de secuencia): un único DO que termina
-- siempre en una excepción, y cada caso en un sub-bloque que se revierte. Antes de aplicar la
-- migración se corre pegado detrás de su cuerpo, sin el BEGIN y el COMMIT; después, solo.
-- Solo y sin la migración tiene que dar 'ENSAYO FALLÓ' (P2, P3, P4, A1, G1 y G2; P1 y P5 pasan
-- igual).
--
-- Fixtures: un admin activo con una sola sucursal, que sea activa, otra sucursal activa y un
-- usuario activo de la sucursal del admin que no sea admin. Los productos nacen en el ensayo.

CREATE OR REPLACE FUNCTION pg_temp.t_precio(p_id bigint)
RETURNS numeric LANGUAGE sql AS $fn$
  SELECT precio FROM public.productos WHERE id = p_id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_lote(VARIADIC p_items jsonb[])
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT public.actualizar_precios_masivo(to_jsonb(p_items));
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_item(p_id bigint, p_precio numeric)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('producto_id', p_id, 'precio_neto', NULL, 'imp_internos', NULL,
                            'precio_final', p_precio);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_como(p_usuario uuid, p_sucursal bigint)
RETURNS void LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims', json_build_object('sub', p_usuario, 'role', 'authenticated')::text, true),
         set_config('request.headers', json_build_object('x-sucursal-id', p_sucursal::text)::text, true);
$fn$;

/** La fila del gate para una firma, o NULL. */
CREATE OR REPLACE FUNCTION pg_temp.t_gate(p_firma text)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT t FROM jsonb_array_elements(public.auditoria_rpcs_definer()->'tablas_sucursal') t
   WHERE t->>'firma' = p_firma;
$fn$;

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_otra   bigint;
  v_adm    uuid;
  v_otro   uuid;
  v_a      bigint;
  v_b      bigint;
  v_nada   bigint;
  v_j      jsonb;
  v_g      jsonb;
  v_e1     text;
  v_e2     text;
  v_fallas text[] := '{}';
BEGIN
  SELECT us.sucursal_id, us.usuario_id
    INTO v_suc, v_adm
    FROM usuario_sucursales us
    JOIN perfiles pf ON pf.id = us.usuario_id
    JOIN sucursales s ON s.id = us.sucursal_id
   WHERE pf.activo AND pf.rol = 'admin' AND s.activa
     AND (SELECT count(*) FROM usuario_sucursales u2 WHERE u2.usuario_id = us.usuario_id) = 1
   ORDER BY us.sucursal_id, us.usuario_id
   LIMIT 1;
  SELECT s.id INTO v_otra FROM sucursales s WHERE s.activa AND s.id <> v_suc ORDER BY s.id LIMIT 1;
  SELECT us.usuario_id INTO v_otro
    FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
   WHERE us.sucursal_id = v_suc AND pf.activo AND pf.rol <> 'admin'
   ORDER BY us.usuario_id LIMIT 1;
  IF v_adm IS NULL OR v_otra IS NULL OR v_otro IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: un admin de una sola sucursal activa, otra sucursal activa y un no admin de la primera';
  END IF;

  INSERT INTO productos (nombre, precio, precio_sin_iva, stock, sucursal_id)
  VALUES ('ZZ ensayo 1438 propio', 100, 80, 0, v_suc)
  RETURNING id INTO v_a;
  INSERT INTO productos (nombre, precio, precio_sin_iva, stock, sucursal_id)
  VALUES ('ZZ ensayo 1438 ajeno', 100, 80, 0, v_otra)
  RETURNING id INTO v_b;
  v_nada := (SELECT max(id) FROM productos) + 1000;

  -- P1 · un producto propio
  BEGIN
    PERFORM pg_temp.t_como(v_adm, v_suc);
    v_j := pg_temp.t_lote(pg_temp.t_item(v_a, 150));
    IF v_j->>'success' IS DISTINCT FROM 'true' OR v_j->>'actualizados' IS DISTINCT FROM '1'
       OR pg_temp.t_precio(v_a) IS DISTINCT FROM 150 THEN
      v_fallas := v_fallas || format('P1 propio dio %s, precio %s', v_j, pg_temp.t_precio(v_a));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ438';
  EXCEPTION
    WHEN SQLSTATE 'ZZ438' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('P1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- P2 · un producto de la otra sucursal
  BEGIN
    PERFORM pg_temp.t_como(v_adm, v_suc);
    v_j := pg_temp.t_lote(pg_temp.t_item(v_b, 150));
    IF v_j->>'success' IS DISTINCT FROM 'false' OR v_j->>'actualizados' IS DISTINCT FROM '0'
       OR v_j->'errores' IS DISTINCT FROM jsonb_build_array(format('Producto ID %s no encontrado en la sucursal activa', v_b))
       OR pg_temp.t_precio(v_b) IS DISTINCT FROM 100 THEN
      v_fallas := v_fallas || format('P2 ajeno dio %s, precio %s', v_j, pg_temp.t_precio(v_b));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ438';
  EXCEPTION
    WHEN SQLSTATE 'ZZ438' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('P2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- P3 · lote mezclado: el ajeno da el mismo error que el inexistente
  BEGIN
    PERFORM pg_temp.t_como(v_adm, v_suc);
    v_j := pg_temp.t_lote(pg_temp.t_item(v_a, 150), pg_temp.t_item(v_b, 150), pg_temp.t_item(v_nada, 150));
    v_e1 := replace(v_j->'errores'->>0, v_b::text, '#');
    v_e2 := replace(v_j->'errores'->>1, v_nada::text, '#');
    IF v_j->>'success' IS DISTINCT FROM 'false' OR v_j->>'actualizados' IS DISTINCT FROM '1'
       OR jsonb_array_length(v_j->'errores') <> 2 OR v_e1 IS DISTINCT FROM v_e2
       OR pg_temp.t_precio(v_a) IS DISTINCT FROM 150 OR pg_temp.t_precio(v_b) IS DISTINCT FROM 100 THEN
      v_fallas := v_fallas || format('P3 mezclado dio %s, precios %s / %s', v_j, pg_temp.t_precio(v_a), pg_temp.t_precio(v_b));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ438';
  EXCEPTION
    WHEN SQLSTATE 'ZZ438' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('P3 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- P4 · el header pide una sucursal que no es del admin
  BEGIN
    PERFORM pg_temp.t_como(v_adm, v_otra);
    v_j := pg_temp.t_lote(pg_temp.t_item(v_a, 150), pg_temp.t_item(v_b, 150));
    IF v_j->>'success' IS DISTINCT FROM 'false' OR v_j->>'actualizados' IS DISTINCT FROM '0'
       OR v_j->'errores'->>0 !~ 'No hay una sucursal activa'
       OR pg_temp.t_precio(v_a) IS DISTINCT FROM 100 OR pg_temp.t_precio(v_b) IS DISTINCT FROM 100 THEN
      v_fallas := v_fallas || format('P4 header ajeno dio %s, precios %s / %s', v_j, pg_temp.t_precio(v_a), pg_temp.t_precio(v_b));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ438';
  EXCEPTION
    WHEN SQLSTATE 'ZZ438' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('P4 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- P5 · quien no es admin
  BEGIN
    PERFORM pg_temp.t_como(v_otro, v_suc);
    v_j := pg_temp.t_lote(pg_temp.t_item(v_a, 150));
    IF v_j->>'success' IS DISTINCT FROM 'false' OR v_j->>'actualizados' IS DISTINCT FROM '0'
       OR v_j->'errores'->>0 !~ '^No autorizado' OR pg_temp.t_precio(v_a) IS DISTINCT FROM 100 THEN
      v_fallas := v_fallas || format('P5 no admin dio %s, precio %s', v_j, pg_temp.t_precio(v_a));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ438';
  EXCEPTION
    WHEN SQLSTATE 'ZZ438' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('P5 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- A1 · la auditoría, sólo para el servidor
  IF EXISTS (SELECT 1
               FROM unnest(ARRAY['public.get_audit_history(text,text,integer)'::regprocedure,
                                 'public.get_suspicious_activity(integer)'::regprocedure]) f(oid)
              WHERE has_function_privilege('authenticated', f.oid, 'EXECUTE')
                 OR has_function_privilege('anon', f.oid, 'EXECUTE')
                 OR NOT has_function_privilege('service_role', f.oid, 'EXECUTE')
                 OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) x
                             WHERE p.oid = f.oid AND x.grantee = 0)) THEN
    v_fallas := v_fallas || 'A1 get_audit_history o get_suspicious_activity siguen alcanzables desde la API'::text;
  END IF;

  -- G1 · el gate, sobre lo que hay
  BEGIN
    v_g := public.auditoria_rpcs_definer();
    IF jsonb_typeof(v_g->'tablas_sucursal') IS DISTINCT FROM 'array' THEN
      v_fallas := v_fallas || 'G1 auditoria_rpcs_definer no devuelve tablas_sucursal'::text;
    ELSIF (pg_temp.t_gate('actualizar_precios_masivo(jsonb)')->>'nombra_sucursal') IS DISTINCT FROM 'true'
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_g->'tablas_sucursal') t
                   WHERE t->>'nombre' IN ('get_audit_history', 'get_suspicious_activity')) THEN
      v_fallas := v_fallas || format('G1 precios %s; auditoría en la lista: %s',
        pg_temp.t_gate('actualizar_precios_masivo(jsonb)'),
        (SELECT jsonb_agg(t) FROM jsonb_array_elements(v_g->'tablas_sucursal') t
          WHERE t->>'nombre' IN ('get_audit_history', 'get_suspicious_activity')));
    END IF;
  EXCEPTION
    WHEN OTHERS THEN v_fallas := v_fallas || format('G1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- G2 · control negativo: definer nuevas, en un sub-bloque que se revierte
  BEGIN
    EXECUTE $sql$
      CREATE FUNCTION public.zz_ensayo_1438_escribe(p_id bigint) RETURNS void
      LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
      BEGIN
        UPDATE productos SET precio = precio WHERE id = p_id;
      END
      $f$;
      CREATE FUNCTION public.zz_ensayo_1438_lee(p_tabla text) RETURNS bigint
      LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $f$
        SELECT count(*) FROM public.audit_logs al WHERE al.tabla = p_tabla;
      $f$;
      CREATE FUNCTION public.zz_ensayo_1438_server(p_id bigint) RETURNS void
      LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
      BEGIN
        UPDATE productos SET precio = precio WHERE id = p_id;
      END
      $f$;
      REVOKE EXECUTE ON FUNCTION public.zz_ensayo_1438_escribe(bigint) FROM PUBLIC, anon;
      REVOKE EXECUTE ON FUNCTION public.zz_ensayo_1438_lee(text) FROM PUBLIC, anon;
      REVOKE EXECUTE ON FUNCTION public.zz_ensayo_1438_server(bigint) FROM PUBLIC, anon, authenticated;
      GRANT EXECUTE ON FUNCTION public.zz_ensayo_1438_escribe(bigint) TO authenticated;
      GRANT EXECUTE ON FUNCTION public.zz_ensayo_1438_lee(text) TO authenticated;
    $sql$;

    v_g := pg_temp.t_gate('zz_ensayo_1438_escribe(bigint)');
    IF v_g->>'nombra_sucursal' IS DISTINCT FROM 'false' OR NOT (v_g->'tablas' ? 'productos') THEN
      v_fallas := v_fallas || format('G2 la que escribe productos sin sucursal: %s', v_g);
    END IF;
    v_g := pg_temp.t_gate('zz_ensayo_1438_lee(text)');
    IF v_g->>'nombra_sucursal' IS DISTINCT FROM 'false' OR NOT (v_g->'tablas' ? 'audit_logs') THEN
      v_fallas := v_fallas || format('G2 la que lee audit_logs sin sucursal: %s', v_g);
    END IF;
    IF pg_temp.t_gate('zz_ensayo_1438_server(bigint)') IS NOT NULL THEN
      v_fallas := v_fallas || 'G2 la que el API no alcanza aparece en el gate'::text;
    END IF;

    EXECUTE $sql$
      CREATE OR REPLACE FUNCTION public.zz_ensayo_1438_escribe(p_id bigint) RETURNS void
      LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
      BEGIN
        UPDATE productos SET precio = precio WHERE id = p_id AND sucursal_id = current_sucursal_id();
      END
      $f$;
    $sql$;
    v_g := pg_temp.t_gate('zz_ensayo_1438_escribe(bigint)');
    IF v_g->>'nombra_sucursal' IS DISTINCT FROM 'true' THEN
      v_fallas := v_fallas || format('G2 la que acota con current_sucursal_id(): %s', v_g);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ438';
  EXCEPTION
    WHEN SQLSTATE 'ZZ438' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('G2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · P1 P2 P3 P4 P5 A1 G1 G2';
END
$ensayo$;
