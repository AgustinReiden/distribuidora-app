-- 480 · Cambio de cliente: el pedido nuevo conserva lo que tenía (#1513 entero; COB-1 de #1512 y
-- PRM-2 de #1515 en el cambio de cliente; gate 3 de #1520; tarjeta 2 de #1524).
--
-- QUÉ PASABA
--   · VTA-01 · cambiar_cliente_pedido conservaba al vendedor sólo si su rol de HOY era admin o
--     preventista, activo y de la sucursal. El pedido de un encargado, de un preventista dado de baja
--     después de vender o de un transportista con el rol extra nacía a nombre del admin que hacía el
--     cambio: la venta por vendedor (pedidos.usuario_id) se movía sin que nadie se enterara. Pasó con
--     el #13372 → #13388, corregido a mano el 05/11.
--   · PRM-1 · El front recalculaba el regalo con la promo vigente, y el server no heredaba la foto
--     (pedido_promo_reglas) ni las cadenas de sustitución: se perdían el sabor elegido, la
--     sustitución, el reparto y la foto. Con el camión ya cargado con Coca, el pedido nuevo podía
--     nacer con Sprite: stock +1 Coca y −1 Sprite contra lo físico.
--   · PRM-2 · Una promo quitada a mano volvía: el cambio le agregaba al pedido un regalo que no tenía.
--   · PAT-8-1 · No miraba clientes.activo del destino. Lo frenaba recién crear_pedido_completo,
--     después de cancelar X, con un mensaje envuelto.
--   · VTA-05 · Fallaba si el pedido tenía un producto sin precio de lista, o con un mínimo de venta
--     que subió después: crear_pedido_completo y sus triggers revalidan como un alta. La edición
--     conserva esas líneas.
--   · COB-1 · Lo que le volvía al cliente original quedaba suelto aunque tuviera boletas abiertas: con
--     'cliente_original', el cobro de X; con los dos destinos, lo que X trajo de su saldo a favor o de
--     un FIFO de su ficha. La boleta seguía "impaga" en la ruta, en el cobro y en la mora.
--
-- QUÉ CAMBIA
--   cambiar_cliente_pedido (cuerpo entero; firma, defaults y EXECUTE iguales):
--   · VTA-01 (decisión del dueño, 10/11) · El pedido nuevo conserva SIEMPRE el usuario_id de X. Lo toma
--     el server del pedido, no de un parámetro, y no mira el rol de hoy. crear_pedido_completo no acepta
--     de vendedor a quien no sea admin o preventista activo, así que el pedido nace a nombre del admin
--     (creado_por sigue siendo él: es quien lo cargó) y enseguida se le pone el vendedor de X, con su
--     renglón en pedido_historial. Cambiar el vendedor es otra cosa: actualizar_preventista_pedido. La
--     respuesta ya no trae 'preventista_fallback' (nadie la leía).
--   · PRM-1 y PRM-2 · El regalo del pedido nuevo es el de X tal cual: las mismas líneas, con la misma
--     promo, el mismo producto y la misma cantidad. Si no, se rechaza antes de tocar nada (un bundle
--     viejo del front lo recalculaba). Si una promo de X cambió de tipo desde el alta, también se
--     rechaza: crear_pedido_completo baja el stock del regalo con el tipo de hoy, y la cancelación lo
--     devolvió con el de la foto. Después del alta, el pedido nuevo hereda de X la foto de cada promo
--     (pedido_promo_reglas, con su origen y su hora), las cadenas de sustitución y los repartos
--     (pedido_item_sustituciones, con claves nuevas) y la descripción de cada línea de regalo. Las
--     filas de reparto que armó el alta se reemplazan por las de X. El stock no cambia: son las mismas
--     líneas que la cancelación devolvió.
--   · PAT-8-1 · El destino tiene que estar activo, antes de cancelar nada.
--   · VTA-05 (en parte) · Recrear el pedido no es una venta nueva. Mientras crea el pedido nuevo,
--     app.cambio_cliente_desde dice cuál es X, y validar_precio_item_pedido no le pide precio de lista
--     a un producto que X ya vendía. app.omitir_minimo_venta queda prendido hasta el commit: el
--     mínimo por producto es un trigger diferido, y si se apagara antes de terminar, regiría. Falta el
--     producto desactivado, que rechaza crear_pedido_completo (es de la tarjeta 3): va aparte, con
--     premisa sobre su md5.
--   · COB-1 (decisión del dueño, 10/11) · Al final, aplicar_credito_cliente(cliente original), FIFO,
--     como el alta y el pago a cuenta. Para eso el pre-bloqueo suma, en su mismo orden, las boletas del
--     cliente original que alcanza su crédito (el suelto más lo que le vuelve de X) y esos créditos.
--     La respuesta suma 'aplicado_cliente_original'.
--   validar_precio_item_pedido: el escape de VTA-05.
--   auditoria_pedidos_cliente_activo(), nueva, sólo de servidor (gate 3 de #1520): toda función de
--   public que inserta en pedidos tiene que nombrar clientes y activo en una misma sentencia. La lee
--   scripts/check-clientes-activo.mjs contra scripts/clientes-activo-permitidas.json, que nace vacía
--   y sólo se achica.
--
-- QUÉ NO CAMBIA
--   crear_pedido_completo, cancelar_pedido_con_stock, aplicar_credito_cliente y actualizar_pedido_items
--   no se tocan. El orden del pre-bloqueo es el mismo (boletas, productos, promos, recorridos, pagos,
--   clientes): sólo suma filas. Los precios de venta se siguen recalculando para el cliente nuevo.
--
-- Ensayo: scripts/test-cambio-cliente-conserva-1513.sql (corre en prod sin dejar rastro), y la clave
-- a2 del arnés (scripts/concurrencia), con A2m nueva.
-- Se aplica en LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos son los que se leyeron de prod el 10/11
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_md5 text;
BEGIN
  SELECT md5(prosrc) INTO v_md5 FROM pg_proc
   WHERE oid = 'public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)'::regprocedure;
  IF v_md5 IS DISTINCT FROM '302a5dbb5b68b80c58d25b2457b0f7d2' THEN
    RAISE EXCEPTION 'mig 480 · cambiar_cliente_pedido cambió en prod desde que se leyó (md5 %, esperado 302a5dbb…): rehacer sobre la definición vigente', v_md5;
  END IF;
  SELECT md5(prosrc) INTO v_md5 FROM pg_proc
   WHERE oid = 'public.validar_precio_item_pedido()'::regprocedure;
  IF v_md5 IS DISTINCT FROM 'eb56230ae9625837fd4c361e7ecadc2e' THEN
    RAISE EXCEPTION 'mig 480 · validar_precio_item_pedido cambió en prod desde que se leyó (md5 %, esperado eb56230a…): rehacer sobre la definición vigente', v_md5;
  END IF;
  IF to_regprocedure('public.auditoria_pedidos_cliente_activo()') IS NOT NULL THEN
    RAISE EXCEPTION 'mig 480 · auditoria_pedidos_cliente_activo() ya existe';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 1 · cambiar_cliente_pedido
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cambiar_cliente_pedido(p_pedido_id bigint, p_nuevo_cliente_id bigint, p_usuario_id uuid, p_items jsonb, p_total numeric, p_total_neto numeric DEFAULT NULL::numeric, p_total_iva numeric DEFAULT 0, p_motivo text DEFAULT 'Cambio de cliente'::text, p_destino_pagos text DEFAULT 'pedido_nuevo'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal     BIGINT := current_sucursal_id();
  v_acting       UUID := auth.uid();
  v_role         TEXT;
  v_pedido       RECORD;
  v_cancel       JSONB;
  v_crear        JSONB;
  v_nuevo_id     BIGINT;
  -- envio_historial_y_rol (#1231): el cargo con que nacio el pedido nuevo.
  v_cargo_nuevo  NUMERIC;
  v_estado_nuevo TEXT;
  -- #1248: lo que el pedido nuevo cobro de mas y quedo a favor del cliente nuevo.
  v_excedente    NUMERIC := 0;
  -- #1460: las boletas que el cobro de X puede pagar en el cliente nuevo.
  v_alcanza      BIGINT[];
  -- #1473: el pre-bloqueo en el orden global y la foto del IVA.
  v_cliente_viejo BIGINT;
  v_plata        NUMERIC;
  v_promos       BIGINT[];
  v_tipo_nuevo   TEXT;
  v_linea        RECORD;
  v_pct          NUMERIC;
  v_neto         NUMERIC;
  v_iva          NUMERIC;
  v_real         NUMERIC;
  v_acc_neto     NUMERIC := 0;
  v_acc_iva      NUMERIC := 0;
  v_acc_real     NUMERIC := 0;
  v_iva_foto     INT := 0;
  -- #1489: lo que le quedo a favor al cliente original con 'pedido_nuevo'.
  v_devuelto     NUMERIC := 0;
  -- #1492 (1): los creditos del cliente nuevo que el pedido nuevo absorbio y
  -- vuelven a quedar sueltos hasta que llegue el cobro de X.
  v_reaplicar    INT := 0;
  -- 480 (#1513, COB-1 de #1512): el destino activo, el regalo de X tal cual,
  -- lo que hereda el pedido nuevo y el credito que le vuelve al cliente original.
  v_cliente_activo  BOOLEAN;
  v_plata_viejo     NUMERIC;
  v_regalo_distinto BOOLEAN;
  v_promo_cambiada  TEXT;
  v_par             RECORD;
  v_cadena_nueva    UUID;
  v_repartos        JSONB;
  v_aplicado_viejo  NUMERIC := 0;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No hay sucursal activa');
  END IF;

  IF p_usuario_id IS DISTINCT FROM v_acting THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesion autenticada');
  END IF;

  SELECT rol INTO v_role FROM perfiles WHERE id = v_acting;
  IF v_role IS NULL OR v_role <> 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin puede cambiar el cliente de un pedido');
  END IF;

  IF p_destino_pagos IS NULL OR p_destino_pagos NOT IN ('pedido_nuevo', 'cliente_original') THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Destino de los pagos invalido: ' || COALESCE(p_destino_pagos, 'NULL')
      || '. Tiene que ser pedido_nuevo o cliente_original.');
  END IF;

  -- La reatribucion no es una venta nueva: el pedido ya cumplio (o no) el
  -- minimo cuando se creo. Ver mig 205.
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  -- mig 389 (#1220): la reatribucion conserva el cargo que el pedido ya tenia.
  PERFORM set_config('app.cargo_envio_forzado',
    COALESCE((SELECT cargo_envio::text FROM pedidos WHERE id = p_pedido_id), '0'), true);
  -- cargo_1_base: y su estado (un no_aplica o un bonificado no renacen gratis).
  PERFORM set_config('app.cargo_envio_estado_forzado',
    COALESCE((SELECT cargo_envio_estado FROM pedidos WHERE id = p_pedido_id), ''), true);

  -- Con 'pedido_nuevo' los pagos NO se desimputan al cancelar el viejo: mas
  -- abajo se reapuntan al pedido nuevo, para que el cobro viaje con la venta.
  -- Sin esto, la desimputacion de la mig 235 se los lleva antes y el UPDATE de
  -- mas abajo no encuentra nada. Con 'cliente_original' esa desimputacion es
  -- justo lo que se quiere: el cobro queda a favor del cliente que pago.
  IF p_destino_pagos = 'pedido_nuevo' THEN
    PERFORM set_config('app.cancelacion_conserva_pagos', '1', true);
  END IF;


  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'El pedido nuevo no tiene items');
  END IF;

  -- #1473 (ADV-1, ADV-5): el orden global antes del primer lock, con los dos
  -- destinos de los pagos: las boletas por id, los productos con los contenedores
  -- de sus promos por id, esas promos por id, los recorridos por id, los pagos por
  -- id y los clientes por id. La 459 tomaba las boletas, los recorridos y los pagos
  -- antes que los productos, que tomaba despues cancelar_pedido_con_stock; la
  -- edicion de una boleta del cliente nuevo va productos -> rutas -> creditos: con
  -- un credito y un producto en comun, 40P01. Y el pedido nuevo tomaba los
  -- productos y las promos de los items que X no tenia con la promo de la
  -- cancelacion ya tomada.
  --   - Las boletas: X y las del cliente nuevo que lo cobrado de X (con
  --     'pedido_nuevo') mas sus creditos alcanzan a pagar en el orden de
  --     aplicar_credito_cliente (fecha, id). Lo cobrado cuenta entero aunque
  --     sobre menos: toma de mas, nunca de menos. Los creditos cuentan con los dos
  --     destinos: el alta del pedido nuevo puede tomarlos (#1469).
  --     480 (COB-1): y las del cliente original que alcanza su credito, el suelto
  --     mas lo que le vuelve de X, que al final se aplica FIFO.
  --   - Los productos: los de las lineas de X (la cancelacion los devuelve), los de
  --     los items nuevos (los vende el pedido nuevo) y los contenedores de las
  --     promos de unos y otros (los mueven la barra y el motor).
  --   - Los pagos: los de X (viajan, o la cancelacion los desimputa), los creditos
  --     del cliente nuevo y, 480, los del cliente original.
  --   - Los clientes: el viejo (el saldo de la cancelacion) y el nuevo (el INSERT
  --     del pedido nuevo y su saldo), al final.
  -- Lee sin lock: el SELECT de abajo vuelve a tomar X y valida, y cada funcion de
  -- abajo vuelve a pedir lo que ya esta tomado.
  v_cliente_viejo := (SELECT cliente_id FROM pedidos
                       WHERE id = p_pedido_id AND sucursal_id = v_sucursal);
  v_plata := COALESCE((SELECT sum(monto) FROM pagos
                        WHERE cliente_id = p_nuevo_cliente_id
                          AND sucursal_id = v_sucursal
                          AND pedido_id IS NULL), 0)
           + CASE WHEN p_destino_pagos = 'pedido_nuevo'
                  THEN COALESCE((SELECT monto_pagado FROM pedidos
                                  WHERE id = p_pedido_id
                                    AND sucursal_id = v_sucursal
                                    AND tipo_factura IS DISTINCT FROM 'VB'), 0)
                  ELSE 0 END;

  v_alcanza := ARRAY[p_pedido_id];
  IF v_plata > 0.005 THEN
    v_alcanza := v_alcanza || ARRAY(
      SELECT b.id
        FROM (SELECT p.id,
                     sum(p.total - COALESCE(p.monto_pagado, 0)) OVER (ORDER BY p.fecha, p.id)
                       - (p.total - COALESCE(p.monto_pagado, 0)) AS antes
                FROM pedidos p
               WHERE p.cliente_id = p_nuevo_cliente_id
                 AND p.sucursal_id = v_sucursal
                 AND p.estado NOT IN ('cancelado', 'anulado')
                 AND p.total > COALESCE(p.monto_pagado, 0)) b
       WHERE b.antes < v_plata);
  END IF;

  -- 480 (COB-1): lo que le vuelve al cliente original de X es, con
  -- 'cliente_original', todo lo cobrado (la cancelacion lo desimputa) y, con los
  -- dos destinos, lo que X trajo de su saldo a favor o de un FIFO de su ficha
  -- (#1489). X no cuenta entre sus boletas: se cancela.
  v_plata_viejo := COALESCE((SELECT sum(monto) FROM pagos
                              WHERE cliente_id = v_cliente_viejo
                                AND sucursal_id = v_sucursal
                                AND pedido_id IS NULL), 0)
                 + COALESCE((SELECT sum(monto) FROM pagos
                              WHERE pedido_id = p_pedido_id
                                AND sucursal_id = v_sucursal
                                AND (p_destino_pagos = 'cliente_original'
                                     OR de_saldo_a_favor OR a_cuenta)), 0);
  IF v_plata_viejo > 0.005 THEN
    v_alcanza := v_alcanza || ARRAY(
      SELECT b.id
        FROM (SELECT p.id,
                     sum(p.total - COALESCE(p.monto_pagado, 0)) OVER (ORDER BY p.fecha, p.id)
                       - (p.total - COALESCE(p.monto_pagado, 0)) AS antes
                FROM pedidos p
               WHERE p.cliente_id = v_cliente_viejo
                 AND p.sucursal_id = v_sucursal
                 AND p.id <> p_pedido_id
                 AND p.estado NOT IN ('cancelado', 'anulado')
                 AND p.total > COALESCE(p.monto_pagado, 0)) b
       WHERE b.antes < v_plata_viejo);
  END IF;

  PERFORM 1
     FROM pedidos
    WHERE id = ANY(v_alcanza)
      AND sucursal_id = v_sucursal
    ORDER BY id
      FOR UPDATE;

  v_promos := ARRAY(
    SELECT pi.promocion_id FROM pedido_items pi
     WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
       AND pi.promocion_id IS NOT NULL
    UNION
    SELECT btrim(e->>'promocion_id')::bigint FROM jsonb_array_elements(p_items) e
     WHERE btrim(COALESCE(e->>'promocion_id', '')) ~ '^[0-9]{1,18}$');

  PERFORM 1
     FROM productos
    WHERE sucursal_id = v_sucursal
      AND id IN (SELECT pi.producto_id FROM pedido_items pi
                  WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
                 UNION
                 SELECT btrim(e->>'producto_id')::bigint FROM jsonb_array_elements(p_items) e
                  WHERE btrim(COALESCE(e->>'producto_id', '')) ~ '^[0-9]{1,18}$'
                 UNION
                 SELECT c FROM public._contenedores_de_promos(v_promos, v_sucursal) c)
    ORDER BY id
      FOR UPDATE;

  PERFORM 1
     FROM promociones
    WHERE sucursal_id = v_sucursal
      AND id = ANY(v_promos)
    ORDER BY id
      FOR UPDATE;

  PERFORM 1
     FROM recorridos
    WHERE id IN (SELECT rp.recorrido_id
                   FROM recorrido_pedidos rp
                  WHERE rp.pedido_id = ANY(v_alcanza))
    ORDER BY id
      FOR NO KEY UPDATE;

  PERFORM 1
     FROM pagos
    WHERE id IN (SELECT pg.id
                   FROM pagos pg
                  WHERE pg.pedido_id = p_pedido_id
                    AND pg.sucursal_id = v_sucursal
                 UNION ALL
                 SELECT pg.id
                   FROM pagos pg
                  WHERE pg.cliente_id IN (p_nuevo_cliente_id, v_cliente_viejo)
                    AND pg.sucursal_id = v_sucursal
                    AND pg.pedido_id IS NULL)
    ORDER BY id
      FOR UPDATE;

  PERFORM 1
     FROM clientes
    WHERE id IN (v_cliente_viejo, p_nuevo_cliente_id)
      AND sucursal_id = v_sucursal
    ORDER BY id
      FOR NO KEY UPDATE;

  SELECT * INTO v_pedido FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pedido no encontrado');
  END IF;

  IF COALESCE(v_pedido.tipo_factura, 'ZZ') = 'VB' THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Un vale blanco no cambia de cliente: cancelalo y cargalo de nuevo al cliente correcto');
  END IF;

  IF v_pedido.estado IN ('entregado', 'cancelado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se puede cambiar el cliente de un pedido ' || v_pedido.estado);
  END IF;

  IF p_nuevo_cliente_id = v_pedido.cliente_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'El cliente nuevo es el mismo que el actual');
  END IF;

  -- mig 276 (#833): con 'pedido_nuevo' los pagos se reapuntan al cliente nuevo.
  -- Un credito de NC es del cliente de la NC: no viaja. Con 'cliente_original'
  -- no viaja nada, y el credito vuelve a saldo a favor de su cliente.
  -- #1489: el que X absorbio del saldo a favor (de_saldo_a_favor o a_cuenta)
  -- vuelve suelto a su cliente, que es el de la NC: frena solo el que se imputo
  -- directo a X.
  IF p_destino_pagos = 'pedido_nuevo'
     AND EXISTS (SELECT 1 FROM pagos WHERE pedido_id = p_pedido_id AND nota_credito_id IS NOT NULL
                   AND NOT (de_saldo_a_favor OR a_cuenta)) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'El pedido esta pagado en parte con credito de la nota de credito #'
      || (SELECT min(nota_credito_id) FROM pagos WHERE pedido_id = p_pedido_id AND nota_credito_id IS NOT NULL
             AND NOT (de_saldo_a_favor OR a_cuenta))
      || ', que es de este cliente: no se puede pasar a otro. Elegi que los pagos queden a favor del cliente original, o cancelalo y carga el pedido nuevo.');
  END IF;

  -- 480 (PAT-8-1): el destino tiene que estar activo. crear_pedido_completo
  -- tambien lo frena, pero despues de cancelar X: aca se dice antes de tocar nada.
  SELECT activo INTO v_cliente_activo
    FROM clientes WHERE id = p_nuevo_cliente_id AND sucursal_id = v_sucursal;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'El cliente nuevo no existe en esta sucursal');
  END IF;
  IF NOT COALESCE(v_cliente_activo, false) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'El cliente nuevo esta dado de baja: no se le pueden pasar pedidos. Si vuelve a comprar, reactivalo desde Clientes.');
  END IF;

  -- 480 (PRM-1, PRM-2): el regalo del pedido nuevo es el de X tal cual, las
  -- mismas lineas con la misma promo, el mismo producto y la misma cantidad. El
  -- cambio de cliente no recalcula el regalo: no cambia el sabor que salio en el
  -- camion ni agrega el de una promo que alguien quito. Un bundle viejo del front
  -- lo recalculaba: se rechaza antes de tocar nada.
  WITH viejo AS (
         SELECT pi.promocion_id AS promo, pi.producto_id::bigint AS producto,
                pi.cantidad::numeric AS cantidad
           FROM pedido_items pi
          WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
            AND COALESCE(pi.es_bonificacion, false)),
       nuevo AS (
         SELECT CASE WHEN btrim(COALESCE(e->>'promocion_id', '')) ~ '^[0-9]{1,18}$'
                     THEN btrim(e->>'promocion_id')::bigint END AS promo,
                CASE WHEN btrim(COALESCE(e->>'producto_id', '')) ~ '^[0-9]{1,18}$'
                     THEN btrim(e->>'producto_id')::bigint END AS producto,
                CASE WHEN btrim(COALESCE(e->>'cantidad', '')) ~ '^[0-9]{1,9}(\.[0-9]+)?$'
                     THEN btrim(e->>'cantidad')::numeric END AS cantidad
           FROM jsonb_array_elements(p_items) e
          WHERE COALESCE((e->>'es_bonificacion')::boolean, false))
  SELECT EXISTS (SELECT * FROM viejo EXCEPT ALL SELECT * FROM nuevo)
      OR EXISTS (SELECT * FROM nuevo EXCEPT ALL SELECT * FROM viejo)
    INTO v_regalo_distinto;
  IF v_regalo_distinto THEN
    RETURN jsonb_build_object('success', false, 'error',
      'El regalo del pedido nuevo tiene que ser el del pedido #' || p_pedido_id
      || ' tal cual: el cambio de cliente no lo recalcula. Recarga la app y volve a intentar.');
  END IF;

  -- 480 (PRM-1): crear_pedido_completo baja el regalo con el tipo de HOY de su
  -- promo (mueve stock o barra), y la cancelacion lo devolvio con el de la foto
  -- (#1324). Si una promo cambio de tipo, el pedido nuevo no puede heredar el
  -- regalo como esta. Las promos ya estan tomadas: el tipo no cambia mientras tanto.
  SELECT string_agg(DISTINCT COALESCE(pr.nombre, '#' || pr.id), ', ')
    INTO v_promo_cambiada
    FROM pedido_items pi
    JOIN promociones pr ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
   WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
     AND COALESCE(pi.es_bonificacion, false)
     AND COALESCE(pi.regalo_mueve_stock_foto,
                  public._regalo_modo_del_pedido(p_pedido_id, pi.promocion_id, v_sucursal), false)
         IS DISTINCT FROM COALESCE(pr.regalo_mueve_stock, false);
  IF v_promo_cambiada IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error',
      'La promocion ' || v_promo_cambiada || ' cambio de tipo (mueve stock o barra) desde que se cargo el pedido:'
      || ' su regalo no puede pasar igual al pedido nuevo. Edita el pedido y quitale esa promo, o cancelalo y carga el pedido nuevo.');
  END IF;

  v_cancel := cancelar_pedido_con_stock(p_pedido_id, p_motivo, p_usuario_id, 'cambio_de_cliente');
  IF NOT COALESCE((v_cancel->>'success')::boolean, false) THEN
    RETURN v_cancel;
  END IF;

  PERFORM quitar_pedido_de_recorridos_activos(p_pedido_id);

  -- #1301: los combos del pedido nuevo se miden contra la foto de este, no
  -- contra la definicion vigente, y el nuevo hereda esa foto.
  PERFORM set_config('app.combo_foto_pedido', p_pedido_id::text, true);
  -- 480 (VTA-05): recrear las lineas de X no es una venta nueva.
  -- validar_precio_item_pedido no le pide precio de lista a un producto que X ya
  -- vendia. Y el minimo de venta por producto (validar_minimo_venta_item) es un
  -- trigger diferido: corre al confirmar, asi que el escape queda prendido hasta
  -- el final de la transaccion (set_config local). Solo se crea este pedido.
  PERFORM set_config('app.cambio_cliente_desde', p_pedido_id::text, true);
  PERFORM set_config('app.omitir_minimo_venta', '1', true);

  -- 480 (VTA-01): el pedido nace a nombre del admin (crear_pedido_completo no
  -- acepta de vendedor a quien no sea admin o preventista activo) y abajo se le
  -- pone el vendedor de X.
  v_crear := crear_pedido_completo(
    p_nuevo_cliente_id,
    p_total,
    p_usuario_id,
    p_items,
    v_pedido.notas,
    v_pedido.forma_pago,
    'pendiente',
    v_pedido.fecha,
    v_pedido.tipo_factura,
    p_total_neto,
    COALESCE(p_total_iva, 0),
    v_pedido.fecha_entrega_programada,
    NULL
  );
  IF NOT COALESCE((v_crear->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'No se pudo crear el pedido nuevo: %',
      COALESCE(v_crear->>'errores', v_crear->>'error', 'error desconocido');
  END IF;
  v_nuevo_id := (v_crear->>'pedido_id')::bigint;
  PERFORM set_config('app.combo_foto_pedido', '', true);
  PERFORM set_config('app.cambio_cliente_desde', '', true);

  -- 480 (VTA-01, decision del duenio del 10/11): el pedido nuevo conserva siempre
  -- al vendedor de X, sin mirar su rol de hoy. Lo toma el server del pedido, no
  -- de un parametro: el cambio de cliente no mueve la venta por vendedor.
  -- Cambiar el vendedor es actualizar_preventista_pedido.
  IF v_pedido.usuario_id IS DISTINCT FROM p_usuario_id THEN
    UPDATE pedidos
       SET usuario_id = v_pedido.usuario_id
     WHERE id = v_nuevo_id AND sucursal_id = v_sucursal;
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (v_nuevo_id, v_acting, 'usuario_id', p_usuario_id::text, v_pedido.usuario_id::text, v_sucursal);
  END IF;

  -- 480 (PRM-1): el pedido nuevo hereda de X la foto de cada promo
  -- (pedido_promo_reglas, #1164), con su origen y su hora: el regalo se armo
  -- con esas reglas, no con las de hoy. El tipo es el mismo (se valido arriba).
  UPDATE pedido_promo_reglas n
     SET cantidad_compra       = o.cantidad_compra,
         cantidad_bonificacion = o.cantidad_bonificacion,
         productos             = o.productos,
         origen                = o.origen,
         tomada_at             = o.tomada_at
    FROM pedido_promo_reglas o
   WHERE o.pedido_id = p_pedido_id AND o.sucursal_id = v_sucursal
     AND n.pedido_id = v_nuevo_id AND n.sucursal_id = v_sucursal
     AND n.promocion_id = o.promocion_id
     AND n.regalo_mueve_stock = o.regalo_mueve_stock;

  -- 480 (PRM-1): y las cadenas de sustitucion y los repartos de sus regalos
  -- (#1057, #1091). Cada linea de regalo nueva se empareja con la de X que tiene
  -- la misma promo, producto y cantidad, en orden de id; si X la tenia con clave,
  -- la nueva recibe una clave nueva con los eslabones de X copiados (con su hora,
  -- en su orden), y un reparto de X sigue siendo uno solo, con su propio id
  -- nuevo. Las filas de reparto que armo el alta se reemplazan por las de X. La
  -- descripcion de cada linea es la de X (la marca de "[Sustituido por: ...]").
  -- El stock no cambia: las lineas son las que la cancelacion devolvio, y los
  -- eslabones son historia (la tabla no tiene triggers).
  IF EXISTS (SELECT 1 FROM pedido_items
              WHERE pedido_id IN (p_pedido_id, v_nuevo_id) AND sucursal_id = v_sucursal
                AND COALESCE(es_bonificacion, false)) THEN
    DELETE FROM pedido_item_sustituciones
     WHERE pedido_id = v_nuevo_id AND sucursal_id = v_sucursal;

    SELECT COALESCE(jsonb_object_agg(r.reparto_id::text, gen_random_uuid()), '{}'::jsonb)
      INTO v_repartos
      FROM (SELECT DISTINCT s.reparto_id
              FROM pedido_item_sustituciones s
             WHERE s.pedido_id = p_pedido_id AND s.sucursal_id = v_sucursal
               AND s.reparto_id IS NOT NULL) r;

    FOR v_par IN
      WITH o AS (
             SELECT pi.id, pi.promocion_id, pi.producto_id, pi.cantidad,
                    pi.regalo_cadena_id, pi.descripcion_regalo,
                    row_number() OVER (PARTITION BY pi.promocion_id, pi.producto_id, pi.cantidad
                                       ORDER BY pi.id) AS rn
               FROM pedido_items pi
              WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
                AND COALESCE(pi.es_bonificacion, false)),
           n AS (
             SELECT pi.id, pi.promocion_id, pi.producto_id, pi.cantidad,
                    row_number() OVER (PARTITION BY pi.promocion_id, pi.producto_id, pi.cantidad
                                       ORDER BY pi.id) AS rn
               FROM pedido_items pi
              WHERE pi.pedido_id = v_nuevo_id AND pi.sucursal_id = v_sucursal
                AND COALESCE(pi.es_bonificacion, false))
      SELECT n.id AS nuevo, o.regalo_cadena_id AS cadena, o.descripcion_regalo
        FROM o
        JOIN n ON n.promocion_id IS NOT DISTINCT FROM o.promocion_id
              AND n.producto_id = o.producto_id
              AND n.cantidad = o.cantidad
              AND n.rn = o.rn
       ORDER BY n.id
    LOOP
      v_cadena_nueva := CASE WHEN v_par.cadena IS NOT NULL THEN gen_random_uuid() END;
      UPDATE pedido_items
         SET regalo_cadena_id   = v_cadena_nueva,
             descripcion_regalo = v_par.descripcion_regalo
       WHERE id = v_par.nuevo;
      IF v_par.cadena IS NOT NULL THEN
        INSERT INTO pedido_item_sustituciones (
          pedido_id, pedido_item_id, promocion_id, producto_original_id, producto_sustituto_id,
          cantidad_original, cantidad_sustituta, regalo_mueve_stock_snapshot, ajuste_producto_id_nuevo,
          motivo, autorizado_por, sucursal_id, created_at, reparto_id, cadena_id, producto_raiz_id
        )
        SELECT v_nuevo_id, v_par.nuevo, s.promocion_id, s.producto_original_id, s.producto_sustituto_id,
               s.cantidad_original, s.cantidad_sustituta, s.regalo_mueve_stock_snapshot, s.ajuste_producto_id_nuevo,
               s.motivo, s.autorizado_por, s.sucursal_id, s.created_at,
               (v_repartos->>s.reparto_id::text)::uuid, v_cadena_nueva, s.producto_raiz_id
          FROM pedido_item_sustituciones s
         WHERE s.pedido_id = p_pedido_id AND s.sucursal_id = v_sucursal
           AND s.cadena_id = v_par.cadena
         ORDER BY s.created_at, s.id;
      END IF;
    END LOOP;
  END IF;

  -- #1473 (VTA-F-4): la reatribucion no es una venta nueva. crear_pedido_completo
  -- pone en cada linea el IVA de hoy del producto; aca cada linea de venta toma la
  -- foto de la linea de venta mas vieja de X con el mismo producto y el mismo
  -- combo, la regla de actualizar_pedido_items (464, #1492): la linea del combo y
  -- la suelta son dos lineas (#1191). Una foto 0 es ambigua y deja la de hoy, y un item
  -- que X no tenia tambien. Si alguna cambio, el neto, el IVA y el ingreso real del
  -- pedido se recalculan con la cuenta de crear_pedido_completo: la suma de cada
  -- desglose redondeada, mas el desglose del envio.
  SELECT COALESCE(tipo_factura, 'ZZ') INTO v_tipo_nuevo
    FROM pedidos WHERE id = v_nuevo_id AND sucursal_id = v_sucursal;
  FOR v_linea IN
    SELECT pi.id, pi.cantidad, pi.precio_unitario, pi.porcentaje_iva,
           (SELECT NULLIF(o.porcentaje_iva, 0)
              FROM pedido_items o
             WHERE o.pedido_id = p_pedido_id AND o.sucursal_id = v_sucursal
               AND o.producto_id = pi.producto_id
               AND o.combo_id IS NOT DISTINCT FROM pi.combo_id
               AND NOT COALESCE(o.es_bonificacion, false)
             ORDER BY o.id
             LIMIT 1) AS foto,
           COALESCE(pr.impuestos_internos, 0) AS pct_ii
      FROM pedido_items pi
      LEFT JOIN productos pr ON pr.id = pi.producto_id AND pr.sucursal_id = pi.sucursal_id
     WHERE pi.pedido_id = v_nuevo_id AND pi.sucursal_id = v_sucursal
       AND NOT COALESCE(pi.es_bonificacion, false)
     ORDER BY pi.id
  LOOP
    v_pct := COALESCE(v_linea.foto, v_linea.porcentaje_iva);
    SELECT d.neto, d.iva, d.ingreso_real INTO v_neto, v_iva, v_real
      FROM calcular_desglose_venta(v_linea.precio_unitario, v_pct, v_linea.pct_ii, v_tipo_nuevo) d;
    IF v_pct IS DISTINCT FROM v_linea.porcentaje_iva THEN
      UPDATE pedido_items
         SET neto_unitario = v_neto,
             iva_unitario = v_iva,
             porcentaje_iva = v_pct,
             ingreso_real_unitario = v_real
       WHERE id = v_linea.id;
      v_iva_foto := v_iva_foto + 1;
    END IF;
    v_acc_neto := v_acc_neto + v_linea.cantidad * v_neto;
    v_acc_iva  := v_acc_iva  + v_linea.cantidad * v_iva;
    v_acc_real := v_acc_real + v_linea.cantidad * v_real;
  END LOOP;
  IF v_iva_foto > 0 THEN
    UPDATE pedidos p
       SET total_neto = round(v_acc_neto, 2) + (public.cargo_envio_desglose(p.cargo_envio, v_tipo_nuevo)).neto,
           total_iva  = round(v_acc_iva, 2)  + (public.cargo_envio_desglose(p.cargo_envio, v_tipo_nuevo)).iva,
           total_real = round(v_acc_real, 2)
     WHERE p.id = v_nuevo_id AND p.sucursal_id = v_sucursal;
  END IF;

  IF p_destino_pagos = 'pedido_nuevo' THEN
    -- #1375: por id, como la foto de la rendicion. El UPDATE solo sigue el orden
    -- fisico, y un pago ya editado queda detras de los mas nuevos.
    PERFORM 1
       FROM pagos
      WHERE pedido_id = p_pedido_id
        AND sucursal_id = v_sucursal
      ORDER BY id
        FOR UPDATE;

    -- #1489: lo que X trajo del saldo a favor de su cliente (de_saldo_a_favor,
    -- #1469) y lo que entro por un FIFO de su ficha (a_cuenta, #1329; decision del
    -- duenio del 06/11) es plata del cliente original, no el cobro de esta venta:
    -- no viaja. Vuelve a ser credito suelto suyo, como lo deja la cancelacion con
    -- 'cliente_original' (el trigger le saca la marca). No se parte ningun pago.
    -- Ya estan tomados: los pagos de X, X y el cliente original van en el
    -- pre-bloqueo. 480 (COB-1): al final se aplica FIFO a sus boletas abiertas.
    WITH d AS (
      UPDATE pagos
         SET pedido_id = NULL,
             notas = TRIM(BOTH ' ' FROM COALESCE(notas, '') || ' [saldo a favor por cambio de cliente]')
       WHERE pedido_id = p_pedido_id
         AND sucursal_id = v_sucursal
         AND (de_saldo_a_favor OR a_cuenta)
      RETURNING monto
    )
    SELECT COALESCE(sum(monto), 0) INTO v_devuelto FROM d;

    -- #1492 (1): el pedido nuevo nacio absorbiendo el saldo a favor del cliente
    -- nuevo (463c). Si con el cobro de X pasa su total, lo absorbido vuelve a
    -- quedar suelto antes de que llegue el cobro: el cobro viaja entero y los
    -- creditos se vuelven a aplicar al final, FIFO. Sin esto,
    -- _pagos_excedente_a_favor (por fecha DESC) partia el cobro de X, y salia un
    -- excedente aunque el cobro entrara en el total nuevo. Son creditos del
    -- cliente nuevo (en el pre-bloqueo) o pedazos que nacieron en esta
    -- transaccion.
    IF COALESCE((SELECT sum(monto) FROM pagos
                  WHERE pedido_id IN (p_pedido_id, v_nuevo_id) AND sucursal_id = v_sucursal), 0)
       > (SELECT total FROM pedidos WHERE id = v_nuevo_id AND sucursal_id = v_sucursal) + 0.005 THEN
      UPDATE pagos
         SET pedido_id = NULL
       WHERE pedido_id = v_nuevo_id
         AND sucursal_id = v_sucursal
         AND de_saldo_a_favor;
      GET DIAGNOSTICS v_reaplicar = ROW_COUNT;
    END IF;

    UPDATE pagos
       SET pedido_id = v_nuevo_id,
           cliente_id = p_nuevo_cliente_id
     WHERE pedido_id = p_pedido_id
       AND sucursal_id = v_sucursal;

    -- #1248 (COB-3): si el total nuevo es menor, lo cobrado de mas pasa a saldo
    -- a favor del cliente nuevo y se aplica a sus otras boletas. Sin esto
    -- quedaba atrapado en la boleta: zzz_pedidos_reconciliar_pagos es OF total
    -- y aca solo cambia monto_pagado (trampa 6). #1492 (1): y lo que se solto de
    -- arriba se vuelve a aplicar.
    v_excedente := public._pagos_excedente_a_favor(v_nuevo_id);
    IF v_excedente > 0 OR v_reaplicar > 0 THEN
      PERFORM public.aplicar_credito_cliente(p_nuevo_cliente_id, v_sucursal);
    END IF;
  END IF;

  -- 480 (COB-1, decision del duenio del 10/11): el credito que le queda al
  -- cliente original (con 'cliente_original', el cobro de X que desimputo la
  -- cancelacion; con los dos destinos, lo que X trajo de su saldo a favor) se
  -- aplica FIFO a sus boletas abiertas, como el alta y el pago a cuenta. Sus
  -- boletas, sus rutas y sus creditos estan en el pre-bloqueo.
  IF EXISTS (SELECT 1 FROM pagos
              WHERE cliente_id = v_pedido.cliente_id
                AND sucursal_id = v_sucursal
                AND pedido_id IS NULL) THEN
    v_aplicado_viejo := COALESCE(public.aplicar_credito_cliente(v_pedido.cliente_id, v_sucursal), 0);
  END IF;

  UPDATE pedidos
     SET motivo_cancelacion = COALESCE(motivo_cancelacion, p_motivo) || ' -> pedido #' || v_nuevo_id
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
  VALUES (
    v_nuevo_id,
    v_acting,
    'cliente_id',
    v_pedido.cliente_id::text,
    p_nuevo_cliente_id::text || ' (cambio de cliente desde pedido #' || p_pedido_id || ')',
    v_sucursal
  );

  -- envio_historial_y_rol (#1231): la reatribucion conserva cargo y estado;
  -- si el pedido nuevo nacio con otros (p. ej. sin productos: cargo 0,
  -- 'gratis'), queda anotado en el nuevo, contra lo que tenia el viejo.
  SELECT cargo_envio, cargo_envio_estado INTO v_cargo_nuevo, v_estado_nuevo
    FROM pedidos WHERE id = v_nuevo_id AND sucursal_id = v_sucursal;
  IF COALESCE(v_pedido.cargo_envio, 0) IS DISTINCT FROM COALESCE(v_cargo_nuevo, 0) THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (v_nuevo_id, v_acting, 'cargo_envio', round(COALESCE(v_pedido.cargo_envio, 0), 2)::TEXT,
            round(COALESCE(v_cargo_nuevo, 0), 2)::TEXT, v_sucursal);
  END IF;
  IF v_pedido.cargo_envio_estado IS DISTINCT FROM v_estado_nuevo THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (v_nuevo_id, v_acting, 'cargo_envio_estado', v_pedido.cargo_envio_estado, v_estado_nuevo, v_sucursal);
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'nuevo_pedido_id', v_nuevo_id,
    'pedido_cancelado_id', p_pedido_id,
    'destino_pagos', p_destino_pagos,
    'excedente_a_favor', v_excedente,
    'a_favor_cliente_original', v_devuelto,
    'aplicado_cliente_original', v_aplicado_viejo
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 2 · validar_precio_item_pedido: el escape de VTA-05
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validar_precio_item_pedido()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_nombre       text;
  v_precio_lista numeric;
BEGIN
  -- Las bonificaciones de promoción van a $0 por diseño.
  IF COALESCE(NEW.es_bonificacion, false) THEN
    RETURN NEW;
  END IF;

  SELECT nombre, precio INTO v_nombre, v_precio_lista
  FROM productos WHERE id = NEW.producto_id;

  IF NEW.precio_unitario IS NULL OR NEW.precio_unitario <= 0 THEN
    RAISE EXCEPTION
      'El producto "%" no puede venderse a precio 0. Cargá el precio de venta antes de facturarlo.',
      COALESCE(v_nombre, NEW.producto_id::text)
      USING ERRCODE = 'check_violation';
  END IF;

  -- Solo en el alta: en UPDATE no se valida el precio de lista para no
  -- trabar la edición de pedidos históricos de un producto que hoy quedó sin precio.
  IF TG_OP = 'INSERT' AND (v_precio_lista IS NULL OR v_precio_lista <= 0)
     -- mig 3XA: un vale blanco va a costo, no a lista (N5).
     AND NOT EXISTS (SELECT 1 FROM pedidos WHERE id = NEW.pedido_id AND tipo_factura = 'VB')
     -- mig 480 (VTA-05): el cambio de cliente recrea las líneas que el pedido ya
     -- vendía (cambiar_cliente_pedido deja en app.cambio_cliente_desde el pedido
     -- original mientras crea el nuevo): no es una venta nueva.
     AND NOT EXISTS (SELECT 1 FROM pedido_items o
                      WHERE o.pedido_id = NULLIF(current_setting('app.cambio_cliente_desde', true), '')::bigint
                        AND o.sucursal_id = NEW.sucursal_id
                        AND o.producto_id = NEW.producto_id
                        AND NOT COALESCE(o.es_bonificacion, false)) THEN
    RAISE EXCEPTION
      'El producto "%" está pendiente de carga de precio de venta y no puede venderse.',
      COALESCE(v_nombre, NEW.producto_id::text)
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3 · El gate 3 de #1520: auditoria_pedidos_cliente_activo()
-- ---------------------------------------------------------------------------
-- Lo lee scripts/check-clientes-activo.mjs, que aplica la lista blanca
-- (scripts/clientes-activo-permitidas.json, nace vacía y sólo se achica). Toda función de public
-- que inserta en pedidos tiene que nombrar `clientes` y `activo` en una misma sentencia: un
-- cliente dado de baja no recibe pedidos (crear_pedido_completo, el bot y el canje en ruta ya lo
-- miran). Una que crea el pedido llamando a crear_pedido_completo hereda su control y no cuenta.
-- Lee texto, no ejecuta: saca los comentarios y vacía los literales ('…' → ''), así un mensaje
-- que diga "activo" no cuenta. Lo que no ve: SQL dinámico (EXECUTE) y un `;` dentro de un
-- literal $…$.
CREATE FUNCTION public.auditoria_pedidos_cliente_activo()
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_catalog'
AS $function$
  WITH t AS (
    SELECT p.oid::regprocedure::text AS firma,
           regexp_replace(regexp_replace(regexp_replace(p.prosrc,
             '/\*.*?\*/', ' ', 'g'),
             '--[^\n]*', ' ', 'g'),
             '''[^'']*''', '''''', 'g') AS src
      FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.prokind = 'f'
       AND p.prosrc ~* '\mpedidos\M'
  ), f AS (
    SELECT t.firma, t.src
      FROM t
     WHERE t.src ~* '\minsert\s+into\s+(public\.)?pedidos\s*\('
  ), miran AS (
    SELECT f.firma,
           EXISTS (SELECT 1
                     FROM regexp_split_to_table(f.src, ';') AS s(texto)
                    WHERE s.texto ~* '\mclientes\M'
                      AND s.texto ~* '\mactivo\M') AS mira
      FROM f
  )
  SELECT jsonb_build_object(
    'generado_at', now(),
    'funciones', (SELECT count(*) FROM miran),
    'sin_activo', COALESCE((SELECT jsonb_agg(firma ORDER BY firma) FROM miran WHERE NOT mira), '[]'::jsonb)
  );
$function$;

COMMENT ON FUNCTION public.auditoria_pedidos_cliente_activo() IS
  'Gate 3 de #1520 (scripts/check-clientes-activo.mjs): funciones de public que insertan en '
  'pedidos sin nombrar clientes y activo en una misma sentencia. Sólo de servidor.';

-- Sólo la corre el gate, con la service_role: las tres mitades.
REVOKE EXECUTE ON FUNCTION public.auditoria_pedidos_cliente_activo() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auditoria_pedidos_cliente_activo() TO service_role;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos son los del repo, los permisos no cambiaron y el gate nace en verde
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  v_md5 text;
  v_acl text;
  v_gate jsonb;
BEGIN
  SELECT md5(prosrc), proacl::text || '/' || prosecdef::text INTO v_md5, v_acl FROM pg_proc
   WHERE oid = 'public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)'::regprocedure;
  IF v_md5 IS DISTINCT FROM '0768802558d380da8f17fd0c0e6c173c'
     OR v_acl IS DISTINCT FROM '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}/true' THEN
    RAISE EXCEPTION 'mig 480 · cambiar_cliente_pedido no quedó como en el repo (md5 %, acl %)', v_md5, v_acl;
  END IF;

  SELECT md5(prosrc), proacl::text || '/' || prosecdef::text INTO v_md5, v_acl FROM pg_proc
   WHERE oid = 'public.validar_precio_item_pedido()'::regprocedure;
  IF v_md5 IS DISTINCT FROM '9b6899320148d9212729b2634d68f2fd'
     OR v_acl IS DISTINCT FROM '{postgres=X/postgres,service_role=X/postgres}/false' THEN
    RAISE EXCEPTION 'mig 480 · validar_precio_item_pedido no quedó como en el repo (md5 %, acl %)', v_md5, v_acl;
  END IF;

  IF has_function_privilege('anon', 'public.auditoria_pedidos_cliente_activo()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.auditoria_pedidos_cliente_activo()', 'EXECUTE') THEN
    RAISE EXCEPTION 'mig 480 · auditoria_pedidos_cliente_activo() quedó ejecutable desde la API';
  END IF;

  v_gate := public.auditoria_pedidos_cliente_activo();
  IF (v_gate->>'funciones')::int < 3 OR jsonb_array_length(v_gate->'sin_activo') > 0 THEN
    RAISE EXCEPTION 'mig 480 · el gate 3 no nace en verde: %', v_gate;
  END IF;
END
$post$;

COMMIT;
