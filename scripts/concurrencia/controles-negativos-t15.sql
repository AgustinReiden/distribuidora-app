-- Controles negativos de la tarjeta 15 de #1378 (#1460, C1 y C7). Se corren sobre la copia LOCAL de Docker con la
-- migración de la tarjeta aplicada. NUNCA contra prod ni contra una rama de Supabase compartida: es DDL sobre `public`.
--
-- Saca los pre-bloqueos de la migración, cada uno en su función. Van juntos porque no se pisan: T15a a T15c sólo
-- pasan por cambiar_cliente_pedido, y T15g y T15h sólo por imputar_credito_a_pedido_impl.
--   M11 cambiar_cliente_pedido no toma nada antes de X (los seis pre-bloqueos de la 467, ver "Por qué cambió"): T15a y
--       T15b vuelven a dar 40P01 en todas las rondas, y T15c (sin forzar) en una parte.
--   M12 imputar_credito_a_pedido_impl no toma las rutas de la boleta: T15g vuelve a dar 40P01.
--   T15d a T15f (C6) no dependen de ninguno: siguen en 0.
--
--   psql -f controles-negativos-t15.sql
--   node run.mjs t15 --out <dir>   (otra carpeta que la de la corrida limpia)
--   RESTAURAR (más abajo) y repetir `docker-local.mjs huella`: cero diferencias.
--
-- Por qué cambió (06/11, tarjeta 10 de #1477): la 467 (#1473) reescribió el pre-bloqueo de cambiar_cliente_pedido. Antes
-- era uno solo (el de #1460 C1, que empezaba en `IF p_destino_pagos = 'pedido_nuevo' AND ...`); ahora son seis bloques
-- `PERFORM 1 ... ORDER BY id FOR [NO KEY] UPDATE` (cuatro FOR UPDATE y dos FOR NO KEY UPDATE) en el orden global: boletas,
-- productos con contenedores, promos, recorridos, pagos y clientes. El patrón viejo ya no aparece una sola vez y el DO
-- abortaba entero sin mutar nada (las cinco variantes corrían sin mutación). La 470 (#1489) no cambió los locks de esa
-- función. Ahora M11 pasa los seis a `ORDER BY id /* MUTADO */` (sin lock) y el DO exige que sean exactamente seis; M12
-- (imputar_credito_a_pedido_impl) no cambió.
--
-- Medido el 06/11 (base reconstruida hasta la 474, huella igual a prod, PC de 22 hilos), con las dos mutaciones puestas;
-- correctas / 40P01 sobre 100 rondas por variante:
--   T15a 0 correctas, 100 40P01 · T15b 0, 100 · T15c (sin forzar) 90, 10 · T15g 97, 100 · T15h (sin forzar) 97, 4.
--   Testigos: T15d 100 correctas, 0 40P01 · T15f (sin forzar) 100, 0.
--   El 40P01 de T15g no resta de las correctas (tiene su columna); su veredicto es el 40P01. Con los pre-bloqueos
--   puestos T15a a T15h dan 0 40P01 y 100 correctas.

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
  SELECT def INTO d FROM conc.mut_orig WHERE firma LIKE 'cambiar_cliente_pedido(%';
  IF regexp_count(d, E'\n    ORDER BY id\n      FOR (NO KEY )?UPDATE;') <> 6 THEN RAISE EXCEPTION 'cambiar_cliente_pedido: esperaba 6 locks de pre-bloqueo, hay %', regexp_count(d, E'\n    ORDER BY id\n      FOR (NO KEY )?UPDATE;'); END IF;
  EXECUTE regexp_replace(d, E'\n    ORDER BY id\n      FOR (NO KEY )?UPDATE;', E'\n    ORDER BY id /* MUTADO */;', 'g');
END
$m$;

-- ===== RESTAURAR (correr aparte, después de las variantes) =====
-- DO $r$ DECLARE d text; BEGIN FOR d IN SELECT def FROM conc.mut_orig LOOP EXECUTE d; END LOOP; END $r$; TRUNCATE conc.mut_orig;
