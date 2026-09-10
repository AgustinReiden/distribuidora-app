-- =========================================================================
-- Los lotes entran por la compra y salen por la merma
--
-- La mig 223 puso el modelo y el motor de consumo. Esta pone las cinco
-- operaciones que lo alimentan y lo vacian.
--
-- POR QUE LOS LOTES DE UNA COMPRA NO SE ESCRIBEN DENTRO DE
-- registrar_compra_completa
-- ---------------------------------------------------------------------------
-- Esa funcion, actualizar_compra_items y anular_compra_atomica son las tres mas
-- parcheadas del repo: la 128 las reescribio, la 177 les metio condicion_iva,
-- la 194 los cargos y la 195 las bonificaciones, todas por el ritual de
-- pg_get_functiondef + ancla sobre el cuerpo vivo. Cada parche mas es una
-- oportunidad mas de revertir en silencio lo que hizo el anterior.
--
-- Los lotes no necesitan estar ahi. sincronizar_lotes_compra es idempotente y
-- se llama desde el cliente justo despues de guardar la compra, con el id que
-- la RPC ya devuelve. Si esa segunda llamada falla, la compra queda bien y los
-- vencimientos sin cargar -- que es exactamente el mismo estado que "el usuario
-- los dejo en blanco", un estado soportado y visible en la ficha como bolsa
-- sin vencimiento.
--
-- La anulacion si necesita engancharse sola, porque nadie la va a llamar: va
-- por un trigger sobre compras.estado.
-- =========================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1 - El clamp
--
-- Red de seguridad del invariante LOTE-A. Cuando la suma de los lotes queda por
-- encima del stock -- una compra editada a la baja, una anulacion, un control de
-- stock que encontro menos --, hay que sacar el excedente de algun lado.
--
-- Sale del lote que vence DESPUES, no del que vence antes: si hay que perder
-- precision, que se pierda sobre la mercaderia que no corre riesgo. Bajar el
-- contador del lote proximo a vencer seria apagar justamente la alarma que
-- esta feature existe para prender.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._clampear_lotes_a_stock(
  p_producto_id bigint,
  p_sucursal_id bigint
) RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_stock     integer;
  v_asignado  integer;
  v_exceso    integer;
  v_saca      integer;
  v_total     integer := 0;
  r           record;
BEGIN
  SELECT stock INTO v_stock
    FROM public.productos
   WHERE id = p_producto_id AND sucursal_id = p_sucursal_id;

  IF v_stock IS NULL THEN
    RETURN 0;
  END IF;

  SELECT COALESCE(SUM(cantidad_restante), 0) INTO v_asignado
    FROM public.producto_lotes
   WHERE producto_id = p_producto_id AND sucursal_id = p_sucursal_id;

  v_exceso := v_asignado - v_stock;
  IF v_exceso <= 0 THEN
    RETURN 0;
  END IF;

  FOR r IN
    SELECT id, cantidad_restante
      FROM public.producto_lotes
     WHERE producto_id = p_producto_id
       AND sucursal_id = p_sucursal_id
       AND cantidad_restante > 0
     ORDER BY fecha_vencimiento DESC, id DESC
     FOR UPDATE
  LOOP
    EXIT WHEN v_exceso <= 0;
    v_saca := LEAST(v_exceso, r.cantidad_restante);
    UPDATE public.producto_lotes
       SET cantidad_restante = cantidad_restante - v_saca
     WHERE id = r.id;
    v_exceso := v_exceso - v_saca;
    v_total  := v_total + v_saca;
  END LOOP;

  RETURN v_total;
END;
$fn$;

COMMENT ON FUNCTION public._clampear_lotes_a_stock(bigint, bigint) IS
  'Baja los lotes hasta que su suma no supere productos.stock, empezando por el '
  'que vence despues. Devuelve cuantas unidades tuvo que sacar. mig 224.';

-- ---------------------------------------------------------------------------
-- 2 - Los lotes de una compra
--
-- p_lotes: [{producto_id, fecha_vencimiento, cantidad}, ...] ya agrupado por
-- (producto, fecha) del lado del cliente. Una linea de factura puede aportar
-- varias entradas -- vienen 12 cajas que vencen en marzo y 8 en mayo -- y varias
-- lineas del mismo producto se suman en una sola.
--
-- Idempotente: borra los lotes de la compra y los reescribe. Preserva el
-- consumo cuando la clave (producto, fecha) sobrevive a la edicion, que es el
-- caso comun -- se corrigio una cantidad, no las fechas.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.sincronizar_lotes_compra(
  p_compra_id bigint,
  p_lotes     jsonb
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_sucursal  bigint := public.current_sucursal_id();
  v_rol       text;
  v_estado    text;
  v_previos   jsonb;
  v_tocados   bigint[];
  v_consumido integer;
  v_creados   integer := 0;
  v_clamp     integer;
  v_avisos    jsonb := '[]'::jsonb;
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

  SELECT estado INTO v_estado
    FROM public.compras
   WHERE id = p_compra_id AND sucursal_id = v_sucursal;

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

  -- Snapshot del consumo actual antes de borrar, indexado por producto|fecha.
  -- Sin esto, editar una compra resucitaria lotes ya vendidos y el clamp los
  -- tendria que volver a bajar por el otro extremo, corriendo el consumo de
  -- lote. Va en un jsonb y no en una tabla temporal: una TEMP TABLE adentro de
  -- una funcion SECURITY DEFINER sobrevive a la funcion y explota en la segunda
  -- llamada de la misma transaccion.
  SELECT COALESCE(jsonb_object_agg(clave, consumido), '{}'::jsonb)
    INTO v_previos
    FROM (
      SELECT producto_id::text || '|' || fecha_vencimiento::text AS clave,
             SUM(cantidad - cantidad_restante)::integer          AS consumido
        FROM public.producto_lotes
       WHERE compra_id = p_compra_id
       GROUP BY 1
    ) t;

  SELECT COALESCE(array_agg(DISTINCT producto_id), ARRAY[]::bigint[])
    INTO v_tocados
    FROM public.producto_lotes
   WHERE compra_id = p_compra_id;

  DELETE FROM public.producto_lotes WHERE compra_id = p_compra_id;

  -- Agrupado en SQL: dos entradas del payload con la misma (producto, fecha)
  -- son el mismo lote y se suman. Asi no hace falta un ON CONFLICT que tendria
  -- que descontar el consumo dos veces.
  FOR r IN
    SELECT (e->>'producto_id')::bigint       AS producto_id,
           (e->>'fecha_vencimiento')::date   AS fecha,
           SUM((e->>'cantidad')::integer)::integer AS cantidad
      FROM jsonb_array_elements(COALESCE(p_lotes, '[]'::jsonb)) e
     GROUP BY 1, 2
  LOOP
    -- La FK compuesta ya lo impediria, pero el mensaje de una FK no le dice
    -- nada a quien esta cargando una factura.
    IF NOT EXISTS (SELECT 1 FROM public.productos
                    WHERE id = r.producto_id AND sucursal_id = v_sucursal) THEN
      RAISE EXCEPTION 'El producto % no existe en esta sucursal', r.producto_id;
    END IF;

    v_consumido := COALESCE(
      (v_previos->>(r.producto_id::text || '|' || r.fecha::text))::integer, 0);

    INSERT INTO public.producto_lotes (
      producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante,
      compra_id, origen, usuario_id
    ) VALUES (
      r.producto_id, v_sucursal, r.fecha, r.cantidad,
      GREATEST(r.cantidad - v_consumido, 0),
      p_compra_id, 'compra', auth.uid()
    );

    v_creados := v_creados + 1;
    v_tocados := v_tocados || r.producto_id;
  END LOOP;

  -- El clamp por producto tocado, en las dos direcciones: los que quedaron en
  -- el payload y los que salieron de el.
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
    'lotes',         v_creados,
    'warning_clamp', v_avisos
  );
END;
$fn$;

COMMENT ON FUNCTION public.sincronizar_lotes_compra(bigint, jsonb) IS
  'Reescribe los lotes de una compra desde [{producto_id, fecha_vencimiento, '
  'cantidad}]. Idempotente. La llama el cliente despues de registrar o editar '
  'la compra. mig 224.';

-- ---------------------------------------------------------------------------
-- 3 - Una compra cancelada se lleva sus lotes
--
-- Va por trigger y no dentro de anular_compra_atomica para no volver a parchear
-- esa funcion. Ojo con el orden: anular_compra_atomica revierte el stock ANTES
-- de poner estado = 'cancelada' (mig 115), asi que cuando este trigger corre el
-- trigger de productos ya pudo haber consumido lotes por FEFO. El invariante se
-- mantiene igual -- borrar lotes solo baja la suma --; lo que se pierde es
-- precision: parte de esas unidades terminan en la bolsa en vez de en un lote.
-- Solo pasa cuando los lotes cubrian casi todo el stock, y se corrige a mano
-- desde la ficha.
--
-- AFTER UPDATE sin `OF estado` y filtrando adentro, por el mismo criterio que
-- el resto de los triggers de la casa.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.borrar_lotes_compra_cancelada() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
BEGIN
  IF NEW.estado = 'cancelada' AND OLD.estado IS DISTINCT FROM 'cancelada' THEN
    DELETE FROM public.producto_lotes WHERE compra_id = NEW.id;
  END IF;
  RETURN NEW;
END;
$fn$;

COMMENT ON FUNCTION public.borrar_lotes_compra_cancelada() IS
  'Al cancelar una compra, sus lotes dejan de existir. mig 224.';

CREATE OR REPLACE TRIGGER trg_lotes_compra_cancelada
  AFTER UPDATE ON public.compras
  FOR EACH ROW EXECUTE FUNCTION public.borrar_lotes_compra_cancelada();

-- ---------------------------------------------------------------------------
-- 4 - Etiquetar parte de la bolsa
--
-- Este es el camino del stock que ya existia cuando se prendio la feature, y
-- tambien el de la compra a la que no se le cargo la fecha. No hay inventario
-- inicial: cuando pasas por un producto y miras la caja, cargas la fecha ahi
-- nomas y esas unidades salen de la bolsa.
--
-- NO toca productos.stock. Solo mueve unidades de "no se cuando vence" a "se
-- cuando vence", que es un cambio de conocimiento, no de saldo.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.crear_lote_manual(
  p_producto_id      bigint,
  p_fecha_vencimiento date,
  p_cantidad         integer
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_sucursal bigint := public.current_sucursal_id();
  v_rol      text;
  v_stock    integer;
  v_asignado integer;
  v_bolsa    integer;
  v_lote_id  bigint;
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la sucursal activa';
  END IF;

  -- Deposito incluido: es quien camina el deposito y ve la caja.
  SELECT rol INTO v_rol FROM public.perfiles WHERE id = auth.uid();
  IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado', 'deposito') THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin, encargado o deposito';
  END IF;

  IF p_fecha_vencimiento IS NULL THEN
    RAISE EXCEPTION 'Falta la fecha de vencimiento';
  END IF;
  IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
    RAISE EXCEPTION 'La cantidad tiene que ser mayor a 0';
  END IF;

  SELECT stock INTO v_stock
    FROM public.productos
   WHERE id = p_producto_id AND sucursal_id = v_sucursal
     FOR UPDATE;

  IF v_stock IS NULL THEN
    RAISE EXCEPTION 'El producto % no existe en esta sucursal', p_producto_id;
  END IF;

  SELECT COALESCE(SUM(cantidad_restante), 0) INTO v_asignado
    FROM public.producto_lotes
   WHERE producto_id = p_producto_id AND sucursal_id = v_sucursal;

  v_bolsa := v_stock - v_asignado;

  IF p_cantidad > v_bolsa THEN
    RAISE EXCEPTION 'Solo hay % unidades sin vencimiento cargado (stock %, ya asignadas %). No se pueden etiquetar %.',
      v_bolsa, v_stock, v_asignado, p_cantidad;
  END IF;

  -- Fusion por (producto, fecha): dos cargas de la misma fecha son el mismo
  -- lote. El UNIQUE de la tabla no lo cubre porque compra_id es NULL y en
  -- Postgres los NULL son distintos entre si.
  SELECT id INTO v_lote_id
    FROM public.producto_lotes
   WHERE producto_id = p_producto_id
     AND sucursal_id = v_sucursal
     AND fecha_vencimiento = p_fecha_vencimiento
     AND compra_id IS NULL
   ORDER BY id
   LIMIT 1
     FOR UPDATE;

  IF v_lote_id IS NOT NULL THEN
    UPDATE public.producto_lotes
       SET cantidad          = cantidad + p_cantidad,
           cantidad_restante = cantidad_restante + p_cantidad
     WHERE id = v_lote_id;
  ELSE
    INSERT INTO public.producto_lotes (
      producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante,
      compra_id, origen, usuario_id
    ) VALUES (
      p_producto_id, v_sucursal, p_fecha_vencimiento, p_cantidad, p_cantidad,
      NULL, 'manual', auth.uid()
    )
    RETURNING id INTO v_lote_id;
  END IF;

  RETURN jsonb_build_object(
    'ok',      true,
    'lote_id', v_lote_id,
    'bolsa',   v_bolsa - p_cantidad
  );
END;
$fn$;

COMMENT ON FUNCTION public.crear_lote_manual(bigint, date, integer) IS
  'Etiqueta con una fecha parte del stock sin vencimiento cargado. No toca '
  'productos.stock. mig 224.';

-- ---------------------------------------------------------------------------
-- 5 - Corregir un contador a mano
--
-- "El sistema dice 12 y en la caja hay 5." La diferencia no se pierde: vuelve a
-- la bolsa, que es la respuesta honesta a "esas 7 unidades existen pero no se
-- de que lote son". Tampoco toca productos.stock: si faltan de verdad, eso es
-- una merma y va por el otro camino.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.ajustar_lote(
  p_lote_id           bigint,
  p_cantidad_restante integer
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_sucursal bigint := public.current_sucursal_id();
  v_rol      text;
  v_lote     record;
  v_stock    integer;
  v_otros    integer;
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la sucursal activa';
  END IF;

  SELECT rol INTO v_rol FROM public.perfiles WHERE id = auth.uid();
  IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin o encargado';
  END IF;

  IF p_cantidad_restante IS NULL OR p_cantidad_restante < 0 THEN
    RAISE EXCEPTION 'La cantidad restante no puede ser negativa';
  END IF;

  SELECT * INTO v_lote
    FROM public.producto_lotes
   WHERE id = p_lote_id AND sucursal_id = v_sucursal
     FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El lote % no existe en esta sucursal', p_lote_id;
  END IF;
  IF p_cantidad_restante > v_lote.cantidad THEN
    RAISE EXCEPTION 'El lote nacio con % unidades: no puede quedarle %',
      v_lote.cantidad, p_cantidad_restante;
  END IF;

  SELECT stock INTO v_stock
    FROM public.productos
   WHERE id = v_lote.producto_id AND sucursal_id = v_sucursal;

  SELECT COALESCE(SUM(cantidad_restante), 0) INTO v_otros
    FROM public.producto_lotes
   WHERE producto_id = v_lote.producto_id
     AND sucursal_id = v_sucursal
     AND id <> p_lote_id;

  IF v_otros + p_cantidad_restante > v_stock THEN
    RAISE EXCEPTION 'No entra: el stock del producto es % y los otros lotes ya ocupan %',
      v_stock, v_otros;
  END IF;

  UPDATE public.producto_lotes
     SET cantidad_restante = p_cantidad_restante
   WHERE id = p_lote_id;

  RETURN jsonb_build_object(
    'ok',                true,
    'lote_id',           p_lote_id,
    'cantidad_restante', p_cantidad_restante,
    'bolsa',             v_stock - v_otros - p_cantidad_restante
  );
END;
$fn$;

COMMENT ON FUNCTION public.ajustar_lote(bigint, integer) IS
  'Corrige a mano el contador de un lote. La diferencia vuelve a la bolsa. No '
  'toca productos.stock. mig 224.';

-- ---------------------------------------------------------------------------
-- 6 - Dar de baja un lote vencido
--
-- EL ORDEN IMPORTA. Se descuenta el lote ANTES que el stock:
--
--   bolsa_despues = (stock - N) - (asignado - N) = stock - asignado = bolsa
--
-- La bolsa queda igual, asi que cuando el trigger de la mig 223 corra no va a
-- encontrar excedente y no va a consumir un segundo lote por FEFO. Al reves --
-- stock primero -- el trigger comeria del lote que vence antes, que podria no
-- ser este.
--
-- El motivo 'vencimiento' ya existe en el CHECK vivo de mermas_stock (mig 011),
-- asi que no hay que tocar el CHECK ni el invariante MERMA-A. El costo lo
-- congela solo trg_mermas_snapshot_costo (mig 119).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.dar_de_baja_lote(
  p_lote_id       bigint,
  p_cantidad      integer,
  p_observaciones text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_sucursal bigint := public.current_sucursal_id();
  v_rol      text;
  v_lote     record;
  v_stock    integer;
  v_merma_id bigint;
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la sucursal activa';
  END IF;

  SELECT rol INTO v_rol FROM public.perfiles WHERE id = auth.uid();
  IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin o encargado';
  END IF;

  IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
    RAISE EXCEPTION 'La cantidad a dar de baja tiene que ser mayor a 0';
  END IF;

  SELECT * INTO v_lote
    FROM public.producto_lotes
   WHERE id = p_lote_id AND sucursal_id = v_sucursal
     FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El lote % no existe en esta sucursal', p_lote_id;
  END IF;
  IF p_cantidad > v_lote.cantidad_restante THEN
    RAISE EXCEPTION 'El lote tiene % unidades: no se pueden dar de baja %',
      v_lote.cantidad_restante, p_cantidad;
  END IF;

  SELECT stock INTO v_stock
    FROM public.productos
   WHERE id = v_lote.producto_id AND sucursal_id = v_sucursal
     FOR UPDATE;

  IF v_stock < p_cantidad THEN
    RAISE EXCEPTION 'El stock del producto es % y la baja es de %: dejaria stock negativo',
      v_stock, p_cantidad;
  END IF;

  -- 1) el lote
  UPDATE public.producto_lotes
     SET cantidad_restante = cantidad_restante - p_cantidad
   WHERE id = p_lote_id;

  -- 2) la merma. usuario_id nunca NULL: es el invariante MERMA-I.
  --    stock_nuevo = GREATEST(stock_anterior - cantidad, 0) es MERMA-B.
  INSERT INTO public.mermas_stock (
    producto_id, cantidad, motivo, observaciones,
    stock_anterior, stock_nuevo, usuario_id, sucursal_id
  ) VALUES (
    v_lote.producto_id, p_cantidad, 'vencimiento',
    COALESCE(NULLIF(btrim(COALESCE(p_observaciones, '')), ''),
             'Lote vencido el ' || to_char(v_lote.fecha_vencimiento, 'DD/MM/YYYY')),
    v_stock, GREATEST(v_stock - p_cantidad, 0), auth.uid(), v_sucursal
  )
  RETURNING id INTO v_merma_id;

  -- 3) el stock, etiquetado para el ledger
  PERFORM set_config('app.stock_origen',   'lote_vencido',    true);
  PERFORM set_config('app.stock_ref_tipo', 'producto_lotes',  true);
  PERFORM set_config('app.stock_ref_id',   p_lote_id::text,   true);
  PERFORM set_config('app.stock_user_id',  auth.uid()::text,  true);

  UPDATE public.productos
     SET stock = stock - p_cantidad,
         updated_at = now()
   WHERE id = v_lote.producto_id AND sucursal_id = v_sucursal;

  RETURN jsonb_build_object(
    'ok',                true,
    'lote_id',           p_lote_id,
    'merma_id',          v_merma_id,
    'cantidad',          p_cantidad,
    'cantidad_restante', v_lote.cantidad_restante - p_cantidad,
    'stock',             v_stock - p_cantidad
  );
END;
$fn$;

COMMENT ON FUNCTION public.dar_de_baja_lote(bigint, integer, text) IS
  'Da de baja unidades de un lote como merma por vencimiento. Descuenta el lote '
  'antes que el stock para que el trigger no consuma un segundo lote. mig 224.';

-- ---------------------------------------------------------------------------
-- 7 - El panel
--
-- Devuelve datos crudos -- la fecha y los dias que faltan -- y NO el semaforo.
-- La regla de que es amarillo y que es rojo vive una sola vez, en
-- src/utils/vencimientos.ts con sus tests. Calcularla tambien aca crearia un
-- espejo que se desincroniza, que es exactamente el problema que obligo a
-- escribir el gate espejo-motor-compras.mjs.
--
-- Una sola firma con DEFAULT y no dos sobrecargas: dos funciones con rangos
-- [obligatorios, total] superpuestos hacen que PostgREST tire PGRST203 en
-- runtime, invisible para tsc y para los tests.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.reporte_vencimientos(
  p_dias_horizonte integer DEFAULT 3650
) RETURNS TABLE (
  lote_id            bigint,
  producto_id        bigint,
  producto_nombre    text,
  producto_codigo    text,
  fecha_vencimiento  date,
  cantidad           integer,
  cantidad_restante  integer,
  dias_restantes     integer,
  origen             text,
  compra_id          bigint,
  stock_producto     integer,
  bolsa_producto     integer
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_sucursal bigint := public.current_sucursal_id();
  v_rol      text;
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la sucursal activa';
  END IF;

  SELECT rol INTO v_rol FROM public.perfiles WHERE id = auth.uid();
  IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado', 'deposito') THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin, encargado o deposito';
  END IF;

  RETURN QUERY
  WITH asignado AS (
    SELECT pl.producto_id AS pid, SUM(pl.cantidad_restante)::integer AS total
      FROM public.producto_lotes pl
     WHERE pl.sucursal_id = v_sucursal
     GROUP BY pl.producto_id
  )
  SELECT l.id,
         l.producto_id,
         p.nombre::text,
         p.codigo::text,
         l.fecha_vencimiento,
         l.cantidad,
         l.cantidad_restante,
         (l.fecha_vencimiento - CURRENT_DATE)::integer,
         l.origen,
         l.compra_id,
         p.stock,
         (p.stock - COALESCE(a.total, 0))::integer
    FROM public.producto_lotes l
    JOIN public.productos p
      ON p.id = l.producto_id AND p.sucursal_id = l.sucursal_id
    LEFT JOIN asignado a ON a.pid = l.producto_id
   WHERE l.sucursal_id = v_sucursal
     AND l.cantidad_restante > 0
     AND (l.fecha_vencimiento - CURRENT_DATE) <= COALESCE(p_dias_horizonte, 3650)
   ORDER BY l.fecha_vencimiento ASC, p.nombre ASC;
END;
$fn$;

COMMENT ON FUNCTION public.reporte_vencimientos(integer) IS
  'Lotes vivos de la sucursal activa con los dias que faltan. El semaforo lo '
  'pinta el front con los umbrales de politicas_comerciales. mig 224.';

-- ---------------------------------------------------------------------------
-- 8 - Permisos
-- ---------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public._clampear_lotes_a_stock(bigint, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.borrar_lotes_compra_cancelada() FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.sincronizar_lotes_compra(bigint, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sincronizar_lotes_compra(bigint, jsonb) TO authenticated;

REVOKE ALL ON FUNCTION public.crear_lote_manual(bigint, date, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crear_lote_manual(bigint, date, integer) TO authenticated;

REVOKE ALL ON FUNCTION public.ajustar_lote(bigint, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ajustar_lote(bigint, integer) TO authenticated;

REVOKE ALL ON FUNCTION public.dar_de_baja_lote(bigint, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.dar_de_baja_lote(bigint, integer, text) TO authenticated;

REVOKE ALL ON FUNCTION public.reporte_vencimientos(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reporte_vencimientos(integer) TO authenticated;

DO $verif$
DECLARE
  v_acl text;
  v_fn  text;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY['_clampear_lotes_a_stock', 'borrar_lotes_compra_cancelada'] LOOP
    SELECT array_to_string(proacl, ',') INTO v_acl
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = v_fn;

    IF v_acl IS NULL THEN
      RAISE EXCEPTION '% quedo con ACL default (PUBLIC ejecuta)', v_fn;
    END IF;
    IF v_acl LIKE '=X/%' OR v_acl LIKE '%,=X/%' THEN
      RAISE EXCEPTION '% quedo ejecutable por PUBLIC: %', v_fn, v_acl;
    END IF;
    IF v_acl LIKE '%anon=%' THEN
      RAISE EXCEPTION '% quedo ejecutable por anon: %', v_fn, v_acl;
    END IF;
    IF v_acl LIKE '%authenticated=%' THEN
      RAISE EXCEPTION '% no deberia ser ejecutable por authenticated: %', v_fn, v_acl;
    END IF;
  END LOOP;

  FOREACH v_fn IN ARRAY ARRAY['sincronizar_lotes_compra', 'crear_lote_manual',
                              'ajustar_lote', 'dar_de_baja_lote',
                              'reporte_vencimientos'] LOOP
    SELECT array_to_string(proacl, ',') INTO v_acl
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = v_fn;

    IF v_acl IS NULL THEN
      RAISE EXCEPTION '% quedo con ACL default (PUBLIC ejecuta)', v_fn;
    END IF;
    IF v_acl LIKE '=X/%' OR v_acl LIKE '%,=X/%' THEN
      RAISE EXCEPTION '% quedo ejecutable por PUBLIC: %', v_fn, v_acl;
    END IF;
    IF v_acl LIKE '%anon=%' THEN
      RAISE EXCEPTION '% quedo ejecutable por anon: %', v_fn, v_acl;
    END IF;
    IF v_acl NOT LIKE '%authenticated=X%' THEN
      RAISE EXCEPTION '% no quedo ejecutable por authenticated: %', v_fn, v_acl;
    END IF;
  END LOOP;
END
$verif$;

COMMIT;
