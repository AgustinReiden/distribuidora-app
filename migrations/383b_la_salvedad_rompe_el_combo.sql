-- =========================================================================
-- 383b · LA SALVEDAD DECIDE POR EL MOTIVO SI EL COMBO SE ROMPE (#1192, entrega
-- 2 de 4 del diseño #1190)
--
-- LA REGLA (decision del dueño, 2026-10-15)
--   Cuando el cliente rechaza una parte de un combo, lo que se queda depende
--   del motivo de la salvedad:
--     - motivos nuestros (faltante_stock, producto_danado, producto_vencido,
--       error_pedido, entregado_otro_cliente) y los dudosos (diferencia_precio,
--       otro): lo que se queda mantiene el precio combo;
--     - cliente_rechaza: el combo se rompe y lo que se queda vuelve a su precio
--       sin combo, el de la foto del pedido (pedido_combos.precios), no la
--       lista de hoy.
--   Combos que sobreviven, por pedido y por combo: el minimo entre lugares de
--   floor((cantidad armada - rechazado por el cliente) / requerida). Lo que se
--   rechaza por un motivo nuestro no le resta combos a nadie.
--
-- EXCEPCION A LAS MIGS 165-168 ("rechazar mercaderia solo baja lo que se paga")
--   Si romper el combo sube el total, SUBE, sin tope. Decision del dueño: "si el
--   cliente rechaza algo y el precio aumenta, es problema de el". Si la boleta
--   ya estaba cobrada, la diferencia queda como deuda: el total se recalcula UNA
--   vez al final de la salvedad (rechazo + recargo, neto), asi que
--   desafectar_sobrepago_pedido solo actua si lo neto baja de lo pagado. La
--   regla de 165-168 sigue rigiendo todo lo demas.
--
-- DOS MOVIMIENTOS, UNA SALVEDAD
--   - salvedades_items.monto_afectado: lo que el cliente no se llevo, positivo,
--     al precio de la linea (el de combo si estaba en el combo), como siempre.
--   - salvedades_items.recargo_combo: lo que el total subio (o bajo) por
--     rehacer el combo, atado a la misma fila. combo_detalle dice cuantos combos
--     habia y cuantos quedaron, y que productos salieron o volvieron. anular
--     rehace el combo sin la salvedad y anota lo suyo en combo_detalle.anulacion.
--
-- EL MODELO
--   Las unidades de un producto en un combo de un pedido son un POZO de hasta
--   dos lineas: la del combo (combo_id, precio de combo) y la que salio del
--   combo roto (combo_roto_id, precio sin combo). Rehacer el combo
--   (_combo_rehacer) es una funcion del estado, no de la historia:
--     cantidad armada  -> pedido_combos.cantidad_combos_armados (alta/edicion)
--     rechazos         -> salvedades cliente_rechaza vivas del combo, posteriores
--                         al armado (pedido_combos.armado_at)
--     lo que hay       -> la suma de las dos lineas de cada producto
--   _combo_plan (pura) dice cuantos combos quedan y cuantas unidades de cada
--   producto van en el combo; _combo_aplicar mueve unidades entre las dos
--   lineas. Por eso el resultado no depende del orden de las salvedades, y
--   anular una (en cualquier orden) deja el pedido como si no hubiera existido.
--   Lo que esta en el combo es lo que se entrego primero (lo que se rompio por
--   un motivo nuestro cuenta para el combo pero no se cobra: va a los combos
--   rotos antes que lo entregado). En un lugar con alternativas a distinto
--   precio, queda en el combo lo que mas descuento tiene.
--
-- PARTIR UNA LINEA reparte su huella (pedido_item_lotes) sin mover stock: las
-- unidades que se mueven se llevan huella primero, por FEFO sobre la de la
-- linea (_combo_mover_huella). Ni la cantidad del producto ni el stock cambian;
-- LOTE-D se cumple por construccion.
--
-- QUE AGREGA
--   * pedido_items.combo_roto_id (+ GRANT SELECT por columna, PEDIDO_ITEM_COLUMNAS).
--   * pedido_combos: cantidad_combos_armados, armado_at, precios, recargo.
--     cantidad_combos pasa a ser los combos VIVOS (>= 0): libera el tope.
--   * salvedades_items: combo_id, recargo_combo, combo_detalle.
--   * _combo_plan (pura), _combo_estado, _combo_mover_huella, _combo_trasladar,
--     _combo_sabor, _combo_partir, _combo_aplicar, _combo_rehacer (de server).
--   * simular_salvedades_combo_impacto: lo que ve el chofer antes de confirmar.
--   * registrar_salvedad y anular_salvedad: el pozo, el combo rehecho y el
--     total al final (con monto_pagado en el SET: CLAUDE.md, vale blanco).
--   * _guardar_combos_pedido: la foto lleva precios, armados y armado_at.
--   * PRECIO-A exime a _combo_partir (mueve unidades al precio de la foto, no
--     vende). COMBO-B: cada combo de un pedido vivo esta en su punto fijo.
--
-- ORDEN DE DESPLIEGUE: esta migracion ANTES que el front. El front nuevo pide
-- combo_roto_id en PEDIDO_ITEM_COLUMNAS: sin la columna, la consulta de pedidos
-- falla entera para todos.
-- =========================================================================


-- -------------------------------------------------------------------------
-- 0 · Parches de texto (mismo helper que la 363 y la 380)
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.rr_parchar(p_def text, p_viejo text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  IF (length(p_def) - length(replace(p_def, p_viejo, ''))) / length(p_viejo) <> 1 THEN
    RAISE EXCEPTION '%: el fragmento no aparece exactamente una vez: revisar a mano', p_que;
  END IF;
  RETURN replace(p_def, p_viejo, p_nuevo);
END
$fn$;

-- El bloque que va de p_desde (unico) hasta el primer p_hasta despues, incluido.
CREATE OR REPLACE FUNCTION pg_temp.rr_bloque(p_def text, p_desde text, p_hasta text, p_que text)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
  i integer;
  j integer;
BEGIN
  IF (length(p_def) - length(replace(p_def, p_desde, ''))) / length(p_desde) <> 1 THEN
    RAISE EXCEPTION '%: el comienzo del bloque no aparece exactamente una vez', p_que;
  END IF;
  i := position(p_desde IN p_def);
  j := position(p_hasta IN substr(p_def, i));
  IF j = 0 THEN
    RAISE EXCEPTION '%: el final del bloque no aparece', p_que;
  END IF;
  RETURN substr(p_def, i, j - 1 + length(p_hasta));
END
$fn$;

-- -------------------------------------------------------------------------
-- 1 · Columnas
-- -------------------------------------------------------------------------

-- La parte de una linea de combo que el cliente rompio (#1192): va a su precio
-- sin combo y sigue siendo del pozo del combo (si el cliente anula el rechazo,
-- vuelve al combo).
ALTER TABLE public.pedido_items ADD COLUMN combo_roto_id bigint;
ALTER TABLE public.pedido_items
  ADD CONSTRAINT pedido_items_combo_roto_fkey
    FOREIGN KEY (combo_roto_id, sucursal_id) REFERENCES public.combos (id, sucursal_id),
  ADD CONSTRAINT pedido_items_combo_roto_coherente CHECK (
    combo_roto_id IS NULL OR (combo_id IS NULL AND NOT COALESCE(es_bonificacion, false)));
CREATE INDEX pedido_items_combo_roto_idx ON public.pedido_items (combo_roto_id) WHERE combo_roto_id IS NOT NULL;
COMMENT ON COLUMN public.pedido_items.combo_roto_id IS
  'Unidades que salieron de este combo porque el cliente rechazo parte de el (#1192): van a su precio sin combo (el de la foto). Las mueve _combo_rehacer.';

-- pedido_items se concede por columna (327, #1003): la nueva nace invisible. Va
-- la lista entera (la de la 380 mas la nueva): el ultimo GRANT de migrations/
-- es el que compara pedidoItemColumnas.test.ts con PEDIDO_ITEM_COLUMNAS.
GRANT SELECT (id, pedido_id, producto_id, cantidad, precio_unitario, subtotal, es_bonificacion, promocion_id, neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva, sucursal_id, tp_import_id, descripcion_regalo, stock_al_crear, ingreso_real_unitario, precio_lista_al_crear, origen_precio, descuento_pct, grupo_precio_escala_id, unidades_por_bloque_al_crear, origen_unidades_por_bloque, regalo_cadena_id, combo_id, precio_sin_combo_unitario, combo_roto_id)
  ON public.pedido_items TO authenticated;

-- La foto: cuantos combos se armaron, cuando, a que precios, y lo que el pedido
-- paga de mas por los combos que rompio el cliente.
ALTER TABLE public.pedido_combos
  ADD COLUMN cantidad_combos_armados integer,
  ADD COLUMN armado_at timestamptz,
  ADD COLUMN precios jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN recargo numeric(12,2) NOT NULL DEFAULT 0;

UPDATE public.pedido_combos f
   SET cantidad_combos_armados = f.cantidad_combos,
       armado_at = f.tomada_at,
       precios = COALESCE((SELECT jsonb_object_agg(pi.producto_id::text,
                                    jsonb_build_object('combo', pi.precio_unitario,
                                                       'sin_combo', pi.precio_sin_combo_unitario))
                             FROM public.pedido_items pi
                            WHERE pi.pedido_id = f.pedido_id AND pi.sucursal_id = f.sucursal_id
                              AND pi.combo_id = f.combo_id), '{}'::jsonb);

ALTER TABLE public.pedido_combos
  ALTER COLUMN cantidad_combos_armados SET NOT NULL,
  ALTER COLUMN armado_at SET NOT NULL,
  ALTER COLUMN armado_at SET DEFAULT now(),
  ADD CONSTRAINT pedido_combos_armados_check CHECK (cantidad_combos_armados > 0),
  ADD CONSTRAINT pedido_combos_vivos_check CHECK (cantidad_combos BETWEEN 0 AND cantidad_combos_armados);
-- cantidad_combos ya no es > 0: un rechazo puede romper todos los combos del
-- pedido y la foto se queda (anular los devuelve).
ALTER TABLE public.pedido_combos DROP CONSTRAINT pedido_combos_cantidad_combos_check;

COMMENT ON COLUMN public.pedido_combos.cantidad_combos IS
  'Combos vivos: los armados menos los que rompio el cliente (#1192). Es lo que cuenta para el tope.';
COMMENT ON COLUMN public.pedido_combos.cantidad_combos_armados IS
  'Combos con los que se armo (o rearmo al editar) el pedido (#1192).';
COMMENT ON COLUMN public.pedido_combos.armado_at IS
  'Cuando se armo o rearmo. Los rechazos de antes ya estan en las lineas: solo cuentan los de despues (#1192).';
COMMENT ON COLUMN public.pedido_combos.precios IS
  '{producto_id: {combo, sin_combo}}: los precios de la foto. Romper el combo vuelve a sin_combo (#1192).';
COMMENT ON COLUMN public.pedido_combos.recargo IS
  'Lo que el pedido paga de mas por los combos que rompio el cliente: suma de (sin_combo - combo) de lo que salio (#1192).';

-- La salvedad sobre el pozo de un combo.
ALTER TABLE public.salvedades_items
  ADD COLUMN combo_id bigint,
  ADD COLUMN recargo_combo numeric(12,2),
  ADD COLUMN combo_detalle jsonb;
ALTER TABLE public.salvedades_items
  ADD CONSTRAINT salvedades_items_combo_fkey
    FOREIGN KEY (combo_id, sucursal_id) REFERENCES public.combos (id, sucursal_id),
  ADD CONSTRAINT salvedades_items_recargo_combo_check CHECK (recargo_combo IS NULL OR combo_id IS NOT NULL);
CREATE INDEX salvedades_items_combo_idx ON public.salvedades_items (combo_id) WHERE combo_id IS NOT NULL;
COMMENT ON COLUMN public.salvedades_items.combo_id IS
  'El combo del pozo de la linea (la del combo o la que salio de el), al registrar (#1192).';
COMMENT ON COLUMN public.salvedades_items.recargo_combo IS
  'Cuanto subio (o bajo) el total por rehacer el combo, aparte de monto_afectado (#1192). Romper el combo no tiene tope (excepcion a 165-168).';
COMMENT ON COLUMN public.salvedades_items.combo_detalle IS
  'Combos antes y despues, y lo que salio o volvio por producto (#1192). anulacion: lo mismo al anular.';

-- -------------------------------------------------------------------------
-- 2 · La regla, pura
-- -------------------------------------------------------------------------
-- p_componentes: la foto [{componente, cantidad, productos}]. p_armados: los
-- combos armados. p_lineas: [{producto_id, en_combo, fuera}] (lo que hay de
-- cada producto en el pozo). p_rechazos: [{producto_id, cantidad}] (lo que
-- rechazo el cliente). p_precios: {producto_id: {combo, sin_combo}}.
-- Devuelve {combos, productos: {producto_id: {en_combo, fuera}}, recargo}.
CREATE OR REPLACE FUNCTION public._combo_plan(p_componentes jsonb, p_armados integer, p_lineas jsonb,
                                              p_rechazos jsonb, p_precios jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $fn$
DECLARE
  v_lineas  jsonb := CASE WHEN jsonb_typeof(p_lineas) = 'array' THEN p_lineas ELSE '[]'::jsonb END;
  v_rech    jsonb := CASE WHEN jsonb_typeof(p_rechazos) = 'array' THEN p_rechazos ELSE '[]'::jsonb END;
  v_k       integer;
  c         jsonb;
  v_resto   integer;
  r         record;
  v_t       integer;
  v_prods   jsonb := '{}'::jsonb;
  v_recargo numeric := 0;
BEGIN
  IF jsonb_typeof(p_componentes) IS DISTINCT FROM 'array' OR jsonb_array_length(p_componentes) = 0
     OR p_armados IS NULL OR p_armados < 0 THEN
    RETURN NULL;
  END IF;

  -- Los combos que sobreviven: el minimo entre lugares de
  -- floor((armados x requerida - rechazado por el cliente) / requerida).
  SELECT min(div(GREATEST(p_armados * (x->>'cantidad')::int
                          - COALESCE((SELECT sum((s->>'cantidad')::int)
                                        FROM jsonb_array_elements(v_rech) s
                                       WHERE x->'productos' @> to_jsonb((s->>'producto_id')::bigint)), 0),
                          0),
                 (x->>'cantidad')::int))::int
    INTO v_k
    FROM jsonb_array_elements(p_componentes) x;

  -- En cada lugar quedan en el combo k x requerida unidades, de lo que hay
  -- (lo que se rompio por un motivo nuestro va a los combos rotos primero). Con
  -- alternativas, queda en el combo lo que mas descuento tiene.
  FOR c IN SELECT * FROM jsonb_array_elements(p_componentes) LOOP
    SELECT LEAST(COALESCE(sum((l->>'en_combo')::int + (l->>'fuera')::int), 0), v_k * (c->>'cantidad')::int)::int
      INTO v_resto
      FROM jsonb_array_elements(v_lineas) l
     WHERE c->'productos' @> to_jsonb((l->>'producto_id')::bigint);
    FOR r IN
      SELECT (l->>'producto_id')::bigint AS producto_id,
             ((l->>'en_combo')::int + (l->>'fuera')::int) AS hay,
             COALESCE((p_precios->(l->>'producto_id')->>'sin_combo')::numeric
                      - (p_precios->(l->>'producto_id')->>'combo')::numeric, 0) AS dif
        FROM jsonb_array_elements(v_lineas) l
       WHERE c->'productos' @> to_jsonb((l->>'producto_id')::bigint)
       ORDER BY 3 DESC, 1
    LOOP
      v_t := LEAST(r.hay, v_resto);
      v_resto := v_resto - v_t;
      v_prods := v_prods || jsonb_build_object(r.producto_id::text,
                                               jsonb_build_object('en_combo', v_t, 'fuera', r.hay - v_t));
      v_recargo := v_recargo + (r.hay - v_t) * r.dif;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object('combos', v_k, 'productos', v_prods, 'recargo', round(v_recargo, 2));
END
$fn$;

-- El origen de precio de una linea del pozo: 'combo' en el combo; fuera, el de
-- su precio sin combo (lista, o escala si el combo era acumulable).
CREATE OR REPLACE FUNCTION public._combo_origen(p_en_combo boolean, p_precio numeric, p_lista numeric,
                                                p_combina boolean)
RETURNS varchar
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $fn$
  SELECT (CASE WHEN p_en_combo THEN 'combo'
               WHEN p_precio = p_lista THEN 'lista'
               WHEN p_combina AND p_precio < p_lista THEN 'mayorista'
               ELSE 'desconocido' END)::varchar;
$fn$;

-- -------------------------------------------------------------------------
-- 3 · El estado del pozo de un combo en un pedido
-- -------------------------------------------------------------------------
-- NULL si el pedido no tiene la foto del combo. p_excluir: una salvedad que no
-- cuenta (la que se esta anulando).
CREATE OR REPLACE FUNCTION public._combo_estado(p_pedido_id bigint, p_sucursal bigint, p_combo_id bigint,
                                                p_excluir bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = public
AS $fn$
  SELECT jsonb_build_object(
    'nombre', f.nombre,
    'componentes', f.componentes,
    'armados', f.cantidad_combos_armados,
    'cantidad_combos', f.cantidad_combos,
    'recargo', f.recargo,
    'precios', f.precios,
    'combina_escalas', f.combina_escalas,
    'lineas', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('producto_id', x.producto_id, 'en_combo', x.en_combo, 'fuera', x.fuera)
                       ORDER BY x.producto_id)
        FROM (SELECT pi.producto_id,
                     COALESCE(sum(pi.cantidad) FILTER (WHERE pi.combo_id = f.combo_id), 0)::int AS en_combo,
                     COALESCE(sum(pi.cantidad) FILTER (WHERE pi.combo_roto_id = f.combo_id), 0)::int AS fuera
                FROM pedido_items pi
               WHERE pi.pedido_id = f.pedido_id AND pi.sucursal_id = f.sucursal_id
                 AND (pi.combo_id = f.combo_id OR pi.combo_roto_id = f.combo_id)
               GROUP BY pi.producto_id) x), '[]'::jsonb),
    -- Los rechazos del cliente vivos, de despues del armado: los de antes de
    -- una edicion ya estan en las lineas que se rearmaron.
    'rechazos', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('producto_id', s.producto_id, 'cantidad', s.cantidad)
                       ORDER BY s.producto_id)
        FROM (SELECT si.producto_id, sum(si.cantidad_afectada)::int AS cantidad
                FROM salvedades_items si
               WHERE si.pedido_id = f.pedido_id AND si.sucursal_id = f.sucursal_id
                 AND si.combo_id = f.combo_id
                 AND si.motivo = 'cliente_rechaza'
                 AND si.estado_resolucion <> 'anulada'
                 AND si.id IS DISTINCT FROM p_excluir
                 AND si.created_at >= f.armado_at
               GROUP BY si.producto_id) s), '[]'::jsonb))
    FROM pedido_combos f
   WHERE f.pedido_id = p_pedido_id AND f.combo_id = p_combo_id AND f.sucursal_id = p_sucursal;
$fn$;

-- -------------------------------------------------------------------------
-- 4 · Mover unidades entre las lineas del pozo, sin mover stock
-- -------------------------------------------------------------------------

-- La huella de p_cantidad unidades pasa de una linea a otra: las que se mueven
-- se la llevan primero, por FEFO sobre la de la linea (el orden de #1127).
CREATE OR REPLACE FUNCTION public._combo_mover_huella(p_desde bigint, p_hacia bigint, p_cantidad integer)
RETURNS void
LANGUAGE plpgsql
SET search_path = public
AS $fn$
DECLARE
  v_pend integer := p_cantidad;
  v_m    integer;
  r      record;
BEGIN
  FOR r IN
    SELECT pil.id, pil.lote_id, pil.cantidad, pil.sucursal_id
      FROM pedido_item_lotes pil
      JOIN producto_lotes l ON l.id = pil.lote_id
     WHERE pil.pedido_item_id = p_desde
     ORDER BY l.fecha_vencimiento, l.id, pil.id
       FOR UPDATE OF pil
  LOOP
    EXIT WHEN v_pend <= 0;
    v_m := LEAST(v_pend, r.cantidad);
    INSERT INTO pedido_item_lotes (pedido_item_id, lote_id, cantidad, sucursal_id)
    VALUES (p_hacia, r.lote_id, v_m, r.sucursal_id)
    ON CONFLICT (pedido_item_id, lote_id)
      DO UPDATE SET cantidad = pedido_item_lotes.cantidad + EXCLUDED.cantidad;
    IF v_m >= r.cantidad THEN
      DELETE FROM pedido_item_lotes WHERE id = r.id;
    ELSE
      UPDATE pedido_item_lotes SET cantidad = cantidad - v_m WHERE id = r.id;
    END IF;
    v_pend := v_pend - v_m;
  END LOOP;
END
$fn$;

-- p_cantidad unidades (y su huella) pasan de una linea a otra del mismo pozo,
-- cada una a su precio. La de origen se borra si queda en cero.
CREATE OR REPLACE FUNCTION public._combo_trasladar(p_desde bigint, p_hacia bigint, p_cantidad integer)
RETURNS void
LANGUAGE plpgsql
SET search_path = public
AS $fn$
DECLARE
  v_cant integer;
BEGIN
  IF COALESCE(p_cantidad, 0) <= 0 OR p_desde = p_hacia THEN
    RETURN;
  END IF;
  SELECT cantidad INTO v_cant FROM pedido_items WHERE id = p_desde FOR UPDATE;
  IF v_cant IS NULL OR p_cantidad > v_cant THEN
    RAISE EXCEPTION 'combo: la linea #% no tiene % unidades para mover', p_desde, p_cantidad;
  END IF;
  UPDATE pedido_items
     SET cantidad = cantidad + p_cantidad,
         subtotal = (cantidad + p_cantidad) * precio_unitario
   WHERE id = p_hacia;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'combo: no existe la linea #%', p_hacia;
  END IF;
  PERFORM public._combo_mover_huella(p_desde, p_hacia, p_cantidad);
  IF p_cantidad = v_cant THEN
    DELETE FROM pedido_items WHERE id = p_desde;
  ELSE
    UPDATE pedido_items
       SET cantidad = cantidad - p_cantidad,
           subtotal = (cantidad - p_cantidad) * precio_unitario
     WHERE id = p_desde;
  END IF;
END
$fn$;

-- Una linea entera pasa al combo (p_en_combo) o sale de el, al precio de la
-- foto (p_precio = {combo, sin_combo}).
CREATE OR REPLACE FUNCTION public._combo_sabor(p_linea bigint, p_combo_id bigint, p_en_combo boolean,
                                               p_precio jsonb, p_combina boolean)
RETURNS void
LANGUAGE plpgsql
SET search_path = public
AS $fn$
DECLARE
  v_precio numeric := CASE WHEN p_en_combo THEN NULLIF(p_precio->>'combo', '')::numeric
                           ELSE NULLIF(p_precio->>'sin_combo', '')::numeric END;
  v_l      record;
  v_d      record;
BEGIN
  SELECT pi.porcentaje_iva, pi.precio_lista_al_crear, COALESCE(p.tipo_factura, 'ZZ') AS tipo
    INTO v_l
    FROM pedido_items pi
    JOIN pedidos p ON p.id = pi.pedido_id
   WHERE pi.id = p_linea;
  IF NOT FOUND OR v_precio IS NULL OR v_precio <= 0
     OR (p_en_combo AND COALESCE(NULLIF(p_precio->>'sin_combo', '')::numeric, 0) <= 0) THEN
    RAISE EXCEPTION 'combo #%: la foto no tiene los precios de la linea #%', p_combo_id, p_linea;
  END IF;
  SELECT * INTO v_d FROM public.calcular_desglose_venta(v_precio, v_l.porcentaje_iva, 0, v_l.tipo);
  UPDATE pedido_items
     SET combo_id = CASE WHEN p_en_combo THEN p_combo_id END,
         combo_roto_id = CASE WHEN p_en_combo THEN NULL ELSE p_combo_id END,
         precio_sin_combo_unitario = CASE WHEN p_en_combo THEN NULLIF(p_precio->>'sin_combo', '')::numeric END,
         precio_unitario = v_precio,
         subtotal = cantidad * v_precio,
         origen_precio = public._combo_origen(p_en_combo, v_precio, v_l.precio_lista_al_crear, p_combina),
         descuento_pct = CASE WHEN v_l.precio_lista_al_crear > 0
                              THEN greatest(-999.99, least(999.99,
                                     round(((v_l.precio_lista_al_crear - v_precio) / v_l.precio_lista_al_crear) * 100, 2)))
                              ELSE descuento_pct END,
         neto_unitario = v_d.neto,
         iva_unitario = v_d.iva,
         ingreso_real_unitario = v_d.ingreso_real
   WHERE id = p_linea;
END
$fn$;

-- Parte una linea: p_cantidad unidades (y su huella) van a una linea nueva del
-- otro lado del combo, al precio de la foto. Devuelve la linea nueva.
-- PRECIO-A la exime: el precio es el de la foto del pedido, no una venta nueva.
CREATE OR REPLACE FUNCTION public._combo_partir(p_linea bigint, p_cantidad integer, p_combo_id bigint,
                                                p_en_combo boolean, p_precio jsonb, p_combina boolean)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = public
AS $fn$
DECLARE
  v_precio numeric := CASE WHEN p_en_combo THEN NULLIF(p_precio->>'combo', '')::numeric
                           ELSE NULLIF(p_precio->>'sin_combo', '')::numeric END;
  v_l      record;
  v_d      record;
  v_nueva  bigint;
BEGIN
  SELECT pi.*, COALESCE(p.tipo_factura, 'ZZ') AS tipo_pedido
    INTO v_l
    FROM pedido_items pi
    JOIN pedidos p ON p.id = pi.pedido_id
   WHERE pi.id = p_linea
     FOR UPDATE OF pi;
  IF NOT FOUND OR COALESCE(p_cantidad, 0) <= 0 OR p_cantidad >= v_l.cantidad THEN
    RAISE EXCEPTION 'combo: no se puede partir % unidades de la linea #%', p_cantidad, p_linea;
  END IF;
  IF v_precio IS NULL OR v_precio <= 0
     OR (p_en_combo AND COALESCE(NULLIF(p_precio->>'sin_combo', '')::numeric, 0) <= 0) THEN
    RAISE EXCEPTION 'combo #%: la foto no tiene los precios de la linea #%', p_combo_id, p_linea;
  END IF;
  SELECT * INTO v_d FROM public.calcular_desglose_venta(v_precio, v_l.porcentaje_iva, 0, v_l.tipo_pedido);

  INSERT INTO pedido_items (
    pedido_id, producto_id, cantidad, precio_unitario, subtotal, es_bonificacion, promocion_id,
    neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva, ingreso_real_unitario,
    sucursal_id, stock_al_crear, costo_unitario_al_crear, precio_lista_al_crear, origen_precio,
    descuento_pct, grupo_precio_escala_id, unidades_por_bloque_al_crear, origen_unidades_por_bloque,
    combo_id, precio_sin_combo_unitario, combo_roto_id
  )
  SELECT v_l.pedido_id, v_l.producto_id, p_cantidad, v_precio, p_cantidad * v_precio,
         v_l.es_bonificacion, v_l.promocion_id,
         v_d.neto, v_d.iva, v_l.impuestos_internos_unitario, v_l.porcentaje_iva, v_d.ingreso_real,
         v_l.sucursal_id, v_l.stock_al_crear,
         -- COSTO-D: la cascada unica de la 238, con el costo de la venta primero
         -- (son las mismas unidades: su costo no cambia por partir la linea).
         public.costo_valuacion(v_l.costo_unitario_al_crear, pr.costo_promedio, pr.costo_real,
                                pr.costo_sin_iva, COALESCE(pr.impuestos_internos, 0)),
         v_l.precio_lista_al_crear,
         public._combo_origen(p_en_combo, v_precio, v_l.precio_lista_al_crear, p_combina),
         CASE WHEN v_l.precio_lista_al_crear > 0
              THEN greatest(-999.99, least(999.99,
                     round(((v_l.precio_lista_al_crear - v_precio) / v_l.precio_lista_al_crear) * 100, 2)))
              ELSE v_l.descuento_pct END,
         v_l.grupo_precio_escala_id, v_l.unidades_por_bloque_al_crear, v_l.origen_unidades_por_bloque,
         CASE WHEN p_en_combo THEN p_combo_id END,
         CASE WHEN p_en_combo THEN NULLIF(p_precio->>'sin_combo', '')::numeric END,
         CASE WHEN p_en_combo THEN NULL ELSE p_combo_id END
    FROM productos pr
   WHERE pr.id = v_l.producto_id
  RETURNING id INTO v_nueva;

  UPDATE pedido_items
     SET cantidad = cantidad - p_cantidad,
         subtotal = (cantidad - p_cantidad) * precio_unitario
   WHERE id = p_linea;
  PERFORM public._combo_mover_huella(p_linea, v_nueva, p_cantidad);
  RETURN v_nueva;
END
$fn$;

-- Lleva las lineas del pozo de cada producto al reparto del plan. Prefiere no
-- cambiar ids: mueve entre las dos lineas que ya hay, parte solo si falta una,
-- y si sobra una se suma a la mas vieja.
CREATE OR REPLACE FUNCTION public._combo_aplicar(p_pedido_id bigint, p_sucursal bigint, p_combo_id bigint,
                                                 p_plan jsonb, p_precios jsonb, p_combina boolean)
RETURNS void
LANGUAGE plpgsql
SET search_path = public
AS $fn$
DECLARE
  r       record;
  v_dup   record;
  v_i     integer;
  v_lc    bigint;
  v_c     integer;
  v_lb    bigint;
  v_o     integer;
  v_vieja bigint;
  v_nueva bigint;
  v_prec  jsonb;
BEGIN
  FOR r IN
    SELECT key::bigint AS producto_id, (value->>'en_combo')::int AS t, (value->>'fuera')::int AS b
      FROM jsonb_each(COALESCE(p_plan->'productos', '{}'::jsonb))
     ORDER BY key::bigint
  LOOP
    v_prec := p_precios->(r.producto_id::text);

    -- Una linea de cada lado: si hubiera dos, la mas nueva se suma a la vieja.
    FOR v_dup IN
      SELECT array_agg(pi.id ORDER BY pi.id) AS ids
        FROM pedido_items pi
       WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = p_sucursal AND pi.producto_id = r.producto_id
         AND (pi.combo_id = p_combo_id OR pi.combo_roto_id = p_combo_id)
       GROUP BY (pi.combo_id IS NOT NULL)
      HAVING count(*) > 1
    LOOP
      FOR v_i IN 2 .. cardinality(v_dup.ids) LOOP
        PERFORM public._combo_trasladar(v_dup.ids[v_i], v_dup.ids[1],
                                        (SELECT cantidad FROM pedido_items WHERE id = v_dup.ids[v_i]));
      END LOOP;
    END LOOP;

    SELECT id, cantidad INTO v_lc, v_c
      FROM pedido_items
     WHERE pedido_id = p_pedido_id AND sucursal_id = p_sucursal AND producto_id = r.producto_id
       AND combo_id = p_combo_id
       FOR UPDATE;
    SELECT id, cantidad INTO v_lb, v_o
      FROM pedido_items
     WHERE pedido_id = p_pedido_id AND sucursal_id = p_sucursal AND producto_id = r.producto_id
       AND combo_roto_id = p_combo_id
       FOR UPDATE;
    v_c := COALESCE(v_c, 0);
    v_o := COALESCE(v_o, 0);
    IF r.t + r.b <> v_c + v_o THEN
      RAISE EXCEPTION 'combo #%, producto #%: el plan reparte % y hay %', p_combo_id, r.producto_id,
        r.t + r.b, v_c + v_o;
    END IF;
    CONTINUE WHEN v_c = r.t;

    IF r.t > 0 AND r.b > 0 THEN
      IF v_lc IS NOT NULL AND v_lb IS NOT NULL THEN
        IF v_c > r.t THEN
          PERFORM public._combo_trasladar(v_lc, v_lb, v_c - r.t);
        ELSE
          PERFORM public._combo_trasladar(v_lb, v_lc, r.t - v_c);
        END IF;
      ELSIF v_lc IS NOT NULL THEN
        PERFORM public._combo_partir(v_lc, r.b, p_combo_id, false, v_prec, p_combina);
      ELSE
        PERFORM public._combo_partir(v_lb, r.t, p_combo_id, true, v_prec, p_combina);
      END IF;
    ELSIF v_lc IS NOT NULL AND v_lb IS NOT NULL THEN
      -- Todo de un lado: queda la linea mas vieja, de ese lado.
      v_vieja := LEAST(v_lc, v_lb);
      v_nueva := GREATEST(v_lc, v_lb);
      PERFORM public._combo_sabor(v_vieja, p_combo_id, r.t > 0, v_prec, p_combina);
      PERFORM public._combo_trasladar(v_nueva, v_vieja, (SELECT cantidad FROM pedido_items WHERE id = v_nueva));
    ELSE
      PERFORM public._combo_sabor(COALESCE(v_lc, v_lb), p_combo_id, r.t > 0, v_prec, p_combina);
    END IF;
  END LOOP;
END
$fn$;

-- Rehace el combo de un pedido: estado -> plan -> lineas -> foto. Devuelve el
-- detalle (combos antes y despues, y por producto lo que estaba y queda en el
-- combo), o NULL si el pedido no tiene la foto del combo. El llamador recalcula
-- el total del pedido.
CREATE OR REPLACE FUNCTION public._combo_rehacer(p_pedido_id bigint, p_sucursal bigint, p_combo_id bigint,
                                                 p_excluir bigint)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = public
AS $fn$
DECLARE
  v_e    jsonb;
  v_plan jsonb;
BEGIN
  PERFORM 1 FROM pedido_combos
   WHERE pedido_id = p_pedido_id AND combo_id = p_combo_id AND sucursal_id = p_sucursal
     FOR UPDATE;
  v_e := public._combo_estado(p_pedido_id, p_sucursal, p_combo_id, p_excluir);
  IF v_e IS NULL THEN
    RETURN NULL;
  END IF;
  v_plan := public._combo_plan(v_e->'componentes', (v_e->>'armados')::int, v_e->'lineas',
                               v_e->'rechazos', v_e->'precios');
  IF v_plan IS NULL THEN
    RETURN NULL;
  END IF;

  PERFORM public._combo_aplicar(p_pedido_id, p_sucursal, p_combo_id, v_plan, v_e->'precios',
                                (v_e->>'combina_escalas')::boolean);

  UPDATE pedido_combos
     SET cantidad_combos = (v_plan->>'combos')::int,
         recargo = (v_plan->>'recargo')::numeric
   WHERE pedido_id = p_pedido_id AND combo_id = p_combo_id AND sucursal_id = p_sucursal;

  RETURN jsonb_build_object(
    'combo_id', p_combo_id,
    'combos_antes', (v_e->>'cantidad_combos')::int,
    'combos_despues', (v_plan->>'combos')::int,
    'recargo_antes', (v_e->>'recargo')::numeric,
    'recargo_despues', (v_plan->>'recargo')::numeric,
    'productos', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'producto_id', (l->>'producto_id')::bigint,
               'en_combo_antes', (l->>'en_combo')::int,
               'en_combo_despues', COALESCE((v_plan->'productos'->(l->>'producto_id')->>'en_combo')::int, 0))
             ORDER BY (l->>'producto_id')::bigint)
        FROM jsonb_array_elements(v_e->'lineas') l), '[]'::jsonb));
END
$fn$;

-- -------------------------------------------------------------------------
-- 5 · Lo que ve el chofer antes de confirmar
-- -------------------------------------------------------------------------
-- p_salvedades: [{pedido_item_id, cantidad_afectada, motivo}], las que se
-- simulan juntas. Por cada combo que tocan: los combos que quedan y el recargo,
-- que es lo que el total sube aparte de lo rechazado al precio de su linea
-- (recargo = total del pozo despues - antes + lo rechazado). Como rehacer el
-- combo no depende del orden, el lote entero da lo mismo que confirmarlas de a
-- una. Sin acceso al pedido, vacio.
CREATE OR REPLACE FUNCTION public.simular_salvedades_combo_impacto(p_pedido_id bigint, p_salvedades jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_sucursal bigint := public.current_sucursal_id();
  v_out      jsonb := '[]'::jsonb;
  v_combo    bigint;
  v_e        jsonb;
  v_lineas   jsonb;
  v_rech     jsonb;
  v_monto    numeric;
  v_plan     jsonb;
  v_antes    numeric;
  v_despues  numeric;
BEGIN
  -- #1009: solo sobre un pedido que el caller puede leer.
  IF v_sucursal IS NULL OR jsonb_typeof(p_salvedades) IS DISTINCT FROM 'array'
     OR NOT public.puede_leer_pedido(p_pedido_id) THEN
    RETURN '[]'::jsonb;
  END IF;

  FOR v_combo IN
    SELECT DISTINCT COALESCE(pi.combo_id, pi.combo_roto_id)
      FROM jsonb_array_elements(p_salvedades) e
      JOIN pedido_items pi ON pi.id = NULLIF(e->>'pedido_item_id', '')::bigint
     WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
       AND COALESCE(pi.combo_id, pi.combo_roto_id) IS NOT NULL
     ORDER BY 1
  LOOP
    v_e := public._combo_estado(p_pedido_id, v_sucursal, v_combo, NULL);
    CONTINUE WHEN v_e IS NULL;

    -- Lo simulado sobre cada producto del pozo: cuanto sale, cuanto rechaza el
    -- cliente y lo que se descuenta al precio de la linea.
    WITH sim AS (
      SELECT pi.producto_id,
             GREATEST(COALESCE(NULLIF(e->>'cantidad_afectada', '')::int, 0), 0) AS cantidad,
             e->>'motivo' = 'cliente_rechaza' AS cliente,
             pi.precio_unitario
        FROM jsonb_array_elements(p_salvedades) e
        JOIN pedido_items pi ON pi.id = NULLIF(e->>'pedido_item_id', '')::bigint
       WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
         AND COALESCE(pi.combo_id, pi.combo_roto_id) = v_combo
    ), por_producto AS (
      SELECT producto_id, sum(cantidad)::int AS cantidad,
             COALESCE(sum(cantidad) FILTER (WHERE cliente), 0)::int AS cliente,
             sum(cantidad * precio_unitario) AS monto
        FROM sim GROUP BY producto_id
    )
    SELECT
      COALESCE((SELECT jsonb_agg(jsonb_build_object(
                         'producto_id', (l->>'producto_id')::bigint,
                         'en_combo', GREATEST((l->>'en_combo')::int + (l->>'fuera')::int - COALESCE(pp.cantidad, 0), 0),
                         'fuera', 0))
                  FROM jsonb_array_elements(v_e->'lineas') l
                  LEFT JOIN por_producto pp ON pp.producto_id = (l->>'producto_id')::bigint), '[]'::jsonb),
      COALESCE((SELECT jsonb_agg(jsonb_build_object('producto_id', x.producto_id, 'cantidad', x.cantidad))
                  FROM (SELECT (r->>'producto_id')::bigint AS producto_id, (r->>'cantidad')::int AS cantidad
                          FROM jsonb_array_elements(v_e->'rechazos') r
                        UNION ALL
                        SELECT producto_id, cliente FROM por_producto WHERE cliente > 0) x), '[]'::jsonb),
      COALESCE((SELECT sum(monto) FROM por_producto), 0)
      INTO v_lineas, v_rech, v_monto;

    v_plan := public._combo_plan(v_e->'componentes', (v_e->>'armados')::int, v_lineas, v_rech, v_e->'precios');
    CONTINUE WHEN v_plan IS NULL;

    SELECT COALESCE(sum(subtotal), 0) INTO v_antes
      FROM pedido_items
     WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal
       AND (combo_id = v_combo OR combo_roto_id = v_combo);
    SELECT COALESCE(sum((p.value->>'en_combo')::int * (v_e->'precios'->p.key->>'combo')::numeric
                        + (p.value->>'fuera')::int * (v_e->'precios'->p.key->>'sin_combo')::numeric), 0)
      INTO v_despues
      FROM jsonb_each(v_plan->'productos') p;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'combo_id', v_combo,
      'nombre', v_e->>'nombre',
      'combos_antes', (v_e->>'cantidad_combos')::int,
      'combos_despues', (v_plan->>'combos')::int,
      'recargo', round(v_despues - v_antes + v_monto, 2),
      'productos', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                 'producto_id', (l->>'producto_id')::bigint,
                 'nombre', pr.nombre,
                 'fuera_antes', (l->>'fuera')::int,
                 'fuera_despues', COALESCE((v_plan->'productos'->(l->>'producto_id')->>'fuera')::int, 0),
                 'precio_combo', (v_e->'precios'->(l->>'producto_id')->>'combo')::numeric,
                 'precio_sin_combo', (v_e->'precios'->(l->>'producto_id')->>'sin_combo')::numeric)
               ORDER BY (l->>'producto_id')::bigint)
          FROM jsonb_array_elements(v_e->'lineas') l
          LEFT JOIN productos pr ON pr.id = (l->>'producto_id')::bigint), '[]'::jsonb)));
  END LOOP;

  RETURN v_out;
END
$fn$;

-- -------------------------------------------------------------------------
-- 6 · La foto: precios, armados y cuando se armo
-- -------------------------------------------------------------------------
-- Igual que en la 380, mas: la foto lleva los precios de combo y sin combo de
-- cada producto (#1192: romper el combo vuelve a ese precio, no a la lista de
-- hoy), los combos armados y cuando. Alta y edicion rearman las lineas desde
-- cero (actualizar_pedido_items borra y reinserta), asi que lo que habia salido
-- de un combo roto vuelve como linea comun y el combo arranca sin recargo.
CREATE OR REPLACE FUNCTION public._guardar_combos_pedido(p_pedido_id bigint, p_sucursal bigint)
RETURNS void
LANGUAGE plpgsql
SET search_path = public
AS $fn$
DECLARE
  r     record;
  v_def jsonb;
  v_k   integer;
BEGIN
  DELETE FROM pedido_combos f
   WHERE f.pedido_id = p_pedido_id AND f.sucursal_id = p_sucursal
     AND NOT EXISTS (SELECT 1 FROM pedido_items pi
                      WHERE pi.pedido_id = f.pedido_id AND pi.sucursal_id = f.sucursal_id
                        AND pi.combo_id = f.combo_id);

  FOR r IN
    SELECT pi.combo_id,
           jsonb_agg(jsonb_build_object('producto_id', pi.producto_id, 'cantidad', pi.cantidad)) AS lineas,
           jsonb_object_agg(pi.producto_id::text,
                            jsonb_build_object('combo', pi.precio_unitario,
                                               'sin_combo', pi.precio_sin_combo_unitario)) AS precios
      FROM pedido_items pi
     WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = p_sucursal AND pi.combo_id IS NOT NULL
     GROUP BY pi.combo_id
  LOOP
    SELECT f.componentes INTO v_def
      FROM pedido_combos f
     WHERE f.pedido_id = p_pedido_id AND f.combo_id = r.combo_id AND f.sucursal_id = p_sucursal;
    IF FOUND THEN
      v_k := public._combo_cantidad(v_def, r.lineas);
      IF v_k IS NULL THEN
        RAISE EXCEPTION 'Las líneas del combo #% del pedido #% no forman combos enteros', r.combo_id, p_pedido_id;
      END IF;
      UPDATE pedido_combos
         SET cantidad_combos = v_k,
             cantidad_combos_armados = v_k,
             armado_at = now(),
             precios = precios || r.precios,
             recargo = 0
       WHERE pedido_id = p_pedido_id AND combo_id = r.combo_id AND sucursal_id = p_sucursal;
    ELSE
      v_def := public._combo_definicion(r.combo_id, p_sucursal);
      v_k := public._combo_cantidad(v_def->'componentes', r.lineas);
      IF v_k IS NULL THEN
        RAISE EXCEPTION 'Las líneas del combo #% del pedido #% no forman combos enteros', r.combo_id, p_pedido_id;
      END IF;
      INSERT INTO pedido_combos (pedido_id, combo_id, sucursal_id, cantidad_combos, nombre, precio,
                                 combina_escalas, componentes, cantidad_combos_armados, armado_at, precios)
      VALUES (p_pedido_id, r.combo_id, p_sucursal, v_k, v_def->>'nombre', (v_def->>'precio')::numeric,
              (v_def->>'combina_escalas')::boolean, v_def->'componentes', v_k, now(), r.precios);
    END IF;
  END LOOP;
END
$fn$;

-- -------------------------------------------------------------------------
-- 7 · registrar_salvedad
-- -------------------------------------------------------------------------
DO $registrar$
DECLARE
  v_def    text := pg_get_functiondef(
    'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure);
  v_total  text;
BEGIN
  v_def := pg_temp.rr_parchar(v_def,
$q$  r_huella                RECORD;
BEGIN
$q$,
$q$  r_huella                RECORD;
  -- #1192: el pozo del combo de la linea (la del combo y la que salio de el).
  v_combo_id              BIGINT;
  v_hermana_id            BIGINT;
  v_hermana_cant          INT;
  v_total_combo_antes     NUMERIC;
  v_combo_rehecho         JSONB;
  v_recargo_combo         NUMERIC;
BEGIN
$q$, 'registrar: declaraciones');

  -- El reintento idempotente contesta tambien el recargo.
  v_def := pg_temp.rr_parchar(v_def,
$q$    SELECT id, monto_afectado, cantidad_entregada, stock_devuelto, pedido_id
      INTO v_existing$q$,
$q$    SELECT id, monto_afectado, cantidad_entregada, stock_devuelto, pedido_id, recargo_combo
      INTO v_existing$q$, 'registrar: el reintento lee el recargo');
  v_def := pg_temp.rr_parchar(v_def,
$q$        'idempotent_replay', true$q$,
$q$        'recargo_combo', v_existing.recargo_combo,
        'idempotent_replay', true$q$, 'registrar: el reintento contesta el recargo');

  v_def := pg_temp.rr_parchar(v_def,
$q$         COALESCE(pi.es_bonificacion, FALSE) AS es_bonificacion, pi.promocion_id
    INTO v_item$q$,
$q$         COALESCE(pi.es_bonificacion, FALSE) AS es_bonificacion, pi.promocion_id,
         pi.combo_id, pi.combo_roto_id
    INTO v_item$q$, 'registrar: la linea trae su combo');

  v_def := pg_temp.rr_parchar(v_def,
$q$  IF p_cantidad_afectada > v_item.cantidad THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cantidad afectada mayor a cantidad del item');
  END IF;
$q$,
$q$  -- #1192: la linea de un combo y la parte que salio del combo roto son las
  -- unidades del mismo producto en el mismo combo (el pozo). Entre dos
  -- salvedades de un mismo lote el combo pudo partirse, y el chofer ve las
  -- cantidades de cuando abrio la pantalla: la salvedad toma de las dos.
  v_combo_id := COALESCE(v_item.combo_id, v_item.combo_roto_id);
  IF v_combo_id IS NOT NULL THEN
    SELECT pi.id, pi.cantidad INTO v_hermana_id, v_hermana_cant
      FROM pedido_items pi
     WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
       AND pi.producto_id = v_item.producto_id AND pi.id <> v_item.id
       AND (pi.combo_id = v_combo_id OR pi.combo_roto_id = v_combo_id)
     ORDER BY pi.id
     LIMIT 1;
  END IF;
  IF p_cantidad_afectada > v_item.cantidad + COALESCE(v_hermana_cant, 0) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cantidad afectada mayor a cantidad del item');
  END IF;
$q$, 'registrar: el pozo del combo');

  v_def := pg_temp.rr_parchar(v_def,
$q$  v_es_bonif := v_item.es_bonificacion;
$q$,
$q$  -- #1192: lo que le falta a la linea sale de su hermana del pozo, y pasa al
  -- precio de la linea. Va despues de todas las validaciones que contestan sin
  -- excepcion: de aca en adelante un error revierte todo. El total del pozo de
  -- antes es la base del recargo.
  IF v_combo_id IS NOT NULL THEN
    SELECT COALESCE(SUM(subtotal), 0) INTO v_total_combo_antes
      FROM pedido_items
     WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal
       AND (combo_id = v_combo_id OR combo_roto_id = v_combo_id);
    IF p_cantidad_afectada > v_item.cantidad THEN
      PERFORM set_config('app.omitir_minimo_venta', '1', true);
      PERFORM public._combo_trasladar(v_hermana_id, v_item.id, p_cantidad_afectada - v_item.cantidad);
      SELECT pi.id, pi.producto_id, pi.cantidad, pi.precio_unitario, pi.subtotal,
             COALESCE(pi.es_bonificacion, FALSE) AS es_bonificacion, pi.promocion_id,
             pi.combo_id, pi.combo_roto_id
        INTO v_item
        FROM pedido_items pi
       WHERE pi.id = p_pedido_item_id AND pi.sucursal_id = v_sucursal;
    END IF;
  END IF;

  v_es_bonif := v_item.es_bonificacion;
$q$, 'registrar: la linea toma de su hermana');

  v_def := pg_temp.rr_parchar(v_def,
$q$    client_request_id, es_bonificacion, promocion_id
  ) VALUES ($q$,
$q$    client_request_id, es_bonificacion, promocion_id, combo_id
  ) VALUES ($q$, 'registrar: la salvedad lleva el combo (columna)');
  v_def := pg_temp.rr_parchar(v_def,
$q$    p_client_request_id, v_item.es_bonificacion, v_item.promocion_id
  ) RETURNING id INTO v_salvedad_id;$q$,
$q$    p_client_request_id, v_item.es_bonificacion, v_item.promocion_id, v_combo_id
  ) RETURNING id INTO v_salvedad_id;$q$, 'registrar: la salvedad lleva el combo (valor)');

  -- El total se mueve al final: rehacer el combo cambia lineas, y el total se
  -- escribe UNA vez con todo (rechazo + recargo). Escrito en dos pasos, una
  -- boleta cobrada vería primero la baja (desafectar_sobrepago_pedido recorta
  -- el pago) y despues la suba (deuda): el cliente cobraria y deberia a la vez.
  v_total := pg_temp.rr_bloque(v_def,
$q$  SELECT COALESCE(tipo_factura, 'ZZ') INTO v_tipo_factura
$q$,
$q$    ) sub
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal;
$q$, 'registrar: el bloque del total');
  v_def := pg_temp.rr_parchar(v_def, v_total,
$q$  -- #1192: el total se recalcula al final, despues de rehacer el combo.
$q$, 'registrar: sale el total de aca');
  -- CLAUDE.md: el UPDATE que cambia el total de un vale blanco nombra
  -- monto_pagado en el SET.
  v_total := pg_temp.rr_parchar(v_total,
$q$         updated_at = NOW()
    FROM ($q$,
$q$         monto_pagado = CASE WHEN pedidos.tipo_factura = 'VB' THEN sub.total_recalc
                             ELSE pedidos.monto_pagado END,
         updated_at = NOW()
    FROM ($q$, 'registrar: monto_pagado del vale blanco');

  v_def := pg_temp.rr_parchar(v_def,
$q$  INSERT INTO salvedad_historial (salvedad_id, accion, estado_nuevo, notas, usuario_id, sucursal_id)
  VALUES (v_salvedad_id, 'creacion', 'pendiente', p_descripcion, v_usuario_id, v_sucursal);$q$,
$q$  -- #1192 (decision del dueño 2026-10-15): el combo se rehace segun el motivo.
  -- Con cliente_rechaza el combo se rompe y lo que se queda vuelve a su precio
  -- sin combo (el de la foto del pedido); con un motivo nuestro (o dudoso)
  -- mantiene el precio combo. Combos que sobreviven: el minimo entre lugares de
  -- floor((armado - rechazado por el cliente) / requerida) (_combo_plan).
  --
  -- EXCEPCION EXPLICITA a las migs 165-168 ("rechazar mercaderia solo baja lo
  -- que se paga"): si romper el combo sube el total, SUBE, sin tope. Palabras
  -- del dueño: "si el cliente rechaza algo y el precio aumenta, es problema de
  -- el". Con la boleta cobrada, la diferencia queda como deuda. La regla de
  -- 165-168 sigue rigiendo todo lo demas.
  --
  -- El recargo es lo que el total del pozo subio, aparte de monto_afectado:
  -- total despues - total antes + lo rechazado. Puede ser negativo: con un
  -- motivo nuestro, lo que habia salido de un combo roto puede volver a el.
  -- Va despues de la anotacion de lotes_devueltos y de la huella de la merma,
  -- que miran SOLO esta linea: mover unidades entre las lineas del pozo antes
  -- las confundiria con huella que perdio el cliente.
  IF v_combo_id IS NOT NULL THEN
    v_combo_rehecho := public._combo_rehacer(p_pedido_id, v_sucursal, v_combo_id, NULL);
    v_recargo_combo := round((SELECT COALESCE(SUM(subtotal), 0) FROM pedido_items
                               WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal
                                 AND (combo_id = v_combo_id OR combo_roto_id = v_combo_id))
                             - v_total_combo_antes + v_monto_afectado, 2);
    UPDATE salvedades_items
       SET recargo_combo = v_recargo_combo,
           combo_detalle = v_combo_rehecho
     WHERE id = v_salvedad_id AND sucursal_id = v_sucursal;
  END IF;

$q$ || v_total || $q$
  INSERT INTO salvedad_historial (salvedad_id, accion, estado_nuevo, notas, usuario_id, sucursal_id)
  VALUES (v_salvedad_id, 'creacion', 'pendiente', p_descripcion, v_usuario_id, v_sucursal);$q$,
    'registrar: el combo y el total, al final');

  v_def := pg_temp.rr_parchar(v_def,
$q$    'es_bonificacion', v_es_bonif,
$q$,
$q$    'es_bonificacion', v_es_bonif,
    'recargo_combo', v_recargo_combo,
$q$, 'registrar: contesta el recargo');

  EXECUTE v_def;
END
$registrar$;

-- -------------------------------------------------------------------------
-- 8 · anular_salvedad
-- -------------------------------------------------------------------------
DO $anular$
DECLARE
  v_def   text := pg_get_functiondef('public.anular_salvedad(bigint,text)'::regprocedure);
  v_total text;
BEGIN
  v_def := pg_temp.rr_parchar(v_def,
$q$  v_g_origen TEXT; v_g_ref_tipo TEXT; v_g_ref_id TEXT; v_g_user TEXT; v_g_item TEXT;
BEGIN$q$,
$q$  v_g_origen TEXT; v_g_ref_tipo TEXT; v_g_ref_id TEXT; v_g_user TEXT; v_g_item TEXT;
  -- #1192: el combo de la salvedad.
  v_combo_rehecho JSONB;
  v_precio_combo  JSONB;
BEGIN$q$, 'anular: declaraciones');

  -- La linea borrada de un combo vuelve a su pozo (a cualquier precio: rehacer
  -- el combo la pone en su lugar). Una que no es de un combo no se suma a una
  -- que si lo es.
  v_def := pg_temp.rr_parchar(v_def,
$q$       AND pi.precio_unitario = v_salvedad.precio_unitario
     ORDER BY pi.id
     LIMIT 1
       FOR UPDATE;$q$,
$q$       -- #1192: la de un combo vuelve a su pozo, a cualquier precio (rehacer
       -- el combo la pone en su lugar); la que no es de un combo no se suma a
       -- una que si lo es.
       AND CASE WHEN v_salvedad.combo_id IS NULL
                THEN pi.precio_unitario = v_salvedad.precio_unitario
                     AND pi.combo_id IS NULL AND pi.combo_roto_id IS NULL
                ELSE v_salvedad.combo_id IN (pi.combo_id, pi.combo_roto_id) END
     ORDER BY (pi.combo_id IS NOT DISTINCT FROM v_salvedad.combo_id) DESC, pi.id
     LIMIT 1
       FOR UPDATE;$q$, 'anular: la linea borrada vuelve a su pozo');

  v_def := pg_temp.rr_parchar(v_def,
$q$    SELECT d.neto, d.iva, d.ingreso_real INTO v_neto, v_iva, v_real
      FROM calcular_desglose_venta(v_salvedad.precio_unitario, v_pct_iva, v_pct_ii, v_tipo_factura) d;
$q$,
$q$    SELECT d.neto, d.iva, d.ingreso_real INTO v_neto, v_iva, v_real
      FROM calcular_desglose_venta(v_salvedad.precio_unitario, v_pct_iva, v_pct_ii, v_tipo_factura) d;
    -- #1192: sin linea en el pozo, vuelve como linea del combo si estaba a
    -- precio de combo, o como la parte que salio de el si no.
    IF v_salvedad.combo_id IS NOT NULL THEN
      SELECT f.precios->(v_salvedad.producto_id::text) INTO v_precio_combo
        FROM pedido_combos f
       WHERE f.pedido_id = v_salvedad.pedido_id AND f.combo_id = v_salvedad.combo_id
         AND f.sucursal_id = v_sucursal;
      IF NOT (v_salvedad.precio_unitario = (v_precio_combo->>'combo')::numeric
              AND COALESCE((v_precio_combo->>'sin_combo')::numeric, 0) > 0) THEN
        v_precio_combo := NULL;
      END IF;
    END IF;
$q$, 'anular: los precios de la foto');

  v_def := pg_temp.rr_parchar(v_def,
$q$      ingreso_real_unitario, costo_unitario_al_crear,
      es_bonificacion, promocion_id
    )$q$,
$q$      ingreso_real_unitario, costo_unitario_al_crear,
      es_bonificacion, promocion_id,
      combo_id, precio_sin_combo_unitario, combo_roto_id
    )$q$, 'anular: columnas del pozo');
  v_def := pg_temp.rr_parchar(v_def,
$q$      COALESCE(v_salvedad.es_bonificacion, FALSE), v_salvedad.promocion_id
    ) RETURNING id INTO v_item_id;$q$,
$q$      COALESCE(v_salvedad.es_bonificacion, FALSE), v_salvedad.promocion_id,
      CASE WHEN v_precio_combo IS NOT NULL THEN v_salvedad.combo_id END,
      CASE WHEN v_precio_combo IS NOT NULL THEN (v_precio_combo->>'sin_combo')::numeric END,
      CASE WHEN v_salvedad.combo_id IS NOT NULL AND v_precio_combo IS NULL THEN v_salvedad.combo_id END
    ) RETURNING id INTO v_item_id;$q$, 'anular: valores del pozo');

  -- El total, al final: despues de reponer la huella y de rehacer el combo.
  v_total := pg_temp.rr_bloque(v_def,
$q$  UPDATE pedidos SET
    total = (SELECT COALESCE(SUM(subtotal), 0) FROM pedido_items WHERE pedido_id = v_salvedad.pedido_id AND sucursal_id = v_sucursal),
$q$,
$q$    updated_at = NOW()
  WHERE id = v_salvedad.pedido_id AND sucursal_id = v_sucursal;
$q$, 'anular: el bloque del total');
  v_def := pg_temp.rr_parchar(v_def, v_total,
$q$  -- #1192: el total se recalcula al final, despues de rehacer el combo.
$q$, 'anular: sale el total de aca');
  v_total := pg_temp.rr_parchar(v_total,
$q$    updated_at = NOW()
  WHERE id = v_salvedad.pedido_id$q$,
$q$    -- CLAUDE.md: el UPDATE que cambia el total de un vale blanco nombra
    -- monto_pagado en el SET.
    monto_pagado = CASE WHEN pedidos.tipo_factura = 'VB'
                        THEN (SELECT COALESCE(SUM(subtotal), 0) FROM pedido_items
                               WHERE pedido_id = v_salvedad.pedido_id AND sucursal_id = v_sucursal)
                        ELSE pedidos.monto_pagado END,
    updated_at = NOW()
  WHERE id = v_salvedad.pedido_id$q$, 'anular: monto_pagado del vale blanco');

  v_def := pg_temp.rr_parchar(v_def,
$q$  /* mig 244: la merma se anula, y productos.stock NO se toca.$q$,
$q$  -- #1192: el combo se rehace SIN esta salvedad: lo que el cliente habia
  -- rechazado vuelve, y si eso rearma combos, lo que habia salido de ellos
  -- vuelve al precio de combo. Rehacer es una funcion del estado, asi que
  -- anular en cualquier orden deja el pedido como si la salvedad no hubiera
  -- existido. Va despues de reponer la huella de la linea (que la mira sola).
  IF v_salvedad.combo_id IS NOT NULL THEN
    v_combo_rehecho := public._combo_rehacer(v_salvedad.pedido_id, v_sucursal, v_salvedad.combo_id,
                                             p_salvedad_id);
    IF v_combo_rehecho IS NOT NULL THEN
      UPDATE salvedades_items
         SET combo_detalle = COALESCE(combo_detalle, '{}'::jsonb)
                             || jsonb_build_object('anulacion', v_combo_rehecho)
       WHERE id = p_salvedad_id AND sucursal_id = v_sucursal;
    END IF;
  END IF;

$q$ || v_total || $q$
  /* mig 244: la merma se anula, y productos.stock NO se toca.$q$, 'anular: el combo y el total, al final');

  EXECUTE v_def;
END
$anular$;

-- -------------------------------------------------------------------------
-- 9 · PRECIO-A exime a _combo_partir; COMBO-B en auditoria_integridad
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.auditoria_funciones_pedido_items_sin_piso()
 RETURNS bigint
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT count(*)
    FROM pg_proc f
   WHERE f.pronamespace = 'public'::regnamespace
     AND f.prokind = 'f'
     -- #1192: _combo_partir parte una linea del pozo de un combo al precio de
     -- la foto del pedido (con o sin combo): no vende nada nuevo.
     AND f.proname NOT IN ('crear_pedido_completo_bot', 'dividir_regalo_pedido', 'anular_salvedad',
                           '_combo_partir')
     AND pg_get_functiondef(f.oid) ~* 'INSERT\s+INTO\s+(public\.)?pedido_items[\s(]'
     AND pg_get_functiondef(f.oid) NOT ILIKE '%precio_fuera_de_politica%';
$function$;

DO $audit$
DECLARE
  v_def text := pg_get_functiondef('public.auditoria_integridad()'::regprocedure);
BEGIN
  v_def := pg_temp.rr_parchar(v_def,
$q$                  > f.cantidad_combos * (lug.c->>'cantidad')::int)))
  )$q$,
$q$                  > f.cantidad_combos * (lug.c->>'cantidad')::int))),
    -- #1192 · cada combo de un pedido vivo esta en el punto fijo de la regla de
    -- la salvedad: rehacerlo no moveria nada (los combos vivos, el recargo y
    -- lo que hay en el combo de cada producto son los del plan), y toda linea
    -- que salio de un combo roto tiene la foto de su combo.
    ('COMBO-B','high','combos de pedidos vivos en el reparto que manda la salvedad (#1192)',
      (SELECT count(*) FROM pedido_combos f
         JOIN pedidos p ON p.id = f.pedido_id AND p.sucursal_id = f.sucursal_id
         CROSS JOIN LATERAL (SELECT public._combo_estado(f.pedido_id, f.sucursal_id, f.combo_id, NULL) AS e) x
         CROSS JOIN LATERAL (SELECT public._combo_plan(x.e->'componentes', (x.e->>'armados')::int, x.e->'lineas',
                                                       x.e->'rechazos', x.e->'precios') AS pl) y
        WHERE p.estado NOT IN ('cancelado','anulado')
          AND (y.pl IS NULL
               OR f.cantidad_combos IS DISTINCT FROM (y.pl->>'combos')::int
               OR f.recargo IS DISTINCT FROM (y.pl->>'recargo')::numeric
               OR EXISTS (SELECT 1 FROM jsonb_array_elements(x.e->'lineas') l
                           WHERE (l->>'en_combo')::int
                                 IS DISTINCT FROM (y.pl->'productos'->(l->>'producto_id')->>'en_combo')::int)))
       + (SELECT count(*) FROM pedido_items pi
           WHERE pi.combo_roto_id IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM pedido_combos f
                              WHERE f.pedido_id = pi.pedido_id AND f.combo_id = pi.combo_roto_id
                                AND f.sucursal_id = pi.sucursal_id)))
  )$q$, 'auditoria: COMBO-B');
  EXECUTE v_def;
END
$audit$;

-- -------------------------------------------------------------------------
-- 10 · Permisos de las funciones nuevas
-- -------------------------------------------------------------------------
-- Las de server: a nadie del front (las tres mitades) y service_role, como la 380.
REVOKE ALL ON FUNCTION public._combo_plan(jsonb, integer, jsonb, jsonb, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._combo_origen(boolean, numeric, numeric, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._combo_estado(bigint, bigint, bigint, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._combo_mover_huella(bigint, bigint, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._combo_trasladar(bigint, bigint, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._combo_sabor(bigint, bigint, boolean, jsonb, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._combo_partir(bigint, integer, bigint, boolean, jsonb, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._combo_aplicar(bigint, bigint, bigint, jsonb, jsonb, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._combo_rehacer(bigint, bigint, bigint, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._combo_plan(jsonb, integer, jsonb, jsonb, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public._combo_origen(boolean, numeric, numeric, boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public._combo_estado(bigint, bigint, bigint, bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public._combo_mover_huella(bigint, bigint, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public._combo_trasladar(bigint, bigint, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public._combo_sabor(bigint, bigint, boolean, jsonb, boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public._combo_partir(bigint, integer, bigint, boolean, jsonb, boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public._combo_aplicar(bigint, bigint, bigint, jsonb, jsonb, boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public._combo_rehacer(bigint, bigint, bigint, bigint) TO service_role;
-- La del front: authenticated (el chofer), sin anon.
REVOKE ALL ON FUNCTION public.simular_salvedades_combo_impacto(bigint, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.simular_salvedades_combo_impacto(bigint, jsonb) TO authenticated, service_role;

-- -------------------------------------------------------------------------
-- 11 · Verificacion estructural
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  f   text;
  v_r text := pg_get_functiondef(
    'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure);
  v_a text := pg_get_functiondef('public.anular_salvedad(bigint,text)'::regprocedure);
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public._combo_plan(jsonb,integer,jsonb,jsonb,jsonb)', 'public._combo_origen(boolean,numeric,numeric,boolean)',
    'public._combo_estado(bigint,bigint,bigint,bigint)', 'public._combo_mover_huella(bigint,bigint,integer)',
    'public._combo_trasladar(bigint,bigint,integer)', 'public._combo_sabor(bigint,bigint,boolean,jsonb,boolean)',
    'public._combo_partir(bigint,integer,bigint,boolean,jsonb,boolean)',
    'public._combo_aplicar(bigint,bigint,bigint,jsonb,jsonb,boolean)',
    'public._combo_rehacer(bigint,bigint,bigint,bigint)'] LOOP
    IF has_function_privilege('anon', f, 'EXECUTE') OR has_function_privilege('authenticated', f, 'EXECUTE') THEN
      RAISE EXCEPTION '% quedo alcanzable desde el front', f;
    END IF;
  END LOOP;
  IF has_function_privilege('anon', 'public.simular_salvedades_combo_impacto(bigint,jsonb)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.simular_salvedades_combo_impacto(bigint,jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'los EXECUTE de simular_salvedades_combo_impacto no quedaron como se esperaba';
  END IF;
  IF NOT has_column_privilege('authenticated', 'public.pedido_items', 'combo_roto_id', 'SELECT')
     OR has_column_privilege('authenticated', 'public.pedido_items', 'costo_unitario_al_crear', 'SELECT') THEN
    RAISE EXCEPTION 'las columnas de pedido_items no quedaron como se esperaba';
  END IF;
  IF has_table_privilege('authenticated', 'public.salvedades_items', 'INSERT')
     OR has_table_privilege('authenticated', 'public.salvedades_items', 'UPDATE') THEN
    RAISE EXCEPTION 'salvedades_items quedo con escritura REST';
  END IF;
  -- Las dos funciones de la salvedad, rehechas y siguen siendo DEFINER.
  IF position('_combo_rehacer' IN v_r) = 0 OR position('_combo_trasladar' IN v_r) = 0
     OR position('monto_pagado = CASE' IN v_r) = 0
     OR position('_combo_rehacer' IN v_a) = 0 OR position('monto_pagado = CASE' IN v_a) = 0 THEN
    RAISE EXCEPTION 'registrar_salvedad o anular_salvedad no quedaron como se esperaba';
  END IF;
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.anular_salvedad(bigint,text)'::regprocedure)
     OR NOT (SELECT prosecdef FROM pg_proc
              WHERE oid = 'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure) THEN
    RAISE EXCEPTION 'las funciones de la salvedad dejaron de ser SECURITY DEFINER';
  END IF;
  -- La pura: 2 combos 1 + 1, el cliente rechaza 1 Coca (producto 2): queda 1
  -- combo y 1 Fernet (producto 1) sale, con recargo 10000 - 8800 = 1200.
  IF public._combo_plan(
       '[{"componente":1,"cantidad":1,"productos":[1]},{"componente":2,"cantidad":1,"productos":[2]}]', 2,
       '[{"producto_id":1,"en_combo":2,"fuera":0},{"producto_id":2,"en_combo":1,"fuera":0}]',
       '[{"producto_id":2,"cantidad":1}]',
       '{"1":{"combo":8800,"sin_combo":10000},"2":{"combo":2200,"sin_combo":2500}}')
     IS DISTINCT FROM '{"combos":1,"recargo":1200,"productos":{"1":{"en_combo":1,"fuera":1},"2":{"en_combo":1,"fuera":0}}}'::jsonb
  -- Un rechazo nuestro no le resta combos a nadie.
     OR public._combo_plan(
       '[{"componente":1,"cantidad":1,"productos":[1]},{"componente":2,"cantidad":1,"productos":[2]}]', 2,
       '[{"producto_id":1,"en_combo":2,"fuera":0},{"producto_id":2,"en_combo":1,"fuera":0}]',
       '[]',
       '{"1":{"combo":8800,"sin_combo":10000},"2":{"combo":2200,"sin_combo":2500}}')
     IS DISTINCT FROM '{"combos":2,"recargo":0,"productos":{"1":{"en_combo":2,"fuera":0},"2":{"en_combo":1,"fuera":0}}}'::jsonb THEN
    RAISE EXCEPTION 'la regla del combo roto no da lo esperado';
  END IF;
END
$verif$;
