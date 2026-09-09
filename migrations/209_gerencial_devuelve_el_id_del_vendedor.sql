-- reporte_gerencial devuelve el id del vendedor
--
-- EL PROBLEMA
-- -----------
-- `reporte_gerencial.vendedores[]` traia nombre, rol, pedidos, venta,
-- venta_real, margen_comercial, margen_real, bonif y base_nc -- pero NO el id
-- del perfil. Cuando el PR #528 tuvo que mostrar la comision real por vendedor
-- (que sale de `calcular_comisiones`, que si devuelve el id), el unico cruce
-- posible fue POR NOMBRE.
--
-- Hoy no hay nombres repetidos en `perfiles`, pero nada lo impide: el dia que
-- haya dos homonimos comparten la celda de comision y nadie se entera. Un cruce
-- por nombre entre dos fuentes es una bomba de tiempo silenciosa, del mismo
-- tipo que las que se vinieron cerrando en las migs 207 y 208.
--
-- EL CAMBIO ES UNA COLUMNA
-- ------------------------
-- La CTE `vendedores` pasa de:
--
--   vendedores AS (SELECT pf.nombre, pf.rol, ...
--                          ^^^^^^^^^
-- a:
--
--   vendedores AS (SELECT pf.id, pf.nombre, pf.rol, ...
--                         ^^^^^^
--
-- El JSON se arma con `to_jsonb(v)` sobre esa CTE, asi que la clave `id` sale
-- sola. Es ADITIVO: ningun consumidor existente se rompe.
--
-- POR QUE ESTA MIGRACION ES UN PARCHE Y NO EL CUERPO COMPLETO
-- ----------------------------------------------------------
-- `reporte_gerencial` son 19.264 caracteres. El precedente del repo (mig 123)
-- pega el body entero, y es lo correcto cuando el cambio es grande. Aca cambia
-- UNA columna: un diff de 19.000 lineas donde cambio una esconde el cambio en
-- vez de mostrarlo, y transcribir a mano el cuerpo de la funcion que calcula
-- todo el dashboard es un riesgo peor que el que se viene a evitar.
--
-- Por eso el parche se aplica sobre el body VIVO (pg_get_functiondef) y se
-- AUTOVERIFICA: si el ancla no aparece exactamente una vez, ABORTA. No hay
-- forma de que "parezca" que funciono sin haber funcionado.
--
-- Si esta migracion falla al reaplicarse es porque la CTE `vendedores` cambio
-- de forma: hay que mirar el body actual y ajustar el ancla, no relajar la
-- guarda.
--
-- MISMA FIRMA. Es CREATE OR REPLACE (adentro del EXECUTE) sobre
-- reporte_gerencial(bigint, date, date, boolean, boolean), la unica que existe.
-- No se crea una sobrecarga: dos con rangos [obligatorios, total] superpuestos
-- darian PGRST203 en runtime (trampa 5 de CLAUDE.md).
--
-- Los permisos NO se tocan: CREATE OR REPLACE preserva los ACL. Verificado
-- despues de aplicar: authenticated=X, anon afuera.

BEGIN;

DO $patch$
DECLARE
  v_src   text;
  v_viejo text := 'vendedores AS (SELECT pf.nombre, pf.rol,';
  v_nuevo text := 'vendedores AS (SELECT pf.id, pf.nombre, pf.rol,';
  v_ocurr int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'reporte_gerencial';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'No existe public.reporte_gerencial: aplica primero la mig 130';
  END IF;

  -- Ya parcheada (reaplicacion): no hay nada que hacer.
  IF position(v_nuevo in v_src) > 0 THEN
    RAISE NOTICE 'reporte_gerencial ya devuelve el id del vendedor, no se toca';
    RETURN;
  END IF;

  v_ocurr := (length(v_src) - length(replace(v_src, v_viejo, ''))) / length(v_viejo);
  IF v_ocurr <> 1 THEN
    RAISE EXCEPTION
      'Se esperaba 1 ocurrencia del ancla de la CTE vendedores y hay %. '
      'La CTE cambio de forma: revisa el body actual con pg_get_functiondef.', v_ocurr;
  END IF;

  EXECUTE replace(v_src, v_viejo, v_nuevo);
END
$patch$;

-- Verificacion: la clave tiene que estar en el JSON, no alcanza con que el
-- EXECUTE no haya tirado.
DO $verif$
DECLARE
  v_tiene boolean;
BEGIN
  SELECT position('vendedores AS (SELECT pf.id, pf.nombre' in pg_get_functiondef(p.oid)) > 0
    INTO v_tiene
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'reporte_gerencial';

  IF NOT v_tiene THEN
    RAISE EXCEPTION 'El parche no quedo aplicado en reporte_gerencial';
  END IF;
END
$verif$;

COMMIT;

-- ROLLBACK (si hiciera falta): el mismo parche al reves.
--   DO $$
--   DECLARE v_src text;
--   BEGIN
--     SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p
--     JOIN pg_namespace n ON n.oid=p.pronamespace
--     WHERE n.nspname='public' AND p.proname='reporte_gerencial';
--     EXECUTE replace(v_src, 'vendedores AS (SELECT pf.id, pf.nombre',
--                            'vendedores AS (SELECT pf.nombre');
--   END $$;
-- El front vuelve a cruzar por nombre revirtiendo el commit; la clave `id` de
-- mas no rompe a nadie mientras tanto.
