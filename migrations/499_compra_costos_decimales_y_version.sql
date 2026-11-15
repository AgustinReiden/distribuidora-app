-- =========================================================================
-- NNN · LA COMPRA: EL COSTO REAL NO QUEDA NEGATIVO, LOS RANGOS DEL RENGLÓN,
--       EL COSTO AL CENTAVO, LA VERSIÓN EN LA EDICIÓN Y EL REGALO LEGAL
--       (reauditoría completa del 12/11: CMP-3, CMP-5, FRG-1 y FRG-4 de #1557;
--        tarjeta 3 de #1565)
--
-- Crea dos helpers de server, parcha por ancla `registrar_compra_completa` y
-- `auditoria_integridad`, y cambia la firma de `actualizar_compra_items` (suma
-- `p_renglones_vistos`; la vieja se dropea, para que PostgREST no tenga dos
-- sobrecargas). Premisa de md5 sobre los cuerpos vivos leídos el 12/11 (los
-- tres en LF) y poscondición de md5, definer y ACL.
-- Ensayo: scripts/test-compra-costos-decimales-y-version-1557.sql. Se aplica en LF.
--
-- =========================================================================
-- 1 · CMP-3 · UN CARGO NEGATIVO MAYOR QUE SU RENGLÓN
-- =========================================================================
-- Una bonificación prorrateada de −2.000 sobre un renglón de 10 × 100 dejaba
-- `costo_real = −100`: el producto quedaba con costo de reposición y promedio
-- negativos, y las ventas congelaban ese costo. El motor
-- (`calcular_costos_compra`) no conoce un piso, y no tiene por qué: el cargo
-- puede ser legal y estar mal repartido. Ahora, en el alta y en la edición, si
-- algún renglón queda con costo real negativo, o en 0 siendo un renglón que se
-- paga (sin bonificación del 100 % y con costo), la compra se rechaza y se
-- dice qué renglón y en cuánto queda. El regalo (bonificación 100) no fija
-- costo, y un cargo positivo (el flete) lo puede llevar arriba de 0: eso sigue.
-- Sin cargos ni II declarado el motor no corre, y el costo real es el neto por
-- (1 + II): con el II en rango no puede quedar negativo.
--
-- =========================================================================
-- 2 · LOS RANGOS DEL RENGLÓN, EN UN SOLO LUGAR
-- =========================================================================
-- El alta validaba cantidad, costo y bonificación (#1471); la edición, nada
-- (una bonificación de −50 o un costo de −100 entraban). Y ninguna de las dos
-- miraba el II ni la alícuota del renglón: un II de −90 % en una FC A dejaba
-- el costo real en 10. La regla es una, `_compra_renglones_fuera_de_rango`, y
-- la llaman las dos. Suma:
--   · el II del renglón y la alícuota de IVA son porcentajes, de 0 a 100, y
--     números ('NaN' no lo es, CMP-1);
--   · CMP-5, el costo 0: ver el punto 4.
-- Y los importes de la cabecera tienen que ser números finitos (un 'NaN' en
-- el IVA o en una percepción entraba, CMP-1) y, salvo la bonificación de la
-- factura, no negativos. Los CHECK de las columnas son de la tarjeta 1 (los
-- mismos rangos); esto es el rechazo con su motivo.
--
-- =========================================================================
-- 3 · FRG-1 · EL COSTO UNITARIO, AL CENTAVO, AL ENTRAR
-- =========================================================================
-- `compra_items.costo_unitario` es numeric(12,2), y el escaneo manda el precio
-- del bulto dividido por las unidades sin redondear. Un bulto de $10.000 con
-- 2.400 unidades viajaba a 4,1666…, el renglón cerraba contra 10.000 con ese
-- costo, y la columna guardaba 4,17: el renglón guardado decía 2.400 × 4,17 =
-- 10.008 contra un subtotal de 10.000. Una NC por todo acreditaba 10.008, y
-- reabrir la compra sin cambios movía la cabecera a 10.008.
-- Ahora el costo se redondea al centavo al entrar (alta y edición), y el
-- control de cada renglón (mig 482) compara el subtotal contra ese costo: el
-- renglón que se guarda cierra contra su subtotal. Un cliente viejo que mande
-- el costo sin redondear recibe «el subtotal mal calculado» con lo que da, en
-- vez de guardar un renglón que no cierra. El front redondea antes de mandar.
-- Los 41 renglones vivos de prod que hoy no cierran no se tocan (se arregla
-- hacia adelante; decisión pendiente del dueño).
--
-- =========================================================================
-- 4 · CMP-5 · EL COSTO 0 Y COMPRA-C
-- =========================================================================
-- La RPC, el modal y la plantilla del Excel tratan como regalo un renglón a
-- costo 0, y COMPRA-C (high) lo contaba como violación; el modal precarga 0 si
-- el producto no tiene costo, y un olvido bajaba el promedio sin aviso.
-- Decisión del dueño (12/11): se rechaza. El regalo legal es la bonificación
-- del 100 %; un renglón a costo 0 sin ella se rechaza con «si viene sin cargo,
-- cargalo con bonificación del 100 %». En prod no hay ningún renglón a costo 0
-- (12/11).
-- COMPRA-C pasa a contar lo que ahora es ilegal: costo o costo real negativo, o
-- un renglón que se paga con costo o costo real 0. El regalo legal (costo 0, o
-- cualquier costo, con bonificación 100) no cuenta. COMPRA-E cuenta la
-- bonificación fuera de [0, 100]: el 100 es el regalo legal, y la RPC lo
-- acepta desde siempre. En prod los dos dan 0, antes y después.
--
-- =========================================================================
-- 5 · FRG-4 · DOS EDICIONES DE LA MISMA COMPRA
-- =========================================================================
-- La edición partía de la compra de la lista (caché de 5 minutos) y la RPC no
-- recibía versión: la segunda de dos ediciones reemplazaba todas las líneas con
-- su copia vieja y pisaba la primera sin aviso.
-- Cada edición borra y recrea las líneas, así que los ids de los renglones son
-- la versión de la compra: `p_renglones_vistos` son los que el usuario abrió.
-- La RPC, con la compra ya tomada FOR UPDATE (482), compara esos ids con los
-- de hoy y, si no son los mismos, rechaza con «alguien la cambió». Sin el
-- parámetro (un bundle viejo del PWA) pide recargar, como los guards de cargos
-- e II de la 194. Ningún otro camino cambia los renglones de una compra viva:
-- la anulación y el cambio de proveedor la cancelan (y la edición ya rechaza
-- una cancelada), y con una NC no se edita (482).
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

-- ---------------------------------------------------------------------------
-- Premisa: los cuerpos vivos son los leídos el 12/11, en LF, y lo nuevo no existe
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)',
     '6f7a9484ede576f24e7650fe45921ff0'),
    ('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)',
     '6d445a93278099e89c2724397e7daa80'),
    ('public.auditoria_integridad()', 'c9db83404dddd57d7ca7c98f74241692')
  ) AS t(f, h) LOOP
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre la definición vigente', r.f, v;
    END IF;
  END LOOP;

  IF to_regprocedure('public._compra_renglones_fuera_de_rango(jsonb,bigint)') IS NOT NULL
     OR to_regprocedure('public._compra_costo_real_sin_piso(jsonb,jsonb,bigint)') IS NOT NULL
     OR EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'actualizar_compra_items'
                  AND pronamespace = 'public'::regnamespace AND pronargs <> 14) THEN
    RAISE EXCEPTION 'mig NNN · un helper o una sobrecarga de actualizar_compra_items ya existe: revisar a mano';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 2 · Los rangos del renglón, para el alta y la edición
-- ---------------------------------------------------------------------------
CREATE FUNCTION public._compra_renglones_fuera_de_rango(p_items jsonb, p_sucursal bigint)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  /* mig NNN (#1557) · Los rangos de un renglón de compra, en el alta y en la
     edición. Devuelve los motivos de los renglones que no entran, uno por
     renglón, o NULL. El CASE va en orden: cada cast se hace después de
     comprobar que el texto es un número ('NaN' no lo es). */
  SELECT string_agg(format('%s (renglón %s): %s', COALESCE(pr.nombre, 'producto ' || COALESCE(r.val->>'producto_id', '?')),
                           r.n, r.motivo), '; ' ORDER BY r.n)
    FROM (
      SELECT e.val, e.n,
             CASE
               WHEN COALESCE(e.val->>'cantidad', '') !~ '^\s*-?[0-9]+(\.[0-9]+)?\s*$'
                 THEN 'la cantidad no es un número'
               WHEN (e.val->>'cantidad')::NUMERIC <> trunc((e.val->>'cantidad')::NUMERIC)
                 THEN 'la cantidad tiene que ser entera'
               WHEN (e.val->>'cantidad')::NUMERIC <= 0
                 THEN 'la cantidad tiene que ser mayor a 0'
               WHEN e.val->>'costo_unitario' IS NOT NULL
                    AND (e.val->>'costo_unitario') !~ '^\s*-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?\s*$'
                 THEN 'el costo no es un número'
               WHEN (e.val->>'costo_unitario')::NUMERIC < 0
                 THEN 'el costo no puede ser negativo'
               WHEN e.val->>'bonificacion' IS NOT NULL
                    AND (e.val->>'bonificacion') !~ '^\s*-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?\s*$'
                 THEN 'la bonificación no es un número'
               WHEN (e.val->>'bonificacion')::NUMERIC < 0 OR (e.val->>'bonificacion')::NUMERIC > 100
                 THEN 'la bonificación es un porcentaje, de 0 a 100'
               WHEN e.val->>'impuestos_internos' IS NOT NULL
                    AND (e.val->>'impuestos_internos') !~ '^\s*-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?\s*$'
                 THEN 'el impuesto interno no es un número'
               WHEN (e.val->>'impuestos_internos')::NUMERIC < 0 OR (e.val->>'impuestos_internos')::NUMERIC > 100
                 THEN 'el impuesto interno es un porcentaje, de 0 a 100'
               WHEN e.val->>'porcentaje_iva' IS NOT NULL
                    AND (e.val->>'porcentaje_iva') !~ '^\s*-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?\s*$'
                 THEN 'la alícuota de IVA no es un número'
               WHEN (e.val->>'porcentaje_iva')::NUMERIC < 0 OR (e.val->>'porcentaje_iva')::NUMERIC > 100
                 THEN 'la alícuota de IVA es un porcentaje, de 0 a 100'
               /* CMP-5 · el regalo legal es la bonificación del 100 %. Un costo 0
                  (o que al centavo da 0) sin ella es casi siempre un olvido: el
                  modal precarga 0 si el producto no tiene costo, y el renglón
                  bajaba el promedio sin aviso. */
               WHEN round(COALESCE((e.val->>'costo_unitario')::NUMERIC, 0), 2) = 0
                    AND COALESCE((e.val->>'bonificacion')::NUMERIC, 0) < 100
                 THEN 'el costo es 0: si viene sin cargo, cargalo con bonificación del 100 %'
             END AS motivo
        FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_items) = 'array'
                                       THEN p_items ELSE '[]'::JSONB END) WITH ORDINALITY AS e(val, n)
    ) r
    LEFT JOIN productos pr
      ON pr.id = CASE WHEN COALESCE(r.val->>'producto_id', '') ~ '^\s*[0-9]+\s*$'
                      THEN (r.val->>'producto_id')::BIGINT END
     AND pr.sucursal_id = p_sucursal
   WHERE r.motivo IS NOT NULL;
$function$;

REVOKE ALL ON FUNCTION public._compra_renglones_fuera_de_rango(jsonb, bigint) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1 · CMP-3 · el renglón que el motor deja sin costo
-- ---------------------------------------------------------------------------
CREATE FUNCTION public._compra_costo_real_sin_piso(p_items jsonb, p_costos jsonb, p_sucursal bigint)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  /* mig NNN (CMP-3, #1557) · Los renglones a los que el motor
     (`calcular_costos_compra`) les deja el costo real negativo, o en 0 a uno
     que se paga (sin bonificación del 100 % y con costo). `p_costos->'lineas'`
     va por índice de `p_items` (base 0). El costo real se compara como lo
     guardan las RPCs, a 4 decimales. Devuelve un motivo por renglón, o NULL. */
  SELECT string_agg(format('%s (renglón %s) queda en %s', COALESCE(pr.nombre, 'producto ' || COALESCE(x.it->>'producto_id', '?')),
                           (l->>'id')::INT + 1, round((l->>'costo_real')::NUMERIC, 2)),
                    '; ' ORDER BY (l->>'id')::INT)
    FROM jsonb_array_elements(COALESCE(p_costos->'lineas', '[]'::JSONB)) AS l
    CROSS JOIN LATERAL (SELECT p_items -> ((l->>'id')::INT) AS it) x
    LEFT JOIN productos pr
      ON pr.id = (x.it->>'producto_id')::BIGINT AND pr.sucursal_id = p_sucursal
   WHERE round((l->>'costo_real')::NUMERIC, 4) < 0
      OR (round((l->>'costo_real')::NUMERIC, 4) = 0
          AND COALESCE((x.it->>'bonificacion')::NUMERIC, 0) < 100
          AND COALESCE((x.it->>'costo_unitario')::NUMERIC, 0) > 0);
$function$;

REVOKE ALL ON FUNCTION public._compra_costo_real_sin_piso(jsonb, jsonb, bigint) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- registrar_compra_completa: cabecera, rangos con el helper, costo al centavo y CMP-3
-- ---------------------------------------------------------------------------
DO $parche_alta$
DECLARE
  v_def text := pg_get_functiondef('public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)'::regprocedure);
  v_par text[][] := ARRAY[
    -- a) los importes de la cabecera, antes de #1077 y del INSERT
    [$a$  /* #1077 · La cabecera es la suma de los renglones$a$,
     $r$  /* mig NNN (CMP-1, #1557) · LOS IMPORTES DE LA CABECERA SON NUMEROS. Un 'NaN'
     o un infinito en el IVA, una percepcion o el total entraba: el CHECK de la
     columna lo frena (tarjeta 1), y esto dice por que. */
  IF EXISTS (SELECT 1 FROM unnest(ARRAY[p_subtotal, p_iva, p_otros_impuestos, p_total,
                                        p_impuestos_internos, p_percepcion_iva, p_percepcion_iibb,
                                        p_no_gravado, p_bonificaciones]::NUMERIC[]) AS x
              WHERE x IN ('NaN', 'Infinity', '-Infinity')) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Hay un importe de la cabecera que no es un número. Revisá los importes; si sigue igual, recargá la aplicación y volvé a cargarla.');
  END IF;

  /* #1077 · La cabecera es la suma de los renglones$r$],
    -- b) los rangos, del helper, y el costo al centavo
    [$a$  SELECT string_agg(format('%s (renglón %s): %s', COALESCE(pr.nombre, 'producto ' || COALESCE(r.val->>'producto_id', '?')),
                           r.n, r.motivo), '; ' ORDER BY r.n)
    INTO v_fuera_de_rango
    FROM (
      SELECT e.val, e.n,
             CASE
               WHEN COALESCE(e.val->>'cantidad', '') !~ '^\s*-?[0-9]+(\.[0-9]+)?\s*$'
                 THEN 'la cantidad no es un número'
               WHEN (e.val->>'cantidad')::NUMERIC <> trunc((e.val->>'cantidad')::NUMERIC)
                 THEN 'la cantidad tiene que ser entera'
               WHEN (e.val->>'cantidad')::NUMERIC <= 0
                 THEN 'la cantidad tiene que ser mayor a 0'
               WHEN e.val->>'costo_unitario' IS NOT NULL
                    AND (e.val->>'costo_unitario') !~ '^\s*-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?\s*$'
                 THEN 'el costo no es un número'
               WHEN (e.val->>'costo_unitario')::NUMERIC < 0
                 THEN 'el costo no puede ser negativo'
               WHEN e.val->>'bonificacion' IS NOT NULL
                    AND (e.val->>'bonificacion') !~ '^\s*-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?\s*$'
                 THEN 'la bonificación no es un número'
               WHEN (e.val->>'bonificacion')::NUMERIC < 0 OR (e.val->>'bonificacion')::NUMERIC > 100
                 THEN 'la bonificación es un porcentaje, de 0 a 100'
             END AS motivo
        FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_items) = 'array'
                                       THEN p_items ELSE '[]'::JSONB END) WITH ORDINALITY AS e(val, n)
    ) r
    LEFT JOIN productos pr
      ON pr.id = CASE WHEN COALESCE(r.val->>'producto_id', '') ~ '^\s*[0-9]+\s*$'
                      THEN (r.val->>'producto_id')::BIGINT END
     AND pr.sucursal_id = v_sucursal
   WHERE r.motivo IS NOT NULL;
  IF v_fuera_de_rango IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Hay renglones fuera de rango: ' || v_fuera_de_rango || '.');
  END IF;$a$,
     $r$  /* mig NNN (#1557) · la regla de los rangos es una, con la edicion: suma el
     II y la alicuota del renglon (0 a 100) y el costo 0 sin bonificacion del
     100 % (CMP-5). */
  v_fuera_de_rango := _compra_renglones_fuera_de_rango(p_items, v_sucursal);
  IF v_fuera_de_rango IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Hay renglones fuera de rango: ' || v_fuera_de_rango || '.');
  END IF;

  /* mig NNN (#1557) · y los importes de la cabecera, salvo la bonificacion de la
     factura (que va con su signo, mig 195), no son negativos: es el CHECK de la
     tarjeta 1, dicho con su motivo. Despues de los renglones, que nombran la
     causa (un costo negativo da un subtotal negativo). */
  IF EXISTS (SELECT 1 FROM unnest(ARRAY[p_subtotal, p_iva, p_otros_impuestos, p_total,
                                        p_impuestos_internos, p_percepcion_iva, p_percepcion_iibb,
                                        p_no_gravado]::NUMERIC[]) AS x
              WHERE x < 0) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Hay un importe de la cabecera negativo: sólo la bonificación de la factura puede serlo. Revisá los importes.');
  END IF;

  /* mig NNN (FRG-1, #1557) · EL COSTO UNITARIO, AL CENTAVO, AL ENTRAR.
     compra_items.costo_unitario es numeric(12,2): el escaneo mandaba el precio
     del bulto dividido por las unidades sin redondear, el renglon cerraba con
     ese costo y la columna guardaba otro (2.400 x 4,17 = 10.008 contra un
     subtotal de 10.000). Desde aca todo el cuerpo —el control de cada renglon,
     el motor y el loop— usa el costo que se guarda. Los rangos ya comprobaron
     que es un numero. */
  IF jsonb_typeof(p_items) = 'array' AND jsonb_array_length(p_items) > 0 THEN
    SELECT jsonb_agg(CASE WHEN jsonb_typeof(e.val->'costo_unitario') IN ('number', 'string')
                          THEN jsonb_set(e.val, '{costo_unitario}',
                                         to_jsonb(round((e.val->>'costo_unitario')::NUMERIC, 2)))
                          ELSE e.val END ORDER BY e.n)
      INTO p_items
      FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(val, n);
  END IF;$r$],
    -- c) CMP-3, apenas corre el motor (antes de tocar stock y costo)
    [$a$    SELECT jsonb_object_agg(l->>'id', l) INTO v_costos_por_linea
      FROM jsonb_array_elements(v_costos->'lineas') l;$a$,
     $r$    SELECT jsonb_object_agg(l->>'id', l) INTO v_costos_por_linea
      FROM jsonb_array_elements(v_costos->'lineas') l;

    /* mig NNN (CMP-3, #1557) · un cargo negativo (una bonificacion prorrateada)
       mayor que su renglon le dejaba el costo real negativo, y el producto
       quedaba con reposicion y promedio negativos. Se rechaza: RAISE y no
       RETURN, porque la compra ya se inserto y el EXCEPTION de abajo la deshace. */
    v_motivo := _compra_costo_real_sin_piso(p_items, v_costos, v_sucursal);
    IF v_motivo IS NOT NULL THEN
      RAISE EXCEPTION 'Los cargos dejan sin costo: %. Un descuento que se prorratea no puede ser mayor que lo que se pagó por el renglón: revisá el monto o a qué líneas se reparte.', v_motivo;
    END IF;$r$]
  ];
  v_n int;
  i int;
BEGIN
  FOR i IN 1 .. array_length(v_par, 1) LOOP
    v_n := (length(v_def) - length(replace(v_def, v_par[i][1], ''))) / length(v_par[i][1]);
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'mig NNN · registrar_compra_completa: el ancla % aparece % vez/veces y se esperaba 1', i, v_n;
    END IF;
    v_def := replace(v_def, v_par[i][1], v_par[i][2]);
  END LOOP;
  EXECUTE v_def;
END
$parche_alta$;

-- ---------------------------------------------------------------------------
-- actualizar_compra_items: la firma nueva (p_renglones_vistos), la versión,
-- cabecera, rangos, costo al centavo y CMP-3
-- ---------------------------------------------------------------------------
DO $parche_edicion$
DECLARE
  v_def text := pg_get_functiondef('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)'::regprocedure);
  v_par text[][] := ARRAY[
    -- la firma
    [$a$p_bonificaciones numeric DEFAULT NULL::numeric)
 RETURNS jsonb$a$,
     $r$p_bonificaciones numeric DEFAULT NULL::numeric, p_renglones_vistos bigint[] DEFAULT NULL::bigint[])
 RETURNS jsonb$r$],
    [$a$  v_pasada           INTEGER;$a$,
     $r$  v_pasada           INTEGER;
  -- mig NNN (#1557)
  v_fuera_de_rango   TEXT;      -- los rangos del renglon (los mismos que el alta)$r$],
    -- FRG-4, la version: con la compra ya tomada y vista viva
    [$a$  IF v_compra.estado = 'cancelada' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se puede editar una compra cancelada');
  END IF;$a$,
     $r$  IF v_compra.estado = 'cancelada' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se puede editar una compra cancelada');
  END IF;

  /* mig NNN (FRG-4, #1557) · LA VERSION DE LA COMPRA. La edicion partia de la
     compra de la lista (cache de 5 minutos) y la segunda de dos ediciones
     reemplazaba todas las lineas con su copia vieja. Cada edicion borra y
     recrea las lineas, asi que sus ids son la version: `p_renglones_vistos` son
     los que el usuario abrio, y tienen que ser los de hoy. La compra ya esta
     tomada FOR UPDATE: una edicion en vuelo termina antes de esta comparacion.
     Sin el parametro (un bundle viejo del PWA) se pide recargar, como los
     guards de cargos e II de la 194. */
  IF p_renglones_vistos IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Actualizá la aplicación (recargá la página) antes de editar esta compra.');
  END IF;
  IF (SELECT COALESCE(array_agg(ci.id ORDER BY ci.id), '{}'::BIGINT[])
        FROM compra_items ci
       WHERE ci.compra_id = p_compra_id AND ci.sucursal_id = v_sucursal)
     IS DISTINCT FROM
     (SELECT COALESCE(array_agg(DISTINCT x ORDER BY x), '{}'::BIGINT[])
        FROM unnest(p_renglones_vistos) AS x) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Alguien la cambió mientras la editabas: guardar pisaría su cambio. Cerrá la compra y volvé a abrirla; tus cambios no se guardaron.');
  END IF;$r$],
    -- CMP-1, la cabecera
    [$a$  /* #1077 · La cabecera es la suma de los renglones$a$,
     $r$  /* mig NNN (CMP-1, #1557) · LOS IMPORTES DE LA CABECERA SON NUMEROS (como
     el alta). */
  IF EXISTS (SELECT 1 FROM unnest(ARRAY[p_subtotal, p_iva, p_total, p_impuestos_internos,
                                        p_percepcion_iva, p_percepcion_iibb, p_no_gravado,
                                        p_otros_impuestos, p_bonificaciones]::NUMERIC[]) AS x
              WHERE x IN ('NaN', 'Infinity', '-Infinity')) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Hay un importe de la cabecera que no es un número. Revisá los importes; si sigue igual, recargá la aplicación y volvé a guardarla.');
  END IF;

  /* #1077 · La cabecera es la suma de los renglones$r$],
    -- los rangos y el costo al centavo, antes del control de cada renglon (482)
    [$a$  /* mig 482 (STK-9, #1516) · EL SUBTOTAL DE CADA RENGLON ES LA CANTIDAD POR EL$a$,
     $r$  /* mig NNN (#1557) · LOS RANGOS DEL RENGLON, los mismos que el alta. La
     edicion no validaba ninguno: una bonificacion de -50 o un costo de -100
     entraban, y ni el alta miraba el II ni la alicuota. */
  v_fuera_de_rango := _compra_renglones_fuera_de_rango(p_items_nuevos, v_sucursal);
  IF v_fuera_de_rango IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Hay renglones fuera de rango: ' || v_fuera_de_rango || '.');
  END IF;

  /* mig NNN (#1557) · los importes de la cabecera no son negativos (ver el alta). */
  IF EXISTS (SELECT 1 FROM unnest(ARRAY[p_subtotal, p_iva, p_total, p_impuestos_internos,
                                        p_percepcion_iva, p_percepcion_iibb, p_no_gravado,
                                        p_otros_impuestos]::NUMERIC[]) AS x
              WHERE x < 0) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Hay un importe de la cabecera negativo: sólo la bonificación de la factura puede serlo. Revisá los importes.');
  END IF;

  /* mig NNN (FRG-1, #1557) · EL COSTO UNITARIO, AL CENTAVO, AL ENTRAR (ver el
     alta). Desde aca todo el cuerpo usa el costo que se guarda. */
  IF jsonb_typeof(p_items_nuevos) = 'array' AND jsonb_array_length(p_items_nuevos) > 0 THEN
    SELECT jsonb_agg(CASE WHEN jsonb_typeof(e.val->'costo_unitario') IN ('number', 'string')
                          THEN jsonb_set(e.val, '{costo_unitario}',
                                         to_jsonb(round((e.val->>'costo_unitario')::NUMERIC, 2)))
                          ELSE e.val END ORDER BY e.n)
      INTO p_items_nuevos
      FROM jsonb_array_elements(p_items_nuevos) WITH ORDINALITY AS e(val, n);
  END IF;

  /* mig 482 (STK-9, #1516) · EL SUBTOTAL DE CADA RENGLON ES LA CANTIDAD POR EL$r$],
    -- CMP-3
    [$a$    SELECT jsonb_object_agg(l->>'id', l) INTO v_costos_por_linea
      FROM jsonb_array_elements(v_costos->'lineas') l;$a$,
     $r$    SELECT jsonb_object_agg(l->>'id', l) INTO v_costos_por_linea
      FROM jsonb_array_elements(v_costos->'lineas') l;

    /* mig NNN (CMP-3, #1557) · ningun renglon queda sin costo por un cargo
       negativo (ver el alta). Antes de tocar stock, costo y lotes. */
    v_motivo := _compra_costo_real_sin_piso(p_items_nuevos, v_costos, v_sucursal);
    IF v_motivo IS NOT NULL THEN
      RAISE EXCEPTION 'Los cargos dejan sin costo: %. Un descuento que se prorratea no puede ser mayor que lo que se pagó por el renglón: revisá el monto o a qué líneas se reparte.', v_motivo;
    END IF;$r$]
  ];
  v_n int;
  i int;
BEGIN
  FOR i IN 1 .. array_length(v_par, 1) LOOP
    v_n := (length(v_def) - length(replace(v_def, v_par[i][1], ''))) / length(v_par[i][1]);
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'mig NNN · actualizar_compra_items: el ancla % aparece % vez/veces y se esperaba 1', i, v_n;
    END IF;
    v_def := replace(v_def, v_par[i][1], v_par[i][2]);
  END LOOP;

  -- Firma nueva: la vieja se va, para que PostgREST no tenga dos sobrecargas (PGRST203).
  DROP FUNCTION public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric);
  EXECUTE v_def;
END
$parche_edicion$;

REVOKE ALL ON FUNCTION public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[]) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4 · COMPRA-C y COMPRA-E: el regalo legal no es una violación
-- ---------------------------------------------------------------------------
DO $parche_auditoria$
DECLARE
  v_def text := pg_get_functiondef('public.auditoria_integridad()'::regprocedure);
  v_a text := $a$    ('COMPRA-C','high','compra_item de compra activa con costo_unitario<=0',
      (SELECT count(*) FROM compra_items ci JOIN compras c ON c.id=ci.compra_id WHERE c.estado<>'cancelada' AND COALESCE(ci.costo_unitario,0)<=0)),
    ('COMPRA-E','medium','bonificación de compra fuera de [0,100)',
      (SELECT count(*) FROM compra_items WHERE bonificacion<0 OR bonificacion>=100)),$a$;
  v_r text := $r$    /* mig NNN (#1557) · el regalo legal (bonificacion 100, con cualquier costo) no cuenta;
       el costo real negativo si (CMP-3), y el costo 0 sin bonificacion del 100 % (CMP-5). */
    ('COMPRA-C','high','compra_item de compra activa con costo o costo real negativo, o que se paga (bonificación < 100) con costo o costo real 0',
      (SELECT count(*) FROM compra_items ci JOIN compras c ON c.id=ci.compra_id WHERE c.estado<>'cancelada'
          AND (COALESCE(ci.costo_unitario,0)<0 OR ci.costo_real_unitario<0
               OR (COALESCE(ci.bonificacion,0)<100 AND (COALESCE(ci.costo_unitario,0)=0 OR ci.costo_real_unitario=0))))),
    ('COMPRA-E','medium','bonificación de compra fuera de [0,100]',
      (SELECT count(*) FROM compra_items WHERE bonificacion<0 OR bonificacion>100)),$r$;
  v_n int;
BEGIN
  v_n := (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · auditoria_integridad: el ancla aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(v_def, v_a, v_r);
END
$parche_auditoria$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, el definer y los EXECUTE quedaron como en el repo,
-- y actualizar_compra_items tiene una sola firma
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public._compra_renglones_fuera_de_rango(jsonb,bigint)', '7c118bfbf192d5c2bd12e1e310cde963', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._compra_costo_real_sin_piso(jsonb,jsonb,bigint)', 'd0c17f7b147cbadb8fedfb6b0c76e572', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)',
     'eedd880741ed76435df7a36011443aff', true, '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[])',
     '5932f8184bc0f0e19ed7ad9fe2d230ae', true, '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.auditoria_integridad()', 'ec5c90af7995f70838e566a34374457b', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}')
  ) AS t(f, h, def, acl) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO x
      FROM pg_proc WHERE oid = r.f::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %)', r.f, x.h, x.a, x.def;
    END IF;
  END LOOP;

  IF (SELECT count(*) FROM pg_proc WHERE proname = 'actualizar_compra_items'
        AND pronamespace = 'public'::regnamespace) <> 1 THEN
    RAISE EXCEPTION 'mig NNN · actualizar_compra_items quedó con más de una firma';
  END IF;
END
$post$;

COMMIT;
