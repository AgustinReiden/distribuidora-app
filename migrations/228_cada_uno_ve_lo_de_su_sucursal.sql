-- Cuatro policies dejaban leer o escribir de más. Se cierran las cuatro acá.
--
-- 1. `perfiles` era legible con la anon key: `perfiles_select_all` no tenía
--    cláusula TO (⇒ PUBLIC) y `USING (true)`, y el baseline le hace GRANT ALL a
--    anon. Con la anon key del bundle, sin loguearse, salían los 17 empleados
--    con email, nombre y rol. Era la única tabla que se filtraba.
-- 2. `cp_select` / `cdc_select` eran `USING (true)`: cualquier logueado, de
--    cualquier sucursal, leía entero el mapa cliente→preventista y los
--    descuentos pactados. Ninguna de las dos tablas tiene `sucursal_id`.
-- 3. `usuario_sucursales_admin_all` era FOR ALL con la sola condición
--    rol = 'admin', y `asignar_usuario_sucursal` sólo chequeaba `es_admin()`:
--    un admin de una sucursal se insertaba a sí mismo en la otra y
--    `current_sucursal_id()` pasaba a autorizarlo.
--
-- ── Por qué los dos helpers SECURITY DEFINER y no el EXISTS directo ──────────
--
-- Las subconsultas de una policy corren con la RLS de la tabla que tocan. Eso
-- rompe las dos formas "obvias" de escribir esto, y las dos fallan calladas:
--
--   a) `EXISTS (SELECT 1 FROM usuario_sucursales us WHERE us.usuario_id =
--      perfiles.id AND us.sucursal_id = current_sucursal_id())` dentro de una
--      policy de `perfiles` ve sólo lo que el caller ve de `usuario_sucursales`,
--      y un preventista sólo ve SU fila (`usuario_sucursales_select_own`).
--      Medido en prod: el EXISTS devolvía 1 perfil en vez de los 11 de la
--      sucursal. `usePedidosQuery` no usa embed para esto —hace un segundo
--      SELECT sobre `perfiles` y arma un map— así que no da error: `usuario` y
--      `transportista` quedaban en null en cada pedido, sin ruido.
--
--   b) `EXISTS (SELECT 1 FROM clientes c ...)` dentro de una policy de
--      `cliente_preventistas` es peor: `mt_clientes_select` ya subconsulta
--      `cliente_preventistas`, así que se cierra el ciclo y Postgres tira
--      `42P17: infinite recursion detected in policy for relation "clientes"`.
--      Verificado en prod: TODA lectura de `clientes` se caía.
--
-- Un SECURITY DEFINER corta las dos cosas: no aplica la RLS de la tabla que lee,
-- así que ni se recorta ni recursa. Los dos son STABLE y fallan cerrado
-- (`current_sucursal_id()` devuelve NULL si el header no está autorizado, y
-- `x = NULL` nunca es true).

-- ── Helpers ─────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.perfil_de_sucursal_activa(p_usuario_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
  SELECT EXISTS (
    SELECT 1 FROM usuario_sucursales us
    WHERE us.usuario_id = p_usuario_id
      AND us.sucursal_id = current_sucursal_id()
  );
$fn$;

REVOKE ALL ON FUNCTION public.perfil_de_sucursal_activa(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.perfil_de_sucursal_activa(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.cliente_de_sucursal_activa(p_cliente_id bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
  SELECT EXISTS (
    SELECT 1 FROM clientes c
    WHERE c.id = p_cliente_id
      AND c.sucursal_id = current_sucursal_id()
  );
$fn$;

REVOKE ALL ON FUNCTION public.cliente_de_sucursal_activa(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cliente_de_sucursal_activa(bigint) TO authenticated, service_role;

-- ── 1. perfiles ─────────────────────────────────────────────────────────────

-- El agujero: TO PUBLIC + USING (true).
DROP POLICY IF EXISTS "perfiles_select_all" ON perfiles;

-- Duplicada del baseline: `USING (auth.uid() IS NOT NULL)` para PUBLIC. No
-- filtraba a anon (auth.uid() es NULL sin JWT), pero es un segundo
-- "todos ven a todos" que dejaría la policy por sucursal de abajo en puro
-- adorno: mientras viva, cualquier logueado sigue leyendo los 17 perfiles.
DROP POLICY IF EXISTS "Perfiles: lectura usuarios autenticados" ON perfiles;

-- Duplicada de "Perfiles: actualizacion propio o admin", que ya cubre al admin
-- con es_admin(). Es la única de las tres legacy con is_admin() que sobra:
-- perfiles_insert_admin y perfiles_delete_admin son las ÚNICAS policies de
-- INSERT/DELETE de la tabla, así que se quedan (dropearlas no cerraría un
-- agujero, dejaría a los admins sin poder dar de alta ni de baja un perfil).
DROP POLICY IF EXISTS "perfiles_update_admin" ON perfiles;

-- Lo que reemplaza a la permisividad: cada uno ve los perfiles de su sucursal
-- activa. Es exactamente el recorte que `useUsuariosQuery` ya hacía a mano con
-- `usuario_sucursales!inner`; ahora también lo hace la base.
CREATE POLICY "perfiles_select_sucursal" ON perfiles
  FOR SELECT TO authenticated
  USING (perfil_de_sucursal_activa(id));

-- La otra mitad: sin esto la tabla sigue teniendo SELECT concedido a anon y
-- alcanza con que alguien vuelva a crear una policy permisiva para reabrir todo.
REVOKE SELECT ON perfiles FROM anon;

-- ── 2. cliente_preventistas y cliente_descuentos_categoria ──────────────────

-- Ojo con el `AND (es_encargado_o_admin() OR preventista_id = auth.uid())` que
-- parece la parte importante: acá AFLOJA en vez de apretar. `mt_clientes_select`
-- decide "este cliente no es de nadie, lo ven todos" (mig 028) con
-- `NOT EXISTS (SELECT 1 FROM cliente_preventistas WHERE cliente_id = ...)`. Si
-- un preventista deja de ver las filas de SUS COLEGAS, ese NOT EXISTS pasa a ser
-- true y los clientes ajenos se le vuelven huérfanos → visibles. Medido en prod
-- con el helper puesto: el preventista pasaba de ver 209 clientes a ver 588.
-- Por eso el recorte acá es sólo por sucursal, que es la fuga real.
DROP POLICY IF EXISTS "cp_select" ON cliente_preventistas;
CREATE POLICY "cp_select" ON cliente_preventistas
  FOR SELECT TO authenticated
  USING (cliente_de_sucursal_activa(cliente_id));

DROP POLICY IF EXISTS "cdc_select" ON cliente_descuentos_categoria;
CREATE POLICY "cdc_select" ON cliente_descuentos_categoria
  FOR SELECT TO authenticated
  USING (cliente_de_sucursal_activa(cliente_id));

-- ── 3. usuario_sucursales ───────────────────────────────────────────────────

-- Un admin sólo administra la sucursal en la que está parado. Para SELECT le
-- siguen quedando `usuario_sucursales_select_own` (sus propias filas, sin filtro
-- de sucursal: es lo que usa SucursalContext para poder cambiar de sucursal
-- ANTES de que exista el header) y `usuario_sucursales_select_sucursal_activa`.
DROP POLICY IF EXISTS "usuario_sucursales_admin_all" ON usuario_sucursales;
CREATE POLICY "usuario_sucursales_admin_all" ON usuario_sucursales
  FOR ALL TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id())
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());

-- Las RPCs son SECURITY DEFINER: se saltean la policy de arriba, así que el
-- mismo chequeo va escrito adentro o no vale nada.
CREATE OR REPLACE FUNCTION public.asignar_usuario_sucursal(
  p_usuario_id uuid,
  p_sucursal_id bigint,
  p_rol character varying DEFAULT 'mismo'::character varying,
  p_es_default boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT es_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin puede asignar sucursales');
  END IF;

  -- Sin esto, un admin de la sucursal 1 se agrega a sí mismo a la 2 y
  -- current_sucursal_id() lo autoriza a partir de ahí.
  IF NOT EXISTS (
    SELECT 1 FROM usuario_sucursales
    WHERE usuario_id = auth.uid() AND sucursal_id = p_sucursal_id
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo podés asignar usuarios a una sucursal a la que pertenecés');
  END IF;

  INSERT INTO usuario_sucursales (usuario_id, sucursal_id, rol, es_default)
  VALUES (p_usuario_id, p_sucursal_id, p_rol, p_es_default)
  ON CONFLICT (usuario_id, sucursal_id) DO UPDATE
    SET rol = EXCLUDED.rol,
        es_default = EXCLUDED.es_default;

  IF p_es_default THEN
    UPDATE usuario_sucursales SET es_default = false
     WHERE usuario_id = p_usuario_id AND sucursal_id <> p_sucursal_id;
  END IF;

  RETURN jsonb_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.asignar_usuario_sucursal(uuid, bigint, character varying, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.asignar_usuario_sucursal(uuid, bigint, character varying, boolean) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.desasignar_usuario_sucursal(
  p_usuario_id uuid,
  p_sucursal_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT es_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin puede desasignar sucursales');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM usuario_sucursales
    WHERE usuario_id = auth.uid() AND sucursal_id = p_sucursal_id
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo podés desasignar usuarios de una sucursal a la que pertenecés');
  END IF;

  DELETE FROM usuario_sucursales
   WHERE usuario_id = p_usuario_id AND sucursal_id = p_sucursal_id;

  RETURN jsonb_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.desasignar_usuario_sucursal(uuid, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.desasignar_usuario_sucursal(uuid, bigint) TO authenticated, service_role;

-- ── 4. El gate que faltaba ──────────────────────────────────────────────────

-- `auditoria_permisos_execute()` (mig 189) sólo mira FUNCIONES. Esta tabla se
-- filtró durante meses sin que ningún check dijera nada. Ésta mira TABLAS, y no
-- lo deduce del catálogo —una policy `USING (auth.uid() IS NOT NULL)` aplica a
-- PUBLIC y no filtra nada, un check estático la marcaría en rojo para siempre—
-- sino que se pone el sombrero de anon y hace el SELECT.
--
-- Es la ÚNICA función de auditoría que va SECURITY INVOKER, por dos razones que
-- se refuerzan: Postgres prohíbe `SET ROLE` dentro de un SECURITY DEFINER
-- (`42501: cannot set parameter "role" within security-definer function`), y el
-- permiso de `SET ROLE anon` se resuelve contra el session_user —que en
-- PostgREST es `authenticator`, miembro de anon— y no contra el rol efectivo.
-- Invoker además no agrega privilegio ninguno: hace exactamente lo que el
-- caller ya podía hacer. Sólo service_role la puede ejecutar.
CREATE OR REPLACE FUNCTION public.auditoria_tablas_anon()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'public'
AS $function$
DECLARE
  r              RECORD;
  v_legibles     jsonb := '[]'::jsonb;
  v_total        integer := 0;
  v_filas        bigint;
  v_rol_original text;
BEGIN
  v_rol_original := coalesce(current_setting('role', true), 'none');

  FOR r IN
    SELECT c.relname
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relkind IN ('r', 'p')
     ORDER BY c.relname
  LOOP
    v_total := v_total + 1;
    BEGIN
      -- set_config(...,true) == SET LOCAL. Se restaura a mano en los dos
      -- caminos: un RESET ROLE pelado volvería al session_user, no al rol con
      -- el que entró la request.
      PERFORM set_config('role', 'anon', true);
      EXECUTE format('SELECT count(*) FROM (SELECT 1 FROM public.%I LIMIT 1) s', r.relname)
         INTO v_filas;
      PERFORM set_config('role', v_rol_original, true);

      IF v_filas > 0 THEN
        v_legibles := v_legibles || jsonb_build_object('tabla', r.relname);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      -- permission denied, o RLS que no deja ni mirar: no es legible.
      PERFORM set_config('role', v_rol_original, true);
    END;
  END LOOP;

  PERFORM set_config('role', v_rol_original, true);

  RETURN jsonb_build_object(
    'generado_at',      now(),
    'total_tablas',     v_total,
    'legibles_anon',    jsonb_array_length(v_legibles),
    'detalle_legibles', v_legibles
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.auditoria_tablas_anon() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auditoria_tablas_anon() TO service_role;
