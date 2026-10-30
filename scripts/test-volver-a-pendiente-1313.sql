-- Ensayo de "Volver a pendiente" (#1313, mig NNN_rutas_2): una RPC atómica
-- en vez de tres llamadas sueltas.
--
-- Corre contra prod SIN dejar rastro, igual que scripts/test-rutas-1313.sql
-- (de donde salen los fixtures y los helpers): un único DO que termina SIEMPRE
-- en una excepción. Va con NNN_rutas_1 aplicada; antes de aplicar NNN_rutas_2
-- se corre pegado detrás de su cuerpo sin el BEGIN/COMMIT. Tiene que correr
-- también con el trigger de transiciones de `pedidos.estado` de la tarjeta 4
-- (#1317) aplicado: la RPC es SECURITY DEFINER y no pasa por el guard de REST.
--
--   V1 · ADM vuelve P1 (asignado, en la ruta en curso de A) → pendiente, sin
--        chofer ni orden, sin parada en la ruta, y la ruta cuenta 1 parada.
--   V2 · A (chofer) intenta volver P2 → 42501.
--   V3 · P1 entregado → error ("Revertir entrega"), P1 sigue entregado.
--   V4 · A no entrega P1 (parada no_entregado); ADM lo vuelve → la parada se
--        borra (destraba las guardas de edición) y el intento queda en
--        pedido_historial.
--   V5 · Sin el EXECUTE para anon.

DO $ensayo$
DECLARE
  v_suc     bigint;
  v_a       uuid;
  v_b       uuid;
  v_adm     uuid;
  v_pxt     uuid;
  v_otra    bigint;
  v_p1      bigint;
  v_p2      bigint;
  v_ra      bigint;
  v_rb      bigint;
  v_txt     text;
  v_n       bigint;
  v_t       text;
  v_fallas  text[] := '{}';
  v_notas   text[] := '{}';
  F1 CONSTANT date := DATE '2099-01-05';
  F2 CONSTANT date := DATE '2099-01-06';
BEGIN
 BEGIN
  -- ------------------------------------------------------------- personas ---
  SELECT s.id, a.usuario_id, b.usuario_id, adm.usuario_id
    INTO v_suc, v_a, v_b, v_adm
    FROM sucursales s
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'transportista'
                   ORDER BY us.usuario_id LIMIT 1) a ON true
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.id <> a.usuario_id
                     AND (pf.rol = 'transportista'
                          OR (pf.rol = 'preventista' AND EXISTS (
                                SELECT 1 FROM perfil_roles pr WHERE pr.usuario_id = pf.id
                                   AND pr.sucursal_id = s.id AND pr.rol = 'transportista')))
                   ORDER BY (pf.rol = 'preventista') DESC, us.usuario_id LIMIT 1) b ON true
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'admin'
                   ORDER BY us.usuario_id LIMIT 1) adm ON true
   WHERE s.activa
   ORDER BY s.id DESC
   LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'faltan fixtures: ninguna sucursal activa con transportista A, otro chofer B y un admin';
  END IF;

  SELECT min(p.id), max(p.id) INTO v_p1, v_p2
    FROM (SELECT p.id FROM pedidos p JOIN clientes c ON c.id = p.cliente_id
           WHERE p.sucursal_id = v_suc AND c.activo
             AND p.tipo_factura IS DISTINCT FROM 'VB'
             AND p.estado IN ('pendiente', 'entregado')
             AND p.total > 0
             AND NOT EXISTS (SELECT 1 FROM recorrido_pedidos rp WHERE rp.pedido_id = p.id)
           ORDER BY (p.estado = 'pendiente') DESC, p.id DESC LIMIT 2) p;
  IF v_p1 IS NULL OR v_p1 = v_p2 THEN
    RAISE EXCEPTION 'faltan fixtures en la sucursal %: dos pedidos sin parada (P1 %, P2 %)', v_suc, v_p1, v_p2;
  END IF;

  -- Un preventista con el extra en S, y otra sucursal suya sin el extra (R9).
  SELECT pf.id, (SELECT us2.sucursal_id FROM usuario_sucursales us2
                  WHERE us2.usuario_id = pf.id AND us2.sucursal_id <> v_suc
                    AND NOT EXISTS (SELECT 1 FROM perfil_roles pr2 WHERE pr2.usuario_id = pf.id
                                       AND pr2.sucursal_id = us2.sucursal_id)
                  ORDER BY 1 LIMIT 1)
    INTO v_pxt, v_otra
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id AND us.sucursal_id = v_suc
   WHERE pf.activo AND pf.rol = 'preventista'
     AND EXISTS (SELECT 1 FROM perfil_roles pr WHERE pr.usuario_id = pf.id
                    AND pr.sucursal_id = v_suc AND pr.rol = 'transportista')
   ORDER BY pf.id LIMIT 1;

  v_notas := v_notas || format('suc %s, A %s, B %s, ADM %s, PXT %s (otra suc %s); P1 %s, P2 %s',
                               v_suc, left(v_a::text, 8), left(v_b::text, 8), left(v_adm::text, 8),
                               left(COALESCE(v_pxt::text, '-'), 8), v_otra, v_p1, v_p2);

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
  CREATE OR REPLACE FUNCTION pg_temp.v(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE r text;
  BEGIN
    EXECUTE p_sql INTO r;
    RETURN r;
  END $f$;
  -- La ruta de un chofer: aplicar_orden_ruta como ADM. Devuelve el id.
  CREATE OR REPLACE FUNCTION pg_temp.ruta(p_adm uuid, p_suc bigint, p_chofer uuid, p_pedidos bigint[], p_fecha date)
  RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE r bigint;
  BEGIN
    PERFORM pg_temp.como(p_adm, p_suc);
    EXECUTE 'SELECT public.aplicar_orden_ruta($1, $2, NULL, NULL, NULL, $3)'
      INTO r
      USING p_chofer,
            (SELECT jsonb_agg(jsonb_build_object('pedido_id', x.id, 'orden_entrega', x.o))
               FROM unnest(p_pedidos) WITH ORDINALITY AS x(id, o)),
            p_fecha;
    PERFORM pg_temp.como(NULL, NULL);
    RETURN r;
  END $f$;
  -- El chofer marca la no entrega.
  CREATE OR REPLACE FUNCTION pg_temp.no_entrega(p_chofer uuid, p_suc bigint, p_pedido bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.como(p_chofer, p_suc);
    EXECUTE 'SELECT public.marcar_no_entregado($1, ''cerrado'', NULL)' USING p_pedido;
    PERFORM pg_temp.como(NULL, NULL);
  END $f$;
  -- Estado de la parada de un pedido en una ruta ('-' si no está).
  CREATE OR REPLACE FUNCTION pg_temp.parada(p_r bigint, p_p bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT COALESCE((SELECT estado_entrega FROM public.recorrido_pedidos
                      WHERE recorrido_id = p_r AND pedido_id = p_p), '-');
  $f$;

  -- Fixture base: P1 y P2 pendientes sin chofer.
  UPDATE pedidos SET estado = 'pendiente', transportista_id = NULL, orden_entrega = NULL
   WHERE id IN (v_p1, v_p2);

  -- ------------------------------------------------------------------- V1 ---
  BEGIN
    v_ra := pg_temp.ruta(v_adm, v_suc, v_a, ARRAY[v_p1, v_p2], F1);
    PERFORM pg_temp.como(v_adm, v_suc);
    v_txt := pg_temp.v(format('SELECT public.volver_pedido_a_pendiente(%s)::text', v_p1));
    PERFORM pg_temp.como(NULL, NULL);
    SELECT format('%s/%s/%s', estado, transportista_id IS NULL, orden_entrega IS NULL)
      INTO v_t FROM pedidos WHERE id = v_p1;
    IF v_t IS DISTINCT FROM 'pendiente/t/t' OR pg_temp.parada(v_ra, v_p1) <> '-'
       OR (SELECT total_pedidos FROM recorridos WHERE id = v_ra) <> 1
       OR (v_txt::jsonb->>'paradas_eliminadas') <> '1' THEN
      v_fallas := v_fallas || format('V1 · P1 %s, parada %s, ruta cuenta %s, respuesta %s',
                                     v_t, pg_temp.parada(v_ra, v_p1),
                                     (SELECT total_pedidos FROM recorridos WHERE id = v_ra), v_txt);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('V1 · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------- V2 ---
  BEGIN
    v_ra := pg_temp.ruta(v_adm, v_suc, v_a, ARRAY[v_p1, v_p2], F1);
    PERFORM pg_temp.como(v_a, v_suc);
    v_txt := pg_temp.intenta(format('SELECT public.volver_pedido_a_pendiente(%s)', v_p2));
    PERFORM pg_temp.como(NULL, NULL);
    IF left(v_txt, 5) <> '42501' OR (SELECT estado FROM pedidos WHERE id = v_p2) <> 'asignado' THEN
      v_fallas := v_fallas || ('V2 · el chofer volvió un pedido a pendiente: ' || v_txt);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('V2 · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------- V3 ---
  BEGIN
    UPDATE pedidos SET estado = 'entregado', fecha_entrega = now(), transportista_id = v_a WHERE id = v_p1;
    PERFORM pg_temp.como(v_adm, v_suc);
    v_txt := pg_temp.intenta(format('SELECT public.volver_pedido_a_pendiente(%s)', v_p1));
    PERFORM pg_temp.como(NULL, NULL);
    IF v_txt = 'PASA' OR (SELECT estado FROM pedidos WHERE id = v_p1) <> 'entregado' THEN
      v_fallas := v_fallas || ('V3 · un entregado volvió a pendiente: ' || v_txt);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('V3 · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------- V4 ---
  BEGIN
    v_ra := pg_temp.ruta(v_adm, v_suc, v_a, ARRAY[v_p1, v_p2], F1);
    PERFORM pg_temp.no_entrega(v_a, v_suc, v_p1);
    PERFORM pg_temp.como(v_adm, v_suc);
    v_txt := pg_temp.v(format('SELECT public.volver_pedido_a_pendiente(%s)::text', v_p1));
    PERFORM pg_temp.como(NULL, NULL);
    IF (v_txt::jsonb->>'paradas_eliminadas') <> '1' OR pg_temp.parada(v_ra, v_p1) <> '-'
       OR (SELECT count(*) FROM pedido_historial WHERE pedido_id = v_p1 AND campo_modificado = 'no_entrega') <> 1 THEN
      v_fallas := v_fallas || format('V4 · respuesta %s, parada %s (esperado 1, -, con historial)', v_txt, pg_temp.parada(v_ra, v_p1));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('V4 · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------- V5 ---
  IF has_function_privilege('anon', 'public.volver_pedido_a_pendiente(bigint)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.volver_pedido_a_pendiente(bigint)', 'EXECUTE') THEN
    v_fallas := v_fallas || 'V5 · grants de volver_pedido_a_pendiente'::text;
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
