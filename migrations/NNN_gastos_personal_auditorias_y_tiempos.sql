-- =========================================================================
-- NNN · GASTOS, PERSONAL, AUDITORÍAS Y DOS LECTORES DE VENTAS SIN NESTED LOOP
--       (plan #1603, ola 2, tanda 5, tarjeta C5)
--
-- Ensayo: scripts/test-gastos-y-auditorias-ola2-1603.sql. Tiempos:
-- scripts/tiempos-ventas-estadisticas-viejas-ola2-1603.sql. Se aplica en LF.
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
-- 3 · SEG-6 (#1545) · siete funciones de gastos y personal tenían el cuerpo
--     con CRLF (las migraciones las fueron parchando respetando el fin de
--     línea). Se recrean con LF: el texto es el MISMO salvo los '\r' (lo
--     prueba la poscondición), con su dueño, sus permisos, SECURITY DEFINER,
--     volatilidad y SET iguales. Todos los '\r' estaban al final de una línea y
--     ninguno dentro de un literal (medido en la 530), así que no cambia ningún
--     mensaje. A las que son SECURITY DEFINER se les suma pg_temp al final del
--     search_path (regla de B15).
-- 4 · 1332-f (#1332) · auditoria_integridad(): tres checks de las roturas a
--     cargo del empleado (gastos 7, mig 450), que se habían dejado para después:
--     ROT-A una rotura viva apunta a una salvedad «A cargo de empleados» o a
--     una merma sin anular; ROT-B una salvedad «A cargo de empleados» tiene al
--     menos una rotura viva; ROT-C la compensación de una rotura es su espejo.
--     Se suman por ancla, sin premisa de md5 (otras tarjetas también le suman
--     checks): el ancla es el cierre de la lista y aparece una vez.
-- 5 · auditoria_fechas_utc(): sacaba los comentarios de línea antes que los
--     literales, así que un literal con '--' escondía el resto de la línea. Usa
--     _sql_sin_comentarios y _sql_sin_comentarios_ni_literales (#1541), como
--     las demás auditorías que leen código.
-- 6 · N8 de la revisión de B22 · _ventas_nc: con estadísticas viejas (el
--     planner cree que pedidos, pedido_items y clientes tienen una fila) armaba
--     nested loops que recorrían esas tablas enteras por cada renglón de nota
--     (3 s con 8.000 boletas y 500 notas). Los joins van ahora por subconsulta
--     (escalar, o LATERAL con OFFSET 0), que siempre es una búsqueda por índice;
--     con estadísticas al día tarda lo mismo (las notas son pocas). El resultado
--     es el mismo fila por fila: cada join era por una PK (o la FK de los
--     renglones de la nota), así que trae la misma fila o ninguna; el filtro de
--     la boleta va dentro del LATERAL, que con CROSS JOIN descarta igual que el
--     JOIN de antes. _tablero_ventas NO se toca: la misma receta, una búsqueda
--     por boleta, la hacía 17 veces más lenta con estadísticas al día (20 → 350
--     ms con 8.000 boletas). Y el resto del tiempo con estadísticas viejas está
--     en los joins de quienes las llaman (pedido_items por boleta), que no son
--     de esta tarjeta: ver el informe de C5.
--
-- SIN DDL DE TABLAS: sólo CREATE OR REPLACE / ALTER FUNCTION, no toma locks de
-- tablas. No cambia firmas ni permisos.
-- =========================================================================

SET LOCAL lock_timeout = '5s';

-- =========================================================================
-- 0 · Premisas: los cuerpos vivos son los de la 530
-- =========================================================================
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public._guardar_gasto(jsonb,boolean)', 'be65ace1cf3f5cd26a72e95c4cb1ecdc'),
    ('public.guardar_empleado(jsonb)', '3765d0525746dbee35083f05d7da631b'),
    ('public._empleado_json(empleados)', 'c2346c3499099cfcbab4b1fde37f6d7a'),
    ('public.listar_personal()', 'db5b90ed607b54779f7a7f80b41311ad'),
    ('public.pagos_cuenta_empleado()', 'f613660dd9309e64debcdc05390ea1a1'),
    ('public._cuenta_empleado_conciliar(text,bigint,bigint,bigint,bigint,bigint,numeric,date,bigint,text)', 'd52526732e94f60e625f36f12347e038'),
    ('public.calcular_comisiones(date,date,bigint[])', '46903c046e900740f4c5ba552044941f'),
    ('public.auditoria_fechas_utc()', 'e1ee6c6cf4fc0736bb386d27fb32c17f'),
    ('public._ventas_nc(bigint[],date,date)', 'a4200429ef13b37b4d55960983a0309c'),
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
                AND prosrc ~ '''ROT-[ABC]''') THEN
    RAISE EXCEPTION 'mig NNN · auditoria_integridad() ya tiene checks ROT-*: revisar a mano';
  END IF;
END
$premisas$;

-- La foto de antes, para la poscondición (dueño, permisos, atributos y texto).
CREATE TEMP TABLE c5_antes ON COMMIT DROP AS
SELECT p.oid, p.oid::regprocedure::text AS firma, p.prosrc,
       p.oid IN ('public.auditoria_fechas_utc()'::regprocedure, 'public.auditoria_integridad()'::regprocedure,
                 'public._ventas_nc(bigint[],date,date)'::regprocedure) AS reescrita, p.proowner, p.proacl, p.prosecdef,
       p.provolatile, p.proparallel, p.proisstrict, p.proleakproof, p.procost, p.prorows,
       p.proconfig, p.prorettype, p.proretset, p.prolang
  FROM pg_proc p
 WHERE p.oid IN ('public._guardar_gasto(jsonb,boolean)'::regprocedure,
                 'public.guardar_empleado(jsonb)'::regprocedure,
                 'public._empleado_json(empleados)'::regprocedure,
                 'public.listar_personal()'::regprocedure,
                 'public.pagos_cuenta_empleado()'::regprocedure,
                 'public._cuenta_empleado_conciliar(text,bigint,bigint,bigint,bigint,bigint,numeric,date,bigint,text)'::regprocedure,
                 'public.calcular_comisiones(date,date,bigint[])'::regprocedure,
                 'public.auditoria_fechas_utc()'::regprocedure,
                 'public.auditoria_integridad()'::regprocedure,
                 'public._ventas_nc(bigint[],date,date)'::regprocedure);

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
-- los '\r'). La poscondición los deshace para comparar con el cuerpo de antes.
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
-- 1, 2 y 3 · Las siete de gastos y personal, en LF (y los dos parches)
-- =========================================================================
DO $lf$
DECLARE
  r record;
  p record;
  v_def text;
BEGIN
  FOR r IN SELECT a.oid, a.firma FROM c5_antes a WHERE NOT a.reescrita ORDER BY a.firma LOOP
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
-- 4 · auditoria_integridad(): los checks de las roturas a cargo del empleado
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
               OR m.revierte_id IS NOT NULL)))$n$ || v_ancla, 'auditoria_integridad');
  EXECUTE v_def;
END
$integridad$;

-- =========================================================================
-- 6 · _ventas_nc: los joins, por índice
-- =========================================================================
CREATE OR REPLACE FUNCTION public._ventas_nc(p_sucs bigint[], p_desde date, p_hasta date)
 RETURNS TABLE(nota_credito_id bigint, fecha date, sucursal_id bigint, pedido_id bigint, cliente_id bigint, zona_id bigint, usuario_id uuid, tipo_factura text, pedido_item_id bigint, producto_id bigint, cantidad integer, monto numeric, iva numeric, ingreso_real numeric, costo_al_crear numeric, cantidad_mercaderia integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT n.id, n.fecha, n.sucursal_id, n.pedido_id, n.cliente_id,
         (SELECT c.zona_id FROM clientes c WHERE c.id = n.cliente_id), pe.usuario_id,
         COALESCE(pe.tipo_factura, 'ZZ')::text, i.pedido_item_id, i.producto_id, i.cantidad,
         i.subtotal,
         i.subtotal * n.iva / n.total,
         -- B22 (#1603): un renglón por monto (cantidad 0) o uno por unidades que
         -- acredita menos que cantidad × precio (la línea tenía un descuento) da el
         -- ingreso real como su plata menos lo que no es ingreso real, al centavo:
         -- en una FC, el neto de la parte (el de _nc_venta_desglose), así que la
         -- suma de la nota da su neto (H6). Los de siempre, como siempre.
         CASE WHEN pi.id IS NOT NULL AND i.subtotal = i.cantidad * pi.precio_unitario
              THEN i.cantidad * COALESCE(pi.ingreso_real_unitario,
                                         CASE WHEN pe.tipo_factura = 'FC'
                                              THEN COALESCE(pi.neto_unitario, pi.precio_unitario)
                                              ELSE pi.precio_unitario END)
              WHEN pi.id IS NOT NULL AND pi.precio_unitario > 0
              THEN i.subtotal
                   - round(i.subtotal * (pi.precio_unitario
                                         - COALESCE(pi.ingreso_real_unitario,
                                                    CASE WHEN pe.tipo_factura = 'FC'
                                                         THEN COALESCE(pi.neto_unitario, pi.precio_unitario)
                                                         ELSE pi.precio_unitario END))
                           / pi.precio_unitario, 2)
              ELSE i.subtotal * CASE WHEN pe.tipo_factura = 'FC' THEN n.neto ELSE n.total END / n.total
         END,
         pi.costo_unitario_al_crear,
         -- B22 v3 (decisión del dueño del 18/11): las unidades que la nota devolvió
         -- de verdad (reingresaron o fueron a merma). Son las que salen del CMV; un
         -- renglón que no movió mercadería da 0.
         CASE WHEN i.lotes_devueltos IS NOT NULL OR i.merma_id IS NOT NULL THEN i.cantidad ELSE 0 END
    FROM notas_credito_venta n
    -- C5 (N8 de #1603): cada join va por subconsulta con OFFSET 0, que el planner
    -- no aplana: es siempre una búsqueda por índice (los renglones por
    -- nota_credito_id, la boleta y la línea por su PK). Trae las mismas filas que
    -- los JOIN de antes; la boleta que no es venta queda afuera igual que con el
    -- JOIN y su WHERE. Con estadísticas viejas los JOIN se planeaban como nested
    -- loops que recorrían pedidos, pedido_items y clientes enteros por cada fila.
    CROSS JOIN LATERAL (SELECT x.pedido_item_id, x.producto_id, x.cantidad, x.subtotal,
                               x.lotes_devueltos, x.merma_id
                          FROM nota_credito_venta_items x
                         WHERE x.nota_credito_id = n.id
                        OFFSET 0) i
    CROSS JOIN LATERAL (SELECT x.usuario_id, x.tipo_factura
                          FROM pedidos x
                         WHERE x.id = n.pedido_id
                           AND x.estado = 'entregado'
                           AND COALESCE(x.canal, 'app') <> 'cambio'
                           AND x.tipo_factura IS DISTINCT FROM 'VB'
                        OFFSET 0) pe
    LEFT JOIN LATERAL (SELECT x.id, x.precio_unitario, x.ingreso_real_unitario, x.neto_unitario,
                              x.costo_unitario_al_crear
                         FROM pedido_items x
                        WHERE x.id = i.pedido_item_id
                       OFFSET 0) pi ON true
   WHERE NOT n.anulada
     AND n.total > 0
     AND n.sucursal_id = ANY(p_sucs)
     AND n.fecha BETWEEN p_desde AND p_hasta
$function$;

-- =========================================================================
-- pg_temp al final del search_path de las SECURITY DEFINER que se recrearon
-- (regla de B15; si B15 ya se aplicó, no hace nada)
-- =========================================================================
DO $pgtemp$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT a.oid FROM c5_antes a JOIN pg_proc p ON p.oid = a.oid
            WHERE p.prosecdef
              AND NOT EXISTS (SELECT 1 FROM unnest(COALESCE(p.proconfig, '{}')) c
                               WHERE c LIKE 'search_path=%' AND c ~ 'pg_temp\s*$') LOOP
    EXECUTE format('ALTER FUNCTION %s SET search_path = public, pg_temp', r.oid::regprocedure);
  END LOOP;
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
       OR v_new.proretset <> a.proretset OR v_new.prolang <> a.prolang THEN
      RAISE EXCEPTION 'mig NNN · % cambió de dueño, permisos o atributos', a.firma;
    END IF;
    -- El SET: el mismo, más pg_temp al final del search_path si es definer.
    IF v_new.proconfig IS DISTINCT FROM a.proconfig
       AND NOT (a.prosecdef AND a.proconfig = ARRAY['search_path=public']
                AND v_new.proconfig = ARRAY['search_path=public, pg_temp']) THEN
      RAISE EXCEPTION 'mig NNN · % quedó con SET %, antes %', a.firma, v_new.proconfig, a.proconfig;
    END IF;
    IF v_new.prosecdef AND NOT EXISTS (SELECT 1 FROM unnest(v_new.proconfig) c
                                        WHERE c LIKE 'search_path=%' AND c ~ 'pg_temp\s*$') THEN
      RAISE EXCEPTION 'mig NNN · % es definer y quedó sin pg_temp', a.firma;
    END IF;
    IF position(E'\r' IN v_new.prosrc) > 0 THEN
      RAISE EXCEPTION 'mig NNN · % sigue con CRLF', a.firma;
    END IF;
    -- El texto: el de antes sin los '\r', con los parches de esta migración.
    IF NOT a.reescrita THEN
      v_esperado := replace(a.prosrc, E'\r', '');
      FOR p IN SELECT * FROM c5_parches WHERE fn = a.oid LOOP
        v_esperado := replace(v_esperado, p.ancla, p.nuevo);
      END LOOP;
      IF v_new.prosrc IS DISTINCT FROM v_esperado THEN
        RAISE EXCEPTION 'mig NNN · % no quedó con el texto de antes sin los CR (y sus parches)', a.firma;
      END IF;
    END IF;
  END LOOP;

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
    (SELECT prosrc FROM pg_proc WHERE oid = 'public.auditoria_integridad()'::regprocedure), '''ROT-[ABC]''', 'g');
  IF v_n <> 3 THEN
    RAISE EXCEPTION 'mig NNN · auditoria_integridad tiene % checks ROT-* (esperados 3)', v_n;
  END IF;
  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public._ventas_nc(bigint[],date,date)'::regprocedure) ~ 'JOIN (pedidos|pedido_items|clientes) ' THEN
    RAISE EXCEPTION 'mig NNN · _ventas_nc sigue con los JOIN de antes';
  END IF;
END
$post$;
