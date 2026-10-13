-- Ensayo de #1113: una compra con notas de crédito no se cancela, y la nota no
-- se despega, no se borra ni se reescribe, por ningún camino.
--
-- Antes de la migración, un admin por REST (o una función DEFINER, o el CASCADE
-- del DELETE de la compra) podía cancelar una compra con notas, reabrir una
-- cancelada, borrar la nota o sus renglones, moverla de compra o reescribirle
-- fecha e importes. La migración pone triggers BEFORE en compras,
-- notas_credito y nota_credito_items, y cierra la escritura REST de las dos
-- tablas de notas.
--
-- Corre contra prod SIN dejar rastro: un único DO; todo pasa dentro de un
-- bloque que termina SIEMPRE en una excepción (atrapada si salió bien), así que
-- productos, compras, lotes y notas se deshacen. Además cada caso corre en su
-- propio sub-bloque que se revierte al terminar: los casos no se pisan.
--
-- Simula PostgREST como test-permisos-definer-sin-rol.sql: `SET LOCAL ROLE
-- authenticated`, el `sub` de un admin real en request.jwt.claims y la sucursal
-- en x-sucursal-id. Los casos "como postgres" prueban que el invariante no
-- depende del rol ni de los grants (lo que vería una DEFINER futura o el
-- CASCADE). No usa ALTER TABLE … DISABLE TRIGGER (toma AccessExclusive sobre
-- compras en prod).
--
-- Bolsa distinta de 0 (lección de la 316): stock 150, compra de 100 con un lote
-- de 100, bolsa 50. La compra C tiene una nota por 10 (stock 140, lote 90).
--
-- Casos REST (admin):
--   A  · cancelar C                         → el trigger lo rechaza; C, lote y stock iguales
--   B  · DELETE de la nota N                → 42501
--   C  · DELETE de la compra C              → el trigger de notas aborta el CASCADE
--   D  · mover N a otra compra              → 42501
--   E  · INSERT de una nota sobre una cancelada → 42501
--   K  · PATCH fecha / iva+ii de N          → 42501, N igual
--   L  · DELETE / PATCH de los renglones    → 42501; y una nota por 91 choca con el tope
--   M  · INSERT de un renglón               → 42501
--   R  · reabrir una compra cancelada       → el trigger lo rechaza
-- Casos como postgres: F (cancelar C), B' (borrar N), C' (borrar C), D' (mover
--   N), E' (nota sobre cancelada), L' (renglones), R' (reabrir).
-- Regresiones (iguales antes y después):
--   G · anular_compra_atomica sobre una compra sin notas
--   H · cambiar_proveedor_compra sobre una compra sin notas
--   I · registrar_nota_credito y registrar_nota_credito_lote como admin REST
--   J · UPDATE compras SET notas = notas / estado = estado, y
--       actualizar_compra_items con los mismos ítems, sobre C (que tiene nota)
--   S · el admin por REST sigue leyendo las notas y sus renglones
--
-- Veredicto: NOTICE 'ENSAYO OK (todo revertido)', o el error 'ENSAYO FALLÓ …'
-- con la lista de fallas. En los dos casos no queda nada escrito.
--
--   psql "$DATABASE_URL" -f scripts/test-compra-nc-rest-1113.sql

DO $ensayo$
DECLARE
  v_admin   uuid;
  v_suc     bigint;
  v_hoy     date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  -- C: compra con nota
  v_pC      bigint;  v_C  bigint;  v_lC bigint;  v_nc bigint;  v_nci bigint;
  -- O: otra compra recibida, sin notas
  v_pO      bigint;  v_O  bigint;  v_lO bigint;
  -- R: compra anulada con la RPC, sin notas
  v_pR      bigint;  v_R  bigint;
  -- G y H: compras sin notas para las regresiones
  v_pG      bigint;  v_G  bigint;  v_lG bigint;
  v_pH      bigint;  v_H  bigint;  v_lH bigint;

  v_prisC   jsonb := '{"stock":140,"lotes":90,"bolsa":50}';
  v_notaN   jsonb;
  v_res     jsonb;
  v_err     text;
  v_err2    text;
  v_n       bigint;
  v_n2      bigint;
  v_cab     record;
  v_items   jsonb;
  v_hist    record;
  v_fallas  text[] := '{}';
BEGIN
 BEGIN
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita un admin activo con una sucursal activa';
  END IF;

  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);

  -- ---------------------------------------------------------------- helpers -
  -- Corre una sentencia como PostgREST (authenticated); NULL si pasó, o
  -- 'SQLSTATE mensaje'. Si falla, el sub-bloque deshace también el SET ROLE.
  CREATE FUNCTION pg_temp.rest(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    RETURN NULL;
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE || ' ' || SQLERRM;
  END $f$;
  -- Una RPC como PostgREST: su jsonb, o {"exception": …}.
  CREATE FUNCTION pg_temp.rest_json(p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE v jsonb;
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN v;
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('exception', SQLSTATE || ' ' || SQLERRM);
  END $f$;
  -- Un conteo como PostgREST (-1 si falla).
  CREATE FUNCTION pg_temp.rest_int(p_sql text) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v bigint;
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN v;
  EXCEPTION WHEN OTHERS THEN
    RETURN -1;
  END $f$;
  -- La misma sentencia como postgres (lo que ve una DEFINER o un CASCADE).
  CREATE FUNCTION pg_temp.pg(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  BEGIN
    EXECUTE p_sql;
    RETURN NULL;
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE || ' ' || SQLERRM;
  END $f$;
  -- stock / suma de lotes / bolsa del producto
  CREATE FUNCTION pg_temp.foto(p_prod bigint) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('stock', pr.stock, 'lotes', l.r, 'bolsa', pr.stock - l.r)
      FROM public.productos pr
      JOIN LATERAL (SELECT COALESCE(SUM(cantidad_restante), 0)::int AS r
                      FROM public.producto_lotes WHERE producto_id = pr.id) l ON true
     WHERE pr.id = p_prod;
  $f$;
  CREATE FUNCTION pg_temp.producto(p_suc bigint, p_nombre text) RETURNS bigint LANGUAGE sql AS $f$
    INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
    VALUES (p_nombre, 100, 150, 10, p_suc) RETURNING id;
  $f$;
  CREATE FUNCTION pg_temp.compra(p_prod bigint, p_suc bigint) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v_id bigint;
  BEGIN
    INSERT INTO public.compras (sucursal_id, fecha_compra, subtotal, iva, total, estado)
    VALUES (p_suc, CURRENT_DATE, 1000, 210, 1210, 'recibida') RETURNING id INTO v_id;
    INSERT INTO public.compra_items (compra_id, producto_id, cantidad, costo_unitario, subtotal, sucursal_id)
    VALUES (v_id, p_prod, 100, 10, 1000, p_suc);
    RETURN v_id;
  END $f$;
  CREATE FUNCTION pg_temp.lote(p_prod bigint, p_suc bigint, p_compra bigint, p_vence date) RETURNS bigint
  LANGUAGE sql AS $f$
    INSERT INTO public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad,
                                       cantidad_restante, compra_id, origen)
    VALUES (p_prod, p_suc, p_vence, 100, 100, p_compra, 'compra') RETURNING id;
  $f$;
  CREATE FUNCTION pg_temp.estado(p_compra bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT estado::text FROM public.compras WHERE id = p_compra;
  $f$;
  CREATE FUNCTION pg_temp.nota(p_nota bigint) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT to_jsonb(nc) FROM public.notas_credito nc WHERE nc.id = p_nota;
  $f$;
  CREATE FUNCTION pg_temp.acreditado(p_nota bigint) RETURNS bigint LANGUAGE sql AS $f$
    SELECT COALESCE(SUM(cantidad), 0) FROM public.nota_credito_items WHERE nota_credito_id = p_nota;
  $f$;

  -- ---------------------------------------------------------------- fixture -
  v_pC := pg_temp.producto(v_suc, 'ZZ ensayo 1113 C');
  v_C  := pg_temp.compra(v_pC, v_suc);
  v_lC := pg_temp.lote(v_pC, v_suc, v_C, v_hoy + 60);
  v_res := public.registrar_nota_credito(v_C, 'ENSAYO-1113', 'ensayo 1113', 0, 0, 0, NULL,
             jsonb_build_array(jsonb_build_object('producto_id', v_pC, 'cantidad', 10,
                                                  'costo_unitario', 10, 'subtotal', 100)), NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'fixture · la nota de C no se registró: %', v_res;
  END IF;
  v_nc := (v_res->>'nota_credito_id')::bigint;
  SELECT id INTO v_nci FROM nota_credito_items WHERE nota_credito_id = v_nc;
  IF pg_temp.foto(v_pC) <> v_prisC THEN
    RAISE EXCEPTION 'fixture · C quedó %, esperaba %', pg_temp.foto(v_pC), v_prisC;
  END IF;
  v_notaN := pg_temp.nota(v_nc);

  v_pO := pg_temp.producto(v_suc, 'ZZ ensayo 1113 O');
  v_O  := pg_temp.compra(v_pO, v_suc);
  v_lO := pg_temp.lote(v_pO, v_suc, v_O, v_hoy + 60);

  v_pR := pg_temp.producto(v_suc, 'ZZ ensayo 1113 R');
  v_R  := pg_temp.compra(v_pR, v_suc);
  PERFORM pg_temp.lote(v_pR, v_suc, v_R, v_hoy + 60);
  v_res := public.anular_compra_atomica(v_R, v_admin);
  IF NOT COALESCE((v_res->>'success')::boolean, false) OR pg_temp.estado(v_R) <> 'cancelada' THEN
    RAISE EXCEPTION 'fixture · R no se anuló: %', v_res;
  END IF;

  v_pG := pg_temp.producto(v_suc, 'ZZ ensayo 1113 G');
  v_G  := pg_temp.compra(v_pG, v_suc);
  v_lG := pg_temp.lote(v_pG, v_suc, v_G, v_hoy + 60);

  v_pH := pg_temp.producto(v_suc, 'ZZ ensayo 1113 H');
  v_H  := pg_temp.compra(v_pH, v_suc);
  v_lH := pg_temp.lote(v_pH, v_suc, v_H, v_hoy + 60);

  -- ======================================================= casos REST =======
  -- A · cancelar C por PATCH
  BEGIN
    v_err := pg_temp.rest(format('UPDATE public.compras SET estado = %L WHERE id = %s', 'cancelada', v_C));
    IF v_err IS NULL OR v_err NOT ILIKE '%nota(s) de crédito%' THEN
      v_fallas := v_fallas || format('A · cancelar por REST una compra con notas tenía que rechazarse; error %s', COALESCE(v_err, '(ninguno)'));
    END IF;
    IF pg_temp.estado(v_C) <> 'recibida' OR pg_temp.foto(v_pC) <> v_prisC
       OR NOT EXISTS (SELECT 1 FROM producto_lotes WHERE id = v_lC AND cantidad_restante = 90) THEN
      v_fallas := v_fallas || format('A · C tenía que seguir recibida con %s y su lote en 90; quedó %s, %s',
                                     v_prisC, pg_temp.estado(v_C), pg_temp.foto(v_pC));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A · error inesperado: ' || SQLERRM);
  END;

  -- B · DELETE de la nota
  BEGIN
    v_err := pg_temp.rest(format('DELETE FROM public.notas_credito WHERE id = %s', v_nc));
    IF v_err IS NULL OR v_err NOT LIKE '42501%' THEN
      v_fallas := v_fallas || format('B · borrar la nota por REST tenía que dar 42501; error %s', COALESCE(v_err, '(ninguno)'));
    END IF;
    IF pg_temp.nota(v_nc) IS DISTINCT FROM v_notaN OR pg_temp.acreditado(v_nc) <> 10 THEN
      v_fallas := v_fallas || 'B · la nota (o sus renglones) desapareció'::text;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('B · error inesperado: ' || SQLERRM);
  END;

  -- C · DELETE de la compra (CASCADE a la nota)
  BEGIN
    v_err := pg_temp.rest(format('DELETE FROM public.compras WHERE id = %s', v_C));
    IF v_err IS NULL OR v_err NOT ILIKE '%no se borra%' THEN
      v_fallas := v_fallas || format('C · borrar por REST una compra con notas tenía que rechazarse; error %s', COALESCE(v_err, '(ninguno)'));
    END IF;
    IF pg_temp.estado(v_C) IS DISTINCT FROM 'recibida'
       OR NOT EXISTS (SELECT 1 FROM compra_items WHERE compra_id = v_C)
       OR NOT EXISTS (SELECT 1 FROM producto_lotes WHERE id = v_lC)
       OR pg_temp.nota(v_nc) IS DISTINCT FROM v_notaN THEN
      v_fallas := v_fallas || 'C · la compra, sus ítems, su lote o la nota no sobrevivieron al DELETE'::text;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('C · error inesperado: ' || SQLERRM);
  END;

  -- D · mover la nota a otra compra
  BEGIN
    v_err := pg_temp.rest(format('UPDATE public.notas_credito SET compra_id = %s WHERE id = %s', v_O, v_nc));
    IF v_err IS NULL OR v_err NOT LIKE '42501%' THEN
      v_fallas := v_fallas || format('D · mover la nota por REST tenía que dar 42501; error %s', COALESCE(v_err, '(ninguno)'));
    END IF;
    IF pg_temp.nota(v_nc) IS DISTINCT FROM v_notaN THEN
      v_fallas := v_fallas || format('D · la nota cambió: %s', pg_temp.nota(v_nc));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('D · error inesperado: ' || SQLERRM);
  END;

  -- E · INSERT de una nota sobre una compra cancelada
  BEGIN
    v_err := pg_temp.rest(format(
      'INSERT INTO public.notas_credito (compra_id, sucursal_id, subtotal, iva, total, tipo, motivo) VALUES (%s, %s, 100, 21, 121, %L, %L)',
      v_R, v_suc, 'ajuste', 'ensayo 1113 E'));
    IF v_err IS NULL OR v_err NOT LIKE '42501%' THEN
      v_fallas := v_fallas || format('E · una nota por REST sobre una compra cancelada tenía que dar 42501; error %s', COALESCE(v_err, '(ninguno)'));
    END IF;
    SELECT count(*) INTO v_n FROM notas_credito WHERE compra_id = v_R;
    IF v_n <> 0 THEN
      v_fallas := v_fallas || format('E · la compra cancelada quedó con %s nota(s)', v_n);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('E · error inesperado: ' || SQLERRM);
  END;

  -- K · reescribir fecha e importes de la nota
  BEGIN
    v_err  := pg_temp.rest(format('UPDATE public.notas_credito SET fecha = %L WHERE id = %s', '2000-01-01', v_nc));
    v_err2 := pg_temp.rest(format('UPDATE public.notas_credito SET iva = 0, impuestos_internos = 0 WHERE id = %s', v_nc));
    IF v_err IS NULL OR v_err NOT LIKE '42501%' OR v_err2 IS NULL OR v_err2 NOT LIKE '42501%' THEN
      v_fallas := v_fallas || format('K · reescribir fecha / importes de la nota por REST tenía que dar 42501; errores %s / %s',
                                     COALESCE(v_err, '(ninguno)'), COALESCE(v_err2, '(ninguno)'));
    END IF;
    IF pg_temp.nota(v_nc) IS DISTINCT FROM v_notaN THEN
      v_fallas := v_fallas || format('K · la nota cambió: %s', pg_temp.nota(v_nc));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('K · error inesperado: ' || SQLERRM);
  END;

  -- L · borrar / achicar los renglones reabre el tope
  BEGIN
    v_err  := pg_temp.rest(format('UPDATE public.nota_credito_items SET cantidad = 1 WHERE id = %s', v_nci));
    v_err2 := pg_temp.rest(format('DELETE FROM public.nota_credito_items WHERE nota_credito_id = %s', v_nc));
    IF v_err IS NULL OR v_err NOT LIKE '42501%' OR v_err2 IS NULL OR v_err2 NOT LIKE '42501%' THEN
      v_fallas := v_fallas || format('L · editar / borrar renglones por REST tenía que dar 42501; errores %s / %s',
                                     COALESCE(v_err, '(ninguno)'), COALESCE(v_err2, '(ninguno)'));
    END IF;
    IF pg_temp.acreditado(v_nc) <> 10 THEN
      v_fallas := v_fallas || format('L · la nota quedó acreditando %s en vez de 10', pg_temp.acreditado(v_nc));
    END IF;
    -- compradas 100, acreditadas 10: 91 no entran
    v_res := public.registrar_nota_credito(v_C, 'ENSAYO-1113-L', 'ensayo 1113 L', 0, 0, 0, NULL,
               jsonb_build_array(jsonb_build_object('producto_id', v_pC, 'cantidad', 91,
                                                    'costo_unitario', 10, 'subtotal', 910)), NULL);
    IF COALESCE((v_res->>'success')::boolean, false)
       OR COALESCE(v_res->>'error', '') NOT ILIKE 'No se puede acreditar%' THEN
      v_fallas := v_fallas || format('L · una segunda nota por 91 tenía que chocar con el tope; devolvió %s', v_res);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('L · error inesperado: ' || SQLERRM);
  END;

  -- M · INSERT de un renglón
  BEGIN
    v_err := pg_temp.rest(format(
      'INSERT INTO public.nota_credito_items (nota_credito_id, producto_id, cantidad, costo_unitario, subtotal, sucursal_id) VALUES (%s, %s, 5, 10, 50, %s)',
      v_nc, v_pC, v_suc));
    IF v_err IS NULL OR v_err NOT LIKE '42501%' THEN
      v_fallas := v_fallas || format('M · insertar un renglón por REST tenía que dar 42501; error %s', COALESCE(v_err, '(ninguno)'));
    END IF;
    IF pg_temp.acreditado(v_nc) <> 10 THEN
      v_fallas := v_fallas || format('M · la nota quedó acreditando %s', pg_temp.acreditado(v_nc));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('M · error inesperado: ' || SQLERRM);
  END;

  -- R · reabrir una compra cancelada
  BEGIN
    v_err := pg_temp.rest(format('UPDATE public.compras SET estado = %L WHERE id = %s', 'recibida', v_R));
    IF v_err IS NULL OR v_err NOT ILIKE '%no se reabre%' THEN
      v_fallas := v_fallas || format('R · reabrir por REST una compra cancelada tenía que rechazarse; error %s', COALESCE(v_err, '(ninguno)'));
    END IF;
    IF pg_temp.estado(v_R) <> 'cancelada' THEN
      v_fallas := v_fallas || format('R · la compra quedó %s', pg_temp.estado(v_R));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('R · error inesperado: ' || SQLERRM);
  END;

  -- =================================================== casos como postgres ==
  -- F · cancelar C
  BEGIN
    v_err := pg_temp.pg(format('UPDATE public.compras SET estado = %L WHERE id = %s', 'cancelada', v_C));
    IF v_err IS NULL OR v_err NOT ILIKE '%nota(s) de crédito%' OR pg_temp.estado(v_C) <> 'recibida'
       OR NOT EXISTS (SELECT 1 FROM producto_lotes WHERE id = v_lC) THEN
      v_fallas := v_fallas || format('F · cancelar como postgres una compra con notas tenía que rechazarse; error %s, estado %s',
                                     COALESCE(v_err, '(ninguno)'), pg_temp.estado(v_C));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('F · error inesperado: ' || SQLERRM);
  END;

  -- B' · borrar N
  BEGIN
    v_err := pg_temp.pg(format('DELETE FROM public.notas_credito WHERE id = %s', v_nc));
    IF v_err IS NULL OR v_err NOT ILIKE '%no se borra%' OR pg_temp.nota(v_nc) IS NULL THEN
      v_fallas := v_fallas || format('B'' · borrar la nota como postgres tenía que rechazarse; error %s', COALESCE(v_err, '(ninguno)'));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('B'' · error inesperado: ' || SQLERRM);
  END;

  -- C' · borrar C (el CASCADE corre como dueño)
  BEGIN
    v_err := pg_temp.pg(format('DELETE FROM public.compras WHERE id = %s', v_C));
    IF v_err IS NULL OR v_err NOT ILIKE '%no se borra%' OR pg_temp.estado(v_C) IS NULL
       OR pg_temp.nota(v_nc) IS NULL THEN
      v_fallas := v_fallas || format('C'' · borrar como postgres una compra con notas tenía que rechazarse; error %s', COALESCE(v_err, '(ninguno)'));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('C'' · error inesperado: ' || SQLERRM);
  END;

  -- D' · mover N a O
  BEGIN
    v_err := pg_temp.pg(format('UPDATE public.notas_credito SET compra_id = %s WHERE id = %s', v_O, v_nc));
    IF v_err IS NULL OR v_err NOT ILIKE '%no se pasa a otra compra%'
       OR pg_temp.nota(v_nc) IS DISTINCT FROM v_notaN THEN
      v_fallas := v_fallas || format('D'' · mover la nota como postgres tenía que rechazarse; error %s', COALESCE(v_err, '(ninguno)'));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('D'' · error inesperado: ' || SQLERRM);
  END;

  -- E' · nota sobre la compra cancelada R
  BEGIN
    v_err := pg_temp.pg(format(
      'INSERT INTO public.notas_credito (compra_id, sucursal_id, subtotal, iva, total, tipo, motivo) VALUES (%s, %s, 100, 21, 121, %L, %L)',
      v_R, v_suc, 'ajuste', 'ensayo 1113 E'''));
    SELECT count(*) INTO v_n FROM notas_credito WHERE compra_id = v_R;
    IF v_err IS NULL OR v_err NOT ILIKE '%cancelada%' OR v_n <> 0 THEN
      v_fallas := v_fallas || format('E'' · una nota como postgres sobre una compra cancelada tenía que rechazarse; error %s, notas %s',
                                     COALESCE(v_err, '(ninguno)'), v_n);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('E'' · error inesperado: ' || SQLERRM);
  END;

  -- L' · renglones
  BEGIN
    v_err  := pg_temp.pg(format('UPDATE public.nota_credito_items SET cantidad = 1 WHERE id = %s', v_nci));
    v_err2 := pg_temp.pg(format('DELETE FROM public.nota_credito_items WHERE id = %s', v_nci));
    IF v_err IS NULL OR v_err NOT ILIKE '%no se edita ni se borra%'
       OR v_err2 IS NULL OR v_err2 NOT ILIKE '%no se edita ni se borra%'
       OR pg_temp.acreditado(v_nc) <> 10 THEN
      v_fallas := v_fallas || format('L'' · editar / borrar renglones como postgres tenía que rechazarse; errores %s / %s',
                                     COALESCE(v_err, '(ninguno)'), COALESCE(v_err2, '(ninguno)'));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('L'' · error inesperado: ' || SQLERRM);
  END;

  -- R' · reabrir R
  BEGIN
    v_err := pg_temp.pg(format('UPDATE public.compras SET estado = %L WHERE id = %s', 'recibida', v_R));
    IF v_err IS NULL OR v_err NOT ILIKE '%no se reabre%' OR pg_temp.estado(v_R) <> 'cancelada' THEN
      v_fallas := v_fallas || format('R'' · reabrir como postgres tenía que rechazarse; error %s', COALESCE(v_err, '(ninguno)'));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('R'' · error inesperado: ' || SQLERRM);
  END;

  -- ========================================================= regresiones ====
  -- G · anular una compra sin notas
  BEGIN
    v_res := public.anular_compra_atomica(v_G, v_admin);
    SELECT origen INTO v_hist FROM stock_historico WHERE producto_id = v_pG ORDER BY id DESC LIMIT 1;
    IF NOT COALESCE((v_res->>'success')::boolean, false)
       OR pg_temp.estado(v_G) <> 'cancelada'
       OR EXISTS (SELECT 1 FROM producto_lotes WHERE id = v_lG)
       OR pg_temp.foto(v_pG) <> '{"stock":50,"lotes":0,"bolsa":50}'::jsonb
       OR v_hist.origen IS DISTINCT FROM 'compra_anulada' THEN
      v_fallas := v_fallas || format('G · anular una compra sin notas: %s, estado %s, foto %s, ledger %s',
                                     v_res, pg_temp.estado(v_G), pg_temp.foto(v_pG), v_hist.origen);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('G · error inesperado: ' || SQLERRM);
  END;

  -- H · cambiar el proveedor de una compra sin notas
  BEGIN
    v_res := public.cambiar_proveedor_compra(v_H, v_admin, NULL, 'ZZ proveedor ensayo 1113', 'ensayo 1113');
    v_n := (v_res->>'nueva_compra_id')::bigint;
    IF NOT COALESCE((v_res->>'success')::boolean, false)
       OR pg_temp.estado(v_H) <> 'cancelada'
       OR pg_temp.estado(v_n) IS DISTINCT FROM 'recibida'
       OR NOT EXISTS (SELECT 1 FROM producto_lotes
                       WHERE id = v_lH AND compra_id = v_n AND cantidad_restante = 100)
       OR pg_temp.foto(v_pH) <> '{"stock":150,"lotes":100,"bolsa":50}'::jsonb THEN
      v_fallas := v_fallas || format('H · cambiar el proveedor: %s, vieja %s, nueva %s, foto %s',
                                     v_res, pg_temp.estado(v_H), pg_temp.estado(v_n), pg_temp.foto(v_pH));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('H · error inesperado: ' || SQLERRM);
  END;

  -- I · las dos puertas de nota, como admin REST, sobre una compra recibida
  BEGIN
    v_res := pg_temp.rest_json(format(
      'SELECT public.registrar_nota_credito(%s, %L, %L, 0, 0, 0, NULL, %L::jsonb, NULL)',
      v_O, 'ENSAYO-1113-I', 'ensayo 1113 I',
      jsonb_build_array(jsonb_build_object('producto_id', v_pO, 'cantidad', 10,
                                           'costo_unitario', 10, 'subtotal', 100))));
    IF NOT COALESCE((v_res->>'success')::boolean, false)
       OR pg_temp.foto(v_pO) <> '{"stock":140,"lotes":90,"bolsa":50}'::jsonb
       OR pg_temp.acreditado((v_res->>'nota_credito_id')::bigint) <> 10 THEN
      v_fallas := v_fallas || format('I · registrar_nota_credito por REST: %s, foto %s', v_res, pg_temp.foto(v_pO));
    END IF;
    v_res := pg_temp.rest_json(format(
      'SELECT public.registrar_nota_credito_lote(%s, 5, %L, %L)', v_lO, 'ENSAYO-1113-IL', 'ensayo 1113 I lote'));
    IF NOT COALESCE((v_res->>'ok')::boolean, false)
       OR pg_temp.foto(v_pO) <> '{"stock":135,"lotes":85,"bolsa":50}'::jsonb
       OR pg_temp.acreditado((v_res->>'nota_credito_id')::bigint) <> 5 THEN
      v_fallas := v_fallas || format('I · registrar_nota_credito_lote por REST: %s, foto %s', v_res, pg_temp.foto(v_pO));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('I · error inesperado: ' || SQLERRM);
  END;

  -- J · lo que no toca el estado sigue andando sobre una compra con nota
  BEGIN
    v_err  := pg_temp.rest(format('UPDATE public.compras SET notas = notas WHERE id = %s', v_C));
    v_err2 := pg_temp.rest(format('UPDATE public.compras SET estado = estado WHERE id = %s', v_C));
    IF v_err IS NOT NULL OR v_err2 IS NOT NULL THEN
      v_fallas := v_fallas || format('J · UPDATE notas = notas / estado = estado no tenía que fallar; errores %s / %s',
                                     COALESCE(v_err, '(ninguno)'), COALESCE(v_err2, '(ninguno)'));
    END IF;
    SELECT subtotal, iva, total INTO v_cab FROM compras WHERE id = v_C;
    SELECT jsonb_agg(jsonb_build_object(
             'producto_id', ci.producto_id, 'cantidad', ci.cantidad,
             'costo_unitario', ci.costo_unitario, 'subtotal', ci.subtotal,
             'bonificacion', COALESCE(ci.bonificacion, 0),
             'porcentaje_iva', COALESCE(ci.porcentaje_iva, 21),
             'condicion_iva', COALESCE(ci.condicion_iva, 'gravado'),
             'impuestos_internos', COALESCE(ci.impuestos_internos, 0)) ORDER BY ci.id)
      INTO v_items
      FROM compra_items ci WHERE ci.compra_id = v_C;
    v_res := public.actualizar_compra_items(v_C, v_items, v_cab.subtotal, v_cab.iva, v_cab.total, v_admin);
    IF NOT COALESCE((v_res->>'success')::boolean, false)
       OR pg_temp.estado(v_C) <> 'recibida'
       OR (SELECT row(subtotal, iva, total)::text FROM compras WHERE id = v_C)
          IS DISTINCT FROM row(v_cab.subtotal, v_cab.iva, v_cab.total)::text THEN
      v_fallas := v_fallas || format('J · actualizar_compra_items con los mismos ítems: %s, estado %s, cabecera antes %s después %s',
                                     v_res, pg_temp.estado(v_C), row(v_cab.subtotal, v_cab.iva, v_cab.total)::text,
                                     (SELECT row(subtotal, iva, total)::text FROM compras WHERE id = v_C));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('J · error inesperado: ' || SQLERRM);
  END;

  -- S · la lectura sigue viva sin la policy ALL
  BEGIN
    v_n  := pg_temp.rest_int('SELECT count(*) FROM public.notas_credito');
    v_n2 := pg_temp.rest_int('SELECT count(*) FROM public.nota_credito_items');
    IF v_n  IS DISTINCT FROM (SELECT count(*) FROM notas_credito      WHERE sucursal_id = v_suc)
       OR v_n2 IS DISTINCT FROM (SELECT count(*) FROM nota_credito_items WHERE sucursal_id = v_suc)
       OR v_n < 1 OR v_n2 < 1 THEN
      v_fallas := v_fallas || format('S · el admin por REST lee %s notas y %s renglones; como postgres hay %s y %s',
                                     v_n, v_n2,
                                     (SELECT count(*) FROM notas_credito      WHERE sucursal_id = v_suc),
                                     (SELECT count(*) FROM nota_credito_items WHERE sucursal_id = v_suc));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('S · error inesperado: ' || SQLERRM);
  END;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (% fallas, todo revertido):\n- %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE EXCEPTION 'ensayo-1113-ok' USING ERRCODE = 'ZZ0OK';
 EXCEPTION WHEN SQLSTATE 'ZZ0OK' THEN
  RAISE NOTICE 'ENSAYO OK (todo revertido)';
 END;
END
$ensayo$;
