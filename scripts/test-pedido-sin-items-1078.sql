-- Ensayo de #1078: actualizar_pedido_items no deja un pedido sin productos.
--
-- Decisión del dueño (2026-10-10): vaciar un pedido no es una edición, es una
-- cancelación. La RPC rechaza la lista sin ningún producto cobrado —vacía,
-- NULL, sólo regalos, o con cantidades en 0— y el mensaje manda a cancelar.
-- Una edición normal (los mismos ítems de vuelta) sigue pasando.
--
-- Corre contra prod SIN dejar rastro (salvo los valores de secuencia que
-- consume): un único DO que termina SIEMPRE en RAISE EXCEPTION. Cada caso corre en su propio subbloque, que también termina en
-- error, así que uno no ve lo que escribió el anterior. La sesión de PostgREST
-- se simula adentro de cada subbloque (SET LOCAL ROLE authenticated +
-- request.jwt.claims + x-sucursal-id).
--
--   'ENSAYO OK …'    → todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' → lista de lo que no se cumplió.
--
-- Antes de la migración tiene que FALLAR; después, pasar.
--
--   psql "$DATABASE_URL" -f scripts/test-pedido-sin-items-1078.sql

DO $ensayo$
DECLARE
  v_fallas   text[] := '{}';
  v_pedido   bigint;  -- pedido vivo, sin regalos, que el admin puede editar
  v_suc      bigint;
  v_admin    uuid;    -- admin de esa sucursal
  v_items    jsonb;   -- sus ítems tal como están
  v_n_antes  int;
  v_total    numeric;
  v_casos    text[] := ARRAY['vacia', 'null', 'solo_regalos', 'cantidad_cero', 'control'];
  v_caso     text;
  v_payload  jsonb;
  v_res      jsonb;
  v_n        int;
  v_tot      numeric;
  v_err      text;
BEGIN
  SELECT p.id, p.sucursal_id, p.total INTO v_pedido, v_suc, v_total
    FROM pedidos p
   WHERE p.estado IN ('pendiente', 'asignado') AND p.canal = 'app'
     AND p.tipo_factura IS DISTINCT FROM 'VB'
     AND public.nota_credito_vigente_de_pedido(p.id) IS NULL
     AND EXISTS (SELECT 1 FROM pedido_items i WHERE i.pedido_id = p.id)
     AND NOT EXISTS (SELECT 1 FROM pedido_items i WHERE i.pedido_id = p.id
                      AND COALESCE(i.es_bonificacion, false))
     AND NOT EXISTS (SELECT 1 FROM pedido_items i JOIN productos pr ON pr.id = i.producto_id
                      WHERE i.pedido_id = p.id AND NOT COALESCE(pr.activo, true))
   ORDER BY p.id DESC LIMIT 1;

  SELECT pf.id INTO v_admin
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.rol = 'admin' AND COALESCE(pf.activo, true) AND us.sucursal_id = v_suc
   ORDER BY pf.id LIMIT 1;

  IF v_pedido IS NULL OR v_admin IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · no hay datos: pedido editable (%), admin de su sucursal (%)',
      v_pedido, v_admin;
  END IF;

  SELECT count(*), jsonb_agg(jsonb_build_object(
           'producto_id', i.producto_id, 'cantidad', i.cantidad,
           'precio_unitario', i.precio_unitario) ORDER BY i.id)
    INTO v_n_antes, v_items
    FROM pedido_items i WHERE i.pedido_id = v_pedido;

  FOREACH v_caso IN ARRAY v_casos LOOP
    v_payload := CASE v_caso
      WHEN 'vacia'         THEN '[]'::jsonb
      WHEN 'null'          THEN NULL
      -- Los mismos productos, pero todos como regalo: nada cobrado.
      WHEN 'solo_regalos'  THEN (SELECT jsonb_agg(e || '{"es_bonificacion": true, "precio_unitario": 0}')
                                   FROM jsonb_array_elements(v_items) e)
      -- Los mismos productos con cantidad 0: la lista no está vacía, el pedido sí.
      WHEN 'cantidad_cero' THEN (SELECT jsonb_agg(e || '{"cantidad": 0}')
                                   FROM jsonb_array_elements(v_items) e)
      ELSE v_items
    END;
    v_res := NULL; v_err := NULL; v_n := NULL; v_tot := NULL;

    BEGIN
      PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
      PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
      EXECUTE 'SET LOCAL ROLE authenticated';
      v_res := public.actualizar_pedido_items(v_pedido, v_payload, v_admin);
      EXECUTE 'RESET ROLE';
      SELECT count(*) INTO v_n FROM pedido_items WHERE pedido_id = v_pedido;
      SELECT total INTO v_tot FROM pedidos WHERE id = v_pedido;
      RAISE EXCEPTION '__deshacer__';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM <> '__deshacer__' THEN v_err := SQLERRM; END IF;
    END;

    IF v_caso = 'control' THEN
      IF v_err IS NOT NULL OR NOT COALESCE((v_res ->> 'success')::boolean, false) THEN
        v_fallas := v_fallas || format('control: la edición sin cambios no pasó (res=%s, error=%s)', v_res, v_err);
      ELSIF v_n <> v_n_antes THEN
        v_fallas := v_fallas || format('control: quedaron %s ítems, había %s', v_n, v_n_antes);
      END IF;
    ELSE
      IF v_err IS NOT NULL THEN
        v_fallas := v_fallas || format('%s: reventó en vez de rechazar con mensaje (%s)', v_caso, v_err);
      ELSIF COALESCE((v_res ->> 'success')::boolean, true) THEN
        v_fallas := v_fallas || format('%s: aceptó (quedaron %s ítems, total %s → %s)', v_caso, v_n, v_total, v_tot);
      -- El mensaje de #1078 y no otro: "cancelalo" también lo dice el del vale blanco.
      ELSIF COALESCE(v_res ->> 'errores', '') NOT ILIKE '%Si ya no va, cancelalo%' THEN
        v_fallas := v_fallas || format('%s: rechazó, pero el mensaje no manda a cancelar (%s)', v_caso, v_res ->> 'errores');
      ELSIF v_n IS DISTINCT FROM v_n_antes OR v_tot IS DISTINCT FROM v_total THEN
        v_fallas := v_fallas || format('%s: rechazó, pero ya había escrito (ítems %s → %s, total %s → %s)',
          v_caso, v_n_antes, v_n, v_total, v_tot);
      END IF;
    END IF;
  END LOOP;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ (pedido %) · %', v_pedido, array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK (pedido %) · vacía, NULL, sólo regalos y cantidad 0 se rechazan mandando a cancelar; la edición sin cambios pasa',
    v_pedido;
END
$ensayo$;
