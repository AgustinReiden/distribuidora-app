-- #1077 · El subtotal de la compra es la suma de sus renglones.
--
-- registrar_compra_completa y actualizar_compra_items escribían
-- compras.subtotal = p_subtotal y el subtotal de cada compra_items desde el
-- JSON, los dos tal como los manda el cliente. Nadie en el servidor miraba que
-- cuadraran: el invariante dependía de que el front no se equivocara, y
-- COMPRA-A2 lo veía recién al día siguiente, con la compra ya guardada. Ahora
-- las dos rechazan si abs(p_subtotal − Σ subtotal de renglones) > 1, con la
-- misma tolerancia que COMPRA-A2.
--
-- DÓNDE: antes de tocar nada. En el alta, antes del INSERT de la cabecera; en
-- la edición, después de los controles de permiso, compra cancelada y 7 días,
-- y antes del primer cálculo: ni stock, ni costo promedio (236), ni cargos
-- (194/195), ni lotes (224/240) llegan a moverse. Devuelve
-- {success:false, error} como los demás rechazos tempranos de las dos RPCs.
--
-- QUÉ SE SUMA: lo mismo que guarda el loop en compra_items.subtotal,
-- COALESCE(item->>'subtotal', 0) de cada elemento, redondeado a 2 decimales
-- como la columna. La cabecera también a 2. Un p_subtotal NULL se rechaza con
-- el mismo mensaje (antes fallaba igual, por el NOT NULL de la columna).
--
-- POR QUÉ 1 Y NO 0,01: el front manda floats sin redondear (la compra 73 quedó
-- con 0,02 de diferencia) y la tolerancia es la del check que vigila esto.
--
-- EL FRONT: la edición manda cabecera y renglones de los mismos state.items con
-- la misma aritmética. El alta tenía un `||` que a un renglón bonificado al
-- 100 % (subtotal 0) le mandaba el bruto, mientras la cabecera lo contaba como
-- 0: se corrige en el mismo PR (useComprasQuery.ts). En prod nunca pasó (cero
-- renglones al 100 %), pero desde f372eb0d esa línea es el "producto de
-- regalo" legítimo, así que un bundle viejo del PWA que cargue un regalo ahora
-- se rechaza hasta que recargue; por eso el mensaje dice "recargá la
-- aplicación". En la edición no pasa: cabecera y renglones salen siempre de los
-- mismos ítems, también en los bundles viejos.
--
-- PRECEDENCIA: un payload con el subtotal desfasado Y otro error (cargos mal
-- formados en el alta, o los guards de "recargá la página" de la 194 en la
-- edición) ahora ve primero el del subtotal. Los dos rechazan sin escribir.
--
-- Las firmas no cambian: CREATE OR REPLACE por ancla conserva dueño y grants.
--
-- Ensayo: scripts/test-subtotal-compra-1077.sql (falla antes, pasa después).

BEGIN;

CREATE OR REPLACE FUNCTION public._mig1077_ancla(
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

-- ---------------------------------------------------------------------------
-- 1 · registrar_compra_completa
-- ---------------------------------------------------------------------------
SELECT public._mig1077_ancla(
  'public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)'::regprocedure,
  E'  v_warning_repos       JSONB := \'[]\'::JSONB;\nBEGIN\n',
  E'  v_warning_repos       JSONB := \'[]\'::JSONB;\n'
  || E'  v_suma_items          NUMERIC;   -- #1077\n'
  || E'BEGIN\n');

SELECT public._mig1077_ancla(
  'public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)'::regprocedure,
  E'\n  INSERT INTO compras (\n    proveedor_id, proveedor_nombre, numero_factura, fecha_compra,\n',
  $nuevo$
  /* #1077 · La cabecera es la suma de los renglones. Los dos numeros los manda
     el cliente; se comparan ACA, antes del INSERT y de tocar stock, costo o
     lotes. Se suma lo mismo que guarda el loop (COALESCE(subtotal, 0) a 2
     decimales, como la columna). Tolerancia 1, la de COMPRA-A2: el front manda
     floats sin redondear. */
  SELECT COALESCE(sum(round(COALESCE((e->>'subtotal')::NUMERIC, 0), 2)), 0)
    INTO v_suma_items
    FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_items) = 'array'
                                   THEN p_items ELSE '[]'::JSONB END) AS e;
  IF p_subtotal IS NULL OR abs(round(p_subtotal, 2) - v_suma_items) > 1 THEN
    RETURN jsonb_build_object('success', false, 'error',
      format('El subtotal de la compra (%s) no coincide con la suma de los renglones (%s). Revisá los renglones; si sigue igual, recargá la aplicación y volvé a cargarla.',
             COALESCE(round(p_subtotal, 2)::TEXT, 'sin informar'), v_suma_items));
  END IF;

  INSERT INTO compras (
    proveedor_id, proveedor_nombre, numero_factura, fecha_compra,
$nuevo$);

-- ---------------------------------------------------------------------------
-- 2 · actualizar_compra_items
-- ---------------------------------------------------------------------------
SELECT public._mig1077_ancla(
  'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)'::regprocedure,
  E'  v_cpp_persistir    NUMERIC;\nBEGIN\n',
  E'  v_cpp_persistir    NUMERIC;\n'
  || E'  v_suma_items       NUMERIC;   -- #1077\n'
  || E'BEGIN\n');

SELECT public._mig1077_ancla(
  'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)'::regprocedure,
  E'\n  v_es_zz := (v_compra.tipo_factura = \'ZZ\');\n',
  $nuevo$
  /* #1077 · La cabecera es la suma de los renglones nuevos (la edicion reemplaza
     todos). Se compara ACA, despues de los controles de permiso y antes de
     revertir stock, costo promedio, cargos o lotes. Mismo criterio que el alta:
     COALESCE(subtotal, 0) a 2 decimales, tolerancia 1 (la de COMPRA-A2). */
  SELECT COALESCE(sum(round(COALESCE((e->>'subtotal')::NUMERIC, 0), 2)), 0)
    INTO v_suma_items
    FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_items_nuevos) = 'array'
                                   THEN p_items_nuevos ELSE '[]'::JSONB END) AS e;
  IF p_subtotal IS NULL OR abs(round(p_subtotal, 2) - v_suma_items) > 1 THEN
    RETURN jsonb_build_object('success', false, 'error',
      format('El subtotal de la compra (%s) no coincide con la suma de los renglones (%s). Revisá los renglones; si sigue igual, recargá la aplicación y volvé a guardarla.',
             COALESCE(round(p_subtotal, 2)::TEXT, 'sin informar'), v_suma_items));
  END IF;

  v_es_zz := (v_compra.tipo_factura = 'ZZ');
$nuevo$);

DROP FUNCTION public._mig1077_ancla(regprocedure, text, text);

-- ---------------------------------------------------------------------------
-- 3 · Verificación
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  f   regprocedure;
  v_n int;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)'::regprocedure,
    'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)'::regprocedure
  ] LOOP
    -- El control quedó una sola vez, y antes de la primera escritura.
    IF (SELECT count(*) FROM regexp_matches(pg_get_functiondef(f), 'no coincide con la suma de los renglones', 'g')) <> 1 THEN
      RAISE EXCEPTION '#1077 · % no tiene el control exactamente una vez', f;
    END IF;
    IF strpos(pg_get_functiondef(f), 'no coincide con la suma de los renglones')
       > least(NULLIF(strpos(pg_get_functiondef(f), 'INSERT INTO compras'), 0),
               NULLIF(strpos(pg_get_functiondef(f), 'UPDATE productos'), 0),
               NULLIF(strpos(pg_get_functiondef(f), 'DELETE FROM compra_items'), 0),
               NULLIF(strpos(pg_get_functiondef(f), 'set_config('), 0)) THEN
      RAISE EXCEPTION '#1077 · en % el control quedó después de una escritura', f;
    END IF;
    -- Los grants no se movieron: authenticated sí, anon no.
    IF NOT has_function_privilege('authenticated', f, 'EXECUTE')
       OR has_function_privilege('anon', f, 'EXECUTE') THEN
      RAISE EXCEPTION '#1077 · % con grants inesperados', f;
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = f) THEN
      RAISE EXCEPTION '#1077 · % dejó de ser SECURITY DEFINER', f;
    END IF;
  END LOOP;

  -- Lo que ya está guardado no cambia: COMPRA-A2 sigue en cero.
  SELECT (c->>'violaciones')::int INTO v_n
    FROM jsonb_array_elements(public.auditoria_integridad() -> 'checks') c
   WHERE c->>'id' = 'COMPRA-A2';
  IF v_n IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION '#1077 · COMPRA-A2 = % (tiene que estar en 0)', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM public.auditoria_definer_sin_rol();
  IF v_n <> 0 THEN
    RAISE EXCEPTION '#1077 · SEG-A no está en cero: %',
      (SELECT string_agg(firma || ' — ' || motivo, E'\n') FROM public.auditoria_definer_sin_rol());
  END IF;
END
$verif$;

COMMIT;
