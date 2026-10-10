-- #1095 · Una compra con notas de crédito no se anula.
--
-- EL BUG
--   anular_compra_atomica le restaba al stock TODO lo de compra_items de la
--   compra. Las notas de crédito con ítems ya habían bajado ese stock al
--   registrarse (registrar_nota_credito y la puerta por lote, las dos), y desde
--   la 341 también los lotes de la compra: lo devuelto se restaba dos veces. El
--   chequeo de "dejaría stock negativo" usa la misma cuenta, así que con stock
--   de otras compras tampoco lo atajaba. Medido en prod antes de esta migración
--   (scripts/test-anular-compra-nc-1095.sql, caso A): stock 150, compra de 100,
--   nota por 10 → stock 140; anular → success y stock 40, en vez de 50 o de un
--   rechazo. Y la nota quedaba colgada de una compra cancelada, que
--   posicion_fiscal y reporte_gerencial excluyen por `c.estado <> 'cancelada'`:
--   un comprobante real desaparecía del IVA/II sin que nadie lo decidiera.
--
-- LA DECISIÓN (del dueño, 2026-10-10)
--   La anulación se rechaza mientras la compra tenga CUALQUIER nota de crédito,
--   de devolución o de ajuste (el ajuste no toca stock, pero anular la compra lo
--   borraría igual del fiscal y del gerencial). Es la misma regla que ya usa
--   cambiar_proveedor_compra. La salida de negocio es registrar otra nota por lo
--   que queda, o editar la compra. No existe una RPC para anular una nota de
--   compra: si hace falta, es una feature aparte.
--
-- EL ARREGLO
--   1 · anular_compra_atomica cuenta las notas de la compra después de tomarla
--       FOR UPDATE y antes de setear los GUC de stock y de bloquear productos:
--       el rechazo no mueve nada.
--   2 · registrar_nota_credito toma la compra FOR SHARE (antes era un EXISTS sin
--       lock).
--   3 · registrar_nota_credito_lote toma la compra del lote FOR SHARE ANTES del
--       lote, y rechaza si está cancelada. Antes iba lote → … → la compra (por el
--       KEY SHARE del INSERT de la nota, FK compuesta
--       notas_credito_compra_id_fkey), al revés que la anulación.
--
-- ORDEN DE LOCKS (por qué cierra la carrera nota ↔ anulación)
--   Las tres toman PRIMERO la fila de compras: la anulación en UPDATE, las dos
--   puertas de nota en SHARE.
--   · Si la anulación tiene la compra, la puerta espera; al reevaluar en READ
--     COMMITTED ve `estado = 'cancelada'` y rechaza.
--   · Si una puerta la tiene en SHARE, el FOR UPDATE de la anulación espera a
--     que commitee; el count de notas es una sentencia posterior, con snapshot
--     nuevo, y ve la nota.
--   · La anulación NO bloquea lotes: todo camino que baja stock va productos →
--     lotes (trg_lotes_sincronizar / _consumir_lotes_fefo), y la anulación sigue
--     compras → productos → (trigger) lotes, como en la 229. Hacer que bloquee
--     lotes antes que productos reabriría un deadlock contra las ventas.
--   · registrar_nota_credito_lote lee el compra_id del lote sin lock, bloquea la
--     compra y recién después el lote, y si el lote cambió de compra en el medio
--     (cambiar_proveedor_compra los reapunta al clon) aborta con "reintentá" en
--     vez de acreditar contra la compra equivocada.
--
-- NO CAMBIA
--   El orden de la 229 (cancelar antes de bajar stock), la etiqueta
--   'compra_anulada', el chequeo de negativos, la restauración de costos, la
--   etiqueta 'lote_devuelto_proveedor', las firmas ni las ACL (CREATE OR REPLACE
--   las conserva). STK-F / STK-D: ninguna subida ni bajada nueva.
--
-- LO QUE QUEDA (a sabiendas, va a issues aparte)
--   · Por REST un admin puede pasar compras.estado a 'cancelada'
--     (mt_compras_update) o borrar una nota (mt_notas_credito_all) y saltearse
--     estas RPCs. El front no usa ninguno de los dos caminos. El invariante
--     "ninguna compra cancelada tiene notas" NO queda cerrado por esta
--     migración.
--   · actualizar_compra_items no mira las notas: editar la compra puede dejar lo
--     comprado por debajo de lo acreditado.
--   · Supera la nota "LO QUE QUEDA · #1095" de la 341.
--
-- Parche por ancla sobre el cuerpo vivo (molde de la 341): si el cuerpo de prod
-- no tiene el ancla exactamente una vez, la migración aborta.
--
-- Ensayo: scripts/test-anular-compra-nc-1095.sql (falla antes, pasa después).

BEGIN;

CREATE OR REPLACE FUNCTION public._mig1095_ancla(
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

REVOKE ALL ON FUNCTION public._mig1095_ancla(regprocedure, text, text) FROM PUBLIC, anon, authenticated;

-- 1 · anular_compra_atomica: la variable del conteo.
SELECT public._mig1095_ancla('public.anular_compra_atomica(bigint,uuid)'::regprocedure,
$ancla$  v_negativos  JSONB;
$ancla$,
$nuevo$  v_negativos  JSONB;
  v_nc_count   INTEGER;  -- #1095
$nuevo$);

-- 2 · anular_compra_atomica: el rechazo, después del FOR UPDATE de la compra.
SELECT public._mig1095_ancla('public.anular_compra_atomica(bigint,uuid)'::regprocedure,
$ancla$  IF v_compra.estado = 'cancelada' THEN
    RETURN jsonb_build_object('success', false, 'error', 'La compra ya está cancelada');
  END IF;
$ancla$,
$nuevo$  IF v_compra.estado = 'cancelada' THEN
    RETURN jsonb_build_object('success', false, 'error', 'La compra ya está cancelada');
  END IF;

  -- #1095: una compra con notas de crédito (devolución o ajuste) no se anula.
  -- Lo acreditado ya bajó el stock (y desde la 341 los lotes de la compra), y
  -- la reversa de abajo lo restaría de nuevo. Además la nota quedaría colgada
  -- de una compra cancelada, que posicion_fiscal y el gerencial excluyen. Es la
  -- misma regla que cambiar_proveedor_compra.
  --
  -- Orden de locks: la compra ya está tomada FOR UPDATE arriba, y las dos
  -- puertas de nota la toman FOR SHARE como primer paso, así que este conteo ve
  -- toda nota commiteada antes y ninguna nota nueva entra después. Esta función
  -- no bloquea lotes: va compras → productos → (trigger) lotes, como todo lo
  -- que baja stock.
  SELECT count(*) INTO v_nc_count
    FROM notas_credito
   WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal;
  IF v_nc_count > 0 THEN
    RETURN jsonb_build_object('success', false, 'error',
      format('La compra tiene %s nota(s) de crédito: no se puede anular. Si se devuelve el resto de la mercadería, registralo con otra nota de crédito.',
             v_nc_count));
  END IF;
$nuevo$);

-- 3 · registrar_nota_credito: la compra FOR SHARE en vez de un EXISTS sin lock.
SELECT public._mig1095_ancla('public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)'::regprocedure,
$ancla$  IF NOT EXISTS (SELECT 1 FROM compras WHERE id = p_compra_id AND estado != 'cancelada' AND sucursal_id = v_sucursal) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Compra no encontrada o cancelada');
  END IF;
$ancla$,
$nuevo$  -- #1095: la compra se toma FOR SHARE, primer lock de la nota. Serializa
  -- contra anular_compra_atomica (que la toma FOR UPDATE): si la anulación va
  -- primero, acá se reevalúa y se ve cancelada; si la nota va primero, la
  -- anulación espera y cuenta esta nota.
  PERFORM 1 FROM compras
   WHERE id = p_compra_id AND estado <> 'cancelada' AND sucursal_id = v_sucursal
     FOR SHARE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Compra no encontrada o cancelada');
  END IF;
$nuevo$);

-- 4 · registrar_nota_credito_lote: la variable de la compra.
SELECT public._mig1095_ancla('public.registrar_nota_credito_lote(bigint,numeric,text,text)'::regprocedure,
$ancla$  v_nota_id    bigint;
$ancla$,
$nuevo$  v_nota_id    bigint;
  v_compra_id  bigint;  -- #1095
$nuevo$);

-- 5 · registrar_nota_credito_lote: la compra antes que el lote.
SELECT public._mig1095_ancla('public.registrar_nota_credito_lote(bigint,numeric,text,text)'::regprocedure,
$ancla$  SELECT * INTO v_lote
    FROM public.producto_lotes
   WHERE id = p_lote_id AND sucursal_id = v_sucursal
     FOR UPDATE;
$ancla$,
$nuevo$  -- #1095: la compra del lote se toma FOR SHARE ANTES que el lote, el mismo
  -- primer paso que registrar_nota_credito y que anular_compra_atomica (que la
  -- toma FOR UPDATE). Así la nota y la anulación se serializan en la compra y
  -- ninguna anulación pasa con esta nota a medio registrar. El compra_id se lee
  -- sin lock y se vuelve a comparar abajo, con el lote ya tomado. Un lote
  -- manual o inexistente sigue de largo y cae en los errores de siempre.
  SELECT compra_id INTO v_compra_id
    FROM public.producto_lotes
   WHERE id = p_lote_id AND sucursal_id = v_sucursal;
  IF v_compra_id IS NOT NULL THEN
    PERFORM 1 FROM public.compras
     WHERE id = v_compra_id AND sucursal_id = v_sucursal AND estado <> 'cancelada'
       FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'La compra % de este lote está cancelada: no se le puede generar una nota de crédito', v_compra_id;
    END IF;
  END IF;

  SELECT * INTO v_lote
    FROM public.producto_lotes
   WHERE id = p_lote_id AND sucursal_id = v_sucursal
     FOR UPDATE;
$nuevo$);

-- 6 · registrar_nota_credito_lote: el comentario que este cambio deja falso,
--     por el chequeo de que el lote no cambió de compra.
SELECT public._mig1095_ancla('public.registrar_nota_credito_lote(bigint,numeric,text,text)'::regprocedure,
$ancla$  -- No hace falta chequear que la compra no este cancelada: cancelarla dispara
  -- `borrar_lotes_compra_cancelada` (mig 224) y el lote no existiria.
$ancla$,
$nuevo$  -- #1095: que la compra no esté cancelada ya se chequeó arriba, con la
  -- compra tomada. Falta que el lote siga siendo de esa compra:
  -- cambiar_proveedor_compra reapunta los lotes al clon, y si lo hizo entre la
  -- lectura sin lock y el lock del lote, la nota iría contra la compra
  -- equivocada.
  IF v_lote.compra_id IS DISTINCT FROM v_compra_id THEN
    RAISE EXCEPTION 'El lote cambió de compra mientras se registraba la nota: reintentá';
  END IF;
$nuevo$);

DROP FUNCTION public._mig1095_ancla(regprocedure, text, text);

-- 7 · Verificación. El caso A del ensayo (bolsa 50) y la forma de los tres
--     cuerpos. Se deshace solo con un SQLSTATE centinela.
DO $verif$
DECLARE
  v_admin  uuid;
  v_suc    bigint;
  v_prod   bigint;
  v_compra bigint;
  v_lote   bigint;
  v_res    jsonb;
  v_stock  int;
  v_rest   int;
  v_estado text;
  v_def    text;
  v_f      regprocedure;
  v_hoy    date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
BEGIN
  -- 7.1 · forma de los cuerpos
  v_def := pg_get_functiondef('public.anular_compra_atomica(bigint,uuid)'::regprocedure);
  IF strpos(v_def, '#1095') = 0 THEN
    RAISE EXCEPTION '#1095 · anular_compra_atomica no quedó parcheada';
  END IF;
  IF v_def ~ 'producto_lotes[^;]*FOR\s+UPDATE' THEN
    RAISE EXCEPTION '#1095 · anular_compra_atomica bloquea lotes: invierte el orden productos → lotes';
  END IF;
  IF strpos(v_def, 'v_nc_count > 0') = 0
     OR strpos(v_def, 'v_nc_count > 0') > strpos(v_def, 'set_config(''app.stock_origen''') THEN
    RAISE EXCEPTION '#1095 · el rechazo por notas tiene que ir antes de los GUC de stock';
  END IF;
  IF strpos(v_def, E'UPDATE compras\n     SET estado = ''cancelada''') = 0
     OR strpos(v_def, E'UPDATE compras\n     SET estado = ''cancelada''')
        > strpos(v_def, E'UPDATE productos p\n     SET stock = p.stock - q.qty') THEN
    RAISE EXCEPTION '#1095 · se perdió el orden de la 229 (cancelar antes de bajar stock)';
  END IF;

  v_def := pg_get_functiondef('public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)'::regprocedure);
  IF strpos(v_def, '#1095') = 0 OR strpos(v_def, 'FOR SHARE') = 0
     OR strpos(v_def, 'FOR SHARE') > strpos(v_def, E'PERFORM 1 FROM compra_items') THEN
    RAISE EXCEPTION '#1095 · registrar_nota_credito no toma la compra FOR SHARE antes de sus líneas';
  END IF;

  v_def := pg_get_functiondef('public.registrar_nota_credito_lote(bigint,numeric,text,text)'::regprocedure);
  IF strpos(v_def, '#1095') = 0 OR strpos(v_def, 'FOR SHARE') = 0
     OR strpos(v_def, 'FOR SHARE')
        > strpos(v_def, E'SELECT * INTO v_lote\n    FROM public.producto_lotes\n   WHERE id = p_lote_id AND sucursal_id = v_sucursal\n     FOR UPDATE') THEN
    RAISE EXCEPTION '#1095 · registrar_nota_credito_lote no toma la compra FOR SHARE antes del lote';
  END IF;

  -- 7.2 · permisos (CREATE OR REPLACE los conserva; se verifica igual)
  FOREACH v_f IN ARRAY ARRAY[
    'public.anular_compra_atomica(bigint,uuid)'::regprocedure,
    'public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)'::regprocedure,
    'public.registrar_nota_credito_lote(bigint,numeric,text,text)'::regprocedure]
  LOOP
    IF has_function_privilege('anon', v_f, 'EXECUTE')
       OR NOT has_function_privilege('authenticated', v_f, 'EXECUTE')
       OR NOT has_function_privilege('service_role', v_f, 'EXECUTE')
       OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) x
                   WHERE p.oid = v_f AND x.grantee = 0) THEN
      RAISE EXCEPTION '#1095 · permisos inesperados en %', v_f;
    END IF;
  END LOOP;

  -- 7.3 · el caso A del ensayo
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
    VALUES ('ZZ verif 1095', 100, 150, 10, v_suc) RETURNING id INTO v_prod;
    INSERT INTO compras (sucursal_id, fecha_compra, subtotal, iva, total, estado)
    VALUES (v_suc, CURRENT_DATE, 1000, 210, 1210, 'recibida') RETURNING id INTO v_compra;
    INSERT INTO compra_items (compra_id, producto_id, cantidad, costo_unitario, subtotal, sucursal_id)
    VALUES (v_compra, v_prod, 100, 10, 1000, v_suc);
    -- lote de la compra con 100 vivas, bolsa 50
    INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, compra_id, origen)
    VALUES (v_prod, v_suc, v_hoy + 60, 100, 100, v_compra, 'compra') RETURNING id INTO v_lote;

    v_res := public.registrar_nota_credito(v_compra, 'VERIF-1095', 'verificacion 1095', 0, 0, 0, NULL,
               jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 10,
                                                    'costo_unitario', 10, 'subtotal', 100)), NULL);
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION '#1095 · la nota de verificación no se registró: %', v_res;
    END IF;

    v_res := public.anular_compra_atomica(v_compra, v_admin);
    SELECT stock INTO v_stock FROM productos WHERE id = v_prod;
    SELECT cantidad_restante INTO v_rest FROM producto_lotes WHERE id = v_lote;
    SELECT estado INTO v_estado FROM compras WHERE id = v_compra;
    IF COALESCE((v_res->>'success')::boolean, false) OR v_stock <> 140
       OR v_estado <> 'recibida' OR v_rest IS DISTINCT FROM 90 THEN
      RAISE EXCEPTION '#1095 · esperaba anulación rechazada, stock 140, compra recibida, lote 90; quedó %, %, %, %',
        v_res, v_stock, v_estado, v_rest;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
  END;
END
$verif$;

COMMIT;
