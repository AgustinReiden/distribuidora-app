-- El regalo de quien no es admin se valida al cargar y al editar (#1123)
--
-- crear_pedido_completo y actualizar_pedido_items aceptaban de cualquier rol
-- que carga pedidos (preventista, encargado) una linea es_bonificacion con el
-- producto y la cantidad que mandara el llamador: un bundle PWA viejo o un
-- request a mano cargaba V x10 mas un regalo de la promo P con un producto de
-- otra categoria y cantidad 50, a $0, y el server lo guardaba, movia stock y
-- lo registraba como regalo de P. Una linea de regalo sin promocion_id iba a
-- $0 sin mover stock ni tocar el acumulador. La guarda de #1112 (351) solo
-- cubre el reparto (dos o mas lineas de la misma promo). El front ya manda,
-- para quien no es admin, el regalo default de la promo con la cantidad de la
-- promo (ModalPedido, puedeElegir = isAdmin): esto lo exige el server.
--
-- Decision del dueno (2026-10-13). Para quien no es admin (perfiles.rol, igual
-- que #1112; no es_preventista(), trampa 4):
--
--   * Producto: el default vigente de la promo (COALESCE(producto_regalo_id,
--     ajuste_producto_id)) o uno de su misma categoria y subcategoria
--     (regalo_misma_categoria, la regla de #950). La categoria cubre la
--     rotacion semanal del default (promo 13): un replay offline tomado antes
--     de la rotacion sigue entrando. Sin default, uno de los disparadores de
--     la promo (el fallback "primer disparador" del front). Al editar se
--     acepta ademas la linea que hereda cadena (_cadena no nulo: la puso el
--     server con regalo_elemento_con_cadena, el llamador no puede) y el mismo
--     producto de la UNICA linea de regalo que la promo ya tenia en el pedido
--     (el default viejo despues de una rotacion). Solo con una linea: una
--     parte de otra categoria de un reparto (dividir_regalo_pedido no mira la
--     categoria) no puede pasar a ser la linea unica con toda la cantidad.
--   * Cantidad: la suma de las lineas de regalo de la promo, HASTA (<=)
--     floor(venta de sus productos / cantidad_compra) * cantidad_bonificacion,
--     la formula de resolverPromociones (regalo_tope_promo, con su espejo).
--     Se mide sobre lo que MANDO el llamador: en la edicion, p_items_nuevos
--     crudo, antes de conservar repartos (275/#1090), en la unidad de la
--     bonificacion. Si se midiera sobre v_items, una promo cuyo reparto
--     conserva el server no tendria ninguna linea que controlar: se podian
--     bajar los disparadores y quedarse con todo el regalo.
--   * Regalo sin promocion_id: se rechaza solo a quien no es admin. Al editar
--     se acepta si el pedido ya tenia esa linea sin promo (mismo producto, la
--     cantidad no sube): pedido_items_promocion_id_fkey es ON DELETE SET NULL,
--     asi que borrar una promo deja sus regalos historicos sin promocion_id de
--     forma legitima. Por eso tampoco hay CHECK ni check de auditoria: un CHECK
--     impediria borrar una promo con historia y un check REGALO-* daria rojo
--     despues de cada borrado. (Ids vigentes de la familia: PROMO-A y PROMO-B.)
--   * Promo inexistente en la sucursal: rechazo.
--   * El admin queda exento de todo. cambiar_cliente_pedido (solo admin)
--     recarga por crear_pedido_completo las lineas de un pedido cuya promo se
--     pudo haber borrado. Si se abre al encargado, revisar aca.
--   * Fuera de alcance (issues aparte): la exclusion entre promos excluyentes
--     y la vigencia (activo, fecha_inicio, fecha_fin) de la promo.
--
-- Por que no en validar_precio_item_pedido: el trigger tambien lo usan las
-- inserciones legitimas de sustituir_regalo_pedido y dividir_regalo_pedido, y
-- no conoce el contexto del alta. La puerta son las dos RPCs: authenticated no
-- tiene INSERT ni UPDATE sobre pedido_items por REST.
--
-- Las dos guardas son de solo lectura y van antes de toda escritura. No tocan
-- stock, GUCs, lotes ni costo_unitario_al_crear (STK-F, STK-D y COSTO-D
-- iguales). Los mensajes no calzan con PATRON_STOCK ni con pareceSesionVencida
-- (src/utils/rechazoDeNegocio.ts): el replay offline los da por terminales y
-- crear_pedido_idempotente no sella offline_id cuando success = false.
--
-- Funciones nuevas: regalo_tope_promo (pura, espejo de resolverPromociones;
-- gate de paridad scripts/espejo-tope-regalo.mjs) y regalo_fuera_de_promo.
-- Solo las llaman las RPCs SECURITY DEFINER (y el gate, como service_role):
-- REVOKE a PUBLIC, anon y authenticated en esta misma migracion.
--
-- En prod, al 2026-10-13: 0 regalos sin promocion_id, 0 por encima del tope en
-- toda la historia, 0 regalos fuera de categoria desde julio. Sin backfill.
--
-- Ensayo: scripts/test-regalo-alta-1123.sql (y scripts/test-alta-reparto-rol-1112.sql,
-- cuyo fixture ahora siembra reglas y disparadores en sus promos).

-- ---------------------------------------------------------------------------
-- 1. El tope de regalo de una promo (espejo de resolverPromociones)
-- ---------------------------------------------------------------------------
-- p_items: lineas del pedido como las manda el front ({producto_id, cantidad,
-- es_bonificacion, ...}). p_productos: array jsonb de ids de los productos de
-- la promo (jsonb y no bigint[]: el gate la llama por PostgREST). Suman solo
-- las lineas que NO son regalo y cuyo producto es de la promo; las de precio
-- editado a mano suman igual (skipOverride: false en el front). Compra nula o
-- <= 0, o bonificacion nula o <= 0, dan 0.
CREATE OR REPLACE FUNCTION public.regalo_tope_promo(
  p_items jsonb, p_productos jsonb, p_compra numeric, p_bonif numeric)
RETURNS integer
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $fn$
  SELECT CASE
    WHEN p_compra IS NULL OR p_compra <= 0 OR COALESCE(p_bonif, 0) <= 0 THEN 0
    ELSE floor(
           floor(COALESCE((
             SELECT SUM(COALESCE(NULLIF(e->>'cantidad', '')::numeric, 0))
               FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_items) = 'array'
                                              THEN p_items ELSE '[]'::jsonb END) e
              WHERE NOT COALESCE((e->>'es_bonificacion')::boolean, false)
                AND NULLIF(e->>'producto_id', '')::numeric IN (
                      SELECT NULLIF(x, '')::numeric
                        FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(p_productos) = 'array'
                                                            THEN p_productos ELSE '[]'::jsonb END) x)
           ), 0) / p_compra) * p_bonif)::integer
  END;
$fn$;

REVOKE EXECUTE ON FUNCTION public.regalo_tope_promo(jsonb, jsonb, numeric, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.regalo_tope_promo(jsonb, jsonb, numeric, numeric) TO service_role;

-- ---------------------------------------------------------------------------
-- 2. El primer motivo por el que los regalos de quien no es admin no entran
-- ---------------------------------------------------------------------------
-- p_items_producto: las lineas cuyo PRODUCTO se juzga (en el alta, p_items; en
-- la edicion, v_items sin las lineas que el server conservo de un reparto).
-- p_items_cantidad: las lineas cuya CANTIDAD se mide contra el tope (en el
-- alta, p_items; en la edicion, p_items_nuevos crudo). p_pedido_id: NULL en el
-- alta; en la edicion habilita las exenciones de lo que el pedido ya tenia.
-- Devuelve NULL si todo entra.
CREATE OR REPLACE FUNCTION public.regalo_fuera_de_promo(
  p_items_producto jsonb, p_items_cantidad jsonb, p_sucursal bigint, p_pedido_id bigint)
RETURNS text
LANGUAGE plpgsql
STABLE
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
BEGIN
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

  -- 2 a 4, por promo: que exista, el producto de cada linea y la cantidad.
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
                      WHERE pp.promocion_id = p.id AND pp.sucursal_id = p_sucursal), '[]'::jsonb) AS productos
      INTO r
      FROM promociones p
     WHERE p.id = v_promo.id AND p.sucursal_id = p_sucursal;
    IF NOT FOUND THEN
      RETURN format('La promoción %s no existe en esta sucursal.', v_promo.id);
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

  RETURN NULL;
END
$fn$;

REVOKE EXECUTE ON FUNCTION public.regalo_fuera_de_promo(jsonb, jsonb, bigint, bigint) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Las guardas en las dos RPCs (parche por ancla sobre la definicion viva)
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
$q$  -- Cubre SOLO el reparto; una sola linea de regalo con otro producto o
  -- cantidad sigue abierta para cualquier rol (issue aparte).
$q$,
$q$  -- Cubre SOLO el reparto; el producto y la cantidad de una sola linea de
  -- regalo los valida la guarda de #1123, mas abajo.
$q$, 'crear_pedido_completo comentario de #1112');

  v_def := pg_temp.rr_parchar(v_def,
$q$  -- El total lo calcula el servidor (mig 235). Antes se insertaba p_total tal
$q$,
$q$  -- mig #1123: el regalo de quien no es admin. Producto: el default vigente de
  -- la promo o uno de su misma categoria (regalo_misma_categoria, #950).
  -- Cantidad: hasta el tope de la promo con las lineas de venta que vinieron
  -- (regalo_tope_promo, espejo de resolverPromociones). Sin promocion_id o con
  -- una promo de otra sucursal: no entra. Solo lectura y antes de toda
  -- escritura; despues del VB, que tiene su propio mensaje para los regalos.
  -- El admin queda exento: cambiar_cliente_pedido (solo admin) recarga por
  -- aca las lineas de un pedido cuya promo se pudo haber borrado (la FK es
  -- ON DELETE SET NULL). Mismo criterio de rol que #1112 (perfiles.rol).
  IF v_user_role <> 'admin' AND p_items IS NOT NULL AND jsonb_typeof(p_items) = 'array' THEN
    DECLARE
      v_motivo_regalo TEXT;
    BEGIN
      v_motivo_regalo := public.regalo_fuera_de_promo(p_items, p_items, v_sucursal, NULL);
      IF v_motivo_regalo IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
          v_motivo_regalo || ' El pedido no se creó.'));
      END IF;
    END;
  END IF;

  -- El total lo calcula el servidor (mig 235). Antes se insertaba p_total tal
$q$, 'crear_pedido_completo guarda del regalo');
  EXECUTE v_def;
END
$crear$;

DO $editar$
DECLARE
  v_def text := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.rr_parchar(v_def,
$q$    FROM jsonb_array_elements(v_items) WITH ORDINALITY AS x(e, o);

  IF v_user_role IN ('preventista') THEN
$q$,
$q$    FROM jsonb_array_elements(v_items) WITH ORDINALITY AS x(e, o);

  -- mig #1123: el regalo de quien no es admin, tambien al editar. Va despues
  -- de conservar los repartos (275/#1090), de la guarda de #1112 y de
  -- regalo_elemento_con_cadena, y antes de toda escritura.
  --   * El PRODUCTO se juzga sobre v_items sin las lineas que el server
  --     conservo de un reparto (marcadas con v_marca_reparto, que el llamador
  --     no puede conocer). Se acepta ademas la linea que hereda cadena
  --     (_cadena, que solo pone el server) y el mismo producto de la unica
  --     linea de regalo que la promo ya tenia.
  --   * La CANTIDAD se mide sobre p_items_nuevos crudo, lo que mando el
  --     llamador en la unidad de la bonificacion (para una promo conservada es
  --     v_total_json): un reparto conservado tambien tiene que caber en el
  --     tope que dan las lineas de venta de ESTA edicion. Va antes de
  --     regalo_sustitucion_resuelta, que convierte a la unidad del sustituto.
  -- Incluye al encargado. El admin queda exento.
  IF v_user_role <> 'admin' THEN
    DECLARE
      v_motivo_regalo TEXT;
    BEGIN
      v_motivo_regalo := public.regalo_fuera_de_promo(
        (SELECT COALESCE(jsonb_agg(x.e ORDER BY x.o), '[]'::jsonb)
           FROM jsonb_array_elements(v_items) WITH ORDINALITY AS x(e, o)
          WHERE x.e->>'_reparto' IS DISTINCT FROM v_marca_reparto),
        p_items_nuevos, v_sucursal, p_pedido_id);
      IF v_motivo_regalo IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
          v_motivo_regalo || ' El pedido no se modificó.'));
      END IF;
    END;
  END IF;

  IF v_user_role IN ('preventista') THEN
$q$, 'actualizar_pedido_items guarda del regalo');
  EXECUTE v_def;
END
$editar$;

-- ---------------------------------------------------------------------------
-- Verificacion estructural
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  f_cre text := 'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)';
  f_act text := 'public.actualizar_pedido_items(bigint,jsonb,uuid)';
  f_top text := 'public.regalo_tope_promo(jsonb,jsonb,numeric,numeric)';
  f_fue text := 'public.regalo_fuera_de_promo(jsonb,jsonb,bigint,bigint)';
  v_cre text := pg_get_functiondef(f_cre::regprocedure);
  v_act text := pg_get_functiondef(f_act::regprocedure);
  f     text;
BEGIN
  IF v_cre NOT LIKE '%regalo_fuera_de_promo(p_items, p_items, v_sucursal, NULL)%'
     OR v_cre NOT LIKE '%Solo un admin puede repartir el regalo%'
     OR v_cre NOT LIKE '%Un vale blanco no lleva promociones ni regalos%'
     -- despues del VB y antes de la primera escritura
     OR strpos(v_cre, 'regalo_fuera_de_promo') < strpos(v_cre, 'Un vale blanco no lleva promociones')
     OR strpos(v_cre, 'regalo_fuera_de_promo') > strpos(v_cre, 'INSERT INTO') THEN
    RAISE EXCEPTION 'crear_pedido_completo no quedo como se esperaba';
  END IF;
  IF v_act NOT LIKE '%regalo_fuera_de_promo(%p_items_nuevos, v_sucursal, p_pedido_id)%'
     OR v_act NOT LIKE '%Solo un admin puede repartir el regalo de una promo en varios productos al editar%'
     -- despues de regalo_elemento_con_cadena y antes de la primera escritura
     OR strpos(v_act, 'regalo_fuera_de_promo') < strpos(v_act, 'public.regalo_elemento_con_cadena(')
     OR strpos(v_act, 'regalo_fuera_de_promo') > strpos(v_act, 'DELETE FROM pedido_items') THEN
    RAISE EXCEPTION 'actualizar_pedido_items no quedo como se esperaba';
  END IF;

  FOREACH f IN ARRAY ARRAY[f_cre, f_act] LOOP
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = f::regprocedure) THEN
      RAISE EXCEPTION '% dejo de ser SECURITY DEFINER', f;
    END IF;
    IF has_function_privilege('anon', f, 'EXECUTE') OR NOT has_function_privilege('authenticated', f, 'EXECUTE') THEN
      RAISE EXCEPTION 'los EXECUTE de % cambiaron', f;
    END IF;
  END LOOP;

  FOREACH f IN ARRAY ARRAY[f_top, f_fue] LOOP
    IF has_function_privilege('anon', f, 'EXECUTE') OR has_function_privilege('authenticated', f, 'EXECUTE') THEN
      RAISE EXCEPTION 'anon o authenticated pueden ejecutar %', f;
    END IF;
  END LOOP;
  IF NOT has_function_privilege('service_role', f_top, 'EXECUTE') THEN
    RAISE EXCEPTION 'service_role no puede ejecutar regalo_tope_promo (gate de paridad)';
  END IF;

  -- Una sola sobrecarga de cada una (PGRST203).
  IF EXISTS (SELECT 1 FROM pg_proc
              WHERE pronamespace = 'public'::regnamespace
                AND proname IN ('crear_pedido_completo', 'actualizar_pedido_items',
                                'regalo_tope_promo', 'regalo_fuera_de_promo')
              GROUP BY proname HAVING count(*) > 1) THEN
    RAISE EXCEPTION 'alguna de las funciones quedo con mas de una sobrecarga';
  END IF;
END
$verif$;
