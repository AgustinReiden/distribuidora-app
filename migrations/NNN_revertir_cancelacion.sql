-- =========================================================================
-- NNN · EL ADMIN PUEDE REVERTIR LA CANCELACIÓN DE UN PEDIDO
--
-- Ensayo: scripts/test-revertir-cancelacion.sql (sin esta migración falla en A0; con ella,
-- ENSAYO OK). Se aplica en LF.
--
-- Hasta acá una baja no se deshacía (mig 360, pedidos_guard_baja): el pedido 1856 volvió a
-- pendiente por REST sin volver a descontar el stock. Decisión del dueño (26/11/2026): el admin
-- la revierte con una RPC propia que deshace lo que hizo la cancelación; todo otro camino sigue
-- rechazado.
--
-- 1 · pedido_cancelacion_foto (sólo de server: RLS sin policies y sin grants). Una fila por
--     cancelación: el estado y los totales de antes, el tipo, los pagos que esa cancelación
--     desimputó (`pagos_liberados`) y las mermas que dejó la de falta de stock (`mermas`). La
--     única FK es la del pedido (compuesta, ON DELETE CASCADE): con otra a sucursales o a
--     perfiles PostgREST la tomaría como tabla puente y daría PGRST201 en embeds de hoy.
-- 2 · cancelar_pedido_con_stock (parche por ancla, premisa de md5 del cuerpo vivo de la 555):
--     guarda la foto justo antes de quitar el pedido de las rutas, y anota cada merma de la
--     falta de stock (la del producto y la del fardo de promo). Nada más cambia.
-- 3 · pedidos_guard_baja: la regla 1 deja pasar UNA transición, cancelado → pendiente, sólo
--     dentro de una función de server (current_user no es un rol de la API) que marcó ese
--     pedido en `app.revertir_cancelacion`. Por REST, aunque se ponga el GUC, sigue el 42501.
--     El resto queda como estaba (el 'anulado' muerto incluido: sacarlo cambia el error que
--     espera test-pedido-baja-1131.sql, de 42501 al del CHECK de estado).
-- 4 · revertir_cancelacion_pedido(p_pedido_id, p_usuario_id): sólo admin activo, con sucursal
--     activa y p_usuario_id = auth.uid(). Lo que hace:
--     · Rechaza (sin escribir nada): la cancelación del cambio de cliente (ya existe el pedido
--       nuevo), la comanda de un canje, el vale blanco que estaba entregado, un pedido con
--       fecha de entrega (vaciarla borraría el control de la rendición de ese día), uno con
--       salvedades o con una NC vigente, un cliente desactivado, un combo que llegó a su tope,
--       la falta de stock sin foto, y la falta de stock de hoy de algún producto (con el
--       producto y cuánto falta, como el alta).
--     · Estado: pendiente, sin chofer ni orden (lo de _pedido_a_pendiente, mig 420), sin motivo.
--     · Totales: los de la foto. Sin foto (cancelaciones anteriores a esta migración), desde las
--       líneas con la cuenta de anular_salvedad; el envío vuelve en 0 (la cancelación lo puso en
--       0 y no quedó dónde estaba).
--     · Stock: cada línea que la cancelación devolvió vuelve a bajar, con su línea en
--       `app.stock_pedido_item_id` y el origen 'pedido_cancelacion_revertida' (es una baja de
--       venta: se suma al WHEN de audit_productos_update, como pedido_creado). La bajada no mira
--       la lista blanca del trigger de lotes: come la bolsa y después FEFO, y deja huella.
--     · Falta de stock: cada merma de la foto se anula (`anulada_at`, como anular_salvedad) y sus
--       unidades vuelven a la bolsa ('pedido_cancelacion_revertida_merma', fuera de la lista
--       blanca, ref la merma); la bajada de la línea las vuelve a tomar: neto cero en el stock,
--       en los lotes y en la bolsa, y la merma deja de contar. La del fardo de promo vuelve sólo
--       si vuelve el regalo; si el motor no vuelve a cerrar ese fardo, lo que sobra se merma de
--       nuevo (la misma cuenta que la cancelación).
--     · Regalos: el regalo de una promo cuya barra ya no vale (`_regalo_barra_vale`) o que ya no
--       tiene cupo (`limite_usos`, con `_promo_usos` y la promo tomada) se saca del pedido; los
--       que quedan vuelven a la barra con `aplicar_uso_promo_acumulador` (+, el inverso de la
--       cancelación). Invariante: una línea de regalo viva con la barra que vale está en la barra.
--     · Cobros: vuelven a la boleta, por id y enteros hasta lo que debe, los pagos de la foto que
--       siguen sueltos del cliente; lo que la cancelación ya aplicó a otra boleta se queda ahí y
--       el pedido debe esa parte. Sin foto no vuelve ningún cobro (sólo el texto de las notas
--       dice de dónde salió un crédito, y adivinar por texto le podría sacar a otra operación
--       su crédito). El pago que vuelve pierde la marca «[saldo a favor por cancelacion]»
--       (_notas_sin_saldo_a_favor) y queda `de_saldo_a_favor` (lo pone su trigger: pasó por
--       crédito), así que en la rendición sigue siendo de quien lo cobró, como estaba cancelado.
--     · Orden de locks: las boletas que alcanza el crédito suelto del cliente con esta, por id
--       (_credito_bloquea_boletas: el trigger de la baja de total las mira al subir el total),
--       los combos con tope, los productos y contenedores por id, las promos por id, y las rutas
--       y los créditos (_credito_bloquea_rutas_y_creditos). El orden de la cancelación.
--     · Queda en pedido_historial ('cancelado' → 'pendiente - Cancelación revertida | …') y en
--       audit_logs por los triggers de cada tabla.
-- 5 · audit_productos_update: 'pedido_cancelacion_revertida' entra en la lista de bajas por venta
--     que no se auditan en productos (ya están en stock_historico).
--
-- PREMISAS (abortan con el motivo): los md5 de cancelar_pedido_con_stock y pedidos_guard_baja de
-- la 555, que la foto y la RPC no existan, la forma del WHEN de audit_productos_update y las
-- funciones con que se cuenta.
--
-- Revertir: DROP FUNCTION revertir_cancelacion_pedido; volver cancelar_pedido_con_stock y
-- pedidos_guard_baja a los cuerpos de las premisas; el WHEN de audit_productos_update sin el
-- origen nuevo; DROP TABLE pedido_cancelacion_foto.
-- =========================================================================

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

SET LOCAL lock_timeout = '5s';

-- ---------------------------------------------------------------------------
-- Premisas
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.cancelar_pedido_con_stock(bigint,text,uuid,text)', 'c4685911513e2f491b184454d6a51e33'),
    ('public.pedidos_guard_baja()', 'e95d122e7beb205ba9a3ea6dc537ffef'),
    -- No cambian: el revertir cuenta con ellas como están.
    ('public._credito_bloquea_boletas(bigint,bigint,bigint,numeric)', NULL),
    ('public._credito_bloquea_rutas_y_creditos(bigint[],bigint,bigint,bigint)', NULL),
    ('public._regalo_barra_vale(bigint,bigint,bigint)', NULL),
    ('public._regalo_modo_del_pedido(bigint,bigint,bigint)', NULL),
    ('public.aplicar_uso_promo_acumulador(bigint,bigint,numeric,bigint,bigint,uuid,text)', NULL),
    ('public._promo_usos(bigint,bigint)', NULL),
    ('public.regalo_usos_de_linea(jsonb,uuid,numeric)', NULL),
    ('public.regalo_eslabones(bigint,bigint,bigint)', NULL),
    ('public._notas_sin_saldo_a_favor(text)', NULL),
    ('public.cargo_envio_desglose(numeric,text)', NULL),
    ('public.nota_credito_vigente_de_pedido(bigint)', NULL),
    ('public._contenedores_de_promos(bigint[],bigint)', NULL),
    ('public.es_admin()', NULL)
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF r.h IS NOT NULL AND v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;

  IF to_regclass('public.pedido_cancelacion_foto') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · pedido_cancelacion_foto ya existe';
  END IF;
  IF to_regprocedure('public.revertir_cancelacion_pedido(bigint,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · revertir_cancelacion_pedido ya existe';
  END IF;
  -- La foto apunta al pedido por la clave del aislamiento.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.pedidos'::regclass AND contype IN ('u', 'p')
                    AND pg_get_constraintdef(oid) = 'UNIQUE (id, sucursal_id)') THEN
    RAISE EXCEPTION 'mig NNN · pedidos no tiene UNIQUE (id, sucursal_id)';
  END IF;
  SELECT pg_get_triggerdef(t.oid) INTO v
    FROM pg_trigger t
   WHERE t.tgrelid = 'public.productos'::regclass AND t.tgname = 'audit_productos_update';
  IF v IS NULL OR v NOT LIKE '%ARRAY[''pedido_creado''::text, ''pedido_creado_bot''::text, ''pedido_editado''::text]%' THEN
    RAISE EXCEPTION 'mig NNN · el WHEN de audit_productos_update cambió: rehacer sobre lo vigente (%)', v;
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
-- 1 · La foto de la cancelación (sólo de server)
-- =========================================================================
CREATE TABLE public.pedido_cancelacion_foto (
  id               bigint      GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  pedido_id        bigint      NOT NULL,
  sucursal_id      bigint      NOT NULL,
  -- El pedido antes de cancelarse.
  estado_anterior  text        NOT NULL,
  tipo             text,
  total            numeric(12,2) NOT NULL
    CONSTRAINT pedido_cancelacion_foto_total_valido CHECK (total >= 0 AND total <> 'NaN'::numeric),
  cargo_envio      numeric(12,2) NOT NULL DEFAULT 0
    CONSTRAINT pedido_cancelacion_foto_cargo_valido CHECK (cargo_envio >= 0 AND cargo_envio <> 'NaN'::numeric),
  total_neto       numeric(12,2)
    CONSTRAINT pedido_cancelacion_foto_neto_no_nan CHECK (total_neto <> 'NaN'::numeric),
  total_iva        numeric(12,2)
    CONSTRAINT pedido_cancelacion_foto_iva_no_nan CHECK (total_iva <> 'NaN'::numeric),
  total_real       numeric(12,2)
    CONSTRAINT pedido_cancelacion_foto_real_no_nan CHECK (total_real <> 'NaN'::numeric),
  -- Los pagos que esta cancelación desimputó (los que pasaron a ser crédito del cliente).
  pagos_liberados  bigint[]    NOT NULL DEFAULT '{}',
  -- Las mermas de la falta de stock: [{merma_id, producto_id, cantidad, promocion_id}]
  -- (promocion_id NULL: la del producto; con valor: el fardo del contenedor de esa promo).
  mermas           jsonb       NOT NULL DEFAULT '[]'::jsonb
    CONSTRAINT pedido_cancelacion_foto_mermas_lista CHECK (jsonb_typeof(mermas) = 'array'),
  cancelada_por    uuid,
  cancelada_at     timestamptz NOT NULL DEFAULT now(),
  -- La reversión: quién, cuándo y qué pagos volvieron a la boleta.
  revertida_por    uuid,
  revertida_at     timestamptz,
  pagos_vueltos    bigint[],
  CONSTRAINT pedido_cancelacion_foto_pedido_fkey FOREIGN KEY (pedido_id, sucursal_id)
    REFERENCES public.pedidos (id, sucursal_id) ON DELETE CASCADE
);

-- Una cancelación viva por pedido: cancelar uno cancelado se rechaza, y la reversión la cierra.
CREATE UNIQUE INDEX pedido_cancelacion_foto_viva_uk
  ON public.pedido_cancelacion_foto (pedido_id) WHERE revertida_at IS NULL;

COMMENT ON TABLE public.pedido_cancelacion_foto IS
  'La foto de cada cancelación de pedido (estado y totales de antes, pagos desimputados, mermas de la falta de stock), para que revertir_cancelacion_pedido la deshaga. La escribe cancelar_pedido_con_stock. Sólo de server: RLS sin policies y sin grants.';

ALTER TABLE public.pedido_cancelacion_foto ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.pedido_cancelacion_foto FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.pedido_cancelacion_foto_id_seq FROM PUBLIC, anon, authenticated;

-- =========================================================================
-- 2 · cancelar_pedido_con_stock guarda la foto
-- =========================================================================
DO $parche_cancelar$
DECLARE
  v_def text := pg_get_functiondef('public.cancelar_pedido_con_stock(bigint,text,uuid,text)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  v_cobrado_fresco NUMERIC;
BEGIN
$a$,
$r$  v_cobrado_fresco NUMERIC;
  -- mig NNN: las mermas de la falta de stock, para la foto.
  v_foto_mermas JSONB := '[]'::jsonb;
BEGIN
$r$, 'cancelar_pedido_con_stock (declare)');

  v_def := pg_temp.parche(v_def,
$a$      ) RETURNING id INTO v_merma_id;

      -- La bajada es una merma: el ledger lo dice y apunta a su fila, igual
$a$,
$r$      ) RETURNING id INTO v_merma_id;

      -- mig NNN: la foto anota la merma, para que revertir la cancelación la anule.
      v_foto_mermas := v_foto_mermas || jsonb_build_array(jsonb_build_object(
        'merma_id', v_merma_id, 'producto_id', v_merma.producto_id,
        'cantidad', v_merma.cantidad, 'promocion_id', NULL));

      -- La bajada es una merma: el ledger lo dice y apunta a su fila, igual
$r$, 'cancelar_pedido_con_stock (merma del producto)');

  v_def := pg_temp.parche(v_def,
$a$        ) RETURNING id INTO v_merma_id;

        PERFORM set_config('app.stock_origen',   'merma',          true);
$a$,
$r$        ) RETURNING id INTO v_merma_id;

        -- mig NNN: la merma del fardo, con su promo.
        v_foto_mermas := v_foto_mermas || jsonb_build_array(jsonb_build_object(
          'merma_id', v_merma_id, 'producto_id', v_promo_rev.contenedor_id,
          'cantidad', v_fardo, 'promocion_id', v_promo_rev.promocion_id));

        PERFORM set_config('app.stock_origen',   'merma',          true);
$r$, 'cancelar_pedido_con_stock (merma del fardo)');

  v_def := pg_temp.parche(v_def,
$a$  -- mig 180: la parada de un pedido cancelado no es una parada. Sin esto
$a$,
$r$  -- mig NNN: la foto de la cancelación, para que el admin la pueda revertir
  -- (revertir_cancelacion_pedido): el pedido de antes, los pagos que esta
  -- cancelación desimputó y las mermas de la falta de stock.
  INSERT INTO pedido_cancelacion_foto (
    pedido_id, sucursal_id, estado_anterior, tipo,
    total, cargo_envio, total_neto, total_iva, total_real,
    pagos_liberados, mermas, cancelada_por
  ) VALUES (
    p_pedido_id, v_sucursal, v_pedido.estado, COALESCE(p_tipo, v_pedido.motivo_cancelacion_tipo),
    COALESCE(v_pedido.total, 0), COALESCE(v_pedido.cargo_envio, 0),
    v_pedido.total_neto, v_pedido.total_iva, v_pedido.total_real,
    COALESCE(v_pagos_liberados, '{}'::bigint[]), v_foto_mermas, v_acting_user
  );

  -- mig 180: la parada de un pedido cancelado no es una parada. Sin esto
$r$, 'cancelar_pedido_con_stock (foto)');

  EXECUTE v_def;
END
$parche_cancelar$;

-- =========================================================================
-- 3 · pedidos_guard_baja: la única salida de una baja es revertir_cancelacion_pedido
-- =========================================================================
CREATE OR REPLACE FUNCTION public.pedidos_guard_baja()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
DECLARE
  -- #1131. INVOKER a proposito: current_user es el rol de la llamada. Dentro
  -- de una RPC DEFINER es su duenio y las reglas de API no aplican.
  v_api        boolean := current_user IN ('authenticated', 'anon', 'service_role');
  v_entra_baja boolean;
BEGIN
  -- Regla 1 (todos): una baja no se deshace. La cancelacion ya devolvio el
  -- stock, puso el total en 0 y desimputo los pagos; volver a otro estado
  -- resucita una venta que no descuenta nada (el pedido 1856).
  -- mig NNN: salvo revertir_cancelacion_pedido, que deshace todo eso. Marca el
  -- pedido en app.revertir_cancelacion y corre como su duenio: por la API el
  -- GUC no alcanza (v_api), y sólo vale cancelado -> pendiente de ese pedido.
  IF TG_OP = 'UPDATE'
     AND OLD.estado IN ('cancelado', 'anulado')
     AND NEW.estado IS DISTINCT FROM OLD.estado
     AND NOT (NOT v_api
              AND OLD.estado = 'cancelado' AND NEW.estado = 'pendiente'
              AND COALESCE(current_setting('app.revertir_cancelacion', true), '') = OLD.id::text) THEN
    RAISE EXCEPTION 'El pedido #% está %: una baja no se deshace con un cambio de estado. La revierte un admin con "Revertir cancelación", que vuelve a descontar el stock.',
      OLD.id, OLD.estado
      USING ERRCODE = '42501';
  END IF;

  IF TG_OP = 'INSERT' THEN
    v_entra_baja := COALESCE(NEW.estado IN ('cancelado', 'anulado'), false);
  ELSE
    v_entra_baja := COALESCE(NEW.estado IN ('cancelado', 'anulado'), false)
                    AND NEW.estado IS DISTINCT FROM OLD.estado;
  END IF;

  IF v_api THEN
    -- Reglas 2 y 3 (API): a la baja se entra solo por cancelar_pedido_con_stock.
    IF v_entra_baja THEN
      RAISE EXCEPTION 'Un pedido se da de baja con "Cancelar pedido", que devuelve el stock; no cambiando el estado.'
        USING ERRCODE = '42501';
    END IF;

    -- Regla 4 (API): el motivo lo escribe la cancelacion. La 354 lo usa como
    -- senial de "ya devuelto".
    IF TG_OP = 'INSERT' THEN
      IF NEW.motivo_cancelacion IS NOT NULL OR NEW.motivo_cancelacion_tipo IS NOT NULL THEN
        RAISE EXCEPTION 'El motivo de cancelación lo escribe "Cancelar pedido": un pedido nuevo no lo trae.'
          USING ERRCODE = '42501';
      END IF;
    ELSIF NEW.motivo_cancelacion IS DISTINCT FROM OLD.motivo_cancelacion
          OR NEW.motivo_cancelacion_tipo IS DISTINCT FROM OLD.motivo_cancelacion_tipo THEN
      RAISE EXCEPTION 'El motivo de cancelación lo escribe "Cancelar pedido": no se edita a mano.'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  -- Regla 5 (todos): a 'cancelado' se entra con motivo. cancelar_pedido_con_stock
  -- no lo valida; el CHECK pedidos_cancelado_con_motivo lo cierra igual, esto
  -- es para que el error se entienda.
  IF NEW.estado = 'cancelado'
     AND (TG_OP = 'INSERT' OR OLD.estado IS DISTINCT FROM 'cancelado')
     AND COALESCE(btrim(NEW.motivo_cancelacion), '') = '' THEN
    RAISE EXCEPTION 'Un pedido se cancela con motivo (pedido #%).', NEW.id
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.pedidos_guard_baja() FROM PUBLIC, anon, authenticated;

-- =========================================================================
-- 4 · revertir_cancelacion_pedido
-- =========================================================================
CREATE FUNCTION public.revertir_cancelacion_pedido(p_pedido_id bigint, p_usuario_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_sucursal        bigint := current_sucursal_id();
  v_usuario         uuid := auth.uid();
  v_cliente_id      bigint;
  v_boletas         bigint[];
  v_pedido          record;
  v_foto            record;
  v_con_foto        boolean;
  v_tipo            text;
  v_estado_anterior text;
  v_es_vb           boolean;
  r                 record;
  v_errores         text[] := '{}';
  v_quitar          bigint[] := '{}';
  v_quitados        jsonb := '[]'::jsonb;
  v_limite          integer;
  v_promo_nombre    text;
  v_usos            bigint;
  v_usos_pedido     bigint;
  v_vendidos        bigint;
  -- Las mermas de la foto que siguen vivas y se anulan: [{merma_id, producto_id, cantidad, promocion_id}].
  v_mermas          jsonb := '[]'::jsonb;
  v_fardos          jsonb := '{}'::jsonb;   -- contenedor -> unidades de fardo que volvieron
  v_antes           jsonb := '{}'::jsonb;   -- contenedor -> stock antes del motor
  v_dif             integer;
  v_stock           integer;
  v_merma_id        bigint;
  v_total           numeric;
  v_cargo           numeric;
  v_neto            numeric;
  v_iva             numeric;
  v_real            numeric;
  v_falta           numeric;
  v_vueltos         bigint[] := '{}';
  v_monto_vuelto    numeric := 0;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;
  IF p_usuario_id IS NOT NULL AND p_usuario_id IS DISTINCT FROM v_usuario THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesion autenticada');
  END IF;
  -- es_admin() mira activo (#1474): un desactivado no revierte aunque su token siga vivo.
  IF NOT public.es_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo un admin revierte una cancelación');
  END IF;

  SELECT cliente_id INTO v_cliente_id
    FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pedido no encontrado');
  END IF;

  -- Orden de locks. Al subir el total, pedidos_reconciliar_pagos toma las boletas
  -- que alcanza el crédito suelto del cliente: se toman antes, por id y con ésta
  -- (como la cancelación y la NC, #1512).
  v_boletas := public._credito_bloquea_boletas(p_pedido_id, v_cliente_id, v_sucursal, 0);

  SELECT * INTO v_pedido FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal FOR UPDATE;
  IF v_pedido.estado IS DISTINCT FROM 'cancelado' THEN
    RETURN jsonb_build_object('success', false, 'error',
      'El pedido #' || p_pedido_id || ' no está cancelado: no hay cancelación que revertir.');
  END IF;
  IF v_pedido.cliente_id IS DISTINCT FROM v_cliente_id THEN
    v_boletas := public._credito_bloquea_boletas(p_pedido_id, v_pedido.cliente_id, v_sucursal, 0);
  END IF;
  v_es_vb := COALESCE(v_pedido.tipo_factura, 'ZZ') = 'VB';

  SELECT * INTO v_foto
    FROM pedido_cancelacion_foto
   WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal AND revertida_at IS NULL
   ORDER BY id DESC
   LIMIT 1
     FOR UPDATE;
  v_con_foto := FOUND;

  v_tipo := COALESCE(v_foto.tipo, v_pedido.motivo_cancelacion_tipo);
  IF v_con_foto THEN
    v_estado_anterior := v_foto.estado_anterior;
  ELSE
    -- Sin foto, el estado de antes es el que anotó la cancelación en el historial.
    SELECT h.valor_anterior INTO v_estado_anterior
      FROM pedido_historial h
     WHERE h.pedido_id = p_pedido_id AND h.sucursal_id = v_sucursal
       AND h.campo_modificado = 'estado' AND h.valor_nuevo LIKE 'cancelado - Motivo:%'
     ORDER BY h.id DESC
     LIMIT 1;
  END IF;

  -- Lo que no se revierte (decisión del dueño, 26/11).
  IF v_tipo = 'cambio_de_cliente' THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Esta cancelación la hizo el cambio de cliente: el pedido ya se cargó de nuevo al otro cliente. No se revierte.');
  END IF;
  IF v_pedido.canal IS NOT DISTINCT FROM 'cambio' THEN
    RETURN jsonb_build_object('success', false, 'error',
      'El pedido #' || p_pedido_id || ' es la comanda de un canje: no se revierte. Si hace falta, cargá el canje de nuevo.');
  END IF;
  IF v_es_vb AND (v_estado_anterior = 'entregado' OR v_pedido.fecha_entrega IS NOT NULL) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Este vale blanco se canceló entregado: no se revierte. Si hay que volver a darlo, cargá un vale nuevo.');
  END IF;
  -- Sin chofer y sin fecha de entrega, el control de la rendición de ese día se
  -- borraría (anular_control_por_cambio_fecha_entrega).
  IF v_pedido.fecha_entrega IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error',
      'El pedido #' || p_pedido_id || ' tiene fecha de entrega: revertirlo tocaría la rendición de ese día. Cargá un pedido nuevo.');
  END IF;
  IF v_tipo = 'falta_stock' AND NOT v_con_foto THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Este pedido se canceló por falta de stock antes de que la cancelación guardara sus mermas: no se sabe qué deshacer. Cargá un pedido nuevo.');
  END IF;
  IF public.nota_credito_vigente_de_pedido(p_pedido_id) IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error',
      'El pedido tiene la nota de crédito #' || public.nota_credito_vigente_de_pedido(p_pedido_id) || ' vigente: no se revierte.');
  END IF;
  IF EXISTS (SELECT 1 FROM salvedades_items
              WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal
                AND estado_resolucion IS DISTINCT FROM 'anulada') THEN
    RETURN jsonb_build_object('success', false, 'error',
      'El pedido tiene salvedades: no vuelve a pendiente con ellas. Cargá un pedido nuevo.');
  END IF;
  IF EXISTS (SELECT 1 FROM clientes
              WHERE id = v_pedido.cliente_id AND sucursal_id = v_sucursal AND activo IS FALSE) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'El cliente del pedido está desactivado: reactivalo antes de revertir la cancelación.');
  END IF;

  -- Los combos con tope, antes que los productos (el orden del alta, #1556).
  FOR r IN
    SELECT c.id, c.nombre, c.tope_combos, f.cantidad_combos
      FROM pedido_combos f
      JOIN combos c ON c.id = f.combo_id AND c.sucursal_id = f.sucursal_id
     WHERE f.pedido_id = p_pedido_id AND f.sucursal_id = v_sucursal
       AND c.tope_combos IS NOT NULL
     ORDER BY c.id
  LOOP
    PERFORM 1 FROM combos WHERE id = r.id AND sucursal_id = v_sucursal FOR UPDATE;
    SELECT COALESCE(sum(f.cantidad_combos), 0) INTO v_vendidos
      FROM pedido_combos f
      JOIN pedidos p ON p.id = f.pedido_id AND p.sucursal_id = f.sucursal_id
     WHERE f.combo_id = r.id AND f.sucursal_id = v_sucursal
       AND p.estado <> 'cancelado'
       AND f.pedido_id <> p_pedido_id;
    IF v_vendidos + r.cantidad_combos > r.tope_combos THEN
      RETURN jsonb_build_object('success', false, 'error',
        format('El combo "%s" llegó a su tope (quedan %s y el pedido lleva %s): no se revierte.',
               r.nombre, GREATEST(r.tope_combos - v_vendidos, 0), r.cantidad_combos));
    END IF;
  END LOOP;

  -- Los productos del pedido y los contenedores de sus promos, por id, antes del
  -- primer movimiento: el orden de la venta y de la cancelación (#1296, #1375).
  PERFORM 1
     FROM productos
    WHERE sucursal_id = v_sucursal
      AND id IN (SELECT pi.producto_id FROM pedido_items pi
                  WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
                 UNION
                 SELECT c FROM public._contenedores_de_promos(
                   ARRAY(SELECT pi.promocion_id FROM pedido_items pi
                          WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
                            AND pi.promocion_id IS NOT NULL), v_sucursal) c)
    ORDER BY id
      FOR UPDATE;

  -- Las promos de los regalos, por id: el cupo se cuenta con la promo tomada,
  -- como trg_limite_usos_promo.
  PERFORM 1
     FROM promociones
    WHERE sucursal_id = v_sucursal
      AND id IN (SELECT pi.promocion_id FROM pedido_items pi
                  WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
                    AND COALESCE(pi.es_bonificacion, false) AND pi.promocion_id IS NOT NULL)
    ORDER BY id
      FOR UPDATE;

  -- Las rutas de las boletas y los créditos del cliente (los pagos que vuelven), por id.
  PERFORM public._credito_bloquea_rutas_y_creditos(v_boletas, v_pedido.cliente_id, v_sucursal, NULL);

  -- Regalos: el de una promo cuya barra ya no vale, o sin cupo, no vuelve (se saca
  -- la línea). Decisión del dueño: el pedido vuelve sin ese regalo, no se rechaza.
  FOR r IN
    SELECT DISTINCT pi.promocion_id
      FROM pedido_items pi
     WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
       AND COALESCE(pi.es_bonificacion, false) AND pi.promocion_id IS NOT NULL
     ORDER BY 1
  LOOP
    SELECT limite_usos, nombre INTO v_limite, v_promo_nombre
      FROM promociones WHERE id = r.promocion_id AND sucursal_id = v_sucursal;
    IF NOT public._regalo_barra_vale(p_pedido_id, r.promocion_id, v_sucursal) THEN
      v_quitar := v_quitar || r.promocion_id;
      v_quitados := v_quitados || jsonb_build_array(jsonb_build_object(
        'promocion_id', r.promocion_id, 'promocion', v_promo_nombre, 'motivo', 'la promo cambió de tipo'));
      CONTINUE;
    END IF;
    IF v_limite IS NOT NULL THEN
      SELECT u.usos INTO v_usos FROM public._promo_usos(r.promocion_id, NULL) u;
      SELECT COALESCE(sum(COALESCE(pi.regalo_corte,
               public.regalo_usos_de_linea(
                 CASE WHEN pi.regalo_cadena_id IS NOT NULL
                      THEN public.regalo_eslabones(pi.pedido_id, pi.promocion_id, pi.sucursal_id) END,
                 pi.regalo_cadena_id, pi.cantidad))), 0)
        INTO v_usos_pedido
        FROM pedido_items pi
       WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
         AND COALESCE(pi.es_bonificacion, false) AND pi.promocion_id = r.promocion_id;
      IF COALESCE(v_usos, 0) + v_usos_pedido > v_limite THEN
        v_quitar := v_quitar || r.promocion_id;
        v_quitados := v_quitados || jsonb_build_array(jsonb_build_object(
          'promocion_id', r.promocion_id, 'promocion', v_promo_nombre, 'motivo', 'sin cupo'));
      END IF;
    END IF;
  END LOOP;

  -- Las mermas de la falta de stock que siguen vivas. La del fardo, sólo si su regalo vuelve.
  IF v_con_foto THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'merma_id', ms.id, 'producto_id', ms.producto_id, 'cantidad', ms.cantidad,
             'promocion_id', (m->>'promocion_id')::bigint) ORDER BY ms.id), '[]'::jsonb)
      INTO v_mermas
      FROM jsonb_array_elements(v_foto.mermas) m
      JOIN mermas_stock ms
        ON ms.id = (m->>'merma_id')::bigint
       AND ms.sucursal_id = v_sucursal
       AND ms.producto_id = (m->>'producto_id')::bigint
       AND ms.cantidad = (m->>'cantidad')::int
       AND ms.anulada_at IS NULL
     WHERE (m->>'promocion_id') IS NULL
        OR (m->>'promocion_id')::bigint <> ALL (v_quitar);
  END IF;

  -- El stock de hoy tiene que alcanzar (la regla del alta), contando lo que vuelve
  -- de las mermas. No se escribió nada todavía.
  FOR r IN
    SELECT pi.producto_id, sum(pi.cantidad)::int AS cantidad, p.stock, p.nombre
      FROM pedido_items pi
      JOIN productos p ON p.id = pi.producto_id AND p.sucursal_id = pi.sucursal_id
     WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
       AND NOT (COALESCE(pi.es_bonificacion, false) AND COALESCE(pi.promocion_id = ANY (v_quitar), false))
       AND (NOT COALESCE(pi.es_bonificacion, false)
            OR COALESCE(public._regalo_modo_del_pedido(p_pedido_id, pi.promocion_id, v_sucursal), false))
     GROUP BY pi.producto_id, p.stock, p.nombre
    HAVING sum(pi.cantidad) > 0
     ORDER BY pi.producto_id
  LOOP
    v_stock := COALESCE(r.stock, 0)
               + COALESCE((SELECT sum((x->>'cantidad')::int) FROM jsonb_array_elements(v_mermas) x
                            WHERE (x->>'producto_id')::bigint = r.producto_id
                              AND (x->>'promocion_id') IS NULL), 0);
    IF v_stock < r.cantidad THEN
      v_errores := v_errores || format('%s: stock insuficiente (disponible: %s, hacen falta: %s; faltan %s)',
                                       r.nombre, v_stock, r.cantidad, r.cantidad - v_stock);
    END IF;
  END LOOP;
  IF cardinality(v_errores) > 0 THEN
    RETURN jsonb_build_object('success', false, 'error',
      'No hay stock para volver a tomar el pedido. ' || array_to_string(v_errores, '; '));
  END IF;

  -- ---------------------------------------------------------------------------
  -- Desde acá se escribe: un rechazo es un RAISE (deshace todo).
  -- ---------------------------------------------------------------------------

  -- Los regalos que no vuelven. Valen 0: no cambian los totales.
  IF cardinality(v_quitar) > 0 THEN
    DELETE FROM pedido_items
     WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal
       AND COALESCE(es_bonificacion, false) AND promocion_id = ANY (v_quitar);
  END IF;

  -- Los totales: los de la foto o, sin foto, desde las líneas (la cuenta de
  -- anular_salvedad; el envío de una cancelación vieja quedó en 0).
  IF v_con_foto THEN
    v_total := v_foto.total;
    v_cargo := v_foto.cargo_envio;
    v_neto  := v_foto.total_neto;
    v_iva   := v_foto.total_iva;
    v_real  := v_foto.total_real;
  ELSE
    v_cargo := COALESCE(v_pedido.cargo_envio, 0);
    SELECT COALESCE(sum(subtotal), 0)
             + CASE WHEN COALESCE(sum(subtotal), 0) > 0 THEN v_cargo ELSE 0 END,
           COALESCE(sum(CASE WHEN NOT COALESCE(es_bonificacion, false)
                             THEN cantidad * COALESCE(neto_unitario, precio_unitario) ELSE 0 END), 0)
             + (public.cargo_envio_desglose(CASE WHEN COALESCE(sum(subtotal), 0) > 0 THEN v_cargo ELSE 0 END,
                                            v_pedido.tipo_factura)).neto,
           COALESCE(sum(CASE WHEN NOT COALESCE(es_bonificacion, false)
                             THEN cantidad * COALESCE(iva_unitario, 0) ELSE 0 END), 0)
             + (public.cargo_envio_desglose(CASE WHEN COALESCE(sum(subtotal), 0) > 0 THEN v_cargo ELSE 0 END,
                                            v_pedido.tipo_factura)).iva,
           COALESCE(sum(CASE WHEN NOT COALESCE(es_bonificacion, false)
                             THEN cantidad * COALESCE(ingreso_real_unitario,
                                    CASE WHEN v_pedido.tipo_factura = 'VB' THEN precio_unitario
                                         WHEN v_pedido.tipo_factura = 'FC' THEN COALESCE(neto_unitario, precio_unitario)
                                         ELSE precio_unitario END)
                             ELSE 0 END), 0)
      INTO v_total, v_neto, v_iva, v_real
      FROM pedido_items
     WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;
  END IF;

  -- El estado: pendiente, sin ruta y sin motivo. pedidos_guard_baja deja pasar
  -- este UPDATE, y sólo éste, por el GUC. Un vale blanco nombra total y
  -- monto_pagado (mig 318): queda saldado por su propio total.
  PERFORM set_config('app.revertir_cancelacion', p_pedido_id::text, true);
  UPDATE pedidos
     SET estado                  = 'pendiente',
         motivo_cancelacion      = NULL,
         motivo_cancelacion_tipo = NULL,
         transportista_id        = NULL,
         orden_entrega           = NULL,
         fecha_entrega           = NULL,
         total                   = v_total,
         cargo_envio             = v_cargo,
         total_neto              = v_neto,
         total_iva               = v_iva,
         total_real              = v_real,
         monto_pagado            = CASE WHEN v_es_vb THEN v_total ELSE 0 END,
         updated_at              = now()
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal;
  PERFORM set_config('app.revertir_cancelacion', '', true);

  PERFORM set_config('app.stock_user_id', COALESCE(v_usuario::text, ''), true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);

  -- Falta de stock: cada merma se anula (como anular_salvedad) y sus unidades vuelven a
  -- la bolsa, fuera de la lista blanca del trigger de lotes: la bajada de la línea, que
  -- come la bolsa primero, las vuelve a tomar. Neto cero en stock, lotes y bolsa.
  FOR r IN
    SELECT (x->>'merma_id')::bigint AS merma_id, (x->>'producto_id')::bigint AS producto_id,
           (x->>'cantidad')::int AS cantidad, (x->>'promocion_id')::bigint AS promocion_id
      FROM jsonb_array_elements(v_mermas) x
     ORDER BY 1
  LOOP
    PERFORM set_config('app.stock_origen',   'pedido_cancelacion_revertida_merma', true);
    PERFORM set_config('app.stock_ref_tipo', 'mermas_stock',                       true);
    PERFORM set_config('app.stock_ref_id',   r.merma_id::text,                     true);
    UPDATE productos SET stock = stock + r.cantidad
     WHERE id = r.producto_id AND sucursal_id = v_sucursal;
    UPDATE mermas_stock SET anulada_at = now(), anulada_por = v_usuario
     WHERE id = r.merma_id AND sucursal_id = v_sucursal;
    IF r.promocion_id IS NOT NULL THEN
      v_fardos := jsonb_set(v_fardos, ARRAY[r.producto_id::text],
                            to_jsonb(COALESCE((v_fardos->>r.producto_id::text)::int, 0) + r.cantidad));
    END IF;
  END LOOP;

  -- El pedido vuelve a tomar su mercadería: cada línea que la cancelación devolvió,
  -- con su línea (la bajada deja huella) y el origen de la reversión.
  PERFORM set_config('app.stock_origen',   'pedido_cancelacion_revertida', true);
  PERFORM set_config('app.stock_ref_tipo', 'pedido',                       true);
  PERFORM set_config('app.stock_ref_id',   p_pedido_id::text,              true);
  FOR r IN
    SELECT pi.id, pi.producto_id, pi.cantidad
      FROM pedido_items pi
     WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
       AND pi.cantidad > 0
       AND (NOT COALESCE(pi.es_bonificacion, false)
            OR COALESCE(public._regalo_modo_del_pedido(p_pedido_id, pi.promocion_id, v_sucursal), false))
     ORDER BY pi.id
  LOOP
    PERFORM set_config('app.stock_pedido_item_id', r.id::text, true);
    UPDATE productos SET stock = stock - r.cantidad
     WHERE id = r.producto_id AND sucursal_id = v_sucursal;
  END LOOP;
  PERFORM set_config('app.stock_pedido_item_id', '', true);

  -- Los regalos que vuelven, a su barra: el inverso de la cancelación, con el mismo
  -- motor y la misma barra (por promo y sabor). Todos valen (_regalo_barra_vale):
  -- los que no, ya se sacaron.
  FOR r IN
    SELECT key AS contenedor_id FROM jsonb_each(v_fardos) ORDER BY 1
  LOOP
    v_antes := jsonb_set(v_antes, ARRAY[r.contenedor_id],
                         to_jsonb((SELECT stock FROM productos
                                    WHERE id = r.contenedor_id::bigint AND sucursal_id = v_sucursal)));
  END LOOP;

  FOR r IN
    SELECT pi.promocion_id, pi.producto_id, SUM(pi.cantidad)::int AS cantidad
      FROM pedido_items pi
     WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
       AND COALESCE(pi.es_bonificacion, false) AND pi.promocion_id IS NOT NULL
     GROUP BY 1, 2
     ORDER BY 1, 2
  LOOP
    PERFORM public.aplicar_uso_promo_acumulador(
      r.promocion_id, r.producto_id, r.cantidad,
      r.producto_id, v_sucursal, v_usuario,
      'Cancelación revertida, pedido #' || p_pedido_id);
  END LOOP;

  -- El fardo que volvió y el motor no volvió a cerrar no existía: se merma de nuevo,
  -- como lo mermó la cancelación.
  FOR r IN
    SELECT key AS contenedor_id, value::int AS vuelto FROM jsonb_each_text(v_fardos) ORDER BY 1
  LOOP
    SELECT stock INTO v_stock FROM productos
     WHERE id = r.contenedor_id::bigint AND sucursal_id = v_sucursal;
    v_dif := r.vuelto - GREATEST((v_antes->>r.contenedor_id)::int - v_stock, 0);
    IF v_dif > 0 THEN
      INSERT INTO mermas_stock (
        producto_id, cantidad, motivo, observaciones,
        stock_anterior, stock_nuevo, usuario_id, sucursal_id
      ) VALUES (
        r.contenedor_id::bigint, v_dif, 'error_inventario',
        'Cancelacion revertida, pedido #' || p_pedido_id || ': fardo de promo que no se volvio a cerrar',
        v_stock, GREATEST(v_stock - v_dif, 0), v_usuario, v_sucursal
      ) RETURNING id INTO v_merma_id;
      PERFORM set_config('app.stock_origen',   'merma',          true);
      PERFORM set_config('app.stock_ref_tipo', 'mermas_stock',   true);
      PERFORM set_config('app.stock_ref_id',   v_merma_id::text, true);
      UPDATE productos SET stock = stock - v_dif
       WHERE id = r.contenedor_id::bigint AND sucursal_id = v_sucursal;
    END IF;
  END LOOP;

  PERFORM set_config('app.stock_origen',         '', true);
  PERFORM set_config('app.stock_ref_tipo',       '', true);
  PERFORM set_config('app.stock_ref_id',         '', true);
  PERFORM set_config('app.stock_user_id',        '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);

  -- Cobros: vuelven, por id y enteros hasta lo que la boleta debe, los pagos que esta
  -- cancelación desimputó y siguen sueltos del cliente. Lo que ya se aplicó a otra
  -- boleta se queda ahí (decisión del dueño). Sin foto no vuelve nada. Un vale blanco
  -- no tiene pagos (mig 317).
  IF v_con_foto AND NOT v_es_vb AND cardinality(v_foto.pagos_liberados) > 0 THEN
    v_falta := v_total;
    FOR r IN
      SELECT id, monto
        FROM pagos
       WHERE id = ANY (v_foto.pagos_liberados)
         AND pedido_id IS NULL
         AND cliente_id = v_pedido.cliente_id
         AND sucursal_id = v_sucursal
       ORDER BY id
         FOR UPDATE
    LOOP
      IF r.monto > 0 AND r.monto <= v_falta + 0.005 THEN
        UPDATE pagos
           SET pedido_id = p_pedido_id,
               notas = NULLIF(btrim(public._notas_sin_saldo_a_favor(notas)), '')
         WHERE id = r.id;
        v_falta := v_falta - r.monto;
        v_vueltos := v_vueltos || r.id;
        v_monto_vuelto := v_monto_vuelto + r.monto;
      END IF;
    END LOOP;
  END IF;

  IF v_con_foto THEN
    UPDATE pedido_cancelacion_foto
       SET revertida_at = now(), revertida_por = v_usuario, pagos_vueltos = v_vueltos
     WHERE id = v_foto.id;
  END IF;

  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
  VALUES (
    p_pedido_id, v_usuario, 'estado', 'cancelado',
    'pendiente - Cancelación revertida | Total: $' || round(v_total, 2)
      || ' | Cobro que volvió: $' || round(v_monto_vuelto, 2)
      || CASE WHEN jsonb_array_length(v_mermas) > 0
              THEN ' | Mermas anuladas: ' || jsonb_array_length(v_mermas) ELSE '' END
      || CASE WHEN jsonb_array_length(v_quitados) > 0
              THEN ' | Sin el regalo de: '
                   || (SELECT string_agg(COALESCE(q->>'promocion', '#' || (q->>'promocion_id')) || ' (' || (q->>'motivo') || ')', ', ')
                         FROM jsonb_array_elements(v_quitados) q)
              ELSE '' END
      || CASE WHEN NOT v_con_foto THEN ' | Cancelación sin foto: no volvió ningún cobro' ELSE '' END,
    v_sucursal
  );

  RETURN jsonb_build_object(
    'success', true,
    'pedido_id', p_pedido_id,
    'total', round(v_total, 2),
    'cobro_vuelto', round(v_monto_vuelto, 2),
    'pagos_vueltos', cardinality(v_vueltos),
    'regalos_quitados', v_quitados,
    'mermas_anuladas', jsonb_array_length(v_mermas),
    'sin_foto', NOT v_con_foto,
    'mensaje', 'Cancelación revertida: el pedido volvió a pendiente y volvió a descontar su stock'
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.revertir_cancelacion_pedido(bigint, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.revertir_cancelacion_pedido(bigint, uuid) TO authenticated;

COMMENT ON FUNCTION public.revertir_cancelacion_pedido(bigint, uuid) IS
  'Revierte la cancelación de un pedido (sólo admin): vuelve a pendiente sin ruta, con sus totales, vuelve a descontar el stock (rechaza si no alcanza), anula las mermas de la falta de stock, saca el regalo sin cupo o de una barra que ya no vale, y le devuelve los cobros de la cancelación que siguen sueltos. Ver la migración NNN_revertir_cancelacion.';

-- =========================================================================
-- 5 · audit_productos_update: la bajada de la reversión es una baja por venta
-- =========================================================================
DO $audit$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_triggerdef(t.oid) INTO v_def
    FROM pg_trigger t
   WHERE t.tgrelid = 'public.productos'::regclass AND t.tgname = 'audit_productos_update';
  v_def := pg_temp.parche(v_def,
    $a$'pedido_editado'::text]$a$,
    $r$'pedido_editado'::text, 'pedido_cancelacion_revertida'::text]$r$,
    'audit_productos_update (WHEN)');
  DROP TRIGGER audit_productos_update ON public.productos;
  EXECUTE v_def;
END
$audit$;

-- ---------------------------------------------------------------------------
-- Poscondiciones
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  v_mal text[] := '{}';
  v text;
BEGIN
  SELECT prosrc INTO v FROM pg_proc WHERE oid = 'public.cancelar_pedido_con_stock(bigint,text,uuid,text)'::regprocedure;
  IF v NOT LIKE '%INSERT INTO pedido_cancelacion_foto%' OR v NOT LIKE '%v_foto_mermas := v_foto_mermas%' THEN
    v_mal := v_mal || 'cancelar_pedido_con_stock no guarda la foto'::text;
  END IF;
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.cancelar_pedido_con_stock(bigint,text,uuid,text)'::regprocedure) THEN
    v_mal := v_mal || 'cancelar_pedido_con_stock dejó de ser DEFINER'::text;
  END IF;
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.revertir_cancelacion_pedido(bigint,uuid)'::regprocedure) THEN
    v_mal := v_mal || 'revertir_cancelacion_pedido no es DEFINER'::text;
  END IF;
  IF has_function_privilege('anon', 'public.revertir_cancelacion_pedido(bigint,uuid)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.revertir_cancelacion_pedido(bigint,uuid)', 'EXECUTE') THEN
    v_mal := v_mal || 'revertir_cancelacion_pedido: EXECUTE debe ser sólo de authenticated'::text;
  END IF;
  IF has_function_privilege('anon', 'public.pedidos_guard_baja()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.pedidos_guard_baja()', 'EXECUTE') THEN
    v_mal := v_mal || 'pedidos_guard_baja tiene EXECUTE para la API'::text;
  END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.pedido_cancelacion_foto'::regclass)
     OR EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'public.pedido_cancelacion_foto'::regclass)
     OR has_table_privilege('authenticated', 'public.pedido_cancelacion_foto', 'SELECT')
     OR has_table_privilege('anon', 'public.pedido_cancelacion_foto', 'SELECT')
     OR has_table_privilege('authenticated', 'public.pedido_cancelacion_foto', 'INSERT') THEN
    v_mal := v_mal || 'pedido_cancelacion_foto no quedó sólo de server (RLS sin policies y sin grants)'::text;
  END IF;
  IF (SELECT count(*) FROM pg_constraint
       WHERE conrelid = 'public.pedido_cancelacion_foto'::regclass AND contype = 'f') <> 1 THEN
    v_mal := v_mal || 'pedido_cancelacion_foto tiene que tener una sola FK (la del pedido)'::text;
  END IF;
  SELECT pg_get_triggerdef(t.oid) INTO v
    FROM pg_trigger t
   WHERE t.tgrelid = 'public.productos'::regclass AND t.tgname = 'audit_productos_update';
  IF v IS NULL OR v NOT LIKE '%''pedido_cancelacion_revertida''::text]%' THEN
    v_mal := v_mal || 'audit_productos_update no tiene el origen de la reversión'::text;
  END IF;

  IF cardinality(v_mal) > 0 THEN
    RAISE EXCEPTION 'mig NNN · no quedó como en el repo: %', array_to_string(v_mal, ' | ');
  END IF;
END
$post$;

COMMIT;
