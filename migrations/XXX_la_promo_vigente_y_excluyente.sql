-- El regalo de quien no es admin tiene que ser de una promo vigente, y de una
-- sola promo por grupo excluyente (#1136, #1137)
--
-- La 356 (#1123) valida el producto y la cantidad del regalo que manda quien no
-- es admin, pero dejo afuera dos cosas:
--
--   * #1137, la vigencia. regalo_fuera_de_promo no miraba activo, fecha_inicio
--     ni fecha_fin: un request armado a mano (o un bundle viejo) cargaba el
--     regalo de una promo apagada o vencida. En prod, el pedido 6659 se cargo
--     con la promo 15 inactiva, 17 minutos antes de que el admin la reactivara.
--   * #1136, la exclusion. resolverConflictosExcluyentes (src/utils/promociones.ts)
--     elige una sola promo por grupo de excluyentes que comparten productos del
--     pedido; el server no lo replicaba y aceptaba el regalo de las dos, cada una
--     dentro de su propio tope. Hoy esta latente (1-9, 1-13 y 9-13 comparten 6
--     productos, y 1 y 9 estan inactivas).
--
-- Decision del dueno (2026-10-13), para quien no es admin (mismo criterio de
-- rol que la 356: perfiles.rol, no es_preventista(), trampa 4):
--
--   * Vigencia: la promo tiene que tener activo = true y estar vigente en
--     LEAST(fecha del pedido, hoy) o en hoy (hora argentina). La fecha del
--     pedido cubre el replay offline (p_fecha = el dia en que se tomo) que se
--     sincroniza despues de fecha_fin; "o en hoy" cubre el alta con fecha
--     anterior al inicio de la promo (ModalPedido resuelve las promos con hoy:
--     pedidos 633 y 642). El tope LEAST existe porque el server no limita
--     p_fecha a hoy fuera del VB: sin el, una fecha futura armada a mano
--     reclamaria hoy una promo que todavia no empezo. activo no guarda
--     historia: apagar una promo la apaga ya, tambien para la cola offline.
--   * Edicion: si el pedido ya tenia regalo de esa promo, se acepta aunque ya
--     no este vigente (la politica rige el alta y no hacia atras, corolario de
--     la trampa 8); el tope de la 356 sigue rigiendo.
--   * Exclusion: una promo con regalo por grupo excluyente. Se rechaza si dos
--     promos excluyentes con regalo en el request comparten un producto de una
--     linea de VENTA del pedido. No se exige la ganadora del union-find: el
--     usuario puede quitar la ganadora en el front (ModalPedido,
--     ModalEditarPedido) y entonces se regala la perdedora, que es legal. Con
--     pares alcanza: dos excluyentes que disparan y comparten un producto del
--     pedido caen siempre en el mismo componente, y todo conjunto sin pares en
--     conflicto se obtiene quitando las demas. Espejo:
--     src/utils/exclusionRegalo.espejo.json (vitest recorre todos los
--     subconjuntos de promos quitadas) y scripts/espejo-exclusion-regalo.mjs.
--   * El admin queda exento, como en la 356: la guarda vive en
--     regalo_fuera_de_promo, que las RPCs llaman solo para quien no es admin.
--     cambiar_cliente_pedido (solo admin) recarga con v_pedido.fecha las
--     lineas de un pedido cuya promo se pudo haber apagado.
--
-- No hay CHECK ni check de auditoria_integridad: la regla rige el alta, y
-- apagar una promo no puede volver ilegales los pedidos viejos (trampa 8).
--
-- regalo_fuera_de_promo pasa de 4 a 5 argumentos (p_fecha, sin DEFAULT): la de
-- 4 se dropea en esta misma migracion, DESPUES de parchar las dos RPCs
-- (trampa 5: dos sobrecargas superpuestas dan PGRST203; y aplicada a medias el
-- alta de quien no es admin fallaria con 42883). CREATE FUNCTION con otra firma
-- no hereda nada: los atributos de la viva (STABLE, SECURITY INVOKER,
-- search_path=public, sin EXECUTE para anon ni authenticated) van explicitos y
-- los vigila el $verif$. Funciona como invoker porque solo la llaman las RPCs
-- SECURITY DEFINER de postgres.
--
-- Las guardas son de solo lectura y van antes de toda escritura: no tocan
-- stock, GUCs, lotes ni costo_unitario_al_crear (STK-F, STK-D y COSTO-D
-- iguales). Los mensajes no calzan con PATRON_STOCK ni con pareceSesionVencida
-- (src/utils/rechazoDeNegocio.ts): el replay offline los da por terminales y
-- crear_pedido_idempotente no sella offline_id cuando success = false.
--
-- No se tocan crear_pedido_idempotente (le pasa p_fecha a crear_pedido_completo),
-- cambiar_cliente_pedido (solo admin, exento) ni crear_pedido_completo_bot (los
-- items los arma el server con la vigencia y la exclusion del edge function).
--
-- Ensayo: scripts/test-promo-vigente-excluyente-1136-1137.sql (y los de 1123,
-- 1112 y 1090, cuyas promos ahora empiezan ayer en hora argentina).

-- ---------------------------------------------------------------------------
-- 1. El primer par de promos excluyentes en conflicto (espejo de la exclusion
--    de resolverPromociones)
-- ---------------------------------------------------------------------------
-- p_items: las lineas del pedido como las manda el front, CON los regalos (que
-- no cuentan). p_promos: [{"id": n, "excluyente": bool, "productos": [ids]}],
-- las promos que traen regalo. Devuelve [a, b] (a < b, el primero por a y
-- despues por b) si dos promos excluyentes comparten el producto de una linea
-- de venta, o NULL. Las lineas con precio editado a mano cuentan (el front las
-- cuenta: skipOverride false). jsonb y no bigint[]: el gate la llama por
-- PostgREST.
CREATE OR REPLACE FUNCTION public.regalo_excluyentes_en_conflicto(p_items jsonb, p_promos jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SECURITY INVOKER
SET search_path = public
AS $fn$
  WITH ventas AS (
    SELECT DISTINCT NULLIF(e->>'producto_id', '')::numeric AS producto
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_items) = 'array'
                                     THEN p_items ELSE '[]'::jsonb END) e
     WHERE NOT COALESCE((e->>'es_bonificacion')::boolean, false)
       AND NULLIF(e->>'producto_id', '') IS NOT NULL
  ), en_pedido AS (
    SELECT DISTINCT NULLIF(pr->>'id', '')::numeric AS id, v.producto
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_promos) = 'array'
                                     THEN p_promos ELSE '[]'::jsonb END) pr
      CROSS JOIN LATERAL jsonb_array_elements_text(CASE WHEN jsonb_typeof(pr->'productos') = 'array'
                                                        THEN pr->'productos' ELSE '[]'::jsonb END) x
      JOIN ventas v ON v.producto = NULLIF(x, '')::numeric
     WHERE COALESCE((pr->>'excluyente')::boolean, false)
       AND NULLIF(pr->>'id', '') IS NOT NULL
  )
  SELECT jsonb_build_array(a.id, b.id)
    FROM en_pedido a
    JOIN en_pedido b ON b.producto = a.producto AND b.id > a.id
   ORDER BY a.id, b.id
   LIMIT 1;
$fn$;

REVOKE EXECUTE ON FUNCTION public.regalo_excluyentes_en_conflicto(jsonb, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.regalo_excluyentes_en_conflicto(jsonb, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- 2. regalo_fuera_de_promo con la fecha del pedido: vigencia y exclusion
-- ---------------------------------------------------------------------------
-- El cuerpo es el de la 356 (pg_get_functiondef de prod, 2026-10-13) con tres
-- cambios: el SELECT de la promo trae activo, fechas y modo_exclusion; el paso
-- 2b (vigencia, #1137) y el paso 5 (exclusion, #1136).
-- p_fecha: la fecha del pedido (en el alta, v_fecha_pedido; en la edicion,
-- pedidos.fecha). Sin DEFAULT: no puede haber dos firmas superpuestas.
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
    --     a proposito la alternativa "o en hoy" (topeada), para el replay
    --     offline y para el alta con fecha anterior al inicio de la promo. El
    --     invariante es que el server nunca sea MAS estricto que el front (si lo
    --     fuera, rechazaria pedidos honestos); lo prueban los casos V y VE de
    --     scripts/test-promo-vigente-excluyente-1136-1137.sql.
    --     En la edicion queda exenta la promo cuyo regalo el pedido ya tenia.
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
                    to_char(v_d, 'DD/MM/YYYY'));
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
-- 3. Las dos RPCs le pasan la fecha del pedido (parche por ancla sobre la
--    definicion viva). Solo cambia la llamada; el resto del cuerpo queda igual.
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

DO $crear$
DECLARE
  v_def text := pg_get_functiondef(
    'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.rr_parchar(v_def,
$q$      v_motivo_regalo := public.regalo_fuera_de_promo(p_items, p_items, v_sucursal, NULL);
$q$,
$q$      -- mig #1136/#1137: la fecha del pedido, para la vigencia de la promo.
      v_motivo_regalo := public.regalo_fuera_de_promo(p_items, p_items, v_sucursal, NULL, v_fecha_pedido);
$q$, 'crear_pedido_completo llamada a regalo_fuera_de_promo');
  EXECUTE v_def;
END
$crear$;

DO $editar$
DECLARE
  v_def text := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.rr_parchar(v_def,
$q$        p_items_nuevos, v_sucursal, p_pedido_id);
$q$,
$q$        p_items_nuevos, v_sucursal, p_pedido_id,
        -- mig #1136/#1137: la fecha del pedido, para la vigencia de la promo.
        (SELECT fecha FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal));
$q$, 'actualizar_pedido_items llamada a regalo_fuera_de_promo');
  EXECUTE v_def;
END
$editar$;

-- La firma vieja se va DESPUES de los parches (trampa 5).
DROP FUNCTION public.regalo_fuera_de_promo(jsonb, jsonb, bigint, bigint);

-- ---------------------------------------------------------------------------
-- Verificacion estructural
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  f_cre text := 'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)';
  f_act text := 'public.actualizar_pedido_items(bigint,jsonb,uuid)';
  f_fue text := 'public.regalo_fuera_de_promo(jsonb,jsonb,bigint,bigint,date)';
  f_exc text := 'public.regalo_excluyentes_en_conflicto(jsonb,jsonb)';
  v_cre text := pg_get_functiondef(f_cre::regprocedure);
  v_act text := pg_get_functiondef(f_act::regprocedure);
  f     text;
  v_p   record;
BEGIN
  IF v_cre NOT LIKE '%regalo_fuera_de_promo(p_items, p_items, v_sucursal, NULL, v_fecha_pedido)%'
     -- despues del VB y antes de la primera escritura
     OR strpos(v_cre, 'regalo_fuera_de_promo') < strpos(v_cre, 'Un vale blanco no lleva promociones')
     OR strpos(v_cre, 'regalo_fuera_de_promo') > strpos(v_cre, 'INSERT INTO') THEN
    RAISE EXCEPTION 'crear_pedido_completo no quedo como se esperaba';
  END IF;
  IF v_act NOT LIKE '%p_items_nuevos, v_sucursal, p_pedido_id,%(SELECT fecha FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal));%'
     -- despues de regalo_elemento_con_cadena y antes de la primera escritura
     OR strpos(v_act, 'regalo_fuera_de_promo') < strpos(v_act, 'public.regalo_elemento_con_cadena(')
     OR strpos(v_act, 'regalo_fuera_de_promo') > strpos(v_act, 'DELETE FROM pedido_items') THEN
    RAISE EXCEPTION 'actualizar_pedido_items no quedo como se esperaba';
  END IF;

  FOREACH f IN ARRAY ARRAY[f_cre, f_act] LOOP
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = f::regprocedure)
       OR (SELECT proconfig FROM pg_proc WHERE oid = f::regprocedure) IS DISTINCT FROM ARRAY['search_path=public'] THEN
      RAISE EXCEPTION '% dejo de ser SECURITY DEFINER con search_path=public', f;
    END IF;
    IF has_function_privilege('anon', f, 'EXECUTE') OR NOT has_function_privilege('authenticated', f, 'EXECUTE') THEN
      RAISE EXCEPTION 'los EXECUTE de % cambiaron', f;
    END IF;
  END LOOP;

  -- Las dos funciones de la guarda: invoker, search_path=public, de postgres,
  -- y sin EXECUTE para anon ni authenticated.
  FOR v_p IN
    SELECT f_fue AS f, 's' AS vol UNION ALL SELECT f_exc, 'i'
  LOOP
    IF (SELECT prosecdef FROM pg_proc WHERE oid = v_p.f::regprocedure)
       OR (SELECT provolatile::text FROM pg_proc WHERE oid = v_p.f::regprocedure) <> v_p.vol
       OR (SELECT proconfig FROM pg_proc WHERE oid = v_p.f::regprocedure) IS DISTINCT FROM ARRAY['search_path=public']
       OR (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid = v_p.f::regprocedure) <> 'postgres' THEN
      RAISE EXCEPTION '% no quedo con los atributos esperados (invoker, %, search_path=public, postgres)', v_p.f, v_p.vol;
    END IF;
    IF has_function_privilege('anon', v_p.f, 'EXECUTE') OR has_function_privilege('authenticated', v_p.f, 'EXECUTE') THEN
      RAISE EXCEPTION 'anon o authenticated pueden ejecutar %', v_p.f;
    END IF;
  END LOOP;
  IF NOT has_function_privilege('service_role', f_exc, 'EXECUTE') THEN
    RAISE EXCEPTION 'service_role no puede ejecutar regalo_excluyentes_en_conflicto (gate de paridad)';
  END IF;

  -- La firma vieja ya no existe y queda una sola sobrecarga de cada una (PGRST203).
  IF to_regprocedure('public.regalo_fuera_de_promo(jsonb,jsonb,bigint,bigint)') IS NOT NULL THEN
    RAISE EXCEPTION 'quedo la regalo_fuera_de_promo de 4 argumentos';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc
              WHERE pronamespace = 'public'::regnamespace
                AND proname IN ('crear_pedido_completo', 'actualizar_pedido_items',
                                'regalo_fuera_de_promo', 'regalo_excluyentes_en_conflicto')
              GROUP BY proname HAVING count(*) > 1) THEN
    RAISE EXCEPTION 'alguna de las funciones quedo con mas de una sobrecarga';
  END IF;
END
$verif$;
