-- =========================================================================
-- Los lotes no pueden sumar mas que el stock
--
-- Tres invariantes para auditoria_integridad(), todos high, que vigilan el
-- modelo de vencimientos de las migs 223/224.
--
-- LOTE-A es el que importa: SUM(cantidad_restante) <= productos.stock por
-- (producto, sucursal). Es la definicion misma de la bolsa "sin vencimiento" --
-- si la suma pasa el stock, la bolsa es negativa y eso no significa nada. Se
-- rompe si alguien escribe producto_lotes por fuera de las RPCs, si el clamp
-- falla, o si un camino nuevo baja el stock sin que el trigger lo vea.
--
-- POR QUE NO SE REESCRIBE LA FUNCION DESDE migrations/105
-- ------------------------------------------------------
-- El cuerpo vivo lo parchearon las migs 178, 180, 194 y 195. Un CREATE OR
-- REPLACE armado desde el archivo original las revertiria todas en silencio.
-- Se lee la definicion viva del catalogo, se inserta con un ancla que tiene que
-- aparecer exactamente una vez, y se ejecuta -- el patron de la mig 180.
-- =========================================================================

BEGIN;

DO $mig$
DECLARE
  v_def   text;
  v_veces integer;
  -- El cierre del VALUES, justo despues del ultimo check (RUTA-C, mig 180).
  v_ancla CONSTANT text := $a$WHERE p.estado IN ('cancelado','anulado') AND r.estado='en_curso'))
  )$a$;
  v_nuevo CONSTANT text := $a$WHERE p.estado IN ('cancelado','anulado') AND r.estado='en_curso')),
    -- ===== Vencimientos por lote (mig 225) =====
    ('LOTE-A','high','productos donde la suma de los lotes supera el stock',
      (SELECT count(*) FROM (
         SELECT l.producto_id AS pid, l.sucursal_id AS sid,
                SUM(l.cantidad_restante) AS asignado
           FROM producto_lotes l GROUP BY 1,2
       ) a
       JOIN productos p ON p.id=a.pid AND p.sucursal_id=a.sid
      WHERE a.asignado > p.stock)),
    ('LOTE-B','high','lotes con el contador fuera de rango',
      (SELECT count(*) FROM producto_lotes
        WHERE cantidad_restante < 0 OR cantidad_restante > cantidad OR cantidad <= 0)),
    ('LOTE-C','high','lotes cuya sucursal no coincide con la del producto',
      (SELECT count(*) FROM producto_lotes l
         JOIN productos p ON p.id=l.producto_id
        WHERE p.sucursal_id <> l.sucursal_id))
  )$a$;
BEGIN
  v_def := pg_get_functiondef('public.auditoria_integridad()'::regprocedure);

  IF position('LOTE-A' in v_def) > 0 THEN
    RAISE NOTICE 'mig 225 - checks LOTE-* ya presentes, se omite';
    RETURN;
  END IF;

  v_veces := (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'mig 225 - el ancla de auditoria_integridad aparece % veces (se esperaba 1). El cuerpo derivo; revisa el parche antes de aplicar.', v_veces;
  END IF;

  EXECUTE replace(v_def, v_ancla, v_nuevo);
END
$mig$;

-- ---------------------------------------------------------------------------
-- Post-condicion, obligatoria.
--
-- Los cuerpos plpgsql son strings y Postgres no los valida al crearlos: un
-- parche que no hubiera entrado NO falla al aplicar, falla en produccion. Hay
-- que correr la funcion y ver los checks nuevos ahi.
--
-- Y tienen que NACER EN VERDE. Un check que nace rojo vuelve inutil al gate
-- diario -- es lo que le paso a COMPRA-A1 antes de la mig 178, y por eso los
-- que se agregaban despues nacian invisibles.
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  v_res  jsonb;
  v_chk  jsonb;
  v_id   text;
BEGIN
  v_res := public.auditoria_integridad();

  FOREACH v_id IN ARRAY ARRAY['LOTE-A', 'LOTE-B', 'LOTE-C'] LOOP
    SELECT c INTO v_chk
      FROM jsonb_array_elements(v_res->'checks') c
     WHERE c->>'id' = v_id;

    IF v_chk IS NULL THEN
      RAISE EXCEPTION 'mig 225 - % no aparece en la salida de auditoria_integridad(). El parche no entro.', v_id;
    END IF;
    IF (v_chk->>'violaciones')::integer <> 0 THEN
      RAISE EXCEPTION 'mig 225 - % nace en rojo con % violaciones. Un check que nace rojo vuelve inutil al gate diario.',
        v_id, v_chk->>'violaciones';
    END IF;
  END LOOP;

  IF (v_res->>'overall_ok')::boolean IS NOT TRUE THEN
    RAISE WARNING 'mig 225 - auditoria_integridad() quedo en rojo por checks PREEXISTENTES (los LOTE-* estan en verde). Revisar aparte.';
  END IF;
END
$verif$;

COMMIT;
