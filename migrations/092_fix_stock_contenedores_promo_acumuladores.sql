-- 092_fix_stock_contenedores_promo_acumuladores.sql
--
-- PARA REVISAR ANTES DE APLICAR. Toca STOCK FISICO (sucursal 1). Aplicarla
-- DESPUES de 091. Idempotente via marcador en observaciones (estilo mig 067).
--
-- ============================================================================
-- CONTEXTO (auditoria 2026-06-23)
-- ============================================================================
-- La auditoria comparo, por sabor, los bloques que DEBIERON descontarse
--   ( FLOOR(total_regalado_no_cancelado / unidades_por_bloque) )
-- contra lo realmente movido en promo_ajustes. Descuadre detectado (fardos):
--
--   contenedor 87 Pomelo 600   esperado 37  real 41  -> +4 de mas  => DEVOLVER 4
--   contenedor 81 Pomelo 3L    esperado 29  real 33  -> +4 de mas  => DEVOLVER 4
--   contenedor 82 Manzana 3L   esperado 49  real 52  -> +3 de mas  => DEVOLVER 3
--   contenedor 80 Naranja 3L   esperado 30  real 31  -> +1 de mas  => DEVOLVER 1
--   contenedor 85 Lima Limon600 esperado 43 real 42  -> -1 de menos => DESCONTAR 1
--   contenedor 86 Naranja 600  esperado 12  real 11  -> -1 de menos => DESCONTAR 1
--
-- DECISION DEL USUARIO: aplicar la estimacion (asumir que el modelo por-sabor es
-- la verdad). ADVERTENCIA registrada: parte del descuadre puede ser carryover
-- legitimo del modelo global al cambiar de sabor, o ruido de los parches
-- manuales 067/068. La estimacion los corrige igual.
--
-- SALVAGUARDA: el stock NUNCA queda negativo. El producto 86 (Naranja 600) hoy
-- esta en 0; "descontar 1" lo dejaria en -1 => se OMITE (con NOTICE). Eso
-- confirma que ese -1 era ruido. Los otros 5 se aplican (87,81,82,80 devuelven;
-- 85 descuenta 55->54).
--
-- Convencion de signos (igual que mig 067 y el resto del codigo):
--   devolver stock  -> productos.stock += ; mermas.cantidad NEGATIVO ; motivo 'promociones_reversion'
--   descontar stock -> productos.stock -= ; mermas.cantidad POSITIVO ; motivo 'promociones'

DO $$
DECLARE
  v_suc    bigint := 1;
  v_marker text   := 'Correccion stock contenedor promo (mig 092, auditoria 2026-06-23)';
  r        RECORD;
  v_old    int;
  v_new    int;
  v_merma  bigint;
BEGIN
  IF EXISTS (
    SELECT 1 FROM mermas_stock
     WHERE observaciones LIKE v_marker || '%' AND sucursal_id = v_suc
  ) THEN
    RAISE NOTICE 'mig 092 ya aplicada; se omite.';
    RETURN;
  END IF;

  PERFORM set_config('app.stock_origen', 'correccion_mig_092', true);

  FOR r IN
    SELECT * FROM (VALUES
      -- producto_id, promocion_id, delta_stock (+ devuelve / - descuenta), N (unidades_por_bloque)
      (87, 12,  4, 12),
      (81, 13,  4,  6),
      (82, 13,  3,  6),
      (80, 13,  1,  6),
      (85, 12, -1, 12),
      (86, 10, -1, 12)
    ) AS t(producto_id, promocion_id, delta_stock, n)
  LOOP
    SELECT stock INTO v_old FROM productos
      WHERE id = r.producto_id AND sucursal_id = v_suc FOR UPDATE;

    IF v_old IS NULL THEN
      RAISE NOTICE 'mig 092: producto % no existe en sucursal %, se omite', r.producto_id, v_suc;
      CONTINUE;
    END IF;

    v_new := v_old + r.delta_stock;
    IF v_new < 0 THEN
      RAISE NOTICE 'mig 092: producto % quedaria negativo (% %+ = %), se OMITE (descuadre probablemente ruido/carryover)',
        r.producto_id, v_old, r.delta_stock, v_new;
      CONTINUE;
    END IF;

    UPDATE productos SET stock = v_new, updated_at = NOW()
      WHERE id = r.producto_id AND sucursal_id = v_suc;

    INSERT INTO mermas_stock (
      producto_id, cantidad, motivo, observaciones,
      stock_anterior, stock_nuevo, sucursal_id
    ) VALUES (
      r.producto_id,
      -r.delta_stock,
      CASE WHEN r.delta_stock < 0 THEN 'promociones' ELSE 'promociones_reversion' END,
      v_marker || ' (delta ' || r.delta_stock || ' fardos, prod ' || r.producto_id || ')',
      v_old, v_new, v_suc
    ) RETURNING id INTO v_merma;

    INSERT INTO promo_ajustes (
      promocion_id, usos_ajustados, unidades_ajustadas,
      producto_id, merma_id, observaciones, sucursal_id
    ) VALUES (
      r.promocion_id, (-r.delta_stock) * r.n, -r.delta_stock,
      r.producto_id, v_merma, v_marker, v_suc
    );

    RAISE NOTICE 'mig 092: producto % stock % -> % (delta % fardos)',
      r.producto_id, v_old, v_new, r.delta_stock;
  END LOOP;
END $$;

-- ============================================================================
-- VERIFICACION (post-aplicar): no debe haber stock negativo en los contenedores
-- ============================================================================
-- SELECT id, nombre, stock FROM productos
--  WHERE id IN (80,81,82,85,86,87) AND sucursal_id = 1 ORDER BY id;
