-- Ensayo de #1313 y #1312 (mig NNN_rutas_1): un pedido vive en una sola ruta,
-- el reorden no borra el "no entregado", cambiar el chofer no arrastra lo que
-- ya no es de la ruta, la transición de recorridos.estado por REST y el rol
-- extra en es_transportista().
--
-- Corre contra prod SIN dejar rastro (salvo valores de secuencia de
-- recorridos, recorrido_pedidos, notificaciones, pedido_historial y
-- audit_logs): un único DO que termina SIEMPRE en una excepción, y cada caso
-- corre en su propio sub-bloque que se revierte. Antes de aplicar la
-- migración se corre pegado detrás de su cuerpo SIN el BEGIN/COMMIT, en la
-- misma llamada: la excepción final revierte también la migración. Después de
-- aplicarla, solo.
--
-- Fixtures (el ensayo falla si falta alguno, nunca se saltea): una sucursal
-- activa S con un transportista base activo A, otro chofer activo B (base, o
-- preventista con el extra en S), un admin ADM, y dos pedidos P1 y P2 de S,
-- no VB, con cliente activo y sin ninguna parada en ninguna ruta, que el
-- fixture deja en 'pendiente' sin chofer. Las rutas van en 2099 para no chocar
-- con uq_recorrido_vigente. Los fixtures van como postgres sin claims; cada
-- paso de un usuario, con sus claims, el header x-sucursal-id y SET LOCAL ROLE
-- authenticated, por EXECUTE.
--
--   R1  · LOG-3 en curso: A tiene P1 y P2; A no entrega P1; ADM le da P1 a B.
--         La parada de A se borra y el intento queda en pedido_historial
--         ('no_entrega'); la de B queda 'pendiente': una sola. P1 se entrega →
--         se marca en la de B, y A no la cuenta (facturado = P2, entregados 0,
--         cobrado 0), tampoco después de recalcular_recorrido(A).
--   R1b · Sin no-entrega: ADM pasa P2 de la ruta en curso de A a la de B → la
--         parada de A se borra (no se visitó) y A cuenta 1 parada.
--   R2  · LOG-3 ruta cerrada: A completa su ruta por REST con P2 pendiente;
--         ADM le arma a B otra fecha con P2 → la de A queda 'reasignado' y no
--         cuenta ni factura P2; completed_at lo puso el servidor.
--   R3  · LOG-4 reorden: A no entrega P1; ADM re-arma la ruta de A sin P1 →
--         la parada se borra y el intento queda en el historial. ADM la re-arma
--         con P1 → parada 'pendiente' limpia y P1 asignado a A.
--   R3b · Si vuelve a salir en la misma ruta sin re-armarla antes sin él, la
--         parada 'no_entregado' se reabre limpia y el intento queda en el
--         historial.
--   R4  · LOG-4: A no entrega P1, ADM se lo da a B, y re-arma la de A sin P1 →
--         P1 sigue asignado a B (antes volvía a preparación sin chofer).
--   R5  · LOG-6: A no entrega P1; ADM le pasa la ruta a B → P2 es de B y P1
--         sigue pendiente sin chofer.
--   R6  · LOG-5 por REST, como A: cancelar → 42501; tocar sólo completed_at →
--         pasa pero no cambia; completar → pasa; reabrir → 42501. Como
--         postgres → pasa.
--   R7  · quitar_pedido_de_recorridos_activos(P1) con P1 'no_entregado' en la
--         ruta de A (lo que hace la cancelación) → la borra (1 parada, RUTA-C
--         limpio) y el intento queda en el historial.
--   R8  · Contadores: _recorrido_contadores da lo guardado en toda ruta de prod
--         (con la migración recién aplicada no se movió ninguna).
--   R10 · A no entrega P1 y el admin igual confirma la entrega sin re-rutear
--         (con A de chofer) → la parada de A pasa a 'entregado' (RUTA-A limpio)
--         y el intento queda en el historial.
--   R11 · Revertir la entrega de P2 (entregado → asignado) → su parada vuelve a
--         'pendiente' sin hora, y la ruta no la cuenta entregada.
--   R9  · #1312: un preventista con el extra transportista en S →
--         es_transportista() true con el header de S; con el de otra sucursal
--         suya (si tiene) false.
--   K   · Estructura: las dos funciones dropeadas no existen; FKs RESTRICT;
--         CHECKs; trigger enganchado; funciones nuevas sin EXECUTE para anon
--         ni authenticated; aplicar_orden_ruta sin CURRENT_DATE.

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
  -- Intentos de no entrega de un pedido en su historial.
  CREATE OR REPLACE FUNCTION pg_temp.hist(p_p bigint) RETURNS bigint LANGUAGE sql AS $f$
    SELECT count(*) FROM public.pedido_historial
     WHERE pedido_id = p_p AND campo_modificado = 'no_entrega';
  $f$;
  -- Estado de la parada de un pedido en una ruta ('-' si no está).
  CREATE OR REPLACE FUNCTION pg_temp.parada(p_r bigint, p_p bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT COALESCE((SELECT estado_entrega FROM public.recorrido_pedidos
                      WHERE recorrido_id = p_r AND pedido_id = p_p), '-');
  $f$;

  -- Fixture base: P1 y P2 pendientes sin chofer.
  UPDATE pedidos SET estado = 'pendiente', transportista_id = NULL, orden_entrega = NULL
   WHERE id IN (v_p1, v_p2);

  -- ------------------------------------------------------------------- R1 ---
  BEGIN
    v_ra := pg_temp.ruta(v_adm, v_suc, v_a, ARRAY[v_p1, v_p2], F1);
    PERFORM pg_temp.no_entrega(v_a, v_suc, v_p1);
    v_rb := pg_temp.ruta(v_adm, v_suc, v_b, ARRAY[v_p1], F1);
    IF pg_temp.parada(v_ra, v_p1) <> '-' OR pg_temp.parada(v_rb, v_p1) <> 'pendiente'
       OR pg_temp.hist(v_p1) <> 1 THEN
      v_fallas := v_fallas || format('R1 · tras reasignar: A %s, B %s, historial %s (esperado -, pendiente, 1)',
                                     pg_temp.parada(v_ra, v_p1), pg_temp.parada(v_rb, v_p1), pg_temp.hist(v_p1));
    END IF;
    SELECT count(*) INTO v_n FROM recorrido_pedidos rp JOIN recorridos r ON r.id = rp.recorrido_id
     WHERE rp.pedido_id = v_p1 AND r.estado = 'en_curso' AND rp.estado_entrega IN ('pendiente', 'entregado');
    IF v_n <> 1 THEN
      v_fallas := v_fallas || format('R1 · P1 tiene %s paradas vivas en rutas en curso (esperado 1)', v_n);
    END IF;

    UPDATE pedidos SET estado = 'entregado', fecha_entrega = now() WHERE id = v_p1;
    IF pg_temp.parada(v_rb, v_p1) <> 'entregado' OR pg_temp.parada(v_ra, v_p1) <> '-' THEN
      v_fallas := v_fallas || format('R1 · tras entregar: A %s, B %s (esperado - / entregado)',
                                     pg_temp.parada(v_ra, v_p1), pg_temp.parada(v_rb, v_p1));
    END IF;
    SELECT format('%s/%s/%s', r.pedidos_entregados, r.total_cobrado = 0,
                  r.total_facturado = (SELECT total FROM pedidos WHERE id = v_p2))
      INTO v_txt FROM recorridos r WHERE r.id = v_ra;
    IF v_txt <> '0/t/t' THEN
      v_fallas := v_fallas || format('R1 · contadores de A (entregados/cobrado=0/facturado=P2): %s, esperado 0/t/t', v_txt);
    END IF;
    IF (SELECT pedidos_entregados FROM recorridos WHERE id = v_rb) <> 1 THEN
      v_fallas := v_fallas || 'R1 · la ruta de B no cuenta la entrega'::text;
    END IF;
    PERFORM pg_temp.como(v_adm, v_suc);
    EXECUTE 'SELECT public.recalcular_recorrido($1)' USING v_ra;
    PERFORM pg_temp.como(NULL, NULL);
    IF (SELECT format('%s/%s', total_pedidos, pedidos_entregados) FROM recorridos WHERE id = v_ra) <> '1/0' THEN
      v_fallas := v_fallas || 'R1 · recalcular_recorrido(A) cuenta P1, que se entregó en la ruta de B'::text;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('R1 · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------ R1b ---
  BEGIN
    v_ra := pg_temp.ruta(v_adm, v_suc, v_a, ARRAY[v_p1, v_p2], F1);
    v_rb := pg_temp.ruta(v_adm, v_suc, v_b, ARRAY[v_p2], F1);
    IF pg_temp.parada(v_ra, v_p2) <> '-' OR pg_temp.parada(v_rb, v_p2) <> 'pendiente'
       OR (SELECT total_pedidos FROM recorridos WHERE id = v_ra) <> 1
       OR (SELECT transportista_id FROM pedidos WHERE id = v_p2) IS DISTINCT FROM v_b THEN
      v_fallas := v_fallas || format('R1b · P2 en A %s, en B %s, A cuenta %s (esperado -, pendiente, 1)',
                                     pg_temp.parada(v_ra, v_p2), pg_temp.parada(v_rb, v_p2),
                                     (SELECT total_pedidos FROM recorridos WHERE id = v_ra));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('R1b · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------- R2 ---
  BEGIN
    v_ra := pg_temp.ruta(v_adm, v_suc, v_a, ARRAY[v_p1, v_p2], F1);
    PERFORM pg_temp.como(v_a, v_suc);
    v_txt := pg_temp.intenta(format(
      'UPDATE public.recorridos SET estado = ''completado'', completed_at = ''2000-01-01'' WHERE id = %s', v_ra));
    PERFORM pg_temp.como(NULL, NULL);
    IF v_txt <> 'PASA' THEN
      v_fallas := v_fallas || ('R2 · A no pudo completar su ruta por REST: ' || v_txt);
    END IF;
    IF (SELECT completed_at < now() - interval '1 minute' FROM recorridos WHERE id = v_ra) THEN
      v_fallas := v_fallas || 'R2 · completed_at quedó el que mandó el cliente, no el del servidor'::text;
    END IF;
    v_rb := pg_temp.ruta(v_adm, v_suc, v_b, ARRAY[v_p2], F2);
    IF pg_temp.parada(v_ra, v_p2) <> 'reasignado' OR pg_temp.parada(v_rb, v_p2) <> 'pendiente' THEN
      v_fallas := v_fallas || format('R2 · P2 en A (completada) %s, en B %s (esperado reasignado / pendiente)',
                                     pg_temp.parada(v_ra, v_p2), pg_temp.parada(v_rb, v_p2));
    END IF;
    IF (SELECT total_facturado FROM recorridos WHERE id = v_ra) <> (SELECT total FROM pedidos WHERE id = v_p1)
       OR (SELECT total_pedidos FROM recorridos WHERE id = v_ra) <> 1 THEN
      v_fallas := v_fallas || 'R2 · la ruta completada de A sigue contando o facturando P2'::text;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('R2 · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------- R3 ---
  BEGIN
    v_ra := pg_temp.ruta(v_adm, v_suc, v_a, ARRAY[v_p1, v_p2], F1);
    PERFORM pg_temp.no_entrega(v_a, v_suc, v_p1);
    PERFORM pg_temp.ruta(v_adm, v_suc, v_a, ARRAY[v_p2], F1);
    IF pg_temp.parada(v_ra, v_p1) <> '-' OR pg_temp.hist(v_p1) <> 1 THEN
      v_fallas := v_fallas || format('R3 · re-armar sin P1: parada %s, historial %s (esperado -, 1)',
                                     pg_temp.parada(v_ra, v_p1), pg_temp.hist(v_p1));
    END IF;
    PERFORM pg_temp.ruta(v_adm, v_suc, v_a, ARRAY[v_p2, v_p1], F1);
    SELECT format('%s/%s/%s/%s', rp.estado_entrega, rp.motivo_no_entrega, p.estado, p.transportista_id = v_a)
      INTO v_txt
      FROM recorrido_pedidos rp JOIN pedidos p ON p.id = rp.pedido_id
     WHERE rp.recorrido_id = v_ra AND rp.pedido_id = v_p1;
    IF v_txt IS DISTINCT FROM 'pendiente//asignado/t' THEN
      v_fallas := v_fallas || format('R3 · P1 vuelto a salir: %s (esperado pendiente//asignado/t)', v_txt);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('R3 · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------ R3b ---
  BEGIN
    v_ra := pg_temp.ruta(v_adm, v_suc, v_a, ARRAY[v_p1, v_p2], F1);
    PERFORM pg_temp.no_entrega(v_a, v_suc, v_p1);
    PERFORM pg_temp.ruta(v_adm, v_suc, v_a, ARRAY[v_p2, v_p1], F1);
    SELECT format('%s/%s/%s', rp.estado_entrega, rp.motivo_no_entrega, p.estado)
      INTO v_txt
      FROM recorrido_pedidos rp JOIN pedidos p ON p.id = rp.pedido_id
     WHERE rp.recorrido_id = v_ra AND rp.pedido_id = v_p1;
    IF v_txt IS DISTINCT FROM 'pendiente//asignado' OR pg_temp.hist(v_p1) <> 1 THEN
      v_fallas := v_fallas || format('R3b · P1 reabierto en la misma ruta: %s, historial %s (esperado pendiente//asignado, 1)',
                                     v_txt, pg_temp.hist(v_p1));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('R3b · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------- R4 ---
  BEGIN
    v_ra := pg_temp.ruta(v_adm, v_suc, v_a, ARRAY[v_p1, v_p2], F1);
    PERFORM pg_temp.no_entrega(v_a, v_suc, v_p1);
    PERFORM pg_temp.ruta(v_adm, v_suc, v_b, ARRAY[v_p1], F1);
    PERFORM pg_temp.ruta(v_adm, v_suc, v_a, ARRAY[v_p2], F1);
    SELECT format('%s/%s', estado, transportista_id = v_b) INTO v_txt FROM pedidos WHERE id = v_p1;
    IF v_txt IS DISTINCT FROM 'asignado/t' THEN
      v_fallas := v_fallas || format('R4 · re-armar la ruta de A le tocó P1, que es de B: %s', v_txt);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('R4 · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------- R5 ---
  BEGIN
    v_ra := pg_temp.ruta(v_adm, v_suc, v_a, ARRAY[v_p1, v_p2], F1);
    PERFORM pg_temp.no_entrega(v_a, v_suc, v_p1);
    PERFORM pg_temp.como(v_adm, v_suc);
    EXECUTE 'SELECT public.cambiar_transportista_recorrido($1, $2)' USING v_ra, v_b;
    PERFORM pg_temp.como(NULL, NULL);
    SELECT format('%s/%s|%s/%s', p1.estado, p1.transportista_id IS NULL, p2.estado, p2.transportista_id = v_b)
      INTO v_txt FROM pedidos p1, pedidos p2 WHERE p1.id = v_p1 AND p2.id = v_p2;
    IF v_txt IS DISTINCT FROM 'pendiente/t|asignado/t' THEN
      v_fallas := v_fallas || format('R5 · tras cambiar el chofer: %s (esperado pendiente/t|asignado/t)', v_txt);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('R5 · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------- R6 ---
  BEGIN
    v_ra := pg_temp.ruta(v_adm, v_suc, v_a, ARRAY[v_p1, v_p2], F1);
    PERFORM pg_temp.como(v_a, v_suc);
    v_txt := pg_temp.intenta(format('UPDATE public.recorridos SET estado = ''cancelado'' WHERE id = %s', v_ra));
    IF left(v_txt, 5) <> '42501' THEN
      v_fallas := v_fallas || ('R6 · A canceló su ruta por REST: ' || v_txt);
    END IF;
    v_txt := pg_temp.intenta(format('UPDATE public.recorridos SET completed_at = now() WHERE id = %s', v_ra));
    PERFORM pg_temp.como(NULL, NULL);
    IF v_txt <> 'PASA' OR (SELECT completed_at IS NOT NULL FROM recorridos WHERE id = v_ra) THEN
      v_fallas := v_fallas || ('R6 · A tocó completed_at sin completar: ' || v_txt);
    END IF;
    PERFORM pg_temp.como(v_a, v_suc);
    v_txt := pg_temp.intenta(format('UPDATE public.recorridos SET estado = ''completado'' WHERE id = %s', v_ra));
    IF v_txt <> 'PASA' THEN
      v_fallas := v_fallas || ('R6 · A no pudo completar su ruta: ' || v_txt);
    END IF;
    v_txt := pg_temp.intenta(format('UPDATE public.recorridos SET estado = ''en_curso'' WHERE id = %s', v_ra));
    IF left(v_txt, 5) <> '42501' THEN
      v_fallas := v_fallas || ('R6 · A reabrió su ruta completada: ' || v_txt);
    END IF;
    PERFORM pg_temp.como(NULL, NULL);
    v_txt := pg_temp.intenta(format('UPDATE public.recorridos SET estado = ''cancelado'' WHERE id = %s', v_ra));
    IF v_txt <> 'PASA' THEN
      v_fallas := v_fallas || ('R6 · el servidor no pudo cancelar la ruta: ' || v_txt);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('R6 · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------- R7 ---
  BEGIN
    v_ra := pg_temp.ruta(v_adm, v_suc, v_a, ARRAY[v_p1, v_p2], F1);
    PERFORM pg_temp.no_entrega(v_a, v_suc, v_p1);
    PERFORM pg_temp.como(v_adm, v_suc);
    v_txt := pg_temp.v(format('SELECT public.quitar_pedido_de_recorridos_activos(%s)::text', v_p1));
    PERFORM pg_temp.como(NULL, NULL);
    IF (v_txt::jsonb->>'paradas_eliminadas') <> '1' OR pg_temp.parada(v_ra, v_p1) <> '-'
       OR pg_temp.hist(v_p1) <> 1 THEN
      v_fallas := v_fallas || format('R7 · quitar: %s, parada %s, historial %s (esperado 1, -, 1)',
                                     v_txt, pg_temp.parada(v_ra, v_p1), pg_temp.hist(v_p1));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('R7 · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------ R10 ---
  BEGIN
    v_ra := pg_temp.ruta(v_adm, v_suc, v_a, ARRAY[v_p1, v_p2], F1);
    PERFORM pg_temp.no_entrega(v_a, v_suc, v_p1);
    UPDATE pedidos SET estado = 'entregado', fecha_entrega = now(), transportista_id = v_a WHERE id = v_p1;
    IF pg_temp.parada(v_ra, v_p1) <> 'entregado' OR pg_temp.hist(v_p1) <> 1
       OR (SELECT pedidos_entregados FROM recorridos WHERE id = v_ra) <> 1 THEN
      v_fallas := v_fallas || format('R10 · entrega sin re-rutear: parada %s, historial %s (esperado entregado, 1)',
                                     pg_temp.parada(v_ra, v_p1), pg_temp.hist(v_p1));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('R10 · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------ R11 ---
  BEGIN
    v_ra := pg_temp.ruta(v_adm, v_suc, v_a, ARRAY[v_p1, v_p2], F1);
    UPDATE pedidos SET estado = 'entregado', fecha_entrega = now() WHERE id = v_p2;
    IF pg_temp.parada(v_ra, v_p2) <> 'entregado' THEN
      v_fallas := v_fallas || ('R11 · la entrega no se marcó: ' || pg_temp.parada(v_ra, v_p2));
    END IF;
    UPDATE pedidos SET estado = 'asignado', fecha_entrega = NULL WHERE id = v_p2;
    SELECT format('%s/%s', rp.estado_entrega, rp.hora_entrega IS NULL) INTO v_txt
      FROM recorrido_pedidos rp WHERE rp.recorrido_id = v_ra AND rp.pedido_id = v_p2;
    IF v_txt IS DISTINCT FROM 'pendiente/t'
       OR (SELECT pedidos_entregados FROM recorridos WHERE id = v_ra) <> 0 THEN
      v_fallas := v_fallas || format('R11 · tras revertir: %s (esperado pendiente/t, 0 entregados)', v_txt);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('R11 · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------- R8 ---
  SELECT count(*) INTO v_n
    FROM recorridos r CROSS JOIN LATERAL public._recorrido_contadores(r.id) c
   WHERE r.total_pedidos IS DISTINCT FROM c.total_pedidos
      OR COALESCE(r.total_facturado, 0) IS DISTINCT FROM c.total_facturado
      OR r.pedidos_entregados IS DISTINCT FROM c.pedidos_entregados
      OR COALESCE(r.total_cobrado, 0) IS DISTINCT FROM c.total_cobrado;
  IF v_n > 0 THEN
    v_fallas := v_fallas || format('R8 · %s rutas con contadores distintos de _recorrido_contadores', v_n);
  END IF;

  -- ------------------------------------------------------------------- R9 ---
  BEGIN
    IF v_pxt IS NULL THEN
      v_fallas := v_fallas || format('R9 · no hay preventista con el extra transportista en %s', v_suc);
    ELSE
      PERFORM pg_temp.como(v_pxt, v_suc);
      v_txt := pg_temp.v('SELECT public.es_transportista()::text');
      IF v_txt IS DISTINCT FROM 'true' THEN
        v_fallas := v_fallas || ('R9 · es_transportista() del preventista con el extra en su sucursal: ' || v_txt);
      END IF;
      IF v_otra IS NOT NULL THEN
        PERFORM pg_temp.como(v_pxt, v_otra);
        v_txt := pg_temp.v('SELECT public.es_transportista()::text');
        IF v_txt IS DISTINCT FROM 'false' THEN
          v_fallas := v_fallas || ('R9 · es_transportista() en una sucursal sin el extra: ' || v_txt);
        END IF;
      ELSE
        v_notas := v_notas || 'R9 · el preventista con el extra no tiene otra sucursal: sólo se probó el sí'::text;
      END IF;
      PERFORM pg_temp.como(NULL, NULL);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('R9 · error inesperado: ' || SQLERRM);
  END;

  -- -------------------------------------------------------------------- K ---
  IF to_regprocedure('public.actualizar_orden_entrega_batch(jsonb)') IS NOT NULL
     OR to_regprocedure('public.limpiar_orden_entrega(uuid)') IS NOT NULL THEN
    v_fallas := v_fallas || 'K · siguen las funciones sin uso'::text;
  END IF;
  SELECT string_agg(conname || '=' || confdeltype::text, ',') INTO v_txt
    FROM pg_constraint
   WHERE conname IN ('recorridos_transportista_id_fkey', 'rendiciones_transportista_id_fkey');
  IF v_txt IS NULL OR v_txt ~ '=[^r]' OR (SELECT count(*) FROM pg_constraint
         WHERE conname IN ('recorridos_transportista_id_fkey', 'rendiciones_transportista_id_fkey')) <> 2 THEN
    v_fallas := v_fallas || ('K · FKs a perfiles: ' || COALESCE(v_txt, '(ninguna)'));
  END IF;
  IF (SELECT count(*) FROM pg_constraint
       WHERE conname IN ('recorridos_estado_valido', 'recorrido_pedidos_estado_entrega_valido')) <> 2 THEN
    v_fallas := v_fallas || 'K · faltan los CHECK de estado'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.recorridos'::regclass
                    AND tgname = 'trg_recorridos_estado' AND tgenabled = 'O') THEN
    v_fallas := v_fallas || 'K · trg_recorridos_estado no está enganchado'::text;
  END IF;
  IF has_function_privilege('authenticated', 'public._recorrido_contadores(bigint)', 'EXECUTE')
     OR has_function_privilege('anon', 'public._recorrido_contadores(bigint)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._no_entregas_al_historial(bigint[])', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.recorridos_estado_transicion()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.recorridos_estado_transicion()', 'EXECUTE') THEN
    v_fallas := v_fallas || 'K · una función nueva es ejecutable por anon o authenticated'::text;
  END IF;
  IF pg_get_functiondef('public.aplicar_orden_ruta(uuid,jsonb,numeric,integer,jsonb,date)'::regprocedure) ~* 'CURRENT_DATE' THEN
    v_fallas := v_fallas || 'K · aplicar_orden_ruta sigue usando CURRENT_DATE'::text;
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
