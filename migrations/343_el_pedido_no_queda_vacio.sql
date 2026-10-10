-- #1078 · actualizar_pedido_items no deja un pedido sin productos.
--
-- El pedido 652 quedó entregado sin ítems: el 2026-05-05 un admin le borró su
-- único ítem (total 13.000 → 0) y lo marcó entregado en el mismo segundo. La
-- 336 lo dejó como legacy en VENTA-J. La RPC rechazaba editar un entregado o un
-- cancelado, pero no una lista vacía.
--
-- Decisión del dueño (2026-10-10): vaciar un pedido no es una edición, es una
-- cancelación (`cancelar_pedido_con_stock` devuelve el stock y deja el total en
-- 0, que es lo que VENTA-I espera de un cancelado). Se rechaza la lista sin
-- ningún renglón cobrado —un renglón que no es regalo y tiene cantidad > 0—:
--   · vacía o NULL;
--   · sólo regalos: sin nada cobrado el regalo no tiene de qué colgarse;
--   · todo en cantidad 0: la lista no está vacía, el pedido sí.
-- El mensaje manda a cancelar.
--
-- El front ya deshabilitaba "Guardar" con 0 productos (ModalEditarPedido); esto
-- cierra el camino de un bundle viejo del PWA o de cualquier otro llamador.
--
-- Se parchea por ancla (molde de la 334): el guard entra justo después del
-- rechazo de cancelados, antes de cualquier escritura. Nada más de la función
-- cambia. CREATE OR REPLACE conserva los GRANT.
--
-- Ensayo: scripts/test-pedido-sin-items-1078.sql (falla antes, pasa después).

BEGIN;

DO $mig$
DECLARE
  v_fn    regprocedure := 'public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure;
  v_def   text;
  v_veces int;
  v_ancla text := $ancla$      ARRAY['No se puede editar un pedido cancelado. Crea uno nuevo.']);
  END IF;
$ancla$;
  v_nuevo text := $nuevo$      ARRAY['No se puede editar un pedido cancelado. Crea uno nuevo.']);
  END IF;

  -- #1078: vaciar un pedido no es editarlo, es cancelarlo. Tiene que quedar al
  -- menos un renglon cobrado (no regalo, cantidad > 0): los regalos solos o
  -- las cantidades en 0 lo dejan en total 0 igual que la lista vacia, y asi
  -- se podia entregar (pedido 652, VENTA-J).
  IF NOT EXISTS (
       SELECT 1
         FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_items_nuevos) = 'array'
                                        THEN p_items_nuevos ELSE '[]'::jsonb END) e
        WHERE NOT COALESCE((e->>'es_bonificacion')::BOOLEAN, false)
          AND COALESCE((e->>'cantidad')::NUMERIC, 0) > 0) THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY[
      'El pedido tiene que conservar al menos un producto que no sea regalo. Si ya no va, cancelalo.']);
  END IF;
$nuevo$;
BEGIN
  v_def := pg_get_functiondef(v_fn);
  v_veces := (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El ancla aparece % veces en % (se esperaba exactamente 1). El cuerpo vivo cambio: revisar a mano.',
      v_veces, v_fn;
  END IF;
  EXECUTE replace(v_def, v_ancla, v_nuevo);
END
$mig$;

-- Verificación: el guard quedó una vez y los permisos no se movieron.
DO $verif$
DECLARE
  v_fn  regprocedure := 'public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure;
  v_def text := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure);
BEGIN
  IF (length(v_def) - length(replace(v_def, 'Si ya no va, cancelalo.', ''))) / length('Si ya no va, cancelalo.') <> 1 THEN
    RAISE EXCEPTION '#1078 · el guard no quedó exactamente una vez en %', v_fn;
  END IF;
  IF NOT has_function_privilege('authenticated', v_fn, 'EXECUTE') THEN
    RAISE EXCEPTION '#1078 · % perdió el EXECUTE de authenticated', v_fn;
  END IF;
  IF has_function_privilege('anon', v_fn, 'EXECUTE') THEN
    RAISE EXCEPTION '#1078 · % quedó ejecutable por anon', v_fn;
  END IF;
END
$verif$;

COMMIT;
