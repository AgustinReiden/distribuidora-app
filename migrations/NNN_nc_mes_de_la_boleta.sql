-- =========================================================================
-- NNN · LA NOTA DE CRÉDITO DE VENTA SE IMPUTA AL MES DE SU BOLETA, Y RESTA DE
--       LAS COMISIONES Y DE LAS METAS
--       (plan #1603, ola 2, tarjeta B16: decisiones del dueño del 16/11 en
--        #1545 y #1551)
--
-- Ensayo: scripts/test-nc-mes-de-la-boleta-ola2-1603.sql. Se aplica en LF.
--
-- =========================================================================
-- 1 · LA NOTA SE IMPUTA AL DÍA DE SU BOLETA
-- =========================================================================
-- Decisión del dueño (16/11): «lo correcto es que se impute al mismo mes de la
-- boleta y si bien haya un campo de cuando se creó efectivamente, la fecha de
-- imputación también existe y es la que cuenta para estadísticas y
-- fiscalmente».
--   · `notas_credito_venta.fecha` pasa a ser la fecha de imputación: la de su
--     boleta (`pedidos.fecha`). Cuándo se creó lo sigue diciendo `created_at`.
--   · El freno está en la tabla: `trg_notas_credito_venta_fecha_de_boleta`
--     (BEFORE INSERT OR UPDATE OF fecha, pedido_id; lee la boleta FOR SHARE, así
--     un cambio de fecha concurrente no la deja atrás) le pone la fecha de su
--     boleta, mande lo que mande quien escribe. Y si cambia la fecha de la
--     boleta, `trg_pedidos_fecha_arrastra_notas_credito` lleva sus notas
--     (vigentes y anuladas) a la nueva: la nota no se separa de su boleta, y
--     corregir la fecha de una boleta no se frena por tener una nota.
--   · La plata no cambia de día: el crédito de la nota (sus pagos, con
--     `nota_credito_id`), la caja y la rendición siguen con la fecha en que se
--     emitió. crear_nota_credito_venta_impl sigue fechando el pago hoy, y
--     devuelve `fecha` (la de imputación) y `creada_el` (hoy, clave nueva).
--   · Las notas que ya existen se corrigen a la fecha de su boleta (en
--     producción, al 16/11: tres, creadas en octubre sobre boletas de
--     septiembre). El bloque dice cuántas movió.
--   · Consecuencia: posicion_fiscal, el gerencial, Ventas por cliente/zona/
--     preventista y el tablero restan la nota por su `fecha` (sin cambiar su
--     cuenta), así que una nota emitida en noviembre sobre una boleta de
--     octubre cambia la posición fiscal y la venta de octubre aunque ya haya
--     cerrado. Es lo que pidió el dueño. La NC de COMPRA no cambia.
--
-- =========================================================================
-- 2 · LA NOTA RESTA DE LA COMISIÓN Y DE LAS METAS
-- =========================================================================
-- Decisión del dueño (16/11): «Si hay una nota de crédito sí resta de las
-- comisiones y las metas».
--   · La comisión es una (`_comision_lineas`): cada clave de una boleta
--     (producto + combo + origen) baja por lo que acreditan las notas vigentes
--     de esa boleta en esa clave, con tope en lo que la clave vende. La nota
--     cae en la clave de su renglón; si el renglón ya no está (la edición rehace
--     las líneas), en la del mismo producto de la boleta, y si la boleta no lo
--     tiene (sólo por una carga directa del server), en la de su renglón de
--     mayor venta, como la resta el gerencial. La parte pagada con
--     adelanto de sueldo ya no comisionaba, y la nota resta en la misma
--     proporción. Las notas salen de `_ventas_nc` (la regla de B8b), no de una
--     copia. Con eso cambian calcular_comisiones (/comisiones), la
--     previsualización y la liquidación, sin tocarlas.
--   · La liquidación es un libro de deltas: una nota emitida después de
--     liquidar el período sale como un ajuste negativo en la liquidación
--     siguiente, y anularla, como uno positivo. `_liquidacion_lineas` lo rotula
--     («Nota de crédito sobre el pedido», «Se anuló una nota de crédito del
--     pedido»).
--   · El gerencial: `kpis.base_comision` y `vendedores[].base_nc` restan las
--     notas de sus boletas (su `nc`, por ancla y sin premisa de md5: B18 parcha
--     otro tramo de la misma función).
--   · Las metas (avance_metas_preventista) y Metas › Rendimiento
--     (rendimiento_preventistas): la venta, la facturación de las metas, el
--     margen, el ticket, por marca y por rubro, netos de las notas. Las
--     unidades no: la nota resta plata, no unidades (la regla de `_ventas_nc`,
--     como en el gerencial). Pedidos, cobertura y clientes nuevos, tampoco.
--   · El bot: bot_ventas_periodo y bot_mis_ventas (y el resumen del
--     preventista, que lee bot_mis_ventas): la venta, el ticket, el top de
--     clientes y lo facturado por producto, netos. Las claves de los JSON no
--     cambian.
--   · reporte_rentabilidad sigue por boleta: es de la tarjeta B8b y su
--     desglose (IVA, impuestos internos, dentro y fuera de combo) no se netea
--     con una resta.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

-- Las dos tablas con DDL (los CREATE TRIGGER): sus locks primero, juntos y sin
-- esperar. Si alguno está tomado, la migración falla al instante y se reintenta.
LOCK TABLE public.pedidos, public.notas_credito_venta IN SHARE ROW EXCLUSIVE MODE NOWAIT;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos de producción en la 525. reporte_gerencial va sin
-- md5 (B18 le parcha el tramo de compras): se exige que las anclas de su tramo
-- aparezcan una vez.
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)', 'a58b4f71752f8b004fbc3c524b12be8b'),
    ('public._comision_lineas(bigint[])', 'b20534d37d4a481d0154326fbbcccda8'),
    ('public._liquidacion_lineas(empleados,date)', 'b0f0bf5343ee5a54f254a866218be28c'),
    ('public.avance_metas_preventista(uuid,date)', '2e6695223c3add5fe1e23944884493a9'),
    ('public.rendimiento_preventistas(bigint,date)', 'bd3dcdc97f4bf07f325ecafb10f97a09'),
    ('public.bot_ventas_periodo(date,date,bigint,integer)', 'bd6bef33c089422952ddb0e549be3cc9'),
    ('public.bot_mis_ventas(uuid,date,date,bigint,integer)', 'fff91e69cfa74fd6c95ac05b57a5299e'),
    ('public.reporte_gerencial(bigint,date,date,boolean,boolean)', NULL),
    ('public._ventas_nc(bigint[],date,date)', 'c44fdae60942de6e93649d62b2024d75')
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
  IF to_regproc('public.notas_credito_venta_fecha_de_boleta') IS NOT NULL
     OR to_regproc('public.pedidos_fecha_arrastra_notas_credito') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · las funciones de los frenos ya existen: revisar a mano';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_trigger
              WHERE tgname IN ('trg_notas_credito_venta_fecha_de_boleta', 'trg_pedidos_fecha_arrastra_notas_credito')) THEN
    RAISE EXCEPTION 'mig NNN · los triggers ya existen: revisar a mano';
  END IF;
END
$premisas$;

-- Reemplaza una sola aparición de un ancla en una definición. Las definiciones
-- se leen en LF (dos de las vivas tienen CRLF en prod: da lo mismo para el SQL).
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

CREATE FUNCTION pg_temp.def(p_f text)
RETURNS text LANGUAGE sql AS $f$
  SELECT replace(pg_get_functiondef(p_f::regprocedure), E'\r\n', E'\n');
$f$;

-- =========================================================================
-- 1 · La fecha de la nota es la de su boleta
-- =========================================================================

-- B16 (#1545, decisión del dueño del 16/11): la fecha de una nota de crédito de
-- venta es la de imputación, la de su boleta; cuándo se creó es created_at. Le
-- pone la fecha de la boleta a toda nota que se escribe, venga de donde venga.
CREATE FUNCTION public.notas_credito_venta_fecha_de_boleta()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_fecha date;
BEGIN
  -- FOR SHARE (H2 de la revisión): un cambio de fecha de la boleta en otra
  -- transacción espera a que ésta termine, o ésta lee la fecha que dejó. La RPC
  -- ya tiene la boleta FOR UPDATE, y el arrastre la tiene por su UPDATE: es la
  -- misma transacción, no espera.
  SELECT p.fecha INTO v_fecha
    FROM pedidos p
   WHERE p.id = NEW.pedido_id AND p.sucursal_id = NEW.sucursal_id
     FOR SHARE;
  -- Sin boleta, la FK compuesta rechaza la fila: no hay fecha que poner.
  IF v_fecha IS NOT NULL THEN
    NEW.fecha := v_fecha;
  END IF;
  RETURN NEW;
END
$function$;

REVOKE ALL ON FUNCTION public.notas_credito_venta_fecha_de_boleta() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.notas_credito_venta_fecha_de_boleta() TO service_role;

CREATE TRIGGER trg_notas_credito_venta_fecha_de_boleta
  BEFORE INSERT OR UPDATE OF fecha, pedido_id ON public.notas_credito_venta
  FOR EACH ROW EXECUTE FUNCTION public.notas_credito_venta_fecha_de_boleta();

-- B16: si la boleta cambia de fecha, sus notas (vigentes y anuladas) van con
-- ella. DEFINER: el admin corrige la fecha por REST y authenticated no escribe
-- notas_credito_venta. El orden de locks es el de la NC: la boleta y después
-- sus notas.
CREATE FUNCTION public.pedidos_fecha_arrastra_notas_credito()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  UPDATE notas_credito_venta
     SET fecha = NEW.fecha
   WHERE pedido_id = NEW.id
     AND sucursal_id = NEW.sucursal_id
     AND fecha IS DISTINCT FROM NEW.fecha;
  RETURN NULL;
END
$function$;

REVOKE ALL ON FUNCTION public.pedidos_fecha_arrastra_notas_credito() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pedidos_fecha_arrastra_notas_credito() TO service_role;

CREATE TRIGGER trg_pedidos_fecha_arrastra_notas_credito
  AFTER UPDATE OF fecha ON public.pedidos
  FOR EACH ROW WHEN (OLD.fecha IS DISTINCT FROM NEW.fecha)
  EXECUTE FUNCTION public.pedidos_fecha_arrastra_notas_credito();

COMMENT ON COLUMN public.notas_credito_venta.fecha IS
  'La fecha de imputación: la de su boleta (pedidos.fecha), que la pone trg_notas_credito_venta_fecha_de_boleta y arrastra trg_pedidos_fecha_arrastra_notas_credito (B16, decisión del dueño del 16/11). Es la que cuenta para los reportes y la posición fiscal. Cuándo se creó es created_at; su crédito (pagos) va con la fecha en que se emitió.';

-- Las notas que ya existen, a la fecha de su boleta. En producción, al 16/11,
-- eran tres (dos vigentes y una anulada), creadas en octubre sobre boletas de
-- septiembre: si son muchas más, mirar antes de moverlas.
DO $datos$
DECLARE
  v_total   int;
  v_mover   int;
  v_vig     int;
  v_movidas int;
BEGIN
  SELECT count(*),
         count(*) FILTER (WHERE n.fecha IS DISTINCT FROM p.fecha),
         count(*) FILTER (WHERE n.fecha IS DISTINCT FROM p.fecha AND NOT n.anulada)
    INTO v_total, v_mover, v_vig
    FROM notas_credito_venta n
    JOIN pedidos p ON p.id = n.pedido_id AND p.sucursal_id = n.sucursal_id;
  RAISE NOTICE 'mig NNN · notas de crédito de venta: % en total, % con otra fecha que la de su boleta (% vigentes)',
    v_total, v_mover, v_vig;
  IF v_mover > 20 THEN
    RAISE EXCEPTION 'mig NNN · hay % notas de venta fuera de la fecha de su boleta (el 16/11 eran 3): revisarlas antes de moverlas', v_mover;
  END IF;

  UPDATE notas_credito_venta n
     SET fecha = p.fecha
    FROM pedidos p
   WHERE p.id = n.pedido_id AND p.sucursal_id = n.sucursal_id
     AND n.fecha IS DISTINCT FROM p.fecha;
  GET DIAGNOSTICS v_movidas = ROW_COUNT;
  RAISE NOTICE 'mig NNN · se movieron % notas de crédito de venta a la fecha de su boleta', v_movidas;

  IF v_movidas <> v_mover OR EXISTS (
       SELECT 1 FROM notas_credito_venta n JOIN pedidos p ON p.id = n.pedido_id AND p.sucursal_id = n.sucursal_id
        WHERE n.fecha IS DISTINCT FROM p.fecha) THEN
    RAISE EXCEPTION 'mig NNN · quedaron notas fuera de la fecha de su boleta (movidas %, esperadas %)', v_movidas, v_mover;
  END IF;
END
$datos$;

-- crear_nota_credito_venta_impl: la nota con la fecha de la boleta (el trigger
-- la pondría igual: así se lee), el crédito con la de hoy, y lo devuelve.
DO $nc$
DECLARE
  v_def text := pg_temp.def('public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)');
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  v_fecha     date   := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;$a$,
$n$  v_fecha     date   := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_fecha_nc  date;   -- B16: la de imputación, la de la boleta$n$, 'nc · declare');
  v_def := pg_temp.parche(v_def,
$a$  INSERT INTO notas_credito_venta (
    sucursal_id, cliente_id, pedido_id, fecha, motivo, observaciones, total, usuario_id,
    neto, iva
  ) VALUES (
    v_sucursal, p_cliente_id, p_pedido_id, v_fecha, p_motivo, NULLIF(trim(p_observaciones), ''),
    v_total, v_user,
    round(v_neto, 2), round(v_iva, 2)
  ) RETURNING id INTO v_nc_id;$a$,
$n$  -- B16 (#1545, decisión del dueño del 16/11): la nota se imputa al día de su
  -- boleta (trg_notas_credito_venta_fecha_de_boleta lo garantiza); cuándo se creó
  -- es created_at. Su crédito (el pago de abajo) es plata de hoy: v_fecha.
  INSERT INTO notas_credito_venta (
    sucursal_id, cliente_id, pedido_id, fecha, motivo, observaciones, total, usuario_id,
    neto, iva
  ) VALUES (
    v_sucursal, p_cliente_id, p_pedido_id, (SELECT pb.fecha FROM pedidos pb WHERE pb.id = p_pedido_id),
    p_motivo, NULLIF(trim(p_observaciones), ''),
    v_total, v_user,
    round(v_neto, 2), round(v_iva, 2)
  ) RETURNING id, fecha INTO v_nc_id, v_fecha_nc;$n$, 'nc · insert');
  v_def := pg_temp.parche(v_def,
$a$    'fecha', v_fecha,$a$,
$n$    'fecha', v_fecha_nc,
    'creada_el', v_fecha,$n$, 'nc · respuesta');
  EXECUTE v_def;
END
$nc$;

-- =========================================================================
-- 2 · La nota resta de la comisión (una sola: _comision_lineas)
-- =========================================================================
DO $com$
DECLARE
  v_def text := pg_temp.def('public._comision_lineas(bigint[])');
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  it AS (
    SELECT ped.id AS pedido_id, ped.usuario_id, ped.fecha, ped.sucursal_id,
           pi.subtotal * ped.factor AS subtotal,$a$,
$n$  lin AS (
    SELECT ped.id AS pedido_id, ped.usuario_id, ped.fecha, ped.sucursal_id,
           pi.subtotal * ped.factor AS subtotal,
           COALESCE(pi.producto_id::text, '-') || '|' || COALESCE(pi.combo_id::text, '-') || '|'
             || COALESCE(pi.origen_precio::text, '-') AS clave,$n$, 'comision · lin');
  v_def := pg_temp.parche(v_def,
$a$      AND ped.factor > 0
  )
  SELECT it.pedido_id,$a$,
$n$      AND ped.factor > 0
  ),
  -- B16 (#1545, decisión del dueño del 16/11): la nota de crédito resta de la
  -- comisión. Las notas vigentes de estas boletas (_ventas_nc: la nota se imputa
  -- al día de su boleta, así que el rango de las boletas las trae a todas), cada
  -- renglón en la clave de su renglón de la boleta o, si la edición lo rehízo, en
  -- la del mismo producto; si la boleta no tiene ese producto (sólo por una carga
  -- directa del server), en la de su renglón de mayor venta, como la resta el
  -- gerencial (por boleta). Con el mismo factor del adelanto de sueldo.
  nc AS (
    SELECT v.pedido_id,
           COALESCE((CASE WHEN pi.id IS NOT NULL THEN pi.producto_id
                          ELSE COALESCE(alt.producto_id, v.producto_id) END)::text, '-') || '|'
             || COALESCE((CASE WHEN pi.id IS NOT NULL THEN pi.combo_id ELSE alt.combo_id END)::text, '-') || '|'
             || COALESCE(CASE WHEN pi.id IS NOT NULL THEN pi.origen_precio::text ELSE alt.origen_precio END, '-') AS clave,
           v.monto * ped.factor AS monto
      FROM public._ventas_nc(ARRAY(SELECT DISTINCT ped.sucursal_id FROM ped),
                             (SELECT min(ped.fecha) FROM ped), (SELECT max(ped.fecha) FROM ped)) v
      JOIN ped ON ped.id = v.pedido_id
      LEFT JOIN pedido_items pi ON pi.id = v.pedido_item_id AND pi.pedido_id = v.pedido_id
      LEFT JOIN LATERAL (
        SELECT x.producto_id, x.combo_id, x.origen_precio::text AS origen_precio
          FROM pedido_items x
         WHERE x.pedido_id = v.pedido_id
           AND COALESCE(x.es_bonificacion, false) = false
         ORDER BY (x.producto_id IS NOT DISTINCT FROM v.producto_id) DESC,
                  CASE WHEN x.producto_id IS NOT DISTINCT FROM v.producto_id
                       THEN (x.combo_id IS NULL)::int ELSE 0 END DESC,
                  CASE WHEN x.producto_id IS NOT DISTINCT FROM v.producto_id
                       THEN 0 ELSE x.subtotal END DESC,
                  x.id
         LIMIT 1
      ) alt ON pi.id IS NULL
  ),
  -- Lo que restan las notas en cada clave, con tope en lo que la clave vende.
  -- MATERIALIZED (H1 de la revisión de B16): sin eso el planner, que estima `lin`
  -- en una fila, lo reordenaba por cada renglón (un mes de boletas con una sola
  -- nota pasaba de 1 s a más de 8). Sólo las boletas con nota.
  nc_clave AS MATERIALIZED (
    SELECT k.pedido_id, k.clave, k.base, LEAST(n.monto, k.base) AS monto
      FROM (SELECT lin.pedido_id, lin.clave, SUM(lin.subtotal) AS base
              FROM lin
             WHERE lin.pedido_id IN (SELECT nc.pedido_id FROM nc)
             GROUP BY lin.pedido_id, lin.clave) k
      JOIN (SELECT nc.pedido_id, nc.clave, SUM(nc.monto) AS monto FROM nc GROUP BY nc.pedido_id, nc.clave) n
        ON n.pedido_id = k.pedido_id AND n.clave = k.clave
     WHERE k.base > 0
  ),
  -- Cada renglón de la clave baja en proporción: los renglones (y los ítems) son
  -- los de la boleta, y la suma de la clave es su venta menos sus notas.
  it AS (
    SELECT l.pedido_id, l.usuario_id, l.fecha, l.sucursal_id,
           CASE WHEN k.pedido_id IS NULL THEN l.subtotal
                ELSE l.subtotal - k.monto * l.subtotal / k.base END AS subtotal,
           l.producto_id, l.combo_id, l.origen_precio, l.categoria_id, l.pct_default
      FROM lin l
      LEFT JOIN nc_clave k ON k.pedido_id = l.pedido_id AND k.clave = l.clave
  )
  SELECT it.pedido_id,$n$, 'comision · nc');
  EXECUTE v_def;
END
$com$;

-- La liquidación: una nota emitida o anulada después de lo liquidado sale como
-- ajuste en la siguiente (el libro de deltas ya lo hace con lo de arriba); acá,
-- su motivo.
DO $liq$
DECLARE
  v_def text := pg_temp.def('public._liquidacion_lineas(empleados,date)');
BEGIN
  v_def := pg_temp.parche(v_def,
$a$              WHEN p.estado = 'entregado' THEN 'Cambió la boleta del pedido'$a$,
$n$              -- B16 (#1545): una nota de crédito de la boleta, emitida o anulada
              -- después de la última liquidación que la congeló.
              WHEN p.estado = 'entregado' AND EXISTS (
                     SELECT 1 FROM notas_credito_venta n
                      WHERE n.pedido_id = c.pedido_id AND n.anulada AND n.anulada_at > cg.congelado_at)
                THEN 'Se anuló una nota de crédito del pedido'
              WHEN p.estado = 'entregado' AND EXISTS (
                     SELECT 1 FROM notas_credito_venta n
                      WHERE n.pedido_id = c.pedido_id AND n.created_at > cg.congelado_at)
                THEN 'Nota de crédito sobre el pedido'
              WHEN p.estado = 'entregado' THEN 'Cambió la boleta del pedido'$n$, 'liquidacion · motivo');
  v_def := pg_temp.parche(v_def,
$a$    FROM cruce c
    JOIN pedidos p ON p.id = c.pedido_id
$a$,
$n$    FROM cruce c
    JOIN pedidos p ON p.id = c.pedido_id
    LEFT JOIN LATERAL (
      SELECT max(lq.created_at) AS congelado_at
        FROM empleado_liquidacion_lineas ll
        JOIN empleado_liquidaciones lq ON lq.id = ll.liquidacion_id
       WHERE ll.pedido_id = c.pedido_id AND ll.usuario_id = c.usuario_id AND ll.vigente
    ) cg ON true
$n$, 'liquidacion · congelado');
  EXECUTE v_def;
END
$liq$;

-- El gerencial: la base de comisión (kpis y vendedores) resta las notas de sus
-- boletas. Sólo el CTE `nc`, por ancla.
DO $ger$
DECLARE
  v_def text := pg_temp.def('public.reporte_gerencial(bigint,date,date,boolean,boolean)');
BEGIN
  v_def := pg_temp.parche(v_def,
$a$           ROUND(GREATEST(pe.total - pe.cargo_envio, 0)
                 * CASE WHEN pe.total > 0$a$,
$n$           -- B16 (#1545): menos las notas de crédito de la boleta (ncl, _ventas_nc).
           ROUND(GREATEST(GREATEST(pe.total - pe.cargo_envio, 0) - COALESCE(ncp.monto, 0), 0)
                 * CASE WHEN pe.total > 0$n$, 'gerencial · base');
  v_def := pg_temp.parche(v_def,
$a$      ) ad ON true
     WHERE pe.estado='entregado' AND pe.canal <> 'cambio'$a$,
$n$      ) ad ON true
      LEFT JOIN (SELECT ncl.pedido_id, SUM(ncl.monto) AS monto FROM ncl GROUP BY ncl.pedido_id) ncp
        ON ncp.pedido_id = pe.id
     WHERE pe.estado='entregado' AND pe.canal <> 'cambio'$n$, 'gerencial · notas');
  EXECUTE v_def;
END
$ger$;

-- =========================================================================
-- 3 · La nota resta de las metas
-- =========================================================================
DO $metas$
DECLARE
  v_def text := pg_temp.def('public.avance_metas_preventista(uuid,date)');
BEGIN
  v_def := pg_temp.parche(v_def,
$a$    LEFT JOIN productos prod ON prod.id = pi.producto_id
    WHERE pi.es_bonificacion IS NOT TRUE
  ),$a$,
$n$    LEFT JOIN productos prod ON prod.id = pi.producto_id
    WHERE pi.es_bonificacion IS NOT TRUE
    UNION ALL
    -- B16 (#1545, decisión del dueño del 16/11): las notas de crédito de sus
    -- boletas restan de la facturación, imputadas al día de la boleta
    -- (_ventas_nc). Restan plata, no unidades.
    SELECT n.sucursal_id, n.fecha, 0, -n.monto, n.producto_id, prod.categoria_id, prod.marca_id
      FROM public._ventas_nc(v_sucursales, v_min, v_max) n
      LEFT JOIN productos prod ON prod.id = n.producto_id
     WHERE n.usuario_id = v_target
  ),$n$, 'metas · it');
  EXECUTE v_def;
END
$metas$;

DO $rend$
DECLARE
  v_def text := pg_temp.def('public.rendimiento_preventistas(bigint,date)');
BEGIN
  v_def := pg_temp.parche(v_def,
$a$    LEFT JOIN categorias cat ON cat.id = prod.categoria_id  -- 1562-b7: el rubro
    WHERE pi.es_bonificacion IS NOT TRUE
  ),$a$,
$n$    LEFT JOIN categorias cat ON cat.id = prod.categoria_id  -- 1562-b7: el rubro
    WHERE pi.es_bonificacion IS NOT TRUE
    UNION ALL
    -- B16 (#1545, decisión del dueño del 16/11): las notas de crédito de las
    -- boletas del mes restan de la venta, el margen, la marca y el rubro de su
    -- vendedor (_ventas_nc, como el gerencial): plata, no unidades ni costo. Una
    -- línea acreditada sin costo resta de la venta sin costo.
    SELECT n.usuario_id, 0, -n.monto,
           0 * public.costo_valuacion(n.costo_al_crear, prod.costo_promedio,
             prod.costo_real, prod.costo_sin_iva, prod.impuestos_internos),
           COALESCE(mar.nombre, '(sin marca)'),
           CASE WHEN prod.id IS NULL THEN '(producto borrado)'
                ELSE public._rubro_rotulo(COALESCE(cat.nombre, prod.categoria)) END
      FROM public._ventas_nc(v_sucursales, v_periodo, v_hasta) n
      LEFT JOIN productos prod ON prod.id = n.producto_id
      LEFT JOIN marcas mar ON mar.id = prod.marca_id
      LEFT JOIN categorias cat ON cat.id = prod.categoria_id
  ),$n$, 'rendimiento · it');
  EXECUTE v_def;
END
$rend$;

-- =========================================================================
-- 4 · El bot: la misma venta neta (sin cambiar sus JSON)
-- =========================================================================
DO $bot$
DECLARE
  v_def text := pg_temp.def('public.bot_ventas_periodo(date,date,bigint,integer)');
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  WITH ventas_filtradas AS ($a$,
$n$  WITH nc AS MATERIALIZED (
    -- B16 (#1545): las notas de crédito de las boletas del período (_ventas_nc,
    -- imputadas al día de su boleta) restan de la venta, del top de clientes y de
    -- lo facturado por producto. No de las unidades. MATERIALIZED: _ventas_nc corre
    -- una vez, no una por boleta.
    SELECT n.pedido_id, n.producto_id, n.monto
      FROM public._ventas_nc(ARRAY[p_sucursal_id], p_desde, p_hasta) n
  ),
  ventas_filtradas AS ($n$, 'bot_ventas_periodo · nc');
  v_def := pg_temp.parche(v_def,
$a$    SELECT id, cliente_id, GREATEST(total - cargo_envio, 0) AS total, fecha$a$,
$n$    SELECT id, cliente_id,
           GREATEST(total - cargo_envio, 0)
             - COALESCE((SELECT SUM(nc.monto) FROM nc WHERE nc.pedido_id = pedidos.id), 0) AS total,
           fecha$n$, 'bot_ventas_periodo · total');
  v_def := pg_temp.parche(v_def,
$a$    SELECT p.id, p.codigo, p.nombre, SUM(pi.cantidad) AS unidades, SUM(pi.subtotal) AS facturado$a$,
$n$    SELECT p.id, p.codigo, p.nombre, SUM(pi.cantidad) AS unidades,
           SUM(pi.subtotal) - COALESCE((SELECT SUM(nc.monto) FROM nc WHERE nc.producto_id = p.id), 0) AS facturado$n$,
    'bot_ventas_periodo · facturado');
  v_def := pg_temp.parche(v_def,
$a$    ORDER BY SUM(pi.subtotal) DESC LIMIT p_limit$a$,
$n$    ORDER BY facturado DESC LIMIT p_limit$n$, 'bot_ventas_periodo · orden');
  EXECUTE v_def;

  v_def := pg_temp.def('public.bot_mis_ventas(uuid,date,date,bigint,integer)');
  v_def := pg_temp.parche(v_def,
$a$  WITH ventas_filtradas AS ($a$,
$n$  WITH nc AS MATERIALIZED (
    -- B16 (#1545): las notas de crédito de sus boletas restan (_ventas_nc). El
    -- resumen del preventista (bot_digest_preventista) lo lee de acá. MATERIALIZED:
    -- _ventas_nc corre una vez, no una por boleta.
    SELECT n.pedido_id, n.monto
      FROM public._ventas_nc(ARRAY[p_sucursal_id], p_desde, p_hasta) n
     WHERE n.usuario_id = p_preventista_id
  ),
  ventas_filtradas AS ($n$, 'bot_mis_ventas · nc');
  v_def := pg_temp.parche(v_def,
$a$    SELECT p.id, p.cliente_id, GREATEST(p.total - p.cargo_envio, 0) AS total$a$,
$n$    SELECT p.id, p.cliente_id,
           GREATEST(p.total - p.cargo_envio, 0)
             - COALESCE((SELECT SUM(nc.monto) FROM nc WHERE nc.pedido_id = p.id), 0) AS total$n$,
    'bot_mis_ventas · total');
  EXECUTE v_def;
END
$bot$;

-- =========================================================================
-- Poscondiciones
-- =========================================================================
DO $post$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)', 'v_fecha_nc', true),
    ('public._comision_lineas(bigint[])', '_ventas_nc', false),
    ('public._liquidacion_lineas(empleados,date)', 'Se anuló una nota de crédito del pedido', false),
    ('public.reporte_gerencial(bigint,date,date,boolean,boolean)', 'COALESCE(ncp.monto, 0)', true),
    ('public.avance_metas_preventista(uuid,date)', '_ventas_nc', true),
    ('public.rendimiento_preventistas(bigint,date)', 'FROM public._ventas_nc(v_sucursales, v_periodo, v_hasta)', true),
    ('public.bot_ventas_periodo(date,date,bigint,integer)', '_ventas_nc', true),
    ('public.bot_mis_ventas(uuid,date,date,bigint,integer)', '_ventas_nc', true)
  ) AS t(f, marca, definer) LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = r.f::regprocedure
                    AND position(r.marca in prosrc) > 0 AND prosecdef = r.definer) THEN
      RAISE EXCEPTION 'mig NNN · el parche de % no entró', r.f;
    END IF;
  END LOOP;
  -- Los frenos: de server, sin EXECUTE para nadie de la API.
  FOR r IN SELECT unnest(ARRAY['public.notas_credito_venta_fecha_de_boleta()',
                               'public.pedidos_fecha_arrastra_notas_credito()']) AS f LOOP
    IF has_function_privilege('anon', r.f, 'EXECUTE') OR has_function_privilege('authenticated', r.f, 'EXECUTE') THEN
      RAISE EXCEPTION 'mig NNN · % quedó con EXECUTE para la API', r.f;
    END IF;
  END LOOP;
  IF (SELECT count(*) FROM pg_trigger
       WHERE (tgname = 'trg_notas_credito_venta_fecha_de_boleta' AND tgrelid = 'public.notas_credito_venta'::regclass)
          OR (tgname = 'trg_pedidos_fecha_arrastra_notas_credito' AND tgrelid = 'public.pedidos'::regclass)) <> 2 THEN
    RAISE EXCEPTION 'mig NNN · faltan los triggers de la fecha de la nota';
  END IF;
END
$post$;

COMMIT;
