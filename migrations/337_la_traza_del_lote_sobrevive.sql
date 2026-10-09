-- La traza lote -> cliente sobrevive a la edicion de la compra y a las
-- salvedades (#1054, #1073)
--
-- #1054 · EDITAR LA COMPRA BORRABA LA TRAZA
--
--   sincronizar_lotes_compra (la app la llama en CADA edicion de una compra,
--   aunque no cambien los vencimientos) hacia DELETE de todos los lotes de la
--   compra y los volvia a crear con ids nuevos, conservando lo consumido por
--   (producto, fecha). Tres efectos, medidos en prod con
--   scripts/test-lotes-trazabilidad-1054-1073.sql:
--     - pedido_item_lotes cuelga del lote con ON DELETE CASCADE: se iba la traza
--       de a que cliente se vendio cada lote (caso A: [{lote 247, 15}] -> []).
--     - movimiento_sucursal_item_lotes cuelga con ON DELETE SET NULL: se iba la
--       de las transferencias (caso B: lote_id 249 -> NULL).
--     - Si la edicion corregia un vencimiento, el lote "nuevo" no encontraba lo
--       consumido y nacia lleno: lote +N, bolsa -N (caso C: [50]/40 -> [90]/0),
--       y anular una salvedad despues volvia a comer de la bolsa (#1050 por
--       otra puerta; caso C2).
--
--   El arreglo: la sincronizacion ACTUALIZA los lotes que ya existen, producto
--   por producto, conservando su id y lo consumido:
--     1. Misma fecha: se actualiza la cantidad del mismo lote.
--     2. Una fecha vieja que ya no esta y una nueva que aparece (del mismo
--        producto): es una correccion de vencimiento, cambia la fecha del MISMO
--        lote. Si en una edicion se corrigen varias fechas de un producto, se
--        emparejan en orden de vencimiento.
--     3. Una fecha nueva sin pareja: lote nuevo, como siempre (nace lleno: son
--        unidades de la bolsa que pasan a tener vencimiento).
--     4. Un lote que de verdad desaparece (decision del dueño, 2026-10-09):
--        - fusion: si otro vencimiento del producto en la compra crecio en esta
--          edicion lo suficiente para absorber lo consumido del que se va (10 +
--          10 -> 20), lo consumido y la traza pasan a ese (al que vence
--          primero). Lo consumido no es opcional: sin sumarlo, el que queda
--          nace mas lleno (lote +N, bolsa -N, el mismo error). Es el molde de
--          la 236: reapuntar, no clonar y borrar. Si el otro vencimiento NO
--          crecio (el usuario solo saco una fila), no es una fusion: absorber
--          lo consumido le bajaria el restante y mandaria unidades con fecha a
--          la bolsa (lo encontro la revision adversarial).
--        - si no hay fusion y tiene traza (ventas, transferencias, o la huella
--          que una salvedad viva anoto), el lote no se borra: queda solo para
--          la traza (columna nueva solo_traza), con cantidad = lo que ya salio
--          y restante 0. No mueve stock ni bolsa, un retiro sigue encontrando a
--          los clientes, no recibe devoluciones (CHECK) y la app no lo precarga
--          en la compra. Si la misma fecha vuelve con otra cantidad, vuelve a
--          ser un vencimiento de la compra; si vuelve igual (un bundle viejo
--          que todavia lo precarga), no pasa nada.
--        - sin traza, se borra como siempre.
--     Las anotaciones de las salvedades (salvedades_items.lotes_devueltos) se
--     reapuntan al mismo destino, asi anular sigue sacando del lote correcto;
--     anular suma por lote las entradas que caen en el mismo.
--
-- #1073 · CUATRO BORDES DE LAS SALVEDADES
--
--   1. Merma sobre la linea entera: registrar borraba la linea y su huella se
--      iba en cascada; como la merma no devuelve stock no se anotaba nada, y
--      anular reponia la linea sin huella. Ahora registrar anota la huella que
--      perdio el cliente devuelva stock o no, y anular la repone.
--   2. Regalo del mismo producto: la resincronizacion del regalo devolvia sin
--      el GUC de la linea del regalo, y _restaurar_lotes_fefo le descontaba la
--      huella a la linea principal. Ahora la devolucion del regalo lleva su
--      propia linea en el GUC (guardado y restaurado: 229).
--   3. Orden de locks: registrar bloqueaba la linea y despues el pedido;
--      anular, al reves. Ahora registrar bloquea el pedido primero, como anular
--      y como cancelar_pedido_con_stock.
--   4. La devolucion que caia en otro lote (decision del dueño, 2026-10-09: se
--      corrige). _restaurar_lotes_fefo devuelve primero a los lotes de donde
--      salio la linea (su huella; la del pedido si el caller no dijo la linea),
--      hasta lo que cada uno le dio, y recien lo que sobra va por FEFO. Lo que
--      devuelve el cliente trae la fecha de ESE lote. Para que valga tambien
--      con la linea entera, registrar devuelve el stock ANTES de borrar la
--      linea (con la linea borrada ya no hay huella que mirar).
--
-- CLAUDE.md: stock por el trigger (ninguna funcion nueva toca productos.stock
-- salvo las que ya lo hacian), la lista blanca de origenes no cambia, y todo
-- GUC que se pisa se guarda y se restaura.
--
-- Firmas, SECURITY DEFINER y GRANTs: como estaban. CREATE OR REPLACE conserva
-- los privilegios; los cuerpos de registrar/anular se parchean en vivo (cada
-- fragmento tiene que aparecer exactamente una vez o la migracion aborta).

-- ---------------------------------------------------------------------------
-- 0 - Auxiliares de parcheo (pg_temp, se borran al final)
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

-- Reemplaza desde el comienzo de `p_desde` hasta el comienzo de `p_hasta`.
CREATE OR REPLACE FUNCTION pg_temp.parchar_tramo(p_def text, p_desde text, p_hasta text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
  v_i int;
  v_j int;
BEGIN
  IF (length(p_def) - length(replace(p_def, p_desde, ''))) / length(p_desde) <> 1
     OR (length(p_def) - length(replace(p_def, p_hasta, ''))) / length(p_hasta) <> 1 THEN
    RAISE EXCEPTION '%: los bordes del tramo no aparecen exactamente una vez: revisar a mano', p_que;
  END IF;
  v_i := strpos(p_def, p_desde);
  v_j := strpos(p_def, p_hasta);
  IF v_j <= v_i THEN
    RAISE EXCEPTION '%: el tramo esta al reves: revisar a mano', p_que;
  END IF;
  RETURN substr(p_def, 1, v_i - 1) || p_nuevo || substr(p_def, v_j);
END
$fn$;

-- ---------------------------------------------------------------------------
-- 0b - El lote que queda solo para la traza
-- ---------------------------------------------------------------------------
-- Un vencimiento que el usuario saca de la compra, si tiene traza, no se borra
-- (ver encabezado). Tiene que quedar MARCADO: sin la marca es un lote agotado
-- comun, con hueco (cantidad - restante), y la primera devolucion sin huella lo
-- volveria a llenar por FEFO -- reviviendo una fecha que el usuario dijo que
-- no existe --, y el modal de la compra lo precargaria como fila editable. El
-- CHECK hace que ningun camino lo pueda rellenar en silencio: el que lo intente
-- falla.

ALTER TABLE public.producto_lotes
  ADD COLUMN solo_traza boolean NOT NULL DEFAULT false;

ALTER TABLE public.producto_lotes
  ADD CONSTRAINT producto_lotes_solo_traza_vacio
  CHECK (NOT solo_traza OR cantidad_restante = 0);

COMMENT ON COLUMN public.producto_lotes.solo_traza IS
  'Vencimiento que se saco de la compra pero tenia traza (pedido_item_lotes, transferencias o una salvedad viva): queda agotado, con cantidad = lo que ya salio, solo para que un retiro encuentre a los clientes. No recibe devoluciones ni se precarga en la compra (mig 337, #1054).';

-- ---------------------------------------------------------------------------
-- 1 - sincronizar_lotes_compra: actualiza, no borra y recrea (#1054)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.sincronizar_lotes_compra(p_compra_id bigint, p_lotes jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal  bigint := public.current_sucursal_id();
  v_rol       text;
  v_estado    text;
  v_tocados   bigint[] := ARRAY[]::bigint[];
  v_grupos    integer := 0;
  v_clamp     integer;
  v_avisos    jsonb := '[]'::jsonb;
  -- #1054: a donde fue a parar cada lote que tenia la compra (id viejo -> id
  -- que lo representa ahora, o null si se borro). Con esto se reapuntan las
  -- anotaciones de las salvedades.
  v_destino   jsonb := '{}'::jsonb;
  -- Cuanto crecio en esta edicion cada lote que queda del producto (id ->
  -- unidades). Es lo que puede absorber de uno que desaparece: una fusion
  -- (10 + 10 -> 20) hace crecer al que queda; sacar una fila sin tocar la otra,
  -- no.
  v_crecio    jsonb;
  v_nuevo     bigint;
  v_sobrante  bigint;
  v_cant      integer;
  v_cons      integer;
  v_prod      bigint;
  r           record;
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la sucursal activa';
  END IF;

  SELECT rol INTO v_rol FROM public.perfiles WHERE id = auth.uid();
  IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin o encargado';
  END IF;

  -- #1054: la compra, las salvedades que anotaron sus lotes y los lotes, en ese
  -- orden: dos ediciones a la vez de la misma compra se serializan, y una
  -- anulacion (que bloquea su salvedad antes que los lotes) no se cruza con
  -- esta edicion en un deadlock.
  SELECT estado INTO v_estado
    FROM public.compras
   WHERE id = p_compra_id AND sucursal_id = v_sucursal
     FOR UPDATE;

  IF v_estado IS NULL THEN
    RAISE EXCEPTION 'La compra % no existe en esta sucursal', p_compra_id;
  END IF;
  IF v_estado = 'cancelada' THEN
    RAISE EXCEPTION 'La compra % esta cancelada: no se le pueden cargar vencimientos', p_compra_id;
  END IF;

  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(COALESCE(p_lotes, '[]'::jsonb)) e
     WHERE e->>'producto_id' IS NULL
        OR e->>'fecha_vencimiento' IS NULL
        OR e->>'cantidad' IS NULL
        OR (e->>'cantidad')::integer <= 0
  ) THEN
    RAISE EXCEPTION 'Hay lotes sin producto, sin fecha o con cantidad no positiva en el payload';
  END IF;

  FOR v_prod IN
    SELECT DISTINCT (e->>'producto_id')::bigint
      FROM jsonb_array_elements(COALESCE(p_lotes, '[]'::jsonb)) e
  LOOP
    IF NOT EXISTS (SELECT 1 FROM public.productos
                    WHERE id = v_prod AND sucursal_id = v_sucursal) THEN
      RAISE EXCEPTION 'El producto % no existe en esta sucursal', v_prod;
    END IF;
  END LOOP;

  PERFORM 1
     FROM public.salvedades_items s
    WHERE s.sucursal_id = v_sucursal
      AND s.estado_resolucion <> 'anulada'
      AND EXISTS (
        SELECT 1
          FROM jsonb_array_elements(CASE WHEN jsonb_typeof(s.lotes_devueltos) = 'array'
                                         THEN s.lotes_devueltos ELSE '[]'::jsonb END) e
          JOIN public.producto_lotes l ON l.id = (e->>'lote_id')::bigint
         WHERE l.compra_id = p_compra_id)
      FOR UPDATE OF s;

  PERFORM 1 FROM public.producto_lotes
   WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
     FOR UPDATE;

  SELECT COALESCE(jsonb_object_agg(id::text, id), '{}'::jsonb)
    INTO v_destino
    FROM public.producto_lotes
   WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal;

  -- Producto por producto: los lotes que la compra ya tiene contra la foto que
  -- manda la app. Cada fila del plan es un lote que se actualiza (id y fecha),
  -- uno que se crea (sin id) o uno que desaparece (sin fecha). Los que ya
  -- quedaron solo para la traza no son vencimientos de la compra: no se
  -- emparejan ni desaparecen; solo vuelven si llega su misma fecha.
  FOR v_prod IN
    SELECT producto_id FROM public.producto_lotes
     WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
    UNION
    SELECT (e->>'producto_id')::bigint
      FROM jsonb_array_elements(COALESCE(p_lotes, '[]'::jsonb)) e
     ORDER BY 1
  LOOP
    v_tocados := v_tocados || v_prod;
    v_crecio  := '{}'::jsonb;

    FOR r IN
      WITH viejos AS (
        SELECT l.id, l.fecha_vencimiento AS fecha, l.cantidad AS cant_vieja, l.solo_traza
          FROM public.producto_lotes l
         WHERE l.compra_id = p_compra_id
           AND l.sucursal_id = v_sucursal
           AND l.producto_id = v_prod
      ), nuevos AS (
        SELECT (e->>'fecha_vencimiento')::date           AS fecha,
               SUM((e->>'cantidad')::integer)::integer   AS cantidad
          FROM jsonb_array_elements(COALESCE(p_lotes, '[]'::jsonb)) e
         WHERE (e->>'producto_id')::bigint = v_prod
         GROUP BY 1
      ), exactos AS (
        SELECT v.id, n.fecha, n.cantidad, v.cant_vieja, v.solo_traza
          FROM viejos v JOIN nuevos n ON n.fecha = v.fecha
      ), viejos_resto AS (
        SELECT v.id, v.cant_vieja, row_number() OVER (ORDER BY v.fecha, v.id) AS rn
          FROM viejos v
         WHERE NOT v.solo_traza
           AND v.id NOT IN (SELECT id FROM exactos)
      ), nuevos_resto AS (
        SELECT n.fecha, n.cantidad, row_number() OVER (ORDER BY n.fecha) AS rn
          FROM nuevos n
         WHERE n.fecha NOT IN (SELECT fecha FROM exactos)
      )
      SELECT id, fecha, cantidad, cant_vieja, solo_traza, 1 AS orden FROM exactos
      UNION ALL
      SELECT vr.id, nr.fecha, nr.cantidad, vr.cant_vieja, false,
             CASE WHEN vr.id IS NULL THEN 2 WHEN nr.fecha IS NULL THEN 3 ELSE 1 END
        FROM viejos_resto vr
        FULL JOIN nuevos_resto nr ON nr.rn = vr.rn
       ORDER BY 6
    LOOP
      IF r.id IS NOT NULL AND r.fecha IS NOT NULL THEN
        v_grupos := v_grupos + 1;

        -- Un lote solo para la traza que vuelve tal cual (fecha y cantidad):
        -- es un bundle viejo del PWA que todavia lo precarga. No pasa nada.
        CONTINUE WHEN r.solo_traza AND r.cantidad = r.cant_vieja;

        -- 1 y 2: el mismo lote. Lo consumido (cantidad - restante) se conserva.
        -- La fecha nueva de una correccion no choca con el UNIQUE (compra,
        -- producto, fecha): si la tuviera otro lote de la compra, habria
        -- emparejado por fecha exacta. Un lote solo para la traza cuya fecha
        -- vuelve con otra cantidad vuelve a ser un vencimiento de la compra
        -- (su cantidad era lo consumido, y su restante 0).
        UPDATE public.producto_lotes
           SET fecha_vencimiento = r.fecha,
               cantidad          = r.cantidad,
               cantidad_restante = GREATEST(r.cantidad - (cantidad - cantidad_restante), 0),
               solo_traza        = false
         WHERE id = r.id;
        v_crecio := v_crecio || jsonb_build_object(r.id::text, r.cantidad - r.cant_vieja);

      ELSIF r.id IS NULL THEN
        -- 3: un vencimiento nuevo.
        v_grupos := v_grupos + 1;
        INSERT INTO public.producto_lotes (
          producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante,
          compra_id, origen, usuario_id
        ) VALUES (
          v_prod, v_sucursal, r.fecha, r.cantidad, r.cantidad,
          p_compra_id, 'compra', auth.uid()
        ) RETURNING id INTO v_nuevo;
        v_crecio := v_crecio || jsonb_build_object(v_nuevo::text, r.cantidad);

      ELSE
        -- 4: el lote desaparece. Va despues de los otros (ORDER BY 6), asi que
        -- los que quedan ya tienen su fecha, su cantidad y su crecimiento.
        SELECT cantidad, cantidad - cantidad_restante INTO v_cant, v_cons
          FROM public.producto_lotes WHERE id = r.id;

        -- Fusion: el que vence primero de los que crecieron lo suficiente para
        -- absorber lo consumido de este (y al menos una unidad: si no crecio,
        -- las unidades vivas de este se van a la bolsa, no a el, y reapuntarle
        -- la anotacion de una salvedad le haria sacar a anular lo que nunca
        -- recibio).
        v_sobrante := NULL;
        SELECT l.id INTO v_sobrante
          FROM public.producto_lotes l
         WHERE v_crecio ? l.id::text
           AND (v_crecio->>l.id::text)::integer >= GREATEST(v_cons, 1)
         ORDER BY l.fecha_vencimiento, l.id
         LIMIT 1;

        IF v_sobrante IS NOT NULL THEN
          v_crecio := v_crecio || jsonb_build_object(
            v_sobrante::text, (v_crecio->>v_sobrante::text)::integer - v_cant);

          UPDATE public.producto_lotes
             SET cantidad_restante = GREATEST(cantidad_restante - v_cons, 0)
           WHERE id = v_sobrante;

          INSERT INTO public.pedido_item_lotes (pedido_item_id, lote_id, cantidad, sucursal_id)
          SELECT pil.pedido_item_id, v_sobrante, pil.cantidad, pil.sucursal_id
            FROM public.pedido_item_lotes pil
           WHERE pil.lote_id = r.id
          ON CONFLICT (pedido_item_id, lote_id)
            DO UPDATE SET cantidad = pedido_item_lotes.cantidad + EXCLUDED.cantidad;
          DELETE FROM public.pedido_item_lotes WHERE lote_id = r.id;

          UPDATE public.movimiento_sucursal_item_lotes
             SET lote_id = v_sobrante
           WHERE lote_id = r.id;

          DELETE FROM public.producto_lotes WHERE id = r.id;
          v_destino := v_destino || jsonb_build_object(r.id::text, v_sobrante);

        ELSIF EXISTS (SELECT 1 FROM public.pedido_item_lotes WHERE lote_id = r.id)
           OR EXISTS (SELECT 1 FROM public.movimiento_sucursal_item_lotes WHERE lote_id = r.id)
           OR EXISTS (
             SELECT 1
               FROM public.salvedades_items s
               CROSS JOIN LATERAL jsonb_array_elements(
                 CASE WHEN jsonb_typeof(s.lotes_devueltos) = 'array'
                      THEN s.lotes_devueltos ELSE '[]'::jsonb END) e
              WHERE s.sucursal_id = v_sucursal
                AND s.estado_resolucion <> 'anulada'
                AND (e->>'lote_id')::bigint = r.id
                AND COALESCE((e->>'huella')::integer, 0) > 0) THEN
          -- Sin fusion y con traza (o con la huella de una salvedad viva, que
          -- anular le tiene que reponer a algun lote): queda solo para la
          -- traza. Lo que tenia vivo pasa a la bolsa, igual que si se hubiera
          -- borrado; su cantidad pasa a ser lo que ya salio.
          UPDATE public.producto_lotes
             SET cantidad          = GREATEST(v_cons, 1),
                 cantidad_restante = 0,
                 solo_traza        = true
           WHERE id = r.id;

        ELSE
          DELETE FROM public.producto_lotes WHERE id = r.id;
          v_destino := v_destino || jsonb_build_object(r.id::text, NULL);
        END IF;
      END IF;
    END LOOP;
  END LOOP;

  -- Las anotaciones de las salvedades vivas siguen al lote: al que lo absorbio,
  -- con su fecha actual; y si el lote se borro, sin clave de compra/vencimiento
  -- (sus unidades ya son bolsa, y un vencimiento que vuelva a cargarse con esa
  -- fecha es otro lote). Dos entradas que terminan en el mismo lote quedan
  -- separadas: anular_salvedad las suma por lote.
  UPDATE public.salvedades_items s
     SET lotes_devueltos = (
       SELECT jsonb_agg(
                CASE
                  WHEN NOT (v_destino ? (t.e->>'lote_id')) THEN t.e
                  WHEN pl.id IS NULL THEN
                    t.e || jsonb_build_object('compra_id', NULL, 'fecha_vencimiento', NULL)
                  ELSE
                    t.e || jsonb_build_object('lote_id', pl.id, 'compra_id', pl.compra_id,
                                              'fecha_vencimiento', pl.fecha_vencimiento)
                END
                ORDER BY t.ord)
         FROM jsonb_array_elements(s.lotes_devueltos) WITH ORDINALITY AS t(e, ord)
         LEFT JOIN public.producto_lotes pl
           ON pl.id = (v_destino->>(t.e->>'lote_id'))::bigint
     )
   WHERE s.sucursal_id = v_sucursal
     AND s.estado_resolucion <> 'anulada'
     AND jsonb_typeof(s.lotes_devueltos) = 'array'
     AND EXISTS (SELECT 1
                   FROM jsonb_array_elements(CASE WHEN jsonb_typeof(s.lotes_devueltos) = 'array'
                                                  THEN s.lotes_devueltos ELSE '[]'::jsonb END) e
                  WHERE v_destino ? (e->>'lote_id'));

  FOREACH v_prod IN ARRAY v_tocados LOOP
    v_clamp := public._clampear_lotes_a_stock(v_prod, v_sucursal);
    IF v_clamp > 0 THEN
      v_avisos := v_avisos || jsonb_build_array(jsonb_build_object(
        'producto_id', v_prod,
        'unidades',    v_clamp
      ));
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok',            true,
    'lotes',         v_grupos,
    'warning_clamp', v_avisos
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 2 - _restaurar_lotes_fefo: primero al lote de donde salio (#1073-4)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._restaurar_lotes_fefo(p_producto_id bigint, p_sucursal_id bigint, p_cantidad integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_pendiente integer := p_cantidad;
  v_pone      integer;
  r           record;
  -- mig 256: a quien se le descuenta la huella. Ver el encabezado de la
  -- migracion: la linea si el caller la dijo, y si no el pedido.
  v_item_id   bigint := CASE
    WHEN COALESCE(current_setting('app.stock_pedido_item_id', true), '') ~ '^[0-9]+$'
    THEN current_setting('app.stock_pedido_item_id', true)::bigint END;
  v_pedido_id bigint := CASE
    WHEN COALESCE(current_setting('app.stock_ref_tipo', true), '') = 'pedido'
     AND COALESCE(current_setting('app.stock_ref_id', true), '') ~ '^[0-9]+$'
    THEN current_setting('app.stock_ref_id', true)::bigint END;
  v_devolver  integer;
  v_baja      integer;
  h           record;
  -- #1073: dos pasadas (ver abajo). v_por_huella son las unidades devueltas
  -- cuya huella todavia no se descontó: nunca se descuenta mas huella que lo
  -- devuelto.
  v_pasada    integer;
  v_por_huella integer := p_cantidad;
  v_huella    integer;
BEGIN
  IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
    RETURN 0;
  END IF;

  -- #1073: dos pasadas. La primera devuelve a los lotes de donde salio la
  -- linea (o el pedido, si el caller no dijo la linea), hasta lo que cada uno
  -- le dio segun su huella: lo que devuelve el cliente trae la fecha de ESE
  -- lote. Antes iba todo por FEFO, y si otro lote vencia antes y tenia hueco
  -- la devolucion caia ahi: ese lote quedaba con unidades de otra fecha y la
  -- huella del lote de origen no bajaba (en un retiro, el cliente aparecia con
  -- unidades de mas). La segunda pasada lleva lo que sobra -- lo que salio de
  -- la bolsa, o una devolucion sin huella -- por FEFO, como siempre.
  --
  -- #1054: un lote solo para la traza (su vencimiento se saco de la compra) no
  -- recibe nada -- su CHECK no lo deja --, pero en la primera pasada se le
  -- descuenta la huella igual: el cliente ya no tiene esas unidades. Las
  -- unidades siguen de largo a la segunda pasada.
  FOR v_pasada IN 1..2 LOOP
    EXIT WHEN v_pendiente <= 0;

    FOR r IN
      SELECT l.id, l.solo_traza, (l.cantidad - l.cantidad_restante) AS hueco,
             COALESCE(t.huella, 0) AS huella
        FROM public.producto_lotes l
        LEFT JOIN (
          SELECT pil.lote_id, SUM(pil.cantidad)::integer AS huella
            FROM public.pedido_item_lotes pil
            JOIN public.pedido_items pi
              ON pi.id = pil.pedido_item_id AND pi.sucursal_id = pil.sucursal_id
           WHERE pil.sucursal_id = p_sucursal_id
             AND CASE WHEN v_item_id IS NOT NULL
                      THEN pil.pedido_item_id = v_item_id
                      WHEN v_pedido_id IS NOT NULL
                      THEN pi.pedido_id = v_pedido_id AND pi.producto_id = p_producto_id
                      ELSE false
                 END
           GROUP BY pil.lote_id
        ) t ON t.lote_id = l.id
       WHERE l.producto_id = p_producto_id
         AND l.sucursal_id = p_sucursal_id
         AND CASE WHEN v_pasada = 1
                  THEN t.huella > 0 AND (l.solo_traza OR l.cantidad_restante < l.cantidad)
                  ELSE NOT l.solo_traza AND l.cantidad_restante < l.cantidad
             END
       ORDER BY l.fecha_vencimiento ASC, l.id ASC
       FOR UPDATE OF l
    LOOP
      EXIT WHEN v_pendiente <= 0 OR (v_pasada = 1 AND v_por_huella <= 0);

      IF v_pasada = 1 AND r.solo_traza THEN
        v_pone   := 0;
        v_huella := LEAST(v_por_huella, r.huella);
      ELSIF v_pasada = 1 THEN
        v_pone   := LEAST(v_pendiente, r.hueco, r.huella, v_por_huella);
        v_huella := v_pone;
      ELSE
        v_pone   := LEAST(v_pendiente, r.hueco);
        v_huella := LEAST(v_pone, v_por_huella);
      END IF;

      IF v_pone > 0 THEN
        UPDATE public.producto_lotes
           SET cantidad_restante = cantidad_restante + v_pone
         WHERE id = r.id;
      END IF;

      -- mig 256: lo que volvio ya no lo tiene el cliente.
      IF (v_item_id IS NOT NULL OR v_pedido_id IS NOT NULL) AND v_huella > 0 THEN
        v_devolver := v_huella;
        FOR h IN
          SELECT pil.id, pil.cantidad
            FROM public.pedido_item_lotes pil
            JOIN public.pedido_items pi
              ON pi.id = pil.pedido_item_id AND pi.sucursal_id = pil.sucursal_id
           WHERE pil.lote_id = r.id
             AND CASE WHEN v_item_id IS NOT NULL
                      THEN pil.pedido_item_id = v_item_id
                      ELSE pi.pedido_id = v_pedido_id AND pi.producto_id = p_producto_id
                 END
           ORDER BY pil.id
           FOR UPDATE OF pil
        LOOP
          EXIT WHEN v_devolver <= 0;
          v_baja := LEAST(v_devolver, h.cantidad);
          IF v_baja >= h.cantidad THEN
            DELETE FROM public.pedido_item_lotes WHERE id = h.id;
          ELSE
            UPDATE public.pedido_item_lotes SET cantidad = cantidad - v_baja WHERE id = h.id;
          END IF;
          v_devolver := v_devolver - v_baja;
        END LOOP;
      END IF;

      v_pendiente  := v_pendiente - v_pone;
      v_por_huella := v_por_huella - v_huella;
    END LOOP;
  END LOOP;

  RETURN p_cantidad - v_pendiente;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3 - registrar_salvedad (#1073-1, -2, -3, -4)
-- ---------------------------------------------------------------------------

DO $registrar$
DECLARE
  v_def text := pg_get_functiondef(
    'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure);
BEGIN
  -- 3a · variables nuevas.
  v_def := pg_temp.parchar(v_def,
$q$  v_item_guc              TEXT;
BEGIN
$q$,
$q$  v_item_guc              TEXT;
  -- #1073: a que lotes volvio la devolucion, y la anotacion entera.
  v_lotes_diff            JSONB;
  v_anotacion             JSONB;
BEGIN
$q$, 'registrar_salvedad 3a');

  -- 3b · la anotacion: se mide al final y se escribe aunque no haya devolucion
  -- (va primero porque el bloque viejo tambien empieza con IF v_stock_devuelto).
  v_def := pg_temp.parchar_tramo(v_def,
$q$  IF v_stock_devuelto THEN
    -- #1050: la devolucion vuelve a su lote por FEFO$q$,
$q$  /* #847: el faltante parcial tambien.$q$,
$q$  -- #1050 / #1073: lo que anular_salvedad tiene que deshacer. `cantidad`: a
  -- que lotes volvio la devolucion. `huella`: cuanta huella perdio el cliente
  -- en cada lote, medida recien ahora, con la linea ya recortada o borrada:
  -- borrarla se lleva su huella en cascada, y eso tambien hay que reponerlo al
  -- anular, devuelva stock o no (#1073: la merma sobre la linea entera la
  -- perdia para siempre). `compra_id`/`fecha_vencimiento` (mig 331): desde
  -- #1054 editar la compra conserva el id del lote, pero anular lo sigue
  -- buscando tambien por esa clave.
  WITH lotes AS (
    SELECT x.lote_id, x.cantidad
      FROM jsonb_to_recordset(COALESCE(v_lotes_diff, '[]'::jsonb))
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
           'huella',   COALESCE(h.cantidad, 0),
           'compra_id',         pl.compra_id,
           'fecha_vencimiento', pl.fecha_vencimiento)
         ORDER BY COALESCE(l.lote_id, h.lote_id)), '[]'::jsonb)
    INTO v_anotacion
    FROM lotes l
    FULL JOIN huella h ON h.lote_id = l.lote_id
    LEFT JOIN producto_lotes pl ON pl.id = COALESCE(l.lote_id, h.lote_id);

  -- Con devolucion se anota siempre, aunque quede vacia: NULL quiere decir
  -- "anterior a la 328" y anular va por el camino viejo. Sin devolucion, solo
  -- si el cliente perdio huella.
  IF v_stock_devuelto OR jsonb_array_length(v_anotacion) > 0 THEN
    UPDATE salvedades_items
       SET lotes_devueltos = v_anotacion
     WHERE id = v_salvedad_id AND sucursal_id = v_sucursal;
  END IF;

$q$, 'registrar_salvedad 3b');

  -- 3c · el pedido se bloquea antes que la linea (#1073-3).
  v_def := pg_temp.parchar(v_def,
$q$  SELECT pi.id, pi.producto_id, pi.cantidad, pi.precio_unitario, pi.subtotal,
$q$,
$q$  -- #1073: el mismo orden de locks que anular_salvedad y que
  -- cancelar_pedido_con_stock: primero el pedido, despues sus lineas. Con el
  -- orden al reves, registrar y anular a la vez sobre la misma linea se
  -- trababan y Postgres mataba una por deadlock. De paso serializa dos
  -- salvedades simultaneas sobre el mismo pedido: la segunda lee la linea ya
  -- recortada por la primera.
  PERFORM 1 FROM pedidos
   WHERE id = p_pedido_id
     AND sucursal_id = v_sucursal
     FOR UPDATE;

  SELECT pi.id, pi.producto_id, pi.cantidad, pi.precio_unitario, pi.subtotal,
$q$, 'registrar_salvedad 3c');

  -- 3d · la devolucion, antes de recortar o borrar la linea (#1073-4).
  v_def := pg_temp.parchar(v_def,
$q$           GROUP BY pil.lote_id) h;

  IF v_cantidad_entregada > 0 THEN
$q$,
$q$           GROUP BY pil.lote_id) h;

  -- #1073: la devolucion va ANTES de recortar o borrar la linea. Con la linea
  -- todavia viva, _restaurar_lotes_fefo encuentra su huella y devuelve las
  -- unidades al lote del que salieron; con la linea entera ya borrada, su
  -- huella se habia ido en cascada y la devolucion caia por FEFO en cualquier
  -- lote.
  --
  -- #1050: se anota a que lotes volvio (v_lotes_diff), para que
  -- anular_salvedad las saque de ESOS y no de la bolsa: el camino de bajada del
  -- trigger no mira el origen y come primero de la bolsa (lote +N, bolsa -N).
  -- El lock del producto va antes de la foto: todo cambio de stock pasa por esta
  -- fila, asi que la diferencia es solo la de este UPDATE. El orden de los
  -- locks sigue siendo pedido, linea, producto.
  IF v_stock_devuelto THEN
    PERFORM 1 FROM productos
     WHERE id = v_item.producto_id AND sucursal_id = v_sucursal
       FOR UPDATE;
    v_lotes_antes := public._mov_lotes_foto(v_item.producto_id, v_sucursal);

    -- La huella que descuenta la devolucion es la de ESTA linea. Sin el GUC,
    -- _restaurar_lotes_fefo cae al pedido entero y se la puede sacar a otra
    -- linea del mismo producto (un regalo). Por transaccion (229): se guarda y
    -- se restaura.
    v_item_guc := current_setting('app.stock_pedido_item_id', true);
    PERFORM set_config('app.stock_pedido_item_id', p_pedido_item_id::text, true);

    UPDATE productos
       SET stock = stock + p_cantidad_afectada
     WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;

    PERFORM set_config('app.stock_pedido_item_id', COALESCE(v_item_guc, ''), true);
    v_lotes_diff := public._mov_lotes_diff(v_item.producto_id, v_sucursal, v_lotes_antes, 1);
  END IF;

  IF v_cantidad_entregada > 0 THEN
$q$, 'registrar_salvedad 3d');

  -- 3e · la devolucion del regalo lleva la linea del regalo (#1073-2).
  v_def := pg_temp.parchar(v_def,
$q$        IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
          UPDATE productos
             SET stock = stock + v_diff
           WHERE id = v_bonif.producto_id
             AND sucursal_id = v_sucursal;
        END IF;
$q$,
$q$        IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
          -- #1073: la devolucion del regalo descuenta la huella del REGALO. Sin
          -- el GUC, _restaurar_lotes_fefo caia al pedido entero y, con el
          -- mismo producto, se la sacaba a la linea principal (que encima la
          -- anotaba como perdida suya y anular se la reponia). Por transaccion
          -- (229): se guarda y se restaura.
          v_item_guc := current_setting('app.stock_pedido_item_id', true);
          PERFORM set_config('app.stock_pedido_item_id', v_bonif.id::text, true);

          UPDATE productos
             SET stock = stock + v_diff
           WHERE id = v_bonif.producto_id
             AND sucursal_id = v_sucursal;

          PERFORM set_config('app.stock_pedido_item_id', COALESCE(v_item_guc, ''), true);
        END IF;
$q$, 'registrar_salvedad 3e');

  EXECUTE v_def;
END
$registrar$;

-- ---------------------------------------------------------------------------
-- 4 - anular_salvedad: la huella se repone aunque no haya devolucion (#1073-1)
-- ---------------------------------------------------------------------------

DO $anular$
DECLARE
  v_def text := pg_get_functiondef('public.anular_salvedad(bigint,text)'::regprocedure);
BEGIN
  v_def := pg_temp.parchar(v_def,
$q$  IF v_salvedad.stock_devuelto THEN
    /* #1050: las unidades salen por el mismo camino por el que entraron.
$q$,
$q$  -- #1073: tambien sin devolucion. Una merma sobre la linea entera borro la
  -- linea y su huella se fue en cascada; registrar_salvedad la anoto
  -- (lotes_devueltos con cantidad 0) y aca se le repone a la linea restituida.
  IF v_salvedad.stock_devuelto OR v_salvedad.lotes_devueltos IS NOT NULL THEN
    /* #1050: las unidades salen por el mismo camino por el que entraron.
$q$, 'anular_salvedad 4a');

  -- 4b · una fila por lote. Dos entradas de la anotacion pueden caer en el
  -- mismo lote (una fusion de la compra reapunta una sobre la otra, o el id de
  -- una y la clave de otra). Con una fila por entrada, el FOR trae las dos con
  -- el cantidad_restante de ANTES del primer UPDATE: la segunda sacaba de
  -- unidades que ya no estaban (o rompia el CHECK) y topaba la huella contra
  -- un consumo viejo.
  v_def := pg_temp.parchar_tramo(v_def,
$q$    FOR r_lote IN
$q$,
$q$    LOOP
      v_saca := GREATEST($q$,
$q$    FOR r_lote IN
      SELECT l.id, l.cantidad, l.cantidad_restante, a.devuelto, a.huella
        FROM (
          SELECT l2.id,
                 SUM(COALESCE(x.cantidad, 0))::integer AS devuelto,
                 SUM(COALESCE(x.huella, 0))::integer   AS huella
            FROM jsonb_to_recordset(COALESCE(v_salvedad.lotes_devueltos, '[]'::jsonb))
                 AS x(lote_id bigint, cantidad integer, huella integer,
                      compra_id bigint, fecha_vencimiento date)
            -- mig 331: por id, o por (compra, producto, vencimiento). Desde
            -- #1054 editar la compra conserva el id del lote (y reapunta la
            -- anotacion si lo fusiona); la clave queda para las anotaciones
            -- hechas antes, cuando la edicion recreaba el lote con otro id.
            JOIN producto_lotes l2
              ON (l2.id = x.lote_id
                  OR (x.compra_id IS NOT NULL
                      AND l2.compra_id = x.compra_id
                      AND l2.fecha_vencimiento = x.fecha_vencimiento))
             AND l2.producto_id = v_salvedad.producto_id
             AND l2.sucursal_id = v_sucursal
           GROUP BY l2.id
        ) a
        JOIN producto_lotes l ON l.id = a.id
       ORDER BY l.fecha_vencimiento, l.id
         FOR UPDATE OF l
$q$, 'anular_salvedad 4b');

  v_def := pg_temp.parchar_tramo(v_def,
$q$    -- mig 244: la bajada sale etiquetada para el ledger.
$q$,
$q$    PERFORM set_config('app.stock_origen',         COALESCE(v_g_origen, ''),   true);
$q$,
$q$    -- #1073: sin devolucion (la merma) no hay bajada: solo se repuso la huella.
    IF v_salvedad.stock_devuelto THEN
      -- mig 244: la bajada sale etiquetada para el ledger.
      PERFORM set_config('app.stock_origen',   'salvedad_anulada',  true);
      PERFORM set_config('app.stock_ref_tipo', 'salvedad',          true);
      PERFORM set_config('app.stock_ref_id',   p_salvedad_id::TEXT, true);
      PERFORM set_config('app.stock_user_id',  COALESCE(v_usuario_id::TEXT, ''), true);
      PERFORM set_config('app.stock_pedido_item_id', COALESCE(v_item_id::TEXT, ''), true);

      UPDATE productos SET stock = stock - v_salvedad.cantidad_afectada
       WHERE id = v_salvedad.producto_id AND sucursal_id = v_sucursal;
    END IF;

$q$, 'anular_salvedad 4c');

  EXECUTE v_def;
END
$anular$;

-- ---------------------------------------------------------------------------
-- 5 - Verificacion estructural
-- ---------------------------------------------------------------------------

DO $verif$
DECLARE
  v_reg text := pg_get_functiondef('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure);
  v_anu text := pg_get_functiondef('public.anular_salvedad(bigint,text)'::regprocedure);
  v_sin text := pg_get_functiondef('public.sincronizar_lotes_compra(bigint,jsonb)'::regprocedure);
  v_res text := pg_get_functiondef('public._restaurar_lotes_fefo(bigint,bigint,integer)'::regprocedure);
BEGIN
  IF v_reg NOT LIKE '%SECURITY DEFINER%'
     OR strpos(v_reg, 'PERFORM 1 FROM pedidos') = 0
     OR strpos(v_reg, 'PERFORM 1 FROM pedidos') > strpos(v_reg, 'PERFORM 1 FROM pedido_items')
     OR strpos(v_reg, 'v_lotes_diff := public._mov_lotes_diff') > strpos(v_reg, 'IF v_cantidad_entregada > 0 THEN')
     OR v_reg NOT LIKE '%set_config(''app.stock_pedido_item_id'', v_bonif.id::text, true)%' THEN
    RAISE EXCEPTION 'registrar_salvedad no quedo como se esperaba';
  END IF;
  IF v_anu NOT LIKE '%SECURITY DEFINER%'
     OR v_anu NOT LIKE '%IF v_salvedad.stock_devuelto OR v_salvedad.lotes_devueltos IS NOT NULL THEN%'
     OR v_anu NOT LIKE '%GROUP BY l2.id%' THEN
    RAISE EXCEPTION 'anular_salvedad no quedo como se esperaba';
  END IF;
  IF v_sin NOT LIKE '%SECURITY DEFINER%' OR v_sin LIKE '%DELETE FROM public.producto_lotes WHERE compra_id%'
     OR v_sin NOT LIKE '%solo_traza        = true%' THEN
    RAISE EXCEPTION 'sincronizar_lotes_compra no quedo como se esperaba';
  END IF;
  IF v_res NOT LIKE '%SECURITY DEFINER%' OR v_res NOT LIKE '%v_pasada%'
     OR v_res NOT LIKE '%NOT l.solo_traza%' THEN
    RAISE EXCEPTION '_restaurar_lotes_fefo no quedo como se esperaba';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.producto_lotes'::regclass
                    AND conname = 'producto_lotes_solo_traza_vacio') THEN
    RAISE EXCEPTION 'falta el CHECK de producto_lotes.solo_traza';
  END IF;
  -- La columna nueva se lee por REST (el modal de la compra filtra por ella):
  -- tiene que verla authenticated.
  IF NOT has_column_privilege('authenticated', 'public.producto_lotes', 'solo_traza', 'SELECT') THEN
    RAISE EXCEPTION 'authenticated no puede leer producto_lotes.solo_traza';
  END IF;
  -- Los GRANTs no cambian con CREATE OR REPLACE, pero se verifica lo que HACEN:
  -- ni anon ni PUBLIC ejecutan ninguna de las cuatro; los helpers de lotes,
  -- tampoco authenticated.
  IF has_function_privilege('anon', 'public.sincronizar_lotes_compra(bigint,jsonb)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.anular_salvedad(bigint,text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public._restaurar_lotes_fefo(bigint,bigint,integer)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._restaurar_lotes_fefo(bigint,bigint,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'los permisos de las funciones cambiaron';
  END IF;
END
$verif$;

DROP FUNCTION pg_temp.parchar(text, text, text, text);
DROP FUNCTION pg_temp.parchar_tramo(text, text, text, text, text);

-- ---------------------------------------------------------------------------
-- 6 - Ensayo con datos reales: los casos de
--     scripts/test-lotes-trazabilidad-1054-1073.sql (ver ahi cada uno).
--     Copia de los casos del script; la corrida de aca solo aborta si algo
--     falla (el script siempre termina en un RAISE).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pg_temp.t_hoy()
RETURNS date LANGUAGE sql AS $fn$
  SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

-- Un lote como {dias, cant, rest}; NULL si ya no existe.
CREATE OR REPLACE FUNCTION pg_temp.t_lote(p_id bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('dias', l.fecha_vencimiento - pg_temp.t_hoy(),
                            'cant', l.cantidad, 'rest', l.cantidad_restante)
    FROM public.producto_lotes l WHERE l.id = p_id;
$fn$;

-- El lote quedo solo para la traza (mig 337). Sin la columna, false.
CREATE OR REPLACE FUNCTION pg_temp.t_solo(p_id bigint)
RETURNS boolean LANGUAGE plpgsql AS $fn$
DECLARE
  v boolean;
BEGIN
  EXECUTE 'SELECT solo_traza FROM public.producto_lotes WHERE id = $1' INTO v USING p_id;
  RETURN COALESCE(v, false);
EXCEPTION WHEN undefined_column THEN
  RETURN false;
END
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

-- pedido_item_lotes de las lineas de un producto: [{item, lote, cant}].
CREATE OR REPLACE FUNCTION pg_temp.t_huella_tabla(p_prod bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('item', pil.pedido_item_id, 'lote', pil.lote_id,
                                               'cant', pil.cantidad)
                            ORDER BY pil.pedido_item_id, pil.lote_id), '[]'::jsonb)
    FROM public.pedido_item_lotes pil
    JOIN public.pedido_items pi ON pi.id = pil.pedido_item_id
   WHERE pi.producto_id = p_prod;
$fn$;

-- Producto con lotes de una compra ([{dias, cantidad, restante}]) y `p_bolsa`
-- unidades sin lote. Devuelve {prod, compra, lotes: [ids en el orden dado]}.
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
  VALUES ('ZZ ensayo 1054', 100,
          p_bolsa + (SELECT COALESCE(SUM((x->>'restante')::int), 0) FROM jsonb_array_elements(p_lotes) x),
          60, p_suc)
  RETURNING id INTO v_prod;

  INSERT INTO public.compras (sucursal_id, estado, usuario_id)
  VALUES (p_suc, 'recibida', p_admin) RETURNING id INTO v_compra;

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
    'ensayo 1054');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  v_ped := (v_res->>'pedido_id')::bigint;
  RETURN jsonb_build_object('pedido', v_ped,
    'item', (SELECT id FROM public.pedido_items WHERE pedido_id = v_ped AND producto_id = p_prod));
END
$fn$;

-- La edicion de la compra, como la manda la app: la foto completa de los
-- vencimientos de la factura ([{dias, cantidad}] de un solo producto).
CREATE OR REPLACE FUNCTION pg_temp.t_editar(p_compra bigint, p_prod bigint, p_lotes jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.sincronizar_lotes_compra(p_compra, COALESCE((
    SELECT jsonb_agg(jsonb_build_object('producto_id', p_prod,
                                        'fecha_vencimiento', pg_temp.t_hoy() + (x->>'dias')::int,
                                        'cantidad', (x->>'cantidad')::int))
      FROM jsonb_array_elements(p_lotes) x), '[]'::jsonb));
  IF NOT COALESCE((v_res->>'ok')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo editar la compra: %', v_res;
  END IF;
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_salvedad(p_ped bigint, p_item bigint, p_cant int, p_motivo text)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.registrar_salvedad(p_ped, p_item, p_cant, p_motivo,
                                     'ensayo 1054: descripcion del caso', NULL, true, NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'registrar %: %', p_motivo, v_res;
  END IF;
  RETURN (v_res->>'salvedad_id')::bigint;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_anular(p_salv bigint)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.anular_salvedad(p_salv, 'ensayo 1054');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'anular: %', v_res;
  END IF;
END
$fn$;

-- Suma unidades a la bolsa con un origen fuera de la lista blanca (no van a
-- ningun lote). Sirve para que la bolsa no quede en 0 despues de un pedido que
-- llego a los lotes: con bolsa 0 la bajada cae en el lote por FEFO y da bien
-- por casualidad.
CREATE OR REPLACE FUNCTION pg_temp.t_a_la_bolsa(p_prod bigint, p_n int)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', 'ensayo_1054', true);
  UPDATE public.productos SET stock = stock + p_n WHERE id = p_prod;
  PERFORM set_config('app.stock_origen', '', true);
END
$fn$;

-- ---------------------------------------------------------------------------
-- #1054
-- ---------------------------------------------------------------------------

-- A · lote 100 con 50 vivas, bolsa 5. Pedido 20: 5 de la bolsa y 15 del lote
--     (huella 15). Editar la compra sin cambios.
CREATE OR REPLACE FUNCTION pg_temp.caso_a(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l bigint; p jsonb; v_item bigint;
  f text[] := '{}'; h0 jsonb; h1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 5);
  v_prod := v->>'prod'; v_l := v->'lotes'->>0;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_item := p->>'item';
  h0 := pg_temp.t_huella_tabla(v_prod);
  IF pg_temp.t_huella(v_item, v_l) <> 15 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: huella %s', h0)));
  END IF;

  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[{"dias":90,"cantidad":100}]');
  h1 := pg_temp.t_huella_tabla(v_prod);

  f := pg_temp.t_si(f, pg_temp.t_lote(v_l) IS NOT NULL,
                    'editar la compra sin cambios borro el lote y lo recreo con otro id');
  f := pg_temp.t_si(f, pg_temp.t_lote(v_l) = '{"dias":90,"cant":100,"rest":35}',
                    format('el lote quedo %s, esperado {dias 90, cant 100, rest 35}', pg_temp.t_lote(v_l)));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l) = 15,
                    format('la huella del cliente en el lote era 15 y quedo %s', pg_temp.t_huella(v_item, v_l)));
  RETURN jsonb_build_object('fallas', to_jsonb(f),
    'reporte', format('lote %s · pedido_item_lotes antes %s / despues %s', v_l, h0, h1));
END
$fn$;

-- B · una transferencia salio del lote (movimiento_sucursal_item_lotes).
--     Editar la compra sin cambios.
CREATE OR REPLACE FUNCTION pg_temp.caso_b(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l bigint; v_mov bigint; v_mitem bigint; v_trl bigint;
  f text[] := '{}'; v_lote_traza bigint;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod'; v_l := v->'lotes'->>0;

  INSERT INTO public.movimientos_sucursal (sucursal_origen_id, sucursal_destino_id, creado_por)
  VALUES (p_suc, p_otra, p_adm) RETURNING id INTO v_mov;
  INSERT INTO public.movimiento_sucursal_items (movimiento_id, producto_origen_id, cantidad, origen_nombre)
  VALUES (v_mov, v_prod, 5, 'ZZ ensayo 1054') RETURNING id INTO v_mitem;
  INSERT INTO public.movimiento_sucursal_item_lotes (item_id, sucursal_id, lote_id, fecha_vencimiento, cantidad)
  VALUES (v_mitem, p_suc, v_l, pg_temp.t_hoy() + 90, 5) RETURNING id INTO v_trl;

  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[{"dias":90,"cantidad":100}]');

  SELECT lote_id INTO v_lote_traza FROM public.movimiento_sucursal_item_lotes WHERE id = v_trl;
  f := pg_temp.t_si(f, v_lote_traza = v_l,
                    format('la traza de la transferencia apuntaba al lote %s y quedo en %s', v_l,
                           COALESCE(v_lote_traza::text, 'NULL')));
  RETURN jsonb_build_object('fallas', to_jsonb(f),
    'reporte', format('movimiento_sucursal_item_lotes.lote_id antes %s / despues %s', v_l,
                      COALESCE(v_lote_traza::text, 'NULL')));
END
$fn$;

-- C · lote 100 con 50 vivas, bolsa 40 (stock 90). Se corrige el vencimiento
--     de 90 a 120 dias.
CREATE OR REPLACE FUNCTION pg_temp.caso_c(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l bigint; f text[] := '{}'; v_foto jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod'; v_l := v->'lotes'->>0;

  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[{"dias":120,"cantidad":100}]');
  v_foto := pg_temp.t_foto(v_prod);

  f := pg_temp.t_si(f, pg_temp.t_lote(v_l) = '{"dias":120,"cant":100,"rest":50}',
                    format('el lote %s quedo %s, esperado el mismo lote con {dias 120, cant 100, rest 50}',
                           v_l, COALESCE(pg_temp.t_lote(v_l)::text, 'borrado')));
  f := pg_temp.t_si(f, v_foto = '{"stock":90,"lotes":[50],"bolsa":40}',
                    format('corregir el vencimiento dejo %s, antes era {stock 90, lotes [50], bolsa 40}', v_foto));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('foto despues %s', v_foto));
END
$fn$;

-- C2 · bolsa 40, pedido 20 de la bolsa {70,[50],20}, salvedad 10 al lote
--      {80,[60],20}, se corrige el vencimiento, se anula: {70,[50],20}.
CREATE OR REPLACE FUNCTION pg_temp.caso_c2(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; p jsonb; v_salv bigint; f text[] := '{}';
  v_f1 jsonb; v_f2 jsonb; v_f3 jsonb; v_f4 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  v_f1 := pg_temp.t_foto(v_prod);
  v_salv := pg_temp.t_salvedad((p->>'pedido')::bigint, (p->>'item')::bigint, 10, 'cliente_rechaza');
  v_f2 := pg_temp.t_foto(v_prod);
  IF v_f1 <> '{"stock":70,"lotes":[50],"bolsa":20}' OR v_f2 <> '{"stock":80,"lotes":[60],"bolsa":20}' THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s, %s', v_f1, v_f2)));
  END IF;

  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[{"dias":120,"cantidad":100}]');
  v_f3 := pg_temp.t_foto(v_prod);
  PERFORM pg_temp.t_anular(v_salv);
  v_f4 := pg_temp.t_foto(v_prod);

  f := pg_temp.t_si(f, v_f3 = v_f2, format('corregir el vencimiento movio lote y bolsa: %s -> %s', v_f2, v_f3));
  f := pg_temp.t_si(f, v_f4 = v_f1, format('anular dejo %s; despues del pedido era %s', v_f4, v_f1));
  RETURN jsonb_build_object('fallas', to_jsonb(f),
    'reporte', format('pedido %s · salvedad %s · edicion %s · anulada %s', v_f1, v_f2, v_f3, v_f4));
END
$fn$;

-- D · huella 15 en el lote (como A) y se corrige el vencimiento.
CREATE OR REPLACE FUNCTION pg_temp.caso_d(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l bigint; p jsonb; v_item bigint;
  f text[] := '{}'; h0 jsonb; h1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 5);
  v_prod := v->>'prod'; v_l := v->'lotes'->>0;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_item := p->>'item';
  h0 := pg_temp.t_huella_tabla(v_prod);

  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[{"dias":120,"cantidad":100}]');
  h1 := pg_temp.t_huella_tabla(v_prod);

  f := pg_temp.t_si(f, pg_temp.t_lote(v_l) = '{"dias":120,"cant":100,"rest":35}',
                    format('el lote %s quedo %s, esperado {dias 120, cant 100, rest 35}',
                           v_l, COALESCE(pg_temp.t_lote(v_l)::text, 'borrado')));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l) = 15,
                    format('la huella del cliente era 15 y quedo %s', pg_temp.t_huella(v_item, v_l)));
  RETURN jsonb_build_object('fallas', to_jsonb(f),
    'reporte', format('lote %s · pedido_item_lotes antes %s / despues %s', v_l, h0, h1));
END
$fn$;

-- F · L1 (30 dias, 10/10) y L2 (90 dias, 10/10), bolsa 5. Pedido 20: 5 de la
--     bolsa, 10 de L1, 5 de L2. La edicion los fusiona en un vencimiento de
--     60 dias por 20: L1 cambia de fecha y absorbe lo consumido y la traza de L2.
CREATE OR REPLACE FUNCTION pg_temp.caso_f(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l1 bigint; v_l2 bigint; p jsonb; v_item bigint;
  f text[] := '{}'; h0 jsonb; h1 jsonb; v_foto jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":10,"restante":10},{"dias":90,"cantidad":10,"restante":10}]', 5);
  v_prod := v->>'prod'; v_l1 := v->'lotes'->>0; v_l2 := v->'lotes'->>1;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_item := p->>'item';
  h0 := pg_temp.t_huella_tabla(v_prod);
  IF pg_temp.t_huella(v_item, v_l1) <> 10 OR pg_temp.t_huella(v_item, v_l2) <> 5 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: huella %s', h0)));
  END IF;

  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[{"dias":60,"cantidad":20}]');
  h1 := pg_temp.t_huella_tabla(v_prod);
  v_foto := pg_temp.t_foto(v_prod);

  f := pg_temp.t_si(f, pg_temp.t_lote(v_l1) = '{"dias":60,"cant":20,"rest":5}',
                    format('L1 quedo %s, esperado {dias 60, cant 20, rest 5}',
                           COALESCE(pg_temp.t_lote(v_l1)::text, 'borrado')));
  f := pg_temp.t_si(f, pg_temp.t_lote(v_l2) IS NULL, 'L2 (el que se fusiono) sigue existiendo');
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 15,
                    format('la huella del cliente era 10 en L1 + 5 en L2 y quedo %s en L1',
                           pg_temp.t_huella(v_item, v_l1)));
  f := pg_temp.t_si(f, v_foto = '{"stock":5,"lotes":[5],"bolsa":0}',
                    format('la fusion dejo %s, esperado {stock 5, lotes [5], bolsa 0}', v_foto));
  RETURN jsonb_build_object('fallas', to_jsonb(f),
    'reporte', format('L1 %s, L2 %s · pedido_item_lotes antes %s / despues %s', v_l1, v_l2, h0, h1));
END
$fn$;

-- F2 · L1 (30 dias, 50/50) y L2 (90 dias, 50 con 40 vivas), bolsa 30.
--      Pedido 20 de la bolsa {100,[50,40],10}; salvedad 10 entra a L2
--      {110,[50,50],10}; la edicion fusiona todo en el vencimiento de L1 por
--      100 {110,[100],10}; anular saca las 10 del lote que quedo {100,[90],10}.
CREATE OR REPLACE FUNCTION pg_temp.caso_f2(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; p jsonb; v_salv bigint; f text[] := '{}';
  v_f1 jsonb; v_f2 jsonb; v_f3 jsonb; v_f4 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":50},{"dias":90,"cantidad":50,"restante":40}]', 30);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  v_f1 := pg_temp.t_foto(v_prod);
  v_salv := pg_temp.t_salvedad((p->>'pedido')::bigint, (p->>'item')::bigint, 10, 'cliente_rechaza');
  v_f2 := pg_temp.t_foto(v_prod);
  IF v_f1 <> '{"stock":100,"lotes":[50,40],"bolsa":10}' OR v_f2 <> '{"stock":110,"lotes":[50,50],"bolsa":10}' THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s, %s', v_f1, v_f2)));
  END IF;

  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[{"dias":30,"cantidad":100}]');
  v_f3 := pg_temp.t_foto(v_prod);
  PERFORM pg_temp.t_anular(v_salv);
  v_f4 := pg_temp.t_foto(v_prod);

  f := pg_temp.t_si(f, v_f3 = '{"stock":110,"lotes":[100],"bolsa":10}',
                    format('la fusion dejo %s, esperado {stock 110, lotes [100], bolsa 10}', v_f3));
  f := pg_temp.t_si(f, v_f4 = '{"stock":100,"lotes":[90],"bolsa":10}',
                    format('anular despues de la fusion dejo %s, esperado {stock 100, lotes [90], bolsa 10}', v_f4));
  RETURN jsonb_build_object('fallas', to_jsonb(f),
    'reporte', format('pedido %s · salvedad %s · fusion %s · anulada %s', v_f1, v_f2, v_f3, v_f4));
END
$fn$;

-- X · huella 15 en el lote (como A) y la edicion saca todos los vencimientos
--     del producto. El lote queda agotado: cantidad = lo que ya salio (65),
--     restante 0. La bolsa se queda con lo que el lote tenia vivo.
CREATE OR REPLACE FUNCTION pg_temp.caso_x(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l bigint; p jsonb; v_item bigint;
  f text[] := '{}'; h0 jsonb; h1 jsonb; v_foto jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 5);
  v_prod := v->>'prod'; v_l := v->'lotes'->>0;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_item := p->>'item';
  h0 := pg_temp.t_huella_tabla(v_prod);

  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[]');
  h1 := pg_temp.t_huella_tabla(v_prod);
  v_foto := pg_temp.t_foto(v_prod);

  f := pg_temp.t_si(f, pg_temp.t_lote(v_l) = '{"dias":90,"cant":65,"rest":0}' AND pg_temp.t_solo(v_l),
                    format('el lote quedo %s (solo_traza %s), esperado agotado {dias 90, cant 65, rest 0}',
                           COALESCE(pg_temp.t_lote(v_l)::text, 'borrado'), pg_temp.t_solo(v_l)));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l) = 15,
                    format('la huella del cliente era 15 y quedo %s', pg_temp.t_huella(v_item, v_l)));
  f := pg_temp.t_si(f, v_foto = '{"stock":35,"lotes":[0],"bolsa":35}',
                    format('sacar el vencimiento dejo %s, esperado {stock 35, lotes [0], bolsa 35}', v_foto));
  RETURN jsonb_build_object('fallas', to_jsonb(f),
    'reporte', format('lote %s · pedido_item_lotes antes %s / despues %s', v_l, h0, h1));
END
$fn$;

-- X2 · sin traza: sacar el vencimiento borra el lote, como siempre.
CREATE OR REPLACE FUNCTION pg_temp.caso_x2(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l bigint; f text[] := '{}'; v_foto jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod'; v_l := v->'lotes'->>0;
  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[]');
  v_foto := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, pg_temp.t_lote(v_l) IS NULL, 'el lote sin traza no se borro');
  f := pg_temp.t_si(f, v_foto = '{"stock":90,"lotes":[],"bolsa":90}',
                    format('sacar el vencimiento dejo %s, esperado {stock 90, lotes [], bolsa 90}', v_foto));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('foto despues %s', v_foto));
END
$fn$;

-- X3 · dos vencimientos con traza y la edicion saca los dos: ninguno absorbe
--      al otro (los dos se van), quedan los dos agotados con su traza.
--      L1 (30 dias, 10/10), L2 (90 dias, 10/10), bolsa 5. Pedido 20: 5 de la
--      bolsa, 10 de L1, 5 de L2.
CREATE OR REPLACE FUNCTION pg_temp.caso_x3(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l1 bigint; v_l2 bigint; p jsonb; v_item bigint;
  f text[] := '{}'; h0 jsonb; h1 jsonb; v_foto jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":10,"restante":10},{"dias":90,"cantidad":10,"restante":10}]', 5);
  v_prod := v->>'prod'; v_l1 := v->'lotes'->>0; v_l2 := v->'lotes'->>1;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_item := p->>'item';
  h0 := pg_temp.t_huella_tabla(v_prod);

  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[]');
  h1 := pg_temp.t_huella_tabla(v_prod);
  v_foto := pg_temp.t_foto(v_prod);

  f := pg_temp.t_si(f, pg_temp.t_lote(v_l1) = '{"dias":30,"cant":10,"rest":0}'
                       AND pg_temp.t_lote(v_l2) = '{"dias":90,"cant":5,"rest":0}'
                       AND pg_temp.t_solo(v_l1) AND pg_temp.t_solo(v_l2),
                    format('L1 quedo %s y L2 %s, esperado agotados {30, 10, 0} y {90, 5, 0}',
                           COALESCE(pg_temp.t_lote(v_l1)::text, 'borrado'),
                           COALESCE(pg_temp.t_lote(v_l2)::text, 'borrado')));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 10 AND pg_temp.t_huella(v_item, v_l2) = 5,
                    format('la traza era 10 en L1 y 5 en L2, quedo %s', h1));
  f := pg_temp.t_si(f, v_foto = '{"stock":5,"lotes":[0,0],"bolsa":5}',
                    format('sacar los vencimientos dejo %s, esperado {stock 5, lotes [0,0], bolsa 5}', v_foto));
  RETURN jsonb_build_object('fallas', to_jsonb(f),
    'reporte', format('L1 %s, L2 %s · pedido_item_lotes antes %s / despues %s', v_l1, v_l2, h0, h1));
END
$fn$;

-- F3 · como F, pero la edicion solo SACA el vencimiento de 30 dias y deja el
--      de 90 como estaba (10). No es una fusion: el de 90 no crecio, asi que
--      no absorbe lo consumido del otro (si lo absorbiera, sus 5 vivas pasarian
--      a la bolsa). El de 30 tiene traza: queda solo para la traza.
CREATE OR REPLACE FUNCTION pg_temp.caso_f3(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l1 bigint; v_l2 bigint; p jsonb; v_item bigint;
  f text[] := '{}'; h0 jsonb; h1 jsonb; v_foto jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":10,"restante":10},{"dias":90,"cantidad":10,"restante":10}]', 5);
  v_prod := v->>'prod'; v_l1 := v->'lotes'->>0; v_l2 := v->'lotes'->>1;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_item := p->>'item';
  h0 := pg_temp.t_huella_tabla(v_prod);

  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[{"dias":90,"cantidad":10}]');
  h1 := pg_temp.t_huella_tabla(v_prod);
  v_foto := pg_temp.t_foto(v_prod);

  f := pg_temp.t_si(f, pg_temp.t_lote(v_l2) = '{"dias":90,"cant":10,"rest":5}',
                    format('L2 quedo %s, esperado sin tocar {90, 10, 5}', COALESCE(pg_temp.t_lote(v_l2)::text, 'borrado')));
  f := pg_temp.t_si(f, pg_temp.t_lote(v_l1) = '{"dias":30,"cant":10,"rest":0}' AND pg_temp.t_solo(v_l1),
                    format('L1 quedo %s (solo_traza %s), esperado solo para la traza {30, 10, 0}',
                           COALESCE(pg_temp.t_lote(v_l1)::text, 'borrado'), pg_temp.t_solo(v_l1)));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 10 AND pg_temp.t_huella(v_item, v_l2) = 5,
                    format('la traza era 10 en L1 y 5 en L2, quedo %s', h1));
  f := pg_temp.t_si(f, v_foto = '{"stock":5,"lotes":[0,5],"bolsa":0}',
                    format('sacar el vencimiento dejo %s, esperado {stock 5, lotes [0,5], bolsa 0}', v_foto));
  RETURN jsonb_build_object('fallas', to_jsonb(f),
    'reporte', format('L1 %s, L2 %s · pedido_item_lotes antes %s / despues %s', v_l1, v_l2, h0, h1));
END
$fn$;

-- X4 · el lote que quedo solo para la traza no revive. Como X (huella 15,
--      lote agotado con 65), y despues: un pedido de 10 que sale de la bolsa
--      y se cancela (devolucion sin huella: no va al lote), y se cancela el
--      pedido original (su huella baja, las unidades van a la bolsa).
CREATE OR REPLACE FUNCTION pg_temp.caso_x4(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l bigint; p jsonb; p2 jsonb; v_item bigint; v_res jsonb;
  f text[] := '{}'; v_f1 jsonb; v_f2 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 5);
  v_prod := v->>'prod'; v_l := v->'lotes'->>0;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_item := p->>'item';
  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[]');

  p2 := pg_temp.t_pedido(p_cli, p_adm, v_prod, 10);
  v_res := public.cancelar_pedido_con_stock((p2->>'pedido')::bigint, 'ensayo 1054', p_adm, NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'cancelar el segundo: %', v_res;
  END IF;
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = '{"stock":35,"lotes":[0],"bolsa":35}',
                    format('cancelar un pedido sin huella dejo %s, esperado {stock 35, lotes [0], bolsa 35}', v_f1));

  v_res := public.cancelar_pedido_con_stock((p->>'pedido')::bigint, 'ensayo 1054', p_adm, NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'cancelar el original: %', v_res;
  END IF;
  v_f2 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f2 = '{"stock":55,"lotes":[0],"bolsa":55}',
                    format('cancelar el pedido con huella dejo %s, esperado {stock 55, lotes [0], bolsa 55}', v_f2));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l) = 0,
                    format('el pedido cancelado sigue con huella %s', pg_temp.t_huella(v_item, v_l)));
  f := pg_temp.t_si(f, pg_temp.t_solo(v_l), 'el lote dejo de ser solo para la traza');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s', v_f1, v_f2));
END
$fn$;

-- X5 · el lote al que solo apunta la anotacion de una salvedad viva no se
--      borra. Pedido 10 (5 de la bolsa, 5 del lote: huella 5), salvedad
--      cliente_rechaza por la linea entera (la linea se borra con su huella; la
--      anotacion la guarda), se sacan los vencimientos, se anula: la linea
--      repuesta vuelve a tener su huella 5 en el lote.
CREATE OR REPLACE FUNCTION pg_temp.caso_x5(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l bigint; p jsonb; v_ped bigint; v_salv bigint; v_item2 bigint;
  f text[] := '{}'; h2 jsonb; v_f2 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 5);
  v_prod := v->>'prod'; v_l := v->'lotes'->>0;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 10); v_ped := p->>'pedido';
  v_salv := pg_temp.t_salvedad(v_ped, (p->>'item')::bigint, 10, 'cliente_rechaza');
  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[]');

  f := pg_temp.t_si(f, pg_temp.t_lote(v_l) IS NOT NULL,
                    'el lote con huella anotada en una salvedad viva se borro');
  PERFORM pg_temp.t_anular(v_salv);
  h2 := pg_temp.t_huella_tabla(v_prod); v_f2 := pg_temp.t_foto(v_prod);
  SELECT id INTO v_item2 FROM public.pedido_items WHERE pedido_id = v_ped AND producto_id = v_prod;
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item2, v_l) = 5,
                    format('anular repuso la linea con huella %s en el lote, esperado 5', pg_temp.t_huella(v_item2, v_l)));
  f := pg_temp.t_si(f, v_f2 = '{"stock":45,"lotes":[0],"bolsa":45}',
                    format('anular dejo %s, esperado {stock 45, lotes [0], bolsa 45}', v_f2));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('pedido_item_lotes anulada %s · foto %s', h2, v_f2));
END
$fn$;

-- X6 · como X (lote solo para la traza, cantidad 65). Un bundle viejo del PWA
--      que todavia lo precarga lo reenvia tal cual (90 dias, 65): no pasa nada.
--      Si el usuario vuelve a cargar esa fecha con otra cantidad (100), el lote
--      vuelve a ser un vencimiento de la compra, con lo consumido (65).
CREATE OR REPLACE FUNCTION pg_temp.caso_x6(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l bigint; p jsonb; f text[] := '{}'; v_f1 jsonb; v_f2 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 5);
  v_prod := v->>'prod'; v_l := v->'lotes'->>0;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[]');

  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[{"dias":90,"cantidad":65}]');
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, pg_temp.t_solo(v_l) AND v_f1 = '{"stock":35,"lotes":[0],"bolsa":35}',
                    format('el reenvio de un bundle viejo cambio algo: %s (solo_traza %s)', v_f1, pg_temp.t_solo(v_l)));

  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[{"dias":90,"cantidad":100}]');
  v_f2 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, NOT pg_temp.t_solo(v_l) AND pg_temp.t_lote(v_l) = '{"dias":90,"cant":100,"rest":35}',
                    format('volver a cargar la fecha dejo el lote en %s (solo_traza %s), esperado {90, 100, 35}',
                           pg_temp.t_lote(v_l), pg_temp.t_solo(v_l)));
  f := pg_temp.t_si(f, v_f2 = '{"stock":35,"lotes":[35],"bolsa":0}',
                    format('volver a cargar la fecha dejo %s, esperado {stock 35, lotes [35], bolsa 0}', v_f2));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s', v_f1, v_f2));
END
$fn$;

-- D2 · como F, pero antes de fusionar hay una salvedad por la linea entera
--      (20) que devolvio 10 a L1 y 5 a L2 (a cada uno lo suyo). La fusion
--      reapunta la anotacion de L2 a L1: quedan dos entradas del mismo lote, y
--      anular tiene que sacar las 15 y reponer la huella 15, no 10.
CREATE OR REPLACE FUNCTION pg_temp.caso_d2(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l1 bigint; p jsonb; v_ped bigint; v_salv bigint; v_item2 bigint;
  f text[] := '{}'; v_f3 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":10,"restante":10},{"dias":90,"cantidad":10,"restante":10}]', 5);
  v_prod := v->>'prod'; v_l1 := v->'lotes'->>0;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_ped := p->>'pedido';
  v_salv := pg_temp.t_salvedad(v_ped, (p->>'item')::bigint, 20, 'cliente_rechaza');
  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[{"dias":60,"cantidad":20}]');
  PERFORM pg_temp.t_anular(v_salv);
  v_f3 := pg_temp.t_foto(v_prod);

  SELECT id INTO v_item2 FROM public.pedido_items WHERE pedido_id = v_ped AND producto_id = v_prod;
  f := pg_temp.t_si(f, v_f3 = '{"stock":5,"lotes":[5],"bolsa":0}',
                    format('anular despues de la fusion dejo %s, esperado {stock 5, lotes [5], bolsa 0}', v_f3));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item2, v_l1) = 15,
                    format('anular repuso huella %s en el lote fusionado, esperado 15', pg_temp.t_huella(v_item2, v_l1)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('foto %s', v_f3));
END
$fn$;

-- N · se agrega un vencimiento nuevo (150 dias, 30): nace lleno y saca de la
--     bolsa; el lote que estaba no se toca.
CREATE OR REPLACE FUNCTION pg_temp.caso_n(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l bigint; f text[] := '{}'; v_foto jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod'; v_l := v->'lotes'->>0;
  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod,
                           '[{"dias":90,"cantidad":100},{"dias":150,"cantidad":30}]');
  v_foto := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, pg_temp.t_lote(v_l) = '{"dias":90,"cant":100,"rest":50}',
                    format('el lote que estaba quedo %s', COALESCE(pg_temp.t_lote(v_l)::text, 'borrado')));
  f := pg_temp.t_si(f, v_foto = '{"stock":90,"lotes":[50,30],"bolsa":10}',
                    format('agregar el vencimiento dejo %s, esperado {stock 90, lotes [50,30], bolsa 10}', v_foto));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('foto despues %s', v_foto));
END
$fn$;

-- Q · se corrige la cantidad del mismo vencimiento (100 -> 80): mismo lote,
--     lo consumido (50) se conserva.
CREATE OR REPLACE FUNCTION pg_temp.caso_q(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l bigint; f text[] := '{}'; v_foto jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod'; v_l := v->'lotes'->>0;
  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[{"dias":90,"cantidad":80}]');
  v_foto := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, pg_temp.t_lote(v_l) = '{"dias":90,"cant":80,"rest":30}',
                    format('el lote quedo %s, esperado el mismo con {cant 80, rest 30}',
                           COALESCE(pg_temp.t_lote(v_l)::text, 'borrado')));
  f := pg_temp.t_si(f, v_foto = '{"stock":90,"lotes":[30],"bolsa":60}',
                    format('corregir la cantidad dejo %s, esperado {stock 90, lotes [30], bolsa 60}', v_foto));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('foto despues %s', v_foto));
END
$fn$;

-- ---------------------------------------------------------------------------
-- #1073
-- ---------------------------------------------------------------------------

-- S1 · lote 100 con 50 vivas, bolsa 3. Pedido 10: 3 de la bolsa y 7 del lote
--      (huella 7). Salvedad producto_danado por las 10: la linea se borra.
--      Anular: la linea vuelve y su huella en el lote tambien (7).
CREATE OR REPLACE FUNCTION pg_temp.caso_s1(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l bigint; p jsonb; v_ped bigint; v_item bigint; v_salv bigint;
  v_item2 bigint; f text[] := '{}'; h0 jsonb; h1 jsonb; h2 jsonb; v_f0 jsonb; v_f2 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 3);
  v_prod := v->>'prod'; v_l := v->'lotes'->>0;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 10); v_ped := p->>'pedido'; v_item := p->>'item';
  h0 := pg_temp.t_huella_tabla(v_prod); v_f0 := pg_temp.t_foto(v_prod);
  IF pg_temp.t_huella(v_item, v_l) <> 7 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: huella %s', h0)));
  END IF;

  v_salv := pg_temp.t_salvedad(v_ped, v_item, 10, 'producto_danado');
  h1 := pg_temp.t_huella_tabla(v_prod);
  PERFORM pg_temp.t_anular(v_salv);
  h2 := pg_temp.t_huella_tabla(v_prod);
  v_f2 := pg_temp.t_foto(v_prod);

  SELECT id INTO v_item2 FROM public.pedido_items WHERE pedido_id = v_ped AND producto_id = v_prod;
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item2, v_l) = 7,
                    format('anular repuso la linea pero su huella en el lote quedo %s (era 7)',
                           pg_temp.t_huella(v_item2, v_l)));
  f := pg_temp.t_si(f, v_f2 = v_f0, format('anular la merma movio stock o lotes: %s -> %s', v_f0, v_f2));
  RETURN jsonb_build_object('fallas', to_jsonb(f),
    'reporte', format('pedido_item_lotes pedido %s / salvedad %s / anulada %s', h0, h1, h2));
END
$fn$;

-- S2 · lote 100 con 50 vivas, bolsa 3. Linea principal de 10 (3 de la bolsa,
--      7 del lote: huella 7) y regalo de 2 del MISMO producto (del lote:
--      huella 2), promo "10 + 2" que mueve stock. Salvedad de 1 sobre la
--      principal: cae el regalo (vuelven 2) y vuelve 1. La huella de la
--      principal tiene que quedar en 6, no en 4.
CREATE OR REPLACE FUNCTION pg_temp.caso_s2(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l bigint; p jsonb; v_ped bigint; v_item bigint; v_promo bigint;
  v_regalo bigint; f text[] := '{}'; h0 jsonb; h1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 3);
  v_prod := v->>'prod'; v_l := v->'lotes'->>0;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 10); v_ped := p->>'pedido'; v_item := p->>'item';

  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id)
  VALUES ('ZZ ensayo 1073 S2', 'bonificacion', CURRENT_DATE, p_suc, true, v_prod) RETURNING id INTO v_promo;
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v_promo, 'cantidad_compra', 10, p_suc), (v_promo, 'cantidad_bonificacion', 2, p_suc);
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id)
  VALUES (v_promo, v_prod, p_suc);

  -- El regalo, cargado como lo carga crear_pedido_completo: la linea y su
  -- bajada de stock con la linea en el GUC (deja huella).
  INSERT INTO public.pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal,
                                   sucursal_id, es_bonificacion, promocion_id)
  VALUES (v_ped, v_prod, 2, 0, 0, p_suc, true, v_promo) RETURNING id INTO v_regalo;
  PERFORM set_config('app.stock_origen', 'pedido_creado', true);
  PERFORM set_config('app.stock_ref_tipo', 'pedido', true);
  PERFORM set_config('app.stock_ref_id', v_ped::text, true);
  PERFORM set_config('app.stock_pedido_item_id', v_regalo::text, true);
  UPDATE public.productos SET stock = stock - 2 WHERE id = v_prod;
  PERFORM set_config('app.stock_pedido_item_id', '', true);
  PERFORM set_config('app.stock_origen', '', true);

  h0 := pg_temp.t_huella_tabla(v_prod);
  IF pg_temp.t_huella(v_item, v_l) <> 7 OR pg_temp.t_huella(v_regalo, v_l) <> 2 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: huella %s', h0)));
  END IF;

  PERFORM pg_temp.t_salvedad(v_ped, v_item, 1, 'cliente_rechaza');
  h1 := pg_temp.t_huella_tabla(v_prod);

  f := pg_temp.t_si(f, NOT EXISTS (SELECT 1 FROM public.pedido_items WHERE id = v_regalo),
                    'el regalo no cayo: el ensayo no ejercita la resincronizacion');
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l) = 6,
                    format('la huella de la linea principal quedo %s, esperado 6 (7 menos la unidad devuelta)',
                           pg_temp.t_huella(v_item, v_l)));
  RETURN jsonb_build_object('fallas', to_jsonb(f),
    'reporte', format('principal %s, regalo %s · pedido_item_lotes antes %s / despues %s',
                      v_item, v_regalo, h0, h1));
END
$fn$;

-- S3 · el orden de los locks: pedidos antes que pedido_items, en las dos.
CREATE OR REPLACE FUNCTION pg_temp.caso_s3(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_reg text := pg_get_functiondef('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure);
  v_anu text := pg_get_functiondef('public.anular_salvedad(bigint,text)'::regprocedure);
  v_r_ped int; v_r_item int; v_r_lock int; v_a_ped int; v_a_item int;
  f text[] := '{}';
BEGIN
  v_r_ped  := regexp_instr(v_reg, 'FROM pedidos\s+WHERE id = p_pedido_id\s+AND sucursal_id = v_sucursal\s+FOR UPDATE');
  v_r_item := regexp_instr(v_reg, 'FROM pedido_items pi\s+WHERE pi\.id = p_pedido_item_id');
  v_r_lock := regexp_instr(v_reg, 'PERFORM 1 FROM pedido_items');
  v_a_ped  := regexp_instr(v_anu, 'FROM pedidos\s+WHERE id = v_salvedad\.pedido_id AND sucursal_id = v_sucursal\s+FOR UPDATE');
  v_a_item := regexp_instr(v_anu, 'UPDATE pedido_items SET');

  f := pg_temp.t_si(f, v_r_ped > 0 AND v_r_ped < v_r_item AND v_r_ped < v_r_lock,
                    format('registrar_salvedad no bloquea pedidos antes que pedido_items (pedidos en %s, linea en %s/%s)',
                           v_r_ped, v_r_item, v_r_lock));
  f := pg_temp.t_si(f, v_a_ped > 0 AND v_a_ped < v_a_item,
                    format('anular_salvedad no bloquea pedidos antes que pedido_items (%s, %s)', v_a_ped, v_a_item));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- S4 · L2 vence a 30 dias y esta vacio (50, 0 vivas); L1 vence a 90 (100, 50
--      vivas). Bolsa 5. Pedido 20: 5 de la bolsa y 15 de L1 (huella 15). Se
--      suman 20 a la bolsa. Salvedad de 10: vuelven a L1 (no a L2, que vence
--      antes y tiene hueco) y la huella de L1 baja a 5. Anular: todo como
--      despues del pedido.
CREATE OR REPLACE FUNCTION pg_temp.caso_s4(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l2 bigint; v_l1 bigint; p jsonb; v_ped bigint; v_item bigint; v_salv bigint;
  f text[] := '{}'; h0 jsonb; h1 jsonb; h2 jsonb; v_f0 jsonb; v_f1 jsonb; v_f2 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 5);
  v_prod := v->>'prod'; v_l2 := v->'lotes'->>0; v_l1 := v->'lotes'->>1;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_ped := p->>'pedido'; v_item := p->>'item';
  PERFORM pg_temp.t_a_la_bolsa(v_prod, 20);
  h0 := pg_temp.t_huella_tabla(v_prod); v_f0 := pg_temp.t_foto(v_prod);
  IF pg_temp.t_huella(v_item, v_l1) <> 15 OR v_f0 <> '{"stock":55,"lotes":[0,35],"bolsa":20}' THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s, huella %s', v_f0, h0)));
  END IF;

  v_salv := pg_temp.t_salvedad(v_ped, v_item, 10, 'cliente_rechaza');
  h1 := pg_temp.t_huella_tabla(v_prod); v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = '{"stock":65,"lotes":[0,45],"bolsa":20}',
                    format('la devolucion dejo %s, esperado {stock 65, lotes [0,45], bolsa 20}: volver a L1', v_f1));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 5,
                    format('la huella en L1 quedo %s, esperado 5 (15 menos las 10 devueltas)',
                           pg_temp.t_huella(v_item, v_l1)));

  PERFORM pg_temp.t_anular(v_salv);
  h2 := pg_temp.t_huella_tabla(v_prod); v_f2 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f2 = v_f0, format('anular dejo %s; despues del pedido era %s', v_f2, v_f0));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 15,
                    format('despues de anular la huella en L1 quedo %s, esperado 15', pg_temp.t_huella(v_item, v_l1)));
  RETURN jsonb_build_object('fallas', to_jsonb(f),
    'reporte', format('L2 %s, L1 %s · pedido_item_lotes pedido %s / salvedad %s / anulada %s · fotos %s / %s / %s',
                      v_l2, v_l1, h0, h1, h2, v_f0, v_f1, v_f2));
END
$fn$;

-- S4b · lo mismo, pero se cancela el pedido entero: las 15 que salieron de L1
--       vuelven a L1 y la huella del pedido desaparece. Las 5 que salieron de
--       la bolsa no tienen lote y van por FEFO, como siempre (a L2).
CREATE OR REPLACE FUNCTION pg_temp.caso_s4b(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l2 bigint; v_l1 bigint; p jsonb; v_ped bigint; v_item bigint; v_res jsonb;
  f text[] := '{}'; h0 jsonb; h1 jsonb; v_f1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 5);
  v_prod := v->>'prod'; v_l2 := v->'lotes'->>0; v_l1 := v->'lotes'->>1;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_ped := p->>'pedido'; v_item := p->>'item';
  PERFORM pg_temp.t_a_la_bolsa(v_prod, 20);
  h0 := pg_temp.t_huella_tabla(v_prod);

  v_res := public.cancelar_pedido_con_stock(v_ped, 'ensayo 1054', p_adm, NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'cancelar: %', v_res;
  END IF;
  h1 := pg_temp.t_huella_tabla(v_prod); v_f1 := pg_temp.t_foto(v_prod);

  f := pg_temp.t_si(f, v_f1 = '{"stock":75,"lotes":[5,50],"bolsa":20}',
                    format('cancelar dejo %s, esperado {stock 75, lotes [5,50], bolsa 20}: las 15 de L1 vuelven a L1', v_f1));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 0,
                    format('el pedido cancelado sigue con huella %s en L1', pg_temp.t_huella(v_item, v_l1)));
  RETURN jsonb_build_object('fallas', to_jsonb(f),
    'reporte', format('L2 %s, L1 %s · pedido_item_lotes pedido %s / cancelado %s · foto %s',
                      v_l2, v_l1, h0, h1, v_f1));
END
$fn$;

DO $ensayo1054$
DECLARE
  v_admin   uuid;
  v_suc     bigint;
  v_otra    bigint;
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
    RAISE EXCEPTION 'ens1054 · el ensayo necesita un admin activo con una sucursal activa';
  END IF;
  SELECT id INTO v_otra FROM sucursales WHERE id <> v_suc ORDER BY id LIMIT 1;
  SELECT id INTO v_cliente FROM clientes WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;
  IF v_cliente IS NULL OR v_otra IS NULL THEN
    RAISE EXCEPTION 'ens1054 · el ensayo necesita un cliente activo en la sucursal % y otra sucursal', v_suc;
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  -- Cada caso corre en un subbloque que termina en una excepcion atrapada,
  -- asi que no deja nada; si alguno falla, la migracion entera aborta.
  FOREACH v_caso IN ARRAY ARRAY['a', 'b', 'c', 'c2', 'd', 'd2', 'f', 'f2', 'f3', 'x', 'x2', 'x3',
                                'x4', 'x5', 'x6', 'n', 'q',
                                's1', 's2', 's3', 's4', 's4b'] LOOP
    v_out := NULL;
    BEGIN
      EXECUTE format('SELECT pg_temp.caso_%s($1, $2, $3, $4)', v_caso)
        INTO v_out USING v_cliente, v_admin, v_suc, v_otra;
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
    RAISE EXCEPTION E'ens1054 · el ensayo fallo (% fallas), la migracion no se aplica:\n- %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
END
$ensayo1054$;

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
