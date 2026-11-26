-- =========================================================================
-- NNN · CADA COBRO VA A LA CAJA DE QUIEN LO COBRÓ (ola 3 de #1603, tanda T4; D1 de #1507,
-- #1710, D8 de #1690)
--
-- Ensayo: scripts/test-ola3-t4-cobro-de-quien.sql (sin esta migración falla en A1; con ella,
-- ENSAYO OK). Se aplica en LF, sobre la 555.
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
-- admin. Un pago que después cubre lo que le faltó al chofer va contra su faltante. Una
-- rendición en disconformidad cuenta como cerrada para lo que llega después (D8).
--
-- 1 · pagos.cobrado_por: de qué caja es el cobro. Se fija al cobrar y no se mueve con la boleta
--     (ni con el cambio de chofer, ni con desimputar_pago, ni con el cambio de cliente). Lo pone el
--     server: las RPCs de cobro con _cobrador_de_cobro (el que llama; el admin elige a cualquier
--     usuario activo de la sucursal; el encargado sólo al chofer de la boleta, que es cargar la
--     entrega o la parada a su nombre), la entrega y pago masivos con el chofer elegido, y el
--     trigger trg_pagos_zz_cobrado_por para el resto: un pedazo es de la caja de su padre (es la
--     misma plata), y lo que no eligió nadie (un arreglo de datos), la regla de antes. Sin FK a
--     perfiles A PROPÓSITO: pagos ya tiene una
--     (usuario_id) y la segunda daría PGRST201 en `usuario:perfiles(...)` de la ficha, también en los
--     bundles viejos (Trampa 5); el trigger valida que sea un perfil. Nadie lo escribe por REST
--     (pagos no tiene INSERT ni UPDATE para authenticated), y se lee con el `*` de siempre.
--     Rend-B5 (un pago sin chofer ni usuario quedaba fuera de toda rendición): un cobro que entra
--     con una sesión siempre tiene dueño (si no lo cargó nadie ni tiene chofer, el de la sesión).
--     Sin sesión (un script del server) puede seguir sin dueño: no hay a quién dárselo, y ningún
--     camino del server carga cobros hoy. No va como CHECK: los ensayos y los arreglos de datos cargan
--     pagos como postgres. Los 56 de prod sin dueño son de febrero y quedan como están.
-- 2 · Los pagos de antes: cobrado_por = el dueño que les daba _rendicion_pagos hoy. NINGÚN pago
--     cambia de caja con esta migración (medido en prod el 26/11: con la regla nueva aplicada para
--     atrás cambiarían 6.200 pagos vivos, $ 220.049.474, casi todos cargados por un admin a nombre
--     del chofer; no hay cómo distinguirlos de un cobro de mostrador, así que se congela lo de hoy).
--     Las rendiciones confirmadas siguen leyendo su foto.
-- 3 · _rendicion_pagos: el dueño es cobrado_por. D8: una disconformidad cuenta como cerrada para
--     el cobro que llega después (una raíz creada después de rendiciones_control.disconformidad_at,
--     que pone un trigger): va al día siguiente al último cerrado de su dueño, como un día confirmado
--     (#1328). Lo que ya estaba sigue vivo en la disconformidad, así un error se corrige antes de
--     resolver. Un pedazo no cuenta como llegado después: su padre se achicó en la misma rendición.
--     La foto de la disconformidad que se confirma o se resuelve respeta ese corte.
-- 4 · Las RPCs de cobro reciben p_cobrado_por (al final, con default: un bundle viejo sigue
--     andando y cobra a nombre de quien llama). Cambian en el _impl; el wrapper lo suma a
--     p_contenido sólo si viene, así el contenido de una solicitud de antes no cambia. Se sacan las
--     firmas viejas (PGRST203).
-- 5 · La rendición de un encargado la confirma un admin (confirmar_rendicion).
-- 6 · corregir_cobro_rendicion: corrige la forma de pago (admin; el encargado, en una rendición
--     abierta que no es la suya ni de otro encargado) y quién cobró (admin), con motivo, en una
--     rendición abierta o en disconformidad (sólo admin). Deja la marca en las notas del pago y en
--     el historial del pedido, y audit_pagos guarda el antes y el después.
-- 7 · cobrar_faltante_rendicion: lo que el cliente paga después contra el faltante que se le cargó
--     a un empleado (sólo admin, que es quien maneja el personal). No es un cobro: la boleta ya
--     figura cobrada. Le baja la deuda al empleado (un movimiento positivo con recupera_faltante_id)
--     y, si es efectivo, entra en la caja de quien lo recibió ese día (tipo 'faltante' positivo en
--     su rendición, que suma al efectivo a entregar). Por otra forma, un ajuste sin rendición.
--     anular_cobro_faltante lo deshace mientras esa caja esté abierta. Deshacer la resolución del
--     chofer con algo cobrado contra su faltante se rechaza.
--
-- PREMISAS: los cuerpos vivos de la 555 (md5 de prosrc) de las funciones que se reemplazan, que
-- las columnas nuevas no existan, y el CHECK de altas_por_clave vigente.
--
-- LOCKS: SHARE ROW EXCLUSIVE NOWAIT sobre pagos y rendiciones_control (ADD COLUMN y el UPDATE del
-- relleno). El relleno toca cada pago una vez (dispara audit_pagos: una fila de auditoría por pago).
--
-- Revertir: volver las funciones a los cuerpos de las premisas (con sus firmas), DROP de las
-- funciones y triggers nuevos, DROP COLUMN pagos.cobrado_por,
-- rendiciones_control.disconformidad_at, empleado_movimientos.recupera_faltante_id y sus CHECK,
-- y el CHECK de altas_por_clave sin 'cobro_faltante' (si no hay filas).
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

-- -------------------------------------------------------------------------
-- Premisas
-- -------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public._rendicion_pagos(bigint,date,date,bigint)', '25f0aebcefe469fdc1a6e5205ea83efa'),
    ('public.anular_salvedad(bigint,text)', '66c0f0cf009d3ac552fba2e7046390c5'),
    ('public.auditoria_definer_sin_rol()', '7cc70e175cb0053031fccea759477348'),
    ('public.confirmar_rendicion(date,uuid,text,jsonb,text)', '87ecb9b67b87ffa0d29afa0043e019b8'),
    ('public.desafectar_sobrepago_pedido(bigint)', 'b038256f1acf602b0ed20475215a3080'),
    ('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)', 'c83df3208d9b057fff7877dd519e1516'),
    ('public.marcar_pagos_masivo(bigint[],text,date,uuid)', '1f13baa2aaba49f787c2198fb774e586'),
    ('public.marcar_pagos_masivo_impl(bigint[],text,date)', 'd3a11592bf22f97275b9bd98ece355b7'),
    ('public.obtener_faltantes_rendiciones(date,date,uuid)', 'febc22280482b1420e9d36104420071c'),
    ('public.registrar_pago_cliente_fifo(bigint,numeric,text,date,text,text,uuid)', '3dd754478ee59e15e14cbeaad3d3e308'),
    ('public.registrar_pago_cliente_fifo_impl(bigint,numeric,text,date,text,text)', 'e7588424aae600abf8407b76d7da56b9'),
    ('public.registrar_pago_combinado_cliente_fifo(bigint,jsonb,date,text,text,uuid)', '8497c398845f786dfbcff897d68acba0'),
    ('public.registrar_pago_combinado_cliente_fifo_impl(bigint,jsonb,date,text,text)', 'b1f824a0c8f9713b8ba2c909a9ef3f5c'),
    ('public.registrar_pagos_pedido(bigint,jsonb,date,text,text,uuid)', '4ba5827629e9b48bf1fe72da2b1cebbb'),
    ('public.registrar_pagos_pedido_impl(bigint,jsonb,date,text,text)', 'a7406466806b8e8465641580217df3ae')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;

  -- Una sola firma de cada RPC de cobro: la que se reemplaza.
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
       AND proname IN ('registrar_pagos_pedido', 'registrar_pagos_pedido_impl',
                       'registrar_pago_cliente_fifo', 'registrar_pago_cliente_fifo_impl',
                       'registrar_pago_combinado_cliente_fifo', 'registrar_pago_combinado_cliente_fifo_impl',
                       'marcar_pagos_masivo', 'marcar_pagos_masivo_impl')) <> 8 THEN
    RAISE EXCEPTION 'mig NNN · hay más de una firma de una RPC de cobro';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.pagos'::regclass AND attname = 'cobrado_por')
     OR EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.rendiciones_control'::regclass
                  AND attname = 'disconformidad_at')
     OR EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.empleado_movimientos'::regclass
                  AND attname = 'recupera_faltante_id') THEN
    RAISE EXCEPTION 'mig NNN · una columna nueva ya existe';
  END IF;

  SELECT pg_get_constraintdef(oid) INTO v FROM pg_constraint
   WHERE conname = 'altas_por_clave_operacion_check' AND conrelid = 'public.altas_por_clave'::regclass;
  IF v IS DISTINCT FROM 'CHECK ((operacion = ANY (ARRAY[''condicion_mayorista''::text, ''promocion''::text, ''cliente''::text, ''gasto''::text, ''empleado''::text, ''visita''::text, ''cambio_producto''::text, ''movimiento_empleado''::text, ''liquidacion_empleado''::text])))' THEN
    RAISE EXCEPTION 'mig NNN · el CHECK de altas_por_clave cambió (%): armarlo sobre la lista vigente', v;
  END IF;

  SELECT pg_get_constraintdef(oid) INTO v FROM pg_constraint
   WHERE conname = 'empleado_movimientos_faltante_negativo';
  IF v IS DISTINCT FROM 'CHECK (((tipo <> ''faltante''::text) OR (revierte_id IS NOT NULL) OR (monto < (0)::numeric)))' THEN
    RAISE EXCEPTION 'mig NNN · el CHECK empleado_movimientos_faltante_negativo cambió (%)', v;
  END IF;
END
$premisas$;

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
    -- T4 (D8): una disconformidad cuenta sólo para la raíz creada después de su corte.
    LEFT JOIN LATERAL (
      SELECT max(c.fecha) + 1 AS abierto
        FROM cerradas c
       WHERE c.transportista_id = dueno.t
         AND (c.desde IS NULL OR (pg.pago_padre_id IS NULL AND pg.created_at > c.desde))
         AND EXISTS (SELECT 1 FROM cerradas d
                      WHERE d.transportista_id = dueno.t AND d.fecha = pg.fecha
                        AND (d.desde IS NULL OR (pg.pago_padre_id IS NULL AND pg.created_at > d.desde)))
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

-- -------------------------------------------------------------------------
-- 4 · Las RPCs de cobro con quién cobró (firmas nuevas, sin las viejas)
-- -------------------------------------------------------------------------
DROP FUNCTION public.registrar_pagos_pedido(bigint, jsonb, date, text, text, uuid);
DROP FUNCTION public.registrar_pagos_pedido_impl(bigint, jsonb, date, text, text);
DROP FUNCTION public.registrar_pago_cliente_fifo(bigint, numeric, text, date, text, text, uuid);
DROP FUNCTION public.registrar_pago_cliente_fifo_impl(bigint, numeric, text, date, text, text);
DROP FUNCTION public.registrar_pago_combinado_cliente_fifo(bigint, jsonb, date, text, text, uuid);
DROP FUNCTION public.registrar_pago_combinado_cliente_fifo_impl(bigint, jsonb, date, text, text);
DROP FUNCTION public.marcar_pagos_masivo(bigint[], text, date, uuid);
DROP FUNCTION public.marcar_pagos_masivo_impl(bigint[], text, date);

-- ---- registrar_pagos_pedido_impl
CREATE OR REPLACE FUNCTION public.registrar_pagos_pedido_impl(p_pedido_id bigint, p_metodos jsonb, p_fecha date, p_notas text DEFAULT NULL::text, p_referencia text DEFAULT NULL::text, p_cobrado_por uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_sucursal_id bigint := current_sucursal_id();
  v_usuario     uuid   := auth.uid();
  v_hoy         date   := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_pedido      RECORD;
  v_metodo      jsonb;
  v_monto       numeric;
  v_total       numeric := 0;
  v_falta       numeric;
  v_pago_id     bigint;
  v_pago_ids    bigint[] := '{}';
  v_cobrador    uuid;
BEGIN
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;
  IF v_usuario IS NULL THEN
    RAISE EXCEPTION 'No autorizado' USING ERRCODE = '42501';
  END IF;

  IF p_pedido_id IS NULL THEN
    RAISE EXCEPTION 'Un pago sin pedido es un pago a cuenta: registralo desde la ficha del cliente.'
      USING ERRCODE = '22023';
  END IF;

  IF p_metodos IS NULL OR jsonb_typeof(p_metodos) <> 'array' OR jsonb_array_length(p_metodos) = 0 THEN
    RAISE EXCEPTION 'Debe enviar al menos una forma de pago' USING ERRCODE = '22023';
  END IF;

  FOR v_metodo IN SELECT * FROM jsonb_array_elements(p_metodos) LOOP
    -- #1468: un "NaN" pasaba el <= 0; y el monto se compara contra lo que falta ya
    -- redondeado al centavo, que es lo que se guarda.
    v_monto := public._monto_de_cobro(NULLIF(v_metodo->>'monto', '')::numeric);
    IF v_monto IS NULL OR v_monto <= 0 THEN
      RAISE EXCEPTION 'Cada forma de pago debe tener un monto mayor a 0' USING ERRCODE = '22023';
    END IF;
    PERFORM public._forma_pago_de_cobro(v_metodo->>'forma_pago', true);
    v_total := v_total + v_monto;
  END LOOP;

  IF p_fecha IS NULL THEN
    RAISE EXCEPTION 'La fecha del pago es obligatoria' USING ERRCODE = '22023';
  END IF;
  IF p_fecha > v_hoy THEN
    RAISE EXCEPTION 'La fecha del pago (%) no puede ser futura', to_char(p_fecha, 'DD/MM/YYYY')
      USING ERRCODE = '22023';
  END IF;
  IF p_fecha <> v_hoy AND NOT es_admin() THEN
    RAISE EXCEPTION 'Solo un admin puede registrar un pago con otra fecha que hoy'
      USING ERRCODE = '42501';
  END IF;

  -- Serializa contra los otros cobros de esta boleta (FIFO, masivos, otro
  -- operador): la cuenta de lo que falta es contra la version que queda.
  SELECT id, cliente_id, total, COALESCE(monto_pagado, 0) AS pagado, estado,
         tipo_factura, usuario_id, transportista_id
    INTO v_pedido
    FROM pedidos
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pedido no encontrado' USING ERRCODE = 'P0002';
  END IF;

  -- es_preventista() y es_transportista() dejan pasar a otros roles (trampa 4):
  -- aca solo importa que admin y encargado ya entraron por la primera rama.
  IF NOT es_encargado_o_admin()
     AND NOT (es_transportista() AND v_pedido.transportista_id IS NOT DISTINCT FROM v_usuario)
     AND NOT (es_preventista() AND v_pedido.usuario_id IS NOT DISTINCT FROM v_usuario) THEN
    RAISE EXCEPTION 'No autorizado: solo podes cobrar un pedido que vendiste o que tenes asignado'
      USING ERRCODE = '42501';
  END IF;

  -- T4 (#1710, D1 de #1507): quien cobró. Lo decide _cobrador_de_cobro: el que llama,
  -- o el que elige el admin (el encargado, sólo el chofer de la boleta).
  v_cobrador := public._cobrador_de_cobro(p_cobrado_por, v_sucursal_id, v_pedido.transportista_id);

  -- Los mismos rechazos que los triggers (360 y 3XA), dichos antes de insertar.
  IF v_pedido.estado IN ('cancelado', 'anulado') THEN
    RAISE EXCEPTION 'El pedido #% está %: no admite pagos. Registralo como pago a cuenta del cliente.',
      p_pedido_id, v_pedido.estado USING ERRCODE = '22023';
  END IF;
  IF v_pedido.tipo_factura = 'VB' THEN
    RAISE EXCEPTION 'El pedido #% es un vale blanco (consumo interno): no admite pagos', p_pedido_id
      USING ERRCODE = '22023';
  END IF;

  v_falta := v_pedido.total - v_pedido.pagado;
  -- #1468: sin tolerancia. Los dos lados son centavos; con 0,005, un cobro de 100,005
  -- sobre 100 entraba, se guardaba 100,01 y dejaba monto_pagado > total.
  IF v_total > v_falta THEN
    RAISE EXCEPTION 'El pago (%) supera lo que falta cobrar del pedido #% (%). Si el cliente deja plata de mas, registrala como pago a cuenta desde su ficha.',
      -- cobros-B5 (tanda 6 de #1603): el to_char de nueve cifras desbordaba desde mil
      -- millones («#########.##»). El mismo formato (100.00), sin tope.
      round(v_total, 2)::text, p_pedido_id,
      round(GREATEST(v_falta, 0), 2)::text
      USING ERRCODE = '22023';
  END IF;

  FOR v_metodo IN SELECT * FROM jsonb_array_elements(p_metodos) LOOP
    INSERT INTO pagos (
      cliente_id, pedido_id, monto, forma_pago, fecha,
      referencia, notas, usuario_id, sucursal_id, cobrado_por
    )
    VALUES (
      v_pedido.cliente_id, v_pedido.id, public._monto_de_cobro((v_metodo->>'monto')::numeric),
      public._forma_pago_de_cobro(v_metodo->>'forma_pago', true), p_fecha,
      NULLIF(trim(p_referencia), ''), NULLIF(trim(p_notas), ''), v_usuario, v_sucursal_id, v_cobrador
    )
    RETURNING id INTO v_pago_id;

    v_pago_ids := v_pago_ids || v_pago_id;
  END LOOP;

  RETURN jsonb_build_object(
    'success',     true,
    'pedido_id',   v_pedido.id,
    'monto_total', v_total,
    'pago_ids',    to_jsonb(v_pago_ids),
    -- Las filas como las leia el front despues del INSERT REST
    -- (`*, usuario:perfiles(id, nombre)`): ModalRegistrarPago muestra el monto
    -- y arma el recibo con esto.
    'pagos', (
      SELECT jsonb_agg(to_jsonb(pg) || jsonb_build_object(
               'usuario', CASE WHEN u.id IS NULL THEN NULL
                               ELSE jsonb_build_object('id', u.id, 'nombre', u.nombre) END)
             ORDER BY pg.id)
        FROM pagos pg
        LEFT JOIN perfiles u ON u.id = pg.usuario_id
       WHERE pg.id = ANY (v_pago_ids)
    )
  );
END;
$function$;

-- ---- registrar_pagos_pedido
CREATE OR REPLACE FUNCTION public.registrar_pagos_pedido(p_pedido_id bigint, p_metodos jsonb, p_fecha date, p_notas text DEFAULT NULL::text, p_referencia text DEFAULT NULL::text, p_client_request_id uuid DEFAULT NULL::uuid, p_cobrado_por uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_previo    jsonb;
  v_resultado jsonb;
BEGIN
  -- La regla entera esta en el _impl. Esto corta antes de abrir la solicitud a
  -- quien no cobra nunca (deposito).
  IF NOT (es_preventista() OR es_transportista()) THEN
    RAISE EXCEPTION 'No autorizado' USING ERRCODE = '42501';
  END IF;

  v_previo := public.pago_solicitud_abrir(p_client_request_id, 'registrar_pagos_pedido',
    -- 1559-b14 (#1559): lo que define el cobro (no la fecha, las notas ni la referencia).
    jsonb_build_object('pedido_id', p_pedido_id, 'metodos', p_metodos)
    -- T4: quién cobró es de qué caja es el cobro. Sin elegir, el contenido es el de antes.
    || CASE WHEN p_cobrado_por IS NULL THEN '{}'::jsonb
            ELSE jsonb_build_object('cobrado_por', p_cobrado_por) END);
  IF v_previo IS NOT NULL THEN
    RETURN v_previo || jsonb_build_object('idempotent_replay', true);
  END IF;

  v_resultado := public.registrar_pagos_pedido_impl(
    p_pedido_id, p_metodos, p_fecha, p_notas, p_referencia, p_cobrado_por
  );

  PERFORM public.pago_solicitud_cerrar(p_client_request_id, v_resultado);
  RETURN v_resultado;
END;
$function$;

-- ---- registrar_pago_cliente_fifo_impl
CREATE OR REPLACE FUNCTION public.registrar_pago_cliente_fifo_impl(p_cliente_id bigint, p_monto numeric, p_forma_pago text, p_fecha date DEFAULT ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires'::text))::date, p_referencia text DEFAULT NULL::text, p_notas text DEFAULT NULL::text, p_cobrado_por uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_sucursal_id bigint := current_sucursal_id();
  v_acting_user uuid := auth.uid();
  v_rol text;
  v_forma text;
  v_monto numeric;
  v_restante numeric;
  v_aplicar numeric;
  v_pedido record;
  v_pago_id bigint;
  v_pago_ids jsonb := '[]'::jsonb;
  v_aplicaciones jsonb := '[]'::jsonb;
  v_credito_aplicado numeric := 0;
  v_cobrador uuid;
BEGIN
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  -- #1468: un NaN pasaba esta guarda (NaN > 0 es verdadero) y LEAST(NaN, falta) saldaba
  -- las boletas con plata que no entró. Y sin redondear, 100,005 imputaba 100 y dejaba
  -- 0,005 que se guardaba como 0,01 a favor. _monto_de_cobro rechaza el NaN y redondea.
  v_monto := public._monto_de_cobro(p_monto);
  IF v_monto IS NULL OR v_monto <= 0 THEN
    RAISE EXCEPTION 'Monto debe ser mayor a 0' USING ERRCODE = '22023';
  END IF;
  v_restante := v_monto;

  -- #1249: antes alcanzaba con un texto no vacio, y 'Efectivo' o 'mp' caian en
  -- "otros" de la rendicion. Desde la ficha tambien entra el adelanto de sueldo.
  v_forma := public._forma_pago_de_cobro(p_forma_pago, false);

  SELECT rol INTO v_rol FROM perfiles WHERE id = v_acting_user;
  IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado: solo admin o encargado pueden registrar pagos desde ficha de cliente'
      USING ERRCODE = '42501';
  END IF;

  -- T4 (#1710, D1 de #1507): quien cobró. Lo decide _cobrador_de_cobro: el que llama,
  -- o el que elige el admin (el encargado, sólo el chofer de la boleta).
  -- El pago a cuenta de la ficha es de la caja de quien lo carga (D1), no del chofer
  -- de las boletas a las que lo imputa el FIFO.
  v_cobrador := public._cobrador_de_cobro(p_cobrado_por, v_sucursal_id, NULL);

  -- cobros-B4 (tanda 6 de #1603): un cliente de otra sucursal (o que no existe)
  -- terminaba en el 23503 de la FK del saldo a favor. Antes de tomar nada.
  IF NOT EXISTS (SELECT 1 FROM clientes WHERE id = p_cliente_id AND sucursal_id = v_sucursal_id) THEN
    RAISE EXCEPTION 'Cliente no encontrado' USING ERRCODE = 'P0002';
  END IF;

  -- #1440: la fecha nunca es futura, como en registrar_pagos_pedido_impl.
  IF p_fecha > public._tablero_hoy() THEN
    RAISE EXCEPTION 'La fecha del pago (%) no puede ser futura', to_char(p_fecha, 'DD/MM/YYYY')
      USING ERRCODE = '22023';
  END IF;

  IF v_rol = 'encargado' THEN
    -- mig 230: la base corre en UTC. Comparar contra CURRENT_DATE entre las
    -- 21:00 y las 24:00 ART rechazaba justo la fecha correcta.
    IF p_fecha <> (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date THEN
      RAISE EXCEPTION 'Encargado solo puede registrar pagos con fecha de hoy'
        USING ERRCODE = '42501';
    END IF;
    IF public.rendicion_dia_cerrada(p_fecha, v_sucursal_id) THEN
      RAISE EXCEPTION 'Rendicion ya cerrada para esta fecha. Pedi a un admin.'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  -- Primero se gasta el saldo a favor que el cliente ya tenia (mig 165), recien
  -- despues se imputa la plata nueva. Sin esto el credito no se consume nunca.
  -- #1439: el orden global (pedidos por id, recorridos por id, pagos) antes del
  -- primer lock: el credito y el bucle toman las boletas por fecha, y cada pago
  -- llega a la ruta por el trigger de monto_pagado. Son las boletas que los dos
  -- pueden tocar; las vuelven a tomar en su orden, ya bloqueadas.
  PERFORM 1
     FROM pedidos
    WHERE cliente_id = p_cliente_id
      AND sucursal_id = v_sucursal_id
      AND COALESCE(estado, '') NOT IN ('cancelado', 'anulado')
      AND total > COALESCE(monto_pagado, 0)
    ORDER BY id
      FOR UPDATE;

  PERFORM 1
     FROM recorridos
    WHERE id IN (SELECT rp.recorrido_id
                   FROM recorrido_pedidos rp
                   JOIN pedidos p ON p.id = rp.pedido_id
                  WHERE p.cliente_id = p_cliente_id
                    AND p.sucursal_id = v_sucursal_id
                    AND COALESCE(p.estado, '') NOT IN ('cancelado', 'anulado')
                    AND p.total > COALESCE(p.monto_pagado, 0))
    ORDER BY id
      FOR NO KEY UPDATE;

  v_credito_aplicado := public.aplicar_credito_cliente(p_cliente_id, v_sucursal_id);

  FOR v_pedido IN
    SELECT id, total, COALESCE(monto_pagado, 0) AS pagado, fecha
    FROM pedidos
    WHERE cliente_id = p_cliente_id
      AND sucursal_id = v_sucursal_id
      AND COALESCE(estado, '') NOT IN ('cancelado', 'anulado')
      AND COALESCE(estado_pago, 'pendiente') <> 'pagado'
      AND total > COALESCE(monto_pagado, 0)
    ORDER BY fecha ASC, id ASC
    -- mig 230: serializa la imputacion, igual que la 181 en
    -- marcar_pagos_masivo_impl. Sin el lock, dos cobros concurrentes al mismo
    -- cliente leen el mismo `pagado` y los dos imputan el saldo entero.
    FOR UPDATE
  LOOP
    EXIT WHEN v_restante <= 0;
    v_aplicar := LEAST(v_restante, v_pedido.total - v_pedido.pagado);

    INSERT INTO pagos (
      cliente_id, pedido_id, monto, forma_pago, fecha,
      referencia, notas, usuario_id, sucursal_id, a_cuenta, cobrado_por
    )
    VALUES (
      p_cliente_id, v_pedido.id, v_aplicar, v_forma, p_fecha,
      p_referencia, p_notas, v_acting_user, v_sucursal_id, true, v_cobrador
    )
    RETURNING id INTO v_pago_id;

    v_pago_ids := v_pago_ids || to_jsonb(v_pago_id);
    v_aplicaciones := v_aplicaciones || jsonb_build_object(
      'pago_id', v_pago_id,
      'pedido_id', v_pedido.id,
      'pedido_fecha', v_pedido.fecha,
      'monto', v_aplicar
    );

    v_restante := v_restante - v_aplicar;
  END LOOP;

  IF v_restante > 0 THEN
    INSERT INTO pagos (
      cliente_id, pedido_id, monto, forma_pago, fecha,
      referencia, notas, usuario_id, sucursal_id, a_cuenta, cobrado_por
    )
    VALUES (
      p_cliente_id, NULL, v_restante, v_forma, p_fecha,
      p_referencia,
      COALESCE(NULLIF(p_notas, '') || ' ', '') || '[saldo a favor]',
      v_acting_user, v_sucursal_id, true, v_cobrador
    )
    RETURNING id INTO v_pago_id;

    v_pago_ids := v_pago_ids || to_jsonb(v_pago_id);
    v_aplicaciones := v_aplicaciones || jsonb_build_object(
      'pago_id', v_pago_id,
      'pedido_id', NULL,
      'monto', v_restante,
      'saldo_a_favor', true
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'monto_total', v_monto,
    'sobrante', v_restante,
    'credito_aplicado', v_credito_aplicado,
    'pago_ids', v_pago_ids,
    'aplicaciones', v_aplicaciones
  );
END;
$function$;

-- ---- registrar_pago_cliente_fifo
CREATE OR REPLACE FUNCTION public.registrar_pago_cliente_fifo(p_cliente_id bigint, p_monto numeric, p_forma_pago text, p_fecha date DEFAULT ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires'::text))::date, p_referencia text DEFAULT NULL::text, p_notas text DEFAULT NULL::text, p_client_request_id uuid DEFAULT NULL::uuid, p_cobrado_por uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_previo    jsonb;
  v_resultado jsonb;
BEGIN
  v_previo := public.pago_solicitud_abrir(p_client_request_id, 'registrar_pago_cliente_fifo',
    -- 1559-b14 (#1559): lo que define el cobro (no la fecha, las notas ni la referencia).
    -- cobros-B6 (tanda 6 de #1603): el monto como número de jsonb, como el combinado
    -- (5.00 = 5). Un NaN queda como el texto "NaN" (to_jsonb) y lo rechaza el _impl.
    jsonb_build_object('cliente_id', p_cliente_id, 'monto', p_monto, 'forma_pago', p_forma_pago)
    || CASE WHEN p_cobrado_por IS NULL THEN '{}'::jsonb
            ELSE jsonb_build_object('cobrado_por', p_cobrado_por) END);
  IF v_previo IS NOT NULL THEN
    RETURN v_previo || jsonb_build_object('idempotent_replay', true);
  END IF;

  v_resultado := public.registrar_pago_cliente_fifo_impl(
    p_cliente_id, p_monto, p_forma_pago, p_fecha, p_referencia, p_notas, p_cobrado_por
  );

  PERFORM public.pago_solicitud_cerrar(p_client_request_id, v_resultado);
  RETURN v_resultado;
END;
$function$;

-- ---- registrar_pago_combinado_cliente_fifo_impl
CREATE OR REPLACE FUNCTION public.registrar_pago_combinado_cliente_fifo_impl(p_cliente_id bigint, p_metodos jsonb, p_fecha date DEFAULT ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires'::text))::date, p_referencia text DEFAULT NULL::text, p_notas text DEFAULT NULL::text, p_cobrado_por uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_sucursal_id bigint := current_sucursal_id();
  v_acting_user uuid := auth.uid();
  v_rol text;
  v_metodo jsonb;
  v_forma text;
  v_monto numeric;
  v_restante numeric;
  v_aplicar numeric;
  v_pedido record;
  v_pago_id bigint;
  v_pago_ids jsonb := '[]'::jsonb;
  v_aplicaciones jsonb := '[]'::jsonb;
  v_monto_total numeric := 0;
  v_sobrante_total numeric := 0;
  v_notas_imputado text;
  v_credito_aplicado numeric := 0;
  v_cobrador uuid;
BEGIN
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  IF p_metodos IS NULL OR jsonb_typeof(p_metodos) <> 'array' OR jsonb_array_length(p_metodos) = 0 THEN
    RAISE EXCEPTION 'Debe enviar al menos una forma de pago' USING ERRCODE = '22023';
  END IF;

  SELECT rol INTO v_rol FROM perfiles WHERE id = v_acting_user;
  IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado: solo admin o encargado pueden registrar pagos desde ficha de cliente'
      USING ERRCODE = '42501';
  END IF;

  -- T4 (#1710, D1 de #1507): quien cobró. Lo decide _cobrador_de_cobro: el que llama,
  -- o el que elige el admin (el encargado, sólo el chofer de la boleta).
  v_cobrador := public._cobrador_de_cobro(p_cobrado_por, v_sucursal_id, NULL);

  -- Gemelo de cobros-B4 (tanda 6 bis de #1603): un cliente de otra sucursal (o que no
  -- existe) terminaba en el 23503 de la FK de pagos. Antes de tomar nada, como
  -- registrar_pago_cliente_fifo_impl (542).
  IF NOT EXISTS (SELECT 1 FROM clientes WHERE id = p_cliente_id AND sucursal_id = v_sucursal_id) THEN
    RAISE EXCEPTION 'Cliente no encontrado' USING ERRCODE = 'P0002';
  END IF;

  -- #1440: la fecha nunca es futura, como en registrar_pagos_pedido_impl.
  IF p_fecha > public._tablero_hoy() THEN
    RAISE EXCEPTION 'La fecha del pago (%) no puede ser futura', to_char(p_fecha, 'DD/MM/YYYY')
      USING ERRCODE = '22023';
  END IF;

  IF v_rol = 'encargado' THEN
    -- mig 230: la base corre en UTC. Comparar contra CURRENT_DATE entre las
    -- 21:00 y las 24:00 ART rechazaba justo la fecha correcta.
    IF p_fecha <> (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date THEN
      RAISE EXCEPTION 'Encargado solo puede registrar pagos con fecha de hoy'
        USING ERRCODE = '42501';
    END IF;
    IF public.rendicion_dia_cerrada(p_fecha, v_sucursal_id) THEN
      RAISE EXCEPTION 'Rendicion ya cerrada para esta fecha. Pedi a un admin.'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  FOR v_metodo IN SELECT * FROM jsonb_array_elements(p_metodos) LOOP
    -- #1468: un "NaN" pasaba el <= 0, y sin redondear se imputaba un monto que no es el
    -- que se guarda. Ver registrar_pago_cliente_fifo_impl.
    v_monto := public._monto_de_cobro(NULLIF(v_metodo->>'monto', '')::numeric);
    IF v_monto IS NULL OR v_monto <= 0 THEN
      RAISE EXCEPTION 'Cada forma de pago debe tener un monto mayor a 0' USING ERRCODE = '22023';
    END IF;
    -- #1249: la lista es formas_pago(), no "cualquier texto no vacio".
    PERFORM public._forma_pago_de_cobro(v_metodo->>'forma_pago', false);
    v_monto_total := v_monto_total + v_monto;
  END LOOP;

  v_notas_imputado := NULLIF(trim(COALESCE(p_notas, '') || ' [pago combinado]'), '');

  -- Igual que en el FIFO simple: primero se gasta el credito preexistente (mig 165).
  -- #1439: el orden global antes del primer lock, como en
  -- registrar_pago_cliente_fifo_impl.
  PERFORM 1
     FROM pedidos
    WHERE cliente_id = p_cliente_id
      AND sucursal_id = v_sucursal_id
      AND COALESCE(estado, '') NOT IN ('cancelado', 'anulado')
      AND total > COALESCE(monto_pagado, 0)
    ORDER BY id
      FOR UPDATE;

  PERFORM 1
     FROM recorridos
    WHERE id IN (SELECT rp.recorrido_id
                   FROM recorrido_pedidos rp
                   JOIN pedidos p ON p.id = rp.pedido_id
                  WHERE p.cliente_id = p_cliente_id
                    AND p.sucursal_id = v_sucursal_id
                    AND COALESCE(p.estado, '') NOT IN ('cancelado', 'anulado')
                    AND p.total > COALESCE(p.monto_pagado, 0))
    ORDER BY id
      FOR NO KEY UPDATE;

  v_credito_aplicado := public.aplicar_credito_cliente(p_cliente_id, v_sucursal_id);

  FOR v_metodo IN SELECT * FROM jsonb_array_elements(p_metodos) LOOP
    v_monto := public._monto_de_cobro((v_metodo->>'monto')::numeric);
    v_forma := public._forma_pago_de_cobro(v_metodo->>'forma_pago', false);
    v_restante := v_monto;

    FOR v_pedido IN
      SELECT id, total, COALESCE(monto_pagado, 0) AS pagado, fecha
      FROM pedidos
      WHERE cliente_id = p_cliente_id
        AND sucursal_id = v_sucursal_id
        AND COALESCE(estado, '') NOT IN ('cancelado', 'anulado')
        AND COALESCE(estado_pago, 'pendiente') <> 'pagado'
        AND total > COALESCE(monto_pagado, 0)
      ORDER BY fecha ASC, id ASC
      -- mig 230: ver registrar_pago_cliente_fifo_impl. Mismo lock, y aca
      -- ademas cada metodo de pago vuelve a recorrer los pedidos.
      FOR UPDATE
    LOOP
      EXIT WHEN v_restante <= 0;
      v_aplicar := LEAST(v_restante, v_pedido.total - v_pedido.pagado);

      INSERT INTO pagos (
        cliente_id, pedido_id, monto, forma_pago, fecha,
        referencia, notas, usuario_id, sucursal_id, a_cuenta, cobrado_por
      )
      VALUES (
        p_cliente_id, v_pedido.id, v_aplicar, v_forma, p_fecha,
        p_referencia, v_notas_imputado, v_acting_user, v_sucursal_id, true, v_cobrador
      )
      RETURNING id INTO v_pago_id;

      v_pago_ids := v_pago_ids || to_jsonb(v_pago_id);
      v_aplicaciones := v_aplicaciones || jsonb_build_object(
        'pago_id', v_pago_id,
        'pedido_id', v_pedido.id,
        'pedido_fecha', v_pedido.fecha,
        'forma_pago', v_forma,
        'monto', v_aplicar
      );

      v_restante := v_restante - v_aplicar;
    END LOOP;

    IF v_restante > 0 THEN
      INSERT INTO pagos (
        cliente_id, pedido_id, monto, forma_pago, fecha,
        referencia, notas, usuario_id, sucursal_id, a_cuenta, cobrado_por
      )
      VALUES (
        p_cliente_id, NULL, v_restante, v_forma, p_fecha,
        p_referencia,
        trim(COALESCE(p_notas, '') || ' [pago combinado] [saldo a favor]'),
        v_acting_user, v_sucursal_id, true, v_cobrador
      )
      RETURNING id INTO v_pago_id;

      v_pago_ids := v_pago_ids || to_jsonb(v_pago_id);
      v_aplicaciones := v_aplicaciones || jsonb_build_object(
        'pago_id', v_pago_id,
        'pedido_id', NULL,
        'forma_pago', v_forma,
        'monto', v_restante,
        'saldo_a_favor', true
      );

      v_sobrante_total := v_sobrante_total + v_restante;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'monto_total', v_monto_total,
    'sobrante', v_sobrante_total,
    'credito_aplicado', v_credito_aplicado,
    'pago_ids', v_pago_ids,
    'aplicaciones', v_aplicaciones
  );
END;
$function$;

-- ---- registrar_pago_combinado_cliente_fifo
CREATE OR REPLACE FUNCTION public.registrar_pago_combinado_cliente_fifo(p_cliente_id bigint, p_metodos jsonb, p_fecha date DEFAULT ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires'::text))::date, p_referencia text DEFAULT NULL::text, p_notas text DEFAULT NULL::text, p_client_request_id uuid DEFAULT NULL::uuid, p_cobrado_por uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_previo    jsonb;
  v_resultado jsonb;
BEGIN
  v_previo := public.pago_solicitud_abrir(p_client_request_id, 'registrar_pago_combinado_cliente_fifo',
    -- 1559-b14 (#1559): lo que define el cobro (no la fecha, las notas ni la referencia).
    jsonb_build_object('cliente_id', p_cliente_id, 'metodos', p_metodos)
    || CASE WHEN p_cobrado_por IS NULL THEN '{}'::jsonb
            ELSE jsonb_build_object('cobrado_por', p_cobrado_por) END);
  IF v_previo IS NOT NULL THEN
    RETURN v_previo || jsonb_build_object('idempotent_replay', true);
  END IF;

  v_resultado := public.registrar_pago_combinado_cliente_fifo_impl(
    p_cliente_id, p_metodos, p_fecha, p_referencia, p_notas, p_cobrado_por
  );

  PERFORM public.pago_solicitud_cerrar(p_client_request_id, v_resultado);
  RETURN v_resultado;
END;
$function$;

-- ---- marcar_pagos_masivo_impl
CREATE OR REPLACE FUNCTION public.marcar_pagos_masivo_impl(p_pedido_ids bigint[], p_forma_pago text, p_fecha date DEFAULT ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires'::text))::date, p_cobrado_por uuid DEFAULT NULL::uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_sucursal_id BIGINT;
  v_affected INTEGER;
  v_pedido RECORD;
  v_rol TEXT;
  v_cobrados BIGINT[] := '{}';
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Solo encargado o admin pueden marcar pagos masivos'
      USING ERRCODE = '42501';
  END IF;

  -- #1249: antes no se validaba; ademas escribe pedidos.forma_pago.
  p_forma_pago := public._forma_pago_de_cobro(p_forma_pago, true);

  -- SEG-1 (#1545): un desactivado no tiene rol aunque su token siga vivo.
  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid() AND COALESCE(activo, true);

  -- #1440: la fecha nunca es futura, como en registrar_pagos_pedido_impl.
  IF p_fecha > public._tablero_hoy() THEN
    RAISE EXCEPTION 'La fecha del pago (%) no puede ser futura', to_char(p_fecha, 'DD/MM/YYYY')
      USING ERRCODE = '22023';
  END IF;

  IF v_rol = 'encargado' THEN
    -- mig 230: la base corre en UTC. Comparar contra CURRENT_DATE entre las
    -- 21:00 y las 24:00 ART rechazaba justo la fecha correcta.
    IF p_fecha <> (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date THEN
      RAISE EXCEPTION 'Encargado solo puede registrar pagos con fecha de hoy'
        USING ERRCODE = '42501';
    END IF;
    IF public.rendicion_dia_cerrada(p_fecha, v_sucursal_id) THEN
      RAISE EXCEPTION 'Rendicion ya cerrada para esta fecha. Pedi a un admin.'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  IF p_pedido_ids IS NULL OR array_length(p_pedido_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;

  -- #1439: el orden de la 439 (marcar_entrega_y_pago_masivo_impl), pedidos por
  -- id y despues recorridos por id, antes del primer pago: cada INSERT llega a la
  -- ruta por el trigger de monto_pagado. No entrega, asi que no toma rendiciones.
  PERFORM 1
     FROM pedidos
    WHERE id = ANY(p_pedido_ids)
      AND sucursal_id = v_sucursal_id
    ORDER BY id
      FOR UPDATE;

  PERFORM 1
     FROM recorridos
    WHERE id IN (SELECT rp.recorrido_id
                   FROM recorrido_pedidos rp
                  WHERE rp.pedido_id = ANY(p_pedido_ids))
    ORDER BY id
      FOR NO KEY UPDATE;

  FOR v_pedido IN
    SELECT id, cliente_id, total, COALESCE(monto_pagado, 0) AS ya_pagado, transportista_id
    FROM pedidos
    WHERE id = ANY(p_pedido_ids)
      AND sucursal_id = v_sucursal_id
      AND COALESCE(estado_pago, 'pendiente') <> 'pagado'
      AND COALESCE(estado, '') NOT IN ('cancelado', 'anulado')
      AND total > COALESCE(monto_pagado, 0)
      AND COALESCE(tipo_factura, 'ZZ') <> 'VB'  -- mig 3XA
    -- mig 181: serializa el lote. Sin el lock, un cobro del chofer en la misma
    -- ventana quedaba tapado por el UPDATE de abajo.
    ORDER BY id
    FOR UPDATE
  LOOP
    INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id,
                       cobrado_por)
    VALUES (
      v_pedido.cliente_id,
      v_pedido.id,
      v_pedido.total - v_pedido.ya_pagado,
      p_forma_pago,
      p_fecha,
      auth.uid(),
      v_sucursal_id,
      -- T4 (#1710): el cobro masivo de la oficina es de quien lo carga; el admin elige otro,
      -- y el encargado sólo el chofer de cada boleta.
      public._cobrador_de_cobro(p_cobrado_por, v_sucursal_id, v_pedido.transportista_id)
    );
    v_cobrados := v_cobrados || v_pedido.id;
  END LOOP;

  -- mig 181: ya NO se escribe monto_pagado = total. El trigger
  -- recalcular_monto_pagado_pedido lo deriva de SUM(pagos) tras el INSERT de
  -- arriba; fijarlo a mano tapaba un cobro concurrente y el pedido se veia
  -- saldado con dos pagos encima.
  -- 1559-b11 (#1559): la forma de pago va solo en las boletas que este lote
  -- cobro. Antes iba en todas las enviadas, y a una ya cobrada le pisaba la forma
  -- con la del lote.
  UPDATE pedidos
     SET forma_pago = p_forma_pago,
         updated_at = now()
   WHERE id = ANY(v_cobrados)
     AND sucursal_id = v_sucursal_id;

  -- 1559-b12 (#1559): cuantas cobro, no cuantas toco el UPDATE: es lo que dice
  -- el aviso del cobro masivo.
  RETURN cardinality(v_cobrados);
END;
$function$;

-- ---- marcar_pagos_masivo
CREATE OR REPLACE FUNCTION public.marcar_pagos_masivo(p_pedido_ids bigint[], p_forma_pago text, p_fecha date DEFAULT ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires'::text))::date, p_client_request_id uuid DEFAULT NULL::uuid, p_cobrado_por uuid DEFAULT NULL::uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_previo    jsonb;
  v_afectados integer;
BEGIN
  v_previo := public.pago_solicitud_abrir(p_client_request_id, 'marcar_pagos_masivo',
    -- 1559-b14 (#1559): lo que define el cobro: los ids ordenados (el lote es un
    -- conjunto) y la forma; no la fecha.
    jsonb_build_object('pedido_ids', to_jsonb(ARRAY(SELECT DISTINCT x FROM unnest(p_pedido_ids) x ORDER BY 1)),
                       'forma_pago', p_forma_pago)
    || CASE WHEN p_cobrado_por IS NULL THEN '{}'::jsonb
            ELSE jsonb_build_object('cobrado_por', p_cobrado_por) END);
  IF v_previo IS NOT NULL THEN
    RETURN COALESCE((v_previo->>'afectados')::integer, 0);
  END IF;

  v_afectados := public.marcar_pagos_masivo_impl(p_pedido_ids, p_forma_pago, p_fecha, p_cobrado_por);

  PERFORM public.pago_solicitud_cerrar(
    p_client_request_id, jsonb_build_object('afectados', v_afectados)
  );
  RETURN v_afectados;
END;
$function$;

-- ---- marcar_entrega_y_pago_masivo_impl
CREATE OR REPLACE FUNCTION public.marcar_entrega_y_pago_masivo_impl(p_pedido_ids bigint[], p_transportista_id uuid, p_forma_pago text, p_fecha date DEFAULT ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires'::text))::date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_sucursal_id BIGINT;
  v_affected INTEGER;
  v_pedido RECORD;
  v_rol TEXT;
  v_fecha_ts TIMESTAMPTZ;
  v_claves bigint[]; -- #1342
  v_clave bigint;
  v_par RECORD;
  -- cobros-B2 (tanda 6 de #1603): las boletas que este lote cobró.
  v_cobrados BIGINT[] := '{}';
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Solo encargado o admin pueden marcar entrega y pago masivos'
      USING ERRCODE = '42501';
  END IF;

  -- #1249: antes no se validaba; ademas escribe pedidos.forma_pago.
  p_forma_pago := public._forma_pago_de_cobro(p_forma_pago, true);

  -- #1548 (RUT-4): sin fecha, hoy (su default). Con NULL no frenaban ni el tope de futuro ni
  -- el "sólo hoy" del encargado, y con todo ya pagado el entregado quedaba sin fecha_entrega.
  p_fecha := COALESCE(p_fecha, public._tablero_hoy());

  -- GTO-15 (#1597): la fecha de entrega va de hoy hasta los días atrás de la política (el
  -- admin, 60), como en marcar_entregas_masivo. El encargado sigue además en "sólo hoy" (la
  -- regla del cobro, abajo).
  DECLARE
    v_motivo_fecha text := public._fecha_entrega_fuera_de_rango(p_fecha, v_sucursal_id, public.es_admin());
  BEGIN
    IF v_motivo_fecha IS NOT NULL THEN
      RAISE EXCEPTION '%', v_motivo_fecha USING ERRCODE = '22023';
    END IF;
  END;

  -- Mismo gate de rendición que marcar_pagos_masivo (esta RPC registra pagos)
  -- SEG-1 (#1545): un desactivado no tiene rol aunque su token siga vivo.
  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid() AND COALESCE(activo, true);
  -- #1440: la fecha nunca es futura, como en registrar_pagos_pedido_impl.
  IF p_fecha > public._tablero_hoy() THEN
    RAISE EXCEPTION 'La fecha del pago (%) no puede ser futura', to_char(p_fecha, 'DD/MM/YYYY')
      USING ERRCODE = '22023';
  END IF;

  IF v_rol = 'encargado' THEN
    -- mig 230: la base corre en UTC. Comparar contra CURRENT_DATE entre las
    -- 21:00 y las 24:00 ART rechazaba justo la fecha correcta.
    IF p_fecha <> (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date THEN
      RAISE EXCEPTION 'Encargado solo puede registrar pagos con fecha de hoy'
        USING ERRCODE = '42501';
    END IF;
    IF public.rendicion_dia_cerrada(p_fecha, v_sucursal_id) THEN
      RAISE EXCEPTION 'Rendicion ya cerrada para esta fecha. Pedi a un admin.'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  IF p_pedido_ids IS NULL OR array_length(p_pedido_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;

  -- #1318 (REN-1): el mismo corte que marcar_entregas_masivo. Va antes del
  -- cobro: si la entrega no entra, el cobro tampoco.
  -- #1342: las rendiciones que toca, antes que los pedidos: es el orden de
  -- confirmar_rendicion (la rendición, y después pagos y pedidos). Compartidas: la
  -- confirmación las toma exclusivas y espera, pero otra entrega del mismo chofer y
  -- día no. Ordenadas, como _rendicion_bloquear. El chequeo va más abajo, con todo
  -- tomado: mirado antes, una confirmación que entraba en el medio se borraba igual
  -- por el trigger.
  v_claves := ARRAY(
    SELECT public._rendicion_clave(x.chofer, x.dia, v_sucursal_id)
      FROM (SELECT p_transportista_id AS chofer, p_fecha AS dia
            UNION ALL
            SELECT p.transportista_id, (p.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
              FROM pedidos p
             WHERE p.id = ANY(p_pedido_ids)
               AND p.sucursal_id = v_sucursal_id
               AND COALESCE(p.estado, '') NOT IN ('entregado', 'cancelado', 'anulado')
               AND COALESCE(p.tipo_factura, 'ZZ') <> 'VB'
               AND p.canal IS DISTINCT FROM 'cambio'
               AND p.fecha_entrega IS NOT NULL) x
     WHERE x.chofer IS NOT NULL);
  FOR v_clave IN SELECT DISTINCT c FROM unnest(v_claves) AS c WHERE c IS NOT NULL ORDER BY c LOOP
    PERFORM pg_advisory_xact_lock_shared(v_clave);
  END LOOP;

  v_fecha_ts := (p_fecha::text || ' 12:00:00 America/Argentina/Buenos_Aires')::timestamptz;

  -- #1375: el orden de aplicar_orden_ruta, pedidos por id y después recorridos
  -- por id, antes del primer pago: cada INSERT llega a la ruta por el trigger de
  -- monto_pagado, y el FOR UPDATE del bucle no alcanza a los que ya estan pagados,
  -- que el UPDATE de abajo tambien toca. Va FOR UPDATE, el del bucle: tomar uno
  -- menor y subirlo despues puede cruzarse con una FK.
  PERFORM 1
     FROM pedidos
    WHERE id = ANY(p_pedido_ids)
      AND sucursal_id = v_sucursal_id
    ORDER BY id
      FOR UPDATE;

  PERFORM 1
     FROM recorridos
    WHERE id IN (SELECT rp.recorrido_id
                   FROM recorrido_pedidos rp
                  WHERE rp.pedido_id = ANY(p_pedido_ids))
       -- mig NNN (Rut-B5, revisión): y la ruta en curso del chofer que entrega, de esta
       -- sucursal y del día de la entrega (la que toma el trigger), en el mismo orden por id.
       OR (transportista_id = p_transportista_id AND sucursal_id = v_sucursal_id
           AND estado = 'en_curso' AND fecha = p_fecha)
    ORDER BY id
      FOR NO KEY UPDATE;

  -- #1342: con las rendiciones y los pedidos tomados. Si un pedido cambió de
  -- chofer o de día desde que se tomaron, la suya no está tomada, y tomarla ahora
  -- invertiría el orden: se rechaza para que se vuelva a intentar.
  FOR v_par IN
    SELECT x.chofer, x.dia
      FROM (SELECT p_transportista_id AS chofer, p_fecha AS dia
            UNION ALL
            SELECT p.transportista_id, (p.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
              FROM pedidos p
             WHERE p.id = ANY(p_pedido_ids)
               AND p.sucursal_id = v_sucursal_id
               AND COALESCE(p.estado, '') NOT IN ('entregado', 'cancelado', 'anulado')
               AND COALESCE(p.tipo_factura, 'ZZ') <> 'VB'
               AND p.canal IS DISTINCT FROM 'cambio'
               AND p.fecha_entrega IS NOT NULL) x
     WHERE x.chofer IS NOT NULL
  LOOP
    IF public._rendicion_clave(v_par.chofer, v_par.dia, v_sucursal_id) <> ALL (v_claves) THEN
      RAISE EXCEPTION 'Un pedido cambió de chofer o de fecha mientras se entregaba: volvé a intentar.'
        USING ERRCODE = '40001';
    END IF;
    IF public.control_rendicion_cerrado(v_par.chofer, v_sucursal_id, v_par.dia) THEN
      RAISE EXCEPTION 'La rendición del % de % ya fue controlada: esta entrega la reabriría. Elegí otra fecha, o reabrí primero el control de ese día.',
        to_char(v_par.dia, 'DD/MM/YYYY'),
        COALESCE((SELECT nombre FROM perfiles WHERE id = v_par.chofer), 'ese chofer')
        USING ERRCODE = '42501';
    END IF;
  END LOOP;

  -- 1) Registrar pago por el saldo pendiente (solo pedidos NO pagados)
  FOR v_pedido IN
    SELECT id, cliente_id, total, COALESCE(monto_pagado, 0) AS ya_pagado
    FROM pedidos
    WHERE id = ANY(p_pedido_ids)
      AND sucursal_id = v_sucursal_id
      AND COALESCE(estado_pago, 'pendiente') <> 'pagado'
      -- #1318 (PED-3): un entregado no se vuelve a entregar, como en la 181.
      AND COALESCE(estado, '') NOT IN ('entregado', 'cancelado', 'anulado')
      AND canal IS DISTINCT FROM 'cambio'
      AND total > COALESCE(monto_pagado, 0)
      AND COALESCE(tipo_factura, 'ZZ') <> 'VB'  -- mig 3XA
    ORDER BY id
    FOR UPDATE
  LOOP
    INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id,
                       cobrado_por)
    VALUES (
      v_pedido.cliente_id,
      v_pedido.id,
      v_pedido.total - v_pedido.ya_pagado,
      p_forma_pago,
      p_fecha,
      auth.uid(),
      v_sucursal_id,
      -- T4 (#1710): la oficina carga la entrega a nombre del chofer elegido: el cobro es suyo.
      COALESCE(p_transportista_id, auth.uid())
    );
    v_cobrados := v_cobrados || v_pedido.id;
  END LOOP;

  -- 2) Entregar + saldar en un solo UPDATE (transportista_id SE asigna)
  -- mig 181: no revivir un pedido cancelado como entregado y pagado.
  UPDATE pedidos
     SET estado = 'entregado',
         fecha_entrega = v_fecha_ts,
         transportista_id = p_transportista_id,
         -- mig 230: ya NO se escribe monto_pagado = total, igual que la 181 en
         -- marcar_pagos_masivo_impl. El INSERT en pagos de arriba dispara
         -- recalcular_monto_pagado_pedido, que lo deriva de SUM(pagos). Este
         -- UPDATE alcanza a TODOS los ids del lote -- tambien los que el bucle
         -- salteo por ya estar pagados -- asi que fijarlo a mano tapaba un
         -- cobro concurrente y dejaba el pedido saldado con dos pagos encima.
         -- cobros-B2 (tanda 6 de #1603), gemelo de 1559-b11: la forma de pago va sólo en
         -- las boletas que este lote cobró. A una que ya estaba cobrada le pisaba la
         -- forma con la del lote.
         forma_pago = CASE WHEN id = ANY(v_cobrados) THEN p_forma_pago ELSE forma_pago END,
         updated_at = now()
   WHERE id = ANY(p_pedido_ids)
     AND sucursal_id = v_sucursal_id
     -- #1318 (PED-3): un entregado no se vuelve a entregar: le pisaba el
     -- chofer y la fecha, y el trigger le borraba el control del día viejo.
     AND COALESCE(estado, '') NOT IN ('entregado', 'cancelado', 'anulado')
     AND COALESCE(tipo_factura, 'ZZ') <> 'VB'  -- mig 3XA
     -- #1318: la comanda de un canje se entrega desde el pedido, que aplica el
     -- cambio (aplicar_cambio_de_parada) antes de cerrarla.
     AND canal IS DISTINCT FROM 'cambio';

  GET DIAGNOSTICS v_affected = ROW_COUNT;
  RETURN v_affected;
END;
$function$;

-- ---- desafectar_sobrepago_pedido
CREATE OR REPLACE FUNCTION public.desafectar_sobrepago_pedido(p_pedido_id bigint)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_pedido     RECORD;
  v_pago       RECORD;
  v_excedente  numeric;
  v_quitar     numeric;
  v_quitado    numeric := 0;
  v_nota       text;
  v_guc        text;
  v_marca      text;
  -- #1559 (COB-1): la salvedad que esta bajando el total, si es una.
  v_salvedad   bigint;
BEGIN
  SELECT id, total, COALESCE(monto_pagado, 0) AS pagado, estado, sucursal_id
    INTO v_pedido
    FROM pedidos
   WHERE id = p_pedido_id;

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  IF v_pedido.estado IN ('cancelado', 'anulado') THEN
    RETURN 0;
  END IF;

  v_excedente := v_pedido.pagado - v_pedido.total;
  IF v_excedente <= 0.005 THEN
    RETURN 0;
  END IF;

  -- #1559 (COB-1, decision del dueño 12/11): anular una salvedad repone el cobro
  -- que recorto. registrar_salvedad baja el total con app.stock_origen =
  -- 'salvedad' y app.stock_ref_id = este pedido, y su fila ya esta insertada: es
  -- la ultima de este pedido creada en esta transaccion (created_at = now()).
  -- El recorte de cobro de boleta de abajo se anota en ella.
  IF current_setting('app.stock_origen', true) = 'salvedad'
     AND current_setting('app.stock_ref_tipo', true) = 'pedido'
     AND current_setting('app.stock_ref_id', true) = p_pedido_id::text THEN
    SELECT s.id INTO v_salvedad
      FROM salvedades_items s
     WHERE s.pedido_id = p_pedido_id
       AND s.sucursal_id = v_pedido.sucursal_id
       AND s.estado_resolucion = 'pendiente'
       AND s.created_at = now()
     ORDER BY s.id DESC
     LIMIT 1;
  END IF;

  -- #1375: los pagos se bloquean por id, como la foto de la rendicion, los
  -- creditos y los UPDATE por pedido. El orden del bucle de abajo es de negocio y
  -- no cambia; si bloqueara el, se cruzaria con la foto con dos pagos del dia.
  PERFORM 1
     FROM pagos
    WHERE pedido_id = p_pedido_id
    ORDER BY id
      FOR UPDATE;

  -- Se recorta desde el pago mas nuevo: el excedente es lo ultimo que se cargo.
  FOR v_pago IN
    SELECT id, monto, cliente_id, forma_pago, fecha, referencia, usuario_id, cobrado_por,
           sucursal_id, nota_credito_id, pago_origen_id, a_cuenta
      FROM pagos
     WHERE pedido_id = p_pedido_id
     ORDER BY fecha DESC, id DESC
     FOR UPDATE
  LOOP
    EXIT WHEN v_excedente <= 0.005;

    v_quitar := LEAST(v_pago.monto, v_excedente);

    -- #1329: un pago a cuenta es plata que entro, no un cobro por el total de la
    -- boleta: lo que sobra queda a favor del cliente, y la caja del dia no se
    -- mueve (por eso va con el escape del guard, como la reimputacion). Decision
    -- del dueño. El credito de una NC sigue por su rama de abajo, y un adelanto de
    -- sueldo no es plata que entro: se recorta.
    IF v_pago.nota_credito_id IS NULL
       AND COALESCE(v_pago.forma_pago, '') <> 'adelanto_sueldo'
       AND (v_pago.a_cuenta OR v_pago.pago_origen_id IS NOT NULL) THEN
      v_marca := ' [baja de total del pedido #' || p_pedido_id || '] [saldo a favor]';
      v_guc := current_setting('app.reimputacion_pagos', true);
      PERFORM set_config('app.reimputacion_pagos', 'on', true);

      IF v_quitar >= v_pago.monto - 0.005 THEN
        UPDATE pagos
           SET pedido_id = NULL,
               notas = trim(COALESCE(notas, '') || v_marca)
         WHERE id = v_pago.id;
        v_quitar := v_pago.monto;
      ELSE
        UPDATE pagos SET monto = monto - v_quitar WHERE id = v_pago.id;

        -- #1359: el pedazo guarda la raiz y su padre directo.
        INSERT INTO pagos (
          cliente_id, pedido_id, monto, forma_pago, fecha,
          referencia, notas, usuario_id, sucursal_id, pago_origen_id, a_cuenta,
          pago_padre_id
        )
        SELECT cliente_id, NULL, v_quitar, forma_pago, fecha, referencia,
               trim(COALESCE(notas, '') || v_marca),
               usuario_id, sucursal_id, COALESCE(pago_origen_id, id), true,
               id
          FROM pagos
         WHERE id = v_pago.id;
      END IF;

      PERFORM set_config('app.reimputacion_pagos', COALESCE(v_guc, ''), true);

      v_excedente := v_excedente - v_quitar;
      v_quitado   := v_quitado + v_quitar;
      CONTINUE;
    END IF;
    v_nota := ' [ajustado -' || trim(to_char(v_quitar, 'FM999999990.00')) ||
              ' por baja de total del pedido ' || p_pedido_id || ']';

    -- #1559 (COB-1): el recorte del cobro de boleta queda en la salvedad que lo
    -- hizo, con los datos del pago por si se borra entero. El credito de una NC
    -- no: lo que le sobra a la boleta vuelve a saldo a favor (abajo) y no hay
    -- cobro que reponer.
    IF v_salvedad IS NOT NULL AND v_pago.nota_credito_id IS NULL THEN
      UPDATE salvedades_items
         SET cobro_recortado = COALESCE(cobro_recortado, '[]'::jsonb)
               || jsonb_build_array(jsonb_build_object(
                    'pago_id',    v_pago.id,
                    'monto',      v_quitar,
                    'borrado',    v_pago.monto - v_quitar <= 0.005,
                    'cliente_id', v_pago.cliente_id,
                    'forma_pago', v_pago.forma_pago,
                    'fecha',      v_pago.fecha,
                    'referencia', v_pago.referencia,
                    'usuario_id', v_pago.usuario_id,
                    -- T4: de qué caja era, para que el cobro que repone anular_salvedad vuelva a ella.
                    'cobrado_por', v_pago.cobrado_por))
       WHERE id = v_salvedad;
    END IF;

    IF v_pago.monto - v_quitar > 0.005 THEN
      UPDATE pagos
         SET monto = monto - v_quitar,
             notas = trim(COALESCE(notas, '') || v_nota)
       WHERE id = v_pago.id;
    ELSE
      -- CHECK pagos_monto_positivo (#1246): el pago entero se borra en vez de
      -- pasar por monto 0. El UPDATE sin cambio de monto es a proposito: pasa
      -- por la misma guarda de caja que el recorte (guard_pago_fecha_cerrada es
      -- BEFORE UPDATE OF monto y el DELETE no la dispara), asi que borrarlo
      -- entero con la caja cerrada sigue rechazado igual que antes.
      UPDATE pagos
         SET monto = monto,
             notas = trim(COALESCE(notas, '') || v_nota)
       WHERE id = v_pago.id;
      DELETE FROM pagos WHERE id = v_pago.id;
    END IF;

    -- mig 276 (#833): un credito de NC no es plata que se devuelve, es un
    -- documento. Lo que la boleta ya no necesita vuelve a saldo a favor con el
    -- mismo documento (pago sin pedido), en vez de evaporarse. La proxima
    -- imputacion (aplicar_credito_cliente, que el trigger de reconciliacion
    -- llama enseguida) lo aplica a otra boleta, y la NC vuelve a ser anulable
    -- por ese pedazo. #1359: su padre es el pago recortado, aunque se haya borrado.
    IF v_pago.nota_credito_id IS NOT NULL THEN
      INSERT INTO pagos (
        cliente_id, pedido_id, monto, forma_pago, fecha,
        referencia, notas, usuario_id, sucursal_id, nota_credito_id, pago_origen_id,
        pago_padre_id
      ) VALUES (
        v_pago.cliente_id, NULL, v_quitar, v_pago.forma_pago, v_pago.fecha,
        v_pago.referencia,
        'Nota de credito #' || v_pago.nota_credito_id || ': vuelve por baja de total del pedido '
          || p_pedido_id || ' [saldo a favor]',
        v_pago.usuario_id, v_pago.sucursal_id, v_pago.nota_credito_id,
        COALESCE(v_pago.pago_origen_id, v_pago.id),
        v_pago.id
      );
    END IF;

    v_excedente := v_excedente - v_quitar;
    v_quitado   := v_quitado + v_quitar;
  END LOOP;

  RETURN v_quitado;
END;
$function$;

-- ---- anular_salvedad
CREATE OR REPLACE FUNCTION public.anular_salvedad(p_salvedad_id bigint, p_notas text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  -- venta-B3 (tanda 6 de #1603): la marca de precio conservado de quien llama.
  v_conservado_previo TEXT;
  v_sucursal BIGINT := current_sucursal_id();
  v_salvedad RECORD;
  v_usuario_id UUID := auth.uid();
  v_tipo_factura TEXT;
  v_pct_iva NUMERIC; v_pct_ii NUMERIC; v_costo_real NUMERIC; v_costo_sin NUMERIC;
  v_costo_prom NUMERIC;
  v_neto NUMERIC; v_iva NUMERIC; v_real NUMERIC;
  v_toca_promo BOOLEAN;
  v_merma_id BIGINT;
  -- #1050
  v_item_id BIGINT;
  v_pend INTEGER;
  v_saca INTEGER;
  v_huella INTEGER;
  r_lote RECORD;
  -- #1142 (mig 365): la huella por lote se repone despues
  -- de la bajada.
  v_rep_lote BIGINT[]  := '{}';
  v_rep_dev  INTEGER[] := '{}';
  v_rep_hue  INTEGER[] := '{}';
  v_i        INTEGER;
  v_cap      INTEGER;
  r_l        RECORD;
  v_g_origen TEXT; v_g_ref_tipo TEXT; v_g_ref_id TEXT; v_g_user TEXT; v_g_item TEXT;
  -- #1192: el combo de la salvedad.
  v_combo_rehecho JSONB;
  v_precio_combo  JSONB;
  -- #1327: el mensaje del guard de caja.
  v_caja_cerrada  TEXT;
  -- gastos 7: las roturas a cargo de empleados.
  v_rot_emp       BIGINT[];
  r_rot           RECORD;
  -- #1559 (COB-1): el cobro que esta salvedad recorto.
  v_plan          JSONB := '[]'::jsonb;
  r_rec           RECORD;
  v_vivo          BOOLEAN;
  v_accion        TEXT;
  v_fecha_rec     DATE;
  v_limite_caja   DATE;
  v_falta         NUMERIC;
  v_rep           NUMERIC;
  v_repuesto      NUMERIC := 0;
  v_sin_reponer   NUMERIC := 0;
  v_resultado     JSONB := '[]'::jsonb;
  -- 1595-b2 (#1595): las marcas del cobro que se repone como nuevo.
  v_marcas        JSONB;
  -- H4 de la revisión de C1: la raíz de la familia del adelanto que se repone.
  v_raiz          BIGINT;
  -- VTA-1 (#1595): la foto de la linea que la salvedad borro.
  v_foto_costo    NUMERIC;
  v_foto_lista    NUMERIC;
  v_foto_origen   TEXT;
  v_foto_desc     NUMERIC;
  v_foto_escala   BIGINT;
  v_foto_upb      INTEGER;
  v_foto_oupb     TEXT;
  -- 1592-b5: las promos a las que restituir la linea les devuelve el derecho.
  v_promos_toca   BIGINT[];
  v_sin_rastro    BOOLEAN;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;
  /* mig 252: SOLO ADMIN, y a proposito: anular restituye la linea, recalcula
     los totales y revierte la merma. Resolver, que no mueve nada, lo puede el
     encargado. El espejo en la UI es `puedeAnularSalvedad`.

     Y de paso, lo que hace que esta funcion pueda existir: mas abajo le inserta
     un pedido_item a un pedido YA ENTREGADO. Eso lo prohibe
     `pedido_items_guard_estado`, y pasa por un solo motivo: esta funcion es
     SECURITY DEFINER y es de postgres, asi que el guard la ve con
     current_user <> 'authenticated' y la deja pasar. Si alguien le saca el
     SECURITY DEFINER, anular deja de funcionar para las salvedades cuya linea
     habia quedado en cero. El ensayo de la 252 se pone rojo si eso pasa. */
  IF NOT es_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin');
  END IF;
  -- mig 331: bloqueada. Sin esto, dos anulaciones simultaneas pasaban las
  -- dos el "Ya anulada" y restaban dos veces el stock y el lote.
  SELECT * INTO v_salvedad FROM salvedades_items WHERE id = p_salvedad_id AND sucursal_id = v_sucursal
     FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'No encontrada'); END IF;
  IF v_salvedad.estado_resolucion = 'anulada' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Ya anulada');
  END IF;

  -- gastos 7: los empleados de las roturas vivas de esta salvedad, despues
  -- de la salvedad y antes que nada mas (el orden de _cargar_roturas). Una
  -- rotura viva es la que nadie compenso.
  v_rot_emp := ARRAY(SELECT DISTINCT m.empleado_id FROM empleado_movimientos m
                      WHERE m.salvedad_id = p_salvedad_id AND m.tipo = 'rotura' AND m.revierte_id IS NULL
                        AND NOT EXISTS (SELECT 1 FROM empleado_movimientos rv WHERE rv.revierte_id = m.id)
                      ORDER BY 1);
  PERFORM 1 FROM empleados WHERE id = ANY (v_rot_emp) ORDER BY id FOR UPDATE;
  IF EXISTS (SELECT 1 FROM empleados WHERE id = ANY (v_rot_emp) AND usuario_id = v_usuario_id) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Esta salvedad le cargó una rotura a tu propia cuenta: la anula otro admin', 'codigo', 'rotura_propia');
  END IF;

  -- #1055: sobre un pedido cancelado no hay nada que restituir: la
  -- cancelacion ya devolvio lo que quedaba en la linea. Anular igual volvia a
  -- poner la linea en un pedido cancelado (total > 0) y bajaba stock que no
  -- salio. Primero el lock del pedido: una cancelacion concurrente espera, o
  -- ya esta confirmada y se ve.
  -- #1446: antes, las otras boletas del cliente que los creditos pueden pagar,
  -- por id y junto con esta (_edicion_bloquea_boletas).
  PERFORM public._edicion_bloquea_boletas(v_salvedad.pedido_id, v_sucursal);
  PERFORM 1 FROM pedidos
   WHERE id = v_salvedad.pedido_id AND sucursal_id = v_sucursal
     FOR UPDATE;
  IF EXISTS (SELECT 1 FROM pedidos
              WHERE id = v_salvedad.pedido_id AND sucursal_id = v_sucursal
                AND estado IN ('cancelado', 'anulado')) THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'El pedido de esta salvedad esta cancelado: la cancelacion ya devolvio la mercaderia y no hay nada que restituir.',
      'codigo', 'pedido_cancelado'
    );
  END IF;

  -- #1327: un dia con la caja cerrada no cambia: ni el total, ni el stock.
  v_caja_cerrada := public._pedido_en_caja_cerrada(v_salvedad.pedido_id, v_sucursal);
  IF v_caja_cerrada IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error', v_caja_cerrada, 'codigo', 'caja_cerrada');
  END IF;

  -- #1163: lo mismo que registrar_salvedad (mig 276). Despues del lock del
  -- pedido: una NC concurrente (crear_nota_credito_venta_impl hace FOR UPDATE
  -- del pedido) espera o ya se ve. nota_credito_vigente_de_pedido no es
  -- definer: la ve porque esta funcion lo es.
  IF public.nota_credito_vigente_de_pedido(v_salvedad.pedido_id) IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error',
      'El pedido tiene la nota de crédito #' || public.nota_credito_vigente_de_pedido(v_salvedad.pedido_id)
      || ' vigente: anulala primero', 'codigo', 'nota_credito_vigente');
  END IF;

  -- #1161: una edicion de items posterior ya fijo las cantidades (y borro la
  -- linea: pedido_item_id queda NULL). Sumar lo de la salvedad lo restituiria
  -- dos veces. Solo actualizar_pedido_items escribe 'items' en
  -- pedido_historial (registrar_salvedad y anular no), asi que una segunda
  -- salvedad no bloquea. El pedido ya entregado no se puede editar: no hay
  -- salida en la app.
  IF EXISTS (SELECT 1 FROM pedido_historial h
              WHERE h.pedido_id = v_salvedad.pedido_id AND h.sucursal_id = v_sucursal
                AND h.campo_modificado = 'items' AND h.created_at > v_salvedad.created_at) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'El pedido se editó después de esta salvedad: la edición ya fijó las cantidades y anular sumaría de nuevo lo que la salvedad sacó. Ese camino no existe todavía: corregir a mano.',
      'codigo', 'pedido_editado');
  END IF;

  /* mig 234: registrar_salvedad toca estado de promociones (usos_pendientes,
     stock del contenedor, la linea de regalo) y anular no lo revierte. Hasta
     que exista el camino de alta, la anulacion que tocaria una promo se
     rechaza: descuadrarla en silencio es peor que no poder anular. */
  IF COALESCE(v_salvedad.es_bonificacion, FALSE) AND v_salvedad.promocion_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Esta salvedad es sobre un regalo de promocion. Anularla tendria que reponer el regalo y volver a consumir el contenedor, y ese camino no existe todavia: corregir a mano.',
      'codigo', 'anulacion_toca_promociones'
    );
  END IF;

  -- #1161: antes de 2026-09-09 la salvedad no guardaba es_bonificacion (183
  -- en NULL). Una a precio 0 es un regalo (la 264): reinsertarla como venta
  -- tira check_violation y fusionarla se lo cobraria al cliente.
  IF v_salvedad.es_bonificacion IS NULL AND v_salvedad.precio_unitario <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Esta salvedad es sobre una línea a precio 0 (un regalo anterior a que la salvedad guardara si lo era). Anularla tendría que reponer el regalo y ese camino no existe todavía: corregir a mano.',
      'codigo', 'anulacion_toca_promociones');
  END IF;

  -- #1162 / #1164: solo las promos de las que el pedido tuvo regalo (su
  -- foto, pedido_promo_reglas), con las reglas y los productos de la venta.
  -- Sin foto, lo vigente (promos_del_pedido). Antes recorria todas las promos
  -- de la sucursal con el producto: una creada despues de la venta, sin
  -- regalo en el pedido, rechazaba la anulacion.
  WITH promos AS (
    SELECT h.promocion_id, h.cantidad_compra AS cant_compra, h.cantidad_bonificacion AS cant_bonif, h.productos
      FROM public.promos_del_pedido(v_salvedad.pedido_id) h
     WHERE v_salvedad.producto_id = ANY (h.productos)
  ), disparadores AS (
    SELECT pm.promocion_id, pm.cant_compra,
           (SELECT COALESCE(SUM(pi.cantidad), 0)::INT
              FROM pedido_items pi
             WHERE pi.pedido_id   = v_salvedad.pedido_id
               AND pi.sucursal_id = v_sucursal
               AND COALESCE(pi.es_bonificacion, FALSE) = FALSE
               AND pi.producto_id = ANY (pm.productos)) AS qty
      FROM promos pm
     WHERE pm.cant_compra > 0 AND pm.cant_bonif > 0
  )
  SELECT array_agg(promocion_id ORDER BY promocion_id) INTO v_promos_toca
    FROM disparadores
   WHERE (qty + v_salvedad.cantidad_afectada) / cant_compra <> qty / cant_compra;
  v_toca_promo := v_promos_toca IS NOT NULL;

  /* 1592-b5 (#1592): cruzar un multiplo no quiere decir que se haya recortado
     un regalo. La resincronizacion de registrar_salvedad solo recorta si el
     pedido tenia mas regalo del que le queda derecho; si ninguna salvedad del
     pedido recorto nada, restituir deja el pedido como estaba. El recorte deja en
     audit_logs, en la transaccion de su salvedad (la misma created_at), el UPDATE
     a la baja o el DELETE de una linea de regalo. Se miran las transacciones de
     TODAS las salvedades del pedido, vivas o anuladas, no solo la de esta: otra
     salvedad puede haber recortado el regalo que esta restitucion vuelve a dar,
     y mirar solo la propia hacia que el resultado dependiera del orden en que se
     anulan (H1 de la revision de M4). Basta un recorte de esas promos en
     cualquiera de ellas para rechazar como antes.
     Cada linea del log se resuelve contra la linea viva o, si ya no existe,
     contra la fila de su DELETE. Una transaccion de salvedad sin ninguna fila de
     este pedido en el log, o una linea que no se puede resolver, no se puede
     saber: se rechaza como antes. */
  IF v_toca_promo THEN
    WITH tx AS (
      -- 1592-b5 residual (N1 de la revisión de M4; tanda 5 de #1603): una transacción cuyas
      -- salvedades son todas sobre un regalo de promo sólo bajó esa línea (el regalo que no llegó), no
      -- recortó nada. Esas salvedades no se anulan (la guarda de la mig 234, arriba), así que lo que se
      -- mira no depende del orden en que se anulan las demás.
      SELECT s.created_at
        FROM salvedades_items s
       WHERE s.pedido_id = v_salvedad.pedido_id AND s.sucursal_id = v_sucursal
       GROUP BY s.created_at
      HAVING NOT bool_and(COALESCE(s.es_bonificacion, false) AND s.promocion_id IS NOT NULL)
    ), filas AS (
      SELECT a.created_at, a.accion, a.old_data, a.new_data,
             COALESCE(
               (SELECT jsonb_build_object('pedido_id', pi.pedido_id, 'es_bonificacion', pi.es_bonificacion,
                                          'promocion_id', pi.promocion_id)
                  FROM pedido_items pi
                 WHERE pi.id = a.registro_id::bigint),
               (SELECT d.old_data
                  FROM audit_logs d
                 WHERE d.tabla = 'pedido_items' AND d.accion = 'DELETE' AND d.registro_id = a.registro_id
                 ORDER BY d.created_at DESC
                 LIMIT 1)) AS linea
        FROM audit_logs a
       WHERE a.tabla = 'pedido_items' AND a.sucursal_id = v_sucursal
         AND a.accion IN ('UPDATE', 'DELETE')
         AND a.created_at IN (SELECT tx.created_at FROM tx)
    )
    SELECT EXISTS (SELECT 1 FROM tx
                    WHERE NOT EXISTS (SELECT 1 FROM filas f
                                       WHERE f.created_at = tx.created_at
                                         AND f.linea->>'pedido_id' = v_salvedad.pedido_id::text))
           OR EXISTS (SELECT 1 FROM filas f WHERE f.linea IS NULL),
           EXISTS (SELECT 1 FROM filas f
                    WHERE f.linea->>'pedido_id' = v_salvedad.pedido_id::text
                      AND COALESCE((f.linea->>'es_bonificacion')::boolean, FALSE)
                      AND (f.linea->>'promocion_id')::bigint = ANY (v_promos_toca)
                      AND (f.accion = 'DELETE'
                           OR (f.new_data->>'cantidad')::numeric < (f.old_data->>'cantidad')::numeric
                           -- mig NNN (1583-a, H2 de la revisión): el recorte que sólo baja el
                           -- corte guardado (W×1 sigue W×1, corte 14 → 10) también es un recorte.
                           OR (f.new_data->>'regalo_corte')::numeric < (f.old_data->>'regalo_corte')::numeric))
      INTO v_sin_rastro, v_toca_promo;

    IF v_toca_promo THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'Restituir esta linea vuelve a dar derecho a un regalo de promocion que una salvedad de este pedido habia recortado. Reponerlo y volver a consumir el contenedor no esta implementado: corregir a mano.',
        'codigo', 'anulacion_toca_promociones'
      );
    ELSIF v_sin_rastro THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'Restituir esta linea vuelve a dar derecho a un regalo de promocion, y no se puede saber si una salvedad de este pedido lo recorto. Reponerlo y volver a consumir el contenedor no esta implementado: corregir a mano.',
        'codigo', 'anulacion_toca_promociones'
      );
    END IF;
  END IF;

  /* mig 244: una salvedad por dañado/vencido dejo una fila en mermas_stock
     (mig 234). Anularla sin anular la merma cuenta las mismas N unidades dos
     veces: facturadas por la linea restituida y perdidas por la merma. Si la
     fila no aparece, se corta ACA -- antes de restituir nada -- y se avisa:
     anular dejando una merma huerfana es descuadrar en silencio. */
  -- #847: el faltante por la misma razon, cuando la linea movio stock (un
  -- regalo de promo no llega aca: lo rechaza el guard de arriba). Las
  -- salvedades por faltante anteriores a #847 tienen su merma por backfill,
  -- salvo cinco que se revisan a mano (ver la migracion de #847).
  IF v_salvedad.motivo IN ('producto_danado', 'producto_vencido')
     OR (v_salvedad.motivo = 'faltante_stock' AND NOT COALESCE(v_salvedad.es_bonificacion, FALSE)) THEN
    SELECT id INTO v_merma_id
      FROM mermas_stock
     WHERE salvedad_id = p_salvedad_id
       AND sucursal_id = v_sucursal
       AND anulada_at IS NULL
     ORDER BY id
     LIMIT 1;

    IF v_merma_id IS NULL THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'Esta salvedad genero una merma y no se encontro la fila para anularla. Anularla igual dejaria la mercaderia contada dos veces: corregir a mano.',
        'codigo', 'merma_no_encontrada'
      );
    END IF;
  END IF;

  -- #1559 (COB-1, decision del dueño 12/11): anular repone el cobro de boleta
  -- que esta salvedad recorto (desafectar_sobrepago_pedido lo anoto en
  -- cobro_recortado), y la boleta queda como si la salvedad no hubiera
  -- existido. Aca se decide que se hace con cada recorte, antes de tocar nada:
  --   · 'sumar': el pago sigue en esta boleta, no esta en la foto de una
  --     rendicion cerrada (#1248) y su fecha sigue abierta: se le devuelve lo
  --     que se le saco.
  --   · 'nuevo': el recorte lo borro entero (esta salvedad u otra de la misma
  --     boleta), o el pago esta en la foto de una rendicion cerrada o en un dia
  --     con la caja cerrada (decision del dueño 13/11): vuelve como un cobro
  --     nuevo con sus datos y su chofer, y el pago de la foto no se toca. Si su
  --     fecha ya esta cerrada (ultima_fecha_caja_cerrada es el ultimo dia
  --     confirmado de la sucursal), lleva la de hoy, como cualquier cobro tardio.
  --   · 'nada': el pago ya no existe o se fue a otra boleta sin que lo haya
  --     borrado una salvedad (decision del dueño 13/11). No se repone, y la
  --     respuesta lo dice.
  -- La boleta ya esta bloqueada (arriba); los pagos, por id.
  -- 1559-c2 (#1559): y antes que los pagos, el producto de la salvedad, el orden
  -- de registrar_salvedad (pedido, linea, productos, pagos). Al reves, con un
  -- pago recortado que se fue a otra boleta y una salvedad sobre ella con el
  -- mismo producto, cada una esperaba a la otra (40P01).
  PERFORM 1 FROM productos
   WHERE id = v_salvedad.producto_id AND sucursal_id = v_sucursal
     FOR UPDATE;
  IF jsonb_array_length(COALESCE(v_salvedad.cobro_recortado, '[]'::jsonb)) > 0 THEN
    PERFORM 1 FROM pagos
     WHERE id IN (SELECT (e->>'pago_id')::bigint
                    FROM jsonb_array_elements(v_salvedad.cobro_recortado) e)
     ORDER BY id
       FOR UPDATE;

    v_limite_caja := public.ultima_fecha_caja_cerrada(v_sucursal);

    FOR r_rec IN
      SELECT e, (e->>'pago_id')::bigint AS pago_id
        FROM jsonb_array_elements(v_salvedad.cobro_recortado) e
    LOOP
      SELECT pg.fecha INTO v_fecha_rec
        FROM pagos pg
       WHERE pg.id = r_rec.pago_id
         AND pg.pedido_id = v_salvedad.pedido_id
         AND pg.sucursal_id = v_sucursal;
      v_vivo := FOUND;

      IF v_vivo AND NOT EXISTS (
           SELECT 1
             FROM rendicion_pagos_confirmados fo
             JOIN rendiciones_control rc ON rc.id = fo.rendicion_id
            WHERE fo.pago_id = r_rec.pago_id
              AND rc.estado IN ('confirmada', 'resuelta'))
         AND (v_limite_caja IS NULL OR v_fecha_rec > v_limite_caja) THEN
        v_accion := 'sumar';
      ELSIF v_vivo OR EXISTS (
           SELECT 1
             FROM salvedades_items s
             CROSS JOIN LATERAL jsonb_array_elements(COALESCE(s.cobro_recortado, '[]'::jsonb)) x
            WHERE s.pedido_id = v_salvedad.pedido_id
              AND s.sucursal_id = v_sucursal
              AND (x->>'pago_id')::bigint = r_rec.pago_id
              AND (x->>'borrado')::boolean) THEN
        v_accion := 'nuevo';
        v_fecha_rec := (r_rec.e->>'fecha')::date;
        IF v_limite_caja IS NOT NULL AND v_fecha_rec <= v_limite_caja THEN
          v_fecha_rec := public._tablero_hoy();
        END IF;
      ELSE
        v_accion := 'nada';
      END IF;

      -- #1327: guard_pago_fecha_cerrada tiraria al reponer. Con la caja cerrada
      -- tambien hoy no hay fecha donde cargar el cobro: se frena aca, antes de
      -- restituir nada.
      IF v_accion <> 'nada' AND v_limite_caja IS NOT NULL AND v_fecha_rec <= v_limite_caja THEN
        RETURN jsonb_build_object('success', false, 'codigo', 'caja_cerrada', 'error',
          format('Anular esta salvedad repone el cobro que recortó, y la caja está cerrada hasta el %s, hoy incluido: para anularla hay que reabrir las rendiciones hasta esa fecha.',
                 to_char(v_limite_caja, 'DD/MM/YYYY')));
      END IF;

      -- 1595-b2 (#1595): el cobro que vuelve como nuevo es el mismo que se recortó,
      -- con sus marcas (a_cuenta, pago_origen_id, pago_padre_id): un adelanto de
      -- sueldo del FIFO de la ficha sigue siendo un pago a cuenta, y desimputar_pago
      -- lo acepta. Del pago vivo (foto de una rendición cerrada o caja cerrada) o, si
      -- el recorte lo borró, de la fila de su DELETE en audit_logs.
      v_marcas := NULL;
      IF v_accion = 'nuevo' THEN
        SELECT jsonb_build_object('a_cuenta', pg.a_cuenta, 'pago_origen_id', pg.pago_origen_id,
                                  'pago_padre_id', pg.pago_padre_id)
          INTO v_marcas
          FROM pagos pg
         WHERE pg.id = r_rec.pago_id AND pg.sucursal_id = v_sucursal;
        IF v_marcas IS NULL THEN
          SELECT jsonb_build_object('a_cuenta', a.old_data->'a_cuenta',
                                    'pago_origen_id', a.old_data->'pago_origen_id',
                                    'pago_padre_id', a.old_data->'pago_padre_id')
            INTO v_marcas
            FROM audit_logs a
           WHERE a.tabla = 'pagos' AND a.accion = 'DELETE'
             AND a.registro_id = r_rec.pago_id::text
             AND a.sucursal_id = v_sucursal
           ORDER BY a.created_at DESC
           LIMIT 1;
        END IF;
      END IF;

      v_plan := v_plan || jsonb_build_array(r_rec.e || jsonb_build_object('accion', v_accion,
                                                                          'fecha_reposicion', v_fecha_rec)
                                                    || CASE WHEN v_marcas IS NULL THEN '{}'::jsonb
                                                            ELSE jsonb_build_object('marcas', v_marcas) END);
    END LOOP;
  END IF;

  -- Restituir lo que la salvedad saco no es cargar un pedido nuevo:
  -- el minimo de venta no debe trabarlo (mig 174).
  PERFORM set_config('app.omitir_minimo_venta', '1', true);

  SELECT COALESCE(tipo_factura, 'ZZ') INTO v_tipo_factura
    FROM pedidos WHERE id = v_salvedad.pedido_id AND sucursal_id = v_sucursal;
  SELECT pi.id INTO v_item_id FROM pedido_items pi
   WHERE pi.id = v_salvedad.pedido_item_id AND pi.sucursal_id = v_sucursal
     FOR UPDATE;
  IF v_item_id IS NULL THEN
    -- #1161 (decision del dueño 2026-10-14, opcion A): la linea se borro (la
    -- salvedad la dejo en 0). Si el pedido tiene otra con la misma clave (la
    -- reinsertada por otra anulacion), se le suma ahi: mismo precio, asi el
    -- total vuelve al de antes por construccion. Regalo y venta no se mezclan,
    -- ni dos precios. Sin ninguna, se inserta (abajo).
    SELECT pi.id INTO v_item_id FROM pedido_items pi
     WHERE pi.pedido_id = v_salvedad.pedido_id AND pi.sucursal_id = v_sucursal
       AND pi.producto_id = v_salvedad.producto_id
       AND COALESCE(pi.es_bonificacion, FALSE) = COALESCE(v_salvedad.es_bonificacion, FALSE)
       AND pi.promocion_id IS NOT DISTINCT FROM v_salvedad.promocion_id
       -- #1192: la de un combo vuelve a su pozo, a cualquier precio (rehacer
       -- el combo la pone en su lugar); la que no es de un combo no se suma a
       -- una que si lo es.
       AND CASE WHEN v_salvedad.combo_id IS NULL
                THEN pi.precio_unitario = v_salvedad.precio_unitario
                     AND pi.combo_id IS NULL AND pi.combo_roto_id IS NULL
                ELSE v_salvedad.combo_id IN (pi.combo_id, pi.combo_roto_id) END
     ORDER BY (pi.combo_id IS NOT DISTINCT FROM v_salvedad.combo_id) DESC, pi.id
     LIMIT 1
       FOR UPDATE;
  END IF;
  IF v_item_id IS NOT NULL THEN
    -- #1140 (decision del dueño 2026-10-13, opcion A): se suma lo que ESTA
    -- salvedad saco, no se vuelve a cantidad_original. Con otra salvedad viva
    -- sobre la misma linea, volver al original borraba tambien lo que recorto
    -- la otra (y con devolucion la linea subia mas de lo que bajaba el stock).
    -- Cada anulacion deshace solo lo suyo, asi que el resultado no depende del
    -- orden; y v_toca_promo, arriba, ya mide la linea + cantidad_afectada. En
    -- el SET, `cantidad` es el valor viejo en las dos expresiones; el precio es
    -- el de la fila, que registrar_salvedad no cambia.
    UPDATE pedido_items SET
      cantidad = cantidad + v_salvedad.cantidad_afectada,
      subtotal = (cantidad + v_salvedad.cantidad_afectada) * precio_unitario
    WHERE id = v_item_id AND sucursal_id = v_sucursal;
  ELSE
    -- #1274: la alicuota de la venta, no la de hoy. La linea ya no existe y
    -- la salvedad no la guarda: la foto es la fila que dejo su DELETE en
    -- audit_logs. Una foto 0 es ambigua (#1258) y cae, como la falta de fila, a
    -- la regla sobre el producto.
    SELECT COALESCE(
             (SELECT NULLIF((a.old_data->>'porcentaje_iva')::numeric, 0)
                FROM audit_logs a
               WHERE a.tabla = 'pedido_items' AND a.accion = 'DELETE'
                 AND a.sucursal_id = v_sucursal
                 AND a.old_data->>'pedido_id' = v_salvedad.pedido_id::text
                 AND a.old_data->>'producto_id' = v_salvedad.producto_id::text
                 AND COALESCE((a.old_data->>'es_bonificacion')::boolean, FALSE) = COALESCE(v_salvedad.es_bonificacion, FALSE)
               ORDER BY a.created_at DESC
               LIMIT 1),
             public._alicuota_iva_venta(condicion_iva, porcentaje_iva)),
           COALESCE(impuestos_internos, 0), costo_promedio, costo_real, costo_sin_iva
      INTO v_pct_iva, v_pct_ii, v_costo_prom, v_costo_real, v_costo_sin
      FROM productos WHERE id = v_salvedad.producto_id AND sucursal_id = v_sucursal;
    SELECT d.neto, d.iva, d.ingreso_real INTO v_neto, v_iva, v_real
      FROM calcular_desglose_venta(v_salvedad.precio_unitario, v_pct_iva, v_pct_ii, v_tipo_factura) d;
    -- #1192: sin linea en el pozo, vuelve como linea del combo si estaba a
    -- precio de combo, o como la parte que salio de el si no.
    IF v_salvedad.combo_id IS NOT NULL THEN
      SELECT f.precios->(v_salvedad.producto_id::text) INTO v_precio_combo
        FROM pedido_combos f
       WHERE f.pedido_id = v_salvedad.pedido_id AND f.combo_id = v_salvedad.combo_id
         AND f.sucursal_id = v_sucursal;
      IF NOT (v_salvedad.precio_unitario = (v_precio_combo->>'combo')::numeric
              AND COALESCE((v_precio_combo->>'sin_combo')::numeric, 0) > 0) THEN
        v_precio_combo := NULL;
      END IF;
    END IF;

    -- VTA-1 (#1595): la foto que registrar_salvedad guardo al borrar la linea:
    -- el costo, la lista, el origen, el descuento, la escala y el factor de bloque
    -- de la venta, no los de hoy. Sin foto (salvedades anteriores a la NNN), lo de
    -- antes: el costo de hoy, y la lista, el origen y el descuento que completa el
    -- trigger. El origen, el descuento y la escala son de la linea que era: si vuelve como otra (era del combo y
    -- vuelve como la parte que salio de el, o al reves), los completa el trigger.
    SELECT f.costo_unitario_al_crear, f.precio_lista_al_crear, f.origen_precio, f.descuento_pct,
           f.grupo_precio_escala_id, f.unidades_por_bloque_al_crear, f.origen_unidades_por_bloque
      INTO v_foto_costo, v_foto_lista, v_foto_origen, v_foto_desc,
           v_foto_escala, v_foto_upb, v_foto_oupb
      FROM salvedad_linea_foto f
     WHERE f.salvedad_id = p_salvedad_id AND f.sucursal_id = v_sucursal;
    IF (v_foto_origen = 'combo') IS DISTINCT FROM (v_precio_combo IS NOT NULL) THEN
      v_foto_origen := NULL;
      v_foto_desc   := NULL;
      v_foto_escala := NULL;
    END IF;

    -- venta-B3 (tanda 6 de #1603): la línea vuelve con el mismo producto, el mismo
    -- precio y la cantidad que esta salvedad sacó: no es una venta nueva. Si hoy el
    -- producto no tiene lista, validar_precio_item_pedido la deja entrar por la misma
    -- marca que la edición (D20 de 1559-b3), sólo para esta línea; la de quien llama
    -- vuelve a como estaba después del INSERT.
    v_conservado_previo := current_setting('app.edicion_precio_conservado', true);
    PERFORM set_config('app.edicion_precio_conservado',
      (COALESCE(NULLIF(v_conservado_previo, '')::jsonb, '{}'::jsonb)
       || jsonb_build_object(v_salvedad.pedido_id || ':' || v_salvedad.producto_id || ':'
                               || v_salvedad.precio_unitario::numeric(10,2)::text,
                             v_salvedad.cantidad_afectada))::text, true);
    INSERT INTO pedido_items (
      pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id,
      neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva,
      ingreso_real_unitario, costo_unitario_al_crear,
      precio_lista_al_crear, origen_precio, descuento_pct,
      grupo_precio_escala_id, unidades_por_bloque_al_crear, origen_unidades_por_bloque,
      es_bonificacion, promocion_id,
      combo_id, precio_sin_combo_unitario, combo_roto_id
    )
    VALUES (
      -- #1140: la linea no existe (esta en 0): vuelve lo de esta salvedad.
      v_salvedad.pedido_id, v_salvedad.producto_id, v_salvedad.cantidad_afectada,
      v_salvedad.precio_unitario, v_salvedad.cantidad_afectada * v_salvedad.precio_unitario, v_sucursal,
      v_neto, v_iva, 0, v_pct_iva,
      v_real,
      -- mig 257 (#673): la cascada unica de la 238, no una copia. VTA-1: la foto
      -- es el snapshot; una foto NULL cae al costo de hoy, como en los reportes.
      public.costo_valuacion(v_foto_costo, v_costo_prom, v_costo_real, v_costo_sin, v_pct_ii),
      v_foto_lista, v_foto_origen, v_foto_desc,
      v_foto_escala, v_foto_upb, v_foto_oupb,
      COALESCE(v_salvedad.es_bonificacion, FALSE), v_salvedad.promocion_id,
      CASE WHEN v_precio_combo IS NOT NULL THEN v_salvedad.combo_id END,
      CASE WHEN v_precio_combo IS NOT NULL THEN (v_precio_combo->>'sin_combo')::numeric END,
      CASE WHEN v_salvedad.combo_id IS NOT NULL AND v_precio_combo IS NULL THEN v_salvedad.combo_id END
    ) RETURNING id INTO v_item_id;
    PERFORM set_config('app.edicion_precio_conservado', COALESCE(v_conservado_previo, ''), true);
  END IF;
  -- #1192: el total se recalcula al final, despues de rehacer el combo.
  -- #1073: tambien sin devolucion. Una merma sobre la linea entera borro la
  -- linea y su huella se fue en cascada; registrar_salvedad la anoto
  -- (lotes_devueltos con cantidad 0) y aca se le repone a la linea restituida.
  IF v_salvedad.stock_devuelto OR v_salvedad.lotes_devueltos IS NOT NULL THEN
    /* #1050: las unidades salen por el mismo camino por el que entraron.
       registrar_salvedad las devolvio a un lote por FEFO y anoto a cual
       (lotes_devueltos). El camino de BAJADA del trigger no mira el origen:
       come primero de la bolsa, asi que bajar el stock sin mas dejaba el lote
       +N y la bolsa -N. El molde es el de la 229 para la compra anulada:
       primero se actua sobre el lote (se le sacan las unidades anotadas, lo que
       todavia tenga), y recien despues baja el stock. Para el trigger esas
       unidades ya son bolsa, y la bajada se come exactamente esas.

       Lo que no esta en el lote (se vendio despues, o el lote se borro) y las
       salvedades anteriores a la anotacion (NULL: su devolucion fue a la bolsa,
       relevado en la migracion) salen por el camino de siempre: bolsa y despues
       FEFO, con huella para esta linea como una venta.

       La huella que la devolucion le saco al cliente en cada lote se le repone
       a la linea restituida, sin pasar lo que el lote consumio de verdad.

       set_config es por TRANSACCION (229): se guardan los GUCs y se restauran
       despues del UPDATE, para no mentirle a lo que siga en el caller. */
    v_g_origen   := current_setting('app.stock_origen', true);
    v_g_ref_tipo := current_setting('app.stock_ref_tipo', true);
    v_g_ref_id   := current_setting('app.stock_ref_id', true);
    v_g_user     := current_setting('app.stock_user_id', true);
    v_g_item     := current_setting('app.stock_pedido_item_id', true);

    PERFORM 1 FROM productos
     WHERE id = v_salvedad.producto_id AND sucursal_id = v_sucursal
       FOR UPDATE;

    v_pend := v_salvedad.cantidad_afectada;
    FOR r_lote IN
      SELECT l.id, l.cantidad, l.cantidad_restante, a.devuelto, a.huella
        FROM (
          SELECT l2.id,
                 SUM(COALESCE(x.cantidad, 0))::integer AS devuelto,
                 SUM(COALESCE(x.huella, 0))::integer   AS huella
            FROM jsonb_to_recordset(COALESCE(v_salvedad.lotes_devueltos, '[]'::jsonb))
                 AS x(lote_id bigint, cantidad integer, huella integer,
                      compra_id bigint, fecha_vencimiento date)
            -- mig 331: por id, o por (compra, producto, vencimiento). Desde
            -- #1054 editar la compra conserva el id del lote (y reapunta la
            -- anotacion si lo fusiona); la clave queda para las anotaciones
            -- hechas antes, cuando la edicion recreaba el lote con otro id.
            JOIN producto_lotes l2
              ON (l2.id = x.lote_id
                  OR (x.compra_id IS NOT NULL
                      AND l2.compra_id = x.compra_id
                      AND l2.fecha_vencimiento = x.fecha_vencimiento))
             AND l2.producto_id = v_salvedad.producto_id
             AND l2.sucursal_id = v_sucursal
           GROUP BY l2.id
        ) a
        JOIN producto_lotes l ON l.id = a.id
       ORDER BY l.fecha_vencimiento, l.id
         FOR UPDATE OF l
    LOOP
      v_saca := GREATEST(LEAST(r_lote.devuelto, r_lote.cantidad_restante, v_pend), 0);
      IF v_saca > 0 THEN
        UPDATE producto_lotes
           SET cantidad_restante = cantidad_restante - v_saca
         WHERE id = r_lote.id;
        v_pend := v_pend - v_saca;
      END IF;

      -- La huella de este lote se repone despues de la bajada (abajo), en el
      -- mismo orden FEFO.
      v_rep_lote := v_rep_lote || r_lote.id;
      v_rep_dev  := v_rep_dev  || r_lote.devuelto;
      v_rep_hue  := v_rep_hue  || r_lote.huella;
    END LOOP;

    -- #1073: sin devolucion (la merma) no hay bajada: solo se repuso la huella.
    IF v_salvedad.stock_devuelto THEN
      -- mig 244: la bajada sale etiquetada para el ledger.
      PERFORM set_config('app.stock_origen',   'salvedad_anulada',  true);
      PERFORM set_config('app.stock_ref_tipo', 'salvedad',          true);
      PERFORM set_config('app.stock_ref_id',   p_salvedad_id::TEXT, true);
      PERFORM set_config('app.stock_user_id',  COALESCE(v_usuario_id::TEXT, ''), true);
      PERFORM set_config('app.stock_pedido_item_id', COALESCE(v_item_id::TEXT, ''), true);

      UPDATE productos SET stock = stock - v_salvedad.cantidad_afectada
       WHERE id = v_salvedad.producto_id AND sucursal_id = v_sucursal;
    END IF;

    /* #1142 / #1073 (mig 365): la huella que la devolucion
       le saco al cliente en cada lote se le repone a la linea restituida.
       Va DESPUES de la bajada para saber cuanto le falta a la linea: si la
       bolsa no alcanzo, la bajada cayo por FEFO en otro lote y
       _consumir_lotes_fefo ya le escribio huella ahi (la linea va en
       app.stock_pedido_item_id). Esa va primero, y la reposicion cubre lo que
       falta hasta la cantidad de la linea: nunca la supera (LOTE-D).
       Con la bolsa suficiente la bajada no escribe huella y la traza vuelve
       entera, tambien si el lote quedo agotado o solo para la traza entre
       registrar y anular (el cliente tiene esas unidades de ese lote; salen
       de la bolsa). La 364 topaba con lo que se le saco al lote (v_saca) y en
       ese caso la dejaba en 0.
       Tope por lote, el de siempre, medido despues de la bajada: la huella de
       lo que volvio a este lote no pasa lo que el lote consumio. #1085: la
       que el cliente perdio sin que las unidades entraran al lote (sin hueco,
       o solo para la traza: fueron a la bolsa) no paso por su contador, y se
       repone entera. Un lote que quedo solo para la traza despues de
       registrar no tiene contador que mirar: ver abajo. */
    v_cap := GREATEST(
      COALESCE((SELECT cantidad FROM pedido_items WHERE id = v_item_id), 0)
      - (SELECT COALESCE(SUM(cantidad), 0)::int FROM pedido_item_lotes WHERE pedido_item_id = v_item_id), 0);
    FOR v_i IN 1 .. COALESCE(array_length(v_rep_lote, 1), 0) LOOP
      SELECT cantidad, cantidad_restante, solo_traza INTO r_l FROM producto_lotes WHERE id = v_rep_lote[v_i];
      IF r_l.solo_traza THEN
        /* Lote solo para la traza (mig 338): sus unidades vivas, tambien las
           que esta salvedad le habia devuelto, pasaron a la bolsa cuando se
           saco su vencimiento, y su cantidad quedo en lo consumido en ese
           momento, sin contar lo que la salvedad viva habia devuelto. Su
           contador no dice nada de esta huella: toda ella se trata como la de
           #1085 y se repone entera (con el tope de la linea), y la cantidad del
           lote sube hasta cubrir la huella que lo apunta (es lo que salio de
           el), para que si el vencimiento vuelve a cargarse lo consumido la
           incluya. Restante sigue en 0. */
        v_huella := LEAST(v_rep_hue[v_i], v_cap);
      ELSE
        v_huella := LEAST(
          GREATEST(LEAST(
            LEAST(v_rep_hue[v_i], v_rep_dev[v_i]),
            (r_l.cantidad - r_l.cantidad_restante)
              - (SELECT COALESCE(SUM(cantidad), 0)::int FROM pedido_item_lotes WHERE lote_id = v_rep_lote[v_i])), 0)
            + GREATEST(v_rep_hue[v_i] - v_rep_dev[v_i], 0),
          v_cap);
      END IF;
      IF v_huella > 0 AND v_item_id IS NOT NULL THEN
        INSERT INTO pedido_item_lotes (pedido_item_id, lote_id, cantidad, sucursal_id)
        VALUES (v_item_id, v_rep_lote[v_i], v_huella, v_sucursal)
        ON CONFLICT (pedido_item_id, lote_id)
          DO UPDATE SET cantidad = pedido_item_lotes.cantidad + EXCLUDED.cantidad;
        v_cap := v_cap - v_huella;
        IF r_l.solo_traza THEN
          UPDATE producto_lotes
             SET cantidad = GREATEST(cantidad,
                   (SELECT COALESCE(SUM(cantidad), 0)::int FROM pedido_item_lotes WHERE lote_id = v_rep_lote[v_i]))
           WHERE id = v_rep_lote[v_i];
        END IF;
      END IF;
    END LOOP;

    PERFORM set_config('app.stock_origen',         COALESCE(v_g_origen, ''),   true);
    PERFORM set_config('app.stock_ref_tipo',       COALESCE(v_g_ref_tipo, ''), true);
    PERFORM set_config('app.stock_ref_id',         COALESCE(v_g_ref_id, ''),   true);
    PERFORM set_config('app.stock_user_id',        COALESCE(v_g_user, ''),     true);
    PERFORM set_config('app.stock_pedido_item_id', COALESCE(v_g_item, ''),     true);
  END IF;

  -- #1192: el combo se rehace SIN esta salvedad: lo que el cliente habia
  -- rechazado vuelve, y si eso rearma combos, lo que habia salido de ellos
  -- vuelve al precio de combo. Rehacer es una funcion del estado, asi que
  -- anular en cualquier orden deja el pedido como si la salvedad no hubiera
  -- existido. Va despues de reponer la huella de la linea (que la mira sola).
  IF v_salvedad.combo_id IS NOT NULL THEN
    v_combo_rehecho := public._combo_rehacer(v_salvedad.pedido_id, v_sucursal, v_salvedad.combo_id,
                                             p_salvedad_id);
    IF v_combo_rehecho IS NOT NULL THEN
      UPDATE salvedades_items
         SET combo_detalle = COALESCE(combo_detalle, '{}'::jsonb)
                             || jsonb_build_object('anulacion', v_combo_rehecho)
       WHERE id = p_salvedad_id AND sucursal_id = v_sucursal;
    END IF;
  END IF;

  UPDATE pedidos SET
    total = (SELECT COALESCE(SUM(subtotal), 0) + CASE WHEN COALESCE(SUM(subtotal), 0) > 0 THEN pedidos.cargo_envio ELSE 0 END
               FROM pedido_items WHERE pedido_id = v_salvedad.pedido_id AND sucursal_id = v_sucursal),
    total_neto = (SELECT COALESCE(SUM(CASE WHEN NOT COALESCE(es_bonificacion, false) THEN cantidad * COALESCE(neto_unitario, precio_unitario) ELSE 0 END), 0)
                         -- cargo_1_base: el envio efectivo (0 si no queda ninguna linea).
                         + (public.cargo_envio_desglose(CASE WHEN COALESCE(SUM(subtotal), 0) > 0 THEN pedidos.cargo_envio ELSE 0 END,
                                                       pedidos.tipo_factura)).neto
                    FROM pedido_items WHERE pedido_id = v_salvedad.pedido_id AND sucursal_id = v_sucursal),
    total_iva = (SELECT COALESCE(SUM(CASE WHEN NOT COALESCE(es_bonificacion, false) THEN cantidad * COALESCE(iva_unitario, 0) ELSE 0 END), 0)
                        + (public.cargo_envio_desglose(CASE WHEN COALESCE(SUM(subtotal), 0) > 0 THEN pedidos.cargo_envio ELSE 0 END,
                                                      pedidos.tipo_factura)).iva
                   FROM pedido_items WHERE pedido_id = v_salvedad.pedido_id AND sucursal_id = v_sucursal),
    total_real = (SELECT COALESCE(SUM(CASE WHEN NOT COALESCE(es_bonificacion, false)
                          THEN cantidad * COALESCE(ingreso_real_unitario,
                               CASE WHEN v_tipo_factura = 'VB' THEN precio_unitario WHEN v_tipo_factura = 'FC' THEN COALESCE(neto_unitario, precio_unitario) ELSE precio_unitario END)
                          ELSE 0 END), 0)
                    FROM pedido_items WHERE pedido_id = v_salvedad.pedido_id AND sucursal_id = v_sucursal),
    -- CLAUDE.md: el UPDATE que cambia el total de un vale blanco nombra
    -- monto_pagado en el SET.
    monto_pagado = CASE WHEN pedidos.tipo_factura = 'VB'
                        THEN (SELECT COALESCE(SUM(subtotal), 0) FROM pedido_items
                               WHERE pedido_id = v_salvedad.pedido_id AND sucursal_id = v_sucursal)
                        ELSE pedidos.monto_pagado END,
    updated_at = NOW()
  WHERE id = v_salvedad.pedido_id AND sucursal_id = v_sucursal;

  -- #1559 (COB-1): con el total de vuelta, cada recorte vuelve a la boleta, con
  -- tope en lo que la boleta debe (monto_pagado lo recalcula el trigger de pagos
  -- en cada paso). Lo que no se repone queda en la respuesta.
  FOR r_rec IN SELECT e FROM jsonb_array_elements(v_plan) e LOOP
    SELECT GREATEST(total - COALESCE(monto_pagado, 0), 0) INTO v_falta
      FROM pedidos WHERE id = v_salvedad.pedido_id AND sucursal_id = v_sucursal;
    v_rep := CASE WHEN r_rec.e->>'accion' = 'nada' THEN 0
                  ELSE round(LEAST((r_rec.e->>'monto')::numeric, v_falta), 2) END;

    -- H4 de la revisión de C1 (con N1 y N4): no se le repone un adelanto de sueldo a un empleado
    -- dado de baja, sea el de la ficha de hoy o el de los movimientos de esa familia de pagos (raíz,
    -- pedazo o el pago que vuelve a crecer). Si no hay nada que reponer (v_rep = 0), no se frena.
    IF v_rep > 0 AND r_rec.e->>'forma_pago' = 'adelanto_sueldo' THEN
      v_raiz := COALESCE((SELECT pg.pago_origen_id FROM pagos pg WHERE pg.id = (r_rec.e->>'pago_id')::bigint),
                         (r_rec.e->'marcas'->>'pago_origen_id')::bigint,
                         (r_rec.e->>'pago_id')::bigint);
      IF EXISTS (SELECT 1 FROM empleados em
                  WHERE em.cliente_id = (r_rec.e->>'cliente_id')::bigint AND NOT em.activo)
         OR EXISTS (SELECT 1 FROM empleado_movimientos m
                      JOIN empleados em ON em.id = m.empleado_id
                     WHERE NOT em.activo
                       AND (m.pago_id = (r_rec.e->>'pago_id')::bigint OR m.pago_raiz_id = v_raiz)) THEN
        RAISE EXCEPTION 'Ese cliente es la ficha de un empleado dado de baja: ya no se le dan adelantos de sueldo';
      END IF;
    END IF;

    IF v_rep > 0 AND r_rec.e->>'accion' = 'sumar' THEN
      UPDATE pagos
         SET monto = monto + v_rep,
             notas = trim(COALESCE(notas, '') || ' [repuesto +'
                     || trim(to_char(v_rep, 'FM999999990.00'))
                     || ' por anulacion de la salvedad #' || p_salvedad_id || ']')
       WHERE id = (r_rec.e->>'pago_id')::bigint;
    ELSIF v_rep > 0 AND r_rec.e->>'accion' = 'nuevo' THEN
      INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, referencia,
                         notas, usuario_id, sucursal_id,
                         a_cuenta, pago_origen_id, pago_padre_id, cobrado_por)
      SELECT p.cliente_id, p.id, v_rep, r_rec.e->>'forma_pago', (r_rec.e->>'fecha_reposicion')::date,
             r_rec.e->>'referencia',
             'Cobro repuesto por anulacion de la salvedad #' || p_salvedad_id
               || ' (lo habia recortado del pago #' || (r_rec.e->>'pago_id') || ')',
             (r_rec.e->>'usuario_id')::uuid, v_sucursal,
             -- 1595-b2: las marcas del recortado (CHECK pagos_pedazo_con_padre: las
             -- dos o ninguna).
             COALESCE((r_rec.e->'marcas'->>'a_cuenta')::boolean, false),
             COALESCE((r_rec.e->'marcas'->>'pago_origen_id')::bigint, (r_rec.e->'marcas'->>'pago_padre_id')::bigint),
             COALESCE((r_rec.e->'marcas'->>'pago_padre_id')::bigint, (r_rec.e->'marcas'->>'pago_origen_id')::bigint),
             -- T4 (#1710): la caja del cobro recortado. Un recorte anterior a la T4 no la guardó:
             -- la de antes, el chofer de la boleta o quien lo cargó.
             COALESCE((r_rec.e->>'cobrado_por')::uuid, p.transportista_id, (r_rec.e->>'usuario_id')::uuid)
        FROM pedidos p
       WHERE p.id = v_salvedad.pedido_id AND p.sucursal_id = v_sucursal;
    END IF;

    v_repuesto    := v_repuesto + v_rep;
    v_sin_reponer := v_sin_reponer + (r_rec.e->>'monto')::numeric - v_rep;
    v_resultado   := v_resultado || jsonb_build_array(r_rec.e || jsonb_build_object('repuesto', v_rep));
  END LOOP;

  IF jsonb_array_length(v_resultado) > 0 THEN
    UPDATE salvedades_items SET cobro_recortado = v_resultado
     WHERE id = p_salvedad_id AND sucursal_id = v_sucursal;
  END IF;

  /* mig 244: la merma se anula, y productos.stock NO se toca. La salvedad por
     dañado/vencido dejo neto CERO sobre el stock (+N 'salvedad_merma' a la
     bolsa, -N 'merma' de la bolsa), asi que las N unidades ya estan contadas
     como salidas; al restituir la linea pasan a estar contadas como venta en
     vez de como rotura. Sumarlas de nuevo seria contarlas dos veces, el mismo
     error al reves. Lo que estaba mal era el libro de mermas, no el stock. */
  IF v_merma_id IS NOT NULL THEN
    UPDATE mermas_stock
       SET anulada_at = NOW(), anulada_por = v_usuario_id
     WHERE id = v_merma_id AND sucursal_id = v_sucursal;
  END IF;

  -- gastos 7: cada rotura viva se compensa, con la misma salvedad. Si ya
  -- estaba liquidada, la compensacion entra en la liquidacion siguiente.
  FOR r_rot IN
    SELECT m.* FROM empleado_movimientos m
     WHERE m.salvedad_id = p_salvedad_id AND m.tipo = 'rotura' AND m.revierte_id IS NULL
       AND NOT EXISTS (SELECT 1 FROM empleado_movimientos rv WHERE rv.revierte_id = m.id)
     ORDER BY m.id
  LOOP
    INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, observacion, revierte_id, creado_por, salvedad_id)
    VALUES (r_rot.empleado_id, public._tablero_hoy(), 'rotura', -r_rot.monto,
            'Anulación de la salvedad #' || p_salvedad_id || COALESCE(': ' || NULLIF(btrim(p_notas), ''), ''),
            r_rot.id, v_usuario_id, p_salvedad_id);
  END LOOP;

  UPDATE salvedades_items SET
    estado_resolucion = 'anulada',
    resolucion_notas = p_notas,
    resolucion_fecha = NOW(),
    resuelto_por = v_usuario_id,
    updated_at = NOW()
  WHERE id = p_salvedad_id AND sucursal_id = v_sucursal;
  INSERT INTO salvedad_historial (salvedad_id, accion, estado_anterior, estado_nuevo, notas, usuario_id, sucursal_id)
  VALUES (p_salvedad_id, 'anulacion', v_salvedad.estado_resolucion, 'anulada', p_notas, v_usuario_id, v_sucursal);
  RETURN jsonb_build_object('success', true,
                            'cobro_repuesto', v_repuesto,
                            'cobro_sin_reponer', v_sin_reponer);
END;
$function$;

-- ---- obtener_faltantes_rendiciones
CREATE OR REPLACE FUNCTION public.obtener_faltantes_rendiciones(p_fecha_desde date, p_fecha_hasta date, p_transportista_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_sucursal_id BIGINT;
  v_res         jsonb;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no seleccionada';
  END IF;
  -- es_transportista() incluye al admin, que ya entro por la rama de arriba
  -- (trampa 4).
  IF NOT es_encargado_o_admin() THEN
    IF NOT es_transportista() THEN
      RAISE EXCEPTION 'No autorizado';
    END IF;
    IF p_transportista_id IS NOT NULL AND p_transportista_id <> auth.uid() THEN
      RAISE EXCEPTION 'Acceso denegado' USING ERRCODE = '42501';
    END IF;
    p_transportista_id := auth.uid();
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', f.id, 'transportista_id', f.rendicion_transportista_id, 'fecha', f.rendicion_fecha,
           'causal', f.causal, 'monto', f.monto, 'observacion', f.observacion,
           -- Al transportista no se le dice a qué otro empleado se le cargó
           -- una línea de su rendición (GTO-10, #1519): la ve sin empleado.
           'empleado', CASE WHEN e.id IS NULL THEN NULL
                            WHEN es_encargado_o_admin() OR e.usuario_id = auth.uid()
                              THEN jsonb_build_object('id', e.id, 'nombre', e.nombre) END,
           'gasto_id', f.gasto_id, 'rubro_nombre', r.nombre,
           'creado_por_nombre', pf.nombre, 'created_at', f.created_at,
           -- T4 (#1710): lo que el cliente ya pagó contra esta línea (descuenta el faltante).
           'recuperado', public._faltante_recuperado(f.id))
         ORDER BY f.rendicion_fecha, f.id), '[]'::jsonb)
    INTO v_res
    FROM rendicion_faltantes f
    LEFT JOIN empleados e ON e.id = f.empleado_id
    LEFT JOIN gastos g ON g.id = f.gasto_id
    LEFT JOIN gasto_rubros r ON r.id = g.rubro_id
    LEFT JOIN perfiles pf ON pf.id = f.creado_por
   WHERE f.anulada_at IS NULL
     AND f.rendicion_sucursal_id = v_sucursal_id
     AND f.rendicion_fecha BETWEEN p_fecha_desde AND p_fecha_hasta
     AND (p_transportista_id IS NULL OR f.rendicion_transportista_id = p_transportista_id);

  RETURN v_res;
END
$function$;

-- ---- confirmar_rendicion
CREATE OR REPLACE FUNCTION public.confirmar_rendicion(p_fecha date, p_transportista_id uuid, p_estado text, p_gastos_rendicion jsonb, p_observaciones text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_sucursal_id BIGINT;
  v_id          BIGINT;
  v_guardar     jsonb;
  v_vistos      jsonb;
  v_quitar      bigint[];
  v_ids_guardar bigint[];
  v_vivos       bigint[];
  v_gid         bigint;
  v_elem        jsonb;
  v_rubro       text;
  v_msg         text;
  v_code        text;
  v_pagos_visto numeric;
  v_falt_visto  numeric;
  v_cambio      text;
  v_cobros_visto jsonb; -- #1547 (FRT-03)
  v_cobros       jsonb;
BEGIN
  -- 1 · sucursal, rol y estado
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no seleccionada';
  END IF;

  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  -- #1328: el encargado no controla su propia rendicion. Marcarla en
  -- disconformidad tambien es hacer el control.
  IF p_transportista_id = auth.uid() AND NOT es_admin() THEN
    RAISE EXCEPTION 'Tu rendición la confirma otro encargado o un admin'
      USING ERRCODE = '42501';
  END IF;

  -- T4 (#1710): lo que cobra un encargado arma su rendición, y ésa la confirma un admin, nunca
  -- otro encargado. Es el rol de la persona, no el de la rendición.
  IF NOT es_admin() AND EXISTS (SELECT 1 FROM perfiles pe
                                 WHERE pe.id = p_transportista_id AND pe.rol = 'encargado') THEN
    RAISE EXCEPTION 'La rendición de un encargado la confirma un admin'
      USING ERRCODE = '42501';
  END IF;

  IF p_estado NOT IN ('confirmada','disconformidad') THEN
    RAISE EXCEPTION 'Estado invalido: %. Use "confirmada" o "disconformidad"', p_estado;
  END IF;

  -- #1547 (REN-2): un día que no llegó no se rinde. Cerrado, cerraba la caja de toda la
  -- sucursal hasta esa fecha (ultima_fecha_caja_cerrada es el máximo de la sucursal).
  IF p_fecha IS NULL OR p_fecha > public._tablero_hoy() THEN
    RAISE EXCEPTION 'La rendición del % todavía no se puede cerrar: ese día no llegó',
      COALESCE(to_char(p_fecha, 'DD/MM/YYYY'), '(sin fecha)') USING ERRCODE = '22023';
  END IF;

  -- 2 · la rendicion, antes que cualquier fila de gastos
  PERFORM public._rendicion_bloquear(ARRAY[public._rendicion_clave(p_transportista_id, p_fecha, v_sucursal_id)]);

  -- 2b · #1547 (REN-4, GTO-2 de #1522): una resolución se deshace toda junta, y sólo desde
  --      «Deshacer resolución» (del admin). Volver a cerrar una resuelta, o una con líneas
  --      vivas, la dejaba "confirmada" con el faltante cargado al empleado.
  IF EXISTS (SELECT 1 FROM rendiciones_control rc
              WHERE rc.fecha = p_fecha AND rc.transportista_id = p_transportista_id
                AND rc.sucursal_id = v_sucursal_id AND rc.estado = 'resuelta')
     OR EXISTS (SELECT 1 FROM rendicion_faltantes f
                 WHERE f.rendicion_sucursal_id = v_sucursal_id
                   AND f.rendicion_transportista_id = p_transportista_id
                   AND f.rendicion_fecha = p_fecha
                   AND f.anulada_at IS NULL) THEN
    RAISE EXCEPTION 'Esta rendición tiene una diferencia resuelta: para cambiar su cierre, un admin tiene que deshacer la resolución primero';
  END IF;

  -- 2c · #1547 (REN-2): una rendición nueva tiene algo que rendir en esta sucursal: una
  --      entrega, un cobro, un gasto o un movimiento de empleado de ese chofer ese día. Es lo
  --      que pone la tarjeta en la grilla (fechas_activas de obtener_resumen_rendiciones), y
  --      vale también para un chofer que después se desactivó o se fue de la sucursal.
  IF NOT EXISTS (SELECT 1 FROM rendiciones_control rc
                  WHERE rc.fecha = p_fecha AND rc.transportista_id = p_transportista_id
                    AND rc.sucursal_id = v_sucursal_id)
     AND NOT EXISTS (SELECT 1 FROM public._rendicion_entregas(v_sucursal_id, p_fecha, p_fecha) e
                      WHERE e.t_id = p_transportista_id)
     AND NOT EXISTS (SELECT 1 FROM public._rendicion_pagos(v_sucursal_id, p_fecha, p_fecha) x
                      WHERE x.t_id = p_transportista_id)
     AND NOT EXISTS (SELECT 1 FROM gastos g
                      WHERE g.origen_pago = 'rendicion' AND g.anulado_at IS NULL
                        AND g.sucursal_id = v_sucursal_id
                        AND g.rendicion_transportista_id = p_transportista_id
                        AND g.rendicion_fecha = p_fecha)
     AND NOT EXISTS (SELECT 1 FROM empleado_movimientos m
                      WHERE m.rendicion_sucursal_id = v_sucursal_id
                        AND m.rendicion_transportista_id = p_transportista_id
                        AND m.rendicion_fecha = p_fecha) THEN
    RAISE EXCEPTION 'No hay nada que rendir de ese transportista el % en esta sucursal: ni entregas, ni cobros, ni gastos',
      to_char(p_fecha, 'DD/MM/YYYY') USING ERRCODE = '22023';
  END IF;

  -- 3 · formato: {vistos: [{id, updated_at}], guardar: [gastos], quitar: [ids],
  --     pagos_personal_visto: numero, faltantes_visto: numero}; una lista que
  --     no viene es [] y un numero que no viene es 0. Un bundle viejo no conoce
  --     los pagos al personal ni los faltantes, asi que si la rendicion tiene
  --     alguno se lo rechaza a proposito en el paso 4, y al refrescar ya manda
  --     lo que vio.
  BEGIN
    IF jsonb_typeof(p_gastos_rendicion) IS DISTINCT FROM 'object'
       OR jsonb_typeof(COALESCE(p_gastos_rendicion->'vistos', '[]')) <> 'array'
       OR jsonb_typeof(COALESCE(p_gastos_rendicion->'quitar', '[]')) <> 'array'
       OR jsonb_typeof(COALESCE(p_gastos_rendicion->'guardar', '[]')) <> 'array'
       OR jsonb_typeof(COALESCE(p_gastos_rendicion->'pagos_personal_visto', '0')) <> 'number'
       OR jsonb_typeof(COALESCE(p_gastos_rendicion->'faltantes_visto', '0')) <> 'number' THEN
      RAISE EXCEPTION 'formato';
    END IF;
    -- #1547 (FRT-03): lo cobrado que mostró el cierre, {efectivo, transferencia, cheque,
    -- cuenta_corriente, tarjeta, otros, entregas}. Un bundle viejo no lo manda: sin el campo
    -- (o con null) no se compara, como antes, y el cierre no se rompe. El front nuevo lo
    -- manda siempre.
    IF jsonb_typeof(p_gastos_rendicion->'cobros_visto') IS DISTINCT FROM 'null'
       AND p_gastos_rendicion->'cobros_visto' IS NOT NULL THEN
      IF jsonb_typeof(p_gastos_rendicion->'cobros_visto') <> 'object'
         OR EXISTS (SELECT 1 FROM unnest(ARRAY['efectivo', 'transferencia', 'cheque', 'cuenta_corriente',
                                               'tarjeta', 'otros', 'entregas']) k
                     WHERE jsonb_typeof(p_gastos_rendicion->'cobros_visto'->k) IS DISTINCT FROM 'number') THEN
        RAISE EXCEPTION 'formato';
      END IF;
      v_cobros_visto := p_gastos_rendicion->'cobros_visto';
    END IF;
    v_vistos  := COALESCE(p_gastos_rendicion->'vistos', '[]');
    v_guardar := COALESCE(p_gastos_rendicion->'guardar', '[]');
    v_pagos_visto := COALESCE((p_gastos_rendicion->>'pagos_personal_visto')::numeric, 0);
    v_falt_visto  := COALESCE((p_gastos_rendicion->>'faltantes_visto')::numeric, 0);
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_vistos) e
                WHERE jsonb_typeof(e) <> 'object' OR jsonb_typeof(e->'id') IS DISTINCT FROM 'number'
                   OR jsonb_typeof(e->'updated_at') IS DISTINCT FROM 'string')
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(p_gastos_rendicion->'quitar', '[]')) e
                   WHERE jsonb_typeof(e) <> 'number')
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_guardar) e
                   WHERE jsonb_typeof(e) <> 'object'
                      OR jsonb_typeof(COALESCE(e->'id', 'null')) NOT IN ('number', 'null')) THEN
      RAISE EXCEPTION 'formato';
    END IF;
    -- Un id con decimales no entra en bigint, ni una fecha mal escrita en
    -- timestamptz: caen al EXCEPTION de abajo.
    PERFORM (e->>'id')::bigint, (e->>'updated_at')::timestamptz FROM jsonb_array_elements(v_vistos) e;
    v_quitar := ARRAY(SELECT (e #>> '{}')::bigint FROM jsonb_array_elements(COALESCE(p_gastos_rendicion->'quitar', '[]')) e);
    v_ids_guardar := ARRAY(SELECT (e->>'id')::bigint FROM jsonb_array_elements(v_guardar) e
                            WHERE e->>'id' IS NOT NULL);
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Los gastos del cierre vienen con un formato inválido';
  END;

  -- 4 · lo que vio el modal: los gastos, los pagos al personal (gastos 5) y
  --     los faltantes a cargo de empleados (gastos 6). Cada camino que los
  --     escribe toma el lock de la rendicion, el del paso 2.
  v_cambio := public._rendicion_cambio_visto(v_sucursal_id, p_transportista_id, p_fecha, v_vistos,
                                             v_pagos_visto, v_falt_visto);
  IF v_cambio = 'gastos' THEN
    RAISE EXCEPTION 'Los gastos de esta rendición cambiaron mientras la cerrabas: tocá Refrescar y volvé a abrir el cierre';
  ELSIF v_cambio = 'pagos' THEN
    RAISE EXCEPTION 'Los pagos al personal de esta rendición cambiaron mientras la cerrabas: tocá Refrescar y volvé a abrir el cierre';
  ELSIF v_cambio = 'faltantes' THEN
    RAISE EXCEPTION 'Los faltantes de esta rendición cambiaron mientras la cerrabas: tocá Refrescar y volvé a abrir el cierre';
  END IF;

  -- 4a · #1547 (FRT-03): lo cobrado, con el filtro de la tarjeta (pagos_agg de
  --      obtener_resumen_rendiciones: sin el adelanto de sueldo). Una rendición cerrada se lee
  --      de su foto, como la tarjeta. Cada cobro que entra toma el lock de la rendición del
  --      paso 2 o espera la foto.
  IF v_cobros_visto IS NOT NULL THEN
    SELECT jsonb_build_object(
             'efectivo',         COALESCE(SUM(x.monto) FILTER (WHERE x.forma_pago = 'efectivo'), 0),
             'transferencia',    COALESCE(SUM(x.monto) FILTER (WHERE x.forma_pago = 'transferencia'), 0),
             'cheque',           COALESCE(SUM(x.monto) FILTER (WHERE x.forma_pago = 'cheque'), 0),
             'cuenta_corriente', COALESCE(SUM(x.monto) FILTER (WHERE x.forma_pago = 'cuenta_corriente'), 0),
             'tarjeta',          COALESCE(SUM(x.monto) FILTER (WHERE x.forma_pago = 'tarjeta'), 0),
             'otros',            COALESCE(SUM(x.monto) FILTER (
                                   WHERE x.forma_pago IS NULL
                                      OR x.forma_pago NOT IN ('efectivo', 'transferencia', 'cheque',
                                                              'cuenta_corriente', 'tarjeta')), 0),
             'entregas',         COALESCE(SUM(x.monto) FILTER (WHERE x.es_entrega_del_dia), 0))
      INTO v_cobros
      FROM public._rendicion_pagos(v_sucursal_id, p_fecha, p_fecha) x
     WHERE x.t_id = p_transportista_id
       AND x.f = p_fecha
       AND COALESCE(x.forma_pago, '') <> 'adelanto_sueldo';
    IF EXISTS (SELECT 1 FROM jsonb_each(v_cobros) c
                WHERE round((c.value #>> '{}')::numeric, 2)
                      <> round((v_cobros_visto->>c.key)::numeric, 2)) THEN
      RAISE EXCEPTION 'Los cobros de esta rendición cambiaron mientras la cerrabas: tocá Refrescar y volvé a abrir el cierre';
    END IF;
  END IF;

  -- 4b · gastos 6: lo imputado al resolver se deshace todo junto. Volver a
  --      disconformidad con lineas vivas dejaria la diferencia imputada dos
  --      veces al resolver otra vez.
  IF p_estado = 'disconformidad'
     AND EXISTS (SELECT 1 FROM rendicion_faltantes f
                  WHERE f.rendicion_sucursal_id = v_sucursal_id
                    AND f.rendicion_transportista_id = p_transportista_id
                    AND f.rendicion_fecha = p_fecha
                    AND f.anulada_at IS NULL) THEN
    RAISE EXCEPTION 'Esta rendición tiene una diferencia imputada: para volver a disconformidad, deshacé la resolución';
  END IF;

  v_vivos := ARRAY(SELECT g.id FROM gastos g
                    WHERE g.origen_pago = 'rendicion'
                      AND g.sucursal_id = v_sucursal_id
                      AND g.rendicion_transportista_id = p_transportista_id
                      AND g.rendicion_fecha = p_fecha
                      AND g.anulado_at IS NULL);

  -- 5 · lo que se quita o se edita es de esta rendicion, y una sola vez
  IF EXISTS (SELECT 1 FROM unnest(v_quitar || v_ids_guardar) x WHERE x <> ALL (v_vivos)) THEN
    RAISE EXCEPTION 'Ese gasto no es de esta rendición o ya está anulado';
  END IF;
  IF cardinality(v_quitar || v_ids_guardar)
     <> (SELECT count(DISTINCT x) FROM unnest(v_quitar || v_ids_guardar) x) THEN
    RAISE EXCEPTION 'Un gasto viene dos veces en el cierre';
  END IF;

  -- 6 · quitar: se anula, con quien y cuando en la anulacion. Un gasto de la
  --     resolucion lo frena rendicion_faltantes_guarda_gasto.
  FOREACH v_gid IN ARRAY v_quitar LOOP
    BEGIN
      PERFORM public._anular_gasto(v_gid, 'Quitado en el cierre de la rendición', true);
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_code = RETURNED_SQLSTATE;
      SELECT r.nombre INTO v_rubro FROM gastos g JOIN gasto_rubros r ON r.id = g.rubro_id WHERE g.id = v_gid;
      RAISE EXCEPTION USING ERRCODE = v_code,
        MESSAGE = COALESCE('En el gasto de ' || v_rubro || ': ', 'En un gasto del cierre: ') || v_msg;
    END;
  END LOOP;

  -- 7 · guardar: lo nuevo y lo editado, siempre en esta rendicion
  FOR v_elem IN SELECT e FROM jsonb_array_elements(v_guardar) e LOOP
    v_elem := v_elem || jsonb_build_object('origen_pago', 'rendicion',
                                           'rendicion_transportista_id', p_transportista_id,
                                           'rendicion_fecha', p_fecha,
                                           'sucursal_id', v_sucursal_id);
    BEGIN
      PERFORM public._guardar_gasto(v_elem, true);
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_code = RETURNED_SQLSTATE;
      v_rubro := NULL;
      SELECT r.nombre INTO v_rubro FROM gasto_rubros r WHERE r.id::text = v_elem->>'rubro_id';
      RAISE EXCEPTION USING ERRCODE = v_code,
        MESSAGE = COALESCE('En el gasto de ' || v_rubro || ': ', 'En un gasto del cierre: ') || v_msg;
    END;
  END LOOP;

  -- 8 · el control, como hasta ahora
  INSERT INTO rendiciones_control (
    fecha, transportista_id, sucursal_id, estado, observaciones,
    controlada_at, controlada_por
  )
  VALUES (
    p_fecha, p_transportista_id, v_sucursal_id, p_estado, p_observaciones,
    now(), auth.uid()
  )
  ON CONFLICT (fecha, transportista_id, sucursal_id) DO UPDATE
    SET estado = EXCLUDED.estado,
        observaciones = EXCLUDED.observaciones,
        controlada_at = now(),
        controlada_por = auth.uid(),
        resuelta_at = NULL,
        resuelta_por = NULL
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

-- ---- auditoria_definer_sin_rol
CREATE OR REPLACE FUNCTION public.auditoria_definer_sin_rol()
 RETURNS TABLE(firma text, motivo text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog', 'pg_temp'
AS $function$
  -- Heurística de texto, como STK-F y COSTO-D. Ver lo que NO ve al final.
  WITH f AS (
    SELECT p.oid::regprocedure::text AS firma,
           -- El cuerpo tal cual, para la lista blanca.
           md5(p.prosrc) AS hash,
           -- Sin comentarios: un helper o un "rol" nombrado en un comentario
           -- no es un guard.
           public._sql_sin_comentarios(p.prosrc) AS src,
           -- Los parámetros uuid de entrada, por nombre.
           COALESCE(ARRAY(
             SELECT a.n
               FROM unnest(p.proargnames[1:p.pronargs], p.proargtypes::oid[]) AS a(n, t)
              WHERE a.t = 'uuid'::regtype AND a.n IS NOT NULL AND a.n <> ''), '{}') AS uargs
      FROM pg_proc p
      JOIN pg_type t ON t.oid = p.prorettype
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.prokind = 'f'
       AND p.prosecdef
       AND t.typname <> 'trigger'
       AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
       AND NOT EXISTS (
         SELECT 1 FROM pg_depend d
          WHERE d.classid = 'pg_proc'::regclass
            AND d.objid = p.oid
            AND d.deptype = 'e')
  ),
  -- LISTA BLANCA DE A, por firma + md5 del cuerpo (#1074). Una entrada exime
  -- a ESE cuerpo: si la función cambia, vuelve a salir en rojo con el md5
  -- nuevo en el motivo. Revisá que el cambio no le abra nada a nadie y
  -- actualizá el md5 acá:
  --   SELECT md5(prosrc) FROM pg_proc WHERE oid = 'public.<firma>'::regprocedure;
  lista_blanca(firma, hash) AS (VALUES
    -- Sólo tocan filas del propio auth.uid().
    ('cambiar_sucursal(bigint)',                 '20cdccf527b210f6c11539a72f95b067'),  -- valida que la sucursal sea del caller
    ('marcar_notificacion_leida(bigint)',        '7c97357d2f443b1a88a7830f15e4d01a'),
    ('marcar_todas_notificaciones_leidas()',     '9812bdd67e61af81f4b39d3fc4279db1'),
    ('generar_codigo_vinculacion_bot()',         '8bc04a524e8f52ed4bacee339bee5999'),
    ('listar_visitas_hoy()',                     '2b01c13670d61b16ddcc89cacf3d65b0'),
    -- Helpers de RLS y de la sucursal activa del caller.
    ('current_sucursal_id()',                    '54d71f56a5d86f814a17f00b620d4eff'),  -- valida el header contra usuario_sucursales
    ('cliente_de_sucursal_activa(bigint)',       'f40cb2ef4e2c451a601d2030ec6196d8'),  -- booleano, policy de cliente_preventistas
    -- Booleano de la policy perfiles_select_sucursal, que se evalúa como el
    -- usuario: sin EXECUTE para authenticated, leer perfiles falla entero. Da
    -- true sólo para perfiles que esa policy ya muestra: no es un oráculo
    -- (#1074, lo prueba scripts/test-permisos-menores-1074.sql).
    ('perfil_de_sucursal_activa(uuid)',          'b17dcf26c7a9151592298c8d518f218a'),
    ('get_deposito_sucursal()',                  'ca9a2d0381ac96e1179d55e40f40b8ba'),  -- coordenadas de la sucursal activa
    ('get_destino_sucursal()',                   '6ae185df6f77096963e5d7f0b15ee2b5'),
    ('parametros_vencimiento()',                 '46629184d68b286d0f6fb8d0a73fa88e'),  -- días de alerta, sin montos
    -- mig NNN (B1, #1603): los días atrás de la política de una sucursal del caller (o del
    -- server), sin montos. La leen las reglas de la fecha del pedido y de la entrega, que
    -- corren como el usuario.
    ('_dias_atras_fecha_pedido(bigint)',         'd9c04f85466d1a1cb9aa12a8fdac48bd'),
    -- Wrappers de idempotencia (mig 167): el rol lo exige el _impl, que no
    -- tiene EXECUTE para authenticated. Un replay del mismo
    -- client_request_id (uuid) devuelve el resultado guardado sin pasar por
    -- el _impl: es el de esa misma solicitud, ya autorizada.
    -- T4 (#1710): con p_cobrado_por.
    ('registrar_pago_cliente_fifo(bigint,numeric,text,date,text,text,uuid,uuid)',        '683067bbb0713631ed085ab9abc583f2'),
    ('registrar_pago_combinado_cliente_fifo(bigint,jsonb,date,text,text,uuid,uuid)',     '8ce481f5badb52f3290df590b0ee36e9'),
    ('marcar_pagos_masivo(bigint[],text,date,uuid,uuid)',                                '3f0c0664a5f79426e2820bea1df5f592'),
    ('marcar_entrega_y_pago_masivo(bigint[],uuid,text,date,uuid)',                       '5d5c3c45a0bc16cbf52ecce8963a1687'),
    ('imputar_credito_a_pedido(bigint,bigint,numeric,uuid)',                             '0c60921397faf1cdd1abbf4edd0a0576'),
    ('crear_nota_credito_venta(bigint,bigint,jsonb,text,text,uuid)',                     'e92f59da39844598b948b7da652977a0'),
    -- Delega en crear_pedido_completo, que exige admin/preventista/encargado.
    -- #1492 (mig 473): el replay suma lo que el pedido absorbió de saldo a favor, del
    -- mismo pedido que ya devolvía (total y cargo), sin otro guard.
    ('crear_pedido_idempotente(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid,text)',
                                                 '153a687adf8278c7a5c1ae9c3872e4ed'),  -- mig NNN (B4, 1559-b4): el replay, sólo de quien cargó
    -- Booleano / fecha de cierre de caja, sin montos. Las usa el front para
    -- la fecha mínima de un pago, y pagos_guard_anulacion_caja_cerrada (un
    -- trigger INVOKER) llama a ultima_fecha_caja_cerrada como el usuario:
    -- revocarla rompería borrar pagos.
    ('rendicion_dia_cerrada(date,bigint)',       '96bf9397648d73a7b77a2f84eb45cf24'),
    ('ultima_fecha_caja_cerrada(bigint)',        'cd39eceb6d9f4372c49a267151fb5c08'),
    -- #1175: booleano de control cerrado por chofer y día, sin montos; lo
    -- llama pedidos_proteger_columnas (INVOKER) como el usuario.
    ('control_rendicion_cerrado(uuid,bigint,date)', '3a5ed52d20b27cf1cb3820b95aa53153')
  ),
  hallazgos AS (
    -- A · Sin guard de rol. Los helpers de rol (trampa 4 de CLAUDE.md:
    --     es_preventista() y es_transportista() dejan pasar a otros roles;
    --     nombrarlos cuenta como guard para este check, pero no lo hace
    --     correcto). La palabra `rol` cuenta sólo si el cuerpo mira auth.uid():
    --     sin eso no puede ser el rol del que llama.
    --     _tablero_sucursales cuenta como helper (mig 392): exige admin o
    --     encargado activo con la sucursal asignada, y authenticated no la ejecuta.
    SELECT f.firma,
           CASE WHEN EXISTS (SELECT 1 FROM lista_blanca lb WHERE lb.firma = f.firma)
                THEN 'sin guard de rol: está en la lista blanca pero el cuerpo cambió (md5 '
                     || f.hash || '); revisarla y actualizar el md5'
                ELSE 'sin guard de rol'
           END AS motivo
      FROM f
     WHERE NOT (src ~* '(\mes_admin|\mes_encargado_o_admin|\mes_preventista|\mes_transportista|\mget_mi_rol|\mget_user_role|\mtiene_rol_extra|_rol_en_sucursal|\m_tablero_sucursales\M|\mpuede_leer_pedido|\mperfil_roles\M)'
                OR (src ~* '\mrol\M' AND src ~* '\mauth\.uid\s*\(\s*\)'))
       AND NOT EXISTS (SELECT 1 FROM lista_blanca lb
                        WHERE lb.firma = f.firma AND lb.hash = f.hash)
    UNION ALL
    -- B · Suplantación (#1048): el rol se lee de perfiles con un uuid que pasa
    --     el que llama —COALESCE(p_x, auth.uid()), o `id = p_usuario_id`— y ese
    --     parámetro nunca se compara con auth.uid() ni se pisa con él. La lista
    --     blanca de A no exime de esto.
    SELECT firma, 'el rol sale de un parámetro: ' || u
      FROM f, unnest(f.uargs) AS u
     WHERE (src ~* ('\mperfiles\M[^;]*\mcoalesce\s*\(\s*' || u || '\s*,\s*auth\.uid\s*\(\s*\)')
            OR (u = 'p_usuario_id' AND src ~* '\mperfiles\M[^;]*\mid\s*=\s*p_usuario_id\M'))
       AND src !~* ('\m' || u || '\s*(IS\s+DISTINCT\s+FROM|<>|!=)\s*auth\.uid\s*\(\s*\)')
       AND src !~* ('\mauth\.uid\s*\(\s*\)\s*(IS\s+DISTINCT\s+FROM|<>|!=)\s*' || u || '\M')
       AND src !~* ('\m' || u || '\s*:=\s*auth\.uid\s*\(\s*\)')
    UNION ALL
    -- C · Guard muerto (#1048): adentro de una DEFINER `current_user` es el
    --     dueño, nunca 'authenticated' ni 'anon'. Un IF que lo pregunta no se
    --     ejecuta (o se ejecuta siempre). Los triggers INVOKER que lo usan bien
    --     no entran acá: no son DEFINER.
    SELECT firma, 'guard muerto: compara current_user con un rol de la app'
      FROM f
     WHERE src ~* '\m(current_user|current_role|session_user)\M\s*(=|<>|!=|IN\s*\(|IS\s+(NOT\s+)?DISTINCT\s+FROM)\s*\(?\s*''(authenticated|anon)'''
  )
  SELECT firma, string_agg(motivo, '; ' ORDER BY motivo)
    FROM hallazgos
   GROUP BY firma
   ORDER BY firma;

  -- LO QUE NO VE (es texto, no ejecución):
  --   · Helpers permisivos (trampa 4 de CLAUDE.md). es_preventista() da true
  --     también para admin y encargado (y para el rol extra de perfil_roles);
  --     es_transportista(), para admin. Nombrarlos cuenta como guard, así que
  --     una función que debería ser SÓLO de preventistas y se cuida con
  --     `IF NOT es_preventista()` pasa limpia aunque deje entrar a otros.
  --   · La lista blanca exime un cuerpo (firma + md5 de prosrc), no una
  --     conducta. No mira lo que la función llama: si un wrapper exceptuado
  --     delega en un _impl u otra función y ESA cambia, la excepción sigue
  --     valiendo. Tampoco cubre lo que está fuera del cuerpo: SECURITY
  --     DEFINER, el search_path, los grants.
  --   · Un guard que nombra el helper pero no actúa: `PERFORM es_admin()`, un
  --     `OR true` en la condición, el IF en una rama que nunca corre.
  --   · Comparaciones de rol que dejan pasar NULL: `v_rol <> 'admin'`,
  --     `v_rol NOT IN (...)` sin `IS NULL OR` delante. Hoy no son alcanzables
  --     (perfiles.rol es NOT NULL y sin perfil no hay sucursal activa).
  --   · Suplantación con otro nombre de parámetro (p_perfil_id, p_admin...) sin
  --     COALESCE, o con el rol pedido a un helper que recibe el parámetro
  --     (`_rol_en_sucursal(p_x, ...)`).
  --   · Suplantación por una variable intermedia
  --     (`v := COALESCE(p_x, auth.uid()); SELECT rol FROM perfiles WHERE id = v`):
  --     B pide perfiles y el COALESCE en la misma sentencia.
  --   · Una validación que no corta: B se da por satisfecho con CUALQUIER
  --     comparación o asignación entre el parámetro y auth.uid(), aunque esté
  --     después de la lectura del rol o no lleve a un RAISE/RETURN.
  --   · El guard muerto escrito al revés (`'authenticated' = current_user`) o
  --     con cast (`current_user::text = ...`).
  --   · Un `--` o un `/*` adentro de un dólar-quote anidado ($q$…$q$) o de un
  --     E'…\'…': _sql_sin_comentarios entiende las comillas simples (#1541),
  --     no esos.
  --   · SQL dinámico (EXECUTE format(...)).
  --   · La sucursal: un guard de rol correcto que no cruza la sucursal pedida
  --     con las asignadas (#982, #1074) pasa limpio.
$function$;


REVOKE ALL ON FUNCTION public.registrar_pagos_pedido(bigint, jsonb, date, text, text, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_pagos_pedido(bigint, jsonb, date, text, text, uuid, uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.registrar_pago_cliente_fifo(bigint, numeric, text, date, text, text, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_pago_cliente_fifo(bigint, numeric, text, date, text, text, uuid, uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.registrar_pago_combinado_cliente_fifo(bigint, jsonb, date, text, text, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_pago_combinado_cliente_fifo(bigint, jsonb, date, text, text, uuid, uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.marcar_pagos_masivo(bigint[], text, date, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.marcar_pagos_masivo(bigint[], text, date, uuid, uuid) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.registrar_pagos_pedido_impl(bigint, jsonb, date, text, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_pagos_pedido_impl(bigint, jsonb, date, text, text, uuid) TO service_role;
REVOKE ALL ON FUNCTION public.registrar_pago_cliente_fifo_impl(bigint, numeric, text, date, text, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_pago_cliente_fifo_impl(bigint, numeric, text, date, text, text, uuid) TO service_role;
REVOKE ALL ON FUNCTION public.registrar_pago_combinado_cliente_fifo_impl(bigint, jsonb, date, text, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_pago_combinado_cliente_fifo_impl(bigint, jsonb, date, text, text, uuid) TO service_role;
REVOKE ALL ON FUNCTION public.marcar_pagos_masivo_impl(bigint[], text, date, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.marcar_pagos_masivo_impl(bigint[], text, date, uuid) TO service_role;

-- -------------------------------------------------------------------------
-- 6 · Corregir la forma de pago (y quién cobró) en una rendición abierta
-- -------------------------------------------------------------------------
CREATE FUNCTION public.corregir_cobro_rendicion(p_pago_id bigint, p_forma_pago text DEFAULT NULL::text,
                                                p_cobrado_por uuid DEFAULT NULL::uuid, p_motivo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
DECLARE
  v_sucursal_id bigint := current_sucursal_id();
  v_hoy         date := public._tablero_hoy();
  v_pg          RECORD;
  v_r           RECORD;
  v_r2          RECORD;
  v_estado      text;
  v_forma       text;
  v_nuevo       uuid;
  v_claves      bigint[];
  v_forma_ped   text;
  v_quien       text;
  v_cambios     text := '';
BEGIN
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;
  IF NOT public.es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Sólo un encargado o un admin corrige un cobro de la rendición' USING ERRCODE = '42501';
  END IF;
  IF p_motivo IS NULL OR btrim(p_motivo) = '' THEN
    RAISE EXCEPTION 'Escribí por qué se corrige' USING ERRCODE = '22023';
  END IF;
  IF p_forma_pago IS NULL AND p_cobrado_por IS NULL THEN
    RAISE EXCEPTION 'No hay nada que corregir' USING ERRCODE = '22023';
  END IF;
  IF p_cobrado_por IS NOT NULL AND NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin cambia quién cobró' USING ERRCODE = '42501';
  END IF;

  SELECT id, pedido_id, fecha, forma_pago, cobrado_por INTO v_pg
    FROM pagos WHERE id = p_pago_id AND sucursal_id = v_sucursal_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pago no encontrado' USING ERRCODE = 'P0002';
  END IF;
  IF COALESCE(v_pg.forma_pago, '') IN ('adelanto_sueldo', 'nota_credito') THEN
    RAISE EXCEPTION 'Un adelanto de sueldo o el crédito de una nota de crédito no se corrige acá'
      USING ERRCODE = '22023';
  END IF;
  v_forma := CASE WHEN p_forma_pago IS NULL THEN v_pg.forma_pago
                  ELSE public._forma_pago_de_cobro(p_forma_pago, true) END;
  v_nuevo := CASE WHEN p_cobrado_por IS NULL THEN v_pg.cobrado_por
                  ELSE public._cobrador_de_cobro(p_cobrado_por, v_sucursal_id, NULL) END;

  -- La rendición en la que está hoy (un día cerrado lo pudo llevar al siguiente).
  SELECT x.t_id, x.f, x.congelado INTO v_r
    FROM public._rendicion_pagos(v_sucursal_id, v_pg.fecha, GREATEST(v_hoy, v_pg.fecha)) x
   WHERE x.pago_id = p_pago_id
   ORDER BY x.congelado DESC LIMIT 1;
  IF NOT FOUND OR v_r.t_id IS NULL THEN
    RAISE EXCEPTION 'Ese cobro no está en ninguna rendición' USING ERRCODE = '22023';
  END IF;
  IF v_r.congelado THEN
    RAISE EXCEPTION 'La rendición de ese cobro ya está cerrada: para corregirlo, reabrila' USING ERRCODE = '42501';
  END IF;

  -- Locks: las rendiciones (la de hoy del cobro y, si cambia de caja, la del nuevo), después la
  -- boleta y el pago. Es el orden de confirmar_rendicion y de la entrega y pago masivos.
  v_claves := ARRAY[public._rendicion_clave(v_r.t_id, v_r.f, v_sucursal_id)];
  IF v_nuevo IS DISTINCT FROM v_r.t_id THEN
    v_claves := v_claves || public._rendicion_clave(v_nuevo, v_pg.fecha, v_sucursal_id);
  END IF;
  PERFORM public._rendicion_bloquear(v_claves);
  IF v_pg.pedido_id IS NOT NULL THEN
    PERFORM 1 FROM pedidos WHERE id = v_pg.pedido_id AND sucursal_id = v_sucursal_id FOR UPDATE;
  END IF;
  PERFORM 1 FROM pagos WHERE id = p_pago_id FOR UPDATE;

  SELECT x.t_id, x.f, x.congelado INTO v_r2
    FROM public._rendicion_pagos(v_sucursal_id, v_pg.fecha, GREATEST(v_hoy, v_pg.fecha)) x
   WHERE x.pago_id = p_pago_id
   ORDER BY x.congelado DESC LIMIT 1;
  IF NOT FOUND OR v_r2.congelado OR v_r2.t_id IS DISTINCT FROM v_r.t_id OR v_r2.f IS DISTINCT FROM v_r.f
     OR (SELECT p.fecha FROM pagos p WHERE p.id = p_pago_id) IS DISTINCT FROM v_pg.fecha THEN
    RAISE EXCEPTION 'La rendición de ese cobro cambió mientras lo corregías: volvé a intentar' USING ERRCODE = '40001';
  END IF;

  SELECT estado INTO v_estado FROM rendiciones_control
   WHERE transportista_id = v_r.t_id AND fecha = v_r.f AND sucursal_id = v_sucursal_id;
  IF v_estado IN ('confirmada', 'resuelta') THEN
    RAISE EXCEPTION 'La rendición de ese cobro ya está cerrada: para corregirlo, reabrila' USING ERRCODE = '42501';
  END IF;
  IF NOT public.es_admin() THEN
    IF v_estado = 'disconformidad' THEN
      RAISE EXCEPTION 'Una rendición en disconformidad la corrige un admin' USING ERRCODE = '42501';
    END IF;
    -- La de un encargado (también la propia: quien no es admin y corrige es encargado).
    IF EXISTS (SELECT 1 FROM perfiles pe WHERE pe.id = v_r.t_id AND pe.rol = 'encargado') THEN
      RAISE EXCEPTION 'La rendición de un encargado la corrige un admin' USING ERRCODE = '42501';
    END IF;
  END IF;
  IF v_nuevo IS DISTINCT FROM v_r.t_id
     AND EXISTS (SELECT 1 FROM rendiciones_control rc
                  WHERE rc.transportista_id = v_nuevo AND rc.fecha = v_pg.fecha AND rc.sucursal_id = v_sucursal_id
                    AND rc.estado IN ('confirmada', 'resuelta', 'disconformidad')) THEN
    RAISE EXCEPTION 'La rendición del % de quien cobró ya está cerrada: no se le puede pasar el cobro',
      to_char(v_pg.fecha, 'DD/MM/YYYY') USING ERRCODE = '42501';
  END IF;

  IF v_forma IS NOT DISTINCT FROM v_pg.forma_pago AND v_nuevo IS NOT DISTINCT FROM v_pg.cobrado_por THEN
    RETURN jsonb_build_object('success', true, 'pago_id', p_pago_id, 'sin_cambios', true);
  END IF;

  SELECT nombre INTO v_quien FROM perfiles WHERE id = auth.uid();
  IF v_forma IS DISTINCT FROM v_pg.forma_pago THEN
    v_cambios := 'forma ' || COALESCE(v_pg.forma_pago, '-') || ' → ' || v_forma;
  END IF;
  IF v_nuevo IS DISTINCT FROM v_pg.cobrado_por THEN
    v_cambios := v_cambios || CASE WHEN v_cambios = '' THEN '' ELSE ', ' END || 'cobró '
      || COALESCE((SELECT nombre FROM perfiles WHERE id = v_pg.cobrado_por), '-') || ' → '
      || COALESCE((SELECT nombre FROM perfiles WHERE id = v_nuevo), '-');
  END IF;

  UPDATE pagos
     SET forma_pago = v_forma,
         cobrado_por = v_nuevo,
         notas = btrim(COALESCE(notas, '') || ' [Corregido en la rendición por ' || COALESCE(v_quien, 'usuario')
                       || ' el ' || to_char(now() AT TIME ZONE 'America/Argentina/Buenos_Aires', 'DD/MM/YYYY HH24:MI')
                       || ': ' || v_cambios || '. Motivo: ' || btrim(p_motivo) || ']')
   WHERE id = p_pago_id;

  -- La forma de la boleta, como actualizar_forma_pago_pago.
  IF v_pg.pedido_id IS NOT NULL AND v_forma IS DISTINCT FROM v_pg.forma_pago THEN
    SELECT forma_pago INTO v_forma_ped
      FROM pagos
     WHERE pedido_id = v_pg.pedido_id
       AND COALESCE(forma_pago, '') NOT IN ('adelanto_sueldo', 'nota_credito')
     ORDER BY monto DESC NULLS LAST, created_at DESC NULLS LAST
     LIMIT 1;
    UPDATE pedidos
       SET forma_pago = COALESCE(v_forma_ped, v_forma), updated_at = now()
     WHERE id = v_pg.pedido_id AND sucursal_id = v_sucursal_id;
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (v_pg.pedido_id, auth.uid(), 'forma_pago_pago_' || p_pago_id::text, v_pg.forma_pago,
            v_forma || ' (corregido en la rendición: ' || btrim(p_motivo) || ')', v_sucursal_id);
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'pago_id', p_pago_id,
    'forma_pago_anterior', v_pg.forma_pago,
    'forma_pago', v_forma,
    'cobrado_por_anterior', v_pg.cobrado_por,
    'cobrado_por', v_nuevo);
END
$function$;
REVOKE ALL ON FUNCTION public.corregir_cobro_rendicion(bigint, text, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.corregir_cobro_rendicion(bigint, text, uuid, text) TO authenticated, service_role;

-- -------------------------------------------------------------------------
-- 7 · Lo que el cliente paga después contra el faltante de un empleado
-- -------------------------------------------------------------------------
ALTER TABLE public.empleado_movimientos
  ADD COLUMN recupera_faltante_id bigint REFERENCES public.rendicion_faltantes(id);
COMMENT ON COLUMN public.empleado_movimientos.recupera_faltante_id IS
  'T4 (#1710): lo que el cliente pagó después contra esta línea de faltante. Positivo; en efectivo es un faltante positivo en la rendición de quien lo recibió.';
CREATE INDEX empleado_movimientos_recupera_idx ON public.empleado_movimientos (recupera_faltante_id)
  WHERE recupera_faltante_id IS NOT NULL;
ALTER TABLE public.empleado_movimientos DROP CONSTRAINT empleado_movimientos_faltante_negativo;
ALTER TABLE public.empleado_movimientos ADD CONSTRAINT empleado_movimientos_faltante_negativo
  CHECK (tipo <> 'faltante' OR revierte_id IS NOT NULL OR recupera_faltante_id IS NOT NULL OR monto < 0);
ALTER TABLE public.empleado_movimientos ADD CONSTRAINT empleado_movimientos_recupero
  CHECK (recupera_faltante_id IS NULL
         OR (tipo IN ('faltante', 'ajuste') AND revierte_id IS NULL AND monto > 0));

ALTER TABLE public.altas_por_clave DROP CONSTRAINT altas_por_clave_operacion_check;
ALTER TABLE public.altas_por_clave ADD CONSTRAINT altas_por_clave_operacion_check
  CHECK (operacion = ANY (ARRAY['condicion_mayorista'::text, 'promocion'::text, 'cliente'::text, 'gasto'::text,
                                'empleado'::text, 'visita'::text, 'cambio_producto'::text, 'movimiento_empleado'::text,
                                'liquidacion_empleado'::text, 'cobro_faltante'::text]));

-- Lo vivo cobrado contra una línea: los movimientos que la recuperan y nadie revirtió.
CREATE FUNCTION public._faltante_recuperado(p_faltante_id bigint)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path = public, pg_temp
AS $function$
  SELECT COALESCE(sum(m.monto), 0)
    FROM empleado_movimientos m
   WHERE m.recupera_faltante_id = p_faltante_id
     AND NOT EXISTS (SELECT 1 FROM empleado_movimientos r WHERE r.revierte_id = m.id);
$function$;
REVOKE ALL ON FUNCTION public._faltante_recuperado(bigint) FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.rendicion_faltantes_guarda_recupero()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path = public, pg_temp
AS $function$
BEGIN
  IF NEW.anulada_at IS NOT NULL AND OLD.anulada_at IS NULL
     AND public._faltante_recuperado(OLD.id) > 0 THEN
    RAISE EXCEPTION 'El cliente ya pagó parte de este faltante: anulá antes ese cobro (Rendiciones, «Lo pagó el cliente»)'
      USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END
$function$;
REVOKE ALL ON FUNCTION public.rendicion_faltantes_guarda_recupero() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER trg_rendicion_faltantes_guarda_recupero
  BEFORE UPDATE OF anulada_at ON public.rendicion_faltantes
  FOR EACH ROW EXECUTE FUNCTION public.rendicion_faltantes_guarda_recupero();

CREATE FUNCTION public.cobrar_faltante_rendicion(p_faltante_id bigint, p_monto numeric, p_forma_pago text,
                                                 p_cobrado_por uuid DEFAULT NULL::uuid,
                                                 p_observacion text DEFAULT NULL::text,
                                                 p_clave uuid DEFAULT NULL::uuid)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
DECLARE
  v_sucursal_id bigint := current_sucursal_id();
  v_hoy         date := public._tablero_hoy();
  v_f           rendicion_faltantes%ROWTYPE;
  v_emp_id      bigint;
  v_e           empleados%ROWTYPE;
  v_monto       numeric;
  v_forma       text;
  v_cobrador    uuid;
  v_obs         text;
  v_id          bigint;
  v_contenido   text;
  v_previa      public.altas_por_clave%ROWTYPE;
  v_tr_nombre   text;
BEGIN
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin ve y carga el personal' USING ERRCODE = '42501';
  END IF;
  v_monto := public._monto_de_cobro(p_monto);
  IF v_monto IS NULL OR v_monto <= 0 THEN
    RAISE EXCEPTION 'El monto tiene que ser mayor a cero' USING ERRCODE = '22023';
  END IF;
  v_forma := public._forma_pago_de_cobro(p_forma_pago, true);
  v_cobrador := public._cobrador_de_cobro(p_cobrado_por, v_sucursal_id, NULL);
  v_obs := NULLIF(btrim(p_observacion), '');

  -- GTO-E: el empleado, después la rendición que recibe el efectivo, después la línea.
  SELECT empleado_id INTO v_emp_id FROM rendicion_faltantes
   WHERE id = p_faltante_id AND rendicion_sucursal_id = v_sucursal_id;
  IF v_emp_id IS NULL THEN
    RAISE EXCEPTION 'Esa línea no es un faltante a cargo de un empleado de esta sucursal' USING ERRCODE = 'P0002';
  END IF;
  SELECT * INTO v_e FROM empleados WHERE id = v_emp_id FOR UPDATE;
  IF NOT FOUND OR NOT public._empleado_visible(v_e.sucursal_id, v_e.de_las_dos) THEN
    RAISE EXCEPTION 'Ese empleado no existe o no lo podés ver';
  END IF;
  IF v_e.usuario_id = auth.uid() THEN
    RAISE EXCEPTION 'Tu propia cuenta la maneja otro admin: no podés cargarte un movimiento';
  END IF;

  IF p_clave IS NOT NULL THEN
    v_contenido := md5(jsonb_build_array(p_faltante_id, v_monto, v_forma, v_cobrador)::text);
    INSERT INTO altas_por_clave (clave, operacion, usuario_id, sucursal_id, contenido)
    VALUES (p_clave, 'cobro_faltante', auth.uid(), v_sucursal_id, v_contenido)
    ON CONFLICT (clave) DO NOTHING;
    IF NOT FOUND THEN
      SELECT * INTO v_previa FROM altas_por_clave WHERE clave = p_clave;
      IF v_previa.operacion <> 'cobro_faltante' OR v_previa.usuario_id IS DISTINCT FROM auth.uid() THEN
        RAISE EXCEPTION 'Esta clave ya se usó para otra operación: recargá la página e intentá de nuevo.'
          USING ERRCODE = '22023';
      END IF;
      IF v_previa.contenido <> v_contenido THEN
        RAISE EXCEPTION 'Este cobro ya se registró con el intento anterior y lo que mandaste ahora es distinto: cerrá esta ventana y revisá la rendición.'
          USING ERRCODE = '22023';
      END IF;
      IF v_previa.entidad_id IS NULL OR NOT EXISTS (SELECT 1 FROM empleado_movimientos WHERE id = v_previa.entidad_id) THEN
        RAISE EXCEPTION 'Este cobro ya se había registrado con el intento anterior y no se encuentra: revisá la rendición.'
          USING ERRCODE = '22023';
      END IF;
      RETURN v_previa.entidad_id;
    END IF;
  END IF;

  IF v_forma = 'efectivo' THEN
    PERFORM public._rendicion_bloquear(ARRAY[public._rendicion_clave(v_cobrador, v_hoy, v_sucursal_id)]);
    IF EXISTS (SELECT 1 FROM rendiciones_control rc
                WHERE rc.transportista_id = v_cobrador AND rc.fecha = v_hoy AND rc.sucursal_id = v_sucursal_id
                  AND rc.estado IN ('confirmada', 'resuelta', 'disconformidad')) THEN
      RAISE EXCEPTION 'La rendición de hoy de quien lo cobró ya está cerrada: el efectivo no puede entrar en ella'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  SELECT * INTO v_f FROM rendicion_faltantes WHERE id = p_faltante_id FOR UPDATE;
  IF v_f.anulada_at IS NOT NULL OR v_f.causal <> 'empleado' OR v_f.empleado_id IS DISTINCT FROM v_emp_id THEN
    RAISE EXCEPTION 'Esa línea ya no es un faltante vivo a cargo de un empleado' USING ERRCODE = '22023';
  END IF;
  IF v_monto > v_f.monto - public._faltante_recuperado(v_f.id) THEN
    RAISE EXCEPTION 'El cobro supera lo que queda del faltante (%)',
      round(v_f.monto - public._faltante_recuperado(v_f.id), 2)::text USING ERRCODE = '22023';
  END IF;

  SELECT nombre INTO v_tr_nombre FROM perfiles WHERE id = v_f.rendicion_transportista_id;
  v_obs := 'Lo pagó el cliente (' || v_forma || '): descuenta el faltante de la rendición de '
           || COALESCE(v_tr_nombre, 'transportista') || ' del ' || to_char(v_f.rendicion_fecha, 'DD/MM/YYYY')
           || COALESCE(' · ' || v_obs, '');

  IF v_forma = 'efectivo' THEN
    INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, observacion, creado_por, recupera_faltante_id,
                                      rendicion_transportista_id, rendicion_fecha, rendicion_sucursal_id)
    VALUES (v_e.id, v_hoy, 'faltante', v_monto, v_obs, auth.uid(), v_f.id, v_cobrador, v_hoy, v_sucursal_id)
    RETURNING id INTO v_id;
  ELSE
    INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, observacion, creado_por, recupera_faltante_id)
    VALUES (v_e.id, v_hoy, 'ajuste', v_monto, v_obs, auth.uid(), v_f.id)
    RETURNING id INTO v_id;
  END IF;

  IF p_clave IS NOT NULL THEN
    UPDATE altas_por_clave SET entidad_id = v_id WHERE clave = p_clave;
  END IF;
  RETURN v_id;
END
$function$;
REVOKE ALL ON FUNCTION public.cobrar_faltante_rendicion(bigint, numeric, text, uuid, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cobrar_faltante_rendicion(bigint, numeric, text, uuid, text, uuid) TO authenticated, service_role;

CREATE FUNCTION public.anular_cobro_faltante(p_movimiento_id bigint, p_motivo text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
DECLARE
  v_m  empleado_movimientos%ROWTYPE;
  v_e  empleados%ROWTYPE;
  v_id bigint;
BEGIN
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin ve y carga el personal' USING ERRCODE = '42501';
  END IF;
  IF p_motivo IS NULL OR btrim(p_motivo) = '' THEN
    RAISE EXCEPTION 'Escribí por qué se anula';
  END IF;
  -- El empleado antes que el movimiento y que la rendición (GTO-E).
  SELECT e.* INTO v_e FROM empleados e JOIN empleado_movimientos m ON m.empleado_id = e.id
   WHERE m.id = p_movimiento_id FOR UPDATE OF e;
  IF NOT FOUND OR NOT public._empleado_visible(v_e.sucursal_id, v_e.de_las_dos) THEN
    RAISE EXCEPTION 'Ese empleado no existe o no lo podés ver';
  END IF;
  IF v_e.usuario_id = auth.uid() THEN
    RAISE EXCEPTION 'Tu propia cuenta la maneja otro admin: no podés cambiar tus movimientos';
  END IF;
  SELECT * INTO v_m FROM empleado_movimientos WHERE id = p_movimiento_id;
  IF v_m.recupera_faltante_id IS NULL THEN
    RAISE EXCEPTION 'Ese movimiento no es un cobro contra un faltante';
  END IF;
  IF EXISTS (SELECT 1 FROM empleado_movimientos WHERE revierte_id = v_m.id) THEN
    RAISE EXCEPTION 'Ese cobro ya está anulado';
  END IF;
  IF v_m.rendicion_fecha IS NOT NULL THEN
    IF v_m.rendicion_sucursal_id IS DISTINCT FROM current_sucursal_id() THEN
      RAISE EXCEPTION 'Ese cobro es de otra sucursal' USING ERRCODE = '42501';
    END IF;
    PERFORM public._rendicion_bloquear(ARRAY[public._rendicion_clave(v_m.rendicion_transportista_id, v_m.rendicion_fecha,
                                                                     v_m.rendicion_sucursal_id)]);
    IF EXISTS (SELECT 1 FROM rendiciones_control rc
                WHERE rc.transportista_id = v_m.rendicion_transportista_id AND rc.fecha = v_m.rendicion_fecha
                  AND rc.sucursal_id = v_m.rendicion_sucursal_id
                  AND rc.estado IN ('confirmada', 'resuelta', 'disconformidad')) THEN
      RAISE EXCEPTION 'La rendición en la que entró ese efectivo ya está cerrada: reabrila primero'
        USING ERRCODE = '42501';
    END IF;
  END IF;
  INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, observacion, revierte_id, creado_por,
                                    rendicion_transportista_id, rendicion_fecha, rendicion_sucursal_id)
  VALUES (v_m.empleado_id, public._tablero_hoy(), v_m.tipo, -v_m.monto, btrim(p_motivo), v_m.id, auth.uid(),
          v_m.rendicion_transportista_id, v_m.rendicion_fecha, v_m.rendicion_sucursal_id)
  RETURNING id INTO v_id;
  RETURN v_id;
END
$function$;
REVOKE ALL ON FUNCTION public.anular_cobro_faltante(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.anular_cobro_faltante(bigint, text) TO authenticated, service_role;

-- -------------------------------------------------------------------------
-- Poscondiciones
-- -------------------------------------------------------------------------
DO $pos$
DECLARE
  v bigint;
BEGIN
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
       AND proname IN ('registrar_pagos_pedido', 'registrar_pagos_pedido_impl',
                       'registrar_pago_cliente_fifo', 'registrar_pago_cliente_fifo_impl',
                       'registrar_pago_combinado_cliente_fifo', 'registrar_pago_combinado_cliente_fifo_impl',
                       'marcar_pagos_masivo', 'marcar_pagos_masivo_impl')
       AND pg_get_function_identity_arguments(oid) LIKE '%p_cobrado_por uuid') <> 8 THEN
    RAISE EXCEPTION 'mig NNN · poscondición: las ocho RPCs de cobro no quedaron con p_cobrado_por (y una sola firma)';
  END IF;
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
                AND p.proname IN ('_cobrador_de_cobro', '_faltante_recuperado', 'pagos_cobrado_por',
                                  'rendicion_control_disconformidad_at', 'rendicion_faltantes_guarda_recupero',
                                  'registrar_pagos_pedido_impl', 'registrar_pago_cliente_fifo_impl',
                                  'registrar_pago_combinado_cliente_fifo_impl', 'marcar_pagos_masivo_impl')
                AND (has_function_privilege('anon', p.oid, 'EXECUTE')
                     OR has_function_privilege('authenticated', p.oid, 'EXECUTE'))) THEN
    RAISE EXCEPTION 'mig NNN · poscondición: una función de server quedó con EXECUTE para anon o authenticated';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p
              WHERE p.pronamespace = 'public'::regnamespace
                AND p.proname IN ('corregir_cobro_rendicion', 'cobrar_faltante_rendicion', 'anular_cobro_faltante',
                                  'registrar_pagos_pedido', 'registrar_pago_cliente_fifo',
                                  'registrar_pago_combinado_cliente_fifo', 'marcar_pagos_masivo')
                AND (has_function_privilege('anon', p.oid, 'EXECUTE')
                     OR NOT has_function_privilege('authenticated', p.oid, 'EXECUTE'))) THEN
    RAISE EXCEPTION 'mig NNN · poscondición: los EXECUTE de las RPCs quedaron mal';
  END IF;
  IF (SELECT count(*) FROM pg_constraint WHERE conrelid = 'public.pagos'::regclass AND contype = 'f'
        AND conkey @> ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid = 'public.pagos'::regclass
                                AND attname = 'cobrado_por')]) <> 0 THEN
    RAISE EXCEPTION 'mig NNN · poscondición: pagos.cobrado_por no lleva FK (PGRST201)';
  END IF;
END
$pos$;

COMMIT;
