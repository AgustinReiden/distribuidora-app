-- 488 · Gastos y personal: topes de fechas y de pagos, el pago de una liquidación anulada y los
-- rubros por clave (#1521, tarjeta 10 del plan #1524). Decisiones del dueño del 10/11.
--
-- QUÉ PASABA Y QUÉ CAMBIA
--   GTO-3 · `vigente_desde` de un arreglo no tenía tope, y un arreglo con la fecha mal no se podía
--           corregir ni borrar. Un «2062» por «2026» dejaba al empleado sin liquidar hasta 2062, y
--           un año de menos ofrecía doce períodos vencidos.
--           · Un arreglo nuevo (el del alta también) vale desde una fecha a no más de 60 días de
--             hoy, para cada lado (`_arreglo_validar_desde`). Corregir el vigente con su misma fecha
--             no pasa por el tope, como antes.
--           · `guardar_arreglo_empleado` con `id` corrige el último arreglo, también su fecha:
--             después del anterior y dentro del tope. Si un período liquidado lo usa, lo frena el
--             trigger `empleado_arreglos_periodo_cerrado`, que ya mira la fecha vieja y la nueva.
--   GTO-4 · El pago que sobrevive a la anulación de su liquidación (su rendición ya estaba
--           cerrada) no se podía revertir: `revertir_movimiento_empleado` contestaba «se revierte
--           anulando la liquidación», que ya estaba anulada. Ahora se revierte como un pago suelto,
--           con la misma regla de la rendición: cerrada, se corrige con un ajuste; reabierta, se
--           revierte.
--   GTO-6 · `_guardar_gasto` aceptaba una fecha futura y cualquier `mes_imputado`. Ahora la fecha
--           no puede ser futura (el reintegro al empleado nace con ella, y la cuenta del empleado
--           no acepta movimientos futuros) y el mes imputado va de 12 meses antes a 1 después del
--           mes de la fecha: el impuesto del mes anterior y la factura atrasada entran, y también
--           el alquiler que se paga adelantado. La rama `origen = 'rendicion'` no se toca (GTO-7,
--           #1522).
--   GTO-8 · Un pago suelto al empleado no tenía tope. Ahora no puede ser más de lo que se le debe
--           (lo de más es un adelanto, como al liquidar), y si sale de una rendición, tampoco más
--           del efectivo que le queda por entregar (`_rendicion_efectivo_a_entregar`, la cuenta del
--           tope de `resolver_rendicion`).
--   GTO-9 · El rubro «Faltantes de caja» se buscaba por nombre, y cualquier admin lo podía
--           renombrar o desactivar. Ahora tiene una clave (`gasto_rubros.clave = 'faltantes_caja'`),
--           `resolver_rendicion` lo busca por ella, y `guardar_rubro_gasto` deja renombrarlo pero
--           no darlo de baja. «Los sueldos no son un gasto» frenaba sólo los nombres que empezaban
--           con «sueldo»: ahora frena una lista de palabras en cualquier parte del nombre, sin
--           tildes ni mayúsculas (`_rubro_es_sueldo`), la misma en el CHECK y en la RPC.
--
-- QUÉ NO CAMBIA
--   Las firmas, los EXECUTE y el SECURITY DEFINER de las funciones que ya existían. De
--   `resolver_rendicion`, sólo la búsqueda del rubro. `liquidar_empleado` no se toca: su pago ya
--   tenía tope contra lo que le toca, y el del efectivo de la rendición queda anotado en el PR.
--   Las tres funciones nuevas son de server: sin EXECUTE para PUBLIC, anon ni authenticated.
--
-- PREMISAS: el md5(prosrc) de cada función que se cambia, leído de prod el 10/11; el CHECK del
-- nombre de los rubros, y un solo rubro «Faltantes de caja».
--
-- Ensayo: scripts/test-gastos-personal-1521.sql. Se aplica en LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas (leídas de prod el 10/11)
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('public.guardar_arreglo_empleado(bigint,jsonb)',         'ea3b7ecf8d47fb47a84ea28ce70b6682'),
      ('public.guardar_empleado(jsonb)',                        'c7c9580e8662c599cd0fbc8f71ba01bd'),
      ('public.registrar_movimiento_empleado(bigint,jsonb)',    '1c51364ac79f2c86041f4204c7b9cb1a'),
      ('public.revertir_movimiento_empleado(bigint,text)',      'aa705a23c175c4be57946358e28131f3'),
      ('public._guardar_gasto(jsonb,boolean)',                  '624620059b3a847f902ec61904e91ffe'),
      ('public.guardar_rubro_gasto(jsonb)',                     '49572ec5cba855cb142236d06bd6332d'),
      ('public.resolver_rendicion(date,uuid,text,jsonb)',       'ecbb9b34771f5a706b6d00446377464d')
    ) AS x(firma, md5)
  LOOP
    IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = r.firma::regprocedure) IS DISTINCT FROM r.md5 THEN
      RAISE EXCEPTION 'mig 488 · % cambió en prod desde que se leyó: rehacer sobre la definición vigente', r.firma;
    END IF;
  END LOOP;

  IF to_regprocedure('public._rubro_es_sueldo(text)') IS NOT NULL
     OR to_regprocedure('public._arreglo_validar_desde(date)') IS NOT NULL
     OR to_regprocedure('public._rendicion_efectivo_a_entregar(bigint,uuid,date)') IS NOT NULL
     OR EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'gasto_rubros' AND column_name = 'clave') THEN
    RAISE EXCEPTION 'mig 488 · ya existe una de las funciones nuevas o gasto_rubros.clave';
  END IF;

  IF (SELECT pg_get_constraintdef(oid) FROM pg_constraint
       WHERE conrelid = 'public.gasto_rubros'::regclass AND conname = 'gasto_rubros_nombre_check')
     IS DISTINCT FROM 'CHECK (((btrim(nombre) <> ''''::text) AND (lower(btrim(nombre)) !~ ''^sueldo''::text)))' THEN
    RAISE EXCEPTION 'mig 488 · gasto_rubros_nombre_check no es el de gastos 1';
  END IF;

  IF (SELECT count(*) FROM gasto_rubros WHERE lower(btrim(nombre)) = 'faltantes de caja') <> 1 THEN
    RAISE EXCEPTION 'mig 488 · se esperaba un solo rubro «Faltantes de caja»';
  END IF;
END
$premisas$;

-- ===========================================================================
-- GTO-9 · los rubros
-- ===========================================================================

-- La lista de lo que es sueldo: una sola, para el CHECK y para guardar_rubro_gasto.
CREATE FUNCTION public._rubro_es_sueldo(p_nombre text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  -- #1521 (GTO-9): los sueldos no son un gasto, salen de las liquidaciones del personal. La
  -- palabra en cualquier parte del nombre, sin tildes ni mayúsculas (decisión del dueño, 10/11).
  -- Las cargas sociales, el sindicato y la ART sí son gasto: no están.
  SELECT translate(lower(COALESCE(p_nombre, '')), 'áéíóúüàèìòù', 'aeiouuaeiou')
         ~ '\m(sueldos?|salarios?|haberes|aguinaldos?|sac|jornal(es)?|vacaciones|horas? extras?|presentismo|indemnizacion(es)?)\M';
$function$;

REVOKE ALL ON FUNCTION public._rubro_es_sueldo(text) FROM PUBLIC, anon, authenticated;

ALTER TABLE public.gasto_rubros DROP CONSTRAINT gasto_rubros_nombre_check;
ALTER TABLE public.gasto_rubros
  ADD CONSTRAINT gasto_rubros_nombre_check CHECK (btrim(nombre) <> '' AND NOT public._rubro_es_sueldo(nombre));

-- La marca de un rubro que usa el sistema. Se busca por ella, no por el nombre.
ALTER TABLE public.gasto_rubros ADD COLUMN clave text;
ALTER TABLE public.gasto_rubros ADD CONSTRAINT gasto_rubros_clave_check CHECK (clave IN ('faltantes_caja'));
CREATE UNIQUE INDEX gasto_rubros_clave_uk ON public.gasto_rubros (clave);
COMMENT ON COLUMN public.gasto_rubros.clave IS
  'Rubro que usa el sistema (#1521). faltantes_caja: el gasto de un robo o pérdida al resolver una rendición (resolver_rendicion). Se puede renombrar, no dar de baja.';

UPDATE public.gasto_rubros SET clave = 'faltantes_caja' WHERE lower(btrim(nombre)) = 'faltantes de caja';

-- guardar_rubro_gasto: la lista de sueldos y el rubro del sistema.
DO $parche_rubro$
DECLARE
  v_def text := pg_get_functiondef('public.guardar_rubro_gasto(jsonb)'::regprocedure);
  v_a1 text := $a$  IF lower(v_nombre) ~ '^sueldo' THEN$a$;
  v_r1 text := $r$  -- #1521 (GTO-9): la lista vive en _rubro_es_sueldo, la misma del CHECK.
  IF public._rubro_es_sueldo(v_nombre) THEN$r$;
  v_a2 text := $a$  IF v_id IS NOT NULL AND v_grupo <> v_viejo.grupo$a$;
  v_r2 text := $r$  -- #1521 (GTO-9): resolver_rendicion busca el rubro de los faltantes por su clave. Se puede
  -- renombrar, pero sin él no se imputa un robo o una pérdida: no se da de baja.
  IF v_id IS NOT NULL AND v_viejo.clave IS NOT NULL AND NOT v_activo THEN
    RAISE EXCEPTION 'El rubro «%» es el de los faltantes de caja de las rendiciones: se le puede cambiar el nombre, pero no darlo de baja',
      v_viejo.nombre;
  END IF;
  IF v_id IS NOT NULL AND v_grupo <> v_viejo.grupo$r$;
  v_n int;
BEGIN
  v_n := (length(v_def) - length(replace(v_def, v_a1, ''))) / length(v_a1);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig 488 · guardar_rubro_gasto: el ancla 1 aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  v_n := (length(v_def) - length(replace(v_def, v_a2, ''))) / length(v_a2);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig 488 · guardar_rubro_gasto: el ancla 2 aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(replace(v_def, v_a1, v_r1), v_a2, v_r2);
END
$parche_rubro$;

-- resolver_rendicion: sólo la búsqueda del rubro.
DO $parche_resolver$
DECLARE
  v_def text := pg_get_functiondef('public.resolver_rendicion(date,uuid,text,jsonb)'::regprocedure);
  v_a text := $a$      SELECT id INTO v_rubro_robo FROM gasto_rubros
       WHERE lower(btrim(nombre)) = 'faltantes de caja' AND activo;
      IF v_rubro_robo IS NULL THEN
        RAISE EXCEPTION 'Falta el rubro «Faltantes de caja»: dalo de alta o reactivalo en Gastos';
      END IF;$a$;
  v_r text := $r$      -- #1521 (GTO-9): por su clave, no por el nombre, que un admin puede cambiar.
      SELECT id INTO v_rubro_robo FROM gasto_rubros
       WHERE clave = 'faltantes_caja' AND activo;
      IF v_rubro_robo IS NULL THEN
        RAISE EXCEPTION 'Falta el rubro de los faltantes de caja (clave faltantes_caja): sin él no se imputa un robo o una pérdida';
      END IF;$r$;
  v_n int;
BEGIN
  v_n := (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig 488 · resolver_rendicion: el ancla aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(v_def, v_a, v_r);
END
$parche_resolver$;

-- ===========================================================================
-- GTO-6 · la fecha y el mes imputado de un gasto
-- ===========================================================================
-- El cuerpo vivo viene en CRLF: las anclas y los reemplazos se escriben en LF y se pasan a CRLF.
DO $parche_gasto$
DECLARE
  v_def text := pg_get_functiondef('public._guardar_gasto(jsonb,boolean)'::regprocedure);
  v_a1 text := replace($a$  IF v_fecha IS NULL THEN
    RAISE EXCEPTION 'Falta la fecha del gasto';
  END IF;$a$, E'\n', E'\r\n');
  v_r1 text := replace($r$  IF v_fecha IS NULL THEN
    RAISE EXCEPTION 'Falta la fecha del gasto';
  END IF;
  -- #1521 (GTO-6): nunca futura. El reintegro al empleado nace con esta fecha, y la cuenta del
  -- empleado no acepta movimientos futuros.
  IF v_fecha > public._tablero_hoy() THEN
    RAISE EXCEPTION 'La fecha del gasto no puede ser futura';
  END IF;$r$, E'\n', E'\r\n');
  v_a2 text := $a$  v_mes := date_trunc('month', COALESCE(v_mes, v_fecha)::timestamp)::date;$a$;
  v_r2 text := replace($r$  v_mes := date_trunc('month', COALESCE(v_mes, v_fecha)::timestamp)::date;
  -- #1521 (GTO-6): de 12 meses antes (el impuesto del mes anterior, una factura atrasada) a 1
  -- después (el alquiler que se paga adelantado) del mes de la fecha.
  IF v_mes < (date_trunc('month', v_fecha::timestamp) - interval '12 months')::date
     OR v_mes > (date_trunc('month', v_fecha::timestamp) + interval '1 month')::date THEN
    RAISE EXCEPTION 'El mes imputado va de 12 meses antes a 1 después del mes de la fecha del gasto';
  END IF;$r$, E'\n', E'\r\n');
  v_n int;
BEGIN
  v_n := (length(v_def) - length(replace(v_def, v_a1, ''))) / length(v_a1);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig 488 · _guardar_gasto: el ancla 1 aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  v_n := (length(v_def) - length(replace(v_def, v_a2, ''))) / length(v_a2);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig 488 · _guardar_gasto: el ancla 2 aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(replace(v_def, v_a1, v_r1), v_a2, v_r2);
END
$parche_gasto$;

-- ===========================================================================
-- GTO-3 · el tope y la corrección de un arreglo
-- ===========================================================================
CREATE FUNCTION public._arreglo_validar_desde(p_desde date)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
-- #1521 (GTO-3): un arreglo vale desde una fecha a no más de 60 días de hoy, para cada lado
-- (decisión del dueño, 10/11). La usan el alta (guardar_empleado) y guardar_arreglo_empleado. El
-- espejo del front es topeDeArreglo (src/utils/personal.ts), con el mismo mensaje.
DECLARE
  v_hoy date := public._tablero_hoy();
BEGIN
  IF p_desde < v_hoy - 60 OR p_desde > v_hoy + 60 THEN
    RAISE EXCEPTION 'El arreglo vale desde una fecha entre el % y el % (hasta 60 días antes o después de hoy)',
      to_char(v_hoy - 60, 'DD/MM/YYYY'), to_char(v_hoy + 60, 'DD/MM/YYYY');
  END IF;
END
$function$;

REVOKE ALL ON FUNCTION public._arreglo_validar_desde(date) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.guardar_arreglo_empleado(p_empleado_id bigint, p_arreglo jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid     uuid := auth.uid();
  v_e       empleados%ROWTYPE;
  v_corrige bigint;
  v_desde   date;
  v_sueldo  numeric;
  v_frec    text;
  v_comis   boolean;
  v_ultimo  empleado_arreglos%ROWTYPE;
  v_previo  date;
  v_id      bigint;
BEGIN
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin ve y carga el personal' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_e FROM empleados WHERE id = p_empleado_id FOR UPDATE;
  IF NOT FOUND OR NOT public._empleado_visible(v_e.sucursal_id, v_e.de_las_dos) THEN
    RAISE EXCEPTION 'Ese empleado no existe o no lo podés ver';
  END IF;
  IF v_e.usuario_id = v_uid THEN
    RAISE EXCEPTION 'Tu propia cuenta la maneja otro admin: no podés cambiar tu arreglo, tu usuario ni tus movimientos';
  END IF;
  IF NOT v_e.activo THEN
    RAISE EXCEPTION 'Ese empleado está dado de baja: reactivalo para cambiarle el arreglo';
  END IF;
  BEGIN
    IF jsonb_typeof(p_arreglo) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'formato';
    END IF;
    v_corrige := NULLIF(p_arreglo->>'id', '')::bigint;
    v_desde  := NULLIF(p_arreglo->>'vigente_desde', '')::date;
    v_sueldo := round(NULLIF(p_arreglo->>'sueldo', '')::numeric, 2);
    v_frec   := NULLIF(btrim(p_arreglo->>'frecuencia'), '');
    v_comis  := COALESCE((p_arreglo->>'comisiona')::boolean, false);
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Hay un dato del empleado con un formato inválido';
  END;
  IF 'NaN'::numeric = v_sueldo OR abs(v_sueldo) > 9999999999.99 THEN
    RAISE EXCEPTION 'Hay un dato del empleado con un formato inválido';
  END IF;
  IF v_desde IS NULL OR v_sueldo IS NULL OR v_frec IS NULL THEN
    RAISE EXCEPTION 'Falta el primer arreglo: el sueldo, cada cuánto y desde cuándo se liquida';
  END IF;
  IF v_sueldo < 0 THEN
    RAISE EXCEPTION 'El sueldo no puede ser negativo';
  END IF;
  IF v_frec NOT IN ('semanal', 'mensual') THEN
    RAISE EXCEPTION 'El sueldo es semanal o mensual';
  END IF;
  IF v_sueldo = 0 AND NOT v_comis THEN
    RAISE EXCEPTION 'Un arreglo sin sueldo fijo tiene que comisionar';
  END IF;

  SELECT * INTO v_ultimo FROM empleado_arreglos WHERE empleado_id = v_e.id ORDER BY vigente_desde DESC LIMIT 1;

  -- #1521 (GTO-3): con id se corrige el último arreglo, también su fecha: después del anterior y
  -- dentro del tope. Si un período liquidado lo usa, lo frena empleado_arreglos_periodo_cerrado,
  -- que mira la fecha vieja y la nueva.
  IF v_corrige IS NOT NULL THEN
    IF v_ultimo.id IS DISTINCT FROM v_corrige THEN
      RAISE EXCEPTION 'Sólo se corrige el último arreglo del empleado';
    END IF;
    IF v_desde <> v_ultimo.vigente_desde THEN
      SELECT max(a.vigente_desde) INTO v_previo FROM empleado_arreglos a
       WHERE a.empleado_id = v_e.id AND a.id <> v_ultimo.id;
      IF v_desde <= v_previo THEN
        RAISE EXCEPTION 'El arreglo corregido vale desde después del anterior (%)', to_char(v_previo, 'DD/MM/YYYY');
      END IF;
      PERFORM public._arreglo_validar_desde(v_desde);
    END IF;
    UPDATE empleado_arreglos
       SET vigente_desde = v_desde, sueldo = v_sueldo, frecuencia = v_frec, comisiona = v_comis, updated_at = now()
     WHERE id = v_ultimo.id;
    RETURN v_ultimo.id;
  END IF;

  IF v_ultimo.id IS NOT NULL AND v_desde < v_ultimo.vigente_desde THEN
    RAISE EXCEPTION 'Un arreglo nuevo vale desde después del vigente (%): para cambiarle la fecha al vigente, elegí «Corregir el vigente»',
      to_char(v_ultimo.vigente_desde, 'DD/MM/YYYY');
  END IF;
  -- Con la misma fecha corrige el vigente, como antes: no pasa por el tope.
  IF v_ultimo.id IS NOT NULL AND v_desde = v_ultimo.vigente_desde THEN
    UPDATE empleado_arreglos
       SET sueldo = v_sueldo, frecuencia = v_frec, comisiona = v_comis, updated_at = now()
     WHERE id = v_ultimo.id;
    RETURN v_ultimo.id;
  END IF;
  PERFORM public._arreglo_validar_desde(v_desde);
  INSERT INTO empleado_arreglos (empleado_id, vigente_desde, sueldo, frecuencia, comisiona, creado_por)
  VALUES (v_e.id, v_desde, v_sueldo, v_frec, v_comis, v_uid)
  RETURNING id INTO v_id;
  RETURN v_id;
END
$function$;

-- guardar_empleado: el primer arreglo del alta, con el mismo tope. Cuerpo vivo en CRLF.
DO $parche_alta$
DECLARE
  v_def text := pg_get_functiondef('public.guardar_empleado(jsonb)'::regprocedure);
  v_a text := $a$  INSERT INTO empleados (sucursal_id, de_las_dos, nombre, puesto, cuil, fecha_ingreso, telefono,$a$;
  v_r text := replace($r$  -- #1521 (GTO-3): el mismo tope que guardar_arreglo_empleado.
  PERFORM public._arreglo_validar_desde(v_desde);

  INSERT INTO empleados (sucursal_id, de_las_dos, nombre, puesto, cuil, fecha_ingreso, telefono,$r$, E'\n', E'\r\n');
  v_n int;
BEGIN
  v_n := (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig 488 · guardar_empleado: el ancla aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(v_def, v_a, v_r);
END
$parche_alta$;

-- ===========================================================================
-- GTO-8 · el tope del pago suelto
-- ===========================================================================
CREATE FUNCTION public._rendicion_efectivo_a_entregar(p_sucursal_id bigint, p_transportista_id uuid, p_fecha date)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  -- #1521 (GTO-8): el efectivo que le queda por entregar a una rendición. Es la cuenta del tope de
  -- resolver_rendicion (paso 9) y del front: lo cobrado en efectivo, menos los gastos de la
  -- rendición, menos los pagos al personal y los faltantes a cargo de empleados (que ya van
  -- negativos).
  SELECT COALESCE((SELECT sum(x.monto) FROM public._rendicion_pagos(p_sucursal_id, p_fecha, p_fecha) x
                    WHERE x.t_id = p_transportista_id AND x.forma_pago = 'efectivo'), 0)
       - COALESCE((SELECT sum(g.monto_total) FROM gastos g
                    WHERE g.origen_pago = 'rendicion' AND g.anulado_at IS NULL
                      AND g.sucursal_id = p_sucursal_id
                      AND g.rendicion_transportista_id = p_transportista_id
                      AND g.rendicion_fecha = p_fecha), 0)
       + COALESCE((SELECT sum(m.monto) FROM empleado_movimientos m
                    WHERE m.rendicion_sucursal_id = p_sucursal_id
                      AND m.rendicion_transportista_id = p_transportista_id
                      AND m.rendicion_fecha = p_fecha
                      AND m.tipo IN ('pago', 'faltante')), 0);
$function$;

REVOKE ALL ON FUNCTION public._rendicion_efectivo_a_entregar(bigint, uuid, date) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.registrar_movimiento_empleado(p_empleado_id bigint, p_movimiento jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_e     empleados%ROWTYPE;
  v_tipo  text;
  v_monto numeric;
  v_fecha date;
  v_obs   text;
  v_id    bigint;
  v_rt    uuid;
  v_rf    date;
  v_rs    bigint;
  v_saldo numeric;
BEGIN
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin ve y carga el personal' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_e FROM empleados WHERE id = p_empleado_id FOR UPDATE;
  IF NOT FOUND OR NOT public._empleado_visible(v_e.sucursal_id, v_e.de_las_dos) THEN
    RAISE EXCEPTION 'Ese empleado no existe o no lo podés ver';
  END IF;
  IF v_e.usuario_id = auth.uid() THEN
    IF p_movimiento->>'tipo' = 'pago' THEN
      RAISE EXCEPTION 'Tu propia cuenta la maneja otro admin: no podés liquidarte ni registrarte pagos';
    END IF;
    RAISE EXCEPTION 'Tu propia cuenta la maneja otro admin: no podés cambiar tu arreglo, tu usuario ni tus movimientos';
  END IF;
  BEGIN
    IF jsonb_typeof(p_movimiento) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'formato';
    END IF;
    v_tipo  := NULLIF(btrim(p_movimiento->>'tipo'), '');
    v_monto := round(NULLIF(p_movimiento->>'monto', '')::numeric, 2);
    v_fecha := COALESCE(NULLIF(p_movimiento->>'fecha', '')::date, public._tablero_hoy());
    v_obs   := NULLIF(btrim(p_movimiento->>'observacion'), '');
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Hay un dato del empleado con un formato inválido';
  END;
  IF 'NaN'::numeric = v_monto OR abs(v_monto) > 9999999999.99 THEN
    RAISE EXCEPTION 'Hay un dato del empleado con un formato inválido';
  END IF;
  IF v_tipo IS NULL OR v_tipo NOT IN ('adelanto', 'ajuste', 'pago') THEN
    RAISE EXCEPTION 'Un movimiento a mano es un adelanto en efectivo, un pago o un ajuste';
  END IF;
  IF v_tipo IN ('adelanto', 'pago') THEN
    IF v_monto IS NULL OR v_monto <= 0 THEN
      RAISE EXCEPTION 'El monto tiene que ser mayor a cero';
    END IF;
    v_monto := -v_monto;
  ELSE
    IF v_monto IS NULL OR v_monto = 0 THEN
      RAISE EXCEPTION 'El ajuste no puede ser cero';
    END IF;
    IF v_obs IS NULL THEN
      RAISE EXCEPTION 'El ajuste necesita una observación que diga por qué';
    END IF;
  END IF;
  IF v_tipo = 'pago' THEN
    SELECT r.transportista_id, r.fecha, r.sucursal_id INTO v_rt, v_rf, v_rs
      FROM public._pago_de_rendicion(p_movimiento) r;
    v_fecha := COALESCE(v_rf, v_fecha);
  END IF;
  IF v_fecha > public._tablero_hoy() THEN
    RAISE EXCEPTION 'La fecha del movimiento no puede ser futura';
  END IF;
  -- #1521 (GTO-8): el pago salda lo que se le debe, nunca más: lo de más es un adelanto, como al
  -- liquidar. Y de una rendición no sale más efectivo del que le queda por entregar. El saldo se
  -- lee con el empleado bloqueado, y el efectivo con la rendición bloqueada (_pago_de_rendicion):
  -- otro pago al mismo empleado, o un gasto o un pago de la misma rendición, espera.
  IF v_tipo = 'pago' THEN
    SELECT COALESCE(sum(m.monto), 0) INTO v_saldo FROM empleado_movimientos m WHERE m.empleado_id = v_e.id;
    IF -v_monto > GREATEST(v_saldo, 0) THEN
      RAISE EXCEPTION 'No se le puede pagar más de lo que se le debe: si le adelantás plata, cargá un adelanto';
    END IF;
    IF v_rf IS NOT NULL AND -v_monto > public._rendicion_efectivo_a_entregar(v_rs, v_rt, v_rf) THEN
      RAISE EXCEPTION 'El pago supera el efectivo que le queda por entregar a esa rendición';
    END IF;
  END IF;
  INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, observacion, creado_por,
                                    rendicion_transportista_id, rendicion_fecha, rendicion_sucursal_id)
  VALUES (v_e.id, v_fecha, v_tipo, v_monto, v_obs, auth.uid(), v_rt, v_rf, v_rs)
  RETURNING id INTO v_id;
  RETURN v_id;
END
$function$;

-- ===========================================================================
-- GTO-4 · el pago que sobrevivió a la anulación de su liquidación
-- ===========================================================================
DO $parche_revertir$
DECLARE
  v_def text := pg_get_functiondef('public.revertir_movimiento_empleado(bigint,text)'::regprocedure);
  v_a text := $a$  IF v_m.tipo = 'pago' AND v_m.liquidacion_id IS NOT NULL THEN
    RAISE EXCEPTION 'Un pago de una liquidación se revierte anulando la liquidación';
  END IF;$a$;
  v_r text := $r$  -- #1521 (GTO-4): el pago que sobrevivió a la anulación de su liquidación (su rendición ya
  -- estaba cerrada) queda como un pago suelto, y se revierte como uno: más abajo, con la regla de
  -- la rendición. Con el empleado bloqueado, nadie anula la liquidación en el medio.
  IF v_m.tipo = 'pago' AND v_m.liquidacion_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM empleado_liquidaciones l
                  WHERE l.id = v_m.liquidacion_id AND l.anulada_at IS NULL) THEN
    RAISE EXCEPTION 'Un pago de una liquidación se revierte anulando la liquidación';
  END IF;$r$;
  v_n int;
BEGIN
  v_n := (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig 488 · revertir_movimiento_empleado: el ancla aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(v_def, v_a, v_r);
END
$parche_revertir$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, el definer y los EXECUTE quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  v_acl_rpc    constant text := '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}';
  v_acl_server constant text := '{postgres=X/postgres,service_role=X/postgres}';
BEGIN
  FOR r IN
    SELECT x.*, p.oid IS NOT NULL AS existe, md5(p.prosrc) AS h, p.proacl::text AS a, p.prosecdef AS d
      FROM (VALUES
        ('public.guardar_arreglo_empleado(bigint,jsonb)',              '534a3dc658839de8bc6a60941581e5c8', true),
        ('public.guardar_empleado(jsonb)',                             '3765d0525746dbee35083f05d7da631b', true),
        ('public.registrar_movimiento_empleado(bigint,jsonb)',         '1f86518d3219e900d71f0896aba69ad3', true),
        ('public.revertir_movimiento_empleado(bigint,text)',           '55f7de0f87a071341e2427a4c3273e0f', true),
        ('public._guardar_gasto(jsonb,boolean)',                       '74d9dad6ee948932b1ca92f78f60fbdc', true),
        ('public.guardar_rubro_gasto(jsonb)',                          'e8a9f72d4a00c01b727985f2bdfae3e1', true),
        ('public.resolver_rendicion(date,uuid,text,jsonb)',            '0f1d4243fdcb8b73a6ae1690fcac74f0', true),
        ('public._rubro_es_sueldo(text)',                              '333dda97f56c265ce54f2c8e7ca6a8be', false),
        ('public._arreglo_validar_desde(date)',                        'f57803ffd178f8181723d3c1a9c25742', false),
        ('public._rendicion_efectivo_a_entregar(bigint,uuid,date)',    '6aeb1b4da9e512527439e57d06643d5d', false)
      ) AS x(firma, md5, definer)
      LEFT JOIN pg_proc p ON p.oid = to_regprocedure(x.firma)
  LOOP
    IF NOT r.existe OR r.h IS DISTINCT FROM r.md5 OR r.d IS DISTINCT FROM r.definer
       OR r.a IS DISTINCT FROM (CASE WHEN r.firma IN ('public._guardar_gasto(jsonb,boolean)', 'public._rubro_es_sueldo(text)',
                                                      'public._arreglo_validar_desde(date)',
                                                      'public._rendicion_efectivo_a_entregar(bigint,uuid,date)')
                                     THEN v_acl_server ELSE v_acl_rpc END) THEN
      RAISE EXCEPTION '% no quedó como en el repo (md5 %, acl %, definer %)', r.firma, r.h, r.a, r.d;
    END IF;
  END LOOP;

  IF (SELECT count(*) FROM gasto_rubros WHERE clave = 'faltantes_caja') <> 1 THEN
    RAISE EXCEPTION 'mig 488 · el rubro de los faltantes de caja no quedó marcado';
  END IF;
END
$post$;

COMMIT;
