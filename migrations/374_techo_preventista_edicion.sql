-- El preventista deja de tener regla propia de precio al editar (#1169). El
-- techo y el piso los pone precio_fuera_de_politica, como al encargado.
--
--   * actualizar_pedido_items tenia, dentro del bloque del preventista, un
--     loop que rechazaba toda linea por encima de productos.precio de HOY
--     ('Como preventista no puede aumentar precios (producto ID N)'), sin la
--     ventana del precio anterior, sin la tolerancia de 0,01 y sin conservar
--     el maximo guardado de la linea. Corria antes que la guarda de la
--     politica (#1139/#1159), asi que el preventista que editaba un pedido con
--     una linea sobre la lista de hoy (porque la lista bajo despues de
--     cargarlo, o porque la puso el admin) quedaba bloqueado aunque no tocara
--     esa linea y aunque el techo la aceptara. Al encargado esa misma edicion
--     le pasaba.
--   * Decision del dueno (2026-10-14, opcion A): se saca solo ese loop. Quedan
--     el chequeo de creador y el de horario (en ese orden, los dos antes de la
--     politica). Una sola regla y un solo mensaje, terminado en ' El pedido no
--     se modifico.'. Lo demas que el loop cubria ya lo cubren otros: el precio
--     NULL o <= 0 y el producto sin lista, trg_validar_precio_item_pedido; el
--     producto inexistente, el chequeo de stock; y precio_unitario es NOT NULL.
--
-- Medicion en prod (90 dias, solo lecturas): 97 ediciones de preventista,
-- ninguna bloqueada en la practica. El unico pedido abierto sobre la lista de
-- hoy (8334) lo frena antes la guarda de fecha. El riesgo aparecia solo con una
-- baja de lista el mismo dia (2 casos en 90 dias) o un precio puesto por el
-- admin. Sin backfill. Sin front: se aplica cuando sea (el front no conoce el
-- mensaje viejo y los dos son terminales para rechazoDeNegocio.ts).
--
-- Parche por ancla sobre la definicion viva, escrita contra el md5
-- f2bbf842ab9ba8711d46b847aa853aca de pg_get_functiondef de prod (2026-10-14).
-- Cada fragmento tiene que aparecer exactamente una vez o la migracion aborta.
-- CREATE OR REPLACE conserva el ACL; el REVOKE va igual y el $verif$ lo vigila.
-- No cambian firma, parametros, GUCs de stock, escrituras ni triggers: PRECIO-A
-- (sigue llamando a precio_fuera_de_politica), COSTO-D, STK-F y STK-D no se
-- mueven.
--
-- Ensayo: scripts/test-politica-precios-1157-1159.sql (T7 y T7-E) y
-- scripts/test-precio-servidor-1138-1139.sql (sin cambios, tiene que seguir OK).

CREATE OR REPLACE FUNCTION pg_temp.rr_parchar(p_def text, p_viejo text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  IF (length(p_def) - length(replace(p_def, p_viejo, ''))) / length(p_viejo) <> 1 THEN
    RAISE EXCEPTION '%: el fragmento no aparece exactamente una vez: revisar a mano', p_que;
  END IF;
  RETURN replace(p_def, p_viejo, p_nuevo);
END
$fn$;

DO $apit$
DECLARE
  v_def text := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure);
BEGIN
  -- (1) El loop de precio del preventista.
  v_def := pg_temp.rr_parchar(v_def,
$q$    FOR v_item_nuevo IN SELECT * FROM jsonb_array_elements(v_items) LOOP
      IF COALESCE((v_item_nuevo->>'es_bonificacion')::BOOLEAN, false) = true THEN
        CONTINUE;
      END IF;
      v_producto_id := (v_item_nuevo->>'producto_id')::INT;
      v_precio_unitario := (v_item_nuevo->>'precio_unitario')::DECIMAL;
      SELECT precio INTO v_precio_actual
        FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal;
      IF v_precio_actual IS NULL THEN
        RETURN jsonb_build_object('success', false, 'errores',
          ARRAY['Producto ID ' || v_producto_id || ' no encontrado']);
      END IF;
      IF v_precio_unitario IS NULL OR v_precio_unitario > v_precio_actual THEN
        RETURN jsonb_build_object('success', false, 'errores',
          ARRAY['Como preventista no puede aumentar precios (producto ID ' || v_producto_id || ')']);
      END IF;
    END LOOP;
  END IF;

  -- mig #1138: el regalo va a precio 0$q$,
$q$    -- #1169: el preventista ya no tiene regla propia de precio. El techo
    -- (lista, anterior que califica y maximo guardado) y el piso los pone
    -- precio_fuera_de_politica mas abajo, como al encargado. Un producto
    -- inexistente lo rechaza el chequeo de stock; sin lista o a precio 0,
    -- trg_validar_precio_item_pedido.
  END IF;

  -- mig #1138: el regalo va a precio 0$q$, 'actualizar_pedido_items loop de precio del preventista');

  -- (2) La declaracion que quedo sin uso. v_hora_corte la sigue usando el
  -- chequeo horario; v_precio_unitario se sigue usando mas abajo.
  v_def := pg_temp.rr_parchar(v_def,
$q$  v_hora_corte CONSTANT TIME := TIME '15:30';
  v_precio_actual DECIMAL;
$q$,
$q$  v_hora_corte CONSTANT TIME := TIME '15:30';
$q$, 'actualizar_pedido_items declaracion de v_precio_actual');

  -- (3) El comentario de la guarda de la politica, que nombraba al techo viejo.
  v_def := pg_temp.rr_parchar(v_def,
$q$  -- lista, tambien al editar (incluye al encargado; el techo del preventista
  -- de arriba queda igual). Con p_pedido_id:$q$,
$q$  -- lista ni sube del techo, tambien al editar (incluye al encargado y, desde
  -- #1169, al preventista, que ya no tiene regla propia). Con p_pedido_id:$q$,
    'actualizar_pedido_items comentario de la guarda');

  EXECUTE v_def;
END
$apit$;

-- RPC del front: authenticated se queda.
REVOKE EXECUTE ON FUNCTION public.actualizar_pedido_items(bigint, jsonb, uuid) FROM PUBLIC, anon;

-- ---------------------------------------------------------------------------
-- Verificacion estructural
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  f_api text := 'public.actualizar_pedido_items(bigint,jsonb,uuid)';
  v_def text := pg_get_functiondef(f_api::regprocedure);
  v_pos_cre int := position('Solo el preventista que creo el pedido puede editarlo' IN v_def);
  v_pos_hor int := position('antes de las 15:30 (ARG)' IN v_def);
  v_pos_pfp int := position('public.precio_fuera_de_politica(' IN v_def);
BEGIN
  IF has_function_privilege('anon', f_api::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'actualizar_pedido_items quedo alcanzable por anon';
  END IF;
  IF NOT has_function_privilege('authenticated', f_api::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'actualizar_pedido_items perdio EXECUTE para authenticated';
  END IF;

  -- Una sola sobrecarga (PGRST203).
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
         AND proname = 'actualizar_pedido_items') <> 1 THEN
    RAISE EXCEPTION 'hay mas de una sobrecarga de actualizar_pedido_items';
  END IF;

  IF v_def NOT LIKE '%SECURITY DEFINER%' OR position('SET search_path TO ''public''' IN v_def) = 0 THEN
    RAISE EXCEPTION 'actualizar_pedido_items perdio SECURITY DEFINER o el search_path';
  END IF;

  IF position('no puede aumentar precios' IN v_def) > 0 OR position('v_precio_actual' IN v_def) > 0 THEN
    RAISE EXCEPTION 'actualizar_pedido_items conserva la regla propia de precio del preventista';
  END IF;

  -- Creador antes que horario, los dos antes de la politica.
  IF v_pos_cre = 0 OR v_pos_hor = 0 OR v_pos_pfp = 0
     OR v_pos_cre >= v_pos_hor OR v_pos_hor >= v_pos_pfp THEN
    RAISE EXCEPTION 'actualizar_pedido_items: falta el chequeo de creador u horario, o cambio el orden (% / % / %)',
      v_pos_cre, v_pos_hor, v_pos_pfp;
  END IF;
  -- La politica sigue para todo no-admin.
  IF position('IF v_user_role <> ''admin'' THEN' IN substr(v_def, greatest(v_pos_pfp - 300, 1), 300)) = 0 THEN
    RAISE EXCEPTION 'actualizar_pedido_items: precio_fuera_de_politica ya no esta bajo IF v_user_role <> admin';
  END IF;
  IF position('mig #1138: el regalo va a precio 0' IN v_def) = 0 THEN
    RAISE EXCEPTION 'actualizar_pedido_items perdio la guarda del regalo a precio 0';
  END IF;
END
$verif$;
