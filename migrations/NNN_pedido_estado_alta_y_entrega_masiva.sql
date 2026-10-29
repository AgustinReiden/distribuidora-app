-- ============================================================================
-- NNN · Pedido: alta, estado y entrega masiva (#1317, #1318, #1319)
-- ============================================================================
-- Tarjeta 4 del plan #1308 (auditoría de los módulos operativos del 29/10).
-- Aplicar desde el contenido LF.
--
-- QUÉ ES ESTO
-- -----------
-- #1317 · PED-1. `authenticated` tiene UPDATE (estado, transportista_id,
--   fecha_entrega, ...) sobre `pedidos`, y la policy deja pasar al vendedor por
--   `usuario_id = auth.uid()`. Por REST un preventista marcaba entregado su
--   pedido con cualquier chofer, o lo volvía de entregado a pendiente para
--   editarlo a la baja y devolver al stock lo que ya tenía el cliente.
--   `pedidos_proteger_columnas` ahora decide quién cambia esas tres columnas:
--     · el chofer del pedido lo pasa a entregado y fija o corrige el día de la
--       entrega, sin cambiar el chofer (488 de las 493 transiciones de quienes
--       no son admin ni encargado desde junio: preventistas con rol de chofer
--       que entregan su propio pedido);
--     · el vendedor puede devolver su pedido no entregado a pendiente y sin
--       chofer, que es lo que hace la edición cuando le cambia la fecha a un
--       pedido en camino (`handleGuardarEdicion`);
--     · cualquier otro cambio, 42501. De entregado sólo vuelven el admin y el
--       encargado, que salen antes del guard, igual que el server: una RPC
--       DEFINER corre como su dueño y no llega acá (`current_user`).
--   El GRANT UPDATE por columna se queda: el chofer escribe estado y
--   fecha_entrega por REST, y el admin y el encargado también el chofer. El
--   filtro por rol lo hace el trigger. El gate es la clasificación de las
--   columnas de `pedidos` en scripts/check-grants-tablas.mjs y el ensayo.
--
-- #1318 · PED-3, REN-1 y la entrega de PED-5.
--   · `marcar_entrega_y_pago_masivo_impl` no excluía los entregados (su gemela
--     sí, desde la 181): volvía a entregar un pedido ya entregado con otro
--     chofer y otra fecha, y el trigger le borraba el control del día viejo.
--     Ahora los saltea, en el cobro y en la entrega. El front ya los manda al
--     cobro masivo, no acá.
--   · Ninguna de las dos masivas entrega con la fecha de un día ya controlado:
--     lo rechaza. Antes reabría el control sin avisar, y
--     `ultima_fecha_caja_cerrada` podía bajar. Un día cerrado se reabre a
--     propósito, desde la rendición.
--   · Las dos saltean la comanda de un canje (`canal = 'cambio'`): entregarla
--     en masa la cerraba sin aplicar el cambio. Se entrega desde el pedido, que
--     llama a `aplicar_cambio_de_parada` antes.
--
-- #1319 · PED-4, PED-8 y PED-7.
--   · Decisión del dueño (29/10): para quien no es admin, la fecha del pedido
--     no pasa de hoy (`_tablero_hoy()`); lo futuro va en la entrega
--     programada. Una fecha pasada sigue entrando, por la cola offline.
--     `crear_pedido_completo_bot` ya carga siempre con la fecha de hoy.
--   · El alta (`crear_pedido_completo` y el bot), la visita y el canje
--     rechazan a un cliente dado de baja. El alta lo devuelve como
--     `success: false`, que la cola offline toma como rechazo definitivo y
--     muestra, sin reintentarlo.
--   · `pedido_historial` registra el cambio de `fecha` (antes y después, y
--     quién).
--
-- #1298 (pedido de #1306, con el OK del dueño del 29/10) · el día de la
--   entrega. `pedidos_proteger_columnas` y `anular_control_por_cambio_fecha_entrega`
--   cortaban `fecha_entrega::date`, que es el día en UTC: una entrega cargada
--   entre las 21 y las 24 de Argentina caía en el control del día siguiente.
--   Pasan al día argentino, `(fecha_entrega AT TIME ZONE
--   'America/Argentina/Buenos_Aires')::date`, la misma expresión que
--   `es_entrega_del_dia` y `_rendicion_entregas` (tarjeta 2 de #1306), y la que
--   usan las masivas de acá.
--
-- QUÉ SE TOCA
-- -----------
-- Parcheadas por ancla sobre el cuerpo vivo, con md5 verificado abajo:
--   pedidos_proteger_columnas, anular_control_por_cambio_fecha_entrega,
--   registrar_cambio_pedido, crear_pedido_completo,
--   crear_pedido_completo_bot, registrar_visita_cliente,
--   registrar_cambio_producto, marcar_entregas_masivo,
--   marcar_entrega_y_pago_masivo_impl.
-- No se tocan: `crear_pedido_idempotente` (el wrapper pasa el success=false
-- tal cual), `marcar_entrega_y_pago_masivo` (el wrapper de idempotencia de la
-- 167), `_aplicar_cambio_producto` (#1329), `auditoria_integridad()` (tarjeta
-- 8) ni los grants. Ninguna cambia de firma: CREATE OR REPLACE conserva dueño,
-- SECURITY DEFINER, search_path y ACL (lo verifica el paso final).
--
-- Ensayo: scripts/test-pedido-estado-alta-entrega-1317-1319.sql.
--
-- ROLLBACK: volver a aplicar las definiciones vivas antes de esta migración de
-- las nueve funciones (pg_get_functiondef de un backup, o deshacer cada ancla a
-- mano). No se toca ninguna fila.
-- ============================================================================

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'mig NNN · el texto de la migración trae CRLF: aplicarla desde la versión LF (git show HEAD:migrations/<archivo>)';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- 0 · Premisas: nada cambió en prod desde que se leyeron los cuerpos (29/10)
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, md5(pg_get_functiondef(x.firma::regprocedure)) AS md5_vivo
      FROM (VALUES
        ('public.pedidos_proteger_columnas()',                                        '45020fab867aca472da0e2dc976743a1'),
        ('public.anular_control_por_cambio_fecha_entrega()',                          'c548eee60a94cca8be6912b92a47d874'),
        ('public.registrar_cambio_pedido()',                                          '24c658d8967b4fe481c393bc71870c53'),
        ('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)',
                                                                                      'c72d9c88481b66ce89a1e1bc1efe5c1e'),
        ('public.crear_pedido_completo_bot(uuid,uuid)',                               '86d2fb6b6a2ba4298970e51545005316'),
        ('public.registrar_visita_cliente(bigint,text,numeric,numeric,numeric,timestamptz,text)',
                                                                                      '25237235591a6b7b0414deeb7bb13820'),
        ('public.registrar_cambio_producto(integer,bigint,integer,bigint,integer,text,text)',
                                                                                      '589a536c13384e88f7964cea2c9499e1'),
        ('public.marcar_entregas_masivo(bigint[],uuid,date)',                         '3fb07aa6948edd07af9222cb917537a4'),
        ('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)',         '5b0e3cab24dcdee1a7546d1e11ebb467')
      ) AS x(firma, md5)
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION 'mig NNN · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer los parches sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;
END
$premisas$;

CREATE OR REPLACE FUNCTION pg_temp.t4_parchar(p_def text, p_viejo text, p_nuevo text, p_que text, p_veces int DEFAULT 1)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
  v_veces int := (length(p_def) - length(replace(p_def, p_viejo, ''))) / length(p_viejo);
BEGIN
  IF v_veces <> p_veces THEN
    RAISE EXCEPTION '%: el ancla aparece % veces (se esperaba %). El cuerpo vivo cambió: revisar a mano', p_que, v_veces, p_veces;
  END IF;
  RETURN replace(p_def, p_viejo, p_nuevo);
END
$fn$;

-- ---------------------------------------------------------------------------
-- 1 · #1317 · pedidos_proteger_columnas: quién cambia estado, chofer y fecha
--     de entrega
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.pedidos_proteger_columnas()'::regprocedure);
BEGIN
  v_def := pg_temp.t4_parchar(v_def,
$q$  -- #1170: la rama del chofer es para los pedidos a los que llega SÓLO como$q$,
$q$  -- #1317: el estado, el chofer y la fecha de entrega. El GRANT UPDATE de esas
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

  -- #1170: la rama del chofer es para los pedidos a los que llega SÓLO como$q$,
    'pedidos_proteger_columnas: estado, chofer y fecha de entrega');

  -- #1298: el día de la entrega es el argentino. Son las 4 y 4 del bloque (2),
  -- que espeja a anular_control_por_cambio_fecha_entrega (sección 1b).
  v_def := pg_temp.t4_parchar(v_def,
    'OLD.fecha_entrega::date',
    $q$(OLD.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date$q$,
    'pedidos_proteger_columnas: día de OLD', 4);
  v_def := pg_temp.t4_parchar(v_def,
    'NEW.fecha_entrega::date',
    $q$(NEW.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date$q$,
    'pedidos_proteger_columnas: día de NEW', 4);
  v_def := pg_temp.t4_parchar(v_def,
    '(mismo ::date,',
    '(mismo día argentino,',
    'pedidos_proteger_columnas: comentario');

  EXECUTE v_def;
END
$patch$;

-- ---------------------------------------------------------------------------
-- 1b · #1298 · anular_control_por_cambio_fecha_entrega: el día argentino
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.anular_control_por_cambio_fecha_entrega()'::regprocedure);
BEGIN
  v_def := pg_temp.t4_parchar(v_def,
    'OLD.fecha_entrega::date',
    $q$(OLD.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date$q$,
    'anular_control_por_cambio_fecha_entrega: día de OLD', 3);
  v_def := pg_temp.t4_parchar(v_def,
    'NEW.fecha_entrega::date',
    $q$(NEW.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date$q$,
    'anular_control_por_cambio_fecha_entrega: día de NEW', 3);
  v_def := pg_temp.t4_parchar(v_def,
$q$BEGIN
  IF OLD.fecha_entrega IS NOT NULL$q$,
$q$BEGIN
  -- #1298: el control es del día argentino de la entrega; ::date sobre el
  -- timestamptz cortaba en UTC (de 21 a 24 caía en el día siguiente). Espejo
  -- del bloque (2) de pedidos_proteger_columnas: si cambia uno, el otro.
  IF OLD.fecha_entrega IS NOT NULL$q$,
    'anular_control_por_cambio_fecha_entrega: comentario');

  EXECUTE v_def;
END
$patch$;

-- ---------------------------------------------------------------------------
-- 2 · #1319 (PED-7) · registrar_cambio_pedido: el historial de la fecha
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.registrar_cambio_pedido()'::regprocedure);
BEGIN
  v_def := pg_temp.t4_parchar(v_def,
$q$  IF OLD.notas IS DISTINCT FROM NEW.notas THEN$q$,
$q$  -- #1319: la fecha del pedido mueve la venta y la comisión de mes (migs
  -- 241/318). Sólo la cambian admin y encargado (#1155): queda quién y desde qué.
  IF OLD.fecha IS DISTINCT FROM NEW.fecha THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (NEW.id, usuario_actual, 'fecha',
            COALESCE(OLD.fecha::TEXT, '(sin fecha)'),
            COALESCE(NEW.fecha::TEXT, '(sin fecha)'),
            NEW.sucursal_id);
  END IF;

  IF OLD.notas IS DISTINCT FROM NEW.notas THEN$q$,
    'registrar_cambio_pedido: fecha');

  EXECUTE v_def;
END
$patch$;

-- ---------------------------------------------------------------------------
-- 3 · #1319 (PED-4, PED-8) · crear_pedido_completo: tope de la fecha y cliente
--     activo
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE
  v_def text := pg_get_functiondef(
    'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.t4_parchar(v_def,
$q$  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista', 'encargado') THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No tiene permisos para crear pedidos')); END IF;$q$,
$q$  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista', 'encargado') THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No tiene permisos para crear pedidos')); END IF;

  -- #1319 (decisión del dueño, 29/10): para quien no es admin, la fecha del
  -- pedido no pasa de hoy, el día argentino. Lo futuro va en la entrega
  -- programada. Una fecha pasada sigue entrando: el pedido que la cola offline
  -- encoló ayer llega hoy con la fecha de ayer.
  IF v_user_role <> 'admin' AND v_fecha_pedido > public._tablero_hoy() THEN
    RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(format(
      'La fecha del pedido (%s) no puede ser posterior a hoy. Si se entrega más adelante, cargalo con la fecha de hoy y elegí la fecha de entrega.',
      to_char(v_fecha_pedido, 'DD/MM/YYYY'))));
  END IF;

  -- #1319: un cliente dado de baja no recibe pedidos, tampoco desde una
  -- pantalla abierta antes de la baja ni desde la cola offline. Va como
  -- success=false, que la cola toma como rechazo definitivo y muestra.
  IF EXISTS (SELECT 1 FROM clientes WHERE id = p_cliente_id AND NOT activo) THEN
    RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(format(
      'El cliente "%s" está dado de baja: no se le pueden cargar pedidos. Si vuelve a comprar, reactivalo desde Clientes.',
      (SELECT COALESCE(nombre_fantasia, '#' || id::text) FROM clientes WHERE id = p_cliente_id))));
  END IF;$q$,
    'crear_pedido_completo: fecha y cliente activo');

  EXECUTE v_def;
END
$patch$;

-- ---------------------------------------------------------------------------
-- 4 · #1319 · crear_pedido_completo_bot: cliente activo (la fecha ya es hoy)
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.crear_pedido_completo_bot(uuid,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.t4_parchar(v_def,
$q$  v_fecha_pedido DATE := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;$q$,
$q$  -- #1319: el bot carga siempre con la fecha de hoy, así que el tope de la
  -- fecha del pedido (no pasa de hoy) se cumple por construcción.
  v_fecha_pedido DATE := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;$q$,
    'crear_pedido_completo_bot: fecha');

  v_def := pg_temp.t4_parchar(v_def,
$q$    RETURN jsonb_build_object('success', false, 'error', 'No tiene permisos para crear pedidos');
  END IF;$q$,
$q$    RETURN jsonb_build_object('success', false, 'error', 'No tiene permisos para crear pedidos');
  END IF;

  -- #1319: un cliente dado de baja no recibe pedidos. La confirmación vive 10
  -- minutos y la baja puede caer en el medio.
  IF EXISTS (SELECT 1 FROM clientes WHERE id = v_pendiente.cliente_id AND NOT activo) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Ese cliente está dado de baja: no se le pueden cargar pedidos. Si vuelve a comprar, pedile a un administrador que lo reactive.');
  END IF;$q$,
    'crear_pedido_completo_bot: cliente activo');

  EXECUTE v_def;
END
$patch$;

-- ---------------------------------------------------------------------------
-- 5 · #1319 · registrar_visita_cliente: cliente activo
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE
  v_def text := pg_get_functiondef(
    'public.registrar_visita_cliente(bigint,text,numeric,numeric,numeric,timestamptz,text)'::regprocedure);
BEGIN
  v_def := pg_temp.t4_parchar(v_def,
$q$  SELECT id, sucursal_id, reservado_admin INTO v_cliente FROM clientes WHERE id = p_cliente_id;$q$,
$q$  SELECT id, sucursal_id, reservado_admin, activo INTO v_cliente FROM clientes WHERE id = p_cliente_id;$q$,
    'registrar_visita_cliente: select');

  v_def := pg_temp.t4_parchar(v_def,
$q$    RETURN jsonb_build_object('success', false, 'error', 'Cliente fuera de la sucursal activa');
  END IF;$q$,
$q$    RETURN jsonb_build_object('success', false, 'error', 'Cliente fuera de la sucursal activa');
  END IF;
  -- #1319: marcar una visita es operar, y con un cliente dado de baja no se opera.
  IF NOT v_cliente.activo THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cliente dado de baja: reactivalo desde Clientes para marcarle visitas');
  END IF;$q$,
    'registrar_visita_cliente: cliente activo');

  EXECUTE v_def;
END
$patch$;

-- ---------------------------------------------------------------------------
-- 6 · #1319 · registrar_cambio_producto: cliente activo
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE
  v_def text := pg_get_functiondef(
    'public.registrar_cambio_producto(integer,bigint,integer,bigint,integer,text,text)'::regprocedure);
BEGIN
  v_def := pg_temp.t4_parchar(v_def,
$q$    RAISE EXCEPTION 'No autorizado';
  END IF;$q$,
$q$    RAISE EXCEPTION 'No autorizado';
  END IF;
  -- #1319: un canje es operar, y con un cliente dado de baja no se opera.
  IF EXISTS (SELECT 1 FROM clientes WHERE id = p_cliente_id AND NOT activo) THEN
    RAISE EXCEPTION 'El cliente está dado de baja: reactivalo desde Clientes para registrarle un cambio de producto.'
      USING ERRCODE = 'P0001';
  END IF;$q$,
    'registrar_cambio_producto: cliente activo');

  EXECUTE v_def;
END
$patch$;

-- ---------------------------------------------------------------------------
-- 7 · #1318 · marcar_entregas_masivo: día controlado y canjes
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.marcar_entregas_masivo(bigint[],uuid,date)'::regprocedure);
BEGIN
  v_def := pg_temp.t4_parchar(v_def,
$q$  v_fecha_ts TIMESTAMPTZ;
BEGIN$q$,
$q$  v_fecha_ts TIMESTAMPTZ;
  v_cerrado RECORD; -- #1318
BEGIN$q$,
    'marcar_entregas_masivo: declare');

  v_def := pg_temp.t4_parchar(v_def,
$q$  v_fecha_ts := (p_fecha::text || ' 12:00:00 America/Argentina/Buenos_Aires')::timestamptz;
$q$,
$q$  -- #1318 (REN-1): entregar con la fecha de un día ya controlado reabría ese
  -- control como efecto secundario (trg_pedidos_anular_control lo borra con su
  -- foto). Un día cerrado se reabre a propósito, desde la rendición. Mira los
  -- dos lados que borra el trigger: el día nuevo del chofer nuevo, y el día que
  -- ya tuviera anotado el pedido.
  SELECT x.chofer, x.dia INTO v_cerrado
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
     AND public.control_rendicion_cerrado(x.chofer, v_sucursal_id, x.dia)
   LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'La rendición del % de % ya fue controlada: esta entrega la reabriría. Elegí otra fecha, o reabrí primero el control de ese día.',
      to_char(v_cerrado.dia, 'DD/MM/YYYY'),
      COALESCE((SELECT nombre FROM perfiles WHERE id = v_cerrado.chofer), 'ese chofer')
      USING ERRCODE = '42501';
  END IF;

  v_fecha_ts := (p_fecha::text || ' 12:00:00 America/Argentina/Buenos_Aires')::timestamptz;
$q$,
    'marcar_entregas_masivo: día controlado');

  v_def := pg_temp.t4_parchar(v_def,
$q$     AND COALESCE(tipo_factura, 'ZZ') <> 'VB';  -- mig 3XA
$q$,
$q$     AND COALESCE(tipo_factura, 'ZZ') <> 'VB'  -- mig 3XA
     -- #1318: la comanda de un canje se entrega desde el pedido, que aplica el
     -- cambio (aplicar_cambio_de_parada) antes de cerrarla.
     AND canal IS DISTINCT FROM 'cambio';
$q$,
    'marcar_entregas_masivo: canjes');

  EXECUTE v_def;
END
$patch$;

-- ---------------------------------------------------------------------------
-- 8 · #1318 · marcar_entrega_y_pago_masivo_impl: entregados, día controlado y
--     canjes
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)'::regprocedure);
BEGIN
  v_def := pg_temp.t4_parchar(v_def,
$q$  v_fecha_ts TIMESTAMPTZ;
BEGIN$q$,
$q$  v_fecha_ts TIMESTAMPTZ;
  v_cerrado RECORD; -- #1318
BEGIN$q$,
    'marcar_entrega_y_pago_masivo_impl: declare');

  v_def := pg_temp.t4_parchar(v_def,
$q$  v_fecha_ts := (p_fecha::text || ' 12:00:00 America/Argentina/Buenos_Aires')::timestamptz;
$q$,
$q$  -- #1318 (REN-1): el mismo corte que marcar_entregas_masivo. Va antes del
  -- cobro: si la entrega no entra, el cobro tampoco.
  SELECT x.chofer, x.dia INTO v_cerrado
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
     AND public.control_rendicion_cerrado(x.chofer, v_sucursal_id, x.dia)
   LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'La rendición del % de % ya fue controlada: esta entrega la reabriría. Elegí otra fecha, o reabrí primero el control de ese día.',
      to_char(v_cerrado.dia, 'DD/MM/YYYY'),
      COALESCE((SELECT nombre FROM perfiles WHERE id = v_cerrado.chofer), 'ese chofer')
      USING ERRCODE = '42501';
  END IF;

  v_fecha_ts := (p_fecha::text || ' 12:00:00 America/Argentina/Buenos_Aires')::timestamptz;
$q$,
    'marcar_entrega_y_pago_masivo_impl: día controlado');

  -- El cobro: un entregado se cobra por el cobro masivo (el front ya lo manda
  -- ahí), y un canje tiene total 0.
  v_def := pg_temp.t4_parchar(v_def,
$q$      AND COALESCE(estado, '') NOT IN ('cancelado', 'anulado')
      AND total > COALESCE(monto_pagado, 0)$q$,
$q$      -- #1318 (PED-3): un entregado no se vuelve a entregar, como en la 181.
      AND COALESCE(estado, '') NOT IN ('entregado', 'cancelado', 'anulado')
      AND canal IS DISTINCT FROM 'cambio'
      AND total > COALESCE(monto_pagado, 0)$q$,
    'marcar_entrega_y_pago_masivo_impl: cobro');

  v_def := pg_temp.t4_parchar(v_def,
$q$     AND COALESCE(estado, '') NOT IN ('cancelado', 'anulado')
     AND COALESCE(tipo_factura, 'ZZ') <> 'VB';  -- mig 3XA
$q$,
$q$     -- #1318 (PED-3): un entregado no se vuelve a entregar: le pisaba el
     -- chofer y la fecha, y el trigger le borraba el control del día viejo.
     AND COALESCE(estado, '') NOT IN ('entregado', 'cancelado', 'anulado')
     AND COALESCE(tipo_factura, 'ZZ') <> 'VB'  -- mig 3XA
     -- #1318: la comanda de un canje se entrega desde el pedido, que aplica el
     -- cambio (aplicar_cambio_de_parada) antes de cerrarla.
     AND canal IS DISTINCT FROM 'cambio';
$q$,
    'marcar_entrega_y_pago_masivo_impl: entrega');

  EXECUTE v_def;
END
$patch$;

-- ---------------------------------------------------------------------------
-- 9 · Verificación: los parches entraron y nada cambió de dueño, ACL ni
--     SECURITY
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.marca, x.definer, p.prosecdef, p.proacl::text AS acl, x.acl AS acl_esperada,
           pg_get_functiondef(p.oid) AS def
      FROM (VALUES
        ('public.pedidos_proteger_columnas()', 'los cambia su chofer al entregarlo', false,
         '{postgres=X/postgres,service_role=X/postgres}'),
        ('public.anular_control_por_cambio_fecha_entrega()', $m$(OLD.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date$m$, true,
         '{postgres=X/postgres,service_role=X/postgres}'),
        ('public.registrar_cambio_pedido()', $m$'fecha',$m$, false,
         '{postgres=X/postgres,service_role=X/postgres}'),
        ('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)',
         'no puede ser posterior a hoy', true,
         '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public.crear_pedido_completo_bot(uuid,uuid)', 'Ese cliente está dado de baja', true,
         '{postgres=X/postgres,service_role=X/postgres}'),
        ('public.registrar_visita_cliente(bigint,text,numeric,numeric,numeric,timestamptz,text)',
         'Cliente dado de baja', true,
         '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public.registrar_cambio_producto(integer,bigint,integer,bigint,integer,text,text)',
         'registrarle un cambio de producto', true,
         '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public.marcar_entregas_masivo(bigint[],uuid,date)', 'esta entrega la reabriría', true,
         '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)', $m$NOT IN ('entregado', 'cancelado', 'anulado')$m$, true,
         '{postgres=X/postgres,service_role=X/postgres}')
      ) AS x(firma, marca, definer, acl)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF position(v_f.marca in v_f.def) = 0 THEN
      RAISE EXCEPTION 'mig NNN · % no quedó parcheada (falta "%")', v_f.firma, v_f.marca;
    END IF;
    IF v_f.prosecdef <> v_f.definer THEN
      RAISE EXCEPTION 'mig NNN · % cambió SECURITY DEFINER a %', v_f.firma, v_f.prosecdef;
    END IF;
    IF v_f.acl IS DISTINCT FROM v_f.acl_esperada THEN
      RAISE EXCEPTION 'mig NNN · % cambió de ACL: % (se esperaba %)', v_f.firma, v_f.acl, v_f.acl_esperada;
    END IF;
  END LOOP;
END
$verif$;
