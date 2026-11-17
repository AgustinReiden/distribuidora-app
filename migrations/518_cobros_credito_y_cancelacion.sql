-- =========================================================================
-- NNN · COBROS, CRÉDITO, NOTA DE CRÉDITO DE VENTA Y CANCELACIÓN
--       (ola 2 del plan #1603, tarjeta B5: COB-b1, COB-b2, COB-b5 y SEG-1 de
--        #1545; 1559-b11, 1559-b12, 1559-b14, 1559-b15 y 1559-b16 de #1559;
--        1595-b1 de #1595; 1558-b4 de #1558)
--
-- Parcha por ancla, con premisa de md5 sobre el cuerpo vivo del 16/11 (ledger
-- en la 512), `_aplicar_credito_pagos`, `_credito_bloquea_boletas`,
-- `cancelar_pedido_con_stock`, `crear_nota_credito_venta_impl`,
-- `marcar_pagos_masivo_impl`, `marcar_entrega_y_pago_masivo_impl`,
-- `auditoria_integridad`, los seis wrappers de cobro que abren una solicitud y
-- las pre-tomas `_alta_bloquea_boletas_credito`, `_edicion_bloquea_boletas` y
-- `pedidos_reconciliar_pagos`. Sin premisa de md5 (son de otra tarjeta o les
-- suman líneas otras): las dos ventanas de `cambiar_cliente_pedido` y los cinco
-- md5 de la lista blanca de `auditoria_definer_sin_rol`.
-- Crea `_credito_ventana` (de server) y cambia la firma de
-- `pago_solicitud_abrir` (de server: la vieja se borra). Suma la columna
-- `pagos_solicitudes.contenido`. No cambia ninguna firma que llame el front.
-- Ensayo: scripts/test-cobros-credito-ola2-1603.sql. Se aplica en LF.
--
-- =========================================================================
-- 1 · COB-b2 · LA VENTANA DE UN CRÉDITO NO CUENTA LA BOLETA DE UNA NC
-- =========================================================================
-- `_aplicar_credito_pagos` y `_credito_bloquea_boletas` toman antes del primer
-- lock las boletas que el crédito alcanza a pagar: la cola por (fecha, id)
-- hasta que lo que deben las anteriores pasa la plata. Pero el crédito de una
-- NC no se imputa a su propia boleta (mig 283): el bucle la saltea, y lo que
-- esa boleta debe no se consume. Contarla en la cola cortaba la ventana antes
-- y el bucle llegaba a una boleta sin bloquear (40P01 latente). La ventana es
-- una, `_credito_ventana(cliente, sucursal, plata, sin, creditos)`: pesa 0 sólo
-- la boleta de una NC vigente cuyo crédito está entre los `creditos` que se
-- aplican (o que la pre-toma cuenta). Sin un crédito de NC en juego da
-- exactamente lo mismo que la fórmula de antes. La usan `_aplicar_credito_pagos`
-- y las seis pre-tomas: `_credito_bloquea_boletas` (cancelación y NC),
-- `_alta_bloquea_boletas_credito` (alta y bot), `_edicion_bloquea_boletas`,
-- `pedidos_reconciliar_pagos` y `cambiar_cliente_pedido` (sus dos ventanas).
-- Cada pre-toma le pasa al menos la plata y los créditos que después aplica,
-- y la ventana crece con los dos: lo que se pre-toma contiene lo que
-- `_aplicar_credito_pagos` toma después. (La primera versión de esta
-- migración ponía en 0 la boleta de toda NC del cliente y sólo en dos
-- funciones: el alta tomaba, después de los productos, una boleta que no
-- pagaba. Lo encontró la revisión de la tarjeta, hallazgo 1.)
--
-- =========================================================================
-- 2 · COB-b1 · LA CANCELACIÓN Y LA NC MIDEN LA VENTANA OTRA VEZ, YA BLOQUEADAS
-- =========================================================================
-- `cancelar_pedido_con_stock` lee lo cobrado de la boleta, y
-- `crear_nota_credito_venta_impl` lo que le falta, antes del FOR UPDATE de la
-- boleta. Un cobro que se esperaba en ese lock cambiaba los dos números, la
-- ventana quedaba corta y `_aplicar_credito_pagos` tomaba boletas fuera del
-- pre-bloqueo, después de los productos y de los créditos. Ahora:
--   · `_credito_bloquea_boletas`, con las boletas ya tomadas, vuelve a medir la
--     ventana y toma las que falten hasta que no falte ninguna (un cobro a una
--     boleta de la cola que se esperó en el lock deja pasar el crédito más
--     lejos). La segunda medida cuenta sólo la plata de esta operación
--     (`p_plata_extra`) y sus pagos: desde #1538 la cancelación y la NC aplican
--     sólo lo suyo, y un crédito que deja suelto otra operación en paralelo no
--     tiene por qué agrandarla (revisión, hallazgo 2);
--   · la cancelación relee lo cobrado con la boleta tomada y, si es más, pide
--     las boletas que alcanza esa plata; la NC hace lo mismo con lo que sobra
--     de su total sobre lo que la boleta debe.
-- Las dos cosas pasan antes de los productos, las rutas y los créditos, así
-- que las rutas de esas boletas también entran en orden. Sin carrera no cambia
-- nada: la segunda medida da lo mismo que la primera. En la carrera, la boleta
-- que falta se toma después de la propia (puede tener un id menor): un 40P01
-- contra otra operación de las mismas boletas sigue siendo posible, pero ya no
-- contra los productos ni los créditos, y nada queda fuera del pre-bloqueo.
--
-- =========================================================================
-- 3 · 1595-b1 · UN CRÉDITO NO SE CORTA A LAS 500 BOLETAS
-- =========================================================================
-- El bucle de `_aplicar_credito_pagos` salía a las 500 vueltas por crédito:
-- con 505 boletas de $1 y un crédito de 600 quedaban 5 abiertas y 100 a favor.
-- La vuelta paga una boleta entera o se queda sin crédito, así que el bucle
-- termina solo; el tope era un freno contra una boleta que no baja. El freno
-- ahora es ése: si la misma boleta vuelve en la vuelta siguiente del mismo
-- crédito, la operación aborta con su motivo en vez de cortar callada. Sin tope
-- de boletas (no hace falta una decisión: el FIFO ya dice que el crédito va
-- entero a las boletas abiertas, y lo que sobra queda a favor).
--
-- =========================================================================
-- 4 · COB-b5 · 'cambio_de_cliente' SÓLO DESDE EL CAMBIO DE CLIENTE
-- =========================================================================
-- `cancelar_pedido_con_stock` con `p_tipo = 'cambio_de_cliente'` no aplica el
-- crédito: lo aplica `cambiar_cliente_pedido`, que la llama. Por llamada
-- directa (un admin) desimputaba los pagos y los dejaba sueltos. Ahora ese
-- tipo se rechaza salvo que quien llama sea `cambiar_cliente_pedido` (la pila
-- de llamadas, PG_CONTEXT: no hace falta tocar el cambio de cliente ni un GUC
-- que alguien pueda prender). El front no ofrece ese motivo al cancelar.
--
-- =========================================================================
-- 5 · SEG-1 · EL ROL DE QUIEN LLAMA, CON ACTIVO
-- =========================================================================
-- `cancelar_pedido_con_stock`, `crear_nota_credito_venta_impl`,
-- `marcar_pagos_masivo_impl` y `marcar_entrega_y_pago_masivo_impl` leían
-- `perfiles.rol` de quien llama sin mirar `activo` (los frenaba igual
-- `current_sucursal_id()`, NULL para un desactivado). Ahora la lectura lo mira.
-- `cancelar_pedido_con_stock` sale de scripts/rol-sin-activo-permitidas.json.
--
-- =========================================================================
-- 6 · 1559-b11 Y 1559-b12 · EL COBRO MASIVO TOCA Y CUENTA LO QUE COBRÓ
-- =========================================================================
-- `marcar_pagos_masivo_impl` escribía `pedidos.forma_pago` en todas las boletas
-- enviadas que no eran canceladas ni VB, también en las que ya estaban cobradas
-- (les pisaba la forma con la del lote), y devolvía cuántas tocó ese UPDATE.
-- Ahora escribe la forma sólo en las que cobró en este lote y devuelve cuántas
-- cobró: es lo que muestra el aviso (el front lo lee desde este PR).
--
-- =========================================================================
-- 7 · 1559-b14 · EL REPLAY DE UN COBRO COMPARA LO QUE SE COBRA
-- =========================================================================
-- `pago_solicitud_abrir` comparaba la operación y el usuario (#1440), no el
-- contenido: una clave reusada para otro monto u otro destino devolvía el
-- resultado del primero y no registraba nada. Ahora cada wrapper le pasa lo que
-- define el cobro (destino, montos y formas; los ids de un lote, ordenados), la
-- solicitud lo guarda (`pagos_solicitudes.contenido`) y un replay con otro
-- contenido se rechaza (22023). Queda afuera lo que puede cambiar entre un
-- intento y su reintento sin ser otro cobro: la fecha (el front la recalcula en
-- cada intento si no la eligió el usuario, y cruza la medianoche), las notas y
-- la referencia. El replay legítimo (mismo contenido) devuelve el resultado
-- guardado, como siempre. Una solicitud de antes de esta migración no tiene
-- contenido y su replay no se compara; tampoco el de un llamador que no lo
-- pasa (`imputar_credito_a_pedido`, de otra tarjeta: anda igual con la firma
-- nueva por el DEFAULT). Un PWA viejo llama a los mismos wrappers con los
-- mismos parámetros: no se entera.
--
-- =========================================================================
-- 8 · 1559-b16 Y 1558-b4 · DOS CHECKS NUEVOS EN auditoria_integridad()
-- =========================================================================
-- NC-A (high): el crédito de una NC son sus pagos (el que nace, sus pedazos y lo
-- que queda suelto, todos con su `nota_credito_id`): suman su total mientras
-- está vigente, y nada cuando está anulada (`anular_nota_credito_venta` los
-- borra). Un crédito de NC borrado a mano, o un pedazo perdido, lo pone rojo.
-- STK-G (high): STK-F mira sólo `UPDATE productos … stock = stock +`. STK-G mira
-- además el UPDATE con el esquema adelante y la asignación absoluta (stock igual
-- a una variable, o a una cuenta que no es una bajada pelada): toda escritura de
-- productos.stock que no sea `stock = stock - …` declara su origen. Hoy ninguna
-- función cae ahí (0 en la base de la tarjeta, con la huella de prod).
--
-- 1559-b15 (el FIFO de la ficha sin techo) no toca el server: decisión del dueño
-- D22 (en #1559), el pago a cuenta no tiene tope; la pantalla pide confirmar si
-- pasa el doble de la deuda (ModalRegistrarPago, en este PR).
--
-- Revertir: volver los cuerpos a los de la premisa, recrear
-- `pago_solicitud_abrir(uuid, text)` con su cuerpo de la premisa, borrar
-- `pago_solicitud_abrir(uuid, text, jsonb)` y `_credito_ventana`, y la columna
-- `pagos_solicitudes.contenido`.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

-- La única tabla que se altera (la columna de la sección 8): su lock va primero, de una y
-- sin esperar. Un ALTER TABLE toma ACCESS EXCLUSIVE hasta el COMMIT; tomado a mitad de la
-- transacción, contra un cobro que la usa, podía dar 40P01. Si no lo consigue al instante,
-- la migración falla y se reintenta.
LOCK TABLE public.pagos_solicitudes IN ACCESS EXCLUSIVE MODE NOWAIT;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos del 16/11 (ledger en la 512)
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public._aplicar_credito_pagos(bigint,bigint,bigint[])', '9d2ecc6fd85b14407c6c85f579508b15'),
    ('public._credito_bloquea_boletas(bigint,bigint,bigint,numeric)', 'f03af491f210255b49b03a2e27aa7118'),
    ('public.cancelar_pedido_con_stock(bigint,text,uuid,text)', '9101927774f8d3511ff7285fdf76af1d'),
    ('public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)', 'f26fe6cc33d11afb81a4ec5d574318a1'),
    ('public.marcar_pagos_masivo_impl(bigint[],text,date)', '7dfde9f7b5f42e8bb1214e3649e28e09'),
    ('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)', '08aa2a964a2395ae0400b01fd909d105'),
    ('public.pago_solicitud_abrir(uuid,text)', '8448a3629708a5b92d9db264ded848f3'),
    ('public.registrar_pagos_pedido(bigint,jsonb,date,text,text,uuid)', '03c630a479556a895b03d5349cd6ded9'),
    ('public.registrar_pago_cliente_fifo(bigint,numeric,text,date,text,text,uuid)', '459a35102a5bd7b04395876dc1b540a5'),
    ('public.registrar_pago_combinado_cliente_fifo(bigint,jsonb,date,text,text,uuid)', 'd721b8f0c4041879cdcadc60577f5f3c'),
    ('public.marcar_pagos_masivo(bigint[],text,date,uuid)', 'b36709a92574c543ef6e221c4844ad33'),
    ('public.marcar_entrega_y_pago_masivo(bigint[],uuid,text,date,uuid)', '9c04d7bc15d261cd7a9d5c6564161db2'),
    ('public.crear_nota_credito_venta(bigint,bigint,jsonb,text,text,uuid)', 'e1da42d326d89c58517baa6fd90381f6'),
    ('public.auditoria_integridad()', '089547f4be0fcd8ed8dfbe0c8f69f2d7'),
    ('public._alta_bloquea_boletas_credito(bigint,bigint)', '68fd4baf367b2074f95bb7be2ec97792'),
    ('public._edicion_bloquea_boletas(bigint,bigint)', '0175b260ba7a47c43026ea90653dccda'),
    ('public.pedidos_reconciliar_pagos()', '145659fa600f0c58e7a558b7c9957843'),
    -- No cambian, pero lo nuevo cuenta con ellas como están.
    ('public._credito_bloquea_rutas_y_creditos(bigint[],bigint,bigint,bigint)', '5345cfa5382a7e73bb43df8357af33b6'),
    ('public.aplicar_credito_cliente(bigint,bigint)', 'de9bc54d4198f7124e2c08b61b84fc63'),
    ('public.pago_solicitud_cerrar(uuid,jsonb)', 'cce9b25d3ab03276e3521ee0e30eb4b1')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;
  IF to_regproc('public._credito_ventana') IS NOT NULL
     OR to_regprocedure('public.pago_solicitud_abrir(uuid,text,jsonb)') IS NOT NULL
     OR EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.pagos_solicitudes'::regclass
                 AND attname = 'contenido' AND NOT attisdropped) THEN
    RAISE EXCEPTION 'mig NNN · _credito_ventana, la firma nueva de pago_solicitud_abrir o pagos_solicitudes.contenido ya existen: revisar a mano';
  END IF;
  -- Los wrappers que abren una solicitud son los siete de #1440: los seis de
  -- acá e imputar_credito_a_pedido (de otra tarjeta, que sigue con dos argumentos).
  IF (SELECT count(*) FROM pg_proc f
       WHERE f.pronamespace = 'public'::regnamespace AND f.proname <> 'pago_solicitud_abrir'
         AND f.prosrc ~ 'pago_solicitud_abrir\(') <> 7 THEN
    RAISE EXCEPTION 'mig NNN · pago_solicitud_abrir no tiene los 7 llamadores que se leyeron: revisar a mano';
  END IF;
END
$premisas$;

-- Reemplaza una sola aparición de un ancla en una definición.
CREATE FUNCTION pg_temp.parche(p_def text, p_ancla text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v_n int := (length(p_def) - length(replace(p_def, p_ancla, ''))) / length(p_ancla);
BEGIN
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · %: el ancla aparece % vez/veces y se esperaba 1', p_que, v_n;
  END IF;
  RETURN replace(p_def, p_ancla, p_nuevo);
END
$f$;

-- =========================================================================
-- 1 · La ventana de un crédito (COB-b2)
-- =========================================================================

-- Las boletas abiertas del cliente que p_plata alcanza a pagar en el orden del
-- FIFO (fecha, id), por id: aquellas cuya cola anterior debe menos que la plata.
-- p_creditos son los pagos (créditos) que se aplican, o que la pre-toma cuenta:
-- la boleta de una NC vigente de uno de ellos pesa 0 en la cola, porque el
-- crédito de esa NC no se le imputa (mig 283) y no la consume; si otro crédito
-- sí, contarla de menos sólo alarga la ventana. Sin un crédito de NC en
-- p_creditos, la ventana es la fórmula de antes. Crece con la plata y con los
-- créditos: una pre-toma que cuenta al menos lo que se aplica después toma al
-- menos lo que se toma después. p_sin es una boleta que no entra (la que se
-- cancela, o la propia de la NC o de la edición, que el llamador toma aparte).
-- Lee sin lock: la llaman antes del FOR UPDATE y otra vez después.
CREATE FUNCTION public._credito_ventana(p_cliente_id bigint, p_sucursal_id bigint, p_plata numeric,
                                        p_sin bigint, p_creditos bigint[])
RETURNS bigint[]
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
  WITH nc AS (
    SELECT ARRAY(SELECT DISTINCT n.pedido_id
                   FROM pagos pg
                   JOIN notas_credito_venta n ON n.id = pg.nota_credito_id
                  WHERE pg.id = ANY(p_creditos)
                    AND n.cliente_id = p_cliente_id
                    AND n.sucursal_id = p_sucursal_id
                    AND NOT n.anulada
                    AND n.pedido_id IS NOT NULL) AS ids
  ), b AS (
    SELECT p.id,
           sum(CASE WHEN p.id = ANY(nc.ids) THEN 0 ELSE p.total - COALESCE(p.monto_pagado, 0) END)
             OVER (ORDER BY p.fecha, p.id)
           - CASE WHEN p.id = ANY(nc.ids) THEN 0 ELSE p.total - COALESCE(p.monto_pagado, 0) END AS antes
      FROM pedidos p, nc
     WHERE p.cliente_id = p_cliente_id
       AND p.sucursal_id = p_sucursal_id
       AND p.id IS DISTINCT FROM p_sin
       AND p.estado NOT IN ('cancelado', 'anulado')
       AND p.total > COALESCE(p.monto_pagado, 0)
  )
  SELECT COALESCE(array_agg(b.id ORDER BY b.id), '{}'::bigint[])
    FROM b
   WHERE COALESCE(p_plata, 0) > 0.005
     AND b.antes < p_plata;
$function$;

REVOKE ALL ON FUNCTION public._credito_ventana(bigint, bigint, numeric, bigint, bigint[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._credito_ventana(bigint, bigint, numeric, bigint, bigint[]) TO service_role;

-- =========================================================================
-- 2 · _credito_bloquea_boletas: la ventana nueva y la segunda medida (COB-b1, COB-b2)
-- =========================================================================
DO $parche_bloquea$
DECLARE
  v_def text := pg_get_functiondef('public._credito_bloquea_boletas(bigint,bigint,bigint,numeric)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$    IF v_plata > 0.005 THEN
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
$a$,
$r$    -- COB-b2 (#1545): la ventana es una, _credito_ventana. Los creditos que se
    -- cuentan: los sueltos del cliente y los pagos de esta boleta (los que la
    -- cancelacion desimputa): la boleta de una NC de uno de ellos no pesa en la
    -- cola. Toma de mas, nunca de menos.
    v_alcanza := public._credito_ventana(
      p_cliente_id, p_sucursal_id, v_plata, p_pedido_id,
      ARRAY(SELECT pg.id FROM pagos pg
             WHERE pg.sucursal_id = p_sucursal_id
               AND ((pg.cliente_id = p_cliente_id AND pg.pedido_id IS NULL)
                    OR (p_pedido_id IS NOT NULL AND pg.pedido_id = p_pedido_id))));
  END IF;
$r$, '_credito_bloquea_boletas (la ventana)');

  v_def := pg_temp.parche(v_def,
$a$    ORDER BY id
      FOR UPDATE;

  RETURN v_alcanza;
$a$,
$r$    ORDER BY id
      FOR UPDATE;

  -- COB-b1 (#1545): la ventana se midio sin lock. Si un cobro a una boleta de la
  -- cola se espero en el FOR UPDATE de arriba, esa boleta ya debe menos y el
  -- credito llega mas lejos. Con las boletas tomadas se vuelve a medir, y las
  -- que falten se toman ahora (antes de los productos, las rutas y los
  -- creditos), hasta que no falte ninguna: cada vuelta suma al menos una.
  -- Se mide con lo que aplica esta operacion (#1538): su plata (p_plata_extra)
  -- y sus pagos. Un credito suelto que deja otra operacion en paralelo no lo
  -- aplica esta, y no agranda la segunda medida (revision, hallazgo 2).
  IF p_cliente_id IS NOT NULL AND COALESCE(p_plata_extra, 0) > 0.005 THEN
    LOOP
      v_faltan := ARRAY(SELECT x
                          FROM unnest(public._credito_ventana(
                                 p_cliente_id, p_sucursal_id, p_plata_extra, p_pedido_id,
                                 ARRAY(SELECT pg.id FROM pagos pg
                                        WHERE p_pedido_id IS NOT NULL
                                          AND pg.pedido_id = p_pedido_id
                                          AND pg.sucursal_id = p_sucursal_id))) x
                         WHERE x <> ALL (v_alcanza)
                         ORDER BY x);
      EXIT WHEN cardinality(v_faltan) = 0;
      PERFORM 1
         FROM pedidos
        WHERE id = ANY(v_faltan)
          AND sucursal_id = p_sucursal_id
        ORDER BY id
          FOR UPDATE;
      v_alcanza := v_alcanza || v_faltan;
    END LOOP;
  END IF;

  RETURN v_alcanza;
$r$, '_credito_bloquea_boletas (la segunda medida)');

  v_def := pg_temp.parche(v_def,
$a$  v_alcanza bigint[] := '{}';
$a$,
$r$  v_alcanza bigint[] := '{}';
  v_faltan  bigint[];
$r$, '_credito_bloquea_boletas (declare)');

  EXECUTE v_def;
END
$parche_bloquea$;

-- =========================================================================
-- 3 · _aplicar_credito_pagos: la ventana nueva y sin tope de 500 (COB-b2, 1595-b1)
-- =========================================================================
DO $parche_aplicar$
DECLARE
  v_def text := pg_get_functiondef('public._aplicar_credito_pagos(bigint,bigint,bigint[])'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$    v_alcanza := ARRAY(
      SELECT b.id
        FROM (SELECT p.id,
                     sum(p.total - COALESCE(p.monto_pagado, 0)) OVER (ORDER BY p.fecha, p.id)
                       - (p.total - COALESCE(p.monto_pagado, 0)) AS antes
                FROM pedidos p
               WHERE p.cliente_id = p_cliente_id
                 AND p.sucursal_id = p_sucursal_id
                 AND p.estado NOT IN ('cancelado', 'anulado')
                 AND p.total > COALESCE(p.monto_pagado, 0)) b
       WHERE b.antes < (SELECT sum(monto) FROM pagos
                         WHERE cliente_id = p_cliente_id
                           AND sucursal_id = p_sucursal_id
                           AND pedido_id IS NULL
                           AND (p_pagos IS NULL OR id = ANY(p_pagos))));
$a$,
$r$    -- COB-b2 (#1545): la ventana es una, _credito_ventana, con los creditos que
    -- se aplican: la boleta de la NC de uno de ellos no pesa en la cola (ese
    -- credito la saltea, abajo), asi que no corta la ventana antes de una boleta
    -- a la que el bucle si llega. Sin creditos de NC, la formula de antes.
    v_alcanza := public._credito_ventana(
      p_cliente_id, p_sucursal_id,
      (SELECT sum(monto) FROM pagos
        WHERE cliente_id = p_cliente_id
          AND sucursal_id = p_sucursal_id
          AND pedido_id IS NULL
          AND (p_pagos IS NULL OR id = ANY(p_pagos))),
      NULL,
      ARRAY(SELECT id FROM pagos
             WHERE cliente_id = p_cliente_id
               AND sucursal_id = p_sucursal_id
               AND pedido_id IS NULL
               AND (p_pagos IS NULL OR id = ANY(p_pagos))));
$r$, '_aplicar_credito_pagos (la ventana)');

  v_def := pg_temp.parche(v_def,
$a$      v_vueltas := v_vueltas + 1;
      EXIT WHEN v_vueltas > 500;  -- backstop, no deberia alcanzarse nunca
$a$,
$r$      -- 1595-b1 (#1595): sin tope de vueltas. Cortaba a las 500 boletas por
      -- credito y dejaba boletas abiertas con plata a favor. Cada vuelta paga una
      -- boleta entera o se queda sin credito, asi que el bucle termina solo; si la
      -- misma boleta vuelve, no bajo lo que debe, y se aborta con su motivo.
      v_vueltas := v_vueltas + 1;
      IF v_pedido.id IS NOT DISTINCT FROM v_ultima THEN
        RAISE EXCEPTION 'El credito % no se pudo aplicar: la boleta #% no bajo lo que debe despues de imputarle %',
          v_credito.id, v_pedido.id, v_aplicar
          USING ERRCODE = 'XX000';
      END IF;
      v_ultima := v_pedido.id;
$r$, '_aplicar_credito_pagos (sin tope)');

  v_def := pg_temp.parche(v_def,
$a$    v_vueltas  := 0;
$a$,
$r$    v_vueltas  := 0;
    v_ultima   := NULL;
$r$, '_aplicar_credito_pagos (la ultima por credito)');

  v_def := pg_temp.parche(v_def,
$a$  v_vueltas   integer;
$a$,
$r$  v_vueltas   integer;
  v_ultima    bigint;
$r$, '_aplicar_credito_pagos (declare)');

  EXECUTE v_def;
END
$parche_aplicar$;

-- =========================================================================
-- 3b · Las pre-tomas del alta, la edición y la baja de total usan la misma ventana
--      (COB-b2; revisión de la tarjeta, hallazgo 1)
-- =========================================================================
-- Cada una le pasa la plata y los créditos que cuenta, que contienen los que
-- después aplica _aplicar_credito_pagos: así lo que pre-toma contiene lo que se
-- toma después. Sin créditos de NC dan exactamente lo mismo que antes.
DO $parche_pretomas$
DECLARE
  v_def text;
BEGIN
  -- El alta y el bot: aplicar_credito_cliente aplica todos los créditos sueltos.
  v_def := pg_get_functiondef('public._alta_bloquea_boletas_credito(bigint,bigint)'::regprocedure);
  v_def := pg_temp.parche(v_def,
$a$  v_alcanza := ARRAY(
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
$a$,
$r$  -- COB-b2 (#1545): la ventana es una, _credito_ventana, con los creditos que
  -- aplica aplicar_credito_cliente (todos los sueltos del cliente).
  v_alcanza := public._credito_ventana(
    p_cliente_id, p_sucursal_id, v_credito, NULL,
    ARRAY(SELECT id FROM pagos
           WHERE cliente_id = p_cliente_id
             AND sucursal_id = p_sucursal_id
             AND pedido_id IS NULL));
$r$, '_alta_bloquea_boletas_credito (la ventana)');
  EXECUTE v_def;

  -- La edición: lo cobrado de la boleta (puede quedar a favor) y los sueltos.
  v_def := pg_get_functiondef('public._edicion_bloquea_boletas(bigint,bigint)'::regprocedure);
  v_def := pg_temp.parche(v_def,
$a$  v_alcanza := ARRAY(
    SELECT b.id
      FROM (SELECT p.id,
                   sum(p.total - COALESCE(p.monto_pagado, 0)) OVER (ORDER BY p.fecha, p.id)
                     - (p.total - COALESCE(p.monto_pagado, 0)) AS antes
              FROM pedidos p
             WHERE p.cliente_id = v_cliente
               AND p.sucursal_id = p_sucursal_id
               AND p.id <> p_pedido_id
               AND p.estado NOT IN ('cancelado', 'anulado')
               AND p.total > COALESCE(p.monto_pagado, 0)) b
     WHERE b.antes < v_plata);
$a$,
$r$  -- COB-b2 (#1545): la ventana es una, _credito_ventana, con los creditos que
  -- pueden aplicarse despues: los pagos de esta boleta (lo que puede quedar a
  -- favor al bajar el total) y los sueltos del cliente. Toma de mas, nunca de menos.
  v_alcanza := public._credito_ventana(
    v_cliente, p_sucursal_id, v_plata, p_pedido_id,
    ARRAY(SELECT pg.id FROM pagos pg
           WHERE pg.sucursal_id = p_sucursal_id
             AND ((pg.cliente_id = v_cliente AND pg.pedido_id IS NULL)
                  OR pg.pedido_id = p_pedido_id)));
$r$, '_edicion_bloquea_boletas (la ventana)');
  EXECUTE v_def;

  -- La baja de total (el trigger): el excedente que suelta esta boleta y los sueltos.
  v_def := pg_get_functiondef('public.pedidos_reconciliar_pagos()'::regprocedure);
  v_def := pg_temp.parche(v_def,
$a$    v_alcanza := ARRAY(
      SELECT b.id
        FROM (SELECT p.id,
                     sum(p.total - COALESCE(p.monto_pagado, 0)) OVER (ORDER BY p.fecha, p.id)
                       - (p.total - COALESCE(p.monto_pagado, 0)) AS antes
                FROM pedidos p
               WHERE p.cliente_id = NEW.cliente_id
                 AND p.sucursal_id = NEW.sucursal_id
                 AND p.estado NOT IN ('cancelado', 'anulado')
                 AND p.total > COALESCE(p.monto_pagado, 0)) b
       WHERE b.antes < v_plata) || NEW.id;
$a$,
$r$    -- COB-b2 (#1545): la ventana es una, _credito_ventana, con los creditos que
    -- pueden aplicarse despues: los pagos de esta boleta (v_pagos; el excedente
    -- sale de ellos) y los sueltos del cliente (v_sueltos).
    v_alcanza := public._credito_ventana(NEW.cliente_id, NEW.sucursal_id, v_plata, NULL,
                                         v_pagos || v_sueltos) || NEW.id;
$r$, 'pedidos_reconciliar_pagos (la ventana)');
  EXECUTE v_def;
END
$parche_pretomas$;

-- =========================================================================
-- 3c · cambiar_cliente_pedido usa la misma ventana (hallazgo 1)
-- =========================================================================
-- La función es de otra tarjeta (B3), que la parcha con premisa de md5: acá va
-- por ancla SIN premisa de md5 (falla si el ancla no está; la poscondición
-- comprueba que entró), y sólo cambia el cálculo de sus dos ventanas.
DO $parche_cambio_cliente$
DECLARE
  v_def text := pg_get_functiondef('public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$    v_alcanza := v_alcanza || ARRAY(
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
$a$,
$r$    -- COB-b2 (#1545): la ventana es una, _credito_ventana, con los creditos del
    -- cliente nuevo y los pagos de X (los que viajan con 'pedido_nuevo').
    v_alcanza := v_alcanza || public._credito_ventana(
      p_nuevo_cliente_id, v_sucursal, v_plata, NULL,
      ARRAY(SELECT pg.id FROM pagos pg
             WHERE pg.sucursal_id = v_sucursal
               AND ((pg.cliente_id = p_nuevo_cliente_id AND pg.pedido_id IS NULL)
                    OR pg.pedido_id = p_pedido_id)));
$r$, 'cambiar_cliente_pedido (la ventana del cliente nuevo)');

  v_def := pg_temp.parche(v_def,
$a$    v_alcanza := v_alcanza || ARRAY(
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
$a$,
$r$    -- COB-b2 (#1545): la ventana es una, _credito_ventana, con los creditos del
    -- cliente original y los pagos de X (los que le vuelven).
    v_alcanza := v_alcanza || public._credito_ventana(
      v_cliente_viejo, v_sucursal, v_plata_viejo, p_pedido_id,
      ARRAY(SELECT pg.id FROM pagos pg
             WHERE pg.sucursal_id = v_sucursal
               AND ((pg.cliente_id = v_cliente_viejo AND pg.pedido_id IS NULL)
                    OR pg.pedido_id = p_pedido_id)));
$r$, 'cambiar_cliente_pedido (la ventana del cliente original)');

  EXECUTE v_def;
END
$parche_cambio_cliente$;

-- =========================================================================
-- 4 · cancelar_pedido_con_stock (SEG-1, COB-b5, COB-b1)
-- =========================================================================
DO $parche_cancelar$
DECLARE
  v_def text := pg_get_functiondef('public.cancelar_pedido_con_stock(bigint,text,uuid,text)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_acting_user;
  IF v_user_role IS NULL OR v_user_role <> 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin puede cancelar pedidos');
  END IF;
$a$,
$r$  -- SEG-1 (#1545): un desactivado no tiene rol aunque su token siga vivo.
  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_acting_user AND COALESCE(activo, true);
  IF v_user_role IS NULL OR v_user_role <> 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin puede cancelar pedidos');
  END IF;

  -- COB-b5 (#1545): con 'cambio_de_cliente' la cancelacion desimputa los pagos y
  -- no aplica el credito, porque lo aplica cambiar_cliente_pedido, que la llama.
  -- Por llamada directa los dejaba sueltos: ese tipo lo pone solo el cambio de
  -- cliente. Se mira quien llama en la pila (PG_CONTEXT): la linea 2 es el
  -- llamador directo.
  IF p_tipo = 'cambio_de_cliente' THEN
    GET DIAGNOSTICS v_ctx = PG_CONTEXT;
    IF split_part(v_ctx, E'\n', 2) !~ '^PL/pgSQL function (public\.)?cambiar_cliente_pedido\(' THEN
      RETURN jsonb_build_object('success', false, 'error',
        'El motivo «cambio de cliente» lo pone el cambio de cliente del pedido. Para cancelarlo, elegí otro motivo.');
    END IF;
  END IF;
$r$, 'cancelar_pedido_con_stock (rol y cambio de cliente)');

  v_def := pg_temp.parche(v_def,
$a$  v_total_original := v_pedido.total;
$a$,
$r$  -- COB-b1 (#1545): lo cobrado se leyo arriba sin lock. Un cobro que se espero en
  -- el FOR UPDATE de la boleta lo cambia, y con mas plata a favor el credito
  -- alcanza boletas que no se tomaron. Se relee con la boleta tomada y, si es
  -- mas, se toman ya las boletas que alcanza: antes de los productos, las rutas
  -- y los creditos.
  IF v_aplica_credito AND v_pedido.cliente_id IS NOT NULL THEN
    v_cobrado_fresco := COALESCE((SELECT sum(monto) FROM pagos
                                   WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal), 0);
    IF v_cobrado_fresco > 0.005
       AND (v_boletas IS NULL OR v_cobrado_fresco > v_cobrado + 0.005
            OR v_pedido.cliente_id IS DISTINCT FROM v_cliente_id) THEN
      v_boletas := public._credito_bloquea_boletas(p_pedido_id, v_pedido.cliente_id, v_sucursal, v_cobrado_fresco);
    END IF;
  END IF;

  v_total_original := v_pedido.total;
$r$, 'cancelar_pedido_con_stock (lo cobrado, con la boleta tomada)');

  v_def := pg_temp.parche(v_def,
$a$  v_pagos_liberados BIGINT[];
BEGIN
$a$,
$r$  v_pagos_liberados BIGINT[];
  v_ctx TEXT;
  v_cobrado_fresco NUMERIC;
BEGIN
$r$, 'cancelar_pedido_con_stock (declare)');

  EXECUTE v_def;
END
$parche_cancelar$;

-- =========================================================================
-- 5 · crear_nota_credito_venta_impl (SEG-1, COB-b1)
-- =========================================================================
DO $parche_nc$
DECLARE
  v_def text := pg_get_functiondef('public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  SELECT rol INTO v_rol FROM perfiles WHERE id = v_user;
$a$,
$r$  -- SEG-1 (#1545): un desactivado no tiene rol aunque su token siga vivo.
  SELECT rol INTO v_rol FROM perfiles WHERE id = v_user AND COALESCE(activo, true);
$r$, 'crear_nota_credito_venta_impl (rol)');

  v_def := pg_temp.parche(v_def,
$a$    v_boletas := public._credito_bloquea_boletas(p_pedido_id, p_cliente_id, v_sucursal,
                                                 GREATEST(v_estimado - v_falta, 0));
$a$,
$r$    v_extra := GREATEST(v_estimado - v_falta, 0);
    v_boletas := public._credito_bloquea_boletas(p_pedido_id, p_cliente_id, v_sucursal, v_extra);
$r$, 'crear_nota_credito_venta_impl (lo que sobra, estimado)');

  v_def := pg_temp.parche(v_def,
$a$  PERFORM public._credito_bloquea_rutas_y_creditos(COALESCE(v_boletas, ARRAY[p_pedido_id]),
$a$,
$r$  -- COB-b1 (#1545): lo que falta de la boleta y el total de la NC se estimaron
  -- arriba sin lock. Un cobro que se espero en el FOR UPDATE de la boleta baja lo
  -- que falta, y lo que sobra de la NC llega mas lejos. Con la boleta tomada se
  -- mide de nuevo y, si sobra mas, se toman ya las boletas que alcanza.
  SELECT GREATEST(total - COALESCE(monto_pagado, 0), 0)
    INTO v_falta
    FROM pedidos
   WHERE id = p_pedido_id;
  IF GREATEST(v_total - v_falta, 0) > v_extra + 0.005 THEN
    v_boletas := public._credito_bloquea_boletas(p_pedido_id, p_cliente_id, v_sucursal,
                                                 GREATEST(v_total - v_falta, 0));
  END IF;

  PERFORM public._credito_bloquea_rutas_y_creditos(COALESCE(v_boletas, ARRAY[p_pedido_id]),
$r$, 'crear_nota_credito_venta_impl (lo que sobra, con la boleta tomada)');

  v_def := pg_temp.parche(v_def,
$a$  v_guc       text;
BEGIN
$a$,
$r$  v_guc       text;
  v_extra     numeric := 0;
BEGIN
$r$, 'crear_nota_credito_venta_impl (declare)');

  EXECUTE v_def;
END
$parche_nc$;

-- =========================================================================
-- 6 · marcar_pagos_masivo_impl (SEG-1, 1559-b11, 1559-b12)
-- =========================================================================
DO $parche_masivo$
DECLARE
  v_def text := pg_get_functiondef('public.marcar_pagos_masivo_impl(bigint[],text,date)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();
$a$,
$r$  -- SEG-1 (#1545): un desactivado no tiene rol aunque su token siga vivo.
  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid() AND COALESCE(activo, true);
$r$, 'marcar_pagos_masivo_impl (rol)');

  v_def := pg_temp.parche(v_def,
$a$      v_sucursal_id
    );
  END LOOP;
$a$,
$r$      v_sucursal_id
    );
    v_cobrados := v_cobrados || v_pedido.id;
  END LOOP;
$r$, 'marcar_pagos_masivo_impl (lo cobrado)');

  v_def := pg_temp.parche(v_def,
$a$  UPDATE pedidos
     SET forma_pago = p_forma_pago,
         updated_at = now()
   WHERE id = ANY(p_pedido_ids)
     AND sucursal_id = v_sucursal_id
     AND COALESCE(estado, '') NOT IN ('cancelado', 'anulado')
     AND COALESCE(tipo_factura, 'ZZ') <> 'VB';  -- mig 3XA

  GET DIAGNOSTICS v_affected = ROW_COUNT;
  RETURN v_affected;
$a$,
$r$  -- 1559-b11 (#1559): la forma de pago va solo en las boletas que este lote
  -- cobro. Antes iba en todas las enviadas, y a una ya cobrada le pisaba la forma
  -- con la del lote.
  UPDATE pedidos
     SET forma_pago = p_forma_pago,
         updated_at = now()
   WHERE id = ANY(v_cobrados)
     AND sucursal_id = v_sucursal_id;

  -- 1559-b12 (#1559): cuantas cobro, no cuantas toco el UPDATE: es lo que dice
  -- el aviso del cobro masivo.
  RETURN cardinality(v_cobrados);
$r$, 'marcar_pagos_masivo_impl (la forma y el conteo)');

  v_def := pg_temp.parche(v_def,
$a$  v_rol TEXT;
BEGIN
$a$,
$r$  v_rol TEXT;
  v_cobrados BIGINT[] := '{}';
BEGIN
$r$, 'marcar_pagos_masivo_impl (declare)');

  EXECUTE v_def;
END
$parche_masivo$;

-- =========================================================================
-- 7 · marcar_entrega_y_pago_masivo_impl (SEG-1)
-- =========================================================================
DO $parche_entrega_masiva$
DECLARE
  v_def text := pg_get_functiondef('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();
$a$,
$r$  -- SEG-1 (#1545): un desactivado no tiene rol aunque su token siga vivo.
  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid() AND COALESCE(activo, true);
$r$, 'marcar_entrega_y_pago_masivo_impl (rol)');

  EXECUTE v_def;
END
$parche_entrega_masiva$;

-- =========================================================================
-- 8 · La solicitud de un cobro guarda y compara su contenido (1559-b14)
-- =========================================================================
ALTER TABLE public.pagos_solicitudes ADD COLUMN contenido jsonb;
COMMENT ON COLUMN public.pagos_solicitudes.contenido IS
  'Lo que define el cobro de la solicitud (destino, montos y formas): un replay con otro contenido se rechaza (#1559, 1559-b14). NULL en las de antes y en los llamadores que no lo pasan.';

CREATE FUNCTION public.pago_solicitud_abrir(p_client_request_id uuid, p_operacion text, p_contenido jsonb DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_previa pagos_solicitudes%ROWTYPE;
BEGIN
  IF p_client_request_id IS NULL THEN
    RETURN NULL;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_client_request_id::text, 0));

  SELECT * INTO v_previa
    FROM pagos_solicitudes
   WHERE client_request_id = p_client_request_id;

  IF FOUND THEN
    -- #1440: el replay es de la misma solicitud, la misma operacion del mismo
    -- usuario. Una clave que ya uso otra no es un reintento: devolverle ese
    -- resultado le haria creer que entro, y no entraria nada. La sucursal no se
    -- compara: es la activa de la pantalla (el front manda X-Sucursal-ID en cada
    -- request), y si el usuario la cambia entre el intento y el reintento, sigue
    -- siendo el mismo cobro.
    IF v_previa.operacion IS DISTINCT FROM p_operacion
       OR v_previa.usuario_id IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION 'La clave % ya es de otra solicitud: no se registró nada', p_client_request_id
        USING ERRCODE = '22023',
              DETAIL = format('Se guardó para %s%s; esta es %s.',
                              v_previa.operacion,
                              CASE WHEN v_previa.usuario_id IS DISTINCT FROM auth.uid()
                                   THEN ', de otro usuario' ELSE '' END,
                              p_operacion);
    END IF;

    -- 1559-b14 (#1559): y el mismo cobro. Con otro destino u otro monto la clave
    -- no es un reintento: el resultado guardado es el de otro cobro. Lo que el
    -- reintento puede cambiar sin ser otro cobro (la fecha, las notas, la
    -- referencia) no entra en el contenido. Sin contenido de un lado (una
    -- solicitud de antes de la NNN, o un llamador que no lo pasa) no se compara.
    IF v_previa.contenido IS NOT NULL AND p_contenido IS NOT NULL
       AND v_previa.contenido IS DISTINCT FROM p_contenido THEN
      RAISE EXCEPTION 'La clave % ya se usó para otro cobro, con otro monto o destino: no se registró nada', p_client_request_id
        USING ERRCODE = '22023',
              DETAIL = 'Un reintento repite el mismo cobro; un cobro distinto lleva una clave nueva.';
    END IF;

    -- resultado NULL solo puede pasar si la ejecucion original quedo a medias sin
    -- abortar la transaccion (no deberia ocurrir: un error revierte tambien esta
    -- fila). Se deja seguir para no dejar el pago sin registrar por un ledger raro.
    RETURN v_previa.resultado;
  END IF;

  INSERT INTO pagos_solicitudes (client_request_id, operacion, usuario_id, sucursal_id, contenido)
  VALUES (p_client_request_id, p_operacion, auth.uid(), current_sucursal_id(), p_contenido);

  RETURN NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public.pago_solicitud_abrir(uuid, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pago_solicitud_abrir(uuid, text, jsonb) TO service_role;

-- Una sola firma: con las dos, una llamada de dos argumentos es ambigua.
DROP FUNCTION public.pago_solicitud_abrir(uuid, text);

-- Cada wrapper pasa lo que define su cobro.
DO $parche_wrappers$
DECLARE
  r record;
  v_def text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.registrar_pagos_pedido(bigint,jsonb,date,text,text,uuid)',
     $a$pago_solicitud_abrir(p_client_request_id, 'registrar_pagos_pedido')$a$,
     $r$pago_solicitud_abrir(p_client_request_id, 'registrar_pagos_pedido',
    -- 1559-b14 (#1559): lo que define el cobro (no la fecha, las notas ni la referencia).
    jsonb_build_object('pedido_id', p_pedido_id, 'metodos', p_metodos))$r$),
    ('public.registrar_pago_cliente_fifo(bigint,numeric,text,date,text,text,uuid)',
     $a$pago_solicitud_abrir(p_client_request_id, 'registrar_pago_cliente_fifo')$a$,
     $r$pago_solicitud_abrir(p_client_request_id, 'registrar_pago_cliente_fifo',
    -- 1559-b14 (#1559): lo que define el cobro (no la fecha, las notas ni la referencia).
    -- El monto como texto: un 'NaN' no entra en un jsonb y lo rechaza el _impl.
    jsonb_build_object('cliente_id', p_cliente_id, 'monto', p_monto::text, 'forma_pago', p_forma_pago))$r$),
    ('public.registrar_pago_combinado_cliente_fifo(bigint,jsonb,date,text,text,uuid)',
     $a$pago_solicitud_abrir(p_client_request_id, 'registrar_pago_combinado_cliente_fifo')$a$,
     $r$pago_solicitud_abrir(p_client_request_id, 'registrar_pago_combinado_cliente_fifo',
    -- 1559-b14 (#1559): lo que define el cobro (no la fecha, las notas ni la referencia).
    jsonb_build_object('cliente_id', p_cliente_id, 'metodos', p_metodos))$r$),
    ('public.marcar_pagos_masivo(bigint[],text,date,uuid)',
     $a$pago_solicitud_abrir(p_client_request_id, 'marcar_pagos_masivo')$a$,
     $r$pago_solicitud_abrir(p_client_request_id, 'marcar_pagos_masivo',
    -- 1559-b14 (#1559): lo que define el cobro: los ids ordenados (el lote es un
    -- conjunto) y la forma; no la fecha.
    jsonb_build_object('pedido_ids', to_jsonb(ARRAY(SELECT DISTINCT x FROM unnest(p_pedido_ids) x ORDER BY 1)),
                       'forma_pago', p_forma_pago))$r$),
    ('public.marcar_entrega_y_pago_masivo(bigint[],uuid,text,date,uuid)',
     $a$pago_solicitud_abrir(p_client_request_id, 'marcar_entrega_y_pago_masivo')$a$,
     $r$pago_solicitud_abrir(p_client_request_id, 'marcar_entrega_y_pago_masivo',
    -- 1559-b14 (#1559): lo que define el cobro: los ids ordenados (el lote es un
    -- conjunto), el chofer y la forma; no la fecha.
    jsonb_build_object('pedido_ids', to_jsonb(ARRAY(SELECT DISTINCT x FROM unnest(p_pedido_ids) x ORDER BY 1)),
                       'transportista_id', p_transportista_id, 'forma_pago', p_forma_pago))$r$),
    ('public.crear_nota_credito_venta(bigint,bigint,jsonb,text,text,uuid)',
     $a$pago_solicitud_abrir(p_client_request_id, 'crear_nota_credito_venta')$a$,
     $r$pago_solicitud_abrir(p_client_request_id, 'crear_nota_credito_venta',
    -- 1559-b14 (#1559): lo que define la nota (no las observaciones).
    jsonb_build_object('pedido_id', p_pedido_id, 'cliente_id', p_cliente_id, 'items', p_items, 'motivo', p_motivo))$r$)
  ) AS t(f, ancla, nuevo) LOOP
    v_def := pg_get_functiondef(r.f::regprocedure);
    v_def := pg_temp.parche(v_def, r.ancla, r.nuevo, r.f);
    EXECUTE v_def;
  END LOOP;
END
$parche_wrappers$;

-- Cinco de esos wrappers están en la lista blanca de SEG-A (auditoria_definer_sin_rol)
-- por su md5: cambian sólo los md5, la razón de la lista sigue (el rol lo exige el
-- _impl). Por ancla y sin premisa de md5 de la función: otras tarjetas le suman líneas.
DO $parche_lista_seg_a$
DECLARE
  r record;
  v_def text := pg_get_functiondef('public.auditoria_definer_sin_rol()'::regprocedure);
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('registrar_pago_cliente_fifo', '459a35102a5bd7b04395876dc1b540a5', '728ea65bf5a8363c6a9b3f254f299323'),
    ('registrar_pago_combinado_cliente_fifo', 'd721b8f0c4041879cdcadc60577f5f3c', '8497c398845f786dfbcff897d68acba0'),
    ('marcar_pagos_masivo', 'b36709a92574c543ef6e221c4844ad33', '1f13baa2aaba49f787c2198fb774e586'),
    ('marcar_entrega_y_pago_masivo', '9c04d7bc15d261cd7a9d5c6564161db2', '5d5c3c45a0bc16cbf52ecce8963a1687'),
    ('crear_nota_credito_venta', 'e1da42d326d89c58517baa6fd90381f6', 'e92f59da39844598b948b7da652977a0')
  ) AS t(f, viejo, nuevo) LOOP
    v_def := pg_temp.parche(v_def, '''' || r.viejo || '''', '''' || r.nuevo || '''',
                            'auditoria_definer_sin_rol (' || r.f || ')');
  END LOOP;
  EXECUTE v_def;
END
$parche_lista_seg_a$;

-- =========================================================================
-- 9 · auditoria_integridad: NC-A y STK-G (1559-b16, 1558-b4)
-- =========================================================================
DO $parche_auditoria$
DECLARE
  v_def text := pg_get_functiondef('public.auditoria_integridad()'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$    ('STK-F','high','funciones de public que suben stock sin declarar app.stock_origen (mig 229)',
      (SELECT public.auditoria_funciones_stock_sin_origen())),
$a$,
$r$    ('STK-F','high','funciones de public que suben stock sin declarar app.stock_origen (mig 229)',
      (SELECT public.auditoria_funciones_stock_sin_origen())),
    -- 1558-b4 (#1558) · STK-F mira solo el UPDATE de productos sin esquema y la
    -- subida incremental. Esto mira ademas el UPDATE con el esquema adelante y la
    -- asignacion absoluta (stock igual a una variable o a una cuenta): toda
    -- escritura de productos.stock que no sea una bajada pelada declara su origen.
    ('STK-G','high','funciones de public que escriben productos.stock (con el esquema adelante o una asignación absoluta) sin declarar app.stock_origen (#1558)',
      (SELECT count(*) FROM pg_proc f
        WHERE f.pronamespace = 'public'::regnamespace
          AND f.prokind = 'f'
          AND pg_get_functiondef(f.oid) ~* 'UPDATE\s+(public\.)?productos\s+(AS\s+)?(\w+\s+)?SET\s((?!\ywhere\y)[^;])*\ystock\s*=\s*(?!\(?\s*(\w+\.)?stock\s*-)'
          AND pg_get_functiondef(f.oid) NOT LIKE '%app.stock_origen%')),
    -- 1559-b16 (#1559) · el credito de una NC son sus pagos (el que nace, sus
    -- pedazos y lo que queda suelto, con su nota_credito_id): suman su total
    -- mientras esta vigente, y nada cuando esta anulada (la anulacion los borra).
    ('NC-A','high','notas de crédito de venta cuyo crédito (Σ pagos con su nota_credito_id) no es su total, o anuladas con crédito vivo (#1559)',
      (SELECT count(*) FROM notas_credito_venta n
         CROSS JOIN LATERAL (SELECT COALESCE(sum(pg.monto), 0) AS s
                               FROM pagos pg WHERE pg.nota_credito_id = n.id) c
        WHERE abs(c.s - CASE WHEN n.anulada THEN 0 ELSE n.total END) > 0.01)),
$r$, 'auditoria_integridad (STK-G y NC-A)');

  EXECUTE v_def;
END
$parche_auditoria$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos son los del repo, con sus permisos
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public._credito_ventana(bigint,bigint,numeric,bigint,bigint[])', '907d16cbb39e0d11a4a2babf4af3c0f4', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._credito_bloquea_boletas(bigint,bigint,bigint,numeric)', 'cf1f4efe95a5ceba68fb5826062a82cb', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._aplicar_credito_pagos(bigint,bigint,bigint[])', '0c77f1627f4d35eb6e0f13b7363deb89', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._alta_bloquea_boletas_credito(bigint,bigint)', '98d85358a89abd8bf7a2499c05a80ce0', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._edicion_bloquea_boletas(bigint,bigint)', '572aca247f18d932b7f9cb784d0a47a9', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.pedidos_reconciliar_pagos()', 'a3b6d6df375879902a715c2ec9cf6ca6', true,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.cancelar_pedido_con_stock(bigint,text,uuid,text)', 'c4685911513e2f491b184454d6a51e33', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)', 'a58b4f71752f8b004fbc3c524b12be8b', true,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.marcar_pagos_masivo_impl(bigint[],text,date)', 'd3a11592bf22f97275b9bd98ece355b7', true,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)', '23c0298ccce785a11810184312597739', true,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.pago_solicitud_abrir(uuid,text,jsonb)', '6af999166ce5fde5479b9ca10444d7a5', true,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.registrar_pagos_pedido(bigint,jsonb,date,text,text,uuid)', '4ba5827629e9b48bf1fe72da2b1cebbb', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.registrar_pago_cliente_fifo(bigint,numeric,text,date,text,text,uuid)', '728ea65bf5a8363c6a9b3f254f299323', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.registrar_pago_combinado_cliente_fifo(bigint,jsonb,date,text,text,uuid)', '8497c398845f786dfbcff897d68acba0', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.marcar_pagos_masivo(bigint[],text,date,uuid)', '1f13baa2aaba49f787c2198fb774e586', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.marcar_entrega_y_pago_masivo(bigint[],uuid,text,date,uuid)', '5d5c3c45a0bc16cbf52ecce8963a1687', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.crear_nota_credito_venta(bigint,bigint,jsonb,text,text,uuid)', 'e92f59da39844598b948b7da652977a0', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.auditoria_integridad()', '04947c172779be50815c29f77b9511e4', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}')
  ) AS t(f, h, def, acl) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO x
      FROM pg_proc WHERE oid = r.f::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.def IS DISTINCT FROM r.def
       OR x.a IS DISTINCT FROM r.acl THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %)', r.f, x.h, x.a, x.def;
    END IF;
  END LOOP;
  -- La ventana es una (hallazgo 1): cambiar_cliente_pedido la usa en sus dos
  -- ventanas, y ninguna función de public fuera de _credito_ventana calcula la
  -- cola a mano.
  IF (SELECT (length(prosrc) - length(replace(prosrc, '_credito_ventana(', ''))) / length('_credito_ventana(')
        FROM pg_proc
       WHERE oid = 'public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)'::regprocedure) <> 2 THEN
    RAISE EXCEPTION 'mig NNN · cambiar_cliente_pedido no quedó con sus dos ventanas en _credito_ventana';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc f
              WHERE f.pronamespace = 'public'::regnamespace
                AND f.proname <> '_credito_ventana'
                AND f.prosrc ~ 'OVER \(ORDER BY p\.fecha, p\.id\)') THEN
    RAISE EXCEPTION 'mig NNN · quedó una ventana de crédito calculada a mano: %',
      (SELECT string_agg(f.oid::regprocedure::text, ', ') FROM pg_proc f
        WHERE f.pronamespace = 'public'::regnamespace AND f.proname <> '_credito_ventana'
          AND f.prosrc ~ 'OVER \(ORDER BY p\.fecha, p\.id\)');
  END IF;
  -- SEG-A no marca ninguna de las funciones que tocó esta migración.
  IF EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol() a
              WHERE a::text ~ '(registrar_pago_cliente_fifo|registrar_pago_combinado_cliente_fifo|marcar_pagos_masivo|marcar_entrega_y_pago_masivo|crear_nota_credito_venta|registrar_pagos_pedido|cancelar_pedido_con_stock)\(') THEN
    RAISE EXCEPTION 'mig NNN · SEG-A marca un wrapper de cobro de esta migración';
  END IF;
  IF to_regprocedure('public.pago_solicitud_abrir(uuid,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · la firma vieja de pago_solicitud_abrir sigue viva';
  END IF;
  IF has_column_privilege('authenticated', 'public.pagos_solicitudes', 'contenido', 'SELECT')
     OR has_column_privilege('anon', 'public.pagos_solicitudes', 'contenido', 'SELECT') THEN
    RAISE EXCEPTION 'mig NNN · pagos_solicitudes.contenido quedó legible por REST: es de server';
  END IF;
END
$post$;

COMMIT;
