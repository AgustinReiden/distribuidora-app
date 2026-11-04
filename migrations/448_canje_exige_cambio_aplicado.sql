-- 448 · El canje se cierra con el cambio aplicado y sobre un día abierto (#1343).
--
-- QUÉ PASABA
--   La comanda de un canje (pedidos.canal = 'cambio') se entrega en dos llamadas:
--   aplicar_cambio_de_parada mueve el stock y después la entrega va por REST. Quedaban tres
--   huecos:
--   · Un PATCH a 'entregado' (del chofer de la parada, de un admin o de un encargado) la
--     cerraba sin aplicar el cambio: el stock no se movía. Un bundle viejo, un reintento a
--     medias o un request a mano lo hacían.
--   · crear_pedido_cambio_en_ruta no miraba clientes.activo: el canje en ruta nacía contra
--     un cliente dado de baja. #1319 lo cerró en registrar_cambio_producto, no acá.
--   · aplicar_cambio_de_parada no miraba la rendición. Desde la 443 la entrega por REST de
--     un día controlado se rechaza, así que el cambio se aplicaba y la comanda quedaba sin
--     entregar. El front lo miraba antes (control_rendicion_cerrado), con una ventana entre
--     ese chequeo y la RPC.
--
-- QUÉ CAMBIA
--   · trg_pedidos_canje_aplicado (nuevo, BEFORE INSERT OR UPDATE OF estado, canal): un canje
--     no pasa a 'entregado' si su recorrido_cambios no tiene aplicado_at. Corre para todos,
--     REST y server: las masivas ya saltean los canjes (416b). Es un trigger y no una RPC
--     que aplique y entregue porque el hueco es la tabla: cualquier RPC se esquiva con un
--     PATCH, y una RPC de entrega tendría que copiar lo que hace la entrega por REST (la
--     fecha, el chofer elegido, quién repartió y los controles de la 443).
--   · crear_pedido_cambio_en_ruta rechaza al cliente dado de baja, con el mensaje de
--     registrar_cambio_producto (416b).
--   · aplicar_cambio_de_parada(p_pedido_id, p_transportista_id, p_fecha): recibe el chofer
--     y el día de la entrega (sin ellos, el chofer del pedido y hoy). Antes de mover nada
--     toma la rendición COMPARTIDA con try, como anular_control_por_cambio_fecha_entrega
--     (443): si alguien la tiene exclusiva (se está confirmando), 40001; si ya quedó
--     controlada, 42501. Después bloquea el pedido y vuelve a mirar aplicado_at, el estado
--     y el chofer: es el orden de la 439 (rendición, pedidos por id, recorridos, pagos), y
--     dos llamadas a la vez ya no aplican el cambio dos veces. Un chofer pasado por
--     parámetro tiene que poder repartir en la sucursal (pedidos_entrega_con_chofer); si
--     el pedido ya tiene otro, la pantalla está vieja (40001).
--     De paso cierra dos huecos que ya estaban: sólo aplica una comanda de canje viva (no
--     un pedido común ni una baja) y de la sucursal activa (un encargado de otra
--     sucursal lo aplicaba por id: es_encargado_o_admin no mira la sucursal).
--     La firma nueva reemplaza a la vieja (DROP, no sobrecarga: PGRST203). Un bundle viejo
--     la llama con sólo p_pedido_id y le toca el chofer del pedido y hoy.
--
-- QUÉ NO CAMBIA
--   _aplicar_cambio_producto (el stock, la merma y la diferencia informativa de #1329), la
--   idempotencia de aplicar_cambio_de_parada, quién puede aplicarlo y los EXECUTE.
--   Si la entrega por REST falla después de aplicar (la rendición se confirmó en el medio),
--   el canje queda aplicado y sin entregar: reintentar no vuelve a mover el stock.
--
-- Ensayo: scripts/test-canje-1343.sql.
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
      ('public.aplicar_cambio_de_parada(bigint)', '06fc3163b8771d418383555cde4b1fe6'),
      ('public.crear_pedido_cambio_en_ruta(integer,bigint,integer,bigint,integer,text,text)', 'da2a12cd0e5eec6e6ca02b8a5cd4f8d1'),
      ('public.anular_control_por_cambio_fecha_entrega()', '00192ce77008c190570037f8a7f3849f'),
      ('public._rendicion_clave(uuid,date,bigint)', '4823d84b9f2ed5027fa1da64dd6e2fee')
    ) AS t(firma, hash)
  LOOP
    IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = r.firma::regprocedure) <> r.hash THEN
      RAISE EXCEPTION '% cambió en prod (md5 %): rehacer el parche sobre el cuerpo vigente',
        r.firma, (SELECT md5(prosrc) FROM pg_proc WHERE oid = r.firma::regprocedure);
    END IF;
  END LOOP;
  IF to_regprocedure('public.aplicar_cambio_de_parada(bigint,uuid,date)') IS NOT NULL
     OR to_regprocedure('public.pedidos_canje_exige_cambio_aplicado()') IS NOT NULL THEN
    RAISE EXCEPTION 'la migración ya está aplicada (o alguien creó las funciones nuevas)';
  END IF;
END
$premisas$;

-- ------------------------------------------------------------------ 1 · trigger ---
CREATE FUNCTION public.pedidos_canje_exige_cambio_aplicado()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- #1343: la comanda de un canje no tiene líneas; lo que mueve el stock es el cambio
  -- (aplicar_cambio_de_parada). Cerrarla sin aplicarlo la daba por hecha sin mover nada.
  -- DEFINER para leer recorrido_cambios sin depender de su RLS (rc_select).
  IF TG_OP = 'UPDATE' AND OLD.estado = 'entregado' AND OLD.canal IS NOT DISTINCT FROM 'cambio' THEN
    RETURN NEW;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM recorrido_cambios
                  WHERE pedido_id = NEW.id AND aplicado_at IS NOT NULL) THEN
    RAISE EXCEPTION 'El canje #% no se puede marcar entregado sin aplicar el cambio de producto: completalo desde el pedido, que mueve el stock y después lo entrega.',
      NEW.id USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.pedidos_canje_exige_cambio_aplicado() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_pedidos_canje_aplicado
  BEFORE INSERT OR UPDATE OF estado, canal ON public.pedidos
  FOR EACH ROW
  WHEN (NEW.canal = 'cambio' AND NEW.estado = 'entregado')
  EXECUTE FUNCTION public.pedidos_canje_exige_cambio_aplicado();

-- ------------------------------------------------- 2 · crear_pedido_cambio_en_ruta ---
CREATE OR REPLACE FUNCTION public.crear_pedido_cambio_en_ruta(p_cliente_id integer, p_producto_devuelto_id bigint, p_cantidad_devuelta integer, p_producto_entregado_id bigint, p_cantidad_entregada integer, p_observaciones text DEFAULT NULL::text, p_motivo text DEFAULT 'erroneo'::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal BIGINT := public.current_sucursal_id();
  v_user UUID := auth.uid();
  v_nombre_devuelto TEXT;
  v_nombre_entregado TEXT;
  v_pedido_id BIGINT;
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'Sin sucursal activa';
  END IF;
  IF NOT public.es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;
  IF p_cantidad_devuelta <= 0 OR p_cantidad_entregada <= 0 THEN
    RAISE EXCEPTION 'Las cantidades deben ser mayores a 0';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM clientes WHERE id = p_cliente_id AND sucursal_id = v_sucursal
  ) THEN
    RAISE EXCEPTION 'Cliente no encontrado en la sucursal';
  END IF;
  -- #1343: un canje es operar, y con un cliente dado de baja no se opera (#1319).
  IF EXISTS (SELECT 1 FROM clientes WHERE id = p_cliente_id AND NOT activo) THEN
    RAISE EXCEPTION 'El cliente está dado de baja: reactivalo desde Clientes para registrarle un cambio de producto.'
      USING ERRCODE = 'P0001';
  END IF;

  SELECT nombre INTO v_nombre_devuelto FROM productos
   WHERE id = p_producto_devuelto_id AND sucursal_id = v_sucursal;
  IF v_nombre_devuelto IS NULL THEN
    RAISE EXCEPTION 'Producto a devolver no encontrado';
  END IF;
  SELECT nombre INTO v_nombre_entregado FROM productos
   WHERE id = p_producto_entregado_id AND sucursal_id = v_sucursal;
  IF v_nombre_entregado IS NULL THEN
    RAISE EXCEPTION 'Producto a entregar no encontrado';
  END IF;

  INSERT INTO pedidos (
    cliente_id, fecha, estado, total, monto_pagado, estado_pago,
    canal, usuario_id, sucursal_id
  ) VALUES (
    p_cliente_id, public._tablero_hoy(), 'pendiente', 0, 0, 'pagado',
    'cambio', v_user, v_sucursal
  ) RETURNING id INTO v_pedido_id;

  INSERT INTO recorrido_cambios (
    pedido_id, cliente_id,
    producto_devuelto_id, producto_devuelto_nombre, cantidad_devuelta,
    producto_entregado_id, producto_entregado_nombre, cantidad_entregada,
    observaciones, sucursal_id, motivo
  ) VALUES (
    v_pedido_id, p_cliente_id,
    p_producto_devuelto_id, v_nombre_devuelto, p_cantidad_devuelta,
    p_producto_entregado_id, v_nombre_entregado, p_cantidad_entregada,
    p_observaciones, v_sucursal, COALESCE(p_motivo,'erroneo')
  );

  RETURN v_pedido_id;
END;
$function$;

-- ---------------------------------------------------- 3 · aplicar_cambio_de_parada ---
DROP FUNCTION public.aplicar_cambio_de_parada(bigint);

CREATE FUNCTION public.aplicar_cambio_de_parada(p_pedido_id bigint, p_transportista_id uuid DEFAULT NULL::uuid, p_fecha date DEFAULT NULL::date)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rc RECORD;
  v_user UUID := auth.uid();
  v_suc BIGINT := public.current_sucursal_id();
  v_cambio_id BIGINT;
  v_autorizado BOOLEAN;
  v_ped RECORD;
  v_ahora RECORD;
  v_chofer UUID;
  v_dia DATE;
BEGIN
  SELECT * INTO v_rc FROM recorrido_cambios WHERE pedido_id = p_pedido_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No hay detalle de cambio para el pedido %', p_pedido_id;
  END IF;

  IF v_rc.aplicado_at IS NOT NULL THEN
    RETURN v_rc.cambio_producto_id;
  END IF;

  -- #1343: el canje es de la sucursal activa (current_sucursal_id ya exige que el que
  -- llama sea de ella): sin esto, un encargado de otra sucursal lo aplicaba por id.
  -- Y es una comanda de canje viva: ni un pedido común ni una baja.
  SELECT canal, estado, transportista_id, sucursal_id INTO v_ped FROM pedidos WHERE id = p_pedido_id;
  IF v_suc IS NULL OR v_ped.sucursal_id IS DISTINCT FROM v_suc THEN
    RAISE EXCEPTION 'El canje #% no es de la sucursal activa: cambiá a su sucursal para completarlo.',
      p_pedido_id USING ERRCODE = '42501';
  END IF;
  IF v_ped.canal IS DISTINCT FROM 'cambio' THEN
    RAISE EXCEPTION 'El pedido #% no es un canje: no tiene cambio de producto que aplicar.', p_pedido_id;
  END IF;
  IF v_ped.estado IN ('cancelado', 'anulado') THEN
    RAISE EXCEPTION 'El canje #% está %: no se aplica el cambio.', p_pedido_id, v_ped.estado;
  END IF;

  v_autorizado := public.es_encargado_o_admin()
    OR EXISTS (
      SELECT 1
      FROM recorrido_pedidos rp
      JOIN recorridos r ON r.id = rp.recorrido_id
      WHERE rp.pedido_id = p_pedido_id
        AND r.transportista_id = v_user
    );
  IF NOT v_autorizado THEN
    RAISE EXCEPTION 'No autorizado para aplicar el cambio';
  END IF;

  -- #1343: el cambio se aplica sólo si la entrega que viene después puede entrar. El día
  -- es el de la entrega: el chofer y la fecha que elige el front, o los del pedido y hoy.
  -- El chofer elegido tiene que poder repartir en la sucursal, la misma regla que
  -- pedidos_entrega_con_chofer: si no, el cambio se aplicaba y la entrega daba 23514.
  IF p_transportista_id IS NOT NULL AND NOT (
       EXISTS (SELECT 1 FROM usuario_sucursales us
                WHERE us.usuario_id = p_transportista_id AND us.sucursal_id = v_suc)
       AND public._actua_como_transportista(p_transportista_id, v_suc)) THEN
    RAISE EXCEPTION 'El transportista elegido no es chofer de esta sucursal: no se aplicó el cambio.' USING ERRCODE = '42501';
  END IF;
  v_chofer := COALESCE(p_transportista_id, v_ped.transportista_id);
  v_dia := COALESCE(p_fecha, public._tablero_hoy());
  IF v_chofer IS NOT NULL THEN
    -- La rendición antes que el pedido (439). El try no espera: si se está confirmando,
    -- que se reintente con el control ya decidido. Mismos estados, try y errores que
    -- anular_control_por_cambio_fecha_entrega (443).
    IF NOT pg_try_advisory_xact_lock_shared(public._rendicion_clave(v_chofer, v_dia, v_ped.sucursal_id)) THEN
      RAISE EXCEPTION 'La rendición del % de ese transportista se está controlando o editando en este momento: volvé a intentar en unos segundos.',
        to_char(v_dia, 'DD/MM/YYYY') USING ERRCODE = '40001';
    END IF;
    IF EXISTS (SELECT 1 FROM rendiciones_control
                WHERE transportista_id = v_chofer AND sucursal_id = v_ped.sucursal_id
                  AND fecha = v_dia AND estado IN ('confirmada', 'resuelta')) THEN
      RAISE EXCEPTION 'La rendición del % de ese transportista ya fue controlada: no se aplicó el cambio. Un encargado o administrador tiene que reabrirla primero desde Rendiciones.',
        to_char(v_dia, 'DD/MM/YYYY') USING ERRCODE = '42501';
    END IF;
  END IF;

  -- El pedido, y con él quieto se vuelve a mirar: dos llamadas a la vez aplicaban el
  -- cambio dos veces. La rendición mirada tiene que ser la de la entrega que viene:
  --   · el chofer del pedido no cambió desde que se leyó (si cambió, tomar su rendición
  --     recién ahora invertiría el orden);
  --   · y si el front manda un chofer y el pedido ya tiene otro, la pantalla está vieja:
  --     la entrega saldría a nombre del del pedido. El front manda uno distinto del del
  --     pedido sólo cuando el pedido no tiene chofer y se elige al confirmar
  --     (necesitaElegirChofer), y ese caso pasa.
  PERFORM 1 FROM pedidos WHERE id = p_pedido_id FOR UPDATE;
  SELECT estado, transportista_id INTO v_ahora FROM pedidos WHERE id = p_pedido_id;
  SELECT * INTO v_rc FROM recorrido_cambios WHERE pedido_id = p_pedido_id;
  IF v_rc.aplicado_at IS NOT NULL THEN
    RETURN v_rc.cambio_producto_id;
  END IF;
  IF v_ahora.estado IN ('cancelado', 'anulado') THEN
    RAISE EXCEPTION 'El canje #% está %: no se aplica el cambio.', p_pedido_id, v_ahora.estado;
  END IF;
  IF v_ahora.transportista_id IS DISTINCT FROM v_ped.transportista_id
     OR (p_transportista_id IS NOT NULL AND v_ahora.transportista_id IS NOT NULL
         AND v_ahora.transportista_id <> p_transportista_id) THEN
    RAISE EXCEPTION 'El canje #% tiene otro transportista que el elegido: actualizá la pantalla y volvé a intentar.',
      p_pedido_id USING ERRCODE = '40001';
  END IF;

  v_cambio_id := public._aplicar_cambio_producto(
    v_rc.cliente_id,
    v_rc.producto_devuelto_id, v_rc.cantidad_devuelta,
    v_rc.producto_entregado_id, v_rc.cantidad_entregada,
    v_rc.observaciones, v_rc.sucursal_id, v_user, COALESCE(v_rc.motivo,'erroneo')
  );

  UPDATE recorrido_cambios
     SET aplicado_at = NOW(), cambio_producto_id = v_cambio_id
   WHERE pedido_id = p_pedido_id;

  RETURN v_cambio_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.aplicar_cambio_de_parada(bigint, uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.aplicar_cambio_de_parada(bigint, uuid, date) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
