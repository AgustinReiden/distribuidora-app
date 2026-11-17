-- =========================================================================
-- NNN · PERMISOS: QUIÉN VE QUÉ, LAS FUNCIONES QUE NADIE LLAMA Y EL GATE DE
--       LOCKS QUE SE PERDÍA DETRÁS DE UN LITERAL CON `--`
--       (plan #1603, ola 2, tarjeta B9: 1558-b3, 1561-b6, SEG-3, SEG-4,
--        SEG-5, SEG-6 de #1545, 1564-b1, b4, b5, b6, b10, b11, b12,
--        1601-b5 (el historial de stock) y 1541-1; y la revisión adversarial
--        de la tarjeta, H4 a H9)
--
-- Policies, grants y funciones de permisos. Parcha por ancla, con premisa de
-- md5 sobre el cuerpo vivo (ledger en la 514), ocho auditoria_*,
-- cambiar_sucursal, generar_codigo_vinculacion_bot y
-- obtener_resumen_cuenta_cliente; auditoria_definer_sin_rol, por ancla con
-- premisa de forma (B4 y B5 le parchan líneas). Crea dos helpers de texto, dos
-- helpers de policy, un trigger y una RPC; borra trece funciones (catorce con
-- _tablero_cat_nombre si queda huérfana) y una vista que nadie usa.
-- Ensayo: scripts/test-permisos-ola2-1603.sql. Se aplica en LF, y no depende
-- del orden contra B3, B4, B5 y B8a.
--
-- No va acá (decisión de coordinación, después de la revisión):
--   · 1564-b7 (las facturas por la sucursal activa): no se hace. La sucursal
--     activa la elige el propio usuario con un header, así que no acota nada,
--     y haría depender la subida de que Storage reenvíe ese header a Postgres.
--     Las policies de la 463 (las sucursales del usuario) quedan.
--   · El REVOKE de las columnas reservadas de politicas_comerciales (la parte
--     2 de 1564-b6): va días después del deploy del front, fuera de esta
--     migración, para no dejar sin política a un bundle viejo del PWA.
--
-- Bloques que se pueden sacar sin tocar el resto:
--   · 9b · las `tablero_*` y obtener_resumen_compras que parchó B8b (514);
--   · 9c · desasignar_usuario_sucursal, que parchó B6b (513).
--
-- =========================================================================
-- 1 · 1541-1 · EL TEXTO DE UN CUERPO SE LIMPIA DE IZQUIERDA A DERECHA
-- =========================================================================
-- auditoria_locks() (y otras ocho auditoria_* que leen código) sacaban primero
-- los comentarios `--` y recién después los literales. Un literal con `--`
-- adentro (`' -- '`, el motivo de la merma de cancelar_pedido_con_stock)
-- perdía su comilla de cierre, la paridad quedaba al revés y tres locks de esa
-- función (el de la 447 sobre los pagos de la boleta entre ellos) no le
-- llegaban a check-locks. Dos helpers puros hacen una sola pasada: lo que
-- empieza en una comilla es un literal (con sus `''`) aunque tenga `--` o
-- `/*` adentro, y lo que empieza en `--` o `/*` fuera de un literal es un
-- comentario:
--   · _sql_sin_comentarios(text): saca los comentarios, deja los literales;
--   · _sql_sin_comentarios_ni_literales(text): además vacía cada literal.
-- Espejo en JS: sinComentarios / sinComentariosNiLiterales de
-- scripts/lib/locks.mjs, con sus casos en src/test/locks.test.ts.
-- Las nueve pasan a usarlos: auditoria_locks, auditoria_rol_sin_activo,
-- auditoria_pedidos_cliente_activo, auditoria_funciones_modo_regalo_vivo y
-- auditoria_reportes_join_interno (que vaciaban literales, el mismo punto
-- ciego), y auditoria_definer_sin_rol, auditoria_rpcs_definer,
-- auditoria_comision_mes_cerrado y auditoria_bot_sin_funcion_canonica (que
-- sólo sacaban comentarios: un `--` en un literal les comía el resto de la
-- línea). Sobre el esquema del 16/11 las salidas no cambian, salvo
-- auditoria_locks, que suma las tres sentencias de cancelar_pedido_con_stock
-- (todas con ORDER BY o por id: check-locks sigue en verde).
--
-- =========================================================================
-- 2 · 1564-b11 · NINGUNA POLICY LEE EL ROL SIN `activo`
-- =========================================================================
-- Quince policies leían perfiles.rol de auth.uid() sin mirar `activo`. Las
-- protegía current_sucursal_id(), que da NULL para un desactivado: protección
-- indirecta. Ahora las de admin y encargado usan es_encargado_o_admin(), y las
-- del depósito (no tiene helper) suman COALESCE(activo, true). Los helpers y
-- current_sucursal_id() van envueltos en (SELECT …): no dependen de la fila y
-- así se resuelven una vez por consulta (initPlan), no una por fila (H5 de la
-- revisión: con 3.000 clientes el count(*) del chofer pasaba de 143 a 1.561 ms).
-- El gate:
-- auditoria_rol_sin_activo() devuelve también `policies` (las que leen el rol
-- del que llama sin `activo`) y scripts/check-rol-sin-activo.mjs falla con
-- cualquiera: no hay lista de permitidas para policies.
--
-- 1558-b3: la rama depósito de mt_productos_update era letra muerta
-- (mt_productos_select no le muestra productos, así que su UPDATE tocaba 0
-- filas). Se saca, y con ella la de mt_stock_historico_insert_ficha, que
-- existía sólo para el trigger de ese UPDATE.
--
-- =========================================================================
-- 3 · 1564-b12 · EL CHOFER VE SÓLO LOS CLIENTES DE SUS PEDIDOS
-- =========================================================================
-- Decisión del dueño (D52, en #1564). mt_clientes_select pasa de una lista
-- negativa («todo el que no es preventista ve todo») a una positiva:
--   · admin y encargado: todos los de la sucursal;
--   · quien actúa como preventista (es_preventista(): el rol o el extra): sin
--     asignar o asignados a él, y no reservados (como antes);
--   · cualquiera: el cliente al que le vendió, como antes;
--   · cualquiera, también el depósito con el extra de chofer: el de un pedido
--     que reparte (sin VB). Antes la exclusión del depósito le ganaba y su ruta
--     salía sin nombre ni dirección (H7 de la revisión, ya pasaba);
--   · el depósito, fuera de lo que reparte, ninguno (como antes).
-- Un rol nuevo (un cajero) no hereda la lectura total.
-- La regla vive en una sola función, _cliente_visible(id, sucursal, reservado)
-- (SQL y SETOF, para que se inlinee en la policy: escalar se llamaba fila por
-- fila), y la usan mt_clientes_select y
-- obtener_resumen_cuenta_cliente, que le daba a cualquier chofer el saldo y el
-- límite de cualquier cliente (H4). verificar_duplicado_cliente queda afuera a
-- propósito: mira todos los clientes de la sucursal para avisar del duplicado
-- (la reescribe B6a). El bot (ficha_cliente) va a la ola 3.
--
-- =========================================================================
-- 4 · 1601-b5 · EL HISTORIAL DE STOCK, SÓLO ADMIN, ENCARGADO Y DEPÓSITO
-- =========================================================================
-- Decisión del dueño (D53, en #1601). mt_stock_historico_select pedía sólo la
-- sucursal. La otra mitad de D53 (los emails de los demás usuarios) no va acá:
-- ver el informe de la tarjeta.
--
-- =========================================================================
-- 5 · 1564-b4 · LOS ENCUADRES DE IMPUESTOS INTERNOS, SÓLO UN ADMIN DE TODAS
-- =========================================================================
-- Decisión del dueño (D49, en #1564). ii_encuadres es global: lo editaba
-- cualquier admin, también con el header de una sucursal ajena.
--
-- 1561-b6 · Decisión del dueño (D34, en #1561): sólo el admin crea o marca
-- (o desmarca) un cliente comodín. La policy del alta y un trigger para el
-- cambio, como reservado_admin y el vale blanco.
--
-- =========================================================================
-- 6 · 1564-b6 · LA POLÍTICA COMERCIAL RESERVADA, POR RPC (PARTE 1)
-- =========================================================================
-- Decisión del dueño (D50, en #1564): el preventista y el chofer ven de la
-- política comercial sólo lo que necesitan para vender; la comisión y el
-- margen mínimo, sólo admin y encargado. RLS no oculta columnas: lo reservado
-- (las comisiones, las alertas de combos y la ventana del precio anterior) lo
-- da politica_comercial_reservada() a admin y encargado de la sucursal activa,
-- y el front nuevo lo lee de ahí. Esta migración NO toca los grants: un bundle
-- viejo del PWA sigue leyendo por REST. El REVOKE de esas columnas (parte 2)
-- se aplica días después del deploy, con su issue.
--
-- =========================================================================
-- 7 · SEG-5 · EL FILTRO DE PERSONAL DE audit_logs NO VA POR PREFIJO
-- =========================================================================
-- mt_audit_logs_select escondía al admin de una sucursal las filas de
-- `empleado%`. Una tabla de personal con otro nombre (rendicion_faltantes
-- tiene empleado_id) quedaba a la vista si se auditaba. Ahora decide
-- _audit_tabla_de_personal(tabla): el prefijo, o una columna empleado_id
-- (salvo `gastos`, que el admin de la sucursal ya ve entero).
-- 1564-b5 · La vista audit_logs_detallado (SELECT para authenticated, ilegible
-- por su JOIN a auth.users, sin lectores) se borra: arreglada, expondría los
-- emails de todas las sucursales.
--
-- =========================================================================
-- 8 · 1564-b1 · UN DESACTIVADO NO CAMBIA DE SUCURSAL NI VINCULA EL BOT
-- =========================================================================
-- cambiar_sucursal y generar_codigo_vinculacion_bot miran `activo`. Las dos
-- están en la lista blanca de auditoria_definer_sin_rol por md5: se actualiza.
--
-- =========================================================================
-- 9 · SEG-3, 1564-b10, SEG-4 · LAS FUNCIONES QUE NADIE LLAMA SE BORRAN
-- =========================================================================
-- Decisión del dueño (D48, en #1545 y #1564): se borran, no sólo se les saca
-- el acceso, después de comprobar que nada las llama. Comprobado el 16/11 en
-- src/, supabase/functions/, scripts/, los workflows y los cuerpos de public:
--   · sin ningún llamador, se borran: tablero_buscar_clientes,
--     tablero_clientes_inactivos, tablero_contexto, tablero_ficha_cliente,
--     tablero_guardar_meta_cobertura, tablero_kpis, tablero_productos_categoria,
--     guardar_horarios_clientes_masivo, obtener_resumen_compras,
--     obtener_sucursales_usuario, desasignar_usuario_sucursal,
--     get_audit_history y get_suspicious_activity (SEG-4: sin EXECUTE para
--     authenticated desde #1438; borrarlas cierra también su parte de SEG-6).
--     desasignar_usuario_sucursal la arregló la 513 (1561-b3) y tampoco tiene
--     llamador en el main del 17/11 ni en las ramas de la ola: se borra igual;
--   · _tablero_cat_nombre, que desde la 514 sólo la llama
--     tablero_productos_categoria: si después de borrar ésa nadie la nombra, se
--     borra; si no, se deja;
--   · con llamador sólo de server, quedan y pierden el EXECUTE de
--     authenticated: tablero_categorias, tablero_facturacion_mensual,
--     tablero_top_clientes_zona y tablero_cobertura (los cruces de
--     scripts/check-integridad.mjs, con service_role; reporte_gerencial, que
--     es DEFINER, llama a tablero_facturacion_mensual) y
--     guardar_analisis_mensual (.claude/commands/reporte-mensual.md, por el
--     MCP de Supabase).
-- Antes de borrar, la migración vuelve a buscar en los cuerpos de public un
-- llamador de cada una, y aborta si aparece.
--
-- =========================================================================
-- 10 · SEG-6 · CUERPOS EN LF
-- =========================================================================
-- _empleado_visible se recrea con LF, sin cambiar una coma: la poscondición
-- compara el md5 con el del cuerpo vivo pasado a LF. auditoria_comision_mes_
-- cerrado queda en LF por el parche del bloque 1. _guardar_gasto no se toca:
-- B8a la recrea.
--
-- Revertir: volver los cuerpos y las policies a los de la premisa, recrear las
-- funciones borradas desde el volcado del 16/11 y borrar los objetos nuevos.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- SEG-3, 1564-b10, SEG-4 (bloque 9): ningún cuerpo de public llama a una de las funciones que se
-- borran (salvo otra que también se borra); se vuelve a mirar acá, por si algo cambió desde el
-- 16/11. Va antes de los locks: lee sólo el catálogo, y es la parte más lenta (medio segundo).
DO $p9$
DECLARE
  c_borrar CONSTANT text[] := ARRAY[
    'tablero_buscar_clientes', 'tablero_clientes_inactivos', 'tablero_contexto', 'tablero_ficha_cliente',
    'tablero_guardar_meta_cobertura', 'tablero_kpis', 'tablero_productos_categoria',
    'guardar_horarios_clientes_masivo', 'obtener_resumen_compras', 'obtener_sucursales_usuario',
    'desasignar_usuario_sucursal', 'get_audit_history', 'get_suspicious_activity'];
  v_re text := '\m(' || array_to_string(c_borrar, '|') || ')\M';
  r record;
BEGIN
  -- Una sola pasada por cuerpo.
  FOR r IN
    SELECT p.oid::regprocedure::text AS quien, substring(p.prosrc FROM v_re) AS llama
      FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND NOT (p.proname = ANY (c_borrar))
       AND p.prosrc ~ v_re
  LOOP
    RAISE EXCEPTION 'mig NNN · % llama a %: no se puede borrar', r.quien, r.llama;
  END LOOP;
  IF EXISTS (SELECT 1 FROM pg_views WHERE schemaname = 'public'
              AND definition ~ ('\m(' || array_to_string(c_borrar, '|') || ')\M')) THEN
    RAISE EXCEPTION 'mig NNN · una vista nombra una de las funciones que se borran';
  END IF;
END
$p9$;

-- Todas las tablas cuyas policies, triggers o vistas cambian, de una vez y sin esperar: cada
-- ALTER POLICY, el CREATE TRIGGER y el DROP VIEW toman ACCESS EXCLUSIVE hasta el COMMIT, y
-- tomados de a uno, en otro orden que el de la venta o la compra, dan 40P01 a la app. Si alguna
-- está ocupada, la migración falla al instante (55P03) y se reintenta.
LOCK TABLE public.clientes, public.productos, public.politicas_comerciales, public.stock_historico,
           public.grupo_precio_escala_minimos, public.grupo_precio_escalas, public.metas_preventista,
           public.pedido_item_lotes, public.producto_lotes, public.proveedores,
           public.producto_equivalencias_proveedor, public.perfil_roles, public.usuario_sucursales,
           public.visitas_cliente, public.ii_encuadres, public.audit_logs, public.audit_logs_detallado
  IN ACCESS EXCLUSIVE MODE NOWAIT;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos y las policies vivos (ledger en la 514). Ninguna de estas funciones la
-- tocan B3, B4, B5 ni B8a. auditoria_definer_sin_rol no lleva md5 (B4 y B5 le parchan líneas):
-- su premisa es la forma, cada ancla tiene que aparecer una vez (pg_temp.parche).
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.auditoria_locks()',                     'e8f5a6b7a134bae28fb40c3a10e21edf'),
    ('public.auditoria_rol_sin_activo()',            '83f8d7f4c485cdd5e4631db4b496493f'),
    ('public.auditoria_pedidos_cliente_activo()',    '5e5969c2660eb2775d54ae6adef9279c'),
    ('public.auditoria_funciones_modo_regalo_vivo()', 'd3ff72dbbd49fdcd112b3a7d015193fe'),
    ('public.auditoria_reportes_join_interno()',     '0bbe945ce0a9f42f094b53e3cb223cfd'),
    ('public.auditoria_rpcs_definer()',              'f0d47494b6632bc5eeca699a88c55880'),
    ('public.auditoria_comision_mes_cerrado()',      'da8022e9f4dfb9b5b1d78c42ca241ab2'),
    ('public.auditoria_bot_sin_funcion_canonica()',  '2295b95fe0ce8204711cc9f8dfee3784'),
    ('public.cambiar_sucursal(bigint)',              '86322b98dc0aaef539dabe10e74bbc16'),
    ('public.generar_codigo_vinculacion_bot()',      '6eebcfbefd5390e044ffbca6e40e62fe'),
    ('public._empleado_visible(bigint,boolean)',     'd4c607e38c98b915e8b1259233370f00'),
    ('public.obtener_resumen_cuenta_cliente(integer)', '8e60a772daa3594038b18e6a22fd294b'),
    -- No cambian, pero las policies nuevas cuentan con ellas como están.
    ('public.es_encargado_o_admin()',                '8dad5014078f931eaad76911c2c171df'),
    ('public.es_preventista()',                      '25bca9777219c7915c0234bb60d4adb1'),
    ('public.es_admin()',                            '975886be1dc20e67edba71686ef50959'),
    ('public.es_admin_de_todas_las_sucursales()',    'ee682b69792f91a86d61bfef244936dc'),
    ('public.current_sucursal_id()',                 '54d71f56a5d86f814a17f00b620d4eff')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;

  -- Las policies que se reescriben, por su huella (md5 de using|check).
  FOR r IN SELECT * FROM (VALUES
      ('audit_logs', 'mt_audit_logs_select', 'd73b80b87986f31478df1b85d3ffed2b'),
      ('clientes', 'mt_clientes_insert', '9a48ba61444ada31dee1049d41c8b6f1'),
      ('clientes', 'mt_clientes_select', '9c2624c99a52010b8f13fce6900ee2a2'),
      ('grupo_precio_escala_minimos', 'mt_gpem_select', 'e346d3d48849e45abd0665695c68a85f'),
      ('grupo_precio_escalas', 'mt_grupo_precio_escalas_select', 'e346d3d48849e45abd0665695c68a85f'),
      ('ii_encuadres', 'ii_encuadres_insert', '0bcae601192312c63aba2ebc31827615'),
      ('ii_encuadres', 'ii_encuadres_update', '77e233987c85e988e18df94f4683306d'),
      ('metas_preventista', 'metas_preventista_admin_select', 'faf79f16c9cbecd5fea8b580341dcc14'),
      ('pedido_item_lotes', 'mt_pedido_item_lotes_select', 'abda489223fa9b440e3e822aec11ba63'),
      ('perfil_roles', 'perfil_roles_select_sucursal_activa', 'dd1a64f282d8a655e7f5a2d44f8ff6fa'),
      ('politicas_comerciales', 'mt_politicas_comerciales_select', 'e346d3d48849e45abd0665695c68a85f'),
      ('producto_equivalencias_proveedor', 'producto_equivalencias_select', 'f0bb3f8695526cffcc9f604fef517fa0'),
      ('producto_lotes', 'mt_producto_lotes_select', 'abda489223fa9b440e3e822aec11ba63'),
      ('productos', 'mt_productos_select', 'e346d3d48849e45abd0665695c68a85f'),
      ('productos', 'mt_productos_update', 'fbc5f530bb63fe60ef2173604f4bce59'),
      ('proveedores', 'mt_proveedores_select', 'abda489223fa9b440e3e822aec11ba63'),
      ('stock_historico', 'mt_stock_historico_insert_ficha', '920f674801d74f06b4316120854ba586'),
      ('stock_historico', 'mt_stock_historico_select', '74f94909bdfef2de782404dd83e292ba'),
      ('usuario_sucursales', 'usuario_sucursales_select_sucursal_activa', 'dd1a64f282d8a655e7f5a2d44f8ff6fa'),
      ('visitas_cliente', 'visitas_cliente_select', '87ef0cde5efb2793b14d26b806cc611c')
    ) AS t(tabla, policy, huella) LOOP
    SELECT md5(coalesce(qual, '') || '|' || coalesce(with_check, '')) INTO v
      FROM pg_policies WHERE schemaname = 'public' AND tablename = r.tabla AND policyname = r.policy;
    IF v IS DISTINCT FROM r.huella THEN
      RAISE EXCEPTION 'mig NNN · la policy % / % cambió (huella %): rehacer sobre la vigente', r.tabla, r.policy, v;
    END IF;
  END LOOP;

  IF to_regproc('public._sql_sin_comentarios') IS NOT NULL
     OR to_regproc('public._sql_sin_comentarios_ni_literales') IS NOT NULL
     OR to_regproc('public._audit_tabla_de_personal') IS NOT NULL
     OR to_regproc('public._cliente_visible') IS NOT NULL
     OR to_regproc('public.clientes_comodin_solo_admin') IS NOT NULL
     OR to_regproc('public.politica_comercial_reservada') IS NOT NULL
     OR EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.clientes'::regclass
                 AND tgname = 'trg_clientes_comodin_solo_admin') THEN
    RAISE EXCEPTION 'mig NNN · una función o el trigger nuevos ya existen: revisar a mano';
  END IF;
END
$premisas$;

-- La definición de una función, en LF (algunos cuerpos vivos están en CRLF, SEG-6).
CREATE FUNCTION pg_temp.def(p_firma text)
RETURNS text LANGUAGE sql AS $f$
  SELECT replace(pg_get_functiondef(p_firma::regprocedure), E'\r\n', E'\n');
$f$;

-- Reemplaza una sola aparición de un ancla en una definición.
CREATE FUNCTION pg_temp.parche(p_def text, p_ancla text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v_n int := (length(p_def) - length(replace(p_def, p_ancla, ''))) / length(p_ancla);
BEGIN
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · %: el ancla aparece % vez/veces y se esperaba 1', p_que, v_n;
  END IF;
  RETURN replace(p_def, p_ancla, p_nuevo);
END
$f$;

-- =========================================================================
-- 1 · 1541-1 · Los helpers de texto y las nueve auditoria_*
-- =========================================================================

-- El cuerpo sin comentarios; los literales quedan como están. Una sola pasada
-- de izquierda a derecha (#1541). Espejo: sinComentarios (scripts/lib/locks.mjs).
-- No entiende un dólar-quote anidado ($q$…$q$) ni un E'…\'…'.
CREATE FUNCTION public._sql_sin_comentarios(p_src text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public'
AS $function$
  SELECT regexp_replace(p_src, '(''(?:[^'']|'''')*'')|--[^\n]*|/\*(?:[^*]|\*+[^*/])*\*+/', '\1', 'g');
$function$;

-- El cuerpo sin comentarios y con cada literal vacío (''). Espejo:
-- sinComentariosNiLiterales (scripts/lib/locks.mjs).
CREATE FUNCTION public._sql_sin_comentarios_ni_literales(p_src text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public'
AS $function$
  SELECT regexp_replace(public._sql_sin_comentarios(p_src), '''(?:[^'']|'''')*''', '''''', 'g');
$function$;

REVOKE EXECUTE ON FUNCTION public._sql_sin_comentarios(text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._sql_sin_comentarios_ni_literales(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._sql_sin_comentarios(text) TO service_role;
GRANT EXECUTE ON FUNCTION public._sql_sin_comentarios_ni_literales(text) TO service_role;

DO $p1$
DECLARE
  v text;
  c_tres_pasos CONSTANT text := $a$regexp_replace(regexp_replace(regexp_replace(p.prosrc,
             '/\*.*?\*/', ' ', 'g'),
             '--[^\n]*', ' ', 'g'),
             '''[^'']*''', '''''', 'g') AS src$a$;
BEGIN
  -- auditoria_locks y auditoria_pedidos_cliente_activo: el mismo texto.
  v := pg_temp.parche(pg_temp.def('public.auditoria_locks()'), c_tres_pasos,
         'public._sql_sin_comentarios_ni_literales(p.prosrc) AS src', 'auditoria_locks');
  EXECUTE v;
  v := pg_temp.parche(pg_temp.def('public.auditoria_pedidos_cliente_activo()'), c_tres_pasos,
         'public._sql_sin_comentarios_ni_literales(p.prosrc) AS src', 'auditoria_pedidos_cliente_activo');
  EXECUTE v;

  v := pg_temp.parche(pg_temp.def('public.auditoria_funciones_modo_regalo_vivo()'),
$a$SELECT regexp_replace(
               regexp_replace(regexp_replace(f.prosrc, '/\*.*?\*/', ' ', 'g'), '--[^\n]*', '', 'g'),
               '''[^'']*''', '', 'g') AS src$a$,
$b$SELECT public._sql_sin_comentarios_ni_literales(f.prosrc) AS src$b$,
         'auditoria_funciones_modo_regalo_vivo');
  EXECUTE v;

  v := pg_temp.parche(pg_temp.def('public.auditoria_reportes_join_interno()'),
$a$regexp_replace(
                 regexp_replace(regexp_replace(f.prosrc, '/\*.*?\*/', ' ', 'g'), '--[^\n]*', '', 'g'),
                 '''[^'']*''', '', 'g'),$a$,
$b$public._sql_sin_comentarios_ni_literales(f.prosrc),$b$,
         'auditoria_reportes_join_interno');
  EXECUTE v;

  v := pg_temp.parche(pg_temp.def('public.auditoria_rpcs_definer()'),
$a$regexp_replace(regexp_replace(
             p.prosrc, '/\*.*?\*/', ' ', 'g'), '--[^\n]*', ' ', 'g')$a$,
$b$public._sql_sin_comentarios(p.prosrc)$b$,
         'auditoria_rpcs_definer');
  EXECUTE v;

  v := pg_temp.parche(pg_temp.def('public.auditoria_comision_mes_cerrado()'),
$a$AND regexp_replace(f.prosrc, '--[^\n]*', '', 'g')$a$,
$b$AND public._sql_sin_comentarios(f.prosrc)$b$,
         'auditoria_comision_mes_cerrado');
  EXECUTE v;

  v := pg_temp.parche(pg_temp.def('public.auditoria_bot_sin_funcion_canonica()'),
$a$OR regexp_replace(pg_get_functiondef(to_regprocedure(m.funcion)), '--[^\n]*', '', 'g')$a$,
$b$OR public._sql_sin_comentarios(pg_get_functiondef(to_regprocedure(m.funcion)))$b$,
         'auditoria_bot_sin_funcion_canonica');
  EXECUTE v;

  -- auditoria_definer_sin_rol: la limpieza y su «lo que no ve».
  v := pg_temp.def('public.auditoria_definer_sin_rol()');
  v := pg_temp.parche(v,
$a$regexp_replace(regexp_replace(p.prosrc, '/\*.*?\*/', ' ', 'g'), '--[^\n]*', ' ', 'g') AS src,$a$,
$b$public._sql_sin_comentarios(p.prosrc) AS src,$b$,
         'auditoria_definer_sin_rol · limpieza');
  v := pg_temp.parche(v,
$a$  --   · Un `--` o un `/*` adentro de un literal: el corte de comentarios no
  --     entiende strings (hoy el único caso, `' -- '` en
  --     cancelar_pedido_con_stock, no esconde ningún guard).$a$,
$b$  --   · Un `--` o un `/*` adentro de un dólar-quote anidado ($q$…$q$) o de un
  --     E'…\'…': _sql_sin_comentarios entiende las comillas simples (#1541),
  --     no esos.$b$,
         'auditoria_definer_sin_rol · lo que no ve');
  EXECUTE v;
END
$p1$;

-- =========================================================================
-- 2 · 1564-b11 · El gate de las policies que leen el rol sin activo
-- =========================================================================
-- auditoria_rol_sin_activo: la limpieza de 1541-1 y una lista nueva,
-- `policies`: las de cualquier esquema con un SELECT sobre perfiles que lee el
-- rol de auth.uid() sin nombrar activo. Es texto, por subconsulta (se corta en
-- cada SELECT del USING y del WITH CHECK).
DO $p2$
DECLARE
  v text;
BEGIN
  v := pg_temp.def('public.auditoria_rol_sin_activo()');
  v := pg_temp.parche(v,
$a$regexp_replace(regexp_replace(regexp_replace(p.prosrc,
             '/\*.*?\*/', ' ', 'g'),
             '--[^\n]*', ' ', 'g'),
             '''[^'']*''', '''''', 'g') AS src$a$,
$b$public._sql_sin_comentarios_ni_literales(p.prosrc) AS src$b$,
         'auditoria_rol_sin_activo · limpieza');
  v := pg_temp.parche(v,
$a$    'funciones', (SELECT count(*) FROM f),
$a$,
$b$    'funciones', (SELECT count(*) FROM f),
    -- 1564-b11 (plan #1603): las policies que leen el rol del que llama sin
    -- activo. No tienen lista de permitidas: usan los helpers o miran activo.
    'policies', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('policy', x.nombre, 'lectura', x.lectura) ORDER BY x.nombre, x.lectura)
        FROM (SELECT DISTINCT pp.schemaname || '.' || pp.tablename || ' / ' || pp.policyname AS nombre,
                     left(regexp_replace(btrim(s.seg), '\s+', ' ', 'g'), 200) AS lectura
                FROM pg_policies pp
               CROSS JOIN LATERAL regexp_split_to_table(
                       coalesce(pp.qual, '') || ' ' || coalesce(pp.with_check, ''), '\mSELECT\M', 'i') AS s(seg)
               WHERE s.seg ~* '\mFROM\s+(public\.)?perfiles\M'
                 AND s.seg ~* '\mrol\M'
                 AND s.seg !~* '\mactivo\M'
                 AND s.seg ~ 'auth\.uid\s*\(\s*\)') x), '[]'::jsonb),
$b$,
         'auditoria_rol_sin_activo · policies');
  EXECUTE v;
END
$p2$;

-- Las quince policies. Admin y encargado: es_encargado_o_admin(). Depósito: el
-- rol con COALESCE(activo, true) (no tiene helper; trampa 4: es_preventista()
-- no sirve para preguntar por un rol). Los helpers y current_sucursal_id(), en
-- (SELECT …): no dependen de la fila y se resuelven una vez (H5).
ALTER POLICY mt_gpem_select ON public.grupo_precio_escala_minimos
  USING ((sucursal_id = (SELECT current_sucursal_id()))
         AND NOT (EXISTS (SELECT 1 FROM perfiles pd
                           WHERE pd.id = auth.uid() AND pd.rol = 'deposito'::text AND COALESCE(pd.activo, true))));

ALTER POLICY mt_grupo_precio_escalas_select ON public.grupo_precio_escalas
  USING ((sucursal_id = (SELECT current_sucursal_id()))
         AND NOT (EXISTS (SELECT 1 FROM perfiles pd
                           WHERE pd.id = auth.uid() AND pd.rol = 'deposito'::text AND COALESCE(pd.activo, true))));

ALTER POLICY mt_politicas_comerciales_select ON public.politicas_comerciales
  USING ((sucursal_id = (SELECT current_sucursal_id()))
         AND NOT (EXISTS (SELECT 1 FROM perfiles pd
                           WHERE pd.id = auth.uid() AND pd.rol = 'deposito'::text AND COALESCE(pd.activo, true))));

ALTER POLICY mt_productos_select ON public.productos
  USING ((sucursal_id = (SELECT current_sucursal_id()))
         AND NOT (EXISTS (SELECT 1 FROM perfiles pd
                           WHERE pd.id = auth.uid() AND pd.rol = 'deposito'::text AND COALESCE(pd.activo, true))));

-- 1558-b3: sin la rama depósito (letra muerta).
ALTER POLICY mt_productos_update ON public.productos
  USING ((SELECT es_admin()) AND (sucursal_id = (SELECT current_sucursal_id())))
  WITH CHECK ((SELECT es_admin()) AND (sucursal_id = (SELECT current_sucursal_id())));

ALTER POLICY mt_stock_historico_insert_ficha ON public.stock_historico
  WITH CHECK ((pg_trigger_depth() = 1) AND (origen = 'ajuste_manual'::text) AND (usuario_id = auth.uid())
              AND (referencia_tipo IS NULL) AND (referencia_id IS NULL)
              AND (sucursal_id = (SELECT current_sucursal_id())) AND (SELECT es_admin()));

ALTER POLICY metas_preventista_admin_select ON public.metas_preventista
  USING ((SELECT es_encargado_o_admin())
         AND (sucursal_id IN (SELECT us.sucursal_id FROM usuario_sucursales us WHERE us.usuario_id = auth.uid())));

ALTER POLICY mt_pedido_item_lotes_select ON public.pedido_item_lotes
  USING (((SELECT es_encargado_o_admin())
          OR EXISTS (SELECT 1 FROM perfiles pd
                      WHERE pd.id = auth.uid() AND pd.rol = 'deposito'::text AND COALESCE(pd.activo, true)))
         AND (sucursal_id = (SELECT current_sucursal_id())));

ALTER POLICY mt_producto_lotes_select ON public.producto_lotes
  USING (((SELECT es_encargado_o_admin())
          OR EXISTS (SELECT 1 FROM perfiles pd
                      WHERE pd.id = auth.uid() AND pd.rol = 'deposito'::text AND COALESCE(pd.activo, true)))
         AND (sucursal_id = (SELECT current_sucursal_id())));

ALTER POLICY mt_proveedores_select ON public.proveedores
  USING (((SELECT es_encargado_o_admin())
          OR EXISTS (SELECT 1 FROM perfiles pd
                      WHERE pd.id = auth.uid() AND pd.rol = 'deposito'::text AND COALESCE(pd.activo, true)))
         AND (sucursal_id = (SELECT current_sucursal_id())));

ALTER POLICY producto_equivalencias_select ON public.producto_equivalencias_proveedor
  USING (((SELECT es_encargado_o_admin())
          OR EXISTS (SELECT 1 FROM perfiles pd
                      WHERE pd.id = auth.uid() AND pd.rol = 'deposito'::text AND COALESCE(pd.activo, true)))
         AND (sucursal_id = (SELECT current_sucursal_id())));

ALTER POLICY perfil_roles_select_sucursal_activa ON public.perfil_roles
  USING ((sucursal_id = (SELECT current_sucursal_id())) AND (SELECT es_encargado_o_admin()));

ALTER POLICY usuario_sucursales_select_sucursal_activa ON public.usuario_sucursales
  USING ((sucursal_id = (SELECT current_sucursal_id())) AND (SELECT es_encargado_o_admin()));

ALTER POLICY visitas_cliente_select ON public.visitas_cliente
  USING ((sucursal_id = (SELECT current_sucursal_id()))
         AND ((preventista_id = (SELECT auth.uid())) OR (SELECT es_encargado_o_admin())));

-- =========================================================================
-- 3 · 1564-b12 · Quién ve un cliente: una sola regla
-- =========================================================================
-- La usan mt_clientes_select y obtener_resumen_cuenta_cliente, siempre como
-- EXISTS (SELECT 1 FROM _cliente_visible(...)): devuelve una fila si el cliente
-- se ve y ninguna si no. Es SETOF a propósito: una función SQL escalar con
-- subconsultas no se inlinea nunca, y en la policy se llamaba fila por fila
-- (3 a 7 veces más lenta que la policy vieja con 3.000 clientes). Como SETOF,
-- SQL, STABLE, sin STRICT, sin SET ni DEFINER, el planner la inlinea en el FROM
-- y los (SELECT …) quedan como initPlan. No le agregues STRICT ni SET: deja de
-- inlinearse y no falla nada.
-- Las ramas que dependen de la fila comparan contra (SELECT auth.uid()) (#1182,
-- #1187). Por RLS las subconsultas de pedidos y cliente_preventistas ven lo
-- mismo que estas condiciones explícitas, así que da igual desde una DEFINER.
CREATE FUNCTION public._cliente_visible(p_cliente_id bigint, p_sucursal_id bigint, p_reservado boolean)
RETURNS SETOF boolean
LANGUAGE sql
STABLE
AS $function$
  SELECT true
   WHERE p_sucursal_id = (SELECT public.current_sucursal_id())
     AND (
           (NOT EXISTS (SELECT 1 FROM public.perfiles pd
                         WHERE pd.id = auth.uid() AND pd.rol = 'deposito' AND COALESCE(pd.activo, true))
            AND ((SELECT public.es_encargado_o_admin())
                 -- Quien actúa como preventista: sin asignar o asignado a él, no reservado.
                 OR ((SELECT public.es_preventista())
                     AND NOT p_reservado
                     AND (NOT EXISTS (SELECT 1 FROM public.cliente_preventistas cp WHERE cp.cliente_id = p_cliente_id)
                          OR EXISTS (SELECT 1 FROM public.cliente_preventistas cp
                                      WHERE cp.cliente_id = p_cliente_id AND cp.preventista_id = (SELECT auth.uid()))))
                 -- Historial (358): le vendió.
                 OR EXISTS (SELECT 1 FROM public.pedidos pe
                             WHERE pe.cliente_id = p_cliente_id AND pe.usuario_id = (SELECT auth.uid()))))
           -- Reparto (#1182): el de un pedido que reparte, sin VB. Vale para todo rol, también el
           -- depósito con el extra de chofer (H7).
           OR EXISTS (SELECT 1 FROM public.pedidos pe
                       WHERE pe.cliente_id = p_cliente_id AND pe.transportista_id = (SELECT auth.uid())
                         AND pe.tipo_factura IS DISTINCT FROM 'VB')
         );
$function$;

-- La policy la evalúa como el usuario: authenticated tiene que ejecutarla (sin EXECUTE el planner
-- no la inlinea). Dice si se ve un cliente de la propia sucursal activa, lo mismo que la policy ya
-- muestra.
REVOKE EXECUTE ON FUNCTION public._cliente_visible(bigint, bigint, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._cliente_visible(bigint, bigint, boolean) TO authenticated, service_role;

ALTER POLICY mt_clientes_select ON public.clientes
  USING (EXISTS (SELECT 1 FROM _cliente_visible(id, sucursal_id, reservado_admin)));

COMMENT ON POLICY mt_clientes_select ON public.clientes IS
'Quién ve un cliente (1564-b12 de #1603, D52): _cliente_visible(id, sucursal, reservado), una lista positiva. Admin y encargado: todos los de la sucursal activa. Quien actúa como preventista (es_preventista(): el rol o el extra): sin asignar o asignados a él, sin reservados. Cualquiera: el que ya le vendió (358) y el de un pedido que reparte sin VB (#1182), también el depósito con el extra de chofer. El depósito, fuera de eso, ninguno. Un rol nuevo no hereda nada. Ver no es operar: lo deciden mt_clientes_update, clientes_proteger_columnas_preventista y los triggers de pedidos. Espejo: obtener_resumen_cuenta_cliente usa la misma función. Quedan afuera a propósito: verificar_duplicado_cliente (mira todos los clientes de la sucursal para avisar de un duplicado; su v_operable decide operar, no ver) y el bot (ficha_cliente, ola 3).';

DO $p3$
DECLARE
  v text;
BEGIN
  v := pg_temp.parche(pg_temp.def('public.obtener_resumen_cuenta_cliente(integer)'),
$a$  -- Mismo predicado que la política mt_clientes_select (migs 298 y #999).
  IF NOT EXISTS (
    SELECT 1 FROM clientes c
    WHERE c.id = p_cliente_id
      AND c.sucursal_id = current_sucursal_id()
      AND (
        NOT EXISTS (SELECT 1 FROM perfiles p WHERE p.id = auth.uid() AND p.rol = 'preventista')
        OR (
          (
            NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id)
            OR EXISTS (SELECT 1 FROM cliente_preventistas cp
                       WHERE cp.cliente_id = c.id AND cp.preventista_id = auth.uid())
          )
          AND NOT c.reservado_admin
        )
        -- Historial (mig 358): ya le vendió, aunque hoy lo atienda otro
        OR EXISTS (SELECT 1 FROM pedidos pe
                   WHERE pe.cliente_id = c.id AND pe.usuario_id = auth.uid())
        -- Reparto (#1182): el cliente de un pedido que reparte, sin VB
        OR EXISTS (SELECT 1 FROM pedidos pe
                   WHERE pe.cliente_id = c.id AND pe.transportista_id = auth.uid()
                     AND pe.tipo_factura IS DISTINCT FROM 'VB')
      )
      AND NOT EXISTS (SELECT 1 FROM perfiles pd WHERE pd.id = auth.uid() AND pd.rol = 'deposito')
  ) THEN$a$,
$b$  -- La misma regla que mt_clientes_select: _cliente_visible (1564-b12 de #1603, H4). Antes le
  -- daba a cualquier chofer el saldo y el límite de cualquier cliente de la sucursal.
  IF NOT EXISTS (
    SELECT 1 FROM clientes c
    CROSS JOIN LATERAL public._cliente_visible(c.id, c.sucursal_id, c.reservado_admin) v
    WHERE c.id = p_cliente_id
  ) THEN$b$,
         'obtener_resumen_cuenta_cliente');
  EXECUTE v;
END
$p3$;

-- =========================================================================
-- 4 · 1601-b5 · El historial de stock
-- =========================================================================
ALTER POLICY mt_stock_historico_select ON public.stock_historico
  USING ((sucursal_id = (SELECT current_sucursal_id()))
         AND ((SELECT es_encargado_o_admin())
              OR EXISTS (SELECT 1 FROM perfiles pd
                          WHERE pd.id = auth.uid() AND pd.rol = 'deposito'::text AND COALESCE(pd.activo, true))));

-- =========================================================================
-- 5 · 1564-b4 · Los encuadres de II, y 1561-b6 · el cliente comodín
-- =========================================================================
ALTER POLICY ii_encuadres_insert ON public.ii_encuadres
  WITH CHECK ((SELECT es_admin_de_todas_las_sucursales()));

ALTER POLICY ii_encuadres_update ON public.ii_encuadres
  USING ((SELECT es_admin_de_todas_las_sucursales()))
  WITH CHECK ((SELECT es_admin_de_todas_las_sucursales()));

ALTER POLICY mt_clientes_insert ON public.clientes
  WITH CHECK ((SELECT es_preventista()) AND (sucursal_id = (SELECT current_sucursal_id()))
              AND ((NOT reservado_admin) OR (SELECT es_admin()))
              AND ((NOT es_comodin) OR (SELECT es_admin())));

-- El cambio de la marca por PATCH (el alta ya la frena la policy). Como
-- clientes_reservado_solo_admin: el server y las RPC DEFINER no pasan por acá.
CREATE FUNCTION public.clientes_comodin_solo_admin()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
BEGIN
  IF current_user <> 'authenticated' THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.es_comodin AND NOT es_admin() THEN
      RAISE EXCEPTION 'Sólo un administrador puede crear un cliente comodín'
        USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.es_comodin IS DISTINCT FROM OLD.es_comodin AND NOT es_admin() THEN
    RAISE EXCEPTION 'Sólo un administrador puede marcar o desmarcar un cliente comodín'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.clientes_comodin_solo_admin() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.clientes_comodin_solo_admin() TO service_role;

CREATE TRIGGER trg_clientes_comodin_solo_admin
  BEFORE INSERT OR UPDATE OF es_comodin ON public.clientes
  FOR EACH ROW EXECUTE FUNCTION public.clientes_comodin_solo_admin();

-- =========================================================================
-- 6 · 1564-b6 · Lo reservado de la política comercial, por RPC (parte 1)
-- =========================================================================
-- Los grants de politicas_comerciales no cambian acá (un bundle viejo del PWA sigue leyendo por
-- REST). El REVOKE de las columnas reservadas es la parte 2, días después del deploy.
-- Lo que no es para vender, a admin y encargado de la sucursal activa. Sin
-- fila para el resto (y para un desactivado: current_sucursal_id() da NULL).
CREATE FUNCTION public.politica_comercial_reservada()
RETURNS TABLE(comision_pct_preventista numeric, comision_pct_otros numeric, combo_margen_minimo_pct numeric,
              combo_descuento_maximo_pct numeric, ventana_precio_anterior_horas integer)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT pc.comision_pct_preventista, pc.comision_pct_otros, pc.combo_margen_minimo_pct,
         pc.combo_descuento_maximo_pct, pc.ventana_precio_anterior_horas
    FROM public.politicas_comerciales pc
   WHERE pc.sucursal_id = public.current_sucursal_id()
     AND public.es_encargado_o_admin();
$function$;

REVOKE EXECUTE ON FUNCTION public.politica_comercial_reservada() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.politica_comercial_reservada() TO authenticated, service_role;

-- =========================================================================
-- 7 · SEG-5 · El filtro de personal de audit_logs, y 1564-b5 · la vista
-- =========================================================================
-- ¿Las filas de auditoría de esta tabla son de personal? El prefijo, o una
-- columna empleado_id. `gastos` no: el admin de la sucursal ya ve el gasto
-- entero (gastos_select). La lee la policy como el usuario.
CREATE FUNCTION public._audit_tabla_de_personal(p_tabla text)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
  SELECT p_tabla LIKE 'empleado%'
      OR (p_tabla <> 'gastos'
          AND EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
                       WHERE a.attrelid = to_regclass('public.' || quote_ident(p_tabla))
                         AND a.attname = 'empleado_id' AND a.attnum > 0 AND NOT a.attisdropped));
$function$;

REVOKE EXECUTE ON FUNCTION public._audit_tabla_de_personal(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._audit_tabla_de_personal(text) TO authenticated, service_role;

ALTER POLICY mt_audit_logs_select ON public.audit_logs
  USING ((SELECT es_admin()) AND (sucursal_id = (SELECT current_sucursal_id()))
         AND ((NOT _audit_tabla_de_personal(tabla)) OR (SELECT es_admin_de_todas_las_sucursales())));

DROP VIEW public.audit_logs_detallado;

-- =========================================================================
-- 8 · 1564-b1 · activo en cambiar_sucursal y en el código del bot
-- =========================================================================
DO $p8$
DECLARE
  v text;
  v_suc text;
  v_bot text;
BEGIN
  v := pg_temp.parche(pg_temp.def('public.cambiar_sucursal(bigint)'),
$a$BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM usuario_sucursales$a$,
$b$BEGIN
  -- Un desactivado no cambia de sucursal aunque su token siga vivo (#1474; 1564-b1 de #1603).
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND COALESCE(activo, true)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Usuario desactivado');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM usuario_sucursales$b$,
         'cambiar_sucursal');
  EXECUTE v;

  v := pg_temp.parche(pg_temp.def('public.generar_codigo_vinculacion_bot()'),
$a$    RAISE EXCEPTION 'No autenticado';
  END IF;
$a$,
$b$    RAISE EXCEPTION 'No autenticado';
  END IF;

  -- Un desactivado no vincula el bot aunque su token siga vivo (#1474; 1564-b1 de #1603).
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND COALESCE(activo, true)) THEN
    RAISE EXCEPTION 'Tu usuario está desactivado.' USING ERRCODE = '42501';
  END IF;
$b$,
         'generar_codigo_vinculacion_bot');
  EXECUTE v;

  -- La lista blanca de auditoria_definer_sin_rol va por md5: los dos cuerpos nuevos.
  SELECT md5(prosrc) INTO v_suc FROM pg_proc WHERE oid = 'public.cambiar_sucursal(bigint)'::regprocedure;
  SELECT md5(prosrc) INTO v_bot FROM pg_proc WHERE oid = 'public.generar_codigo_vinculacion_bot()'::regprocedure;
  v := pg_temp.def('public.auditoria_definer_sin_rol()');
  v := pg_temp.parche(v, $a$('cambiar_sucursal(bigint)',                 '86322b98dc0aaef539dabe10e74bbc16'),$a$,
         format('(%L,                 %L),', 'cambiar_sucursal(bigint)', v_suc),
         'auditoria_definer_sin_rol · cambiar_sucursal');
  v := pg_temp.parche(v, $a$('generar_codigo_vinculacion_bot()',         '6eebcfbefd5390e044ffbca6e40e62fe'),$a$,
         format('(%L,         %L),', 'generar_codigo_vinculacion_bot()', v_bot),
         'auditoria_definer_sin_rol · generar_codigo_vinculacion_bot');
  EXECUTE v;
END
$p8$;


-- =========================================================================
-- 9 · SEG-3, 1564-b10, SEG-4 · Las funciones que nadie llama
-- =========================================================================
-- Que nadie las llama lo comprobó el bloque $p9$, antes de los locks.

-- 9a · Sin ninguna otra tarjeta encima.
DROP FUNCTION public.tablero_buscar_clientes(text, bigint, integer);
DROP FUNCTION public.tablero_clientes_inactivos(bigint, integer, boolean);
DROP FUNCTION public.tablero_contexto();
DROP FUNCTION public.tablero_guardar_meta_cobertura(bigint, date, numeric, integer);
DROP FUNCTION public.guardar_horarios_clientes_masivo(jsonb);
DROP FUNCTION public.obtener_sucursales_usuario();
DROP FUNCTION public.get_audit_history(text, text, integer);
DROP FUNCTION public.get_suspicious_activity(integer);

-- Con llamador sólo de server: quedan, sin EXECUTE para authenticated.
REVOKE EXECUTE ON FUNCTION public.tablero_categorias(bigint, date, date, bigint) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.tablero_facturacion_mensual(bigint, integer) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.tablero_top_clientes_zona(bigint, date, date, integer, integer) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.tablero_cobertura(bigint, date) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.guardar_analisis_mensual(bigint, date, text, jsonb) FROM PUBLIC, anon, authenticated;

-- 9b · Las que B8b parcha por ancla con premisa de md5 (1597-b2 en
-- tablero_ficha_cliente, 1557-b3 en obtener_resumen_compras, y tablero_kpis y
-- tablero_productos_categoria en su barrido de los tablero_*). Acá no se toca su
-- cuerpo: sólo se borran, con IF EXISTS y sin premisa de md5, así da igual el orden
-- (si B8b va después, se saltea las que no existan).
DROP FUNCTION IF EXISTS public.tablero_kpis(bigint, integer);
DROP FUNCTION IF EXISTS public.tablero_productos_categoria(uuid, text, bigint, date, date, bigint);
DROP FUNCTION IF EXISTS public.tablero_ficha_cliente(bigint);
DROP FUNCTION IF EXISTS public.obtener_resumen_compras(date, date);

-- _tablero_cat_nombre: desde la 514 (B8b) la llama sólo tablero_productos_categoria, que se
-- acaba de borrar. Si ya nadie la nombra, queda huérfana y se borra (D48); si alguna otra
-- función la sigue llamando, se deja y se avisa.
DO $p9b$
BEGIN
  IF to_regprocedure('public._tablero_cat_nombre(text)') IS NULL THEN
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p
              WHERE p.pronamespace = 'public'::regnamespace
                AND p.proname <> '_tablero_cat_nombre'
                AND p.prosrc ~ '\m_tablero_cat_nombre\M')
     OR EXISTS (SELECT 1 FROM pg_views WHERE schemaname = 'public' AND definition ~ '\m_tablero_cat_nombre\M') THEN
    RAISE NOTICE 'mig NNN · _tablero_cat_nombre sigue teniendo llamador: se deja';
  ELSE
    DROP FUNCTION public._tablero_cat_nombre(text);
  END IF;
END
$p9b$;

-- 9c · La que arregla B6b (1561-b3).
DROP FUNCTION public.desasignar_usuario_sucursal(uuid, bigint);

-- =========================================================================
-- 10 · SEG-6 · Cuerpos en LF
-- =========================================================================
DO $p10$
BEGIN
  EXECUTE pg_temp.def('public._empleado_visible(bigint,boolean)');
END
$p10$;


-- ---------------------------------------------------------------------------
-- Poscondiciones
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  v_t text;
BEGIN
  -- 1541-1: las nueve usan los helpers y ninguna conserva la limpieza vieja.
  FOR r IN SELECT p.oid::regprocedure::text AS f, p.prosrc
             FROM pg_proc p
            WHERE p.oid::regprocedure::text IN (
                    'auditoria_locks()', 'auditoria_rol_sin_activo()', 'auditoria_pedidos_cliente_activo()',
                    'auditoria_funciones_modo_regalo_vivo()', 'auditoria_reportes_join_interno()',
                    'auditoria_definer_sin_rol()', 'auditoria_rpcs_definer()', 'auditoria_comision_mes_cerrado()',
                    'auditoria_bot_sin_funcion_canonica()') LOOP
    IF position('_sql_sin_comentarios' in r.prosrc) = 0 OR position('''--[^\n]*''' in r.prosrc) > 0
       OR position(E'\r' in r.prosrc) > 0 THEN
      RAISE EXCEPTION 'mig NNN · % no quedó con la limpieza nueva', r.f;
    END IF;
  END LOOP;
  -- Con los locks tomados no se corre ninguna auditoría entera: se mira sólo lo que cambió.
  -- (El ensayo y los gates corren las auditorías enteras.)
  IF position('FOR NO KEY UPDATE' in public._sql_sin_comentarios_ni_literales(
       (SELECT prosrc FROM pg_proc WHERE oid = 'public.cancelar_pedido_con_stock(bigint,text,uuid,text)'::regprocedure))) = 0 THEN
    RAISE EXCEPTION 'mig NNN · la limpieza nueva sigue sin ver el lock de la 447 de cancelar_pedido_con_stock';
  END IF;

  -- 1564-b11: ninguna policy lee el rol del que llama sin activo (el criterio de
  -- auditoria_rol_sin_activo()->'policies', sólo sobre pg_policies).
  IF EXISTS (SELECT 1 FROM pg_policies pp
               CROSS JOIN LATERAL regexp_split_to_table(
                       coalesce(pp.qual, '') || ' ' || coalesce(pp.with_check, ''), '\mSELECT\M', 'i') AS s(seg)
              WHERE s.seg ~* '\mFROM\s+(public\.)?perfiles\M' AND s.seg ~* '\mrol\M'
                AND s.seg !~* '\mactivo\M' AND s.seg ~ 'auth\.uid\s*\(\s*\)') THEN
    RAISE EXCEPTION 'mig NNN · quedan policies que leen el rol sin activo';
  END IF;

  -- 1564-b1: la lista blanca de A tiene los md5 nuevos de las dos.
  IF position((SELECT md5(prosrc) FROM pg_proc WHERE oid = 'public.cambiar_sucursal(bigint)'::regprocedure)
              in (SELECT prosrc FROM pg_proc WHERE oid = 'public.auditoria_definer_sin_rol()'::regprocedure)) = 0
     OR position((SELECT md5(prosrc) FROM pg_proc WHERE oid = 'public.generar_codigo_vinculacion_bot()'::regprocedure)
              in (SELECT prosrc FROM pg_proc WHERE oid = 'public.auditoria_definer_sin_rol()'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'mig NNN · la lista blanca de auditoria_definer_sin_rol no tiene los md5 nuevos';
  END IF;

  -- 1564-b6 (parte 1): la RPC existe y los grants de lectura siguen como estaban (tabla entera).
  IF to_regprocedure('public.politica_comercial_reservada()') IS NULL
     OR NOT has_table_privilege('authenticated', 'public.politicas_comerciales', 'SELECT')
     OR has_table_privilege('anon', 'public.politicas_comerciales', 'SELECT') THEN
    RAISE EXCEPTION 'mig NNN · la política comercial no quedó como se esperaba (RPC y grants de hoy)';
  END IF;

  -- Cada policy reescrita, con lo que tiene que decir.
  FOR r IN SELECT * FROM (VALUES
      ('clientes', 'mt_clientes_select', '_cliente_visible\(', NULL),
      ('clientes', 'mt_clientes_insert', 'es_comodin', NULL),
      ('stock_historico', 'mt_stock_historico_select', 'es_encargado_o_admin', NULL),
      ('stock_historico', 'mt_stock_historico_insert_ficha', 'es_admin', 'deposito'),
      ('productos', 'mt_productos_update', 'es_admin', 'deposito'),
      ('productos', 'mt_productos_select', 'activo', NULL),
      ('ii_encuadres', 'ii_encuadres_insert', 'es_admin_de_todas_las_sucursales', NULL),
      ('ii_encuadres', 'ii_encuadres_update', 'es_admin_de_todas_las_sucursales', NULL),
      ('audit_logs', 'mt_audit_logs_select', '_audit_tabla_de_personal', 'empleado%'),
      ('grupo_precio_escala_minimos', 'mt_gpem_select', 'activo', NULL),
      ('grupo_precio_escalas', 'mt_grupo_precio_escalas_select', 'activo', NULL),
      ('politicas_comerciales', 'mt_politicas_comerciales_select', 'activo', NULL),
      ('metas_preventista', 'metas_preventista_admin_select', 'es_encargado_o_admin', NULL),
      ('pedido_item_lotes', 'mt_pedido_item_lotes_select', 'activo', NULL),
      ('producto_lotes', 'mt_producto_lotes_select', 'activo', NULL),
      ('proveedores', 'mt_proveedores_select', 'activo', NULL),
      ('producto_equivalencias_proveedor', 'producto_equivalencias_select', 'activo', NULL),
      ('perfil_roles', 'perfil_roles_select_sucursal_activa', 'es_encargado_o_admin', NULL),
      ('usuario_sucursales', 'usuario_sucursales_select_sucursal_activa', 'es_encargado_o_admin', NULL),
      ('visitas_cliente', 'visitas_cliente_select', 'es_encargado_o_admin', NULL)
    ) AS t(tabla, policy, dice, no_dice) LOOP
    SELECT coalesce(qual, '') || ' ' || coalesce(with_check, '') INTO v_t
      FROM pg_policies WHERE schemaname = 'public' AND tablename = r.tabla AND policyname = r.policy;
    IF v_t IS NULL OR v_t !~ r.dice OR (r.no_dice IS NOT NULL AND position(r.no_dice in v_t) > 0)
       -- H5: ningún helper de rol ni current_sucursal_id() pelado (fila por fila).
       OR v_t ~ '(?<!SELECT )\m(es_admin|es_encargado_o_admin|es_preventista|es_admin_de_todas_las_sucursales|current_sucursal_id)\(\)' THEN
      RAISE EXCEPTION 'mig NNN · la policy % / % no quedó como se esperaba: %', r.tabla, r.policy, v_t;
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.clientes'::regclass
                  AND tgname = 'trg_clientes_comodin_solo_admin' AND tgenabled = 'O') THEN
    RAISE EXCEPTION 'mig NNN · falta el trigger trg_clientes_comodin_solo_admin';
  END IF;
  IF to_regclass('public.audit_logs_detallado') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · la vista audit_logs_detallado sigue';
  END IF;

  -- H4: obtener_resumen_cuenta_cliente decide con la misma regla que la policy.
  SELECT prosrc INTO v_t FROM pg_proc WHERE oid = 'public.obtener_resumen_cuenta_cliente(integer)'::regprocedure;
  IF position('_cliente_visible(' in v_t) = 0 OR position('p.rol = ''preventista''' in v_t) > 0 THEN
    RAISE EXCEPTION 'mig NNN · obtener_resumen_cuenta_cliente no usa _cliente_visible';
  END IF;
  -- H5: _cliente_visible se puede inlinear (SETOF, SQL, STABLE, sin STRICT, SET ni DEFINER).
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_language l ON l.oid = p.prolang
                  WHERE p.oid = 'public._cliente_visible(bigint,bigint,boolean)'::regprocedure
                    AND l.lanname = 'sql' AND p.proretset AND p.provolatile = 's'
                    AND NOT p.proisstrict AND NOT p.prosecdef AND p.proconfig IS NULL) THEN
    RAISE EXCEPTION 'mig NNN · _cliente_visible no se puede inlinear en la policy';
  END IF;

  -- SEG-3, 1564-b10, SEG-4: las trece no existen; las cinco de server, sin authenticated.
  FOR r IN SELECT * FROM unnest(ARRAY[
      'tablero_buscar_clientes(text,bigint,integer)', 'tablero_clientes_inactivos(bigint,integer,boolean)',
      'tablero_contexto()', 'tablero_ficha_cliente(bigint)', 'tablero_guardar_meta_cobertura(bigint,date,numeric,integer)',
      'tablero_kpis(bigint,integer)', 'tablero_productos_categoria(uuid,text,bigint,date,date,bigint)',
      'guardar_horarios_clientes_masivo(jsonb)', 'obtener_resumen_compras(date,date)', 'obtener_sucursales_usuario()',
      'desasignar_usuario_sucursal(uuid,bigint)', 'get_audit_history(text,text,integer)',
      'get_suspicious_activity(integer)']) AS t(f) LOOP
    IF to_regprocedure('public.' || r.f) IS NOT NULL THEN
      RAISE EXCEPTION 'mig NNN · % sigue existiendo', r.f;
    END IF;
  END LOOP;
  FOR r IN SELECT * FROM unnest(ARRAY[
      'tablero_categorias(bigint,date,date,bigint)', 'tablero_facturacion_mensual(bigint,integer)',
      'tablero_top_clientes_zona(bigint,date,date,integer,integer)', 'tablero_cobertura(bigint,date)',
      'guardar_analisis_mensual(bigint,date,text,jsonb)']) AS t(f) LOOP
    IF has_function_privilege('authenticated', 'public.' || r.f, 'EXECUTE')
       OR NOT has_function_privilege('service_role', 'public.' || r.f, 'EXECUTE') THEN
      RAISE EXCEPTION 'mig NNN · los permisos de % no quedaron como se esperaba', r.f;
    END IF;
  END LOOP;
  IF to_regprocedure('public._tablero_cat_nombre(text)') IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
                       AND p.proname <> '_tablero_cat_nombre' AND p.prosrc ~ '\m_tablero_cat_nombre\M') THEN
    RAISE EXCEPTION 'mig NNN · _tablero_cat_nombre quedó huérfana';
  END IF;

  -- SEG-6.
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = 'public._empleado_visible(bigint,boolean)'::regprocedure)
     IS DISTINCT FROM '9ef67549009db1c1301d8b311f02a256' THEN
    RAISE EXCEPTION 'mig NNN · _empleado_visible no quedó igual en LF';
  END IF;

  -- Nada nuevo para anon, y los helpers de server sin EXECUTE para authenticated.
  FOR r IN SELECT * FROM (VALUES
      ('public._sql_sin_comentarios(text)', false),
      ('public._sql_sin_comentarios_ni_literales(text)', false),
      ('public.clientes_comodin_solo_admin()', false),
      ('public._audit_tabla_de_personal(text)', true),
      ('public._cliente_visible(bigint,bigint,boolean)', true),
      ('public.politica_comercial_reservada()', true)
    ) AS t(f, auth) LOOP
    IF has_function_privilege('anon', r.f, 'EXECUTE')
       OR has_function_privilege('authenticated', r.f, 'EXECUTE') IS DISTINCT FROM r.auth THEN
      RAISE EXCEPTION 'mig NNN · los permisos de % no quedaron como se esperaba', r.f;
    END IF;
  END LOOP;
END
$post$;

COMMIT;
