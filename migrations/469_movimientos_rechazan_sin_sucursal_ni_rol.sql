-- 469 · Los movimientos entre sucursales rechazan al que no es de la sucursal y al desactivado
--       (#1488, tarjeta 11 de #1477).
--
-- QUÉ PASABA
--   aceptar_, denegar_, editar_ y cancelar_movimiento_sucursal (SECURITY DEFINER, EXECUTE para
--   authenticated) cortaban con
--     IF current_sucursal_id() <> v_destino THEN …            (v_origen en editar y cancelar)
--     IF _rol_en_sucursal(auth.uid(), v_destino) NOT IN ('admin', 'encargado') THEN …
--                                                             (<> 'admin' en editar y cancelar)
--   y con NULL ninguna de las dos corta: `NULL <> 2` y `NULL NOT IN (…)` dan NULL, y el IF lo
--   toma como falso.
--   · current_sucursal_id() da NULL si el header x-sucursal-id nombra una sucursal de la que el
--     usuario no es miembro, y desde la 463 también para un perfil desactivado con el token vivo.
--   · _rol_en_sucursal() da NULL para quien no es de esa sucursal (a propósito, 463), y no mira
--     activo: al desactivado le devuelve su rol.
--   Así un preventista de la 1 que manda `x-sucursal-id: 2` aceptaba, denegaba, editaba o
--   cancelaba envíos de otra sucursal y movía stock, y un admin o encargado desactivado seguía
--   haciéndolo hasta que le vencía el token. El encabezado de la 463 decía que los movimientos
--   verificaban la pertenencia antes del rol; la verificaban contra un NULL.
--
-- QUÉ CAMBIA
--   · Las cuatro rechazan primero si current_sucursal_id() es NULL ("Tu usuario no tiene acceso a
--     la sucursal seleccionada"), y comparan la sucursal con IS DISTINCT FROM.
--   · El rol va con COALESCE(…, ''): sin rol en la sucursal no es admin ni encargado.
--   · crear_movimiento_sucursal ya cortaba con `v_origen IS NULL`; su guarda de rol pasa al mismo
--     COALESCE, para que ninguna de las cinco dependa de que el NULL se haya atajado antes.
--   · El gate. check-rpcs-definer.mjs las daba por acotadas porque es textual: ve que el cuerpo
--     nombra current_sucursal_id(). auditoria_rpcs_definer() suma `guardas_nulas`: las RPCs
--     definer alcanzables que comparan current_sucursal_id() (o un alias) con `<>`, `!=` o
--     NOT IN sin chequear antes su `IS NULL`, o _rol_en_sucursal(…) con `<>`, `!=` o NOT IN
--     sin COALESCE. Ninguna tiene excepción: es rojo siempre. Antes de esta migración daba las
--     cinco de movimientos y nada más; después, ninguna.
--
-- QUÉ NO CAMBIA
--   Las firmas, los EXECUTE, el resto de los cuerpos (stock, lotes, costos, notificaciones) y
--   _rol_en_sucursal() / current_sucursal_id(), que tienen otros llamadores (trampa 4). En
--   auditoria_rpcs_definer(), las tres listas que ya devolvía.
--
-- Ensayo: scripts/test-movimientos-sin-sucursal-1488.sql.
-- Aplicar desde el contenido LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: nada cambió en prod desde que se leyeron los cuerpos (06/11)
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, md5(p.prosrc) AS md5_vivo
      FROM (VALUES
        ('public.crear_movimiento_sucursal(bigint,text,jsonb)',   'a463d2a9c6debc35dca8a3e971921491'),
        ('public.aceptar_movimiento_sucursal(bigint,jsonb)',      '0221bbc3dc860f6f9aedc4e1aeac3d92'),
        ('public.denegar_movimiento_sucursal(bigint,text)',       '0006a28cbf554bebbb5ad74b1dc1adcd'),
        ('public.editar_movimiento_sucursal(bigint,text,jsonb)',  '16914ee1b3026d940a8a45428604668a'),
        ('public.cancelar_movimiento_sucursal(bigint,text)',      '260be7499f251b77d5f23d97d98c9efc'),
        ('public.auditoria_rpcs_definer()',                       '38f466a6f15ed94b2e19cc37e4bc370e')
      ) AS x(firma, md5)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION 'mig 469 · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- Parches por ancla sobre el cuerpo vivo
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _n_parche (firma text, orden int, ancla text, reemplazo text, veces int DEFAULT 1) ON COMMIT DROP;

INSERT INTO _n_parche (firma, orden, ancla, reemplazo) VALUES
('public.crear_movimiento_sucursal(bigint,text,jsonb)', 1,
$a$  IF public._rol_en_sucursal(auth.uid(), v_origen) NOT IN ('admin', 'encargado') THEN
$a$,
$r$  -- #1488: sin rol en la sucursal (NULL) no es admin ni encargado.
  IF COALESCE(public._rol_en_sucursal(auth.uid(), v_origen), '') NOT IN ('admin', 'encargado') THEN
$r$),

('public.aceptar_movimiento_sucursal(bigint,jsonb)', 1,
$a$  IF current_sucursal_id() <> v_destino THEN
$a$,
$r$  -- #1488: con NULL (no es de la sucursal del header, o está desactivado) el `<>`
  -- no cortaba. Primero la sucursal, después el rol, y los dos fallan cerrados.
  IF current_sucursal_id() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Tu usuario no tiene acceso a la sucursal seleccionada'); END IF;
  IF current_sucursal_id() IS DISTINCT FROM v_destino THEN
$r$),
('public.aceptar_movimiento_sucursal(bigint,jsonb)', 2,
$a$  IF public._rol_en_sucursal(auth.uid(), v_destino) NOT IN ('admin', 'encargado') THEN
$a$,
$r$  IF COALESCE(public._rol_en_sucursal(auth.uid(), v_destino), '') NOT IN ('admin', 'encargado') THEN
$r$),

('public.denegar_movimiento_sucursal(bigint,text)', 1,
$a$  IF current_sucursal_id() <> v_destino THEN
$a$,
$r$  -- #1488: con NULL (no es de la sucursal del header, o está desactivado) el `<>`
  -- no cortaba. Primero la sucursal, después el rol, y los dos fallan cerrados.
  IF current_sucursal_id() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Tu usuario no tiene acceso a la sucursal seleccionada'); END IF;
  IF current_sucursal_id() IS DISTINCT FROM v_destino THEN
$r$),
('public.denegar_movimiento_sucursal(bigint,text)', 2,
$a$  IF public._rol_en_sucursal(auth.uid(), v_destino) NOT IN ('admin', 'encargado') THEN
$a$,
$r$  IF COALESCE(public._rol_en_sucursal(auth.uid(), v_destino), '') NOT IN ('admin', 'encargado') THEN
$r$),

('public.editar_movimiento_sucursal(bigint,text,jsonb)', 1,
$a$  IF current_sucursal_id() <> v_origen THEN
$a$,
$r$  -- #1488: con NULL (no es de la sucursal del header, o está desactivado) el `<>`
  -- no cortaba. Primero la sucursal, después el rol, y los dos fallan cerrados.
  IF current_sucursal_id() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Tu usuario no tiene acceso a la sucursal seleccionada'); END IF;
  IF current_sucursal_id() IS DISTINCT FROM v_origen THEN
$r$),
('public.editar_movimiento_sucursal(bigint,text,jsonb)', 2,
$a$  IF public._rol_en_sucursal(auth.uid(), v_origen) <> 'admin' THEN
$a$,
$r$  IF COALESCE(public._rol_en_sucursal(auth.uid(), v_origen), '') <> 'admin' THEN
$r$),

('public.cancelar_movimiento_sucursal(bigint,text)', 1,
$a$  IF current_sucursal_id() <> v_origen THEN
$a$,
$r$  -- #1488: con NULL (no es de la sucursal del header, o está desactivado) el `<>`
  -- no cortaba. Primero la sucursal, después el rol, y los dos fallan cerrados.
  IF current_sucursal_id() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Tu usuario no tiene acceso a la sucursal seleccionada'); END IF;
  IF current_sucursal_id() IS DISTINCT FROM v_origen THEN
$r$),
('public.cancelar_movimiento_sucursal(bigint,text)', 2,
$a$  IF public._rol_en_sucursal(auth.uid(), v_origen) <> 'admin' THEN
$a$,
$r$  IF COALESCE(public._rol_en_sucursal(auth.uid(), v_origen), '') <> 'admin' THEN
$r$),

('public.auditoria_rpcs_definer()', 1,
$a$  v_suc_tablas jsonb := '[]';
$a$,
$r$  v_suc_tablas jsonb := '[]';
  v_guardas jsonb := '[]';  -- #1488
$r$),
('public.auditoria_rpcs_definer()', 2,
$a$  END LOOP;

  RETURN jsonb_build_object(
$a$,
$r$
    -- 4 · Las guardas que fallan abiertas con NULL (#1488). `IF current_sucursal_id() <> v`
    -- e `IF _rol_en_sucursal(…) NOT IN (…)` no cortan cuando el helper da NULL (el header
    -- nombra una sucursal ajena, o el perfil está desactivado): NULL <> v es NULL, y el IF
    -- lo toma como falso. La sucursal se exime si el cuerpo chequea `IS NULL` sobre ella o un
    -- alias; el rol, sólo con COALESCE (el `)` de la llamada no va seguido del operador). Es
    -- texto: no ve un alias de dos saltos ni un IS NULL que rija para otra rama.
    IF (    (r.src ~ ('(' || v_suc || ')\s*(<>|!=|not\s+in\M)')
             OR r.src ~ ('(<>|!=)\s*(' || v_suc || ')'))
        AND r.src !~ ('(' || v_suc || ')\s+is\s+null'))
       OR r.src ~ '_rol_en_sucursal\s*\([^()]*(\([^()]*\)[^()]*)*\)\s*(<>|!=|not\s+in\M)' THEN
      v_guardas := v_guardas || jsonb_build_object('firma', r.firma, 'nombre', r.nombre);
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
$r$),
('public.auditoria_rpcs_definer()', 3,
$a$    'tablas_sucursal', v_suc_tablas);
$a$,
$r$    'tablas_sucursal', v_suc_tablas,
    'guardas_nulas', v_guardas);
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
        RAISE EXCEPTION 'mig 469 · % parche %: el ancla aparece % vez/veces y se esperaba %',
          v_f.firma, v_p.orden, v_n, v_p.veces;
      END IF;
      v_def := replace(v_def, v_p.ancla, v_p.reemplazo);
    END LOOP;
    EXECUTE v_def;
  END LOOP;
END
$parches$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, los EXECUTE y el SECURITY DEFINER quedaron como en el repo, y el
-- gate nuevo no ve ninguna guarda abierta (las cinco de movimientos eran todas las que había).
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  v_guardas jsonb;
BEGIN
  FOR r IN
    SELECT t.firma, t.hash, t.acl, md5(p.prosrc) AS h, p.proacl::text AS a, p.prosecdef AS def
      FROM (VALUES
        ('public.crear_movimiento_sucursal(bigint,text,jsonb)',   '255c6e7ae58fa8e39007daedde4e89c0',
         '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public.aceptar_movimiento_sucursal(bigint,jsonb)',      'cb4b0f2b893789f17d0b262d46502dcb',
         '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public.denegar_movimiento_sucursal(bigint,text)',       'ab811d1116f642a3675a92a7b151189c',
         '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public.editar_movimiento_sucursal(bigint,text,jsonb)',  'e2005a2061e79a6e00aea3ba4b13c7f4',
         '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public.cancelar_movimiento_sucursal(bigint,text)',      '77ebfeff2e5e43788aea595c41971819',
         '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public.auditoria_rpcs_definer()',                       '35ccb13582403cf6d07c05a593ac3130',
         '{postgres=X/postgres,service_role=X/postgres}')
      ) AS t(firma, hash, acl)
      JOIN pg_proc p ON p.oid = t.firma::regprocedure
  LOOP
    IF r.h <> r.hash OR r.a IS DISTINCT FROM r.acl OR NOT r.def THEN
      RAISE EXCEPTION '% no quedó como en el repo (md5 %, acl %, definer %)', r.firma, r.h, r.a, r.def;
    END IF;
  END LOOP;
  v_guardas := public.auditoria_rpcs_definer()->'guardas_nulas';
  IF v_guardas IS DISTINCT FROM '[]'::jsonb THEN
    RAISE EXCEPTION 'auditoria_rpcs_definer() todavía ve guardas abiertas: %', v_guardas;
  END IF;
END
$post$;

COMMIT;
