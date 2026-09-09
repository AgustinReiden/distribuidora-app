-- =========================================================================
-- El factor de fraccion tiene UNA SOLA fuente viva
--
-- EL BUG (issue #535)
-- -------------------
-- Despues de la mig 212 el factor esta en tres lugares y cada consumidor lee
-- uno distinto. Editarlo desde ModalPromocion mueve `promociones` y no toca
-- `promo_acumuladores`, sin que falle nada ni avise nadie.
--
-- LO QUE LA AUDITORIA ENCONTRO (contra el codigo VIVO, no contra migrations/)
-- --------------------------------------------------------------------------
-- 1. El acumulador NO esta en el camino principal del stock. Solo dos
--    funciones tocan `promo_acumuladores`: esta misma y sustituir_regalo_pedido.
--    Los cuatro caminos que descuentan stock de verdad -- crear_pedido_completo,
--    crear_pedido_completo_bot, actualizar_pedido_items y
--    revertir_bloques_auto_ajuste -- leen `promociones` EN VIVO y no lo miran.
--    Es la estrategia de "minimo invasivo" que la mig 059 declaro explicitamente.
--
-- 2. aplicar_uso_promo_acumulador ya se contradice sola: el GATE lee
--    v_promo.unidades_por_bloque (vivo) y la ARITMETICA lee
--    v_acc.unidades_por_bloque (congelado). No hay una postura "el acumulador
--    congela el factor" que defender: la funcion cree las dos mitades a la vez.
--
-- 3. La copia nunca divergio. 11 filas de acumulador en prod:
--    `unidades_por_bloque` difiere del vivo en 0 y `stock_por_bloque` en 0.
--    Pero `ajuste_producto_id` difiere en 7 -- ese SI es dato por fila (el
--    contenedor que eligio el admin para cada sabor sustituido).
--    De las tres columnas de config copiadas, una es dato y dos son cache.
--
-- 4. El "carry forward" ya es el comportamiento vivo: crear_pedido_completo
--    renormaliza el resto con el N VIVO en cada pedido. Bajar el factor con
--    resto abierto YA cierra un bloque en el proximo pedido. Nadie lo eligio.
--
-- LA DECISION
-- -----------
-- Dos fuentes con roles distintos, ninguna tercera copia:
--   VIVO             promociones.unidades_por_bloque / .stock_por_bloque
--                    -> gobierna que pasa AHORA
--   CONGELADO X ITEM pedido_items.unidades_por_bloque_al_crear (mig 212)
--                    -> gobierna que dice la HISTORIA
--
-- Se dropean promo_acumuladores.unidades_por_bloque y .stock_por_bloque: eran
-- cache, no congelado. Se QUEDAN ajuste_producto_id y usos_pendientes.
--
-- OJO CON EL ERROR INVERSO: las tres columnas copiadas se ven iguales y se
-- resuelven al reves. Dropear tambien `ajuste_producto_id` rompe las barras
-- paralelas, que son la razon de existir de la tabla.
--
-- QUIEN MANDA EN LA BARRA DEFAULT
-- -------------------------------
-- `promociones.usos_pendientes`. Los 4 caminos de stock la usan y no conocen
-- el acumulador; la promo 12 no tiene fila de acumulador para su regalo default
-- (96), asi que ahi la barra existe SOLO en `promociones`; y VistaPromociones
-- ya muestra ese valor.
-- De ahi la regla que evita el doble descuento: el trigger toca
-- `promociones.usos_pendientes` y las filas de acumulador de SUSTITUTOS
-- unicamente. La fila del regalo default no la toca nunca -- ni la espeja ni la
-- cierra. Espejarla haria desaparecer los 4 de la promo 13 sin mover un fardo.
-- Ese desacuerdo es preexistente y va en el issue #553.
--
-- RIESGO: bajo. Solo 5 promos fraccionan (factores 6 y 12) y una sola esta
-- activa (la 13). El factor nunca cambio en toda la historia: 651 mediciones en
-- promo_ajustes con min = max = valor vivo (ver mig 212). Este bug es real pero
-- nunca se disparo.
--
-- QUE SE PROBO ANTES DE APLICAR (2026-09-09)
-- ------------------------------------------
-- La migracion entera se corrio contra los datos REALES de prod dentro de una
-- transaccion terminada en ROLLBACK, con siete casos sobre la promo 13 (factor
-- 6; barras sustitutas 78 -> 0, 79 -> 0, 80 -> 2, 81 -> 4, 83 -> 2):
--   1. Bajar 6 -> 2 cierra 1+2+1 bloques y descuenta 1, 2 y 1 del contenedor de
--      cada barra. La fila de acumulador del regalo DEFAULT (82, resto 4) queda
--      intacta y su contenedor no se mueve: es la regla del doble descuento.
--   2. Subir 2 -> 12 no mueve un solo fardo, pero deja la constancia igual.
--   3. N -> NULL deja el resto intacto y no mueve stock.
--   4. Un UPDATE que no toca esas columnas (renombrar la promo) no dispara nada.
--   5. Reescribir el MISMO valor tampoco -- es lo que hace updatePromocion en
--      cada guardado, y sin el WHEN seria una fila de ajuste por edicion.
--   6. Lo que promete previsualizar_cambio_factor es lo que despues hace el
--      trigger (misma aritmetica, un solo bloques_a_cerrar).
--   7. aplicar_uso_promo_acumulador sin la copia usa el factor VIVO: con N = 2 y
--      resto 0, un delta de +2 cierra bloque -- con la copia vieja (6) no habria
--      cerrado nada.
-- Control negativo hecho aparte: un RAISE EXCEPTION dentro del mismo mecanismo
-- vuelve como error, o sea que "paso" significa algo.
--
-- COMO SE REVIERTE: re-agregar las dos columnas, backfillearlas desde
-- `promociones` (que es de donde salieron y con lo que siempre coincidieron),
-- dropear el trigger y volver a la version anterior de las dos funciones.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1 - Parche por ancla sobre el cuerpo VIVO.
--
--     migrations/ no es espejo de prod: sustituir_regalo_pedido fue redefinida
--     varias veces despues de la 059 (hoy tiene v_ajuste_sustituto_efectivo y
--     el snapshot de costo_unitario_al_crear, que la 059 no tenia). Copiar el
--     cuerpo del archivo revertiria logica viva en silencio. Mismo mecanismo
--     que uso la mig 212.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._mig220_reemplazar_ancla(
  p_funcion regprocedure,
  p_ancla   text,
  p_nuevo   text
)
RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text;
  v_veces int;
BEGIN
  v_def := pg_get_functiondef(p_funcion);

  v_veces := (length(v_def) - length(replace(v_def, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El ancla aparece % veces en % (se esperaba exactamente 1). El cuerpo vivo cambio: revisar a mano.',
      v_veces, p_funcion;
  END IF;

  EXECUTE replace(v_def, p_ancla, p_nuevo);
END;
$fn$;

-- sustituir_regalo_pedido crea la entry default cuando no existe, copiando las
-- dos columnas de config. Sin ese INSERT el DROP de mas abajo la rompe en
-- runtime (y no falla ni en tsc ni en los tests).
DO $patch$
DECLARE
  v_fn regprocedure;
BEGIN
  SELECT p.oid::regprocedure INTO v_fn
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
                   AND p.proname = 'sustituir_regalo_pedido';

  PERFORM public._mig220_reemplazar_ancla(
    v_fn,
    E'        INSERT INTO promo_acumuladores (promocion_id, producto_regalo_id, ajuste_producto_id,\n'
    || E'          unidades_por_bloque, stock_por_bloque, usos_pendientes, sucursal_id)\n'
    || E'        VALUES (v_promo.id, v_promo.producto_regalo_id, v_promo.ajuste_producto_id,\n'
    || E'          v_promo.unidades_por_bloque, v_promo.stock_por_bloque, COALESCE(v_promo.usos_pendientes, 0), v_sucursal)',
    E'        INSERT INTO promo_acumuladores (promocion_id, producto_regalo_id, ajuste_producto_id,\n'
    || E'          usos_pendientes, sucursal_id)\n'
    || E'        VALUES (v_promo.id, v_promo.producto_regalo_id, v_promo.ajuste_producto_id,\n'
    || E'          COALESCE(v_promo.usos_pendientes, 0), v_sucursal)'
  );
END
$patch$;

DROP FUNCTION public._mig220_reemplazar_ancla(regprocedure, text, text);

-- -------------------------------------------------------------------------
-- 2 - aplicar_uso_promo_acumulador deja de leer la copia.
--
--     Unico cambio respecto del cuerpo vivo: donde decia v_acc.unidades_por_bloque
--     y v_acc.stock_por_bloque ahora dice v_promo.*, que es lo que la funcion YA
--     leia para su propio gate tres lineas mas arriba. El resto del cuerpo
--     (semantica de resto con clamp de la mig 091, mermas, promo_ajustes,
--     convencion de signos) queda igual.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.aplicar_uso_promo_acumulador(
  p_promocion_id bigint,
  p_producto_regalo_id bigint,
  p_delta numeric,
  p_ajuste_producto_id_def bigint,
  p_sucursal_id bigint,
  p_usuario_id uuid,
  p_motivo text
) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_promo          RECORD;
  v_acc            RECORD;
  v_usos_raw       NUMERIC;
  v_blocks         INT;
  v_usos_final     NUMERIC;
  v_stock_delta    INT;
  v_usos_ajustados INT;
  v_stock_anterior INT;
  v_stock_nuevo    INT;
  v_merma_id       BIGINT;
BEGIN
  SELECT id, unidades_por_bloque, stock_por_bloque, ajuste_automatico,
         ajuste_producto_id, regalo_mueve_stock
    INTO v_promo
    FROM promociones
   WHERE id = p_promocion_id AND sucursal_id = p_sucursal_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('aplicado', false, 'razon', 'promo no encontrada');
  END IF;
  IF NOT COALESCE(v_promo.ajuste_automatico, FALSE) THEN
    RETURN jsonb_build_object('aplicado', false, 'razon', 'promo no es modo B');
  END IF;
  IF COALESCE(v_promo.unidades_por_bloque, 0) <= 0
     OR COALESCE(v_promo.stock_por_bloque, 0) <= 0 THEN
    RETURN jsonb_build_object('aplicado', false, 'razon', 'config bloque invalida');
  END IF;

  SELECT id, ajuste_producto_id, usos_pendientes
    INTO v_acc
    FROM promo_acumuladores
   WHERE promocion_id = p_promocion_id
     AND producto_regalo_id = p_producto_regalo_id
     AND sucursal_id = p_sucursal_id
   FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO promo_acumuladores (
      promocion_id, producto_regalo_id, ajuste_producto_id,
      usos_pendientes, sucursal_id
    ) VALUES (
      p_promocion_id, p_producto_regalo_id, p_ajuste_producto_id_def,
      0, p_sucursal_id
    )
    ON CONFLICT (promocion_id, producto_regalo_id, sucursal_id) DO NOTHING;
    SELECT id, ajuste_producto_id, usos_pendientes
      INTO v_acc
      FROM promo_acumuladores
     WHERE promocion_id = p_promocion_id
       AND producto_regalo_id = p_producto_regalo_id
       AND sucursal_id = p_sucursal_id
     FOR UPDATE;
  END IF;

  -- Semantica de RESTO con clamp: usos_pendientes SIEMPRE queda en [0, N).
  v_usos_raw := COALESCE(v_acc.usos_pendientes, 0) + p_delta;
  IF v_usos_raw >= 0 THEN
    v_blocks      := FLOOR(v_usos_raw / v_promo.unidades_por_bloque)::INT;
    v_usos_final  := v_usos_raw - (v_blocks * v_promo.unidades_por_bloque);
    v_stock_delta := -(v_blocks * v_promo.stock_por_bloque);
    v_usos_ajustados := v_blocks * v_promo.unidades_por_bloque;
  ELSE
    v_blocks      := CEIL(ABS(v_usos_raw) / v_promo.unidades_por_bloque)::INT;
    v_usos_final  := v_usos_raw + (v_blocks * v_promo.unidades_por_bloque);
    v_stock_delta := (v_blocks * v_promo.stock_por_bloque);
    v_usos_ajustados := -(v_blocks * v_promo.unidades_por_bloque);
  END IF;

  UPDATE promo_acumuladores
     SET usos_pendientes = v_usos_final, updated_at = NOW()
   WHERE id = v_acc.id;

  IF v_stock_delta <> 0 AND v_acc.ajuste_producto_id IS NOT NULL THEN
    PERFORM set_config('app.stock_origen', 'auto_ajuste_promo', true);
    PERFORM set_config('app.stock_ref_tipo', 'promocion', true);
    PERFORM set_config('app.stock_ref_id', p_promocion_id::TEXT, true);
    PERFORM set_config('app.stock_user_id', p_usuario_id::TEXT, true);

    SELECT stock INTO v_stock_anterior
      FROM productos
     WHERE id = v_acc.ajuste_producto_id AND sucursal_id = p_sucursal_id
     FOR UPDATE;
    v_stock_nuevo := COALESCE(v_stock_anterior, 0) + v_stock_delta;

    UPDATE productos SET stock = v_stock_nuevo, updated_at = NOW()
     WHERE id = v_acc.ajuste_producto_id AND sucursal_id = p_sucursal_id;

    INSERT INTO mermas_stock (
      producto_id, cantidad, motivo, observaciones,
      stock_anterior, stock_nuevo, usuario_id, sucursal_id
    ) VALUES (
      v_acc.ajuste_producto_id,
      -v_stock_delta,
      CASE WHEN v_stock_delta < 0 THEN 'promociones' ELSE 'promociones_reversion' END,
      p_motivo, COALESCE(v_stock_anterior, 0), v_stock_nuevo, p_usuario_id, p_sucursal_id
    ) RETURNING id INTO v_merma_id;

    INSERT INTO promo_ajustes (
      promocion_id, usos_ajustados, unidades_ajustadas,
      producto_id, merma_id, usuario_id, observaciones, sucursal_id
    ) VALUES (
      p_promocion_id, v_usos_ajustados, -v_stock_delta,
      v_acc.ajuste_producto_id, v_merma_id, p_usuario_id, p_motivo, p_sucursal_id
    );
  END IF;

  RETURN jsonb_build_object(
    'aplicado', true,
    'acumulador_id', v_acc.id,
    'usos_pendientes', v_usos_final,
    'bloques_delta', CASE WHEN v_stock_delta < 0 THEN v_blocks ELSE -v_blocks END
  );
END;
$function$;

ALTER FUNCTION public.aplicar_uso_promo_acumulador(BIGINT, BIGINT, NUMERIC, BIGINT, BIGINT, UUID, TEXT)
  OWNER TO postgres;

COMMENT ON FUNCTION public.aplicar_uso_promo_acumulador(BIGINT, BIGINT, NUMERIC, BIGINT, BIGINT, UUID, TEXT) IS
  'Aplica delta al acumulador (promo,producto_regalo,sucursal). El factor y el '
  'stock por bloque salen SIEMPRE de promociones en vivo: el acumulador solo '
  'guarda el resto y el contenedor de esa barra.';

-- -------------------------------------------------------------------------
-- 3 - Se van las dos copias.
-- -------------------------------------------------------------------------
ALTER TABLE public.promo_acumuladores
  DROP COLUMN IF EXISTS unidades_por_bloque,
  DROP COLUMN IF EXISTS stock_por_bloque;

COMMENT ON COLUMN public.promo_acumuladores.ajuste_producto_id IS
  'Contenedor (fardo) de ESTA barra. Es dato por fila, no copia: difiere del '
  'ajuste_producto_id de la promo en 7 de 11 filas. NO dropear "por simetria" '
  'con unidades_por_bloque / stock_por_bloque, que si eran cache.';

COMMENT ON COLUMN public.promo_acumuladores.usos_pendientes IS
  'Resto de la barra, en [0, N) con N = promociones.unidades_por_bloque VIVO. '
  'La barra del regalo default de la promo NO vive aca sino en '
  'promociones.usos_pendientes (ver issue #553).';

-- -------------------------------------------------------------------------
-- 4 - La aritmetica de renormalizacion, en un solo lugar.
--     La usan el trigger (que escribe) y el preview (que solo mira), para que
--     lo que el modal promete y lo que la base hace no se puedan separar.
-- -------------------------------------------------------------------------
-- p_resto es NUMERIC, no INT: promo_acumuladores.usos_pendientes es
-- NUMERIC(10,2) y pedido_items.cantidad tambien, asi que un resto fraccionario
-- es posible. Con FLOOR nunca se cierra un bloque que la aritmetica exacta no
-- cerraria; con un cast a int, un resto de 5.5 con N = 6 redondearia a 6 y
-- cerraria un bloque de mas.
CREATE OR REPLACE FUNCTION public.bloques_a_cerrar(
  p_resto numeric,
  p_unidades_por_bloque integer
)
RETURNS integer
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $fn$
  SELECT CASE
    WHEN COALESCE(p_unidades_por_bloque, 0) <= 0 THEN 0
    ELSE FLOOR(GREATEST(COALESCE(p_resto, 0), 0) / p_unidades_por_bloque)::int
  END;
$fn$;

COMMENT ON FUNCTION public.bloques_a_cerrar(numeric, integer) IS
  'Bloques que un resto cierra bajo un factor dado. 0 si el factor no fracciona. '
  'Con N nuevo > N viejo siempre da 0, porque el resto vive en [0, N viejo).';

REVOKE ALL ON FUNCTION public.bloques_a_cerrar(numeric, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bloques_a_cerrar(numeric, integer) TO authenticated, service_role;

-- -------------------------------------------------------------------------
-- 5 - El trigger. Renormaliza las barras abiertas cuando cambia el factor.
--
--     Va en la tabla y no en una RPC para que no se pueda saltear: el modal,
--     una RPC futura, o un UPDATE a mano desde el editor SQL, todos pasan por
--     aca. Mismo criterio que el trigger de la mig 212.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.renormalizar_bloques_por_cambio_factor()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_usuario     UUID := auth.uid();
  v_n           INT  := NEW.unidades_por_bloque;
  v_spb         INT  := NEW.stock_por_bloque;
  v_obs         TEXT;
  v_barra       RECORD;
  v_bloques     INT;
  v_resto_final NUMERIC;
  v_unidades    INT;
  v_stock_ant   INT;
  v_stock_nue   INT;
  v_merma_id    BIGINT;
BEGIN
  -- El prefijo NO puede ser ninguno de los 5 que la mig 212 lee como medicion
  -- del factor vivo ('Auto-ajuste%', 'Cancelacion pedido #%', 'Eliminacion
  -- pedido #%', 'Edicion pedido #%', 'Salvedad%'), para que una arqueologia
  -- futura distinga una medicion de un cambio.
  v_obs := format('Cambio de factor: unidades_por_bloque %s -> %s, stock_por_bloque %s -> %s',
                  COALESCE(OLD.unidades_por_bloque::text, 'NULL'),
                  COALESCE(NEW.unidades_por_bloque::text, 'NULL'),
                  COALESCE(OLD.stock_por_bloque::text,   'NULL'),
                  COALESCE(NEW.stock_por_bloque::text,   'NULL'));

  -- Constancia del cambio, SIEMPRE, haya movido stock o no. Es la unica
  -- evidencia fechada que va a quedar: audit_log_changes no cubre `promociones`
  -- y `updated_at` es fecha de ultimo USO, no de edicion (mig 212).
  INSERT INTO promo_ajustes (promocion_id, usos_ajustados, usuario_id, observaciones, sucursal_id)
  VALUES (NEW.id, 0, v_usuario, v_obs, NEW.sucursal_id);

  -- Sin N nuevo no hay aritmetica posible: la promo dejo de fraccionar. El
  -- resto queda INTACTO y se renormaliza si la promo vuelve a fraccionar -- ese
  -- UPDATE dispara este mismo trigger. Es lo menos destructivo y es reversible.
  IF COALESCE(v_n, 0) <= 0 OR COALESCE(v_spb, 0) <= 0 THEN
    RETURN NULL;
  END IF;

  -- Las barras, en una sola lista. acc_id NULL = la barra default, que vive en
  -- promociones.usos_pendientes. Las filas de acumulador del regalo default
  -- quedan EXCLUIDAS a proposito: si no, se cerraria el mismo bloque dos veces.
  --
  -- Sin FOR UPDATE sobre promo_acumuladores: el UPDATE de `promociones` que
  -- disparo este trigger ya tiene la fila de la promo bloqueada, y
  -- aplicar_uso_promo_acumulador arranca con SELECT ... FROM promociones FOR
  -- UPDATE. Esa fila serializa los dos caminos.
  FOR v_barra IN
    SELECT NULL::bigint AS acc_id,
           GREATEST(COALESCE(NEW.usos_pendientes, 0), 0)::numeric AS resto,
           NEW.ajuste_producto_id AS contenedor
    UNION ALL
    SELECT a.id, GREATEST(COALESCE(a.usos_pendientes, 0), 0), a.ajuste_producto_id
      FROM promo_acumuladores a
     WHERE a.promocion_id = NEW.id
       AND a.sucursal_id  = NEW.sucursal_id
       AND a.producto_regalo_id IS DISTINCT FROM NEW.producto_regalo_id
  LOOP
    v_bloques := public.bloques_a_cerrar(v_barra.resto, v_n);
    CONTINUE WHEN v_bloques = 0;

    v_resto_final := v_barra.resto - (v_bloques * v_n);
    v_unidades    := v_bloques * v_spb;

    IF v_barra.acc_id IS NULL THEN
      -- No re-dispara este trigger: `usos_pendientes` no esta en la lista de
      -- columnas del UPDATE OF. Si dispara trg_check_promo_limite, que solo
      -- desactiva la promo cuando el resto SUBE hasta limite_usos -- y aca solo
      -- puede bajar.
      -- La columna es INT y su resto tambien, asi que el cast no pierde nada:
      -- la barra default nunca paso por la aritmetica NUMERIC del acumulador.
      UPDATE promociones SET usos_pendientes = v_resto_final::int
       WHERE id = NEW.id AND sucursal_id = NEW.sucursal_id;
    ELSE
      UPDATE promo_acumuladores SET usos_pendientes = v_resto_final, updated_at = NOW()
       WHERE id = v_barra.acc_id;
    END IF;

    CONTINUE WHEN v_barra.contenedor IS NULL;

    -- Contexto para el trigger registrar_cambio_stock (mig 038).
    PERFORM set_config('app.stock_origen', 'auto_ajuste_promo', true);
    PERFORM set_config('app.stock_ref_tipo', 'promocion', true);
    PERFORM set_config('app.stock_ref_id', NEW.id::TEXT, true);
    PERFORM set_config('app.stock_user_id', COALESCE(v_usuario::TEXT, ''), true);

    SELECT stock INTO v_stock_ant
      FROM productos
     WHERE id = v_barra.contenedor AND sucursal_id = NEW.sucursal_id
     FOR UPDATE;
    v_stock_nue := COALESCE(v_stock_ant, 0) - v_unidades;

    UPDATE productos SET stock = v_stock_nue, updated_at = NOW()
     WHERE id = v_barra.contenedor AND sucursal_id = NEW.sucursal_id;

    -- Misma convencion de signos que aplicar_uso_promo_acumulador:
    -- + = descuento, - = devolucion. Aca solo se cierran bloques, nunca se
    -- revierten, asi que siempre es positivo.
    INSERT INTO mermas_stock (
      producto_id, cantidad, motivo, observaciones,
      stock_anterior, stock_nuevo, usuario_id, sucursal_id
    ) VALUES (
      v_barra.contenedor, v_unidades, 'promociones', v_obs,
      COALESCE(v_stock_ant, 0), v_stock_nue, v_usuario, NEW.sucursal_id
    ) RETURNING id INTO v_merma_id;

    INSERT INTO promo_ajustes (
      promocion_id, usos_ajustados, unidades_ajustadas,
      producto_id, merma_id, usuario_id, observaciones, sucursal_id
    ) VALUES (
      NEW.id, v_bloques * v_n, v_unidades,
      v_barra.contenedor, v_merma_id, v_usuario, v_obs, NEW.sucursal_id
    );
  END LOOP;

  RETURN NULL;
END;
$fn$;

ALTER FUNCTION public.renormalizar_bloques_por_cambio_factor() OWNER TO postgres;

-- Funcion de trigger: no necesita EXECUTE para nadie, la invoca el executor
-- como parte del DML. Igual que completar_origen_precio_item (mig 148).
REVOKE ALL ON FUNCTION public.renormalizar_bloques_por_cambio_factor() FROM PUBLIC, anon, authenticated;

-- El WHEN no es opcional: updatePromocion escribe las 14 columnas en cada
-- guardado, asi que sin el, renombrar una promo dejaria una fila de "cambio de
-- factor" que no cambio nada.
DROP TRIGGER IF EXISTS trg_renormalizar_bloques_por_cambio_factor ON public.promociones;
CREATE TRIGGER trg_renormalizar_bloques_por_cambio_factor
  AFTER UPDATE OF unidades_por_bloque, stock_por_bloque ON public.promociones
  FOR EACH ROW
  WHEN (OLD.unidades_por_bloque IS DISTINCT FROM NEW.unidades_por_bloque
     OR OLD.stock_por_bloque    IS DISTINCT FROM NEW.stock_por_bloque)
  EXECUTE FUNCTION public.renormalizar_bloques_por_cambio_factor();

-- -------------------------------------------------------------------------
-- 6 - El preview que consume el modal. Read-only, misma aritmetica.
--     SECURITY INVOKER a proposito: las policies de SELECT de promociones,
--     promo_acumuladores y productos ya lo scopean por sucursal.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.previsualizar_cambio_factor(
  p_promocion_id        bigint,
  p_unidades_por_bloque integer,
  p_stock_por_bloque    integer
)
RETURNS TABLE (
  barra              text,
  producto_regalo_id bigint,
  producto_regalo    text,
  contenedor_id      bigint,
  contenedor         text,
  resto_actual       numeric,
  bloques_a_cerrar   integer,
  unidades_de_stock  integer,
  resto_final        numeric
)
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $fn$
  WITH promo AS (
    SELECT p.id, p.sucursal_id, p.producto_regalo_id, p.ajuste_producto_id,
           GREATEST(COALESCE(p.usos_pendientes, 0), 0)::numeric AS resto
      FROM promociones p
     WHERE p.id = p_promocion_id
  ),
  barras AS (
    SELECT 'default'::text AS barra, pr.producto_regalo_id AS regalo_id,
           pr.ajuste_producto_id AS cont_id, pr.resto, pr.sucursal_id
      FROM promo pr
    UNION ALL
    SELECT 'sustituto', a.producto_regalo_id, a.ajuste_producto_id,
           GREATEST(COALESCE(a.usos_pendientes, 0), 0), a.sucursal_id
      FROM promo_acumuladores a
      JOIN promo pr ON pr.id = a.promocion_id AND pr.sucursal_id = a.sucursal_id
     WHERE a.producto_regalo_id IS DISTINCT FROM pr.producto_regalo_id
  ),
  calc AS (
    SELECT b.*, public.bloques_a_cerrar(b.resto, p_unidades_por_bloque) AS bloques
      FROM barras b
  )
  SELECT c.barra,
         c.regalo_id,
         pg.nombre,
         c.cont_id,
         pc.nombre,
         c.resto,
         c.bloques,
         (c.bloques * COALESCE(p_stock_por_bloque, 0))::int,
         c.resto - (c.bloques * COALESCE(p_unidades_por_bloque, 0))
    FROM calc c
    LEFT JOIN productos pg ON pg.id = c.regalo_id AND pg.sucursal_id = c.sucursal_id
    LEFT JOIN productos pc ON pc.id = c.cont_id   AND pc.sucursal_id = c.sucursal_id
   ORDER BY c.barra, c.regalo_id;
$fn$;

COMMENT ON FUNCTION public.previsualizar_cambio_factor(bigint, integer, integer) IS
  'Que pasaria con las barras abiertas si el factor pasara a los valores dados. '
  'Sin efectos. Comparte la aritmetica con el trigger via bloques_a_cerrar.';

REVOKE ALL ON FUNCTION public.previsualizar_cambio_factor(bigint, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.previsualizar_cambio_factor(bigint, integer, integer) TO authenticated, service_role;

-- -------------------------------------------------------------------------
-- 7 - Verificacion.
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  v_cols  int;
  v_acl   text;
  v_trg   int;
  v_sobre int;
  v_def   text;
BEGIN
  -- La aritmetica, que es el corazon de todo esto. Sin datos: son propiedades
  -- de la funcion pura que comparten el trigger y el preview.
  IF public.bloques_a_cerrar(4, 2) <> 2 THEN
    RAISE EXCEPTION 'bloques_a_cerrar: resto 4 con N=2 tiene que dar 2 bloques.';
  END IF;
  IF public.bloques_a_cerrar(4, 6) <> 0 THEN
    RAISE EXCEPTION 'bloques_a_cerrar: subir el factor NUNCA puede cerrar un bloque.';
  END IF;
  IF public.bloques_a_cerrar(5.5, 6) <> 0 THEN
    RAISE EXCEPTION 'bloques_a_cerrar: un resto fraccionario no se redondea para arriba.';
  END IF;
  IF public.bloques_a_cerrar(4, 1) <> 4 THEN
    RAISE EXCEPTION 'bloques_a_cerrar: con N=1 cada unidad suelta es un bloque.';
  END IF;
  IF public.bloques_a_cerrar(4, NULL) <> 0 OR public.bloques_a_cerrar(4, 0) <> 0 THEN
    RAISE EXCEPTION 'bloques_a_cerrar: sin factor no hay aritmetica, tiene que dar 0.';
  END IF;
  IF public.bloques_a_cerrar(0, 6) <> 0 OR public.bloques_a_cerrar(NULL, 6) <> 0 THEN
    RAISE EXCEPTION 'bloques_a_cerrar: sin resto no se cierra nada.';
  END IF;

  -- Las dos copias se fueron y las dos columnas que son dato se quedaron.
  SELECT count(*) INTO v_cols FROM information_schema.columns
   WHERE table_schema='public' AND table_name='promo_acumuladores'
     AND column_name IN ('unidades_por_bloque','stock_por_bloque');
  IF v_cols <> 0 THEN
    RAISE EXCEPTION 'Quedaron % columna(s) de config en promo_acumuladores.', v_cols;
  END IF;

  SELECT count(*) INTO v_cols FROM information_schema.columns
   WHERE table_schema='public' AND table_name='promo_acumuladores'
     AND column_name IN ('ajuste_producto_id','usos_pendientes');
  IF v_cols <> 2 THEN
    RAISE EXCEPTION 'Faltan columnas de dato en promo_acumuladores (hay %, se esperaban 2).', v_cols;
  END IF;

  -- No quedo ninguna lectura de la copia en el cuerpo vivo de las dos funciones
  -- que tocan el acumulador.
  SELECT string_agg(p.proname, ', ') INTO v_acl
  FROM pg_proc p
  WHERE p.pronamespace='public'::regnamespace
    AND p.proname IN ('aplicar_uso_promo_acumulador','sustituir_regalo_pedido')
    AND pg_get_functiondef(p.oid) LIKE '%v_acc.unidades_por_bloque%';
  IF v_acl IS NOT NULL THEN
    RAISE EXCEPTION 'Quedo una lectura de la copia congelada en: %.', v_acl;
  END IF;

  -- El trigger existe, con la lista de columnas y el WHEN.
  SELECT count(*) INTO v_trg FROM pg_trigger t
   WHERE t.tgrelid='public.promociones'::regclass
     AND t.tgname='trg_renormalizar_bloques_por_cambio_factor';
  IF v_trg <> 1 THEN
    RAISE EXCEPTION 'El trigger de renormalizacion no quedo creado.';
  END IF;

  SELECT pg_get_triggerdef(t.oid) INTO v_def FROM pg_trigger t
   WHERE t.tgrelid='public.promociones'::regclass
     AND t.tgname='trg_renormalizar_bloques_por_cambio_factor';
  IF v_def NOT LIKE '%UPDATE OF unidades_por_bloque, stock_por_bloque%'
     OR v_def NOT LIKE '%WHEN%IS DISTINCT FROM%' THEN
    RAISE EXCEPTION 'El trigger quedo sin lista de columnas o sin WHEN: %', v_def;
  END IF;

  -- Una sola sobrecarga de cada funcion nueva: dos con rangos superpuestos dan
  -- PGRST203 en runtime, invisible para tsc y para los tests.
  SELECT count(*) INTO v_sobre FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace AND p.proname='previsualizar_cambio_factor';
  IF v_sobre <> 1 THEN
    RAISE EXCEPTION 'Hay % sobrecargas de previsualizar_cambio_factor.', v_sobre;
  END IF;

  -- El ACL de las dos funciones alcanzables quedo cerrado para anon y PUBLIC.
  SELECT array_to_string(array_agg(p.proname || ' -> ' || a::text), '; ') INTO v_acl
  FROM pg_proc p, unnest(p.proacl) a
  WHERE p.pronamespace='public'::regnamespace
    AND p.proname IN ('previsualizar_cambio_factor','bloques_a_cerrar',
                      'renormalizar_bloques_por_cambio_factor')
    AND (a::text LIKE '=%' OR a::text LIKE 'anon=%');
  IF v_acl IS NOT NULL THEN
    RAISE EXCEPTION 'Quedo una funcion ejecutable por anon o PUBLIC: %', v_acl;
  END IF;

  RAISE NOTICE 'OK: el factor tiene una sola fuente viva.';
END
$verif$;

COMMIT;
