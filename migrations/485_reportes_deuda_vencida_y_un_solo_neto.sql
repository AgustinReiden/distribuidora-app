-- 485 · Reportes: la deuda vencida con los días de crédito y sin el crédito suelto, un solo
-- "neto", las zonas por id y la venta en curso del bot (#1518, y COB-4 de #1512).
--
-- QUÉ PASABA
--   · REP-1. La alerta "Cobranza vencida" del gerencial (`v_cob_venc`) y su detalle
--     (`reporte_alerta_detalle`) contaban las boletas con fecha de pedido de más de 30 días.
--     Cuentas por cobrar cuenta desde la entrega más los `dias_credito` del cliente. En Taco Pozo,
--     donde los clientes tienen 7 días, Cuentas por cobrar daba $1.144.900 vencidos y la alerta $0.
--   · COB-4. Cuentas por cobrar y Deudores en mora no descontaban el crédito suelto del cliente
--     (pagos sin boleta): una boleta impaga seguía vencida por el total aunque el cliente tuviera
--     plata a favor, y `consistencia.clientes_con_desvio` marcaba justo esos casos.
--   · REP-2. En Rentabilidad, `ventasNetas` era Σ neto_unitario: en ZZ es el neto teórico
--     (precio / 1,21) con IVA 0, así que brutas − IVA − II no daba netas (sucursal 1, octubre:
--     43,7 M − 0 − 0 contra 36,1 M) y había dos "netos" distintos en la pantalla.
--     `reporte_gerencial.kpis.venta_neta` tenía la misma raíz (Σ total_neto).
--   · REP-4. `tablero_top_clientes_zona` sacaba a los clientes dados de baja del ranking y del
--     total de la zona: en octubre no cerraba contra `tablero_cobertura` por $215.530.
--   · REP-6. `reporte_ventas_por_cliente.zonas` agrupaba por nombre: en la Red sumaba en una fila
--     las zonas homónimas de dos sucursales.
--   · REP-8. La venta "en curso" de `bot_ventas_periodo` contaba pendiente y asignado, pero no lo
--     que está en preparación, y contaba el vale blanco. El Dashboard y el gerencial con "Todos"
--     cuentan pendiente, en preparación y asignado, sin canje ni vale blanco y sin envío.
--   · REP-10. `serie_diaria` salía como 'DD/MM', sin año.
--   · REP-11. Con "Todos", la base de comisión de un vendedor que sólo tenía pedidos sin entregar
--     era su venta en curso (`COALESCE(n.base_nc, e.venta)`).
--
-- QUÉ CAMBIA
--   · `_cxc_boletas(sucursales)`, nueva y sólo de server (como `mermas_valorizadas`): las boletas
--     abiertas con su saldo, el crédito suelto del cliente aplicado FIFO por (fecha, id) como lo
--     aplicaría `aplicar_credito_cliente`, la base de la mora (la entrega en el día argentino), los
--     días de mora contra los `dias_credito` del cliente y si está vencida. Es la única definición
--     de "vencido": la consumen Cuentas por cobrar, Deudores en mora, la alerta y su detalle.
--     Es una lectura, no una imputación: no salta la boleta de su propia NC (mig 283), así que con
--     un crédito de NC el total del cliente es el mismo y el tramo puede correrse a una boleta.
--   · `reporte_cuentas_por_cobrar` y `obtener_deudores_mora` salen de ahí: el saldo y los tramos
--     van descontado el crédito; `totalPagado` incluye el crédito aplicado y cada cliente suma
--     `creditoAplicado` (y `totales.credito_aplicado`). Las formas de la salida no cambian.
--   · `reporte_gerencial`: `v_cob_venc` sale de `_cxc_boletas` (lo vencido de Cuentas por cobrar);
--     `venta_neta` es venta − IVA débito (FC: sin IVA; ZZ: el final), y por lo tanto
--     `margen_comercial_neto` = `margen_real`; `base_nc` es sólo lo entregado; `serie_diaria` va en
--     'YYYY-MM-DD' (el front la muestra como DD/MM).
--   · `reporte_alerta_detalle` ('cobranza_vencida'): la misma regla; la lista suma la alerta.
--   · `reporte_rentabilidad`: `ventasNetas` = brutas − IVA − II, que es el ingreso del margen.
--   · `tablero_top_clientes_zona`: el ranking y el total de la zona incluyen al cliente dado de
--     baja (es historial, como en `tablero_cobertura`); el padrón, los compradores y los
--     inactivos siguen siendo de los activos, y el de baja no hace saltar la alerta.
--   · `reporte_ventas_por_cliente`: las zonas van por id, con `zona_id` y `sucursal` en la salida.
--   · `bot_ventas_periodo`: en curso es pendiente, en preparación y asignado, sin vale blanco.
--
-- LOS NÚMEROS (prod, 10/11)
--   · Antes, con 0 clientes con crédito suelto y deuda a la vez, Cuentas por cobrar y Deudores en
--     mora no cambian. La alerta de Tucumán ya coincidía (213.060); la de Taco Pozo pasa de 0 a
--     1.144.900, lo vencido de Cuentas por cobrar.
--   · En toda la historia, venta − IVA débito = venta real y brutas − IVA − II = ingresos, así que
--     `venta_neta` y `ventasNetas` pasan a esos números sin mover ningún otro. Octubre, sucursal 1:
--     venta_neta 36.121.235,85 → 43.706.703,35; ventasNetas, lo mismo.
--   · Top clientes por zona, octubre, sucursal 1: 39.600.203,35 → 39.815.733,35, lo de cobertura.
--   · Los cruces de `check-integridad.mjs` (venta del gerencial contra clientes, preventistas,
--     categorías y mes a mes) no tocan nada de esto y siguen cerrando.
--
-- QUÉ NO CAMBIA
--   La "venta por vendedor" (la definición de CLAUDE.md), la cobranza del gerencial, `calcular_comisiones`,
--   las firmas, el SECURITY DEFINER y los EXECUTE de las funciones que ya existían. Los parches van
--   por ancla sobre el cuerpo vivo, con premisa de md5; `reporte_cuentas_por_cobrar`,
--   `obtener_deudores_mora` y `tablero_top_clientes_zona` se reescriben enteras.
--
-- Ensayo: scripts/test-reportes-vencido-y-neto-1518.sql. Se aplica en LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos son los que se leyeron de prod el 10/11
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('public.reporte_gerencial(bigint,date,date,boolean,boolean)',           '891bddbeab3a71344d64c93bea9adfbe'),
      ('public.reporte_alerta_detalle(bigint,text,date,date,boolean)',         'e7740a30bdec8345b4888abd381c6f6a'),
      ('public.reporte_rentabilidad(date,date,bigint,text)',                   'a9a55a0d18453bf4689d5aa720635814'),
      ('public.reporte_cuentas_por_cobrar(bigint)',                            'b93a9dd5ee752f4f6901dea3c168f351'),
      ('public.obtener_deudores_mora(integer)',                                '4ad44defb1b3e297be3c18272af9210a'),
      ('public.tablero_top_clientes_zona(bigint,date,date,integer,integer)',   '8594ad0ce2f69e64ae842786b211c74f'),
      ('public.reporte_ventas_por_cliente(date,date,uuid,bigint)',             '2a3b70fe90348908d6c739cccd5db201'),
      ('public.bot_ventas_periodo(date,date,bigint,integer)',                  '95eddae68a502452652022b62f49318d')
    ) AS t(fn, md5)
  LOOP
    IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = r.fn::regprocedure) IS DISTINCT FROM r.md5 THEN
      RAISE EXCEPTION 'mig 485 · % cambió en prod desde que se leyó: rehacer sobre la definición vigente', r.fn;
    END IF;
  END LOOP;
  IF to_regproc('public._cxc_boletas') IS NOT NULL THEN
    RAISE EXCEPTION 'mig 485 · _cxc_boletas ya existe';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- Parche por ancla: cada ancla aparece una sola vez en el cuerpo vivo
-- ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp.parchear(p_fn regprocedure, p_anclas text[], p_reemplazos text[])
RETURNS void
LANGUAGE plpgsql
AS $parchear$
DECLARE
  v_def text := pg_get_functiondef(p_fn);
  v_n   int;
BEGIN
  FOR i IN 1 .. array_length(p_anclas, 1) LOOP
    v_n := (length(v_def) - length(replace(v_def, p_anclas[i], ''))) / length(p_anclas[i]);
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'mig 485 · %: el ancla % aparece % vez/veces y se esperaba 1', p_fn, i, v_n;
    END IF;
    v_def := replace(v_def, p_anclas[i], p_reemplazos[i]);
  END LOOP;
  EXECUTE v_def;
END
$parchear$;

-- ---------------------------------------------------------------------------
-- _cxc_boletas: la única definición de "vencido" (REP-1) con el crédito suelto (COB-4)
-- ---------------------------------------------------------------------------
CREATE FUNCTION public._cxc_boletas(p_sucursales bigint[])
RETURNS TABLE(pedido_id bigint, cliente_id bigint, sucursal_id bigint, estado text,
              total numeric, monto_pagado numeric, saldo numeric, credito numeric,
              saldo_neto numeric, base_mora date, dias_mora integer, vencido boolean)
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $fn$
  -- #1518 (REP-1, COB-4). Las boletas abiertas de las sucursales: no canceladas ni anuladas,
  -- con saldo (total − pagado > 0). De cada una sale lo que la consume:
  --   · saldo_neto: el saldo menos el crédito suelto del cliente en esa sucursal (pagos sin
  --     boleta), aplicado FIFO por (fecha, id), el orden de aplicar_credito_cliente. Una boleta
  --     que el crédito cubre entera queda con saldo_neto 0. Es una lectura: no salta la boleta
  --     de su propia NC (mig 283), así que el total del cliente es el mismo y el tramo puede
  --     correrse de boleta.
  --   · base_mora: la entrega en el día argentino (#1250), o la fecha del pedido.
  --   · dias_mora: hoy (argentino) menos la base más los días de crédito del cliente (30 si no
  --     tiene). vencido: entregada y con dias_mora > 0. Lo que no está entregado es corriente.
  -- La consumen reporte_cuentas_por_cobrar, obtener_deudores_mora, la alerta de cobranza vencida
  -- del gerencial y su detalle: el mismo vencido en las cuatro.
  WITH abiertas AS (
    SELECT p.id, p.cliente_id, p.sucursal_id, p.estado, p.fecha, p.total, p.monto_pagado,
           GREATEST(0, COALESCE(p.total, 0) - COALESCE(p.monto_pagado, 0)) AS saldo,
           COALESCE((p.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date,
                    p.fecha,
                    (p.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date) AS base_mora
      FROM pedidos p
     WHERE p.estado NOT IN ('cancelado', 'anulado')
       AND p.estado_pago IS DISTINCT FROM 'pagado'
       AND p.sucursal_id = ANY(p_sucursales)
       AND COALESCE(p.total, 0) - COALESCE(p.monto_pagado, 0) > 0
  ),
  creditos AS (
    SELECT g.cliente_id, g.sucursal_id, SUM(g.monto) AS monto
      FROM pagos g
     WHERE g.pedido_id IS NULL
       AND g.sucursal_id = ANY(p_sucursales)
     GROUP BY g.cliente_id, g.sucursal_id
  ),
  fifo AS (
    SELECT a.*,
           COALESCE(cr.monto, 0) AS credito_cliente,
           SUM(a.saldo) OVER (PARTITION BY a.cliente_id, a.sucursal_id ORDER BY a.fecha, a.id)
             - a.saldo AS antes
      FROM abiertas a
      LEFT JOIN creditos cr ON cr.cliente_id = a.cliente_id AND cr.sucursal_id = a.sucursal_id
  ),
  aplicado AS (
    SELECT f.*, LEAST(f.saldo, GREATEST(f.credito_cliente - f.antes, 0)) AS credito
      FROM fifo f
  )
  SELECT ap.id, ap.cliente_id, ap.sucursal_id, ap.estado, ap.total, ap.monto_pagado, ap.saldo,
         ap.credito,
         ap.saldo - ap.credito AS saldo_neto,
         ap.base_mora,
         (public._tablero_hoy() - (ap.base_mora + COALESCE(c.dias_credito, 30)))::int AS dias_mora,
         (ap.estado = 'entregado'
           AND public._tablero_hoy() - (ap.base_mora + COALESCE(c.dias_credito, 30)) > 0) AS vencido
    FROM aplicado ap
    JOIN clientes c ON c.id = ap.cliente_id
$fn$;

-- Sólo de server: la llaman las RPCs SECURITY DEFINER de abajo (corren como postgres). Sin
-- EXECUTE para nadie que llegue por la API: recibe sucursales y no las acota.
REVOKE ALL ON FUNCTION public._cxc_boletas(bigint[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._cxc_boletas(bigint[]) TO service_role;

-- ---------------------------------------------------------------------------
-- reporte_cuentas_por_cobrar (COB-4): las boletas, el crédito y los tramos de _cxc_boletas
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reporte_cuentas_por_cobrar(p_sucursal_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursales  bigint[];
  v_asignadas   bigint[];
  v_es_servicio boolean := (auth.uid() IS NULL);
  v_out         jsonb;
BEGIN
  IF NOT v_es_servicio THEN
    IF NOT public.es_encargado_o_admin() THEN
      RAISE EXCEPTION 'Acceso denegado: se requiere rol admin o encargado';
    END IF;
    SELECT array_agg(sucursal_id) INTO v_asignadas
      FROM usuario_sucursales WHERE usuario_id = auth.uid();
    IF v_asignadas IS NULL THEN
      RAISE EXCEPTION 'Acceso denegado: el usuario no tiene sucursales asignadas';
    END IF;
  END IF;

  IF p_sucursal_id IS NULL THEN
    v_sucursales := public._sucursales_red();  -- #1262 (REP-8)
  ELSE
    -- #982: la sucursal pedida tiene que ser una de las asignadas.
    IF NOT v_es_servicio AND NOT (p_sucursal_id = ANY(v_asignadas)) THEN
      RAISE EXCEPTION 'Acceso denegado: la sucursal % no está asignada al usuario', p_sucursal_id
        USING ERRCODE = '42501';
    END IF;
    v_sucursales := ARRAY[p_sucursal_id];
  END IF;

  WITH con_tramo AS (
    -- #1518 (COB-4): las boletas, la mora y el vencido salen de _cxc_boletas, la misma regla que
    -- la alerta de cobranza vencida del gerencial. El saldo va descontado el crédito suelto del
    -- cliente (FIFO, de la boleta más vieja a la más nueva); la que el crédito cubre entera no
    -- figura. Lo cubierto con crédito cuenta como pagado: total − pagado sigue siendo el saldo.
    SELECT b.cliente_id,
           b.total,
           COALESCE(b.monto_pagado, 0) + b.credito AS pagado,
           b.credito,
           b.saldo_neto AS saldo,
           CASE
             WHEN NOT b.vencido        THEN 'corriente'
             WHEN b.dias_mora <= 30    THEN 'vencido30'
             WHEN b.dias_mora <= 60    THEN 'vencido60'
             ELSE 'vencido90'
           END AS tramo
      FROM public._cxc_boletas(v_sucursales) b
     WHERE b.saldo_neto > 0
  ),
  por_cliente AS (
    SELECT ct.cliente_id,
           SUM(ct.total)                                        AS total_deuda,
           SUM(ct.pagado)                                       AS total_pagado,
           SUM(ct.credito)                                      AS credito_aplicado,
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
           c.nombre_fantasia, c.razon_social, z.nombre AS zona, c.cuit, c.telefono,
           c.activo, c.dias_credito,
           COALESCE(c.limite_credito,0) AS limite_credito,
           COALESCE(c.saldo_cuenta,0)   AS saldo_cuenta
    FROM por_cliente pc
    JOIN clientes c ON c.id = pc.cliente_id
    LEFT JOIN zonas z ON z.id = c.zona_id
  )
  SELECT jsonb_build_object(
    'meta', jsonb_build_object(
      'generado_at', now(),
      'criterio', 'Pedidos no cancelados ni anulados con saldo (total - monto_pagado > 0), '
                  'descontado el saldo a favor sin imputar del cliente (de la boleta mas vieja a la mas nueva). '
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
        'vencido90', COALESCE(ROUND(SUM(vencido90),2),0),
        'credito_aplicado', COALESCE(ROUND(SUM(credito_aplicado),2),0)
      ) FROM filas
    ),
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
          'creditoAplicado',  ROUND(f.credito_aplicado,2),
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
$function$;

-- ---------------------------------------------------------------------------
-- obtener_deudores_mora (COB-4): lo vencido, descontado el crédito suelto
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_deudores_mora(p_dias_min integer DEFAULT 1)
 RETURNS TABLE(cliente_id bigint, nombre text, saldo numeric, saldo_vencido numeric, dias_mora_max integer, pedido_mas_viejo date)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal_id bigint;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no seleccionada';
  END IF;
  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  RETURN QUERY
  WITH pedidos_vencidos AS (
    -- #1518 (COB-4): las boletas y la mora salen de _cxc_boletas, como en Cuentas por cobrar:
    -- la entrega en el día argentino más los días de crédito del cliente (#1250), y el saldo de
    -- cada boleta descontado el crédito a favor sin imputar (FIFO). Una boleta que el crédito
    -- cubre entera no está en mora.
    SELECT b.cliente_id AS cli_id,
           b.saldo_neto AS saldo_pedido,
           b.base_mora  AS base_date,
           b.dias_mora
      FROM public._cxc_boletas(ARRAY[v_sucursal_id]) b
     WHERE b.estado = 'entregado'
       AND b.saldo_neto > 0
  )
  SELECT
    c.id AS cliente_id,
    c.nombre_fantasia AS nombre,
    COALESCE(c.saldo_cuenta, 0)::numeric AS saldo,
    COALESCE(SUM(pv.saldo_pedido) FILTER (WHERE pv.dias_mora >= p_dias_min), 0)::numeric AS saldo_vencido,
    MAX(pv.dias_mora)::int AS dias_mora_max,
    MIN(pv.base_date) AS pedido_mas_viejo
  FROM pedidos_vencidos pv
  JOIN clientes c ON c.id = pv.cli_id
  GROUP BY c.id, c.nombre_fantasia, c.saldo_cuenta
  HAVING MAX(pv.dias_mora) >= p_dias_min
  ORDER BY MAX(pv.dias_mora) DESC, COALESCE(c.saldo_cuenta, 0) DESC;
END;
$function$;

-- ---------------------------------------------------------------------------
-- reporte_gerencial: el vencido de Cuentas por cobrar, un solo neto, la base de comisión
-- entregada y la serie con año
-- ---------------------------------------------------------------------------
SELECT pg_temp.parchear('public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure,
  ARRAY[
$a$            COALESCE(SUM(total_neto),0) AS venta_neta,$a$,
$a$      CASE WHEN pf.id IS NULL THEN 0 ELSE COALESCE(n.base_nc, e.venta) END AS base_nc$a$,
$a$  serie AS (SELECT to_char(fecha,'DD/MM') AS dia, SUM(venta_prod) AS venta FROM ped GROUP BY fecha ORDER BY fecha)$a$,
$a$  SELECT COALESCE(SUM(total - COALESCE(monto_pagado,0)),0), COUNT(DISTINCT cliente_id)
    INTO v_cob_venc, v_cob_venc_cli
  FROM pedidos
  WHERE estado='entregado' AND canal <> 'cambio' AND sucursal_id = ANY(v_sucursales)
    AND COALESCE(estado_pago,'pendiente') IN ('pendiente','parcial')
    AND fecha < v_hoy - 30 AND total > COALESCE(monto_pagado,0);  -- #1250
  IF v_cob_venc > 0 THEN
    v_alertas := v_alertas || jsonb_build_object('severidad','critical','codigo','cobranza_vencida','titulo','Cobranza vencida',
      'detalle', v_cob_venc_cli::text||' cliente(s) con saldo impago hace +30 días',$a$
  ],
  ARRAY[
$r$            -- #1518 (REP-2): el neto es uno, la venta menos el IVA débito (FC: sin IVA; ZZ: el
            -- final, que no discrimina IVA). Σ total_neto era el neto teórico de la ZZ (precio /
            -- 1,21), que no es plata de nadie. Da lo mismo que venta_real.
            COALESCE(SUM(venta_prod - total_iva),0) AS venta_neta,$r$,
$r$      -- #1518 (REP-11): la base es lo entregado (`nc`) también con "Todos". Con
      -- COALESCE(n.base_nc, e.venta), un vendedor con sólo pedidos sin entregar tenía de base su
      -- venta en curso: la venta se reconoce con la entrega.
      CASE WHEN pf.id IS NULL THEN 0 ELSE COALESCE(n.base_nc, 0) END AS base_nc$r$,
$r$  -- #1518 (REP-10): el día con año (ISO); el front lo muestra como DD/MM.
  serie AS (SELECT to_char(fecha,'YYYY-MM-DD') AS dia, SUM(venta_prod) AS venta FROM ped GROUP BY fecha ORDER BY fecha)$r$,
$r$  -- #1518 (REP-1, COB-4): lo vencido es lo de Cuentas por cobrar, con su misma regla
  -- (_cxc_boletas): la entrega más los días de crédito del cliente, descontado el crédito
  -- suelto. Antes era la fecha del pedido más 30 días: en Taco Pozo (7 días) la alerta daba $0.
  SELECT COALESCE(SUM(b.saldo_neto),0), COUNT(DISTINCT b.cliente_id)
    INTO v_cob_venc, v_cob_venc_cli
  FROM public._cxc_boletas(v_sucursales) b
  WHERE b.vencido AND b.saldo_neto > 0;
  IF v_cob_venc > 0 THEN
    v_alertas := v_alertas || jsonb_build_object('severidad','critical','codigo','cobranza_vencida','titulo','Cobranza vencida',
      'detalle', v_cob_venc_cli::text||' cliente(s) con saldo vencido según sus días de crédito',$r$
  ]);

-- ---------------------------------------------------------------------------
-- reporte_alerta_detalle: la lista detrás de la alerta, con la misma regla
-- ---------------------------------------------------------------------------
SELECT pg_temp.parchear('public.reporte_alerta_detalle(bigint,text,date,date,boolean)'::regprocedure,
  ARRAY[
$a$    -- Sin filtro de periodo a proposito: la alerta es contra hoy - 30.
    SELECT COALESCE(jsonb_agg(jsonb_build_object('nombre', nombre, 'valor', valor, 'detalle', detalle) ORDER BY valor DESC), '[]')
      INTO v_result FROM (
      SELECT COALESCE(NULLIF(c.nombre_fantasia,''), c.razon_social) AS nombre,
             SUM(p.total - COALESCE(p.monto_pagado,0)) AS valor,
             'hace ' || MAX(v_hoy - p.fecha) || ' días' AS detalle
      FROM pedidos p JOIN clientes c ON c.id = p.cliente_id
      WHERE p.estado='entregado' AND p.canal <> 'cambio' AND p.sucursal_id = ANY(v_sucursales)
        AND p.tipo_factura IS DISTINCT FROM 'VB'
        AND COALESCE(p.estado_pago,'pendiente') IN ('pendiente','parcial')
        AND p.fecha < v_hoy - 30 AND p.total > COALESCE(p.monto_pagado,0)
      GROUP BY c.id, c.nombre_fantasia, c.razon_social
      ORDER BY valor DESC
      LIMIT 100$a$
  ],
  ARRAY[
$r$    -- Sin filtro de período a propósito: la alerta es contra hoy. #1518 (REP-1, COB-4): la
    -- regla de Cuentas por cobrar y de la alerta (_cxc_boletas), la entrega más los días de
    -- crédito del cliente y descontado el crédito suelto. La lista suma la alerta.
    SELECT COALESCE(jsonb_agg(jsonb_build_object('nombre', nombre, 'valor', valor, 'detalle', detalle) ORDER BY valor DESC), '[]')
      INTO v_result FROM (
      SELECT COALESCE(NULLIF(c.nombre_fantasia,''), c.razon_social) AS nombre,
             SUM(b.saldo_neto) AS valor,
             'vencida hace ' || MAX(b.dias_mora) || ' días' AS detalle
      FROM public._cxc_boletas(v_sucursales) b JOIN clientes c ON c.id = b.cliente_id
      WHERE b.vencido AND b.saldo_neto > 0
      GROUP BY c.id, c.nombre_fantasia, c.razon_social
      ORDER BY valor DESC, c.id
      LIMIT 100$r$
  ]);

-- ---------------------------------------------------------------------------
-- reporte_rentabilidad (REP-2): netas = brutas − IVA − II
-- ---------------------------------------------------------------------------
SELECT pg_temp.parchear('public.reporte_rentabilidad(date,date,bigint,text)'::regprocedure,
  ARRAY[
$a$           pi.cantidad * COALESCE(pi.neto_unitario,
             COALESCE(pi.ingreso_real_unitario, pi.precio_unitario)) AS neto,
$a$,
$a$        'ventasNetas',       (SELECT COALESCE(ROUND(SUM(neto),2),0) FROM it),$a$
  ],
  ARRAY[
'',
$r$        -- #1518 (REP-2): un solo neto. Netas = brutas − IVA − II, y es el ingreso del margen
        -- (FC: sin IVA; ZZ: el final). Antes era Σ neto_unitario, el neto teórico de la ZZ
        -- (precio / 1,21): en octubre dejaba 7,6 M sin explicar en la sucursal 1.
        'ventasNetas',       (SELECT COALESCE(ROUND(SUM(subtotal),2),0) - COALESCE(ROUND(SUM(iva),2),0)
                                     - COALESCE(ROUND(SUM(imp_internos),2),0) FROM it),$r$
  ]);

-- ---------------------------------------------------------------------------
-- reporte_ventas_por_cliente (REP-6): las zonas por id
-- ---------------------------------------------------------------------------
SELECT pg_temp.parchear('public.reporte_ventas_por_cliente(date,date,uuid,bigint)'::regprocedure,
  ARRAY[
$a$      c.codigo,
      COALESCE(z.nombre, 'SIN ZONA') AS zona
    FROM ventana v
    LEFT JOIN clientes c ON c.id = v.cliente_id
    LEFT JOIN zonas    z ON z.id = c.zona_id$a$,
$a$    SELECT cliente_id, nombre, codigo, zona,
           COUNT(*)::int AS pedidos,
           SUM(total)    AS total
    FROM base
    GROUP BY cliente_id, nombre, codigo, zona$a$,
$a$    SELECT zona,
           COUNT(*)::int      AS clientes,
           SUM(pedidos)::int  AS pedidos,
           SUM(total)         AS total
    FROM por_cliente
    GROUP BY zona$a$,
$a$               'zona',            pz.zona,$a$
  ],
  ARRAY[
$r$      c.codigo,
      -- #1518 (REP-6): la zona va por id. Por nombre, la Red sumaba en una fila las zonas
      -- homónimas de dos sucursales. La sucursal de la zona las distingue en pantalla.
      z.id AS zona_id,
      COALESCE(z.nombre, 'SIN ZONA') AS zona,
      zs.nombre AS zona_sucursal
    FROM ventana v
    LEFT JOIN clientes c ON c.id = v.cliente_id
    LEFT JOIN zonas    z ON z.id = c.zona_id
    LEFT JOIN sucursales zs ON zs.id = z.sucursal_id$r$,
$r$    SELECT cliente_id, nombre, codigo, zona_id, zona, zona_sucursal,
           COUNT(*)::int AS pedidos,
           SUM(total)    AS total
    FROM base
    GROUP BY cliente_id, nombre, codigo, zona_id, zona, zona_sucursal$r$,
$r$    SELECT zona_id, zona, zona_sucursal,
           COUNT(*)::int      AS clientes,
           SUM(pedidos)::int  AS pedidos,
           SUM(total)         AS total
    FROM por_cliente
    GROUP BY zona_id, zona, zona_sucursal$r$,
$r$               'zona_id',         pz.zona_id,
               'zona',            pz.zona,
               'sucursal',        pz.zona_sucursal,$r$
  ]);

-- ---------------------------------------------------------------------------
-- bot_ventas_periodo (REP-8): en curso es lo tomado y sin entregar, sin vale blanco
-- ---------------------------------------------------------------------------
SELECT pg_temp.parchear('public.bot_ventas_periodo(date,date,bigint,integer)'::regprocedure,
  ARRAY[
$a$      AND canal <> 'cambio'
      AND COALESCE(estado, '') IN ('asignado', 'pendiente')$a$
  ],
  ARRAY[
$r$      AND canal <> 'cambio'
      -- #1518 (REP-8): en curso es todo lo tomado y sin entregar, como el Dashboard y el
      -- gerencial con "Todos": también lo que está en preparación. El vale blanco no es venta.
      AND tipo_factura IS DISTINCT FROM 'VB'
      AND COALESCE(estado, '') IN ('pendiente', 'en_preparacion', 'asignado')$r$
  ]);

-- ---------------------------------------------------------------------------
-- tablero_top_clientes_zona (REP-4): el cliente dado de baja sigue en la venta de su zona
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tablero_top_clientes_zona(p_sucursal_id bigint DEFAULT NULL::bigint, p_desde date DEFAULT NULL::date, p_hasta date DEFAULT NULL::date, p_limit integer DEFAULT 10, p_dias_alerta integer DEFAULT 14)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucs  bigint[] := _tablero_sucursales(p_sucursal_id);
  v_hoy   date := _tablero_hoy();
  v_hasta date := COALESCE(p_hasta, _tablero_hoy());
  v_desde date := COALESCE(p_desde, make_date(extract(year FROM COALESCE(p_hasta, _tablero_hoy()))::int, 1, 1));
  r jsonb;
BEGIN
  WITH cli AS (
    -- #1518 (REP-4): también los dados de baja. Su venta es historial y sigue siendo venta de la
    -- zona: el ranking y el total la incluyen, como la facturación de tablero_cobertura. El
    -- padrón de la zona, los compradores y los inactivos siguen siendo de los activos, y un
    -- cliente de baja no hace saltar la alerta.
    SELECT c.id, c.zona_id, c.codigo, c.telefono, c.activo,
           COALESCE(NULLIF(btrim(c.nombre_fantasia), ''), c.razon_social) AS nombre
      FROM clientes c
     WHERE c.sucursal_id = ANY(v_sucs) AND c.zona_id IS NOT NULL
  ),
  per AS (
    SELECT cliente_id, sum(total) AS total, count(*) AS pedidos
      FROM _tablero_ventas(v_sucs, v_desde, v_hasta) GROUP BY cliente_id
  ),
  ult AS (
    SELECT cliente_id, max(fecha) AS ultima
      FROM _tablero_ventas(v_sucs, '2000-01-01', v_hoy) GROUP BY cliente_id
  ),
  rk AS (
    SELECT cli.*, per.total, per.pedidos, ult.ultima,
           (v_hoy - ult.ultima) AS dias,
           row_number() OVER (PARTITION BY cli.zona_id ORDER BY per.total DESC NULLS LAST, cli.nombre, cli.id) AS rn
      FROM cli JOIN per ON per.cliente_id = cli.id
      LEFT JOIN ult ON ult.cliente_id = cli.id
  ),
  zs AS (
    SELECT z.id, z.nombre, z.sucursal_id, pf.nombre AS preventista,
           (SELECT count(*) FROM cli WHERE cli.zona_id = z.id AND cli.activo) AS clientes_zona,
           (SELECT count(*) FROM rk WHERE rk.zona_id = z.id AND rk.activo) AS compradores,
           (SELECT COALESCE(sum(total), 0) FROM rk WHERE rk.zona_id = z.id) AS total,
           (SELECT count(*) FROM cli LEFT JOIN ult ON ult.cliente_id = cli.id
             WHERE cli.zona_id = z.id AND cli.activo
               AND (ult.ultima IS NULL OR v_hoy - ult.ultima > p_dias_alerta)) AS inactivos
      FROM zonas z
      LEFT JOIN preventista_zonas pz ON pz.zona_id = z.id
      LEFT JOIN perfiles pf ON pf.id = pz.perfil_id
     WHERE z.sucursal_id = ANY(v_sucs) AND COALESCE(z.activo, true)
  )
  SELECT jsonb_build_object(
    'desde', v_desde, 'hasta', v_hasta, 'hoy', v_hoy, 'dias_alerta', p_dias_alerta,
    'zonas', COALESCE(jsonb_agg(jsonb_build_object(
      'zona_id', zs.id, 'zona', zs.nombre, 'sucursal_id', zs.sucursal_id, 'preventista', zs.preventista,
      'clientes_zona', zs.clientes_zona, 'compradores', zs.compradores, 'total', zs.total, 'inactivos', zs.inactivos,
      'top', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                 'rank', rk.rn, 'cliente_id', rk.id, 'codigo', rk.codigo, 'nombre', rk.nombre,
                 'telefono', rk.telefono, 'activo', rk.activo, 'total', rk.total, 'pedidos', rk.pedidos,
                 'ticket', round(rk.total / NULLIF(rk.pedidos, 0), 2),
                 'ultima_compra', rk.ultima, 'dias_sin_compra', rk.dias,
                 'alerta', (rk.activo AND (rk.ultima IS NULL OR rk.dias > p_dias_alerta))) ORDER BY rk.rn)
          FROM rk WHERE rk.zona_id = zs.id AND rk.rn <= p_limit), '[]'::jsonb)
    ) ORDER BY zs.total DESC), '[]'::jsonb)
  ) INTO r FROM zs;
  RETURN r;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, el definer y los EXECUTE quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  v record;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('public._cxc_boletas(bigint[])',                                         '06118b6014fe35a1e6c8166aed4b4e27', false,
       '{postgres=X/postgres,service_role=X/postgres}'),
      ('public.reporte_gerencial(bigint,date,date,boolean,boolean)',            'a324634a3aafa53d8c45ab56b4b2c3f0', true,
       '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
      ('public.reporte_alerta_detalle(bigint,text,date,date,boolean)',          '1098d1b1d04c5185a8de76c78f1332fe', true,
       '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
      ('public.reporte_rentabilidad(date,date,bigint,text)',                    '45de214d8f0bab256740889d317fcf57', true,
       '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
      ('public.reporte_cuentas_por_cobrar(bigint)',                             '2b3e819aaaeddb405cab16eef276d1e8', true,
       '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
      ('public.obtener_deudores_mora(integer)',                                 '8682f3b60e9e6a209de9d9f8c30b52ce', true,
       '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
      ('public.tablero_top_clientes_zona(bigint,date,date,integer,integer)',    'b862b2b82e158acebc59009b4b374fc5', true,
       '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
      ('public.reporte_ventas_por_cliente(date,date,uuid,bigint)',              '8d4004f14c0d8581155bdac50c549371', true,
       '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
      ('public.bot_ventas_periodo(date,date,bigint,integer)',                   'bd6bef33c089422952ddb0e549be3cc9', true,
       '{postgres=X/postgres,service_role=X/postgres}')
    ) AS t(fn, md5, definer, acl)
  LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO v
      FROM pg_proc WHERE oid = r.fn::regprocedure;
    IF v.h IS DISTINCT FROM r.md5 OR v.a IS DISTINCT FROM r.acl OR v.def IS DISTINCT FROM r.definer THEN
      RAISE EXCEPTION 'mig 485 · % no quedó como en el repo (md5 %, acl %, definer %)', r.fn, v.h, v.a, v.def;
    END IF;
  END LOOP;
END
$post$;

COMMIT;
