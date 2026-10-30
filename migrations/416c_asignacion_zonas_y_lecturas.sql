-- ============================================================================
-- 416 · Asignación, zonas y lecturas (#1314, #1315, #1316 · plan #1308, tarjeta 3)
-- ============================================================================
-- Aplicada en prod el 2026-10-29 como 416 (414 y 415 ya estaban tomados en el
-- ledger). Aplicar desde el contenido LF.
--
-- QUÉ ES ESTO
-- -----------
-- #1314 · `clientes.zona` (texto) y `clientes.preventista_id` son copias que no
--   siguen a `zonas.nombre` ni a `cliente_preventistas`: hoy 131 clientes tienen
--   la zona vieja y 46 el preventista de alguien que ya no trabaja. Decisión del
--   dueño (29/10): dejan de leerse y se dropean después, sin trigger de
--   sincronización. La zona sale de `zonas` por `zona_id` y el preventista, de
--   `cliente_preventistas`. Acá dejan de leerlas las cinco funciones de la
--   tarjeta; el drop va aparte, cuando ningún bundle viejo del PWA las pida.
--   No se corrigen los datos: con nadie leyéndolas, no hay qué corregir.
-- #1315 · lecturas que escondían filas:
--   · ASG-1. `tablero_clientes_inactivos` hacía JOIN (inner) a `zonas`, y 272 de
--     807 clientes activos no tienen zona: el tablero dejaba afuera 160 clientes
--     en riesgo. Ahora es LEFT JOIN y la zona sale "(sin zona)".
--   · ASG-6. En `reporte_ventas_por_cliente`, la CTE `vendedores` hacía JOIN a
--     `perfiles`: los pedidos sin `usuario_id` sumaban al total pero no a la
--     lista de vendedores. Ahora va una fila "(sin vendedor)" con id NULL, como
--     la REP-2 de la 410 en `reporte_gerencial`.
-- #1316 · asignación:
--   · ASG-3. La zona manda también en el ALTA y al LIBERAR UN RESERVADO: el
--     trigger de la 359 era sólo `AFTER UPDATE OF zona_id`. Y el preventista sin
--     zonas no puede dar de alta un cliente en la zona de otro
--     (`clientes_alta_en_zona_propia` sólo validaba a los que tienen zonas).
--   · ASG-2. Quien deja de actuar como preventista en una sucursal suelta ahí su
--     cartera y sus zonas, y esos clientes pasan al dueño de su zona (o quedan
--     sin asignar si la zona no tiene dueño). Antes sólo pasaba al desactivarlo,
--     y los clientes volvían al pozo aunque la zona tuviera dueño. Ahora también
--     al cambiarle el rol, al sacarle el rol extra y al sacarlo de la sucursal.
--     La salida de la sucursal se cubre con un trigger sobre `usuario_sucursales`:
--     `desasignar_usuario_sucursal` (tarjeta 1 de #1306) no se toca.
--   · ASG-7 se arregla en el front (la ficha guarda sólo lo que cambió de la
--     asignación); no hay RPC nueva.
--
-- QUÉ SE TOCA
-- -----------
-- Nuevas, sólo de servidor (sin EXECUTE para PUBLIC, anon ni authenticated):
--   · _soltar_cartera(uuid, bigint) ............ suelta cartera y zonas en una sucursal.
--   · clientes_alta_asigna_duenio() ............ trigger AFTER INSERT de clientes.
--   · usuario_sucursales_suelta_cartera() ...... trigger AFTER DELETE/UPDATE.
--   · perfil_roles_suelta_cartera() ............ trigger AFTER DELETE/UPDATE.
-- Reemplazada entera (md5 verificado): soltar_cartera_preventista_inactivo
--   (su trigger pasa a mirar también `rol`).
-- Parcheadas por ancla sobre el cuerpo vivo (md5 verificado): clientes_alta_en_zona_propia,
--   tablero_clientes_inactivos, tablero_ficha_cliente, reporte_ventas_por_cliente,
--   hojas_de_ruta_deposito, reporte_cuentas_por_cobrar.
-- Triggers: trg_clientes_zona_asigna_duenio (también al liberar un reservado),
--   trg_clientes_alta_asigna_duenio (nuevo), trg_soltar_cartera_preventista_inactivo
--   (también por rol), trg_usuario_sucursales_suelta_cartera y
--   trg_perfil_roles_suelta_cartera (nuevos).
-- Ninguna cambia de firma ni de RETURNS: CREATE OR REPLACE conserva dueño,
-- SECURITY DEFINER, search_path y ACL. Las `tablero_*` las consume el tablero
-- externo: devuelven las mismas claves.
-- No se toca: asignar_usuario_sucursal, desasignar_usuario_sucursal, las policies
-- cp_* (tarjeta 1 de #1306), cliente_preventistas_no_ajeno, _asignar_clientes_a,
-- _duenio_zona ni auditoria_integridad().
--
-- Ensayo: scripts/test-asignacion-zonas-lecturas-1314-1316.sql (falla antes,
-- pasa después).
-- ============================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'mig 416 · el texto de la migración trae CRLF: aplicarla desde la versión LF (git show HEAD:migrations/<archivo>)';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- 0 · Premisas
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_f record;
BEGIN
  -- Lo que se reemplaza o se parchea, y lo que se llama sin tocar. Leído en prod
  -- el 2026-10-29, después de la 413.
  FOR v_f IN
    SELECT x.firma, x.md5, md5(pg_get_functiondef(x.firma::regprocedure)) AS md5_vivo
      FROM (VALUES
        ('public.soltar_cartera_preventista_inactivo()',                      '27d2f33a5991168a42cc76226c521c2a'),
        ('public.clientes_alta_en_zona_propia()',                             '69ce139b0a25ebff2d809dddd77379cd'),
        ('public.tablero_clientes_inactivos(bigint,integer,boolean)',         'f027fa05227e11f855de4979cf17563b'),
        ('public.tablero_ficha_cliente(bigint)',                              'eed19069a5be00def9495fb146dc983a'),
        ('public.reporte_ventas_por_cliente(date,date,uuid,bigint)',          '3aeb9407c56c5e9ddf8856a496576710'),
        ('public.hojas_de_ruta_deposito(date)',                               '84b657a0426640e0bdb465a3d9528597'),
        ('public.reporte_cuentas_por_cobrar(bigint)',                         'a77107478e2dbe4f2e3a2b8248241bc0'),
        ('public.clientes_zona_asigna_duenio()',                              '00384972cb011060a398f561fa6145cc'),
        ('public._asignar_clientes_a(bigint[],uuid)',                         '56205c75a831ecda7b6408a6260169cf'),
        ('public._duenio_zona(bigint)',                                       '863df80af6a4dff93ae35e3ef0e060cc'),
        ('public._actua_como_preventista(uuid,bigint)',                       '966aa0da9ec5e572f19462855ab50627'),
        ('public.soltar_zonas_preventista()',                                 '327ad406ab8a6dc933a0511d8090f343')
      ) AS x(firma, md5)
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION 'mig 416 · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer los parches sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;

  -- Los triggers que se recrean están como se leyeron.
  IF (SELECT pg_get_triggerdef(t.oid) FROM pg_trigger t
       WHERE t.tgrelid = 'public.clientes'::regclass AND t.tgname = 'trg_clientes_zona_asigna_duenio')
     IS DISTINCT FROM
     'CREATE TRIGGER trg_clientes_zona_asigna_duenio AFTER UPDATE OF zona_id ON public.clientes FOR EACH ROW WHEN (((old.zona_id IS DISTINCT FROM new.zona_id) AND (new.zona_id IS NOT NULL) AND (NOT new.reservado_admin))) EXECUTE FUNCTION clientes_zona_asigna_duenio()'
  THEN
    RAISE EXCEPTION 'mig 416 · trg_clientes_zona_asigna_duenio no es el de la 359';
  END IF;
  IF (SELECT pg_get_triggerdef(t.oid) FROM pg_trigger t
       WHERE t.tgrelid = 'public.perfiles'::regclass AND t.tgname = 'trg_soltar_cartera_preventista_inactivo')
     IS DISTINCT FROM
     'CREATE TRIGGER trg_soltar_cartera_preventista_inactivo AFTER UPDATE OF activo ON public.perfiles FOR EACH ROW WHEN (((old.activo IS DISTINCT FROM new.activo) AND (new.activo = false))) EXECUTE FUNCTION soltar_cartera_preventista_inactivo()'
  THEN
    RAISE EXCEPTION 'mig 416 · trg_soltar_cartera_preventista_inactivo no es el de la 264';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_trigger t
              WHERE NOT t.tgisinternal
                AND t.tgrelid IN ('public.usuario_sucursales'::regclass, 'public.perfil_roles'::regclass)) THEN
    RAISE EXCEPTION 'mig 416 · usuario_sucursales o perfil_roles ya tienen triggers: revisar antes de sumar los de la cartera';
  END IF;
END
$premisas$;

-- Patch por ancla sobre la definición viva: cada ancla tiene que aparecer
-- exactamente una vez (después de aplicar las anteriores) o aborta.
CREATE FUNCTION pg_temp._parchear(p_firma text, p_pares text[])
RETURNS void
LANGUAGE plpgsql AS $f$
DECLARE
  v_def text := pg_get_functiondef(p_firma::regprocedure);
  v_n   int;
BEGIN
  FOR i IN 1 .. array_length(p_pares, 1) BY 2 LOOP
    v_n := (length(v_def) - length(replace(v_def, p_pares[i], ''))) / length(p_pares[i]);
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'mig 416 · el ancla % de % aparece % veces', (i + 1) / 2, p_firma, v_n;
    END IF;
    v_def := replace(v_def, p_pares[i], p_pares[i + 1]);
  END LOOP;
  EXECUTE v_def;
END
$f$;

CREATE TEMP TABLE _m416_acl ON COMMIT DROP AS
SELECT p.oid, p.proacl::text AS acl, p.prosecdef
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname IN ('soltar_cartera_preventista_inactivo', 'clientes_alta_en_zona_propia',
                     'tablero_clientes_inactivos', 'tablero_ficha_cliente',
                     'reporte_ventas_por_cliente', 'hojas_de_ruta_deposito',
                     'reporte_cuentas_por_cobrar');

-- ---------------------------------------------------------------------------
-- 1 · #1316 ASG-2 · soltar la cartera en una sucursal
-- ---------------------------------------------------------------------------
-- Saca a p_usuario de las zonas y de la cartera de la sucursal p_sucursal. Cada
-- cliente que se queda sin ningún preventista pasa al dueño de su zona; si la
-- zona no tiene dueño (o era de p_usuario), queda sin asignar: visible para
-- todos los preventistas, el default seguro de la 264. Un cliente que además lo
-- atiende otro conserva a ese otro: soltar no es linkear la zona.
-- Las zonas se borran primero, así _duenio_zona ya no lo devuelve a él.
CREATE FUNCTION public._soltar_cartera(p_usuario uuid, p_sucursal bigint)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_soltados bigint[];
  r          record;
BEGIN
  DELETE FROM preventista_zonas
   WHERE perfil_id = p_usuario AND sucursal_id = p_sucursal;

  WITH borradas AS (
    DELETE FROM cliente_preventistas cp
     USING clientes c
     WHERE c.id = cp.cliente_id
       AND cp.preventista_id = p_usuario
       AND c.sucursal_id = p_sucursal
    RETURNING cp.cliente_id
  )
  SELECT array_agg(cliente_id) INTO v_soltados FROM borradas;

  IF v_soltados IS NULL THEN
    RETURN 0;
  END IF;

  FOR r IN
    SELECT _duenio_zona(c.zona_id) AS duenio, array_agg(c.id) AS ids
      FROM clientes c
     WHERE c.id = ANY (v_soltados)
       AND c.zona_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id)
     GROUP BY 1
  LOOP
    IF r.duenio IS NOT NULL THEN
      PERFORM _asignar_clientes_a(r.ids, r.duenio);
    END IF;
  END LOOP;

  RETURN cardinality(v_soltados);
END;
$$;

REVOKE ALL ON FUNCTION public._soltar_cartera(uuid, bigint) FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public._soltar_cartera(uuid, bigint) IS
'#1316. Saca a p_usuario de las zonas y la cartera de la sucursal p_sucursal; los clientes '
'que quedan sin preventista pasan al dueño de su zona (o quedan sin asignar). La llaman los '
'triggers de perfiles, perfil_roles y usuario_sucursales. Sólo de servidor.';

-- 1a · perfiles: al desactivarlo (como en la 264) y al cambiarle el rol. Se
-- suelta en cada sucursal donde tiene cartera o zonas: todas si se desactiva,
-- y si cambió el rol, las que ya no atiende como preventista (con el rol extra
-- de una sucursal la sigue atendiendo ahí).
CREATE OR REPLACE FUNCTION public.soltar_cartera_preventista_inactivo()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_suc bigint;
BEGIN
  FOR v_suc IN
    SELECT c.sucursal_id
      FROM cliente_preventistas cp JOIN clientes c ON c.id = cp.cliente_id
     WHERE cp.preventista_id = NEW.id
    UNION
    SELECT pz.sucursal_id FROM preventista_zonas pz WHERE pz.perfil_id = NEW.id
  LOOP
    IF NOT COALESCE(NEW.activo, true)
       OR NOT _actua_como_preventista(NEW.id, v_suc) THEN
      PERFORM _soltar_cartera(NEW.id, v_suc);
    END IF;
  END LOOP;
  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.soltar_cartera_preventista_inactivo() FROM PUBLIC, anon, authenticated;

DROP TRIGGER trg_soltar_cartera_preventista_inactivo ON public.perfiles;
CREATE TRIGGER trg_soltar_cartera_preventista_inactivo
  AFTER UPDATE OF activo, rol ON public.perfiles
  FOR EACH ROW
  WHEN ((OLD.activo IS DISTINCT FROM NEW.activo AND NEW.activo = false)
        OR OLD.rol IS DISTINCT FROM NEW.rol)
  EXECUTE FUNCTION public.soltar_cartera_preventista_inactivo();

-- 1b · usuario_sucursales: salir de la sucursal (DELETE, como hace
-- desasignar_usuario_sucursal) o mover la fila a otro usuario o sucursal. El
-- UPDATE de asignar_usuario_sucursal sólo cambia `rol` y `es_default`, que no
-- sacan a nadie de la sucursal: no dispara.
CREATE FUNCTION public.usuario_sucursales_suelta_cartera()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  PERFORM _soltar_cartera(OLD.usuario_id, OLD.sucursal_id);
  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.usuario_sucursales_suelta_cartera() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_usuario_sucursales_suelta_cartera
  AFTER DELETE ON public.usuario_sucursales
  FOR EACH ROW
  EXECUTE FUNCTION public.usuario_sucursales_suelta_cartera();

CREATE TRIGGER trg_usuario_sucursales_mueve_cartera
  AFTER UPDATE OF usuario_id, sucursal_id ON public.usuario_sucursales
  FOR EACH ROW
  WHEN (OLD.usuario_id IS DISTINCT FROM NEW.usuario_id OR OLD.sucursal_id IS DISTINCT FROM NEW.sucursal_id)
  EXECUTE FUNCTION public.usuario_sucursales_suelta_cartera();

-- 1c · perfil_roles: sacarle (o cambiarle) el rol extra preventista de una
-- sucursal. Hoy el CHECK sólo admite 'transportista', así que no dispara nunca;
-- queda para el día que se amplíe (ver el COMMENT de perfil_roles_rol_check).
CREATE FUNCTION public.perfil_roles_suelta_cartera()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF OLD.rol = 'preventista'
     AND NOT _actua_como_preventista(OLD.usuario_id, OLD.sucursal_id) THEN
    PERFORM _soltar_cartera(OLD.usuario_id, OLD.sucursal_id);
  END IF;
  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.perfil_roles_suelta_cartera() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_perfil_roles_suelta_cartera
  AFTER DELETE OR UPDATE ON public.perfil_roles
  FOR EACH ROW
  EXECUTE FUNCTION public.perfil_roles_suelta_cartera();

-- ---------------------------------------------------------------------------
-- 2 · #1316 ASG-3 · la zona manda en el alta y al liberar un reservado
-- ---------------------------------------------------------------------------
-- Liberar un reservado (reservado_admin true → false) cuenta como entrar a la
-- zona. La función de la 359 sirve igual: lee NEW.
DROP TRIGGER trg_clientes_zona_asigna_duenio ON public.clientes;
CREATE TRIGGER trg_clientes_zona_asigna_duenio
  AFTER UPDATE OF zona_id, reservado_admin ON public.clientes
  FOR EACH ROW
  WHEN ((OLD.zona_id IS DISTINCT FROM NEW.zona_id
         OR (OLD.reservado_admin AND NOT NEW.reservado_admin))
        AND NEW.zona_id IS NOT NULL
        AND NOT NEW.reservado_admin)
  EXECUTE FUNCTION public.clientes_zona_asigna_duenio();

-- El alta. El preventista dueño que da de alta en su zona se asigna desde la
-- app, después del INSERT: si el trigger ya lo hubiera puesto, el INSERT de un
-- bundle viejo del PWA (que no usa ON CONFLICT) daría 23505 y el alta se vería
-- fallada. Por eso el trigger se saltea al dueño cuando es el que da de alta.
CREATE FUNCTION public.clientes_alta_asigna_duenio()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_duenio uuid;
BEGIN
  v_duenio := _duenio_zona(NEW.zona_id);
  IF v_duenio IS NOT NULL AND v_duenio IS DISTINCT FROM auth.uid() THEN
    PERFORM _asignar_clientes_a(ARRAY[NEW.id], v_duenio);
  END IF;
  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.clientes_alta_asigna_duenio() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_clientes_alta_asigna_duenio
  AFTER INSERT ON public.clientes
  FOR EACH ROW
  WHEN (NEW.zona_id IS NOT NULL AND NOT NEW.reservado_admin)
  EXECUTE FUNCTION public.clientes_alta_asigna_duenio();

-- El preventista sin zonas tampoco da de alta en la zona de otro: el cliente
-- sería del dueño y él no lo podría operar. Se mira preventista_zonas sin pasar
-- por _duenio_zona (la función es INVOKER y authenticated no ejecuta helpers
-- de servidor); la policy de SELECT le deja ver las zonas de su sucursal, que
-- es la del cliente (mt_clientes_insert).
SELECT pg_temp._parchear('public.clientes_alta_en_zona_propia()', ARRAY[
$a$  -- Sin zonas en esta sucursal: como siempre.
$a$,
$b$  -- Una zona con dueño es de su dueño (#1316): ni siquiera el preventista sin
  -- zonas da de alta ahí.
  IF NEW.zona_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM preventista_zonas pz
     WHERE pz.zona_id = NEW.zona_id AND pz.perfil_id <> auth.uid()
  ) THEN
    RAISE EXCEPTION 'La zona % la atiende otro preventista: elegí otra zona o pedile el alta a un administrador',
      (SELECT z.nombre FROM zonas z WHERE z.id = NEW.zona_id)
      USING ERRCODE = '42501';
  END IF;

  -- Sin zonas en esta sucursal: como siempre.
$b$]);

-- ---------------------------------------------------------------------------
-- 3 · #1315 y #1314 · las lecturas
-- ---------------------------------------------------------------------------
-- El preventista de un cliente es su fila de cliente_preventistas (hoy hay a lo
-- sumo una por cliente; con varias, la más vieja). Sin fila, el dueño de la
-- zona, como ya hacían los tableros.
SELECT pg_temp._parchear('public.tablero_clientes_inactivos(bigint,integer,boolean)', ARRAY[
$a$c.zona_id, z.nombre AS zona, c.sucursal_id$a$,
$b$c.zona_id, COALESCE(z.nombre, '(sin zona)') AS zona, c.sucursal_id$b$,
$a$           COALESCE(c.preventista_id, pz.perfil_id) AS preventista_id,$a$,
$b$           COALESCE(pc.id, pz.perfil_id) AS preventista_id,$b$,
$a$      JOIN zonas z ON z.id = c.zona_id$a$,
$b$      LEFT JOIN zonas z ON z.id = c.zona_id$b$,
$a$      LEFT JOIN perfiles pc ON pc.id = c.preventista_id$a$,
$b$      LEFT JOIN LATERAL (
        SELECT pf.id, pf.nombre
          FROM cliente_preventistas cp JOIN perfiles pf ON pf.id = cp.preventista_id
         WHERE cp.cliente_id = c.id
         ORDER BY cp.creado_en, cp.preventista_id
         LIMIT 1
      ) pc ON true$b$]);

SELECT pg_temp._parchear('public.tablero_ficha_cliente(bigint)', ARRAY[
$a$      LEFT JOIN perfiles pc ON pc.id = c.preventista_id$a$,
$b$      LEFT JOIN LATERAL (
        SELECT pf.nombre
          FROM cliente_preventistas cp JOIN perfiles pf ON pf.id = cp.preventista_id
         WHERE cp.cliente_id = c.id
         ORDER BY cp.creado_en, cp.preventista_id
         LIMIT 1
      ) pc ON true$b$]);

SELECT pg_temp._parchear('public.reporte_ventas_por_cliente(date,date,uuid,bigint)', ARRAY[
$a$           COALESCE(NULLIF(btrim(per.nombre), ''), '(sin nombre)') AS nombre,$a$,
$b$           CASE WHEN v.usuario_id IS NULL THEN '(sin vendedor)'  -- #1315 (ASG-6)
                ELSE COALESCE(NULLIF(btrim(per.nombre), ''), '(sin nombre)') END AS nombre,$b$,
$a$    JOIN perfiles per ON per.id = v.usuario_id$a$,
$b$    LEFT JOIN perfiles per ON per.id = v.usuario_id$b$,
$a$      COALESCE(z.nombre, NULLIF(btrim(c.zona), ''), 'SIN ZONA') AS zona$a$,
$b$      COALESCE(z.nombre, 'SIN ZONA') AS zona$b$]);

SELECT pg_temp._parchear('public.hojas_de_ruta_deposito(date)', ARRAY[
$a$                        'zona', c.zona,$a$,
$b$                        'zona', (SELECT z.nombre FROM public.zonas z WHERE z.id = c.zona_id),$b$]);

SELECT pg_temp._parchear('public.reporte_cuentas_por_cobrar(bigint)', ARRAY[
$a$           c.nombre_fantasia, c.razon_social, c.zona, c.cuit, c.telefono,$a$,
$b$           c.nombre_fantasia, c.razon_social, z.nombre AS zona, c.cuit, c.telefono,$b$,
$a$    JOIN clientes c ON c.id = pc.cliente_id$a$,
$b$    JOIN clientes c ON c.id = pc.cliente_id
    LEFT JOIN zonas z ON z.id = c.zona_id$b$]);

-- ---------------------------------------------------------------------------
-- 4 · Verificación
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  v_f    text;
  v_def  text;
BEGIN
  -- Nada que ya existía cambió de dueño, SECURITY DEFINER ni ACL.
  IF EXISTS (SELECT 1 FROM _m416_acl a JOIN pg_proc p ON p.oid = a.oid
              WHERE p.proacl::text IS DISTINCT FROM a.acl OR p.prosecdef <> a.prosecdef) THEN
    RAISE EXCEPTION 'mig 416 · una función parcheada cambió de ACL o de SECURITY DEFINER';
  END IF;
  IF (SELECT count(*) FROM _m416_acl) <> 7 THEN
    RAISE EXCEPTION 'mig 416 · se esperaban 7 funciones existentes, hay %', (SELECT count(*) FROM _m416_acl);
  END IF;

  -- Las nuevas y los triggers: sin EXECUTE para la app.
  FOREACH v_f IN ARRAY ARRAY[
    'public._soltar_cartera(uuid,bigint)',
    'public.soltar_cartera_preventista_inactivo()',
    'public.usuario_sucursales_suelta_cartera()',
    'public.perfil_roles_suelta_cartera()',
    'public.clientes_alta_asigna_duenio()',
    'public.clientes_alta_en_zona_propia()'
  ] LOOP
    IF has_function_privilege('anon', v_f, 'EXECUTE')
       OR has_function_privilege('authenticated', v_f, 'EXECUTE') THEN
      RAISE EXCEPTION 'mig 416 · % quedó ejecutable por la app', v_f;
    END IF;
  END LOOP;

  -- Ninguna de las cinco lecturas lee las columnas legadas.
  FOREACH v_f IN ARRAY ARRAY[
    'public.tablero_clientes_inactivos(bigint,integer,boolean)',
    'public.tablero_ficha_cliente(bigint)',
    'public.reporte_ventas_por_cliente(date,date,uuid,bigint)',
    'public.hojas_de_ruta_deposito(date)',
    'public.reporte_cuentas_por_cobrar(bigint)'
  ] LOOP
    v_def := pg_get_functiondef(v_f::regprocedure);
    -- \m: `vc.preventista_id` (visitas_cliente, en la ficha) no es la columna.
    IF v_def ~ '\mc\.zona\M' OR v_def ~ '\mc\.preventista_id' THEN
      RAISE EXCEPTION 'mig 416 · % sigue leyendo clientes.zona o clientes.preventista_id', v_f;
    END IF;
  END LOOP;
END
$verif$;

COMMIT;
