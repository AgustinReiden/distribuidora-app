-- ============================================================================
-- 434 · Los checks que habrían atajado la auditoría de módulos (#1330, punto 3
-- de #1376; plan #1308 tarjeta 8)
-- ============================================================================
-- El número se elige al aplicarla, contra el ledger de prod y origin/main
-- (trampa 3 de CLAUDE.md). Aplicar desde el contenido LF.
-- Ensayo: scripts/test-gates-1330.sql.
--
-- auditoria_integridad(), parcheada por ancla sobre el cuerpo vivo:
--   RUTA-A y RUTA-B pasan a las paradas vivas y a `_recorrido_contadores` (419).
--     Una parada 'no_entregado' o 'reasignado' es historia: su pedido se puede
--     entregar en otra ruta, y la cuenta vieja daba un rojo sin arreglo.
--   PROMO-C · ninguna función lee el tipo de regalo vivo para un pedido que ya
--     existe (#1324: cada pedido queda con la foto de su modo).
--   ASG-A · un cliente de una zona con dueño es de ese dueño y de nadie más,
--     salvo reservado (359, #1316).
--   ASG-B · quien tiene cartera actúa como preventista activo en la sucursal
--     del cliente, y la tiene asignada (378, #1316).
--   COMIS-06 · un mes cerrado no cambia (#1320). Se congela por vigencia y no
--     por foto, así que no hay un número para comparar: un adelanto cargado
--     después del cierre SÍ corrige el mes (COM-4, decisión del dueño). Lo que
--     no se puede mover es la configuración de ese mes, y eso es lo que mira.
--     El comportamiento lo prueba test-comisiones-1320-1321.sql (C1 y C2).
--   REPORTE-A · ningún reporte vuelve a perder filas por un JOIN interno
--     (#1262, #1315). Los cruces de totales van en scripts/check-integridad.mjs.
--   EMP-A y EMP-B · la cuenta de cada empleado cierra con sus pagos y sus
--     gastos (definición del comentario del 30/10 de #1330).
--   EMP-C · un empleado que no es "de las dos" no cruza de sucursal por su
--     cliente ni por su vehículo. Sus FK son simples a propósito (430). Los
--     gastos quedan afuera: `_guardar_gasto` conserva al editar un empleado que
--     después cambió de sucursal, y ese rojo no se arregla tocando datos.
--   FISCAL-B · neto + IVA = total en las NC de venta de un pedido FC (#1276).
--   VENTA-E · pasa a `_tablero_hoy()` (#1277): de noche CURRENT_DATE ya es mañana.
--     Sale de scripts/fechas-utc-permitidas.json.
--   GASTO-A y el resto de la lista no cambian.
--
-- Punto 3 de #1376: `hojas_de_ruta_deposito`, `reporte_gerencial` y
--   `reporte_rentabilidad` leían `promociones.regalo_mueve_stock` y pasan a
--   `_regalo_modo_del_pedido`. Con `unidades_por_bloque_al_crear` cargado, o sin
--   ninguna promo que haya cambiado de tipo, el número es el mismo: se comprueba
--   acá abajo, comparando los dos reportes antes y después.
--   Límite: la foto guarda el modo, no el factor. Las 70 líneas de regalo sin
--   `unidades_por_bloque_al_crear` (promos 1, 10, 12 y 13) siguen tomando
--   `pr.unidades_por_bloque` de la promo viva, y la pantalla lo borra al pasar a
--   unidad entera. Pasaba igual antes de esta migración; va anotado en #1376.
-- `reporte_combos`: LEFT JOIN a productos (REPORTE-A). Una línea de combo sin
--   producto iría como "(producto borrado)", igual que en el gerencial; hoy no
--   hay ninguna, los combos son posteriores a la FK RESTRICT.
--
-- Funciones nuevas, sólo de servidor: auditoria_funciones_modo_regalo_vivo(),
--   auditoria_reportes_join_interno(), auditoria_comision_mes_cerrado().
-- No toca tablas ni grants de tablas.
-- ============================================================================

BEGIN;

DO $premisas$
DECLARE
  v_f record;
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'mig 434 · la migración llegó con CRLF: aplicarla desde el contenido LF';
  END IF;

  -- Los cuerpos vivos son los que se leyeron (2026-11-02, ledger en la 431d).
  FOR v_f IN
    SELECT x.firma, x.md5, md5(p.prosrc) AS md5_vivo
      FROM (VALUES
        ('public.auditoria_integridad()',                                  'd5604566d1e4ac841ab333e5220bde16'),
        ('public.hojas_de_ruta_deposito(date)',                            '807c641b72bdb3b53567a2b7680ff441'),
        ('public.reporte_gerencial(bigint,date,date,boolean,boolean)',     'd8eaf8deb174232a08e14bfea573eb91'),
        ('public.reporte_rentabilidad(date,date,bigint,text)',             '617a4d48f3ed6938d1347e29eba3cbe4'),
        ('public.reporte_combos(bigint,date,date,boolean,boolean)',        'abbd706168baa5d7b2991e7204ac49be')
      ) AS x(firma, md5)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION 'mig 434 · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;

  IF to_regprocedure('public._recorrido_contadores(bigint)') IS NULL
     OR to_regprocedure('public._regalo_modo_del_pedido(bigint,bigint,bigint)') IS NULL
     OR to_regprocedure('public._duenio_zona(bigint)') IS NULL
     OR to_regprocedure('public._actua_como_preventista(uuid,bigint)') IS NULL THEN
    RAISE EXCEPTION 'mig 434 · falta un helper (_recorrido_contadores, _regalo_modo_del_pedido, _duenio_zona o _actua_como_preventista)';
  END IF;
END
$premisas$;

-- La foto de los reportes, para compararla después de parchearlos. Una línea de
-- regalo sin `unidades_por_bloque_al_crear` depende del modo: si alguna promo
-- cambió de tipo, el número se corrige, y esta migración se revisa a mano.
CREATE TEMP TABLE _434_reportes_antes ON COMMIT DROP AS
SELECT s.id AS sucursal_id,
       reporte_gerencial(s.id, DATE '2026-01-01', public._tablero_hoy()) - 'meta' AS gerencial,
       reporte_rentabilidad(DATE '2026-01-01', public._tablero_hoy(), s.id) - 'meta' AS rentabilidad
  FROM (SELECT id FROM sucursales WHERE activa UNION ALL SELECT NULL::bigint) s(id);

-- ----------------------------------------------------------------------------
-- 1 · PROMO-C: el tipo de regalo de un pedido que existe es de la foto
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.auditoria_funciones_modo_regalo_vivo()
 RETURNS bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- Las que nombran la columna (sin comentarios ni literales: una clave de un
  -- JSON no es una lectura) y no pasan por la foto. Es texto: una función que
  -- mencione la foto y además lea lo vivo no se ve, como STK-F y COSTO-D.
  SELECT count(*)
    FROM pg_proc f
    CROSS JOIN LATERAL (
      SELECT regexp_replace(
               regexp_replace(regexp_replace(f.prosrc, '/\*.*?\*/', ' ', 'g'), '--[^\n]*', '', 'g'),
               '''[^'']*''', '', 'g') AS src
    ) s
   WHERE f.pronamespace = 'public'::regnamespace
     AND f.prokind = 'f'
     AND s.src ~* '\yregalo_mueve_stock\y'
     AND s.src !~* '\y(_regalo_modo_del_pedido|pedido_promo_reglas|promos_del_pedido)\y'
     AND f.proname NOT IN (
       -- El alta: el pedido nace con el tipo de hoy, y de acá sale la foto.
       'crear_pedido_completo', 'crear_pedido_completo_bot', '_promo_reglas_vigentes',
       -- La definición de la promo, no un pedido: el aviso de cambiar el factor
       -- y lo que corre al cambiar la promo o el bulto de un producto.
       'previsualizar_cambio_factor', 'renormalizar_bloques_por_cambio_factor',
       'validar_cambio_unidades_por_bulto',
       -- La barra es de la promo viva (431a): sólo le entran las líneas de su
       -- modo, y eso lo decide `_regalo_barra_vale` antes de llamarla.
       'aplicar_uso_promo_acumulador',
       -- Reciben la promo, no el pedido. Quien las llama con un pedido viejo ya
       -- resolvió el modo por `_regalo_modo_del_pedido`.
       'factor_regalo_de_linea', 'unidades_por_bloque_de_barra');
$function$;

COMMENT ON FUNCTION public.auditoria_funciones_modo_regalo_vivo() IS
  'PROMO-C (#1324): funciones que leen promociones.regalo_mueve_stock sin pasar por la foto del pedido.';

-- ----------------------------------------------------------------------------
-- 2 · REPORTE-A: un reporte no pierde filas por un JOIN interno
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.auditoria_reportes_join_interno()
 RETURNS bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- #1262 y #1315: hay líneas sin producto, pedidos sin vendedor y clientes sin
  -- zona. Con un JOIN interno se caen de la suma y el reporte no cierra contra
  -- su total. Sobre perfiles mira sólo el vendedor del pedido: el JOIN de
  -- `cliente_preventistas` es la asignación, con FK, y no suma plata.
  SELECT count(*)
    FROM pg_proc f
    CROSS JOIN LATERAL (
      SELECT regexp_replace(
               regexp_replace(
                 regexp_replace(regexp_replace(f.prosrc, '/\*.*?\*/', ' ', 'g'), '--[^\n]*', '', 'g'),
                 '''[^'']*''', '', 'g'),
               '\yLEFT\s+(OUTER\s+)?JOIN\y', 'LEFT_JOIN', 'gi') AS src
    ) s
   WHERE f.pronamespace = 'public'::regnamespace
     AND f.prokind = 'f'
     AND (f.proname LIKE 'reporte\_%' OR f.proname LIKE 'tablero\_%' OR f.proname LIKE '\_tablero\_%')
     -- Lista los productos de cada combo para mostrarlos y no suma venta: un
     -- producto borrado no se vende más, y su fila no tiene de qué cerrar.
     AND f.proname <> 'reporte_combos_rotacion'
     AND ((s.src ~* '\ypedido_items\y' AND s.src ~* '\yJOIN\s+(public\.)?productos\y')
          OR (s.src ~* '\ypedidos\y'
              AND s.src ~* '\yJOIN\s+(public\.)?perfiles(\s+AS)?\s+\w+\s+ON\s+\(?\s*(\w+\.id\s*=\s*\w+\.usuario_id|\w+\.usuario_id\s*=\s*\w+\.id)')
          OR s.src ~* '\yJOIN\s+(public\.)?zonas\y');
$function$;

COMMENT ON FUNCTION public.auditoria_reportes_join_interno() IS
  'REPORTE-A (#1262, #1315): reportes y tableros con un JOIN interno a productos, al vendedor o a zonas.';

-- ----------------------------------------------------------------------------
-- 3 · COMIS-06: la configuración de un mes cerrado no cambia
-- ----------------------------------------------------------------------------
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
    + (SELECT CASE WHEN bool_and(f.prosrc ~ '\ycomision_pct_vigencias\y' AND f.prosrc ~ '\ybaja_desde\y')
                   THEN 0 ELSE 1 END
         FROM pg_proc f
        WHERE f.pronamespace = 'public'::regnamespace AND f.proname = 'calcular_comisiones');
$function$;

COMMENT ON FUNCTION public.auditoria_comision_mes_cerrado() IS
  'COMIS-06 (#1320): la configuración de las comisiones de un mes cerrado no cambia.';

-- Sólo de servidor: las llama auditoria_integridad(), que es SECURITY DEFINER.
REVOKE ALL ON FUNCTION public.auditoria_funciones_modo_regalo_vivo() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.auditoria_reportes_join_interno() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.auditoria_comision_mes_cerrado() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auditoria_funciones_modo_regalo_vivo() TO service_role;
GRANT EXECUTE ON FUNCTION public.auditoria_reportes_join_interno() TO service_role;
GRANT EXECUTE ON FUNCTION public.auditoria_comision_mes_cerrado() TO service_role;

-- ----------------------------------------------------------------------------
-- 4 · Los tres que leían el modo vivo y el JOIN de reporte_combos
-- ----------------------------------------------------------------------------
DO $patch$
DECLARE
  v_modo  constant text := 'public._regalo_modo_del_pedido(pi.pedido_id, pi.promocion_id, pi.sucursal_id)';
  -- El gerencial lo evalúa en toda línea, y sólo le importa a la que no tiene factor.
  v_modo_linea constant text := 'CASE WHEN pi.unidades_por_bloque_al_crear IS NULL AND pi.promocion_id IS NOT NULL THEN '
                                || v_modo || ' END';
  v_def   text;
  v_a     text;
  v_b     text;
BEGIN
  -- hojas_de_ruta_deposito: la clave del JSON sigue igual, el front la lee.
  v_def := pg_get_functiondef('public.hojas_de_ruta_deposito(date)'::regprocedure);
  v_a := '''regalo_mueve_stock'', pm.regalo_mueve_stock) END';
  IF (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a) <> 1 THEN
    RAISE EXCEPTION 'mig 434 · hojas_de_ruta_deposito: el ancla no está una vez';
  END IF;
  EXECUTE replace(v_def, v_a, '''regalo_mueve_stock'', ' || v_modo || ') END');

  -- reporte_gerencial: las tres de las líneas de regalo.
  v_def := pg_get_functiondef('public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure);
  v_a := 'public.factor_bonificacion(pi.unidades_por_bloque_al_crear, pr.regalo_mueve_stock, pr.unidades_por_bloque)';
  IF (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a) <> 3 THEN
    RAISE EXCEPTION 'mig 434 · reporte_gerencial: el ancla no está tres veces';
  END IF;
  EXECUTE replace(v_def, v_a,
    'public.factor_bonificacion(pi.unidades_por_bloque_al_crear, ' || v_modo_linea || ', pr.unidades_por_bloque)');

  -- reporte_rentabilidad
  v_def := pg_get_functiondef('public.reporte_rentabilidad(date,date,bigint,text)'::regprocedure);
  v_a := E'public.factor_bonificacion(pi.unidades_por_bloque_al_crear,\n                           pr.regalo_mueve_stock, pr.unidades_por_bloque)';
  IF (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a) <> 1 THEN
    RAISE EXCEPTION 'mig 434 · reporte_rentabilidad: el ancla no está una vez';
  END IF;
  EXECUTE replace(v_def, v_a,
    E'public.factor_bonificacion(pi.unidades_por_bloque_al_crear,\n                           ' || v_modo || ', pr.unidades_por_bloque)');

  -- reporte_combos
  v_def := pg_get_functiondef('public.reporte_combos(bigint,date,date,boolean,boolean)'::regprocedure);
  v_a := E'      JOIN productos prod ON prod.id = pi.producto_id\n     WHERE pi.combo_id IS NOT NULL';
  v_b := E'           prod.nombre AS producto\n';
  IF (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a) <> 1
     OR (length(v_def) - length(replace(v_def, v_b, ''))) / length(v_b) <> 1 THEN
    RAISE EXCEPTION 'mig 434 · reporte_combos: las anclas no están una vez';
  END IF;
  v_def := replace(v_def, v_a, E'      LEFT JOIN productos prod ON prod.id = pi.producto_id\n     WHERE pi.combo_id IS NOT NULL');
  EXECUTE replace(v_def, v_b, E'           COALESCE(prod.nombre, ''(producto borrado)'') AS producto\n');
END
$patch$;

-- ----------------------------------------------------------------------------
-- 5 · auditoria_integridad(): RUTA-A, RUTA-B y los checks nuevos
-- ----------------------------------------------------------------------------
DO $patch$
DECLARE
  v_def      text := pg_get_functiondef('public.auditoria_integridad()'::regprocedure);
  v_cierre   text := E'\n  )\n  SELECT jsonb_agg(\n';
  v_venta_e  text := 'AND (fecha IS NULL OR fecha>CURRENT_DATE))),';
  v_ruta_a   text := $a$    ('RUTA-A','high','paradas de pedidos entregados que quedaron sin marcar',
      (SELECT count(*) FROM recorrido_pedidos rp JOIN pedidos p ON p.id=rp.pedido_id
        WHERE p.estado='entregado' AND COALESCE(rp.estado_entrega,'pendiente')<>'entregado')),
    ('RUTA-B','high','recorridos con pedidos_entregados/total_cobrado distintos del recalculo',
      (SELECT count(*) FROM recorridos r
         LEFT JOIN LATERAL (
           SELECT COUNT(*) FILTER (WHERE p.estado='entregado') AS ent,
                  COALESCE(SUM(p.monto_pagado) FILTER (WHERE p.estado='entregado' AND COALESCE(p.tipo_factura,'ZZ')<>'VB'),0) AS cob
             FROM recorrido_pedidos rp JOIN pedidos p ON p.id=rp.pedido_id
            WHERE rp.recorrido_id=r.id) s ON TRUE
        WHERE r.pedidos_entregados IS DISTINCT FROM s.ent
           OR COALESCE(r.total_cobrado,0) IS DISTINCT FROM COALESCE(s.cob,0))),
$a$;
  v_ruta_n   text := $a$    -- #1330: las paradas vivas, las de `_recorrido_contadores` (419). Una
    -- 'no_entregado' o 'reasignado' es historia: el pedido se entrega en otra
    -- ruta y esa parada queda como está, sin que haya nada que arreglar.
    ('RUTA-A','high','paradas vivas de pedidos entregados que quedaron sin marcar',
      (SELECT count(*) FROM recorrido_pedidos rp JOIN pedidos p ON p.id=rp.pedido_id
        WHERE p.estado='entregado' AND rp.estado_entrega='pendiente')),
    ('RUTA-B','high','recorridos con pedidos_entregados/total_cobrado distintos de _recorrido_contadores',
      (SELECT count(*) FROM recorridos r
         CROSS JOIN LATERAL public._recorrido_contadores(r.id) c
        WHERE r.pedidos_entregados IS DISTINCT FROM c.pedidos_entregados
           OR COALESCE(r.total_cobrado,0) IS DISTINCT FROM c.total_cobrado)),
$a$;
  v_nuevos   text := $a$,
    -- #1324 · decisión del dueño: el tipo de una promo se puede cambiar con
    -- pedidos abiertos, y cada pedido queda con la foto de su modo.
    ('PROMO-C','high','funciones que leen promociones.regalo_mueve_stock sin pasar por la foto del pedido (#1324)',
      (SELECT public.auditoria_funciones_modo_regalo_vivo())),
    -- #1316 · la zona manda (359): el dueño de la zona y nadie más. Cuenta los
    -- inactivos, porque `asignar_preventista_zona` también los pasa.
    ('ASG-A','high','clientes de una zona con dueño que no están asignados sólo a ese dueño, salvo reservados (#1316)',
      (SELECT count(*) FROM clientes c
         CROSS JOIN LATERAL (SELECT public._duenio_zona(c.zona_id) AS duenio) d
        WHERE d.duenio IS NOT NULL AND NOT c.reservado_admin
          AND (NOT EXISTS (SELECT 1 FROM cliente_preventistas cp
                            WHERE cp.cliente_id = c.id AND cp.preventista_id = d.duenio)
               OR EXISTS (SELECT 1 FROM cliente_preventistas cp
                           WHERE cp.cliente_id = c.id AND cp.preventista_id <> d.duenio)))),
    -- #1316 · sin esto un cliente queda con quien ya no lo atiende, y ningún
    -- otro preventista lo ve. `_actua_como_preventista` no mira la asignación a
    -- la sucursal de un rol base preventista: va aparte.
    ('ASG-B','high','cartera de quien no actúa como preventista activo en la sucursal del cliente (#1316)',
      (SELECT count(*) FROM cliente_preventistas cp
         JOIN clientes c ON c.id = cp.cliente_id
         LEFT JOIN perfiles pf ON pf.id = cp.preventista_id
        WHERE NOT COALESCE(pf.activo, false)
           OR NOT public._actua_como_preventista(cp.preventista_id, c.sucursal_id)
           OR NOT EXISTS (SELECT 1 FROM usuario_sucursales us
                           WHERE us.usuario_id = cp.preventista_id AND us.sucursal_id = c.sucursal_id))),
    ('COMIS-06','high','la configuración de las comisiones de un mes cerrado no cambia (#1320)',
      (SELECT public.auditoria_comision_mes_cerrado())),
    ('REPORTE-A','high','reportes y tableros con un JOIN interno a productos, al vendedor o a zonas (#1262, #1315)',
      (SELECT public.auditoria_reportes_join_interno())),
    -- gastos 3/5 (decisión 6) · el pago no tiene FK: se puede borrar y el
    -- movimiento queda. La suma por pago no alcanza: un pedazo asentado al
    -- empleado equivocado cuadra igual. El neto entero va a un solo empleado,
    -- el del movimiento que lleva el cliente del pago, o el que hoy tiene esa
    -- ficha: un pago que pasa entre dos fichas del mismo empleado no asienta
    -- nada, porque la cuenta ya está bien.
    ('EMP-A','high','la mercadería de cada pago cuadra con el pago y cae en un solo empleado (#1330)',
      (SELECT count(*) FROM (
         SELECT x.pago_id
           FROM (SELECT m.pago_id, m.empleado_id, sum(m.monto) AS neto,
                        COALESCE(bool_or(m.cliente_id = pg.cliente_id OR e.cliente_id = pg.cliente_id), false) AS del_cliente,
                        COALESCE(max(-pg.monto) FILTER (WHERE pg.forma_pago = 'adelanto_sueldo'), 0) AS objetivo
                   FROM empleado_movimientos m
                   LEFT JOIN pagos pg ON pg.id = m.pago_id
                   LEFT JOIN empleados e ON e.id = m.empleado_id
                  WHERE m.tipo = 'mercaderia'
                  GROUP BY m.pago_id, m.empleado_id) x
          GROUP BY x.pago_id, x.objetivo
         HAVING abs(sum(x.neto) - x.objetivo) > 0.005
             OR count(*) FILTER (WHERE abs(x.neto) > 0.005) > 1
             OR count(*) FILTER (WHERE abs(x.neto) > 0.005 AND NOT x.del_cliente) > 0) y)),
    -- gastos 3/5 · por empleado: el suyo lleva el monto si el gasto es de un
    -- empleado y no está anulado, y cualquier otro, 0.
    ('EMP-B','high','el reintegro de cada gasto cuadra con el gasto y con su empleado (#1330)',
      (SELECT (SELECT count(*) FROM (
                 SELECT m.gasto_id
                   FROM empleado_movimientos m
                   JOIN gastos g ON g.id = m.gasto_id
                  WHERE m.tipo = 'reintegro'
                  GROUP BY m.gasto_id, m.empleado_id, g.empleado_id, g.origen_pago, g.anulado_at, g.monto_total
                 HAVING abs(sum(m.monto)
                            - CASE WHEN m.empleado_id = g.empleado_id AND g.origen_pago = 'empleado'
                                        AND g.anulado_at IS NULL
                                   THEN g.monto_total ELSE 0 END) > 0.005) y)
            + (SELECT count(*) FROM gastos g
                WHERE g.origen_pago = 'empleado' AND g.anulado_at IS NULL
                  AND NOT EXISTS (SELECT 1 FROM empleado_movimientos m
                                   WHERE m.gasto_id = g.id AND m.empleado_id = g.empleado_id)))),
    -- 430 · las FK de empleados son simples porque uno "de las dos" cruza a
    -- propósito. Los gastos no van: `_guardar_gasto` conserva al editar un
    -- empleado que después cambió de sucursal, y ese rojo no tiene arreglo.
    ('EMP-C','high','empleados que no son de las dos con el cliente o el vehículo de otra sucursal (#1330)',
      (SELECT count(*) FROM empleados e
         LEFT JOIN clientes c ON c.id = e.cliente_id
         LEFT JOIN vehiculos v ON v.id = e.vehiculo_id
        WHERE e.de_las_dos IS NOT TRUE
          AND (c.sucursal_id <> e.sucursal_id OR v.sucursal_id <> e.sucursal_id))),
    -- #1276 · sólo FC: en una NC de ZZ el neto es "como si", igual que
    -- pedidos.total_neto. Una anulada no acredita nada, y el ZZ↔FC sólo exige
    -- que no haya una NC vigente.
    ('FISCAL-B','high','NC de venta de un pedido FC donde neto + iva <> total (#1276)',
      (SELECT count(*) FROM notas_credito_venta n
         JOIN pedidos p ON p.id = n.pedido_id
        WHERE p.tipo_factura = 'FC' AND NOT n.anulada
          AND abs(COALESCE(n.neto, 0) + COALESCE(n.iva, 0) - n.total) > 0.005))$a$;
  v_id text;
BEGIN
  IF (length(v_def) - length(replace(v_def, v_cierre, ''))) / length(v_cierre) <> 1 THEN
    RAISE EXCEPTION 'mig 434 · auditoria_integridad: el cierre de la lista de checks no está una vez';
  END IF;
  IF (length(v_def) - length(replace(v_def, v_ruta_a, ''))) / length(v_ruta_a) <> 1 THEN
    RAISE EXCEPTION 'mig 434 · auditoria_integridad: RUTA-A y RUTA-B no son las que se leyeron';
  END IF;
  IF (length(v_def) - length(replace(v_def, v_venta_e, ''))) / length(v_venta_e) <> 1 THEN
    RAISE EXCEPTION 'mig 434 · auditoria_integridad: VENTA-E no es la que se leyó';
  END IF;
  -- La salida es una lista: un id repetido no falla ni se nota.
  FOREACH v_id IN ARRAY ARRAY['PROMO-C', 'ASG-A', 'ASG-B', 'COMIS-06', 'REPORTE-A', 'EMP-A', 'EMP-B', 'EMP-C', 'FISCAL-B'] LOOP
    IF position('''' || v_id || '''' in v_def) > 0 THEN
      RAISE EXCEPTION 'mig 434 · auditoria_integridad ya tiene el id %', v_id;
    END IF;
  END LOOP;

  v_def := replace(v_def, v_venta_e, 'AND (fecha IS NULL OR fecha>public._tablero_hoy()))),');
  EXECUTE replace(replace(v_def, v_ruta_a, v_ruta_n), v_cierre, v_nuevos || v_cierre);
END
$patch$;

-- ----------------------------------------------------------------------------
-- 6 · Verificación
-- ----------------------------------------------------------------------------
DO $verif$
DECLARE
  v_a      jsonb := public.auditoria_integridad();
  v_rojos  text;
  r        record;
  f        text;
BEGIN
  -- Ningún id repetido, en toda la lista.
  SELECT string_agg(i, ', ') INTO v_rojos
    FROM (SELECT c->>'id' AS i FROM jsonb_array_elements(v_a->'checks') c
           GROUP BY 1 HAVING count(*) > 1) x;
  IF v_rojos IS NOT NULL THEN
    RAISE EXCEPTION 'mig 434 · ids repetidos en auditoria_integridad: %', v_rojos;
  END IF;
  IF (v_a->>'total_checks')::int <> 79 THEN
    RAISE EXCEPTION 'mig 434 · auditoria_integridad quedó con % checks, no 79', v_a->>'total_checks';
  END IF;

  -- Cada check nuevo nace en 0.
  SELECT string_agg(format('%s = %s', c->>'id', c->>'violaciones'), ', ') INTO v_rojos
    FROM jsonb_array_elements(v_a->'checks') c
   WHERE c->>'id' = ANY (ARRAY['RUTA-A', 'RUTA-B', 'PROMO-C', 'ASG-A', 'ASG-B', 'COMIS-06',
                               'REPORTE-A', 'EMP-A', 'EMP-B', 'EMP-C', 'FISCAL-B', 'GASTO-A', 'VENTA-E'])
     AND (c->>'violaciones')::bigint <> 0;
  IF v_rojos IS NOT NULL THEN
    RAISE EXCEPTION 'mig 434 · checks en rojo al aplicar: %', v_rojos;
  END IF;

  -- Los reportes dan lo mismo que antes del parche.
  FOR r IN SELECT * FROM _434_reportes_antes LOOP
    IF reporte_gerencial(r.sucursal_id, DATE '2026-01-01', public._tablero_hoy()) - 'meta' IS DISTINCT FROM r.gerencial THEN
      RAISE EXCEPTION 'mig 434 · reporte_gerencial cambió en la sucursal %', COALESCE(r.sucursal_id::text, 'Red');
    END IF;
    IF reporte_rentabilidad(DATE '2026-01-01', public._tablero_hoy(), r.sucursal_id) - 'meta' IS DISTINCT FROM r.rentabilidad THEN
      RAISE EXCEPTION 'mig 434 · reporte_rentabilidad cambió en la sucursal %', COALESCE(r.sucursal_id::text, 'Red');
    END IF;
  END LOOP;

  FOREACH f IN ARRAY ARRAY['public.auditoria_funciones_modo_regalo_vivo()',
                           'public.auditoria_reportes_join_interno()',
                           'public.auditoria_comision_mes_cerrado()'] LOOP
    IF has_function_privilege('anon', f, 'EXECUTE') OR has_function_privilege('authenticated', f, 'EXECUTE') THEN
      RAISE EXCEPTION 'mig 434 · % quedó alcanzable desde el front', f;
    END IF;
  END LOOP;
END
$verif$;

COMMIT;
