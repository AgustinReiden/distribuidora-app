-- Ensayo de #1098: VENTA-J exime al pedido que el cliente rechazó entero por
-- salvedad, y sigue mordiendo ante cualquier otra venta entregada sin ítems.
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en RAISE
-- EXCEPTION, así que todo lo que escriba se deshace. Los canarios sólo hacen
-- UPDATE sobre salvedades_items dentro de subbloques que se deshacen con el
-- SQLSTATE centinela P0099 (nada de DELETE: cascadearía a salvedad_historial).
--
--   'ENSAYO OK …'    → todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' → lista de lo que no se cumplió.
--
-- Antes de la migración tiene que FALLAR (VENTA-J = 1 por el pedido 7604);
-- después, pasar.
--
-- Es un ensayo de un momento dado: necesita que en prod haya al menos un
-- rechazo total vigente (hoy, 2026-10-10, los pedidos 652 y 7604). Si no hay
-- ninguno falla por "sin blanco", a propósito: habría que sembrar el caso.
--
--   psql "$DATABASE_URL" -f scripts/test-venta-j-1098.sql

DO $ensayo$
DECLARE
  v_fallas  text[] := '{}';
  v_blanco  bigint;
  v_canje   bigint;
  v_antes   int;
  v_despues int;
  v_n       int;
  r         record;
BEGIN
  SET LOCAL lock_timeout = '2s';

  -- ------------------------------------------------- 1 · VENTA-J en cero ---
  SELECT count(*), max((c->>'violaciones')::int) INTO v_n, v_antes
    FROM jsonb_array_elements(public.auditoria_integridad() -> 'checks') c
   WHERE c->>'id' = 'VENTA-J';
  IF v_n <> 1 THEN
    v_fallas := v_fallas || format('VENTA-J aparece %s veces en auditoria_integridad()', v_n);
  ELSIF v_antes <> 0 THEN
    v_fallas := v_fallas || format('VENTA-J = %s (tiene que estar en 0)', v_antes);
  END IF;

  -- -------------------------------------------- blanco elegido en runtime ---
  -- Un rechazo total: entregado, no canje, total 0, sin líneas, y con la huella
  -- completa de la salvedad (vigente, cantidad_entregada 0, línea borrada).
  SELECT p.id INTO v_blanco FROM pedidos p
   WHERE p.estado = 'entregado' AND p.canal <> 'cambio' AND p.total = 0
     AND NOT EXISTS (SELECT 1 FROM pedido_items pi WHERE pi.pedido_id = p.id)
     AND EXISTS (SELECT 1 FROM salvedades_items s
                  WHERE s.pedido_id = p.id AND s.sucursal_id = p.sucursal_id
                    AND s.estado_resolucion IS DISTINCT FROM 'anulada'
                    AND s.cantidad_entregada = 0
                    AND s.pedido_item_id IS NULL)
   ORDER BY p.id LIMIT 1;

  IF v_blanco IS NULL THEN
    v_fallas := v_fallas || 'sin blanco: no hay ningún rechazo total vigente en prod para los canarios';
  ELSE
    -- --------------------------------- 2 · la salvedad anulada no exime ----
    -- Anula todas las salvedades del pedido (por pedido_id): VENTA-J +1. Si el
    -- blanco es el 652, prueba además que se fue la exclusión a mano por id.
    BEGIN
      UPDATE salvedades_items SET estado_resolucion = 'anulada' WHERE pedido_id = v_blanco;
      SELECT (c->>'violaciones')::int INTO v_despues
        FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c WHERE c->>'id' = 'VENTA-J';
      IF v_despues - v_antes <> 1 THEN
        v_fallas := v_fallas || format('VENTA-J no ve el pedido %s con su salvedad anulada (%s → %s)',
                                       v_blanco, v_antes, v_despues);
      END IF;
      RAISE EXCEPTION USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('canario anulada saltado: %s', SQLERRM);
    END;

    -- ------------------------------- 3 · una salvedad parcial no exime ----
    -- Si la salvedad dejó algo entregado, el pedido sin líneas no se explica
    -- por ella: alguien las borró a mano. VENTA-J +1.
    BEGIN
      UPDATE salvedades_items SET cantidad_entregada = 1 WHERE pedido_id = v_blanco;
      SELECT (c->>'violaciones')::int INTO v_despues
        FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c WHERE c->>'id' = 'VENTA-J';
      IF v_despues - v_antes <> 1 THEN
        v_fallas := v_fallas || format('VENTA-J exime al pedido %s con una salvedad parcial (%s → %s)',
                                       v_blanco, v_antes, v_despues);
      END IF;
      RAISE EXCEPTION USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('canario parcial saltado: %s', SQLERRM);
    END;
  END IF;

  -- ------------------- 4 · el canje no cuenta; como venta, sí (molde 1043) ---
  BEGIN
    SELECT min(p.id) INTO v_canje FROM pedidos p
     WHERE p.estado = 'entregado' AND p.canal = 'cambio'
       AND NOT EXISTS (SELECT 1 FROM pedido_items pi WHERE pi.pedido_id = p.id)
       AND NOT EXISTS (SELECT 1 FROM salvedades_items s WHERE s.pedido_id = p.id);
    IF v_canje IS NULL THEN
      RAISE EXCEPTION 'no hay un canje entregado sin salvedades para el canario';
    END IF;
    UPDATE pedidos SET canal = 'app' WHERE id = v_canje;
    SELECT (c->>'violaciones')::int INTO v_despues
      FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c WHERE c->>'id' = 'VENTA-J';
    IF v_despues - v_antes <> 1 THEN
      v_fallas := v_fallas || format('VENTA-J no ve una venta entregada sin ítems (canje %s → app: %s → %s)',
                                     v_canje, v_antes, v_despues);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('canario canje saltado: %s', SQLERRM);
  END;

  -- ------------------------------------------------ 5 · ids únicos -------
  FOR r IN SELECT c->>'id' AS id, count(*) AS n
             FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c
            GROUP BY 1 HAVING count(*) > 1 LOOP
    v_fallas := v_fallas || format('el check %s aparece %s veces', r.id, r.n);
  END LOOP;

  -- ------------------------------------------------------------ veredicto --
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · VENTA-J en 0, exime el rechazo total del pedido % y sigue mordiendo (anulada, parcial, canje %)',
    v_blanco, v_canje;
END
$ensayo$;
