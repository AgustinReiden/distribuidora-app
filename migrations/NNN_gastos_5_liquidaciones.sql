-- =========================================================================
-- NNN · GASTOS 5 · LIQUIDACIONES Y COMISIONES CONGELADAS (entrega 4 de 5)
--
-- Diseno: docs/superpowers/specs/2026-10-28-gastos-y-cuentas-del-personal-design.md
-- Plan:   docs/superpowers/plans/2026-11-02-gastos-4-liquidaciones.md (Tarea 2)
-- Ensayo: scripts/test-gastos-5.sql
--
-- Liquidar cierra un periodo de un empleado: suma a su cuenta el sueldo, las
-- comisiones y los ajustes, y registra el pago en la misma accion.
--
-- QUE AGREGA
--   * empleado_liquidaciones, empleado_liquidacion_conceptos y
--     empleado_liquidacion_lineas, de server como las de la entrega 3.
--   * _comision_lineas: la comision por linea sale de calcular_comisiones y la
--     usan las dos. Abajo se prueba que calcular_comisiones da lo mismo que
--     antes en cada mes de 2026, y si un mes difiere la migracion aborta.
--   * Las RPCs previsualizar_liquidacion, liquidar_empleado, anular_liquidacion
--     y obtener_liquidacion, el pago suelto, y personal_por_mes para #1269.
--   * Dos guardas por trigger: un arreglo o una baja que caen dentro de lo ya
--     liquidado se rechazan, sea cual sea el camino.
--
-- POR QUE LA CLAVE DE UNA LINEA NO ES SU ID. actualizar_pedido_items borra y
-- reinserta las lineas, asi que cada edicion les cambia el id. La clave es
-- producto + combo + origen de precio: misma clave quiere decir misma regla,
-- asi que se agrupa y se suma.
--
-- COMO SE LEE EL LIBRO. empleado_liquidacion_lineas guarda deltas: la primera
-- fila de una linea lleva su base y las siguientes, la diferencia. Lo congelado
-- es la suma de las filas vigentes. Un ajuste no pisa nada, y anular una
-- liquidacion es marcar sus filas como no vigentes. Cada fila guarda el
-- vendedor del pedido, porque pedidos.usuario_id cambia: lo vivo vale para esa
-- foto solo si el pedido sigue siendo de ese vendedor, y si no al anterior le
-- sale como ajuste y al nuevo le entra como un pedido mas.
--
-- LA RENDICION. Un pago puede salir de la plata de una rendicion pendiente. El
-- movimiento guarda la rendicion (transportista, dia y sucursal), y
-- obtener_resumen_rendiciones suma un total por rendicion, sin nombres. Una
-- rendicion cerrada no cambia nunca: al anular una liquidacion pagada con ella
-- el pago queda, y la liquidacion nueva lo descuenta sola. Como cambia lo que
-- se entrega, confirmar_rendicion compara lo pagado con lo que vio el modal, con
-- la misma regla que los gastos.
--
-- DESPLIEGUE. obtener_resumen_rendiciones suma una columna al final, que un
-- bundle viejo ignora. confirmar_rendicion no cambia de firma, pero un bundle
-- viejo no manda lo que vio de los pagos: si la rendicion tiene alguno, no la
-- cierra hasta refrescar. Las RPCs nuevas las usa recien el bundle nuevo. Crear las
-- FKs toma un lock breve sobre pedidos y perfiles: con lock_timeout de 5s, si
-- choca se reintenta. Se aplica fuera del horario de cierre de rendiciones.
-- =========================================================================

SET LOCAL lock_timeout = '5s';

-- -------------------------------------------------------------------------
-- 0 · Las funciones que se reescriben son las de hoy
-- -------------------------------------------------------------------------
-- md5(prosrc) de prod al 2026-11-02. Las de la 430 llevan CRLF en prod.
DO $vivas$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('public.calcular_comisiones(date,date,bigint[])', '40b1b721846688a357b452bcb1c7c5c9'),
      ('public.obtener_resumen_rendiciones(date,date,uuid)', '06aae115f4ac237d59623f1b0ff7a886'),
      ('public._empleado_json(empleados)', 'c164580110b99447eb285b86b202c7c6'),
      ('public.obtener_cuenta_empleado(bigint)', '44334922227243cf5579ff63c44301ac'),
      ('public.registrar_movimiento_empleado(bigint,jsonb)', 'dfd8bc320f8684c8058132be4f6c4f7e'),
      ('public.revertir_movimiento_empleado(bigint,text)', '568c4c4addc9253637e34273c5b779b9'),
      ('public.auditoria_comision_mes_cerrado()', '9ff7f5190c33ad1bbd04931c54b5d506'),
      ('public.confirmar_rendicion(date,uuid,text,jsonb,text)', 'd56e43a8227cdeb00a10d3a6e2320a65')) AS v(firma, md5)
  LOOP
    IF to_regprocedure(r.firma) IS NULL
       OR (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure(r.firma)) <> r.md5 THEN
      RAISE EXCEPTION '% no es la de prod del 2026-11-02: rehacer la migracion sobre la definicion viva', r.firma;
    END IF;
  END LOOP;
END
$vivas$;

-- La foto de calcular_comisiones antes de tocarla: cada mes de 2026, por
-- sucursal. La compara el bloque $despues$. Molde del $ensayo$ de la 241.
CREATE TEMP TABLE _comisiones_antes (admin uuid, suc bigint, mes date, j jsonb);

DO $antes$
DECLARE
  v_admin uuid;
BEGIN
  SELECT pf.id INTO v_admin FROM perfiles pf
   WHERE pf.rol = 'admin' AND pf.activo
     AND (SELECT count(*) FROM usuario_sucursales us WHERE us.usuario_id = pf.id AND us.sucursal_id IN (1, 2)) = 2
   ORDER BY pf.id LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'hace falta un admin de las dos sucursales para probar calcular_comisiones';
  END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  INSERT INTO _comisiones_antes
  SELECT v_admin, s, m::date, public.calcular_comisiones(m::date, (m + interval '1 month - 1 day')::date, ARRAY[s])
    FROM unnest(ARRAY[1, 2]::bigint[]) AS s
   CROSS JOIN generate_series(DATE '2026-01-01', DATE '2026-12-01', interval '1 month') AS m;
  PERFORM set_config('request.jwt.claims', '', true);
END
$antes$;

-- -------------------------------------------------------------------------
-- 1 · Las tablas
-- -------------------------------------------------------------------------
-- sucursal_al_liquidar no se llama sucursal_id a proposito: es una foto del
-- empleado, no la sucursal de la fila. Con ese nombre, empleado_id seria un par
-- de auditoria_sucursal_cruzada y una FK compuesta frenaria cambiarle la
-- sucursal al empleado.
CREATE TABLE public.empleado_liquidaciones (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  empleado_id          bigint NOT NULL REFERENCES public.empleados(id),
  desde                date NOT NULL,
  hasta                date NOT NULL,
  frecuencia           text NOT NULL CHECK (frecuencia IN ('semanal', 'mensual')),
  sucursal_al_liquidar bigint NOT NULL REFERENCES public.sucursales(id),
  de_las_dos           boolean NOT NULL,
  saldo_anterior       numeric(14,2) NOT NULL,
  a_pagar              numeric(14,2) NOT NULL,
  pagado               numeric(14,2) NOT NULL CHECK (pagado >= 0),
  fecha_pago           date NOT NULL,
  creado_por           uuid NOT NULL,
  created_at           timestamptz NOT NULL DEFAULT now(),
  anulada_at           timestamptz,
  anulada_por          uuid,
  motivo_anulacion     text,
  CONSTRAINT empleado_liquidaciones_periodo CHECK (hasta >= desde),
  CONSTRAINT empleado_liquidaciones_anulada CHECK ((anulada_at IS NULL) = (motivo_anulacion IS NULL))
);

CREATE UNIQUE INDEX empleado_liquidaciones_periodo_key ON public.empleado_liquidaciones (empleado_id, desde)
  WHERE anulada_at IS NULL;

COMMENT ON TABLE public.empleado_liquidaciones IS
  'Una por empleado y periodo: cierra el periodo, suma sueldo, comisiones y ajustes a la cuenta y registra el pago (gastos 5). Tabla de server: se lee y se escribe solo por las RPCs de Personal.';
COMMENT ON COLUMN public.empleado_liquidaciones.sucursal_al_liquidar IS
  'Foto del empleado al liquidar, no la sucursal de la fila: por eso no se llama sucursal_id.';

-- La base para sumar aguinaldo y lo demas sin rehacer tablas. detalle: en el
-- sueldo {arreglo_id, propuesto, motivo}; en la comision y el ajuste {pedidos,
-- base}. El de sueldo va aunque de 0: guarda el propuesto y el motivo.
CREATE TABLE public.empleado_liquidacion_conceptos (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  liquidacion_id bigint NOT NULL REFERENCES public.empleado_liquidaciones(id),
  concepto       text NOT NULL CHECK (concepto IN ('sueldo', 'comision', 'ajuste_comision')),
  monto          numeric(14,2) NOT NULL,
  detalle        jsonb NOT NULL DEFAULT '{}',
  CONSTRAINT empleado_liquidacion_conceptos_key UNIQUE (liquidacion_id, concepto)
);

COMMENT ON TABLE public.empleado_liquidacion_conceptos IS
  'Los conceptos de cada liquidacion: sueldo, comision y ajuste de comision (gastos 5). Tabla de server.';

CREATE TABLE public.empleado_liquidacion_lineas (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  liquidacion_id bigint NOT NULL REFERENCES public.empleado_liquidaciones(id),
  empleado_id    bigint NOT NULL REFERENCES public.empleados(id),
  pedido_id      bigint NOT NULL REFERENCES public.pedidos(id),
  usuario_id     uuid NOT NULL,
  clave          text NOT NULL,
  producto_id    bigint,
  combo_id       bigint,
  origen_precio  text,
  regla_id       bigint,
  pct            numeric(5,2) NOT NULL,
  base           numeric(16,6) NOT NULL,
  comision       numeric(16,6) NOT NULL,
  tipo           text NOT NULL CHECK (tipo IN ('inicial', 'linea_nueva', 'ajuste')),
  motivo         text,
  entregado_el   date NOT NULL,
  vigente        boolean NOT NULL DEFAULT true,
  CONSTRAINT empleado_liquidacion_lineas_motivo CHECK ((tipo = 'inicial') = (motivo IS NULL))
);

CREATE UNIQUE INDEX empleado_liquidacion_lineas_key ON public.empleado_liquidacion_lineas (pedido_id, clave, usuario_id)
  WHERE tipo <> 'ajuste' AND vigente;
CREATE INDEX empleado_liquidacion_lineas_empleado_idx ON public.empleado_liquidacion_lineas (empleado_id) WHERE vigente;
CREATE INDEX empleado_liquidacion_lineas_liquidacion_idx ON public.empleado_liquidacion_lineas (liquidacion_id);

COMMENT ON TABLE public.empleado_liquidacion_lineas IS
  'La foto de las comisiones: un libro de deltas por pedido, clave y vendedor. Lo congelado es la suma de las filas vigentes (gastos 5). Tabla de server.';

ALTER TABLE public.empleado_movimientos
  ADD COLUMN liquidacion_id bigint REFERENCES public.empleado_liquidaciones(id),
  ADD COLUMN rendicion_transportista_id uuid REFERENCES public.perfiles(id),
  ADD COLUMN rendicion_fecha date,
  ADD COLUMN rendicion_sucursal_id bigint REFERENCES public.sucursales(id),
  DROP CONSTRAINT empleado_movimientos_tipo_check,
  ADD CONSTRAINT empleado_movimientos_tipo_check
    CHECK (tipo IN ('mercaderia', 'reintegro', 'adelanto', 'ajuste', 'sueldo', 'comision', 'ajuste_comision', 'pago')),
  DROP CONSTRAINT empleado_movimientos_revierte_a_mano,
  ADD CONSTRAINT empleado_movimientos_revierte_a_mano
    CHECK (revierte_id IS NULL OR tipo NOT IN ('mercaderia', 'reintegro')),
  ADD CONSTRAINT empleado_movimientos_de_liquidacion
    CHECK (tipo NOT IN ('sueldo', 'comision', 'ajuste_comision') OR liquidacion_id IS NOT NULL),
  ADD CONSTRAINT empleado_movimientos_pago_negativo CHECK (tipo <> 'pago' OR revierte_id IS NOT NULL OR monto < 0),
  ADD CONSTRAINT empleado_movimientos_rendicion_entera
    CHECK ((rendicion_fecha IS NULL) = (rendicion_transportista_id IS NULL)
           AND (rendicion_fecha IS NULL) = (rendicion_sucursal_id IS NULL)),
  ADD CONSTRAINT empleado_movimientos_rendicion_pago CHECK (rendicion_fecha IS NULL OR tipo = 'pago');

CREATE INDEX empleado_movimientos_liquidacion_idx ON public.empleado_movimientos (liquidacion_id)
  WHERE liquidacion_id IS NOT NULL;
CREATE INDEX empleado_movimientos_rendicion_idx ON public.empleado_movimientos (rendicion_sucursal_id, rendicion_fecha)
  WHERE rendicion_fecha IS NOT NULL;

COMMENT ON TABLE public.empleado_movimientos IS
  'La cuenta del empleado: un libro con signo (+ la empresa le debe, - el le debe). La mercaderia y el reintegro los asientan los triggers de pagos y gastos; el adelanto, el ajuste y el pago suelto, a mano; el sueldo, la comision, el ajuste de comision y el pago, la liquidacion. Nada se edita ni se borra (gastos 4 y 5). Tabla de server.';
COMMENT ON COLUMN public.empleado_movimientos.rendicion_fecha IS
  'Con rendicion_transportista_id y rendicion_sucursal_id: la rendicion de cuya plata salio un pago (gastos 5).';

ALTER TABLE public.empleado_liquidaciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.empleado_liquidacion_conceptos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.empleado_liquidacion_lineas ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.empleado_liquidaciones, public.empleado_liquidacion_conceptos,
                    public.empleado_liquidacion_lineas
  FROM PUBLIC, anon, authenticated;

CREATE TRIGGER audit_empleado_liquidaciones
  AFTER INSERT OR UPDATE OR DELETE ON public.empleado_liquidaciones
  FOR EACH ROW EXECUTE FUNCTION public.audit_log_changes();

-- -------------------------------------------------------------------------
-- 2 · Una sola comision
-- -------------------------------------------------------------------------
-- Una fila por linea de los pedidos dados que son venta: la definicion de "venta
-- por vendedor" (CLAUDE.md) sin el corte de fechas, que pone el que llama.
CREATE FUNCTION public._comision_lineas(p_pedido_ids bigint[])
RETURNS TABLE (pedido_id bigint, usuario_id uuid, sucursal_id bigint, fecha date, producto_id bigint, combo_id bigint,
               origen_precio text, categoria_id uuid, clave text, base numeric, pct numeric, regla_id bigint)
LANGUAGE sql
STABLE
SET search_path = public
AS $fn$
  WITH ped AS (
    SELECT p.id, p.usuario_id, p.fecha, p.sucursal_id,
           -- COM-4 (#1321): no comisiona lo cobrado con adelanto de sueldo
           -- (consumo de empleado). Cada linea comisiona por la parte de la
           -- boleta que no se pago asi. Cuentan todos sus adelantos, tambien
           -- los del mes siguiente (decision del dueño, 29/10).
           CASE WHEN p.total > 0
                THEN 1 - LEAST(COALESCE(ad.monto, 0), p.total) / p.total
                ELSE 1
           END AS factor
    FROM pedidos p
    LEFT JOIN LATERAL (
      SELECT SUM(g.monto) AS monto
        FROM pagos g
       WHERE g.pedido_id = p.id
         AND g.forma_pago = 'adelanto_sueldo'
    ) ad ON true
    WHERE p.id = ANY(p_pedido_ids)
      AND p.estado = 'entregado'
      AND p.canal <> 'cambio'
      AND p.tipo_factura IS DISTINCT FROM 'VB'
      AND p.usuario_id IN (SELECT id FROM perfiles)
  ),
  vend AS (
    -- COM-5 (#1321): el % de preventista es de quien actua como preventista en
    -- la sucursal del pedido (rol base o el extra), no del rol base.
    SELECT u.usuario_id, u.sucursal_id,
           _actua_como_preventista(u.usuario_id, u.sucursal_id) AS es_preventista
    FROM (SELECT DISTINCT ped.usuario_id, ped.sucursal_id FROM ped) u
  ),
  pct_mes AS (
    -- COM-1 (#1320): el default que regia en el mes del pedido.
    SELECT m.sucursal_id, m.mes,
           COALESCE(v.pct_preventista, 2) AS pct_preventista,
           COALESCE(v.pct_otros, 0)       AS pct_otros
    FROM (SELECT DISTINCT ped.sucursal_id, date_trunc('month', ped.fecha)::date AS mes FROM ped) m
    LEFT JOIN LATERAL (
      SELECT cv.pct_preventista, cv.pct_otros
        FROM comision_pct_vigencias cv
       WHERE cv.sucursal_id = m.sucursal_id AND cv.vigente_desde <= m.mes
       ORDER BY cv.vigente_desde DESC
       LIMIT 1
    ) v ON true
  ),
  it AS (
    SELECT ped.id AS pedido_id, ped.usuario_id, ped.fecha, ped.sucursal_id,
           pi.subtotal * ped.factor AS subtotal,
           pi.producto_id,
           pi.combo_id,
           pi.origen_precio::text AS origen_precio,
           prod.categoria_id,
           CASE WHEN vend.es_preventista THEN pm.pct_preventista ELSE pm.pct_otros END AS pct_default
    FROM ped
    JOIN pedido_items pi ON pi.pedido_id = ped.id
    LEFT JOIN productos prod ON prod.id = pi.producto_id
    JOIN vend ON vend.usuario_id = ped.usuario_id AND vend.sucursal_id = ped.sucursal_id
    JOIN pct_mes pm ON pm.sucursal_id = ped.sucursal_id
                   AND pm.mes = date_trunc('month', ped.fecha)::date
    WHERE COALESCE(pi.es_bonificacion, false) = false
      -- Pagado entero con adelanto: no entra, ni en la base ni en los items.
      AND ped.factor > 0
  )
  SELECT it.pedido_id, it.usuario_id, it.sucursal_id, it.fecha, it.producto_id, it.combo_id,
         it.origen_precio, it.categoria_id,
         COALESCE(it.producto_id::text, '-') || '|' || COALESCE(it.combo_id::text, '-') || '|'
           || COALESCE(it.origen_precio, '-') AS clave,
         it.subtotal AS base,
         COALESCE(rg.porcentaje, it.pct_default) AS pct,
         rg.id AS regla_id
    FROM it
    LEFT JOIN LATERAL (
      SELECT r.id, r.porcentaje FROM comision_reglas r
      -- COM-2 (#1320): una regla dada de baja rige para lo anterior a su baja.
      WHERE (r.baja_desde IS NULL OR it.fecha < r.baja_desde)
        AND (r.sucursal_id    IS NULL OR r.sucursal_id    = it.sucursal_id)
        AND (r.preventista_id IS NULL OR r.preventista_id = it.usuario_id)
        AND (r.origen_precio  IS NULL OR r.origen_precio  = it.origen_precio)
        AND (r.producto_id    IS NULL OR r.producto_id    = it.producto_id)
        AND (r.categoria_id   IS NULL OR r.categoria_id   = it.categoria_id)
        AND r.vigente_desde <= it.fecha
        AND (r.vigente_hasta IS NULL OR r.vigente_hasta >= it.fecha)
      ORDER BY
        (CASE WHEN r.preventista_id IS NOT NULL THEN 8 ELSE 0 END
       + CASE WHEN r.producto_id    IS NOT NULL THEN 4 ELSE 0 END
       + CASE WHEN r.categoria_id   IS NOT NULL THEN 2 ELSE 0 END
       + CASE WHEN r.origen_precio  IS NOT NULL THEN 1 ELSE 0 END) DESC,
        (r.sucursal_id IS NOT NULL) DESC,
        r.vigente_desde DESC,
        r.id DESC
      LIMIT 1
    ) rg ON true;
$fn$;

CREATE OR REPLACE FUNCTION public.calcular_comisiones(p_desde date, p_hasta date, p_sucursal_ids bigint[] DEFAULT NULL::bigint[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_sucursales bigint[];
  v_pct_prev   numeric;
  v_pct_otros  numeric;
  v_out        jsonb;
BEGIN
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Solo un admin puede ver el calculo de comisiones' USING ERRCODE = '42501';
  END IF;

  IF p_desde IS NULL OR p_hasta IS NULL OR p_hasta < p_desde THEN
    RAISE EXCEPTION 'Rango de fechas invalido';
  END IF;

  -- #1048 (molde de #982): un admin calcula sólo sobre sus sucursales.
  v_sucursales := ARRAY(SELECT sucursal_id FROM usuario_sucursales WHERE usuario_id = auth.uid());
  IF array_length(v_sucursales, 1) IS NULL THEN
    RAISE EXCEPTION 'Acceso denegado: el usuario no tiene sucursales asignadas'
      USING ERRCODE = '42501';
  END IF;
  IF array_length(p_sucursal_ids, 1) IS NOT NULL THEN
    IF NOT (p_sucursal_ids <@ v_sucursales) THEN
      RAISE EXCEPTION 'Acceso denegado: pediste sucursales que no tenés asignadas'
        USING ERRCODE = '42501';
    END IF;
    v_sucursales := p_sucursal_ids;
  END IF;

  -- El default que rige al final del período, para el texto de la pantalla.
  -- El cálculo usa, ítem por ítem, el del mes del pedido (#1320).
  SELECT COALESCE(MAX(v.pct_preventista), 2),
         COALESCE(MAX(v.pct_otros), 0)
    INTO v_pct_prev, v_pct_otros
    FROM unnest(v_sucursales) AS s(id)
    CROSS JOIN LATERAL (
      SELECT cv.pct_preventista, cv.pct_otros
        FROM comision_pct_vigencias cv
       WHERE cv.sucursal_id = s.id AND cv.vigente_desde <= p_hasta
       ORDER BY cv.vigente_desde DESC
       LIMIT 1
    ) v;

  WITH con_pct AS (
    -- Por pedidos.fecha: es un calculo, no lo liquidado (gastos 5).
    SELECT l.usuario_id, l.fecha, l.sucursal_id, l.base AS subtotal, l.producto_id,
           l.origen_precio, l.categoria_id, l.pct
      FROM _comision_lineas(ARRAY(SELECT p.id FROM pedidos p
                                   WHERE p.fecha BETWEEN p_desde AND p_hasta
                                     AND p.sucursal_id = ANY(v_sucursales))) l
  ),
  por_origen AS (
    SELECT usuario_id,
           COALESCE(origen_precio, 'sin_dato') AS origen,
           SUM(subtotal)                 AS base,
           SUM(subtotal * pct / 100.0)   AS comision,
           COUNT(*)                      AS items
    FROM con_pct
    GROUP BY usuario_id, COALESCE(origen_precio, 'sin_dato')
  ),
  por_preventista AS (
    SELECT c.usuario_id,
           COALESCE(pf.nombre, 'Sin nombre')                                  AS nombre,
           pf.email,
           SUM(c.subtotal)                                                    AS base,
           SUM(c.subtotal * c.pct / 100.0)                                    AS comision,
           COUNT(*)                                                           AS items,
           COUNT(*) FILTER (WHERE c.origen_precio IS NULL)                    AS items_sin_desglose,
           COALESCE(SUM(c.subtotal) FILTER (WHERE c.origen_precio IS NULL),0) AS base_sin_desglose
    FROM con_pct c
    LEFT JOIN perfiles pf ON pf.id = c.usuario_id
    GROUP BY c.usuario_id, pf.nombre, pf.email
  )
  SELECT jsonb_build_object(
    'desde', p_desde,
    'hasta', p_hasta,
    'comision_default', v_pct_prev,
    'comision_pct_preventista', v_pct_prev,
    'comision_pct_otros', v_pct_otros,
    'preventistas', COALESCE((
      SELECT jsonb_agg(x ORDER BY (x->>'base')::numeric DESC)
      FROM (
        SELECT jsonb_build_object(
          'id', pp.usuario_id,
          'nombre', pp.nombre,
          'email', pp.email,
          'base', ROUND(pp.base, 2),
          'comision', ROUND(pp.comision, 2),
          'items', pp.items,
          'items_sin_desglose', pp.items_sin_desglose,
          'base_sin_desglose', ROUND(pp.base_sin_desglose, 2),
          'por_origen', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
              'origen', po.origen,
              'base', ROUND(po.base, 2),
              'comision', ROUND(po.comision, 2),
              'items', po.items
            ) ORDER BY po.base DESC)
            FROM por_origen po WHERE po.usuario_id = pp.usuario_id
          ), '[]'::jsonb)
        ) AS x
        FROM por_preventista pp
      ) s
    ), '[]'::jsonb),
    'totales', (
      SELECT jsonb_build_object(
        'base', COALESCE(ROUND(SUM(base), 2), 0),
        'comision', COALESCE(ROUND(SUM(comision), 2), 0),
        'items', COALESCE(SUM(items), 0),
        'items_sin_desglose', COALESCE(SUM(items_sin_desglose), 0),
        'base_sin_desglose', COALESCE(ROUND(SUM(base_sin_desglose), 2), 0)
      ) FROM por_preventista
    )
  ) INTO v_out;

  RETURN v_out;
END;
$function$;

-- COMIS-06 (434) le pedia al cuerpo de calcular_comisiones que nombrara lo que
-- regia en el mes. Esa logica ahora esta en _comision_lineas: se mira ahi, y
-- que calcular_comisiones la use. Una que no exista da 1.
CREATE OR REPLACE FUNCTION public.auditoria_comision_mes_cerrado()
RETURNS bigint
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT
    -- Una vigencia escrita después de que cerró su mes. La base del 2000 viene
    -- de la 421 con la fecha que tenía la política, y nada la vuelve a tocar:
    -- cambiar el % abre la fila del mes en curso.
    (SELECT count(*) FROM comision_pct_vigencias v
      WHERE CASE WHEN v.vigente_desde = DATE '2000-01-01'
                 THEN v.actualizado_en >= TIMESTAMPTZ '2026-10-30 02:08:36+00'
                 ELSE (v.actualizado_en AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
                      >= (v.vigente_desde + INTERVAL '1 month')::date END)
    -- Una regla que nació rigiendo en un mes que ya había cerrado.
    + (SELECT count(*) FROM comision_reglas r
        WHERE r.vigente_desde
              < date_trunc('month', r.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date)
    -- Un camino nuevo que las escriba sin las guardas de la 421.
    + (SELECT count(*) FROM pg_proc f
        WHERE f.pronamespace = 'public'::regnamespace
          AND f.prokind = 'f'
          AND f.proname NOT IN ('actualizar_comisiones_default', 'guardar_comision_regla',
                                'desactivar_comision_regla')
          AND regexp_replace(f.prosrc, '--[^\n]*', '', 'g')
              ~* '(INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+(public\.)?comision_(pct_vigencias|reglas)\y')
    -- El cálculo tiene que salir de lo que regía en el mes del pedido. Por nombre
    -- y no con un cast: cambiarle la firma no puede romper auditoria_integridad().
    + (SELECT CASE WHEN count(*) FILTER (WHERE f.proname = 'calcular_comisiones') = 1
                    AND count(*) FILTER (WHERE f.proname = '_comision_lineas') = 1
                    AND bool_and(CASE f.proname
                                   WHEN 'calcular_comisiones' THEN f.prosrc ~ '\y_comision_lineas\y'
                                   ELSE f.prosrc ~ '\ycomision_pct_vigencias\y' AND f.prosrc ~ '\ybaja_desde\y'
                                 END)
                   THEN 0 ELSE 1 END
         FROM pg_proc f
        WHERE f.pronamespace = 'public'::regnamespace
          AND f.proname IN ('calcular_comisiones', '_comision_lineas'));
$function$;

-- -------------------------------------------------------------------------
-- 3 · Periodos y sueldo
-- -------------------------------------------------------------------------
-- El COALESCE es para que un entregado sin fecha_entrega no quede sin
-- comisionar para siempre: los 6 que hay son de antes de cualquier arranque.
CREATE FUNCTION public._empleado_dia_de_entrega(p_fecha_entrega timestamptz, p_fecha date)
RETURNS date
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $fn$
  SELECT COALESCE((p_fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date, p_fecha);
$fn$;

-- Lunes a domingo, o dia 1 al ultimo.
CREATE FUNCTION public._periodo_que_contiene(p_dia date, p_frecuencia text)
RETURNS TABLE (inicio date, fin date)
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $fn$
  SELECT x.i, CASE WHEN p_frecuencia = 'semanal' THEN x.i + 6
                   ELSE (x.i + interval '1 month')::date - 1 END
    FROM (SELECT date_trunc(CASE WHEN p_frecuencia = 'semanal' THEN 'week' ELSE 'month' END, p_dia::timestamp)::date AS i) x;
$fn$;

CREATE FUNCTION public._empleado_ultima_hasta(p_empleado_id bigint)
RETURNS date
LANGUAGE sql
STABLE
SET search_path = public
AS $fn$
  SELECT max(l.hasta) FROM empleado_liquidaciones l WHERE l.empleado_id = p_empleado_id AND l.anulada_at IS NULL;
$fn$;

-- El arreglo vigente a p_desde, entero o 0 si el periodo empieza despues de la
-- baja. El sistema no prorratea: el admin lo corrige a mano en la pantalla.
CREATE FUNCTION public._liquidacion_sueldo_propuesto(p_e public.empleados, p_desde date, p_hasta date)
RETURNS TABLE (arreglo_id bigint, arreglo_desde date, sueldo numeric, avisos text[])
LANGUAGE sql
STABLE
SET search_path = public
AS $fn$
  SELECT a.id, a.vigente_desde,
         CASE WHEN p_desde > p_e.fecha_baja THEN 0 ELSE a.sueldo END,
         array_remove(ARRAY[
           CASE WHEN EXISTS (SELECT 1 FROM empleado_arreglos b
                              WHERE b.empleado_id = a.empleado_id
                                AND b.vigente_desde > p_desde AND b.vigente_desde <= p_hasta)
                THEN 'arreglo_cambia' END,
           CASE WHEN p_desde <> (SELECT p.inicio FROM public._periodo_que_contiene(p_desde, a.frecuencia) p)
                  OR p_e.fecha_baja BETWEEN p_desde AND p_hasta - 1
                THEN 'periodo_parcial' END]::text[], NULL)
    FROM empleado_arreglos a
   WHERE a.empleado_id = p_e.id AND a.vigente_desde <= p_desde
   ORDER BY a.vigente_desde DESC
   LIMIT 1;
$fn$;

-- -------------------------------------------------------------------------
-- 4 · Lo que entra en una liquidacion
-- -------------------------------------------------------------------------
-- inicial: lo entregado hasta p_hasta, sin piso, asi que lo que se entrega
-- despues de liquidar entra en el periodo siguiente. Un pedido con filas
-- vigentes de ese mismo vendedor ya se liquido, aunque el usuario se haya
-- revinculado a otro empleado; con otro vendedor en las filas, cambio de manos
-- y entra.
-- ajuste y linea_nueva: lo congelado de este empleado contra lo vivo, por
-- pedido, clave y vendedor de la foto. Lo vivo cuenta solo si el pedido sigue
-- siendo de ese vendedor. La linea congelada usa siempre su % y la nueva, la
-- regla vigente a pedidos.fecha.
CREATE FUNCTION public._liquidacion_lineas(p_e public.empleados, p_hasta date)
RETURNS TABLE (pedido_id bigint, usuario_id uuid, clave text, producto_id bigint, combo_id bigint, origen_precio text,
               regla_id bigint, pct numeric, base numeric, comision numeric, tipo text, motivo text, entregado_el date)
LANGUAGE sql
STABLE
SET search_path = public
AS $fn$
  WITH entran AS (
    SELECT s.id, s.dia
      FROM (SELECT p.id, public._empleado_dia_de_entrega(p.fecha_entrega, p.fecha) AS dia
              FROM pedidos p
             WHERE p.usuario_id = p_e.usuario_id
               AND (p.sucursal_id = p_e.sucursal_id OR p_e.de_las_dos)
               AND p.estado = 'entregado'
               AND NOT EXISTS (SELECT 1 FROM empleado_liquidacion_lineas l
                                WHERE l.pedido_id = p.id AND l.usuario_id = p.usuario_id AND l.vigente)) s
     WHERE s.dia <= p_hasta
       -- Sin arreglo ese dia (antes del arranque) da NULL y no entra.
       AND (SELECT a.comisiona FROM empleado_arreglos a
             WHERE a.empleado_id = p_e.id AND a.vigente_desde <= s.dia
             ORDER BY a.vigente_desde DESC LIMIT 1)
  ),
  iniciales AS (
    SELECT c.pedido_id, c.usuario_id, c.clave, e.dia,
           min(c.producto_id) AS producto_id, min(c.combo_id) AS combo_id, min(c.origen_precio) AS origen_precio,
           min(c.regla_id) AS regla_id, min(c.pct) AS pct, sum(c.base) AS base
      FROM public._comision_lineas(ARRAY(SELECT x.id FROM entran x)) c
      JOIN entran e ON e.id = c.pedido_id
     GROUP BY c.pedido_id, c.usuario_id, c.clave, e.dia
  ),
  congelado AS (
    SELECT l.pedido_id, l.usuario_id, l.clave, sum(l.base) AS base,
           (array_agg(l.pct ORDER BY l.id))[1] AS pct,
           (array_agg(l.regla_id ORDER BY l.id))[1] AS regla_id,
           (array_agg(l.producto_id ORDER BY l.id))[1] AS producto_id,
           (array_agg(l.combo_id ORDER BY l.id))[1] AS combo_id,
           (array_agg(l.origen_precio ORDER BY l.id))[1] AS origen_precio
      FROM empleado_liquidacion_lineas l
     WHERE l.empleado_id = p_e.id AND l.vigente
     GROUP BY l.pedido_id, l.usuario_id, l.clave
  ),
  vivo AS (
    SELECT c.pedido_id, c.usuario_id, c.clave,
           min(c.producto_id) AS producto_id, min(c.combo_id) AS combo_id, min(c.origen_precio) AS origen_precio,
           min(c.regla_id) AS regla_id, min(c.pct) AS pct, sum(c.base) AS base
      FROM public._comision_lineas(ARRAY(SELECT DISTINCT k.pedido_id FROM congelado k)) c
     GROUP BY c.pedido_id, c.usuario_id, c.clave
  ),
  cruce AS (
    SELECT COALESCE(k.pedido_id, v.pedido_id) AS pedido_id,
           COALESCE(k.usuario_id, v.usuario_id) AS usuario_id,
           COALESCE(k.clave, v.clave) AS clave,
           k.pedido_id IS NOT NULL AS congelada,
           CASE WHEN k.pedido_id IS NOT NULL THEN k.producto_id ELSE v.producto_id END AS producto_id,
           CASE WHEN k.pedido_id IS NOT NULL THEN k.combo_id ELSE v.combo_id END AS combo_id,
           CASE WHEN k.pedido_id IS NOT NULL THEN k.origen_precio ELSE v.origen_precio END AS origen_precio,
           CASE WHEN k.pedido_id IS NOT NULL THEN k.regla_id ELSE v.regla_id END AS regla_id,
           CASE WHEN k.pedido_id IS NOT NULL THEN k.pct ELSE v.pct END AS pct,
           COALESCE(v.base, 0) - COALESCE(k.base, 0) AS base
      FROM congelado k
      FULL JOIN vivo v ON v.pedido_id = k.pedido_id AND v.usuario_id = k.usuario_id AND v.clave = k.clave
     WHERE k.pedido_id IS NOT NULL
        OR EXISTS (SELECT 1 FROM congelado x WHERE x.pedido_id = v.pedido_id AND x.usuario_id = v.usuario_id)
  )
  SELECT i.pedido_id, i.usuario_id, i.clave, i.producto_id, i.combo_id, i.origen_precio, i.regla_id, i.pct,
         round(i.base, 6), round(i.base * i.pct / 100, 6), 'inicial'::text, NULL::text, i.dia
    FROM iniciales i
  UNION ALL
  SELECT c.pedido_id, c.usuario_id, c.clave, c.producto_id, c.combo_id, c.origen_precio, c.regla_id, c.pct,
         round(c.base, 6), round(c.base * c.pct / 100, 6),
         CASE WHEN c.congelada THEN 'ajuste' ELSE 'linea_nueva' END,
         CASE WHEN NOT c.congelada THEN 'Línea nueva en el pedido'
              WHEN p.usuario_id IS DISTINCT FROM c.usuario_id THEN 'El pedido pasó a otro vendedor'
              WHEN p.estado IN ('cancelado', 'anulado') THEN 'Se canceló el pedido'
              WHEN p.estado = 'entregado' THEN 'Cambió la boleta del pedido'
              ELSE 'El pedido volvió a pendiente' END,
         public._empleado_dia_de_entrega(p.fecha_entrega, p.fecha)
    FROM cruce c
    JOIN pedidos p ON p.id = c.pedido_id
   WHERE abs(c.base * c.pct / 100) >= 0.005;
$fn$;

-- El periodo pendiente mas viejo. La baja no lo corta (decision 4). Un periodo
-- entero despues de la baja solo existe para liquidar lo que se entrego despues
-- de que se fue, con sueldo 0: si la entrega cae mas adelante que el periodo que
-- sigue, el periodo salta hasta ella, o ese pedido no se liquidaria nunca.
CREATE FUNCTION public._empleado_periodo_siguiente(p_e public.empleados)
RETURNS TABLE (desde date, hasta date, frecuencia text, mas_vencidos integer)
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $fn$
DECLARE
  v_hoy   date := public._tablero_hoy();
  v_dia   date;
  v_fin   date;
  v_frec  text;
  v_pend  date;
  v_ini   date;
BEGIN
  SELECT COALESCE(public._empleado_ultima_hasta(p_e.id) + 1, min(a.vigente_desde)) INTO v_dia
    FROM empleado_arreglos a WHERE a.empleado_id = p_e.id;
  IF v_dia IS NULL THEN
    RETURN;
  END IF;

  SELECT a.frecuencia INTO v_frec FROM empleado_arreglos a
   WHERE a.empleado_id = p_e.id AND a.vigente_desde <= v_dia ORDER BY a.vigente_desde DESC LIMIT 1;
  SELECT p.fin INTO v_fin FROM public._periodo_que_contiene(v_dia, v_frec) p;

  IF v_dia > p_e.fecha_baja THEN
    -- Sin los de comision 0: un periodo sin plata no se liquida y trabaria al que sigue.
    SELECT min(l.entregado_el) INTO v_pend FROM public._liquidacion_lineas(p_e, v_hoy) l
     WHERE l.tipo = 'inicial' AND abs(l.comision) >= 0.005;
    IF v_pend > v_fin THEN
      SELECT a.frecuencia INTO v_frec FROM empleado_arreglos a
       WHERE a.empleado_id = p_e.id AND a.vigente_desde <= v_pend ORDER BY a.vigente_desde DESC LIMIT 1;
      SELECT p.inicio, p.fin INTO v_ini, v_fin FROM public._periodo_que_contiene(v_pend, v_frec) p;
      v_dia := GREATEST(v_dia, v_ini);
    END IF;
  END IF;

  desde := v_dia;
  hasta := v_fin;
  frecuencia := v_frec;
  mas_vencidos := 0;
  -- Los periodos terminados despues de este, con la frecuencia de cada uno.
  v_dia := v_fin + 1;
  WHILE p_e.fecha_baja IS NULL OR v_dia <= p_e.fecha_baja LOOP
    SELECT a.frecuencia INTO v_frec FROM empleado_arreglos a
     WHERE a.empleado_id = p_e.id AND a.vigente_desde <= v_dia ORDER BY a.vigente_desde DESC LIMIT 1;
    SELECT p.fin INTO v_fin FROM public._periodo_que_contiene(v_dia, v_frec) p;
    EXIT WHEN v_fin >= v_hoy;
    mas_vencidos := mas_vencidos + 1;
    v_dia := v_fin + 1;
  END LOOP;
  RETURN NEXT;
END
$fn$;

-- De donde salio un movimiento: su liquidacion y su rendicion, o NULL. Lo usan
-- la cuenta y la vista previa, que son solo del admin: tiene nombres.
CREATE FUNCTION public._movimiento_origen_json(p_m public.empleado_movimientos)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = public
AS $fn$
  SELECT jsonb_build_object(
    'liquidacion', (SELECT jsonb_build_object(
                             'id', li.id, 'desde', li.desde, 'hasta', li.hasta, 'frecuencia', li.frecuencia,
                             'pedidos', COALESCE((SELECT (c.detalle->>'pedidos')::integer
                                                    FROM empleado_liquidacion_conceptos c
                                                   WHERE c.liquidacion_id = li.id AND c.concepto = 'comision'), 0),
                             'anulada', li.anulada_at IS NOT NULL)
                      FROM empleado_liquidaciones li WHERE li.id = p_m.liquidacion_id),
    'rendicion', (SELECT jsonb_build_object('transportista_nombre', tr.nombre, 'fecha', p_m.rendicion_fecha)
                    FROM perfiles tr WHERE tr.id = p_m.rendicion_transportista_id));
$fn$;

-- La forma de VistaPreviaLiquidacion (src/types/personal.ts), sin periodo,
-- puede_liquidar ni en_curso. p_sueldo NULL usa el propuesto.
CREATE FUNCTION public._liquidacion_json(p_e public.empleados, p_desde date, p_hasta date, p_sueldo numeric DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $fn$
DECLARE
  v_s      record;
  v_com    jsonb;
  v_aju    jsonb;
  v_corte  bigint;
  v_movs   jsonb;
  v_suma   numeric;
  v_saldo  numeric;
  v_avisos text[];
BEGIN
  SELECT * INTO v_s FROM public._liquidacion_sueldo_propuesto(p_e, p_desde, p_hasta);

  WITH l AS MATERIALIZED (SELECT * FROM public._liquidacion_lineas(p_e, p_hasta))
  SELECT jsonb_build_object(
           'total', COALESCE(round(sum(l.comision) FILTER (WHERE l.tipo = 'inicial'), 2), 0),
           'base', COALESCE(round(sum(l.base) FILTER (WHERE l.tipo = 'inicial'), 2), 0),
           'detalle', COALESCE((
             SELECT jsonb_agg(jsonb_build_object('pedido_id', x.pedido_id, 'fecha', x.fecha, 'entregado_el', x.entregado_el,
                                                 'cliente', x.cliente, 'base', round(x.base, 2), 'comision', round(x.comision, 2))
                              ORDER BY x.entregado_el, x.pedido_id)
               FROM (SELECT i.pedido_id, p.fecha, i.entregado_el, COALESCE(c.nombre_fantasia, c.razon_social) AS cliente,
                            sum(i.base) AS base, sum(i.comision) AS comision
                       FROM l i
                       JOIN pedidos p ON p.id = i.pedido_id
                       LEFT JOIN clientes c ON c.id = p.cliente_id
                      WHERE i.tipo = 'inicial'
                      GROUP BY i.pedido_id, p.fecha, i.entregado_el, c.nombre_fantasia, c.razon_social) x), '[]'::jsonb)),
         jsonb_build_object(
           'total', COALESCE(round(sum(l.comision) FILTER (WHERE l.tipo <> 'inicial'), 2), 0),
           'detalle', COALESCE((
             SELECT jsonb_agg(jsonb_build_object('pedido_id', y.pedido_id, 'motivo', y.motivo,
                                                 'base', round(y.base, 2), 'comision', round(y.comision, 2))
                              ORDER BY y.pedido_id, y.motivo)
               FROM (SELECT a.pedido_id, a.motivo, sum(a.base) AS base, sum(a.comision) AS comision
                       FROM l a WHERE a.tipo <> 'inicial' GROUP BY a.pedido_id, a.motivo) y), '[]'::jsonb))
    INTO v_com, v_aju
    FROM l;

  -- Lo posterior a la ultima liquidacion. El pago que quedo de una anulada es
  -- plata que salio: se muestra, y la liquidacion nueva lo descuenta.
  SELECT max(m.id) INTO v_corte
    FROM empleado_movimientos m
    JOIN empleado_liquidaciones li ON li.id = m.liquidacion_id AND li.anulada_at IS NULL
   WHERE m.empleado_id = p_e.id;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', m.id, 'fecha', m.fecha, 'tipo', m.tipo, 'monto', m.monto, 'observacion', m.observacion,
           'pedido_id', m.pedido_id,
           'gasto', CASE WHEN g.id IS NULL THEN NULL
                         ELSE jsonb_build_object('id', g.id, 'rubro', r.nombre,
                                                 'vehiculo', CASE WHEN v.id IS NULL THEN NULL
                                                                  ELSE v.descripcion || ' ' || v.patente END) END,
           'revierte_id', m.revierte_id,
           'por_el_mismo', COALESCE(m.creado_por = p_e.usuario_id, false))
           || public._movimiento_origen_json(m) ORDER BY m.fecha, m.id), '[]'::jsonb),
         COALESCE(sum(m.monto), 0)
    INTO v_movs, v_suma
    FROM empleado_movimientos m
    LEFT JOIN empleado_liquidaciones li ON li.id = m.liquidacion_id
    LEFT JOIN gastos g ON g.id = m.gasto_id
    LEFT JOIN gasto_rubros r ON r.id = g.rubro_id
    LEFT JOIN vehiculos v ON v.id = g.vehiculo_id
   WHERE m.empleado_id = p_e.id
     AND m.id > COALESCE(v_corte, 0)
     AND (m.liquidacion_id IS NULL
          OR (m.tipo = 'pago' AND li.anulada_at IS NOT NULL AND m.revierte_id IS NULL
              AND NOT EXISTS (SELECT 1 FROM empleado_movimientos rv WHERE rv.revierte_id = m.id)));

  SELECT COALESCE(sum(m.monto), 0) INTO v_saldo FROM empleado_movimientos m WHERE m.empleado_id = p_e.id;

  v_avisos := COALESCE(v_s.avisos, '{}');
  IF p_e.usuario_id IS NULL
     AND EXISTS (SELECT 1 FROM empleado_arreglos a
                  WHERE a.empleado_id = p_e.id AND a.comisiona AND a.vigente_desde <= p_hasta
                    AND NOT EXISTS (SELECT 1 FROM empleado_arreglos b
                                     WHERE b.empleado_id = a.empleado_id AND b.vigente_desde > a.vigente_desde
                                       AND b.vigente_desde <= p_desde)) THEN
    v_avisos := array_append(v_avisos, 'comisiona_sin_usuario');
  END IF;

  RETURN jsonb_build_object(
    'sueldo', jsonb_build_object('propuesto', COALESCE(v_s.sueldo, 0), 'arreglo_desde', v_s.arreglo_desde),
    'comisiones', v_com,
    'ajustes', v_aju,
    'movimientos', v_movs,
    'saldo_anterior', v_saldo - v_suma,
    'saldo_actual', v_saldo,
    'a_pagar', round(v_saldo + COALESCE(p_sueldo, v_s.sueldo, 0) + (v_com->>'total')::numeric + (v_aju->>'total')::numeric, 2),
    'avisos', to_jsonb(v_avisos));
END
$fn$;

-- Cada pago sale de una sola plata. Con origen_pago 'oficina' (o sin el) no
-- devuelve filas. Con 'rendicion', las validaciones de _guardar_gasto: el lock
-- se queda hasta el fin de la transaccion, el mismo de confirmar_rendicion.
CREATE FUNCTION public._pago_de_rendicion(p_datos jsonb)
RETURNS TABLE (transportista_id uuid, fecha date, sucursal_id bigint)
LANGUAGE plpgsql
SET search_path = public
AS $fn$
DECLARE
  v_origen text;
  v_t      uuid;
  v_f      date;
  v_suc    bigint := public.current_sucursal_id();
BEGIN
  BEGIN
    v_origen := COALESCE(NULLIF(btrim(p_datos->>'origen_pago'), ''), 'oficina');
    v_t := NULLIF(btrim(p_datos->>'rendicion_transportista_id'), '')::uuid;
    v_f := NULLIF(p_datos->>'rendicion_fecha', '')::date;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Hay un dato de la liquidación con un formato inválido';
  END;
  IF v_origen = 'oficina' THEN
    RETURN;
  END IF;
  IF v_origen <> 'rendicion' THEN
    RAISE EXCEPTION 'Hay un dato de la liquidación con un formato inválido';
  END IF;
  IF v_t IS NULL OR v_f IS NULL THEN
    RAISE EXCEPTION 'Elegí de qué rendición sale la plata: el transportista y el día';
  END IF;
  IF v_f > public._tablero_hoy() THEN
    RAISE EXCEPTION 'La rendición no puede ser de un día que todavía no llegó';
  END IF;
  IF v_suc IS NULL OR NOT EXISTS (SELECT 1 FROM usuario_sucursales us
                                   WHERE us.usuario_id = v_t AND us.sucursal_id = v_suc) THEN
    RAISE EXCEPTION 'Ese transportista no es de esta sucursal';
  END IF;
  PERFORM public._rendicion_bloquear(ARRAY[public._rendicion_clave(v_t, v_f, v_suc)]);
  IF public.control_rendicion_cerrado(v_t, v_suc, v_f) THEN
    RAISE EXCEPTION 'Esa rendición ya está cerrada: pagá con la oficina o elegí otra';
  END IF;
  transportista_id := v_t;
  fecha := v_f;
  sucursal_id := v_suc;
  RETURN NEXT;
END
$fn$;

-- La forma de LiquidacionResumen.
CREATE FUNCTION public._liquidacion_resumen_json(p_l public.empleado_liquidaciones)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = public
AS $fn$
  SELECT jsonb_build_object(
    'id', p_l.id, 'desde', p_l.desde, 'hasta', p_l.hasta, 'frecuencia', p_l.frecuencia,
    'sueldo', COALESCE((SELECT c.monto FROM empleado_liquidacion_conceptos c
                         WHERE c.liquidacion_id = p_l.id AND c.concepto = 'sueldo'), 0),
    'comision', COALESCE((SELECT c.monto FROM empleado_liquidacion_conceptos c
                           WHERE c.liquidacion_id = p_l.id AND c.concepto = 'comision'), 0),
    'ajuste', COALESCE((SELECT c.monto FROM empleado_liquidacion_conceptos c
                         WHERE c.liquidacion_id = p_l.id AND c.concepto = 'ajuste_comision'), 0),
    'a_pagar', p_l.a_pagar, 'pagado', p_l.pagado, 'fecha_pago', p_l.fecha_pago,
    'rendicion', (SELECT jsonb_build_object('transportista_nombre', pf.nombre, 'fecha', m.rendicion_fecha)
                    FROM empleado_movimientos m
                    JOIN perfiles pf ON pf.id = m.rendicion_transportista_id
                   WHERE m.liquidacion_id = p_l.id AND m.tipo = 'pago' AND m.revierte_id IS NULL),
    'anulada_at', p_l.anulada_at, 'motivo_anulacion', p_l.motivo_anulacion,
    'creado_por_nombre', (SELECT pf.nombre FROM perfiles pf WHERE pf.id = p_l.creado_por),
    'es_la_ultima', p_l.anulada_at IS NULL
                    AND NOT EXISTS (SELECT 1 FROM empleado_liquidaciones o
                                     WHERE o.empleado_id = p_l.empleado_id AND o.anulada_at IS NULL
                                       AND o.desde > p_l.desde));
$fn$;

-- El costo de personal por mes para el estado de resultados (#1269), con el
-- molde de gastos_por_mes: lo de p_sucursales y todos los compartidos, y solo lo
-- liquidado. La comision ya esta en Contribucion: Personal suma solo el sueldo.
-- El sueldo se reparte por dias entre los meses del periodo y el ultimo absorbe
-- el redondeo; la comision va al mes de entrega y el ajuste al del hasta, los
-- dos en la sucursal del pedido.
CREATE FUNCTION public.personal_por_mes(p_desde date, p_hasta date, p_sucursales bigint[])
RETURNS TABLE (mes date, empleado_id bigint, sucursal_id bigint, compartido boolean, concepto text, monto numeric)
LANGUAGE sql
STABLE
SET search_path = public
AS $fn$
  WITH sueldos AS (
    SELECT l.id, l.empleado_id, l.sucursal_al_liquidar, l.de_las_dos, l.desde, l.hasta, c.monto
      FROM empleado_liquidaciones l
      JOIN empleado_liquidacion_conceptos c ON c.liquidacion_id = l.id AND c.concepto = 'sueldo'
     WHERE l.anulada_at IS NULL AND c.monto <> 0
  ),
  cuotas AS (
    SELECT s.*, m.mes,
           round(s.monto * m.dias / (s.hasta - s.desde + 1), 2) AS cuota
      FROM sueldos s
     CROSS JOIN LATERAL (
       SELECT g::date AS mes,
              LEAST(s.hasta, (g + interval '1 month')::date - 1) - GREATEST(s.desde, g::date) + 1 AS dias
         FROM generate_series(date_trunc('month', s.desde::timestamp), date_trunc('month', s.hasta::timestamp),
                              interval '1 month') g) m
  ),
  filas AS (
    SELECT c.mes, c.empleado_id, c.sucursal_al_liquidar AS sucursal_id, c.de_las_dos AS compartido,
           'sueldo'::text AS concepto,
           CASE WHEN c.mes = max(c.mes) OVER w THEN c.monto - (sum(c.cuota) OVER w - c.cuota) ELSE c.cuota END AS monto
      FROM cuotas c
    WINDOW w AS (PARTITION BY c.id)
    UNION ALL
    SELECT date_trunc('month', li.entregado_el::timestamp)::date, li.empleado_id, p.sucursal_id, false, 'comision',
           round(sum(li.comision), 2)
      FROM empleado_liquidacion_lineas li
      JOIN pedidos p ON p.id = li.pedido_id
     WHERE li.vigente AND li.tipo = 'inicial'
     GROUP BY 1, li.empleado_id, p.sucursal_id
    UNION ALL
    SELECT date_trunc('month', l.hasta::timestamp)::date, li.empleado_id, p.sucursal_id, false, 'ajuste_comision',
           round(sum(li.comision), 2)
      FROM empleado_liquidacion_lineas li
      JOIN empleado_liquidaciones l ON l.id = li.liquidacion_id
      JOIN pedidos p ON p.id = li.pedido_id
     WHERE li.vigente AND li.tipo <> 'inicial'
     GROUP BY 1, li.empleado_id, p.sucursal_id
  )
  SELECT f.mes, f.empleado_id, f.sucursal_id, f.compartido, f.concepto, f.monto
    FROM filas f
   WHERE f.mes >= date_trunc('month', p_desde::timestamp)::date AND f.mes <= p_hasta
     AND (f.sucursal_id = ANY(p_sucursales) OR f.compartido)
     AND f.monto <> 0
   ORDER BY f.mes, f.empleado_id, f.concepto;
$fn$;

-- -------------------------------------------------------------------------
-- 5 · Las guardas: lo liquidado no se cambia de costado
-- -------------------------------------------------------------------------
CREATE FUNCTION public.empleado_arreglos_periodo_cerrado()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $fn$
DECLARE
  v_hasta date := public._empleado_ultima_hasta(NEW.empleado_id);
BEGIN
  IF NEW.vigente_desde <= v_hasta OR (TG_OP = 'UPDATE' AND OLD.vigente_desde <= v_hasta) THEN
    RAISE EXCEPTION 'Ya se liquidó hasta el %: un arreglo nuevo vale desde el día siguiente, o anulá esa liquidación',
      to_char(v_hasta, 'DD/MM/YYYY');
  END IF;
  RETURN NEW;
END
$fn$;

CREATE TRIGGER trg_empleado_arreglos_periodo_cerrado
  BEFORE INSERT OR UPDATE OF vigente_desde, sueldo, frecuencia, comisiona ON public.empleado_arreglos
  FOR EACH ROW EXECUTE FUNCTION public.empleado_arreglos_periodo_cerrado();

CREATE FUNCTION public.empleados_periodo_cerrado()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $fn$
DECLARE
  v_hasta date := public._empleado_ultima_hasta(NEW.id);
BEGIN
  IF NEW.fecha_baja < v_hasta THEN
    RAISE EXCEPTION 'Ya se liquidó hasta el %: la baja va desde esa fecha, o anulá esa liquidación',
      to_char(v_hasta, 'DD/MM/YYYY');
  END IF;
  RETURN NEW;
END
$fn$;

CREATE TRIGGER trg_empleados_periodo_cerrado
  BEFORE UPDATE OF fecha_baja ON public.empleados
  FOR EACH ROW EXECUTE FUNCTION public.empleados_periodo_cerrado();

-- -------------------------------------------------------------------------
-- 6 · Lo que cambia en Personal
-- -------------------------------------------------------------------------
-- periodo: NULL si ya no hay nada para liquidar despues de la baja. Los ajustes
-- no se miran aca, para no recalcular en cada tarjeta: la ficha los ve por la
-- vista previa.
CREATE OR REPLACE FUNCTION public._empleado_json(p_e public.empleados)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = public
AS $fn$
  SELECT jsonb_build_object(
    'id', p_e.id, 'nombre', p_e.nombre, 'puesto', p_e.puesto, 'sucursal_id', p_e.sucursal_id,
    'de_las_dos', p_e.de_las_dos, 'cuil', p_e.cuil, 'fecha_ingreso', p_e.fecha_ingreso, 'telefono', p_e.telefono,
    'activo', p_e.activo, 'fecha_baja', p_e.fecha_baja,
    'usuario', (SELECT jsonb_build_object('id', pf.id, 'nombre', pf.nombre) FROM perfiles pf WHERE pf.id = p_e.usuario_id),
    'cliente', (SELECT jsonb_build_object('id', c.id, 'nombre_fantasia', COALESCE(c.nombre_fantasia, c.razon_social),
                                          'activo', COALESCE(c.activo, true))
                  FROM clientes c WHERE c.id = p_e.cliente_id),
    'vehiculo', (SELECT jsonb_build_object('id', v.id, 'patente', v.patente, 'descripcion', v.descripcion)
                   FROM vehiculos v WHERE v.id = p_e.vehiculo_id),
    'arreglo', (SELECT jsonb_build_object(
                         'id', a.id, 'vigente_desde', a.vigente_desde,
                         'vigente_hasta', (SELECT min(b.vigente_desde) - 1 FROM empleado_arreglos b
                                            WHERE b.empleado_id = a.empleado_id AND b.vigente_desde > a.vigente_desde),
                         'sueldo', a.sueldo, 'frecuencia', a.frecuencia, 'comisiona', a.comisiona)
                  FROM empleado_arreglos a
                 WHERE a.empleado_id = p_e.id
                 ORDER BY (a.vigente_desde <= public._tablero_hoy()) DESC,
                          CASE WHEN a.vigente_desde <= public._tablero_hoy() THEN a.vigente_desde END DESC NULLS LAST,
                          a.vigente_desde
                 LIMIT 1),
    'arranque', (SELECT min(a.vigente_desde) FROM empleado_arreglos a WHERE a.empleado_id = p_e.id),
    'saldo', COALESCE((SELECT sum(m.monto) FROM empleado_movimientos m WHERE m.empleado_id = p_e.id), 0),
    'es_propio', COALESCE(p_e.usuario_id = auth.uid(), false),
    'periodo', (SELECT jsonb_build_object('desde', ps.desde, 'hasta', ps.hasta, 'frecuencia', ps.frecuencia,
                                          'mas_vencidos', ps.mas_vencidos)
                  FROM public._empleado_periodo_siguiente(p_e) ps
                 WHERE CASE WHEN ps.desde > p_e.fecha_baja
                            THEN EXISTS (SELECT 1 FROM public._liquidacion_lineas(p_e, ps.hasta) l
                                          WHERE l.tipo = 'inicial' AND abs(l.comision) >= 0.005)
                            ELSE true END));
$fn$;

CREATE OR REPLACE FUNCTION public.obtener_cuenta_empleado(p_empleado_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_e empleados%ROWTYPE;
BEGIN
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin ve y carga el personal' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_e FROM empleados WHERE id = p_empleado_id;
  IF NOT FOUND OR NOT public._empleado_visible(v_e.sucursal_id, v_e.de_las_dos) THEN
    RAISE EXCEPTION 'Ese empleado no existe o no lo podés ver';
  END IF;
  RETURN jsonb_build_object(
    'empleado', public._empleado_json(v_e),
    'arreglos', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id', a.id, 'vigente_desde', a.vigente_desde,
               'vigente_hasta', (SELECT min(b.vigente_desde) - 1 FROM empleado_arreglos b
                                  WHERE b.empleado_id = a.empleado_id AND b.vigente_desde > a.vigente_desde),
               'sueldo', a.sueldo, 'frecuencia', a.frecuencia, 'comisiona', a.comisiona)
             ORDER BY a.vigente_desde DESC)
        FROM empleado_arreglos a WHERE a.empleado_id = v_e.id), '[]'::jsonb),
    'liquidaciones', COALESCE((
      SELECT jsonb_agg(public._liquidacion_resumen_json(l) ORDER BY l.desde DESC, l.id DESC)
        FROM empleado_liquidaciones l WHERE l.empleado_id = v_e.id), '[]'::jsonb),
    'movimientos', COALESCE((
      SELECT jsonb_agg(x.j ORDER BY x.fecha DESC, x.id DESC)
        FROM (SELECT m.id, m.fecha,
                     jsonb_build_object(
                       'id', m.id, 'fecha', m.fecha, 'tipo', m.tipo, 'monto', m.monto,
                       'saldo', sum(m.monto) OVER (ORDER BY m.fecha, m.id),
                       'observacion', m.observacion, 'pago_id', m.pago_id, 'pedido_id', m.pedido_id,
                       'gasto', CASE WHEN g.id IS NULL THEN NULL
                                     ELSE jsonb_build_object('id', g.id, 'rubro', r.nombre,
                                                             'vehiculo', CASE WHEN v.id IS NULL THEN NULL
                                                                              ELSE v.descripcion || ' ' || v.patente END) END,
                       'revierte_id', m.revierte_id,
                       'revertido', EXISTS (SELECT 1 FROM empleado_movimientos rv WHERE rv.revierte_id = m.id),
                       'creado_por_nombre', pf.nombre, 'created_at', m.created_at)
                     || public._movimiento_origen_json(m) AS j
                FROM empleado_movimientos m
                LEFT JOIN gastos g ON g.id = m.gasto_id
                LEFT JOIN gasto_rubros r ON r.id = g.rubro_id
                LEFT JOIN vehiculos v ON v.id = g.vehiculo_id
                LEFT JOIN perfiles pf ON pf.id = m.creado_por
               WHERE m.empleado_id = v_e.id) x), '[]'::jsonb));
END
$fn$;

-- El adelanto y el pago van positivos y se guardan negativos; el ajuste, con su
-- signo. Un empleado dado de baja tambien recibe movimientos: el que se fue
-- debiendo. El pago no tiene tope, y con una rendicion su fecha es la de ella.
CREATE OR REPLACE FUNCTION public.registrar_movimiento_empleado(p_empleado_id bigint, p_movimiento jsonb)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
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
  INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, observacion, creado_por,
                                    rendicion_transportista_id, rendicion_fecha, rendicion_sucursal_id)
  VALUES (v_e.id, v_fecha, v_tipo, v_monto, v_obs, auth.uid(), v_rt, v_rf, v_rs)
  RETURNING id INTO v_id;
  RETURN v_id;
END
$fn$;

-- Solo lo cargado a mano, una vez y con motivo. Los automaticos siguen a su
-- pago o a su gasto, y lo de una liquidacion se revierte anulandola. Un pago de
-- una rendicion copia sus datos y le devuelve la plata, si sigue pendiente.
CREATE OR REPLACE FUNCTION public.revertir_movimiento_empleado(p_movimiento_id bigint, p_motivo text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
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
$fn$;

-- -------------------------------------------------------------------------
-- 7 · La rendicion: el total pagado al personal
-- -------------------------------------------------------------------------
-- Cambia el retorno: se dropea y se reponen sus permisos. Devuelve un total, sin
-- nombres: el encargado y el chofer no ven a quien se le pago.
DROP FUNCTION public.obtener_resumen_rendiciones(date, date, uuid);

CREATE FUNCTION public.obtener_resumen_rendiciones(
  p_fecha_desde date DEFAULT ((((now() AT TIME ZONE 'America/Argentina/Buenos_Aires'::text))::date - '30 days'::interval))::date,
  p_fecha_hasta date DEFAULT ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires'::text))::date,
  p_transportista_id uuid DEFAULT NULL::uuid)
RETURNS TABLE(fecha date, transportista_id uuid, transportista_nombre text, total_efectivo numeric,
              total_transferencia numeric, total_cheque numeric, total_cuenta_corriente numeric, total_tarjeta numeric,
              total_otros numeric, total_adelanto_sueldo numeric, total_general numeric, total_entregas numeric,
              total_ctascte numeric, cantidad_pedidos bigint, total_entregado numeric, total_gastos numeric,
              cantidad_gastos bigint, estado text, observaciones text, controlada boolean,
              controlada_at timestamp with time zone, controlada_por_nombre text,
              resuelta_at timestamp with time zone, resuelta_por_nombre text, total_pagos_personal numeric)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
    -- reversion lleva la misma rendicion y lo devuelve.
    SELECT m.rendicion_transportista_id AS t_id, m.rendicion_fecha AS f,
           (-SUM(m.monto))::numeric AS tot_pp
      FROM empleado_movimientos m
     WHERE m.rendicion_sucursal_id = v_sucursal_id
       AND m.rendicion_fecha BETWEEN p_fecha_desde AND p_fecha_hasta
       AND (p_transportista_id IS NULL OR m.rendicion_transportista_id = p_transportista_id)
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
    COALESCE(pagos_personal_agg.tot_pp, 0)::numeric AS total_pagos_personal
  FROM fechas_activas fa
  JOIN perfiles tr ON tr.id = fa.t_id
  LEFT JOIN pagos_agg ON pagos_agg.t_id = fa.t_id AND pagos_agg.f = fa.f
  LEFT JOIN adelantos_agg ON adelantos_agg.t_id = fa.t_id AND adelantos_agg.f = fa.f
  LEFT JOIN entregas_agg ON entregas_agg.t_id = fa.t_id AND entregas_agg.f = fa.f
  LEFT JOIN gastos_agg ON gastos_agg.t_id = fa.t_id AND gastos_agg.f = fa.f
  LEFT JOIN pagos_personal_agg ON pagos_personal_agg.t_id = fa.t_id AND pagos_personal_agg.f = fa.f
  LEFT JOIN rendiciones_control rc
    ON rc.fecha = fa.f
   AND rc.transportista_id = fa.t_id
   AND rc.sucursal_id = v_sucursal_id
  LEFT JOIN perfiles cp ON cp.id = rc.controlada_por
  LEFT JOIN perfiles rp2 ON rp2.id = rc.resuelta_por
  ORDER BY fa.f DESC, tr.nombre ASC;
END;
$function$;

-- Un pago al personal cambia lo que se entrega igual que un gasto: el cierre
-- compara lo pagado con lo que vio el modal (pagos_personal_visto, paso 4b).
CREATE OR REPLACE FUNCTION public.confirmar_rendicion(p_fecha date, p_transportista_id uuid, p_estado text, p_gastos_rendicion jsonb, p_observaciones text DEFAULT NULL::text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
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
  --     pagos_personal_visto: numero}; una lista que no viene es [].
  --     pagos_personal_visto que no viene es 0: un bundle viejo no conoce los
  --     pagos al personal, asi que si la rendicion tiene alguno se lo rechaza a
  --     proposito en el paso 4b, y al refrescar ya manda lo que vio.
  BEGIN
    IF jsonb_typeof(p_gastos_rendicion) IS DISTINCT FROM 'object'
       OR jsonb_typeof(COALESCE(p_gastos_rendicion->'vistos', '[]')) <> 'array'
       OR jsonb_typeof(COALESCE(p_gastos_rendicion->'quitar', '[]')) <> 'array'
       OR jsonb_typeof(COALESCE(p_gastos_rendicion->'guardar', '[]')) <> 'array'
       OR jsonb_typeof(COALESCE(p_gastos_rendicion->'pagos_personal_visto', '0')) <> 'number' THEN
      RAISE EXCEPTION 'formato';
    END IF;
    v_vistos  := COALESCE(p_gastos_rendicion->'vistos', '[]');
    v_guardar := COALESCE(p_gastos_rendicion->'guardar', '[]');
    v_pagos_visto := COALESCE((p_gastos_rendicion->>'pagos_personal_visto')::numeric, 0);
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

  -- 4 · los vivos de esta rendicion tienen que ser los que vio el modal, con
  --     la misma version (id, updated_at): uno editado mientras tanto tambien
  --     cambia lo que se entrega
  v_vivos := ARRAY(SELECT g.id FROM gastos g
                    WHERE g.origen_pago = 'rendicion'
                      AND g.sucursal_id = v_sucursal_id
                      AND g.rendicion_transportista_id = p_transportista_id
                      AND g.rendicion_fecha = p_fecha
                      AND g.anulado_at IS NULL);
  IF EXISTS (SELECT g.id, g.updated_at FROM gastos g WHERE g.id = ANY (v_vivos)
             EXCEPT
             SELECT (e->>'id')::bigint, (e->>'updated_at')::timestamptz FROM jsonb_array_elements(v_vistos) e)
     OR EXISTS (SELECT (e->>'id')::bigint, (e->>'updated_at')::timestamptz FROM jsonb_array_elements(v_vistos) e
                EXCEPT
                SELECT g.id, g.updated_at FROM gastos g WHERE g.id = ANY (v_vivos)) THEN
    RAISE EXCEPTION 'Los gastos de esta rendición cambiaron mientras la cerrabas: tocá Refrescar y volvé a abrir el cierre';
  END IF;

  -- 4b · lo mismo con los pagos al personal (gastos 5). Cada camino que los
  --      escribe toma el lock de la rendicion, el del paso 2.
  IF COALESCE((SELECT -SUM(m.monto) FROM empleado_movimientos m
                WHERE m.rendicion_sucursal_id = v_sucursal_id
                  AND m.rendicion_transportista_id = p_transportista_id
                  AND m.rendicion_fecha = p_fecha), 0) <> v_pagos_visto THEN
    RAISE EXCEPTION 'Los pagos al personal de esta rendición cambiaron mientras la cerrabas: tocá Refrescar y volvé a abrir el cierre';
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
$function$;

-- -------------------------------------------------------------------------
-- 8 · Las RPCs de la liquidacion
-- -------------------------------------------------------------------------
CREATE FUNCTION public.previsualizar_liquidacion(p_empleado_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_e   empleados%ROWTYPE;
  v_p   record;
  v_j   jsonb;
  v_hoy date := public._tablero_hoy();
BEGIN
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin ve y carga el personal' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_e FROM empleados WHERE id = p_empleado_id;
  IF NOT FOUND OR NOT public._empleado_visible(v_e.sucursal_id, v_e.de_las_dos) THEN
    RAISE EXCEPTION 'Ese empleado no existe o no lo podés ver';
  END IF;
  SELECT * INTO v_p FROM public._empleado_periodo_siguiente(v_e);
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  v_j := public._liquidacion_json(v_e, v_p.desde, v_p.hasta);
  IF v_p.desde > v_e.fecha_baja
     AND (v_j#>>'{comisiones,total}')::numeric = 0 AND (v_j#>>'{ajustes,total}')::numeric = 0 THEN
    RETURN NULL;
  END IF;
  RETURN v_j || jsonb_build_object(
    'periodo', jsonb_build_object('desde', v_p.desde, 'hasta', v_p.hasta, 'frecuencia', v_p.frecuencia,
                                  'mas_vencidos', v_p.mas_vencidos),
    'puede_liquidar', v_p.desde <= v_hoy AND v_e.usuario_id IS DISTINCT FROM auth.uid(),
    'en_curso', v_hoy <= v_p.hasta);
END
$fn$;

-- p_liquidacion es LiquidarPayload (src/types/personal.ts). El front manda lo
-- que vio (a_pagar_esperado): si algo cambio en el medio, se rechaza.
CREATE FUNCTION public.liquidar_empleado(p_empleado_id bigint, p_liquidacion jsonb)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_uid      uuid := auth.uid();
  v_hoy      date := public._tablero_hoy();
  v_e        empleados%ROWTYPE;
  v_p        record;
  v_s        record;
  v_rend     record;
  v_j        jsonb;
  v_id       bigint;
  v_desde    date;
  v_hasta    date;
  v_sueldo   numeric;
  v_motivo   text;
  v_pago     numeric;
  v_fpago    date;
  v_esperado numeric;
  v_com      numeric;
  v_aju      numeric;
  v_t        record;
BEGIN
  -- 1 · rol y empleado
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin ve y carga el personal' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_e FROM empleados WHERE id = p_empleado_id FOR UPDATE;
  IF NOT FOUND OR NOT public._empleado_visible(v_e.sucursal_id, v_e.de_las_dos) THEN
    RAISE EXCEPTION 'Ese empleado no existe o no lo podés ver';
  END IF;
  -- 2 · uno mismo
  IF v_e.usuario_id = v_uid THEN
    RAISE EXCEPTION 'Tu propia cuenta la maneja otro admin: no podés liquidarte ni registrarte pagos';
  END IF;
  -- 3 · formato
  BEGIN
    IF jsonb_typeof(p_liquidacion) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'formato';
    END IF;
    v_desde    := NULLIF(p_liquidacion->>'desde', '')::date;
    v_hasta    := NULLIF(p_liquidacion->>'hasta', '')::date;
    v_sueldo   := round(NULLIF(p_liquidacion->>'sueldo', '')::numeric, 2);
    v_motivo   := NULLIF(btrim(p_liquidacion->>'motivo_sueldo'), '');
    v_pago     := round(NULLIF(p_liquidacion->>'pago', '')::numeric, 2);
    v_fpago    := NULLIF(p_liquidacion->>'fecha_pago', '')::date;
    v_esperado := round(NULLIF(p_liquidacion->>'a_pagar_esperado', '')::numeric, 2);
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Hay un dato de la liquidación con un formato inválido';
  END;
  IF v_desde IS NULL OR v_hasta IS NULL OR v_sueldo IS NULL OR v_pago IS NULL OR v_fpago IS NULL OR v_esperado IS NULL
     OR 'NaN'::numeric IN (v_sueldo, v_pago, v_esperado)
     OR GREATEST(abs(v_sueldo), abs(v_pago), abs(v_esperado)) > 9999999999.99 THEN
    RAISE EXCEPTION 'Hay un dato de la liquidación con un formato inválido';
  END IF;
  -- 4 · el periodo es el proximo
  SELECT * INTO v_p FROM public._empleado_periodo_siguiente(v_e);
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Ese empleado no tiene nada para liquidar';
  END IF;
  IF v_p.desde <> v_desde OR v_p.hasta <> v_hasta THEN
    RAISE EXCEPTION 'Ese período ya no es el próximo a liquidar: volvé a abrir la liquidación';
  END IF;
  IF v_desde > v_hoy THEN
    RAISE EXCEPTION 'El período todavía no empezó';
  END IF;
  v_j := public._liquidacion_json(v_e, v_desde, v_hasta, v_sueldo);
  IF v_desde > v_e.fecha_baja
     AND (v_j#>>'{comisiones,total}')::numeric = 0 AND (v_j#>>'{ajustes,total}')::numeric = 0 THEN
    RAISE EXCEPTION 'Ese empleado no tiene nada para liquidar';
  END IF;
  -- 5 · el sueldo
  SELECT * INTO v_s FROM public._liquidacion_sueldo_propuesto(v_e, v_desde, v_hasta);
  IF v_sueldo < 0 THEN
    RAISE EXCEPTION 'El sueldo no puede ser negativo';
  END IF;
  IF v_sueldo <> COALESCE(v_s.sueldo, 0) AND v_motivo IS NULL THEN
    RAISE EXCEPTION 'Escribí por qué cambia el sueldo';
  END IF;
  -- 6 · lo que vio el admin
  IF (v_j->>'a_pagar')::numeric <> v_esperado THEN
    RAISE EXCEPTION 'Algo cambió desde que abriste la liquidación: revisá los números antes de confirmar';
  END IF;
  -- 7 · el pago
  IF v_pago < 0 THEN
    RAISE EXCEPTION 'El pago no puede ser negativo';
  END IF;
  IF v_pago > GREATEST(v_esperado, 0) THEN
    RAISE EXCEPTION 'No se le puede pagar más de lo que le toca: si le adelantás plata, cargá un adelanto';
  END IF;
  IF v_fpago > v_hoy THEN
    RAISE EXCEPTION 'La fecha del pago no puede ser futura';
  END IF;
  -- 8 · de que plata sale
  IF v_pago > 0 THEN
    SELECT * INTO v_rend FROM public._pago_de_rendicion(p_liquidacion);
    v_fpago := COALESCE(v_rend.fecha, v_fpago);
  END IF;
  -- 9 · la liquidacion, sus lineas y sus conceptos
  INSERT INTO empleado_liquidaciones (empleado_id, desde, hasta, frecuencia, sucursal_al_liquidar, de_las_dos,
                                      saldo_anterior, a_pagar, pagado, fecha_pago, creado_por)
  VALUES (v_e.id, v_desde, v_hasta, v_p.frecuencia, v_e.sucursal_id, v_e.de_las_dos,
          (v_j->>'saldo_anterior')::numeric, v_esperado, v_pago, v_fpago, v_uid)
  RETURNING id INTO v_id;

  INSERT INTO empleado_liquidacion_lineas (liquidacion_id, empleado_id, pedido_id, usuario_id, clave, producto_id, combo_id,
                                           origen_precio, regla_id, pct, base, comision, tipo, motivo, entregado_el)
  SELECT v_id, v_e.id, l.pedido_id, l.usuario_id, l.clave, l.producto_id, l.combo_id,
         l.origen_precio, l.regla_id, l.pct, l.base, l.comision, l.tipo, l.motivo, l.entregado_el
    FROM public._liquidacion_lineas(v_e, v_hasta) l;

  -- Lo escrito manda: otra transaccion pudo entregar un pedido despues de
  -- calcular el JSON.
  SELECT COALESCE(round(sum(l.comision) FILTER (WHERE l.tipo = 'inicial'), 2), 0) AS com,
         COALESCE(round(sum(l.base) FILTER (WHERE l.tipo = 'inicial'), 2), 0) AS com_base,
         count(DISTINCT l.pedido_id) FILTER (WHERE l.tipo = 'inicial') AS com_ped,
         COALESCE(round(sum(l.comision) FILTER (WHERE l.tipo <> 'inicial'), 2), 0) AS aju,
         COALESCE(round(sum(l.base) FILTER (WHERE l.tipo <> 'inicial'), 2), 0) AS aju_base,
         count(DISTINCT l.pedido_id) FILTER (WHERE l.tipo <> 'inicial') AS aju_ped
    INTO v_t
    FROM empleado_liquidacion_lineas l WHERE l.liquidacion_id = v_id;
  v_com := v_t.com;
  v_aju := v_t.aju;
  IF v_com <> (v_j#>>'{comisiones,total}')::numeric OR v_aju <> (v_j#>>'{ajustes,total}')::numeric THEN
    RAISE EXCEPTION 'Algo cambió desde que abriste la liquidación: revisá los números antes de confirmar';
  END IF;

  INSERT INTO empleado_liquidacion_conceptos (liquidacion_id, concepto, monto, detalle)
  VALUES (v_id, 'sueldo', v_sueldo, jsonb_build_object('arreglo_id', v_s.arreglo_id, 'propuesto', COALESCE(v_s.sueldo, 0),
                                                       'motivo', v_motivo));
  IF v_com <> 0 THEN
    INSERT INTO empleado_liquidacion_conceptos (liquidacion_id, concepto, monto, detalle)
    VALUES (v_id, 'comision', v_com, jsonb_build_object('pedidos', v_t.com_ped, 'base', v_t.com_base));
  END IF;
  IF v_aju <> 0 THEN
    INSERT INTO empleado_liquidacion_conceptos (liquidacion_id, concepto, monto, detalle)
    VALUES (v_id, 'ajuste_comision', v_aju, jsonb_build_object('pedidos', v_t.aju_ped, 'base', v_t.aju_base));
  END IF;

  -- 10 · los movimientos
  IF v_sueldo <> 0 THEN
    INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, observacion, liquidacion_id, creado_por)
    VALUES (v_e.id, LEAST(v_hasta, v_hoy), 'sueldo', v_sueldo, v_motivo, v_id, v_uid);
  END IF;
  IF v_com <> 0 THEN
    INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, liquidacion_id, creado_por)
    VALUES (v_e.id, LEAST(v_hasta, v_hoy), 'comision', v_com, v_id, v_uid);
  END IF;
  IF v_aju <> 0 THEN
    INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, liquidacion_id, creado_por)
    VALUES (v_e.id, LEAST(v_hasta, v_hoy), 'ajuste_comision', v_aju, v_id, v_uid);
  END IF;
  IF v_pago > 0 THEN
    INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, liquidacion_id, creado_por,
                                      rendicion_transportista_id, rendicion_fecha, rendicion_sucursal_id)
    VALUES (v_e.id, v_fpago, 'pago', -v_pago, v_id, v_uid, v_rend.transportista_id, v_rend.fecha, v_rend.sucursal_id);
  END IF;
  RETURN v_id;
END
$fn$;

-- Solo la ultima. Revierte sus movimientos y libera sus pedidos. El pago de una
-- rendicion ya cerrada queda: la plata salio de verdad y la rendicion no cambia.
CREATE FUNCTION public.anular_liquidacion(p_liquidacion_id bigint, p_motivo text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_uid uuid := auth.uid();
  v_e   empleados%ROWTYPE;
  v_l   empleado_liquidaciones%ROWTYPE;
  v_m   empleado_movimientos%ROWTYPE;
BEGIN
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin ve y carga el personal' USING ERRCODE = '42501';
  END IF;
  SELECT e.* INTO v_e FROM empleados e JOIN empleado_liquidaciones l ON l.empleado_id = e.id
   WHERE l.id = p_liquidacion_id FOR UPDATE OF e;
  IF NOT FOUND OR NOT public._empleado_visible(v_e.sucursal_id, v_e.de_las_dos) THEN
    RAISE EXCEPTION 'Esa liquidación no existe o no la podés ver';
  END IF;
  IF v_e.usuario_id = v_uid THEN
    RAISE EXCEPTION 'Tu propia cuenta la maneja otro admin: no podés liquidarte ni registrarte pagos';
  END IF;
  SELECT * INTO v_l FROM empleado_liquidaciones WHERE id = p_liquidacion_id;
  IF v_l.anulada_at IS NOT NULL THEN
    RAISE EXCEPTION 'Esa liquidación ya está anulada';
  END IF;
  IF EXISTS (SELECT 1 FROM empleado_liquidaciones o
              WHERE o.empleado_id = v_l.empleado_id AND o.anulada_at IS NULL AND o.desde > v_l.desde) THEN
    RAISE EXCEPTION 'Sólo se anula la última liquidación de cada empleado';
  END IF;
  IF p_motivo IS NULL OR btrim(p_motivo) = '' THEN
    RAISE EXCEPTION 'Escribí por qué se anula';
  END IF;

  FOR v_m IN SELECT * FROM empleado_movimientos WHERE liquidacion_id = v_l.id AND revierte_id IS NULL ORDER BY id LOOP
    IF v_m.rendicion_fecha IS NOT NULL THEN
      PERFORM public._rendicion_bloquear(ARRAY[public._rendicion_clave(v_m.rendicion_transportista_id, v_m.rendicion_fecha,
                                                                       v_m.rendicion_sucursal_id)]);
      CONTINUE WHEN public.control_rendicion_cerrado(v_m.rendicion_transportista_id, v_m.rendicion_sucursal_id,
                                                     v_m.rendicion_fecha);
    END IF;
    INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, observacion, revierte_id, liquidacion_id, creado_por,
                                      rendicion_transportista_id, rendicion_fecha, rendicion_sucursal_id)
    VALUES (v_m.empleado_id, public._tablero_hoy(), v_m.tipo, -v_m.monto, btrim(p_motivo), v_m.id, v_l.id, v_uid,
            v_m.rendicion_transportista_id, v_m.rendicion_fecha, v_m.rendicion_sucursal_id);
  END LOOP;

  UPDATE empleado_liquidacion_lineas SET vigente = false WHERE liquidacion_id = v_l.id;
  UPDATE empleado_liquidaciones
     SET anulada_at = now(), anulada_por = v_uid, motivo_anulacion = btrim(p_motivo)
   WHERE id = v_l.id;
END
$fn$;

-- La forma de DetalleLiquidacion, desde lo congelado y no desde lo vivo.
CREATE FUNCTION public.obtener_liquidacion(p_liquidacion_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_l empleado_liquidaciones%ROWTYPE;
  v_e empleados%ROWTYPE;
  v_d jsonb;
BEGIN
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin ve y carga el personal' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_l FROM empleado_liquidaciones WHERE id = p_liquidacion_id;
  SELECT * INTO v_e FROM empleados WHERE id = v_l.empleado_id;
  IF v_e.id IS NULL OR NOT public._empleado_visible(v_e.sucursal_id, v_e.de_las_dos) THEN
    RAISE EXCEPTION 'Esa liquidación no existe o no la podés ver';
  END IF;
  SELECT c.detalle INTO v_d FROM empleado_liquidacion_conceptos c
   WHERE c.liquidacion_id = v_l.id AND c.concepto = 'sueldo';
  RETURN public._liquidacion_resumen_json(v_l) || jsonb_build_object(
    'sueldo_propuesto', (v_d->>'propuesto')::numeric,
    'motivo_sueldo', v_d->>'motivo',
    'pedidos', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('pedido_id', x.pedido_id, 'fecha', x.fecha, 'entregado_el', x.entregado_el,
                                          'cliente', x.cliente, 'base', round(x.base, 2), 'comision', round(x.comision, 2))
                       ORDER BY x.entregado_el, x.pedido_id)
        FROM (SELECT i.pedido_id, p.fecha, i.entregado_el, COALESCE(c.nombre_fantasia, c.razon_social) AS cliente,
                     sum(i.base) AS base, sum(i.comision) AS comision
                FROM empleado_liquidacion_lineas i
                JOIN pedidos p ON p.id = i.pedido_id
                LEFT JOIN clientes c ON c.id = p.cliente_id
               WHERE i.liquidacion_id = v_l.id AND i.tipo = 'inicial'
               GROUP BY i.pedido_id, p.fecha, i.entregado_el, c.nombre_fantasia, c.razon_social) x), '[]'::jsonb),
    'ajustes', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('pedido_id', y.pedido_id, 'motivo', y.motivo,
                                          'base', round(y.base, 2), 'comision', round(y.comision, 2))
                       ORDER BY y.pedido_id, y.motivo)
        FROM (SELECT a.pedido_id, a.motivo, sum(a.base) AS base, sum(a.comision) AS comision
                FROM empleado_liquidacion_lineas a
               WHERE a.liquidacion_id = v_l.id AND a.tipo <> 'inicial'
               GROUP BY a.pedido_id, a.motivo) y), '[]'::jsonb));
END
$fn$;

-- -------------------------------------------------------------------------
-- 9 · Permisos
-- -------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public._comision_lineas(bigint[]) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._empleado_dia_de_entrega(timestamptz, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._periodo_que_contiene(date, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._empleado_ultima_hasta(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._empleado_periodo_siguiente(public.empleados) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._liquidacion_sueldo_propuesto(public.empleados, date, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._liquidacion_lineas(public.empleados, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._liquidacion_json(public.empleados, date, date, numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._liquidacion_resumen_json(public.empleado_liquidaciones) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._movimiento_origen_json(public.empleado_movimientos) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._pago_de_rendicion(jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.personal_por_mes(date, date, bigint[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._comision_lineas(bigint[]) TO service_role;
GRANT EXECUTE ON FUNCTION public._empleado_dia_de_entrega(timestamptz, date) TO service_role;
GRANT EXECUTE ON FUNCTION public._periodo_que_contiene(date, text) TO service_role;
GRANT EXECUTE ON FUNCTION public._empleado_ultima_hasta(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public._empleado_periodo_siguiente(public.empleados) TO service_role;
GRANT EXECUTE ON FUNCTION public._liquidacion_sueldo_propuesto(public.empleados, date, date) TO service_role;
GRANT EXECUTE ON FUNCTION public._liquidacion_lineas(public.empleados, date) TO service_role;
GRANT EXECUTE ON FUNCTION public._liquidacion_json(public.empleados, date, date, numeric) TO service_role;
GRANT EXECUTE ON FUNCTION public._liquidacion_resumen_json(public.empleado_liquidaciones) TO service_role;
GRANT EXECUTE ON FUNCTION public._movimiento_origen_json(public.empleado_movimientos) TO service_role;
GRANT EXECUTE ON FUNCTION public._pago_de_rendicion(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.personal_por_mes(date, date, bigint[]) TO service_role;

-- Las de trigger: sin EXECUTE para nadie.
REVOKE ALL ON FUNCTION public.empleado_arreglos_periodo_cerrado() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.empleados_periodo_cerrado() FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.previsualizar_liquidacion(bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.liquidar_empleado(bigint, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.anular_liquidacion(bigint, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.obtener_liquidacion(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.previsualizar_liquidacion(bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.liquidar_empleado(bigint, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.anular_liquidacion(bigint, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.obtener_liquidacion(bigint) TO authenticated, service_role;

-- Los que tenia antes del DROP.
REVOKE ALL ON FUNCTION public.obtener_resumen_rendiciones(date, date, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.obtener_resumen_rendiciones(date, date, uuid) TO authenticated, service_role;

-- -------------------------------------------------------------------------
-- 10 · calcular_comisiones no se movio
-- -------------------------------------------------------------------------
DO $despues$
DECLARE
  r record;
BEGIN
  IF (SELECT count(*) FROM _comisiones_antes) <> 24 THEN
    RAISE EXCEPTION 'la foto de calcular_comisiones no tiene los 24 meses';
  END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', (SELECT admin FROM _comisiones_antes LIMIT 1))::text, true);
  FOR r IN SELECT * FROM _comisiones_antes ORDER BY mes, suc LOOP
    IF public.calcular_comisiones(r.mes, (r.mes + interval '1 month - 1 day')::date, ARRAY[r.suc]) IS DISTINCT FROM r.j THEN
      RAISE EXCEPTION 'calcular_comisiones cambio en % de la sucursal %', r.mes, r.suc;
    END IF;
  END LOOP;
  PERFORM set_config('request.jwt.claims', '', true);
END
$despues$;

DROP TABLE _comisiones_antes;

-- -------------------------------------------------------------------------
-- 11 · Verificacion estructural
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.empleado_liquidaciones', 'public.empleado_liquidacion_conceptos',
                           'public.empleado_liquidacion_lineas'] LOOP
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = f::regclass)
       OR EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = f::regclass) THEN
      RAISE EXCEPTION '% quedo sin RLS o con policies', f;
    END IF;
    IF has_table_privilege('anon', f, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
       OR has_table_privilege('authenticated', f, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
       OR has_any_column_privilege('anon', f, 'SELECT,INSERT,UPDATE,REFERENCES')
       OR has_any_column_privilege('authenticated', f, 'SELECT,INSERT,UPDATE,REFERENCES') THEN
      RAISE EXCEPTION '% quedo con privilegios para anon o authenticated', f;
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.empleado_arreglos'::regclass
                                            AND tgname = 'trg_empleado_arreglos_periodo_cerrado')
     OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.empleados'::regclass
                                               AND tgname = 'trg_empleados_periodo_cerrado') THEN
    RAISE EXCEPTION 'faltan las guardas de lo liquidado';
  END IF;
  FOREACH f IN ARRAY ARRAY['public._comision_lineas(bigint[])', 'public._empleado_dia_de_entrega(timestamptz,date)',
                           'public._periodo_que_contiene(date,text)', 'public._empleado_ultima_hasta(bigint)',
                           'public._empleado_periodo_siguiente(empleados)',
                           'public._liquidacion_sueldo_propuesto(empleados,date,date)',
                           'public._liquidacion_lineas(empleados,date)',
                           'public._liquidacion_json(empleados,date,date,numeric)',
                           'public._liquidacion_resumen_json(empleado_liquidaciones)',
                           'public._movimiento_origen_json(empleado_movimientos)',
                           'public._pago_de_rendicion(jsonb)', 'public.personal_por_mes(date,date,bigint[])',
                           'public.empleado_arreglos_periodo_cerrado()', 'public.empleados_periodo_cerrado()'] LOOP
    IF has_function_privilege('anon', f, 'EXECUTE') OR has_function_privilege('authenticated', f, 'EXECUTE') THEN
      RAISE EXCEPTION '% quedo alcanzable desde el front', f;
    END IF;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.previsualizar_liquidacion(bigint)', 'public.liquidar_empleado(bigint,jsonb)',
                           'public.anular_liquidacion(bigint,text)', 'public.obtener_liquidacion(bigint)',
                           'public.obtener_resumen_rendiciones(date,date,uuid)',
                           'public.confirmar_rendicion(date,uuid,text,jsonb,text)'] LOOP
    IF has_function_privilege('anon', f, 'EXECUTE') OR NOT has_function_privilege('authenticated', f, 'EXECUTE') THEN
      RAISE EXCEPTION 'los EXECUTE de % no quedaron como se esperaba', f;
    END IF;
  END LOOP;
END
$verif$;
