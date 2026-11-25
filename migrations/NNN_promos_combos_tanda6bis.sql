-- =========================================================================
-- NNN · PROMOS Y COMBOS: EL OTRO SABOR SIN SU BULTO EN EL ALTA Y LA EDICIÓN, EL
--       COMBO CON UN COMPONENTE SIN LISTA, EL COMBO QUE SE SUMA AL PRECIO DE HOY
--       Y EL REGALO DEL PEDIDO EN LA EDICIÓN Y EN EL CAMBIO DE CLIENTE
--       (tanda 6 bis del plan #1603, tarjeta I: promos-B1, B4 y B5 de la
--        reauditoría del 24/11 y las notas N1 y N2 de la segunda lente de promos)
--
-- Agrega a `pedido_combos` la columna `tramos` (con su CHECK), crea cuatro funciones
-- (`_regalo_sin_bulto`, `_combo_tramos_para`, `_combo_tramos_validos` y la nueva firma
-- de `_combo_total`, que reemplaza a la vieja), reescribe `_guardar_combos_pedido`, y
-- parcha por ancla, con premisa de md5 sobre los cuerpos vivos de la 544,
-- `regalo_fuera_de_promo`, `_regalo_de_la_promo` y `combo_fuera_de_regla`. Suma además,
-- por ancla y SIN premisa de md5 (son de la tarjeta H y su migración va antes: el
-- ancla aparece exactamente una vez), una llamada a `_regalo_sin_bulto` en la rama del
-- admin de `crear_pedido_completo` y de `actualizar_pedido_items`. No cambia firmas ni
-- permisos de lo que existe (salvo `_combo_total`, interna: sin EXECUTE para
-- authenticated, la llama sólo `combo_fuera_de_regla`).
-- Ensayo: scripts/test-promos-combos-tanda6bis-1603.sql. Se aplica en LF.
--
-- -------------------------------------------------------------------------
-- 1 · promos-B1 en el alta y la edición: otro sabor del mismo rubro sin «unidades
--     por bulto» no hereda el empaque de la promo
-- -------------------------------------------------------------------------
-- La 544 se lo pidió a la sustitución y al reparto. En el alta y la edición del pedido
-- se podía cargar como regalo otro sabor del mismo rubro (el admin desde el selector;
-- cualquiera con un request armado a mano), y su barra contaba con el N de la promo,
-- que es el empaque del regalo. `_regalo_sin_bulto` es la regla: un regalo de una promo
-- de fracción con unidades por bloque cuya barra no es la del contenedor de la promo, y
-- cuyo contenedor no tiene bulto, se rechaza. No la piden el regalo de la promo, un
-- producto que el pedido ya tenía como regalo de esa promo (o el pedido original de un
-- cambio de cliente), una línea con su cadena de sustitución, una promo sin unidades por
-- bloque ni una que mueve stock. La llama `regalo_fuera_de_promo` (paso 3: quien no es
-- admin, y el bot) y, decisión de la coordinadora con el molde de la 544 (es un dato que
-- falta para contar la barra, no un permiso), la rama del admin del alta y de la
-- edición. El selector del admin en ModalPedido dice lo mismo antes de confirmar.
--
-- -------------------------------------------------------------------------
-- 2 · promos-B4: el combo acumulable con un componente sin precio de lista
-- -------------------------------------------------------------------------
-- `precio_fuera_de_politica` no valida una línea sin lista: en la edición, la que
-- conserva su precio (1559-b3) podía declarar un `precio_sin_escala_unitario` más alto
-- o un `precio_sin_combo_unitario` más bajo, y el descuento de escala de más le bajaba
-- `_combo_total` y el precio a las otras líneas. Ahora `combo_fuera_de_regla` publica
-- el sin escala que declaró cada línea (`app.combo_sin_escala`), `_guardar_combos_pedido`
-- lo guarda en `pedido_combos.precios` (`sin_escala`, junto a `combo` y `sin_combo`), y a
-- una línea sin lista no se le acepta un descuento de escala por unidad (sin escala −
-- sin combo) mayor que el guardado: 0 si la foto no lo tiene (una foto de antes, o un
-- producto que no estaba en el combo).
--
-- -------------------------------------------------------------------------
-- 3 · promos-B5: los combos que se suman al editar, al precio de hoy
-- -------------------------------------------------------------------------
-- Decisión del dueño (24/11): «los combos nuevos, al precio de hoy»; y (25/11): «un
-- renglón, precio promedio». Combo de $ 1.000 que hoy vale $ 1.200; el pedido de ayer
-- tiene 1; para sumar otro, quien no es admin lo carga a $ 1.200: 2 combos, $ 2.200, a
-- $ 1.100 cada uno en sus líneas. La foto lleva los tramos de precio en
-- `pedido_combos.tramos` ([{cantidad, precio}], en el orden en que entraron; NULL, en
-- los de antes, es un tramo de `cantidad_combos_armados` a `precio`). Al editar, lo que
-- el pedido conserva sale de sus tramos (los primeros que entraron: recorte LIFO), lo
-- que se suma va al precio de hoy (`_combo_tramos_para`), y el total es la suma de los
-- tramos menos lo que bajó la escala (`_combo_total` con tramos). Una línea por producto
-- y por combo, como siempre: la comisión, los reportes de combos, la nota de crédito y
-- la salvedad leen las líneas y `precios`, no `precio`. La foto del admin también suma
-- al precio de hoy (la plata de sus líneas no se valida, como hoy).
--
-- -------------------------------------------------------------------------
-- 4 · N1 y N2 de la segunda lente: el regalo del pedido
-- -------------------------------------------------------------------------
-- N1 · Decisión del dueño: el regalo del pedido es el que la promo daba cuando nació. La
-- edición que vuelve a ese regalo (un reparto que ya no cierra, en la pantalla) mandaba
-- el regalo de hoy; ahora manda el del pedido, y `regalo_fuera_de_promo` (paso 3) lo
-- acepta en una promo que el pedido ya tenía: el regalo de referencia
-- (`_regalo_de_la_promo`) o uno de su rubro, además del de hoy como siempre.
-- N2 · El pedido rehecho por un cambio de cliente nace de nuevo, pero su regalo es el del
-- original: `_regalo_de_la_promo` sigue el `pedido_historial` del cambio de cliente
-- («(cambio de cliente desde pedido #N)», que escribe cambiar_cliente_pedido) hasta el
-- primer pedido y mide desde su alta. Sin columna nueva.
--
-- Revertir: volver `regalo_fuera_de_promo`, `_regalo_de_la_promo`, `combo_fuera_de_regla`
-- y `_guardar_combos_pedido` a los cuerpos de la premisa, sacar los dos bloques del admin
-- de `crear_pedido_completo` y `actualizar_pedido_items`, recrear `_combo_total` con su
-- firma vieja, y borrar las funciones nuevas, el CHECK y la columna.
-- =========================================================================

BEGIN;

-- La única tabla con DDL (la columna y su CHECK): su lock primero, sin esperar.
LOCK TABLE public.pedido_combos IN ACCESS EXCLUSIVE MODE NOWAIT;

SET LOCAL lock_timeout = '5s';

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos (ledger en la 544) de las funciones de esta tarjeta, lo
-- que el arreglo usa tal como está, y que lo nuevo todavía no existe.
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.regalo_fuera_de_promo(jsonb,jsonb,bigint,bigint,date)', '7a5d67c746a4d5bb67b8d313d13584be'),
    ('public._regalo_de_la_promo(bigint,bigint,bigint,uuid,bigint,numeric)', '0ed07e72b5d047e60695d13bfae3d312'),
    ('public.combo_fuera_de_regla(jsonb,bigint,date,bigint,boolean)', '589942c33c244c752112bf7712d1fe84'),
    ('public._guardar_combos_pedido(bigint,bigint)', '3279e74715f9b580e7323bb66a085d55'),
    ('public._combo_total(numeric,integer,jsonb)', '0469ca14f72cc71b0864a50244367159'),
    ('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)', NULL),
    ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', NULL),
    ('public.contenedor_de_barra(bigint,bigint,bigint,bigint)', NULL),
    ('public._regalo_modo_del_pedido(bigint,bigint,bigint)', NULL),
    ('public._combo_definicion(bigint,bigint)', NULL),
    ('public._combo_cantidad(jsonb,jsonb)', NULL),
    ('public.regalo_misma_categoria(bigint,bigint,bigint)', NULL)
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    IF r.h IS NOT NULL THEN
      SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
      IF v IS DISTINCT FROM r.h THEN
        RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
      END IF;
    END IF;
  END LOOP;
  IF to_regprocedure('public._regalo_sin_bulto(jsonb,bigint,bigint)') IS NOT NULL
     OR to_regprocedure('public._combo_tramos_para(jsonb,integer,numeric)') IS NOT NULL
     OR to_regprocedure('public._combo_tramos_validos(jsonb,integer)') IS NOT NULL
     OR to_regprocedure('public._combo_total(numeric,integer,jsonb,jsonb)') IS NOT NULL
     OR EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.pedido_combos'::regclass
                                             AND attname = 'tramos' AND NOT attisdropped) THEN
    RAISE EXCEPTION 'mig NNN · lo que crea esta migración ya existe';
  END IF;
END
$premisas$;

-- =========================================================================
-- 1 · promos-B1: la regla del bulto, en una función
-- =========================================================================
CREATE FUNCTION public._regalo_sin_bulto(p_items jsonb, p_sucursal bigint, p_pedido_id bigint)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path = public, pg_temp
AS $function$
DECLARE
  -- promos-B1 (tanda 6 bis de #1603): el pedido cuyos regalos ya están, también el
  -- original de un cambio de cliente (el pedido nuevo recrea sus líneas tal cual).
  v_ped    bigint := COALESCE(p_pedido_id, NULLIF(current_setting('app.cambio_cliente_desde', true), '')::bigint);
  v_nombre text;
BEGIN
  -- Un regalo de una promo de fracción con unidades por bloque cuenta en la barra de SU
  -- contenedor (contenedor_de_barra, como el alta y el motor), con el bulto de ese
  -- contenedor o, sin el dato, con el N de la promo, que es el empaque del regalo. Así
  -- un sabor suelto contaba como si viniera en el fardo del regalo. Como en
  -- sustituir_regalo_pedido y dividir_regalo_pedido (544), sin el bulto no entra. No lo
  -- piden el regalo de la promo (su barra es la del contenedor), un producto que el
  -- pedido ya tenía como regalo de esa promo, una línea con su cadena (la sustitución ya
  -- lo pidió), una promo sin unidades por bloque ni una que mueve stock.
  SELECT string_agg(DISTINCT pr.nombre, ', ' ORDER BY pr.nombre) INTO v_nombre
    FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_items) = 'array' THEN p_items ELSE '[]'::jsonb END) e
    JOIN promociones p ON p.id = NULLIF(e->>'promocion_id', '')::bigint AND p.sucursal_id = p_sucursal
    JOIN productos pr ON pr.id = NULLIF(e->>'producto_id', '')::bigint AND pr.sucursal_id = p_sucursal
   WHERE COALESCE((e->>'es_bonificacion')::boolean, false)
     AND NOT (p_pedido_id IS NOT NULL AND e->>'_cadena' IS NOT NULL)
     AND COALESCE(p.unidades_por_bloque, 0) > 0
     AND NOT COALESCE(CASE WHEN v_ped IS NULL THEN p.regalo_mueve_stock
                           ELSE public._regalo_modo_del_pedido(v_ped, p.id, p_sucursal) END, true)
     AND NOT (v_ped IS NOT NULL
              AND EXISTS (SELECT 1 FROM pedido_items pi
                           WHERE pi.pedido_id = v_ped AND pi.sucursal_id = p_sucursal
                             AND COALESCE(pi.es_bonificacion, false)
                             AND pi.promocion_id = p.id AND pi.producto_id = pr.id))
     AND public.contenedor_de_barra(p.id, pr.id, p_sucursal, pr.id) IS DISTINCT FROM p.ajuste_producto_id
     AND (SELECT pc.unidades_por_bulto FROM productos pc
           WHERE pc.id = public.contenedor_de_barra(p.id, pr.id, p_sucursal, pr.id)
             AND pc.sucursal_id = p_sucursal) IS NULL;
  IF v_nombre IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN 'Para regalar ' || v_nombre
         || ' hay que cargar en su ficha cuántas unidades sueltas trae cada unidad de stock (unidades por bulto).';
END
$function$;

-- Sólo de server: la llaman regalo_fuera_de_promo y las RPC del alta y la edición.
REVOKE ALL ON FUNCTION public._regalo_sin_bulto(jsonb, bigint, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._regalo_sin_bulto(jsonb, bigint, bigint) TO service_role;

-- =========================================================================
-- 3 · promos-B5: los tramos de la foto de un combo
-- =========================================================================
-- Los tramos de `p_k` combos a partir de `p_tramos`: con menos, los primeros que entraron
-- (se van primero los últimos: LIFO); con más, lo que falta en un tramo nuevo a
-- `p_precio_nuevo` (pegado al último si es el mismo precio). Espejo: `tramosDelCombo`
-- (src/utils/combos.ts), con los casos de combos.espejo.json.
CREATE FUNCTION public._combo_tramos_para(p_tramos jsonb, p_k integer, p_precio_nuevo numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path = public, pg_temp
AS $function$
DECLARE
  v_out   jsonb := '[]'::jsonb;
  v_resto integer := GREATEST(COALESCE(p_k, 0), 0);
  v_toma  integer;
  t       record;
BEGIN
  FOR t IN
    SELECT (x->>'cantidad')::integer AS cantidad, (x->>'precio')::numeric AS precio
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_tramos) = 'array' THEN p_tramos ELSE '[]'::jsonb END)
           WITH ORDINALITY AS a(x, o)
     ORDER BY a.o
  LOOP
    EXIT WHEN v_resto <= 0;
    v_toma := LEAST(t.cantidad, v_resto);
    CONTINUE WHEN v_toma <= 0;
    v_out := v_out || jsonb_build_array(jsonb_build_object('cantidad', v_toma, 'precio', t.precio));
    v_resto := v_resto - v_toma;
  END LOOP;
  IF v_resto > 0 THEN
    IF jsonb_array_length(v_out) > 0
       AND (v_out->-1->>'precio')::numeric = p_precio_nuevo THEN
      v_out := jsonb_set(v_out, '{-1,cantidad}', to_jsonb((v_out->-1->>'cantidad')::integer + v_resto));
    ELSE
      v_out := v_out || jsonb_build_array(jsonb_build_object('cantidad', v_resto, 'precio', p_precio_nuevo));
    END IF;
  END IF;
  RETURN v_out;
END
$function$;

REVOKE ALL ON FUNCTION public._combo_tramos_para(jsonb, integer, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._combo_tramos_para(jsonb, integer, numeric) TO service_role;

-- El CHECK de la columna: NULL (una foto de antes), o un array de tramos con cantidad
-- entera > 0 y precio > 0, con centavos y finito (un número de JSON no es NaN ni
-- infinito, pero un string sí: tiene que ser número), que suman los combos armados.
CREATE FUNCTION public._combo_tramos_validos(p_tramos jsonb, p_armados integer)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path = public, pg_temp
AS $function$
  SELECT p_tramos IS NULL
      OR (jsonb_typeof(p_tramos) = 'array'
          AND NOT EXISTS (
                SELECT 1 FROM jsonb_array_elements(p_tramos) x
                 WHERE jsonb_typeof(x) <> 'object'
                    OR jsonb_typeof(x->'cantidad') IS DISTINCT FROM 'number'
                    OR jsonb_typeof(x->'precio') IS DISTINCT FROM 'number'
                    OR (x->>'cantidad')::numeric <= 0
                    OR (x->>'cantidad')::numeric <> trunc((x->>'cantidad')::numeric)
                    OR (x->>'precio')::numeric <= 0
                    OR (x->>'precio')::numeric > 9999999999.99
                    OR (x->>'precio')::numeric <> round((x->>'precio')::numeric, 2))
          AND (SELECT COALESCE(sum((x->>'cantidad')::numeric), 0) FROM jsonb_array_elements(p_tramos) x)
              = COALESCE(p_armados, 0));
$function$;

REVOKE ALL ON FUNCTION public._combo_tramos_validos(jsonb, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._combo_tramos_validos(jsonb, integer) TO service_role;

ALTER TABLE public.pedido_combos ADD COLUMN tramos jsonb;
COMMENT ON COLUMN public.pedido_combos.tramos IS
  'promos-B5 (tanda 6 bis de #1603): los tramos de precio de los combos armados, [{cantidad, precio}] en el orden en que entraron. NULL: un tramo de cantidad_combos_armados a precio (las fotos de antes). Lo escribe _guardar_combos_pedido.';
ALTER TABLE public.pedido_combos ADD CONSTRAINT pedido_combos_tramos_validos
  CHECK (public._combo_tramos_validos(tramos, cantidad_combos_armados));

-- El total: con tramos, Σ precio × cantidad de cada tramo en lugar de precio × k.
-- Firma nueva con el parámetro opcional y sin la vieja (dos sobrecargas con 3
-- argumentos serían ambiguas). Espejo: totalDelCombo.
DROP FUNCTION public._combo_total(numeric, integer, jsonb);

CREATE FUNCTION public._combo_total(p_precio numeric, p_k integer, p_lineas jsonb, p_tramos jsonb DEFAULT NULL)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
 SET search_path = public, pg_temp
AS $function$
  SELECT round((CASE WHEN p_tramos IS NULL THEN round(p_precio * 100) * p_k
                     ELSE (SELECT sum(round((t->>'precio')::numeric * 100) * (t->>'cantidad')::numeric)
                             FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_tramos) = 'array'
                                                            THEN p_tramos ELSE '[]'::jsonb END) t) END
                - COALESCE((SELECT sum(NULLIF(e->>'cantidad', '')::numeric
                                       * (round(NULLIF(e->>'sin_escala', '')::numeric * 100)
                                          - round(NULLIF(e->>'ref', '')::numeric * 100)))
                              FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_lineas) = 'array'
                                                             THEN p_lineas ELSE '[]'::jsonb END) e
                             WHERE NULLIF(e->>'sin_escala', '') IS NOT NULL), 0)) / 100, 2);
$function$;

REVOKE ALL ON FUNCTION public._combo_total(numeric, integer, jsonb, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._combo_total(numeric, integer, jsonb, jsonb) TO service_role;

-- La foto: los tramos en cada guardado, y el sin escala que declaró cada línea (B4).
CREATE OR REPLACE FUNCTION public._guardar_combos_pedido(p_pedido_id bigint, p_sucursal bigint)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path = public, pg_temp
AS $function$
DECLARE
  r     record;
  v_f   record;
  v_def jsonb;
  v_k   integer;
  -- #1301: el pedido nuevo de un cambio de cliente hereda la foto del original.
  v_original bigint := NULLIF(current_setting('app.combo_foto_pedido', true), '')::bigint;
  -- promos-B4 (tanda 6 bis de #1603): el sin escala que declaró cada línea de un combo
  -- acumulable, como lo publicó combo_fuera_de_regla ({combo: {producto: sin escala}}).
  v_sin      jsonb := COALESCE(NULLIF(current_setting('app.combo_sin_escala', true), '')::jsonb, '{}'::jsonb);
  v_hoy      numeric;
  v_tramos   jsonb;
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
                            jsonb_strip_nulls(jsonb_build_object(
                              'combo', pi.precio_unitario,
                              'sin_combo', pi.precio_sin_combo_unitario,
                              'sin_escala', (v_sin->(pi.combo_id::text)->>(pi.producto_id::text))::numeric))) AS precios
      FROM pedido_items pi
     WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = p_sucursal AND pi.combo_id IS NOT NULL
     GROUP BY pi.combo_id
  LOOP
    -- promos-B5 (tanda 6 bis de #1603), decisiones del dueño del 24/11 y el 25/11: lo que
    -- el pedido conserva queda a su precio (los primeros tramos), lo que se suma va al
    -- precio de hoy del combo, para todo rol (la plata de las líneas del admin no se
    -- valida, como siempre).
    v_hoy := (public._combo_definicion(r.combo_id, p_sucursal)->>'precio')::numeric;
    SELECT fc.componentes, fc.tramos, fc.cantidad_combos, fc.cantidad_combos_armados, fc.precio INTO v_f
      FROM pedido_combos fc
     WHERE fc.pedido_id = p_pedido_id AND fc.combo_id = r.combo_id AND fc.sucursal_id = p_sucursal;
    IF FOUND THEN
      v_def := v_f.componentes;
      v_k := public._combo_cantidad(v_def, r.lineas);
      IF v_k IS NULL THEN
        RAISE EXCEPTION 'Las líneas del combo #% del pedido #% no forman combos enteros', r.combo_id, p_pedido_id;
      END IF;
      v_tramos := public._combo_tramos_para(
                    public._combo_tramos_para(COALESCE(v_f.tramos, jsonb_build_array(jsonb_build_object(
                                                'cantidad', v_f.cantidad_combos_armados, 'precio', v_f.precio))),
                                              v_f.cantidad_combos, NULL),
                    v_k, COALESCE(v_hoy, v_f.precio));
      UPDATE pedido_combos
         SET cantidad_combos = v_k,
             cantidad_combos_armados = v_k,
             armado_at = now(),
             precios = precios || r.precios,
             recargo = 0,
             tramos = v_tramos
       WHERE pedido_id = p_pedido_id AND combo_id = r.combo_id AND sucursal_id = p_sucursal;
    ELSE
      v_def := NULL;
      v_tramos := NULL;
      IF v_original IS NOT NULL THEN
        SELECT jsonb_build_object('nombre', fo.nombre, 'precio', fo.precio,
                                  'combina_escalas', fo.combina_escalas, 'componentes', fo.componentes),
               public._combo_tramos_para(COALESCE(fo.tramos, jsonb_build_array(jsonb_build_object(
                                           'cantidad', fo.cantidad_combos_armados, 'precio', fo.precio))),
                                         fo.cantidad_combos, NULL)
          INTO v_def, v_tramos
          FROM pedido_combos fo
         WHERE fo.pedido_id = v_original AND fo.combo_id = r.combo_id AND fo.sucursal_id = p_sucursal;
      END IF;
      v_def := COALESCE(v_def, public._combo_definicion(r.combo_id, p_sucursal));
      v_k := public._combo_cantidad(v_def->'componentes', r.lineas);
      IF v_k IS NULL THEN
        RAISE EXCEPTION 'Las líneas del combo #% del pedido #% no forman combos enteros', r.combo_id, p_pedido_id;
      END IF;
      v_tramos := public._combo_tramos_para(
                    COALESCE(v_tramos, '[]'::jsonb), v_k,
                    CASE WHEN v_tramos IS NULL THEN (v_def->>'precio')::numeric
                         ELSE COALESCE(v_hoy, (v_def->>'precio')::numeric) END);
      INSERT INTO pedido_combos (pedido_id, combo_id, sucursal_id, cantidad_combos, nombre, precio,
                                 combina_escalas, componentes, cantidad_combos_armados, armado_at, precios,
                                 tramos)
      VALUES (p_pedido_id, r.combo_id, p_sucursal, v_k, v_def->>'nombre', (v_def->>'precio')::numeric,
              (v_def->>'combina_escalas')::boolean, v_def->'componentes', v_k, now(), r.precios,
              v_tramos);
    END IF;
  END LOOP;
  -- Lo publicado vale para este guardado y nada más.
  PERFORM set_config('app.combo_sin_escala', '', true);
END
$function$;

-- =========================================================================
-- Los tramos que se cambian por ancla: la función, el ancla y su reemplazo. Las de
-- esta tarjeta tienen premisa de md5 y su poscondición los vuelve a poner al revés;
-- las dos de la tarjeta H (sin md5) piden que el ancla aparezca una vez.
-- =========================================================================
CREATE TEMP TABLE t6bi_tramos (ord int PRIMARY KEY, fn text, que text, ancla text, nuevo text) ON COMMIT DROP;

INSERT INTO t6bi_tramos VALUES
-- 1 y 4 · regalo_fuera_de_promo
(1, 'public.regalo_fuera_de_promo(jsonb,jsonb,bigint,bigint,date)', 'las declaraciones',
$a$  v_conservado int;
$a$,
$r$  v_conservado int;
  -- N1 (tanda 6 bis de #1603): el regalo de referencia del pedido para la promo.
  v_ref        bigint;
  -- promos-B1 (tanda 6 bis de #1603): el motivo de _regalo_sin_bulto.
  v_sin_bulto  text;
$r$),
(2, 'public.regalo_fuera_de_promo(jsonb,jsonb,bigint,bigint,date)', 'el regalo de referencia',
$a$         AND COALESCE(pi.es_bonificacion, false) AND pi.promocion_id = v_promo.id;
    END IF;
    IF EXISTS (
$a$,
$r$         AND COALESCE(pi.es_bonificacion, false) AND pi.promocion_id = v_promo.id;
    END IF;
    -- N1 (tanda 6 bis de #1603), decisión del dueño: el regalo del pedido es el que la promo
    -- daba cuando nació (_regalo_de_la_promo, promos-B2). La edición que vuelve a él (o a
    -- uno de su rubro) en una promo que el pedido ya tenía entra aunque hoy la promo dé
    -- otro de otro rubro; el de hoy sigue entrando como siempre.
    v_ref := NULL;
    IF v_n_lineas > 0 THEN
      SELECT x.producto_id INTO v_ref
        FROM public._regalo_de_la_promo(p_pedido_id, v_promo.id, p_sucursal, NULL, NULL, NULL) x;
    END IF;
    IF EXISTS (
$r$),
(3, 'public.regalo_fuera_de_promo(jsonb,jsonb,bigint,bigint,date)', 'el regalo de referencia entra',
$a$               OR (p_pedido_id IS NOT NULL AND v_n_lineas = 1
                   AND v_prod_unica = NULLIF(e->>'producto_id', '')::bigint), false)) THEN
$a$,
$r$               OR (p_pedido_id IS NOT NULL AND v_n_lineas = 1
                   AND v_prod_unica = NULLIF(e->>'producto_id', '')::bigint)
               OR (v_ref IS NOT NULL
                   AND (v_ref = NULLIF(e->>'producto_id', '')::bigint
                        OR public.regalo_misma_categoria(v_ref, NULLIF(e->>'producto_id', '')::bigint, p_sucursal))),
               false)) THEN
$r$),
(4, 'public.regalo_fuera_de_promo(jsonb,jsonb,bigint,bigint,date)', 'el bulto del regalo',
$a$  -- 5. Exclusion (#1136): una sola promo con regalo por grupo excluyente.
$a$,
$r$  -- 4b. promos-B1 (tanda 6 bis de #1603): un regalo cuya barra no es la del contenedor de
  --     la promo, sin su bulto (_regalo_sin_bulto). Lo mismo le pide al admin la rama del
  --     admin del alta y de la edición.
  v_sin_bulto := public._regalo_sin_bulto(v_prod, p_sucursal, p_pedido_id);
  IF v_sin_bulto IS NOT NULL THEN
    RETURN v_sin_bulto;
  END IF;

  -- 5. Exclusion (#1136): una sola promo con regalo por grupo excluyente.
$r$),
-- 4 · N2: _regalo_de_la_promo
(5, 'public._regalo_de_la_promo(bigint,bigint,bigint,uuid,bigint,numeric)', 'las declaraciones',
$a$  v_precio  numeric;
BEGIN
$a$,
$r$  v_precio  numeric;
  -- N2 (tanda 6 bis de #1603): el pedido original de un cambio de cliente.
  v_desde   bigint;
  v_previo  bigint;
  v_vueltas int := 0;
  v_alta    timestamptz;
BEGIN
$r$),
(6, 'public._regalo_de_la_promo(bigint,bigint,bigint,uuid,bigint,numeric)', 'el alta del pedido original',
$a$  SELECT pe.created_at INTO v_nacio
    FROM pedidos pe WHERE pe.id = p_pedido_id AND pe.sucursal_id = p_sucursal_id;
$a$,
$r$  SELECT pe.created_at INTO v_nacio
    FROM pedidos pe WHERE pe.id = p_pedido_id AND pe.sucursal_id = p_sucursal_id;
  -- N2 (tanda 6 bis de #1603): el pedido que rehízo un cambio de cliente nace de nuevo,
  -- pero su regalo es el del original: se sigue el pedido_historial que escribe
  -- cambiar_cliente_pedido («(cambio de cliente desde pedido #N)») hasta el primero, y se
  -- mide desde su alta. Un cambio sobre un pedido ya cambiado repite el paso (tope 20).
  v_desde := p_pedido_id;
  WHILE v_nacio IS NOT NULL AND v_vueltas < 20 LOOP
    v_vueltas := v_vueltas + 1;
    SELECT substring(h.valor_nuevo FROM '\(cambio de cliente desde pedido #([0-9]+)\)$')::bigint INTO v_previo
      FROM pedido_historial h
     WHERE h.pedido_id = v_desde AND h.sucursal_id = p_sucursal_id
       AND h.campo_modificado = 'cliente_id'
       AND h.valor_nuevo ~ '\(cambio de cliente desde pedido #[0-9]+\)$'
     ORDER BY h.id
     LIMIT 1;
    EXIT WHEN v_previo IS NULL OR v_previo = v_desde;
    SELECT pe.created_at INTO v_alta
      FROM pedidos pe WHERE pe.id = v_previo AND pe.sucursal_id = p_sucursal_id;
    EXIT WHEN v_alta IS NULL;
    v_nacio := LEAST(v_nacio, v_alta);
    v_desde := v_previo;
    v_previo := NULL;
  END LOOP;
$r$),
-- 2 y 3 · combo_fuera_de_regla
(7, 'public.combo_fuera_de_regla(jsonb,bigint,date,bigint,boolean)', 'las declaraciones',
$a$  v_vendidos bigint;
$a$,
$r$  v_vendidos bigint;
  -- promos-B5 (tanda 6 bis de #1603): los tramos de la foto, y su precios (B4).
  v_tramos   jsonb;
  v_precios  jsonb;
$r$),
(8, 'public.combo_fuera_de_regla(jsonb,bigint,date,bigint,boolean)', 'lo publicado empieza vacío',
$a$BEGIN
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_items) e WHERE NULLIF(e->>'combo_id', '') IS NOT NULL) THEN
$a$,
$r$BEGIN
  -- promos-B4 (tanda 6 bis de #1603): lo que esta validación le publica a
  -- _guardar_combos_pedido arranca vacío.
  PERFORM set_config('app.combo_sin_escala', '', true);
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_items) e WHERE NULLIF(e->>'combo_id', '') IS NOT NULL) THEN
$r$),
(9, 'public.combo_fuera_de_regla(jsonb,bigint,date,bigint,boolean)', 'los tramos de la foto',
$a$    v_def := NULL;
    v_k_foto := NULL;
    IF v_foto_de IS NOT NULL THEN
      SELECT jsonb_build_object('nombre', f.nombre, 'precio', f.precio,
                                'combina_escalas', f.combina_escalas, 'componentes', f.componentes),
             f.cantidad_combos
        INTO v_def, v_k_foto
$a$,
$r$    v_def := NULL;
    v_k_foto := NULL;
    v_tramos := NULL;
    v_precios := NULL;
    IF v_foto_de IS NOT NULL THEN
      -- promos-B5: lo que el pedido conserva, a los precios de sus tramos (los primeros que
      -- entraron, hasta los combos que tiene hoy).
      SELECT jsonb_build_object('nombre', f.nombre, 'precio', f.precio,
                                'combina_escalas', f.combina_escalas, 'componentes', f.componentes),
             f.cantidad_combos,
             public._combo_tramos_para(COALESCE(f.tramos, jsonb_build_array(jsonb_build_object(
                                         'cantidad', f.cantidad_combos_armados, 'precio', f.precio))),
                                       f.cantidad_combos, NULL),
             f.precios
        INTO v_def, v_k_foto, v_tramos, v_precios
$r$),
(10, 'public.combo_fuera_de_regla(jsonb,bigint,date,bigint,boolean)', 'publicar el sin escala',
$a$    CONTINUE WHEN NOT p_validar_politica;
$a$,
$r$    -- promos-B4 (tanda 6 bis de #1603): el sin escala que declara cada línea de un combo
    -- acumulable, para que _guardar_combos_pedido lo guarde en la foto (también el del
    -- admin, que no se valida).
    IF (v_def->>'combina_escalas')::boolean THEN
      PERFORM set_config('app.combo_sin_escala',
        (COALESCE(NULLIF(current_setting('app.combo_sin_escala', true), '')::jsonb, '{}'::jsonb)
         || jsonb_build_object(r.combo_id::text,
              COALESCE((SELECT jsonb_object_agg(x->>'producto_id', (x->>'sin_escala')::numeric)
                          FROM jsonb_array_elements(r.lineas) x
                         WHERE x->>'sin_escala' IS NOT NULL), '{}'::jsonb)))::text,
        true);
    END IF;

    CONTINUE WHEN NOT p_validar_politica;
$r$),
(11, 'public.combo_fuera_de_regla(jsonb,bigint,date,bigint,boolean)', 'la línea sin lista',
$a$        RETURN format('Una línea del combo "%s" viene sin su precio sin escala.', v_nombre);
      END IF;
      v_lineas := r.lineas;
$a$,
$r$        RETURN format('Una línea del combo "%s" viene sin su precio sin escala.', v_nombre);
      END IF;
      -- promos-B4 (tanda 6 bis de #1603): precio_fuera_de_politica no valida una línea sin
      -- precio de lista (la que conserva su precio en la edición, 1559-b3), así que su sin
      -- escala y su sin combo vienen sin control: no puede descontar por escala, por unidad,
      -- más de lo que descontaba en la foto del pedido (0 si la foto no lo tiene).
      IF EXISTS (SELECT 1
                   FROM jsonb_array_elements(r.lineas) x
                   JOIN productos pr ON pr.id = (x->>'producto_id')::bigint AND pr.sucursal_id = p_sucursal
                  WHERE (pr.precio IS NULL OR pr.precio <= 0)
                    AND (x->>'sin_escala')::numeric - (x->>'ref')::numeric
                        > COALESCE((v_precios->(x->>'producto_id')->>'sin_escala')::numeric
                                   - (v_precios->(x->>'producto_id')->>'sin_combo')::numeric, 0) + 0.005) THEN
        RETURN format('Una línea del combo "%s" es de un producto sin precio de lista y descuenta por escala más que en el pedido. Recargá la app y volvé a armar el pedido.', v_nombre);
      END IF;
      v_lineas := r.lineas;
$r$),
(12, 'public.combo_fuera_de_regla(jsonb,bigint,date,bigint,boolean)', 'el total por tramos',
$a$    v_total := public._combo_total((v_def->>'precio')::numeric, v_k, v_lineas);
$a$,
$r$    -- promos-B5 (tanda 6 bis de #1603), decisiones del dueño del 24/11 y el 25/11: con foto,
    -- lo que el pedido conserva vale lo de sus tramos y lo que se suma, el precio de hoy del
    -- combo; un renglón por producto, al precio promedio.
    IF v_tramos IS NOT NULL THEN
      v_tramos := public._combo_tramos_para(v_tramos, v_k,
                    COALESCE((public._combo_definicion(r.combo_id, p_sucursal)->>'precio')::numeric,
                             (v_def->>'precio')::numeric));
    END IF;
    v_total := public._combo_total((v_def->>'precio')::numeric, v_k, v_lineas, v_tramos);
$r$),
-- 1 · promos-B1 para el admin, en las dos RPC de la tarjeta H (sin premisa de md5)
(13, 'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)', 'el bulto del regalo del admin',
$a$  IF v_user_role <> 'admin' AND p_items IS NOT NULL AND jsonb_typeof(p_items) = 'array' THEN
    DECLARE
      v_motivo_regalo TEXT;
$a$,
$r$  -- promos-B1 (tanda 6 bis de #1603): el admin no pasa por regalo_fuera_de_promo, pero el
  -- bulto de un regalo cuya barra no es la del contenedor de la promo es un dato que falta
  -- para contar la barra, no un permiso (el molde de la 544): también se le pide a él.
  IF v_user_role = 'admin' AND p_items IS NOT NULL AND jsonb_typeof(p_items) = 'array' THEN
    DECLARE
      v_sin_bulto TEXT := public._regalo_sin_bulto(p_items, v_sucursal, NULL);
    BEGIN
      IF v_sin_bulto IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
          v_sin_bulto || ' El pedido no se creó.'), 'codigo', 'regalo_fuera_de_promo');
      END IF;
    END;
  END IF;

  IF v_user_role <> 'admin' AND p_items IS NOT NULL AND jsonb_typeof(p_items) = 'array' THEN
    DECLARE
      v_motivo_regalo TEXT;
$r$),
(14, 'public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'el bulto del regalo del admin',
$a$  -- Incluye al encargado. El admin queda exento.
  IF v_user_role <> 'admin' THEN
    DECLARE
      v_motivo_regalo TEXT;
$a$,
$r$  -- Incluye al encargado. El admin queda exento.
  -- promos-B1 (tanda 6 bis de #1603): salvo del bulto de un regalo nuevo cuya barra no es la
  -- del contenedor de la promo, que es un dato y no un permiso (el molde de la 544).
  IF v_user_role = 'admin' THEN
    DECLARE
      v_sin_bulto TEXT := public._regalo_sin_bulto(v_items, v_sucursal, p_pedido_id);
    BEGIN
      IF v_sin_bulto IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
          v_sin_bulto || ' El pedido no se modificó.'));
      END IF;
    END;
  END IF;
  IF v_user_role <> 'admin' THEN
    DECLARE
      v_motivo_regalo TEXT;
$r$);

-- =========================================================================
-- El parche: cada función con sus tramos (su search_path ya termina en pg_temp)
-- =========================================================================
DO $parche$
DECLARE
  f     text;
  v_def text;
  r     record;
  v_n   int;
BEGIN
  FOR f IN SELECT DISTINCT fn FROM t6bi_tramos ORDER BY 1 LOOP
    v_def := pg_get_functiondef(f::regprocedure);
    FOR r IN SELECT * FROM t6bi_tramos WHERE fn = f ORDER BY ord LOOP
      v_n := (length(v_def) - length(replace(v_def, r.ancla, ''))) / length(r.ancla);
      IF v_n <> 1 THEN
        RAISE EXCEPTION 'mig NNN · % (%): el ancla aparece % vez/veces y se esperaba 1', f, r.que, v_n;
      END IF;
      v_def := replace(v_def, r.ancla, r.nuevo);
    END LOOP;
    -- 531 (B15): el CREATE OR REPLACE lleva la cláusula SET; sin ella la borraría.
    IF position(E' SET search_path TO ''public'', ''pg_temp''\n' IN v_def) = 0 THEN
      RAISE EXCEPTION 'mig NNN · %: no encuentro su search_path', f;
    END IF;
    EXECUTE v_def;
  END LOOP;
END
$parche$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos de esta tarjeta son los del repo y no cambiaron fuera de
-- sus tramos (deshaciéndolos vuelve el md5 de la premisa); en las dos de la tarjeta H,
-- el tramo nuevo aparece una vez y el ancla sigue entera adentro. El definer, el
-- search_path y los EXECUTE, los de antes. Lo nuevo, como dice este archivo.
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  v_src text;
  r     record;
  t     record;
  x     record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.regalo_fuera_de_promo(jsonb,jsonb,bigint,bigint,date)',
     '59ed33b778a9fac3e74a80935f6edf5b', '7a5d67c746a4d5bb67b8d313d13584be',
     '{postgres=X/postgres,service_role=X/postgres}', false),
    ('public._regalo_de_la_promo(bigint,bigint,bigint,uuid,bigint,numeric)',
     '3aa97e8704a400fc675ac77ec4073b74', '0ed07e72b5d047e60695d13bfae3d312',
     '{postgres=X/postgres,service_role=X/postgres}', false),
    ('public.combo_fuera_de_regla(jsonb,bigint,date,bigint,boolean)',
     '5d463b7b7766b6e2e5036edafe151f5f', '589942c33c244c752112bf7712d1fe84',
     '{postgres=X/postgres,service_role=X/postgres}', false),
    ('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)',
     NULL, NULL, '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', true),
    ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)',
     NULL, NULL, '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', true)
  ) AS v(fn, h, h_antes, acl, def) LOOP
    SELECT prosrc, md5(prosrc) AS h, proacl::text AS a, prosecdef AS def, proconfig::text AS cfg INTO x
      FROM pg_proc WHERE oid = r.fn::regprocedure;
    IF (r.h IS NOT NULL AND x.h IS DISTINCT FROM r.h) OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def
       OR x.cfg IS DISTINCT FROM '{"search_path=public, pg_temp"}' THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %, config %)', r.fn, x.h, x.a, x.def, x.cfg;
    END IF;
    v_src := x.prosrc;
    FOR t IN SELECT * FROM t6bi_tramos WHERE fn = r.fn ORDER BY ord DESC LOOP
      IF (length(v_src) - length(replace(v_src, t.nuevo, ''))) / length(t.nuevo) <> 1 THEN
        RAISE EXCEPTION 'mig NNN · % (%): el tramo nuevo no aparece una vez', r.fn, t.que;
      END IF;
      v_src := replace(v_src, t.nuevo, t.ancla);
    END LOOP;
    IF r.h_antes IS NOT NULL AND md5(v_src) IS DISTINCT FROM r.h_antes THEN
      RAISE EXCEPTION 'mig NNN · % cambió fuera de sus tramos (md5 sin el parche %)', r.fn, md5(v_src);
    END IF;
  END LOOP;

  FOR r IN SELECT * FROM (VALUES
    ('public._guardar_combos_pedido(bigint,bigint)', 'b08723128ac5eb501e1999a13b0197e3', '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._regalo_sin_bulto(jsonb,bigint,bigint)', 'b1bd188fea2bc5e03b3b8ac68399a73d', '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._combo_tramos_para(jsonb,integer,numeric)', '3747714542581be348cde7a0b2a900a5', '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._combo_tramos_validos(jsonb,integer)', '7747cb9253e7254a52d58dc71a9b2a91', '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._combo_total(numeric,integer,jsonb,jsonb)', '0316ee3480fd7d8a05a624c0ba9d1bd8', '{postgres=X/postgres,service_role=X/postgres}')
  ) AS v(fn, h, acl) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def, proconfig::text AS cfg INTO x
      FROM pg_proc WHERE oid = r.fn::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def
       OR x.cfg IS DISTINCT FROM '{"search_path=public, pg_temp"}' THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %, config %)', r.fn, x.h, x.a, x.def, x.cfg;
    END IF;
  END LOOP;
  IF to_regprocedure('public._combo_total(numeric,integer,jsonb)') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · la firma vieja de _combo_total sigue viva';
  END IF;
  IF (SELECT format_type(atttypid, atttypmod) FROM pg_attribute
       WHERE attrelid = 'public.pedido_combos'::regclass AND attname = 'tramos' AND NOT attisdropped) IS DISTINCT FROM 'jsonb'
     OR (SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c
          WHERE c.conrelid = 'public.pedido_combos'::regclass AND c.conname = 'pedido_combos_tramos_validos')
        IS DISTINCT FROM 'CHECK (_combo_tramos_validos(tramos, cantidad_combos_armados))' THEN
    RAISE EXCEPTION 'mig NNN · la columna tramos o su CHECK no quedaron como en el repo';
  END IF;
END
$post$;

COMMIT;
