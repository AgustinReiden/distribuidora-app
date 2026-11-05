-- Controles negativos de la tarjeta 15 de #1378 (#1460, C1 y C7). Se corren sobre la copia LOCAL de Docker con la
-- migración de la tarjeta aplicada. NUNCA contra prod ni contra una rama de Supabase compartida: es DDL sobre `public`.
--
-- Saca los dos pre-bloqueos de la migración, cada uno en su función. Van juntos porque no se pisan: T15a a T15c sólo
-- pasan por cambiar_cliente_pedido, y T15g y T15h sólo por imputar_credito_a_pedido_impl.
--   M11 cambiar_cliente_pedido no toma nada antes de X: T15a y T15b vuelven a dar 40P01 en casi todas las rondas, y
--       T15c (sin forzar) en una parte.
--   M12 imputar_credito_a_pedido_impl no toma las rutas de la boleta: T15g vuelve a dar 40P01.
--   T15d a T15f (C6) no dependen de ninguno: siguen en 0.
--
--   psql -f controles-negativos-t15.sql
--   node run.mjs t15 --out <dir>   (otra carpeta que la de la corrida limpia)
--   RESTAURAR (más abajo) y repetir `docker-local.mjs huella`: cero diferencias.

-- ===== MUTAR =====
CREATE TABLE IF NOT EXISTS conc.mut_orig (firma text PRIMARY KEY, def text NOT NULL);
INSERT INTO conc.mut_orig SELECT p.oid::regprocedure::text, pg_get_functiondef(p.oid)
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
   AND p.proname IN ('cambiar_cliente_pedido', 'imputar_credito_a_pedido_impl')
ON CONFLICT DO NOTHING;
DO $m$
DECLARE
  d text; f text; pat text; rep text;
BEGIN
  FOR f, pat, rep IN SELECT v.f, v.pat, v.rep FROM (VALUES
      ('cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)',
       E'  IF p_destino_pagos = ''pedido_nuevo''\n     AND (SELECT COALESCE(monto_pagado, 0) FROM pedidos',
       E'  IF false /* MUTADO */ AND p_destino_pagos = ''pedido_nuevo''\n     AND (SELECT COALESCE(monto_pagado, 0) FROM pedidos'),
      ('imputar_credito_a_pedido_impl(bigint,bigint,numeric)',
       E'                    AND pd.sucursal_id = v_sucursal_id)',
       E'                    AND false /* MUTADO */ AND pd.sucursal_id = v_sucursal_id)')
    ) v(f, pat, rep)
  LOOP
    SELECT def INTO d FROM conc.mut_orig WHERE firma = f;
    IF d IS NULL THEN
      RAISE EXCEPTION '%: no está en conc.mut_orig', f;
    END IF;
    IF (length(d) - length(replace(d, pat, ''))) / length(pat) <> 1 THEN
      RAISE EXCEPTION '%: el patrón no aparece una sola vez (¿falta la migración de la tarjeta 15?)', f;
    END IF;
    EXECUTE replace(d, pat, rep);
  END LOOP;
END
$m$;

-- ===== RESTAURAR (correr aparte, después de las variantes) =====
-- DO $r$ DECLARE d text; BEGIN FOR d IN SELECT def FROM conc.mut_orig LOOP EXECUTE d; END LOOP; END $r$; TRUNCATE conc.mut_orig;
