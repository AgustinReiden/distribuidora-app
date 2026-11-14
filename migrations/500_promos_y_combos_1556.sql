-- =========================================================================
-- NNN · PROMOS Y COMBOS: EL REPARTO MIRA LA CATEGORÍA, LA BARRA REINICIADA,
--       EL TOPE DEL COMBO AL ANULAR UNA SALVEDAD Y EL CORTE DE CADA LÍNEA
--       (reauditoría completa del 12/11: PRM-A, PRM-B, PRM-C y PRM-D de #1556;
--        tarjeta 5 de #1565)
--
-- Reemplaza el cuerpo entero de cuatro funciones chicas, parcha por ancla
-- otras tres, crea una de trigger y suma dos columnas, con premisa de md5
-- sobre el cuerpo vivo leído el 12/11 (ledger en la 490) y poscondición de
-- md5, definer y ACL. Los siete cuerpos vivos están en LF.
-- Ensayo: scripts/test-promos-y-combos-1556.sql. Se aplica en LF.
--
-- =========================================================================
-- 1 · PRM-A (alto) · EL REPARTO MIRABA EL ROL PERO NO LA CATEGORÍA
-- =========================================================================
-- `sustituir_regalo_pedido` rechaza al encargado que cambia el regalo por un
-- producto de otra categoría (mig 295, #950: es decisión del dueño, sólo el
-- admin). `dividir_regalo_pedido` acepta admin y encargado y no miraba la
-- categoría de las partes: el encargado cambiaba R×4 por W×3 + R×1 de un
-- whisky, y el stock del whisky bajaba. El front limita el reparto a la misma
-- categoría (ModalSustituirRegalo); el server no.
-- Ahora el reparto aplica la misma regla, con el mismo criterio
-- (`regalo_misma_categoria` contra el producto de la línea) y el mismo
-- mensaje. En prod hay 3 repartos, los tres de un admin.
--
-- =========================================================================
-- 2 · PRM-B · LA BARRA REINICIADA Y EL PEDIDO DEL TRAMO ANTERIOR
-- =========================================================================
-- Al pasar una promo de unidad entera a fracción la barra arranca en 0
-- (`trg_promo_tipo_reinicia_barra`, 431a). Un pedido tomado en un tramo de
-- fracción ANTERIOR tiene una foto de fracción, como la promo de hoy, así que
-- `_regalo_barra_vale` volvía a dar true: cancelarlo, o editarlo sin el
-- regalo, le restaba a la barra nueva unidades que nunca entraron en ella. El
-- contenedor quedaba en 101 con una merma `promociones_reversion` de −1.
-- Ahora el reinicio marca las fotos de fracción que existen
-- (`pedido_promo_reglas.barra_anterior`) y `_regalo_barra_vale` da false para
-- ellas: el pedido de un tramo anterior no le resta ni le suma a la barra
-- reiniciada, como un pedido de otro modo. La marca no se borra al editar
-- (`capturar_promo_del_pedido` no la nombra): sus unidades ya estaban en la
-- barra que se tiró. En prod ninguna promo pasó de unidad entera a fracción
-- (audit_logs, 12/11): ninguna foto nace marcada.
--
-- =========================================================================
-- 3 · PRM-C · ANULAR UNA SALVEDAD REARMABA UN COMBO POR ENCIMA DE SU TOPE
-- =========================================================================
-- El tope de un combo cuenta los combos vivos (`pedido_combos`). Una
-- salvedad `cliente_rechaza` rompe un combo y libera un lugar, otro pedido lo
-- toma, y al anular la salvedad `_combo_rehacer` volvía a armarlo sin mirar
-- el tope: quedaban 3 con tope 2. Para el cupo de una promo esa anulación se
-- rechaza a propósito (el trigger del cupo).
-- Ahora `_combo_rehacer`, cuando rearma más combos de los que el pedido
-- tenía, cuenta los de los otros pedidos con el combo bloqueado, como el
-- alta (`combo_fuera_de_regla`), y si pasa el tope rechaza con su motivo:
-- la anulación entera se deshace. `anular_salvedad` no cambia. La salvedad
-- sólo baja combos, así que a `registrar_salvedad` no le cambia nada.
-- El combo se bloquea con NOWAIT: la anulación ya tiene los productos de la
-- línea, y el alta toma el combo ANTES que sus productos. Esperarlo sería
-- un 40P01 contra un alta del mismo combo; con NOWAIT la anulación falla en
-- el acto con un mensaje para reintentar, y el alta sigue.
-- En prod no hay combos cargados.
--
-- =========================================================================
-- 4 · PRM-D · EL CORTE SE GUARDA EN LA LÍNEA
-- =========================================================================
-- El cupo de una promo (`_promo_usos`) cuenta el corte: lo que da la promo,
-- en su unidad, no lo entregado. Lo deducía deshaciendo la cadena de
-- sustituciones desde la cantidad de hoy (`regalo_usos_de_linea`), y un
-- cambio por valor que achica mucho pierde información: con R×10 → W×1,
-- de R×5 a R×14 dan todos W×1, y W×1 se deshace siempre en 10. Con límite
-- 14, P1 editado a 14 seguía contando 10 y entraba otro pedido con 4 (18
-- cortes reales); editado a 5 seguía trabando 10.
-- Decisión del dueño (12/11): cuenta lo que daba la promo, y el corte se
-- guarda en la línea en vez de deducirse.
--   · `pedido_items.regalo_corte` (integer, NULL fuera de los regalos de
--     promo). No la lee el front: nace sin SELECT para authenticated.
--   · La sella `sellar_corte_regalo_item`, BEFORE INSERT y BEFORE UPDATE de
--     cantidad, es_bonificacion, promocion_id y ella misma. Corre antes que
--     `trg_aplicar_sustituciones_regalo` (por el nombre), así que en un INSERT
--     ve la cantidad que mandó quien inserta, antes de que la cadena la
--     convierta: en el alta, el bot y la edición, esa cantidad es la de la
--     promo (el modal de edición manda el regalo en la unidad de la raíz). Una
--     línea conservada de un reparto (`app.regalo_linea_conservada`) se
--     reinserta en la unidad de su parte: su corte es el de la parte
--     (`regalo_cantidad_base`). Sin tocar `crear_pedido_completo` ni
--     `actualizar_pedido_items`.
--   · Lo escribe a mano, con `app.regalo_corte_manual`, quien lo sabe:
--       - `sustituir_regalo_pedido` lo conserva (sustituir no mueve el cupo);
--       - `dividir_regalo_pedido` le da a cada parte su cantidad, que está en
--         la unidad de la promo (no reparte una línea cambiada por valor);
--       - `cambiar_cliente_pedido` copia el de la línea de X a la nueva, como
--         ya copia su cadena: el alta la insertó con la cantidad de X, que es
--         la del sustituto.
--     Sin la marca, un valor escrito a mano no cuenta: se vuelve a calcular.
--   · Un UPDATE de la cantidad sin la marca (la salvedad) le suma al corte lo
--     que cambió la cantidad medida en cortes con la cadena de siempre: en un
--     regalo sin cambio por valor es exacto, como antes.
--   · `_promo_usos` lee el corte guardado (y, sin él, lo deduce como antes).
--     `regalo_usos_de_linea` no cambia: la siguen usando la salvedad, las
--     simulaciones y la edición para medir el regalo, y es el relleno.
--   · Las líneas que ya existen se llenan con lo que hoy cuenta el cupo
--     (`regalo_usos_de_linea`), sin la auditoría. En prod, 1.980 regalos de
--     promo, y en ninguno ese valor difiere de la cantidad (12/11): el cupo
--     de hoy no cambia.
--
-- Revertir: DROP del trigger, de su función y de las dos columnas, y volver
-- los siete cuerpos a los de la premisa.
-- =========================================================================

BEGIN;

-- Los ADD COLUMN toman pedido_items y pedido_promo_reglas enteras: mejor fallar
-- a los 5 segundos y reintentar que dejar a Pedidos esperando detrás.
SET LOCAL lock_timeout = '5s';

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos del 12/11 (ledger en la 490), y nada de lo nuevo
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)', 'bf401dfb728c720e066d06c17cc1e0c2'),
      ('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)', 'e8bb5ef19d2c922b389d3fc62c7b1d2e'),
      ('public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)', '32838128c6f1aec5da55e890039494f6'),
      ('public._combo_rehacer(bigint,bigint,bigint,bigint)', '47f3668b7d59eaae9e52e2af9c073fa7'),
      ('public._regalo_barra_vale(bigint,bigint,bigint)', 'e38566cf6d1bb5659f484bd642277600'),
      ('public.promo_tipo_reinicia_barra()', '2fdfcc2bdadc52283a754f9f2faa3c3a'),
      ('public._promo_usos(bigint,bigint)', 'd06c6cca197356205289943eb9b4aa9a'),
      -- No cambian, pero el trigger nuevo cuenta con ellas como están.
      ('public.aplicar_sustituciones_regalo_pre_insert()', NULL),
      ('public.regalo_usos_de_linea(jsonb,uuid,numeric)', 'ef688c68401e8f44d923c3d24d857b48'),
      ('public.capturar_promo_del_pedido()', 'b4926b8557e7269eef4258fb39626488')
    ) AS t(firma, hash)
  LOOP
    IF to_regprocedure(r.firma) IS NULL THEN
      RAISE EXCEPTION '% no existe en prod: rehacer sobre lo vigente', r.firma;
    END IF;
    IF r.hash IS NOT NULL
       AND (SELECT md5(prosrc) FROM pg_proc WHERE oid = r.firma::regprocedure) <> r.hash THEN
      RAISE EXCEPTION '% cambió en prod (md5 %): rehacer sobre el cuerpo vigente',
        r.firma, (SELECT md5(prosrc) FROM pg_proc WHERE oid = r.firma::regprocedure);
    END IF;
  END LOOP;
  IF position('regalo_linea_conservada' IN
       (SELECT prosrc FROM pg_proc WHERE oid = 'public.aplicar_sustituciones_regalo_pre_insert()'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'aplicar_sustituciones_regalo_pre_insert ya no mira app.regalo_linea_conservada: revisar el corte de las líneas conservadas';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.pedido_items'::regclass
                AND attname = 'regalo_corte' AND NOT attisdropped)
     OR EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.pedido_promo_reglas'::regclass
                   AND attname = 'barra_anterior' AND NOT attisdropped) THEN
    RAISE EXCEPTION 'regalo_corte o barra_anterior ya existen';
  END IF;
  -- El orden de los BEFORE INSERT es por nombre: el corte tiene que verse antes
  -- de que la cadena convierta la cantidad.
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.pedido_items'::regclass
                    AND tgname = 'trg_aplicar_sustituciones_regalo' AND NOT tgisinternal)
     OR 'pedido_items_regalo_corte' >= 'trg_aplicar_sustituciones_regalo' THEN
    RAISE EXCEPTION 'el trigger de sustituciones no está o cambió de nombre: el corte se sellaría tarde';
  END IF;
  IF has_table_privilege('authenticated', 'public.pedido_items', 'SELECT')
     OR has_table_privilege('authenticated', 'public.pedido_promo_reglas', 'SELECT') THEN
    RAISE EXCEPTION 'el SELECT de pedido_items o de pedido_promo_reglas ya no es por columna o sólo de server: revisar antes de seguir';
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

-- =========================================================================
-- 1 · PRM-A · dividir_regalo_pedido mira la categoría de las partes
-- 4 · PRM-D · y escribe el corte de cada parte
-- =========================================================================
DO $parche_dividir$
DECLARE
  v_def text := pg_get_functiondef('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$    RETURN jsonb_build_object('success', false, 'error', 'Hay un producto del reparto que no existe en esta sucursal');
  END IF;
$a$,
$r$    RETURN jsonb_build_object('success', false, 'error', 'Hay un producto del reparto que no existe en esta sucursal');
  END IF;
  -- PRM-A (#1556): la regla de sustituir_regalo_pedido (mig 295, #950). Pasar el regalo
  -- a un producto de otra categoría es decisión del dueño: sólo el admin, también
  -- repartiéndolo. Mismo criterio (contra el producto de la línea) y mismo mensaje.
  IF v_user_role IS DISTINCT FROM 'admin'
     AND EXISTS (SELECT 1 FROM unnest(v_prod) AS r(producto_id)
                  WHERE r.producto_id IS DISTINCT FROM v_item.producto_id
                    AND NOT public.regalo_misma_categoria(v_item.producto_id, r.producto_id, v_sucursal)) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Solo un admin puede cambiar el regalo por un producto de otra categoría');
  END IF;
$r$, 'dividir_regalo_pedido (categoría)');

  v_def := pg_temp.parche(v_def,
$a$  FOR v_parte IN SELECT r.orden, r.producto_id, r.cantidad, pr.nombre
$a$,
$r$  -- PRM-D (#1556): el corte de cada parte es su cantidad, que está en la unidad de la
  -- promo (arriba se rechaza la línea cambiada por valor). Lo escribe acá, a mano.
  PERFORM set_config('app.regalo_corte_manual', '1', true);
  FOR v_parte IN SELECT r.orden, r.producto_id, r.cantidad, pr.nombre
$r$, 'dividir_regalo_pedido (marca del corte)');

  v_def := pg_temp.parche(v_def,
$a$             cantidad = v_parte.cantidad::int,
             subtotal = 0,
$a$,
$r$             cantidad = v_parte.cantidad::int,
             regalo_corte = v_parte.cantidad::int,
             subtotal = 0,
$r$, 'dividir_regalo_pedido (corte de la línea)');

  v_def := pg_temp.parche(v_def,
$a$        costo_unitario_al_crear, regalo_cadena_id
      ) VALUES (
$a$,
$r$        costo_unitario_al_crear, regalo_cadena_id, regalo_corte
      ) VALUES (
$r$, 'dividir_regalo_pedido (columnas de la parte)');

  v_def := pg_temp.parche(v_def,
$a$        v_cadenas[v_parte.orden]
      ) RETURNING id INTO v_nuevo_id;
      v_item_ids := v_item_ids || v_nuevo_id;
    END IF;
  END LOOP;
$a$,
$r$        v_cadenas[v_parte.orden], v_parte.cantidad::int
      ) RETURNING id INTO v_nuevo_id;
      v_item_ids := v_item_ids || v_nuevo_id;
    END IF;
  END LOOP;
  PERFORM set_config('app.regalo_corte_manual', '', true);
$r$, 'dividir_regalo_pedido (valores de la parte)');

  EXECUTE v_def;
END
$parche_dividir$;

-- =========================================================================
-- 2 · PRM-B · la barra reiniciada no cuenta los pedidos del tramo anterior
-- =========================================================================
ALTER TABLE public.pedido_promo_reglas
  ADD COLUMN barra_anterior boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.pedido_promo_reglas.barra_anterior IS
  'El regalo de este pedido entró en una barra de fracción que se reinició después (#1556, PRM-B): al pasar la promo de unidad entera a fracción, trg_promo_tipo_reinicia_barra la pone en true en las fotos de fracción que existen. _regalo_barra_vale da false con ella: el pedido no le resta ni le suma a la barra nueva. No se borra al editar.';

CREATE OR REPLACE FUNCTION public.promo_tipo_reinicia_barra()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  NEW.usos_pendientes := 0;
  UPDATE promo_acumuladores
     SET usos_pendientes = 0, updated_at = now()
   WHERE promocion_id = NEW.id AND sucursal_id = NEW.sucursal_id AND usos_pendientes <> 0;
  -- PRM-B (#1556): los pedidos de fracción que ya existen entraron en la barra que se
  -- acaba de tirar, no en la nueva. Sin la marca, su foto (fracción) coincide otra vez con
  -- la promo y _regalo_barra_vale los dejaba restarle a la barra nueva lo que nunca entró:
  -- un fardo fantasma al cancelarlos o al editarlos sin el regalo.
  UPDATE pedido_promo_reglas
     SET barra_anterior = true
   WHERE promocion_id = NEW.id AND sucursal_id = NEW.sucursal_id
     AND NOT regalo_mueve_stock AND NOT barra_anterior;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public._regalo_barra_vale(p_pedido_id bigint, p_promocion_id bigint, p_sucursal_id bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  -- #1324: la barra es de la promo viva, y una línea de otro modo no entró en ella.
  -- PRM-B (#1556): tampoco una de un tramo de fracción anterior a un reinicio de la barra.
  SELECT COALESCE(
    (SELECT COALESCE(public._regalo_modo_del_pedido(p_pedido_id, p_promocion_id, p_sucursal_id), false)
              = COALESCE(p.regalo_mueve_stock, false)
            AND NOT EXISTS (SELECT 1 FROM pedido_promo_reglas f
                             WHERE f.pedido_id = p_pedido_id AND f.promocion_id = p_promocion_id
                               AND f.sucursal_id = p_sucursal_id AND f.barra_anterior)
       FROM promociones p
      WHERE p.id = p_promocion_id AND p.sucursal_id = p_sucursal_id),
    false);
$function$;

-- =========================================================================
-- 3 · PRM-C · _combo_rehacer no rearma por encima del tope
-- =========================================================================
CREATE OR REPLACE FUNCTION public._combo_rehacer(p_pedido_id bigint, p_sucursal bigint, p_combo_id bigint, p_excluir bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_e        jsonb;
  v_plan     jsonb;
  v_tope     integer;
  v_nombre   text;
  v_vendidos bigint;
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

  -- PRM-C (#1556): rearmar más combos de los que el pedido tenía (anular una salvedad que
  -- rompió uno) no puede pasar el tope: el lugar que liberó la salvedad puede haberlo
  -- tomado otro pedido. Se cuenta como el alta (combo_fuera_de_regla), con el combo
  -- bloqueado, y se rechaza con su motivo: la operación entera se deshace, como la anulación
  -- que choca con el cupo de una promo. Bajar combos (la salvedad) no se mira.
  -- NOWAIT: quien llega acá ya tiene los productos de la línea, y el alta toma el combo
  -- antes que sus productos. Esperarlo sería un 40P01 contra un alta del mismo combo.
  IF (v_plan->>'combos')::int > COALESCE((v_e->>'cantidad_combos')::int, 0) THEN
    SELECT c.tope_combos, c.nombre INTO v_tope, v_nombre
      FROM combos c
     WHERE c.id = p_combo_id AND c.sucursal_id = p_sucursal;
    IF v_tope IS NOT NULL THEN
      BEGIN
        PERFORM 1 FROM combos WHERE id = p_combo_id AND sucursal_id = p_sucursal FOR UPDATE NOWAIT;
      EXCEPTION WHEN lock_not_available THEN
        RAISE EXCEPTION 'Otro pedido está tomando el combo "%" en este momento: probá de nuevo en unos segundos.', v_nombre
          USING ERRCODE = '55P03';
      END;
      SELECT COALESCE(sum(f.cantidad_combos), 0) INTO v_vendidos
        FROM pedido_combos f
        JOIN pedidos p ON p.id = f.pedido_id AND p.sucursal_id = f.sucursal_id
       WHERE f.combo_id = p_combo_id AND f.sucursal_id = p_sucursal
         AND p.estado <> 'cancelado'
         AND f.pedido_id <> p_pedido_id;
      IF v_vendidos + (v_plan->>'combos')::int > v_tope THEN
        RAISE EXCEPTION 'El combo "%" llegó a su tope: quedan %, y volver a armarlo en este pedido lleva %.',
          v_nombre, GREATEST(v_tope - v_vendidos, 0), (v_plan->>'combos')::int
          USING HINT = 'El lugar que había liberado la salvedad ya lo tomó otro pedido. Sacá ese combo de otro pedido, o pedile al admin que suba el tope.';
      END IF;
    END IF;
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
$function$;

-- =========================================================================
-- 4 · PRM-D · el corte de cada línea de regalo
-- =========================================================================
ALTER TABLE public.pedido_items
  ADD COLUMN regalo_corte integer,
  ADD CONSTRAINT pedido_items_regalo_corte_check CHECK (regalo_corte IS NULL OR regalo_corte >= 0);

COMMENT ON COLUMN public.pedido_items.regalo_corte IS
  'Lo que da la promo por esta línea de regalo, en su unidad: el corte (#1556, PRM-D). Es lo que cuenta el cupo (_promo_usos), no la cantidad entregada: una línea cambiada por valor (R×14 → W×1) sigue contando 14. NULL fuera de los regalos de promo. Lo sella sellar_corte_regalo_item; sustituir, dividir y el cambio de cliente lo escriben con app.regalo_corte_manual. No lo lee el front.';

CREATE FUNCTION public.sellar_corte_regalo_item()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_eslabones jsonb;
BEGIN
  -- PRM-D (#1556): el corte de la línea, lo que cuenta el cupo. DEFINER porque las cadenas
  -- (pedido_item_sustituciones) se leen como en aplicar_sustituciones_regalo_pre_insert.
  IF NOT (COALESCE(NEW.es_bonificacion, false) AND NEW.promocion_id IS NOT NULL) THEN
    NEW.regalo_corte := NULL;
    RETURN NEW;
  END IF;

  -- Lo escribe quien lo sabe: sustituir (lo conserva), dividir (cada parte) y el cambio de
  -- cliente (el de la línea de X). Sin la marca, lo escrito a mano se vuelve a calcular.
  IF current_setting('app.regalo_corte_manual', true) = '1' AND NEW.regalo_corte IS NOT NULL THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    -- Este trigger corre antes que trg_aplicar_sustituciones_regalo (por el nombre): la
    -- cantidad es la que mandó quien inserta, en la unidad de la promo. Una línea conservada
    -- de un reparto se reinserta en la unidad de su parte, y su corte es el de la parte.
    IF current_setting('app.regalo_linea_conservada', true) = '1' THEN
      NEW.regalo_corte := round(public.regalo_cantidad_base(
                            public.regalo_eslabones(NEW.pedido_id, NEW.promocion_id, NEW.sucursal_id),
                            NEW.regalo_cadena_id, NEW.cantidad))::integer;
    ELSE
      NEW.regalo_corte := NEW.cantidad;
    END IF;
    RETURN NEW;
  END IF;

  -- Un UPDATE de la cantidad (la salvedad): el corte cambia lo que cambió la cantidad
  -- medida en cortes con la cadena de la línea. En un regalo sin cambio por valor es exacto.
  IF NEW.regalo_cadena_id IS NOT NULL OR OLD.regalo_cadena_id IS NOT NULL THEN
    v_eslabones := public.regalo_eslabones(NEW.pedido_id, NEW.promocion_id, NEW.sucursal_id);
  END IF;
  IF COALESCE(OLD.es_bonificacion, false) AND OLD.promocion_id IS NOT DISTINCT FROM NEW.promocion_id
     AND OLD.regalo_corte IS NOT NULL THEN
    NEW.regalo_corte := GREATEST(0,
      OLD.regalo_corte
      + public.regalo_usos_de_linea(v_eslabones, NEW.regalo_cadena_id, NEW.cantidad)
      - public.regalo_usos_de_linea(v_eslabones, OLD.regalo_cadena_id, OLD.cantidad))::integer;
  ELSE
    NEW.regalo_corte := public.regalo_usos_de_linea(v_eslabones, NEW.regalo_cadena_id, NEW.cantidad)::integer;
  END IF;
  RETURN NEW;
END
$function$;

-- Es de trigger: no necesita EXECUTE para nadie de la app.
REVOKE ALL ON FUNCTION public.sellar_corte_regalo_item() FROM PUBLIC, anon, authenticated;

-- Las líneas que ya existen, antes del trigger y sin la auditoría (no es una edición de
-- nadie): lo que hoy cuenta el cupo. El ALTER TABLE de arriba ya tiene la tabla tomada.
ALTER TABLE public.pedido_items DISABLE TRIGGER audit_pedido_items;
UPDATE public.pedido_items
   SET regalo_corte = public.regalo_usos_de_linea(
                        CASE WHEN regalo_cadena_id IS NOT NULL
                             THEN public.regalo_eslabones(pedido_id, promocion_id, sucursal_id) END,
                        regalo_cadena_id, cantidad)::integer
 WHERE COALESCE(es_bonificacion, false) AND promocion_id IS NOT NULL;
ALTER TABLE public.pedido_items ENABLE TRIGGER audit_pedido_items;

-- El nombre importa: los BEFORE INSERT corren por nombre, y éste tiene que ver la cantidad
-- antes que trg_aplicar_sustituciones_regalo la convierta.
CREATE TRIGGER pedido_items_regalo_corte
  BEFORE INSERT OR UPDATE OF cantidad, es_bonificacion, promocion_id, regalo_corte
  ON public.pedido_items
  FOR EACH ROW EXECUTE FUNCTION public.sellar_corte_regalo_item();

CREATE OR REPLACE FUNCTION public._promo_usos(p_promocion_id bigint, p_pedido_id bigint DEFAULT NULL::bigint)
 RETURNS TABLE(usos bigint, del_pedido bigint)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  -- #1300: un uso es el corte. PRM-D (#1556): el que guarda la línea (regalo_corte), no el
  -- que se deduce deshaciendo la cadena desde la cantidad de hoy: un cambio por valor que
  -- achica (R×10 -> W×1) pierde la cantidad. Sin él, se deduce como antes.
  SELECT COALESCE(sum(l.usos), 0)::bigint,
         COALESCE(sum(l.usos) FILTER (WHERE l.pedido_id = p_pedido_id), 0)::bigint
    FROM (SELECT pi.pedido_id,
                 COALESCE(pi.regalo_corte,
                   public.regalo_usos_de_linea(
                     CASE WHEN pi.regalo_cadena_id IS NOT NULL
                          THEN public.regalo_eslabones(pi.pedido_id, pi.promocion_id, pi.sucursal_id) END,
                     pi.regalo_cadena_id, pi.cantidad)) AS usos
            FROM pedido_items pi
            JOIN pedidos p ON p.id = pi.pedido_id
           WHERE pi.promocion_id = p_promocion_id
             AND pi.es_bonificacion
             AND p.estado <> 'cancelado') l;
$function$;

-- sustituir_regalo_pedido: sustituir no mueve el cupo, el corte se queda.
DO $parche_sustituir$
DECLARE
  v_def text := pg_get_functiondef('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  v_cadena := COALESCE(v_item.regalo_cadena_id, gen_random_uuid());
  UPDATE pedido_items
$a$,
$r$  v_cadena := COALESCE(v_item.regalo_cadena_id, gen_random_uuid());
  -- PRM-D (#1556): sustituir no mueve el cupo. El corte de la línea (regalo_corte) se queda
  -- como estaba: la marca le dice al trigger que no lo vuelva a calcular con la cantidad nueva.
  PERFORM set_config('app.regalo_corte_manual', '1', true);
  UPDATE pedido_items
$r$, 'sustituir_regalo_pedido (marca del corte)');

  v_def := pg_temp.parche(v_def,
$a$                                     WHERE id = p_producto_nuevo_id AND sucursal_id = v_sucursal)
   WHERE id = p_pedido_item_id;
$a$,
$r$                                     WHERE id = p_producto_nuevo_id AND sucursal_id = v_sucursal)
   WHERE id = p_pedido_item_id;
  PERFORM set_config('app.regalo_corte_manual', '', true);
$r$, 'sustituir_regalo_pedido (fin de la marca)');

  EXECUTE v_def;
END
$parche_sustituir$;

-- cambiar_cliente_pedido: la línea nueva hereda el corte de la de X, como su cadena.
DO $parche_cambio_cliente$
DECLARE
  v_def text := pg_get_functiondef('public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$      SELECT n.id AS nuevo, o.regalo_cadena_id AS cadena, o.descripcion_regalo
$a$,
$r$      SELECT n.id AS nuevo, o.id AS viejo, o.regalo_cadena_id AS cadena, o.descripcion_regalo
$r$, 'cambiar_cliente_pedido (la línea de X)');

  v_def := pg_temp.parche(v_def,
$a$      UPDATE pedido_items
         SET regalo_cadena_id   = v_cadena_nueva,
             descripcion_regalo = v_par.descripcion_regalo
       WHERE id = v_par.nuevo;
$a$,
$r$      -- PRM-D (#1556): y su corte. El alta la insertó con la cantidad de X, que en una línea
      -- cambiada por valor es la del sustituto, no lo que da la promo.
      PERFORM set_config('app.regalo_corte_manual', '1', true);
      UPDATE pedido_items
         SET regalo_cadena_id   = v_cadena_nueva,
             descripcion_regalo = v_par.descripcion_regalo,
             regalo_corte       = COALESCE((SELECT o.regalo_corte FROM pedido_items o
                                             WHERE o.id = v_par.viejo AND o.sucursal_id = v_sucursal),
                                           regalo_corte)
       WHERE id = v_par.nuevo;
      PERFORM set_config('app.regalo_corte_manual', '', true);
$r$, 'cambiar_cliente_pedido (el corte)');

  EXECUTE v_def;
END
$parche_cambio_cliente$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, el definer y los EXECUTE quedaron como en el repo,
-- las columnas sin SELECT para la app y todos los regalos con su corte
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)', '81e56ea614d582b4719ff6f405884d53', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)', '0dc69aa6a22ad0ec698147008fd5b498', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)', '5ca686d53a299f1bec98e5b16e4fe68c', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public._combo_rehacer(bigint,bigint,bigint,bigint)', '1f4a8e8823640bbcd71cddadd5eeace0', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._regalo_barra_vale(bigint,bigint,bigint)', 'f4ff91437fd7892000d71732f57daa13', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.promo_tipo_reinicia_barra()', 'babeac68e20c09aff1fa55bffd038ace', true,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._promo_usos(bigint,bigint)', '85158451c18d057942eac88ba2960f74', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.sellar_corte_regalo_item()', 'fa5740d521e0e61d9c6760aa61ee25aa', true,
     '{postgres=X/postgres,service_role=X/postgres}')
  ) AS t(f, h, def, acl) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO x
      FROM pg_proc WHERE oid = r.f::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %)', r.f, x.h, x.a, x.def;
    END IF;
  END LOOP;

  IF has_column_privilege('authenticated', 'public.pedido_items', 'regalo_corte', 'SELECT')
     OR has_column_privilege('anon', 'public.pedido_items', 'regalo_corte', 'SELECT')
     OR has_column_privilege('authenticated', 'public.pedido_promo_reglas', 'barra_anterior', 'SELECT')
     OR has_column_privilege('anon', 'public.pedido_promo_reglas', 'barra_anterior', 'SELECT') THEN
    RAISE EXCEPTION 'mig NNN · las columnas nuevas no son sólo de server';
  END IF;

  IF EXISTS (SELECT 1 FROM public.pedido_items
              WHERE COALESCE(es_bonificacion, false) AND promocion_id IS NOT NULL
                AND regalo_corte IS NULL)
     OR EXISTS (SELECT 1 FROM public.pedido_items
                 WHERE NOT (COALESCE(es_bonificacion, false) AND promocion_id IS NOT NULL)
                   AND regalo_corte IS NOT NULL) THEN
    RAISE EXCEPTION 'mig NNN · hay regalos de promo sin corte, o líneas con corte que no son regalos de promo';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.pedido_items'::regclass
                    AND tgname = 'pedido_items_regalo_corte' AND tgenabled = 'O')
     OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.pedido_items'::regclass
                       AND tgname = 'audit_pedido_items' AND tgenabled = 'O') THEN
    RAISE EXCEPTION 'mig NNN · el trigger del corte o el de la auditoría no quedaron habilitados';
  END IF;
END
$post$;

COMMIT;
