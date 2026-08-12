-- ============================================================================
-- 177 · Condición de IVA por producto y por línea de compra
-- ============================================================================
-- El gerente necesita cargar UNA factura de proveedor que mezcle productos
-- gravados y no gravados, con distintas alícuotas. La mitad ya estaba: desde la
-- mig 113 `compra_items.porcentaje_iva` es un snapshot por línea y los RPCs lo
-- leen del jsonb. Faltaba poder distinguir "no gravado" de "0% gravado" — hoy
-- son indistinguibles — y que la condición viva en la ficha del producto para
-- no re-elegirla en cada factura (la venta ya hereda `productos.porcentaje_iva`,
-- así que un producto exento sale con IVA 0 sin tocar código de venta).
--
-- Decisiones:
--   · `compras.subtotal` NO cambia de semántica: sigue siendo el neto de TODAS
--     las líneas (bruto − bonif). Es lo que valida el check COMPRA-A2 de
--     auditoria_integridad y lo que consume el control blando de cuadre. El
--     neto gravado real queda derivable exacto desde compra_items (ver el
--     COMMENT de la columna).
--   · `compras.no_gravado` (cabecera) no se toca: es para conceptos SIN línea
--     de producto (pallets, envases). No se mezcla con las líneas no gravadas.
--   · DEFAULT 'gravado' backfillea correcto: las 506 líneas históricas de prod
--     (115 FC a 21%, 29 ZZ a 0%, 362 pre-113 en NULL) son todas gravadas.
--   · Ninguna firma de RPC cambia. `condicion_iva` viaja DENTRO del jsonb
--     `p_items`, así que una pestaña vieja del PWA sigue funcionando igual y no
--     se crean sobrecargas ambiguas (ver mig 176 / PGRST203).
--
-- Los cuerpos de las 6 funciones se parchean leyendo el catálogo en vez de
-- hardcodearlos: el cambio es aditivo y así no se revierte en silencio nada que
-- haya entrado fuera de banda. Cada reemplazo exige que su ancla aparezca
-- exactamente una vez; si el cuerpo derivó, la migración falla en vez de
-- aplicar un parche parcial. Cada bloque es idempotente: si la función ya
-- menciona condicion_iva, se saltea.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Columnas
-- ----------------------------------------------------------------------------

ALTER TABLE public.productos
  ADD COLUMN IF NOT EXISTS condicion_iva text NOT NULL DEFAULT 'gravado';

ALTER TABLE public.compra_items
  ADD COLUMN IF NOT EXISTS condicion_iva text NOT NULL DEFAULT 'gravado';

-- Snapshot para el clonado entre sucursales; espeja origen_porcentaje_iva.
-- Nullable a propósito: los movimientos anteriores a esta migración no lo tienen.
ALTER TABLE public.movimiento_sucursal_items
  ADD COLUMN IF NOT EXISTS origen_condicion_iva text;

COMMENT ON COLUMN public.productos.condicion_iva IS
  'Condición frente al IVA: gravado (con alícuota en porcentaje_iva) | exento | no_gravado. La venta la hereda vía porcentaje_iva.';
COMMENT ON COLUMN public.compra_items.condicion_iva IS
  'Condición de la línea (snapshot al registrar). Distingue no gravado de 0% gravado. Neto gravado de una compra = SUM(subtotal) FILTER (WHERE condicion_iva = ''gravado''); IVA por alícuota = SUM(subtotal * porcentaje_iva / 100) GROUP BY porcentaje_iva.';
COMMENT ON COLUMN public.movimiento_sucursal_items.origen_condicion_iva IS
  'Condición de IVA del producto en la sucursal origen (snapshot). NULL = movimiento previo a la mig 177.';

-- OJO (deuda conocida, diferida): posicion_fiscal (mig 121) informa
-- fc_neto = SUM(compras.subtotal), que con facturas mixtas pasa a ser "neto de
-- líneas" y no "neto gravado" estricto. Cuando se haga el libro IVA hay que
-- agregarle un CTE sobre compra_items con las fórmulas del COMMENT de arriba;
-- no requiere backfill porque la clasificación queda desde esta migración.
COMMENT ON COLUMN public.compras.subtotal IS
  'Neto de TODAS las líneas (bruto − bonif), gravadas y no gravadas. Lo valida COMPRA-A2 contra SUM(compra_items.subtotal). El neto gravado se deriva de compra_items.condicion_iva (mig 177).';

-- Coherencia UNIDIRECCIONAL a propósito: no se exige que gravado ⇒ tasa > 0,
-- porque las 29 líneas ZZ de prod son ('gravado', 0) y son legítimas (una
-- compra sin factura no discrimina IVA). La otra dirección sí importa: sin ella
-- un producto ('exento', 21) cobraría IVA en la venta en silencio.
DO $mig$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'compra_items_condicion_iva_check') THEN
    ALTER TABLE public.compra_items
      ADD CONSTRAINT compra_items_condicion_iva_check
        CHECK (condicion_iva IN ('gravado', 'exento', 'no_gravado')),
      ADD CONSTRAINT compra_items_condicion_iva_coherente
        CHECK (condicion_iva = 'gravado' OR COALESCE(porcentaje_iva, 0) = 0);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'productos_condicion_iva_check') THEN
    ALTER TABLE public.productos
      ADD CONSTRAINT productos_condicion_iva_check
        CHECK (condicion_iva IN ('gravado', 'exento', 'no_gravado')),
      ADD CONSTRAINT productos_condicion_iva_coherente
        CHECK (condicion_iva = 'gravado' OR COALESCE(porcentaje_iva, 0) = 0);
  END IF;
END;
$mig$;

-- ----------------------------------------------------------------------------
-- 2. Helper de parcheo: reemplaza exigiendo que el ancla sea única
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._mig177_reemplazo_unico(
  p_texto text, p_ancla text, p_nuevo text, p_donde text
) RETURNS text LANGUAGE plpgsql IMMUTABLE AS $helper$
DECLARE
  v_veces integer;
BEGIN
  v_veces := (length(p_texto) - length(replace(p_texto, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'mig 177 · % : el ancla "%" aparece % veces (se esperaba 1). El cuerpo derivó del texto conocido; revisá el parche antes de aplicar.',
      p_donde, left(p_ancla, 70), v_veces;
  END IF;
  RETURN replace(p_texto, p_ancla, p_nuevo);
END;
$helper$;

-- ----------------------------------------------------------------------------
-- 3. registrar_compra_completa — lee y persiste condicion_iva
-- ----------------------------------------------------------------------------

DO $mig$
DECLARE
  v_def text;
BEGIN
  v_def := pg_get_functiondef(
    'public.registrar_compra_completa(bigint, character varying, character varying, date, numeric, numeric, numeric, numeric, character varying, text, uuid, jsonb, character varying, numeric, numeric, numeric, numeric)'::regprocedure);
  IF v_def LIKE '%condicion_iva%' THEN RETURN; END IF;

  v_def := public._mig177_reemplazo_unico(v_def,
    $a$  v_porcentaje_iva      NUMERIC;$a$,
    $a$  v_porcentaje_iva      NUMERIC;
  v_condicion_iva       TEXT;$a$,
    'registrar_compra_completa/declare');

  v_def := public._mig177_reemplazo_unico(v_def,
    $a$    v_porcentaje_iva     := CASE WHEN v_es_zz THEN 0 ELSE COALESCE((v_item->>'porcentaje_iva')::NUMERIC, 21) END;$a$,
    $a$    -- mig 177: la condición manda sobre la alícuota. Normaliza, nunca rechaza:
    -- un cliente viejo que no manda el campo se comporta exactamente como antes.
    v_condicion_iva      := CASE
      WHEN v_es_zz THEN 'gravado'
      WHEN COALESCE(v_item->>'condicion_iva', 'gravado') IN ('exento', 'no_gravado')
        THEN v_item->>'condicion_iva'
      ELSE 'gravado'
    END;
    v_porcentaje_iva     := CASE
      WHEN v_es_zz OR v_condicion_iva <> 'gravado' THEN 0
      ELSE COALESCE((v_item->>'porcentaje_iva')::NUMERIC, 21)
    END;$a$,
    'registrar_compra_completa/asignacion');

  v_def := public._mig177_reemplazo_unico(v_def,
    $a$      porcentaje_iva, impuestos_internos, costo_neto_unitario, costo_real_unitario$a$,
    $a$      porcentaje_iva, impuestos_internos, costo_neto_unitario, costo_real_unitario,
      condicion_iva$a$,
    'registrar_compra_completa/insert-columnas');

  v_def := public._mig177_reemplazo_unico(v_def,
    $a$      round(v_costo_neto, 4),
      v_costo_real
    );$a$,
    $a$      round(v_costo_neto, 4),
      v_costo_real,
      v_condicion_iva
    );$a$,
    'registrar_compra_completa/insert-valores');

  EXECUTE v_def;
END;
$mig$;

-- ----------------------------------------------------------------------------
-- 4. actualizar_compra_items — mismo criterio en la edición
-- ----------------------------------------------------------------------------

DO $mig$
DECLARE
  v_def text;
BEGIN
  v_def := pg_get_functiondef(
    'public.actualizar_compra_items(bigint, jsonb, numeric, numeric, numeric, uuid, numeric, numeric, numeric, numeric, numeric)'::regprocedure);
  IF v_def LIKE '%condicion_iva%' THEN RETURN; END IF;

  v_def := public._mig177_reemplazo_unico(v_def,
    $a$  v_porcentaje_iva NUMERIC;$a$,
    $a$  v_porcentaje_iva NUMERIC;
  v_condicion_iva TEXT;$a$,
    'actualizar_compra_items/declare');

  v_def := public._mig177_reemplazo_unico(v_def,
    $a$    v_porcentaje_iva     := CASE WHEN v_es_zz THEN 0 ELSE COALESCE((v_item->>'porcentaje_iva')::NUMERIC, 21) END;$a$,
    $a$    -- mig 177: la condición manda sobre la alícuota (ver registrar_compra_completa).
    v_condicion_iva      := CASE
      WHEN v_es_zz THEN 'gravado'
      WHEN COALESCE(v_item->>'condicion_iva', 'gravado') IN ('exento', 'no_gravado')
        THEN v_item->>'condicion_iva'
      ELSE 'gravado'
    END;
    v_porcentaje_iva     := CASE
      WHEN v_es_zz OR v_condicion_iva <> 'gravado' THEN 0
      ELSE COALESCE((v_item->>'porcentaje_iva')::NUMERIC, 21)
    END;$a$,
    'actualizar_compra_items/asignacion');

  v_def := public._mig177_reemplazo_unico(v_def,
    $a$      porcentaje_iva, impuestos_internos, costo_neto_unitario, costo_real_unitario$a$,
    $a$      porcentaje_iva, impuestos_internos, costo_neto_unitario, costo_real_unitario,
      condicion_iva$a$,
    'actualizar_compra_items/insert-columnas');

  v_def := public._mig177_reemplazo_unico(v_def,
    $a$      v_porcentaje_iva, v_impuestos_internos, round(v_costo_neto, 4), v_costo_real
    );$a$,
    $a$      v_porcentaje_iva, v_impuestos_internos, round(v_costo_neto, 4), v_costo_real,
      v_condicion_iva
    );$a$,
    'actualizar_compra_items/insert-valores');

  EXECUTE v_def;
END;
$mig$;

-- ----------------------------------------------------------------------------
-- 5. cambiar_proveedor_compra — el clon tiene que conservar la clasificación
--    (si no, cambiar de proveedor la perdería en silencio)
-- ----------------------------------------------------------------------------

DO $mig$
DECLARE
  v_def text;
BEGIN
  v_def := pg_get_functiondef(
    'public.cambiar_proveedor_compra(bigint, uuid, bigint, character varying, text)'::regprocedure);
  IF v_def LIKE '%condicion_iva%' THEN RETURN; END IF;

  v_def := public._mig177_reemplazo_unico(v_def,
    $a$    porcentaje_iva, impuestos_internos, costo_neto_unitario, costo_real_unitario$a$,
    $a$    porcentaje_iva, impuestos_internos, costo_neto_unitario, costo_real_unitario,
    condicion_iva$a$,
    'cambiar_proveedor_compra/insert-columnas');

  v_def := public._mig177_reemplazo_unico(v_def,
    $a$    ci.porcentaje_iva, ci.impuestos_internos, ci.costo_neto_unitario, ci.costo_real_unitario$a$,
    $a$    ci.porcentaje_iva, ci.impuestos_internos, ci.costo_neto_unitario, ci.costo_real_unitario,
    ci.condicion_iva$a$,
    'cambiar_proveedor_compra/select-columnas');

  EXECUTE v_def;
END;
$mig$;

-- ----------------------------------------------------------------------------
-- 6. Movimientos entre sucursales — snapshotear y propagar la condición
--    Sin esto, un producto exento movido a otra sucursal aterriza como gravado:
--    los números salen bien pero la clasificación se pierde sin aviso.
-- ----------------------------------------------------------------------------

DO $mig$
DECLARE
  v_def text;
  v_fn  text;
BEGIN
  -- crear_ y editar_movimiento_sucursal comparten el INSERT de items
  FOREACH v_fn IN ARRAY ARRAY[
    'public.crear_movimiento_sucursal(bigint, text, jsonb)',
    'public.editar_movimiento_sucursal(bigint, text, jsonb)'
  ] LOOP
    v_def := pg_get_functiondef(v_fn::regprocedure);
    CONTINUE WHEN v_def LIKE '%condicion_iva%';

    v_def := public._mig177_reemplazo_unico(v_def,
      $a$      origen_impuestos_internos, origen_porcentaje_iva, origen_stock_minimo,$a$,
      $a$      origen_impuestos_internos, origen_porcentaje_iva, origen_condicion_iva, origen_stock_minimo,$a$,
      v_fn || '/insert-columnas');

    v_def := public._mig177_reemplazo_unico(v_def,
      $a$      v_prod.impuestos_internos, v_prod.porcentaje_iva, v_prod.stock_minimo,$a$,
      $a$      v_prod.impuestos_internos, v_prod.porcentaje_iva, v_prod.condicion_iva, v_prod.stock_minimo,$a$,
      v_fn || '/insert-valores');

    EXECUTE v_def;
  END LOOP;

  -- aceptar_movimiento_sucursal: crea el producto en el destino
  v_def := pg_get_functiondef('public.aceptar_movimiento_sucursal(bigint, jsonb)'::regprocedure);
  IF v_def LIKE '%condicion_iva%' THEN RETURN; END IF;

  v_def := public._mig177_reemplazo_unico(v_def,
    $a$        impuestos_internos, porcentaje_iva, stock, stock_minimo, proveedor_id,$a$,
    $a$        impuestos_internos, porcentaje_iva, condicion_iva, stock, stock_minimo, proveedor_id,$a$,
    'aceptar_movimiento_sucursal/insert-columnas');

  v_def := public._mig177_reemplazo_unico(v_def,
    $a$        v_item.origen_impuestos_internos, v_item.origen_porcentaje_iva, 0, v_item.origen_stock_minimo, NULL,$a$,
    $a$        v_item.origen_impuestos_internos, v_item.origen_porcentaje_iva,
        COALESCE(v_item.origen_condicion_iva, 'gravado'), 0, v_item.origen_stock_minimo, NULL,$a$,
    'aceptar_movimiento_sucursal/insert-valores');

  EXECUTE v_def;
END;
$mig$;

DROP FUNCTION IF EXISTS public._mig177_reemplazo_unico(text, text, text, text);

-- ----------------------------------------------------------------------------
-- 7. Verificación (esperado: todo 'gravado', nada se movió)
--
--   SELECT condicion_iva, porcentaje_iva, count(*)
--     FROM compra_items GROUP BY 1,2 ORDER BY 3 DESC;
--   -- ('gravado',21)=115, ('gravado',0)=29, ('gravado',NULL)=362
--
--   SELECT condicion_iva, count(*) FROM productos GROUP BY 1;  -- gravado=247
-- ----------------------------------------------------------------------------
