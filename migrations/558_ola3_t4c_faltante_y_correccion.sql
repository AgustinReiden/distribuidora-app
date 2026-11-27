-- =========================================================================
-- NNN · T4c · LO QUE PAGA EL CLIENTE CONTRA UN FALTANTE, Y CORREGIR UN COBRO EN LA RENDICIÓN
-- (ola 3 de #1603, tanda T4; #1710, D8 de #1690)
--
-- Tercera de tres (ver la T4a). Pide la T4b aplicada. Ensayo: scripts/test-ola3-t4-cobro-de-quien.sql.
-- Se aplica en LF.
--
-- 1 · corregir_cobro_rendicion: corrige la forma de pago (admin; el encargado, en una rendición
--     abierta que no es de un encargado ni de un admin) y quién cobró (admin), con motivo, en una
--     rendición abierta o en disconformidad (sólo admin). Un cobro que vive en el día siguiente a un
--     día cerrado no se pasa a otro. Deja la marca en las notas del pago y en el historial del
--     pedido, y audit_pagos guarda el antes y el después.
-- 2 · cobrar_faltante_rendicion: lo que el cliente paga después contra el faltante que se le cargó
--     a un empleado (sólo admin, que maneja el personal). No es un cobro: la boleta ya figura
--     cobrada. Le baja la deuda al empleado (un movimiento positivo con recupera_faltante_id) y, en
--     efectivo, entra en la caja de hoy de quien lo recibió (un 'faltante' positivo en su rendición,
--     que suma al efectivo a entregar). Por otra forma, un ajuste sin rendición. Clave en
--     altas_por_clave ('cobro_faltante'). anular_cobro_faltante lo deshace mientras esa caja esté
--     abierta, y deshacer la resolución del chofer con algo cobrado contra su faltante se rechaza.
-- 3 · obtener_faltantes_rendiciones devuelve lo recuperado de cada línea.
-- 4 · FALT-B de auditoria_integridad() no cuenta lo que pagó el cliente contra un faltante
--     (recupera_faltante_id): no tiene línea propia. Parcheado por ancla, como la 548.
--
-- PREMISAS: la T4b, los cuerpos de obtener_faltantes_rendiciones y auditoria_integridad (md5), y
-- los CHECK vigentes de altas_por_clave y empleado_movimientos_faltante_negativo.
--
-- Revertir (si no hay cobros contra faltantes): las dos funciones a sus cuerpos, DROP de las
-- funciones y el trigger nuevos, DROP COLUMN empleado_movimientos.recupera_faltante_id con sus
-- CHECK, y los CHECK de antes de altas_por_clave y de empleado_movimientos_faltante_negativo.
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

LOCK TABLE public.empleado_movimientos, public.altas_por_clave, public.rendicion_faltantes IN SHARE ROW EXCLUSIVE MODE NOWAIT;

DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.obtener_faltantes_rendiciones(date,date,uuid)', 'febc22280482b1420e9d36104420071c'),
    ('public.auditoria_integridad()', 'c7dfa8d33ffc4b70a26a0ce1122d4eee')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;

  -- La T4b: las RPCs de cobro con quién cobró.
  IF to_regprocedure('public.registrar_pagos_pedido_impl(bigint,jsonb,date,text,text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'mig NNN · falta la T4b (las RPCs de cobro con p_cobrado_por): aplicarla antes';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.empleado_movimientos'::regclass
               AND attname = 'recupera_faltante_id') THEN
    RAISE EXCEPTION 'mig NNN · empleado_movimientos.recupera_faltante_id ya existe';
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
    IF EXISTS (SELECT 1 FROM perfiles pe WHERE pe.id = v_r.t_id AND pe.rol IN ('encargado', 'admin')) THEN
      RAISE EXCEPTION 'La rendición de un encargado o de un admin la corrige un admin' USING ERRCODE = '42501';
    END IF;
  END IF;
  -- Un cobro que vive en el día siguiente a un día cerrado (#1328) no se pasa a otro: iría al día
  -- de su fecha del otro, uno viejo.
  IF v_nuevo IS DISTINCT FROM v_r.t_id AND v_r.f IS DISTINCT FROM v_pg.fecha THEN
    RAISE EXCEPTION 'Ese cobro está en la rendición del % porque su día (%) ya estaba cerrado: para pasárselo a otro, reabrí ese día',
      to_char(v_r.f, 'DD/MM/YYYY'), to_char(v_pg.fecha, 'DD/MM/YYYY') USING ERRCODE = '22023';
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

-- obtener_faltantes_rendiciones
DO $t4$
DECLARE
  v text := pg_get_functiondef('public.obtener_faltantes_rendiciones(date,date,uuid)'::regprocedure);
BEGIN
  v := pg_temp.t4_parche(v, $o$           'creado_por_nombre', pf.nombre, 'created_at', f.created_at)$o$,
    $n$           'creado_por_nombre', pf.nombre, 'created_at', f.created_at,
           -- T4 (#1710): lo que el cliente ya pagó contra esta línea (descuenta el faltante).
           'recuperado', public._faltante_recuperado(f.id))$n$, 1);
  EXECUTE v;
END
$t4$;
-- auditoria_integridad
DO $t4$
DECLARE
  v text := pg_get_functiondef('public.auditoria_integridad()'::regprocedure);
BEGIN
  v := pg_temp.t4_parche(v, $o$    ('FALT-B','high','movimientos «faltante» que ninguna línea de faltante nombra (#1426)',
      (SELECT count(*) FROM empleado_movimientos m
        WHERE m.tipo = 'faltante' AND m.revierte_id IS NULL
          AND NOT EXISTS$o$,
    $n$    -- T4 (#1710): lo que el cliente pagó después contra un faltante (recupera_faltante_id) es un
    -- faltante positivo en la caja de quien lo recibió, sin línea propia.
    ('FALT-B','high','movimientos «faltante» que ninguna línea de faltante nombra (#1426)',
      (SELECT count(*) FROM empleado_movimientos m
        WHERE m.tipo = 'faltante' AND m.revierte_id IS NULL AND m.recupera_faltante_id IS NULL
          AND NOT EXISTS$n$, 1);
  EXECUTE v;
END
$t4$;

-- -------------------------------------------------------------------------
-- Poscondiciones
-- -------------------------------------------------------------------------
DO $pos$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc p
              WHERE p.pronamespace = 'public'::regnamespace
                AND p.proname IN ('_faltante_recuperado', 'rendicion_faltantes_guarda_recupero')
                AND (has_function_privilege('anon', p.oid, 'EXECUTE')
                     OR has_function_privilege('authenticated', p.oid, 'EXECUTE')))
     OR EXISTS (SELECT 1 FROM pg_proc p
                 WHERE p.pronamespace = 'public'::regnamespace
                   AND p.proname IN ('corregir_cobro_rendicion', 'cobrar_faltante_rendicion', 'anular_cobro_faltante')
                   AND (has_function_privilege('anon', p.oid, 'EXECUTE')
                        OR NOT has_function_privilege('authenticated', p.oid, 'EXECUTE'))) THEN
    RAISE EXCEPTION 'mig NNN · poscondición: los EXECUTE de las funciones nuevas quedaron mal';
  END IF;
  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.auditoria_integridad()'::regprocedure)
     !~ 'AND m\.recupera_faltante_id IS NULL' THEN
    RAISE EXCEPTION 'mig NNN · poscondición: FALT-B sin lo que pagó el cliente contra un faltante';
  END IF;
  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.obtener_faltantes_rendiciones(date,date,uuid)'::regprocedure)
     !~ '_faltante_recuperado' THEN
    RAISE EXCEPTION 'mig NNN · poscondición: obtener_faltantes_rendiciones sin lo recuperado';
  END IF;
END
$pos$;

COMMIT;
