-- =========================================================================
-- NNN · CIERRES DE PERMISOS QUE ESPERAN A QUE NO QUEDEN BUNDLES VIEJOS
--       (plan #1603, ola 2, tanda 5, tarjeta C6: 1601-b5 de #1601, 1564-b6 parte 2 de #1564,
--        1595-b6 residual de #1595)
--
-- Ensayo: scripts/test-cierres-permisos-ola2-1603.sql. Se aplica en LF, en una sola transacción
-- o sentencia por sentencia.
-- Necesita ANTES NNN_linaje_de_pagos_metas_y_emails (crea emails_de_usuarios, que reemplaza la
-- lectura del email por REST). No va con la de facturas.
--
-- CUÁNDO: los tres bloques juntos, cuando la medición del bloque 2 (la más estricta: consultas
-- D1/D2 del informe de la tarjeta C6, filtradas a la app web) dé 0 varios días seguidos. Cada
-- bloque trae su premisa y su poscondición.
--
--   1 · perfiles.email (1601-b5, D53: los emails de los demás los leen admin y encargado).
--       REVOKE SELECT de la tabla y GRANT por columna de todas menos email. Rompe a todo bundle
--       anterior a #1670: pide `select=*` de su propio perfil al entrar (useAuth) y de las
--       listas de usuarios, y `id,nombre,email` en la lista de pedidos; con esto, 42501 en la
--       consulta ENTERA, para todos los roles: el login no encuentra el perfil y cierra la sesión.
--   2 · politicas_comerciales (1564-b6 parte 2, D50): authenticated lee por REST sólo lo de
--       vender (POLITICA_COLUMNAS_PARA_VENDER, más sucursal_id); lo reservado, por
--       politica_comercial_reservada(). Rompe a todo bundle anterior al merge del PR #1648
--       (17/11/2026 14:53): su select nombra las comisiones, la ventana del precio anterior y los
--       topes del combo; con esto, 42501 en la consulta entera: la política queda en la última
--       que el teléfono cacheó, o en la de por defecto (compra mínima 0) si no tiene caché. El
--       server sigue validando el mínimo en el alta.
--   3 · pedidos.updated_at (1595-b6 residual): sale del GRANT UPDATE de authenticated. La versión
--       la pone el server desde la 519 (pedidos_proteger_columnas), así que el GRANT ya no deja
--       hacer nada: el cierre es de prolijidad. Rompe a todo bundle anterior al merge del PR
--       #1647 (17/11/2026 14:00): su cambio de estado (marcar entregado, en preparación,
--       asignado) manda `updated_at` en el PATCH; con esto, 42501 y el cambio no se guarda.
--
-- LOCKS: ninguno de tabla. Los GRANT y REVOKE no bloquean la tabla (sólo el catálogo).
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

-- -------------------------------------------------------------------------
-- 1 · perfiles.email deja de leerse por REST (D53)
-- -------------------------------------------------------------------------
DO $p1$
BEGIN
  IF to_regprocedure('public.emails_de_usuarios(uuid[])') IS NULL THEN
    RAISE EXCEPTION 'bloque 1 · falta emails_de_usuarios (NNN_linaje_de_pagos_metas_y_emails): aplicarla antes';
  END IF;
  -- Un REVOKE de tabla borra también los grants por columna del mismo privilegio (CLAUDE.md):
  -- se exige que hoy no haya ninguno, y que las columnas sean las de hoy.
  IF NOT has_table_privilege('authenticated', 'public.perfiles', 'SELECT')
     OR EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.perfiles'::regclass
                   AND attnum > 0 AND attacl IS NOT NULL)
     OR has_table_privilege('anon', 'public.perfiles', 'SELECT')
     OR (SELECT string_agg(attname, ',' ORDER BY attname) FROM pg_attribute
          WHERE attrelid = 'public.perfiles'::regclass AND attnum > 0 AND NOT attisdropped)
        <> 'activo,created_at,email,id,nombre,rol,zona' THEN
    RAISE EXCEPTION 'bloque 1 · los grants o las columnas de perfiles no son los esperados: revisar a mano';
  END IF;
END
$p1$;

REVOKE SELECT ON public.perfiles FROM authenticated;
GRANT SELECT (id, nombre, rol, activo, created_at, zona) ON public.perfiles TO authenticated;

COMMENT ON COLUMN public.perfiles.email IS
  'No se lee por REST (1601-b5, D53): authenticated tiene SELECT columna por columna sin ésta. El de otro usuario lo da emails_de_usuarios() a admin y encargado; el propio está en la sesión.';

DO $post1$
BEGIN
  IF has_column_privilege('authenticated', 'public.perfiles', 'email', 'SELECT')
     OR NOT has_column_privilege('authenticated', 'public.perfiles', 'nombre', 'SELECT')
     OR NOT has_column_privilege('authenticated', 'public.perfiles', 'activo', 'SELECT')
     OR NOT has_table_privilege('authenticated', 'public.perfiles', 'UPDATE')
     OR has_column_privilege('anon', 'public.perfiles', 'nombre', 'SELECT') THEN
    RAISE EXCEPTION 'bloque 1 · poscondición: los grants de perfiles no quedaron como se esperaba';
  END IF;
END
$post1$;

-- -------------------------------------------------------------------------
-- 2 · politicas_comerciales: lo reservado, sólo por la RPC (1564-b6 parte 2, D50)
-- -------------------------------------------------------------------------
DO $p2$
BEGIN
  IF to_regprocedure('public.politica_comercial_reservada()') IS NULL THEN
    RAISE EXCEPTION 'bloque 2 · falta politica_comercial_reservada (la parte 1, migración 522)';
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
    RAISE EXCEPTION 'bloque 2 · los grants o las columnas de politicas_comerciales no son los esperados: revisar a mano';
  END IF;
END
$p2$;

REVOKE SELECT ON public.politicas_comerciales FROM authenticated;
GRANT SELECT (sucursal_id, monto_minimo_pedido, modo_minimo_pedido, monto_envio_gratis, cargo_envio_pedido,
              mostrar_sin_stock, dias_atras_fecha_pedido, dias_alerta_vencimiento, dias_critico_vencimiento,
              multiplo_redondeo_precio)
  ON public.politicas_comerciales TO authenticated;

DO $post2$
BEGIN
  IF has_column_privilege('authenticated', 'public.politicas_comerciales', 'comision_pct_otros', 'SELECT')
     OR has_column_privilege('authenticated', 'public.politicas_comerciales', 'comision_pct_preventista', 'SELECT')
     OR has_column_privilege('authenticated', 'public.politicas_comerciales', 'combo_margen_minimo_pct', 'SELECT')
     OR has_column_privilege('authenticated', 'public.politicas_comerciales', 'combo_descuento_maximo_pct', 'SELECT')
     OR has_column_privilege('authenticated', 'public.politicas_comerciales', 'ventana_precio_anterior_horas', 'SELECT')
     OR has_column_privilege('authenticated', 'public.politicas_comerciales', 'actualizado_por', 'SELECT')
     OR NOT has_column_privilege('authenticated', 'public.politicas_comerciales', 'monto_minimo_pedido', 'SELECT')
     OR NOT has_column_privilege('authenticated', 'public.politicas_comerciales', 'multiplo_redondeo_precio', 'SELECT')
     OR has_column_privilege('anon', 'public.politicas_comerciales', 'monto_minimo_pedido', 'SELECT') THEN
    RAISE EXCEPTION 'bloque 2 · poscondición: los grants de politicas_comerciales no quedaron como se esperaba';
  END IF;
END
$post2$;

-- -------------------------------------------------------------------------
-- 3 · pedidos.updated_at sale del GRANT UPDATE (1595-b6 residual)
-- -------------------------------------------------------------------------
DO $p3$
BEGIN
  IF NOT has_column_privilege('authenticated', 'public.pedidos', 'updated_at', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.pedidos', 'UPDATE') THEN
    RAISE EXCEPTION 'bloque 3 · el UPDATE de pedidos no es por columnas con updated_at: revisar a mano';
  END IF;
END
$p3$;

REVOKE UPDATE (updated_at) ON public.pedidos FROM authenticated;

DO $post3$
BEGIN
  IF has_column_privilege('authenticated', 'public.pedidos', 'updated_at', 'UPDATE')
     OR NOT has_column_privilege('authenticated', 'public.pedidos', 'estado', 'UPDATE')
     OR NOT has_column_privilege('authenticated', 'public.pedidos', 'updated_at', 'SELECT') THEN
    RAISE EXCEPTION 'bloque 3 · poscondición: los grants de pedidos no quedaron como se esperaba';
  END IF;
END
$post3$;

COMMIT;
