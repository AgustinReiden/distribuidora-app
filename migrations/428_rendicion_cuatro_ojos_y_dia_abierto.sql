-- ============================================================================
-- 428 · Rendición: cuatro ojos y el pago que llega a un día cerrado (#1328)
-- ============================================================================
-- Tarjeta 7 del plan #1308. Aplicar desde el contenido LF.
-- Ensayo: scripts/test-rendicion-nucleo-1328-1329.sql (R3, R2 y R4) y
-- scripts/test-rendicion-congelada-1248.sql, que no puede cambiar.
--
-- QUÉ ES ESTO
-- -----------
-- REN-3 · El encargado que reparte, cobra y confirma su propio día se controla a
--   sí mismo: pasó en 8 de las 95 rendiciones de un encargado, la última el
--   28/07. Decisión del dueño (29/10): la confirma otro encargado o un admin, y
--   si en la sucursal hay un solo encargado, el admin. `confirmar_rendicion` lo
--   rechaza para los dos estados: marcarla en disconformidad también es hacer el
--   control. `resolver_rendicion` también, porque cierra la rendición: sin eso,
--   la suya en disconformidad se cerraba por ahí. Y `marcar_rendicion_controlada`
--   y `desmarcar_rendicion_controlada`, que el front ya no usa pero siguen
--   ejecutables: con la primera firmaba el control de otro, con la segunda borraba
--   la disconformidad que le marcaron. El admin sí confirma la suya: la decisión
--   habla del encargado.
-- REN-2 · Lo vivo de `_rendicion_pagos` no miraba si el grupo (chofer, día) ya
--   estaba cerrado. Una reimputación escapa al guard de caja, y si le cambia el
--   dueño a un pago, el pago aparece en una rendición confirmada que no lo tenía.
--   Hoy no hay ningún caso en prod: esta migración no mueve un solo pago.
--   Ahora un pago vivo que cae en un día cerrado de su chofer va al día siguiente
--   al último que cerró ese chofer, y ahí cuenta como cuenta corriente: no es la
--   entrega de ese día. Es a propósito el último y no el primer hueco: en Taco Pozo
--   cada chofer tiene entre 25 y 33 días sin cerrar, y un pago en un hueco viejo
--   queda donde nadie mira (la grilla abre una semana). Confirmar ese día lo guarda
--   en su foto; si se confirma uno posterior, el pago sigue adelante. Reabrir el día
--   original lo devuelve a su fecha, porque el día se calcula al leer: `pagos.fecha`
--   no se toca.
--   `_rendicion_tomar_foto` pide lo vivo de su día con `p_foto_de`: el trigger
--   corre con la rendición ya confirmada, y sin eso vería su propio día cerrado y
--   mandaría todos sus pagos al día siguiente. Y bloquea también los pagos que le
--   llegan de otro día, por el mismo motivo que los del día (#1292).
--
-- QUÉ SE TOCA
-- -----------
-- Reescrita entera, con premisa de md5: _rendicion_pagos (suma p_foto_de, así que
--   se dropea la firma vieja y se revocan los permisos de la nueva).
-- Parcheadas por ancla, con premisa de md5: confirmar_rendicion,
--   resolver_rendicion, marcar_rendicion_controlada,
--   desmarcar_rendicion_controlada, _rendicion_tomar_foto.

BEGIN;

-- ---------------------------------------------------------------------------
-- 0 · Premisas: nada cambió en prod desde que se leyeron los cuerpos
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, md5(pg_get_functiondef(x.firma::regprocedure)) AS md5_vivo
      FROM (VALUES
        ('public._rendicion_pagos(bigint,date,date)',               '4a5dba05740d76453368e25987dbd47b'),
        ('public._rendicion_tomar_foto(bigint)',                    'd45b49409a760779795650fa61775110'),
        ('public.confirmar_rendicion(date,uuid,text,jsonb,text)',   'bf610c1072da07d40a4f20eb1a13c13a'),
        ('public.resolver_rendicion(date,uuid,text)',               '6d12645b54847adaf40c134fe269970c'),
        ('public.marcar_rendicion_controlada(date,uuid)',           'af8a3f3cd51c741ff402a3615d3c57ff'),
        ('public.desmarcar_rendicion_controlada(date,uuid)',        'f6e93ddfef7819361518a43b7f48aaf2')
      ) AS x(firma, md5)
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION 'mig 428 · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 1 · REN-2: _rendicion_pagos
-- ---------------------------------------------------------------------------
DROP FUNCTION public._rendicion_pagos(bigint, date, date);

CREATE FUNCTION public._rendicion_pagos(p_sucursal_id bigint, p_desde date, p_hasta date, p_foto_de bigint DEFAULT NULL)
 RETURNS TABLE(t_id uuid, f date, pago_id bigint, cliente_id bigint, usuario_id uuid, monto numeric, forma_pago text, referencia text, notas text, pedido_id bigint, pedido_fecha date, pedido_estado text, pedido_total numeric, es_entrega_del_dia boolean, pago_created_at timestamp with time zone, congelado boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  -- #1328: p_foto_de es la rendicion que esta tomando su foto. El trigger corre
  -- con ella ya confirmada y su dia, para ella, sigue abierto.
  WITH cerradas AS MATERIALIZED (
    SELECT rc.transportista_id, rc.fecha
      FROM rendiciones_control rc
     WHERE rc.sucursal_id = p_sucursal_id
       AND rc.estado IN ('confirmada', 'resuelta')
       AND rc.id IS DISTINCT FROM p_foto_de
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
   CROSS JOIN LATERAL (SELECT COALESCE(pd.transportista_id, pg.usuario_id) AS t) dueno
    -- #1328: el dia del pago esta cerrado para su chofer y la foto no lo tiene: va
    -- al dia siguiente al ultimo que cerro ese chofer, no a un hueco viejo.
    LEFT JOIN LATERAL (
      SELECT max(c.fecha) + 1 AS abierto
        FROM cerradas c
       WHERE c.transportista_id = dueno.t
         AND EXISTS (SELECT 1 FROM cerradas d
                      WHERE d.transportista_id = dueno.t AND d.fecha = pg.fecha)
    ) dia ON true
   WHERE pg.sucursal_id = p_sucursal_id
     AND pg.fecha <= p_hasta
     AND COALESCE(dia.abierto, pg.fecha) BETWEEN p_desde AND p_hasta
     AND COALESCE(pg.forma_pago, '') <> 'nota_credito'
     AND NOT EXISTS (
       SELECT 1
         FROM rendicion_pagos_confirmados fo
         JOIN rendiciones_control rc ON rc.id = fo.rendicion_id
        WHERE fo.pago_id IN (pg.id, pg.pago_origen_id)
          AND (fo.pago_id = pg.id OR pg.id > fo.ultimo_pago_id)
          AND rc.estado IN ('confirmada', 'resuelta'));
$function$;

REVOKE ALL ON FUNCTION public._rendicion_pagos(bigint, date, date, bigint) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2 · Parches por ancla
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _r_parche (firma text, orden int, ancla text, reemplazo text, veces int DEFAULT 1) ON COMMIT DROP;

INSERT INTO _r_parche (firma, orden, ancla, reemplazo) VALUES
('public._rendicion_tomar_foto(bigint)', 1,
$a$  PERFORM 1
     FROM pagos
    WHERE sucursal_id = r.sucursal_id
      AND fecha = r.fecha
    ORDER BY id
      FOR SHARE;
$a$,
$r$  -- #1328: tambien los que le llegan de un dia cerrado.
  PERFORM 1
     FROM pagos
    WHERE sucursal_id = r.sucursal_id
      AND (fecha = r.fecha
           OR id IN (SELECT v.pago_id
                       FROM public._rendicion_pagos(r.sucursal_id, r.fecha, r.fecha, r.id) v
                      WHERE NOT v.congelado))
    ORDER BY id
      FOR SHARE;
$r$),
('public._rendicion_tomar_foto(bigint)', 2,
$a$    FROM public._rendicion_pagos(r.sucursal_id, r.fecha, r.fecha) v
   WHERE v.t_id = r.transportista_id
$a$,
$r$    FROM public._rendicion_pagos(r.sucursal_id, r.fecha, r.fecha, r.id) v
   WHERE v.t_id = r.transportista_id
$r$),
('public.confirmar_rendicion(date,uuid,text,jsonb,text)', 1,
$a$  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF p_estado NOT IN ('confirmada','disconformidad') THEN
$a$,
$r$  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  -- #1328: el encargado no controla su propia rendicion. Marcarla en
  -- disconformidad tambien es hacer el control.
  IF p_transportista_id = auth.uid() AND NOT es_admin() THEN
    RAISE EXCEPTION 'Tu rendición la confirma otro encargado o un admin'
      USING ERRCODE = '42501';
  END IF;

  IF p_estado NOT IN ('confirmada','disconformidad') THEN
$r$),
('public.resolver_rendicion(date,uuid,text)', 1,
$a$  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  -- gastos 3: un gasto que se esta guardando desde Gastos sobre esta
$a$,
$r$  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  -- #1328: resolverla la cierra, asi que rige lo mismo que para confirmarla.
  IF p_transportista_id = auth.uid() AND NOT es_admin() THEN
    RAISE EXCEPTION 'Tu rendición la resuelve otro encargado o un admin'
      USING ERRCODE = '42501';
  END IF;

  -- gastos 3: un gasto que se esta guardando desde Gastos sobre esta
$r$),
('public.marcar_rendicion_controlada(date,uuid)', 1,
$a$  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  INSERT INTO rendiciones_control (fecha, transportista_id, sucursal_id, controlada_por)
$a$,
$r$  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  -- #1328: la misma regla que confirmar_rendicion.
  IF p_transportista_id = auth.uid() AND NOT es_admin() THEN
    RAISE EXCEPTION 'Tu rendición la controla otro encargado o un admin'
      USING ERRCODE = '42501';
  END IF;

  INSERT INTO rendiciones_control (fecha, transportista_id, sucursal_id, controlada_por)
$r$),
('public.desmarcar_rendicion_controlada(date,uuid)', 1,
$a$  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  DELETE FROM rendiciones_control
$a$,
$r$  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  -- #1328: la misma regla que confirmar_rendicion.
  IF p_transportista_id = auth.uid() AND NOT es_admin() THEN
    RAISE EXCEPTION 'Tu rendición la reabre otro encargado o un admin'
      USING ERRCODE = '42501';
  END IF;

  DELETE FROM rendiciones_control
$r$);

DO $parches$
DECLARE
  v_f   record;
  v_p   record;
  v_def text;
  v_n   int;
BEGIN
  FOR v_f IN SELECT DISTINCT firma FROM _r_parche ORDER BY firma LOOP
    v_def := pg_get_functiondef(v_f.firma::regprocedure);
    FOR v_p IN SELECT * FROM _r_parche WHERE firma = v_f.firma ORDER BY orden LOOP
      v_n := (length(v_def) - length(replace(v_def, v_p.ancla, ''))) / length(v_p.ancla);
      IF v_n <> v_p.veces THEN
        RAISE EXCEPTION 'mig 428 · % parche %: el ancla aparece % vez/veces y se esperaba %',
          v_f.firma, v_p.orden, v_n, v_p.veces;
      END IF;
      v_def := replace(v_def, v_p.ancla, v_p.reemplazo);
    END LOOP;
    EXECUTE v_def;
  END LOOP;
END
$parches$;

-- ---------------------------------------------------------------------------
-- 3 · Verificación
-- ---------------------------------------------------------------------------
DO $verif$
BEGIN
  IF to_regprocedure('public._rendicion_pagos(bigint,date,date)') IS NOT NULL THEN
    RAISE EXCEPTION 'mig 428 · quedó la firma vieja de _rendicion_pagos';
  END IF;
  IF has_function_privilege('anon', 'public._rendicion_pagos(bigint,date,date,bigint)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._rendicion_pagos(bigint,date,date,bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'mig 428 · _rendicion_pagos quedó alcanzable por REST';
  END IF;
  -- Hoy ningún pago vivo cae en un día cerrado: nada cambió de lugar.
  IF EXISTS (
    SELECT 1
      FROM sucursales s
     CROSS JOIN LATERAL public._rendicion_pagos(s.id, DATE '2020-01-01', DATE '2099-12-31') p
      JOIN pagos pg ON pg.id = p.pago_id
     WHERE NOT p.congelado AND p.f <> pg.fecha) THEN
    RAISE EXCEPTION 'mig 428 · hay pagos vivos en un día cerrado: revisarlos antes de aplicar';
  END IF;
END
$verif$;

COMMIT;
