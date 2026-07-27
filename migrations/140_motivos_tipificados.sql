-- =========================================================================
-- 140_motivos_tipificados.sql
--
-- PROBLEMA: hoy el chofer NO tiene forma de marcar "no entregué". Sus únicas
-- opciones son Entregar o reportar una salvedad por ítem. Cuando un local está
-- cerrado, alguien después cancela el pedido a mano con un texto libre.
--
-- Los 151 cancelados de los últimos 90 días mezclan cosas incomparables:
--   CERRADO 50 · SIN PLATA 24 · Prueba 22 · recargas por bug de promo ~12 ·
--   RECHAZO 7 · clima 5 · unificación de pedidos 4 · …
-- Con texto libre no se puede medir nada ni mostrarle nada confiable al
-- preventista, que es de donde salen las peleas con reparto.
--
-- Una sola lista cerrada para los dos usos (no-entrega del chofer y
-- cancelación administrativa del admin): son el mismo vocabulario visto desde
-- dos roles, y unificarla permite backfillear el histórico, que hoy los tiene
-- mezclados en la misma columna.
--
-- Resultado del backfill sobre 218 cancelaciones históricas:
--   cerrado 62 · otro 37 · sin_dinero 26 · error_de_carga 25 · prueba 24 ·
--   cliente_cancelo 16 · cliente_rechaza 12 · unifica_pedidos 7 · clima 7 ·
--   ausente 2   →  83% clasificado.
-- =========================================================================

-- -------------------------------------------------------------------------
-- 1. No entrega (la carga el chofer, en la calle)
-- -------------------------------------------------------------------------
ALTER TABLE public.recorrido_pedidos
  ADD COLUMN IF NOT EXISTS motivo_no_entrega varchar(30);
ALTER TABLE public.recorrido_pedidos
  ADD COLUMN IF NOT EXISTS nota_no_entrega text;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'recorrido_pedidos_motivo_no_entrega_check') THEN
    ALTER TABLE public.recorrido_pedidos
      ADD CONSTRAINT recorrido_pedidos_motivo_no_entrega_check
      CHECK (motivo_no_entrega IS NULL OR motivo_no_entrega IN (
        'cerrado', 'sin_dinero', 'cliente_rechaza', 'ausente',
        'direccion_incorrecta', 'clima', 'otro'
      ));
  END IF;
END $$;

COMMENT ON COLUMN public.recorrido_pedidos.motivo_no_entrega IS
  'Por qué no se pudo entregar, lista cerrada. Lo carga el chofer. Mig 140.';

-- -------------------------------------------------------------------------
-- 2. Cancelación (la carga un admin). Incluye los motivos logísticos porque el
--    histórico los tiene, y porque cancelar por "estaba cerrado" es un caso real.
-- -------------------------------------------------------------------------
ALTER TABLE public.pedidos
  ADD COLUMN IF NOT EXISTS motivo_cancelacion_tipo varchar(30);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'pedidos_motivo_cancelacion_tipo_check') THEN
    ALTER TABLE public.pedidos
      ADD CONSTRAINT pedidos_motivo_cancelacion_tipo_check
      CHECK (motivo_cancelacion_tipo IS NULL OR motivo_cancelacion_tipo IN (
        'cerrado', 'sin_dinero', 'cliente_rechaza', 'ausente',
        'direccion_incorrecta', 'clima',
        'cliente_cancelo', 'error_de_carga', 'duplicado', 'unifica_pedidos',
        'prueba', 'otro'
      ));
  END IF;
END $$;

COMMENT ON COLUMN public.pedidos.motivo_cancelacion_tipo IS
  'Motivo de cancelación tipificado. `motivo_cancelacion` (text) queda como nota complementaria. Mig 140.';

-- -------------------------------------------------------------------------
-- 3. Backfill del histórico. Lo que no encaja con seguridad queda en 'otro'
--    con el texto original intacto en `motivo_cancelacion`.
-- -------------------------------------------------------------------------
UPDATE pedidos SET motivo_cancelacion_tipo = CASE
  WHEN motivo_cancelacion ~* 'cerrad'                                    THEN 'cerrado'
  WHEN motivo_cancelacion ~* 'sin plata|no ten(i|í)a plata|sin dinero'   THEN 'sin_dinero'
  WHEN motivo_cancelacion ~* 'prueba'                                    THEN 'prueba'
  WHEN motivo_cancelacion ~* 'rechaz'                                    THEN 'cliente_rechaza'
  WHEN motivo_cancelacion ~* 'unificam|unifica'                          THEN 'unifica_pedidos'
  WHEN motivo_cancelacion ~* 'clima|mal tiempo|feo el clima'             THEN 'clima'
  WHEN motivo_cancelacion ~* 'promo|precio|carg(ad|)o|error|modific'     THEN 'error_de_carga'
  WHEN motivo_cancelacion ~* 'no se encotraba|no se encontraba|ausente'  THEN 'ausente'
  WHEN motivo_cancelacion ~* 'cancel|nunca hizo|no quiso'                THEN 'cliente_cancelo'
  ELSE 'otro'
END
WHERE estado = 'cancelado'
  AND motivo_cancelacion IS NOT NULL
  AND motivo_cancelacion <> ''
  AND motivo_cancelacion_tipo IS NULL;
