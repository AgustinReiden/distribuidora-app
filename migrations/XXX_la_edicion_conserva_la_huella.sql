-- La edicion conserva la huella (#1097) y una cantidad invalida se rechaza (#1094)
--
-- #1097: los caminos que deshacen lineas y las rehacen -- editar un pedido
-- (actualizar_pedido_items), sustituir un regalo (sustituir_regalo_pedido) y
-- repartirlo (dividir_regalo_pedido) -- devolvian lo viejo con un origen de la
-- lista blanca y a nivel PEDIDO (sin la linea en app.stock_pedido_item_id), y
-- volvian a bajar sin la linea. Medido en prod con
-- scripts/test-huella-edicion-1094-1097.sql:
--   - editar sin cambios una linea de 20 = 5 de la bolsa + 15 de L1 dejaba
--     L1 +15 y la bolsa -15, y la linea nueva SIN huella (E1). Una linea que
--     salio entera de la bolsa volvia por FEFO a otro lote (E1b).
--   - sustituir o repartir el regalo R le comia la huella a OTRA linea del
--     mismo producto (la X: "ORDER BY pil.id" del descuento a nivel pedido),
--     y bajaba el sustituto antes de que la linea lo tuviera, asi que el
--     guard de _consumir_lotes_fefo no anotaba nada (E8, E9).
--   - el bot no seteaba la linea: sus pedidos nunca dejaban huella (E11).
--
-- Decision del dueño (2026-10-10, opcion C): es el corolario de CLAUDE.md "la
-- devolucion que se cancela sola NO va etiquetada". La devolucion de una
-- edicion se cancela con la bajada que viene despues, asi que va a la BOLSA
-- (origen fuera de la lista blanca, con ref=pedido para STK-D); la bajada lleva
-- su linea, y al final _rehacer_huella_lineas conserva la huella que la
-- cantidad nueva sigue cubriendo y devuelve el resto a su lote, primero el que
-- vence antes (lo mismo que una salvedad por la diferencia: 338/342). Primero
-- por linea de origen (bonif, promo, cadena): una linea que no cambio conserva
-- su huella entera aunque otra del mismo producto baje, aun con un solo lote
-- (E4c). El sobrante, por producto: no depende de emparejar renglones viejos
-- con nuevos (fusionados, reordenados, con otra cadena) ni toca la huella de
-- las otras lineas del pedido. Lo devuelto de una linea SIN huella va a la bolsa:
-- desde la 256 toda bajada con linea deja huella, asi que esa linea salio de
-- la bolsa (y hay 0 pedidos editables anteriores a la 256 con lotes).
--
-- #1094: actualizar_pedido_items aceptaba, al lado de un renglon valido, uno
-- en 0 o negativo (el -1 SUBIA el stock), y una fraccion reventaba con un
-- 22P02 crudo en el ::INT. Ahora cada renglon, regalos incluidos, tiene que
-- ser un entero de 1 en adelante, con el mensaje de crear_pedido_completo. Y
-- un CHECK (cantidad > 0) en pedido_items: hay 0 filas que lo violen y ningun
-- camino escribe 0 a proposito. sustituir_regalo_pedido aceptaba fracciones:
-- la linea (INTEGER) redondeaba para un lado y la bajada de stock para el otro
-- (2,5 dejaba la linea en 3 y bajaba 2; 0,5 dejaba 1 y no bajaba nada). Ahora
-- rechaza lo que no sea entero, como ya hacia dividir_regalo_pedido (E8c).
--
-- Funciones parcheadas en vivo sobre pg_get_functiondef (cada fragmento tiene
-- que aparecer exactamente una vez o la migracion aborta). Firmas, SECURITY
-- DEFINER y GRANTs: como estaban. Dos helpers nuevos de servidor, revocados a
-- PUBLIC, anon y authenticated. No tocan productos.stock (solo lotes y huella),
-- asi que STK-F y STK-D no los miran.

-- ---------------------------------------------------------------------------
-- 1 - Helpers
-- ---------------------------------------------------------------------------

-- La huella de unas lineas, por producto, tomada ANTES de deshacerlas:
-- [{prod, suc, cant: suma de las cantidades,
--   claves: [{clave, cant}]: la cantidad vieja por linea de origen,
--   lotes: [{lote, cant, solo_traza, venc, clave, bonif, promo, cadena}]}].
-- La clave de una linea de origen es (bonif, promo, cadena), en texto: con
-- ella _rehacer_huella_lineas conserva primero la huella de cada linea en la
-- linea nueva que la sucede. El caller pasa solo las lineas que mueven stock
-- (no regalo, o regalo de modo A).
CREATE OR REPLACE FUNCTION public._foto_huella_lineas(p_lineas bigint[])
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  WITH li AS (
    SELECT pi.id, pi.producto_id, pi.sucursal_id, pi.cantidad,
           COALESCE(pi.es_bonificacion, false) AS bonif, pi.promocion_id AS promo,
           pi.regalo_cadena_id AS cadena,
           COALESCE(pi.es_bonificacion, false)::text || '|' || COALESCE(pi.promocion_id::text, '')
             || '|' || COALESCE(pi.regalo_cadena_id::text, '') AS clave
      FROM public.pedido_items pi
     WHERE pi.id = ANY(p_lineas) AND pi.producto_id IS NOT NULL)
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'prod', c.producto_id, 'suc', c.sucursal_id, 'cant', c.cant,
           'claves', (SELECT jsonb_agg(jsonb_build_object('clave', k.clave, 'cant', k.cant) ORDER BY k.clave)
                        FROM (SELECT li.clave, SUM(li.cantidad)::int AS cant
                                FROM li
                               WHERE li.producto_id = c.producto_id AND li.sucursal_id = c.sucursal_id
                               GROUP BY li.clave) k),
           'lotes', COALESCE((
             SELECT jsonb_agg(jsonb_build_object(
                      'lote', pil.lote_id, 'cant', pil.cantidad, 'solo_traza', l.solo_traza,
                      'venc', l.fecha_vencimiento, 'clave', li.clave,
                      'bonif', li.bonif, 'promo', li.promo, 'cadena', li.cadena)
                    ORDER BY l.fecha_vencimiento DESC, l.id DESC, pil.id)
               FROM public.pedido_item_lotes pil
               JOIN li
                 ON li.id = pil.pedido_item_id AND li.sucursal_id = pil.sucursal_id
               JOIN public.producto_lotes l
                 ON l.id = pil.lote_id AND l.sucursal_id = pil.sucursal_id
              WHERE li.producto_id = c.producto_id
                AND li.sucursal_id = c.sucursal_id
                AND l.producto_id = c.producto_id), '[]'::jsonb))
         ORDER BY c.producto_id), '[]'::jsonb)
    FROM (SELECT li.producto_id, li.sucursal_id, SUM(li.cantidad)::int AS cant
            FROM li
           GROUP BY li.producto_id, li.sucursal_id) c;
$fn$;

-- Rehace la huella despues de deshacer y rehacer lineas (#1097).
--
-- Precondicion: la devolucion de las lineas viejas fue SIN etiquetar (cayo en
-- la bolsa) y su huella se borro, asi que los lotes siguen con la huella vieja
-- descontada; la bajada de las lineas nuevas ya corrio con su linea en
-- app.stock_pedido_item_id (lo que paso a FEFO ya dejo huella nueva).
--
-- La regla es la de una salvedad por la diferencia (338/342), POR LINEA: una
-- linea que baja de Q a q devuelve primero lo del lote, asi que conserva
-- R = max(0, H - max(0, Q - q)) de su huella H; dentro de la huella vuelve
-- primero el lote que vence antes (la pasada 1 de _restaurar_lotes_fefo va
-- ASC) y se conservan los que vencen despues.
--   Pasada 1, por linea de origen: con la clave (bonif, promo, cadena), H, Q y
--     q son los de esa clave (q, de las lineas nuevas con la misma clave, ya
--     con la sustitucion aplicada), y lo conservado se re-anota en ESAS lineas
--     nuevas. Asi una linea que no cambio conserva su huella entera aunque
--     otra del mismo producto baje (sin esta pasada, la primera entrada de la
--     foto se llevaba todo y la intacta podia quedar en 0, aun con un solo lote).
--   Pasada 2, el sobrante por producto: con H, Q y q de todo el producto se
--     conserva en total max(R del producto, suma de los R por clave), y lo que
--     la pasada 1 no anoto (renglones fusionados, una cadena nueva, una linea
--     que cambio de clave, o sin capacidad) se re-anota en cualquier linea
--     nueva del producto, prefiriendo la misma clave.
--   Al final, lo que no se conservo vuelve a su lote hasta donde haya hueco.
-- Nunca mas huella que cantidad en una linea (capacidad = cantidad - huella).
-- La bolsa es derivada (stock - suma de restantes): baja sola. Un lote
-- solo_traza no recibe unidades -- ya estan en la bolsa --, pero lo
-- conservado se re-anota igual. Un lote que ya no existe no tiene a donde
-- volver ni que anotar: sus unidades quedan en la bolsa.
CREATE OR REPLACE FUNCTION public._rehacer_huella_lineas(p_foto jsonb, p_lineas bigint[])
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  e          jsonb;
  c          jsonb;
  v_prod     bigint;
  v_suc      bigint;
  v_lineas   bigint[] := COALESCE(p_lineas, '{}');
  v_lote     bigint[];
  v_cant     integer[];
  v_clave    text[];
  v_bonif    boolean[];
  v_promo    bigint[];
  v_cadena   uuid[];
  v_existe   boolean[];
  v_solo     boolean[];
  v_usado    integer[];
  n          integer;
  i          integer;
  v_h        integer;
  v_q_viejo  integer;
  v_q_nuevo  integer;
  v_h_k      integer;
  v_q_k      integer;
  v_qn_k     integer;
  v_r_k      integer;
  v_suma_k   integer;
  v_anot_1   integer;
  v_resto    integer;
  v_k        integer;
  v_anotado  integer;
  v_pone     integer;
  v_r        integer;
  v_lin      record;
BEGIN
  FOR e IN SELECT * FROM jsonb_array_elements(COALESCE(p_foto, '[]'::jsonb)) LOOP
    v_prod    := (e->>'prod')::bigint;
    v_suc     := (e->>'suc')::bigint;
    v_q_viejo := COALESCE((e->>'cant')::integer, 0);

    SELECT array_agg((y->>'lote')::bigint   ORDER BY (y->>'venc')::date DESC, (y->>'lote')::bigint DESC, o),
           array_agg((y->>'cant')::integer  ORDER BY (y->>'venc')::date DESC, (y->>'lote')::bigint DESC, o),
           array_agg(y->>'clave'            ORDER BY (y->>'venc')::date DESC, (y->>'lote')::bigint DESC, o),
           array_agg((y->>'bonif')::boolean ORDER BY (y->>'venc')::date DESC, (y->>'lote')::bigint DESC, o),
           array_agg((y->>'promo')::bigint  ORDER BY (y->>'venc')::date DESC, (y->>'lote')::bigint DESC, o),
           array_agg((y->>'cadena')::uuid   ORDER BY (y->>'venc')::date DESC, (y->>'lote')::bigint DESC, o)
      INTO v_lote, v_cant, v_clave, v_bonif, v_promo, v_cadena
      FROM jsonb_array_elements(COALESCE(e->'lotes', '[]'::jsonb)) WITH ORDINALITY AS t(y, o);
    n := COALESCE(cardinality(v_lote), 0);
    CONTINUE WHEN n = 0;
    SELECT COALESCE(SUM(x), 0) INTO v_h FROM unnest(v_cant) x;
    CONTINUE WHEN v_h <= 0;

    -- Los lotes, bloqueados en un orden fijo, y como estan ahora.
    PERFORM 1 FROM public.producto_lotes l
      WHERE l.id = ANY(v_lote) AND l.sucursal_id = v_suc
      ORDER BY l.id FOR UPDATE;
    SELECT array_agg(l.id IS NOT NULL ORDER BY s.i), array_agg(COALESCE(l.solo_traza, false) ORDER BY s.i)
      INTO v_existe, v_solo
      FROM generate_subscripts(v_lote, 1) AS s(i)
      LEFT JOIN public.producto_lotes l ON l.id = v_lote[s.i] AND l.sucursal_id = v_suc;
    v_usado := array_fill(0, ARRAY[n]);

    SELECT COALESCE(SUM(pi.cantidad), 0)::integer INTO v_q_nuevo
      FROM public.pedido_items pi
     WHERE pi.id = ANY(v_lineas) AND pi.producto_id = v_prod AND pi.sucursal_id = v_suc;

    -- Pasada 1: por linea de origen.
    v_suma_k := 0;
    v_anot_1 := 0;
    FOR c IN SELECT * FROM jsonb_array_elements(COALESCE(e->'claves', '[]'::jsonb)) LOOP
      SELECT COALESCE(SUM(v_cant[s.i]), 0) INTO v_h_k
        FROM generate_subscripts(v_cant, 1) AS s(i)
       WHERE v_clave[s.i] = c->>'clave';
      CONTINUE WHEN v_h_k <= 0;
      v_q_k := COALESCE((c->>'cant')::integer, 0);
      SELECT COALESCE(SUM(pi.cantidad), 0)::integer INTO v_qn_k
        FROM public.pedido_items pi
       WHERE pi.id = ANY(v_lineas) AND pi.producto_id = v_prod AND pi.sucursal_id = v_suc
         AND COALESCE(pi.es_bonificacion, false)::text || '|' || COALESCE(pi.promocion_id::text, '')
               || '|' || COALESCE(pi.regalo_cadena_id::text, '') = c->>'clave';
      v_r_k := GREATEST(0, v_h_k - GREATEST(0, v_q_k - v_qn_k));
      v_suma_k := v_suma_k + v_r_k;

      FOR i IN 1..n LOOP
        EXIT WHEN v_r_k <= 0;
        CONTINUE WHEN v_clave[i] IS DISTINCT FROM c->>'clave' OR NOT v_existe[i];
        v_k := LEAST(v_r_k, v_cant[i] - v_usado[i]);
        CONTINUE WHEN v_k <= 0;
        v_anotado := 0;
        FOR v_lin IN
          SELECT pi.id,
                 pi.cantidad - COALESCE((SELECT SUM(pil.cantidad) FROM public.pedido_item_lotes pil
                                          WHERE pil.pedido_item_id = pi.id), 0) AS cap
            FROM public.pedido_items pi
           WHERE pi.id = ANY(v_lineas) AND pi.producto_id = v_prod AND pi.sucursal_id = v_suc
             AND COALESCE(pi.es_bonificacion, false)::text || '|' || COALESCE(pi.promocion_id::text, '')
                   || '|' || COALESCE(pi.regalo_cadena_id::text, '') = c->>'clave'
           ORDER BY pi.id
        LOOP
          EXIT WHEN v_anotado >= v_k;
          v_pone := LEAST(v_k - v_anotado, v_lin.cap);
          CONTINUE WHEN v_pone <= 0;
          INSERT INTO public.pedido_item_lotes (pedido_item_id, lote_id, cantidad, sucursal_id)
          VALUES (v_lin.id, v_lote[i], v_pone, v_suc)
          ON CONFLICT (pedido_item_id, lote_id)
            DO UPDATE SET cantidad = pedido_item_lotes.cantidad + EXCLUDED.cantidad;
          v_anotado := v_anotado + v_pone;
        END LOOP;
        v_usado[i] := v_usado[i] + v_anotado;
        v_r_k      := v_r_k - v_anotado;
        v_anot_1   := v_anot_1 + v_anotado;
      END LOOP;
    END LOOP;

    -- Pasada 2: el sobrante, por producto.
    v_resto := GREATEST(GREATEST(0, v_h - GREATEST(0, v_q_viejo - v_q_nuevo)), v_suma_k) - v_anot_1;
    FOR i IN 1..n LOOP
      EXIT WHEN v_resto <= 0;
      CONTINUE WHEN NOT v_existe[i];
      v_k := LEAST(v_resto, v_cant[i] - v_usado[i]);
      CONTINUE WHEN v_k <= 0;
      v_anotado := 0;
      FOR v_lin IN
        SELECT pi.id,
               pi.cantidad - COALESCE((SELECT SUM(pil.cantidad) FROM public.pedido_item_lotes pil
                                        WHERE pil.pedido_item_id = pi.id), 0) AS cap
          FROM public.pedido_items pi
         WHERE pi.id = ANY(v_lineas) AND pi.producto_id = v_prod AND pi.sucursal_id = v_suc
         ORDER BY (COALESCE(pi.es_bonificacion, false) = v_bonif[i]
                   AND pi.promocion_id IS NOT DISTINCT FROM v_promo[i]
                   AND pi.regalo_cadena_id IS NOT DISTINCT FROM v_cadena[i]) DESC,
                  (COALESCE(pi.es_bonificacion, false) = v_bonif[i]
                   AND pi.promocion_id IS NOT DISTINCT FROM v_promo[i]) DESC,
                  pi.id
      LOOP
        EXIT WHEN v_anotado >= v_k;
        v_pone := LEAST(v_k - v_anotado, v_lin.cap);
        CONTINUE WHEN v_pone <= 0;
        INSERT INTO public.pedido_item_lotes (pedido_item_id, lote_id, cantidad, sucursal_id)
        VALUES (v_lin.id, v_lote[i], v_pone, v_suc)
        ON CONFLICT (pedido_item_id, lote_id)
          DO UPDATE SET cantidad = pedido_item_lotes.cantidad + EXCLUDED.cantidad;
        v_anotado := v_anotado + v_pone;
      END LOOP;
      v_usado[i] := v_usado[i] + v_anotado;
      v_resto    := v_resto - v_anotado;
    END LOOP;

    -- Lo que no se conservo vuelve a su lote.
    FOR i IN 1..n LOOP
      v_r := v_cant[i] - v_usado[i];
      CONTINUE WHEN v_r <= 0 OR NOT v_existe[i] OR v_solo[i];
      UPDATE public.producto_lotes
         SET cantidad_restante = cantidad_restante + LEAST(v_r, cantidad - cantidad_restante)
       WHERE id = v_lote[i] AND sucursal_id = v_suc;
    END LOOP;
  END LOOP;
END
$fn$;

REVOKE ALL ON FUNCTION public._foto_huella_lineas(bigint[]) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._rehacer_huella_lineas(jsonb, bigint[]) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2 - Parches
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

-- 2a · actualizar_pedido_items
DO $actualizar$
DECLARE
  v_def text := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.parchar(v_def,
$q$  v_cadena       UUID;
  v_clave_desc   TEXT;
BEGIN
$q$,
$q$  v_cadena       UUID;
  v_clave_desc   TEXT;
  -- #1097: la huella de las lineas que se rehacen, las lineas nuevas que
  -- mueven stock y el GUC de linea del caller (por transaccion: 229).
  v_foto         JSONB;
  v_lineas_stock BIGINT[] := '{}';
  v_item_guc     TEXT;
  -- #1094: el producto del primer renglon con una cantidad invalida.
  v_cant_invalida TEXT;
BEGIN
$q$, 'actualizar 3a');

  v_def := pg_temp.parchar(v_def,
$q$      'El pedido tiene que conservar al menos un producto que no sea regalo. Si ya no va, cancelalo.']);
  END IF;
$q$,
$q$      'El pedido tiene que conservar al menos un producto que no sea regalo. Si ya no va, cancelalo.']);
  END IF;

  -- #1094: cada renglon, regalos incluidos, con una cantidad entera de 1 en
  -- adelante. Al lado de uno valido pasaban el 0 y el negativo (el -1 subia el
  -- stock), y una fraccion reventaba con un 22P02 crudo en el ::INT de abajo.
  -- El mismo mensaje que crear_pedido_completo. El CASE no es un adorno: SQL no
  -- garantiza el orden de un OR, y el cast de un texto que no es numero tira.
  SELECT COALESCE(e->>'producto_id', '?') INTO v_cant_invalida
    FROM jsonb_array_elements(p_items_nuevos) WITH ORDINALITY AS x(e, o)
   WHERE CASE WHEN COALESCE(e->>'cantidad', '') ~ '^[0-9]{1,10}$'
              THEN (e->>'cantidad')::NUMERIC NOT BETWEEN 1 AND 2147483647
              ELSE true END
   ORDER BY o
   LIMIT 1;
  IF v_cant_invalida IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY[
      'Cantidad invalida para producto ID ' || v_cant_invalida]);
  END IF;
$q$, 'actualizar 3b');

  v_def := pg_temp.parchar(v_def,
$q$  -- mig 338 (#1083): sumado por producto. UPDATE ... FROM con dos lineas del
$q$,
$q$  -- #1097: la devolucion de abajo se cancela con la bajada de las lineas
  -- nuevas, asi que va SIN etiquetar (pedido_editado no esta en la lista
  -- blanca de trg_lotes_sincronizar): todo cae en la bolsa y los lotes quedan
  -- con la huella vieja descontada. La bajada lleva su linea, y al final
  -- _rehacer_huella_lineas conserva lo que la cantidad nueva sigue cubriendo
  -- (por linea de origen; el sobrante, por producto) y devuelve el resto a su
  -- lote. Antes iba con
  -- 'pedido_creado' a nivel pedido: lo que salio de la bolsa volvia a un lote
  -- y el DELETE de abajo se llevaba la huella. La foto, antes de tocar nada,
  -- con el mismo predicado que los dos UPDATE.
  SELECT public._foto_huella_lineas(array_agg(pi.id)) INTO v_foto
    FROM pedido_items pi
    LEFT JOIN promociones pr ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
   WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
     AND (NOT COALESCE(pi.es_bonificacion, false)
          OR (pi.promocion_id IS NOT NULL AND COALESCE(pr.regalo_mueve_stock, FALSE)));
  PERFORM set_config('app.stock_origen', 'pedido_editado', true);

  -- mig 338 (#1083): sumado por producto. UPDATE ... FROM con dos lineas del
$q$, 'actualizar 3c foto');

  v_def := pg_temp.parchar(v_def,
$q$  -- mig 294 (#840): por (promo, SABOR), contra la barra de ese sabor.
$q$,
$q$  -- #1097: de aca para abajo, el origen de siempre (el acumulador y las
  -- bajadas).
  PERFORM set_config('app.stock_origen', 'pedido_creado', true);

  -- mig 294 (#840): por (promo, SABOR), contra la barra de ese sabor.
$q$, 'actualizar 3c origen');

  v_def := pg_temp.parchar(v_def,
$q$      UPDATE productos SET stock = stock - v_cantidad_nueva WHERE id = v_producto_guardado AND sucursal_id = v_sucursal;
$q$,
$q$      -- #1097: la bajada con SU linea: lo que pase a FEFO deja huella. Se
      -- guarda y se restaura (por transaccion: 229).
      v_item_guc := current_setting('app.stock_pedido_item_id', true);
      PERFORM set_config('app.stock_pedido_item_id', v_pedido_item_guardado::text, true);
      UPDATE productos SET stock = stock - v_cantidad_nueva WHERE id = v_producto_guardado AND sucursal_id = v_sucursal;
      PERFORM set_config('app.stock_pedido_item_id', COALESCE(v_item_guc, ''), true);
      v_lineas_stock := v_lineas_stock || v_pedido_item_guardado;
$q$, 'actualizar 3d linea');

  v_def := pg_temp.parchar(v_def,
$q$        UPDATE productos SET stock = stock - v_cantidad_guardada WHERE id = v_producto_guardado AND sucursal_id = v_sucursal;
$q$,
$q$        -- #1097: idem, y restaurado ANTES del acumulador: la merma del
        -- contenedor del mismo producto no es huella de esta linea.
        v_item_guc := current_setting('app.stock_pedido_item_id', true);
        PERFORM set_config('app.stock_pedido_item_id', v_pedido_item_guardado::text, true);
        UPDATE productos SET stock = stock - v_cantidad_guardada WHERE id = v_producto_guardado AND sucursal_id = v_sucursal;
        PERFORM set_config('app.stock_pedido_item_id', COALESCE(v_item_guc, ''), true);
        v_lineas_stock := v_lineas_stock || v_pedido_item_guardado;
$q$, 'actualizar 3d regalo');

  v_def := pg_temp.parchar(v_def,
$q$  UPDATE pedidos SET total = v_total_nuevo, total_neto = round(v_total_neto_nuevo, 2)$q$,
$q$  -- #1097: la huella vieja sobre las lineas nuevas (ver arriba).
  IF v_foto IS NOT NULL THEN
    PERFORM public._rehacer_huella_lineas(v_foto, v_lineas_stock);
  END IF;

  UPDATE pedidos SET total = v_total_nuevo, total_neto = round(v_total_neto_nuevo, 2)$q$, 'actualizar 3e');

  EXECUTE v_def;
END
$actualizar$;

-- 2b · sustituir_regalo_pedido
DO $sustituir$
DECLARE
  v_def text := pg_get_functiondef('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.parchar(v_def,
$q$  v_cadena             UUID;
BEGIN
$q$,
$q$  v_cadena             UUID;
  -- #1097: la huella de la linea antes de deshacerla y el GUC de linea del
  -- caller (por transaccion: 229).
  v_foto               JSONB;
  v_item_guc           TEXT;
BEGIN
$q$, 'sustituir declare');

  v_def := pg_temp.parchar(v_def,
$q$    RETURN jsonb_build_object('success', false, 'error', 'La cantidad sustituta debe ser mayor a 0');
  END IF;
$q$,
$q$    RETURN jsonb_build_object('success', false, 'error', 'La cantidad sustituta debe ser mayor a 0');
  END IF;
  -- #1094: solo enteros. La linea es INTEGER y redondeaba la fraccion para un
  -- lado mientras la bajada de stock la redondeaba para el otro (2,5: linea 3,
  -- stock -2; 0,5: linea 1, stock sin mover). Como dividir_regalo_pedido.
  IF p_cantidad_nueva <> trunc(p_cantidad_nueva) THEN
    RETURN jsonb_build_object('success', false, 'error', 'La cantidad sustituta tiene que ser un numero entero');
  END IF;
$q$, 'sustituir cantidad');

  v_def := pg_temp.parchar(v_def,
$q$    UPDATE productos SET stock = stock + v_item.cantidad WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
    UPDATE productos SET stock = stock - p_cantidad_nueva WHERE id = p_producto_nuevo_id AND sucursal_id = v_sucursal;
$q$,
$q$    -- #1097: la devolucion del original se cancela con la bajada del
    -- sustituto (y con P -> P, literalmente): va SIN etiquetar, a la bolsa, y
    -- _rehacer_huella_lineas devuelve a su lote lo que la linea ya no cubre.
    -- Antes iba a nivel pedido y le comia la huella a otra linea del mismo
    -- producto. La bajada va abajo, cuando la linea ya tiene el producto nuevo
    -- (el guard de _consumir_lotes_fefo).
    v_foto := public._foto_huella_lineas(ARRAY[p_pedido_item_id]);
    DELETE FROM pedido_item_lotes WHERE pedido_item_id = p_pedido_item_id AND sucursal_id = v_sucursal;
    PERFORM set_config('app.stock_origen', 'sustitucion_regalo_rehecha', true);
    UPDATE productos SET stock = stock + v_item.cantidad WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
    PERFORM set_config('app.stock_origen', 'sustitucion_regalo', true);
$q$, 'sustituir devolucion');

  v_def := pg_temp.parchar(v_def,
$q$   WHERE id = p_pedido_item_id;
  INSERT INTO pedido_item_sustituciones (
$q$,
$q$   WHERE id = p_pedido_item_id;
  -- #1097: la bajada del sustituto con la linea, que ya es del producto
  -- nuevo, y la huella vieja rehecha (ver arriba).
  IF v_regalo_mueve_stock THEN
    v_item_guc := current_setting('app.stock_pedido_item_id', true);
    PERFORM set_config('app.stock_pedido_item_id', p_pedido_item_id::text, true);
    UPDATE productos SET stock = stock - p_cantidad_nueva WHERE id = p_producto_nuevo_id AND sucursal_id = v_sucursal;
    PERFORM set_config('app.stock_pedido_item_id', COALESCE(v_item_guc, ''), true);
    PERFORM public._rehacer_huella_lineas(v_foto, ARRAY[p_pedido_item_id]);
  END IF;
  INSERT INTO pedido_item_sustituciones (
$q$, 'sustituir bajada');

  EXECUTE v_def;
END
$sustituir$;

-- 2c · dividir_regalo_pedido
DO $dividir$
DECLARE
  v_def text := pg_get_functiondef('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.parchar(v_def,
$q$  v_cant               NUMERIC[];
BEGIN
$q$,
$q$  v_cant               NUMERIC[];
  -- #1097: la huella de la linea antes de repartirla, la parte de cada
  -- producto y el GUC de linea del caller (por transaccion: 229).
  v_foto               JSONB;
  v_linea_parte        BIGINT;
  v_item_guc           TEXT;
BEGIN
$q$, 'dividir declare');

  v_def := pg_temp.parchar(v_def,
$q$    PERFORM set_config('app.stock_user_id', v_user_id::TEXT, true);
    FOR v_neto IN SELECT producto_id, consumo
$q$,
$q$    PERFORM set_config('app.stock_user_id', v_user_id::TEXT, true);
    -- #1097: aca solo la devolucion del neto, SIN etiquetar (a la bolsa): se
    -- cancela con las bajadas de las partes, que van abajo con su linea, y
    -- _rehacer_huella_lineas devuelve a su lote lo que las partes ya no
    -- cubren. Antes iba a nivel pedido y le comia la huella a otra linea.
    v_foto := public._foto_huella_lineas(ARRAY[p_pedido_item_id]);
    DELETE FROM pedido_item_lotes WHERE pedido_item_id = p_pedido_item_id AND sucursal_id = v_sucursal;
    PERFORM set_config('app.stock_origen', 'sustitucion_regalo_rehecha', true);
    FOR v_neto IN SELECT producto_id, consumo
$q$, 'dividir foto');

  v_def := pg_temp.parchar(v_def,
$q$      UPDATE productos SET stock = stock - v_neto.consumo
       WHERE id = v_neto.producto_id AND sucursal_id = v_sucursal;
    END LOOP;
  ELSE
$q$,
$q$      IF v_neto.consumo < 0 THEN
        UPDATE productos SET stock = stock - v_neto.consumo
         WHERE id = v_neto.producto_id AND sucursal_id = v_sucursal;
      END IF;
    END LOOP;
    PERFORM set_config('app.stock_origen', 'sustitucion_regalo', true);
  ELSE
$q$, 'dividir devolucion');

  v_def := pg_temp.parchar(v_def,
$q$  SELECT string_agg('producto_id=' || producto_id || ' cantidad=' || cantidad, '; ' ORDER BY orden)
    INTO v_detalle$q$,
$q$  -- #1097: las bajadas, con las partes ya guardadas: cada producto esta en
  -- una sola parte (los repetidos se rechazan arriba), y lo que pase a FEFO
  -- deja huella en ella. Despues, la huella vieja rehecha.
  IF v_regalo_mueve_stock THEN
    FOR v_neto IN SELECT producto_id, consumo
                   FROM (SELECT t.producto_id, sum(t.c) AS consumo
                           FROM (SELECT u.producto_id, u.cantidad AS c
                                   FROM unnest(v_prod, v_cant) AS u(producto_id, cantidad)
                                 UNION ALL
                                 SELECT v_item.producto_id, -v_item.cantidad) t
                          GROUP BY t.producto_id) n
                  WHERE consumo > 0
                  ORDER BY producto_id LOOP
      SELECT id INTO v_linea_parte
        FROM pedido_items
       WHERE id = ANY(v_item_ids) AND producto_id = v_neto.producto_id AND sucursal_id = v_sucursal
       ORDER BY id
       LIMIT 1;
      v_item_guc := current_setting('app.stock_pedido_item_id', true);
      PERFORM set_config('app.stock_pedido_item_id', COALESCE(v_linea_parte::text, ''), true);
      UPDATE productos SET stock = stock - v_neto.consumo
       WHERE id = v_neto.producto_id AND sucursal_id = v_sucursal;
      PERFORM set_config('app.stock_pedido_item_id', COALESCE(v_item_guc, ''), true);
    END LOOP;
    PERFORM public._rehacer_huella_lineas(v_foto, v_item_ids);
  END IF;

  SELECT string_agg('producto_id=' || producto_id || ' cantidad=' || cantidad, '; ' ORDER BY orden)
    INTO v_detalle$q$, 'dividir bajadas');

  EXECUTE v_def;
END
$dividir$;

-- 2d · crear_pedido_completo_bot: el bot no devuelve nada, solo baja; con la
--      linea, sus pedidos dejan huella como los de la app.
DO $bot$
DECLARE
  v_def text := pg_get_functiondef('public.crear_pedido_completo_bot(uuid,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.parchar(v_def,
$q$  v_regalo_default_id BIGINT;
BEGIN
$q$,
$q$  v_regalo_default_id BIGINT;
  -- #1097: la linea recien insertada y el GUC de linea del caller.
  v_item_bot BIGINT;
  v_item_guc TEXT;
BEGIN
$q$, 'bot declare');

  v_def := pg_temp.parchar(v_def,
$q$      v_pendiente.sucursal_id, v_stock_al_crear, v_costo_al_crear, v_descripcion_regalo
    );
$q$,
$q$      v_pendiente.sucursal_id, v_stock_al_crear, v_costo_al_crear, v_descripcion_regalo
    ) RETURNING id INTO v_item_bot;
$q$, 'bot insert');

  v_def := pg_temp.parchar(v_def,
$q$    IF NOT v_es_bonificacion THEN
      UPDATE productos SET stock = stock - v_cantidad WHERE id = v_producto_id AND sucursal_id = v_pendiente.sucursal_id;
$q$,
$q$    -- #1097: la bajada con SU linea (lo que pase a FEFO deja huella),
    -- guardado y restaurado ANTES del acumulador (por transaccion: 229).
    v_item_guc := current_setting('app.stock_pedido_item_id', true);
    PERFORM set_config('app.stock_pedido_item_id', v_item_bot::text, true);
    IF NOT v_es_bonificacion THEN
      UPDATE productos SET stock = stock - v_cantidad WHERE id = v_producto_id AND sucursal_id = v_pendiente.sucursal_id;
$q$, 'bot bajada');

  v_def := pg_temp.parchar(v_def,
$q$    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      -- mig 294 (#840): un contador por sabor$q$,
$q$    PERFORM set_config('app.stock_pedido_item_id', COALESCE(v_item_guc, ''), true);

    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      -- mig 294 (#840): un contador por sabor$q$, 'bot restaurar');

  EXECUTE v_def;
END
$bot$;

DROP FUNCTION pg_temp.parchar(text, text, text, text);

-- ---------------------------------------------------------------------------
-- 3 - CHECK (#1094)
-- ---------------------------------------------------------------------------
-- Hay 0 filas con cantidad <= 0 y ningun camino escribe 0 a proposito.

ALTER TABLE public.pedido_items
  ADD CONSTRAINT pedido_items_cantidad_positiva CHECK (cantidad > 0);

-- ---------------------------------------------------------------------------
-- 4 - Verificacion estructural
-- ---------------------------------------------------------------------------

DO $verif$
DECLARE
  v_act  text := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure);
  v_sus  text := pg_get_functiondef('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)'::regprocedure);
  v_div  text := pg_get_functiondef('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'::regprocedure);
  v_bot  text := pg_get_functiondef('public.crear_pedido_completo_bot(uuid,uuid)'::regprocedure);
  v_trg  text := pg_get_functiondef('public.sincronizar_lotes_stock()'::regprocedure);
  f      text;
BEGIN
  IF (length(v_act) - length(replace(v_act, '_rehacer_huella_lineas(v_foto, v_lineas_stock)', '')))
       / length('_rehacer_huella_lineas(v_foto, v_lineas_stock)') <> 1
     OR (length(v_act) - length(replace(v_act, '''pedido_editado''', ''))) / length('''pedido_editado''') <> 1
     OR (length(v_act) - length(replace(v_act, 'Cantidad invalida para producto ID', '')))
          / length('Cantidad invalida para producto ID') <> 1
     OR (length(v_act) - length(replace(v_act, 'set_config(''app.stock_pedido_item_id'', v_pedido_item_guardado', '')))
          / length('set_config(''app.stock_pedido_item_id'', v_pedido_item_guardado') <> 2 THEN
    RAISE EXCEPTION 'actualizar_pedido_items no quedo como se esperaba';
  END IF;
  IF v_sus NOT LIKE '%''sustitucion_regalo_rehecha''%' OR v_sus NOT LIKE '%_rehacer_huella_lineas(v_foto, ARRAY[p_pedido_item_id])%'
     OR v_sus NOT LIKE '%p_cantidad_nueva <> trunc(p_cantidad_nueva)%' THEN
    RAISE EXCEPTION 'sustituir_regalo_pedido no quedo como se esperaba';
  END IF;
  IF v_div NOT LIKE '%''sustitucion_regalo_rehecha''%' OR v_div NOT LIKE '%_rehacer_huella_lineas(v_foto, v_item_ids)%' THEN
    RAISE EXCEPTION 'dividir_regalo_pedido no quedo como se esperaba';
  END IF;
  IF v_bot NOT LIKE '%set_config(''app.stock_pedido_item_id'', v_item_bot::text, true)%'
     OR v_bot NOT LIKE '%RETURNING id INTO v_item_bot%' THEN
    RAISE EXCEPTION 'crear_pedido_completo_bot no quedo como se esperaba';
  END IF;
  -- Los dos origenes nuevos tienen que quedar FUERA de la lista blanca: si no,
  -- la devolucion vuelve a un lote y el lote queda +N.
  IF v_trg LIKE '%pedido_editado%' OR v_trg LIKE '%sustitucion_regalo_rehecha%' THEN
    RAISE EXCEPTION 'sincronizar_lotes_stock tiene en la lista blanca un origen que tiene que caer en la bolsa';
  END IF;

  FOREACH f IN ARRAY ARRAY['public.actualizar_pedido_items(bigint,jsonb,uuid)',
                           'public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)',
                           'public.dividir_regalo_pedido(bigint,jsonb,text,uuid)',
                           'public.crear_pedido_completo_bot(uuid,uuid)',
                           'public._foto_huella_lineas(bigint[])',
                           'public._rehacer_huella_lineas(jsonb,bigint[])'] LOOP
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = f::regprocedure) THEN
      RAISE EXCEPTION '% dejo de ser SECURITY DEFINER', f;
    END IF;
    IF has_function_privilege('anon', f, 'EXECUTE') THEN
      RAISE EXCEPTION 'anon puede ejecutar %', f;
    END IF;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.actualizar_pedido_items(bigint,jsonb,uuid)',
                           'public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)',
                           'public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'] LOOP
    IF NOT has_function_privilege('authenticated', f, 'EXECUTE') THEN
      RAISE EXCEPTION 'authenticated perdio EXECUTE sobre %', f;
    END IF;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.crear_pedido_completo_bot(uuid,uuid)',
                           'public._foto_huella_lineas(bigint[])',
                           'public._rehacer_huella_lineas(jsonb,bigint[])'] LOOP
    IF has_function_privilege('authenticated', f, 'EXECUTE') THEN
      RAISE EXCEPTION 'authenticated puede ejecutar %, que es de servidor', f;
    END IF;
  END LOOP;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.pedido_items'::regclass
                    AND conname = 'pedido_items_cantidad_positiva' AND convalidated) THEN
    RAISE EXCEPTION 'falta el CHECK pedido_items_cantidad_positiva';
  END IF;
END
$verif$;

-- ---------------------------------------------------------------------------
-- 5 - Ensayo con datos reales: los casos de
--     scripts/test-huella-edicion-1094-1097.sql (ver ahi cada uno). La corrida
--     de aca solo aborta si algo falla.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pg_temp.t_hoy()
RETURNS date LANGUAGE sql AS $fn$
  SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_foto(p_prod bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object(
    'stock', pr.stock,
    'lotes', COALESCE((SELECT jsonb_agg(l.cantidad_restante ORDER BY l.fecha_vencimiento, l.id)
                         FROM public.producto_lotes l WHERE l.producto_id = pr.id), '[]'::jsonb),
    'bolsa', pr.stock - COALESCE((SELECT SUM(l.cantidad_restante)
                                    FROM public.producto_lotes l WHERE l.producto_id = pr.id), 0)::int)
    FROM public.productos pr WHERE pr.id = p_prod;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_huella(p_item bigint, p_lote bigint)
RETURNS int LANGUAGE sql AS $fn$
  SELECT COALESCE(SUM(cantidad), 0)::int FROM public.pedido_item_lotes
   WHERE pedido_item_id = p_item AND lote_id = p_lote;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_huella_linea(p_item bigint)
RETURNS int LANGUAGE sql AS $fn$
  SELECT COALESCE(SUM(cantidad), 0)::int FROM public.pedido_item_lotes WHERE pedido_item_id = p_item;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_linea(p_ped bigint, p_prod bigint, p_regalo boolean)
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT id FROM public.pedido_items
   WHERE pedido_id = p_ped AND producto_id = p_prod AND COALESCE(es_bonificacion, false) = p_regalo
   ORDER BY id LIMIT 1;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_prod(p_suc bigint, p_admin uuid, p_lotes jsonb, p_bolsa int)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod   bigint;
  v_compra bigint;
  v_id     bigint;
  v_ids    jsonb := '[]'::jsonb;
  l        jsonb;
BEGIN
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1097', 100,
          p_bolsa + (SELECT COALESCE(SUM((x->>'restante')::int), 0) FROM jsonb_array_elements(p_lotes) x),
          60, p_suc)
  RETURNING id INTO v_prod;

  IF jsonb_array_length(p_lotes) > 0 THEN
    INSERT INTO public.compras (sucursal_id, estado, usuario_id)
    VALUES (p_suc, 'recibida', p_admin) RETURNING id INTO v_compra;
  END IF;

  FOR l IN SELECT * FROM jsonb_array_elements(p_lotes) LOOP
    INSERT INTO public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad,
                                       cantidad_restante, usuario_id, compra_id)
    VALUES (v_prod, p_suc, pg_temp.t_hoy() + (l->>'dias')::int, (l->>'cantidad')::int,
            (l->>'restante')::int, p_admin, v_compra)
    RETURNING id INTO v_id;
    v_ids := v_ids || to_jsonb(v_id);
  END LOOP;

  RETURN jsonb_build_object('prod', v_prod, 'compra', v_compra, 'lotes', v_ids);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_pedido(p_cli bigint, p_admin uuid, p_prod bigint, p_cant int)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
  v_ped bigint;
BEGIN
  v_res := public.crear_pedido_completo(
    p_cli, p_cant * 100, p_admin,
    jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 100)),
    'ensayo 1097');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  v_ped := (v_res->>'pedido_id')::bigint;
  RETURN jsonb_build_object('pedido', v_ped, 'item', pg_temp.t_linea(v_ped, p_prod, false));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_a_la_bolsa(p_prod bigint, p_n int)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', 'ensayo_1097', true);
  UPDATE public.productos SET stock = stock + p_n WHERE id = p_prod;
  PERFORM set_config('app.stock_origen', '', true);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_linea_extra(p_ped bigint, p_prod bigint, p_suc bigint, p_cant int,
                                                  p_promo bigint)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_item bigint;
BEGIN
  INSERT INTO public.pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal,
                                   sucursal_id, es_bonificacion, promocion_id)
  VALUES (p_ped, p_prod, p_cant, CASE WHEN p_promo IS NULL THEN 100 ELSE 0 END,
          CASE WHEN p_promo IS NULL THEN 100 * p_cant ELSE 0 END,
          p_suc, p_promo IS NOT NULL, p_promo)
  RETURNING id INTO v_item;
  PERFORM set_config('app.stock_origen', 'pedido_creado', true);
  PERFORM set_config('app.stock_ref_tipo', 'pedido', true);
  PERFORM set_config('app.stock_ref_id', p_ped::text, true);
  PERFORM set_config('app.stock_pedido_item_id', v_item::text, true);
  UPDATE public.productos SET stock = stock - p_cant WHERE id = p_prod;
  PERFORM set_config('app.stock_pedido_item_id', '', true);
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  RETURN v_item;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_pedido_con_regalo(p_cli bigint, p_adm uuid, p_suc bigint,
                                                        p_bolsa int, p_extra int)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; p jsonb; v_ped bigint; v_promo bigint; v_regalo bigint;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', p_bolsa);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_ped := p->>'pedido';

  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id)
  VALUES ('ZZ ensayo 1097', 'bonificacion', CURRENT_DATE, p_suc, true, v_prod) RETURNING id INTO v_promo;
  v_regalo := pg_temp.t_linea_extra(v_ped, v_prod, p_suc, 4, v_promo);

  PERFORM pg_temp.t_a_la_bolsa(v_prod, p_extra);
  RETURN jsonb_build_object('prod', v_prod, 'pedido', v_ped, 'promo', v_promo,
                            'l2', v->'lotes'->0, 'l1', v->'lotes'->1,
                            'x', p->'item', 'r', v_regalo);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_editar_res(p_ped bigint, p_adm uuid, p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
BEGIN
  RETURN public.actualizar_pedido_items(p_ped, p_items, p_adm);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_editar(p_ped bigint, p_adm uuid, p_items jsonb)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.actualizar_pedido_items(p_ped, p_items, p_adm);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo editar el pedido: %', v_res;
  END IF;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_x(p_prod bigint, p_cant int)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 100);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_r(p_prod bigint, p_cant int, p_promo bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 0,
                            'es_bonificacion', true, 'promocion_id', p_promo);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_base_e1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; p jsonb; v_prod bigint;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 5);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  PERFORM pg_temp.t_a_la_bolsa(v_prod, 20);
  IF pg_temp.t_foto(v_prod) <> '{"stock":55,"lotes":[0,35],"bolsa":20}'
     OR pg_temp.t_huella((p->>'item')::bigint, (v->'lotes'->>1)::bigint) <> 15 THEN
    RAISE EXCEPTION 'punto de partida de E1: % (huella %)', pg_temp.t_foto(v_prod),
      pg_temp.t_huella((p->>'item')::bigint, (v->'lotes'->>1)::bigint);
  END IF;
  RETURN jsonb_build_object('prod', v_prod, 'pedido', p->'pedido', 'item', p->'item',
                            'l2', v->'lotes'->0, 'l1', v->'lotes'->1);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_e1_editar(p_cli bigint, p_adm uuid, p_suc bigint, p_cant int,
                                                p_foto jsonb, p_huella int)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  d jsonb; v_prod bigint; v_ped bigint; v_nueva bigint; f text[] := '{}'; v_f1 jsonb;
BEGIN
  d := pg_temp.t_base_e1(p_cli, p_adm, p_suc);
  v_prod := d->>'prod'; v_ped := d->>'pedido';
  PERFORM pg_temp.t_editar(v_ped, p_adm, jsonb_build_array(pg_temp.t_x(v_prod, p_cant)));
  v_nueva := pg_temp.t_linea(v_ped, v_prod, false);
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = p_foto, format('editar a %s dejo %s, esperado %s', p_cant, v_f1, p_foto));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_nueva, (d->>'l1')::bigint) = p_huella
                       AND pg_temp.t_huella_linea(v_nueva) = p_huella,
                    format('la linea nueva quedo con huella %s en L1 (%s en total), esperado %s',
                           pg_temp.t_huella(v_nueva, (d->>'l1')::bigint), pg_temp.t_huella_linea(v_nueva), p_huella));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('foto %s', v_f1));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_e1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT pg_temp.t_e1_editar(p_cli, p_adm, p_suc, 20, '{"stock":55,"lotes":[0,35],"bolsa":20}', 15);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_e2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT pg_temp.t_e1_editar(p_cli, p_adm, p_suc, 30, '{"stock":45,"lotes":[0,35],"bolsa":10}', 15);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_e3(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT pg_temp.t_e1_editar(p_cli, p_adm, p_suc, 10, '{"stock":65,"lotes":[0,45],"bolsa":20}', 5);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_e1b(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; p jsonb; v_prod bigint; v_ped bigint; f text[] := '{}'; v_f0 jsonb; v_f1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 25);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_ped := p->>'pedido';
  v_f0 := pg_temp.t_foto(v_prod);
  IF v_f0 <> '{"stock":55,"lotes":[0,50],"bolsa":5}' THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', v_f0)));
  END IF;
  PERFORM pg_temp.t_editar(v_ped, p_adm, jsonb_build_array(pg_temp.t_x(v_prod, 20)));
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = v_f0, format('editar sin cambios dejo %s, antes %s', v_f1, v_f0));
  f := pg_temp.t_si(f, pg_temp.t_huella_linea(pg_temp.t_linea(v_ped, v_prod, false)) = 0,
                    'la linea que salio de la bolsa quedo con huella');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s', v_f0, v_f1));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_e1c(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  d jsonb; v_prod bigint; v_ped bigint; f text[] := '{}'; v_f0 jsonb; v_f1 jsonb; v_x bigint; v_r bigint;
BEGIN
  d := pg_temp.t_pedido_con_regalo(p_cli, p_adm, p_suc, 20, 20);
  v_prod := d->>'prod'; v_ped := d->>'pedido';
  v_f0 := pg_temp.t_foto(v_prod);
  IF v_f0 <> '{"stock":66,"lotes":[0,46],"bolsa":20}'
     OR pg_temp.t_huella_linea((d->>'x')::bigint) <> 0
     OR pg_temp.t_huella((d->>'r')::bigint, (d->>'l1')::bigint) <> 4 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', v_f0)));
  END IF;
  PERFORM pg_temp.t_editar(v_ped, p_adm, jsonb_build_array(pg_temp.t_x(v_prod, 20),
                                                           pg_temp.t_r(v_prod, 4, (d->>'promo')::bigint)));
  v_x := pg_temp.t_linea(v_ped, v_prod, false); v_r := pg_temp.t_linea(v_ped, v_prod, true);
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = v_f0, format('editar sin cambios dejo %s, antes %s', v_f1, v_f0));
  f := pg_temp.t_si(f, pg_temp.t_huella_linea(v_x) = 0,
                    format('X quedo con huella %s, esperado 0', pg_temp.t_huella_linea(v_x)));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_r, (d->>'l1')::bigint) = 4,
                    format('R quedo con huella %s en L1, esperado 4', pg_temp.t_huella(v_r, (d->>'l1')::bigint)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s', v_f0, v_f1));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_e4(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  d jsonb; v_prod bigint; v_ped bigint; f text[] := '{}'; v_f0 jsonb; v_f1 jsonb; v_x bigint; v_r bigint;
BEGIN
  d := pg_temp.t_pedido_con_regalo(p_cli, p_adm, p_suc, 5, 20);
  v_prod := d->>'prod'; v_ped := d->>'pedido';
  v_f0 := pg_temp.t_foto(v_prod);
  IF v_f0 <> '{"stock":51,"lotes":[0,31],"bolsa":20}'
     OR pg_temp.t_huella((d->>'x')::bigint, (d->>'l1')::bigint) <> 15
     OR pg_temp.t_huella((d->>'r')::bigint, (d->>'l1')::bigint) <> 4 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', v_f0)));
  END IF;
  PERFORM pg_temp.t_editar(v_ped, p_adm, jsonb_build_array(pg_temp.t_x(v_prod, 20),
                                                           pg_temp.t_r(v_prod, 4, (d->>'promo')::bigint)));
  v_x := pg_temp.t_linea(v_ped, v_prod, false); v_r := pg_temp.t_linea(v_ped, v_prod, true);
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1->'stock' = v_f0->'stock',
                    format('E5 · el stock quedo %s, antes %s (#1083)', v_f1->'stock', v_f0->'stock'));
  f := pg_temp.t_si(f, v_f1 = v_f0, format('editar sin cambios dejo %s, antes %s', v_f1, v_f0));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_x, (d->>'l1')::bigint) = 15
                       AND pg_temp.t_huella(v_r, (d->>'l1')::bigint) = 4,
                    format('huellas X %s / R %s en L1, esperado 15 / 4',
                           pg_temp.t_huella(v_x, (d->>'l1')::bigint), pg_temp.t_huella(v_r, (d->>'l1')::bigint)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s', v_f0, v_f1));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_e4c(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  d jsonb; v_prod bigint; v_ped bigint; v_l1 bigint; v_res jsonb; f text[] := '{}';
  v_f0 jsonb; v_f1 jsonb; v_f2 jsonb; v_x bigint; v_r bigint;
BEGIN
  d := pg_temp.t_pedido_con_regalo(p_cli, p_adm, p_suc, 5, 20);
  v_prod := d->>'prod'; v_ped := d->>'pedido'; v_l1 := d->>'l1';
  v_f0 := pg_temp.t_foto(v_prod);
  IF v_f0 <> '{"stock":51,"lotes":[0,31],"bolsa":20}'
     OR pg_temp.t_huella((d->>'x')::bigint, v_l1) <> 15
     OR pg_temp.t_huella((d->>'r')::bigint, v_l1) <> 4 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', v_f0)));
  END IF;
  PERFORM pg_temp.t_editar(v_ped, p_adm, jsonb_build_array(pg_temp.t_x(v_prod, 10),
                                                           pg_temp.t_r(v_prod, 4, (d->>'promo')::bigint)));
  v_x := pg_temp.t_linea(v_ped, v_prod, false); v_r := pg_temp.t_linea(v_ped, v_prod, true);
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = '{"stock":61,"lotes":[0,41],"bolsa":20}',
                    format('bajar X a 10 dejo %s, esperado {61,[0,41],20}', v_f1));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_x, v_l1) = 5 AND pg_temp.t_huella_linea(v_x) = 5
                       AND pg_temp.t_huella(v_r, v_l1) = 4 AND pg_temp.t_huella_linea(v_r) = 4,
                    format('huellas X %s / R %s, esperado 5 / 4 (R no cambio)',
                           pg_temp.t_huella_linea(v_x), pg_temp.t_huella_linea(v_r)));
  v_res := public.cancelar_pedido_con_stock(v_ped, 'ensayo 1097', p_adm, NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'cancelar: %', v_res;
  END IF;
  v_f2 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f2 = '{"stock":75,"lotes":[0,50],"bolsa":25}',
                    format('cancelar despues de bajar X dejo %s, esperado {75,[0,50],25} (como sin editar)', v_f2));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s / %s', v_f0, v_f1, v_f2));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_e4b(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; p jsonb; v_prod bigint; v_ped bigint; v_l1 bigint; v_a2 bigint; v_nueva bigint;
  f text[] := '{}'; v_f0 jsonb; v_f1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 0);
  v_prod := v->>'prod'; v_l1 := v->'lotes'->>1;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 10); v_ped := p->>'pedido';
  PERFORM pg_temp.t_a_la_bolsa(v_prod, 10);
  v_a2 := pg_temp.t_linea_extra(v_ped, v_prod, p_suc, 10, NULL);
  PERFORM pg_temp.t_a_la_bolsa(v_prod, 20);
  v_f0 := pg_temp.t_foto(v_prod);
  IF v_f0 <> '{"stock":60,"lotes":[0,40],"bolsa":20}'
     OR pg_temp.t_huella((p->>'item')::bigint, v_l1) <> 10 OR pg_temp.t_huella_linea(v_a2) <> 0 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', v_f0)));
  END IF;
  PERFORM pg_temp.t_editar(v_ped, p_adm, jsonb_build_array(pg_temp.t_x(v_prod, 20)));
  v_nueva := pg_temp.t_linea(v_ped, v_prod, false);
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = v_f0, format('fusionar dejo %s, antes %s', v_f1, v_f0));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_nueva, v_l1) = 10,
                    format('la linea fusionada quedo con huella %s en L1, esperado 10', pg_temp.t_huella(v_nueva, v_l1)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s', v_f0, v_f1));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_e6(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  a jsonb; b jsonb; v_a bigint; v_b bigint; p jsonb; v_ped bigint;
  f text[] := '{}'; v_fa jsonb; v_fb jsonb; v_res jsonb; v_err text; v_sa jsonb; v_sb jsonb;
  v_nombre text; v_payload jsonb;
BEGIN
  a := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 5);
  b := pg_temp.t_prod(p_suc, p_adm, '[]', 50);
  v_a := a->>'prod'; v_b := b->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_a, 20); v_ped := p->>'pedido';
  v_fa := pg_temp.t_foto(v_a); v_fb := pg_temp.t_foto(v_b);

  FOR v_nombre, v_payload IN
    SELECT * FROM (VALUES
      ('-1',        jsonb_build_array(pg_temp.t_x(v_a, 20), pg_temp.t_x(v_b, -1))),
      ('0',         jsonb_build_array(pg_temp.t_x(v_a, 20), pg_temp.t_x(v_b, 0))),
      ('0.4',       jsonb_build_array(pg_temp.t_x(v_a, 20),
                                      jsonb_build_object('producto_id', v_b, 'cantidad', 0.4, 'precio_unitario', 100))),
      ('regalo 0',  jsonb_build_array(pg_temp.t_x(v_a, 20),
                                      jsonb_build_object('producto_id', v_b, 'cantidad', 0, 'precio_unitario', 0,
                                                         'es_bonificacion', true)))) t(n, j)
  LOOP
    v_res := NULL; v_err := NULL; v_sa := NULL; v_sb := NULL;
    BEGIN
      v_res := pg_temp.t_editar_res(v_ped, p_adm, v_payload);
      v_sa := pg_temp.t_foto(v_a); v_sb := pg_temp.t_foto(v_b);
      RAISE EXCEPTION USING ERRCODE = 'ZZ002';
    EXCEPTION
      WHEN SQLSTATE 'ZZ002' THEN NULL;
      WHEN OTHERS THEN v_err := SQLSTATE || ' ' || SQLERRM;
    END;
    IF v_err IS NOT NULL THEN
      f := f || format('%s: revento en vez de rechazar (%s)', v_nombre, v_err);
    ELSIF COALESCE((v_res->>'success')::boolean, true) THEN
      f := f || format('%s: acepto (stock de B %s -> %s)', v_nombre, v_fb->'stock', v_sb->'stock');
    ELSIF COALESCE(v_res->>'errores', '') NOT LIKE '%Cantidad invalida para producto ID ' || v_b || '%' THEN
      f := f || format('%s: rechazo con otro mensaje (%s)', v_nombre, v_res->>'errores');
    ELSIF v_sa IS DISTINCT FROM v_fa OR v_sb IS DISTINCT FROM v_fb THEN
      f := f || format('%s: rechazo pero movio stock (A %s -> %s, B %s -> %s)', v_nombre, v_fa, v_sa, v_fb, v_sb);
    END IF;
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_e7(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  a jsonb; p jsonb; v_estado text := 'paso'; v_con text;
BEGIN
  a := pg_temp.t_prod(p_suc, p_adm, '[]', 50);
  p := pg_temp.t_pedido(p_cli, p_adm, (a->>'prod')::bigint, 2);
  BEGIN
    INSERT INTO public.pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id)
    VALUES ((p->>'pedido')::bigint, (a->>'prod')::bigint, 0, 100, 0, p_suc);
  EXCEPTION
    WHEN check_violation THEN
      GET STACKED DIAGNOSTICS v_con = CONSTRAINT_NAME;
      v_estado := 'check ' || COALESCE(v_con, '?');
    WHEN OTHERS THEN v_estado := 'otro error: ' || SQLSTATE || ' ' || SQLERRM;
  END;
  RETURN jsonb_build_object('fallas',
    CASE WHEN v_estado = 'check pedido_items_cantidad_positiva' THEN '[]'::jsonb
         ELSE jsonb_build_array(format('un renglon con cantidad 0: %s, esperado el CHECK pedido_items_cantidad_positiva', v_estado)) END);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_e8(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  d jsonb; q jsonb; v_prod bigint; v_q bigint; v_lq bigint; v_res jsonb;
  f text[] := '{}'; v_f1 jsonb; v_fq jsonb;
BEGIN
  d := pg_temp.t_pedido_con_regalo(p_cli, p_adm, p_suc, 5, 20);
  q := pg_temp.t_prod(p_suc, p_adm, '[{"dias":60,"cantidad":100,"restante":10}]', 2);
  v_prod := d->>'prod'; v_q := q->>'prod'; v_lq := q->'lotes'->>0;
  v_res := public.sustituir_regalo_pedido((d->>'r')::bigint, v_q, 3, 'ensayo 1097', NULL, NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'sustituir: %', v_res;
  END IF;
  v_f1 := pg_temp.t_foto(v_prod); v_fq := pg_temp.t_foto(v_q);
  f := pg_temp.t_si(f, pg_temp.t_huella((d->>'x')::bigint, (d->>'l1')::bigint) = 15,
                    format('X quedo con huella %s en L1, esperado 15',
                           pg_temp.t_huella((d->>'x')::bigint, (d->>'l1')::bigint)));
  f := pg_temp.t_si(f, pg_temp.t_huella((d->>'r')::bigint, (d->>'l1')::bigint) = 0
                       AND pg_temp.t_huella((d->>'r')::bigint, (d->>'l2')::bigint) = 0,
                    'R sigue con huella en un lote de P');
  f := pg_temp.t_si(f, pg_temp.t_huella((d->>'r')::bigint, v_lq) = 1,
                    format('R quedo con huella %s en el lote de Q, esperado 1', pg_temp.t_huella((d->>'r')::bigint, v_lq)));
  f := pg_temp.t_si(f, v_f1 = '{"stock":55,"lotes":[0,35],"bolsa":20}',
                    format('P quedo %s, esperado {55,[0,35],20}', v_f1));
  f := pg_temp.t_si(f, v_fq = '{"stock":9,"lotes":[9],"bolsa":0}',
                    format('Q quedo %s, esperado {9,[9],0}', v_fq));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('P %s / Q %s', v_f1, v_fq));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_e8b(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  d jsonb; v_prod bigint; v_res jsonb; f text[] := '{}'; v_f0 jsonb; v_f1 jsonb;
BEGIN
  d := pg_temp.t_pedido_con_regalo(p_cli, p_adm, p_suc, 5, 10);
  v_prod := d->>'prod';
  v_f0 := pg_temp.t_foto(v_prod);
  IF v_f0 <> '{"stock":41,"lotes":[0,31],"bolsa":10}' THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', v_f0)));
  END IF;
  v_res := public.sustituir_regalo_pedido((d->>'r')::bigint, v_prod, 6, 'ensayo 1097', NULL, NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'sustituir: %', v_res;
  END IF;
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = '{"stock":39,"lotes":[0,31],"bolsa":8}',
                    format('P quedo %s, esperado {39,[0,31],8}', v_f1));
  f := pg_temp.t_si(f, pg_temp.t_huella((d->>'r')::bigint, (d->>'l1')::bigint) = 4
                       AND pg_temp.t_huella((d->>'x')::bigint, (d->>'l1')::bigint) = 15,
                    format('huellas R %s / X %s en L1, esperado 4 / 15',
                           pg_temp.t_huella((d->>'r')::bigint, (d->>'l1')::bigint),
                           pg_temp.t_huella((d->>'x')::bigint, (d->>'l1')::bigint)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s', v_f0, v_f1));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_e8c(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  d jsonb; q jsonb; v_q bigint; v_res jsonb; v_err text; v_c numeric;
  v_fq0 jsonb; v_fq jsonb; v_lin jsonb; f text[] := '{}';
BEGIN
  d := pg_temp.t_pedido_con_regalo(p_cli, p_adm, p_suc, 5, 20);
  q := pg_temp.t_prod(p_suc, p_adm, '[]', 20);
  v_q := q->>'prod';
  v_fq0 := pg_temp.t_foto(v_q);
  FOREACH v_c IN ARRAY ARRAY[0.4, 0.5, 2.5]::numeric[] LOOP
    v_res := NULL; v_err := NULL; v_fq := NULL; v_lin := NULL;
    BEGIN
      v_res := public.sustituir_regalo_pedido((d->>'r')::bigint, v_q, v_c, 'ensayo 1097', NULL, NULL);
      v_fq := pg_temp.t_foto(v_q);
      SELECT jsonb_build_object('producto', producto_id, 'cantidad', cantidad) INTO v_lin
        FROM public.pedido_items WHERE id = (d->>'r')::bigint;
      RAISE EXCEPTION USING ERRCODE = 'ZZ003';
    EXCEPTION
      WHEN SQLSTATE 'ZZ003' THEN NULL;
      WHEN OTHERS THEN v_err := SQLSTATE || ' ' || SQLERRM;
    END;
    IF v_err IS NOT NULL THEN
      f := f || format('sustituir con %s revento (%s)', v_c, v_err);
    ELSIF COALESCE((v_res->>'success')::boolean, true) THEN
      f := f || format('sustituir con %s acepto: la linea quedo %s y Q %s -> %s',
                       v_c, v_lin, v_fq0->'stock', v_fq->'stock');
    ELSIF v_res->>'error' IS DISTINCT FROM 'La cantidad sustituta tiene que ser un numero entero' THEN
      f := f || format('sustituir con %s rechazo con otro mensaje (%s)', v_c, v_res->>'error');
    ELSIF v_fq IS DISTINCT FROM v_fq0 OR (v_lin->>'producto')::bigint <> (d->>'prod')::bigint
          OR (v_lin->>'cantidad')::int <> 4 THEN
      f := f || format('sustituir con %s rechazo pero movio algo (linea %s, Q %s)', v_c, v_lin, v_fq);
    END IF;
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_e9(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  d jsonb; q jsonb; v_prod bigint; v_q bigint; v_lq bigint; v_res jsonb; v_parte_q bigint;
  f text[] := '{}'; v_f1 jsonb; v_fq jsonb;
BEGIN
  d := pg_temp.t_pedido_con_regalo(p_cli, p_adm, p_suc, 5, 20);
  q := pg_temp.t_prod(p_suc, p_adm, '[{"dias":60,"cantidad":100,"restante":10}]', 2);
  v_prod := d->>'prod'; v_q := q->>'prod'; v_lq := q->'lotes'->>0;
  v_res := public.dividir_regalo_pedido((d->>'r')::bigint,
             jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1),
                               jsonb_build_object('producto_id', v_q, 'cantidad', 3)),
             'ensayo 1097', NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'dividir: %', v_res;
  END IF;
  v_parte_q := pg_temp.t_linea((d->>'pedido')::bigint, v_q, true);
  v_f1 := pg_temp.t_foto(v_prod); v_fq := pg_temp.t_foto(v_q);
  f := pg_temp.t_si(f, pg_temp.t_huella((d->>'x')::bigint, (d->>'l1')::bigint) = 15,
                    format('X quedo con huella %s en L1, esperado 15',
                           pg_temp.t_huella((d->>'x')::bigint, (d->>'l1')::bigint)));
  f := pg_temp.t_si(f, pg_temp.t_huella((d->>'r')::bigint, (d->>'l1')::bigint) = 1,
                    format('R (P x1) quedo con huella %s en L1, esperado 1',
                           pg_temp.t_huella((d->>'r')::bigint, (d->>'l1')::bigint)));
  f := pg_temp.t_si(f, v_f1 = '{"stock":54,"lotes":[0,34],"bolsa":20}',
                    format('P quedo %s, esperado {54,[0,34],20}', v_f1));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_parte_q, v_lq) = 1,
                    format('la parte Q quedo con huella %s en su lote, esperado 1', pg_temp.t_huella(v_parte_q, v_lq)));
  f := pg_temp.t_si(f, v_fq = '{"stock":9,"lotes":[9],"bolsa":0}',
                    format('Q quedo %s, esperado {9,[9],0}', v_fq));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('P %s / Q %s', v_f1, v_fq));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_e10(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  d jsonb; v_prod bigint; v_ped bigint; v_res jsonb; f text[] := '{}'; v_f1 jsonb;
BEGIN
  d := pg_temp.t_base_e1(p_cli, p_adm, p_suc);
  v_prod := d->>'prod'; v_ped := d->>'pedido';
  PERFORM pg_temp.t_editar(v_ped, p_adm, jsonb_build_array(pg_temp.t_x(v_prod, 20)));
  v_res := public.cancelar_pedido_con_stock(v_ped, 'ensayo 1097', p_adm, NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'cancelar: %', v_res;
  END IF;
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = '{"stock":75,"lotes":[0,50],"bolsa":25}',
                    format('cancelar despues de editar dejo %s, esperado {75,[0,50],25}', v_f1));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('foto %s', v_f1));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_e11(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_conf uuid; v_res jsonb; v_item bigint; f text[] := '{}';
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 5);
  v_prod := v->>'prod';
  INSERT INTO public.bot_pedidos_pendientes (perfil_id, sucursal_id, cliente_id, items, total)
  VALUES (p_adm, p_suc, p_cli, jsonb_build_array(pg_temp.t_x(v_prod, 20)), 2000)
  RETURNING id INTO v_conf;
  v_res := public.crear_pedido_completo_bot(p_adm, v_conf);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'bot: %', v_res;
  END IF;
  v_item := pg_temp.t_linea((v_res->>'pedido_id')::bigint, v_prod, false);
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, (v->'lotes'->>0)::bigint) = 15,
                    format('la linea del bot quedo con huella %s, esperado 15',
                           pg_temp.t_huella(v_item, (v->'lotes'->>0)::bigint)));
  f := pg_temp.t_si(f, pg_temp.t_foto(v_prod) = '{"stock":35,"lotes":[35],"bolsa":0}',
                    format('el producto quedo %s, esperado {35,[35],0}', pg_temp.t_foto(v_prod)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_u1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; p jsonb; v_prod bigint; f text[] := '{}';
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[]', 50);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 10);
  PERFORM pg_temp.t_editar((p->>'pedido')::bigint, p_adm, jsonb_build_array(pg_temp.t_x(v_prod, 12)));
  f := pg_temp.t_si(f, pg_temp.t_foto(v_prod) = '{"stock":38,"lotes":[],"bolsa":38}',
                    format('sin lotes quedo %s, esperado stock 38', pg_temp.t_foto(v_prod)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

DO $ensayo1097$
DECLARE
  v_admin   uuid;
  v_suc     bigint;
  v_cliente bigint;
  v_caso    text;
  v_out     jsonb;
  v_fallas  text[] := '{}';
BEGIN
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'ens1097 · el ensayo necesita un admin activo con una sucursal activa';
  END IF;
  SELECT id INTO v_cliente FROM clientes
   WHERE sucursal_id = v_suc AND activo AND tipo_factura_default IS DISTINCT FROM 'VB'
   ORDER BY id LIMIT 1;
  IF v_cliente IS NULL THEN
    RAISE EXCEPTION 'ens1097 · el ensayo necesita un cliente activo en la sucursal %', v_suc;
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  -- Cada caso corre en un subbloque que termina en una excepcion atrapada,
  -- asi que no deja nada; si alguno falla, la migracion entera aborta.
  FOREACH v_caso IN ARRAY ARRAY['e1', 'e2', 'e3', 'e1b', 'e1c', 'e4', 'e4b', 'e4c', 'e6', 'e7',
                                'e8', 'e8b', 'e8c', 'e9', 'e10', 'e11', 'u1'] LOOP
    v_out := NULL;
    BEGIN
      EXECUTE format('SELECT pg_temp.caso_%s($1, $2, $3)', v_caso)
        INTO v_out USING v_cliente, v_admin, v_suc;
      RAISE EXCEPTION USING ERRCODE = 'ZZ001';
    EXCEPTION
      WHEN SQLSTATE 'ZZ001' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('%s · error: %s', upper(v_caso), SQLERRM);
    END;
    IF v_out IS NOT NULL THEN
      v_fallas := v_fallas || ARRAY(SELECT upper(v_caso) || ' · ' || x
                                      FROM jsonb_array_elements_text(COALESCE(v_out->'fallas', '[]')) x);
    END IF;
  END LOOP;

  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.headers', '', true);
  PERFORM set_config('app.omitir_minimo_pedido', '', true);

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ens1097 · el ensayo fallo (% fallas), la migracion no se aplica:\n- %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
END
$ensayo1097$;

-- Las auxiliares del ensayo no se quedan en la sesion.
DO $limpieza$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS f
      FROM pg_proc p
     WHERE p.pronamespace = pg_my_temp_schema()
       AND (p.proname LIKE 't\_%' OR p.proname LIKE 'caso\_%')
  LOOP
    EXECUTE 'DROP FUNCTION ' || r.f::text;
  END LOOP;
END
$limpieza$;
