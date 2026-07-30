-- ============================================================================
-- 132 · Fix de datos: costo_con_iva de productos ZZ inflado por el modal
-- ============================================================================
-- En una compra ZZ lo pagado ES el costo final: ya incluye IVA e impuestos
-- internos, no se le suma nada encima (mig 111). El RPC de compras siempre lo
-- respetó (costo_financiero_unitario devuelve el neto tal cual en ZZ), pero
-- ModalProducto recalculaba costo_con_iva con la fórmula FC
-- (neto × (1 + IVA% + II%)) sin mirar ultimo_tipo_compra, y ese valor se
-- persistía al guardar la ficha. Resultado: productos comprados en negro con
-- el costo financiero inflado (ratios exactos de 1,21 y 1,2775 en prod).
--
-- Efecto colateral que reportó el usuario: el % de margen bruto salía negativo
-- (denominador inflado 21%) aunque el monto en pesos fuera positivo.
--
-- El fix de la app va en ModalProducto (usa calcularCostoFinanciero con el
-- tipo). Esta migración corrige las filas ya escritas. Idempotente: sólo toca
-- las que difieren.
-- ============================================================================

UPDATE public.productos
   SET costo_con_iva = costo_sin_iva,
       updated_at    = NOW()
 WHERE ultimo_tipo_compra = 'ZZ'
   AND costo_sin_iva IS NOT NULL
   AND costo_con_iva IS NOT NULL
   AND round(costo_con_iva, 2) <> round(costo_sin_iva, 2);
