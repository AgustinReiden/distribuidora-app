-- NNN · Limpieza, paso A: nada del server lee clientes.zona, escribe clientes.preventista_id
-- ni lee las tablas viejas de rendiciones (#1336, #1368). Tarjeta 10 de #1389.
--
-- QUÉ PASABA
--   La zona sale de `zonas` por `zona_id` y el preventista de `cliente_preventistas` (#1314):
--   las dos columnas viejas de clientes se dropean. Antes del drop quedaban en el server:
--   - bot_buscar_cliente y bot_mis_clientes devolvían `c.zona`, el texto viejo. Medido el
--     04/11: 128 clientes tienen un texto distinto del nombre de su zona, y el bot les mostraba
--     la zona vieja.
--   - clientes_ritmo_compra caía al texto viejo cuando el cliente no tenía zona_id. Medido el
--     04/11: 1 cliente, inactivo, tiene texto y no tiene zona_id.
--   - _asignar_clientes_a espejaba el dueño en `clientes.preventista_id`.
--   - bot_metricas_admin_dia contaba rendiciones de la tabla vieja `rendiciones` sin control.
--     El sistema viejo no crea filas desde abril: sólo veía la rendición del 15/04, y el digest
--     decía todos los días "Rendiciones sin controlar: 1. La más vieja es de hace 203 días".
--
-- QUÉ CAMBIA
--   - bot_buscar_cliente y bot_mis_clientes: `zona` es el nombre de la zona del cliente, o
--     NULL sin zona. La columna de salida se llama igual: el bot no cambia.
--   - clientes_ritmo_compra: `COALESCE(z.nombre, 'SIN ZONA')`, sin el texto viejo. La lee
--     bot_clientes_atrasados.
--   - _asignar_clientes_a ya no escribe clientes.preventista_id. Nada la lee (front, bot ni
--     server): ModalCliente la cargaba en el formulario y no la usaba.
--   - bot_metricas_admin_dia: `rendiciones_pendientes` es {count: 0, dias_mas_vieja: 0} fijo,
--     y la sección Rendiciones del digest no muestra nada. Rehacerla sobre el sistema nuevo
--     es #1455.
--
-- QUÉ NO CAMBIA
--   Las firmas, los tipos de salida, los EXECUTE y el resto de cada cuerpo. No dropea nada:
--   los drops van en el paso B, cuando ya no lleguen consultas de bundles viejos.
--   Las dos columnas y las tres tablas siguen. Los bundles viejos todavía las escriben, y no
--   rompe nada.
--
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
-- Premisas: nada cambió en prod desde que se leyeron los cuerpos (04/11)
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, md5(p.prosrc) AS md5_vivo
      FROM (VALUES
        ('public._asignar_clientes_a(bigint[],uuid)',                      '419bc85e5161bd8099d3331f45735ce0'),
        ('public.bot_buscar_cliente(text,uuid,text,bigint,integer)',       '734949e9ef885f0dd94997ab3d34e297'),
        ('public.bot_mis_clientes(uuid,bigint,boolean,integer,integer)',   '411039b27c2ec7429e251a391017e3cc'),
        ('public.clientes_ritmo_compra(bigint,text,uuid,uuid,bigint)',     'd99ee9b0d30071d1096df6961249218c'),
        ('public.bot_metricas_admin_dia(date,bigint)',                     '1e19f3e44f6ce740ec07c8b775b5e4af')
      ) AS x(firma, md5)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION 'mig NNN · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer sobre la definición vigente',
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
('public._asignar_clientes_a(bigint[],uuid)', 1,
$a$  UPDATE clientes
     SET preventista_id = p_duenio
   WHERE id = ANY (v_ids)
     AND preventista_id IS DISTINCT FROM p_duenio;

$a$,
''),

('public.bot_buscar_cliente(text,uuid,text,bigint,integer)', 1,
$a$    c.direccion, c.zona, c.sucursal_id
$a$,
$r$    -- #1336: la zona sale de zonas por zona_id; la columna de texto se dropea.
    c.direccion, (SELECT z.nombre FROM zonas z WHERE z.id = c.zona_id) AS zona, c.sucursal_id
$r$),

('public.bot_mis_clientes(uuid,bigint,boolean,integer,integer)', 1,
$a$      c.zona,
$a$,
$r$      -- #1336: la zona sale de zonas por zona_id; la columna de texto se dropea.
      (SELECT z.nombre FROM zonas z WHERE z.id = c.zona_id) AS zona,
$r$),

('public.clientes_ritmo_compra(bigint,text,uuid,uuid,bigint)', 1,
$a$           -- La zona como la muestra la app (reporte_ventas_por_cliente): la de
           -- la tabla zonas, y el texto viejo sólo si no hay zona asignada.
           COALESCE(z.nombre, NULLIF(btrim(c.zona), ''), 'SIN ZONA') AS zona,
$a$,
$r$           -- La zona como la muestra la app (reporte_ventas_por_cliente): la de
           -- la tabla zonas. Sin el texto viejo, que se dropea (#1336).
           COALESCE(z.nombre, 'SIN ZONA') AS zona,
$r$),

('public.bot_metricas_admin_dia(date,bigint)', 1,
$a$  rendiciones_pendientes AS (
    SELECT
      COUNT(*)::int                                              AS count,
      COALESCE(MAX(public._tablero_hoy() - r.fecha), 0)::int              AS dias_mas_vieja
    FROM rendiciones r
    LEFT JOIN rendiciones_control rc
      ON  rc.fecha = r.fecha
      AND rc.transportista_id = r.transportista_id
      AND rc.sucursal_id = r.sucursal_id
    WHERE rc.id IS NULL
      AND r.fecha < public._tablero_hoy() - INTERVAL '2 days'  -- #1250: el día argentino
      AND (p_sucursal_id IS NULL OR r.sucursal_id = p_sucursal_id)
  ),
$a$,
$r$  -- #1368: contaba la tabla vieja `rendiciones`, que se dropea y desde abril sólo tenía la
  -- del 15/04. Queda en 0 hasta que se rehaga sobre el sistema nuevo (#1455).
  rendiciones_pendientes AS (
    SELECT 0::int AS count, 0::int AS dias_mas_vieja
  ),
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
        RAISE EXCEPTION 'mig NNN · % parche %: el ancla aparece % vez/veces y se esperaba %',
          v_f.firma, v_p.orden, v_n, v_p.veces;
      END IF;
      v_def := replace(v_def, v_p.ancla, v_p.reemplazo);
    END LOOP;
    EXECUTE v_def;
  END LOOP;
END
$parches$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos y los EXECUTE quedaron como en el repo, y ninguna función de
-- public lee clientes.zona, escribe clientes.preventista_id ni lee las tablas viejas salvo
-- las dos de rendiciones que dropea el paso B (sin EXECUTE para authenticated desde la 314).
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r       record;
  v_resto text;
BEGIN
  FOR r IN
    SELECT t.firma, t.hash, md5(p.prosrc) AS h, p.proacl::text AS a, p.prosecdef AS def
      FROM (VALUES
        ('public._asignar_clientes_a(bigint[],uuid)',                      '608c2d224294630ea95cec50ca08ea07'),
        ('public.bot_buscar_cliente(text,uuid,text,bigint,integer)',       '1318738018edf75e4d19c8d02d165de8'),
        ('public.bot_mis_clientes(uuid,bigint,boolean,integer,integer)',   'ed5779e0b332bb667eb83e455ecac6e9'),
        ('public.clientes_ritmo_compra(bigint,text,uuid,uuid,bigint)',     'a637f5ac54fa8c6f4fb77908c2124860'),
        ('public.bot_metricas_admin_dia(date,bigint)',                     '71ce6341364a568ef6d67b8a8fedaa3e')
      ) AS t(firma, hash)
      JOIN pg_proc p ON p.oid = t.firma::regprocedure
  LOOP
    IF r.h <> r.hash OR r.a IS DISTINCT FROM '{postgres=X/postgres,service_role=X/postgres}' OR NOT r.def THEN
      RAISE EXCEPTION '% no quedó como en el repo (md5 %, acl %, definer %)', r.firma, r.h, r.a, r.def;
    END IF;
  END LOOP;

  SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v_resto
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.prokind = 'f'
     AND (p.prosrc ~ '\m(c|clientes)\.zona\M(?!_)'
          OR p.prosrc ~* 'update\s+(public\.)?clientes\M[^;]*\mpreventista_id\M'
          OR p.prosrc ~* 'insert\s+into\s+(public\.)?clientes\s*\([^)]*\mpreventista_id\M'
          OR p.prosrc ~ '\m(FROM|JOIN|INTO|UPDATE)\s+(public\.)?rendicion(es|_items|_ajustes)\M')
     AND p.oid NOT IN ('public.crear_rendicion_por_fecha(uuid,date)'::regprocedure,
                       'public.obtener_estadisticas_rendiciones(date,date,uuid)'::regprocedure);
  IF v_resto IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · todavía hay lectores o escritores: %', v_resto;
  END IF;
END
$post$;

COMMIT;
