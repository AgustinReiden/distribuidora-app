-- =========================================================================
-- mig 331 · EL REGALO CONSERVA SU SABOR AL EDITAR (#1016) Y LA CADENA SE
--           ORDENA POR ID (#1051)
--
-- #1016 · EL PROBLEMA
-- -------------------
-- `crear_pedido_completo` y `crear_pedido_completo_bot` arman la descripcion
-- del regalo con la regla de la 271 (#830): si el regalo no es del sabor
-- default de la promo, prefijo de la promo + nombre del producto entregado.
-- `actualizar_pedido_items` no: al editar, toda linea de regalo (menos las de
-- un reparto conservado) tomaba `promociones.descripcion_regalo` tal cual, que
-- habla del default de HOY. La promo 13 rota el default cada semana: un pedido
-- con Limon editado despues de la rotacion --aunque no se toque nada-- quedaba
-- diciendo Manzana en la hoja de ruta, y desde #996 eso dejaba ademas una fila
-- 'items' en el historial. El 2026-10-09: 161 de 330 lineas de regalo de los
-- ultimos 30 dias no eran del default actual.
--
-- LA REGLA (decision del dueno, 2026-10-09)
-- -----------------------------------------
-- · La regla de la 271 vive en UNA funcion, `regalo_descripcion_de_linea`, y la
--   usan la creacion (app y bot) y la edicion.
-- · Al editar, una linea de regalo que YA estaba --misma promo, mismo producto
--   final despues de la cadena de sustituciones-- conserva su descripcion. Si
--   tenia marca, se conserva la base solo cuando el trigger la va a reponer;
--   la parte de un reparto que se disuelve no la recupera (el reparto corta la
--   cadena) y va con la regla: si no, una linea de Manzana diria "Limon".
--   Las lineas de prod se crearon cuando su sabor ERA el default y guardan el
--   texto escrito a mano de la promo ("2 Botellas Manaos Limon 3LT"); la regla
--   armaria "2 Botellas MANAOS LIMON 3 LT" y la primera edicion cambiaria el
--   texto y dejaria historial sin que nadie tocara nada. La regla se aplica a una linea nueva o a un sabor que cambio.
--   Contra aceptado: corregir el texto de una promo no reescribe los pedidos
--   viejos al editarlos.
--
-- #1051 · LA CADENA SE ORDENA POR ID
-- ----------------------------------
-- `regalo_cadena_pasos` y el corte del reparto en `regalo_sustitucion_resuelta`
-- ordenaban por (created_at, id). created_at es now(), el inicio de la
-- transaccion, y sustituir_regalo_pedido serializa con FOR UPDATE: si dos
-- sustituciones del mismo item se cruzan, la que empezo antes y tomo el lock
-- despues tiene fecha menor e id mayor, y la cadena se cortaba antes de tiempo.
-- El id sale del INSERT, despues del lock: es el orden real (mientras la
-- secuencia de pedido_item_sustituciones siga con CACHE 1: con cache, cada
-- sesion reserva su tanda de ids y el orden se pierde). Mismo cambio en el
-- espejo del front (pasosDeCadena, repartoRegalo.ts) y en el fixture de paridad
-- (src/utils/cadenaSustitucion.espejo.json), que suma dos casos con la fecha en
-- contra del id. El 2026-10-09 habia 0 pares invertidos en prod: no hay datos
-- que cambien de lectura.
--
-- #1051 · LA MARCA "[Sustituido por: ...]"
-- ---------------------------------------
-- La arman ahora dos funciones puras, y las usan el trigger de sustituciones,
-- sustituir_regalo_pedido y dividir_regalo_pedido:
-- · `regalo_descripcion_base`: saca la marca desde la PRIMERA hasta el final. La
--   regex anterior ('[^\]]*\]') se cortaba en el primer ']' de un nombre de
--   producto y dejaba basura en la base.
-- · `regalo_descripcion_con_marca`: base + UNA marca; sin base, la marca sola
--   (una promo sin descripcion_regalo dejaba ' [Sustituido por: X]', con un
--   espacio adelante).
-- · `regalo_raiz_cadena`: el producto con el que arranco la cadena que termina en
--   un producto (la misma caminata hacia atras que raizDeSustitucion() del
--   front). La marca va solo si el final es DISTINTO de la raiz: una vuelta
--   A -> P -> A dejaba "[Sustituido por: A]". Por la misma regla, un ajuste de
--   cantidad sobre el mismo producto (A -> A) tampoco la lleva, ni la parte de
--   un reparto que vuelve a la raiz de la linea (dividir_regalo_pedido).
--
-- COSTO, STOCK, LOTES
-- -------------------
-- · Ningun camino nuevo mueve stock ni escribe costo. actualizar_pedido_items
--   sigue valuando con costo_valuacion despues del INSERT ... RETURNING (mig
--   257) y moviendo stock con lo que quedo en la fila (252/295); el trigger y
--   sustituir no cambian su costo ni su etiqueta de stock. COSTO-D y STK-F no
--   cambian.
--
-- Permisos: las cuatro funciones nuevas corren solo dentro de funciones del
-- server (las RPCs y el trigger son SECURITY DEFINER) -> REVOKE a PUBLIC, anon
-- y authenticated. Las parchadas conservan firma, ACL, DEFINER y search_path
-- (el $verif$ lo compara).
-- =========================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 0 · Andamio. Se dropea al final.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _mig1016_acl ON COMMIT DROP AS
SELECT p.oid::regprocedure::text AS fn, p.proacl::text AS acl, p.prosecdef, p.proconfig::text AS cfg
  FROM pg_proc p
 WHERE p.pronamespace = 'public'::regnamespace
   AND p.proname IN ('crear_pedido_completo', 'crear_pedido_completo_bot', 'actualizar_pedido_items',
                     'sustituir_regalo_pedido', 'dividir_regalo_pedido',
                     'aplicar_sustituciones_regalo_pre_insert',
                     'regalo_sustitucion_resuelta', 'regalo_cadena_pasos');

CREATE OR REPLACE FUNCTION public._mig1016_ancla(
  p_funcion regprocedure, p_ancla text, p_nuevo text
) RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text;
  v_ancla text := replace(p_ancla, E'\r', '');
  v_veces int;
BEGIN
  v_def := pg_get_functiondef(p_funcion);
  v_veces := (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'mig1016 · el ancla aparece % veces en % (se esperaba 1). El cuerpo vivo cambio: revisar a mano. Ancla: %',
      v_veces, p_funcion, left(v_ancla, 160);
  END IF;
  EXECUTE replace(v_def, v_ancla, replace(p_nuevo, E'\r', ''));
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 1 · Las funciones nuevas.
-- ---------------------------------------------------------------------------

-- La regla de la 271 (#830), en un solo lugar: el sabor default lleva el texto
-- de la promo; otro sabor, el prefijo de la promo ("2 Botellas ") + el nombre
-- del producto. NULL si la promo no existe en la sucursal.
CREATE FUNCTION public.regalo_descripcion_de_linea(
  p_promocion_id bigint, p_producto_id bigint, p_sucursal_id bigint
) RETURNS text
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $fn$
  SELECT CASE
           WHEN pr.producto_regalo_id IS DISTINCT FROM p_producto_id AND pr.descripcion_regalo IS NOT NULL
             THEN COALESCE(substring(pr.descripcion_regalo from '^\d+\s+\S+\s+'), '')
                  || COALESCE((SELECT nombre FROM productos
                                WHERE id = p_producto_id AND sucursal_id = p_sucursal_id), '')
           ELSE pr.descripcion_regalo
         END
    FROM promociones pr
   WHERE pr.id = p_promocion_id AND pr.sucursal_id = p_sucursal_id;
$fn$;

-- La descripcion sin la marca. Desde la PRIMERA marca hasta el final: un nombre
-- con ']' cortaba la regex anterior, y una linea vieja con dos marcas (pedido
-- 3351) queda limpia igual. Saca UN espacio adelante y no '\s*': la base queda
-- como estaba aunque termine en espacio. NULL si no queda nada.
CREATE FUNCTION public.regalo_descripcion_base(p_descripcion text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public'
AS $fn$
  SELECT NULLIF(regexp_replace(COALESCE(p_descripcion, ''), ' ?\[Sustituido por:.*$', ''), '');
$fn$;

-- La base + UNA marca, con un espacio entre las dos (rtrim: el nombre de un
-- producto puede terminar en espacio, y la regla de la 271 lo arrastra). Sin
-- base, la marca sola.
CREATE FUNCTION public.regalo_descripcion_con_marca(p_descripcion text, p_nombre_sustituto text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public'
AS $fn$
  SELECT COALESCE(NULLIF(rtrim(public.regalo_descripcion_base(p_descripcion)), '') || ' ', '')
         || '[Sustituido por: ' || COALESCE(p_nombre_sustituto, '?') || ']';
$fn$;

-- El producto con el que arranco la cadena que termina en p_producto_id: desde
-- el final, el eslabon vigente mas nuevo que llega a el, despues el anterior
-- que llega a su original, y asi. Vigente = posterior al ultimo reparto y no
-- del reparto (mig 275). Si nada llega a p_producto_id, es la raiz. Espejo de
-- raizDeSustitucion() en src/utils/repartoRegalo.ts.
CREATE FUNCTION public.regalo_raiz_cadena(
  p_pedido_id bigint, p_promocion_id bigint, p_producto_id bigint, p_sucursal_id bigint
) RETURNS bigint
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $fn$
DECLARE
  v_corte bigint;
  v_hasta bigint;
  v_nodo  bigint := p_producto_id;
  v_s     record;
BEGIN
  SELECT max(s.id) INTO v_corte
    FROM pedido_item_sustituciones s
   WHERE s.pedido_id = p_pedido_id AND s.promocion_id = p_promocion_id
     AND s.sucursal_id = p_sucursal_id AND s.reparto_id IS NOT NULL;
  LOOP
    SELECT s.id, s.producto_original_id INTO v_s
      FROM pedido_item_sustituciones s
     WHERE s.pedido_id = p_pedido_id AND s.promocion_id = p_promocion_id
       AND s.sucursal_id = p_sucursal_id AND s.reparto_id IS NULL
       AND s.producto_sustituto_id = v_nodo
       AND (v_corte IS NULL OR s.id > v_corte)
       AND (v_hasta IS NULL OR s.id < v_hasta)
     ORDER BY s.id DESC
     LIMIT 1;
    EXIT WHEN NOT FOUND;
    v_nodo  := v_s.producto_original_id;
    v_hasta := v_s.id;
  END LOOP;
  RETURN v_nodo;
END;
$fn$;

REVOKE ALL ON FUNCTION public.regalo_descripcion_de_linea(bigint, bigint, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.regalo_descripcion_base(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.regalo_descripcion_con_marca(text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.regalo_raiz_cadena(bigint, bigint, bigint, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.regalo_descripcion_de_linea(bigint, bigint, bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.regalo_descripcion_base(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.regalo_descripcion_con_marca(text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.regalo_raiz_cadena(bigint, bigint, bigint, bigint) TO service_role;

-- ---------------------------------------------------------------------------
-- 2 · #1051: la cadena por id. Cuerpos enteros (son chicos); CREATE OR REPLACE
--     conserva la ACL.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.regalo_cadena_pasos(p_eslabones jsonb, p_producto_id bigint)
RETURNS bigint[]
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $fn$
DECLARE
  -- Los eslabones de UNA promo, por id (#1051): created_at es el inicio de la
  -- transaccion y el id sale despues del lock, asi que el id es el orden real.
  -- Espejo: pasosDeCadena() en repartoRegalo.ts.
  v_ids   bigint[];
  v_orig  bigint[];
  v_sust  bigint[];
  v_rep   boolean[];
  v_n     int;
  -- Posicion del ultimo eslabon aplicado (o del ultimo reparto, al arrancar).
  v_desde int := 0;
  v_i     int;
  v_nodo  bigint := p_producto_id;
  v_pasos bigint[] := '{}';
BEGIN
  SELECT array_agg((e->>'id')::bigint ORDER BY (e->>'id')::bigint),
         array_agg((e->>'producto_original_id')::bigint ORDER BY (e->>'id')::bigint),
         array_agg((e->>'producto_sustituto_id')::bigint ORDER BY (e->>'id')::bigint),
         array_agg((e->>'reparto_id') IS NOT NULL ORDER BY (e->>'id')::bigint)
    INTO v_ids, v_orig, v_sust, v_rep
    FROM jsonb_array_elements(COALESCE(p_eslabones, '[]'::jsonb)) e;
  v_n := COALESCE(array_length(v_ids, 1), 0);

  -- Un reparto es la ultima decision sobre la composicion del regalo y anula
  -- lo anterior (mig 275): se arranca despues del ULTIMO, y sus filas no
  -- reescriben nada.
  FOR v_i IN 1..v_n LOOP
    IF v_rep[v_i] THEN
      v_desde := v_i;
    END IF;
  END LOOP;

  -- #1010: SIEMPRE el siguiente eslabon --el primero posterior al ultimo
  -- aplicado cuyo original sea el producto actual--, no el mas nuevo.
  LOOP
    v_i := v_desde + 1;
    WHILE v_i <= v_n AND (v_rep[v_i] OR v_orig[v_i] IS DISTINCT FROM v_nodo) LOOP
      v_i := v_i + 1;
    END LOOP;
    EXIT WHEN v_i > v_n;
    v_pasos := v_pasos || v_ids[v_i];
    v_nodo  := v_sust[v_i];
    v_desde := v_i;
  END LOOP;

  RETURN v_pasos;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.regalo_sustitucion_resuelta(
  p_pedido_id bigint, p_promocion_id bigint, p_producto_id bigint,
  p_sucursal_id bigint, p_cantidad numeric
) RETURNS TABLE (producto_id bigint, cantidad numeric, pasos integer, ya_sustituido boolean)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $fn$
DECLARE
  v_eslabones jsonb;
  v_id        bigint;
  -- El ultimo reparto de la promo: lo anterior ya no vale (mig 275). Por id
  -- (#1051), como regalo_cadena_pasos.
  v_corte_id  bigint;
  v_nodo      bigint  := p_producto_id;
  -- Contenedor del nodo, para su factor (el del original es el mismo producto,
  -- como en la 295; el de un sustituto, el que eligio el admin).
  v_ajuste    bigint  := p_producto_id;
  v_cant      numeric := p_cantidad;
  v_pasos     integer := 0;
  v_s         pedido_item_sustituciones%ROWTYPE;
BEGIN
  -- mig 313 (#1010): QUE eslabones se aplican lo decide regalo_cadena_pasos,
  -- la misma regla que pasosDeCadena() en el front (test de paridad:
  -- src/utils/cadenaSustitucion.espejo.json).
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', s.id, 'created_at', s.created_at,
           'producto_original_id', s.producto_original_id,
           'producto_sustituto_id', s.producto_sustituto_id,
           'reparto_id', s.reparto_id)), '[]'::jsonb)
    INTO v_eslabones
    FROM pedido_item_sustituciones s
   WHERE s.pedido_id = p_pedido_id
     AND s.promocion_id = p_promocion_id
     AND s.sucursal_id = p_sucursal_id;

  FOREACH v_id IN ARRAY public.regalo_cadena_pasos(v_eslabones, p_producto_id) LOOP
    SELECT s.* INTO v_s FROM pedido_item_sustituciones s WHERE s.id = v_id;

    -- La cantidad, con la regla de la 295 aplicada a este eslabon.
    IF v_cant IS NOT NULL AND COALESCE(v_s.cantidad_original, 0) > 0
       AND v_s.cantidad_sustituta IS NOT NULL THEN
      IF v_cant = v_s.cantidad_original THEN
        v_cant := v_s.cantidad_sustituta;
      ELSIF NOT public.regalo_misma_categoria(v_nodo, v_s.producto_sustituto_id, p_sucursal_id)
            OR public.factor_regalo_de_linea(p_promocion_id, v_nodo, p_sucursal_id, v_ajuste)
               IS DISTINCT FROM
               public.factor_regalo_de_linea(p_promocion_id, v_s.producto_sustituto_id, p_sucursal_id,
                                             COALESCE(v_s.ajuste_producto_id_nuevo, v_s.producto_sustituto_id)) THEN
        v_cant := GREATEST(1, round(v_cant * v_s.cantidad_sustituta / v_s.cantidad_original));
      END IF;
    END IF;

    v_nodo   := v_s.producto_sustituto_id;
    v_ajuste := COALESCE(v_s.ajuste_producto_id_nuevo, v_s.producto_sustituto_id);
    v_pasos  := v_pasos + 1;
  END LOOP;

  SELECT max(s.id) INTO v_corte_id
    FROM pedido_item_sustituciones s
   WHERE s.pedido_id = p_pedido_id
     AND s.promocion_id = p_promocion_id
     AND s.sucursal_id = p_sucursal_id
     AND s.reparto_id IS NOT NULL;

  producto_id := v_nodo;
  cantidad    := v_cant;
  pasos       := v_pasos;
  -- Llego ya sustituido: es el sustituto de una fila vigente (no una
  -- auto-sustitucion) y no tiene eslabones para adelante.
  ya_sustituido := v_pasos = 0 AND EXISTS (
    SELECT 1
      FROM pedido_item_sustituciones s
     WHERE s.pedido_id = p_pedido_id
       AND s.promocion_id = p_promocion_id
       AND s.sucursal_id = p_sucursal_id
       AND s.reparto_id IS NULL
       AND s.producto_sustituto_id = p_producto_id
       AND s.producto_original_id <> p_producto_id
       AND (v_corte_id IS NULL OR s.id > v_corte_id));
  RETURN NEXT;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 3 · La marca: el trigger, sustituir_regalo_pedido y dividir_regalo_pedido.
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._mig1016_ancla('public.aplicar_sustituciones_regalo_pre_insert()'::regprocedure,
$ancla$  IF (v_r.pasos > 0 OR v_r.ya_sustituido)
     AND COALESCE(NEW.descripcion_regalo, '') NOT LIKE '%[Sustituido por:%' THEN
    SELECT nombre INTO v_nombre_sustituto
      FROM productos
     WHERE id = v_r.producto_id
       AND sucursal_id = NEW.sucursal_id;
    NEW.descripcion_regalo := COALESCE(NEW.descripcion_regalo, '') ||
                              ' [Sustituido por: ' || COALESCE(v_nombre_sustituto, '?') || ']';
  END IF;$ancla$,
$nuevo$  -- mig 331 (#1051): y solo si la cadena no volvio a su raiz. Una vuelta
  -- A -> P -> A (o un ajuste de cantidad A -> A) entrega lo que dice la base:
  -- la marca decia "[Sustituido por: A]".
  IF (v_r.pasos > 0 OR v_r.ya_sustituido)
     AND COALESCE(NEW.descripcion_regalo, '') NOT LIKE '%[Sustituido por:%'
     AND public.regalo_raiz_cadena(NEW.pedido_id, NEW.promocion_id, v_r.producto_id, NEW.sucursal_id)
         IS DISTINCT FROM v_r.producto_id THEN
    SELECT nombre INTO v_nombre_sustituto
      FROM productos
     WHERE id = v_r.producto_id
       AND sucursal_id = NEW.sucursal_id;
    NEW.descripcion_regalo := public.regalo_descripcion_con_marca(NEW.descripcion_regalo, v_nombre_sustituto);
  END IF;$nuevo$);

  PERFORM public._mig1016_ancla('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)'::regprocedure,
$ancla$         -- mig 313 (#1010): una sola marca. En una cadena se acumulaba una
         -- por sustitucion. Se sacan las anteriores y queda el mismo texto que
         -- pone el trigger al editar: la base de la descripcion + la marca del
         -- final. La marca se agrega siempre con UN espacio adelante (o sin
         -- ninguno, la de dividir_regalo_pedido con btrim): sacar ' ?' y no
         -- '\s*' deja intacta la base aunque termine en espacio.
         descripcion_regalo = regexp_replace(COALESCE(descripcion_regalo, ''),
                                             ' ?\[Sustituido por:[^\]]*\]', '', 'g')
                              || ' [Sustituido por: ' || COALESCE(v_nuevo_nombre, '?') || ']',$ancla$,
$nuevo$         -- mig 313 (#1010): una sola marca, la del final, sobre la base de la
         -- descripcion: el mismo texto que pone el trigger al editar.
         -- mig 331 (#1051): la arman regalo_descripcion_base/_con_marca (un
         -- nombre con ']' rompia la regex; sin base quedaba un espacio
         -- adelante), y si la linea vuelve a la raiz de su cadena (A -> P -> A,
         -- o A -> A) no lleva marca. La raiz del producto ACTUAL es la del nuevo:
         -- el eslabon que se inserta abajo va del actual al nuevo.
         descripcion_regalo = CASE
           WHEN public.regalo_raiz_cadena(v_item.pedido_id, v_item.promocion_id,
                                          v_item.producto_id, v_sucursal) IS DISTINCT FROM p_producto_nuevo_id
             THEN public.regalo_descripcion_con_marca(descripcion_regalo, v_nuevo_nombre)
           ELSE public.regalo_descripcion_base(descripcion_regalo)
         END,$nuevo$);

  PERFORM public._mig1016_ancla('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'::regprocedure,
$ancla$  v_desc_base          TEXT;
  v_desc               TEXT;$ancla$,
$nuevo$  v_desc_base          TEXT;
  v_desc               TEXT;
  -- mig 331 (#1051): el producto con el que arranco la cadena de la linea.
  v_raiz               BIGINT;$nuevo$);

  -- Antes de registrar el reparto: con el reparto ya escrito, la raiz de
  -- cualquier producto es el mismo (el reparto corta la cadena).
  PERFORM public._mig1016_ancla('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'::regprocedure,
$ancla$  -- ── El registro, ANTES de insertar las partes ──$ancla$,
$nuevo$  v_raiz := public.regalo_raiz_cadena(v_item.pedido_id, v_item.promocion_id,
                                       v_item.producto_id, v_sucursal);

  -- ── El registro, ANTES de insertar las partes ──$nuevo$);

  PERFORM public._mig1016_ancla('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'::regprocedure,
$ancla$  v_desc_base := btrim(regexp_replace(COALESCE(v_item.descripcion_regalo, ''),
                                      '\s*\[Sustituido por:[^\]]*\]', '', 'g'));$ancla$,
$nuevo$  -- mig 331 (#1051): la misma limpieza que sustituir y el trigger.
  v_desc_base := btrim(public.regalo_descripcion_base(v_item.descripcion_regalo));$nuevo$);

  -- mig 331 (#1051): la parte que vuelve a la raiz de la cadena va sin marca
  -- (decia "[Sustituido por: <la raiz>]").
  PERFORM public._mig1016_ancla('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'::regprocedure,
$ancla$      v_desc := btrim(v_desc_base || ' [Sustituido por: ' || COALESCE(v_parte.nombre, '?') || ']');$ancla$,
$nuevo$      v_desc := CASE WHEN v_parte.producto_id = v_raiz THEN NULLIF(v_desc_base, '')
                     ELSE public.regalo_descripcion_con_marca(v_desc_base, v_parte.nombre) END;$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 4 · #1016: la regla de la 271 en una sola funcion.
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._mig1016_ancla('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)'::regprocedure,
$ancla$      SELECT descripcion_regalo, producto_regalo_id
        INTO v_descripcion_regalo, v_regalo_default_id
        FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
      -- mig 271 (#830): otro sabor -> la descripcion del producto entregado.
      IF v_regalo_default_id IS DISTINCT FROM v_producto_id AND v_descripcion_regalo IS NOT NULL THEN
        v_descripcion_regalo := COALESCE(substring(v_descripcion_regalo from '^\d+\s+\S+\s+'), '')
          || COALESCE((SELECT nombre FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal), '');
      END IF;$ancla$,
$nuevo$      -- mig 271 (#830): otro sabor -> la descripcion del producto entregado.
      -- mig 331 (#1016): la regla vive en regalo_descripcion_de_linea, la
      -- misma que usan el bot y la edicion.
      v_descripcion_regalo := public.regalo_descripcion_de_linea(v_promocion_id, v_producto_id, v_sucursal);$nuevo$);

  PERFORM public._mig1016_ancla('public.crear_pedido_completo_bot(uuid,uuid)'::regprocedure,
$ancla$      SELECT descripcion_regalo, producto_regalo_id
        INTO v_descripcion_regalo, v_regalo_default_id
        FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_pendiente.sucursal_id;
      IF v_regalo_default_id IS DISTINCT FROM v_producto_id AND v_descripcion_regalo IS NOT NULL THEN
        v_descripcion_regalo := COALESCE(substring(v_descripcion_regalo from '^\d+\s+\S+\s+'), '')
          || COALESCE((SELECT nombre FROM productos WHERE id = v_producto_id AND sucursal_id = v_pendiente.sucursal_id), '');
      END IF;$ancla$,
$nuevo$      -- mig 331 (#1016): la regla vive en regalo_descripcion_de_linea.
      v_descripcion_regalo := public.regalo_descripcion_de_linea(v_promocion_id, v_producto_id,
                                                                 v_pendiente.sucursal_id);$nuevo$);

  -- actualizar_pedido_items: la base de cada linea de regalo que ya estaba.
  PERFORM public._mig1016_ancla('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure,
$ancla$  -- mig 313 (#996): las lineas como QUEDARON, para el historial.
  v_items_guardados JSONB;$ancla$,
$nuevo$  -- mig 313 (#996): las lineas como QUEDARON, para el historial.
  v_items_guardados JSONB;
  -- mig 331 (#1016): la descripcion de cada linea de regalo que ya estaba,
  -- por "promo:producto", y como resuelve la cadena la que se guarda.
  v_desc_previas JSONB;
  v_desc_previa  TEXT;
  v_regalo_final BIGINT;
  v_regalo_pasos INT;
  v_regalo_ya    BOOLEAN;$nuevo$);

  PERFORM public._mig1016_ancla('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure,
$ancla$  DELETE FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;$ancla$,
$nuevo$  -- mig 331 (#1016): antes de borrar, la descripcion de cada regalo que ya
  -- estaba. Si dos lineas de la misma promo tienen el mismo producto, la mas
  -- vieja.
  SELECT COALESCE(jsonb_object_agg(x.clave, x.descripcion), '{}'::jsonb)
    INTO v_desc_previas
    FROM (SELECT DISTINCT ON (pi.promocion_id, pi.producto_id)
                 pi.promocion_id || ':' || pi.producto_id AS clave,
                 pi.descripcion_regalo AS descripcion
            FROM pedido_items pi
           WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
             AND COALESCE(pi.es_bonificacion, false) = true
             AND pi.promocion_id IS NOT NULL
           ORDER BY pi.promocion_id, pi.producto_id, pi.id) x;

  DELETE FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;$nuevo$);

  PERFORM public._mig1016_ancla('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure,
$ancla$      IF v_descripcion_regalo IS NULL THEN
        SELECT descripcion_regalo INTO v_descripcion_regalo FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
      END IF;$ancla$,
$nuevo$      -- mig 331 (#1016): el resto, con la regla de la 271 si la linea es
      -- nueva o cambio de sabor, y con la descripcion que ya tenia si no:
      -- misma promo y mismo producto FINAL (el que deja el trigger despues de
      -- la cadena de sustituciones; el JSON trae la raiz). Antes tomaba el
      -- texto de la promo, que habla del default de HOY: un Limon editado
      -- despues de rotar el default a Manzana quedaba diciendo Manzana.
      -- Una descripcion CON marca se conserva (sin la marca) solo si el
      -- trigger la va a volver a poner --misma condicion que el trigger--: la
      -- parte de un reparto que se disuelve ("...Limon [Sustituido por:
      -- Manzana]") no la recupera, porque el reparto corta la cadena, y sin
      -- marca diria Limon de una linea de Manzana. Esa va con la regla.
      IF v_descripcion_regalo IS NULL THEN
        SELECT r.producto_id, r.pasos, r.ya_sustituido
          INTO v_regalo_final, v_regalo_pasos, v_regalo_ya
          FROM public.regalo_sustitucion_resuelta(p_pedido_id, v_promocion_id, v_producto_id,
                                                  v_sucursal, NULL) r;
        v_desc_previa := v_desc_previas ->> (v_promocion_id || ':' || v_regalo_final);
        IF v_desc_previas ? (v_promocion_id || ':' || v_regalo_final)
           AND COALESCE(v_desc_previa, '') NOT LIKE '%[Sustituido por:%' THEN
          v_descripcion_regalo := v_desc_previa;
        ELSIF v_desc_previas ? (v_promocion_id || ':' || v_regalo_final)
              AND (v_regalo_pasos > 0 OR v_regalo_ya)
              AND public.regalo_raiz_cadena(p_pedido_id, v_promocion_id, v_regalo_final, v_sucursal)
                  IS DISTINCT FROM v_regalo_final THEN
          v_descripcion_regalo := public.regalo_descripcion_base(v_desc_previa);
        ELSE
          v_descripcion_regalo := public.regalo_descripcion_de_linea(v_promocion_id, v_producto_id, v_sucursal);
        END IF;
      END IF;$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 5 · Verificacion: permisos, cuerpos, compuertas y el recorrido puro.
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  v_n     int;
  v_def   text;
  v_fn    text;
  v_audit jsonb;
  v_casos jsonb;
  v_c     jsonb;
BEGIN
  -- (a) Las nuevas: solo service_role.
  FOREACH v_fn IN ARRAY ARRAY[
    'public.regalo_descripcion_de_linea(bigint,bigint,bigint)',
    'public.regalo_descripcion_base(text)',
    'public.regalo_descripcion_con_marca(text,text)',
    'public.regalo_raiz_cadena(bigint,bigint,bigint,bigint)'] LOOP
    IF has_function_privilege('anon', v_fn, 'EXECUTE')
       OR has_function_privilege('authenticated', v_fn, 'EXECUTE')
       OR NOT has_function_privilege('service_role', v_fn, 'EXECUTE') THEN
      RAISE EXCEPTION 'mig1016 · % tiene que ejecutarla solo service_role', v_fn;
    END IF;
  END LOOP;

  -- (b) Las parchadas: misma firma, ACL, DEFINER y search_path.
  SELECT count(*) INTO v_n
    FROM _mig1016_acl a
    LEFT JOIN pg_proc p ON p.oid = to_regprocedure(a.fn)
   WHERE p.oid IS NULL
      OR p.proacl::text IS DISTINCT FROM a.acl
      OR p.prosecdef IS DISTINCT FROM a.prosecdef OR p.proconfig::text IS DISTINCT FROM a.cfg;
  IF v_n > 0 OR (SELECT count(*) FROM _mig1016_acl) <> 8 THEN
    RAISE EXCEPTION 'mig1016 · cambio la firma, la ACL, el SECURITY DEFINER o el search_path de % funcion(es)', v_n;
  END IF;

  -- (c) Una sola copia de la regla y de la marca. La regex de la 271 y la
  --     marca armada a mano solo viven en las funciones nuevas.
  SELECT string_agg(p.proname, ', ') INTO v_fn
    FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'
     AND p.proname NOT IN ('regalo_descripcion_de_linea', 'regalo_descripcion_base', 'regalo_descripcion_con_marca')
     -- strpos y no LIKE: en LIKE la barra es escape.
     AND (strpos(pg_get_functiondef(p.oid), $q$from '^\d+\s+\S+\s+'$q$) > 0
          OR strpos(pg_get_functiondef(p.oid), $q$' [Sustituido por: '$q$) > 0
          OR strpos(pg_get_functiondef(p.oid), $q$[^\]]*\]$q$) > 0);
  IF v_fn IS NOT NULL THEN
    RAISE EXCEPTION 'mig1016 · quedan copias de la regla o de la marca en: %', v_fn;
  END IF;

  v_def := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure);
  IF v_def NOT LIKE '%regalo_descripcion_de_linea(v_promocion_id, v_producto_id, v_sucursal)%'
     OR v_def NOT LIKE '%INTO v_pedido_item_guardado, v_producto_guardado, v_cantidad_guardada%'
     OR v_def NOT LIKE '%costo_valuacion(%'
     OR v_def NOT LIKE '%INTO v_items_guardados FROM pedido_items%'
     OR v_def LIKE '%SELECT descripcion_regalo INTO v_descripcion_regalo FROM promociones%' THEN
    RAISE EXCEPTION 'mig1016 · actualizar_pedido_items no quedo como se esperaba';
  END IF;
  IF pg_get_functiondef('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)'::regprocedure)
       NOT LIKE '%regalo_descripcion_de_linea(%'
     OR pg_get_functiondef('public.crear_pedido_completo_bot(uuid,uuid)'::regprocedure)
       NOT LIKE '%regalo_descripcion_de_linea(%' THEN
    RAISE EXCEPTION 'mig1016 · la creacion no usa regalo_descripcion_de_linea';
  END IF;
  v_def := pg_get_functiondef('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)'::regprocedure);
  IF v_def NOT LIKE '%regalo_raiz_cadena(%' OR v_def NOT LIKE '%costo_valuacion(%'
     OR v_def NOT LIKE '%''sustitucion_regalo''%' THEN
    RAISE EXCEPTION 'mig1016 · sustituir_regalo_pedido no quedo como se esperaba';
  END IF;
  IF pg_get_functiondef('public.aplicar_sustituciones_regalo_pre_insert()'::regprocedure) NOT LIKE '%regalo_raiz_cadena(%'
     OR strpos(pg_get_functiondef('public.regalo_cadena_pasos(jsonb,bigint)'::regprocedure), $q$->>'created_at'$q$) > 0 THEN
    RAISE EXCEPTION 'mig1016 · el trigger o regalo_cadena_pasos no quedaron como se esperaba';
  END IF;

  -- (d) Compuertas.
  v_audit := public.auditoria_integridad();
  SELECT count(*) INTO v_n
    FROM jsonb_array_elements(v_audit->'checks') c
   WHERE c->>'id' IN ('COSTO-D', 'STK-F', 'PROMO-A', 'PROMO-B', 'BONIF-C', 'BONIF-D', 'STK-B')
     AND NOT (c->>'ok')::boolean;
  IF v_n > 0 THEN
    RAISE EXCEPTION 'mig1016 · auditoria_integridad en rojo: %',
      (SELECT jsonb_agg(c) FROM jsonb_array_elements(v_audit->'checks') c
        WHERE NOT (c->>'ok')::boolean
          AND c->>'id' IN ('COSTO-D','STK-F','PROMO-A','PROMO-B','BONIF-C','BONIF-D','STK-B'));
  END IF;

  -- (e) Las funciones puras.
  IF public.regalo_descripcion_base('2 Botellas X [Sustituido por: P [x3]] [Sustituido por: Q]') <> '2 Botellas X'
     OR public.regalo_descripcion_base(' [Sustituido por: P]') IS NOT NULL
     OR public.regalo_descripcion_base(NULL) IS NOT NULL
     OR public.regalo_descripcion_con_marca(NULL, 'P') <> '[Sustituido por: P]'
     OR public.regalo_descripcion_con_marca('2 Botellas X [Sustituido por: P]]', 'Q') <> '2 Botellas X [Sustituido por: Q]' THEN
    RAISE EXCEPTION 'mig1016 · las funciones de la marca no dan lo esperado';
  END IF;

  -- (f) El recorrido por id. El juego completo lo corre el gate
  --     (scripts/espejo-cadena-regalo.mjs); aca van los de #1051.
  v_casos := jsonb_build_array(
    jsonb_build_object('producto', 1, 'esperado', '[11,12]'::jsonb, 'eslabones', '[
      {"id":12,"created_at":"2026-10-01T10:00:01Z","producto_original_id":2,"producto_sustituto_id":3,"reparto_id":null},
      {"id":11,"created_at":"2026-10-01T10:00:05Z","producto_original_id":1,"producto_sustituto_id":2,"reparto_id":null}]'::jsonb),
    jsonb_build_object('producto', 2, 'esperado', '[13]'::jsonb, 'eslabones', '[
      {"id":13,"created_at":"2026-10-01T10:00:01Z","producto_original_id":2,"producto_sustituto_id":4,"reparto_id":null},
      {"id":12,"created_at":"2026-10-01T10:00:05Z","producto_original_id":2,"producto_sustituto_id":2,"reparto_id":"8b0d6f43-2a52-4d1c-9a51-6a3f8d0e5c11"},
      {"id":11,"created_at":"2026-10-01T10:00:00Z","producto_original_id":1,"producto_sustituto_id":2,"reparto_id":null}]'::jsonb));
  FOR v_c IN SELECT * FROM jsonb_array_elements(v_casos) LOOP
    IF to_jsonb(public.regalo_cadena_pasos(v_c->'eslabones', (v_c->>'producto')::bigint))
       IS DISTINCT FROM v_c->'esperado' THEN
      RAISE EXCEPTION 'mig1016 · regalo_cadena_pasos: esperado % y dio %', v_c->'esperado',
        public.regalo_cadena_pasos(v_c->'eslabones', (v_c->>'producto')::bigint);
    END IF;
  END LOOP;

  RAISE NOTICE 'mig1016 · verificacion OK';
END
$verif$;

-- ---------------------------------------------------------------------------
-- 6 · El ensayo, con productos y promos sinteticos, en un sub-bloque que se
--     deshace solo (SQLSTATE centinela, como la 295, la 304 y la 313). Solo
--     llama RPCs publicas: corre igual contra los cuerpos de antes, donde
--     tiene que fallar.
--     L = Limon (default de la promo al crear), M = Manzana (el default
--     despues de rotar), P y R = sustitutos, Q = un nombre con ']'.
-- ---------------------------------------------------------------------------
DO $ensayo$
DECLARE
  v_admin   uuid;
  v_suc     bigint;
  v_cliente bigint;
  v_l bigint; v_m bigint; v_p bigint; v_q bigint; v_r bigint; v_v bigint;
  v_promo    bigint;  -- modo A, con descripcion escrita a mano
  v_promo_sd bigint;  -- modo A, sin descripcion
  v_res     jsonb;
  v_ped1 bigint; v_ped2 bigint; v_ped3 bigint; v_ped4 bigint; v_ped5 bigint;
  v_ped6 bigint; v_ped7 bigint; v_ped8 bigint; v_ped9 bigint;
  v_item    bigint;
  v_prod    bigint;
  v_desc    text;
  v_hist    int;
  v_stocks  int[];
  v_fallas  text[] := '{}';
  c_limon   CONSTANT text := '2 Botellas ZZ Limon a mano';
  c_regla_l CONSTANT text := '2 Botellas ZZ ensayo mig1016 Limon';
BEGIN
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'mig1016 · el ensayo necesita un admin activo con una sucursal activa';
  END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  PERFORM set_config('app.omitir_minimo_venta', '1', true);
  SELECT id INTO v_cliente FROM clientes WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;

  BEGIN
    INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria, unidades_por_bulto, costo_promedio)
    VALUES ('ZZ ensayo mig1016 Limon', 6000, 100, v_suc, 'ZZ ensayo mig1016', 6, 100) RETURNING id INTO v_l;
    INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria, unidades_por_bulto, costo_promedio)
    VALUES ('ZZ ensayo mig1016 Manzana', 6000, 100, v_suc, 'ZZ ensayo mig1016', 6, 100) RETURNING id INTO v_m;
    INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria, unidades_por_bulto, costo_promedio)
    VALUES ('ZZ ensayo mig1016 P', 6000, 100, v_suc, 'ZZ ensayo mig1016', 6, 200) RETURNING id INTO v_p;
    INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria, unidades_por_bulto, costo_promedio)
    VALUES ('ZZ ensayo mig1016 Q [x3]', 6000, 100, v_suc, 'ZZ ensayo mig1016', 6, 300) RETURNING id INTO v_q;
    INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria, unidades_por_bulto, costo_promedio)
    VALUES ('ZZ ensayo mig1016 R', 6000, 100, v_suc, 'ZZ ensayo mig1016', 6, 400) RETURNING id INTO v_r;
    INSERT INTO productos (nombre, precio, stock, sucursal_id)
    VALUES ('ZZ ensayo mig1016 vendido', 100, 100, v_suc) RETURNING id INTO v_v;

    INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id, ajuste_automatico,
      producto_regalo_id, regalo_mueve_stock, descripcion_regalo)
    VALUES ('ZZ ensayo mig1016', 'bonificacion', CURRENT_DATE, v_suc, FALSE,
      v_l, TRUE, c_limon) RETURNING id INTO v_promo;
    INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id, ajuste_automatico,
      producto_regalo_id, regalo_mueve_stock, descripcion_regalo)
    VALUES ('ZZ ensayo mig1016 sin descripcion', 'bonificacion', CURRENT_DATE, v_suc, FALSE,
      v_l, TRUE, NULL) RETURNING id INTO v_promo_sd;

    -- ── Antes de rotar: todos con Limon, que es el default. ──
    -- 1 · sin tocar.
    v_res := public.crear_pedido_completo(v_cliente, 100, v_admin, jsonb_build_array(
      jsonb_build_object('producto_id', v_l, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), 'ensayo mig1016 limon');
    v_ped1 := (v_res->>'pedido_id')::bigint;
    SELECT descripcion_regalo INTO v_desc FROM pedido_items WHERE pedido_id = v_ped1 AND es_bonificacion;
    IF v_desc IS DISTINCT FROM c_limon THEN
      v_fallas := v_fallas || format('crear Limon default: desc=%L', v_desc);
    END IF;

    -- 2 · Limon sustituido por P.
    v_res := public.crear_pedido_completo(v_cliente, 100, v_admin, jsonb_build_array(
      jsonb_build_object('producto_id', v_l, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), 'ensayo mig1016 sustituido');
    v_ped2 := (v_res->>'pedido_id')::bigint;
    SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped2 AND es_bonificacion;
    v_res := public.sustituir_regalo_pedido(v_item, v_p, 2, 'ensayo mig1016 L->P', NULL, NULL);
    SELECT descripcion_regalo INTO v_desc FROM pedido_items WHERE id = v_item;
    IF NOT COALESCE((v_res->>'success')::boolean, false)
       OR v_desc IS DISTINCT FROM c_limon || ' [Sustituido por: ZZ ensayo mig1016 P]' THEN
      v_fallas := v_fallas || format('sustituir L->P: %s desc=%L', v_res, v_desc);
    END IF;

    -- 3 · #1051: una vuelta L -> P -> L no deja "[Sustituido por: Limon]".
    v_res := public.crear_pedido_completo(v_cliente, 100, v_admin, jsonb_build_array(
      jsonb_build_object('producto_id', v_l, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), 'ensayo mig1016 vuelta');
    v_ped3 := (v_res->>'pedido_id')::bigint;
    SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped3 AND es_bonificacion;
    v_res := public.sustituir_regalo_pedido(v_item, v_p, 2, 'ensayo mig1016 L->P', NULL, NULL);
    v_res := public.sustituir_regalo_pedido(v_item, v_l, 2, 'ensayo mig1016 P->L', NULL, NULL);
    SELECT descripcion_regalo INTO v_desc FROM pedido_items WHERE id = v_item;
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_desc IS DISTINCT FROM c_limon THEN
      v_fallas := v_fallas || format('vuelta L->P->L al sustituir: %s desc=%L', v_res, v_desc);
    END IF;

    -- 4 · #1051: un nombre con ']' en el medio de la cadena (L -> Q[x3] -> R).
    v_res := public.crear_pedido_completo(v_cliente, 100, v_admin, jsonb_build_array(
      jsonb_build_object('producto_id', v_l, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), 'ensayo mig1016 corchete');
    v_ped4 := (v_res->>'pedido_id')::bigint;
    SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped4 AND es_bonificacion;
    v_res := public.sustituir_regalo_pedido(v_item, v_q, 2, 'ensayo mig1016 L->Q', NULL, NULL);
    v_res := public.sustituir_regalo_pedido(v_item, v_r, 2, 'ensayo mig1016 Q->R', NULL, NULL);
    SELECT descripcion_regalo INTO v_desc FROM pedido_items WHERE id = v_item;
    IF NOT COALESCE((v_res->>'success')::boolean, false)
       OR v_desc IS DISTINCT FROM c_limon || ' [Sustituido por: ZZ ensayo mig1016 R]' THEN
      v_fallas := v_fallas || format('nombre con corchete: %s desc=%L', v_res, v_desc);
    END IF;

    -- 5 · #1051: promo sin descripcion: la marca sin espacio adelante.
    v_res := public.crear_pedido_completo(v_cliente, 100, v_admin, jsonb_build_array(
      jsonb_build_object('producto_id', v_l, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo_sd),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), 'ensayo mig1016 sin desc');
    v_ped5 := (v_res->>'pedido_id')::bigint;
    SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped5 AND es_bonificacion;
    v_res := public.sustituir_regalo_pedido(v_item, v_p, 2, 'ensayo mig1016 sin desc', NULL, NULL);
    SELECT descripcion_regalo INTO v_desc FROM pedido_items WHERE id = v_item;
    IF NOT COALESCE((v_res->>'success')::boolean, false)
       OR v_desc IS DISTINCT FROM '[Sustituido por: ZZ ensayo mig1016 P]' THEN
      v_fallas := v_fallas || format('promo sin descripcion: %s desc=%L', v_res, v_desc);
    END IF;

    -- 8 · #1051: L sustituido por P y repartido en L + P. La parte L vuelve a
    --     la raiz: sin marca. La P conserva la suya.
    v_res := public.crear_pedido_completo(v_cliente, 100, v_admin, jsonb_build_array(
      jsonb_build_object('producto_id', v_l, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), 'ensayo mig1016 reparto vuelta');
    v_ped8 := (v_res->>'pedido_id')::bigint;
    SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped8 AND es_bonificacion;
    v_res := public.sustituir_regalo_pedido(v_item, v_p, 2, 'ensayo mig1016 L->P', NULL, NULL);
    v_res := public.dividir_regalo_pedido(v_item, jsonb_build_array(
      jsonb_build_object('producto_id', v_l, 'cantidad', 1),
      jsonb_build_object('producto_id', v_p, 'cantidad', 1)), 'ensayo mig1016 reparto', NULL);
    IF NOT COALESCE((v_res->>'success')::boolean, false)
       OR (SELECT descripcion_regalo FROM pedido_items WHERE pedido_id = v_ped8 AND es_bonificacion AND producto_id = v_l)
          IS DISTINCT FROM c_limon
       OR (SELECT descripcion_regalo FROM pedido_items WHERE pedido_id = v_ped8 AND es_bonificacion AND producto_id = v_p)
          IS DISTINCT FROM c_limon || ' [Sustituido por: ZZ ensayo mig1016 P]' THEN
      v_fallas := v_fallas || format('reparto con vuelta a la raiz: %s L=%L P=%L', v_res,
        (SELECT descripcion_regalo FROM pedido_items WHERE pedido_id = v_ped8 AND es_bonificacion AND producto_id = v_l),
        (SELECT descripcion_regalo FROM pedido_items WHERE pedido_id = v_ped8 AND es_bonificacion AND producto_id = v_p));
    END IF;

    -- 9 · L repartido en L + M (para disolver el reparto despues de rotar).
    v_res := public.crear_pedido_completo(v_cliente, 100, v_admin, jsonb_build_array(
      jsonb_build_object('producto_id', v_l, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), 'ensayo mig1016 reparto disuelto');
    v_ped9 := (v_res->>'pedido_id')::bigint;
    SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped9 AND es_bonificacion;
    v_res := public.dividir_regalo_pedido(v_item, jsonb_build_array(
      jsonb_build_object('producto_id', v_l, 'cantidad', 1),
      jsonb_build_object('producto_id', v_m, 'cantidad', 1)), 'ensayo mig1016 reparto', NULL);
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('repartir L en L + M: %s', v_res);
    END IF;

    -- 6 · un pedido sin regalo, para agregarle uno al editar.
    v_res := public.crear_pedido_completo(v_cliente, 100, v_admin, jsonb_build_array(
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), 'ensayo mig1016 sin regalo');
    v_ped6 := (v_res->>'pedido_id')::bigint;

    -- ── La promo rota el default a Manzana (y su texto, como en prod). ──
    UPDATE promociones SET producto_regalo_id = v_m, descripcion_regalo = '2 Botellas ZZ Manzana a mano'
     WHERE id = v_promo;

    -- 7 · #1016 literal: Limon cargado cuando NO es el default -> la regla.
    v_res := public.crear_pedido_completo(v_cliente, 100, v_admin, jsonb_build_array(
      jsonb_build_object('producto_id', v_l, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), 'ensayo mig1016 regla');
    v_ped7 := (v_res->>'pedido_id')::bigint;
    SELECT descripcion_regalo INTO v_desc FROM pedido_items WHERE pedido_id = v_ped7 AND es_bonificacion;
    IF v_desc IS DISTINCT FROM c_regla_l THEN
      v_fallas := v_fallas || format('crear Limon no default: desc=%L', v_desc);
    END IF;

    -- ── Editar SIN CAMBIOS: el front manda la raiz (Limon) y la misma cantidad. ──
    -- 1 · conserva su texto, no mueve stock y no deja historial.
    SELECT array_agg(stock ORDER BY id) INTO v_stocks FROM productos WHERE id IN (v_l, v_m, v_p, v_q, v_r, v_v);
    SELECT count(*) INTO v_hist FROM pedido_historial WHERE pedido_id = v_ped1 AND campo_modificado = 'items';
    v_res := public.actualizar_pedido_items(v_ped1, jsonb_build_array(
      jsonb_build_object('producto_id', v_l, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
    SELECT producto_id, descripcion_regalo INTO v_prod, v_desc FROM pedido_items WHERE pedido_id = v_ped1 AND es_bonificacion;
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_prod <> v_l OR v_desc IS DISTINCT FROM c_limon THEN
      v_fallas := v_fallas || format('editar Limon tras rotar: %s prod=%s desc=%L', v_res, v_prod, v_desc);
    END IF;
    IF (SELECT count(*) FROM pedido_historial WHERE pedido_id = v_ped1 AND campo_modificado = 'items') <> v_hist THEN
      v_fallas := v_fallas || 'editar Limon tras rotar sin cambios dejo historial de items'::text;
    END IF;

    -- 2 · sustituido: la base de Limon + la marca de P.
    SELECT count(*) INTO v_hist FROM pedido_historial WHERE pedido_id = v_ped2 AND campo_modificado = 'items';
    v_res := public.actualizar_pedido_items(v_ped2, jsonb_build_array(
      jsonb_build_object('producto_id', v_l, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
    SELECT producto_id, descripcion_regalo INTO v_prod, v_desc FROM pedido_items WHERE pedido_id = v_ped2 AND es_bonificacion;
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_prod <> v_p
       OR v_desc IS DISTINCT FROM c_limon || ' [Sustituido por: ZZ ensayo mig1016 P]' THEN
      v_fallas := v_fallas || format('editar sustituido tras rotar: %s prod=%s desc=%L', v_res, v_prod, v_desc);
    END IF;
    IF (SELECT count(*) FROM pedido_historial WHERE pedido_id = v_ped2 AND campo_modificado = 'items') <> v_hist THEN
      v_fallas := v_fallas || 'editar sustituido sin cambios dejo historial de items'::text;
    END IF;

    -- 3 · la vuelta L -> P -> L sigue sin marca al editar.
    v_res := public.actualizar_pedido_items(v_ped3, jsonb_build_array(
      jsonb_build_object('producto_id', v_l, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
    SELECT producto_id, descripcion_regalo INTO v_prod, v_desc FROM pedido_items WHERE pedido_id = v_ped3 AND es_bonificacion;
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_prod <> v_l OR v_desc IS DISTINCT FROM c_limon THEN
      v_fallas := v_fallas || format('editar vuelta L->P->L: %s prod=%s desc=%L', v_res, v_prod, v_desc);
    END IF;
    IF EXISTS (SELECT 1 FROM pedido_historial WHERE pedido_id = v_ped3 AND campo_modificado = 'items') THEN
      v_fallas := v_fallas || 'editar la vuelta sin cambios dejo historial de items'::text;
    END IF;

    -- 7 · el que nacio con la regla la conserva.
    SELECT count(*) INTO v_hist FROM pedido_historial WHERE pedido_id = v_ped7 AND campo_modificado = 'items';
    v_res := public.actualizar_pedido_items(v_ped7, jsonb_build_array(
      jsonb_build_object('producto_id', v_l, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
    SELECT descripcion_regalo INTO v_desc FROM pedido_items WHERE pedido_id = v_ped7 AND es_bonificacion;
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_desc IS DISTINCT FROM c_regla_l THEN
      v_fallas := v_fallas || format('editar el de la regla: %s desc=%L', v_res, v_desc);
    END IF;
    IF (SELECT count(*) FROM pedido_historial WHERE pedido_id = v_ped7 AND campo_modificado = 'items') <> v_hist THEN
      v_fallas := v_fallas || 'editar el de la regla sin cambios dejo historial de items'::text;
    END IF;

    -- Ninguna edicion sin cambios movio stock.
    IF (SELECT array_agg(stock ORDER BY id) FROM productos WHERE id IN (v_l, v_m, v_p, v_q, v_r, v_v)) IS DISTINCT FROM v_stocks THEN
      v_fallas := v_fallas || format('las ediciones sin cambios movieron stock: antes %s despues %s', v_stocks,
        (SELECT array_agg(stock ORDER BY id) FROM productos WHERE id IN (v_l, v_m, v_p, v_q, v_r, v_v)));
    END IF;

    -- ── Editar CON cambios: la regla rige lo nuevo. ──
    -- 6 · se agrega Limon, que ya no es el default -> la regla.
    v_res := public.actualizar_pedido_items(v_ped6, jsonb_build_array(
      jsonb_build_object('producto_id', v_l, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
    SELECT descripcion_regalo INTO v_desc FROM pedido_items WHERE pedido_id = v_ped6 AND es_bonificacion;
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_desc IS DISTINCT FROM c_regla_l THEN
      v_fallas := v_fallas || format('agregar Limon al editar: %s desc=%L', v_res, v_desc);
    END IF;

    -- 1 · cambia el sabor a Manzana (el default de hoy) -> el texto de la promo.
    v_res := public.actualizar_pedido_items(v_ped1, jsonb_build_array(
      jsonb_build_object('producto_id', v_m, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
    SELECT descripcion_regalo INTO v_desc FROM pedido_items WHERE pedido_id = v_ped1 AND es_bonificacion;
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_desc IS DISTINCT FROM '2 Botellas ZZ Manzana a mano' THEN
      v_fallas := v_fallas || format('cambiar a Manzana al editar: %s desc=%L', v_res, v_desc);
    END IF;

    -- 2 · la venta crece: el regalo sustituido sube y conserva base y marca.
    v_res := public.actualizar_pedido_items(v_ped2, jsonb_build_array(
      jsonb_build_object('producto_id', v_l, 'cantidad', 4, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 2, 'precio_unitario', 100)), v_admin);
    SELECT producto_id, descripcion_regalo INTO v_prod, v_desc FROM pedido_items WHERE pedido_id = v_ped2 AND es_bonificacion;
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_prod <> v_p
       OR v_desc IS DISTINCT FROM c_limon || ' [Sustituido por: ZZ ensayo mig1016 P]' THEN
      v_fallas := v_fallas || format('editar sustituido con mas venta: %s prod=%s desc=%L', v_res, v_prod, v_desc);
    END IF;

    -- 9 · la venta crece y el reparto se disuelve: el front manda M (el
    --     default de hoy). La parte M decia "...Limon [Sustituido por: M]" y
    --     el trigger no le repone la marca (el reparto corta la cadena): va
    --     con la regla, no con "Limon".
    v_res := public.actualizar_pedido_items(v_ped9, jsonb_build_array(
      jsonb_build_object('producto_id', v_m, 'cantidad', 4, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo),
      jsonb_build_object('producto_id', v_v, 'cantidad', 2, 'precio_unitario', 100)), v_admin);
    SELECT producto_id, descripcion_regalo INTO v_prod, v_desc FROM pedido_items WHERE pedido_id = v_ped9 AND es_bonificacion;
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_prod <> v_m
       OR v_desc IS DISTINCT FROM '2 Botellas ZZ Manzana a mano' THEN
      v_fallas := v_fallas || format('reparto disuelto: %s prod=%s desc=%L', v_res, v_prod, v_desc);
    END IF;

    IF array_length(v_fallas, 1) > 0 THEN
      RAISE EXCEPTION 'mig1016 · el ensayo fallo en % caso(s):%', array_length(v_fallas, 1),
        E'\n  - ' || array_to_string(v_fallas, E'\n  - ');
    END IF;
    RAISE EXCEPTION 'mig1016-ok' USING ERRCODE = '2F000';
  EXCEPTION WHEN SQLSTATE '2F000' THEN
    IF SQLERRM <> 'mig1016-ok' THEN RAISE; END IF;
    RAISE NOTICE 'mig1016 · ensayo OK: la descripcion conserva el sabor al editar, la regla rige lo nuevo, y la marca sin vuelta, sin corchete roto y sin espacio';
  END;
END
$ensayo$;

-- ---------------------------------------------------------------------------
-- 7 · Se saca el andamio.
-- ---------------------------------------------------------------------------
DROP FUNCTION public._mig1016_ancla(regprocedure, text, text);

COMMIT;
