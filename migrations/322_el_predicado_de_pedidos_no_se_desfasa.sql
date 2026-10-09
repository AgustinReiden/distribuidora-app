-- #1020 · El predicado de mt_pedidos_select no se desfasa de sus copias
--
-- La 314 (#1009) copió el predicado de la policy de SELECT de `pedidos`
--
--   (es_encargado_o_admin() OR usuario_id = auth.uid() OR transportista_id = auth.uid())
--   AND sucursal_id = current_sucursal_id()
--
-- en tres lugares, porque una función SECURITY DEFINER no pasa por la RLS:
--   * puede_leer_pedido(bigint), que usan las dos simular_*;
--   * inline en deuda_previa y deuda_previa_detalle (columnas calculadas, una
--     vez por fila: con el helper costaban 5x).
--
-- La 314 verificó que coincidieran AL APLICAR. Nada lo volvía a mirar: si
-- mañana la policy se ensancha (que depósito vea pedidos, sumar el rol extra),
-- las copias quedan atrás y la deuda previa y el simulador de salvedades
-- devuelven 0 / [] para las filas recién visibles, sin que falle nada. Y al
-- revés: si alguien edita una copia, el criterio se separa del de la RLS.
--
-- SEG-B en auditoria_integridad() lo mira en cada corrida del gate. El detalle
-- de qué se desfasó lo da `auditoria_predicado_pedidos()`.
--
-- Si SEG-B se pone rojo porque la policy cambió A PROPÓSITO: actualizar las
-- tres copias y el texto esperado de abajo en la misma migración.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1 · La función del check.
--
--     Sin argumentos lee la policy viva. Los dos parámetros existen para el
--     canario de la sección 3: probar que el check muerde con una policy
--     distinta sin hacer ALTER POLICY, que bloquea `pedidos` mientras dura la
--     transacción.
--
--     Las copias se comparan con los espacios normalizados: el texto exacto
--     depende del formato del cuerpo, el criterio no.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.auditoria_predicado_pedidos(
  p_qual     text    DEFAULT NULL,
  p_n_select integer DEFAULT NULL
)
RETURNS TABLE(problema text)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $fn$
  WITH esperado AS (
    SELECT
      '((es_encargado_o_admin() OR (usuario_id = auth.uid()) OR (transportista_id = auth.uid())) AND (sucursal_id = current_sucursal_id()))'::text
        AS qual,
      'pe.sucursal_id = current_sucursal_id() AND ( es_encargado_o_admin() OR pe.usuario_id = auth.uid() OR pe.transportista_id = auth.uid())'::text
        AS helper,
      -- El inline son dos piezas: la sucursal (la guarda de la 215) y el rol
      -- (la 314). Se buscan por separado para que un comentario entre las dos
      -- no cuente como cambio de criterio.
      'pe.sucursal_id = current_sucursal_id()'::text
        AS inline_sucursal,
      'AND (pe.usuario_id = auth.uid() OR pe.transportista_id = auth.uid() OR es_encargado_o_admin())'::text
        AS inline_rol
  ),
  vivo AS (
    SELECT
      COALESCE(p_qual,
        (SELECT qual FROM pg_policies
          WHERE schemaname = 'public' AND tablename = 'pedidos'
            AND policyname = 'mt_pedidos_select')) AS qual,
      COALESCE(p_n_select,
        (SELECT count(*)::int FROM pg_policies
          WHERE schemaname = 'public' AND tablename = 'pedidos'
            AND cmd IN ('SELECT', 'ALL') AND permissive = 'PERMISSIVE')) AS n_select
  ),
  cuerpo AS (
    SELECT f.firma,
           regexp_replace(COALESCE(
             (SELECT p.prosrc FROM pg_proc p WHERE p.oid = to_regprocedure(f.firma)), ''),
             '\s+', ' ', 'g') AS src
      FROM unnest(ARRAY[
        'public.puede_leer_pedido(bigint)',
        'public.deuda_previa(public.pedidos)',
        'public.deuda_previa_detalle(public.pedidos)',
        'public.simular_salvedad_promo_impacto(bigint,bigint,integer)',
        'public.simular_salvedades_promo_impacto(bigint,jsonb)'
      ]) AS f(firma)
  )
  SELECT 'mt_pedidos_select cambió: dice ' || COALESCE(v.qual, '(no existe)')
    FROM vivo v, esperado e
   WHERE v.qual IS DISTINCT FROM e.qual
  UNION ALL
  SELECT format('pedidos tiene %s policies PERMISSIVE de SELECT (se esperaba 1): la visibilidad ya no es sólo mt_pedidos_select', v.n_select)
    FROM vivo v
   WHERE v.n_select IS DISTINCT FROM 1
  UNION ALL
  SELECT 'puede_leer_pedido ya no copia el predicado de mt_pedidos_select'
    FROM cuerpo c, esperado e
   WHERE c.firma = 'public.puede_leer_pedido(bigint)'
     AND position(e.helper IN c.src) = 0
  UNION ALL
  SELECT c.firma || ' ya no tiene el predicado inline de mt_pedidos_select'
    FROM cuerpo c, esperado e
   WHERE c.firma IN ('public.deuda_previa(public.pedidos)', 'public.deuda_previa_detalle(public.pedidos)')
     AND (position(e.inline_sucursal IN c.src) = 0 OR position(e.inline_rol IN c.src) = 0)
  UNION ALL
  SELECT c.firma || ' ya no pasa por puede_leer_pedido(p_pedido_id)'
    FROM cuerpo c
   WHERE c.firma LIKE 'public.simular_%'
     AND position('public.puede_leer_pedido(p_pedido_id)' IN c.src) = 0;
$fn$;

COMMENT ON FUNCTION public.auditoria_predicado_pedidos(text, integer) IS
  'Check SEG-B (#1020): mt_pedidos_select y sus tres copias en funciones DEFINER (puede_leer_pedido, el inline de deuda_previa y deuda_previa_detalle) dicen lo mismo. Cero o rojo.';

REVOKE ALL ON FUNCTION public.auditoria_predicado_pedidos(text, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auditoria_predicado_pedidos(text, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 2 · SEG-B en auditoria_integridad(), al lado de SEG-A.
--     Ancla con la guarda de "exactamente una vez" (migs 257, 300, 314).
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE
  v_fn    regprocedure := 'public.auditoria_integridad()'::regprocedure;
  v_def   text := pg_get_functiondef('public.auditoria_integridad()'::regprocedure);
  v_ancla text := $ancla$    ('STK-F','high','funciones de public que suben stock sin declarar app.stock_origen (mig 229)',$ancla$;
  v_veces int;
BEGIN
  v_veces := (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El ancla aparece % veces en % (se esperaba exactamente 1). El cuerpo vivo cambio: revisar a mano.',
      v_veces, v_fn;
  END IF;
  EXECUTE replace(v_def, v_ancla,
$nuevo$    ('SEG-B','high','mt_pedidos_select y sus copias en funciones DEFINER dicen lo mismo (#1020)',
      (SELECT count(*) FROM public.auditoria_predicado_pedidos())),
    ('STK-F','high','funciones de public que suben stock sin declarar app.stock_origen (mig 229)',$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 3 · Verificación: en cero hoy, y muerde en cada uno de sus casos.
--     Cada canario se deshace solo con un SQLSTATE centinela.
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  v_lista text;
  v_n     int;
BEGIN
  IF has_function_privilege('authenticated', 'public.auditoria_predicado_pedidos(text,integer)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.auditoria_predicado_pedidos(text,integer)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.auditoria_predicado_pedidos(text,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION '#1020 · auditoria_predicado_pedidos tiene que ser sólo de service_role';
  END IF;

  -- 3.1 · Hoy, en cero.
  SELECT string_agg(problema, ' | ') INTO v_lista FROM public.auditoria_predicado_pedidos();
  IF v_lista IS NOT NULL THEN
    RAISE EXCEPTION '#1020 · SEG-B no está en cero: %', v_lista;
  END IF;

  -- 3.2 · SEG-B está una sola vez en auditoria_integridad() y en verde.
  SELECT count(*) INTO v_n
    FROM jsonb_array_elements(public.auditoria_integridad() -> 'checks') c
   WHERE c->>'id' = 'SEG-B' AND (c->>'ok')::boolean;
  IF v_n <> 1 THEN
    RAISE EXCEPTION '#1020 · SEG-B no aparece una vez y en verde en auditoria_integridad() (%)', v_n;
  END IF;

  -- 3.3 · Una policy más ancha (depósito ve pedidos) → rojo.
  IF NOT EXISTS (SELECT 1 FROM public.auditoria_predicado_pedidos(
       '((es_encargado_o_admin() OR (usuario_id = auth.uid()) OR (transportista_id = auth.uid()) OR (EXISTS ( SELECT 1 FROM perfiles WHERE ((perfiles.id = auth.uid()) AND (perfiles.rol = ''deposito''::text))))) AND (sucursal_id = current_sucursal_id()))',
       NULL)) THEN
    RAISE EXCEPTION '#1020 · SEG-B no detecta una policy distinta';
  END IF;

  -- 3.4 · Una segunda policy PERMISSIVE de SELECT → rojo.
  IF NOT EXISTS (SELECT 1 FROM public.auditoria_predicado_pedidos(NULL, 2)) THEN
    RAISE EXCEPTION '#1020 · SEG-B no detecta una segunda policy de SELECT';
  END IF;

  -- 3.5 · Una copia editada → rojo. El guard de deuda_previa sigue nombrando
  --       el helper (SEG-A no se entera) pero deja pasar a todos.
  BEGIN
    EXECUTE replace(pg_get_functiondef('public.deuda_previa(public.pedidos)'::regprocedure),
      'OR es_encargado_o_admin())',
      'OR es_encargado_o_admin() OR true)');
    IF NOT EXISTS (SELECT 1 FROM public.auditoria_predicado_pedidos()
                    WHERE problema LIKE 'public.deuda_previa(public.pedidos)%') THEN
      RAISE EXCEPTION '#1020 · SEG-B no detecta deuda_previa sin el predicado';
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- 3.6 · El helper editado → rojo.
  BEGIN
    EXECUTE replace(pg_get_functiondef('public.puede_leer_pedido(bigint)'::regprocedure),
      'OR pe.transportista_id = auth.uid())', 'OR true)');
    IF NOT EXISTS (SELECT 1 FROM public.auditoria_predicado_pedidos()
                    WHERE problema LIKE 'puede_leer_pedido%') THEN
      RAISE EXCEPTION '#1020 · SEG-B no detecta puede_leer_pedido editado';
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;
END
$verif$;

COMMIT;
