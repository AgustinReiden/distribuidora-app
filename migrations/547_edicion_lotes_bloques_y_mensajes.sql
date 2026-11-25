-- =========================================================================
-- NNN · LA EDICIÓN DEL PEDIDO: EL LOTE DEL CONTENEDOR QUE TOMA UN BLOQUE NUEVO,
--       EL CAMINO DE STK-2 Y EL MENSAJE DEL TOPE DE LA CADENA
--       (plan #1603, tanda 6 bis, tarjeta J)
--
-- Ensayo: scripts/test-edicion-lotes-tanda6bis-1603.sql (falla sin esta
-- migración en J1a, J1b, J1c, J1d, J1f, J3 y J4; ENSAYO OK con ella). Se aplica en LF,
-- DESPUÉS de la de la tarjeta I (546). Sólo cambia el cuerpo de
-- actualizar_pedido_items (por ancla y sin premisa de md5: la 546 le suma un
-- tramo en la rama del admin, lejos de estos) y crea un helper de server: no toca
-- tablas ni toma sus locks. Ninguna firma cambia: un bundle viejo del PWA sigue
-- llamando igual.
--
-- 1 · LOTE-A al editar (H-3 de la lente de H, preexistente). La edición devuelve
--     las líneas sin etiqueta (a la bolsa) y, al final, _rehacer_huella_lineas
--     pasa de la bolsa a su lote lo que la cantidad nueva ya no cubre. En el medio
--     la barra cierra bloques, y la bajada del bloque come la bolsa primero: se
--     comía justo las unidades devueltas, que el rehacer después le devolvía al
--     lote sin que la bolsa las tuviera. C con un lote de 5, alta A×10 + S×2 + C×1
--     (C: 3 en el lote, el bloque y la línea con huella en él); editar a A×20 + S×4
--     dejaba C en 3 con el lote en 4 (bolsa −1, LOTE-A) y el bloque nuevo diciendo
--     «bolsa». Ahora, si después del rehacer la bolsa de un contenedor quedó
--     negativa, el bloque que esta edición cerró desde la bolsa hereda el lote al
--     que el rehacer devolvió (el molde M3-1 de _barra_mover_neto): el lote no
--     sube y el bloque dice ese lote, así que deshacerlo vuelve a él. Queda C en
--     3, el lote en 3, la bolsa en 0 y el bloque en el lote. Sólo mueve lo que
--     falta para que la bolsa no quede negativa: toda edición que hoy deja la
--     bolsa en 0 o más da exactamente lo mismo. Helper nuevo
--     _bloques_heredan_lotes_devueltos (de server, sin EXECUTE para nadie más).
-- 2 · COMBO-B después de una rotura (lente de I): no hacía falta. Es un artefacto
--     de correr la salvedad y la edición en la misma transacción: _combo_estado
--     cuenta los rechazos con created_at >= armado_at y, con un solo now(), el
--     rechazo de la salvedad parece posterior al armado que la edición rehízo.
--     Con la salvedad antes de la edición (como pasa en la app) la auditoría da
--     verde; el ensayo lo deja como regresión (J2).
-- 3 · El camino de STK-2 (H-1 de la lente de H): se activaba con que la promo
--     tuviera bloques vivos en ese contenedor, aunque esta edición no bajara su
--     barra, y el rechazo salía como excepción «contando lo que devuelve la barra»
--     sin que ninguna barra devolviera nada. Ahora se activa sólo si esta edición
--     baja la barra de esa promo y ese sabor (la del bloque vivo); si no, el
--     rechazo de siempre (success=false, «stock insuficiente (disponible…,
--     adicional…)»).
-- 4 · El mensaje N3 (lente de promos): el rechazo del tope de la cadena de un
--     regalo sustituido nombraba el regalo del JSON; ahora nombra el regalo con el
--     que mide, el de _regalo_de_la_promo. Sólo el texto.
--
-- Revertir: volver actualizar_pedido_items a su texto sin estos cuatro tramos (los
-- anclas de abajo) y DROP FUNCTION public._bloques_heredan_lotes_devueltos.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: lo que se usa existe, y lo nuevo todavía no.
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT unnest(ARRAY[
      'public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)',
      'public._rehacer_huella_lineas(jsonb,bigint[])',
      'public._barra_mover_neto(jsonb,bigint,uuid)',
      'public._regalo_de_la_promo(bigint,bigint,bigint,uuid,bigint,numeric)',
      'public.regalo_sustitucion_resuelta(bigint,bigint,bigint,bigint,numeric,uuid)']) AS f LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace
                AND proname = '_bloques_heredan_lotes_devueltos') THEN
    RAISE EXCEPTION 'mig NNN · _bloques_heredan_lotes_devueltos ya existe: rehacer sobre lo vigente';
  END IF;
END
$premisas$;

-- =========================================================================
-- 1 · El helper: el bloque nuevo hereda el lote que el rehacer le devolvió
-- =========================================================================
CREATE FUNCTION public._bloques_heredan_lotes_devueltos(
  p_sucursal_id bigint,
  p_promos bigint[],
  p_ajuste_max bigint,
  p_lotes_antes jsonb
)
RETURNS void
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_prod   RECORD;
  v_falta  INT;
  v_fardos JSONB;
  v_bloque RECORD;
  v_el     JSONB;
  v_nuevos JSONB;
  v_pend   INT;
  v_toma   INT;
BEGIN
  -- LOTE-A al editar (tanda 6 bis de #1603). La edición devuelve las líneas a la bolsa y
  -- _rehacer_huella_lineas, al final, pasa a su lote lo que la cantidad nueva no cubre. Si
  -- en el medio un bloque de la barra (los de id mayor que p_ajuste_max de estas promos,
  -- que el llamador tiene tomadas) se comió esas unidades de la bolsa, el rehacer subió el
  -- lote sin contrapartida y la bolsa quedó negativa. Lo que falta para que no lo esté sale
  -- de lo que el rehacer le devolvió a cada lote (p_lotes_antes: los contadores de antes del
  -- rehacer), en el orden de los lotes, y lo hereda la parte {"lote_id": null} de esos
  -- bloques, en el orden en que se cerraron: el lote no sube y el bloque dice de qué lote
  -- salió, como el fardo que se abre en una barra y se cierra en otra (_barra_mover_neto).
  -- El stock y el ledger no se mueven. Una bolsa que no quedó negativa no se toca.
  IF p_lotes_antes IS NULL OR p_lotes_antes = '{}'::jsonb OR COALESCE(cardinality(p_promos), 0) = 0 THEN
    RETURN;
  END IF;

  FOR v_prod IN
    SELECT p.id,
           p.stock - COALESCE((SELECT SUM(l.cantidad_restante) FROM producto_lotes l
                                WHERE l.producto_id = p.id AND l.sucursal_id = p.sucursal_id), 0) AS bolsa
      FROM productos p
     WHERE p.sucursal_id = p_sucursal_id
       AND p.id IN (SELECT pa.producto_id FROM promo_ajustes pa
                     WHERE pa.promocion_id = ANY(p_promos) AND pa.sucursal_id = p_sucursal_id
                       AND pa.id > p_ajuste_max
                       AND pa.lotes_pendientes @> '[{"lote_id": null}]'::jsonb)
     ORDER BY p.id
  LOOP
    CONTINUE WHEN v_prod.bolsa >= 0;
    v_falta := -v_prod.bolsa;
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'lote_id', l.id, 'cantidad', l.cantidad_restante - (p_lotes_antes->>l.id::TEXT)::INT)
             ORDER BY l.fecha_vencimiento, l.id), '[]'::jsonb)
      INTO v_fardos
      FROM producto_lotes l
     WHERE l.producto_id = v_prod.id AND l.sucursal_id = p_sucursal_id
       AND p_lotes_antes ? l.id::TEXT
       AND l.cantidad_restante > (p_lotes_antes->>l.id::TEXT)::INT;
    CONTINUE WHEN jsonb_array_length(v_fardos) = 0;

    FOR v_bloque IN
      SELECT pa.id, pa.lotes_pendientes
        FROM promo_ajustes pa
       WHERE pa.promocion_id = ANY(p_promos) AND pa.sucursal_id = p_sucursal_id
         AND pa.id > p_ajuste_max AND pa.producto_id = v_prod.id
         AND pa.lotes_pendientes @> '[{"lote_id": null}]'::jsonb
       ORDER BY pa.id
    LOOP
      EXIT WHEN v_falta <= 0;
      v_nuevos := '[]'::jsonb;
      FOR v_el IN
        SELECT a.x FROM jsonb_array_elements(v_bloque.lotes_pendientes) WITH ORDINALITY AS a(x, ord)
         ORDER BY a.ord
      LOOP
        IF v_el->>'lote_id' IS NOT NULL THEN
          v_nuevos := v_nuevos || jsonb_build_array(v_el);
          CONTINUE;
        END IF;
        v_pend := (v_el->>'cantidad')::INT;
        FOR i IN 0 .. jsonb_array_length(v_fardos) - 1 LOOP
          EXIT WHEN v_pend <= 0 OR v_falta <= 0;
          CONTINUE WHEN (v_fardos->i->>'cantidad')::INT <= 0;
          v_toma := LEAST(v_pend, v_falta, (v_fardos->i->>'cantidad')::INT);
          UPDATE producto_lotes
             SET cantidad_restante = cantidad_restante - v_toma
           WHERE id = (v_fardos->i->>'lote_id')::BIGINT AND sucursal_id = p_sucursal_id;
          v_nuevos := v_nuevos || jsonb_build_array(jsonb_build_object(
                        'lote_id', (v_fardos->i->>'lote_id')::BIGINT, 'cantidad', v_toma));
          v_fardos := jsonb_set(v_fardos, ARRAY[i::TEXT, 'cantidad'],
                                to_jsonb((v_fardos->i->>'cantidad')::INT - v_toma));
          v_pend := v_pend - v_toma;
          v_falta := v_falta - v_toma;
        END LOOP;
        IF v_pend > 0 THEN
          v_nuevos := v_nuevos || jsonb_build_array(jsonb_build_object('lote_id', NULL, 'cantidad', v_pend));
        END IF;
      END LOOP;
      -- En el orden en que lo anota el motor: primero la bolsa y después los lotes por
      -- vencimiento (el motor deshace del final al principio), como _barra_mover_neto.
      SELECT CASE WHEN COALESCE(sum((e->>'cantidad')::INT) FILTER (WHERE e->>'lote_id' IS NULL), 0) > 0
                  THEN jsonb_build_array(jsonb_build_object(
                         'lote_id', NULL,
                         'cantidad', sum((e->>'cantidad')::INT) FILTER (WHERE e->>'lote_id' IS NULL)))
                  ELSE '[]'::jsonb END
             || COALESCE((SELECT jsonb_agg(jsonb_build_object('lote_id', x.lote_id, 'cantidad', x.cantidad)
                                           ORDER BY l.fecha_vencimiento, l.id)
                            FROM (SELECT (y->>'lote_id')::BIGINT AS lote_id, sum((y->>'cantidad')::INT) AS cantidad
                                    FROM jsonb_array_elements(v_nuevos) y
                                   WHERE y->>'lote_id' IS NOT NULL
                                   GROUP BY 1) x
                            JOIN producto_lotes l ON l.id = x.lote_id AND l.sucursal_id = p_sucursal_id),
                         '[]'::jsonb)
        INTO v_nuevos
        FROM jsonb_array_elements(v_nuevos) e;
      IF v_nuevos IS DISTINCT FROM v_bloque.lotes_pendientes THEN
        UPDATE promo_ajustes SET lotes_pendientes = v_nuevos WHERE id = v_bloque.id;
      END IF;
    END LOOP;
  END LOOP;
END
$fn$;
REVOKE ALL ON FUNCTION public._bloques_heredan_lotes_devueltos(bigint, bigint[], bigint, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._bloques_heredan_lotes_devueltos(bigint, bigint[], bigint, jsonb) TO service_role;
COMMENT ON FUNCTION public._bloques_heredan_lotes_devueltos(bigint, bigint[], bigint, jsonb) IS
  'Edición del pedido (tanda 6 bis de #1603, LOTE-A): el bloque de la barra que la edición cerró desde la bolsa hereda el lote al que _rehacer_huella_lineas devolvió las unidades que ese bloque se comió. Sólo lo que deja la bolsa del contenedor en 0.';

-- Reemplaza un ancla que tiene que aparecer exactamente p_n veces.
CREATE FUNCTION pg_temp.parche(p_def text, p_ancla text, p_nuevo text, p_n int, p_que text)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v_n int := (length(p_def) - length(replace(p_def, p_ancla, ''))) / length(p_ancla);
BEGIN
  IF v_n <> p_n THEN
    RAISE EXCEPTION 'mig NNN · %: el ancla aparece % vez/veces y se esperaba %', p_que, v_n, p_n;
  END IF;
  RETURN replace(p_def, p_ancla, p_nuevo);
END
$f$;

-- =========================================================================
-- actualizar_pedido_items: los cuatro tramos (1, 3 y 4)
-- =========================================================================
DO $edicion$
DECLARE
  v_def text := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)'::regprocedure);
BEGIN
  -- 1 · Las variables.
  v_def := pg_temp.parche(v_def,
$a$  v_barra_primero BOOLEAN := false;
$a$,
$a$  v_barra_primero BOOLEAN := false;
  -- LOTE-A al editar (tanda 6 bis de #1603): las promos cuya barra mueve la edición, el
  -- último bloque que tenían antes y los lotes de sus contenedores antes del rehacer.
  v_barra_promos      BIGINT[] := '{}';
  v_barra_ajuste_max  BIGINT := 0;
  v_barra_lotes_antes JSONB := '{}'::jsonb;
$a$,
    1, 'actualizar_pedido_items (LOTE-A, variables)');

  -- 3 · El camino de STK-2, sólo si esta edición baja la barra de ese contenedor.
  v_def := pg_temp.parche(v_def,
$a$                                               WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
                                                 AND COALESCE(pi.es_bonificacion, false) AND pi.promocion_id IS NOT NULL
                                                 AND public._regalo_barra_vale(p_pedido_id, pi.promocion_id, v_sucursal))) THEN
          v_n_contenedor := v_n_contenedor + 1;$a$,
$a$                                               WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
                                                 AND COALESCE(pi.es_bonificacion, false) AND pi.promocion_id IS NOT NULL
                                                 AND public._regalo_barra_vale(p_pedido_id, pi.promocion_id, v_sucursal))
                      -- H-1 de la lente de H (tanda 6 bis): y sólo si ESTA edición baja la
                      -- barra de ese bloque (la de su sabor; un bloque sin anotar, la de la
                      -- promo): lo que queda del regalo, con el producto y la cantidad que van a
                      -- quedar (la misma función que el trigger y el pre-chequeo), contra lo que
                      -- el pedido tiene. Si no la baja, ninguna barra devuelve nada y va el
                      -- rechazo de siempre.
                      AND (SELECT COALESCE(SUM(x.cantidad), 0)
                             FROM (SELECT CASE WHEN e->>'_reparto' IS NOT DISTINCT FROM v_marca_reparto
                                               THEN (e->>'producto_id')::BIGINT
                                               ELSE (SELECT r.producto_id
                                                       FROM public.regalo_sustitucion_resuelta(
                                                              p_pedido_id, (e->>'promocion_id')::BIGINT, (e->>'producto_id')::BIGINT,
                                                              v_sucursal, (e->>'cantidad')::NUMERIC, (e->>'_cadena')::UUID) r)
                                          END AS producto_id,
                                          CASE WHEN e->>'_reparto' IS NOT DISTINCT FROM v_marca_reparto
                                               THEN (e->>'cantidad')::NUMERIC
                                               ELSE (SELECT r.cantidad
                                                       FROM public.regalo_sustitucion_resuelta(
                                                              p_pedido_id, (e->>'promocion_id')::BIGINT, (e->>'producto_id')::BIGINT,
                                                              v_sucursal, (e->>'cantidad')::NUMERIC, (e->>'_cadena')::UUID) r)
                                          END AS cantidad
                                     FROM jsonb_array_elements(v_items) e
                                    WHERE COALESCE((e->>'es_bonificacion')::BOOLEAN, false)
                                      AND (e->>'promocion_id')::BIGINT = pa.promocion_id) x
                            WHERE pa.barra_regalo_id IS NULL OR x.producto_id = pa.barra_regalo_id)
                          < (SELECT COALESCE(SUM(pi.cantidad), 0)
                               FROM pedido_items pi
                              WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
                                AND COALESCE(pi.es_bonificacion, false) AND pi.promocion_id = pa.promocion_id
                                AND (pa.barra_regalo_id IS NULL OR pi.producto_id = pa.barra_regalo_id))) THEN
          v_n_contenedor := v_n_contenedor + 1;$a$,
    1, 'actualizar_pedido_items (H-1, el camino de STK-2)');

  -- 4 · El mensaje del tope de la cadena nombra el regalo con el que mide.
  v_def := pg_temp.parche(v_def,
$a$        LEFT JOIN productos rg ON rg.id = (e->>'producto_id')::BIGINT AND rg.sucursal_id = v_sucursal
$a$,
$a$        -- N3 de la lente de promos (tanda 6 bis): el regalo con el que mide el tope (el que
        -- daba la promo cuando el pedido nació, _regalo_de_la_promo), no el del JSON.
        LEFT JOIN productos rg
          ON rg.id = COALESCE((SELECT d.producto_id
                                 FROM public._regalo_de_la_promo(p_pedido_id, (e->>'promocion_id')::BIGINT, v_sucursal,
                                                                 (e->>'_cadena')::UUID, (e->>'producto_id')::BIGINT,
                                                                 (e->>'cantidad')::NUMERIC) d),
                              (e->>'producto_id')::BIGINT)
         AND rg.sucursal_id = v_sucursal
$a$,
    1, 'actualizar_pedido_items (N3, el mensaje)');

  -- 1 · Antes de mover la barra: sus promos y su último bloque.
  v_def := pg_temp.parche(v_def,
$a$  PERFORM public._barra_mover_neto(
    (SELECT COALESCE(jsonb_agg(jsonb_build_object(
$a$,
$a$  -- LOTE-A al editar (tanda 6 bis de #1603): los bloques que cierre esta barra son los de
  -- id mayor de estas promos (tomadas arriba, #1460: nadie más les escribe bloques).
  v_barra_promos := ARRAY(SELECT DISTINCT split_part(k.key, ':', 1)::BIGINT
                            FROM jsonb_each_text(v_barra_neto) k
                           WHERE k.value::NUMERIC <> 0
                           ORDER BY 1);
  v_barra_ajuste_max := COALESCE((SELECT max(pa.id) FROM promo_ajustes pa
                                   WHERE pa.promocion_id = ANY(v_barra_promos) AND pa.sucursal_id = v_sucursal), 0);
  PERFORM public._barra_mover_neto(
    (SELECT COALESCE(jsonb_agg(jsonb_build_object(
$a$,
    1, 'actualizar_pedido_items (LOTE-A, antes de la barra)');

  -- 1 · El rehacer de la huella, con los lotes de antes y el helper después.
  v_def := pg_temp.parche(v_def,
$a$  IF v_foto IS NOT NULL THEN
    PERFORM public._rehacer_huella_lineas(v_foto, v_lineas_stock);
  END IF;
$a$,
$a$  -- LOTE-A al editar (tanda 6 bis de #1603): los contadores de los lotes de los
  -- contenedores de los bloques que esta edición cerró desde la bolsa, antes del rehacer.
  SELECT COALESCE(jsonb_object_agg(l.id::TEXT, l.cantidad_restante), '{}'::jsonb)
    INTO v_barra_lotes_antes
    FROM producto_lotes l
   WHERE l.sucursal_id = v_sucursal
     AND l.producto_id IN (SELECT pa.producto_id FROM promo_ajustes pa
                            WHERE pa.promocion_id = ANY(v_barra_promos) AND pa.sucursal_id = v_sucursal
                              AND pa.id > v_barra_ajuste_max
                              AND pa.lotes_pendientes @> '[{"lote_id": null}]'::jsonb);
  IF v_foto IS NOT NULL THEN
    PERFORM public._rehacer_huella_lineas(v_foto, v_lineas_stock);
  END IF;
  -- Si un bloque nuevo se comió de la bolsa lo que el rehacer le devolvió a un lote, el
  -- bloque hereda ese lote y la bolsa no queda negativa (LOTE-A).
  PERFORM public._bloques_heredan_lotes_devueltos(v_sucursal, v_barra_promos, v_barra_ajuste_max,
                                                  v_barra_lotes_antes);
$a$,
    1, 'actualizar_pedido_items (LOTE-A, después del rehacer)');

  -- 531 (B15): el CREATE OR REPLACE lleva la cláusula SET; sin ella la borraría.
  IF position(E' SET search_path TO ''public'', ''pg_temp''\n' IN v_def) = 0 THEN
    RAISE EXCEPTION 'mig NNN · actualizar_pedido_items: no encuentro su search_path';
  END IF;
  EXECUTE v_def;
END
$edicion$;

-- ---------------------------------------------------------------------------
-- Poscondiciones
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', '_bloques_heredan_lotes_devueltos(', 1),
    ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'v_barra_ajuste_max', 4),
    ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'H-1 de la lente de H', 1),
    ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'public._regalo_de_la_promo(p_pedido_id', 1),
    ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'contando lo que devuelve la barra de la promo', 1),
    ('public._bloques_heredan_lotes_devueltos(bigint,bigint[],bigint,jsonb)', 'UPDATE promo_ajustes SET lotes_pendientes', 1)
  ) AS t(f, marca, n) LOOP
    IF (SELECT (length(prosrc) - length(replace(prosrc, r.marca, ''))) / length(r.marca)
          FROM pg_proc WHERE oid = r.f::regprocedure) <> r.n THEN
      RAISE EXCEPTION 'mig NNN · el parche de % no entró (% debía aparecer % veces)', r.f, r.marca, r.n;
    END IF;
  END LOOP;
  -- El definer, el search_path con pg_temp y los permisos: la RPC como estaba (definer, del
  -- front) y el helper como los de la barra (invoker, sólo server); nada para anon.
  FOR r IN SELECT * FROM (VALUES
      ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', true, true),
      ('public._bloques_heredan_lotes_devueltos(bigint,bigint[],bigint,jsonb)', false, false)
    ) AS t(f, definer, api) LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = r.f::regprocedure
                    AND proconfig @> ARRAY['search_path=public, pg_temp'] AND prosecdef = r.definer) THEN
      RAISE EXCEPTION 'mig NNN · % quedó con otro definer o sin pg_temp en su search_path', r.f;
    END IF;
    IF has_function_privilege('anon', r.f, 'EXECUTE')
       OR has_function_privilege('authenticated', r.f, 'EXECUTE') IS DISTINCT FROM r.api THEN
      RAISE EXCEPTION 'mig NNN · los permisos de % no son los esperados', r.f;
    END IF;
  END LOOP;
END
$post$;

COMMIT;
