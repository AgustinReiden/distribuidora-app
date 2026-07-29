-- =========================================================================
-- 153_barridas_5_grupos.sql
--
-- El ruteo pasa de 3 a 5 bloques. El criterio viejo (sólo hora de cierre)
-- dejaba que, dentro del primer bloque, el optimizador arrancara por un local
-- que abre 09:00 mientras uno de 07:00 quedaba noveno: el camión sale 08:00 y
-- la primera parada estaba cerrada.
--
-- Orden nuevo:
--   1 · abren temprano Y cierran al mediodía  (lo único visitable al salir)
--   2 · cierran hasta las 13
--   3 · cierran hasta las 14:30
--   4 · sin horario cargado
--   5 · corrido o abren tarde
--
-- El grupo 1 exige las DOS condiciones: un local 07:00-24:00 abre temprano
-- pero no urge, y meterlo ahí gasta la mañana —el recurso escaso— en alguien
-- que se puede visitar a cualquier hora. En una ruta real eso llevaba el primer
-- bloque de 6 a 14 paradas.
--
-- Los valores 1-3 ya persistidos siguen siendo válidos como número, pero su
-- SIGNIFICADO cambió (el 2 era "sin horario" y ahora es "cierran hasta las 13").
-- No se migran: son de rutas ya ejecutadas y sólo se usan para mostrar y medir.
-- =========================================================================

ALTER TABLE public.recorrido_pedidos
  DROP CONSTRAINT IF EXISTS recorrido_pedidos_barrida_check;

ALTER TABLE public.recorrido_pedidos
  ADD CONSTRAINT recorrido_pedidos_barrida_check
  CHECK (barrida IS NULL OR barrida BETWEEN 1 AND 5);

COMMENT ON COLUMN public.recorrido_pedidos.barrida IS
  'Bloque de reparto (mig 153): 1 = abren temprano y cierran al mediodía, 2 = cierran hasta las 13, 3 = cierran hasta las 14:30, 4 = sin horario, 5 = corrido o abren tarde. NULL = ruta armada sin barridas.';
