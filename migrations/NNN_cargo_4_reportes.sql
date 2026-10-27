-- NNN · Cargo de envio: la venta de los reportes es de productos (lo que falta
-- del cargo de envio sobre la 389, #1220, spec §2).
--
-- Diseno: docs/superpowers/specs/2026-10-26-cargo-envio-faltantes-design.md.
-- Cuarta migracion del plan; requiere cargo_1_base (cargo_envio_desglose).
--
-- El cargo de envio vive DENTRO de pedidos.total (mig 389):
--   total = SUM(subtotal) + (SUM(subtotal) > 0 ? cargo_envio : 0)
-- y desde cargo_1_base su desglose fiscal (FC 21 % incluido, ZZ todo neto, VB
-- nada) va dentro de total_neto/total_iva. Lo que es VENTA (de quien vende, del
-- cliente, del dia) es de productos:
--   venta de productos = GREATEST(total - cargo_envio, 0)
--   cargo efectivo     = total - GREATEST(total - cargo_envio, 0)
-- y lo que es PLATA A COBRAR (saldo, cobranza, deuda, pendientes de entrega,
-- recorridos, rendiciones, jornadas del transportista) sigue con total.
-- posicion_fiscal NO se toca: el IVA del envio se declara.
--
-- Con cargo_envio = 0 cada expresion nueva da exactamente lo mismo que la
-- vieja (GREATEST(total - 0, 0) = total, porque total >= 0 por CHECK, y el
-- desglose solo se resta si cargo_envio > 0). El ensayo lo prueba: foto de
-- cada funcion migrada antes y despues, con los cargos neutralizados.
--
-- INVENTARIO (prod, 2026-10-27). Consulta del plan:
--   SELECT p.oid::regprocedure FROM pg_proc p
--    WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'
--      AND pg_get_functiondef(p.oid) ~ 'canal <> ''cambio'''
--      AND pg_get_functiondef(p.oid) ~* '\mtotal\M';
-- da 22 funciones. Mas reporte_ventas_por_cliente, que filtra
-- COALESCE(pe.canal, 'app') <> 'cambio' y no entra en la regex.
--
--   SE MIGRAN (11):
--   reporte_gerencial          kpis.venta/ticket/fc_venta/zz_venta, venta_neta
--                              e iva_debito (sin el desglose del envio),
--                              venta_real (solo su fallback sin total_real),
--                              base_comision y vendedores[].base_nc, mensual
--                              (venta, ticket), serie_diaria, top_clientes; los
--                              margenes y la alerta de venta en baja salen de
--                              kpis.venta. NO: cobranza (cobrado/pendiente),
--                              alerta de cobranza vencida, consumo interno (VB,
--                              cargo 0 por construccion).
--   reporte_ventas_por_cliente todo es venta (clientes, zonas, vendedores, por_mes).
--   reporte_ventas_por_preventista  solo totalVentas; totalPagado y
--                              totalPendiente son plata a cobrar.
--   bot_mis_ventas             total_ventas, ticket, top_clientes.
--   bot_ventas_periodo         total_ventas, ticket, top_clientes y en_curso
--                              (venta en curso, misma unidad que total_ventas).
--   bot_digest_preventista     dia_tomados_total (lo que tomo el preventista;
--                              el mes sale de bot_mis_ventas).
--   bot_metricas_admin_dia     ventas_dia (total y ticket), promedio_7d y
--                              delta_pct, entregado_dia, top_clientes. NO:
--                              pendientes_entrega (lo que el chofer cobra),
--                              pendientes_pago, cuentas por cobrar.
--   clientes_ritmo_compra      monto_mensual (lo hereda bot_clientes_atrasados,
--                              bot_riesgo_por_preventista, bot_resumen_cliente_visita).
--                              saldo sigue siendo el saldo.
--   reporte_alerta_detalle     clientes_inactivos (venta 90 dias). NO:
--                              cobranza_vencida.
--   jornadas_preventista       monto del pedido entregado y de los pendientes
--                              (lo que vendio / tiene tomado el preventista).
--   jornada_preventista_detalle  monto del pedido entregado.
--
--   NO SE MIGRAN:
--   posicion_fiscal            el IVA del envio se declara (spec §3).
--   jornadas_transportista, jornada_transportista_detalle  plata que cobra el chofer.
--   obtener_resumen_cuenta_cliente, obtener_resumen_cuenta_cliente_bot
--                              total_compras es la cuenta corriente
--                              (saldo = compras - pagos): el envio se debe.
--   bot_historico_pedidos_cliente  historial de la cuenta del cliente: cada
--                              pedido con lo que se le cobro.
--   bot_resumen_cliente_visita total del ultimo pedido (lo que pago); su monto
--                              mensual ya sale de clientes_ritmo_compra.
--   bot_riesgo_por_preventista lo hereda de clientes_ritmo_compra.
--   avance_metas_preventista, rendimiento_preventistas, calcular_comisiones,
--   reporte_rentabilidad, reporte_combos*, reporte_rechazos  la venta sale de
--                              las lineas (pedido_items), no de total.
--   bot_mis_clientes           'total' es un COUNT.
--   obtener_estadisticas_pedidos, bot_sugerir_visitas_rfm  no existen en prod.
--   tablero_kpis, tablero_facturacion_mensual, tablero_top_clientes_zona,
--   tablero_ficha_cliente, tablero_cobertura, tablero_clientes_inactivos
--                              no siguen la definicion de venta (ni filtran el
--                              canje) y no los llama este repo ni otra funcion.
--
-- Ninguna firma ni forma de respuesta cambia: solo los numeros (y desde hoy
-- solo los de pedidos con cargo). Cada funcion se PARCHEA por ancla sobre la
-- definicion viva (molde de la 373 / cargo_1_base): cada ancla tiene que
-- aparecer exactamente una vez, o la migracion se cae en vez de pisar algo.
-- CREATE OR REPLACE conserva dueno, SECURITY DEFINER, search_path y ACL; el
-- bloque final lo verifica contra la foto de la ACL. Ninguna de las 11 tiene
-- su md5 en una lista blanca (SEG-A).
--
-- Ensayo: scripts/test-cargo-4.sql (parte 1 antes de esta migracion, parte 2
-- despues; ver su encabezado).

SET LOCAL lock_timeout = '5s';

-- ---------------------------------------------------------------------------
-- 0 · Premisas
-- ---------------------------------------------------------------------------
DO $premisas$
BEGIN
  IF to_regprocedure('public.cargo_envio_desglose(numeric,text)') IS NULL THEN
    RAISE EXCEPTION 'cargo_4: falta cargo_envio_desglose (aplicar antes cargo_1_base)';
  END IF;
END
$premisas$;

-- La ACL de las 11, tal como esta antes de tocarlas (la seccion 2 exige que
-- quede identica).
DROP TABLE IF EXISTS pg_temp._cargo4_acl;
CREATE TEMP TABLE _cargo4_acl AS
SELECT p.oid, p.proname::text AS proname, p.proacl::text AS acl, p.prosecdef, p.proconfig::text AS config
  FROM pg_proc p
 WHERE p.pronamespace = 'public'::regnamespace
   AND p.proname IN ('reporte_gerencial', 'reporte_ventas_por_cliente', 'reporte_ventas_por_preventista',
                     'bot_mis_ventas', 'bot_ventas_periodo', 'bot_digest_preventista',
                     'bot_metricas_admin_dia', 'clientes_ritmo_compra', 'reporte_alerta_detalle',
                     'jornadas_preventista', 'jornada_preventista_detalle');

DO $premisas$
BEGIN
  IF (SELECT count(*) FROM _cargo4_acl) <> 11 THEN
    RAISE EXCEPTION 'cargo_4: se esperaban 11 funciones (una por nombre), hay %', (SELECT count(*) FROM _cargo4_acl);
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 1 · Parches por ancla sobre la definicion viva
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.cargo4_parchar(p_def text, p_viejo text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
  v_veces int := (length(p_def) - length(replace(p_def, p_viejo, ''))) / length(p_viejo);
BEGIN
  IF v_veces <> 1 THEN
    RAISE EXCEPTION '%: el ancla aparece % veces (se esperaba 1). El cuerpo vivo cambio: revisar a mano', p_que, v_veces;
  END IF;
  RETURN replace(p_def, p_viejo, p_nuevo);
END
$fn$;

-- Igual, con una expresion regular: para las anclas con columnas alineadas a
-- espacios, donde el ancla literal dependeria de contar blancos.
CREATE OR REPLACE FUNCTION pg_temp.cargo4_parchar_re(p_def text, p_patron text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
  v_veces int := regexp_count(p_def, p_patron);
BEGIN
  IF v_veces <> 1 THEN
    RAISE EXCEPTION '%: el ancla aparece % veces (se esperaba 1). El cuerpo vivo cambio: revisar a mano', p_que, v_veces;
  END IF;
  RETURN regexp_replace(p_def, p_patron, p_nuevo);
END
$fn$;

-- 1a · reporte_gerencial
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure);
BEGIN
  -- `ped` suma venta_prod y deja total para la cobranza (cobr_ped).
  v_def := pg_temp.cargo4_parchar(v_def,
$q$    SELECT id, cliente_id, usuario_id, total, monto_pagado, fecha, forma_pago, estado_pago,
           COALESCE(total_neto, total) AS total_neto, COALESCE(total_iva, 0) AS total_iva,
           COALESCE(tipo_factura, 'ZZ') AS tipo_factura,
           COALESCE(total_real,
             CASE WHEN COALESCE(tipo_factura, 'ZZ') = 'FC' THEN COALESCE(total_neto, total) ELSE total END
           ) AS total_real$q$,
$q$    -- cargo_4 (cargo de envio): `total` (con el envio) queda para la cobranza
    -- (cobr_ped); la venta es de productos (venta_prod) y el neto/IVA van sin el
    -- desglose del envio efectivo, que cargo_1_base suma a total_neto/total_iva
    -- (posicion_fiscal si lo declara). Con cargo_envio = 0 da lo mismo que antes.
    SELECT id, cliente_id, usuario_id, total, monto_pagado, fecha, forma_pago, estado_pago,
           GREATEST(total - cargo_envio, 0) AS venta_prod,
           COALESCE(total_neto - CASE WHEN cargo_envio > 0
                                      THEN (public.cargo_envio_desglose(total - GREATEST(total - cargo_envio, 0), tipo_factura)).neto
                                      ELSE 0 END,
                    GREATEST(total - cargo_envio, 0)) AS total_neto,
           COALESCE(total_iva - CASE WHEN cargo_envio > 0
                                     THEN (public.cargo_envio_desglose(total - GREATEST(total - cargo_envio, 0), tipo_factura)).iva
                                     ELSE 0 END, 0) AS total_iva,
           COALESCE(tipo_factura, 'ZZ') AS tipo_factura,
           COALESCE(total_real,
             CASE WHEN COALESCE(tipo_factura, 'ZZ') = 'FC'
                  THEN COALESCE(total_neto - CASE WHEN cargo_envio > 0
                                                  THEN (public.cargo_envio_desglose(total - GREATEST(total - cargo_envio, 0), tipo_factura)).neto
                                                  ELSE 0 END,
                                GREATEST(total - cargo_envio, 0))
                  ELSE GREATEST(total - cargo_envio, 0) END
           ) AS total_real$q$,
    'reporte_gerencial: ped');

  -- La base de comision (k_nc y vendedores[].base_nc) es de productos.
  v_def := pg_temp.cargo4_parchar(v_def,
$q$    SELECT usuario_id, total FROM pedidos
    WHERE estado='entregado' AND canal <> 'cambio'$q$,
$q$    -- cargo_4: la base de comision es de productos.
    SELECT usuario_id, GREATEST(total - cargo_envio, 0) AS total FROM pedidos
    WHERE estado='entregado' AND canal <> 'cambio'$q$,
    'reporte_gerencial: nc');

  v_def := pg_temp.cargo4_parchar(v_def,
$q$  k_ped AS (SELECT COUNT(*) AS pedidos, COALESCE(SUM(total),0) AS venta,
            COUNT(DISTINCT cliente_id) AS clientes, COALESCE(ROUND(AVG(total)),0) AS ticket,$q$,
$q$  k_ped AS (SELECT COUNT(*) AS pedidos, COALESCE(SUM(venta_prod),0) AS venta, -- cargo_4
            COUNT(DISTINCT cliente_id) AS clientes, COALESCE(ROUND(AVG(venta_prod)),0) AS ticket,$q$,
    'reporte_gerencial: k_ped venta y ticket');

  v_def := pg_temp.cargo4_parchar(v_def,
$q$COALESCE(SUM(total) FILTER (WHERE tipo_factura='FC'),0) AS fc_venta,$q$,
$q$COALESCE(SUM(venta_prod) FILTER (WHERE tipo_factura='FC'),0) AS fc_venta,$q$,
    'reporte_gerencial: k_ped fc_venta');

  v_def := pg_temp.cargo4_parchar(v_def,
$q$COALESCE(SUM(total) FILTER (WHERE tipo_factura='ZZ'),0) AS zz_venta,$q$,
$q$COALESCE(SUM(venta_prod) FILTER (WHERE tipo_factura='ZZ'),0) AS zz_venta,$q$,
    'reporte_gerencial: k_ped zz_venta');

  v_def := pg_temp.cargo4_parchar(v_def,
$q$  m_ped AS (SELECT to_char(fecha,'YYYY-MM') AS mes, COUNT(*) AS pedidos, SUM(total) AS venta,$q$,
$q$  m_ped AS (SELECT to_char(fecha,'YYYY-MM') AS mes, COUNT(*) AS pedidos, SUM(venta_prod) AS venta, -- cargo_4$q$,
    'reporte_gerencial: m_ped venta');

  v_def := pg_temp.cargo4_parchar(v_def,
$q$COUNT(DISTINCT cliente_id) AS clientes, ROUND(AVG(total)) AS ticket FROM ped GROUP BY 1),$q$,
$q$COUNT(DISTINCT cliente_id) AS clientes, ROUND(AVG(venta_prod)) AS ticket FROM ped GROUP BY 1),$q$,
    'reporte_gerencial: m_ped ticket');

  v_def := pg_temp.cargo4_parchar(v_def,
$q$COUNT(DISTINCT p.id) AS pedidos, SUM(p.total) AS venta$q$,
$q$COUNT(DISTINCT p.id) AS pedidos, SUM(p.venta_prod) AS venta -- cargo_4$q$,
    'reporte_gerencial: top_cli');

  v_def := pg_temp.cargo4_parchar(v_def,
$q$serie AS (SELECT to_char(fecha,'DD/MM') AS dia, SUM(total) AS venta FROM ped$q$,
$q$serie AS (SELECT to_char(fecha,'DD/MM') AS dia, SUM(venta_prod) AS venta FROM ped$q$,
    'reporte_gerencial: serie');

  EXECUTE v_def;
END
$patch$;

-- 1b · reporte_ventas_por_cliente
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.reporte_ventas_por_cliente(date,date,uuid,bigint)'::regprocedure);
BEGIN
  v_def := pg_temp.cargo4_parchar(v_def,
$q$    SELECT pe.id, pe.cliente_id, pe.total, pe.fecha, pe.usuario_id
    FROM pedidos pe$q$,
$q$    -- cargo_4: la venta es de productos (el envio no es compra del cliente).
    SELECT pe.id, pe.cliente_id, GREATEST(pe.total - pe.cargo_envio, 0) AS total, pe.fecha, pe.usuario_id
    FROM pedidos pe$q$,
    'reporte_ventas_por_cliente: ventana');
  EXECUTE v_def;
END
$patch$;

-- 1c · reporte_ventas_por_preventista: solo totalVentas
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.reporte_ventas_por_preventista(date,date,bigint)'::regprocedure);
BEGIN
  v_def := pg_temp.cargo4_parchar(v_def,
$q$    SELECT p.usuario_id, p.total, p.estado,$q$,
$q$    -- cargo_4: totalVentas es de productos; pagado y pendiente siguen con total.
    SELECT p.usuario_id, p.total, p.estado,
           GREATEST(p.total - p.cargo_envio, 0) AS venta_prod,$q$,
    'reporte_ventas_por_preventista: ped');
  v_def := pg_temp.cargo4_parchar_re(v_def,
$q$SUM\(ped\.total\)(\s+AS total_ventas,)$q$,
$q$SUM(ped.venta_prod)\1$q$,
    'reporte_ventas_por_preventista: total_ventas');
  EXECUTE v_def;
END
$patch$;

-- 1d · bot_mis_ventas
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.bot_mis_ventas(uuid,date,date,bigint,integer)'::regprocedure);
BEGIN
  v_def := pg_temp.cargo4_parchar(v_def,
$q$    SELECT p.id, p.cliente_id, p.total
    FROM pedidos p$q$,
$q$    -- cargo_4: la venta es de productos.
    SELECT p.id, p.cliente_id, GREATEST(p.total - p.cargo_envio, 0) AS total
    FROM pedidos p$q$,
    'bot_mis_ventas: ventas_filtradas');
  EXECUTE v_def;
END
$patch$;

-- 1e · bot_ventas_periodo
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.bot_ventas_periodo(date,date,bigint,integer)'::regprocedure);
BEGIN
  v_def := pg_temp.cargo4_parchar(v_def,
$q$    SELECT id, cliente_id, total, fecha
    FROM pedidos$q$,
$q$    -- cargo_4: la venta (y la venta en curso) es de productos.
    SELECT id, cliente_id, GREATEST(total - cargo_envio, 0) AS total, fecha
    FROM pedidos$q$,
    'bot_ventas_periodo: ventas_filtradas');
  v_def := pg_temp.cargo4_parchar(v_def,
$q$    SELECT COALESCE(SUM(total), 0) AS monto, COUNT(*) AS pedidos$q$,
$q$    SELECT COALESCE(SUM(GREATEST(total - cargo_envio, 0)), 0) AS monto, COUNT(*) AS pedidos$q$,
    'bot_ventas_periodo: en_curso');
  EXECUTE v_def;
END
$patch$;

-- 1f · bot_digest_preventista: lo tomado ayer (el mes sale de bot_mis_ventas)
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.bot_digest_preventista(uuid,bigint,date)'::regprocedure);
BEGIN
  v_def := pg_temp.cargo4_parchar(v_def,
$q$  SELECT json_build_object('pedidos', COUNT(*), 'total', COALESCE(SUM(total), 0))$q$,
$q$  -- cargo_4: lo tomado es de productos.
  SELECT json_build_object('pedidos', COUNT(*), 'total', COALESCE(SUM(GREATEST(total - cargo_envio, 0)), 0))$q$,
    'bot_digest_preventista: tomados');
  EXECUTE v_def;
END
$patch$;

-- 1g · bot_metricas_admin_dia: venta, ticket, promedio y entregado; los
-- pendientes de entrega y de pago siguen con total.
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.bot_metricas_admin_dia(date,bigint)'::regprocedure);
BEGIN
  v_def := pg_temp.cargo4_parchar(v_def,
$q$    SELECT id, total, cliente_id, sucursal_id
    FROM pedidos$q$,
$q$    -- cargo_4: venta, ticket y top de clientes de productos; pendientes de
    -- entrega, de pago y la deuda siguen con total (plata a cobrar).
    SELECT id, GREATEST(total - cargo_envio, 0) AS total, cliente_id, sucursal_id
    FROM pedidos$q$,
    'bot_metricas_admin_dia: pedidos_dia');
  v_def := pg_temp.cargo4_parchar(v_def,
$q$  pedidos_7d AS (
    SELECT total
    FROM pedidos$q$,
$q$  pedidos_7d AS (
    SELECT GREATEST(total - cargo_envio, 0) AS total
    FROM pedidos$q$,
    'bot_metricas_admin_dia: pedidos_7d');
  v_def := pg_temp.cargo4_parchar_re(v_def,
$q$COALESCE\(SUM\(total\), 0\)::numeric\(14,2\)(\s+AS total\s+FROM pedidos\s+WHERE fecha = p_fecha\s+AND estado = 'entregado')$q$,
$q$COALESCE(SUM(GREATEST(total - cargo_envio, 0)), 0)::numeric(14,2)\1$q$,
    'bot_metricas_admin_dia: entregado_dia');
  EXECUTE v_def;
END
$patch$;

-- 1h · clientes_ritmo_compra: monto_mensual (el saldo sigue siendo el saldo)
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.clientes_ritmo_compra(bigint,text,uuid,uuid,bigint)'::regprocedure);
BEGIN
  v_def := pg_temp.cargo4_parchar(v_def,
$q$    SELECT pe.cliente_id, pe.fecha, pe.total, pe.usuario_id$q$,
$q$    -- cargo_4: el monto mensual es de productos.
    SELECT pe.cliente_id, pe.fecha, GREATEST(pe.total - pe.cargo_envio, 0) AS total, pe.usuario_id$q$,
    'clientes_ritmo_compra: ventas');
  EXECUTE v_def;
END
$patch$;

-- 1i · reporte_alerta_detalle: clientes inactivos (la cobranza vencida sigue con total)
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.reporte_alerta_detalle(bigint,text,date,date,boolean)'::regprocedure);
BEGIN
  v_def := pg_temp.cargo4_parchar(v_def,
$q$COALESCE(SUM(p.total) FILTER (WHERE p.fecha >= CURRENT_DATE - 90), 0) AS valor,$q$,
$q$COALESCE(SUM(GREATEST(p.total - p.cargo_envio, 0)) FILTER (WHERE p.fecha >= CURRENT_DATE - 90), 0) AS valor, -- cargo_4: venta de productos$q$,
    'reporte_alerta_detalle: clientes_inactivos');
  EXECUTE v_def;
END
$patch$;

-- 1j · jornadas_preventista: el monto entregado y el pendiente
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.jornadas_preventista(date,date,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.cargo4_parchar_re(v_def,
$q$ELSE p\.total(\s+END AS monto)$q$,
$q$ELSE GREATEST(p.total - p.cargo_envio, 0) -- cargo_4: venta de productos\1$q$,
    'jornadas_preventista: monto');
  v_def := pg_temp.cargo4_parchar_re(v_def,
$q$('monto',\s+)COALESCE\(SUM\(p\.total\), 0\)$q$,
$q$\1COALESCE(SUM(GREATEST(p.total - p.cargo_envio, 0)), 0)$q$,
    'jornadas_preventista: pendientes');
  EXECUTE v_def;
END
$patch$;

-- 1k · jornada_preventista_detalle: el monto del pedido entregado
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.jornada_preventista_detalle(date,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.cargo4_parchar(v_def,
$q$ELSE f.total END,$q$,
$q$ELSE GREATEST(f.total - f.cargo_envio, 0) END, -- cargo_4: venta de productos$q$,
    'jornada_preventista_detalle: monto');
  EXECUTE v_def;
END
$patch$;

-- ---------------------------------------------------------------------------
-- 2 · Verificacion
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  v_f   record;
  v_def text;
BEGIN
  FOR v_f IN
    SELECT a.*, p.proacl::text AS acl_ahora, p.prosecdef AS secdef_ahora, p.proconfig::text AS config_ahora
      FROM _cargo4_acl a JOIN pg_proc p ON p.oid = a.oid
  LOOP
    v_def := pg_get_functiondef(v_f.oid);
    -- Cada cuerpo quedo con su parche.
    IF v_def NOT LIKE '%cargo_4%' THEN
      RAISE EXCEPTION 'cargo_4: % no quedo parcheada', v_f.proname;
    END IF;
    -- Mismo dueno de permisos, SECURITY DEFINER y search_path que antes.
    IF v_f.acl_ahora IS DISTINCT FROM v_f.acl OR v_f.secdef_ahora IS DISTINCT FROM v_f.prosecdef
       OR v_f.config_ahora IS DISTINCT FROM v_f.config THEN
      RAISE EXCEPTION 'cargo_4: % cambio de ACL/SECURITY/search_path (antes % %, ahora % %)',
        v_f.proname, v_f.acl, v_f.config, v_f.acl_ahora, v_f.config_ahora;
    END IF;
  END LOOP;
  -- Las 11 siguen siendo 11 (ninguna sobrecarga nueva).
  IF (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
         AND p.proname IN (SELECT proname FROM _cargo4_acl)) <> 11 THEN
    RAISE EXCEPTION 'cargo_4: aparecio una sobrecarga de alguna funcion parcheada';
  END IF;

  -- En el gerencial no queda ninguna suma de venta sobre total.
  v_def := pg_get_functiondef('public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure);
  IF v_def ~ 'SUM\(total\) AS venta' OR v_def ~ 'AVG\(total\)' OR v_def ~ 'SUM\(p\.total\) AS venta'
     OR v_def ~ 'SUM\(total\) FILTER \(WHERE tipo_factura' THEN
    RAISE EXCEPTION 'cargo_4: reporte_gerencial todavia suma total como venta';
  END IF;
  -- Y la cobranza sigue con total.
  IF v_def NOT LIKE '%LEAST(COALESCE(p.monto_pagado,0), p.total) AS cubierto%' THEN
    RAISE EXCEPTION 'cargo_4: la cobranza del gerencial dejo de usar total';
  END IF;
END
$verif$;

-- ROLLBACK: volver a aplicar las definiciones anteriores de las 11 funciones
-- (pg_get_functiondef de prod antes de esta migracion; los parches son
-- reversibles reemplazando cada texto nuevo por su ancla). Sin cambios de
-- datos ni de esquema.
