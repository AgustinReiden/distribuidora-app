-- Ensayo de la migración de los restos del núcleo: el NaN, las promos y 'anulado' (tarjeta 9 de #1524; #1515, #1520).
--
--   N1 · productos: precio, precio_sin_iva e impuestos_internos en 'NaN' dan 23514 (productos_precios_no_nan), y un
--        precio_sin_iva NULL entra.
--   N2 · crear_condicion_para_producto con precio 'NaN' da 23514 (grupo_precio_escalas_precio_unitario_no_nan) y no
--        deja la condición a medias; con un precio válido entra.
--   N3 · actualizar_politica_minimo_pedido con el mínimo, el envío gratis o el cargo en 'NaN', y
--        actualizar_monto_minimo_pedido con 'NaN', dan 23514 (politicas_comerciales_montos_no_nan).
--   N4 · guardar_meta_gerencial y guardar_meta_preventista con 'NaN' o 'Infinity' dan 23514.
--   N5 · actualizar_precios_masivo con un precio_final 'NaN' no cambia ese producto y lo informa en sus errores con el
--        nombre del CHECK. El otro producto del lote sí cambia.
--   E1 · Un pedido no pasa a 'anulado' (23514, pedidos_estado_check), y a 'cancelado' sí.
--   P1 · promociones: limite_usos 0, fecha_fin antes del inicio, unidades_por_bloque 0 y stock_por_bloque 0 dan 23514.
--        Una promo válida entra.
--   P2 · promocion_reglas: 2.5, 0, 'NaN', 'Infinity' y 3000000000 dan 23514, y 12 entra.
--   P3 · cambiar_regalo_promocion con p_datos de fecha_fin antes del inicio da 23514 y la promo no cambia.
--   D1 · ajustar_stock_promocion_completo ya no existe.
--   S1 · sustituir_regalo_pedido con una clave ya usada: un preventista recibe el rechazo del rol, no el replay.
--   S2 · El admin, con la misma línea, el mismo producto y la misma cantidad, recibe el replay con el id de la fila.
--   S3 · Con otra cantidad, otro producto u otra línea recibe 'sustitucion_ya_registrada'.
--   S4 · Desde otra sucursal no recibe el replay: sigue de largo y no encuentra la línea.
--   R1 a R4 · Lo mismo para dividir_regalo_pedido, con las partes y 'reparto_ya_registrado'. En R3 cuentan también
--        el orden de las partes y sus cantidades.
--   G1 · auditoria_nan() recorre más de 100 columnas y no encuentra filas; auditoria_locks() devuelve las sentencias
--        con lock, entre ellas las de sustituir_regalo_pedido. Las dos son sólo de la service_role.
--   L1 · Los cuerpos de sustituir y dividir tienen el md5 de la migración, siguen SECURITY DEFINER y con los mismos
--        EXECUTE.
--
-- Corre contra prod sin dejar rastro (salvo valores de secuencia): un único DO que termina siempre en una excepción, y
-- cada caso en un sub-bloque que se revierte. Antes de aplicar la migración se corre pegado detrás de su cuerpo, sin
-- el BEGIN y el COMMIT; después, solo. Solo y sin la migración tiene que dar 'ENSAYO FALLÓ' en todos los casos menos
-- S2 y R2, que es lo que no cambia.
--
-- Fixtures: un admin activo con dos sucursales activas, un cliente activo que no sea de vale blanco en la primera y
-- un preventista activo en ella. Los productos, los pedidos, las promos y las sustituciones nacen en el ensayo. Las
-- sustituciones se insertan a mano: el reintento contesta antes de tocar la línea.

CREATE OR REPLACE FUNCTION pg_temp.r9_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.r9_reset()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
END
$fn$;

-- Quién llama y desde qué sucursal.
CREATE OR REPLACE FUNCTION pg_temp.r9_como(p_uid uuid, p_suc bigint)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
END
$fn$;

-- Corre p_sql y lo revierte. Devuelve 'ok' o '<SQLSTATE> <constraint> <mensaje>'.
CREATE OR REPLACE FUNCTION pg_temp.r9_err(p_sql text)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
  v_c text;
BEGIN
  BEGIN
    EXECUTE p_sql;
    RAISE EXCEPTION 'ok' USING ERRCODE = 'ZZ520';
  EXCEPTION
    WHEN SQLSTATE 'ZZ520' THEN RETURN 'ok';
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_c = CONSTRAINT_NAME;
      RETURN SQLSTATE || ' ' || COALESCE(NULLIF(v_c, ''), '-') || ' ' || SQLERRM;
  END;
END
$fn$;

-- ¿p_sql cae en el CHECK p_check (23514)?
CREATE OR REPLACE FUNCTION pg_temp.r9_cae(p_sql text, p_check text)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT pg_temp.r9_err(p_sql) LIKE '23514 ' || p_check || ' %';
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.r9_producto(p_suc bigint, p_nombre text, p_precio numeric)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES (p_nombre, p_precio, 100, 60, p_suc)
  RETURNING id;
$fn$;

-- Un pedido con dos líneas (A×5 y C×3) a p_cli. Devuelve {pedido, item_a, item_c}.
CREATE OR REPLACE FUNCTION pg_temp.r9_pedido(p_cli bigint, p_adm uuid, p_a bigint, p_c bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
  v_ped bigint;
BEGIN
  v_res := public.crear_pedido_completo(
    p_cli, 800, p_adm,
    jsonb_build_array(jsonb_build_object('producto_id', p_a, 'cantidad', 5, 'precio_unitario', 100),
                      jsonb_build_object('producto_id', p_c, 'cantidad', 3, 'precio_unitario', 100)),
    'ensayo 1520');
  PERFORM pg_temp.r9_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  v_ped := (v_res->>'pedido_id')::bigint;
  RETURN jsonb_build_object('pedido', v_ped,
    'item_a', (SELECT id FROM public.pedido_items WHERE pedido_id = v_ped AND producto_id = p_a ORDER BY id LIMIT 1),
    'item_c', (SELECT id FROM public.pedido_items WHERE pedido_id = v_ped AND producto_id = p_c ORDER BY id LIMIT 1));
END
$fn$;

-- Una promo válida (10 → 2 de p_regalo), la crea postgres.
CREATE OR REPLACE FUNCTION pg_temp.r9_promo(p_suc bigint, p_regalo bigint)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id)
  VALUES ('ZZ ensayo 1520', 'bonificacion', public._tablero_hoy() - 1, p_suc, false, p_regalo)
  RETURNING id;
$fn$;

-- ── N · NaN ──────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pg_temp.r9_caso_n1(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f   text[] := '{}';
  v_a bigint := pg_temp.r9_producto((p->>'suc')::bigint, 'ZZ ensayo 1520 N1', 100);
  c   text;
BEGIN
  FOREACH c IN ARRAY ARRAY['precio', 'precio_sin_iva', 'impuestos_internos'] LOOP
    f := pg_temp.r9_si(f, pg_temp.r9_cae(format('UPDATE public.productos SET %I = ''NaN'' WHERE id = %s', c, v_a),
                                         'productos_precios_no_nan'),
                       format('%s = NaN: %s', c,
                              pg_temp.r9_err(format('UPDATE public.productos SET %I = ''NaN'' WHERE id = %s', c, v_a))));
  END LOOP;
  f := pg_temp.r9_si(f, pg_temp.r9_err(format('UPDATE public.productos SET precio_sin_iva = NULL WHERE id = %s', v_a)) = 'ok',
                     'precio_sin_iva NULL no entra');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.r9_caso_n2(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_suc bigint := (p->>'suc')::bigint;
  v_a   bigint := pg_temp.r9_producto(v_suc, 'ZZ ensayo 1520 N2', 100);
  v_sql text := format('SELECT public.crear_condicion_para_producto(%s, 10, ''NaN'')', v_a);
  v_res jsonb;
BEGIN
  PERFORM pg_temp.r9_como((p->>'admin')::uuid, v_suc);
  f := pg_temp.r9_si(f, pg_temp.r9_cae(v_sql, 'grupo_precio_escalas_precio_unitario_no_nan'),
                     format('la condición con precio NaN: %s', pg_temp.r9_err(v_sql)));
  f := pg_temp.r9_si(f, NOT EXISTS (SELECT 1 FROM public.grupo_precio_productos WHERE producto_id = v_a),
                     'la condición con precio NaN dejó el grupo creado');
  v_res := public.crear_condicion_para_producto(v_a, 10, 90);
  f := pg_temp.r9_si(f, v_res ? 'escala_id' AND (v_res->>'escala_id') IS NOT NULL,
                     format('la condición válida no entró: %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.r9_caso_n3(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_sql text;
BEGIN
  PERFORM pg_temp.r9_como((p->>'admin')::uuid, (p->>'suc')::bigint);
  FOREACH v_sql IN ARRAY ARRAY[
    'SELECT public.actualizar_politica_minimo_pedido(''bloquear'', ''NaN'', 0, 0)',
    'SELECT public.actualizar_politica_minimo_pedido(''bloquear'', 0, ''NaN'', 0)',
    'SELECT public.actualizar_politica_minimo_pedido(''cargo'', 0, 0, ''NaN'')',
    'SELECT public.actualizar_politica_minimo_pedido(''escalas'', 0, ''NaN'', 0)',
    'SELECT public.actualizar_monto_minimo_pedido(''NaN'')'] LOOP
    f := pg_temp.r9_si(f, pg_temp.r9_cae(v_sql, 'politicas_comerciales_montos_no_nan'),
                       format('%s: %s', v_sql, pg_temp.r9_err(v_sql)));
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.r9_caso_n4(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_suc bigint := (p->>'suc')::bigint;
  v_x   text;
  v_sql text;
BEGIN
  PERFORM pg_temp.r9_como((p->>'admin')::uuid, v_suc);
  FOREACH v_x IN ARRAY ARRAY['NaN', 'Infinity'] LOOP
    v_sql := format('SELECT public.guardar_meta_gerencial(%s, public._tablero_hoy(), ''venta'', %L)', v_suc, v_x);
    f := pg_temp.r9_si(f, pg_temp.r9_cae(v_sql, 'metas_gerenciales_valor_finito'),
                       format('meta gerencial %s: %s', v_x, pg_temp.r9_err(v_sql)));
    v_sql := format('SELECT public.guardar_meta_preventista(NULL, %s, %L::uuid, public._tablero_hoy(), ''facturacion'', %L)',
                    v_suc, p->>'prev', v_x);
    f := pg_temp.r9_si(f, pg_temp.r9_cae(v_sql, 'metas_preventista_valor_objetivo_finito'),
                       format('meta del preventista %s: %s', v_x, pg_temp.r9_err(v_sql)));
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.r9_caso_n5(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_suc bigint := (p->>'suc')::bigint;
  v_a   bigint := pg_temp.r9_producto(v_suc, 'ZZ ensayo 1520 N5 A', 100);
  v_b   bigint := pg_temp.r9_producto(v_suc, 'ZZ ensayo 1520 N5 B', 100);
  v_res jsonb;
BEGIN
  PERFORM pg_temp.r9_como((p->>'admin')::uuid, v_suc);
  v_res := public.actualizar_precios_masivo(jsonb_build_array(
    jsonb_build_object('producto_id', v_a, 'precio_final', 'NaN'),
    jsonb_build_object('producto_id', v_b, 'precio_final', 150)));
  f := pg_temp.r9_si(f, NOT COALESCE((v_res->>'success')::boolean, true)
                        AND (v_res->>'errores') LIKE '%productos_precios_no_nan%',
                     format('el masivo contestó %s', v_res));
  f := pg_temp.r9_si(f, (SELECT precio FROM public.productos WHERE id = v_a) = 100,
                     format('el producto con NaN quedó en %s', (SELECT precio FROM public.productos WHERE id = v_a)));
  f := pg_temp.r9_si(f, (SELECT precio FROM public.productos WHERE id = v_b) = 150,
                     'el otro producto del lote no se actualizó');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ── E · 'anulado' ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pg_temp.r9_caso_e1(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_suc bigint := (p->>'suc')::bigint;
  x     jsonb;
  v_sql text;
BEGIN
  PERFORM pg_temp.r9_como((p->>'admin')::uuid, v_suc);
  x := pg_temp.r9_pedido((p->>'cli')::bigint, (p->>'admin')::uuid,
                         pg_temp.r9_producto(v_suc, 'ZZ ensayo 1520 E1 A', 100),
                         pg_temp.r9_producto(v_suc, 'ZZ ensayo 1520 E1 C', 100));
  v_sql := format('UPDATE public.pedidos SET estado = ''anulado'', motivo_cancelacion = ''ensayo 1520'', '
                  || 'motivo_cancelacion_tipo = ''prueba'' WHERE id = %s', x->>'pedido');
  f := pg_temp.r9_si(f, pg_temp.r9_cae(v_sql, 'pedidos_estado_check'),
                     format('pasar a anulado: %s', pg_temp.r9_err(v_sql)));
  v_sql := replace(v_sql, '''anulado''', '''cancelado''');
  f := pg_temp.r9_si(f, pg_temp.r9_err(v_sql) = 'ok', format('pasar a cancelado: %s', pg_temp.r9_err(v_sql)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ── P · Promos ───────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pg_temp.r9_caso_p1(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_suc bigint := (p->>'suc')::bigint;
  v_r   bigint := pg_temp.r9_producto(v_suc, 'ZZ ensayo 1520 P1', 100);
  v_ins text := 'INSERT INTO public.promociones (nombre, tipo, fecha_inicio, fecha_fin, sucursal_id, regalo_mueve_stock, '
                || 'producto_regalo_id, limite_usos, unidades_por_bloque, stock_por_bloque) VALUES '
                || '(''ZZ ensayo 1520 P1'', ''bonificacion'', public._tablero_hoy(), %s, %s, false, %s, %s, %s, %s)';
  v_sql text;
  v_chk text;
BEGIN
  FOR v_sql, v_chk IN
    SELECT format(v_ins, e.fin, v_suc, v_r, e.lim, e.upb, e.spb), e.chk
      FROM (VALUES ('NULL', '0',    'NULL', 'NULL', 'promociones_limite_usos_positivo'),
                   ('NULL', '-3',   'NULL', 'NULL', 'promociones_limite_usos_positivo'),
                   ('public._tablero_hoy() - 1', 'NULL', 'NULL', 'NULL', 'promociones_fechas_en_orden'),
                   ('NULL', 'NULL', '0',    '1',    'promociones_factor_positivo'),
                   ('NULL', 'NULL', '6',    '0',    'promociones_factor_positivo')) AS e(fin, lim, upb, spb, chk)
  LOOP
    f := pg_temp.r9_si(f, pg_temp.r9_cae(v_sql, v_chk), format('%s: %s', v_chk, pg_temp.r9_err(v_sql)));
  END LOOP;
  v_sql := format(v_ins, 'public._tablero_hoy()', v_suc, v_r, '5', '6', '1');
  f := pg_temp.r9_si(f, pg_temp.r9_err(v_sql) = 'ok', format('la promo válida: %s', pg_temp.r9_err(v_sql)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.r9_caso_p2(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_suc bigint := (p->>'suc')::bigint;
  v_p   bigint := pg_temp.r9_promo(v_suc, pg_temp.r9_producto(v_suc, 'ZZ ensayo 1520 P2', 100));
  v_x   text;
  v_sql text;
BEGIN
  FOREACH v_x IN ARRAY ARRAY['2.5', '0', '-1', 'NaN', 'Infinity', '3000000000'] LOOP
    v_sql := format('INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id) '
                    || 'VALUES (%s, ''cantidad_compra'', %L, %s)', v_p, v_x, v_suc);
    f := pg_temp.r9_si(f, pg_temp.r9_cae(v_sql, 'promocion_reglas_valor_entero'),
                       format('regla %s: %s', v_x, pg_temp.r9_err(v_sql)));
  END LOOP;
  v_sql := format('INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id) '
                  || 'VALUES (%s, ''cantidad_compra'', 12, %s)', v_p, v_suc);
  f := pg_temp.r9_si(f, pg_temp.r9_err(v_sql) = 'ok', format('la regla 12: %s', pg_temp.r9_err(v_sql)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.r9_caso_p3(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_suc bigint := (p->>'suc')::bigint;
  v_r   bigint := pg_temp.r9_producto(v_suc, 'ZZ ensayo 1520 P3', 100);
  v_p   bigint := pg_temp.r9_promo(v_suc, v_r);
  v_sql text;
BEGIN
  PERFORM pg_temp.r9_como((p->>'admin')::uuid, v_suc);
  v_sql := format('SELECT public.cambiar_regalo_promocion(%s, %s, NULL, false, %L::jsonb)', v_p, v_r,
    jsonb_build_object('nombre', 'ZZ ensayo 1520 P3', 'tipo', 'bonificacion',
                       'fecha_inicio', public._tablero_hoy(), 'fecha_fin', public._tablero_hoy() - 5,
                       'limite_usos', NULL, 'prioridad', 0, 'regalo_mueve_stock', false,
                       'modo_exclusion', 'acumulable', 'unidades_por_bloque', NULL, 'stock_por_bloque', NULL,
                       'descripcion_regalo', NULL)::text);
  f := pg_temp.r9_si(f, pg_temp.r9_cae(v_sql, 'promociones_fechas_en_orden'),
                     format('guardar con el fin antes del inicio: %s', pg_temp.r9_err(v_sql)));
  f := pg_temp.r9_si(f, (SELECT fecha_fin IS NULL AND fecha_inicio = public._tablero_hoy() - 1
                           FROM public.promociones WHERE id = v_p),
                     'la promo cambió');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.r9_caso_d1(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
BEGIN
  RETURN jsonb_build_object('fallas', to_jsonb(pg_temp.r9_si('{}',
    to_regprocedure('public.ajustar_stock_promocion_completo(bigint,bigint,integer,integer,uuid,text)') IS NULL,
    'ajustar_stock_promocion_completo sigue existiendo')));
END
$fn$;

-- ── S · El reintento de sustituir ────────────────────────────────────────────

-- Un pedido con dos líneas y una sustitución de la línea A (A → B × 2) con la clave p_k.
-- Devuelve {pedido, item_a, item_c, b, c, sust}.
CREATE OR REPLACE FUNCTION pg_temp.r9_con_sustitucion(p jsonb, p_k uuid)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_suc  bigint := (p->>'suc')::bigint;
  v_adm  uuid := (p->>'admin')::uuid;
  v_a    bigint := pg_temp.r9_producto(v_suc, 'ZZ ensayo 1520 S A', 100);
  v_b    bigint := pg_temp.r9_producto(v_suc, 'ZZ ensayo 1520 S B', 100);
  v_c    bigint := pg_temp.r9_producto(v_suc, 'ZZ ensayo 1520 S C', 100);
  x      jsonb;
  v_sust bigint;
BEGIN
  PERFORM pg_temp.r9_como(v_adm, v_suc);
  x := pg_temp.r9_pedido((p->>'cli')::bigint, v_adm, v_a, v_c);
  INSERT INTO public.pedido_item_sustituciones (
    pedido_id, pedido_item_id, producto_original_id, producto_sustituto_id, cantidad_original, cantidad_sustituta,
    regalo_mueve_stock_snapshot, motivo, autorizado_por, sucursal_id, client_request_id, cadena_id)
  VALUES ((x->>'pedido')::bigint, (x->>'item_a')::bigint, v_a, v_b, 5, 2, true, 'ensayo 1520', v_adm, v_suc, p_k,
          gen_random_uuid())
  RETURNING id INTO v_sust;
  RETURN x || jsonb_build_object('b', v_b, 'c', v_c, 'sust', v_sust);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.r9_sustituir(p_item bigint, p_prod bigint, p_cant numeric, p_k uuid)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.sustituir_regalo_pedido(p_item, p_prod, p_cant, 'ensayo 1520', NULL, p_k);
  PERFORM pg_temp.r9_reset();
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.r9_caso_s1(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  k     uuid := gen_random_uuid();
  x     jsonb := pg_temp.r9_con_sustitucion(p, k);
  v_res jsonb;
BEGIN
  PERFORM pg_temp.r9_como((p->>'prev')::uuid, (p->>'suc')::bigint);
  v_res := pg_temp.r9_sustituir((x->>'item_a')::bigint, (x->>'b')::bigint, 2, k);
  f := pg_temp.r9_si(f, NOT COALESCE((v_res->>'success')::boolean, true)
                        AND v_res->>'error' = 'Solo admin o encargado pueden sustituir regalos',
                     format('el preventista recibió %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.r9_caso_s2(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  k     uuid := gen_random_uuid();
  x     jsonb := pg_temp.r9_con_sustitucion(p, k);
  v_res jsonb;
BEGIN
  v_res := pg_temp.r9_sustituir((x->>'item_a')::bigint, (x->>'b')::bigint, 2, k);
  f := pg_temp.r9_si(f, COALESCE((v_res->>'success')::boolean, false)
                        AND COALESCE((v_res->>'idempotent_replay')::boolean, false)
                        AND (v_res->>'sustitucion_id')::bigint = (x->>'sust')::bigint,
                     format('el reintento igual contestó %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.r9_caso_s3(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  k     uuid := gen_random_uuid();
  x     jsonb := pg_temp.r9_con_sustitucion(p, k);
  v_res jsonb;
  r     record;
BEGIN
  FOR r IN SELECT * FROM (VALUES ('otra cantidad', (x->>'item_a')::bigint, (x->>'b')::bigint, 3::numeric),
                                 ('otro producto', (x->>'item_a')::bigint, (x->>'c')::bigint, 2::numeric),
                                 ('otra línea',    (x->>'item_c')::bigint, (x->>'b')::bigint, 2::numeric))
                            AS t(caso, item, prod, cant) LOOP
    v_res := pg_temp.r9_sustituir(r.item, r.prod, r.cant, k);
    f := pg_temp.r9_si(f, NOT COALESCE((v_res->>'success')::boolean, true)
                          AND v_res->>'codigo' = 'sustitucion_ya_registrada',
                       format('%s contestó %s', r.caso, v_res));
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.r9_caso_s4(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  k     uuid := gen_random_uuid();
  x     jsonb := pg_temp.r9_con_sustitucion(p, k);
  v_res jsonb;
BEGIN
  PERFORM pg_temp.r9_como((p->>'admin')::uuid, (p->>'suc2')::bigint);
  v_res := pg_temp.r9_sustituir((x->>'item_a')::bigint, (x->>'b')::bigint, 2, k);
  f := pg_temp.r9_si(f, NOT COALESCE((v_res->>'success')::boolean, true) AND v_res->>'error' = 'Item no encontrado',
                     format('desde otra sucursal contestó %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ── R · El reintento de repartir ─────────────────────────────────────────────

-- Un pedido con dos líneas y un reparto de la línea A en B × 1 y C × 1, con la clave p_k en la primera fila.
-- Devuelve {pedido, item_a, item_c, b, c, sust, reparto}.
CREATE OR REPLACE FUNCTION pg_temp.r9_con_reparto(p jsonb, p_k uuid)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_suc  bigint := (p->>'suc')::bigint;
  v_adm  uuid := (p->>'admin')::uuid;
  v_a    bigint := pg_temp.r9_producto(v_suc, 'ZZ ensayo 1520 R A', 100);
  v_b    bigint := pg_temp.r9_producto(v_suc, 'ZZ ensayo 1520 R B', 100);
  v_c    bigint := pg_temp.r9_producto(v_suc, 'ZZ ensayo 1520 R C', 100);
  v_rep  uuid := gen_random_uuid();
  x      jsonb;
  v_sust bigint;
BEGIN
  PERFORM pg_temp.r9_como(v_adm, v_suc);
  x := pg_temp.r9_pedido((p->>'cli')::bigint, v_adm, v_a, v_c);
  INSERT INTO public.pedido_item_sustituciones (
    pedido_id, pedido_item_id, producto_original_id, producto_sustituto_id, cantidad_original, cantidad_sustituta,
    regalo_mueve_stock_snapshot, motivo, autorizado_por, sucursal_id, client_request_id, reparto_id, cadena_id)
  VALUES ((x->>'pedido')::bigint, (x->>'item_a')::bigint, v_a, v_b, 2, 1, true, 'ensayo 1520', v_adm, v_suc, p_k,
          v_rep, gen_random_uuid())
  RETURNING id INTO v_sust;
  INSERT INTO public.pedido_item_sustituciones (
    pedido_id, pedido_item_id, producto_original_id, producto_sustituto_id, cantidad_original, cantidad_sustituta,
    regalo_mueve_stock_snapshot, motivo, autorizado_por, sucursal_id, client_request_id, reparto_id, cadena_id)
  VALUES ((x->>'pedido')::bigint, (x->>'item_a')::bigint, v_a, v_c, 2, 1, true, 'ensayo 1520', v_adm, v_suc, NULL,
          v_rep, gen_random_uuid());
  RETURN x || jsonb_build_object('b', v_b, 'c', v_c, 'sust', v_sust, 'reparto', v_rep);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.r9_dividir(p_item bigint, p_partes jsonb, p_k uuid)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.dividir_regalo_pedido(p_item, p_partes, 'ensayo 1520', p_k);
  PERFORM pg_temp.r9_reset();
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.r9_partes(p_b bigint, p_nb int, p_c bigint, p_nc int)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_array(jsonb_build_object('producto_id', p_b, 'cantidad', p_nb),
                           jsonb_build_object('producto_id', p_c, 'cantidad', p_nc));
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.r9_caso_r1(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  k     uuid := gen_random_uuid();
  x     jsonb := pg_temp.r9_con_reparto(p, k);
  v_res jsonb;
BEGIN
  PERFORM pg_temp.r9_como((p->>'prev')::uuid, (p->>'suc')::bigint);
  v_res := pg_temp.r9_dividir((x->>'item_a')::bigint,
                              pg_temp.r9_partes((x->>'b')::bigint, 1, (x->>'c')::bigint, 1), k);
  f := pg_temp.r9_si(f, NOT COALESCE((v_res->>'success')::boolean, true)
                        AND v_res->>'error' = 'Solo admin o encargado pueden repartir regalos',
                     format('el preventista recibió %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.r9_caso_r2(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  k     uuid := gen_random_uuid();
  x     jsonb := pg_temp.r9_con_reparto(p, k);
  v_res jsonb;
BEGIN
  v_res := pg_temp.r9_dividir((x->>'item_a')::bigint,
                              pg_temp.r9_partes((x->>'b')::bigint, 1, (x->>'c')::bigint, 1), k);
  f := pg_temp.r9_si(f, COALESCE((v_res->>'success')::boolean, false)
                        AND COALESCE((v_res->>'idempotent_replay')::boolean, false)
                        AND (v_res->>'sustitucion_id')::bigint = (x->>'sust')::bigint
                        AND v_res->>'reparto_id' = x->>'reparto',
                     format('el reintento igual contestó %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.r9_caso_r3(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  k     uuid := gen_random_uuid();
  x     jsonb := pg_temp.r9_con_reparto(p, k);
  v_b   bigint := (x->>'b')::bigint;
  v_c   bigint := (x->>'c')::bigint;
  v_res jsonb;
  r     record;
BEGIN
  FOR r IN SELECT * FROM (VALUES ('otras cantidades', (x->>'item_a')::bigint, pg_temp.r9_partes(v_b, 2, v_c, 1)),
                                 ('otro orden',       (x->>'item_a')::bigint, pg_temp.r9_partes(v_c, 1, v_b, 1)),
                                 ('otra línea',       (x->>'item_c')::bigint, pg_temp.r9_partes(v_b, 1, v_c, 1)))
                            AS t(caso, item, partes) LOOP
    v_res := pg_temp.r9_dividir(r.item, r.partes, k);
    f := pg_temp.r9_si(f, NOT COALESCE((v_res->>'success')::boolean, true)
                          AND v_res->>'codigo' = 'reparto_ya_registrado',
                       format('%s contestó %s', r.caso, v_res));
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.r9_caso_r4(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  k     uuid := gen_random_uuid();
  x     jsonb := pg_temp.r9_con_reparto(p, k);
  v_res jsonb;
BEGIN
  PERFORM pg_temp.r9_como((p->>'admin')::uuid, (p->>'suc2')::bigint);
  v_res := pg_temp.r9_dividir((x->>'item_a')::bigint,
                              pg_temp.r9_partes((x->>'b')::bigint, 1, (x->>'c')::bigint, 1), k);
  f := pg_temp.r9_si(f, NOT COALESCE((v_res->>'success')::boolean, true) AND v_res->>'error' = 'Item no encontrado',
                     format('desde otra sucursal contestó %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ── G y L · Los gates y los cuerpos ─────────────────────────────────────────

CREATE OR REPLACE FUNCTION pg_temp.r9_caso_g1(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_nan jsonb;
  v_lck jsonb;
  fn    text;
BEGIN
  IF to_regprocedure('public.auditoria_nan()') IS NULL OR to_regprocedure('public.auditoria_locks()') IS NULL THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array('faltan auditoria_nan() o auditoria_locks()'));
  END IF;
  EXECUTE 'SELECT public.auditoria_nan()' INTO v_nan;
  EXECUTE 'SELECT public.auditoria_locks()' INTO v_lck;
  f := pg_temp.r9_si(f, (v_nan->>'columnas')::int > 100 AND jsonb_array_length(v_nan->'con_nan') = 0,
                     format('auditoria_nan() dio %s columnas y %s', v_nan->>'columnas', v_nan->'con_nan'));
  f := pg_temp.r9_si(f, EXISTS (SELECT 1 FROM jsonb_array_elements(v_lck->'sentencias') e
                                 WHERE e->>'firma' = 'sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)'
                                   AND e->>'sentencia' ~* 'FOR UPDATE'),
                     'auditoria_locks() no devolvió los locks de sustituir_regalo_pedido');
  FOREACH fn IN ARRAY ARRAY['public.auditoria_nan()', 'public.auditoria_locks()'] LOOP
    f := pg_temp.r9_si(f, NOT has_function_privilege('anon', fn, 'EXECUTE')
                          AND NOT has_function_privilege('authenticated', fn, 'EXECUTE')
                          AND has_function_privilege('service_role', fn, 'EXECUTE'),
                       format('%s tiene los EXECUTE %s', fn,
                              (SELECT proacl::text FROM pg_proc WHERE oid = fn::regprocedure)));
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.r9_caso_l1(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  r record;
BEGIN
  FOR r IN SELECT pr.oid::regprocedure::text AS firma, md5(pr.prosrc) AS h, pr.proacl::text AS a,
                  pr.prosecdef AS d, e.esperado
             FROM (VALUES ('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)',
                           'e8bb5ef19d2c922b389d3fc62c7b1d2e'),
                          ('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)',
                           'bf401dfb728c720e066d06c17cc1e0c2')) AS e(fn, esperado)
             JOIN pg_proc pr ON pr.oid = e.fn::regprocedure LOOP
    f := pg_temp.r9_si(f, r.h = r.esperado, format('%s tiene el md5 %s', r.firma, r.h));
    f := pg_temp.r9_si(f, r.d, format('%s dejó de ser SECURITY DEFINER', r.firma));
    f := pg_temp.r9_si(f, r.a = '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}',
                       format('%s tiene los EXECUTE %s', r.firma, r.a));
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

DO $ensayo1520$
DECLARE
  v_admin  uuid;
  v_suc    bigint;
  v_suc2   bigint;
  v_prev   uuid;
  v_cli    bigint;
  v_p      jsonb;
  v_caso   text;
  v_out    jsonb;
  v_fallas text[] := '{}';
BEGIN
  -- Un admin activo con dos sucursales activas, la primera con un cliente que no sea de vale blanco y un preventista.
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   WHERE EXISTS (SELECT 1 FROM clientes c
                  WHERE c.sucursal_id = us.sucursal_id AND c.activo AND c.tipo_factura_default IS DISTINCT FROM 'VB')
     AND EXISTS (SELECT 1 FROM usuario_sucursales up JOIN perfiles pp ON pp.id = up.usuario_id
                  WHERE up.sucursal_id = us.sucursal_id AND pp.rol = 'preventista' AND pp.activo)
     AND EXISTS (SELECT 1 FROM usuario_sucursales u2 JOIN sucursales s2 ON s2.id = u2.sucursal_id AND s2.activa
                  WHERE u2.usuario_id = us.usuario_id AND u2.sucursal_id <> us.sucursal_id)
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  SELECT u2.sucursal_id INTO v_suc2
    FROM usuario_sucursales u2 JOIN sucursales s2 ON s2.id = u2.sucursal_id AND s2.activa
   WHERE u2.usuario_id = v_admin AND u2.sucursal_id <> v_suc
   ORDER BY u2.sucursal_id LIMIT 1;
  SELECT up.usuario_id INTO v_prev
    FROM usuario_sucursales up JOIN perfiles pp ON pp.id = up.usuario_id AND pp.rol = 'preventista' AND pp.activo
   WHERE up.sucursal_id = v_suc
   ORDER BY up.usuario_id LIMIT 1;
  SELECT id INTO v_cli FROM clientes
   WHERE sucursal_id = v_suc AND activo AND tipo_factura_default IS DISTINCT FROM 'VB'
   ORDER BY id LIMIT 1;
  IF v_admin IS NULL OR v_suc2 IS NULL OR v_prev IS NULL OR v_cli IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · hace falta un admin activo con dos sucursales activas, y en la primera un cliente '
                    'activo y un preventista activo';
  END IF;
  v_p := jsonb_build_object('admin', v_admin, 'suc', v_suc, 'suc2', v_suc2, 'prev', v_prev, 'cli', v_cli);

  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  FOREACH v_caso IN ARRAY ARRAY['n1', 'n2', 'n3', 'n4', 'n5', 'e1', 'p1', 'p2', 'p3', 'd1',
                                's1', 's2', 's3', 's4', 'r1', 'r2', 'r3', 'r4', 'g1', 'l1'] LOOP
    v_out := NULL;
    BEGIN
      PERFORM pg_temp.r9_reset();
      PERFORM pg_temp.r9_como(v_admin, v_suc);
      EXECUTE format('SELECT pg_temp.r9_caso_%s($1)', v_caso) INTO v_out USING v_p;
      RAISE EXCEPTION USING ERRCODE = 'ZZ001';
    EXCEPTION
      WHEN SQLSTATE 'ZZ001' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('%s · error: %s', upper(v_caso), SQLERRM);
    END;
    IF v_out IS NOT NULL THEN
      v_fallas := v_fallas || ARRAY(SELECT upper(v_caso) || ' · ' || x
                                      FROM jsonb_array_elements_text(COALESCE(v_out->'fallas', '[]')) x);
    END IF;
  END LOOP;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (% fallas):\n- %', cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK';
END
$ensayo1520$;
