-- Control negativo de la tarjeta 14 de #1378 (#1460). Se corre sobre la copia LOCAL de Docker con la migración de la
-- tarjeta aplicada. NUNCA contra prod ni contra una rama de Supabase compartida: es DDL sobre `public`.
--
-- Saca a la vez los pre-bloqueos de la migración, uno por función (y cambia el orden de los precios en masa): cada
-- variante de T14 llama a una sola de ellas contra la venta, así que no se pisan (por qué eso importa: "Controles
-- negativos" del README).
--   · (ajustar_stock_promocion_completo y sus variantes T14a y T14b ya no están: la función se borró, #1515 PRM-3.)
--   · trg_promo_factor_bloquea_contenedores queda deshabilitado: T14c y T14d vuelven a dar 40P01.
--   · eliminar_pedido_completo vuelve a recorrer las líneas sin bloquear antes: T14e y T14f.
--   · actualizar_pedido_items vuelve a tomar las promos en el orden del JSON: T14g y T14h.
--   · registrar_salvedad vuelve a tomar la promo de un regalo de otro modo recién al confirmar: T14j.
--   · actualizar_precios_masivo vuelve a actualizar en el orden del JSON: T14l y T14m (ver "Por qué cambió").
--     psql -f controles-negativos-t14.sql
-- Después: node run.mjs t14 --out <dir>, RESTAURAR y repetir `docker-local.mjs huella`: cero diferencias.
--
-- Por qué cambió (06/11, tarjeta 10 de #1477): la 467 (#1473, ADV-3) sacó de actualizar_precios_masivo el pre-bloqueo
-- del lote (el `PERFORM 1 FROM productos ... ORDER BY id FOR NO KEY UPDATE` de antes del bucle): ahora cada producto se
-- toma dentro del bucle, con espera acotada, y el bucle recorre los ids ordenados (`ORDER BY CASE WHEN ... ::numeric
-- END NULLS LAST, t.n`). La sexta fila del VALUES de antes ya no encontraba su patrón y el DO abortaba entero
-- ("el pre-bloqueo no aparece una sola vez"; es atómico: no mutaba nada, y las once variantes corrían sin mutación).
-- Ahora la mutación de esa función cambia el `ORDER BY` por id del bucle por `ORDER BY t.n` (el orden del JSON): el cruce vuelve.
-- Los otros cinco pre-bloqueos no cambiaron (la 470 y la 472 no los tocan).
--
-- Medido el 06/11 (base reconstruida hasta la 474, huella igual a prod, PC de 22 hilos), con la mutación puesta.
-- Correctas / 40P01 por variante (sobre 100 rondas, salvo donde se aclara):
--   T14a 100 correctas, 100 40P01 · T14c 100, 100 · T14e 100, 100 · T14f 100, 100 · T14g 100, 100 · T14h 100, 100 ·
--   T14j 100, 100. El 40P01 tiene su propia columna y no resta de las correctas: el veredicto de esas variantes es el
--   40P01 (con el pre-bloqueo puesto dan 0).
--   T14l 0 correctas, 83 40P01 (más 100 × P0001 «otra operación lo estaba usando y no se cambió»: la espera acotada de
--   los precios en masa se salta A en cada ronda).
--   Sin forzar (arrancan juntas) casi no cae, y con el pre-bloqueo puesto da 0: T14d 9 de 200, T14i 3 de 200, T14b 0 de
--   200, T14m 0 de 200. T14k, T14n, T14o y T14p (C4) dan 0 con y sin la mutación: no dependen de ninguno de estos
--   pre-bloqueos.

-- ===== MUTAR =====
CREATE TABLE IF NOT EXISTS conc.mut_orig (firma text PRIMARY KEY, def text NOT NULL);
INSERT INTO conc.mut_orig SELECT p.oid::regprocedure::text, pg_get_functiondef(p.oid)
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
   AND p.proname IN ('eliminar_pedido_completo', 'actualizar_pedido_items', 'actualizar_precios_masivo',
                     'registrar_salvedad')
ON CONFLICT DO NOTHING;
DO $m$
DECLARE
  d text; f text; pat text;
BEGIN
  IF to_regprocedure('public.promo_factor_bloquea_contenedores()') IS NULL THEN
    RAISE EXCEPTION 'falta la migración de la tarjeta 14';
  END IF;
  -- Cada pre-bloqueo es un PERFORM 1 ... FOR [NO KEY] UPDATE; que empieza en la línea que sigue a su comentario
  -- #1460 (Cn). Se lo cambia por un PERFORM que no toma nada.
  FOR f, pat IN SELECT v.f, v.pat FROM (VALUES
      ('actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)',
       E'  PERFORM 1\n     FROM promociones\n    WHERE sucursal_id = v_sucursal\n      AND id IN (SELECT pi.promocion_id FROM pedido_items pi\n                  WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal\n                    AND pi.promocion_id IS NOT NULL\n                 UNION\n                 SELECT (e->>''promocion_id'')::bigint FROM jsonb_array_elements(v_items) e\n                  WHERE e->>''promocion_id'' IS NOT NULL)\n    ORDER BY id\n      FOR UPDATE;\n'),
      ('registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)',
       E'  PERFORM 1\n     FROM promociones\n    WHERE sucursal_id = v_sucursal\n      AND id IN (SELECT pi.promocion_id FROM pedido_items pi\n                  WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal\n                    AND pi.promocion_id IS NOT NULL)\n    ORDER BY id\n      FOR UPDATE;\n')
    ) v(f, pat)
  LOOP
    SELECT def INTO d FROM conc.mut_orig WHERE firma = f;
    IF (length(d) - length(replace(d, pat, ''))) / length(pat) <> 1 THEN
      RAISE EXCEPTION '%: el pre-bloqueo no aparece una sola vez', f;
    END IF;
    EXECUTE replace(d, pat, E'  PERFORM 1; -- MUTADO\n');
  END LOOP;
  -- eliminar_pedido_completo tiene dos (productos y promos): se cortan los dos, desde el comentario hasta el bucle.
  SELECT def INTO d FROM conc.mut_orig WHERE firma = 'eliminar_pedido_completo(bigint,uuid,text,boolean)';
  IF position('-- #1460 (C5)' IN d) = 0 THEN
    RAISE EXCEPTION 'eliminar_pedido_completo: no está el pre-bloqueo de C5';
  END IF;
  EXECUTE substr(d, 1, position('-- #1460 (C5)' IN d) - 1) || E'-- MUTADO\n    FOR v_item IN'
          || substr(d, position('FOR v_item IN' IN d) + length('FOR v_item IN'));
  -- actualizar_precios_masivo: desde la 467 no hay pre-bloqueo del lote; el orden por id está en el ORDER BY del bucle.
  -- Se lo cambia por el orden del JSON (t.n).
  SELECT def INTO d FROM conc.mut_orig WHERE firma = 'actualizar_precios_masivo(jsonb,jsonb)';
  f := E'     ORDER BY CASE WHEN btrim(t.e->>''producto_id'') ~ ''^[0-9]{1,18}$''
                   THEN btrim(t.e->>''producto_id'')::numeric END NULLS LAST,
              t.n';
  IF (length(d) - length(replace(d, f, ''))) / length(f) <> 1 THEN
    RAISE EXCEPTION 'actualizar_precios_masivo: el ORDER BY por id del bucle no aparece una sola vez';
  END IF;
  EXECUTE replace(d, f, E'     ORDER BY t.n /* MUTADO */');
  ALTER TABLE public.promociones DISABLE TRIGGER trg_promo_factor_bloquea_contenedores;
END
$m$;

-- ===== RESTAURAR (correr aparte, después de las variantes) =====
-- ALTER TABLE public.promociones ENABLE TRIGGER trg_promo_factor_bloquea_contenedores;
-- DO $r$ DECLARE d text; BEGIN FOR d IN SELECT def FROM conc.mut_orig LOOP EXECUTE d; END LOOP; END $r$; TRUNCATE conc.mut_orig;
