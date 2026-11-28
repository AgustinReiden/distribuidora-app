-- =========================================================================
-- NNN · T5 · LAS REGLAS DE LA RENDICIÓN
-- (ola 3 de #1603, tanda T5 de #1690; puntos de #1554, #1392, #1522, #1545, #1564 y #1601)
--
-- Se aplica en LF, sobre la 559. Ensayo: scripts/test-ola3-t5-reglas-rendicion.sql (sin esta
-- migración falla; con ella, ENSAYO OK).
--
-- Decisiones del dueño (26/11) que aplica:
--   D6 · confirmar la rendición del chofer A traba sólo los cobros de A de ese día (y de antes):
--        los otros choferes y la oficina siguen cargando.
--   D7 · el admin resuelve también la disconformidad de su propia rendición (ya lo hacía: queda
--        escrito y ensayado).
--   D8 · una rendición en disconformidad cuenta como cerrada. Los cobros ya los mandaba al día
--        siguiente la T4; acá, todo lo demás: gastos, pagos al personal y entregas.
--   D9 · nadie le carga gastos a su propia rendición (ni el encargado ni el admin que reparte), y
--        los de la rendición de un encargado los carga un admin.
--
--  1 · Rend-B4 / D6 · guard_pago_fecha_cerrada mira la caja de QUIEN COBRÓ (pagos.cobrado_por,
--      T4), no la de toda la sucursal. ultima_fecha_caja_cerrada y rendicion_dia_cerrada reciben
--      p_cobrado_por (opcional: sin él, la sucursal entera, como antes, para los que la usan así),
--      y las cuatro RPCs de cobro le preguntan por el que cobra. El trigger pasa a llamarse
--      trg_pagos_zzz_guard_fecha_cerrada para correr después de trg_pagos_zz_cobrado_por, que es
--      el que fija de quién es el cobro. Con el mismo criterio (#1329, son espejo del guard):
--      cambiarle la forma a un cobro (actualizar_forma_pago_pago) y anularlo
--      (pagos_guard_anulacion_caja_cerrada).
--      Lo que sigue mirando la caja de la sucursal entera (más estricto, no se tocó): imputar un
--      crédito, reponer el cobro de una salvedad, el cambio de comprobante, la cancelación de un
--      vale blanco y el pedido entregado en un día cerrado (_pedido_en_caja_cerrada).
--  2 · m1 / D8 · control_rendicion_cerrado cuenta la disconformidad como cerrada, y
--      anular_control_por_cambio_fecha_entrega (su espejo) también. Además ese trigger ya no borra
--      una disconformidad por ningún camino: un cambio de entrega del server (la cancelación de un
--      vale blanco o de una boleta entregada, el cambio de cliente) sobre un día en disconformidad
--      se rechaza. La guarda de caja de esas funciones sólo mira confirmada y resuelta.
--      corregir_cobro_rendicion (T4) no pasa un cobro a quien tiene la caja cerrada hasta su fecha
--      (ultima_fecha_caja_cerrada, como el guard), no sólo ese mismo día.
--  3 · 1601-b2 · control_rendicion_cerrado, ultima_fecha_caja_cerrada y rendicion_dia_cerrada
--      rechazan a un usuario desactivado (su token puede seguir vivo, #1474).
--  4 · Rend-B1 · se elimina marcar_rendicion_controlada: ninguna pantalla la usaba, dejaba una
--      fila «pendiente» que se informaba controlada y no tomaba la rendición. En prod no hay
--      ninguna fila «pendiente».
--  5 · Rend-B2 · consultar_control_rendicion: «controlada» es que alguien la controló
--      (confirmada, en disconformidad o resuelta), no que haya una fila.
--  6 · Rend-B6 · jornadas_transportista y jornada_transportista_detalle: sin la ventana de 90
--      días (una entrega cuenta por su día aunque el pedido sea más viejo), y el monto de un
--      cancelado sale del total que tenía al cancelarse (la foto de la 559), no de total_real
--      (que es la base del margen, no lo que valía la boleta).
--  7 · 1564-b3 · jornadas_preventista y jornadas_transportista devuelven el nombre sólo de
--      alguien de la sucursal activa (o que tiene pedidos en ella).
--  8 · Rend-B7 · lo que vio el modal de los pagos al personal y de los faltantes se compara
--      también por cuáles son (una huella de los ids), no sólo por la suma: revertir 100 y cargar
--      otros 100 ya no pasa como «sin cambios». obtener_resumen_rendiciones devuelve las huellas;
--      _rendicion_cambio_visto las compara si vienen (un bundle viejo no las manda).
--  9 · m1 · resolver_rendicion compara lo cobrado que vio el modal (cobros_visto, como
--      confirmar_rendicion) y lo que vio de los faltantes (faltantes_visto): la T4 deja corregir
--      un cobro en una disconformidad, y una rendición que recibió lo que el cliente pagó contra
--      un faltante no se podía resolver («formato inválido»). Lo cobrado es una sola cuenta,
--      _rendicion_cobros_vistos, que usan las dos.
-- 10 · GTO-C · resolver_rendicion toma el efectivo a entregar de _rendicion_efectivo_a_entregar.
-- 11 · Clave de idempotencia del cierre y de la resolución (altas_por_clave, 'cierre_rendicion' y
--      'resolucion_rendicion'): un reintento con la misma clave y lo mismo devuelve el control
--      del primer intento, en vez de rechazar con «los gastos cambiaron» (sus gastos ya estaban).
--      Si lo que nombraba ya no está (el cierre se reabrió, la resolución se deshizo), la clave se
--      libera y es un cierre o una resolución nuevos.
-- 12 · GTO-7 / D9 · _guardar_gasto y _anular_gasto: un gasto de la propia rendición (nuevo, que
--      llega, que sale de ella o que se anula) se rechaza; el admin lo anota al cerrarla o
--      resolverla. El encargado no toca los gastos de la rendición de un encargado.
-- 13 · SEG-2 · obtener_faltantes_rendiciones no le da al transportista quién cargó la línea ni el
--      rubro; la observación, sólo de la línea que se le cargó a él.
-- 14 · auditoria_definer_sin_rol: la lista blanca con las firmas y los cuerpos nuevos.
--
-- PREMISAS: el md5 de prosrc de cada función que se reemplaza o se parchea (los de prod el
-- 27/11, tras la 559), el trigger de fecha de pagos y el CHECK de altas_por_clave.
-- Las funciones grandes se parchean por ancla, como la 548 y la T4: se lee el cuerpo vivo, se
-- reemplaza cada ancla (exactamente las veces esperadas) y se ejecuta.
--
-- LOCKS: SHARE ROW EXCLUSIVE NOWAIT sobre pagos (se recrea su trigger) y altas_por_clave (su
-- CHECK). Ningún orden de locks cambia: las claves se escriben con la rendición ya tomada.
--
-- Revertir: cada función a su cuerpo de la 559 (está en el ledger), recrear
-- marcar_rendicion_controlada (mig 547/1547) y los dos CREATE de firma vieja
-- (ultima_fecha_caja_cerrada(bigint), rendicion_dia_cerrada(date,bigint),
-- _rendicion_cambio_visto de seis argumentos, obtener_resumen_rendiciones sin las huellas), el
-- trigger con su nombre de antes, y el CHECK de altas_por_clave sin las dos operaciones (si no
-- hay filas con ellas).
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

LOCK TABLE public.pagos, public.altas_por_clave IN SHARE ROW EXCLUSIVE MODE NOWAIT;

DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.marcar_rendicion_controlada(date,uuid)',                                'ecf4d041cef8c5495e75fa87d46fecb1'),
    ('public.consultar_control_rendicion(uuid,date)',                                '769e3f23230af91114f59ac146f478a7'),
    ('public.jornadas_transportista(date,date,uuid)',                                '01d2dc694573501c75c5cc4528f422fa'),
    ('public.jornada_transportista_detalle(date,uuid)',                              '8b8d12eaad323e7b609ba720f679a5d2'),
    ('public.jornadas_preventista(date,date,uuid)',                                  'ee5c4ea64ba52b98cb5e20d95ed692dd'),
    ('public._rendicion_cambio_visto(bigint,uuid,date,jsonb,numeric,numeric)',       '504c9cefa5b26398f65f9f45c40176be'),
    ('public.resolver_rendicion(date,uuid,text,jsonb)',                              '0f1d4243fdcb8b73a6ae1690fcac74f0'),
    ('public.confirmar_rendicion(date,uuid,text,jsonb,text)',                        'd649187931e6307ada53441ddf5cca55'),
    ('public.control_rendicion_cerrado(uuid,bigint,date)',                           '3a5ed52d20b27cf1cb3820b95aa53153'),
    ('public.ultima_fecha_caja_cerrada(bigint)',                                     'cd39eceb6d9f4372c49a267151fb5c08'),
    ('public.rendicion_dia_cerrada(date,bigint)',                                    '96bf9397648d73a7b77a2f84eb45cf24'),
    ('public.obtener_faltantes_rendiciones(date,date,uuid)',                         '84445790cc771cfe0d3c3a002ac441ba'),
    ('public._guardar_gasto(jsonb,boolean)',                                         '28e6799e7a284c96ba3aec228ae7fcc5'),
    ('public.guard_pago_fecha_cerrada()',                                            'a763cdd5980b0e0f18cb549ee97629de'),
    ('public._rendicion_efectivo_a_entregar(bigint,uuid,date)',                      '6aeb1b4da9e512527439e57d06643d5d'),
    ('public.obtener_resumen_rendiciones(date,date,uuid)',                           '8bde77f0038295524b364f324eeabbc0'),
    ('public.anular_control_por_cambio_fecha_entrega()',                             '00192ce77008c190570037f8a7f3849f'),
    ('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)',            '6154b342a018632f3531eda98174a415'),
    ('public.marcar_pagos_masivo_impl(bigint[],text,date,uuid)',                     '478c88e6a16636682325263d58f5bb76'),
    ('public.registrar_pago_cliente_fifo_impl(bigint,numeric,text,date,text,text,uuid)', 'b64b3575f925e57f41629d01761a0dd5'),
    ('public.registrar_pago_combinado_cliente_fifo_impl(bigint,jsonb,date,text,text,uuid)', '1fbe2216a169e229201d72e04b3445b4'),
    ('public.pagos_cobrado_por()',                                                   '9b1238813541f8268e460b792ed62b3e'),
    ('public.actualizar_forma_pago_pago(bigint,text)',                               '635b6cb520d332bd543fec2043414500'),
    ('public.pagos_guard_anulacion_caja_cerrada()',                                  '649493239bdded558fe4a55649c1c60c'),
    ('public.corregir_cobro_rendicion(bigint,text,uuid,text)',                       'e7e2c761592658de4d4c1988630bc8bb'),
    ('public._anular_gasto(bigint,text,boolean)',                                    'af021b07fcf5741ccbed34890a0004ab'),
    ('public.auditoria_definer_sin_rol()',                                           '0584667cb81b0a3569055a9d7c8297ec')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;

  FOR r IN SELECT * FROM (VALUES
    ('public.ultima_fecha_caja_cerrada(bigint,uuid)'),
    ('public.rendicion_dia_cerrada(date,bigint,uuid)'),
    ('public._rendicion_huella_movimientos(bigint,uuid,date,text)'),
    ('public._rendicion_cobros_vistos(bigint,uuid,date)')
  ) AS t(f) LOOP
    IF to_regprocedure(r.f) IS NOT NULL THEN
      RAISE EXCEPTION 'mig NNN · % ya existe', r.f;
    END IF;
  END LOOP;

  SELECT pg_get_triggerdef(oid) INTO v FROM pg_trigger
   WHERE tgname = 'trg_pagos_guard_fecha_cerrada' AND tgrelid = 'public.pagos'::regclass;
  IF v IS DISTINCT FROM 'CREATE TRIGGER trg_pagos_guard_fecha_cerrada BEFORE INSERT OR UPDATE OF fecha, monto ON public.pagos FOR EACH ROW EXECUTE FUNCTION guard_pago_fecha_cerrada()' THEN
    RAISE EXCEPTION 'mig NNN · el trigger de fecha de pagos cambió (%)', v;
  END IF;
  -- El guard tiene que correr después del que fija cobrado_por (los BEFORE van por nombre).
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_pagos_zz_cobrado_por'
                    AND tgrelid = 'public.pagos'::regclass) THEN
    RAISE EXCEPTION 'mig NNN · falta trg_pagos_zz_cobrado_por (la T4a)';
  END IF;

  SELECT pg_get_constraintdef(oid) INTO v FROM pg_constraint
   WHERE conname = 'altas_por_clave_operacion_check' AND conrelid = 'public.altas_por_clave'::regclass;
  IF v IS DISTINCT FROM 'CHECK ((operacion = ANY (ARRAY[''condicion_mayorista''::text, ''promocion''::text, ''cliente''::text, ''gasto''::text, ''empleado''::text, ''visita''::text, ''cambio_producto''::text, ''movimiento_empleado''::text, ''liquidacion_empleado''::text, ''cobro_faltante''::text])))' THEN
    RAISE EXCEPTION 'mig NNN · el CHECK de altas_por_clave cambió (%): armarlo sobre la lista vigente', v;
  END IF;

  -- Rend-B1: una fila «pendiente» es lo único que dejaba marcar_rendicion_controlada.
  IF EXISTS (SELECT 1 FROM public.rendiciones_control WHERE estado = 'pendiente') THEN
    RAISE EXCEPTION 'mig NNN · hay rendiciones «pendiente»: mirar de dónde salieron antes de sacar marcar_rendicion_controlada';
  END IF;
END
$premisas$;

-- Parche por ancla: cada ancla tiene que aparecer exactamente las veces que se espera.
CREATE FUNCTION pg_temp.t5_parche(p_def text, p_viejo text, p_nuevo text, p_veces int)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  n int := (length(p_def) - length(replace(p_def, p_viejo, ''))) / length(p_viejo);
BEGIN
  IF n <> p_veces THEN
    RAISE EXCEPTION 'mig NNN · un ancla aparece % veces (esperaba %): %', n, p_veces, left(p_viejo, 120);
  END IF;
  RETURN replace(p_def, p_viejo, p_nuevo);
END
$f$;

-- -------------------------------------------------------------------------
-- 1 · 1601-b2, D6 y D8: las guardas de caja y de control
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.control_rendicion_cerrado(p_transportista_id uuid, p_sucursal_id bigint, p_fecha date)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
BEGIN
  -- Sin sucursal no hay rendición que mirar. `_guardar_gasto` llega acá con la
  -- fila vieja vacía al crear un gasto: `NULL AND f()` evalúa f() igual.
  IF p_sucursal_id IS NULL THEN
    RETURN false;
  END IF;

  -- #1175: lo llama pedidos_proteger_columnas (INVOKER, como authenticated),
  -- que no ve rendiciones_control por RLS. Booleano, sin montos. Misma
  -- naturaleza que rendicion_dia_cerrada (lista blanca de SEG-A).
  -- #1334: sólo de las sucursales del que llama. Levanta porque la usan los
  -- guards, y un false les abriría el control cerrado. El server (auth.uid()
  -- NULL) no pasa por acá.
  -- 1601-b2 (T5): y de un usuario activo: el token de un desactivado sigue vivo (#1474).
  IF auth.uid() IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM usuario_sucursales us
        WHERE us.usuario_id = auth.uid() AND us.sucursal_id = p_sucursal_id) THEN
    RAISE EXCEPTION 'Acceso denegado: la sucursal % no está asignada al usuario', p_sucursal_id
      USING ERRCODE = '42501';
  END IF;
  IF auth.uid() IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM perfiles pe WHERE pe.id = auth.uid() AND COALESCE(pe.activo, true)) THEN
    RAISE EXCEPTION 'Acceso denegado: el usuario está desactivado' USING ERRCODE = '42501';
  END IF;

  -- D8 (T5, decisión del dueño 26/11): una disconformidad cuenta como cerrada. Lo que ya estaba
  -- se corrige al resolverla (o con «Editar cierre»); un gasto, un pago al personal o una entrega
  -- nuevos no le entran. Los cobros que llegan después van al día siguiente (_rendicion_pagos,
  -- la T4). Espejo: anular_control_por_cambio_fecha_entrega.
  RETURN EXISTS (SELECT 1 FROM rendiciones_control
                  WHERE transportista_id = p_transportista_id
                    AND sucursal_id = p_sucursal_id
                    AND fecha = p_fecha
                    AND estado IN ('confirmada', 'resuelta', 'disconformidad'));
END;
$function$;

DROP FUNCTION public.ultima_fecha_caja_cerrada(bigint);
CREATE FUNCTION public.ultima_fecha_caja_cerrada(p_sucursal_id bigint, p_cobrado_por uuid DEFAULT NULL::uuid)
 RETURNS date
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
BEGIN
  -- #1334: sólo de las sucursales del que llama. Levanta porque la usan los
  -- guards, y un NULL les abriría la caja cerrada. El server (auth.uid() NULL) no
  -- pasa por acá. 1601-b2 (T5): y de un usuario activo.
  IF auth.uid() IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM usuario_sucursales us
        WHERE us.usuario_id = auth.uid() AND us.sucursal_id = p_sucursal_id) THEN
    RAISE EXCEPTION 'Acceso denegado: la sucursal % no está asignada al usuario', p_sucursal_id
      USING ERRCODE = '42501';
  END IF;
  IF auth.uid() IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM perfiles pe WHERE pe.id = auth.uid() AND COALESCE(pe.activo, true)) THEN
    RAISE EXCEPTION 'Acceso denegado: el usuario está desactivado' USING ERRCODE = '42501';
  END IF;

  -- D6 (T5, decisión del dueño 26/11): con p_cobrado_por, la caja de esa persona (el último día
  -- que se le confirmó o resolvió); confirmar la de un chofer no traba los cobros de los demás.
  -- Sin él, la de la sucursal entera, como siempre (anular un pago, cambiarle la forma, el
  -- cambio de comprobante, la cancelación de un vale blanco).
  RETURN (SELECT MAX(fecha)
            FROM rendiciones_control
           WHERE sucursal_id = p_sucursal_id
             AND (p_cobrado_por IS NULL OR transportista_id = p_cobrado_por)
             AND estado IN ('confirmada','resuelta'));
END;
$function$;
REVOKE ALL ON FUNCTION public.ultima_fecha_caja_cerrada(bigint, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ultima_fecha_caja_cerrada(bigint, uuid) TO authenticated, service_role;

DROP FUNCTION public.rendicion_dia_cerrada(date, bigint);
CREATE FUNCTION public.rendicion_dia_cerrada(p_fecha date, p_sucursal_id bigint DEFAULT NULL::bigint,
                                             p_cobrado_por uuid DEFAULT NULL::uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
DECLARE
  v_sucursal bigint;
BEGIN
  v_sucursal := COALESCE(p_sucursal_id, current_sucursal_id());
  IF v_sucursal IS NULL THEN
    RETURN false;
  END IF;

  -- #1334: sólo de las sucursales del que llama. Levanta porque la usan los
  -- guards, y un false les abriría la caja cerrada. El server (auth.uid() NULL)
  -- no pasa por acá. 1601-b2 (T5): y de un usuario activo.
  IF auth.uid() IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM usuario_sucursales us
        WHERE us.usuario_id = auth.uid() AND us.sucursal_id = v_sucursal) THEN
    RAISE EXCEPTION 'Acceso denegado: la sucursal % no está asignada al usuario', v_sucursal
      USING ERRCODE = '42501';
  END IF;
  IF auth.uid() IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM perfiles pe WHERE pe.id = auth.uid() AND COALESCE(pe.activo, true)) THEN
    RAISE EXCEPTION 'Acceso denegado: el usuario está desactivado' USING ERRCODE = '42501';
  END IF;

  -- D6 (T5): con p_cobrado_por, sólo la rendición de esa persona ese día.
  RETURN EXISTS (
    SELECT 1 FROM rendiciones_control
    WHERE fecha = p_fecha
      AND sucursal_id = v_sucursal
      AND (p_cobrado_por IS NULL OR transportista_id = p_cobrado_por)
      AND estado IN ('confirmada', 'resuelta')
  );
END;
$function$;
REVOKE ALL ON FUNCTION public.rendicion_dia_cerrada(date, bigint, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rendicion_dia_cerrada(date, bigint, uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.guard_pago_fecha_cerrada()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
DECLARE
  v_limite date;
  v_duenio uuid;
BEGIN
  IF NEW.sucursal_id IS NULL OR NEW.fecha IS NULL THEN
    RETURN NEW;
  END IF;

  -- Reimputacion interna (mig 165): mover plata ya cobrada entre boletas del
  -- mismo cliente no cambia el total del dia, solo a que boleta se aplica. El
  -- desglose por chofer de una rendicion confirmada tampoco cambia: se lee de su
  -- foto (rendicion_pagos_confirmados, #1248). El GUC es transaction-scoped y lo
  -- setean unicamente las funciones de reimputacion (aplicar_credito_cliente,
  -- imputar_credito_a_pedido_impl, _pagos_excedente_a_favor).
  IF current_setting('app.reimputacion_pagos', true) = 'on' THEN
    RETURN NEW;
  END IF;

  -- mig 276 (#833): un credito de NC no es plata de la rendicion (las RPCs de
  -- rendiciones lo excluyen), asi que emitirlo un dia con la caja controlada
  -- no la desbalancea. Quien lo puede crear lo decide pagos_guard_nota_credito.
  IF NEW.forma_pago = 'nota_credito' THEN
    RETURN NEW;
  END IF;

  -- D6 (T5, decisión del dueño 26/11): la caja que mira es la de quien cobró, la rendición a la
  -- que va el cobro (pagos.cobrado_por, T4; lo fija trg_pagos_zz_cobrado_por, que por eso corre
  -- antes: este trigger es trg_pagos_zzz_…). Confirmar la de un chofer ya no traba los cobros de
  -- los otros choferes ni de la oficina. Un pago sin dueño (sin sesión), la caja de la sucursal.
  v_duenio := COALESCE(NEW.cobrado_por,
                       CASE WHEN NEW.de_saldo_a_favor THEN NEW.usuario_id
                            ELSE COALESCE((SELECT pd.transportista_id FROM pedidos pd WHERE pd.id = NEW.pedido_id),
                                          NEW.usuario_id) END);
  v_limite := public.ultima_fecha_caja_cerrada(NEW.sucursal_id, v_duenio);

  IF v_limite IS NOT NULL AND NEW.fecha <= v_limite THEN
    RAISE EXCEPTION 'La caja de la sucursal esta cerrada hasta el % para quien cobró (su rendicion esta controlada). No se puede registrar/editar un pago con fecha %. Reabri la rendicion de ese dia para hacer cambios.',
      to_char(v_limite, 'DD/MM/YYYY'), to_char(NEW.fecha, 'DD/MM/YYYY')
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER trg_pagos_guard_fecha_cerrada ON public.pagos;
CREATE TRIGGER trg_pagos_zzz_guard_fecha_cerrada BEFORE INSERT OR UPDATE OF fecha, monto ON public.pagos
  FOR EACH ROW EXECUTE FUNCTION public.guard_pago_fecha_cerrada();

-- Las cuatro RPCs de cobro: el «sólo hoy» del encargado pregunta por la caja del que cobra.
DO $rpcs_cobro$
DECLARE
  v_def text;
BEGIN
  v_def := pg_get_functiondef('public.registrar_pago_cliente_fifo_impl(bigint,numeric,text,date,text,text,uuid)'::regprocedure);
  v_def := pg_temp.t5_parche(v_def,
    'IF public.rendicion_dia_cerrada(p_fecha, v_sucursal_id) THEN',
    '-- D6 (T5): la rendición de quien cobra, no la de toda la sucursal.
    IF public.rendicion_dia_cerrada(p_fecha, v_sucursal_id, v_cobrador) THEN', 1);
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.registrar_pago_combinado_cliente_fifo_impl(bigint,jsonb,date,text,text,uuid)'::regprocedure);
  v_def := pg_temp.t5_parche(v_def,
    'IF public.rendicion_dia_cerrada(p_fecha, v_sucursal_id) THEN',
    '-- D6 (T5): la rendición de quien cobra, no la de toda la sucursal.
    IF public.rendicion_dia_cerrada(p_fecha, v_sucursal_id, v_cobrador) THEN', 1);
  EXECUTE v_def;

  -- El encargado cobra a su nombre o al del chofer de cada boleta (_cobrador_de_cobro): la caja
  -- de la que pregunta es la que eligió (sin elegir, la suya); el trigger mira cada cobro.
  v_def := pg_get_functiondef('public.marcar_pagos_masivo_impl(bigint[],text,date,uuid)'::regprocedure);
  v_def := pg_temp.t5_parche(v_def,
    'IF public.rendicion_dia_cerrada(p_fecha, v_sucursal_id) THEN',
    '-- D6 (T5): la rendición de quien cobra, no la de toda la sucursal.
    IF public.rendicion_dia_cerrada(p_fecha, v_sucursal_id, COALESCE(p_cobrado_por, auth.uid())) THEN', 1);
  EXECUTE v_def;

  -- Los cobros de la entrega masiva son del chofer elegido (T4).
  v_def := pg_get_functiondef('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)'::regprocedure);
  v_def := pg_temp.t5_parche(v_def,
    'IF public.rendicion_dia_cerrada(p_fecha, v_sucursal_id) THEN',
    '-- D6 (T5): la rendición de quien cobra, no la de toda la sucursal.
    IF public.rendicion_dia_cerrada(p_fecha, v_sucursal_id, COALESCE(p_transportista_id, auth.uid())) THEN', 1);
  EXECUTE v_def;

  -- #1329: cambiar la forma y anular un cobro miran la misma caja que el guard (la de quien cobró).
  v_def := pg_get_functiondef('public.actualizar_forma_pago_pago(bigint,text)'::regprocedure);
  v_def := pg_temp.t5_parche(v_def,
    '  SELECT id, pedido_id, fecha, forma_pago
    INTO v_pago',
    '  SELECT id, pedido_id, fecha, forma_pago, cobrado_por
    INTO v_pago', 1);
  v_def := pg_temp.t5_parche(v_def,
    '  -- #1329: el criterio de guard_pago_fecha_cerrada, que no cubre forma_pago.
  v_limite := public.ultima_fecha_caja_cerrada(v_sucursal_id);',
    '  -- #1329: el criterio de guard_pago_fecha_cerrada, que no cubre forma_pago. D6 (T5): la caja
  -- de quien cobró (sin dueño, la de la sucursal).
  v_limite := public.ultima_fecha_caja_cerrada(v_sucursal_id, v_pago.cobrado_por);', 1);
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.pagos_guard_anulacion_caja_cerrada()'::regprocedure);
  v_def := pg_temp.t5_parche(v_def,
    '  v_limite := public.ultima_fecha_caja_cerrada(OLD.sucursal_id);',
    '  -- D6 (T5): la caja de quien cobró, como guard_pago_fecha_cerrada (sin dueño, la de la sucursal).
  v_limite := public.ultima_fecha_caja_cerrada(OLD.sucursal_id, OLD.cobrado_por);', 1);
  EXECUTE v_def;

  -- D8: el espejo de control_rendicion_cerrado (la carrera con un control que se cierra).
  v_def := pg_get_functiondef('public.anular_control_por_cambio_fecha_entrega()'::regprocedure);
  v_def := pg_temp.t5_parche(v_def,
    'AND fecha = v_dia AND estado IN (''confirmada'', ''resuelta'')) THEN',
    'AND fecha = v_dia AND estado IN (''confirmada'', ''resuelta'', ''disconformidad'')) THEN', 2);
  -- D8: una disconformidad no se borra por ningún camino, tampoco el del server (la cancelación de
  -- un vale blanco o de una boleta entregada, el cambio de cliente): se resuelve primero.
  v_def := pg_temp.t5_parche(v_def,
    '    DELETE FROM rendiciones_control
    WHERE transportista_id = OLD.transportista_id',
    '    IF EXISTS (SELECT 1 FROM rendiciones_control
                WHERE transportista_id = OLD.transportista_id AND sucursal_id = OLD.sucursal_id
                  AND fecha = v_dia AND estado = ''disconformidad'') THEN
      RAISE EXCEPTION ''La rendición del % de ese transportista está en disconformidad: este cambio la reabriría. Un admin la tiene que resolver primero.'',
        to_char(v_dia, ''DD/MM/YYYY'') USING ERRCODE = ''42501'';
    END IF;
    DELETE FROM rendiciones_control
    WHERE transportista_id = OLD.transportista_id', 1);
  v_def := pg_temp.t5_parche(v_def,
    '    DELETE FROM rendiciones_control
    WHERE transportista_id = NEW.transportista_id',
    '    IF EXISTS (SELECT 1 FROM rendiciones_control
                WHERE transportista_id = NEW.transportista_id AND sucursal_id = NEW.sucursal_id
                  AND fecha = v_dia AND estado = ''disconformidad'') THEN
      RAISE EXCEPTION ''La rendición del % de ese transportista está en disconformidad: este cambio la reabriría. Un admin la tiene que resolver primero.'',
        to_char(v_dia, ''DD/MM/YYYY'') USING ERRCODE = ''42501'';
    END IF;
    DELETE FROM rendiciones_control
    WHERE transportista_id = NEW.transportista_id', 1);
  EXECUTE v_def;

  -- corregir_cobro_rendicion: a quien tiene la caja cerrada hasta la fecha del cobro no se le pasa
  -- (el cobro iría al día siguiente a su último cierre, #1328), como guard_pago_fecha_cerrada.
  v_def := pg_get_functiondef('public.corregir_cobro_rendicion(bigint,text,uuid,text)'::regprocedure);
  v_def := pg_temp.t5_parche(v_def,
    '  IF v_nuevo IS DISTINCT FROM v_r.t_id
     AND EXISTS (SELECT 1 FROM rendiciones_control rc
                  WHERE rc.transportista_id = v_nuevo AND rc.fecha = v_pg.fecha AND rc.sucursal_id = v_sucursal_id
                    AND rc.estado IN (''confirmada'', ''resuelta'', ''disconformidad'')) THEN',
    '  -- T5 (D6): y la caja de quien cobró, cerrada hasta esa fecha (ultima_fecha_caja_cerrada).
  IF v_nuevo IS DISTINCT FROM v_r.t_id
     AND (EXISTS (SELECT 1 FROM rendiciones_control rc
                   WHERE rc.transportista_id = v_nuevo AND rc.fecha = v_pg.fecha AND rc.sucursal_id = v_sucursal_id
                     AND rc.estado IN (''confirmada'', ''resuelta'', ''disconformidad''))
          OR v_pg.fecha <= public.ultima_fecha_caja_cerrada(v_sucursal_id, v_nuevo)) THEN', 1);
  EXECUTE v_def;
END
$rpcs_cobro$;

-- -------------------------------------------------------------------------
-- 2 · Rend-B1 y Rend-B2: el control a mano
-- -------------------------------------------------------------------------
DROP FUNCTION public.marcar_rendicion_controlada(date, uuid);

CREATE OR REPLACE FUNCTION public.consultar_control_rendicion(p_transportista_id uuid, p_fecha date)
 RETURNS TABLE(controlada boolean, controlada_at timestamp with time zone, controlada_por_nombre text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
DECLARE
  v_sucursal_id BIGINT;
BEGIN
  v_sucursal_id := current_sucursal_id();

  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no seleccionada';
  END IF;

  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  -- Rend-B2 (T5): controlada es que alguien la controló (confirmó, marcó en disconformidad o
  -- resolvió), no que exista la fila: una «pendiente» no es un control.
  RETURN QUERY
  SELECT
    COALESCE(rc.estado IN ('confirmada', 'disconformidad', 'resuelta'), false) AS controlada,
    rc.controlada_at,
    cp.nombre::text AS controlada_por_nombre
  FROM (SELECT 1) x
  LEFT JOIN rendiciones_control rc
    ON rc.fecha = p_fecha
   AND rc.transportista_id = p_transportista_id
   AND rc.sucursal_id = v_sucursal_id
  LEFT JOIN perfiles cp ON cp.id = rc.controlada_por;
END;
$function$;

-- -------------------------------------------------------------------------
-- 3 · Rend-B6 y 1564-b3: las jornadas
-- -------------------------------------------------------------------------
DO $jornadas$
DECLARE
  v_def text;
BEGIN
  v_def := pg_get_functiondef('public.jornadas_transportista(date,date,uuid)'::regprocedure);
  v_def := pg_temp.t5_parche(v_def,
    'SELECT nombre INTO v_nombre FROM perfiles WHERE id = v_target;',
    '-- 1564-b3 (T5): el nombre, sólo de alguien de esta sucursal (o con pedidos en ella).
  SELECT pe.nombre INTO v_nombre FROM perfiles pe
   WHERE pe.id = v_target
     AND (EXISTS (SELECT 1 FROM usuario_sucursales us
                   WHERE us.usuario_id = v_target AND us.sucursal_id = v_sucursal)
          OR EXISTS (SELECT 1 FROM pedidos px
                      WHERE px.transportista_id = v_target AND px.sucursal_id = v_sucursal));', 1);
  v_def := pg_temp.t5_parche(v_def,
    'THEN COALESCE(NULLIF(p.total, 0), NULLIF(p.total_real, 0),',
    'THEN COALESCE(NULLIF(p.total, 0),
                      -- Rend-B6 (T5): lo que valía al cancelarse (la foto de la 559), no total_real.
                      (SELECT NULLIF(cf.total, 0) FROM pedido_cancelacion_foto cf
                        WHERE cf.pedido_id = p.id AND cf.revertida_at IS NULL
                        ORDER BY cf.id DESC LIMIT 1),', 1);
  v_def := pg_temp.t5_parche(v_def,
    '      AND p.estado IN (''entregado'',''cancelado'')
      AND p.fecha >= (p_desde - 90)
      AND p.fecha <= p_hasta',
    '      AND p.estado IN (''entregado'',''cancelado'')
      -- Rend-B6 (T5): sin la ventana de 90 días. Una entrega con fecha cuenta por su día; el
      -- resto (cancelados y entregas sin fecha) se calcula y lo filtra del_rango.
      AND ((p.estado = ''entregado'' AND p.fecha_entrega IS NOT NULL
            AND (p.fecha_entrega AT TIME ZONE ''America/Argentina/Buenos_Aires'')::date BETWEEN p_desde AND p_hasta)
           OR ((p.estado = ''cancelado'' OR p.fecha_entrega IS NULL) AND p.fecha <= p_hasta))', 1);
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.jornada_transportista_detalle(date,uuid)'::regprocedure);
  v_def := pg_temp.t5_parche(v_def,
    'THEN COALESCE(NULLIF(f.total, 0), NULLIF(f.total_real, 0),',
    'THEN COALESCE(NULLIF(f.total, 0),
                                 -- Rend-B6 (T5): lo que valía al cancelarse, no total_real.
                                 (SELECT NULLIF(cf.total, 0) FROM pedido_cancelacion_foto cf
                                   WHERE cf.pedido_id = f.id AND cf.revertida_at IS NULL
                                   ORDER BY cf.id DESC LIMIT 1),', 1);
  v_def := pg_temp.t5_parche(v_def,
    '        (p_dia IS NOT NULL
         AND p.estado IN (''entregado'',''cancelado'')
         AND p.fecha BETWEEN (p_dia - 90) AND p_dia)',
    '        -- Rend-B6 (T5): sin la ventana de 90 días (ver jornadas_transportista).
        (p_dia IS NOT NULL
         AND p.estado IN (''entregado'',''cancelado'')
         AND ((p.estado = ''entregado'' AND p.fecha_entrega IS NOT NULL
               AND (p.fecha_entrega AT TIME ZONE ''America/Argentina/Buenos_Aires'')::date = p_dia)
              OR ((p.estado = ''cancelado'' OR p.fecha_entrega IS NULL) AND p.fecha <= p_dia)))', 1);
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.jornadas_preventista(date,date,uuid)'::regprocedure);
  v_def := pg_temp.t5_parche(v_def,
    'SELECT nombre INTO v_nombre FROM perfiles WHERE id = v_target;',
    '-- 1564-b3 (T5): el nombre, sólo de alguien de esta sucursal (o con pedidos en ella).
  SELECT pe.nombre INTO v_nombre FROM perfiles pe
   WHERE pe.id = v_target
     AND (EXISTS (SELECT 1 FROM usuario_sucursales us
                   WHERE us.usuario_id = v_target AND us.sucursal_id = v_sucursal)
          OR EXISTS (SELECT 1 FROM pedidos px
                      WHERE px.usuario_id = v_target AND px.sucursal_id = v_sucursal));', 1);
  EXECUTE v_def;
END
$jornadas$;

-- -------------------------------------------------------------------------
-- 4 · Rend-B7, m1 y GTO-C: lo que vio el modal, y una sola cuenta
-- -------------------------------------------------------------------------
-- Cuáles son los movimientos de un tipo de la rendición: los ids, en una huella opaca (no dice
-- quién cobró ni cuánto). Una reversión es otro movimiento: cambia la huella aunque la suma no.
CREATE FUNCTION public._rendicion_huella_movimientos(p_sucursal_id bigint, p_transportista_id uuid,
                                                     p_fecha date, p_tipo text)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path = public, pg_temp
AS $function$
  SELECT md5(COALESCE(string_agg(m.id::text, ',' ORDER BY m.id), ''))
    FROM empleado_movimientos m
   WHERE m.rendicion_sucursal_id = p_sucursal_id
     AND m.rendicion_transportista_id = p_transportista_id
     AND m.rendicion_fecha = p_fecha
     AND m.tipo = p_tipo;
$function$;
REVOKE ALL ON FUNCTION public._rendicion_huella_movimientos(bigint, uuid, date, text) FROM PUBLIC, anon, authenticated;

-- Lo cobrado de una rendición como lo muestra su tarjeta (pagos_agg de obtener_resumen_rendiciones,
-- sin el adelanto de sueldo): es lo que comparan confirmar_rendicion y resolver_rendicion.
CREATE FUNCTION public._rendicion_cobros_vistos(p_sucursal_id bigint, p_transportista_id uuid, p_fecha date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path = public, pg_temp
AS $function$
  SELECT jsonb_build_object(
           'efectivo',         COALESCE(SUM(x.monto) FILTER (WHERE x.forma_pago = 'efectivo'), 0),
           'transferencia',    COALESCE(SUM(x.monto) FILTER (WHERE x.forma_pago = 'transferencia'), 0),
           'cheque',           COALESCE(SUM(x.monto) FILTER (WHERE x.forma_pago = 'cheque'), 0),
           'cuenta_corriente', COALESCE(SUM(x.monto) FILTER (WHERE x.forma_pago = 'cuenta_corriente'), 0),
           'tarjeta',          COALESCE(SUM(x.monto) FILTER (WHERE x.forma_pago = 'tarjeta'), 0),
           'otros',            COALESCE(SUM(x.monto) FILTER (
                                 WHERE x.forma_pago IS NULL
                                    OR x.forma_pago NOT IN ('efectivo', 'transferencia', 'cheque',
                                                            'cuenta_corriente', 'tarjeta')), 0),
           'entregas',         COALESCE(SUM(x.monto) FILTER (WHERE x.es_entrega_del_dia), 0))
    FROM public._rendicion_pagos(p_sucursal_id, p_fecha, p_fecha) x
   WHERE x.t_id = p_transportista_id
     AND x.f = p_fecha
     AND COALESCE(x.forma_pago, '') <> 'adelanto_sueldo';
$function$;
REVOKE ALL ON FUNCTION public._rendicion_cobros_vistos(bigint, uuid, date) FROM PUBLIC, anon, authenticated;

DROP FUNCTION public._rendicion_cambio_visto(bigint, uuid, date, jsonb, numeric, numeric);
CREATE FUNCTION public._rendicion_cambio_visto(p_sucursal_id bigint, p_transportista_id uuid, p_fecha date,
                                               p_vistos jsonb, p_pagos_personal_visto numeric,
                                               p_faltantes_visto numeric,
                                               p_huella_pagos text DEFAULT NULL::text,
                                               p_huella_faltantes text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path = public, pg_temp
AS $function$
DECLARE
  v_vivos bigint[];
BEGIN
  -- Los gastos vivos de la rendicion tienen que ser los que vio el modal, con
  -- la misma version (id, updated_at): uno editado tambien cambia lo que se
  -- entrega.
  v_vivos := ARRAY(SELECT g.id FROM gastos g
                    WHERE g.origen_pago = 'rendicion'
                      AND g.sucursal_id = p_sucursal_id
                      AND g.rendicion_transportista_id = p_transportista_id
                      AND g.rendicion_fecha = p_fecha
                      AND g.anulado_at IS NULL);
  IF EXISTS (SELECT g.id, g.updated_at FROM gastos g WHERE g.id = ANY (v_vivos)
             EXCEPT
             SELECT (e->>'id')::bigint, (e->>'updated_at')::timestamptz FROM jsonb_array_elements(p_vistos) e)
     OR EXISTS (SELECT (e->>'id')::bigint, (e->>'updated_at')::timestamptz FROM jsonb_array_elements(p_vistos) e
                EXCEPT
                SELECT g.id, g.updated_at FROM gastos g WHERE g.id = ANY (v_vivos)) THEN
    RETURN 'gastos';
  END IF;

  -- Los pagos al personal (gastos 5) y los faltantes a cargo de empleados
  -- (gastos 6), cada uno por su tipo: una reversion lleva el mismo tipo y la
  -- misma rendicion, y lo devuelve.
  -- Rend-B7 (T5): y por cuáles son, si el modal mandó la huella (obtener_resumen_rendiciones la
  -- da): revertir 100 y cargar otros 100 deja la misma suma, no los mismos movimientos. Sin la
  -- huella (un bundle viejo), sólo la suma, como antes.
  IF COALESCE((SELECT -SUM(m.monto) FROM empleado_movimientos m
                WHERE m.rendicion_sucursal_id = p_sucursal_id
                  AND m.rendicion_transportista_id = p_transportista_id
                  AND m.rendicion_fecha = p_fecha
                  AND m.tipo = 'pago'), 0) <> p_pagos_personal_visto
     OR (p_huella_pagos IS NOT NULL
         AND public._rendicion_huella_movimientos(p_sucursal_id, p_transportista_id, p_fecha, 'pago')
             <> p_huella_pagos) THEN
    RETURN 'pagos';
  END IF;
  IF COALESCE((SELECT -SUM(m.monto) FROM empleado_movimientos m
                WHERE m.rendicion_sucursal_id = p_sucursal_id
                  AND m.rendicion_transportista_id = p_transportista_id
                  AND m.rendicion_fecha = p_fecha
                  AND m.tipo = 'faltante'), 0) <> p_faltantes_visto
     OR (p_huella_faltantes IS NOT NULL
         AND public._rendicion_huella_movimientos(p_sucursal_id, p_transportista_id, p_fecha, 'faltante')
             <> p_huella_faltantes) THEN
    RETURN 'faltantes';
  END IF;
  RETURN NULL;
END
$function$;
REVOKE ALL ON FUNCTION public._rendicion_cambio_visto(bigint, uuid, date, jsonb, numeric, numeric, text, text) FROM PUBLIC, anon, authenticated;

-- obtener_resumen_rendiciones: las dos huellas al final (cambia el RETURNS TABLE: DROP y CREATE;
-- un bundle viejo no las lee).
DO $resumen$
DECLARE
  v_def text;
BEGIN
  v_def := pg_get_functiondef('public.obtener_resumen_rendiciones(date,date,uuid)'::regprocedure);
  v_def := pg_temp.t5_parche(v_def,
    'total_pagos_personal numeric, total_faltantes_empleados numeric)',
    'total_pagos_personal numeric, total_faltantes_empleados numeric, huella_pagos_personal text, huella_faltantes text)', 1);
  v_def := pg_temp.t5_parche(v_def,
    '    COALESCE(faltantes_agg.tot_fe, 0)::numeric AS total_faltantes_empleados
  FROM fechas_activas fa',
    '    COALESCE(faltantes_agg.tot_fe, 0)::numeric AS total_faltantes_empleados,
    -- Rend-B7 (T5): cuáles son los pagos al personal y los faltantes (una huella de los ids, sin
    -- nombres ni montos); el cierre y la resolución la devuelven para compararla.
    public._rendicion_huella_movimientos(v_sucursal_id, fa.t_id, fa.f, ''pago'')::text AS huella_pagos_personal,
    public._rendicion_huella_movimientos(v_sucursal_id, fa.t_id, fa.f, ''faltante'')::text AS huella_faltantes
  FROM fechas_activas fa', 1);
  v_def := pg_temp.t5_parche(v_def, 'CREATE OR REPLACE FUNCTION', 'CREATE FUNCTION', 1);
  DROP FUNCTION public.obtener_resumen_rendiciones(date, date, uuid);
  EXECUTE v_def;
END
$resumen$;
REVOKE ALL ON FUNCTION public.obtener_resumen_rendiciones(date, date, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.obtener_resumen_rendiciones(date, date, uuid) TO authenticated, service_role;

-- La clave de idempotencia del cierre y de la resolución.
ALTER TABLE public.altas_por_clave DROP CONSTRAINT altas_por_clave_operacion_check;
ALTER TABLE public.altas_por_clave ADD CONSTRAINT altas_por_clave_operacion_check
  CHECK (operacion = ANY (ARRAY['condicion_mayorista'::text, 'promocion'::text, 'cliente'::text, 'gasto'::text,
                                'empleado'::text, 'visita'::text, 'cambio_producto'::text,
                                'movimiento_empleado'::text, 'liquidacion_empleado'::text,
                                'cobro_faltante'::text, 'cierre_rendicion'::text,
                                'resolucion_rendicion'::text]));

DO $confirmar$
DECLARE
  v_def text;
BEGIN
  v_def := pg_get_functiondef('public.confirmar_rendicion(date,uuid,text,jsonb,text)'::regprocedure);
  v_def := pg_temp.t5_parche(v_def,
    '  v_cobros_visto jsonb; -- #1547 (FRT-03)
  v_cobros       jsonb;',
    '  v_cobros_visto jsonb; -- #1547 (FRT-03)
  v_cobros       jsonb;
  -- Rend-B7 y la clave (T5).
  v_huella_pagos text;
  v_huella_falt  text;
  v_clave        uuid;
  v_contenido    text;
  v_previa       public.altas_por_clave%ROWTYPE;', 1);

  -- La clave, con la rendición ya tomada: un doble toque espera al primero y ve su clave.
  v_def := pg_temp.t5_parche(v_def,
    '  PERFORM public._rendicion_bloquear(ARRAY[public._rendicion_clave(p_transportista_id, p_fecha, v_sucursal_id)]);

  -- 2b ·',
    '  PERFORM public._rendicion_bloquear(ARRAY[public._rendicion_clave(p_transportista_id, p_fecha, v_sucursal_id)]);

  -- 2a · T5: la clave del cierre (altas_por_clave, como el alta de un gasto). La misma clave con
  --      lo mismo es un reintento (la respuesta se perdió): devuelve el control del primer
  --      intento sin volver a guardar sus gastos. Si ese cierre ya no está (se reabrió), la clave
  --      se libera. Sin clave (un PWA de antes), como siempre: un reintento con gastos nuevos se
  --      rechaza porque ya están.
  IF jsonb_typeof(p_gastos_rendicion) = ''object''
     AND NULLIF(p_gastos_rendicion->>''clave'', '''') IS NOT NULL THEN
    BEGIN
      v_clave := (p_gastos_rendicion->>''clave'')::uuid;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION ''Los gastos del cierre vienen con un formato inválido'';
    END;
    v_contenido := md5(jsonb_build_object(''fecha'', p_fecha, ''transportista'', p_transportista_id,
                                          ''estado'', p_estado, ''observaciones'', p_observaciones,
                                          ''cierre'', p_gastos_rendicion - ''clave'')::text);
    INSERT INTO altas_por_clave (clave, operacion, usuario_id, sucursal_id, contenido)
    VALUES (v_clave, ''cierre_rendicion'', auth.uid(), v_sucursal_id, v_contenido)
    ON CONFLICT (clave) DO NOTHING;
    IF NOT FOUND THEN
      SELECT * INTO v_previa FROM altas_por_clave WHERE clave = v_clave;
      IF v_previa.operacion <> ''cierre_rendicion'' OR v_previa.usuario_id IS DISTINCT FROM auth.uid()
         OR v_previa.sucursal_id <> v_sucursal_id THEN
        RAISE EXCEPTION ''Esta clave ya se usó para otra operación: recargá la página e intentá de nuevo.''
          USING ERRCODE = ''22023'';
      END IF;
      IF v_previa.contenido <> v_contenido THEN
        RAISE EXCEPTION ''Este cierre ya entró con el intento anterior y lo que mandaste ahora es distinto: tocá Refrescar y volvé a abrirlo.''
          USING ERRCODE = ''22023'';
      END IF;
      IF v_previa.entidad_id IS NOT NULL
         AND EXISTS (SELECT 1 FROM rendiciones_control WHERE id = v_previa.entidad_id) THEN
        RETURN v_previa.entidad_id;
      END IF;
      -- El cierre de esa clave ya no está (se reabrió): la clave se libera y esto es un cierre nuevo.
      UPDATE altas_por_clave SET entidad_id = NULL WHERE clave = v_clave;
    END IF;
  END IF;

  -- 2b ·', 1);

  -- Rend-B7: las huellas (texto o null; sin ellas, sólo la suma).
  v_def := pg_temp.t5_parche(v_def,
    '  EXCEPTION WHEN others THEN
    RAISE EXCEPTION ''Los gastos del cierre vienen con un formato inválido'';
  END;

  -- 4 ·',
    '  EXCEPTION WHEN others THEN
    RAISE EXCEPTION ''Los gastos del cierre vienen con un formato inválido'';
  END;
  -- Rend-B7 (T5): cuáles son los pagos al personal y los faltantes que vio el modal.
  IF jsonb_typeof(COALESCE(p_gastos_rendicion->''huella_pagos_personal'', ''null'')) NOT IN (''string'', ''null'')
     OR jsonb_typeof(COALESCE(p_gastos_rendicion->''huella_faltantes'', ''null'')) NOT IN (''string'', ''null'') THEN
    RAISE EXCEPTION ''Los gastos del cierre vienen con un formato inválido'';
  END IF;
  v_huella_pagos := p_gastos_rendicion->>''huella_pagos_personal'';
  v_huella_falt  := p_gastos_rendicion->>''huella_faltantes'';

  -- 4 ·', 1);
  v_def := pg_temp.t5_parche(v_def,
    'v_cambio := public._rendicion_cambio_visto(v_sucursal_id, p_transportista_id, p_fecha, v_vistos,
                                             v_pagos_visto, v_falt_visto);',
    'v_cambio := public._rendicion_cambio_visto(v_sucursal_id, p_transportista_id, p_fecha, v_vistos,
                                             v_pagos_visto, v_falt_visto, v_huella_pagos, v_huella_falt);', 1);
  -- Lo cobrado: la cuenta común (_rendicion_cobros_vistos), la misma que usa resolver_rendicion.
  v_def := pg_temp.t5_parche(v_def,
    '    SELECT jsonb_build_object(
             ''efectivo'',         COALESCE(SUM(x.monto) FILTER (WHERE x.forma_pago = ''efectivo''), 0),
             ''transferencia'',    COALESCE(SUM(x.monto) FILTER (WHERE x.forma_pago = ''transferencia''), 0),
             ''cheque'',           COALESCE(SUM(x.monto) FILTER (WHERE x.forma_pago = ''cheque''), 0),
             ''cuenta_corriente'', COALESCE(SUM(x.monto) FILTER (WHERE x.forma_pago = ''cuenta_corriente''), 0),
             ''tarjeta'',          COALESCE(SUM(x.monto) FILTER (WHERE x.forma_pago = ''tarjeta''), 0),
             ''otros'',            COALESCE(SUM(x.monto) FILTER (
                                   WHERE x.forma_pago IS NULL
                                      OR x.forma_pago NOT IN (''efectivo'', ''transferencia'', ''cheque'',
                                                              ''cuenta_corriente'', ''tarjeta'')), 0),
             ''entregas'',         COALESCE(SUM(x.monto) FILTER (WHERE x.es_entrega_del_dia), 0))
      INTO v_cobros
      FROM public._rendicion_pagos(v_sucursal_id, p_fecha, p_fecha) x
     WHERE x.t_id = p_transportista_id
       AND x.f = p_fecha
       AND COALESCE(x.forma_pago, '''') <> ''adelanto_sueldo'';',
    '    v_cobros := public._rendicion_cobros_vistos(v_sucursal_id, p_transportista_id, p_fecha);', 1);
  -- La clave apunta al control que dejó el cierre.
  v_def := pg_temp.t5_parche(v_def,
    '  RETURNING id INTO v_id;

  RETURN v_id;',
    '  RETURNING id INTO v_id;

  IF v_clave IS NOT NULL THEN
    UPDATE altas_por_clave SET entidad_id = v_id WHERE clave = v_clave;
  END IF;

  RETURN v_id;', 1);
  EXECUTE v_def;
END
$confirmar$;

DO $resolver$
DECLARE
  v_def text;
BEGIN
  v_def := pg_get_functiondef('public.resolver_rendicion(date,uuid,text,jsonb)'::regprocedure);
  v_def := pg_temp.t5_parche(v_def,
    '  v_fecha_txt    text := to_char(p_fecha, ''DD/MM/YYYY'');',
    '  v_fecha_txt    text := to_char(p_fecha, ''DD/MM/YYYY'');
  -- m1, Rend-B7 y la clave (T5).
  v_falt_visto   numeric;
  v_cobros_visto jsonb;
  v_huella_pagos text;
  v_huella_falt  text;
  v_clave        uuid;
  v_contenido    text;
  v_previa       public.altas_por_clave%ROWTYPE;', 1);
  -- D7: el admin resuelve también la suya.
  v_def := pg_temp.t5_parche(v_def,
    '  IF NOT es_admin() THEN
    RAISE EXCEPTION ''Sólo un admin resuelve una disconformidad'' USING ERRCODE = ''42501'';
  END IF;',
    '  -- D7 (T5, decisión del dueño 26/11): también la de su propia rendición, como la confirma. Lo
  --     que no puede es cargarse el faltante a sí mismo (paso 5).
  IF NOT es_admin() THEN
    RAISE EXCEPTION ''Sólo un admin resuelve una disconformidad'' USING ERRCODE = ''42501'';
  END IF;', 1);
  -- Lo que vio el modal, además de los gastos y los pagos al personal.
  v_def := pg_temp.t5_parche(v_def,
    '    v_lineas := p_resolucion->''lineas'';
    IF EXISTS',
    '    -- m1 y Rend-B7 (T5): lo cobrado (como confirmar_rendicion), lo imputado a empleados y las
    -- huellas. Opcionales: un bundle viejo no los manda y sin ellos no se comparan.
    BEGIN
      IF jsonb_typeof(COALESCE(p_resolucion->''faltantes_visto'', ''null'')) NOT IN (''number'', ''null'')
         OR jsonb_typeof(COALESCE(p_resolucion->''huella_pagos_personal'', ''null'')) NOT IN (''string'', ''null'')
         OR jsonb_typeof(COALESCE(p_resolucion->''huella_faltantes'', ''null'')) NOT IN (''string'', ''null'')
         OR jsonb_typeof(COALESCE(p_resolucion->''clave'', ''null'')) NOT IN (''string'', ''null'')
         OR (jsonb_typeof(COALESCE(p_resolucion->''cobros_visto'', ''null'')) <> ''null''
             AND (jsonb_typeof(p_resolucion->''cobros_visto'') <> ''object''
                  OR EXISTS (SELECT 1 FROM unnest(ARRAY[''efectivo'', ''transferencia'', ''cheque'', ''cuenta_corriente'',
                                                        ''tarjeta'', ''otros'', ''entregas'']) k
                              WHERE jsonb_typeof(p_resolucion->''cobros_visto''->k) IS DISTINCT FROM ''number''))) THEN
        RAISE EXCEPTION ''formato'';
      END IF;
      v_falt_visto := (p_resolucion->>''faltantes_visto'')::numeric;
      IF jsonb_typeof(COALESCE(p_resolucion->''cobros_visto'', ''null'')) = ''object'' THEN
        v_cobros_visto := p_resolucion->''cobros_visto'';
      END IF;
      v_huella_pagos := p_resolucion->>''huella_pagos_personal'';
      v_huella_falt  := p_resolucion->>''huella_faltantes'';
      v_clave := NULLIF(p_resolucion->>''clave'', '''')::uuid;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION ''La resolución viene con un formato inválido'';
    END;
    v_lineas := p_resolucion->''lineas'';
    IF EXISTS', 1);
  -- La clave, con la rendición ya tomada.
  v_def := pg_temp.t5_parche(v_def,
    '  PERFORM public._rendicion_bloquear(ARRAY[public._rendicion_clave(p_transportista_id, p_fecha, v_sucursal_id)]);

  -- 7 ·',
    '  PERFORM public._rendicion_bloquear(ARRAY[public._rendicion_clave(p_transportista_id, p_fecha, v_sucursal_id)]);

  -- 6b · T5: la clave de la resolución (altas_por_clave). La misma clave con lo mismo es un
  --      reintento: devuelve el control del primer intento, ya resuelto, sin volver a imputar. Si
  --      esa resolución se deshizo, la clave se libera.
  IF v_clave IS NOT NULL THEN
    v_contenido := md5(jsonb_build_object(''fecha'', p_fecha, ''transportista'', p_transportista_id,
                                          ''observaciones'', p_observaciones,
                                          ''resolucion'', p_resolucion - ''clave'')::text);
    INSERT INTO altas_por_clave (clave, operacion, usuario_id, sucursal_id, contenido)
    VALUES (v_clave, ''resolucion_rendicion'', auth.uid(), v_sucursal_id, v_contenido)
    ON CONFLICT (clave) DO NOTHING;
    IF NOT FOUND THEN
      SELECT * INTO v_previa FROM altas_por_clave WHERE clave = v_clave;
      IF v_previa.operacion <> ''resolucion_rendicion'' OR v_previa.usuario_id IS DISTINCT FROM auth.uid()
         OR v_previa.sucursal_id <> v_sucursal_id THEN
        RAISE EXCEPTION ''Esta clave ya se usó para otra operación: recargá la página e intentá de nuevo.''
          USING ERRCODE = ''22023'';
      END IF;
      IF v_previa.contenido <> v_contenido THEN
        RAISE EXCEPTION ''Esta resolución ya entró con el intento anterior y lo que mandaste ahora es distinto: tocá Refrescar y volvé a abrirla.''
          USING ERRCODE = ''22023'';
      END IF;
      IF v_previa.entidad_id IS NOT NULL
         AND EXISTS (SELECT 1 FROM rendiciones_control
                      WHERE id = v_previa.entidad_id AND estado = ''resuelta'') THEN
        RETURN v_previa.entidad_id;
      END IF;
      -- La resolución de esa clave ya no está (se deshizo): la clave se libera y esto es otra.
      UPDATE altas_por_clave SET entidad_id = NULL WHERE clave = v_clave;
    END IF;
  END IF;

  -- 7 ·', 1);
  v_def := pg_temp.t5_parche(v_def,
    '    v_cambio := public._rendicion_cambio_visto(v_sucursal_id, p_transportista_id, p_fecha, v_vistos,
                                               v_pagos_visto, 0);',
    '    -- m1 (T5): lo imputado a empleados que vio el modal (sin el dato, 0, como antes).
    v_cambio := public._rendicion_cambio_visto(v_sucursal_id, p_transportista_id, p_fecha, v_vistos,
                                               v_pagos_visto, COALESCE(v_falt_visto, 0),
                                               v_huella_pagos, v_huella_falt);', 1);
  v_def := pg_temp.t5_parche(v_def,
    '    ELSIF v_cambio IS NOT NULL THEN
      RAISE EXCEPTION ''La resolución viene con un formato inválido'';
    END IF;
  END IF;',
    '    ELSIF v_cambio = ''faltantes'' AND v_falt_visto IS NOT NULL THEN
      RAISE EXCEPTION ''Los faltantes de esta rendición cambiaron mientras la resolvías: tocá Refrescar y volvé a abrir'';
    ELSIF v_cambio IS NOT NULL THEN
      RAISE EXCEPTION ''La resolución viene con un formato inválido'';
    END IF;
    -- m1 (T5): lo cobrado que vio el modal. En una disconformidad un cobro se puede corregir (la
    -- T4): se resuelve sobre lo que se vio.
    IF v_cobros_visto IS NOT NULL
       AND EXISTS (SELECT 1 FROM jsonb_each(public._rendicion_cobros_vistos(v_sucursal_id, p_transportista_id, p_fecha)) c
                    WHERE round((c.value #>> ''{}'')::numeric, 2)
                          <> round((v_cobros_visto->>c.key)::numeric, 2)) THEN
      RAISE EXCEPTION ''Los cobros de esta rendición cambiaron mientras la resolvías: tocá Refrescar y volvé a abrir'';
    END IF;
  END IF;', 1);
  -- GTO-C: el efectivo a entregar es una sola cuenta.
  v_def := pg_temp.t5_parche(v_def,
    '    v_disponible :=
        COALESCE((SELECT SUM(x.monto) FROM public._rendicion_pagos(v_sucursal_id, p_fecha, p_fecha) x
                   WHERE x.t_id = p_transportista_id AND x.forma_pago = ''efectivo''), 0)
      - COALESCE((SELECT SUM(g.monto_total) FROM gastos g
                   WHERE g.origen_pago = ''rendicion'' AND g.anulado_at IS NULL
                     AND g.sucursal_id = v_sucursal_id
                     AND g.rendicion_transportista_id = p_transportista_id
                     AND g.rendicion_fecha = p_fecha), 0)
      + COALESCE((SELECT SUM(m.monto) FROM empleado_movimientos m
                   WHERE m.rendicion_sucursal_id = v_sucursal_id
                     AND m.rendicion_transportista_id = p_transportista_id
                     AND m.rendicion_fecha = p_fecha
                     AND m.tipo IN (''pago'', ''faltante'')), 0);',
    '    -- GTO-C (T5): la cuenta común, la misma que la tarjeta.
    v_disponible := public._rendicion_efectivo_a_entregar(v_sucursal_id, p_transportista_id, p_fecha);', 1);
  v_def := pg_temp.t5_parche(v_def,
    '         resuelta_por = auth.uid()
   WHERE id = v_id;

  RETURN v_id;',
    '         resuelta_por = auth.uid()
   WHERE id = v_id;

  IF v_clave IS NOT NULL THEN
    UPDATE altas_por_clave SET entidad_id = v_id WHERE clave = v_clave;
  END IF;

  RETURN v_id;', 1);
  EXECUTE v_def;
END
$resolver$;

-- -------------------------------------------------------------------------
-- 5 · GTO-7 / D9: los gastos de la propia rendición
-- -------------------------------------------------------------------------
DO $gasto$
DECLARE
  v_def text;
BEGIN
  v_def := pg_get_functiondef('public._guardar_gasto(jsonb,boolean)'::regprocedure);
  v_def := pg_temp.t5_parche(v_def,
    '  -- 8b · desde Gastos: la rendicion vieja y la nueva, y recien ahi la fila',
    '  -- 8a · GTO-7 / D9 (T5, decisión del dueño 26/11): nadie le carga gastos a su propia rendición,
  --      ni el encargado ni el admin que reparte: se los anota el admin al cerrarla. Vale para el
  --      gasto nuevo, para el que llega a la rendición y para el que se edita en ella o sale de
  --      ella. Desde el cierre o la resolución el admin sí (los confirma y resuelve, D7); el
  --      encargado no llega ahí con la suya (confirmar_rendicion lo frena). Y la rendición de un
  --      encargado la confirma un admin (T4): sus gastos también los carga un admin.
  IF v_origen = ''rendicion'' OR v_viejo.origen_pago = ''rendicion'' THEN
    IF NOT (p_desde_cierre AND v_admin)
       AND v_uid IN (CASE WHEN v_origen = ''rendicion'' THEN v_rend_tr END,
                     CASE WHEN v_viejo.origen_pago = ''rendicion'' THEN v_viejo.rendicion_transportista_id END) THEN
      IF v_admin THEN
        RAISE EXCEPTION ''Un gasto de tu propia rendición se anota al cerrarla, desde Rendiciones (o lo carga otro admin)''
          USING ERRCODE = ''42501'';
      END IF;
      RAISE EXCEPTION ''Los gastos de tu propia rendición los carga un admin'' USING ERRCODE = ''42501'';
    END IF;
    IF NOT v_admin AND EXISTS (
         SELECT 1 FROM perfiles pe
          WHERE pe.rol = ''encargado''
            AND pe.id IN (CASE WHEN v_origen = ''rendicion'' THEN v_rend_tr END,
                          CASE WHEN v_viejo.origen_pago = ''rendicion'' THEN v_viejo.rendicion_transportista_id END)) THEN
      RAISE EXCEPTION ''Los gastos de la rendición de un encargado los carga un admin'' USING ERRCODE = ''42501'';
    END IF;
  END IF;

  -- 8b · desde Gastos: la rendicion vieja y la nueva, y recien ahi la fila', 1);
  EXECUTE v_def;
END
$gasto$;

DO $anular_gasto$
DECLARE
  v_def text;
BEGIN
  v_def := pg_get_functiondef('public._anular_gasto(bigint,text,boolean)'::regprocedure);
  v_def := pg_temp.t5_parche(v_def,
    '  IF NOT p_desde_cierre AND v_gasto.origen_pago = ''rendicion''
     AND public.control_rendicion_cerrado(',
    '  -- GTO-7 / D9 (T5): anular un gasto de la propia rendición, tampoco (el admin, desde el cierre o
  -- al deshacer la resolución, sí); el de la rendición de un encargado lo anula un admin.
  IF v_gasto.origen_pago = ''rendicion'' THEN
    IF NOT (p_desde_cierre AND public.es_admin()) AND v_gasto.rendicion_transportista_id = v_uid THEN
      IF public.es_admin() THEN
        RAISE EXCEPTION ''Un gasto de tu propia rendición se quita al cerrarla, desde Rendiciones (o lo anula otro admin)''
          USING ERRCODE = ''42501'';
      END IF;
      RAISE EXCEPTION ''Los gastos de tu propia rendición los anula un admin'' USING ERRCODE = ''42501'';
    END IF;
    IF NOT public.es_admin() AND EXISTS (SELECT 1 FROM perfiles pe
                                          WHERE pe.id = v_gasto.rendicion_transportista_id AND pe.rol = ''encargado'') THEN
      RAISE EXCEPTION ''Los gastos de la rendición de un encargado los anula un admin'' USING ERRCODE = ''42501'';
    END IF;
  END IF;
  IF NOT p_desde_cierre AND v_gasto.origen_pago = ''rendicion''
     AND public.control_rendicion_cerrado(', 1);
  EXECUTE v_def;
END
$anular_gasto$;

-- -------------------------------------------------------------------------
-- 6 · SEG-2: lo que el transportista ve de sus faltantes
-- -------------------------------------------------------------------------
DO $faltantes$
DECLARE
  v_def text;
BEGIN
  v_def := pg_get_functiondef('public.obtener_faltantes_rendiciones(date,date,uuid)'::regprocedure);
  v_def := pg_temp.t5_parche(v_def,
    '''causal'', f.causal, ''monto'', f.monto, ''observacion'', f.observacion,',
    '''causal'', f.causal, ''monto'', f.monto,
           -- SEG-2 (T5): al transportista, la observación sólo de la línea que se le cargó a él, y
           -- ni quién la cargó ni el rubro del gasto.
           ''observacion'', CASE WHEN es_encargado_o_admin() OR e.usuario_id = auth.uid() THEN f.observacion END,', 1);
  v_def := pg_temp.t5_parche(v_def,
    '''gasto_id'', f.gasto_id, ''rubro_nombre'', r.nombre,
           ''creado_por_nombre'', pf.nombre, ''created_at'', f.created_at,',
    '''gasto_id'', CASE WHEN es_encargado_o_admin() THEN f.gasto_id END,
           ''rubro_nombre'', CASE WHEN es_encargado_o_admin() THEN r.nombre END,
           ''creado_por_nombre'', CASE WHEN es_encargado_o_admin() THEN pf.nombre END,
           ''created_at'', f.created_at,', 1);
  EXECUTE v_def;
END
$faltantes$;

-- -------------------------------------------------------------------------
-- 7 · SEG-A: la lista blanca de auditoria_definer_sin_rol con las firmas y los cuerpos nuevos
-- -------------------------------------------------------------------------
DO $lista_blanca$
DECLARE
  v_def text;
BEGIN
  v_def := pg_get_functiondef('public.auditoria_definer_sin_rol()'::regprocedure);
  v_def := pg_temp.t5_parche(v_def,
    '    (''rendicion_dia_cerrada(date,bigint)'',       ''96bf9397648d73a7b77a2f84eb45cf24''),
    (''ultima_fecha_caja_cerrada(bigint)'',        ''cd39eceb6d9f4372c49a267151fb5c08''),',
    format('    -- T5 (D6): con la caja de quien cobró (p_cobrado_por); 1601-b2: rechazan a un desactivado.
    (%L, %L),
    (%L, %L),',
      'rendicion_dia_cerrada(date,bigint,uuid)',
      (SELECT md5(prosrc) FROM pg_proc WHERE oid = 'public.rendicion_dia_cerrada(date,bigint,uuid)'::regprocedure),
      'ultima_fecha_caja_cerrada(bigint,uuid)',
      (SELECT md5(prosrc) FROM pg_proc WHERE oid = 'public.ultima_fecha_caja_cerrada(bigint,uuid)'::regprocedure)), 1);
  v_def := pg_temp.t5_parche(v_def,
    '    (''control_rendicion_cerrado(uuid,bigint,date)'', ''3a5ed52d20b27cf1cb3820b95aa53153'')',
    format('    -- T5: la disconformidad cuenta como cerrada (D8) y rechaza a un desactivado (1601-b2).
    (%L, %L)',
      'control_rendicion_cerrado(uuid,bigint,date)',
      (SELECT md5(prosrc) FROM pg_proc WHERE oid = 'public.control_rendicion_cerrado(uuid,bigint,date)'::regprocedure)), 1);
  EXECUTE v_def;
END
$lista_blanca$;

-- -------------------------------------------------------------------------
-- POSCONDICIONES
-- -------------------------------------------------------------------------
DO $pos$
DECLARE
  r record;
  v text;
BEGIN
  IF to_regprocedure('public.marcar_rendicion_controlada(date,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · marcar_rendicion_controlada sigue';
  END IF;
  IF to_regprocedure('public.ultima_fecha_caja_cerrada(bigint)') IS NOT NULL
     OR to_regprocedure('public.rendicion_dia_cerrada(date,bigint)') IS NOT NULL
     OR to_regprocedure('public._rendicion_cambio_visto(bigint,uuid,date,jsonb,numeric,numeric)') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · quedó una firma vieja (PGRST203)';
  END IF;

  -- Cada función tocada: su search_path termina en pg_temp, y nada para anon.
  FOR r IN SELECT p.oid, p.oid::regprocedure::text AS firma, p.prosecdef, p.proconfig
             FROM pg_proc p
            WHERE p.oid IN (
              'public.control_rendicion_cerrado(uuid,bigint,date)'::regprocedure,
              'public.ultima_fecha_caja_cerrada(bigint,uuid)'::regprocedure,
              'public.rendicion_dia_cerrada(date,bigint,uuid)'::regprocedure,
              'public.guard_pago_fecha_cerrada()'::regprocedure,
              'public.registrar_pago_cliente_fifo_impl(bigint,numeric,text,date,text,text,uuid)'::regprocedure,
              'public.registrar_pago_combinado_cliente_fifo_impl(bigint,jsonb,date,text,text,uuid)'::regprocedure,
              'public.marcar_pagos_masivo_impl(bigint[],text,date,uuid)'::regprocedure,
              'public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)'::regprocedure,
              'public.anular_control_por_cambio_fecha_entrega()'::regprocedure,
              'public.actualizar_forma_pago_pago(bigint,text)'::regprocedure,
              'public.pagos_guard_anulacion_caja_cerrada()'::regprocedure,
              'public.corregir_cobro_rendicion(bigint,text,uuid,text)'::regprocedure,
              'public._anular_gasto(bigint,text,boolean)'::regprocedure,
              'public.consultar_control_rendicion(uuid,date)'::regprocedure,
              'public.jornadas_transportista(date,date,uuid)'::regprocedure,
              'public.jornada_transportista_detalle(date,uuid)'::regprocedure,
              'public.jornadas_preventista(date,date,uuid)'::regprocedure,
              'public._rendicion_huella_movimientos(bigint,uuid,date,text)'::regprocedure,
              'public._rendicion_cobros_vistos(bigint,uuid,date)'::regprocedure,
              'public._rendicion_cambio_visto(bigint,uuid,date,jsonb,numeric,numeric,text,text)'::regprocedure,
              'public.obtener_resumen_rendiciones(date,date,uuid)'::regprocedure,
              'public.confirmar_rendicion(date,uuid,text,jsonb,text)'::regprocedure,
              'public.resolver_rendicion(date,uuid,text,jsonb)'::regprocedure,
              'public._guardar_gasto(jsonb,boolean)'::regprocedure,
              'public.obtener_faltantes_rendiciones(date,date,uuid)'::regprocedure,
              'public.auditoria_definer_sin_rol()'::regprocedure)
  LOOP
    IF NOT EXISTS (SELECT 1 FROM unnest(r.proconfig) c WHERE c ~ '^search_path=.*pg_temp$') THEN
      RAISE EXCEPTION 'mig NNN · % no termina su search_path en pg_temp (%)', r.firma, r.proconfig;
    END IF;
    IF has_function_privilege('anon', r.oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'mig NNN · % quedó con EXECUTE para anon', r.firma;
    END IF;
  END LOOP;

  -- Lo que llama el front sigue para authenticated; lo interno, no.
  FOR r IN SELECT * FROM (VALUES
    ('public.ultima_fecha_caja_cerrada(bigint,uuid)', true),
    ('public.rendicion_dia_cerrada(date,bigint,uuid)', true),
    ('public.control_rendicion_cerrado(uuid,bigint,date)', true),
    ('public.consultar_control_rendicion(uuid,date)', true),
    ('public.obtener_resumen_rendiciones(date,date,uuid)', true),
    ('public.confirmar_rendicion(date,uuid,text,jsonb,text)', true),
    ('public.resolver_rendicion(date,uuid,text,jsonb)', true),
    ('public.obtener_faltantes_rendiciones(date,date,uuid)', true),
    ('public.jornadas_transportista(date,date,uuid)', true),
    ('public._rendicion_huella_movimientos(bigint,uuid,date,text)', false),
    ('public._rendicion_cobros_vistos(bigint,uuid,date)', false),
    ('public._rendicion_cambio_visto(bigint,uuid,date,jsonb,numeric,numeric,text,text)', false),
    ('public._guardar_gasto(jsonb,boolean)', false),
    ('public.guard_pago_fecha_cerrada()', false)
  ) AS t(f, auth) LOOP
    IF has_function_privilege('authenticated', r.f::regprocedure, 'EXECUTE') IS DISTINCT FROM r.auth THEN
      RAISE EXCEPTION 'mig NNN · EXECUTE de authenticated sobre % no es %', r.f, r.auth;
    END IF;
  END LOOP;

  -- El guard corre después del que fija cobrado_por.
  SELECT pg_get_triggerdef(oid) INTO v FROM pg_trigger
   WHERE tgname = 'trg_pagos_zzz_guard_fecha_cerrada' AND tgrelid = 'public.pagos'::regclass;
  IF v IS DISTINCT FROM 'CREATE TRIGGER trg_pagos_zzz_guard_fecha_cerrada BEFORE INSERT OR UPDATE OF fecha, monto ON public.pagos FOR EACH ROW EXECUTE FUNCTION guard_pago_fecha_cerrada()' THEN
    RAISE EXCEPTION 'mig NNN · el trigger de fecha de pagos quedó %', v;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_pagos_guard_fecha_cerrada') THEN
    RAISE EXCEPTION 'mig NNN · quedó el trigger de fecha viejo';
  END IF;

  -- Las anclas cambiaron lo que tenían que cambiar.
  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.resolver_rendicion(date,uuid,text,jsonb)'::regprocedure)
       !~ '_rendicion_efectivo_a_entregar'
     OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.confirmar_rendicion(date,uuid,text,jsonb,text)'::regprocedure)
       !~ '_rendicion_cobros_vistos'
     OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.jornadas_transportista(date,date,uuid)'::regprocedure)
       ~ 'p_desde - 90'
     OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.obtener_faltantes_rendiciones(date,date,uuid)'::regprocedure)
       ~ '''creado_por_nombre'', pf\.nombre' THEN
    RAISE EXCEPTION 'mig NNN · un parche no quedó';
  END IF;

  -- La lista blanca de SEG-A no encuentra nada de esta migración.
  IF EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol() a
              WHERE a.firma IN ('rendicion_dia_cerrada(date,bigint,uuid)', 'ultima_fecha_caja_cerrada(bigint,uuid)',
                                'control_rendicion_cerrado(uuid,bigint,date)', 'consultar_control_rendicion(uuid,date)',
                                'obtener_resumen_rendiciones(date,date,uuid)', 'obtener_faltantes_rendiciones(date,date,uuid)',
                                'jornadas_transportista(date,date,uuid)', 'jornada_transportista_detalle(date,uuid)',
                                'jornadas_preventista(date,date,uuid)', 'confirmar_rendicion(date,uuid,text,jsonb,text)',
                                'resolver_rendicion(date,uuid,text,jsonb)')) THEN
    RAISE EXCEPTION 'mig NNN · auditoria_definer_sin_rol encuentra una función de esta migración';
  END IF;
END
$pos$;

COMMIT;
