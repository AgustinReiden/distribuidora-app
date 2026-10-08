-- #1009 + #982 · Las funciones SECURITY DEFINER miran el rol (y la sucursal)
--
-- Una función DEFINER corre como su dueño: la RLS no la ve. Si además
-- `authenticated` tiene EXECUTE, cualquier usuario logueado —depósito,
-- un preventista ajeno— la llama directo por `rpc/<nombre>` con los argumentos
-- que quiera. La única barrera es lo que la función chequee por su cuenta.
--
-- EL BARRIDO (2026-10-08, sobre prod). Todas las DEFINER de `public` con
-- EXECUTE para authenticated cuyo cuerpo no nombra ningún helper de rol dieron
-- 33. Cada una cayó en una de tres cajas:
--
--   A · Agujero real → guard (secciones 2 a 5).
--       deuda_previa, deuda_previa_detalle, simular_salvedad_promo_impacto,
--       simular_salvedades_promo_impacto: cualquier rol de la sucursal leía la
--       deuda, las boletas impagas o los regalos de CUALQUIER pedido. Ahora
--       responden sólo sobre un pedido que el caller ya puede leer por RLS.
--       eliminar_proveedor (no estaba en el issue): cualquiera borraba
--       cualquier proveedor de cualquier sucursal. Ahora sólo admin, y de la
--       sucursal activa — lo mismo que la policy mt_proveedores_delete.
--
--   B · Nadie del front la usa → REVOKE a las tres mitades (sección 6).
--       crear_recorrido (el hook existe, ninguna pantalla lo llama),
--       crear_rendicion_por_fecha, obtener_estadisticas_rendiciones y
--       obtener_estadisticas_pedidos (sin caller), pedido_bundle_para_promo (la
--       llama sólo crear_pedido_completo, que es DEFINER), y las tres
--       auditoria_* que sólo corren desde CI con service_role o desde
--       auditoria_integridad(). Se revocan, no se borran: es reversible con un
--       GRANT y el código que las define sigue siendo la referencia.
--
--   C · No filtran nada → lista blanca del check nuevo, con el porqué al lado de
--       cada una (sección 7).
--
-- #982. `reporte_cuentas_por_cobrar` y `reporte_ventas_por_preventista`
-- calculaban las sucursales asignadas y después no cruzaban `p_sucursal_id`
-- con ellas. El barrido de todas las `reporte_*` encontró una tercera con el
-- mismo molde de la 208: `reporte_rentabilidad` (sección 5).
--
-- EL GATE (sección 7). Check SEG-A en auditoria_integridad(): cuenta las DEFINER
-- de public alcanzables por authenticated que no nombran un helper de rol y no
-- están en la lista blanca. Severidad high: tumba el gate de CI. El detalle lo
-- da `auditoria_definer_sin_rol()`.
--
-- Lo que NO cambia: ningún uso legítimo. El front llama los tres reportes con
-- p_sucursal_id NULL; el bot entra como servicio (auth.uid() NULL) y saltea el
-- guard; deuda_previa y las simular_* se piden siempre sobre filas que la RLS
-- ya dejó ver; /proveedores es sólo admin.

BEGIN;

-- ---------------------------------------------------------------------------
-- 0 · Andamio: parche por ancla, con la guarda de "exactamente una vez".
--     El mismo de las migs 257 y 300. Si otra sesión cambió el cuerpo vivo, el
--     ancla no aparece y la migración falla en vez de pisar el cambio.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._migrol_ancla(
  p_funcion regprocedure, p_ancla text, p_nuevo text
) RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text;
  v_veces int;
BEGIN
  v_def := pg_get_functiondef(p_funcion);
  v_veces := (length(v_def) - length(replace(v_def, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El ancla aparece % veces en % (se esperaba exactamente 1). El cuerpo vivo cambio: revisar a mano. Ancla: %',
      v_veces, p_funcion, left(p_ancla, 120);
  END IF;
  EXECUTE replace(v_def, p_ancla, p_nuevo);
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 1 · puede_leer_pedido(id): el predicado de la policy mt_pedidos_select.
--
--     encargado/admin, o el pedido es tuyo como vendedor o como transportista,
--     y de la sucursal activa. Es exactamente lo que la RLS deja leer de
--     `pedidos`, así que una función que lo exige no le muestra a nadie un
--     pedido que no podía ver ya. Depósito no está en el predicado (no es
--     encargado/admin, ni vendedor, ni transportista): queda afuera, que es la
--     decisión del dueño de #999.
--
--     SI CAMBIÁS mt_pedidos_select, CAMBIÁ ESTO (y el inline de deuda_previa
--     y deuda_previa_detalle, sección 2). La policy filtra filas por REST, esto
--     filtra lo que devuelven las DEFINER que reciben un pedido. La sección 8
--     verifica que la policy diga exactamente esto al aplicar.
--
--     INVOKER y sin EXECUTE para nadie de la app: sólo la llaman funciones
--     DEFINER, que corren como postgres.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.puede_leer_pedido(p_pedido_id bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $fn$
  SELECT EXISTS (
    SELECT 1
      FROM pedidos pe
     WHERE pe.id = p_pedido_id
       AND pe.sucursal_id = current_sucursal_id()
       AND (   es_encargado_o_admin()
            OR pe.usuario_id = auth.uid()
            OR pe.transportista_id = auth.uid())
  );
$fn$;

COMMENT ON FUNCTION public.puede_leer_pedido(bigint) IS
  'Mig #1009: el predicado de mt_pedidos_select para las funciones DEFINER que reciben un pedido. Si cambia la policy, cambia esto.';

REVOKE ALL ON FUNCTION public.puede_leer_pedido(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.puede_leer_pedido(bigint) TO service_role;

-- ---------------------------------------------------------------------------
-- 2 · deuda_previa / deuda_previa_detalle: sólo sobre un pedido que podés leer.
--
--     La 215 ya hizo que una fila inventada no matchee (`ref` relee el pedido
--     por id y sucursal). Faltaba el rol: depósito o un preventista ajeno
--     recorrían ids y se llevaban deuda y boletas impagas con monto. Con el
--     predicado sumado, `ref` sale vacío y la función devuelve 0 / [] — lo mismo
--     que ya devolvía para un pedido de otra sucursal.
--
--     Acá el predicado va INLINE sobre la fila que `ref` ya leyó, y no por
--     puede_leer_pedido(): son columnas calculadas, corren una vez por fila de
--     cada lista de pedidos (sin paginar en fetchPedidosAsignados). Medido en
--     prod sobre 300 pedidos, las dos juntas: 54 ms hoy, 261 ms con el helper
--     (relee el pedido y no se puede inlinear por su SET search_path), 76 ms
--     inline. auth.uid() va primero porque es lo barato.
--     Es la tercera copia del predicado de mt_pedidos_select (con la policy y
--     el helper): la sección 8 verifica que la policy siga diciendo eso.
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._migrol_ancla('public.deuda_previa(public.pedidos)'::regprocedure,
$ancla$    WHERE pe.id = p.id
      AND pe.sucursal_id = current_sucursal_id()
$ancla$,
$nuevo$    WHERE pe.id = p.id
      AND pe.sucursal_id = current_sucursal_id()
      -- #1009: y sólo si el caller puede leer el pedido. Es el predicado de
      -- mt_pedidos_select, inline por costo (ver la migración).
      AND (pe.usuario_id = auth.uid() OR pe.transportista_id = auth.uid() OR es_encargado_o_admin())
$nuevo$);

  PERFORM public._migrol_ancla('public.deuda_previa_detalle(public.pedidos)'::regprocedure,
$ancla$    WHERE pe.id = p.id
      AND pe.sucursal_id = current_sucursal_id()
$ancla$,
$nuevo$    WHERE pe.id = p.id
      AND pe.sucursal_id = current_sucursal_id()
      -- #1009: y sólo si el caller puede leer el pedido. Es el predicado de
      -- mt_pedidos_select, inline por costo (ver la migración).
      AND (pe.usuario_id = auth.uid() OR pe.transportista_id = auth.uid() OR es_encargado_o_admin())
$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 3 · simular_salvedad(es)_promo_impacto: mismo predicado.
--
--     Devuelven nombres de promo y cantidades de regalos del pedido, sin plata,
--     pero de un pedido que el caller no necesariamente puede leer. Las llaman
--     la salvedad del transportista y la entrega con salvedad de Pedidos, ambas
--     sobre pedidos que la RLS ya le mostró.
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._migrol_ancla('public.simular_salvedad_promo_impacto(bigint,bigint,integer)'::regprocedure,
$ancla$   WHERE pi.id = p_pedido_item_id
     AND pi.pedido_id = p_pedido_id
     AND pi.sucursal_id = v_sucursal;
$ancla$,
$nuevo$   WHERE pi.id = p_pedido_item_id
     AND pi.pedido_id = p_pedido_id
     AND pi.sucursal_id = v_sucursal
     -- #1009: sólo sobre un pedido que el caller puede leer.
     AND public.puede_leer_pedido(p_pedido_id);
$nuevo$);

  PERFORM public._migrol_ancla('public.simular_salvedades_promo_impacto(bigint,jsonb)'::regprocedure,
$ancla$     WHERE pi.pedido_id = p_pedido_id
       AND pi.sucursal_id = current_sucursal_id()
$ancla$,
$nuevo$     WHERE pi.pedido_id = p_pedido_id
       AND pi.sucursal_id = current_sucursal_id()
       -- #1009: sólo sobre un pedido que el caller puede leer.
       AND public.puede_leer_pedido(p_pedido_id)
$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 4 · eliminar_proveedor: sólo admin, y de la sucursal activa.
--
--     Mismo criterio que mt_proveedores_delete (es_admin() y sucursal activa)
--     y que la ruta /proveedores (sólo admin). Se reescribe entera porque el
--     guard tiene que quedar AFUERA del `EXCEPTION WHEN OTHERS`: adentro, el
--     RAISE se convertía en {success:false} con HTTP 200 y "acceso denegado" no
--     se distinguía de "proveedor no encontrado". El resto del cuerpo es el de
--     prod, con los fines de línea normalizados.
--     Un proveedor de otra sucursal da "Proveedor no encontrado", igual que
--     uno que no existe.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.eliminar_proveedor(p_proveedor_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_proveedor RECORD;
BEGIN
  -- #1009: el rol se chequea afuera del bloque con EXCEPTION, para que el
  -- rechazo llegue como error (42501) y no como {success:false}.
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Acceso denegado: sólo un admin puede eliminar proveedores'
      USING ERRCODE = '42501';
  END IF;

  BEGIN
    -- Buscar el proveedor (#1009: de la sucursal activa)
    SELECT * INTO v_proveedor
    FROM proveedores
    WHERE id = p_proveedor_id
      AND sucursal_id = current_sucursal_id();

    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false, 'error', 'Proveedor no encontrado');
    END IF;

    -- Guardar registro en tabla de auditoría
    INSERT INTO proveedores_eliminados (
      proveedor_id, nombre, cuit, direccion, telefono, email,
      contacto, notas, activo, fecha_creacion, eliminado_por
    ) VALUES (
      v_proveedor.id,
      v_proveedor.nombre,
      v_proveedor.cuit,
      v_proveedor.direccion,
      v_proveedor.telefono,
      v_proveedor.email,
      v_proveedor.contacto,
      v_proveedor.notas,
      v_proveedor.activo,
      v_proveedor.created_at,
      auth.uid()
    );

    -- Eliminar el proveedor (compras mantienen proveedor_nombre por ON DELETE SET NULL)
    DELETE FROM proveedores WHERE id = p_proveedor_id;

    RETURN jsonb_build_object(
      'success', true,
      'nombre', v_proveedor.nombre
    );
  EXCEPTION
    WHEN OTHERS THEN
      RETURN jsonb_build_object('success', false, 'error', SQLERRM);
  END;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 5 · #982 · los reportes cruzan la sucursal pedida con las asignadas.
--
--     El guard es el mismo texto que ya tienen las reporte_* que cruzan bien
--     (alerta_detalle, gerencial, mermas, valuacion_inventario,
--     ventas_por_cliente). El camino de servicio (auth.uid() NULL: los bot_*
--     que las envuelven) no cambia. reporte_stock_red no se toca: es sólo
--     admin y de red a propósito.
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE
  v_fn regprocedure;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY[
    'public.reporte_cuentas_por_cobrar(bigint)'::regprocedure,
    'public.reporte_ventas_por_preventista(date,date,bigint)'::regprocedure,
    'public.reporte_rentabilidad(date,date,bigint)'::regprocedure
  ] LOOP
    PERFORM public._migrol_ancla(v_fn,
$ancla$    v_sucursales := COALESCE(v_asignadas, ARRAY(SELECT id FROM sucursales));
  ELSE
    v_sucursales := ARRAY[p_sucursal_id];
$ancla$,
$nuevo$    v_sucursales := COALESCE(v_asignadas, ARRAY(SELECT id FROM sucursales));
  ELSE
    -- #982: la sucursal pedida tiene que ser una de las asignadas.
    IF NOT v_es_servicio AND NOT (p_sucursal_id = ANY(v_asignadas)) THEN
      RAISE EXCEPTION 'Acceso denegado: la sucursal % no está asignada al usuario', p_sucursal_id
        USING ERRCODE = '42501';
    END IF;
    v_sucursales := ARRAY[p_sucursal_id];
$nuevo$);
  END LOOP;
END
$patch$;

-- ---------------------------------------------------------------------------
-- 6 · Las que nadie de la app llama: afuera authenticated.
--
--     Receta de server de CLAUDE.md: las tres mitades. service_role (CI, bot)
--     y postgres (las DEFINER que las llaman) conservan su EXECUTE.
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.crear_recorrido(uuid,jsonb,numeric,integer)                         FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.crear_rendicion_por_fecha(uuid,date)                                 FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.obtener_estadisticas_rendiciones(date,date,uuid)                     FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.obtener_estadisticas_pedidos(timestamp with time zone,timestamp with time zone,uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.pedido_bundle_para_promo(bigint,bigint,integer)                      FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.auditoria_permisos_execute()                                         FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.auditoria_funciones_costo_sin_valuacion()                            FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.auditoria_funciones_stock_sin_origen()                               FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.crear_recorrido(uuid,jsonb,numeric,integer)                         TO service_role;
GRANT EXECUTE ON FUNCTION public.crear_rendicion_por_fecha(uuid,date)                                 TO service_role;
GRANT EXECUTE ON FUNCTION public.obtener_estadisticas_rendiciones(date,date,uuid)                     TO service_role;
GRANT EXECUTE ON FUNCTION public.obtener_estadisticas_pedidos(timestamp with time zone,timestamp with time zone,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.pedido_bundle_para_promo(bigint,bigint,integer)                      TO service_role;
GRANT EXECUTE ON FUNCTION public.auditoria_permisos_execute()                                         TO service_role;
GRANT EXECUTE ON FUNCTION public.auditoria_funciones_costo_sin_valuacion()                            TO service_role;
GRANT EXECUTE ON FUNCTION public.auditoria_funciones_stock_sin_origen()                               TO service_role;

-- ---------------------------------------------------------------------------
-- 7 · El gate: SEG-A en auditoria_integridad().
--
--     Cuenta las funciones de public que son SECURITY DEFINER, no son de
--     trigger (un trigger no se puede invocar por RPC) ni de una extensión,
--     authenticated puede ejecutar, y cuyo cuerpo no nombra ningún helper de
--     rol. Es una heurística de texto, como STK-F y COSTO-D: nombrar el helper
--     no prueba que el guard esté bien, pero no nombrarlo prueba que no hay
--     guard de rol. Lo que sigue en la lista blanca se revisó a mano.
--
--     La lista blanca es por FIRMA, no por nombre: si alguien cambia la firma
--     o agrega una sobrecarga, la entrada deja de cubrirla y el check salta.
--     Para sumar una entrada, escribí al lado por qué no filtra nada.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.auditoria_definer_sin_rol()
RETURNS TABLE(firma text)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $fn$
  SELECT p.oid::regprocedure::text
    FROM pg_proc p
    JOIN pg_type t ON t.oid = p.prorettype
   WHERE p.pronamespace = 'public'::regnamespace
     AND p.prokind = 'f'
     AND p.prosecdef
     AND t.typname <> 'trigger'
     AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
     AND NOT EXISTS (
       SELECT 1 FROM pg_depend d
        WHERE d.classid = 'pg_proc'::regclass
          AND d.objid = p.oid
          AND d.deptype = 'e')
     -- Los helpers de rol. Trampa 4 de CLAUDE.md: es_preventista() y
     -- es_transportista() dejan pasar a otros roles; nombrarlos cuenta como
     -- guard para este check, pero no lo hace correcto.
     AND p.prosrc !~* '(\mes_admin|\mes_encargado_o_admin|\mes_preventista|\mes_transportista|\mget_mi_rol|\mget_user_role|\mtiene_rol_extra|_rol_en_sucursal|\mpuede_leer_pedido|\mperfil_roles\M|\mrol\M)'
     AND p.oid::regprocedure::text NOT IN (
       -- Sólo tocan filas del propio auth.uid().
       'cambiar_sucursal(bigint)',                 -- valida que la sucursal sea del caller
       'marcar_notificacion_leida(bigint)',
       'marcar_todas_notificaciones_leidas()',
       'generar_codigo_vinculacion_bot()',
       'listar_visitas_hoy()',
       -- Helpers de RLS y de la sucursal activa del caller.
       'current_sucursal_id()',                    -- valida el header contra usuario_sucursales
       'cliente_de_sucursal_activa(bigint)',        -- booleano, policy de cliente_preventistas
       'perfil_de_sucursal_activa(uuid)',           -- booleano, policy de perfiles
       'get_deposito_sucursal()',                   -- coordenadas de la sucursal activa
       'get_destino_sucursal()',
       'parametros_vencimiento()',                  -- días de alerta, sin montos
       -- Wrappers de idempotencia (mig 167): el rol lo exige el _impl, que no
       -- tiene EXECUTE para authenticated. Un replay del mismo
       -- client_request_id (uuid) devuelve el resultado guardado sin pasar por
       -- el _impl: es el de esa misma solicitud, ya autorizada.
       'registrar_pago_cliente_fifo(bigint,numeric,text,date,text,text,uuid)',
       'registrar_pago_combinado_cliente_fifo(bigint,jsonb,date,text,text,uuid)',
       'marcar_pagos_masivo(bigint[],text,date,uuid)',
       'marcar_entrega_y_pago_masivo(bigint[],uuid,text,date,uuid)',
       'imputar_credito_a_pedido(bigint,bigint,numeric,uuid)',
       'crear_nota_credito_venta(bigint,bigint,jsonb,text,text,uuid)',
       -- Delega en crear_pedido_completo, que exige admin/preventista/encargado.
       'crear_pedido_idempotente(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid,text)',
       -- Booleano / fecha de cierre de caja, sin montos. Las usa el front para
       -- la fecha mínima de un pago, y pagos_guard_anulacion_caja_cerrada (un
       -- trigger INVOKER) llama a ultima_fecha_caja_cerrada como el usuario:
       -- revocarla rompería borrar pagos.
       'rendicion_dia_cerrada(date,bigint)',
       'ultima_fecha_caja_cerrada(bigint)'
     )
   ORDER BY 1;
$fn$;

COMMENT ON FUNCTION public.auditoria_definer_sin_rol() IS
  'Check SEG-A (#1009): funciones SECURITY DEFINER de public que authenticated puede ejecutar y no nombran un helper de rol, fuera de la lista blanca. Cero o rojo.';

REVOKE ALL ON FUNCTION public.auditoria_definer_sin_rol() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auditoria_definer_sin_rol() TO service_role;

DO $patch$
BEGIN
  PERFORM public._migrol_ancla('public.auditoria_integridad()'::regprocedure,
$ancla$    ('STK-F','high','funciones de public que suben stock sin declarar app.stock_origen (mig 229)',$ancla$,
$nuevo$    ('SEG-A','high','funciones SECURITY DEFINER de public que authenticated ejecuta sin chequear el rol (#1009)',
      (SELECT count(*) FROM public.auditoria_definer_sin_rol())),
    ('STK-F','high','funciones de public que suben stock sin declarar app.stock_origen (mig 229)',$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 8 · Verificación estructural. El comportamiento por rol lo prueba
--     scripts/test-permisos-definer-sin-rol.sql.
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  v_fn     text;
  v_lista  text;
  v_check  jsonb;
BEGIN
  -- 8.1 · Las revocadas: ni authenticated ni anon; service_role sí.
  FOREACH v_fn IN ARRAY ARRAY[
    'public.crear_recorrido(uuid,jsonb,numeric,integer)',
    'public.crear_rendicion_por_fecha(uuid,date)',
    'public.obtener_estadisticas_rendiciones(date,date,uuid)',
    'public.obtener_estadisticas_pedidos(timestamp with time zone,timestamp with time zone,uuid)',
    'public.pedido_bundle_para_promo(bigint,bigint,integer)',
    'public.auditoria_permisos_execute()',
    'public.auditoria_funciones_costo_sin_valuacion()',
    'public.auditoria_funciones_stock_sin_origen()',
    'public.auditoria_definer_sin_rol()',
    'public.puede_leer_pedido(bigint)'
  ] LOOP
    IF has_function_privilege('authenticated', v_fn, 'EXECUTE')
       OR has_function_privilege('anon', v_fn, 'EXECUTE') THEN
      RAISE EXCEPTION '#1009 · % sigue ejecutable por authenticated o anon', v_fn;
    END IF;
    IF NOT has_function_privilege('service_role', v_fn, 'EXECUTE') THEN
      RAISE EXCEPTION '#1009 · % quedó sin EXECUTE para service_role', v_fn;
    END IF;
  END LOOP;

  -- 8.2 · Las que el front sigue llamando conservan su EXECUTE.
  FOREACH v_fn IN ARRAY ARRAY[
    'public.deuda_previa(public.pedidos)',
    'public.deuda_previa_detalle(public.pedidos)',
    'public.simular_salvedad_promo_impacto(bigint,bigint,integer)',
    'public.simular_salvedades_promo_impacto(bigint,jsonb)',
    'public.eliminar_proveedor(bigint)',
    'public.reporte_cuentas_por_cobrar(bigint)',
    'public.reporte_ventas_por_preventista(date,date,bigint)',
    'public.reporte_rentabilidad(date,date,bigint)'
  ] LOOP
    IF NOT has_function_privilege('authenticated', v_fn, 'EXECUTE') THEN
      RAISE EXCEPTION '#1009 · % perdió el EXECUTE de authenticated', v_fn;
    END IF;
    IF has_function_privilege('anon', v_fn, 'EXECUTE') THEN
      RAISE EXCEPTION '#1009 · % quedó ejecutable por anon', v_fn;
    END IF;
  END LOOP;

  -- 8.2b · La policy que copian puede_leer_pedido y el inline de deuda_previa
  --        sigue diciendo lo mismo. Si alguien la cambió en paralelo, esto
  --        frena la migración en vez de dejar dos criterios distintos.
  IF (SELECT qual FROM pg_policies
       WHERE schemaname = 'public' AND tablename = 'pedidos'
         AND policyname = 'mt_pedidos_select')
     IS DISTINCT FROM
     '((es_encargado_o_admin() OR (usuario_id = auth.uid()) OR (transportista_id = auth.uid())) AND (sucursal_id = current_sucursal_id()))'
  THEN
    RAISE EXCEPTION '#1009 · mt_pedidos_select cambió: revisar puede_leer_pedido y el inline de deuda_previa';
  END IF;
  IF (SELECT count(*) FROM pg_policies
       WHERE schemaname = 'public' AND tablename = 'pedidos'
         AND cmd IN ('SELECT', 'ALL') AND permissive = 'PERMISSIVE') <> 1 THEN
    RAISE EXCEPTION '#1009 · pedidos tiene más de una policy de SELECT: puede_leer_pedido ya no es toda la visibilidad';
  END IF;

  -- 8.3 · SEG-A en cero, y presente en auditoria_integridad().
  SELECT string_agg(firma, ', ') INTO v_lista FROM public.auditoria_definer_sin_rol();
  IF v_lista IS NOT NULL THEN
    RAISE EXCEPTION '#1009 · SEG-A no está en cero: %', v_lista;
  END IF;

  SELECT c INTO v_check
    FROM jsonb_array_elements(public.auditoria_integridad() -> 'checks') c
   WHERE c->>'id' = 'SEG-A';
  IF v_check IS NULL THEN
    RAISE EXCEPTION '#1009 · SEG-A no aparece en auditoria_integridad()';
  END IF;
  IF (SELECT count(*) FROM jsonb_array_elements(public.auditoria_integridad() -> 'checks') c
       WHERE c->>'id' = 'SEG-A') <> 1 THEN
    RAISE EXCEPTION '#1009 · el id SEG-A está repetido en auditoria_integridad()';
  END IF;

  -- 8.4 · El check muerde: una DEFINER nueva, expuesta y sin rol, aparece.
  --       El sub-bloque se deshace solo con un SQLSTATE centinela.
  BEGIN
    CREATE FUNCTION public._canario_seg_a() RETURNS int
      LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
      AS $c$ SELECT 1 $c$;
    GRANT EXECUTE ON FUNCTION public._canario_seg_a() TO authenticated;
    IF NOT EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol()
                    WHERE firma = '_canario_seg_a()') THEN
      RAISE EXCEPTION '#1009 · SEG-A no detecta una DEFINER expuesta sin rol';
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- 8.5 · Y no salta con una que nombra el helper.
  BEGIN
    CREATE FUNCTION public._canario_seg_a() RETURNS boolean
      LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
      AS $c$ SELECT es_encargado_o_admin() $c$;
    GRANT EXECUTE ON FUNCTION public._canario_seg_a() TO authenticated;
    IF EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol()
                WHERE firma = '_canario_seg_a()') THEN
      RAISE EXCEPTION '#1009 · SEG-A marca una función que sí chequea el rol';
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;
END
$verif$;

DROP FUNCTION public._migrol_ancla(regprocedure, text, text);

COMMIT;
