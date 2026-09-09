-- =========================================================================
-- La barra del regalo default vive en un solo lugar
--
-- EL BUG (issue #553)
-- -------------------
-- El resto de la barra del regalo DEFAULT estaba en dos lugares que no
-- coincidian: `promociones.usos_pendientes` y la fila de `promo_acumuladores`
-- de ese mismo producto. VistaPromociones muestra el primero; el segundo vivia
-- en la matematica de sustitucion.
--
-- CUAL DE LOS DOS ERA EL CORRECTO
-- -------------------------------
-- Ninguno, sistematicamente. Comparando contra el valor DERIVADO del historial
-- (misma formula que uso la mig 091 §B: total regalado no cancelado, mod N):
--
--   promo  activa  derivado  promociones  acumulador
--     1      no        0         0 ok         0 ok
--    10      no        7         8 mal        7 ok
--    11      no        0         2 mal        0 ok
--    12      no        2        11 mal      (no existe)
--    13      SI        2         0 mal        4 mal
--
-- Las dos derivan, y ninguna gana siempre.
--
-- POR QUE EL DERIVADO NO ES LA VERDAD, Y POR QUE ESTA MIGRACION NO LO USA PARA
-- LA PROMO ACTIVA
-- ----------------------------------------------------------------------------
-- Durante el desarrollo de esta migracion, el pedido 5728 se cancelo en
-- produccion y el derivado de la promo 13 paso de 0 a 2 en el medio. Eso es el
-- contraejemplo, no una casualidad: `revertir_bloques_auto_ajuste` procesa una
-- cancelacion DEVOLVIENDO stock y ajustando el contador, mientras que el
-- derivado simplemente deja de contar esas unidades. Las dos contabilidades
-- divergen a proposito, y cual de las dos refleja el stock que hay en el
-- deposito solo lo dice un conteo fisico.
--
-- Por eso el contador SOLO se alinea en las promos INACTIVAS, donde no hay
-- proximo cierre de bloque y por lo tanto no hay stock que se pueda mover mal.
-- El de la promo activa queda como esta: mover el resto de una barra viva
-- cambia cuando cierra el proximo bloque, o sea que mueve stock real.
--
-- LA DECISION
-- -----------
-- `promociones.usos_pendientes` es el unico hogar de la barra default. Ya lo
-- era de hecho -- los 4 caminos de stock la usan y no conocen el acumulador, y
-- la promo 12 nunca tuvo fila para su default y funciona igual --, pero
-- `aplicar_uso_promo_acumulador` solo sabia operar sobre filas de acumulador,
-- asi que sustituir_regalo_pedido tenia que copiar el valor de ida y de vuelta
-- alrededor de cada sustitucion (mig 059 §5.B.1 y §5.B.4). Esa copia es la que
-- se separaba entre sustitucion y sustitucion, porque crear_pedido_completo
-- solo mueve `promociones`.
--
-- Ahora el helper ramifica: si el producto es el regalo default de la promo,
-- opera sobre `promociones.usos_pendientes`; si no, sobre su fila. Con eso el
-- baile de sincronizacion sobra y se borra.
--
-- LA ROTACION DEL REGALO, QUE ES POR DONDE SE REABRIA SOLO
-- --------------------------------------------------------
-- Borrar las filas default no alcanza: si despues cambia
-- `promociones.producto_regalo_id` a un sabor que YA tiene fila de sustituto,
-- esa fila pasa a ser "la fila default" y la doble representacion vuelve sola.
-- Y el regalo SI rota en esta base: 9 sustituciones en toda la historia no
-- explican las 3.000 unidades repartidas en los 6 sabores de la promo 13.
--
-- Por eso va un segundo trigger que, al rotar el regalo, INTERCAMBIA las barras:
-- el resto que estaba en `promociones` pasa a ser la fila del sabor VIEJO, y la
-- fila del sabor NUEVO se pliega dentro de `promociones` y se borra. Cada resto
-- queda pegado a su sabor y no se pierde ninguno. No mueve stock.
--
-- ORDEN DE LOS DOS TRIGGERS: se llama `trg_promo_rotar...` para que corra ANTES
-- que `trg_renormalizar...` (postgres los dispara por orden alfabetico de
-- nombre), asi la renormalizacion ve las barras ya intercambiadas. Y por eso
-- mismo la renormalizacion pasa a RELEER `usos_pendientes` de la tabla en vez
-- de usar NEW: NEW quedo congelado en el valor que escribio el statement y no
-- incluye lo que escribio el otro trigger.
--
-- LO QUE ESTA MIGRACION NO ARREGLA, A PROPOSITO
-- ---------------------------------------------
-- Las barras de SUSTITUTOS de la promo 13 tambien derivaron del valor derivado
-- (78: 0 vs 2, 83: 2 vs 4, y a la 12 le faltan filas para 85 y 125). No se
-- tocan: la 13 esta ACTIVA, y mover el resto de una barra activa cambia cuando
-- cierra el proximo bloque, o sea que mueve stock real. Saber si esos bloques
-- ya se descontaron o no exige un conteo fisico, que es justo lo que la mig 091
-- §B declaro fuera de alcance y se entrelaza con las correcciones manuales de
-- las migs 067/068. Queda como hallazgo, no como arreglo silencioso.
--
-- COMO SE REVIERTE: recrear las filas default desde
-- `promociones.usos_pendientes`, dropear los dos triggers y volver a la version
-- anterior del helper y de sustituir_regalo_pedido.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1 - El helper aprende a operar sobre la barra default.
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
  v_es_default     BOOLEAN;
  v_resto_actual   NUMERIC;
  v_contenedor     BIGINT;
  -- El id de la fila, aparte del RECORD: en la barra default `v_acc` nunca se
  -- asigna, y referenciar `v_acc.id` -- aunque sea en la rama NO tomada de un
  -- CASE -- tira "record is not assigned yet", porque la estructura de un
  -- RECORD sin asignar es indeterminada y la expresion ni siquiera se planifica.
  v_acc_id         BIGINT;
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
         ajuste_producto_id, regalo_mueve_stock, producto_regalo_id, usos_pendientes
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

  v_es_default := p_producto_regalo_id IS NOT NULL
                  AND p_producto_regalo_id = v_promo.producto_regalo_id;

  IF v_es_default THEN
    -- La barra del regalo default vive en promociones.usos_pendientes y en
    -- ningun otro lado (issue #553). No hay fila de acumulador que crear.
    v_resto_actual := GREATEST(COALESCE(v_promo.usos_pendientes, 0), 0);
    v_contenedor   := v_promo.ajuste_producto_id;
  ELSE
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
    v_resto_actual := COALESCE(v_acc.usos_pendientes, 0);
    v_contenedor   := v_acc.ajuste_producto_id;
    v_acc_id       := v_acc.id;
  END IF;

  -- Semantica de RESTO con clamp: usos_pendientes SIEMPRE queda en [0, N).
  v_usos_raw := v_resto_actual + p_delta;
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

  IF v_es_default THEN
    -- La columna es INT. El resto de la barra default nunca paso por la
    -- aritmetica NUMERIC del acumulador, asi que el cast no pierde nada.
    UPDATE promociones
       SET usos_pendientes = GREATEST(v_usos_final, 0)::INT
     WHERE id = p_promocion_id AND sucursal_id = p_sucursal_id;
  ELSE
    UPDATE promo_acumuladores
       SET usos_pendientes = v_usos_final, updated_at = NOW()
     WHERE id = v_acc_id;
  END IF;

  IF v_stock_delta <> 0 AND v_contenedor IS NOT NULL THEN
    PERFORM set_config('app.stock_origen', 'auto_ajuste_promo', true);
    PERFORM set_config('app.stock_ref_tipo', 'promocion', true);
    PERFORM set_config('app.stock_ref_id', p_promocion_id::TEXT, true);
    PERFORM set_config('app.stock_user_id', p_usuario_id::TEXT, true);

    SELECT stock INTO v_stock_anterior
      FROM productos
     WHERE id = v_contenedor AND sucursal_id = p_sucursal_id
     FOR UPDATE;
    v_stock_nuevo := COALESCE(v_stock_anterior, 0) + v_stock_delta;

    UPDATE productos SET stock = v_stock_nuevo, updated_at = NOW()
     WHERE id = v_contenedor AND sucursal_id = p_sucursal_id;

    INSERT INTO mermas_stock (
      producto_id, cantidad, motivo, observaciones,
      stock_anterior, stock_nuevo, usuario_id, sucursal_id
    ) VALUES (
      v_contenedor,
      -v_stock_delta,
      CASE WHEN v_stock_delta < 0 THEN 'promociones' ELSE 'promociones_reversion' END,
      p_motivo, COALESCE(v_stock_anterior, 0), v_stock_nuevo, p_usuario_id, p_sucursal_id
    ) RETURNING id INTO v_merma_id;

    INSERT INTO promo_ajustes (
      promocion_id, usos_ajustados, unidades_ajustadas,
      producto_id, merma_id, usuario_id, observaciones, sucursal_id
    ) VALUES (
      p_promocion_id, v_usos_ajustados, -v_stock_delta,
      v_contenedor, v_merma_id, p_usuario_id, p_motivo, p_sucursal_id
    );
  END IF;

  RETURN jsonb_build_object(
    'aplicado', true,
    'barra', CASE WHEN v_es_default THEN 'default' ELSE 'sustituto' END,
    'acumulador_id', v_acc_id,
    'usos_pendientes', v_usos_final,
    'bloques_delta', CASE WHEN v_stock_delta < 0 THEN v_blocks ELSE -v_blocks END
  );
END;
$function$;

ALTER FUNCTION public.aplicar_uso_promo_acumulador(BIGINT, BIGINT, NUMERIC, BIGINT, BIGINT, UUID, TEXT)
  OWNER TO postgres;

COMMENT ON FUNCTION public.aplicar_uso_promo_acumulador(BIGINT, BIGINT, NUMERIC, BIGINT, BIGINT, UUID, TEXT) IS
  'Aplica delta a una barra de la promo. Si el producto es el regalo default, la '
  'barra es promociones.usos_pendientes; si no, su fila de promo_acumuladores. '
  'El factor sale siempre de promociones en vivo.';

-- -------------------------------------------------------------------------
-- 2 - sustituir_regalo_pedido pierde el baile de sincronizacion.
--     Sobra: el helper ahora opera sobre promociones.usos_pendientes cuando el
--     producto es el regalo default. Parche por ancla sobre el cuerpo VIVO,
--     que no es el del archivo de la 059.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._mig221_reemplazar_ancla(
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

DO $patch$
DECLARE
  v_fn regprocedure;
BEGIN
  SELECT p.oid::regprocedure INTO v_fn
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
                   AND p.proname = 'sustituir_regalo_pedido';

  -- 2.a) Fuera el "alinear el acumulador default al contador global" del inicio.
  PERFORM public._mig221_reemplazar_ancla(
    v_fn,
    E'    IF v_promo.producto_regalo_id IS NOT NULL THEN\n'
    || E'      SELECT id, usos_pendientes INTO v_acc_default\n'
    || E'        FROM promo_acumuladores\n'
    || E'       WHERE promocion_id = v_promo.id AND producto_regalo_id = v_promo.producto_regalo_id AND sucursal_id = v_sucursal\n'
    || E'       FOR UPDATE;\n'
    || E'      IF FOUND THEN\n'
    || E'        IF v_acc_default.usos_pendientes IS DISTINCT FROM COALESCE(v_promo.usos_pendientes, 0) THEN\n'
    || E'          UPDATE promo_acumuladores SET usos_pendientes = COALESCE(v_promo.usos_pendientes, 0), updated_at = NOW()\n'
    || E'           WHERE id = v_acc_default.id;\n'
    || E'        END IF;\n'
    || E'      ELSE\n'
    || E'        INSERT INTO promo_acumuladores (promocion_id, producto_regalo_id, ajuste_producto_id,\n'
    || E'          usos_pendientes, sucursal_id)\n'
    || E'        VALUES (v_promo.id, v_promo.producto_regalo_id, v_promo.ajuste_producto_id,\n'
    || E'          COALESCE(v_promo.usos_pendientes, 0), v_sucursal)\n'
    || E'        ON CONFLICT (promocion_id, producto_regalo_id, sucursal_id) DO NOTHING;\n'
    || E'      END IF;\n'
    || E'    END IF;\n',
    E'    -- La barra default vive en promociones.usos_pendientes y el helper opera\n'
    || E'    -- directo sobre ella (mig 221). No hay nada que sincronizar.\n'
  );

  -- 2.b) Fuera el "re-sincronizar el contador global desde el acumulador" del final.
  SELECT p.oid::regprocedure INTO v_fn
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
                   AND p.proname = 'sustituir_regalo_pedido';

  PERFORM public._mig221_reemplazar_ancla(
    v_fn,
    E'    IF v_promo.producto_regalo_id IS NOT NULL THEN\n'
    || E'      SELECT usos_pendientes INTO v_promo_usos_default\n'
    || E'        FROM promo_acumuladores\n'
    || E'       WHERE promocion_id = v_promo.id AND producto_regalo_id = v_promo.producto_regalo_id AND sucursal_id = v_sucursal;\n'
    || E'      UPDATE promociones SET usos_pendientes = GREATEST(COALESCE(v_promo_usos_default, 0)::INT, 0)\n'
    || E'       WHERE id = v_promo.id AND sucursal_id = v_sucursal;\n'
    || E'    END IF;\n',
    ''
  );

  -- 2.c) Y las dos declaraciones que quedaron sin uso.
  SELECT p.oid::regprocedure INTO v_fn
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
                   AND p.proname = 'sustituir_regalo_pedido';

  PERFORM public._mig221_reemplazar_ancla(
    v_fn,
    E'  v_promo_usos_default NUMERIC;\n  v_acc_default        RECORD;\n',
    ''
  );
END
$patch$;

DROP FUNCTION public._mig221_reemplazar_ancla(regprocedure, text, text);

-- -------------------------------------------------------------------------
-- 3 - La renormalizacion relee de la tabla en vez de confiar en NEW.
--
--     NEW quedo congelado en lo que escribio el statement, y el trigger de
--     rotacion de mas abajo corre ANTES y puede haber cambiado
--     usos_pendientes. Sin este cambio, cambiar el regalo Y el factor en el
--     mismo guardado renormalizaria contra un resto viejo.
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
  v_promo       RECORD;
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

  -- Releer: trg_promo_rotar_barra_default corre antes que este y puede haber
  -- movido usos_pendientes, que NEW no refleja.
  SELECT usos_pendientes, ajuste_producto_id, producto_regalo_id
    INTO v_promo
    FROM promociones
   WHERE id = NEW.id AND sucursal_id = NEW.sucursal_id;

  -- Las barras, en una sola lista. acc_id NULL = la barra default, que vive en
  -- promociones.usos_pendientes. Desde la mig 221 no existen filas de
  -- acumulador para el regalo default, pero el filtro se deja igual: es el
  -- invariante, no una limpieza de una sola vez.
  --
  -- Sin FOR UPDATE sobre promo_acumuladores: el UPDATE de `promociones` que
  -- disparo este trigger ya tiene la fila de la promo bloqueada, y
  -- aplicar_uso_promo_acumulador arranca con SELECT ... FROM promociones FOR
  -- UPDATE. Esa fila serializa los dos caminos.
  FOR v_barra IN
    SELECT NULL::bigint AS acc_id,
           GREATEST(COALESCE(v_promo.usos_pendientes, 0), 0)::numeric AS resto,
           v_promo.ajuste_producto_id AS contenedor
    UNION ALL
    SELECT a.id, GREATEST(COALESCE(a.usos_pendientes, 0), 0), a.ajuste_producto_id
      FROM promo_acumuladores a
     WHERE a.promocion_id = NEW.id
       AND a.sucursal_id  = NEW.sucursal_id
       AND a.producto_regalo_id IS DISTINCT FROM v_promo.producto_regalo_id
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
REVOKE ALL ON FUNCTION public.renormalizar_bloques_por_cambio_factor() FROM PUBLIC, anon, authenticated;

-- -------------------------------------------------------------------------
-- 4 - Rotar el regalo intercambia las barras, no las duplica.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rotar_barra_default_de_promo()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_resto_viejo NUMERIC;
  v_resto_nuevo NUMERIC;
BEGIN
  -- El resto que hoy esta en promociones pertenece al regalo VIEJO.
  v_resto_viejo := GREATEST(COALESCE(NEW.usos_pendientes, 0), 0);

  -- El resto del regalo NUEVO, si ya tenia barra como sustituto.
  SELECT GREATEST(COALESCE(usos_pendientes, 0), 0) INTO v_resto_nuevo
    FROM promo_acumuladores
   WHERE promocion_id = NEW.id
     AND producto_regalo_id = NEW.producto_regalo_id
     AND sucursal_id = NEW.sucursal_id
   FOR UPDATE;

  -- El regalo viejo se muda a su propia fila con el resto que traia. El
  -- contenedor es el que tenia la promo ANTES de rotar: en modo fraccion el
  -- regalo y el contenedor son el mismo producto y rotan juntos.
  IF OLD.producto_regalo_id IS NOT NULL AND v_resto_viejo > 0 THEN
    INSERT INTO promo_acumuladores (
      promocion_id, producto_regalo_id, ajuste_producto_id, usos_pendientes, sucursal_id
    ) VALUES (
      NEW.id, OLD.producto_regalo_id,
      COALESCE(OLD.ajuste_producto_id, OLD.producto_regalo_id),
      v_resto_viejo, NEW.sucursal_id
    )
    ON CONFLICT (promocion_id, producto_regalo_id, sucursal_id)
    DO UPDATE SET usos_pendientes = promo_acumuladores.usos_pendientes + EXCLUDED.usos_pendientes,
                  updated_at = NOW();
  END IF;

  -- El regalo nuevo pasa a vivir en promociones y deja de tener fila.
  UPDATE promociones SET usos_pendientes = COALESCE(v_resto_nuevo, 0)::INT
   WHERE id = NEW.id AND sucursal_id = NEW.sucursal_id;

  DELETE FROM promo_acumuladores
   WHERE promocion_id = NEW.id
     AND producto_regalo_id = NEW.producto_regalo_id
     AND sucursal_id = NEW.sucursal_id;

  RETURN NULL;
END;
$fn$;

ALTER FUNCTION public.rotar_barra_default_de_promo() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.rotar_barra_default_de_promo() FROM PUBLIC, anon, authenticated;

-- El nombre importa: postgres dispara los triggers por orden alfabetico, y
-- `trg_promo_...` < `trg_renormalizar_...`, asi que la rotacion corre primero y
-- la renormalizacion ve las barras ya intercambiadas.
DROP TRIGGER IF EXISTS trg_promo_rotar_barra_default ON public.promociones;
CREATE TRIGGER trg_promo_rotar_barra_default
  AFTER UPDATE OF producto_regalo_id ON public.promociones
  FOR EACH ROW
  WHEN (OLD.producto_regalo_id IS DISTINCT FROM NEW.producto_regalo_id
        AND COALESCE(NEW.ajuste_automatico, FALSE))
  EXECUTE FUNCTION public.rotar_barra_default_de_promo();

-- -------------------------------------------------------------------------
-- 5 - Los datos.
--
--     5.a) El contador default al valor derivado, SOLO en promos INACTIVAS.
--     No hay proximo cierre de bloque ahi, asi que no hay stock que se pueda
--     mover mal; si alguna se reactiva, arranca con el contador correcto en vez
--     de con uno que derivo. La activa queda intacta a proposito -- ver el
--     encabezado.
-- -------------------------------------------------------------------------
WITH derivado AS (
  SELECT pi.promocion_id, pi.sucursal_id,
         (SUM(pi.cantidad) % p.unidades_por_bloque)::int AS resto
    FROM pedido_items pi
    JOIN pedidos pe    ON pe.id = pi.pedido_id
    JOIN promociones p ON p.id = pi.promocion_id AND p.sucursal_id = pi.sucursal_id
   WHERE pi.es_bonificacion
     AND pe.estado <> 'cancelado'
     AND pi.producto_id = p.producto_regalo_id
     AND COALESCE(p.ajuste_automatico, false)
     AND COALESCE(p.unidades_por_bloque, 0) > 0
   GROUP BY pi.promocion_id, pi.sucursal_id, p.unidades_por_bloque
)
UPDATE promociones p
   SET usos_pendientes = d.resto
  FROM derivado d
 WHERE p.id = d.promocion_id
   AND p.sucursal_id = d.sucursal_id
   AND NOT p.activo
   AND p.usos_pendientes IS DISTINCT FROM d.resto;

-- 5.b) Y recien despues las filas duplicadas. El valor que sobrevive es el de
--      `promociones`, que es el que TODOS los caminos de codigo leen -- los 4
--      de stock y la UI. La fila que se borra ya estaba condenada: la proxima
--      sustitucion la iba a pisar con este mismo valor (mig 059 §5.B.1).

DELETE FROM promo_acumuladores a
 USING promociones p
 WHERE p.id = a.promocion_id
   AND p.sucursal_id = a.sucursal_id
   AND a.producto_regalo_id = p.producto_regalo_id;

-- -------------------------------------------------------------------------
-- 6 - Verificacion.
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  v_dobles int;
  v_def    text;
  v_trg    int;
  v_activa int;
BEGIN
  -- El invariante: ninguna promo tiene fila de acumulador para su regalo default.
  SELECT count(*) INTO v_dobles
  FROM promo_acumuladores a
  JOIN promociones p ON p.id = a.promocion_id AND p.sucursal_id = a.sucursal_id
  WHERE a.producto_regalo_id = p.producto_regalo_id;
  IF v_dobles > 0 THEN
    RAISE EXCEPTION 'Quedaron % barras default duplicadas.', v_dobles;
  END IF;

  -- Las INACTIVAS quedaron en el derivado.
  SELECT count(*) INTO v_activa
  FROM promociones p
  WHERE NOT p.activo AND COALESCE(p.ajuste_automatico, false)
    AND COALESCE(p.unidades_por_bloque, 0) > 0
    AND p.usos_pendientes IS DISTINCT FROM (
      SELECT COALESCE((SUM(pi.cantidad) % p.unidades_por_bloque)::int, 0)
        FROM pedido_items pi JOIN pedidos pe ON pe.id = pi.pedido_id
       WHERE pi.promocion_id = p.id AND pi.sucursal_id = p.sucursal_id
         AND pi.es_bonificacion AND pe.estado <> 'cancelado'
         AND pi.producto_id = p.producto_regalo_id
    );
  IF v_activa > 0 THEN
    RAISE EXCEPTION 'La barra default de % promo(s) inactiva(s) no quedo en el derivado.', v_activa;
  END IF;

  -- Las ACTIVAS no se tocan, pero se informa la diferencia: es el pendiente de
  -- conteo fisico, no un fallo de esta migracion.
  SELECT count(*) INTO v_activa
  FROM promociones p
  WHERE p.activo AND COALESCE(p.ajuste_automatico, false)
    AND COALESCE(p.unidades_por_bloque, 0) > 0
    AND p.usos_pendientes IS DISTINCT FROM (
      SELECT COALESCE((SUM(pi.cantidad) % p.unidades_por_bloque)::int, 0)
        FROM pedido_items pi JOIN pedidos pe ON pe.id = pi.pedido_id
       WHERE pi.promocion_id = p.id AND pi.sucursal_id = p.sucursal_id
         AND pi.es_bonificacion AND pe.estado <> 'cancelado'
         AND pi.producto_id = p.producto_regalo_id
    );
  IF v_activa > 0 THEN
    RAISE NOTICE 'AVISO: % promo(s) ACTIVA(s) tienen el contador default distinto del derivado. '
                 'No se tocan a proposito: mover el resto de una barra viva mueve stock. '
                 'Necesita conteo fisico.', v_activa;
  END IF;

  -- El baile de sincronizacion se fue de sustituir_regalo_pedido. La asercion
  -- fuerte: la funcion no menciona `promo_acumuladores` NUNCA MAS. Sus cuatro
  -- menciones vivian en los dos bloques que se borraron; todo lo que necesita
  -- del acumulador se lo pide ahora a aplicar_uso_promo_acumulador.
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace AND p.proname='sustituir_regalo_pedido';
  IF v_def LIKE '%promo_acumuladores%' THEN
    RAISE EXCEPTION 'Quedo una referencia a promo_acumuladores en sustituir_regalo_pedido.';
  END IF;
  IF v_def LIKE '%v_acc_default%' OR v_def LIKE '%v_promo_usos_default%' THEN
    RAISE EXCEPTION 'Quedaron declaraciones huerfanas en sustituir_regalo_pedido.';
  END IF;

  -- Los dos triggers, en el orden correcto.
  SELECT count(*) INTO v_trg FROM pg_trigger t
   WHERE t.tgrelid='public.promociones'::regclass
     AND t.tgname IN ('trg_promo_rotar_barra_default','trg_renormalizar_bloques_por_cambio_factor');
  IF v_trg <> 2 THEN
    RAISE EXCEPTION 'Faltan triggers en promociones (hay %, se esperaban 2).', v_trg;
  END IF;
  IF 'trg_promo_rotar_barra_default' >= 'trg_renormalizar_bloques_por_cambio_factor' THEN
    RAISE EXCEPTION 'El trigger de rotacion dejo de correr antes que el de renormalizacion.';
  END IF;

  -- El helper sabe de la barra default.
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace AND p.proname='aplicar_uso_promo_acumulador';
  IF v_def NOT LIKE '%v_es_default%' THEN
    RAISE EXCEPTION 'aplicar_uso_promo_acumulador no ramifica por barra default.';
  END IF;

  RAISE NOTICE 'OK: la barra default vive en un solo lugar.';
END
$verif$;

COMMIT;
