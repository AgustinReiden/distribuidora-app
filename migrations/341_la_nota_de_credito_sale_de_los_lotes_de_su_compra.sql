-- #1079 · La devolución por nota de crédito sale de los lotes de SU compra.
--
-- EL BUG
--   registrar_nota_credito con ítems (la nota por factura entera) bajaba el
--   stock con un UPDATE pelado. El camino de bajada de trg_lotes_sincronizar no
--   mira el origen: come primero la bolsa "sin vencimiento" y después FEFO
--   global. Así, devolverle al proveedor 10 unidades de la compra C dejaba el
--   lote de C intacto (el aviso de vencimientos seguía contando 10 unidades que
--   ya no están) y le sacaba 10 a la bolsa, o al lote que vence primero de OTRA
--   compra. Medido en prod contra la 336 (scripts/test-nota-credito-lotes-1079.sql,
--   caso A): lote de C con 50 vivas, bolsa 40, nota por 10 → lote 50 / bolsa
--   30, en vez de 40 / 40. Es así desde antes de la 336; la etiqueta
--   'nota_credito' que le puso la 336 no cambia cómo baja.
--
-- LA DECISIÓN (del dueño, 2026-10-10)
--   La devolución sale de los lotes de la compra que se acredita, empezando por
--   el que vence antes. Lo que a esos lotes no les alcance sale de la bolsa (y
--   si tampoco alcanza, FEFO global, que es lo que ya hace el trigger). Es lo
--   que hace registrar_nota_credito_lote con su lote puntual, y lo que la 229
--   le dio a la compra cancelada.
--
-- EL ARREGLO
--   Por cada renglón, ANTES del UPDATE de stock, se descuentan de los lotes de
--   (compra, producto) con unidades vivas, por vencimiento, hasta lo que de
--   verdad va a bajar el stock (el UPDATE se clampea a 0: un stock menor que lo
--   devuelto baja sólo lo que hay). Con el lote ya descontado, la bolsa que ve
--   el trigger crece en lo mismo y la bajada sale de ahí: el lote de la compra
--   queda −N y la bolsa igual. El orden es el de registrar_nota_credito_lote
--   ("el lote, ANTES del stock").
--
--   Los lotes se buscan por compra_id en el momento de la nota, no por un id
--   guardado: no hay referencia que una edición de la compra pueda dejar
--   colgada. Y una edición posterior conserva lo descontado, porque
--   sincronizar_lotes_compra conserva lo consumido (cantidad − restante).
--   Los lotes sólo para la traza tienen restante 0 y no entran.
--
--   No cambia: el tope de lo acreditable, el II, la etiqueta 'nota_credito' del
--   ledger, la nota sin ítems (ajuste, no toca stock) ni la puerta por lote.
--   Es una bajada: no va a la lista blanca del trigger, y STK-F (sólo subidas)
--   y STK-D (ya etiquetada) no cambian.
--
-- LO QUE QUEDA (de la revisión adversarial, baja severidad, a sabiendas)
--   · Orden de locks: esta nota va compra_items → productos → lotes; la puerta
--     por lote y dar_de_baja_lote van lote → ... → productos. Dos admins sobre
--     el mismo lote a la vez pueden chocar en un deadlock: Postgres aborta una
--     de las dos entera (sin EXCEPTION WHEN OTHERS acá) y se reintenta. Antes
--     pasaba sólo cuando la bolsa no alcanzaba.
--   · Un vencimiento NUEVO que sincronizar_lotes_compra cree mientras la nota
--     espera su lock no entra en el FOR de la nota: esa nota sale de la bolsa,
--     como antes. No rompe nada; no se serializa contra la edición.
--   · Anular una compra con notas resta dos veces lo devuelto: preexistente,
--     #1095.
--
-- Parche por ancla sobre el cuerpo vivo (molde de las 314, 322, 334 y 336): si
-- el cuerpo de prod no tiene el ancla exactamente una vez, la migración aborta.
--
-- Ensayo: scripts/test-nota-credito-lotes-1079.sql (falla antes, pasa después).

BEGIN;

CREATE OR REPLACE FUNCTION public._mig1079_ancla(
  p_funcion regprocedure, p_ancla text, p_nuevo text
) RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text;
  v_veces int;
BEGIN
  v_def := pg_get_functiondef(p_funcion);
  v_veces := (length(v_def) - length(replace(v_def, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El ancla aparece % veces en % (se esperaba exactamente 1). El cuerpo vivo cambio: revisar a mano. Ancla: %',
      v_veces, p_funcion, left(p_ancla, 120);
  END IF;
  EXECUTE replace(v_def, p_ancla, p_nuevo);
END;
$fn$;

-- 1 · Las variables del descuento por lote.
SELECT public._mig1079_ancla('public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)'::regprocedure,
$ancla$  v_tipo TEXT; v_ii NUMERIC; v_total NUMERIC;  -- mig 280
$ancla$,
$nuevo$  v_tipo TEXT; v_ii NUMERIC; v_total NUMERIC;  -- mig 280
  v_de_lotes INTEGER; v_toma INTEGER; v_lote RECORD;  -- #1079
$nuevo$);

-- 2 · Los lotes de la compra, antes del stock.
SELECT public._mig1079_ancla('public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)'::regprocedure,
$ancla$    UPDATE productos SET stock = GREATEST(stock - v_cantidad, 0) WHERE id = v_producto_id AND sucursal_id = v_sucursal;
  END LOOP;$ancla$,
$nuevo$    -- #1079: lo devuelto sale de los lotes de ESTA compra, el que vence antes
    -- primero, y ANTES del stock (como registrar_nota_credito_lote). Si no,
    -- el trigger come la bolsa y después FEFO global, y el lote de la compra
    -- sigue contando unidades que ya se devolvieron. Hasta lo que de verdad
    -- baja el stock, que se clampea a 0. Lo que a estos lotes no les alcance
    -- sale de la bolsa: con el lote ya descontado, el trigger ve la bolsa
    -- crecer en lo mismo y no toca otros lotes.
    v_de_lotes := GREATEST(LEAST(v_cantidad, v_stock_actual), 0);
    FOR v_lote IN
      SELECT id, cantidad_restante
        FROM producto_lotes
       WHERE compra_id = p_compra_id
         AND producto_id = v_producto_id
         AND sucursal_id = v_sucursal
         AND cantidad_restante > 0
       ORDER BY fecha_vencimiento, id
         FOR UPDATE
    LOOP
      EXIT WHEN v_de_lotes <= 0;
      v_toma := LEAST(v_de_lotes, v_lote.cantidad_restante);
      UPDATE producto_lotes SET cantidad_restante = cantidad_restante - v_toma WHERE id = v_lote.id;
      v_de_lotes := v_de_lotes - v_toma;
    END LOOP;

    UPDATE productos SET stock = GREATEST(stock - v_cantidad, 0) WHERE id = v_producto_id AND sucursal_id = v_sucursal;
  END LOOP;$nuevo$);

-- 3 · El comentario de la puerta por lote que este cambio deja falso. Sólo
--     comentario: el cuerpo no cambia.
SELECT public._mig1079_ancla('public.registrar_nota_credito_lote(bigint,numeric,text,text)'::regprocedure,
$ancla$  -- la compra completa por un lado y el lote por el otro acreditaria el doble
  -- -- la nota de compra baja stock pero no toca lotes, asi que el contador del
  -- lote sigue en pie y habilitaria la segunda vuelta.
$ancla$,
$nuevo$  -- la compra completa por un lado y el lote por el otro acreditaria el doble.
  -- (Desde #1079 la nota por factura entera tambien baja los lotes de la
  -- compra, pero solo lo que les queda vivo; lo demas sale de la bolsa. El
  -- tope que cierra la segunda vuelta sigue siendo este.)
$nuevo$);

DROP FUNCTION public._mig1079_ancla(regprocedure, text, text);

-- 4 · Verificación: el caso B del ensayo (no el primero por FEFO global, con
--     bolsa > 0). Se deshace solo con un SQLSTATE centinela.
DO $verif$
DECLARE
  v_admin  uuid;
  v_suc    bigint;
  v_prod   bigint;
  v_otra   bigint;
  v_compra bigint;
  v_lote_d bigint;
  v_lote_c bigint;
  v_res    jsonb;
  v_c      int;
  v_d      int;
  v_stock  int;
  v_hoy    date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
BEGIN
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;

  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);

    INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
    VALUES ('ZZ verif 1079', 100, 90, 10, v_suc) RETURNING id INTO v_prod;
    INSERT INTO compras (sucursal_id, fecha_compra, subtotal, iva, total)
    VALUES (v_suc, CURRENT_DATE, 1000, 210, 1210) RETURNING id INTO v_otra;
    INSERT INTO compras (sucursal_id, fecha_compra, subtotal, iva, total)
    VALUES (v_suc, CURRENT_DATE, 1000, 210, 1210) RETURNING id INTO v_compra;
    INSERT INTO compra_items (compra_id, producto_id, cantidad, costo_unitario, subtotal, sucursal_id)
    VALUES (v_otra, v_prod, 100, 10, 1000, v_suc), (v_compra, v_prod, 100, 10, 1000, v_suc);
    -- otra compra que vence antes (30 vivas), la de la nota después (50), bolsa 10
    INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, compra_id, origen)
    VALUES (v_prod, v_suc, v_hoy + 20, 100, 30, v_otra, 'compra') RETURNING id INTO v_lote_d;
    INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, compra_id, origen)
    VALUES (v_prod, v_suc, v_hoy + 60, 100, 50, v_compra, 'compra') RETURNING id INTO v_lote_c;

    v_res := public.registrar_nota_credito(v_compra, 'VERIF-1079', 'verificacion 1079', 0, 0, 0, NULL,
               jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 10,
                                                    'costo_unitario', 10, 'subtotal', 100)), NULL);
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION '#1079 · la nota de verificación no se registró: %', v_res;
    END IF;

    SELECT cantidad_restante INTO v_c FROM producto_lotes WHERE id = v_lote_c;
    SELECT cantidad_restante INTO v_d FROM producto_lotes WHERE id = v_lote_d;
    SELECT stock INTO v_stock FROM productos WHERE id = v_prod;
    IF v_c <> 40 OR v_d <> 30 OR v_stock <> 80 THEN
      RAISE EXCEPTION '#1079 · esperaba lote de la compra 40, otro lote 30, stock 80 (bolsa 10); quedó %, %, %',
        v_c, v_d, v_stock;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
  END;
END
$verif$;

COMMIT;
