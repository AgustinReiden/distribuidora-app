-- 400 · Devuelve al costo de reposicion los cargos de la compra que le borro la
-- ficha del producto.
--
-- La compra deja en productos.costo_real el costo unitario de su motor (migs
-- 193/194): neto + impuesto interno + los cargos que se prorratean al costo
-- (flete, pallets, bonificaciones), con el II ajustado al declarado. La ficha
-- recalculaba ese costo como neto x (1 + II%) y lo grababa en CADA guardado, se
-- hubiera tocado el costo o no: cambiar un subrubro o un precio le borraba el
-- flete. El audit_logs lo muestra desde el 06/10/2026 (un cambio de subrubro
-- bajo un costo de 4.703,33 a 4.136,15). El front ya no lo hace
-- (utils/costoFinalProducto); esto repara lo que quedo.
--
-- A quien se toca: el producto cuyo costo_real es EXACTAMENTE la formula de la
-- ficha (con la tasa de II de hoy o con la de la compra, que pudo cambiar
-- despues por el encuadre), cuya ultima compra que fijo costo sumo cargos
-- (>= 1 peso por unidad por encima de neto + II) y cuyo neto sigue siendo el de
-- esa compra. Un neto distinto es una correccion a mano y no se toca.
--
-- Que se le pone: la formula de la ficha de hoy + lo que esa compra sumo por
-- encima de neto + II. Es la misma cuenta que hace la ficha nueva
-- (adicionalDeCompra + conAdicionalDeCompra). Con la tasa de II sin cambios da
-- el costo final de la compra al centavo; con la tasa cambiada conserva los
-- cargos y aplica la tasa de hoy.
--
-- La "ultima compra que fija costo" es la de registrar_compra_completa: no
-- cancelada, bonificacion < 100 y neto > 0 (v_actualiza_costo), la mas nueva por
-- (fecha_compra, id) (v_es_mas_reciente). Solo cambia costo_real: ni stock, ni
-- promedio (que siempre incluyo los cargos), ni costo_sin_iva/costo_con_iva.
--
-- Idempotente: aplicada, ningun producto vuelve a cumplir el criterio. Al
-- aplicarla el 28/10/2026 eran 18 productos.

DO $restaurar$
DECLARE
  v_n INTEGER;
BEGIN
  WITH ultima AS (
    SELECT DISTINCT ON (ci.producto_id)
           ci.producto_id,
           COALESCE(ci.costo_neto_unitario,
                    ci.costo_unitario * (1 - COALESCE(ci.bonificacion, 0) / 100)) AS neto_compra,
           COALESCE(ci.impuestos_internos, 0) AS ii_compra,
           ci.costo_real_unitario AS real_compra
      FROM compra_items ci
      JOIN compras c ON c.id = ci.compra_id AND c.sucursal_id = ci.sucursal_id
     WHERE c.estado <> 'cancelada'
       AND COALESCE(ci.bonificacion, 0) < 100
       AND COALESCE(ci.costo_unitario, 0) * (1 - COALESCE(ci.bonificacion, 0) / 100) > 0
       AND ci.costo_real_unitario IS NOT NULL
     ORDER BY ci.producto_id, c.fecha_compra DESC, c.id DESC, ci.id DESC
  ), calc AS (
    SELECT p.id,
           p.costo_real AS real_prod,
           p.costo_sin_iva,
           u.neto_compra,
           CASE WHEN COALESCE(p.ultimo_tipo_compra, 'FC') = 'ZZ' THEN p.costo_sin_iva
                ELSE round(p.costo_sin_iva * (1 + COALESCE(p.impuestos_internos, 0) / 100), 4)
           END AS ficha_hoy,
           CASE WHEN COALESCE(p.ultimo_tipo_compra, 'FC') = 'ZZ' THEN p.costo_sin_iva
                ELSE round(p.costo_sin_iva * (1 + u.ii_compra / 100), 4)
           END AS ficha_tasa_compra,
           u.real_compra
             - CASE WHEN COALESCE(p.ultimo_tipo_compra, 'FC') = 'ZZ' THEN u.neto_compra
                    ELSE round(u.neto_compra * (1 + u.ii_compra / 100), 4)
               END AS adicional
      FROM productos p
      JOIN ultima u ON u.producto_id = p.id
     WHERE p.costo_real IS NOT NULL
       AND p.costo_sin_iva > 0
  ), a_reparar AS (
    SELECT id, round(ficha_hoy + adicional, 4) AS costo_real_nuevo
      FROM calc
     WHERE abs(costo_sin_iva - neto_compra) < 0.01
       AND abs(adicional) >= 1
       AND (abs(real_prod - ficha_hoy) < 0.01 OR abs(real_prod - ficha_tasa_compra) < 0.01)
       AND abs(real_prod - (ficha_hoy + adicional)) >= 0.01
  )
  UPDATE productos p
     SET costo_real = r.costo_real_nuevo,
         updated_at = NOW()
    FROM a_reparar r
   WHERE p.id = r.id;

  GET DIAGNOSTICS v_n = ROW_COUNT;

  -- Red: el relevamiento previo dio 18. Muchos mas quiere decir que el criterio
  -- esta agarrando algo que no es este bug; mejor frenar que reescribir costos.
  IF v_n > 40 THEN
    RAISE EXCEPTION 'mig 400: % productos cumplen el criterio (se esperaban ~18). No se toca nada.', v_n;
  END IF;

  RAISE NOTICE 'mig 400: costo de reposicion restaurado en % productos', v_n;
END
$restaurar$;
