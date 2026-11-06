-- Ensayo de la migración que vuelve a guardar una promo en una sola transacción (#1491, tarjeta 14 de #1477).
--
-- Los 40P01 los mide el arnés (scripts/concurrencia, `t6`: T6k a T6n). Acá, en una sola sesión:
--
--   R1 · El guardado a medias, reproducido: el camino de dos pasos de la 467 (la RPC con cuatro argumentos y después
--        el UPDATE del resto, en otra transacción). Promo con regalo S, contenedor C con 2 de stock, factor 6/1, la
--        barra en 3 y ajuste automático. Cambiar el regalo a Q y el factor a 1: la RPC rota la barra (S queda con 3
--        en promo_acumuladores, contenedor C) y el UPDATE da 23514 al renormalizar (3 bloques de 1 contra 2 de
--        stock). El regalo queda en Q con el factor viejo. Pasa con y sin la migración: es lo que hace un bundle
--        viejo del PWA, que sigue llamando así hasta que se actualiza.
--   R2 · Lo mismo con el límite de usos: con 2 ya regalados, la RPC cambia el regalo y el UPDATE de limite_usos = 1
--        lo rechaza trg_limite_usos_no_baja. El regalo queda cambiado.
--   N1 · El mismo cambio que R1 en una sola llamada (p_datos): vuelve {success: false, codigo:
--        'contenedor_sin_stock'} con el nombre del contenedor y su stock en el mensaje, y la promo, su barra, sus
--        productos, sus reglas, sus ajustes y el contenedor quedan como estaban.
--   N2 · El mismo cambio que R2 en una sola llamada: {success: false} con el mensaje del límite, y nada cambia.
--   E1 · Un guardado entero que entra: regalo, contenedor, factor (cierra 3 bloques con stock de sobra), nombre,
--        fechas, límite, prioridad, modo, descripción, un producto que entra y otro que sale, una regla que cambia,
--        una que entra y una que sale. Queda igual que el UPDATE único de antes de la 467 sobre una promo gemela (la
--        misma barra, los mismos ajustes, el mismo descuento del contenedor), con los productos y las reglas
--        conciliados.
--   E2 · La llamada de cuatro argumentos (el bundle viejo) hace lo de la 467: cambia el regalo y nada más.
--   E3 · Un producto que no es de la sucursal en producto_ids: {success: false} y nada cambia.
--   E4 · Guardar sin cambios: {success: true, cambio: false} y la promo queda igual.
--   L1 · cambiar_regalo_promocion tiene una sola firma, la de cinco argumentos, con EXECUTE para authenticated y no
--        para anon; authenticated sigue sin UPDATE REST del regalo ni del contenedor, y con el de activo. PROMO-C de
--        auditoria_integridad() en verde: la RPC escribe regalo_mueve_stock y está en su lista de excepciones.
--
-- Corre contra prod sin dejar rastro (salvo valores de secuencia): un único DO que termina siempre en una excepción, y
-- cada caso en un sub-bloque que se revierte. Antes de aplicar la migración se corre pegado detrás de su cuerpo, sin
-- el BEGIN y el COMMIT; después, solo. Solo y sin la migración tiene que dar 'ENSAYO FALLÓ' por N1, N2, E1, E3, E4 y
-- L1 (la firma de cinco argumentos no existe), y R1 y R2 pasan: reproducen el guardado a medias.
--
-- Fixtures: una sucursal activa con un admin activo y la caja de hoy abierta. El resto nace en el ensayo.

CREATE OR REPLACE FUNCTION pg_temp.t_cliente(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (p_nombre, p_nombre, 'Ensayo 1491', p_suc)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_producto(p_suc bigint, p_nombre text, p_stock int DEFAULT 1000)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES (p_nombre, 1, p_stock, 1, p_suc)
  RETURNING id;
$fn$;

-- Una promo de bonificación (10 de A → 2 de regalo), con ajuste automático, el contenedor y la barra dados.
CREATE OR REPLACE FUNCTION pg_temp.t_promo(p_suc bigint, p_nombre text, p_a bigint, p_regalo bigint, p_cont bigint,
                                           p_usos int, p_mueve boolean DEFAULT false)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_id bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id,
                                  ajuste_automatico, ajuste_producto_id, unidades_por_bloque, stock_por_bloque,
                                  usos_pendientes)
  VALUES (p_nombre, 'bonificacion', public._tablero_hoy() - 1, p_suc, p_mueve, p_regalo,
          p_cont IS NOT NULL, p_cont, CASE WHEN p_cont IS NOT NULL THEN 6 END, CASE WHEN p_cont IS NOT NULL THEN 1 END,
          p_usos)
  RETURNING id INTO v_id;
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v_id, 'cantidad_compra', 10, p_suc), (v_id, 'cantidad_bonificacion', 2, p_suc);
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id) VALUES (v_id, p_a, p_suc);
  RETURN v_id;
END
$fn$;

-- Un id de producto, o su letra si está en p_ids (para comparar dos promos gemelas).
CREATE OR REPLACE FUNCTION pg_temp.t_l(p_id bigint, p_ids bigint[], p_letras text[])
RETURNS text LANGUAGE sql AS $fn$
  SELECT COALESCE(p_letras[array_position(p_ids, p_id)], p_id::text);
$fn$;

-- Todo lo que un guardado puede tocar de una promo, más el stock de un contenedor. Con p_ids, los productos van por
-- su letra.
CREATE OR REPLACE FUNCTION pg_temp.t_estado(p_promo bigint, p_cont bigint, p_ids bigint[] DEFAULT '{}',
                                            p_letras text[] DEFAULT '{}')
RETURNS text LANGUAGE sql AS $fn$
  SELECT format('nombre=%s regalo=%s cont=%s auto=%s factor=%s/%s limite=%s usos=%s fin=%s prio=%s modo=%s desc=%s activo=%s'
                || ' acum=[%s] prods=[%s] reglas=[%s] ajustes=%s stock_cont=%s',
                pr.nombre, pg_temp.t_l(pr.producto_regalo_id, p_ids, p_letras),
                pg_temp.t_l(pr.ajuste_producto_id, p_ids, p_letras), pr.ajuste_automatico, pr.unidades_por_bloque,
                pr.stock_por_bloque, pr.limite_usos, pr.usos_pendientes, pr.fecha_fin, pr.prioridad, pr.modo_exclusion,
                pr.descripcion_regalo, pr.activo,
                (SELECT string_agg(pg_temp.t_l(a.producto_regalo_id, p_ids, p_letras) || ':'
                                   || pg_temp.t_l(a.ajuste_producto_id, p_ids, p_letras) || ':' || a.usos_pendientes, ','
                                   ORDER BY a.producto_regalo_id)
                   FROM public.promo_acumuladores a WHERE a.promocion_id = p_promo),
                (SELECT string_agg(pg_temp.t_l(pp.producto_id, p_ids, p_letras), ',' ORDER BY pp.producto_id)
                   FROM public.promocion_productos pp WHERE pp.promocion_id = p_promo),
                (SELECT string_agg(r.clave || '=' || r.valor, ',' ORDER BY r.clave)
                   FROM public.promocion_reglas r WHERE r.promocion_id = p_promo),
                (SELECT count(*) FROM public.promo_ajustes pa WHERE pa.promocion_id = p_promo),
                (SELECT stock FROM public.productos WHERE id = p_cont))
    FROM public.promociones pr WHERE pr.id = p_promo;
$fn$;

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_adm    uuid;
  v_hoy    date := public._tablero_hoy();
  v_a      bigint;
  v_b      bigint;
  v_s      bigint;
  v_q      bigint;
  v_c      bigint;
  v_c2     bigint;
  v_c3     bigint;
  v_p      bigint;
  v_p2     bigint;
  v_ped    jsonb;
  v_antes  text;
  v_txt    text;
  v_err    text;
  v_j      jsonb;
  v_datos  jsonb;
  v_fallas text[] := '{}';
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
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  v_a := pg_temp.t_producto(v_suc, 'ZZ ensayo 1491 A');
  v_b := pg_temp.t_producto(v_suc, 'ZZ ensayo 1491 B');
  v_s := pg_temp.t_producto(v_suc, 'ZZ ensayo 1491 S');
  v_q := pg_temp.t_producto(v_suc, 'ZZ ensayo 1491 Q');
  v_c := pg_temp.t_producto(v_suc, 'ZZ ensayo 1491 C', 2);

  -- Lo que manda el modal al cambiar el regalo a Q y el factor a 1 (#1491: el escenario del issue).
  v_datos := jsonb_build_object(
    'nombre', 'ZZ ensayo 1491 cambiada', 'tipo', 'bonificacion', 'fecha_inicio', v_hoy - 1, 'fecha_fin', NULL,
    'limite_usos', NULL, 'prioridad', 0, 'regalo_mueve_stock', false, 'modo_exclusion', 'acumulable',
    'unidades_por_bloque', 1, 'stock_por_bloque', 1, 'descripcion_regalo', NULL,
    'producto_ids', jsonb_build_array(v_a),
    'reglas', jsonb_build_array(jsonb_build_object('clave', 'cantidad_compra', 'valor', 10),
                                jsonb_build_object('clave', 'cantidad_bonificacion', 'valor', 2)));

  -- R1 · el guardado a medias de dos pasos, con el contenedor sin stock
  BEGIN
    v_p := pg_temp.t_promo(v_suc, 'ZZ ensayo 1491 R1', v_a, v_s, v_c, 3);
    v_j := public.cambiar_regalo_promocion(v_p, v_q, v_c, true);
    v_err := 'el UPDATE pasó';
    BEGIN
      UPDATE public.promociones SET nombre = 'ZZ ensayo 1491 cambiada', unidades_por_bloque = 1, stock_por_bloque = 1
       WHERE id = v_p;
    EXCEPTION WHEN check_violation THEN
      v_err := SQLSTATE;
    END;
    IF NOT COALESCE((v_j->>'success')::boolean, false) OR v_err <> '23514'
       OR (SELECT producto_regalo_id::text || '/' || unidades_por_bloque || '/' || nombre FROM promociones WHERE id = v_p)
          IS DISTINCT FROM v_q::text || '/6/ZZ ensayo 1491 R1' THEN
      v_fallas := v_fallas || format('R1 no reprodujo el guardado a medias: rpc %s, update %s, estado %s', v_j, v_err,
                                     pg_temp.t_estado(v_p, v_c));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ491';
  EXCEPTION
    WHEN SQLSTATE 'ZZ491' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- R2 · el guardado a medias de dos pasos, con el límite por debajo de lo regalado
  BEGIN
    v_p := pg_temp.t_promo(v_suc, 'ZZ ensayo 1491 R2', v_a, v_s, NULL, 0, true);
    v_ped := public.crear_pedido_completo(
      pg_temp.t_cliente(v_suc, 'ZZ ensayo 1491'), 10, v_adm,
      jsonb_build_array(jsonb_build_object('producto_id', v_a, 'cantidad', 10, 'precio_unitario', 1),
                        jsonb_build_object('producto_id', v_s, 'cantidad', 2, 'precio_unitario', 0,
                                           'es_bonificacion', true, 'promocion_id', v_p)),
      'ensayo 1491', 'efectivo', 'pendiente', v_hoy, NULL);
    IF NOT COALESCE((v_ped->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'no se pudo crear el pedido con el regalo: %', v_ped;
    END IF;
    v_j := public.cambiar_regalo_promocion(v_p, v_q, NULL, false);
    v_err := 'el UPDATE pasó';
    BEGIN
      UPDATE public.promociones SET limite_usos = 1 WHERE id = v_p;
    EXCEPTION WHEN raise_exception THEN
      v_err := SQLERRM;
    END;
    IF NOT COALESCE((v_j->>'success')::boolean, false) OR v_err NOT LIKE '%no puede ser menor%'
       OR (SELECT producto_regalo_id::text || '/' || COALESCE(limite_usos::text, 'null') FROM promociones WHERE id = v_p)
          IS DISTINCT FROM v_q::text || '/null' THEN
      v_fallas := v_fallas || format('R2 no reprodujo el guardado a medias: rpc %s, update %s, estado %s', v_j, v_err,
                                     pg_temp.t_estado(v_p, NULL));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ491';
  EXCEPTION
    WHEN SQLSTATE 'ZZ491' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- N1 · el cambio de R1 en una sola llamada: no entra nada, y el error dice qué contenedor
  BEGIN
    v_p := pg_temp.t_promo(v_suc, 'ZZ ensayo 1491 N1', v_a, v_s, v_c, 3);
    v_antes := pg_temp.t_estado(v_p, v_c);
    v_j := public.cambiar_regalo_promocion(v_p, v_q, v_c, true, v_datos);
    v_txt := pg_temp.t_estado(v_p, v_c);
    IF COALESCE((v_j->>'success')::boolean, true)
       OR v_j->>'codigo' IS DISTINCT FROM 'contenedor_sin_stock'
       OR v_j->>'error' NOT LIKE '%«ZZ ensayo 1491 C»%hay 2%No se guardó ningún cambio%'
       OR v_txt IS DISTINCT FROM v_antes THEN
      v_fallas := v_fallas || format('N1 dio %s · antes %s · después %s', v_j, v_antes, v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ491';
  EXCEPTION
    WHEN SQLSTATE 'ZZ491' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('N1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- N2 · el cambio de R2 en una sola llamada
  BEGIN
    v_p := pg_temp.t_promo(v_suc, 'ZZ ensayo 1491 N2', v_a, v_s, NULL, 0, true);
    v_ped := public.crear_pedido_completo(
      pg_temp.t_cliente(v_suc, 'ZZ ensayo 1491'), 10, v_adm,
      jsonb_build_array(jsonb_build_object('producto_id', v_a, 'cantidad', 10, 'precio_unitario', 1),
                        jsonb_build_object('producto_id', v_s, 'cantidad', 2, 'precio_unitario', 0,
                                           'es_bonificacion', true, 'promocion_id', v_p)),
      'ensayo 1491', 'efectivo', 'pendiente', v_hoy, NULL);
    IF NOT COALESCE((v_ped->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'no se pudo crear el pedido con el regalo: %', v_ped;
    END IF;
    v_antes := pg_temp.t_estado(v_p, NULL);
    v_j := public.cambiar_regalo_promocion(v_p, v_q, NULL, false,
             v_datos || jsonb_build_object('limite_usos', 1, 'regalo_mueve_stock', true,
                                           'unidades_por_bloque', NULL, 'stock_por_bloque', NULL));
    v_txt := pg_temp.t_estado(v_p, NULL);
    IF COALESCE((v_j->>'success')::boolean, true)
       OR v_j->>'error' NOT LIKE '%no puede ser menor%No se guardó ningún cambio%'
       OR v_txt IS DISTINCT FROM v_antes THEN
      v_fallas := v_fallas || format('N2 dio %s · antes %s · después %s', v_j, v_antes, v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ491';
  EXCEPTION
    WHEN SQLSTATE 'ZZ491' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('N2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E1 · un guardado entero que entra, contra el UPDATE único de antes de la 467 sobre una gemela
  BEGIN
    v_c2 := pg_temp.t_producto(v_suc, 'ZZ ensayo 1491 C2');
    v_c3 := pg_temp.t_producto(v_suc, 'ZZ ensayo 1491 C3');
    v_p := pg_temp.t_promo(v_suc, 'ZZ ensayo 1491 E1', v_a, v_s, v_c2, 3);
    v_p2 := pg_temp.t_promo(v_suc, 'ZZ ensayo 1491 E1', v_a, v_s, v_c3, 3);
    INSERT INTO promocion_reglas (promocion_id, clave, valor, sucursal_id)
    VALUES (v_p, 'zz_ensayo', 1, v_suc), (v_p2, 'zz_ensayo', 1, v_suc);

    v_j := public.cambiar_regalo_promocion(v_p, v_q, v_c2, true, jsonb_build_object(
      'nombre', 'ZZ ensayo 1491 E1 nueva', 'tipo', 'bonificacion', 'fecha_inicio', v_hoy, 'fecha_fin', v_hoy + 30,
      'limite_usos', 50, 'prioridad', 3, 'regalo_mueve_stock', false, 'modo_exclusion', 'excluyente',
      'unidades_por_bloque', 1, 'stock_por_bloque', 1, 'descripcion_regalo', 'una Q',
      'producto_ids', jsonb_build_array(v_b::text),
      'reglas', jsonb_build_array(jsonb_build_object('clave', 'cantidad_compra', 'valor', 12),
                                  jsonb_build_object('clave', 'cantidad_bonificacion', 'valor', 2),
                                  jsonb_build_object('clave', 'zz_nueva', 'valor', 7))));

    UPDATE promociones
       SET nombre = 'ZZ ensayo 1491 E1 nueva', tipo = 'bonificacion', fecha_inicio = v_hoy, fecha_fin = v_hoy + 30,
           limite_usos = 50, prioridad = 3, regalo_mueve_stock = false, modo_exclusion = 'excluyente',
           unidades_por_bloque = 1, stock_por_bloque = 1, descripcion_regalo = 'una Q',
           producto_regalo_id = v_q, ajuste_producto_id = v_c3, ajuste_automatico = true
     WHERE id = v_p2;
    DELETE FROM promocion_productos WHERE promocion_id = v_p2;
    INSERT INTO promocion_productos (promocion_id, producto_id, sucursal_id) VALUES (v_p2, v_b, v_suc);
    DELETE FROM promocion_reglas WHERE promocion_id = v_p2 AND clave = 'zz_ensayo';
    UPDATE promocion_reglas SET valor = 12 WHERE promocion_id = v_p2 AND clave = 'cantidad_compra';
    INSERT INTO promocion_reglas (promocion_id, clave, valor, sucursal_id) VALUES (v_p2, 'zz_nueva', 7, v_suc);

    v_antes := pg_temp.t_estado(v_p2, v_c3, ARRAY[v_a, v_b, v_s, v_q, v_c3], ARRAY['A', 'B', 'S', 'Q', 'C']);
    v_txt := pg_temp.t_estado(v_p, v_c2, ARRAY[v_a, v_b, v_s, v_q, v_c2], ARRAY['A', 'B', 'S', 'Q', 'C']);
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR NOT COALESCE((v_j->>'cambio')::boolean, false)
       OR (v_j->'promocion'->>'nombre') IS DISTINCT FROM 'ZZ ensayo 1491 E1 nueva'
       OR v_txt IS DISTINCT FROM v_antes
       OR v_txt NOT LIKE '%regalo=Q cont=C %acum=[S:C:0%] prods=[B]%stock_cont=997' THEN
      v_fallas := v_fallas || format('E1 dio %s · rpc %s · directo %s', v_j, v_txt, v_antes);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ491';
  EXCEPTION
    WHEN SQLSTATE 'ZZ491' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E2 · la llamada de cuatro argumentos cambia el regalo y nada más
  BEGIN
    v_p := pg_temp.t_promo(v_suc, 'ZZ ensayo 1491 E2', v_a, v_s, NULL, 0);
    v_antes := pg_temp.t_estado(v_p, NULL);
    v_j := public.cambiar_regalo_promocion(v_p, v_q, NULL, false);
    v_txt := pg_temp.t_estado(v_p, NULL);
    IF NOT COALESCE((v_j->>'success')::boolean, false) OR NOT COALESCE((v_j->>'cambio')::boolean, false)
       OR v_txt IS DISTINCT FROM replace(v_antes, 'regalo=' || v_s, 'regalo=' || v_q) THEN
      v_fallas := v_fallas || format('E2 dio %s · antes %s · después %s', v_j, v_antes, v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ491';
  EXCEPTION
    WHEN SQLSTATE 'ZZ491' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E3 · un producto que no es de la sucursal
  BEGIN
    v_p := pg_temp.t_promo(v_suc, 'ZZ ensayo 1491 E3', v_a, v_s, NULL, 0);
    v_antes := pg_temp.t_estado(v_p, NULL);
    v_j := public.cambiar_regalo_promocion(v_p, v_q, NULL, false,
             v_datos || jsonb_build_object('producto_ids', jsonb_build_array(v_a, -1),
                                           'unidades_por_bloque', NULL, 'stock_por_bloque', NULL));
    v_txt := pg_temp.t_estado(v_p, NULL);
    IF COALESCE((v_j->>'success')::boolean, true) OR v_j->>'error' NOT LIKE 'Algún producto%'
       OR v_txt IS DISTINCT FROM v_antes THEN
      v_fallas := v_fallas || format('E3 dio %s · antes %s · después %s', v_j, v_antes, v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ491';
  EXCEPTION
    WHEN SQLSTATE 'ZZ491' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E3 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E4 · guardar sin cambios
  BEGIN
    v_p := pg_temp.t_promo(v_suc, 'ZZ ensayo 1491 E4', v_a, v_s, v_c, 3);
    v_antes := pg_temp.t_estado(v_p, v_c);
    v_j := public.cambiar_regalo_promocion(v_p, v_s, v_c, true,
             v_datos || jsonb_build_object('nombre', 'ZZ ensayo 1491 E4', 'unidades_por_bloque', 6));
    v_txt := pg_temp.t_estado(v_p, v_c);
    IF NOT COALESCE((v_j->>'success')::boolean, false) OR COALESCE((v_j->>'cambio')::boolean, true)
       OR v_txt IS DISTINCT FROM v_antes THEN
      v_fallas := v_fallas || format('E4 dio %s · antes %s · después %s', v_j, v_antes, v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ491';
  EXCEPTION
    WHEN SQLSTATE 'ZZ491' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E4 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- L1 · una sola firma y los permisos
  IF (SELECT count(*) FROM pg_proc WHERE proname = 'cambiar_regalo_promocion' AND pronamespace = 'public'::regnamespace) <> 1
     OR to_regprocedure('public.cambiar_regalo_promocion(bigint,bigint,bigint,boolean,jsonb)') IS NULL
     OR has_function_privilege('anon', 'public.cambiar_regalo_promocion(bigint,bigint,bigint,boolean,jsonb)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.cambiar_regalo_promocion(bigint,bigint,bigint,boolean,jsonb)', 'EXECUTE')
     OR has_column_privilege('authenticated', 'public.promociones', 'producto_regalo_id', 'UPDATE')
     OR has_column_privilege('authenticated', 'public.promociones', 'ajuste_producto_id', 'UPDATE')
     OR NOT has_column_privilege('authenticated', 'public.promociones', 'activo', 'UPDATE') THEN
    v_fallas := v_fallas || 'L1 la firma o los permisos de cambiar_regalo_promocion no son los esperados'::text;
  END IF;
  -- PROMO-C: la RPC escribe regalo_mueve_stock (la definición de la promo) y está en la lista de excepciones.
  IF public.auditoria_funciones_modo_regalo_vivo() <> 0 THEN
    v_fallas := v_fallas || 'L1 PROMO-C en rojo'::text;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · R1 R2 N1 N2 E1 E2 E3 E4 L1';
 END;
END
$ensayo$;
