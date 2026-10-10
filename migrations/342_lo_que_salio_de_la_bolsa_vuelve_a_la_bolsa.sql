-- Lo que salio de la bolsa vuelve a la bolsa (#1085)
--
-- La 338 hizo que _restaurar_lotes_fefo devuelva primero a los lotes de donde
-- salio la linea (su huella en pedido_item_lotes) y que lo que sobre siga por
-- FEFO. Lo que sobra, en una linea con huella, es lo que salio de la BOLSA
-- (unidades sin vencimiento): entraba por FEFO a cualquier lote con hueco, que
-- quedaba +N con unidades de otra fecha, y la bolsa -N. Medido en prod con
-- scripts/test-devolucion-bolsa-1085.sql (caso B1: lote 100 con 50 vivas, otro
-- vacio que vence antes, bolsa 5, pedido 20 = 5 bolsa + 15 lote, salvedad de
-- 18: las 3 de la bolsa terminaban en el lote vacio).
--
-- Decision del dueño (2026-10-10): si la linea (o el pedido, cuando el caller
-- no dice la linea) tiene huella, lo que excede la huella vuelve a la bolsa.
-- Sin ninguna huella -- lineas del bot, pedidos anteriores a la 256, una linea
-- que salio entera de la bolsa, o una devolucion que no es de un pedido -- no
-- hay forma de saber de donde salio y sigue por FEFO, como siempre.
--
-- De paso, el mismo borde por otro lado (caso B2): si el lote de donde salio
-- la linea ya no tiene hueco, la primera pasada ni lo miraba y la huella del
-- cliente no bajaba. Ahora la huella baja igual -- el cliente devolvio esas
-- unidades -- y lo que no entra en el lote va a la bolsa. Es lo mismo que la
-- 338 ya hacia con un lote solo para la traza, que es el caso de hueco 0.
--
-- Dos bordes mas, que encontro la revision adversarial de este cambio:
--   - cancelar_pedido_con_stock y eliminar_pedido_completo devolvian cada
--     linea con la huella del PEDIDO: con dos lineas del mismo producto (la
--     linea y su regalo), la primera se comia la huella de las dos y la
--     segunda caia por FEFO a otro lote (caso B4/B5). Ahora cada linea devuelve
--     con la suya.
--   - anular_salvedad topaba toda la huella a reponer con lo que el lote
--     consumio; la parte que no habia vuelto al lote (caso B2) se perdia.
--     Ahora el tope es solo para lo que volvio al lote.
--
-- Funciones parcheadas en vivo (cada fragmento tiene que aparecer exactamente
-- una vez o la migracion aborta). Firmas, SECURITY DEFINER y GRANTs: como
-- estaban. Ningun camino nuevo toca stock: el trigger sigue siendo el que
-- llama a _restaurar_lotes_fefo, y lo que no se pone en un lote ya es bolsa.

-- ---------------------------------------------------------------------------
-- 1 - _restaurar_lotes_fefo
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pg_temp.parchar(p_def text, p_viejo text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  IF (length(p_def) - length(replace(p_def, p_viejo, ''))) / length(p_viejo) <> 1 THEN
    RAISE EXCEPTION '%: el fragmento no aparece exactamente una vez: revisar a mano', p_que;
  END IF;
  RETURN replace(p_def, p_viejo, p_nuevo);
END
$fn$;

DO $restaurar$
DECLARE
  v_def text := pg_get_functiondef('public._restaurar_lotes_fefo(bigint,bigint,integer)'::regprocedure);
BEGIN
  -- 1a · cuanta huella tiene el caller sobre este producto.
  v_def := pg_temp.parchar(v_def,
$q$  v_huella    integer;
BEGIN
$q$,
$q$  v_huella    integer;
  -- #1085: la huella total del caller (la linea, o el pedido) sobre este
  -- producto. Si hay, lo que la excede salio de la bolsa y vuelve a la bolsa.
  v_huella_total integer;
BEGIN
$q$, '1a');

  v_def := pg_temp.parchar(v_def,
$q$  FOR v_pasada IN 1..2 LOOP
    EXIT WHEN v_pendiente <= 0;
$q$,
$q$  -- #1085: con huella, lo que la excede salio de la bolsa (unidades sin
  -- vencimiento): vuelve a la bolsa, no a un lote por FEFO -- ese lote quedaba
  -- +N con unidades de otra fecha. La segunda pasada queda para lo que no
  -- tiene ninguna huella (bot, pedidos anteriores a la 256, devoluciones que no
  -- son de un pedido), donde no hay forma de saber de donde salio.
  SELECT COALESCE(SUM(pil.cantidad), 0)::integer INTO v_huella_total
    FROM public.pedido_item_lotes pil
    JOIN public.pedido_items pi
      ON pi.id = pil.pedido_item_id AND pi.sucursal_id = pil.sucursal_id
    JOIN public.producto_lotes l
      ON l.id = pil.lote_id AND l.producto_id = p_producto_id
   WHERE pil.sucursal_id = p_sucursal_id
     AND CASE WHEN v_item_id IS NOT NULL
              THEN pil.pedido_item_id = v_item_id
              WHEN v_pedido_id IS NOT NULL
              THEN pi.pedido_id = v_pedido_id AND pi.producto_id = p_producto_id
              ELSE false
         END;

  FOR v_pasada IN 1..2 LOOP
    EXIT WHEN v_pendiente <= 0 OR (v_pasada = 2 AND v_huella_total > 0);
$q$, '1b');

  -- 1c · la primera pasada mira todos los lotes con huella, tengan hueco o no.
  v_def := pg_temp.parchar(v_def,
$q$                  THEN t.huella > 0 AND (l.solo_traza OR l.cantidad_restante < l.cantidad)
$q$,
$q$                  THEN t.huella > 0
$q$, '1c');

  -- 1d · la huella baja por lo que el cliente devolvio de ese lote; las
  -- unidades entran hasta donde haya hueco (un lote solo para la traza no
  -- tiene). Lo que no entra sigue de largo: con huella, a la bolsa.
  v_def := pg_temp.parchar(v_def,
$q$      IF v_pasada = 1 AND r.solo_traza THEN
        v_pone   := 0;
        v_huella := LEAST(v_por_huella, r.huella);
      ELSIF v_pasada = 1 THEN
        v_pone   := LEAST(v_pendiente, r.hueco, r.huella, v_por_huella);
        v_huella := v_pone;
      ELSE
$q$,
$q$      IF v_pasada = 1 THEN
        -- #1085: la huella baja por todo lo que el cliente devolvio de este
        -- lote, entre o no en el lote. Antes un lote sin hueco ni se miraba y
        -- la huella no bajaba.
        v_huella := LEAST(v_por_huella, r.huella);
        v_pone   := CASE WHEN r.solo_traza THEN 0
                         ELSE LEAST(v_pendiente, GREATEST(r.hueco, 0), v_huella) END;
      ELSE
$q$, '1d');

  EXECUTE v_def;
END
$restaurar$;

-- ---------------------------------------------------------------------------
-- 1b - cancelar_pedido_con_stock y eliminar_pedido_completo: cada linea con
--      su huella (lo encontro la revision adversarial)
-- ---------------------------------------------------------------------------
-- Las dos devuelven el stock con un UPDATE por linea, pero con los GUCs del
-- PEDIDO y no los de la linea. Con dos lineas del mismo producto (la linea y
-- su regalo, o dos renglones), la primera devolucion se comia la huella de las
-- dos y la segunda, ya sin huella, caia por FEFO a cualquier lote: el bug de
-- esta migracion por la puerta de atras. Ahora cada UPDATE lleva su linea en
-- app.stock_pedido_item_id, guardado y restaurado (229).

DO $cancelar$
DECLARE
  v_def text := pg_get_functiondef('public.cancelar_pedido_con_stock(bigint,text,uuid,text)'::regprocedure);
BEGIN
  v_def := pg_temp.parchar(v_def,
$q$  IF NOT v_falta_stock THEN
    FOR v_item IN
      SELECT pi.producto_id, pi.cantidad, COALESCE(pi.es_bonificacion, false) AS es_bonificacion,
             pi.promocion_id, COALESCE(pr.regalo_mueve_stock, FALSE) AS regalo_mueve_stock
      FROM pedido_items pi
      LEFT JOIN promociones pr ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
      WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
    LOOP
      IF v_item.es_bonificacion THEN
        IF v_item.regalo_mueve_stock THEN
          UPDATE productos SET stock = stock + v_item.cantidad
          WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
        END IF;
      ELSE
        UPDATE productos SET stock = stock + v_item.cantidad
        WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
      END IF;
    END LOOP;
$q$,
$q$  IF NOT v_falta_stock THEN
    FOR v_item IN
      SELECT pi.id, pi.producto_id, pi.cantidad, COALESCE(pi.es_bonificacion, false) AS es_bonificacion,
             pi.promocion_id, COALESCE(pr.regalo_mueve_stock, FALSE) AS regalo_mueve_stock
      FROM pedido_items pi
      LEFT JOIN promociones pr ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
      WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
    LOOP
      IF NOT v_item.es_bonificacion OR v_item.regalo_mueve_stock THEN
        -- #1085: la devolucion de ESTA linea, con su huella. Con la del pedido,
        -- la primera linea de un producto se comia la huella de las demas y
        -- esas caian por FEFO a cualquier lote. Por transaccion (229).
        DECLARE
          v_item_guc TEXT := current_setting('app.stock_pedido_item_id', true);
        BEGIN
          PERFORM set_config('app.stock_pedido_item_id', v_item.id::text, true);
          UPDATE productos SET stock = stock + v_item.cantidad
          WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
          PERFORM set_config('app.stock_pedido_item_id', COALESCE(v_item_guc, ''), true);
        END;
      END IF;
    END LOOP;
$q$, 'cancelar_pedido_con_stock');
  EXECUTE v_def;
END
$cancelar$;

DO $eliminar$
DECLARE
  v_def text := pg_get_functiondef('public.eliminar_pedido_completo(bigint,uuid,text,boolean)'::regprocedure);
BEGIN
  v_def := pg_temp.parchar(v_def,
$q$      SELECT pi.producto_id, pi.cantidad, COALESCE(pi.es_bonificacion, false) AS es_bonificacion,
             pi.promocion_id, COALESCE(pr.regalo_mueve_stock, FALSE) AS regalo_mueve_stock
      FROM pedido_items pi
      LEFT JOIN promociones pr ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
      WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
    LOOP
      IF NOT v_item.es_bonificacion OR v_item.regalo_mueve_stock THEN
        UPDATE productos SET stock = stock + v_item.cantidad WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
      END IF;
$q$,
$q$      SELECT pi.id, pi.producto_id, pi.cantidad, COALESCE(pi.es_bonificacion, false) AS es_bonificacion,
             pi.promocion_id, COALESCE(pr.regalo_mueve_stock, FALSE) AS regalo_mueve_stock
      FROM pedido_items pi
      LEFT JOIN promociones pr ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
      WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
    LOOP
      IF NOT v_item.es_bonificacion OR v_item.regalo_mueve_stock THEN
        -- #1085: la devolucion de ESTA linea, con su huella (ver
        -- cancelar_pedido_con_stock). Por transaccion (229).
        DECLARE
          v_item_guc TEXT := current_setting('app.stock_pedido_item_id', true);
        BEGIN
          PERFORM set_config('app.stock_pedido_item_id', v_item.id::text, true);
          UPDATE productos SET stock = stock + v_item.cantidad WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
          PERFORM set_config('app.stock_pedido_item_id', COALESCE(v_item_guc, ''), true);
        END;
      END IF;
$q$, 'eliminar_pedido_completo');
  EXECUTE v_def;
END
$eliminar$;

-- ---------------------------------------------------------------------------
-- 1c - anular_salvedad: el tope de la huella es para lo que volvio al lote
-- ---------------------------------------------------------------------------
-- La huella que anular le repone al cliente en un lote se topa con lo que ese
-- lote consumio, para no inventar mas huella que consumo. Pero con esta
-- migracion parte de la huella que perdio el cliente puede no haber vuelto al
-- lote (el lote no tenia hueco, o es solo para la traza): esa parte no paso
-- por el contador del lote, el tope no tiene nada que decir sobre ella, y
-- topandola se perdia (lo encontro la revision adversarial: caso B2).

DO $anular$
DECLARE
  v_def text := pg_get_functiondef('public.anular_salvedad(bigint,text)'::regprocedure);
BEGIN
  v_def := pg_temp.parchar(v_def,
$q$      -- Tope: la huella de un lote no pasa lo que ese lote consumio.
      v_huella := LEAST(
        r_lote.huella,
        (r_lote.cantidad - (r_lote.cantidad_restante - v_saca))
          - (SELECT COALESCE(SUM(cantidad), 0)::int FROM pedido_item_lotes WHERE lote_id = r_lote.id));
$q$,
$q$      -- Tope: la huella de lo que volvio a este lote no pasa lo que el lote
      -- consumio. #1085: la que el cliente perdio sin que las unidades
      -- entraran al lote (sin hueco, o solo para la traza: fueron a la bolsa)
      -- no paso por su contador, y se repone entera.
      v_huella := GREATEST(LEAST(
        LEAST(r_lote.huella, r_lote.devuelto),
        (r_lote.cantidad - (r_lote.cantidad_restante - v_saca))
          - (SELECT COALESCE(SUM(cantidad), 0)::int FROM pedido_item_lotes WHERE lote_id = r_lote.id)), 0)
        + GREATEST(r_lote.huella - r_lote.devuelto, 0);
$q$, 'anular_salvedad');
  EXECUTE v_def;
END
$anular$;

DROP FUNCTION pg_temp.parchar(text, text, text, text);

-- ---------------------------------------------------------------------------
-- 2 - Verificacion estructural
-- ---------------------------------------------------------------------------

DO $verif$
DECLARE
  v_res text := pg_get_functiondef('public._restaurar_lotes_fefo(bigint,bigint,integer)'::regprocedure);
BEGIN
  IF v_res NOT LIKE '%SECURITY DEFINER%'
     OR v_res NOT LIKE '%EXIT WHEN v_pendiente <= 0 OR (v_pasada = 2 AND v_huella_total > 0);%'
     OR v_res NOT LIKE '%NOT l.solo_traza%' THEN
    RAISE EXCEPTION '_restaurar_lotes_fefo no quedo como se esperaba';
  END IF;
  IF pg_get_functiondef('public.cancelar_pedido_con_stock(bigint,text,uuid,text)'::regprocedure)
       NOT LIKE '%set_config(''app.stock_pedido_item_id'', v_item.id::text, true)%'
     OR pg_get_functiondef('public.eliminar_pedido_completo(bigint,uuid,text,boolean)'::regprocedure)
       NOT LIKE '%set_config(''app.stock_pedido_item_id'', v_item.id::text, true)%'
     OR pg_get_functiondef('public.anular_salvedad(bigint,text)'::regprocedure)
       NOT LIKE '%GREATEST(r_lote.huella - r_lote.devuelto, 0)%' THEN
    RAISE EXCEPTION 'cancelar / eliminar / anular no quedaron como se esperaba';
  END IF;
  IF has_function_privilege('anon', 'public._restaurar_lotes_fefo(bigint,bigint,integer)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._restaurar_lotes_fefo(bigint,bigint,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'los permisos de _restaurar_lotes_fefo cambiaron';
  END IF;
END
$verif$;

-- ---------------------------------------------------------------------------
-- 3 - Ensayo con datos reales: los casos de
--     scripts/test-devolucion-bolsa-1085.sql (ver ahi cada uno). La corrida de
--     aca solo aborta si algo falla.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pg_temp.t_hoy()
RETURNS date LANGUAGE sql AS $fn$
  SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

-- Un lote como {dias, cant, rest}; NULL si ya no existe.
CREATE OR REPLACE FUNCTION pg_temp.t_lote(p_id bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('dias', l.fecha_vencimiento - pg_temp.t_hoy(),
                            'cant', l.cantidad, 'rest', l.cantidad_restante)
    FROM public.producto_lotes l WHERE l.id = p_id;
$fn$;

-- El lote quedo solo para la traza (mig 338). Sin la columna, false.
CREATE OR REPLACE FUNCTION pg_temp.t_solo(p_id bigint)
RETURNS boolean LANGUAGE plpgsql AS $fn$
DECLARE
  v boolean;
BEGIN
  EXECUTE 'SELECT solo_traza FROM public.producto_lotes WHERE id = $1' INTO v USING p_id;
  RETURN COALESCE(v, false);
EXCEPTION WHEN undefined_column THEN
  RETURN false;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_foto(p_prod bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object(
    'stock', pr.stock,
    'lotes', COALESCE((SELECT jsonb_agg(l.cantidad_restante ORDER BY l.fecha_vencimiento, l.id)
                         FROM public.producto_lotes l WHERE l.producto_id = pr.id), '[]'::jsonb),
    'bolsa', pr.stock - COALESCE((SELECT SUM(l.cantidad_restante)
                                    FROM public.producto_lotes l WHERE l.producto_id = pr.id), 0)::int)
    FROM public.productos pr WHERE pr.id = p_prod;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_huella(p_item bigint, p_lote bigint)
RETURNS int LANGUAGE sql AS $fn$
  SELECT COALESCE(SUM(cantidad), 0)::int FROM public.pedido_item_lotes
   WHERE pedido_item_id = p_item AND lote_id = p_lote;
$fn$;

-- pedido_item_lotes de las lineas de un producto: [{item, lote, cant}].
CREATE OR REPLACE FUNCTION pg_temp.t_huella_tabla(p_prod bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('item', pil.pedido_item_id, 'lote', pil.lote_id,
                                               'cant', pil.cantidad)
                            ORDER BY pil.pedido_item_id, pil.lote_id), '[]'::jsonb)
    FROM public.pedido_item_lotes pil
    JOIN public.pedido_items pi ON pi.id = pil.pedido_item_id
   WHERE pi.producto_id = p_prod;
$fn$;

-- Producto con lotes de una compra ([{dias, cantidad, restante}]) y `p_bolsa`
-- unidades sin lote. Devuelve {prod, compra, lotes: [ids en el orden dado]}.
CREATE OR REPLACE FUNCTION pg_temp.t_prod(p_suc bigint, p_admin uuid, p_lotes jsonb, p_bolsa int)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod   bigint;
  v_compra bigint;
  v_id     bigint;
  v_ids    jsonb := '[]'::jsonb;
  l        jsonb;
BEGIN
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1085', 100,
          p_bolsa + (SELECT COALESCE(SUM((x->>'restante')::int), 0) FROM jsonb_array_elements(p_lotes) x),
          60, p_suc)
  RETURNING id INTO v_prod;

  INSERT INTO public.compras (sucursal_id, estado, usuario_id)
  VALUES (p_suc, 'recibida', p_admin) RETURNING id INTO v_compra;

  FOR l IN SELECT * FROM jsonb_array_elements(p_lotes) LOOP
    INSERT INTO public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad,
                                       cantidad_restante, usuario_id, compra_id)
    VALUES (v_prod, p_suc, pg_temp.t_hoy() + (l->>'dias')::int, (l->>'cantidad')::int,
            (l->>'restante')::int, p_admin, v_compra)
    RETURNING id INTO v_id;
    v_ids := v_ids || to_jsonb(v_id);
  END LOOP;

  RETURN jsonb_build_object('prod', v_prod, 'compra', v_compra, 'lotes', v_ids);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_pedido(p_cli bigint, p_admin uuid, p_prod bigint, p_cant int)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
  v_ped bigint;
BEGIN
  v_res := public.crear_pedido_completo(
    p_cli, p_cant * 100, p_admin,
    jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 100)),
    'ensayo 1085');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  v_ped := (v_res->>'pedido_id')::bigint;
  RETURN jsonb_build_object('pedido', v_ped,
    'item', (SELECT id FROM public.pedido_items WHERE pedido_id = v_ped AND producto_id = p_prod));
END
$fn$;

-- La edicion de la compra, como la manda la app: la foto completa de los
-- vencimientos de la factura ([{dias, cantidad}] de un solo producto).
CREATE OR REPLACE FUNCTION pg_temp.t_editar(p_compra bigint, p_prod bigint, p_lotes jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.sincronizar_lotes_compra(p_compra, COALESCE((
    SELECT jsonb_agg(jsonb_build_object('producto_id', p_prod,
                                        'fecha_vencimiento', pg_temp.t_hoy() + (x->>'dias')::int,
                                        'cantidad', (x->>'cantidad')::int))
      FROM jsonb_array_elements(p_lotes) x), '[]'::jsonb));
  IF NOT COALESCE((v_res->>'ok')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo editar la compra: %', v_res;
  END IF;
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_salvedad(p_ped bigint, p_item bigint, p_cant int, p_motivo text)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.registrar_salvedad(p_ped, p_item, p_cant, p_motivo,
                                     'ensayo 1085: descripcion del caso', NULL, true, NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'registrar %: %', p_motivo, v_res;
  END IF;
  RETURN (v_res->>'salvedad_id')::bigint;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_anular(p_salv bigint)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.anular_salvedad(p_salv, 'ensayo 1085');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'anular: %', v_res;
  END IF;
END
$fn$;

-- Suma unidades a la bolsa con un origen fuera de la lista blanca (no van a
-- ningun lote). Sirve para que la bolsa no quede en 0 despues de un pedido que
-- llego a los lotes: con bolsa 0 la bajada cae en el lote por FEFO y da bien
-- por casualidad.
CREATE OR REPLACE FUNCTION pg_temp.t_a_la_bolsa(p_prod bigint, p_n int)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', 'ensayo_1054', true);
  UPDATE public.productos SET stock = stock + p_n WHERE id = p_prod;
  PERFORM set_config('app.stock_origen', '', true);
END
$fn$;

-- ---------------------------------------------------------------------------
-- Casos
-- ---------------------------------------------------------------------------

-- B1 · salvedad. L2 vence a 30 dias y esta vacio (50, 0 vivas); L1 vence a
--      90 (100, 50 vivas). Bolsa 5. Pedido 20: 5 de la bolsa y 15 de L1
--      (huella 15). Se suman 20 a la bolsa. Salvedad de 18: 15 vuelven a L1 y
--      las 3 que salieron de la bolsa vuelven a la bolsa, no a L2. Anular deja
--      todo como despues del pedido.
CREATE OR REPLACE FUNCTION pg_temp.caso_b1(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l2 bigint; v_l1 bigint; p jsonb; v_ped bigint; v_item bigint; v_salv bigint;
  f text[] := '{}'; v_f0 jsonb; v_f1 jsonb; v_f2 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 5);
  v_prod := v->>'prod'; v_l2 := v->'lotes'->>0; v_l1 := v->'lotes'->>1;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_ped := p->>'pedido'; v_item := p->>'item';
  PERFORM pg_temp.t_a_la_bolsa(v_prod, 20);
  v_f0 := pg_temp.t_foto(v_prod);
  IF pg_temp.t_huella(v_item, v_l1) <> 15 OR v_f0 <> '{"stock":55,"lotes":[0,35],"bolsa":20}' THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', v_f0)));
  END IF;

  v_salv := pg_temp.t_salvedad(v_ped, v_item, 18, 'cliente_rechaza');
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = '{"stock":73,"lotes":[0,50],"bolsa":23}',
                    format('la devolucion dejo %s, esperado {stock 73, lotes [0,50], bolsa 23}: las 3 de la bolsa vuelven a la bolsa', v_f1));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 0,
                    format('la huella en L1 quedo %s, esperado 0', pg_temp.t_huella(v_item, v_l1)));

  PERFORM pg_temp.t_anular(v_salv);
  v_f2 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f2 = v_f0, format('anular dejo %s; despues del pedido era %s', v_f2, v_f0));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 15,
                    format('despues de anular la huella en L1 quedo %s, esperado 15', pg_temp.t_huella(v_item, v_l1)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s / %s', v_f0, v_f1, v_f2));
END
$fn$;

-- B2 · el lote de donde salio la linea ya no tiene hueco. Como B1 hasta el
--      pedido (huella 15 en L1); despues L1 se vuelve a llenar (100/100) con
--      unidades de la bolsa. Salvedad de 10: no entran en L1, van a la bolsa
--      (no a L2), y la huella del cliente en L1 baja igual a 5.
CREATE OR REPLACE FUNCTION pg_temp.caso_b2(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l2 bigint; v_l1 bigint; p jsonb; v_ped bigint; v_item bigint; v_salv bigint;
  f text[] := '{}'; v_f0 jsonb; v_f1 jsonb; v_f2 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 5);
  v_prod := v->>'prod'; v_l2 := v->'lotes'->>0; v_l1 := v->'lotes'->>1;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_ped := p->>'pedido'; v_item := p->>'item';
  PERFORM pg_temp.t_a_la_bolsa(v_prod, 65);
  UPDATE public.producto_lotes SET cantidad_restante = cantidad WHERE id = v_l1;
  v_f0 := pg_temp.t_foto(v_prod);
  IF pg_temp.t_huella(v_item, v_l1) <> 15 OR v_f0 <> '{"stock":100,"lotes":[0,100],"bolsa":0}' THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', v_f0)));
  END IF;

  v_salv := pg_temp.t_salvedad(v_ped, v_item, 10, 'cliente_rechaza');
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = '{"stock":110,"lotes":[0,100],"bolsa":10}',
                    format('la devolucion dejo %s, esperado {stock 110, lotes [0,100], bolsa 10}', v_f1));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 5,
                    format('la huella en L1 quedo %s, esperado 5 (el cliente devolvio 10)', pg_temp.t_huella(v_item, v_l1)));

  -- Anular: lo que no entro en L1 no paso por su contador, asi que su huella
  -- vuelve entera (el tope "no mas que lo que el lote consumio" es para lo que
  -- volvio al lote).
  PERFORM pg_temp.t_anular(v_salv);
  v_f2 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f2 = v_f0, format('anular dejo %s; antes de la salvedad era %s', v_f2, v_f0));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 15,
                    format('despues de anular la huella en L1 quedo %s, esperado 15', pg_temp.t_huella(v_item, v_l1)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s / %s', v_f0, v_f1, v_f2));
END
$fn$;

-- B3 · cancelar el pedido entero (el caso S4b de la 338): las 15 de L1
--      vuelven a L1 y las 5 que salieron de la bolsa, a la bolsa.
CREATE OR REPLACE FUNCTION pg_temp.caso_b3(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l2 bigint; v_l1 bigint; p jsonb; v_ped bigint; v_item bigint; v_res jsonb;
  f text[] := '{}'; v_f1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 5);
  v_prod := v->>'prod'; v_l2 := v->'lotes'->>0; v_l1 := v->'lotes'->>1;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_ped := p->>'pedido'; v_item := p->>'item';
  PERFORM pg_temp.t_a_la_bolsa(v_prod, 20);

  v_res := public.cancelar_pedido_con_stock(v_ped, 'ensayo 1085', p_adm, NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'cancelar: %', v_res;
  END IF;
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = '{"stock":75,"lotes":[0,50],"bolsa":25}',
                    format('cancelar dejo %s, esperado {stock 75, lotes [0,50], bolsa 25}', v_f1));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 0,
                    format('el pedido cancelado sigue con huella %s en L1', pg_temp.t_huella(v_item, v_l1)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('foto %s', v_f1));
END
$fn$;

-- Arma el pedido de B4/B5: L0 vence a 30 dias y esta vacio (50, 0 vivas), L1
-- vence a 90 (100, 50 vivas), bolsa 5. Linea X de 20 (5 de la bolsa, 15 de L1:
-- huella 15) y regalo R de 4 del MISMO producto con una promo que mueve stock
-- (de L1: huella 4). Despues se suman 20 a la bolsa. Devuelve
-- {prod, pedido, l0, l1, x, r}.
CREATE OR REPLACE FUNCTION pg_temp.t_pedido_con_regalo(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; p jsonb; v_ped bigint; v_promo bigint; v_regalo bigint;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 5);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_ped := p->>'pedido';

  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id)
  VALUES ('ZZ ensayo 1085', 'bonificacion', CURRENT_DATE, p_suc, true, v_prod) RETURNING id INTO v_promo;
  INSERT INTO public.pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal,
                                   sucursal_id, es_bonificacion, promocion_id)
  VALUES (v_ped, v_prod, 4, 0, 0, p_suc, true, v_promo) RETURNING id INTO v_regalo;
  PERFORM set_config('app.stock_origen', 'pedido_creado', true);
  PERFORM set_config('app.stock_ref_tipo', 'pedido', true);
  PERFORM set_config('app.stock_ref_id', v_ped::text, true);
  PERFORM set_config('app.stock_pedido_item_id', v_regalo::text, true);
  UPDATE public.productos SET stock = stock - 4 WHERE id = v_prod;
  PERFORM set_config('app.stock_pedido_item_id', '', true);
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);

  PERFORM pg_temp.t_a_la_bolsa(v_prod, 20);
  RETURN jsonb_build_object('prod', v_prod, 'pedido', v_ped, 'l0', v->'lotes'->0, 'l1', v->'lotes'->1,
                            'x', p->'item', 'r', v_regalo);
END
$fn$;

-- B4 · cancelar un pedido con dos lineas del mismo producto (la linea y su
--      regalo). Cada linea devuelve con su propia huella: X pone 15 en L1 y 5
--      en la bolsa, R pone 4 en L1. Antes la primera devolucion (a nivel
--      pedido) se comia la huella de las dos y la segunda caia por FEFO en L0.
CREATE OR REPLACE FUNCTION pg_temp.caso_b4(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  d jsonb; v_res jsonb; f text[] := '{}'; v_f0 jsonb; v_f1 jsonb;
BEGIN
  d := pg_temp.t_pedido_con_regalo(p_cli, p_adm, p_suc);
  v_f0 := pg_temp.t_foto((d->>'prod')::bigint);
  IF v_f0 <> '{"stock":51,"lotes":[0,31],"bolsa":20}'
     OR pg_temp.t_huella((d->>'x')::bigint, (d->>'l1')::bigint) <> 15
     OR pg_temp.t_huella((d->>'r')::bigint, (d->>'l1')::bigint) <> 4 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', v_f0)));
  END IF;

  v_res := public.cancelar_pedido_con_stock((d->>'pedido')::bigint, 'ensayo 1085', p_adm, NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'cancelar: %', v_res;
  END IF;
  v_f1 := pg_temp.t_foto((d->>'prod')::bigint);
  f := pg_temp.t_si(f, v_f1 = '{"stock":75,"lotes":[0,50],"bolsa":25}',
                    format('cancelar dejo %s, esperado {stock 75, lotes [0,50], bolsa 25}', v_f1));
  f := pg_temp.t_si(f, pg_temp.t_huella((d->>'x')::bigint, (d->>'l1')::bigint) = 0
                       AND pg_temp.t_huella((d->>'r')::bigint, (d->>'l1')::bigint) = 0,
                    'el pedido cancelado sigue con huella');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s', v_f0, v_f1));
END
$fn$;

-- B5 · lo mismo, eliminando el pedido con restauracion de stock.
CREATE OR REPLACE FUNCTION pg_temp.caso_b5(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  d jsonb; v_res jsonb; f text[] := '{}'; v_f1 jsonb;
BEGIN
  d := pg_temp.t_pedido_con_regalo(p_cli, p_adm, p_suc);
  v_res := public.eliminar_pedido_completo((d->>'pedido')::bigint, p_adm, 'ensayo 1085', true);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'eliminar: %', v_res;
  END IF;
  v_f1 := pg_temp.t_foto((d->>'prod')::bigint);
  f := pg_temp.t_si(f, v_f1 = '{"stock":75,"lotes":[0,50],"bolsa":25}',
                    format('eliminar dejo %s, esperado {stock 75, lotes [0,50], bolsa 25}', v_f1));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('foto %s', v_f1));
END
$fn$;

-- U1 · sin huella no hay forma de saber de donde salio: sigue por FEFO. Una
--      linea que salio entera de la bolsa (lote 100 con 50 vivas, bolsa 40,
--      pedido 20): la salvedad de 10 entra al lote, como siempre.
CREATE OR REPLACE FUNCTION pg_temp.caso_u1(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; p jsonb; f text[] := '{}'; v_f1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  PERFORM pg_temp.t_salvedad((p->>'pedido')::bigint, (p->>'item')::bigint, 10, 'cliente_rechaza');
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = '{"stock":80,"lotes":[60],"bolsa":20}',
                    format('sin huella la devolucion dejo %s, esperado {stock 80, lotes [60], bolsa 20} (FEFO)', v_f1));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('foto %s', v_f1));
END
$fn$;

-- U2 · una devolucion que no es de un pedido (sin linea ni pedido en los GUCs,
--      con un origen de la lista blanca) sigue por FEFO.
CREATE OR REPLACE FUNCTION pg_temp.caso_u2(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; f text[] := '{}'; v_f1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod';
  PERFORM set_config('app.stock_origen', 'movimiento_cancelado', true);
  PERFORM set_config('app.stock_ref_tipo', 'movimiento', true);
  PERFORM set_config('app.stock_ref_id', '1', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
  UPDATE public.productos SET stock = stock + 10 WHERE id = v_prod;
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = '{"stock":100,"lotes":[60],"bolsa":40}',
                    format('la devolucion sin pedido dejo %s, esperado {stock 100, lotes [60], bolsa 40} (FEFO)', v_f1));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('foto %s', v_f1));
END
$fn$;

DO $ensayo1085$
DECLARE
  v_admin   uuid;
  v_suc     bigint;
  v_otra    bigint;
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
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'ens1085 · el ensayo necesita un admin activo con una sucursal activa';
  END IF;
  SELECT id INTO v_otra FROM sucursales WHERE id <> v_suc ORDER BY id LIMIT 1;
  SELECT id INTO v_cliente FROM clientes WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;
  IF v_cliente IS NULL OR v_otra IS NULL THEN
    RAISE EXCEPTION 'ens1085 · el ensayo necesita un cliente activo en la sucursal % y otra sucursal', v_suc;
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  -- Cada caso corre en un subbloque que termina en una excepcion atrapada,
  -- asi que no deja nada; si alguno falla, la migracion entera aborta.
  FOREACH v_caso IN ARRAY ARRAY['b1', 'b2', 'b3', 'b4', 'b5', 'u1', 'u2'] LOOP
    v_out := NULL;
    BEGIN
      EXECUTE format('SELECT pg_temp.caso_%s($1, $2, $3, $4)', v_caso)
        INTO v_out USING v_cliente, v_admin, v_suc, v_otra;
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

  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.headers', '', true);
  PERFORM set_config('app.omitir_minimo_pedido', '', true);

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ens1085 · el ensayo fallo (% fallas), la migracion no se aplica:\n- %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
END
$ensayo1085$;

-- Las auxiliares del ensayo no se quedan en la sesion.
DO $limpieza$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS f
      FROM pg_proc p
     WHERE p.pronamespace = pg_my_temp_schema()
       AND (p.proname LIKE 't\_%' OR p.proname LIKE 'caso\_%')
  LOOP
    EXECUTE 'DROP FUNCTION ' || r.f::text;
  END LOOP;
END
$limpieza$;
