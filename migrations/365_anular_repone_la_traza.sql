-- Anular repone la traza (#1142, #1073): el tope de huella de la 364 solo
-- cuando hace falta.
--
-- La 364 le puso a la huella que anular_salvedad repone por lo que habia
-- vuelto a un lote un tope v_saca (lo que efectivamente se le saco al lote),
-- para que la bajada que cae por FEFO en otro lote no deje la linea con mas
-- huella que cantidad (LOTE-D). Ese tope tambien muerde cuando NO hace falta:
--   - el lote quedo agotado o solo para la traza (mig 338) entre registrar y
--     anular, y la bolsa alcanza: v_saca es 0 y la huella repuesta queda en 0,
--     cuando el cliente tiene esas unidades de ese lote (#1073, y el comentario
--     #1085 de la propia funcion: la traza se repone entera). Es el X5 de
--     scripts/test-lotes-trazabilidad-1054-1073.sql, rojo desde la 364;
--   - el lote se vacio en parte y la bolsa alcanza: la linea de 20 quedaba con
--     17 de huella en vez de 20 (A6b del ensayo de 1140-1142).
--
-- Ahora la huella se repone DESPUES de la bajada, con el tope que de verdad
-- importa: lo que le falta a la linea para llegar a su cantidad, contando la
-- huella que la bajada le acaba de escribir por FEFO en otro lote. Con la bolsa
-- suficiente la bajada no escribe huella y la traza vuelve entera; con la bolsa
-- corta y el lote vacio, la huella del FEFO va primero y la reposicion cubre el
-- resto: linea de 20, huella 17 en L1 + 3 en L2 (A6, como la 364). El tope por
-- lote de siempre (la huella de lo que volvio no pasa lo que el lote consumio,
-- y la de #1085 se repone entera) se mantiene, ahora medido sobre el lote
-- despues de la bajada.
--
-- Salvo en un lote que quedo solo para la traza entre registrar y anular: su
-- cantidad es lo consumido al sacar el vencimiento (GREATEST(v_cons, 1)), que
-- no cuenta lo que la salvedad viva habia devuelto, y el tope por lote cortaba
-- la reposicion (lote 50/50 sin hueco: huella 1 en vez de 5). Ahi la huella se
-- trata entera como la de #1085 (con el tope de la linea) y la cantidad del
-- lote sube hasta cubrir la huella que lo apunta. No es stock: restante sigue
-- en 0 y LOTE-A/LOTE-B no se mueven.
--
-- Exposicion en prod al escribir esto: 0 salvedades anuladas (anular nunca se
-- uso). Sin backfill.
--
-- No se agrega ningun UPDATE productos.stock, no cambia ningun origen, ningun
-- GUC ni se escribe costo: STK-F, STK-D y COSTO-D no se mueven.
--
-- Parche por ancla sobre pg_get_functiondef de PROD (cada fragmento tiene que
-- aparecer exactamente una vez o la migracion aborta). Firma, SECURITY DEFINER,
-- search_path y GRANTs: como estaban (CREATE OR REPLACE conserva el ACL; la
-- seccion 2 lo compara). Ninguna funcion nueva: no hay REVOKE que hacer.

-- ---------------------------------------------------------------------------
-- 1 - Parche
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pg_temp.parchar(p_def text, p_viejo text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  IF (length(p_def) - length(replace(p_def, p_viejo, ''))) / length(p_viejo) <> 1 THEN
    RAISE EXCEPTION '%: el fragmento no aparece exactamente una vez: revisar a mano', p_que;
  END IF;
  RETURN replace(p_def, p_viejo, p_nuevo);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.contar(p_def text, p_que text)
RETURNS int LANGUAGE sql AS $fn$
  SELECT (length(p_def) - length(replace(p_def, p_que, ''))) / length(p_que);
$fn$;

CREATE TEMP TABLE t_antes AS
SELECT p.proacl::text AS acl,
       pg_temp.contar(pg_get_functiondef(p.oid), 'set_config(') AS set_config,
       pg_temp.contar(pg_get_functiondef(p.oid), 'current_setting(''app.stock_') AS current_setting,
       pg_temp.contar(pg_get_functiondef(p.oid), 'UPDATE productos') AS updates_productos
  FROM pg_proc p
 WHERE p.oid = 'public.anular_salvedad(bigint,text)'::regprocedure;

DO $anular$
DECLARE
  v_def text := pg_get_functiondef('public.anular_salvedad(bigint,text)'::regprocedure);
BEGIN
  -- 1a · lo que el loop anota para reponer despues de la bajada.
  v_def := pg_temp.parchar(v_def,
$q$  r_lote RECORD;
$q$,
$q$  r_lote RECORD;
  -- #1142 (mig 365): la huella por lote se repone despues
  -- de la bajada.
  v_rep_lote BIGINT[]  := '{}';
  v_rep_dev  INTEGER[] := '{}';
  v_rep_hue  INTEGER[] := '{}';
  v_i        INTEGER;
  v_cap      INTEGER;
  r_l        RECORD;
$q$, '1a');

  -- 1b · el loop ya no repone: anota.
  v_def := pg_temp.parchar(v_def,
$q$      -- Tope: la huella de lo que volvio a este lote no pasa lo que el lote
      -- consumio. #1085: la que el cliente perdio sin que las unidades
      -- entraran al lote (sin hueco, o solo para la traza: fueron a la bolsa)
      -- no paso por su contador, y se repone entera.
      -- #1142 (decision del dueño 2026-10-13): y la parte devuelta no pasa de
      -- lo que efectivamente se le saco al lote (v_saca). Lo que el lote ya no
      -- tiene lo cubre la bajada etiquetada de abajo: sale de la bolsa (sin
      -- huella) o por FEFO de otro lote, y ahi _consumir_lotes_fefo le escribe
      -- su propia huella a la linea (app.stock_pedido_item_id = la linea). El
      -- segundo termino del LEAST no alcanza: en un lote con consumo sin huella
      -- (lo comun) no limita nada. Escenario: bolsa 0, el lote se vacio entre
      -- registrar y anular; la linea de 20 quedaba con huella 23 (LOTE-D).
      v_huella := GREATEST(LEAST(
        LEAST(r_lote.huella, r_lote.devuelto, v_saca),
        (r_lote.cantidad - (r_lote.cantidad_restante - v_saca))
          - (SELECT COALESCE(SUM(cantidad), 0)::int FROM pedido_item_lotes WHERE lote_id = r_lote.id)), 0)
        + GREATEST(r_lote.huella - r_lote.devuelto, 0);
      IF v_huella > 0 AND v_item_id IS NOT NULL THEN
        INSERT INTO pedido_item_lotes (pedido_item_id, lote_id, cantidad, sucursal_id)
        VALUES (v_item_id, r_lote.id, v_huella, v_sucursal)
        ON CONFLICT (pedido_item_id, lote_id)
          DO UPDATE SET cantidad = pedido_item_lotes.cantidad + EXCLUDED.cantidad;
      END IF;
    END LOOP;
$q$,
$q$      -- La huella de este lote se repone despues de la bajada (abajo), en el
      -- mismo orden FEFO.
      v_rep_lote := v_rep_lote || r_lote.id;
      v_rep_dev  := v_rep_dev  || r_lote.devuelto;
      v_rep_hue  := v_rep_hue  || r_lote.huella;
    END LOOP;
$q$, '1b');

  -- 1c · la reposicion, despues de la bajada y antes de restaurar los GUCs.
  v_def := pg_temp.parchar(v_def,
$q$      UPDATE productos SET stock = stock - v_salvedad.cantidad_afectada
       WHERE id = v_salvedad.producto_id AND sucursal_id = v_sucursal;
    END IF;
$q$,
$q$      UPDATE productos SET stock = stock - v_salvedad.cantidad_afectada
       WHERE id = v_salvedad.producto_id AND sucursal_id = v_sucursal;
    END IF;

    /* #1142 / #1073 (mig 365): la huella que la devolucion
       le saco al cliente en cada lote se le repone a la linea restituida.
       Va DESPUES de la bajada para saber cuanto le falta a la linea: si la
       bolsa no alcanzo, la bajada cayo por FEFO en otro lote y
       _consumir_lotes_fefo ya le escribio huella ahi (la linea va en
       app.stock_pedido_item_id). Esa va primero, y la reposicion cubre lo que
       falta hasta la cantidad de la linea: nunca la supera (LOTE-D).
       Con la bolsa suficiente la bajada no escribe huella y la traza vuelve
       entera, tambien si el lote quedo agotado o solo para la traza entre
       registrar y anular (el cliente tiene esas unidades de ese lote; salen
       de la bolsa). La 364 topaba con lo que se le saco al lote (v_saca) y en
       ese caso la dejaba en 0.
       Tope por lote, el de siempre, medido despues de la bajada: la huella de
       lo que volvio a este lote no pasa lo que el lote consumio. #1085: la
       que el cliente perdio sin que las unidades entraran al lote (sin hueco,
       o solo para la traza: fueron a la bolsa) no paso por su contador, y se
       repone entera. Un lote que quedo solo para la traza despues de
       registrar no tiene contador que mirar: ver abajo. */
    v_cap := GREATEST(
      COALESCE((SELECT cantidad FROM pedido_items WHERE id = v_item_id), 0)
      - (SELECT COALESCE(SUM(cantidad), 0)::int FROM pedido_item_lotes WHERE pedido_item_id = v_item_id), 0);
    FOR v_i IN 1 .. COALESCE(array_length(v_rep_lote, 1), 0) LOOP
      SELECT cantidad, cantidad_restante, solo_traza INTO r_l FROM producto_lotes WHERE id = v_rep_lote[v_i];
      IF r_l.solo_traza THEN
        /* Lote solo para la traza (mig 338): sus unidades vivas, tambien las
           que esta salvedad le habia devuelto, pasaron a la bolsa cuando se
           saco su vencimiento, y su cantidad quedo en lo consumido en ese
           momento, sin contar lo que la salvedad viva habia devuelto. Su
           contador no dice nada de esta huella: toda ella se trata como la de
           #1085 y se repone entera (con el tope de la linea), y la cantidad del
           lote sube hasta cubrir la huella que lo apunta (es lo que salio de
           el), para que si el vencimiento vuelve a cargarse lo consumido la
           incluya. Restante sigue en 0. */
        v_huella := LEAST(v_rep_hue[v_i], v_cap);
      ELSE
        v_huella := LEAST(
          GREATEST(LEAST(
            LEAST(v_rep_hue[v_i], v_rep_dev[v_i]),
            (r_l.cantidad - r_l.cantidad_restante)
              - (SELECT COALESCE(SUM(cantidad), 0)::int FROM pedido_item_lotes WHERE lote_id = v_rep_lote[v_i])), 0)
            + GREATEST(v_rep_hue[v_i] - v_rep_dev[v_i], 0),
          v_cap);
      END IF;
      IF v_huella > 0 AND v_item_id IS NOT NULL THEN
        INSERT INTO pedido_item_lotes (pedido_item_id, lote_id, cantidad, sucursal_id)
        VALUES (v_item_id, v_rep_lote[v_i], v_huella, v_sucursal)
        ON CONFLICT (pedido_item_id, lote_id)
          DO UPDATE SET cantidad = pedido_item_lotes.cantidad + EXCLUDED.cantidad;
        v_cap := v_cap - v_huella;
        IF r_l.solo_traza THEN
          UPDATE producto_lotes
             SET cantidad = GREATEST(cantidad,
                   (SELECT COALESCE(SUM(cantidad), 0)::int FROM pedido_item_lotes WHERE lote_id = v_rep_lote[v_i]))
           WHERE id = v_rep_lote[v_i];
        END IF;
      END IF;
    END LOOP;
$q$, '1c');

  EXECUTE v_def;
END
$anular$;

DROP FUNCTION pg_temp.parchar(text, text, text, text);

-- ---------------------------------------------------------------------------
-- 2 - Verificacion estructural
-- ---------------------------------------------------------------------------

DO $verif$
DECLARE
  v_anu text := pg_get_functiondef('public.anular_salvedad(bigint,text)'::regprocedure);
  v_a   record;
  v_aud jsonb;
BEGIN
  SELECT * INTO v_a FROM t_antes;

  -- Sigue SECURITY DEFINER (pedido_items_guard_estado depende de eso), sin el
  -- tope v_saca, y la reposicion va despues de la bajada.
  IF v_anu NOT LIKE '%SECURITY DEFINER%'
     OR position('v_saca),' IN v_anu) > 0
     OR position('r_lote.huella - r_lote.devuelto' IN v_anu) > 0
     OR pg_temp.contar(v_anu, 'INSERT INTO pedido_item_lotes') <> 1
     OR position('GREATEST(v_rep_hue[v_i] - v_rep_dev[v_i], 0)' IN v_anu) = 0
     OR position('v_huella := LEAST(v_rep_hue[v_i], v_cap);' IN v_anu) = 0
     OR pg_temp.contar(v_anu, 'IF r_l.solo_traza THEN') <> 2
     OR position('INSERT INTO pedido_item_lotes' IN v_anu)
        < position('stock = stock - v_salvedad.cantidad_afectada' IN v_anu)
     OR position('INSERT INTO pedido_item_lotes' IN v_anu)
        > position('set_config(''app.stock_pedido_item_id'', COALESCE(v_g_item' IN v_anu)
     OR position('cantidad = cantidad + v_salvedad.cantidad_afectada' IN v_anu) = 0
     OR position('''salvedad_anulada''' IN v_anu) = 0 THEN
    RAISE EXCEPTION 'anular_salvedad no quedo como se esperaba';
  END IF;

  -- Los GUCs de stock y las bajadas: los mismos que antes (STK-F, STK-D).
  IF pg_temp.contar(v_anu, 'set_config(') <> v_a.set_config
     OR pg_temp.contar(v_anu, 'current_setting(''app.stock_') <> v_a.current_setting
     OR pg_temp.contar(v_anu, 'UPDATE productos') <> v_a.updates_productos THEN
    RAISE EXCEPTION 'anular_salvedad cambio sus GUCs o sus UPDATE de productos';
  END IF;

  -- ACL identico; nada para PUBLIC ni anon; authenticated conserva EXECUTE.
  IF v_a.acl IS DISTINCT FROM (SELECT proacl::text FROM pg_proc
                                WHERE oid = 'public.anular_salvedad(bigint,text)'::regprocedure) THEN
    RAISE EXCEPTION 'el ACL de anular_salvedad cambio';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) x
              WHERE p.oid = 'public.anular_salvedad(bigint,text)'::regprocedure
                AND (x.grantee = 0 OR x.grantee = 'anon'::regrole))
     OR NOT has_function_privilege('authenticated', 'public.anular_salvedad(bigint,text)'::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'anular_salvedad quedo alcanzable por PUBLIC/anon o perdio authenticated';
  END IF;

  -- Una sola sobrecarga (PGRST203).
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
         AND proname = 'anular_salvedad') <> 1 THEN
    RAISE EXCEPTION 'hay mas de una sobrecarga de anular_salvedad';
  END IF;

  -- LOTE-D en high y en 0.
  v_aud := public.auditoria_integridad();
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_aud->'checks') x
                  WHERE x->>'id' = 'LOTE-D' AND x->>'severidad' = 'high'
                    AND (x->>'violaciones')::int = 0) THEN
    RAISE EXCEPTION 'LOTE-D no esta en high o no da 0';
  END IF;
END
$verif$;

DROP TABLE t_antes;
DROP FUNCTION pg_temp.contar(text, text);
