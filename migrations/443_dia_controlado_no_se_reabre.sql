-- 443 · Un día controlado no se reabre como efecto secundario (#1342).
--
-- QUÉ PASABA
--   La 416b (#1318) cerró que las masivas reabrieran un día controlado. Quedaban dos
--   puertas por las que trg_pedidos_anular_control borraba un control confirmado con su
--   foto, sin que nadie lo pidiera:
--   · La entrega suelta por REST de admin y encargado. pedidos_proteger_columnas los
--     dejaba salir antes del bloque que protege los controles cerrados. Pasaba al
--     entregar (continuarEntrega y la entrega con cobro), al revertir una entrega y al
--     corregir la fecha de entrega en la edición.
--   · La carrera de las masivas. Miraban control_rendicion_cerrado antes del UPDATE sin
--     tomar la rendición: si se confirmaba en el medio, el trigger la borraba igual.
--   La entrega suelta tenía la misma carrera, entre el trigger BEFORE y el AFTER.
--
-- QUÉ CAMBIA
--   · pedidos_proteger_columnas: el bloque de los controles cerrados corre para todo
--     cambio por REST, también de admin y encargado. Reabrir un día es a propósito,
--     desde la rendición. La rama del vendedor no cambia (la saca #1383).
--     Si el cambio toca un día, anota el pedido en app.pedidos_por_rest para el AFTER.
--   · anular_control_por_cambio_fecha_entrega: para un pedido anotado, antes de borrar
--     toma la rendición COMPARTIDA con pg_try_advisory_xact_lock_shared y vuelve a mirar el
--     control. Si alguien la tiene exclusiva (se está confirmando, o se le carga un gasto),
--     40001; si ya quedó controlada, 42501. El try nunca espera: el pedido ya está
--     bloqueado, y esperar la rendición después del pedido invertiría el orden de
--     confirmar_rendicion. Lo que llega del server (DEFINER) borra como antes.
--   · Las dos masivas toman COMPARTIDAS las rendiciones que tocan, ordenadas, ANTES de
--     bloquear los pedidos: es el orden de confirmar_rendicion (la rendición y después
--     pagos y pedidos) y el de la 439 (pedidos por id, recorridos por id, pagos).
--     Con los pedidos quietos vuelven a mirar: el control, y que ningún pedido haya
--     cambiado de chofer o de día mientras tanto (si cambió, 40001: tomar su rendición
--     recién ahí invertiría el orden).
--   · Compartida y no exclusiva: entregar contra entregar no se excluye (lo ordenan los
--     locks de pedidos), y una entrega por REST del mismo chofer y día no choca con una
--     masiva ni con otra entrega. Lo que se excluye es entregar contra los que la toman
--     exclusiva (_rendicion_bloquear): confirmar, resolver, reabrir y los gastos y pagos
--     al personal de la rendición.
--   · desmarcar_rendicion_controlada, el botón "Reabrir control" de Rendiciones, toma la
--     rendición antes de borrar el control, como confirmar_rendicion.
--
-- QUÉ NO CAMBIA
--   Las firmas, los EXECUTE, SECURITY DEFINER/INVOKER, los filtros de las masivas y lo que
--   borra el trigger para las RPCs del server.
--
-- Ensayo: scripts/test-dia-controlado-1342.sql, y C9 del arnés (scripts/concurrencia).
-- Aplicar desde el contenido LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

DO $premisas$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('public.pedidos_proteger_columnas()', 'd8dbd660961962efbb13828d330f0154'),
      ('public.anular_control_por_cambio_fecha_entrega()', 'cbe9e31fcd6894b07fd276c229481837'),
      ('public.marcar_entregas_masivo(bigint[],uuid,date)', 'd89d94fb3d9d93812bca2e7d05b25d65'),
      ('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)', 'f734cbdd5a8b12b7f66da9e5a60c9a9f'),
      ('public.desmarcar_rendicion_controlada(date,uuid)', '7d242da01d8d4297eaf503bdbc757eca')
    ) AS t(firma, hash)
  LOOP
    IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = r.firma::regprocedure) <> r.hash THEN
      RAISE EXCEPTION '% cambió en prod (md5 %): rehacer el parche sobre el cuerpo vigente',
        r.firma, (SELECT md5(prosrc) FROM pg_proc WHERE oid = r.firma::regprocedure);
    END IF;
  END LOOP;
END
$premisas$;

CREATE OR REPLACE FUNCTION public.pedidos_proteger_columnas()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_bloqueadas text;
BEGIN
  IF current_user <> 'authenticated' THEN
    RETURN NEW;
  END IF;

  IF pg_trigger_depth() > 1 THEN
    RETURN NEW;
  END IF;

  -- #1342: ningún cambio por REST borra un control cerrado, tampoco el de admin o
  -- encargado. Reabrir un día es a propósito, desde la rendición. Espeja las DOS
  -- condiciones de anular_control_por_cambio_fecha_entrega (mismo día argentino,
  -- misma sesión): si cambia una, cambiá la otra. El server (DEFINER) no pasa por
  -- acá y sigue borrando por diseño. Un cambio de ESTADO de una baja lo rechaza
  -- pedidos_guard_baja (corre después, por orden alfabético) con su propio
  -- mensaje: acá no se toca, para no taparlo.
  IF TG_OP = 'UPDATE'
     AND NOT (OLD.estado IN ('cancelado','anulado') AND NEW.estado IS DISTINCT FROM OLD.estado) THEN
    -- (1) Una baja no cambia la fecha de entrega (sólo admin y encargado la corrigen).
    -- Va antes que el control, como antes de #1342: su mensaje es el que corresponde.
    IF OLD.estado IN ('cancelado','anulado')
       AND NEW.fecha_entrega IS DISTINCT FROM OLD.fecha_entrega
       AND NOT es_encargado_o_admin() THEN
      RAISE EXCEPTION 'El pedido #% está %: su fecha de entrega no se cambia. Si hay que corregirla, pedíselo a un encargado o administrador.',
        OLD.id, OLD.estado USING ERRCODE = '42501';
    END IF;
    -- (2) El control cerrado.
    IF OLD.fecha_entrega IS NOT NULL AND OLD.transportista_id IS NOT NULL
       AND (NEW.fecha_entrega IS NULL
            OR (OLD.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date IS DISTINCT FROM (NEW.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
            OR (NEW.estado = 'cancelado' AND OLD.estado = 'entregado')
            OR OLD.transportista_id IS DISTINCT FROM NEW.transportista_id) THEN
      IF public.control_rendicion_cerrado(OLD.transportista_id, OLD.sucursal_id, (OLD.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date) THEN
        RAISE EXCEPTION 'La rendición del % de ese transportista ya fue controlada: este cambio la reabriría. Un encargado o administrador tiene que reabrirla primero desde Rendiciones.',
          to_char((OLD.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date, 'DD/MM/YYYY') USING ERRCODE = '42501';
      END IF;
      -- Para el AFTER, que vuelve a mirar con la rendición tomada (la carrera con
      -- una confirmación). Una lista de ids: un PATCH puede tocar varias filas.
      PERFORM set_config('app.pedidos_por_rest',
                         COALESCE(current_setting('app.pedidos_por_rest', true), '') || ',' || OLD.id || ',', true);
    END IF;
    IF NEW.fecha_entrega IS NOT NULL AND NEW.transportista_id IS NOT NULL AND NEW.estado = 'entregado'
       AND (OLD.fecha_entrega IS NULL
            OR (OLD.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date IS DISTINCT FROM (NEW.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
            OR OLD.transportista_id IS DISTINCT FROM NEW.transportista_id) THEN
      IF public.control_rendicion_cerrado(NEW.transportista_id, NEW.sucursal_id, (NEW.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date) THEN
        RAISE EXCEPTION 'La rendición del % de ese transportista ya fue controlada: este cambio la reabriría. Un encargado o administrador tiene que reabrirla primero desde Rendiciones.',
          to_char((NEW.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date, 'DD/MM/YYYY') USING ERRCODE = '42501';
      END IF;
      PERFORM set_config('app.pedidos_por_rest',
                         COALESCE(current_setting('app.pedidos_por_rest', true), '') || ',' || NEW.id || ',', true);
    END IF;
  END IF;

  IF es_encargado_o_admin() THEN
    RETURN NEW;
  END IF;

  -- ---- Alta: la venta es de quien la carga (mig 219, issue #549) ----------
  IF TG_OP = 'INSERT' THEN
    IF NEW.usuario_id IS NOT NULL AND NEW.usuario_id IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION
        'Un pedido se atribuye a quien lo carga: no podés crear uno a nombre de otro usuario (usuario_id %). Solo un administrador o encargado puede hacerlo.',
        NEW.usuario_id
        USING ERRCODE = '42501';
    END IF;

    -- Mig 233 (a): `creado_por` es la autoría de la CARGA. Misma regla.
    IF NEW.creado_por IS NOT NULL AND NEW.creado_por IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION
        'No podés registrar un pedido como cargado por otro usuario (creado_por %). Solo un administrador o encargado puede hacerlo.',
        NEW.creado_por
        USING ERRCODE = '42501';
    END IF;

    -- Mig 233 (b): se ASIGNA, no se rechaza (molde de pagos_forzar_usuario, 190b).
    IF NEW.usuario_id IS NULL THEN
      NEW.usuario_id := auth.uid();
    END IF;

    RETURN NEW;
  END IF;

  -- ---- De acá abajo es UPDATE (usa OLD) ----------------------------------

  -- #1317: el estado, el chofer y la fecha de entrega. El GRANT UPDATE de esas
  -- columnas es de authenticated entero (el chofer las escribe por REST): quién
  -- cambia qué lo decide esto. Admin y encargado salieron arriba, y el server
  -- (DEFINER) no llega acá. El cambio de estado de una baja lo rechaza
  -- pedidos_guard_baja con su propio mensaje, como en el bloque de arriba.
  IF NOT (OLD.estado IN ('cancelado','anulado') AND NEW.estado IS DISTINCT FROM OLD.estado)
     AND (NEW.estado IS DISTINCT FROM OLD.estado
          OR NEW.transportista_id IS DISTINCT FROM OLD.transportista_id
          OR NEW.fecha_entrega IS DISTINCT FROM OLD.fecha_entrega) THEN
    IF es_transportista()
       AND OLD.transportista_id = auth.uid()
       AND NEW.transportista_id IS NOT DISTINCT FROM OLD.transportista_id
       AND NEW.estado = 'entregado' THEN
      -- El chofer del pedido lo entrega, o corrige el día de su entrega. Vale
      -- también para el preventista con rol de chofer en su propio pedido.
      NULL;
    ELSIF OLD.usuario_id = auth.uid()
          AND OLD.estado IN ('pendiente', 'en_preparacion', 'asignado')
          AND NEW.estado = 'pendiente'
          AND NEW.transportista_id IS NULL
          AND NEW.fecha_entrega IS NOT DISTINCT FROM OLD.fecha_entrega THEN
      -- El vendedor saca de la ruta su pedido no entregado: es lo que hace la
      -- edición cuando le cambia la fecha a un pedido en camino. No mueve
      -- stock ni plata.
      NULL;
    ELSE
      RAISE EXCEPTION 'El estado, el chofer y la fecha de entrega del pedido #% los cambia su chofer al entregarlo, o un encargado o administrador.',
        OLD.id USING ERRCODE = '42501';
    END IF;
  END IF;

  -- #1170: la rama del chofer es para los pedidos a los que llega SÓLO como
  -- chofer. es_transportista() da true por el rol extra (trampa 4): en un
  -- pedido propio rige la regla del vendedor, como para cualquier preventista.
  IF es_transportista() AND OLD.usuario_id IS DISTINCT FROM auth.uid() THEN
    SELECT string_agg(o.key, ', ' ORDER BY o.key) INTO v_bloqueadas
    FROM jsonb_each(to_jsonb(OLD)) o
    JOIN jsonb_each(to_jsonb(NEW)) n ON n.key = o.key
    WHERE o.value IS DISTINCT FROM n.value
      AND o.key NOT IN ('estado', 'fecha_entrega', 'updated_at');

    IF v_bloqueadas IS NOT NULL THEN
      RAISE EXCEPTION 'Un transportista solo puede confirmar la entrega. Columnas rechazadas: %',
        v_bloqueadas
        USING ERRCODE = '42501';
    END IF;

    IF NEW.estado IS DISTINCT FROM OLD.estado AND NEW.estado <> 'entregado' THEN
      RAISE EXCEPTION 'Un transportista solo puede marcar la entrega, no pasar el pedido a "%"',
        NEW.estado
        USING ERRCODE = '42501';
    END IF;

    RETURN NEW;
  END IF;

  -- #1155: 'fecha' (la del pedido, no la de entrega) sólo la cambian admin y
  -- encargado: la venta por vendedor y la comisión se atribuyen por ella
  -- (migs 241/318), y la vigencia de la promo en la edición también (#1137).
  SELECT string_agg(o.key, ', ' ORDER BY o.key) INTO v_bloqueadas
  FROM jsonb_each(to_jsonb(OLD)) o
  JOIN jsonb_each(to_jsonb(NEW)) n ON n.key = o.key
  WHERE o.value IS DISTINCT FROM n.value
    AND o.key IN (
      'total', 'total_neto', 'total_iva', 'total_real', 'cargo_envio', 'cargo_envio_estado', 'monto_pagado',
      'estado_pago', 'cliente_id', 'sucursal_id', 'usuario_id', 'creado_por',
      'preventista_id', 'tipo_factura', 'stock_descontado', 'offline_id',
      'fecha'
    );

  IF v_bloqueadas IS NOT NULL THEN
    RAISE EXCEPTION 'No tenes permiso para modificar estas columnas de pedidos: %',
      v_bloqueadas
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.anular_control_por_cambio_fecha_entrega()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  -- #1342: lo anota pedidos_proteger_columnas cuando el cambio viene por REST.
  v_rest boolean := position(',' || NEW.id || ',' in COALESCE(current_setting('app.pedidos_por_rest', true), '')) > 0;
  v_dia  date;
BEGIN
  -- #1298: el control es del día argentino de la entrega; ::date sobre el
  -- timestamptz cortaba en UTC (de 21 a 24 caía en el día siguiente). Espejo
  -- del bloque de controles de pedidos_proteger_columnas: si cambia uno, el otro.
  IF OLD.fecha_entrega IS NOT NULL
     AND OLD.transportista_id IS NOT NULL
     AND (
       NEW.fecha_entrega IS NULL
       OR (OLD.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date IS DISTINCT FROM (NEW.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
       OR (NEW.estado = 'cancelado' AND OLD.estado = 'entregado')
       OR OLD.transportista_id IS DISTINCT FROM NEW.transportista_id
     ) THEN
    v_dia := (OLD.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
    -- #1342: el BEFORE ya rechazó el control que veía. Si se confirmó después, la
    -- rendición la tiene confirmar_rendicion (exclusiva) o ya está en
    -- rendiciones_control. Compartida: no choca con otra entrega ni con una masiva,
    -- que también la toman compartida. El try no espera: el pedido ya está tomado, y
    -- esperar la rendición después invertiría el orden de confirmar_rendicion y de
    -- las masivas. Los estados son los de control_rendicion_cerrado.
    IF v_rest THEN
      IF NOT pg_try_advisory_xact_lock_shared(public._rendicion_clave(OLD.transportista_id, v_dia, OLD.sucursal_id)) THEN
        RAISE EXCEPTION 'La rendición del % de ese transportista se está controlando o editando en este momento: volvé a intentar en unos segundos.',
          to_char(v_dia, 'DD/MM/YYYY') USING ERRCODE = '40001';
      END IF;
      IF EXISTS (SELECT 1 FROM rendiciones_control
                  WHERE transportista_id = OLD.transportista_id AND sucursal_id = OLD.sucursal_id
                    AND fecha = v_dia AND estado IN ('confirmada', 'resuelta')) THEN
        RAISE EXCEPTION 'La rendición del % de ese transportista ya fue controlada: este cambio la reabriría. Un encargado o administrador tiene que reabrirla primero desde Rendiciones.',
          to_char(v_dia, 'DD/MM/YYYY') USING ERRCODE = '42501';
      END IF;
    END IF;
    DELETE FROM rendiciones_control
    WHERE transportista_id = OLD.transportista_id
      AND sucursal_id = OLD.sucursal_id
      AND fecha = v_dia;
  END IF;

  IF NEW.fecha_entrega IS NOT NULL
     AND NEW.transportista_id IS NOT NULL
     AND NEW.estado = 'entregado'
     AND (
       OLD.fecha_entrega IS NULL
       OR (OLD.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date IS DISTINCT FROM (NEW.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
       OR OLD.transportista_id IS DISTINCT FROM NEW.transportista_id
     ) THEN
    v_dia := (NEW.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
    IF v_rest THEN
      IF NOT pg_try_advisory_xact_lock_shared(public._rendicion_clave(NEW.transportista_id, v_dia, NEW.sucursal_id)) THEN
        RAISE EXCEPTION 'La rendición del % de ese transportista se está controlando o editando en este momento: volvé a intentar en unos segundos.',
          to_char(v_dia, 'DD/MM/YYYY') USING ERRCODE = '40001';
      END IF;
      IF EXISTS (SELECT 1 FROM rendiciones_control
                  WHERE transportista_id = NEW.transportista_id AND sucursal_id = NEW.sucursal_id
                    AND fecha = v_dia AND estado IN ('confirmada', 'resuelta')) THEN
        RAISE EXCEPTION 'La rendición del % de ese transportista ya fue controlada: este cambio la reabriría. Un encargado o administrador tiene que reabrirla primero desde Rendiciones.',
          to_char(v_dia, 'DD/MM/YYYY') USING ERRCODE = '42501';
      END IF;
    END IF;
    DELETE FROM rendiciones_control
    WHERE transportista_id = NEW.transportista_id
      AND sucursal_id = NEW.sucursal_id
      AND fecha = v_dia;
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.marcar_entregas_masivo(p_pedido_ids bigint[], p_transportista_id uuid, p_fecha date DEFAULT ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires'::text))::date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal_id BIGINT;
  v_affected INTEGER;
  v_fecha_ts TIMESTAMPTZ;
  v_claves bigint[]; -- #1342
  v_clave bigint;
  v_par RECORD;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Solo encargado o admin pueden marcar entregas masivas'
      USING ERRCODE = '42501';
  END IF;

  IF p_pedido_ids IS NULL OR array_length(p_pedido_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;

  -- #1318 (REN-1): entregar con la fecha de un día ya controlado reabría ese
  -- control como efecto secundario (trg_pedidos_anular_control lo borra con su
  -- foto). Un día cerrado se reabre a propósito, desde la rendición. Mira los
  -- dos lados que borra el trigger: el día nuevo del chofer nuevo, y el día que
  -- ya tuviera anotado el pedido.
  -- #1342: las rendiciones que toca, antes que los pedidos: es el orden de
  -- confirmar_rendicion (la rendición, y después pagos y pedidos). Compartidas: la
  -- confirmación las toma exclusivas y espera, pero otra entrega del mismo chofer y
  -- día no. Ordenadas, como _rendicion_bloquear. El chequeo va más abajo, con todo
  -- tomado: mirado antes, una confirmación que entraba en el medio se borraba igual
  -- por el trigger.
  v_claves := ARRAY(
    SELECT public._rendicion_clave(x.chofer, x.dia, v_sucursal_id)
      FROM (SELECT p_transportista_id AS chofer, p_fecha AS dia
            UNION ALL
            SELECT p.transportista_id, (p.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
              FROM pedidos p
             WHERE p.id = ANY(p_pedido_ids)
               AND p.sucursal_id = v_sucursal_id
               AND COALESCE(p.estado, '') NOT IN ('entregado', 'cancelado', 'anulado')
               AND COALESCE(p.tipo_factura, 'ZZ') <> 'VB'
               AND p.canal IS DISTINCT FROM 'cambio'
               AND p.fecha_entrega IS NOT NULL) x
     WHERE x.chofer IS NOT NULL);
  FOR v_clave IN SELECT DISTINCT c FROM unnest(v_claves) AS c WHERE c IS NOT NULL ORDER BY c LOOP
    PERFORM pg_advisory_xact_lock_shared(v_clave);
  END LOOP;

  v_fecha_ts := (p_fecha::text || ' 12:00:00 America/Argentina/Buenos_Aires')::timestamptz;

  -- #1375: el orden de aplicar_orden_ruta, pedidos por id y después recorridos
  -- por id. Sin esto el UPDATE sigue el orden físico y los triggers por fila
  -- toman las rutas en el orden de sus filas.
  PERFORM 1
     FROM pedidos
    WHERE id = ANY(p_pedido_ids)
      AND sucursal_id = v_sucursal_id
    ORDER BY id
      FOR NO KEY UPDATE;

  PERFORM 1
     FROM recorridos
    WHERE id IN (SELECT rp.recorrido_id
                   FROM recorrido_pedidos rp
                  WHERE rp.pedido_id = ANY(p_pedido_ids))
    ORDER BY id
      FOR NO KEY UPDATE;

  -- #1342: con las rendiciones y los pedidos tomados. Si un pedido cambió de
  -- chofer o de día desde que se tomaron, la suya no está tomada, y tomarla ahora
  -- invertiría el orden: se rechaza para que se vuelva a intentar.
  FOR v_par IN
    SELECT x.chofer, x.dia
      FROM (SELECT p_transportista_id AS chofer, p_fecha AS dia
            UNION ALL
            SELECT p.transportista_id, (p.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
              FROM pedidos p
             WHERE p.id = ANY(p_pedido_ids)
               AND p.sucursal_id = v_sucursal_id
               AND COALESCE(p.estado, '') NOT IN ('entregado', 'cancelado', 'anulado')
               AND COALESCE(p.tipo_factura, 'ZZ') <> 'VB'
               AND p.canal IS DISTINCT FROM 'cambio'
               AND p.fecha_entrega IS NOT NULL) x
     WHERE x.chofer IS NOT NULL
  LOOP
    IF public._rendicion_clave(v_par.chofer, v_par.dia, v_sucursal_id) <> ALL (v_claves) THEN
      RAISE EXCEPTION 'Un pedido cambió de chofer o de fecha mientras se entregaba: volvé a intentar.'
        USING ERRCODE = '40001';
    END IF;
    IF public.control_rendicion_cerrado(v_par.chofer, v_sucursal_id, v_par.dia) THEN
      RAISE EXCEPTION 'La rendición del % de % ya fue controlada: esta entrega la reabriría. Elegí otra fecha, o reabrí primero el control de ese día.',
        to_char(v_par.dia, 'DD/MM/YYYY'),
        COALESCE((SELECT nombre FROM perfiles WHERE id = v_par.chofer), 'ese chofer')
        USING ERRCODE = '42501';
    END IF;
  END LOOP;

  UPDATE pedidos
     SET estado = 'entregado',
         fecha_entrega = v_fecha_ts,
         transportista_id = p_transportista_id,
         updated_at = now()
   WHERE id = ANY(p_pedido_ids)
     AND sucursal_id = v_sucursal_id
     -- mig 181: el unico guard vivia en el filtro de la query del front, y la
     -- ventana es todo el tiempo que el modal queda abierto (sin realtime sobre
     -- pedidos ni revalidacion al confirmar).
     AND COALESCE(estado, '') NOT IN ('entregado', 'cancelado', 'anulado')
     AND COALESCE(tipo_factura, 'ZZ') <> 'VB'  -- mig 3XA
     -- #1318: la comanda de un canje se entrega desde el pedido, que aplica el
     -- cambio (aplicar_cambio_de_parada) antes de cerrarla.
     AND canal IS DISTINCT FROM 'cambio';

  GET DIAGNOSTICS v_affected = ROW_COUNT;
  RETURN v_affected;
END;
$function$;

CREATE OR REPLACE FUNCTION public.marcar_entrega_y_pago_masivo_impl(p_pedido_ids bigint[], p_transportista_id uuid, p_forma_pago text, p_fecha date DEFAULT ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires'::text))::date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal_id BIGINT;
  v_affected INTEGER;
  v_pedido RECORD;
  v_rol TEXT;
  v_fecha_ts TIMESTAMPTZ;
  v_claves bigint[]; -- #1342
  v_clave bigint;
  v_par RECORD;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Solo encargado o admin pueden marcar entrega y pago masivos'
      USING ERRCODE = '42501';
  END IF;

  -- #1249: antes no se validaba; ademas escribe pedidos.forma_pago.
  p_forma_pago := public._forma_pago_de_cobro(p_forma_pago, true);

  -- Mismo gate de rendición que marcar_pagos_masivo (esta RPC registra pagos)
  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();
  IF v_rol = 'encargado' THEN
    -- mig 230: la base corre en UTC. Comparar contra CURRENT_DATE entre las
    -- 21:00 y las 24:00 ART rechazaba justo la fecha correcta.
    IF p_fecha <> (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date THEN
      RAISE EXCEPTION 'Encargado solo puede registrar pagos con fecha de hoy'
        USING ERRCODE = '42501';
    END IF;
    IF public.rendicion_dia_cerrada(p_fecha, v_sucursal_id) THEN
      RAISE EXCEPTION 'Rendicion ya cerrada para esta fecha. Pedi a un admin.'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  IF p_pedido_ids IS NULL OR array_length(p_pedido_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;

  -- #1318 (REN-1): el mismo corte que marcar_entregas_masivo. Va antes del
  -- cobro: si la entrega no entra, el cobro tampoco.
  -- #1342: las rendiciones que toca, antes que los pedidos: es el orden de
  -- confirmar_rendicion (la rendición, y después pagos y pedidos). Compartidas: la
  -- confirmación las toma exclusivas y espera, pero otra entrega del mismo chofer y
  -- día no. Ordenadas, como _rendicion_bloquear. El chequeo va más abajo, con todo
  -- tomado: mirado antes, una confirmación que entraba en el medio se borraba igual
  -- por el trigger.
  v_claves := ARRAY(
    SELECT public._rendicion_clave(x.chofer, x.dia, v_sucursal_id)
      FROM (SELECT p_transportista_id AS chofer, p_fecha AS dia
            UNION ALL
            SELECT p.transportista_id, (p.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
              FROM pedidos p
             WHERE p.id = ANY(p_pedido_ids)
               AND p.sucursal_id = v_sucursal_id
               AND COALESCE(p.estado, '') NOT IN ('entregado', 'cancelado', 'anulado')
               AND COALESCE(p.tipo_factura, 'ZZ') <> 'VB'
               AND p.canal IS DISTINCT FROM 'cambio'
               AND p.fecha_entrega IS NOT NULL) x
     WHERE x.chofer IS NOT NULL);
  FOR v_clave IN SELECT DISTINCT c FROM unnest(v_claves) AS c WHERE c IS NOT NULL ORDER BY c LOOP
    PERFORM pg_advisory_xact_lock_shared(v_clave);
  END LOOP;

  v_fecha_ts := (p_fecha::text || ' 12:00:00 America/Argentina/Buenos_Aires')::timestamptz;

  -- #1375: el orden de aplicar_orden_ruta, pedidos por id y después recorridos
  -- por id, antes del primer pago: cada INSERT llega a la ruta por el trigger de
  -- monto_pagado, y el FOR UPDATE del bucle no alcanza a los que ya estan pagados,
  -- que el UPDATE de abajo tambien toca. Va FOR UPDATE, el del bucle: tomar uno
  -- menor y subirlo despues puede cruzarse con una FK.
  PERFORM 1
     FROM pedidos
    WHERE id = ANY(p_pedido_ids)
      AND sucursal_id = v_sucursal_id
    ORDER BY id
      FOR UPDATE;

  PERFORM 1
     FROM recorridos
    WHERE id IN (SELECT rp.recorrido_id
                   FROM recorrido_pedidos rp
                  WHERE rp.pedido_id = ANY(p_pedido_ids))
    ORDER BY id
      FOR NO KEY UPDATE;

  -- #1342: con las rendiciones y los pedidos tomados. Si un pedido cambió de
  -- chofer o de día desde que se tomaron, la suya no está tomada, y tomarla ahora
  -- invertiría el orden: se rechaza para que se vuelva a intentar.
  FOR v_par IN
    SELECT x.chofer, x.dia
      FROM (SELECT p_transportista_id AS chofer, p_fecha AS dia
            UNION ALL
            SELECT p.transportista_id, (p.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
              FROM pedidos p
             WHERE p.id = ANY(p_pedido_ids)
               AND p.sucursal_id = v_sucursal_id
               AND COALESCE(p.estado, '') NOT IN ('entregado', 'cancelado', 'anulado')
               AND COALESCE(p.tipo_factura, 'ZZ') <> 'VB'
               AND p.canal IS DISTINCT FROM 'cambio'
               AND p.fecha_entrega IS NOT NULL) x
     WHERE x.chofer IS NOT NULL
  LOOP
    IF public._rendicion_clave(v_par.chofer, v_par.dia, v_sucursal_id) <> ALL (v_claves) THEN
      RAISE EXCEPTION 'Un pedido cambió de chofer o de fecha mientras se entregaba: volvé a intentar.'
        USING ERRCODE = '40001';
    END IF;
    IF public.control_rendicion_cerrado(v_par.chofer, v_sucursal_id, v_par.dia) THEN
      RAISE EXCEPTION 'La rendición del % de % ya fue controlada: esta entrega la reabriría. Elegí otra fecha, o reabrí primero el control de ese día.',
        to_char(v_par.dia, 'DD/MM/YYYY'),
        COALESCE((SELECT nombre FROM perfiles WHERE id = v_par.chofer), 'ese chofer')
        USING ERRCODE = '42501';
    END IF;
  END LOOP;

  -- 1) Registrar pago por el saldo pendiente (solo pedidos NO pagados)
  FOR v_pedido IN
    SELECT id, cliente_id, total, COALESCE(monto_pagado, 0) AS ya_pagado
    FROM pedidos
    WHERE id = ANY(p_pedido_ids)
      AND sucursal_id = v_sucursal_id
      AND COALESCE(estado_pago, 'pendiente') <> 'pagado'
      -- #1318 (PED-3): un entregado no se vuelve a entregar, como en la 181.
      AND COALESCE(estado, '') NOT IN ('entregado', 'cancelado', 'anulado')
      AND canal IS DISTINCT FROM 'cambio'
      AND total > COALESCE(monto_pagado, 0)
      AND COALESCE(tipo_factura, 'ZZ') <> 'VB'  -- mig 3XA
    ORDER BY id
    FOR UPDATE
  LOOP
    INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id)
    VALUES (
      v_pedido.cliente_id,
      v_pedido.id,
      v_pedido.total - v_pedido.ya_pagado,
      p_forma_pago,
      p_fecha,
      auth.uid(),
      v_sucursal_id
    );
  END LOOP;

  -- 2) Entregar + saldar en un solo UPDATE (transportista_id SE asigna)
  -- mig 181: no revivir un pedido cancelado como entregado y pagado.
  UPDATE pedidos
     SET estado = 'entregado',
         fecha_entrega = v_fecha_ts,
         transportista_id = p_transportista_id,
         -- mig 230: ya NO se escribe monto_pagado = total, igual que la 181 en
         -- marcar_pagos_masivo_impl. El INSERT en pagos de arriba dispara
         -- recalcular_monto_pagado_pedido, que lo deriva de SUM(pagos). Este
         -- UPDATE alcanza a TODOS los ids del lote -- tambien los que el bucle
         -- salteo por ya estar pagados -- asi que fijarlo a mano tapaba un
         -- cobro concurrente y dejaba el pedido saldado con dos pagos encima.
         forma_pago = p_forma_pago,
         updated_at = now()
   WHERE id = ANY(p_pedido_ids)
     AND sucursal_id = v_sucursal_id
     -- #1318 (PED-3): un entregado no se vuelve a entregar: le pisaba el
     -- chofer y la fecha, y el trigger le borraba el control del día viejo.
     AND COALESCE(estado, '') NOT IN ('entregado', 'cancelado', 'anulado')
     AND COALESCE(tipo_factura, 'ZZ') <> 'VB'  -- mig 3XA
     -- #1318: la comanda de un canje se entrega desde el pedido, que aplica el
     -- cambio (aplicar_cambio_de_parada) antes de cerrarla.
     AND canal IS DISTINCT FROM 'cambio';

  GET DIAGNOSTICS v_affected = ROW_COUNT;
  RETURN v_affected;
END;
$function$;


CREATE OR REPLACE FUNCTION public.desmarcar_rendicion_controlada(p_fecha date, p_transportista_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
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

  -- #1328: la misma regla que confirmar_rendicion.
  IF p_transportista_id = auth.uid() AND NOT es_admin() THEN
    RAISE EXCEPTION 'Tu rendición la reabre otro encargado o un admin'
      USING ERRCODE = '42501';
  END IF;

  -- #1342: es el camino a propósito para reabrir un día (el botón de Rendiciones).
  -- La rendición antes que el control, como confirmar_rendicion: sin el lock,
  -- reabrir mientras otro la confirma podía dejar la confirmación en pie.
  PERFORM public._rendicion_bloquear(ARRAY[public._rendicion_clave(p_transportista_id, p_fecha, v_sucursal_id)]);

  DELETE FROM rendiciones_control
  WHERE fecha = p_fecha
    AND transportista_id = p_transportista_id
    AND sucursal_id = v_sucursal_id;
END;
$function$;

COMMIT;
