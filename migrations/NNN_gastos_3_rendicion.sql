-- =========================================================================
-- NNN · GASTOS 3 · LOS GASTOS DE LA RENDICION (entrega 2 de 5)
--
-- Diseno: docs/superpowers/specs/2026-10-28-gastos-y-cuentas-del-personal-design.md
-- Plan:   docs/superpowers/plans/2026-10-29-gastos-2-rendicion.md (Tarea 2)
-- Ensayo: scripts/test-gastos-3.sql
--
-- Un gasto pagado con la plata de una rendicion (el combustible que carga el
-- chofer con lo que cobro) es un gasto como cualquier otro, con rubro,
-- comprobante y vehiculo, y ademas se descuenta del efectivo que entrega ese
-- dia. Hasta aca eso era rendicion_gastos: texto libre y un monto, sin rubro,
-- que no llegaba al resultado (0 filas en prod). Esta migracion lo pasa a
-- `gastos` y retira esa tabla.
--
-- QUE AGREGA
--   * gastos.rendicion_transportista_id y gastos.rendicion_fecha, obligatorias
--     con origen_pago = 'rendicion' y NULL con cualquier otro origen
--     (gastos_rendicion_check).
--   * guardar_gasto y anular_gasto pasan a ser wrappers de _guardar_gasto y
--     _anular_gasto (de server), que reciben p_desde_cierre. Desde la vista
--     Gastos un gasto de una rendicion cerrada (confirmada o resuelta;
--     disconformidad no lo esta) no se carga, no se cambia, no se mueve a la
--     oficina y no se anula: eso es "Editar cierre". Desde confirmar_rendicion
--     si.
--   * confirmar_rendicion cambia de firma: p_gastos jsonb (la lista de
--     rendicion_gastos) se va y entra p_gastos_rendicion {vistos, guardar,
--     quitar}. vistos son los gastos que mostro el modal: si no son los vivos,
--     alguien cargo o quito uno mientras tanto y el cierre se rechaza entero.
--     guardar lleva solo lo nuevo y lo editado (asi el encargado reconfirma
--     sin tocar los gastos que cargo un admin) y quitar anula con el motivo
--     'Quitado en el cierre de la rendicion'.
--   * obtener_resumen_rendiciones suma los gastos de rendicion en total_gastos
--     y cantidad_gastos (siguen aportando filas a la grilla, #639).
--   * obtener_gastos_rendiciones (nueva): la lista, con los roles de
--     obtener_resumen_rendiciones (#724: el transportista, solo lo suyo).
--   * GASTO-A en auditoria_integridad(): gastos de una rendicion cerrada
--     cambiados despues del cierre.
--
-- EL VINCULO ES POR CLAVE, NO POR FK A rendiciones_control. La rendicion es
-- (transportista, fecha, sucursal del gasto). Una rendicion pendiente no tiene
-- fila de control, y trg_pedidos_anular_control borra la de una cerrada cuando
-- cambia una entrega (#1175): con una FK, ese borrado se llevaria los gastos o
-- quedaria trabado. La unica FK nueva es la del transportista a perfiles.
--
-- ORDEN DE LOCKS: primero la rendicion (pg_advisory_xact_lock de
-- _rendicion_clave) y despues la fila del gasto, en todo camino. Lo toman
-- confirmar_rendicion, resolver_rendicion y toda escritura de un gasto de
-- rendicion; un gasto que cambia de rendicion bloquea las dos en orden
-- ascendente (_rendicion_bloquear). Desde la vista Gastos el gasto se lee sin
-- lock, se bloquea la rendicion y recien ahi se relee FOR UPDATE; desde el
-- cierre, la rendicion ya esta bloqueada y el gasto se lee FOR UPDATE directo.
--
-- PERMISOS: sin tablas nuevas ni escritura REST (scripts/grants-rest.json no
-- cambia; las columnas nuevas entran por el GRANT SELECT de tabla de la 411).
-- RPCs del front: REVOKE PUBLIC, anon. Helpers de server (_guardar_gasto,
-- _anular_gasto, _rendicion_clave, _rendicion_bloquear): ademas authenticated.
--
-- DESPLIEGUE: va JUNTO con el front. El bundle viejo llama confirmar_rendicion
-- con p_gastos, que ya no existe (PGRST202): cerrar una rendicion falla sin
-- guardar nada hasta que se recarga. Aplicar fuera del horario de cierre.
-- =========================================================================

SET LOCAL lock_timeout = '5s';

-- -------------------------------------------------------------------------
-- 1 · Las columnas de la rendicion en gastos
-- -------------------------------------------------------------------------
ALTER TABLE public.gastos
  ADD COLUMN rendicion_transportista_id uuid REFERENCES public.perfiles(id),
  ADD COLUMN rendicion_fecha date,
  ADD CONSTRAINT gastos_rendicion_check CHECK (
    (origen_pago = 'rendicion' AND rendicion_transportista_id IS NOT NULL AND rendicion_fecha IS NOT NULL)
    OR (origen_pago <> 'rendicion' AND rendicion_transportista_id IS NULL AND rendicion_fecha IS NULL));

CREATE INDEX gastos_rendicion_idx ON public.gastos (sucursal_id, rendicion_fecha, rendicion_transportista_id)
  WHERE origen_pago = 'rendicion';

COMMENT ON COLUMN public.gastos.rendicion_transportista_id IS
  'Con origen_pago = rendicion: el transportista de la rendicion de cuya plata salio el gasto. La rendicion es (transportista, rendicion_fecha, sucursal_id), sin FK a rendiciones_control: una pendiente no tiene fila (gastos 3).';
COMMENT ON COLUMN public.gastos.rendicion_fecha IS
  'Con origen_pago = rendicion: el dia de la rendicion. Se descuenta del efectivo que el transportista entrega ese dia (gastos 3).';
COMMENT ON COLUMN public.gastos.origen_pago IS
  'oficina | rendicion | empleado. Rendicion desde gastos 3 (con rendicion_transportista_id y rendicion_fecha); empleado todavia lo rechaza guardar_gasto.';

-- -------------------------------------------------------------------------
-- 2 · Helpers de la rendicion: su clave y su lock
-- -------------------------------------------------------------------------
-- El molde de las migs 167 y 235. La fecha va con to_char y no con ::text,
-- que depende de DateStyle. Con un argumento NULL da NULL.
CREATE FUNCTION public._rendicion_clave(p_transportista_id uuid, p_fecha date, p_sucursal_id bigint)
RETURNS bigint
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $fn$
  SELECT hashtextextended('rendicion|' || p_transportista_id::text || '|' || to_char(p_fecha, 'YYYY-MM-DD')
                          || '|' || p_sucursal_id::text, 0);
$fn$;

-- Sin repetir y en orden ascendente: dos transacciones que mueven gastos entre
-- las mismas dos rendiciones las bloquean en el mismo orden y no se trancan.
CREATE FUNCTION public._rendicion_bloquear(p_claves bigint[])
RETURNS void
LANGUAGE plpgsql
SET search_path = public
AS $fn$
DECLARE
  v_clave bigint;
BEGIN
  FOR v_clave IN SELECT DISTINCT c FROM unnest(p_claves) AS c WHERE c IS NOT NULL ORDER BY c LOOP
    PERFORM pg_advisory_xact_lock(v_clave);
  END LOOP;
END
$fn$;

-- -------------------------------------------------------------------------
-- 3 · _guardar_gasto: el cuerpo de guardar_gasto (411), con la rendicion
-- -------------------------------------------------------------------------
CREATE FUNCTION public._guardar_gasto(p_gasto jsonb, p_desde_cierre boolean)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_uid       uuid := auth.uid();
  v_admin     boolean := public.es_admin();
  v_actual    bigint := public.current_sucursal_id();
  v_id        bigint;
  v_viejo     gastos%ROWTYPE;
  v_releido   gastos%ROWTYPE;
  v_rubro     gasto_rubros%ROWTYPE;
  v_suc       bigint;
  v_comp      boolean;
  v_fecha     date;
  v_rubro_id  bigint;
  v_total     numeric;
  v_tipo      text;
  v_numero    text;
  v_alicuota  numeric;
  v_iva       numeric;
  v_piva      numeric;
  v_piibb     numeric;
  v_otros     numeric;
  v_veh       bigint;
  v_litros    numeric;
  v_km        integer;
  v_mes       date;
  v_meses     integer;
  v_origen    text;
  v_obs       text;
  v_rend_tr   uuid;
  v_rend_f    date;
BEGIN
  -- 1 · rol
  IF NOT public.es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Sólo un admin o el encargado pueden cargar gastos';
  END IF;
  IF jsonb_typeof(p_gasto) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Faltan los datos del gasto';
  END IF;
  BEGIN
    v_id       := NULLIF(p_gasto->>'id', '')::bigint;
    v_suc      := COALESCE(NULLIF(p_gasto->>'sucursal_id', '')::bigint, v_actual);
    v_comp     := COALESCE((p_gasto->>'compartido')::boolean, false);
    v_fecha    := NULLIF(p_gasto->>'fecha', '')::date;
    v_rubro_id := NULLIF(p_gasto->>'rubro_id', '')::bigint;
    v_total    := round(NULLIF(p_gasto->>'monto_total', '')::numeric, 2);
    v_tipo     := NULLIF(btrim(p_gasto->>'comprobante'), '');
    v_numero   := NULLIF(btrim(p_gasto->>'comprobante_numero'), '');
    v_alicuota := NULLIF(p_gasto->>'alicuota_iva', '')::numeric;
    v_iva      := round(COALESCE(NULLIF(p_gasto->>'iva', '')::numeric, 0), 2);
    v_piva     := round(COALESCE(NULLIF(p_gasto->>'percepcion_iva', '')::numeric, 0), 2);
    v_piibb    := round(COALESCE(NULLIF(p_gasto->>'percepcion_iibb', '')::numeric, 0), 2);
    v_otros    := round(COALESCE(NULLIF(p_gasto->>'otros_impuestos', '')::numeric, 0), 2);
    v_veh      := NULLIF(p_gasto->>'vehiculo_id', '')::bigint;
    v_litros   := round(NULLIF(p_gasto->>'litros', '')::numeric, 2);
    v_km       := NULLIF(p_gasto->>'km_tablero', '')::integer;
    v_mes      := NULLIF(p_gasto->>'mes_imputado', '')::date;
    v_meses    := COALESCE(NULLIF(p_gasto->>'repartir_meses', '')::integer, 1);
    v_origen   := COALESCE(NULLIF(btrim(p_gasto->>'origen_pago'), ''), 'oficina');
    v_obs      := NULLIF(btrim(p_gasto->>'observacion'), '');
    v_rend_tr  := NULLIF(btrim(p_gasto->>'rendicion_transportista_id'), '')::uuid;
    v_rend_f   := NULLIF(p_gasto->>'rendicion_fecha', '')::date;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Hay un dato del gasto con un formato inválido';
  END;
  -- En numeric, NaN es MAYOR que todo: pasaria un > 0.
  IF 'NaN'::numeric IN (v_total, v_iva, v_piva, v_piibb, v_otros, v_alicuota, v_litros) THEN
    RAISE EXCEPTION 'Hay un dato del gasto con un formato inválido';
  END IF;

  -- 2 · sucursal
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la sucursal del gasto: elegí una sucursal';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM usuario_sucursales us JOIN sucursales s ON s.id = us.sucursal_id
                  WHERE us.usuario_id = v_uid AND us.sucursal_id = v_suc AND s.activa) THEN
    RAISE EXCEPTION 'No tenés asignada esa sucursal: el gasto va en una de tus sucursales';
  END IF;

  -- 3 · lo que el encargado no puede
  IF NOT v_admin THEN
    IF v_comp THEN
      RAISE EXCEPTION 'Sólo un admin puede cargar un gasto compartido';
    END IF;
    IF v_suc IS DISTINCT FROM v_actual THEN
      RAISE EXCEPTION 'El encargado carga gastos sólo en la sucursal en la que está';
    END IF;
  END IF;

  IF v_id IS NOT NULL THEN
    -- Desde el cierre, confirmar_rendicion ya bloqueo la rendicion: la fila
    -- va FOR UPDATE ya. Desde Gastos, primero la rendicion (paso 8b).
    IF p_desde_cierre THEN
      SELECT * INTO v_viejo FROM gastos WHERE id = v_id FOR UPDATE;
    ELSE
      SELECT * INTO v_viejo FROM gastos WHERE id = v_id;
    END IF;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Ese gasto no existe';
    END IF;
    -- Antes que el vehiculo: si no, cambiar de sucursal un gasto con vehiculo
    -- daria "el vehiculo no es de la sucursal", que no dice que hacer.
    IF v_viejo.sucursal_id <> v_suc THEN
      RAISE EXCEPTION 'Un gasto no cambia de sucursal: anulalo y cargalo de nuevo en la otra';
    END IF;
  END IF;

  -- 4 · rubro (uno dado de baja se puede conservar al editar, no elegir)
  SELECT * INTO v_rubro FROM gasto_rubros WHERE id = v_rubro_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Elegí el rubro del gasto';
  END IF;
  IF NOT v_rubro.activo AND v_viejo.rubro_id IS DISTINCT FROM v_rubro_id THEN
    RAISE EXCEPTION 'El rubro % está dado de baja: elegí otro', v_rubro.nombre;
  END IF;

  -- 5 · vehiculo (idem)
  IF v_veh IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM vehiculos
        WHERE id = v_veh AND sucursal_id = v_suc
          AND (activo OR v_viejo.vehiculo_id IS NOT DISTINCT FROM v_veh)) THEN
    RAISE EXCEPTION 'El vehículo no es de la sucursal del gasto o está dado de baja';
  END IF;

  -- 6 · litros y km del tablero, solo con un rubro que los pide
  IF (v_litros IS NOT NULL OR v_km IS NOT NULL) AND NOT v_rubro.pide_litros_km THEN
    RAISE EXCEPTION 'Este rubro no lleva litros ni km';
  END IF;
  IF v_litros IS NOT NULL AND v_litros <= 0 THEN
    RAISE EXCEPTION 'Los litros tienen que ser más que cero';
  END IF;
  IF v_km IS NOT NULL AND v_veh IS NULL THEN
    RAISE EXCEPTION 'Para anotar los km del tablero elegí el vehículo';
  END IF;
  IF v_km IS NOT NULL AND v_km NOT BETWEEN 0 AND 9999999 THEN
    RAISE EXCEPTION 'Los km del tablero tienen que estar entre 0 y 9.999.999';
  END IF;

  -- 7 · datos y desglose (los mensajes de errorDeDesglose, src/utils/gastos.ts)
  IF v_fecha IS NULL THEN
    RAISE EXCEPTION 'Falta la fecha del gasto';
  END IF;
  IF v_total IS NULL OR v_total <= 0 OR v_total > 999999999999.99 THEN
    RAISE EXCEPTION 'El monto tiene que ser mayor a cero';
  END IF;
  IF v_tipo IS NULL OR v_tipo NOT IN ('factura_a', 'factura_m', 'factura_b', 'factura_c', 'recibo', 'ticket', 'ninguno') THEN
    RAISE EXCEPTION 'Elegí el comprobante del gasto';
  END IF;
  IF v_iva < 0 OR v_piva < 0 OR v_piibb < 0 OR v_otros < 0 THEN
    RAISE EXCEPTION 'Ningún importe puede ser negativo';
  END IF;
  IF v_tipo IN ('factura_a', 'factura_m') THEN
    IF v_total - v_iva - v_piva - v_piibb - v_otros <= 0 THEN
      RAISE EXCEPTION 'Con factura A o M el neto tiene que ser mayor a cero';
    END IF;
    IF v_alicuota IS NOT NULL AND v_alicuota NOT IN (21, 10.5, 27) THEN
      RAISE EXCEPTION 'La alícuota de IVA tiene que ser 21, 10,5 o 27';
    END IF;
  ELSE
    IF v_iva > 0 OR v_piva > 0 OR v_piibb > 0 OR v_otros > 0 THEN
      RAISE EXCEPTION 'Sólo la factura A o M lleva IVA y percepciones';
    END IF;
    -- Sin desglose, la alicuota no significa nada.
    v_alicuota := NULL;
  END IF;
  IF v_meses NOT BETWEEN 1 AND 120 THEN
    RAISE EXCEPTION 'Un gasto se reparte en 1 a 120 meses';
  END IF;
  v_mes := date_trunc('month', COALESCE(v_mes, v_fecha)::timestamp)::date;

  -- 8 · origen: la oficina o una rendicion (el empleado, en la entrega 3)
  IF v_origen = 'oficina' THEN
    v_rend_tr := NULL;
    v_rend_f  := NULL;
  ELSIF v_origen = 'rendicion' THEN
    IF v_rend_tr IS NULL OR v_rend_f IS NULL THEN
      RAISE EXCEPTION 'Elegí de qué rendición salió la plata: el transportista y el día';
    END IF;
    IF v_rend_f > public._tablero_hoy() THEN
      RAISE EXCEPTION 'La rendición no puede ser de un día que todavía no llegó';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM usuario_sucursales WHERE usuario_id = v_rend_tr AND sucursal_id = v_suc) THEN
      RAISE EXCEPTION 'Ese transportista no es de la sucursal del gasto';
    END IF;
  ELSIF v_origen = 'empleado' THEN
    RAISE EXCEPTION 'Todavía no se puede pagar un gasto con la plata de un empleado: cargalo como pagado por la oficina';
  ELSE
    RAISE EXCEPTION 'Elegí con qué plata se pagó el gasto';
  END IF;

  -- 8b · desde Gastos: la rendicion vieja y la nueva, y recien ahi la fila
  IF NOT p_desde_cierre THEN
    PERFORM public._rendicion_bloquear(ARRAY[
      CASE WHEN v_viejo.origen_pago = 'rendicion'
           THEN public._rendicion_clave(v_viejo.rendicion_transportista_id, v_viejo.rendicion_fecha, v_viejo.sucursal_id)
      END,
      public._rendicion_clave(v_rend_tr, v_rend_f, v_suc)]);
    IF v_id IS NOT NULL THEN
      SELECT * INTO v_releido FROM gastos WHERE id = v_id FOR UPDATE;
      -- Si otro lo movio de rendicion entre las dos lecturas, el lock que
      -- tenemos no es el de su rendicion de ahora.
      IF v_releido.origen_pago IS DISTINCT FROM v_viejo.origen_pago
         OR v_releido.rendicion_transportista_id IS DISTINCT FROM v_viejo.rendicion_transportista_id
         OR v_releido.rendicion_fecha IS DISTINCT FROM v_viejo.rendicion_fecha THEN
        RAISE EXCEPTION 'El gasto cambió mientras lo guardabas: volvé a intentarlo';
      END IF;
      v_viejo := v_releido;
    END IF;
  END IF;

  -- 9 · edicion: quien lo puede cambiar
  IF v_id IS NOT NULL THEN
    IF v_viejo.anulado_at IS NOT NULL THEN
      RAISE EXCEPTION 'Este gasto está anulado: no se puede cambiar';
    END IF;
    IF v_admin THEN
      IF NOT EXISTS (SELECT 1 FROM usuario_sucursales WHERE usuario_id = v_uid AND sucursal_id = v_viejo.sucursal_id) THEN
        RAISE EXCEPTION 'No tenés asignada la sucursal de este gasto';
      END IF;
      IF v_viejo.compartido AND v_viejo.creado_por IS DISTINCT FROM v_uid
         AND NOT public._tiene_todas_las_sucursales() THEN
        RAISE EXCEPTION 'Este gasto compartido lo puede cambiar quien lo cargó o un admin de todas las sucursales';
      END IF;
      -- Compartirlo se lo saca al que lo cargo (el encargado deja de verlo, y
      -- desde ahi solo lo toca un admin de todas): lo decide el o uno de todas.
      IF v_comp AND NOT v_viejo.compartido AND v_viejo.creado_por IS DISTINCT FROM v_uid
         AND NOT public._tiene_todas_las_sucursales() THEN
        RAISE EXCEPTION 'Para compartir un gasto que cargó otro, anulalo y cargalo de nuevo como compartido';
      END IF;
    ELSIF v_viejo.creado_por IS DISTINCT FROM v_uid OR v_viejo.compartido THEN
      RAISE EXCEPTION 'El encargado sólo edita los gastos que cargó';
    END IF;
  END IF;

  -- 10 · desde Gastos, una rendicion cerrada no se toca: es "Editar cierre"
  IF NOT p_desde_cierre THEN
    IF v_viejo.origen_pago = 'rendicion'
       AND public.control_rendicion_cerrado(v_viejo.rendicion_transportista_id, v_viejo.sucursal_id, v_viejo.rendicion_fecha) THEN
      RAISE EXCEPTION 'Este gasto es de una rendición cerrada: se cambia desde «Editar cierre» en Rendiciones';
    END IF;
    IF v_origen = 'rendicion' AND public.control_rendicion_cerrado(v_rend_tr, v_suc, v_rend_f) THEN
      RAISE EXCEPTION 'Esa rendición ya está cerrada: el gasto se carga desde «Editar cierre» en Rendiciones';
    END IF;
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO gastos (sucursal_id, compartido, fecha, rubro_id, monto_total, comprobante, comprobante_numero,
                        alicuota_iva, iva, percepcion_iva, percepcion_iibb, otros_impuestos, vehiculo_id, litros,
                        mes_imputado, repartir_meses, origen_pago, rendicion_transportista_id, rendicion_fecha,
                        observacion, creado_por)
    VALUES (v_suc, v_comp, v_fecha, v_rubro_id, v_total, v_tipo, v_numero,
            v_alicuota, v_iva, v_piva, v_piibb, v_otros, v_veh, v_litros,
            v_mes, v_meses, v_origen, v_rend_tr, v_rend_f,
            v_obs, v_uid)
    RETURNING id INTO v_id;
  ELSE
    UPDATE gastos
       SET compartido = v_comp, fecha = v_fecha, rubro_id = v_rubro_id, monto_total = v_total,
           comprobante = v_tipo, comprobante_numero = v_numero, alicuota_iva = v_alicuota, iva = v_iva,
           percepcion_iva = v_piva, percepcion_iibb = v_piibb, otros_impuestos = v_otros,
           vehiculo_id = v_veh, litros = v_litros, mes_imputado = v_mes, repartir_meses = v_meses,
           origen_pago = v_origen, rendicion_transportista_id = v_rend_tr, rendicion_fecha = v_rend_f,
           observacion = v_obs, updated_at = now()
     WHERE id = v_id;
  END IF;

  -- La lectura de km de la carga es la del gasto: la crea, la corrige o la borra.
  IF v_km IS NOT NULL THEN
    INSERT INTO vehiculo_km (sucursal_id, vehiculo_id, fecha, km, origen, gasto_id, creado_por)
    VALUES (v_suc, v_veh, v_fecha, v_km, 'carga', v_id, v_uid)
    ON CONFLICT (gasto_id) DO UPDATE
      SET vehiculo_id = EXCLUDED.vehiculo_id, fecha = EXCLUDED.fecha, km = EXCLUDED.km;
  ELSE
    DELETE FROM vehiculo_km WHERE gasto_id = v_id;
  END IF;

  RETURN v_id;
END
$fn$;

-- La puerta de la vista Gastos. Misma firma que en la 411: conserva los grants.
CREATE OR REPLACE FUNCTION public.guardar_gasto(p_gasto jsonb)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  IF NOT public.es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Sólo un admin o el encargado pueden cargar gastos';
  END IF;
  RETURN public._guardar_gasto(p_gasto, false);
END
$fn$;

-- -------------------------------------------------------------------------
-- 4 · _anular_gasto: el cuerpo de anular_gasto (411), con la rendicion
-- -------------------------------------------------------------------------
CREATE FUNCTION public._anular_gasto(p_gasto_id bigint, p_motivo text, p_desde_cierre boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_uid     uuid := auth.uid();
  v_gasto   gastos%ROWTYPE;
  v_releido gastos%ROWTYPE;
BEGIN
  IF NOT public.es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Sólo un admin o el encargado pueden anular gastos';
  END IF;
  IF p_motivo IS NULL OR btrim(p_motivo) = '' THEN
    RAISE EXCEPTION 'Escribí por qué se anula';
  END IF;
  -- El mismo orden de locks que _guardar_gasto: la rendicion y despues la fila.
  IF p_desde_cierre THEN
    SELECT * INTO v_gasto FROM gastos WHERE id = p_gasto_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Ese gasto no existe';
    END IF;
  ELSE
    SELECT * INTO v_gasto FROM gastos WHERE id = p_gasto_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Ese gasto no existe';
    END IF;
    IF v_gasto.origen_pago = 'rendicion' THEN
      PERFORM public._rendicion_bloquear(ARRAY[
        public._rendicion_clave(v_gasto.rendicion_transportista_id, v_gasto.rendicion_fecha, v_gasto.sucursal_id)]);
    END IF;
    SELECT * INTO v_releido FROM gastos WHERE id = p_gasto_id FOR UPDATE;
    IF v_releido.origen_pago IS DISTINCT FROM v_gasto.origen_pago
       OR v_releido.rendicion_transportista_id IS DISTINCT FROM v_gasto.rendicion_transportista_id
       OR v_releido.rendicion_fecha IS DISTINCT FROM v_gasto.rendicion_fecha THEN
      RAISE EXCEPTION 'El gasto cambió mientras lo guardabas: volvé a intentarlo';
    END IF;
    v_gasto := v_releido;
  END IF;
  IF v_gasto.anulado_at IS NOT NULL THEN
    RAISE EXCEPTION 'Este gasto ya está anulado';
  END IF;
  IF public.es_admin() THEN
    IF NOT EXISTS (SELECT 1 FROM usuario_sucursales WHERE usuario_id = v_uid AND sucursal_id = v_gasto.sucursal_id) THEN
      RAISE EXCEPTION 'No tenés asignada la sucursal de este gasto';
    END IF;
    IF v_gasto.compartido AND v_gasto.creado_por IS DISTINCT FROM v_uid
       AND NOT public._tiene_todas_las_sucursales() THEN
      RAISE EXCEPTION 'Este gasto compartido lo puede anular quien lo cargó o un admin de todas las sucursales';
    END IF;
  ELSIF v_gasto.creado_por IS DISTINCT FROM v_uid OR v_gasto.compartido
        OR v_gasto.sucursal_id IS DISTINCT FROM public.current_sucursal_id() THEN
    RAISE EXCEPTION 'El encargado sólo anula los gastos que cargó';
  END IF;
  IF NOT p_desde_cierre AND v_gasto.origen_pago = 'rendicion'
     AND public.control_rendicion_cerrado(v_gasto.rendicion_transportista_id, v_gasto.sucursal_id, v_gasto.rendicion_fecha) THEN
    RAISE EXCEPTION 'Este gasto es de una rendición cerrada: se quita desde «Editar cierre» en Rendiciones';
  END IF;

  UPDATE gastos
     SET anulado_at = now(), anulado_por = v_uid, motivo_anulacion = btrim(p_motivo), updated_at = now()
   WHERE id = p_gasto_id;
  DELETE FROM vehiculo_km WHERE gasto_id = p_gasto_id;
END
$fn$;

CREATE OR REPLACE FUNCTION public.anular_gasto(p_gasto_id bigint, p_motivo text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  IF NOT public.es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Sólo un admin o el encargado pueden anular gastos';
  END IF;
  PERFORM public._anular_gasto(p_gasto_id, p_motivo, false);
END
$fn$;

-- -------------------------------------------------------------------------
-- 5 · confirmar_rendicion: los gastos viajan como cambios
-- -------------------------------------------------------------------------
-- Firma nueva (trampa 5: se dropea la vieja, no conviven). p_gastos_rendicion
-- va antes de p_observaciones porque no tiene default; el front llama por
-- nombre.
DROP FUNCTION public.confirmar_rendicion(date, uuid, text, text, jsonb);

CREATE FUNCTION public.confirmar_rendicion(
  p_fecha            date,
  p_transportista_id uuid,
  p_estado           text,
  p_gastos_rendicion jsonb,
  p_observaciones    text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_sucursal_id BIGINT;
  v_id          BIGINT;
  v_guardar     jsonb;
  v_vistos      bigint[];
  v_quitar      bigint[];
  v_ids_guardar bigint[];
  v_vivos       bigint[];
  v_gid         bigint;
  v_elem        jsonb;
  v_rubro       text;
  v_msg         text;
  v_code        text;
BEGIN
  -- 1 · sucursal, rol y estado
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no seleccionada';
  END IF;

  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF p_estado NOT IN ('confirmada','disconformidad') THEN
    RAISE EXCEPTION 'Estado invalido: %. Use "confirmada" o "disconformidad"', p_estado;
  END IF;

  -- 2 · la rendicion, antes que cualquier fila de gastos
  PERFORM public._rendicion_bloquear(ARRAY[public._rendicion_clave(p_transportista_id, p_fecha, v_sucursal_id)]);

  -- 3 · formato: {vistos: [ids], guardar: [gastos], quitar: [ids]}; una clave
  --     que no viene es []
  BEGIN
    IF jsonb_typeof(p_gastos_rendicion) IS DISTINCT FROM 'object'
       OR jsonb_typeof(COALESCE(p_gastos_rendicion->'vistos', '[]')) <> 'array'
       OR jsonb_typeof(COALESCE(p_gastos_rendicion->'quitar', '[]')) <> 'array'
       OR jsonb_typeof(COALESCE(p_gastos_rendicion->'guardar', '[]')) <> 'array' THEN
      RAISE EXCEPTION 'formato';
    END IF;
    v_guardar := COALESCE(p_gastos_rendicion->'guardar', '[]');
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(p_gastos_rendicion->'vistos', '[]')
                                                  || COALESCE(p_gastos_rendicion->'quitar', '[]')) e
                WHERE jsonb_typeof(e) <> 'number')
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_guardar) e
                   WHERE jsonb_typeof(e) <> 'object'
                      OR jsonb_typeof(COALESCE(e->'id', 'null')) NOT IN ('number', 'null')) THEN
      RAISE EXCEPTION 'formato';
    END IF;
    -- Un id con decimales no entra en bigint: cae al EXCEPTION de abajo.
    v_vistos := ARRAY(SELECT (e #>> '{}')::bigint FROM jsonb_array_elements(COALESCE(p_gastos_rendicion->'vistos', '[]')) e);
    v_quitar := ARRAY(SELECT (e #>> '{}')::bigint FROM jsonb_array_elements(COALESCE(p_gastos_rendicion->'quitar', '[]')) e);
    v_ids_guardar := ARRAY(SELECT (e->>'id')::bigint FROM jsonb_array_elements(v_guardar) e
                            WHERE e->>'id' IS NOT NULL);
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Los gastos del cierre vienen con un formato inválido';
  END;

  -- 4 · los vivos de esta rendicion tienen que ser los que vio el modal
  v_vivos := ARRAY(SELECT g.id FROM gastos g
                    WHERE g.origen_pago = 'rendicion'
                      AND g.sucursal_id = v_sucursal_id
                      AND g.rendicion_transportista_id = p_transportista_id
                      AND g.rendicion_fecha = p_fecha
                      AND g.anulado_at IS NULL);
  IF NOT (v_vivos <@ v_vistos AND v_vistos <@ v_vivos) THEN
    RAISE EXCEPTION 'Los gastos de esta rendición cambiaron mientras la cerrabas: tocá Refrescar y volvé a abrir el cierre';
  END IF;

  -- 5 · lo que se quita o se edita es de esta rendicion, y una sola vez
  IF EXISTS (SELECT 1 FROM unnest(v_quitar || v_ids_guardar) x WHERE x <> ALL (v_vivos)) THEN
    RAISE EXCEPTION 'Ese gasto no es de esta rendición o ya está anulado';
  END IF;
  IF cardinality(v_quitar || v_ids_guardar)
     <> (SELECT count(DISTINCT x) FROM unnest(v_quitar || v_ids_guardar) x) THEN
    RAISE EXCEPTION 'Un gasto viene dos veces en el cierre';
  END IF;

  -- 6 · quitar: se anula, con quien y cuando en la anulacion
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
$fn$;

-- -------------------------------------------------------------------------
-- 6 · resolver_rendicion: el mismo lock, antes de leer el control
-- -------------------------------------------------------------------------
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

  UPDATE rendiciones_control
     SET estado = 'resuelta',
         observaciones = COALESCE(v_obs_previas, '')
           || CASE WHEN v_obs_previas IS NOT NULL AND length(v_obs_previas) > 0 THEN E'\n\n' ELSE '' END
           || '[Resuelta por ' || COALESCE(v_nombre_usuario, 'usuario') || ' el '
           || to_char(now(), 'DD/MM/YYYY HH24:MI')
           || ']: ' || p_observaciones,
         resuelta_at = now(),
         resuelta_por = auth.uid()
   WHERE id = v_id;

  RETURN v_id;
END;
$fn$;

-- -------------------------------------------------------------------------
-- 7 · obtener_resumen_rendiciones: total_gastos sale de gastos
-- -------------------------------------------------------------------------
-- Se reemplaza solo la CTE gastos_agg sobre el cuerpo vivo (sigue aportando
-- filas a fechas_activas, #639). Las dos marcas tienen que aparecer una vez.
DO $patch$
DECLARE
  v_def   text := pg_get_functiondef('public.obtener_resumen_rendiciones(date,date,uuid)'::regprocedure);
  v_desde text := E'  gastos_agg AS (\n';
  v_hasta text := E'  /* #1248 · una rendicion cerrada esta siempre en la grilla';
  v_nuevo text := E'  gastos_agg AS (\n'
    || E'    -- gastos 3: los gastos pagados con la plata de esta rendicion.\n'
    || E'    SELECT g.rendicion_transportista_id AS t_id, g.rendicion_fecha AS f,\n'
    || E'           SUM(g.monto_total)::numeric AS tot_g, COUNT(*)::bigint AS cant_g\n'
    || E'      FROM gastos g\n'
    || E'     WHERE g.origen_pago = ''rendicion'' AND g.anulado_at IS NULL\n'
    || E'       AND g.sucursal_id = v_sucursal_id\n'
    || E'       AND g.rendicion_fecha BETWEEN p_fecha_desde AND p_fecha_hasta\n'
    || E'       AND (p_transportista_id IS NULL OR g.rendicion_transportista_id = p_transportista_id)\n'
    || E'     GROUP BY 1, 2\n'
    || E'  ),\n';
  v_ini   int;
  v_fin   int;
BEGIN
  IF (length(v_def) - length(replace(v_def, v_desde, ''))) / length(v_desde) <> 1
     OR (length(v_def) - length(replace(v_def, v_hasta, ''))) / length(v_hasta) <> 1 THEN
    RAISE EXCEPTION 'obtener_resumen_rendiciones cambio: las marcas de gastos_agg no estan una vez cada una';
  END IF;
  v_ini := position(v_desde IN v_def);
  v_fin := position(v_hasta IN v_def);
  IF v_fin <= v_ini OR substr(v_def, v_ini, v_fin - v_ini) !~ 'FROM rendicion_gastos rg' THEN
    RAISE EXCEPTION 'obtener_resumen_rendiciones cambio: gastos_agg no es la de rendicion_gastos';
  END IF;
  EXECUTE left(v_def, v_ini - 1) || v_nuevo || substr(v_def, v_fin);
END
$patch$;

-- -------------------------------------------------------------------------
-- 8 · obtener_gastos_rendiciones: la lista
-- -------------------------------------------------------------------------
CREATE FUNCTION public.obtener_gastos_rendiciones(
  p_fecha_desde      date,
  p_fecha_hasta      date,
  p_transportista_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_sucursal_id BIGINT;
  v_res         jsonb;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no seleccionada';
  END IF;
  -- Los roles de obtener_resumen_rendiciones (#724): el transportista ve solo
  -- lo suyo (null = yo); es_transportista() incluye al admin, que ya entro
  -- por la rama de arriba (trampa 4).
  IF NOT es_encargado_o_admin() THEN
    IF NOT es_transportista() THEN
      RAISE EXCEPTION 'No autorizado';
    END IF;
    IF p_transportista_id IS NOT NULL AND p_transportista_id <> auth.uid() THEN
      RAISE EXCEPTION 'Acceso denegado' USING ERRCODE = '42501';
    END IF;
    p_transportista_id := auth.uid();
  END IF;

  -- Las columnas de GASTO_COLUMNAS (src/hooks/queries/gastoColumnas.ts), mas
  -- la rendicion y los km de la carga. Un compartido tambien: es plata de esta
  -- rendicion.
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', g.id, 'sucursal_id', g.sucursal_id, 'compartido', g.compartido, 'fecha', g.fecha,
           'rubro_id', g.rubro_id, 'monto_total', g.monto_total, 'comprobante', g.comprobante,
           'comprobante_numero', g.comprobante_numero, 'alicuota_iva', g.alicuota_iva, 'iva', g.iva,
           'percepcion_iva', g.percepcion_iva, 'percepcion_iibb', g.percepcion_iibb,
           'otros_impuestos', g.otros_impuestos, 'neto', g.neto, 'costo', g.costo,
           'vehiculo_id', g.vehiculo_id, 'litros', g.litros, 'mes_imputado', g.mes_imputado,
           'repartir_meses', g.repartir_meses, 'mes_fin', g.mes_fin, 'origen_pago', g.origen_pago,
           'observacion', g.observacion, 'creado_por', g.creado_por, 'anulado_at', g.anulado_at,
           'created_at', g.created_at,
           'rendicion_transportista_id', g.rendicion_transportista_id, 'rendicion_fecha', g.rendicion_fecha,
           'rubro', jsonb_build_object('id', r.id, 'nombre', r.nombre, 'grupo', r.grupo),
           'vehiculo', CASE WHEN v.id IS NULL THEN NULL
                            ELSE jsonb_build_object('id', v.id, 'patente', v.patente, 'descripcion', v.descripcion) END,
           'km_tablero', k.km)
         ORDER BY g.rendicion_fecha DESC, g.rendicion_transportista_id, g.id), '[]'::jsonb)
    INTO v_res
    FROM gastos g
    JOIN gasto_rubros r ON r.id = g.rubro_id
    LEFT JOIN vehiculos v ON v.id = g.vehiculo_id
    LEFT JOIN vehiculo_km k ON k.gasto_id = g.id
   WHERE g.origen_pago = 'rendicion'
     AND g.anulado_at IS NULL
     AND g.sucursal_id = v_sucursal_id
     AND g.rendicion_fecha BETWEEN p_fecha_desde AND p_fecha_hasta
     AND (p_transportista_id IS NULL OR g.rendicion_transportista_id = p_transportista_id);

  RETURN v_res;
END
$fn$;

-- -------------------------------------------------------------------------
-- 9 · rendicion_gastos se retira
-- -------------------------------------------------------------------------
DO $retiro$
BEGIN
  IF EXISTS (SELECT 1 FROM public.rendicion_gastos) THEN
    RAISE EXCEPTION 'rendicion_gastos tiene filas: revisalas antes de retirarla';
  END IF;
END
$retiro$;

DROP TABLE public.rendicion_gastos;

-- -------------------------------------------------------------------------
-- 10 · GASTO-A en auditoria_integridad()
-- -------------------------------------------------------------------------
-- Da 0 en todo camino legitimo: "Editar cierre" escribe el gasto y
-- controlada_at con el mismo now(), y un cambio durante la disconformidad es
-- anterior a resuelta_at. Se suma despues del ultimo check del cuerpo vivo.
DO $patch$
DECLARE
  v_def   text := pg_get_functiondef('public.auditoria_integridad()'::regprocedure);
  v_ancla text := E'\n  )\n  SELECT jsonb_agg(\n';
  v_nuevo text := E',\n'
    || E'    -- gastos 3 · un gasto de una rendicion cerrada se cambia solo desde\n'
    || E'    -- "Editar cierre", que lo escribe con el mismo now() que controlada_at.\n'
    || E'    -- Cuenta los anulados: quitarlo tambien es cambiarlo.\n'
    || E'    (''GASTO-A'',''high'',''gastos de una rendición cerrada cambiados después del cierre, sin pasar por «Editar cierre» (gastos 3)'',\n'
    || E'      (SELECT count(*) FROM gastos g\n'
    || E'         JOIN rendiciones_control rc\n'
    || E'           ON rc.transportista_id = g.rendicion_transportista_id AND rc.fecha = g.rendicion_fecha\n'
    || E'          AND rc.sucursal_id = g.sucursal_id\n'
    || E'        WHERE g.origen_pago = ''rendicion''\n'
    || E'          AND rc.estado IN (''confirmada'', ''resuelta'')\n'
    || E'          AND g.updated_at > CASE WHEN rc.estado = ''resuelta'' THEN rc.resuelta_at ELSE rc.controlada_at END))'
    || v_ancla;
BEGIN
  IF (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla) <> 1 THEN
    RAISE EXCEPTION 'auditoria_integridad cambio: el cierre de la lista de checks no esta una vez';
  END IF;
  IF v_def ~ '''GASTO-' THEN
    RAISE EXCEPTION 'auditoria_integridad ya tiene un id GASTO-*: revisar la lista viva antes de sumar GASTO-A';
  END IF;
  EXECUTE replace(v_def, v_ancla, v_nuevo);
END
$patch$;

-- -------------------------------------------------------------------------
-- 11 · Permisos de las funciones nuevas
-- -------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public._rendicion_clave(uuid, date, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._rendicion_bloquear(bigint[]) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._guardar_gasto(jsonb, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._anular_gasto(bigint, text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._rendicion_clave(uuid, date, bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public._rendicion_bloquear(bigint[]) TO service_role;
GRANT EXECUTE ON FUNCTION public._guardar_gasto(jsonb, boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public._anular_gasto(bigint, text, boolean) TO service_role;

REVOKE ALL ON FUNCTION public.confirmar_rendicion(date, uuid, text, jsonb, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.obtener_gastos_rendiciones(date, date, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.confirmar_rendicion(date, uuid, text, jsonb, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.obtener_gastos_rendiciones(date, date, uuid) TO authenticated, service_role;

-- -------------------------------------------------------------------------
-- 12 · Verificacion estructural
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  f text;
BEGIN
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'confirmar_rendicion') <> 1
     OR to_regprocedure('public.confirmar_rendicion(date,uuid,text,text,jsonb)') IS NOT NULL THEN
    RAISE EXCEPTION 'confirmar_rendicion no quedo con una sola firma, la nueva';
  END IF;
  IF to_regclass('public.rendicion_gastos') IS NOT NULL THEN
    RAISE EXCEPTION 'rendicion_gastos sigue existiendo';
  END IF;
  FOREACH f IN ARRAY ARRAY['public._rendicion_clave(uuid,date,bigint)', 'public._rendicion_bloquear(bigint[])',
                           'public._guardar_gasto(jsonb,boolean)', 'public._anular_gasto(bigint,text,boolean)'] LOOP
    IF has_function_privilege('anon', f, 'EXECUTE') OR has_function_privilege('authenticated', f, 'EXECUTE') THEN
      RAISE EXCEPTION '% quedo alcanzable desde el front', f;
    END IF;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.confirmar_rendicion(date,uuid,text,jsonb,text)',
                           'public.obtener_gastos_rendiciones(date,date,uuid)',
                           'public.guardar_gasto(jsonb)', 'public.anular_gasto(bigint,text)',
                           'public.resolver_rendicion(date,uuid,text)',
                           'public.obtener_resumen_rendiciones(date,date,uuid)'] LOOP
    IF has_function_privilege('anon', f, 'EXECUTE') OR NOT has_function_privilege('authenticated', f, 'EXECUTE') THEN
      RAISE EXCEPTION 'los EXECUTE de % no quedaron como se esperaba', f;
    END IF;
  END LOOP;
  IF pg_get_functiondef('public.obtener_resumen_rendiciones(date,date,uuid)'::regprocedure) ~ 'rendicion_gastos'
     OR pg_get_functiondef('public.auditoria_integridad()'::regprocedure) !~ '''GASTO-A''' THEN
    RAISE EXCEPTION 'obtener_resumen_rendiciones o auditoria_integridad no quedaron parcheadas';
  END IF;
END
$verif$;
