-- Ensayo de la migración del modo de la foto como columna real (#1417).
--
--   A1 · Alta: el regalo de fracción lleva false, el de unidad entera true, la venta NULL;
--        siempre lo mismo que _regalo_modo_del_pedido.
--   A2 · La promo cambia de tipo: las líneas que ya existen no cambian.
--   A3 · Editar el pedido después del cambio: las líneas reinsertadas llevan el modo de la
--        foto, no el de hoy.
--   A4 · Dividir el regalo después del cambio: las partes, también.
--   A5 · Escrita a mano se vuelve a calcular, en un regalo y en una venta; sin promo, NULL.
--   A6 · La carrera del alta: si la promo cambia de tipo entre el BEFORE de la línea y la
--        foto, el INSERT se rechaza con 40001. Sin el cambio en el medio, pasa.
--   A7 · Como authenticated (la sesión de un admin en su sucursal): el select de
--        PEDIDO_ITEM_COLUMNAS pasa y trae el modo de la foto. Control: el costo y la fila
--        entera, que es lo que pedía la columna computada, dan 42501.
--   A8 · Permisos: la computada no existe, los triggers no tienen EXECUTE para la app, y la
--        columna la lee authenticated y no anon.
--
-- Contra prod sin la migración fallan todos. Corre SIN dejar rastro (salvo valores de
-- secuencia): cada caso en un subbloque revertido, y todo termina en un RAISE. El veredicto
-- es 'ENSAYO OK' o 'ENSAYO FALLO' en el mensaje. En seco, en una sola transacción con la
-- migración SIN su BEGIN y su COMMIT (con ellos queda aplicada):
--
--   sed '/^BEGIN;$/d; /^COMMIT;$/d' migrations/451_modo_regalo_columna_real.sql > /tmp/nnn.sql
--   psql "$DATABASE_URL" -1 -f /tmp/nnn.sql -f scripts/test-modo-foto-regalo-1417.sql
--
-- Fixtures: un admin activo con una sucursal activa y un cliente activo en ella. El resto
-- nace en el ensayo.

CREATE OR REPLACE FUNCTION pg_temp.mf_hoy()
RETURNS date LANGUAGE sql AS $fn$
  SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.mf_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.mf_reset()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
END
$fn$;

-- Un producto con bolsa y un lote (bolsa > 0 a propósito, nota de la 316).
CREATE OR REPLACE FUNCTION pg_temp.mf_prod(p_suc bigint, p_adm uuid, p_cat text)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod   bigint;
  v_compra bigint;
BEGIN
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id, categoria)
  VALUES ('ZZ ensayo 1417 ' || p_cat, 100, 150, 60, p_suc, 'ZZ ensayo 1417 ' || p_cat)
  RETURNING id INTO v_prod;
  INSERT INTO public.compras (sucursal_id, estado, usuario_id)
  VALUES (p_suc, 'recibida', p_adm) RETURNING id INTO v_compra;
  INSERT INTO public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad,
                                     cantidad_restante, usuario_id, compra_id)
  VALUES (v_prod, p_suc, pg_temp.mf_hoy() + 90, 50, 50, p_adm, v_compra);
  RETURN v_prod;
END
$fn$;

-- "Compra 10, lleva 2" sobre p_disparador. Fracción: bloque de 6, el contenedor es el regalo.
CREATE OR REPLACE FUNCTION pg_temp.mf_promo(p_suc bigint, p_regalo bigint, p_disparador bigint, p_mueve boolean)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock,
                                  producto_regalo_id, ajuste_automatico, unidades_por_bloque,
                                  stock_por_bloque, ajuste_producto_id)
  VALUES ('ZZ ensayo 1417', 'bonificacion', pg_temp.mf_hoy() - 1, p_suc, p_mueve, p_regalo, NOT p_mueve,
          CASE WHEN NOT p_mueve THEN 6 END, CASE WHEN NOT p_mueve THEN 1 END,
          CASE WHEN NOT p_mueve THEN p_regalo END)
  RETURNING id INTO v;
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v, 'cantidad_compra', 10, p_suc), (v, 'cantidad_bonificacion', 2, p_suc);
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id)
  VALUES (v, p_disparador, p_suc);
  RETURN v;
END
$fn$;

-- Cambia el tipo de regalo de la promo, como lo guarda ModalPromocion. Devuelve true para
-- poder llamarla desde un RETURNING (A6).
CREATE OR REPLACE FUNCTION pg_temp.mf_cambiar_tipo(p_promo bigint, p_mueve boolean, p_contenedor bigint)
RETURNS boolean LANGUAGE sql AS $fn$
  UPDATE public.promociones
     SET regalo_mueve_stock = p_mueve, ajuste_automatico = NOT p_mueve,
         unidades_por_bloque = CASE WHEN NOT p_mueve THEN 6 END,
         stock_por_bloque = CASE WHEN NOT p_mueve THEN 1 END,
         ajuste_producto_id = CASE WHEN NOT p_mueve THEN p_contenedor END
   WHERE id = p_promo
  RETURNING true;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.mf_v(p_prod bigint, p_cant int)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 100);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.mf_r(p_prod bigint, p_cant int, p_promo bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 0,
                            'es_bonificacion', true, 'promocion_id', p_promo);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.mf_alta(p_cli bigint, p_adm uuid, p_items jsonb)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.crear_pedido_completo(
    p_cli,
    (SELECT SUM((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric) FROM jsonb_array_elements(p_items) e),
    p_adm, p_items, 'ensayo 1417');
  PERFORM pg_temp.mf_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.mf_ok(p_res jsonb)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT COALESCE((p_res->>'success')::boolean, false);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.mf_linea(p_ped bigint, p_prod bigint, p_regalo boolean DEFAULT true)
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT id FROM public.pedido_items
   WHERE pedido_id = p_ped AND producto_id = p_prod AND COALESCE(es_bonificacion, false) = p_regalo
   ORDER BY id LIMIT 1;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.mf_col(p_item bigint)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT regalo_mueve_stock_foto FROM public.pedido_items WHERE id = p_item;
$fn$;

-- Cuántas líneas del pedido tienen la columna distinta del modo que usa el server.
CREATE OR REPLACE FUNCTION pg_temp.mf_desalineadas(p_ped bigint)
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT count(*) FROM public.pedido_items i
   WHERE i.pedido_id = p_ped
     AND i.regalo_mueve_stock_foto IS DISTINCT FROM
         CASE WHEN COALESCE(i.es_bonificacion, false) AND i.promocion_id IS NOT NULL
              THEN public._regalo_modo_del_pedido(i.pedido_id, i.promocion_id, i.sucursal_id) END;
$fn$;

-- Las de los regalos de una promo en el pedido, todas con este modo (y al menos una).
CREATE OR REPLACE FUNCTION pg_temp.mf_regalos_con(p_ped bigint, p_promo bigint, p_modo boolean)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT count(*) > 0 AND bool_and(regalo_mueve_stock_foto IS NOT DISTINCT FROM p_modo)
    FROM public.pedido_items
   WHERE pedido_id = p_ped AND promocion_id = p_promo AND COALESCE(es_bonificacion, false);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.mf_version(p_ped bigint)
RETURNS timestamptz LANGUAGE sql AS $fn$
  SELECT updated_at FROM public.pedidos WHERE id = p_ped;
$fn$;

-- Un pedido con un regalo de fracción y otro con uno de unidad entera.
CREATE OR REPLACE FUNCTION pg_temp.mf_base(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v bigint; w bigint; r bigint; z bigint; v_frac bigint; v_entera bigint;
BEGIN
  v := pg_temp.mf_prod(p_suc, p_adm, 'v');
  w := pg_temp.mf_prod(p_suc, p_adm, 'w');
  r := pg_temp.mf_prod(p_suc, p_adm, 'r');
  z := pg_temp.mf_prod(p_suc, p_adm, 'z');
  v_frac   := pg_temp.mf_promo(p_suc, r, v, false);
  v_entera := pg_temp.mf_promo(p_suc, z, w, true);
  RETURN jsonb_build_object(
    'v', v, 'w', w, 'r', r, 'z', z, 'frac', v_frac, 'entera', v_entera,
    'p1', pg_temp.mf_alta(p_cli, p_adm, jsonb_build_array(pg_temp.mf_v(v, 10), pg_temp.mf_r(r, 2, v_frac))),
    'p2', pg_temp.mf_alta(p_cli, p_adm, jsonb_build_array(pg_temp.mf_v(w, 10), pg_temp.mf_r(z, 2, v_entera))));
END
$fn$;

-- ---------------------------------------------------------------------------
-- A1 y A2 · alta y cambio de tipo
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.mf_caso_a1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; b jsonb;
BEGIN
  b := pg_temp.mf_base(p_cli, p_adm, p_suc);
  f := pg_temp.mf_si(f, pg_temp.mf_col(pg_temp.mf_linea((b->>'p1')::bigint, (b->>'r')::bigint)) IS FALSE,
                     'fracción: la línea no dice false');
  f := pg_temp.mf_si(f, pg_temp.mf_col(pg_temp.mf_linea((b->>'p2')::bigint, (b->>'z')::bigint)) IS TRUE,
                     'unidad entera: la línea no dice true');
  f := pg_temp.mf_si(f, pg_temp.mf_col(pg_temp.mf_linea((b->>'p1')::bigint, (b->>'v')::bigint, false)) IS NULL,
                     'una línea de venta tiene modo');
  f := pg_temp.mf_si(f, pg_temp.mf_desalineadas((b->>'p1')::bigint) = 0
                        AND pg_temp.mf_desalineadas((b->>'p2')::bigint) = 0,
                     'en el alta la columna no es _regalo_modo_del_pedido');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.mf_caso_a2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; b jsonb;
BEGIN
  b := pg_temp.mf_base(p_cli, p_adm, p_suc);
  PERFORM pg_temp.mf_cambiar_tipo((b->>'frac')::bigint, true, (b->>'r')::bigint);
  PERFORM pg_temp.mf_cambiar_tipo((b->>'entera')::bigint, false, (b->>'z')::bigint);
  f := pg_temp.mf_si(f, pg_temp.mf_regalos_con((b->>'p1')::bigint, (b->>'frac')::bigint, false),
                     'fracción que pasó a unidad entera: la línea cambió de modo');
  f := pg_temp.mf_si(f, pg_temp.mf_regalos_con((b->>'p2')::bigint, (b->>'entera')::bigint, true),
                     'unidad entera que pasó a fracción: la línea cambió de modo');
  f := pg_temp.mf_si(f, pg_temp.mf_desalineadas((b->>'p1')::bigint) = 0
                        AND pg_temp.mf_desalineadas((b->>'p2')::bigint) = 0,
                     'tras el cambio de tipo la columna no es _regalo_modo_del_pedido');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- A3 y A4 · editar y dividir después del cambio de tipo
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.mf_caso_a3(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; b jsonb; v_res jsonb; v_ped bigint;
BEGIN
  b := pg_temp.mf_base(p_cli, p_adm, p_suc);
  v_ped := (b->>'p1')::bigint;
  PERFORM pg_temp.mf_cambiar_tipo((b->>'frac')::bigint, true, (b->>'r')::bigint);
  -- La misma regla y el mismo regalo: la edición pasa (#1324) y borra y reinserta todo.
  -- LV-1 de #1565 (decisión del dueño del 13/11): a este regalo ya no se le suma, así que
  -- la edición toca la venta y deja el regalo; subirlo se rechaza y no cambia nada.
  v_res := public.actualizar_pedido_items(
    v_ped,
    jsonb_build_array(pg_temp.mf_v((b->>'v')::bigint, 12), pg_temp.mf_r((b->>'r')::bigint, 2, (b->>'frac')::bigint)),
    p_adm, NULL, pg_temp.mf_version(v_ped));
  PERFORM pg_temp.mf_reset();
  f := pg_temp.mf_si(f, pg_temp.mf_ok(v_res), format('editar: %s', v_res));
  f := pg_temp.mf_si(f, pg_temp.mf_regalos_con(v_ped, (b->>'frac')::bigint, false),
                     'editar: el regalo reinsertado tomó el modo de hoy, no el de la foto');
  f := pg_temp.mf_si(f, pg_temp.mf_desalineadas(v_ped) = 0, 'editar: la columna no es _regalo_modo_del_pedido');
  v_res := public.actualizar_pedido_items(
    v_ped,
    jsonb_build_array(pg_temp.mf_v((b->>'v')::bigint, 20), pg_temp.mf_r((b->>'r')::bigint, 4, (b->>'frac')::bigint)),
    p_adm, NULL, pg_temp.mf_version(v_ped));
  PERFORM pg_temp.mf_reset();
  f := pg_temp.mf_si(f, NOT pg_temp.mf_ok(v_res) AND v_res->>'codigo' = 'regalo_de_tramo_anterior'
                        AND (SELECT cantidad FROM public.pedido_items
                              WHERE id = pg_temp.mf_linea(v_ped, (b->>'r')::bigint)) = 2,
                     format('subirle el regalo dio %s, esperado el rechazo sin cambios', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.mf_caso_a4(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; b jsonb; v_res jsonb; v_ped bigint; z2 bigint;
BEGIN
  b := pg_temp.mf_base(p_cli, p_adm, p_suc);
  v_ped := (b->>'p2')::bigint;
  z2 := pg_temp.mf_prod(p_suc, p_adm, 'z');
  PERFORM pg_temp.mf_cambiar_tipo((b->>'entera')::bigint, false, (b->>'z')::bigint);
  v_res := public.dividir_regalo_pedido(pg_temp.mf_linea(v_ped, (b->>'z')::bigint),
    jsonb_build_array(jsonb_build_object('producto_id', (b->>'z')::bigint, 'cantidad', 1),
                      jsonb_build_object('producto_id', z2, 'cantidad', 1)), 'ensayo 1417');
  PERFORM pg_temp.mf_reset();
  f := pg_temp.mf_si(f, pg_temp.mf_ok(v_res), format('dividir: %s', v_res));
  f := pg_temp.mf_si(f, (SELECT count(*) FROM public.pedido_items
                          WHERE pedido_id = v_ped AND COALESCE(es_bonificacion, false)) = 2,
                     'dividir: no quedaron dos partes');
  f := pg_temp.mf_si(f, pg_temp.mf_regalos_con(v_ped, (b->>'entera')::bigint, true),
                     'dividir: una parte tomó el modo de hoy, no el de la foto');
  f := pg_temp.mf_si(f, pg_temp.mf_desalineadas(v_ped) = 0, 'dividir: la columna no es _regalo_modo_del_pedido');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- A5 · escrita a mano
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.mf_caso_a5(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; b jsonb; v_regalo bigint; v_venta bigint;
BEGIN
  b := pg_temp.mf_base(p_cli, p_adm, p_suc);
  v_regalo := pg_temp.mf_linea((b->>'p1')::bigint, (b->>'r')::bigint);
  v_venta  := pg_temp.mf_linea((b->>'p1')::bigint, (b->>'v')::bigint, false);
  UPDATE public.pedido_items SET regalo_mueve_stock_foto = true WHERE id IN (v_regalo, v_venta);
  f := pg_temp.mf_si(f, pg_temp.mf_col(v_regalo) IS FALSE, 'un regalo escrito a mano quedó con el modo escrito');
  f := pg_temp.mf_si(f, pg_temp.mf_col(v_venta) IS NULL, 'una venta escrita a mano quedó con modo');
  -- Sin promo (lo que hace el SET NULL de la FK al borrar la promo) no tiene modo.
  UPDATE public.pedido_items SET promocion_id = NULL WHERE id = v_regalo;
  f := pg_temp.mf_si(f, pg_temp.mf_col(v_regalo) IS NULL, 'un regalo sin promo quedó con modo');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- A6 · la carrera del alta
-- ---------------------------------------------------------------------------
-- El RETURNING corre con la fila ya insertada (después de su BEFORE) y antes de los AFTER
-- de la sentencia: cambiar ahí el tipo de la promo es lo que haría otra transacción entre el
-- sello de la línea y la foto que toma capturar_promo_del_pedido.
CREATE OR REPLACE FUNCTION pg_temp.mf_caso_a6(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint; r bigint; v_promo bigint; v_ped bigint; v_ok boolean;
  v_rechazo text;
BEGIN
  v := pg_temp.mf_prod(p_suc, p_adm, 'v');
  r := pg_temp.mf_prod(p_suc, p_adm, 'r');
  v_promo := pg_temp.mf_promo(p_suc, r, v, false);
  -- Un pedido sin regalo: la promo no tiene foto en él.
  v_ped := pg_temp.mf_alta(p_cli, p_adm, jsonb_build_array(pg_temp.mf_v(v, 10)));

  BEGIN
    INSERT INTO public.pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal,
                                     es_bonificacion, promocion_id, sucursal_id)
    VALUES (v_ped, r, 2, 0, 0, true, v_promo, p_suc)
    RETURNING pg_temp.mf_cambiar_tipo(v_promo, true, r) INTO v_ok;
    f := f || 'la promo cambió de tipo entre el sello y la foto y el INSERT pasó';
  EXCEPTION WHEN SQLSTATE '40001' THEN
    v_rechazo := SQLERRM;
  END;
  f := pg_temp.mf_si(f, v_rechazo LIKE 'La promoción % cambió de tipo mientras se guardaba el pedido %',
                     format('el rechazo no es el esperado: %s', v_rechazo));

  -- Control: sin el cambio en el medio pasa, con el modo de la promo, y la foto nace igual.
  PERFORM pg_temp.mf_cambiar_tipo(v_promo, false, r);
  INSERT INTO public.pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal,
                                   es_bonificacion, promocion_id, sucursal_id)
  VALUES (v_ped, r, 2, 0, 0, true, v_promo, p_suc);
  f := pg_temp.mf_si(f, pg_temp.mf_regalos_con(v_ped, v_promo, false), 'control: la línea no dice false');
  f := pg_temp.mf_si(f, (SELECT regalo_mueve_stock FROM public.pedido_promo_reglas
                          WHERE pedido_id = v_ped AND promocion_id = v_promo) IS FALSE,
                     'control: la foto no nació con el modo de la línea');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- A7 · como authenticated
-- ---------------------------------------------------------------------------
-- PEDIDO_ITEM_COLUMNAS de src/lib/pedidoItemColumnas.ts, tal cual.
CREATE OR REPLACE FUNCTION pg_temp.mf_columnas_front()
RETURNS text LANGUAGE sql AS $fn$
  SELECT 'id, pedido_id, producto_id, cantidad, precio_unitario, subtotal, es_bonificacion, promocion_id, neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva, sucursal_id, tp_import_id, descripcion_regalo, stock_al_crear, ingreso_real_unitario, precio_lista_al_crear, origen_precio, descuento_pct, grupo_precio_escala_id, unidades_por_bloque_al_crear, origen_unidades_por_bloque, regalo_cadena_id, combo_id, precio_sin_combo_unitario, combo_roto_id, regalo_mueve_stock_foto'::text;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.mf_caso_a7(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; b jsonb; v_regalo bigint; v_leido jsonb; v_sql text;
BEGIN
  b := pg_temp.mf_base(p_cli, p_adm, p_suc);
  v_regalo := pg_temp.mf_linea((b->>'p2')::bigint, (b->>'z')::bigint);
  PERFORM pg_temp.mf_cambiar_tipo((b->>'entera')::bigint, false, (b->>'z')::bigint);

  -- Lo que pide el front, con el embed de la lista (items dentro del pedido).
  v_sql := format(
    'SELECT jsonb_agg(i) FROM (SELECT %s FROM public.pedido_items WHERE pedido_id = $1) i',
    pg_temp.mf_columnas_front());
  BEGIN
    PERFORM set_config('role', 'authenticated', true);
    EXECUTE v_sql INTO v_leido USING (b->>'p2')::bigint;
    RAISE EXCEPTION USING ERRCODE = 'ZZ002';
  EXCEPTION
    WHEN SQLSTATE 'ZZ002' THEN NULL;
    WHEN OTHERS THEN f := f || format('authenticated no pudo leer PEDIDO_ITEM_COLUMNAS: %s %s', SQLSTATE, SQLERRM);
  END;
  f := pg_temp.mf_si(f, current_user <> 'authenticated', 'el rol no volvió después del bloque');
  f := pg_temp.mf_si(f, jsonb_array_length(COALESCE(v_leido, '[]')) = 2,
                     format('authenticated no ve las dos líneas del pedido (RLS o sucursal): %s', v_leido));
  f := pg_temp.mf_si(f, (SELECT (e->>'regalo_mueve_stock_foto')::boolean FROM jsonb_array_elements(v_leido) e
                          WHERE (e->>'id')::bigint = v_regalo) IS TRUE,
                     'authenticated no lee el modo de la foto (true) tras pasar la promo a fracción');

  -- Control: el rol muerde. El costo no se lee, y la fila entera (lo que pasaba la columna
  -- computada de la 442) tampoco.
  FOREACH v_sql IN ARRAY ARRAY[
    'SELECT costo_unitario_al_crear FROM public.pedido_items LIMIT 0',
    'SELECT to_jsonb(i) FROM public.pedido_items i LIMIT 0'] LOOP
    BEGIN
      PERFORM set_config('role', 'authenticated', true);
      EXECUTE v_sql;
      f := f || format('control: authenticated pudo correr «%s»', v_sql);
      RAISE EXCEPTION USING ERRCODE = 'ZZ002';
    EXCEPTION
      WHEN insufficient_privilege OR SQLSTATE 'ZZ002' THEN NULL;
    END;
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- A8 · permisos
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.mf_caso_a8(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_fn text;
BEGIN
  f := pg_temp.mf_si(f, to_regprocedure('public.regalo_mueve_stock_foto(public.pedido_items)') IS NULL,
                     'la columna computada sigue existiendo');
  FOREACH v_fn IN ARRAY ARRAY['public.sellar_modo_regalo_item()', 'public.verificar_modo_regalo_item()'] LOOP
    f := pg_temp.mf_si(f, NOT has_function_privilege('authenticated', v_fn, 'EXECUTE')
                          AND NOT has_function_privilege('anon', v_fn, 'EXECUTE'),
                       format('%s tiene EXECUTE para la app', v_fn));
  END LOOP;
  f := pg_temp.mf_si(f, has_column_privilege('authenticated', 'public.pedido_items', 'regalo_mueve_stock_foto', 'SELECT')
                        AND NOT has_column_privilege('anon', 'public.pedido_items', 'regalo_mueve_stock_foto', 'SELECT')
                        AND NOT has_table_privilege('authenticated', 'public.pedido_items', 'SELECT'),
                     'la columna no quedó por columna para authenticated, o anon la lee');
  -- Ninguna función de un argumento del tipo fila de pedido_items (lo que mira el gate nuevo).
  f := pg_temp.mf_si(f, NOT EXISTS (SELECT 1 FROM pg_proc p
                                     WHERE p.pronamespace = 'public'::regnamespace AND p.pronargs = 1
                                       AND p.proargtypes[0] = 'public.pedido_items'::regtype),
                     'queda una función de un argumento pedido_items');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

DO $ensayo1417$
DECLARE
  v_admin   uuid;
  v_suc     bigint;
  v_cliente bigint;
  v_caso    text;
  v_out     jsonb;
  v_fallas  text[] := '{}';
BEGIN
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  SELECT id INTO v_cliente FROM clientes
   WHERE sucursal_id = v_suc AND activo AND tipo_factura_default IS DISTINCT FROM 'VB'
   ORDER BY id LIMIT 1;
  IF v_admin IS NULL OR v_cliente IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLO · hace falta un admin activo con una sucursal activa y un cliente activo en ella';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  FOREACH v_caso IN ARRAY ARRAY['a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7', 'a8'] LOOP
    v_out := NULL;
    BEGIN
      PERFORM pg_temp.mf_reset();
      EXECUTE format('SELECT pg_temp.mf_caso_%s($1, $2, $3)', v_caso)
        INTO v_out USING v_cliente, v_admin, v_suc;
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
    RAISE EXCEPTION E'ENSAYO FALLO (% fallas):\n- %', cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK';
END
$ensayo1417$;
