-- Ensayo de la migración que deja de releer los contenedores con la promo tomada (#1501, puntos 1, 2 y 3).
--
-- El 40P01 lo mide el arnés (scripts/concurrencia, `t6`: T6o, con su control negativo). Acá, en una sola sesión, que
-- guardar una promo hace lo mismo que antes y que el aviso al trigger no sale de su sentencia:
--
--   E1 · Un guardado con p_datos que cambia el regalo, el contenedor y el factor y cierra 3 bloques con stock de
--        sobra: entra, rota la barra, descuenta 3 del contenedor y, después de la llamada,
--        app.promo_contenedores_tomados queda vacío.
--   E2 · El mismo cambio con el contenedor sin stock: {success: false, codigo: 'contenedor_sin_stock'}, la promo y el
--        contenedor quedan como estaban, y el GUC también queda vacío (lo deshace el bloque de excepción).
--   E3 · La llamada de cuatro argumentos (el bundle viejo) cambia el regalo y nada más, sin tocar el GUC.
--   E4 · Un UPDATE del factor fuera de la RPC (el camino REST del admin, o el server) sigue corriendo el trigger de
--        sentencia y renormaliza igual.
--   L1 · Los cuerpos y los EXECUTE de promo_factor_bloquea_contenedores, cambiar_regalo_promocion, _rendicion_pagos
--        y _alta_bloquea_boletas_credito son los de la migración (en las dos últimas sólo cambia un comentario).
--
-- Corre contra prod sin dejar rastro (salvo valores de secuencia): un único DO que termina siempre en una excepción, y
-- cada caso en un sub-bloque que se revierte. Antes de aplicar la migración se corre pegado detrás de su cuerpo, sin
-- el BEGIN y el COMMIT; después, solo. Solo y sin la migración tiene que dar 'ENSAYO FALLÓ', únicamente por L1.
--
-- Fixtures: una sucursal activa con un admin activo y la caja de hoy abierta. El resto nace en el ensayo.

CREATE OR REPLACE FUNCTION pg_temp.t_producto(p_suc bigint, p_nombre text, p_stock int DEFAULT 1000)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES (p_nombre, 1, p_stock, 1, p_suc)
  RETURNING id;
$fn$;

-- Una promo de bonificación (10 de A → 2 de regalo), con ajuste automático, factor 6/1 y la barra dada.
CREATE OR REPLACE FUNCTION pg_temp.t_promo(p_suc bigint, p_nombre text, p_a bigint, p_regalo bigint, p_cont bigint,
                                           p_usos int)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_id bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id,
                                  ajuste_automatico, ajuste_producto_id, unidades_por_bloque, stock_por_bloque,
                                  usos_pendientes)
  VALUES (p_nombre, 'bonificacion', public._tablero_hoy() - 1, p_suc, false, p_regalo,
          true, p_cont, 6, 1, p_usos)
  RETURNING id INTO v_id;
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v_id, 'cantidad_compra', 10, p_suc), (v_id, 'cantidad_bonificacion', 2, p_suc);
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id) VALUES (v_id, p_a, p_suc);
  RETURN v_id;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_estado(p_promo bigint, p_cont bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT format('regalo=%s cont=%s factor=%s/%s usos=%s acum=[%s] ajustes=%s stock_cont=%s',
                pr.producto_regalo_id, pr.ajuste_producto_id, pr.unidades_por_bloque, pr.stock_por_bloque,
                pr.usos_pendientes,
                (SELECT string_agg(a.producto_regalo_id || ':' || a.ajuste_producto_id || ':' || a.usos_pendientes, ','
                                   ORDER BY a.producto_regalo_id)
                   FROM public.promo_acumuladores a WHERE a.promocion_id = p_promo),
                (SELECT count(*) FROM public.promo_ajustes pa WHERE pa.promocion_id = p_promo),
                (SELECT stock FROM public.productos WHERE id = p_cont))
    FROM public.promociones pr WHERE pr.id = p_promo;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_guc()
RETURNS text LANGUAGE sql AS $fn$
  SELECT COALESCE(current_setting('app.promo_contenedores_tomados', true), '');
$fn$;

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_adm    uuid;
  v_hoy    date := public._tablero_hoy();
  v_a      bigint;
  v_s      bigint;
  v_q      bigint;
  v_c      bigint;
  v_p      bigint;
  v_antes  text;
  v_txt    text;
  v_j      jsonb;
  v_datos  jsonb;
  v_fallas text[] := '{}';
  r        record;
BEGIN
 BEGIN
  SELECT s.id, adm.usuario_id
    INTO v_suc, v_adm
    FROM sucursales s
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'admin'
                   ORDER BY us.usuario_id LIMIT 1) adm ON true
   WHERE s.activa
     AND COALESCE(public.ultima_fecha_caja_cerrada(s.id), v_hoy - 1) < v_hoy
   ORDER BY s.id
   LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: ninguna sucursal activa con un admin y la caja de hoy abierta';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);

  v_a := pg_temp.t_producto(v_suc, 'ZZ ensayo 1501 A');
  v_s := pg_temp.t_producto(v_suc, 'ZZ ensayo 1501 S');
  v_q := pg_temp.t_producto(v_suc, 'ZZ ensayo 1501 Q');

  -- Cambiar el regalo a Q y el factor a 1: con la barra en 3, cierra 3 bloques de 1.
  v_datos := jsonb_build_object(
    'nombre', 'ZZ ensayo 1501 cambiada', 'tipo', 'bonificacion', 'fecha_inicio', v_hoy - 1, 'fecha_fin', NULL,
    'limite_usos', NULL, 'prioridad', 0, 'regalo_mueve_stock', false, 'modo_exclusion', 'acumulable',
    'unidades_por_bloque', 1, 'stock_por_bloque', 1, 'descripcion_regalo', NULL,
    'producto_ids', jsonb_build_array(v_a),
    'reglas', jsonb_build_array(jsonb_build_object('clave', 'cantidad_compra', 'valor', 10),
                                jsonb_build_object('clave', 'cantidad_bonificacion', 'valor', 2)));

  -- E1 · el guardado entra y el GUC queda vacío
  BEGIN
    v_c := pg_temp.t_producto(v_suc, 'ZZ ensayo 1501 C', 100);
    v_p := pg_temp.t_promo(v_suc, 'ZZ ensayo 1501 E1', v_a, v_s, v_c, 3);
    v_j := public.cambiar_regalo_promocion(v_p, v_q, v_c, true, v_datos);
    v_txt := pg_temp.t_estado(v_p, v_c);
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR v_txt NOT LIKE format('regalo=%s cont=%s factor=1/1 %%stock_cont=97', v_q, v_c)
       OR v_txt NOT LIKE format('%%acum=[%s:%s:0%%', v_s, v_c)
       OR pg_temp.t_guc() <> '' THEN
      v_fallas := v_fallas || format('E1 dio %s · %s · guc «%s»', v_j, v_txt, pg_temp.t_guc());
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ501';
  EXCEPTION
    WHEN SQLSTATE 'ZZ501' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E2 · el contenedor sin stock: nada cambia y el GUC queda vacío
  BEGIN
    v_c := pg_temp.t_producto(v_suc, 'ZZ ensayo 1501 C sin stock', 2);
    v_p := pg_temp.t_promo(v_suc, 'ZZ ensayo 1501 E2', v_a, v_s, v_c, 3);
    v_antes := pg_temp.t_estado(v_p, v_c);
    v_j := public.cambiar_regalo_promocion(v_p, v_q, v_c, true, v_datos);
    v_txt := pg_temp.t_estado(v_p, v_c);
    IF COALESCE((v_j->>'success')::boolean, true)
       OR v_j->>'codigo' IS DISTINCT FROM 'contenedor_sin_stock'
       OR v_txt IS DISTINCT FROM v_antes
       OR pg_temp.t_guc() <> '' THEN
      v_fallas := v_fallas || format('E2 dio %s · antes %s · después %s · guc «%s»', v_j, v_antes, v_txt, pg_temp.t_guc());
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ501';
  EXCEPTION
    WHEN SQLSTATE 'ZZ501' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E3 · la llamada de cuatro argumentos cambia el regalo y nada más
  BEGIN
    v_c := pg_temp.t_producto(v_suc, 'ZZ ensayo 1501 C3', 100);
    v_p := pg_temp.t_promo(v_suc, 'ZZ ensayo 1501 E3', v_a, v_s, v_c, 3);
    v_j := public.cambiar_regalo_promocion(v_p, v_q, v_c, true);
    v_txt := pg_temp.t_estado(v_p, v_c);
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR v_txt NOT LIKE format('regalo=%s cont=%s factor=6/1 %%stock_cont=100', v_q, v_c)
       OR pg_temp.t_guc() <> '' THEN
      v_fallas := v_fallas || format('E3 dio %s · %s · guc «%s»', v_j, v_txt, pg_temp.t_guc());
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ501';
  EXCEPTION
    WHEN SQLSTATE 'ZZ501' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E3 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E4 · el UPDATE del factor fuera de la RPC sigue renormalizando
  BEGIN
    v_c := pg_temp.t_producto(v_suc, 'ZZ ensayo 1501 C4', 100);
    v_p := pg_temp.t_promo(v_suc, 'ZZ ensayo 1501 E4', v_a, v_s, v_c, 3);
    UPDATE public.promociones SET unidades_por_bloque = 1, stock_por_bloque = 1 WHERE id = v_p;
    v_txt := pg_temp.t_estado(v_p, v_c);
    IF v_txt NOT LIKE format('regalo=%s cont=%s factor=1/1 usos=0 %%stock_cont=97', v_s, v_c) THEN
      v_fallas := v_fallas || format('E4 dio %s', v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ501';
  EXCEPTION
    WHEN SQLSTATE 'ZZ501' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E4 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- L1 · los cuerpos y los EXECUTE
  FOR r IN
    SELECT f.firma, f.md5, f.acl, md5(p.prosrc) AS h, p.proacl::text AS a
      FROM (VALUES
        ('public.promo_factor_bloquea_contenedores()', '859e10cd31a27610ef43c5b1b6f63eb7',
         '{postgres=X/postgres,service_role=X/postgres}'),
        ('public.cambiar_regalo_promocion(bigint,bigint,bigint,boolean,jsonb)', '582dae61b953871c538470ccd69ce394',
         '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public._rendicion_pagos(bigint,date,date,bigint)', '25f0aebcefe469fdc1a6e5205ea83efa',
         '{postgres=X/postgres,service_role=X/postgres}'),
        ('public._alta_bloquea_boletas_credito(bigint,bigint)', '68fd4baf367b2074f95bb7be2ec97792',
         '{postgres=X/postgres,service_role=X/postgres}')
      ) AS f(firma, md5, acl)
      JOIN pg_proc p ON p.oid = f.firma::regprocedure
  LOOP
    IF r.h <> r.md5 OR r.a IS DISTINCT FROM r.acl THEN
      v_fallas := v_fallas || format('L1 %s tiene md5 %s y acl %s', r.firma, r.h, r.a);
    END IF;
  END LOOP;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · E1 E2 E3 E4 L1';
 END;
END
$ensayo$;
