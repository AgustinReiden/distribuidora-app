-- 272 — Un regalo se puede repartir en varios sabores (#831, caso Munay)
--
-- Se entregaron 15 fardos de regalo y el cliente los quiso repartidos en varios
-- sabores. `sustituir_regalo_pedido` cambia UNA linea por UN producto, asi que
-- no habia forma de hacerlo sin editar a mano.
--
-- §1 `pedido_item_sustituciones.reparto_id`: las N filas de un reparto comparten
--    ese uuid. Una fila por parte, TODAS con el mismo producto_original_id y
--    cantidad_original (la linea que se repartio) -- incluida la parte que se
--    queda con el producto original, que queda como X→X.
--
-- §2 `regalo_sustituto_vigente()`: la regla de "que sustituto le toca a este
--    regalo" vivia copiada en dos lugares -- el trigger de pre-insert y el
--    pre-chequeo de stock de actualizar_pedido_items -- con un LIMIT 1 cada uno.
--    Con un reparto ese LIMIT 1 COLAPSA: la parte que se quedo con el sabor
--    original (X) matchea las N filas X→*, toma una cualquiera (mismo
--    created_at) y reescribe la linea a otro sabor. Y ni hace falta que X sea
--    parte: una sustitucion vieja C→D (anterior al reparto) le reescribe a D la
--    parte C recien insertada.
--    La regla nueva: se mira la fila mas nueva de la promo en el pedido que sea
--    del producto O de un reparto. Si es de un reparto, el reparto es la ultima
--    decision sobre la composicion del regalo y ninguna sustitucion anterior
--    vale: no se reescribe nada. Una sustitucion simple POSTERIOR al reparto
--    (cambiar una de las partes) sigue valiendo para su producto.
--
-- §3 `dividir_regalo_pedido()`: la RPC. Una transaccion, mismas guardas que
--    sustituir (admin/encargado, no entregado, regalo con promo) mas cancelado
--    y anulado -- ahi el stock ya se devolvio y repartir lo devolveria otra
--    vez --. La suma de las partes tiene que ser IGUAL a la cantidad de la
--    linea, en su misma unidad: si la linea esta en subunidades (promo
--    Fraccion), se reparte en subunidades y las partes heredan
--    `unidades_por_bloque_al_crear`. Stock y acumuladores se mueven por el
--    NETO de cada producto (la parte que se queda con X no devuelve y vuelve a
--    tomar lo mismo), con las mismas herramientas que sustituir: modo A
--    etiquetado 'sustitucion_regalo' (lista blanca de trg_lotes_sincronizar),
--    modo B por aplicar_uso_promo_acumulador. Costo con costo_valuacion
--    (COSTO-D).
--
-- §4 `actualizar_pedido_items`: la edicion no colapsa el reparto. El front
--    recalcula el regalo desde la promo y manda UNA linea; si el pedido tiene
--    varias lineas de regalo de esa promo y la cantidad total no cambio, se
--    guardan las lineas que ya estaban. Si la cantidad cambio, manda lo que
--    vino (no hay forma honesta de repartir una cantidad nueva). Esto cubre
--    tambien a un bundle viejo del PWA, que no sabe de repartos. Las lineas
--    conservadas mantienen su `descripcion_regalo`: sin ella todas las partes
--    se imprimian con el mismo texto de la promo y el chofer no sabia que
--    sabor cargar. Incluye el `FOR UPDATE` del pedido (#826).
--
-- §5 Salvedades con N lineas: la resincronizacion de registrar_salvedad
--    comparaba CADA linea de regalo contra el total esperado de la promo. Con
--    5+5+5 y un esperado de 10 no recortaba nada; con esperado 3 dejaba 3+3+3.
--    Ahora el exceso se calcula por promo y se recorta de las lineas mas
--    nuevas hacia atras. Las dos simulaciones usan la misma regla. Con una
--    sola linea el resultado es identico al de antes.

-- ─── §1 ──────────────────────────────────────────────────────────────────────

ALTER TABLE public.pedido_item_sustituciones
  ADD COLUMN IF NOT EXISTS reparto_id uuid;

COMMENT ON COLUMN public.pedido_item_sustituciones.reparto_id IS
  'Agrupa las filas de un reparto del regalo en varios sabores (dividir_regalo_pedido, mig 272). NULL = sustitucion simple.';

CREATE INDEX IF NOT EXISTS idx_pedido_sustituciones_pedido_promo
  ON public.pedido_item_sustituciones (pedido_id, promocion_id, created_at DESC, id DESC);

-- ─── §2 ──────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.regalo_sustituto_vigente(
  p_pedido_id   bigint,
  p_promocion_id bigint,
  p_producto_id bigint,
  p_sucursal_id bigint
)
RETURNS bigint
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  -- NULL = el regalo se guarda con el producto que vino. Ver la cabecera §2.
  SELECT CASE WHEN s.reparto_id IS NULL THEN s.producto_sustituto_id END
    FROM pedido_item_sustituciones s
   WHERE s.pedido_id = p_pedido_id
     AND s.promocion_id = p_promocion_id
     AND s.sucursal_id = p_sucursal_id
     AND (s.producto_original_id = p_producto_id OR s.reparto_id IS NOT NULL)
   ORDER BY s.created_at DESC, s.id DESC
   LIMIT 1;
$$;

-- Solo la llaman funciones del server (el trigger y actualizar_pedido_items,
-- las dos SECURITY DEFINER): se revoca a las tres.
REVOKE ALL ON FUNCTION public.regalo_sustituto_vigente(bigint, bigint, bigint, bigint)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.aplicar_sustituciones_regalo_pre_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sustituto BIGINT;
  v_nombre_sustituto TEXT;
  v_costo_sustituto NUMERIC;
BEGIN
  IF NOT COALESCE(NEW.es_bonificacion, FALSE) THEN
    RETURN NEW;
  END IF;
  IF NEW.promocion_id IS NULL THEN
    RETURN NEW;
  END IF;
  -- mig 272 (#831): era un LIMIT 1 sobre producto_original_id, que colapsaba
  -- un reparto al sabor de una de sus filas. La regla vive en un solo lugar.
  v_sustituto := public.regalo_sustituto_vigente(
    NEW.pedido_id, NEW.promocion_id, NEW.producto_id, NEW.sucursal_id);
  IF v_sustituto IS NOT NULL THEN
    IF COALESCE(NEW.descripcion_regalo, '') NOT LIKE '%[Sustituido por:%' THEN
      SELECT nombre INTO v_nombre_sustituto
        FROM productos
       WHERE id = v_sustituto
         AND sucursal_id = NEW.sucursal_id;
      NEW.descripcion_regalo := COALESCE(NEW.descripcion_regalo, '') ||
                                ' [Sustituido por: ' || COALESCE(v_nombre_sustituto, '?') || ']';
    END IF;
    NEW.producto_id := v_sustituto;

    -- El costo tiene que seguir al producto (issue #537). Quien llamo al INSERT
    -- snapshoteo el costo del producto ORIGINAL, que a partir de esta linea ya
    -- no es el de la fila. Misma cascada que usa reporte_gerencial.
    -- mig 257 (#673): la cascada es la de costo_valuacion (mig 238) y no una
    -- copia. Sin snapshot previo: esto ES el snapshot.
    SELECT public.costo_valuacion(NULL, costo_promedio, costo_real, costo_sin_iva,
                                  COALESCE(impuestos_internos, 0))
      INTO v_costo_sustituto
      FROM productos
     WHERE id = v_sustituto
       AND sucursal_id = NEW.sucursal_id;

    -- Si el sustituto no tiene ningun costo cargado, dejar NULL antes que dejar
    -- el del original: NULL hace que el reporte caiga al costo vivo del producto
    -- correcto, y un numero equivocado no.
    NEW.costo_unitario_al_crear := v_costo_sustituto;
  END IF;
  RETURN NEW;
END;
$function$;

-- ─── §3 ──────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.dividir_regalo_pedido(
  p_pedido_item_id    bigint,
  p_partes            jsonb,
  p_motivo            text,
  p_client_request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id            UUID := auth.uid();
  v_user_role          TEXT;
  v_sucursal           BIGINT := current_sucursal_id();
  v_item               RECORD;
  v_promo              RECORD;
  v_regalo_mueve_stock BOOLEAN;
  v_existing           RECORD;
  v_reparto            UUID := gen_random_uuid();
  v_n                  INT;
  v_suma               NUMERIC;
  v_parte              RECORD;
  v_neto               RECORD;
  v_stock              NUMERIC;
  v_nombre             TEXT;
  v_desc_base          TEXT;
  v_desc               TEXT;
  v_parte_en_linea     BIGINT;
  v_nuevo_id           BIGINT;
  v_item_ids           BIGINT[] := '{}';
  v_sust_ids           BIGINT[] := '{}';
  v_sust_id            BIGINT;
  v_primera            BOOLEAN := TRUE;
  v_detalle            TEXT;
  v_prod               BIGINT[];
  v_cant               NUMERIC[];
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No hay sucursal activa');
  END IF;
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autenticado');
  END IF;
  -- Idempotencia: el client_request_id va en la PRIMERA fila del reparto (el
  -- indice unico es por fila, y las N comparten reparto_id).
  IF p_client_request_id IS NOT NULL THEN
    SELECT id, reparto_id INTO v_existing
      FROM pedido_item_sustituciones
     WHERE client_request_id = p_client_request_id;
    IF FOUND THEN
      RETURN jsonb_build_object('success', true, 'sustitucion_id', v_existing.id,
        'reparto_id', v_existing.reparto_id, 'idempotent_replay', true);
    END IF;
  END IF;
  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_user_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin o encargado pueden repartir regalos');
  END IF;
  IF p_motivo IS NULL OR btrim(p_motivo) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Falta el motivo del reparto');
  END IF;

  -- ── Las partes ──
  IF p_partes IS NULL OR jsonb_typeof(p_partes) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Las partes tienen que ser una lista');
  END IF;
  BEGIN
    SELECT array_agg((e->>'producto_id')::bigint ORDER BY o),
           array_agg((e->>'cantidad')::numeric ORDER BY o)
      INTO v_prod, v_cant
      FROM jsonb_array_elements(p_partes) WITH ORDINALITY AS x(e, o);
  EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    RETURN jsonb_build_object('success', false, 'error', 'Hay una parte con producto o cantidad invalidos');
  END;
  v_n := COALESCE(array_length(v_prod, 1), 0);
  IF v_n < 2 THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Un reparto necesita al menos dos productos. Para cambiar el regalo por uno solo, usa la sustitucion.');
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(v_prod, v_cant) AS t(producto_id, cantidad)
              WHERE producto_id IS NULL OR cantidad IS NULL OR cantidad <= 0
                 OR cantidad <> trunc(cantidad)) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Cada parte necesita un producto y una cantidad entera mayor a 0');
  END IF;
  IF (SELECT count(DISTINCT x) FROM unnest(v_prod) AS x) <> v_n THEN
    RETURN jsonb_build_object('success', false, 'error', 'Hay un producto repetido en el reparto');
  END IF;
  SELECT sum(x) INTO v_suma FROM unnest(v_cant) AS x;

  -- ── La linea (y el pedido: FOR UPDATE bloquea las dos filas del JOIN) ──
  SELECT pi.id, pi.pedido_id, pi.producto_id, pi.cantidad, pi.es_bonificacion,
         pi.promocion_id, pi.sucursal_id, pi.descripcion_regalo, pi.precio_unitario,
         pi.neto_unitario, pi.iva_unitario, pi.impuestos_internos_unitario,
         pi.porcentaje_iva, pi.ingreso_real_unitario, pi.origen_precio,
         pi.unidades_por_bloque_al_crear, pi.origen_unidades_por_bloque,
         p.estado AS pedido_estado
    INTO v_item
    FROM pedido_items pi
    JOIN pedidos p ON p.id = pi.pedido_id
   WHERE pi.id = p_pedido_item_id AND pi.sucursal_id = v_sucursal
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Item no encontrado');
  END IF;
  IF NOT COALESCE(v_item.es_bonificacion, FALSE) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo se pueden repartir items marcados como bonificacion');
  END IF;
  IF v_item.pedido_estado = 'entregado' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se puede repartir un regalo en un pedido ya entregado');
  END IF;
  -- A diferencia de sustituir: un cancelado ya tiene el stock devuelto, y
  -- repartir lo devolveria otra vez.
  IF v_item.pedido_estado IN ('cancelado', 'anulado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se puede repartir un regalo de un pedido cancelado');
  END IF;
  IF v_item.promocion_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Este regalo no viene de una promoción, así que no se puede repartir desde acá. Editá el pedido para cambiarlo.');
  END IF;
  IF v_suma <> v_item.cantidad THEN
    RETURN jsonb_build_object('success', false, 'error',
      'La suma de las partes (' || v_suma || ') tiene que ser igual a la cantidad del regalo (' || v_item.cantidad || ')');
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(v_prod) AS r(producto_id)
              WHERE NOT EXISTS (SELECT 1 FROM productos pr
                                 WHERE pr.id = r.producto_id AND pr.sucursal_id = v_sucursal)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Hay un producto del reparto que no existe en esta sucursal');
  END IF;

  SELECT id, regalo_mueve_stock, ajuste_automatico, producto_regalo_id,
         ajuste_producto_id, unidades_por_bloque, stock_por_bloque, usos_pendientes
    INTO v_promo FROM promociones WHERE id = v_item.promocion_id AND sucursal_id = v_sucursal;
  v_regalo_mueve_stock := COALESCE(v_promo.regalo_mueve_stock, TRUE);

  -- Consumo NETO por producto: lo que se lleva cada parte menos lo que vuelve
  -- de la linea original. La parte que se queda con el producto original no
  -- devuelve Q para volver a tomar x: mueve x - Q.
  -- Se calcula en cada FOR de abajo con la misma subconsulta.

  -- Stock ANTES de mover nada: las validaciones devuelven {success:false} sin
  -- RAISE, asi que no puede haber quedado nada a medio hacer.
  IF v_regalo_mueve_stock THEN
    FOR v_neto IN SELECT producto_id, consumo
                   FROM (SELECT t.producto_id, sum(t.c) AS consumo
                           FROM (SELECT u.producto_id, u.cantidad AS c
                                   FROM unnest(v_prod, v_cant) AS u(producto_id, cantidad)
                                 UNION ALL
                                 SELECT v_item.producto_id, -v_item.cantidad) t
                          GROUP BY t.producto_id) n
                  WHERE consumo > 0
                  ORDER BY producto_id LOOP
      SELECT stock, nombre INTO v_stock, v_nombre
        FROM productos WHERE id = v_neto.producto_id AND sucursal_id = v_sucursal FOR UPDATE;
      IF v_stock < v_neto.consumo THEN
        RETURN jsonb_build_object('success', false, 'error',
          'Stock insuficiente de ' || COALESCE(v_nombre, 'producto ' || v_neto.producto_id)
          || ' (' || v_stock || ' disponible, se necesitan ' || v_neto.consumo || ')');
      END IF;
    END LOOP;
  END IF;

  -- ── El registro, ANTES de insertar las partes ──
  -- El trigger de pre-insert mira esta tabla: con el reparto ya registrado,
  -- regalo_sustituto_vigente() lo ve como la ultima decision y no reescribe
  -- ninguna de las partes que se insertan abajo.
  FOR v_parte IN SELECT orden, producto_id, cantidad
                   FROM unnest(v_prod, v_cant) WITH ORDINALITY AS u(producto_id, cantidad, orden)
                  ORDER BY orden LOOP
    INSERT INTO pedido_item_sustituciones (
      pedido_id, pedido_item_id, promocion_id, producto_original_id, producto_sustituto_id,
      cantidad_original, cantidad_sustituta, regalo_mueve_stock_snapshot, ajuste_producto_id_nuevo,
      motivo, autorizado_por, sucursal_id, client_request_id, reparto_id
    ) VALUES (
      v_item.pedido_id, p_pedido_item_id, v_item.promocion_id, v_item.producto_id, v_parte.producto_id,
      v_item.cantidad, v_parte.cantidad, v_regalo_mueve_stock,
      CASE WHEN v_regalo_mueve_stock THEN NULL
           WHEN v_parte.producto_id = v_item.producto_id THEN v_promo.ajuste_producto_id
           ELSE v_parte.producto_id END,
      p_motivo, v_user_id, v_sucursal,
      CASE WHEN v_primera THEN p_client_request_id END, v_reparto
    ) RETURNING id INTO v_sust_id;
    v_sust_ids := v_sust_ids || v_sust_id;
    v_primera := FALSE;
  END LOOP;

  -- ── Stock / acumuladores por el neto ──
  IF v_regalo_mueve_stock THEN
    -- 'sustitucion_regalo' esta en la lista blanca de trg_lotes_sincronizar: lo
    -- que vuelve del original vuelve a su lote (FEFO). Las bajadas no miran el
    -- origen. Primero las devoluciones, despues las bajadas.
    PERFORM set_config('app.stock_origen', 'sustitucion_regalo', true);
    PERFORM set_config('app.stock_ref_tipo', 'pedido', true);
    PERFORM set_config('app.stock_ref_id', v_item.pedido_id::TEXT, true);
    PERFORM set_config('app.stock_user_id', v_user_id::TEXT, true);
    FOR v_neto IN SELECT producto_id, consumo
                   FROM (SELECT t.producto_id, sum(t.c) AS consumo
                           FROM (SELECT u.producto_id, u.cantidad AS c
                                   FROM unnest(v_prod, v_cant) AS u(producto_id, cantidad)
                                 UNION ALL
                                 SELECT v_item.producto_id, -v_item.cantidad) t
                          GROUP BY t.producto_id) n
                  WHERE consumo <> 0
                  ORDER BY consumo, producto_id LOOP
      UPDATE productos SET stock = stock - v_neto.consumo
       WHERE id = v_neto.producto_id AND sucursal_id = v_sucursal;
    END LOOP;
  ELSE
    -- Mismo helper y mismo contenedor por defecto que sustituir_regalo_pedido:
    -- la salida del original contra el contenedor de la promo, cada sabor
    -- nuevo contra si mismo. La barra default vive en promociones (mig 221).
    FOR v_neto IN SELECT producto_id, consumo
                   FROM (SELECT t.producto_id, sum(t.c) AS consumo
                           FROM (SELECT u.producto_id, u.cantidad AS c
                                   FROM unnest(v_prod, v_cant) AS u(producto_id, cantidad)
                                 UNION ALL
                                 SELECT v_item.producto_id, -v_item.cantidad) t
                          GROUP BY t.producto_id) n
                  WHERE consumo <> 0
                  ORDER BY consumo, producto_id LOOP
      PERFORM public.aplicar_uso_promo_acumulador(
        v_promo.id, v_neto.producto_id, v_neto.consumo,
        CASE WHEN v_neto.producto_id = v_item.producto_id
             THEN v_promo.ajuste_producto_id ELSE v_neto.producto_id END,
        v_sucursal, v_user_id,
        CASE WHEN v_neto.consumo < 0
             THEN 'reparto: salida del producto regalo original'
             ELSE 'reparto: entrada de un sabor del regalo' END
      );
    END LOOP;
  END IF;

  -- ── Las lineas ──
  -- La parte que se queda con el producto original ocupa la linea original; si
  -- no hay, la primera. El resto son lineas nuevas con la misma promo, la
  -- misma unidad y el mismo origen de precio.
  v_parte_en_linea := COALESCE(array_position(v_prod, v_item.producto_id), 1);

  -- La descripcion arranca de la de la promo, sin las marcas de sustituciones
  -- anteriores: cada parte lleva la suya, y es lo que distingue los sabores en
  -- la hoja de ruta.
  v_desc_base := btrim(regexp_replace(COALESCE(v_item.descripcion_regalo, ''),
                                      '\s*\[Sustituido por:[^\]]*\]', '', 'g'));

  FOR v_parte IN SELECT r.orden, r.producto_id, r.cantidad, pr.nombre
                   FROM unnest(v_prod, v_cant) WITH ORDINALITY AS r(producto_id, cantidad, orden)
                   JOIN productos pr ON pr.id = r.producto_id AND pr.sucursal_id = v_sucursal
                  ORDER BY (r.orden <> v_parte_en_linea), r.orden LOOP
    IF v_parte.producto_id = v_item.producto_id THEN
      v_desc := v_item.descripcion_regalo;
    ELSE
      v_desc := btrim(v_desc_base || ' [Sustituido por: ' || COALESCE(v_parte.nombre, '?') || ']');
    END IF;

    IF v_parte.orden = v_parte_en_linea THEN
      UPDATE pedido_items
         SET producto_id = v_parte.producto_id,
             cantidad = v_parte.cantidad::int,
             subtotal = 0,
             descripcion_regalo = v_desc,
             -- COSTO-D: la cascada unica de la 238.
             costo_unitario_al_crear = (SELECT public.costo_valuacion(NULL, costo_promedio,
                                                 costo_real, costo_sin_iva,
                                                 COALESCE(impuestos_internos, 0))
                                          FROM productos
                                         WHERE id = v_parte.producto_id AND sucursal_id = v_sucursal)
       WHERE id = p_pedido_item_id;
      v_item_ids := v_item_ids || p_pedido_item_id;
    ELSE
      INSERT INTO pedido_items (
        pedido_id, producto_id, cantidad, precio_unitario, subtotal,
        es_bonificacion, promocion_id,
        neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva,
        ingreso_real_unitario, sucursal_id, descripcion_regalo, origen_precio,
        unidades_por_bloque_al_crear, origen_unidades_por_bloque,
        costo_unitario_al_crear
      ) VALUES (
        v_item.pedido_id, v_parte.producto_id, v_parte.cantidad::int, COALESCE(v_item.precio_unitario, 0), 0,
        TRUE, v_item.promocion_id,
        v_item.neto_unitario, v_item.iva_unitario, v_item.impuestos_internos_unitario, v_item.porcentaje_iva,
        v_item.ingreso_real_unitario, v_sucursal, v_desc, v_item.origen_precio,
        v_item.unidades_por_bloque_al_crear, v_item.origen_unidades_por_bloque,
        (SELECT public.costo_valuacion(NULL, costo_promedio, costo_real, costo_sin_iva,
                                       COALESCE(impuestos_internos, 0))
           FROM productos WHERE id = v_parte.producto_id AND sucursal_id = v_sucursal)
      ) RETURNING id INTO v_nuevo_id;
      v_item_ids := v_item_ids || v_nuevo_id;
    END IF;
  END LOOP;

  SELECT string_agg('producto_id=' || producto_id || ' cantidad=' || cantidad, '; ' ORDER BY orden)
    INTO v_detalle FROM unnest(v_prod, v_cant) WITH ORDINALITY AS u(producto_id, cantidad, orden);
  INSERT INTO pedido_historial (
    pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id
  ) VALUES (
    v_item.pedido_id, v_user_id, 'reparto_regalo',
    'producto_id=' || v_item.producto_id || ' cantidad=' || v_item.cantidad,
    v_detalle || ' motivo=' || p_motivo,
    v_sucursal
  );

  RETURN jsonb_build_object('success', true,
    'sustitucion_id', v_sust_ids[1],
    'sustitucion_ids', to_jsonb(v_sust_ids),
    'reparto_id', v_reparto,
    'pedido_item_ids', to_jsonb(v_item_ids),
    'modo', CASE WHEN v_regalo_mueve_stock THEN 'A' ELSE 'B' END);
EXCEPTION
  WHEN unique_violation THEN
    -- Dos envios simultaneos del mismo reparto: el que perdio la carrera
    -- devuelve el replay, igual que sustituir_regalo_pedido.
    SELECT id, reparto_id INTO v_existing
      FROM pedido_item_sustituciones
     WHERE client_request_id = p_client_request_id;
    IF FOUND THEN
      RETURN jsonb_build_object('success', true, 'sustitucion_id', v_existing.id,
        'reparto_id', v_existing.reparto_id, 'idempotent_replay', true);
    END IF;
    RAISE;
  WHEN raise_exception THEN
    -- P0001: validaciones de negocio de los triggers de pedido_items.
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$function$;

-- La llama el front: se revocan las dos mitades del default y se le da a
-- authenticated (la funcion adentro exige admin/encargado).
REVOKE ALL ON FUNCTION public.dividir_regalo_pedido(bigint, jsonb, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.dividir_regalo_pedido(bigint, jsonb, text, uuid) TO authenticated;

-- ─── §4 ──────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.actualizar_pedido_items(p_pedido_id bigint, p_items_nuevos jsonb, p_usuario_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_item_nuevo JSONB;
  v_producto_id INT;
  v_cantidad_original INT;
  v_cantidad_nueva INT;
  v_diferencia INT;
  v_es_bonificacion BOOLEAN;
  v_stock_actual INT;
  v_producto_nombre TEXT;
  v_total_nuevo DECIMAL := 0;
  v_total_neto_nuevo DECIMAL := 0;
  v_total_iva_nuevo DECIMAL := 0;
  v_total_real_nuevo DECIMAL := 0;
  v_total_anterior DECIMAL;
  v_errores TEXT[] := '{}';
  v_items_originales JSONB;
  v_user_role TEXT;
  v_neto_unitario DECIMAL;
  v_iva_unitario DECIMAL;
  v_ingreso_real DECIMAL;
  v_porcentaje_iva DECIMAL;
  v_precio_unitario DECIMAL;
  v_promocion_id BIGINT;
  v_regalo_mueve_stock BOOLEAN;
  v_descripcion_regalo TEXT;
  v_bonif RECORD;
  v_promo RECORD;
  v_usos_pendientes_actual INT;
  v_bloques_completos INT;
  v_ajustar_usos INT;
  v_ajustar_stock INT;
  v_stock_ajuste_anterior INT;
  v_stock_ajuste_nuevo INT;
  v_ajuste_producto_nombre TEXT;
  v_merma_id BIGINT;
  v_container_id BIGINT;
  -- mig 252 (#653): lo que el trigger de sustituciones dejo REALMENTE en la
  -- fila. Todo lo que mueve stock de aca para abajo se cuelga de este valor,
  -- no del producto_id que vino en el JSON.
  v_producto_guardado BIGINT;
  v_producto_sustituto BIGINT;
  -- mig 257 (#673): el id del renglon que quedo, para poder valuarlo despues
  -- del INSERT --que es cuando recien se sabe de que producto habla--.
  v_pedido_item_guardado BIGINT;
  v_pedido_creator UUID;
  v_pedido_created_at TIMESTAMPTZ;
  v_tipo_factura TEXT;
  v_hora_corte CONSTANT TIME := TIME '15:30';
  v_precio_actual DECIMAL;
  v_costo_actual DECIMAL; v_imp_int_actual DECIMAL; v_costo_al_crear DECIMAL;
  v_costo_real_actual DECIMAL; v_pct_iva_actual DECIMAL;
  v_costo_promedio_actual DECIMAL;
  -- mig 272 (#831): los items que se guardan de verdad. Son p_items_nuevos con
  -- los repartos de regalo conservados (ver abajo).
  v_items JSONB;
  v_reparto RECORD;
  v_total_json INT;
  v_n_json INT;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['No se pudo determinar la sucursal activa']);
  END IF;
  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['ID de usuario no coincide con la sesion autenticada']);
  END IF;
  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado', 'preventista') THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['No autorizado']);
  END IF;

  -- #826: FOR UPDATE serializa dos ediciones del mismo pedido.
  SELECT total, usuario_id, created_at, COALESCE(tipo_factura, 'ZZ')
    INTO v_total_anterior, v_pedido_creator, v_pedido_created_at, v_tipo_factura
    FROM pedidos
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['Pedido no encontrado']);
  END IF;

  IF EXISTS (SELECT 1 FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal AND estado = 'entregado') THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['No se puede editar un pedido ya entregado']);
  END IF;

  -- mig 181: un cancelado ya tiene el stock devuelto y el total en 0. Editarlo
  -- lo devolvia por segunda vez y le resucitaba el total.
  IF EXISTS (SELECT 1 FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal
               AND estado IN ('cancelado', 'anulado')) THEN
    RETURN jsonb_build_object('success', false, 'errores',
      ARRAY['No se puede editar un pedido cancelado. Crea uno nuevo.']);
  END IF;

  -- mig 181: si la ruta ya salio, los fardos estan arriba del camion. El
  -- preventista no puede cambiarlo (paso 86 veces y deja stock fantasma: la RPC
  -- devuelve lo viejo y descuenta lo nuevo). Encargado/admin si, que son los que
  -- pueden avisarle al chofer.
  IF v_user_role NOT IN ('admin', 'encargado')
     AND EXISTS (SELECT 1 FROM recorrido_pedidos rp
                   JOIN recorridos r ON r.id = rp.recorrido_id
                  WHERE rp.pedido_id = p_pedido_id AND r.estado = 'en_curso') THEN
    RETURN jsonb_build_object('success', false, 'errores',
      ARRAY['El pedido ya esta en una hoja de ruta armada. Pedile a un encargado que lo modifique.']);
  END IF;

  -- mig 272 (#831): un regalo repartido en varios sabores sobrevive a la
  -- edicion. El front (y cualquier bundle viejo) recalcula el regalo desde la
  -- promo y manda UNA linea: si la promo ya tiene varias lineas de regalo en el
  -- pedido y la cantidad total no cambio, se guardan las que estaban, con su
  -- descripcion. Si la cantidad cambio, va lo que vino: repartir una cantidad
  -- nueva es una decision que no se puede adivinar.
  v_items := COALESCE(p_items_nuevos, '[]'::jsonb);
  FOR v_reparto IN
    SELECT pi.promocion_id,
           SUM(pi.cantidad)::INT AS total,
           jsonb_agg(jsonb_build_object(
             'producto_id', pi.producto_id, 'cantidad', pi.cantidad,
             'precio_unitario', 0, 'es_bonificacion', true,
             'promocion_id', pi.promocion_id,
             'descripcion_regalo', pi.descripcion_regalo) ORDER BY pi.id) AS lineas
      FROM pedido_items pi
     WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
       AND COALESCE(pi.es_bonificacion, false) = true
       AND pi.promocion_id IS NOT NULL
     GROUP BY pi.promocion_id
    HAVING COUNT(*) > 1
  LOOP
    SELECT COALESCE(SUM((e->>'cantidad')::INT), 0), COUNT(*)
      INTO v_total_json, v_n_json
      FROM jsonb_array_elements(v_items) e
     WHERE COALESCE((e->>'es_bonificacion')::BOOLEAN, false)
       AND (e->>'promocion_id')::BIGINT = v_reparto.promocion_id;
    IF v_n_json > 0 AND v_total_json = v_reparto.total THEN
      SELECT COALESCE(jsonb_agg(e ORDER BY o), '[]'::jsonb) INTO v_items
        FROM jsonb_array_elements(v_items) WITH ORDINALITY AS x(e, o)
       WHERE NOT (COALESCE((e->>'es_bonificacion')::BOOLEAN, false)
                  AND (e->>'promocion_id')::BIGINT IS NOT DISTINCT FROM v_reparto.promocion_id);
      v_items := v_items || v_reparto.lineas;
    END IF;
  END LOOP;

  IF v_user_role IN ('preventista') THEN
    IF v_pedido_creator IS DISTINCT FROM p_usuario_id THEN
      RETURN jsonb_build_object('success', false, 'errores',
        ARRAY['Solo el preventista que creo el pedido puede editarlo']);
    END IF;

    IF (v_pedido_created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
         IS DISTINCT FROM (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
       OR (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::time >= v_hora_corte
    THEN
      RETURN jsonb_build_object('success', false, 'errores',
        ARRAY['Como preventista solo puede editar pedidos del dia actual antes de las 15:30 (ARG)']);
    END IF;

    FOR v_item_nuevo IN SELECT * FROM jsonb_array_elements(v_items) LOOP
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

  SELECT jsonb_agg(jsonb_build_object(
    'producto_id', producto_id, 'cantidad', cantidad,
    'precio_unitario', precio_unitario, 'es_bonificacion', COALESCE(es_bonificacion, false)))
  INTO v_items_originales FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;

  FOR v_item_nuevo IN SELECT * FROM jsonb_array_elements(v_items) LOOP
    v_producto_id := (v_item_nuevo->>'producto_id')::INT;
    v_cantidad_nueva := (v_item_nuevo->>'cantidad')::INT;
    v_es_bonificacion := COALESCE((v_item_nuevo->>'es_bonificacion')::BOOLEAN, false);
    v_promocion_id := (v_item_nuevo->>'promocion_id')::BIGINT;

    IF v_es_bonificacion THEN
      IF v_promocion_id IS NULL THEN CONTINUE; END IF;
      SELECT regalo_mueve_stock INTO v_regalo_mueve_stock FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
      IF NOT COALESCE(v_regalo_mueve_stock, FALSE) THEN CONTINUE; END IF;
    END IF;

    -- mig 252 (#653): mismo criterio que aplicar_sustituciones_regalo_pre_insert.
    -- El pre-chequeo de stock tiene que mirar el producto que REALMENTE se va a
    -- descontar: si no, un regalo sustituido justamente porque el original se
    -- quedo sin stock hace fallar la edicion entera con "stock insuficiente" de
    -- un producto que nadie va a tocar. Pisar v_producto_id es seguro: los dos
    -- FOR lo releen del JSON en cada vuelta.
    -- mig 272 (#831): "mismo criterio" ahora es literal: la misma funcion.
    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      v_producto_sustituto := public.regalo_sustituto_vigente(
        p_pedido_id, v_promocion_id, v_producto_id, v_sucursal);
      IF v_producto_sustituto IS NOT NULL THEN
        v_producto_id := v_producto_sustituto;
      END IF;
    END IF;

    SELECT COALESCE(cantidad, 0) INTO v_cantidad_original
    FROM pedido_items
    WHERE pedido_id = p_pedido_id AND producto_id = v_producto_id
      AND COALESCE(es_bonificacion, false) = v_es_bonificacion
      AND sucursal_id = v_sucursal;

    v_diferencia := v_cantidad_nueva - COALESCE(v_cantidad_original, 0);

    IF v_diferencia > 0 THEN
      SELECT stock, nombre INTO v_stock_actual, v_producto_nombre
      FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal FOR UPDATE;

      IF v_stock_actual IS NULL THEN
        v_errores := array_append(v_errores, 'Producto ID ' || v_producto_id || ' no encontrado');
      ELSIF v_stock_actual < v_diferencia THEN
        v_errores := array_append(v_errores, COALESCE(v_producto_nombre, 'Producto ' || v_producto_id)
          || ': stock insuficiente (disponible: ' || v_stock_actual || ', adicional: ' || v_diferencia || ')');
      END IF;
    END IF;
  END LOOP;

  IF array_length(v_errores, 1) > 0 THEN
    RETURN jsonb_build_object('success', false, 'errores', to_jsonb(v_errores));
  END IF;

  -- mig 229: las dos restituciones de abajo devuelven stock. 'pedido_creado'
  -- es el origen que la 223 ya esperaba de esta funcion -- su comentario decia
  -- que la etiquetaba, y no era cierto hasta esta migracion.
  PERFORM set_config('app.stock_origen', 'pedido_creado', true);
  PERFORM set_config('app.stock_ref_tipo', 'pedido', true);
  PERFORM set_config('app.stock_ref_id', p_pedido_id::TEXT, true);
  PERFORM set_config('app.stock_user_id', COALESCE(p_usuario_id::TEXT, ''), true);

  UPDATE productos p
  SET stock = p.stock + pi.cantidad
  FROM pedido_items pi
  WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
    AND COALESCE(pi.es_bonificacion, false) = false
    AND p.id = pi.producto_id AND p.sucursal_id = v_sucursal;

  UPDATE productos p
  SET stock = p.stock + pi.cantidad
  FROM pedido_items pi
  JOIN promociones pr ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
  WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
    AND COALESCE(pi.es_bonificacion, false) = true
    AND pi.promocion_id IS NOT NULL
    AND COALESCE(pr.regalo_mueve_stock, FALSE) = TRUE
    AND p.id = pi.producto_id AND p.sucursal_id = v_sucursal;

  FOR v_bonif IN
    SELECT pi.promocion_id AS promocion_id,
           CASE WHEN pr.producto_regalo_id IS DISTINCT FROM pi.producto_id
                THEN pi.producto_id ELSE pr.ajuste_producto_id END AS contenedor_id,
           SUM(pi.cantidad)::INT AS total_cantidad
      FROM pedido_items pi
      LEFT JOIN promociones pr
        ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
     WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
       AND COALESCE(pi.es_bonificacion, false) = true AND pi.promocion_id IS NOT NULL
     GROUP BY 1, 2
  LOOP
    PERFORM public.revertir_bloques_auto_ajuste(
      v_bonif.promocion_id, v_bonif.total_cantidad, v_sucursal,
      p_usuario_id, 'Edicion pedido #' || p_pedido_id,
      v_bonif.contenedor_id
    );
  END LOOP;

  DELETE FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;

  FOR v_item_nuevo IN SELECT * FROM jsonb_array_elements(v_items) LOOP
    v_producto_id := (v_item_nuevo->>'producto_id')::INT;
    v_cantidad_nueva := (v_item_nuevo->>'cantidad')::INT;
    v_precio_unitario := (v_item_nuevo->>'precio_unitario')::DECIMAL;
    v_es_bonificacion := COALESCE((v_item_nuevo->>'es_bonificacion')::BOOLEAN, false);
    v_promocion_id := (v_item_nuevo->>'promocion_id')::BIGINT;

    SELECT costo_promedio, costo_real, costo_sin_iva, COALESCE(impuestos_internos, 0), COALESCE(porcentaje_iva, 21)
      INTO v_costo_promedio_actual, v_costo_real_actual, v_costo_actual, v_imp_int_actual, v_pct_iva_actual
      FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal;
    -- mig 257 (#673): el costo NO se decide aca. El SELECT de arriba lee el
    -- producto del JSON --el ORIGINAL-- y el trigger de sustituciones puede
    -- reescribir producto_id unas lineas mas abajo. Del pre-INSERT sale el
    -- desglose de precio (IVA/II), que se cobra por el precio del JSON; el
    -- costo sale despues del INSERT, del producto que quedo en la fila.
    v_costo_al_crear := NULL;

    IF v_es_bonificacion THEN
      v_neto_unitario := 0; v_iva_unitario := 0; v_ingreso_real := 0; v_porcentaje_iva := 0;
    ELSE
      SELECT d.neto, d.iva, d.ingreso_real
        INTO v_neto_unitario, v_iva_unitario, v_ingreso_real
        FROM calcular_desglose_venta(v_precio_unitario, v_pct_iva_actual, v_imp_int_actual, v_tipo_factura) d;
      v_porcentaje_iva := v_pct_iva_actual;
    END IF;

    v_descripcion_regalo := NULL;
    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      -- mig 272 (#831): una linea conservada de un reparto trae su propia
      -- descripcion (la que dice que sabor es). El front no la manda nunca.
      v_descripcion_regalo := v_item_nuevo->>'descripcion_regalo';
      IF v_descripcion_regalo IS NULL THEN
        SELECT descripcion_regalo INTO v_descripcion_regalo FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
      END IF;
    END IF;

    INSERT INTO pedido_items (
      pedido_id, producto_id, cantidad, precio_unitario, subtotal,
      es_bonificacion, promocion_id,
      neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva,
      ingreso_real_unitario,
      sucursal_id, descripcion_regalo, costo_unitario_al_crear
    ) VALUES (
      p_pedido_id, v_producto_id, v_cantidad_nueva, v_precio_unitario,
      v_cantidad_nueva * v_precio_unitario,
      v_es_bonificacion, v_promocion_id,
      v_neto_unitario, v_iva_unitario, 0, v_porcentaje_iva,
      v_ingreso_real,
      v_sucursal, v_descripcion_regalo, v_costo_al_crear
    )
    -- mig 252 (#653): aplicar_sustituciones_regalo_pre_insert puede haber
    -- reescrito producto_id al sustituto. Lo que sigue descuenta stock y elige
    -- contenedor: tiene que hablar del renglon que quedo, no del que se pidio.
    RETURNING id, producto_id INTO v_pedido_item_guardado, v_producto_guardado;

    -- mig 257 (#673): la valuacion sigue al renglon GUARDADO, igual que el
    -- stock y el contenedor desde la 252. Antes se calculaba antes del INSERT
    -- y con el producto del JSON: un regalo sustituido se guardaba con el costo
    -- del original --80 de 295 productos de prod tienen costo_real distinto de
    -- costo_promedio, asi que no es el mismo numero-- y solo se salvaba si el
    -- trigger lo reparaba.
    --
    -- La cascada es UNA sola y vive en costo_valuacion (mig 238): snapshot >
    -- promedio > real > reconstruccion desde sin_iva. Aca no hay snapshot
    -- previo --esto ES el snapshot--, asi que va NULL en el primer argumento.
    SELECT public.costo_valuacion(NULL, p.costo_promedio, p.costo_real,
                                  p.costo_sin_iva, COALESCE(p.impuestos_internos, 0))
      INTO v_costo_al_crear
      FROM productos p
     WHERE p.id = v_producto_guardado AND p.sucursal_id = v_sucursal;

    UPDATE pedido_items SET costo_unitario_al_crear = v_costo_al_crear
     WHERE id = v_pedido_item_guardado;

    IF NOT v_es_bonificacion THEN
      UPDATE productos SET stock = stock - v_cantidad_nueva WHERE id = v_producto_guardado AND sucursal_id = v_sucursal;
      v_total_nuevo := v_total_nuevo + (v_cantidad_nueva * v_precio_unitario);
      v_total_neto_nuevo := v_total_neto_nuevo + (v_cantidad_nueva * v_neto_unitario);
      v_total_iva_nuevo := v_total_iva_nuevo + (v_cantidad_nueva * v_iva_unitario);
      v_total_real_nuevo := v_total_real_nuevo + (v_cantidad_nueva * v_ingreso_real);
    ELSIF v_promocion_id IS NOT NULL THEN
      SELECT regalo_mueve_stock INTO v_regalo_mueve_stock FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
      IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
        UPDATE productos SET stock = stock - v_cantidad_nueva WHERE id = v_producto_guardado AND sucursal_id = v_sucursal;
      END IF;
      UPDATE promociones SET usos_pendientes = usos_pendientes + v_cantidad_nueva WHERE id = v_promocion_id AND sucursal_id = v_sucursal;

      SELECT id, nombre, ajuste_automatico, ajuste_producto_id, unidades_por_bloque,
             stock_por_bloque, usos_pendientes, producto_regalo_id
      INTO v_promo
      FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal FOR UPDATE;

      -- mig 252 (#653): el contenedor del que sale el fardo se decide con el
      -- producto GUARDADO, que es el mismo que van a leer las cuatro
      -- reversiones. Con v_producto_id el fardo salia de uno y volvia a otro.
      v_container_id := CASE WHEN v_promo.producto_regalo_id IS DISTINCT FROM v_producto_guardado
                             THEN v_producto_guardado ELSE v_promo.ajuste_producto_id END;

      IF v_promo.ajuste_automatico AND v_container_id IS NOT NULL
         AND COALESCE(v_promo.unidades_por_bloque, 0) > 0 AND COALESCE(v_promo.stock_por_bloque, 0) > 0 THEN
        v_usos_pendientes_actual := v_promo.usos_pendientes;
        v_bloques_completos := v_usos_pendientes_actual / v_promo.unidades_por_bloque;
        IF v_bloques_completos > 0 THEN
          v_ajustar_usos := v_bloques_completos * v_promo.unidades_por_bloque;
          v_ajustar_stock := v_bloques_completos * v_promo.stock_por_bloque;

          SELECT stock, nombre INTO v_stock_ajuste_anterior, v_ajuste_producto_nombre
          FROM productos WHERE id = v_container_id AND sucursal_id = v_sucursal FOR UPDATE;

          IF v_stock_ajuste_anterior IS NULL THEN
            RAISE EXCEPTION 'Auto-ajuste: producto destino no encontrado (promo %)', v_promocion_id;
          END IF;
          IF v_stock_ajuste_anterior < v_ajustar_stock THEN
            RAISE EXCEPTION 'Auto-ajuste: stock insuficiente en % (disponible: %, requerido: %)',
              v_ajuste_producto_nombre, v_stock_ajuste_anterior, v_ajustar_stock;
          END IF;

          v_stock_ajuste_nuevo := v_stock_ajuste_anterior - v_ajustar_stock;

          INSERT INTO mermas_stock (producto_id, cantidad, motivo, observaciones, stock_anterior, stock_nuevo, usuario_id, sucursal_id)
          VALUES (v_container_id, v_ajustar_stock, 'promociones',
            'Auto-ajuste (Promo: ' || v_promo.nombre || ', Pedido #' || p_pedido_id || ', edicion)',
            v_stock_ajuste_anterior, v_stock_ajuste_nuevo, p_usuario_id, v_sucursal)
          RETURNING id INTO v_merma_id;

          UPDATE productos SET stock = v_stock_ajuste_nuevo, updated_at = NOW()
          WHERE id = v_container_id AND sucursal_id = v_sucursal;

          INSERT INTO promo_ajustes (promocion_id, usos_ajustados, unidades_ajustadas, producto_id, merma_id, usuario_id, observaciones, sucursal_id)
          VALUES (v_promocion_id, v_ajustar_usos, v_ajustar_stock, v_container_id,
            v_merma_id, p_usuario_id, 'Auto-ajuste por edicion pedido #' || p_pedido_id, v_sucursal);

          UPDATE promociones SET usos_pendientes = GREATEST(usos_pendientes - v_ajustar_usos, 0)
          WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
        END IF;
      END IF;
    END IF;
  END LOOP;

  UPDATE pedidos SET total = v_total_nuevo, total_neto = round(v_total_neto_nuevo, 2), total_iva = round(v_total_iva_nuevo, 2), total_real = round(v_total_real_nuevo, 2), updated_at = NOW()
  WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

  -- mig 272: se registra lo que se guardo (v_items), que puede diferir de lo
  -- que mando el front si se conservo un reparto.
  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
  VALUES (p_pedido_id, p_usuario_id, 'items', COALESCE(v_items_originales::TEXT, '[]'), v_items::TEXT, v_sucursal);

  IF v_total_anterior IS DISTINCT FROM v_total_nuevo THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (p_pedido_id, p_usuario_id, 'total', v_total_anterior::TEXT, v_total_nuevo::TEXT, v_sucursal);
  END IF;

  RETURN jsonb_build_object('success', true, 'total_nuevo', v_total_nuevo);
END;
$function$;

-- ─── §5 ──────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.registrar_salvedad(p_pedido_id bigint, p_pedido_item_id bigint, p_cantidad_afectada integer, p_motivo character varying, p_descripcion text DEFAULT NULL::text, p_foto_url text DEFAULT NULL::text, p_devolver_stock boolean DEFAULT true, p_client_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal              BIGINT := current_sucursal_id();
  v_salvedad_id           BIGINT;
  v_item                  RECORD;
  v_existing              RECORD;
  v_cantidad_entregada    INTEGER;
  v_monto_afectado        DECIMAL;
  v_usuario_id            UUID;
  v_es_admin_o_encargado  BOOLEAN;
  v_subtotal_nuevo        DECIMAL;
  v_stock_devuelto        BOOLEAN := FALSE;
  v_merma_registrada      BOOLEAN := FALSE;
  v_stock_actual          INTEGER;
  v_es_bonif              BOOLEAN;
  v_mueve_stock           BOOLEAN;
  v_bonif                 RECORD;
  v_cant_compra           INT;
  v_cant_bonif            INT;
  v_total_qty             INT;
  v_bloques               INT;
  v_expected_bonif        INT;
  v_diff                  INT;
  v_regalo_mueve_stock    BOOLEAN;
  v_tipo_factura          TEXT;
  v_merma_id              BIGINT;
  -- mig 272 (#831): la resincronizacion va por promo, no por linea.
  v_promo_sync            RECORD;
  v_exceso                INT;
BEGIN
  IF p_client_request_id IS NOT NULL THEN
    SELECT id, motivo, monto_afectado, cantidad_entregada, stock_devuelto, pedido_id
      INTO v_existing
      FROM salvedades_items
     WHERE client_request_id = p_client_request_id;

    IF FOUND THEN
      RETURN jsonb_build_object(
        'success', true,
        'salvedad_id', v_existing.id,
        'monto_afectado', v_existing.monto_afectado,
        'cantidad_entregada', v_existing.cantidad_entregada,
        'stock_devuelto', v_existing.stock_devuelto,
        'merma_registrada', v_existing.motivo IN ('producto_danado', 'producto_vencido'),
        'nuevo_total_pedido', (
          SELECT total FROM pedidos
           WHERE id = v_existing.pedido_id AND sucursal_id = v_sucursal
        ),
        'idempotent_replay', true
      );
    END IF;
  END IF;

  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  v_usuario_id := auth.uid();
  IF v_usuario_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Usuario no autenticado');
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM perfiles
     WHERE id = v_usuario_id AND rol IN ('admin', 'encargado')
  ) INTO v_es_admin_o_encargado;
  IF NOT v_es_admin_o_encargado THEN
    IF NOT EXISTS (
      SELECT 1 FROM pedidos
       WHERE id = p_pedido_id AND transportista_id = v_usuario_id AND sucursal_id = v_sucursal
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'No autorizado para este pedido');
    END IF;
  END IF;

  SELECT pi.id, pi.producto_id, pi.cantidad, pi.precio_unitario, pi.subtotal,
         COALESCE(pi.es_bonificacion, FALSE) AS es_bonificacion, pi.promocion_id
    INTO v_item
    FROM pedido_items pi
   WHERE pi.id = p_pedido_item_id
     AND pi.pedido_id = p_pedido_id
     AND pi.sucursal_id = v_sucursal;

  IF NOT FOUND THEN
    -- Puede pasar legitimamente con un regalo que la resincronizacion de
    -- promos ya saco del pedido; el `codigo` deja que el llamador lo
    -- distinga de un error real.
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Item de pedido no encontrado',
      'codigo', 'item_no_encontrado'
    );
  END IF;

  IF p_cantidad_afectada > v_item.cantidad THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cantidad afectada mayor a cantidad del item');
  END IF;
  IF p_cantidad_afectada <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cantidad debe ser mayor a 0');
  END IF;

  v_es_bonif := v_item.es_bonificacion;

  -- Esta linea descontó stock cuando se cargo el pedido? Un regalo de una
  -- promo con `regalo_mueve_stock = false` nunca lo toco, asi que tampoco lo
  -- devuelve ni genera merma.
  IF v_es_bonif THEN
    SELECT COALESCE(pr.regalo_mueve_stock, FALSE) INTO v_mueve_stock
      FROM promociones pr
     WHERE pr.id = v_item.promocion_id AND pr.sucursal_id = v_sucursal;
    v_mueve_stock := COALESCE(v_mueve_stock, FALSE);
  ELSE
    v_mueve_stock := TRUE;
  END IF;

  v_cantidad_entregada := v_item.cantidad - p_cantidad_afectada;
  v_monto_afectado     := p_cantidad_afectada * v_item.precio_unitario;
  v_subtotal_nuevo     := v_cantidad_entregada * v_item.precio_unitario;

  IF p_motivo IN ('cliente_rechaza', 'error_pedido', 'diferencia_precio') THEN
    v_stock_devuelto := TRUE;
  END IF;
  v_stock_devuelto := v_stock_devuelto AND v_mueve_stock;

  PERFORM set_config('app.stock_origen', 'salvedad', true);
  PERFORM set_config('app.stock_ref_tipo', 'pedido', true);
  PERFORM set_config('app.stock_ref_id', p_pedido_id::TEXT, true);
  PERFORM set_config('app.stock_user_id', v_usuario_id::TEXT, true);
  -- Lo que se entrego de menos no lo trapa el minimo de compra (mig 147).
  PERFORM set_config('app.omitir_minimo_venta', '1', true);

  INSERT INTO salvedades_items (
    pedido_id, pedido_item_id, producto_id, cantidad_original, cantidad_afectada,
    cantidad_entregada, motivo, descripcion, foto_url, monto_afectado, precio_unitario,
    reportado_por, stock_devuelto, stock_devuelto_at, estado_resolucion, sucursal_id,
    client_request_id, es_bonificacion, promocion_id
  ) VALUES (
    p_pedido_id, p_pedido_item_id, v_item.producto_id, v_item.cantidad, p_cantidad_afectada,
    v_cantidad_entregada, p_motivo, p_descripcion, p_foto_url, v_monto_afectado, v_item.precio_unitario,
    v_usuario_id, v_stock_devuelto, CASE WHEN v_stock_devuelto THEN NOW() ELSE NULL END, 'pendiente', v_sucursal,
    p_client_request_id, v_item.es_bonificacion, v_item.promocion_id
  ) RETURNING id INTO v_salvedad_id;

  IF v_salvedad_id IS NULL THEN
    RAISE EXCEPTION 'No se pudo crear la salvedad';
  END IF;

  IF v_cantidad_entregada > 0 THEN
    UPDATE pedido_items
       SET cantidad = v_cantidad_entregada,
           subtotal = v_subtotal_nuevo
     WHERE id = p_pedido_item_id AND sucursal_id = v_sucursal;
  ELSE
    DELETE FROM pedido_items
     WHERE id = p_pedido_item_id AND sucursal_id = v_sucursal;
  END IF;

  -- Salvedad sobre el regalo mismo: las unidades que no se entregaron dejan
  -- de estar comprometidas por la promo.
  IF v_es_bonif AND v_item.promocion_id IS NOT NULL THEN
    PERFORM public.revertir_bloques_auto_ajuste(
      v_item.promocion_id, p_cantidad_afectada, v_sucursal,
      v_usuario_id, 'Salvedad sobre regalo, pedido #' || p_pedido_id,
      (SELECT CASE WHEN pr.producto_regalo_id IS DISTINCT FROM v_item.producto_id
                   THEN v_item.producto_id ELSE pr.ajuste_producto_id END
         FROM promociones pr
        WHERE pr.id = v_item.promocion_id AND pr.sucursal_id = v_sucursal)
    );
  END IF;

  -- Resincronizar bonificaciones: si cayo el disparador, cae el regalo.
  -- Solo reduce, nunca aumenta, asi que no pisa una salvedad manual sobre el
  -- propio regalo hecha en el mismo lote.
  --
  -- mig 272 (#831): por PROMO, no por linea. Un regalo repartido en sabores
  -- son N lineas de la misma promo, y comparar cada una contra el total
  -- esperado no recortaba nada (5+5+5 contra 10) o dejaba de mas (3+3+3
  -- contra 3). El exceso se saca de las lineas mas nuevas hacia atras; con
  -- una sola linea es exactamente lo de antes.
  FOR v_promo_sync IN
    SELECT pi.promocion_id, SUM(pi.cantidad)::INT AS total_bonif
      FROM pedido_items pi
     WHERE pi.pedido_id = p_pedido_id
       AND pi.sucursal_id = v_sucursal
       AND COALESCE(pi.es_bonificacion, FALSE) = TRUE
       AND pi.promocion_id IS NOT NULL
     GROUP BY pi.promocion_id
  LOOP
    SELECT
      MAX(CASE WHEN pr.clave = 'cantidad_compra'       THEN pr.valor END)::INT,
      MAX(CASE WHEN pr.clave = 'cantidad_bonificacion' THEN pr.valor END)::INT,
      MAX(p.regalo_mueve_stock::INT)::BOOLEAN
    INTO v_cant_compra, v_cant_bonif, v_regalo_mueve_stock
    FROM promociones p
    LEFT JOIN promocion_reglas pr
      ON pr.promocion_id = p.id
    WHERE p.id = v_promo_sync.promocion_id
      AND p.sucursal_id = v_sucursal
    GROUP BY p.id;

    IF v_cant_compra IS NULL OR v_cant_compra <= 0
       OR v_cant_bonif IS NULL OR v_cant_bonif <= 0 THEN
      CONTINUE;
    END IF;

    SELECT COALESCE(SUM(pi.cantidad), 0)::INT
      INTO v_total_qty
      FROM pedido_items pi
      JOIN promocion_productos pp
        ON pp.producto_id = pi.producto_id
       AND pp.promocion_id = v_promo_sync.promocion_id
     WHERE pi.pedido_id = p_pedido_id
       AND pi.sucursal_id = v_sucursal
       AND COALESCE(pi.es_bonificacion, FALSE) = FALSE;

    v_bloques        := v_total_qty / v_cant_compra;
    v_expected_bonif := v_bloques * v_cant_bonif;

    IF v_expected_bonif < v_promo_sync.total_bonif THEN
      v_exceso := v_promo_sync.total_bonif - v_expected_bonif;

      FOR v_bonif IN
        SELECT pi.id, pi.producto_id, pi.cantidad, pi.promocion_id
          FROM pedido_items pi
         WHERE pi.pedido_id = p_pedido_id
           AND pi.sucursal_id = v_sucursal
           AND COALESCE(pi.es_bonificacion, FALSE) = TRUE
           AND pi.promocion_id = v_promo_sync.promocion_id
         ORDER BY pi.id DESC
      LOOP
        EXIT WHEN v_exceso <= 0;
        v_diff   := LEAST(v_bonif.cantidad, v_exceso);
        v_exceso := v_exceso - v_diff;

        IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
          UPDATE productos
             SET stock = stock + v_diff
           WHERE id = v_bonif.producto_id
             AND sucursal_id = v_sucursal;
        END IF;

        PERFORM public.revertir_bloques_auto_ajuste(
          v_bonif.promocion_id, v_diff, v_sucursal,
          v_usuario_id, 'Salvedad pedido #' || p_pedido_id,
          (SELECT CASE WHEN pr.producto_regalo_id IS DISTINCT FROM v_bonif.producto_id
                       THEN v_bonif.producto_id ELSE pr.ajuste_producto_id END
             FROM promociones pr
            WHERE pr.id = v_bonif.promocion_id AND pr.sucursal_id = v_sucursal)
        );

        IF v_bonif.cantidad - v_diff = 0 THEN
          DELETE FROM pedido_items WHERE id = v_bonif.id;
        ELSE
          UPDATE pedido_items
             SET cantidad = v_bonif.cantidad - v_diff,
                 subtotal = (v_bonif.cantidad - v_diff) * COALESCE(precio_unitario, 0)
           WHERE id = v_bonif.id;
        END IF;
      END LOOP;
    END IF;
  END LOOP;

  SELECT COALESCE(tipo_factura, 'ZZ') INTO v_tipo_factura
    FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

  UPDATE pedidos
     SET total = sub.total_recalc,
         total_neto = sub.neto_recalc,
         total_iva = sub.iva_recalc,
         total_real = sub.real_recalc,
         updated_at = NOW()
    FROM (
      SELECT
        COALESCE(SUM(subtotal), 0) AS total_recalc,
        COALESCE(SUM(CASE WHEN COALESCE(es_bonificacion, FALSE) = FALSE
                          THEN cantidad * COALESCE(neto_unitario, precio_unitario)
                          ELSE 0 END), 0) AS neto_recalc,
        COALESCE(SUM(CASE WHEN COALESCE(es_bonificacion, FALSE) = FALSE
                          THEN cantidad * COALESCE(iva_unitario, 0)
                          ELSE 0 END), 0) AS iva_recalc,
        COALESCE(SUM(CASE WHEN COALESCE(es_bonificacion, FALSE) = FALSE
                          THEN cantidad * COALESCE(ingreso_real_unitario,
                               CASE WHEN v_tipo_factura = 'FC'
                                    THEN COALESCE(neto_unitario, precio_unitario)
                                    ELSE precio_unitario END)
                          ELSE 0 END), 0) AS real_recalc
        FROM pedido_items
       WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal
    ) sub
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

  IF v_stock_devuelto THEN
    UPDATE productos
       SET stock = stock + p_cantidad_afectada
     WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
  END IF;

  IF p_motivo IN ('producto_danado', 'producto_vencido') AND v_mueve_stock THEN
    /* mig 234: las unidades ya habian salido del stock al crear el pedido.
       La merma sola las descontaba una SEGUNDA vez (19 unidades de stock
       fantasma en prod). Ahora se devuelven primero y se merman despues:
       neto 0 sobre productos.stock y una fila de mermas_stock medida
       contra el stock ya devuelto, que es lo que pide MERMA-B.

       El origen de ESTA devolucion queda a proposito FUERA de la lista
       blanca de trg_lotes_sincronizar (223/229). Con un origen
       whitelisteado la devolucion vuelve al lote por FEFO, pero la bajada
       de la merma sale de la bolsa primero, asi que el lote termina +N y
       la bolsa -N en cada salvedad por rotura. Medido en prod con un lote
       sintetico: 50 -> 53 -> 53 con 'salvedad', 50 -> 50 -> 50 con este
       origen. Estas unidades no vuelven a la gondola -- se rompen en el
       mismo movimiento --, asi que las dos patas tienen que caer del mismo
       lado del mostrador. La regla de CLAUDE.md (toda devolucion va
       etiquetada) sigue valiendo para la devolucion que SI queda devuelta. */
    PERFORM set_config('app.stock_origen', 'salvedad_merma', true);

    UPDATE productos
       SET stock = stock + p_cantidad_afectada
     WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;

    SELECT stock INTO v_stock_actual
      FROM productos
     WHERE id = v_item.producto_id AND sucursal_id = v_sucursal
     FOR UPDATE;

    INSERT INTO mermas_stock (
      producto_id, cantidad, motivo, observaciones,
      stock_anterior, stock_nuevo, usuario_id, sucursal_id, salvedad_id
    ) VALUES (
      v_item.producto_id, p_cantidad_afectada,
      CASE p_motivo WHEN 'producto_danado' THEN 'rotura' WHEN 'producto_vencido' THEN 'vencimiento' END,
      COALESCE(p_descripcion, 'Salvedad pedido #' || p_pedido_id || ': ' || p_motivo),
      v_stock_actual, GREATEST(v_stock_actual - p_cantidad_afectada, 0), v_usuario_id, v_sucursal,
      v_salvedad_id
    ) RETURNING id INTO v_merma_id;

    -- La bajada es una merma, no una salvedad: el ledger tiene que decir eso
    -- y apuntar a la fila de mermas_stock, igual que registrar_merma_manual
    -- (mig 232).
    PERFORM set_config('app.stock_origen',   'merma',          true);
    PERFORM set_config('app.stock_ref_tipo', 'mermas_stock',   true);
    PERFORM set_config('app.stock_ref_id',   v_merma_id::TEXT,  true);

    UPDATE productos
       SET stock = GREATEST(stock - p_cantidad_afectada, 0)
     WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;

    -- set_config es por TRANSACCION, no por funcion (mig 229): dejar la
    -- etiqueta en 'merma' le mentiria a cualquier movimiento posterior de
    -- este mismo caller. Se restaura la de la salvedad.
    PERFORM set_config('app.stock_origen',   'salvedad',        true);
    PERFORM set_config('app.stock_ref_tipo', 'pedido',          true);
    PERFORM set_config('app.stock_ref_id',   p_pedido_id::TEXT, true);

    v_merma_registrada := TRUE;
  END IF;

  INSERT INTO salvedad_historial (salvedad_id, accion, estado_nuevo, notas, usuario_id, sucursal_id)
  VALUES (v_salvedad_id, 'creacion', 'pendiente', p_descripcion, v_usuario_id, v_sucursal);

  RETURN jsonb_build_object(
    'success', true,
    'salvedad_id', v_salvedad_id,
    'monto_afectado', v_monto_afectado,
    'cantidad_entregada', v_cantidad_entregada,
    'stock_devuelto', v_stock_devuelto,
    'merma_registrada', v_merma_registrada,
    'es_bonificacion', v_es_bonif,
    'nuevo_total_pedido', (
      SELECT total FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal
    )
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$function$;

-- Simulacion de UNA salvedad: una fila por promo afectada (antes, una por
-- linea de regalo, cada una comparada contra el total de la promo).
CREATE OR REPLACE FUNCTION public.simular_salvedad_promo_impacto(p_pedido_id bigint, p_pedido_item_id bigint, p_cantidad_afectada integer)
 RETURNS TABLE(promocion_id bigint, promo_nombre text, bonif_actual integer, bonif_esperada integer, delta integer, descripcion_regalo text, sera_eliminada boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_item RECORD;
BEGIN
  IF v_sucursal IS NULL OR p_cantidad_afectada IS NULL OR p_cantidad_afectada <= 0 THEN
    RETURN;
  END IF;

  SELECT pi.id, pi.producto_id, pi.cantidad, COALESCE(pi.es_bonificacion, FALSE) AS es_bonificacion
    INTO v_item
    FROM pedido_items pi
   WHERE pi.id = p_pedido_item_id
     AND pi.pedido_id = p_pedido_id
     AND pi.sucursal_id = v_sucursal;

  IF v_item IS NULL OR v_item.es_bonificacion THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH bonifs AS (
    -- mig 272 (#831): agregado por promo. Un regalo repartido en sabores son
    -- varias lineas y el esperado es de la promo entera.
    SELECT pi.promocion_id, SUM(pi.cantidad)::INT AS cantidad
      FROM pedido_items pi
     WHERE pi.pedido_id = p_pedido_id
       AND pi.sucursal_id = v_sucursal
       AND COALESCE(pi.es_bonificacion, FALSE) = TRUE
       AND pi.promocion_id IS NOT NULL
     GROUP BY pi.promocion_id
  ),
  promo_info AS (
    SELECT
      b.cantidad AS bonif_qty,
      b.promocion_id,
      p.nombre AS promo_nombre,
      p.descripcion_regalo,
      MAX(CASE WHEN pr.clave = 'cantidad_compra'       THEN pr.valor END)::INT AS cant_compra,
      MAX(CASE WHEN pr.clave = 'cantidad_bonificacion' THEN pr.valor END)::INT AS cant_bonif
    FROM bonifs b
    JOIN promociones p ON p.id = b.promocion_id AND p.sucursal_id = v_sucursal
    LEFT JOIN promocion_reglas pr ON pr.promocion_id = p.id
    GROUP BY b.cantidad, b.promocion_id, p.nombre, p.descripcion_regalo
  ),
  totales AS (
    SELECT
      pi.pedido_id, pp.promocion_id,
      SUM(
        CASE
          WHEN pi.id = p_pedido_item_id THEN GREATEST(pi.cantidad - p_cantidad_afectada, 0)
          ELSE pi.cantidad
        END
      )::INT AS total_qty_post
    FROM pedido_items pi
    JOIN promocion_productos pp ON pp.producto_id = pi.producto_id
    WHERE pi.pedido_id = p_pedido_id
      AND pi.sucursal_id = v_sucursal
      AND COALESCE(pi.es_bonificacion, FALSE) = FALSE
    GROUP BY pi.pedido_id, pp.promocion_id
  )
  SELECT
    pi.promocion_id,
    pi.promo_nombre::TEXT,
    pi.bonif_qty AS bonif_actual,
    (COALESCE(t.total_qty_post, 0) / NULLIF(pi.cant_compra, 0)) * pi.cant_bonif AS bonif_esperada,
    pi.bonif_qty - ((COALESCE(t.total_qty_post, 0) / NULLIF(pi.cant_compra, 0)) * pi.cant_bonif) AS delta,
    pi.descripcion_regalo,
    ((COALESCE(t.total_qty_post, 0) / NULLIF(pi.cant_compra, 0)) * pi.cant_bonif) = 0 AS sera_eliminada
  FROM promo_info pi
  LEFT JOIN totales t ON t.promocion_id = pi.promocion_id
  WHERE pi.cant_compra IS NOT NULL AND pi.cant_compra > 0
    AND pi.cant_bonif  IS NOT NULL AND pi.cant_bonif  > 0
    AND pi.bonif_qty > ((COALESCE(t.total_qty_post, 0) / NULLIF(pi.cant_compra, 0)) * pi.cant_bonif);
END;
$function$;

-- Simulacion de un lote: por linea, con el exceso de cada promo repartido de
-- las lineas mas nuevas hacia atras, igual que registrar_salvedad.
CREATE OR REPLACE FUNCTION public.simular_salvedades_promo_impacto(p_pedido_id bigint, p_salvedades jsonb)
 RETURNS TABLE(pedido_item_id bigint, promocion_id bigint, promo_nombre text, producto_id bigint, producto_nombre text, descripcion_regalo text, cantidad_actual integer, cantidad_final integer, delta integer, sera_eliminada boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH afectadas AS (
    SELECT (e->>'pedido_item_id')::BIGINT AS item_id,
           GREATEST(COALESCE((e->>'cantidad_afectada')::INT, 0), 0) AS cant
      FROM jsonb_array_elements(COALESCE(p_salvedades, '[]'::jsonb)) e
     WHERE (e->>'pedido_item_id') IS NOT NULL
  ),
  items AS (
    SELECT pi.id, pi.producto_id, pi.cantidad, pi.promocion_id,
           pi.descripcion_regalo,
           COALESCE(pi.es_bonificacion, FALSE) AS es_bonif,
           GREATEST(pi.cantidad - COALESCE(a.cant, 0), 0)::INT AS cantidad_post
      FROM pedido_items pi
      LEFT JOIN afectadas a ON a.item_id = pi.id
     WHERE pi.pedido_id = p_pedido_id
       AND pi.sucursal_id = current_sucursal_id()
  ),
  reglas AS (
    SELECT p.id AS promocion_id, p.nombre, p.descripcion_regalo,
           MAX(CASE WHEN pr.clave = 'cantidad_compra'       THEN pr.valor END)::INT AS cant_compra,
           MAX(CASE WHEN pr.clave = 'cantidad_bonificacion' THEN pr.valor END)::INT AS cant_bonif
      FROM promociones p
      LEFT JOIN promocion_reglas pr ON pr.promocion_id = p.id
     WHERE p.sucursal_id = current_sucursal_id()
     GROUP BY p.id, p.nombre, p.descripcion_regalo
  ),
  totales AS (
    SELECT pp.promocion_id, SUM(i.cantidad_post)::INT AS qty_post
      FROM items i
      JOIN promocion_productos pp ON pp.producto_id = i.producto_id
     WHERE NOT i.es_bonif
     GROUP BY pp.promocion_id
  ),
  bonifs AS (
    -- mig 272 (#831): el exceso es de la PROMO (suma de sus lineas contra el
    -- esperado) y se descuenta de la linea mas nueva hacia atras. `previas`
    -- es lo que ya tienen las lineas mas nuevas que esta: con una sola linea
    -- vale 0 y el resultado es LEAST(cantidad_post, esperado), lo de antes.
    SELECT b.id, b.producto_id, b.cantidad, b.promocion_id, b.descripcion_regalo,
           b.cantidad_post,
           r.promocion_id AS regla_promo, r.nombre, r.descripcion_regalo AS desc_promo,
           r.cant_compra, r.cant_bonif, t.qty_post,
           SUM(b.cantidad_post) OVER (PARTITION BY b.promocion_id) AS post_promo,
           COALESCE(SUM(b.cantidad_post) OVER (
             PARTITION BY b.promocion_id ORDER BY b.id DESC
             ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS previas
      FROM items b
      LEFT JOIN reglas  r ON r.promocion_id = b.promocion_id
      LEFT JOIN totales t ON t.promocion_id = b.promocion_id
     WHERE b.es_bonif
  ),
  calculo AS (
    SELECT
      b.id,
      b.promocion_id,
      b.nombre,
      b.producto_id,
      prod.nombre AS producto_nombre,
      COALESCE(b.descripcion_regalo, b.desc_promo) AS desc_regalo,
      b.cantidad,
      (b.cantidad_post - CASE
          WHEN b.regla_promo IS NULL
            OR COALESCE(b.cant_compra, 0) <= 0
            OR COALESCE(b.cant_bonif, 0)  <= 0
          THEN 0
          ELSE LEAST(b.cantidad_post, GREATEST(
                 GREATEST(b.post_promo - (COALESCE(b.qty_post, 0) / b.cant_compra) * b.cant_bonif, 0)
                 - b.previas, 0))
        END)::INT AS cantidad_final
      FROM bonifs b
      LEFT JOIN productos prod ON prod.id = b.producto_id
  )
  SELECT
    c.id                             AS pedido_item_id,
    c.promocion_id,
    c.nombre::TEXT                   AS promo_nombre,
    c.producto_id,
    c.producto_nombre::TEXT,
    c.desc_regalo::TEXT              AS descripcion_regalo,
    c.cantidad                       AS cantidad_actual,
    c.cantidad_final,
    (c.cantidad - c.cantidad_final)  AS delta,
    (c.cantidad_final = 0)           AS sera_eliminada
  FROM calculo c
  ORDER BY c.id;
$function$;
