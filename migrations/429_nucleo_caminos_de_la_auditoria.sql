-- ============================================================================
-- 429 · Núcleo: los caminos que vio la auditoría de módulos (#1329)
-- ============================================================================
-- Tarjeta 7 del plan #1308. Aplicar desde el contenido LF.
-- Ensayo: scripts/test-rendicion-nucleo-1328-1329.sql (P1, C1, D1, F1, V1 y O1).
--
-- De los ocho, se confirmaron seis contra prod. Dos se tacharon en el issue:
--   · `eliminar_pedido_completo`: no se ejecuta por REST desde #1147, y el sistema
--     viejo no tiene ninguna rendición cerrada.
--   · `mt_salvedades_items_select`: el chofer no ve la salvedad de un VB. El
--     EXISTS sobre `pedidos` corre con la RLS de `pedidos`, que ya se lo oculta, y
--     el vendedor del VB ve la línea entera por `mt_pedido_items_select`.
--
-- QUÉ ES ESTO
-- -----------
-- posicion_fiscal · La Red era una copia de `_sucursales_red()`. Hoy dan lo mismo;
--   la regla de #1262 es que no haya copia. No mueve ningún número.
-- _aplicar_cambio_producto · Sumaba la diferencia del canje a `saldo_cuenta` sin
--   una boleta o un pago detrás. El primer canje con diferencia ponía rojo CC-A
--   (critical), y la deuda no se podía cobrar: el pago quedaba como crédito y el
--   saldo arrastraba la diferencia para siempre. Decisión del dueño (31/10): la
--   diferencia es informativa. Queda en `cambios_productos.diferencia_monto` y, si
--   hay que cobrarla, se hace un pedido. El único canje de prod tiene diferencia
--   0: no hay nada que revertir.
-- desafectar_sobrepago_pedido · Recortaba cualquier pago. La regla de 165-168 es
--   para el cobro de boleta, que se carga por el total y queda inflado si el total
--   baja. Un pago a cuenta de la ficha es plata que entró: $200 por FIFO sobre una
--   boleta que baja a $150 dejaban $150 en pagos y $0 a favor. Decisión del dueño
--   (31/10): queda a favor del cliente. Como eso no mueve la caja del día, va por
--   el escape de la reimputación (como `_pagos_excedente_a_favor`), y la
--   reconciliación lo imputa enseguida a otra boleta.
--   `pagos.a_cuenta` marca lo que cargan los dos FIFO. Rige para adelante: en los
--   pagos viejos no se puede distinguir. También la llevan los créditos que se
--   imputan enteros (`aplicar_credito_cliente`, `imputar_credito_a_pedido_impl`):
--   sin eso, un cobro que quedó a favor y se reimputó se perdía igual. Un pedazo
--   (`pago_origen_id`) nació de un crédito, así que también cuenta. El crédito de
--   una NC sigue por su rama. El adelanto de sueldo no es plata que entró: se recorta.
--   El loop ahora bloquea los pagos FOR UPDATE: partir un pago lo pide (#1292).
-- actualizar_forma_pago_pago · Era el único camino con otro criterio de caja:
--   miraba si alguien cerró ESE día. El guard (`guard_pago_fecha_cerrada`) dice
--   que la caja está cerrada hasta la última fecha controlada de la sucursal, y
--   el trigger no cubre `forma_pago`. Ahora usa el del guard. Los otros que llaman
--   a `rendicion_dia_cerrada` insertan pagos y pasan por el guard después.
-- crear_rendicion_recorrido, presentar_rendicion, revisar_rendicion ·
--   Sistema viejo: 1 fila de abril, nada las llama, no filtran por sucursal. Se
--   dropean, con `es_admin_rendiciones`, que sólo la usaban ellas. Las tablas van
--   a su propio issue.
-- registrar_origen_precio_items · Con sesión ignoraba `p_perfil_id` y no miraba la
--   sucursal del pedido: un admin escribía un pedido de otra. Ahora, con sesión, el
--   pedido es de la sucursal activa y `p_perfil_id`, si viene, es el que llama. El
--   bot, sin sesión, sigue igual.

BEGIN;

-- ---------------------------------------------------------------------------
-- 0 · Premisas: nada cambió en prod desde que se leyeron los cuerpos
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, md5(pg_get_functiondef(x.firma::regprocedure)) AS md5_vivo
      FROM (VALUES
        ('public.posicion_fiscal(bigint,date,date)',                '23676382d9108e56043d043c561982d5'),
        ('public._aplicar_cambio_producto(integer,bigint,integer,bigint,integer,text,bigint,uuid,text)',
                                                                    '786dea42d9c0b1513940f395911d6af0'),
        ('public.desafectar_sobrepago_pedido(bigint)',              'b18ae82fdb8e10f80c482ea80c31704d'),
        ('public.registrar_pago_cliente_fifo_impl(bigint,numeric,text,date,text,text)',
                                                                    '3585f30de0d3fc64c5554738f3d9cbad'),
        ('public.registrar_pago_combinado_cliente_fifo_impl(bigint,jsonb,date,text,text)',
                                                                    'd1844c076b2d051619c4099ba490bb91'),
        ('public.aplicar_credito_cliente(bigint,bigint)',           '7afa431d5125c00c1f7e2c7d4e1a41c8'),
        ('public.imputar_credito_a_pedido_impl(bigint,bigint,numeric)',
                                                                    '12a9ee412bc4497b7d631bffd6a9df17'),
        ('public.actualizar_forma_pago_pago(bigint,text)',          '05605e43bb765fb8a64b983ed30ebeee'),
        ('public.registrar_origen_precio_items(bigint,jsonb,uuid)', '2cd04df7e96d23e89c6cc461c1a792d3'),
        ('public.crear_rendicion_recorrido(bigint,uuid)',           '0406b6a952627af0e3ecf3785d41fdd0'),
        ('public.presentar_rendicion(bigint,numeric,text)',         '1f1b3737e58ef8701f1b3979ac30df81'),
        ('public.revisar_rendicion(bigint,character varying,text)', 'ddc112fe6c20e2f513f4b520470bcf1c'),
        ('public.es_admin_rendiciones()',                           'cb2faf24e83653b59967a424abd95e12')
      ) AS x(firma, md5)
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION 'mig 429 · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 1 · El sistema viejo de rendiciones
-- ---------------------------------------------------------------------------
DROP FUNCTION public.crear_rendicion_recorrido(bigint, uuid);
DROP FUNCTION public.presentar_rendicion(bigint, numeric, text);
DROP FUNCTION public.revisar_rendicion(bigint, character varying, text);
DROP FUNCTION public.es_admin_rendiciones();

-- ---------------------------------------------------------------------------
-- 2 · pagos.a_cuenta
-- ---------------------------------------------------------------------------
ALTER TABLE public.pagos ADD COLUMN a_cuenta boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.pagos.a_cuenta IS
  'Lo cargo un FIFO de la ficha: es plata que entro, no un cobro por el total de la boleta. Si la boleta baja, lo que sobra queda a favor del cliente (#1329). Desde la 429: los pagos viejos no se distinguen.';

-- ---------------------------------------------------------------------------
-- 3 · Parches por ancla
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _n_parche (firma text, orden int, ancla text, reemplazo text, veces int DEFAULT 1) ON COMMIT DROP;

INSERT INTO _n_parche (firma, orden, ancla, reemplazo) VALUES
-- posicion_fiscal
('public.posicion_fiscal(bigint,date,date)', 1,
$a$    SELECT array_agg(id) INTO v_sucursales FROM sucursales WHERE activa;
    IF NOT v_es_servicio THEN
      SELECT array_agg(s) INTO v_sucursales FROM unnest(v_sucursales) AS s WHERE s = ANY(v_asignadas); END IF;
$a$,
$r$    -- #1329: la misma Red que los reportes (#1262), no una copia.
    v_sucursales := public._sucursales_red();
$r$),

-- _aplicar_cambio_producto
('public._aplicar_cambio_producto(integer,bigint,integer,bigint,integer,text,bigint,uuid,text)', 1,
$a$  UPDATE clientes
     SET saldo_cuenta = COALESCE(saldo_cuenta, 0) + v_diferencia
   WHERE id = p_cliente_id;

$a$,
$r$  -- #1329: la diferencia es informativa, decision del dueño. Sumarla a
  -- saldo_cuenta, sin boleta ni pago detras, rompia CC-A y no se podia cobrar:
  -- si hay que cobrarla, se hace un pedido.

$r$),

-- registrar_pago_cliente_fifo_impl
('public.registrar_pago_cliente_fifo_impl(bigint,numeric,text,date,text,text)', 1,
$a$      referencia, notas, usuario_id, sucursal_id
    )
    VALUES (
      p_cliente_id, v_pedido.id, v_aplicar, v_forma, p_fecha,
      p_referencia, p_notas, v_acting_user, v_sucursal_id
    )
$a$,
$r$      referencia, notas, usuario_id, sucursal_id, a_cuenta
    )
    VALUES (
      p_cliente_id, v_pedido.id, v_aplicar, v_forma, p_fecha,
      p_referencia, p_notas, v_acting_user, v_sucursal_id, true
    )
$r$),
('public.registrar_pago_cliente_fifo_impl(bigint,numeric,text,date,text,text)', 2,
$a$      referencia, notas, usuario_id, sucursal_id
    )
    VALUES (
      p_cliente_id, NULL, v_restante, v_forma, p_fecha,
      p_referencia,
      COALESCE(NULLIF(p_notas, '') || ' ', '') || '[saldo a favor]',
      v_acting_user, v_sucursal_id
    )
$a$,
$r$      referencia, notas, usuario_id, sucursal_id, a_cuenta
    )
    VALUES (
      p_cliente_id, NULL, v_restante, v_forma, p_fecha,
      p_referencia,
      COALESCE(NULLIF(p_notas, '') || ' ', '') || '[saldo a favor]',
      v_acting_user, v_sucursal_id, true
    )
$r$),

-- registrar_pago_combinado_cliente_fifo_impl
('public.registrar_pago_combinado_cliente_fifo_impl(bigint,jsonb,date,text,text)', 1,
$a$        referencia, notas, usuario_id, sucursal_id
      )
      VALUES (
        p_cliente_id, v_pedido.id, v_aplicar, v_forma, p_fecha,
        p_referencia, v_notas_imputado, v_acting_user, v_sucursal_id
      )
$a$,
$r$        referencia, notas, usuario_id, sucursal_id, a_cuenta
      )
      VALUES (
        p_cliente_id, v_pedido.id, v_aplicar, v_forma, p_fecha,
        p_referencia, v_notas_imputado, v_acting_user, v_sucursal_id, true
      )
$r$),
('public.registrar_pago_combinado_cliente_fifo_impl(bigint,jsonb,date,text,text)', 2,
$a$        referencia, notas, usuario_id, sucursal_id
      )
      VALUES (
        p_cliente_id, NULL, v_restante, v_forma, p_fecha,
        p_referencia,
        trim(COALESCE(p_notas, '') || ' [pago combinado] [saldo a favor]'),
        v_acting_user, v_sucursal_id
      )
$a$,
$r$        referencia, notas, usuario_id, sucursal_id, a_cuenta
      )
      VALUES (
        p_cliente_id, NULL, v_restante, v_forma, p_fecha,
        p_referencia,
        trim(COALESCE(p_notas, '') || ' [pago combinado] [saldo a favor]'),
        v_acting_user, v_sucursal_id, true
      )
$r$),

-- aplicar_credito_cliente
('public.aplicar_credito_cliente(bigint,bigint)', 1,
$a$           SET pedido_id = v_pedido.id,
               notas = NULLIF(trim(replace(COALESCE(notas, ''), '[saldo a favor]', '')), '')
$a$,
$r$           SET pedido_id = v_pedido.id,
               -- #1329: un credito es plata que entro.
               a_cuenta = true,
               notas = NULLIF(trim(replace(COALESCE(notas, ''), '[saldo a favor]', '')), '')
$r$),

-- imputar_credito_a_pedido_impl
('public.imputar_credito_a_pedido_impl(bigint,bigint,numeric)', 1,
$a$       SET pedido_id = p_pedido_id,
           notas = NULLIF(trim(replace(COALESCE(notas, ''), '[saldo a favor]', '')), '')
$a$,
$r$       SET pedido_id = p_pedido_id,
           -- #1329: un credito es plata que entro.
           a_cuenta = true,
           notas = NULLIF(trim(replace(COALESCE(notas, ''), '[saldo a favor]', '')), '')
$r$),

-- desafectar_sobrepago_pedido
('public.desafectar_sobrepago_pedido(bigint)', 1,
$a$  v_nota       text;
BEGIN
$a$,
$r$  v_nota       text;
  v_guc        text;
  v_marca      text;
BEGIN
$r$),
('public.desafectar_sobrepago_pedido(bigint)', 2,
$a$    SELECT id, monto, cliente_id, forma_pago, fecha, referencia, usuario_id,
           sucursal_id, nota_credito_id, pago_origen_id
      FROM pagos
     WHERE pedido_id = p_pedido_id
     ORDER BY fecha DESC, id DESC
  LOOP
    EXIT WHEN v_excedente <= 0.005;

    v_quitar := LEAST(v_pago.monto, v_excedente);
$a$,
$r$    SELECT id, monto, cliente_id, forma_pago, fecha, referencia, usuario_id,
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

        INSERT INTO pagos (
          cliente_id, pedido_id, monto, forma_pago, fecha,
          referencia, notas, usuario_id, sucursal_id, pago_origen_id, a_cuenta
        )
        SELECT cliente_id, NULL, v_quitar, forma_pago, fecha, referencia,
               trim(COALESCE(notas, '') || v_marca),
               usuario_id, sucursal_id, COALESCE(pago_origen_id, id), true
          FROM pagos
         WHERE id = v_pago.id;
      END IF;

      PERFORM set_config('app.reimputacion_pagos', COALESCE(v_guc, ''), true);

      v_excedente := v_excedente - v_quitar;
      v_quitado   := v_quitado + v_quitar;
      CONTINUE;
    END IF;
$r$),

-- actualizar_forma_pago_pago
('public.actualizar_forma_pago_pago(bigint,text)', 1,
$a$  v_nueva_forma_pedido text;
BEGIN
$a$,
$r$  v_nueva_forma_pedido text;
  v_limite date;
BEGIN
$r$),
('public.actualizar_forma_pago_pago(bigint,text)', 2,
$a$  IF public.rendicion_dia_cerrada(v_pago.fecha, v_sucursal_id) THEN
    RAISE EXCEPTION 'Rendicion ya cerrada para esta fecha. No se puede modificar.'
      USING ERRCODE = '42501';
  END IF;
$a$,
$r$  -- #1329: el criterio de guard_pago_fecha_cerrada, que no cubre forma_pago.
  v_limite := public.ultima_fecha_caja_cerrada(v_sucursal_id);
  IF v_limite IS NOT NULL AND v_pago.fecha <= v_limite THEN
    RAISE EXCEPTION 'La caja de la sucursal esta cerrada hasta el % (rendicion controlada). No se puede cambiar la forma de un pago con fecha %. Reabri las rendiciones hasta esa fecha para hacer cambios.',
      to_char(v_limite, 'DD/MM/YYYY'), to_char(v_pago.fecha, 'DD/MM/YYYY')
      USING ERRCODE = '42501';
  END IF;
$r$),

-- registrar_origen_precio_items
('public.registrar_origen_precio_items(bigint,jsonb,uuid)', 1,
$a$  v_caller := COALESCE(v_uid, p_perfil_id);

$a$,
$r$  -- #1329: con sesion manda la sesion. p_perfil_id es del server (el bot), y el
  -- pedido tiene que ser de la sucursal activa.
  IF v_uid IS NOT NULL AND (p_perfil_id <> auth.uid()
                            OR v_sucursal IS DISTINCT FROM current_sucursal_id()) THEN
    RAISE EXCEPTION 'Sin permiso para registrar el origen del precio de este pedido'
      USING ERRCODE = '42501';
  END IF;

  v_caller := COALESCE(v_uid, p_perfil_id);

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
        RAISE EXCEPTION 'mig 429 · % parche %: el ancla aparece % vez/veces y se esperaba %',
          v_f.firma, v_p.orden, v_n, v_p.veces;
      END IF;
      v_def := replace(v_def, v_p.ancla, v_p.reemplazo);
    END LOOP;
    EXECUTE v_def;
  END LOOP;
END
$parches$;

COMMIT;
