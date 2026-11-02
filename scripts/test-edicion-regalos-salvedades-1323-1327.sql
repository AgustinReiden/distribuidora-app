-- Ensayo de #1323, #1324, #1325, #1326 y #1327 (tarjeta 6 del plan #1308).
--
--   P2  · venta y regalo del mismo producto con stock justo, con bolsa > 0: 8+5
--         contra 12 se rechaza, 8+4 pasa y el stock queda en 0, no negativo.
--   P6  · la concurrencia optimista: el updated_at viejo se rechaza con su codigo y
--         no toca nada; el vigente pasa; sin parametro (un bundle viejo) pasa.
--   P5  · la comanda de un canje no se edita.
--   M1  · promo de unidad entera que pasa a fraccion con pedidos abiertos: la
--         salvedad, la cancelacion, la edicion, sustituir y dividir leen la foto, y
--         ninguno toca la barra viva ni devuelve un fardo fantasma.
--   M2  · al reves, fraccion que pasa a unidad entera: nada mueve stock.
--   M3  · un pedido nuevo sale con el modo nuevo.
--   M4  · el contador de unidad entera no se hereda como barra: pasar a fraccion no
--         cierra bloques ni merma. Una linea de otro modo conserva su factor al
--         editarla y sustituirla. Con la regla cambiada, la edicion no recalcula el
--         regalo. Una foto sin regalo vivo no manda sobre el regalo que vuelve.
--   R1  · A x4 cambiado por valor a P x19: la salvedad de 1 deja P x10 y la
--         simulacion lo dice antes; la segunda borra el regalo; la edicion lo
--         conserva. Sin cadena y con reparto, la cuenta sigue cerrando.
--   R2  · una linea movida entre dos eslabones vale su corte: A x4 -> B x2 -> C x2
--         vale 2, y la salvedad la baja.
--   R3  · la misma categoria convierte como las demas: A4->B6, promo en 8, B x12.
--   L1  · sustituir, dividir, cancelar, editar y la salvedad bloquean productos y
--         contenedores juntos y por id antes de moverlos (#1326, #1375).
--   C1  · el guard de caja: a dia cerrado no se registra ni se anula, tambien a las
--         23 de Argentina, y el reintento de lo que ya entro sigue contestando.
--   C2  · cancelar un vale blanco entregado a las 23 de Argentina mira su dia: con
--         esa caja cerrada no se cancela, y con la del dia anterior si (#1277).
--   V1  · #1372: la ventana del preventista, la pura, a los dos lados de las 15:30.
--   V2  · #1372: el preventista dueño antes del corte devuelve a pendiente su pedido
--         en camino y no queda la parada viva; pasado el corte, y siendo ajeno, se
--         rechaza y no cambia nada. El chofer tampoco puede. El admin, siempre.
--   G1  · permisos y firma, y que SEG-A no se queje de las nuevas.
--
-- Contra prod sin la migracion fallan todos salvo la parte "sin cadena" de R1.
-- Corre SIN dejar rastro: cada caso en un subbloque revertido, y todo termina en
-- un RAISE. El veredicto es 'ENSAYO OK' o 'ENSAYO FALLO' en el mensaje. En seco,
-- las dos en una sola transaccion:
--
--   psql "$DATABASE_URL" -1 -f migrations/431a_edicion_regalos_lo_comun.sql \
--                           -f migrations/431b_salvedades_y_cancelacion.sql \
--                           -f migrations/431c_editar_items_del_pedido.sql \
--                           -f migrations/431d_sustituir_y_dividir_regalo.sql \
--                           -f scripts/test-edicion-regalos-salvedades-1323-1327.sql

CREATE OR REPLACE FUNCTION pg_temp.er_hoy()
RETURNS date LANGUAGE sql AS $fn$
  SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.er_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.er_reset()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.er_stock(p_prod bigint)
RETURNS int LANGUAGE sql AS $fn$
  SELECT stock FROM public.productos WHERE id = p_prod;
$fn$;

-- Un producto con p_bolsa sin lote y un lote con p_lote vivas. Bolsa > 0 a
-- proposito (nota de la 316).
CREATE OR REPLACE FUNCTION pg_temp.er_prod(p_suc bigint, p_adm uuid, p_cat text, p_bolsa int, p_lote int)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod   bigint;
  v_compra bigint;
BEGIN
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id, categoria)
  VALUES ('ZZ ensayo 1323 ' || p_cat, 100, p_bolsa + p_lote, 60, p_suc, 'ZZ ensayo 1323 ' || p_cat)
  RETURNING id INTO v_prod;
  IF p_lote > 0 THEN
    INSERT INTO public.compras (sucursal_id, estado, usuario_id)
    VALUES (p_suc, 'recibida', p_adm) RETURNING id INTO v_compra;
    INSERT INTO public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad,
                                       cantidad_restante, usuario_id, compra_id)
    VALUES (v_prod, p_suc, pg_temp.er_hoy() + 90, p_lote, p_lote, p_adm, v_compra);
  END IF;
  RETURN v_prod;
END
$fn$;

-- "Compra 10, lleva 2" sobre p_disparador. Fraccion: el contenedor es el regalo.
CREATE OR REPLACE FUNCTION pg_temp.er_promo(p_suc bigint, p_regalo bigint, p_disparador bigint, p_mueve boolean)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock,
                                  producto_regalo_id, ajuste_automatico, unidades_por_bloque,
                                  stock_por_bloque, ajuste_producto_id)
  VALUES ('ZZ ensayo 1323', 'bonificacion', pg_temp.er_hoy() - 1, p_suc, p_mueve, p_regalo, NOT p_mueve,
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

-- Cambia el tipo de regalo de la promo, como lo guarda ModalPromocion.
CREATE OR REPLACE FUNCTION pg_temp.er_cambiar_tipo(p_promo bigint, p_mueve boolean, p_contenedor bigint)
RETURNS void LANGUAGE sql AS $fn$
  UPDATE public.promociones
     SET regalo_mueve_stock = p_mueve, ajuste_automatico = NOT p_mueve,
         unidades_por_bloque = CASE WHEN NOT p_mueve THEN 6 END,
         stock_por_bloque = CASE WHEN NOT p_mueve THEN 1 END,
         ajuste_producto_id = CASE WHEN NOT p_mueve THEN p_contenedor END
   WHERE id = p_promo;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.er_v(p_prod bigint, p_cant int)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 100);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.er_r(p_prod bigint, p_cant int, p_promo bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 0,
                            'es_bonificacion', true, 'promocion_id', p_promo);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.er_alta(p_cli bigint, p_adm uuid, p_items jsonb)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.crear_pedido_completo(
    p_cli,
    (SELECT SUM((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric) FROM jsonb_array_elements(p_items) e),
    p_adm, p_items, 'ensayo 1323');
  PERFORM pg_temp.er_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.er_editar(p_ped bigint, p_adm uuid, p_items jsonb, p_esperado timestamptz DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.actualizar_pedido_items(p_ped, p_items, p_adm, NULL, p_esperado);
  PERFORM pg_temp.er_reset();
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.er_ok(p_res jsonb)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT COALESCE((p_res->>'success')::boolean, false);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.er_linea(p_ped bigint, p_prod bigint, p_regalo boolean DEFAULT true)
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT id FROM public.pedido_items
   WHERE pedido_id = p_ped AND producto_id = p_prod AND COALESCE(es_bonificacion, false) = p_regalo
   ORDER BY id LIMIT 1;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.er_cant(p_ped bigint, p_prod bigint, p_regalo boolean DEFAULT true)
RETURNS int LANGUAGE sql AS $fn$
  SELECT COALESCE(SUM(cantidad), 0)::int FROM public.pedido_items
   WHERE pedido_id = p_ped AND producto_id = p_prod AND COALESCE(es_bonificacion, false) = p_regalo;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.er_salvedad(p_ped bigint, p_item bigint, p_cant int, p_motivo text DEFAULT 'cliente_rechaza',
                                               p_clave uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.registrar_salvedad(p_ped, p_item, p_cant, p_motivo, 'ensayo 1323', NULL, true, p_clave);
  PERFORM pg_temp.er_reset();
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.er_sustituir(p_item bigint, p_prod bigint, p_cant int)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.sustituir_regalo_pedido(p_item, p_prod, p_cant, 'ensayo 1323');
  PERFORM pg_temp.er_reset();
  IF NOT pg_temp.er_ok(v_res) THEN
    RAISE EXCEPTION 'no se pudo sustituir: %', v_res;
  END IF;
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.er_dividir(p_item bigint, p_a bigint, p_ca int, p_b bigint, p_cb int)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.dividir_regalo_pedido(p_item,
    jsonb_build_array(jsonb_build_object('producto_id', p_a, 'cantidad', p_ca),
                      jsonb_build_object('producto_id', p_b, 'cantidad', p_cb)), 'ensayo 1323');
  PERFORM pg_temp.er_reset();
  IF NOT pg_temp.er_ok(v_res) THEN
    RAISE EXCEPTION 'no se pudo repartir: %', v_res;
  END IF;
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.er_cancelar(p_ped bigint)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.cancelar_pedido_con_stock(p_ped, 'ensayo 1323', auth.uid(), 'error_de_carga');
  PERFORM pg_temp.er_reset();
  IF NOT pg_temp.er_ok(v_res) THEN
    RAISE EXCEPTION 'no se pudo cancelar: %', v_res;
  END IF;
END
$fn$;

-- ---------------------------------------------------------------------------
-- #1323
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.er_caso_p2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; x bigint; v_promo bigint; v_ped bigint; v_res jsonb;
BEGIN
  x := pg_temp.er_prod(p_suc, p_adm, 'x', 7, 5);
  v_promo := pg_temp.er_promo(p_suc, x, x, true);
  v_ped := pg_temp.er_alta(p_cli, p_adm, jsonb_build_array(pg_temp.er_v(x, 2), pg_temp.er_r(x, 1, v_promo)));
  f := pg_temp.er_si(f, pg_temp.er_stock(x) = 9, format('el alta dejo stock %s, esperado 9', pg_temp.er_stock(x)));

  v_res := pg_temp.er_editar(v_ped, p_adm, jsonb_build_array(pg_temp.er_v(x, 8), pg_temp.er_r(x, 5, v_promo)));
  f := pg_temp.er_si(f, NOT pg_temp.er_ok(v_res) AND v_res::text LIKE '%stock insuficiente (disponible: 9, adicional: 10)%',
                     format('8+5 contra 12 dio %s, esperado el rechazo por la suma', v_res));
  f := pg_temp.er_si(f, pg_temp.er_stock(x) = 9, format('tras el rechazo el stock quedo %s', pg_temp.er_stock(x)));

  v_res := pg_temp.er_editar(v_ped, p_adm, jsonb_build_array(pg_temp.er_v(x, 8), pg_temp.er_r(x, 4, v_promo)));
  f := pg_temp.er_si(f, pg_temp.er_ok(v_res), format('8+4 contra 12 dio %s, esperado que pase', v_res));
  f := pg_temp.er_si(f, pg_temp.er_stock(x) = 0, format('8+4 dejo stock %s, esperado 0', pg_temp.er_stock(x)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.er_caso_p6(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; x bigint; v_ped bigint; v_res jsonb; v_leido timestamptz;
BEGIN
  x := pg_temp.er_prod(p_suc, p_adm, 'x', 50, 5);
  v_ped := pg_temp.er_alta(p_cli, p_adm, jsonb_build_array(pg_temp.er_v(x, 2)));
  -- Toda la transaccion tiene el mismo now(): el leido se corre para atras.
  UPDATE public.pedidos SET updated_at = now() - interval '1 hour' WHERE id = v_ped RETURNING updated_at INTO v_leido;

  v_res := pg_temp.er_editar(v_ped, p_adm, jsonb_build_array(pg_temp.er_v(x, 3)), v_leido);
  f := pg_temp.er_si(f, pg_temp.er_ok(v_res), format('con el vigente dio %s, esperado que pase', v_res));
  f := pg_temp.er_si(f, (v_res->>'updated_at')::timestamptz = (SELECT updated_at FROM public.pedidos WHERE id = v_ped),
                     format('devolvio updated_at %s, que no es el de la fila', v_res->>'updated_at'));

  v_res := pg_temp.er_editar(v_ped, p_adm, jsonb_build_array(pg_temp.er_v(x, 9)), v_leido);
  f := pg_temp.er_si(f, NOT pg_temp.er_ok(v_res) AND v_res->>'codigo' = 'pedido_editado_por_otro'
                        AND v_res::text LIKE '%Otro usuario%',
                     format('con el viejo dio %s, esperado el rechazo', v_res));
  f := pg_temp.er_si(f, pg_temp.er_cant(v_ped, x, false) = 3,
                     format('el rechazo dejo %s, esperado 3', pg_temp.er_cant(v_ped, x, false)));

  v_res := pg_temp.er_editar(v_ped, p_adm, jsonb_build_array(pg_temp.er_v(x, 4)));
  f := pg_temp.er_si(f, pg_temp.er_ok(v_res), format('sin parametro dio %s, esperado que pase', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.er_caso_p5(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; x bigint; v_ped bigint; v_res jsonb;
BEGIN
  x := pg_temp.er_prod(p_suc, p_adm, 'x', 50, 5);
  v_ped := pg_temp.er_alta(p_cli, p_adm, jsonb_build_array(pg_temp.er_v(x, 2)));
  UPDATE public.pedidos SET canal = 'cambio' WHERE id = v_ped;
  v_res := pg_temp.er_editar(v_ped, p_adm, jsonb_build_array(pg_temp.er_v(x, 3)));
  f := pg_temp.er_si(f, NOT pg_temp.er_ok(v_res) AND v_res::text LIKE '%canje no se edita%',
                     format('editar un canje dio %s, esperado el rechazo', v_res));
  f := pg_temp.er_si(f, pg_temp.er_cant(v_ped, x, false) = 2, 'el rechazo cambio la linea');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- #1324
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.er_caso_m1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint; r bigint; r2 bigint; v_promo bigint;
  p_cae bigint; p_reg bigint; p_can bigint; p_edi bigint; p_sus bigint; p_div bigint;
  v_antes int; v_res jsonb;
  v_items jsonb;
BEGIN
  v  := pg_temp.er_prod(p_suc, p_adm, 'v', 500, 50);
  r  := pg_temp.er_prod(p_suc, p_adm, 'r', 100, 50);
  r2 := pg_temp.er_prod(p_suc, p_adm, 'r', 100, 50);
  v_promo := pg_temp.er_promo(p_suc, r, v, true);
  v_items := jsonb_build_array(pg_temp.er_v(v, 10), pg_temp.er_r(r, 2, v_promo));
  p_cae := pg_temp.er_alta(p_cli, p_adm, v_items);
  p_reg := pg_temp.er_alta(p_cli, p_adm, v_items);
  p_can := pg_temp.er_alta(p_cli, p_adm, v_items);
  p_edi := pg_temp.er_alta(p_cli, p_adm, v_items);
  p_sus := pg_temp.er_alta(p_cli, p_adm, v_items);
  p_div := pg_temp.er_alta(p_cli, p_adm, v_items);

  -- 12 usos de unidad entera: como barra de 6 serian 2 bloques.
  v_antes := pg_temp.er_stock(r);
  PERFORM pg_temp.er_cambiar_tipo(v_promo, false, r);
  f := pg_temp.er_si(f, pg_temp.er_stock(r) = v_antes,
                     format('pasar a fraccion movio %s, esperado 0', pg_temp.er_stock(r) - v_antes));
  f := pg_temp.er_si(f, (SELECT usos_pendientes FROM public.promociones WHERE id = v_promo) = 0,
                     'pasar a fraccion no reinicio la barra');

  -- La salvedad que hace caer el regalo devuelve lo que salio, y nada mas.
  v_antes := pg_temp.er_stock(r);
  v_res := pg_temp.er_salvedad(p_cae, pg_temp.er_linea(p_cae, v, false), 5);
  f := pg_temp.er_si(f, pg_temp.er_ok(v_res), format('salvedad: %s', v_res));
  f := pg_temp.er_si(f, pg_temp.er_stock(r) = v_antes + 2,
                     format('la salvedad que tira el regalo movio %s, esperado +2', pg_temp.er_stock(r) - v_antes));

  -- La salvedad sobre el regalo.
  v_antes := pg_temp.er_stock(r);
  v_res := pg_temp.er_salvedad(p_reg, pg_temp.er_linea(p_reg, r), 1);
  f := pg_temp.er_si(f, pg_temp.er_ok(v_res) AND (v_res->>'stock_devuelto')::boolean,
                     format('salvedad sobre el regalo: %s, esperado que devuelva', v_res));
  f := pg_temp.er_si(f, pg_temp.er_stock(r) = v_antes + 1,
                     format('la salvedad sobre el regalo movio %s, esperado +1', pg_temp.er_stock(r) - v_antes));

  -- Cancelar: 2 fantasma si no se leyera la foto, y un fardo si tocara la barra.
  v_antes := pg_temp.er_stock(r);
  PERFORM pg_temp.er_cancelar(p_can);
  f := pg_temp.er_si(f, pg_temp.er_stock(r) = v_antes + 2,
                     format('cancelar movio %s, esperado +2', pg_temp.er_stock(r) - v_antes));

  -- Editar: devuelve 2 y baja 4, con el modo de la foto, que no cambia.
  v_antes := pg_temp.er_stock(r);
  v_res := pg_temp.er_editar(p_edi, p_adm, jsonb_build_array(pg_temp.er_v(v, 20), pg_temp.er_r(r, 4, v_promo)));
  f := pg_temp.er_si(f, pg_temp.er_ok(v_res), format('edicion: %s', v_res));
  f := pg_temp.er_si(f, pg_temp.er_stock(r) = v_antes - 2,
                     format('editar movio %s, esperado -2', pg_temp.er_stock(r) - v_antes));
  f := pg_temp.er_si(f, (SELECT regalo_mueve_stock FROM public.pedido_promo_reglas
                          WHERE pedido_id = p_edi AND promocion_id = v_promo),
                     'la edicion le cambio el modo a la foto');
  v_antes := pg_temp.er_stock(r);
  PERFORM pg_temp.er_cancelar(p_edi);
  f := pg_temp.er_si(f, pg_temp.er_stock(r) = v_antes + 4,
                     format('cancelar lo editado movio %s, esperado +4', pg_temp.er_stock(r) - v_antes));

  -- Sustituir y dividir mueven stock, no la barra.
  v_antes := pg_temp.er_stock(r2);
  PERFORM pg_temp.er_sustituir(pg_temp.er_linea(p_sus, r), r2, 2);
  f := pg_temp.er_si(f, pg_temp.er_stock(r2) = v_antes - 2,
                     format('sustituir bajo %s del sustituto, esperado -2', pg_temp.er_stock(r2) - v_antes));
  v_antes := pg_temp.er_stock(r2);
  PERFORM pg_temp.er_dividir(pg_temp.er_linea(p_div, r), r, 1, r2, 1);
  f := pg_temp.er_si(f, pg_temp.er_stock(r2) = v_antes - 1,
                     format('dividir bajo %s de la parte, esperado -1', pg_temp.er_stock(r2) - v_antes));

  f := pg_temp.er_si(f, (SELECT usos_pendientes FROM public.promociones WHERE id = v_promo) = 0
                        AND NOT EXISTS (SELECT 1 FROM public.promo_ajustes WHERE promocion_id = v_promo
                                                                             AND created_at >= now()
                                                                             AND unidades_ajustadas <> 0
                                                                             AND producto_id = r
                                                                             AND usos_ajustados < 0),
                     'una linea de otro modo toco la barra viva');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.er_caso_m2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint; r bigint; v_promo bigint; p_a bigint; p_b bigint; p_c bigint;
  v_antes int; v_res jsonb; v_items jsonb;
BEGIN
  v := pg_temp.er_prod(p_suc, p_adm, 'v', 500, 50);
  r := pg_temp.er_prod(p_suc, p_adm, 'r', 100, 50);
  v_promo := pg_temp.er_promo(p_suc, r, v, false);
  v_items := jsonb_build_array(pg_temp.er_v(v, 10), pg_temp.er_r(r, 2, v_promo));
  p_a := pg_temp.er_alta(p_cli, p_adm, v_items);
  p_b := pg_temp.er_alta(p_cli, p_adm, v_items);
  p_c := pg_temp.er_alta(p_cli, p_adm, v_items);
  PERFORM pg_temp.er_cambiar_tipo(v_promo, true, NULL);

  v_antes := pg_temp.er_stock(r);
  PERFORM pg_temp.er_cancelar(p_a);
  v_res := pg_temp.er_salvedad(p_b, pg_temp.er_linea(p_b, r), 1);
  f := pg_temp.er_si(f, pg_temp.er_ok(v_res) AND NOT (v_res->>'stock_devuelto')::boolean,
                     format('salvedad: %s, esperado que no devuelva', v_res));
  v_res := pg_temp.er_editar(p_c, p_adm, jsonb_build_array(pg_temp.er_v(v, 20), pg_temp.er_r(r, 4, v_promo)));
  f := pg_temp.er_si(f, pg_temp.er_ok(v_res), format('edicion: %s', v_res));
  f := pg_temp.er_si(f, pg_temp.er_stock(r) = v_antes,
                     format('cancelar, la salvedad y editar movieron %s, esperado 0', pg_temp.er_stock(r) - v_antes));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.er_caso_m3(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint; r bigint; v_promo bigint; v_ped bigint; v_antes int;
BEGIN
  v := pg_temp.er_prod(p_suc, p_adm, 'v', 500, 50);
  r := pg_temp.er_prod(p_suc, p_adm, 'r', 100, 50);
  v_promo := pg_temp.er_promo(p_suc, r, v, true);
  PERFORM pg_temp.er_cambiar_tipo(v_promo, false, r);
  v_antes := pg_temp.er_stock(r);
  v_ped := pg_temp.er_alta(p_cli, p_adm, jsonb_build_array(pg_temp.er_v(v, 10), pg_temp.er_r(r, 2, v_promo)));
  f := pg_temp.er_si(f, pg_temp.er_stock(r) = v_antes, 'un pedido nuevo no salio con el modo nuevo');
  f := pg_temp.er_si(f, NOT (SELECT regalo_mueve_stock FROM public.pedido_promo_reglas
                              WHERE pedido_id = v_ped AND promocion_id = v_promo),
                     'la foto de un pedido nuevo no tiene el modo nuevo');
  f := pg_temp.er_si(f, (SELECT usos_pendientes FROM public.promociones WHERE id = v_promo) = 2,
                     'un pedido nuevo no entro en la barra');
  f := pg_temp.er_si(f, public.promo_pedidos_abiertos(v_promo) = 1, 'promo_pedidos_abiertos no lo cuenta');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.er_caso_m4(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint; r bigint; r2 bigint; v_promo bigint; v_b bigint;
  p_fac bigint; p_sus bigint; p_reg bigint; p_foto bigint; v_res jsonb; v_antes int; v_items jsonb;
BEGIN
  v  := pg_temp.er_prod(p_suc, p_adm, 'v', 500, 50);
  r  := pg_temp.er_prod(p_suc, p_adm, 'r', 100, 50);
  r2 := pg_temp.er_prod(p_suc, p_adm, 'r', 100, 50);

  -- Fraccion que pasa a entera: el factor 6 de la linea sobrevive.
  v_b := pg_temp.er_promo(p_suc, r, v, false);
  v_items := jsonb_build_array(pg_temp.er_v(v, 10), pg_temp.er_r(r, 2, v_b));
  p_fac := pg_temp.er_alta(p_cli, p_adm, v_items);
  p_sus := pg_temp.er_alta(p_cli, p_adm, v_items);
  PERFORM pg_temp.er_cambiar_tipo(v_b, true, NULL);
  v_res := pg_temp.er_editar(p_fac, p_adm, jsonb_build_array(pg_temp.er_v(v, 20), pg_temp.er_r(r, 4, v_b)));
  f := pg_temp.er_si(f, pg_temp.er_ok(v_res), format('edicion: %s', v_res));
  f := pg_temp.er_si(f, (SELECT unidades_por_bloque_al_crear FROM public.pedido_items WHERE id = pg_temp.er_linea(p_fac, r)) = 6,
                     format('la edicion dejo factor %s, esperado 6',
                            (SELECT unidades_por_bloque_al_crear FROM public.pedido_items WHERE id = pg_temp.er_linea(p_fac, r))));
  PERFORM pg_temp.er_sustituir(pg_temp.er_linea(p_sus, r), r2, 2);
  f := pg_temp.er_si(f, (SELECT unidades_por_bloque_al_crear FROM public.pedido_items WHERE id = pg_temp.er_linea(p_sus, r2)) = 6,
                     'sustituir no conservo el factor');

  -- Entera que pasa a fraccion con otra regla: 12 serian 12 fardos.
  v_promo := pg_temp.er_promo(p_suc, r, v, true);
  p_reg := pg_temp.er_alta(p_cli, p_adm, jsonb_build_array(pg_temp.er_v(v, 10), pg_temp.er_r(r, 2, v_promo)));
  p_foto := pg_temp.er_alta(p_cli, p_adm, jsonb_build_array(pg_temp.er_v(v, 10), pg_temp.er_r(r, 2, v_promo)));
  v_res := pg_temp.er_editar(p_foto, p_adm, jsonb_build_array(pg_temp.er_v(v, 5)));
  f := pg_temp.er_si(f, pg_temp.er_ok(v_res), format('sacar el regalo: %s', v_res));
  PERFORM pg_temp.er_cambiar_tipo(v_promo, false, r);
  UPDATE public.promocion_reglas SET valor = 12 WHERE promocion_id = v_promo AND clave = 'cantidad_bonificacion';

  v_antes := pg_temp.er_stock(r);
  v_res := pg_temp.er_editar(p_reg, p_adm, jsonb_build_array(pg_temp.er_v(v, 10), pg_temp.er_r(r, 12, v_promo)));
  f := pg_temp.er_si(f, NOT pg_temp.er_ok(v_res) AND v_res->>'codigo' = 'regalo_de_promo_cambiada',
                     format('recalcular con la regla nueva dio %s, esperado el rechazo', v_res));
  f := pg_temp.er_si(f, pg_temp.er_stock(r) = v_antes AND pg_temp.er_cant(p_reg, r) = 2, 'el rechazo cambio algo');
  -- El mismo regalo, tocando otra cosa, sigue.
  v_res := pg_temp.er_editar(p_reg, p_adm, jsonb_build_array(pg_temp.er_v(v, 11), pg_temp.er_r(r, 2, v_promo)));
  f := pg_temp.er_si(f, pg_temp.er_ok(v_res), format('con el regalo como estaba dio %s', v_res));
  -- Esa edicion no le rehizo la foto: el recalculo sigue rechazado.
  v_res := pg_temp.er_editar(p_reg, p_adm, jsonb_build_array(pg_temp.er_v(v, 11), pg_temp.er_r(r, 12, v_promo)));
  f := pg_temp.er_si(f, v_res->>'codigo' = 'regalo_de_promo_cambiada',
                     format('recalcular despues de una edicion dio %s, esperado el rechazo', v_res));

  -- El regalo que vuelve a un pedido que ya no lo tenia sale con el modo vivo.
  v_antes := pg_temp.er_stock(r);
  v_res := pg_temp.er_editar(p_foto, p_adm, jsonb_build_array(pg_temp.er_v(v, 10), pg_temp.er_r(r, 2, v_promo)));
  f := pg_temp.er_si(f, pg_temp.er_ok(v_res), format('volver a agregar el regalo: %s', v_res));
  f := pg_temp.er_si(f, pg_temp.er_stock(r) = v_antes,
                     format('el regalo que vuelve movio %s, esperado 0 (modo vivo)', pg_temp.er_stock(r) - v_antes));
  f := pg_temp.er_si(f, (SELECT usos_pendientes FROM public.promociones WHERE id = v_promo) = 2,
                     'el regalo que vuelve no entro en la barra');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- #1325
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.er_caso_r1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint; a bigint; b bigint; p bigint; v_promo bigint; v_ped bigint;
  v_linea bigint; v_antes int; v_res jsonb; s record; l record;
BEGIN
  v := pg_temp.er_prod(p_suc, p_adm, 'v', 500, 50);
  a := pg_temp.er_prod(p_suc, p_adm, 'a', 100, 50);
  b := pg_temp.er_prod(p_suc, p_adm, 'a', 100, 50);
  p := pg_temp.er_prod(p_suc, p_adm, 'p', 100, 50);
  v_promo := pg_temp.er_promo(p_suc, a, v, true);

  -- Por valor: A x4 -> P x19. Una salvedad de 1 deja 19 vendidas y 2 de A: P x10.
  v_ped := pg_temp.er_alta(p_cli, p_adm, jsonb_build_array(pg_temp.er_v(v, 20), pg_temp.er_r(a, 4, v_promo)));
  PERFORM pg_temp.er_sustituir(pg_temp.er_linea(v_ped, a), p, 19);
  v_linea := pg_temp.er_linea(v_ped, v, false);

  SELECT * INTO s FROM public.simular_salvedad_promo_impacto(v_ped, v_linea, 1);
  f := pg_temp.er_si(f, s.bonif_actual = 19 AND s.bonif_esperada = 10 AND s.delta = 9 AND NOT s.sera_eliminada,
                     format('simular dio actual %s, esperada %s, delta %s', s.bonif_actual, s.bonif_esperada, s.delta));
  SELECT * INTO l FROM public.simular_salvedades_promo_impacto(v_ped,
    jsonb_build_array(jsonb_build_object('pedido_item_id', v_linea, 'cantidad_afectada', 1)));
  f := pg_temp.er_si(f, l.cantidad_actual = 19 AND l.cantidad_final = 10 AND l.delta = 9,
                     format('simular el lote dio %s -> %s', l.cantidad_actual, l.cantidad_final));

  v_antes := pg_temp.er_stock(p);
  v_res := pg_temp.er_salvedad(v_ped, v_linea, 1);
  f := pg_temp.er_si(f, pg_temp.er_ok(v_res), format('salvedad: %s', v_res));
  f := pg_temp.er_si(f, pg_temp.er_cant(v_ped, p) = 10,
                     format('la salvedad dejo P x%s, esperado P x10', pg_temp.er_cant(v_ped, p)));
  f := pg_temp.er_si(f, pg_temp.er_stock(p) = v_antes + 9,
                     format('la salvedad devolvio %s de P, esperado 9', pg_temp.er_stock(p) - v_antes));

  -- La edicion manda la raiz con la cantidad de la promo y la linea sigue igual.
  v_antes := pg_temp.er_stock(p);
  v_res := pg_temp.er_editar(v_ped, p_adm, jsonb_build_array(pg_temp.er_v(v, 19), pg_temp.er_r(a, 2, v_promo)));
  f := pg_temp.er_si(f, pg_temp.er_ok(v_res), format('edicion: %s', v_res));
  f := pg_temp.er_si(f, pg_temp.er_cant(v_ped, p) = 10 AND pg_temp.er_stock(p) = v_antes,
                     format('la edicion dejo P x%s y movio %s', pg_temp.er_cant(v_ped, p), pg_temp.er_stock(p) - v_antes));

  -- La segunda: la linea ya se movio despues de su eslabon, y sigue valiendo 2.
  v_linea := pg_temp.er_linea(v_ped, v, false);
  SELECT * INTO s FROM public.simular_salvedad_promo_impacto(v_ped, v_linea, 10);
  f := pg_temp.er_si(f, s.delta = 10 AND s.sera_eliminada,
                     format('simular la segunda dio delta %s, eliminada %s', s.delta, s.sera_eliminada));
  v_antes := pg_temp.er_stock(p);
  v_res := pg_temp.er_salvedad(v_ped, v_linea, 10);
  f := pg_temp.er_si(f, pg_temp.er_ok(v_res) AND pg_temp.er_cant(v_ped, p) = 0 AND pg_temp.er_stock(p) = v_antes + 10,
                     format('la segunda dejo P x%s y devolvio %s: %s', pg_temp.er_cant(v_ped, p),
                            pg_temp.er_stock(p) - v_antes, v_res));

  -- Sin cadena: lo de siempre.
  v_ped := pg_temp.er_alta(p_cli, p_adm, jsonb_build_array(pg_temp.er_v(v, 20), pg_temp.er_r(a, 4, v_promo)));
  v_res := pg_temp.er_salvedad(v_ped, pg_temp.er_linea(v_ped, v, false), 1);
  f := pg_temp.er_si(f, pg_temp.er_cant(v_ped, a) = 2,
                     format('sin cadena dejo A x%s, esperado A x2', pg_temp.er_cant(v_ped, a)));

  -- Un reparto: A x2 + B x2. Se recorta de la linea mas nueva y queda el corte que da la promo.
  v_ped := pg_temp.er_alta(p_cli, p_adm, jsonb_build_array(pg_temp.er_v(v, 20), pg_temp.er_r(a, 4, v_promo)));
  PERFORM pg_temp.er_dividir(pg_temp.er_linea(v_ped, a), a, 2, b, 2);
  v_res := pg_temp.er_salvedad(v_ped, pg_temp.er_linea(v_ped, v, false), 1);
  f := pg_temp.er_si(f, pg_temp.er_cant(v_ped, a) + pg_temp.er_cant(v_ped, b) = 2,
                     format('el reparto quedo A x%s + B x%s, esperado que sumen 2',
                            pg_temp.er_cant(v_ped, a), pg_temp.er_cant(v_ped, b)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.er_caso_r2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint; a bigint; b bigint; c bigint; v_promo bigint; v_ped bigint; v_res jsonb;
  v_usos bigint;
BEGIN
  v := pg_temp.er_prod(p_suc, p_adm, 'v', 500, 50);
  a := pg_temp.er_prod(p_suc, p_adm, 'a', 100, 50);
  b := pg_temp.er_prod(p_suc, p_adm, 'a', 100, 50);
  c := pg_temp.er_prod(p_suc, p_adm, 'a', 100, 50);
  v_promo := pg_temp.er_promo(p_suc, a, v, true);
  v_ped := pg_temp.er_alta(p_cli, p_adm, jsonb_build_array(pg_temp.er_v(v, 20), pg_temp.er_r(a, 4, v_promo)));
  PERFORM pg_temp.er_sustituir(pg_temp.er_linea(v_ped, a), b, 4);
  v_res := pg_temp.er_salvedad(v_ped, pg_temp.er_linea(v_ped, v, false), 10);
  f := pg_temp.er_si(f, pg_temp.er_cant(v_ped, b) = 2, format('la primera dejo B x%s: %s', pg_temp.er_cant(v_ped, b), v_res));
  PERFORM pg_temp.er_sustituir(pg_temp.er_linea(v_ped, b), c, 2);
  SELECT del_pedido INTO v_usos FROM public._promo_usos(v_promo, v_ped);
  f := pg_temp.er_si(f, v_usos = 2, format('C x2 cuenta %s, esperado 2', v_usos));
  v_res := pg_temp.er_salvedad(v_ped, pg_temp.er_linea(v_ped, v, false), 1);
  f := pg_temp.er_si(f, pg_temp.er_cant(v_ped, c) = 0,
                     format('la segunda dejo C x%s, esperado que caiga: %s', pg_temp.er_cant(v_ped, c), v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.er_caso_r3(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint; a bigint; b bigint; v_promo bigint; v_ped bigint; v_res jsonb; v_usos bigint;
BEGIN
  v := pg_temp.er_prod(p_suc, p_adm, 'v', 500, 50);
  a := pg_temp.er_prod(p_suc, p_adm, 'a', 100, 50);
  b := pg_temp.er_prod(p_suc, p_adm, 'a', 100, 50);
  v_promo := pg_temp.er_promo(p_suc, a, v, true);
  v_ped := pg_temp.er_alta(p_cli, p_adm, jsonb_build_array(pg_temp.er_v(v, 20), pg_temp.er_r(a, 4, v_promo)));
  PERFORM pg_temp.er_sustituir(pg_temp.er_linea(v_ped, a), b, 6);
  v_res := pg_temp.er_editar(v_ped, p_adm, jsonb_build_array(pg_temp.er_v(v, 40), pg_temp.er_r(a, 8, v_promo)));
  f := pg_temp.er_si(f, pg_temp.er_ok(v_res), format('edicion: %s', v_res));
  f := pg_temp.er_si(f, pg_temp.er_cant(v_ped, b) = 12,
                     format('la edicion dejo B x%s, esperado B x12 (lo que muestra la pantalla)', pg_temp.er_cant(v_ped, b)));
  SELECT del_pedido INTO v_usos FROM public._promo_usos(v_promo, v_ped);
  f := pg_temp.er_si(f, v_usos = 8, format('el cupo cuenta %s, esperado el corte, 8', v_usos));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- #1326: el deadlock no se reproduce con una sesion; se mira el orden del cuerpo.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.er_caso_l1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_def text; v_firma text;
BEGIN
  FOREACH v_firma IN ARRAY ARRAY['public.cancelar_pedido_con_stock(bigint,text,uuid,text)',
                                 'public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamptz)',
                                 'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)',
                                 'public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)',
                                 'public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'] LOOP
    v_def := pg_get_functiondef(v_firma::regprocedure);
    f := pg_temp.er_si(f, position('public._contenedores_de_promos(' IN v_def) > 0
                          AND position('public._contenedores_de_promos(' IN v_def) < position('aplicar_uso_promo_acumulador' IN v_def),
                       format('%s no bloquea los contenedores antes del motor de promos', v_firma));
  END LOOP;
  FOREACH v_firma IN ARRAY ARRAY['public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)',
                                 'public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'] LOOP
    v_def := pg_get_functiondef(v_firma::regprocedure);
    f := pg_temp.er_si(f, v_def ~ 'PERFORM 1 FROM productos\s+WHERE sucursal_id = v_sucursal[^;]*ORDER BY id\s+FOR UPDATE;'
                          AND position('PERFORM 1 FROM productos' IN v_def) > 0
                          AND position('PERFORM 1 FROM productos' IN v_def) < position('UPDATE productos' IN v_def)
                          AND position('PERFORM 1 FROM productos' IN v_def) < position('SELECT stock' IN v_def),
                       format('%s no bloquea sus productos juntos antes de moverlos', v_firma));
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- #1327
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.er_caso_c1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; x bigint; v_ped bigint; v_res jsonb; v_clave uuid := gen_random_uuid(); v_s1 bigint; v_s2 bigint;
  v_dia date := pg_temp.er_hoy() + 401; v_tr uuid;
BEGIN
  -- Un chofer de la sucursal: otro usuario, con el rol puesto (se revierte con el caso).
  SELECT us.usuario_id INTO v_tr
    FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
   WHERE us.sucursal_id = p_suc AND us.usuario_id <> p_adm
   ORDER BY (pf.rol = 'transportista') DESC, us.usuario_id
   LIMIT 1;
  UPDATE public.perfiles SET rol = 'transportista' WHERE id = v_tr;
  x := pg_temp.er_prod(p_suc, p_adm, 'x', 50, 5);
  v_ped := pg_temp.er_alta(p_cli, p_adm, jsonb_build_array(pg_temp.er_v(x, 10)));
  -- A las 23 de Argentina: en UTC ya es el dia siguiente.
  UPDATE public.pedidos
     SET transportista_id = v_tr, estado = 'entregado',
         fecha_entrega = (v_dia + time '23:00') AT TIME ZONE 'America/Argentina/Buenos_Aires'
   WHERE id = v_ped;

  v_res := pg_temp.er_salvedad(v_ped, pg_temp.er_linea(v_ped, x, false), 1, 'cliente_rechaza', v_clave);
  f := pg_temp.er_si(f, pg_temp.er_ok(v_res), format('con la caja abierta dio %s', v_res));
  v_s1 := (v_res->>'salvedad_id')::bigint;

  -- La caja del dia anterior no lo alcanza.
  INSERT INTO public.rendiciones_control (fecha, transportista_id, sucursal_id, estado, controlada_at, controlada_por)
  VALUES (v_dia - 1, p_adm, p_suc, 'confirmada', now(), p_adm);
  v_res := pg_temp.er_salvedad(v_ped, pg_temp.er_linea(v_ped, x, false), 1);
  f := pg_temp.er_si(f, pg_temp.er_ok(v_res), format('con la caja cerrada hasta el dia anterior dio %s', v_res));
  v_s2 := (v_res->>'salvedad_id')::bigint;
  v_res := public.anular_salvedad(v_s2, 'ensayo 1323');
  PERFORM pg_temp.er_reset();
  f := pg_temp.er_si(f, pg_temp.er_ok(v_res), format('anular con la caja abierta dio %s', v_res));

  INSERT INTO public.rendiciones_control (fecha, transportista_id, sucursal_id, estado, controlada_at, controlada_por)
  VALUES (v_dia, p_adm, p_suc, 'confirmada', now(), p_adm);
  v_res := pg_temp.er_salvedad(v_ped, pg_temp.er_linea(v_ped, x, false), 1);
  f := pg_temp.er_si(f, NOT pg_temp.er_ok(v_res) AND v_res->>'codigo' = 'caja_cerrada',
                     format('con la caja cerrada dio %s, esperado el rechazo', v_res));
  f := pg_temp.er_si(f, pg_temp.er_cant(v_ped, x, false) = 9,
                     format('el rechazo dejo %s, esperado 9', pg_temp.er_cant(v_ped, x, false)));

  -- El reintento de lo que entro antes del cierre contesta lo que hizo.
  v_res := pg_temp.er_salvedad(v_ped, pg_temp.er_linea(v_ped, x, false), 1, 'cliente_rechaza', v_clave);
  f := pg_temp.er_si(f, pg_temp.er_ok(v_res) AND (v_res->>'idempotent_replay')::boolean
                        AND (v_res->>'salvedad_id')::bigint = v_s1,
                     format('el reintento dio %s, esperado el replay', v_res));
  -- La misma clave con otros datos: no se da por hecho lo que no se hizo.
  v_res := pg_temp.er_salvedad(v_ped, pg_temp.er_linea(v_ped, x, false), 2, 'cliente_rechaza', v_clave);
  f := pg_temp.er_si(f, NOT pg_temp.er_ok(v_res) AND v_res->>'codigo' = 'salvedad_ya_registrada',
                     format('la clave con otra cantidad dio %s, esperado el rechazo', v_res));

  v_res := public.anular_salvedad(v_s1, 'ensayo 1323');
  PERFORM pg_temp.er_reset();
  f := pg_temp.er_si(f, NOT pg_temp.er_ok(v_res) AND v_res->>'codigo' = 'caja_cerrada',
                     format('anular con la caja cerrada dio %s, esperado el rechazo', v_res));
  f := pg_temp.er_si(f, (SELECT estado_resolucion FROM public.salvedades_items WHERE id = v_s1) = 'pendiente',
                     'el rechazo anulo la salvedad');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.er_caso_c2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; x bigint; v_ped bigint; v_res jsonb; v_dia date := pg_temp.er_hoy() + 401;
BEGIN
  x := pg_temp.er_prod(p_suc, p_adm, 'x', 50, 5);
  v_ped := pg_temp.er_alta(p_cli, p_adm, jsonb_build_array(pg_temp.er_v(x, 2)));
  UPDATE public.pedidos
     SET tipo_factura = 'VB', total = total, monto_pagado = total,
         transportista_id = p_adm, estado = 'entregado',
         fecha_entrega = (v_dia + time '23:00') AT TIME ZONE 'America/Argentina/Buenos_Aires'
   WHERE id = v_ped;

  INSERT INTO public.rendiciones_control (fecha, transportista_id, sucursal_id, estado, controlada_at, controlada_por)
  VALUES (v_dia, p_adm, p_suc, 'confirmada', now(), p_adm);
  v_res := public.cancelar_pedido_con_stock(v_ped, 'ensayo 1323', p_adm, 'error_de_carga');
  PERFORM pg_temp.er_reset();
  f := pg_temp.er_si(f, NOT pg_temp.er_ok(v_res) AND v_res::text LIKE '%' || to_char(v_dia, 'DD/MM/YYYY') || '%caja esta cerrada%',
                     format('con su caja cerrada dio %s, esperado el rechazo con su dia', v_res));

  DELETE FROM public.rendiciones_control WHERE fecha = v_dia AND sucursal_id = p_suc;
  INSERT INTO public.rendiciones_control (fecha, transportista_id, sucursal_id, estado, controlada_at, controlada_por)
  VALUES (v_dia - 1, p_adm, p_suc, 'confirmada', now(), p_adm);
  v_res := public.cancelar_pedido_con_stock(v_ped, 'ensayo 1323', p_adm, 'error_de_carga');
  PERFORM pg_temp.er_reset();
  f := pg_temp.er_si(f, pg_temp.er_ok(v_res), format('con la caja del dia anterior dio %s, esperado que pase', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- #1372
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.er_caso_v1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
BEGIN
  f := pg_temp.er_si(f, public._preventista_en_ventana('2026-11-02 09:00-03', '2026-11-02 15:29:59-03'), 'antes del corte');
  f := pg_temp.er_si(f, NOT public._preventista_en_ventana('2026-11-02 09:00-03', '2026-11-02 15:30:00-03'), 'a las 15:30 ya paso');
  f := pg_temp.er_si(f, NOT public._preventista_en_ventana('2026-11-01 09:00-03', '2026-11-02 10:00-03'), 'cargado ayer');
  -- A las 22 de Argentina del dia anterior, en UTC ya es hoy: no es el mismo dia.
  f := pg_temp.er_si(f, NOT public._preventista_en_ventana('2026-11-01 22:00-03', '2026-11-02 09:00-03'), 'cargado a la noche, dia argentino');
  f := pg_temp.er_si(f, NOT public._preventista_en_ventana(NULL, '2026-11-02 10:00-03'), 'sin fecha de carga');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.er_como(p_uid uuid, p_suc bigint)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
END
$fn$;

-- La RPC sobre un pedido asignado con su parada en una ruta en curso. Devuelve el
-- error, o NULL si paso.
CREATE OR REPLACE FUNCTION pg_temp.er_volver(p_ped bigint)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.volver_pedido_a_pendiente_por_edicion(p_ped);
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLERRM;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.er_en_camino(p_cli bigint, p_adm uuid, p_suc bigint, p_duenio uuid, p_tr uuid, p_x bigint)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_ped bigint; v_rec bigint;
BEGIN
  v_ped := pg_temp.er_alta(p_cli, p_adm, jsonb_build_array(pg_temp.er_v(p_x, 1)));
  UPDATE public.pedidos SET usuario_id = p_duenio, transportista_id = p_tr, estado = 'asignado' WHERE id = v_ped;
  INSERT INTO public.recorridos (transportista_id, fecha, estado, sucursal_id)
  VALUES (p_tr, pg_temp.er_hoy() + 500 + (v_ped % 100)::int, 'en_curso', p_suc) RETURNING id INTO v_rec;
  INSERT INTO public.recorrido_pedidos (recorrido_id, pedido_id, sucursal_id, orden_entrega)
  VALUES (v_rec, v_ped, p_suc, 1);
  RETURN v_ped;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.er_paradas(p_ped bigint)
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT count(*) FROM public.recorrido_pedidos rp
    JOIN public.recorridos r ON r.id = rp.recorrido_id
   WHERE rp.pedido_id = p_ped AND r.estado = 'en_curso';
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.er_caso_v2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; x bigint; v_ped bigint; v_prev uuid; v_otro uuid; v_tr uuid; e text;
BEGIN
  -- Tres usuarios de la sucursal: el rol se les pone aca y se revierte con el caso.
  SELECT (a)[1], (a)[2], (a)[3] INTO v_prev, v_otro, v_tr
    FROM (SELECT array_agg(us.usuario_id ORDER BY us.usuario_id) AS a
            FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
           WHERE us.sucursal_id = p_suc AND us.usuario_id <> p_adm) z;
  IF v_tr IS NULL THEN
    RAISE EXCEPTION 'hacen falta tres usuarios activos en la sucursal';
  END IF;
  UPDATE public.perfiles SET rol = 'preventista' WHERE id IN (v_prev, v_otro);
  UPDATE public.perfiles SET rol = 'transportista' WHERE id = v_tr;
  x := pg_temp.er_prod(p_suc, p_adm, 'x', 50, 5);

  -- Con el reloj real: un pedido de ayer no entra, a ninguna hora.
  v_ped := pg_temp.er_en_camino(p_cli, p_adm, p_suc, v_prev, v_tr, x);
  UPDATE public.pedidos SET created_at = created_at - interval '2 days' WHERE id = v_ped;
  PERFORM pg_temp.er_como(v_prev, p_suc);
  e := pg_temp.er_volver(v_ped);
  PERFORM pg_temp.er_como(p_adm, p_suc);
  f := pg_temp.er_si(f, e LIKE '%antes de las 15:30%', format('un pedido de ayer dio %s', COALESCE(e, 'paso')));

  -- El reloj de la ventana lo fija el caso: el ensayo corre a cualquier hora.
  CREATE OR REPLACE FUNCTION public._preventista_en_ventana(p_creado timestamptz, p_ahora timestamptz DEFAULT now())
  RETURNS boolean LANGUAGE sql STABLE AS 'SELECT true';

  -- El dueno, antes del corte.
  v_ped := pg_temp.er_en_camino(p_cli, p_adm, p_suc, v_prev, v_tr, x);
  PERFORM pg_temp.er_como(v_prev, p_suc);
  e := pg_temp.er_volver(v_ped);
  PERFORM pg_temp.er_como(p_adm, p_suc);
  PERFORM pg_temp.er_reset();
  f := pg_temp.er_si(f, e IS NULL, format('el dueno antes del corte dio %s', e));
  f := pg_temp.er_si(f, (SELECT estado = 'pendiente' AND transportista_id IS NULL FROM public.pedidos WHERE id = v_ped),
                     'el dueno: el pedido no quedo pendiente y sin chofer');
  f := pg_temp.er_si(f, pg_temp.er_paradas(v_ped) = 0, 'el dueno: quedo la parada viva');

  -- Ajeno, antes del corte.
  v_ped := pg_temp.er_en_camino(p_cli, p_adm, p_suc, v_prev, v_tr, x);
  PERFORM pg_temp.er_como(v_otro, p_suc);
  e := pg_temp.er_volver(v_ped);
  PERFORM pg_temp.er_como(p_adm, p_suc);
  f := pg_temp.er_si(f, e LIKE '%preventista que cargó%', format('el ajeno dio %s', COALESCE(e, 'paso')));
  f := pg_temp.er_si(f, pg_temp.er_paradas(v_ped) = 1
                        AND (SELECT estado = 'asignado' AND transportista_id = v_tr FROM public.pedidos WHERE id = v_ped),
                     'el rechazo al ajeno cambio el pedido');

  -- El chofer no, aunque sea el suyo.
  PERFORM pg_temp.er_como(v_tr, p_suc);
  e := pg_temp.er_volver(v_ped);
  PERFORM pg_temp.er_como(p_adm, p_suc);
  f := pg_temp.er_si(f, e LIKE '%preventista que cargó%', format('el chofer dio %s', COALESCE(e, 'paso')));

  -- El dueno, pasado el corte.
  CREATE OR REPLACE FUNCTION public._preventista_en_ventana(p_creado timestamptz, p_ahora timestamptz DEFAULT now())
  RETURNS boolean LANGUAGE sql STABLE AS 'SELECT false';
  PERFORM pg_temp.er_como(v_prev, p_suc);
  e := pg_temp.er_volver(v_ped);
  PERFORM pg_temp.er_como(p_adm, p_suc);
  f := pg_temp.er_si(f, e LIKE '%antes de las 15:30%', format('pasado el corte dio %s', COALESCE(e, 'paso')));
  f := pg_temp.er_si(f, pg_temp.er_paradas(v_ped) = 1
                        AND (SELECT estado = 'asignado' FROM public.pedidos WHERE id = v_ped),
                     'el rechazo pasado el corte cambio el pedido');

  -- El admin, con el corte pasado.
  e := pg_temp.er_volver(v_ped);
  PERFORM pg_temp.er_reset();
  f := pg_temp.er_si(f, e IS NULL AND pg_temp.er_paradas(v_ped) = 0
                        AND (SELECT estado = 'pendiente' FROM public.pedidos WHERE id = v_ped),
                     format('el admin dio %s', e));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.er_caso_g1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_fn text;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY['public._regalo_modo_del_pedido(bigint,bigint,bigint)',
                              'public._regalo_barra_vale(bigint,bigint,bigint)',
                              'public.regalo_cantidad_tras_eslabon(numeric,numeric,numeric)',
                              'public._regalo_recorte(bigint,bigint,bigint,numeric,jsonb)',
                              'public._pedido_en_caja_cerrada(bigint,bigint)',
                              'public._contenedores_de_promos(bigint[],bigint)',
                              'public._preventista_en_ventana(timestamptz,timestamptz)',
                              'public._pedido_a_pendiente(bigint,bigint,text)',
                              'public.promo_tipo_reinicia_barra()'] LOOP
    f := pg_temp.er_si(f, NOT has_function_privilege('authenticated', v_fn, 'EXECUTE')
                          AND NOT has_function_privilege('anon', v_fn, 'EXECUTE'),
                       format('%s no es de server', v_fn));
  END LOOP;
  f := pg_temp.er_si(f, has_function_privilege('service_role', 'public.regalo_cantidad_tras_eslabon(numeric,numeric,numeric)', 'EXECUTE'),
                     'el gate de espejo no puede llamar a la conversion');
  f := pg_temp.er_si(f, has_function_privilege('authenticated', 'public.promo_pedidos_abiertos(bigint)', 'EXECUTE')
                        AND NOT has_function_privilege('anon', 'public.promo_pedidos_abiertos(bigint)', 'EXECUTE'),
                     'promo_pedidos_abiertos: permisos');
  f := pg_temp.er_si(f, has_function_privilege('authenticated', 'public.volver_pedido_a_pendiente_por_edicion(bigint)', 'EXECUTE')
                        AND NOT has_function_privilege('anon', 'public.volver_pedido_a_pendiente_por_edicion(bigint)', 'EXECUTE'),
                     'volver_pedido_a_pendiente_por_edicion: permisos');
  f := pg_temp.er_si(f, NOT EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol()),
                     format('SEG-A: %s', (SELECT string_agg(firma || ' · ' || motivo, ' | ') FROM public.auditoria_definer_sin_rol())));
  f := pg_temp.er_si(f, to_regprocedure('public.actualizar_pedido_items(bigint,jsonb,uuid,text)') IS NULL,
                     'quedo la firma vieja de actualizar_pedido_items');
  f := pg_temp.er_si(f, has_function_privilege('authenticated', 'public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamptz)', 'EXECUTE')
                        AND NOT has_function_privilege('anon', 'public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamptz)', 'EXECUTE'),
                     'actualizar_pedido_items: permisos');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

DO $ensayo1323$
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

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  FOREACH v_caso IN ARRAY ARRAY['p2', 'p6', 'p5', 'm1', 'm2', 'm3', 'm4', 'r1', 'r2', 'r3', 'l1', 'c1', 'c2', 'v1', 'v2', 'g1'] LOOP
    v_out := NULL;
    BEGIN
      PERFORM pg_temp.er_reset();
      EXECUTE format('SELECT pg_temp.er_caso_%s($1, $2, $3)', v_caso)
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
$ensayo1323$;
