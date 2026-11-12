-- =========================================================================
-- NNN · EL CIERRE DE UNA RENDICIÓN VALIDA LO QUE CONFIRMA, Y UNA ENTREGA
--       VALIDA A SU CHOFER Y A SU FECHA
--       (auditoría de lo ajeno al núcleo del 12/11: FRT-03, REN-2 y REN-4 de
--       #1547; RUT-2 y RUT-4 de #1548; GTO-2 de #1522)
--
-- Parcha por ancla `confirmar_rendicion`, `desmarcar_rendicion_controlada`,
-- `marcar_rendicion_controlada`, `aplicar_orden_ruta`, `marcar_entregas_masivo`
-- y `marcar_entrega_y_pago_masivo_impl`; reemplaza el cuerpo de
-- `_actua_como_transportista` (diez líneas); y suma un CHECK `NOT VALID` a
-- `pedidos`. Premisa de md5 sobre los cuerpos vivos leídos el 12/11 y
-- poscondición de md5, ACL y definer.
-- Ensayo: scripts/test-rendicion-y-entregas-1547-1548.sql. Se aplica en LF.
--
-- =========================================================================
-- 1 · FRT-03 · EL CIERRE CONFIRMABA UN COBRO QUE EL CONTROLADOR NO VIO
-- =========================================================================
-- El cierre ya manda lo que vio de los gastos, los pagos al personal y los
-- faltantes, y `_rendicion_cambio_visto` rechaza si cambió. Lo cobrado no
-- viajaba: el controlador veía $100, el chofer cargaba un cobro de $50, y la
-- confirmación congelaba $150 en la foto.
--
-- Ahora el cierre manda `cobros_visto`: lo cobrado de la rendición por forma
-- de pago y lo que de eso fue cobro del día de la entrega, tal como lo mostró
-- la tarjeta (`obtener_resumen_rendiciones`: total_efectivo,
-- total_transferencia, total_cheque, total_cuenta_corriente, total_tarjeta,
-- total_otros y total_entregas). `confirmar_rendicion` lo recalcula de
-- `_rendicion_pagos` con el mismo filtro que la tarjeta (sin el adelanto de
-- sueldo, que no es plata de la rendición) y rechaza si alguno cambió. Cubre
-- un cobro que entra, uno que se anula, uno que cambia de forma de pago y uno
-- que pasa de cuenta corriente a entrega del día. No cubre un cambio que deja
-- iguales las siete sumas (anular un cobro de $100 en efectivo y cargar otro de
-- $100 en efectivo): la tarjeta no trae una cantidad ni un id de los cobros, y
-- sumarlos obligaba a recrear `obtener_resumen_rendiciones` (bajo B7).
--
-- Un bundle viejo del PWA no conoce el campo y no lo manda: sin `cobros_visto`
-- (o con null) no se compara, como hasta hoy, y el cierre no se rompe. El front
-- nuevo lo manda siempre.
--
-- =========================================================================
-- 2 · REN-2 · UNA RENDICIÓN CON FECHA FUTURA CERRABA LA CAJA DE LA SUCURSAL
-- =========================================================================
-- `ultima_fecha_caja_cerrada` es el máximo de la sucursal, y
-- `guard_pago_fecha_cerrada` rechaza todo pago con fecha hasta ahí (decisión
-- de la 134). Confirmar la rendición de hoy + 30 dejaba a toda la sucursal sin
-- poder cobrar.
--   · `confirmar_rendicion` y `marcar_rendicion_controlada` (las dos que crean
--     una fila de `rendiciones_control`; resolver y deshacer parten de una que
--     ya existe) rechazan un día posterior a hoy (`_tablero_hoy()`).
--   · Y una rendición nueva tiene que tener algo que rendir: para ese chofer,
--     ese día y esa sucursal, una entrega (`_rendicion_entregas`), un cobro
--     (`_rendicion_pagos`), un gasto de la rendición o un movimiento de
--     empleado de la rendición; o ya tener su fila de control. Es exactamente
--     lo que pone la tarjeta en la grilla (`fechas_activas` de
--     `obtener_resumen_rendiciones`), así que todo lo que la pantalla ofrece
--     cerrar pasa, y el día de un chofer que después se desactivó o se cambió
--     de sucursal también: sus entregas y sus cobros siguen ahí. Se descartó
--     "es o fue de la sucursal": que fue no queda guardado en ningún lado, y
--     "es hoy de la sucursal" deja cerrar un día vacío de cualquier chofer de
--     la sucursal, que no rinde nada y sólo sirve para cerrar la caja (B4).
--
-- =========================================================================
-- 3 · REN-4 (y GTO-2 de #1522) · REABRIR UNA RESUELTA DEJABA EL FALTANTE VIVO
-- =========================================================================
-- «Reabrir control» (`desmarcar_rendicion_controlada`) y «Editar cierre»
-- (`confirmar_rendicion` sobre una fila `resuelta`) no miraban la resolución:
-- la rendición quedaba sin control, o "confirmada" sin `resuelta_por`, y la
-- línea de `rendicion_faltantes` y la deuda del empleado seguían en pie. Ahora
-- las dos rechazan una rendición `resuelta` o con líneas vivas, y mandan a
-- «Deshacer resolución» (`deshacer_resolucion_rendicion`, sólo del admin desde
-- la 446, que lo deshace todo junto y la deja en disconformidad). El encargado
-- ya no puede reabrir ni editar una resuelta. El 4b de `confirmar_rendicion`
-- (volver a disconformidad con líneas vivas) queda como estaba.
--
-- =========================================================================
-- 4 · RUT-2 · SE ENTREGABA O SE ARMABA UNA RUTA A NOMBRE DE CUALQUIERA
-- =========================================================================
-- `_actua_como_transportista(uuid, sucursal)` miraba sólo el rol: un chofer de
-- otra sucursal o uno desactivado pasaban. Ahora exige, como
-- `cambiar_transportista_recorrido`: perfil activo, que sea de esa sucursal
-- (`usuario_sucursales`) y el rol de chofer, base o el extra de `perfil_roles`
-- de ESA sucursal. `es_transportista()` (la de `auth.uid()`, que incluye al
-- admin) no se toca.
-- Sus llamadores (pg_proc y triggers, leídos el 12/11):
--   · `pedidos_entrega_con_chofer()` (trigger de `pedidos`): pregunta sólo al
--     pasar a entregado o al cambiar el chofer de un entregado. Un entregado
--     viejo de un chofer hoy inactivo no se revalida: el pasado queda.
--   · `aplicar_cambio_de_parada`: ya pedía `usuario_sucursales`; ahora además
--     el perfil activo.
-- Y `aplicar_orden_ruta` no validaba al chofer: ahora lo pasa por la misma
-- función. Con la ruta en curso de un chofer que se desactivó ya no se puede
-- re-armar con él: se pasa a otro con «Cambiar transportista»
-- (`cambiar_transportista_recorrido`), que ya validaba esto mismo.
-- Lo que deja de andar sobre los pedidos pendientes de un chofer que hoy no
-- pasa (inactivo o sin la sucursal): entregarlos a su nombre (PATCH del front,
-- las dos masivas, el canje de `aplicar_cambio_de_parada`) y armarle o
-- re-armarle una ruta. Se reasignan a otro chofer.
--
-- =========================================================================
-- 5 · RUT-4 · EL CHOFER SACABA UNA ENTREGA DE LA RENDICIÓN BORRÁNDOLE LA FECHA
-- =========================================================================
-- El chofer tiene `UPDATE (fecha_entrega)` por REST sobre lo suyo, y
-- `pedidos_proteger_columnas` acepta cualquier fecha mientras siga entregado,
-- también NULL: el pedido salía de `_rendicion_entregas` y de toda rendición.
-- Ahora un CHECK: `estado <> 'entregado' OR fecha_entrega IS NOT NULL`. Va
-- como CHECK y no en `pedidos_proteger_columnas` ni en un trigger (otras
-- migraciones pendientes tienen el md5 de esa función y la lista de triggers
-- de `pedidos` como premisa), y cubre el REST, las RPC y los triggers.
-- Corregir el día de la entrega a otra fecha (no nula) sigue andando.
-- Los caminos que entregan, revisados el 12/11:
--   · el alta de un vale blanco (`crear_pedido_completo`) y
--     `cambiar_tipo_factura_pedido` a VB ponen la fecha (12:00 ART de la fecha
--     del pedido), o conservan la que el entregado ya tenía;
--   · la entrega por REST del front (`actualizarEstado`) manda la fecha
--     elegida o la de hoy, a las 12:00 ART; el canje se entrega por ahí;
--   · `marcar_entregas_masivo(…, p_fecha => NULL)` dejaba el entregado sin
--     fecha (bajo B2 de rutas), y `marcar_entrega_y_pago_masivo_impl` también,
--     cuando todos los pedidos ya estaban pagados (si no, rebotaba en
--     `pagos.fecha NOT NULL`; además, con NULL el chequeo del encargado "sólo
--     hoy" no frenaba). Las dos toman ahora hoy (`_tablero_hoy()`) cuando no
--     viene la fecha, que es su default: la entrega queda a las 12:00 ART de
--     hoy, como la del front.
-- El CHECK va `NOT VALID`: vale para lo nuevo. En prod hay 7 entregados de
-- agosto sin fecha (6 de la app y 1 canje) que esta migración NO corrige. Ojo:
-- un CHECK `NOT VALID` se revisa en todo UPDATE de la fila, así que cualquier
-- escritura sobre esos 7 (un cobro que recalcula `monto_pagado`, una edición)
-- va a fallar con 23514 hasta que se les ponga la fecha. Queda para el dueño.
-- No se le pone tope a la fecha futura de una entrega (VTA-07 de #1522).
-- =========================================================================

BEGIN;
SET LOCAL lock_timeout = '5s';

-- ---------------------------------------------------------------------------
-- Premisa: los cuerpos vivos son los leídos el 12/11, y el CHECK no existe
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.confirmar_rendicion(date,uuid,text,jsonb,text)',               'a43c402226370f13e908380f565b2fb4'),
    ('public.desmarcar_rendicion_controlada(date,uuid)',                    'eaa447cf71f857dadbb58aa42049cbde'),
    ('public.marcar_rendicion_controlada(date,uuid)',                       'f6d0ebb8e8aac82f7a4bdd92a5c9eecb'),
    ('public._actua_como_transportista(uuid,bigint)',                       '2de47d995da886aa51efa278cb969f5f'),
    ('public.aplicar_orden_ruta(uuid,jsonb,numeric,integer,jsonb,date)',    'cc8a2e6c8f3599313d46fa539a227c34'),
    ('public.marcar_entregas_masivo(bigint[],uuid,date)',                   'ac0c4a331c9876d5f33c778cbedc4fc8'),
    ('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)',   '9a32b73da6395bb29075c00d8c3b5469')
  ) AS t(f, h) LOOP
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió en prod desde que se leyó (md5 %): rehacer sobre la definición vigente', r.f, v;
    END IF;
  END LOOP;

  IF EXISTS (SELECT 1 FROM pg_constraint
              WHERE conrelid = 'public.pedidos'::regclass AND conname = 'pedidos_entregado_con_fecha') THEN
    RAISE EXCEPTION 'mig NNN · pedidos_entregado_con_fecha ya existe: revisar a mano';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 4 · RUT-2: quién reparte en una sucursal
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._actua_como_transportista(p_usuario uuid, p_sucursal bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  -- #1548 (RUT-2): activo y de esa sucursal, como cambiar_transportista_recorrido. Un
  -- entregado viejo no se revalida: pedidos_entrega_con_chofer pregunta sólo al entregar o
  -- al cambiar el chofer.
  SELECT EXISTS (
    SELECT 1 FROM public.perfiles p
     WHERE p.id = p_usuario
       AND p.activo
       AND EXISTS (SELECT 1 FROM public.usuario_sucursales us
                    WHERE us.usuario_id = p.id
                      AND us.sucursal_id = p_sucursal)
       AND (p.rol = 'transportista'
            OR (p.rol NOT IN ('admin', 'encargado')
                AND EXISTS (SELECT 1 FROM public.perfil_roles pr
                             WHERE pr.usuario_id = p.id
                               AND pr.sucursal_id = p_sucursal
                               AND pr.rol = 'transportista'))));
$function$;

DO $parche_ruta$
DECLARE
  v_def text := pg_get_functiondef('public.aplicar_orden_ruta(uuid,jsonb,numeric,integer,jsonb,date)'::regprocedure);
  v_a text := $a$  IF p_pedidos IS NULL OR jsonb_array_length(p_pedidos) = 0 THEN
    RAISE EXCEPTION 'No hay pedidos para aplicar orden';
  END IF;
$a$;
  v_r text := $r$  IF p_pedidos IS NULL OR jsonb_array_length(p_pedidos) = 0 THEN
    RAISE EXCEPTION 'No hay pedidos para aplicar orden';
  END IF;

  -- #1548 (RUT-2): la ruta sale a nombre de quien reparte en esta sucursal: activo, de la
  -- sucursal y con el rol de chofer. Es la regla de la entrega (pedidos_entrega_con_chofer).
  IF p_transportista_id IS NULL OR NOT public._actua_como_transportista(p_transportista_id, v_sucursal) THEN
    RAISE EXCEPTION 'La ruta no puede salir a nombre de %: no es un chofer activo de esta sucursal.',
      COALESCE((SELECT nombre FROM perfiles WHERE id = p_transportista_id), 'ese usuario')
      USING ERRCODE = '42501';
  END IF;
$r$;
  v_n int;
BEGIN
  v_n := (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · aplicar_orden_ruta: el ancla aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(v_def, v_a, v_r);
END
$parche_ruta$;

-- ---------------------------------------------------------------------------
-- 5 · RUT-4: las masivas sin fecha entregan hoy
-- ---------------------------------------------------------------------------
DO $parche_masivo$
DECLARE
  v_def text := pg_get_functiondef('public.marcar_entregas_masivo(bigint[],uuid,date)'::regprocedure);
  v_a text := $a$  IF p_pedido_ids IS NULL OR array_length(p_pedido_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;
$a$;
  v_r text := $r$  -- #1548 (RUT-4): sin fecha, hoy (su default). Con NULL el entregado quedaba sin
  -- fecha_entrega y fuera de toda rendición; ahora lo frena el CHECK pedidos_entregado_con_fecha.
  p_fecha := COALESCE(p_fecha, public._tablero_hoy());

  IF p_pedido_ids IS NULL OR array_length(p_pedido_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;
$r$;
  v_n int;
BEGIN
  v_n := (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · marcar_entregas_masivo: el ancla aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(v_def, v_a, v_r);
END
$parche_masivo$;

DO $parche_masivo_pago$
DECLARE
  v_def text := pg_get_functiondef('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)'::regprocedure);
  v_a text := $a$  p_forma_pago := public._forma_pago_de_cobro(p_forma_pago, true);
$a$;
  v_r text := $r$  p_forma_pago := public._forma_pago_de_cobro(p_forma_pago, true);

  -- #1548 (RUT-4): sin fecha, hoy (su default). Con NULL no frenaban ni el tope de futuro ni
  -- el "sólo hoy" del encargado, y con todo ya pagado el entregado quedaba sin fecha_entrega.
  p_fecha := COALESCE(p_fecha, public._tablero_hoy());
$r$;
  v_n int;
BEGIN
  v_n := (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · marcar_entrega_y_pago_masivo_impl: el ancla aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(v_def, v_a, v_r);
END
$parche_masivo_pago$;

-- Un entregado tiene fecha de entrega. NOT VALID: los 7 de agosto que no la tienen quedan para el
-- dueño (ver el encabezado: cualquier UPDATE sobre ellos falla hasta corregirlos).
ALTER TABLE public.pedidos
  ADD CONSTRAINT pedidos_entregado_con_fecha
  CHECK (estado <> 'entregado' OR fecha_entrega IS NOT NULL) NOT VALID;

-- ---------------------------------------------------------------------------
-- 1, 2 y 3 · confirmar_rendicion
-- ---------------------------------------------------------------------------
DO $parche_confirmar$
DECLARE
  v_def text := pg_get_functiondef('public.confirmar_rendicion(date,uuid,text,jsonb,text)'::regprocedure);
  v_anclas text[] := ARRAY[
    -- a · las variables nuevas
    $a$  v_cambio      text;
BEGIN
$a$,
    -- b · la fecha, con el estado
    $a$  IF p_estado NOT IN ('confirmada','disconformidad') THEN
    RAISE EXCEPTION 'Estado invalido: %. Use "confirmada" o "disconformidad"', p_estado;
  END IF;
$a$,
    -- c · con la rendición tomada: la resolución y que haya algo que rendir
    $a$  PERFORM public._rendicion_bloquear(ARRAY[public._rendicion_clave(p_transportista_id, p_fecha, v_sucursal_id)]);
$a$,
    -- d · el formato de cobros_visto
    $a$       OR jsonb_typeof(COALESCE(p_gastos_rendicion->'faltantes_visto', '0')) <> 'number' THEN
      RAISE EXCEPTION 'formato';
    END IF;
$a$,
    -- e · lo cobrado, después de lo visto de gastos, pagos al personal y faltantes
    $a$  ELSIF v_cambio = 'faltantes' THEN
    RAISE EXCEPTION 'Los faltantes de esta rendición cambiaron mientras la cerrabas: tocá Refrescar y volvé a abrir el cierre';
  END IF;
$a$];
  v_reemplazos text[] := ARRAY[
    $r$  v_cambio      text;
  v_cobros_visto jsonb; -- #1547 (FRT-03)
  v_cobros       jsonb;
BEGIN
$r$,
    $r$  IF p_estado NOT IN ('confirmada','disconformidad') THEN
    RAISE EXCEPTION 'Estado invalido: %. Use "confirmada" o "disconformidad"', p_estado;
  END IF;

  -- #1547 (REN-2): un día que no llegó no se rinde. Cerrado, cerraba la caja de toda la
  -- sucursal hasta esa fecha (ultima_fecha_caja_cerrada es el máximo de la sucursal).
  IF p_fecha IS NULL OR p_fecha > public._tablero_hoy() THEN
    RAISE EXCEPTION 'La rendición del % todavía no se puede cerrar: ese día no llegó',
      COALESCE(to_char(p_fecha, 'DD/MM/YYYY'), '(sin fecha)') USING ERRCODE = '22023';
  END IF;
$r$,
    $r$  PERFORM public._rendicion_bloquear(ARRAY[public._rendicion_clave(p_transportista_id, p_fecha, v_sucursal_id)]);

  -- 2b · #1547 (REN-4, GTO-2 de #1522): una resolución se deshace toda junta, y sólo desde
  --      «Deshacer resolución» (del admin). Volver a cerrar una resuelta, o una con líneas
  --      vivas, la dejaba "confirmada" con el faltante cargado al empleado.
  IF EXISTS (SELECT 1 FROM rendiciones_control rc
              WHERE rc.fecha = p_fecha AND rc.transportista_id = p_transportista_id
                AND rc.sucursal_id = v_sucursal_id AND rc.estado = 'resuelta')
     OR EXISTS (SELECT 1 FROM rendicion_faltantes f
                 WHERE f.rendicion_sucursal_id = v_sucursal_id
                   AND f.rendicion_transportista_id = p_transportista_id
                   AND f.rendicion_fecha = p_fecha
                   AND f.anulada_at IS NULL) THEN
    RAISE EXCEPTION 'Esta rendición tiene una diferencia resuelta: para cambiar su cierre, un admin tiene que deshacer la resolución primero';
  END IF;

  -- 2c · #1547 (REN-2): una rendición nueva tiene algo que rendir en esta sucursal: una
  --      entrega, un cobro, un gasto o un movimiento de empleado de ese chofer ese día. Es lo
  --      que pone la tarjeta en la grilla (fechas_activas de obtener_resumen_rendiciones), y
  --      vale también para un chofer que después se desactivó o se fue de la sucursal.
  IF NOT EXISTS (SELECT 1 FROM rendiciones_control rc
                  WHERE rc.fecha = p_fecha AND rc.transportista_id = p_transportista_id
                    AND rc.sucursal_id = v_sucursal_id)
     AND NOT EXISTS (SELECT 1 FROM public._rendicion_entregas(v_sucursal_id, p_fecha, p_fecha) e
                      WHERE e.t_id = p_transportista_id)
     AND NOT EXISTS (SELECT 1 FROM public._rendicion_pagos(v_sucursal_id, p_fecha, p_fecha) x
                      WHERE x.t_id = p_transportista_id)
     AND NOT EXISTS (SELECT 1 FROM gastos g
                      WHERE g.origen_pago = 'rendicion' AND g.anulado_at IS NULL
                        AND g.sucursal_id = v_sucursal_id
                        AND g.rendicion_transportista_id = p_transportista_id
                        AND g.rendicion_fecha = p_fecha)
     AND NOT EXISTS (SELECT 1 FROM empleado_movimientos m
                      WHERE m.rendicion_sucursal_id = v_sucursal_id
                        AND m.rendicion_transportista_id = p_transportista_id
                        AND m.rendicion_fecha = p_fecha) THEN
    RAISE EXCEPTION 'No hay nada que rendir de ese transportista el % en esta sucursal: ni entregas, ni cobros, ni gastos',
      to_char(p_fecha, 'DD/MM/YYYY') USING ERRCODE = '22023';
  END IF;
$r$,
    $r$       OR jsonb_typeof(COALESCE(p_gastos_rendicion->'faltantes_visto', '0')) <> 'number' THEN
      RAISE EXCEPTION 'formato';
    END IF;
    -- #1547 (FRT-03): lo cobrado que mostró el cierre, {efectivo, transferencia, cheque,
    -- cuenta_corriente, tarjeta, otros, entregas}. Un bundle viejo no lo manda: sin el campo
    -- (o con null) no se compara, como antes, y el cierre no se rompe. El front nuevo lo
    -- manda siempre.
    IF jsonb_typeof(p_gastos_rendicion->'cobros_visto') IS DISTINCT FROM 'null'
       AND p_gastos_rendicion->'cobros_visto' IS NOT NULL THEN
      IF jsonb_typeof(p_gastos_rendicion->'cobros_visto') <> 'object'
         OR EXISTS (SELECT 1 FROM unnest(ARRAY['efectivo', 'transferencia', 'cheque', 'cuenta_corriente',
                                               'tarjeta', 'otros', 'entregas']) k
                     WHERE jsonb_typeof(p_gastos_rendicion->'cobros_visto'->k) IS DISTINCT FROM 'number') THEN
        RAISE EXCEPTION 'formato';
      END IF;
      v_cobros_visto := p_gastos_rendicion->'cobros_visto';
    END IF;
$r$,
    $r$  ELSIF v_cambio = 'faltantes' THEN
    RAISE EXCEPTION 'Los faltantes de esta rendición cambiaron mientras la cerrabas: tocá Refrescar y volvé a abrir el cierre';
  END IF;

  -- 4a · #1547 (FRT-03): lo cobrado, con el filtro de la tarjeta (pagos_agg de
  --      obtener_resumen_rendiciones: sin el adelanto de sueldo). Una rendición cerrada se lee
  --      de su foto, como la tarjeta. Cada cobro que entra toma el lock de la rendición del
  --      paso 2 o espera la foto.
  IF v_cobros_visto IS NOT NULL THEN
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
      INTO v_cobros
      FROM public._rendicion_pagos(v_sucursal_id, p_fecha, p_fecha) x
     WHERE x.t_id = p_transportista_id
       AND x.f = p_fecha
       AND COALESCE(x.forma_pago, '') <> 'adelanto_sueldo';
    IF EXISTS (SELECT 1 FROM jsonb_each(v_cobros) c
                WHERE round((c.value #>> '{}')::numeric, 2)
                      <> round((v_cobros_visto->>c.key)::numeric, 2)) THEN
      RAISE EXCEPTION 'Los cobros de esta rendición cambiaron mientras la cerrabas: tocá Refrescar y volvé a abrir el cierre';
    END IF;
  END IF;
$r$];
  v_n int;
BEGIN
  FOR i IN 1 .. array_length(v_anclas, 1) LOOP
    v_n := (length(v_def) - length(replace(v_def, v_anclas[i], ''))) / length(v_anclas[i]);
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'mig NNN · confirmar_rendicion: el ancla % aparece % vez/veces y se esperaba 1', i, v_n;
    END IF;
    v_def := replace(v_def, v_anclas[i], v_reemplazos[i]);
  END LOOP;
  EXECUTE v_def;
END
$parche_confirmar$;

-- ---------------------------------------------------------------------------
-- 3 · REN-4: «Reabrir control» no deshace una resolución
-- ---------------------------------------------------------------------------
DO $parche_desmarcar$
DECLARE
  v_def text := pg_get_functiondef('public.desmarcar_rendicion_controlada(date,uuid)'::regprocedure);
  v_a text := $a$  PERFORM public._rendicion_bloquear(ARRAY[public._rendicion_clave(p_transportista_id, p_fecha, v_sucursal_id)]);
$a$;
  v_r text := $r$  PERFORM public._rendicion_bloquear(ARRAY[public._rendicion_clave(p_transportista_id, p_fecha, v_sucursal_id)]);

  -- #1547 (REN-4, GTO-2 de #1522): reabrir una resuelta dejaba la línea viva y el faltante
  -- cargado al empleado. Una resolución se deshace toda junta, desde «Deshacer resolución».
  IF EXISTS (SELECT 1 FROM rendiciones_control rc
              WHERE rc.fecha = p_fecha AND rc.transportista_id = p_transportista_id
                AND rc.sucursal_id = v_sucursal_id AND rc.estado = 'resuelta')
     OR EXISTS (SELECT 1 FROM rendicion_faltantes f
                 WHERE f.rendicion_sucursal_id = v_sucursal_id
                   AND f.rendicion_transportista_id = p_transportista_id
                   AND f.rendicion_fecha = p_fecha
                   AND f.anulada_at IS NULL) THEN
    RAISE EXCEPTION 'Esta rendición tiene una diferencia resuelta: para reabrirla, un admin tiene que deshacer la resolución primero';
  END IF;
$r$;
  v_n int;
BEGIN
  v_n := (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · desmarcar_rendicion_controlada: el ancla aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(v_def, v_a, v_r);
END
$parche_desmarcar$;

-- ---------------------------------------------------------------------------
-- 2 · REN-2: marcar_rendicion_controlada también crea la fila
-- ---------------------------------------------------------------------------
DO $parche_marcar$
DECLARE
  v_def text := pg_get_functiondef('public.marcar_rendicion_controlada(date,uuid)'::regprocedure);
  v_a text := $a$    RAISE EXCEPTION 'Tu rendición la controla otro encargado o un admin'
      USING ERRCODE = '42501';
  END IF;
$a$;
  v_r text := $r$    RAISE EXCEPTION 'Tu rendición la controla otro encargado o un admin'
      USING ERRCODE = '42501';
  END IF;

  -- #1547 (REN-2): las mismas dos reglas que confirmar_rendicion: ni un día que no llegó, ni
  -- una rendición sin nada que rendir en esta sucursal (salvo que ya tenga su fila).
  IF p_fecha IS NULL OR p_fecha > public._tablero_hoy() THEN
    RAISE EXCEPTION 'La rendición del % todavía no se puede cerrar: ese día no llegó',
      COALESCE(to_char(p_fecha, 'DD/MM/YYYY'), '(sin fecha)') USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM rendiciones_control rc
                  WHERE rc.fecha = p_fecha AND rc.transportista_id = p_transportista_id
                    AND rc.sucursal_id = v_sucursal_id)
     AND NOT EXISTS (SELECT 1 FROM public._rendicion_entregas(v_sucursal_id, p_fecha, p_fecha) e
                      WHERE e.t_id = p_transportista_id)
     AND NOT EXISTS (SELECT 1 FROM public._rendicion_pagos(v_sucursal_id, p_fecha, p_fecha) x
                      WHERE x.t_id = p_transportista_id)
     AND NOT EXISTS (SELECT 1 FROM gastos g
                      WHERE g.origen_pago = 'rendicion' AND g.anulado_at IS NULL
                        AND g.sucursal_id = v_sucursal_id
                        AND g.rendicion_transportista_id = p_transportista_id
                        AND g.rendicion_fecha = p_fecha)
     AND NOT EXISTS (SELECT 1 FROM empleado_movimientos m
                      WHERE m.rendicion_sucursal_id = v_sucursal_id
                        AND m.rendicion_transportista_id = p_transportista_id
                        AND m.rendicion_fecha = p_fecha) THEN
    RAISE EXCEPTION 'No hay nada que rendir de ese transportista el % en esta sucursal: ni entregas, ni cobros, ni gastos',
      to_char(p_fecha, 'DD/MM/YYYY') USING ERRCODE = '22023';
  END IF;
$r$;
  v_n int;
BEGIN
  v_n := (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · marcar_rendicion_controlada: el ancla aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(v_def, v_a, v_r);
END
$parche_marcar$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, el definer y los EXECUTE quedaron como en el repo,
-- y el CHECK existe sin validar
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.confirmar_rendicion(date,uuid,text,jsonb,text)', '87ecb9b67b87ffa0d29afa0043e019b8', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.desmarcar_rendicion_controlada(date,uuid)', '2ef77e1fe3c0d8d59b330d6e8a038eee', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.marcar_rendicion_controlada(date,uuid)', 'ecf4d041cef8c5495e75fa87d46fecb1', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public._actua_como_transportista(uuid,bigint)', '42e2ceb259312bf20ba1145f1ff7ee75', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.aplicar_orden_ruta(uuid,jsonb,numeric,integer,jsonb,date)', '8023195a7078920efc376f2ed675c125', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.marcar_entregas_masivo(bigint[],uuid,date)', '9501a8cfdd48587000d3432751354141', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)', '095d9998f7b254e9cdfd2a16b04ec57c', true,
     '{postgres=X/postgres,service_role=X/postgres}')
  ) AS t(f, h, def, acl) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO x
      FROM pg_proc WHERE oid = r.f::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %)', r.f, x.h, x.a, x.def;
    END IF;
  END LOOP;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.pedidos'::regclass AND conname = 'pedidos_entregado_con_fecha'
                    AND contype = 'c' AND NOT convalidated
                    AND pg_get_constraintdef(oid) = 'CHECK (((estado <> ''entregado''::text) OR (fecha_entrega IS NOT NULL))) NOT VALID') THEN
    RAISE EXCEPTION 'mig NNN · pedidos_entregado_con_fecha no quedó como se esperaba: %',
      (SELECT pg_get_constraintdef(oid) FROM pg_constraint
        WHERE conrelid = 'public.pedidos'::regclass AND conname = 'pedidos_entregado_con_fecha');
  END IF;
END
$post$;

COMMIT;
