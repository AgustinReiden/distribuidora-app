-- =========================================================================
-- mig 338 · LA CADENA DE SUSTITUCIONES ES POR LINEA, NO POR PROMO (#1057)
--           Y LA EDICION DEVUELVE EL STOCK DE TODAS LAS LINEAS (#1083)
--
-- #1057 · EL PROBLEMA
-- -------------------
-- Los eslabones de pedido_item_sustituciones se buscaban por pedido + promo.
-- Con una sola linea de regalo por promo da igual; despues de un reparto
-- (dividir_regalo_pedido, mig 275) hay varias, y se mezclaban. Medido con un
-- ensayo en prod que se deshizo (2026-10-09), reparto X + Y, L1 X->Y, L2 Y->X:
-- · editar SIN cambios reescribia L1 a X por el eslabon Y->X de L2: el pedido
--   quedaba X + X y L1 seguia diciendo "[Sustituido por: Y]";
-- · reparto Y + W (sin el original), L1 Y->W, L2 W->Y: L2 quedaba sin marca
--   aunque su texto habla de X;
-- · una parte que va Y->Z (2->4) y vuelve Z->Y (4->3) perdia la marca, y cada
--   edicion la recorria de nuevo desde Y x3: quedaba Y x5 y en modo A
--   descontaba 2 de mas;
-- · un front sin la clave que manda el FINAL con la cantidad de la promo
--   dejaba Z x2 de un cambio por valor X2 -> Z5.
-- No se puede filtrar por pedido_item_id: actualizar_pedido_items borra y
-- reinserta las lineas, y la FK es SET NULL (mig 062).
--
-- LA REGLA (decisiones del dueno, 2026-10-09)
-- -------------------------------------------
-- · Cada linea de regalo tiene una clave de cadena (pedido_items.
--   regalo_cadena_id) y cada eslabon la de su linea (cadena_id). Una linea solo
--   ve los eslabones de SU clave; sin clave no tiene cadena.
-- · La clave la decide el server, nunca el front:
--     - sustituir_regalo_pedido usa la de la linea o le crea una;
--     - dividir_regalo_pedido le da una nueva a cada parte, y la fila del
--       reparto de cada parte lleva la de la parte y el producto que describe
--       el texto de la linea repartida (producto_raiz_id);
--     - actualizar_pedido_items: una linea conservada de un reparto lleva la
--       suya y se reinserta TAL COMO ESTABA (no recorre la cadena); si la promo
--       tenia UNA linea y llega UNA, hereda la clave, y el server recorre
--       desde la raiz de esa cadena aunque el JSON traiga el final; si la promo
--       no tenia lineas (se cayo y vuelve), hereda la de su ultima cadena salvo
--       que sea de un reparto (decision A); un reparto que se disuelve (llega
--       otra cantidad) arranca sin cadena.
-- · La marca "[Sustituido por: ...]" va solo si el producto no es el que
--   describe el texto (regla de la 331b). Para una parte de un reparto, lo que
--   describe el texto es la raiz de la linea antes de repartirse.
--
-- QUE CAMBIA
-- ----------
-- · Puras (sin tablas; las corre el gate de paridad, scripts/espejo-cadena-
--   regalo.mjs, contra src/utils/cadenaSustitucion.espejo.json):
--     regalo_cadena_pasos(eslabones, producto, cadena)        = pasosDeCadena()
--     regalo_raiz_de_eslabones(eslabones, producto, cadena)   = raizDeSustitucion()
--     regalo_raiz_descrita(eslabones, producto, cadena)       = raizDescrita()
--   regalo_raiz_de_eslabones es ESPEJO de verdad: valida el recorrido hacia
--   adelante y devuelve NULL si no hay raiz (antes devolvia el producto).
-- · Con tablas: regalo_eslabones, regalo_sustitucion_resuelta,
--   regalo_sustituto_vigente, regalo_raiz_cadena y regalo_raiz_descrita_de_linea
--   reciben la clave. Las firmas viejas se dropean (trampa 5): una funcion SQL
--   que llama a una firma dropeada no falla al dropear, falla al usarse.
-- · regalo_elemento_con_cadena: la herencia de la clave en la edicion.
-- · El trigger, sustituir, dividir y actualizar_pedido_items, por ancla.
-- · v_desc_previas (331b) por clave: dos lineas que terminan en el mismo
--   producto ya no se pisan. Sin clave, promo:producto solo si es unica.
-- · El pre-chequeo de stock compara contra la linea de la MISMA clave.
--
-- #1083 · EL STOCK
-- ----------------
-- actualizar_pedido_items devolvia el stock con UPDATE ... FROM pedido_items:
-- con dos lineas del mismo producto el UPDATE toca la fila de productos UNA
-- vez y devuelve una sola. Ahora suma por producto antes.
--
-- COSTO, STOCK, LOTES
-- -------------------
-- · COSTO-D: el trigger valua con costo_valuacion el producto que queda;
--   actualizar_pedido_items sigue valuando despues del INSERT ... RETURNING
--   (mig 257); sustituir y dividir no cambian su costo.
-- · Stock: sigue moviendose con lo que QUEDO en la fila. Las devoluciones de
--   actualizar_pedido_items siguen etiquetadas 'pedido_creado' (mig 229): solo
--   cambia que ahora devuelven la suma. STK-F no cambia.
--
-- DATOS: en prod, 11 eslabones (todos de pedidos entregados) y 0 repartos. Se
-- les da una clave por (pedido, promo); si aparece un reparto o mas de una
-- linea de regalo por (pedido, promo), la migracion aborta.
--
-- ORDEN DE DEPLOY: esta migracion va ANTES del merge. El front nuevo pide
-- pedido_items.regalo_cadena_id y, sin la columna, se cae la consulta entera
-- de pedidos. Y entre aplicar y mergear, el gate de paridad de main
-- (scripts/espejo-cadena-regalo.mjs, cron diario) llama a la firma vieja de
-- regalo_cadena_pasos y queda rojo: es esperable y se arregla con el merge.
-- Toma un lock exclusivo sobre pedido_items hasta el COMMIT (ensayo incluido):
-- aplicarla en un horario tranquilo.
--
-- QUE NO CAMBIA (sabido, fuera de alcance): un reparto con una parte cambiada
-- por valor (Y2 -> Z4 -> Y3) ya no suma lo que da la promo, asi que el front lo
-- da por perdido y la proxima edicion lo disuelve (migs 275/295): #1090. El
-- ensayo C4/C6 prueba el camino del server cuando el total coincide. Y un
-- reparto hecho en el alta no deja filas de reparto, asi que la promo que
-- vuelve puede heredar la cadena de una de sus partes: #1091.
--
-- Permisos: todas las funciones nuevas corren solo dentro del server (o del
-- gate, con service_role) -> REVOKE a PUBLIC, anon y authenticated. Las
-- parchadas conservan firma, ACL, DEFINER y search_path (el $verif$ lo
-- compara).
-- =========================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 0 · Andamio. Se dropea al final.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _mig1057_acl ON COMMIT DROP AS
SELECT p.oid::regprocedure::text AS fn, p.proacl::text AS acl, p.prosecdef, p.proconfig::text AS cfg
  FROM pg_proc p
 WHERE p.pronamespace = 'public'::regnamespace
   AND p.proname IN ('actualizar_pedido_items', 'sustituir_regalo_pedido', 'dividir_regalo_pedido',
                     'aplicar_sustituciones_regalo_pre_insert');

CREATE OR REPLACE FUNCTION public._mig1057_ancla(
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
    RAISE EXCEPTION 'mig1057 · el ancla aparece % veces en % (se esperaba 1). El cuerpo vivo cambio: revisar a mano. Ancla: %',
      v_veces, p_funcion, left(v_ancla, 160);
  END IF;
  EXECUTE replace(v_def, v_ancla, replace(p_nuevo, E'\r', ''));
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 1 · Las columnas y los datos.
-- ---------------------------------------------------------------------------
ALTER TABLE public.pedido_items ADD COLUMN regalo_cadena_id uuid;
COMMENT ON COLUMN public.pedido_items.regalo_cadena_id IS
  'Clave de la cadena de sustituciones de este regalo (mig 338, #1057). Los eslabones con el mismo cadena_id son los de esta linea. NULL = sin cadena.';
-- Una clave es de UNA linea viva: si algo la duplica, falla en vez de volver
-- a mezclar cadenas en silencio.
CREATE UNIQUE INDEX pedido_items_regalo_cadena_id_key
  ON public.pedido_items (regalo_cadena_id) WHERE regalo_cadena_id IS NOT NULL;
-- pedido_items se concede columna por columna (#1003). La lista completa, y no
-- solo la columna nueva: pedidoItemColumnas.test.ts toma el ultimo GRANT de
-- migrations/ como la lista vigente y la compara con PEDIDO_ITEM_COLUMNAS.
-- Conceder de nuevo una columna ya concedida no cambia nada.
GRANT SELECT (id, pedido_id, producto_id, cantidad, precio_unitario, subtotal, es_bonificacion, promocion_id, neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva, sucursal_id, tp_import_id, descripcion_regalo, stock_al_crear, ingreso_real_unitario, precio_lista_al_crear, origen_precio, descuento_pct, grupo_precio_escala_id, unidades_por_bloque_al_crear, origen_unidades_por_bloque, regalo_cadena_id) ON public.pedido_items TO authenticated, anon;

-- La FK es compuesta, como las otras tres a productos de esta tabla: el
-- aislamiento por sucursal (trampa 6).
ALTER TABLE public.pedido_item_sustituciones
  ADD COLUMN cadena_id uuid,
  ADD COLUMN producto_raiz_id bigint,
  ADD CONSTRAINT pedido_item_sustituciones_producto_raiz_id_fkey
    FOREIGN KEY (producto_raiz_id, sucursal_id) REFERENCES public.productos(id, sucursal_id);
COMMENT ON COLUMN public.pedido_item_sustituciones.cadena_id IS
  'La linea a la que pertenece el eslabon: pedido_items.regalo_cadena_id (mig 338, #1057). Una fila de reparto lleva la de su parte.';
COMMENT ON COLUMN public.pedido_item_sustituciones.producto_raiz_id IS
  'Solo filas de reparto: el producto que describe el texto de la linea repartida. Decide la marca de la parte (mig 338).';
CREATE INDEX idx_pedido_sustituciones_cadena ON public.pedido_item_sustituciones (cadena_id);

DO $datos$
DECLARE
  v_n int;
BEGIN
  IF EXISTS (SELECT 1 FROM pedido_item_sustituciones WHERE reparto_id IS NOT NULL) THEN
    RAISE EXCEPTION 'mig1057 · hay repartos: la clave por (pedido, promo) no alcanza. Revisar a mano.';
  END IF;
  SELECT count(*) INTO v_n
    FROM (SELECT pi.pedido_id, pi.promocion_id
            FROM pedido_items pi
           WHERE COALESCE(pi.es_bonificacion, false) AND pi.promocion_id IS NOT NULL
             AND EXISTS (SELECT 1 FROM pedido_item_sustituciones s
                          WHERE s.pedido_id = pi.pedido_id AND s.promocion_id = pi.promocion_id)
           GROUP BY 1, 2 HAVING count(*) > 1) x;
  IF v_n > 0 THEN
    RAISE EXCEPTION 'mig1057 · % (pedido, promo) con sustituciones tienen mas de una linea de regalo. Revisar a mano.', v_n;
  END IF;

  CREATE TEMP TABLE _mig1057_claves ON COMMIT DROP AS
  SELECT pedido_id, promocion_id, sucursal_id, gen_random_uuid() AS cadena_id
    FROM (SELECT DISTINCT pedido_id, promocion_id, sucursal_id FROM pedido_item_sustituciones) g;

  UPDATE pedido_item_sustituciones s SET cadena_id = c.cadena_id
    FROM _mig1057_claves c
   WHERE s.pedido_id = c.pedido_id AND s.promocion_id IS NOT DISTINCT FROM c.promocion_id
     AND s.sucursal_id = c.sucursal_id;
  UPDATE pedido_items pi SET regalo_cadena_id = c.cadena_id
    FROM _mig1057_claves c
   WHERE pi.pedido_id = c.pedido_id AND pi.promocion_id = c.promocion_id AND pi.sucursal_id = c.sucursal_id
     AND COALESCE(pi.es_bonificacion, false);
END
$datos$;

ALTER TABLE public.pedido_item_sustituciones ALTER COLUMN cadena_id SET NOT NULL;

-- ---------------------------------------------------------------------------
-- 2 · Las puras. Espejos en src/utils/repartoRegalo.ts; paridad en
--     src/utils/cadenaSustitucion.espejo.json.
-- ---------------------------------------------------------------------------
DROP FUNCTION public.regalo_sustituto_vigente(bigint, bigint, bigint, bigint);
DROP FUNCTION public.regalo_sustitucion_resuelta(bigint, bigint, bigint, bigint, numeric);
DROP FUNCTION public.regalo_raiz_cadena(bigint, bigint, bigint, bigint);
DROP FUNCTION public.regalo_cadena_pasos(jsonb, bigint);

-- Espejo: pasosDeCadena(). Los eslabones de UNA linea (cadena_id = p_cadena;
-- sin clave, ninguno), por id; se arranca despues del ultimo reparto de esa
-- clave y sus filas no reescriben nada; desde el producto, SIEMPRE el
-- siguiente eslabon cuyo original sea el producto actual (#1010).
CREATE FUNCTION public.regalo_cadena_pasos(p_eslabones jsonb, p_producto_id bigint, p_cadena uuid)
RETURNS bigint[]
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO 'public'
AS $fn$
DECLARE
  v_ids   bigint[];
  v_orig  bigint[];
  v_sust  bigint[];
  v_rep   boolean[];
  v_n     int;
  v_desde int := 0;
  v_i     int;
  v_nodo  bigint := p_producto_id;
  v_pasos bigint[] := '{}';
BEGIN
  IF p_cadena IS NULL THEN
    RETURN v_pasos;
  END IF;
  SELECT array_agg((e->>'id')::bigint ORDER BY (e->>'id')::bigint),
         array_agg((e->>'producto_original_id')::bigint ORDER BY (e->>'id')::bigint),
         array_agg((e->>'producto_sustituto_id')::bigint ORDER BY (e->>'id')::bigint),
         array_agg((e->>'reparto_id') IS NOT NULL ORDER BY (e->>'id')::bigint)
    INTO v_ids, v_orig, v_sust, v_rep
    FROM jsonb_array_elements(COALESCE(p_eslabones, '[]'::jsonb)) e
   WHERE (e->>'cadena_id')::uuid = p_cadena;
  v_n := COALESCE(array_length(v_ids, 1), 0);

  FOR v_i IN 1..v_n LOOP
    IF v_rep[v_i] THEN
      v_desde := v_i;
    END IF;
  END LOOP;

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

-- Espejo: raizDeSustitucion(). El producto con el que arranco la cadena que
-- termina en p_producto_id, caminando hacia atras por los eslabones vigentes
-- de la clave (posteriores al ultimo reparto, sin sus filas). NULL si no hay
-- raiz, si la raiz es el mismo producto (A -> P -> A) o si la cadena,
-- recorrida hacia adelante desde ella, no termina en este producto.
CREATE FUNCTION public.regalo_raiz_de_eslabones(p_eslabones jsonb, p_producto_id bigint, p_cadena uuid)
RETURNS bigint
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO 'public'
AS $fn$
DECLARE
  v_orig  bigint[];
  v_sust  bigint[];
  v_n     int;
  v_hasta int;
  v_i     int;
  v_nodo  bigint := p_producto_id;
  v_raiz  bigint;
  v_pasos bigint[];
  v_final bigint;
BEGIN
  IF p_cadena IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT array_agg((x.e->>'producto_original_id')::bigint ORDER BY x.id),
         array_agg((x.e->>'producto_sustituto_id')::bigint ORDER BY x.id)
    INTO v_orig, v_sust
    FROM (SELECT e, (e->>'id')::bigint AS id
            FROM jsonb_array_elements(COALESCE(p_eslabones, '[]'::jsonb)) e
           WHERE (e->>'cadena_id')::uuid = p_cadena) x
   WHERE x.e->>'reparto_id' IS NULL
     AND x.id > COALESCE((SELECT max((r->>'id')::bigint)
                            FROM jsonb_array_elements(COALESCE(p_eslabones, '[]'::jsonb)) r
                           WHERE (r->>'cadena_id')::uuid = p_cadena AND r->>'reparto_id' IS NOT NULL), 0);
  v_n := COALESCE(array_length(v_orig, 1), 0);
  v_hasta := v_n + 1;

  LOOP
    v_i := v_hasta - 1;
    WHILE v_i >= 1 AND v_sust[v_i] IS DISTINCT FROM v_nodo LOOP
      v_i := v_i - 1;
    END LOOP;
    EXIT WHEN v_i < 1;
    v_nodo  := v_orig[v_i];
    v_raiz  := v_nodo;
    v_hasta := v_i;
  END LOOP;

  IF v_raiz IS NULL OR v_raiz = p_producto_id THEN
    RETURN NULL;
  END IF;
  v_pasos := public.regalo_cadena_pasos(p_eslabones, v_raiz, p_cadena);
  IF COALESCE(array_length(v_pasos, 1), 0) = 0 THEN
    v_final := v_raiz;
  ELSE
    SELECT (e->>'producto_sustituto_id')::bigint INTO v_final
      FROM jsonb_array_elements(p_eslabones) e
     WHERE (e->>'id')::bigint = v_pasos[array_length(v_pasos, 1)]
     LIMIT 1;
  END IF;
  RETURN CASE WHEN v_final = p_producto_id THEN v_raiz END;
END;
$fn$;

-- Espejo: raizDescrita(). El producto que describe el texto de la linea: la
-- raiz de su cadena (o el producto mismo); y si la linea es una parte de un
-- reparto y la cadena arranca en su sabor, la raiz de la linea antes de
-- repartirse (producto_raiz_id de su fila de reparto). La marca va si esto es
-- distinto del producto (regla de la 331b).
CREATE FUNCTION public.regalo_raiz_descrita(p_eslabones jsonb, p_producto_id bigint, p_cadena uuid)
RETURNS bigint
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO 'public'
AS $fn$
DECLARE
  v_inicio bigint;
  v_rep    jsonb;
BEGIN
  v_inicio := COALESCE(public.regalo_raiz_de_eslabones(p_eslabones, p_producto_id, p_cadena), p_producto_id);
  IF p_cadena IS NULL THEN
    RETURN v_inicio;
  END IF;
  SELECT e INTO v_rep
    FROM jsonb_array_elements(COALESCE(p_eslabones, '[]'::jsonb)) e
   WHERE (e->>'cadena_id')::uuid = p_cadena AND e->>'reparto_id' IS NOT NULL
   ORDER BY (e->>'id')::bigint DESC
   LIMIT 1;
  IF v_rep IS NOT NULL AND (v_rep->>'producto_sustituto_id')::bigint = v_inicio THEN
    RETURN COALESCE((v_rep->>'producto_raiz_id')::bigint, (v_rep->>'producto_original_id')::bigint);
  END IF;
  RETURN v_inicio;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 3 · Las que leen la tabla.
-- ---------------------------------------------------------------------------

-- Los eslabones de un pedido + promo, en el formato de las puras.
CREATE FUNCTION public.regalo_eslabones(p_pedido_id bigint, p_promocion_id bigint, p_sucursal_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $fn$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', s.id,
           'producto_original_id', s.producto_original_id,
           'producto_sustituto_id', s.producto_sustituto_id,
           'reparto_id', s.reparto_id,
           'cadena_id', s.cadena_id,
           'producto_raiz_id', s.producto_raiz_id) ORDER BY s.id), '[]'::jsonb)
    FROM pedido_item_sustituciones s
   WHERE s.pedido_id = p_pedido_id
     AND s.promocion_id = p_promocion_id
     AND s.sucursal_id = p_sucursal_id;
$fn$;

CREATE FUNCTION public.regalo_sustitucion_resuelta(
  p_pedido_id bigint, p_promocion_id bigint, p_producto_id bigint,
  p_sucursal_id bigint, p_cantidad numeric, p_cadena uuid
) RETURNS TABLE (producto_id bigint, cantidad numeric, pasos integer, ya_sustituido boolean)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $fn$
DECLARE
  v_eslabones jsonb := public.regalo_eslabones(p_pedido_id, p_promocion_id, p_sucursal_id);
  v_id        bigint;
  -- El ultimo reparto de la clave: lo anterior ya no vale (mig 275).
  v_corte_id  bigint;
  v_nodo      bigint  := p_producto_id;
  -- Contenedor del nodo, para su factor (mig 295).
  v_ajuste    bigint  := p_producto_id;
  v_cant      numeric := p_cantidad;
  v_pasos     integer := 0;
  v_s         pedido_item_sustituciones%ROWTYPE;
BEGIN
  -- mig 338 (#1057): solo los eslabones de esta linea (su clave).
  FOREACH v_id IN ARRAY public.regalo_cadena_pasos(v_eslabones, p_producto_id, p_cadena) LOOP
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
   WHERE s.pedido_id = p_pedido_id AND s.promocion_id = p_promocion_id
     AND s.sucursal_id = p_sucursal_id AND s.cadena_id = p_cadena
     AND s.reparto_id IS NOT NULL;

  producto_id := v_nodo;
  cantidad    := v_cant;
  pasos       := v_pasos;
  -- Llego ya sustituido: es el sustituto de un eslabon vigente de SU cadena
  -- (no una auto-sustitucion) y no tiene eslabones para adelante.
  ya_sustituido := v_pasos = 0 AND p_cadena IS NOT NULL AND EXISTS (
    SELECT 1
      FROM pedido_item_sustituciones s
     WHERE s.pedido_id = p_pedido_id AND s.promocion_id = p_promocion_id
       AND s.sucursal_id = p_sucursal_id AND s.cadena_id = p_cadena
       AND s.reparto_id IS NULL
       AND s.producto_sustituto_id = p_producto_id
       AND s.producto_original_id <> p_producto_id
       AND (v_corte_id IS NULL OR s.id > v_corte_id));
  RETURN NEXT;
END;
$fn$;

CREATE FUNCTION public.regalo_sustituto_vigente(
  p_pedido_id bigint, p_promocion_id bigint, p_producto_id bigint, p_sucursal_id bigint, p_cadena uuid
) RETURNS bigint
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $fn$
  -- NULL = el regalo se guarda con el producto que vino. El final de la cadena
  -- de ESTA linea (mig 338).
  SELECT CASE WHEN r.pasos > 0 THEN r.producto_id END
    FROM public.regalo_sustitucion_resuelta(p_pedido_id, p_promocion_id, p_producto_id,
                                            p_sucursal_id, NULL, p_cadena) r;
$fn$;

-- Espejo de raizDeSustitucion() sobre la tabla: NULL si no hay raiz distinta.
CREATE FUNCTION public.regalo_raiz_cadena(
  p_pedido_id bigint, p_promocion_id bigint, p_producto_id bigint, p_sucursal_id bigint, p_cadena uuid
) RETURNS bigint
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $fn$
  SELECT public.regalo_raiz_de_eslabones(public.regalo_eslabones(p_pedido_id, p_promocion_id, p_sucursal_id),
                                         p_producto_id, p_cadena);
$fn$;

-- Lo que describe el texto de la linea; la marca va si es distinto del producto.
CREATE FUNCTION public.regalo_raiz_descrita_de_linea(
  p_pedido_id bigint, p_promocion_id bigint, p_producto_id bigint, p_sucursal_id bigint, p_cadena uuid
) RETURNS bigint
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $fn$
  SELECT public.regalo_raiz_descrita(public.regalo_eslabones(p_pedido_id, p_promocion_id, p_sucursal_id),
                                     p_producto_id, p_cadena);
$fn$;

-- La herencia de la clave al editar, para UN regalo del JSON que no es una
-- linea conservada de un reparto. Devuelve el elemento con '_cadena' (la clave
-- que va a tener la linea, o null) y, si hereda, con el producto normalizado a
-- la RAIZ de la cadena: el trigger recorre desde ahi, asi que no importa si el
-- front mando la raiz o el final (un front sin la clave manda el final con la
-- cantidad de la promo, que esta en unidades de la raiz).
-- · La promo tenia una linea y llega una: hereda su clave.
-- · No tenia (se cayo y vuelve): la de su ultima cadena, salvo que sea de un
--   reparto (decision A del dueno, 2026-10-09).
-- · Tenia varias (un reparto que se disuelve) o llegan varias: sin cadena.
-- · El producto del JSON no es ni el final ni la raiz: es otro regalo, sin cadena.
CREATE FUNCTION public.regalo_elemento_con_cadena(
  p_pedido_id bigint, p_promocion_id bigint, p_sucursal_id bigint, p_elemento jsonb, p_n_json integer
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $fn$
DECLARE
  v_sin    jsonb := (p_elemento - '_cadena') || jsonb_build_object('_cadena', NULL);
  v_prod   bigint := (p_elemento->>'producto_id')::bigint;
  v_n      int;
  v_cadena uuid;
  v_final  bigint;
  v_inicio bigint;
BEGIN
  IF p_n_json <> 1 THEN
    RETURN v_sin;
  END IF;
  SELECT count(*), (array_agg(pi.regalo_cadena_id))[1], (array_agg(pi.producto_id))[1]
    INTO v_n, v_cadena, v_final
    FROM pedido_items pi
   WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = p_sucursal_id
     AND COALESCE(pi.es_bonificacion, false) AND pi.promocion_id = p_promocion_id;

  IF v_n > 1 THEN
    RETURN v_sin;
  ELSIF v_n = 1 THEN
    IF v_cadena IS NULL THEN
      RETURN v_sin;
    END IF;
    v_inicio := COALESCE(public.regalo_raiz_cadena(p_pedido_id, p_promocion_id, v_final, p_sucursal_id, v_cadena),
                         v_final);
  ELSE
    SELECT s.cadena_id INTO v_cadena
      FROM pedido_item_sustituciones s
     WHERE s.pedido_id = p_pedido_id AND s.promocion_id = p_promocion_id AND s.sucursal_id = p_sucursal_id
     ORDER BY s.id DESC
     LIMIT 1;
    IF v_cadena IS NULL
       OR EXISTS (SELECT 1 FROM pedido_item_sustituciones s
                   WHERE s.pedido_id = p_pedido_id AND s.promocion_id = p_promocion_id
                     AND s.sucursal_id = p_sucursal_id AND s.cadena_id = v_cadena
                     AND s.reparto_id IS NOT NULL) THEN
      RETURN v_sin;
    END IF;
    SELECT s.producto_original_id INTO v_inicio
      FROM pedido_item_sustituciones s
     WHERE s.pedido_id = p_pedido_id AND s.promocion_id = p_promocion_id
       AND s.sucursal_id = p_sucursal_id AND s.cadena_id = v_cadena
     ORDER BY s.id
     LIMIT 1;
    SELECT r.producto_id INTO v_final
      FROM public.regalo_sustitucion_resuelta(p_pedido_id, p_promocion_id, v_inicio, p_sucursal_id,
                                              NULL, v_cadena) r;
  END IF;

  IF v_prod IS DISTINCT FROM v_final AND v_prod IS DISTINCT FROM v_inicio THEN
    RETURN v_sin;
  END IF;
  RETURN v_sin || jsonb_build_object('producto_id', v_inicio, '_cadena', v_cadena);
END;
$fn$;

REVOKE ALL ON FUNCTION public.regalo_cadena_pasos(jsonb, bigint, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.regalo_raiz_de_eslabones(jsonb, bigint, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.regalo_raiz_descrita(jsonb, bigint, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.regalo_eslabones(bigint, bigint, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.regalo_sustitucion_resuelta(bigint, bigint, bigint, bigint, numeric, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.regalo_sustituto_vigente(bigint, bigint, bigint, bigint, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.regalo_raiz_cadena(bigint, bigint, bigint, bigint, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.regalo_raiz_descrita_de_linea(bigint, bigint, bigint, bigint, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.regalo_elemento_con_cadena(bigint, bigint, bigint, jsonb, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.regalo_cadena_pasos(jsonb, bigint, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.regalo_raiz_de_eslabones(jsonb, bigint, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.regalo_raiz_descrita(jsonb, bigint, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.regalo_eslabones(bigint, bigint, bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.regalo_sustitucion_resuelta(bigint, bigint, bigint, bigint, numeric, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.regalo_sustituto_vigente(bigint, bigint, bigint, bigint, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.regalo_raiz_cadena(bigint, bigint, bigint, bigint, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.regalo_raiz_descrita_de_linea(bigint, bigint, bigint, bigint, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.regalo_elemento_con_cadena(bigint, bigint, bigint, jsonb, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 4 · El trigger. Cuerpo entero (es chico). CREATE OR REPLACE conserva la ACL.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.aplicar_sustituciones_regalo_pre_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_r RECORD;
  v_nombre_sustituto TEXT;
BEGIN
  IF NOT COALESCE(NEW.es_bonificacion, FALSE) THEN
    RETURN NEW;
  END IF;
  IF NEW.promocion_id IS NULL THEN
    RETURN NEW;
  END IF;
  -- mig 338 (#1057): una linea conservada de un reparto se reinserta tal como
  -- estaba. Ya es el final de su cadena y su cantidad esta en la unidad del
  -- final: recorrerla de nuevo reconvertia la cantidad en cada edicion
  -- (Y -> Z -> Y dejaba Y x5 de una Y x3). La marca la pone
  -- actualizar_pedido_items, que trae su descripcion.
  IF current_setting('app.regalo_linea_conservada', true) = '1' THEN
    RETURN NEW;
  END IF;

  -- mig 304 (#965): la cadena entera y la cantidad convertida en cada paso.
  -- mig 338 (#1057): la cadena de ESTA linea (su clave), no la de la promo.
  SELECT * INTO v_r
    FROM public.regalo_sustitucion_resuelta(NEW.pedido_id, NEW.promocion_id, NEW.producto_id,
                                            NEW.sucursal_id, NEW.cantidad, NEW.regalo_cadena_id);

  IF v_r.pasos > 0 THEN
    NEW.cantidad := v_r.cantidad;
  END IF;

  -- La marca que leen la hoja de ruta y la tarjeta: si el producto no es el
  -- que describe el texto (regla de la 331b). Para una parte de un reparto, lo
  -- que describe el texto es la raiz de la linea antes de repartirse.
  IF COALESCE(NEW.descripcion_regalo, '') NOT LIKE '%[Sustituido por:%'
     AND public.regalo_raiz_descrita_de_linea(NEW.pedido_id, NEW.promocion_id, v_r.producto_id,
                                             NEW.sucursal_id, NEW.regalo_cadena_id)
         IS DISTINCT FROM v_r.producto_id THEN
    SELECT nombre INTO v_nombre_sustituto
      FROM productos
     WHERE id = v_r.producto_id
       AND sucursal_id = NEW.sucursal_id;
    NEW.descripcion_regalo := public.regalo_descripcion_con_marca(NEW.descripcion_regalo, v_nombre_sustituto);
  END IF;

  IF v_r.producto_id IS DISTINCT FROM NEW.producto_id THEN
    NEW.producto_id := v_r.producto_id;

    -- El costo tiene que seguir al producto (issue #537). mig 257 (#673): la
    -- cascada es la de costo_valuacion (mig 238) y no una copia. Sin snapshot
    -- previo: esto ES el snapshot. Si el sustituto no tiene ningun costo
    -- cargado queda NULL antes que el del original.
    SELECT public.costo_valuacion(NULL, costo_promedio, costo_real, costo_sin_iva,
                                  COALESCE(impuestos_internos, 0))
      INTO NEW.costo_unitario_al_crear
      FROM productos
     WHERE id = v_r.producto_id
       AND sucursal_id = NEW.sucursal_id;
  END IF;
  RETURN NEW;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 5 · sustituir_regalo_pedido: la clave de la linea, en la linea y en el eslabon.
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._mig1057_ancla('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)'::regprocedure,
$ancla$  v_otra_categoria     BOOLEAN;$ancla$,
$nuevo$  v_otra_categoria     BOOLEAN;
  -- mig 338 (#1057): la clave de la cadena de esta linea.
  v_cadena             UUID;$nuevo$);

  PERFORM public._mig1057_ancla('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)'::regprocedure,
$ancla$  SELECT pi.id, pi.pedido_id, pi.producto_id, pi.cantidad, pi.es_bonificacion,
         pi.promocion_id, pi.sucursal_id, p.estado AS pedido_estado
    INTO v_item$ancla$,
$nuevo$  SELECT pi.id, pi.pedido_id, pi.producto_id, pi.cantidad, pi.es_bonificacion,
         pi.promocion_id, pi.sucursal_id, p.estado AS pedido_estado, pi.regalo_cadena_id
    INTO v_item$nuevo$);

  PERFORM public._mig1057_ancla('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)'::regprocedure,
$ancla$  UPDATE pedido_items
     SET producto_id = p_producto_nuevo_id, cantidad = p_cantidad_nueva, subtotal = 0,$ancla$,
$nuevo$  -- mig 338 (#1057): la de la linea, o una nueva si es su primer cambio.
  v_cadena := COALESCE(v_item.regalo_cadena_id, gen_random_uuid());
  UPDATE pedido_items
     SET producto_id = p_producto_nuevo_id, cantidad = p_cantidad_nueva, subtotal = 0,
         regalo_cadena_id = v_cadena,$nuevo$);

  PERFORM public._mig1057_ancla('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)'::regprocedure,
$ancla$           WHEN public.regalo_raiz_cadena(v_item.pedido_id, v_item.promocion_id,
                                          v_item.producto_id, v_sucursal) IS DISTINCT FROM p_producto_nuevo_id$ancla$,
$nuevo$           -- mig 338 (#1057): lo que describe el texto, por la cadena de ESTA
           -- linea (antes del eslabon nuevo, que va del actual al nuevo).
           WHEN public.regalo_raiz_descrita_de_linea(v_item.pedido_id, v_item.promocion_id,
                                          v_item.producto_id, v_sucursal, v_item.regalo_cadena_id)
                IS DISTINCT FROM p_producto_nuevo_id$nuevo$);

  PERFORM public._mig1057_ancla('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)'::regprocedure,
$ancla$    motivo, autorizado_por, sucursal_id, client_request_id
  ) VALUES ($ancla$,
$nuevo$    motivo, autorizado_por, sucursal_id, client_request_id, cadena_id
  ) VALUES ($nuevo$);

  PERFORM public._mig1057_ancla('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)'::regprocedure,
$ancla$    p_motivo, v_user_id, v_sucursal, p_client_request_id
  ) RETURNING id INTO v_sust_id;$ancla$,
$nuevo$    p_motivo, v_user_id, v_sucursal, p_client_request_id, v_cadena
  ) RETURNING id INTO v_sust_id;$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 6 · dividir_regalo_pedido: una clave nueva por parte.
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._mig1057_ancla('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'::regprocedure,
$ancla$  v_raiz               BIGINT;$ancla$,
$nuevo$  v_raiz               BIGINT;
  -- mig 338 (#1057): la clave de cada parte, por orden.
  v_cadenas            UUID[];$nuevo$);

  PERFORM public._mig1057_ancla('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'::regprocedure,
$ancla$         pi.unidades_por_bloque_al_crear, pi.origen_unidades_por_bloque,
         p.estado AS pedido_estado$ancla$,
$nuevo$         pi.unidades_por_bloque_al_crear, pi.origen_unidades_por_bloque,
         p.estado AS pedido_estado, pi.regalo_cadena_id$nuevo$);

  PERFORM public._mig1057_ancla('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'::regprocedure,
$ancla$  v_raiz := public.regalo_raiz_cadena(v_item.pedido_id, v_item.promocion_id,
                                       v_item.producto_id, v_sucursal);$ancla$,
$nuevo$  -- mig 338 (#1057): lo que describe el texto de la linea, por SU cadena.
  -- Va en la fila de reparto de cada parte: es la raiz que decide su marca.
  v_raiz := public.regalo_raiz_descrita_de_linea(v_item.pedido_id, v_item.promocion_id,
                                                 v_item.producto_id, v_sucursal, v_item.regalo_cadena_id);
  -- Cada parte arranca su propia cadena: los cambios de una no los ve otra.
  SELECT array_agg(gen_random_uuid()) INTO v_cadenas FROM generate_series(1, v_n);$nuevo$);

  PERFORM public._mig1057_ancla('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'::regprocedure,
$ancla$      motivo, autorizado_por, sucursal_id, client_request_id, reparto_id
    ) VALUES ($ancla$,
$nuevo$      motivo, autorizado_por, sucursal_id, client_request_id, reparto_id,
      cadena_id, producto_raiz_id
    ) VALUES ($nuevo$);

  PERFORM public._mig1057_ancla('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'::regprocedure,
$ancla$      CASE WHEN v_primera THEN p_client_request_id END, v_reparto
    ) RETURNING id INTO v_sust_id;$ancla$,
$nuevo$      CASE WHEN v_primera THEN p_client_request_id END, v_reparto,
      v_cadenas[v_parte.orden], v_raiz
    ) RETURNING id INTO v_sust_id;$nuevo$);

  PERFORM public._mig1057_ancla('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'::regprocedure,
$ancla$             descripcion_regalo = v_desc,
             -- COSTO-D: la cascada unica de la 238.$ancla$,
$nuevo$             descripcion_regalo = v_desc,
             regalo_cadena_id = v_cadenas[v_parte.orden],
             -- COSTO-D: la cascada unica de la 238.$nuevo$);

  PERFORM public._mig1057_ancla('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'::regprocedure,
$ancla$        costo_unitario_al_crear
      ) VALUES ($ancla$,
$nuevo$        costo_unitario_al_crear, regalo_cadena_id
      ) VALUES ($nuevo$);

  PERFORM public._mig1057_ancla('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'::regprocedure,
$ancla$           FROM productos WHERE id = v_parte.producto_id AND sucursal_id = v_sucursal)
      ) RETURNING id INTO v_nuevo_id;$ancla$,
$nuevo$           FROM productos WHERE id = v_parte.producto_id AND sucursal_id = v_sucursal),
        v_cadenas[v_parte.orden]
      ) RETURNING id INTO v_nuevo_id;$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 7 · actualizar_pedido_items.
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._mig1057_ancla('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure,
$ancla$  v_regalo_ya    BOOLEAN;$ancla$,
$nuevo$  v_regalo_ya    BOOLEAN;
  -- mig 338 (#1057): la clave de cada regalo y con que clave se busca su
  -- descripcion previa.
  v_cadena       UUID;
  v_clave_desc   TEXT;$nuevo$);

  -- Las lineas conservadas de un reparto llevan su clave.
  PERFORM public._mig1057_ancla('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure,
$ancla$             '_reparto', v_marca_reparto) ORDER BY pi.id) AS lineas$ancla$,
$nuevo$             '_reparto', v_marca_reparto,
             -- mig 338 (#1057): la clave de la parte.
             '_cadena', pi.regalo_cadena_id) ORDER BY pi.id) AS lineas$nuevo$);

  -- La clave de cada regalo, decidida por el server. Una '_cadena' que traiga
  -- el JSON se descarta siempre, salvo en las lineas que conservo el server
  -- (las de la marca '_reparto' de esta llamada).
  PERFORM public._mig1057_ancla('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure,
$ancla$  IF v_user_role IN ('preventista') THEN$ancla$,
$nuevo$  -- mig 338 (#1057): la clave de cadena de cada regalo (ver
  -- regalo_elemento_con_cadena). Un regalo que hereda la clave va con la raiz
  -- de su cadena, aunque el front haya mandado el final.
  SELECT COALESCE(jsonb_agg(
           CASE
             WHEN NOT COALESCE((x.e->>'es_bonificacion')::BOOLEAN, false) OR x.e->>'promocion_id' IS NULL
               THEN x.e - '_cadena'
             WHEN x.e->>'_reparto' IS NOT DISTINCT FROM v_marca_reparto
               THEN x.e
             ELSE public.regalo_elemento_con_cadena(
                    p_pedido_id, (x.e->>'promocion_id')::BIGINT, v_sucursal, x.e - '_reparto',
                    (SELECT count(*)::INT FROM jsonb_array_elements(v_items) j
                      WHERE COALESCE((j->>'es_bonificacion')::BOOLEAN, false)
                        AND j->>'promocion_id' = x.e->>'promocion_id'
                        AND j->>'_reparto' IS DISTINCT FROM v_marca_reparto))
           END ORDER BY x.o), '[]'::jsonb)
    INTO v_items
    FROM jsonb_array_elements(v_items) WITH ORDINALITY AS x(e, o);

  IF v_user_role IN ('preventista') THEN$nuevo$);

  -- Pre-chequeo de inactivos: con la clave; una conservada no se recorre.
  PERFORM public._mig1057_ancla('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure,
$ancla$    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      v_producto_sustituto := public.regalo_sustituto_vigente(
        p_pedido_id, v_promocion_id, v_producto_id, v_sucursal);$ancla$,
$nuevo$    -- mig 338 (#1057): la cadena de esta linea; una conservada ya es el final.
    IF v_es_bonificacion AND v_promocion_id IS NOT NULL
       AND v_item_nuevo->>'_reparto' IS DISTINCT FROM v_marca_reparto THEN
      v_producto_sustituto := public.regalo_sustituto_vigente(
        p_pedido_id, v_promocion_id, v_producto_id, v_sucursal, (v_item_nuevo->>'_cadena')::UUID);$nuevo$);

  -- Pre-chequeo de stock: con la clave, y contra la linea de la misma clave.
  PERFORM public._mig1057_ancla('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure,
$ancla$    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      SELECT r.producto_id, r.cantidad INTO v_producto_id, v_cantidad_nueva
        FROM public.regalo_sustitucion_resuelta(p_pedido_id, v_promocion_id, v_producto_id,
                                                v_sucursal, v_cantidad_nueva) r;
    END IF;$ancla$,
$nuevo$    -- mig 338 (#1057): la cadena de esta linea; una conservada va como esta.
    IF v_es_bonificacion AND v_promocion_id IS NOT NULL
       AND v_item_nuevo->>'_reparto' IS DISTINCT FROM v_marca_reparto THEN
      SELECT r.producto_id, r.cantidad INTO v_producto_id, v_cantidad_nueva
        FROM public.regalo_sustitucion_resuelta(p_pedido_id, v_promocion_id, v_producto_id,
                                                v_sucursal, v_cantidad_nueva,
                                                (v_item_nuevo->>'_cadena')::UUID) r;
    END IF;$nuevo$);

  PERFORM public._mig1057_ancla('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure,
$ancla$      AND (NOT v_es_bonificacion OR promocion_id IS NOT DISTINCT FROM v_promocion_id)
      AND sucursal_id = v_sucursal;$ancla$,
$nuevo$      AND (NOT v_es_bonificacion OR promocion_id IS NOT DISTINCT FROM v_promocion_id)
      -- mig 338 (#1057): un regalo con clave, contra SU linea. Dos lineas de
      -- la promo con el mismo producto (un reparto y un cambio) hacian que el
      -- INTO tomara cualquiera, y una diferencia fantasma frenaba la edicion.
      AND (v_item_nuevo->>'_cadena' IS NULL OR regalo_cadena_id = (v_item_nuevo->>'_cadena')::UUID)
      AND sucursal_id = v_sucursal;$nuevo$);

  -- #1083: la devolucion suma por producto.
  PERFORM public._mig1057_ancla('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure,
$ancla$  UPDATE productos p
  SET stock = p.stock + pi.cantidad
  FROM pedido_items pi
  WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
    AND COALESCE(pi.es_bonificacion, false) = false
    AND p.id = pi.producto_id AND p.sucursal_id = v_sucursal;$ancla$,
$nuevo$  -- mig 338 (#1083): sumado por producto. UPDATE ... FROM con dos lineas del
  -- mismo producto actualiza la fila UNA vez, con una sola de ellas: devolvia
  -- una linea y el INSERT de abajo descontaba las dos.
  UPDATE productos p
  SET stock = p.stock + d.cantidad
  FROM (SELECT pi.producto_id, sum(pi.cantidad) AS cantidad
          FROM pedido_items pi
         WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
           AND COALESCE(pi.es_bonificacion, false) = false
         GROUP BY pi.producto_id) d
  WHERE p.id = d.producto_id AND p.sucursal_id = v_sucursal;$nuevo$);

  PERFORM public._mig1057_ancla('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure,
$ancla$  UPDATE productos p
  SET stock = p.stock + pi.cantidad
  FROM pedido_items pi
  JOIN promociones pr ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
  WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
    AND COALESCE(pi.es_bonificacion, false) = true
    AND pi.promocion_id IS NOT NULL
    AND COALESCE(pr.regalo_mueve_stock, FALSE) = TRUE
    AND p.id = pi.producto_id AND p.sucursal_id = v_sucursal;$ancla$,
$nuevo$  -- mig 338 (#1083): idem para los regalos de modo A.
  UPDATE productos p
  SET stock = p.stock + d.cantidad
  FROM (SELECT pi.producto_id, sum(pi.cantidad) AS cantidad
          FROM pedido_items pi
          JOIN promociones pr ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
         WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
           AND COALESCE(pi.es_bonificacion, false) = true
           AND pi.promocion_id IS NOT NULL
           AND COALESCE(pr.regalo_mueve_stock, FALSE) = TRUE
         GROUP BY pi.producto_id) d
  WHERE p.id = d.producto_id AND p.sucursal_id = v_sucursal;$nuevo$);

  -- v_desc_previas por clave.
  PERFORM public._mig1057_ancla('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure,
$ancla$  SELECT COALESCE(jsonb_object_agg(x.clave, x.descripcion), '{}'::jsonb)
    INTO v_desc_previas
    FROM (SELECT DISTINCT ON (pi.promocion_id, pi.producto_id)
                 pi.promocion_id || ':' || pi.producto_id AS clave,
                 pi.descripcion_regalo AS descripcion
            FROM pedido_items pi
           WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
             AND COALESCE(pi.es_bonificacion, false) = true
             AND pi.promocion_id IS NOT NULL
           ORDER BY pi.promocion_id, pi.producto_id, pi.id) x;$ancla$,
$nuevo$  -- mig 338 (#1057): por la clave de la linea ('k:<clave>'): dos lineas de un
  -- reparto que terminan en el mismo producto ya no se pisan. Un regalo sin
  -- clave usa "promo:producto" solo si esa combinacion es de UNA linea.
  SELECT COALESCE(jsonb_object_agg(x.clave, x.descripcion), '{}'::jsonb)
    INTO v_desc_previas
    FROM (SELECT 'k:' || pi.regalo_cadena_id AS clave, pi.descripcion_regalo AS descripcion
            FROM pedido_items pi
           WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
             AND COALESCE(pi.es_bonificacion, false) = true
             AND pi.promocion_id IS NOT NULL AND pi.regalo_cadena_id IS NOT NULL
          UNION ALL
          SELECT pi.promocion_id || ':' || pi.producto_id, min(pi.descripcion_regalo)
            FROM pedido_items pi
           WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
             AND COALESCE(pi.es_bonificacion, false) = true
             AND pi.promocion_id IS NOT NULL
           GROUP BY pi.promocion_id, pi.producto_id
          HAVING count(*) = 1) x;$nuevo$);

  PERFORM public._mig1057_ancla('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure,
$ancla$      IF v_descripcion_regalo IS NULL THEN
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
        ELSE$ancla$,
$nuevo$      -- mig 338 (#1057): con la clave de la linea. La marca se conserva (sin
      -- la marca: la repone el trigger) si el producto no es el que describe
      -- el texto, la misma condicion que el trigger.
      IF v_descripcion_regalo IS NULL THEN
        v_cadena := (v_item_nuevo->>'_cadena')::UUID;
        SELECT r.producto_id, r.pasos, r.ya_sustituido
          INTO v_regalo_final, v_regalo_pasos, v_regalo_ya
          FROM public.regalo_sustitucion_resuelta(p_pedido_id, v_promocion_id, v_producto_id,
                                                  v_sucursal, NULL, v_cadena) r;
        v_clave_desc := CASE WHEN v_cadena IS NOT NULL THEN 'k:' || v_cadena
                             ELSE v_promocion_id || ':' || v_regalo_final END;
        v_desc_previa := v_desc_previas ->> v_clave_desc;
        IF v_desc_previas ? v_clave_desc
           AND COALESCE(v_desc_previa, '') NOT LIKE '%[Sustituido por:%' THEN
          v_descripcion_regalo := v_desc_previa;
        ELSIF v_desc_previas ? v_clave_desc
              AND public.regalo_raiz_descrita_de_linea(p_pedido_id, v_promocion_id, v_regalo_final,
                                                       v_sucursal, v_cadena)
                  IS DISTINCT FROM v_regalo_final THEN
          v_descripcion_regalo := public.regalo_descripcion_base(v_desc_previa);
        ELSE$nuevo$);

  -- El INSERT: la clave, y la marca de linea conservada para el trigger
  -- (por fila: se apaga despues de cada INSERT).
  PERFORM public._mig1057_ancla('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure,
$ancla$    INSERT INTO pedido_items (
      pedido_id, producto_id, cantidad, precio_unitario, subtotal,
      es_bonificacion, promocion_id,
      neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva,
      ingreso_real_unitario,
      sucursal_id, descripcion_regalo, costo_unitario_al_crear
    ) VALUES ($ancla$,
$nuevo$    -- mig 338 (#1057): una linea conservada de un reparto no recorre la
    -- cadena (ver el trigger). set_config es por transaccion: se apaga abajo,
    -- despues del INSERT.
    PERFORM set_config('app.regalo_linea_conservada',
      CASE WHEN v_item_nuevo->>'_reparto' IS NOT DISTINCT FROM v_marca_reparto THEN '1' ELSE '' END, true);
    INSERT INTO pedido_items (
      pedido_id, producto_id, cantidad, precio_unitario, subtotal,
      es_bonificacion, promocion_id,
      neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva,
      ingreso_real_unitario,
      sucursal_id, descripcion_regalo, costo_unitario_al_crear, regalo_cadena_id
    ) VALUES ($nuevo$);

  PERFORM public._mig1057_ancla('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure,
$ancla$      v_sucursal, v_descripcion_regalo, v_costo_al_crear
    )$ancla$,
$nuevo$      v_sucursal, v_descripcion_regalo, v_costo_al_crear,
      CASE WHEN v_es_bonificacion AND v_promocion_id IS NOT NULL
           THEN (v_item_nuevo->>'_cadena')::UUID END
    )$nuevo$);

  PERFORM public._mig1057_ancla('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure,
$ancla$    RETURNING id, producto_id, cantidad INTO v_pedido_item_guardado, v_producto_guardado, v_cantidad_guardada;$ancla$,
$nuevo$    RETURNING id, producto_id, cantidad INTO v_pedido_item_guardado, v_producto_guardado, v_cantidad_guardada;
    PERFORM set_config('app.regalo_linea_conservada', '', true);$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 8 · Verificacion: permisos, cuerpos, quien llama a que, compuertas, puras.
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  v_n     int;
  v_def   text;
  v_fn    text;
  v_audit jsonb;
  v_e     jsonb;
BEGIN
  -- (a) Las nuevas: solo service_role.
  FOREACH v_fn IN ARRAY ARRAY[
    'public.regalo_cadena_pasos(jsonb,bigint,uuid)',
    'public.regalo_raiz_de_eslabones(jsonb,bigint,uuid)',
    'public.regalo_raiz_descrita(jsonb,bigint,uuid)',
    'public.regalo_eslabones(bigint,bigint,bigint)',
    'public.regalo_sustitucion_resuelta(bigint,bigint,bigint,bigint,numeric,uuid)',
    'public.regalo_sustituto_vigente(bigint,bigint,bigint,bigint,uuid)',
    'public.regalo_raiz_cadena(bigint,bigint,bigint,bigint,uuid)',
    'public.regalo_raiz_descrita_de_linea(bigint,bigint,bigint,bigint,uuid)',
    'public.regalo_elemento_con_cadena(bigint,bigint,bigint,jsonb,integer)'] LOOP
    IF has_function_privilege('anon', v_fn, 'EXECUTE')
       OR has_function_privilege('authenticated', v_fn, 'EXECUTE')
       OR NOT has_function_privilege('service_role', v_fn, 'EXECUTE') THEN
      RAISE EXCEPTION 'mig1057 · % tiene que ejecutarla solo service_role', v_fn;
    END IF;
  END LOOP;

  -- (b) Las parchadas: misma firma, ACL, DEFINER y search_path.
  SELECT count(*) INTO v_n
    FROM _mig1057_acl a
    LEFT JOIN pg_proc p ON p.oid = to_regprocedure(a.fn)
   WHERE p.oid IS NULL
      OR p.proacl::text IS DISTINCT FROM a.acl
      OR p.prosecdef IS DISTINCT FROM a.prosecdef OR p.proconfig::text IS DISTINCT FROM a.cfg;
  IF v_n > 0 OR (SELECT count(*) FROM _mig1057_acl) <> 4 THEN
    RAISE EXCEPTION 'mig1057 · cambio la firma, la ACL, el SECURITY DEFINER o el search_path de % funcion(es)', v_n;
  END IF;

  -- (c) Una sola firma de cada una, y nadie fuera de la lista las llama: una
  --     funcion SQL que llama a una firma dropeada no falla al dropear.
  SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v_fn
    FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace
     AND p.proname IN ('regalo_cadena_pasos', 'regalo_raiz_de_eslabones', 'regalo_raiz_descrita',
                       'regalo_sustitucion_resuelta', 'regalo_sustituto_vigente', 'regalo_raiz_cadena')
     AND p.pronargs NOT IN (3, 5, 6);
  IF v_fn IS NOT NULL OR (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
        AND p.proname IN ('regalo_cadena_pasos', 'regalo_raiz_de_eslabones', 'regalo_raiz_descrita',
                          'regalo_sustitucion_resuelta', 'regalo_sustituto_vigente', 'regalo_raiz_cadena')) <> 6 THEN
    RAISE EXCEPTION 'mig1057 · quedo una firma vieja: %', v_fn;
  END IF;
  SELECT string_agg(p.proname || '->' || f, ', ') INTO v_fn
    FROM pg_proc p,
         unnest(ARRAY['regalo_sustitucion_resuelta(', 'regalo_sustituto_vigente(', 'regalo_raiz_cadena(',
                      'regalo_cadena_pasos(', 'regalo_raiz_descrita_de_linea(', 'regalo_elemento_con_cadena(']) f
   WHERE p.pronamespace = 'public'::regnamespace
     AND strpos(pg_get_functiondef(p.oid), f) > 0
     AND p.proname || '(' <> f
     AND (p.proname, f) NOT IN (
       ('actualizar_pedido_items', 'regalo_sustitucion_resuelta('),
       ('actualizar_pedido_items', 'regalo_sustituto_vigente('),
       ('actualizar_pedido_items', 'regalo_raiz_descrita_de_linea('),
       ('actualizar_pedido_items', 'regalo_elemento_con_cadena('),
       ('aplicar_sustituciones_regalo_pre_insert', 'regalo_sustitucion_resuelta('),
       ('aplicar_sustituciones_regalo_pre_insert', 'regalo_raiz_descrita_de_linea('),
       ('sustituir_regalo_pedido', 'regalo_raiz_descrita_de_linea('),
       ('dividir_regalo_pedido', 'regalo_raiz_descrita_de_linea('),
       ('dividir_regalo_pedido', 'regalo_sustituto_vigente('),   -- solo en un comentario
       ('regalo_sustitucion_resuelta', 'regalo_cadena_pasos('),
       ('regalo_raiz_de_eslabones', 'regalo_cadena_pasos('),
       ('regalo_sustituto_vigente', 'regalo_sustitucion_resuelta('),
       ('regalo_elemento_con_cadena', 'regalo_raiz_cadena('),
       ('regalo_elemento_con_cadena', 'regalo_sustitucion_resuelta('));
  IF v_fn IS NOT NULL THEN
    RAISE EXCEPTION 'mig1057 · llamadas fuera de la lista (revisar la firma): %', v_fn;
  END IF;

  -- (d) Los cuerpos llevan lo nuevo y no perdieron lo de antes.
  v_def := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure);
  IF v_def NOT LIKE '%regalo_elemento_con_cadena(%'
     OR v_def NOT LIKE '%app.regalo_linea_conservada%'
     OR v_def NOT LIKE '%GROUP BY pi.producto_id) d%'
     OR v_def LIKE '%SET stock = p.stock + pi.cantidad%'
     OR v_def NOT LIKE '%INTO v_pedido_item_guardado, v_producto_guardado, v_cantidad_guardada%'
     OR v_def NOT LIKE '%costo_valuacion(%'
     OR v_def NOT LIKE '%INTO v_items_guardados FROM pedido_items%'
     OR v_def NOT LIKE '%regalo_descripcion_de_linea(v_promocion_id, v_producto_id, v_sucursal)%' THEN
    RAISE EXCEPTION 'mig1057 · actualizar_pedido_items no quedo como se esperaba';
  END IF;
  v_def := pg_get_functiondef('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)'::regprocedure);
  IF v_def NOT LIKE '%regalo_cadena_id = v_cadena%' OR v_def NOT LIKE '%client_request_id, v_cadena%'
     OR v_def NOT LIKE '%costo_valuacion(%' OR v_def NOT LIKE '%''sustitucion_regalo''%' THEN
    RAISE EXCEPTION 'mig1057 · sustituir_regalo_pedido no quedo como se esperaba';
  END IF;
  v_def := pg_get_functiondef('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'::regprocedure);
  IF (length(v_def) - length(replace(v_def, 'v_cadenas[v_parte.orden]', ''))) / length('v_cadenas[v_parte.orden]') <> 3
     OR v_def NOT LIKE '%costo_valuacion(%' THEN
    RAISE EXCEPTION 'mig1057 · dividir_regalo_pedido no quedo como se esperaba';
  END IF;

  -- (e) Datos y columnas.
  IF EXISTS (SELECT 1 FROM pedido_item_sustituciones WHERE cadena_id IS NULL)
     OR to_regclass('public.pedido_items_regalo_cadena_id_key') IS NULL
     OR NOT has_column_privilege('authenticated', 'public.pedido_items', 'regalo_cadena_id', 'SELECT')
     OR EXISTS (SELECT 1 FROM pedido_items pi
                 WHERE pi.regalo_cadena_id IS NOT NULL
                   AND NOT EXISTS (SELECT 1 FROM pedido_item_sustituciones s
                                    WHERE s.cadena_id = pi.regalo_cadena_id AND s.pedido_id = pi.pedido_id
                                      AND s.promocion_id = pi.promocion_id)) THEN
    RAISE EXCEPTION 'mig1057 · las claves no quedaron como se esperaba';
  END IF;

  -- (f) Compuertas.
  v_audit := public.auditoria_integridad();
  SELECT count(*) INTO v_n
    FROM jsonb_array_elements(v_audit->'checks') c
   WHERE c->>'id' IN ('COSTO-D', 'STK-F', 'PROMO-A', 'PROMO-B', 'BONIF-C', 'BONIF-D', 'STK-B')
     AND NOT (c->>'ok')::boolean;
  IF v_n > 0 THEN
    RAISE EXCEPTION 'mig1057 · auditoria_integridad en rojo: %',
      (SELECT jsonb_agg(c) FROM jsonb_array_elements(v_audit->'checks') c
        WHERE NOT (c->>'ok')::boolean
          AND c->>'id' IN ('COSTO-D','STK-F','PROMO-A','PROMO-B','BONIF-C','BONIF-D','STK-B'));
  END IF;

  -- (g) Las puras, con el ejemplo del issue. El juego completo lo corre el gate.
  --     Reparto X(1) en X + Y(2): filas 10 (k1) y 11 (k2); L1 12 X->Y (k1); L2 13 Y->X (k2).
  v_e := '[
    {"id":10,"producto_original_id":1,"producto_sustituto_id":1,"reparto_id":"8b0d6f43-2a52-4d1c-9a51-6a3f8d0e5c11","cadena_id":"00000000-0000-4000-8000-0000000000a1","producto_raiz_id":1},
    {"id":11,"producto_original_id":1,"producto_sustituto_id":2,"reparto_id":"8b0d6f43-2a52-4d1c-9a51-6a3f8d0e5c11","cadena_id":"00000000-0000-4000-8000-0000000000a2","producto_raiz_id":1},
    {"id":12,"producto_original_id":1,"producto_sustituto_id":2,"reparto_id":null,"cadena_id":"00000000-0000-4000-8000-0000000000a1","producto_raiz_id":null},
    {"id":13,"producto_original_id":2,"producto_sustituto_id":1,"reparto_id":null,"cadena_id":"00000000-0000-4000-8000-0000000000a2","producto_raiz_id":null}]'::jsonb;
  IF public.regalo_cadena_pasos(v_e, 2, '00000000-0000-4000-8000-0000000000a1') <> '{}'::bigint[]
     OR public.regalo_cadena_pasos(v_e, 1, '00000000-0000-4000-8000-0000000000a1') <> '{12}'::bigint[]
     OR public.regalo_cadena_pasos(v_e, 1, NULL) <> '{}'::bigint[]
     OR public.regalo_raiz_de_eslabones(v_e, 2, '00000000-0000-4000-8000-0000000000a1') IS DISTINCT FROM 1
     OR public.regalo_raiz_de_eslabones(v_e, 1, '00000000-0000-4000-8000-0000000000a2') IS DISTINCT FROM 2
     OR public.regalo_raiz_descrita(v_e, 2, '00000000-0000-4000-8000-0000000000a1') IS DISTINCT FROM 1
     OR public.regalo_raiz_descrita(v_e, 1, '00000000-0000-4000-8000-0000000000a2') IS DISTINCT FROM 1
     OR public.regalo_raiz_descrita(v_e, 5, NULL) IS DISTINCT FROM 5 THEN
    RAISE EXCEPTION 'mig1057 · las puras no dan lo esperado con el ejemplo del issue';
  END IF;

  RAISE NOTICE 'mig1057 · verificacion OK';
END
$verif$;

-- ---------------------------------------------------------------------------
-- 9 · El ensayo, con productos y promos sinteticos, en un sub-bloque que se
--     deshace solo (SQLSTATE centinela, como la 304, la 313 y la 331b). Solo
--     llama RPCs publicas: el 2026-10-09 corrio contra los cuerpos de antes y
--     fallo en C1, C1b, C3 (el final), C4, C8 y el stock (C7).
--     X es el regalo default; Y y W de la misma categoria; Z de otra (se
--     convierte por valor). Promo 1 regala X, promo 2 regala Y; las dos modo A.
-- ---------------------------------------------------------------------------
DO $ensayo$
DECLARE
  v_admin   uuid;
  v_suc     bigint;
  v_cliente bigint;
  v_x bigint; v_y bigint; v_w bigint; v_z bigint; v_v bigint;
  v_p1 bigint; v_p2 bigint;
  v_res  jsonb;
  v_ped  bigint;
  v_peds bigint[] := '{}';
  v_l1 bigint; v_l2 bigint;
  v_hist int;
  v_got  jsonb;
  v_fallas text[] := '{}';
  c   CONSTANT text := '2 Botellas ZZ X a mano';
  c2  CONSTANT text := '2 Botellas ZZ Y a mano';
  my  CONSTANT text := ' [Sustituido por: ZZ ensayo mig1057 Y]';
  mw  CONSTANT text := ' [Sustituido por: ZZ ensayo mig1057 W]';
  mz  CONSTANT text := ' [Sustituido por: ZZ ensayo mig1057 Z]';
BEGIN
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'mig1057 · el ensayo necesita un admin activo con una sucursal activa';
  END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  PERFORM set_config('app.omitir_minimo_venta', '1', true);
  SELECT id INTO v_cliente FROM clientes WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;

  BEGIN
    INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria, unidades_por_bulto, costo_promedio)
    VALUES ('ZZ ensayo mig1057 X', 6000, 100, v_suc, 'ZZ ensayo mig1057', 6, 100) RETURNING id INTO v_x;
    INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria, unidades_por_bulto, costo_promedio)
    VALUES ('ZZ ensayo mig1057 Y', 6000, 100, v_suc, 'ZZ ensayo mig1057', 6, 110) RETURNING id INTO v_y;
    INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria, unidades_por_bulto, costo_promedio)
    VALUES ('ZZ ensayo mig1057 W', 6000, 100, v_suc, 'ZZ ensayo mig1057', 6, 120) RETURNING id INTO v_w;
    INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria, unidades_por_bulto, costo_promedio)
    VALUES ('ZZ ensayo mig1057 Z', 6000, 100, v_suc, 'ZZ ensayo mig1057 otra', 6, 130) RETURNING id INTO v_z;
    INSERT INTO productos (nombre, precio, stock, sucursal_id)
    VALUES ('ZZ ensayo mig1057 vendido', 100, 100, v_suc) RETURNING id INTO v_v;
    INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id, ajuste_automatico,
      producto_regalo_id, regalo_mueve_stock, descripcion_regalo)
    VALUES ('ZZ ensayo mig1057', 'bonificacion', CURRENT_DATE, v_suc, FALSE, v_x, TRUE, c) RETURNING id INTO v_p1;
    INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id, ajuste_automatico,
      producto_regalo_id, regalo_mueve_stock, descripcion_regalo)
    VALUES ('ZZ ensayo mig1057 dos', 'bonificacion', CURRENT_DATE, v_suc, FALSE, v_y, TRUE, c2) RETURNING id INTO v_p2;

    -- ===== C1 · #1057 literal: reparto X2 + Y2, L1 X->Y, L2 Y->X =====
    v_res := public.crear_pedido_completo(v_cliente, 100, v_admin, jsonb_build_array(
      jsonb_build_object('producto_id', v_x, 'cantidad', 4, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_p1),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), 'ensayo mig1057 C1');
    v_ped := (v_res->>'pedido_id')::bigint; v_peds := v_peds || v_ped;
    SELECT id INTO v_l1 FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    v_res := public.dividir_regalo_pedido(v_l1, jsonb_build_array(
      jsonb_build_object('producto_id', v_x, 'cantidad', 2), jsonb_build_object('producto_id', v_y, 'cantidad', 2)), 'ensayo C1', NULL);
    SELECT id INTO v_l2 FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion AND id <> v_l1;
    v_res := public.sustituir_regalo_pedido(v_l1, v_y, 2, 'ensayo C1 L1 X->Y', NULL, NULL);
    v_res := public.sustituir_regalo_pedido(v_l2, v_x, 2, 'ensayo C1 L2 Y->X', NULL, NULL);
    v_got := (SELECT jsonb_agg(jsonb_build_array(producto_id, cantidad, descripcion_regalo) ORDER BY id)
                FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion);
    -- L1 cambio a Y (su texto dice X): marca Y. L2 volvio a X, que es lo que
    -- dice su texto: sin marca (regla de la 331b, confirmada el 2026-10-09).
    IF v_got IS DISTINCT FROM jsonb_build_array(jsonb_build_array(v_y, 2, c || my), jsonb_build_array(v_x, 2, c)) THEN
      v_fallas := v_fallas || format('C1 tras sustituir: %s', v_got);
    END IF;
    SELECT count(*) INTO v_hist FROM pedido_historial WHERE pedido_id = v_ped AND campo_modificado = 'items';
    -- Editar sin cambios: el front manda las lineas del reparto como estan.
    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_y, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_p1),
      jsonb_build_object('producto_id', v_x, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_p1),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
    v_got := (SELECT jsonb_agg(jsonb_build_array(producto_id, cantidad, descripcion_regalo) ORDER BY producto_id)
                FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion);
    IF NOT COALESCE((v_res->>'success')::boolean, false)
       OR v_got IS DISTINCT FROM (SELECT jsonb_agg(e ORDER BY (e->>0)::bigint) FROM jsonb_array_elements(
            jsonb_build_array(jsonb_build_array(v_y, 2, c || my), jsonb_build_array(v_x, 2, c))) e) THEN
      v_fallas := v_fallas || format('C1 editar sin cambios: %s -> %s', v_res, v_got);
    END IF;
    IF (SELECT count(*) FROM pedido_historial WHERE pedido_id = v_ped AND campo_modificado = 'items') <> v_hist THEN
      v_fallas := v_fallas || 'C1 editar sin cambios dejo historial de items'::text;
    END IF;
    -- Un bundle viejo que manda UNA linea con el total: se conserva igual.
    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_x, 'cantidad', 4, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_p1),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
    v_got := (SELECT jsonb_agg(jsonb_build_array(producto_id, cantidad, descripcion_regalo) ORDER BY producto_id)
                FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion);
    IF NOT COALESCE((v_res->>'success')::boolean, false)
       OR v_got IS DISTINCT FROM (SELECT jsonb_agg(e ORDER BY (e->>0)::bigint) FROM jsonb_array_elements(
            jsonb_build_array(jsonb_build_array(v_y, 2, c || my), jsonb_build_array(v_x, 2, c))) e) THEN
      v_fallas := v_fallas || format('C1 editar con una linea (bundle viejo): %s -> %s', v_res, v_got);
    END IF;
    -- C2 · la cantidad cambia: el reparto se disuelve en una linea X sin cadena.
    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_x, 'cantidad', 6, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_p1),
      jsonb_build_object('producto_id', v_v, 'cantidad', 2, 'precio_unitario', 100)), v_admin);
    v_got := (SELECT jsonb_agg(jsonb_build_array(producto_id, cantidad, descripcion_regalo, regalo_cadena_id IS NULL))
                FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion);
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_got IS DISTINCT FROM jsonb_build_array(jsonb_build_array(v_x, 6, c, true)) THEN
      v_fallas := v_fallas || format('C2 reparto disuelto: %s -> %s', v_res, v_got);
    END IF;

    -- ===== C1b · reparto sin el original: X4 -> Y2 + W2, L1 Y->W, L2 W->Y =====
    v_res := public.crear_pedido_completo(v_cliente, 100, v_admin, jsonb_build_array(
      jsonb_build_object('producto_id', v_x, 'cantidad', 4, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_p1),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), 'ensayo mig1057 C1b');
    v_ped := (v_res->>'pedido_id')::bigint; v_peds := v_peds || v_ped;
    SELECT id INTO v_l1 FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    v_res := public.dividir_regalo_pedido(v_l1, jsonb_build_array(
      jsonb_build_object('producto_id', v_y, 'cantidad', 2), jsonb_build_object('producto_id', v_w, 'cantidad', 2)), 'ensayo C1b', NULL);
    SELECT id INTO v_l1 FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion AND producto_id = v_y;
    SELECT id INTO v_l2 FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion AND producto_id = v_w;
    v_res := public.sustituir_regalo_pedido(v_l1, v_w, 2, 'ensayo C1b L1 Y->W', NULL, NULL);
    v_res := public.sustituir_regalo_pedido(v_l2, v_y, 2, 'ensayo C1b L2 W->Y', NULL, NULL);
    v_got := (SELECT jsonb_agg(jsonb_build_array(producto_id, cantidad, descripcion_regalo) ORDER BY id)
                FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion);
    -- Las dos dicen X en su texto y ninguna es X: las dos llevan marca.
    IF v_got IS DISTINCT FROM jsonb_build_array(jsonb_build_array(v_w, 2, c || mw), jsonb_build_array(v_y, 2, c || my)) THEN
      v_fallas := v_fallas || format('C1b tras sustituir: %s', v_got);
    END IF;
    SELECT count(*) INTO v_hist FROM pedido_historial WHERE pedido_id = v_ped AND campo_modificado = 'items';
    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_w, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_p1),
      jsonb_build_object('producto_id', v_y, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_p1),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
    v_got := (SELECT jsonb_agg(jsonb_build_array(producto_id, cantidad, descripcion_regalo) ORDER BY producto_id)
                FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion);
    IF NOT COALESCE((v_res->>'success')::boolean, false)
       OR v_got IS DISTINCT FROM (SELECT jsonb_agg(e ORDER BY (e->>0)::bigint) FROM jsonb_array_elements(
            jsonb_build_array(jsonb_build_array(v_w, 2, c || mw), jsonb_build_array(v_y, 2, c || my))) e) THEN
      v_fallas := v_fallas || format('C1b editar sin cambios: %s -> %s', v_res, v_got);
    END IF;
    IF (SELECT count(*) FROM pedido_historial WHERE pedido_id = v_ped AND campo_modificado = 'items') <> v_hist THEN
      v_fallas := v_fallas || 'C1b editar sin cambios dejo historial de items'::text;
    END IF;

    -- ===== C3 · una linea, cambio por valor X2 -> Z5 =====
    v_res := public.crear_pedido_completo(v_cliente, 100, v_admin, jsonb_build_array(
      jsonb_build_object('producto_id', v_x, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_p1),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), 'ensayo mig1057 C3');
    v_ped := (v_res->>'pedido_id')::bigint; v_peds := v_peds || v_ped;
    SELECT id INTO v_l1 FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    v_res := public.sustituir_regalo_pedido(v_l1, v_z, 5, 'ensayo C3 X->Z', NULL, NULL);
    -- el front manda la raiz
    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_x, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_p1),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
    v_got := (SELECT jsonb_agg(jsonb_build_array(producto_id, cantidad, descripcion_regalo)) FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion);
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_got IS DISTINCT FROM jsonb_build_array(jsonb_build_array(v_z, 5, c || mz)) THEN
      v_fallas := v_fallas || format('C3 editar con la raiz: %s -> %s', v_res, v_got);
    END IF;
    -- un front sin la clave (cache viejo) manda el FINAL con la cantidad de la promo
    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_z, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_p1),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
    v_got := (SELECT jsonb_agg(jsonb_build_array(producto_id, cantidad, descripcion_regalo)) FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion);
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_got IS DISTINCT FROM jsonb_build_array(jsonb_build_array(v_z, 5, c || mz)) THEN
      v_fallas := v_fallas || format('C3 editar con el final: %s -> %s', v_res, v_got);
    END IF;
    -- una clave que manda el cliente se ignora: la linea sigue con la suya
    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_x, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_p1,
                         '_cadena', gen_random_uuid()),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
    v_got := (SELECT jsonb_agg(jsonb_build_array(producto_id, cantidad, descripcion_regalo,
                     EXISTS (SELECT 1 FROM pedido_item_sustituciones s WHERE s.cadena_id = pi.regalo_cadena_id)))
                FROM pedido_items pi WHERE pedido_id = v_ped AND es_bonificacion);
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_got IS DISTINCT FROM jsonb_build_array(jsonb_build_array(v_z, 5, c || mz, true)) THEN
      v_fallas := v_fallas || format('C3 clave del cliente: %s -> %s', v_res, v_got);
    END IF;
    -- la venta crece: proporcional
    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_x, 'cantidad', 4, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_p1),
      jsonb_build_object('producto_id', v_v, 'cantidad', 2, 'precio_unitario', 100)), v_admin);
    v_got := (SELECT jsonb_agg(jsonb_build_array(producto_id, cantidad, descripcion_regalo)) FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion);
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_got IS DISTINCT FROM jsonb_build_array(jsonb_build_array(v_z, 10, c || mz)) THEN
      v_fallas := v_fallas || format('C3 editar con mas venta: %s -> %s', v_res, v_got);
    END IF;

    -- ===== C4 · ciclo dentro de una parte: X4 -> X2 + Y2; parte Y: Y->Z 4, Z->Y 3 =====
    v_res := public.crear_pedido_completo(v_cliente, 100, v_admin, jsonb_build_array(
      jsonb_build_object('producto_id', v_x, 'cantidad', 4, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_p1),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), 'ensayo mig1057 C4');
    v_ped := (v_res->>'pedido_id')::bigint; v_peds := v_peds || v_ped;
    SELECT id INTO v_l1 FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    v_res := public.dividir_regalo_pedido(v_l1, jsonb_build_array(
      jsonb_build_object('producto_id', v_x, 'cantidad', 2), jsonb_build_object('producto_id', v_y, 'cantidad', 2)), 'ensayo C4', NULL);
    SELECT id INTO v_l2 FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion AND id <> v_l1;
    v_res := public.sustituir_regalo_pedido(v_l2, v_z, 4, 'ensayo C4 Y->Z', NULL, NULL);
    v_res := public.sustituir_regalo_pedido(v_l2, v_y, 3, 'ensayo C4 Z->Y', NULL, NULL);
    v_got := (SELECT jsonb_agg(jsonb_build_array(producto_id, cantidad, descripcion_regalo) ORDER BY id)
                FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion);
    -- la parte Y dice X en su texto y es Y: lleva marca Y aunque volvio al sabor del reparto.
    IF v_got IS DISTINCT FROM jsonb_build_array(jsonb_build_array(v_x, 2, c), jsonb_build_array(v_y, 3, c || my)) THEN
      v_fallas := v_fallas || format('C4 tras el ciclo: %s', v_got);
    END IF;
    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_x, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_p1),
      jsonb_build_object('producto_id', v_y, 'cantidad', 3, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_p1),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
    v_got := (SELECT jsonb_agg(jsonb_build_array(producto_id, cantidad, descripcion_regalo) ORDER BY producto_id)
                FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion);
    IF NOT COALESCE((v_res->>'success')::boolean, false)
       OR v_got IS DISTINCT FROM (SELECT jsonb_agg(e ORDER BY (e->>0)::bigint) FROM jsonb_array_elements(
            jsonb_build_array(jsonb_build_array(v_x, 2, c), jsonb_build_array(v_y, 3, c || my))) e) THEN
      v_fallas := v_fallas || format('C4 editar sin cambios: %s -> %s', v_res, v_got);
    END IF;
    -- C6 · un segundo reparto sobre la parte Y (Y3 -> Y1 + W2), despues editar.
    SELECT id INTO v_l2 FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion AND producto_id = v_y;
    v_res := public.dividir_regalo_pedido(v_l2, jsonb_build_array(
      jsonb_build_object('producto_id', v_y, 'cantidad', 1), jsonb_build_object('producto_id', v_w, 'cantidad', 2)), 'ensayo C6', NULL);
    v_got := (SELECT jsonb_agg(jsonb_build_array(producto_id, cantidad, descripcion_regalo) ORDER BY producto_id)
                FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion);
    -- las dos partes nuevas siguen hablando de X: las dos llevan marca.
    IF NOT COALESCE((v_res->>'success')::boolean, false)
       OR v_got IS DISTINCT FROM (SELECT jsonb_agg(e ORDER BY (e->>0)::bigint) FROM jsonb_array_elements(
            jsonb_build_array(jsonb_build_array(v_x, 2, c), jsonb_build_array(v_y, 1, c || my),
                              jsonb_build_array(v_w, 2, c || mw))) e) THEN
      v_fallas := v_fallas || format('C6 segundo reparto: %s -> %s', v_res, v_got);
    END IF;
    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_x, 'cantidad', 5, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_p1),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
    v_got := (SELECT jsonb_agg(jsonb_build_array(producto_id, cantidad, descripcion_regalo) ORDER BY producto_id)
                FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion);
    IF NOT COALESCE((v_res->>'success')::boolean, false)
       OR v_got IS DISTINCT FROM (SELECT jsonb_agg(e ORDER BY (e->>0)::bigint) FROM jsonb_array_elements(
            jsonb_build_array(jsonb_build_array(v_x, 2, c), jsonb_build_array(v_y, 1, c || my),
                              jsonb_build_array(v_w, 2, c || mw))) e) THEN
      v_fallas := v_fallas || format('C6 editar sin cambios: %s -> %s', v_res, v_got);
    END IF;

    -- ===== C5 · decision A: la promo se cae y vuelve con lo que eligio el admin =====
    v_res := public.crear_pedido_completo(v_cliente, 100, v_admin, jsonb_build_array(
      jsonb_build_object('producto_id', v_x, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_p1),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), 'ensayo mig1057 C5');
    v_ped := (v_res->>'pedido_id')::bigint; v_peds := v_peds || v_ped;
    SELECT id INTO v_l1 FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    v_res := public.sustituir_regalo_pedido(v_l1, v_y, 2, 'ensayo C5 X->Y', NULL, NULL);
    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_x, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_p1),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
    v_got := (SELECT jsonb_agg(jsonb_build_array(producto_id, cantidad, descripcion_regalo)) FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion);
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_got IS DISTINCT FROM jsonb_build_array(jsonb_build_array(v_y, 2, c || my)) THEN
      v_fallas := v_fallas || format('C5 la promo vuelve: %s -> %s', v_res, v_got);
    END IF;
    -- C5b · despues de un reparto, la promo que vuelve arranca del default.
    v_res := public.crear_pedido_completo(v_cliente, 100, v_admin, jsonb_build_array(
      jsonb_build_object('producto_id', v_x, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_p1),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), 'ensayo mig1057 C5b');
    v_ped := (v_res->>'pedido_id')::bigint; v_peds := v_peds || v_ped;
    SELECT id INTO v_l1 FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    v_res := public.dividir_regalo_pedido(v_l1, jsonb_build_array(
      jsonb_build_object('producto_id', v_y, 'cantidad', 1), jsonb_build_object('producto_id', v_w, 'cantidad', 1)), 'ensayo C5b', NULL);
    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_x, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_p1),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
    v_got := (SELECT jsonb_agg(jsonb_build_array(producto_id, cantidad, descripcion_regalo)) FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion);
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_got IS DISTINCT FROM jsonb_build_array(jsonb_build_array(v_x, 2, c)) THEN
      v_fallas := v_fallas || format('C5b vuelve tras reparto: %s -> %s', v_res, v_got);
    END IF;

    -- ===== C7 · dos promos cuyas cadenas terminan en Z =====
    v_res := public.crear_pedido_completo(v_cliente, 100, v_admin, jsonb_build_array(
      jsonb_build_object('producto_id', v_x, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_p1),
      jsonb_build_object('producto_id', v_y, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_p2),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), 'ensayo mig1057 C7');
    v_ped := (v_res->>'pedido_id')::bigint; v_peds := v_peds || v_ped;
    SELECT id INTO v_l1 FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion AND promocion_id = v_p1;
    SELECT id INTO v_l2 FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion AND promocion_id = v_p2;
    v_res := public.sustituir_regalo_pedido(v_l1, v_z, 5, 'ensayo C7 X->Z', NULL, NULL);
    v_res := public.sustituir_regalo_pedido(v_l2, v_z, 5, 'ensayo C7 Y->Z', NULL, NULL);
    SELECT count(*) INTO v_hist FROM pedido_historial WHERE pedido_id = v_ped AND campo_modificado = 'items';
    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_x, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_p1),
      jsonb_build_object('producto_id', v_y, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_p2),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
    v_got := (SELECT jsonb_agg(jsonb_build_array(promocion_id, producto_id, cantidad, descripcion_regalo) ORDER BY promocion_id)
                FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion);
    IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_got IS DISTINCT FROM jsonb_build_array(
         jsonb_build_array(v_p1, v_z, 5, c || mz), jsonb_build_array(v_p2, v_z, 5, c2 || mz)) THEN
      v_fallas := v_fallas || format('C7 dos promos: %s -> %s', v_res, v_got);
    END IF;
    IF (SELECT count(*) FROM pedido_historial WHERE pedido_id = v_ped AND campo_modificado = 'items') <> v_hist THEN
      v_fallas := v_fallas || 'C7 editar sin cambios dejo historial de items'::text;
    END IF;

    -- ===== #1083 · el stock: modo A, todo producto sintetico = 100 - lo que tienen las lineas vivas =====
    v_got := (SELECT jsonb_agg(jsonb_build_array(p.nombre, p.stock,
                 100 - COALESCE((SELECT sum(pi.cantidad) FROM pedido_items pi
                                  WHERE pi.producto_id = p.id AND pi.pedido_id = ANY(v_peds)), 0)) ORDER BY p.id)
                FROM productos p WHERE p.id IN (v_x, v_y, v_w, v_z, v_v)
                 AND p.stock <> 100 - COALESCE((SELECT sum(pi.cantidad) FROM pedido_items pi
                                  WHERE pi.producto_id = p.id AND pi.pedido_id = ANY(v_peds)), 0));
    IF v_got IS NOT NULL THEN
      v_fallas := v_fallas || format('stock descuadrado [nombre, stock, esperado]: %s', v_got);
    END IF;

    -- ===== Las claves: ninguna repetida entre lineas vivas, y cada eslabon de
    --       una clave es del pedido y la promo de su linea. =====
    IF EXISTS (SELECT 1 FROM pedido_items WHERE pedido_id = ANY(v_peds) AND regalo_cadena_id IS NOT NULL
                GROUP BY regalo_cadena_id HAVING count(*) > 1)
       OR EXISTS (SELECT 1 FROM pedido_items pi JOIN pedido_item_sustituciones s ON s.cadena_id = pi.regalo_cadena_id
                   WHERE pi.pedido_id = ANY(v_peds)
                     AND (s.pedido_id <> pi.pedido_id OR s.promocion_id IS DISTINCT FROM pi.promocion_id)) THEN
      v_fallas := v_fallas || 'claves repetidas o cruzadas entre lineas'::text;
    END IF;

    -- ===== C8 · dos lineas de la promo con el mismo producto y stock 0 de ese producto =====
    v_res := public.crear_pedido_completo(v_cliente, 100, v_admin, jsonb_build_array(
      jsonb_build_object('producto_id', v_x, 'cantidad', 4, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_p1),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), 'ensayo mig1057 C8');
    v_ped := (v_res->>'pedido_id')::bigint; v_peds := v_peds || v_ped;
    SELECT id INTO v_l1 FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion;
    v_res := public.dividir_regalo_pedido(v_l1, jsonb_build_array(
      jsonb_build_object('producto_id', v_x, 'cantidad', 3), jsonb_build_object('producto_id', v_w, 'cantidad', 1)), 'ensayo C8', NULL);
    v_res := public.sustituir_regalo_pedido(v_l1, v_w, 3, 'ensayo C8 X->W', NULL, NULL);
    UPDATE productos SET stock = 0 WHERE id = v_w;
    v_res := public.actualizar_pedido_items(v_ped, jsonb_build_array(
      jsonb_build_object('producto_id', v_w, 'cantidad', 3, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_p1),
      jsonb_build_object('producto_id', v_w, 'cantidad', 1, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_p1),
      jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)), v_admin);
    IF NOT COALESCE((v_res->>'success')::boolean, false)
       OR (SELECT stock FROM productos WHERE id = v_w) <> 0 THEN
      v_fallas := v_fallas || format('C8 mismo producto dos veces sin stock: %s stock W=%s', v_res,
        (SELECT stock FROM productos WHERE id = v_w));
    END IF;

    IF array_length(v_fallas, 1) > 0 THEN
      RAISE EXCEPTION 'mig1057 · el ensayo fallo en % caso(s):%', array_length(v_fallas, 1),
        E'\n  - ' || array_to_string(v_fallas, E'\n  - ');
    END IF;
    RAISE EXCEPTION 'mig1057-ok' USING ERRCODE = '2F000';
  EXCEPTION WHEN SQLSTATE '2F000' THEN
    IF SQLERRM <> 'mig1057-ok' THEN RAISE; END IF;
    RAISE NOTICE 'mig1057 · ensayo OK: cada linea con su cadena y su marca, la conservada no se recorre, la clave la decide el server, la promo que vuelve, y el stock de dos lineas del mismo producto';
  END;
END
$ensayo$;

-- ---------------------------------------------------------------------------
-- 10 · Se saca el andamio.
-- ---------------------------------------------------------------------------
DROP FUNCTION public._mig1057_ancla(regprocedure, text, text);

COMMIT;
