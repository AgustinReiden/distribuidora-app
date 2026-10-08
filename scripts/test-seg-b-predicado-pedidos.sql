-- Ensayo de #1020: el gate se entera si una copia del predicado de
-- mt_pedidos_select deja de decir lo mismo.
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en
-- RAISE EXCEPTION, así que lo que reescribe se deshace. No toca la policy
-- (ALTER POLICY bloquearía `pedidos` mientras dura la transacción): ese lado lo
-- cubre el $verif$ de la migración pasándole una policy falsa al check.
--
-- Dos ediciones sutiles, de las que SEG-A no ve porque el cuerpo sigue
-- nombrando el helper de rol:
--   1. el inline de deuda_previa con `OR true` al final;
--   2. puede_leer_pedido con `OR true` en el lugar del transportista.
-- Después de cada una, auditoria_integridad() tiene que tener MÁS checks en
-- rojo que antes. Sin SEG-B (antes de la migración de #1020) no cambia nada.
--
-- Veredicto en el mensaje del error final: 'ENSAYO OK …' o 'ENSAYO FALLÓ …'.
--
--   psql "$DATABASE_URL" -f scripts/test-seg-b-predicado-pedidos.sql

DO $ensayo$
DECLARE
  v_antes   int;
  v_despues int;
  v_fallas  text[] := '{}';
BEGIN
  SELECT count(*) INTO v_antes
    FROM jsonb_array_elements(public.auditoria_integridad() -> 'checks') c
   WHERE NOT (c->>'ok')::boolean;

  -- 1 · deuda_previa: el guard nombra el helper pero deja pasar a todos.
  BEGIN
    EXECUTE replace(pg_get_functiondef('public.deuda_previa(public.pedidos)'::regprocedure),
      'OR es_encargado_o_admin())', 'OR es_encargado_o_admin() OR true)');
    SELECT count(*) INTO v_despues
      FROM jsonb_array_elements(public.auditoria_integridad() -> 'checks') c
     WHERE NOT (c->>'ok')::boolean;
    IF v_despues <= v_antes THEN
      v_fallas := v_fallas || format('deuda_previa con OR true: auditoria_integridad no se entera (rojos antes %s, después %s)', v_antes, v_despues);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- 2 · puede_leer_pedido: cualquiera "puede leer" cualquier pedido.
  BEGIN
    EXECUTE replace(pg_get_functiondef('public.puede_leer_pedido(bigint)'::regprocedure),
      'OR pe.transportista_id = auth.uid())', 'OR true)');
    SELECT count(*) INTO v_despues
      FROM jsonb_array_elements(public.auditoria_integridad() -> 'checks') c
     WHERE NOT (c->>'ok')::boolean;
    IF v_despues <= v_antes THEN
      v_fallas := v_fallas || format('puede_leer_pedido con OR true: auditoria_integridad no se entera (rojos antes %s, después %s)', v_antes, v_despues);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (% fallas, todo revertido):\n- %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK (todo revertido). Rojos en auditoria_integridad antes de editar: %', v_antes;
END
$ensayo$;
