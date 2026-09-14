-- =========================================================================
-- Migración 233: cada uno escribe lo suyo
--
-- Issue #549 (los residuales que la 219 dejó a propósito) + los cinco agujeros
-- de escritura que la auditoría adversarial encontró alrededor. Todos son el
-- mismo error, repetido en seis tablas: **la policy autoriza por ROL y por
-- SUCURSAL, y nunca por PERTENENCIA**. `es_preventista()` es true también para
-- admin y encargado (trampa 4 de CLAUDE.md), así que "preventista de la
-- sucursal" no acota casi nada, y ninguna de estas tablas tenía un guard de
-- columnas que compensara.
--
-- Ninguno de estos caminos lo ofrece la UI. Todos los habilita el token del
-- usuario por PostgREST, sin pasar por ningún RPC.
--
-- ---------------------------------------------------------------------------
-- 1 · pedido_items: el SELECT miraba el pedido padre; el INSERT y el UPDATE no
-- ---------------------------------------------------------------------------
-- `mt_pedido_items_select` ya exigía ser encargado/admin, el vendedor o el
-- chofer DEL PEDIDO. Sus hermanos de escritura eran `es_preventista() AND
-- sucursal_id = current_sucursal_id()` pelado: un preventista podía hacer
-- `PATCH /pedido_items?id=eq.N` sobre items de pedidos YA ENTREGADOS de OTRO
-- vendedor y cambiarles `cantidad` y `precio_unitario`, fuera de la ventana que
-- `actualizar_pedido_items` controla.
--
-- La asimetría es la misma que dejó pasar el agujero de la 219: la lectura
-- estaba bien, la escritura no, y como nadie escribe por ahí desde el front
-- nadie lo vio. Lo que cuelga de `pedido_items` es plata:
-- `calcular_comisiones`, `avance_metas_preventista`, `reporte_gerencial` y
-- `reporte_rentabilidad` leen esta tabla.
--
-- Dos capas, como en la 190 §4 y la 219:
--   * la RLS acota QUÉ FILAS (las de mis pedidos), y
--   * el trigger acota QUÉ COLUMNAS, porque la RLS sola deja que un vendedor se
--     reescriba el precio de sus PROPIOS items ya entregados — que también es
--     plata, sólo que la suya.
--
-- El transportista queda fuera de la escritura a propósito: lee (para saber qué
-- entregar) pero no escribe. Hoy tampoco escribe — no hay un solo
-- `.from('pedido_items').update(...)` en el front.
--
-- ---------------------------------------------------------------------------
-- 2 · pedido_historial: la auditoría la podía escribir cualquiera
-- ---------------------------------------------------------------------------
-- `mt_pedido_historial_insert` era `sucursal_id = current_sucursal_id()` a
-- secas: ni rol ni pertenencia. Cualquier autenticado podía sembrar filas de
-- auditoría con el `usuario_id` de otro. Una tabla de auditoría que el auditado
-- puede escribir no es auditoría.
--
-- Las filas legítimas NO salen de ahí: las escriben `registrar_creacion_pedido`
-- y `registrar_cambio_pedido`, dos triggers AFTER sobre `pedidos`.
--
-- OJO CON LA TRAMPA, que se comió la primera versión de esta migración: esos dos
-- triggers son **SECURITY INVOKER** (`prosecdef = false` en prod, verificado),
-- así que corren como el usuario y **sí pasan por la RLS de `pedido_historial`**.
-- Dropear la policy a secas rompe TODO: cada INSERT y cada UPDATE de `pedidos`
-- desde el navegador dispara el trigger, el trigger choca contra la RLS y el
-- pedido entero se cae con "new row violates row-level security policy for table
-- pedido_historial". Es el espejo exacto de la nota de la 190b: **un trigger
-- dispara igual aunque el que escribe sea DEFINER —eso saltea RLS, no
-- triggers—**, y al revés, un trigger INVOKER no saltea nada.
--
-- Así que la policy no se dropea: se acota a lo único que la distingue. Un
-- INSERT que viene por PostgREST tiene `pg_trigger_depth() = 0`; uno que viene
-- de adentro de un trigger tiene 1 o más. El atacante no puede fabricarse una
-- profundidad de trigger: tendría que hacer que se dispare un trigger cuyo
-- cuerpo escriba lo que él quiere, y los dos únicos que escriben esta tabla
-- arman la fila con `OLD`/`NEW` del pedido y `usuario_id = auth.uid()`.
-- El `usuario_id = auth.uid()` va igual en el WITH CHECK, que es lo que el
-- hallazgo pedía de verdad: no alcanza con "sólo escriben triggers", hace falta
-- "y a tu propio nombre". Los RPC SECURITY DEFINER no pasan por acá (corren como
-- el owner, que sí saltea RLS) y por eso pueden seguir escribiendo el historial
-- con el `app.current_user_id` que setean.
--
-- El único `.from('pedido_historial').insert(...)` del front
-- (`usePedidosQuery.ts`, entrega+pago masivo) nunca funcionó: mandaba `accion`,
-- `descripcion` y `fecha` —tres columnas que la tabla no tiene— y omitía
-- `campo_modificado` y `sucursal_id`, que son NOT NULL. Fallaba el 100% de las
-- veces y el `.then(() => {})` se comía el error. Es el mismo insert muerto que
-- el comentario de `entregarPedidosMasivo` documenta 280 líneas más arriba,
-- copiado. Se borra en este mismo commit: dejarlo invita a que alguien lo
-- "arregle" y se encuentre con un 42501 en vez de con esta explicación.
--
-- Y el SELECT se acota igual que `mt_pedido_items_select`, por la misma razón:
-- el historial de un pedido cuenta quién le cambió el precio y cuándo. El único
-- lector por PostgREST (`handleVerHistorial`) filtra por un `pedido_id` que el
-- usuario ya tuvo que poder ver para abrirle la ficha; los paneles que derivan
-- del historial (`useJornadasPreventistaQuery`) van por RPC y no pasan por acá.
--
-- ---------------------------------------------------------------------------
-- 3 · cliente_preventistas: la auto-asignación se comía el guard de la 216
-- ---------------------------------------------------------------------------
-- `cp_insert` (mig 002) es `es_admin() OR preventista_id = auth.uid()`. La 002
-- la relajó para UN caso concreto: el preventista que crea un cliente nuevo se
-- auto-asigna en el INSERT siguiente. Pero la policy no mira el cliente, así que
-- servía para cualquiera: un preventista se insertaba como asignado de un
-- cliente de OTRO preventista y desde ahí pasaba el guard de la 216
-- (`pedidos_cliente_asignado` deja pasar si estás en `cliente_preventistas`) y
-- veía la ficha por `mt_clientes_select`. La 216 midió dos casos reales.
--
-- La 214 ya había visto la forma del agujero y lo dice con todas las letras:
-- "modelarlo dentro de `cliente_preventistas` no sirve: su policy de INSERT
-- (mig 002) deja auto-asignarse a cualquiera". Tapó el caso `reservado_admin`
-- con `cliente_preventistas_no_reservado` y dejó el resto abierto.
--
-- El trigger nuevo cierra el resto sin tocar el caso que motivó la 002: un
-- cliente recién creado no tiene otro preventista, así que la auto-asignación
-- pasa. Lo que se rechaza es meterse en un cliente que YA atiende otro, y
-- asignar a través de la frontera de sucursal.
--
-- POR QUÉ ES SECURITY DEFINER (y por qué NO lleva el guard de `current_user`):
-- tiene que LEER `clientes` y `cliente_preventistas` para decidir, y bajo la RLS
-- del caller un cliente ajeno es invisible — el EXISTS no encontraría nada y el
-- guard sería fail-OPEN, que es exactamente el modo de falla que arruina un
-- guard de seguridad. Es el mismo molde que `cliente_preventistas_no_reservado`
-- (214) y `pedidos_cliente_asignado` (216), y por eso la exención de los
-- caminos de servicio NO se hace con `current_user` —adentro de una DEFINER
-- `current_user` es siempre el owner, la trampa que documenta la 190b— sino con
-- `auth.uid() IS NULL`, como la 216. Hoy no hay ningún RPC ni edge function que
-- escriba esta tabla: el único escritor es el front.
--
-- ---------------------------------------------------------------------------
-- 4 · productos: el rol depósito era dueño de la fila entera
-- ---------------------------------------------------------------------------
-- `mt_productos_update` autoriza a `admin` o a `perfiles.rol = 'deposito'` sobre
-- la fila COMPLETA, sin guard de columnas: `precio`, `costo_promedio`,
-- `costo_real`, `porcentaje_iva` incluidos. Depósito mueve stock; no fija
-- precios ni costos, y el CMV y toda la valuación cuelgan de esas columnas.
--
-- Hoy no hay usuarios `deposito` en PROD, así que esto no está siendo explotado
-- ni puede estarlo: se abre solo el día que se cree el primero, que es
-- precisamente el día en que nadie se va a acordar de esta policy. Por eso va
-- ahora y no cuando aparezca el usuario.
--
-- `updated_at` va en la lista blanca porque lo pisa
-- `trigger_update_productos_timestamp`; `etiqueta_bulto` y `stock_minimo`
-- porque son parte de la ficha logística que depósito sí administra.
--
-- ---------------------------------------------------------------------------
-- 5 · pedidos_proteger_columnas: los dos residuales que la 219 dejó escritos
-- ---------------------------------------------------------------------------
-- La 219 cerró `usuario_id` en el alta y dejó dos cosas anotadas:
--
--   a) `creado_por` está bloqueado en UPDATE y no en INSERT: la rama nueva hace
--      `RETURN NEW` antes de mirarlo. O sea que la venta ya no se le puede
--      atribuir a otro, pero la AUTORÍA DE LA CARGA sí — y es la columna con la
--      que `crear_pedido_completo` distingue "el admin cargó a nombre de Juan"
--      de "lo cargó Juan". Misma regla, misma línea: a otro sólo admin o
--      encargado.
--
--   b) `usuario_id IS NULL` pasaba, y son dos pedidos reales (marzo, los dos
--      también sin `creado_por`). La 219 lo dejó abierto porque cerrarlo con un
--      RAISE convierte en error un dato que la base hoy admite. La salida es la
--      de `pagos_forzar_usuario` (190b): no fallar, ASIGNAR. Un INSERT directo
--      sin `usuario_id` ahora queda atribuido a quien lo manda, que es
--      exactamente lo que la regla de la 219 dice que tiene que pasar.
--
-- NO se pone `pedidos.usuario_id NOT NULL`, y es una decisión, no un olvido:
-- las dos filas históricas no tienen autor recuperable (tampoco `creado_por`),
-- así que el constraint exigiría inventarles uno o borrarlas. Con el
-- `NEW.usuario_id := auth.uid()` de acá, todo INSERT directo futuro nace con
-- autor; los caminos que no pasan por el guard (`crear_pedido_completo`,
-- `crear_pedido_completo_bot`) ya lo escriben siempre. El NOT NULL quedaría como
-- red de seguridad de un agujero que ya no existe, a cambio de tocar datos
-- históricos. Si algún día se resuelven esas dos filas, ahí sí.
--
-- ---------------------------------------------------------------------------
-- 6 · clientes: `place_id` faltaba en la lista blanca de la 157
-- ---------------------------------------------------------------------------
-- No es un agujero: es el mismo guard mordiendo a quien tiene que dejar pasar.
-- La 151 agregó `clientes.place_id` y el allow-list de
-- `clientes_proteger_columnas_preventista` (080/140/157) nunca se enteró. El
-- form manda `place_id` SIEMPRE (`ClientesContainer.tsx`, patch restringido), y
-- `AddressAutocomplete` lo cambia cada vez que se elige una dirección del
-- buscador. Resultado: un preventista que CORRIGE una dirección con el
-- autocompletado recibe 42501 y no puede guardar. Si no lo toca, el valor viaja
-- igual pero sin cambiar, y por eso el bug sólo aparece justo cuando el dato
-- sirve. `place_id` es evidencia de auditoría de direcciones (151), no un dato
-- comercial: pertenece al mismo grupo que `latitud`/`longitud`, que ya estaban.
--
-- ---------------------------------------------------------------------------
-- 7 · recorridos / recorrido_pedidos: el encargado armaba la ruta a ciegas
-- ---------------------------------------------------------------------------
-- Este no lo trajo la auditoría adversarial; salió de cruzar la RLS con la UI.
-- `mt_recorridos_select` y `mt_recorrido_pedidos_select` son `es_admin() OR
-- transportista_id = auth.uid()`, pero la app le habilita al encargado
-- `/recorridos` (`App.tsx`, `isAdminOrEncargado`) y "Armar ruta del día"
-- (`PedidoToolbar.tsx`, `showOpsGroups = isAdmin || isEncargado`), y
-- `aplicar_orden_ruta` —SECURITY DEFINER, así que la RLS de escritura no lo
-- frena— acepta `es_encargado_o_admin()`.
--
-- La combinación es peor que un permiso faltante: el encargado PUEDE escribir y
-- NO puede leer. `ModalGestionRutas` se apoya en `useRutasEnCursoQuery` para no
-- ser ciego a las rutas ya armadas, y `aplicar_orden_ruta` REEMPLAZA las paradas
-- pendientes del chofer. Un encargado que arma una segunda ruta no ve la
-- primera y se la borra, sin un solo error en pantalla. Y `/recorridos` le abre
-- vacío.
--
-- Se extiende sólo el SELECT. La escritura sigue siendo `es_admin()` en la
-- policy: el camino real del encargado es la RPC, que es donde vive el gate.
-- =========================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. pedido_items · qué filas (RLS) y qué columnas (trigger)
-- ---------------------------------------------------------------------------
-- Molde de la 190 §4: `es_encargado_o_admin()` explícito primero —si no, acotar
-- `es_preventista()` le sacaría a la oficina los pedidos ajenos, que es la mayor
-- parte de lo que hace— y recién después la rama del preventista puro, atada a
-- `pedidos.usuario_id`.
--
-- `pedido_items.pedido_id` es nullable en el schema; en prod no hay ni una fila
-- con NULL (0 de 19.712). Con el EXISTS, una fila así sería invisible e
-- inescribible para todo el que no sea encargado/admin — el mismo criterio que
-- `mt_pedido_items_select` ya aplica desde siempre.

DROP POLICY IF EXISTS "mt_pedido_items_insert" ON public.pedido_items;
CREATE POLICY "mt_pedido_items_insert"
  ON public.pedido_items
  FOR INSERT TO authenticated
  WITH CHECK (
    sucursal_id = public.current_sucursal_id()
    AND (
      public.es_encargado_o_admin()
      OR EXISTS (
        SELECT 1 FROM public.pedidos pd
        WHERE pd.id = pedido_items.pedido_id
          AND pd.usuario_id = auth.uid()
          AND pd.sucursal_id = public.current_sucursal_id()
      )
    )
  );

DROP POLICY IF EXISTS "mt_pedido_items_update" ON public.pedido_items;
CREATE POLICY "mt_pedido_items_update"
  ON public.pedido_items
  FOR UPDATE TO authenticated
  USING (
    sucursal_id = public.current_sucursal_id()
    AND (
      public.es_encargado_o_admin()
      OR EXISTS (
        SELECT 1 FROM public.pedidos pd
        WHERE pd.id = pedido_items.pedido_id
          AND pd.usuario_id = auth.uid()
          AND pd.sucursal_id = public.current_sucursal_id()
      )
    )
  )
  WITH CHECK (
    sucursal_id = public.current_sucursal_id()
    AND (
      public.es_encargado_o_admin()
      OR EXISTS (
        SELECT 1 FROM public.pedidos pd
        WHERE pd.id = pedido_items.pedido_id
          AND pd.usuario_id = auth.uid()
          AND pd.sucursal_id = public.current_sucursal_id()
      )
    )
  );

-- El guard de columnas. Molde de `pedidos_proteger_columnas` (181/219):
--   * INVOKER, no DEFINER: la primera línea compara `current_user`, y adentro de
--     una DEFINER eso es siempre el owner y toda la protección se apaga en
--     silencio (la trampa de la 190b);
--   * `current_user <> 'authenticated'` exenta a `actualizar_pedido_items`
--     (SECURITY DEFINER → corre como postgres), al bot (service_role) y a las
--     conexiones directas;
--   * `pg_trigger_depth() > 1` exenta las cascadas de otros triggers;
--   * encargado/admin salen antes de la lista.
--
-- Es deny-list y no allow-list, igual que en `pedidos`: lo que se protege es la
-- plata (cantidad, precios, costos, el descuento y la marca de bonificación) más
-- las dos columnas de identidad de la fila (`pedido_id`, `sucursal_id`), que son
-- por donde se muda un item a un pedido ajeno. Lo descriptivo
-- (`descripcion_regalo`) no está y no hace falta que esté.
--
-- Sólo UPDATE: en el alta no hay nada que comparar, y quién puede insertar
-- contra qué pedido ya lo decide el WITH CHECK de arriba.

CREATE OR REPLACE FUNCTION public.pedido_items_proteger_columnas()
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

  IF es_encargado_o_admin() THEN
    RETURN NEW;
  END IF;

  SELECT string_agg(o.key, ', ' ORDER BY o.key) INTO v_bloqueadas
  FROM jsonb_each(to_jsonb(OLD)) o
  JOIN jsonb_each(to_jsonb(NEW)) n ON n.key = o.key
  WHERE o.value IS DISTINCT FROM n.value
    AND o.key IN (
      'cantidad', 'precio_unitario', 'subtotal', 'costo_unitario_al_crear',
      'ingreso_real_unitario', 'descuento_pct', 'es_bonificacion',
      'pedido_id', 'sucursal_id'
    );

  IF v_bloqueadas IS NOT NULL THEN
    RAISE EXCEPTION 'No tenes permiso para modificar estas columnas de pedido_items: %. Los items de un pedido se editan desde la ficha del pedido.',
      v_bloqueadas
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS pedido_items_proteger_columnas ON public.pedido_items;
CREATE TRIGGER pedido_items_proteger_columnas
  BEFORE UPDATE ON public.pedido_items
  FOR EACH ROW
  EXECUTE FUNCTION public.pedido_items_proteger_columnas();

REVOKE ALL ON FUNCTION public.pedido_items_proteger_columnas()
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. pedido_historial · nadie la escribe por PostgREST; se lee como los items
-- ---------------------------------------------------------------------------

-- `pg_trigger_depth() > 0`: el INSERT tiene que venir de adentro de un trigger.
-- Por PostgREST la profundidad es 0 y la policy no matchea. Ver el porqué largo
-- arriba: los dos triggers que escriben esta tabla son INVOKER y pasan por acá.
DROP POLICY IF EXISTS "mt_pedido_historial_insert" ON public.pedido_historial;
CREATE POLICY "mt_pedido_historial_insert"
  ON public.pedido_historial
  FOR INSERT TO authenticated
  WITH CHECK (
    pg_trigger_depth() > 0
    AND sucursal_id = public.current_sucursal_id()
    AND usuario_id = auth.uid()
  );

DROP POLICY IF EXISTS "mt_pedido_historial_select" ON public.pedido_historial;
CREATE POLICY "mt_pedido_historial_select"
  ON public.pedido_historial
  FOR SELECT TO authenticated
  USING (
    sucursal_id = public.current_sucursal_id()
    AND EXISTS (
      SELECT 1 FROM public.pedidos p
      WHERE p.id = pedido_historial.pedido_id
        AND (
          public.es_encargado_o_admin()
          OR p.usuario_id = auth.uid()
          OR p.transportista_id = auth.uid()
        )
    )
  );

-- ---------------------------------------------------------------------------
-- 3. cliente_preventistas · no te metas en el cliente de otro
-- ---------------------------------------------------------------------------
-- `cp_insert` (mig 002) queda como está: el trigger es el que mira el cliente,
-- que es lo que una policy WITH CHECK sobre esta tabla no puede hacer sin
-- toparse con la RLS de `clientes`.

CREATE OR REPLACE FUNCTION public.cliente_preventistas_no_ajeno()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal bigint;
  v_cliente  text;
  v_duenos   text;
BEGIN
  -- RPCs SECURITY DEFINER llamadas sin sesión, service_role, bot, conexiones
  -- directas: `auth.uid()` es NULL y no hay identidad que validar. Mismo
  -- criterio que `pedidos_cliente_asignado` (216). NO se usa `current_user`:
  -- adentro de una SECURITY DEFINER es siempre el owner (mig 190b).
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF es_admin() THEN
    RETURN NEW;
  END IF;

  SELECT c.sucursal_id, COALESCE(c.nombre_fantasia, c.razon_social)
    INTO v_sucursal, v_cliente
    FROM clientes c
   WHERE c.id = NEW.cliente_id;

  IF v_sucursal IS NULL OR v_sucursal IS DISTINCT FROM current_sucursal_id() THEN
    RAISE EXCEPTION 'El cliente #% no es de tu sucursal: no podés asignarle preventistas.',
      NEW.cliente_id
      USING ERRCODE = '42501';
  END IF;

  -- Auto-asignarse un cliente SIN dueño sigue permitido: es el flujo que motivó
  -- la mig 002 (el preventista crea el cliente y se lo queda). Lo que se cierra
  -- es meterse en uno que ya atiende otro.
  SELECT string_agg(pf.nombre, ', ' ORDER BY pf.nombre)
    INTO v_duenos
    FROM cliente_preventistas cp
    JOIN perfiles pf ON pf.id = cp.preventista_id
   WHERE cp.cliente_id = NEW.cliente_id
     AND cp.preventista_id IS DISTINCT FROM NEW.preventista_id;

  IF v_duenos IS NOT NULL THEN
    RAISE EXCEPTION 'Cliente asignado a otro preventista: % (#%) lo atiende %. No podés asignártelo.',
      COALESCE(v_cliente, '?'), NEW.cliente_id, v_duenos
      USING ERRCODE = '42501';
  END IF;

  -- Asignar a un TERCERO es cosa de admin, que ya salió por el RETURN de arriba.
  IF NEW.preventista_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Solo un administrador puede asignarle un cliente a otro preventista.'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_cliente_preventistas_no_ajeno ON public.cliente_preventistas;
CREATE TRIGGER trg_cliente_preventistas_no_ajeno
  BEFORE INSERT OR UPDATE ON public.cliente_preventistas
  FOR EACH ROW
  EXECUTE FUNCTION public.cliente_preventistas_no_ajeno();

REVOKE ALL ON FUNCTION public.cliente_preventistas_no_ajeno()
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. productos · depósito mueve stock, no precios
-- ---------------------------------------------------------------------------
-- INVOKER por la misma razón que el resto: compara `current_user`. Lee
-- `perfiles.rol` CRUDO —no `es_admin()` para decidir el rol restringido— igual
-- que `clientes_proteger_columnas_preventista` (157), pero exenta admin por
-- `es_admin()` ANTES, para que un admin con `perfiles.rol` raro no quede
-- atrapado por su rol nominal.

CREATE OR REPLACE FUNCTION public.productos_proteger_columnas()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_rol text;
  v_bloqueadas text;
BEGIN
  IF current_user <> 'authenticated' THEN
    RETURN NEW;
  END IF;

  IF pg_trigger_depth() > 1 THEN
    RETURN NEW;
  END IF;

  IF es_admin() THEN
    RETURN NEW;
  END IF;

  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();

  IF v_rol IS DISTINCT FROM 'deposito' THEN
    RETURN NEW;  -- los demás roles ya no llegan acá: mt_productos_update los frena
  END IF;

  SELECT string_agg(o.key, ', ' ORDER BY o.key) INTO v_bloqueadas
  FROM jsonb_each(to_jsonb(OLD)) o
  JOIN jsonb_each(to_jsonb(NEW)) n ON n.key = o.key
  WHERE o.value IS DISTINCT FROM n.value
    AND o.key NOT IN ('stock', 'stock_minimo', 'etiqueta_bulto', 'updated_at');

  IF v_bloqueadas IS NOT NULL THEN
    RAISE EXCEPTION 'El rol deposito solo puede mover stock: no puede modificar estas columnas de productos: %',
      v_bloqueadas
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS productos_proteger_columnas ON public.productos;
CREATE TRIGGER productos_proteger_columnas
  BEFORE UPDATE ON public.productos
  FOR EACH ROW
  EXECUTE FUNCTION public.productos_proteger_columnas();

REVOKE ALL ON FUNCTION public.productos_proteger_columnas()
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. pedidos_proteger_columnas · los dos residuales de la 219
-- ---------------------------------------------------------------------------
-- Sólo cambia la rama INSERT. Todo lo demás queda byte por byte como lo dejó la
-- 219 (ver ahí el porqué de `auth.uid()` pelado en vez del COALESCE de la 216:
-- este bloque sólo se alcanza con `current_user = 'authenticated'`, o sea que
-- `auth.uid()` nunca es NULL, y con el COALESCE el guard sería fail-OPEN).

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

  IF es_encargado_o_admin() THEN
    RETURN NEW;
  END IF;

  -- ---- Alta: la venta es de quien la carga (mig 219, issue #549) ----------
  -- Acá abajo el caller ya no es admin ni encargado, así que solo puede
  -- atribuirse el pedido a sí mismo.
  IF TG_OP = 'INSERT' THEN
    IF NEW.usuario_id IS NOT NULL AND NEW.usuario_id IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION
        'Un pedido se atribuye a quien lo carga: no podés crear uno a nombre de otro usuario (usuario_id %). Solo un administrador o encargado puede hacerlo.',
        NEW.usuario_id
        USING ERRCODE = '42501';
    END IF;

    -- Mig 233 (a): `creado_por` es la autoría de la CARGA, la columna con la que
    -- `crear_pedido_completo` distingue "el admin cargó a nombre de Juan" de "lo
    -- cargó Juan". Estaba bloqueada en UPDATE y no en INSERT. Misma regla.
    IF NEW.creado_por IS NOT NULL AND NEW.creado_por IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION
        'No podés registrar un pedido como cargado por otro usuario (creado_por %). Solo un administrador o encargado puede hacerlo.',
        NEW.creado_por
        USING ERRCODE = '42501';
    END IF;

    -- Mig 233 (b): sin `usuario_id` el pedido no queda atribuido a nadie y
    -- desaparece de comisiones y de ventas por vendedor. Se ASIGNA, no se
    -- rechaza: molde de `pagos_forzar_usuario` (190b). Un RAISE convertiría en
    -- error un dato que la columna hoy admite (2 filas históricas, marzo).
    IF NEW.usuario_id IS NULL THEN
      NEW.usuario_id := auth.uid();
    END IF;

    RETURN NEW;
  END IF;

  -- ---- De acá abajo es UPDATE (usa OLD) ----------------------------------
  IF es_transportista() THEN
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

  SELECT string_agg(o.key, ', ' ORDER BY o.key) INTO v_bloqueadas
  FROM jsonb_each(to_jsonb(OLD)) o
  JOIN jsonb_each(to_jsonb(NEW)) n ON n.key = o.key
  WHERE o.value IS DISTINCT FROM n.value
    AND o.key IN (
      'total', 'total_neto', 'total_iva', 'total_real', 'monto_pagado',
      'estado_pago', 'cliente_id', 'sucursal_id', 'usuario_id', 'creado_por',
      'preventista_id', 'tipo_factura', 'stock_descontado', 'offline_id'
    );

  IF v_bloqueadas IS NOT NULL THEN
    RAISE EXCEPTION 'No tenes permiso para modificar estas columnas de pedidos: %',
      v_bloqueadas
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.pedidos_proteger_columnas()
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. clientes · `place_id` entra a la lista blanca
-- ---------------------------------------------------------------------------
-- Único cambio: la línea de `place_id`. El resto queda igual que en la 157.

CREATE OR REPLACE FUNCTION public.clientes_proteger_columnas_preventista()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_rol text;
  v_bloqueadas text;
BEGIN
  -- RPCs SECURITY DEFINER, service_role, conexiones directas: exentas.
  IF current_user <> 'authenticated' THEN
    RETURN NEW;
  END IF;

  -- Cascadas desde otros triggers (saldo_cuenta desde pedidos): exentas.
  IF pg_trigger_depth() > 1 THEN
    RETURN NEW;
  END IF;

  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();

  IF v_rol IS NULL OR v_rol NOT IN ('preventista') THEN
    RETURN NEW;  -- admin y encargado sin restricción
  END IF;

  SELECT string_agg(o.key, ', ' ORDER BY o.key) INTO v_bloqueadas
  FROM jsonb_each(to_jsonb(OLD)) o
  JOIN jsonb_each(to_jsonb(NEW)) n ON n.key = o.key
  WHERE o.value IS DISTINCT FROM n.value
    AND o.key NOT IN (
      'razon_social', 'direccion', 'aclaracion_direccion', 'latitud',
      'longitud', 'telefono', 'contacto', 'horarios_atencion', 'rubro', 'notas',
      -- Mig 140: el horario canónico se carga junto con los días.
      'dias_atencion', 'horarios_atencion_original',
      -- Mig 157: escape del horario obligatorio al cargar un pedido.
      'sin_horario_fijo',
      -- Mig 233: `place_id` (mig 151) es la evidencia de qué lugar eligió el
      -- preventista en el autocompletado. Viaja en el mismo patch que
      -- `direccion`/`latitud`/`longitud` y cambia con ellos; sin esta línea,
      -- corregir una dirección desde el buscador devolvía 42501.
      'place_id'
    );

  IF v_bloqueadas IS NOT NULL THEN
    RAISE EXCEPTION 'El rol % no puede modificar estas columnas de clientes: %',
      v_rol, v_bloqueadas
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.clientes_proteger_columnas_preventista()
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 7. recorridos / recorrido_pedidos · el encargado ve lo que arma
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS "mt_recorridos_select" ON public.recorridos;
CREATE POLICY "mt_recorridos_select"
  ON public.recorridos
  FOR SELECT TO authenticated
  USING (
    sucursal_id = public.current_sucursal_id()
    AND (
      public.es_encargado_o_admin()
      OR transportista_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "mt_recorrido_pedidos_select" ON public.recorrido_pedidos;
CREATE POLICY "mt_recorrido_pedidos_select"
  ON public.recorrido_pedidos
  FOR SELECT TO authenticated
  USING (
    sucursal_id = public.current_sucursal_id()
    AND (
      public.es_encargado_o_admin()
      OR EXISTS (
        SELECT 1 FROM public.recorridos r
        WHERE r.id = recorrido_pedidos.recorrido_id
          AND r.transportista_id = auth.uid()
      )
    )
  );

-- ---------------------------------------------------------------------------
-- 8. Verificación
-- ---------------------------------------------------------------------------

DO $verif$
DECLARE
  v_acl   text;
  v_qual  text;
  v_check text;
  v_tipo  int;
  r       record;
BEGIN
  -- --- ACL de las funciones de trigger -------------------------------------
  -- Una función de trigger no necesita EXECUTE para nadie: la invoca el
  -- executor como parte del DML, no el caller. El gate de CI
  -- (scripts/check-permisos.mjs) falla ante cualquier función alcanzable con la
  -- anon key, y Supabase concede a PUBLIC y a anon por separado.
  FOR r IN
    SELECT unnest(ARRAY[
      'pedido_items_proteger_columnas',
      'cliente_preventistas_no_ajeno',
      'productos_proteger_columnas',
      'pedidos_proteger_columnas',
      'clientes_proteger_columnas_preventista'
    ]) AS fn
  LOOP
    SELECT array_to_string(p.proacl, ',') INTO v_acl
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = r.fn;

    IF v_acl IS NULL THEN
      RAISE EXCEPTION '% no existe o quedo con ACL default (= ejecutable por PUBLIC)', r.fn;
    END IF;
    IF v_acl LIKE '=X/%' OR v_acl LIKE '%,=X/%' THEN
      RAISE EXCEPTION '% quedo ejecutable por PUBLIC: %', r.fn, v_acl;
    END IF;
    IF v_acl LIKE '%anon=%' THEN
      RAISE EXCEPTION '% quedo ejecutable por anon: %', r.fn, v_acl;
    END IF;
    IF v_acl LIKE '%authenticated=%' THEN
      RAISE EXCEPTION '% quedo ejecutable por authenticated: %', r.fn, v_acl;
    END IF;
  END LOOP;

  -- --- Las INVOKER tienen que seguir siendo INVOKER -------------------------
  -- Adentro de una SECURITY DEFINER `current_user` es el owner, la primera
  -- linea daria siempre true y toda la proteccion se apagaria en silencio
  -- (mig 190b). Es el modo de falla mas caro de esta familia de triggers.
  FOR r IN
    SELECT unnest(ARRAY[
      'pedido_items_proteger_columnas',
      'productos_proteger_columnas',
      'pedidos_proteger_columnas',
      'clientes_proteger_columnas_preventista'
    ]) AS fn
  LOOP
    IF EXISTS (
      SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public' AND p.proname = r.fn AND p.prosecdef
    ) THEN
      RAISE EXCEPTION '% quedo SECURITY DEFINER: el guard de current_user se apaga', r.fn;
    END IF;
  END LOOP;

  -- ...y la de cliente_preventistas tiene que seguir siendo DEFINER: lee
  -- `clientes` y `cliente_preventistas`, que bajo la RLS del caller esconden
  -- justo el cliente ajeno que hay que detectar (fail-open).
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'cliente_preventistas_no_ajeno' AND p.prosecdef
  ) THEN
    RAISE EXCEPTION 'cliente_preventistas_no_ajeno tiene que ser SECURITY DEFINER: si no, no ve el cliente ajeno y el guard es fail-open';
  END IF;

  -- --- Los triggers existen y estan en el evento correcto -------------------
  SELECT t.tgtype::int INTO v_tipo FROM pg_trigger t
   WHERE t.tgrelid = 'public.pedido_items'::regclass
     AND t.tgname = 'pedido_items_proteger_columnas';
  IF v_tipo IS NULL THEN
    RAISE EXCEPTION 'falta el trigger pedido_items_proteger_columnas';
  END IF;
  IF (v_tipo & 16) = 0 OR (v_tipo & 2) = 0 THEN
    RAISE EXCEPTION 'pedido_items_proteger_columnas no quedo BEFORE UPDATE (tgtype=%)', v_tipo;
  END IF;

  SELECT t.tgtype::int INTO v_tipo FROM pg_trigger t
   WHERE t.tgrelid = 'public.productos'::regclass
     AND t.tgname = 'productos_proteger_columnas';
  IF v_tipo IS NULL THEN
    RAISE EXCEPTION 'falta el trigger productos_proteger_columnas';
  END IF;
  IF (v_tipo & 16) = 0 OR (v_tipo & 2) = 0 THEN
    RAISE EXCEPTION 'productos_proteger_columnas no quedo BEFORE UPDATE (tgtype=%)', v_tipo;
  END IF;

  SELECT t.tgtype::int INTO v_tipo FROM pg_trigger t
   WHERE t.tgrelid = 'public.cliente_preventistas'::regclass
     AND t.tgname = 'trg_cliente_preventistas_no_ajeno';
  IF v_tipo IS NULL THEN
    RAISE EXCEPTION 'falta el trigger trg_cliente_preventistas_no_ajeno';
  END IF;
  IF (v_tipo & 4) = 0 OR (v_tipo & 2) = 0 THEN
    RAISE EXCEPTION 'trg_cliente_preventistas_no_ajeno no quedo BEFORE INSERT (tgtype=%)', v_tipo;
  END IF;

  -- El de la 214 sigue vivo: los dos guards son independientes y ninguno cubre
  -- lo del otro (reservado_admin vs. cliente ajeno).
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger t
     WHERE t.tgrelid = 'public.cliente_preventistas'::regclass
       AND t.tgname = 'trg_cliente_preventistas_no_reservado'
  ) THEN
    RAISE EXCEPTION 'se perdio trg_cliente_preventistas_no_reservado (mig 214)';
  END IF;

  -- El de la 219 sigue en INSERT **y** UPDATE.
  SELECT t.tgtype::int INTO v_tipo FROM pg_trigger t
   WHERE t.tgrelid = 'public.pedidos'::regclass AND t.tgname = 'pedidos_proteger_columnas';
  IF v_tipo IS NULL OR (v_tipo & 4) = 0 OR (v_tipo & 16) = 0 OR (v_tipo & 2) = 0 THEN
    RAISE EXCEPTION 'pedidos_proteger_columnas perdio INSERT o UPDATE (tgtype=%)', v_tipo;
  END IF;

  -- --- Las policies quedaron con el predicado de pertenencia ---------------
  SELECT with_check INTO v_check FROM pg_policies
   WHERE schemaname='public' AND tablename='pedido_items' AND policyname='mt_pedido_items_insert';
  IF v_check IS NULL OR v_check NOT LIKE '%usuario_id = auth.uid()%' THEN
    RAISE EXCEPTION 'mt_pedido_items_insert no mira el pedido padre: %', coalesce(v_check,'(null)');
  END IF;

  SELECT qual, with_check INTO v_qual, v_check FROM pg_policies
   WHERE schemaname='public' AND tablename='pedido_items' AND policyname='mt_pedido_items_update';
  IF v_qual IS NULL OR v_qual NOT LIKE '%usuario_id = auth.uid()%'
     OR v_check IS NULL OR v_check NOT LIKE '%usuario_id = auth.uid()%' THEN
    RAISE EXCEPTION 'mt_pedido_items_update no mira el pedido padre en USING y WITH CHECK';
  END IF;

  SELECT with_check INTO v_check FROM pg_policies
   WHERE schemaname='public' AND tablename='pedido_historial' AND policyname='mt_pedido_historial_insert';
  IF v_check IS NULL
     OR v_check NOT LIKE '%pg_trigger_depth() > 0%'
     OR v_check NOT LIKE '%usuario_id = auth.uid()%' THEN
    RAISE EXCEPTION 'mt_pedido_historial_insert no quedo acotada a los triggers y al usuario propio: %', coalesce(v_check,'(null)');
  END IF;
  IF (SELECT count(*) FROM pg_policies
       WHERE schemaname='public' AND tablename='pedido_historial' AND cmd='INSERT') <> 1 THEN
    RAISE EXCEPTION 'pedido_historial quedo con mas de una policy de INSERT: las permisivas se suman con OR';
  END IF;

  -- Los dos triggers de auditoria tienen que seguir siendo INVOKER: si alguien
  -- los pasa a DEFINER dejan de pasar por la policy de arriba y el acote se
  -- vuelve decorativo. (Y si los pasa a DEFINER *y* borra la policy, nada falla
  -- y nadie se entera: por eso se chequea el par.)
  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname='public'
       AND p.proname IN ('registrar_creacion_pedido','registrar_cambio_pedido')
       AND p.prosecdef
  ) THEN
    RAISE EXCEPTION 'registrar_creacion_pedido / registrar_cambio_pedido pasaron a SECURITY DEFINER: mt_pedido_historial_insert dejo de gobernarlos';
  END IF;

  SELECT qual INTO v_qual FROM pg_policies
   WHERE schemaname='public' AND tablename='pedido_historial' AND policyname='mt_pedido_historial_select';
  IF v_qual IS NULL OR v_qual NOT LIKE '%usuario_id = auth.uid()%' THEN
    RAISE EXCEPTION 'mt_pedido_historial_select no quedo acotado al pedido propio: %', coalesce(v_qual,'(null)');
  END IF;

  FOR r IN
    SELECT 'recorridos' AS t, 'mt_recorridos_select' AS p
    UNION ALL SELECT 'recorrido_pedidos', 'mt_recorrido_pedidos_select'
  LOOP
    SELECT qual INTO v_qual FROM pg_policies
     WHERE schemaname='public' AND tablename=r.t AND policyname=r.p;
    IF v_qual IS NULL OR v_qual NOT LIKE '%es_encargado_o_admin()%' THEN
      RAISE EXCEPTION '% no quedo con es_encargado_o_admin(): %', r.p, coalesce(v_qual,'(null)');
    END IF;
  END LOOP;

  -- --- La lista blanca de clientes tiene place_id ---------------------------
  IF (SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
       WHERE n.nspname='public' AND p.proname='clientes_proteger_columnas_preventista')
     NOT LIKE '%''place_id''%' THEN
    RAISE EXCEPTION 'clientes_proteger_columnas_preventista quedo sin place_id en la lista blanca';
  END IF;
END
$verif$;

COMMIT;
