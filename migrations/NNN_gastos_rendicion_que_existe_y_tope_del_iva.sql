-- =========================================================================
-- NNN · GASTOS: LA FECHA DE UNA RENDICIÓN QUE NO EXISTE TIENE PISO, Y EL IVA
--       DE UNA FACTURA A O M TIENE TOPE
--       (reauditoría completa del 12/11: GTO-1 y GTO-2 de #1562)
--
-- Crea dos helpers de server, reescribe `_fecha_carga_validar_piso` para que
-- el piso viva en un solo lugar, y parcha por ancla `_guardar_gasto` y
-- `_pago_de_rendicion`, con premisa de md5 sobre el cuerpo vivo (el de la
-- 490) y poscondición de md5 y ACL.
-- Ensayos: scripts/test-arrastre-nc-y-piso-de-fecha-1542-1545.sql (suma los
-- casos de la rendición que no existe) y scripts/test-gastos-rendicion-e-iva-1562.sql.
-- Se aplica en LF.
--
-- =========================================================================
-- 1 · GTO-1 · LA RENDICIÓN QUE NO EXISTE
-- =========================================================================
-- La 490 (#1545) le puso un piso de 60 días a la fecha de un gasto, de un
-- movimiento de empleado y del pago de una liquidación, y dejó exenta la
-- fecha que sale de una rendición: no se tipea. Pero nada comprobaba que esa
-- rendición existiera. Con origen «Una rendición» y cualquier chofer de la
-- sucursal, un encargado cargaba un gasto fechado en 2016, que caía en la
-- posición fiscal de noviembre de 2016. Lo mismo el pago de una liquidación o
-- un pago suelto que «sale» de una rendición (`_pago_de_rendicion`).
--
-- Ahora la fecha de una rendición queda exenta sólo si la rendición existe:
--   · hay cobros de ese chofer ese día en esa sucursal, con el día y el dueño
--     de cada cobro como los cuenta `_rendicion_pagos` (el pago de un día ya
--     cerrado va al siguiente; el del saldo a favor es de quien lo cobró), o
--   · hay una fila en `rendiciones_control` para ese chofer, ese día y esa
--     sucursal.
-- La regla es una, `_fecha_rendicion_validar_piso`. Leer `_rendicion_pagos`
-- de un día cuesta (~0,6 s en prod el 12/11), así que se pregunta sólo cuando
-- la fecha cae debajo del piso: en el caso normal no se lee nada. Para eso el
-- piso pasa a `_fecha_carga_piso()`, que usan las dos.
--
-- La llaman `_guardar_gasto` (el gasto de una rendición fechado el día de esa
-- rendición) y `_pago_de_rendicion`, que es por donde pasan el pago suelto
-- (`registrar_movimiento_empleado`) y el de una liquidación
-- (`liquidar_empleado`): esas dos siguen sin piso propio para la fecha de la
-- rendición, y ahora el piso se lo pone `_pago_de_rendicion`.
--
-- En prod no hay nada que reparar: 0 gastos, 0 movimientos de empleado con
-- rendición y 0 liquidaciones (leído el 12/11).
--
-- =========================================================================
-- 2 · GTO-2 · EL IVA DE UNA FACTURA A O M
-- =========================================================================
-- `_guardar_gasto` sólo pedía que el neto (total − IVA − percepciones − otros)
-- fuera mayor a cero. Sobre un total de 1.210 entraban IVA de 500, 999 y
-- 999,99, y `posicion_fiscal` los sumaba como crédito fiscal. Una factura con
-- dos alícuotas es legal, así que no se fija el IVA exacto: el tope es el de
-- la alícuota más alta, `IVA ≤ (total − percepciones − otros) × 27/127` (el
-- 27 % del neto), al centavo. Espejo: `errorDeDesglose` (src/utils/gastos.ts).
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
-- Premisa: los cuerpos vivos son los de la 490, y los helpers no existen
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public._guardar_gasto(jsonb,boolean)',          '093729c4cdcb0fcedc148ecdaeb2e4b3'),
    ('public._pago_de_rendicion(jsonb)',              '197ce02d2dcd1ca0fa9942cc84788534'),
    ('public._fecha_carga_validar_piso(date,text)',   '5ebf1dc12c2c1b4b2875aebb9692a74a')
  ) AS t(f, h) LOOP
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió en prod desde que se leyó (md5 %): rehacer sobre la definición vigente', r.f, v;
    END IF;
  END LOOP;

  IF to_regprocedure('public._fecha_carga_piso()') IS NOT NULL
     OR to_regprocedure('public._fecha_rendicion_validar_piso(date,uuid,bigint,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · un helper ya existe: revisar a mano';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 1 · GTO-1 · el piso en un solo lugar, y la rendición que existe
-- ---------------------------------------------------------------------------
CREATE FUNCTION public._fecha_carga_piso()
 RETURNS date
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  -- #1545 (GTO-A): el primer día que se puede cargar, 60 días antes de hoy (el día argentino).
  -- Lo usan _fecha_carga_validar_piso y _fecha_rendicion_validar_piso. Espejo: pisoDeFechaDeCarga
  -- (src/utils/personal.ts).
  SELECT public._tablero_hoy() - 60;
$function$;

REVOKE ALL ON FUNCTION public._fecha_carga_piso() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._fecha_carga_validar_piso(p_fecha date, p_de_que text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
-- #1545 (GTO-A): la fecha de un gasto, de un movimiento de empleado y del pago de una liquidación
-- va hasta 60 días antes de hoy, el día argentino (decisión del dueño, 12/11), para todos. Un año
-- mal tipeado dejaba el gasto fuera de los meses corrientes. `p_de_que` completa el mensaje («del
-- gasto», «del movimiento», «del pago»). El espejo del front es errorDeFechaVieja
-- (src/utils/personal.ts), con el mismo mensaje. #1562: el piso es _fecha_carga_piso.
DECLARE
  v_piso date := public._fecha_carga_piso();
BEGIN
  IF p_fecha < v_piso THEN
    RAISE EXCEPTION 'La fecha % no puede ser anterior al % (hasta 60 días antes de hoy)',
      p_de_que, to_char(v_piso, 'DD/MM/YYYY');
  END IF;
END
$function$;

CREATE FUNCTION public._fecha_rendicion_validar_piso(p_fecha date, p_transportista uuid, p_sucursal bigint, p_de_que text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
-- #1562 (GTO-1): la fecha que sale de una rendición (el gasto de una rendición fechado el día de
-- esa rendición, el pago al personal que sale de ella) no se tipea y no tiene piso, pero sólo si la
-- rendición existe: hay cobros de ese chofer ese día en esa sucursal, contados como los cuenta
-- _rendicion_pagos (su día y su dueño), o hay una fila en rendiciones_control. Si no, la fecha la
-- eligió quien la carga, y rige el piso de siempre (_fecha_carga_validar_piso).
-- Leer _rendicion_pagos de un día cuesta: se pregunta sólo cuando la fecha cae debajo del piso.
BEGIN
  IF p_fecha >= public._fecha_carga_piso() THEN
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM rendiciones_control rc
              WHERE rc.fecha = p_fecha
                AND rc.transportista_id = p_transportista
                AND rc.sucursal_id = p_sucursal)
     OR EXISTS (SELECT 1 FROM public._rendicion_pagos(p_sucursal, p_fecha, p_fecha) x
                 WHERE x.t_id = p_transportista) THEN
    RETURN;
  END IF;
  PERFORM public._fecha_carga_validar_piso(p_fecha, p_de_que);
END
$function$;

REVOKE ALL ON FUNCTION public._fecha_rendicion_validar_piso(date, uuid, bigint, text) FROM PUBLIC, anon, authenticated;

-- _guardar_gasto: el piso del gasto de una rendición (GTO-1) y el tope del IVA (GTO-2). El cuerpo
-- vivo viene en CRLF: las anclas y los reemplazos se escriben en LF y se pasan a CRLF.
DO $parche_gasto$
DECLARE
  v_def text := pg_get_functiondef('public._guardar_gasto(jsonb,boolean)'::regprocedure);
  v_a1 text := replace($a$  -- #1545 (GTO-A): ni anterior a 60 días. Rige al cargar y al cambiar la fecha: un gasto viejo se
  -- sigue pudiendo corregir sin tocarla. La fecha de un gasto de una rendición que es el día de
  -- esa rendición no se tipea, y no tiene piso.
  IF (v_id IS NULL OR v_viejo.fecha IS DISTINCT FROM v_fecha)
     AND NOT (v_origen = 'rendicion' AND v_rend_f IS NOT NULL AND v_fecha = v_rend_f) THEN
    PERFORM public._fecha_carga_validar_piso(v_fecha, 'del gasto');
  END IF;$a$, E'\n', E'\r\n');
  v_r1 text := replace($r$  -- #1545 (GTO-A): ni anterior a 60 días. Rige al cargar y al cambiar la fecha: un gasto viejo se
  -- sigue pudiendo corregir sin tocarla. La fecha de un gasto de una rendición que es el día de
  -- esa rendición no se tipea, y no tiene piso, pero sólo si esa rendición existe (#1562, GTO-1):
  -- si no, el día lo eligió quien carga el gasto.
  IF v_id IS NULL OR v_viejo.fecha IS DISTINCT FROM v_fecha THEN
    IF v_origen = 'rendicion' AND v_rend_tr IS NOT NULL AND v_fecha = v_rend_f THEN
      PERFORM public._fecha_rendicion_validar_piso(v_fecha, v_rend_tr, v_suc, 'del gasto');
    ELSE
      PERFORM public._fecha_carga_validar_piso(v_fecha, 'del gasto');
    END IF;
  END IF;$r$, E'\n', E'\r\n');
  v_a2 text := replace($a$    IF v_total - v_iva - v_piva - v_piibb - v_otros <= 0 THEN
      RAISE EXCEPTION 'Con factura A o M el neto tiene que ser mayor a cero';
    END IF;$a$, E'\n', E'\r\n');
  v_r2 text := replace($r$    IF v_total - v_iva - v_piva - v_piibb - v_otros <= 0 THEN
      RAISE EXCEPTION 'Con factura A o M el neto tiene que ser mayor a cero';
    END IF;
    -- #1562 (GTO-2): el IVA no pasa del de la alícuota más alta. Una factura con dos alícuotas es
    -- legal, así que no se fija el IVA exacto: el tope es (total − percepciones − otros) × 27/127,
    -- el 27 % del neto, al centavo.
    IF v_iva > round((v_total - v_piva - v_piibb - v_otros) * 27 / 127, 2) THEN
      RAISE EXCEPTION 'El IVA no puede pasar del 27 %% del neto: revisá el IVA y las percepciones';
    END IF;$r$, E'\n', E'\r\n');
  v_n int;
BEGIN
  v_n := (length(v_def) - length(replace(v_def, v_a1, ''))) / length(v_a1);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · _guardar_gasto: el ancla del piso aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  v_n := (length(v_def) - length(replace(v_def, v_a2, ''))) / length(v_a2);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · _guardar_gasto: el ancla del neto aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(replace(v_def, v_a1, v_r1), v_a2, v_r2);
END
$parche_gasto$;

-- _pago_de_rendicion: el pago suelto y el de una liquidación llevan el día de la rendición, que
-- tiene piso si la rendición no existe. El cuerpo vivo viene en CRLF. Va después de bloquear la
-- rendición y de ver que no está cerrada.
DO $parche_pago$
DECLARE
  v_def text := pg_get_functiondef('public._pago_de_rendicion(jsonb)'::regprocedure);
  v_a text := replace($a$  IF public.control_rendicion_cerrado(v_t, v_suc, v_f) THEN
    RAISE EXCEPTION 'Esa rendición ya está cerrada: pagá con la oficina o elegí otra';
  END IF;$a$, E'\n', E'\r\n');
  v_r text := replace($r$  IF public.control_rendicion_cerrado(v_t, v_suc, v_f) THEN
    RAISE EXCEPTION 'Esa rendición ya está cerrada: pagá con la oficina o elegí otra';
  END IF;
  -- #1562 (GTO-1): el pago lleva el día de la rendición, que no se tipea y por eso quienes llaman
  -- (registrar_movimiento_empleado, liquidar_empleado) no le ponen piso. Pero sólo si la rendición
  -- existe: si no, el día lo eligió quien carga el pago.
  PERFORM public._fecha_rendicion_validar_piso(v_f, v_t, v_suc, 'del pago');$r$, E'\n', E'\r\n');
  v_n int;
BEGIN
  v_n := (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · _pago_de_rendicion: el ancla aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(v_def, v_a, v_r);
END
$parche_pago$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, el definer y los EXECUTE quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public._fecha_carga_piso()', '27023a47f51666d5c07eabd281ea4284', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._fecha_carga_validar_piso(date,text)', '294d00e4f350b32ce2b0b9f4e1b9194a', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._fecha_rendicion_validar_piso(date,uuid,bigint,text)', 'c794bf5f856edfc754f5e3e86371fb5a', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._guardar_gasto(jsonb,boolean)', 'd717ba627ebc1ca023c7200f56fa945a', true,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._pago_de_rendicion(jsonb)', '85f28ae4d70f4708b02c55392917c479', false,
     '{postgres=X/postgres,service_role=X/postgres}')
  ) AS t(f, h, def, acl) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO x
      FROM pg_proc WHERE oid = r.f::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %)', r.f, x.h, x.a, x.def;
    END IF;
  END LOOP;
END
$post$;

COMMIT;
