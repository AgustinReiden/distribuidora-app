-- La promo se mide en LEAST(fecha del pedido, hoy) tambien al editar (#1152,
-- mitad de fecha futura de #1155), el rechazo de regalo lleva codigo para el
-- replay offline (#1153) y el bot revalida la promo al confirmar (#1154).
--
--   * #1152. ModalPedido resolvia las promos con hoy y ModalEditarPedido con
--     pedido.fecha sin tope. Decision del dueno (2026-10-14, regla del
--     2026-10-13): los dos modales miden en LEAST(fecha del pedido, hoy)
--     (src/utils/fechaReferenciaPromo.ts), y el server hace lo mismo tambien
--     en la edicion: v_d deja de distinguir alta y edicion. Un pedido con
--     fecha futura puesta a mano ya no reclama al editar una promo que empieza
--     entre manana y esa fecha (VE4 del ensayo de 1136-1137 pasa a rechazo).
--     Esto cierra solo la mitad de FECHA FUTURA de #1155: mover pedidos.fecha
--     hacia atras por PATCH (y despues editar con el regalo de una promo ya
--     terminada, vigente en esa fecha pasada) sigue abierto hasta que
--     pedidos_proteger_columnas proteja la columna (G4). La alternativa "o en
--     hoy" se conserva: cubre la cola offline armada con el front viejo
--     (ModalPedido resolvia con hoy) y el invariante sigue siendo que el
--     server nunca es mas estricto que el front.
--     El mensaje de vigencia, en la edicion con fecha futura, dice ademas el
--     dia en que se edita (" editado el "), como el alta dice " cargado el ".
--   * #1153. crear_pedido_completo devuelve 'codigo' = 'regalo_fuera_de_promo'
--     junto al rechazo de regalo. RechazoDeNegocioError lo lleva y el replay
--     offline marca la operacion para ofrecer "Sincronizar sin el regalo"
--     (decide el preventista). crear_pedido_idempotente no se toca: devuelve
--     el resultado tal cual y solo sella offline_id con success, asi que el
--     reintento con la misma clave es seguro. Los demas rechazos (compra
--     minima, producto desactivado, total, piso de precio) no llevan codigo.
--   * #1154. crear_pedido_completo_bot no miraba la promo entre la
--     previsualizacion y la confirmacion (vive 10 minutos): ahora llama a
--     regalo_fuera_de_promo(items, items, sucursal, NULL, hoy) antes de toda
--     escritura, con la misma exencion de admin que la app. El rechazo va por
--     'error' (crear_pedido.ts antepone "Stock insuficiente:" a 'errores') y
--     corta antes del UPDATE de consumido: la confirmacion queda sin consumir.
--
-- Exposicion en prod al escribir esto: 0 pedidos con fecha > hoy, 0 pedidos
-- del bot y 0 confirmaciones pendientes. Sin backfill.
--
-- Orden de despliegue: PRIMERO el front, despues esta migracion. Front nuevo
-- contra server viejo: el server queda mas laxo. Front viejo contra server
-- nuevo: un PWA sin actualizar puede ver rechazada la edicion de un pedido
-- con fecha futura que agrega el regalo de una promo que empieza en el medio.
--
-- Ningun bloque nuevo mueve stock, toca GUCs, lotes ni costo_unitario_al_crear:
-- STK-F, STK-D y COSTO-D no se mueven. El gate de piso de precio de la 363
-- excluye al bot por nombre.
--
-- regalo_fuera_de_promo: CREATE OR REPLACE completo desde pg_get_functiondef de
-- prod (2026-10-14, igual al cuerpo de la 362). Las otras dos: parche por ancla
-- sobre la definicion viva (cada fragmento tiene que aparecer exactamente una
-- vez o la migracion aborta). CREATE OR REPLACE conserva el ACL; los REVOKE van
-- igual y el $verif$ los vigila.
--
-- Ensayo: scripts/test-promo-fecha-replay-bot-1152-1153-1154.sql y
-- scripts/test-promo-vigente-excluyente-1136-1137.sql (VE4 cambia).

-- ---------------------------------------------------------------------------
-- 1. regalo_fuera_de_promo: LEAST(fecha, hoy) tambien en la edicion
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.regalo_fuera_de_promo(
  p_items_producto jsonb, p_items_cantidad jsonb, p_sucursal bigint, p_pedido_id bigint, p_fecha date)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $fn$
DECLARE
  v_prod     jsonb := CASE WHEN jsonb_typeof(p_items_producto) = 'array' THEN p_items_producto ELSE '[]'::jsonb END;
  v_cant     jsonb := CASE WHEN jsonb_typeof(p_items_cantidad) = 'array' THEN p_items_cantidad ELSE '[]'::jsonb END;
  r          record;
  v_promo    record;
  v_def      bigint;
  v_def_nom  text;
  v_n_lineas int;
  v_prod_unica bigint;
  v_tope     int;
  v_suma     numeric;
  v_hoy      date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_d        date;
  v_promos   jsonb;
  v_par      jsonb;
BEGIN
  -- #1152/#1155: el alta y la edicion miden en LEAST(fecha del pedido, hoy),
  -- igual que los dos modales (src/utils/fechaReferenciaPromo.ts). Una fecha
  -- futura puesta a mano no adelanta promos que todavia no empezaron.
  -- (Mover la fecha hacia atras sigue siendo posible por PATCH hasta que
  -- pedidos_proteger_columnas proteja pedidos.fecha: #1155, G4.)
  v_d := LEAST(COALESCE(p_fecha, v_hoy), v_hoy);

  -- 1. Regalo sin promo. En la edicion entra solo si el pedido ya lo tenia
  --    (mismo producto y la cantidad no sube): la linea que dejo un ON DELETE
  --    SET NULL de la promo.
  FOR r IN
    SELECT NULLIF(e->>'producto_id', '')::bigint AS producto,
           SUM(COALESCE(NULLIF(e->>'cantidad', '')::numeric, 0)) AS cantidad
      FROM jsonb_array_elements(v_prod) e
     WHERE COALESCE((e->>'es_bonificacion')::boolean, false)
       AND NULLIF(e->>'promocion_id', '') IS NULL
     GROUP BY 1
     ORDER BY 1
  LOOP
    IF p_pedido_id IS NULL
       OR r.cantidad > COALESCE((SELECT SUM(pi.cantidad)
                                   FROM pedido_items pi
                                  WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = p_sucursal
                                    AND COALESCE(pi.es_bonificacion, false)
                                    AND pi.promocion_id IS NULL
                                    AND pi.producto_id = r.producto), 0) THEN
      RETURN format('Una línea de regalo tiene que venir de una promoción (producto ID %s).',
                    COALESCE(r.producto::text, '?'));
    END IF;
  END LOOP;

  -- 2 a 4, por promo: que exista y este vigente, el producto de cada linea y
  -- la cantidad.
  FOR v_promo IN
    SELECT DISTINCT (e->>'promocion_id')::bigint AS id
      FROM jsonb_array_elements(v_prod || v_cant) e
     WHERE COALESCE((e->>'es_bonificacion')::boolean, false)
       AND NULLIF(e->>'promocion_id', '') IS NOT NULL
     ORDER BY 1
  LOOP
    SELECT p.id, p.nombre, COALESCE(p.producto_regalo_id, p.ajuste_producto_id) AS def,
           (SELECT rg.valor FROM promocion_reglas rg
             WHERE rg.promocion_id = p.id AND rg.clave = 'cantidad_compra') AS compra,
           (SELECT rg.valor FROM promocion_reglas rg
             WHERE rg.promocion_id = p.id AND rg.clave = 'cantidad_bonificacion') AS bonif,
           COALESCE((SELECT jsonb_agg(pp.producto_id ORDER BY pp.producto_id)
                       FROM promocion_productos pp
                      WHERE pp.promocion_id = p.id AND pp.sucursal_id = p_sucursal), '[]'::jsonb) AS productos,
           p.activo, p.fecha_inicio, p.fecha_fin, p.modo_exclusion
      INTO r
      FROM promociones p
     WHERE p.id = v_promo.id AND p.sucursal_id = p_sucursal;
    IF NOT FOUND THEN
      RETURN format('La promoción %s no existe en esta sucursal.', v_promo.id);
    END IF;

    -- 2b. Vigencia (#1137). Va antes del producto: una promo apagada no pasa
    --     por el chequeo de categoria.
    --     El mismo predicado tiene otras dos copias: fetchPromoMap
    --     (src/hooks/queries/usePromocionesQuery.ts) y el edge function del bot
    --     (supabase/functions/_shared/pricing/index.ts). No hay gate de paridad
    --     porque NO son iguales por diseno: el server es mas permisivo y admite
    --     a proposito la alternativa "o en hoy", para el replay offline y
    --     para la cola armada con el front viejo (ModalPedido resolvia con
    --     hoy: el alta con fecha anterior al inicio de la promo, pedidos 633 y
    --     642). v_d imita la fecha con que resuelven los dos fronts: desde
    --     #1152, ModalPedido y ModalEditarPedido usan LEAST(fecha del pedido,
    --     hoy) (fechaReferenciaPromo). El invariante es que el server nunca
    --     sea MAS estricto que el front (si lo fuera, rechazaria pedidos
    --     honestos); lo prueban los casos V y VE de
    --     scripts/test-promo-vigente-excluyente-1136-1137.sql.
    --     En la edicion queda exenta la promo cuyo regalo el pedido ya tenia,
    --     pero solo si el request lo conserva: ModalEditarPedido hoy lo pierde
    --     con la promo apagada (ver la cabecera de la 362, "Edicion").
    IF NOT (COALESCE(r.activo, false)
            AND ((r.fecha_inicio <= v_d AND (r.fecha_fin IS NULL OR r.fecha_fin >= v_d))
              OR (r.fecha_inicio <= v_hoy AND (r.fecha_fin IS NULL OR r.fecha_fin >= v_hoy))))
       AND NOT (p_pedido_id IS NOT NULL
                AND EXISTS (SELECT 1 FROM pedido_items pi
                             WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = p_sucursal
                               AND COALESCE(pi.es_bonificacion, false)
                               AND pi.promocion_id = v_promo.id)) THEN
      IF NOT COALESCE(r.activo, false) THEN
        RETURN format('La promo "%s" está desactivada: su regalo ya no entra en un pedido nuevo. Recargá la app y volvé a cargarlo.',
                      r.nombre);
      END IF;
      RETURN format('La promo "%s" rige %s: su regalo no entra en un pedido del %s. Recargá la app y volvé a cargarlo.',
                    r.nombre,
                    CASE WHEN r.fecha_fin IS NULL THEN 'desde el ' || to_char(r.fecha_inicio, 'DD/MM/YYYY')
                         ELSE 'del ' || to_char(r.fecha_inicio, 'DD/MM/YYYY')
                              || ' al ' || to_char(r.fecha_fin, 'DD/MM/YYYY') END,
                    -- La fecha del pedido, no v_d: con fecha futura se dice
                    -- ademas el dia de carga o de edicion (el del tope).
                    to_char(COALESCE(p_fecha, v_hoy), 'DD/MM/YYYY')
                    || CASE WHEN p_fecha > v_hoy
                            THEN CASE WHEN p_pedido_id IS NULL THEN ' cargado el ' ELSE ' editado el ' END
                                 || to_char(v_hoy, 'DD/MM/YYYY') ELSE '' END);
    END IF;

    -- 3. Producto.
    v_def := r.def;
    v_n_lineas := 0; v_prod_unica := NULL;
    IF p_pedido_id IS NOT NULL THEN
      SELECT count(*), (array_agg(pi.producto_id))[1]
        INTO v_n_lineas, v_prod_unica
        FROM pedido_items pi
       WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = p_sucursal
         AND COALESCE(pi.es_bonificacion, false) AND pi.promocion_id = v_promo.id;
    END IF;
    IF EXISTS (
         SELECT 1
           FROM jsonb_array_elements(v_prod) e
          WHERE COALESCE((e->>'es_bonificacion')::boolean, false)
            AND NULLIF(e->>'promocion_id', '')::bigint = v_promo.id
            -- COALESCE: un producto_id nulo no puede colarse por un NULL.
            AND NOT COALESCE(
                  (v_def IS NOT NULL
                   AND public.regalo_misma_categoria(v_def, NULLIF(e->>'producto_id', '')::bigint, p_sucursal))
               OR (v_def IS NULL
                   AND EXISTS (SELECT 1 FROM promocion_productos pp
                                WHERE pp.promocion_id = v_promo.id AND pp.sucursal_id = p_sucursal
                                  AND pp.producto_id = NULLIF(e->>'producto_id', '')::bigint))
               OR (p_pedido_id IS NOT NULL AND e->>'_cadena' IS NOT NULL)
               OR (p_pedido_id IS NOT NULL AND v_n_lineas = 1
                   AND v_prod_unica = NULLIF(e->>'producto_id', '')::bigint), false)) THEN
      SELECT nombre INTO v_def_nom FROM productos WHERE id = v_def AND sucursal_id = p_sucursal;
      RETURN format('El regalo de la promo "%s" tiene que ser %s o un producto de su misma categoría. Solo un admin puede elegir otro producto.',
                    r.nombre,
                    CASE WHEN v_def IS NULL THEN 'uno de sus productos'
                         ELSE COALESCE(v_def_nom, 'el producto ID ' || v_def) END);
    END IF;

    -- 4. Cantidad, sobre lo que mando el llamador.
    SELECT COALESCE(SUM(COALESCE(NULLIF(e->>'cantidad', '')::numeric, 0)), 0)
      INTO v_suma
      FROM jsonb_array_elements(v_cant) e
     WHERE COALESCE((e->>'es_bonificacion')::boolean, false)
       AND NULLIF(e->>'promocion_id', '')::bigint = v_promo.id;
    v_tope := public.regalo_tope_promo(v_cant, r.productos, r.compra, r.bonif);
    IF v_suma > v_tope THEN
      RETURN format('El regalo de la promo "%s" no puede pasar de %s con lo que lleva el pedido (vinieron %s). Recargá la app y volvé a cargarlo.',
                    r.nombre, v_tope, v_suma);
    END IF;
  END LOOP;

  -- 5. Exclusion (#1136): una sola promo con regalo por grupo excluyente.
  --    Mismo conjunto de promos que recorre el FOR. La venta se mide sobre
  --    v_cant, lo que mando el llamador (como el tope). Sin exencion en la
  --    edicion: el front nunca manda las dos, y los repartos conservados no
  --    cambian el conjunto de promos. Espejo: regalo_excluyentes_en_conflicto.
  SELECT jsonb_agg(jsonb_build_object(
           'id', p.id,
           'excluyente', p.modo_exclusion = 'excluyente',
           'productos', COALESCE((SELECT jsonb_agg(pp.producto_id ORDER BY pp.producto_id)
                                    FROM promocion_productos pp
                                   WHERE pp.promocion_id = p.id AND pp.sucursal_id = p_sucursal), '[]'::jsonb))
           ORDER BY p.id)
    INTO v_promos
    FROM promociones p
   WHERE p.sucursal_id = p_sucursal
     AND p.id IN (SELECT (e->>'promocion_id')::bigint
                    FROM jsonb_array_elements(v_prod || v_cant) e
                   WHERE COALESCE((e->>'es_bonificacion')::boolean, false)
                     AND NULLIF(e->>'promocion_id', '') IS NOT NULL);
  v_par := public.regalo_excluyentes_en_conflicto(v_cant, v_promos);
  IF v_par IS NOT NULL THEN
    RETURN format('Las promos "%s" y "%s" son excluyentes y comparten productos de este pedido: lleva el regalo de una sola. Recargá la app y volvé a cargarlo.',
                  (SELECT nombre FROM promociones WHERE id = (v_par->>0)::bigint),
                  (SELECT nombre FROM promociones WHERE id = (v_par->>1)::bigint));
  END IF;

  RETURN NULL;
END
$fn$;

REVOKE EXECUTE ON FUNCTION public.regalo_fuera_de_promo(jsonb, jsonb, bigint, bigint, date) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Parches por ancla sobre la definicion viva
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.rr_parchar(p_def text, p_viejo text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  IF (length(p_def) - length(replace(p_def, p_viejo, ''))) / length(p_viejo) <> 1 THEN
    RAISE EXCEPTION '%: el fragmento no aparece exactamente una vez: revisar a mano', p_que;
  END IF;
  RETURN replace(p_def, p_viejo, p_nuevo);
END
$fn$;

-- 2a. crear_pedido_completo: el rechazo de regalo lleva codigo (#1153).
DO $crear$
DECLARE
  v_def text := pg_get_functiondef(
    'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.rr_parchar(v_def,
$q$        RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
          v_motivo_regalo || ' El pedido no se creó.'));
$q$,
$q$        -- #1153: el codigo deja al replay offline ofrecer "sincronizar sin el regalo".
        RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
          v_motivo_regalo || ' El pedido no se creó.'), 'codigo', 'regalo_fuera_de_promo');
$q$, 'crear_pedido_completo rechazo de regalo');
  EXECUTE v_def;
END
$crear$;

-- 2b. crear_pedido_completo_bot: revalida la promo al confirmar (#1154).
DO $bot$
DECLARE
  v_def text := pg_get_functiondef('public.crear_pedido_completo_bot(uuid,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.rr_parchar(v_def,
$q$    IF v_motivo_minimo IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'error', v_motivo_minimo);
    END IF;
  END;
$q$,
$q$    IF v_motivo_minimo IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'error', v_motivo_minimo);
    END IF;
  END;

  -- #1154: la promo se revalida al confirmar (la confirmacion vive 10 min y
  -- la promo puede apagarse, vencer o cambiar de productos en el medio). Misma
  -- guarda y misma exencion de admin que crear_pedido_completo.
  IF v_user_role <> 'admin' THEN
    DECLARE
      v_motivo_regalo TEXT;
    BEGIN
      v_motivo_regalo := public.regalo_fuera_de_promo(v_pendiente.items, v_pendiente.items,
                                                       v_pendiente.sucursal_id, NULL, v_fecha_pedido);
      IF v_motivo_regalo IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'error',
          replace(v_motivo_regalo, 'Recargá la app y volvé a cargarlo.', 'Hacé el pedido de nuevo.')
          || ' El pedido no se creó.');
      END IF;
    END;
  END IF;
$q$, 'crear_pedido_completo_bot cierre de la compra minima');
  EXECUTE v_def;
END
$bot$;

REVOKE EXECUTE ON FUNCTION public.crear_pedido_completo_bot(uuid, uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Verificacion estructural
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  f_fue text := 'public.regalo_fuera_de_promo(jsonb,jsonb,bigint,bigint,date)';
  f_cre text := 'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)';
  f_idm text := 'public.crear_pedido_idempotente(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid,text)';
  f_bot text := 'public.crear_pedido_completo_bot(uuid,uuid)';
  v_fue text := pg_get_functiondef(f_fue::regprocedure);
  v_cre text := pg_get_functiondef(f_cre::regprocedure);
  v_bot text := pg_get_functiondef(f_bot::regprocedure);
  f     text;
BEGIN
  -- Nada alcanzable con la anon key (PUBLIC incluido).
  FOREACH f IN ARRAY ARRAY[f_fue, f_cre, f_idm, f_bot] LOOP
    IF has_function_privilege('anon', f::regprocedure, 'EXECUTE') THEN
      RAISE EXCEPTION '% quedo alcanzable por anon', f;
    END IF;
  END LOOP;
  -- La guarda y el bot son de server; las dos RPCs del alta siguen para authenticated.
  IF has_function_privilege('authenticated', f_fue::regprocedure, 'EXECUTE')
     OR has_function_privilege('authenticated', f_bot::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'regalo_fuera_de_promo o crear_pedido_completo_bot quedo alcanzable por authenticated';
  END IF;
  IF NOT has_function_privilege('authenticated', f_cre::regprocedure, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', f_idm::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'crear_pedido_completo o crear_pedido_idempotente perdio EXECUTE para authenticated';
  END IF;

  IF position('v_d := LEAST(COALESCE(p_fecha, v_hoy), v_hoy);' IN v_fue) = 0
     OR position('editado el' IN v_fue) = 0
     -- sigue INVOKER: la llaman solo las RPCs SECURITY DEFINER
     OR v_fue LIKE '%SECURITY DEFINER%' THEN
    RAISE EXCEPTION 'regalo_fuera_de_promo no quedo como se esperaba';
  END IF;
  IF position('''codigo'', ''regalo_fuera_de_promo''' IN v_cre) = 0 THEN
    RAISE EXCEPTION 'crear_pedido_completo no devuelve el codigo del rechazo de regalo';
  END IF;
  -- La guarda del bot va antes de toda escritura.
  IF position('regalo_fuera_de_promo' IN v_bot) = 0
     OR position('regalo_fuera_de_promo' IN v_bot) > position('INSERT INTO pedidos' IN v_bot)
     OR position('regalo_fuera_de_promo' IN v_bot) > position('UPDATE productos' IN v_bot)
     OR v_bot NOT LIKE '%SECURITY DEFINER%' THEN
    RAISE EXCEPTION 'crear_pedido_completo_bot no quedo como se esperaba';
  END IF;

  -- Una sola sobrecarga de cada una (PGRST203).
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
         AND proname IN ('regalo_fuera_de_promo', 'crear_pedido_completo', 'crear_pedido_completo_bot')) <> 3 THEN
    RAISE EXCEPTION 'hay mas de una sobrecarga de alguna de las tres funciones';
  END IF;
END
$verif$;
