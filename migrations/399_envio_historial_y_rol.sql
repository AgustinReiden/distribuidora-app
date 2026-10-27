-- 399 · Cargo de envio: queda en el historial y se decide con el rol de la
-- sucursal (#1231, #1232).
--
-- Requiere 394 (cargo_1_base) y 395 (cargo_2_edicion).
--
-- 1 · #1231. pedido_historial no registraba el cargo de envio ni su estado: no
--     quedaba rastro de quien bonifico un envio ni de cuando un pedido paso a
--     pagarlo. Ahora, con el formato de los demas campos (una fila por campo,
--     valor anterior y nuevo en texto, el usuario que actua):
--       * actualizar_pedido_items anota 'cargo_envio' y 'cargo_envio_estado'
--         cuando la edicion los cambia. Son los valores de las COLUMNAS (el
--         cargo guardado, no el efectivo: sin productos el efectivo es 0 pero
--         la regla ya deja el cargo en 0 con estado 'gratis').
--       * cambiar_cliente_pedido anota en el pedido NUEVO lo mismo cuando
--         difiere del viejo. La reatribucion conserva cargo y estado
--         (app.cargo_envio_forzado / app.cargo_envio_estado_forzado), asi que
--         en la practica solo difiere si el pedido nuevo queda sin productos
--         (pedido_cargo_envio da 0 y el 'cobrado' forzado nace 'gratis'). Va
--         igual: el historial no supone que la regla de hoy sea la de manana.
--     El cargo se escribe con dos decimales (round(x, 2)::text), como lo lee el
--     front (parsePrecio).
--
-- 2 · #1232. El dialogo "¿Agregar/Sacar envio?" lo decide el front con el rol
--     de la sucursal activa (effectiveRol = currentSucursalRol ?? perfil.rol,
--     App.tsx: usuario_sucursales.rol, con 'mismo' = perfiles.rol), y la RPC lo
--     decidia con perfiles.rol. Con un usuario preventista en perfiles y
--     encargado en la sucursal, el front preguntaba y el server ignoraba la
--     respuesta en silencio; al reves (admin en perfiles, preventista en la
--     sucursal), el server pedia una decision que el front nunca muestra y la
--     edicion quedaba rechazada.
--     Ahora quien decide el envio sale de _rol_en_sucursal(usuario, sucursal),
--     que es exactamente esa semantica, y cae en perfiles.rol si el usuario no
--     tiene fila en la sucursal (el `?? perfil.rol` del front). SOLO para el
--     envio: el resto de las reglas de la funcion (precio, regalo, combos,
--     corte horario) siguen con perfiles.rol, como antes. No es perfil_roles:
--     esos son roles EXTRA (transportista) que no hacen a nadie admin ni
--     encargado.
--     _rol_en_sucursal es SECURITY DEFINER con EXECUTE solo para postgres y
--     service_role; esta funcion es DEFINER de postgres, asi que la llama
--     como su dueno. No cambia ningun grant.
--
-- El cuerpo NO se copia: se lee el vivo con pg_get_functiondef y se le
-- reemplazan anclas que tienen que aparecer exactamente una vez (molde 395).
-- Si el cuerpo vivo cambio, la migracion se cae en vez de pisar. Misma firma:
-- CREATE OR REPLACE conserva los permisos (authenticated y service_role; nada
-- para PUBLIC ni anon), y la verificacion de abajo lo comprueba.
--
-- Ensayo: scripts/test-envio-historial-rol.sql.

SET LOCAL lock_timeout = '5s';

CREATE OR REPLACE FUNCTION pg_temp.envhist_parchar(p_def text, p_viejo text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
  v_veces int := (length(p_def) - length(replace(p_def, p_viejo, ''))) / length(p_viejo);
BEGIN
  IF v_veces <> 1 THEN
    RAISE EXCEPTION '%: el ancla aparece % veces (se esperaba 1). El cuerpo vivo cambio: revisar a mano', p_que, v_veces;
  END IF;
  RETURN replace(p_def, p_viejo, p_nuevo);
END
$fn$;

-- ---------------------------------------------------------------------------
-- 1 · actualizar_pedido_items
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid,text)'::regprocedure);
BEGIN
  -- #1232: el rol que decide el envio es el de la sucursal (effectiveRol).
  v_def := pg_temp.envhist_parchar(v_def,
$q$  v_es_preventista := v_user_role NOT IN ('admin', 'encargado');$q$,
$q$  -- envio_historial_y_rol (#1232): quien decide el envio es el rol de la
  -- sucursal activa, el mismo que usa el front para mostrar el dialogo
  -- (effectiveRol = usuario_sucursales.rol, 'mismo' = perfiles.rol); sin fila
  -- en la sucursal, perfiles.rol. Solo para el envio: el resto de la funcion
  -- sigue con v_user_role.
  v_es_preventista := COALESCE(public._rol_en_sucursal(p_usuario_id, v_sucursal), v_user_role)
                        NOT IN ('admin', 'encargado');$q$,
    'actualizar_pedido_items: rol del envio');

  -- #1231: el cargo y su estado, en el historial, si cambiaron.
  v_def := pg_temp.envhist_parchar(v_def,
$q$    VALUES (p_pedido_id, p_usuario_id, 'total', v_total_anterior::TEXT, v_total_nuevo::TEXT, v_sucursal);
  END IF;$q$,
$q$    VALUES (p_pedido_id, p_usuario_id, 'total', v_total_anterior::TEXT, v_total_nuevo::TEXT, v_sucursal);
  END IF;

  -- envio_historial_y_rol (#1231): quien bonifico o cambio el envio. Las
  -- columnas como quedaron (el cargo guardado, no el efectivo).
  IF COALESCE(v_cargo_envio, 0) IS DISTINCT FROM COALESCE(v_cargo_tras.cargo, 0) THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (p_pedido_id, p_usuario_id, 'cargo_envio', round(COALESCE(v_cargo_envio, 0), 2)::TEXT,
            round(COALESCE(v_cargo_tras.cargo, 0), 2)::TEXT, v_sucursal);
  END IF;
  IF v_cargo_estado IS DISTINCT FROM v_cargo_tras.estado THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (p_pedido_id, p_usuario_id, 'cargo_envio_estado', v_cargo_estado, v_cargo_tras.estado, v_sucursal);
  END IF;$q$,
    'actualizar_pedido_items: historial del envio');

  EXECUTE v_def;
END
$patch$;

-- ---------------------------------------------------------------------------
-- 2 · cambiar_cliente_pedido
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text)'::regprocedure);
BEGIN
  v_def := pg_temp.envhist_parchar(v_def,
$q$  v_nuevo_id     BIGINT;$q$,
$q$  v_nuevo_id     BIGINT;
  -- envio_historial_y_rol (#1231): el cargo con que nacio el pedido nuevo.
  v_cargo_nuevo  NUMERIC;
  v_estado_nuevo TEXT;$q$,
    'cambiar_cliente_pedido: declaraciones');

  v_def := pg_temp.envhist_parchar(v_def,
$q$  RETURN jsonb_build_object(
    'success', true,
    'nuevo_pedido_id', v_nuevo_id,$q$,
$q$  -- envio_historial_y_rol (#1231): la reatribucion conserva cargo y estado;
  -- si el pedido nuevo nacio con otros (p. ej. sin productos: cargo 0,
  -- 'gratis'), queda anotado en el nuevo, contra lo que tenia el viejo.
  SELECT cargo_envio, cargo_envio_estado INTO v_cargo_nuevo, v_estado_nuevo
    FROM pedidos WHERE id = v_nuevo_id AND sucursal_id = v_sucursal;
  IF COALESCE(v_pedido.cargo_envio, 0) IS DISTINCT FROM COALESCE(v_cargo_nuevo, 0) THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (v_nuevo_id, v_acting, 'cargo_envio', round(COALESCE(v_pedido.cargo_envio, 0), 2)::TEXT,
            round(COALESCE(v_cargo_nuevo, 0), 2)::TEXT, v_sucursal);
  END IF;
  IF v_pedido.cargo_envio_estado IS DISTINCT FROM v_estado_nuevo THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (v_nuevo_id, v_acting, 'cargo_envio_estado', v_pedido.cargo_envio_estado, v_estado_nuevo, v_sucursal);
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'nuevo_pedido_id', v_nuevo_id,$q$,
    'cambiar_cliente_pedido: historial del envio');

  EXECUTE v_def;
END
$patch$;

-- ---------------------------------------------------------------------------
-- Verificacion
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  f     regprocedure;
  v_def text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.actualizar_pedido_items(bigint,jsonb,uuid,text)'::regprocedure,
    'public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text)'::regprocedure]
  LOOP
    v_def := pg_get_functiondef(f);
    IF v_def NOT LIKE '%envio_historial_y_rol (#1231)%' OR v_def NOT LIKE '%''cargo_envio_estado'', %' THEN
      RAISE EXCEPTION '% no quedo parcheada', f;
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = f)
       OR NOT ('search_path=public' = ANY (SELECT unnest(proconfig) FROM pg_proc WHERE oid = f)) THEN
      RAISE EXCEPTION '% perdio SECURITY DEFINER o su search_path', f;
    END IF;
    -- Permisos: los de la viva (authenticated y service_role; nada para anon ni PUBLIC).
    IF has_function_privilege('anon', f, 'EXECUTE')
       OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = f AND a.grantee = 0)
       OR NOT has_function_privilege('authenticated', f, 'EXECUTE')
       OR NOT has_function_privilege('service_role', f, 'EXECUTE') THEN
      RAISE EXCEPTION '% quedo con permisos distintos de la viva', f;
    END IF;
  END LOOP;

  IF pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid,text)'::regprocedure)
       NOT LIKE '%public._rol_en_sucursal(p_usuario_id, v_sucursal)%' THEN
    RAISE EXCEPTION 'actualizar_pedido_items no decide el envio con _rol_en_sucursal';
  END IF;
  -- _rol_en_sucursal sigue siendo de server.
  IF has_function_privilege('authenticated', 'public._rol_en_sucursal(uuid,bigint)', 'EXECUTE')
     OR has_function_privilege('anon', 'public._rol_en_sucursal(uuid,bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION '_rol_en_sucursal quedo alcanzable desde la API';
  END IF;
  -- Siguen validando el rol (SEG-A).
  IF EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol()
              WHERE firma LIKE 'actualizar_pedido_items(%' OR firma LIKE 'cambiar_cliente_pedido(%') THEN
    RAISE EXCEPTION 'actualizar_pedido_items o cambiar_cliente_pedido quedaron en rojo en SEG-A';
  END IF;
END
$verif$;

-- ROLLBACK: volver a crear las dos funciones con el cuerpo vivo de antes de
-- esta migracion (sacar los dos bloques 'envio_historial_y_rol' y devolver
-- v_es_preventista := v_user_role NOT IN ('admin', 'encargado')). Misma firma:
-- los permisos no cambian. Las filas 'cargo_envio' y 'cargo_envio_estado' que
-- ya se escribieron en pedido_historial se pueden quedar (son historia).
