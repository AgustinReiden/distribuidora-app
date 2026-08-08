-- =========================================================================
-- 173_entrega_del_chofer_actualiza_la_parada.sql
--
-- Cuando el chofer marca una entrega, la parada del recorrido no se enteraba.
--
-- EL SINTOMA
-- ----------
-- Ruta 82 (Taco Pozo, 08/08): 17 pedidos entregados, pero solo 7 paradas con
-- `estado_entrega = 'entregado'`. Y `recorridos.total_cobrado` informaba
-- $263.900 contra $364.500 realmente cobrados: la rendicion del dia salia
-- $100.600 corta. No es de esa ruta ni de ese chofer — hay 1.331 paradas asi
-- en la historia (Marcos 1.029, Transporte Taco Pozo 292, Juan 10).
--
-- CAUSA 1: el trigger corria con los permisos del chofer
-- ------------------------------------------------------
-- `actualizar_recorrido_entrega()` no era SECURITY DEFINER, asi que sus UPDATE
-- pasaban por la RLS del usuario que disparo el trigger. Y
-- `mt_recorrido_pedidos_update` solo habilita `es_admin()`:
--
--   UPDATE recorrido_pedidos ... -> 0 filas, SIN error (RLS filtra, no falla)
--   UPDATE recorridos        ... -> OK (su policy permite al transportista dueño)
--
-- O sea: el contador de la ruta avanzaba y la parada quedaba en 'pendiente'.
-- Split-brain garantizado para CUALQUIER chofer que no sea admin, desde
-- siempre. Verificado reproduciendo la sesion de un chofer con RLS activa.
--
-- El fix es SECURITY DEFINER y no abrir la policy: la escritura sigue
-- encerrada en el trigger, que controla exactamente que columnas toca. Darle
-- UPDATE directo sobre `recorrido_pedidos` al chofer le abriria tambien
-- orden_entrega, barrida y notas, que no tiene por que tocar.
--
-- CAUSA 2: los contadores se sumaban a ciegas, y en el momento equivocado
-- ----------------------------------------------------------------------
-- Hacia `pedidos_entregados = pedidos_entregados + 1` y
-- `total_cobrado = total_cobrado + NEW.monto_pagado`. Dos problemas:
--
--   · Sumar 1 es irreversible: entregado -> asignado -> entregado contaba dos
--     veces, y una entrega revertida no descontaba nunca.
--   · `NEW.monto_pagado` se lee en el instante en que se marca entregado. El
--     chofer cobra DESPUES de marcar (o el cobro entra por otra via), asi que
--     ahi todavia valia 0 y la plata no se contaba jamas. De ahi los $100.600.
--
-- Ahora los dos se recalculan desde las paradas, que es la fuente de verdad, y
-- el trigger tambien escucha `monto_pagado` para que un cobro posterior
-- actualice el total. Al ser un recalculo y no un delta, es idempotente: correr
-- de mas no rompe nada y una reversion se refleja sola.
--
-- Se mantiene a proposito el filtro `r.fecha = CURRENT_DATE`: solo se toca la
-- ruta del dia. Marcar una entrega al dia siguiente sigue sin mover contadores
-- historicos, igual que hasta hoy.
-- =========================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.actualizar_recorrido_entrega()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_recorrido_id BIGINT;
BEGIN
  SELECT rp.recorrido_id INTO v_recorrido_id
  FROM recorrido_pedidos rp
  JOIN recorridos r ON r.id = rp.recorrido_id
  WHERE rp.pedido_id = NEW.id
    AND r.fecha      = CURRENT_DATE
    AND r.estado     = 'en_curso'
  LIMIT 1;

  IF v_recorrido_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Solo en la transicion a entregado: si no, un cobro posterior pisaria la
  -- hora_entrega real.
  IF NEW.estado = 'entregado' AND OLD.estado IS DISTINCT FROM 'entregado' THEN
    UPDATE recorrido_pedidos
    SET estado_entrega = 'entregado',
        hora_entrega   = NOW()
    WHERE recorrido_id = v_recorrido_id
      AND pedido_id    = NEW.id;
  END IF;

  -- Contadores recalculados desde las paradas (idempotente).
  UPDATE recorridos r
  SET pedidos_entregados = sub.entregados,
      total_cobrado      = sub.cobrado
  FROM (
    SELECT COUNT(*) FILTER (WHERE p.estado = 'entregado')                  AS entregados,
           COALESCE(SUM(p.monto_pagado) FILTER (WHERE p.estado = 'entregado'), 0) AS cobrado
    FROM recorrido_pedidos rp
    JOIN pedidos p ON p.id = rp.pedido_id
    WHERE rp.recorrido_id = v_recorrido_id
  ) sub
  WHERE r.id = v_recorrido_id;

  RETURN NEW;
END;
$fn$;

COMMENT ON FUNCTION public.actualizar_recorrido_entrega() IS
  'Sincroniza la parada del recorrido con el pedido: marca estado_entrega al '
  'entregar y recalcula pedidos_entregados/total_cobrado desde las paradas. '
  'SECURITY DEFINER a proposito (mig 173): sin eso la RLS de recorrido_pedidos '
  '(admin-only) descartaba el UPDATE en silencio para todo chofer no admin.';

-- Ahora tambien sobre monto_pagado: el cobro casi siempre entra DESPUES de
-- marcar entregado, y sin esto total_cobrado se quedaba con el valor de ese
-- instante (0) para siempre.
DROP TRIGGER IF EXISTS trigger_actualizar_recorrido_entrega ON public.pedidos;
CREATE TRIGGER trigger_actualizar_recorrido_entrega
  AFTER UPDATE OF estado, monto_pagado ON public.pedidos
  FOR EACH ROW
  EXECUTE FUNCTION public.actualizar_recorrido_entrega();

COMMIT;
