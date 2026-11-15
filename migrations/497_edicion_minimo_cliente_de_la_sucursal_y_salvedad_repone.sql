-- =========================================================================
-- NNN · LA EDICIÓN NO SE TRABA POR UN MÍNIMO QUE SUBIÓ DESPUÉS, EL ALTA NO
--       NOMBRA A UN CLIENTE DE OTRA SUCURSAL, Y ANULAR UNA SALVEDAD REPONE
--       EL COBRO QUE RECORTÓ
--       (reauditoría completa del 12/11: CAT-3, SEG-1 y COB-1 de #1559;
--        tarjeta 6 de #1565)
--
-- Reemplaza el cuerpo entero de cuatro funciones (`validar_minimo_venta_item`,
-- `pedidos_cliente_asignado`, `pedidos_cliente_reservado` y
-- `desafectar_sobrepago_pedido`), parcha por ancla `actualizar_pedido_items` y
-- `anular_salvedad`, y le suma una columna a `salvedades_items`. Premisa de
-- md5 sobre los cuerpos vivos leídos el 12/11 (la 490 aplicada) y poscondición
-- de md5, definer y ACL.
-- Ensayo: scripts/test-minimo-cliente-salvedad-1559.sql. Se aplica en LF.
--
-- =========================================================================
-- 1 · CAT-3 · EL MÍNIMO DE VENTA RIGE LO NUEVO Y LO QUE BAJA
-- =========================================================================
-- `trg_validar_minimo_venta_item` (diferido) suma las líneas de venta de cada
-- producto al confirmar y rechaza si quedan debajo de
-- `productos.cantidad_minima_venta`. `actualizar_pedido_items` borra y
-- reinserta todas las líneas, así que para el trigger todas son nuevas: un
-- pedido con 5 u. de un producto cuyo mínimo pasó después a 12 no se podía
-- editar en ninguna línea, ni siquiera en otra.
--
-- La política rige el alta, no retroactivamente (como el monto mínimo, trampa
-- 8 de CLAUDE.md). Ahora la edición anota, antes de borrar, cuánto tenía el
-- pedido de cada producto (`app.minimo_venta_previo`, local a la
-- transacción, una sola vez por pedido: la primera foto es la de antes de
-- editar). El trigger deja pasar el producto que ya estaba y no bajó; rechaza
-- el producto nuevo y el que baja, como hasta ahora. El espejo del front es
-- `moqQueBloqueaLaEdicion` (src/utils/precioMayorista.ts).
--
-- =========================================================================
-- 2 · SEG-1 · EL ALTA NO NOMBRA A UN CLIENTE DE OTRA SUCURSAL
-- =========================================================================
-- `pedidos_cliente_asignado()` y `pedidos_cliente_reservado()` son triggers
-- BEFORE INSERT DEFINER que leían el cliente sin acotar a `NEW.sucursal_id`.
-- La FK compuesta `(cliente_id, sucursal_id)` corre después de los BEFORE,
-- así que con un id de otra sucursal el alta respondía «Cliente asignado a
-- otro preventista: <nombre> (#268) lo atiende <vendedor>» o «El cliente 270
-- está reservado a administración», y los ids son secuenciales.
--
-- Ahora los dos miran sólo un cliente de la sucursal del pedido. Si no lo es,
-- no dicen nada y la FK rechaza igual que con un id que no existe (23503).
-- `crear_pedido_completo` no cambia.
--
-- =========================================================================
-- 3 · COB-1 · ANULAR UNA SALVEDAD REPONE EL COBRO QUE RECORTÓ
-- =========================================================================
-- Una salvedad sobre una boleta cobrada recorta el cobro (migs 165-168):
-- `pedidos_reconciliar_pagos` llama a `desafectar_sobrepago_pedido`, que le
-- saca el excedente al pago más nuevo. Anularla subía el total de vuelta y el
-- cobro quedaba recortado: el cliente figuraba debiendo plata que pagó.
--
-- Decisión del dueño (12/11): la anulación repone el cobro que esa salvedad
-- recortó, y la boleta queda como si la salvedad no hubiera existido.
--   · La salvedad guarda qué pago recortó y cuánto
--     (`salvedades_items.cobro_recortado`, un arreglo). Lo escribe
--     `desafectar_sobrepago_pedido` cuando corre dentro del alta de una
--     salvedad: `registrar_salvedad` deja `app.stock_origen = 'salvedad'` y
--     `app.stock_ref_id` = el pedido mientras baja el total, y la salvedad es
--     la última de ese pedido creada en esta transacción. Guarda también los
--     datos del pago (cliente, forma, fecha, referencia, quien cobró) por si
--     el recorte lo borró entero.
--   · Sólo el cobro de boleta: lo pagado a cuenta, un pedazo o el crédito de
--     una NC quedan a favor del cliente (#1329) y no hay nada que reponer.
--   · `anular_salvedad` le devuelve a cada pago lo que le sacó, con tope en lo
--     que la boleta debe después de volver el total. Un pago que el recorte
--     borró entero (esta salvedad u otra de la misma boleta) vuelve como un
--     cobro nuevo con sus datos.
--   · Decisión del dueño (13/11): un pago que ya está en la foto de una
--     rendición confirmada (#1248) vuelve como un cobro nuevo de su chofer, y
--     la rendición no cambia. Como la caja de la sucursal está cerrada hasta
--     ese día (`ultima_fecha_caja_cerrada` es el último día confirmado de
--     cualquier chofer), el cobro nuevo lleva la fecha de hoy: es como entra
--     cualquier cobro tardío. Lo mismo cuando la fecha del cobro original quedó
--     cerrada sin estar en una foto (otro chofer cerró ese día, o el recorte lo
--     había borrado): ese cobro no se puede tocar ni volver a cargar con su
--     fecha. Sólo se frena si la caja está cerrada también hoy.
--   · Decisión del dueño (13/11): un pago que ya no existe o se fue a otra
--     boleta, sin que lo haya borrado una salvedad, no se repone, y la
--     respuesta lo dice.
--   · Si el día de la entrega está cerrado, la anulación se rechaza antes, como
--     hasta ahora (#1327: un día con la caja cerrada no cambia de total). Por eso
--     el caso de la rendición confirmada aparece con un cobro anterior a la
--     entrega, en un día que ya se cerró.
--   · `pedidos_reconciliar_pagos` no cambia: sólo actúa cuando el total baja.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisa: los cuerpos vivos son los leídos el 12/11, y la columna no existe
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.validar_minimo_venta_item()',  '4395467ecaf14a7db9fea593f143ff04'),
    ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'ffeb5f8e91a22f1718cdb928b2eb1dcb'),
    ('public.pedidos_cliente_asignado()',   '44d1b9ec5113485845bcae37ac62af7c'),
    ('public.pedidos_cliente_reservado()',  'b207b88970f2f621035dc53f2a6efa69'),
    ('public.desafectar_sobrepago_pedido(bigint)', 'f0a6c0bc96d4d5e3163bf7ff5faef30a'),
    ('public.anular_salvedad(bigint,text)', '7649abb7b00d2bd13720d0f9a3f1bc8b')
  ) AS t(f, h) LOOP
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió en prod desde que se leyó (md5 %): rehacer sobre la definición vigente', r.f, v;
    END IF;
  END LOOP;

  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public' AND table_name = 'salvedades_items'
                AND column_name = 'cobro_recortado') THEN
    RAISE EXCEPTION 'mig NNN · salvedades_items.cobro_recortado ya existe: revisar a mano';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 1 · CAT-3 · el trigger deja pasar el producto que ya estaba y no bajó
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validar_minimo_venta_item()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_nombre text;
  v_minimo integer;
  v_total  bigint;
  v_previo bigint;
BEGIN
  -- #1470: el mínimo es del PRODUCTO en el pedido, no de la línea (decisión del
  -- dueño, 06/11): la suma de sus líneas de venta, la de un combo incluida. Un
  -- combo parte el producto en la línea del combo y la suelta (#1191), y
  -- cualquiera de las dos puede quedar debajo del mínimo sin que el producto lo
  -- esté. Es lo que mide validarMOQPedido en el front. Por eso corre diferido,
  -- al confirmar: recién ahí están todas las líneas.

  -- Los RPCs de salvedad prenden este flag (local a la transaccion): lo que
  -- se entrega de menos no puede quedar trabado por el minimo de compra.
  IF COALESCE(current_setting('app.omitir_minimo_venta', true), '') = '1' THEN
    RETURN NULL;
  END IF;

  IF COALESCE(NEW.es_bonificacion, false) THEN
    RETURN NULL;
  END IF;

  SELECT nombre, cantidad_minima_venta INTO v_nombre, v_minimo
  FROM productos WHERE id = NEW.producto_id AND sucursal_id = NEW.sucursal_id;

  IF v_minimo IS NULL THEN
    RETURN NULL;
  END IF;

  -- Un vale blanco no tiene minimo de venta por producto (N6), ni en el alta ni
  -- en la edicion (decision del dueño, 06/11). crear_pedido_completo prende el
  -- flag de arriba solo mientras inserta las lineas de un VB y lo apaga antes
  -- de terminar: al confirmar ya no esta, y el VB se reconoce por el pedido.
  IF EXISTS (SELECT 1 FROM pedidos
              WHERE id = NEW.pedido_id AND sucursal_id = NEW.sucursal_id
                AND tipo_factura = 'VB') THEN
    RETURN NULL;
  END IF;

  -- La fila del trigger puede haberse borrado despues (la edicion borra y
  -- reinserta): se suma lo que hay al confirmar. Sin lineas de venta del
  -- producto no hay minimo que cumplir.
  SELECT COALESCE(SUM(pi.cantidad), 0) INTO v_total
    FROM pedido_items pi
   WHERE pi.pedido_id = NEW.pedido_id AND pi.sucursal_id = NEW.sucursal_id
     AND pi.producto_id = NEW.producto_id
     AND NOT COALESCE(pi.es_bonificacion, false);

  IF v_total > 0 AND v_total < v_minimo THEN
    -- #1559 (CAT-3): la politica rige el alta, no retroactivamente. La edicion
    -- (actualizar_pedido_items) anota cuanto tenia el pedido de cada producto
    -- antes de borrar sus lineas. Un producto que ya estaba debajo de un minimo
    -- que subio despues pasa mientras no baje; el producto nuevo y el que baja
    -- cumplen el minimo de hoy. Espejo: moqQueBloqueaLaEdicion (front).
    v_previo := COALESCE((NULLIF(current_setting('app.minimo_venta_previo', true), '')::jsonb
                            -> (NEW.pedido_id::text) ->> (NEW.producto_id::text))::bigint, 0);
    IF v_previo > 0 AND v_total >= v_previo THEN
      RETURN NULL;
    END IF;

    RAISE EXCEPTION 'La compra mínima de "%" es % unidades (se cargaron %)',
      COALESCE(v_nombre, NEW.producto_id::text), v_minimo, v_total
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NULL;
END;
$function$;

-- actualizar_pedido_items: la foto de cada producto, antes de borrar las líneas. El cuerpo
-- vivo está en LF.
DO $parche_edicion$
DECLARE
  v_def text := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)'::regprocedure);
  v_a text := $a$           ORDER BY pi.producto_id, pi.combo_id, pi.id) x;

  DELETE FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;$a$;
  v_r text := $r$           ORDER BY pi.producto_id, pi.combo_id, pi.id) x;

  -- #1559 (CAT-3): cuanto tenia el pedido de cada producto (lineas de venta),
  -- antes de borrarlas. validar_minimo_venta_item corre diferido, al confirmar,
  -- y con esto deja pasar el producto que ya estaba y no bajo: el minimo de
  -- venta rige lo nuevo y lo que baja, no lo que el pedido ya tenia. Una sola
  -- vez por pedido y transaccion: la foto es la de antes de la primera edicion.
  PERFORM set_config('app.minimo_venta_previo',
    (COALESCE(NULLIF(current_setting('app.minimo_venta_previo', true), ''), '{}')::jsonb
     || jsonb_build_object(p_pedido_id::text,
          COALESCE(NULLIF(current_setting('app.minimo_venta_previo', true), '')::jsonb -> (p_pedido_id::text),
                   (SELECT COALESCE(jsonb_object_agg(x.producto_id::text, x.cant), '{}'::jsonb)
                      FROM (SELECT pi.producto_id, SUM(pi.cantidad) AS cant
                              FROM pedido_items pi
                             WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
                               AND pi.producto_id IS NOT NULL
                               AND NOT COALESCE(pi.es_bonificacion, false)
                             GROUP BY pi.producto_id) x))))::text,
    true);

  DELETE FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;$r$;
  v_n int;
BEGIN
  v_n := (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · actualizar_pedido_items: el ancla aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(v_def, v_a, v_r);
END
$parche_edicion$;

-- ---------------------------------------------------------------------------
-- 2 · SEG-1 · los triggers del alta miran sólo un cliente de la sucursal
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pedidos_cliente_asignado()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_autor uuid;
  v_duenos text;
  v_cliente text;
BEGIN
  IF NEW.cliente_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- #1559 (SEG-1): sólo un cliente de la sucursal del pedido. Con el de otra,
  -- este trigger (DEFINER, corre antes que la FK compuesta) contestaba su nombre
  -- y quién lo atiende. Sin decir nada, la FK (cliente_id, sucursal_id) rechaza
  -- igual que con un id que no existe.
  IF NOT EXISTS (SELECT 1 FROM clientes c
                  WHERE c.id = NEW.cliente_id AND c.sucursal_id = NEW.sucursal_id) THEN
    RETURN NEW;
  END IF;

  v_autor := COALESCE(
    (SELECT p.id FROM perfiles p WHERE p.id = auth.uid()),
    NEW.creado_por,
    NEW.usuario_id
  );

  IF v_autor IS NULL THEN
    RETURN NEW;
  END IF;

  -- Actúa como preventista en la sucursal del pedido: rol base preventista, o el
  -- extra de esa sucursal sin ser admin ni encargado (#1179). No es_preventista():
  -- da true a admin y encargado y mira auth.uid(), no al autor.
  IF NOT public._actua_como_preventista(v_autor, NEW.sucursal_id) THEN
    RETURN NEW;
  END IF;

  -- Huérfano: sin ninguna asignación => visible para todos los preventistas
  -- (mig 028). Pasa.
  IF NOT EXISTS (
    SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = NEW.cliente_id
  ) THEN
    RETURN NEW;
  END IF;

  -- Asignado a él. Pasa.
  IF EXISTS (
    SELECT 1 FROM cliente_preventistas cp
    WHERE cp.cliente_id = NEW.cliente_id AND cp.preventista_id = v_autor
  ) THEN
    RETURN NEW;
  END IF;

  SELECT string_agg(pf.nombre, ', ' ORDER BY pf.nombre)
    INTO v_duenos
    FROM cliente_preventistas cp
    JOIN perfiles pf ON pf.id = cp.preventista_id
   WHERE cp.cliente_id = NEW.cliente_id;

  SELECT COALESCE(c.nombre_fantasia, c.razon_social)
    INTO v_cliente
    FROM clientes c WHERE c.id = NEW.cliente_id AND c.sucursal_id = NEW.sucursal_id;

  RAISE EXCEPTION 'Cliente asignado a otro preventista: % (#%) lo atiende %. No podés cargarle pedidos.',
    COALESCE(v_cliente, '?'), NEW.cliente_id, COALESCE(v_duenos, 'otro preventista')
    USING ERRCODE = '42501';
END;
$function$;

CREATE OR REPLACE FUNCTION public.pedidos_cliente_reservado()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.cliente_id IS NULL OR NEW.usuario_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- #1559 (SEG-1): sólo un cliente de la sucursal del pedido. El de otra sale
  -- por la FK compuesta, igual que un id que no existe, sin decir que está
  -- reservado.
  IF EXISTS (SELECT 1 FROM clientes c
              WHERE c.id = NEW.cliente_id AND c.sucursal_id = NEW.sucursal_id
                AND c.reservado_admin)
     AND public._actua_como_preventista(NEW.usuario_id, NEW.sucursal_id)
  THEN
    RAISE EXCEPTION 'El cliente % está reservado a administración: no se le pueden cargar pedidos desde un preventista', NEW.cliente_id
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3 · COB-1 · la salvedad guarda qué cobro recortó, y la anulación lo repone
-- ---------------------------------------------------------------------------
ALTER TABLE public.salvedades_items ADD COLUMN cobro_recortado jsonb;

COMMENT ON COLUMN public.salvedades_items.cobro_recortado IS
  '#1559 (COB-1): el cobro de boleta que esta salvedad recortó al bajar el total, '
  'uno por pago: [{pago_id, monto, borrado, cliente_id, forma_pago, fecha, referencia, usuario_id}]. '
  'Lo escribe desafectar_sobrepago_pedido; anular_salvedad lo repone y le suma accion y repuesto.';

CREATE OR REPLACE FUNCTION public.desafectar_sobrepago_pedido(p_pedido_id bigint)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_pedido     RECORD;
  v_pago       RECORD;
  v_excedente  numeric;
  v_quitar     numeric;
  v_quitado    numeric := 0;
  v_nota       text;
  v_guc        text;
  v_marca      text;
  -- #1559 (COB-1): la salvedad que esta bajando el total, si es una.
  v_salvedad   bigint;
BEGIN
  SELECT id, total, COALESCE(monto_pagado, 0) AS pagado, estado, sucursal_id
    INTO v_pedido
    FROM pedidos
   WHERE id = p_pedido_id;

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  IF v_pedido.estado IN ('cancelado', 'anulado') THEN
    RETURN 0;
  END IF;

  v_excedente := v_pedido.pagado - v_pedido.total;
  IF v_excedente <= 0.005 THEN
    RETURN 0;
  END IF;

  -- #1559 (COB-1, decision del dueño 12/11): anular una salvedad repone el cobro
  -- que recorto. registrar_salvedad baja el total con app.stock_origen =
  -- 'salvedad' y app.stock_ref_id = este pedido, y su fila ya esta insertada: es
  -- la ultima de este pedido creada en esta transaccion (created_at = now()).
  -- El recorte de cobro de boleta de abajo se anota en ella.
  IF current_setting('app.stock_origen', true) = 'salvedad'
     AND current_setting('app.stock_ref_tipo', true) = 'pedido'
     AND current_setting('app.stock_ref_id', true) = p_pedido_id::text THEN
    SELECT s.id INTO v_salvedad
      FROM salvedades_items s
     WHERE s.pedido_id = p_pedido_id
       AND s.sucursal_id = v_pedido.sucursal_id
       AND s.estado_resolucion = 'pendiente'
       AND s.created_at = now()
     ORDER BY s.id DESC
     LIMIT 1;
  END IF;

  -- #1375: los pagos se bloquean por id, como la foto de la rendicion, los
  -- creditos y los UPDATE por pedido. El orden del bucle de abajo es de negocio y
  -- no cambia; si bloqueara el, se cruzaria con la foto con dos pagos del dia.
  PERFORM 1
     FROM pagos
    WHERE pedido_id = p_pedido_id
    ORDER BY id
      FOR UPDATE;

  -- Se recorta desde el pago mas nuevo: el excedente es lo ultimo que se cargo.
  FOR v_pago IN
    SELECT id, monto, cliente_id, forma_pago, fecha, referencia, usuario_id,
           sucursal_id, nota_credito_id, pago_origen_id, a_cuenta
      FROM pagos
     WHERE pedido_id = p_pedido_id
     ORDER BY fecha DESC, id DESC
     FOR UPDATE
  LOOP
    EXIT WHEN v_excedente <= 0.005;

    v_quitar := LEAST(v_pago.monto, v_excedente);

    -- #1329: un pago a cuenta es plata que entro, no un cobro por el total de la
    -- boleta: lo que sobra queda a favor del cliente, y la caja del dia no se
    -- mueve (por eso va con el escape del guard, como la reimputacion). Decision
    -- del dueño. El credito de una NC sigue por su rama de abajo, y un adelanto de
    -- sueldo no es plata que entro: se recorta.
    IF v_pago.nota_credito_id IS NULL
       AND COALESCE(v_pago.forma_pago, '') <> 'adelanto_sueldo'
       AND (v_pago.a_cuenta OR v_pago.pago_origen_id IS NOT NULL) THEN
      v_marca := ' [baja de total del pedido #' || p_pedido_id || '] [saldo a favor]';
      v_guc := current_setting('app.reimputacion_pagos', true);
      PERFORM set_config('app.reimputacion_pagos', 'on', true);

      IF v_quitar >= v_pago.monto - 0.005 THEN
        UPDATE pagos
           SET pedido_id = NULL,
               notas = trim(COALESCE(notas, '') || v_marca)
         WHERE id = v_pago.id;
        v_quitar := v_pago.monto;
      ELSE
        UPDATE pagos SET monto = monto - v_quitar WHERE id = v_pago.id;

        -- #1359: el pedazo guarda la raiz y su padre directo.
        INSERT INTO pagos (
          cliente_id, pedido_id, monto, forma_pago, fecha,
          referencia, notas, usuario_id, sucursal_id, pago_origen_id, a_cuenta,
          pago_padre_id
        )
        SELECT cliente_id, NULL, v_quitar, forma_pago, fecha, referencia,
               trim(COALESCE(notas, '') || v_marca),
               usuario_id, sucursal_id, COALESCE(pago_origen_id, id), true,
               id
          FROM pagos
         WHERE id = v_pago.id;
      END IF;

      PERFORM set_config('app.reimputacion_pagos', COALESCE(v_guc, ''), true);

      v_excedente := v_excedente - v_quitar;
      v_quitado   := v_quitado + v_quitar;
      CONTINUE;
    END IF;
    v_nota := ' [ajustado -' || trim(to_char(v_quitar, 'FM999999990.00')) ||
              ' por baja de total del pedido ' || p_pedido_id || ']';

    -- #1559 (COB-1): el recorte del cobro de boleta queda en la salvedad que lo
    -- hizo, con los datos del pago por si se borra entero. El credito de una NC
    -- no: lo que le sobra a la boleta vuelve a saldo a favor (abajo) y no hay
    -- cobro que reponer.
    IF v_salvedad IS NOT NULL AND v_pago.nota_credito_id IS NULL THEN
      UPDATE salvedades_items
         SET cobro_recortado = COALESCE(cobro_recortado, '[]'::jsonb)
               || jsonb_build_array(jsonb_build_object(
                    'pago_id',    v_pago.id,
                    'monto',      v_quitar,
                    'borrado',    v_pago.monto - v_quitar <= 0.005,
                    'cliente_id', v_pago.cliente_id,
                    'forma_pago', v_pago.forma_pago,
                    'fecha',      v_pago.fecha,
                    'referencia', v_pago.referencia,
                    'usuario_id', v_pago.usuario_id))
       WHERE id = v_salvedad;
    END IF;

    IF v_pago.monto - v_quitar > 0.005 THEN
      UPDATE pagos
         SET monto = monto - v_quitar,
             notas = trim(COALESCE(notas, '') || v_nota)
       WHERE id = v_pago.id;
    ELSE
      -- CHECK pagos_monto_positivo (#1246): el pago entero se borra en vez de
      -- pasar por monto 0. El UPDATE sin cambio de monto es a proposito: pasa
      -- por la misma guarda de caja que el recorte (guard_pago_fecha_cerrada es
      -- BEFORE UPDATE OF monto y el DELETE no la dispara), asi que borrarlo
      -- entero con la caja cerrada sigue rechazado igual que antes.
      UPDATE pagos
         SET monto = monto,
             notas = trim(COALESCE(notas, '') || v_nota)
       WHERE id = v_pago.id;
      DELETE FROM pagos WHERE id = v_pago.id;
    END IF;

    -- mig 276 (#833): un credito de NC no es plata que se devuelve, es un
    -- documento. Lo que la boleta ya no necesita vuelve a saldo a favor con el
    -- mismo documento (pago sin pedido), en vez de evaporarse. La proxima
    -- imputacion (aplicar_credito_cliente, que el trigger de reconciliacion
    -- llama enseguida) lo aplica a otra boleta, y la NC vuelve a ser anulable
    -- por ese pedazo. #1359: su padre es el pago recortado, aunque se haya borrado.
    IF v_pago.nota_credito_id IS NOT NULL THEN
      INSERT INTO pagos (
        cliente_id, pedido_id, monto, forma_pago, fecha,
        referencia, notas, usuario_id, sucursal_id, nota_credito_id, pago_origen_id,
        pago_padre_id
      ) VALUES (
        v_pago.cliente_id, NULL, v_quitar, v_pago.forma_pago, v_pago.fecha,
        v_pago.referencia,
        'Nota de credito #' || v_pago.nota_credito_id || ': vuelve por baja de total del pedido '
          || p_pedido_id || ' [saldo a favor]',
        v_pago.usuario_id, v_pago.sucursal_id, v_pago.nota_credito_id,
        COALESCE(v_pago.pago_origen_id, v_pago.id),
        v_pago.id
      );
    END IF;

    v_excedente := v_excedente - v_quitar;
    v_quitado   := v_quitado + v_quitar;
  END LOOP;

  RETURN v_quitado;
END;
$function$;

-- anular_salvedad: cuatro anclas (el DECLARE, la decisión antes de tocar nada, la reposición
-- después de que vuelve el total, y la respuesta). El cuerpo vivo está en LF.
DO $parche_anular$
DECLARE
  v_def text := pg_get_functiondef('public.anular_salvedad(bigint,text)'::regprocedure);
  v_a1 text := $a$  v_rot_emp       BIGINT[];
  r_rot           RECORD;
BEGIN$a$;
  v_r1 text := $r$  v_rot_emp       BIGINT[];
  r_rot           RECORD;
  -- #1559 (COB-1): el cobro que esta salvedad recorto.
  v_plan          JSONB := '[]'::jsonb;
  r_rec           RECORD;
  v_vivo          BOOLEAN;
  v_accion        TEXT;
  v_fecha_rec     DATE;
  v_limite_caja   DATE;
  v_falta         NUMERIC;
  v_rep           NUMERIC;
  v_repuesto      NUMERIC := 0;
  v_sin_reponer   NUMERIC := 0;
  v_resultado     JSONB := '[]'::jsonb;
BEGIN$r$;
  v_a2 text := $a$  -- Restituir lo que la salvedad saco no es cargar un pedido nuevo:
  -- el minimo de venta no debe trabarlo (mig 174).$a$;
  v_r2 text := $r$  -- #1559 (COB-1, decision del dueño 12/11): anular repone el cobro de boleta
  -- que esta salvedad recorto (desafectar_sobrepago_pedido lo anoto en
  -- cobro_recortado), y la boleta queda como si la salvedad no hubiera
  -- existido. Aca se decide que se hace con cada recorte, antes de tocar nada:
  --   · 'sumar': el pago sigue en esta boleta, no esta en la foto de una
  --     rendicion cerrada (#1248) y su fecha sigue abierta: se le devuelve lo
  --     que se le saco.
  --   · 'nuevo': el recorte lo borro entero (esta salvedad u otra de la misma
  --     boleta), o el pago esta en la foto de una rendicion cerrada o en un dia
  --     con la caja cerrada (decision del dueño 13/11): vuelve como un cobro
  --     nuevo con sus datos y su chofer, y el pago de la foto no se toca. Si su
  --     fecha ya esta cerrada (ultima_fecha_caja_cerrada es el ultimo dia
  --     confirmado de la sucursal), lleva la de hoy, como cualquier cobro tardio.
  --   · 'nada': el pago ya no existe o se fue a otra boleta sin que lo haya
  --     borrado una salvedad (decision del dueño 13/11). No se repone, y la
  --     respuesta lo dice.
  -- La boleta ya esta bloqueada (arriba); los pagos, por id.
  IF jsonb_array_length(COALESCE(v_salvedad.cobro_recortado, '[]'::jsonb)) > 0 THEN
    PERFORM 1 FROM pagos
     WHERE id IN (SELECT (e->>'pago_id')::bigint
                    FROM jsonb_array_elements(v_salvedad.cobro_recortado) e)
     ORDER BY id
       FOR UPDATE;

    v_limite_caja := public.ultima_fecha_caja_cerrada(v_sucursal);

    FOR r_rec IN
      SELECT e, (e->>'pago_id')::bigint AS pago_id
        FROM jsonb_array_elements(v_salvedad.cobro_recortado) e
    LOOP
      SELECT pg.fecha INTO v_fecha_rec
        FROM pagos pg
       WHERE pg.id = r_rec.pago_id
         AND pg.pedido_id = v_salvedad.pedido_id
         AND pg.sucursal_id = v_sucursal;
      v_vivo := FOUND;

      IF v_vivo AND NOT EXISTS (
           SELECT 1
             FROM rendicion_pagos_confirmados fo
             JOIN rendiciones_control rc ON rc.id = fo.rendicion_id
            WHERE fo.pago_id = r_rec.pago_id
              AND rc.estado IN ('confirmada', 'resuelta'))
         AND (v_limite_caja IS NULL OR v_fecha_rec > v_limite_caja) THEN
        v_accion := 'sumar';
      ELSIF v_vivo OR EXISTS (
           SELECT 1
             FROM salvedades_items s
             CROSS JOIN LATERAL jsonb_array_elements(COALESCE(s.cobro_recortado, '[]'::jsonb)) x
            WHERE s.pedido_id = v_salvedad.pedido_id
              AND s.sucursal_id = v_sucursal
              AND (x->>'pago_id')::bigint = r_rec.pago_id
              AND (x->>'borrado')::boolean) THEN
        v_accion := 'nuevo';
        v_fecha_rec := (r_rec.e->>'fecha')::date;
        IF v_limite_caja IS NOT NULL AND v_fecha_rec <= v_limite_caja THEN
          v_fecha_rec := public._tablero_hoy();
        END IF;
      ELSE
        v_accion := 'nada';
      END IF;

      -- #1327: guard_pago_fecha_cerrada tiraria al reponer. Con la caja cerrada
      -- tambien hoy no hay fecha donde cargar el cobro: se frena aca, antes de
      -- restituir nada.
      IF v_accion <> 'nada' AND v_limite_caja IS NOT NULL AND v_fecha_rec <= v_limite_caja THEN
        RETURN jsonb_build_object('success', false, 'codigo', 'caja_cerrada', 'error',
          format('Anular esta salvedad repone el cobro que recortó, y la caja está cerrada hasta el %s, hoy incluido: para anularla hay que reabrir las rendiciones hasta esa fecha.',
                 to_char(v_limite_caja, 'DD/MM/YYYY')));
      END IF;

      v_plan := v_plan || jsonb_build_array(r_rec.e || jsonb_build_object('accion', v_accion,
                                                                          'fecha_reposicion', v_fecha_rec));
    END LOOP;
  END IF;

  -- Restituir lo que la salvedad saco no es cargar un pedido nuevo:
  -- el minimo de venta no debe trabarlo (mig 174).$r$;
  v_a3 text := $a$  WHERE id = v_salvedad.pedido_id AND sucursal_id = v_sucursal;

  /* mig 244: la merma se anula, y productos.stock NO se toca. La salvedad por$a$;
  v_r3 text := $r$  WHERE id = v_salvedad.pedido_id AND sucursal_id = v_sucursal;

  -- #1559 (COB-1): con el total de vuelta, cada recorte vuelve a la boleta, con
  -- tope en lo que la boleta debe (monto_pagado lo recalcula el trigger de pagos
  -- en cada paso). Lo que no se repone queda en la respuesta.
  FOR r_rec IN SELECT e FROM jsonb_array_elements(v_plan) e LOOP
    SELECT GREATEST(total - COALESCE(monto_pagado, 0), 0) INTO v_falta
      FROM pedidos WHERE id = v_salvedad.pedido_id AND sucursal_id = v_sucursal;
    v_rep := CASE WHEN r_rec.e->>'accion' = 'nada' THEN 0
                  ELSE round(LEAST((r_rec.e->>'monto')::numeric, v_falta), 2) END;

    IF v_rep > 0 AND r_rec.e->>'accion' = 'sumar' THEN
      UPDATE pagos
         SET monto = monto + v_rep,
             notas = trim(COALESCE(notas, '') || ' [repuesto +'
                     || trim(to_char(v_rep, 'FM999999990.00'))
                     || ' por anulacion de la salvedad #' || p_salvedad_id || ']')
       WHERE id = (r_rec.e->>'pago_id')::bigint;
    ELSIF v_rep > 0 AND r_rec.e->>'accion' = 'nuevo' THEN
      INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, referencia,
                         notas, usuario_id, sucursal_id)
      SELECT p.cliente_id, p.id, v_rep, r_rec.e->>'forma_pago', (r_rec.e->>'fecha_reposicion')::date,
             r_rec.e->>'referencia',
             'Cobro repuesto por anulacion de la salvedad #' || p_salvedad_id
               || ' (lo habia recortado del pago #' || (r_rec.e->>'pago_id') || ')',
             (r_rec.e->>'usuario_id')::uuid, v_sucursal
        FROM pedidos p
       WHERE p.id = v_salvedad.pedido_id AND p.sucursal_id = v_sucursal;
    END IF;

    v_repuesto    := v_repuesto + v_rep;
    v_sin_reponer := v_sin_reponer + (r_rec.e->>'monto')::numeric - v_rep;
    v_resultado   := v_resultado || jsonb_build_array(r_rec.e || jsonb_build_object('repuesto', v_rep));
  END LOOP;

  IF jsonb_array_length(v_resultado) > 0 THEN
    UPDATE salvedades_items SET cobro_recortado = v_resultado
     WHERE id = p_salvedad_id AND sucursal_id = v_sucursal;
  END IF;

  /* mig 244: la merma se anula, y productos.stock NO se toca. La salvedad por$r$;
  v_a4 text := $a$  VALUES (p_salvedad_id, 'anulacion', v_salvedad.estado_resolucion, 'anulada', p_notas, v_usuario_id, v_sucursal);
  RETURN jsonb_build_object('success', true);$a$;
  v_r4 text := $r$  VALUES (p_salvedad_id, 'anulacion', v_salvedad.estado_resolucion, 'anulada', p_notas, v_usuario_id, v_sucursal);
  RETURN jsonb_build_object('success', true,
                            'cobro_repuesto', v_repuesto,
                            'cobro_sin_reponer', v_sin_reponer);$r$;
  v_n int;
  i int;
  v_as text[];
  v_rs text[];
BEGIN
  v_as := ARRAY[v_a1, v_a2, v_a3, v_a4];
  v_rs := ARRAY[v_r1, v_r2, v_r3, v_r4];
  FOR i IN 1 .. 4 LOOP
    v_n := (length(v_def) - length(replace(v_def, v_as[i], ''))) / length(v_as[i]);
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'mig NNN · anular_salvedad: el ancla % aparece % vez/veces y se esperaba 1', i, v_n;
    END IF;
    v_def := replace(v_def, v_as[i], v_rs[i]);
  END LOOP;
  EXECUTE v_def;
END
$parche_anular$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, el definer y los EXECUTE quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.validar_minimo_venta_item()', '265f7882a641a8475e80a4eee63677aa', true,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', '9bf3c42b9d4447172b9c96999f65ea00', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.pedidos_cliente_asignado()', '84754c312560f862e6f0c53d213b2f21', true,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.pedidos_cliente_reservado()', 'f3f82c5a401e4476b671287f6373bb62', true,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.desafectar_sobrepago_pedido(bigint)', 'b038256f1acf602b0ed20475215a3080', true,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.anular_salvedad(bigint,text)', 'c521503ea76283748fc1addcbc9f8842', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}')
  ) AS t(f, h, def, acl) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO x
      FROM pg_proc WHERE oid = r.f::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %)', r.f, x.h, x.a, x.def;
    END IF;
  END LOOP;
END
$post$;

COMMIT;
