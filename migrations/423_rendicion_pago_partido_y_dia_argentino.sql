-- ============================================================================
-- 423 · Rendición: el pago partido y el día argentino (#1292, #1298)
-- ============================================================================
-- Tarjeta 2 del plan #1306 (cobros y rendición). Aplicada en prod el 2026-10-30
-- como 423 (la 421 y la 422 ya estaban tomadas en el ledger). Aplicar desde el
-- contenido LF.
-- Ensayo: scripts/test-rendicion-congelada-1248.sql (casos K4 a K7) y
-- scripts/test-fechas-utc-1298.sql.
--
-- QUÉ ES ESTO
-- -----------
-- #1292 · Un pago partido se contaba dos veces en una rendición confirmada, o se
--   perdía. `_rendicion_pagos` sacaba de lo vivo todo pago cuya RAÍZ estaba en
--   una foto. Eso está bien para un pedazo que nació DESPUÉS de la foto: su plata
--   ya está en el monto que la foto le guardó a la raíz. Pero un pedazo que ya
--   existía al tomar la foto es un pago aparte. Si la foto lo rindió, sale por su
--   id; si no (era de otro chofer), tiene que seguir vivo:
--     · doble conteo: el FIFO deja un crédito X, se edita una boleta del chofer
--       A y `aplicar_credito_cliente` parte X en un pedazo Y. La foto de A rinde
--       Y, y como X no está en ninguna foto, Y seguía vivo: A figuraba con Y de
--       más.
--     · pérdida: si después la raíz entraba a una foto, el pedazo que ya existía
--       quedaba afuera de todas las rendiciones.
--   Ahora la foto guarda hasta qué id de pago vio (`ultimo_pago_id`), y de lo
--   vivo sale el pago que una foto cerrada rindió, o el pedazo cuya raíz rindió
--   una foto y que nació después de ella (id > `ultimo_pago_id`).
--   Para que "nació después" sea cierto con dos transacciones a la vez, la foto
--   bloquea (FOR SHARE) los pagos del día antes de mirar. Quien parte un pago lo
--   bloquea FOR UPDATE antes de insertar el pedazo (`aplicar_credito_cliente`,
--   `imputar_credito_a_pedido_impl`, `_pagos_excedente_a_favor`): o terminó
--   antes, y la foto ve al padre ya achicado y al pedazo con un id menor o igual
--   al corte; o espera a que el cierre termine, y su pedazo nace con un id mayor.
--   Límite conocido: `pagos` guarda sólo la raíz, no el padre. Un pedazo de un
--   pedazo que se parte después de la foto se mide contra la raíz: si la foto
--   rindió el pedazo intermedio y no la raíz, el nieto sigue vivo. Hoy no hay
--   ningún pedazo en prod.
-- #1298 · El día de una entrega y la hora de una resolución se cortaban en UTC.
--   · `_rendicion_entregas` y `es_entrega_del_dia` (una columna de
--     `_rendicion_pagos`) pasan a
--     `(fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date`. Una
--     entrega a las 22 de Argentina caía en la rendición del día siguiente, y
--     ahora además quedaba congelada en su foto.
--   · `resolver_rendicion` escribía la hora UTC en `observaciones`.
--   · `crear_rendicion_por_fecha` y `cambiar_tipo_factura_pedido` también deciden
--     de qué día es una entrega: el mismo corte, por reemplazo (decisión de la
--     coordinación de #1306). `pedidos_proteger_columnas` y
--     `anular_control_por_cambio_fecha_entrega` ya cortan así desde la 416 de
--     #1308; `cancelar_pedido_con_stock` (tarjeta 6 de #1308) sigue en
--     scripts/fechas-utc-permitidas.json con #1277.
--   · `auditoria_fechas_utc()` ve también `CAST(now() AS date)`, `date(now())`,
--     `date_trunc` por día, semana, mes o año, `to_char` y `extract` sobre now()
--     o sus sinónimos, y los mismos cortes sobre una columna timestamptz; y mira
--     vistas, policies y CHECKs, no sólo funciones y defaults. El gate compara
--     las funciones por firma: una sobrecarga nueva ya no pasa por llevar el
--     nombre de una permitida (scripts/lib/fechasUtc.mjs).
--
-- QUÉ SE TOCA
-- -----------
-- Reescritas enteras, con premisa de md5 sobre el cuerpo vivo (abajo):
--   _rendicion_pagos, _rendicion_tomar_foto, _rendicion_entregas,
--   resolver_rendicion (la de la 413, con la hora argentina) y
--   auditoria_fechas_utc.
-- Parcheadas por reemplazo sobre el cuerpo vivo (md5 antes y después):
--   cambiar_tipo_factura_pedido y crear_rendicion_por_fecha, sólo el corte de día.
-- Tabla: `rendicion_pagos_confirmados.ultimo_pago_id`.
-- No se toca `confirmar_rendicion` (tarjeta 7 de #1308), ninguna función de
-- gastos de la 413, ni `auditoria_integridad()`.
-- ============================================================================

SET LOCAL lock_timeout = '5s';

-- ----------------------------------------------------------------------------
-- 0 · Premisas
-- ----------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
BEGIN
  -- Las funciones que se reescriben son las de prod del 2026-10-29 (la 406, la
  -- 410 y la 413). Si otra migración las cambió en el medio, esta las pisaría
  -- sin avisar: se aborta y se rehace sobre la definición viva.
  FOR r IN SELECT * FROM (VALUES
      ('public._rendicion_pagos(bigint,date,date)',    '967f017f0923a1abb2230b3ba21b6c15'),
      ('public._rendicion_tomar_foto(bigint)',         '7f7b2bbe716fc447ba4b09808d697a6b'),
      ('public._rendicion_entregas(bigint,date,date)', '8538753413d0af72fd9e5dc6e0bb7662'),
      ('public.resolver_rendicion(date,uuid,text)',    '04d541c70520b142959d01590eb87d33'),
      ('public.auditoria_fechas_utc()',                'de6bc28b0e8804c73961de58c3eab44a')) AS v(firma, md5)
  LOOP
    IF to_regprocedure(r.firma) IS NULL
       OR (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure(r.firma)) <> r.md5 THEN
      RAISE EXCEPTION '% no es la de prod del 2026-10-29: rehacer la migracion sobre la definicion viva', r.firma;
    END IF;
  END LOOP;

  -- El corte de las fotos que ya hay es el id más alto de hoy. Vale sólo si
  -- ningún pedazo de un pago rendido nació entre su foto y esta migración: de
  -- ese no se sabría de qué lado del corte cae.
  IF EXISTS (SELECT 1
               FROM public.pagos pg
               JOIN public.rendicion_pagos_confirmados fo ON fo.pago_id = pg.pago_origen_id
               JOIN public.rendiciones_control rc ON rc.id = fo.rendicion_id
              WHERE rc.estado IN ('confirmada', 'resuelta')) THEN
    RAISE EXCEPTION 'hay pedazos de pagos rendidos: decidir a mano de que lado del corte cae cada uno';
  END IF;

  -- Las fotos guardan es_entrega_del_dia y lo entregado con el corte UTC. El
  -- cambio sólo mueve las entregas de 21 a 24 (hora argentina), y ninguna está
  -- en una rendición cerrada: las fotos siguen valiendo.
  IF EXISTS (SELECT 1
               FROM public.pedidos pd
               JOIN public.rendiciones_control rc
                 ON rc.transportista_id = pd.transportista_id
                AND rc.sucursal_id = pd.sucursal_id
                AND rc.estado IN ('confirmada', 'resuelta')
                AND rc.fecha IN (pd.fecha_entrega::date,
                                 (pd.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date)
              WHERE pd.fecha_entrega::date
                    <> (pd.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date)
     OR EXISTS (SELECT 1
                  FROM public.rendicion_pagos_confirmados fo
                  JOIN public.pedidos pd ON pd.id = fo.pedido_id
                 WHERE pd.fecha_entrega::date
                       <> (pd.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date) THEN
    RAISE EXCEPTION 'una rendicion cerrada tiene una entrega de 21 a 24: su foto cambiaria de dia, revisarla antes';
  END IF;
END
$premisas$;

-- ----------------------------------------------------------------------------
-- 1 · #1292 · La foto guarda su corte
-- ----------------------------------------------------------------------------
ALTER TABLE public.rendicion_pagos_confirmados ADD COLUMN ultimo_pago_id bigint;
UPDATE public.rendicion_pagos_confirmados
   SET ultimo_pago_id = (SELECT COALESCE(max(id), 0) FROM public.pagos);
ALTER TABLE public.rendicion_pagos_confirmados ALTER COLUMN ultimo_pago_id SET NOT NULL;
COMMENT ON COLUMN public.rendicion_pagos_confirmados.ultimo_pago_id IS
  'El id de pago más alto que existía al tomar la foto (#1292). Un pedazo de un pago de la foto '
  'con un id mayor nació después: su plata ya está en el monto que la foto le guardó a la raíz, '
  'y no se lee vivo. Un pedazo con un id menor o igual era un pago aparte.';

-- Los pagos de las rendiciones de un rango, con la regla de la foto:
--   · la rendicion cerrada (confirmada o resuelta) lee su foto;
--   · todo pago que ninguna foto rindio se lee vivo, atribuido como siempre
--     (COALESCE(pd.transportista_id, pg.usuario_id)).
-- Un pago rendido sale de lo vivo por su id. Un pedazo sale tambien si su raiz
-- (pago_origen_id) esta en una foto y nacio despues de ella (#1292): su plata
-- ya esta en el monto que la foto le guardo a la raiz. Un pedazo que ya existia
-- al tomar la foto es un pago aparte, rendido o vivo por su cuenta.
-- Asi la plata de una rendicion cerrada no cambia ni se va a otra. Lo unico que
-- se le puede sumar es un pago que ninguna rendicion cerrada rindio (p. ej. un
-- cobro del preventista cuya boleta se le asigna despues a ese chofer). No se
-- pierde ni se cuenta dos veces: o esta en una foto, o esta vivo.
-- Sin nota_credito: no es plata de la rendicion (276). El adelanto de sueldo si
-- viene: el resumen lo muestra aparte (273) y el detalle lo filtra.
-- es_entrega_del_dia corta la entrega en el dia argentino (#1298).
CREATE OR REPLACE FUNCTION public._rendicion_pagos(p_sucursal_id bigint, p_desde date, p_hasta date)
 RETURNS TABLE (
   t_id uuid, f date, pago_id bigint, cliente_id bigint, usuario_id uuid,
   monto numeric, forma_pago text, referencia text, notas text,
   pedido_id bigint, pedido_fecha date, pedido_estado text, pedido_total numeric,
   es_entrega_del_dia boolean, pago_created_at timestamptz, congelado boolean
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
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
  SELECT COALESCE(pd.transportista_id, pg.usuario_id), pg.fecha, pg.id::bigint,
         pg.cliente_id::bigint, pg.usuario_id,
         pg.monto, pg.forma_pago::text, pg.referencia::text, pg.notas,
         pg.pedido_id::bigint, pd.fecha, pd.estado::text, pd.total,
         COALESCE(pg.pedido_id IS NOT NULL
                  AND pd.estado = 'entregado'
                  AND COALESCE((pd.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date,
                               pg.fecha) = pg.fecha, false),
         pg.created_at, false
    FROM pagos pg
    LEFT JOIN pedidos pd ON pd.id = pg.pedido_id
   WHERE pg.sucursal_id = p_sucursal_id
     AND pg.fecha BETWEEN p_desde AND p_hasta
     AND COALESCE(pg.forma_pago, '') <> 'nota_credito'
     AND NOT EXISTS (
       SELECT 1
         FROM rendicion_pagos_confirmados fo
         JOIN rendiciones_control rc ON rc.id = fo.rendicion_id
        WHERE fo.pago_id IN (pg.id, pg.pago_origen_id)
          AND (fo.pago_id = pg.id OR pg.id > fo.ultimo_pago_id)
          AND rc.estado IN ('confirmada', 'resuelta'));
$function$;

CREATE OR REPLACE FUNCTION public._rendicion_tomar_foto(p_rendicion_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  r        RECORD;
  v_ultimo bigint;
BEGIN
  SELECT id, fecha, transportista_id, sucursal_id
    INTO r
    FROM rendiciones_control
   WHERE id = p_rendicion_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  -- Primero se suelta la foto propia (si la habia): sus pagos vuelven a estar
  -- vivos y entran de nuevo si siguen siendo de esta rendicion.
  DELETE FROM rendicion_pagos_confirmados WHERE rendicion_id = r.id;

  -- #1292: los pagos del dia quedan quietos hasta que termine el cierre. Quien
  -- parte uno lo bloquea FOR UPDATE antes de insertar el pedazo: o ya termino,
  -- y la foto ve al padre achicado y al pedazo, o espera y su pedazo nace con un
  -- id mayor que el corte. Con el corte, _rendicion_pagos sabe si un pedazo de
  -- un pago de esta foto ya estaba o nacio de la plata que la foto le guardo.
  PERFORM 1
     FROM pagos
    WHERE sucursal_id = r.sucursal_id
      AND fecha = r.fecha
    ORDER BY id
      FOR SHARE;
  v_ultimo := COALESCE((SELECT max(id) FROM pagos), 0);

  INSERT INTO rendicion_pagos_confirmados (
    rendicion_id, pago_id, cliente_id, usuario_id, monto, forma_pago, referencia, notas,
    pedido_id, pedido_fecha, pedido_estado, pedido_total, es_entrega_del_dia, pago_created_at,
    ultimo_pago_id
  )
  SELECT r.id, v.pago_id, v.cliente_id, v.usuario_id, v.monto, v.forma_pago, v.referencia, v.notas,
         v.pedido_id, v.pedido_fecha, v.pedido_estado, v.pedido_total, v.es_entrega_del_dia,
         v.pago_created_at, v_ultimo
    FROM public._rendicion_pagos(r.sucursal_id, r.fecha, r.fecha) v
   WHERE v.t_id = r.transportista_id
     AND NOT v.congelado;

  UPDATE rendiciones_control rc
     SET total_entregado_confirmado  = COALESCE(e.tot_entregado, 0),
         cantidad_pedidos_confirmada = COALESCE(e.cant, 0)
    FROM (SELECT 1) x
    LEFT JOIN public._rendicion_entregas(r.sucursal_id, r.fecha, r.fecha) e
      ON e.t_id = r.transportista_id
   WHERE rc.id = r.id;
END;
$function$;

-- ----------------------------------------------------------------------------
-- 2 · #1298 · El día argentino
-- ----------------------------------------------------------------------------

-- Lo entregado por chofer y dia: el entregas_agg de obtener_resumen_rendiciones,
-- en un solo lugar para que la foto y el resumen no se separen. El dia de la
-- entrega es el argentino (#1298): fecha_entrega es timestamptz, y ::date pelado
-- corta en UTC.
CREATE OR REPLACE FUNCTION public._rendicion_entregas(p_sucursal_id bigint, p_desde date, p_hasta date)
 RETURNS TABLE (t_id uuid, f date, tot_entregado numeric, cant bigint)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT pd.transportista_id,
         (pd.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date,
         SUM(pd.total)::numeric,
         COUNT(*)::bigint
    FROM pedidos pd
   WHERE pd.estado = 'entregado'
     AND pd.fecha_entrega IS NOT NULL
     AND pd.transportista_id IS NOT NULL
     AND (pd.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date BETWEEN p_desde AND p_hasta
     AND pd.sucursal_id = p_sucursal_id
     -- 3XA (N12): el vale blanco no es mercadería que el transportista tenga que
     -- rendir. Los 75 VB históricos con transportista salen de lo entregado igual
     -- que su pago sale de lo cobrado, así los dos lados bajan juntos.
     AND COALESCE(pd.tipo_factura, 'ZZ') <> 'VB'
   GROUP BY 1, 2;
$function$;

-- La de la 413, con la hora argentina en la marca de observaciones.
CREATE OR REPLACE FUNCTION public.resolver_rendicion(p_fecha date, p_transportista_id uuid, p_observaciones text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_sucursal_id BIGINT;
  v_id BIGINT;
  v_estado_actual TEXT;
  v_obs_previas TEXT;
  v_nombre_usuario TEXT;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no seleccionada';
  END IF;

  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  -- gastos 3: un gasto que se esta guardando desde Gastos sobre esta
  -- rendicion en disconformidad termina antes de que quede resuelta.
  PERFORM public._rendicion_bloquear(ARRAY[public._rendicion_clave(p_transportista_id, p_fecha, v_sucursal_id)]);

  SELECT id, estado, observaciones
    INTO v_id, v_estado_actual, v_obs_previas
  FROM rendiciones_control
  WHERE fecha = p_fecha
    AND transportista_id = p_transportista_id
    AND sucursal_id = v_sucursal_id;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'No existe rendicion para (%, %)', p_fecha, p_transportista_id;
  END IF;

  IF v_estado_actual <> 'disconformidad' THEN
    RAISE EXCEPTION 'Solo se pueden resolver rendiciones en disconformidad (estado actual: %)', v_estado_actual;
  END IF;

  SELECT nombre INTO v_nombre_usuario FROM perfiles WHERE id = auth.uid();

  -- #1298: la hora que lee el encargado es la argentina, no la del servidor.
  UPDATE rendiciones_control
     SET estado = 'resuelta',
         observaciones = COALESCE(v_obs_previas, '')
           || CASE WHEN v_obs_previas IS NOT NULL AND length(v_obs_previas) > 0 THEN E'\n\n' ELSE '' END
           || '[Resuelta por ' || COALESCE(v_nombre_usuario, 'usuario') || ' el '
           || to_char(now() AT TIME ZONE 'America/Argentina/Buenos_Aires', 'DD/MM/YYYY HH24:MI')
           || ']: ' || p_observaciones,
         resuelta_at = now(),
         resuelta_por = auth.uid()
   WHERE id = v_id;

  RETURN v_id;
END;
$fn$;

-- Dos funciones que deciden de qué día es una entrega, fuera de la rendición
-- (decisión de la coordinación de #1306, 2026-10-29). Mismo corte que arriba,
-- por reemplazo sobre el cuerpo vivo: el cuerpo nuevo tiene que ser el viejo con
-- ese reemplazo y nada más.
--   · cambiar_tipo_factura_pedido: el aviso de que la rendición de ese día está
--     cerrada, al pasar un entregado a VB o desde VB.
--   · crear_rendicion_por_fecha: qué entregas entran a la rendición del día.
-- pedidos_proteger_columnas y anular_control_por_cambio_fecha_entrega ya cortan
-- así (416 de #1308). Falta cancelar_pedido_con_stock (tarjeta 6 de #1308, #1277):
-- no deja cancelar un vale blanco entregado con la caja de su día cerrada, y hasta
-- que cambie, para una entrega de 21 a 24 mira el día siguiente.
DO $parche$
DECLARE
  r     record;
  v_src text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('public.cambiar_tipo_factura_pedido(bigint,character varying,uuid)', 'eca0f6c655a41d3c155c399af27397c8',
       'v_pedido.fecha_entrega::date',
       '(v_pedido.fecha_entrega AT TIME ZONE ''America/Argentina/Buenos_Aires'')::date', 2),
      ('public.crear_rendicion_por_fecha(uuid,date)', 'faaa6bc8b1657128f1a8c7f9a623f68b',
       'COALESCE(p.fecha_entrega, p.updated_at)::date',
       '(COALESCE(p.fecha_entrega, p.updated_at) AT TIME ZONE ''America/Argentina/Buenos_Aires'')::date', 2)
    ) AS v(firma, md5, viejo, nuevo, veces)
  LOOP
    SELECT prosrc INTO v_src FROM pg_proc WHERE oid = to_regprocedure(r.firma);
    IF v_src IS NULL OR md5(v_src) <> r.md5 THEN
      RAISE EXCEPTION '% no es la de prod del 2026-10-29: rehacer el parche sobre la definicion viva', r.firma;
    END IF;
    IF (length(v_src) - length(replace(v_src, r.viejo, ''))) / length(r.viejo) <> r.veces THEN
      RAISE EXCEPTION '% no tiene % veces el corte que se reemplaza', r.firma, r.veces;
    END IF;
    EXECUTE replace(pg_get_functiondef(to_regprocedure(r.firma)), r.viejo, r.nuevo);
    IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure(r.firma)) <> md5(replace(v_src, r.viejo, r.nuevo)) THEN
      RAISE EXCEPTION 'el parche de % cambio algo mas que el corte de dia', r.firma;
    END IF;
  END LOOP;
END
$parche$;

-- El gate del dia argentino (#1250, ampliado en #1298). El dia del servidor
-- (UTC) sale de "ahora" (now() y sus sinonimos) o de una columna timestamptz.
-- Pasados a fecha, truncados por calendario, formateados o desarmados sin AT
-- TIME ZONE, cortan en UTC. Las columnas se reconocen por nombre: entran las que
-- son timestamptz en toda relacion de public (fecha, que en una tabla es
-- timestamptz y en quince es date, no entra). Un corte sobre una variable o un
-- parametro timestamptz no se ve.
-- Se miran funciones (sql y plpgsql, por firma), defaults, vistas, policies y
-- CHECKs. Las columnas generadas y los indices no pueden: su expresion tiene que
-- ser inmutable, y ::date sobre un timestamptz no lo es.
CREATE OR REPLACE FUNCTION public.auditoria_fechas_utc()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH ahora(re) AS (VALUES (
    '(\m(now|transaction_timestamp|statement_timestamp|clock_timestamp)\s*\(\s*\)|\mcurrent_timestamp\M)')),
  col(re) AS (
    SELECT '(\w+\.)?\m(' || string_agg(t.attname, '|' ORDER BY t.attname) || ')\M'
      FROM (SELECT a.attname::text AS attname
              FROM pg_attribute a
              JOIN pg_class c ON c.oid = a.attrelid
              JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm')
               AND a.attnum > 0 AND NOT a.attisdropped
             GROUP BY a.attname
            HAVING bool_and(a.atttypid = 'timestamptz'::regtype)) t
  ),
  -- {X} es "ahora" o una columna; {TZ}, que no siga AT TIME ZONE. Las de crudo
  -- leen la unidad, que es un literal: se miran sin quitarlos.
  plantilla(nombre, re, crudo) AS (VALUES
    ('CURRENT_DATE',          '\mcurrent_date\M',                                false),
    ('LOCALTIMESTAMP',        '\mlocaltimestamp\M',                              false),
    ('LOCALTIME',             '\mlocaltime\M',                                   false),
    ('{X}::date',             '{X}\s*\)?\s*::\s*date\M',                         false),
    ('CAST({X} AS date)',     '\mcast\s*\(\s*{X}\s+as\s+date\M',                 false),
    ('date({X})',             '\mdate\s*\(\s*{X}\s*\)',                          false),
    ('to_char({X})',          '\mto_char\s*\(\s*{X}{TZ}',                        false),
    ('date_trunc(dia, {X})',  '\mdate_trunc\s*\(\s*''(day|week|month|quarter|year|decade|century|millennium)''(\s*::\s*text)?\s*,\s*{X}{TZ}', true),
    ('extract({X})',          '(\mextract\s*\(\s*(?!epoch\M)[a-z]+\s+from|\mdate_part\s*\(\s*''(?!epoch'')[a-z]+''(\s*::\s*text)?\s*,)\s*{X}{TZ}', true)
  ),
  pat(nombre, re, crudo) AS (
    SELECT p.nombre, p.re, p.crudo FROM plantilla p WHERE strpos(p.re, '{X}') = 0
    UNION ALL
    SELECT replace(p.nombre, '{X}', x.que),
           replace(replace(p.re, '{X}', x.re), '{TZ}', '(?!\s*at\s+time\s+zone)'),
           p.crudo
      FROM plantilla p
      CROSS JOIN (SELECT 'ahora' AS que, re FROM ahora
                  UNION ALL SELECT 'columna', re FROM col WHERE re IS NOT NULL) x
     WHERE strpos(p.re, '{X}') > 0
  ),
  fn AS (
    -- Sin comentarios de bloque y de línea (crudo), y además sin literales (src).
    -- El de línea se escribe -{2} para que este mismo cuerpo no se corte solo.
    SELECT t.nombre, t.firma, t.crudo, regexp_replace(t.crudo, '''[^'']*''', ' ', 'g') AS src
      FROM (SELECT p.proname::text AS nombre, p.oid::regprocedure::text AS firma,
                   regexp_replace(regexp_replace(p.prosrc, '/\*.*?\*/', ' ', 'g'), '-{2}[^\n]*', ' ', 'g') AS crudo
              FROM pg_proc p
              JOIN pg_namespace n ON n.oid = p.pronamespace
              JOIN pg_language l ON l.oid = p.prolang
             WHERE n.nspname = 'public' AND p.prokind IN ('f', 'p')
               AND l.lanname IN ('sql', 'plpgsql')
               AND NOT EXISTS (SELECT 1 FROM pg_depend d
                                WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')) t
  ),
  hallazgos AS (
    SELECT fn.nombre, fn.firma, array_agg(DISTINCT pat.nombre ORDER BY pat.nombre) AS patrones
      FROM fn JOIN pat ON (CASE WHEN pat.crudo THEN fn.crudo ELSE fn.src END) ~* pat.re
     GROUP BY fn.nombre, fn.firma
  ),
  obj(tipo, nombre, crudo) AS (
    SELECT 'default', c.relname || '.' || a.attname, pg_get_expr(ad.adbin, ad.adrelid)
      FROM pg_attrdef ad
      JOIN pg_class c ON c.oid = ad.adrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_attribute a ON a.attrelid = ad.adrelid AND a.attnum = ad.adnum
     WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
    UNION ALL
    SELECT 'vista', c.relname::text, pg_get_viewdef(c.oid)
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind IN ('v', 'm')
       AND NOT EXISTS (SELECT 1 FROM pg_depend d
                        WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e')
    UNION ALL
    SELECT 'policy', c.relname || '.' || pol.polname,
           concat_ws(' ', pg_get_expr(pol.polqual, pol.polrelid), pg_get_expr(pol.polwithcheck, pol.polrelid))
      FROM pg_policy pol
      JOIN pg_class c ON c.oid = pol.polrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
    UNION ALL
    SELECT 'check', c.relname || '.' || co.conname, pg_get_constraintdef(co.oid)
      FROM pg_constraint co
      JOIN pg_class c ON c.oid = co.conrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND co.contype = 'c'
  ),
  obj_hallazgos AS (
    SELECT o.tipo, o.nombre, o.crudo, array_agg(DISTINCT pat.nombre ORDER BY pat.nombre) AS patrones
      FROM obj o
      JOIN pat ON (CASE WHEN pat.crudo THEN o.crudo
                        ELSE regexp_replace(o.crudo, '''[^'']*''', ' ', 'g') END) ~* pat.re
     GROUP BY o.tipo, o.nombre, o.crudo
  )
  SELECT jsonb_build_object(
    'generado_at', now(),
    'total_funciones', (SELECT count(*) FROM fn),
    'funciones', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                    'nombre', h.nombre, 'firma', h.firma, 'patrones', to_jsonb(h.patrones))
                    ORDER BY h.firma) FROM hallazgos h), '[]'::jsonb),
    'defaults', COALESCE((SELECT jsonb_agg(jsonb_build_object('columna', h.nombre, 'default', h.crudo)
                    ORDER BY h.nombre) FROM obj_hallazgos h WHERE h.tipo = 'default'), '[]'::jsonb),
    'vistas', COALESCE((SELECT jsonb_agg(jsonb_build_object('nombre', h.nombre, 'patrones', to_jsonb(h.patrones))
                    ORDER BY h.nombre) FROM obj_hallazgos h WHERE h.tipo = 'vista'), '[]'::jsonb),
    'policies', COALESCE((SELECT jsonb_agg(jsonb_build_object('nombre', h.nombre, 'patrones', to_jsonb(h.patrones))
                    ORDER BY h.nombre) FROM obj_hallazgos h WHERE h.tipo = 'policy'), '[]'::jsonb),
    'checks', COALESCE((SELECT jsonb_agg(jsonb_build_object('nombre', h.nombre, 'patrones', to_jsonb(h.patrones))
                    ORDER BY h.nombre) FROM obj_hallazgos h WHERE h.tipo = 'check'), '[]'::jsonb)
  );
$function$;

-- ----------------------------------------------------------------------------
-- 3 · Verificación
-- ----------------------------------------------------------------------------
DO $verif$
DECLARE
  v_g     jsonb := public.auditoria_fechas_utc();
  v_mias  text[];
  f       text;
BEGIN
  IF NOT (v_g ? 'vistas' AND v_g ? 'policies' AND v_g ? 'checks') OR (v_g->>'total_funciones')::int = 0 THEN
    RAISE EXCEPTION 'auditoria_fechas_utc() no quedo como se esperaba: %', v_g - 'funciones';
  END IF;

  -- Lo de esta tarjeta ya no corta en UTC.
  SELECT array_agg(x->>'firma') INTO v_mias
    FROM jsonb_array_elements(v_g->'funciones') x
   WHERE x->>'nombre' IN ('_rendicion_pagos', '_rendicion_tomar_foto', '_rendicion_entregas',
                          'resolver_rendicion', 'registrar_pagos_pedido', 'registrar_pagos_pedido_impl',
                          '_forma_pago_de_cobro', 'auditoria_fechas_utc',
                          'cambiar_tipo_factura_pedido', 'crear_rendicion_por_fecha');
  IF v_mias IS NOT NULL THEN
    RAISE EXCEPTION 'siguen cortando en UTC: %', v_mias;
  END IF;

  -- Lo que ve y lo que no, caso por caso, en scripts/test-fechas-utc-1298.sql.
  -- Aca, que lo bien escrito no salga.
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_g->'funciones') x WHERE x->>'nombre' = '_tablero_hoy') THEN
    RAISE EXCEPTION '_tablero_hoy() salio en el gate: el AT TIME ZONE no se esta respetando';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_attribute
                  WHERE attrelid = 'public.rendicion_pagos_confirmados'::regclass
                    AND attname = 'ultimo_pago_id' AND attnotnull) THEN
    RAISE EXCEPTION 'rendicion_pagos_confirmados.ultimo_pago_id no quedo NOT NULL';
  END IF;

  -- Los permisos de la 406, la 410 y la 413 siguen: CREATE OR REPLACE los conserva.
  FOREACH f IN ARRAY ARRAY['public._rendicion_pagos(bigint,date,date)', 'public._rendicion_tomar_foto(bigint)',
                           'public._rendicion_entregas(bigint,date,date)', 'public.auditoria_fechas_utc()'] LOOP
    IF has_function_privilege('anon', f, 'EXECUTE') OR has_function_privilege('authenticated', f, 'EXECUTE') THEN
      RAISE EXCEPTION '% quedo alcanzable desde el front', f;
    END IF;
  END LOOP;
  IF has_function_privilege('anon', 'public.resolver_rendicion(date,uuid,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.resolver_rendicion(date,uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'los EXECUTE de resolver_rendicion no quedaron como se esperaba';
  END IF;
END
$verif$;
