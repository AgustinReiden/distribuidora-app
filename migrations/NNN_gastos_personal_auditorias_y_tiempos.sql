-- =========================================================================
-- NNN · GASTOS, PERSONAL, FUNCIONES SIN CRLF Y DOS AUDITORÍAS
--       (plan #1603, ola 2, tanda 5, tarjeta C5)
--
-- Ensayo: scripts/test-gastos-y-auditorias-ola2-1603.sql. Se aplica en LF, y da
-- lo mismo en una sola transacción (producción) que sentencia por sentencia
-- (el CI): abre y cierra la suya, como la 529 y la 530.
--
-- 1 · 1562-b2 (#1562) · _guardar_gasto: un 'Infinity' (o '-Infinity') en un
--     importe o en los litros pasaba la guarda del NaN y los litros llegaban
--     al INSERT: «numeric field overflow» crudo. Ahora un infinito es «un dato
--     con un formato inválido», como el NaN, y los litros tienen el techo de su
--     columna (numeric(10,2)) con su motivo. Los demás importes ya tenían techo
--     o una guarda que los frena (el total, el neto, la alícuota).
-- 2 · 1597-b6 (#1597) · guardar_empleado: la fecha de ingreso no puede ser
--     futura ni 'infinity'. Rige al cargarla y al cambiarla: una ficha que ya
--     la tiene así se sigue editando sin tocarla (como la fecha de un gasto).
-- 3 · SEG-6 (#1545) · TODA función de public con '\r' en el cuerpo (29 en la
--     530: gastos, personal, liquidaciones y cuatro triggers de updated_at) se
--     recrea en LF. Se eligen por el catálogo, no por una lista escrita a mano
--     que se desactualiza; la premisa es que en cada una todos los '\r' son de
--     fin de línea (van seguidos de '\n'), que ninguno está dentro de un literal
--     y que el cuerpo no tiene cadenas con '$...$' adentro: si una no cumple, la
--     migración aborta y la nombra. La poscondición prueba que el texto nuevo es
--     el de antes sin los '\r' (más los parches de 1 y 2) y que dueño, permisos,
--     SECURITY DEFINER, volatilidad, costo, ROWS y lo demás quedan iguales, y
--     que no queda ninguna función de public con '\r'. NO cambia ninguna lógica.
--     El search_path de cada función que se recrea termina en pg_temp (B15).
-- 4 · 1332-f (#1332) · auditoria_integridad(): tres checks de las roturas a
--     cargo del empleado (gastos 7, mig 450): ROT-A una rotura viva apunta a
--     una salvedad «A cargo de empleados» o a una merma sin anular; ROT-B una
--     salvedad «A cargo de empleados» tiene al menos una rotura viva; ROT-C la
--     compensación de una rotura es su espejo. Y SEG-C: ninguna función de
--     public con '\r' (así no vuelve a entrar; el gate «auditoria_integridad()
--     estructural» del CI lo corre). Se suman por ancla, sin premisa de md5
--     (otras tarjetas también le suman checks): el ancla aparece una vez.
-- 5 · auditoria_fechas_utc(): sacaba los comentarios de línea antes que los
--     literales, así que un literal con '--' escondía el resto de la línea. Usa
--     _sql_sin_comentarios y _sql_sin_comentarios_ni_literales (#1541).
--
-- N8 (tiempos con estadísticas viejas) no cambia código: decisión de la
-- coordinadora (19/11). La regla de correr ANALYZE después de una carga masiva
-- está en CLAUDE.md, y se mide con scripts/tiempos-ventas-estadisticas-viejas-ola2-1603.sql.
--
-- SIN DDL DE TABLAS: sólo CREATE OR REPLACE / ALTER FUNCTION, no toma locks de
-- tablas. No cambia firmas ni permisos.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

-- =========================================================================
-- 0 · Premisas
-- =========================================================================
DO $premisas$
DECLARE
  r record;
  v text;
  v_n int;
BEGIN
  -- Las que se parchan: los cuerpos de la 530.
  FOR r IN SELECT * FROM (VALUES
    ('public._guardar_gasto(jsonb,boolean)', 'be65ace1cf3f5cd26a72e95c4cb1ecdc'),
    ('public.guardar_empleado(jsonb)', '3765d0525746dbee35083f05d7da631b'),
    ('public.auditoria_fechas_utc()', 'e1ee6c6cf4fc0736bb386d27fb32c17f'),
    -- auditoria_integridad va sin md5 (otras tarjetas le suman checks): se
    -- exige que su ancla aparezca una vez.
    ('public.auditoria_integridad()', NULL),
    ('public._sql_sin_comentarios(text)', NULL),
    ('public._sql_sin_comentarios_ni_literales(text)', NULL)
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    IF r.h IS NULL THEN CONTINUE; END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM pg_proc WHERE oid = 'public.auditoria_integridad()'::regprocedure
                AND prosrc ~ '''(ROT-[ABC]|SEG-C)''') THEN
    RAISE EXCEPTION 'mig NNN · auditoria_integridad() ya tiene checks ROT-* o SEG-C: revisar a mano';
  END IF;

  -- SEG-6: cada función de public con '\r' se puede limpiar sin cambiar nada.
  FOR r IN SELECT p.oid::regprocedure AS f, p.prosrc, p.prokind
             FROM pg_proc p
            WHERE p.pronamespace = 'public'::regnamespace AND position(E'\r' IN p.prosrc) > 0
              AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass
                                 AND d.objid = p.oid AND d.deptype = 'e') LOOP
    IF r.prokind NOT IN ('f', 'p') THEN
      RAISE EXCEPTION 'mig NNN · % no es una función ni un procedimiento: revisar a mano', r.f;
    END IF;
    IF length(r.prosrc) - length(replace(r.prosrc, E'\r', ''))
       <> length(r.prosrc) - length(replace(r.prosrc, E'\r\n', E'\n')) THEN
      RAISE EXCEPTION 'mig NNN · % tiene un \r que no es de fin de línea: no se toca', r.f;
    END IF;
    IF (SELECT length(s) - length(replace(s, E'\r', '')) FROM (SELECT public._sql_sin_comentarios(r.prosrc) s) z)
       <> (SELECT length(s) - length(replace(s, E'\r', '')) FROM (SELECT public._sql_sin_comentarios_ni_literales(r.prosrc) s) z) THEN
      RAISE EXCEPTION 'mig NNN · % tiene un \r dentro de un literal: no se toca', r.f;
    END IF;
    IF r.prosrc ~ '\$[A-Za-z_]*\$' THEN
      RAISE EXCEPTION 'mig NNN · % tiene una cadena entre $...$ en el cuerpo: revisar a mano', r.f;
    END IF;
  END LOOP;
  SELECT count(*) INTO v_n FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND position(E'\r' IN prosrc) > 0;
  RAISE NOTICE 'mig NNN · % funciones de public con CRLF se pasan a LF', v_n;
END
$premisas$;

-- La foto de antes, para la poscondición (dueño, permisos, atributos y texto):
-- las de CRLF y las dos auditorías que se parchan.
CREATE TEMP TABLE c5_antes ON COMMIT DROP AS
SELECT p.oid, p.oid::regprocedure::text AS firma, p.prosrc,
       position(E'\r' IN p.prosrc) > 0 AS crlf,
       p.proowner, p.proacl, p.prosecdef, p.provolatile, p.proparallel, p.proisstrict,
       p.proleakproof, p.procost, p.prorows, p.proconfig, p.prorettype, p.proretset,
       p.prolang, p.prokind, p.prosupport, p.proargnames, p.proargdefaults
  FROM pg_proc p
 WHERE p.pronamespace = 'public'::regnamespace
   AND (position(E'\r' IN p.prosrc) > 0
        OR p.oid IN ('public.auditoria_fechas_utc()'::regprocedure, 'public.auditoria_integridad()'::regprocedure))
   AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass
                      AND d.objid = p.oid AND d.deptype = 'e');

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

-- Los parches de los puntos 1 y 2 (anclas en LF: se aplican después de sacar
-- los '\r'). La poscondición los rehace sobre el cuerpo de antes y compara.
CREATE TEMP TABLE c5_parches (fn regprocedure, ancla text, nuevo text) ON COMMIT DROP;
INSERT INTO c5_parches VALUES
('public._guardar_gasto(jsonb,boolean)',
$a$  IF 'NaN'::numeric IN (v_total, v_iva, v_piva, v_piibb, v_otros, v_alicuota, v_litros) THEN
    RAISE EXCEPTION 'Hay un dato del gasto con un formato inválido';
  END IF;
$a$,
$n$  IF 'NaN'::numeric IN (v_total, v_iva, v_piva, v_piibb, v_otros, v_alicuota, v_litros) THEN
    RAISE EXCEPTION 'Hay un dato del gasto con un formato inválido';
  END IF;
  -- 1562-b2 (#1562): un infinito pasa toda guarda que no lo nombra; los litros
  -- llegaban al INSERT y daban «numeric field overflow» crudo.
  IF 'Infinity'::numeric IN (abs(v_total), abs(v_iva), abs(v_piva), abs(v_piibb), abs(v_otros),
                             abs(v_alicuota), abs(v_litros)) THEN
    RAISE EXCEPTION 'Hay un dato del gasto con un formato inválido';
  END IF;
$n$),
('public._guardar_gasto(jsonb,boolean)',
$a$  IF v_litros IS NOT NULL AND v_litros <= 0 THEN
    RAISE EXCEPTION 'Los litros tienen que ser más que cero';
  END IF;
$a$,
$n$  IF v_litros IS NOT NULL AND v_litros <= 0 THEN
    RAISE EXCEPTION 'Los litros tienen que ser más que cero';
  END IF;
  -- 1562-b2: el techo de la columna (numeric(10,2)), con su motivo.
  IF v_litros > 99999999.99 THEN
    RAISE EXCEPTION 'Los litros no pueden pasar de 99.999.999,99';
  END IF;
$n$),
('public.guardar_empleado(jsonb)',
$a$  v_dos := COALESCE(v_dos, v_viejo.de_las_dos, false);
$a$,
$n$  v_dos := COALESCE(v_dos, v_viejo.de_las_dos, false);

  -- 1597-b6 (#1597): la fecha de ingreso es un día de verdad y no es futura. Rige
  -- al cargarla y al cambiarla: una ficha que ya la tiene así se sigue editando.
  IF v_ingreso IS NOT NULL AND (v_id IS NULL OR v_ingreso IS DISTINCT FROM v_viejo.fecha_ingreso) THEN
    IF NOT isfinite(v_ingreso) THEN
      RAISE EXCEPTION 'Hay un dato del empleado con un formato inválido';
    END IF;
    IF v_ingreso > public._tablero_hoy() THEN
      RAISE EXCEPTION 'La fecha de ingreso no puede ser futura';
    END IF;
  END IF;
$n$);

-- =========================================================================
-- 1, 2 y 3 · Las de CRLF, en LF (y los dos parches)
-- =========================================================================
DO $lf$
DECLARE
  r record;
  p record;
  v_def text;
BEGIN
  IF (SELECT count(*) FROM c5_parches pa WHERE NOT EXISTS (SELECT 1 FROM c5_antes a WHERE a.oid = pa.fn AND a.crlf)) > 0 THEN
    RAISE EXCEPTION 'mig NNN · _guardar_gasto o guardar_empleado ya no tienen CRLF: revisar a mano';
  END IF;
  FOR r IN SELECT a.oid, a.firma FROM c5_antes a WHERE a.crlf ORDER BY a.firma LOOP
    v_def := replace(pg_get_functiondef(r.oid), E'\r', '');
    FOR p IN SELECT * FROM c5_parches WHERE fn = r.oid LOOP
      v_def := pg_temp.parche(v_def, p.ancla, p.nuevo, r.firma);
    END LOOP;
    EXECUTE v_def;
  END LOOP;
END
$lf$;

-- =========================================================================
-- 5 · auditoria_fechas_utc(): la limpieza de una pasada (#1541)
-- =========================================================================
DO $fechas$
DECLARE
  v_def text := pg_get_functiondef('public.auditoria_fechas_utc()'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$    -- Sin comentarios de bloque y de línea (crudo), y además sin literales (src).
    -- El de línea se escribe -{2} para que este mismo cuerpo no se corte solo.
    SELECT t.nombre, t.firma, t.crudo, regexp_replace(t.crudo, '''[^'']*''', ' ', 'g') AS src
      FROM (SELECT p.proname::text AS nombre, p.oid::regprocedure::text AS firma,
                   regexp_replace(regexp_replace(p.prosrc, '/\*.*?\*/', ' ', 'g'), '-{2}[^\n]*', ' ', 'g') AS crudo
$a$,
$n$    -- Sin comentarios (crudo), y además sin literales (src): una sola pasada que
    -- entiende las comillas (#1541). Sacar primero los comentarios de línea y
    -- después los literales escondía lo que seguía a un literal con dos guiones.
    SELECT t.nombre, t.firma, t.crudo, public._sql_sin_comentarios_ni_literales(t.prosrc) AS src
      FROM (SELECT p.proname::text AS nombre, p.oid::regprocedure::text AS firma, p.prosrc,
                   public._sql_sin_comentarios(p.prosrc) AS crudo
$n$, 'auditoria_fechas_utc (funciones)');
  v_def := pg_temp.parche(v_def,
$a$                        ELSE regexp_replace(o.crudo, '''[^'']*''', ' ', 'g') END) ~* pat.re
$a$,
$n$                        ELSE public._sql_sin_comentarios_ni_literales(o.crudo) END) ~* pat.re
$n$, 'auditoria_fechas_utc (objetos)');
  EXECUTE v_def;
END
$fechas$;

-- =========================================================================
-- 4 · auditoria_integridad(): las roturas a cargo del empleado y SEG-C
-- =========================================================================
DO $integridad$
DECLARE
  v_def text := pg_get_functiondef('public.auditoria_integridad()'::regprocedure);
  v_ancla text := $a$
  )
  SELECT jsonb_agg(
    jsonb_build_object('id',id,'severidad',severidad,'descripcion',descripcion,'violaciones',viol,'ok',(viol=0))$a$;
BEGIN
  v_def := pg_temp.parche(v_def, v_ancla, $n$,
    -- 1332-f (#1332) · gastos 7: una rotura viva (la que nadie compensó) apunta
    -- a una salvedad resuelta «A cargo de empleados» (descuento_transportista) o
    -- a una merma sin anular. anular_salvedad compensa las de su salvedad; una
    -- merma manual no se anula, y su rotura se revierte desde la cuenta.
    ('ROT-A','high','roturas a cargo de un empleado que siguen vivas sobre una salvedad anulada o no «A cargo de empleados», o sobre una merma anulada (#1332)',
      (SELECT count(*) FROM empleado_movimientos m
         LEFT JOIN salvedades_items s ON s.id = m.salvedad_id
         LEFT JOIN mermas_stock ms ON ms.id = m.merma_id
        WHERE m.tipo = 'rotura' AND m.revierte_id IS NULL
          AND NOT EXISTS (SELECT 1 FROM empleado_movimientos rv WHERE rv.revierte_id = m.id)
          AND ((m.salvedad_id IS NOT NULL AND s.estado_resolucion IS DISTINCT FROM 'descuento_transportista')
            OR (m.merma_id IS NOT NULL AND ms.anulada_at IS NOT NULL)))),
    -- resolver_salvedad exige al menos una línea para «A cargo de empleados», y
    -- la rotura de una salvedad sólo se deshace anulándola.
    ('ROT-B','high','salvedades «A cargo de empleados» sin ninguna rotura viva (#1332)',
      (SELECT count(*) FROM salvedades_items s
        WHERE s.estado_resolucion = 'descuento_transportista'
          AND NOT EXISTS (SELECT 1 FROM empleado_movimientos m
                           WHERE m.salvedad_id = s.id AND m.tipo = 'rotura' AND m.revierte_id IS NULL
                             AND NOT EXISTS (SELECT 1 FROM empleado_movimientos rv WHERE rv.revierte_id = m.id)))),
    -- La compensación (anular_salvedad, revertir_movimiento_empleado) es la
    -- misma rotura con el monto opuesto: mismo empleado, misma merma o salvedad,
    -- y no compensa a otra compensación.
    ('ROT-C','high','compensaciones de una rotura que no son su espejo: otro tipo, otro empleado, otro monto u otro origen (#1332)',
      (SELECT count(*) FROM empleado_movimientos rv
         JOIN empleado_movimientos m ON m.id = rv.revierte_id
        WHERE (rv.tipo = 'rotura' OR m.tipo = 'rotura')
          AND (rv.tipo IS DISTINCT FROM m.tipo OR rv.empleado_id <> m.empleado_id OR rv.monto <> -m.monto
               OR rv.merma_id IS DISTINCT FROM m.merma_id OR rv.salvedad_id IS DISTINCT FROM m.salvedad_id
               OR m.revierte_id IS NOT NULL))),
    -- SEG-6 (#1545): un cuerpo con CRLF no se encuentra con un ancla en LF y
    -- las migraciones lo van arrastrando. Las de extensiones no cuentan.
    ('SEG-C','high','funciones de public con CRLF en el cuerpo (SEG-6, #1545)',
      (SELECT count(*) FROM pg_proc p
        WHERE p.pronamespace = 'public'::regnamespace AND position(E'\r' IN p.prosrc) > 0
          AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass
                             AND d.objid = p.oid AND d.deptype = 'e')))$n$ || v_ancla, 'auditoria_integridad');
  EXECUTE v_def;
END
$integridad$;

-- =========================================================================
-- pg_temp al final del search_path de toda función que se recreó y fija uno
-- (regla de B15; si B15 ya se aplicó, no hace nada)
-- =========================================================================
DO $pgtemp$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT a.oid, substr(c, length('search_path=') + 1) AS sp
             FROM c5_antes a JOIN pg_proc p ON p.oid = a.oid
             CROSS JOIN LATERAL unnest(p.proconfig) c
            WHERE c LIKE 'search_path=%' AND c !~ 'pg_temp\s*$' LOOP
    EXECUTE format('ALTER FUNCTION %s SET search_path = %s, pg_temp', r.oid::regprocedure, r.sp);
  END LOOP;
  IF EXISTS (SELECT 1 FROM c5_antes a JOIN pg_proc p ON p.oid = a.oid
              WHERE p.prosecdef AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%')) THEN
    RAISE EXCEPTION 'mig NNN · hay una definer sin search_path: revisar a mano';
  END IF;
END
$pgtemp$;

-- =========================================================================
-- Poscondición
-- =========================================================================
DO $post$
DECLARE
  a record;
  v_new pg_proc%ROWTYPE;
  v_esperado text;
  v_cfg text[];
  p record;
  v_n int;
BEGIN
  FOR a IN SELECT * FROM c5_antes LOOP
    SELECT * INTO v_new FROM pg_proc WHERE oid = a.oid;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'mig NNN · % desapareció', a.firma;
    END IF;
    -- Lo que no cambia en ninguna: dueño, permisos, atributos, firma y lenguaje.
    IF v_new.proowner <> a.proowner OR v_new.proacl IS DISTINCT FROM a.proacl
       OR v_new.prosecdef <> a.prosecdef OR v_new.provolatile <> a.provolatile
       OR v_new.proparallel <> a.proparallel OR v_new.proisstrict <> a.proisstrict
       OR v_new.proleakproof <> a.proleakproof OR v_new.procost <> a.procost
       OR v_new.prorows <> a.prorows OR v_new.prorettype <> a.prorettype
       OR v_new.proretset <> a.proretset OR v_new.prolang <> a.prolang
       OR v_new.prokind <> a.prokind OR v_new.prosupport <> a.prosupport
       OR v_new.proargnames IS DISTINCT FROM a.proargnames
       OR v_new.proargdefaults::text IS DISTINCT FROM a.proargdefaults::text THEN
      RAISE EXCEPTION 'mig NNN · % cambió de dueño, permisos o atributos', a.firma;
    END IF;
    -- El SET: el mismo, con pg_temp al final del search_path.
    v_cfg := ARRAY(SELECT CASE WHEN c LIKE 'search_path=%' AND c !~ 'pg_temp\s*$' THEN c || ', pg_temp' ELSE c END
                     FROM unnest(a.proconfig) WITH ORDINALITY u(c, n) ORDER BY n);
    IF v_new.proconfig IS DISTINCT FROM (CASE WHEN a.proconfig IS NULL THEN NULL ELSE v_cfg END) THEN
      RAISE EXCEPTION 'mig NNN · % quedó con SET %, antes %', a.firma, v_new.proconfig, a.proconfig;
    END IF;
    IF position(E'\r' IN v_new.prosrc) > 0 THEN
      RAISE EXCEPTION 'mig NNN · % sigue con CRLF', a.firma;
    END IF;
    -- El texto de las de CRLF: el de antes sin los '\r', con los parches.
    IF a.crlf THEN
      v_esperado := replace(a.prosrc, E'\r', '');
      FOR p IN SELECT * FROM c5_parches WHERE fn = a.oid LOOP
        v_esperado := replace(v_esperado, p.ancla, p.nuevo);
      END LOOP;
      IF v_new.prosrc IS DISTINCT FROM v_esperado THEN
        RAISE EXCEPTION 'mig NNN · % no quedó con el texto de antes sin los CR (y sus parches)', a.firma;
      END IF;
    END IF;
  END LOOP;

  SELECT count(*) INTO v_n FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND position(E'\r' IN prosrc) > 0;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'mig NNN · quedan % funciones de public con CRLF', v_n;
  END IF;
  -- Los parches entraron.
  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public._guardar_gasto(jsonb,boolean)'::regprocedure)
       !~ 'Los litros no pueden pasar de 99\.999\.999,99'
     OR (SELECT prosrc FROM pg_proc WHERE oid = 'public._guardar_gasto(jsonb,boolean)'::regprocedure)
       !~ '''Infinity''::numeric IN \(abs\(v_total\)'
     OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.guardar_empleado(jsonb)'::regprocedure)
       !~ 'La fecha de ingreso no puede ser futura' THEN
    RAISE EXCEPTION 'mig NNN · faltan los parches de gastos o de personal';
  END IF;
  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.auditoria_fechas_utc()'::regprocedure)
       ~ 'regexp_replace\(t\.crudo'
     OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.auditoria_fechas_utc()'::regprocedure)
       !~ 'public\._sql_sin_comentarios\(p\.prosrc\) AS crudo' THEN
    RAISE EXCEPTION 'mig NNN · auditoria_fechas_utc no quedó con la limpieza de una pasada';
  END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(
    (SELECT prosrc FROM pg_proc WHERE oid = 'public.auditoria_integridad()'::regprocedure), '''(ROT-[ABC]|SEG-C)''', 'g');
  IF v_n <> 4 THEN
    RAISE EXCEPTION 'mig NNN · auditoria_integridad tiene % checks ROT-*/SEG-C (esperados 4)', v_n;
  END IF;
END
$post$;

COMMIT;
