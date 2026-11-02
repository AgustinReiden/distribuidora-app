-- ===========================================================================
-- 431a · Edición, regalos y salvedades: lo común (#1323, #1324, #1325, #1326, #1327, #1372)
-- Tarjeta 6 del plan #1308. Son cuatro archivos que se aplican en orden, 431a a 431d:
-- juntos no entran en una sola llamada. Este encabezado es el de los cuatro.
--
-- #1324 · REG-1: el tipo de regalo de un pedido que ya existe es el de su foto.
--   Decisión del dueño (29/10): se puede cambiar el tipo de regalo de una promo
--   con pedidos abiertos, con aviso, y esos pedidos no cambian. Eso obliga a tres
--   cosas, no a una:
--   · las funciones leen el modo de pedido_promo_reglas (_regalo_modo_del_pedido),
--     y sólo si no hay foto, el de la promo viva. También eliminar_pedido_completo,
--     que el issue no nombra y tenía la misma lectura;
--   · la foto no cambia de modo: capturar_promo_del_pedido rehace las reglas en
--     cada edición, pero el modo dice cómo salió el stock de ESTE pedido. Si lo
--     pisara, la edición devolvería con un modo y dejaría escrito otro;
--   · la barra es de la promo viva, y una línea de otro modo no entró en ella:
--     aplicar_uso_promo_acumulador va sólo si los dos modos coinciden
--     (_regalo_barra_vale). Sin esto, cancelar un regalo de unidad entera en una
--     promo que pasó a fracción deshacía un bloque y devolvía un fardo fantasma;
--   · al pasar a fracción, la barra arranca en 0 (trg_promo_tipo_reinicia_barra): en
--     unidad entera usos_pendientes es un contador que nunca se cierra, y heredado
--     como barra cerraba bloques y mermaba mercadería que ya había salido entera;
--   · el factor de la línea también es de la foto: la edición y la sustitución no lo
--     rehacen con la promo viva, o los reportes dividen mal el costo del regalo;
--   · una foto sin regalo vivo no dice cómo salió nada: la edición que vuelve a
--     agregar el regalo arranca con el modo vivo;
--   · si además cambió la regla, la edición no recalcula el regalo con el modo viejo:
--     12 botellas de la regla nueva no son 12 fardos. Se rechaza.
--
-- #1323 · PED-2: el pre-chequeo de stock suma por producto todo lo que baja
--   stock (venta, combo y regalo que mueve stock) contra lo mismo del pedido.
--   PED-6: concurrencia optimista con p_updated_at_esperado. La firma cambia: se
--   dropea la vieja. Un bundle viejo no manda el parámetro y sigue andando.
--   PED-5: la comanda de un canje no se edita.
--
-- #1325 · REG-2: la salvedad y las dos simulaciones miden el regalo en cortes
--   (regalo_usos_de_linea, no pi.cantidad), y el recorte se pasa a la unidad de
--   la línea con la misma cadena que la sustitución (_regalo_recorte).
--   regalo_usos_de_linea invierte la cadena eslabón por eslabón, hasta el último
--   reparto: con el primero y el último, una línea movida entre dos eslabones valía
--   de más (A×4 -> B×2 -> C×2 valía 4), y el recorte no la bajaba nunca.
--   REG-3: una sola conversión, regalo_cantidad_tras_eslabon, con espejo en
--   cantidadTrasEslabon. El server dejaba de escalar dentro de una misma
--   categoría y empaque, y la pantalla no: mostraba B×12 y se guardaba B×8. Queda
--   la proporción del eslabón, que es además la inversa que usa
--   regalo_usos_de_linea para el cupo. Hoy hay 3 eslabones con cantidades
--   distintas en todo prod. Con esto, el guard (c) de dividir_regalo_pedido queda
--   cubierto por el (a) y se saca.
--
-- #1326 · REG-4: sustituir y dividir bloquean sus productos juntos, ORDER BY id,
--   antes de mover el primero. Es el molde de #1296.
-- #1375, punto 1: los contenedores que mueve el motor de promos entran en ese
--   mismo lock (_contenedores_de_promos), en cancelar, editar, sustituir y dividir.
--   registrar_salvedad, que bloqueaba el producto de la línea y después el regalo
--   y su contenedor, también. Los puntos 2 y 3 de #1375 no son de estas funciones.
--
-- #1327 · SAL-1: registrar_salvedad y anular_salvedad con el guard de caja de
--   cambiar_tipo_factura_pedido (_pedido_en_caja_cerrada). En los últimos 90 días
--   no habría frenado ninguna de las 212 salvedades. Va para todos los roles y mira
--   la caja de la sucursal: la salida es reabrir las rendiciones hasta esa fecha.
--   SAL-2 es del front, y SAL-3 también: la clave de la salvedad ya no sale del
--   contenido, así que acá un reintento con otro contenido contesta que ya se
--   registró, en vez de darla por hecha.
--
--   Y cancelar_pedido_con_stock corta el día de la entrega en Argentina: entre las
--   21 y las 24, `fecha_entrega::date` era el día siguiente, y un vale blanco de una
--   caja cerrada se podía cancelar (#1277; sale de fechas-utc-permitidas.json).
--
-- #1372 · Decisión del dueño (02/11): la edición devuelve el pedido a pendiente en
--   una sola transacción (volver_pedido_a_pendiente_por_edicion), y el preventista
--   dueño puede hacerlo dentro de las reglas de preventistaPuedeEditar, validadas
--   acá (_preventista_en_ventana, el cuarto lugar del corte de las 15:30: ver
--   src/utils/permisosPedido.ts). Lo que hace, sacarlo de la ruta incluido, es
--   _pedido_a_pendiente, el cuerpo de volver_pedido_a_pendiente sin copiarlo: esa
--   sigue siendo de admin y encargado. quitar_pedido_de_recorridos_activos no cambia.
--
-- Nueva: promo_pedidos_abiertos, el aviso de ModalPromocion.
-- ===========================================================================


BEGIN;

-- ---------------------------------------------------------------------------
-- Premisas: nada cambió en prod desde que se leyeron los cuerpos
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, md5(pg_get_functiondef(x.firma::regprocedure)) AS md5_vivo
      FROM (VALUES
        ('public.capturar_promo_del_pedido()',
         '50492613569f798a2893e2ac98d5b689'),
        ('public.regalo_sustitucion_resuelta(bigint,bigint,bigint,bigint,numeric,uuid)',
         '6775096cfd67f27f40a0d264ec14a681'),
        ('public.regalo_usos_de_linea(jsonb,uuid,numeric)',
         '8087da2e6b6074037c5e6ae39b617088'),
        ('public.simular_salvedad_promo_impacto(bigint,bigint,integer)',
         '11a9f5e56f939891ff0a1857b34f1b18'),
        ('public.simular_salvedades_promo_impacto(bigint,jsonb)',
         '9a0e6155da2158953169c74f408b593f'),
        ('public.volver_pedido_a_pendiente(bigint)',
         '5080d245d9cd02a0abcef6332cf768c7')
      ) AS x(firma, md5)
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION 'mig 431a · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 1 · Helpers
-- ---------------------------------------------------------------------------

-- #1324: cómo sale el stock del regalo de una promo en ESTE pedido. La foto, y
-- sólo sin foto (un regalo nuevo en la edición), la promo viva. NULL si no hay
-- ninguna de las dos: cada llamador conserva su default.
CREATE FUNCTION public._regalo_modo_del_pedido(p_pedido_id bigint, p_promocion_id bigint, p_sucursal_id bigint)
RETURNS boolean
LANGUAGE sql STABLE
SET search_path TO 'public'
AS $function$
  SELECT COALESCE(
    (SELECT f.regalo_mueve_stock FROM pedido_promo_reglas f
      WHERE f.pedido_id = p_pedido_id AND f.promocion_id = p_promocion_id
        AND f.sucursal_id = p_sucursal_id),
    (SELECT p.regalo_mueve_stock FROM promociones p
      WHERE p.id = p_promocion_id AND p.sucursal_id = p_sucursal_id));
$function$;

-- #1324: la barra (promociones.usos_pendientes, promo_acumuladores) es de la promo
-- viva. Una línea cuyo modo no es el vivo no entró en ella, o entró en otra.
CREATE FUNCTION public._regalo_barra_vale(p_pedido_id bigint, p_promocion_id bigint, p_sucursal_id bigint)
RETURNS boolean
LANGUAGE sql STABLE
SET search_path TO 'public'
AS $function$
  SELECT COALESCE(
    (SELECT COALESCE(public._regalo_modo_del_pedido(p_pedido_id, p_promocion_id, p_sucursal_id), false)
              = COALESCE(p.regalo_mueve_stock, false)
       FROM promociones p
      WHERE p.id = p_promocion_id AND p.sucursal_id = p_sucursal_id),
    false);
$function$;

-- #1325 · REG-3: la cantidad que sigue a un eslabón. Una sola regla, y con espejo:
-- cantidadTrasEslabon (src/utils/repartoRegalo.ts) y cadenaSustitucion.espejo.json.
CREATE FUNCTION public.regalo_cantidad_tras_eslabon(p_cantidad numeric, p_original numeric, p_sustituta numeric)
RETURNS numeric
LANGUAGE sql IMMUTABLE
SET search_path TO 'public'
AS $function$
  SELECT CASE
           WHEN p_cantidad IS NULL OR COALESCE(p_original, 0) <= 0 OR p_sustituta IS NULL THEN p_cantidad
           WHEN p_cantidad = p_original THEN p_sustituta
           WHEN p_sustituta = p_original THEN p_cantidad
           ELSE GREATEST(1, round(p_cantidad * p_sustituta / p_original))
         END;
$function$;

-- #1325: el corte de una línea. Deshace la cadena desde el final, eslabón por
-- eslabón, hasta el último reparto, que es donde arranca el corte de una parte. La
-- línea se pudo mover entre dos eslabones (una salvedad, la edición): la proporción
-- de cada uno se aplica a lo que había en ese momento.
CREATE OR REPLACE FUNCTION public.regalo_usos_de_linea(p_eslabones jsonb, p_cadena uuid, p_cantidad numeric)
 RETURNS bigint
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cant numeric := p_cantidad;
  r      record;
BEGIN
  IF p_cadena IS NOT NULL THEN
    FOR r IN
      SELECT x
        FROM jsonb_array_elements(COALESCE(p_eslabones, '[]'::jsonb)) x
       WHERE (x->>'cadena_id')::uuid = p_cadena
       ORDER BY (x->>'id')::bigint DESC
    LOOP
      EXIT WHEN r.x->>'reparto_id' IS NOT NULL;
      v_cant := public.regalo_cantidad_tras_eslabon(
        v_cant, (r.x->>'cantidad_sustituta')::numeric, (r.x->>'cantidad_original')::numeric);
    END LOOP;
  END IF;
  RETURN round(v_cant)::bigint;
END;
$function$;

-- #1324: al pasar de unidad entera a fracción, la barra arranca en 0. En unidad
-- entera usos_pendientes cuenta los usos y nunca se cierra: esas unidades ya
-- salieron enteras, y heredadas como barra cerraban bloques (y el trigger de
-- renormalización los mermaba) por mercadería que no salió dos veces. Va antes que
-- ese trigger, que relee la fila.
CREATE FUNCTION public.promo_tipo_reinicia_barra()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  NEW.usos_pendientes := 0;
  UPDATE promo_acumuladores
     SET usos_pendientes = 0, updated_at = now()
   WHERE promocion_id = NEW.id AND sucursal_id = NEW.sucursal_id AND usos_pendientes <> 0;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_promo_tipo_reinicia_barra
  BEFORE UPDATE OF regalo_mueve_stock ON public.promociones
  FOR EACH ROW
  WHEN (OLD.regalo_mueve_stock IS TRUE AND NEW.regalo_mueve_stock IS FALSE)
  EXECUTE FUNCTION public.promo_tipo_reinicia_barra();

-- #1325 · REG-2: reparte un exceso medido en cortes entre las líneas de regalo de
-- una promo, de la más nueva a la más vieja, y dice cuánto queda en cada una, en
-- la unidad de la línea. Una línea cambiada por valor (A×4 -> P×19) vale 4: si le
-- sacan 2, quedan 2 de A, que recorridos por su cadena son P×10. Es la cuenta de
-- registrar_salvedad y de las dos simulaciones. p_cantidades pisa la cantidad de
-- las líneas ({item_id: cantidad}), para simular un lote. Devuelve sólo las líneas
-- que bajan.
CREATE FUNCTION public._regalo_recorte(
  p_pedido_id bigint, p_promocion_id bigint, p_sucursal_id bigint, p_exceso numeric,
  p_cantidades jsonb DEFAULT NULL)
RETURNS TABLE(pedido_item_id bigint, producto_id bigint, cantidad integer, cantidad_final integer)
LANGUAGE plpgsql STABLE
SET search_path TO 'public'
AS $function$
DECLARE
  v_eslabones jsonb := public.regalo_eslabones(p_pedido_id, p_promocion_id, p_sucursal_id);
  v_resto     numeric := COALESCE(p_exceso, 0);
  v_cant      integer;
  v_corte     numeric;
  v_saca      numeric;
  v_final     numeric;
  r           record;
BEGIN
  FOR r IN
    SELECT pi.id, pi.producto_id, pi.cantidad, pi.regalo_cadena_id
      FROM pedido_items pi
     WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = p_sucursal_id
       AND COALESCE(pi.es_bonificacion, false) AND pi.promocion_id = p_promocion_id
     ORDER BY pi.id DESC
  LOOP
    EXIT WHEN v_resto <= 0;
    v_cant := COALESCE((p_cantidades->>(r.id::text))::integer, r.cantidad);
    CONTINUE WHEN v_cant <= 0;

    v_corte := public.regalo_usos_de_linea(v_eslabones, r.regalo_cadena_id, v_cant);
    v_saca  := LEAST(v_corte, v_resto);
    v_resto := v_resto - v_saca;

    IF v_saca >= v_corte THEN
      v_final := 0;
    ELSE
      SELECT x.cantidad INTO v_final
        FROM public.regalo_sustitucion_resuelta(
               p_pedido_id, p_promocion_id,
               COALESCE(public.regalo_raiz_de_eslabones(v_eslabones, r.producto_id, r.regalo_cadena_id),
                        r.producto_id),
               p_sucursal_id, v_corte - v_saca, r.regalo_cadena_id) x;
      -- El redondeo de la cadena nunca sube la línea.
      v_final := LEAST(v_final, v_cant);
    END IF;

    IF v_final < v_cant THEN
      pedido_item_id := r.id;
      producto_id    := r.producto_id;
      cantidad       := v_cant;
      cantidad_final := v_final::integer;
      RETURN NEXT;
    END IF;
  END LOOP;
END;
$function$;

-- #1375: los productos que el motor de promos puede mover además de las líneas: el
-- contenedor de la barra default y el de cada sabor. Una función que baja por
-- aplicar_uso_promo_acumulador los bloquea junto con sus productos, por id.
CREATE FUNCTION public._contenedores_de_promos(p_promos bigint[], p_sucursal_id bigint)
RETURNS SETOF bigint
LANGUAGE sql STABLE
SET search_path TO 'public'
AS $function$
  SELECT p.ajuste_producto_id FROM promociones p
   WHERE p.id = ANY (p_promos) AND p.sucursal_id = p_sucursal_id AND p.ajuste_producto_id IS NOT NULL
  UNION
  SELECT a.ajuste_producto_id FROM promo_acumuladores a
   WHERE a.promocion_id = ANY (p_promos) AND a.sucursal_id = p_sucursal_id AND a.ajuste_producto_id IS NOT NULL;
$function$;

-- #1327 · SAL-1: el criterio de cambiar_tipo_factura_pedido. El mensaje, o NULL si
-- el pedido no cae en una caja cerrada. Se pregunta con el pedido bloqueado.
CREATE FUNCTION public._pedido_en_caja_cerrada(p_pedido_id bigint, p_sucursal_id bigint)
RETURNS text
LANGUAGE sql STABLE
SET search_path TO 'public'
AS $function$
  SELECT format('El pedido se entregó el %s y la caja está cerrada hasta el %s: para cambiarlo hay que reabrir las rendiciones hasta esa fecha.',
                to_char(x.dia, 'DD/MM/YYYY'), to_char(x.limite, 'DD/MM/YYYY'))
    FROM (SELECT (p.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date AS dia,
                 public.ultima_fecha_caja_cerrada(p_sucursal_id) AS limite
            FROM pedidos p
           WHERE p.id = p_pedido_id AND p.sucursal_id = p_sucursal_id
             AND p.estado = 'entregado' AND p.fecha_entrega IS NOT NULL) x
   WHERE x.dia <= x.limite;
$function$;

-- #1372: la ventana del preventista para tocar su pedido: el día que lo cargó, en
-- Argentina, antes de las 15:30. Espejo de preventistaPuedeEditar
-- (src/utils/permisosPedido.ts).
CREATE FUNCTION public._preventista_en_ventana(p_creado timestamptz, p_ahora timestamptz DEFAULT now())
RETURNS boolean
LANGUAGE sql STABLE
SET search_path TO 'public'
AS $function$
  SELECT COALESCE(
    (p_creado AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
      = (p_ahora AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
    AND (p_ahora AT TIME ZONE 'America/Argentina/Buenos_Aires')::time < TIME '15:30',
    false);
$function$;

-- #1372: el pedido vuelve a pendiente y sale de la ruta en curso, todo en la
-- transacción del que llama. Es de server: el permiso lo mira cada RPC. El que
-- llama ya bloqueó el pedido y pasa su estado.
CREATE FUNCTION public._pedido_a_pendiente(p_pedido_id bigint, p_sucursal_id bigint, p_estado text)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'public'
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

-- #1372: la edición que le cambia la fecha a un pedido en camino. Lo mismo que
-- volver_pedido_a_pendiente (420), con otro quién: además de admin y encargado, el
-- preventista dueño dentro de su ventana. Un preventista puede hacerlo con la ruta
-- en curso: es decisión del dueño. Lo que no puede es cambiar las líneas
-- (actualizar_pedido_items).
CREATE FUNCTION public.volver_pedido_a_pendiente_por_edicion(p_pedido_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_pedido   RECORD;
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  SELECT estado, usuario_id, created_at INTO v_pedido
    FROM pedidos
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal
     FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'El pedido #% no existe en esta sucursal', p_pedido_id
      USING ERRCODE = 'P0002';
  END IF;

  IF NOT es_encargado_o_admin() THEN
    IF NOT es_preventista() OR v_pedido.usuario_id IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION 'Sólo el preventista que cargó el pedido, un encargado o un admin pueden cambiarle la fecha'
        USING ERRCODE = '42501';
    END IF;
    IF NOT public._preventista_en_ventana(v_pedido.created_at) THEN
      RAISE EXCEPTION 'Como preventista sólo podés cambiar pedidos del día actual antes de las 15:30'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  RETURN public._pedido_a_pendiente(p_pedido_id, v_sucursal, v_pedido.estado);
END;
$function$;

-- #1324: el aviso de ModalPromocion. Es invoker a propósito: la RLS de pedidos ya
-- acota a la sucursal y al rol.
CREATE FUNCTION public.promo_pedidos_abiertos(p_promocion_id bigint)
RETURNS integer
LANGUAGE sql STABLE
SET search_path TO 'public'
AS $function$
  SELECT count(DISTINCT pi.pedido_id)::integer
    FROM pedido_items pi
    JOIN pedidos p ON p.id = pi.pedido_id
   WHERE pi.promocion_id = p_promocion_id
     AND COALESCE(pi.es_bonificacion, false)
     AND p.estado NOT IN ('entregado', 'cancelado', 'anulado');
$function$;

-- Los nueve primeros son de server: los llaman funciones definer. La pura va
-- además por REST para el gate de espejo, como las demás, sólo con service_role.
REVOKE ALL ON FUNCTION public._regalo_modo_del_pedido(bigint, bigint, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._regalo_barra_vale(bigint, bigint, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.regalo_cantidad_tras_eslabon(numeric, numeric, numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._regalo_recorte(bigint, bigint, bigint, numeric, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._pedido_en_caja_cerrada(bigint, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._contenedores_de_promos(bigint[], bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._preventista_en_ventana(timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._pedido_a_pendiente(bigint, bigint, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.promo_tipo_reinicia_barra() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.volver_pedido_a_pendiente_por_edicion(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.volver_pedido_a_pendiente_por_edicion(bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.regalo_cantidad_tras_eslabon(numeric, numeric, numeric) TO service_role;
REVOKE ALL ON FUNCTION public.promo_pedidos_abiertos(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.promo_pedidos_abiertos(bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2 · Las dos simulaciones (#1325): la cuenta de registrar_salvedad, en cortes
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.simular_salvedad_promo_impacto(p_pedido_id bigint, p_pedido_item_id bigint, p_cantidad_afectada integer)
 RETURNS TABLE(promocion_id bigint, promo_nombre text, bonif_actual integer, bonif_esperada integer, delta integer, descripcion_regalo text, sera_eliminada boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_item RECORD;
BEGIN
  IF v_sucursal IS NULL OR p_cantidad_afectada IS NULL OR p_cantidad_afectada <= 0 THEN
    RETURN;
  END IF;

  SELECT pi.id, pi.producto_id, pi.cantidad, COALESCE(pi.es_bonificacion, FALSE) AS es_bonificacion
    INTO v_item
    FROM pedido_items pi
   WHERE pi.id = p_pedido_item_id
     AND pi.pedido_id = p_pedido_id
     AND pi.sucursal_id = v_sucursal
     -- #1009: sólo sobre un pedido que el caller puede leer.
     AND public.puede_leer_pedido(p_pedido_id);

  IF v_item IS NULL OR v_item.es_bonificacion THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH bonifs AS (
    -- mig 275 (#831): agregado por promo. Un regalo repartido en sabores son
    -- varias lineas y el esperado es de la promo entera.
    -- #1325: `cantidad` es la unidad de las lineas, y `corte` la de la promo.
    SELECT pi.promocion_id, SUM(pi.cantidad)::INT AS cantidad,
           SUM(public.regalo_usos_de_linea(
                 CASE WHEN pi.regalo_cadena_id IS NOT NULL
                      THEN public.regalo_eslabones(p_pedido_id, pi.promocion_id, v_sucursal) END,
                 pi.regalo_cadena_id, pi.cantidad))::INT AS corte
      FROM pedido_items pi
     WHERE pi.pedido_id = p_pedido_id
       AND pi.sucursal_id = v_sucursal
       AND COALESCE(pi.es_bonificacion, FALSE) = TRUE
       AND pi.promocion_id IS NOT NULL
     GROUP BY pi.promocion_id
  ),
  promo_info AS (
    SELECT
      b.cantidad AS bonif_qty,
      b.corte AS bonif_corte,
      b.promocion_id,
      p.nombre AS promo_nombre,
      p.descripcion_regalo,
      -- #1164: las reglas y los productos de la foto del pedido.
      h.cantidad_compra AS cant_compra,
      h.cantidad_bonificacion AS cant_bonif,
      h.productos
    FROM bonifs b
    JOIN promociones p ON p.id = b.promocion_id AND p.sucursal_id = v_sucursal
    JOIN public.promos_del_pedido(p_pedido_id) h ON h.promocion_id = b.promocion_id
    -- #1141: el alcance de registrar_salvedad (y de v_toca_promo).
    WHERE v_item.producto_id = ANY (h.productos)
  ),
  totales AS (
    SELECT
      pm.promocion_id,
      SUM(
        CASE
          WHEN pi.id = p_pedido_item_id THEN GREATEST(pi.cantidad - p_cantidad_afectada, 0)
          ELSE pi.cantidad
        END
      )::INT AS total_qty_post
    FROM promo_info pm
    JOIN pedido_items pi
      ON pi.pedido_id = p_pedido_id
     AND pi.sucursal_id = v_sucursal
     AND COALESCE(pi.es_bonificacion, FALSE) = FALSE
     AND pi.producto_id = ANY (pm.productos)
    GROUP BY pm.promocion_id
  ),
  excesos AS (
    SELECT
      pi.promocion_id,
      pi.promo_nombre::TEXT AS promo_nombre,
      pi.bonif_qty,
      pi.descripcion_regalo,
      -- #1141: LEAST(bonif - esperado_despues, esperado_antes - esperado_despues).
      -- #1325: en cortes. NULLIF como antes: el orden de evaluacion de los filtros
      -- no esta garantizado si el planner empuja `exceso > 0` adentro.
      LEAST(pi.bonif_corte - (COALESCE(t.total_qty_post, 0) / NULLIF(pi.cant_compra, 0)) * pi.cant_bonif,
            ((COALESCE(t.total_qty_post, 0) + p_cantidad_afectada) / NULLIF(pi.cant_compra, 0)) * pi.cant_bonif
              - (COALESCE(t.total_qty_post, 0) / NULLIF(pi.cant_compra, 0)) * pi.cant_bonif)::INT AS exceso
    FROM promo_info pi
    LEFT JOIN totales t ON t.promocion_id = pi.promocion_id
    WHERE pi.cant_compra IS NOT NULL AND pi.cant_compra > 0
      AND pi.cant_bonif  IS NOT NULL AND pi.cant_bonif  > 0
  )
  SELECT
    e.promocion_id,
    e.promo_nombre,
    e.bonif_qty AS bonif_actual,
    e.bonif_qty - c.recorte AS bonif_esperada,
    c.recorte AS delta,
    e.descripcion_regalo,
    (e.bonif_qty - c.recorte) = 0 AS sera_eliminada
  FROM excesos e
  CROSS JOIN LATERAL (
    SELECT COALESCE(SUM(r.cantidad - r.cantidad_final), 0)::INT AS recorte
      FROM public._regalo_recorte(p_pedido_id, e.promocion_id, v_sucursal, e.exceso) r
  ) c
  WHERE e.exceso > 0 AND c.recorte > 0;
END;
$function$;

CREATE OR REPLACE FUNCTION public.simular_salvedades_promo_impacto(p_pedido_id bigint, p_salvedades jsonb)
 RETURNS TABLE(pedido_item_id bigint, promocion_id bigint, promo_nombre text, producto_id bigint, producto_nombre text, descripcion_regalo text, cantidad_actual integer, cantidad_final integer, delta integer, sera_eliminada boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH afectadas AS (
    SELECT (e->>'pedido_item_id')::BIGINT AS item_id,
           GREATEST(COALESCE((e->>'cantidad_afectada')::INT, 0), 0) AS cant
      FROM jsonb_array_elements(COALESCE(p_salvedades, '[]'::jsonb)) e
     WHERE (e->>'pedido_item_id') IS NOT NULL
  ),
  items AS (
    SELECT pi.id, pi.producto_id, pi.cantidad, pi.promocion_id,
           pi.descripcion_regalo, pi.regalo_cadena_id,
           COALESCE(pi.es_bonificacion, FALSE) AS es_bonif,
           GREATEST(pi.cantidad - COALESCE(a.cant, 0), 0)::INT AS cantidad_post
      FROM pedido_items pi
      LEFT JOIN afectadas a ON a.item_id = pi.id
     WHERE pi.pedido_id = p_pedido_id
       AND pi.sucursal_id = current_sucursal_id()
       -- #1009: sólo sobre un pedido que el caller puede leer.
       AND public.puede_leer_pedido(p_pedido_id)
  ),
  -- #1164: las promos del pedido, con las reglas y los productos de su foto.
  reglas AS (
    SELECT p.id AS promocion_id, p.nombre, p.descripcion_regalo,
           h.cantidad_compra AS cant_compra, h.cantidad_bonificacion AS cant_bonif, h.productos
      FROM public.promos_del_pedido(p_pedido_id) h
      JOIN promociones p ON p.id = h.promocion_id AND p.sucursal_id = current_sucursal_id()
  ),
  totales AS (
    SELECT r.promocion_id, SUM(i.cantidad_post)::INT AS qty_post,
           SUM(i.cantidad)::INT AS qty_pre
      FROM reglas r
      JOIN items i ON NOT i.es_bonif AND i.producto_id = ANY (r.productos)
     GROUP BY r.promocion_id
  ),
  -- #1141: el alcance de registrar_salvedad: las promos que tienen el
  -- producto de alguna linea afectada que no es regalo.
  tocadas AS (
    SELECT DISTINCT r.promocion_id
      FROM reglas r
      JOIN items i ON NOT i.es_bonif AND i.producto_id = ANY (r.productos)
      JOIN afectadas a ON a.item_id = i.id AND a.cant > 0
  ),
  -- #1325: el regalo de cada promo en cortes, despues de las salvedades del lote
  -- que caen sobre el regalo mismo.
  cortes AS (
    SELECT b.promocion_id,
           SUM(CASE WHEN b.cantidad_post > 0
                    THEN public.regalo_usos_de_linea(
                           CASE WHEN b.regalo_cadena_id IS NOT NULL
                                THEN public.regalo_eslabones(p_pedido_id, b.promocion_id, current_sucursal_id()) END,
                           b.regalo_cadena_id, b.cantidad_post)
                    ELSE 0 END) AS corte_post
      FROM items b
     WHERE b.es_bonif AND b.promocion_id IS NOT NULL
     GROUP BY b.promocion_id
  ),
  excesos AS (
    SELECT r.promocion_id,
           LEAST(c.corte_post - (COALESCE(t.qty_post, 0) / r.cant_compra) * r.cant_bonif,
                 (COALESCE(t.qty_pre, 0) / r.cant_compra) * r.cant_bonif
                 - (COALESCE(t.qty_post, 0) / r.cant_compra) * r.cant_bonif) AS exceso
      FROM reglas r
      JOIN tocadas tc ON tc.promocion_id = r.promocion_id
      JOIN cortes c ON c.promocion_id = r.promocion_id
      LEFT JOIN totales t ON t.promocion_id = r.promocion_id
     WHERE COALESCE(r.cant_compra, 0) > 0 AND COALESCE(r.cant_bonif, 0) > 0
  ),
  -- mig 275 (#831): el exceso es de la PROMO y se descuenta de la linea mas nueva
  -- hacia atras (_regalo_recorte).
  recortes AS (
    SELECT rc.pedido_item_id, rc.cantidad_final
      FROM excesos e
     CROSS JOIN LATERAL public._regalo_recorte(
             p_pedido_id, e.promocion_id, current_sucursal_id(), e.exceso,
             (SELECT jsonb_object_agg(i.id::text, i.cantidad_post) FROM items i WHERE i.es_bonif)) rc
     WHERE e.exceso > 0
  ),
  calculo AS (
    SELECT
      b.id,
      b.promocion_id,
      r.nombre,
      b.producto_id,
      prod.nombre AS producto_nombre,
      COALESCE(b.descripcion_regalo, r.descripcion_regalo) AS desc_regalo,
      b.cantidad,
      COALESCE(rc.cantidad_final, b.cantidad_post)::INT AS cantidad_final
      FROM items b
      LEFT JOIN reglas r ON r.promocion_id = b.promocion_id
      LEFT JOIN recortes rc ON rc.pedido_item_id = b.id
      LEFT JOIN productos prod ON prod.id = b.producto_id
     WHERE b.es_bonif
  )
  SELECT
    c.id                             AS pedido_item_id,
    c.promocion_id,
    c.nombre::TEXT                   AS promo_nombre,
    c.producto_id,
    c.producto_nombre::TEXT,
    c.desc_regalo::TEXT              AS descripcion_regalo,
    c.cantidad                       AS cantidad_actual,
    c.cantidad_final,
    (c.cantidad - c.cantidad_final)  AS delta,
    (c.cantidad_final = 0)           AS sera_eliminada
  FROM calculo c
  ORDER BY c.id;
$function$;

-- ---------------------------------------------------------------------------
-- Parches por ancla
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _n_parche (firma text, orden int, ancla text, reemplazo text, veces int DEFAULT 1) ON COMMIT DROP;

INSERT INTO _n_parche (firma, orden, ancla, reemplazo) VALUES
('public.capturar_promo_del_pedido()', 1,
$a$         regalo_mueve_stock    = EXCLUDED.regalo_mueve_stock,
$a$,
$r$         -- #1324: regalo_mueve_stock no se pisa. Dice como salio el stock de este
         -- pedido, y la edicion devuelve y vuelve a bajar con ese mismo modo.
$r$),

('public.capturar_promo_del_pedido()', 2,
$a$                        AND o.promocion_id = NEW.promocion_id);
$a$,
$r$                        AND o.promocion_id = NEW.promocion_id)
     -- #1324: con la promo de otro modo la foto entera se queda: la regla es parte
     -- de como se armo este regalo, y es contra lo que se mide si se puede recalcular.
     AND pedido_promo_reglas.regalo_mueve_stock IS NOT DISTINCT FROM EXCLUDED.regalo_mueve_stock;
$r$),

('public.regalo_sustitucion_resuelta(bigint,bigint,bigint,bigint,numeric,uuid)', 1,
$a$  -- Contenedor del nodo, para su factor (mig 295).
  v_ajuste    bigint  := p_producto_id;
$a$,
''),

('public.regalo_sustitucion_resuelta(bigint,bigint,bigint,bigint,numeric,uuid)', 2,
$a$    -- La cantidad, con la regla de la 295 aplicada a este eslabon.
    IF v_cant IS NOT NULL AND COALESCE(v_s.cantidad_original, 0) > 0
       AND v_s.cantidad_sustituta IS NOT NULL THEN
      IF v_cant = v_s.cantidad_original THEN
        v_cant := v_s.cantidad_sustituta;
      ELSIF NOT public.regalo_misma_categoria(v_nodo, v_s.producto_sustituto_id, p_sucursal_id)
            OR public.factor_regalo_de_linea(p_promocion_id, v_nodo, p_sucursal_id, v_ajuste)
               IS DISTINCT FROM
               public.factor_regalo_de_linea(p_promocion_id, v_s.producto_sustituto_id, p_sucursal_id,
                                             COALESCE(v_s.ajuste_producto_id_nuevo, v_s.producto_sustituto_id)) THEN
        v_cant := GREATEST(1, round(v_cant * v_s.cantidad_sustituta / v_s.cantidad_original));
      END IF;
    END IF;

    v_nodo   := v_s.producto_sustituto_id;
    v_ajuste := COALESCE(v_s.ajuste_producto_id_nuevo, v_s.producto_sustituto_id);
$a$,
$r$    -- #1325: la conversion tiene espejo en el front.
    v_cant := public.regalo_cantidad_tras_eslabon(v_cant, v_s.cantidad_original, v_s.cantidad_sustituta);

    v_nodo   := v_s.producto_sustituto_id;
$r$),

('public.volver_pedido_a_pendiente(bigint)', 1,
$a$  v_estado   TEXT;
  v_paradas  BIGINT[];
  v_rutas    BIGINT[];
  v_rid      BIGINT;
BEGIN
$a$,
$r$  v_estado   TEXT;
BEGIN
$r$),

('public.volver_pedido_a_pendiente(bigint)', 2,
$a$  IF v_estado = 'entregado' THEN
    RAISE EXCEPTION 'El pedido #% ya está entregado: para deshacerlo usá "Revertir entrega"', p_pedido_id;
  END IF;
  IF v_estado NOT IN ('pendiente', 'en_preparacion', 'asignado') THEN
    RAISE EXCEPTION 'El pedido #% está % y no vuelve a pendiente', p_pedido_id, v_estado;
  END IF;

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
    AND rp.sucursal_id = v_sucursal
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
$a$,
$r$  RETURN public._pedido_a_pendiente(p_pedido_id, v_sucursal, v_estado);
END;
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
        RAISE EXCEPTION 'mig 431a · % parche %: el ancla aparece % vez/veces y se esperaba %',
          v_f.firma, v_p.orden, v_n, v_p.veces;
      END IF;
      v_def := replace(v_def, v_p.ancla, v_p.reemplazo);
    END LOOP;
    EXECUTE v_def;
  END LOOP;
END
$parches$;

COMMIT;
