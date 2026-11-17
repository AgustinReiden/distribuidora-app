-- =========================================================================
-- NNN · UNA PROMO CON USO NO SE BORRA, EL REPARTO DE UN COMBO NO DEJA UNA
--       LÍNEA EN $0, LOS ESPEJOS DE COMBOS Y LA FOTO DE LA LÍNEA QUE UN COMBO
--       FUSIONA
--       (plan #1603, ola 2, tarjeta B1c: 1556-b1 y 1556-b3 de #1556, 1592-b4
--        de #1592, y lo que dejó la ola 1 sobre `_combo_trasladar`)
--
-- Parcha por ancla cuatro funciones de server (`_combo_prorrateo`,
-- `_combo_cantidad`, `_combo_trasladar` y el mensaje de `combo_fuera_de_regla`),
-- con premisa de md5 sobre el cuerpo vivo del 16/11 (ledger en la 512; los
-- mismos con la 514), y crea una guarda de borrado sobre `promociones`. No
-- cambia tablas ni firmas. Toma el lock de `promociones` al principio (NOWAIT).
-- Ensayo: scripts/test-promos-combos-ola2-1603.sql. Se aplica en LF.
--
-- =========================================================================
-- 1 · 1556-b1 · UNA PROMO CON USO NO SE BORRA
-- =========================================================================
-- Las FKs de `promociones` no son RESTRICT: `pedido_items.promocion_id` y
-- `salvedades_items.promocion_id` son SET NULL y `promo_ajustes`,
-- `pedido_promo_reglas` y `promo_acumuladores` son CASCADE. Un admin que borra
-- por REST una promo con un pedido abierto le deja el regalo sin promo, se
-- pierde la foto del modo (`pedido_promo_reglas`) y al cancelar el regalo no
-- vuelve al stock. Hasta ahora lo frenaba sólo el front
-- (`src/utils/promocionesEliminacion.ts`).
-- Decisión del dueño (D1 del plan #1603, en #1556): no se puede borrar una promo
-- con regalos en pedidos abiertos; se rechaza y se ofrece desactivarla.
-- `trg_promocion_no_se_borra_con_uso` (BEFORE DELETE) dice lo mismo que el
-- front, que ya ofrecía desactivar con cualquier uso: rechaza si la promo tiene
-- líneas de pedido (de cualquier estado: un pedido entregado o cancelado
-- también pierde con qué promo se vendió), ajustes de stock o salvedades (una
-- salvedad sobre el regalo lo borró de `pedido_items`, y anularla lo repone con
-- la promo de la salvedad). El front suma las salvedades a su cuenta. Cubre el
-- REST, el panel y cualquier camino de server; el admin no está exento.
--
-- =========================================================================
-- 2 · 1592-b4 · EL REPARTO DE UN COMBO NO DEJA UNA LÍNEA EN $0
-- =========================================================================
-- `_combo_prorrateo` redondea T·c/R: con una referencia de centavos y el combo
-- muy rebajado le daba 0 a esa línea (Fernet $10.000 + caramelo $0,01 en un
-- combo de $4.000: $4.000 + $0, el caramelo gratis), y los ajustes del resto
-- podían dejarla negativa. Ahora queda $3.999,99 + $0,01: si el reparto de
-- siempre deja alguna línea por debajo de un centavo, cada unidad toma un
-- centavo y lo que queda del total (T − Σ q) se reparte con la misma regla,
-- sin bajar ninguna línea de 0: el resto va a la más cara que lo divide sin quedar negativa, y en el reparto de
-- #1259 cada una toma el precio más cercano a su proporción entre 0 y lo que
-- todavía falta repartir. Si ni así hay reparto (un combo de centavos que no
-- alcanza para un centavo por unidad), NULL, como un total que no se puede
-- repartir: `combo_fuera_de_regla` lo rechaza y el front no lo arma. El
-- rechazo dice que el combo no se puede repartir a ese precio, no «recargá la
-- app» (H3 de la revisión): recargar no lo arregla.
-- Cuando ninguna línea queda en 0 el reparto es el de siempre (lo prueba el
-- ensayo contra una copia del cuerpo anterior), así que un pedido ya armado se
-- valida igual. El espejo es `prorratearTotal` (src/utils/combos.ts), con los
-- casos nuevos en src/utils/combos.espejo.json y su gate
-- (scripts/espejo-combos.mjs).
--
-- =========================================================================
-- 3 · 1556-b3 · LOS ESPEJOS DE COMBOS Y DEL REGALO
-- =========================================================================
-- `_combo_cantidad` rechazaba una cantidad escrita `1.0` (la expresión regular
-- pedía dígitos), y `cantidadDeCombos` la acepta: un número entero es entero
-- aunque traiga `.0`. Ahora el SQL también. La otra diferencia
-- (`cantidad_sustituta` nula en `cantidadTrasEslabon`) era del lado del TS y se
-- arregla allá. Ninguna llega con datos reales.
--
-- =========================================================================
-- 4 · LA LÍNEA QUE UN COMBO FUSIONA GUARDA SU FOTO
-- =========================================================================
-- `_combo_trasladar` mueve unidades entre las dos líneas del pozo de un combo
-- (la del combo y la que salió de él) y, si las mueve todas, borra la de
-- origen. Una salvedad anterior sobre esa línea se queda sin línea (la FK le
-- pone `pedido_item_id` en NULL) y sin foto, y anularla la recreaba con el
-- costo de hoy y sin la lista, el origen ni el descuento de la venta. La regla
-- de VTA-1 (#1595): un camino que borra la línea de una salvedad guarda la foto.
-- Ahora `_combo_trasladar` la guarda antes del DELETE, con lo mismo que
-- `registrar_salvedad`.
--
-- Revertir: volver los cuatro cuerpos a los de la premisa, y borrar el trigger y
-- su función.
-- =========================================================================

BEGIN;

-- La única tabla con DDL (el CREATE TRIGGER): su lock primero, sin esperar.
LOCK TABLE public.promociones IN SHARE ROW EXCLUSIVE MODE NOWAIT;

SET LOCAL lock_timeout = '5s';

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos del 16/11 (ledger en la 512)
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public._combo_prorrateo(numeric,jsonb)', '3eff1124bef26ea2735c8019cdb6e68e'),
    ('public._combo_cantidad(jsonb,jsonb)', '843fb0cba28e984da189e862d2e27135'),
    ('public._combo_trasladar(bigint,bigint,integer)', '032d7bd15efbe15c5d71b68f17aa089a'),
    ('public.combo_fuera_de_regla(jsonb,bigint,date,bigint,boolean)', '912892a3f0b92ef5e59e2208d8124312')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;
  IF to_regproc('public.promocion_no_se_borra_con_uso') IS NOT NULL
     OR EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.promociones'::regclass
                 AND tgname = 'trg_promocion_no_se_borra_con_uso') THEN
    RAISE EXCEPTION 'mig NNN · la guarda de borrado de promociones ya existe: revisar a mano';
  END IF;
  IF to_regclass('public.salvedad_linea_foto') IS NULL THEN
    RAISE EXCEPTION 'mig NNN · falta salvedad_linea_foto (VTA-1, #1595)';
  END IF;
END
$premisas$;

-- Reemplaza las apariciones de un ancla en una definición; tienen que ser
-- exactamente p_veces.
CREATE FUNCTION pg_temp.parche(p_def text, p_ancla text, p_nuevo text, p_que text, p_veces int DEFAULT 1)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v_n int := (length(p_def) - length(replace(p_def, p_ancla, ''))) / length(p_ancla);
BEGIN
  IF v_n <> p_veces THEN
    RAISE EXCEPTION 'mig NNN · %: el ancla aparece % vez/veces y se esperaba %', p_que, v_n, p_veces;
  END IF;
  RETURN replace(p_def, p_ancla, p_nuevo);
END
$f$;

-- El tramo de una definición que va desde `p_desde` (incluido) hasta `p_hasta`
-- (excluido). Las dos marcas aparecen una sola vez, en ese orden.
CREATE FUNCTION pg_temp.tramo(p_def text, p_desde text, p_hasta text, p_que text)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v_i int := position(p_desde in p_def);
  v_j int := position(p_hasta in p_def);
BEGIN
  IF (length(p_def) - length(replace(p_def, p_desde, ''))) / length(p_desde) <> 1
     OR (length(p_def) - length(replace(p_def, p_hasta, ''))) / length(p_hasta) <> 1
     OR v_j <= v_i THEN
    RAISE EXCEPTION 'mig NNN · %: las marcas del tramo no aparecen una vez cada una y en orden', p_que;
  END IF;
  RETURN substr(p_def, v_i, v_j - v_i);
END
$f$;

-- =========================================================================
-- 1592-b4 · `_combo_prorrateo`: ninguna línea en $0
-- =========================================================================
DO $prorrateo$
DECLARE
  v_def    text := pg_get_functiondef('public._combo_prorrateo(numeric,jsonb)'::regprocedure);
  v_viejo  text;
  v_nuevo  text;
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  v_falta numeric;
BEGIN
$a$,
$r$  v_falta numeric;
  v_pase  integer;
  v_piso  numeric := 0;
  v_tope  numeric;
BEGIN
$r$, '_combo_prorrateo (variables)');

  -- El reparto de siempre, de punta a punta: va adentro de los dos pasos.
  v_viejo := pg_temp.tramo(v_def,
$a$  v_u := array_fill(0::numeric, ARRAY[n]);
$a$,
$a$
  RETURN (SELECT jsonb_object_agg(v_ids[s.i]::text, round(v_u[s.i] / 100, 2))$a$,
    '_combo_prorrateo (el reparto)');
  v_nuevo := pg_temp.parche(v_viejo,
$a$  v_u := array_fill(0::numeric, ARRAY[n]);
$a$,
$r$  v_u := array_fill(0::numeric, ARRAY[n]);
  v_suma := 0;
$r$, '_combo_prorrateo (la suma de cada paso)');
  -- En el segundo paso el resto no deja negativa a la línea que lo absorbe.
  v_nuevo := pg_temp.parche(v_nuevo,
$a$     WHERE mod(v_resto, v_q[s.i]) = 0
$a$,
$r$     WHERE mod(v_resto, v_q[s.i]) = 0
       AND (v_pase = 1 OR v_u[s.i] + div(v_resto, v_q[s.i]) >= 0)
$r$, '_combo_prorrateo (la que absorbe el resto)');
  -- En el segundo paso, entre 0 y lo que falta repartir: lo que pasa del tope
  -- baja al mayor precio que deja el resto divisible (v_x - v_y es el paso).
  v_nuevo := pg_temp.parche(v_nuevo,
$a$        IF abs(v_y * v_r - v_t * v_c[i]) < abs(v_x * v_r - v_t * v_c[i]) THEN
          v_x := v_y;
        END IF;
$a$,
$r$        IF v_pase = 2 THEN
          v_tope := div(v_falta, v_q[i]);
          IF v_x > v_tope THEN
            v_x := v_x - div(v_x - v_tope + (v_x - v_y) - 1, v_x - v_y) * (v_x - v_y);
          ELSIF v_y >= 0 AND abs(v_y * v_r - v_t * v_c[i]) < abs(v_x * v_r - v_t * v_c[i]) THEN
            v_x := v_y;
          END IF;
          IF v_x < 0 THEN
            RETURN NULL;
          END IF;
        ELSIF abs(v_y * v_r - v_t * v_c[i]) < abs(v_x * v_r - v_t * v_c[i]) THEN
          v_x := v_y;
        END IF;
$r$, '_combo_prorrateo (el reparto de #1259)');
  -- Un nivel más de sangría: va adentro del FOR.
  v_nuevo := rtrim(v_nuevo, E'\n');
  v_nuevo := '  ' || replace(v_nuevo, E'\n', E'\n  ');
  v_nuevo := replace(v_nuevo, E'\n  \n', E'\n\n');

  v_def := pg_temp.parche(v_def, v_viejo,
$r$  -- 1592-b4 (#1592): ninguna linea en $0. Si el reparto de siempre deja
  -- alguna por debajo de un centavo (una referencia de centavos en un combo
  -- muy rebajado), cada unidad toma un centavo y lo que queda del total se
  -- reparte con la misma regla, sin bajar ninguna de 0. Si ninguna queda en 0,
  -- el reparto es el de siempre. Espejo: prorratearTotal (src/utils/combos.ts).
  FOR v_pase IN 1..2 LOOP
$r$ || v_nuevo || $r$
    EXIT WHEN v_pase = 2 OR NOT EXISTS (SELECT 1 FROM unnest(v_u) AS x WHERE x < 1);
    v_piso := (SELECT sum(x) FROM unnest(v_q) AS x);
    IF v_t < v_piso THEN
      RETURN NULL;
    END IF;
    v_t := v_t - v_piso;
  END LOOP;
  IF v_piso > 0 THEN
    IF EXISTS (SELECT 1 FROM unnest(v_u) AS x WHERE x < 0) THEN
      RETURN NULL;
    END IF;
    FOR i IN 1..n LOOP
      v_u[i] := v_u[i] + 1;
    END LOOP;
  END IF;
$r$, '_combo_prorrateo (los dos pasos)');
  EXECUTE v_def;
END
$prorrateo$;

-- =========================================================================
-- 1556-b3 · `_combo_cantidad`: una cantidad `1.0` es entera
-- =========================================================================
DO $cantidad$
DECLARE
  v_def text := pg_get_functiondef('public._combo_cantidad(jsonb,jsonb)'::regprocedure);
BEGIN
  -- Las dos: la de los lugares del combo y la de las líneas.
  v_def := pg_temp.parche(v_def,
    $a$!~ '^[0-9]{1,9}$'$a$,
    $r$!~ '^[0-9]{1,9}(\.0+)?$'$r$,
    '_combo_cantidad (enteros con .0)', 2);
  EXECUTE v_def;
END
$cantidad$;

-- =========================================================================
-- `_combo_trasladar`: la línea que se fusiona guarda su foto (VTA-1)
-- =========================================================================
DO $trasladar$
DECLARE
  v_def text := pg_get_functiondef('public._combo_trasladar(bigint,bigint,integer)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  IF p_cantidad = v_cant THEN
    DELETE FROM pedido_items WHERE id = p_desde;
$a$,
$r$  IF p_cantidad = v_cant THEN
    -- VTA-1 (#1595): la foto de la linea para toda salvedad que apunta a ella,
    -- como en registrar_salvedad: el DELETE les pone pedido_item_id en NULL y
    -- anular_salvedad la recrea con el costo, la lista, el origen, el descuento,
    -- la escala y el factor de bloque de la venta, no los de hoy. COSTO-D: copia
    -- el costo tal cual a la foto; quien lo vuelve a escribir lo pasa por
    -- costo_valuacion.
    INSERT INTO salvedad_linea_foto (salvedad_id, sucursal_id, pedido_item_id, costo_unitario_al_crear,
                                     precio_lista_al_crear, origen_precio, descuento_pct,
                                     grupo_precio_escala_id, unidades_por_bloque_al_crear,
                                     origen_unidades_por_bloque)
    SELECT s.id, s.sucursal_id, pi.id, pi.costo_unitario_al_crear,
           pi.precio_lista_al_crear, pi.origen_precio, pi.descuento_pct,
           pi.grupo_precio_escala_id, pi.unidades_por_bloque_al_crear, pi.origen_unidades_por_bloque
      FROM salvedades_items s
      JOIN pedido_items pi ON pi.id = s.pedido_item_id AND pi.sucursal_id = s.sucursal_id
     WHERE s.pedido_item_id = p_desde
     ORDER BY s.id
    ON CONFLICT (salvedad_id) DO NOTHING;
    DELETE FROM pedido_items WHERE id = p_desde;
$r$, '_combo_trasladar (la foto antes del DELETE)');
  EXECUTE v_def;
END
$trasladar$;

-- =========================================================================
-- H3 de la revisión · `combo_fuera_de_regla`: el combo sin reparto lo dice
-- =========================================================================
DO $mensaje$
DECLARE
  v_def text := pg_get_functiondef('public.combo_fuera_de_regla(jsonb,bigint,date,bigint,boolean)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$    v_prorr := public._combo_prorrateo(v_total, v_lineas);
    IF v_prorr IS NULL
$a$,
$r$    v_prorr := public._combo_prorrateo(v_total, v_lineas);
    -- 1592-b4 (H3 de la revisión): sin reparto (no deja un centavo en cada
    -- línea), el combo no se vende a ese precio. Recargar la app no lo arregla.
    IF v_prorr IS NULL THEN
      RETURN format('El combo "%s" no se puede repartir entre sus productos a ese precio. Cargá los productos sin el combo.', v_nombre);
    END IF;
    IF v_prorr IS NULL
$r$, 'combo_fuera_de_regla (el mensaje sin reparto)');
  EXECUTE v_def;
END
$mensaje$;


-- =========================================================================
-- 1556-b1 · la guarda de borrado de promociones
-- =========================================================================
CREATE FUNCTION public.promocion_no_se_borra_con_uso()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_pedidos     int;
  v_ajustes     int;
  v_salvedades  int;
  v_que         text[] := '{}';
BEGIN
  -- 1556-b1 (#1556): las FKs de promociones no son RESTRICT. Borrar una promo con
  -- uso le deja el regalo de un pedido sin promo (SET NULL), se lleva la foto del
  -- modo y los ajustes (CASCADE), y al cancelar el regalo no vuelve al stock.
  -- Decisión del dueño (D1 del plan #1603): no se puede; se desactiva. La misma
  -- regla que el front (src/utils/promocionesEliminacion.ts): líneas de pedido de
  -- cualquier estado, ajustes de stock o salvedades. SECURITY DEFINER: cuenta lo
  -- que hay, no lo que la RLS deja ver al que borra.
  SELECT count(DISTINCT pi.pedido_id) INTO v_pedidos
    FROM pedido_items pi
   WHERE pi.promocion_id = OLD.id AND pi.sucursal_id = OLD.sucursal_id;
  SELECT count(*) INTO v_ajustes
    FROM promo_ajustes pa
   WHERE pa.promocion_id = OLD.id AND pa.sucursal_id = OLD.sucursal_id;
  SELECT count(*) INTO v_salvedades
    FROM salvedades_items si
   WHERE si.promocion_id = OLD.id AND si.sucursal_id = OLD.sucursal_id;
  IF v_pedidos > 0 THEN
    v_que := v_que || format('%s %s', v_pedidos, CASE WHEN v_pedidos = 1 THEN 'pedido' ELSE 'pedidos' END);
  END IF;
  IF v_ajustes > 0 THEN
    v_que := v_que || format('%s %s de stock', v_ajustes, CASE WHEN v_ajustes = 1 THEN 'ajuste' ELSE 'ajustes' END);
  END IF;
  IF v_salvedades > 0 THEN
    v_que := v_que || format('%s %s', v_salvedades, CASE WHEN v_salvedades = 1 THEN 'salvedad' ELSE 'salvedades' END);
  END IF;
  IF cardinality(v_que) > 0 THEN
    RAISE EXCEPTION 'No se puede eliminar la promoción «%»: la usan %. Desactivala: deja de aplicarse a pedidos nuevos y el historial queda intacto.',
      OLD.nombre, array_to_string(v_que, ', ');
  END IF;
  RETURN OLD;
END
$function$;

REVOKE ALL ON FUNCTION public.promocion_no_se_borra_con_uso() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.promocion_no_se_borra_con_uso() TO service_role;

CREATE TRIGGER trg_promocion_no_se_borra_con_uso
  BEFORE DELETE ON public.promociones
  FOR EACH ROW
  EXECUTE FUNCTION public.promocion_no_se_borra_con_uso();

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, el definer y los EXECUTE quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public._combo_prorrateo(numeric,jsonb)', '2ccf3e9a95d2e7aec8d265f0956a61d5', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._combo_cantidad(jsonb,jsonb)', '63f1e91870100ee1b90cec6c7f0773a6', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._combo_trasladar(bigint,bigint,integer)', '5cacddb5d177dc18d4d79c16d2f42af0', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.combo_fuera_de_regla(jsonb,bigint,date,bigint,boolean)', '589942c33c244c752112bf7712d1fe84', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.promocion_no_se_borra_con_uso()', '0b9b4e8c7575194d141c17dc79383f54', true,
     '{postgres=X/postgres,service_role=X/postgres}')
  ) AS t(f, h, def, acl) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO x
      FROM pg_proc WHERE oid = r.f::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %)', r.f, x.h, x.a, x.def;
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.promociones'::regclass
                  AND tgname = 'trg_promocion_no_se_borra_con_uso' AND tgenabled = 'O') THEN
    RAISE EXCEPTION 'mig NNN · falta el trigger de borrado de promociones';
  END IF;
END
$post$;

COMMIT;
