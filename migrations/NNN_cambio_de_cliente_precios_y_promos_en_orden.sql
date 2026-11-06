-- NNN · El cambio de cliente, los precios en masa y el regalo de una promo toman sus filas en el
-- orden global, y el historial muestra el total antes que el estado de pago (#1473, tarjeta 6
-- de #1477).
--
-- QUÉ PASABA
--   · ADV-1 · cambiar_cliente_pedido (459) pre-bloqueaba las boletas, los recorridos y los pagos
--     (los de X y los créditos del cliente nuevo) antes que los productos, y los productos los
--     tomaba después cancelar_pedido_con_stock. La edición, la cancelación y la salvedad van
--     productos → rutas → créditos. Con un crédito K del cliente nuevo y una boleta Y suya que
--     comparte el producto P con X, la edición de Y toma P y después K, y el cambio de X toma K y
--     después P: 40P01.
--   · ADV-5 · El pedido nuevo (crear_pedido_completo) bloqueaba los productos y las promos de los
--     ítems nuevos que X no tenía con la promo de la cancelación ya tomada.
--   · VTA-F-4 (la parte del cambio de cliente) · crear_pedido_completo pone en cada línea el IVA
--     de hoy del producto. Una reatribución no es una venta nueva: la alícuota es la foto de la
--     línea de X (#1258), como en cambiar_tipo_factura_pedido y anular_salvedad (433).
--   · ADV-3 · actualizar_precios_masivo (460) pre-bloqueaba todo el lote fuera del EXCEPTION del
--     bucle: un 40P01 o un timeout tumbaba el lote entero. Decisión del dueño (05/11): el
--     producto trabado se saltea y al final se avisa cuáles no se cambiaron, como antes de la 460.
--   · ADV-2 · Un UPDATE REST de promociones que cambia producto_regalo_id o ajuste_producto_id
--     tiene la fila de la promo cuando la FK pide el producto nuevo (KEY SHARE). La venta toma ese
--     producto (FOR UPDATE, una línea suya) y después la promo: 40P01. Un trigger de sentencia
--     no ve los valores nuevos y uno de fila corre con la fila ya tomada, así que no hay trigger
--     que lo adelante.
--   · ADV-4 · Un UPDATE OF total de una boleta dispara trg_pedidos_reconciliar_pagos (457) antes
--     que trigger_registrar_cambio_pedido, y el estado de pago que cambia la reimputación entraba
--     a pedido_historial antes que el total que lo causó. Dentro del mismo UPDATE,
--     registrar_cambio_pedido también escribía el estado_pago antes que el total. Las filas
--     empatan en created_at.
--
-- QUÉ CAMBIA
--   · cambiar_cliente_pedido, antes de su lock de X, en el orden global: las boletas (X y las del
--     cliente nuevo que lo cobrado de X, si viaja, más sus créditos alcanzan a pagar en el orden
--     de aplicar_credito_cliente) por id → los productos de las líneas de X y de los ítems nuevos
--     con los contenedores de sus promos, por id → esas promos, por id → los recorridos de esas
--     boletas, por id → los pagos de X y los créditos del cliente nuevo, por id → los dos
--     clientes, por id. Se toma con los dos destinos de los pagos: el alta del pedido nuevo puede
--     tomar los créditos del cliente nuevo (#1469). Toma de más, nunca de menos.
--     Y después de crear el pedido nuevo, cada línea de venta toma la alícuota de la última línea
--     de venta del mismo producto en X; una foto 0 es ambigua (#1258) y deja la de hoy. Si alguna
--     cambió, el neto, el IVA y el ingreso real del pedido se recalculan como en
--     crear_pedido_completo. Con los productos de hoy (todos al 21) no cambia nada.
--   · actualizar_precios_masivo recorre el lote por id y toma cada producto dentro del
--     EXCEPTION de su vuelta, con un lock_timeout de hasta 1 s y 4 s en total para todo el lote.
--     El que no se pudo tomar (55P03 o 40P01) se saltea, y la respuesta lo nombra en `errores` y
--     en `trabados` ([{producto_id, nombre}]). Lo demás, igual.
--   · cambiar_regalo_promocion (nueva, RPC de admin): toma el producto de regalo y el contenedor
--     nuevos (KEY SHARE, el lock de la FK), después la promo, y recién ahí cambia las dos
--     columnas, con ajuste_automatico en el mismo UPDATE (la rotación de la barra mira el valor
--     nuevo). authenticated pierde el UPDATE REST de producto_regalo_id y ajuste_producto_id
--     (el resto de la tabla sigue igual) y el front los cambia por la RPC, antes del UPDATE REST
--     del resto: la barra rota y después se renormaliza con el factor nuevo, como en un solo
--     UPDATE.
--   · trigger_registrar_cambio_pedido pasa a llamarse trg_historial_cambio_pedido: corre antes
--     que trg_pedidos_reconciliar_pagos ('trg_h' < 'trg_p'). registrar_cambio_pedido escribe el
--     total antes que el estado_pago. El front desempata por id.
--
-- QUÉ NO CAMBIA
--   Qué se cancela, se crea, se imputa o se recorta en el cambio de cliente; los precios, los
--   mensajes de antes y la firma de actualizar_precios_masivo; las barras y lo que hacen los
--   triggers de promociones; qué registra el historial. crear_pedido_completo y
--   actualizar_pedido_items no se tocan (tarjetas 2 y 3).
--
-- Ensayo: scripts/test-locks-cambio-cliente-precios-promos-1473.sql (corre en prod sin dejar
-- rastro), y la clave t6 del arnés (scripts/concurrencia).
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
-- Premisas: los cuerpos vivos son los que se leyeron de prod (06/11)
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, md5(p.prosrc) AS md5_vivo
      FROM (VALUES
        ('public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)', '2e006a55197171eeb28934bf4992fad6'),
        ('public.actualizar_precios_masivo(jsonb)',                                                    '8fcdc176939f6ddc5ed665cf8fc290e9'),
        ('public.registrar_cambio_pedido()',                                                           '243cf9ad6eab034af81ee7f45ad4fd91')
      ) AS x(firma, md5)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION 'mig NNN · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;

  IF to_regproc('public.cambiar_regalo_promocion') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · cambiar_regalo_promocion ya existe';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgname = 'trigger_registrar_cambio_pedido'
                    AND tgrelid = 'public.pedidos'::regclass) THEN
    RAISE EXCEPTION 'mig NNN · trigger_registrar_cambio_pedido no está en pedidos';
  END IF;
  -- El UPDATE de promociones es de tabla: revocarlo no se lleva ningún grant por columna.
  IF NOT has_table_privilege('authenticated', 'public.promociones', 'UPDATE') THEN
    RAISE EXCEPTION 'mig NNN · authenticated ya no tiene el UPDATE de tabla sobre promociones';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- Parches por ancla sobre el cuerpo vivo
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _nnn_parche (firma text, orden int, ancla text, reemplazo text) ON COMMIT DROP;

INSERT INTO _nnn_parche (firma, orden, ancla, reemplazo) VALUES
-- cambiar_cliente_pedido 1: las variables nuevas.
('public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)', 1,
$a$  v_alcanza      BIGINT[];
BEGIN
$a$,
$r$  v_alcanza      BIGINT[];
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
BEGIN
$r$),

-- cambiar_cliente_pedido 2: la foto del IVA, justo después de crear el pedido nuevo.
('public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)', 3,
$a$  v_nuevo_id := (v_crear->>'pedido_id')::bigint;
  PERFORM set_config('app.combo_foto_pedido', '', true);
$a$,
$r$  v_nuevo_id := (v_crear->>'pedido_id')::bigint;
  PERFORM set_config('app.combo_foto_pedido', '', true);

  -- #1473 (VTA-F-4): la reatribucion no es una venta nueva. crear_pedido_completo
  -- pone en cada linea el IVA de hoy del producto; aca cada linea de venta toma la
  -- foto de la ultima linea de venta del mismo producto en X (#1258, como
  -- cambiar_tipo_factura_pedido). Una foto 0 es ambigua y deja la de hoy, y un item
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
               AND NOT COALESCE(o.es_bonificacion, false)
             ORDER BY o.id DESC
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
$r$),

-- registrar_cambio_pedido: el total antes que el estado de pago que causa.
('public.registrar_cambio_pedido()', 1,
$a$  IF OLD.estado_pago IS DISTINCT FROM NEW.estado_pago THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (NEW.id, usuario_actual, 'estado_pago',
            COALESCE(OLD.estado_pago, 'pendiente'),
            COALESCE(NEW.estado_pago, 'pendiente'),
            NEW.sucursal_id);
  END IF;

  IF OLD.total IS DISTINCT FROM NEW.total THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (NEW.id, usuario_actual, 'total',
            OLD.total::TEXT,
            NEW.total::TEXT,
            NEW.sucursal_id);
  END IF;
$a$,
$r$  -- #1473 (ADV-4): el total antes que el estado de pago, que es su consecuencia
  -- (trigger_actualizar_estado_pago lo recalcula en el mismo UPDATE). Las filas de
  -- una transaccion empatan en created_at y el front desempata por id.
  IF OLD.total IS DISTINCT FROM NEW.total THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (NEW.id, usuario_actual, 'total',
            OLD.total::TEXT,
            NEW.total::TEXT,
            NEW.sucursal_id);
  END IF;

  IF OLD.estado_pago IS DISTINCT FROM NEW.estado_pago THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (NEW.id, usuario_actual, 'estado_pago',
            COALESCE(OLD.estado_pago, 'pendiente'),
            COALESCE(NEW.estado_pago, 'pendiente'),
            NEW.sucursal_id);
  END IF;
$r$);

-- cambiar_cliente_pedido 2 (orden 2): el pre-bloqueo de la 459 se reemplaza entero, desde su
-- comentario hasta el lock de X (exclusive). Va por marcas y no por ancla literal: son 60
-- renglones, y la premisa de md5 ya garantiza el cuerpo.
INSERT INTO _nnn_parche (firma, orden, ancla, reemplazo) VALUES
('public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)', 2,
'MARCAS',
$r$  -- #1473 (ADV-1, ADV-5): el orden global antes del primer lock, con los dos
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
  --   - Los productos: los de las lineas de X (la cancelacion los devuelve), los de
  --     los items nuevos (los vende el pedido nuevo) y los contenedores de las
  --     promos de unos y otros (los mueven la barra y el motor).
  --   - Los pagos: los de X (viajan, o la cancelacion los desimputa) y los creditos
  --     del cliente nuevo.
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
                  WHERE pg.cliente_id = p_nuevo_cliente_id
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

$r$);

DO $parches$
DECLARE
  v_firma  text;
  v_p      record;
  v_def    text;
  v_n      int;
  v_desde  text := '  -- #1460: el orden global (pedidos, recorridos, pagos) antes del primer lock.' || E'\n';
  v_hasta  text := '  SELECT * INTO v_pedido FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal FOR UPDATE;' || E'\n';
  v_i      int;
  v_j      int;
BEGIN
  FOR v_firma IN SELECT DISTINCT firma FROM _nnn_parche ORDER BY firma LOOP
    v_def := pg_get_functiondef(v_firma::regprocedure);
    FOR v_p IN SELECT * FROM _nnn_parche WHERE firma = v_firma ORDER BY orden LOOP
      IF v_p.ancla = 'MARCAS' THEN
        IF (length(v_def) - length(replace(v_def, v_desde, ''))) / length(v_desde) <> 1
           OR (length(v_def) - length(replace(v_def, v_hasta, ''))) / length(v_hasta) <> 1 THEN
          RAISE EXCEPTION 'mig NNN · %: las marcas del pre-bloqueo de la 459 no aparecen una vez cada una', v_firma;
        END IF;
        v_i := position(v_desde in v_def);
        v_j := position(v_hasta in v_def);
        IF v_j <= v_i THEN
          RAISE EXCEPTION 'mig NNN · %: las marcas del pre-bloqueo están al revés', v_firma;
        END IF;
        v_def := substr(v_def, 1, v_i - 1) || v_p.reemplazo || substr(v_def, v_j);
      ELSE
        v_n := (length(v_def) - length(replace(v_def, v_p.ancla, ''))) / length(v_p.ancla);
        IF v_n <> 1 THEN
          RAISE EXCEPTION 'mig NNN · % parche %: el ancla aparece % vez/veces y se esperaba 1', v_firma, v_p.orden, v_n;
        END IF;
        v_def := replace(v_def, v_p.ancla, v_p.reemplazo);
      END IF;
    END LOOP;
    EXECUTE v_def;
  END LOOP;
END
$parches$;

-- ---------------------------------------------------------------------------
-- ADV-3 · actualizar_precios_masivo: el producto trabado se saltea y se avisa
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.actualizar_precios_masivo(p_productos jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_item JSONB;
  v_actualizados INT := 0;
  v_errores TEXT[] := '{}';
  v_producto_id INT;
  v_sucursal_id BIGINT;
  -- #1473 (ADV-3): los que no se pudieron tomar, y cuánto se esperó.
  v_trabados JSONB := '[]'::jsonb;
  v_nombre TEXT;
  v_inicio TIMESTAMPTZ := clock_timestamp();
  v_espera_ms INT;
  v_lock_timeout TEXT := current_setting('lock_timeout');
BEGIN
  -- SECURITY FIX: Solo admins pueden actualizar precios masivamente
  IF NOT es_admin() THEN
    RETURN jsonb_build_object(
      'success', false,
      'actualizados', 0,
      'errores', jsonb_build_array('No autorizado: Solo administradores pueden actualizar precios')
    );
  END IF;

  -- #1438: una definer no pasa por RLS. Como la policy mt_productos_update, sólo los
  -- productos de la sucursal activa. current_sucursal_id() da NULL si el header pide una
  -- sucursal que no es del usuario.
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'actualizados', 0,
      'errores', jsonb_build_array('No hay una sucursal activa: recargá la página e intentá de nuevo')
    );
  END IF;

  -- #1473 (ADV-3): cada producto se toma dentro del EXCEPTION de su vuelta, por id
  -- (el orden de la venta, la edición, la cancelación y la salvedad, #1460 C8). La
  -- 460 bloqueaba el lote entero antes del bucle: un 40P01 o un timeout tumbaba
  -- todo. Decisión del dueño (05/11): el que está trabado se saltea, y al final se
  -- avisa cuáles no se cambiaron. La espera es de hasta 1 s por producto y 4 s para
  -- todo el lote, por debajo del statement_timeout (8 s), que no se puede atajar:
  -- pasado eso, el que esté tomado se saltea en el acto. Un id que no es un número
  -- va al final y el bucle lo informa como siempre.
  FOR v_item IN
    SELECT t.e
      FROM jsonb_array_elements(p_productos) WITH ORDINALITY AS t(e, n)
     ORDER BY CASE WHEN btrim(t.e->>'producto_id') ~ '^[0-9]{1,18}$'
                   THEN btrim(t.e->>'producto_id')::numeric END NULLS LAST,
              t.n
  LOOP
    v_producto_id := NULL;
    BEGIN
      v_producto_id := (v_item->>'producto_id')::INT;

      v_espera_ms := GREATEST(1, LEAST(1000,
        4000 - (extract(epoch FROM clock_timestamp() - v_inicio) * 1000)::int));
      -- Es local a esta vuelta: si la vuelta cae, el EXCEPTION lo deshace con ella.
      PERFORM set_config('lock_timeout', v_espera_ms || 'ms', true);
      PERFORM 1 FROM productos
       WHERE id = v_producto_id AND sucursal_id = v_sucursal_id
         FOR NO KEY UPDATE;
      PERFORM set_config('lock_timeout', v_lock_timeout, true);

      UPDATE productos
      SET
        precio_sin_iva = COALESCE((v_item->>'precio_neto')::DECIMAL, precio_sin_iva),
        impuestos_internos = COALESCE((v_item->>'imp_internos')::DECIMAL, impuestos_internos),
        precio = COALESCE((v_item->>'precio_final')::DECIMAL, precio),
        updated_at = NOW()
      WHERE id = v_producto_id
        AND sucursal_id = v_sucursal_id;

      -- El de otra sucursal cuenta como el que no existe, con el mismo texto.
      IF FOUND THEN
        v_actualizados := v_actualizados + 1;
      ELSE
        v_errores := array_append(v_errores,
          'Producto ID ' || v_producto_id || ' no encontrado en la sucursal activa');
      END IF;
    EXCEPTION
      WHEN lock_not_available OR deadlock_detected THEN
        SELECT nombre INTO v_nombre
          FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal_id;
        v_trabados := v_trabados || jsonb_build_object('producto_id', v_producto_id, 'nombre', v_nombre);
        v_errores := array_append(v_errores,
          COALESCE(v_nombre, 'Producto') || ' (ID ' || v_producto_id
            || '): otra operación lo estaba usando y no se cambió');
      WHEN OTHERS THEN
        v_errores := array_append(v_errores,
          'Error en producto ID ' || COALESCE(v_producto_id::TEXT, 'desconocido') || ': ' || SQLERRM);
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'success', array_length(v_errores, 1) IS NULL,
    'actualizados', v_actualizados,
    'errores', COALESCE(to_jsonb(v_errores), '[]'::jsonb),
    'trabados', v_trabados
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- ADV-2 · El regalo y el contenedor de una promo cambian por RPC, no por REST
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.cambiar_regalo_promocion(
  p_promocion_id bigint,
  p_producto_regalo_id bigint,
  p_ajuste_producto_id bigint,
  p_ajuste_automatico boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_promo    RECORD;
BEGIN
  -- La policy mt_promociones_all: admin, y la promo de la sucursal activa.
  IF NOT es_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: sólo un administrador cambia el regalo de una promo');
  END IF;
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No hay una sucursal activa: recargá la página e intentá de nuevo');
  END IF;

  -- #1473 (ADV-2): los productos nuevos antes que la promo. Cambiar el regalo o el
  -- contenedor por REST tenía la fila de la promo cuando la FK pedía el producto
  -- nuevo (KEY SHARE); la venta toma ese producto (FOR UPDATE) y después la promo
  -- (455): 40P01. KEY SHARE es el lock de la FK, y alcanza: choca con el de la
  -- venta, así que se espera a la venta antes de tocar la promo. Los dos, de la
  -- sucursal activa.
  IF p_producto_regalo_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM productos WHERE id = p_producto_regalo_id AND sucursal_id = v_sucursal) THEN
    RETURN jsonb_build_object('success', false, 'error', 'El producto de regalo no existe en esta sucursal');
  END IF;
  IF p_ajuste_producto_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM productos WHERE id = p_ajuste_producto_id AND sucursal_id = v_sucursal) THEN
    RETURN jsonb_build_object('success', false, 'error', 'El producto contenedor no existe en esta sucursal');
  END IF;

  PERFORM 1
     FROM productos
    WHERE sucursal_id = v_sucursal
      AND id IN (p_producto_regalo_id, p_ajuste_producto_id)
    ORDER BY id
      FOR KEY SHARE;

  SELECT id, producto_regalo_id, ajuste_producto_id, ajuste_automatico INTO v_promo
    FROM promociones
   WHERE id = p_promocion_id AND sucursal_id = v_sucursal
     FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Promoción no encontrada');
  END IF;

  -- Igual que el UPDATE REST de antes: trg_promo_rotar_barra_default corre si cambia
  -- el regalo y mira el ajuste_automatico NUEVO, así que va en el mismo UPDATE
  -- (prender o apagar el ajuste junto con el regalo rota la barra como antes). El
  -- factor lo cambia después el UPDATE REST: renormalizar corría después de rotar.
  -- Sin cambios no se escribe nada.
  IF v_promo.producto_regalo_id IS DISTINCT FROM p_producto_regalo_id
     OR v_promo.ajuste_producto_id IS DISTINCT FROM p_ajuste_producto_id
     OR v_promo.ajuste_automatico IS DISTINCT FROM COALESCE(p_ajuste_automatico, false) THEN
    UPDATE promociones
       SET producto_regalo_id = p_producto_regalo_id,
           ajuste_producto_id = p_ajuste_producto_id,
           ajuste_automatico = COALESCE(p_ajuste_automatico, false)
     WHERE id = p_promocion_id AND sucursal_id = v_sucursal;
  END IF;

  RETURN jsonb_build_object('success', true, 'promocion_id', p_promocion_id,
    'cambio', v_promo.producto_regalo_id IS DISTINCT FROM p_producto_regalo_id
              OR v_promo.ajuste_producto_id IS DISTINCT FROM p_ajuste_producto_id
              OR v_promo.ajuste_automatico IS DISTINCT FROM COALESCE(p_ajuste_automatico, false));
END
$function$;

REVOKE EXECUTE ON FUNCTION public.cambiar_regalo_promocion(bigint, bigint, bigint, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cambiar_regalo_promocion(bigint, bigint, bigint, boolean) TO authenticated;

-- El UPDATE REST de promociones pasa de tabla a columnas, sin producto_regalo_id ni
-- ajuste_producto_id. El de tabla es el único que hay (la premisa lo mira): revocarlo
-- no se lleva un grant por columna que hubiera que conservar.
REVOKE UPDATE ON public.promociones FROM authenticated;
GRANT UPDATE (activo, ajuste_automatico, created_at, descripcion_regalo, fecha_fin, fecha_inicio,
              id, limite_usos, modo_exclusion, nombre, prioridad, regalo_mueve_stock,
              stock_por_bloque, sucursal_id, tipo, unidades_por_bloque, updated_at, usos_pendientes)
   ON public.promociones TO authenticated;

-- ---------------------------------------------------------------------------
-- ADV-4 · El historial corre antes que la reimputación
-- ---------------------------------------------------------------------------
-- Los AFTER de una fila corren en orden de nombre: 'trg_h' va antes que
-- 'trg_pedidos_reconciliar_pagos' (457), y el total entra a pedido_historial antes
-- que el estado de pago que cambia la reimputación. registrar_cambio_pedido sólo
-- inserta en pedido_historial: correr antes que las rutas, el saldo y la
-- reimputación no cambia ningún lock ni ningún número.
ALTER TRIGGER trigger_registrar_cambio_pedido ON public.pedidos RENAME TO trg_historial_cambio_pedido;

-- ---------------------------------------------------------------------------
-- Poscondiciones
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, x.acl, md5(p.prosrc) AS md5_vivo, p.proacl::text || '/' || p.prosecdef::text AS acl_viva
      FROM (VALUES
        ('public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)', '72242f3aaa5cca16667ac56d6d94fd74', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}/true'),
        ('public.actualizar_precios_masivo(jsonb)',                                                    'cdd3851d6e095307d84e6dc0a30e8119', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}/true'),
        ('public.registrar_cambio_pedido()',                                                           '5b6deb243016db84b767a2757746a0fa', '{postgres=X/postgres,service_role=X/postgres}/false'),
        ('public.cambiar_regalo_promocion(bigint,bigint,bigint,boolean)',                              '58aa734161804d91bed158b6095615d1', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}/true')
      ) AS x(firma, md5, acl)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF v_f.md5_vivo <> v_f.md5 OR v_f.acl_viva <> v_f.acl THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %)', v_f.firma, v_f.md5_vivo, v_f.acl_viva;
    END IF;
  END LOOP;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgname = 'trg_historial_cambio_pedido'
                    AND tgrelid = 'public.pedidos'::regclass AND tgenabled = 'O')
     OR EXISTS (SELECT 1 FROM pg_trigger
                 WHERE tgname = 'trigger_registrar_cambio_pedido'
                   AND tgrelid = 'public.pedidos'::regclass) THEN
    RAISE EXCEPTION 'mig NNN · el trigger del historial no quedó renombrado';
  END IF;

  IF has_column_privilege('authenticated', 'public.promociones', 'producto_regalo_id', 'UPDATE')
     OR has_column_privilege('authenticated', 'public.promociones', 'ajuste_producto_id', 'UPDATE')
     OR NOT has_column_privilege('authenticated', 'public.promociones', 'unidades_por_bloque', 'UPDATE')
     OR NOT has_column_privilege('authenticated', 'public.promociones', 'activo', 'UPDATE')
     OR has_table_privilege('anon', 'public.promociones', 'UPDATE') THEN
    RAISE EXCEPTION 'mig NNN · los grants de UPDATE de promociones no quedaron como se esperaba';
  END IF;
END
$post$;

COMMIT;
