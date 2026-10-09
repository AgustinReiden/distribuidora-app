-- Anular una salvedad saca las unidades del mismo lote al que volvieron (#1050)
--
-- EL BUG
--
--   La salvedad que devuelve stock (cliente_rechaza, error_pedido,
--   diferencia_precio, entregado_otro_cliente, otro) sube productos.stock con
--   origen 'salvedad', que esta en la lista blanca de sincronizar_lotes_stock:
--   las unidades vuelven a un lote por FEFO. Anularla las bajaba con
--   'salvedad_anulada', y el camino de BAJADA del trigger no mira el origen:
--   come primero de la bolsa. Con un lote de 50 vivas y bolsa 40, un pedido de
--   10 (sale de la bolsa) y la salvedad de 10 (vuelve al lote):
--
--     despues del pedido   stock 80 · lote 50 · bolsa 30
--     despues de la salv.  stock 90 · lote 60 · bolsa 30
--     despues de anular    stock 80 · lote 60 · bolsa 20     <- lote +10, bolsa -10
--
--   El ensayo de la 316 arrancaba con bolsa 0, que es justo el caso en que la
--   bajada no tiene otra cosa que comer que el lote: daba bien por casualidad.
--   Medido en prod antes de esta migracion con scripts/test-anular-salvedad-
--   lote-bolsa.sql: los cinco motivos dejan lote 60 / bolsa 20.
--
-- EL ARREGLO: el mismo molde que la 229 para la compra anulada
--
--   La 229 resolvio la compra cancelada actuando PRIMERO sobre el lote (borrar
--   los propios) y bajando el stock DESPUES, para que el trigger no tuviera
--   nada ajeno que comerse. Aca igual, sin tocar el trigger:
--
--   1. registrar_salvedad anota en `salvedades_items.lotes_devueltos` a que
--      lotes volvio cada unidad: foto de los lotes antes y despues del UPDATE
--      de stock (los mismos _mov_lotes_foto / _mov_lotes_diff de los
--      movimientos entre sucursales, 286). '[]' si todo fue a la bolsa.
--   2. anular_salvedad, ANTES de la bajada, saca de esos lotes lo anotado (lo
--      que todavia tengan). Para el trigger esas unidades pasan a ser bolsa, y
--      la bajada de N se come exactamente esas: lote -N, bolsa igual. Lo que ya
--      no esta en el lote (se vendio, se borro) sale por el camino de siempre.
--   3. La huella lote -> cliente (pedido_item_lotes, 256). La devolucion se la
--      saca a la linea (_restaurar_lotes_fefo la descuenta; si la linea queda en
--      cero, el DELETE la borra en cascada). Se anota cuanta huella perdio la
--      linea en cada lote y al anular se le repone a la linea restituida: las
--      unidades vuelven a estar en manos del cliente. La devolucion ahora
--      descuenta la huella de ESTA linea (app.stock_pedido_item_id); sin eso
--      _restaurar_lotes_fefo caia al pedido entero y podia sacarsela a otra
--      linea del mismo producto, un regalo por ejemplo. Lo que sale por FEFO en
--      el camino de siempre deja huella igual que una venta.
--   4. set_config es por TRANSACCION (229): anular_salvedad guarda los GUCs de
--      app.stock_* antes de su UPDATE y los restaura despues.
--
--   NULL en lotes_devueltos = salvedad anterior a esta migracion: sale de la
--   bolsa, como antes. Relevado en prod el 2026-10-09: las 14 salvedades vivas
--   con stock devuelto cuyo producto tiene lotes se cargaron todas antes del
--   primer lote (17/09), o sea que su devolucion fue a la bolsa y sacarla de la
--   bolsa es lo correcto. El $legado$ de abajo aborta si aparece alguna cargada
--   con lotes y sin anotacion.
--
--   La columna la escribe solo el servidor: salvedades_items tiene INSERT por
--   REST para transportista y UPDATE para admin, y una anotacion inventada
--   haria que la anulacion saque de otro lote. Un trigger la rechaza cuando
--   viene de authenticated/anon (no es DEFINER: current_user es el del caller).
--
-- LOS DOS MENORES DEL MISMO CODIGO
--
--   · El reintento idempotente corria ANTES de verificar sucursal y sesion: con
--     el uuid de client_request_id devolvia los datos de la salvedad a
--     cualquiera. Ahora corre despues de la sucursal, la sesion y el permiso
--     sobre el pedido, y busca solo en la sucursal activa y en ese pedido.
--   · `merma_registrada` del reintento salia del motivo; un regalo con
--     regalo_mueve_stock = false por dañado decia true sin merma. Ahora dice si
--     existe la fila en mermas_stock.
--
-- Decision del dueño (2026-10-09): 'otro' y 'diferencia_precio' siguen
-- devolviendo stock. No cambia la lista de motivos.
--
-- Firmas, SECURITY DEFINER y GRANTs de registrar_salvedad y anular_salvedad:
-- como estaban (se parchea el cuerpo vivo; cada ancla tiene que aparecer
-- exactamente una vez o la migracion aborta).

-- ---------------------------------------------------------------------------
-- 0 · Andamio: reemplazo por ancla (temporal de la sesion, no queda en public).
--     Se le sacan los \r a ancla y reemplazo: el repo hace checkout con CRLF y
--     los cuerpos de prod son LF.
-- ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp.ancla(p_fn regprocedure, p_ancla text, p_nuevo text)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  v_def   text := pg_get_functiondef(p_fn);
  v_ancla text := replace(p_ancla, E'\r', '');
  v_veces int;
BEGIN
  v_veces := (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El ancla aparece % veces en % (se esperaba 1): el cuerpo vivo cambio, revisar a mano. Ancla: %',
      v_veces, p_fn, left(v_ancla, 120);
  END IF;
  EXECUTE replace(v_def, v_ancla, replace(p_nuevo, E'\r', ''));
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 1 · La columna, y quien la puede escribir
-- ---------------------------------------------------------------------------
ALTER TABLE public.salvedades_items
  ADD COLUMN lotes_devueltos jsonb;

COMMENT ON COLUMN public.salvedades_items.lotes_devueltos IS
  'A que lotes volvio la devolucion de stock de esta salvedad, y cuanta huella '
  '(pedido_item_lotes) le saco al cliente en cada uno: [{lote_id, cantidad, huella}]. '
  'La escribe registrar_salvedad y la lee anular_salvedad para sacar las unidades '
  'del mismo lote (#1050). NULL = salvedad anterior a la anotacion o sin devolucion.';

CREATE FUNCTION public.salvedades_lotes_devueltos_solo_servidor()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $fn$
BEGIN
  -- NO es SECURITY DEFINER a proposito: current_user es el del que escribe.
  -- Por REST es authenticated/anon; desde registrar_salvedad (DEFINER, de
  -- postgres) es postgres.
  IF current_user IN ('authenticated', 'anon')
     AND (TG_OP = 'INSERT' AND NEW.lotes_devueltos IS NOT NULL
          OR TG_OP = 'UPDATE' AND NEW.lotes_devueltos IS DISTINCT FROM OLD.lotes_devueltos) THEN
    RAISE EXCEPTION 'lotes_devueltos lo escribe registrar_salvedad, no se carga a mano'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$fn$;

-- Funcion de trigger: la invoca el executor, nadie la llama (CLAUDE.md).
REVOKE ALL ON FUNCTION public.salvedades_lotes_devueltos_solo_servidor() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_salvedades_lotes_devueltos_solo_servidor
  BEFORE INSERT OR UPDATE OF lotes_devueltos ON public.salvedades_items
  FOR EACH ROW EXECUTE FUNCTION public.salvedades_lotes_devueltos_solo_servidor();

-- ---------------------------------------------------------------------------
-- 2 · registrar_salvedad
-- ---------------------------------------------------------------------------
DO $registrar$
DECLARE
  v_fn constant regprocedure :=
    'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure;
BEGIN
  -- 2a · el reintento sale de arriba de todo (y se declaran las fotos)
  PERFORM pg_temp.ancla(v_fn,
$a$BEGIN
  IF p_client_request_id IS NOT NULL THEN
    SELECT id, motivo, monto_afectado, cantidad_entregada, stock_devuelto, pedido_id
      INTO v_existing
      FROM salvedades_items
     WHERE client_request_id = p_client_request_id;

    IF FOUND THEN
      RETURN jsonb_build_object(
        'success', true,
        'salvedad_id', v_existing.id,
        'monto_afectado', v_existing.monto_afectado,
        'cantidad_entregada', v_existing.cantidad_entregada,
        'stock_devuelto', v_existing.stock_devuelto,
        'merma_registrada', v_existing.motivo IN ('producto_danado', 'producto_vencido', 'faltante_stock'),
        'nuevo_total_pedido', (
          SELECT total FROM pedidos
           WHERE id = v_existing.pedido_id AND sucursal_id = v_sucursal
        ),
        'idempotent_replay', true
      );
    END IF;
  END IF;

  IF v_sucursal IS NULL THEN$a$,
$n$  -- #1050: a que lotes volvio la devolucion y cuanta huella perdio el cliente.
  v_lotes_antes           JSONB;
  v_huella_antes          JSONB;
  v_item_guc              TEXT;
BEGIN
  IF v_sucursal IS NULL THEN$n$);

  -- 2b · ... y entra despues de la sucursal, la sesion y el permiso
  PERFORM pg_temp.ancla(v_fn,
$a$  -- mig 276 (#833): sobre el pedido de una NC vigente no hay salvedad.
$a$,
$n$  -- #1050: el reintento idempotente contesta DESPUES de saber quien pregunta.
  -- Antes corria arriba de todo: con el uuid devolvia los datos de la salvedad
  -- sin sesion, sin permiso sobre el pedido y desde cualquier sucursal. Busca
  -- en la sucursal activa y en ESTE pedido, que es el que el permiso de arriba
  -- verifico. `merma_registrada` dice si hay merma, no si el motivo suele
  -- generarla (un regalo que no mueve stock no la genera).
  IF p_client_request_id IS NOT NULL THEN
    SELECT id, monto_afectado, cantidad_entregada, stock_devuelto, pedido_id
      INTO v_existing
      FROM salvedades_items
     WHERE client_request_id = p_client_request_id
       AND sucursal_id = v_sucursal
       AND pedido_id = p_pedido_id;

    IF FOUND THEN
      RETURN jsonb_build_object(
        'success', true,
        'salvedad_id', v_existing.id,
        'monto_afectado', v_existing.monto_afectado,
        'cantidad_entregada', v_existing.cantidad_entregada,
        'stock_devuelto', v_existing.stock_devuelto,
        'merma_registrada', EXISTS (
          SELECT 1 FROM mermas_stock
           WHERE salvedad_id = v_existing.id AND sucursal_id = v_sucursal
        ),
        'nuevo_total_pedido', (
          SELECT total FROM pedidos
           WHERE id = v_existing.pedido_id AND sucursal_id = v_sucursal
        ),
        'idempotent_replay', true
      );
    END IF;
  END IF;

  -- mig 276 (#833): sobre el pedido de una NC vigente no hay salvedad.
$n$);

  -- 2c · la huella, ANTES de tocar la linea: si la salvedad la deja en cero,
  --      el DELETE de pedido_items se lleva la huella en cascada.
  PERFORM pg_temp.ancla(v_fn,
$a$  IF v_cantidad_entregada > 0 THEN
    UPDATE pedido_items
$a$,
$n$  -- #1050: la huella de ESTA linea sobre los lotes, antes de tocarla
  -- (borrarla la borra en cascada) y antes de devolver (_restaurar_lotes_fefo
  -- la descuenta). La diferencia con la de despues es lo que anular_salvedad le
  -- tiene que reponer. Se lee con la linea lockeada: una anulacion concurrente
  -- sobre la misma linea no puede reponer huella entre esta foto y la de despues.
  PERFORM 1 FROM pedido_items
   WHERE id = p_pedido_item_id AND sucursal_id = v_sucursal
     FOR UPDATE;
  SELECT COALESCE(jsonb_object_agg(h.lote_id::text, h.cantidad), '{}'::jsonb)
    INTO v_huella_antes
    FROM (SELECT pil.lote_id, SUM(pil.cantidad)::int AS cantidad
            FROM pedido_item_lotes pil
           WHERE pil.pedido_item_id = p_pedido_item_id
             AND pil.sucursal_id = v_sucursal
           GROUP BY pil.lote_id) h;

  IF v_cantidad_entregada > 0 THEN
    UPDATE pedido_items
$n$);

  -- 2d · la devolucion anota a que lotes fue
  PERFORM pg_temp.ancla(v_fn,
$a$  IF v_stock_devuelto THEN
    UPDATE productos
       SET stock = stock + p_cantidad_afectada
     WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
  END IF;
$a$,
$n$  IF v_stock_devuelto THEN
    -- #1050: la devolucion vuelve a su lote por FEFO (origen 'salvedad', lista
    -- blanca del trigger). Se anota a cuales, para que anular_salvedad las saque
    -- de ESOS y no de la bolsa: el camino de bajada del trigger no mira el
    -- origen y come primero de la bolsa (lote +N, bolsa -N). El lock del
    -- producto va antes de la foto: todo cambio de stock pasa por esta fila, asi
    -- que la diferencia es solo la de este UPDATE. Mismo lugar en que antes lo
    -- tomaba el UPDATE: no cambia el orden de los locks.
    PERFORM 1 FROM productos
     WHERE id = v_item.producto_id AND sucursal_id = v_sucursal
       FOR UPDATE;
    v_lotes_antes := public._mov_lotes_foto(v_item.producto_id, v_sucursal);

    -- La huella que descuenta la devolucion es la de ESTA linea. Sin el GUC,
    -- _restaurar_lotes_fefo cae al pedido entero y se la puede sacar a otra
    -- linea del mismo producto (un regalo), y la anulacion despues se la
    -- repondria a esta: la huella cambiaba de linea. Si la linea ya se borro,
    -- su huella se fue en cascada y la devolucion no descuenta la de nadie mas.
    -- Por transaccion (229): se guarda y se restaura.
    v_item_guc := current_setting('app.stock_pedido_item_id', true);
    PERFORM set_config('app.stock_pedido_item_id', p_pedido_item_id::text, true);

    UPDATE productos
       SET stock = stock + p_cantidad_afectada
     WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;

    PERFORM set_config('app.stock_pedido_item_id', COALESCE(v_item_guc, ''), true);

    UPDATE salvedades_items
       SET lotes_devueltos = (
         WITH lotes AS (
           SELECT x.lote_id, x.cantidad
             FROM jsonb_to_recordset(public._mov_lotes_diff(v_item.producto_id, v_sucursal, v_lotes_antes, 1))
                  AS x(lote_id bigint, cantidad integer)
         ), despues AS (
           SELECT pil.lote_id, SUM(pil.cantidad)::int AS cantidad
             FROM pedido_item_lotes pil
            WHERE pil.pedido_item_id = p_pedido_item_id
              AND pil.sucursal_id = v_sucursal
            GROUP BY pil.lote_id
         ), huella AS (
           SELECT a.key::bigint AS lote_id, a.value::int - COALESCE(d.cantidad, 0) AS cantidad
             FROM jsonb_each_text(v_huella_antes) a
             LEFT JOIN despues d ON d.lote_id = a.key::bigint
            WHERE a.value::int - COALESCE(d.cantidad, 0) > 0
         )
         SELECT COALESCE(jsonb_agg(jsonb_build_object(
                  'lote_id',  COALESCE(l.lote_id, h.lote_id),
                  'cantidad', COALESCE(l.cantidad, 0),
                  'huella',   COALESCE(h.cantidad, 0))
                ORDER BY COALESCE(l.lote_id, h.lote_id)), '[]'::jsonb)
           FROM lotes l
           FULL JOIN huella h ON h.lote_id = l.lote_id
       )
     WHERE id = v_salvedad_id AND sucursal_id = v_sucursal;
  END IF;
$n$);
END
$registrar$;

-- ---------------------------------------------------------------------------
-- 3 · anular_salvedad
-- ---------------------------------------------------------------------------
DO $anular$
DECLARE
  v_fn constant regprocedure := 'public.anular_salvedad(bigint,text)'::regprocedure;
BEGIN
  PERFORM pg_temp.ancla(v_fn,
$a$  v_merma_id BIGINT;
BEGIN
$a$,
$n$  v_merma_id BIGINT;
  -- #1050
  v_item_id BIGINT;
  v_pend INTEGER;
  v_saca INTEGER;
  v_huella INTEGER;
  r_lote RECORD;
  v_g_origen TEXT; v_g_ref_tipo TEXT; v_g_ref_id TEXT; v_g_user TEXT; v_g_item TEXT;
BEGIN
$n$);

  -- La linea que queda con las unidades: la misma, o la que se vuelve a crear.
  PERFORM pg_temp.ancla(v_fn,
$a$  IF EXISTS (SELECT 1 FROM pedido_items WHERE id = v_salvedad.pedido_item_id AND sucursal_id = v_sucursal) THEN
$a$,
$n$  IF EXISTS (SELECT 1 FROM pedido_items WHERE id = v_salvedad.pedido_item_id AND sucursal_id = v_sucursal) THEN
    v_item_id := v_salvedad.pedido_item_id;
$n$);

  PERFORM pg_temp.ancla(v_fn,
$a$      COALESCE(v_salvedad.es_bonificacion, FALSE), v_salvedad.promocion_id
    );
  END IF;
$a$,
$n$      COALESCE(v_salvedad.es_bonificacion, FALSE), v_salvedad.promocion_id
    ) RETURNING id INTO v_item_id;
  END IF;
$n$);

  PERFORM pg_temp.ancla(v_fn,
$a$  IF v_salvedad.stock_devuelto THEN
    -- mig 244: la bajada sale etiquetada. Es una BAJADA, asi que la lista
    -- blanca de trg_lotes_sincronizar ni la mira --el camino de bajada no mira
    -- el origen--: sigue comiendo de la bolsa y despues FEFO, igual que antes.
    -- Lo que cambia es que el ledger deja de decir 'auto' sin referencia.
    PERFORM set_config('app.stock_origen',   'salvedad_anulada',  true);
    PERFORM set_config('app.stock_ref_tipo', 'salvedad',          true);
    PERFORM set_config('app.stock_ref_id',   p_salvedad_id::TEXT, true);
    PERFORM set_config('app.stock_user_id',  COALESCE(v_usuario_id::TEXT, ''), true);

    UPDATE productos SET stock = stock - v_salvedad.cantidad_afectada
     WHERE id = v_salvedad.producto_id AND sucursal_id = v_sucursal;
  END IF;
$a$,
$n$  IF v_salvedad.stock_devuelto THEN
    /* #1050: las unidades salen por el mismo camino por el que entraron.
       registrar_salvedad las devolvio a un lote por FEFO y anoto a cual
       (lotes_devueltos). El camino de BAJADA del trigger no mira el origen:
       come primero de la bolsa, asi que bajar el stock sin mas dejaba el lote
       +N y la bolsa -N. El molde es el de la 229 para la compra anulada:
       primero se actua sobre el lote (se le sacan las unidades anotadas, lo que
       todavia tenga), y recien despues baja el stock. Para el trigger esas
       unidades ya son bolsa, y la bajada se come exactamente esas.

       Lo que no esta en el lote (se vendio despues, o el lote se borro) y las
       salvedades anteriores a la anotacion (NULL: su devolucion fue a la bolsa,
       relevado en la migracion) salen por el camino de siempre: bolsa y despues
       FEFO, con huella para esta linea como una venta.

       La huella que la devolucion le saco al cliente en cada lote se le repone
       a la linea restituida, sin pasar lo que el lote consumio de verdad.

       set_config es por TRANSACCION (229): se guardan los GUCs y se restauran
       despues del UPDATE, para no mentirle a lo que siga en el caller. */
    v_g_origen   := current_setting('app.stock_origen', true);
    v_g_ref_tipo := current_setting('app.stock_ref_tipo', true);
    v_g_ref_id   := current_setting('app.stock_ref_id', true);
    v_g_user     := current_setting('app.stock_user_id', true);
    v_g_item     := current_setting('app.stock_pedido_item_id', true);

    PERFORM 1 FROM productos
     WHERE id = v_salvedad.producto_id AND sucursal_id = v_sucursal
       FOR UPDATE;

    v_pend := v_salvedad.cantidad_afectada;
    FOR r_lote IN
      SELECT l.id, l.cantidad, l.cantidad_restante,
             COALESCE(x.cantidad, 0) AS devuelto, COALESCE(x.huella, 0) AS huella
        FROM jsonb_to_recordset(COALESCE(v_salvedad.lotes_devueltos, '[]'::jsonb))
             AS x(lote_id bigint, cantidad integer, huella integer)
        JOIN producto_lotes l
          ON l.id = x.lote_id
         AND l.producto_id = v_salvedad.producto_id
         AND l.sucursal_id = v_sucursal
       ORDER BY l.fecha_vencimiento, l.id
         FOR UPDATE OF l
    LOOP
      v_saca := GREATEST(LEAST(r_lote.devuelto, r_lote.cantidad_restante, v_pend), 0);
      IF v_saca > 0 THEN
        UPDATE producto_lotes
           SET cantidad_restante = cantidad_restante - v_saca
         WHERE id = r_lote.id;
        v_pend := v_pend - v_saca;
      END IF;

      -- Tope: la huella de un lote no pasa lo que ese lote consumio.
      v_huella := LEAST(
        r_lote.huella,
        (r_lote.cantidad - (r_lote.cantidad_restante - v_saca))
          - (SELECT COALESCE(SUM(cantidad), 0)::int FROM pedido_item_lotes WHERE lote_id = r_lote.id));
      IF v_huella > 0 AND v_item_id IS NOT NULL THEN
        INSERT INTO pedido_item_lotes (pedido_item_id, lote_id, cantidad, sucursal_id)
        VALUES (v_item_id, r_lote.id, v_huella, v_sucursal)
        ON CONFLICT (pedido_item_id, lote_id)
          DO UPDATE SET cantidad = pedido_item_lotes.cantidad + EXCLUDED.cantidad;
      END IF;
    END LOOP;

    -- mig 244: la bajada sale etiquetada para el ledger.
    PERFORM set_config('app.stock_origen',   'salvedad_anulada',  true);
    PERFORM set_config('app.stock_ref_tipo', 'salvedad',          true);
    PERFORM set_config('app.stock_ref_id',   p_salvedad_id::TEXT, true);
    PERFORM set_config('app.stock_user_id',  COALESCE(v_usuario_id::TEXT, ''), true);
    PERFORM set_config('app.stock_pedido_item_id', COALESCE(v_item_id::TEXT, ''), true);

    UPDATE productos SET stock = stock - v_salvedad.cantidad_afectada
     WHERE id = v_salvedad.producto_id AND sucursal_id = v_sucursal;

    PERFORM set_config('app.stock_origen',         COALESCE(v_g_origen, ''),   true);
    PERFORM set_config('app.stock_ref_tipo',       COALESCE(v_g_ref_tipo, ''), true);
    PERFORM set_config('app.stock_ref_id',         COALESCE(v_g_ref_id, ''),   true);
    PERFORM set_config('app.stock_user_id',        COALESCE(v_g_user, ''),     true);
    PERFORM set_config('app.stock_pedido_item_id', COALESCE(v_g_item, ''),     true);
  END IF;
$n$);
END
$anular$;

-- ---------------------------------------------------------------------------
-- 4 · Verificacion estructural
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  v_reg text := pg_get_functiondef('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure);
  v_anu text := pg_get_functiondef('public.anular_salvedad(bigint,text)'::regprocedure);
BEGIN
  -- El reintento: una sola vez, despues del permiso, y sin el motivo como merma.
  IF (length(v_reg) - length(replace(v_reg, 'idempotent_replay', ''))) / length('idempotent_replay') <> 1
     OR position('idempotent_replay' IN v_reg) < position('No autorizado para este pedido' IN v_reg)
     OR position('Usuario no autenticado' IN v_reg) > position('idempotent_replay' IN v_reg)
     OR v_reg LIKE '%v_existing.motivo IN%'
     OR v_reg NOT LIKE '%AND pedido_id = p_pedido_id;%' THEN
    RAISE EXCEPTION 'registrar_salvedad: el reintento no quedo despues del permiso';
  END IF;
  -- La lista de motivos que devuelven stock no cambia (decision del dueño).
  IF v_reg NOT LIKE '%IN (''cliente_rechaza'', ''error_pedido'', ''diferencia_precio'', ''entregado_otro_cliente'', ''otro'') THEN%' THEN
    RAISE EXCEPTION 'registrar_salvedad: cambio la lista de motivos que devuelven stock';
  END IF;
  IF v_reg NOT LIKE '%SET lotes_devueltos%' OR v_reg NOT LIKE '%SECURITY DEFINER%' THEN
    RAISE EXCEPTION 'registrar_salvedad no anota lotes_devueltos';
  END IF;
  IF v_anu NOT LIKE '%v_salvedad.lotes_devueltos%'
     OR v_anu NOT LIKE '%RETURNING id INTO v_item_id%'
     OR v_anu NOT LIKE '%app.stock_pedido_item_id'', COALESCE(v_g_item%'
     OR v_anu NOT LIKE '%SECURITY DEFINER%' THEN
    RAISE EXCEPTION 'anular_salvedad no quedo como se esperaba';
  END IF;
  -- El trigger de lotes no se toco: 'salvedad' sigue en la lista blanca y
  -- 'salvedad_anulada' no entra (es una bajada).
  IF pg_get_functiondef('public.sincronizar_lotes_stock()'::regprocedure) NOT LIKE '%''salvedad''%'
     OR pg_get_functiondef('public.sincronizar_lotes_stock()'::regprocedure) LIKE '%salvedad_anulada%' THEN
    RAISE EXCEPTION 'cambio la lista blanca de sincronizar_lotes_stock';
  END IF;
  IF has_function_privilege('authenticated', 'public.salvedades_lotes_devueltos_solo_servidor()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.salvedades_lotes_devueltos_solo_servidor()', 'EXECUTE') THEN
    RAISE EXCEPTION 'la funcion de trigger quedo ejecutable por la API';
  END IF;
END
$verif$;

-- ---------------------------------------------------------------------------
-- 5 · El legado: ninguna salvedad viva devolvio a un lote sin anotarlo
--     (relevado el 2026-10-09: las 14 candidatas son anteriores al primer lote)
-- ---------------------------------------------------------------------------
DO $legado$
DECLARE
  v_n int;
BEGIN
  SELECT count(*) INTO v_n
    FROM salvedades_items s
   WHERE s.stock_devuelto
     AND s.estado_resolucion IS DISTINCT FROM 'anulada'
     AND s.lotes_devueltos IS NULL
     AND EXISTS (SELECT 1 FROM producto_lotes l
                  WHERE l.producto_id = s.producto_id
                    AND l.sucursal_id = s.sucursal_id
                    AND l.created_at < s.created_at);
  IF v_n > 0 THEN
    RAISE EXCEPTION '% salvedad(es) vivas pudieron devolver a un lote sin anotarlo: anularlas sacaria de la bolsa. Revisar a mano antes de aplicar.', v_n;
  END IF;
END
$legado$;

-- ---------------------------------------------------------------------------
-- 6 · Ensayo #1050 con datos reales (se deshace solo: termina en una excepcion
--     atrapada). Es scripts/test-anular-salvedad-lote-bolsa.sql, que antes de
--     esta migracion daba 10 fallas.
-- ---------------------------------------------------------------------------
DO $ensayo$
DECLARE
  v_admin    uuid;
  v_otro     uuid;
  v_suc      bigint;
  v_suc2     bigint;
  v_cliente  bigint;
  v_prod     bigint;
  v_lote_a   bigint;
  v_lote_b   bigint;
  v_res      jsonb;
  v_ped      bigint;
  v_item     bigint;
  v_salv     bigint;
  v_req      uuid;
  v_foto     jsonb;
  v_motivo   text;
  v_hoy      date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_fallas   text[] := '{}';
BEGIN
 -- Todo corre en este bloque interno, que termina SIEMPRE en una excepcion:
 -- lo que crea se deshace. El OK se atrapa abajo y queda como NOTICE, asi el
 -- mismo DO sirve suelto y como compuerta dentro de la migracion.
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

  -- Alguien de la misma sucursal que no es admin, ni encargado, ni el
  -- transportista del pedido (el pedido del ensayo no tiene transportista).
  SELECT us.usuario_id INTO v_otro
    FROM usuario_sucursales us
    JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo AND pf.rol NOT IN ('admin', 'encargado')
   WHERE us.sucursal_id = v_suc
   ORDER BY us.usuario_id
   LIMIT 1;
  -- Y otra sucursal activa del mismo admin, si tiene.
  SELECT us.sucursal_id INTO v_suc2
    FROM usuario_sucursales us
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   WHERE us.usuario_id = v_admin AND us.sucursal_id <> v_suc
   ORDER BY us.sucursal_id
   LIMIT 1;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  SELECT id INTO v_cliente FROM clientes
   WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;
  IF v_cliente IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita un cliente activo en la sucursal %', v_suc;
  END IF;

  -- stock / suma de lotes / bolsa, y cada lote por id.
  CREATE FUNCTION pg_temp.foto(p_prod bigint) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('stock', pr.stock, 'lote', l.r, 'bolsa', pr.stock - l.r)
      FROM public.productos pr
      JOIN LATERAL (SELECT COALESCE(SUM(cantidad_restante), 0)::int AS r
                      FROM public.producto_lotes WHERE producto_id = pr.id) l ON true
     WHERE pr.id = p_prod;
  $f$;
  CREATE FUNCTION pg_temp.lote(p_lote bigint) RETURNS int LANGUAGE sql AS $f$
    SELECT cantidad_restante FROM public.producto_lotes WHERE id = p_lote;
  $f$;
  -- huella del pedido sobre los lotes de un producto
  CREATE FUNCTION pg_temp.huella(p_ped bigint, p_prod bigint) RETURNS int LANGUAGE sql AS $f$
    SELECT COALESCE(SUM(pil.cantidad), 0)::int
      FROM public.pedido_item_lotes pil
      JOIN public.pedido_items pi ON pi.id = pil.pedido_item_id
     WHERE pi.pedido_id = p_ped AND pi.producto_id = p_prod;
  $f$;

  -- -------------------------------------------------------------------------
  -- A · los cinco motivos que devuelven stock
  -- -------------------------------------------------------------------------
  FOREACH v_motivo IN ARRAY ARRAY['cliente_rechaza', 'error_pedido', 'diferencia_precio',
                                  'entregado_otro_cliente', 'otro']
  LOOP
    INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
    VALUES ('ZZ ensayo 1050 ' || v_motivo, 100, 90, 60, v_suc) RETURNING id INTO v_prod;
    INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, usuario_id)
    VALUES (v_prod, v_suc, v_hoy + 90, 100, 50, v_admin);

    v_res := public.crear_pedido_completo(
      v_cliente, 1000, v_admin,
      jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 10, 'precio_unitario', 100)),
      'ensayo 1050');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'A/% · no se pudo crear el pedido: %', v_motivo, v_res;
    END IF;
    v_ped := (v_res->>'pedido_id')::bigint;
    SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped AND producto_id = v_prod;

    v_foto := pg_temp.foto(v_prod);
    IF v_foto <> '{"stock":80,"lote":50,"bolsa":30}'::jsonb THEN
      RAISE EXCEPTION 'A/% · el pedido no dejo el punto de partida esperado: %', v_motivo, v_foto;
    END IF;

    v_res := public.registrar_salvedad(v_ped, v_item, 10, v_motivo,
                                       'ensayo 1050, se anula enseguida', NULL, true, NULL);
    IF NOT COALESCE((v_res->>'success')::boolean, false)
       OR NOT COALESCE((v_res->>'stock_devuelto')::boolean, false) THEN
      RAISE EXCEPTION 'A/% · registrar: %', v_motivo, v_res;
    END IF;
    v_salv := (v_res->>'salvedad_id')::bigint;

    v_foto := pg_temp.foto(v_prod);
    IF v_foto <> '{"stock":90,"lote":60,"bolsa":30}'::jsonb THEN
      RAISE EXCEPTION 'A/% · la salvedad no volvio al lote: %', v_motivo, v_foto;
    END IF;

    v_res := public.anular_salvedad(v_salv, 'ensayo 1050');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'A/% · anular: %', v_motivo, v_res;
    END IF;

    v_foto := pg_temp.foto(v_prod);
    IF v_foto <> '{"stock":80,"lote":50,"bolsa":30}'::jsonb THEN
      v_fallas := v_fallas || format('A/%s · anular dejo %s; tenia que volver a {"stock":80,"lote":50,"bolsa":30}',
                                     v_motivo, v_foto);
    END IF;
    IF pg_temp.huella(v_ped, v_prod) <> 0 THEN
      v_fallas := v_fallas || format('A/%s · el pedido salio de la bolsa y anular le dejo %s de huella en el lote',
                                     v_motivo, pg_temp.huella(v_ped, v_prod));
    END IF;
  END LOOP;

  -- -------------------------------------------------------------------------
  -- B · el mismo lote al que volvieron, no el primero por FEFO
  -- -------------------------------------------------------------------------
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1050 B', 100, 110, 60, v_suc) RETURNING id INTO v_prod;
  INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, usuario_id)
  VALUES (v_prod, v_suc, v_hoy + 30, 50, 50, v_admin) RETURNING id INTO v_lote_a;
  INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, usuario_id)
  VALUES (v_prod, v_suc, v_hoy + 90, 100, 40, v_admin) RETURNING id INTO v_lote_b;

  v_res := public.crear_pedido_completo(
    v_cliente, 1000, v_admin,
    jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 10, 'precio_unitario', 100)),
    'ensayo 1050 B');
  v_ped := (v_res->>'pedido_id')::bigint;
  SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped AND producto_id = v_prod;

  v_res := public.registrar_salvedad(v_ped, v_item, 10, 'otro', 'ensayo 1050 B, mismo lote', NULL, true, NULL);
  v_salv := (v_res->>'salvedad_id')::bigint;
  IF pg_temp.lote(v_lote_a) <> 50 OR pg_temp.lote(v_lote_b) <> 50 THEN
    RAISE EXCEPTION 'B · la salvedad no volvio al lote B: A % B %', pg_temp.lote(v_lote_a), pg_temp.lote(v_lote_b);
  END IF;

  v_res := public.anular_salvedad(v_salv, 'ensayo 1050 B');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'B · anular: %', v_res;
  END IF;
  v_foto := pg_temp.foto(v_prod);
  IF pg_temp.lote(v_lote_a) <> 50 OR pg_temp.lote(v_lote_b) <> 40
     OR v_foto <> '{"stock":100,"lote":90,"bolsa":10}'::jsonb THEN
    v_fallas := v_fallas || format('B · anular dejo lote A %s, lote B %s, %s; tenia que ser A 50, B 40, {"stock":100,"lote":90,"bolsa":10}',
                                   pg_temp.lote(v_lote_a), pg_temp.lote(v_lote_b), v_foto);
  END IF;

  -- -------------------------------------------------------------------------
  -- F · la huella vuelve al cliente (parcial y total)
  -- -------------------------------------------------------------------------
  FOREACH v_motivo IN ARRAY ARRAY['parcial', 'total']
  LOOP
    INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
    VALUES ('ZZ ensayo 1050 F ' || v_motivo, 100, 50, 60, v_suc) RETURNING id INTO v_prod;
    INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, usuario_id)
    VALUES (v_prod, v_suc, v_hoy + 90, 100, 50, v_admin) RETURNING id INTO v_lote_a;

    v_res := public.crear_pedido_completo(
      v_cliente, 1000, v_admin,
      jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 10, 'precio_unitario', 100)),
      'ensayo 1050 F');
    v_ped := (v_res->>'pedido_id')::bigint;
    SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped AND producto_id = v_prod;
    IF pg_temp.huella(v_ped, v_prod) <> 10 OR pg_temp.foto(v_prod) <> '{"stock":40,"lote":40,"bolsa":0}'::jsonb THEN
      RAISE EXCEPTION 'F/% · el pedido no salio del lote con huella: huella %, %',
        v_motivo, pg_temp.huella(v_ped, v_prod), pg_temp.foto(v_prod);
    END IF;

    v_res := public.registrar_salvedad(v_ped, v_item, CASE v_motivo WHEN 'parcial' THEN 4 ELSE 10 END,
                                       'cliente_rechaza', NULL, NULL, true, NULL);
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'F/% · registrar: %', v_motivo, v_res;
    END IF;
    v_salv := (v_res->>'salvedad_id')::bigint;
    IF pg_temp.huella(v_ped, v_prod) <> (CASE v_motivo WHEN 'parcial' THEN 6 ELSE 0 END) THEN
      RAISE EXCEPTION 'F/% · la salvedad no le saco la huella al cliente: %', v_motivo, pg_temp.huella(v_ped, v_prod);
    END IF;

    v_res := public.anular_salvedad(v_salv, 'ensayo 1050 F');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'F/% · anular: %', v_motivo, v_res;
    END IF;
    v_foto := pg_temp.foto(v_prod);
    IF v_foto <> '{"stock":40,"lote":40,"bolsa":0}'::jsonb OR pg_temp.huella(v_ped, v_prod) <> 10
       OR NOT EXISTS (SELECT 1 FROM pedido_item_lotes pil JOIN pedido_items pi ON pi.id = pil.pedido_item_id
                       WHERE pi.pedido_id = v_ped AND pil.lote_id = v_lote_a AND pil.cantidad = 10) THEN
      v_fallas := v_fallas || format('F/%s · anular dejo %s y huella %s; tenia que ser {"stock":40,"lote":40,"bolsa":0} y 10 en el lote',
                                     v_motivo, v_foto, pg_temp.huella(v_ped, v_prod));
    END IF;
  END LOOP;

  -- -------------------------------------------------------------------------
  -- H · la huella es de la linea, no del pedido: dos lineas del mismo producto.
  --     Bolsa 24, lote 100 con 50. Linea A de 24 (sale de la bolsa) y linea B
  --     de 2 (sale del lote: huella B = 2). Salvedad de 5 sobre A: vuelve al
  --     lote, pero A no tenia huella ahi; la de B no se toca. Anular: A sigue
  --     sin huella y B con 2. Antes de #1050 la devolucion le sacaba la huella
  --     a B y la anulacion se la daba a A.
  -- -------------------------------------------------------------------------
  DECLARE
    v_a bigint;
    v_b bigint;
  BEGIN
    INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
    VALUES ('ZZ ensayo 1050 H', 100, 74, 60, v_suc) RETURNING id INTO v_prod;
    INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, usuario_id)
    VALUES (v_prod, v_suc, v_hoy + 90, 100, 50, v_admin);
    v_res := public.crear_pedido_completo(
      v_cliente, 2600, v_admin,
      jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 24, 'precio_unitario', 100),
                        jsonb_build_object('producto_id', v_prod, 'cantidad', 2, 'precio_unitario', 100)),
      'ensayo 1050 H');
    v_ped := (v_res->>'pedido_id')::bigint;
    SELECT min(id), max(id) INTO v_a, v_b FROM pedido_items WHERE pedido_id = v_ped;
    IF (SELECT COALESCE(SUM(cantidad), 0) FROM pedido_item_lotes WHERE pedido_item_id = v_b) <> 2
       OR (SELECT COALESCE(SUM(cantidad), 0) FROM pedido_item_lotes WHERE pedido_item_id = v_a) <> 0 THEN
      RAISE EXCEPTION 'H · el alta no dejo la huella esperada (A 0, B 2)';
    END IF;

    v_res := public.registrar_salvedad(v_ped, v_a, 5, 'cliente_rechaza', NULL, NULL, true, NULL);
    v_salv := (v_res->>'salvedad_id')::bigint;
    IF (SELECT COALESCE(SUM(cantidad), 0) FROM pedido_item_lotes WHERE pedido_item_id = v_b) <> 2 THEN
      v_fallas := v_fallas || format('H · la salvedad sobre A le saco la huella a B: B quedo en %s',
        (SELECT COALESCE(SUM(cantidad), 0) FROM pedido_item_lotes WHERE pedido_item_id = v_b));
    END IF;

    v_res := public.anular_salvedad(v_salv, 'ensayo 1050 H');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'H · anular: %', v_res;
    END IF;
    IF (SELECT COALESCE(SUM(cantidad), 0) FROM pedido_item_lotes WHERE pedido_item_id = v_a) <> 0
       OR (SELECT COALESCE(SUM(cantidad), 0) FROM pedido_item_lotes WHERE pedido_item_id = v_b) <> 2 THEN
      v_fallas := v_fallas || format('H · despues de anular la huella quedo A %s, B %s; tenia que ser A 0, B 2',
        (SELECT COALESCE(SUM(cantidad), 0) FROM pedido_item_lotes WHERE pedido_item_id = v_a),
        (SELECT COALESCE(SUM(cantidad), 0) FROM pedido_item_lotes WHERE pedido_item_id = v_b));
    END IF;
  END;

  -- -------------------------------------------------------------------------
  -- G · lotes_devueltos no se escribe por REST
  -- -------------------------------------------------------------------------
  DECLARE
    v_n int;
  BEGIN
    SET LOCAL ROLE authenticated;
    UPDATE salvedades_items SET lotes_devueltos = '[]'::jsonb WHERE id = v_salv;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RAISE EXCEPTION 'filas %', v_n USING ERRCODE = 'ZZ002';
  EXCEPTION
    WHEN SQLSTATE '42501' THEN
      IF SQLERRM NOT LIKE '%lotes_devueltos%' THEN
        v_fallas := v_fallas || format('G · error inesperado al escribir lotes_devueltos como authenticated: %s', SQLERRM);
      END IF;
    WHEN SQLSTATE 'ZZ002' THEN
      v_fallas := v_fallas || format('G · authenticated escribio lotes_devueltos (%s)', SQLERRM);
  END;

  -- -------------------------------------------------------------------------
  -- D · reintento: merma_registrada dice si hay merma
  -- -------------------------------------------------------------------------
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1050 D', 100, 90, 60, v_suc) RETURNING id INTO v_prod;
  v_res := public.crear_pedido_completo(
    v_cliente, 1000, v_admin,
    jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 10, 'precio_unitario', 100)),
    'ensayo 1050 D');
  v_ped := (v_res->>'pedido_id')::bigint;
  SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped AND producto_id = v_prod;
  v_req := gen_random_uuid();

  -- La fila que deja una salvedad por dañado sobre un regalo que no mueve
  -- stock: motivo de merma, sin devolucion y sin fila en mermas_stock.
  INSERT INTO salvedades_items (
    pedido_id, pedido_item_id, producto_id, cantidad_original, cantidad_afectada,
    cantidad_entregada, motivo, monto_afectado, precio_unitario, reportado_por,
    stock_devuelto, estado_resolucion, sucursal_id, client_request_id, es_bonificacion
  ) VALUES (
    v_ped, v_item, v_prod, 10, 2, 8, 'producto_danado', 0, 0, v_admin,
    false, 'pendiente', v_suc, v_req, true
  ) RETURNING id INTO v_salv;

  v_res := public.registrar_salvedad(v_ped, v_item, 2, 'producto_danado', NULL, NULL, true, v_req);
  IF NOT COALESCE((v_res->>'idempotent_replay')::boolean, false) THEN
    RAISE EXCEPTION 'D · el reintento no reconocio la salvedad: %', v_res;
  END IF;
  IF COALESCE((v_res->>'merma_registrada')::boolean, true) THEN
    v_fallas := v_fallas || format('D · el reintento dice merma_registrada = %s y no hay merma', v_res->>'merma_registrada');
  END IF;

  -- -------------------------------------------------------------------------
  -- E · reintento sin sesion / sin permiso / desde otra sucursal
  -- -------------------------------------------------------------------------
  -- (sigue usando la salvedad de D: tiene client_request_id)
  PERFORM set_config('request.jwt.claims', '{}', true);
  v_res := public.registrar_salvedad(v_ped, v_item, 2, 'producto_danado', NULL, NULL, true, v_req);
  IF v_res ? 'salvedad_id' OR COALESCE((v_res->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('E · sin sesion, el reintento devolvio los datos: %s', v_res);
  END IF;

  IF v_otro IS NOT NULL THEN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_otro)::text, true);
    v_res := public.registrar_salvedad(v_ped, v_item, 2, 'producto_danado', NULL, NULL, true, v_req);
    IF v_res ? 'salvedad_id' OR COALESCE((v_res->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('E · un usuario sin permiso sobre el pedido recibio los datos: %s', v_res);
    END IF;
  ELSE
    v_fallas := v_fallas || 'E · no hay un usuario sin rol de entrega en la sucursal para probar el permiso'::text;
  END IF;

  IF v_suc2 IS NOT NULL THEN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc2::text)::text, true);
    v_res := public.registrar_salvedad(v_ped, v_item, 2, 'producto_danado', NULL, NULL, true, v_req);
    IF v_res ? 'salvedad_id' OR COALESCE((v_res->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('E · desde otra sucursal el reintento devolvio los datos: %s', v_res);
    END IF;
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (% fallas, todo revertido):\n- %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE EXCEPTION 'ensayo-1050-ok' USING ERRCODE = 'ZZ0OK';
 EXCEPTION WHEN SQLSTATE 'ZZ0OK' THEN
  RAISE NOTICE 'ENSAYO OK (todo revertido)';
 END;
END
$ensayo$;
