-- =========================================================================
-- NNN · CIERRES DE PERMISOS QUE ESPERAN A QUE NO QUEDEN BUNDLES VIEJOS
--       (plan #1603, ola 2, tanda 5, tarjeta C6: 1601-b5 de #1601, 1564-b6 parte 2 y
--        1564-b7 de #1564, 1595-b6 residual de #1595)
--
-- Ensayo: scripts/test-cierres-permisos-ola2-1603.sql. Se aplica en LF.
-- NO va junto con la migración de integridad de la misma tarjeta (linaje de pagos y metas).
--
-- CUÁNDO: cada bloque cierra algo que un bundle viejo del PWA todavía usa. Se aplica cuando
-- los logs del gateway (consultas del informe de la tarjeta C6) muestren que ya no quedan
-- pedidos de bundles anteriores a los de abajo. Los cinco bloques son independientes: si el
-- dueño decide fechas distintas, se parte el archivo por bloque (cada uno trae su premisa
-- y su poscondición) sin tocar nada más.
--
--   1 · emails_de_usuarios(uuid[]) (RPC nueva). No rompe nada; el front de este PR la usa
--       (y mientras no existe, lee la tabla). Se puede aplicar sola, antes que el resto.
--   2 · perfiles.email (1601-b5, D53: los emails de los demás los leen admin y encargado).
--       REVOKE SELECT de la tabla y GRANT por columna de todas menos email. Rompe a todo
--       bundle anterior al front de este PR: pide `select=*` de su propio perfil al entrar
--       (useAuth) y de las listas de usuarios, y `id,nombre,email` en la lista de pedidos;
--       con esto, 42501 en la consulta ENTERA, para todos los roles: el login no encuentra
--       el perfil y cierra la sesión.
--   3 · politicas_comerciales (1564-b6 parte 2, D50): authenticated lee por REST sólo lo de
--       vender (POLITICA_COLUMNAS_PARA_VENDER, más sucursal_id); lo reservado, por
--       politica_comercial_reservada(). Rompe a todo bundle anterior al merge del PR #1648
--       (17/11/2026 14:53): su select nombra las comisiones, la ventana del precio anterior
--       y los topes del combo; con esto, 42501 en la consulta entera: la política queda en
--       la última que el teléfono cacheó, o en los valores por defecto (compra mínima 0)
--       si no tiene caché. El server sigue validando el mínimo en el alta.
--   4 · pedidos.updated_at (1595-b6 residual): sale del GRANT UPDATE de authenticated. La
--       versión la pone el server desde la 519 (pedidos_proteger_columnas), así que el
--       GRANT ya no deja hacer nada: el cierre es de prolijidad. Rompe a todo bundle
--       anterior al merge del PR #1647 (17/11/2026 14:00): su cambio de estado
--       (actualizarEstado: marcar entregado, pasar a en preparación o asignado) manda
--       `updated_at` en el PATCH; con esto, 42501 y el cambio no se guarda.
--   5 · Las facturas escaneadas por la sucursal activa (1564-b7, D51: «un usuario de dos
--       sucursales ve las facturas escaneadas sólo de la sucursal en la que está
--       trabajando»). Las tres policies del bucket `facturas` comparan el primer tramo del
--       path con current_sucursal_id() en vez de con todas las sucursales del usuario. No
--       rompe ningún bundle: todos suben y abren con el header X-Sucursal-ID de la sucursal
--       activa (el fetch global de src/lib/supabase.ts), y storage-api pasa los headers del
--       request a request.headers. Verificar en prod una subida desde la sucursal que NO es
--       la default de un usuario de dos sucursales, apenas se aplique. Sin storage.objects
--       (la base local y la del CI) el bloque no hace nada y lo avisa.
--
-- LOCKS: los GRANT y REVOKE no bloquean la tabla (sólo el catálogo). Las policies de
-- storage.objects sí: el bloque 5 toma ACCESS EXCLUSIVE NOWAIT sobre storage.objects antes
-- de tocarlas. Ningún otro DDL de tabla.
-- =========================================================================

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

SET LOCAL lock_timeout = '5s';

-- Lo único con DDL de tabla es el bloque 5; el lock va primero, como pide la regla.
DO $locks$
BEGIN
  IF to_regclass('storage.objects') IS NOT NULL THEN
    EXECUTE 'LOCK TABLE storage.objects IN ACCESS EXCLUSIVE MODE NOWAIT';
  END IF;
END
$locks$;

-- -------------------------------------------------------------------------
-- 1 · emails_de_usuarios: el email de otro, sólo para admin y encargado (D53)
-- -------------------------------------------------------------------------
DO $p1$
BEGIN
  IF to_regprocedure('public.emails_de_usuarios(uuid[])') IS NOT NULL THEN
    RAISE EXCEPTION 'bloque 1 · emails_de_usuarios ya existe';
  END IF;
  IF to_regprocedure('public.perfil_de_sucursal_activa(uuid)') IS NULL
     OR to_regprocedure('public.admin_comparte_sucursal_con(uuid)') IS NULL THEN
    RAISE EXCEPTION 'bloque 1 · faltan los helpers de visibilidad de perfiles';
  END IF;
END
$p1$;

CREATE FUNCTION public.emails_de_usuarios(p_ids uuid[])
RETURNS TABLE (id uuid, email text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  -- 1601-b5 (#1601, decisión del dueño D53): los emails de los demás usuarios los leen admin
  -- y encargado; cada uno, el suyo. A quién ve cada uno es lo mismo que las policies de
  -- SELECT de perfiles: su sucursal activa (perfiles_select_sucursal) y, el admin, quien
  -- comparte alguna sucursal con él (perfiles_select_admin). Un desactivado no es admin ni
  -- encargado (#1474): recibe sólo el suyo.
  SELECT p.id, p.email
    FROM perfiles p
   WHERE p.id = ANY(p_ids)
     AND (p.id = auth.uid()
          OR (es_encargado_o_admin()
              AND (perfil_de_sucursal_activa(p.id) OR admin_comparte_sucursal_con(p.id))));
$function$;

REVOKE ALL ON FUNCTION public.emails_de_usuarios(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.emails_de_usuarios(uuid[]) TO authenticated;

-- -------------------------------------------------------------------------
-- 2 · perfiles.email deja de leerse por REST (D53)
-- -------------------------------------------------------------------------
DO $p2$
BEGIN
  -- Un REVOKE de tabla borra también los grants por columna del mismo privilegio
  -- (CLAUDE.md): se exige que hoy no haya ninguno, y que las columnas sean las de hoy.
  IF NOT has_table_privilege('authenticated', 'public.perfiles', 'SELECT')
     OR EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.perfiles'::regclass
                   AND attnum > 0 AND attacl IS NOT NULL)
     OR has_table_privilege('anon', 'public.perfiles', 'SELECT')
     OR (SELECT string_agg(attname, ',' ORDER BY attname) FROM pg_attribute
          WHERE attrelid = 'public.perfiles'::regclass AND attnum > 0 AND NOT attisdropped)
        <> 'activo,created_at,email,id,nombre,rol,zona' THEN
    RAISE EXCEPTION 'bloque 2 · los grants o las columnas de perfiles no son los esperados: revisar a mano';
  END IF;
END
$p2$;

REVOKE SELECT ON public.perfiles FROM authenticated;
GRANT SELECT (id, nombre, rol, activo, created_at, zona) ON public.perfiles TO authenticated;

COMMENT ON COLUMN public.perfiles.email IS
  'No se lee por REST (1601-b5, D53): authenticated tiene SELECT columna por columna sin ésta. El de otro usuario lo da emails_de_usuarios() a admin y encargado; el propio está en la sesión.';

-- -------------------------------------------------------------------------
-- 3 · politicas_comerciales: lo reservado, sólo por la RPC (1564-b6 parte 2, D50)
-- -------------------------------------------------------------------------
DO $p3$
BEGIN
  IF to_regprocedure('public.politica_comercial_reservada()') IS NULL THEN
    RAISE EXCEPTION 'bloque 3 · falta politica_comercial_reservada (la parte 1, migración 522)';
  END IF;
  IF NOT has_table_privilege('authenticated', 'public.politicas_comerciales', 'SELECT')
     OR EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.politicas_comerciales'::regclass
                   AND attnum > 0 AND attacl IS NOT NULL)
     OR has_table_privilege('authenticated', 'public.politicas_comerciales', 'INSERT, UPDATE, DELETE')
     OR has_table_privilege('anon', 'public.politicas_comerciales', 'SELECT')
     OR (SELECT string_agg(attname, ',' ORDER BY attname) FROM pg_attribute
          WHERE attrelid = 'public.politicas_comerciales'::regclass AND attnum > 0 AND NOT attisdropped)
        <> 'actualizado_en,actualizado_por,cargo_envio_pedido,combo_descuento_maximo_pct,combo_margen_minimo_pct,'
           'comision_pct_otros,comision_pct_preventista,dias_alerta_vencimiento,dias_atras_fecha_pedido,'
           'dias_critico_vencimiento,modo_minimo_pedido,monto_envio_gratis,monto_minimo_pedido,'
           'mostrar_sin_stock,multiplo_redondeo_precio,sucursal_id,ventana_precio_anterior_horas' THEN
    RAISE EXCEPTION 'bloque 3 · los grants o las columnas de politicas_comerciales no son los esperados: revisar a mano';
  END IF;
END
$p3$;

REVOKE SELECT ON public.politicas_comerciales FROM authenticated;
GRANT SELECT (sucursal_id, monto_minimo_pedido, modo_minimo_pedido, monto_envio_gratis, cargo_envio_pedido,
              mostrar_sin_stock, dias_atras_fecha_pedido, dias_alerta_vencimiento, dias_critico_vencimiento,
              multiplo_redondeo_precio)
  ON public.politicas_comerciales TO authenticated;

-- -------------------------------------------------------------------------
-- 4 · pedidos.updated_at sale del GRANT UPDATE (1595-b6 residual)
-- -------------------------------------------------------------------------
DO $p4$
BEGIN
  IF NOT has_column_privilege('authenticated', 'public.pedidos', 'updated_at', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.pedidos', 'UPDATE') THEN
    RAISE EXCEPTION 'bloque 4 · el UPDATE de pedidos no es por columnas con updated_at: revisar a mano';
  END IF;
END
$p4$;

REVOKE UPDATE (updated_at) ON public.pedidos FROM authenticated;

-- -------------------------------------------------------------------------
-- 5 · Las facturas escaneadas, de la sucursal activa (1564-b7, D51)
-- -------------------------------------------------------------------------
DO $p5$
DECLARE
  v_n integer;
BEGIN
  IF to_regclass('storage.objects') IS NULL THEN
    RAISE NOTICE 'bloque 5 · no hay storage.objects (base local o CI): las policies de facturas no se tocan';
    RETURN;
  END IF;

  SELECT count(*) INTO v_n
    FROM pg_policies
   WHERE schemaname = 'storage' AND tablename = 'objects'
     AND policyname IN ('facturas_select_encargado_o_admin', 'facturas_insert_encargado_o_admin', 'facturas_delete_admin');
  IF v_n <> 3 THEN
    RAISE EXCEPTION 'bloque 5 · esperaba las tres policies de facturas de la 463, hay %', v_n;
  END IF;

  -- El path es `<sucursal_id>/<uuid>.<ext>` (ModalCompra y escanear-factura/ruta.ts). Se compara
  -- como texto, sin cast: un path viejo (`facturas/…`) no tira error, sólo no matchea. Con un
  -- header de una sucursal que no es suya, current_sucursal_id() da NULL y no matchea nada.
  EXECUTE 'DROP POLICY facturas_select_encargado_o_admin ON storage.objects';
  EXECUTE 'DROP POLICY facturas_insert_encargado_o_admin ON storage.objects';
  EXECUTE 'DROP POLICY facturas_delete_admin ON storage.objects';

  EXECUTE $pol$
    CREATE POLICY facturas_select_encargado_o_admin ON storage.objects
      FOR SELECT TO authenticated
      USING (
        bucket_id = 'facturas'
        AND public.es_encargado_o_admin()
        AND (storage.foldername(name))[1] = public.current_sucursal_id()::text
      )
  $pol$;
  EXECUTE $pol$
    CREATE POLICY facturas_insert_encargado_o_admin ON storage.objects
      FOR INSERT TO authenticated
      WITH CHECK (
        bucket_id = 'facturas'
        AND public.es_encargado_o_admin()
        AND (storage.foldername(name))[1] = public.current_sucursal_id()::text
      )
  $pol$;
  EXECUTE $pol$
    CREATE POLICY facturas_delete_admin ON storage.objects
      FOR DELETE TO authenticated
      USING (
        bucket_id = 'facturas'
        AND public.es_admin()
        AND (storage.foldername(name))[1] = public.current_sucursal_id()::text
      )
  $pol$;
END
$p5$;

-- -------------------------------------------------------------------------
-- Poscondición
-- -------------------------------------------------------------------------
DO $post$
DECLARE
  v_n integer;
BEGIN
  IF has_function_privilege('anon', 'public.emails_de_usuarios(uuid[])', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.emails_de_usuarios(uuid[])', 'EXECUTE') THEN
    RAISE EXCEPTION 'poscondición · los permisos de emails_de_usuarios no son los esperados';
  END IF;
  IF has_column_privilege('authenticated', 'public.perfiles', 'email', 'SELECT')
     OR NOT has_column_privilege('authenticated', 'public.perfiles', 'nombre', 'SELECT')
     OR NOT has_column_privilege('authenticated', 'public.perfiles', 'activo', 'SELECT')
     OR NOT has_table_privilege('authenticated', 'public.perfiles', 'UPDATE')
     OR has_column_privilege('anon', 'public.perfiles', 'nombre', 'SELECT') THEN
    RAISE EXCEPTION 'poscondición · los grants de perfiles no quedaron como se esperaba';
  END IF;
  IF has_column_privilege('authenticated', 'public.politicas_comerciales', 'comision_pct_otros', 'SELECT')
     OR has_column_privilege('authenticated', 'public.politicas_comerciales', 'comision_pct_preventista', 'SELECT')
     OR has_column_privilege('authenticated', 'public.politicas_comerciales', 'combo_margen_minimo_pct', 'SELECT')
     OR has_column_privilege('authenticated', 'public.politicas_comerciales', 'combo_descuento_maximo_pct', 'SELECT')
     OR has_column_privilege('authenticated', 'public.politicas_comerciales', 'ventana_precio_anterior_horas', 'SELECT')
     OR has_column_privilege('authenticated', 'public.politicas_comerciales', 'actualizado_por', 'SELECT')
     OR NOT has_column_privilege('authenticated', 'public.politicas_comerciales', 'monto_minimo_pedido', 'SELECT')
     OR NOT has_column_privilege('authenticated', 'public.politicas_comerciales', 'multiplo_redondeo_precio', 'SELECT')
     OR has_column_privilege('anon', 'public.politicas_comerciales', 'monto_minimo_pedido', 'SELECT') THEN
    RAISE EXCEPTION 'poscondición · los grants de politicas_comerciales no quedaron como se esperaba';
  END IF;
  IF has_column_privilege('authenticated', 'public.pedidos', 'updated_at', 'UPDATE')
     OR NOT has_column_privilege('authenticated', 'public.pedidos', 'estado', 'UPDATE')
     OR NOT has_column_privilege('authenticated', 'public.pedidos', 'updated_at', 'SELECT') THEN
    RAISE EXCEPTION 'poscondición · los grants de pedidos no quedaron como se esperaba';
  END IF;
  IF to_regclass('storage.objects') IS NOT NULL THEN
    SELECT count(*) INTO v_n
      FROM pg_policies
     WHERE schemaname = 'storage' AND tablename = 'objects'
       AND policyname IN ('facturas_select_encargado_o_admin', 'facturas_insert_encargado_o_admin', 'facturas_delete_admin')
       AND COALESCE(qual, with_check) ~ 'current_sucursal_id\(\)'
       AND COALESCE(qual, with_check) !~ 'usuario_sucursales';
    IF v_n <> 3 THEN
      RAISE EXCEPTION 'poscondición · las policies de facturas no comparan con la sucursal activa (% de 3)', v_n;
    END IF;
  END IF;
END
$post$;

COMMIT;
