-- =========================================================================
-- NNN · GASTOS Y PERSONAL: EL TOPE DEL IVA POR RENGLÓN, LA ÚLTIMA CUOTA, LA
--       FECHA DEL REINTEGRO, LOS RUBROS DE TODA LA EMPRESA, LAS PALABRAS DE
--       SUELDO, EL LOCK DEL EMPLEADO Y LA VERSIÓN DE LA EDICIÓN
--       (plan #1603, ola 2, tarjeta B8a: 1562-c1, 1562-b1, 1597-b4, 1597-b5,
--        GTO-B y GTO-E de #1545, 1599-b9)
--
-- Parcha por ancla `_guardar_gasto`, `_anular_gasto` y `guardar_rubro_gasto`,
-- y reemplaza `_gasto_cuota`, `_rubro_es_sueldo` y `gastos_cuenta_empleado`
-- (con su trigger), con premisa de md5 sobre el cuerpo vivo del 16/11 (ledger
-- en la 512). Suma la columna `gastos.renglones_factura`. No cambia firmas.
-- Ensayo: scripts/test-gastos-personal-ola2-1603.sql. Se aplica en LF.
--
-- Fin de línea de los cuerpos vivos: `_guardar_gasto` y `gastos_cuenta_empleado`
-- están en CRLF en prod (SEG-6, que arregla B9 recreándolas en LF). La premisa
-- compara el md5 del cuerpo normalizado a LF, así que pasa igual antes o
-- después de B9, y el ancla se busca en LF y, si no aparece, en CRLF (el texto
-- nuevo entra con el fin de línea del cuerpo). `gastos_cuenta_empleado` se
-- reemplaza entera y queda en LF.
--
-- =========================================================================
-- 1 · 1562-c1 · EL TOPE DEL IVA TOLERA UN CENTAVO POR RENGLÓN
-- =========================================================================
-- El tope de GTO-2 (#1562) es el 27 % del neto al centavo, `(total −
-- percepciones − otros) × 27/127`. Una factura A al 27 % con el IVA redondeado
-- por renglón lo pasa: dos renglones de neto 100,13 dan 27,04 + 27,04 = 54,08
-- sobre 254,34, y el tope da 54,07. Decisión del dueño (15/11, D40 en #1562):
-- el tope tolera un centavo por renglón de la factura. El gasto no sabía
-- cuántos renglones tiene su factura: ahora lo guarda,
-- `gastos.renglones_factura` (1 por defecto, de 1 a 99: decisión del dueño del
-- 17/11, porque con 999 una factura A de $10 entraba con $9,99 de IVA), y el
-- tope es el de antes más `0,01 × renglones`. Sólo cuenta en una factura A o M; en el resto
-- queda en 1. En una edición, la clave ausente conserva el valor guardado (un
-- PWA de antes no la manda). Espejo: `topeIvaGastoCentavos` y `errorDeDesglose`
-- (src/utils/gastos.ts), y el campo «Renglones» del bloque de IVA de ModalGasto.
--
-- =========================================================================
-- 2 · 1562-b1 · LA ÚLTIMA CUOTA NO QUEDA NEGATIVA
-- =========================================================================
-- `_gasto_cuota` daba las n−1 primeras cuotas redondeadas al centavo y la
-- última con el resto: 0,60 en 120 cuotas son 119 de 0,01 y la última −0,59.
-- Ahora, si las n−1 primeras redondeadas pasan el costo, van truncadas al
-- centavo (0,00) y la última se lleva el resto (0,60). Sólo cambia esos casos:
-- una cuota que hoy no da una última negativa queda igual, así que los meses
-- ya cerrados no se mueven. La suma sigue siendo el costo. Espejo:
-- `cuotaDeGasto` (src/utils/gastos.ts), con los mismos casos en el ensayo y en
-- src/utils/gastos.test.ts.
--
-- =========================================================================
-- 3 · 1597-b4 · LA FECHA DEL REINTEGRO SIGUE A LA DEL GASTO
-- =========================================================================
-- Cambiarle la fecha a un gasto que pagó un empleado no movía su reintegro:
-- `trg_gastos_cuenta_empleado` no miraba `fecha`. Ahora la mira, y el reintegro
-- que nació con la fecha del gasto pasa a la fecha nueva, siempre que no esté
-- dentro de una liquidación (lo pagado es la foto: una liquidación toma los
-- movimientos por id, `_liquidacion_json`). Sólo se mueve ese, el que no lleva
-- motivo: las correcciones de monto (con motivo) siguen con el día en que se
-- hicieron, aunque sea el mismo día del gasto.
--
-- =========================================================================
-- 4 · 1597-b5 · LOS RUBROS DE GASTO LOS CAMBIA UN ADMIN DE TODAS LAS SUCURSALES
-- =========================================================================
-- `gasto_rubros` no tiene sucursal y `guardar_rubro_gasto` sólo pedía
-- `es_admin()`: un admin de una sucursal cambiaba los rubros de todas.
-- Decisión del dueño (15/11, D46 en #1597): los rubros son de toda la empresa
-- y los cambia sólo un admin que esté en todas las sucursales
-- (`_tiene_todas_las_sucursales`). Rige para crear y para editar.
--
-- =========================================================================
-- 5 · GTO-B · LAS PALABRAS DE SUELDO
-- =========================================================================
-- Decisión del dueño (15/11, D45 en #1545): «remuneraciones» y «comisiones» se
-- detectan como rubro de sueldo (la comisión sale de la liquidación: como gasto
-- se contaría dos veces), en cualquier parte del nombre como las demás. La
-- comisión de un medio de cobro (banco, tarjeta, Mercado Pago o Libre, Posnet,
-- Naranja, Ualá, MODO, Rapipago, Pago Fácil, transferencia) sigue siendo gasto:
-- el ensayo de la 488 tiene «Comisiones bancarias» como tal; la lista la armó la
-- tarjeta con la revisión adversarial. «sac» y «vacaciones» se frenan como
-- palabra dentro del nombre, como hoy (decisión del dueño del 17/11: «Pago de
-- SAC», «SAC 2026» y «Vacaciones del personal» se siguen frenando; «Bolsas SAC»
-- y «Seguro de vacaciones del vehículo» también). Las letras sueltas separadas
-- por puntos, guiones, espacios o guiones bajos se juntan antes de comparar:
-- «S.A.C.», «S-A-C» y «S_A_C» son «sac». El CHECK `gasto_rubros_nombre_check`
-- se vuelve a crear para que valide las filas con la regla nueva; antes, un
-- bloque lista los rubros que dejaría afuera y aborta.
--
-- =========================================================================
-- 6 · GTO-E · EL EMPLEADO SE TOMA ANTES QUE LA RENDICIÓN Y QUE LA FILA
-- =========================================================================
-- El reintegro de un gasto pagado por un empleado lo escribe el trigger con el
-- gasto ya tomado (y, desde Gastos, la rendición): el empleado sólo quedaba
-- tomado por el FOR KEY SHARE de la FK del movimiento, al final. Eso alcanzaba
-- para que un pago (`registrar_movimiento_empleado`) o una liquidación
-- (`liquidar_empleado`), que toman el empleado FOR UPDATE al entrar, no leyeran
-- un saldo que una anulación baja a la vez: la FK los ponía en fila. Pero
-- dependía de la FK, y el orden quedaba al revés del de esas dos funciones y de
-- `resolver_rendicion` (los empleados por id, después la rendición): editar un
-- gasto de la rendición R para que lo pague el empleado E (R, la fila, E) contra
-- un pago a E con plata de R (E, R) era un 40P01. Ahora `_guardar_gasto` toma
-- el empleado de antes y el de ahora, por id, antes que la rendición, y
-- `_anular_gasto` el suyo antes que la fila. Desde el cierre de una rendición
-- no hay empleado: `confirmar_rendicion` sólo guarda gastos de la rendición.
-- `registrar_movimiento_empleado` y `liquidar_empleado` no cambian: ya toman
-- el empleado primero.
--
-- =========================================================================
-- 7 · 1599-b9 · LA EDICIÓN COMPARA LA VERSIÓN
-- =========================================================================
-- Decisión del dueño (15/11, D47 en #1599): la edición de un gasto avisa si
-- otro lo cambió mientras tanto, como en los pedidos. El JSON trae
-- `updated_at_esperado` (el `updated_at` del gasto que vio quien edita), y
-- `_guardar_gasto` lo compara con la fila: al leerla y, desde Gastos, otra vez
-- con la fila tomada. Sin la clave (un PWA de antes) no compara. La firma de
-- `guardar_gasto(jsonb)` no cambia.
--
-- Revertir: volver los seis cuerpos a los de la premisa, el trigger a
-- `UPDATE OF monto_total, origen_pago, empleado_id, anulado_at`, y quitar la
-- columna `gastos.renglones_factura`.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

-- Las dos tablas que se alteran (la columna y el trigger de gastos, el CHECK de gasto_rubros), de
-- una vez y antes de toda premisa: o se consiguen las dos o falla al instante y se reintenta.
LOCK TABLE public.gastos, public.gasto_rubros IN ACCESS EXCLUSIVE MODE NOWAIT;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos, normalizados a LF. Leídos el 16/11 (ledger en la 512) y
-- comprobados el 17/11 sobre prod en la 519 con la 520, la 521 y la 522 aplicadas encima: esas
-- tres no tocan ninguna de estas funciones.
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public._guardar_gasto(jsonb,boolean)', 'd0549186969d159b154f4adba99f04fc'),
    ('public._anular_gasto(bigint,text,boolean)', 'b51c86655379fca2a68c6a8dc3233921'),
    ('public.gastos_cuenta_empleado()', '08442335dd8cf5e0039feaa4e4762432'),
    ('public.guardar_rubro_gasto(jsonb)', 'e8a9f72d4a00c01b727985f2bdfae3e1'),
    ('public._gasto_cuota(numeric,integer,integer)', '0ea8712fe6da84728ee63b710ae559bd'),
    ('public._rubro_es_sueldo(text)', '333dda97f56c265ce54f2c8e7ca6a8be'),
    -- No cambian, pero el orden de GTO-E cuenta con que toman el empleado primero.
    ('public.registrar_movimiento_empleado(bigint,jsonb)', '86f8222bfa56d02fd9955177e39f7718'),
    ('public.liquidar_empleado(bigint,jsonb)', '1d917c5de3448d76a352d05cce5e5574'),
    -- 1597-b5 cuenta con ella como está.
    ('public._tiene_todas_las_sucursales()', 'c698cd82742989dfab587bdf29e4333e')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(replace(prosrc, E'\r\n', E'\n')) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 en LF %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;

  IF (SELECT pg_get_triggerdef(oid) FROM pg_trigger
       WHERE tgrelid = 'public.gastos'::regclass AND tgname = 'trg_gastos_cuenta_empleado')
     IS DISTINCT FROM 'CREATE TRIGGER trg_gastos_cuenta_empleado AFTER INSERT OR UPDATE OF monto_total, origen_pago, empleado_id, anulado_at ON public.gastos FOR EACH ROW EXECUTE FUNCTION gastos_cuenta_empleado()' THEN
    RAISE EXCEPTION 'mig NNN · trg_gastos_cuenta_empleado no es el de gastos 4';
  END IF;
  IF (SELECT pg_get_constraintdef(oid) FROM pg_constraint
       WHERE conrelid = 'public.gasto_rubros'::regclass AND conname = 'gasto_rubros_nombre_check')
     IS DISTINCT FROM 'CHECK (((btrim(nombre) <> ''''::text) AND (NOT _rubro_es_sueldo(nombre))))' THEN
    RAISE EXCEPTION 'mig NNN · gasto_rubros_nombre_check no es el de la 488';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public' AND table_name = 'gastos' AND column_name = 'renglones_factura') THEN
    RAISE EXCEPTION 'mig NNN · gastos.renglones_factura ya existe';
  END IF;
END
$premisas$;

-- Reemplaza una sola aparición de un ancla. El cuerpo puede estar en LF o en CRLF: el ancla se
-- busca como viene y, si no aparece, con CRLF; el texto nuevo entra con el mismo fin de línea.
CREATE FUNCTION pg_temp.parche(p_def text, p_ancla text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v_ancla text := p_ancla;
  v_nuevo text := p_nuevo;
  v_n int := (length(p_def) - length(replace(p_def, p_ancla, ''))) / length(p_ancla);
BEGIN
  IF v_n = 0 AND position(E'\r\n' in p_def) > 0 THEN
    v_ancla := replace(p_ancla, E'\n', E'\r\n');
    v_nuevo := replace(p_nuevo, E'\n', E'\r\n');
    v_n := (length(p_def) - length(replace(p_def, v_ancla, ''))) / length(v_ancla);
  END IF;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · %: el ancla aparece % vez/veces y se esperaba 1', p_que, v_n;
  END IF;
  RETURN replace(p_def, v_ancla, v_nuevo);
END
$f$;

-- =========================================================================
-- 1 · La columna de los renglones de la factura
-- =========================================================================
ALTER TABLE public.gastos
  ADD COLUMN renglones_factura integer NOT NULL DEFAULT 1
  CONSTRAINT gastos_renglones_factura_rango CHECK (renglones_factura BETWEEN 1 AND 99);

COMMENT ON COLUMN public.gastos.renglones_factura IS
  '1562-c1 (#1562, D40): cuántos renglones tiene la factura A o M del gasto, de 1 a 99 (decisión del dueño, 17/11). El tope del IVA tolera un centavo por renglón (el IVA redondeado por renglón). 1 en el resto de los comprobantes. La escribe sólo _guardar_gasto.';

-- =========================================================================
-- 2 · 1562-b1 · _gasto_cuota
-- =========================================================================
CREATE OR REPLACE FUNCTION public._gasto_cuota(p_costo numeric, p_n integer, p_k integer)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  -- Cuota k de n: las n−1 primeras valen costo/n al centavo y la última se lleva el resto.
  -- 1562-b1 (#1562): si las n−1 primeras redondeadas pasan el costo (0,60 en 120: 119 × 0,01),
  -- la última quedaría negativa; ahí van truncadas al centavo y la última se lleva el resto. Lo
  -- que no daba una última negativa queda igual. Espejo: cuotaDeGasto (src/utils/gastos.ts).
  SELECT CASE
    WHEN p_costo IS NULL OR p_n IS NULL OR p_k IS NULL OR p_n < 1 OR p_k < 1 OR p_k > p_n THEN NULL
    WHEN p_k < p_n THEN c.base
    ELSE p_costo - c.base * (p_n - 1)
  END
    FROM (SELECT CASE WHEN abs(round(p_costo / NULLIF(p_n, 0), 2)) * (p_n - 1) > abs(p_costo)
                      THEN trunc(p_costo / NULLIF(p_n, 0), 2)
                      ELSE round(p_costo / NULLIF(p_n, 0), 2) END AS base) c;
$function$;

-- =========================================================================
-- 3 · GTO-B · _rubro_es_sueldo y el CHECK que la usa
-- =========================================================================
CREATE OR REPLACE FUNCTION public._rubro_es_sueldo(p_nombre text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  -- #1521 (GTO-9): los sueldos no son un gasto, salen de las liquidaciones del personal. Sin
  -- tildes ni mayúsculas. Las cargas sociales, el sindicato y la ART sí son gasto: no están.
  -- #1545 (GTO-B, decisiones del dueño del 15/11 y del 17/11): la palabra en cualquier parte del
  -- nombre, «sac» y «vacaciones» también («Pago de SAC», «Vacaciones del personal»), y se suman
  -- «remuneraciones» y «comisiones» (la comisión sale de la liquidación: como gasto se contaría
  -- dos veces), salvo la de un medio de cobro, que es gasto («Comisiones bancarias», «Comisión
  -- Posnet»). Las letras sueltas separadas por puntos, guiones, espacios o guiones bajos se juntan
  -- antes de comparar: «S.A.C.», «S-A-C» y «S_A_C» son «sac». Los espacios repetidos cuentan uno.
  SELECT y.n ~ '\m(sueldos?|salarios?|haberes|aguinaldos?|sac|jornal(es)?|vacaciones|horas? extras?|presentismo|indemnizacion(es)?|remuneracion(es)?)\M'
      OR (y.n ~ '\mcomision(es)?\M'
          AND y.n !~ '\m(banc[a-z]*|tarjetas?|mercado ?(pago|libre)|posnet|naranja|uala|modo|rapipago|pago ?facil|transferencias?)\M')
    FROM (SELECT translate(lower(COALESCE(p_nombre, '')), 'áéíóúüàèìòù_', 'aeiouuaeiou ') AS t) x
         CROSS JOIN LATERAL (
           SELECT regexp_replace(regexp_replace(x.t, '\m([a-z])[^a-z0-9]+(?=[a-z]\M)', '\1', 'g'), '\s+', ' ', 'g') AS n) y;
$function$;

-- GTO-B · premisa de datos, con la función ya reemplazada (una sola regla): ningún rubro
-- existente queda afuera. Si alguno queda, aborta toda la migración con la lista.
DO $rubros$
DECLARE
  v_malos text;
BEGIN
  SELECT string_agg(format('%s (id %s)', g.nombre, g.id), ', ' ORDER BY g.id) INTO v_malos
    FROM gasto_rubros g
   WHERE public._rubro_es_sueldo(g.nombre);
  IF v_malos IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · estos rubros de gasto pasan a ser de sueldo con GTO-B: % (renombrarlos o darlos de baja antes de aplicar)', v_malos;
  END IF;
END
$rubros$;

-- Se vuelve a crear para que valide las filas con la regla nueva (reemplazar la función no las
-- revisa).
ALTER TABLE public.gasto_rubros DROP CONSTRAINT gasto_rubros_nombre_check;
ALTER TABLE public.gasto_rubros
  ADD CONSTRAINT gasto_rubros_nombre_check CHECK (btrim(nombre) <> '' AND NOT public._rubro_es_sueldo(nombre));

-- =========================================================================
-- 4 · 1597-b5 · guardar_rubro_gasto: sólo un admin de todas las sucursales
-- =========================================================================
DO $parche_rubro$
DECLARE
  v_def text := pg_get_functiondef('public.guardar_rubro_gasto(jsonb)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin puede crear o editar rubros';
  END IF;
$a$,
$r$  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin puede crear o editar rubros';
  END IF;
  -- 1597-b5 (#1597, decisión del dueño 15/11): los rubros de gasto son de toda la empresa
  -- (gasto_rubros no tiene sucursal): los crea y los cambia sólo un admin de todas las sucursales.
  IF NOT public._tiene_todas_las_sucursales() THEN
    RAISE EXCEPTION 'Los rubros de gasto son de toda la empresa: los crea o los cambia un admin que esté en todas las sucursales';
  END IF;
$r$, 'guardar_rubro_gasto (admin de todas)');

  EXECUTE v_def;
END
$parche_rubro$;

-- =========================================================================
-- 5 · _guardar_gasto: renglones, versión y el lock del empleado
-- =========================================================================
DO $parche_guardar$
DECLARE
  v_def text := pg_get_functiondef('public._guardar_gasto(jsonb,boolean)'::regprocedure);
BEGIN
  -- 5a · variables
  v_def := pg_temp.parche(v_def,
$a$  v_emp       bigint;
BEGIN
$a$,
$r$  v_emp       bigint;
  v_renglones integer;
  v_esperado  timestamptz;
BEGIN
$r$, '_guardar_gasto (variables)');

  -- 5b · lectura del JSON
  v_def := pg_temp.parche(v_def,
$a$    v_emp      := NULLIF(p_gasto->>'empleado_id', '')::bigint;
  EXCEPTION WHEN others THEN
$a$,
$r$    v_emp      := NULLIF(p_gasto->>'empleado_id', '')::bigint;
    v_renglones := NULLIF(p_gasto->>'renglones_factura', '')::integer;
    v_esperado := NULLIF(p_gasto->>'updated_at_esperado', '')::timestamptz;
  EXCEPTION WHEN others THEN
$r$, '_guardar_gasto (lectura)');

  -- 5c · 1599-b9: la versión, al leer la fila
  v_def := pg_temp.parche(v_def,
$a$    IF NOT FOUND THEN
      RAISE EXCEPTION 'Ese gasto no existe';
    END IF;
    -- Antes que el vehiculo: si no, cambiar de sucursal un gasto con vehiculo
$a$,
$r$    IF NOT FOUND THEN
      RAISE EXCEPTION 'Ese gasto no existe';
    END IF;
    -- 1599-b9 (#1599, decisión del dueño 15/11): la edición compara la versión que vio quien
    -- edita (`updated_at_esperado`, el updated_at del gasto al abrirlo): si otro lo guardó o lo
    -- anuló en el medio, este guardado no lo pisa. Sin la clave (un PWA de antes) no compara.
    -- Se vuelve a mirar con la fila tomada (8b).
    IF v_esperado IS NOT NULL AND v_viejo.updated_at IS DISTINCT FROM v_esperado THEN
      RAISE EXCEPTION 'Este gasto cambió desde que lo abriste (se guardó o se anuló en el medio): cerralo y volvé a abrirlo para ver cómo quedó';
    END IF;
    -- Antes que el vehiculo: si no, cambiar de sucursal un gasto con vehiculo
$r$, '_guardar_gasto (versión al leer)');

  -- 5d · 1562-c1: el tope del IVA con un centavo por renglón
  v_def := pg_temp.parche(v_def,
$a$  IF v_tipo IN ('factura_a', 'factura_m') THEN
    IF v_total - v_iva - v_piva - v_piibb - v_otros <= 0 THEN
      RAISE EXCEPTION 'Con factura A o M el neto tiene que ser mayor a cero';
    END IF;
    -- #1562 (GTO-2): el IVA no pasa del de la alícuota más alta. Una factura con dos alícuotas es
    -- legal, así que no se fija el IVA exacto: el tope es (total − percepciones − otros) × 27/127,
    -- el 27 % del neto, al centavo.
    IF v_iva > round((v_total - v_piva - v_piibb - v_otros) * 27 / 127, 2) THEN
$a$,
$r$  IF v_tipo IN ('factura_a', 'factura_m') THEN
    -- 1562-c1 (#1562, D40): los renglones de la factura. En una edición, la clave ausente
    -- conserva los guardados.
    v_renglones := COALESCE(v_renglones, v_viejo.renglones_factura, 1);
    IF v_renglones NOT BETWEEN 1 AND 99 THEN
      RAISE EXCEPTION 'Los renglones de la factura van de 1 a 99';
    END IF;
    IF v_total - v_iva - v_piva - v_piibb - v_otros <= 0 THEN
      RAISE EXCEPTION 'Con factura A o M el neto tiene que ser mayor a cero';
    END IF;
    -- #1562 (GTO-2): el IVA no pasa del de la alícuota más alta. Una factura con dos alícuotas es
    -- legal, así que no se fija el IVA exacto: el tope es (total − percepciones − otros) × 27/127,
    -- el 27 % del neto, al centavo. 1562-c1 (decisión del dueño 15/11): más un centavo por renglón
    -- de la factura, que redondea el IVA de cada uno (dos renglones de neto 100,13 al 27 % son
    -- 27,04 + 27,04 = 54,08 sobre 254,34, y el 27 % del neto da 54,07).
    IF v_iva > round((v_total - v_piva - v_piibb - v_otros) * 27 / 127, 2) + 0.01 * v_renglones THEN
$r$, '_guardar_gasto (tope del IVA)');

  v_def := pg_temp.parche(v_def,
$a$    -- Sin desglose, la alicuota no significa nada.
    v_alicuota := NULL;
$a$,
$r$    -- Sin desglose, la alicuota no significa nada. Ni los renglones.
    v_alicuota := NULL;
    v_renglones := 1;
$r$, '_guardar_gasto (renglones sin factura A o M)');

  -- 5e · GTO-E: los empleados antes que la rendición y que la fila
  v_def := pg_temp.parche(v_def,
$a$  -- 8 · origen: la oficina, una rendicion o un empleado
$a$,
$r$  -- 7b · GTO-E (#1545): el empleado que pagaba el gasto y el que lo paga ahora, por id, antes que
  --      la rendicion (8b) y que la fila: el orden de registrar_movimiento_empleado,
  --      liquidar_empleado y resolver_rendicion (los empleados, despues la rendicion). El trigger
  --      del reintegro escribe su cuenta con el ya tomado: un pago o una liquidacion del mismo
  --      empleado espera y lee el saldo con el reintegro. Si otro cambia el empleado del gasto en
  --      el medio, 8b lo rechaza. Desde el cierre no hay empleado: confirmar_rendicion solo
  --      guarda gastos de la rendicion.
  IF NOT p_desde_cierre THEN
    PERFORM 1 FROM empleados
     WHERE id IN (CASE WHEN v_origen = 'empleado' THEN v_emp END,
                  CASE WHEN v_viejo.origen_pago = 'empleado' THEN v_viejo.empleado_id END)
     ORDER BY id
       FOR UPDATE;
  END IF;

  -- 8 · origen: la oficina, una rendicion o un empleado
$r$, '_guardar_gasto (lock del empleado)');

  -- 5f · 1599-b9: la versión otra vez, con la fila tomada
  v_def := pg_temp.parche(v_def,
$a$      v_viejo := v_releido;
$a$,
$r$      v_viejo := v_releido;
      IF v_esperado IS NOT NULL AND v_viejo.updated_at IS DISTINCT FROM v_esperado THEN
        RAISE EXCEPTION 'Este gasto cambió desde que lo abriste (se guardó o se anuló en el medio): cerralo y volvé a abrirlo para ver cómo quedó';
      END IF;
$r$, '_guardar_gasto (versión con la fila tomada)');

  -- 5g · la columna nueva en el alta y en la edición
  v_def := pg_temp.parche(v_def,
$a$                        empleado_id, observacion, creado_por)
$a$,
$r$                        empleado_id, observacion, creado_por, renglones_factura)
$r$, '_guardar_gasto (alta, columnas)');
  v_def := pg_temp.parche(v_def,
$a$            v_emp, v_obs, v_uid)
$a$,
$r$            v_emp, v_obs, v_uid, v_renglones)
$r$, '_guardar_gasto (alta, valores)');
  v_def := pg_temp.parche(v_def,
$a$           empleado_id = v_emp, observacion = v_obs, updated_at = now()
$a$,
$r$           empleado_id = v_emp, observacion = v_obs, renglones_factura = v_renglones, updated_at = now()
$r$, '_guardar_gasto (edición)');

  EXECUTE v_def;
END
$parche_guardar$;

-- =========================================================================
-- 6 · GTO-E · _anular_gasto: el empleado antes que la fila
-- =========================================================================
DO $parche_anular$
DECLARE
  v_def text := pg_get_functiondef('public._anular_gasto(bigint,text,boolean)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$    IF v_gasto.origen_pago = 'rendicion' THEN
      PERFORM public._rendicion_bloquear(ARRAY[
$a$,
$r$    -- GTO-E (#1545): el empleado que lo pago, antes que la fila (el orden de _guardar_gasto, de
    -- registrar_movimiento_empleado y de liquidar_empleado). Un pago o una liquidacion del mismo
    -- empleado espera a que el reintegro quede en cero y lee el saldo sin el.
    IF v_gasto.origen_pago = 'empleado' THEN
      PERFORM 1 FROM empleados WHERE id = v_gasto.empleado_id FOR UPDATE;
    END IF;
    IF v_gasto.origen_pago = 'rendicion' THEN
      PERFORM public._rendicion_bloquear(ARRAY[
$r$, '_anular_gasto (lock del empleado)');

  v_def := pg_temp.parche(v_def,
$a$       OR v_releido.rendicion_fecha IS DISTINCT FROM v_gasto.rendicion_fecha THEN
$a$,
$r$       OR v_releido.rendicion_fecha IS DISTINCT FROM v_gasto.rendicion_fecha
       OR v_releido.empleado_id IS DISTINCT FROM v_gasto.empleado_id THEN
$r$, '_anular_gasto (relectura con el empleado)');

  EXECUTE v_def;
END
$parche_anular$;

-- =========================================================================
-- 7 · 1597-b4 · gastos_cuenta_empleado y su trigger: la fecha del reintegro
-- =========================================================================
CREATE OR REPLACE FUNCTION public.gastos_cuenta_empleado()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_objetivo numeric;
  v_emp      bigint;
  v_motivo   text;
  v_corte    bigint;
BEGIN
  IF NEW.origen_pago IS DISTINCT FROM 'empleado' THEN
    IF TG_OP = 'INSERT' THEN
      RETURN NULL;
    END IF;
    IF OLD.origen_pago IS DISTINCT FROM 'empleado' THEN
      RETURN NULL;
    END IF;
  END IF;
  v_emp := CASE WHEN NEW.origen_pago = 'empleado' THEN NEW.empleado_id END;
  v_objetivo := CASE WHEN NEW.origen_pago = 'empleado' AND NEW.anulado_at IS NULL THEN NEW.monto_total ELSE 0 END;
  IF TG_OP = 'UPDATE' THEN
    -- 1597-b4 (#1597): la fecha del reintegro sigue a la del gasto. Se mueve el que nació con la
    -- fecha del gasto, del mismo empleado y fuera de toda liquidación (una liquidación toma los
    -- movimientos por id, como _liquidacion_json: lo pagado no se toca). Es el que no lleva motivo
    -- (_cuenta_empleado_conciliar le pone motivo a toda corrección): las correcciones de monto
    -- quedan con el día en que se hicieron, aunque sea el del gasto. El empleado ya está tomado
    -- (_guardar_gasto, GTO-E).
    IF NEW.fecha IS DISTINCT FROM OLD.fecha
       AND OLD.origen_pago = 'empleado' AND NEW.origen_pago = 'empleado'
       AND OLD.empleado_id = NEW.empleado_id
       AND OLD.anulado_at IS NULL AND NEW.anulado_at IS NULL THEN
      SELECT max(m.id) INTO v_corte
        FROM empleado_movimientos m
        JOIN empleado_liquidaciones li ON li.id = m.liquidacion_id AND li.anulada_at IS NULL
       WHERE m.empleado_id = NEW.empleado_id;
      UPDATE empleado_movimientos m
         SET fecha = NEW.fecha
       WHERE m.gasto_id = NEW.id
         AND m.empleado_id = NEW.empleado_id
         AND m.tipo = 'reintegro'
         AND m.fecha = OLD.fecha
         AND m.observacion IS NULL
         AND m.id > COALESCE(v_corte, 0);
    END IF;
    v_motivo := CASE WHEN NEW.anulado_at IS NOT NULL AND OLD.anulado_at IS NULL THEN 'Se anuló el gasto'
                     WHEN OLD.origen_pago = 'empleado' AND NEW.origen_pago <> 'empleado'
                       THEN 'El gasto dejó de estar pagado por un empleado'
                     WHEN OLD.empleado_id IS DISTINCT FROM NEW.empleado_id THEN 'El gasto pasó a otro empleado'
                     ELSE 'El gasto cambió de monto' END;
  END IF;
  PERFORM public._cuenta_empleado_conciliar('reintegro', NULL, NULL, NULL, NEW.id, v_emp, v_objetivo, NEW.fecha,
                                            NULL, v_motivo);
  RETURN NULL;
END
$function$;

DROP TRIGGER trg_gastos_cuenta_empleado ON public.gastos;
CREATE TRIGGER trg_gastos_cuenta_empleado
  AFTER INSERT OR UPDATE OF monto_total, origen_pago, empleado_id, anulado_at, fecha ON public.gastos
  FOR EACH ROW EXECUTE FUNCTION public.gastos_cuenta_empleado();

-- ---------------------------------------------------------------------------
-- Poscondiciones
-- ---------------------------------------------------------------------------
DO $pos$
DECLARE
  v_g text := replace(pg_get_functiondef('public._guardar_gasto(jsonb,boolean)'::regprocedure), E'\r\n', E'\n');
  v_a text := pg_get_functiondef('public._anular_gasto(bigint,text,boolean)'::regprocedure);
  v_r text := pg_get_functiondef('public.guardar_rubro_gasto(jsonb)'::regprocedure);
BEGIN
  IF position('+ 0.01 * v_renglones THEN' in v_g) = 0
     OR position('renglones_factura = v_renglones' in v_g) = 0
     OR position('v_esperado IS NOT NULL AND v_viejo.updated_at IS DISTINCT FROM v_esperado' in v_g) = 0
     OR (length(v_g) - length(replace(v_g, 'v_viejo.updated_at IS DISTINCT FROM v_esperado', '')))
        / length('v_viejo.updated_at IS DISTINCT FROM v_esperado') <> 2
     OR position('7b · GTO-E' in v_g) = 0
     OR position('7b · GTO-E' in v_g) > position('8b · desde Gastos' in v_g) THEN
    RAISE EXCEPTION 'mig NNN · el parche de _guardar_gasto no quedó';
  END IF;
  IF position('PERFORM 1 FROM empleados WHERE id = v_gasto.empleado_id FOR UPDATE' in v_a) = 0
     OR position('v_releido.empleado_id IS DISTINCT FROM v_gasto.empleado_id' in v_a) = 0 THEN
    RAISE EXCEPTION 'mig NNN · el parche de _anular_gasto no quedó';
  END IF;
  IF position('_tiene_todas_las_sucursales()' in v_r) = 0 THEN
    RAISE EXCEPTION 'mig NNN · el parche de guardar_rubro_gasto no quedó';
  END IF;
  IF public._gasto_cuota(0.60, 120, 1) <> 0 OR public._gasto_cuota(0.60, 120, 120) <> 0.60
     OR public._gasto_cuota(20.15, 2, 1) <> 10.08 OR public._gasto_cuota(20.15, 2, 2) <> 10.07 THEN
    RAISE EXCEPTION 'mig NNN · _gasto_cuota no da lo esperado';
  END IF;
  IF NOT public._rubro_es_sueldo('S.A.C.') OR NOT public._rubro_es_sueldo('S-A-C')
     OR NOT public._rubro_es_sueldo('Pago de SAC') OR NOT public._rubro_es_sueldo('Vacaciones del personal')
     OR NOT public._rubro_es_sueldo('Remuneraciones') OR NOT public._rubro_es_sueldo('Comisiones de vendedores')
     OR public._rubro_es_sueldo('Comisiones bancarias') OR public._rubro_es_sueldo('Comisión Posnet')
     OR public._rubro_es_sueldo('Luz, agua y gas') OR public._rubro_es_sueldo('Saco') THEN
    RAISE EXCEPTION 'mig NNN · _rubro_es_sueldo no da lo esperado';
  END IF;
  IF (SELECT pg_get_triggerdef(oid) FROM pg_trigger
       WHERE tgrelid = 'public.gastos'::regclass AND tgname = 'trg_gastos_cuenta_empleado')
     IS DISTINCT FROM 'CREATE TRIGGER trg_gastos_cuenta_empleado AFTER INSERT OR UPDATE OF monto_total, origen_pago, empleado_id, anulado_at, fecha ON public.gastos FOR EACH ROW EXECUTE FUNCTION gastos_cuenta_empleado()' THEN
    RAISE EXCEPTION 'mig NNN · trg_gastos_cuenta_empleado no quedó con la fecha';
  END IF;
  -- Ninguna función nueva ni permiso nuevo: las reemplazadas conservan los suyos.
  IF has_function_privilege('anon', 'public._guardar_gasto(jsonb,boolean)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._guardar_gasto(jsonb,boolean)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.gastos_cuenta_empleado()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._rubro_es_sueldo(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'mig NNN · una función de server quedó con EXECUTE para anon o authenticated';
  END IF;
END
$pos$;

COMMIT;
