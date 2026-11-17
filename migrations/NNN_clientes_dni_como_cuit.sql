-- =========================================================================
-- NNN · LOS DNI DE CLIENTES CARGADOS COMO CUIT
--       (tarjeta B17 de la ola 2 del plan #1603; punto 1561-b11 de #1561,
--        decisión del dueño del 16/11: «Sí, corregilos» y «Sí, sin documento»)
--
-- Migración de DATOS sobre `clientes`, con su freno. Se aplica sólo con el OK
-- explícito del dueño, después de medir prod con las consultas de sólo lectura de
-- la tarjeta. Ensayo: scripts/test-clientes-dni-ola2-1603.sql. Se aplica en LF.
--
-- Qué pasó. `clientes.cuit` guarda el CUIT (`XX-XXXXXXXX-X`) o un DNI en el
-- formato de almacenamiento de la app (`00-XXXXXXXX-0`, `dniToStorageFormat`), y
-- `clientes.tipo_documento` dice cuál es. Dos defectos del front:
--   · el tipo nunca llegó a la base: ni el alta (`createCliente` nombra sus
--     columnas una por una) ni la edición (el patch de ClientesContainer) lo
--     mandaban, así que todo cliente quedó con el default 'CUIT';
--   · el campo nace en CUIT y hasta el 16/11 exigía 11 dígitos: un DNI se cargaba
--     rellenado con ceros a la izquierda (`000` + el DNI de 8, `0000` + el de 7) y
--     el campo lo partía como CUIT: `00-0NNNNNNN-D`, el DNI en los últimos 8.
--     Y elegir DNI y dejarlo vacío guardaba el relleno `00-00000000-0`.
--
-- Los grupos (por los dígitos del valor; medidos en prod el 16/11):
--   dni_relleno_11          `00-0NNNNNNN-D`, D ≠ 0     118 · DNI = los últimos 8 dígitos
--   ambiguo                 `00-0NNNNNNN-0`             14 · ver la regla abajo
--   formato_almacenamiento  `00-NNNNNNNN-0`, N1 ≠ 0      2 · ya es el formato: sólo el tipo
--   relleno_ceros           `00-00000000-0`             18 · sin documento: `cuit` NULL
--   cuit                    11 dígitos, no empieza con 00  2 · no se toca
-- Los corregidos quedan con `tipo_documento = 'DNI'` y `cuit = '00-' || DNI de 8 || '-0'`
-- (el relleno, con `cuit` NULL y el tipo en su default). Activos e inactivos por
-- igual: el historial los sigue mostrando, y el CHECK de abajo vale para todos.
--
-- Los 14 ambiguos. `00-0NNNNNNN-0` es a la vez un DNI de 8 que termina en 0 con el
-- relleno de arriba y el formato de almacenamiento de un DNI de 7. La regla es
-- 'ultimos_8' (el DNI son los últimos 8 dígitos, como los 118): los 118 tienen el
-- último dígito del 1 al 9, así que con la misma carga se esperan 118/9 ≈ 13 que
-- terminen en 0, y son 14; por el selector de DNI entraron sólo 2 DNI de 8 (el
-- tercer grupo), y uno de 7 es mucho menos común que uno de 8. Además, un DNI de 7
-- cargado con el relleno de 11 también termina en los últimos 8, así que esta regla
-- lo lee bien en los dos casos. La otra lectura ('almacenamiento': el valor ya es el
-- formato de un DNI de 7, sólo cambia el tipo) queda en el parámetro de la corrección
-- (`v_regla` de la sección 3), para el caso de que el dueño la elija.
--
-- Qué dispara el UPDATE de `clientes` (SET cuit, tipo_documento, como postgres):
--   · audit_clientes (AFTER, cada fila): una fila en audit_logs por cliente
--     corregido, con campos_modificados {cuit, tipo_documento} y usuario NULL. Se deja
--     a propósito: es el rastro del cambio en el historial del cliente (audit_logs es
--     evidencia), y son ~150 filas;
--   · trg_clientes_proteger_columnas, _reservado_solo_admin, _saldo_y_credito_solo_admin
--     y _vb_solo_admin (BEFORE): salen al instante, porque current_user no es
--     authenticated;
--   · NO dispara trg_clientes_zona_asigna_duenio (OF zona_id, reservado_admin), ni
--     trg_clientes_reservado_limpia_asignaciones (OF reservado_admin), ni
--     trg_clientes_comodin_solo_admin (OF es_comodin): no reasigna clientes ni toca
--     cliente_preventistas, y `clientes` no tiene triggers que muevan saldos.
--   La premisa de esquema aborta si los triggers de `clientes` no son esos diez.
--
-- El freno:
--   · `trg_clientes_tipo_documento_del_valor` (BEFORE INSERT OR UPDATE OF cuit,
--     tipo_documento): el tipo sale del valor. `00-XXXXXXXX-0` es DNI y lo demás es
--     CUIT (ningún CUIT empieza con 00), y el relleno `00-00000000-0` queda NULL. Así
--     un bundle viejo del PWA, que no manda el tipo, guarda bien y no recibe un error;
--   · el CHECK `clientes_documento_con_su_tipo`: un valor cuyos dígitos empiezan con
--     00 es el formato de almacenamiento de un DNI, distinto del relleno, y va con tipo
--     DNI; cualquier otro valor no va con tipo DNI. Lo único que todavía lo puede
--     violar es un valor con forma rara que empiece con 00 (un DNI rellenado a 11 que
--     el front viejo dejara pasar): el front lo traduce (`errorDeSupabase`).
--   Espejo en el front: `tipoDocumentoDelValor` (src/utils/documentoCliente.ts).
--
-- Respaldo: `clientes_documento_respaldo` (sólo de server: RLS sin policies y sin
-- grants) guarda el valor y el tipo de antes y de después de cada fila tocada. El
-- guion para deshacer va aparte, con el informe de la tarjeta.
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

-- El CHECK y el trigger nuevos toman ACCESS EXCLUSIVE sobre clientes. Un solo lock,
-- al principio y sin esperar: o lo consigue ya, o falla en el acto sin haber
-- bloqueado nada y se reintenta. Con la tabla tomada, nadie carga un cliente entre la
-- premisa y el UPDATE.
LOCK TABLE public.clientes IN ACCESS EXCLUSIVE MODE NOWAIT;

-- ---------------------------------------------------------------------------
-- Premisa de esquema
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_trg text;
BEGIN
  IF to_regclass('public.clientes_documento_respaldo') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · clientes_documento_respaldo ya existe: revisar a mano';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint
              WHERE conrelid = 'public.clientes'::regclass AND conname = 'clientes_documento_con_su_tipo') THEN
    RAISE EXCEPTION 'mig NNN · clientes_documento_con_su_tipo ya existe: revisar a mano';
  END IF;
  IF to_regprocedure('public.clientes_tipo_documento_del_valor()') IS NOT NULL
     OR to_regprocedure('public._clientes_dni_como_cuit_corregir(text, jsonb)') IS NOT NULL
     OR to_regprocedure('public._clientes_documento_grupos(text)') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · las funciones de la corrección ya existen: revisar a mano';
  END IF;

  IF (SELECT format_type(atttypid, atttypmod) FROM pg_attribute
       WHERE attrelid = 'public.clientes'::regclass AND attname = 'cuit' AND NOT attisdropped)
       IS DISTINCT FROM 'character varying(13)'
     OR (SELECT format_type(atttypid, atttypmod) FROM pg_attribute
          WHERE attrelid = 'public.clientes'::regclass AND attname = 'tipo_documento' AND NOT attisdropped)
       IS DISTINCT FROM 'character varying(4)' THEN
    RAISE EXCEPTION 'mig NNN · clientes.cuit o clientes.tipo_documento no son varchar(13) / varchar(4): revisar a mano';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.clientes'::regclass AND conname = 'clientes_tipo_documento_check') THEN
    RAISE EXCEPTION 'mig NNN · falta clientes_tipo_documento_check (CUIT o DNI): revisar a mano';
  END IF;

  -- Lo que dispara el UPDATE de clientes es lo que se leyó (arriba). Un trigger nuevo
  -- puede hacer algo con ~150 filas que nadie miró.
  SELECT string_agg(tgname, ', ' ORDER BY tgname) INTO v_trg
    FROM pg_trigger WHERE tgrelid = 'public.clientes'::regclass AND NOT tgisinternal;
  IF v_trg IS DISTINCT FROM
     'audit_clientes, trg_clientes_alta_asigna_duenio, trg_clientes_alta_en_zona_propia, '
     'trg_clientes_comodin_solo_admin, trg_clientes_proteger_columnas, '
     'trg_clientes_reservado_limpia_asignaciones, trg_clientes_reservado_solo_admin, '
     'trg_clientes_saldo_y_credito_solo_admin, trg_clientes_vb_solo_admin, '
     'trg_clientes_zona_asigna_duenio' THEN
    RAISE EXCEPTION 'mig NNN · los triggers de clientes no son los que se leyeron el 17/11 (%): mirar qué dispara un UPDATE de cuit antes de aplicar', v_trg;
  END IF;
END
$premisas$;

-- =========================================================================
-- 1 · El respaldo (sólo de server)
-- =========================================================================
CREATE TABLE public.clientes_documento_respaldo (
  cliente_id              bigint       NOT NULL PRIMARY KEY,
  sucursal_id             bigint       NOT NULL,
  grupo                   text         NOT NULL
    CONSTRAINT clientes_documento_respaldo_grupo_check
    CHECK (grupo IN ('dni_relleno_11', 'ambiguo', 'formato_almacenamiento', 'relleno_ceros')),
  -- La lectura de los ambiguos con la que se corrigió (NULL en los otros grupos).
  regla_ambiguos          text
    CONSTRAINT clientes_documento_respaldo_regla_check
    CHECK (regla_ambiguos IN ('ultimos_8', 'almacenamiento')),
  activo                  boolean      NOT NULL,
  cuit_anterior           varchar(13),
  tipo_documento_anterior varchar(4),
  cuit_nuevo              varchar(13),
  tipo_documento_nuevo    varchar(4),
  corregido_en            timestamptz  NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.clientes_documento_respaldo IS
  'B17 (#1561, 1561-b11): el documento de cada cliente que corrigió la migración de los DNI cargados como CUIT, antes y después, para poder deshacerla. Sólo de server: RLS sin policies y sin grants (es dato de clientes). La escribe _clientes_dni_como_cuit_corregir.';

ALTER TABLE public.clientes_documento_respaldo ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.clientes_documento_respaldo FROM PUBLIC, anon, authenticated;


-- =========================================================================
-- 2 · La corrección
-- =========================================================================
-- Cada cliente con documento, con su grupo y, si se corrige, el valor y el tipo
-- nuevos. Por los dígitos del valor, así un guion o un espacio de más no lo saca de
-- su grupo. Lee activos e inactivos a propósito. Sólo de server.
--   'ultimos_8': el DNI son los últimos 8 de los 11 dígitos (el relleno con ceros a
--   la izquierda); 'almacenamiento': los 8 del medio de 00-XXXXXXXX-0.
-- Un `00-XXXXXXXX-0` que ya tiene tipo DNI no es ambiguo: el tipo lo puso alguien
-- (el front nuevo, el trigger o esta misma corrección), y se lee como está. Por eso
-- volver a correrla no toca nada.
CREATE FUNCTION public._clientes_documento_grupos(p_regla_ambiguos text)
 RETURNS TABLE (id bigint, sucursal_id bigint, activo boolean, cuit varchar(13), tipo_documento varchar(4),
                grupo text, cuit_nuevo varchar(13), tipo_nuevo varchar(4))
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT y.id, y.sucursal_id, y.activo, y.cuit, y.tipo_documento, y.grupo,
         ('00-' || CASE y.grupo
                     WHEN 'dni_relleno_11' THEN y.ult8
                     WHEN 'ambiguo' THEN CASE WHEN p_regla_ambiguos = 'ultimos_8' THEN y.ult8 ELSE y.alm8 END
                     WHEN 'formato_almacenamiento' THEN y.alm8
                   END || '-0')::varchar(13),
         CASE WHEN y.grupo = 'relleno_ceros' THEN 'CUIT'
              WHEN y.grupo IN ('dni_relleno_11', 'ambiguo', 'formato_almacenamiento') THEN 'DNI'
         END::varchar(4)
    FROM (
      SELECT z.*,
             CASE
               WHEN z.d = '' THEN 'vacio'
               WHEN z.d ~ '^0{11}$' THEN 'relleno_ceros'
               -- Un DNI tiene al menos 7 cifras: un número más chico es otra cosa y va
               -- a mano (cae en otro_00, que aborta).
               WHEN z.d ~ '^000[0-9]{7}[1-9]$' AND ltrim(z.ult8, '0') ~ '^[0-9]{7,8}$' THEN 'dni_relleno_11'
               WHEN z.d ~ '^00[0-9]{8}0$' AND z.tipo_documento = 'DNI' AND ltrim(z.alm8, '0') ~ '^[0-9]{7,8}$'
                 THEN 'formato_almacenamiento'
               WHEN z.d ~ '^000[0-9]{7}0$'
                    AND ltrim(CASE WHEN p_regla_ambiguos = 'ultimos_8' THEN z.ult8 ELSE z.alm8 END, '0')
                        ~ '^[0-9]{7,8}$' THEN 'ambiguo'
               WHEN z.d ~ '^00[1-9][0-9]{7}0$' THEN 'formato_almacenamiento'
               WHEN z.d LIKE '00%' THEN 'otro_00'
               WHEN z.d ~ '^[0-9]{11}$' THEN 'cuit'
               ELSE 'otro'
             END AS grupo
        FROM (SELECT c.id, c.sucursal_id, c.activo, c.cuit, c.tipo_documento, d.d,
                     substr(d.d, 4, 8) AS ult8, substr(d.d, 3, 8) AS alm8
                FROM public.clientes c
               CROSS JOIN LATERAL (SELECT regexp_replace(c.cuit, '[^0-9]', '', 'g') AS d) d
               WHERE c.cuit IS NOT NULL) z
    ) y;
$function$;

REVOKE ALL ON FUNCTION public._clientes_documento_grupos(text) FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public._clientes_documento_grupos(text) IS
  'B17 (#1561, 1561-b11): el grupo del documento de cada cliente (dni_relleno_11, ambiguo, formato_almacenamiento, relleno_ceros, cuit, otro, otro_00, vacio) y el valor y el tipo con que lo deja la corrección. Sólo de server.';

-- Cuenta los grupos, aborta si alguno se sale de su rango (`p_rangos`:
-- {"grupo": [mínimo, máximo]}), guarda el respaldo, corrige y comprueba. Si no hay
-- nada que corregir (la foto del CI, una base de ensayo, o prod ya corregida) no
-- mira los rangos y no toca nada. Devuelve los conteos. La llaman esta migración y
-- el ensayo; nadie más (sin EXECUTE).
CREATE FUNCTION public._clientes_dni_como_cuit_corregir(p_regla_ambiguos text, p_rangos jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_conteo      jsonb;
  v_a_corregir  int;
  v_fuera       text;
  v_ids         bigint[];
  v_n           int;
  v_inactivos   int;
  v_duplicados  int;
  v_mal         int;
BEGIN
  IF p_regla_ambiguos IS NULL OR p_regla_ambiguos NOT IN ('ultimos_8', 'almacenamiento') THEN
    RAISE EXCEPTION 'La regla de los ambiguos es ''ultimos_8'' o ''almacenamiento'', no %', p_regla_ambiguos;
  END IF;

  SELECT jsonb_object_agg(k.grupo, (SELECT count(*) FROM public._clientes_documento_grupos(p_regla_ambiguos) g
                                     WHERE g.grupo = k.grupo))
    INTO v_conteo
    FROM unnest(ARRAY['dni_relleno_11', 'ambiguo', 'formato_almacenamiento', 'relleno_ceros',
                      'cuit', 'otro', 'otro_00', 'vacio']) AS k(grupo);

  SELECT count(*) INTO v_a_corregir
    FROM public._clientes_documento_grupos(p_regla_ambiguos) g
   WHERE g.cuit_nuevo IS DISTINCT FROM g.cuit AND g.tipo_nuevo IS NOT NULL
      OR g.tipo_nuevo IS DISTINCT FROM g.tipo_documento AND g.tipo_nuevo IS NOT NULL;

  -- Un valor que empieza con 00 y no es de ningún grupo dejaría inválido el CHECK: a mano.
  IF (v_conteo->>'otro_00')::int > 0 THEN
    RAISE EXCEPTION 'B17 · % clientes tienen un documento que empieza con 00 y no es un DNI reconocible (conteo: %): corregirlos a mano antes',
      v_conteo->>'otro_00', v_conteo;
  END IF;

  IF v_a_corregir = 0 THEN
    RETURN v_conteo || jsonb_build_object('actualizados', 0, 'inactivos_actualizados', 0,
                                          'duplicados_dni', 0, 'regla_ambiguos', p_regla_ambiguos);
  END IF;

  -- Premisa de datos: cada grupo en su rango.
  SELECT string_agg(format('%s=%s (esperado de %s a %s)', r.key, COALESCE(v_conteo->>r.key, '?'),
                           r.value->>0, r.value->>1), ', ' ORDER BY r.key)
    INTO v_fuera
    FROM jsonb_each(COALESCE(p_rangos, '{}'::jsonb)) r
   WHERE NOT v_conteo ? r.key
      OR (v_conteo->>r.key)::int NOT BETWEEN (r.value->>0)::int AND (r.value->>1)::int;
  IF v_fuera IS NOT NULL THEN
    RAISE EXCEPTION 'B17 · los grupos no son los que se midieron: % (conteo completo: %). Volver a medir prod y revisar',
      v_fuera, v_conteo;
  END IF;

  -- Respaldo y corrección, sólo de las filas que cambian.
  WITH g AS (
    SELECT * FROM public._clientes_documento_grupos(p_regla_ambiguos) g
     WHERE g.tipo_nuevo IS NOT NULL
       AND (g.cuit_nuevo IS DISTINCT FROM g.cuit OR g.tipo_nuevo IS DISTINCT FROM g.tipo_documento)
  ), ins AS (
    INSERT INTO public.clientes_documento_respaldo
      (cliente_id, sucursal_id, grupo, regla_ambiguos, activo,
       cuit_anterior, tipo_documento_anterior, cuit_nuevo, tipo_documento_nuevo)
    SELECT g.id, g.sucursal_id, g.grupo, CASE WHEN g.grupo = 'ambiguo' THEN p_regla_ambiguos END, g.activo,
           g.cuit, g.tipo_documento, g.cuit_nuevo, g.tipo_nuevo
      FROM g
    RETURNING cliente_id, cuit_nuevo, tipo_documento_nuevo
  ), upd AS (
    UPDATE public.clientes c
       SET cuit = ins.cuit_nuevo,
           tipo_documento = ins.tipo_documento_nuevo
      FROM ins
     WHERE c.id = ins.cliente_id
    RETURNING c.id
  )
  SELECT array_agg(upd.id ORDER BY upd.id), count(*) INTO v_ids, v_n FROM upd;

  -- Poscondición.
  IF v_n <> v_a_corregir THEN
    RAISE EXCEPTION 'B17 · se corrigieron % clientes y había % para corregir', v_n, v_a_corregir;
  END IF;

  SELECT count(*) INTO v_mal
    FROM public.clientes_documento_respaldo r
    LEFT JOIN public.clientes c ON c.id = r.cliente_id
   WHERE r.cliente_id = ANY (v_ids)
     AND (c.cuit IS DISTINCT FROM r.cuit_nuevo OR c.tipo_documento IS DISTINCT FROM r.tipo_documento_nuevo);
  IF v_mal > 0 THEN
    RAISE EXCEPTION 'B17 · % clientes no quedaron como dice el respaldo', v_mal;
  END IF;

  IF EXISTS (SELECT 1 FROM public.clientes c
              WHERE c.cuit IS NOT NULL
                AND regexp_replace(c.cuit, '[^0-9]', '', 'g') LIKE '00%'
                AND (c.cuit !~ '^00-[0-9]{8}-0$' OR c.cuit = '00-00000000-0'
                     OR c.tipo_documento IS DISTINCT FROM 'DNI')) THEN
    RAISE EXCEPTION 'B17 · quedan documentos que empiezan con 00 sin el formato de un DNI o sin tipo DNI';
  END IF;

  SELECT count(*) FILTER (WHERE NOT r.activo) INTO v_inactivos
    FROM public.clientes_documento_respaldo r
   WHERE r.cliente_id = ANY (v_ids);

  -- Informativo: cuántos DNI de una sucursal quedan en más de un cliente, con alguno
  -- de los corregidos (no hay UNIQUE sobre el documento, y el control de duplicados
  -- del alta no lo mira).
  SELECT count(*) INTO v_duplicados
    FROM (SELECT 1
            FROM public.clientes c
           WHERE c.tipo_documento = 'DNI' AND c.cuit IS NOT NULL
           GROUP BY c.sucursal_id, c.cuit
          HAVING count(*) > 1 AND bool_or(c.id = ANY (v_ids))) dup;

  RETURN v_conteo || jsonb_build_object('actualizados', v_n, 'inactivos_actualizados', v_inactivos,
                                        'duplicados_dni', v_duplicados, 'regla_ambiguos', p_regla_ambiguos);
END
$function$;

REVOKE ALL ON FUNCTION public._clientes_dni_como_cuit_corregir(text, jsonb) FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public._clientes_dni_como_cuit_corregir(text, jsonb) IS
  'B17 (#1561, 1561-b11): corrige los DNI de clientes cargados como CUIT (tipo DNI y formato 00-XXXXXXXX-0; el relleno 00-00000000-0 queda NULL) y guarda el antes y el después en clientes_documento_respaldo. Sólo de server: la llaman su migración y su ensayo.';

-- =========================================================================
-- 3 · Se corrige prod
-- =========================================================================
-- Los rangos, sobre lo medido el 16/11 (118 / 14 / 2 / 18 / 2, y nada más):
--   · dni_relleno_11 y ambiguo nacen del campo CUIT que exigía 11 dígitos; desde el
--     16/11 (B11b) el dígito verificador rechaza 10 de cada 11 de esos rellenos, así
--     que no crecen: +2 de tolerancia, y −5 por ediciones;
--   · formato_almacenamiento y relleno_ceros crecen con cada alta con DNI hasta que
--     llegue el front de esta tarjeta: hasta +10 y +12;
--   · cuit crece con las altas con CUIT: hasta 20; otro (no empieza con 00 y no
--     tiene 11 dígitos) hasta 5. otro_00 aborta siempre (adentro de la función).
DO $correccion$
DECLARE
  -- La lectura de los 14 ambiguos: 'ultimos_8' (la recomendada) o 'almacenamiento'.
  v_regla text := 'ultimos_8';
  v_r     jsonb;
BEGIN
  v_r := public._clientes_dni_como_cuit_corregir(v_regla, jsonb_build_object(
    'dni_relleno_11',         jsonb_build_array(113, 120),
    'ambiguo',                jsonb_build_array(9, 16),
    'formato_almacenamiento', jsonb_build_array(0, 12),
    'relleno_ceros',          jsonb_build_array(13, 30),
    'cuit',                   jsonb_build_array(0, 20),
    'otro',                   jsonb_build_array(0, 5)));
  RAISE NOTICE 'mig NNN · documentos de clientes: %', v_r;
END
$correccion$;

-- =========================================================================
-- 4 · El freno
-- =========================================================================
CREATE FUNCTION public.clientes_tipo_documento_del_valor()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  -- B17 (#1561): el tipo de documento sale del valor. Un DNI se guarda en el formato
  -- `00-XXXXXXXX-0` y ningún CUIT empieza con 00. Así un bundle viejo del PWA, que
  -- nunca mandó el tipo, guarda bien. Espejo: tipoDocumentoDelValor (front).
  IF NEW.cuit IS NULL THEN
    RETURN NEW;
  END IF;
  IF NEW.cuit = '00-00000000-0' THEN
    -- El relleno de un DNI vacío: el cliente no tiene documento.
    NEW.cuit := NULL;
  ELSIF NEW.cuit ~ '^00-[0-9]{8}-0$' THEN
    NEW.tipo_documento := 'DNI';
  ELSIF regexp_replace(NEW.cuit, '[^0-9]', '', 'g') NOT LIKE '00%' THEN
    NEW.tipo_documento := 'CUIT';
  END IF;
  -- Lo que empieza con 00 con otra forma lo rechaza clientes_documento_con_su_tipo.
  RETURN NEW;
END
$function$;

-- Una función de trigger no necesita EXECUTE de nadie (la invoca el executor).
REVOKE ALL ON FUNCTION public.clientes_tipo_documento_del_valor() FROM PUBLIC, anon, authenticated;

-- El nombre la deja después de trg_clientes_proteger_columnas (los BEFORE corren por
-- nombre): el control del preventista mira lo que mandó, no lo que derivó éste.
CREATE TRIGGER trg_clientes_tipo_documento_del_valor
  BEFORE INSERT OR UPDATE OF cuit, tipo_documento ON public.clientes
  FOR EACH ROW EXECUTE FUNCTION public.clientes_tipo_documento_del_valor();

ALTER TABLE public.clientes ADD CONSTRAINT clientes_documento_con_su_tipo CHECK (
  cuit IS NULL
  OR CASE WHEN regexp_replace(cuit, '[^0-9]', '', 'g') LIKE '00%'
          THEN cuit ~ '^00-[0-9]{8}-0$' AND cuit <> '00-00000000-0'
               AND tipo_documento IS NOT DISTINCT FROM 'DNI'
          ELSE tipo_documento IS DISTINCT FROM 'DNI'
     END
);

COMMENT ON CONSTRAINT clientes_documento_con_su_tipo ON public.clientes IS
  'B17 (#1561): un documento que empieza con 00 es un DNI en el formato 00-XXXXXXXX-0 (no el relleno 00-00000000-0) y va con tipo DNI; cualquier otro no va con tipo DNI. El tipo lo pone trg_clientes_tipo_documento_del_valor.';
COMMENT ON COLUMN public.clientes.tipo_documento IS
  'Tipo de documento: CUIT (XX-XXXXXXXX-X) o DNI (guardado como 00-XXXXXXXX-0). Sale del valor de cuit: lo pone trg_clientes_tipo_documento_del_valor (B17, #1561).';

-- ---------------------------------------------------------------------------
-- Poscondición
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  v_mal text[] := '{}';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint c
                  WHERE c.conrelid = 'public.clientes'::regclass AND c.conname = 'clientes_documento_con_su_tipo'
                    AND c.contype = 'c' AND c.convalidated) THEN
    v_mal := v_mal || 'el CHECK clientes_documento_con_su_tipo no quedó validado'::text;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger t
                  WHERE t.tgrelid = 'public.clientes'::regclass AND t.tgname = 'trg_clientes_tipo_documento_del_valor'
                    AND t.tgenabled = 'O'
                    AND pg_get_triggerdef(t.oid) = 'CREATE TRIGGER trg_clientes_tipo_documento_del_valor BEFORE INSERT OR UPDATE OF cuit, tipo_documento ON public.clientes FOR EACH ROW EXECUTE FUNCTION clientes_tipo_documento_del_valor()') THEN
    v_mal := v_mal || 'el trigger trg_clientes_tipo_documento_del_valor no quedó como en el repo'::text;
  END IF;

  IF has_function_privilege('authenticated', 'public.clientes_tipo_documento_del_valor()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.clientes_tipo_documento_del_valor()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._clientes_dni_como_cuit_corregir(text, jsonb)', 'EXECUTE')
     OR has_function_privilege('anon', 'public._clientes_dni_como_cuit_corregir(text, jsonb)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._clientes_documento_grupos(text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public._clientes_documento_grupos(text)', 'EXECUTE') THEN
    v_mal := v_mal || 'las funciones nuevas quedaron con EXECUTE para anon o authenticated'::text;
  END IF;

  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.clientes_documento_respaldo'::regclass)
     OR EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'public.clientes_documento_respaldo'::regclass)
     OR has_table_privilege('authenticated', 'public.clientes_documento_respaldo', 'SELECT')
     OR has_table_privilege('anon', 'public.clientes_documento_respaldo', 'SELECT')
     OR has_table_privilege('authenticated', 'public.clientes_documento_respaldo', 'INSERT')
     OR has_table_privilege('authenticated', 'public.clientes_documento_respaldo', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.clientes_documento_respaldo', 'DELETE') THEN
    v_mal := v_mal || 'clientes_documento_respaldo no quedó sólo de server (RLS sin policies y sin grants)'::text;
  END IF;

  IF EXISTS (SELECT 1 FROM public.clientes c
              WHERE c.cuit IS NOT NULL
                AND regexp_replace(c.cuit, '[^0-9]', '', 'g') ~ '^000[0-9]{7}[1-9]$') THEN
    v_mal := v_mal || 'quedan DNI rellenados a 11 dígitos'::text;
  END IF;
  IF EXISTS (SELECT 1 FROM public.clientes c WHERE c.cuit = '00-00000000-0') THEN
    v_mal := v_mal || 'quedan clientes con el relleno 00-00000000-0'::text;
  END IF;

  IF array_length(v_mal, 1) > 0 THEN
    RAISE EXCEPTION 'mig NNN · no quedó como en el repo: %', array_to_string(v_mal, ' | ');
  END IF;
END
$post$;

COMMIT;
