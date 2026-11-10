-- 479 · El crédito que nace de una cancelación o de una nota de crédito se aplica a las boletas
-- abiertas, anular una NC aplicada la desimputa, y "anular" el saldo a favor de una boleta lo quita
-- de la boleta en vez de borrarlo (#1512: COB-1, COB-2 y COB-3; #1520: VTA-10; tarjeta 1 de #1524).
--
-- QUÉ PASABA
--   · COB-1 · cancelar_pedido_con_stock desimputaba los cobros de la boleta cancelada y
--     crear_nota_credito_venta_impl insertaba el crédito de la NC suelto (pagos.pedido_id NULL), y
--     ninguno llamaba a aplicar_credito_cliente. El cliente quedaba con crédito y deuda a la vez:
--     saldo_cuenta bajaba, pero la boleta impaga seguía "impaga" por el total en la parada del chofer,
--     en el modal de cobro, en la mora y en cuentas por cobrar. Pasó en prod (pago 6492, NC #1).
--   · COB-2 · En una boleta, "Anular pago" sobre un pago que vino del saldo a favor, un pago a cuenta
--     o un pedazo hacía un DELETE: la boleta volvía a deber y el crédito desaparecía. El cliente
--     perdía esa plata.
--   · COB-3 · anular_nota_credito_venta rechazaba la NC con algo aplicado (v_aplicado > 0). Con
--     COB-1, toda NC sobre una boleta impaga nace aplicada: no se habría podido anular ninguna.
--   · VTA-10 · Pasar un vale blanco a ZZ o FC dejaba cargo_envio en 0 y el estado en 'no_aplica', y
--     cargo_tras_edicion sale enseguida con 'no_aplica': el pedido quedaba sin envío para siempre.
--
-- QUÉ CAMBIA
--   · Decisión del dueño (10/11): el crédito de una NC de venta baja primero su propia boleta, si
--     sigue impaga, y lo que sobra va FIFO a las otras abiertas, de la más vieja a la más nueva. El de
--     una cancelación va FIFO (aplicar_credito_cliente), como el alta y el pago a cuenta.
--     - crear_nota_credito_venta_impl: el pago 'nota_credito' nace suelto como antes y, si su boleta
--       debe algo, se le imputa entero o en un pedazo (pago_origen_id y pago_padre_id, como
--       aplicar_credito_cliente). El trigger de la 463c lo marca de_saldo_a_favor. Lo que sobra va por
--       aplicar_credito_cliente, que nunca lo devuelve a su boleta (mig 283). La respuesta suma
--       credito_aplicado_pedido, credito_aplicado_otras y credito_disponible.
--     - cancelar_pedido_con_stock: si desimputó algo, al final llama a aplicar_credito_cliente. No lo
--       hace con app.cancelacion_conserva_pagos = '1' ni con p_tipo = 'cambio_de_cliente': el crédito
--       del cambio de cliente lo aplica cambiar_cliente_pedido (tarjeta 2 de #1524). La respuesta suma
--       credito_aplicado.
--   · El orden global de locks: las boletas que el crédito alcanza, por id y junto con la propia;
--     después (en la cancelación, después de productos y promos) sus rutas por id, y los créditos del
--     cliente por id, junto con los pagos de la boleta cancelada. Lo hacen dos helpers nuevos de
--     server, _credito_bloquea_boletas y _credito_bloquea_rutas_y_creditos, con la cuenta de
--     _edicion_bloquea_boletas y de pedidos_reconciliar_pagos: la plata que puede quedar a favor es a
--     lo sumo lo cobrado de la boleta (o la NC menos lo que debe su boleta) más los créditos sueltos,
--     y la propia boleta no cuenta en la cola. Toma de más, nunca de menos. Se lee sin lock, como en
--     el alta (#1501, A2l): si en el medio cambia, aplicar_credito_cliente toma lo nuevo al final.
--   · COB-2 · desimputar_pago(pago, pedido) (RPC nueva, sólo admin): un pago con de_saldo_a_favor,
--     a_cuenta o pago_origen_id, imputado a esa boleta, vuelve a ser crédito suelto del mismo cliente
--     (pedido_id NULL, con su nota). Decisión del dueño (10/11): queda suelto, no se reaplica solo; lo
--     absorbe el próximo pedido, el próximo pago a cuenta o una imputación a mano. No cambia
--     saldo_cuenta, ni la fecha, ni el monto, ni la forma: la caja del día no se mueve, y la rendición
--     cerrada se lee de su foto (#1248). Un cobro de la boleta (sin ninguna de las tres marcas) se
--     sigue anulando con el DELETE de siempre. Con el pago ya suelto, contesta éxito
--     (ya_estaba_suelto): un reintento no falla.
--     Y el DELETE REST de esos pagos se rechaza con un trigger nuevo,
--     trg_pagos_guard_credito_aplicado, con el texto de qué hacer. No es la policy mt_pagos_delete
--     porque una policy filtra en silencio: el DELETE borraba 0 filas y el front decía "Pago anulado".
--   · COB-2 · cambiar_tipo_factura_pedido: el mensaje de ZZ/FC → VB con pagos dice que los cobros se
--     anulan y el saldo a favor se quita de la boleta.
--   · COB-3 · anular_nota_credito_venta desimputa lo aplicado: borra todos los pagos de la NC, sueltos
--     e imputados, y las boletas que pagaba vuelven a deber eso. Toma antes esas boletas por id y sus
--     rutas por id. El control de que el crédito coincide con el total de la NC suma lo suelto y lo
--     aplicado. La respuesta suma credito_desimputado y pedidos_desimputados.
--   · VTA-10 · Decisión del dueño (10/11): al pasar de VB a ZZ o FC, el envío sale como en el alta,
--     con la política de hoy de la sucursal (pedido_cargo_envio y _cargo_envio_estado_alta), dentro de
--     total, total_neto y total_iva, no de total_real. La respuesta suma cargo_envio.
--
-- QUÉ NO CAMBIA
--   aplicar_credito_cliente (su firma, su FIFO y que no aplica el crédito de una NC a su propia
--   boleta; la tarjeta 2 también la llama), imputar_credito_a_pedido, la policy mt_pagos_delete, las
--   firmas y los EXECUTE de las funciones que ya existían. En la cancelación, qué pagos se desimputan,
--   el stock, los lotes y las promos. En cambiar_tipo_factura_pedido, el resto de las ramas.
--
-- Ensayo: scripts/test-credito-suelto-1512.sql (corre en prod sin dejar rastro), los de los
-- llamadores de la cancelación (t6 y t15 del arnés) y las variantes nuevas b1* de
-- scripts/concurrencia/escenarios.mjs (la cancelación y la NC contra un cobro y contra una venta del
-- mismo cliente). Se aplica en LF.

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
  r record;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('public.cancelar_pedido_con_stock(bigint,text,uuid,text)',              '083550ab7e3524525a667b9cb2a5d554'),
      ('public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)',  '3a0d56f78a198436c5c45413ce689c04'),
      ('public.anular_nota_credito_venta(bigint,text)',                        'dc8a13efc7f6ce3f53a25a832c3165e3'),
      ('public.cambiar_tipo_factura_pedido(bigint,character varying,uuid)',    'cc1ed8062ea3141fa2d6e4a35636c193'),
      -- No cambia, pero lo de abajo se apoya en su FIFO y en que excluye la boleta de la NC.
      ('public.aplicar_credito_cliente(bigint,bigint)',                        'c56c4200f0ca10c4920629e8e552f21f')
    ) AS t(firma, hash)
  LOOP
    IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = r.firma::regprocedure) IS DISTINCT FROM r.hash THEN
      RAISE EXCEPTION 'mig 479 · % cambió en prod (md5 %): rehacer el parche sobre el cuerpo vigente',
        r.firma, (SELECT md5(prosrc) FROM pg_proc WHERE oid = r.firma::regprocedure);
    END IF;
  END LOOP;

  IF EXISTS (SELECT 1 FROM pg_proc
              WHERE pronamespace = 'public'::regnamespace
                AND proname IN ('desimputar_pago', '_credito_bloquea_boletas',
                                '_credito_bloquea_rutas_y_creditos', 'pagos_guard_borrar_credito_aplicado'))
     OR EXISTS (SELECT 1 FROM pg_trigger
                 WHERE tgrelid = 'public.pagos'::regclass AND tgname = 'trg_pagos_guard_credito_aplicado') THEN
    RAISE EXCEPTION 'mig 479 · ya existe alguna de las funciones o el trigger nuevos: ¿se aplicó dos veces?';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 1 · Los helpers del orden global de locks (sólo server)
-- ---------------------------------------------------------------------------
CREATE FUNCTION public._credito_bloquea_boletas(p_pedido_id bigint, p_cliente_id bigint,
                                                p_sucursal_id bigint, p_plata_extra numeric)
 RETURNS bigint[]
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_plata   numeric;
  v_alcanza bigint[] := '{}';
BEGIN
  -- #1512 (COB-1): la cancelacion y la NC dejan plata a favor del cliente y la
  -- aplican con aplicar_credito_cliente, que toma las boletas que esa plata
  -- alcanza a pagar. Tomadas desde ahi, con la boleta propia ya bloqueada, una
  -- de id menor quedaba al reves del orden por id (un FIFO o un alta del mismo
  -- cliente las toma por id: 40P01). Aca se toman antes, todas juntas y por id
  -- con la propia, como _edicion_bloquea_boletas (#1446). La plata es la que
  -- puede quedar a favor (p_plata_extra) mas los creditos sueltos, y la boleta
  -- propia no cuenta en la cola: toma de mas, nunca de menos. Lee sin lock: el
  -- llamador vuelve a tomar la boleta y valida. Devuelve lo que bloqueo, con la
  -- propia, para _credito_bloquea_rutas_y_creditos.
  IF p_cliente_id IS NOT NULL THEN
    v_plata := GREATEST(COALESCE(p_plata_extra, 0), 0)
               + COALESCE((SELECT sum(monto) FROM pagos
                            WHERE cliente_id = p_cliente_id
                              AND sucursal_id = p_sucursal_id
                              AND pedido_id IS NULL), 0);
    IF v_plata > 0.005 THEN
      v_alcanza := ARRAY(
        SELECT b.id
          FROM (SELECT p.id,
                       sum(p.total - COALESCE(p.monto_pagado, 0)) OVER (ORDER BY p.fecha, p.id)
                         - (p.total - COALESCE(p.monto_pagado, 0)) AS antes
                  FROM pedidos p
                 WHERE p.cliente_id = p_cliente_id
                   AND p.sucursal_id = p_sucursal_id
                   AND p.id IS DISTINCT FROM p_pedido_id
                   AND p.estado NOT IN ('cancelado', 'anulado')
                   AND p.total > COALESCE(p.monto_pagado, 0)) b
         WHERE b.antes < v_plata);
    END IF;
  END IF;

  IF p_pedido_id IS NOT NULL THEN
    v_alcanza := v_alcanza || p_pedido_id;
  END IF;

  PERFORM 1
     FROM pedidos
    WHERE id = ANY(v_alcanza)
      AND sucursal_id = p_sucursal_id
    ORDER BY id
      FOR UPDATE;

  RETURN v_alcanza;
END;
$function$;

CREATE FUNCTION public._credito_bloquea_rutas_y_creditos(p_boletas bigint[], p_cliente_id bigint,
                                                         p_sucursal_id bigint, p_pagos_de bigint)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  -- #1512 (COB-1): el resto del orden global, despues de las boletas (y, en la
  -- cancelacion, de los productos y las promos), antes de la primera escritura
  -- que llega a una boleta: sus rutas por id (cada imputacion llega a la ruta por
  -- el trigger de monto_pagado) y los creditos del cliente por id, junto con los
  -- pagos de p_pagos_de, que la cancelacion desimputa y pasan a ser creditos: en
  -- una sola sentencia, por id, como la foto de la rendicion. Es el orden de
  -- aplicar_credito_cliente y de pedidos_reconciliar_pagos.
  PERFORM 1
     FROM recorridos
    WHERE id IN (SELECT rp.recorrido_id
                   FROM recorrido_pedidos rp
                  WHERE rp.pedido_id = ANY(p_boletas))
    ORDER BY id
      FOR NO KEY UPDATE;

  PERFORM 1
     FROM pagos
    WHERE id IN (SELECT pg.id
                   FROM pagos pg
                  WHERE pg.cliente_id = p_cliente_id
                    AND pg.sucursal_id = p_sucursal_id
                    AND pg.pedido_id IS NULL
                 UNION ALL
                 SELECT pg.id
                   FROM pagos pg
                  WHERE p_pagos_de IS NOT NULL
                    AND pg.pedido_id = p_pagos_de
                    AND pg.sucursal_id = p_sucursal_id)
    ORDER BY id
      FOR UPDATE;
END;
$function$;

REVOKE ALL ON FUNCTION public._credito_bloquea_boletas(bigint,bigint,bigint,numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._credito_bloquea_rutas_y_creditos(bigint[],bigint,bigint,bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._credito_bloquea_boletas(bigint,bigint,bigint,numeric) TO service_role;
GRANT EXECUTE ON FUNCTION public._credito_bloquea_rutas_y_creditos(bigint[],bigint,bigint,bigint) TO service_role;

-- ---------------------------------------------------------------------------
-- 2 · La cancelación aplica lo que desimputa (parches por ancla)
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _479_parche (funcion text, orden int, ancla text, reemplazo text) ON COMMIT DROP;

INSERT INTO _479_parche (funcion, orden, ancla, reemplazo) VALUES
-- 1 · las variables.
('cancelar', 1,
$a$  v_fardo INTEGER;
BEGIN
$a$,
$r$  v_fardo INTEGER;
  -- #1512 (COB-1): lo cobrado que la cancelacion deja a favor se aplica a las
  -- otras boletas del cliente. No con 'cancelacion_conserva_pagos' (no se
  -- desimputa nada) ni en un cambio de cliente: ese credito lo aplica
  -- cambiar_cliente_pedido.
  v_aplica_credito BOOLEAN := COALESCE(current_setting('app.cancelacion_conserva_pagos', true), '') <> '1'
                              AND COALESCE(p_tipo, '') <> 'cambio_de_cliente';
  v_cliente_id BIGINT;
  v_cobrado NUMERIC := 0;
  v_boletas BIGINT[];
  v_liberados INTEGER := 0;
  v_credito_aplicado NUMERIC := 0;
BEGIN
$r$),
-- 2 · las boletas que alcanza lo cobrado, por id y con esta, antes de tomarla.
('cancelar', 2,
$a$  SELECT * INTO v_pedido FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal FOR UPDATE;
$a$,
$r$  -- #1512 (COB-1): si la boleta tiene cobros, lo que queda a favor alcanza a
  -- otras boletas del cliente, que aplicar_credito_cliente toma al final. Se
  -- toman ahora, por id y con esta, antes que los productos: el orden del alta
  -- (_alta_bloquea_boletas_credito) y de la edicion (_edicion_bloquea_boletas).
  -- Sin cobros, la cancelacion toma lo mismo que antes.
  IF v_aplica_credito THEN
    SELECT cliente_id INTO v_cliente_id
      FROM pedidos
     WHERE id = p_pedido_id AND sucursal_id = v_sucursal;
    v_cobrado := COALESCE((SELECT sum(monto) FROM pagos
                            WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal), 0);
    IF v_cliente_id IS NOT NULL AND v_cobrado > 0.005 THEN
      v_boletas := public._credito_bloquea_boletas(p_pedido_id, v_cliente_id, v_sucursal, v_cobrado);
    END IF;
  END IF;

  SELECT * INTO v_pedido FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal FOR UPDATE;
$r$),
-- 3 · las rutas y los créditos antes de desimputar, y cuántos pagos se desimputaron.
('cancelar', 3,
$a$    PERFORM 1
       FROM pagos
      WHERE pedido_id = p_pedido_id
        AND sucursal_id = v_sucursal
      ORDER BY id
        FOR NO KEY UPDATE;

    UPDATE pagos
       SET pedido_id = NULL,
           notas = TRIM(BOTH ' ' FROM COALESCE(notas, '') || ' [saldo a favor por cancelacion]')
     WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;
  END IF;
$a$,
$r$    -- #1512 (COB-1): con credito para aplicar, antes las rutas de esas boletas
    -- por id y despues, en una sola sentencia por id, los creditos del cliente y
    -- los pagos de esta boleta, que pasan a serlo. El PERFORM de abajo vuelve a
    -- tomar los mismos pagos.
    IF v_boletas IS NOT NULL THEN
      PERFORM public._credito_bloquea_rutas_y_creditos(v_boletas, v_pedido.cliente_id, v_sucursal, p_pedido_id);
    END IF;

    PERFORM 1
       FROM pagos
      WHERE pedido_id = p_pedido_id
        AND sucursal_id = v_sucursal
      ORDER BY id
        FOR NO KEY UPDATE;

    UPDATE pagos
       SET pedido_id = NULL,
           notas = TRIM(BOTH ' ' FROM COALESCE(notas, '') || ' [saldo a favor por cancelacion]')
     WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;
    GET DIAGNOSTICS v_liberados = ROW_COUNT;
  END IF;
$r$),
-- 4 · con la boleta ya cancelada (no entra en la cola), el crédito va FIFO a las otras.
('cancelar', 4,
$a$  -- mig 180: la parada de un pedido cancelado no es una parada. Sin esto
$a$,
$r$  -- #1512 (COB-1, decision del dueño 10/11): lo cobrado que quedo a favor va
  -- FIFO a las otras boletas abiertas del cliente, como el alta y el pago a
  -- cuenta. Antes quedaba suelto: el cliente tenia credito y deuda a la vez, y
  -- el chofer le cobraba la boleta entera.
  IF v_aplica_credito AND v_liberados > 0 THEN
    v_credito_aplicado := COALESCE(public.aplicar_credito_cliente(v_pedido.cliente_id, v_sucursal), 0);
  END IF;

  -- mig 180: la parada de un pedido cancelado no es una parada. Sin esto
$r$),
-- 5 · la respuesta.
('cancelar', 5,
$a$    'mermas_registradas', v_mermas
  );
$a$,
$r$    'mermas_registradas', v_mermas,
    'credito_aplicado', round(v_credito_aplicado, 2)
  );
$r$),
-- 1 · VTA-10: las variables del envío.
('tipo', 1,
$a$  v_mensaje TEXT;
BEGIN
$a$,
$r$  v_mensaje TEXT;
  -- #1520 (VTA-10)
  v_cargo_envio NUMERIC := 0;
  v_cargo_estado TEXT;
BEGIN
$r$),
-- 2 · COB-2: el saldo a favor no se anula, se quita de la boleta.
('tipo', 2,
$a$          'El pedido tiene pagos registrados (o crédito imputado): un vale blanco no admite pagos. Anulalos primero.');
$a$,
$r$          'El pedido tiene pagos registrados: un vale blanco no admite pagos. Anulá los cobros y quitá de la boleta el saldo a favor aplicado (vuelve a favor del cliente) antes de pasarlo a vale blanco.');
$r$),
-- 3 · VTA-10: el envío de VB → ZZ/FC, como en el alta.
('tipo', 3,
$a$      -- B1: `total` y `monto_pagado` en el SET. Queda entregado y pendiente de
      -- cobro; el transportista no se toca (un VB nuevo no tiene).
      UPDATE pedidos
         SET tipo_factura = p_tipo,
$a$,
$r$      -- #1520 (VTA-10, decision del dueño 10/11): el envio sale como en el alta,
      -- con la politica de hoy de la sucursal. Antes quedaba en 0 y 'no_aplica', y
      -- cargo_tras_edicion no lo recalcula nunca con 'no_aplica'. Va en total,
      -- total_neto y total_iva, no en total_real (cargo_1_base).
      v_cargo_envio  := COALESCE(public.pedido_cargo_envio(round(v_total, 2), v_sucursal), 0);
      v_cargo_estado := public._cargo_envio_estado_alta(v_cargo_envio, v_sucursal);
      v_total      := v_total + v_cargo_envio;
      v_total_neto := v_total_neto + (public.cargo_envio_desglose(v_cargo_envio, p_tipo)).neto;
      v_total_iva  := v_total_iva  + (public.cargo_envio_desglose(v_cargo_envio, p_tipo)).iva;

      -- B1: `total` y `monto_pagado` en el SET. Queda entregado y pendiente de
      -- cobro; el transportista no se toca (un VB nuevo no tiene).
      UPDATE pedidos
         SET tipo_factura = p_tipo,
             cargo_envio  = v_cargo_envio,
             cargo_envio_estado = v_cargo_estado,
$r$),
-- 4 · VTA-10: el mensaje dice el envío.
('tipo', 4,
$a$        || to_char(round(v_total, 2), 'FM$999G999G999D00') || '.'
        || CASE WHEN v_pedido.transportista_id IS NULL
$a$,
$r$        || to_char(round(v_total, 2), 'FM$999G999G999D00') || '.'
        || CASE WHEN v_cargo_envio > 0
                THEN ' Incluye el envío: ' || to_char(round(v_cargo_envio, 2), 'FM$999G999G999D00') || '.'
                ELSE '' END
        || CASE WHEN v_pedido.transportista_id IS NULL
$r$),
-- 5 · VTA-10: la respuesta.
('tipo', 5,
$a$      'total_iva', round(v_total_iva, 2), 'total_real', round(v_total_real, 2),
      'mensaje', v_mensaje);
$a$,
$r$      'total_iva', round(v_total_iva, 2), 'total_real', round(v_total_real, 2),
      'cargo_envio', round(v_cargo_envio, 2),
      'mensaje', v_mensaje);
$r$);

DO $parches$
DECLARE
  v_f   record;
  v_p   record;
  v_def text;
  v_n   int;
BEGIN
  FOR v_f IN
    SELECT * FROM (VALUES
      ('cancelar', 'public.cancelar_pedido_con_stock(bigint,text,uuid,text)'),
      ('tipo',     'public.cambiar_tipo_factura_pedido(bigint,character varying,uuid)')
    ) AS t(funcion, firma)
  LOOP
    v_def := pg_get_functiondef(v_f.firma::regprocedure);
    FOR v_p IN SELECT * FROM _479_parche WHERE funcion = v_f.funcion ORDER BY orden LOOP
      v_n := (length(v_def) - length(replace(v_def, v_p.ancla, ''))) / length(v_p.ancla);
      IF v_n <> 1 THEN
        RAISE EXCEPTION 'mig 479 · parche % %: el ancla aparece % vez/veces y se esperaba 1',
          v_p.funcion, v_p.orden, v_n;
      END IF;
      v_def := replace(v_def, v_p.ancla, v_p.reemplazo);
    END LOOP;
    EXECUTE v_def;
  END LOOP;
END
$parches$;

-- ---------------------------------------------------------------------------
-- 3 · La NC baja primero su boleta y lo que sobra va FIFO
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crear_nota_credito_venta_impl(p_pedido_id bigint, p_cliente_id bigint, p_items jsonb, p_motivo text, p_observaciones text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal  bigint := current_sucursal_id();
  v_user      uuid   := auth.uid();
  v_rol       text;
  v_fecha     date   := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_pedido    RECORD;
  v_it        RECORD;
  v_total     numeric := 0;
  v_neto      numeric := 0; -- #1257
  v_iva       numeric := 0;
  v_nc_id     bigint;
  v_pago_id   bigint;
  v_n         integer;
  v_n_dist    integer;
  -- #1512 (COB-1)
  v_estimado  numeric;
  v_falta     numeric;
  v_boletas   bigint[];
  v_aplicar   numeric;
  v_aplicado  numeric := 0;
  v_otras     numeric := 0;
  v_guc       text;
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  -- Rol primario crudo, como registrar_pago_cliente_fifo_impl: es el espejo de
  -- puedeCrearNotaCreditoVenta (src/lib/permisos.ts).
  SELECT rol INTO v_rol FROM perfiles WHERE id = v_user;
  IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado: solo admin o encargado pueden emitir notas de credito'
      USING ERRCODE = '42501';
  END IF;

  IF COALESCE(p_motivo, '') NOT IN ('producto_vencido', 'producto_danado', 'otro') THEN
    RAISE EXCEPTION 'Motivo invalido: %', p_motivo USING ERRCODE = '22023';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'La nota de credito necesita al menos un item' USING ERRCODE = '22023';
  END IF;

  -- #1512 (COB-1): el credito baja esta boleta y lo que sobra va FIFO a las
  -- otras del cliente (aplicar_credito_cliente, al final). Las que puede
  -- alcanzar se toman ahora, por id y con esta, antes que sus rutas y los
  -- creditos (_credito_bloquea_boletas). Se lee sin lock: lo que sobra es a lo
  -- sumo lo que la NC pasa lo que debe esta boleta. Si el pedido no existe o no
  -- es del cliente, no se toma nada y lo dice el SELECT de abajo.
  SELECT GREATEST(p.total - COALESCE(p.monto_pagado, 0), 0)
    INTO v_falta
    FROM pedidos p
   WHERE p.id = p_pedido_id AND p.sucursal_id = v_sucursal AND p.cliente_id = p_cliente_id;
  IF FOUND THEN
    SELECT COALESCE(sum((e->>'cantidad')::numeric * COALESCE(pi.precio_unitario, 0)), 0)
      INTO v_estimado
      FROM jsonb_array_elements(p_items) e
      JOIN pedido_items pi
        ON pi.id::text = e->>'pedido_item_id'
       AND pi.pedido_id = p_pedido_id
       AND pi.sucursal_id = v_sucursal
     WHERE e->>'cantidad' ~ '^[0-9]{1,9}$';
    v_boletas := public._credito_bloquea_boletas(p_pedido_id, p_cliente_id, v_sucursal,
                                                 GREATEST(v_estimado - v_falta, 0));
  END IF;

  -- El lock del pedido serializa dos NCs simultaneas sobre las mismas lineas.
  SELECT id, cliente_id, estado
    INTO v_pedido
    FROM pedidos
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pedido no encontrado' USING ERRCODE = 'P0002';
  END IF;
  IF EXISTS (SELECT 1 FROM pedidos WHERE id = p_pedido_id AND tipo_factura = 'VB') THEN
    RAISE EXCEPTION 'El pedido #% es un vale blanco (consumo interno): no admite nota de credito. Si hay que bajarle el total, es una salvedad.', p_pedido_id
      USING ERRCODE = '22023';
  END IF;
  IF v_pedido.estado IS DISTINCT FROM 'entregado' THEN
    RAISE EXCEPTION 'Solo se puede emitir una nota de credito sobre un pedido entregado (estado: %)',
      v_pedido.estado USING ERRCODE = '22023';
  END IF;
  IF v_pedido.cliente_id IS DISTINCT FROM p_cliente_id THEN
    RAISE EXCEPTION 'El pedido #% no es de este cliente', p_pedido_id USING ERRCODE = '22023';
  END IF;

  SELECT count(*), count(DISTINCT e->>'pedido_item_id')
    INTO v_n, v_n_dist
    FROM jsonb_array_elements(p_items) e;
  IF v_n <> v_n_dist THEN
    RAISE EXCEPTION 'Hay items repetidos en la nota de credito' USING ERRCODE = '22023';
  END IF;

  -- Validacion y total. El precio sale del pedido, nunca del cliente.
  FOR v_it IN
    SELECT r.pedido_item_id_txt,
           r.cantidad_txt,
           pi.id                             AS pi_id,
           pi.cantidad                       AS entregada,
           pi.precio_unitario,
           pi.neto_unitario,
           pi.iva_unitario,
           COALESCE(pi.es_bonificacion, false) AS es_bonif,
           COALESCE((
             SELECT SUM(i.cantidad)
               FROM nota_credito_venta_items i
               JOIN notas_credito_venta n ON n.id = i.nota_credito_id
              WHERE i.pedido_item_id = pi.id AND NOT n.anulada
           ), 0)                             AS ya_acreditada
      FROM (
        SELECT e->>'pedido_item_id' AS pedido_item_id_txt,
               e->>'cantidad'       AS cantidad_txt
          FROM jsonb_array_elements(p_items) e
      ) r
      LEFT JOIN pedido_items pi
        ON pi.id::text = r.pedido_item_id_txt
       AND pi.pedido_id = p_pedido_id
       AND pi.sucursal_id = v_sucursal
  LOOP
    IF v_it.pi_id IS NULL THEN
      RAISE EXCEPTION 'El item % no pertenece al pedido #%', v_it.pedido_item_id_txt, p_pedido_id
        USING ERRCODE = '22023';
    END IF;
    IF v_it.cantidad_txt IS NULL OR v_it.cantidad_txt !~ '^[0-9]+$' OR v_it.cantidad_txt::integer <= 0 THEN
      RAISE EXCEPTION 'Cantidad invalida para el item %: %', v_it.pi_id, COALESCE(v_it.cantidad_txt, 'vacia')
        USING ERRCODE = '22023';
    END IF;
    IF v_it.es_bonif THEN
      RAISE EXCEPTION 'El item % es un regalo de promocion: no se cobro, no se acredita', v_it.pi_id
        USING ERRCODE = '22023';
    END IF;
    IF v_it.cantidad_txt::integer > v_it.entregada - v_it.ya_acreditada THEN
      RAISE EXCEPTION 'Item %: se entregaron % y ya se acreditaron %; no se pueden acreditar %',
        v_it.pi_id, v_it.entregada, v_it.ya_acreditada, v_it.cantidad_txt USING ERRCODE = '22023';
    END IF;
    v_total := v_total + v_it.cantidad_txt::integer * COALESCE(v_it.precio_unitario, 0);
    -- #1257: la foto de la linea (lo que el pedido declaro por esas unidades).
    v_iva  := v_iva  + v_it.cantidad_txt::integer * COALESCE(v_it.iva_unitario, 0);
    v_neto := v_neto + v_it.cantidad_txt::integer
                       * COALESCE(v_it.neto_unitario, COALESCE(v_it.precio_unitario, 0) - COALESCE(v_it.iva_unitario, 0));
  END LOOP;

  IF v_total <= 0 THEN
    RAISE EXCEPTION 'El total de la nota de credito tiene que ser mayor a 0' USING ERRCODE = '22023';
  END IF;

  -- #1512 (COB-1): el resto del orden global antes de la primera escritura que
  -- llega a una boleta: las rutas de esas boletas por id, y los creditos del
  -- cliente por id.
  PERFORM public._credito_bloquea_rutas_y_creditos(COALESCE(v_boletas, ARRAY[p_pedido_id]),
                                                   p_cliente_id, v_sucursal, NULL);

  INSERT INTO notas_credito_venta (
    sucursal_id, cliente_id, pedido_id, fecha, motivo, observaciones, total, usuario_id,
    neto, iva
  ) VALUES (
    v_sucursal, p_cliente_id, p_pedido_id, v_fecha, p_motivo, NULLIF(trim(p_observaciones), ''),
    v_total, v_user,
    round(v_neto, 2), round(v_iva, 2)
  ) RETURNING id INTO v_nc_id;

  INSERT INTO nota_credito_venta_items (
    nota_credito_id, sucursal_id, pedido_item_id, producto_id, cantidad, precio_unitario, subtotal
  )
  SELECT v_nc_id, v_sucursal, pi.id, pi.producto_id, (e->>'cantidad')::integer,
         pi.precio_unitario, (e->>'cantidad')::integer * pi.precio_unitario
    FROM jsonb_array_elements(p_items) e
    JOIN pedido_items pi
      ON pi.id::text = e->>'pedido_item_id'
     AND pi.pedido_id = p_pedido_id
     AND pi.sucursal_id = v_sucursal;

  -- El credito: nace como pago sin pedido = saldo a favor (165/235). Sin stock,
  -- sin tocar el total ni las lineas del pedido.
  INSERT INTO pagos (
    cliente_id, pedido_id, monto, forma_pago, fecha,
    referencia, notas, usuario_id, sucursal_id, nota_credito_id
  ) VALUES (
    p_cliente_id, NULL, v_total, 'nota_credito', v_fecha,
    'NC-' || v_nc_id,
    'Nota de credito #' || v_nc_id || ' (pedido #' || p_pedido_id || ') [saldo a favor]',
    v_user, v_sucursal, v_nc_id
  ) RETURNING id INTO v_pago_id;

  -- #1512 (COB-1, decision del dueño 10/11): el credito baja primero esta boleta,
  -- si sigue impaga, como lo hace aplicar_credito_cliente con un credito: entero
  -- o en un pedazo que guarda la raiz y su padre (#1248, #1359). El trigger de la
  -- 463c lo marca de_saldo_a_favor. aplicar_credito_cliente no aplica el
  -- credito de una NC a su propia boleta (mig 283): por eso va aca.
  SELECT GREATEST(total - COALESCE(monto_pagado, 0), 0)
    INTO v_falta
    FROM pedidos
   WHERE id = p_pedido_id;
  v_aplicar := round(LEAST(v_total, v_falta), 2);

  IF v_aplicar > 0.005 THEN
    v_guc := current_setting('app.reimputacion_pagos', true);
    PERFORM set_config('app.reimputacion_pagos', 'on', true);

    IF v_aplicar >= v_total - 0.005 THEN
      UPDATE pagos
         SET pedido_id = p_pedido_id,
             -- #1329: un credito es plata que entro.
             a_cuenta = true,
             notas = NULLIF(trim(replace(COALESCE(notas, ''), '[saldo a favor]', '')), '')
       WHERE id = v_pago_id;
      v_aplicado := v_total;
    ELSE
      UPDATE pagos SET monto = monto - v_aplicar WHERE id = v_pago_id;

      INSERT INTO pagos (
        cliente_id, pedido_id, monto, forma_pago, fecha,
        referencia, notas, usuario_id, sucursal_id, nota_credito_id, pago_origen_id,
        pago_padre_id
      )
      SELECT cliente_id, p_pedido_id, v_aplicar, forma_pago, fecha, referencia,
             NULLIF(trim(replace(COALESCE(notas, ''), '[saldo a favor]', '')), ''),
             usuario_id, sucursal_id, nota_credito_id, COALESCE(pago_origen_id, id),
             id
        FROM pagos
       WHERE id = v_pago_id;
      v_aplicado := v_aplicar;
    END IF;

    PERFORM set_config('app.reimputacion_pagos', COALESCE(v_guc, ''), true);
  END IF;

  -- Lo que sobra va FIFO a las otras boletas abiertas, de la mas vieja a la mas
  -- nueva.
  IF v_total - v_aplicado > 0.005 THEN
    v_otras := COALESCE(public.aplicar_credito_cliente(p_cliente_id, v_sucursal), 0);
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'nota_credito_id', v_nc_id,
    'pago_id', v_pago_id,
    'total', v_total,
    'neto', round(v_neto, 2),
    'iva', round(v_iva, 2),
    'fecha', v_fecha,
    'credito_aplicado_pedido', round(v_aplicado, 2),
    'credito_aplicado_otras', round(v_otras, 2),
    'credito_disponible', round(COALESCE((SELECT sum(monto) FROM pagos
                                           WHERE nota_credito_id = v_nc_id AND pedido_id IS NULL), 0), 2)
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4 · Anular una NC desimputa lo aplicado
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.anular_nota_credito_venta(p_nota_credito_id bigint, p_motivo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal    bigint := current_sucursal_id();
  v_user        uuid   := auth.uid();
  v_rol         text;
  v_nc          RECORD;
  v_disponible  numeric;
  v_aplicado    numeric;
  v_borrados    integer;
  v_boletas     bigint[];
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  SELECT rol INTO v_rol FROM perfiles WHERE id = v_user;
  IF v_rol IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Solo admin puede anular una nota de credito' USING ERRCODE = '42501';
  END IF;

  -- #1512 (COB-3): anular desimputa lo aplicado. Las boletas que pagaba el
  -- credito se toman antes, por id, y sus rutas por id: borrar sus pagos llega a
  -- cada una por el trigger de monto_pagado y a su ruta por el de la entrega. Es
  -- el orden global (boletas, rutas, pagos). Se lee sin lock; si en el medio el
  -- credito llega a otra boleta, el DELETE la toma al final.
  v_boletas := ARRAY(SELECT DISTINCT pg.pedido_id
                       FROM pagos pg
                      WHERE pg.nota_credito_id = p_nota_credito_id
                        AND pg.sucursal_id = v_sucursal
                        AND pg.pedido_id IS NOT NULL
                      ORDER BY 1);
  PERFORM 1
     FROM pedidos
    WHERE id = ANY(v_boletas)
      AND sucursal_id = v_sucursal
    ORDER BY id
      FOR UPDATE;
  PERFORM 1
     FROM recorridos
    WHERE id IN (SELECT rp.recorrido_id
                   FROM recorrido_pedidos rp
                  WHERE rp.pedido_id = ANY(v_boletas))
    ORDER BY id
      FOR NO KEY UPDATE;

  SELECT id, total, anulada, cliente_id
    INTO v_nc
    FROM notas_credito_venta
   WHERE id = p_nota_credito_id AND sucursal_id = v_sucursal
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Nota de credito no encontrada' USING ERRCODE = 'P0002';
  END IF;
  IF v_nc.anulada THEN
    RAISE EXCEPTION 'La nota de credito #% ya esta anulada', p_nota_credito_id USING ERRCODE = '22023';
  END IF;

  -- Lock de los pedazos: aplicar_credito_cliente los actualiza, asi que una
  -- imputacion concurrente espera o nos hace esperar.
  -- #1424: por id, como la foto de la rendicion.
  PERFORM 1 FROM pagos WHERE nota_credito_id = p_nota_credito_id ORDER BY id FOR UPDATE;

  SELECT COALESCE(SUM(monto) FILTER (WHERE pedido_id IS NULL), 0),
         COALESCE(SUM(monto) FILTER (WHERE pedido_id IS NOT NULL), 0)
    INTO v_disponible, v_aplicado
    FROM pagos
   WHERE nota_credito_id = p_nota_credito_id;

  -- El credito de la NC, suelto o aplicado, suma su total: desafectar y los
  -- pedazos lo mueven, nunca lo crean ni lo borran.
  IF abs(v_disponible + v_aplicado - v_nc.total) > 0.005 THEN
    RAISE EXCEPTION 'No se puede anular: el credito de la nota (%) no coincide con su total (%). Revisar a mano.',
      to_char(v_disponible + v_aplicado, 'FM999999990.00'), to_char(v_nc.total, 'FM999999990.00')
      USING ERRCODE = '22023';
  END IF;

  -- Se borra todo el credito: lo suelto y lo aplicado. Las boletas que pagaba
  -- vuelven a deber eso (el trigger de monto_pagado), y el saldo del cliente
  -- sube el total de la NC.
  PERFORM set_config('app.anulando_nota_credito', 'on', true);
  DELETE FROM pagos WHERE nota_credito_id = p_nota_credito_id;
  GET DIAGNOSTICS v_borrados = ROW_COUNT;
  PERFORM set_config('app.anulando_nota_credito', 'off', true);

  UPDATE notas_credito_venta
     SET anulada = true,
         anulada_por = v_user,
         anulada_at = now(),
         motivo_anulacion = NULLIF(trim(p_motivo), '')
   WHERE id = p_nota_credito_id;

  RETURN jsonb_build_object(
    'success', true,
    'nota_credito_id', p_nota_credito_id,
    'credito_revertido', round(v_disponible + v_aplicado, 2),
    'credito_desimputado', round(v_aplicado, 2),
    'pedidos_desimputados', to_jsonb(v_boletas),
    'pagos_borrados', v_borrados
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 5 · COB-2: quitar de una boleta el saldo a favor aplicado, por RPC
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.desimputar_pago(p_pago_id bigint, p_pedido_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal bigint := current_sucursal_id();
  v_pago     RECORD;
BEGIN
  -- #1512 (COB-2): un pago que vino del saldo a favor (de_saldo_a_favor), un
  -- pago a cuenta (a_cuenta) o un pedazo (pago_origen_id) es plata del cliente
  -- que se aplico a esta boleta. "Anularlo" lo quita de la boleta y vuelve a
  -- ser credito suelto del mismo cliente; borrarlo hacia desaparecer la plata.
  -- Decision del dueño (10/11): queda suelto, no se reaplica solo. No cambia
  -- saldo_cuenta, ni la fecha, ni el monto, ni la forma: la caja del dia no se
  -- mueve, y una rendicion cerrada se lee de su foto (#1248). Un cobro de la
  -- boleta, sin ninguna de las tres marcas, se anula con el DELETE de siempre.
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Solo un admin puede quitar un pago de una boleta' USING ERRCODE = '42501';
  END IF;
  IF p_pago_id IS NULL OR p_pedido_id IS NULL THEN
    RAISE EXCEPTION 'Faltan el pago o la boleta' USING ERRCODE = '22023';
  END IF;

  -- El orden global: la boleta, sus rutas por id (el UPDATE llega a la ruta por
  -- el trigger de monto_pagado) y recien el pago.
  PERFORM 1 FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal FOR UPDATE;
  PERFORM 1
     FROM recorridos
    WHERE id IN (SELECT rp.recorrido_id
                   FROM recorrido_pedidos rp
                   JOIN pedidos pd ON pd.id = rp.pedido_id
                  WHERE rp.pedido_id = p_pedido_id
                    AND pd.sucursal_id = v_sucursal)
    ORDER BY id
      FOR NO KEY UPDATE;

  SELECT id, pedido_id, cliente_id, monto, de_saldo_a_favor, a_cuenta, pago_origen_id
    INTO v_pago
    FROM pagos
   WHERE id = p_pago_id AND sucursal_id = v_sucursal
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pago no encontrado' USING ERRCODE = 'P0002';
  END IF;

  -- Un reintento que llega con el pago ya suelto no falla.
  IF v_pago.pedido_id IS NULL THEN
    RETURN jsonb_build_object('success', true, 'pago_id', p_pago_id, 'pedido_id', p_pedido_id,
                              'monto', v_pago.monto, 'ya_estaba_suelto', true);
  END IF;
  IF v_pago.pedido_id <> p_pedido_id THEN
    RAISE EXCEPTION 'El pago #% ya no está en la boleta #%, sino en la #%: volvé a abrirla',
      p_pago_id, p_pedido_id, v_pago.pedido_id USING ERRCODE = '22023';
  END IF;
  IF NOT (COALESCE(v_pago.de_saldo_a_favor, false) OR COALESCE(v_pago.a_cuenta, false)
          OR v_pago.pago_origen_id IS NOT NULL) THEN
    RAISE EXCEPTION 'El pago #% es un cobro de la boleta #%, no saldo a favor: se anula, no se quita',
      p_pago_id, p_pedido_id USING ERRCODE = '22023';
  END IF;

  UPDATE pagos
     SET pedido_id = NULL,
         notas = trim(COALESCE(notas, '') || ' [quitado del pedido #' || p_pedido_id || '] [saldo a favor]')
   WHERE id = p_pago_id;

  RETURN jsonb_build_object(
    'success', true,
    'pago_id', p_pago_id,
    'pedido_id', p_pedido_id,
    'monto', v_pago.monto,
    'ya_estaba_suelto', false,
    'saldo_a_favor', round(COALESCE((SELECT sum(monto) FROM pagos
                                      WHERE cliente_id = v_pago.cliente_id
                                        AND sucursal_id = v_sucursal
                                        AND pedido_id IS NULL), 0), 2)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.desimputar_pago(bigint,bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.desimputar_pago(bigint,bigint) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6 · COB-2: el DELETE REST de ese saldo a favor se rechaza con su texto
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.pagos_guard_borrar_credito_aplicado()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  -- #1512 (COB-2): el borrado directo desde la app (como
  -- pagos_guard_anulacion_caja_cerrada: el server corre como su dueño y no pasa).
  -- Una policy filtraria en silencio: el DELETE borraria 0 filas y el front
  -- diria "Pago anulado".
  IF current_user = 'authenticated'
     AND pg_trigger_depth() = 1
     AND OLD.pedido_id IS NOT NULL
     AND (COALESCE(OLD.de_saldo_a_favor, false) OR COALESCE(OLD.a_cuenta, false)
          OR OLD.pago_origen_id IS NOT NULL) THEN
    RAISE EXCEPTION 'El pago #% es saldo a favor del cliente aplicado a la boleta #%: no se borra. Quitalo de la boleta y vuelve a saldo a favor del cliente.',
      OLD.id, OLD.pedido_id USING ERRCODE = '42501';
  END IF;
  RETURN OLD;
END;
$function$;

REVOKE ALL ON FUNCTION public.pagos_guard_borrar_credito_aplicado() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pagos_guard_borrar_credito_aplicado() TO service_role;

CREATE TRIGGER trg_pagos_guard_credito_aplicado
  BEFORE DELETE ON public.pagos
  FOR EACH ROW EXECUTE FUNCTION public.pagos_guard_borrar_credito_aplicado();

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos son los del repo y los permisos, los esperados
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  v_md5 text;
  v_acl text;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('public.cancelar_pedido_con_stock(bigint,text,uuid,text)',             '3e6473cbe68550ed21514daae5e4a7f1',
       '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}/true'),
      ('public.cambiar_tipo_factura_pedido(bigint,character varying,uuid)',   '6d80f9a7597bd645c5c1704bc7620b04',
       '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}/true'),
      ('public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)', 'b5f15944ac98d4010766f03b6274a947',
       '{postgres=X/postgres,service_role=X/postgres}/true'),
      ('public.anular_nota_credito_venta(bigint,text)',                       '842276e15b7b438ed778834ceb76f36f',
       '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}/true'),
      ('public.desimputar_pago(bigint,bigint)',                               '3d1b171b70e53663fbdaa7e96bd4af2c',
       '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}/true'),
      ('public._credito_bloquea_boletas(bigint,bigint,bigint,numeric)',       'f03af491f210255b49b03a2e27aa7118',
       '{postgres=X/postgres,service_role=X/postgres}/false'),
      ('public._credito_bloquea_rutas_y_creditos(bigint[],bigint,bigint,bigint)', '5345cfa5382a7e73bb43df8357af33b6',
       '{postgres=X/postgres,service_role=X/postgres}/false'),
      ('public.pagos_guard_borrar_credito_aplicado()',                        '438f53a96624182ab9190d917303f786',
       '{postgres=X/postgres,service_role=X/postgres}/false'),
      -- No cambia.
      ('public.aplicar_credito_cliente(bigint,bigint)',                       'c56c4200f0ca10c4920629e8e552f21f',
       '{postgres=X/postgres,service_role=X/postgres}/true')
    ) AS t(firma, hash, acl)
  LOOP
    SELECT md5(prosrc), proacl::text || '/' || prosecdef::text INTO v_md5, v_acl
      FROM pg_proc WHERE oid = r.firma::regprocedure;
    IF v_md5 IS DISTINCT FROM r.hash OR v_acl IS DISTINCT FROM r.acl THEN
      RAISE EXCEPTION 'mig 479 · % no quedó como en el repo (md5 %, acl %)', r.firma, v_md5, v_acl;
    END IF;
  END LOOP;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgrelid = 'public.pagos'::regclass
                    AND tgname = 'trg_pagos_guard_credito_aplicado'
                    AND tgenabled = 'O') THEN
    RAISE EXCEPTION 'mig 479 · falta el trigger trg_pagos_guard_credito_aplicado';
  END IF;
END
$post$;

COMMIT;
