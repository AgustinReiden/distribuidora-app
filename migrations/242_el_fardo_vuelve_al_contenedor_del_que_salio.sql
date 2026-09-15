-- El fardo vuelve al contenedor del que salio
--
-- En una promo de fraccion con auto-ajuste el regalo son botellas y lo que baja
-- del stock es el FARDO de donde salen. Cual fardo lo decide el alta desde la
-- mig 096/132, por item:
--
--     contenedor = CASE WHEN promo.producto_regalo_id IS DISTINCT FROM item.producto_id
--                       THEN item.producto_id            -- el preventista eligio otro sabor
--                       ELSE promo.ajuste_producto_id END -- el regalo default de la promo
--
-- Los cuatro caminos que DEVUELVEN ese bloque -- edicion, cancelacion,
-- eliminacion y salvedad -- no tenian por donde enterarse: los cuatro llaman a
-- `revertir_bloques_auto_ajuste`, que leia siempre `promociones.ajuste_producto_id`.
-- El fardo salia de un sabor y volvia a otro, sin que fallara nada.
--
-- EL EJEMPLO, con los numeros de la promo 13 ("Manaos 6+2", 6 botellas por
-- bloque, 1 fardo por bloque) y el regalo default A = MANAOS POMELO BLANCO 3 LT:
--
--   Pedido con 6 botellas de regalo del sabor B = MANAOS NARANJA 3 LT.
--   Stock inicial: A = 50 fardos, B = 40 fardos.
--
--   Alta  · usos_pendientes 0 -> 6, se completa un bloque, sale 1 fardo de B.
--           A = 50, B = 39.  (lo hace bien desde la 132)
--   Cancelacion, ANTES de esta migracion:
--           revertir devuelve 1 fardo a A.   A = 51, B = 39.  <- cruzado
--   Cancelacion, DESPUES:
--           revertir devuelve 1 fardo a B.   A = 50, B = 40.  <- cerro donde abrio
--
-- El cruce es exactamente esto, medido en prod: 7 unidades en 6 pedidos, promos
-- 12 y 13. No se corrigen aca (ver "Lo que esta migracion NO hace").
--
-- QUE CAMBIA
--
--   1 · `revertir_bloques_auto_ajuste` recibe `p_contenedor_id BIGINT DEFAULT NULL`,
--       con fallback a `promociones.ajuste_producto_id` -- que es lo que hacia
--       siempre, o sea que un llamador que no lo pase se comporta igual que hoy.
--       Es firma nueva, asi que la vieja se DROPEA en esta misma migracion
--       (Trampa 5: dos sobrecargas con rangos superpuestos = PGRST203 en runtime,
--       invisible para tsc y para los tests). Queda UNA sola sobrecarga.
--
--   2 · Los cuatro llamadores derivan el contenedor POR ITEM, con la misma
--       formula del alta, y agrupan por (promocion_id, contenedor) en vez de
--       solo por promocion_id. Partir el delta de una promo en varias llamadas
--       no cambia cuantos bloques se liberan en total -- ceil((d1+d2-u)/N) =
--       ceil((d1-u)/N) + ceil((d1+d2-u-b1*N)/N) -- solo a que contenedor se le
--       acredita cada uno, que es de lo que se trata. Donde antes quedaba un
--       `promo_ajustes` por promo ahora queda uno por promo y contenedor: esa es
--       la granularidad correcta, y es la que el check nuevo mira.
--
--   3 · `crear_pedido_completo_bot` gana la derivacion que `crear_pedido_completo`
--       tiene desde la 096. Hoy no hay pedidos con canal='bot' en prod, asi que
--       no arrastra nada; se empareja ahora para que no nazca cruzado.
--
--   4 · `auditoria_integridad` suma PROMO-A (familia nueva): por promo y
--       contenedor, lo devuelto no puede superar lo descontado. Es el gate de
--       esta regla.
--
-- POR QUE EL ESPEJO DEL ALTA Y NO OTRA COSA
--
--   `promo_acumuladores` (mig 059) lleva una barra por (promo, sabor) con su
--   propio contenedor, pero solo la escribe `sustituir_regalo_pedido`. El alta
--   nunca crea filas ahi: suma los usos a la barra default
--   (`promociones.usos_pendientes`) y descuenta del contenedor del sabor. La
--   reversion tiene que ser el espejo exacto de eso -- misma barra, mismo
--   contenedor -- o el pedido no cierra donde abrio. De paso: las 7 filas de
--   `promo_acumuladores` en prod tienen `ajuste_producto_id = producto_regalo_id`,
--   igual que las dos promos con auto-ajuste, asi que las dos fuentes coinciden.
--
-- LO QUE ESTA MIGRACION NO HACE
--
--   · No corrige los cruces historicos. Quedan listados en el PR para que el
--     dueño decida: son 7 unidades, y moverlas es un ajuste de stock con nombre
--     y fecha, no un efecto secundario de un cambio de funciones.
--   · No toca la lista blanca de `sincronizar_lotes_stock`: el origen de la
--     reversion sigue siendo 'auto_ajuste_promo', que ya esta adentro.
--   · No toca la firma de las tres RPCs que llama el front
--     (`crear_pedido_completo`, `actualizar_pedido_items`,
--     `cancelar_pedido_con_stock`), asi que no hay nada que tocar en
--     `src/hooks/queries` ni en ningun schema Zod.
--   · No resuelve la decision #621 (anular_salvedad) aunque toque
--     `registrar_salvedad`: aca solo se corrige el contenedor.
--   · `trg_aplicar_sustituciones_regalo` reescribe `NEW.producto_id` al sustituto
--     DESPUES de que `actualizar_pedido_items` decidio de que producto descontar.
--     Ese desfasaje es anterior a esta migracion y sigue igual; queda anotado en
--     el PR. Con o sin el, derivar el contenedor del item es mas cerca de la
--     verdad que leer siempre `ajuste_producto_id`.
--
-- Tecnica: parche por ancla sobre el cuerpo VIVO de cada funcion (mismo molde
-- que la mig 241). Las cinco funciones son largas y esto les toca tres lineas:
-- reescribirlas enteras seria pegar 60 KB de codigo que nadie diffea.

BEGIN;

-- ---------------------------------------------------------------------------
-- 0 · Andamio: parche por ancla, con la guarda de "exactamente una vez".
--     Se dropea al final. No queda ninguna funcion nueva viva salvo la del
--     punto 1.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._migct_ancla(
  p_funcion regprocedure, p_ancla text, p_nuevo text
) RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text;
  v_veces int;
BEGIN
  v_def := pg_get_functiondef(p_funcion);
  v_veces := (length(v_def) - length(replace(v_def, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El ancla aparece % veces en % (se esperaba exactamente 1). El cuerpo vivo cambio: revisar a mano. Ancla: %',
      v_veces, p_funcion, left(p_ancla, 120);
  END IF;
  EXECUTE replace(v_def, p_ancla, p_nuevo);
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 1 · revertir_bloques_auto_ajuste: ahora se le puede decir a que contenedor.
--
--     Firma nueva => se dropea la vieja (Trampa 5). Los cuatro llamadores se
--     actualizan mas abajo, en esta misma transaccion.
--
--     El guardado/restaurado de los cuatro GUCs de `app.stock_*` alrededor del
--     UPDATE sigue igual (mig 229): `set_config` es por transaccion, y este
--     helper tiene varios llamadores que ya tenian su propia etiqueta puesta.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.revertir_bloques_auto_ajuste(bigint, integer, bigint, uuid, text);

CREATE FUNCTION public.revertir_bloques_auto_ajuste(
  p_promocion_id  bigint,
  p_usos_delta    integer,
  p_sucursal_id   bigint,
  p_usuario_id    uuid,
  p_observaciones text   DEFAULT NULL::text,
  p_contenedor_id bigint DEFAULT NULL::bigint
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_promo              RECORD;
  v_contenedor         BIGINT;
  v_usos_antes         INT;
  v_usos_nuevos_raw    INT;
  v_bloques_a_revertir INT;
  v_usos_a_liberar     INT;
  v_usos_finales       INT;
  v_stock_a_devolver   INT;
  v_stock_anterior     INT;
  v_stock_nuevo        INT;
  v_merma_id           BIGINT;
  -- mig 229: set_config es por transaccion, asi que el GUC del que nos llamo
  -- se guarda y se restaura alrededor del UPDATE. Ver la cabecera.
  v_org_prev           text;
  v_ref_tipo_prev      text;
  v_ref_id_prev        text;
  v_user_prev          text;
BEGIN
  IF p_usos_delta IS NULL OR p_usos_delta <= 0 THEN
    RETURN COALESCE(
      (SELECT usos_pendientes FROM promociones
        WHERE id = p_promocion_id AND sucursal_id = p_sucursal_id), 0);
  END IF;

  SELECT id, nombre, ajuste_automatico, ajuste_producto_id,
         unidades_por_bloque, stock_por_bloque, usos_pendientes
    INTO v_promo
    FROM promociones
   WHERE id = p_promocion_id AND sucursal_id = p_sucursal_id
   FOR UPDATE;

  IF NOT FOUND THEN RETURN 0; END IF;

  -- El contenedor del que salio el bloque. Lo sabe el llamador, que tiene el
  -- item: si el regalo era de otro sabor, el fardo salio de ESE sabor (mig 096).
  -- El fallback a `ajuste_producto_id` es lo que esta funcion hacia siempre, y
  -- deja que un llamador que no sepa el contenedor siga funcionando igual.
  v_contenedor := COALESCE(p_contenedor_id, v_promo.ajuste_producto_id);

  v_usos_antes      := COALESCE(v_promo.usos_pendientes, 0);
  v_usos_nuevos_raw := v_usos_antes - p_usos_delta;

  IF NOT COALESCE(v_promo.ajuste_automatico, FALSE)
     OR v_contenedor IS NULL
     OR COALESCE(v_promo.unidades_por_bloque, 0) <= 0
     OR COALESCE(v_promo.stock_por_bloque, 0)   <= 0 THEN
    v_usos_finales := GREATEST(v_usos_nuevos_raw, 0);
    UPDATE promociones SET usos_pendientes = v_usos_finales
     WHERE id = p_promocion_id AND sucursal_id = p_sucursal_id;
    RETURN v_usos_finales;
  END IF;

  IF v_usos_nuevos_raw >= 0 THEN
    UPDATE promociones SET usos_pendientes = v_usos_nuevos_raw
     WHERE id = p_promocion_id AND sucursal_id = p_sucursal_id;
    RETURN v_usos_nuevos_raw;
  END IF;

  v_bloques_a_revertir := CEIL(
    ABS(v_usos_nuevos_raw)::NUMERIC / v_promo.unidades_por_bloque::NUMERIC
  )::INT;
  v_usos_a_liberar   := v_bloques_a_revertir * v_promo.unidades_por_bloque;
  v_usos_finales     := v_usos_nuevos_raw + v_usos_a_liberar;
  v_stock_a_devolver := v_bloques_a_revertir * v_promo.stock_por_bloque;

  SELECT stock INTO v_stock_anterior
    FROM productos
   WHERE id = v_contenedor AND sucursal_id = p_sucursal_id
   FOR UPDATE;

  v_stock_nuevo := COALESCE(v_stock_anterior, 0) + v_stock_a_devolver;

  v_org_prev      := current_setting('app.stock_origen', true);
  v_ref_tipo_prev := current_setting('app.stock_ref_tipo', true);
  v_ref_id_prev   := current_setting('app.stock_ref_id', true);
  v_user_prev     := current_setting('app.stock_user_id', true);

  PERFORM set_config('app.stock_origen', 'auto_ajuste_promo', true);
  PERFORM set_config('app.stock_ref_tipo', 'promocion', true);
  PERFORM set_config('app.stock_ref_id', p_promocion_id::TEXT, true);
  PERFORM set_config('app.stock_user_id', COALESCE(p_usuario_id::TEXT, ''), true);

  UPDATE productos SET stock = v_stock_nuevo, updated_at = NOW()
   WHERE id = v_contenedor AND sucursal_id = p_sucursal_id;

  PERFORM set_config('app.stock_origen',   COALESCE(v_org_prev, ''), true);
  PERFORM set_config('app.stock_ref_tipo', COALESCE(v_ref_tipo_prev, ''), true);
  PERFORM set_config('app.stock_ref_id',   COALESCE(v_ref_id_prev, ''), true);
  PERFORM set_config('app.stock_user_id',  COALESCE(v_user_prev, ''), true);

  INSERT INTO mermas_stock (
    producto_id, cantidad, motivo, observaciones,
    stock_anterior, stock_nuevo, usuario_id, sucursal_id
  ) VALUES (
    v_contenedor, -v_stock_a_devolver, 'promociones_reversion',
    COALESCE(p_observaciones, 'Reversion auto-ajuste') || ' (Promo: ' || v_promo.nombre || ')',
    COALESCE(v_stock_anterior, 0), v_stock_nuevo, p_usuario_id, p_sucursal_id
  ) RETURNING id INTO v_merma_id;

  INSERT INTO promo_ajustes (
    promocion_id, usos_ajustados, unidades_ajustadas, producto_id,
    merma_id, usuario_id, observaciones, sucursal_id
  ) VALUES (
    p_promocion_id, -v_usos_a_liberar, -v_stock_a_devolver, v_contenedor,
    v_merma_id, p_usuario_id,
    COALESCE(p_observaciones, 'Reversion auto-ajuste'),
    p_sucursal_id
  );

  UPDATE promociones SET usos_pendientes = v_usos_finales
   WHERE id = p_promocion_id AND sucursal_id = p_sucursal_id;

  RETURN v_usos_finales;
END;
$function$;

-- Funcion nueva => nace con EXECUTE para PUBLIC, y Supabase le da otro a `anon`
-- y a `authenticated` por default privileges. Se revocan las tres en la misma
-- migracion (CLAUDE.md). `authenticated` tambien se va, aunque la firma vieja lo
-- tenia: los cuatro llamadores son SECURITY DEFINER de postgres -- la ejecutan
-- como postgres, no como el caller -- y nadie la llama por PostgREST (no aparece
-- en `src/` ni en `supabase/functions/`).
REVOKE ALL ON FUNCTION public.revertir_bloques_auto_ajuste(bigint, integer, bigint, uuid, text, bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.revertir_bloques_auto_ajuste(bigint, integer, bigint, uuid, text, bigint)
  TO postgres, service_role;

-- ---------------------------------------------------------------------------
-- 2 · actualizar_pedido_items · tres anclas.
--
--     (a) una variable para el contenedor;
--     (b) la devolucion agrupa por (promo, contenedor);
--     (c) el auto-ajuste del re-insert descuenta del contenedor del item, igual
--         que el alta.
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE v_fn regprocedure := 'public.actualizar_pedido_items(bigint, jsonb, uuid)'::regprocedure;
BEGIN
  PERFORM public._migct_ancla(v_fn,
$ancla$  v_merma_id BIGINT;
  v_pedido_creator UUID;$ancla$,
$nuevo$  v_merma_id BIGINT;
  v_container_id BIGINT;
  v_pedido_creator UUID;$nuevo$);

  -- (b) El LEFT JOIN preserva el comportamiento de antes para un item cuya
  -- promocion_id ya no existe: contenedor NULL, y revertir_bloques_auto_ajuste
  -- devuelve 0 sin tocar nada.
  PERFORM public._migct_ancla(v_fn,
$ancla$  FOR v_bonif IN
    SELECT promocion_id, SUM(cantidad)::INT AS total_cantidad
      FROM pedido_items
     WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal
       AND COALESCE(es_bonificacion, false) = true AND promocion_id IS NOT NULL
     GROUP BY promocion_id
  LOOP
    PERFORM public.revertir_bloques_auto_ajuste(
      v_bonif.promocion_id, v_bonif.total_cantidad, v_sucursal,
      p_usuario_id, 'Edicion pedido #' || p_pedido_id
    );
  END LOOP;$ancla$,
$nuevo$  FOR v_bonif IN
    SELECT pi.promocion_id AS promocion_id,
           CASE WHEN pr.producto_regalo_id IS DISTINCT FROM pi.producto_id
                THEN pi.producto_id ELSE pr.ajuste_producto_id END AS contenedor_id,
           SUM(pi.cantidad)::INT AS total_cantidad
      FROM pedido_items pi
      LEFT JOIN promociones pr
        ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
     WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
       AND COALESCE(pi.es_bonificacion, false) = true AND pi.promocion_id IS NOT NULL
     GROUP BY 1, 2
  LOOP
    PERFORM public.revertir_bloques_auto_ajuste(
      v_bonif.promocion_id, v_bonif.total_cantidad, v_sucursal,
      p_usuario_id, 'Edicion pedido #' || p_pedido_id,
      v_bonif.contenedor_id
    );
  END LOOP;$nuevo$);

  -- (c) Mismo CASE que crear_pedido_completo (mig 096/132).
  PERFORM public._migct_ancla(v_fn,
$ancla$      SELECT id, nombre, ajuste_automatico, ajuste_producto_id, unidades_por_bloque,
             stock_por_bloque, usos_pendientes
      INTO v_promo
      FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal FOR UPDATE;

      IF v_promo.ajuste_automatico AND v_promo.ajuste_producto_id IS NOT NULL$ancla$,
$nuevo$      SELECT id, nombre, ajuste_automatico, ajuste_producto_id, unidades_por_bloque,
             stock_por_bloque, usos_pendientes, producto_regalo_id
      INTO v_promo
      FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal FOR UPDATE;

      v_container_id := CASE WHEN v_promo.producto_regalo_id IS DISTINCT FROM v_producto_id
                             THEN v_producto_id ELSE v_promo.ajuste_producto_id END;

      IF v_promo.ajuste_automatico AND v_container_id IS NOT NULL$nuevo$);

  PERFORM public._migct_ancla(v_fn,
$ancla$          SELECT stock, nombre INTO v_stock_ajuste_anterior, v_ajuste_producto_nombre
          FROM productos WHERE id = v_promo.ajuste_producto_id AND sucursal_id = v_sucursal FOR UPDATE;$ancla$,
$nuevo$          SELECT stock, nombre INTO v_stock_ajuste_anterior, v_ajuste_producto_nombre
          FROM productos WHERE id = v_container_id AND sucursal_id = v_sucursal FOR UPDATE;$nuevo$);

  PERFORM public._migct_ancla(v_fn,
$ancla$          VALUES (v_promo.ajuste_producto_id, v_ajustar_stock, 'promociones',$ancla$,
$nuevo$          VALUES (v_container_id, v_ajustar_stock, 'promociones',$nuevo$);

  PERFORM public._migct_ancla(v_fn,
$ancla$          UPDATE productos SET stock = v_stock_ajuste_nuevo, updated_at = NOW()
          WHERE id = v_promo.ajuste_producto_id AND sucursal_id = v_sucursal;$ancla$,
$nuevo$          UPDATE productos SET stock = v_stock_ajuste_nuevo, updated_at = NOW()
          WHERE id = v_container_id AND sucursal_id = v_sucursal;$nuevo$);

  PERFORM public._migct_ancla(v_fn,
$ancla$          VALUES (v_promocion_id, v_ajustar_usos, v_ajustar_stock, v_promo.ajuste_producto_id,$ancla$,
$nuevo$          VALUES (v_promocion_id, v_ajustar_usos, v_ajustar_stock, v_container_id,$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 3 · cancelar_pedido_con_stock · el loop v_promo_rev de la mig 235.
--
--     Lo que la 235 agrupaba por promocion ahora se agrupa por promocion Y
--     contenedor: dos renglones de la misma promo con sabores distintos son dos
--     deltas, no uno, porque devuelven a fardos distintos.
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._migct_ancla('public.cancelar_pedido_con_stock(bigint, text, uuid, text)'::regprocedure,
$ancla$  -- Agrupado por promocion a proposito: dos renglones de la misma promo son un
  -- solo delta y dejan un solo promo_ajustes, no dos.
  --
  -- El helper guarda y restaura los cuatro GUCs de app.stock_* alrededor de su
  -- UPDATE (mig 229), asi que el 'pedido_cancelado' de arriba sigue valiendo
  -- para el resto del cuerpo.
  FOR v_promo_rev IN
    SELECT pi.promocion_id AS promocion_id, SUM(pi.cantidad)::INT AS cantidad
      FROM pedido_items pi
     WHERE pi.pedido_id = p_pedido_id
       AND pi.sucursal_id = v_sucursal
       AND COALESCE(pi.es_bonificacion, false) = true
       AND pi.promocion_id IS NOT NULL
     GROUP BY pi.promocion_id
  LOOP
    PERFORM public.revertir_bloques_auto_ajuste(
      v_promo_rev.promocion_id, v_promo_rev.cantidad, v_sucursal,
      v_acting_user, 'Cancelacion pedido #' || p_pedido_id);
  END LOOP;$ancla$,
$nuevo$  -- Agrupado por promocion Y CONTENEDOR: dos renglones de la misma promo con
  -- sabores distintos salieron de fardos distintos, asi que son dos deltas y
  -- dejan un promo_ajustes cada uno. El contenedor se deriva por item con la
  -- misma formula del alta (mig 096/132).
  --
  -- El helper guarda y restaura los cuatro GUCs de app.stock_* alrededor de su
  -- UPDATE (mig 229), asi que el 'pedido_cancelado' de arriba sigue valiendo
  -- para el resto del cuerpo.
  FOR v_promo_rev IN
    SELECT pi.promocion_id AS promocion_id,
           CASE WHEN pr.producto_regalo_id IS DISTINCT FROM pi.producto_id
                THEN pi.producto_id ELSE pr.ajuste_producto_id END AS contenedor_id,
           SUM(pi.cantidad)::INT AS cantidad
      FROM pedido_items pi
      LEFT JOIN promociones pr
        ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
     WHERE pi.pedido_id = p_pedido_id
       AND pi.sucursal_id = v_sucursal
       AND COALESCE(pi.es_bonificacion, false) = true
       AND pi.promocion_id IS NOT NULL
     GROUP BY 1, 2
  LOOP
    PERFORM public.revertir_bloques_auto_ajuste(
      v_promo_rev.promocion_id, v_promo_rev.cantidad, v_sucursal,
      v_acting_user, 'Cancelacion pedido #' || p_pedido_id,
      v_promo_rev.contenedor_id);
  END LOOP;$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 4 · eliminar_pedido_completo · ya recorria item por item, solo le faltaba el
--     contenedor de cada uno.
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE v_fn regprocedure := 'public.eliminar_pedido_completo(bigint, uuid, text, boolean)'::regprocedure;
BEGIN
  PERFORM public._migct_ancla(v_fn,
$ancla$      SELECT pi.producto_id, pi.cantidad, COALESCE(pi.es_bonificacion, false) AS es_bonificacion,
             pi.promocion_id, COALESCE(pr.regalo_mueve_stock, FALSE) AS regalo_mueve_stock
      FROM pedido_items pi$ancla$,
$nuevo$      SELECT pi.producto_id, pi.cantidad, COALESCE(pi.es_bonificacion, false) AS es_bonificacion,
             pi.promocion_id, COALESCE(pr.regalo_mueve_stock, FALSE) AS regalo_mueve_stock,
             CASE WHEN pr.producto_regalo_id IS DISTINCT FROM pi.producto_id
                  THEN pi.producto_id ELSE pr.ajuste_producto_id END AS contenedor_id
      FROM pedido_items pi$nuevo$);

  PERFORM public._migct_ancla(v_fn,
$ancla$        PERFORM public.revertir_bloques_auto_ajuste(
          v_item.promocion_id, v_item.cantidad::INT, v_sucursal,
          p_usuario_id, 'Eliminacion pedido #' || p_pedido_id
        );$ancla$,
$nuevo$        PERFORM public.revertir_bloques_auto_ajuste(
          v_item.promocion_id, v_item.cantidad::INT, v_sucursal,
          p_usuario_id, 'Eliminacion pedido #' || p_pedido_id,
          v_item.contenedor_id
        );$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 5 · registrar_salvedad · dos llamadas, las dos con el item a mano.
--
--     El contenedor va como subconsulta escalar en vez de variable nueva: las
--     dos llamadas ya tienen el producto del renglon, y una subconsulta de una
--     fila por promo es mas barata que arrastrar estado por una funcion de 300
--     lineas que ya tiene 25 variables.
--
--     Esta funcion tambien es la que toca la decision #621 (anular_salvedad).
--     No se resuelve aca.
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE v_fn regprocedure := 'public.registrar_salvedad(bigint, bigint, integer, character varying, text, text, boolean, uuid)'::regprocedure;
BEGIN
  PERFORM public._migct_ancla(v_fn,
$ancla$    PERFORM public.revertir_bloques_auto_ajuste(
      v_item.promocion_id, p_cantidad_afectada, v_sucursal,
      v_usuario_id, 'Salvedad sobre regalo, pedido #' || p_pedido_id
    );$ancla$,
$nuevo$    PERFORM public.revertir_bloques_auto_ajuste(
      v_item.promocion_id, p_cantidad_afectada, v_sucursal,
      v_usuario_id, 'Salvedad sobre regalo, pedido #' || p_pedido_id,
      (SELECT CASE WHEN pr.producto_regalo_id IS DISTINCT FROM v_item.producto_id
                   THEN v_item.producto_id ELSE pr.ajuste_producto_id END
         FROM promociones pr
        WHERE pr.id = v_item.promocion_id AND pr.sucursal_id = v_sucursal)
    );$nuevo$);

  PERFORM public._migct_ancla(v_fn,
$ancla$      PERFORM public.revertir_bloques_auto_ajuste(
        v_bonif.promocion_id, v_diff, v_sucursal,
        v_usuario_id, 'Salvedad pedido #' || p_pedido_id
      );$ancla$,
$nuevo$      PERFORM public.revertir_bloques_auto_ajuste(
        v_bonif.promocion_id, v_diff, v_sucursal,
        v_usuario_id, 'Salvedad pedido #' || p_pedido_id,
        (SELECT CASE WHEN pr.producto_regalo_id IS DISTINCT FROM v_bonif.producto_id
                     THEN v_bonif.producto_id ELSE pr.ajuste_producto_id END
           FROM promociones pr
          WHERE pr.id = v_bonif.promocion_id AND pr.sucursal_id = v_sucursal)
      );$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 6 · crear_pedido_completo_bot · la derivacion que le falta desde la 096.
--
--     La 096 la dejo afuera a proposito ("el bot nunca overridea"). Hoy el bot
--     toma pedidos con `bot_pedidos_pendientes.items`, que puede traer una
--     bonificacion de cualquier sabor, y no hay ningun pedido con canal='bot' en
--     prod todavia: el momento de emparejarlo es antes del primero, no despues.
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE v_fn regprocedure := 'public.crear_pedido_completo_bot(uuid, uuid)'::regprocedure;
BEGIN
  PERFORM public._migct_ancla(v_fn,
$ancla$  v_merma_id BIGINT;
BEGIN$ancla$,
$nuevo$  v_merma_id BIGINT;
  v_container_id BIGINT;
BEGIN$nuevo$);

  PERFORM public._migct_ancla(v_fn,
$ancla$      SELECT id, nombre, ajuste_automatico, ajuste_producto_id, unidades_por_bloque,
             stock_por_bloque, usos_pendientes
        INTO v_promo
        FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_pendiente.sucursal_id FOR UPDATE;

      IF v_promo.ajuste_automatico AND v_promo.ajuste_producto_id IS NOT NULL$ancla$,
$nuevo$      SELECT id, nombre, ajuste_automatico, ajuste_producto_id, unidades_por_bloque,
             stock_por_bloque, usos_pendientes, producto_regalo_id
        INTO v_promo
        FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_pendiente.sucursal_id FOR UPDATE;

      -- Mismo CASE que crear_pedido_completo (mig 096/132).
      v_container_id := CASE WHEN v_promo.producto_regalo_id IS DISTINCT FROM v_producto_id
                             THEN v_producto_id ELSE v_promo.ajuste_producto_id END;

      IF v_promo.ajuste_automatico AND v_container_id IS NOT NULL$nuevo$);

  PERFORM public._migct_ancla(v_fn,
$ancla$          SELECT stock, nombre INTO v_stock_ajuste_anterior, v_ajuste_producto_nombre
            FROM productos WHERE id = v_promo.ajuste_producto_id AND sucursal_id = v_pendiente.sucursal_id FOR UPDATE;$ancla$,
$nuevo$          SELECT stock, nombre INTO v_stock_ajuste_anterior, v_ajuste_producto_nombre
            FROM productos WHERE id = v_container_id AND sucursal_id = v_pendiente.sucursal_id FOR UPDATE;$nuevo$);

  PERFORM public._migct_ancla(v_fn,
$ancla$            v_promo.ajuste_producto_id, v_ajustar_stock, 'promociones',$ancla$,
$nuevo$            v_container_id, v_ajustar_stock, 'promociones',$nuevo$);

  PERFORM public._migct_ancla(v_fn,
$ancla$          UPDATE productos SET stock = v_stock_ajuste_nuevo, updated_at = NOW()
            WHERE id = v_promo.ajuste_producto_id AND sucursal_id = v_pendiente.sucursal_id;$ancla$,
$nuevo$          UPDATE productos SET stock = v_stock_ajuste_nuevo, updated_at = NOW()
            WHERE id = v_container_id AND sucursal_id = v_pendiente.sucursal_id;$nuevo$);

  PERFORM public._migct_ancla(v_fn,
$ancla$            v_promocion_id, v_ajustar_usos, v_ajustar_stock, v_promo.ajuste_producto_id,$ancla$,
$nuevo$            v_promocion_id, v_ajustar_usos, v_ajustar_stock, v_container_id,$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 7 · auditoria_integridad · PROMO-A.
--
--     `promo_ajustes` es el libro del auto-ajuste: una fila positiva por cada
--     bloque que se descuenta y una negativa por cada uno que vuelve, las dos
--     con el contenedor en `producto_id`. Devolverle a un contenedor mas fardos
--     de los que se le sacaron es imposible si cada reversion va al mismo fardo
--     del que salio -- y es la firma exacta del cruce que esta migracion cierra.
--
--     Va sin ventana de fechas: hoy prod no tiene ni un grupo en negativo (los 7
--     cruces historicos quedaron enmascarados porque el contenedor default tiene
--     consumo propio de sobra). Si alguna vez aparece una cohorte legacy que no
--     se pueda corregir, el centinela es acotarlo con `created_at >` la fecha de
--     su correccion, como hace CC-B.
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._migct_ancla('public.auditoria_integridad()'::regprocedure,
$ancla$    ('STK-F','high','funciones de public que suben stock sin declarar app.stock_origen (mig 229)',$ancla$,
$nuevo$    ('PROMO-A','high','promo_ajustes: ningun (promo, contenedor) devolvio mas fardos de los que se le descontaron (mig 242)',
      (SELECT count(*) FROM (
         SELECT promocion_id, sucursal_id, producto_id
           FROM promo_ajustes
          WHERE producto_id IS NOT NULL
          GROUP BY 1,2,3
         HAVING SUM(COALESCE(unidades_ajustadas,0)) < 0) x)),
    ('STK-F','high','funciones de public que suben stock sin declarar app.stock_origen (mig 229)',$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 8 · El ensayo: el pedido tiene que cerrar donde abrio.
--
--     Promo sintetica con producto_regalo_id = A, pedido con el regalo del sabor
--     B, cancelacion, y los stocks de A y B contra el inicial. Con el codigo de
--     antes el fardo volvia a A y esto termina en A = inicial+1, B = inicial-1.
--
--     Todo el ensayo vive en un sub-bloque que se deshace solo: se levanta una
--     excepcion con un SQLSTATE centinela al final del camino feliz, que revierte
--     los datos de prueba y deja seguir a la migracion. Si la verificacion falla,
--     la excepcion es otra y se propaga: la migracion no entra.
--
--     Se hace pasar por un admin (set_config local, se descarta al COMMIT), que
--     es lo que `crear_pedido_completo` y `cancelar_pedido_con_stock` exigen.
-- ---------------------------------------------------------------------------
DO $ensayo$
DECLARE
  v_admin     uuid;
  v_suc       bigint;
  v_cliente   bigint;
  v_prod_a    bigint;
  v_prod_b    bigint;
  v_prod_c    bigint;
  v_promo     bigint;
  v_res       jsonb;
  v_pedido    bigint;
  v_stock_a   int;
  v_stock_b   int;
  v_stock_c   int;
BEGIN
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'migct · el ensayo necesita un admin activo con al menos una sucursal activa';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  -- El pedido del ensayo es de $100: la compra minima de la sucursal no tiene
  -- nada que decir sobre un pedido que no existe fuera de esta transaccion.
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  PERFORM set_config('app.omitir_minimo_venta', '1', true);

  SELECT id INTO v_cliente FROM clientes
   WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;
  IF v_cliente IS NULL THEN
    RAISE EXCEPTION 'migct · el ensayo necesita un cliente activo en la sucursal %', v_suc;
  END IF;

  BEGIN
    INSERT INTO productos (nombre, precio, stock, sucursal_id)
    VALUES ('ZZ ensayo mig242 contenedor A', 100, 50, v_suc) RETURNING id INTO v_prod_a;
    INSERT INTO productos (nombre, precio, stock, sucursal_id)
    VALUES ('ZZ ensayo mig242 contenedor B', 100, 40, v_suc) RETURNING id INTO v_prod_b;
    INSERT INTO productos (nombre, precio, stock, sucursal_id)
    VALUES ('ZZ ensayo mig242 producto vendido', 100, 10, v_suc) RETURNING id INTO v_prod_c;

    -- Un bloque = una unidad de regalo = un fardo del contenedor. Con eso el
    -- alta cierra un bloque con un solo renglon y el ensayo mide un entero.
    INSERT INTO promociones (
      nombre, tipo, fecha_inicio, sucursal_id, ajuste_automatico,
      ajuste_producto_id, producto_regalo_id, unidades_por_bloque,
      stock_por_bloque, regalo_mueve_stock, usos_pendientes
    ) VALUES (
      'ZZ ensayo mig242', 'bonificacion', CURRENT_DATE, v_suc, TRUE,
      v_prod_a, v_prod_a, 1, 1, FALSE, 0
    ) RETURNING id INTO v_promo;

    v_res := public.crear_pedido_completo(
      v_cliente, 100, v_admin,
      jsonb_build_array(
        jsonb_build_object('producto_id', v_prod_c, 'cantidad', 1, 'precio_unitario', 100),
        jsonb_build_object('producto_id', v_prod_b, 'cantidad', 1, 'precio_unitario', 0,
                           'es_bonificacion', true, 'promocion_id', v_promo)),
      'ensayo mig242');

    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'migct · el ensayo no pudo crear el pedido: %', v_res;
    END IF;
    v_pedido := (v_res->>'pedido_id')::bigint;

    -- El alta ya descuenta del contenedor correcto desde la mig 132: si esto no
    -- se cumple, lo que cambio es el alta y el resto del ensayo no significa nada.
    SELECT stock INTO v_stock_b FROM productos WHERE id = v_prod_b;
    SELECT stock INTO v_stock_a FROM productos WHERE id = v_prod_a;
    IF v_stock_b <> 39 OR v_stock_a <> 50 THEN
      RAISE EXCEPTION 'migct · el alta no descontó del contenedor elegido: A=% (esperado 50), B=% (esperado 39)',
        v_stock_a, v_stock_b;
    END IF;

    v_res := public.cancelar_pedido_con_stock(v_pedido, 'ensayo mig242', v_admin, 'prueba');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'migct · el ensayo no pudo cancelar el pedido: %', v_res;
    END IF;

    SELECT stock INTO v_stock_a FROM productos WHERE id = v_prod_a;
    SELECT stock INTO v_stock_b FROM productos WHERE id = v_prod_b;
    SELECT stock INTO v_stock_c FROM productos WHERE id = v_prod_c;

    IF v_stock_a <> 50 OR v_stock_b <> 40 OR v_stock_c <> 10 THEN
      RAISE EXCEPTION
        'migct · el fardo no volvio al contenedor del que salio: A=% (esperado 50), B=% (esperado 40), vendido=% (esperado 10)',
        v_stock_a, v_stock_b, v_stock_c;
    END IF;

    -- Camino feliz: se deshace todo lo que el ensayo creo.
    RAISE EXCEPTION 'migct-ok' USING ERRCODE = '2F000';
  EXCEPTION WHEN SQLSTATE '2F000' THEN
    IF SQLERRM <> 'migct-ok' THEN RAISE; END IF;
    RAISE NOTICE 'migct · ensayo OK: el regalo de sabor distinto salio y volvio al mismo contenedor';
  END;
END
$ensayo$;

-- ---------------------------------------------------------------------------
-- 9 · Se saca el andamio.
--     CREATE OR REPLACE preserva la ACL de las cinco funciones parcheadas; la
--     unica con ACL nueva es revertir_bloques_auto_ajuste, ya revocada arriba.
-- ---------------------------------------------------------------------------
DROP FUNCTION public._migct_ancla(regprocedure, text, text);

COMMIT;
