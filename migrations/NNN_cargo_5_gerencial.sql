-- NNN · Cargo de envio: metricas de envio en el reporte gerencial (lo que falta
-- del cargo de envio sobre la 389, #1220, spec §2).
--
-- Diseno: docs/superpowers/specs/2026-10-26-cargo-envio-faltantes-design.md.
-- Quinta migracion del plan; requiere cargo_1_base (pedidos.cargo_envio_estado)
-- y cargo_4_reportes (la venta del gerencial es de productos: `ped.venta_prod`).
-- Parchea reporte_gerencial ENCIMA de la version que deja cargo_4.
--
-- reporte_gerencial suma una clave de primer nivel:
--   envios = { recaudado, cobrados, gratis, bonificados, pct_cobrado,
--              venta_productos, venta_total }
-- sobre los pedidos que cuentan como venta (`ped`: mismo estado, canal, VB,
-- fecha y sucursal que kpis.venta) CON productos (venta_prod > 0):
--   recaudado       = SUM(cargo efectivo) = SUM(total - GREATEST(total - cargo_envio, 0))
--   cobrados        = cargo_envio_estado = 'cobrado' con cargo efectivo > 0
--   gratis          = cargo_envio_estado = 'gratis'
--   bonificados     = cargo_envio_estado = 'bonificado'
--   pct_cobrado     = cobrados / NULLIF(cobrados + gratis + bonificados, 0)  (0..1)
--   venta_productos = SUM(venta_prod)  (== kpis.venta)
--   venta_total     = venta_productos + recaudado
-- Sin ningun pedido cobrado|gratis|bonificado en el periodo, envios = null:
-- una sucursal que no cobra envio no ve la palabra (spec, anti-objetivos). El
-- rechazo total (venta_prod = 0) no cuenta: no hubo venta ni envio cobrado.
--
-- Compatibilidad: la firma no cambia; la respuesta gana una clave que el front
-- de produccion ignora. kpis, mensual, comparativo, cobranza y alertas no se
-- tocan (envios no va en kpis, asi que tampoco aparece en el comparativo).
--
-- Se PARCHEA por ancla sobre la definicion viva (molde de cargo_4): cada ancla
-- aparece exactamente una vez, o la migracion se cae. CREATE OR REPLACE conserva
-- dueno, SECURITY DEFINER, search_path y ACL; el bloque final lo verifica.
--
-- Ensayo: scripts/test-cargo-5.sql (parte 1 antes de esta migracion, parte 2
-- despues; ver su encabezado).

SET LOCAL lock_timeout = '5s';

-- ---------------------------------------------------------------------------
-- 0 · Premisas
-- ---------------------------------------------------------------------------
DO $premisas$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public' AND table_name = 'pedidos'
                    AND column_name = 'cargo_envio_estado') THEN
    RAISE EXCEPTION 'cargo_5: falta pedidos.cargo_envio_estado (aplicar antes cargo_1_base)';
  END IF;
  IF pg_get_functiondef('public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure)
       NOT LIKE '%venta_prod%' THEN
    RAISE EXCEPTION 'cargo_5: reporte_gerencial no tiene venta_prod (aplicar antes cargo_4_reportes)';
  END IF;
END
$premisas$;

DROP TABLE IF EXISTS pg_temp._cargo5_acl;
CREATE TEMP TABLE _cargo5_acl AS
SELECT p.oid, p.proacl::text AS acl, p.prosecdef, p.proconfig::text AS config
  FROM pg_proc p
 WHERE p.oid = 'public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure;

-- ---------------------------------------------------------------------------
-- 1 · Parches por ancla sobre la definicion viva
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.cargo5_parchar(p_def text, p_viejo text, p_nuevo text, p_que text)
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

DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure);
BEGIN
  -- `ped` lleva el estado del cargo y el cargo efectivo.
  v_def := pg_temp.cargo5_parchar(v_def,
$q$           GREATEST(total - cargo_envio, 0) AS venta_prod,$q$,
$q$           GREATEST(total - cargo_envio, 0) AS venta_prod,
           -- cargo_5: estado del cargo y cargo efectivo, para el bloque envios.
           cargo_envio_estado, total - GREATEST(total - cargo_envio, 0) AS cargo_efectivo,$q$,
    'reporte_gerencial: ped');

  -- El bloque envios, sobre los pedidos de `ped` con productos.
  v_def := pg_temp.cargo5_parchar(v_def,
$q$  serie AS (SELECT to_char(fecha,'DD/MM') AS dia, SUM(venta_prod) AS venta FROM ped$q$,
$q$  -- cargo_5: metricas de envio sobre la venta con productos (el rechazo total,
  -- venta_prod = 0, no cuenta). venta_total = venta_productos + recaudado.
  k_env AS (SELECT COALESCE(SUM(cargo_efectivo),0) AS recaudado,
      COUNT(*) FILTER (WHERE cargo_envio_estado = 'cobrado' AND cargo_efectivo > 0) AS cobrados,
      COUNT(*) FILTER (WHERE cargo_envio_estado = 'gratis') AS gratis,
      COUNT(*) FILTER (WHERE cargo_envio_estado = 'bonificado') AS bonificados,
      COALESCE(SUM(venta_prod),0) AS venta_productos
    FROM ped WHERE venta_prod > 0),
  serie AS (SELECT to_char(fecha,'DD/MM') AS dia, SUM(venta_prod) AS venta FROM ped$q$,
    'reporte_gerencial: k_env');

  v_def := pg_temp.cargo5_parchar(v_def,
$q$    'serie_diaria', (SELECT COALESCE(jsonb_agg(jsonb_build_array(s.dia, s.venta)),'[]') FROM serie s),$q$,
$q$    'serie_diaria', (SELECT COALESCE(jsonb_agg(jsonb_build_array(s.dia, s.venta)),'[]') FROM serie s),
    -- cargo_5: null si en el periodo ningun pedido con productos fue cobrado,
    -- gratis o bonificado (la sucursal no cobra envio: el front no lo muestra).
    'envios', (SELECT CASE WHEN e.cobrados + e.gratis + e.bonificados = 0 THEN NULL
        ELSE jsonb_build_object('recaudado', e.recaudado, 'cobrados', e.cobrados,
          'gratis', e.gratis, 'bonificados', e.bonificados,
          'pct_cobrado', round(e.cobrados::numeric / NULLIF(e.cobrados + e.gratis + e.bonificados, 0), 4),
          'venta_productos', e.venta_productos,
          'venta_total', e.venta_productos + e.recaudado) END
      FROM k_env e),$q$,
    'reporte_gerencial: envios');

  EXECUTE v_def;
END
$patch$;

-- ---------------------------------------------------------------------------
-- 2 · Verificacion
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  v_f   record;
  v_def text := pg_get_functiondef('public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure);
  v_r   jsonb;
BEGIN
  IF v_def NOT LIKE '%cargo_5%' OR v_def NOT LIKE '%cargo_4%' THEN
    RAISE EXCEPTION 'cargo_5: reporte_gerencial perdio un parche (cargo_4 o cargo_5)';
  END IF;
  SELECT a.*, p.proacl::text AS acl_ahora, p.prosecdef AS secdef_ahora, p.proconfig::text AS config_ahora
    INTO v_f FROM _cargo5_acl a JOIN pg_proc p ON p.oid = a.oid;
  IF v_f.acl_ahora IS DISTINCT FROM v_f.acl OR v_f.secdef_ahora IS DISTINCT FROM v_f.prosecdef
     OR v_f.config_ahora IS DISTINCT FROM v_f.config THEN
    RAISE EXCEPTION 'cargo_5: reporte_gerencial cambio de ACL/SECURITY/search_path (antes % %, ahora % %)',
      v_f.acl, v_f.config, v_f.acl_ahora, v_f.config_ahora;
  END IF;
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
         AND proname = 'reporte_gerencial') <> 1 THEN
    RAISE EXCEPTION 'cargo_5: aparecio una sobrecarga de reporte_gerencial';
  END IF;
  -- Las mismas guardas de cargo_4: ninguna suma de venta sobre total.
  IF v_def ~ 'SUM\(total\) AS venta' OR v_def ~ 'AVG\(total\)' OR v_def ~ 'SUM\(p\.total\) AS venta'
     OR v_def ~ 'SUM\(total\) FILTER \(WHERE tipo_factura' THEN
    RAISE EXCEPTION 'cargo_5: reporte_gerencial volvio a sumar total como venta';
  END IF;
  -- La clave existe en la respuesta (aunque sea null).
  v_r := public.reporte_gerencial(NULL, CURRENT_DATE, CURRENT_DATE, false, false);
  IF NOT (v_r ? 'envios') THEN
    RAISE EXCEPTION 'cargo_5: la respuesta de reporte_gerencial no tiene la clave envios';
  END IF;
END
$verif$;

-- ROLLBACK: volver a aplicar la definicion de reporte_gerencial que dejo
-- cargo_4 (los tres parches se revierten reemplazando cada texto nuevo por su
-- ancla). Sin cambios de datos ni de esquema.
