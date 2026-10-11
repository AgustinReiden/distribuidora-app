-- #1098 · VENTA-J exime al pedido que el cliente rechazó entero por salvedad.
--
-- Los pedidos 652 y 7604 quedaron entregados sin ninguna línea. No los vació un
-- admin (como decían los comentarios de las migs 336 y 343): son dos rechazos
-- totales en el flujo de entrega (salvedades 52 y 703, `cliente_rechaza`).
-- `registrar_salvedad` borra la línea cuando la cantidad entregada queda en 0,
-- porque el CHECK de cantidad no la deja en 0, y la salvedad ya devolvió el
-- stock, los lotes y el total. VENTA-J ("ninguna venta entregada sin items") se
-- ponía en rojo con cada rechazo total, y el 652 estaba excluido a mano por id.
--
-- Decisión del dueño (2026-10-10, opción A): el pedido rechazado entero queda
-- entregado, total 0 y sin líneas. VENTA-J lo exime por la HUELLA de la
-- salvedad, no por id:
--   · pedido con total 0;
--   · una salvedad vigente del pedido (estado_resolucion distinto de 'anulada');
--   · con cantidad_entregada = 0 (rechazo total de la línea);
--   · y pedido_item_id NULL (la línea se borró).
-- Si se anula la salvedad, `anular_salvedad` reinserta la línea y el pedido sale
-- solo de la exención; si la salvedad fue parcial, no explica un pedido vacío y
-- el check sigue mordiendo.
--
-- Residual aceptado: `salvedades_items.pedido_item_id` es ON DELETE SET NULL, así
-- que un admin que borre por REST las demás líneas de un pedido que ya tenía un
-- rechazo total de otra línea, y además deje el total en 0, imita la huella.
-- Requiere manipular datos a mano en dos lugares.
--
-- Se parchea por ancla sobre la definición viva (molde de la 343): sólo cambia
-- el tuple VENTA-J y su comentario. CREATE OR REPLACE conserva los GRANT.
--
-- Ensayo: scripts/test-venta-j-1098.sql (falla antes, pasa después).

BEGIN;

CREATE TEMP TABLE _mig1098_priv ON COMMIT DROP AS
SELECT has_function_privilege('anon', 'public.auditoria_integridad()'::regprocedure, 'EXECUTE') AS anon_x,
       has_function_privilege('authenticated', 'public.auditoria_integridad()'::regprocedure, 'EXECUTE') AS auth_x;

DO $mig$
DECLARE
  v_fn    regprocedure := 'public.auditoria_integridad()'::regprocedure;
  v_def   text;
  v_veces int;
  v_ancla text := $ancla$    -- #1043: el canje (canal 'cambio') nace sin ítems por diseño: lo canjeado
    -- vive en recorrido_cambios, y eso lo cuida CAMBIO-03. El 652 es legacy: el
    -- 2026-05-05 un admin le borró su único ítem y lo marcó entregado en el
    -- mismo segundo.
    ('VENTA-J','low','ninguna venta entregada sin items',
      (SELECT count(*) FROM pedidos p WHERE estado='entregado' AND canal<>'cambio' AND p.id<>652
         AND NOT EXISTS (SELECT 1 FROM pedido_items pi WHERE pi.pedido_id=p.id))),
$ancla$;
  v_nuevo text := $nuevo$    -- #1043: el canje (canal 'cambio') nace sin ítems por diseño: lo canjeado
    -- vive en recorrido_cambios, y eso lo cuida CAMBIO-03.
    -- #1098: el pedido que el cliente rechazó entero en la entrega queda sin
    -- líneas (registrar_salvedad borra la que queda en 0; el CHECK de cantidad
    -- no la deja en 0) y con total 0. Se exime por la huella de la salvedad
    -- vigente: cantidad_entregada 0 y la línea borrada. Así eran el 652 y el
    -- 7604 (salvedades 52 y 703). Si se anula la salvedad, la línea vuelve.
    ('VENTA-J','low','ninguna venta entregada sin items (salvo el pedido que el cliente rechazó entero por salvedad)',
      (SELECT count(*) FROM pedidos p WHERE estado='entregado' AND canal<>'cambio'
         AND NOT EXISTS (SELECT 1 FROM pedido_items pi WHERE pi.pedido_id=p.id)
         AND NOT EXISTS (SELECT 1 FROM salvedades_items s
                          WHERE s.pedido_id = p.id AND s.sucursal_id = p.sucursal_id
                            AND p.total = 0
                            AND s.estado_resolucion IS DISTINCT FROM 'anulada'
                            AND s.cantidad_entregada = 0
                            AND s.pedido_item_id IS NULL))),
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

-- Verificación: el tuple nuevo quedó una vez, la exclusión por id se fue,
-- VENTA-J está en 0, no hay ids repetidos y los permisos no se movieron.
DO $verif$
DECLARE
  v_fn    regprocedure := 'public.auditoria_integridad()'::regprocedure;
  v_def   text := pg_get_functiondef('public.auditoria_integridad()'::regprocedure);
  v_marca text := 'rechazó entero por salvedad)';
  v_n     int;
  v_viol  int;
  v_dup   text;
  r       record;
BEGIN
  IF (length(v_def) - length(replace(v_def, v_marca, ''))) / length(v_marca) <> 1 THEN
    RAISE EXCEPTION '#1098 · el VENTA-J nuevo no quedó exactamente una vez';
  END IF;
  IF position('p.id<>652' IN v_def) > 0 THEN
    RAISE EXCEPTION '#1098 · quedó la exclusión a mano del 652';
  END IF;
  SELECT count(*), max((c->>'violaciones')::int) INTO v_n, v_viol
    FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c WHERE c->>'id' = 'VENTA-J';
  IF v_n <> 1 OR v_viol <> 0 THEN
    RAISE EXCEPTION '#1098 · VENTA-J aparece % veces con % violaciones (se esperaba 1 vez en 0)', v_n, v_viol;
  END IF;
  SELECT string_agg(id, ', ') INTO v_dup FROM (
    SELECT c->>'id' AS id FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c
     GROUP BY 1 HAVING count(*) > 1) d;
  IF v_dup IS NOT NULL THEN
    RAISE EXCEPTION '#1098 · ids de check repetidos: %', v_dup;
  END IF;
  SELECT * INTO r FROM _mig1098_priv;
  IF has_function_privilege('anon', v_fn, 'EXECUTE') IS DISTINCT FROM r.anon_x
     OR has_function_privilege('authenticated', v_fn, 'EXECUTE') IS DISTINCT FROM r.auth_x THEN
    RAISE EXCEPTION '#1098 · cambiaron los permisos de %', v_fn;
  END IF;
END
$verif$;

COMMIT;
