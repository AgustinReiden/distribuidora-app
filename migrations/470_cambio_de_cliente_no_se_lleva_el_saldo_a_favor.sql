-- 470 · El cambio de cliente no se lleva al cliente nuevo la plata del cliente original, el cobro de X
-- viaja entero y la foto del IVA sigue la regla de la edición (#1489, y los puntos 1 y 5 de #1492;
-- tarjeta 12 de #1477).
--
-- QUÉ PASABA
--   · #1489 · Desde la 463c (#1469), una boleta nueva absorbe al crearse el saldo a favor de su
--     cliente: el pago que llega desde el crédito queda en la boleta con pagos.de_saldo_a_favor. Con
--     p_destino_pagos = 'pedido_nuevo', cambiar_cliente_pedido (467) mudaba TODOS los pagos de X al
--     pedido nuevo y al cliente nuevo. El crédito de C1 pasaba a pagar la boleta de C2: C1 perdía su
--     saldo a favor y C2 debía esa plata de menos. CC-A no lo ve, porque las cuentas cierran: la
--     plata queda en el cliente equivocado. Lo mismo pasaba con un pago a cuenta del FIFO de la ficha
--     de C1 (registrar_pago_cliente_fifo, pagos.a_cuenta, #1329), que el FIFO carga directo en la
--     boleta impaga más vieja, que puede ser X.
--   · #1492 (1) · Con un crédito K de C2, el pedido nuevo N nace absorbiéndolo (463c). Después llegaba
--     el cobro de X y _pagos_excedente_a_favor(N), que recorta por fecha DESC, partía el cobro de hoy
--     de X: salía un excedente aunque el cobro entrara en el total nuevo, y quedaba imputado K en su
--     lugar. Y si K era de una nota de crédito, N ya no podía volver a cambiar con 'pedido_nuevo'.
--   · #1492 (5) · La foto del IVA de una línea tenía dos reglas: actualizar_pedido_items (464) toma
--     la línea más vieja por producto + combo, y cambiar_cliente_pedido (467) la más nueva por
--     producto, sin combo.
--
-- QUÉ CAMBIA (todo en cambiar_cliente_pedido)
--   · Con 'pedido_nuevo', antes de mudar los pagos de X, los que tienen de_saldo_a_favor o a_cuenta
--     vuelven a ser crédito suelto de C1 (pedido_id NULL, el cliente no cambia), como los deja la
--     cancelación con 'cliente_original': la misma nota, y el trigger de la 463c les saca la marca.
--     Viaja sólo el cobro de la boleta, el que no tiene ninguna de las dos marcas. Decisión del dueño
--     (06/11): el pago a cuenta del FIFO se queda con C1, igual que lo absorbido. No se parte ni se
--     crea ningún pago: un pedazo conserva su pago_origen_id y su pago_padre_id. La respuesta suma
--     'a_favor_cliente_original': cuánto le quedó a favor a C1 por esto.
--   · La guarda de la nota de crédito frena sólo el crédito de NC que se imputó directo a X (sin
--     marca): el que X absorbió del saldo a favor vuelve suelto a su cliente, que es el de la NC.
--   · Si el cobro de X más lo que N absorbió de C2 pasa el total de N, lo absorbido vuelve a quedar
--     suelto antes de que llegue el cobro; el cobro viaja entero y aplicar_credito_cliente vuelve a
--     aplicar los créditos de C2 (FIFO) al final. 'excedente_a_favor' queda en lo que el cobro de X
--     pasa el total nuevo. Si no lo pasa, nada cambia.
--   · La foto del IVA de cada línea de venta del pedido nuevo es la de la línea de venta más vieja de
--     X con el mismo producto y el mismo combo, como en actualizar_pedido_items (464). Una foto 0
--     sigue siendo ambigua y deja la de hoy.
--   · Los locks no cambian. Los pagos de X, X y C1 ya están en el pre-bloqueo de la 467. N lo creó
--     esta transacción, sus pagos son créditos de C2 (en el pre-bloqueo) o pedazos nuevos, y
--     aplicar_credito_cliente(C2) ya corría con el excedente: toma lo mismo.
--     El crédito de C1 queda suelto, como con 'cliente_original': no se aplica acá a otras boletas
--     de C1.
--
-- QUÉ NO CAMBIA
--   'cliente_original' (la cancelación ya desimputa todo y el reconcile no corre sobre un cancelado),
--   el pre-bloqueo y su orden, la firma y los EXECUTE. crear_pedido_completo, la absorción del alta
--   (463c) y _pagos_excedente_a_favor no se tocan.
--
-- Ensayo: scripts/test-cambio-cliente-saldo-a-favor-1489.sql (corre en prod sin dejar rastro), y
-- las claves t6, t15 y a2 del arnés (scripts/concurrencia), con A2j y A2k nuevas.
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
-- Premisa: el cuerpo vivo es el que dejó la 467 (06/11)
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_md5 text;
BEGIN
  SELECT md5(prosrc) INTO v_md5 FROM pg_proc
   WHERE oid = 'public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)'::regprocedure;
  IF v_md5 IS DISTINCT FROM '72242f3aaa5cca16667ac56d6d94fd74' THEN
    RAISE EXCEPTION 'mig 470 · cambiar_cliente_pedido cambió en prod desde que se leyó (md5 %, esperado 72242f3a…): rehacer sobre la definición vigente', v_md5;
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- Parches por ancla sobre el cuerpo vivo
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _nnn_parche (orden int, ancla text, reemplazo text) ON COMMIT DROP;

INSERT INTO _nnn_parche (orden, ancla, reemplazo) VALUES
-- 1 · las variables nuevas.
(1,
$a$  v_iva_foto     INT := 0;
$a$,
$r$  v_iva_foto     INT := 0;
  -- #1489: lo que le quedo a favor al cliente original con 'pedido_nuevo'.
  v_devuelto     NUMERIC := 0;
  -- #1492 (1): los creditos del cliente nuevo que el pedido nuevo absorbio y
  -- vuelven a quedar sueltos hasta que llegue el cobro de X.
  v_reaplicar    INT := 0;
$r$),
-- 2 · la guarda de la NC frena sólo el crédito imputado directo a X.
(2,
$a$  -- Un credito de NC es del cliente de la NC: no viaja. Con 'cliente_original'
  -- no viaja nada, y el credito vuelve a saldo a favor de su cliente.
  IF p_destino_pagos = 'pedido_nuevo'
     AND EXISTS (SELECT 1 FROM pagos WHERE pedido_id = p_pedido_id AND nota_credito_id IS NOT NULL) THEN
$a$,
$r$  -- Un credito de NC es del cliente de la NC: no viaja. Con 'cliente_original'
  -- no viaja nada, y el credito vuelve a saldo a favor de su cliente.
  -- #1489: el que X absorbio del saldo a favor (de_saldo_a_favor o a_cuenta)
  -- vuelve suelto a su cliente, que es el de la NC: frena solo el que se imputo
  -- directo a X.
  IF p_destino_pagos = 'pedido_nuevo'
     AND EXISTS (SELECT 1 FROM pagos WHERE pedido_id = p_pedido_id AND nota_credito_id IS NOT NULL
                   AND NOT (de_saldo_a_favor OR a_cuenta)) THEN
$r$),
(3,
$a$      || (SELECT min(nota_credito_id) FROM pagos WHERE pedido_id = p_pedido_id AND nota_credito_id IS NOT NULL)
$a$,
$r$      || (SELECT min(nota_credito_id) FROM pagos WHERE pedido_id = p_pedido_id AND nota_credito_id IS NOT NULL
             AND NOT (de_saldo_a_favor OR a_cuenta))
$r$),
-- 4 · la foto del IVA, con la regla de actualizar_pedido_items (464).
(4,
$a$  -- pone en cada linea el IVA de hoy del producto; aca cada linea de venta toma la
  -- foto de la ultima linea de venta del mismo producto en X (#1258, como
  -- cambiar_tipo_factura_pedido). Una foto 0 es ambigua y deja la de hoy, y un item
$a$,
$r$  -- pone en cada linea el IVA de hoy del producto; aca cada linea de venta toma la
  -- foto de la linea de venta mas vieja de X con el mismo producto y el mismo
  -- combo, la regla de actualizar_pedido_items (464, #1492): la linea del combo y
  -- la suelta son dos lineas (#1191). Una foto 0 es ambigua y deja la de hoy, y un item
$r$),
(5,
$a$               AND o.producto_id = pi.producto_id
               AND NOT COALESCE(o.es_bonificacion, false)
             ORDER BY o.id DESC
             LIMIT 1) AS foto,
$a$,
$r$               AND o.producto_id = pi.producto_id
               AND o.combo_id IS NOT DISTINCT FROM pi.combo_id
               AND NOT COALESCE(o.es_bonificacion, false)
             ORDER BY o.id
             LIMIT 1) AS foto,
$r$),
-- 6 · con 'pedido_nuevo', la plata del cliente original no viaja y el cobro de X viaja entero.
(6,
$a$    UPDATE pagos
       SET pedido_id = v_nuevo_id,
           cliente_id = p_nuevo_cliente_id
     WHERE pedido_id = p_pedido_id
       AND sucursal_id = v_sucursal;

    -- #1248 (COB-3): si el total nuevo es menor, lo cobrado de mas pasa a saldo
    -- a favor del cliente nuevo y se aplica a sus otras boletas. Sin esto
    -- quedaba atrapado en la boleta: zzz_pedidos_reconciliar_pagos es OF total
    -- y aca solo cambia monto_pagado (trampa 6).
    v_excedente := public._pagos_excedente_a_favor(v_nuevo_id);
    IF v_excedente > 0 THEN
      PERFORM public.aplicar_credito_cliente(p_nuevo_cliente_id, v_sucursal);
    END IF;
$a$,
$r$    -- #1489: lo que X trajo del saldo a favor de su cliente (de_saldo_a_favor,
    -- #1469) y lo que entro por un FIFO de su ficha (a_cuenta, #1329; decision del
    -- duenio del 06/11) es plata del cliente original, no el cobro de esta venta:
    -- no viaja. Vuelve a ser credito suelto suyo, como lo deja la cancelacion con
    -- 'cliente_original' (el trigger le saca la marca). No se parte ningun pago.
    -- Ya estan tomados: los pagos de X, X y el cliente original van en el
    -- pre-bloqueo.
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
$r$),
-- 7 · la respuesta lo cuenta.
(7,
$a$    'excedente_a_favor', v_excedente
$a$,
$r$    'excedente_a_favor', v_excedente,
    'a_favor_cliente_original', v_devuelto
$r$);

DO $parches$
DECLARE
  v_p   record;
  v_def text;
  v_n   int;
BEGIN
  v_def := pg_get_functiondef('public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)'::regprocedure);
  FOR v_p IN SELECT * FROM _nnn_parche ORDER BY orden LOOP
    v_n := (length(v_def) - length(replace(v_def, v_p.ancla, ''))) / length(v_p.ancla);
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'mig 470 · parche %: el ancla aparece % vez/veces y se esperaba 1', v_p.orden, v_n;
    END IF;
    v_def := replace(v_def, v_p.ancla, v_p.reemplazo);
  END LOOP;
  EXECUTE v_def;
END
$parches$;

-- ---------------------------------------------------------------------------
-- Poscondición: el cuerpo es el del repo y los permisos no cambiaron
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  v_md5 text;
  v_acl text;
BEGIN
  SELECT md5(prosrc), proacl::text || '/' || prosecdef::text INTO v_md5, v_acl FROM pg_proc
   WHERE oid = 'public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)'::regprocedure;
  IF v_md5 IS DISTINCT FROM '302a5dbb5b68b80c58d25b2457b0f7d2'
     OR v_acl IS DISTINCT FROM '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}/true' THEN
    RAISE EXCEPTION 'mig 470 · cambiar_cliente_pedido no quedó como en el repo (md5 %, acl %)', v_md5, v_acl;
  END IF;
END
$post$;

COMMIT;
