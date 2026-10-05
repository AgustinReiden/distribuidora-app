-- XXX — Sustituir un regalo no toca un pedido cancelado (#841)
--
-- `sustituir_regalo_pedido` sólo rechazaba `estado = 'entregado'`. En un pedido
-- `cancelado` o `anulado` el stock ya se devolvió (cancelar_pedido), así que
-- sustituir el regalo en modo A lo devolvía OTRA vez (stock + cantidad del
-- original) y descontaba el sustituto de un pedido que no existe; en modo B
-- movía los acumuladores de la promo por un regalo que nunca se va a entregar.
-- `dividir_regalo_pedido` (mig 275) ya rechazaba esos dos estados; acá se le
-- pone la misma guarda a sustituir, con el mismo estilo de retorno.
--
-- El cuerpo parte de la definición VIGENTE en prod (pg_get_functiondef al
-- 2026-10-05), no del repo. El único cambio es la guarda; el manejo de stock
-- (modo A etiquetado 'sustitucion_regalo', de la lista blanca de
-- trg_lotes_sincronizar; modo B por aplicar_uso_promo_acumulador) queda igual.
-- La firma no cambia, así que CREATE OR REPLACE conserva owner y ACL; igual se
-- reafirman los grants vigentes (postgres, authenticated, service_role).

CREATE OR REPLACE FUNCTION public.sustituir_regalo_pedido(p_pedido_item_id bigint, p_producto_nuevo_id bigint, p_cantidad_nueva numeric, p_motivo text, p_ajuste_producto_id_nuevo bigint DEFAULT NULL::bigint, p_client_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id            UUID := auth.uid();
  v_user_role          TEXT;
  v_sucursal           BIGINT := current_sucursal_id();
  v_item               RECORD;
  v_promo              RECORD;
  v_stock_nuevo        NUMERIC;
  v_regalo_mueve_stock BOOLEAN;
  v_sust_id            BIGINT;
  v_existing           RECORD;
  v_nuevo_nombre       TEXT;
  v_ajuste_sustituto_efectivo BIGINT;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No hay sucursal activa');
  END IF;
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autenticado');
  END IF;
  IF p_client_request_id IS NOT NULL THEN
    SELECT id INTO v_existing
      FROM pedido_item_sustituciones
     WHERE client_request_id = p_client_request_id;
    IF FOUND THEN
      RETURN jsonb_build_object('success', true, 'sustitucion_id', v_existing.id, 'idempotent_replay', true);
    END IF;
  END IF;
  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_user_id;
  IF v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin o encargado pueden sustituir regalos');
  END IF;
  IF p_cantidad_nueva IS NULL OR p_cantidad_nueva <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'La cantidad sustituta debe ser mayor a 0');
  END IF;
  SELECT pi.id, pi.pedido_id, pi.producto_id, pi.cantidad, pi.es_bonificacion,
         pi.promocion_id, pi.sucursal_id, p.estado AS pedido_estado
    INTO v_item
    FROM pedido_items pi
    JOIN pedidos p ON p.id = pi.pedido_id
   WHERE pi.id = p_pedido_item_id AND pi.sucursal_id = v_sucursal
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Item no encontrado');
  END IF;
  IF NOT COALESCE(v_item.es_bonificacion, FALSE) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo se pueden sustituir items marcados como bonificacion');
  END IF;
  IF v_item.pedido_estado = 'entregado' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se puede sustituir un regalo en un pedido ya entregado');
  END IF;
  /* #841 · un cancelado/anulado ya tiene el stock devuelto: sustituir
     lo devolveria otra vez y descontaria el sustituto de un pedido que no
     existe. Misma guarda que dividir_regalo_pedido (mig 275). */
  IF v_item.pedido_estado IN ('cancelado', 'anulado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se puede cambiar el regalo de un pedido cancelado');
  END IF;
  /* mig 240 · sin promocion no hay sustitucion.
     v_promo se cargaba solo si habia promocion_id y dos lineas despues se leia
     igual (COALESCE(v_promo.regalo_mueve_stock, TRUE)): con un bonificado sin
     promocion la funcion moria con 'record "v_promo" is not assigned yet' y el
     EXCEPTION lo devolvia como si fuera una validacion. Ahora se rechaza
     antes, con un mensaje que dice que hacer. */
  IF v_item.promocion_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Este regalo no viene de una promoción, así que no se puede sustituir desde acá. Editá el pedido para cambiarlo.');
  END IF;
  SELECT id, regalo_mueve_stock, ajuste_automatico, producto_regalo_id,
         ajuste_producto_id, unidades_por_bloque, stock_por_bloque, usos_pendientes
    INTO v_promo FROM promociones WHERE id = v_item.promocion_id AND sucursal_id = v_sucursal;
  v_regalo_mueve_stock := COALESCE(v_promo.regalo_mueve_stock, TRUE);
  v_ajuste_sustituto_efectivo := COALESCE(p_ajuste_producto_id_nuevo, p_producto_nuevo_id);
  SELECT nombre INTO v_nuevo_nombre FROM productos WHERE id = p_producto_nuevo_id AND sucursal_id = v_sucursal;
  IF v_regalo_mueve_stock THEN
    SELECT stock INTO v_stock_nuevo FROM productos WHERE id = p_producto_nuevo_id AND sucursal_id = v_sucursal FOR UPDATE;
    IF v_stock_nuevo IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'Producto sustituto no existe en esta sucursal');
    END IF;
    IF v_stock_nuevo < p_cantidad_nueva THEN
      RETURN jsonb_build_object('success', false, 'error', 'Stock insuficiente del producto sustituto (' || v_stock_nuevo || ' disponible)');
    END IF;
    PERFORM set_config('app.stock_origen', 'sustitucion_regalo', true);
    PERFORM set_config('app.stock_ref_tipo', 'pedido', true);
    PERFORM set_config('app.stock_ref_id', v_item.pedido_id::TEXT, true);
    PERFORM set_config('app.stock_user_id', v_user_id::TEXT, true);
    UPDATE productos SET stock = stock + v_item.cantidad WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
    UPDATE productos SET stock = stock - p_cantidad_nueva WHERE id = p_producto_nuevo_id AND sucursal_id = v_sucursal;
  ELSE
    -- La barra default vive en promociones.usos_pendientes y el helper opera
    -- directo sobre ella (mig 221). No hay nada que sincronizar.
    PERFORM public.aplicar_uso_promo_acumulador(
      v_promo.id, v_item.producto_id, -v_item.cantidad,
      v_promo.ajuste_producto_id, v_sucursal, v_user_id,
      'sustitucion: salida del producto regalo original'
    );
    PERFORM public.aplicar_uso_promo_acumulador(
      v_promo.id, p_producto_nuevo_id, p_cantidad_nueva,
      v_ajuste_sustituto_efectivo, v_sucursal, v_user_id,
      'sustitucion: entrada del producto regalo sustituto'
    );
  END IF;
  UPDATE pedido_items
     SET producto_id = p_producto_nuevo_id, cantidad = p_cantidad_nueva, subtotal = 0,
         descripcion_regalo = COALESCE(descripcion_regalo, '') || ' [Sustituido por: ' || COALESCE(v_nuevo_nombre, '?') || ']',
         -- mig 257 (#673): era `costo_real` pelado --el costo de REPOSICION--,
         -- sin caer al promedio. Ahora la misma cascada que todos: la de la 238.
         costo_unitario_al_crear = (SELECT public.costo_valuacion(NULL, costo_promedio,
                                             costo_real, costo_sin_iva,
                                             COALESCE(impuestos_internos, 0))
                                      FROM productos
                                     WHERE id = p_producto_nuevo_id AND sucursal_id = v_sucursal)
   WHERE id = p_pedido_item_id;
  INSERT INTO pedido_item_sustituciones (
    pedido_id, pedido_item_id, promocion_id, producto_original_id, producto_sustituto_id,
    cantidad_original, cantidad_sustituta, regalo_mueve_stock_snapshot, ajuste_producto_id_nuevo,
    motivo, autorizado_por, sucursal_id, client_request_id
  ) VALUES (
    v_item.pedido_id, p_pedido_item_id, v_item.promocion_id, v_item.producto_id, p_producto_nuevo_id,
    v_item.cantidad, p_cantidad_nueva, v_regalo_mueve_stock, v_ajuste_sustituto_efectivo,
    p_motivo, v_user_id, v_sucursal, p_client_request_id
  ) RETURNING id INTO v_sust_id;
  INSERT INTO pedido_historial (
    pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id
  ) VALUES (
    v_item.pedido_id, v_user_id, 'sustitucion_regalo',
    'producto_id=' || v_item.producto_id || ' cantidad=' || v_item.cantidad,
    'producto_id=' || p_producto_nuevo_id || ' cantidad=' || p_cantidad_nueva || ' motivo=' || p_motivo,
    v_sucursal
  );
  RETURN jsonb_build_object('success', true, 'sustitucion_id', v_sust_id,
    'modo', CASE WHEN v_regalo_mueve_stock THEN 'A' ELSE 'B' END);
/* mig 240 · el handler generico traducia TODO a {success:false}: un bug de
   programacion llegaba al usuario con la misma cara que "stock insuficiente",
   y no habia forma de distinguirlos ni desde el front ni desde Sentry. Quedan
   los dos SQLSTATE que vale la pena traducir; el resto propaga. */
EXCEPTION
  WHEN unique_violation THEN
    -- El unico indice unico de pedido_item_sustituciones aparte del PK es el
    -- parcial sobre client_request_id: dos envios simultaneos de la misma
    -- sustitucion. El que perdio la carrera lee lo que el otro ya commiteo y
    -- devuelve el mismo replay que la guarda de arriba.
    SELECT id INTO v_existing
      FROM pedido_item_sustituciones
     WHERE client_request_id = p_client_request_id;
    IF FOUND THEN
      RETURN jsonb_build_object('success', true, 'sustitucion_id', v_existing.id, 'idempotent_replay', true);
    END IF;
    RAISE;
  WHEN raise_exception THEN
    -- P0001: las validaciones de negocio de los triggers de pedido_items
    -- (validar_minimo_venta_item, validar_precio_item_pedido). Son mensajes
    -- escritos para el usuario.
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$function$;

-- Grants vigentes en prod: {postgres=X, authenticated=X, service_role=X}.
-- La RPC la llama el front (ModalSustituirRegalo), así que va la receta de dos
-- mitades: fuera PUBLIC y anon, adentro authenticated (y service_role).
REVOKE ALL ON FUNCTION public.sustituir_regalo_pedido(bigint, bigint, numeric, text, bigint, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sustituir_regalo_pedido(bigint, bigint, numeric, text, bigint, uuid) TO authenticated, service_role;

DO $verif$
DECLARE
  v_def text;
  v_acl text;
BEGIN
  v_def := pg_get_functiondef('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)'::regprocedure);
  IF v_def NOT LIKE '%pedido_estado IN (''cancelado'', ''anulado'')%'
     OR v_def NOT LIKE '%No se puede cambiar el regalo de un pedido cancelado%' THEN
    RAISE EXCEPTION 'sustituir_regalo_pedido no tiene la guarda de cancelado/anulado (#841)';
  END IF;
  -- La guarda tiene que ir ANTES de mover stock o acumuladores.
  IF position('No se puede cambiar el regalo de un pedido cancelado' IN v_def)
     > position('app.stock_origen' IN v_def) THEN
    RAISE EXCEPTION 'la guarda de cancelado quedo despues del movimiento de stock';
  END IF;
  -- El resto del cuerpo sigue en pie.
  IF v_def NOT LIKE '%''sustitucion_regalo''%' OR v_def NOT LIKE '%costo_valuacion%'
     OR v_def NOT LIKE '%pedido ya entregado%' THEN
    RAISE EXCEPTION 'sustituir_regalo_pedido perdio parte del cuerpo vigente';
  END IF;
  -- Grants: nadie mas que postgres, authenticated y service_role.
  SELECT proacl::text INTO v_acl FROM pg_proc
   WHERE oid = 'public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)'::regprocedure;
  IF v_acl LIKE '%anon=%' OR v_acl LIKE '%{=X%' OR v_acl LIKE '%,=X%'
     OR v_acl NOT LIKE '%authenticated=X%' THEN
    RAISE EXCEPTION 'grants de sustituir_regalo_pedido inesperados: %', v_acl;
  END IF;
END
$verif$;
