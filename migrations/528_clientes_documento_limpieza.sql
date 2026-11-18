-- =========================================================================
-- NNN · LIMPIEZA DEL DOCUMENTO DE LOS CLIENTES: LOS NÚMEROS INVENTADOS SE
--       VACÍAN, LOS DNI QUEDAN CON SU TIPO, Y EL FRENO
--       (tarjeta B17 de la ola 2 del plan #1603; punto 1561-b11 de #1561)
--
-- Migración de DATOS sobre `clientes`, con su freno. Se aplica sólo con el OK
-- explícito del dueño, después de medir prod con las consultas de sólo lectura de
-- la tarjeta. Ensayo: scripts/test-clientes-documento-ola2-1603.sql. Se aplica en LF.
--
-- Qué pasó (lo contó el dueño el 17/11). El CUIT empezó siendo la validación para
-- no repetir un cliente, y era un campo obligatorio: hasta el 19/02/2026 el modal
-- no guardaba un cliente sin 11 dígitos en el campo CUIT. Como casi ningún
-- cliente tiene CUIT, se inventaba un número corto (un código propio) y el campo
-- lo completaba con ceros: `00-00000123-4`. No son documentos y no identifican a
-- nadie. Además, el front nunca le mandó a la base el tipo de documento (ni el
-- alta ni la edición lo nombraban), así que los dos DNI cargados con el selector
-- quedaron con tipo 'CUIT', y elegir DNI y dejarlo vacío guardaba el relleno
-- `00-00000000-0`.
--
-- Los grupos, por lo que el valor ES (sobre sus dígitos; medidos en prod el 17/11,
-- 815 clientes, 661 sin documento):
--   cuit_valido            11 dígitos, no empieza con 00, dígito verificador bien  ·  2 · no se toca
--   cuit_verificador_malo  11 dígitos, no empieza con 00, verificador mal          ·  0 · no se toca
--   dni_almacenamiento     `00-XXXXXXXX-0` con 7 u 8 cifras en el tramo del medio   ·  2 · tipo DNI
--   relleno_ceros          sólo ceros (`00-00000000-0`)                             · 18 · cuit NULL
--   inventado              11 dígitos, empieza con 00 y, sin los ceros de adelante,
--                          le quedan de 1 a 6 cifras                                 · 132 · cuit NULL
--   vacio                  sin dígitos ('' o espacios)                              · no se toca
--   otro_00 / otro         cualquier otra cosa: la migración ABORTA (corregir a mano)
-- La frontera entre «DNI» e «inventado» es la cantidad de cifras: un DNI son 7 u 8
-- (sin ceros de adelante) en el tramo del medio de `00-XXXXXXXX-0`, así que el valor
-- entero, sin los ceros de adelante, tiene 8 o 9; un inventado tiene 6 o menos. Un
-- valor que empieza con 00 y le quedan 7 cifras, o 8 o más sin la forma de un DNI,
-- no es ninguno de los dos: otro_00, aborta, no se adivina.
-- Los vaciados quedan con `tipo_documento` en su default ('CUIT'). Activos e
-- inactivos por igual (131 de los inventados tienen pedidos: el UPDATE no toca
-- pedidos, sólo `cuit` y `tipo_documento`).
--
-- Qué dispara el UPDATE de `clientes` (SET cuit, tipo_documento, como postgres):
--   · audit_clientes (AFTER, cada fila): una fila en audit_logs por cliente
--     corregido, con campos_modificados {cuit} o {cuit, tipo_documento} y usuario
--     NULL. Se deja a propósito: es el rastro del cambio en el historial del cliente
--     (audit_logs es evidencia), y son ~152 filas;
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
--     tipo_documento): el tipo sale del valor. `00-XXXXXXXX-0` con un DNI de 7 u 8
--     cifras es DNI y lo que no empieza con 00 es CUIT (ningún CUIT empieza con 00);
--     un valor de sólo ceros queda NULL. Así un bundle viejo del PWA, que no manda el
--     tipo, guarda bien un DNI;
--   · el CHECK `clientes_documento_con_su_tipo`: un valor que empieza con 00 sólo
--     puede ser un DNI en el formato de almacenamiento, con tipo DNI; cualquier otro
--     no va con tipo DNI. Un número inventado que mande un bundle viejo lo viola, y el
--     front lo traduce: «Ese número no es un CUIT ni un DNI. Si el cliente no tiene
--     documento, dejá el campo vacío.» (`errorDeSupabase`).
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
     OR to_regprocedure('public._clientes_documento_limpiar(jsonb)') IS NOT NULL
     OR to_regprocedure('public._clientes_documento_grupos()') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · las funciones de la limpieza ya existen: revisar a mano';
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
    CHECK (grupo IN ('inventado', 'dni_almacenamiento', 'relleno_ceros')),
  activo                  boolean      NOT NULL,
  cuit_anterior           varchar(13),
  tipo_documento_anterior varchar(4),
  cuit_nuevo              varchar(13),
  tipo_documento_nuevo    varchar(4),
  corregido_en            timestamptz  NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.clientes_documento_respaldo IS
  'B17 (#1561, 1561-b11): el documento de cada cliente que tocó la limpieza (números inventados y rellenos vaciados, DNI con su tipo), antes y después, para poder deshacerla. Sólo de server: RLS sin policies y sin grants (es dato de clientes). La escribe _clientes_documento_limpiar.';

ALTER TABLE public.clientes_documento_respaldo ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.clientes_documento_respaldo FROM PUBLIC, anon, authenticated;

-- =========================================================================
-- 2 · La limpieza
-- =========================================================================
-- Cada cliente con documento, con su grupo y, si se corrige, el valor y el tipo
-- nuevos. Por los dígitos del valor, así un guion o un espacio de más no lo saca de
-- su grupo. Lee activos e inactivos a propósito. Sólo de server.
CREATE FUNCTION public._clientes_documento_grupos()
 RETURNS TABLE (id bigint, sucursal_id bigint, activo boolean, cuit varchar(13), tipo_documento varchar(4),
                grupo text, cuit_nuevo varchar(13), tipo_nuevo varchar(4))
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT y.id, y.sucursal_id, y.activo, y.cuit, y.tipo_documento, y.grupo,
         CASE WHEN y.grupo = 'dni_almacenamiento' THEN ('00-' || y.medio || '-0')::varchar(13) END,
         CASE WHEN y.grupo = 'dni_almacenamiento' THEN 'DNI'
              WHEN y.grupo IN ('inventado', 'relleno_ceros') THEN 'CUIT'
         END::varchar(4)
    FROM (
      SELECT z.*,
             CASE
               WHEN z.d = '' THEN 'vacio'
               WHEN z.d ~ '^0+$' THEN 'relleno_ceros'
               -- `00-XXXXXXXX-0` con un DNI de 7 u 8 cifras en el medio.
               WHEN z.d ~ '^00[0-9]{8}0$' AND ltrim(z.medio, '0') ~ '^[0-9]{7,8}$' THEN 'dni_almacenamiento'
               -- Un número corto rellenado con ceros a 11 dígitos.
               WHEN z.d ~ '^00[0-9]{9}$' AND length(ltrim(z.d, '0')) BETWEEN 1 AND 6 THEN 'inventado'
               WHEN z.d LIKE '00%' THEN 'otro_00'
               WHEN z.d ~ '^[0-9]{11}$' AND z.verificador_ok THEN 'cuit_valido'
               WHEN z.d ~ '^[0-9]{11}$' THEN 'cuit_verificador_malo'
               ELSE 'otro'
             END AS grupo
        FROM (SELECT c.id, c.sucursal_id, c.activo, c.cuit, c.tipo_documento, d.d,
                     substr(d.d, 3, 8) AS medio,
                     -- Dígito verificador del CUIT (módulo 11; resto 1 no existe), como
                     -- validarCuit del front.
                     CASE WHEN d.d ~ '^[0-9]{11}$' THEN
                       (SELECT CASE WHEN s.r = 1 THEN false
                                    ELSE (CASE WHEN s.r = 0 THEN 0 ELSE 11 - s.r END) = substr(d.d, 11, 1)::int
                               END
                          FROM (SELECT (SELECT sum(substr(d.d, i, 1)::int * (ARRAY[5,4,3,2,7,6,5,4,3,2])[i])
                                          FROM generate_series(1, 10) i) % 11 AS r) s)
                     END AS verificador_ok
                FROM public.clientes c
               CROSS JOIN LATERAL (SELECT regexp_replace(c.cuit, '[^0-9]', '', 'g') AS d) d
               WHERE c.cuit IS NOT NULL) z
    ) y;
$function$;

REVOKE ALL ON FUNCTION public._clientes_documento_grupos() FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public._clientes_documento_grupos() IS
  'B17 (#1561, 1561-b11): el grupo del documento de cada cliente (cuit_valido, cuit_verificador_malo, dni_almacenamiento, relleno_ceros, inventado, vacio, otro_00, otro) y el valor y el tipo con que lo deja la limpieza. Sólo de server.';

-- Cuenta los grupos, aborta si alguno se sale de su rango (`p_rangos`:
-- {"grupo": [mínimo, máximo]}) o si hay un valor que no es de ningún grupo, guarda
-- el respaldo, corrige y comprueba. Si no hay nada que corregir (la foto del CI, una
-- base de ensayo, o prod ya limpia) no mira los rangos y no toca nada. Devuelve los
-- conteos. La llaman esta migración y el ensayo; nadie más (sin EXECUTE).
CREATE FUNCTION public._clientes_documento_limpiar(p_rangos jsonb)
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
  v_mal         int;
BEGIN
  SELECT jsonb_object_agg(k.grupo, (SELECT count(*) FROM public._clientes_documento_grupos() g
                                     WHERE g.grupo = k.grupo))
    INTO v_conteo
    FROM unnest(ARRAY['cuit_valido', 'cuit_verificador_malo', 'dni_almacenamiento', 'relleno_ceros',
                      'inventado', 'vacio', 'otro_00', 'otro']) AS k(grupo);

  -- Lo que no es de ningún grupo no se adivina: a mano.
  IF (v_conteo->>'otro_00')::int > 0 OR (v_conteo->>'otro')::int > 0 THEN
    RAISE EXCEPTION 'B17 · % clientes tienen un documento que no es un CUIT, ni un DNI, ni un número inventado reconocible (conteo: %): corregirlos a mano antes',
      (v_conteo->>'otro_00')::int + (v_conteo->>'otro')::int, v_conteo;
  END IF;

  SELECT count(*) INTO v_a_corregir
    FROM public._clientes_documento_grupos() g
   WHERE g.tipo_nuevo IS NOT NULL
     AND (g.cuit_nuevo IS DISTINCT FROM g.cuit OR g.tipo_nuevo IS DISTINCT FROM g.tipo_documento);

  IF v_a_corregir = 0 THEN
    RETURN v_conteo || jsonb_build_object('actualizados', 0, 'vaciados', 0, 'inactivos_actualizados', 0);
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
    SELECT * FROM public._clientes_documento_grupos() g
     WHERE g.tipo_nuevo IS NOT NULL
       AND (g.cuit_nuevo IS DISTINCT FROM g.cuit OR g.tipo_nuevo IS DISTINCT FROM g.tipo_documento)
  ), ins AS (
    INSERT INTO public.clientes_documento_respaldo
      (cliente_id, sucursal_id, grupo, activo,
       cuit_anterior, tipo_documento_anterior, cuit_nuevo, tipo_documento_nuevo)
    SELECT g.id, g.sucursal_id, g.grupo, g.activo, g.cuit, g.tipo_documento, g.cuit_nuevo, g.tipo_nuevo
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

  IF EXISTS (SELECT 1 FROM public._clientes_documento_grupos() g
              WHERE g.grupo IN ('inventado', 'relleno_ceros', 'otro_00', 'otro')
                 OR g.grupo = 'dni_almacenamiento'
                    AND (g.cuit IS DISTINCT FROM g.cuit_nuevo OR g.tipo_documento IS DISTINCT FROM 'DNI')) THEN
    RAISE EXCEPTION 'B17 · después de la limpieza quedan números inventados, rellenos o DNI sin su tipo';
  END IF;

  SELECT count(*) FILTER (WHERE NOT r.activo) INTO v_inactivos
    FROM public.clientes_documento_respaldo r
   WHERE r.cliente_id = ANY (v_ids);

  RETURN v_conteo || jsonb_build_object(
    'actualizados', v_n,
    'vaciados', (SELECT count(*) FROM public.clientes_documento_respaldo r
                  WHERE r.cliente_id = ANY (v_ids) AND r.cuit_nuevo IS NULL),
    'inactivos_actualizados', v_inactivos);
END
$function$;

REVOKE ALL ON FUNCTION public._clientes_documento_limpiar(jsonb) FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public._clientes_documento_limpiar(jsonb) IS
  'B17 (#1561, 1561-b11): vacía los números inventados y los rellenos del documento de los clientes y le pone el tipo DNI a los DNI, guardando el antes y el después en clientes_documento_respaldo. Sólo de server: la llaman su migración y su ensayo.';

-- =========================================================================
-- 3 · Se limpia prod
-- =========================================================================
-- Los rangos, sobre lo medido el 17/11 (132 inventados, 2 DNI, 18 rellenos, 2 CUIT):
--   · inventado: el campo dejó de ser obligatorio el 19/02 (115 de los 132 son de
--     febrero) y desde el 16/11 el front exige el dígito verificador, que deja pasar
--     uno de cada once de esos números: casi no crece. +3 de tolerancia, y −5 por
--     ediciones;
--   · dni_almacenamiento y relleno_ceros crecen con cada alta con DNI hasta que llegue
--     el front de esta tarjeta: hasta +10 y +12;
--   · cuit_valido crece con las altas con CUIT: hasta 20; cuit_verificador_malo, hasta
--     2 (los dos medidos, si alguno no pasa el verificador: desde B11b no entran nuevos).
--   otro_00 y otro abortan siempre (adentro de la función).
DO $limpieza$
DECLARE
  v_r jsonb;
BEGIN
  v_r := public._clientes_documento_limpiar(jsonb_build_object(
    'inventado',             jsonb_build_array(127, 135),
    'dni_almacenamiento',    jsonb_build_array(0, 12),
    'relleno_ceros',         jsonb_build_array(13, 30),
    'cuit_valido',           jsonb_build_array(0, 20),
    'cuit_verificador_malo', jsonb_build_array(0, 2)));
  RAISE NOTICE 'mig NNN · documentos de clientes: %', v_r;
END
$limpieza$;

-- =========================================================================
-- 4 · El freno
-- =========================================================================
CREATE FUNCTION public.clientes_tipo_documento_del_valor()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_d text;
BEGIN
  -- B17 (#1561): el tipo de documento sale del valor. Un DNI se guarda en el formato
  -- `00-XXXXXXXX-0` (7 u 8 cifras) y ningún CUIT empieza con 00. Así un bundle viejo
  -- del PWA, que nunca mandó el tipo, guarda bien. Espejo: tipoDocumentoDelValor (front).
  IF NEW.cuit IS NULL THEN
    RETURN NEW;
  END IF;
  v_d := regexp_replace(NEW.cuit, '[^0-9]', '', 'g');
  IF v_d ~ '^0+$' THEN
    -- El relleno de un documento vacío: el cliente no tiene documento.
    NEW.cuit := NULL;
  ELSIF NEW.cuit ~ '^00-[0-9]{8}-0$' AND ltrim(substr(NEW.cuit, 4, 8), '0') ~ '^[0-9]{7,8}$' THEN
    NEW.tipo_documento := 'DNI';
  ELSIF v_d NOT LIKE '00%' THEN
    NEW.tipo_documento := 'CUIT';
  END IF;
  -- Lo demás que empieza con 00 (un número inventado) lo rechaza clientes_documento_con_su_tipo.
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
          THEN cuit ~ '^00-[0-9]{8}-0$' AND ltrim(substr(cuit, 4, 8), '0') ~ '^[0-9]{7,8}$'
               AND tipo_documento IS NOT DISTINCT FROM 'DNI'
          ELSE tipo_documento IS DISTINCT FROM 'DNI'
     END
);

COMMENT ON CONSTRAINT clientes_documento_con_su_tipo ON public.clientes IS
  'B17 (#1561): un documento que empieza con 00 sólo puede ser un DNI de 7 u 8 cifras en el formato 00-XXXXXXXX-0, con tipo DNI (un número inventado rellenado con ceros no entra); cualquier otro no va con tipo DNI. El tipo lo pone trg_clientes_tipo_documento_del_valor.';
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
     OR has_function_privilege('authenticated', 'public._clientes_documento_limpiar(jsonb)', 'EXECUTE')
     OR has_function_privilege('anon', 'public._clientes_documento_limpiar(jsonb)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._clientes_documento_grupos()', 'EXECUTE')
     OR has_function_privilege('anon', 'public._clientes_documento_grupos()', 'EXECUTE') THEN
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

  IF EXISTS (SELECT 1 FROM public._clientes_documento_grupos() g
              WHERE g.grupo IN ('inventado', 'relleno_ceros', 'otro_00', 'otro')) THEN
    v_mal := v_mal || 'quedan números inventados, rellenos o documentos irreconocibles'::text;
  END IF;

  IF array_length(v_mal, 1) > 0 THEN
    RAISE EXCEPTION 'mig NNN · no quedó como en el repo: %', array_to_string(v_mal, ' | ');
  END IF;
END
$post$;

COMMIT;
