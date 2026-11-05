-- 457 · La edición que cambia el total toma las otras boletas y los créditos antes que el cliente (#1446).
--
-- QUÉ PASABA
--   Un UPDATE OF total de una boleta X (actualizar_pedido_items, una salvedad, cualquier camino
--   que cambie el total) disparaba sus triggers AFTER en orden alfabético:
--     trigger_actualizar_recorrido_entrega  → las rutas de X;
--     trigger_actualizar_saldo_pedido       → el cliente (clientes.saldo_cuenta);
--     zzz_pedidos_reconciliar_pagos         → los pagos de X (desafectar_sobrepago_pedido), y
--                                             las otras boletas que los créditos pagan y los
--                                             créditos (aplicar_credito_cliente).
--   El cliente quedaba tomado antes que las otras boletas y que los créditos. Un camino que toma
--   otra boleta Y del mismo cliente, o uno de sus créditos, y después el cliente (imputar un
--   crédito a Y, el cobro suelto de Y) se cruzaba con la edición: 40P01, sin datos rotos.
--   Y X se tomaba antes que las otras boletas: el caller la bloquea al entrar, y el trigger llega a
--   Y después. Con Y de id menor, un FIFO (que desde la 454 toma las boletas del cliente por id:
--   Y, X) también se cruzaba, aunque el cliente ya no estuviera en el medio.
--   Medido en el arnés (scripts/concurrencia, claves t10r y t13): ver #1446.
--
-- QUÉ CAMBIA (sólo el orden de los locks)
--   · El trigger se llama trg_pedidos_reconciliar_pagos: los AFTER corren en orden de nombre, y
--     así corre antes que el de las rutas y que el del saldo. El zzz_ era para correr "cuando
--     trigger_actualizar_saldo_pedido ya contabilizó el cambio de total" (165), pero el saldo es
--     un delta (contrib nueva − contrib vieja de cada UPDATE, en los dos triggers de saldo) y
--     nada de la reconciliación lee saldo_cuenta: el saldo final es el mismo en cualquier orden.
--     Los contadores de la ruta son un recálculo: el último ve el estado final, como antes.
--   · pedidos_reconciliar_pagos, antes de desafectar y de aplicar, si el cliente tiene créditos
--     o a X le sobra lo cobrado: las boletas que esa plata alcanza a pagar en el orden de
--     aplicar_credito_cliente (fecha, id), con X, por id; sus recorridos por id, y los créditos
--     y los pagos de X por id. Es el orden global (pedidos → recorridos → paradas → pagos), y el
--     cliente queda para el final. El excedente se cuenta entero aunque desafectar recorte una
--     parte en vez de dejarla a favor: toma de más, nunca de menos. Sin créditos ni excedente no
--     toma nada, como antes.
--   · actualizar_pedido_items, registrar_salvedad, anular_salvedad y cambiar_tipo_factura_pedido
--     (pasar a vale blanco lleva el total a costo), justo antes de su lock de X, llaman a
--     _edicion_bloquea_boletas (nueva, de server): X y las otras boletas del cliente
--     que los créditos más todo lo cobrado de X alcanzan a pagar, juntas y por id. El total nuevo
--     todavía no se sabe, así que la cota es lo cobrado entero: el conjunto contiene al que piden
--     después el trigger y aplicar_credito_cliente. Sin plata a favor posible no toma nada.
--
-- QUÉ NO CAMBIA
--   Qué se recorta, se imputa o a qué boleta, el saldo, las firmas y los EXECUTE de lo que ya
--   existía. desafectar_sobrepago_pedido y aplicar_credito_cliente no se tocan (son de #1419 y de
--   la 454). Con esos cuatro, todo UPDATE de pedidos.total de public pasa por el pre-bloqueo: el
--   quinto es cancelar_pedido_con_stock, que deja la boleta cancelada y el trigger no corre. Un
--   camino nuevo que cambie el total llama a _edicion_bloquea_boletas antes de tomar la boleta.
--
-- Ensayo: scripts/test-edicion-creditos-1446.sql (corre en prod sin dejar rastro).
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
-- Premisas: el cuerpo vivo y el trigger son los que se leyeron de prod (04/11)
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, md5(p.prosrc) AS md5_vivo
      FROM (VALUES
        ('public.pedidos_reconciliar_pagos()',                                                        'e01f951d2540f5501b6356b4202193b0'),
        ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)',           'd7a6bc26ac5d93200272f5054de7e359'),
        ('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)', '34200d1a3d6f4e1b924f467a65907bb9'),
        ('public.anular_salvedad(bigint,text)',                                                       '11d1a95187777baa4ea31c29afda9a8b'),
        ('public.cambiar_tipo_factura_pedido(bigint,character varying,uuid)',                         '28d8f465e38957608f4ce53837b98ade')
      ) AS x(firma, md5)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION 'mig 457 · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;

  IF to_regprocedure('public._edicion_bloquea_boletas(bigint,bigint)') IS NOT NULL THEN
    RAISE EXCEPTION 'mig 457 · _edicion_bloquea_boletas ya existe';
  END IF;

  IF (SELECT pg_get_triggerdef(oid) FROM pg_trigger
       WHERE tgrelid = 'public.pedidos'::regclass AND tgname = 'zzz_pedidos_reconciliar_pagos')
     IS DISTINCT FROM 'CREATE TRIGGER zzz_pedidos_reconciliar_pagos AFTER UPDATE OF total ON public.pedidos FOR EACH ROW WHEN (((new.total IS DISTINCT FROM old.total) AND (new.estado <> ALL (ARRAY[''cancelado''::text, ''anulado''::text])))) EXECUTE FUNCTION pedidos_reconciliar_pagos()' THEN
    RAISE EXCEPTION 'mig 457 · el trigger zzz_pedidos_reconciliar_pagos cambió en prod desde que se leyó';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_trigger
              WHERE tgrelid = 'public.pedidos'::regclass AND tgname = 'trg_pedidos_reconciliar_pagos') THEN
    RAISE EXCEPTION 'mig 457 · trg_pedidos_reconciliar_pagos ya existe';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- pedidos_reconciliar_pagos: el pre-bloqueo
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pedidos_reconciliar_pagos()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_excedente numeric;
  v_plata     numeric;
  v_alcanza   bigint[];
BEGIN
  -- Defensa contra reentrada. En la practica no se alcanza (las cascadas internas
  -- actualizan monto_pagado, no total), pero el trigger toca pagos y no conviene
  -- depender de eso.
  IF current_setting('app.reimputacion_pagos', true) = 'on' THEN
    RETURN NULL;
  END IF;

  -- #1446: el orden global antes del primer lock de desafectar y de aplicar. Este
  -- trigger corre antes que el del saldo (por el nombre), asi que el cliente queda
  -- para el final. Si el cliente tiene creditos o a la boleta le sobra lo cobrado:
  -- las boletas que esa plata alcanza a pagar en el orden de aplicar_credito_cliente
  -- (fecha, id), con esta, por id; sus recorridos por id, y los creditos y los pagos
  -- de esta boleta por id. El excedente cuenta entero aunque desafectar recorte una
  -- parte: toma de mas, nunca de menos. Las funciones de abajo vuelven a tomar lo
  -- que ya esta bloqueado.
  v_excedente := GREATEST(COALESCE(NEW.monto_pagado, 0) - NEW.total, 0);
  v_plata := v_excedente + COALESCE((SELECT sum(monto) FROM pagos
                                      WHERE cliente_id = NEW.cliente_id
                                        AND sucursal_id = NEW.sucursal_id
                                        AND pedido_id IS NULL), 0);

  IF v_plata > 0.005 THEN
    v_alcanza := ARRAY(
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

    PERFORM 1
       FROM pedidos
      WHERE id = ANY(v_alcanza)
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
                    WHERE pg.cliente_id = NEW.cliente_id
                      AND pg.sucursal_id = NEW.sucursal_id
                      AND pg.pedido_id IS NULL
                   UNION ALL
                   SELECT pg.id
                     FROM pagos pg
                    WHERE pg.pedido_id = NEW.id
                      AND v_excedente > 0.005)
      ORDER BY id
        FOR UPDATE;
  END IF;

  PERFORM public.desafectar_sobrepago_pedido(NEW.id);
  PERFORM public.aplicar_credito_cliente(NEW.cliente_id, NEW.sucursal_id);

  RETURN NULL;
END;
$function$;

-- ---------------------------------------------------------------------------
-- El trigger, con un nombre que corre antes que el de las rutas y el del saldo
-- ---------------------------------------------------------------------------
DROP TRIGGER zzz_pedidos_reconciliar_pagos ON public.pedidos;

-- El nombre importa, y reemplaza al zzz_ de la 165: no lo vuelvas a zzz_ (#1446).
-- Los triggers AFTER de una fila corren en orden de nombre, y 'trg_' va antes que
-- 'trigger_': éste corre antes que trigger_actualizar_recorrido_entrega y que
-- trigger_actualizar_saldo_pedido, así la edición toma las otras boletas, sus rutas
-- y los créditos antes que el cliente. La 165 lo ponía último "cuando el saldo ya
-- contabilizó el cambio de total", pero nada de lo que corre acá adentro lee el
-- saldo ni lo que esos dos triggers escriben:
--   · los dos triggers de saldo (actualizar_saldo_pedido de pedidos y
--     actualizar_saldo_cliente de pagos) suman el delta OLD→NEW de cada evento, y
--     los deltas conmutan;
--   · desafectar_sobrepago_pedido, aplicar_credito_cliente y los triggers de pagos
--     no leen saldo_cuenta ni los contadores de la ruta. Los dos BEFORE de clientes
--     que miran saldo_cuenta salen sin mirarlo a pg_trigger_depth() > 1, que es
--     siempre el caso en la cascada;
--   · el monto_pagado y el estado_pago de la boleta son los mismos en los dos
--     órdenes: los escriben el UPDATE y sus BEFORE, y ni la ruta ni el saldo tocan
--     pedidos;
--   · los contadores de la ruta son un recálculo, y el último ve el estado final.
-- Lo único que cambia es qué fila de pedido_historial entra primero dentro de la
-- transacción (el total o el estado_pago de la reimputación); tienen el mismo
-- created_at, que es por lo que las ordena el front.
-- Lo prueba scripts/test-edicion-creditos-1446.sql: los mismos números con los dos
-- órdenes, y CC-A sin cambios.
CREATE TRIGGER trg_pedidos_reconciliar_pagos
AFTER UPDATE OF total ON public.pedidos
FOR EACH ROW
WHEN (NEW.total IS DISTINCT FROM OLD.total
      AND NEW.estado NOT IN ('cancelado', 'anulado'))
EXECUTE FUNCTION public.pedidos_reconciliar_pagos();

-- ---------------------------------------------------------------------------
-- Los llamadores: las boletas por id antes que la propia
-- ---------------------------------------------------------------------------
CREATE FUNCTION public._edicion_bloquea_boletas(p_pedido_id bigint, p_sucursal_id bigint)
RETURNS void
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_cliente bigint;
  v_plata   numeric;
  v_alcanza bigint[];
BEGIN
  -- #1446: la llaman los caminos que cambian el total de una boleta, antes de su
  -- primer lock sobre ella. Cuando el total cambia, pedidos_reconciliar_pagos
  -- toma las otras boletas del cliente que los creditos alcanzan a pagar; desde
  -- el trigger, la boleta ya esta tomada y una de id menor quedaba al reves del
  -- orden por id (un FIFO toma las dos por id: 40P01). Aca se toman todas juntas
  -- y por id. Todavia no se sabe el total nuevo: lo que puede quedar a favor es a
  -- lo sumo todo lo cobrado de la boleta, y ella no cuenta en la cola. Asi el
  -- conjunto contiene al que despues piden el trigger y aplicar_credito_cliente:
  -- toma de mas, nunca de menos. Sin plata a favor posible no toma nada, y la
  -- boleta la toma el llamador como antes. Lee sin lock: el llamador la vuelve a
  -- tomar y valida.
  SELECT cliente_id,
         CASE WHEN tipo_factura = 'VB' THEN 0 ELSE COALESCE(monto_pagado, 0) END
    INTO v_cliente, v_plata
    FROM pedidos
   WHERE id = p_pedido_id
     AND sucursal_id = p_sucursal_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_plata := v_plata + COALESCE((SELECT sum(monto) FROM pagos
                                  WHERE cliente_id = v_cliente
                                    AND sucursal_id = p_sucursal_id
                                    AND pedido_id IS NULL), 0);
  IF v_plata <= 0.005 THEN
    RETURN;
  END IF;

  v_alcanza := ARRAY(
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
  IF cardinality(v_alcanza) = 0 THEN
    RETURN;
  END IF;

  PERFORM 1
     FROM pedidos
    WHERE id = ANY(v_alcanza || p_pedido_id)
    ORDER BY id
      FOR UPDATE;
END;
$function$;

-- Sólo la llaman funciones de server (SECURITY DEFINER): nadie más la ejecuta.
REVOKE ALL ON FUNCTION public._edicion_bloquea_boletas(bigint, bigint) FROM PUBLIC, anon, authenticated;

CREATE TEMP TABLE _nnn_parche (firma text, ancla text, reemplazo text) ON COMMIT DROP;

INSERT INTO _nnn_parche (firma, ancla, reemplazo) VALUES
('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)',
$a$  -- #826: FOR UPDATE serializa dos ediciones del mismo pedido.
$a$,
$r$  -- #1446: las otras boletas del cliente que los creditos pueden pagar, por id
  -- y junto con esta, antes del lock de abajo (_edicion_bloquea_boletas).
  PERFORM public._edicion_bloquea_boletas(p_pedido_id, v_sucursal);

  -- #826: FOR UPDATE serializa dos ediciones del mismo pedido.
$r$),
('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)',
$a$  PERFORM 1 FROM pedidos
   WHERE id = p_pedido_id
     AND sucursal_id = v_sucursal
     FOR UPDATE;
$a$,
$r$  -- #1446: antes, las otras boletas del cliente que los creditos pueden pagar,
  -- por id y junto con esta (_edicion_bloquea_boletas).
  PERFORM public._edicion_bloquea_boletas(p_pedido_id, v_sucursal);
  PERFORM 1 FROM pedidos
   WHERE id = p_pedido_id
     AND sucursal_id = v_sucursal
     FOR UPDATE;
$r$),
('public.anular_salvedad(bigint,text)',
$a$  PERFORM 1 FROM pedidos
   WHERE id = v_salvedad.pedido_id AND sucursal_id = v_sucursal
     FOR UPDATE;
$a$,
$r$  -- #1446: antes, las otras boletas del cliente que los creditos pueden pagar,
  -- por id y junto con esta (_edicion_bloquea_boletas).
  PERFORM public._edicion_bloquea_boletas(v_salvedad.pedido_id, v_sucursal);
  PERFORM 1 FROM pedidos
   WHERE id = v_salvedad.pedido_id AND sucursal_id = v_sucursal
     FOR UPDATE;
$r$),
('public.cambiar_tipo_factura_pedido(bigint,character varying,uuid)',
$a$  SELECT id, estado, tipo_factura, cliente_id, canal, fecha, fecha_entrega,
$a$,
$r$  -- #1446: pasar a vale blanco cambia el total. Antes, las otras boletas del
  -- cliente que los creditos pueden pagar, por id y junto con esta
  -- (_edicion_bloquea_boletas).
  PERFORM public._edicion_bloquea_boletas(p_pedido_id, v_sucursal);

  SELECT id, estado, tipo_factura, cliente_id, canal, fecha, fecha_entrega,
$r$);

DO $parches$
DECLARE
  v_p   record;
  v_def text;
  v_n   int;
BEGIN
  FOR v_p IN SELECT * FROM _nnn_parche ORDER BY firma LOOP
    v_def := pg_get_functiondef(v_p.firma::regprocedure);
    v_n := (length(v_def) - length(replace(v_def, v_p.ancla, ''))) / length(v_p.ancla);
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'mig 457 · %: el ancla aparece % vez/veces y se esperaba 1', v_p.firma, v_n;
    END IF;
    EXECUTE replace(v_def, v_p.ancla, v_p.reemplazo);
  END LOOP;
END
$parches$;

-- ---------------------------------------------------------------------------
-- Poscondiciones
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  v_antes text[];
  v_f     record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, x.acl, md5(p.prosrc) AS md5_vivo, p.proacl::text || '/' || p.prosecdef::text AS acl_viva
      FROM (VALUES
        ('public.pedidos_reconciliar_pagos()',                                                   '2d0eccc317dde64f8e38ac30a6942b37', '{postgres=X/postgres,service_role=X/postgres}/true'),
        ('public._edicion_bloquea_boletas(bigint,bigint)',                                       '0175b260ba7a47c43026ea90653dccda', '{postgres=X/postgres,service_role=X/postgres}/false'),
        ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)',      '6ce783bf7f933809525ed800fadea044', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}/true'),
        ('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)', '61c5324693320ac4b9ac6c9b00c4f322','{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}/true'),
        ('public.anular_salvedad(bigint,text)',                                                  '7649abb7b00d2bd13720d0f9a3f1bc8b', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}/true'),
        ('public.cambiar_tipo_factura_pedido(bigint,character varying,uuid)',                    'cc1ed8062ea3141fa2d6e4a35636c193','{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}/true')
      ) AS x(firma, md5, acl)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF v_f.md5_vivo <> v_f.md5 OR v_f.acl_viva <> v_f.acl THEN
      RAISE EXCEPTION 'mig 457 · % no quedó como en el repo (md5 %, acl %)', v_f.firma, v_f.md5_vivo, v_f.acl_viva;
    END IF;
  END LOOP;

  -- Los AFTER UPDATE de pedidos que toman filas, en el orden en que corren.
  v_antes := ARRAY(SELECT tgname::text FROM pg_trigger
                    WHERE tgrelid = 'public.pedidos'::regclass
                      AND tgname IN ('trg_pedidos_reconciliar_pagos', 'trigger_actualizar_recorrido_entrega',
                                     'trigger_actualizar_saldo_pedido', 'zzz_pedidos_reconciliar_pagos')
                    ORDER BY tgname COLLATE "C");
  IF v_antes IS DISTINCT FROM ARRAY['trg_pedidos_reconciliar_pagos', 'trigger_actualizar_recorrido_entrega',
                                    'trigger_actualizar_saldo_pedido'] THEN
    RAISE EXCEPTION 'mig 457 · los triggers de pedidos no quedaron en el orden esperado: %', v_antes;
  END IF;
END
$post$;

COMMIT;
