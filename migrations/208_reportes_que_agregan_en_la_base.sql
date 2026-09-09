-- Los reportes agregan en la BASE, no en el navegador
--
-- EL PROBLEMA
-- -----------
-- Tres reportes bajaban miles de filas al navegador para sumarlas ahi:
-- Cuentas por Cobrar traia 720 clientes + todos los pedidos impagos,
-- Rentabilidad traia los pedidos del periodo con sus items y sus productos, y
-- Por Preventista los pedidos con sus items. PostgREST corta en 1.000 filas y
-- devuelve 200, asi que ademas salian truncados en silencio.
--
-- El PR anterior arreglo la correccion paginando: se traen todas las filas,
-- de a 1.000. Los numeros pasaron a estar bien, pero el costo quedo: con
-- ~1.100 pedidos por mes, en un año y medio el dashboard sin filtro serian 20
-- viajes encadenados trayendo pedidos con items y productos embebidos.
--
-- Esta migracion cierra la otra mitad: que la base devuelva la agregacion en
-- vez de las filas. Un GROUP BY sobre millones de filas con indice tarda
-- milisegundos y devuelve decenas de filas; el tope de PostgREST deja de
-- existir porque nunca se acerca.
--
-- Es el mismo camino que ya se recorrio dos veces en este repo cuando paso
-- esto mismo: `reporte_ventas_por_cliente` (mig 197) y
-- `reporte_valuacion_inventario` (mig 131).
--
-- UNA SOLA DEFINICION DEL SALDO
-- -----------------------------
-- `clientes.saldo_cuenta` lo mantiene un trigger (`actualizar_saldo_cliente`)
-- y `pedidos.monto_pagado` otros dos. Verificado contra prod en la misma
-- sentencia: el saldo del trigger y el derivado pedido-por-pedido coinciden
-- EXACTO, cliente por cliente ($8.713.880 en 111 clientes, diferencia 0).
--
-- `reporte_cuentas_por_cobrar` deriva de los pedidos porque el aging necesita
-- la fecha de entrega de cada uno, pero devuelve TAMBIEN `saldo_cuenta` por
-- cliente y un bloque `consistencia` con los que difieran. Si algun dia un
-- trigger se rompe, el reporte lo dice en vez de mostrar dos numeros distintos
-- en dos pantallas y que alguien los descubra por casualidad.
--
-- NO SE TOCA NINGUNA TABLA. Son tres funciones de lectura nuevas.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Cuentas por cobrar
--
-- Reemplaza el armado en el navegador. Devuelve una fila por cliente CON
-- saldo, no los 720 clientes ni sus pedidos.
--
-- Los INACTIVOS entran a proposito: un informe de deuda que esconde al que
-- debe y ya no opera no sirve para cobrarle (baja logica, CLAUDE.md).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.reporte_cuentas_por_cobrar(
  p_sucursal_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_sucursales  bigint[];
  v_asignadas   bigint[];
  v_es_servicio boolean := (auth.uid() IS NULL);
  v_rol         text;
  v_out         jsonb;
BEGIN
  -- Guard identico al de reporte_ventas_por_cliente (mig 197).
  IF NOT v_es_servicio THEN
    SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();
    IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
      RAISE EXCEPTION 'Acceso denegado: se requiere rol admin o encargado';
    END IF;
    SELECT array_agg(sucursal_id) INTO v_asignadas
      FROM usuario_sucursales WHERE usuario_id = auth.uid();
    IF v_asignadas IS NULL THEN
      RAISE EXCEPTION 'Acceso denegado: el usuario no tiene sucursales asignadas';
    END IF;
  END IF;

  IF p_sucursal_id IS NULL THEN
    v_sucursales := COALESCE(v_asignadas, ARRAY(SELECT id FROM sucursales));
  ELSE
    v_sucursales := ARRAY[p_sucursal_id];
  END IF;

  WITH ped AS (
    -- Un pedido cancelado no es deuda: cancelar pone total = 0 (mig 175).
    SELECT p.cliente_id,
           p.total,
           p.monto_pagado,
           p.estado,
           GREATEST(0, COALESCE(p.total,0) - COALESCE(p.monto_pagado,0)) AS saldo,
           -- fecha_entrega y created_at son timestamptz: se pasan a date EN
           -- HORA ARGENTINA, igual que la mig 130. Con ::date a secas, una
           -- entrega de las 22h cae al dia siguiente (UTC) y corre la mora.
           COALESCE(
             (p.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date,
             p.fecha,
             (p.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
           ) AS base_mora
    FROM pedidos p
    WHERE p.estado <> 'cancelado'
      AND p.estado_pago IS DISTINCT FROM 'pagado'
      AND p.sucursal_id = ANY(v_sucursales)
  ),
  con_saldo AS (
    SELECT * FROM ped WHERE saldo > 0
  ),
  -- El tramo se resuelve una sola vez por pedido y despues se agrupa: asi el
  -- saldo del cliente es, por construccion, la suma de sus tramos. En el
  -- armado viejo eran dos numeros calculados por caminos distintos y no
  -- coincidian.
  con_tramo AS (
    SELECT cs.*,
           CASE
             WHEN cs.estado <> 'entregado' THEN 'corriente'
             ELSE CASE
               WHEN (CURRENT_DATE - (cs.base_mora + COALESCE(c.dias_credito, 30))) <= 0  THEN 'corriente'
               WHEN (CURRENT_DATE - (cs.base_mora + COALESCE(c.dias_credito, 30))) <= 30 THEN 'vencido30'
               WHEN (CURRENT_DATE - (cs.base_mora + COALESCE(c.dias_credito, 30))) <= 60 THEN 'vencido60'
               ELSE 'vencido90'
             END
           END AS tramo
    FROM con_saldo cs
    JOIN clientes c ON c.id = cs.cliente_id
  ),
  por_cliente AS (
    SELECT ct.cliente_id,
           SUM(ct.total)                                        AS total_deuda,
           SUM(COALESCE(ct.monto_pagado,0))                     AS total_pagado,
           SUM(ct.saldo)                                        AS saldo,
           COUNT(*)                                             AS pedidos_pendientes,
           COALESCE(SUM(ct.saldo) FILTER (WHERE ct.tramo='corriente'),0)  AS corriente,
           COALESCE(SUM(ct.saldo) FILTER (WHERE ct.tramo='vencido30'),0)  AS vencido30,
           COALESCE(SUM(ct.saldo) FILTER (WHERE ct.tramo='vencido60'),0)  AS vencido60,
           COALESCE(SUM(ct.saldo) FILTER (WHERE ct.tramo='vencido90'),0)  AS vencido90
    FROM con_tramo ct
    GROUP BY ct.cliente_id
  ),
  filas AS (
    SELECT pc.*,
           c.nombre_fantasia, c.razon_social, c.zona, c.cuit, c.telefono,
           c.activo, c.dias_credito,
           COALESCE(c.limite_credito,0) AS limite_credito,
           COALESCE(c.saldo_cuenta,0)   AS saldo_cuenta
    FROM por_cliente pc
    JOIN clientes c ON c.id = pc.cliente_id
  )
  SELECT jsonb_build_object(
    'meta', jsonb_build_object(
      'generado_at', now(),
      'criterio', 'Pedidos no cancelados con saldo (total - monto_pagado > 0). '
                  'La mora se cuenta desde la entrega + los dias de credito del cliente. '
                  'Incluye clientes inactivos: la deuda no se da de baja con el cliente.'
    ),
    'totales', (
      SELECT jsonb_build_object(
        'clientes',  COUNT(*),
        'saldo',     COALESCE(ROUND(SUM(saldo),2),0),
        'corriente', COALESCE(ROUND(SUM(corriente),2),0),
        'vencido30', COALESCE(ROUND(SUM(vencido30),2),0),
        'vencido60', COALESCE(ROUND(SUM(vencido60),2),0),
        'vencido90', COALESCE(ROUND(SUM(vencido90),2),0)
      ) FROM filas
    ),
    -- Auto-chequeo: si el saldo denormalizado del trigger deja de coincidir
    -- con el derivado de los pedidos, el reporte lo DICE. Hoy la lista viene
    -- vacia (verificado contra prod, diferencia 0 en los 111 clientes).
    'consistencia', jsonb_build_object(
      'clientes_con_desvio', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'cliente_id', f.cliente_id,
          'nombre', f.nombre_fantasia,
          'saldo_calculado', ROUND(f.saldo,2),
          'saldo_cuenta', ROUND(f.saldo_cuenta,2)
        ))
        FROM filas f WHERE ABS(f.saldo - f.saldo_cuenta) > 1
      ), '[]'::jsonb)
    ),
    'clientes', COALESCE((
      SELECT jsonb_agg(x ORDER BY (x->>'saldoPendiente')::numeric DESC)
      FROM (
        SELECT jsonb_build_object(
          'cliente', jsonb_build_object(
            'id', f.cliente_id,
            'nombre_fantasia', f.nombre_fantasia,
            'razon_social', f.razon_social,
            'zona', f.zona,
            'cuit', f.cuit,
            'telefono', f.telefono,
            'activo', f.activo,
            'dias_credito', f.dias_credito,
            'limite_credito', f.limite_credito,
            'saldo_cuenta', ROUND(f.saldo_cuenta,2)
          ),
          'totalDeuda',       ROUND(f.total_deuda,2),
          'totalPagado',      ROUND(f.total_pagado,2),
          'saldoPendiente',   ROUND(f.saldo,2),
          'limiteCredito',    ROUND(f.limite_credito,2),
          'creditoDisponible',ROUND(f.limite_credito - f.saldo,2),
          'pedidosPendientes',f.pedidos_pendientes,
          'aging', jsonb_build_object(
            'corriente', ROUND(f.corriente,2),
            'vencido30', ROUND(f.vencido30,2),
            'vencido60', ROUND(f.vencido60,2),
            'vencido90', ROUND(f.vencido90,2)
          )
        ) AS x
        FROM filas f
      ) s
    ), '[]'::jsonb)
  ) INTO v_out;

  RETURN v_out;
END;
$fn$;

COMMENT ON FUNCTION public.reporte_cuentas_por_cobrar(bigint) IS
  'Deuda por cliente con aging, agregada en la base. Una fila por cliente CON '
  'saldo. El saldo se deriva pedido por pedido (total - monto_pagado) y por '
  'construccion es la suma de sus tramos de aging. Devuelve tambien el '
  'saldo_cuenta del trigger y un bloque consistencia con los desvios. mig 208.';

-- ---------------------------------------------------------------------------
-- 2. Ventas por preventista
--
-- Devuelve una fila por vendedor en vez de todos los pedidos del periodo con
-- sus items.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.reporte_ventas_por_preventista(
  p_desde       date DEFAULT NULL,
  p_hasta       date DEFAULT NULL,
  p_sucursal_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_sucursales  bigint[];
  v_asignadas   bigint[];
  v_es_servicio boolean := (auth.uid() IS NULL);
  v_rol         text;
  v_out         jsonb;
BEGIN
  IF NOT v_es_servicio THEN
    SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();
    IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
      RAISE EXCEPTION 'Acceso denegado: se requiere rol admin o encargado';
    END IF;
    SELECT array_agg(sucursal_id) INTO v_asignadas
      FROM usuario_sucursales WHERE usuario_id = auth.uid();
    IF v_asignadas IS NULL THEN
      RAISE EXCEPTION 'Acceso denegado: el usuario no tiene sucursales asignadas';
    END IF;
  END IF;

  IF p_sucursal_id IS NULL THEN
    v_sucursales := COALESCE(v_asignadas, ARRAY(SELECT id FROM sucursales));
  ELSE
    v_sucursales := ARRAY[p_sucursal_id];
  END IF;

  WITH ped AS (
    SELECT p.usuario_id, p.total, p.estado,
           COALESCE(p.monto_pagado,0) AS monto_pagado
    FROM pedidos p
    WHERE p.estado <> 'cancelado'
      AND p.sucursal_id = ANY(v_sucursales)
      AND (p_desde IS NULL OR p.fecha >= p_desde)
      AND (p_hasta IS NULL OR p.fecha <= p_hasta)
      AND p.usuario_id IS NOT NULL
  ),
  por_usuario AS (
    SELECT ped.usuario_id,
           SUM(ped.total)                                  AS total_ventas,
           COUNT(*)                                        AS cantidad_pedidos,
           SUM(ped.monto_pagado)                           AS total_pagado,
           SUM(GREATEST(0, ped.total - ped.monto_pagado))  AS total_pendiente,
           COUNT(*) FILTER (WHERE ped.estado = 'pendiente') AS pedidos_pendientes,
           COUNT(*) FILTER (WHERE ped.estado = 'asignado')  AS pedidos_asignados,
           COUNT(*) FILTER (WHERE ped.estado = 'entregado') AS pedidos_entregados
    FROM ped GROUP BY ped.usuario_id
  )
  SELECT COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'id',                pu.usuario_id,
      'nombre',            COALESCE(pf.nombre, 'Usuario desconocido'),
      'email',             COALESCE(pf.email, 'N/A'),
      'totalVentas',       ROUND(pu.total_ventas,2),
      'cantidadPedidos',   pu.cantidad_pedidos,
      'totalPagado',       ROUND(pu.total_pagado,2),
      'totalPendiente',    ROUND(pu.total_pendiente,2),
      'pedidosPendientes', pu.pedidos_pendientes,
      'pedidosAsignados',  pu.pedidos_asignados,
      'pedidosEntregados', pu.pedidos_entregados
    ) ORDER BY pu.total_ventas DESC)
    FROM por_usuario pu
    LEFT JOIN perfiles pf ON pf.id = pu.usuario_id
  ), '[]'::jsonb) INTO v_out;

  RETURN v_out;
END;
$fn$;

COMMENT ON FUNCTION public.reporte_ventas_por_preventista(date, date, bigint) IS
  'Ventas, cobrado y pendiente por vendedor, agregado en la base. Pagado y '
  'pendiente salen de monto_pagado, no de baldes por estado_pago: asi cierran '
  'contra totalVentas y los pagos parciales cuentan. Excluye cancelados. mig 208.';

-- ---------------------------------------------------------------------------
-- 3. Rentabilidad por producto
--
-- Devuelve una fila por producto vendido en vez de los pedidos con sus items y
-- sus productos embebidos, que es el payload mas pesado de todos los reportes.
--
-- El costo usa la MISMA cascada canonica que reporte_gerencial (mig 130) y que
-- `costoCanonicoUnitario` en el front:
--   COALESCE(pi.costo_unitario_al_crear, prod.costo_promedio, prod.costo_real,
--            costo_sin_iva * (1 + impuestos_internos/100))
-- El ingreso real sale del snapshot fiscal del item (mig 123): en FC la venta
-- es el neto porque el IVA se remite, en ZZ es el precio final.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.reporte_rentabilidad(
  p_desde       date DEFAULT NULL,
  p_hasta       date DEFAULT NULL,
  p_sucursal_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_sucursales  bigint[];
  v_asignadas   bigint[];
  v_es_servicio boolean := (auth.uid() IS NULL);
  v_rol         text;
  v_out         jsonb;
BEGIN
  IF NOT v_es_servicio THEN
    SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();
    IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
      RAISE EXCEPTION 'Acceso denegado: se requiere rol admin o encargado';
    END IF;
    SELECT array_agg(sucursal_id) INTO v_asignadas
      FROM usuario_sucursales WHERE usuario_id = auth.uid();
    IF v_asignadas IS NULL THEN
      RAISE EXCEPTION 'Acceso denegado: el usuario no tiene sucursales asignadas';
    END IF;
  END IF;

  IF p_sucursal_id IS NULL THEN
    v_sucursales := COALESCE(v_asignadas, ARRAY(SELECT id FROM sucursales));
  ELSE
    v_sucursales := ARRAY[p_sucursal_id];
  END IF;

  WITH ped AS (
    SELECT p.id, p.tipo_factura
    FROM pedidos p
    WHERE p.estado <> 'cancelado'
      AND p.sucursal_id = ANY(v_sucursales)
      AND (p_desde IS NULL OR p.created_at >= p_desde::timestamp)
      AND (p_hasta IS NULL OR p.created_at < (p_hasta + 1)::timestamp)
  ),
  it AS (
    SELECT pi.producto_id,
           prod.nombre,
           prod.codigo,
           pi.cantidad,
           COALESCE(pi.subtotal, pi.cantidad * pi.precio_unitario) AS subtotal,
           -- Ingreso real (mig 123): snapshot si existe; si no, FC = neto y
           -- ZZ = precio final.
           pi.cantidad * COALESCE(
             pi.ingreso_real_unitario,
             CASE WHEN ped.tipo_factura = 'FC'
                  THEN COALESCE(pi.neto_unitario, pi.precio_unitario)
                  ELSE pi.precio_unitario END
           ) AS ingreso_real,
           pi.cantidad * COALESCE(pi.iva_unitario, 0)                AS iva,
           pi.cantidad * COALESCE(pi.impuestos_internos_unitario, 0) AS imp_internos,
           pi.cantidad * COALESCE(pi.neto_unitario,
             COALESCE(pi.ingreso_real_unitario, pi.precio_unitario)) AS neto,
           -- Cascada de costo canonica (mig 130).
           pi.cantidad * COALESCE(
             pi.costo_unitario_al_crear,
             prod.costo_promedio,
             prod.costo_real,
             ROUND(prod.costo_sin_iva * (1 + COALESCE(prod.impuestos_internos,0)/100), 4)
           ) AS costo
    FROM ped
    JOIN pedido_items pi ON pi.pedido_id = ped.id
    JOIN productos prod ON prod.id = pi.producto_id
  ),
  por_producto AS (
    SELECT it.producto_id, it.nombre, it.codigo,
           SUM(it.cantidad)     AS cantidad_vendida,
           SUM(it.ingreso_real) AS ingresos,
           SUM(COALESCE(it.costo,0)) AS costos
    FROM it GROUP BY it.producto_id, it.nombre, it.codigo
  )
  SELECT jsonb_build_object(
    'productos', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id',               pp.producto_id,
        'nombre',           pp.nombre,
        'codigo',           pp.codigo,
        'cantidadVendida',  pp.cantidad_vendida,
        'ingresos',         ROUND(pp.ingresos,2),
        'costos',           ROUND(pp.costos,2),
        'margen',           ROUND(pp.ingresos - pp.costos,2),
        'margenPorcentaje', CASE WHEN pp.ingresos > 0
                                 THEN ROUND((pp.ingresos - pp.costos) / pp.ingresos * 100, 2)
                                 ELSE 0 END
      ) ORDER BY (pp.ingresos - pp.costos) DESC)
      FROM por_producto pp
    ), '[]'::jsonb),
    'totales', (
      SELECT jsonb_build_object(
        'ingresosTotales',   COALESCE(ROUND(SUM(ingresos),2),0),
        'costosTotales',     COALESCE(ROUND(SUM(costos),2),0),
        'margenTotal',       COALESCE(ROUND(SUM(ingresos) - SUM(costos),2),0),
        'margenPorcentaje',  CASE WHEN COALESCE(SUM(ingresos),0) > 0
                                  THEN ROUND((SUM(ingresos)-SUM(costos))/SUM(ingresos)*100, 2)
                                  ELSE 0 END,
        'cantidadPedidos',   (SELECT COUNT(*) FROM ped),
        'ventasBrutas',      (SELECT COALESCE(ROUND(SUM(subtotal),2),0) FROM it),
        'ivaDiscriminado',   (SELECT COALESCE(ROUND(SUM(iva),2),0) FROM it),
        'impuestosInternos', (SELECT COALESCE(ROUND(SUM(imp_internos),2),0) FROM it),
        'ventasNetas',       (SELECT COALESCE(ROUND(SUM(neto),2),0) FROM it)
      ) FROM por_producto
    )
  ) INTO v_out;

  RETURN v_out;
END;
$fn$;

COMMENT ON FUNCTION public.reporte_rentabilidad(date, date, bigint) IS
  'Margen por producto agregado en la base, con la cascada de costo canonica '
  'de la mig 130 y el ingreso real del snapshot fiscal de la mig 123. mig 208.';

-- ---------------------------------------------------------------------------
-- Permisos. Una SECURITY DEFINER nace ejecutable por PUBLIC y el GRANT a
-- authenticated no lo revierte (gate de CI: scripts/check-permisos.mjs).
-- ---------------------------------------------------------------------------

ALTER FUNCTION public.reporte_cuentas_por_cobrar(bigint) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.reporte_cuentas_por_cobrar(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reporte_cuentas_por_cobrar(bigint) TO authenticated;

ALTER FUNCTION public.reporte_ventas_por_preventista(date, date, bigint) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.reporte_ventas_por_preventista(date, date, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reporte_ventas_por_preventista(date, date, bigint) TO authenticated;

ALTER FUNCTION public.reporte_rentabilidad(date, date, bigint) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.reporte_rentabilidad(date, date, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reporte_rentabilidad(date, date, bigint) TO authenticated;

DO $verif$
DECLARE
  v_acl text;
  v_fn  text;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY[
    'reporte_cuentas_por_cobrar',
    'reporte_ventas_por_preventista',
    'reporte_rentabilidad'
  ] LOOP
    SELECT array_to_string(proacl, ',') INTO v_acl
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = v_fn;

    IF v_acl IS NULL THEN
      RAISE EXCEPTION '% quedo con ACL default (PUBLIC ejecuta)', v_fn;
    END IF;
    IF v_acl LIKE '=X/%' OR v_acl LIKE '%,=X/%' THEN
      RAISE EXCEPTION '% quedo ejecutable por PUBLIC: %', v_fn, v_acl;
    END IF;
    IF v_acl LIKE '%anon=%' THEN
      RAISE EXCEPTION '% quedo ejecutable por anon: %', v_fn, v_acl;
    END IF;
    IF v_acl NOT LIKE '%authenticated=X%' THEN
      RAISE EXCEPTION '% no quedo ejecutable por authenticated: %', v_fn, v_acl;
    END IF;
  END LOOP;
END
$verif$;

COMMIT;

-- ROLLBACK (si hiciera falta):
--   DROP FUNCTION IF EXISTS public.reporte_cuentas_por_cobrar(bigint);
--   DROP FUNCTION IF EXISTS public.reporte_ventas_por_preventista(date, date, bigint);
--   DROP FUNCTION IF EXISTS public.reporte_rentabilidad(date, date, bigint);
-- El front vuelve solo al camino paginado revirtiendo el commit: las funciones
-- son aditivas, no reemplazan nada en la base.
