-- =========================================================================
-- NNN · T4a · CADA COBRO ES DE LA CAJA DE QUIEN LO COBRÓ: LA COLUMNA, EL RELLENO Y LA RENDICIÓN
-- (ola 3 de #1603, tanda T4; D1 de #1507, #1710, D8 de #1690)
--
-- Es la primera de tres, que se aplican en orden y dejan la base consistente cada una:
--   T4a (esta) · pagos.cobrado_por, su trigger y su relleno; D8; _rendicion_pagos; la rendición
--                de un encargado la confirma un admin.
--   T4b        · las RPCs de cobro con p_cobrado_por (quién cobró, que elige el admin).
--   T4c        · lo que paga el cliente contra un faltante, y corregir un cobro en la rendición.
-- Con sólo la T4a, las RPCs de cobro siguen como hoy y el trigger les pone la regla de antes, así
-- que nadie cambia de caja.
--
-- Ensayo: scripts/test-ola3-t4-cobro-de-quien.sql (pide las tres; sin ellas falla en A1; con
-- ellas, ENSAYO OK). Se aplica en LF, sobre la 555.
--
-- El problema: _rendicion_pagos le daba al chofer de la boleta todo cobro que no viniera de saldo
-- a favor, lo hubiera cobrado él o la oficina. El dueño se calculaba al leer, con el chofer que la
-- boleta tuviera ese día: un FIFO de la ficha, el cobro del alta o el cambio de chofer movían plata
-- de una caja a otra con el día abierto (#1507, REN-1 y RUT-1).
--
-- Decisiones del dueño (26/11): lo que cobra el chofer va siempre a su caja; lo que cobra el
-- encargado o el admin en la oficina, a la de quien lo cargó (también el pago a cuenta de la
-- ficha); lo que la oficina carga al marcar una entrega con un chofer elegido es del chofer; el
-- admin puede elegir quién cobró. Lo que cobra el encargado arma su rendición, que confirma un
-- admin. Una rendición en disconformidad cuenta como cerrada para lo que llega después (D8).
--
-- 1 · pagos.cobrado_por: de qué caja es el cobro. Se fija al cobrar y no se mueve con la boleta
--     (ni con el cambio de chofer, ni con desimputar_pago, ni con el cambio de cliente). Lo pone el
--     server: las RPCs de cobro (T4b) con _cobrador_de_cobro (el que llama; el admin elige a
--     cualquier usuario activo de la sucursal; el encargado sólo al chofer de la boleta), y el
--     trigger trg_pagos_zz_cobrado_por para el resto: un pedazo es de la caja de su padre (es la
--     misma plata), y lo que no eligió nadie, la regla de antes. Sin FK a perfiles A PROPÓSITO:
--     pagos ya tiene una (usuario_id) y la segunda daría PGRST201 en `usuario:perfiles(...)` de la
--     ficha, también en los bundles viejos (Trampa 5); el trigger valida que sea un perfil. Nadie
--     lo escribe por REST (pagos no tiene INSERT ni UPDATE para authenticated), y se lee con el `*`.
--     Rend-B5 (un pago sin chofer ni usuario quedaba fuera de toda rendición): un cobro que entra
--     con una sesión siempre tiene dueño (sin usuario ni chofer, el de la sesión). Sin sesión (un
--     script del server) puede seguir sin dueño: ningún camino del server carga cobros hoy. No va
--     como CHECK: los ensayos y los arreglos de datos cargan pagos como postgres. Los 56 de prod sin
--     dueño son de febrero y quedan como están.
-- 2 · Los pagos de antes: cobrado_por = el dueño que les daba _rendicion_pagos hoy. NINGÚN pago
--     cambia de caja (medido en prod el 26/11: con la regla nueva aplicada para atrás cambiarían
--     6.200 pagos vivos, $ 220.049.474, casi todos cargados por un admin a nombre del chofer; no hay
--     cómo distinguirlos de un cobro de mostrador). Las rendiciones confirmadas siguen con su foto.
-- 3 · _rendicion_pagos: el dueño es cobrado_por. D8: una disconformidad cuenta como cerrada para
--     el cobro que llega después (cargado, su raíz, después de rendiciones_control.disconformidad_at,
--     que pone un trigger): va al día siguiente al último cerrado de su dueño, como un día
--     confirmado (#1328). Lo que ya estaba sigue vivo en la disconformidad, así un error se corrige
--     antes de resolver; un pedazo va con su raíz. La foto al confirmarla o resolverla respeta el corte.
-- 4 · La rendición de un encargado la confirma un admin (confirmar_rendicion, parcheada por ancla).
--
-- PREMISAS: los cuerpos de la 555 (md5 de prosrc) de _rendicion_pagos y confirmar_rendicion, y que
-- las columnas nuevas no existan. Las funciones existentes se parchean por ancla, como la 548: se
-- lee el cuerpo vivo, se reemplazan sus anclas (cada una, exactamente las veces esperadas) y se
-- ejecuta.
--
-- LOCKS: SHARE ROW EXCLUSIVE NOWAIT sobre pagos y rendiciones_control (ADD COLUMN y el UPDATE del
-- relleno). El relleno toca cada pago una vez (dispara audit_pagos: una fila de auditoría por pago).
--
-- Revertir (después de revertir la T4b y la T4c): volver _rendicion_pagos y confirmar_rendicion a
-- los cuerpos de las premisas, DROP de los triggers y funciones nuevos, DROP COLUMN
-- pagos.cobrado_por y rendiciones_control.disconformidad_at.
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

LOCK TABLE public.pagos, public.rendiciones_control IN SHARE ROW EXCLUSIVE MODE NOWAIT;

DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public._rendicion_pagos(bigint,date,date,bigint)', '25f0aebcefe469fdc1a6e5205ea83efa'),
    ('public.confirmar_rendicion(date,uuid,text,jsonb,text)', '87ecb9b67b87ffa0d29afa0043e019b8')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;

  IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.pagos'::regclass AND attname = 'cobrado_por')
     OR EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.rendiciones_control'::regclass
                  AND attname = 'disconformidad_at') THEN
    RAISE EXCEPTION 'mig NNN · una columna nueva ya existe';
  END IF;
END
$premisas$;

-- Parche por ancla: cada ancla tiene que aparecer exactamente las veces que se espera.
CREATE FUNCTION pg_temp.t4_parche(p_def text, p_viejo text, p_nuevo text, p_veces int)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  n int := (length(p_def) - length(replace(p_def, p_viejo, ''))) / length(p_viejo);
BEGIN
  IF n <> p_veces THEN
    RAISE EXCEPTION 'mig NNN · un ancla aparece % veces (esperaba %): %', n, p_veces, left(p_viejo, 100);
  END IF;
  RETURN replace(p_def, p_viejo, p_nuevo);
END
$f$;

-- -------------------------------------------------------------------------
-- 1 · pagos.cobrado_por, con el dueño de hoy
-- -------------------------------------------------------------------------
ALTER TABLE public.pagos ADD COLUMN cobrado_por uuid;
COMMENT ON COLUMN public.pagos.cobrado_por IS
  'T4 (#1710): de qué caja (rendición) es el cobro. Lo pone el server al cobrar y no sigue a la boleta. Sin FK a propósito (PGRST201 con pagos_usuario_id_fkey): lo valida trg_pagos_zz_cobrado_por.';

-- El dueño que les daba _rendicion_pagos hasta la 555: nadie cambia de caja. El crédito de una NC
-- no es de ninguna rendición y queda sin dueño.
UPDATE public.pagos pg
   SET cobrado_por = CASE WHEN pg.de_saldo_a_favor THEN pg.usuario_id
                          ELSE COALESCE((SELECT pd.transportista_id FROM public.pedidos pd WHERE pd.id = pg.pedido_id),
                                        pg.usuario_id) END
 WHERE COALESCE(pg.forma_pago, '') <> 'nota_credito';

CREATE INDEX pagos_cobrado_por_idx ON public.pagos (sucursal_id, cobrado_por, fecha);

CREATE FUNCTION public.pagos_cobrado_por()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path = public, pg_temp
AS $function$
DECLARE
  v uuid;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    -- Nadie escribe pagos por REST; esto es por si algún día se abre.
    IF current_user = 'authenticated' THEN
      RAISE EXCEPTION 'Quién cobró lo corrige un admin desde la rendición' USING ERRCODE = '42501';
    END IF;
  ELSE
    -- Un pedazo es la misma plata que su padre: es de su caja, mande lo que mande quien lo parte.
    IF NEW.pago_padre_id IS NOT NULL THEN
      SELECT p.cobrado_por INTO v FROM public.pagos p WHERE p.id = NEW.pago_padre_id;
      IF v IS NOT NULL THEN
        NEW.cobrado_por := v;
      END IF;
    END IF;
    -- Sin elegir: un camino que no es una RPC de cobro (todas lo eligen; un arreglo de datos, un
    -- script). La regla de antes de la T4: el chofer de la boleta, o quien lo cargó; lo que llega
    -- desde saldo a favor, de quien lo cargó. Y Rend-B5: si así no es de nadie, del de la sesión.
    IF NEW.cobrado_por IS NULL AND COALESCE(NEW.forma_pago, '') <> 'nota_credito' THEN
      NEW.cobrado_por := COALESCE(
        CASE WHEN NEW.de_saldo_a_favor THEN NEW.usuario_id
             ELSE COALESCE((SELECT pd.transportista_id FROM public.pedidos pd WHERE pd.id = NEW.pedido_id),
                           NEW.usuario_id) END,
        auth.uid());
    END IF;
  END IF;
  IF NEW.cobrado_por IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.perfiles pe WHERE pe.id = NEW.cobrado_por) THEN
    RAISE EXCEPTION 'Quien cobró no es un usuario' USING ERRCODE = '23503';
  END IF;
  RETURN NEW;
END
$function$;
REVOKE ALL ON FUNCTION public.pagos_cobrado_por() FROM PUBLIC, anon, authenticated;

-- zz: después de trg_pagos_forzar_usuario y de trg_pagos_marcar_saldo_a_favor.
CREATE TRIGGER trg_pagos_zz_cobrado_por
  BEFORE INSERT OR UPDATE OF cobrado_por ON public.pagos
  FOR EACH ROW EXECUTE FUNCTION public.pagos_cobrado_por();

-- Quién cobró, para una RPC de cobro.
CREATE FUNCTION public._cobrador_de_cobro(p_cobrado_por uuid, p_sucursal_id bigint, p_chofer_de_la_boleta uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE
 SET search_path = public, pg_temp
AS $function$
DECLARE
  v_yo uuid := auth.uid();
BEGIN
  IF p_cobrado_por IS NULL OR p_cobrado_por = v_yo THEN
    RETURN v_yo;
  END IF;
  -- El admin elige a cualquiera, como elige quién entregó. El encargado carga a su nombre o, al
  -- marcar la entrega o la parada, al del chofer de la boleta.
  IF NOT public.es_admin()
     AND NOT (public.es_encargado_o_admin() AND p_chofer_de_la_boleta IS NOT NULL
              AND p_cobrado_por = p_chofer_de_la_boleta) THEN
    RAISE EXCEPTION 'Sólo un admin elige quién cobró: el encargado carga a su nombre o al del chofer de la boleta'
      USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.perfiles pe
                   JOIN public.usuario_sucursales us ON us.usuario_id = pe.id AND us.sucursal_id = p_sucursal_id
                  WHERE pe.id = p_cobrado_por AND COALESCE(pe.activo, true)) THEN
    RAISE EXCEPTION 'Quien cobró tiene que ser un usuario activo de esta sucursal' USING ERRCODE = '22023';
  END IF;
  RETURN p_cobrado_por;
END
$function$;
REVOKE ALL ON FUNCTION public._cobrador_de_cobro(uuid, bigint, uuid) FROM PUBLIC, anon, authenticated;

-- -------------------------------------------------------------------------
-- 3 · D8: desde cuándo una rendición está en disconformidad
-- -------------------------------------------------------------------------
ALTER TABLE public.rendiciones_control ADD COLUMN disconformidad_at timestamptz;
COMMENT ON COLUMN public.rendiciones_control.disconformidad_at IS
  'T4 (D8 de #1690): desde cuándo está en disconformidad. Un cobro (raíz) creado después no entra en ella: va al día siguiente, como en un día cerrado. Se conserva al confirmarla o resolverla.';

-- Las dos de prod: desde que se marcaron.
UPDATE public.rendiciones_control SET disconformidad_at = controlada_at
 WHERE estado = 'disconformidad';
UPDATE public.rendiciones_control SET disconformidad_at = created_at
 WHERE estado = 'disconformidad' AND disconformidad_at IS NULL;

CREATE FUNCTION public.rendicion_control_disconformidad_at()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path = public, pg_temp
AS $function$
BEGIN
  IF NEW.estado = 'disconformidad' THEN
    -- La primera vez. Volver de una resuelta (deshacer) o de una confirmada conserva el corte.
    NEW.disconformidad_at := COALESCE(NEW.disconformidad_at, now());
  ELSIF NEW.estado = 'pendiente'
        OR (NEW.estado = 'confirmada' AND (TG_OP = 'INSERT' OR OLD.estado = 'pendiente')) THEN
    NEW.disconformidad_at := NULL;
  END IF;
  RETURN NEW;
END
$function$;
REVOKE ALL ON FUNCTION public.rendicion_control_disconformidad_at() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_rendiciones_control_disconformidad_at
  BEFORE INSERT OR UPDATE OF estado ON public.rendiciones_control
  FOR EACH ROW EXECUTE FUNCTION public.rendicion_control_disconformidad_at();

CREATE OR REPLACE FUNCTION public._rendicion_pagos(p_sucursal_id bigint, p_desde date, p_hasta date, p_foto_de bigint DEFAULT NULL::bigint)
 RETURNS TABLE(t_id uuid, f date, pago_id bigint, cliente_id bigint, usuario_id uuid, monto numeric, forma_pago text, referencia text, notas text, pedido_id bigint, pedido_fecha date, pedido_estado text, pedido_total numeric, es_entrega_del_dia boolean, pago_created_at timestamp with time zone, congelado boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  -- #1328: p_foto_de es la rendicion que esta tomando su foto. El trigger corre
  -- con ella ya confirmada y su dia, para ella, sigue abierto.
  -- T4 (D8): una disconformidad cuenta como cerrada para la raíz que llega después de
  -- disconformidad_at (desde). La rendición que toma su foto viniendo de una disconformidad
  -- mantiene ese corte. desde NULL: cerrada para todo.
  WITH RECURSIVE cerradas AS MATERIALIZED (
    SELECT rc.transportista_id, rc.fecha,
           CASE WHEN rc.estado = 'disconformidad' OR rc.id = p_foto_de THEN rc.disconformidad_at END AS desde
      FROM rendiciones_control rc
     WHERE rc.sucursal_id = p_sucursal_id
       AND rc.estado IN ('confirmada', 'resuelta', 'disconformidad')
       AND CASE WHEN rc.estado = 'disconformidad' OR rc.id = p_foto_de
                THEN rc.disconformidad_at IS NOT NULL ELSE true END
  ),
  -- #1359/#1369: cada pedazo de la sucursal con cada uno de sus ancestros, y el
  -- hijo de ese ancestro en la cadena. Se sube por el padre: la raiz no alcanza,
  -- el pedazo pudo salir de otro pedazo.
  cadena (pago_id, ancestro_id, hijo_id) AS (
    SELECT p.id::bigint, p.pago_padre_id, p.id::bigint
      FROM pagos p
     WHERE p.sucursal_id = p_sucursal_id
       AND p.pago_padre_id IS NOT NULL
    UNION ALL
    SELECT c.pago_id, a.pago_padre_id, c.ancestro_id
      FROM cadena c
      JOIN pagos a ON a.id = c.ancestro_id
     WHERE a.pago_padre_id IS NOT NULL
  ),
  -- Un pedazo esta rendido si una foto tiene al ancestro que guardaba su plata al
  -- corte: el ultimo de la cadena que ya existia, o sea el que tiene a su hijo en
  -- la cadena despues del corte (los ids crecen por la cadena).
  rendidos_por_cadena AS MATERIALIZED (
    SELECT DISTINCT c.pago_id
      FROM cadena c
      JOIN rendicion_pagos_confirmados fo ON fo.pago_id = c.ancestro_id
      JOIN rendiciones_control rc ON rc.id = fo.rendicion_id
     WHERE c.hijo_id > fo.ultimo_pago_id
       AND rc.estado IN ('confirmada', 'resuelta')
  )
  SELECT rc.transportista_id, rc.fecha, fo.pago_id, fo.cliente_id, fo.usuario_id,
         fo.monto, fo.forma_pago, fo.referencia, fo.notas,
         fo.pedido_id, fo.pedido_fecha, fo.pedido_estado, fo.pedido_total,
         fo.es_entrega_del_dia, fo.pago_created_at, true
    FROM rendiciones_control rc
    JOIN rendicion_pagos_confirmados fo ON fo.rendicion_id = rc.id
   WHERE rc.sucursal_id = p_sucursal_id
     AND rc.fecha BETWEEN p_desde AND p_hasta
     AND rc.estado IN ('confirmada', 'resuelta')
  UNION ALL
  SELECT dueno.t, COALESCE(dia.abierto, pg.fecha), pg.id::bigint,
         pg.cliente_id::bigint, pg.usuario_id,
         pg.monto, pg.forma_pago::text, pg.referencia::text, pg.notas,
         pg.pedido_id::bigint, pd.fecha, pd.estado::text, pd.total,
         COALESCE(pg.pedido_id IS NOT NULL
                  AND dia.abierto IS NULL
                  AND pd.estado = 'entregado'
                  AND COALESCE((pd.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date,
                               pg.fecha) = pg.fecha, false),
         pg.created_at, false
    FROM pagos pg
    LEFT JOIN pedidos pd ON pd.id = pg.pedido_id
    -- T4 (#1710, D1 de #1507): el cobro es de la caja de quien lo cobró (pagos.cobrado_por),
    -- que se fija al cobrar y no sigue a la boleta. La regla de antes queda para un pago sin
    -- dueño (los de antes de la T4 que no tenían ni chofer ni usuario).
   CROSS JOIN LATERAL (SELECT COALESCE(pg.cobrado_por,
                                       CASE WHEN pg.de_saldo_a_favor THEN pg.usuario_id
                                            ELSE COALESCE(pd.transportista_id, pg.usuario_id) END) AS t) dueno
    -- #1328: el dia del pago esta cerrado para su chofer y la foto no lo tiene: va
    -- al dia siguiente al ultimo que cerro ese chofer, no a un hueco viejo.
    -- T4 (D8): una disconformidad cuenta para el cobro que llegó después de su corte: el que se
    -- cargó después (su raíz). Un pedazo es la plata de su raíz: si la raíz llegó antes, el pedazo
    -- (aunque nazca después, de una salvedad o un crédito) sigue en la disconformidad; si llegó
    -- después, va con ella al día siguiente. Una raíz borrada no cuenta como llegada después.
   CROSS JOIN LATERAL (SELECT CASE WHEN pg.pago_origen_id IS NULL THEN pg.created_at
                                   ELSE (SELECT r.created_at FROM pagos r WHERE r.id = pg.pago_origen_id) END
                                AS llego) raiz
    LEFT JOIN LATERAL (
      SELECT max(c.fecha) + 1 AS abierto
        FROM cerradas c
       WHERE c.transportista_id = dueno.t
         AND (c.desde IS NULL OR raiz.llego > c.desde)
         AND EXISTS (SELECT 1 FROM cerradas d
                      WHERE d.transportista_id = dueno.t AND d.fecha = pg.fecha
                        AND (d.desde IS NULL OR raiz.llego > d.desde))
    ) dia ON true
   WHERE pg.sucursal_id = p_sucursal_id
     AND pg.fecha <= p_hasta
     AND COALESCE(dia.abierto, pg.fecha) BETWEEN p_desde AND p_hasta
     AND COALESCE(pg.forma_pago, '') <> 'nota_credito'
     AND NOT EXISTS (
       SELECT 1
         FROM rendicion_pagos_confirmados fo
         JOIN rendiciones_control rc ON rc.id = fo.rendicion_id
        WHERE fo.pago_id = pg.id
          AND rc.estado IN ('confirmada', 'resuelta'))
     AND NOT EXISTS (SELECT 1 FROM rendidos_por_cadena r WHERE r.pago_id = pg.id);
$function$;

-- confirmar_rendicion
DO $t4$
DECLARE
  v text := pg_get_functiondef('public.confirmar_rendicion(date,uuid,text,jsonb,text)'::regprocedure);
BEGIN
  v := pg_temp.t4_parche(v, $o$    RAISE EXCEPTION 'Tu rendición la confirma otro encargado o un admin'
      USING ERRCODE = '42501';
  END IF;
$o$,
    $n$    RAISE EXCEPTION 'Tu rendición la confirma otro encargado o un admin'
      USING ERRCODE = '42501';
  END IF;

  -- T4 (#1710): lo que cobra un encargado arma su rendición, y ésa la confirma un admin, nunca
  -- otro encargado. Es el rol de la persona, no el de la rendición.
  IF NOT es_admin() AND EXISTS (SELECT 1 FROM perfiles pe
                                 WHERE pe.id = p_transportista_id AND pe.rol = 'encargado') THEN
    RAISE EXCEPTION 'La rendición de un encargado la confirma un admin'
      USING ERRCODE = '42501';
  END IF;
$n$, 1);
  EXECUTE v;
END
$t4$;

-- -------------------------------------------------------------------------
-- Poscondiciones
-- -------------------------------------------------------------------------
DO $pos$
DECLARE
  v bigint;
BEGIN
  -- Nadie cambió de caja: el dueño nuevo es el de antes.
  SELECT count(*) INTO v FROM pagos pg
   WHERE COALESCE(pg.forma_pago, '') <> 'nota_credito'
     AND pg.cobrado_por IS DISTINCT FROM
         CASE WHEN pg.de_saldo_a_favor THEN pg.usuario_id
              ELSE COALESCE((SELECT pd.transportista_id FROM pedidos pd WHERE pd.id = pg.pedido_id), pg.usuario_id) END;
  IF v <> 0 THEN
    RAISE EXCEPTION 'mig NNN · poscondición: % pagos cambiarían de caja', v;
  END IF;
  IF EXISTS (SELECT 1 FROM rendiciones_control WHERE estado = 'disconformidad' AND disconformidad_at IS NULL) THEN
    RAISE EXCEPTION 'mig NNN · poscondición: una disconformidad sin su corte';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p
              WHERE p.pronamespace = 'public'::regnamespace
                AND p.proname IN ('_cobrador_de_cobro', 'pagos_cobrado_por', 'rendicion_control_disconformidad_at')
                AND (has_function_privilege('anon', p.oid, 'EXECUTE')
                     OR has_function_privilege('authenticated', p.oid, 'EXECUTE'))) THEN
    RAISE EXCEPTION 'mig NNN · poscondición: una función de server quedó con EXECUTE para anon o authenticated';
  END IF;
  IF (SELECT count(*) FROM pg_constraint WHERE conrelid = 'public.pagos'::regclass AND contype = 'f'
        AND conkey @> ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid = 'public.pagos'::regclass
                                AND attname = 'cobrado_por')]) <> 0 THEN
    RAISE EXCEPTION 'mig NNN · poscondición: pagos.cobrado_por no lleva FK (PGRST201)';
  END IF;
  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.confirmar_rendicion(date,uuid,text,jsonb,text)'::regprocedure)
     !~ 'La rendición de un encargado la confirma un admin' THEN
    RAISE EXCEPTION 'mig NNN · poscondición: confirmar_rendicion sin la regla del encargado';
  END IF;
END
$pos$;

COMMIT;
