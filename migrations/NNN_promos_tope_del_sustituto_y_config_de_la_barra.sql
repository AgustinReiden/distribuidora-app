-- =========================================================================
-- NNN · PROMOS Y REGALOS: EL TOPE DEL SUSTITUTO DE UN REGALO, LA BARRA NO
--       CAMBIA DE CONFIGURACIÓN MIENTRAS UN PEDIDO LA PUEDE DESHACER Y EL
--       BLOQUE DE UN CAMBIO DE FACTOR ANOTA SU LOTE
--       (reauditoría del núcleo del 15/11, #1592: PRM-1, PRM-2, PRM-3,
--        1592-b2, 1592-b3; de las mismas funciones 1556-b2, 1556-c2; y la
--        revisión adversarial de la tarjeta, H1 a H6)
--
-- Parcha por ancla cinco funciones (`sustituir_regalo_pedido`,
-- `dividir_regalo_pedido`, `actualizar_pedido_items`,
-- `aplicar_uso_promo_acumulador` y `renormalizar_bloques_por_cambio_factor`),
-- con premisa de md5 sobre el cuerpo vivo del 16/11 (ledger en la 508); crea
-- la regla pura del tope con espejo, cinco funciones de server y una guarda
-- sobre `promociones`; y una RPC que le da el corte de una línea a la pantalla
-- de cambio de regalo. No cambia tablas ni firmas.
-- Ensayo: scripts/test-promos-regalos-1592.sql. Se aplica en LF.
--
-- =========================================================================
-- 1 · PRM-1 · EL TOPE DEL SUSTITUTO DE UN REGALO
-- =========================================================================
-- `sustituir_regalo_pedido` sólo pedía una cantidad entera, mayor que 0 y con
-- stock: el encargado cambiaba R×4 por R×40 (el mismo producto) o por S×40, y
-- la edición escalaba después la razón del eslabón (V×20 → S×80).
-- Decisión del dueño (16/11, en #1592): para quien no es admin, el sustituto
-- entra si (a) es del mismo rubro que el regalo, con igual o menor cantidad (un
-- cambio de sabor, aunque sea algo más caro), o (b) vale igual o menos que el
-- regalo, a precio de lista. Siempre contra el regalo que da la promo (su
-- producto y la cantidad del corte), no contra el producto con el que se cargó
-- la línea ni contra la línea de hoy. Vale igual para el reparto, sobre la suma
-- de las partes. El admin sigue sin tope.
--   · La regla, pura y con espejo: `regalo_tope_sustituto` = lo que sea más
--     entre el corte (si es del mismo rubro) y floor(corte × precio por unidad
--     del regalo / precio por unidad del sustituto). El precio por unidad de la
--     línea es precio / factor de su barra en fracción, precio en modo A. Sin
--     precio, sólo cuenta el rubro. El espejo es `topeSustitutoRegalo`
--     (src/utils/regaloOtroEmpaque.ts), con los casos de
--     src/utils/topeSustituto.espejo.json y su gate
--     (scripts/espejo-tope-sustituto.mjs, en integridad.yml).
--   · El regalo de la promo es `producto_regalo_id`, o su contenedor, como en
--     `regalo_fuera_de_promo` (`_regalo_de_la_promo`). Una promo que no lo
--     nombra regala uno de sus productos: ahí la referencia es la raíz de la
--     cadena de la línea, la de antes del reparto en una parte.
--   · `sustituir_regalo_pedido`: el tope con el corte de la línea
--     (`_regalo_tope_de_linea`). Contra el regalo de la promo, ni sustituir dos
--     veces, ni cargar o editar otro sabor (H2), ni repartir y sustituir una
--     parte (H1) suben el techo.
--   · `dividir_regalo_pedido` (H1): todas las partes del mismo rubro que el
--     regalo y la suma hasta el corte, o la suma de lo que valen hasta lo que
--     vale el regalo con el corte (`_regalo_reparto_dentro_del_tope`).
--   · `actualizar_pedido_items`: un regalo que la cadena de su línea convierte
--     no pasa el tope contra el regalo de la promo con el corte que trae el
--     JSON (el que se le sella), más una unidad por eslabón por el redondeo de
--     las conversiones, salvo que no crezca más allá de lo que el último
--     eslabón dejó (`_regalo_tope_de_cadena`). Así una cadena escalada entre
--     dos eslabones crece en proporción (H3), y la que un admin armó por
--     encima (R×4 → R×40) se conserva pero no crece con la edición de otro.
--   · La pantalla (H4) sugiere la cantidad por valor con la misma cuenta, contra
--     el regalo de la promo y el corte de la línea, y no deja confirmar por
--     encima del tope a quien no es admin. El corte de la línea se lo da
--     `regalo_corte_de_linea` (admin y encargado, sucursal activa): la columna
--     sigue siendo de server. Si la RPC falla, la pantalla usa la cantidad de
--     la línea.
-- 1556-b2: el stock del sustituto se compara neto de lo que la línea ya tiene
-- del mismo producto (R×4 por R×4 con stock 0 daba «Stock insuficiente»).
-- 1556-c2: `sustituir_regalo_pedido` y `dividir_regalo_pedido` leían el modo
-- de la promo y la marca de la barra sin tomarla. Ahora la toman FOR UPDATE
-- después de los productos (el orden de la venta y de la edición, #1460) y
-- recién ahí leen el modo, la marca y el factor.
--
-- =========================================================================
-- 2 · PRM-2 · LA BARRA NO CAMBIA DE CONFIGURACIÓN MIENTRAS LA PUEDEN DESHACER
-- =========================================================================
-- `aplicar_uso_promo_acumulador` deshace los bloques con el factor, el stock
-- por bloque y el contenedor de hoy: cambiarlos con pedidos que ya entraron en
-- la barra dejaba el contenedor descuadrado al cancelarlos (6 → 4 con dos
-- pedidos R×4: 51 en vez de 50; contenedor C1 → C2: C1 49 y C2 51).
-- Decisión del dueño (D2 del plan #1603): no se puede, igual que con las
-- unidades por bulto de un producto (`validar_cambio_unidades_por_bulto`).
-- `trg_promo_config_barra_con_pedidos` (BEFORE UPDATE de promociones) rechaza
-- el cambio de `unidades_por_bloque`, `stock_por_bloque`, `ajuste_producto_id`
-- o `ajuste_automatico` de una promo de fracción (antes o después del cambio)
-- mientras haya pedidos que todavía pueden deshacer algo de la barra, y dice
-- cuántos son y cuáles:
--   · sin cancelar, y si están entregados, de un día con la caja abierta: la
--     salvedad del regalo pasa por la barra igual que la cancelación, y la caja
--     cerrada la rechaza (H6, `_pedido_en_caja_cerrada`);
--   · con un regalo que entró en la barra (foto de fracción, sin la marca de un
--     tramo anterior);
--   · en una barra que el cambio toca: todas si aparece o desaparece la barra
--     (el ajuste automático, un factor vacío); las que cuentan con el factor de
--     la promo si cambia el factor (un contenedor con su bulto cuenta con ése);
--     la del regalo de la promo si cambia el contenedor.
-- El cambio de regalo que trae su contenedor cuando el contenedor era el mismo
-- regalo (lo que arma el formulario de fracción) entra (H5): lo cubre
-- `trg_promo_rotar_barra_default`, que muda la barra vieja con su contenedor; si
-- estaba en 0, la primera vuelta crea la fila con el producto de la línea, que
-- es ese contenedor. Con otro contenedor, o si el regalo nuevo ya tiene una
-- barra con otro contenedor, sigue trabado. Cambiar el tipo de la promo sigue
-- permitido (#1324, decisión del dueño): la barra se reinicia y esos pedidos no
-- entran en la nueva. Cubre la RPC, el UPDATE REST del admin y el borrado del
-- contenedor (la FK pone `ajuste_producto_id` en NULL; el mensaje lo dice).
-- `cambiar_regalo_promocion` ya devuelve el rechazo de un trigger como texto
-- («No se guardó ningún cambio de la promoción»): el front lo muestra.
-- Por qué una guarda y no deshacer cada bloque con la configuración con la que
-- se armó: los bloques de la barra no se anotan por pedido ni guardan si
-- siguen pendientes (los de antes de esta migración no tienen el dato), y esa
-- cuenta la comparten el alta, la edición, la cancelación, la salvedad, la
-- anulación, la sustitución, el reparto y el cambio de cliente. Rehacerla es un
-- cambio de fondo de la barra, con migración de datos, y queda propuesto aparte.
--
-- =========================================================================
-- 3 · PRM-3 · EL BLOQUE DE UN CAMBIO DE FACTOR ANOTA SU LOTE
-- =========================================================================
-- `renormalizar_bloques_por_cambio_factor` bajaba el contenedor sin
-- `promo_ajustes.lotes_pendientes`: deshacer ese bloque mandaba el fardo a la
-- bolsa aunque hubiera salido de un lote (lote 49, bolsa 1). Ahora hace lo que
-- la 492 (STK-19) le hizo a `aplicar_uso_promo_acumulador`: la foto de los
-- lotes antes de bajar (`_mov_lotes_foto` y `_mov_lotes_diff`) y lo que vino de
-- la bolsa primero. Y guarda y restaura los cinco GUC de stock alrededor del
-- UPDATE: quedaban puestos en 'auto_ajuste_promo'.
--
-- =========================================================================
-- 4 · LOS BAJOS DE LA BARRA
-- =========================================================================
-- 1592-b2: una promo que mueve stock con ajuste automático y factor
-- descontaba dos veces: el regalo por línea y un fardo del contenedor. Una
-- promo que mueve stock no tiene barra (lo dice el comentario de la 294): en
-- `aplicar_uso_promo_acumulador` va por el contador, y la renormalización no
-- le cierra bloques. Por la misma regla, tampoco a una sin ajuste automático,
-- cuyo `usos_pendientes` es un contador: renormalizarlo le bajaba el
-- contenedor. Latente: el modal no arma esas promos y en prod hay 0.
-- 1592-b3: en una promo que mueve stock el contador va en la unidad de la
-- línea (el alta suma la línea, la cancelación resta la que quedó), y un
-- cambio por valor (R×10 → W×1) lo dejaba corrido en 9. Ahora la sustitución
-- le pasa la diferencia, como en una de fracción.
--
-- No hacía falta: 1558-c1. Los bloques de una promo se deshacen del último al
-- primero entre todos sus pedidos porque son de la barra, no de un pedido: un
-- bloque lo cierran unidades de varios pedidos, y no hay un «bloque de este
-- pedido» que devolver. El último fardo que salió es el primero que vuelve, a
-- donde salió; el total y el estado final cierran.
--
-- Revertir: volver los cinco cuerpos a los de la premisa, y borrar el trigger y
-- las ocho funciones nuevas.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos del 16/11 (ledger en la 508)
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)', 'd7af267910f5372e13434c80ee98c4b7'),
    ('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)', '0c574aefbe8d6e9d97fba2c553adc2d0'),
    ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'c15aa49005a602eb48b7d527e698b748'),
    ('public.aplicar_uso_promo_acumulador(bigint,bigint,numeric,bigint,bigint,uuid,text)', 'd74e85aee404b38040059b67125e3175'),
    ('public.renormalizar_bloques_por_cambio_factor()', '0f5c089fdcd140cc865b0255d4183c13'),
    -- No cambian, pero las reglas nuevas cuentan con ellas como están.
    ('public._regalo_barra_vale(bigint,bigint,bigint)', 'f4ff91437fd7892000d71732f57daa13'),
    ('public._regalo_modo_del_pedido(bigint,bigint,bigint)', 'a6b34b20f9cb25e88c1c78746309da41'),
    ('public.regalo_eslabones(bigint,bigint,bigint)', '437bf430517266331c4f55102811014b'),
    ('public.regalo_cadena_pasos(jsonb,bigint,uuid)', '23579072c1119564dae9f707e19aad2d'),
    ('public.regalo_cantidad_tras_eslabon(numeric,numeric,numeric)', '1826a6f11303c96169a2cd474cbef80d'),
    ('public.regalo_cantidad_base(jsonb,uuid,numeric)', 'b96572441e6d515530b94009db07c286'),
    ('public.factor_regalo_de_linea(bigint,bigint,bigint,bigint)', '6a31fcd62141e3bd89fedd3f573e158c'),
    ('public._mov_lotes_foto(bigint,bigint)', '6ca074b808d19facff8d224da4a97a5a'),
    ('public._mov_lotes_diff(bigint,bigint,jsonb,integer)', '087b6a5e247316cfb1128d15d5294f10'),
    ('public.regalo_misma_categoria(bigint,bigint,bigint)', '51ab00f0009593778561bdd391ed3e04'),
    ('public.contenedor_de_barra(bigint,bigint,bigint,bigint)', '3d3329ccb9051216c257924941cf783f'),
    ('public._pedido_en_caja_cerrada(bigint,bigint)', 'f8e28e851890364cacc15526cc1f05ba'),
    -- H5: la excepción del cambio de regalo cuenta con la rotación como está.
    ('public.rotar_barra_default_de_promo()', 'b44fa3a31c94f3a2387d3319bb1dde2f')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;
  IF to_regproc('public._regalo_raiz_de_linea') IS NOT NULL
     OR to_regproc('public.regalo_tope_sustituto') IS NOT NULL
     OR to_regproc('public._regalo_de_la_promo') IS NOT NULL
     OR to_regproc('public._regalo_tope_de_linea') IS NOT NULL
     OR to_regproc('public._regalo_reparto_dentro_del_tope') IS NOT NULL
     OR to_regproc('public._regalo_tope_de_cadena') IS NOT NULL
     OR to_regproc('public.regalo_corte_de_linea') IS NOT NULL
     OR to_regproc('public.promo_config_barra_con_pedidos') IS NOT NULL
     OR EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.promociones'::regclass
                 AND tgname = 'trg_promo_config_barra_con_pedidos') THEN
    RAISE EXCEPTION 'mig NNN · una función o el trigger nuevos ya existen: revisar a mano';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.promo_ajustes'::regclass
                    AND attname = 'lotes_pendientes' AND NOT attisdropped)
     OR NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.pedido_items'::regclass
                    AND attname = 'regalo_corte' AND NOT attisdropped) THEN
    RAISE EXCEPTION 'mig NNN · faltan promo_ajustes.lotes_pendientes (492) o pedido_items.regalo_corte (500)';
  END IF;
END
$premisas$;

-- Reemplaza una sola aparición de un ancla en una definición.
CREATE FUNCTION pg_temp.parche(p_def text, p_ancla text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v_n int := (length(p_def) - length(replace(p_def, p_ancla, ''))) / length(p_ancla);
BEGIN
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · %: el ancla aparece % vez/veces y se esperaba 1', p_que, v_n;
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
-- Las cuentas del tope (PRM-1)
-- =========================================================================

-- La regla, pura (decisión del dueño del 16/11, en #1592). Hasta cuántas
-- unidades de un sustituto puede poner quien no es admin en lugar del regalo
-- que da la promo, con su corte: todo el corte si es del mismo rubro (un cambio
-- de sabor, aunque sea algo más caro), o lo que no valga más, a precio de lista
-- por unidad de la línea (precio / factor de su barra), redondeado para abajo.
-- Lo que sea más. Sin precio en uno de los dos, sólo cuenta el rubro. Tiene
-- espejo con gate: topeSustitutoRegalo (src/utils/regaloOtroEmpaque.ts), con
-- los casos de src/utils/topeSustituto.espejo.json.
CREATE FUNCTION public.regalo_tope_sustituto(p_corte numeric, p_precio_regalo numeric, p_factor_regalo numeric,
                                             p_precio_sustituto numeric, p_factor_sustituto numeric,
                                             p_mismo_rubro boolean)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public'
AS $function$
  SELECT CASE
           WHEN p_corte IS NULL OR p_corte <= 0 THEN 0
           ELSE GREATEST(
                  CASE WHEN p_mismo_rubro IS TRUE THEN p_corte ELSE 0 END,
                  CASE WHEN COALESCE(p_precio_regalo, 0) <= 0 OR COALESCE(p_precio_sustituto, 0) <= 0 THEN 0
                       -- corte × (precio_regalo / f_regalo) / (precio_sust / f_sust), sin dividir dos veces
                       ELSE floor(p_corte * p_precio_regalo * GREATEST(COALESCE(p_factor_sustituto, 1), 1)
                                  / (GREATEST(COALESCE(p_factor_regalo, 1), 1) * p_precio_sustituto))
                  END)
         END;
$function$;

-- La raíz de la cadena de una línea, para una promo que no nombra su regalo
-- (el regalo es uno de sus productos): la parte del último reparto de la clave
-- con la raíz de antes del reparto, o el primer eslabón; sin eslabones, la línea.
CREATE FUNCTION public._regalo_raiz_de_linea(p_eslabones jsonb, p_cadena uuid, p_producto_id bigint, p_cantidad numeric)
RETURNS TABLE(producto_id bigint, cantidad numeric)
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public'
AS $function$
  WITH e AS (
    SELECT x, (x->>'id')::bigint AS id
      FROM jsonb_array_elements(COALESCE(p_eslabones, '[]'::jsonb)) x
     WHERE p_cadena IS NOT NULL AND (x->>'cadena_id')::uuid = p_cadena
  ), rep AS (
    SELECT x FROM e WHERE x->>'reparto_id' IS NOT NULL ORDER BY id DESC LIMIT 1
  ), pri AS (
    SELECT x FROM e ORDER BY id LIMIT 1
  )
  SELECT COALESCE((SELECT COALESCE((x->>'producto_raiz_id')::bigint, (x->>'producto_original_id')::bigint) FROM rep),
                  (SELECT (x->>'producto_original_id')::bigint FROM pri),
                  p_producto_id),
         COALESCE((SELECT (x->>'cantidad_sustituta')::numeric FROM rep),
                  (SELECT (x->>'cantidad_original')::numeric FROM pri),
                  p_cantidad);
$function$;

-- El regalo contra el que se mide un sustituto: el que da la promo
-- (producto_regalo_id, o su contenedor, como regalo_fuera_de_promo), y no el
-- producto con el que se cargó la línea ni la línea de hoy. Una promo que no lo
-- nombra regala uno de sus productos: ahí, la raíz de la cadena de la línea. Y
-- el factor de su barra: 1 si el regalo mueve stock (la foto del pedido).
CREATE FUNCTION public._regalo_de_la_promo(p_pedido_id bigint, p_promocion_id bigint, p_sucursal_id bigint,
                                           p_cadena uuid, p_producto_linea bigint, p_corte numeric)
RETURNS TABLE(producto_id bigint, precio numeric, factor integer, por_linea boolean)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $function$
BEGIN
  por_linea := COALESCE(public._regalo_modo_del_pedido(p_pedido_id, p_promocion_id, p_sucursal_id), true);
  SELECT COALESCE(p.producto_regalo_id, p.ajuste_producto_id) INTO producto_id
    FROM promociones p WHERE p.id = p_promocion_id AND p.sucursal_id = p_sucursal_id;
  IF producto_id IS NULL THEN
    SELECT r.producto_id INTO producto_id
      FROM public._regalo_raiz_de_linea(public.regalo_eslabones(p_pedido_id, p_promocion_id, p_sucursal_id),
                                        p_cadena, p_producto_linea, p_corte) r;
  END IF;
  SELECT pr.precio INTO precio FROM productos pr WHERE pr.id = producto_id AND pr.sucursal_id = p_sucursal_id;
  factor := CASE WHEN por_linea THEN 1
                 ELSE GREATEST(COALESCE(public.factor_regalo_de_linea(p_promocion_id, producto_id, p_sucursal_id, producto_id), 1), 1)
            END;
  RETURN NEXT;
END
$function$;

-- PRM-1: el tope de un sustituto en una línea (regalo_tope_sustituto contra el
-- regalo de la promo, con el corte que se pasa).
CREATE FUNCTION public._regalo_tope_de_linea(p_pedido_id bigint, p_promocion_id bigint, p_sucursal_id bigint,
                                             p_cadena uuid, p_producto_linea bigint, p_corte numeric,
                                             p_sustituto bigint, p_contenedor_sustituto bigint)
RETURNS TABLE(regalo bigint, tope numeric)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $function$
DECLARE
  v_r record;
BEGIN
  SELECT * INTO v_r FROM public._regalo_de_la_promo(p_pedido_id, p_promocion_id, p_sucursal_id,
                                                    p_cadena, p_producto_linea, p_corte);
  regalo := v_r.producto_id;
  tope := public.regalo_tope_sustituto(
            p_corte, v_r.precio, v_r.factor,
            (SELECT pr.precio FROM productos pr WHERE pr.id = p_sustituto AND pr.sucursal_id = p_sucursal_id),
            CASE WHEN v_r.por_linea THEN 1
                 ELSE GREATEST(COALESCE(public.factor_regalo_de_linea(p_promocion_id, p_sustituto, p_sucursal_id,
                                                                      COALESCE(p_contenedor_sustituto, p_sustituto)), 1), 1)
            END,
            p_sustituto = v_r.producto_id
              OR COALESCE(public.regalo_misma_categoria(v_r.producto_id, p_sustituto, p_sucursal_id), false));
  RETURN NEXT;
END
$function$;

-- PRM-1 (H1 de la revisión): un reparto cumple la regla sobre el total de sus
-- partes. Todas del mismo rubro que el regalo de la promo y la suma hasta el
-- corte, o la suma de lo que valen, a precio de lista por unidad de la línea,
-- hasta lo que vale el regalo con su corte.
CREATE FUNCTION public._regalo_reparto_dentro_del_tope(p_pedido_id bigint, p_promocion_id bigint, p_sucursal_id bigint,
                                                       p_cadena uuid, p_producto_linea bigint, p_corte numeric,
                                                       p_productos bigint[], p_cantidades numeric[])
RETURNS TABLE(regalo bigint, dentro boolean)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $function$
DECLARE
  v_r       record;
  v_precios boolean;
  v_suma    numeric;
BEGIN
  SELECT * INTO v_r FROM public._regalo_de_la_promo(p_pedido_id, p_promocion_id, p_sucursal_id,
                                                    p_cadena, p_producto_linea, p_corte);
  regalo := v_r.producto_id;
  IF (SELECT bool_and(x = v_r.producto_id
                      OR COALESCE(public.regalo_misma_categoria(v_r.producto_id, x, p_sucursal_id), false))
        FROM unnest(p_productos) x)
     AND (SELECT sum(c) FROM unnest(p_cantidades) c) <= p_corte THEN
    dentro := true;
    RETURN NEXT;
    RETURN;
  END IF;
  SELECT bool_and(COALESCE(pr.precio, 0) > 0),
         sum(t.c * pr.precio
             / CASE WHEN v_r.por_linea THEN 1
                    ELSE GREATEST(COALESCE(public.factor_regalo_de_linea(p_promocion_id, t.x, p_sucursal_id, t.x), 1), 1) END)
    INTO v_precios, v_suma
    FROM unnest(p_productos, p_cantidades) AS t(x, c)
    LEFT JOIN productos pr ON pr.id = t.x AND pr.sucursal_id = p_sucursal_id;
  -- Un margen de redondeo para las divisiones por el factor (6, 12…), que no
  -- son exactas en numeric: lo que vale lo mismo, entra.
  dentro := COALESCE(v_precios, false) AND COALESCE(v_r.precio, 0) > 0
            AND v_suma <= p_corte * v_r.precio / v_r.factor + 0.000001;
  RETURN NEXT;
END
$function$;

-- PRM-1: en la edición, el regalo que la cadena de su línea convierte. Sin
-- pasos (la cadena no lo toca), ninguna fila. El tope es el del producto final
-- contra el regalo de la promo con el corte que trae el JSON (que es el que se
-- le sella a la línea), más una unidad por eslabón (las conversiones de la
-- cadena redondean), o lo que el último eslabón ya dejó si es más: lo que armó un
-- admin por encima se conserva, pero la edición de otro no lo hace crecer.
CREATE FUNCTION public._regalo_tope_de_cadena(p_pedido_id bigint, p_promocion_id bigint, p_producto_id bigint,
                                              p_sucursal_id bigint, p_cantidad numeric, p_cadena uuid)
RETURNS TABLE(producto_final bigint, cantidad_final numeric, tope numeric)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $function$
DECLARE
  v_eslabones jsonb;
  v_pasos     bigint[];
  v_id        bigint;
  v_s         pedido_item_sustituciones%ROWTYPE;
  v_cant      numeric := p_cantidad;
  v_t         numeric;
BEGIN
  IF p_cadena IS NULL OR p_cantidad IS NULL OR p_promocion_id IS NULL THEN
    RETURN;
  END IF;
  v_eslabones := public.regalo_eslabones(p_pedido_id, p_promocion_id, p_sucursal_id);
  v_pasos := public.regalo_cadena_pasos(v_eslabones, p_producto_id, p_cadena);
  IF COALESCE(array_length(v_pasos, 1), 0) = 0 THEN
    RETURN;
  END IF;
  -- El mismo recorrido que regalo_sustitucion_resuelta.
  FOREACH v_id IN ARRAY v_pasos LOOP
    SELECT s.* INTO v_s FROM pedido_item_sustituciones s WHERE s.id = v_id;
    v_cant := public.regalo_cantidad_tras_eslabon(v_cant, v_s.cantidad_original, v_s.cantidad_sustituta);
  END LOOP;
  SELECT t.tope INTO v_t
    FROM public._regalo_tope_de_linea(p_pedido_id, p_promocion_id, p_sucursal_id, p_cadena, p_producto_id,
                                      p_cantidad, v_s.producto_sustituto_id, v_s.ajuste_producto_id_nuevo) t;
  producto_final := v_s.producto_sustituto_id;
  cantidad_final := v_cant;
  tope := GREATEST(v_s.cantidad_sustituta, COALESCE(v_t, 0) + array_length(v_pasos, 1));
  RETURN NEXT;
END
$function$;

REVOKE ALL ON FUNCTION public.regalo_tope_sustituto(numeric, numeric, numeric, numeric, numeric, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._regalo_raiz_de_linea(jsonb, uuid, bigint, numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._regalo_de_la_promo(bigint, bigint, bigint, uuid, bigint, numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._regalo_tope_de_linea(bigint, bigint, bigint, uuid, bigint, numeric, bigint, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._regalo_reparto_dentro_del_tope(bigint, bigint, bigint, uuid, bigint, numeric, bigint[], numeric[]) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._regalo_tope_de_cadena(bigint, bigint, bigint, bigint, numeric, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.regalo_tope_sustituto(numeric, numeric, numeric, numeric, numeric, boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public._regalo_raiz_de_linea(jsonb, uuid, bigint, numeric) TO service_role;
GRANT EXECUTE ON FUNCTION public._regalo_de_la_promo(bigint, bigint, bigint, uuid, bigint, numeric) TO service_role;
GRANT EXECUTE ON FUNCTION public._regalo_tope_de_linea(bigint, bigint, bigint, uuid, bigint, numeric, bigint, bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public._regalo_reparto_dentro_del_tope(bigint, bigint, bigint, uuid, bigint, numeric, bigint[], numeric[]) TO service_role;
GRANT EXECUTE ON FUNCTION public._regalo_tope_de_cadena(bigint, bigint, bigint, bigint, numeric, uuid) TO service_role;

-- H4: la pantalla de cambio de regalo sugiere y topea con la misma cuenta que el
-- server, y para eso necesita el corte de la línea. La columna sigue siendo de server
-- (mig 500): la da esta RPC, sólo a admin y encargado (los que sustituyen), de una línea
-- de la sucursal activa.
CREATE FUNCTION public.regalo_corte_de_linea(p_pedido_item_id bigint)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT pi.regalo_corte
    FROM pedido_items pi
   WHERE pi.id = p_pedido_item_id
     AND pi.sucursal_id = current_sucursal_id()
     AND public.es_encargado_o_admin();
$function$;

REVOKE ALL ON FUNCTION public.regalo_corte_de_linea(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.regalo_corte_de_linea(bigint) TO authenticated, service_role;

-- =========================================================================
-- 1 · sustituir_regalo_pedido: la promo tomada, el tope, el stock neto y el
--     contador
-- =========================================================================
DO $parche_sustituir$
DECLARE
  v_def    text := pg_get_functiondef('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)'::regprocedure);
  v_modo   text;
  v_bulto  text;
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  v_item_guc           TEXT;
BEGIN
$a$,
$r$  v_item_guc           TEXT;
  -- PRM-1 (#1592): el corte de la línea y el tope del sustituto.
  v_corte              NUMERIC;
  v_tope               RECORD;
BEGIN
$r$, 'sustituir_regalo_pedido (declaraciones)');

  -- 1556-c2: la lectura de la promo, el modo y el rechazo de LV-1 pasan abajo,
  -- después de tomar los productos, con la promo tomada.
  v_modo := pg_temp.tramo(v_def,
$a$  SELECT id, regalo_mueve_stock, ajuste_automatico, producto_regalo_id,
         ajuste_producto_id, unidades_por_bloque, stock_por_bloque, usos_pendientes
    INTO v_promo FROM promociones WHERE id = v_item.promocion_id AND sucursal_id = v_sucursal;
$a$,
$a$  v_ajuste_sustituto_efectivo := COALESCE(p_ajuste_producto_id_nuevo, p_producto_nuevo_id);
$a$, 'sustituir_regalo_pedido (la promo y el modo)');
  v_def := pg_temp.parche(v_def, v_modo, '', 'sustituir_regalo_pedido (sacar la promo y el modo)');
  v_modo := pg_temp.parche(v_modo,
$a$ AND sucursal_id = v_sucursal;
  -- #1324: el modo de la foto del pedido.
$a$,
$r$ AND sucursal_id = v_sucursal
     FOR UPDATE;
  -- #1324: el modo de la foto del pedido.
$r$, 'sustituir_regalo_pedido (la promo, FOR UPDATE)');

  -- El chequeo del bulto de otra categoría usa el modo: va con él.
  v_bulto := pg_temp.tramo(v_def,
$a$  IF v_otra_categoria AND NOT v_regalo_mueve_stock
$a$,
$a$  -- #1326 / #1375: los productos y los contenedores juntos y por id, antes de
$a$, 'sustituir_regalo_pedido (el bulto de otra categoría)');
  v_def := pg_temp.parche(v_def, v_bulto, '', 'sustituir_regalo_pedido (sacar el bulto)');

  v_def := pg_temp.parche(v_def,
$a$                UNION SELECT c FROM public._contenedores_de_promos(ARRAY[v_item.promocion_id], v_sucursal) c)
   ORDER BY id
     FOR UPDATE;
$a$,
$r$                UNION SELECT c FROM public._contenedores_de_promos(ARRAY[v_item.promocion_id], v_sucursal) c)
   ORDER BY id
     FOR UPDATE;

  -- 1556-c2 (#1556): la promo, después de los productos (el orden de la venta y de la
  -- edición, #1460), y recién con ella tomada el modo, la marca de la barra y el factor.
  -- Se leían sin tomarla: un cambio de tipo simultáneo se colaba entre el chequeo y la barra.
$r$ || v_modo || v_bulto || $r$  -- PRM-1 (#1592): decisión del dueño (16/11). Para quien no es admin, el sustituto entra
  -- si es del mismo rubro que el regalo con igual o menor cantidad, o si no vale más, a
  -- precio de lista, que el regalo. Siempre contra el regalo que da la promo, con el corte
  -- de la línea (lo que cuenta el cupo, en la unidad de la promo): no contra el producto
  -- con el que se cargó la línea ni contra la línea de hoy, así ni sustituir dos veces ni
  -- cargar otro sabor suben el techo. El admin, sin tope.
  IF v_user_role IS DISTINCT FROM 'admin' THEN
    v_corte := COALESCE((SELECT regalo_corte FROM pedido_items WHERE id = p_pedido_item_id),
                        public.regalo_cantidad_base(public.regalo_eslabones(v_item.pedido_id, v_item.promocion_id, v_sucursal),
                                                    v_item.regalo_cadena_id, v_item.cantidad));
    SELECT * INTO v_tope
      FROM public._regalo_tope_de_linea(v_item.pedido_id, v_item.promocion_id, v_sucursal, v_item.regalo_cadena_id,
                                        v_item.producto_id, v_corte, p_producto_nuevo_id, v_ajuste_sustituto_efectivo);
    IF p_cantidad_nueva > v_tope.tope THEN
      RETURN jsonb_build_object('success', false, 'codigo', 'regalo_sustituto_sobre_tope', 'error',
        CASE WHEN v_tope.tope < 1 THEN format(
          'Una unidad de %s ya vale más, a precio de lista, que el regalo que da la promo (%s de %s), y no es del mismo rubro: ese cambio lo puede hacer sólo un admin.',
          COALESCE(v_nuevo_nombre, 'ese producto'), round(v_corte)::bigint,
          COALESCE((SELECT nombre FROM productos WHERE id = v_tope.regalo AND sucursal_id = v_sucursal), 'otro producto'))
        ELSE format(
          'El regalo se puede cambiar por otro del mismo rubro con la misma cantidad o menos, o por algo que no valga más, a precio de lista, que el regalo que da la promo (%s de %s): se pueden poner hasta %s de %s. Para dar más, lo tiene que cambiar un admin.',
          round(v_corte)::bigint,
          COALESCE((SELECT nombre FROM productos WHERE id = v_tope.regalo AND sucursal_id = v_sucursal), 'otro producto'),
          round(v_tope.tope)::bigint, COALESCE(v_nuevo_nombre, 'ese producto')) END);
    END IF;
  END IF;
$r$, 'sustituir_regalo_pedido (la promo después de los productos y el tope)');

  -- 1556-b2: el stock neto de lo que la línea ya tiene del mismo producto.
  v_def := pg_temp.parche(v_def,
$a$    IF v_stock_nuevo < p_cantidad_nueva THEN
      RETURN jsonb_build_object('success', false, 'error', 'Stock insuficiente del producto sustituto (' || v_stock_nuevo || ' disponible)');
$a$,
$r$    -- 1556-b2 (#1556): lo que la línea ya tiene de ese producto vuelve antes de que baje el
    -- sustituto. R×4 por R×4 con el stock en 0 daba «Stock insuficiente».
    IF p_producto_nuevo_id = v_item.producto_id THEN
      v_stock_nuevo := v_stock_nuevo + v_item.cantidad;
    END IF;
    IF v_stock_nuevo < p_cantidad_nueva THEN
      RETURN jsonb_build_object('success', false, 'error', 'Stock insuficiente del producto sustituto (' || v_stock_nuevo || ' disponible)');
$r$, 'sustituir_regalo_pedido (stock neto)');

  -- 1592-b3: el contador de una promo que mueve stock.
  v_def := pg_temp.parche(v_def,
$a$      'sustitucion: entrada del producto regalo sustituto'
    );
  END IF;
$a$,
$r$      'sustitucion: entrada del producto regalo sustituto'
    );
  END IF;
  -- 1592-b3 (#1592): en una promo que mueve stock, usos_pendientes es un contador en la
  -- unidad de la línea: el alta suma la línea y la cancelación resta la que quedó. Sin la
  -- diferencia, un cambio por valor (R×10 → W×1) lo dejaba corrido en 9.
  IF v_regalo_mueve_stock AND p_cantidad_nueva <> v_item.cantidad
     AND public._regalo_barra_vale(v_item.pedido_id, v_item.promocion_id, v_sucursal) THEN
    PERFORM public.aplicar_uso_promo_acumulador(
      v_promo.id, p_producto_nuevo_id, p_cantidad_nueva - v_item.cantidad,
      v_ajuste_sustituto_efectivo, v_sucursal, v_user_id,
      'sustitucion: el contador de la promo'
    );
  END IF;
$r$, 'sustituir_regalo_pedido (el contador)');

  EXECUTE v_def;
END
$parche_sustituir$;

-- =========================================================================
-- 2 · dividir_regalo_pedido: la promo tomada (1556-c2)
-- =========================================================================
DO $parche_dividir$
DECLARE
  v_def  text := pg_get_functiondef('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'::regprocedure);
  v_modo text;
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  v_item_guc           TEXT;
BEGIN
$a$,
$r$  v_item_guc           TEXT;
  -- PRM-1 (#1592, H1 de la revisión): el corte de la línea y si el reparto entra.
  v_corte              NUMERIC;
  v_tope               RECORD;
BEGIN
$r$, 'dividir_regalo_pedido (declaraciones)');

  v_modo := pg_temp.tramo(v_def,
$a$  SELECT id, regalo_mueve_stock, ajuste_automatico, producto_regalo_id,
         ajuste_producto_id, unidades_por_bloque, stock_por_bloque, usos_pendientes
    INTO v_promo FROM promociones WHERE id = v_item.promocion_id AND sucursal_id = v_sucursal;
$a$,
$a$  -- Consumo NETO por producto: lo que se lleva cada parte menos lo que vuelve
$a$, 'dividir_regalo_pedido (la promo, el modo y el empaque)');
  v_def := pg_temp.parche(v_def, v_modo, '', 'dividir_regalo_pedido (sacar la promo y el modo)');
  v_modo := pg_temp.parche(v_modo,
$a$ AND sucursal_id = v_sucursal;
  -- #1324: el modo de la foto del pedido.
$a$,
$r$ AND sucursal_id = v_sucursal
     FOR UPDATE;
  -- #1324: el modo de la foto del pedido.
$r$, 'dividir_regalo_pedido (la promo, FOR UPDATE)');

  v_def := pg_temp.parche(v_def,
$a$   ORDER BY id
     FOR UPDATE;

  -- Stock ANTES de mover nada: las validaciones devuelven {success:false} sin
$a$,
$r$   ORDER BY id
     FOR UPDATE;

  -- 1556-c2 (#1556): la promo, después de los productos (el orden de la venta y de la
  -- edición, #1460), y recién con ella tomada el modo, la marca de la barra y el empaque.
  -- Se leían sin tomarla: un cambio de tipo simultáneo se colaba entre el chequeo y la barra.
$r$ || v_modo || $r$  -- PRM-1 (#1592, H1 de la revisión): la regla del sustituto vale para el reparto, sobre
  -- el total de sus partes y contra el regalo que da la promo con el corte de la línea:
  -- todas del mismo rubro, o la suma de lo que valen hasta lo que vale el regalo. Sin
  -- esto, repartir en productos caros, o repartir y después sustituir una parte, salteaba
  -- el tope. El admin, sin tope.
  IF v_user_role IS DISTINCT FROM 'admin' THEN
    v_corte := COALESCE((SELECT regalo_corte FROM pedido_items WHERE id = p_pedido_item_id), v_item.cantidad);
    SELECT * INTO v_tope
      FROM public._regalo_reparto_dentro_del_tope(v_item.pedido_id, v_item.promocion_id, v_sucursal,
                                                  v_item.regalo_cadena_id, v_item.producto_id, v_corte, v_prod, v_cant);
    IF NOT COALESCE(v_tope.dentro, false) THEN
      RETURN jsonb_build_object('success', false, 'codigo', 'regalo_sustituto_sobre_tope', 'error', format(
        'El reparto puede llevar sabores del mismo rubro que el regalo, o productos que entre todos no valgan más, a precio de lista, que el regalo que da la promo (%s de %s). Para repartirlo así, lo tiene que hacer un admin.',
        round(v_corte)::bigint,
        COALESCE((SELECT nombre FROM productos WHERE id = v_tope.regalo AND sucursal_id = v_sucursal), 'otro producto')));
    END IF;
  END IF;

  -- Stock ANTES de mover nada: las validaciones devuelven {success:false} sin
$r$, 'dividir_regalo_pedido (la promo después de los productos y el tope)');

  EXECUTE v_def;
END
$parche_dividir$;

-- =========================================================================
-- 3 · actualizar_pedido_items: la edición no escala un sustituto por encima
--     del tope (PRM-1)
-- =========================================================================
DO $parche_editar$
DECLARE
  v_def text := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$        v_tramo_anterior)), 'codigo', 'regalo_de_tramo_anterior');
    END IF;
  END;
$a$,
$r$        v_tramo_anterior)), 'codigo', 'regalo_de_tramo_anterior');
    END IF;
  END;

  -- PRM-1 (#1592): decisión del dueño (16/11). Para quien no es admin, la edición no
  -- escala un regalo sustituido por encima de la regla: el regalo que la cadena de su
  -- línea convierte (el mismo recorrido que el trigger y el pre-chequeo de abajo) no pasa
  -- el tope contra el regalo de la promo con el corte que trae el JSON, salvo que no crezca
  -- más allá de lo que el último eslabón dejó (lo que armó un admin se conserva, pero no
  -- crece). Una línea conservada de un reparto va tal cual y no se mide. Va antes de
  -- escribir nada.
  IF v_user_role IS DISTINCT FROM 'admin' THEN
    DECLARE
      v_sobre_tope TEXT;
    BEGIN
      SELECT string_agg(format('%s de %s, y quien no es admin puede llegar hasta %s',
                               round(t.cantidad_final)::bigint, COALESCE(pr.nombre, '#' || t.producto_final),
                               round(t.tope)::bigint),
                        '; ' ORDER BY t.producto_final)
        INTO v_sobre_tope
        FROM jsonb_array_elements(v_items) e
       CROSS JOIN LATERAL public._regalo_tope_de_cadena(
               p_pedido_id, (e->>'promocion_id')::BIGINT, (e->>'producto_id')::BIGINT, v_sucursal,
               (e->>'cantidad')::NUMERIC, (e->>'_cadena')::UUID) t
        LEFT JOIN productos pr ON pr.id = t.producto_final AND pr.sucursal_id = v_sucursal
       WHERE COALESCE((e->>'es_bonificacion')::BOOLEAN, false)
         AND e->>'promocion_id' IS NOT NULL
         AND e->>'_reparto' IS DISTINCT FROM v_marca_reparto
         AND t.cantidad_final > t.tope;
      IF v_sobre_tope IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(format(
          'Con este cambio, un regalo cambiado por otro producto pasaría a valer más, a precio de lista, que el regalo que da la promo: quedaría en %s. Sólo un admin puede dejarlo así: pedile que edite el pedido, o volvé el regalo a su producto. El pedido no se modificó.',
          v_sobre_tope)), 'codigo', 'regalo_sustituto_sobre_tope');
      END IF;
    END;
  END IF;
$r$, 'actualizar_pedido_items (el tope del sustituto)');

  EXECUTE v_def;
END
$parche_editar$;

-- =========================================================================
-- 4 · aplicar_uso_promo_acumulador: una promo que mueve stock no tiene barra
--     (1592-b2)
-- =========================================================================
DO $parche_acumulador$
DECLARE
  v_def text := pg_get_functiondef('public.aplicar_uso_promo_acumulador(bigint,bigint,numeric,bigint,bigint,uuid,text)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  IF NOT COALESCE(v_promo.ajuste_automatico, FALSE)
     OR COALESCE(v_promo.unidades_por_bloque, 0) <= 0
     OR COALESCE(v_promo.stock_por_bloque, 0) <= 0 THEN
$a$,
$r$  -- 1592-b2 (#1592): modo A es la promo que mueve stock, y el regalo ya bajó por línea.
  -- Con ajuste automático y factor, además cerraba bloques del contenedor: descontaba
  -- dos veces.
  IF NOT COALESCE(v_promo.ajuste_automatico, FALSE)
     OR COALESCE(v_promo.unidades_por_bloque, 0) <= 0
     OR COALESCE(v_promo.stock_por_bloque, 0) <= 0
     OR v_promo.regalo_mueve_stock IS NOT FALSE THEN
$r$, 'aplicar_uso_promo_acumulador (modo A, contador)');

  EXECUTE v_def;
END
$parche_acumulador$;

-- =========================================================================
-- 5 · renormalizar_bloques_por_cambio_factor: el bloque anota su lote y los
--     GUC vuelven (PRM-3); sin barra no cierra bloques (1592-b2)
-- =========================================================================
DO $parche_renormalizar$
DECLARE
  v_def  text := pg_get_functiondef('public.renormalizar_bloques_por_cambio_factor()'::regprocedure);
  v_cola text;
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  v_merma_id    BIGINT;
BEGIN
$a$,
$r$  v_merma_id    BIGINT;
  -- PRM-3 (#1592): de dónde salió el fardo, y los GUC del llamador.
  v_foto        JSONB;
  v_lotes       JSONB;
  v_de_lotes    INT;
  v_org_prev      TEXT;
  v_ref_tipo_prev TEXT;
  v_ref_id_prev   TEXT;
  v_user_prev     TEXT;
  v_item_prev     TEXT;
BEGIN
$r$, 'renormalizar (declaraciones)');

  v_def := pg_temp.parche(v_def,
$a$  IF COALESCE(v_n, 0) <= 0 OR COALESCE(v_spb, 0) <= 0 THEN
    RETURN NULL;
  END IF;
$a$,
$r$  -- 1592-b2 (#1592): sin barra no hay bloques. Una promo que mueve stock, o sin ajuste
  -- automático, lleva un contador en usos_pendientes (aplicar_uso_promo_acumulador):
  -- renormalizarlo le cerraba bloques y le bajaba el contenedor.
  IF COALESCE(v_n, 0) <= 0 OR COALESCE(v_spb, 0) <= 0
     OR NOT COALESCE(NEW.ajuste_automatico, false) OR NEW.regalo_mueve_stock IS NOT FALSE THEN
    RETURN NULL;
  END IF;
$r$, 'renormalizar (sin barra)');

  v_cola := pg_temp.tramo(v_def,
$a$    PERFORM set_config('app.stock_origen', 'auto_ajuste_promo', true);
$a$,
$a$  END LOOP;

  RETURN NULL;
$a$, 'renormalizar (el bloque)');
  v_def := pg_temp.parche(v_def, v_cola,
$r$    SELECT stock INTO v_stock_ant
      FROM productos
     WHERE id = v_barra.contenedor AND sucursal_id = NEW.sucursal_id
     FOR UPDATE;
    v_stock_nue := COALESCE(v_stock_ant, 0) - v_unidades;

    -- PRM-3 (#1592): como el bloque de aplicar_uso_promo_acumulador (#1558, STK-19), éste
    -- anota en promo_ajustes.lotes_pendientes de dónde salió el fardo (la foto de los lotes,
    -- como un envío; lo que vino de la bolsa, primero, que es como lo come la bajada). Sin
    -- el registro, deshacerlo lo mandaba a la bolsa aunque hubiera salido de un lote. Y los
    -- cinco GUC se guardan y se restauran alrededor del UPDATE (229): quedaban puestos.
    v_org_prev      := current_setting('app.stock_origen', true);
    v_ref_tipo_prev := current_setting('app.stock_ref_tipo', true);
    v_ref_id_prev   := current_setting('app.stock_ref_id', true);
    v_user_prev     := current_setting('app.stock_user_id', true);
    v_item_prev     := current_setting('app.stock_pedido_item_id', true);
    v_foto  := NULL;
    v_lotes := NULL;
    IF EXISTS (SELECT 1 FROM producto_lotes
                WHERE producto_id = v_barra.contenedor AND sucursal_id = NEW.sucursal_id) THEN
      v_foto := public._mov_lotes_foto(v_barra.contenedor, NEW.sucursal_id);
    END IF;

    PERFORM set_config('app.stock_origen', 'auto_ajuste_promo', true);
    PERFORM set_config('app.stock_ref_tipo', 'promocion', true);
    PERFORM set_config('app.stock_ref_id', NEW.id::TEXT, true);
    PERFORM set_config('app.stock_user_id', COALESCE(v_usuario::TEXT, ''), true);
    -- El contenedor no es ninguna línea.
    PERFORM set_config('app.stock_pedido_item_id', '', true);

    UPDATE productos SET stock = v_stock_nue, updated_at = NOW()
     WHERE id = v_barra.contenedor AND sucursal_id = NEW.sucursal_id;

    IF v_foto IS NOT NULL THEN
      SELECT COALESCE(SUM(x.cantidad), 0)::INT,
             COALESCE(jsonb_agg(jsonb_build_object('lote_id', x.lote_id, 'cantidad', x.cantidad)
                                ORDER BY x.fecha_vencimiento, x.lote_id), '[]'::jsonb)
        INTO v_de_lotes, v_lotes
        FROM jsonb_to_recordset(public._mov_lotes_diff(v_barra.contenedor, NEW.sucursal_id, v_foto, -1))
             AS x(lote_id BIGINT, fecha_vencimiento DATE, cantidad INT);
      IF v_unidades > v_de_lotes THEN
        v_lotes := jsonb_build_array(jsonb_build_object('lote_id', NULL, 'cantidad', v_unidades - v_de_lotes))
                   || v_lotes;
      END IF;
    END IF;

    PERFORM set_config('app.stock_origen',   COALESCE(v_org_prev, ''), true);
    PERFORM set_config('app.stock_ref_tipo', COALESCE(v_ref_tipo_prev, ''), true);
    PERFORM set_config('app.stock_ref_id',   COALESCE(v_ref_id_prev, ''), true);
    PERFORM set_config('app.stock_user_id',  COALESCE(v_user_prev, ''), true);
    PERFORM set_config('app.stock_pedido_item_id', COALESCE(v_item_prev, ''), true);

    INSERT INTO mermas_stock (
      producto_id, cantidad, motivo, observaciones,
      stock_anterior, stock_nuevo, usuario_id, sucursal_id
    ) VALUES (
      v_barra.contenedor, v_unidades, 'promociones', v_obs,
      COALESCE(v_stock_ant, 0), v_stock_nue, v_usuario, NEW.sucursal_id
    ) RETURNING id INTO v_merma_id;

    INSERT INTO promo_ajustes (
      promocion_id, usos_ajustados, unidades_ajustadas,
      producto_id, merma_id, usuario_id, observaciones, sucursal_id,
      lotes_pendientes
    ) VALUES (
      NEW.id, v_bloques * v_n, v_unidades,
      v_barra.contenedor, v_merma_id, v_usuario, v_obs, NEW.sucursal_id,
      v_lotes
    );
$r$, 'renormalizar (el bloque con su lote)');

  EXECUTE v_def;
END
$parche_renormalizar$;

-- =========================================================================
-- 6 · PRM-2 · la configuración de la barra no cambia con pedidos abiertos
-- =========================================================================
CREATE FUNCTION public.promo_config_barra_con_pedidos()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_fraccion_antes   boolean;
  v_fraccion_despues boolean;
  v_cambia_barra     boolean;
  v_cambia_factor    boolean;
  v_cambia_cont      boolean;
  v_rota             boolean;
  v_que              text[] := '{}';
  v_pedidos          int;
  v_ids              text;
BEGIN
  -- PRM-2 (#1592): aplicar_uso_promo_acumulador deshace los bloques con el factor, el
  -- stock por bloque y el contenedor de hoy. Cambiarlos mientras un pedido que entró en la
  -- barra todavía la puede deshacer descuadra el contenedor. Decisión del dueño (plan
  -- #1603, D2): no se puede, como las unidades por bulto de un producto
  -- (validar_cambio_unidades_por_bulto).
  -- El cambio de tipo es otra regla (#1324, decisión del dueño): se puede con pedidos
  -- abiertos, la barra se reinicia (trg_promo_tipo_reinicia_barra) y esos pedidos no entran
  -- en la nueva. Con la promo de unidad entera, antes o después, no hay barra.
  IF OLD.regalo_mueve_stock IS NOT FALSE OR NEW.regalo_mueve_stock IS NOT FALSE THEN
    RETURN NEW;
  END IF;
  -- La barra cierra bloques sólo así (aplicar_uso_promo_acumulador); si no, es un contador.
  v_fraccion_antes := COALESCE(OLD.ajuste_automatico, false)
                      AND COALESCE(OLD.unidades_por_bloque, 0) > 0 AND COALESCE(OLD.stock_por_bloque, 0) > 0;
  v_fraccion_despues := COALESCE(NEW.ajuste_automatico, false)
                        AND COALESCE(NEW.unidades_por_bloque, 0) > 0 AND COALESCE(NEW.stock_por_bloque, 0) > 0;
  IF NOT v_fraccion_antes AND NOT v_fraccion_despues THEN
    RETURN NEW;
  END IF;
  -- La barra aparece o desaparece (el ajuste automático, o un factor que pasa a vacío):
  -- toca a todas las barras de la promo.
  v_cambia_barra := v_fraccion_antes IS DISTINCT FROM v_fraccion_despues;
  -- El factor y el stock por bloque: a las barras cuyo contenedor no trae su bulto
  -- (con unidades_por_bulto cuentan con ése, mig 295).
  v_cambia_factor := OLD.unidades_por_bloque IS DISTINCT FROM NEW.unidades_por_bloque
                     OR OLD.stock_por_bloque IS DISTINCT FROM NEW.stock_por_bloque;
  -- H5 (revisión de M1): cambiar el regalo de la promo con su contenedor, cuando el
  -- contenedor era el mismo regalo (lo que arma el formulario de fracción), lo cubre
  -- trg_promo_rotar_barra_default: la barra vieja se muda a promo_acumuladores con el
  -- contenedor viejo, y si estaba en 0 la primera vuelta la crea con el producto de la
  -- línea, que es ese contenedor. Hace falta que la rotación corra (ajuste automático) y
  -- que el regalo nuevo no traiga una barra propia con otro contenedor, que se mudaría a la
  -- de la promo.
  v_rota := OLD.producto_regalo_id IS NOT NULL AND NEW.producto_regalo_id IS NOT NULL
            AND OLD.producto_regalo_id IS DISTINCT FROM NEW.producto_regalo_id
            AND COALESCE(NEW.ajuste_automatico, false)
            AND COALESCE(OLD.ajuste_producto_id, OLD.producto_regalo_id) = OLD.producto_regalo_id
            AND NOT EXISTS (SELECT 1 FROM promo_acumuladores a
                             WHERE a.promocion_id = NEW.id AND a.sucursal_id = NEW.sucursal_id
                               AND a.producto_regalo_id = NEW.producto_regalo_id
                               AND a.ajuste_producto_id IS DISTINCT FROM NEW.ajuste_producto_id);
  -- El contenedor: a la barra del regalo de la promo.
  v_cambia_cont := OLD.ajuste_producto_id IS DISTINCT FROM NEW.ajuste_producto_id AND NOT v_rota;

  IF OLD.unidades_por_bloque IS DISTINCT FROM NEW.unidades_por_bloque THEN
    v_que := v_que || 'las unidades por bloque'::text;
  END IF;
  IF OLD.stock_por_bloque IS DISTINCT FROM NEW.stock_por_bloque THEN
    v_que := v_que || 'el stock por bloque'::text;
  END IF;
  IF v_cambia_cont THEN
    v_que := v_que || 'el contenedor'::text;
  END IF;
  IF COALESCE(OLD.ajuste_automatico, false) IS DISTINCT FROM COALESCE(NEW.ajuste_automatico, false) THEN
    v_que := v_que || 'el ajuste automático'::text;
  END IF;
  IF NOT (v_cambia_barra OR v_cambia_factor OR v_cambia_cont) OR cardinality(v_que) = 0 THEN
    RETURN NEW;
  END IF;

  -- Los pedidos que todavía pueden deshacer algo de la barra: los que no están cancelados
  -- y, si están entregados, los de un día con la caja abierta, que todavía admiten una
  -- salvedad (H6 de la revisión: la salvedad del regalo pasa por la barra igual que la
  -- cancelación; la caja cerrada la rechaza, _pedido_en_caja_cerrada). Con un regalo que
  -- entró en la barra (foto de fracción, sin la marca de un tramo anterior; la promo de la
  -- tabla es la de antes del cambio) y en una barra que el cambio toca.
  SELECT count(*), left(string_agg('#' || x.id, ', ' ORDER BY x.id), 200)
    INTO v_pedidos, v_ids
    FROM (SELECT DISTINCT pe.id
            FROM pedido_items pi
            JOIN pedidos pe ON pe.id = pi.pedido_id
           WHERE pi.promocion_id = NEW.id
             AND pi.sucursal_id = NEW.sucursal_id
             AND COALESCE(pi.es_bonificacion, false)
             AND pe.estado <> 'cancelado'
             AND (pe.estado <> 'entregado' OR public._pedido_en_caja_cerrada(pe.id, NEW.sucursal_id) IS NULL)
             AND NOT COALESCE(public._regalo_modo_del_pedido(pe.id, NEW.id, NEW.sucursal_id), false)
             AND NOT EXISTS (SELECT 1 FROM pedido_promo_reglas f
                              WHERE f.pedido_id = pe.id AND f.promocion_id = NEW.id
                                AND f.sucursal_id = NEW.sucursal_id AND f.barra_anterior)
             AND (v_cambia_barra
                  OR (v_cambia_factor
                      AND (SELECT pc.unidades_por_bulto FROM productos pc
                            WHERE pc.id = public.contenedor_de_barra(NEW.id, pi.producto_id, NEW.sucursal_id, pi.producto_id)
                              AND pc.sucursal_id = NEW.sucursal_id) IS NULL)
                  OR (v_cambia_cont AND pi.producto_id = OLD.producto_regalo_id))) x;
  IF v_pedidos > 0 THEN
    -- L2 de la revisión: borrar el producto que es el contenedor (la FK pone
    -- ajuste_producto_id en NULL desde su propio trigger) dice qué se quiso hacer.
    IF pg_trigger_depth() > 1 AND NEW.ajuste_producto_id IS NULL AND OLD.ajuste_producto_id IS NOT NULL THEN
      RAISE EXCEPTION 'No se puede borrar el producto #%: es el contenedor de la promo «%», y hay % pedido(s) sin entregar, o entregados con la caja abierta, con regalos que ya se contaron en su barra (%). Sacalo de la promo cuando esos pedidos se entreguen y cierre la caja, o se cancelen.',
        OLD.ajuste_producto_id, NEW.nombre, v_pedidos, v_ids;
    END IF;
    RAISE EXCEPTION 'No se puede cambiar % de la promo «%»: hay % pedido(s) sin entregar, o entregados con la caja abierta, con regalos que ya se contaron en su barra (%). Si se cancelaran, se editaran o recibieran una salvedad, se descontarían con la configuración nueva y el contenedor quedaría descuadrado. Esperá a que esos pedidos se entreguen y cierre su caja, o se cancelen, y cambialo después.',
      array_to_string(v_que, ', '), NEW.nombre, v_pedidos, v_ids;
  END IF;
  RETURN NEW;
END
$function$;

REVOKE ALL ON FUNCTION public.promo_config_barra_con_pedidos() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.promo_config_barra_con_pedidos() TO service_role;

CREATE TRIGGER trg_promo_config_barra_con_pedidos
  BEFORE UPDATE OF unidades_por_bloque, stock_por_bloque, ajuste_producto_id, ajuste_automatico
  ON public.promociones
  FOR EACH ROW
  WHEN (old.unidades_por_bloque IS DISTINCT FROM new.unidades_por_bloque
        OR old.stock_por_bloque IS DISTINCT FROM new.stock_por_bloque
        OR old.ajuste_producto_id IS DISTINCT FROM new.ajuste_producto_id
        OR old.ajuste_automatico IS DISTINCT FROM new.ajuste_automatico)
  EXECUTE FUNCTION public.promo_config_barra_con_pedidos();

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, el definer y los EXECUTE quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)', '243714f196f2dae7ae9cb8bdf43b54a1', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)', 'd120bac125a5656fb39d3bf72469c0e0', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'b6e7138c67b92ea84196e0856cf37fca', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.aplicar_uso_promo_acumulador(bigint,bigint,numeric,bigint,bigint,uuid,text)', '6386b01d78e5b1d7ceb9e98ddda6941e', true,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.renormalizar_bloques_por_cambio_factor()', 'a10d7e1cc73030707b47e572fb869caa', true,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.regalo_tope_sustituto(numeric,numeric,numeric,numeric,numeric,boolean)', '63dd3de2f8706a9f721fee08c3b3f431', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._regalo_raiz_de_linea(jsonb,uuid,bigint,numeric)', '0a4953e7c778ab8a5101b56020094922', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._regalo_de_la_promo(bigint,bigint,bigint,uuid,bigint,numeric)', 'bd3354c71bc4b681173f97dd1b009b69', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._regalo_tope_de_linea(bigint,bigint,bigint,uuid,bigint,numeric,bigint,bigint)', 'bec6ca64733089bf6d3c7cfb8af055a6', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._regalo_reparto_dentro_del_tope(bigint,bigint,bigint,uuid,bigint,numeric,bigint[],numeric[])', '522c38e1603c85948d9cd19d60028982', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._regalo_tope_de_cadena(bigint,bigint,bigint,bigint,numeric,uuid)', '82c25d84bb5a13efac0105c78f4d8c8a', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.regalo_corte_de_linea(bigint)', '4bfa829b9e08787196a220bf1e00d62b', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.promo_config_barra_con_pedidos()', 'd42a965a55ec570aba96d4196bccae7f', true,
     '{postgres=X/postgres,service_role=X/postgres}')
  ) AS t(f, h, def, acl) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO x
      FROM pg_proc WHERE oid = r.f::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %)', r.f, x.h, x.a, x.def;
    END IF;
  END LOOP;
  IF has_column_privilege('authenticated', 'public.pedido_items', 'regalo_corte', 'SELECT')
     OR has_column_privilege('anon', 'public.pedido_items', 'regalo_corte', 'SELECT') THEN
    RAISE EXCEPTION 'mig NNN · pedido_items.regalo_corte quedó legible por REST: es de server (500)';
  END IF;
END
$post$;

COMMIT;
