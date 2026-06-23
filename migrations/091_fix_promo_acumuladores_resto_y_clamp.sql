-- 091_fix_promo_acumuladores_resto_y_clamp.sql
--
-- PARA REVISAR ANTES DE APLICAR. No toca stock fisico (eso va en una migracion
-- aparte, con conteo confirmado). Solo: (a) endurece el helper de acumuladores y
-- (b) recomputa promo_acumuladores.usos_pendientes al RESTO correcto.
--
-- ============================================================================
-- CONTEXTO (auditoria 2026-06-23)
-- ============================================================================
-- Sintoma: la barra de consumo en modo Fraccion mostraba valores imposibles
--   ("24/12", "-10/12", "-4/6"). Reproducido en prod (sucursal 1):
--     promo 12 regalo 86 (Naranja)  usos_pendientes = 24   (tope 12)
--     promo 12 regalo 87 (Pomelo)   usos_pendientes = -10
--     promo 13 regalo 82 (Manzana)  usos_pendientes = -4
--     promo 13 regalo 78 (Cola)     usos_pendientes = 6    (tope 6, debio ser 0)
--
-- Causa raiz (verificada contra el codigo REAL de prod, no el repo):
--   public.aplicar_uso_promo_acumulador hacia
--       v_usos_nuevo := v_acc.usos_pendientes + p_delta;   -- SIN clamp
--       v_old_blocks := FLOOR(v_acc.usos_pendientes / N);  -- SIN GREATEST
--   => guardaba valores negativos o > tope, y FLOOR sobre negativos producia
--      delta_blocks negativo => "stock = stock - (-1)" = stock fantasma sumado
--      al contenedor. (El repo si tenia GREATEST; prod habia quedado atras.)
--   sustituir_regalo_pedido amplificaba: sincronizaba el acumulador default al
--   contador-resto global y luego le restaba la CANTIDAD COMPLETA del item ->
--   underflow.
--
-- Fix de fondo: alinear el acumulador a la MISMA semantica que el contador
-- global (promociones.usos_pendientes) y que revertir_bloques_auto_ajuste:
-- usos_pendientes es un RESTO que SIEMPRE vive en [0, N). Al cruzar bloques se
-- descuenta/devuelve stock del contenedor y se deja el resto. Con esto, la
-- sustitucion (que llama a este helper con -cantidad / +cantidad) queda
-- coherente sin reescribir sustituir_regalo_pedido: el -cantidad revierte
-- bloques (devuelve fardos del sabor original) y el +cantidad completa bloques
-- (descuenta fardos del sabor nuevo).

-- ============================================================================
-- PARTE A — Helper endurecido: semantica de resto + clamp
-- ============================================================================
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
  v_blocks         INT;          -- magnitud de bloques cruzados (>= 0)
  v_usos_final     NUMERIC;      -- resto resultante, SIEMPRE en [0, N)
  v_stock_delta    INT;          -- + devuelve / - descuenta (unidades de contenedor)
  v_usos_ajustados INT;          -- para auditoria (+ descuento / - reversion)
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

  SELECT id, ajuste_producto_id, unidades_por_bloque, stock_por_bloque, usos_pendientes
    INTO v_acc
    FROM promo_acumuladores
   WHERE promocion_id = p_promocion_id
     AND producto_regalo_id = p_producto_regalo_id
     AND sucursal_id = p_sucursal_id
   FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO promo_acumuladores (
      promocion_id, producto_regalo_id, ajuste_producto_id,
      unidades_por_bloque, stock_por_bloque, usos_pendientes, sucursal_id
    ) VALUES (
      p_promocion_id, p_producto_regalo_id, p_ajuste_producto_id_def,
      v_promo.unidades_por_bloque, v_promo.stock_por_bloque, 0, p_sucursal_id
    )
    ON CONFLICT (promocion_id, producto_regalo_id, sucursal_id) DO NOTHING;
    SELECT id, ajuste_producto_id, unidades_por_bloque, stock_por_bloque, usos_pendientes
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
    v_blocks      := FLOOR(v_usos_raw / v_acc.unidades_por_bloque)::INT;   -- bloques completados
    v_usos_final  := v_usos_raw - (v_blocks * v_acc.unidades_por_bloque);
    v_stock_delta := -(v_blocks * v_acc.stock_por_bloque);                 -- descuenta contenedor
    v_usos_ajustados := v_blocks * v_acc.unidades_por_bloque;
  ELSE
    v_blocks      := CEIL(ABS(v_usos_raw) / v_acc.unidades_por_bloque)::INT; -- bloques a revertir
    v_usos_final  := v_usos_raw + (v_blocks * v_acc.unidades_por_bloque);
    v_stock_delta := (v_blocks * v_acc.stock_por_bloque);                  -- devuelve contenedor
    v_usos_ajustados := -(v_blocks * v_acc.unidades_por_bloque);
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
      -v_stock_delta,   -- convencion: + = descuento, - = devolucion (igual que el resto del codigo)
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

-- ============================================================================
-- PARTE B — Recompute de acumuladores existentes al RESTO correcto
-- ============================================================================
-- usos_pendientes correcto por sabor = (total regalado NO cancelado) mod N.
-- Es solo el contador de display; promo_acumuladores no tiene trigger de stock,
-- asi que este UPDATE NO mueve stock. El ajuste de stock fisico (descuadres de
-- contenedor) va en migracion aparte, con conteo confirmado.
--
-- OJO: esto NO arregla el descuadre de stock fisico de los contenedores
-- (ver auditoria: 87 +4, 81 +4, 82 +3, 80 +1, 86 -1, 85 -1 vs lo esperado),
-- que ademas se entrelaza con las correcciones manuales 067/068.

WITH entregado AS (
  SELECT pi.promocion_id,
         pi.producto_id,
         pi.sucursal_id,
         (SUM(pi.cantidad) % p.unidades_por_bloque) AS resto
    FROM pedido_items pi
    JOIN pedidos pe   ON pe.id = pi.pedido_id
    JOIN promociones p ON p.id = pi.promocion_id AND p.sucursal_id = pi.sucursal_id
   WHERE pi.es_bonificacion = true
     AND pe.estado <> 'cancelado'
     AND COALESCE(p.ajuste_automatico, false) = true
     AND COALESCE(p.unidades_por_bloque, 0) > 0
   GROUP BY pi.promocion_id, pi.producto_id, pi.sucursal_id, p.unidades_por_bloque
)
UPDATE promo_acumuladores a
   SET usos_pendientes = e.resto, updated_at = NOW()
  FROM entregado e
 WHERE a.promocion_id = e.promocion_id
   AND a.producto_regalo_id = e.producto_id
   AND a.sucursal_id = e.sucursal_id
   AND a.usos_pendientes IS DISTINCT FROM e.resto;

-- Acumuladores sin entregas reales (huerfanos de sustituciones revertidas) -> 0.
UPDATE promo_acumuladores a
   SET usos_pendientes = 0, updated_at = NOW()
 WHERE a.usos_pendientes <> 0
   AND NOT EXISTS (
     SELECT 1
       FROM pedido_items pi
       JOIN pedidos pe ON pe.id = pi.pedido_id
      WHERE pi.promocion_id = a.promocion_id
        AND pi.producto_id  = a.producto_regalo_id
        AND pi.sucursal_id  = a.sucursal_id
        AND pi.es_bonificacion = true
        AND pe.estado <> 'cancelado'
   );

-- ============================================================================
-- VERIFICACION (correr despues de aplicar; debe devolver 0 filas)
-- ============================================================================
-- SELECT * FROM promo_acumuladores
--  WHERE usos_pendientes < 0
--     OR usos_pendientes >= COALESCE(unidades_por_bloque, 1);
