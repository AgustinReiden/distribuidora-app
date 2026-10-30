-- ============================================================================
-- 421 · Comisiones y metas: un mes cerrado no cambia (#1320, #1321; plan #1308
-- tarjeta 5)
-- ============================================================================
-- El número se elige al aplicarla, contra el ledger de prod y origin/main.
-- Aplicar desde el contenido LF. Ensayo: scripts/test-comisiones-1320-1321.sql.
--
-- Decisión del dueño (29/10, #1320): la comisión de un mes liquidado se
-- congela, y el % lo cambia sólo el admin (el encargado no, tampoco el suyo).
-- "Mes cerrado" es todo mes anterior al mes en curso, en el día argentino
-- (`_tablero_hoy()`). Se congela por vigencia, no por foto: no hace falta un
-- paso de "liquidar" y el cálculo de cualquier mes sale de lo que regía en él.
--
-- COM-1 · El % por defecto tenía un solo valor por sucursal, en
--   `politicas_comerciales`, y `calcular_comisiones` lo aplicaba a cualquier
--   mes: subirlo de 2 a 10 multiplicaba por 5 la comisión de septiembre ya
--   liquidada. Ahora vive con vigencia mensual en `comision_pct_vigencias`
--   (una fila por sucursal y mes desde el que rige). Cambiarlo rige desde el
--   1° del mes en curso; el cálculo toma, ítem por ítem, el del mes del pedido.
--   `politicas_comerciales.comision_pct_*` queda como espejo del vigente, que
--   es lo que lee /configuracion. Y `actualizar_comisiones_default` pasa a ser
--   sólo de admin.
-- COM-2 · Dar de baja una regla hacía `activo = false`, y el cálculo filtraba
--   `WHERE r.activo`: la regla desaparecía también de los meses en que rigió.
--   Ahora la baja anota `baja_desde` (el día de la baja) y el cálculo la
--   aplica a los pedidos anteriores. Además, `guardar_comision_regla` no deja
--   que una regla nueva ni una edición toque un mes cerrado: una regla nueva
--   rige desde el mes en curso, y editar una que ya rigió en un mes cerrado la
--   corta ahí (queda dada de baja desde el 1° del mes) y crea otra con lo
--   pedido desde el mes en curso. Sólo puede moverse su `vigente_hasta`, y no
--   a un mes cerrado.
-- COM-4 · Un pago con `adelanto_sueldo` sacaba de la comisión el pedido
--   entero. La regla es que no comisiona LO COBRADO con adelanto: cada línea
--   comisiona por la parte de la boleta que no se pagó así
--   (1 − adelanto / total). Cuentan todos los adelantos del pedido, se carguen
--   cuando se carguen (decisión del dueño, 29/10): el consumo de un empleado
--   se suele saldar con el adelanto del mes siguiente (2 de los 7 casos de
--   prod), y un corte al fin del mes lo dejaría comisionar entero. Por eso un
--   adelanto cargado después del cierre sí corrige el mes del pedido: es un
--   dato, no un cambio de configuración. Aplicar esto no mueve agosto ni
--   septiembre; sólo los dos pedidos de octubre pagados en parte.
-- COM-5 · El % por defecto se elegía por `perfiles.rol`: un chofer con el rol
--   extra de preventista cobraba el % del resto. Ahora es el de preventista
--   para quien actúa como preventista en la sucursal del pedido
--   (`_actua_como_preventista`): rol base preventista, o el extra en esa
--   sucursal; admin y encargado van al % del resto, como antes. Hoy no hay
--   casos: `perfil_roles_rol_check` sólo acepta el extra 'transportista'. Es
--   para que el día que se abra el extra de preventista no haya que volver acá.
-- COM-3 · Las metas:
--   · `desactivar_meta_preventista` y la edición de `guardar_meta_preventista`
--     operaban por `p_id` sin mirar la sucursal de la meta. Ahora la meta tiene
--     que ser de una sucursal del que llama, y la edición no la muda de
--     sucursal.
--   · El `ON CONFLICT` del alta no incluía la sucursal: la meta de un
--     preventista que trabaja en dos sucursales pisaba la de la otra. El
--     índice único suma `sucursal_id`.
--   · La meta gerencial de la Red (`sucursal_id` NULL) la cargaba cualquier
--     admin; ahora sólo el que tiene todas las sucursales activas, igual que
--     la policy de lectura de `metas_gerenciales` (#1272).
--   · El vendedor de una regla de comisión y el de una meta se acotan a los
--     usuarios del que llama (gate de #1291): salen de
--     `scripts/rpcs-definer-permitidas.json`.
-- Día argentino (#1250): `guardar_comision_regla`, `guardar_meta_preventista`
--   y el default de `comision_reglas.vigente_desde` usaban `current_date`;
--   salen de `scripts/fechas-utc-permitidas.json`.
--
-- "Venta por vendedor" (CLAUDE.md, migs 241/318): sin cambios. El monto sale
-- de las líneas sin bonificación (Σ subtotal = total − envío), porque las
-- reglas son por producto, categoría y origen del precio.
--
-- `reporte_gerencial` (sólo su CTE `nc`, parcheado por ancla sobre el cuerpo
-- vivo): `kpis.base_comision` y `vendedores[].base_nc` copiaban la exclusión del
-- pedido entero con adelanto, "igual que en calcular_comisiones (si no, no
-- cierran)". Pasan a la misma regla de COM-4. Sin cambios de firma ni del JSON.
-- ============================================================================

BEGIN;

DO $premisas$
DECLARE
  v_f record;
BEGIN
  -- El parche de reporte_gerencial busca anclas con saltos de línea LF.
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'mig 421 · la migración llegó con CRLF: aplicarla desde el contenido LF';
  END IF;

  -- Los cuerpos vivos son los que se leyeron (2026-10-29, ledger en la 420).
  FOR v_f IN
    SELECT x.firma, x.md5, md5(pg_get_functiondef(x.firma::regprocedure)) AS md5_vivo
      FROM (VALUES
        ('public.calcular_comisiones(date,date,bigint[])',                                          '6057d2c5c37d48bccda9e05832062ebc'),
        ('public.actualizar_comisiones_default(numeric,numeric)',                                   '7c5f5fa13eca951f09ebc3377a26b338'),
        ('public.guardar_comision_regla(bigint,bigint,uuid,text,numeric,date,date,bigint,uuid)',    '498954d8bfaaeafd0411ac4a443a5915'),
        ('public.desactivar_comision_regla(bigint)',                                                '0f9dbe560ce164339fdc4e44fd42c73e'),
        ('public.guardar_meta_preventista(bigint,bigint,uuid,date,text,numeric,uuid,uuid,bigint[],date)', '3fae121dc97014a7ca91cabe992c6530'),
        ('public.desactivar_meta_preventista(bigint)',                                              'c4cca406c5247ec6bd5c413fc4567975'),
        ('public.guardar_meta_gerencial(bigint,date,text,numeric)',                                 '398fbb6c2909edf1a33e823f21ce9758'),
        ('public.reporte_gerencial(bigint,date,date,boolean,boolean)',                              'd05d1f8693e8d1a2e067509dd13c4b8b')
      ) AS x(firma, md5)
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION 'mig 421 · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;

  IF to_regclass('public.comision_pct_vigencias') IS NOT NULL THEN
    RAISE EXCEPTION 'mig 421 · comision_pct_vigencias ya existe';
  END IF;
  IF to_regprocedure('public._tablero_hoy()') IS NULL
     OR to_regprocedure('public._actua_como_preventista(uuid,bigint)') IS NULL
     OR to_regprocedure('public._tiene_todas_las_sucursales()') IS NULL
     OR to_regprocedure('public.admin_comparte_sucursal_con(uuid)') IS NULL
     OR to_regprocedure('public.comision_regla_alcanzable(bigint)') IS NULL THEN
    RAISE EXCEPTION 'mig 421 · falta un helper (_tablero_hoy, _actua_como_preventista, _tiene_todas_las_sucursales, admin_comparte_sucursal_con o comision_regla_alcanzable)';
  END IF;
END
$premisas$;

-- ----------------------------------------------------------------------------
-- 1 · El % por defecto, con vigencia mensual (COM-1)
-- ----------------------------------------------------------------------------
CREATE TABLE public.comision_pct_vigencias (
  sucursal_id     bigint       NOT NULL REFERENCES public.sucursales(id) ON DELETE CASCADE,
  vigente_desde   date         NOT NULL,
  pct_preventista numeric(5,2) NOT NULL,
  pct_otros       numeric(5,2) NOT NULL,
  usuario_id      uuid         REFERENCES public.perfiles(id) ON DELETE SET NULL,
  actualizado_en  timestamptz  NOT NULL DEFAULT now(),
  PRIMARY KEY (sucursal_id, vigente_desde),
  CONSTRAINT comision_pct_vigencias_mes CHECK (vigente_desde = date_trunc('month', vigente_desde)::date),
  CONSTRAINT comision_pct_vigencias_preventista CHECK (pct_preventista >= 0 AND pct_preventista <= 100),
  CONSTRAINT comision_pct_vigencias_otros CHECK (pct_otros >= 0 AND pct_otros <= 100)
);

COMMENT ON TABLE public.comision_pct_vigencias IS
  'El % de comisión por defecto de cada sucursal, por mes desde el que rige (#1320). '
  'calcular_comisiones usa el del mes del pedido, así que un mes cerrado no cambia. '
  'La escribe sólo actualizar_comisiones_default (admin), desde el mes en curso. '
  'Sólo de server: RLS sin policies y sin grants.';

ALTER TABLE public.comision_pct_vigencias ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.comision_pct_vigencias FROM PUBLIC, anon, authenticated;

-- Lo que rige hoy rige desde siempre: no hay historia de cambios del % (audit_logs
-- no registra ninguno), y es lo que el cálculo venía usando para todos los meses.
INSERT INTO public.comision_pct_vigencias (sucursal_id, vigente_desde, pct_preventista, pct_otros, usuario_id, actualizado_en)
SELECT pc.sucursal_id, DATE '2000-01-01',
       COALESCE(pc.comision_pct_preventista, 2), COALESCE(pc.comision_pct_otros, 0),
       pc.actualizado_por, COALESCE(pc.actualizado_en, now())
  FROM public.politicas_comerciales pc;

COMMENT ON COLUMN public.politicas_comerciales.comision_pct_preventista IS
  'Espejo del % de preventista que rige este mes. La historia, que es la que usa el cálculo, '
  'vive en comision_pct_vigencias (#1320). Lo escribe actualizar_comisiones_default.';
COMMENT ON COLUMN public.politicas_comerciales.comision_pct_otros IS
  'Espejo del % del resto que rige este mes. La historia, que es la que usa el cálculo, '
  'vive en comision_pct_vigencias (#1320). Lo escribe actualizar_comisiones_default.';

-- ----------------------------------------------------------------------------
-- 2 · La baja de una regla tiene fecha (COM-2)
-- ----------------------------------------------------------------------------
ALTER TABLE public.comision_reglas ADD COLUMN baja_desde date;

-- Hoy no hay reglas. Una dada de baja de antes de esta migración ya no regía en
-- ningún mes: se le pone la baja en su propio inicio, y el cálculo no cambia.
UPDATE public.comision_reglas SET baja_desde = vigente_desde WHERE NOT activo;

ALTER TABLE public.comision_reglas
  ADD CONSTRAINT comision_reglas_baja_coherente CHECK ((baja_desde IS NULL) = activo);

ALTER TABLE public.comision_reglas
  ALTER COLUMN vigente_desde SET DEFAULT ((now() AT TIME ZONE 'America/Argentina/Tucuman'))::date;

COMMENT ON COLUMN public.comision_reglas.baja_desde IS
  'Día de la baja: la regla rige para los pedidos anteriores y no para ese día en adelante (#1320). '
  'NULL mientras está activa.';

-- ----------------------------------------------------------------------------
-- 3 · Una meta es de su sucursal (COM-3)
-- ----------------------------------------------------------------------------
DROP INDEX public.metas_preventista_uidx;
CREATE UNIQUE INDEX metas_preventista_uidx ON public.metas_preventista USING btree (
  sucursal_id, preventista_id, periodo, periodo_fin, tipo_meta,
  COALESCE(marca_id, '00000000-0000-0000-0000-000000000000'::uuid),
  COALESCE(categoria_id, '00000000-0000-0000-0000-000000000000'::uuid),
  COALESCE(producto_ids, '{}'::bigint[])
);

-- ----------------------------------------------------------------------------
-- 4 · calcular_comisiones (COM-1, COM-2, COM-4, COM-5)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.calcular_comisiones(p_desde date, p_hasta date, p_sucursal_ids bigint[] DEFAULT NULL::bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
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

  WITH ped AS (
    -- "Venta por vendedor" (CLAUDE.md): entregado, sin canjes ni vales blancos,
    -- por pedidos.fecha, de pedidos.usuario_id.
    SELECT p.id, p.usuario_id, p.fecha, p.sucursal_id,
           -- COM-4 (#1321): no comisiona lo cobrado con adelanto de sueldo
           -- (consumo de empleado). Cada línea comisiona por la parte de la
           -- boleta que no se pagó así. Cuentan todos sus adelantos, también
           -- los del mes siguiente (decisión del dueño, 29/10).
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
    WHERE p.estado = 'entregado'
      AND p.canal <> 'cambio'
      AND p.tipo_factura IS DISTINCT FROM 'VB'
      AND p.fecha BETWEEN p_desde AND p_hasta
      AND p.sucursal_id = ANY(v_sucursales)
      AND p.usuario_id IN (SELECT id FROM perfiles)
  ),
  vend AS (
    -- COM-5 (#1321): el % de preventista es de quien actúa como preventista en
    -- la sucursal del pedido (rol base o el extra), no del rol base.
    SELECT u.usuario_id, u.sucursal_id,
           _actua_como_preventista(u.usuario_id, u.sucursal_id) AS es_preventista
    FROM (SELECT DISTINCT usuario_id, sucursal_id FROM ped) u
  ),
  pct_mes AS (
    -- COM-1 (#1320): el default que regía en el mes del pedido.
    SELECT m.sucursal_id, m.mes,
           COALESCE(v.pct_preventista, 2) AS pct_preventista,
           COALESCE(v.pct_otros, 0)       AS pct_otros
    FROM (SELECT DISTINCT sucursal_id, date_trunc('month', fecha)::date AS mes FROM ped) m
    LEFT JOIN LATERAL (
      SELECT cv.pct_preventista, cv.pct_otros
        FROM comision_pct_vigencias cv
       WHERE cv.sucursal_id = m.sucursal_id AND cv.vigente_desde <= m.mes
       ORDER BY cv.vigente_desde DESC
       LIMIT 1
    ) v ON true
  ),
  it AS (
    SELECT ped.usuario_id, ped.fecha, ped.sucursal_id,
           pi.subtotal * ped.factor AS subtotal,
           pi.producto_id,
           pi.origen_precio,
           prod.categoria_id,
           CASE WHEN vend.es_preventista THEN pm.pct_preventista ELSE pm.pct_otros END AS pct_default
    FROM ped
    JOIN pedido_items pi ON pi.pedido_id = ped.id
    LEFT JOIN productos prod ON prod.id = pi.producto_id
    JOIN vend ON vend.usuario_id = ped.usuario_id AND vend.sucursal_id = ped.sucursal_id
    JOIN pct_mes pm ON pm.sucursal_id = ped.sucursal_id
                   AND pm.mes = date_trunc('month', ped.fecha)::date
    WHERE COALESCE(pi.es_bonificacion, false) = false
      -- Pagado entero con adelanto: no entra, ni en la base ni en los ítems.
      AND ped.factor > 0
  ),
  con_pct AS (
    SELECT it.*,
      COALESCE((
        SELECT r.porcentaje FROM comision_reglas r
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
      ), it.pct_default) AS pct
    FROM it
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

-- ----------------------------------------------------------------------------
-- 4b · reporte_gerencial: su base de comisión, con la misma regla (COM-4)
-- ----------------------------------------------------------------------------
-- Sólo el CTE `nc`, que alimenta `kpis.base_comision` y `vendedores[].base_nc`.
-- Se parchea por ancla sobre el cuerpo vivo (md5 verificado arriba): el resto
-- del reporte no se toca. El pedido pagado entero con adelanto entra con 0:
-- así `base_nc` de un vendedor que sólo tiene esos da 0 y no cae a su venta
-- por el `COALESCE(n.base_nc, e.venta)` (antes caía). `kpis.base_comision` no
-- cambia por eso.
DO $parche_gerencial$
DECLARE
  v_def   text := pg_get_functiondef('public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure);
  v_ancla text := $ancla$    SELECT usuario_id, GREATEST(total - cargo_envio, 0) AS total FROM pedidos
    WHERE estado='entregado' AND canal <> 'cambio'
      AND tipo_factura IS DISTINCT FROM 'VB'  -- 3XB: no comisiona
      -- 3XB (N16): el pedido cobrado con adelanto de sueldo tampoco, igual
      -- que en calcular_comisiones (si no, base_comision y base_nc no cierran).
      AND NOT EXISTS (SELECT 1 FROM pagos g WHERE g.pedido_id = pedidos.id AND g.forma_pago = 'adelanto_sueldo')
      AND fecha BETWEEN p_desde AND p_hasta AND sucursal_id = ANY(v_sucursales)
      AND usuario_id IN (SELECT id FROM perfiles)
  ),$ancla$;
  v_nuevo text := $nuevo$    -- #1321 (COM-4): lo cobrado con adelanto de sueldo no comisiona: entra
    -- la parte de la boleta que no se pago asi (pagada entera, 0), con todos
    -- sus adelantos. La misma regla que calcular_comisiones (si no,
    -- base_comision y base_nc no cierran). Un vendedor con todo pagado con
    -- adelanto queda con base 0, no con su venta.
    SELECT pe.usuario_id,
           ROUND(GREATEST(pe.total - pe.cargo_envio, 0)
                 * CASE WHEN pe.total > 0
                        THEN 1 - LEAST(COALESCE(ad.monto, 0), pe.total) / pe.total
                        ELSE 1 END, 2) AS total
      FROM pedidos pe
      LEFT JOIN LATERAL (
        SELECT SUM(g.monto) AS monto FROM pagos g
         WHERE g.pedido_id = pe.id AND g.forma_pago = 'adelanto_sueldo'
      ) ad ON true
     WHERE pe.estado='entregado' AND pe.canal <> 'cambio'
       AND pe.tipo_factura IS DISTINCT FROM 'VB'  -- 3XB: no comisiona
       AND pe.fecha BETWEEN p_desde AND p_hasta AND pe.sucursal_id = ANY(v_sucursales)
       AND pe.usuario_id IN (SELECT id FROM perfiles)
  ),$nuevo$;
  v_n     int;
BEGIN
  v_n := (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig 421 · reporte_gerencial: el ancla del CTE nc aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(v_def, v_ancla, v_nuevo);
END
$parche_gerencial$;

-- ----------------------------------------------------------------------------
-- 5 · actualizar_comisiones_default: sólo admin, rige desde el mes en curso
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.actualizar_comisiones_default(p_pct_preventista numeric, p_pct_otros numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal bigint := public.current_sucursal_id();
  v_mes      date   := date_trunc('month', public._tablero_hoy())::date;
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la sucursal activa';
  END IF;

  -- COM-1 (#1320, decisión del dueño): el % lo cambia sólo el admin. El
  -- encargado no, tampoco el suyo.
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin puede cambiar el porcentaje de comisión'
      USING ERRCODE = '42501';
  END IF;

  IF p_pct_preventista IS NULL OR p_pct_preventista < 0 OR p_pct_preventista > 100 THEN
    RAISE EXCEPTION 'El porcentaje de preventista debe estar entre 0 y 100';
  END IF;
  IF p_pct_otros IS NULL OR p_pct_otros < 0 OR p_pct_otros > 100 THEN
    RAISE EXCEPTION 'El porcentaje del resto debe estar entre 0 y 100';
  END IF;

  -- Rige desde el 1° del mes en curso; los meses cerrados conservan el suyo.
  INSERT INTO public.comision_pct_vigencias (
    sucursal_id, vigente_desde, pct_preventista, pct_otros, usuario_id, actualizado_en
  )
  VALUES (v_sucursal, v_mes, p_pct_preventista, p_pct_otros, auth.uid(), now())
  ON CONFLICT (sucursal_id, vigente_desde) DO UPDATE
    SET pct_preventista = EXCLUDED.pct_preventista,
        pct_otros       = EXCLUDED.pct_otros,
        usuario_id      = EXCLUDED.usuario_id,
        actualizado_en  = EXCLUDED.actualizado_en;

  -- El espejo que lee /configuracion.
  INSERT INTO public.politicas_comerciales (
    sucursal_id, comision_pct_preventista, comision_pct_otros, actualizado_por, actualizado_en
  )
  VALUES (v_sucursal, p_pct_preventista, p_pct_otros, auth.uid(), now())
  ON CONFLICT (sucursal_id) DO UPDATE
    SET comision_pct_preventista = EXCLUDED.comision_pct_preventista,
        comision_pct_otros       = EXCLUDED.comision_pct_otros,
        actualizado_por          = EXCLUDED.actualizado_por,
        actualizado_en           = EXCLUDED.actualizado_en;

  RETURN jsonb_build_object(
    'comision_pct_preventista', p_pct_preventista,
    'comision_pct_otros', p_pct_otros,
    'vigente_desde', v_mes
  );
END;
$function$;

-- ----------------------------------------------------------------------------
-- 6 · guardar_comision_regla: no toca un mes cerrado (COM-2, COM-3)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guardar_comision_regla(p_id bigint, p_sucursal_id bigint, p_preventista_id uuid, p_origen_precio text, p_porcentaje numeric, p_vigente_desde date DEFAULT NULL::date, p_vigente_hasta date DEFAULT NULL::date, p_producto_id bigint DEFAULT NULL::bigint, p_categoria_id uuid DEFAULT NULL::uuid)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_id    bigint;
  v_hoy   date := _tablero_hoy();
  v_corte date := date_trunc('month', _tablero_hoy())::date;
  v_desde date;
  v_r     comision_reglas%ROWTYPE;
BEGIN
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Solo un admin puede definir reglas de comision' USING ERRCODE = '42501';
  END IF;

  -- #1048: los admins no ven toda la red. Una regla con sucursal es de esa
  -- sucursal; una global rige en todas y sólo la toca quien las tiene todas.
  IF NOT comision_regla_alcanzable(p_sucursal_id) THEN
    RAISE EXCEPTION '%', CASE WHEN p_sucursal_id IS NULL
        THEN 'Una regla para todas las sucursales sólo la puede definir un admin asignado a todas'
        ELSE format('No tenés asignada la sucursal %s', p_sucursal_id) END
      USING ERRCODE = '42501';
  END IF;

  -- #1291: el vendedor de la regla es uno de los usuarios del admin.
  IF p_preventista_id IS NOT NULL AND NOT admin_comparte_sucursal_con(p_preventista_id) THEN
    RAISE EXCEPTION 'Ese vendedor no trabaja en ninguna de tus sucursales' USING ERRCODE = '42501';
  END IF;

  IF p_porcentaje IS NULL OR p_porcentaje < 0 OR p_porcentaje > 100 THEN
    RAISE EXCEPTION 'El porcentaje debe estar entre 0 y 100';
  END IF;

  -- #1320: los meses anteriores al mes en curso están cerrados. Ninguna regla
  -- nueva ni ninguna edición cambia lo que regía en ellos.
  IF p_id IS NULL THEN
    v_desde := COALESCE(p_vigente_desde, v_hoy);
    IF v_desde < v_corte THEN
      RAISE EXCEPTION 'Una regla no puede regir antes del %: los meses anteriores ya cerraron',
        to_char(v_corte, 'DD/MM/YYYY');
    END IF;
    IF p_vigente_hasta IS NOT NULL AND p_vigente_hasta < v_desde THEN
      RAISE EXCEPTION 'La regla no puede terminar antes de empezar';
    END IF;

    INSERT INTO comision_reglas (
      sucursal_id, preventista_id, origen_precio, producto_id, categoria_id,
      porcentaje, vigente_desde, vigente_hasta, usuario_id
    ) VALUES (
      p_sucursal_id, p_preventista_id, NULLIF(p_origen_precio, ''), p_producto_id, p_categoria_id,
      p_porcentaje, v_desde, p_vigente_hasta, auth.uid()
    )
    RETURNING id INTO v_id;
    RETURN v_id;
  END IF;

  SELECT * INTO v_r FROM comision_reglas WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La regla % no existe', p_id USING ERRCODE = 'no_data_found';
  END IF;
  IF NOT comision_regla_alcanzable(v_r.sucursal_id) THEN
    RAISE EXCEPTION 'La regla % es de una sucursal que no tenés asignada', p_id
      USING ERRCODE = '42501';
  END IF;
  IF v_r.baja_desde IS NOT NULL THEN
    RAISE EXCEPTION 'La regla % está dada de baja: cargá una nueva', p_id;
  END IF;

  v_desde := COALESCE(p_vigente_desde, v_r.vigente_desde);

  -- Todavía no rigió en un mes cerrado: se edita entera.
  IF v_r.vigente_desde >= v_corte THEN
    IF v_desde < v_corte THEN
      RAISE EXCEPTION 'Una regla no puede regir antes del %: los meses anteriores ya cerraron',
        to_char(v_corte, 'DD/MM/YYYY');
    END IF;
    IF p_vigente_hasta IS NOT NULL AND p_vigente_hasta < v_desde THEN
      RAISE EXCEPTION 'La regla no puede terminar antes de empezar';
    END IF;
    UPDATE comision_reglas SET
      sucursal_id    = p_sucursal_id,
      preventista_id = p_preventista_id,
      origen_precio  = NULLIF(p_origen_precio, ''),
      producto_id    = p_producto_id,
      categoria_id   = p_categoria_id,
      porcentaje     = p_porcentaje,
      vigente_desde  = v_desde,
      vigente_hasta  = p_vigente_hasta
    WHERE id = p_id
    RETURNING id INTO v_id;
    RETURN v_id;
  END IF;

  -- Ya rigió en un mes cerrado.
  IF v_r.vigente_hasta IS NOT NULL AND v_r.vigente_hasta < v_corte THEN
    RAISE EXCEPTION 'La regla % terminó el %: sus meses ya cerraron y no se puede cambiar',
      p_id, to_char(v_r.vigente_hasta, 'DD/MM/YYYY');
  END IF;

  IF (v_r.sucursal_id, v_r.preventista_id, v_r.origen_precio::text, v_r.producto_id,
      v_r.categoria_id, v_r.porcentaje, v_r.vigente_desde)
     IS NOT DISTINCT FROM
     (p_sucursal_id, p_preventista_id, NULLIF(p_origen_precio, ''), p_producto_id,
      p_categoria_id, p_porcentaje, v_desde) THEN
    -- Sólo cambia hasta cuándo rige: se puede, mientras no termine en un mes cerrado.
    IF p_vigente_hasta IS NOT NULL AND p_vigente_hasta < v_corte - 1 THEN
      RAISE EXCEPTION 'La regla % no puede terminar antes del %: los meses anteriores ya cerraron',
        p_id, to_char(v_corte - 1, 'DD/MM/YYYY');
    END IF;
    UPDATE comision_reglas SET vigente_hasta = p_vigente_hasta WHERE id = p_id;
    RETURN p_id;
  END IF;

  -- Cambia lo que rige: la regla vieja queda como estaba hasta el fin del mes
  -- anterior (dada de baja desde el 1° del mes en curso) y desde el mes en
  -- curso rige una nueva con lo pedido. Se devuelve la nueva.
  UPDATE comision_reglas
     SET vigente_hasta = v_corte - 1,
         activo        = false,
         baja_desde    = v_corte
   WHERE id = p_id;

  v_desde := GREATEST(v_desde, v_corte);
  IF p_vigente_hasta IS NOT NULL AND p_vigente_hasta < v_desde THEN
    RAISE EXCEPTION 'La regla no puede terminar antes de empezar';
  END IF;

  INSERT INTO comision_reglas (
    sucursal_id, preventista_id, origen_precio, producto_id, categoria_id,
    porcentaje, vigente_desde, vigente_hasta, usuario_id
  ) VALUES (
    p_sucursal_id, p_preventista_id, NULLIF(p_origen_precio, ''), p_producto_id, p_categoria_id,
    p_porcentaje, v_desde, p_vigente_hasta, auth.uid()
  )
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$function$;

-- ----------------------------------------------------------------------------
-- 7 · desactivar_comision_regla: la baja tiene fecha (COM-2)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.desactivar_comision_regla(p_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_r comision_reglas%ROWTYPE;
BEGIN
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Solo un admin puede dar de baja reglas de comision' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_r FROM comision_reglas WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La regla % no existe', p_id USING ERRCODE = 'no_data_found';
  END IF;
  -- #1048: sólo reglas de sucursales asignadas (o globales, si las tiene todas).
  IF NOT comision_regla_alcanzable(v_r.sucursal_id) THEN
    RAISE EXCEPTION 'La regla % es de una sucursal que no tenés asignada', p_id
      USING ERRCODE = '42501';
  END IF;
  IF v_r.baja_desde IS NOT NULL THEN
    RETURN;
  END IF;

  -- #1320: deja de regir desde hoy. Lo anterior la sigue usando.
  UPDATE comision_reglas
     SET activo = false,
         baja_desde = _tablero_hoy()
   WHERE id = p_id;
END;
$function$;

-- ----------------------------------------------------------------------------
-- 8 · guardar_meta_preventista (COM-3)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guardar_meta_preventista(p_id bigint, p_sucursal_id bigint, p_preventista_id uuid, p_periodo date, p_tipo_meta text, p_valor_objetivo numeric, p_marca_id uuid DEFAULT NULL::uuid, p_categoria_id uuid DEFAULT NULL::uuid, p_producto_ids bigint[] DEFAULT NULL::bigint[], p_periodo_hasta date DEFAULT NULL::date)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_id        bigint;
  v_desde     date;
  v_hasta     date;
  v_productos bigint[];
  v_ajenos    integer;
  v_suc_meta  bigint;
BEGIN
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Solo un admin puede definir objetivos' USING ERRCODE = '42501';
  END IF;

  IF p_periodo_hasta IS NULL THEN
    v_desde := date_trunc('month', COALESCE(p_periodo, _tablero_hoy()))::date;
    v_hasta := (v_desde + interval '1 month - 1 day')::date;
  ELSE
    v_desde := COALESCE(p_periodo, _tablero_hoy());
    v_hasta := p_periodo_hasta;
  END IF;

  IF v_hasta < v_desde THEN
    RAISE EXCEPTION 'El fin del período no puede ser anterior al inicio';
  END IF;

  IF p_valor_objetivo IS NULL OR p_valor_objetivo <= 0 THEN
    RAISE EXCEPTION 'El objetivo debe ser mayor a 0';
  END IF;

  IF p_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Indicá la sucursal del objetivo';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM usuario_sucursales
    WHERE usuario_id = auth.uid() AND sucursal_id = p_sucursal_id
  ) THEN
    RAISE EXCEPTION 'No tenés acceso a esa sucursal' USING ERRCODE = '42501';
  END IF;

  -- #1291: el preventista trabaja en la sucursal de la meta, que es una del que llama.
  IF NOT EXISTS (
    SELECT 1 FROM usuario_sucursales us
      JOIN usuario_sucursales yo ON yo.sucursal_id = us.sucursal_id AND yo.usuario_id = auth.uid()
    WHERE us.usuario_id = p_preventista_id AND us.sucursal_id = p_sucursal_id
  ) THEN
    RAISE EXCEPTION 'Ese usuario no trabaja en la sucursal elegida';
  END IF;

  IF p_producto_ids IS NOT NULL AND cardinality(p_producto_ids) > 0 THEN
    SELECT array_agg(DISTINCT x ORDER BY x) INTO v_productos
    FROM unnest(p_producto_ids) AS x;

    SELECT COUNT(*) INTO v_ajenos
    FROM unnest(v_productos) AS x
    WHERE NOT EXISTS (
      SELECT 1 FROM productos p WHERE p.id = x AND p.sucursal_id = p_sucursal_id
    );
    IF v_ajenos > 0 THEN
      RAISE EXCEPTION '% producto(s) no pertenecen a la sucursal elegida', v_ajenos;
    END IF;
  ELSE
    v_productos := NULL;
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO metas_preventista (
      sucursal_id, preventista_id, periodo, periodo_fin, tipo_meta,
      marca_id, categoria_id, producto_ids, valor_objetivo, usuario_id
    ) VALUES (
      p_sucursal_id, p_preventista_id, v_desde, v_hasta, p_tipo_meta,
      p_marca_id, p_categoria_id, v_productos, p_valor_objetivo, auth.uid()
    )
    -- COM-3 (#1321): la meta de otra sucursal del mismo preventista es otra meta.
    ON CONFLICT (
      sucursal_id, preventista_id, periodo, periodo_fin, tipo_meta,
      COALESCE(marca_id, '00000000-0000-0000-0000-000000000000'::uuid),
      COALESCE(categoria_id, '00000000-0000-0000-0000-000000000000'::uuid),
      COALESCE(producto_ids, '{}'::bigint[])
    ) DO UPDATE SET
      valor_objetivo = EXCLUDED.valor_objetivo,
      activo         = true,
      usuario_id     = EXCLUDED.usuario_id
    RETURNING id INTO v_id;
  ELSE
    SELECT sucursal_id INTO v_suc_meta FROM metas_preventista WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'El objetivo % no existe', p_id USING ERRCODE = 'no_data_found';
    END IF;
    -- COM-3 (#1321): la meta es de la sucursal pedida, que ya se cruzó con las
    -- del que llama. Un objetivo no se muda de sucursal.
    IF v_suc_meta IS DISTINCT FROM p_sucursal_id THEN
      RAISE EXCEPTION 'El objetivo % es de otra sucursal', p_id USING ERRCODE = '42501';
    END IF;

    UPDATE metas_preventista SET
      preventista_id = p_preventista_id,
      periodo        = v_desde,
      periodo_fin    = v_hasta,
      tipo_meta      = p_tipo_meta,
      marca_id       = p_marca_id,
      categoria_id   = p_categoria_id,
      producto_ids   = v_productos,
      valor_objetivo = p_valor_objetivo
    WHERE id = p_id
    RETURNING id INTO v_id;
  END IF;

  RETURN v_id;
END;
$function$;

-- ----------------------------------------------------------------------------
-- 9 · desactivar_meta_preventista (COM-3)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.desactivar_meta_preventista(p_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Solo un admin puede dar de baja objetivos' USING ERRCODE = '42501';
  END IF;

  -- COM-3 (#1321): sólo una meta de una sucursal del que llama.
  UPDATE metas_preventista SET activo = false
   WHERE id = p_id
     AND sucursal_id IN (SELECT us.sucursal_id FROM usuario_sucursales us
                          WHERE us.usuario_id = auth.uid());
  IF NOT FOUND THEN
    RAISE EXCEPTION 'El objetivo % no existe o es de una sucursal que no tenés asignada', p_id
      USING ERRCODE = '42501';
  END IF;
END;
$function$;

-- ----------------------------------------------------------------------------
-- 10 · guardar_meta_gerencial: la Red sólo con todas las sucursales (COM-3)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guardar_meta_gerencial(p_sucursal_id bigint, p_periodo date, p_metrica text, p_valor numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF auth.uid() IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin') THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin';
  END IF;
  IF auth.uid() IS NOT NULL AND p_sucursal_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM usuario_sucursales WHERE usuario_id = auth.uid() AND sucursal_id = p_sucursal_id) THEN
    RAISE EXCEPTION 'Acceso denegado: la sucursal no está asignada al usuario';
  END IF;
  -- COM-3 (#1321): la meta de la Red la carga sólo quien tiene todas las
  -- sucursales activas, el mismo criterio con que la lee (#1272).
  IF auth.uid() IS NOT NULL AND p_sucursal_id IS NULL
     AND NOT _tiene_todas_las_sucursales() THEN
    RAISE EXCEPTION 'Acceso denegado: la meta de la Red sólo la carga un admin con todas las sucursales'
      USING ERRCODE = '42501';
  END IF;
  IF p_metrica NOT IN ('venta','margen_neto') THEN
    RAISE EXCEPTION 'Métrica inválida: %', p_metrica;
  END IF;
  IF p_valor IS NULL OR p_valor < 0 THEN
    RAISE EXCEPTION 'Valor inválido';
  END IF;

  INSERT INTO metas_gerenciales (sucursal_id, periodo, metrica, valor, usuario_id, updated_at)
  VALUES (p_sucursal_id, date_trunc('month', p_periodo)::date, p_metrica, p_valor, auth.uid(), now())
  ON CONFLICT (COALESCE(sucursal_id, -1), periodo, metrica) DO UPDATE
    SET valor = EXCLUDED.valor, usuario_id = EXCLUDED.usuario_id, updated_at = now();
END;
$function$;

-- ----------------------------------------------------------------------------
-- 11 · Verificación
-- ----------------------------------------------------------------------------
DO $verif$
BEGIN
  IF has_table_privilege('authenticated', 'public.comision_pct_vigencias', 'SELECT')
     OR has_table_privilege('anon', 'public.comision_pct_vigencias', 'SELECT')
     OR has_table_privilege('authenticated', 'public.comision_pct_vigencias', 'INSERT') THEN
    RAISE EXCEPTION 'mig 421 · comision_pct_vigencias quedó alcanzable por REST';
  END IF;
  IF EXISTS (SELECT 1 FROM politicas_comerciales pc
              WHERE NOT EXISTS (SELECT 1 FROM comision_pct_vigencias cv WHERE cv.sucursal_id = pc.sucursal_id)) THEN
    RAISE EXCEPTION 'mig 421 · hay una sucursal sin su %% de comisión en comision_pct_vigencias';
  END IF;
  IF pg_get_indexdef('public.metas_preventista_uidx'::regclass) !~ '\(sucursal_id, preventista_id' THEN
    RAISE EXCEPTION 'mig 421 · metas_preventista_uidx no incluye la sucursal';
  END IF;
  IF pg_get_functiondef('public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure)
       ~ 'NOT EXISTS \(SELECT 1 FROM pagos g WHERE g\.pedido_id = pedidos\.id AND g\.forma_pago = ''adelanto_sueldo''\)' THEN
    RAISE EXCEPTION 'mig 421 · reporte_gerencial sigue excluyendo el pedido entero con adelanto';
  END IF;
  IF has_function_privilege('anon', 'public.reporte_gerencial(bigint,date,date,boolean,boolean)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.reporte_gerencial(bigint,date,date,boolean,boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'mig 421 · cambiaron los grants de reporte_gerencial';
  END IF;
  IF has_function_privilege('anon', 'public.calcular_comisiones(date,date,bigint[])', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.calcular_comisiones(date,date,bigint[])', 'EXECUTE') THEN
    RAISE EXCEPTION 'mig 421 · cambiaron los grants de calcular_comisiones';
  END IF;
END
$verif$;

COMMIT;
