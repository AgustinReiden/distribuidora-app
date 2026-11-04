-- =========================================================================
-- 446 · GASTOS 6 · FALTANTES DE RENDICION (entrega 6 de gastos)
--
-- Diseno: docs/superpowers/specs/2026-11-03-faltantes-de-rendicion-design.md
-- Plan:   docs/superpowers/plans/2026-11-03-gastos-6-faltantes-de-rendicion.md (Tarea 2)
-- Ensayo: scripts/test-gastos-6.sql
--
-- Al resolver una disconformidad, el admin imputa la plata que falto en una o
-- varias lineas, cada una con su monto y su causal. «A cargo del empleado» es
-- una deuda en su cuenta; «robo o perdida» y «gasto que no se cargo» son gastos
-- de la rendicion. Lo imputado baja el efectivo a entregar, y se deshace todo
-- junto con «Deshacer resolucion».
--
-- QUE AGREGA
--   * rendicion_faltantes: una fila por linea, de server (RLS sin policies y
--     sin grants). Cada linea apunta a lo que creo: un movimiento o un gasto.
--     Deshacer la anula, no la borra.
--   * El tipo 'faltante' de empleado_movimientos: negativo y con la rendicion.
--     Su compensacion es otro 'faltante', positivo, con revierte_id.
--   * El rubro «Faltantes de caja» (grupo otros), para el robo o la perdida.
--   * rendicion_faltantes_guarda_gasto: un trigger sobre gastos que no deja
--     cambiar ni anular un gasto con una linea viva, venga de donde venga.
--   * _rendicion_cambio_visto: lo que vio el modal (gastos, pagos al personal y
--     faltantes), una sola definicion para el cierre y la resolucion.
--   * resolver_rendicion con p_resolucion y solo de admin;
--     deshacer_resolucion_rendicion; obtener_faltantes_rendiciones.
--   * obtener_resumen_rendiciones suma total_faltantes_empleados, y
--     total_pagos_personal pasa a contar solo tipo = 'pago'.
--   * confirmar_rendicion compara faltantes_visto, y no manda a disconformidad
--     una rendicion con lineas vivas. revertir_movimiento_empleado rechaza un
--     faltante.
--
-- POR QUE LA CLAVE Y NO EL ID. Las lineas se atan a la clave de la rendicion
-- (transportista, dia y sucursal), como los gastos y los pagos al personal, y
-- no a rendiciones_control.id: anular_control_por_cambio_fecha_entrega borra el
-- control cuando cambia la entrega de un pedido del dia. Lo imputado tiene que
-- seguir restando y poder deshacerse con la rendicion pendiente.
--
-- EL ORDEN DE LOS LOCKS es el de registrar_movimiento_empleado: los empleados
-- de las lineas (FOR UPDATE, por id) y despues la rendicion
-- (_rendicion_bloquear). Deshacer lee los empleados de las lineas vivas, los
-- bloquea, bloquea la rendicion y relee: si las lineas nombran a otro, rechaza.
--
-- POR QUE NO HACE FALTA SALTEAR NINGUNA GUARDA. Resolver escribe todo con la
-- rendicion en disconformidad, que no es cerrada, y recien al final la pasa a
-- resuelta. Deshacer primero la vuelve a disconformidad y despues anula las
-- lineas, y recien entonces los gastos: la guarda de gastos ya no las ve vivas.
-- Los gastos nacen con el mismo now() que resuelta_at, asi que GASTO-A da 0.
--
-- EL BUNDLE VIEJO. resolver_rendicion cambia de firma (la vieja se dropea:
-- PGRST203) con p_resolucion DEFAULT NULL: el admin con el bundle viejo sigue
-- resolviendo solo con el texto, y el encargado recibe «Sólo un admin resuelve
-- una disconformidad». confirmar_rendicion no cambia de firma: sin
-- faltantes_visto vale 0, asi que una rendicion sin faltantes cierra como hoy y
-- una con faltantes no cierra hasta refrescar. obtener_resumen_rendiciones suma
-- una columna al final, que el bundle viejo ignora.
--
-- DESPLIEGUE. Toca empleado_movimientos (CHECKs) y gastos (un trigger): locks
-- breves; con lock_timeout de 5s, si choca se reintenta. Se aplica fuera del
-- horario de cierre de rendiciones, y el front va enseguida.
-- =========================================================================

SET LOCAL lock_timeout = '5s';

-- -------------------------------------------------------------------------
-- 0 · Las funciones que se reescriben son las de hoy
-- -------------------------------------------------------------------------
-- md5(prosrc) de prod al 2026-11-03. Las de la 437 llevan CRLF en prod.
DO $vivas$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('public.resolver_rendicion(date,uuid,text)', 'a30b741cf968581a460a8a4d109dd00f'),
      ('public.confirmar_rendicion(date,uuid,text,jsonb,text)', '077a9f784e5ac2e704f355c805b1b286'),
      ('public.obtener_resumen_rendiciones(date,date,uuid)', '97d90bcd2d841417d715603fbd31c4ef'),
      ('public.revertir_movimiento_empleado(bigint,text)', '10b93a53646eb5e1d6d43a5863c0374b')) AS v(firma, md5)
  LOOP
    IF to_regprocedure(r.firma) IS NULL
       OR (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure(r.firma)) <> r.md5 THEN
      RAISE EXCEPTION '% no es la de prod del 2026-11-03: rehacer la migracion sobre la definicion viva', r.firma;
    END IF;
  END LOOP;
END
$vivas$;

-- -------------------------------------------------------------------------
-- 1 · empleado_movimientos: el tipo 'faltante'
-- -------------------------------------------------------------------------
ALTER TABLE public.empleado_movimientos DROP CONSTRAINT empleado_movimientos_tipo_check;
ALTER TABLE public.empleado_movimientos ADD CONSTRAINT empleado_movimientos_tipo_check
  CHECK (tipo IN ('mercaderia', 'reintegro', 'adelanto', 'ajuste', 'sueldo', 'comision', 'ajuste_comision', 'pago', 'faltante'));
ALTER TABLE public.empleado_movimientos DROP CONSTRAINT empleado_movimientos_rendicion_pago;
ALTER TABLE public.empleado_movimientos ADD CONSTRAINT empleado_movimientos_rendicion_pago
  CHECK (rendicion_fecha IS NULL OR tipo IN ('pago', 'faltante'));
ALTER TABLE public.empleado_movimientos ADD CONSTRAINT empleado_movimientos_faltante_negativo
  CHECK (tipo <> 'faltante' OR revierte_id IS NOT NULL OR monto < 0);
ALTER TABLE public.empleado_movimientos ADD CONSTRAINT empleado_movimientos_faltante_rendicion
  CHECK (tipo <> 'faltante' OR rendicion_fecha IS NOT NULL);

-- -------------------------------------------------------------------------
-- 2 · El rubro del robo o la perdida
-- -------------------------------------------------------------------------
-- Uno para toda la red: gasto_rubros no tiene sucursal. Si alguien ya lo dio de
-- alta con ese nombre, queda el suyo.
INSERT INTO public.gasto_rubros (nombre, grupo, palabras_busqueda, pide_litros_km, reparto_sugerido_meses, sugiere_mes_anterior)
VALUES ('Faltantes de caja', 'otros', 'faltante robo perdida', false, NULL, false)
ON CONFLICT ((lower(btrim(nombre)))) DO NOTHING;

-- -------------------------------------------------------------------------
-- 3 · rendicion_faltantes
-- -------------------------------------------------------------------------
-- La sucursal es una foto de la clave: no se llama sucursal_id, para que
-- auditoria_sucursal_cruzada no la cruce con el empleado.
CREATE TABLE public.rendicion_faltantes (
  id                          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  rendicion_transportista_id  uuid NOT NULL REFERENCES public.perfiles(id),
  rendicion_fecha             date NOT NULL,
  rendicion_sucursal_id       bigint NOT NULL REFERENCES public.sucursales(id),
  causal                      text NOT NULL CHECK (causal IN ('empleado', 'robo_perdida', 'gasto_no_cargado')),
  monto                       numeric(14,2) NOT NULL CHECK (monto > 0),
  empleado_id                 bigint REFERENCES public.empleados(id),
  movimiento_id               bigint UNIQUE REFERENCES public.empleado_movimientos(id),
  gasto_id                    bigint UNIQUE REFERENCES public.gastos(id),
  observacion                 text,
  creado_por                  uuid NOT NULL,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  anulada_at                  timestamptz,
  anulada_por                 uuid,
  motivo_anulacion            text,
  CONSTRAINT rendicion_faltantes_empleado
    CHECK ((causal = 'empleado') = (empleado_id IS NOT NULL AND movimiento_id IS NOT NULL AND gasto_id IS NULL)),
  CONSTRAINT rendicion_faltantes_gasto
    CHECK ((causal <> 'empleado') = (gasto_id IS NOT NULL AND empleado_id IS NULL AND movimiento_id IS NULL)),
  CONSTRAINT rendicion_faltantes_anulacion
    CHECK ((anulada_at IS NULL) = (motivo_anulacion IS NULL))
);

CREATE INDEX rendicion_faltantes_vivas_idx
  ON public.rendicion_faltantes (rendicion_sucursal_id, rendicion_fecha, rendicion_transportista_id)
  WHERE anulada_at IS NULL;

ALTER TABLE public.rendicion_faltantes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.rendicion_faltantes FROM PUBLIC, anon, authenticated;

-- -------------------------------------------------------------------------
-- 4 · La guarda de los gastos de una resolucion
-- -------------------------------------------------------------------------
-- Un gasto con una linea viva no cambia ni se anula por ningun camino: desde
-- Gastos con la rendicion reabierta, desde «Editar cierre» o a mano. Se arregla
-- deshaciendo la resolucion, que anula la linea antes que el gasto.
CREATE FUNCTION public.rendicion_faltantes_guarda_gasto()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM rendicion_faltantes WHERE gasto_id = OLD.id AND anulada_at IS NULL) THEN
    RAISE EXCEPTION 'Este gasto es de la resolución de una diferencia: se deshace con «Deshacer resolución» en Rendiciones'
      USING ERRCODE = '42501';
  END IF;
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER trg_rendicion_faltantes_guarda_gasto
  BEFORE UPDATE OR DELETE ON public.gastos
  FOR EACH ROW EXECUTE FUNCTION public.rendicion_faltantes_guarda_gasto();

-- -------------------------------------------------------------------------
-- 5 · Lo que vio el modal
-- -------------------------------------------------------------------------
-- Los pasos 4 y 4b de confirmar_rendicion, mas los faltantes. NULL si nada
-- cambio, o lo primero que cambio: 'gastos', 'pagos' o 'faltantes'. Cada
-- llamador tiene su mensaje. p_vistos ya viene validado.
CREATE FUNCTION public._rendicion_cambio_visto(p_sucursal_id bigint, p_transportista_id uuid, p_fecha date,
                                               p_vistos jsonb, p_pagos_personal_visto numeric,
                                               p_faltantes_visto numeric)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
  v_vivos bigint[];
BEGIN
  -- Los gastos vivos de la rendicion tienen que ser los que vio el modal, con
  -- la misma version (id, updated_at): uno editado tambien cambia lo que se
  -- entrega.
  v_vivos := ARRAY(SELECT g.id FROM gastos g
                    WHERE g.origen_pago = 'rendicion'
                      AND g.sucursal_id = p_sucursal_id
                      AND g.rendicion_transportista_id = p_transportista_id
                      AND g.rendicion_fecha = p_fecha
                      AND g.anulado_at IS NULL);
  IF EXISTS (SELECT g.id, g.updated_at FROM gastos g WHERE g.id = ANY (v_vivos)
             EXCEPT
             SELECT (e->>'id')::bigint, (e->>'updated_at')::timestamptz FROM jsonb_array_elements(p_vistos) e)
     OR EXISTS (SELECT (e->>'id')::bigint, (e->>'updated_at')::timestamptz FROM jsonb_array_elements(p_vistos) e
                EXCEPT
                SELECT g.id, g.updated_at FROM gastos g WHERE g.id = ANY (v_vivos)) THEN
    RETURN 'gastos';
  END IF;

  -- Los pagos al personal (gastos 5) y los faltantes a cargo de empleados
  -- (gastos 6), cada uno por su tipo: una reversion lleva el mismo tipo y la
  -- misma rendicion, y lo devuelve.
  IF COALESCE((SELECT -SUM(m.monto) FROM empleado_movimientos m
                WHERE m.rendicion_sucursal_id = p_sucursal_id
                  AND m.rendicion_transportista_id = p_transportista_id
                  AND m.rendicion_fecha = p_fecha
                  AND m.tipo = 'pago'), 0) <> p_pagos_personal_visto THEN
    RETURN 'pagos';
  END IF;
  IF COALESCE((SELECT -SUM(m.monto) FROM empleado_movimientos m
                WHERE m.rendicion_sucursal_id = p_sucursal_id
                  AND m.rendicion_transportista_id = p_transportista_id
                  AND m.rendicion_fecha = p_fecha
                  AND m.tipo = 'faltante'), 0) <> p_faltantes_visto THEN
    RETURN 'faltantes';
  END IF;
  RETURN NULL;
END
$$;

-- -------------------------------------------------------------------------
-- 6 · confirmar_rendicion: faltantes_visto y la disconformidad con lineas
-- -------------------------------------------------------------------------
-- El cuerpo de la 437, con los pasos 4 y 4b en _rendicion_cambio_visto.
CREATE OR REPLACE FUNCTION public.confirmar_rendicion(p_fecha date, p_transportista_id uuid, p_estado text, p_gastos_rendicion jsonb, p_observaciones text DEFAULT NULL::text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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

  IF p_estado NOT IN ('confirmada','disconformidad') THEN
    RAISE EXCEPTION 'Estado invalido: %. Use "confirmada" o "disconformidad"', p_estado;
  END IF;

  -- 2 · la rendicion, antes que cualquier fila de gastos
  PERFORM public._rendicion_bloquear(ARRAY[public._rendicion_clave(p_transportista_id, p_fecha, v_sucursal_id)]);

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
$$;

-- -------------------------------------------------------------------------
-- 7 · obtener_resumen_rendiciones: los faltantes a cargo de empleados
-- -------------------------------------------------------------------------
-- Cambia el retorno: DROP + CREATE, con los mismos grants. No la llama ninguna
-- otra funcion de public (solo la nombra un comentario de
-- obtener_gastos_rendiciones).
DROP FUNCTION public.obtener_resumen_rendiciones(date, date, uuid);

CREATE FUNCTION public.obtener_resumen_rendiciones(
  p_fecha_desde date DEFAULT ((((now() AT TIME ZONE 'America/Argentina/Buenos_Aires'::text))::date - '30 days'::interval))::date,
  p_fecha_hasta date DEFAULT ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires'::text))::date,
  p_transportista_id uuid DEFAULT NULL::uuid)
RETURNS TABLE(fecha date, transportista_id uuid, transportista_nombre text, total_efectivo numeric,
              total_transferencia numeric, total_cheque numeric, total_cuenta_corriente numeric,
              total_tarjeta numeric, total_otros numeric, total_adelanto_sueldo numeric, total_general numeric,
              total_entregas numeric, total_ctascte numeric, cantidad_pedidos bigint, total_entregado numeric,
              total_gastos numeric, cantidad_gastos bigint, estado text, observaciones text, controlada boolean,
              controlada_at timestamp with time zone, controlada_por_nombre text,
              resuelta_at timestamp with time zone, resuelta_por_nombre text, total_pagos_personal numeric,
              total_faltantes_empleados numeric)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sucursal_id BIGINT;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no seleccionada';
  END IF;
  IF NOT es_encargado_o_admin() THEN
    -- #724: el transportista ve sólo su propia fila (null = yo, como
    -- avance_metas_preventista). es_transportista() incluye admin y rol
    -- extra (trampa 4); el admin ya entró por la rama de arriba.
    IF NOT es_transportista() THEN
      RAISE EXCEPTION 'No autorizado';
    END IF;
    IF p_transportista_id IS NOT NULL AND p_transportista_id <> auth.uid() THEN
      RAISE EXCEPTION 'Acceso denegado' USING ERRCODE = '42501';
    END IF;
    p_transportista_id := auth.uid();
  END IF;

  RETURN QUERY
  WITH rp AS (
    -- #1248: de _rendicion_pagos, que para una rendicion cerrada lee su foto.
    SELECT x.*
      FROM public._rendicion_pagos(v_sucursal_id, p_fecha_desde, p_fecha_hasta) x
     WHERE x.t_id IS NOT NULL
       AND (p_transportista_id IS NULL OR x.t_id = p_transportista_id)
  ),
  pagos_agg AS (
    SELECT
      rp.t_id,
      rp.f,
      SUM(CASE WHEN rp.forma_pago = 'efectivo' THEN rp.monto ELSE 0 END)::numeric AS tot_ef,
      SUM(CASE WHEN rp.forma_pago = 'transferencia' THEN rp.monto ELSE 0 END)::numeric AS tot_tr,
      SUM(CASE WHEN rp.forma_pago = 'cheque' THEN rp.monto ELSE 0 END)::numeric AS tot_ch,
      SUM(CASE WHEN rp.forma_pago = 'cuenta_corriente' THEN rp.monto ELSE 0 END)::numeric AS tot_cc,
      SUM(CASE WHEN rp.forma_pago = 'tarjeta' THEN rp.monto ELSE 0 END)::numeric AS tot_tj,
      SUM(CASE WHEN rp.forma_pago NOT IN ('efectivo','transferencia','cheque','cuenta_corriente','tarjeta')
                OR rp.forma_pago IS NULL THEN rp.monto ELSE 0 END)::numeric AS tot_ot,
      SUM(rp.monto)::numeric AS tot_gen,
      SUM(CASE WHEN rp.es_entrega_del_dia THEN rp.monto ELSE 0 END)::numeric AS tot_entregas,
      SUM(CASE WHEN rp.es_entrega_del_dia THEN 0 ELSE rp.monto END)::numeric AS tot_ctascte
    FROM rp
    -- migs 273/276 (#832, #833): las formas no dinerarias no son plata de la rendicion.
    WHERE COALESCE(rp.forma_pago, '') <> 'adelanto_sueldo'
    GROUP BY rp.t_id, rp.f
  ),
  /* mig 273 (#832) · informativo: mismo criterio de atribucion que pagos_agg, pero NO
     aporta filas a fechas_activas (ver el encabezado de la migracion). */
  adelantos_agg AS (
    SELECT rp.t_id, rp.f, SUM(rp.monto)::numeric AS tot_adel
      FROM rp
     WHERE rp.forma_pago = 'adelanto_sueldo'
     GROUP BY rp.t_id, rp.f
  ),
  entregas_agg AS (
    SELECT e.t_id, e.f, e.tot_entregado, e.cant
      FROM public._rendicion_entregas(v_sucursal_id, p_fecha_desde, p_fecha_hasta) e
     WHERE (p_transportista_id IS NULL OR e.t_id = p_transportista_id)
  ),
  gastos_agg AS (
    -- gastos 3: los gastos pagados con la plata de esta rendicion.
    SELECT g.rendicion_transportista_id AS t_id, g.rendicion_fecha AS f,
           SUM(g.monto_total)::numeric AS tot_g, COUNT(*)::bigint AS cant_g
      FROM gastos g
     WHERE g.origen_pago = 'rendicion' AND g.anulado_at IS NULL
       AND g.sucursal_id = v_sucursal_id
       AND g.rendicion_fecha BETWEEN p_fecha_desde AND p_fecha_hasta
       AND (p_transportista_id IS NULL OR g.rendicion_transportista_id = p_transportista_id)
     GROUP BY 1, 2
  ),
  pagos_personal_agg AS (
    -- gastos 5: lo pagado al personal con la plata de esta rendicion. Una
    -- reversion lleva la misma rendicion y lo devuelve. gastos 6: sólo los
    -- pagos; los faltantes van aparte.
    SELECT m.rendicion_transportista_id AS t_id, m.rendicion_fecha AS f,
           (-SUM(m.monto))::numeric AS tot_pp
      FROM empleado_movimientos m
     WHERE m.rendicion_sucursal_id = v_sucursal_id
       AND m.rendicion_fecha BETWEEN p_fecha_desde AND p_fecha_hasta
       AND (p_transportista_id IS NULL OR m.rendicion_transportista_id = p_transportista_id)
       AND m.tipo = 'pago'
     GROUP BY 1, 2
    HAVING SUM(m.monto) <> 0
  ),
  faltantes_agg AS (
    -- gastos 6: lo imputado a empleados al resolver la rendicion. Deshacer lo
    -- compensa con la misma rendicion.
    SELECT m.rendicion_transportista_id AS t_id, m.rendicion_fecha AS f,
           (-SUM(m.monto))::numeric AS tot_fe
      FROM empleado_movimientos m
     WHERE m.rendicion_sucursal_id = v_sucursal_id
       AND m.rendicion_fecha BETWEEN p_fecha_desde AND p_fecha_hasta
       AND (p_transportista_id IS NULL OR m.rendicion_transportista_id = p_transportista_id)
       AND m.tipo = 'faltante'
     GROUP BY 1, 2
    HAVING SUM(m.monto) <> 0
  ),
  /* #1248 · una rendicion cerrada esta siempre en la grilla, aunque lo vivo de
     su dia ya no le deje pagos ni entregas. */
  cerradas AS (
    SELECT rc0.transportista_id AS t_id, rc0.fecha AS f
      FROM rendiciones_control rc0
     WHERE rc0.sucursal_id = v_sucursal_id
       AND rc0.estado IN ('confirmada', 'resuelta')
       AND rc0.fecha BETWEEN p_fecha_desde AND p_fecha_hasta
       AND (p_transportista_id IS NULL OR rc0.transportista_id = p_transportista_id)
  ),
  /* mig 245 (#639) · fechas_activas es el esqueleto de la grilla. gastos_agg ya
     estaba calculado y LEFT-JOINeado abajo, pero no aportaba filas: un
     transportista que un dia solo cargo gastos --sin cobrar ni entregar-- no
     aparecia, y su rendicion de ese dia era invisible para el control. */
  fechas_activas AS (
    SELECT pa.t_id, pa.f FROM pagos_agg pa
    UNION
    SELECT ea.t_id, ea.f FROM entregas_agg ea
    UNION
    SELECT ga.t_id, ga.f FROM gastos_agg ga
    UNION
    SELECT pp.t_id, pp.f FROM pagos_personal_agg pp
    UNION
    SELECT fe.t_id, fe.f FROM faltantes_agg fe
    UNION
    SELECT ce.t_id, ce.f FROM cerradas ce
  )
  SELECT
    fa.f::date AS fecha,
    fa.t_id AS transportista_id,
    tr.nombre::text AS transportista_nombre,
    COALESCE(pagos_agg.tot_ef, 0)::numeric AS total_efectivo,
    COALESCE(pagos_agg.tot_tr, 0)::numeric AS total_transferencia,
    COALESCE(pagos_agg.tot_ch, 0)::numeric AS total_cheque,
    COALESCE(pagos_agg.tot_cc, 0)::numeric AS total_cuenta_corriente,
    COALESCE(pagos_agg.tot_tj, 0)::numeric AS total_tarjeta,
    COALESCE(pagos_agg.tot_ot, 0)::numeric AS total_otros,
    COALESCE(adelantos_agg.tot_adel, 0)::numeric AS total_adelanto_sueldo,
    COALESCE(pagos_agg.tot_gen, 0)::numeric AS total_general,
    COALESCE(pagos_agg.tot_entregas, 0)::numeric AS total_entregas,
    COALESCE(pagos_agg.tot_ctascte, 0)::numeric AS total_ctascte,
    -- #1248: lo entregado de un dia cerrado tambien sale de la foto.
    (CASE WHEN rc.estado IN ('confirmada', 'resuelta') AND rc.cantidad_pedidos_confirmada IS NOT NULL
          THEN rc.cantidad_pedidos_confirmada
          ELSE COALESCE(entregas_agg.cant, 0) END)::bigint AS cantidad_pedidos,
    (CASE WHEN rc.estado IN ('confirmada', 'resuelta') AND rc.total_entregado_confirmado IS NOT NULL
          THEN rc.total_entregado_confirmado
          ELSE COALESCE(entregas_agg.tot_entregado, 0) END)::numeric AS total_entregado,
    COALESCE(gastos_agg.tot_g, 0)::numeric AS total_gastos,
    COALESCE(gastos_agg.cant_g, 0)::bigint AS cantidad_gastos,
    COALESCE(rc.estado, 'pendiente')::text AS estado,
    rc.observaciones,
    (rc.id IS NOT NULL AND COALESCE(rc.estado, 'pendiente') IN ('confirmada','resuelta')) AS controlada,
    rc.controlada_at,
    cp.nombre::text AS controlada_por_nombre,
    rc.resuelta_at,
    rp2.nombre::text AS resuelta_por_nombre,
    COALESCE(pagos_personal_agg.tot_pp, 0)::numeric AS total_pagos_personal,
    COALESCE(faltantes_agg.tot_fe, 0)::numeric AS total_faltantes_empleados
  FROM fechas_activas fa
  JOIN perfiles tr ON tr.id = fa.t_id
  LEFT JOIN pagos_agg ON pagos_agg.t_id = fa.t_id AND pagos_agg.f = fa.f
  LEFT JOIN adelantos_agg ON adelantos_agg.t_id = fa.t_id AND adelantos_agg.f = fa.f
  LEFT JOIN entregas_agg ON entregas_agg.t_id = fa.t_id AND entregas_agg.f = fa.f
  LEFT JOIN gastos_agg ON gastos_agg.t_id = fa.t_id AND gastos_agg.f = fa.f
  LEFT JOIN pagos_personal_agg ON pagos_personal_agg.t_id = fa.t_id AND pagos_personal_agg.f = fa.f
  LEFT JOIN faltantes_agg ON faltantes_agg.t_id = fa.t_id AND faltantes_agg.f = fa.f
  LEFT JOIN rendiciones_control rc
    ON rc.fecha = fa.f
   AND rc.transportista_id = fa.t_id
   AND rc.sucursal_id = v_sucursal_id
  LEFT JOIN perfiles cp ON cp.id = rc.controlada_por
  LEFT JOIN perfiles rp2 ON rp2.id = rc.resuelta_por
  ORDER BY fa.f DESC, tr.nombre ASC;
END;
$$;

-- -------------------------------------------------------------------------
-- 8 · revertir_movimiento_empleado: un faltante no se revierte desde Personal
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.revertir_movimiento_empleado(p_movimiento_id bigint, p_motivo text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_m  empleado_movimientos%ROWTYPE;
  v_e  empleados%ROWTYPE;
  v_id bigint;
BEGIN
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin ve y carga el personal' USING ERRCODE = '42501';
  END IF;
  -- El empleado antes que el movimiento: el mismo orden de locks que
  -- registrar_movimiento_empleado.
  SELECT e.* INTO v_e FROM empleados e JOIN empleado_movimientos m ON m.empleado_id = e.id
   WHERE m.id = p_movimiento_id FOR UPDATE OF e;
  IF NOT FOUND OR NOT public._empleado_visible(v_e.sucursal_id, v_e.de_las_dos) THEN
    RAISE EXCEPTION 'Ese empleado no existe o no lo podés ver';
  END IF;
  IF v_e.usuario_id = auth.uid() THEN
    RAISE EXCEPTION 'Tu propia cuenta la maneja otro admin: no podés cambiar tu arreglo, tu usuario ni tus movimientos';
  END IF;
  SELECT * INTO v_m FROM empleado_movimientos WHERE id = p_movimiento_id;
  IF v_m.tipo = 'pago' AND v_m.liquidacion_id IS NOT NULL THEN
    RAISE EXCEPTION 'Un pago de una liquidación se revierte anulando la liquidación';
  END IF;
  -- gastos 6: lo imputado al resolver una rendicion se deshace todo junto.
  IF v_m.tipo = 'faltante' THEN
    RAISE EXCEPTION 'Un faltante de rendición se deshace desde la rendición, con «Deshacer resolución»';
  END IF;
  IF v_m.tipo NOT IN ('adelanto', 'ajuste', 'pago') THEN
    RAISE EXCEPTION 'Sólo se revierte un movimiento cargado a mano';
  END IF;
  IF v_m.revierte_id IS NOT NULL THEN
    RAISE EXCEPTION 'Un movimiento que revierte a otro no se revierte: cargá uno nuevo';
  END IF;
  IF EXISTS (SELECT 1 FROM empleado_movimientos WHERE revierte_id = v_m.id) THEN
    RAISE EXCEPTION 'Ese movimiento ya está revertido';
  END IF;
  IF p_motivo IS NULL OR btrim(p_motivo) = '' THEN
    RAISE EXCEPTION 'Escribí por qué se revierte';
  END IF;
  IF v_m.rendicion_fecha IS NOT NULL THEN
    PERFORM public._rendicion_bloquear(ARRAY[public._rendicion_clave(v_m.rendicion_transportista_id, v_m.rendicion_fecha,
                                                                     v_m.rendicion_sucursal_id)]);
    IF public.control_rendicion_cerrado(v_m.rendicion_transportista_id, v_m.rendicion_sucursal_id, v_m.rendicion_fecha) THEN
      RAISE EXCEPTION 'Ese pago salió de una rendición ya cerrada: no se revierte, corregilo con un ajuste';
    END IF;
  END IF;
  INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, observacion, revierte_id, creado_por,
                                    rendicion_transportista_id, rendicion_fecha, rendicion_sucursal_id)
  VALUES (v_m.empleado_id, public._tablero_hoy(), v_m.tipo, -v_m.monto, btrim(p_motivo), v_m.id, auth.uid(),
          v_m.rendicion_transportista_id, v_m.rendicion_fecha, v_m.rendicion_sucursal_id)
  RETURNING id INTO v_id;
  RETURN v_id;
END
$$;

-- -------------------------------------------------------------------------
-- 9 · resolver_rendicion: solo de admin, con la diferencia imputada
-- -------------------------------------------------------------------------
-- La firma vieja se dropea: dos sobrecargas con rangos superpuestos dan
-- PGRST203 (trampa 5).
DROP FUNCTION public.resolver_rendicion(date, uuid, text);

CREATE FUNCTION public.resolver_rendicion(p_fecha date, p_transportista_id uuid, p_observaciones text,
                                          p_resolucion jsonb DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sucursal_id  BIGINT;
  v_id           BIGINT;
  v_estado       TEXT;
  v_obs_previas  TEXT;
  v_nombre       TEXT;
  v_tr_nombre    TEXT;
  v_lineas       jsonb := '[]';
  v_vistos       jsonb;
  v_pagos_visto  numeric;
  v_l            jsonb;
  v_monto        numeric;
  v_obs          text;
  v_gasto        jsonb;
  v_emp_ids      bigint[];
  v_e            empleados%ROWTYPE;
  v_eid          bigint;
  v_cambio       text;
  v_disponible   numeric;
  v_rubro_robo   bigint;
  v_mov          bigint;
  v_gid          bigint;
  v_rubro        text;
  v_msg          text;
  v_code         text;
  v_fecha_txt    text := to_char(p_fecha, 'DD/MM/YYYY');
BEGIN
  -- 1 · sucursal y rol (gastos 6: resolver es solo del admin)
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no seleccionada';
  END IF;
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin resuelve una disconformidad' USING ERRCODE = '42501';
  END IF;

  -- 2 · el texto, que hasta ahora exigia solo el front
  IF p_observaciones IS NULL OR btrim(p_observaciones) = '' THEN
    RAISE EXCEPTION 'Escribí cómo se resolvió';
  END IF;

  -- 3 · el transportista es de la sucursal activa. Una rendicion que ya vive en
  --     esta sucursal se resuelve aunque el chofer ya no la tenga, como en
  --     _guardar_gasto (que igual le pide la sucursal a un gasto nuevo).
  IF NOT EXISTS (SELECT 1 FROM usuario_sucursales us
                  WHERE us.usuario_id = p_transportista_id AND us.sucursal_id = v_sucursal_id)
     AND NOT EXISTS (SELECT 1 FROM rendiciones_control rc
                      WHERE rc.transportista_id = p_transportista_id AND rc.fecha = p_fecha
                        AND rc.sucursal_id = v_sucursal_id) THEN
    RAISE EXCEPTION 'Ese transportista no es de esta sucursal';
  END IF;

  -- 4 · formato: {lineas: [...], vistos: [{id, updated_at}], pagos_personal_visto: n}.
  --     Sin p_resolucion (el bundle viejo) no hay lineas ni comparacion.
  IF p_resolucion IS NOT NULL THEN
    BEGIN
      IF jsonb_typeof(p_resolucion) IS DISTINCT FROM 'object'
         OR jsonb_typeof(p_resolucion->'lineas') IS DISTINCT FROM 'array'
         OR jsonb_typeof(p_resolucion->'vistos') IS DISTINCT FROM 'array'
         OR jsonb_typeof(p_resolucion->'pagos_personal_visto') IS DISTINCT FROM 'number' THEN
        RAISE EXCEPTION 'formato';
      END IF;
      v_vistos := p_resolucion->'vistos';
      v_pagos_visto := (p_resolucion->>'pagos_personal_visto')::numeric;
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_vistos) e
                  WHERE jsonb_typeof(e) <> 'object' OR jsonb_typeof(e->'id') IS DISTINCT FROM 'number'
                     OR jsonb_typeof(e->'updated_at') IS DISTINCT FROM 'string') THEN
        RAISE EXCEPTION 'formato';
      END IF;
      PERFORM (e->>'id')::bigint, (e->>'updated_at')::timestamptz FROM jsonb_array_elements(v_vistos) e;
      -- Cada linea: causal y monto numero; el empleado, numero o null (falta
      -- elegirlo); la observacion, texto o null; el gasto, un objeto sin id y
      -- con monto_total igual al de la linea.
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_resolucion->'lineas') l
                  WHERE jsonb_typeof(l) <> 'object'
                     OR l->>'causal' IS NULL OR l->>'causal' NOT IN ('empleado', 'robo_perdida', 'gasto_no_cargado')
                     OR jsonb_typeof(l->'monto') IS DISTINCT FROM 'number'
                     OR jsonb_typeof(COALESCE(l->'observacion', 'null')) NOT IN ('string', 'null')
                     OR (l->>'causal' = 'empleado'
                         AND jsonb_typeof(COALESCE(l->'empleado_id', 'null')) NOT IN ('number', 'null'))
                     OR (l->>'causal' = 'gasto_no_cargado'
                         AND (jsonb_typeof(l->'gasto') IS DISTINCT FROM 'object'
                              OR jsonb_typeof(COALESCE(l->'gasto'->'id', 'null')) <> 'null'
                              OR round((l->'gasto'->>'monto_total')::numeric, 2) IS DISTINCT FROM round((l->>'monto')::numeric, 2)))) THEN
        RAISE EXCEPTION 'formato';
      END IF;
      PERFORM (l->>'empleado_id')::bigint FROM jsonb_array_elements(p_resolucion->'lineas') l;
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_resolucion->'lineas') l
                  WHERE abs((l->>'monto')::numeric) > 999999999999.99) THEN
        RAISE EXCEPTION 'formato';
      END IF;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'La resolución viene con un formato inválido';
    END;
    v_lineas := p_resolucion->'lineas';
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_lineas) l WHERE round((l->>'monto')::numeric, 2) <= 0) THEN
      RAISE EXCEPTION 'Cada línea lleva un monto mayor a 0';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_lineas) l
                WHERE l->>'causal' = 'empleado' AND l->>'empleado_id' IS NULL) THEN
      RAISE EXCEPTION 'Elegí a qué empleado se le carga el faltante';
    END IF;
  END IF;

  -- 5 · los empleados, antes que la rendicion: el orden de
  --     registrar_movimiento_empleado.
  v_emp_ids := ARRAY(SELECT DISTINCT (l->>'empleado_id')::bigint FROM jsonb_array_elements(v_lineas) l
                      WHERE l->>'causal' = 'empleado' ORDER BY 1);
  FOREACH v_eid IN ARRAY v_emp_ids LOOP
    SELECT * INTO v_e FROM empleados WHERE id = v_eid FOR UPDATE;
    IF NOT FOUND OR NOT public._empleado_visible(v_e.sucursal_id, v_e.de_las_dos) THEN
      RAISE EXCEPTION 'Ese empleado no existe o no lo podés ver';
    END IF;
    IF NOT v_e.activo THEN
      RAISE EXCEPTION 'Ese empleado está dado de baja';
    END IF;
    IF v_e.sucursal_id <> v_sucursal_id AND NOT v_e.de_las_dos THEN
      RAISE EXCEPTION 'Ese empleado no es de esta sucursal';
    END IF;
    IF v_e.usuario_id = auth.uid() THEN
      RAISE EXCEPTION 'Tu propia cuenta la maneja otro admin: no podés cargarte un faltante';
    END IF;
  END LOOP;

  -- 6 · la rendicion. Un gasto que se esta guardando desde Gastos sobre esta
  --     rendicion termina antes (gastos 3).
  PERFORM public._rendicion_bloquear(ARRAY[public._rendicion_clave(p_transportista_id, p_fecha, v_sucursal_id)]);

  -- 7 · el control: tiene que existir y estar en disconformidad
  SELECT id, estado, observaciones
    INTO v_id, v_estado, v_obs_previas
  FROM rendiciones_control
  WHERE fecha = p_fecha
    AND transportista_id = p_transportista_id
    AND sucursal_id = v_sucursal_id;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'No existe rendicion para (%, %)', p_fecha, p_transportista_id;
  END IF;

  IF v_estado <> 'disconformidad' THEN
    RAISE EXCEPTION 'Solo se pueden resolver rendiciones en disconformidad (estado actual: %)', v_estado;
  END IF;

  -- Una disconformidad no tiene lineas vivas: confirmar_rendicion no la deja
  -- volver con ellas, y deshacer las anula todas.
  IF EXISTS (SELECT 1 FROM rendicion_faltantes f
              WHERE f.rendicion_sucursal_id = v_sucursal_id
                AND f.rendicion_transportista_id = p_transportista_id
                AND f.rendicion_fecha = p_fecha
                AND f.anulada_at IS NULL) THEN
    RAISE EXCEPTION 'La resolución viene con un formato inválido';
  END IF;

  -- 8 · lo que vio el modal
  IF p_resolucion IS NOT NULL THEN
    v_cambio := public._rendicion_cambio_visto(v_sucursal_id, p_transportista_id, p_fecha, v_vistos,
                                               v_pagos_visto, 0);
    IF v_cambio = 'gastos' THEN
      RAISE EXCEPTION 'Los gastos de esta rendición cambiaron mientras la resolvías: tocá Refrescar y volvé a abrir';
    ELSIF v_cambio = 'pagos' THEN
      RAISE EXCEPTION 'Los pagos al personal de esta rendición cambiaron mientras la resolvías: tocá Refrescar y volvé a abrir';
    ELSIF v_cambio IS NOT NULL THEN
      RAISE EXCEPTION 'La resolución viene con un formato inválido';
    END IF;
  END IF;

  IF jsonb_array_length(v_lineas) > 0 THEN
    -- 9 · el tope: lo imputado no deja el efectivo a entregar en negativo. Es
    --     la cuenta del front: el efectivo cobrado, menos los gastos, los pagos
    --     al personal y los faltantes a cargo de empleados.
    v_disponible :=
        COALESCE((SELECT SUM(x.monto) FROM public._rendicion_pagos(v_sucursal_id, p_fecha, p_fecha) x
                   WHERE x.t_id = p_transportista_id AND x.forma_pago = 'efectivo'), 0)
      - COALESCE((SELECT SUM(g.monto_total) FROM gastos g
                   WHERE g.origen_pago = 'rendicion' AND g.anulado_at IS NULL
                     AND g.sucursal_id = v_sucursal_id
                     AND g.rendicion_transportista_id = p_transportista_id
                     AND g.rendicion_fecha = p_fecha), 0)
      + COALESCE((SELECT SUM(m.monto) FROM empleado_movimientos m
                   WHERE m.rendicion_sucursal_id = v_sucursal_id
                     AND m.rendicion_transportista_id = p_transportista_id
                     AND m.rendicion_fecha = p_fecha
                     AND m.tipo IN ('pago', 'faltante')), 0);
    IF round(v_disponible - (SELECT SUM(round((l->>'monto')::numeric, 2)) FROM jsonb_array_elements(v_lineas) l), 2) < 0 THEN
      RAISE EXCEPTION 'Lo imputado supera lo que había para entregar';
    END IF;

    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_lineas) l WHERE l->>'causal' = 'robo_perdida') THEN
      SELECT id INTO v_rubro_robo FROM gasto_rubros
       WHERE lower(btrim(nombre)) = 'faltantes de caja' AND activo;
      IF v_rubro_robo IS NULL THEN
        RAISE EXCEPTION 'Falta el rubro «Faltantes de caja»: dalo de alta o reactivalo en Gastos';
      END IF;
    END IF;
    SELECT nombre INTO v_tr_nombre FROM perfiles WHERE id = p_transportista_id;
  END IF;

  -- 10 · las lineas, en el orden en que vinieron
  FOR v_l IN SELECT l FROM jsonb_array_elements(v_lineas) WITH ORDINALITY AS x(l, n) ORDER BY n LOOP
    v_monto := round((v_l->>'monto')::numeric, 2);
    v_obs   := NULLIF(btrim(v_l->>'observacion'), '');
    v_mov   := NULL;
    v_gid   := NULL;
    IF v_l->>'causal' = 'empleado' THEN
      INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, observacion, creado_por,
                                        rendicion_transportista_id, rendicion_fecha, rendicion_sucursal_id)
      VALUES ((v_l->>'empleado_id')::bigint, public._tablero_hoy(), 'faltante', -v_monto, v_obs, auth.uid(),
              p_transportista_id, p_fecha, v_sucursal_id)
      RETURNING id INTO v_mov;
    ELSE
      IF v_l->>'causal' = 'robo_perdida' THEN
        v_gasto := jsonb_build_object(
          'fecha', p_fecha, 'rubro_id', v_rubro_robo, 'monto_total', v_monto, 'comprobante', 'ninguno',
          'observacion', 'Robo o pérdida · diferencia de la rendición de ' || COALESCE(v_tr_nombre, 'transportista')
                         || ' del ' || v_fecha_txt || COALESCE(' · ' || v_obs, ''));
      ELSE
        v_gasto := v_l->'gasto';
        v_gasto := v_gasto || jsonb_build_object(
          'observacion', COALESCE(NULLIF(btrim(v_gasto->>'observacion'), '') || ' · ', '')
                         || 'Diferencia de la rendición del ' || v_fecha_txt);
      END IF;
      -- Lo de la rendicion lo pone el server, como el paso 7 de confirmar_rendicion.
      -- Nunca compartido: deshacer lo anula con la regla de _anular_gasto, y un
      -- compartido de otro admin no lo podria anular.
      v_gasto := v_gasto || jsonb_build_object('compartido', false,
                                               'origen_pago', 'rendicion',
                                               'rendicion_transportista_id', p_transportista_id,
                                               'rendicion_fecha', p_fecha,
                                               'sucursal_id', v_sucursal_id);
      BEGIN
        v_gid := public._guardar_gasto(v_gasto, true);
      EXCEPTION WHEN others THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_code = RETURNED_SQLSTATE;
        v_rubro := NULL;
        SELECT r.nombre INTO v_rubro FROM gasto_rubros r WHERE r.id::text = v_gasto->>'rubro_id';
        RAISE EXCEPTION USING ERRCODE = v_code,
          MESSAGE = COALESCE('En la línea de ' || v_rubro || ': ', 'En una línea de la diferencia: ') || v_msg;
      END;
    END IF;
    INSERT INTO rendicion_faltantes (rendicion_transportista_id, rendicion_fecha, rendicion_sucursal_id, causal, monto,
                                     empleado_id, movimiento_id, gasto_id, observacion, creado_por)
    VALUES (p_transportista_id, p_fecha, v_sucursal_id, v_l->>'causal', v_monto,
            CASE WHEN v_mov IS NOT NULL THEN (v_l->>'empleado_id')::bigint END, v_mov, v_gid, v_obs, auth.uid());
  END LOOP;

  -- 11 · resuelta, con el sello de hoy. La foto la toma trg_rendiciones_control_foto.
  SELECT nombre INTO v_nombre FROM perfiles WHERE id = auth.uid();

  -- #1298: la hora que lee el encargado es la argentina, no la del servidor.
  UPDATE rendiciones_control
     SET estado = 'resuelta',
         observaciones = COALESCE(v_obs_previas, '')
           || CASE WHEN v_obs_previas IS NOT NULL AND length(v_obs_previas) > 0 THEN E'\n\n' ELSE '' END
           || '[Resuelta por ' || COALESCE(v_nombre, 'usuario') || ' el '
           || to_char(now() AT TIME ZONE 'America/Argentina/Buenos_Aires', 'DD/MM/YYYY HH24:MI')
           || ']: ' || p_observaciones,
         resuelta_at = now(),
         resuelta_por = auth.uid()
   WHERE id = v_id;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION public.resolver_rendicion(date, uuid, text, jsonb) IS
  'Resuelve una rendicion en disconformidad (solo admin). p_resolucion trae las lineas de la diferencia (empleado, robo_perdida, gasto_no_cargado) y lo que vio el modal; NULL resuelve solo con el texto. Gastos 6.';

-- -------------------------------------------------------------------------
-- 10 · deshacer_resolucion_rendicion
-- -------------------------------------------------------------------------
-- Deshace todo lo que imputo la resolucion y vuelve la rendicion a
-- disconformidad. Sin fila de control (se reabrio sola y esta pendiente), no
-- crea ninguna.
CREATE FUNCTION public.deshacer_resolucion_rendicion(p_fecha date, p_transportista_id uuid, p_motivo text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sucursal_id BIGINT;
  v_emp_ids     bigint[];
  v_id          bigint;
  v_estado      text;
  v_obs_previas text;
  v_nombre      text;
  v_motivo      text := btrim(p_motivo);
  v_f           rendicion_faltantes%ROWTYPE;
  v_m           empleado_movimientos%ROWTYPE;
BEGIN
  -- 1 · sucursal, rol y motivo
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no seleccionada';
  END IF;
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin deshace una resolución' USING ERRCODE = '42501';
  END IF;
  IF v_motivo IS NULL OR v_motivo = '' THEN
    RAISE EXCEPTION 'Escribí por qué se deshace';
  END IF;

  -- 2 · el transportista es de la sucursal activa, o la rendicion o sus lineas
  --     ya viven en ella: una deuda mal cargada se deshace aunque el chofer ya
  --     no tenga la sucursal.
  IF NOT EXISTS (SELECT 1 FROM usuario_sucursales us
                  WHERE us.usuario_id = p_transportista_id AND us.sucursal_id = v_sucursal_id)
     AND NOT EXISTS (SELECT 1 FROM rendiciones_control rc
                      WHERE rc.transportista_id = p_transportista_id AND rc.fecha = p_fecha
                        AND rc.sucursal_id = v_sucursal_id)
     AND NOT EXISTS (SELECT 1 FROM rendicion_faltantes f
                      WHERE f.rendicion_sucursal_id = v_sucursal_id
                        AND f.rendicion_transportista_id = p_transportista_id
                        AND f.rendicion_fecha = p_fecha
                        AND f.anulada_at IS NULL) THEN
    RAISE EXCEPTION 'Ese transportista no es de esta sucursal';
  END IF;

  -- 3 · los empleados de las lineas vivas, antes que la rendicion
  v_emp_ids := ARRAY(SELECT DISTINCT f.empleado_id FROM rendicion_faltantes f
                      WHERE f.rendicion_sucursal_id = v_sucursal_id
                        AND f.rendicion_transportista_id = p_transportista_id
                        AND f.rendicion_fecha = p_fecha
                        AND f.anulada_at IS NULL
                        AND f.empleado_id IS NOT NULL
                      ORDER BY 1);
  PERFORM 1 FROM empleados WHERE id = ANY (v_emp_ids) ORDER BY id FOR UPDATE;

  -- 4 · la rendicion, y se releen las lineas: si nombran a otro empleado, la
  --     resolucion cambio entre las dos lecturas.
  PERFORM public._rendicion_bloquear(ARRAY[public._rendicion_clave(p_transportista_id, p_fecha, v_sucursal_id)]);
  IF EXISTS (SELECT 1 FROM rendicion_faltantes f
              WHERE f.rendicion_sucursal_id = v_sucursal_id
                AND f.rendicion_transportista_id = p_transportista_id
                AND f.rendicion_fecha = p_fecha
                AND f.anulada_at IS NULL
                AND f.empleado_id IS NOT NULL
                AND f.empleado_id <> ALL (v_emp_ids)) THEN
    RAISE EXCEPTION 'La resolución cambió mientras la deshacías: volvé a intentar';
  END IF;
  -- Nadie se carga movimientos a si mismo: tampoco la compensacion.
  IF EXISTS (SELECT 1 FROM empleados WHERE id = ANY (v_emp_ids) AND usuario_id = auth.uid()) THEN
    RAISE EXCEPTION 'Tu propia cuenta la maneja otro admin: no podés cambiar tu arreglo, tu usuario ni tus movimientos';
  END IF;

  -- 5 · algo para deshacer: una resuelta, o lineas vivas
  SELECT id, estado, observaciones INTO v_id, v_estado, v_obs_previas
    FROM rendiciones_control
   WHERE fecha = p_fecha AND transportista_id = p_transportista_id AND sucursal_id = v_sucursal_id
   FOR UPDATE;
  IF v_estado IS DISTINCT FROM 'resuelta'
     AND NOT EXISTS (SELECT 1 FROM rendicion_faltantes f
                      WHERE f.rendicion_sucursal_id = v_sucursal_id
                        AND f.rendicion_transportista_id = p_transportista_id
                        AND f.rendicion_fecha = p_fecha
                        AND f.anulada_at IS NULL) THEN
    RAISE EXCEPTION 'No hay nada para deshacer en esta rendición';
  END IF;

  -- 6 · primero la rendicion vuelve a disconformidad: deja de estar cerrada y
  --     el trigger le suelta la foto.
  IF v_id IS NOT NULL THEN
    SELECT nombre INTO v_nombre FROM perfiles WHERE id = auth.uid();
    UPDATE rendiciones_control
       SET estado = 'disconformidad',
           resuelta_at = NULL,
           resuelta_por = NULL,
           observaciones = COALESCE(v_obs_previas, '')
             || CASE WHEN v_obs_previas IS NOT NULL AND length(v_obs_previas) > 0 THEN E'\n\n' ELSE '' END
             || '[Deshecha por ' || COALESCE(v_nombre, 'usuario') || ' el '
             || to_char(now() AT TIME ZONE 'America/Argentina/Buenos_Aires', 'DD/MM/YYYY HH24:MI')
             || ']: ' || v_motivo
     WHERE id = v_id;
  END IF;

  -- 7 · cada linea: se anula y despues se compensa la deuda o se anula el gasto
  --     (con la linea ya anulada, la guarda de gastos lo deja pasar).
  FOR v_f IN SELECT * FROM rendicion_faltantes f
              WHERE f.rendicion_sucursal_id = v_sucursal_id
                AND f.rendicion_transportista_id = p_transportista_id
                AND f.rendicion_fecha = p_fecha
                AND f.anulada_at IS NULL
              ORDER BY f.id
  LOOP
    UPDATE rendicion_faltantes
       SET anulada_at = now(), anulada_por = auth.uid(), motivo_anulacion = v_motivo
     WHERE id = v_f.id;
    IF v_f.causal = 'empleado' THEN
      SELECT * INTO v_m FROM empleado_movimientos WHERE id = v_f.movimiento_id;
      INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, observacion, revierte_id, creado_por,
                                        rendicion_transportista_id, rendicion_fecha, rendicion_sucursal_id)
      VALUES (v_m.empleado_id, public._tablero_hoy(), 'faltante', -v_m.monto, v_motivo, v_m.id, auth.uid(),
              v_m.rendicion_transportista_id, v_m.rendicion_fecha, v_m.rendicion_sucursal_id);
    ELSE
      PERFORM public._anular_gasto(v_f.gasto_id, 'Se deshizo la resolución de la diferencia: ' || v_motivo, true);
    END IF;
  END LOOP;
END;
$$;

-- -------------------------------------------------------------------------
-- 11 · obtener_faltantes_rendiciones
-- -------------------------------------------------------------------------
-- Las lineas vivas de las rendiciones del rango, con los roles de
-- obtener_gastos_rendiciones: encargado y admin ven la sucursal activa, y el
-- transportista solo lo suyo (null = yo).
CREATE FUNCTION public.obtener_faltantes_rendiciones(p_fecha_desde date, p_fecha_hasta date,
                                                     p_transportista_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
           'empleado', CASE WHEN e.id IS NULL THEN NULL
                            ELSE jsonb_build_object('id', e.id, 'nombre', e.nombre) END,
           'gasto_id', f.gasto_id, 'rubro_nombre', r.nombre,
           'creado_por_nombre', pf.nombre, 'created_at', f.created_at)
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
$$;

-- -------------------------------------------------------------------------
-- 12 · Permisos
-- -------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.rendicion_faltantes_guarda_gasto() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._rendicion_cambio_visto(bigint, uuid, date, jsonb, numeric, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._rendicion_cambio_visto(bigint, uuid, date, jsonb, numeric, numeric) TO service_role;

REVOKE ALL ON FUNCTION public.obtener_resumen_rendiciones(date, date, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.resolver_rendicion(date, uuid, text, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.deshacer_resolucion_rendicion(date, uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.obtener_faltantes_rendiciones(date, date, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.obtener_resumen_rendiciones(date, date, uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.resolver_rendicion(date, uuid, text, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.deshacer_resolucion_rendicion(date, uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.obtener_faltantes_rendiciones(date, date, uuid) TO authenticated, service_role;

-- -------------------------------------------------------------------------
-- 13 · Verificacion estructural
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  v_f text;
BEGIN
  IF to_regprocedure('public.resolver_rendicion(date,uuid,text)') IS NOT NULL
     OR (SELECT count(*) FROM pg_proc WHERE proname = 'resolver_rendicion' AND pronamespace = 'public'::regnamespace) <> 1 THEN
    RAISE EXCEPTION 'gastos_6: tiene que quedar una sola resolver_rendicion, la de cuatro argumentos';
  END IF;
  FOREACH v_f IN ARRAY ARRAY['public.resolver_rendicion(date,uuid,text,jsonb)',
                             'public.deshacer_resolucion_rendicion(date,uuid,text)',
                             'public.obtener_faltantes_rendiciones(date,date,uuid)',
                             'public.obtener_resumen_rendiciones(date,date,uuid)',
                             'public._rendicion_cambio_visto(bigint,uuid,date,jsonb,numeric,numeric)',
                             'public.rendicion_faltantes_guarda_gasto()'] LOOP
    IF has_function_privilege('anon', v_f, 'EXECUTE') THEN
      RAISE EXCEPTION 'gastos_6: anon ejecuta %', v_f;
    END IF;
  END LOOP;
  IF has_function_privilege('authenticated', 'public._rendicion_cambio_visto(bigint,uuid,date,jsonb,numeric,numeric)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.rendicion_faltantes_guarda_gasto()', 'EXECUTE') THEN
    RAISE EXCEPTION 'gastos_6: authenticated ejecuta un helper de server';
  END IF;
  IF has_table_privilege('anon', 'public.rendicion_faltantes', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
     OR has_table_privilege('authenticated', 'public.rendicion_faltantes', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') THEN
    RAISE EXCEPTION 'gastos_6: rendicion_faltantes tiene privilegios para anon o authenticated';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM gasto_rubros WHERE lower(btrim(nombre)) = 'faltantes de caja' AND activo) THEN
    RAISE EXCEPTION 'gastos_6: el rubro «Faltantes de caja» no existe o esta dado de baja';
  END IF;
END
$verif$;
