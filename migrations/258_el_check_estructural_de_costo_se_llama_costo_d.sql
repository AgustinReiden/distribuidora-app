-- 258 · El check estructural de costo se llama COSTO-D
--
-- Corrección de la 257. El check nuevo nació con el id `COSTO-A`, que ya estaba
-- ocupado desde la 105 por otro check --el centinela de datos: "pedidos de las
-- últimas 2h, líneas no-bonif con costo congelado poblado"--. `auditoria_integridad()`
-- devuelve una lista, no un mapa: dos filas con el mismo id no chocan, no fallan
-- y no se notan. Quedaban dos `COSTO-A` distintos en la misma salida, y el día
-- que uno se ponga rojo nadie sabe cuál.
--
-- El estructural --el de #673, el que cuenta funciones de `public` que escriben
-- `costo_unitario_al_crear` sin pasar por `costo_valuacion()`-- pasa a `COSTO-D`.
-- El centinela de datos se queda con `COSTO-A`, que es el que ya tenía. La `B` y
-- la `C` también estaban ocupadas: la familia `COSTO-*` ya iba por la cuarta
-- letra y nadie lo dice en ningún lado, que es exactamente por qué el ensayo de
-- acá abajo pasa a verificar que NINGÚN id se repita.
--
-- Parche por ancla sobre el cuerpo vivo, igual que la 257.

BEGIN;

CREATE OR REPLACE FUNCTION public._migsv_ancla(
  p_funcion regprocedure, p_ancla text, p_nuevo text
) RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text;
  v_veces int;
BEGIN
  v_def := pg_get_functiondef(p_funcion);
  v_veces := (length(v_def) - length(replace(v_def, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El ancla aparece % veces en % (se esperaba exactamente 1). El cuerpo vivo cambio: revisar a mano. Ancla: %',
      v_veces, p_funcion, left(p_ancla, 120);
  END IF;
  EXECUTE replace(v_def, p_ancla, p_nuevo);
END;
$fn$;

DO $patch$
BEGIN
  PERFORM public._migsv_ancla('public.auditoria_integridad()'::regprocedure,
$ancla$    ('COSTO-A','high','funciones de public que escriben costo_unitario_al_crear sin pasar por costo_valuacion (mig 238, #673)',$ancla$,
$nuevo$    ('COSTO-D','high','funciones de public que escriben costo_unitario_al_crear sin pasar por costo_valuacion (mig 238, #673)',$nuevo$);
END
$patch$;

COMMENT ON FUNCTION public.auditoria_funciones_costo_sin_valuacion() IS
  'Check COSTO-D (migs 257 y 258, #673): funciones de public que escriben pedido_items.costo_unitario_al_crear sin pasar por costo_valuacion() (mig 238). Estructural, como auditoria_funciones_stock_sin_origen. Cero o rojo. Nacio como COSTO-A, id que ya usaba el centinela de datos de la 105.';

-- ---------------------------------------------------------------------------
-- El ensayo: un id, un check. Y de paso la invariante que la 257 no tenia y
-- que es la que hubiera atajado esto: NINGUN id repetido en toda la salida.
-- ---------------------------------------------------------------------------
DO $ensayo$
DECLARE
  v_dup text;
  v_b   int;
BEGIN
  SELECT string_agg(id, ', ' ORDER BY id) INTO v_dup
    FROM (SELECT c->>'id' AS id
            FROM public.auditoria_integridad() r, jsonb_array_elements(r->'checks') c
           GROUP BY 1 HAVING count(*) > 1) d;
  IF v_dup IS NOT NULL THEN
    RAISE EXCEPTION 'migsv · auditoria_integridad() devuelve ids repetidos: %', v_dup;
  END IF;

  SELECT count(*) INTO v_b
    FROM public.auditoria_integridad() r, jsonb_array_elements(r->'checks') c
   WHERE c->>'id' = 'COSTO-D' AND (c->>'ok')::boolean;
  IF v_b <> 1 THEN
    RAISE EXCEPTION 'migsv · COSTO-D aparece % veces en verde (esperado 1)', v_b;
  END IF;

  RAISE NOTICE 'migsv · ensayo OK: un id por check, y COSTO-D en verde';
END
$ensayo$;

DROP FUNCTION public._migsv_ancla(regprocedure, text, text);

COMMIT;
