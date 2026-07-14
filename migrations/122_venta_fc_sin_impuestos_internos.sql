-- ============================================================================
-- 122 · Venta FC: el desglose NO discrimina impuestos internos
-- ============================================================================
-- Regla de negocio (aclarada por el usuario 2026-07-14): la distribuidora NO
-- es agente de impuestos internos. El II existe solo en la COMPRA (integra el
-- costo real, mig 111); la factura de VENTA discrimina únicamente neto + IVA.
--
--   Antes (mig 117): FC → neto = precio / (1 + iva% + II%)   ← subestimaba el
--                    neto y "facturaba" un II fantasma.
--   Ahora:           FC → neto = precio / (1 + iva%); iva = neto × iva%; II = 0.
--   ZZ: sin cambios (todo el precio es ingreso neto).
--
-- Un solo CREATE OR REPLACE de calcular_desglose_venta corrige los 5 RPCs que
-- la usan (crear_pedido_completo, _bot, actualizar_pedido_items,
-- anular_salvedad, cambiar_tipo_factura_pedido) sin tocarlos: todos le pasan
-- la tasa de II del producto, que ahora se ignora en el lado venta.
-- No hay datos que corregir: el único pedido FC en prod está cancelado con
-- total 0 y ningún item FC tiene II > 0.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.calcular_desglose_venta(
  p_precio numeric,
  p_pct_iva numeric,
  p_pct_ii numeric,
  p_tipo_factura text
) RETURNS TABLE(neto numeric, iva numeric, imp_internos numeric)
LANGUAGE sql IMMUTABLE
AS $$
  SELECT
    CASE WHEN p_tipo_factura = 'ZZ' THEN round(COALESCE(p_precio, 0), 2)
         ELSE round(COALESCE(p_precio, 0) / (1 + COALESCE(p_pct_iva, 0)/100), 2) END,
    CASE WHEN p_tipo_factura = 'ZZ' THEN 0::numeric
         ELSE round(COALESCE(p_precio, 0) / (1 + COALESCE(p_pct_iva, 0)/100) * COALESCE(p_pct_iva, 0)/100, 2) END,
    0::numeric;  -- la venta nunca discrimina imp. internos (no somos agente)
$$;

COMMENT ON FUNCTION public.calcular_desglose_venta(numeric, numeric, numeric, text) IS
  'Desglose fiscal por unidad de VENTA. ZZ: todo el precio es ingreso neto. FC: neto = precio/(1+iva%); la venta NUNCA discrimina impuestos internos (la distribuidora no es agente; el II vive solo en el costo de compra). p_pct_ii se conserva en la firma por compatibilidad pero se ignora.';
