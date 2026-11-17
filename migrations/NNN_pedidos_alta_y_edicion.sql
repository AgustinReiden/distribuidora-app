-- =========================================================================
-- NNN · PEDIDOS: EL ALTA Y LA EDICIÓN
--       (ola 2 del plan #1603, tarjeta B4: 1558-b2, 1592-b1, 1559-b1 a b10,
--        1561-b4, 1595-b6, 1595-b9, 1543-b2, 1601-b4 con su parte de 1601-b9,
--        SEG-1 de #1545 en cambiar_tipo_factura_pedido y M10-2 de la ola 1)
--
-- Parcha por ancla, con premisa de md5 sobre el cuerpo vivo del 16/11 (ledger
-- en la 512): crear_pedido_completo, crear_pedido_completo_bot,
-- crear_pedido_idempotente, actualizar_pedido_items, actualizar_preventista_pedido,
-- cambiar_tipo_factura_pedido, pedidos_proteger_columnas,
-- validar_precio_item_pedido y registrar_origen_precio_items. Le suma un
-- parámetro con DEFAULT a actualizar_fechas_y_notas_pedido (dropea la firma
-- vieja). Crea dos funciones (_fecha_entrega_programada_fuera_de_rango y la RPC
-- de lectura dias_atras_fecha_pedido) y dos FK compuestas a grupo_precio_escalas.
-- Ensayo: scripts/test-pedidos-alta-edicion-ola2-1603.sql. Se aplica en LF.
--
-- -------------------------------------------------------------------------
-- El alta (crear_pedido_completo). Nada cambia de firma ni de contrato: un
-- PWA viejo o un alta encolada con los parámetros de hoy sigue entrando. Lo
-- que se rechaza de nuevo es dato inválido, con success=false y el motivo
-- en castellano (la cola lo toma como rechazo definitivo y lo muestra).
--   · 1561-b4 (D33): una sucursal inactiva no acepta pedidos. Se mira en el
--     alta, no en current_sucursal_id() ni en los helpers de rol. El cambio de
--     cliente (app.cambio_cliente_desde) no es un pedido nuevo y pasa.
--   · 1559-b7: el cliente tiene que ser de la sucursal activa. Antes el alta
--     contestaba el nombre de un cliente inactivo de otra sucursal; uno activo
--     de otra sucursal moría en la FK compuesta con un 23503 crudo.
--   · 1559-b5: la forma de pago del pedido es una de formas_pago() que se
--     registra y es dinero (efectivo, transferencia, cheque, tarjeta), o la
--     histórica 'cuenta_corriente' (un bundle viejo la ofrecía). NULL sigue
--     entrando. El vale blanco la pisa con 'efectivo' y no se mira; el cambio
--     de cliente copia la del pedido original y tampoco.
--   · 1559-b6 (D21): la entrega programada va de hoy a 60 días adelante. El
--     piso es la fecha del pedido si es anterior a hoy: un alta encolada ayer
--     llega con la programada de ayer, y el admin carga o atrasa pedidos viejos
--     (el modal corre la programada con la fecha). La regla es
--     _fecha_entrega_programada_fuera_de_rango; la edición la cumple, si la
--     programada cambia, por pedidos_proteger_columnas.
--   · 1558-b2 (D4): todo regalo baja stock. Un regalo sin promoción no
--     descontaba nada (y la cancelación, la edición y la salvedad tampoco lo
--     devuelven), así que no puede nacer: el alta lo rechaza para todo rol, con
--     el código de regalo_fuera_de_promo para que el replay ofrezca sincronizar
--     sin él. El cambio de cliente sí lo recrea (cambiar_cliente_pedido exige
--     el mismo regalo que el pedido original, que tampoco lo descontó).
--   · 1559-b1: se guarda la suma calculada, no p_total (la tolerancia de un
--     centavo dejaba el total corrido de SUM(subtotal) y del desglose).
--   · 1543-b2: el escape de la 480b para un producto desactivado en el cambio
--     de cliente rige por tipo de línea y hasta la cantidad del pedido original.
-- crear_pedido_completo_bot: 1558-b2 igual (sólo eso, por la ficha).
-- crear_pedido_idempotente (1559-b4): el replay de una clave sólo le devuelve
-- el pedido a quien lo cargó.
--
-- La edición:
--   · actualizar_pedido_items
--     - 1595-b9 (D24): el preventista no edita el pedido de un cliente dado de
--       baja (lo cierran el encargado o el admin), ni el de un cliente que ya no
--       puede operar (reservado, o asignado a otro preventista).
--     - 1558-b2: no suma un regalo sin promoción; uno que el pedido ya tenía
--       (datos de antes) se conserva o se baja.
--     - 1592-b1: un regalo cambiado por valor que viene en el producto y la
--       cantidad de la línea (R×10 → W×1, un caller que manda W×1) se reinserta
--       con su corte (10), no con 1: si no, el cupo de la promo perdía 9.
--     - 1559-b3 (D20): un producto que hoy quedó sin precio de lista se conserva
--       a su precio guardado, hasta la cantidad que tenía (lo deja pasar
--       validar_precio_item_pedido con app.edicion_precio_conservado).
--   · actualizar_fechas_y_notas_pedido (1559-b10): recibe p_updated_at_esperado
--     (DEFAULT NULL: el bundle viejo no lo manda y no compara) y rechaza con
--     'pedido_editado_por_otro' si el pedido cambió.
--   · actualizar_preventista_pedido (1559-b9): devuelve updated_at_anterior y
--     updated_at, como sustituir o dividir un regalo.
--   · pedidos_proteger_columnas
--     - 1595-b6: la versión (updated_at) no la elige el cliente. Un UPDATE por
--       REST (o por una RPC INVOKER) que cambia algo la mueve a now(); uno que
--       no cambia nada la deja como estaba. Así un PATCH ya no repone la versión
--       vieja para pisar la edición de otro. No se revoca el GRANT de la columna:
--       el PWA viejo la manda al marcar una entrega (usePedidosQuery) y el PATCH
--       entero daría 42501; el front nuevo deja de mandarla.
--     - 1559-b6: la programada que se cambia va de hoy (o de la fecha del pedido,
--       si es anterior) a 60 días, para todos.
--     - 1559-b8: un vale blanco no pasa a fecha futura, tampoco por el admin.
--   · cambiar_tipo_factura_pedido: 1559-b2 (LEFT JOIN a productos en el pase
--     ZZ ↔ FC) y SEG-1 de #1545 (el rol de quien llama, con activo). 1595-b11
--     (D25) no cambia nada: el pase de un entregado ya es sólo del admin.
--   · registrar_origen_precio_items (1601-b4): sólo escribe una escala de la
--     sucursal del pedido; y pedido_items.grupo_precio_escala_id (1601-b9) y la
--     foto de la salvedad tienen FK compuesta, ON DELETE SET NULL de la columna
--     (anular_salvedad reinserta la escala de la foto).
--
-- M10-2 (ola 1): dias_atras_fecha_pedido(), una RPC de lectura que devuelve los
-- días de la política que usa el server (_dias_atras_fecha_pedido, 7 sin fila),
-- para el front del depósito con el rol extra de chofer y de quien la RLS no
-- le deja leer la fila.
--
-- Orden de despliegue: la migración antes que el front (el front nuevo manda
-- p_updated_at_esperado y llama a dias_atras_fecha_pedido). El front viejo
-- sigue andando con la migración aplicada.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

-- Las FK nuevas (sección 11) son DDL sobre pedido_items y salvedad_linea_foto, y le toman
-- lock a grupo_precio_escalas. Todos juntos y al principio, sin esperar: tomados de a uno,
-- en otro orden que el del alta de un pedido, daban deadlock con la app. Si alguno está
-- tomado la migración falla al instante y se reintenta.
LOCK TABLE public.pedido_items, public.salvedad_linea_foto, public.grupo_precio_escalas
  IN ACCESS EXCLUSIVE MODE NOWAIT;

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
    ('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)', '06de31250f5ef0437f68625f6f46401e'),
    ('public.crear_pedido_completo_bot(uuid,uuid)', '7abf9cba158eae650853ef3348963238'),
    ('public.crear_pedido_idempotente(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid,text)', '63f0759223a668afdd04ce684aee18ef'),
    ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'b6e7138c67b92ea84196e0856cf37fca'),
    ('public.actualizar_fechas_y_notas_pedido(bigint,text,date,timestamp with time zone,date)', 'd96e3c0a38d363c0a51029af90bc0dca'),
    ('public.actualizar_preventista_pedido(bigint,uuid)', '111245f6fb109d8827264ad20458662b'),
    ('public.cambiar_tipo_factura_pedido(bigint,character varying,uuid)', '6d80f9a7597bd645c5c1704bc7620b04'),
    ('public.pedidos_proteger_columnas()', '2ab9c05bb89a01c0633df5e376000e52'),
    ('public.validar_precio_item_pedido()', '9b6899320148d9212729b2634d68f2fd'),
    ('public.registrar_origen_precio_items(bigint,jsonb,uuid)', '07b3f92a471f695e3af5d99ed18e8001'),
    -- No cambian, pero lo nuevo cuenta con ellas como están.
    ('public._dias_atras_fecha_pedido(bigint)', 'd9c04f85466d1a1cb9aa12a8fdac48bd')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;
  IF to_regproc('public._fecha_entrega_programada_fuera_de_rango') IS NOT NULL
     OR to_regproc('public.dias_atras_fecha_pedido') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · una función nueva ya existe: revisar a mano';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'grupo_precio_escalas_id_sucursal_uk'
                    AND conrelid = 'public.grupo_precio_escalas'::regclass)
     OR NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.salvedad_linea_foto'::regclass
                     AND attname = 'grupo_precio_escala_id' AND NOT attisdropped) THEN
    RAISE EXCEPTION 'mig NNN · falta UNIQUE (id, sucursal_id) de grupo_precio_escalas o salvedad_linea_foto.grupo_precio_escala_id';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint
              WHERE conrelid IN ('public.pedido_items'::regclass, 'public.salvedad_linea_foto'::regclass)
                AND contype = 'f' AND confrelid = 'public.grupo_precio_escalas'::regclass) THEN
    RAISE EXCEPTION 'mig NNN · ya hay una FK a grupo_precio_escalas: revisar a mano';
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
-- 1 · Las reglas nuevas
-- =========================================================================

-- 1559-b6 (D21 del plan #1603): la fecha de entrega programada de un pedido va de
-- p_piso (hoy, o la fecha del pedido si es anterior) hasta 60
-- días después de hoy, el día argentino. NULL: entra. La llaman crear_pedido_completo y
-- pedidos_proteger_columnas (INVOKER, como authenticated). Espejo del techo en el front:
-- src/utils/fechaEntregaProgramada.ts.
CREATE FUNCTION public._fecha_entrega_programada_fuera_de_rango(p_fecha date, p_piso date)
RETURNS text
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
  SELECT CASE
           WHEN p_fecha IS NULL THEN NULL
           WHEN p_fecha > r.hoy + 60 THEN format(
             'La fecha de entrega programada (%s) no puede ser posterior al %s: va hasta 60 días adelante.',
             to_char(p_fecha, 'DD/MM/YYYY'), to_char(r.hoy + 60, 'DD/MM/YYYY'))
           WHEN p_piso IS NOT NULL AND p_fecha < p_piso THEN format(
             'La fecha de entrega programada (%s) no puede ser anterior al %s.',
             to_char(p_fecha, 'DD/MM/YYYY'), to_char(p_piso, 'DD/MM/YYYY'))
         END
    FROM (SELECT public._tablero_hoy() AS hoy) r
$function$;

REVOKE ALL ON FUNCTION public._fecha_entrega_programada_fuera_de_rango(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._fecha_entrega_programada_fuera_de_rango(date, date) TO authenticated, service_role;

-- M10-2: los días hacia atrás de la fecha del pedido de la sucursal activa, los mismos
-- que aplica el server (_dias_atras_fecha_pedido, DEFINER y acotada a un usuario activo
-- de la sucursal; 7 sin fila, como _fecha_pedido_fuera_de_rango). El front la usa en
-- lugar de la columna de politicas_comerciales, que la RLS le oculta al depósito con el
-- rol extra de chofer.
CREATE FUNCTION public.dias_atras_fecha_pedido()
RETURNS integer
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
  SELECT COALESCE(public._dias_atras_fecha_pedido(public.current_sucursal_id()), 7)
$function$;

REVOKE ALL ON FUNCTION public.dias_atras_fecha_pedido() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.dias_atras_fecha_pedido() TO authenticated, service_role;

-- =========================================================================
-- 2 · crear_pedido_completo
-- =========================================================================
DO $parche_alta$
DECLARE
  v_def text := pg_get_functiondef('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)'::regprocedure);
BEGIN
  -- 1561-b4: la sucursal inactiva, después del rol.
  v_def := pg_temp.parche(v_def,
$a$  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista', 'encargado') THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No tiene permisos para crear pedidos')); END IF;
$a$,
$r$  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista', 'encargado') THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No tiene permisos para crear pedidos')); END IF;

  -- 1561-b4 (#1561, decisión del dueño D33): una sucursal inactiva no acepta pedidos; se
  -- sigue leyendo en los reportes. Se mira acá y no en current_sucursal_id(). El cambio de
  -- cliente (app.cambio_cliente_desde) no es un pedido nuevo: recrea uno que ya existía.
  IF NULLIF(current_setting('app.cambio_cliente_desde', true), '') IS NULL
     AND NOT EXISTS (SELECT 1 FROM sucursales WHERE id = v_sucursal AND COALESCE(activa, true)) THEN
    RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(format(
      'La sucursal %s está dada de baja: no acepta pedidos nuevos. El pedido no se creó.',
      COALESCE((SELECT nombre FROM sucursales WHERE id = v_sucursal), '#' || v_sucursal))));
  END IF;
$r$, 'crear_pedido_completo (sucursal inactiva)');

  -- 1559-b7, 1559-b5 y 1559-b6: el cliente de la sucursal, la forma de pago y la
  -- entrega programada.
  v_def := pg_temp.parche(v_def,
$a$  IF EXISTS (SELECT 1 FROM clientes WHERE id = p_cliente_id AND NOT activo) THEN
    RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(format(
      'El cliente "%s" está dado de baja: no se le pueden cargar pedidos. Si vuelve a comprar, reactivalo desde Clientes.',
      (SELECT COALESCE(nombre_fantasia, '#' || id::text) FROM clientes WHERE id = p_cliente_id))));
  END IF;
$a$,
$r$  -- 1559-b7 (#1559): sólo un cliente de la sucursal activa, y del inactivo se nombra sólo
  -- ése. Antes el de otra sucursal moría en la FK compuesta con un 23503 crudo, o, si
  -- estaba dado de baja, se contestaba su nombre.
  IF NOT EXISTS (SELECT 1 FROM clientes WHERE id = p_cliente_id AND sucursal_id = v_sucursal) THEN
    RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
      'El cliente del pedido no existe en esta sucursal. El pedido no se creó.'));
  END IF;
  IF EXISTS (SELECT 1 FROM clientes WHERE id = p_cliente_id AND sucursal_id = v_sucursal AND NOT activo) THEN
    RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(format(
      'El cliente "%s" está dado de baja: no se le pueden cargar pedidos. Si vuelve a comprar, reactivalo desde Clientes.',
      (SELECT COALESCE(nombre_fantasia, '#' || id::text) FROM clientes
        WHERE id = p_cliente_id AND sucursal_id = v_sucursal))));
  END IF;

  -- 1559-b5 (#1559): la forma de pago del pedido es una de formas_pago() que una persona
  -- registra y es dinero, o la histórica 'cuenta_corriente' (un bundle viejo la ofrecía).
  -- NULL sigue entrando. El vale blanco la pisa con 'efectivo'; el cambio de cliente copia
  -- la del pedido original.
  IF v_tipo_factura <> 'VB' AND p_forma_pago IS NOT NULL
     AND NULLIF(current_setting('app.cambio_cliente_desde', true), '') IS NULL
     AND p_forma_pago <> 'cuenta_corriente'
     AND NOT EXISTS (SELECT 1 FROM public.formas_pago() f
                      WHERE f.forma = p_forma_pago AND f.se_registra AND f.dineraria) THEN
    RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(format(
      'La forma de pago "%s" no es válida para un pedido: va %s. El pedido no se creó.',
      p_forma_pago,
      (SELECT string_agg(f.forma, ', ') FROM public.formas_pago() f WHERE f.se_registra AND f.dineraria))));
  END IF;

  -- 1559-b6 (#1559, decisión del dueño D21): la entrega programada va de hoy a 60 días
  -- adelante. El piso es la fecha del pedido si es anterior a hoy: el alta encolada ayer
  -- llega con la programada de ayer, y el admin carga pedidos viejos. El cambio de cliente
  -- conserva la del pedido original; el vale blanco no la usa.
  IF v_tipo_factura <> 'VB' AND p_fecha_entrega_programada IS NOT NULL
     AND NULLIF(current_setting('app.cambio_cliente_desde', true), '') IS NULL THEN
    v_motivo_fecha := public._fecha_entrega_programada_fuera_de_rango(
      p_fecha_entrega_programada, LEAST(public._tablero_hoy(), v_fecha_pedido));
    IF v_motivo_fecha IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
        v_motivo_fecha || ' El pedido no se creó.'));
    END IF;
  END IF;
$r$, 'crear_pedido_completo (cliente, forma de pago y entrega programada)');

  -- 1558-b2: un regalo es de una promoción.
  v_def := pg_temp.parche(v_def,
$a$      'El pedido tiene que tener al menos un producto que no sea regalo. El pedido no se creó.'));
  END IF;
$a$,
$r$      'El pedido tiene que tener al menos un producto que no sea regalo. El pedido no se creó.'));
  END IF;

  -- 1558-b2 (#1558, decisión del dueño D4): todo regalo baja stock. Uno sin promoción no
  -- descontaba nada, y la cancelación, la edición y la salvedad tampoco lo devuelven: no
  -- puede nacer, para ningún rol. Con el código de regalo_fuera_de_promo, el replay de la
  -- cola ofrece sincronizar sin él. El cambio de cliente lo recrea igual: no es un regalo
  -- nuevo (cambiar_cliente_pedido exige el regalo del pedido original tal cual).
  IF NULLIF(current_setting('app.cambio_cliente_desde', true), '') IS NULL
     AND EXISTS (SELECT 1
                   FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_items) = 'array'
                                                  THEN p_items ELSE '[]'::jsonb END) e
                  WHERE COALESCE((e->>'es_bonificacion')::BOOLEAN, false)
                    AND NULLIF(e->>'promocion_id', '') IS NULL) THEN
    RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
      'Un regalo tiene que ser de una promoción: sin promoción no descuenta stock. Cargalo con su promoción, o como venta. El pedido no se creó.'),
      'codigo', 'regalo_fuera_de_promo');
  END IF;
$r$, 'crear_pedido_completo (regalo sin promoción)');

  -- 1559-b1: se guarda la suma calculada.
  v_def := pg_temp.parche(v_def,
$a$    v_cargo_envio := public.pedido_cargo_envio(v_total_calc, v_sucursal); -- mig 389 (#1220)
$a$,
$r$    -- 1559-b1 (#1559): lo que se guarda es la suma de las líneas, no el p_total que entró
    -- dentro de la tolerancia de un centavo: pedidos.total cierra contra SUM(subtotal) y
    -- contra el desglose (FISCAL-A).
    p_total := v_total_calc;
    v_cargo_envio := public.pedido_cargo_envio(v_total_calc, v_sucursal); -- mig 389 (#1220)
$r$, 'crear_pedido_completo (el total calculado)');

  -- 1543-b2: el escape del cambio de cliente para un producto desactivado.
  v_def := pg_temp.parche(v_def,
$a$    ELSIF NOT v_producto_activo
          AND NOT EXISTS (SELECT 1 FROM pedido_items o
                           WHERE o.pedido_id = NULLIF(current_setting('app.cambio_cliente_desde', true), '')::bigint
                             AND o.sucursal_id = v_sucursal
                             AND o.producto_id = v_producto_id) THEN
$a$,
$r$    -- 1543-b2 (#1543): el escape rige por tipo de línea (venta o regalo) y hasta la
    -- cantidad que el pedido original tenía de ese producto en ese tipo. Antes alcanzaba
    -- con que lo tuviera en cualquier línea y en cualquier cantidad.
    ELSIF NOT v_producto_activo
          AND NOT (NULLIF(current_setting('app.cambio_cliente_desde', true), '') IS NOT NULL
                   AND NOT EXISTS (
                     SELECT 1
                       FROM (SELECT COALESCE((e->>'es_bonificacion')::BOOLEAN, false) AS regalo,
                                    SUM((e->>'cantidad')::INT) AS cantidad
                               FROM jsonb_array_elements(p_items) e
                              WHERE (e->>'producto_id')::INT = v_producto_id
                              GROUP BY 1) n
                      WHERE n.cantidad > (SELECT COALESCE(SUM(o.cantidad), 0)
                                            FROM pedido_items o
                                           WHERE o.pedido_id = NULLIF(current_setting('app.cambio_cliente_desde', true), '')::bigint
                                             AND o.sucursal_id = v_sucursal
                                             AND o.producto_id = v_producto_id
                                             AND COALESCE(o.es_bonificacion, false) = n.regalo))) THEN
$r$, 'crear_pedido_completo (escape del cambio de cliente)');

  EXECUTE v_def;
END
$parche_alta$;

-- =========================================================================
-- 3 · crear_pedido_completo_bot: 1558-b2 (sólo eso)
-- =========================================================================
DO $parche_bot$
DECLARE
  v_def text := pg_get_functiondef('public.crear_pedido_completo_bot(uuid,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$      'El pedido tiene que tener al menos un producto que no sea regalo. El pedido no se creó.');
  END IF;
$a$,
$r$      'El pedido tiene que tener al menos un producto que no sea regalo. El pedido no se creó.');
  END IF;

  -- 1558-b2 (#1558, decisión del dueño D4): un regalo es de una promoción, como en
  -- crear_pedido_completo. Sin promoción no descontaba stock.
  IF EXISTS (SELECT 1
               FROM jsonb_array_elements(CASE WHEN jsonb_typeof(v_pendiente.items) = 'array'
                                              THEN v_pendiente.items ELSE '[]'::jsonb END) e
              WHERE COALESCE((e->>'es_bonificacion')::BOOLEAN, false)
                AND NULLIF(e->>'promocion_id', '') IS NULL) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Un regalo tiene que ser de una promoción: sin promoción no descuenta stock. Hacé el pedido de nuevo. El pedido no se creó.');
  END IF;
$r$, 'crear_pedido_completo_bot (regalo sin promoción)');

  EXECUTE v_def;
END
$parche_bot$;

-- =========================================================================
-- 4 · crear_pedido_idempotente: 1559-b4
-- =========================================================================
DO $parche_idempotente$
DECLARE
  v_def text := pg_get_functiondef('public.crear_pedido_idempotente(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid,text)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  v_existing_cargo    NUMERIC;
$a$,
$r$  v_existing_cargo    NUMERIC;
  v_existing_creador  UUID; -- 1559-b4
$r$, 'crear_pedido_idempotente (declaración)');

  v_def := pg_temp.parche(v_def,
$a$    SELECT id, sucursal_id, total, cargo_envio
      INTO v_existing, v_existing_sucursal, v_existing_total, v_existing_cargo
$a$,
$r$    SELECT id, sucursal_id, total, cargo_envio, creado_por
      INTO v_existing, v_existing_sucursal, v_existing_total, v_existing_cargo, v_existing_creador
$r$, 'crear_pedido_idempotente (el creador)');

  v_def := pg_temp.parche(v_def,
$a$    IF v_existing IS NOT NULL THEN
      IF v_existing_sucursal IS NOT DISTINCT FROM v_sucursal THEN
$a$,
$r$    IF v_existing IS NOT NULL THEN
      -- 1559-b4 (#1559): el replay le devuelve el pedido sólo a quien lo cargó. Con la
      -- clave de otro usuario contestaba el id, el total y el saldo a favor de un pedido
      -- ajeno. La clave es un uuid por alta: otro usuario no la repite sin querer.
      IF v_existing_creador IS DISTINCT FROM auth.uid() THEN
        RETURN jsonb_build_object(
          'success', false,
          'errores', jsonb_build_array(
            'Esa clave de alta ya la usó otro usuario: el pedido no se creó. Recargá la app y volvé a cargarlo.'));
      END IF;
      IF v_existing_sucursal IS NOT DISTINCT FROM v_sucursal THEN
$r$, 'crear_pedido_idempotente (el replay de otro usuario)');

  EXECUTE v_def;
END
$parche_idempotente$;

-- =========================================================================
-- 5 · actualizar_pedido_items
-- =========================================================================
DO $parche_editar$
DECLARE
  v_def text := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)'::regprocedure);
BEGIN
  -- 1558-b2: no se suma un regalo sin promoción.
  v_def := pg_temp.parche(v_def,
$a$    RETURN jsonb_build_object('success', false, 'errores', ARRAY[
      'Cantidad invalida para producto ID ' || v_cant_invalida]);
  END IF;
$a$,
$r$    RETURN jsonb_build_object('success', false, 'errores', ARRAY[
      'Cantidad invalida para producto ID ' || v_cant_invalida]);
  END IF;

  -- 1558-b2 (#1558, decisión del dueño D4): un regalo sin promoción no descuenta stock, y
  -- la edición no lo devuelve ni lo baja. No se agrega ni se le suma; uno que el pedido ya
  -- tenía (de antes de esta regla) se conserva o se baja.
  DECLARE
    v_regalo_libre TEXT;
  BEGIN
    SELECT string_agg(COALESCE(pr.nombre, 'el producto ID ' || n.producto_id), ', ' ORDER BY n.producto_id)
      INTO v_regalo_libre
      FROM (SELECT (e->>'producto_id')::BIGINT AS producto_id, SUM((e->>'cantidad')::INT) AS cantidad
              FROM jsonb_array_elements(p_items_nuevos) e
             WHERE COALESCE((e->>'es_bonificacion')::BOOLEAN, false)
               AND NULLIF(e->>'promocion_id', '') IS NULL
             GROUP BY 1) n
      LEFT JOIN productos pr ON pr.id = n.producto_id AND pr.sucursal_id = v_sucursal
     WHERE n.cantidad > (SELECT COALESCE(SUM(pi.cantidad), 0)
                           FROM pedido_items pi
                          WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
                            AND COALESCE(pi.es_bonificacion, false) AND pi.promocion_id IS NULL
                            AND pi.producto_id = n.producto_id);
    IF v_regalo_libre IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(format(
        'Un regalo tiene que ser de una promoción: sin promoción no descuenta stock (%s). Cargalo con su promoción, o como venta. El pedido no se modificó.',
        v_regalo_libre)), 'codigo', 'regalo_fuera_de_promo');
    END IF;
  END;
$r$, 'actualizar_pedido_items (regalo sin promoción)');

  -- 1592-b1: el corte de un regalo cambiado por valor que vino en la unidad de la línea.
  v_def := pg_temp.parche(v_def,
$a$  -- mig 338 (#1057): la clave de cadena de cada regalo (ver
  -- regalo_elemento_con_cadena). Un regalo que hereda la clave va con la raiz
$a$,
$r$  -- 1592-b1 (#1592): el regalo se manda en la unidad de la promo (el corte), y el trigger
  -- de sustituciones lo convierte. Un caller que manda la línea como está (R×10 cambiado
  -- por valor a W×1, y viene W×1) dejaba el corte en 1 y la cadena volvía a convertir R×1:
  -- el cupo de la promo perdía 9. Si la promo tiene una sola línea en el pedido y en el
  -- JSON, encadenada, y viene con su producto y su cantidad de hoy, va con su corte;
  -- regalo_elemento_con_cadena la lleva a la raíz y el trigger la vuelve a dejar igual.
  SELECT COALESCE(jsonb_agg(CASE WHEN l.corte IS NOT NULL
                                 THEN x.e || jsonb_build_object('cantidad', l.corte)
                                 ELSE x.e END ORDER BY x.o), '[]'::jsonb)
    INTO v_items
    FROM jsonb_array_elements(v_items) WITH ORDINALITY AS x(e, o)
    LEFT JOIN LATERAL (
      SELECT pi.regalo_corte AS corte
        FROM pedido_items pi
       WHERE COALESCE((x.e->>'es_bonificacion')::BOOLEAN, false)
         AND x.e->>'_reparto' IS DISTINCT FROM v_marca_reparto
         AND NULLIF(x.e->>'promocion_id', '') IS NOT NULL
         AND pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
         AND COALESCE(pi.es_bonificacion, false)
         AND pi.promocion_id = (x.e->>'promocion_id')::BIGINT
         AND pi.regalo_cadena_id IS NOT NULL
         AND pi.regalo_corte IS NOT NULL
         AND pi.regalo_corte <> pi.cantidad
         AND pi.producto_id = (x.e->>'producto_id')::BIGINT
         AND pi.cantidad = (x.e->>'cantidad')::NUMERIC
         AND (SELECT count(*) FROM pedido_items q
               WHERE q.pedido_id = p_pedido_id AND q.sucursal_id = v_sucursal
                 AND COALESCE(q.es_bonificacion, false) AND q.promocion_id = pi.promocion_id) = 1
         AND (SELECT count(*) FROM jsonb_array_elements(v_items) j
               WHERE COALESCE((j->>'es_bonificacion')::BOOLEAN, false)
                 AND j->>'promocion_id' = x.e->>'promocion_id'
                 AND j->>'_reparto' IS DISTINCT FROM v_marca_reparto) = 1
         AND public.regalo_raiz_cadena(p_pedido_id, pi.promocion_id, pi.producto_id, v_sucursal,
                                       pi.regalo_cadena_id) IS DISTINCT FROM pi.producto_id
    ) l ON true;

  -- mig 338 (#1057): la clave de cadena de cada regalo (ver
  -- regalo_elemento_con_cadena). Un regalo que hereda la clave va con la raiz
$r$, 'actualizar_pedido_items (el corte del regalo por valor)');

  -- 1595-b9: el cliente del preventista.
  v_def := pg_temp.parche(v_def,
$a$    IF v_pedido_creator IS DISTINCT FROM p_usuario_id THEN
      RETURN jsonb_build_object('success', false, 'errores',
        ARRAY['Solo el preventista que creo el pedido puede editarlo']);
    END IF;
$a$,
$r$    IF v_pedido_creator IS DISTINCT FROM p_usuario_id THEN
      RETURN jsonb_build_object('success', false, 'errores',
        ARRAY['Solo el preventista que creo el pedido puede editarlo']);
    END IF;

    -- 1595-b9 (#1595, decisión del dueño D24): el pedido de un cliente dado de baja lo
    -- editan el admin y el encargado, para cerrarlo; el preventista no. Y el preventista
    -- edita sólo si puede operar el cliente (esClienteOperable; la rama de operar de
    -- mt_clientes_update): sin asignar o asignado a él, y no reservado. Va antes de la
    -- ventana de las 15:30, para que el motivo sea éste.
    DECLARE
      v_cli RECORD;
    BEGIN
      SELECT c.id, COALESCE(c.activo, true) AS activo, COALESCE(c.reservado_admin, false) AS reservado,
             COALESCE(c.nombre_fantasia, c.razon_social, '#' || c.id::text) AS nombre
        INTO v_cli
        FROM pedidos pe
        JOIN clientes c ON c.id = pe.cliente_id AND c.sucursal_id = pe.sucursal_id
       WHERE pe.id = p_pedido_id AND pe.sucursal_id = v_sucursal;
      IF FOUND AND NOT v_cli.activo THEN
        RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(format(
          'El cliente "%s" está dado de baja: su pedido lo edita un encargado o un admin, para cerrarlo. El pedido no se modificó.',
          v_cli.nombre)));
      END IF;
      IF FOUND AND (v_cli.reservado
                    OR (EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = v_cli.id)
                        AND NOT EXISTS (SELECT 1 FROM cliente_preventistas cp
                                         WHERE cp.cliente_id = v_cli.id AND cp.preventista_id = p_usuario_id))) THEN
        RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(format(
          'El cliente "%s" ya no está a tu cargo: su pedido lo edita un encargado o un admin. El pedido no se modificó.',
          v_cli.nombre)));
      END IF;
    END;
$r$, 'actualizar_pedido_items (el cliente del preventista)');

  -- 1559-b3: el precio guardado de un producto que hoy no tiene lista.
  v_def := pg_temp.parche(v_def,
$a$  DELETE FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;
$a$,
$r$  -- 1559-b3 (#1559, decisión del dueño D20): una línea de venta de un producto que hoy
  -- quedó sin precio de lista se puede conservar a su precio guardado, hasta la cantidad
  -- que tenía. validar_precio_item_pedido lo deja pasar con esta lista
  -- ("pedido:producto:precio" → cantidad) y la va gastando; se apaga después del bucle.
  PERFORM set_config('app.edicion_precio_conservado',
    COALESCE((SELECT jsonb_object_agg(k.clave, k.cantidad)::text
                FROM (SELECT p_pedido_id || ':' || pi.producto_id || ':' || pi.precio_unitario::text AS clave,
                             SUM(pi.cantidad) AS cantidad
                        FROM pedido_items pi
                        JOIN productos pr ON pr.id = pi.producto_id AND pr.sucursal_id = pi.sucursal_id
                       WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
                         AND NOT COALESCE(pi.es_bonificacion, false)
                         AND (pr.precio IS NULL OR pr.precio <= 0)
                       GROUP BY 1) k), ''),
    true);

  DELETE FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;
$r$, 'actualizar_pedido_items (el precio conservado, antes)');

  v_def := pg_temp.parche(v_def,
$a$  -- #1097: la huella vieja sobre las lineas nuevas (ver arriba).
$a$,
$r$  -- 1559-b3: el precio conservado vale sólo para la reinserción.
  PERFORM set_config('app.edicion_precio_conservado', '', true);

  -- #1097: la huella vieja sobre las lineas nuevas (ver arriba).
$r$, 'actualizar_pedido_items (el precio conservado, después)');

  EXECUTE v_def;
END
$parche_editar$;

-- =========================================================================
-- 6 · validar_precio_item_pedido: 1559-b3
-- =========================================================================
DO $parche_precio$
DECLARE
  v_def text := pg_get_functiondef('public.validar_precio_item_pedido()'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  v_precio_lista numeric;
$a$,
$r$  v_precio_lista numeric;
  -- 1559-b3: lo que la edición conserva sin lista.
  v_conservado   jsonb;
  v_clave        text;
  v_queda        numeric;
$r$, 'validar_precio_item_pedido (declaración)');

  v_def := pg_temp.parche(v_def,
$a$  -- Solo en el alta: en UPDATE no se valida el precio de lista para no
$a$,
$r$  -- 1559-b3 (#1559, decisión del dueño D20): actualizar_pedido_items borra y reinserta las
  -- líneas, y un producto que hoy quedó sin precio de lista trababa la edición entera. La
  -- línea que vuelve con el mismo producto y el mismo precio que tenía, hasta la cantidad
  -- que tenía, entra (app.edicion_precio_conservado, que pone la edición y se va gastando).
  -- Un precio o una cantidad nuevos siguen pidiendo lista.
  IF TG_OP = 'INSERT' AND (v_precio_lista IS NULL OR v_precio_lista <= 0) THEN
    v_conservado := NULLIF(current_setting('app.edicion_precio_conservado', true), '')::jsonb;
    v_clave := NEW.pedido_id || ':' || NEW.producto_id || ':' || NEW.precio_unitario::text;
    v_queda := (v_conservado ->> v_clave)::numeric;
    IF v_queda IS NOT NULL AND NEW.cantidad <= v_queda THEN
      PERFORM set_config('app.edicion_precio_conservado',
                         jsonb_set(v_conservado, ARRAY[v_clave], to_jsonb(v_queda - NEW.cantidad))::text, true);
      RETURN NEW;
    END IF;
  END IF;

  -- Solo en el alta: en UPDATE no se valida el precio de lista para no
$r$, 'validar_precio_item_pedido (el precio conservado)');

  EXECUTE v_def;
END
$parche_precio$;

-- =========================================================================
-- 7 · actualizar_fechas_y_notas_pedido: 1559-b10 (firma nueva, con DEFAULT)
-- =========================================================================
DO $parche_fechas$
DECLARE
  v_def text := pg_get_functiondef('public.actualizar_fechas_y_notas_pedido(bigint,text,date,timestamp with time zone,date)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$p_fecha_entrega_programada date DEFAULT NULL::date)
$a$,
$r$p_fecha_entrega_programada date DEFAULT NULL::date, p_updated_at_esperado timestamp with time zone DEFAULT NULL::timestamp with time zone)
$r$, 'actualizar_fechas_y_notas_pedido (la firma)');

  v_def := pg_temp.parche(v_def,
$a$    RAISE EXCEPTION 'El pedido #% no existe en esta sucursal o no lo podés editar', p_pedido_id
      USING ERRCODE = 'P0002';
  END IF;
$a$,
$r$    RAISE EXCEPTION 'El pedido #% no existe en esta sucursal o no lo podés editar', p_pedido_id
      USING ERRCODE = 'P0002';
  END IF;

  -- 1559-b10 (#1559): el control de versión de la edición (#1323), como
  -- actualizar_pedido_items: se compara con la fila bloqueada. Sin el parámetro (un bundle
  -- viejo) no se compara.
  IF p_updated_at_esperado IS NOT NULL AND v_pedido.updated_at IS DISTINCT FROM p_updated_at_esperado THEN
    RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
      'Otro usuario modificó este pedido mientras lo tenías abierto. Cerrá la edición y volvé a abrirlo para ver cómo quedó.'),
      'codigo', 'pedido_editado_por_otro');
  END IF;
$r$, 'actualizar_fechas_y_notas_pedido (la versión esperada)');

  v_def := pg_temp.parche(v_def,
$a$  -- #1323: la versión de antes y la nueva, como sustituir y dividir un regalo
  -- (#1376). Sin vuelta a pendiente son la misma: el PATCH no mueve updated_at.
$a$,
$r$  -- #1323: la versión de antes y la nueva, como sustituir y dividir un regalo
  -- (#1376). Desde la NNN (1595-b6) pedidos_proteger_columnas mueve updated_at cuando
  -- el UPDATE cambia algo; si no cambió nada, son la misma.
$r$, 'actualizar_fechas_y_notas_pedido (comentario)');

  DROP FUNCTION public.actualizar_fechas_y_notas_pedido(bigint, text, date, timestamp with time zone, date);
  EXECUTE v_def;
END
$parche_fechas$;

REVOKE ALL ON FUNCTION public.actualizar_fechas_y_notas_pedido(bigint, text, date, timestamp with time zone, date, timestamp with time zone) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.actualizar_fechas_y_notas_pedido(bigint, text, date, timestamp with time zone, date, timestamp with time zone) TO authenticated, service_role;

-- =========================================================================
-- 8 · actualizar_preventista_pedido: 1559-b9
-- =========================================================================
DO $parche_preventista$
DECLARE
  v_def text := pg_get_functiondef('public.actualizar_preventista_pedido(bigint,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  v_anterior uuid;
$a$,
$r$  v_anterior uuid;
  -- 1559-b9: la versión de antes y la nueva.
  v_version_anterior timestamptz;
  v_version timestamptz;
$r$, 'actualizar_preventista_pedido (declaración)');

  v_def := pg_temp.parche(v_def,
$a$  SELECT usuario_id INTO v_anterior FROM pedidos
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal;
$a$,
$r$  SELECT usuario_id, updated_at INTO v_anterior, v_version_anterior FROM pedidos
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal
     FOR UPDATE;
$r$, 'actualizar_preventista_pedido (la versión de antes)');

  v_def := pg_temp.parche(v_def,
$a$    RETURN jsonb_build_object('success', true, 'sin_cambios', true);
$a$,
$r$    RETURN jsonb_build_object('success', true, 'sin_cambios', true,
                              'updated_at_anterior', v_version_anterior, 'updated_at', v_version_anterior);
$r$, 'actualizar_preventista_pedido (sin cambios)');

  v_def := pg_temp.parche(v_def,
$a$         updated_at = now()
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal;
$a$,
$r$         updated_at = now()
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal
  RETURNING updated_at INTO v_version;
$r$, 'actualizar_preventista_pedido (la versión nueva)');

  v_def := pg_temp.parche(v_def,
$a$  RETURN jsonb_build_object('success', true, 'pedido_id', p_pedido_id, 'preventista_id', p_nuevo_preventista_id);
$a$,
$r$  -- 1559-b9 (#1559): la edición abierta adopta la versión nueva sólo si estaba parada en
  -- la de antes (versionTrasCambioPropio), como tras sustituir o dividir un regalo.
  RETURN jsonb_build_object('success', true, 'pedido_id', p_pedido_id, 'preventista_id', p_nuevo_preventista_id,
                            'updated_at_anterior', v_version_anterior, 'updated_at', v_version);
$r$, 'actualizar_preventista_pedido (la respuesta)');

  EXECUTE v_def;
END
$parche_preventista$;

-- =========================================================================
-- 9 · cambiar_tipo_factura_pedido: 1559-b2 y SEG-1 (#1545)
-- =========================================================================
DO $parche_tipo$
DECLARE
  v_def text := pg_get_functiondef('public.cambiar_tipo_factura_pedido(bigint,character varying,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
$a$,
$r$  -- SEG-1 (#1545): un desactivado no tiene rol (#1474), aunque hoy ya lo frene
  -- current_sucursal_id() arriba.
  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id AND COALESCE(activo, true);
$r$, 'cambiar_tipo_factura_pedido (el rol con activo)');

  v_def := pg_temp.parche(v_def,
$a$      FROM pedido_items pi
      JOIN productos pr ON pr.id = pi.producto_id AND pr.sucursal_id = pi.sucursal_id
     WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
  LOOP
$a$,
$r$      FROM pedido_items pi
      -- 1559-b2 (#1559): LEFT JOIN, como un reporte (#1262). Una línea de un producto
      -- borrado (producto_id NULL) quedaba fuera del desglose y el neto y el IVA dejaban de
      -- cerrar con el total. Sin producto, la foto del IVA o el 21 y sin impuesto interno.
      LEFT JOIN productos pr ON pr.id = pi.producto_id AND pr.sucursal_id = pi.sucursal_id
     WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
  LOOP
$r$, 'cambiar_tipo_factura_pedido (el pase ZZ ↔ FC)');

  EXECUTE v_def;
END
$parche_tipo$;

-- =========================================================================
-- 10 · pedidos_proteger_columnas: 1595-b6, 1559-b6 y 1559-b8
-- =========================================================================
DO $parche_proteger$
DECLARE
  v_def text := pg_get_functiondef('public.pedidos_proteger_columnas()'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  IF pg_trigger_depth() > 1 THEN
    RETURN NEW;
  END IF;
$a$,
$r$  IF pg_trigger_depth() > 1 THEN
    RETURN NEW;
  END IF;

  -- 1595-b6 (#1595): la versión del pedido (updated_at, el control de la edición, #1323) no
  -- la elige el cliente. Un PATCH que reponía la vieja hacía que actualizar_pedido_items
  -- pisara la edición de otro. Un UPDATE de authenticated que cambia algo la mueve a now(), y
  -- uno que no cambia nada la deja como estaba. El GRANT de la columna sigue: el PWA viejo la
  -- manda al marcar una entrega, y sin él ese PATCH entero daría 42501.
  IF TG_OP = 'UPDATE' THEN
    NEW.updated_at := CASE WHEN (to_jsonb(NEW) - 'updated_at') IS DISTINCT FROM (to_jsonb(OLD) - 'updated_at')
                           THEN now() ELSE OLD.updated_at END;
  END IF;
$r$, 'pedidos_proteger_columnas (la versión)');

  v_def := pg_temp.parche(v_def,
$a$  IF es_encargado_o_admin() THEN
    RETURN NEW;
  END IF;
$a$,
$r$  -- 1559-b8 (#1559): un vale blanco nace entregado y no lleva fecha futura (el alta y
  -- cambiar_tipo_factura_pedido ya lo frenan). Tampoco la edición, del admin incluido.
  IF TG_OP = 'UPDATE' AND NEW.tipo_factura = 'VB' AND NEW.fecha IS DISTINCT FROM OLD.fecha
     AND NEW.fecha > public._tablero_hoy() THEN
    RAISE EXCEPTION 'Un vale blanco nace entregado: no puede llevar una fecha futura (%).',
      to_char(NEW.fecha, 'DD/MM/YYYY') USING ERRCODE = '22023';
  END IF;

  -- 1559-b6 (#1559, decisión del dueño D21): la entrega programada que se cambia va de hoy
  -- a 60 días adelante, para todos. Sólo si cambia: un pedido viejo se sigue editando. Con el
  -- piso del alta: la fecha del pedido si es anterior a hoy (el modal corre la programada
  -- junto con la fecha cuando el admin la atrasa).
  IF TG_OP = 'UPDATE' AND NEW.fecha_entrega_programada IS NOT NULL
     AND NEW.fecha_entrega_programada IS DISTINCT FROM OLD.fecha_entrega_programada THEN
    v_motivo_fecha := public._fecha_entrega_programada_fuera_de_rango(
      NEW.fecha_entrega_programada, LEAST(public._tablero_hoy(), NEW.fecha));
    IF v_motivo_fecha IS NOT NULL THEN
      RAISE EXCEPTION '%', v_motivo_fecha USING ERRCODE = '22023';
    END IF;
  END IF;

  IF es_encargado_o_admin() THEN
    RETURN NEW;
  END IF;
$r$, 'pedidos_proteger_columnas (vale blanco futuro y entrega programada)');

  EXECUTE v_def;
END
$parche_proteger$;

-- =========================================================================
-- 11 · registrar_origen_precio_items (1601-b4) y las FK de la escala (1601-b9)
-- =========================================================================
DO $parche_origen$
DECLARE
  v_def text := pg_get_functiondef('public.registrar_origen_precio_items(bigint,jsonb,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$        grupo_precio_escala_id = COALESCE(
          (item->>'grupo_precio_escala_id')::bigint,
          pi.grupo_precio_escala_id
        )
$a$,
$r$        -- 1601-b4 (#1601): sólo una escala de la sucursal del pedido; otra no se escribe.
        grupo_precio_escala_id = COALESCE(
          (SELECT e.id FROM public.grupo_precio_escalas e
            WHERE e.id = (item->>'grupo_precio_escala_id')::bigint AND e.sucursal_id = v_sucursal),
          pi.grupo_precio_escala_id
        )
$r$, 'registrar_origen_precio_items (la escala de la sucursal)');

  EXECUTE v_def;
END
$parche_origen$;

-- Premisa de datos: una escala que ya no existe o de otra sucursal no dice nada (no se
-- puede leer por ella). Se cuentan y se ponen en NULL antes de la FK. La consulta de
-- sólo lectura para medirlo en prod está en el informe de la tarjeta.
DO $datos_escala$
DECLARE
  v_items int;
  v_fotos int;
BEGIN
  SELECT count(*) INTO v_items
    FROM pedido_items pi
   WHERE pi.grupo_precio_escala_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM grupo_precio_escalas e
                      WHERE e.id = pi.grupo_precio_escala_id AND e.sucursal_id = pi.sucursal_id);
  SELECT count(*) INTO v_fotos
    FROM salvedad_linea_foto f
   WHERE f.grupo_precio_escala_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM grupo_precio_escalas e
                      WHERE e.id = f.grupo_precio_escala_id AND e.sucursal_id = f.sucursal_id);
  IF v_items > 5000 OR v_fotos > 500 THEN
    RAISE EXCEPTION 'mig NNN · % líneas y % fotos con una escala que no existe en su sucursal: más de lo esperado, revisar a mano antes de poner la FK',
      v_items, v_fotos;
  END IF;
  RAISE NOTICE 'mig NNN · escalas huérfanas que se ponen en NULL: % líneas de pedido y % fotos de salvedad', v_items, v_fotos;
  UPDATE pedido_items pi
     SET grupo_precio_escala_id = NULL
   WHERE pi.grupo_precio_escala_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM grupo_precio_escalas e
                      WHERE e.id = pi.grupo_precio_escala_id AND e.sucursal_id = pi.sucursal_id);
  UPDATE salvedad_linea_foto f
     SET grupo_precio_escala_id = NULL
   WHERE f.grupo_precio_escala_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM grupo_precio_escalas e
                      WHERE e.id = f.grupo_precio_escala_id AND e.sucursal_id = f.sucursal_id);
END
$datos_escala$;

-- 1601-b9 (#1601, la parte de esta tarjeta): la escala con la que se vendió la línea es
-- de su sucursal. ON DELETE SET NULL de la columna: borrar una condición (CASCADE a sus
-- escalas) deja la línea sin escala, no la borra. La foto de la salvedad la lleva igual,
-- porque anular_salvedad la reinserta en pedido_items.
ALTER TABLE public.pedido_items
  ADD CONSTRAINT pedido_items_grupo_precio_escala_fkey
  FOREIGN KEY (grupo_precio_escala_id, sucursal_id)
  REFERENCES public.grupo_precio_escalas (id, sucursal_id)
  ON DELETE SET NULL (grupo_precio_escala_id) NOT VALID;
ALTER TABLE public.pedido_items VALIDATE CONSTRAINT pedido_items_grupo_precio_escala_fkey;

ALTER TABLE public.salvedad_linea_foto
  ADD CONSTRAINT salvedad_linea_foto_grupo_precio_escala_fkey
  FOREIGN KEY (grupo_precio_escala_id, sucursal_id)
  REFERENCES public.grupo_precio_escalas (id, sucursal_id)
  ON DELETE SET NULL (grupo_precio_escala_id) NOT VALID;
ALTER TABLE public.salvedad_linea_foto VALIDATE CONSTRAINT salvedad_linea_foto_grupo_precio_escala_fkey;

-- =========================================================================
-- 12 · La lista blanca de SEG-A: el cuerpo nuevo de crear_pedido_idempotente
-- =========================================================================
-- auditoria_definer_sin_rol exime crear_pedido_idempotente por firma y md5. El cambio de
-- 1559-b4 no le abre nada a nadie (le cierra el replay a otro usuario): se actualiza el md5
-- de su línea, por ancla y sin premisa de md5 de la función (otras tarjetas le suman líneas).
DO $parche_lista_blanca$
DECLARE
  v_def text := pg_get_functiondef('public.auditoria_definer_sin_rol()'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$    ('crear_pedido_idempotente(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid,text)',
                                                 '63f0759223a668afdd04ce684aee18ef'),
$a$,
$r$    ('crear_pedido_idempotente(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid,text)',
                                                 '153a687adf8278c7a5c1ae9c3872e4ed'),  -- mig NNN (B4, 1559-b4): el replay, sólo de quien cargó
$r$, 'auditoria_definer_sin_rol (md5 de crear_pedido_idempotente)');

  EXECUTE v_def;
END
$parche_lista_blanca$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, el definer y los EXECUTE quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)', '8b0db4fcd010599185a1aee539b58dac', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.crear_pedido_completo_bot(uuid,uuid)', 'b233ee9edc19fb342a9a54faec848442', true, '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.crear_pedido_idempotente(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid,text)', '153a687adf8278c7a5c1ae9c3872e4ed', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', '387beb9228d1751823bc2a6c710b9098', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.actualizar_fechas_y_notas_pedido(bigint,text,date,timestamp with time zone,date,timestamp with time zone)', '531aeb1d8ac595240eed7a765d2d7130', false,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.actualizar_preventista_pedido(bigint,uuid)', '43ac71d45f8d8a6a793b840b820da418', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.cambiar_tipo_factura_pedido(bigint,character varying,uuid)', 'b22c82d8d45127b50e0d70e8999c55be', true, '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.pedidos_proteger_columnas()', 'c960f2e5517ce4d6ebef5c3be74b2977', false, '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.validar_precio_item_pedido()', '2911386410fd4ea917058aa3b8d2e069', false, '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.registrar_origen_precio_items(bigint,jsonb,uuid)', '9af0909f1c443bd99b6ecb18a31399d8', true, '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public._fecha_entrega_programada_fuera_de_rango(date,date)', 'e8db0b4c94805a3531758a5322343a69', false,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.dias_atras_fecha_pedido()', '2b5ae4d5cd0b97aa65f85f0e2e9e7606', false,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}')
  ) AS t(f, h, def, acl) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO x
      FROM pg_proc WHERE oid = r.f::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %)', r.f, x.h, x.a, x.def;
    END IF;
  END LOOP;
  IF to_regprocedure('public.actualizar_fechas_y_notas_pedido(bigint,text,date,timestamp with time zone,date)') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · quedó la firma vieja de actualizar_fechas_y_notas_pedido (PGRST203)';
  END IF;
  IF (SELECT count(*) FROM pg_constraint
       WHERE conname IN ('pedido_items_grupo_precio_escala_fkey', 'salvedad_linea_foto_grupo_precio_escala_fkey')
         AND convalidated) <> 2 THEN
    RAISE EXCEPTION 'mig NNN · las FK de la escala no quedaron validadas';
  END IF;
  IF EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol() a
              WHERE split_part(a.firma, '(', 1) IN ('crear_pedido_completo', 'crear_pedido_idempotente',
                                                    'actualizar_pedido_items', 'actualizar_preventista_pedido',
                                                    'cambiar_tipo_factura_pedido', 'registrar_origen_precio_items')) THEN
    RAISE EXCEPTION 'mig NNN · SEG-A ve en rojo una función de esta migración: %',
      (SELECT string_agg(a.firma || ' ' || a.motivo, '; ') FROM public.auditoria_definer_sin_rol() a);
  END IF;
END
$post$;

COMMIT;
