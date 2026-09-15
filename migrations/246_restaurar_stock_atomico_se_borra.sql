-- =========================================================================
-- restaurar_stock_atomico se borra (#617)
--
-- Decision del dueno: la RPC no tiene ningun caller. useRestaurarStockMutation
-- (src/hooks/queries/useProductosQuery.ts) y restaurarStock
-- (src/hooks/supabase/useProductos.ts) tenian cero usos fuera de su propia
-- definicion y un test -- se borraron en el mismo cambio que esta migracion.
--
-- La RPC seguia viva con EXECUTE para authenticated: admin, preventista y
-- encargado podian subir el stock de cualquier producto de su sucursal sin
-- ningun documento (compra, pedido, movimiento) detras.
--
-- 'restauracion_manual' se agrego a la lista blanca de sincronizar_lotes_stock
-- (mig 229) solo por esta RPC -- es la unica funcion que la usaba como origen,
-- verificado contra el cuerpo vivo. Se saca de la lista junto con la funcion.
-- =========================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1 - Sacar 'restauracion_manual' de la lista blanca del trigger de lotes.
--     Unico cambio real en el cuerpo: se reescribe entero para que quede
--     legible, no por anclas (no hay ambiguedad que patchear).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.sincronizar_lotes_stock()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_delta    integer := NEW.stock - OLD.stock;
  v_asignado integer;
  v_bolsa    integer;
  v_origen   text := COALESCE(NULLIF(current_setting('app.stock_origen', true), ''), 'auto');
BEGIN
  IF v_delta = 0 THEN
    RETURN NEW;
  END IF;

  -- mig 229: el atajo era `IF v_asignado = 0 THEN RETURN NEW`, y cortaba justo
  -- en el caso que hay que atender: lotes que existen pero estan consumidos a
  -- 0. _restaurar_lotes_fefo busca lotes con cantidad_restante < cantidad, o
  -- sea que ahi es cuando mas hace falta. Ahora mira si HAY lotes, no cuanto
  -- les queda; el barrido por producto sin lotes sigue sin pagarse.
  IF NOT EXISTS (
    SELECT 1 FROM public.producto_lotes
     WHERE producto_id = NEW.id AND sucursal_id = NEW.sucursal_id
  ) THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(SUM(cantidad_restante), 0) INTO v_asignado
    FROM public.producto_lotes
   WHERE producto_id = NEW.id AND sucursal_id = NEW.sucursal_id;

  IF v_delta < 0 THEN
    v_bolsa := OLD.stock - v_asignado;
    IF (-v_delta) > v_bolsa THEN
      PERFORM public._consumir_lotes_fefo(NEW.id, NEW.sucursal_id, (-v_delta) - v_bolsa);
    END IF;
  ELSIF v_origen IN ('pedido_creado', 'pedido_creado_bot', 'pedido_cancelado',
                     'pedido_eliminado', 'salvedad', 'sustitucion_regalo',
                     'auto_ajuste_promo', 'movimiento_denegado',
                     'movimiento_cancelado', 'cambio_producto',
                     'movimiento_editado') THEN
    PERFORM public._restaurar_lotes_fefo(NEW.id, NEW.sucursal_id, v_delta);
  END IF;

  RETURN NEW;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 2 - Borrar la RPC. Una sola sobrecarga confirmada contra pg_proc en vivo:
--     restaurar_stock_atomico(jsonb).
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.restaurar_stock_atomico(jsonb);

-- ---------------------------------------------------------------------------
-- 3 - Verificacion.
-- ---------------------------------------------------------------------------

DO $verif$
DECLARE
  v_def text;
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'restaurar_stock_atomico'
  ) THEN
    RAISE EXCEPTION 'restaurar_stock_atomico sigue existiendo.';
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'sincronizar_lotes_stock';

  IF v_def LIKE '%restauracion_manual%' THEN
    RAISE EXCEPTION 'restauracion_manual sigue en la lista blanca de sincronizar_lotes_stock.';
  END IF;

  IF v_def NOT LIKE '%movimiento_editado%' OR v_def NOT LIKE '%cambio_producto%' THEN
    RAISE EXCEPTION 'La lista blanca perdio otros origenes ademas de restauracion_manual.';
  END IF;
END;
$verif$;

COMMIT;
