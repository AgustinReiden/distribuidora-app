-- Ensayo de "quién marcó la entrega" (#1555, mig NNN_quien_marco_la_entrega):
-- `pedidos.entregado_por` y `pedidos.entregado_at`, que escribe
-- `trg_pedidos_registrar_entrega`.
--
-- Corre contra prod SIN dejar rastro, como scripts/test-volver-a-pendiente-1313.sql
-- (de donde salen los helpers): un único DO que termina SIEMPRE en una
-- excepción. Sin la migración falla en E0 (las columnas no existen).
--
-- Usa dos pedidos que ya existen (sin parada, que no sean vale blanco ni canje),
-- los deja pendientes dentro de la transacción y entrega con fechas de 2099
-- para no cruzarse con ninguna rendición controlada.
--
--   E0 · Las columnas, el trigger y sus permisos están.
--   E1 · ADM entrega P1 por REST a nombre del chofer A → entregado_por = ADM
--        (no A), entregado_at = ahora, y es el mismo usuario que deja el historial.
--   E2 · Un UPDATE que no toca el estado no mueve el sello, y reenviar
--        'entregado' sobre un entregado tampoco.
--   E3 · ADM revierte la entrega → las dos columnas quedan en NULL. El chofer A
--        entrega después su pedido por REST → pasa `pedidos_proteger_columnas`
--        (el orden de los triggers) y entregado_por = A.
--   E4 · ADM entrega P2 con `marcar_entregas_masivo` a nombre de A →
--        entregado_por = ADM.
--   E5 · Las columnas no se escriben por REST: 42501 para ADM y para A.
--   E6 · Un pedido que nace entregado (el INSERT, como el vale blanco): con
--        sesión queda quien lo carga; sin sesión, su `usuario_id`.
--   E7 · El invariante en toda la tabla: sello si y sólo si entregado.
--
-- No llama a `marcar_entrega_y_pago_masivo` ni a las dos RPC del vale blanco:
-- registran cobros o piden un cliente habilitado, y lo que este trigger ve de
-- ellas es lo que ya cubren E4 (un UPDATE de estado dentro de una función
-- DEFINER) y E6 (un INSERT que nace entregado).

DO $ensayo$
DECLARE
  v_suc     bigint;
  v_a       uuid;
  v_adm     uuid;
  v_p1      bigint;
  v_p2      bigint;
  v_p3      bigint;
  v_t       text;
  v_n       bigint;
  v_fallas  text[] := '{}';
  v_notas   text[] := '{}';
  F1  CONSTANT date := DATE '2099-01-05';
  FTS CONSTANT text := '2099-01-05T12:00:00-03:00';
BEGIN
 BEGIN
  -- ------------------------------------------------------------------- E0 ---
  IF (SELECT count(*) FROM information_schema.columns
       WHERE table_schema = 'public' AND table_name = 'pedidos'
         AND column_name IN ('entregado_por', 'entregado_at')) <> 2 THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA',
      MESSAGE = 'ENSAYO FALLO · E0: pedidos no tiene entregado_por y entregado_at (falta la migración)';
  END IF;
  IF to_regprocedure('public.pedidos_registrar_entrega()') IS NULL
     OR has_function_privilege('anon', 'public.pedidos_registrar_entrega()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.pedidos_registrar_entrega()', 'EXECUTE') THEN
    v_fallas := v_fallas || 'E0 · pedidos_registrar_entrega no existe o tiene EXECUTE para anon/authenticated'::text;
  END IF;
  -- El trigger corre después de pedidos_proteger_columnas (orden por nombre).
  IF NOT EXISTS (SELECT 1 FROM pg_trigger t
                  WHERE t.tgrelid = 'public.pedidos'::regclass AND t.tgname = 'trg_pedidos_registrar_entrega'
                    AND t.tgenabled = 'O' AND t.tgname > 'pedidos_proteger_columnas') THEN
    v_fallas := v_fallas || 'E0 · trg_pedidos_registrar_entrega no está, está apagado u ordena antes de pedidos_proteger_columnas'::text;
  END IF;

  -- ------------------------------------------------------------- personas ---
  SELECT s.id, a.usuario_id, adm.usuario_id
    INTO v_suc, v_a, v_adm
    FROM sucursales s
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'transportista'
                   ORDER BY us.usuario_id LIMIT 1) a ON true
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'admin'
                   ORDER BY us.usuario_id LIMIT 1) adm ON true
   WHERE s.activa
     AND (SELECT count(*) FROM pedidos p JOIN clientes c ON c.id = p.cliente_id
           WHERE p.sucursal_id = s.id AND c.activo
             AND p.tipo_factura IS DISTINCT FROM 'VB' AND COALESCE(p.canal, 'app') <> 'cambio'
             AND p.estado = 'pendiente' AND p.total > 0
             AND NOT EXISTS (SELECT 1 FROM recorrido_pedidos rp WHERE rp.pedido_id = p.id)) >= 2
   ORDER BY s.id DESC
   LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'faltan fixtures: ninguna sucursal activa con un transportista, un admin y dos pedidos pendientes sin parada';
  END IF;

  SELECT min(p.id), max(p.id) INTO v_p1, v_p2
    FROM (SELECT p.id FROM pedidos p JOIN clientes c ON c.id = p.cliente_id
           WHERE p.sucursal_id = v_suc AND c.activo
             AND p.tipo_factura IS DISTINCT FROM 'VB' AND COALESCE(p.canal, 'app') <> 'cambio'
             AND p.estado = 'pendiente' AND p.total > 0
             AND NOT EXISTS (SELECT 1 FROM recorrido_pedidos rp WHERE rp.pedido_id = p.id)
           ORDER BY p.id DESC LIMIT 2) p;

  v_notas := v_notas || format('suc %s, A %s, ADM %s; P1 %s, P2 %s',
                               v_suc, left(v_a::text, 8), left(v_adm::text, 8), v_p1, v_p2);

  -- ---------------------------------------------------------------- helpers -
  CREATE OR REPLACE FUNCTION pg_temp.como(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims',
                       CASE WHEN p_uid IS NULL THEN ''
                            ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
    PERFORM set_config('request.jwt.claim.sub', COALESCE(p_uid::text, ''), true);
    PERFORM set_config('request.headers',
                       CASE WHEN p_suc IS NULL THEN '' ELSE json_build_object('x-sucursal-id', p_suc::text)::text END, true);
    IF p_uid IS NULL THEN
      EXECUTE 'RESET ROLE';
    ELSE
      EXECUTE 'SET LOCAL ROLE authenticated';
    END IF;
  END $f$;
  CREATE OR REPLACE FUNCTION pg_temp.intenta(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  BEGIN
    EXECUTE p_sql;
    RETURN 'PASA';
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE || ' ' || SQLERRM;
  END $f$;
  -- El sello de un pedido: "estado/quien/tiene fecha".
  CREATE OR REPLACE FUNCTION pg_temp.sello(p_pedido bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT format('%s/%s/%s', estado, COALESCE(left(entregado_por::text, 8), '-'),
                  CASE WHEN entregado_at IS NULL THEN '-' WHEN entregado_at = now() THEN 'ahora' ELSE entregado_at::date::text END)
      FROM public.pedidos WHERE id = p_pedido;
  $f$;

  -- Fixture base: P1 y P2 pendientes, sin chofer.
  UPDATE pedidos SET estado = 'pendiente', transportista_id = NULL, orden_entrega = NULL, retiro_deposito = false
   WHERE id IN (v_p1, v_p2);
  IF pg_temp.sello(v_p1) <> 'pendiente/-/-' THEN
    v_fallas := v_fallas || format('fixture · P1 pendiente quedó %s', pg_temp.sello(v_p1));
  END IF;

  -- ------------------------------------------------------------------- E1 ---
  PERFORM pg_temp.como(v_adm, v_suc);
  v_t := pg_temp.intenta(format(
    'UPDATE public.pedidos SET estado = ''entregado'', fecha_entrega = %L, transportista_id = %L, updated_at = now() WHERE id = %s',
    FTS, v_a, v_p1));
  PERFORM pg_temp.como(NULL, NULL);
  IF v_t <> 'PASA' OR pg_temp.sello(v_p1) <> format('entregado/%s/ahora', left(v_adm::text, 8)) THEN
    v_fallas := v_fallas || format('E1 · ADM entrega P1: %s, sello %s (esperado entregado/%s/ahora)',
                                   v_t, pg_temp.sello(v_p1), left(v_adm::text, 8));
  END IF;
  IF (SELECT transportista_id FROM pedidos WHERE id = v_p1) IS DISTINCT FROM v_a THEN
    v_fallas := v_fallas || 'E1 · el chofer de P1 no quedó en transportista_id'::text;
  END IF;
  -- La misma persona que el historial.
  IF (SELECT ph.usuario_id FROM pedido_historial ph
       WHERE ph.pedido_id = v_p1 AND ph.campo_modificado = 'estado' AND ph.valor_nuevo = 'entregado'
       ORDER BY ph.id DESC LIMIT 1)
     IS DISTINCT FROM (SELECT entregado_por FROM pedidos WHERE id = v_p1) THEN
    v_fallas := v_fallas || 'E1 · entregado_por no coincide con el usuario de la fila del historial'::text;
  END IF;

  -- ------------------------------------------------------------------- E2 ---
  -- Se le pone un sello reconocible (un UPDATE que no nombra el estado no dispara el trigger).
  UPDATE pedidos SET entregado_at = TIMESTAMPTZ '2000-01-01 12:00:00-03' WHERE id = v_p1;
  PERFORM pg_temp.como(v_adm, v_suc);
  v_t := pg_temp.intenta(format('UPDATE public.pedidos SET notas = ''ensayo 1555'' WHERE id = %s', v_p1));
  v_t := v_t || ' | ' || pg_temp.intenta(format(
    'UPDATE public.pedidos SET estado = ''entregado'', updated_at = now() WHERE id = %s', v_p1));
  PERFORM pg_temp.como(NULL, NULL);
  IF v_t <> 'PASA | PASA' OR pg_temp.sello(v_p1) <> format('entregado/%s/2000-01-01', left(v_adm::text, 8)) THEN
    v_fallas := v_fallas || format('E2 · el sello se movió sin transición: %s, sello %s', v_t, pg_temp.sello(v_p1));
  END IF;

  -- ------------------------------------------------------------------- E3 ---
  PERFORM pg_temp.como(v_adm, v_suc);
  v_t := pg_temp.intenta(format(
    'UPDATE public.pedidos SET estado = ''asignado'', fecha_entrega = NULL, updated_at = now() WHERE id = %s', v_p1));
  PERFORM pg_temp.como(NULL, NULL);
  IF v_t <> 'PASA' OR pg_temp.sello(v_p1) <> 'asignado/-/-' THEN
    v_fallas := v_fallas || format('E3 · revertir la entrega: %s, sello %s (esperado asignado/-/-)', v_t, pg_temp.sello(v_p1));
  END IF;
  PERFORM pg_temp.como(v_a, v_suc);
  v_t := pg_temp.intenta(format(
    'UPDATE public.pedidos SET estado = ''entregado'', fecha_entrega = %L, updated_at = now() WHERE id = %s', FTS, v_p1));
  PERFORM pg_temp.como(NULL, NULL);
  IF v_t <> 'PASA' OR pg_temp.sello(v_p1) <> format('entregado/%s/ahora', left(v_a::text, 8)) THEN
    v_fallas := v_fallas || format('E3 · el chofer entrega su pedido: %s, sello %s (esperado entregado/%s/ahora)',
                                   v_t, pg_temp.sello(v_p1), left(v_a::text, 8));
  END IF;

  -- ------------------------------------------------------------------- E4 ---
  PERFORM pg_temp.como(v_adm, v_suc);
  v_t := pg_temp.intenta(format('SELECT public.marcar_entregas_masivo(ARRAY[%s]::bigint[], %L::uuid, %L::date)', v_p2, v_a, F1));
  PERFORM pg_temp.como(NULL, NULL);
  IF v_t <> 'PASA' OR pg_temp.sello(v_p2) <> format('entregado/%s/ahora', left(v_adm::text, 8)) THEN
    v_fallas := v_fallas || format('E4 · masiva de ADM a nombre de A: %s, sello %s (esperado entregado/%s/ahora)',
                                   v_t, pg_temp.sello(v_p2), left(v_adm::text, 8));
  END IF;

  -- ------------------------------------------------------------------- E5 ---
  PERFORM pg_temp.como(v_adm, v_suc);
  v_t := pg_temp.intenta(format('UPDATE public.pedidos SET entregado_por = %L WHERE id = %s', v_a, v_p2));
  v_t := left(v_t, 5) || ' | ' || left(pg_temp.intenta(format('UPDATE public.pedidos SET entregado_at = now() WHERE id = %s', v_p2)), 5);
  PERFORM pg_temp.como(v_a, v_suc);
  v_t := v_t || ' | ' || left(pg_temp.intenta(format('UPDATE public.pedidos SET entregado_por = %L WHERE id = %s', v_a, v_p1)), 5);
  PERFORM pg_temp.como(NULL, NULL);
  IF v_t <> '42501 | 42501 | 42501' THEN
    v_fallas := v_fallas || format('E5 · escribir el sello por REST dio %s (esperado 42501 las tres)', v_t);
  END IF;

  -- ------------------------------------------------------------------- E6 ---
  -- Un pedido que nace entregado: una copia de P2 (ya entregado, con chofer).
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.jwt.claim.sub', v_adm::text, true);
    INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, transportista_id, fecha, fecha_entrega, tipo_factura, canal)
    SELECT cliente_id, sucursal_id, usuario_id, total, 'entregado', transportista_id, fecha, fecha_entrega, tipo_factura, canal
      FROM pedidos WHERE id = v_p2
    RETURNING id INTO v_p3;
    IF pg_temp.sello(v_p3) <> format('entregado/%s/ahora', left(v_adm::text, 8)) THEN
      v_fallas := v_fallas || format('E6 · nace entregado con sesión: sello %s (esperado entregado/%s/ahora)',
                                     pg_temp.sello(v_p3), left(v_adm::text, 8));
    END IF;
    PERFORM pg_temp.como(NULL, NULL);
    INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, transportista_id, fecha, fecha_entrega, tipo_factura, canal)
    SELECT cliente_id, sucursal_id, usuario_id, total, 'entregado', transportista_id, fecha, fecha_entrega, tipo_factura, canal
      FROM pedidos WHERE id = v_p2
    RETURNING id INTO v_p3;
    IF pg_temp.sello(v_p3) <> format('entregado/%s/ahora',
         COALESCE((SELECT left(pf.id::text, 8) FROM pedidos p JOIN perfiles pf ON pf.id = p.usuario_id WHERE p.id = v_p2), '-')) THEN
      v_fallas := v_fallas || format('E6 · nace entregado sin sesión: sello %s (esperado el usuario_id del pedido)', pg_temp.sello(v_p3));
    END IF;
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.como(NULL, NULL);
    v_fallas := v_fallas || ('E6 · error inesperado: ' || SQLSTATE || ' ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------- E7 ---
  SELECT count(*) INTO v_n FROM pedidos
   WHERE (estado = 'entregado' AND entregado_at IS NULL)
      OR (estado IS DISTINCT FROM 'entregado' AND (entregado_at IS NOT NULL OR entregado_por IS NOT NULL));
  IF v_n <> 0 THEN
    v_fallas := v_fallas || format('E7 · %s pedidos rompen el invariante (sello si y sólo si entregado)', v_n);
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA', MESSAGE = format(E'ENSAYO FALLO (%s fallas, todo revertido):\n- %s\nnotas: %s',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), array_to_string(v_notas, ' | '));
  END IF;
  RAISE EXCEPTION USING ERRCODE = 'ZZ0OK', MESSAGE = format('ENSAYO OK (todo revertido) · notas: %s', array_to_string(v_notas, ' | '));
 EXCEPTION WHEN SQLSTATE 'ZZ0OK' OR SQLSTATE 'ZZ0FA' THEN
  -- Se relanza afuera del bloque que escribió.
  GET STACKED DIAGNOSTICS v_t = MESSAGE_TEXT;
  RAISE EXCEPTION '%', v_t;
 END;
END
$ensayo$;
