-- NNN · Un desactivado no entra a los reportes, a las metas ni al bot de admin aunque su token
-- siga vivo (#1490, tarjeta 13 de #1477).
--
-- La 463 (#1474) hizo que es_admin(), es_encargado_o_admin(), es_preventista(),
-- es_transportista() y current_sucursal_id() den false/NULL para perfiles.activo = false. Estas
-- 22 RPCs no los usaban: decidían el permiso leyendo perfiles.rol de auth.uid() directo, y no
-- llaman a current_sucursal_id() antes del guard. Un admin o encargado dado de baja seguía
-- viendo /reportes (ventas, costos, márgenes, cuentas por cobrar), cargando metas y el análisis
-- mensual, y leyendo o tocando el bot de admin hasta que se le vencía el token.
--
-- El arreglo es SÓLO el guard: se cambia el texto que lee el rol por el helper equivalente de la
-- 463, y nada más del cuerpo. El bypass de servidor (`auth.uid() IS NOT NULL AND …`,
-- v_es_servicio) queda igual. Ningún número cambia para un usuario activo: el ensayo compara la
-- salida de cada reporte antes y después.
--   · `NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin')`
--       → `NOT public.es_admin()` (8 funciones).
--   · `SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();` + `IF v_rol IS DISTINCT FROM
--       'admin' THEN` → `IF NOT public.es_admin() THEN` (los 5 bot_admin_*).
--   · `SELECT rol INTO v_rol …;` + `IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado')
--       THEN` → `IF NOT public.es_encargado_o_admin() THEN` (los 8 reporte_* de /reportes).
--     v_rol queda declarada y sin uso: sacarla tocaría otra línea del cuerpo.
--   · asegurar_cargo_concepto: la rama encargado/depósito suma `AND COALESCE(activo, true)`,
--     como los helpers (no hay es_deposito()).
--
-- No se tocan las 35 que leen perfiles.rol sin activo pero ya rechazan a un desactivado por
-- otro lado (current_sucursal_id() NULL, bot_admin_puede_gestionar(), _tablero_sucursales()):
-- nada de refactors de paso. Quedan en scripts/rol-sin-activo-permitidas.json con su motivo, y
-- el ensayo prueba que rechazan.
--
-- Gate nuevo: auditoria_rol_sin_activo(), sólo de servidor, que lee scripts/check-rol-sin-activo.mjs.
-- Marca toda sentencia de una función ejecutable por authenticated que lee `perfiles` con
-- auth.uid() (o un alias de un salto, `v := auth.uid()`), nombra `rol` y no nombra `activo`.
--
-- Ensayo: scripts/test-desactivado-sin-rol-1490.sql.
-- Aplicar desde el contenido LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- -------------------------------------------------------------------------
-- 1 · Los guards usan los helpers de la 463
-- -------------------------------------------------------------------------
-- Premisa: md5(prosrc) de prod al 06/11 (ninguno con CRLF). Cada texto viejo aparece una sola
-- vez en el cuerpo, y el cuerpo nuevo es exactamente el viejo con ese reemplazo.
DO $guards$
DECLARE
  c_admin   CONSTANT text := 'NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = ''admin'')';
  c_bot     CONSTANT text := E'SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();\n  IF v_rol IS DISTINCT FROM ''admin'' THEN';
  c_rep     CONSTANT text := E'SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();\n    IF v_rol IS NULL OR v_rol NOT IN (''admin'', ''encargado'') THEN';
  c_cargo   CONSTANT text := 'WHERE id = auth.uid() AND rol IN (''encargado'', ''deposito'')))';
  r         record;
  v_oid     regprocedure;
  v_src     text;
  v_def     text;
  v_veces   int;
BEGIN
  FOR r IN
    SELECT t.firma, t.hash, t.viejo, t.nuevo FROM (VALUES
      ('auditoria_integridad()',                                   '89bed02a56b547e60fb052f48c47283a', c_admin, 'NOT public.es_admin()'),
      ('auditoria_sucursal_cruzada()',                             '4002d759942a0cdb966a8f94a2a1654b', c_admin, 'NOT public.es_admin()'),
      ('guardar_analisis_mensual(bigint,date,text,jsonb)',         'b991ebe7b420551f6609fe7da2dd1a41', c_admin, 'NOT public.es_admin()'),
      ('guardar_meta_gerencial(bigint,date,text,numeric)',         'e3c85895d9b93a18ad444a793f0ae9cd', c_admin, 'NOT public.es_admin()'),
      ('migraciones_aplicadas()',                                  '86459d81859ad9681c64cdad14932827', c_admin, 'NOT public.es_admin()'),
      ('posicion_fiscal(bigint,date,date)',                        'e1f7f9bec3e171b71d545b5be6a5dfab', c_admin, 'NOT public.es_admin()'),
      ('reporte_gerencial(bigint,date,date,boolean,boolean)',      '5438f0188ab423bf13c7421078e9cef9', c_admin, 'NOT public.es_admin()'),
      ('reporte_alerta_detalle(bigint,text,date,date,boolean)',    '91525e70910be3f4366b82d180f24110', c_admin, 'NOT public.es_admin()'),
      ('bot_admin_audit_log(date,date,text,uuid,integer)',         '2942c8565d12259c3f05a1f082e1594d', c_bot,   'IF NOT public.es_admin() THEN'),
      ('bot_admin_audit_summary(date,date)',                       '8d1df2487bb689ae5f278cb9af5d1cef', c_bot,   'IF NOT public.es_admin() THEN'),
      ('bot_admin_digests_enviados(date,date)',                    'd8194ac7d48cfcb410d19fdd3b798f22', c_bot,   'IF NOT public.es_admin() THEN'),
      ('bot_admin_listar_vinculados()',                            '752a8875179403776201683c7c90a4ab', c_bot,   'IF NOT public.es_admin() THEN'),
      ('bot_admin_toggle_usuario(bigint,boolean)',                 'a77537f78dc178b81a8ae13598a43a53', c_bot,   'IF NOT public.es_admin() THEN'),
      ('reporte_bonificaciones(date,date,bigint,integer)',         'd9f59c1f88a55fc301fcf4a9888f775f', c_rep,   'IF NOT public.es_encargado_o_admin() THEN'),
      ('reporte_cuentas_por_cobrar(bigint)',                       '3304593de122f74f4568eb104bb7bf8b', c_rep,   'IF NOT public.es_encargado_o_admin() THEN'),
      ('reporte_mermas(date,date,bigint,text,integer,integer,text)', '360bd6e53218e6698f012f3abd50cd0d', c_rep, 'IF NOT public.es_encargado_o_admin() THEN'),
      ('reporte_rechazos(date,date,bigint)',                       '7057482d5d636ca095c7003b0136aa29', c_rep,   'IF NOT public.es_encargado_o_admin() THEN'),
      ('reporte_rentabilidad(date,date,bigint,text)',              'b39a33f7a77706c1d73a4f78535bfa80', c_rep,   'IF NOT public.es_encargado_o_admin() THEN'),
      ('reporte_valuacion_inventario(bigint)',                     '2f6db6bbb250f7876ddea8f94b146dde', c_rep,   'IF NOT public.es_encargado_o_admin() THEN'),
      ('reporte_ventas_por_cliente(date,date,uuid,bigint)',        '1f0b4a5e561f0ddc78727a635a32c5ba', c_rep,   'IF NOT public.es_encargado_o_admin() THEN'),
      ('reporte_ventas_por_preventista(date,date,bigint)',         'eb473803fcdbe29c4de14360338d98e3', c_rep,   'IF NOT public.es_encargado_o_admin() THEN'),
      ('asegurar_cargo_concepto(text,integer,text,boolean,boolean,text,bigint)', 'bfa294528163c7cfd51b7ed4fd722f4d', c_cargo,
         'WHERE id = auth.uid() AND rol IN (''encargado'', ''deposito'') AND COALESCE(activo, true)))')
    ) AS t(firma, hash, viejo, nuevo)
  LOOP
    v_oid := to_regprocedure('public.' || r.firma);
    IF v_oid IS NULL THEN
      RAISE EXCEPTION '% no existe en prod: rehacer el parche', r.firma;
    END IF;
    SELECT prosrc INTO v_src FROM pg_proc WHERE oid = v_oid;
    IF md5(v_src) IS DISTINCT FROM r.hash THEN
      RAISE EXCEPTION '% cambió en prod (md5 %): rehacer el parche sobre el cuerpo vigente', r.firma, md5(v_src);
    END IF;
    v_veces := (length(v_src) - length(replace(v_src, r.viejo, ''))) / length(r.viejo);
    IF v_veces <> 1 THEN
      RAISE EXCEPTION '%: el guard viejo aparece % veces en el cuerpo, no una', r.firma, v_veces;
    END IF;
    v_def := pg_get_functiondef(v_oid);
    IF (length(v_def) - length(replace(v_def, r.viejo, ''))) / length(r.viejo) <> 1 THEN
      RAISE EXCEPTION '%: el guard viejo no aparece una sola vez en pg_get_functiondef', r.firma;
    END IF;

    EXECUTE replace(v_def, r.viejo, r.nuevo);

    IF (SELECT prosrc FROM pg_proc WHERE oid = v_oid) IS DISTINCT FROM replace(v_src, r.viejo, r.nuevo) THEN
      RAISE EXCEPTION '%: el cuerpo nuevo no es el viejo con sólo el guard cambiado', r.firma;
    END IF;
  END LOOP;
END
$guards$;

-- -------------------------------------------------------------------------
-- 2 · El gate: auditoria_rol_sin_activo()
-- -------------------------------------------------------------------------
-- Lo lee scripts/check-rol-sin-activo.mjs, que aplica la lista blanca
-- (scripts/rol-sin-activo-permitidas.json, sólo se achica). Lee texto, no ejecuta: antes de
-- partir en sentencias por `;` saca los comentarios y vacía los literales ('…' → ''), así un
-- mensaje de error que diga "rol" no cuenta. Lo que no ve: un alias de dos saltos, el usuario
-- pasado como parámetro, SQL dinámico (EXECUTE) y un `;` dentro de un literal $…$.
CREATE FUNCTION public.auditoria_rol_sin_activo()
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_catalog'
AS $function$
  WITH f AS (
    SELECT p.oid::regprocedure::text AS firma,
           p.prosecdef AS definer,
           regexp_replace(regexp_replace(regexp_replace(p.prosrc,
             '/\*.*?\*/', ' ', 'g'),
             '--[^\n]*', ' ', 'g'),
             '''[^'']*''', '''''', 'g') AS src
      FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.prokind = 'f'
       AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
       AND p.prosrc ~ '\mperfiles\M'
  ), alias AS (
    SELECT f.firma, array_agg(DISTINCT lower(m[1])) AS nombres
      FROM f, regexp_matches(f.src,
             '(\w+)\s*(?:uuid\s*)?(?::=|\mDEFAULT\M)\s*\(?\s*(?:SELECT\s+)?auth\.uid\s*\(\s*\)', 'gi') AS m
     GROUP BY f.firma
  ), sentencias AS (
    SELECT f.firma, f.definer, s.texto, a.nombres
      FROM f
      LEFT JOIN alias a USING (firma)
      CROSS JOIN LATERAL regexp_split_to_table(f.src, ';') AS s(texto)
  ), lecturas AS (
    SELECT DISTINCT firma, definer, left(regexp_replace(btrim(texto), '\s+', ' ', 'g'), 200) AS lectura
      FROM sentencias
     WHERE texto ~ '\mperfiles\M'
       AND texto ~* '\mrol\M'
       AND texto !~* '\mactivo\M'
       AND (texto ~ 'auth\.uid\s*\(\s*\)'
            OR EXISTS (SELECT 1 FROM unnest(nombres) AS n WHERE texto ~* ('\m' || n || '\M')))
  )
  SELECT jsonb_build_object(
    'generado_at', now(),
    'funciones', (SELECT count(*) FROM f),
    'lecturas', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('firma', firma, 'definer', definer, 'lectura', lectura)
                       ORDER BY firma, lectura)
        FROM lecturas), '[]'::jsonb)
  );
$function$;

COMMENT ON FUNCTION public.auditoria_rol_sin_activo() IS
  'Gate de #1490 (scripts/check-rol-sin-activo.mjs): sentencias de funciones ejecutables por '
  'authenticated que leen perfiles.rol de auth.uid() sin mirar activo. Sólo de servidor.';

-- Sólo la corre el gate, con la service_role: las tres mitades.
REVOKE EXECUTE ON FUNCTION public.auditoria_rol_sin_activo() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auditoria_rol_sin_activo() TO service_role;

-- Ninguna de las 22 sigue leyendo el rol sin activo.
DO $verifica$
DECLARE
  v_quedan text;
BEGIN
  SELECT string_agg(DISTINCT e->>'firma', ', ') INTO v_quedan
    FROM jsonb_array_elements(public.auditoria_rol_sin_activo()->'lecturas') AS e
   WHERE e->>'firma' IN (
     'auditoria_integridad()', 'auditoria_sucursal_cruzada()',
     'guardar_analisis_mensual(bigint,date,text,jsonb)', 'guardar_meta_gerencial(bigint,date,text,numeric)',
     'migraciones_aplicadas()', 'posicion_fiscal(bigint,date,date)',
     'reporte_gerencial(bigint,date,date,boolean,boolean)', 'reporte_alerta_detalle(bigint,text,date,date,boolean)',
     'bot_admin_audit_log(date,date,text,uuid,integer)', 'bot_admin_audit_summary(date,date)',
     'bot_admin_digests_enviados(date,date)', 'bot_admin_listar_vinculados()',
     'bot_admin_toggle_usuario(bigint,boolean)', 'reporte_bonificaciones(date,date,bigint,integer)',
     'reporte_cuentas_por_cobrar(bigint)', 'reporte_mermas(date,date,bigint,text,integer,integer,text)',
     'reporte_rechazos(date,date,bigint)', 'reporte_rentabilidad(date,date,bigint,text)',
     'reporte_valuacion_inventario(bigint)', 'reporte_ventas_por_cliente(date,date,uuid,bigint)',
     'reporte_ventas_por_preventista(date,date,bigint)',
     'asegurar_cargo_concepto(text,integer,text,boolean,boolean,text,bigint)');
  IF v_quedan IS NOT NULL THEN
    RAISE EXCEPTION 'siguen leyendo el rol sin activo: %', v_quedan;
  END IF;
  IF has_function_privilege('anon', 'public.auditoria_rol_sin_activo()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.auditoria_rol_sin_activo()', 'EXECUTE') THEN
    RAISE EXCEPTION 'auditoria_rol_sin_activo() quedó ejecutable desde la API';
  END IF;
END
$verifica$;

COMMIT;
