-- 463 · La boleta nueva absorbe el saldo a favor del cliente, y el alta sin líneas de venta se rechaza (#1469).
--
-- QUÉ PASABA
--   · COB-F-4. Un crédito suelto (pagos.pedido_id NULL) se aplica con aplicar_credito_cliente, que
--     llaman pedidos_reconciliar_pagos (AFTER UPDATE OF total), los FIFO, los masivos y las notas de
--     crédito. Una boleta nace con su total en el INSERT, sin un UPDATE del total: el crédito quedaba
--     suelto mientras el cliente debía la boleta nueva. saldo_cuenta lo netea (CC-A no lo ve), pero
--     la boleta figuraba impaga por el total y el cobrador cobraba de más. En prod: el pago 8047
--     (cliente 464, $400 del 29/10) con las boletas 12409 y 12477 entregadas e impagas.
--   · VTA-F-2. crear_pedido_completo y el bot aceptaban un pedido sin líneas o sólo con regalos
--     cuando la política de la sucursal no tiene mínimo. La edición lo rechaza desde #1078.
--
-- QUÉ CAMBIA
--   Decisión del dueño (05/11): la boleta nueva absorbe el saldo a favor al crearse, FIFO como el
--   resto (primero la boleta impaga más vieja, la misma aplicar_credito_cliente), se muestra cuánto
--   se aplicó, y la migración aplica los créditos sueltos que hoy tienen una boleta impaga.
--   · crear_pedido_completo (y por él crear_pedido_idempotente y cambiar_cliente_pedido) y
--     crear_pedido_completo_bot, salvo el vale blanco (nace saldado):
--       - rechazan el pedido sin al menos una línea que no sea regalo con cantidad > 0, con el
--         texto de la edición;
--       - si el cliente tiene créditos sueltos, los toman en el orden global, antes que el cliente
--         (que lo toma el INSERT del pedido, por trigger_actualizar_saldo_pedido):
--           las boletas que los créditos alcanzan (por id, _alta_bloquea_boletas_credito)
--           → productos y contenedores → promos (lo de la 455)
--           → los recorridos de esas boletas y los créditos (por id, _alta_bloquea_creditos)
--           → el cliente.
--         Las boletas van antes que los productos, como en la edición (_edicion_bloquea_boletas,
--         457); los créditos después de productos y promos y antes que el cliente.
--       - al final aplican el crédito (_alta_aplicar_saldo_a_favor → aplicar_credito_cliente) y
--         devuelven saldo_a_favor_aplicado (lo que cayó en esta boleta) y saldo_a_favor_otras (lo
--         que fue a boletas más viejas).
--   · pagos.de_saldo_a_favor (nueva): true en un pago de una boleta que llegó desde un crédito. La
--     pone un trigger (trg_pagos_marcar_saldo_a_favor) cuando un pago pasa de suelto a una boleta, o
--     cuando nace un pedazo de un crédito o de otra boleta; vuelve a false si el pago queda suelto.
--     Cubre a todo camino que aplique o impute créditos sin tocarlo. Es lo que muestra el front
--     ("Saldo a favor aplicado: $X"). Hacia adelante: los pagos de antes quedan en false.
--   · Los créditos sueltos de hoy que tienen una boleta impaga del mismo cliente y sucursal se
--     aplican (aplicar_credito_cliente). Medido el 06/11: uno, el 8047 (464, $400 → 12409). El 5571
--     (cliente 707, $30) no tiene boleta impaga y queda suelto hasta la próxima.
--
-- QUÉ NO CAMBIA
--   A qué boleta va el crédito (FIFO, aplicar_credito_cliente no se toca), las firmas, los EXECUTE,
--   ni ningún total. El saldo de los clientes no se mueve (saldo_cuenta ya neteaba el crédito).
--   crear_pedido_idempotente no se toca: el alta pasa por crear_pedido_completo.
--   cambiar_cliente_pedido (tarjeta 6 de #1477) toma los créditos del cliente nuevo antes que los
--   productos: con esta migración su crear_pedido_completo los vuelve a pedir después. Ver el
--   arnés (scripts/concurrencia, clave a2) y #1473.
--
-- Ensayo: scripts/test-saldo-a-favor-alta-1469.sql (corre en prod sin dejar rastro).
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
        ('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)',
         'b39d6d60ed41b9d407e1e2a4a4f28a17'),
        ('public.crear_pedido_completo_bot(uuid,uuid)', '7677969a6ab3d2e3f50cb3c54a3a0445'),
        ('public.aplicar_credito_cliente(bigint,bigint)', 'c56c4200f0ca10c4920629e8e552f21f')
      ) AS x(firma, md5)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION 'mig 463 · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public' AND table_name = 'pagos' AND column_name = 'de_saldo_a_favor') THEN
    RAISE EXCEPTION 'mig 463 · pagos.de_saldo_a_favor ya existe';
  END IF;
  IF to_regproc('public._alta_bloquea_boletas_credito') IS NOT NULL
     OR to_regproc('public._alta_bloquea_creditos') IS NOT NULL
     OR to_regproc('public._alta_aplicar_saldo_a_favor') IS NOT NULL
     OR to_regproc('public.pagos_marcar_saldo_a_favor') IS NOT NULL THEN
    RAISE EXCEPTION 'mig 463 · alguna de las funciones nuevas ya existe';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- La marca del pago que llegó a una boleta desde un crédito
-- ---------------------------------------------------------------------------
ALTER TABLE public.pagos ADD COLUMN de_saldo_a_favor boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.pagos.de_saldo_a_favor IS
  'true: este pago de una boleta llegó desde un crédito (saldo a favor) o desde otra boleta. La pone trg_pagos_marcar_saldo_a_favor; nadie la escribe a mano. Desde la mig 463 (#1469); los pagos anteriores quedan en false.';

CREATE FUNCTION public.pagos_marcar_saldo_a_favor()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_padre record;
BEGIN
  -- #1469: la marca la decide el server, nunca quien escribe la fila. Un pago suelto es un
  -- crédito, no un pago de una boleta. Un pago que pasa de suelto a una boleta es saldo a
  -- favor que se aplicó (aplicar_credito_cliente, imputar_credito_a_pedido). Uno que se mueve
  -- de boleta (cambiar_cliente_pedido) conserva lo que era. Un pedazo nuevo es saldo a favor
  -- si sale de un crédito o de otra boleta, y si sale de la misma, hereda la marca.
  IF NEW.pedido_id IS NULL THEN
    NEW.de_saldo_a_favor := false;
  ELSIF TG_OP = 'UPDATE' THEN
    NEW.de_saldo_a_favor := CASE WHEN OLD.pedido_id IS NULL THEN true ELSE OLD.de_saldo_a_favor END;
  ELSE
    NEW.de_saldo_a_favor := false;
    IF NEW.pago_padre_id IS NOT NULL THEN
      SELECT pedido_id, de_saldo_a_favor INTO v_padre FROM pagos WHERE id = NEW.pago_padre_id;
      IF FOUND THEN
        NEW.de_saldo_a_favor := v_padre.pedido_id IS DISTINCT FROM NEW.pedido_id OR v_padre.de_saldo_a_favor;
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

-- Una función de trigger no necesita EXECUTE para nadie (CLAUDE.md, #1245).
REVOKE EXECUTE ON FUNCTION public.pagos_marcar_saldo_a_favor() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_pagos_marcar_saldo_a_favor
  BEFORE INSERT OR UPDATE OF pedido_id, de_saldo_a_favor ON public.pagos
  FOR EACH ROW EXECUTE FUNCTION public.pagos_marcar_saldo_a_favor();

-- ---------------------------------------------------------------------------
-- Los helpers del alta (de server: los llaman crear_pedido_completo y el bot)
-- ---------------------------------------------------------------------------
-- Fase 1, antes de los productos: las boletas impagas del cliente que sus créditos alcanzan a
-- pagar en el orden de aplicar_credito_cliente (fecha, id), por id. NULL si no tiene créditos
-- sueltos: el alta no toma nada más, como antes. La boleta que se va a crear todavía no existe:
-- si entra antes en la cola (una fecha vieja), el crédito llega a menos boletas, nunca a más.
-- Con app.reimputacion_pagos prendido (una reimputación en curso) tampoco: la misma defensa de
-- pedidos_reconciliar_pagos.
CREATE FUNCTION public._alta_bloquea_boletas_credito(p_cliente_id bigint, p_sucursal_id bigint)
RETURNS bigint[]
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_credito numeric;
  v_alcanza bigint[];
BEGIN
  IF current_setting('app.reimputacion_pagos', true) = 'on' THEN
    RETURN NULL;
  END IF;

  SELECT sum(monto) INTO v_credito
    FROM pagos
   WHERE cliente_id = p_cliente_id
     AND sucursal_id = p_sucursal_id
     AND pedido_id IS NULL;
  IF COALESCE(v_credito, 0) <= 0.005 THEN
    RETURN NULL;
  END IF;

  v_alcanza := ARRAY(
    SELECT b.id
      FROM (SELECT p.id,
                   sum(p.total - COALESCE(p.monto_pagado, 0)) OVER (ORDER BY p.fecha, p.id)
                     - (p.total - COALESCE(p.monto_pagado, 0)) AS antes
              FROM pedidos p
             WHERE p.cliente_id = p_cliente_id
               AND p.sucursal_id = p_sucursal_id
               AND p.estado NOT IN ('cancelado', 'anulado')
               AND p.total > COALESCE(p.monto_pagado, 0)) b
     WHERE b.antes < v_credito);

  PERFORM 1
     FROM pedidos
    WHERE id = ANY(v_alcanza)
    ORDER BY id
      FOR UPDATE;

  RETURN v_alcanza;
END;
$function$;

-- Fase 2, después de productos y promos y antes que el cliente: los recorridos de esas boletas y
-- los créditos, por id (el pre-bloqueo de aplicar_credito_cliente, que después los vuelve a pedir).
CREATE FUNCTION public._alta_bloquea_creditos(p_cliente_id bigint, p_sucursal_id bigint, p_boletas bigint[])
RETURNS void
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM 1
     FROM recorridos
    WHERE id IN (SELECT rp.recorrido_id
                   FROM recorrido_pedidos rp
                  WHERE rp.pedido_id = ANY(p_boletas))
    ORDER BY id
      FOR NO KEY UPDATE;

  PERFORM 1
     FROM pagos
    WHERE cliente_id = p_cliente_id
      AND sucursal_id = p_sucursal_id
      AND pedido_id IS NULL
    ORDER BY id
      FOR UPDATE;
END;
$function$;

-- Al final del alta: aplica los créditos FIFO y dice cuánto cayó en la boleta nueva y cuánto en
-- las más viejas. La boleta nueva todavía no tiene cobros: su monto_pagado es lo que le cayó.
CREATE FUNCTION public._alta_aplicar_saldo_a_favor(p_pedido_id bigint, p_cliente_id bigint, p_sucursal_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_total numeric;
  v_aqui  numeric;
BEGIN
  v_total := COALESCE(public.aplicar_credito_cliente(p_cliente_id, p_sucursal_id), 0);
  SELECT COALESCE(monto_pagado, 0) INTO v_aqui FROM pedidos WHERE id = p_pedido_id;
  RETURN jsonb_build_object('saldo_a_favor_aplicado', round(v_aqui, 2),
                            'saldo_a_favor_otras', round(GREATEST(v_total - v_aqui, 0), 2));
END;
$function$;

-- Sólo de server: los llaman las dos RPCs del alta, que son SECURITY DEFINER.
REVOKE EXECUTE ON FUNCTION public._alta_bloquea_boletas_credito(bigint, bigint) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._alta_bloquea_creditos(bigint, bigint, bigint[]) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._alta_aplicar_saldo_a_favor(bigint, bigint, bigint) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Parches por ancla sobre el cuerpo vivo
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _n_parche (firma text, orden int, ancla text, reemplazo text, veces int DEFAULT 1) ON COMMIT DROP;

INSERT INTO _n_parche (firma, orden, ancla, reemplazo) VALUES
-- crear_pedido_completo · las variables.
('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)', 1,
$a$  v_reparto_alta RECORD;
BEGIN
$a$,
$r$  v_reparto_alta RECORD;
  -- #1469: las boletas que alcanzan los créditos sueltos del cliente (NULL: no tiene) y lo
  -- que la boleta absorbió.
  v_credito_boletas BIGINT[];
  v_saldo_favor JSONB := '{}'::JSONB;
BEGIN
$r$),

-- crear_pedido_completo · VTA-F-2, antes de toda escritura.
('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)', 2,
$a$  -- mig #1123: el regalo de quien no es admin. Producto: el default vigente de
$a$,
$r$  -- #1469 (VTA-F-2): un pedido tiene al menos un renglón que se cobra (no regalo, cantidad
  -- > 0), como la edición desde #1078. Sin mínimo en la política de la sucursal, el alta
  -- aceptaba la lista vacía o sólo regalos.
  IF NOT EXISTS (
       SELECT 1
         FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_items) = 'array'
                                        THEN p_items ELSE '[]'::jsonb END) e
        WHERE NOT COALESCE((e->>'es_bonificacion')::BOOLEAN, false)
          AND COALESCE((e->>'cantidad')::NUMERIC, 0) > 0) THEN
    RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
      'El pedido tiene que tener al menos un producto que no sea regalo. El pedido no se creó.'));
  END IF;

  -- mig #1123: el regalo de quien no es admin. Producto: el default vigente de
$r$),

-- crear_pedido_completo · fase 1 del crédito: sus boletas antes que los productos.
('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)', 3,
$a$  PERFORM 1 FROM productos
   WHERE sucursal_id = v_sucursal
     AND id IN (SELECT (key)::BIGINT FROM jsonb_each_text(v_cantidades_totales)
$a$,
$r$  -- #1469: si el cliente tiene créditos sueltos, la boleta nueva los absorbe al final
  -- (aplicar_credito_cliente). Las boletas que esos créditos alcanzan van antes que los
  -- productos, como en la edición (_edicion_bloquea_boletas, 457); los recorridos y los
  -- créditos, después de las promos; el cliente lo toma el INSERT del pedido. Un vale blanco
  -- nace saldado y no toma nada.
  IF v_tipo_factura <> 'VB' THEN
    v_credito_boletas := public._alta_bloquea_boletas_credito(p_cliente_id, v_sucursal);
  END IF;

  PERFORM 1 FROM productos
   WHERE sucursal_id = v_sucursal
     AND id IN (SELECT (key)::BIGINT FROM jsonb_each_text(v_cantidades_totales)
$r$),

-- crear_pedido_completo · fase 2 del crédito: recorridos y créditos, después de las promos.
('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)', 4,
$a$  PERFORM 1 FROM promociones
   WHERE sucursal_id = v_sucursal AND id = ANY (v_promos_regalo)
   ORDER BY id
     FOR UPDATE;
$a$,
$r$  PERFORM 1 FROM promociones
   WHERE sucursal_id = v_sucursal AND id = ANY (v_promos_regalo)
   ORDER BY id
     FOR UPDATE;
  IF v_credito_boletas IS NOT NULL THEN
    PERFORM public._alta_bloquea_creditos(p_cliente_id, v_sucursal, v_credito_boletas);
  END IF;
$r$),

-- crear_pedido_completo · aplicar el crédito, con la boleta ya completa.
('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)', 5,
$a$  -- mig 3XA: el que cargo un vale blanco no vio montos (no puede leer
$a$,
$r$  -- #1469 (COB-F-4): el saldo a favor del cliente, FIFO. Lo que cae en esta boleta se
  -- devuelve para mostrarlo; lo que va a boletas más viejas, aparte.
  IF v_credito_boletas IS NOT NULL THEN
    v_saldo_favor := public._alta_aplicar_saldo_a_favor(v_pedido_id, p_cliente_id, v_sucursal);
  END IF;

  -- mig 3XA: el que cargo un vale blanco no vio montos (no puede leer
$r$),

-- crear_pedido_completo · la respuesta.
('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)', 6,
$a$    || CASE WHEN v_tipo_factura = 'VB'
$a$,
$r$    || v_saldo_favor
    || CASE WHEN v_tipo_factura = 'VB'
$r$),

-- bot · las variables.
('public.crear_pedido_completo_bot(uuid,uuid)', 1,
$a$  v_promos_regalo BIGINT[];
BEGIN
$a$,
$r$  v_promos_regalo BIGINT[];
  -- #1469: lo mismo que crear_pedido_completo.
  v_credito_boletas BIGINT[];
  v_saldo_favor JSONB := '{}'::JSONB;
BEGIN
$r$),

-- bot · VTA-F-2.
('public.crear_pedido_completo_bot(uuid,uuid)', 2,
$a$  -- El total lo calcula el servidor (mig 235), igual que en
$a$,
$r$  -- #1469 (VTA-F-2): al menos un renglón que se cobra, como crear_pedido_completo.
  IF NOT EXISTS (
       SELECT 1
         FROM jsonb_array_elements(CASE WHEN jsonb_typeof(v_pendiente.items) = 'array'
                                        THEN v_pendiente.items ELSE '[]'::jsonb END) e
        WHERE NOT COALESCE((e->>'es_bonificacion')::BOOLEAN, false)
          AND COALESCE((e->>'cantidad')::NUMERIC, 0) > 0) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'El pedido tiene que tener al menos un producto que no sea regalo. El pedido no se creó.');
  END IF;

  -- El total lo calcula el servidor (mig 235), igual que en
$r$),

-- bot · fase 1.
('public.crear_pedido_completo_bot(uuid,uuid)', 3,
$a$  PERFORM 1 FROM productos
   WHERE sucursal_id = v_pendiente.sucursal_id
$a$,
$r$  -- #1469: el orden de crear_pedido_completo (el bot no carga vales blancos).
  v_credito_boletas := public._alta_bloquea_boletas_credito(v_pendiente.cliente_id, v_pendiente.sucursal_id);

  PERFORM 1 FROM productos
   WHERE sucursal_id = v_pendiente.sucursal_id
$r$),

-- bot · fase 2.
('public.crear_pedido_completo_bot(uuid,uuid)', 4,
$a$  PERFORM 1 FROM promociones
   WHERE sucursal_id = v_pendiente.sucursal_id AND id = ANY (v_promos_regalo)
   ORDER BY id
     FOR UPDATE;
$a$,
$r$  PERFORM 1 FROM promociones
   WHERE sucursal_id = v_pendiente.sucursal_id AND id = ANY (v_promos_regalo)
   ORDER BY id
     FOR UPDATE;
  IF v_credito_boletas IS NOT NULL THEN
    PERFORM public._alta_bloquea_creditos(v_pendiente.cliente_id, v_pendiente.sucursal_id, v_credito_boletas);
  END IF;
$r$),

-- bot · aplicar y responder.
('public.crear_pedido_completo_bot(uuid,uuid)', 5,
$a$  UPDATE bot_pedidos_pendientes SET consumido = TRUE WHERE id = p_confirmacion_id;

  RETURN jsonb_build_object('success', true, 'pedido_id', v_pedido_id, 'total', v_pendiente.total + v_cargo_envio, 'cargo_envio', v_cargo_envio);
$a$,
$r$  -- #1469 (COB-F-4): el saldo a favor del cliente, FIFO, como crear_pedido_completo.
  IF v_credito_boletas IS NOT NULL THEN
    v_saldo_favor := public._alta_aplicar_saldo_a_favor(v_pedido_id, v_pendiente.cliente_id, v_pendiente.sucursal_id);
  END IF;

  UPDATE bot_pedidos_pendientes SET consumido = TRUE WHERE id = p_confirmacion_id;

  RETURN jsonb_build_object('success', true, 'pedido_id', v_pedido_id, 'total', v_pendiente.total + v_cargo_envio, 'cargo_envio', v_cargo_envio)
         || v_saldo_favor;
$r$);

DO $parches$
DECLARE
  v_f   record;
  v_p   record;
  v_def text;
  v_n   int;
BEGIN
  FOR v_f IN SELECT DISTINCT firma FROM _n_parche ORDER BY firma LOOP
    v_def := pg_get_functiondef(v_f.firma::regprocedure);
    FOR v_p IN SELECT * FROM _n_parche WHERE firma = v_f.firma ORDER BY orden LOOP
      v_n := (length(v_def) - length(replace(v_def, v_p.ancla, ''))) / length(v_p.ancla);
      IF v_n <> v_p.veces THEN
        RAISE EXCEPTION 'mig 463 · % parche %: el ancla aparece % vez/veces y se esperaba %',
          v_f.firma, v_p.orden, v_n, v_p.veces;
      END IF;
      v_def := replace(v_def, v_p.ancla, v_p.reemplazo);
    END LOOP;
    EXECUTE v_def;
  END LOOP;
END
$parches$;

-- ---------------------------------------------------------------------------
-- Los créditos sueltos de hoy con una boleta impaga del mismo cliente y sucursal
-- ---------------------------------------------------------------------------
DO $sueltos$
DECLARE
  v_c record;
  v_aplicado numeric;
  v_n int := 0;
  v_monto numeric := 0;
BEGIN
  FOR v_c IN
    SELECT DISTINCT pg.cliente_id, pg.sucursal_id
      FROM pagos pg
     WHERE pg.pedido_id IS NULL
       AND EXISTS (SELECT 1 FROM pedidos p
                    WHERE p.cliente_id = pg.cliente_id
                      AND p.sucursal_id = pg.sucursal_id
                      AND p.estado NOT IN ('cancelado', 'anulado')
                      AND p.total > COALESCE(p.monto_pagado, 0))
     ORDER BY 1, 2
  LOOP
    v_aplicado := COALESCE(public.aplicar_credito_cliente(v_c.cliente_id, v_c.sucursal_id), 0);
    v_n := v_n + 1;
    v_monto := v_monto + v_aplicado;
    RAISE NOTICE 'mig 463 · cliente % (sucursal %): % de saldo a favor aplicado', v_c.cliente_id, v_c.sucursal_id, v_aplicado;
  END LOOP;
  RAISE NOTICE 'mig 463 · % cliente(s), % aplicado en total', v_n, v_monto;

  -- Ningún crédito suelto convive con una boleta impaga que pueda pagar (el de una NC no va a
  -- la boleta que la originó, mig 283).
  IF EXISTS (SELECT 1
               FROM pagos pg
               LEFT JOIN notas_credito_venta nc ON nc.id = pg.nota_credito_id
              WHERE pg.pedido_id IS NULL
                AND EXISTS (SELECT 1 FROM pedidos p
                             WHERE p.cliente_id = pg.cliente_id
                               AND p.sucursal_id = pg.sucursal_id
                               AND p.estado NOT IN ('cancelado', 'anulado')
                               AND p.total > COALESCE(p.monto_pagado, 0)
                               AND p.id IS DISTINCT FROM nc.pedido_id)) THEN
    RAISE EXCEPTION 'mig 463 · quedó un crédito suelto con una boleta impaga que podía pagar';
  END IF;
END
$sueltos$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos y los EXECUTE quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT t.firma, t.hash, t.acl, t.definer, md5(p.prosrc) AS h, p.proacl::text AS a, p.prosecdef AS def
      FROM (VALUES
        ('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)',
         '56969128aba1e0125044c9afbd40846e', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', true),
        ('public.crear_pedido_completo_bot(uuid,uuid)',
         '7abf9cba158eae650853ef3348963238', '{postgres=X/postgres,service_role=X/postgres}', true),
        ('public._alta_bloquea_boletas_credito(bigint,bigint)',
         '981e18810fe5431f783298c1c81091c7', '{postgres=X/postgres,service_role=X/postgres}', false),
        ('public._alta_bloquea_creditos(bigint,bigint,bigint[])',
         'f061aa2116301e0142f5c4ce1844ce8b', '{postgres=X/postgres,service_role=X/postgres}', false),
        ('public._alta_aplicar_saldo_a_favor(bigint,bigint,bigint)',
         'a4de5988c701c41a304775b40d5c3213', '{postgres=X/postgres,service_role=X/postgres}', false),
        ('public.pagos_marcar_saldo_a_favor()',
         '7719a8d736c771e643f96b0c614305e4', '{postgres=X/postgres,service_role=X/postgres}', false)
      ) AS t(firma, hash, acl, definer)
      JOIN pg_proc p ON p.oid = t.firma::regprocedure
  LOOP
    IF r.h <> r.hash OR r.a IS DISTINCT FROM r.acl OR r.def <> r.definer THEN
      RAISE EXCEPTION '% no quedó como en el repo (md5 %, acl %, definer %)', r.firma, r.h, r.a, r.def;
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgname = 'trg_pagos_marcar_saldo_a_favor'
                    AND tgrelid = 'public.pagos'::regclass AND tgenabled = 'O') THEN
    RAISE EXCEPTION 'trg_pagos_marcar_saldo_a_favor no quedó creado';
  END IF;
END
$post$;

COMMIT;
