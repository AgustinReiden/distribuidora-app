-- =========================================================================
-- NNN · RUTAS: ORDEN DE LOS BLOQUEOS, NO ENTREGADO Y REFECHADO (ola 3,
--       tarjeta T2 de #1677; #1432, VTA-06 de #1522, Rut-B7 y Rut-B12 de
--       #1554, 1601-b1 de #1601 y #1697)
--
-- Ensayo: scripts/test-ola3-t2-rutas-no-entregado.sql (falla sin esta
-- migración, ENSAYO OK con ella). Carreras de dos sesiones:
-- scripts/concurrencia/t2-rutas-orden-de-bloqueos.sh.
-- Se aplica en LF. Una DDL de tabla (la columna nueva de pedidos): su LOCK va
-- al principio, NOWAIT.
--
-- El orden de las rutas desde #1406 es pedidos por id → recorridos por id →
-- paradas (recorrido_pedidos). Tres caminos no lo seguían:
--
-- 1 · #1432 + VTA-06 · marcar_no_entregado escribía la parada antes de tomar
--     el pedido, y leía el pedido sin bloquearlo: contra una entrega del mismo
--     pedido (pedido → ruta → parada) era un 40P01, y una entrega confirmada
--     en el medio volvía a pendiente (su UPDATE no miraba el estado). Ahora
--     toma el pedido FOR UPDATE, después sus rutas por id, después la parada,
--     y el UPDATE del pedido no toca uno entregado ni dado de baja.
-- 2 · #1432 · _pedido_a_pendiente borraba la parada antes de tomar la ruta
--     cuando su UPDATE del pedido no matcheaba (pedido ya pendiente, sin
--     chofer ni orden, con una parada en una ruta en curso). Ahora toma las
--     rutas del pedido por id antes de todo (el pedido ya lo tiene su wrapper).
-- 3 · #1432 · cambiar_transportista_recorrido tomaba la ruta y después los
--     pedidos, sin orden. Ahora toma primero, por id, los pedidos que la ruta
--     todavía reparte (los que puede mover), después la ruta; si con la ruta
--     tomada la ruta reparte un pedido que no tomó (lo sumaron en el medio),
--     se rechaza con 40001 para que se reintente, en vez de pedirlo fuera de
--     orden. El chofer nuevo se valida con _actua_como_transportista (la regla
--     de aplicar_orden_ruta y de la entrega, #1548), la misma que ahora pide
--     el trigger del pedido (punto 6).
-- 4 · Rut-B12 · quitar_pedido_de_recorridos_activos, llamada sola sobre un
--     pedido entregado, borraba su parada entregada. Ahora la conserva (la
--     cancelación la llama con el pedido ya cancelado y sigue igual). El rol se
--     mira con es_encargado_o_admin(), activo incluido (#1490): sale de
--     scripts/rol-sin-activo-permitidas.json.
-- 5 · Rut-B7 (decisión del dueño) · una ruta no se completa desde la app con
--     paradas sin marcar: recorridos_estado_transicion rechaza en_curso →
--     completado por REST mientras quede una parada 'pendiente' cuyo pedido no
--     está entregado ni dado de baja, con el motivo y cuántas faltan. El
--     cierre del server (cerrar_recorridos_vencidos) no pasa por acá. El
--     UPDATE de recorridos sigue concedido (un bundle viejo del PWA lo usa
--     para completar una ruta ya marcada entera): queda en bundle_viejo.
-- 6 · 1601-b1 · pedidos.transportista_id se podía asignar por REST a
--     cualquier perfil (de otra sucursal, de otro rol, desactivado) mientras
--     el pedido no se entregara. pedidos_entrega_con_chofer (DEFINER, ya es
--     la que valida el chofer de una entrega) lo valida en toda asignación o
--     cambio de chofer, con _actua_como_transportista, para todo camino: el
--     REST, las RPC y el server. Un vale blanco no cambia. No se toca
--     pedidos_proteger_columnas (es de la tarjeta T4): la regla corre igual
--     para el PATCH de admin y encargado, que ahí salen antes.
-- 7 · #1697 (decisiones del dueño del 25/11) · al marcar «no entregado», en
--     ese momento, la entrega programada pasa al día siguiente (día
--     calendario, el día argentino de hoy + 1), con todos los motivos salvo
--     'cliente_rechaza' («Lo rechazó»), que queda como hoy. El pedido guarda
--     la fecha original en pedidos.entrega_refechada_desde (la programada que
--     tenía o, sin programada, el día de la ruta; si se refecha otra vez,
--     conserva la primera): la pantalla la muestra como «Refechado». La
--     fecha del pedido (pedidos.fecha) no se toca. Respeta el rango de la
--     entrega programada (_fecha_entrega_programada_fuera_de_rango); una
--     programada que ya es futura no se adelanta. El armado se sigue borrando
--     (Rut-B9, pedidos_registrar_armado, sin cambios).
--     La columna es de server: authenticated la lee (pedidos se lee por
--     tabla) y no la escribe (pedidos.UPDATE es por columna y no se suma).
--
-- Lo que NO hace: no toca pedidos_proteger_columnas, actualizar_recorrido_
-- entrega, las masivas, aplicar_orden_ruta ni cerrar_recorridos_vencidos.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

-- La DDL de tabla: su lock primero, sin esperar.
LOCK TABLE public.pedidos IN ACCESS EXCLUSIVE MODE NOWAIT;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos de producción en la 553.
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.marcar_no_entregado(bigint,character varying,text)', '616b2c3986899f6d021fa79bf12bbae6'),
    ('public._pedido_a_pendiente(bigint,bigint,text)', 'fecba6acd3c35148c2272da9f720a94e'),
    ('public.cambiar_transportista_recorrido(bigint,uuid)', 'aba2a237f2f6f323b0d559ab846fd7db'),
    ('public.quitar_pedido_de_recorridos_activos(bigint)', 'f9676901f4a4383ad205223522e38382'),
    ('public.recorridos_estado_transicion()', 'cc22cfc32963d309e11eaea22d8f992c'),
    ('public.pedidos_entrega_con_chofer()', '506b5868c309d0397be4f951fe255b5a'),
    ('public._actua_como_transportista(uuid,bigint)', '42e2ceb259312bf20ba1145f1ff7ee75'),
    ('public._fecha_entrega_programada_fuera_de_rango(date,date)', 'e8db0b4c94805a3531758a5322343a69'),
    ('public.pedidos_registrar_armado()', '2d5583b0ea405bcea6a8883977f94c9f')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.pedidos'::regclass
                AND attname = 'entrega_refechada_desde' AND NOT attisdropped) THEN
    RAISE EXCEPTION 'mig NNN · ya está aplicada (existe pedidos.entrega_refechada_desde)';
  END IF;
  -- Los disparadores de los que dependen los puntos 5 y 6.
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.recorridos'::regclass
                    AND tgname = 'trg_recorridos_estado' AND NOT tgisinternal)
     OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.pedidos'::regclass
                       AND tgname = 'trg_pedidos_entrega_con_chofer' AND NOT tgisinternal
                       AND pg_get_triggerdef(oid) LIKE '%UPDATE OF estado, transportista_id, retiro_deposito%') THEN
    RAISE EXCEPTION 'mig NNN · los triggers de recorridos o pedidos no son los que se leyeron';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 7 · La fecha original de una entrega refechada.
-- ---------------------------------------------------------------------------
ALTER TABLE public.pedidos ADD COLUMN entrega_refechada_desde date;

COMMENT ON COLUMN public.pedidos.entrega_refechada_desde IS
  '#1697: la entrega programada que tenía el pedido antes de que marcar_no_entregado la pasara al día siguiente (sin programada, el día de la ruta). NULL: nunca se refechó. Con varios refechados, la primera. La escribe sólo el server.';

-- ---------------------------------------------------------------------------
-- 1 + 7 · marcar_no_entregado
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.marcar_no_entregado(p_pedido_id bigint, p_motivo character varying, p_nota text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
DECLARE
  v_sucursal      bigint := current_sucursal_id();
  v_uid           uuid := auth.uid();
  v_hoy           date := public._tablero_hoy();
  v_transportista uuid;
  v_usuario_id    uuid;
  v_estado        text;
  v_cliente       text;
  v_fecha         date;
  v_programada    date;
  v_paradas       int;
  v_fecha_ruta    date;
  v_refecha       boolean;
  v_nueva         date;
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  IF p_motivo IS NULL OR p_motivo NOT IN (
    'cerrado', 'sin_dinero', 'cliente_rechaza', 'ausente',
    'direccion_incorrecta', 'clima', 'otro'
  ) THEN
    RAISE EXCEPTION 'Motivo de no entrega inválido: %', COALESCE(p_motivo, '(vacío)');
  END IF;

  -- "otro" sin explicación no sirve para nada: es el que después nadie entiende.
  IF p_motivo = 'otro' AND (p_nota IS NULL OR length(trim(p_nota)) < 3) THEN
    RAISE EXCEPTION 'Si el motivo es "otro" hay que escribir qué pasó';
  END IF;

  -- mig NNN (#1432, VTA-06 de #1522): el pedido se toma PRIMERO, en el orden de la 439
  -- (pedidos, rutas, paradas), y se lee tomado: una entrega del mismo pedido que se confirma
  -- en el medio ya no vuelve a pendiente, y la entrega (pedido → ruta → parada) no se cruza
  -- con esta función, que antes escribía la parada antes de tomar el pedido.
  SELECT p.transportista_id, p.usuario_id, p.estado, p.fecha, p.fecha_entrega_programada
    INTO v_transportista, v_usuario_id, v_estado, v_fecha, v_programada
  FROM pedidos p
  WHERE p.id = p_pedido_id AND p.sucursal_id = v_sucursal
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pedido % no encontrado en esta sucursal', p_pedido_id;
  END IF;

  SELECT c.nombre_fantasia INTO v_cliente
    FROM pedidos p JOIN clientes c ON c.id = p.cliente_id
   WHERE p.id = p_pedido_id;

  IF v_estado = 'entregado' THEN
    RAISE EXCEPTION 'El pedido % ya figura entregado', p_pedido_id;
  END IF;

  -- Mig 243: un cancelado/anulado ya tiene el stock devuelto, el total en 0 y
  -- los pagos desimputados (mig 235). Volverlo a 'pendiente' lo resucita como
  -- venta viva de $0, que es lo que la compra mínima no puede validar después
  -- (se valida al crear, trampa 8). Si hay que re-entregarlo, se crea uno nuevo
  -- — la misma salida que da `actualizar_pedido_items` desde la 181.
  IF v_estado IN ('cancelado', 'anulado') THEN
    RAISE EXCEPTION 'El pedido % está % y no se puede reabrir desde el reparto: creá uno nuevo',
      p_pedido_id, v_estado
      USING ERRCODE = '42501';
  END IF;

  -- Lo puede marcar el chofer al que se le asignó, o un admin/encargado.
  -- SEG-1 (#1601): sin chofer (transportista_id NULL, como lo deja esta misma función) la
  -- comparación daba NULL, el NOT también, y el IF no cortaba: pasaba cualquier rol de la
  -- sucursal. Un NULL no autoriza a nadie más que a admin y encargado, que se miran con su
  -- helper (activo incluido, #1490).
  IF NOT (COALESCE(v_transportista = v_uid, false) OR public.es_encargado_o_admin()) THEN
    RAISE EXCEPTION 'Solo el transportista asignado o un encargado puede marcar la no entrega'
      USING ERRCODE = '42501';
  END IF;

  -- mig NNN (#1432): las rutas del pedido, por id, antes de su parada. Son las mismas que toma
  -- después el trigger de la entrega (actualizar_recorrido_entrega) al pasar el pedido a
  -- pendiente: con el pedido tomado nadie le suma una parada en el medio (aplicar_orden_ruta
  -- toma el pedido antes).
  PERFORM 1
     FROM recorridos r
    WHERE r.id IN (SELECT rp.recorrido_id
                     FROM recorrido_pedidos rp
                    WHERE rp.pedido_id = p_pedido_id)
    ORDER BY r.id
      FOR NO KEY UPDATE;

  -- 1) Queda el registro del intento fallido en la ruta.
  WITH marcadas AS (
    UPDATE recorrido_pedidos rp
    SET estado_entrega    = 'no_entregado',
        motivo_no_entrega = p_motivo,
        nota_no_entrega   = NULLIF(trim(COALESCE(p_nota, '')), ''),
        hora_entrega      = now()
    FROM recorridos r
    WHERE rp.recorrido_id = r.id
      AND rp.pedido_id = p_pedido_id
      AND rp.sucursal_id = v_sucursal
      AND r.estado = 'en_curso'
      -- mig 550 (Rut-B5): no la parada 'reasignado' de una ruta en curso, que es de otro
      -- chofer que ya no la tiene.
      AND rp.estado_entrega <> 'reasignado'
    RETURNING r.fecha
  )
  SELECT count(*), max(fecha) INTO v_paradas, v_fecha_ruta FROM marcadas;

  -- Mig 243: sin parada marcada no hay nada que registrar, y liberar el pedido
  -- igual deja el intento fallido sin rastro (que es lo que la 144 vino a medir)
  -- devolviendo success: true. Aborta en vez de seguir de largo.
  IF v_paradas = 0 THEN
    RAISE EXCEPTION 'El pedido % no es una parada de ninguna hoja de ruta en curso de esta sucursal: no hay no-entrega que registrar',
      p_pedido_id
      USING ERRCODE = '42501';
  END IF;

  -- mig NNN (#1697, decisiones del dueño del 25/11): la entrega programada pasa al día
  -- siguiente (hoy + 1, día calendario argentino) en este mismo momento, salvo que el cliente
  -- no lo quiso recibir. Una programada que ya es posterior a hoy no se adelanta. Dentro del
  -- rango de la entrega programada (de hoy a 60 días); fuera de él, queda como estaba.
  v_refecha := p_motivo <> 'cliente_rechaza' AND (v_programada IS NULL OR v_programada <= v_hoy);
  IF v_refecha THEN
    v_nueva := v_hoy + 1;
    IF public._fecha_entrega_programada_fuera_de_rango(v_nueva, LEAST(v_hoy, v_fecha)) IS NOT NULL THEN
      v_refecha := false;
      v_nueva := NULL;
    END IF;
  END IF;

  -- 2) Se libera el pedido para poder re-rutearlo. No se cancela. Con el estado en el WHERE
  -- (VTA-06): con el pedido tomado no debería cambiar, pero un entregado no vuelve atrás.
  UPDATE pedidos
  SET estado                   = 'pendiente',
      transportista_id         = NULL,
      orden_entrega            = NULL,
      fecha_entrega_programada = CASE WHEN v_refecha THEN v_nueva ELSE fecha_entrega_programada END,
      entrega_refechada_desde  = CASE WHEN v_refecha
                                      THEN COALESCE(entrega_refechada_desde, fecha_entrega_programada, v_fecha_ruta)
                                      ELSE entrega_refechada_desde END
  WHERE id = p_pedido_id AND sucursal_id = v_sucursal
    AND estado NOT IN ('entregado', 'cancelado', 'anulado');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El pedido % cambió de estado mientras se marcaba: volvé a cargar la ruta', p_pedido_id
      USING ERRCODE = '40001';
  END IF;

  -- 3) Aviso al preventista dueño de la venta, con el motivo.
  IF v_usuario_id IS NOT NULL AND v_usuario_id <> v_uid THEN
    INSERT INTO notificaciones (
      usuario_id, sucursal_id, tipo, titulo, mensaje, entidad_tipo, entidad_id, payload
    ) VALUES (
      v_usuario_id, v_sucursal, 'pedido_no_entregado',
      'Pedido no entregado',
      format('El pedido #%s de %s no se pudo entregar: %s%s',
             p_pedido_id, COALESCE(v_cliente, 'cliente'),
             CASE p_motivo
               WHEN 'cerrado'              THEN 'el local estaba cerrado'
               WHEN 'sin_dinero'           THEN 'el cliente no tenía dinero'
               WHEN 'cliente_rechaza'      THEN 'el cliente rechazó el pedido'
               WHEN 'ausente'              THEN 'no había nadie'
               WHEN 'direccion_incorrecta' THEN 'la dirección es incorrecta'
               WHEN 'clima'                THEN 'por el clima'
               ELSE COALESCE(NULLIF(trim(COALESCE(p_nota, '')), ''), 'otro motivo')
             END,
             CASE WHEN v_refecha THEN format('. La entrega pasa al %s', to_char(v_nueva, 'DD/MM')) ELSE '' END),
      'pedido', p_pedido_id,
      jsonb_build_object('pedido_id', p_pedido_id, 'motivo', p_motivo, 'nota', p_nota,
                         'refechado_a', v_nueva)
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'pedido_id', p_pedido_id,
    'motivo', p_motivo,
    'paradas_marcadas', v_paradas,
    'refechado', v_refecha,
    'fecha_entrega_programada', CASE WHEN v_refecha THEN v_nueva ELSE v_programada END
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 2 · _pedido_a_pendiente
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._pedido_a_pendiente(p_pedido_id bigint, p_sucursal_id bigint, p_estado text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path = public, pg_temp
AS $function$
DECLARE
  v_paradas BIGINT[];
  v_rutas   BIGINT[];
  v_rid     BIGINT;
BEGIN
  IF p_estado = 'entregado' THEN
    RAISE EXCEPTION 'El pedido #% ya está entregado: para deshacerlo usá "Revertir entrega"', p_pedido_id;
  END IF;
  IF p_estado NOT IN ('pendiente', 'en_preparacion', 'asignado') THEN
    RAISE EXCEPTION 'El pedido #% está % y no vuelve a pendiente', p_pedido_id, p_estado;
  END IF;

  -- mig NNN (#1432): las rutas del pedido, por id, antes de tocar nada (el pedido ya lo tomó
  -- quien llama). Si el UPDATE de abajo no matchea (el pedido ya estaba pendiente, sin chofer
  -- ni orden) el trigger de la entrega no corre, y la parada se borraba antes de tomar la ruta.
  -- Son las mismas rutas que toma ese trigger cuando sí corre.
  PERFORM 1
     FROM recorridos r
    WHERE r.id IN (SELECT rp.recorrido_id
                     FROM recorrido_pedidos rp
                    WHERE rp.pedido_id = p_pedido_id)
    ORDER BY r.id
      FOR NO KEY UPDATE;

  -- Lo mismo que hacía el front por REST (chofer, estado, updated_at y
  -- fecha_entrega en NULL), en una sola sentencia.
  UPDATE pedidos
     SET estado           = 'pendiente',
         transportista_id = NULL,
         orden_entrega    = NULL,
         fecha_entrega    = NULL,
         updated_at       = now()
   WHERE id = p_pedido_id
     AND (estado <> 'pendiente' OR transportista_id IS NOT NULL OR orden_entrega IS NOT NULL);

  -- Sale de la(s) ruta(s) en curso, para que no quede como parada fantasma y
  -- reaparezca limpio en "Armar ruta". El no entregado deja su rastro antes.
  SELECT array_agg(rp.id), array_agg(DISTINCT rp.recorrido_id ORDER BY rp.recorrido_id)
    INTO v_paradas, v_rutas
    FROM recorrido_pedidos rp
    JOIN recorridos r ON r.id = rp.recorrido_id
   WHERE rp.pedido_id   = p_pedido_id
     AND rp.sucursal_id = p_sucursal_id
     AND r.estado       = 'en_curso';

  IF v_paradas IS NOT NULL THEN
    PERFORM public._no_entregas_al_historial(v_paradas);
    DELETE FROM recorrido_pedidos WHERE id = ANY(v_paradas);
  END IF;

  FOREACH v_rid IN ARRAY COALESCE(v_rutas, '{}') LOOP
    UPDATE recorridos r
       SET total_pedidos      = c.total_pedidos,
           total_facturado    = c.total_facturado,
           pedidos_entregados = c.pedidos_entregados,
           total_cobrado      = c.total_cobrado
      FROM public._recorrido_contadores(v_rid) c
     WHERE r.id = v_rid;
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'pedido_id', p_pedido_id,
    'paradas_eliminadas', COALESCE(cardinality(v_paradas), 0)
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3 · cambiar_transportista_recorrido
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cambiar_transportista_recorrido(p_recorrido_id bigint, p_transportista_id uuid)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
DECLARE
  v_sucursal   bigint := current_sucursal_id();
  v_recorrido  recorridos%ROWTYPE;
  v_entregadas integer;
  v_conflicto  bigint;
  v_nombre     text;
  v_tomados    bigint[];
  v_faltan     bigint[];
BEGIN
  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado para cambiar el transportista de una ruta'
      USING ERRCODE = '42501';
  END IF;

  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'Sucursal no resuelta para el usuario actual';
  END IF;

  IF p_transportista_id IS NULL THEN
    RAISE EXCEPTION 'Hay que elegir un transportista';
  END IF;

  -- mig NNN (#1432): primero los pedidos que la ruta todavía reparte (los que este cambio
  -- puede mover), por id; después la ruta. Antes era ruta → pedidos, al revés de la 439, y se
  -- cruzaba con la entrega o el cobro de un pedido de la ruta (pedido → ruta).
  SELECT array_agg(p.id ORDER BY p.id) INTO v_tomados
    FROM (SELECT p.id
            FROM pedidos p
           WHERE p.id IN (SELECT rp.pedido_id FROM recorrido_pedidos rp
                           WHERE rp.recorrido_id = p_recorrido_id
                             AND rp.estado_entrega = 'pendiente')
             AND p.sucursal_id = v_sucursal
           ORDER BY p.id
             FOR NO KEY UPDATE) p;

  -- FOR NO KEY UPDATE: sin el lock, dos admins reasignando en paralelo pueden pasar
  -- los dos el chequeo de uq_recorrido_vigente y uno se come el 23505.
  SELECT * INTO v_recorrido
  FROM recorridos
  WHERE id = p_recorrido_id
    AND sucursal_id = v_sucursal
  FOR NO KEY UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La ruta #% no existe en esta sucursal', p_recorrido_id
      USING ERRCODE = 'P0002';
  END IF;

  IF v_recorrido.transportista_id = p_transportista_id THEN
    RETURN p_recorrido_id;  -- ya esta a su nombre: no-op
  END IF;

  IF v_recorrido.estado <> 'en_curso' THEN
    RAISE EXCEPTION 'La ruta #% esta %, solo se puede reasignar una ruta en curso',
      p_recorrido_id, v_recorrido.estado;
  END IF;

  -- mig NNN (#1432): con la ruta tomada nadie le suma una parada; si se la sumaron entre la
  -- lectura de arriba y el lock, ese pedido no está tomado y pedirlo ahora invertiría el
  -- orden. Se rechaza para que se reintente (el reintento lo toma primero).
  SELECT array_agg(rp.pedido_id ORDER BY rp.pedido_id) INTO v_faltan
    FROM recorrido_pedidos rp
   WHERE rp.recorrido_id = p_recorrido_id
     AND rp.estado_entrega = 'pendiente'
     AND rp.pedido_id <> ALL (COALESCE(v_tomados, '{}'));
  IF v_faltan IS NOT NULL THEN
    RAISE EXCEPTION 'La ruta #% cambió mientras se le cambiaba el chofer (se le sumaron los pedidos %): probá de nuevo',
      p_recorrido_id, array_to_string(v_faltan, ', ')
      USING ERRCODE = '40001';
  END IF;

  -- mig NNN (1601-b1): habilitado como chofer en esta sucursal con la regla de la entrega y de
  -- aplicar_orden_ruta (_actua_como_transportista, #1548): activo, de la sucursal, con rol base
  -- transportista o el extra (sin admin ni encargado). Es la regla que ahora pide el trigger de
  -- cada pedido (pedidos_entrega_con_chofer).
  -- El EXISTS sobre usuario_sucursales está incluido en _actua_como_transportista; va escrito
  -- para que el gate de las RPC definer vea que el usuario se acota a la sucursal activa.
  SELECT p.nombre INTO v_nombre
  FROM perfiles p
  WHERE p.id = p_transportista_id
    AND EXISTS (SELECT 1 FROM usuario_sucursales us
                 WHERE us.usuario_id = p.id AND us.sucursal_id = v_sucursal)
    AND public._actua_como_transportista(p.id, v_sucursal);

  IF v_nombre IS NULL THEN
    RAISE EXCEPTION 'El usuario elegido no esta habilitado como transportista en esta sucursal';
  END IF;

  -- Entregas ya hechas EN ESTA RUTA: la rendicion del dia quedaria partida
  -- entre dos. Una parada en historia no cuenta (#1313).
  SELECT COUNT(*) INTO v_entregadas
  FROM recorrido_pedidos rp
  JOIN pedidos p ON p.id = rp.pedido_id
  WHERE rp.recorrido_id = p_recorrido_id
    AND rp.estado_entrega IN ('pendiente', 'entregado')
    AND (rp.estado_entrega = 'entregado' OR p.estado = 'entregado');

  IF v_entregadas > 0 THEN
    RAISE EXCEPTION
      'La ruta #% ya tiene % entrega(s) hecha(s) por %. Sacale esas paradas o armale una ruta nueva al otro chofer.',
      p_recorrido_id,
      v_entregadas,
      COALESCE((SELECT nombre FROM perfiles WHERE id = v_recorrido.transportista_id), 'el chofer actual');
  END IF;

  -- uq_recorrido_vigente (transportista_id, fecha, sucursal_id) WHERE en_curso
  SELECT id INTO v_conflicto
  FROM recorridos
  WHERE transportista_id = p_transportista_id
    AND fecha            = v_recorrido.fecha
    AND sucursal_id      = v_sucursal
    AND estado           = 'en_curso'
  LIMIT 1;

  IF v_conflicto IS NOT NULL THEN
    RAISE EXCEPTION
      '% ya tiene la ruta #% armada para el %. Pasale las paradas a esa en vez de duplicarla.',
      v_nombre, v_conflicto, to_char(v_recorrido.fecha, 'DD/MM/YYYY');
  END IF;

  UPDATE recorridos
  SET transportista_id = p_transportista_id
  WHERE id = p_recorrido_id;

  -- Los pedidos tambien: `pedidos.transportista_id` es lo que leen la PWA del
  -- chofer, las policies de `pagos` (mig 155) y la rendicion. Sin esto la ruta
  -- cambia de nombre en el listado y el chofer nuevo no la ve.
  -- Sólo los que la ruta todavía reparte (#1313): asignados al chofer viejo y
  -- con la parada pendiente. Uno que volvió a pendiente (p. ej. no entregado),
  -- se canceló o ya es de otro chofer no se arrastra. Todos están tomados (arriba).
  UPDATE pedidos p
  SET transportista_id = p_transportista_id
  FROM recorrido_pedidos rp
  WHERE rp.recorrido_id   = p_recorrido_id
    AND p.id              = rp.pedido_id
    AND p.sucursal_id     = v_sucursal
    AND rp.estado_entrega = 'pendiente'
    AND p.estado          = 'asignado'
    AND p.transportista_id IS NOT DISTINCT FROM v_recorrido.transportista_id;

  RETURN p_recorrido_id;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4 · quitar_pedido_de_recorridos_activos
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.quitar_pedido_de_recorridos_activos(p_pedido_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
DECLARE
  v_sucursal  BIGINT := current_sucursal_id();
  v_estado    TEXT;
  v_paradas   BIGINT[];
  v_afectados BIGINT[];
  v_rid       BIGINT;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No hay sucursal activa');
  END IF;

  -- mig NNN: el rol con su helper, activo incluido (#1490).
  IF NOT public.es_encargado_o_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado');
  END IF;

  -- #1406: las rutas en curso del pedido se bloquean por id antes de borrar sus
  -- paradas, en el orden de la 439 (pedidos, rutas, paradas). Desde
  -- cancelar_pedido_con_stock ya estan tomadas, por el trigger de la entrega. El
  -- front la llama sola, y borraba la parada antes de tomar la ruta: la entrega
  -- de ese mismo pedido, que toma la ruta y despues la parada, se cruzaba con
  -- ella. El pedido no hace falta: no se escribe.
  PERFORM 1
     FROM recorridos r
    WHERE r.id IN (SELECT rp.recorrido_id
                     FROM recorrido_pedidos rp
                    WHERE rp.pedido_id   = p_pedido_id
                      AND rp.sucursal_id = v_sucursal)
      AND r.estado = 'en_curso'
    ORDER BY r.id
      FOR NO KEY UPDATE;

  -- mig NNN (Rut-B12 de #1554): leído con las rutas tomadas, así una entrega en curso ya
  -- confirmó. La parada entregada de un pedido entregado es la entrega: no se borra. La
  -- cancelación llama con el pedido ya cancelado, y ahí sale como siempre.
  SELECT estado INTO v_estado FROM pedidos WHERE id = p_pedido_id;

  -- mig 180: se guardan los recorridos tocados para recalcularlos. Sin esto
  -- total_pedidos/total_facturado quedaban contando una parada que ya no existe.
  -- #1313: el no entregado deja su rastro en el historial antes de irse.
  SELECT array_agg(rp.id), array_agg(DISTINCT rp.recorrido_id ORDER BY rp.recorrido_id)
    INTO v_paradas, v_afectados
  FROM recorrido_pedidos rp
  JOIN recorridos r ON r.id = rp.recorrido_id
  WHERE rp.pedido_id   = p_pedido_id
    AND rp.sucursal_id = v_sucursal
    AND r.estado       = 'en_curso'
    AND NOT (v_estado IS NOT DISTINCT FROM 'entregado' AND rp.estado_entrega = 'entregado');

  IF v_paradas IS NOT NULL THEN
    PERFORM public._no_entregas_al_historial(v_paradas);
    DELETE FROM recorrido_pedidos WHERE id = ANY(v_paradas);
    FOREACH v_rid IN ARRAY v_afectados LOOP
      PERFORM public.recalcular_recorrido(v_rid);
    END LOOP;
  END IF;

  RETURN jsonb_build_object('success', true, 'paradas_eliminadas', COALESCE(cardinality(v_paradas), 0));
END;
$function$;

-- ---------------------------------------------------------------------------
-- 5 · recorridos_estado_transicion (Rut-B7)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.recorridos_estado_transicion()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path = public, pg_temp
AS $function$
DECLARE
  v_sin_marcar integer;
BEGIN
  -- Las RPCs (SECURITY DEFINER, corren como su dueño) y el servidor manejan el
  -- estado a su manera. Por REST —el grant de `recorridos.UPDATE (completed_at,
  -- estado)` es para que el chofer cierre su ruta— sólo vale en_curso →
  -- completado, y la hora la pone el servidor (#1313, LOG-5). Un completed_at
  -- que mande el cliente se ignora (p. ej. completar una ruta que ya cerró el
  -- cron no falla: queda como estaba).
  IF current_user <> 'authenticated' THEN
    RETURN NEW;
  END IF;

  IF NEW.estado IS DISTINCT FROM OLD.estado THEN
    IF NOT (OLD.estado = 'en_curso' AND NEW.estado = 'completado') THEN
      RAISE EXCEPTION 'Una ruta % no puede pasar a % desde la app: sólo se completa una ruta en curso',
        OLD.estado, NEW.estado
        USING ERRCODE = '42501';
    END IF;
    -- mig NNN (Rut-B7 de #1554, decisión del dueño): con paradas sin marcar no se completa.
    -- Cada una se marca entregada o no entregada, y recién ahí se cierra la ruta. Si no,
    -- marcar_no_entregado ya no las encuentra (pide la ruta en curso) y la parada queda
    -- pendiente contando en una ruta cerrada. Cuenta como sin marcar la parada pendiente cuyo
    -- pedido no está entregado ni dado de baja (una desfasada de un entregado no traba).
    SELECT count(*) INTO v_sin_marcar
      FROM recorrido_pedidos rp
     WHERE rp.recorrido_id = OLD.id
       AND rp.estado_entrega = 'pendiente'
       AND NOT EXISTS (SELECT 1 FROM pedidos p
                        WHERE p.id = rp.pedido_id
                          AND p.estado IN ('entregado', 'cancelado', 'anulado'));
    IF v_sin_marcar > 0 THEN
      RAISE EXCEPTION 'La ruta #% tiene % parada(s) sin marcar: marcá cada una como entregada o no entregada y después cerrá la ruta.',
        OLD.id, v_sin_marcar
        USING ERRCODE = '23514';
    END IF;
    NEW.completed_at := now();
  ELSE
    NEW.completed_at := OLD.completed_at;
  END IF;

  RETURN NEW;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 6 · pedidos_entrega_con_chofer (1601-b1)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pedidos_entrega_con_chofer()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
DECLARE
  v_es_vb      boolean := NEW.tipo_factura IS NOT DISTINCT FROM 'VB';
  v_transicion boolean;
BEGIN
  -- Fuera de entregado no hay retiro, y con chofer tampoco: el retiro se apaga
  -- solo (revertir la entrega, volver a pendiente, asignarle chofer).
  IF NEW.estado IS DISTINCT FROM 'entregado' OR NEW.transportista_id IS NOT NULL THEN
    NEW.retiro_deposito := false;
  END IF;

  IF NEW.retiro_deposito
     AND (TG_OP = 'INSERT' OR NOT OLD.retiro_deposito)
     AND auth.uid() IS NOT NULL
     AND NOT public.es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Solo un administrador o encargado puede marcar que el cliente retiró el pedido en el depósito.'
      USING ERRCODE = '42501';
  END IF;

  -- mig NNN (1601-b1 de #1601): el chofer de un pedido es un chofer de su sucursal en toda
  -- asignación o cambio, no sólo al entregar. Por REST se le podía poner cualquier perfil
  -- (de otra sucursal, de otro rol o desactivado) a un pedido sin entregar: admin y encargado
  -- salen antes en pedidos_proteger_columnas. La regla es la de la entrega (#1548) y la de
  -- aplicar_orden_ruta. Un chofer que ya estaba no se revalida (el pasado queda como está), y
  -- el vale blanco sigue sin pedir chofer.
  IF NOT v_es_vb
     AND NEW.transportista_id IS NOT NULL
     AND (TG_OP = 'INSERT' OR OLD.transportista_id IS DISTINCT FROM NEW.transportista_id)
     AND NOT public._actua_como_transportista(NEW.transportista_id, NEW.sucursal_id) THEN
    RAISE EXCEPTION 'El pedido #% no se puede asignar a %: no es chofer en esta sucursal.',
      NEW.id, COALESCE((SELECT nombre FROM public.perfiles WHERE id = NEW.transportista_id), 'ese usuario')
      USING ERRCODE = '23514';
  END IF;

  IF NEW.estado IS DISTINCT FROM 'entregado' OR v_es_vb THEN
    RETURN NEW;
  END IF;

  v_transicion := TG_OP = 'INSERT' OR OLD.estado IS DISTINCT FROM 'entregado';

  -- Sin chofer y sin retiro: se rechaza al entregar, o al sacarle el chofer (o
  -- el retiro) a uno ya entregado. Un entregado viejo que ya estaba sin chofer
  -- no se toca: el pasado queda como esta (decision del duenio).
  IF NEW.transportista_id IS NULL AND NOT NEW.retiro_deposito
     AND (v_transicion OR OLD.transportista_id IS NOT NULL OR OLD.retiro_deposito) THEN
    RAISE EXCEPTION 'El pedido #% no tiene chofer: elegí quién lo repartió, o marcá que el cliente lo retiró en el depósito.',
      NEW.id USING ERRCODE = '23514';
  END IF;

  IF NEW.transportista_id IS NOT NULL
     AND (v_transicion OR OLD.transportista_id IS DISTINCT FROM NEW.transportista_id)
     AND NOT public._actua_como_transportista(NEW.transportista_id, NEW.sucursal_id) THEN
    RAISE EXCEPTION 'El pedido #% no se puede entregar a nombre de %: no es chofer en esta sucursal.',
      NEW.id, COALESCE((SELECT nombre FROM public.perfiles WHERE id = NEW.transportista_id), 'ese usuario')
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END
$function$;

-- Los grants de las funciones reemplazadas no cambian (CREATE OR REPLACE los conserva). Se
-- repiten los REVOKE por las dudas: ninguna de estas es de anon, y las de server de nadie.
REVOKE ALL ON FUNCTION public.marcar_no_entregado(bigint, character varying, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cambiar_transportista_recorrido(bigint, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.quitar_pedido_de_recorridos_activos(bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public._pedido_a_pendiente(bigint, bigint, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.recorridos_estado_transicion() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.pedidos_entrega_con_chofer() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Poscondiciones
-- ---------------------------------------------------------------------------
DO $pos$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.marcar_no_entregado(bigint,character varying,text)', '0a0fb201ab534c2ad3ad3d37144de4ce'),
    ('public._pedido_a_pendiente(bigint,bigint,text)', '84ee376ad61cfe788c7c82bb7446352f'),
    ('public.cambiar_transportista_recorrido(bigint,uuid)', 'e13b72c3b0561b002da28a1e9985253a'),
    ('public.quitar_pedido_de_recorridos_activos(bigint)', '621af18e95b1d7f6f66fb28b5f331a5c'),
    ('public.recorridos_estado_transicion()', '0320a07ba003fa4d58d289b25ea9d1b5'),
    ('public.pedidos_entrega_con_chofer()', 'bae7dcb40f58dc3e7d9d563ce368fdfa')
  ) AS t(f, h) LOOP
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como se esperaba (md5 %)', r.f, v;
    END IF;
  END LOOP;
  FOR r IN SELECT * FROM (VALUES
    ('public.marcar_no_entregado(bigint,character varying,text)', true, true),
    ('public.cambiar_transportista_recorrido(bigint,uuid)', true, true),
    ('public.quitar_pedido_de_recorridos_activos(bigint)', true, true),
    ('public._pedido_a_pendiente(bigint,bigint,text)', false, false),
    ('public.recorridos_estado_transicion()', false, false),
    ('public.pedidos_entrega_con_chofer()', false, true)
  ) AS t(f, rpc, definer) LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = r.f::regprocedure
                    AND p.proconfig @> ARRAY['search_path=public, pg_temp']
                    AND p.prosecdef = r.definer) THEN
      RAISE EXCEPTION 'mig NNN · % no fija search_path = public, pg_temp o cambió su SECURITY', r.f;
    END IF;
    IF has_function_privilege('anon', r.f, 'EXECUTE')
       OR has_function_privilege('authenticated', r.f, 'EXECUTE') IS DISTINCT FROM r.rpc THEN
      RAISE EXCEPTION 'mig NNN · los grants de % no quedaron bien', r.f;
    END IF;
  END LOOP;
  -- La columna nueva: la lee authenticated, no la escribe nadie de la API.
  IF NOT has_column_privilege('authenticated', 'public.pedidos', 'entrega_refechada_desde', 'SELECT')
     OR has_column_privilege('authenticated', 'public.pedidos', 'entrega_refechada_desde', 'UPDATE')
     OR has_column_privilege('authenticated', 'public.pedidos', 'entrega_refechada_desde', 'INSERT')
     OR has_column_privilege('anon', 'public.pedidos', 'entrega_refechada_desde', 'SELECT') THEN
    RAISE EXCEPTION 'mig NNN · los grants de pedidos.entrega_refechada_desde no quedaron bien';
  END IF;
  -- Rut-B9 sigue: volver a pendiente le borra el armado.
  SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = 'public.pedidos_registrar_armado()'::regprocedure;
  IF v IS DISTINCT FROM '2d5583b0ea405bcea6a8883977f94c9f' THEN
    RAISE EXCEPTION 'mig NNN · pedidos_registrar_armado cambió';
  END IF;
END
$pos$;

COMMIT;
