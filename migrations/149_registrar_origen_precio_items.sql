-- =========================================================================
-- 149_registrar_origen_precio_items.sql
--
-- La mig 148 dejó el trigger completando lo que el server puede computar solo:
-- el precio de lista al crear y la magnitud del descuento. Lo que el server NO
-- puede saber es POR QUÉ ese precio: la precedencia real (promo → mayorista →
-- descuento del cliente, y el override manual por encima de todo) vive en
-- TypeScript, con escalas combinadas, `min_productos_distintos` y overrides por
-- producto. Reimplementarla en PL/pgSQL sería duplicar lógica compleja con alto
-- riesgo de divergencia silenciosa.
--
-- POR QUÉ UN RPC APARTE Y NO UN CAMPO MÁS EN EL JSONB DE `crear_pedido_completo`
--
-- El plan preveía pasarlo dentro de `p_items`. Eso obliga a reescribir tres
-- funciones de ~14k caracteres cada una —`crear_pedido_completo`,
-- `crear_pedido_completo_bot` y `actualizar_pedido_items`—, que son
-- exactamente las que, si se rompen, dejan a la distribuidora sin poder tomar
-- pedidos. El origen del precio es metadato analítico: no participa del total,
-- ni del stock, ni del saldo. No justifica ese riesgo.
--
-- El flujo de alta ya es multi-paso (crear pedido → descontar stock → registrar
-- pago), así que un paso más es idiomático acá.
--
-- CONSECUENCIA ASUMIDA: si esta llamada falla o no se hace (cola offline que
-- reenvía sólo `crear_pedido_completo`, bot), los ítems quedan en
-- 'desconocido'. No quedan mal: quedan sin etiquetar, y `calcular_comisiones`
-- los va a contar y mostrar como "sin desglose". Es una pérdida de resolución
-- visible, no un dato falso.
--
-- Guarda de integridad: sólo completa ítems cuyo origen sea NULL o
-- 'desconocido'. No es una vía para reescribir la historia de un pedido viejo.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.registrar_origen_precio_items(
  p_pedido_id bigint,
  p_origenes  jsonb,
  -- Sólo se usa cuando no hay sesión (el bot corre con service role y
  -- `auth.uid()` es NULL). Con sesión se ignora y manda el usuario real.
  p_perfil_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_uid          uuid := auth.uid();
  v_caller       uuid;
  v_dueno        uuid;
  v_sucursal     bigint;
  v_actualizados integer := 0;
  v_fila         integer;
  item           jsonb;
  v_origen       text;
BEGIN
  SELECT usuario_id, sucursal_id INTO v_dueno, v_sucursal
  FROM pedidos WHERE id = p_pedido_id;

  IF v_dueno IS NULL AND v_sucursal IS NULL THEN
    RAISE EXCEPTION 'Pedido % inexistente', p_pedido_id USING ERRCODE = 'no_data_found';
  END IF;

  v_caller := COALESCE(v_uid, p_perfil_id);

  -- Mismo criterio que la policy de SELECT de pedido_items: lo puede completar
  -- quien puede ver el pedido. El UPDATE directo está reservado a preventistas
  -- por RLS, por eso esta función es SECURITY DEFINER y revalida acá.
  IF NOT (es_encargado_o_admin() OR (v_caller IS NOT NULL AND v_caller = v_dueno)) THEN
    RAISE EXCEPTION 'Sin permiso para registrar el origen del precio de este pedido'
      USING ERRCODE = '42501';
  END IF;

  IF p_origenes IS NULL OR jsonb_typeof(p_origenes) <> 'array' THEN
    RETURN jsonb_build_object('success', true, 'actualizados', 0);
  END IF;

  FOR item IN SELECT * FROM jsonb_array_elements(p_origenes)
  LOOP
    v_origen := item->>'origen_precio';

    -- Un valor fuera de la lista abortaría por el CHECK de la mig 148 y se
    -- llevaría puesto el resto del lote. Se saltea el ítem y se sigue.
    IF v_origen IS NULL OR v_origen NOT IN (
      'lista', 'mayorista', 'desc_cliente', 'desc_categoria', 'manual', 'bonificacion'
    ) THEN
      CONTINUE;
    END IF;

    UPDATE pedido_items pi
    SET origen_precio          = v_origen,
        grupo_precio_escala_id = COALESCE(
          (item->>'grupo_precio_escala_id')::bigint,
          pi.grupo_precio_escala_id
        )
    WHERE pi.pedido_id = p_pedido_id
      AND pi.producto_id = (item->>'producto_id')::bigint
      AND COALESCE(pi.es_bonificacion, false)
          = COALESCE((item->>'es_bonificacion')::boolean, false)
      AND (pi.origen_precio IS NULL OR pi.origen_precio = 'desconocido');

    GET DIAGNOSTICS v_fila = ROW_COUNT;
    v_actualizados := v_actualizados + v_fila;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'actualizados', v_actualizados);
END;
$fn$;

ALTER FUNCTION public.registrar_origen_precio_items(bigint, jsonb, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.registrar_origen_precio_items(bigint, jsonb, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.registrar_origen_precio_items(bigint, jsonb, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_origen_precio_items(bigint, jsonb, uuid) TO service_role;

COMMENT ON FUNCTION public.registrar_origen_precio_items(bigint, jsonb, uuid) IS
  'Completa origen_precio y grupo_precio_escala_id de los items de un pedido, con lo que resolvio el cliente. Solo pisa NULL/desconocido. Mig 149.';
