-- Controles negativos de la tarjeta 13 de #1378 (#1446). Se corren sobre la copia LOCAL de Docker con la migración
-- de la tarjeta aplicada. NUNCA contra prod ni contra una rama de Supabase compartida: es DDL sobre `public`.
--
-- La corrida de antes de la migración es el control negativo del arreglo entero. Acá se saca una PARTE por vez, para
-- ver que cada una hace falta. Son tres grupos y no se corren juntos:
--
--   M10 _edicion_bloquea_boletas no toma nada (los cuatro llamadores vuelven a tomar X primero). El trigger queda.
--       Con Y < X, el FIFO toma Y y pide X: T13g, T13j y T13l vuelven a dar 40P01, y las dos ediciones (T13f). T13a a
--       T13d siguen en 0 (el trigger corre antes que el saldo y toma Y antes que el cliente).
--         psql -v grupo=m10 -f controles-negativos-t13.sql
--   M9  Lo de M10, y además pedidos_reconciliar_pagos sin su pre-bloqueo (el nombre queda: corre antes que el saldo).
--       Al bajar una boleta cobrada, desafectar_sobrepago_pedido toma el cliente antes que aplicar_credito_cliente
--       llegue a Y: T13c y T13d vuelven a dar 40P01. T13a y T13b siguen en 0 (sin excedente alcanza con el
--       pre-bloqueo de aplicar_credito_cliente, de la 454).
--         psql -v grupo=m9 -f controles-negativos-t13.sql
--   M8  El trigger vuelve a llamarse zzz_pedidos_reconciliar_pagos (corre después del saldo); los dos pre-bloqueos
--       quedan. La edición toma el cliente antes que la ruta de Y, que el pre-bloqueo de los llamadores no toma (sólo
--       boletas): T13n, el cobro de W en esa ruta, vuelve a dar 40P01. T13a a T13d siguen en 0 (los cubre el
--       pre-bloqueo de los llamadores).
--       T13m ya no la muerde, y no por un lock nuevo (#1499): desde la 463c la boleta nueva absorbe el saldo a favor, y
--       la W que t13_ruta_setup crea después del crédito se lo lleva al nacer (va a Y). En T13m no queda plata a favor,
--       la edición de X no llega a R y no hay cruce (con R retenida, la edición no la espera). T13n es T13m con un
--       crédito suelto creado después de W (conc.t13n_ruta_setup).
--       Medido el 07/11 (base = prod hasta la 474): sin la mutación, T13m y T13n 100/100 y 0 40P01; con M8, T13n 89
--       40P01 en 100 rondas (víctima: el cobro de W, en actualizar_saldo_pedido, esperando el cliente), T13m 0.
--         psql -v grupo=m8 -f controles-negativos-t13.sql
--   Después de cada grupo: node run.mjs t13 --out <dir> (una carpeta por grupo), RESTAURAR y repetir
--   `docker-local.mjs huella`: cero diferencias.

-- ===== MUTAR =====
CREATE TABLE IF NOT EXISTS conc.mut_orig (firma text PRIMARY KEY, def text NOT NULL);
INSERT INTO conc.mut_orig SELECT p.oid::regprocedure::text, pg_get_functiondef(p.oid)
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
   AND p.proname IN ('pedidos_reconciliar_pagos', '_edicion_bloquea_boletas')
ON CONFLICT DO NOTHING;
SELECT set_config('conc.grupo', :'grupo', false);
DO $m$
DECLARE
  d text; f text; pat text; rep text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.pedidos'::regclass AND tgname = 'trg_pedidos_reconciliar_pagos')
     OR to_regprocedure('public._edicion_bloquea_boletas(bigint,bigint)') IS NULL THEN
    RAISE EXCEPTION 'falta la migración de la tarjeta 13 (o ya hay un grupo aplicado: RESTAURAR primero)';
  END IF;
  IF current_setting('conc.grupo') = 'm8' THEN
    ALTER TRIGGER trg_pedidos_reconciliar_pagos ON public.pedidos RENAME TO zzz_pedidos_reconciliar_pagos;
    RETURN;
  ELSIF current_setting('conc.grupo') NOT IN ('m9', 'm10') THEN
    RAISE EXCEPTION 'grupo: m8, m9 o m10';
  END IF;
  FOR f, pat, rep IN SELECT v.f, v.pat, v.rep FROM (VALUES
      ('_edicion_bloquea_boletas(bigint,bigint)', 'IF v_plata <= 0.005 THEN', 'IF true /* MUTADO */ OR v_plata <= 0.005 THEN', true),
      ('pedidos_reconciliar_pagos()',             'IF v_plata > 0.005 THEN',  'IF false /* MUTADO */ AND v_plata > 0.005 THEN', current_setting('conc.grupo') = 'm9')
    ) v(f, pat, rep, va) WHERE va
  LOOP
    SELECT def INTO d FROM conc.mut_orig WHERE firma = f;
    IF (length(d) - length(replace(d, pat, ''))) / length(pat) <> 1 THEN
      RAISE EXCEPTION '%: "%" no aparece una sola vez', f, pat;
    END IF;
    EXECUTE replace(d, pat, rep);
  END LOOP;
END
$m$;

-- ===== RESTAURAR (correr aparte, después de las variantes; sirve para los tres grupos) =====
-- DO $r$ BEGIN IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'zzz_pedidos_reconciliar_pagos') THEN
--   ALTER TRIGGER zzz_pedidos_reconciliar_pagos ON public.pedidos RENAME TO trg_pedidos_reconciliar_pagos; END IF; END $r$;
-- DO $r$ DECLARE d text; BEGIN FOR d IN SELECT def FROM conc.mut_orig LOOP EXECUTE d; END LOOP; END $r$; TRUNCATE conc.mut_orig;
