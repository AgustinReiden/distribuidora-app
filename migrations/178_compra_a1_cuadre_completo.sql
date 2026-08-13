-- ============================================================================
-- 178 · auditoria_integridad: COMPRA-A1 vuelve a cuadrar la factura entera
-- ============================================================================
-- El check nació en la mig 105 con la estructura de compras de ese momento:
--
--     total = subtotal + iva + otros_impuestos
--
-- Las migs 113/114 le agregaron a la cabecera `impuestos_internos`,
-- `percepcion_iva`, `percepcion_iibb` y `no_gravado` (y sacaron el II de
-- `otros_impuestos`, que volvió a ser catch-all), pero el check nunca se
-- actualizó. Desde entonces TODA compra FC con percepciones o imp. internos lo
-- viola: 12 de 120 compras activas al 2026-08-12, severidad `high`.
--
-- El costo real de esto no es el número: `scripts/check-integridad.mjs` corre a
-- diario desde .github/workflows/integridad.yml y sale con exit 1 ante cualquier
-- critical/high en rojo. Con COMPRA-A1 permanentemente rojo el gate no distingue
-- una regresión nueva del ruido de fondo, así que los checks que se agreguen
-- después nacen invisibles.
--
-- La fórmula nueva es la misma que ya usa el control blando de cuadre del RPC
-- registrar_compra_completa (mig 128). Verificado contra prod ANTES de aplicar:
-- con la fórmula corregida quedan 0 violaciones sobre las 120 compras activas,
-- o sea las 12 eran 100% fórmula vieja y no hay ningún dato descuadrado.
--
-- Se parchea leyendo el catálogo, exigiendo que el ancla aparezca exactamente
-- una vez: si el cuerpo derivó, la migración falla en vez de aplicar un parche
-- parcial (mismo criterio que la mig 177). Idempotente: si el check ya está
-- corregido, no hace nada.
-- ============================================================================

DO $mig$
DECLARE
  v_def   text;
  v_ancla CONSTANT text := $a$    ('COMPRA-A1','high','compras.total = subtotal+iva+otros_impuestos',
      (SELECT count(*) FROM compras WHERE estado<>'cancelada' AND abs(COALESCE(total,0)-(COALESCE(subtotal,0)+COALESCE(iva,0)+COALESCE(otros_impuestos,0)))>1.0)),$a$;
  v_nuevo CONSTANT text := $a$    ('COMPRA-A1','high','compras.total = subtotal+iva+ii+percepciones+no gravado+otros (mig 178)',
      (SELECT count(*) FROM compras WHERE estado<>'cancelada' AND abs(COALESCE(total,0)-(
        COALESCE(subtotal,0)+COALESCE(iva,0)+COALESCE(impuestos_internos,0)
        +COALESCE(percepcion_iva,0)+COALESCE(percepcion_iibb,0)
        +COALESCE(no_gravado,0)+COALESCE(otros_impuestos,0)))>1.0)),$a$;
  v_veces integer;
BEGIN
  v_def := pg_get_functiondef('public.auditoria_integridad()'::regprocedure);

  IF position('mig 178' in v_def) > 0 THEN
    RAISE NOTICE 'mig 178 · COMPRA-A1 ya corregido, se omite';
    RETURN;
  END IF;

  v_veces := (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'mig 178 · el ancla de COMPRA-A1 aparece % veces (se esperaba 1). El cuerpo derivó; revisá el parche antes de aplicar.', v_veces;
  END IF;

  EXECUTE replace(v_def, v_ancla, v_nuevo);
END;
$mig$;

-- ----------------------------------------------------------------------------
-- Verificación (esperado: COMPRA-A1 en verde, 0 violaciones)
--
--   SELECT c->>'id', c->>'ok', c->>'violaciones'
--     FROM jsonb_array_elements(auditoria_integridad()->'checks') c
--    WHERE c->>'id' LIKE 'COMPRA-%';
-- ----------------------------------------------------------------------------
