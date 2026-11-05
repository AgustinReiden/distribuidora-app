-- Control negativo de la tarjeta 14 de #1378 (#1460). Se corre sobre la copia LOCAL de Docker con la migración de la
-- tarjeta aplicada. NUNCA contra prod ni contra una rama de Supabase compartida: es DDL sobre `public`.
--
-- Saca los seis pre-bloqueos de la migración a la vez: cada uno está en una función distinta, y cada variante de T14
-- llama a una sola de ellas contra la venta, así que no se pisan (por qué eso importa: "Controles negativos" del README).
--   · ajustar_stock_promocion_completo vuelve a tomar la promo antes que el producto: T14a vuelve a dar 40P01.
--   · trg_promo_factor_bloquea_contenedores queda deshabilitado: T14c y T14d vuelven a dar 40P01.
--   · eliminar_pedido_completo vuelve a recorrer las líneas sin bloquear antes: T14e y T14f.
--   · actualizar_pedido_items vuelve a tomar las promos en el orden del JSON: T14g y T14h.
--   · registrar_salvedad vuelve a tomar la promo de un regalo de otro modo recién al confirmar: T14j.
--   · actualizar_precios_masivo vuelve a actualizar en el orden del JSON: T14l y T14m.
--     psql -f controles-negativos-t14.sql
-- Después: node run.mjs t14 --out <dir>, RESTAURAR y repetir `docker-local.mjs huella`: cero diferencias.

-- ===== MUTAR =====
CREATE TABLE IF NOT EXISTS conc.mut_orig (firma text PRIMARY KEY, def text NOT NULL);
INSERT INTO conc.mut_orig SELECT p.oid::regprocedure::text, pg_get_functiondef(p.oid)
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
   AND p.proname IN ('ajustar_stock_promocion_completo', 'eliminar_pedido_completo', 'actualizar_pedido_items',
                     'actualizar_precios_masivo', 'registrar_salvedad')
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
      ('ajustar_stock_promocion_completo(bigint,bigint,integer,integer,uuid,text)',
       E'  PERFORM 1 FROM productos\n   WHERE id = p_producto_id AND sucursal_id = v_sucursal\n     FOR UPDATE;\n'),
      ('actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)',
       E'  PERFORM 1\n     FROM promociones\n    WHERE sucursal_id = v_sucursal\n      AND id IN (SELECT pi.promocion_id FROM pedido_items pi\n                  WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal\n                    AND pi.promocion_id IS NOT NULL\n                 UNION\n                 SELECT (e->>''promocion_id'')::bigint FROM jsonb_array_elements(v_items) e\n                  WHERE e->>''promocion_id'' IS NOT NULL)\n    ORDER BY id\n      FOR UPDATE;\n'),
      ('registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)',
       E'  PERFORM 1\n     FROM promociones\n    WHERE sucursal_id = v_sucursal\n      AND id IN (SELECT pi.promocion_id FROM pedido_items pi\n                  WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal\n                    AND pi.promocion_id IS NOT NULL)\n    ORDER BY id\n      FOR UPDATE;\n'),
      ('actualizar_precios_masivo(jsonb)',
       E'  PERFORM 1\n     FROM productos\n    WHERE sucursal_id = v_sucursal_id\n      AND id IN (SELECT btrim(e->>''producto_id'')::bigint FROM jsonb_array_elements(p_productos) e\n                  WHERE btrim(e->>''producto_id'') ~ ''^[0-9]{1,18}$'')\n    ORDER BY id\n      FOR NO KEY UPDATE;\n')
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
  ALTER TABLE public.promociones DISABLE TRIGGER trg_promo_factor_bloquea_contenedores;
END
$m$;

-- ===== RESTAURAR (correr aparte, después de las variantes) =====
-- ALTER TABLE public.promociones ENABLE TRIGGER trg_promo_factor_bloquea_contenedores;
-- DO $r$ DECLARE d text; BEGIN FOR d IN SELECT def FROM conc.mut_orig LOOP EXECUTE d; END LOOP; END $r$; TRUNCATE conc.mut_orig;
