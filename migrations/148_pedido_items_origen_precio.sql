-- =========================================================================
-- 148_pedido_items_origen_precio.sql
--
-- El 31% de los ítems entregados (≈$22,3M de $65,7M en 60 días) sale bajo
-- precio de lista sin dejar rastro de POR QUÉ: el descuento pisa
-- `precio_unitario` y desaparece. Sin esto no hay comisión variable por
-- descuento posible, y el dato no es reconstruible hacia atrás porque los
-- precios de lista y los % de descuento cambiaron desde entonces.
--
-- Por eso esta migración va suelta y ANTES que las reglas de comisión: cada
-- día sin ella es un día de ventas sin desglose recuperable.
--
-- Mismo patrón que `costo_unitario_al_crear` (mig 100): columnas nullable,
-- forward-only, nada se rompe.
--
-- DOS DECISIONES QUE SE APARTAN DEL PLAN, con motivo:
--
-- 1. `grupo_precio_escala_id` va SIN foreign key. `updateGrupoPrecio` (el modal
--    de condición mayorista) borra y reinserta TODAS las escalas del grupo en
--    cada edición. Con una FK, editar un grupo que ya tiene ventas fallaría
--    (RESTRICT) o nos borraría el dato histórico (CASCADE). Es una referencia
--    histórica, no relacional: el id vale como rastro aunque la escala ya no
--    exista.
--
-- 2. Los ítems anteriores a esta migración quedan con `origen_precio` NULL, no
--    'desconocido'. NULL = "no hay dato porque es viejo"; 'desconocido' =
--    "es nuevo y no se pudo determinar". Distinguirlos es lo que le permite a
--    `calcular_comisiones` decir con exactitud cuántos ítems quedaron sin
--    desglose en vez de mezclar las dos cosas.
-- =========================================================================

ALTER TABLE public.pedido_items
  ADD COLUMN IF NOT EXISTS precio_lista_al_crear  numeric(12,2),
  ADD COLUMN IF NOT EXISTS origen_precio          varchar(20),
  ADD COLUMN IF NOT EXISTS descuento_pct          numeric(5,2),
  ADD COLUMN IF NOT EXISTS grupo_precio_escala_id bigint;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'pedido_items_origen_precio_check') THEN
    ALTER TABLE public.pedido_items
      ADD CONSTRAINT pedido_items_origen_precio_check
      CHECK (origen_precio IS NULL OR origen_precio IN (
        'lista', 'mayorista', 'desc_cliente', 'desc_categoria',
        'manual', 'bonificacion', 'desconocido'
      ));
  END IF;
END $$;

COMMENT ON COLUMN public.pedido_items.precio_lista_al_crear IS
  'Snapshot de productos.precio al crear el ítem. Sin esto el descuento no se puede reconstruir: el precio de lista se mueve. Mig 148.';
COMMENT ON COLUMN public.pedido_items.origen_precio IS
  'Por qué se cobró este precio. NULL = ítem anterior a la mig 148 (no hay dato). desconocido = posterior pero no determinable.';
COMMENT ON COLUMN public.pedido_items.descuento_pct IS
  'Magnitud del descuento vs el precio de lista, derivada. Negativo = se vendió por encima de lista. Mig 148.';
COMMENT ON COLUMN public.pedido_items.grupo_precio_escala_id IS
  'Escala mayorista que aplicó. SIN FK a propósito: editar un grupo borra y recrea sus escalas (mig 148).';

-- -------------------------------------------------------------------------
-- Lo que el server puede computar barato, lo computa el server.
--
-- Por trigger y no dentro de los RPCs, igual que las guardas de precio (139) y
-- de mínimo de venta (147): `crear_pedido_completo`, `crear_pedido_completo_bot`
-- y `actualizar_pedido_items` son tres funciones de ~14k caracteres, y las tres
-- terminan en un INSERT a pedido_items. Un trigger las cubre a las tres, más la
-- cola offline y cualquier RPC futuro, sin reescribir ninguna.
--
-- `origen_precio` y `grupo_precio_escala_id` los va a mandar el cliente (la
-- precedencia real —promo → mayorista → descuento de cliente— vive en TypeScript
-- y reimplementarla en PL/pgSQL duplicaría lógica compleja). El trigger NO pisa
-- lo que venga cargado: solo completa lo que falta.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.completar_origen_precio_item()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $fn$
DECLARE
  v_lista numeric;
BEGIN
  -- 1. Precio de lista vigente al momento de crear el ítem.
  IF NEW.precio_lista_al_crear IS NULL THEN
    SELECT precio INTO v_lista FROM productos WHERE id = NEW.producto_id;
    NEW.precio_lista_al_crear := v_lista;
  END IF;
  v_lista := NEW.precio_lista_al_crear;

  -- 2. Descuento derivado. Se acota al rango de numeric(5,2): un producto de
  --    lista muy baja vendido caro daría un porcentaje que no entra en la
  --    columna y abortaría el INSERT del pedido entero.
  IF NEW.descuento_pct IS NULL AND v_lista IS NOT NULL AND v_lista > 0 THEN
    NEW.descuento_pct := greatest(
      -999.99,
      least(999.99, round(((v_lista - NEW.precio_unitario) / v_lista) * 100, 2))
    );
  END IF;

  -- 3. Origen, solo si el cliente no lo declaró.
  IF NEW.origen_precio IS NULL THEN
    IF COALESCE(NEW.es_bonificacion, false) THEN
      NEW.origen_precio := 'bonificacion';
    ELSIF v_lista IS NULL OR v_lista <= 0 THEN
      NEW.origen_precio := 'desconocido';
    ELSIF NEW.precio_unitario = v_lista THEN
      NEW.origen_precio := 'lista';
    ELSE
      -- Por debajo o por encima de lista sin que nadie diga por qué. No se
      -- adivina: 'desconocido' es un dato, una etiqueta inventada es ruido.
      NEW.origen_precio := 'desconocido';
    END IF;
  END IF;

  RETURN NEW;
END;
$fn$;

ALTER FUNCTION public.completar_origen_precio_item() OWNER TO postgres;

-- Solo INSERT: `actualizar_pedido_items` borra y reinserta los ítems, así que
-- la edición también pasa por acá y re-snapshotea contra el precio de lista del
-- momento de la edición. Es el mismo criterio que ya tiene
-- `costo_unitario_al_crear` en esa función.
DROP TRIGGER IF EXISTS trg_completar_origen_precio_item ON public.pedido_items;
CREATE TRIGGER trg_completar_origen_precio_item
  BEFORE INSERT ON public.pedido_items
  FOR EACH ROW
  EXECUTE FUNCTION public.completar_origen_precio_item();

-- -------------------------------------------------------------------------
-- Backfill: lo único derivable del histórico.
--
-- `es_bonificacion` es un hecho registrado, así que esos ítems sí se pueden
-- etiquetar. El resto NO se toca: los precios de lista y los % de descuento
-- de entonces no son reconstruibles, e inventarles un origen ensuciaría el
-- único dato que dice la verdad ("de estos ítems no sabemos").
-- -------------------------------------------------------------------------
UPDATE public.pedido_items
SET origen_precio = 'bonificacion'
WHERE es_bonificacion IS TRUE
  AND origen_precio IS NULL;
