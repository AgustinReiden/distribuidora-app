-- NNN · El cambio de cliente no se lleva al cliente nuevo la plata del cliente original (#1489,
-- tarjeta 12 de #1477).
--
-- QUÉ PASABA
--   Desde la 463c (#1469), una boleta nueva absorbe al crearse el saldo a favor de su cliente: el
--   pago que llega desde el crédito queda en la boleta con pagos.de_saldo_a_favor. Con
--   p_destino_pagos = 'pedido_nuevo', cambiar_cliente_pedido (467) mudaba TODOS los pagos de X al
--   pedido nuevo y al cliente nuevo. El crédito de C1 pasaba a pagar la boleta de C2: C1 perdía su
--   saldo a favor y C2 debía esa plata de menos. CC-A no lo ve, porque las cuentas cierran: la
--   plata queda en el cliente equivocado.
--   Lo mismo pasaba con un pago a cuenta del FIFO de la ficha de C1 (registrar_pago_cliente_fifo,
--   pagos.a_cuenta, #1329): el FIFO lo carga directo en la boleta impaga más vieja, que puede ser X.
--   Es plata que C1 pagó a cuenta de su deuda, no el cobro de esa venta.
--
-- QUÉ CAMBIA
--   · Con 'pedido_nuevo', antes de mudar los pagos de X, los que tienen de_saldo_a_favor o a_cuenta
--     vuelven a ser crédito suelto de C1 (pedido_id NULL, el cliente no cambia), como los deja la
--     cancelación con 'cliente_original': la misma nota, y el trigger de la 463c les saca la marca.
--     Viaja sólo el cobro de la boleta (los pagos sin ninguna de las dos marcas). No se parte ni se
--     crea ningún pago: un pedazo conserva su pago_origen_id y su pago_padre_id.
--   · La respuesta suma 'a_favor_cliente_original': cuánto le quedó a favor a C1 por esto.
--   · Los locks no cambian: los pagos de X ya están en el pre-bloqueo de la 467, y soltar un pago
--     de X toma X (recalcular_monto_pagado_pedido) y C1 (el saldo), que también están. El crédito
--     queda suelto, como con 'cliente_original': no se aplica a otras boletas de C1 acá.
--
-- QUÉ NO CAMBIA
--   'cliente_original' (la cancelación ya desimputa todo, y el reconcile no corre sobre un
--   cancelado), el cobro que viaja, el excedente del pedido nuevo, el pre-bloqueo y su orden, la
--   firma y los EXECUTE. crear_pedido_completo y la absorción del alta (463c) no se tocan: el
--   pedido nuevo absorbe el crédito suelto de C2, que es lo que corresponde, y el de C1 ya no
--   viaja por ningún camino.
--
-- Ensayo: scripts/test-cambio-cliente-saldo-a-favor-1489.sql (corre en prod sin dejar rastro), y
-- las claves t6, t15 y a2 (A2h, A2i) del arnés (scripts/concurrencia).
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
    RAISE EXCEPTION 'mig NNN · cambiar_cliente_pedido cambió en prod desde que se leyó (md5 %, esperado 72242f3a…): rehacer sobre la definición vigente', v_md5;
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- Parches por ancla sobre el cuerpo vivo
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _nnn_parche (orden int, ancla text, reemplazo text) ON COMMIT DROP;

INSERT INTO _nnn_parche (orden, ancla, reemplazo) VALUES
-- 1 · la variable nueva.
(1,
$a$  v_iva_foto     INT := 0;
$a$,
$r$  v_iva_foto     INT := 0;
  -- #1489: lo que le quedó a favor al cliente original con 'pedido_nuevo'.
  v_devuelto     NUMERIC := 0;
$r$),
-- 2 · con 'pedido_nuevo', la plata del cliente original no viaja.
(2,
$a$    UPDATE pagos
       SET pedido_id = v_nuevo_id,
           cliente_id = p_nuevo_cliente_id
     WHERE pedido_id = p_pedido_id
       AND sucursal_id = v_sucursal;
$a$,
$r$    -- #1489: lo que X trajo del saldo a favor de su cliente (de_saldo_a_favor,
    -- #1469) y lo que entro por un FIFO de su ficha (a_cuenta, #1329) es plata del
    -- cliente original, no el cobro de esta venta: no viaja. Vuelve a ser credito
    -- suelto suyo, como lo deja la cancelacion con 'cliente_original' (el trigger
    -- le saca la marca). No se parte ningun pago. Ya estan tomados: los pagos de X,
    -- X y el cliente original van en el pre-bloqueo.
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

    UPDATE pagos
       SET pedido_id = v_nuevo_id,
           cliente_id = p_nuevo_cliente_id
     WHERE pedido_id = p_pedido_id
       AND sucursal_id = v_sucursal;
$r$),
-- 3 · la respuesta lo cuenta.
(3,
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
      RAISE EXCEPTION 'mig NNN · parche %: el ancla aparece % vez/veces y se esperaba 1', v_p.orden, v_n;
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
  IF v_md5 IS DISTINCT FROM '0d994db36fbb986e7e4da03f03812bed'
     OR v_acl IS DISTINCT FROM '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}/true' THEN
    RAISE EXCEPTION 'mig NNN · cambiar_cliente_pedido no quedó como en el repo (md5 %, acl %)', v_md5, v_acl;
  END IF;
END
$post$;

COMMIT;
