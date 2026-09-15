-- ============================================================================
-- 249 · El trigger de mermas llama a la cascada única
-- ============================================================================
-- Decisión del dueño (#628). La 238 dejó `mermas_stock_snapshot_costo` afuera
-- a propósito ("repite la cascada una cuarta vez... va por issue aparte"): el
-- trigger seguía con su propia copia,
--
--     COALESCE(costo_promedio, costo_real,
--              round(costo_sin_iva * (1 + COALESCE(impuestos_internos,0)/100), 4))
--
-- sin el `NULLIF(costo_sin_iva, 0)` que sí tiene `costo_valuacion()` desde la
-- 238 (#511). La diferencia es exactamente un producto sin `costo_promedio` ni
-- `costo_real` y con `costo_sin_iva = 0`: la cascada del trigger evaluaba
-- `round(0 * (1+ii/100), 4) = 0` y congelaba un costo de **0** como si fuera un
-- dato real, en vez de NULL como "sin_costo". Un cero congelado en
-- `mermas_stock.costo_unitario` es indistinguible de un producto que de verdad
-- cuesta cero: la señal "todavía no se cargó el costo" se perdía justo al
-- escribir la merma, que es el único momento en que se puede capturar --
-- después, `costo_valuacion(costo_unitario, ...)` ve el 0 como snapshot válido
-- y ya no vuelve a mirar las otras patas.
--
-- LO QUE CAMBIA
-- -------------
-- El trigger deja de tener cascada propia y llama a la única que hay:
-- `public.costo_valuacion(NULL, costo_promedio, costo_real, costo_sin_iva,
-- impuestos_internos)`. El primer argumento es `NULL` a propósito: el trigger
-- sólo entra cuando `NEW.costo_unitario IS NULL` (nadie mandó un snapshot
-- propio desde afuera), así que no hay "congelado" que pasarle -- el snapshot
-- que se está por escribir es justamente el resultado de esta llamada.
--
-- El `round(..., 4)` se queda en el trigger, no se mueve a la función pura:
-- `costo_valuacion()` no redondea (la usan `mermas_valorizadas` y
-- `compra_items` sin redondear, mig 238) y este es el único de sus llamadores
-- que sí necesita 4 decimales fijos, porque es el que ESCRIBE el snapshot que
-- después se lee tal cual. Redondear adentro de la función pura le movería el
-- número a los demás llamadores.
--
-- POR QUÉ NO SE MUEVE NINGÚN NÚMERO YA ESCRITO
-- ---------------------------------------------
-- Sólo se reemplaza el CUERPO de un trigger BEFORE INSERT: ninguna fila
-- existente de `mermas_stock` se toca, y el criterio de merma
-- (`mermas_valorizadas`, mig 238) sigue leyendo `m.costo_unitario` tal como
-- quedó escrito en su momento. Medido contra prod el 2026-09-15, del 2026-09-01
-- al 2026-09-15 (red completa):
--
--     reporte_gerencial(...).kpis.mermas   = 23862.2499
--     reporte_mermas(...).totales.costo    = 23862.2499
--
-- y la invariante `totales.costo == kpis.mermas` (238, #570) sigue cerrando
-- por construcción después de este archivo, porque ninguno de los dos lee otra
-- cosa que no sea la columna ya escrita.
--
-- Lo que sí cambia es el PRÓXIMO insert: una merma futura sobre un producto sin
-- `costo_promedio`/`costo_real` y con `costo_sin_iva = 0` va a congelar NULL en
-- vez de 0, y esa fila SÍ va a contar para `origen_costo = 'sin_costo'` en
-- `mermas_valorizadas` -- que es exactamente la señal que #628 pide recuperar.
--
-- Cierra #628.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.mermas_stock_snapshot_costo()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_costo_promedio     numeric;
  v_costo_real         numeric;
  v_costo_sin_iva      numeric;
  v_impuestos_internos numeric;
BEGIN
  IF NEW.costo_unitario IS NULL THEN
    SELECT costo_promedio, costo_real, costo_sin_iva, impuestos_internos
      INTO v_costo_promedio, v_costo_real, v_costo_sin_iva, v_impuestos_internos
      FROM productos
     WHERE id = NEW.producto_id AND sucursal_id = NEW.sucursal_id;

    -- mig 249 (#628) · LA cascada (238), no una copia propia. NULL de primer
    -- argumento porque acá no hay ningun snapshot previo que pasarle: este
    -- round() ES el snapshot que se esta por congelar. El redondeo a 4
    -- decimales se queda en el trigger -- costo_valuacion() no redondea.
    NEW.costo_unitario := round(
      public.costo_valuacion(NULL, v_costo_promedio, v_costo_real,
                             v_costo_sin_iva, v_impuestos_internos), 4);
  END IF;
  RETURN NEW;
END;
$function$;

COMMENT ON COLUMN public.mermas_stock.costo_unitario IS
  'Costo por unidad congelado al registrar la merma, vía public.costo_valuacion() '
  '(mig 249): snapshot (N/A acá) > costo_promedio > costo_real > costo_sin_iva*(1+ii/100), '
  'con NULLIF(costo_sin_iva,0). NULL = sin ninguna pata de costo cargada al momento de '
  'la merma (sin_costo, mig 238/#511) o fila previa a mig 119 → el reporte cae al costo vivo.';

-- ---------------------------------------------------------------------------
-- El ensayo. Si algo de esto no da, la migración entera se cae.
-- ---------------------------------------------------------------------------
DO $ensayo$
DECLARE
  v_def        text;
  v_ger_desp   numeric;
  v_mer_desp   numeric;
  v_costo      numeric;
BEGIN
  -- 1 · El cuerpo vivo llama a costo_valuacion() y no le quedó la fórmula vieja.
  v_def := pg_get_functiondef('public.mermas_stock_snapshot_costo()'::regprocedure);
  IF v_def NOT LIKE '%public.costo_valuacion(%' THEN
    RAISE EXCEPTION 'mig249 · el trigger no llama a costo_valuacion()';
  END IF;
  IF v_def LIKE '%costo_sin_iva * (1 + COALESCE(impuestos_internos%' THEN
    RAISE EXCEPTION 'mig249 · el trigger todavia tiene la cascada vieja adentro';
  END IF;

  -- 2 · El caso del issue: las tres patas NULL y costo_sin_iva = 0 → NULL, no 0.
  --     Se prueba SIN tocar productos ni mermas_stock reales: una tabla
  --     temporal "productos" (pg_temp se busca antes que public.productos, aun
  --     con SET search_path='public' en la función) y otra "mermas_stock" con
  --     el mismo trigger enganchado. Se borran a mano mas abajo, ANTES de
  --     llamar a reporte_gerencial/reporte_mermas/auditoria_integridad --si
  --     siguieran vivas les taparian las tablas reales--; el ON COMMIT DROP
  --     queda solo como red por si una excepcion corta el bloque antes.
  CREATE TEMP TABLE productos (
    id                   bigint PRIMARY KEY,
    sucursal_id          bigint NOT NULL,
    costo_promedio       numeric,
    costo_real           numeric,
    costo_sin_iva        numeric,
    impuestos_internos   numeric
  ) ON COMMIT DROP;
  INSERT INTO productos (id, sucursal_id, costo_promedio, costo_real, costo_sin_iva, impuestos_internos)
  VALUES (-1, -1, NULL, NULL, 0, 10);

  CREATE TEMP TABLE mermas_stock (
    producto_id    bigint,
    sucursal_id    bigint,
    costo_unitario numeric
  ) ON COMMIT DROP;
  CREATE TRIGGER trg_mig249_ensayo
    BEFORE INSERT ON mermas_stock
    FOR EACH ROW EXECUTE FUNCTION public.mermas_stock_snapshot_costo();

  INSERT INTO mermas_stock (producto_id, sucursal_id) VALUES (-1, -1)
  RETURNING costo_unitario INTO v_costo;

  IF v_costo IS NOT NULL THEN
    RAISE EXCEPTION 'mig249 · costo_sin_iva=0 sin otra pata deberia congelar NULL, dio %', v_costo;
  END IF;

  -- Un producto con costo_promedio cargado sigue congelando ese valor (no se
  -- rompe el camino feliz).
  UPDATE productos SET costo_promedio = 15.5 WHERE id = -1;
  INSERT INTO mermas_stock (producto_id, sucursal_id) VALUES (-1, -1)
  RETURNING costo_unitario INTO v_costo;
  IF v_costo IS DISTINCT FROM 15.5 THEN
    RAISE EXCEPTION 'mig249 · con costo_promedio=15.5 se esperaba congelar 15.5, dio %', v_costo;
  END IF;

  -- Las dos temporales se borran ACA, antes de tocar reporte_gerencial /
  -- reporte_mermas / auditoria_integridad: pg_temp se busca antes que
  -- `public` sin importar el search_path de esas funciones, asi que si
  -- siguieran vivas les taparian las tablas reales por el resto de esta
  -- transaccion.
  DROP TABLE mermas_stock;
  DROP TABLE productos;

  -- 3 · La invariante de la 238 (totales.costo == kpis.mermas) sigue cerrando
  --     sobre datos reales. No se compara contra un numero congelado de
  --     antemano -- prod sigue viva y puede sumar mermas nuevas entre que se
  --     midio a mano y que esto corre -- se verifica la igualdad, que es la
  --     que no puede depender del momento porque las dos funciones leen la
  --     MISMA columna ya escrita (mermas_valorizadas, mig 238). Medido a mano
  --     contra prod el 2026-09-15 (ver cabecera): 23862.2499 en las dos.
  SELECT (public.reporte_gerencial(NULL, '2026-09-01'::date, '2026-09-15'::date, true, false)->'kpis'->>'mermas')::numeric,
         (public.reporte_mermas('2026-09-01'::date, '2026-09-15'::date, NULL, NULL, 50)->'totales'->>'costo')::numeric
    INTO v_ger_desp, v_mer_desp;

  IF v_ger_desp IS DISTINCT FROM v_mer_desp THEN
    RAISE EXCEPTION 'mig249 · la invariante totales.costo == kpis.mermas se rompio: % <> %',
      v_mer_desp, v_ger_desp;
  END IF;

  -- 4 · Integridad en verde.
  IF (public.auditoria_integridad()->>'overall_ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'mig249 · auditoria_integridad quedo en rojo: %', public.auditoria_integridad()->'checks';
  END IF;

  RAISE NOTICE 'mig249 · ensayo OK · sin_costo=NULL, camino feliz=15.5, ledger sin moverse (%), integridad verde',
    v_ger_desp;
END
$ensayo$;

COMMIT;
