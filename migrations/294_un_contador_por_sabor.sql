-- =========================================================================
-- mig 294 · UN CONTADOR POR SABOR (#840)
--
-- EL BUG
-- ------
-- En una promo de fraccion con auto-ajuste (modo B: `ajuste_automatico`,
-- `regalo_mueve_stock = false`) cada sabor tiene su fardo abierto. Pero habia
-- dos contabilidades:
--
--   · sustituir_regalo_pedido y dividir_regalo_pedido movian usos con
--     `aplicar_uso_promo_acumulador`, contra la barra DE ESE SABOR
--     (`promo_acumuladores`, o `promociones.usos_pendientes` para el sabor
--     default, mig 221);
--   · el alta (crear_pedido_completo, _bot), la edicion
--     (actualizar_pedido_items), la cancelacion, la eliminacion y la salvedad
--     sumaban y restaban TODO en la barra default (`promociones.usos_pendientes`)
--     con el contenedor de cada linea, y revertian con
--     `revertir_bloques_auto_ajuste`, que solo sabia de esa barra.
--
-- Medido en prod (ensayo de la 272, con ROLLBACK): regalo de 14 botellas
-- repartido 314:6 / 80:4 / 79:4 y cancelado. Sin reparto: 79 -> 113,
-- 80 -> 115, 314 -> 125. Con reparto: 79 -> 114, 80 -> 114, 314 -> 125, y la
-- barra de 79 quedaba en 4 sin ninguna linea. El total de fardos cerraba; el
-- sabor no.
--
-- LA DECISION DEL DUENO (2026-10-06)
-- ---------------------------------
-- Un contador por sabor en TODOS los caminos: se descuenta un fardo de Lima
-- recien cuando salieron N botellas de Lima.
--
-- QUE CAMBIA
-- ----------
-- 1 · `aplicar_uso_promo_acumulador` es EL motor. Todos los caminos le pasan
--     (promo, sabor de la linea, +-cantidad). Opera sobre la barra de ese
--     sabor: `promociones.usos_pendientes` si el sabor es el regalo default
--     (contenedor = `promociones.ajuste_producto_id`, como desde la 221), y su
--     fila de `promo_acumuladores` si no (contenedor = el de la fila; al
--     crearla, el propio sabor). Cada N usos de ESA barra se descuentan
--     `stock_por_bloque` unidades de SU contenedor, y cada bloque que una
--     devolucion deshace vuelve a ESE contenedor.
--     Aprende tres cosas que antes vivian en los llamadores:
--       · guarda y restaura los cuatro GUCs de app.stock_* alrededor de su
--         UPDATE (mig 229): ahora lo llaman funciones que ya tienen su propia
--         etiqueta puesta ('pedido_creado', 'pedido_cancelado', 'salvedad'...)
--         y la siguiente linea del llamador tiene que seguir saliendo con ella;
--       · respeta `app.contenedor_origen` en la subida (mig 269, cancelar por
--         falta de stock), como hacia revertir_bloques_auto_ajuste;
--       · rechaza el bloque si el contenedor no alcanza ("Auto-ajuste: stock
--         insuficiente en ..."), el mismo mensaje que tenian el alta y la
--         edicion. Antes sustituir/dividir podian dejar el contenedor en
--         negativo (STK-B); ahora devuelven ese error.
--     Y en una promo que NO es modo B (o con el factor sin configurar) mueve
--     `promociones.usos_pendientes` como contador de usos, con el piso en 0:
--     lo mismo que hacian el alta (+) y revertir_bloques_auto_ajuste (-).
--
-- 2 · Los siete llamadores pasan por el motor, por (promo, sabor):
--     crear_pedido_completo, crear_pedido_completo_bot, actualizar_pedido_items
--     (devolucion y re-alta), cancelar_pedido_con_stock, eliminar_pedido_completo,
--     registrar_salvedad (las dos devoluciones). sustituir_regalo_pedido y
--     dividir_regalo_pedido ya lo usaban; solo cambia el contenedor POR DEFECTO
--     de la salida del original: el propio sabor, no el de la promo (ese
--     default es el que en el medido creo la fila de 79 apuntando a otro fardo).
--
-- 3 · `revertir_bloques_auto_ajuste` se DROPEA: no queda ningun llamador y dos
--     motores era justamente el bug.
--
-- 4 · `promociones.usos_pendientes` NO se deja de escribir: en modo B pasa a
--     ser la barra del sabor DEFAULT y solo de el (no la suma de todos). Es lo
--     que ya suponian la 221 (aplicar_uso_promo_acumulador, la rotacion del
--     regalo, la renormalizacion por cambio de factor, previsualizar_cambio_factor)
--     y la UI (VistaPromociones y ModalSustituirRegalo sintetizan la barra
--     default desde ahi y las demas desde promo_acumuladores). En modo A sigue
--     siendo el contador de usos (limite_usos). BONIF-D (no negativo) sigue
--     valiendo: el motor nunca lo deja < 0.
--
-- 5 · DATOS: cada barra de modo B se recalcula desde los pedidos vivos y los
--     fardos ya descontados:
--
--       barra(promo, sabor) = (U - D) mod N, llevado a [0, N)
--
--       U = SUM(pedido_items.cantidad) de los regalos de esa promo y ese
--           producto en pedidos no cancelados/anulados (entregados incluidos:
--           esas botellas salieron);
--       D = SUM(promo_ajustes.usos_ajustados) de esa promo con
--           producto_id = el contenedor de ese sabor (los bloques descontados
--           menos los devueltos, en botellas);
--       N = promociones.unidades_por_bloque.
--
--     (U - D) mod N es "cuantas botellas de ese sabor salieron desde el ultimo
--     fardo de ese sabor". El cociente (U - D - barra) / N es la diferencia
--     historica en fardos (cancelaciones anteriores a la 235 que no devolvian,
--     el regalo que roto de sabor, bloques que cerro una linea de otro sabor
--     cuando la barra era compartida). NO se corrige aca: mover stock por eso
--     es un ajuste con nombre y fecha que necesita conteo fisico (lo mismo que
--     dijeron la 091 §B y la 221). Queda en el reporte ANTES/DESPUES.
--     Cada barra que cambia deja una constancia en promo_ajustes
--     (usos_ajustados = 0, sin unidades: no mueve PROMO-A).
--
-- REQUISITO PARA ESTA CUENTA: en cada promo modo B el contenedor de cada
-- sabor es el propio sabor (hoy es asi en las 5: ajuste_producto_id =
-- producto_regalo_id y todas las filas apuntan a si mismas). Si dos sabores
-- compartieran contenedor, D se contaria dos veces: la migracion lo chequea y
-- se cae antes de escribir.
--
-- LO QUE NO HACE
-- --------------
-- · No toca el factor por producto (#950): sigue siendo el de la promo.
-- · No toca ajustar_stock_promocion_completo (ajuste manual): sigue operando
--   sobre promociones.usos_pendientes, que en modo B es la barra del default.
-- · No cambia los GRANTs de nadie (CREATE OR REPLACE los conserva; el $verif$
--   los compara contra los de antes), SALVO el del motor: ahora mueve el stock
--   de todas las promos y no valida rol ni sucursal, asi que se revoca a
--   PUBLIC, anon y authenticated. Lo llaman solo funciones SECURITY DEFINER de
--   postgres; el front y las edge functions no (CLAUDE.md: funcion que solo
--   corre desde el server, se revoca a las tres). Decision del dueno.
--
-- CAMBIOS CHICOS QUE CONVIENE SABER (no cambian numeros):
-- · El fardo que baja el alta / el bot / la re-alta de una edicion sale con
--   origen 'auto_ajuste_promo' y ref promocion/<id> (antes heredaba la
--   etiqueta del llamador, 'pedido_creado'). La bajada del trigger de lotes no
--   mira el origen; ningun check de auditoria cuenta esos movimientos.
-- · Textos de promo_ajustes: edicion y bot pasan a 'Auto-ajuste (Promo: X,
--   ...)'; siguen entrando en el LIKE 'Auto-ajuste%' de la 212. Las mermas de
--   sustituir/dividir llevan ' (Promo: X)' al final.
-- · pedido_bundle_para_promo corre por cada linea de regalo de una promo
--   automatica, no solo al cerrar un bloque (una consulta mas por linea).
-- · Sustituir / dividir rechazan con "stock insuficiente" si el contenedor no
--   alcanza, en vez de dejarlo en negativo (rompia STK-B).
-- · En una promo con regalo_mueve_stock = false Y ajuste_automatico = false,
--   sustituir haria -X (con piso 0) y +X sobre el contador de usos y podria
--   inflarlo. Hoy no hay ninguna promo asi.
--
-- Tecnica: cirugia por ancla y por tramo sobre el cuerpo VIVO de prod (molde
-- de las 242/289). Si un ancla no aparece exactamente una vez, la migracion
-- entera se cae. Los helpers sacan los \r: un checkout con CRLF no rompe las
-- anclas.
-- =========================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 0 · Andamio. Se dropea al final.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _mig840_acl ON COMMIT DROP AS
SELECT p.oid::regprocedure::text AS fn, p.proacl::text AS acl, p.prosecdef, p.proconfig::text AS cfg
  FROM pg_proc p
 WHERE p.pronamespace = 'public'::regnamespace
   AND p.proname IN ('aplicar_uso_promo_acumulador', 'crear_pedido_completo',
                     'crear_pedido_completo_bot', 'actualizar_pedido_items',
                     'cancelar_pedido_con_stock', 'eliminar_pedido_completo',
                     'registrar_salvedad', 'sustituir_regalo_pedido',
                     'dividir_regalo_pedido');

CREATE OR REPLACE FUNCTION public._mig840_ancla(
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
    RAISE EXCEPTION 'mig840 · el ancla aparece % veces en % (se esperaba 1). El cuerpo vivo cambio: revisar a mano. Ancla: %',
      v_veces, p_funcion, left(v_ancla, 160);
  END IF;
  EXECUTE replace(v_def, v_ancla, replace(p_nuevo, E'\r', ''));
END;
$fn$;

-- Reemplaza el TRAMO que va desde `p_desde` hasta `p_hasta` inclusive. Las dos
-- marcas tienen que aparecer exactamente una vez, y en ese orden.
CREATE OR REPLACE FUNCTION public._mig840_tramo(
  p_funcion regprocedure, p_desde text, p_hasta text, p_nuevo text
) RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text;
  v_desde text := replace(p_desde, E'\r', '');
  v_hasta text := replace(p_hasta, E'\r', '');
  v_i     int;
  v_j     int;
BEGIN
  v_def := pg_get_functiondef(p_funcion);
  IF (length(v_def) - length(replace(v_def, v_desde, ''))) / length(v_desde) <> 1 THEN
    RAISE EXCEPTION 'mig840 · la marca de inicio no aparece exactamente una vez en %: %', p_funcion, left(v_desde, 160);
  END IF;
  IF (length(v_def) - length(replace(v_def, v_hasta, ''))) / length(v_hasta) <> 1 THEN
    RAISE EXCEPTION 'mig840 · la marca de fin no aparece exactamente una vez en %: %', p_funcion, left(v_hasta, 160);
  END IF;
  v_i := strpos(v_def, v_desde);
  v_j := strpos(v_def, v_hasta);
  IF v_j < v_i THEN
    RAISE EXCEPTION 'mig840 · en % la marca de fin esta antes que la de inicio', p_funcion;
  END IF;
  EXECUTE left(v_def, v_i - 1) || replace(p_nuevo, E'\r', '')
       || substr(v_def, v_j + length(v_hasta));
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 1 · EL motor. Misma firma (CREATE OR REPLACE conserva owner y ACL).
-- ---------------------------------------------------------------------------
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
  -- CASE -- tira "record is not assigned yet".
  v_acc_id         BIGINT;
  v_usos_raw       NUMERIC;
  v_blocks         INT;
  v_usos_final     NUMERIC;
  v_stock_delta    INT;
  v_usos_ajustados INT;
  v_stock_anterior INT;
  v_stock_nuevo    INT;
  v_cont_nombre    TEXT;
  v_merma_id       BIGINT;
  v_obs_merma      TEXT;
  -- mig 229: set_config es por TRANSACCION. Este motor lo llaman funciones que
  -- ya pusieron su propia etiqueta, y la proxima linea que muevan tiene que
  -- seguir saliendo con ella: se guarda y se restaura alrededor del UPDATE.
  v_org_prev       TEXT;
  v_ref_tipo_prev  TEXT;
  v_ref_id_prev    TEXT;
  v_user_prev      TEXT;
BEGIN
  IF p_delta IS NULL THEN
    RETURN jsonb_build_object('aplicado', false, 'razon', 'delta nulo');
  END IF;

  SELECT id, nombre, unidades_por_bloque, stock_por_bloque, ajuste_automatico,
         ajuste_producto_id, regalo_mueve_stock, producto_regalo_id, usos_pendientes
    INTO v_promo
    FROM promociones
   WHERE id = p_promocion_id AND sucursal_id = p_sucursal_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('aplicado', false, 'razon', 'promo no encontrada');
  END IF;

  -- mig 294 (#840): una promo que no fracciona (modo A, o modo B sin factor)
  -- no tiene barras: `usos_pendientes` es un contador de usos, con piso en 0.
  -- Es lo que hacian el alta (+) y revertir_bloques_auto_ajuste (-), que ahora
  -- pasan por aca.
  IF NOT COALESCE(v_promo.ajuste_automatico, FALSE)
     OR COALESCE(v_promo.unidades_por_bloque, 0) <= 0
     OR COALESCE(v_promo.stock_por_bloque, 0) <= 0 THEN
    UPDATE promociones
       SET usos_pendientes = GREATEST(COALESCE(usos_pendientes, 0) + p_delta, 0)::INT
     WHERE id = p_promocion_id AND sucursal_id = p_sucursal_id;
    RETURN jsonb_build_object(
      'aplicado', true, 'barra', 'contador',
      'usos_pendientes', GREATEST(COALESCE(v_promo.usos_pendientes, 0) + p_delta, 0)::INT,
      'bloques_delta', 0);
  END IF;

  v_es_default := p_producto_regalo_id IS NOT NULL
                  AND p_producto_regalo_id = v_promo.producto_regalo_id;

  IF v_es_default THEN
    -- La barra del sabor default vive en promociones.usos_pendientes y en
    -- ningun otro lado (issue #553). Desde la mig 294 es SOLO la de ese sabor.
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
        p_promocion_id, p_producto_regalo_id,
        COALESCE(p_ajuste_producto_id_def, p_producto_regalo_id),
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
    v_resto_actual := GREATEST(COALESCE(v_acc.usos_pendientes, 0), 0);
    v_contenedor   := v_acc.ajuste_producto_id;
    v_acc_id       := v_acc.id;
  END IF;

  -- Semantica de RESTO: la barra queda en [0, N). Subir cierra un bloque cada
  -- N; bajar por debajo de 0 deshace los bloques que haga falta (el fardo
  -- vuelve). Es la misma aritmetica que tenia revertir_bloques_auto_ajuste.
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
    UPDATE promociones
       SET usos_pendientes = GREATEST(v_usos_final, 0)::INT
     WHERE id = p_promocion_id AND sucursal_id = p_sucursal_id;
  ELSE
    UPDATE promo_acumuladores
       SET usos_pendientes = v_usos_final, updated_at = NOW()
     WHERE id = v_acc_id;
  END IF;

  IF v_stock_delta <> 0 AND v_contenedor IS NOT NULL THEN
    SELECT stock, nombre INTO v_stock_anterior, v_cont_nombre
      FROM productos
     WHERE id = v_contenedor AND sucursal_id = p_sucursal_id
     FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Auto-ajuste: producto destino no encontrado (promo %)', p_promocion_id;
    END IF;
    -- El alta y la edicion ya rechazaban esto con este mismo mensaje. Ahora vale
    -- para todos los caminos: un bloque no deja el contenedor en negativo.
    IF v_stock_delta < 0 AND COALESCE(v_stock_anterior, 0) < -v_stock_delta THEN
      RAISE EXCEPTION 'Auto-ajuste: stock insuficiente en % (disponible: %, requerido: %)',
        v_cont_nombre, COALESCE(v_stock_anterior, 0), -v_stock_delta;
    END IF;
    v_stock_nuevo := COALESCE(v_stock_anterior, 0) + v_stock_delta;

    v_org_prev      := current_setting('app.stock_origen', true);
    v_ref_tipo_prev := current_setting('app.stock_ref_tipo', true);
    v_ref_id_prev   := current_setting('app.stock_ref_id', true);
    v_user_prev     := current_setting('app.stock_user_id', true);

    -- 'auto_ajuste_promo' esta en la lista blanca de trg_lotes_sincronizar: el
    -- fardo que vuelve, vuelve a su lote (FEFO). La bajada no mira el origen.
    -- mig 269: el llamador puede pedir otro origen para la SUBIDA
    -- (cancelar por falta de stock: el fardo vuelve y se merma enseguida).
    PERFORM set_config('app.stock_origen',
      CASE WHEN v_stock_delta > 0
           THEN COALESCE(NULLIF(current_setting('app.contenedor_origen', true), ''), 'auto_ajuste_promo')
           ELSE 'auto_ajuste_promo' END, true);
    PERFORM set_config('app.stock_ref_tipo', 'promocion', true);
    PERFORM set_config('app.stock_ref_id', p_promocion_id::TEXT, true);
    PERFORM set_config('app.stock_user_id', COALESCE(p_usuario_id::TEXT, ''), true);

    UPDATE productos SET stock = v_stock_nuevo, updated_at = NOW()
     WHERE id = v_contenedor AND sucursal_id = p_sucursal_id;

    PERFORM set_config('app.stock_origen',   COALESCE(v_org_prev, ''), true);
    PERFORM set_config('app.stock_ref_tipo', COALESCE(v_ref_tipo_prev, ''), true);
    PERFORM set_config('app.stock_ref_id',   COALESCE(v_ref_id_prev, ''), true);
    PERFORM set_config('app.stock_user_id',  COALESCE(v_user_prev, ''), true);

    v_obs_merma := CASE WHEN COALESCE(p_motivo, '') LIKE '%Promo:%' THEN p_motivo
                        ELSE COALESCE(p_motivo, 'Auto-ajuste') || ' (Promo: ' || v_promo.nombre || ')' END;

    INSERT INTO mermas_stock (
      producto_id, cantidad, motivo, observaciones,
      stock_anterior, stock_nuevo, usuario_id, sucursal_id
    ) VALUES (
      v_contenedor,
      -v_stock_delta,
      CASE WHEN v_stock_delta < 0 THEN 'promociones' ELSE 'promociones_reversion' END,
      v_obs_merma, COALESCE(v_stock_anterior, 0), v_stock_nuevo, p_usuario_id, p_sucursal_id
    ) RETURNING id INTO v_merma_id;

    -- promo_ajustes.observaciones conserva el motivo tal cual: la mig 212 lee
    -- sus prefijos ('Auto-ajuste%', 'Cancelacion pedido #%', ...).
    INSERT INTO promo_ajustes (
      promocion_id, usos_ajustados, unidades_ajustadas,
      producto_id, merma_id, usuario_id, observaciones, sucursal_id
    ) VALUES (
      p_promocion_id, v_usos_ajustados, -v_stock_delta,
      v_contenedor, v_merma_id, p_usuario_id, COALESCE(p_motivo, 'Auto-ajuste'), p_sucursal_id
    );
  END IF;

  RETURN jsonb_build_object(
    'aplicado', true,
    'barra', CASE WHEN v_es_default THEN 'default' ELSE 'sabor' END,
    'acumulador_id', v_acc_id,
    'contenedor', v_contenedor,
    'usos_pendientes', v_usos_final,
    'bloques_delta', CASE WHEN v_stock_delta < 0 THEN v_blocks ELSE -v_blocks END,
    'unidades_stock', -v_stock_delta
  );
END;
$function$;

COMMENT ON FUNCTION public.aplicar_uso_promo_acumulador(BIGINT, BIGINT, NUMERIC, BIGINT, BIGINT, UUID, TEXT) IS
  'EL motor de las barras de regalo (mig 294, #840). Una barra por (promo, sabor): '
  'la del sabor default en promociones.usos_pendientes, las demas en promo_acumuladores. '
  'Delta + cierra bloques y descuenta del contenedor de ESE sabor; delta - los deshace y '
  'el fardo vuelve a ese mismo contenedor. En promos sin fraccion mueve el contador de usos.';

-- Solo server: lo llaman funciones SECURITY DEFINER de postgres. Ver cabecera.
REVOKE ALL ON FUNCTION public.aplicar_uso_promo_acumulador(BIGINT, BIGINT, NUMERIC, BIGINT, BIGINT, UUID, TEXT)
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2 · crear_pedido_completo · el alta suma en la barra del sabor de la linea.
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._mig840_tramo(
    'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)'::regprocedure,
$desde$      UPDATE promociones SET usos_pendientes = usos_pendientes + v_cantidad WHERE id = v_promocion_id AND sucursal_id = v_sucursal;$desde$,
$hasta$          UPDATE promociones SET usos_pendientes = GREATEST(usos_pendientes - v_ajustar_usos, 0)
          WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
        END IF;
      END IF;$hasta$,
$nuevo$      -- mig 294 (#840): un contador por sabor. La linea suma en la barra de SU
      -- producto y, si cierra un bloque, el fardo sale del contenedor de esa
      -- barra. Todo eso lo hace el motor, que es el mismo de la devolucion.
      SELECT nombre, COALESCE(ajuste_automatico, false) AS auto
        INTO v_promo
        FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
      v_observacion := NULL;
      IF v_promo.auto THEN
        v_pedidos_bundle := public.pedido_bundle_para_promo(v_promocion_id, v_sucursal, 20);
        v_observacion := 'Auto-ajuste (Promo: ' || v_promo.nombre
                         || ', Pedidos: ' || COALESCE(v_pedidos_bundle, '#' || v_pedido_id) || ')';
      END IF;
      PERFORM public.aplicar_uso_promo_acumulador(
        v_promocion_id, v_producto_id, v_cantidad, v_producto_id,
        v_sucursal, p_usuario_id, v_observacion);$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 3 · crear_pedido_completo_bot · lo mismo.
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._mig840_tramo(
    'public.crear_pedido_completo_bot(uuid,uuid)'::regprocedure,
$desde$      UPDATE promociones SET usos_pendientes = usos_pendientes + v_cantidad WHERE id = v_promocion_id AND sucursal_id = v_pendiente.sucursal_id;$desde$,
$hasta$          UPDATE promociones SET usos_pendientes = GREATEST(usos_pendientes - v_ajustar_usos, 0)
            WHERE id = v_promocion_id AND sucursal_id = v_pendiente.sucursal_id;
        END IF;
      END IF;$hasta$,
$nuevo$      -- mig 294 (#840): un contador por sabor, mismo motor que el alta de la app.
      PERFORM public.aplicar_uso_promo_acumulador(
        v_promocion_id, v_producto_id, v_cantidad, v_producto_id,
        v_pendiente.sucursal_id, p_perfil_id,
        'Auto-ajuste (Promo: '
          || COALESCE((SELECT nombre FROM promociones
                        WHERE id = v_promocion_id AND sucursal_id = v_pendiente.sucursal_id), '?')
          || ', Pedido #' || v_pedido_id || ' via bot)');$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 4 · actualizar_pedido_items · la devolucion y la re-alta, por sabor.
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE v_fn regprocedure := 'public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure;
BEGIN
  -- (a) La devolucion de todo lo que tenia el pedido: por (promo, sabor),
  --     contra la barra de cada sabor. Partir el delta por sabor no cambia
  --     cuantos fardos vuelven de cada contenedor: cada sabor tiene el suyo.
  PERFORM public._mig840_tramo(v_fn,
$desde$  FOR v_bonif IN$desde$,
$hasta$      v_bonif.contenedor_id
    );
  END LOOP;$hasta$,
$nuevo$  -- mig 294 (#840): por (promo, SABOR), contra la barra de ese sabor.
  FOR v_bonif IN
    SELECT pi.promocion_id, pi.producto_id, SUM(pi.cantidad)::INT AS total_cantidad
      FROM pedido_items pi
     WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
       AND COALESCE(pi.es_bonificacion, false) = true AND pi.promocion_id IS NOT NULL
     GROUP BY pi.promocion_id, pi.producto_id
     ORDER BY pi.promocion_id, pi.producto_id
  LOOP
    PERFORM public.aplicar_uso_promo_acumulador(
      v_bonif.promocion_id, v_bonif.producto_id, -v_bonif.total_cantidad,
      v_bonif.producto_id, v_sucursal, p_usuario_id,
      'Edicion pedido #' || p_pedido_id);
  END LOOP;$nuevo$);

  -- (b) La re-alta, con el producto GUARDADO (mig 252: el trigger de
  --     sustituciones puede haberlo reescrito).
  PERFORM public._mig840_tramo(v_fn,
$desde$      UPDATE promociones SET usos_pendientes = usos_pendientes + v_cantidad_nueva WHERE id = v_promocion_id AND sucursal_id = v_sucursal;$desde$,
$hasta$          UPDATE promociones SET usos_pendientes = GREATEST(usos_pendientes - v_ajustar_usos, 0)
          WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
        END IF;
      END IF;$hasta$,
$nuevo$      -- mig 294 (#840): la barra del sabor que QUEDO en la fila (mig 252).
      PERFORM public.aplicar_uso_promo_acumulador(
        v_promocion_id, v_producto_guardado, v_cantidad_nueva, v_producto_guardado,
        v_sucursal, p_usuario_id,
        'Auto-ajuste (Promo: '
          || COALESCE((SELECT nombre FROM promociones
                        WHERE id = v_promocion_id AND sucursal_id = v_sucursal), '?')
          || ', Pedido #' || p_pedido_id || ', edicion)');$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 5 · cancelar_pedido_con_stock · el loop de la 235/242/269, por sabor.
--     Lo de 'falta_stock' (mig 269) queda igual; solo cambia de donde sale el
--     contenedor: el de la barra del sabor, que es el que el motor va a tocar.
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._mig840_tramo(
    'public.cancelar_pedido_con_stock(bigint,text,uuid,text)'::regprocedure,
$desde$  -- mig 235: el fardo del regalo vuelve al contenedor.$desde$,
$hasta$  LOOP
    v_contenedor_faltante := v_falta_stock$hasta$,
$nuevo$  -- mig 235: el fardo del regalo vuelve al contenedor. Aca habia un
  -- GREATEST(usos_pendientes - cantidad, 0) a mano: el clamp se comia el
  -- negativo y el bloque que se mermo al completarse no volvia NUNCA.
  --
  -- mig 294 (#840): por (promo, SABOR), contra la barra de ese sabor y con el
  -- mismo motor que el alta. Si las botellas que vuelven deshacen un bloque
  -- de ese sabor, el fardo vuelve al contenedor de esa barra.
  --
  -- El motor guarda y restaura los cuatro GUCs de app.stock_* alrededor de su
  -- UPDATE (mig 229), asi que el 'pedido_cancelado' de arriba sigue valiendo
  -- para el resto del cuerpo.
  --
  -- mig 269: se llama para todo motivo. Con 'falta_stock', si el contenedor es
  -- un producto del pedido (todos faltaron, por definicion del motivo), el
  -- fardo que repone el motor tampoco existia: vuelve con un origen fuera de
  -- la lista blanca (app.contenedor_origen) y se merma enseguida. El
  -- contenedor de la barra: el de la promo para el sabor default, el de la
  -- fila (o el propio sabor, si todavia no tiene) para los demas.
  FOR v_promo_rev IN
    SELECT pi.promocion_id AS promocion_id,
           pi.producto_id  AS producto_id,
           CASE WHEN pr.producto_regalo_id = pi.producto_id THEN pr.ajuste_producto_id
                ELSE COALESCE(pa.ajuste_producto_id, pi.producto_id) END AS contenedor_id,
           SUM(pi.cantidad)::INT AS cantidad
      FROM pedido_items pi
      LEFT JOIN promociones pr
        ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
      LEFT JOIN promo_acumuladores pa
        ON pa.promocion_id = pi.promocion_id AND pa.producto_regalo_id = pi.producto_id
       AND pa.sucursal_id = pi.sucursal_id
     WHERE pi.pedido_id = p_pedido_id
       AND pi.sucursal_id = v_sucursal
       AND COALESCE(pi.es_bonificacion, false) = true
       AND pi.promocion_id IS NOT NULL
     GROUP BY 1, 2, 3
     ORDER BY 1, 2
  LOOP
    v_contenedor_faltante := v_falta_stock$nuevo$);

  PERFORM public._mig840_ancla(
    'public.cancelar_pedido_con_stock(bigint,text,uuid,text)'::regprocedure,
$ancla$    PERFORM public.revertir_bloques_auto_ajuste(
      v_promo_rev.promocion_id, v_promo_rev.cantidad, v_sucursal,
      v_acting_user, 'Cancelacion pedido #' || p_pedido_id,
      v_promo_rev.contenedor_id);$ancla$,
$nuevo$    PERFORM public.aplicar_uso_promo_acumulador(
      v_promo_rev.promocion_id, v_promo_rev.producto_id, -v_promo_rev.cantidad,
      v_promo_rev.producto_id, v_sucursal, v_acting_user,
      'Cancelacion pedido #' || p_pedido_id);$nuevo$);

  PERFORM public._mig840_ancla(
    'public.cancelar_pedido_con_stock(bigint,text,uuid,text)'::regprocedure,
$ancla$      -- 0 si el helper no revirtio ningun bloque (usos_pendientes lo absorbio).$ancla$,
$nuevo$      -- 0 si el motor no deshizo ningun bloque (la barra del sabor lo absorbio).$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 6 · eliminar_pedido_completo · item por item, contra la barra de su sabor.
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE v_fn regprocedure := 'public.eliminar_pedido_completo(bigint,uuid,text,boolean)'::regprocedure;
BEGIN
  PERFORM public._mig840_ancla(v_fn,
$ancla$ AS regalo_mueve_stock,
             CASE WHEN pr.producto_regalo_id IS DISTINCT FROM pi.producto_id
                  THEN pi.producto_id ELSE pr.ajuste_producto_id END AS contenedor_id$ancla$,
$nuevo$ AS regalo_mueve_stock$nuevo$);

  PERFORM public._mig840_ancla(v_fn,
$ancla$        PERFORM public.revertir_bloques_auto_ajuste(
          v_item.promocion_id, v_item.cantidad::INT, v_sucursal,
          p_usuario_id, 'Eliminacion pedido #' || p_pedido_id,
          v_item.contenedor_id
        );$ancla$,
$nuevo$        -- mig 294 (#840): contra la barra del sabor de la linea.
        PERFORM public.aplicar_uso_promo_acumulador(
          v_item.promocion_id, v_item.producto_id, -v_item.cantidad,
          v_item.producto_id, v_sucursal, p_usuario_id,
          'Eliminacion pedido #' || p_pedido_id);$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 7 · registrar_salvedad · las dos devoluciones, contra la barra del sabor.
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE v_fn regprocedure := 'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure;
BEGIN
  PERFORM public._mig840_tramo(v_fn,
$desde$    PERFORM public.revertir_bloques_auto_ajuste(
      v_item.promocion_id$desde$,
$hasta$        WHERE pr.id = v_item.promocion_id AND pr.sucursal_id = v_sucursal)
    );$hasta$,
$nuevo$    -- mig 294 (#840): las botellas restan de la barra de ESE sabor.
    PERFORM public.aplicar_uso_promo_acumulador(
      v_item.promocion_id, v_item.producto_id, -p_cantidad_afectada,
      v_item.producto_id, v_sucursal, v_usuario_id,
      'Salvedad sobre regalo, pedido #' || p_pedido_id);$nuevo$);

  PERFORM public._mig840_tramo(v_fn,
$desde$        PERFORM public.revertir_bloques_auto_ajuste(
          v_bonif.promocion_id$desde$,
$hasta$          WHERE pr.id = v_bonif.promocion_id AND pr.sucursal_id = v_sucursal)
        );$hasta$,
$nuevo$        PERFORM public.aplicar_uso_promo_acumulador(
          v_bonif.promocion_id, v_bonif.producto_id, -v_diff,
          v_bonif.producto_id, v_sucursal, v_usuario_id,
          'Salvedad pedido #' || p_pedido_id);$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 8 · sustituir / dividir · la salida del original, contra SU barra.
--     El contenedor por defecto solo se usa si el sabor todavia no tiene fila.
--     Era el de la promo: con el alta escribiendo en la barra default, el
--     original "sin fila" era casi siempre un sabor que el alta habia sumado
--     en otro lado, y la fila nacia apuntando al fardo equivocado (el 79 del
--     medido). Ahora es el propio sabor, como cualquier otra fila.
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._mig840_ancla(
    'public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)'::regprocedure,
$ancla$      v_promo.id, v_item.producto_id, -v_item.cantidad,
      v_promo.ajuste_producto_id, v_sucursal, v_user_id,$ancla$,
$nuevo$      v_promo.id, v_item.producto_id, -v_item.cantidad,
      v_item.producto_id, v_sucursal, v_user_id,$nuevo$);

  PERFORM public._mig840_ancla(
    'public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'::regprocedure,
$ancla$        CASE WHEN v_neto.producto_id = v_item.producto_id
             THEN v_promo.ajuste_producto_id ELSE v_neto.producto_id END,
        v_sucursal, v_user_id,$ancla$,
$nuevo$        v_neto.producto_id,
        v_sucursal, v_user_id,$nuevo$);

  PERFORM public._mig840_ancla(
    'public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'::regprocedure,
$ancla$    -- Mismo helper y mismo contenedor por defecto que sustituir_regalo_pedido:
    -- la salida del original contra el contenedor de la promo, cada sabor
    -- nuevo contra si mismo. La barra default vive en promociones (mig 221).$ancla$,
$nuevo$    -- Mismo motor que sustituir_regalo_pedido y que el alta: cada producto
    -- contra la barra de su sabor (mig 294, #840). La del sabor default vive
    -- en promociones (mig 221); el contenedor por defecto de una fila nueva es
    -- el propio sabor.$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 9 · Un solo motor: revertir_bloques_auto_ajuste se va.
-- ---------------------------------------------------------------------------
DO $chk$
DECLARE v_n int;
BEGIN
  SELECT count(*) INTO v_n
    FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace
     AND p.proname <> 'revertir_bloques_auto_ajuste'
     AND pg_get_functiondef(p.oid) LIKE '%revertir_bloques_auto_ajuste(%';
  IF v_n > 0 THEN
    RAISE EXCEPTION 'mig840 · quedan % funciones que llaman a revertir_bloques_auto_ajuste', v_n;
  END IF;
END
$chk$;

DROP FUNCTION public.revertir_bloques_auto_ajuste(bigint, integer, bigint, uuid, text, bigint);

-- ---------------------------------------------------------------------------
-- 10 · DATOS: cada barra de modo B, recalculada por sabor (ver cabecera).
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _mig840_barras ON COMMIT DROP AS
WITH promos AS (
  SELECT id, sucursal_id, producto_regalo_id, ajuste_producto_id,
         usos_pendientes, unidades_por_bloque AS n
    FROM promociones
   WHERE COALESCE(ajuste_automatico, false)
     AND COALESCE(unidades_por_bloque, 0) > 0
     AND COALESCE(stock_por_bloque, 0) > 0
),
u AS (
  SELECT pi.promocion_id, pi.sucursal_id, pi.producto_id AS sabor, SUM(pi.cantidad) AS usos
    FROM pedido_items pi
    JOIN pedidos pe ON pe.id = pi.pedido_id
    JOIN promos p   ON p.id = pi.promocion_id AND p.sucursal_id = pi.sucursal_id
   WHERE COALESCE(pi.es_bonificacion, false)
     AND pe.estado NOT IN ('cancelado', 'anulado')
   GROUP BY 1, 2, 3
),
d AS (
  SELECT pa.promocion_id, pa.sucursal_id, pa.producto_id AS contenedor,
         SUM(COALESCE(pa.usos_ajustados, 0)) AS usos
    FROM promo_ajustes pa
    JOIN promos p ON p.id = pa.promocion_id AND p.sucursal_id = pa.sucursal_id
   WHERE pa.producto_id IS NOT NULL
   GROUP BY 1, 2, 3
),
sabores AS (
  SELECT promocion_id, sucursal_id, sabor FROM u
  UNION SELECT promocion_id, sucursal_id, contenedor FROM d
  UNION SELECT promocion_id, sucursal_id, producto_regalo_id FROM promo_acumuladores
  UNION SELECT id, sucursal_id, producto_regalo_id FROM promos WHERE producto_regalo_id IS NOT NULL
),
base AS (
  SELECT s.promocion_id, s.sucursal_id, s.sabor, p.n,
         (s.sabor = p.producto_regalo_id) AS es_default,
         CASE WHEN s.sabor = p.producto_regalo_id THEN p.ajuste_producto_id
              ELSE COALESCE(a.ajuste_producto_id, s.sabor) END AS contenedor,
         CASE WHEN s.sabor = p.producto_regalo_id THEN p.usos_pendientes::numeric
              ELSE a.usos_pendientes END AS barra_antes,
         COALESCE(u.usos, 0) AS usos_vivos
    FROM sabores s
    JOIN promos p ON p.id = s.promocion_id AND p.sucursal_id = s.sucursal_id
    LEFT JOIN promo_acumuladores a
      ON a.promocion_id = s.promocion_id AND a.producto_regalo_id = s.sabor
     AND a.sucursal_id = s.sucursal_id
    LEFT JOIN u ON u.promocion_id = s.promocion_id AND u.sucursal_id = s.sucursal_id
               AND u.sabor = s.sabor
)
SELECT b.*, COALESCE(d.usos, 0) AS usos_descontados,
       (((b.usos_vivos - COALESCE(d.usos, 0)) % b.n) + b.n) % b.n AS barra_despues
  FROM base b
  LEFT JOIN d ON d.promocion_id = b.promocion_id AND d.sucursal_id = b.sucursal_id
             AND d.contenedor = b.contenedor;

DO $datos$
DECLARE v_n int;
BEGIN
  -- El requisito de la cuenta: un contenedor por sabor. Si dos sabores de una
  -- promo compartieran contenedor, sus fardos descontados se contarian dos
  -- veces. Hoy no pasa en ninguna; si pasa, a mano.
  SELECT count(*) INTO v_n FROM (
    SELECT promocion_id, sucursal_id, contenedor
      FROM _mig840_barras WHERE contenedor IS NOT NULL
     GROUP BY 1, 2, 3 HAVING count(*) > 1) x;
  IF v_n > 0 THEN
    RAISE EXCEPTION 'mig840 · % contenedores compartidos por dos sabores de la misma promo: el recalculo no es valido, revisar a mano', v_n;
  END IF;

  -- La constancia, antes de escribir: una fila por barra que cambia, sin
  -- unidades (no mueve PROMO-A) y con un prefijo que la 212 no lee como
  -- medicion del factor.
  INSERT INTO promo_ajustes (promocion_id, usos_ajustados, producto_id, observaciones, sucursal_id)
  SELECT promocion_id, 0, contenedor,
         format('Recalculo barra por sabor (mig 294, #840): producto %s, %s -> %s (usos vivos %s, descontados %s)',
                sabor, COALESCE(barra_antes::text, 'sin barra'), barra_despues, usos_vivos, usos_descontados),
         sucursal_id
    FROM _mig840_barras
   WHERE COALESCE(barra_antes, 0) <> barra_despues;

  -- Sabor default: promociones.usos_pendientes.
  UPDATE promociones p
     SET usos_pendientes = b.barra_despues::int
    FROM _mig840_barras b
   WHERE b.es_default
     AND p.id = b.promocion_id AND p.sucursal_id = b.sucursal_id
     AND p.usos_pendientes IS DISTINCT FROM b.barra_despues::int;

  -- Los demas: su fila. Solo se crea fila si la barra no queda en 0.
  INSERT INTO promo_acumuladores (promocion_id, producto_regalo_id, ajuste_producto_id, usos_pendientes, sucursal_id)
  SELECT promocion_id, sabor, contenedor, barra_despues, sucursal_id
    FROM _mig840_barras
   WHERE NOT es_default AND (barra_antes IS NOT NULL OR barra_despues <> 0)
  ON CONFLICT (promocion_id, producto_regalo_id, sucursal_id)
  DO UPDATE SET usos_pendientes = EXCLUDED.usos_pendientes, updated_at = NOW()
   WHERE promo_acumuladores.usos_pendientes IS DISTINCT FROM EXCLUDED.usos_pendientes;
END
$datos$;

-- ---------------------------------------------------------------------------
-- 11 · Verificacion. Lo estructural primero; despues el ensayo, en un
--      sub-bloque que se deshace solo (SQLSTATE centinela, como la 242).
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  v_n        int;
  v_def      text;
  v_fn       text;
  v_audit    jsonb;
  v_admin    uuid;
  v_suc      bigint;
  v_cliente  bigint;
  v_a        bigint;  -- sabor default (y su contenedor)
  v_b        bigint;  -- sabor del alta
  v_c        bigint;  -- otro sabor
  v_v        bigint;  -- producto vendido
  v_promo    bigint;
  v_res      jsonb;
  v_pedido   bigint;
  v_item     bigint;
  v_sa int; v_sb int; v_sc int; v_sv int;
  v_ba numeric; v_bb numeric; v_bc numeric;
  v_origen   text;
BEGIN
  -- (a) Un solo motor.
  IF to_regprocedure('public.revertir_bloques_auto_ajuste(bigint,integer,bigint,uuid,text,bigint)') IS NOT NULL THEN
    RAISE EXCEPTION 'mig840 · revertir_bloques_auto_ajuste sigue existiendo';
  END IF;
  SELECT count(*) INTO v_n FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'revertir_bloques_auto_ajuste';
  IF v_n > 0 THEN RAISE EXCEPTION 'mig840 · quedo una sobrecarga de revertir_bloques_auto_ajuste'; END IF;

  FOREACH v_fn IN ARRAY ARRAY[
    'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)',
    'public.crear_pedido_completo_bot(uuid,uuid)',
    'public.actualizar_pedido_items(bigint,jsonb,uuid)',
    'public.cancelar_pedido_con_stock(bigint,text,uuid,text)',
    'public.eliminar_pedido_completo(bigint,uuid,text,boolean)',
    'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)',
    'public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)',
    'public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'] LOOP
    v_def := pg_get_functiondef(v_fn::regprocedure);
    IF v_def NOT LIKE '%aplicar_uso_promo_acumulador(%' THEN
      RAISE EXCEPTION 'mig840 · % no pasa por el motor', v_fn;
    END IF;
    -- Ninguno escribe la barra a mano.
    IF v_def ~* 'SET\s+usos_pendientes' THEN
      RAISE EXCEPTION 'mig840 · % todavia escribe usos_pendientes a mano', v_fn;
    END IF;
  END LOOP;

  v_def := pg_get_functiondef('public.aplicar_uso_promo_acumulador(bigint,bigint,numeric,bigint,bigint,uuid,text)'::regprocedure);
  IF v_def NOT LIKE '%v_org_prev%' OR v_def NOT LIKE '%app.contenedor_origen%' THEN
    RAISE EXCEPTION 'mig840 · el motor no guarda/restaura los GUCs o no respeta app.contenedor_origen';
  END IF;

  -- (b) Firmas, SECURITY DEFINER, search_path y GRANTs: como estaban, salvo
  -- la ACL del motor, que se revoca a proposito (ver cabecera).
  SELECT count(*) INTO v_n
    FROM _mig840_acl a
    LEFT JOIN pg_proc p ON p.oid = a.fn::regprocedure
   WHERE p.oid IS NULL
      OR (p.proacl::text IS DISTINCT FROM a.acl AND p.proname <> 'aplicar_uso_promo_acumulador')
      OR p.prosecdef IS DISTINCT FROM a.prosecdef OR p.proconfig::text IS DISTINCT FROM a.cfg;
  IF v_n > 0 OR (SELECT count(*) FROM _mig840_acl) <> 9 THEN
    RAISE EXCEPTION 'mig840 · cambio la firma, la ACL, el SECURITY DEFINER o el search_path de % funcion(es)', v_n;
  END IF;
  IF has_function_privilege('authenticated', 'public.aplicar_uso_promo_acumulador(bigint,bigint,numeric,bigint,bigint,uuid,text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.aplicar_uso_promo_acumulador(bigint,bigint,numeric,bigint,bigint,uuid,text)', 'EXECUTE')
     OR has_function_privilege('public', 'public.aplicar_uso_promo_acumulador(bigint,bigint,numeric,bigint,bigint,uuid,text)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.aplicar_uso_promo_acumulador(bigint,bigint,numeric,bigint,bigint,uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'mig840 · el motor sigue abierto a authenticated/anon/PUBLIC o perdio service_role';
  END IF;

  -- (c) Las barras quedaron en la formula, y en [0, N).
  SELECT count(*) INTO v_n
    FROM _mig840_barras b
    LEFT JOIN promociones p ON p.id = b.promocion_id AND p.sucursal_id = b.sucursal_id
    LEFT JOIN promo_acumuladores a ON a.promocion_id = b.promocion_id
     AND a.producto_regalo_id = b.sabor AND a.sucursal_id = b.sucursal_id
   WHERE CASE WHEN b.es_default THEN p.usos_pendientes::numeric
              ELSE COALESCE(a.usos_pendientes, 0) END <> b.barra_despues;
  IF v_n > 0 THEN RAISE EXCEPTION 'mig840 · % barras no quedaron en el valor recalculado', v_n; END IF;

  SELECT count(*) INTO v_n
    FROM promo_acumuladores a
    JOIN promociones p ON p.id = a.promocion_id AND p.sucursal_id = a.sucursal_id
   WHERE COALESCE(p.unidades_por_bloque, 0) > 0
     AND (a.usos_pendientes < 0 OR a.usos_pendientes >= p.unidades_por_bloque);
  IF v_n > 0 THEN RAISE EXCEPTION 'mig840 · % filas de promo_acumuladores fuera de [0, N)', v_n; END IF;

  -- La 221: ninguna fila para el sabor default.
  SELECT count(*) INTO v_n
    FROM promo_acumuladores a
    JOIN promociones p ON p.id = a.promocion_id AND p.sucursal_id = a.sucursal_id
   WHERE a.producto_regalo_id = p.producto_regalo_id;
  IF v_n > 0 THEN RAISE EXCEPTION 'mig840 · % filas de acumulador para el sabor default (mig 221)', v_n; END IF;

  -- (d) Las compuertas: COSTO-D, STK-F y la familia PROMO/BONIF en verde.
  v_audit := public.auditoria_integridad();
  SELECT count(*) INTO v_n
    FROM jsonb_array_elements(v_audit->'checks') c
   WHERE c->>'id' IN ('COSTO-D', 'STK-F', 'PROMO-A', 'PROMO-B', 'BONIF-C', 'BONIF-D', 'MERMA-B', 'MERMA-E', 'STK-B')
     AND NOT (c->>'ok')::boolean;
  IF v_n > 0 THEN
    RAISE EXCEPTION 'mig840 · auditoria_integridad en rojo: %',
      (SELECT jsonb_agg(c) FROM jsonb_array_elements(v_audit->'checks') c
        WHERE NOT (c->>'ok')::boolean
          AND c->>'id' IN ('COSTO-D','STK-F','PROMO-A','PROMO-B','BONIF-C','BONIF-D','MERMA-B','MERMA-E','STK-B'));
  END IF;

  -- (e) El ensayo: el caso medido del issue, con productos y promo sinteticos.
  --     Promo 6+2 (N = 6, 1 fardo por bloque). A = sabor default, B y C otros.
  --     Alta: 14 de B -> 2 fardos de B, barra B = 2.
  --     Reparto 6 B / 4 C / 4 A -> B devuelve 1 fardo (barra 0), C = 4, A = 4.
  --     Cancelacion -> cada sabor como estaba, y las tres barras en 0.
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'mig840 · el ensayo necesita un admin activo con una sucursal activa';
  END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  PERFORM set_config('app.omitir_minimo_venta', '1', true);
  SELECT id INTO v_cliente FROM clientes WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;

  BEGIN
    INSERT INTO productos (nombre, precio, stock, sucursal_id)
    VALUES ('ZZ ensayo mig840 sabor A', 100, 50, v_suc) RETURNING id INTO v_a;
    INSERT INTO productos (nombre, precio, stock, sucursal_id)
    VALUES ('ZZ ensayo mig840 sabor B', 100, 40, v_suc) RETURNING id INTO v_b;
    INSERT INTO productos (nombre, precio, stock, sucursal_id)
    VALUES ('ZZ ensayo mig840 sabor C', 100, 30, v_suc) RETURNING id INTO v_c;
    INSERT INTO productos (nombre, precio, stock, sucursal_id)
    VALUES ('ZZ ensayo mig840 vendido', 100, 10, v_suc) RETURNING id INTO v_v;

    INSERT INTO promociones (
      nombre, tipo, fecha_inicio, sucursal_id, ajuste_automatico,
      ajuste_producto_id, producto_regalo_id, unidades_por_bloque,
      stock_por_bloque, regalo_mueve_stock, usos_pendientes
    ) VALUES (
      'ZZ ensayo mig840', 'bonificacion', CURRENT_DATE, v_suc, TRUE,
      v_a, v_a, 6, 1, FALSE, 0
    ) RETURNING id INTO v_promo;

    -- El regalo va PRIMERO: la linea vendida de despues tiene que seguir
    -- saliendo con 'pedido_creado' (el motor restaura los GUCs).
    v_res := public.crear_pedido_completo(
      v_cliente, 100, v_admin,
      jsonb_build_array(
        jsonb_build_object('producto_id', v_b, 'cantidad', 14, 'precio_unitario', 0,
                           'es_bonificacion', true, 'promocion_id', v_promo),
        jsonb_build_object('producto_id', v_v, 'cantidad', 1, 'precio_unitario', 100)),
      'ensayo mig840');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'mig840 · el ensayo no pudo crear el pedido: %', v_res;
    END IF;
    v_pedido := (v_res->>'pedido_id')::bigint;

    SELECT stock INTO v_sb FROM productos WHERE id = v_b;
    SELECT usos_pendientes INTO v_bb FROM promo_acumuladores WHERE promocion_id = v_promo AND producto_regalo_id = v_b;
    SELECT usos_pendientes INTO v_ba FROM promociones WHERE id = v_promo;
    IF v_sb <> 38 OR v_bb <> 2 OR v_ba <> 0 THEN
      RAISE EXCEPTION 'mig840 · alta: B=% (esperado 38), barra B=% (esperado 2), barra default=% (esperado 0)', v_sb, v_bb, v_ba;
    END IF;
    SELECT h.origen INTO v_origen FROM stock_historico h
     WHERE h.producto_id = v_v ORDER BY h.id DESC LIMIT 1;
    IF v_origen IS DISTINCT FROM 'pedido_creado' THEN
      RAISE EXCEPTION 'mig840 · la linea vendida despues del regalo salio con origen % (esperado pedido_creado)', v_origen;
    END IF;

    SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_pedido AND es_bonificacion;
    v_res := public.dividir_regalo_pedido(v_item,
      jsonb_build_array(jsonb_build_object('producto_id', v_b, 'cantidad', 6),
                        jsonb_build_object('producto_id', v_c, 'cantidad', 4),
                        jsonb_build_object('producto_id', v_a, 'cantidad', 4)),
      'ensayo mig840', NULL);
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'mig840 · el ensayo no pudo repartir: %', v_res;
    END IF;

    v_res := public.cancelar_pedido_con_stock(v_pedido, 'ensayo mig840', v_admin, 'prueba');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'mig840 · el ensayo no pudo cancelar: %', v_res;
    END IF;

    SELECT stock INTO v_sa FROM productos WHERE id = v_a;
    SELECT stock INTO v_sb FROM productos WHERE id = v_b;
    SELECT stock INTO v_sc FROM productos WHERE id = v_c;
    SELECT stock INTO v_sv FROM productos WHERE id = v_v;
    SELECT usos_pendientes INTO v_ba FROM promociones WHERE id = v_promo;
    SELECT COALESCE(max(usos_pendientes) FILTER (WHERE producto_regalo_id = v_b), 0),
           COALESCE(max(usos_pendientes) FILTER (WHERE producto_regalo_id = v_c), 0)
      INTO v_bb, v_bc FROM promo_acumuladores WHERE promocion_id = v_promo;
    IF v_sa <> 50 OR v_sb <> 40 OR v_sc <> 30 OR v_sv <> 10
       OR v_ba <> 0 OR v_bb <> 0 OR v_bc <> 0 THEN
      RAISE EXCEPTION 'mig840 · reparto + cancelacion no cerro por sabor: A=% B=% C=% vendido=% (esperado 50/40/30/10), barras A=% B=% C=% (esperado 0)',
        v_sa, v_sb, v_sc, v_sv, v_ba, v_bb, v_bc;
    END IF;

    RAISE EXCEPTION 'mig840-ok' USING ERRCODE = '2F000';
  EXCEPTION WHEN SQLSTATE '2F000' THEN
    IF SQLERRM <> 'mig840-ok' THEN RAISE; END IF;
    RAISE NOTICE 'mig840 · ensayo OK: alta, reparto y cancelacion cierran por sabor';
  END;

  RAISE NOTICE 'mig840 · OK: un contador por sabor, un solo motor';
END
$verif$;

-- ---------------------------------------------------------------------------
-- 12 · Se saca el andamio.
-- ---------------------------------------------------------------------------
DROP FUNCTION public._mig840_ancla(regprocedure, text, text);
DROP FUNCTION public._mig840_tramo(regprocedure, text, text, text);

COMMIT;
