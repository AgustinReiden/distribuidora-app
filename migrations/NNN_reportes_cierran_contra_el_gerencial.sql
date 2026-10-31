-- ============================================================================
-- NNN · Rentabilidad y las ventas por vendedor cierran contra el gerencial (#1297)
-- ============================================================================
-- Tarjeta 5 del plan #1306 (reportes). Aplicar desde el contenido LF.
-- Ensayo: scripts/test-reportes-cierran-1297.sql.
--
-- QUÉ ES ESTO
-- -----------
-- REP-N1 · `reporte_rentabilidad` costeaba un regalo fraccionado entero:
--   cantidad * costo. `reporte_gerencial` lo divide por `factor_bonificacion`
--   desde la 227 (la cantidad de esa línea son partes de un bloque, no bloques).
--   Rentabilidad divide igual, así `costos` es cmv + bonif del gerencial. Una
--   línea sin costo sigue dando NULL y sigue marcada `sinCosto`.
-- REP-N2 · `rendimiento_preventistas` dejaba afuera los pedidos sin `usuario_id`,
--   que sí son venta (la regla de la 410: van como "(sin vendedor)"). Ahora la
--   fila existe sólo cuando hay un pedido así en el mes, con `preventista_id`
--   NULL. Por eso los cruces por usuario pasan a `IS NOT DISTINCT FROM`: con `=`
--   la fila quedaba en cero. Sigue sin metas: `metas` es por preventista. Y el
--   avance pasa de un WHERE a un CASE: el LATERAL se aplana y la función se
--   evaluaba igual, y `avance_metas_preventista(NULL, ...)` es "el usuario
--   logueado" (como servidor, 42501 "Sin usuario"; lo encontró el ensayo).
-- `reporte_ventas_por_preventista` tenía la misma diferencia, con el mismo
--   pedido: filtraba `usuario_id IS NOT NULL`. Ahora trae la fila, con `id` NULL.
--   `bot_ventas_por_preventista` la recibe tal cual, sin cambios: `(x->>'id')::uuid`
--   da NULL, entra en `total_todos_los_roles`, y con `solo_preventistas` queda en
--   `excluidos`, que es lo que el bot le cuenta al usuario.
--
-- ANTES → DESPUÉS (prod, 2026-10-31)
--   Rentabilidad, Red, 2026: costosTotales 221.679.232,29 → 189.602.146,53, que
--     es cmv + bonif del gerencial. El margen pasa de 22,6% a 33,8%.
--   Rendimiento, Red, marzo: venta 10.012.245 → 10.087.645, la del gerencial.
--   Por preventista, Red, 2026: 286.366.952,48 → 286.442.352,48, la del gerencial.
--   La diferencia en los dos últimos son los 75.400 de los pedidos 872 y 904.
--
-- `venta_sin_costo` no cambia, y `margen_comercial` tampoco para quien ya tenía
-- fila: el rendimiento deja esa venta fuera del margen, y el gerencial la cuenta
-- a costo 0. Por eso margen + venta_sin_costo = margen del gerencial, y lo mira
-- el ensayo. La pantalla lo avisa (#1289).
--
-- Parcheadas por ancla sobre el cuerpo vivo, con md5 antes y después (molde de la
-- 423). No tocan reporte_gerencial, costo_valuacion ni factor_bonificacion.

DO $parche$
DECLARE
  r      record;
  v_par  text[];
  v_src  text;
  v_def  text;
  v_fin  text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('public.reporte_rentabilidad(date,date,bigint,text)', '775b0dea93f7348e284b0a89b4673bbb',
       ARRAY[
         [$v$prod.costo_real, prod.costo_sin_iva, prod.impuestos_internos) AS costo$v$,
          $n$prod.costo_real, prod.costo_sin_iva, prod.impuestos_internos)
             -- #1297 (REP-N1): el regalo se divide como en reporte_gerencial (227),
             -- así costos = cmv + bonif. El factor es >= 1 y NULL sigue siendo NULL.
             / CASE WHEN pi.es_bonificacion
                    THEN public.factor_bonificacion(pi.unidades_por_bloque_al_crear,
                           pr.regalo_mueve_stock, pr.unidades_por_bloque)
                    ELSE 1 END AS costo$n$],
         [$v$LEFT JOIN productos prod ON prod.id = pi.producto_id  -- #1262 (REP-1)$v$,
          $n$LEFT JOIN productos prod ON prod.id = pi.producto_id  -- #1262 (REP-1)
    LEFT JOIN promociones pr ON pr.id = pi.promocion_id$n$]
       ]::text[]),
      ('public.rendimiento_preventistas(bigint,date)', 'e7ca54a5699a53c4de4bb6e3d070591e',
       ARRAY[
         [$v$SELECT usuario_id FROM ped WHERE usuario_id IS NOT NULL$v$,
          $n$-- #1297 (REP-N2): un pedido sin usuario_id es venta. El NULL es la fila
    -- "(sin vendedor)", y por eso los cruces son con IS NOT DISTINCT FROM.
    SELECT usuario_id FROM ped$n$],
         [$v$FROM gente g LEFT JOIN ped p ON p.usuario_id = g.usuario_id$v$,
          $n$FROM gente g LEFT JOIN ped p ON p.usuario_id IS NOT DISTINCT FROM g.usuario_id$n$],
         [$v$'nombre', COALESCE(pf.nombre, '(sin perfil)'),$v$,
          $n$'nombre', CASE WHEN b.usuario_id IS NULL THEN '(sin vendedor)'
                       ELSE COALESCE(pf.nombre, '(sin perfil)') END,$n$],
         [$v$LEFT JOIN items i         ON i.usuario_id = b.usuario_id$v$,
          $n$LEFT JOIN items i         ON i.usuario_id IS NOT DISTINCT FROM b.usuario_id$n$],
         [$v$LEFT JOIN nuevos n        ON n.usuario_id = b.usuario_id$v$,
          $n$LEFT JOIN nuevos n        ON n.usuario_id IS NOT DISTINCT FROM b.usuario_id$n$],
         [$v$LEFT JOIN por_marca pm    ON pm.usuario_id = b.usuario_id$v$,
          $n$LEFT JOIN por_marca pm    ON pm.usuario_id IS NOT DISTINCT FROM b.usuario_id$n$],
         [$v$LEFT JOIN por_categoria pc ON pc.usuario_id = b.usuario_id$v$,
          $n$LEFT JOIN por_categoria pc ON pc.usuario_id IS NOT DISTINCT FROM b.usuario_id$n$],
         [$v$SELECT avance_metas_preventista(b.usuario_id, v_periodo) AS detalle
    WHERE mt.total > 0$v$,
          $n$-- #1297: CASE y no WHERE. El planner aplana este LATERAL y evalúa la función
    -- antes del filtro: en la fila "(sin vendedor)" la llamaría con NULL, y el
    -- NULL es "el usuario logueado".
    SELECT CASE WHEN mt.total > 0
                THEN avance_metas_preventista(b.usuario_id, v_periodo) END AS detalle$n$]
       ]::text[]),
      ('public.reporte_ventas_por_preventista(date,date,bigint)', '5193fa82a241110a8ae73526dca70841',
       ARRAY[
         [$v$      AND p.usuario_id IS NOT NULL$v$,
          $n$      -- #1297: un pedido sin usuario_id también es venta: va como "(sin vendedor)".$n$],
         [$v$'nombre',            COALESCE(pf.nombre, 'Usuario desconocido'),$v$,
          $n$'nombre',            CASE WHEN pu.usuario_id IS NULL THEN '(sin vendedor)'
                                ELSE COALESCE(pf.nombre, 'Usuario desconocido') END,$n$]
       ]::text[])
    ) AS v(firma, md5, cambios)
  LOOP
    SELECT prosrc INTO v_src FROM pg_proc WHERE oid = to_regprocedure(r.firma);
    IF v_src IS NULL OR md5(v_src) <> r.md5 THEN
      RAISE EXCEPTION '% no es la de prod del 2026-10-31: rehacer el parche sobre la definicion viva', r.firma;
    END IF;
    v_def := pg_get_functiondef(to_regprocedure(r.firma));
    v_fin := v_src;
    FOREACH v_par SLICE 1 IN ARRAY r.cambios LOOP
      IF (length(v_src) - length(replace(v_src, v_par[1], ''))) / length(v_par[1]) <> 1 THEN
        RAISE EXCEPTION '% no tiene una sola vez el ancla: %', r.firma, v_par[1];
      END IF;
      v_def := replace(v_def, v_par[1], v_par[2]);
      v_fin := replace(v_fin, v_par[1], v_par[2]);
    END LOOP;
    EXECUTE v_def;
    IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure(r.firma)) <> md5(v_fin) THEN
      RAISE EXCEPTION 'el parche de % cambio algo mas que sus anclas', r.firma;
    END IF;
    -- CREATE OR REPLACE conserva los permisos y el SECURITY DEFINER: se miran igual.
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure(r.firma))
       OR has_function_privilege('anon', r.firma, 'EXECUTE')
       OR NOT has_function_privilege('authenticated', r.firma, 'EXECUTE') THEN
      RAISE EXCEPTION '% quedo con otros permisos', r.firma;
    END IF;
  END LOOP;
END
$parche$;
