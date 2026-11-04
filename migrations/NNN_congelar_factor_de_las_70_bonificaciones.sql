-- NNN · Las 70 bonificaciones de abril y mayo congelan su factor (#1407).
--
-- QUÉ PASABA
--   La 212 congeló el factor de fracción de cada regalo (pedido_items.unidades_por_bloque_al_crear)
--   midiéndolo en promo_ajustes. 70 líneas nacieron antes de la primera medición exacta de su
--   promo y quedaron en NULL a propósito: no había evidencia directa. Con NULL,
--   factor_bonificacion() cae al factor de HOY de la promo, y lo mismo factorDeLaLinea en el
--   front. Si alguien edita alguna de esas cuatro promos (ModalPromocion borra el factor al
--   pasarla a unidad entera), el costo de esos regalos en Rentabilidad, en el gerencial y en
--   el reporte de bonificaciones se multiplica por 6 o por 12, y también su cifra en bloques
--   (#1363) y la de la boleta. El pasado se mueve.
--
--     promo                                                      factor  líneas  fechas
--      1 · 2 Manaos Citrus de Regalo                                 6      34   06/04 a 27/04
--     10 · 1 Fardo Placer 500 cc + 1 Botella Manaos 600 cc Naranja  12      29   20/04 a 25/04
--     12 · 1 Fardo Placer 500cc + 1 Placer Pomelo Blanco 500cc      12       6   02/05
--     13 · Promo Manaos 6 + 2 3L                                     6       1   13/05
--
-- QUÉ CAMBIA
--   · Las 70 líneas guardan el factor de hoy de su promo, que es el que ya usan hoy: ningún
--     número cambia, ni hoy ni después de editar la promo.
--   · Origen nuevo 'inferido_constante': el factor no se midió en la línea, se infiere de una
--     serie de mediciones constante. Se suma al CHECK pedido_items_origen_unidades_por_bloque_check.
--   El dueño lo aprobó el 04/11 con una condición: que no le afecte ni le distorsione los
--   datos. Por eso la migración aborta ante cualquier diferencia (pasos 0, 3 y 5).
--
-- POR QUÉ EL FACTOR DE HOY ES EL DE ENTONCES (relevado en prod el 04/11)
--   · Mediciones exactas (el criterio de la 212: |unidades_ajustadas| = 1 en un auto-ajuste,
--     una cancelación, una eliminación, una edición o una salvedad), todas iguales al de hoy:
--     promo 1: 2 (6) · promo 10: 5 (12) · promo 12: 171 (12) · promo 13: 730 (6, del 13/05
--     14:53 al 04/11; la línea es del 13/05 13:36).
--   · El cociente |usos| / |unidades| da el mismo factor en TODAS las filas de ajuste de las
--     cuatro, también en las que no son exactas (las de las promos 1 y 10 arrancan el 24/04).
--   · Las migraciones 067 y 068 escriben los factores de las promos 13 y 12 (6 y 12).
--   · Desde que promociones se audita (09/09) ninguna de las cuatro cambió unidades_por_bloque
--     ni regalo_mueve_stock. El updated_at de hoy de la promo 13 no es una edición: es el
--     último uso (auditado sólo como {updated_at}, a la misma hora que el auto-ajuste 16:46).
--   · La foto de las 70 (pedido_items.regalo_mueve_stock_foto y pedido_promo_reglas) es
--     regalo_mueve_stock = false: el modo ya estaba congelado (434, 451) y fracciona.
--
-- TRIGGERS QUE DISPARA EL UPDATE (pg_get_triggerdef de pedido_items, 04/11)
--   Sólo dos, porque las demás listas `UPDATE OF` no nombran estas columnas:
--   · audit_pedido_items (sin lista): deja 140 filas en audit_logs, dos por línea, porque el
--     factor y el origen van en dos UPDATE (ver BLOQUEO).
--   · pedido_items_proteger_columnas (sin lista): para todo current_user que no es
--     authenticated devuelve NEW sin mirar, y la migración corre como postgres.
--   Ni stock, ni lotes, ni total, ni precio, ni modo, ni límite de usos: las huellas del paso 3
--   y del paso 5 lo prueban igual.
--
-- BLOQUEO
--   Cambiar un CHECK es DROP + ADD, y el DROP toma ACCESS EXCLUSIVE sobre pedido_items hasta el
--   COMMIT. NOT VALID + VALIDATE no lo achica en una sola transacción: el lock del DROP ya está
--   tomado y el re-chequeo de ~28.000 filas tarda milisegundos. Lo que sí lo achica es el orden:
--   el factor (que el CHECK viejo ya acepta) y las dos fotos de los reportes van ANTES del
--   ALTER, con lock de filas nada más, y el ALTER y el origen van al final, con lock_timeout
--   para no hacer cola detrás de una lectura larga y trabar la app.
--
-- CÓMO SE REVIERTE (deja todo como antes de esta migración)
--   UPDATE pedido_items SET unidades_por_bloque_al_crear = NULL, origen_unidades_por_bloque = NULL
--    WHERE origen_unidades_por_bloque = 'inferido_constante';
--   y el CHECK vuelve a la lista de la 212.
-- ============================================================================

-- REPEATABLE READ: las fotos de antes y de después ven el mismo snapshot más los cambios
-- propios. En READ COMMITTED un pedido que la app crea o entrega entre las dos fotos movería
-- un reporte y el ensayo abortaría por un falso positivo. Si otra transacción edita una de
-- las 70 líneas mientras tanto, el UPDATE da 40001 y no se escribe nada: se reaplica.
BEGIN ISOLATION LEVEL REPEATABLE READ;

-- Fines de línea: se aplica en LF (git show HEAD:migrations/<archivo>), así el md5 del ledger
-- es el del archivo.
DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'mig NNN · el texto de la migración trae CRLF: aplicarla desde la versión LF (git show HEAD:migrations/<archivo>)';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- 0 · Guardas. Cualquiera que falle aborta antes de escribir nada.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _m1407_esperado (promocion_id bigint PRIMARY KEY, factor integer, lineas integer)
  ON COMMIT DROP;
INSERT INTO _m1407_esperado VALUES (1, 6, 34), (10, 12, 29), (12, 12, 6), (13, 6, 1);

-- Las líneas a tocar: toda bonificación sin factor. Tienen que ser exactamente las 70.
CREATE TEMP TABLE _m1407_lineas ON COMMIT DROP AS
SELECT pi.id, pi.pedido_id, pi.promocion_id, pi.origen_unidades_por_bloque,
       pi.regalo_mueve_stock_foto,
       public.factor_bonificacion(pi.unidades_por_bloque_al_crear, pr.regalo_mueve_stock,
                                  pr.unidades_por_bloque)            AS factor_antes_promo,
       public.factor_bonificacion(pi.unidades_por_bloque_al_crear, pi.regalo_mueve_stock_foto,
                                  pr.unidades_por_bloque)            AS factor_antes_foto
  FROM pedido_items pi
  LEFT JOIN promociones pr ON pr.id = pi.promocion_id
 WHERE pi.es_bonificacion
   AND pi.unidades_por_bloque_al_crear IS NULL;

DO $guardas$
DECLARE
  v_n     integer;
  v_det   text;
BEGIN
  -- 70 líneas, repartidas como se relevó.
  SELECT count(*) INTO v_n FROM _m1407_lineas;
  IF v_n <> 70 THEN
    RAISE EXCEPTION 'mig NNN · hay % bonificaciones sin factor, se esperaban 70', v_n;
  END IF;

  SELECT string_agg(format('promo %s: %s líneas (esperadas %s)', coalesce(l.promocion_id, e.promocion_id),
                           coalesce(l.n, 0), coalesce(e.lineas, 0)), '; ')
    INTO v_det
    FROM (SELECT promocion_id, count(*)::int AS n FROM _m1407_lineas GROUP BY 1) l
    FULL JOIN _m1407_esperado e ON e.promocion_id = l.promocion_id
   WHERE l.n IS DISTINCT FROM e.lineas;
  IF v_det IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · el reparto por promo cambió: %', v_det;
  END IF;

  IF EXISTS (SELECT 1 FROM _m1407_lineas WHERE origen_unidades_por_bloque IS NOT NULL) THEN
    RAISE EXCEPTION 'mig NNN · alguna de las 70 ya tiene origen de factor';
  END IF;

  -- Cada promo sigue fraccionando, con el factor relevado.
  SELECT string_agg(format('promo %s: regalo_mueve_stock %s, unidades_por_bloque %s (esperado %s)',
                           e.promocion_id, coalesce(p.regalo_mueve_stock::text, 'NULL'),
                           coalesce(p.unidades_por_bloque::text, 'NULL'), e.factor), '; ')
    INTO v_det
    FROM _m1407_esperado e
    LEFT JOIN promociones p ON p.id = e.promocion_id
   WHERE p.regalo_mueve_stock IS DISTINCT FROM false
      OR p.unidades_por_bloque IS DISTINCT FROM e.factor;
  IF v_det IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · una promo dejó de fraccionar o cambió de factor: %', v_det;
  END IF;

  -- Ninguna medición exacta (criterio de la 212) contradice el factor, y cada promo tiene al
  -- menos una: sin medición no hay de dónde inferir.
  SELECT string_agg(format('promo %s: %s exactas, %s distintas de %s',
                           m.promocion_id, m.n, m.malas, m.factor), '; ')
    INTO v_det
    FROM (SELECT e.promocion_id, e.factor, count(a.id) AS n,
                 count(a.id) FILTER (WHERE abs(a.usos_ajustados) <> e.factor) AS malas
            FROM _m1407_esperado e
            LEFT JOIN promo_ajustes a
              ON a.promocion_id = e.promocion_id
             AND abs(a.unidades_ajustadas) = 1
             AND (a.observaciones LIKE 'Auto-ajuste%'
               OR a.observaciones LIKE 'Cancelacion pedido #%'
               OR a.observaciones LIKE 'Eliminacion pedido #%'
               OR a.observaciones LIKE 'Edicion pedido #%'
               OR a.observaciones LIKE 'Salvedad%')
           GROUP BY e.promocion_id, e.factor) m
   WHERE m.n = 0 OR m.malas > 0;
  IF v_det IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · las mediciones exactas no sostienen el factor: %', v_det;
  END IF;

  -- Desde que promociones se audita, ninguna de las cuatro cambió de factor ni de modo.
  SELECT string_agg(format('promo %s el %s: %s', a.registro_id, a.created_at, a.campos_modificados), '; ')
    INTO v_det
    FROM audit_logs a
   WHERE a.tabla = 'promociones'
     AND a.registro_id IN (SELECT promocion_id::text FROM _m1407_esperado)
     AND a.campos_modificados && ARRAY['unidades_por_bloque', 'regalo_mueve_stock', 'stock_por_bloque'];
  IF v_det IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · una de las promos cambió de factor o de modo: %', v_det;
  END IF;

  -- La foto de cada línea dice que el regalo fracciona: en la columna y en pedido_promo_reglas.
  SELECT count(*) INTO v_n
    FROM _m1407_lineas l
   WHERE l.regalo_mueve_stock_foto IS DISTINCT FROM false
      OR NOT EXISTS (SELECT 1 FROM pedido_promo_reglas ppr
                      WHERE ppr.pedido_id = l.pedido_id
                        AND ppr.promocion_id = l.promocion_id
                        AND ppr.regalo_mueve_stock IS FALSE);
  IF v_n > 0 THEN
    RAISE EXCEPTION 'mig NNN · % línea(s) sin foto regalo_mueve_stock = false', v_n;
  END IF;

  -- Hoy cada línea ya usa ese factor, por la promo y por la foto. Si no, congelar cambiaría
  -- un número.
  SELECT count(*) INTO v_n
    FROM _m1407_lineas l JOIN _m1407_esperado e USING (promocion_id)
   WHERE l.factor_antes_promo <> e.factor OR l.factor_antes_foto <> e.factor;
  IF v_n > 0 THEN
    RAISE EXCEPTION 'mig NNN · % línea(s) no usan hoy el factor que se les congelaría', v_n;
  END IF;
END
$guardas$;

-- ---------------------------------------------------------------------------
-- 1 · Andamio del ensayo (molde: la 318). Todo en pg_temp; se borra al final.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _m1407_foto (
  etapa  text   NOT NULL,          -- 'antes' | 'despues' | 'final'
  fn     text   NOT NULL,
  rango  text   NOT NULL DEFAULT '',
  suc    bigint,                   -- NULL = Red
  extra  text   NOT NULL DEFAULT '',
  valor  jsonb
) ON COMMIT DROP;

-- Normaliza un jsonb para comparar contenido y no orden (copia de _vb_norm, 318).
CREATE FUNCTION pg_temp._m1407_norm(j jsonb) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $f$
DECLARE
  r jsonb;
BEGIN
  CASE jsonb_typeof(j)
    WHEN 'object' THEN
      SELECT COALESCE(jsonb_object_agg(e.k, pg_temp._m1407_norm(e.v)), '{}'::jsonb)
        INTO r FROM jsonb_each(j) AS e(k, v);
    WHEN 'array' THEN
      SELECT COALESCE(jsonb_agg(s.x ORDER BY s.x::text), '[]'::jsonb)
        INTO r FROM (SELECT pg_temp._m1407_norm(a.v) AS x
                       FROM jsonb_array_elements(j) AS a(v)) s;
    ELSE
      r := j;
  END CASE;
  RETURN r;
END
$f$;

-- Huellas de la plata y del stock: tabla entera, fila por fila. pedido_items va sin las dos
-- columnas que esta migración escribe; todo lo demás de la línea tiene que quedar igual.
CREATE FUNCTION pg_temp._m1407_huellas(p_etapa text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  INSERT INTO _m1407_foto (etapa, fn, valor)
  SELECT p_etapa, 'huella:pedidos',
         to_jsonb(md5(COALESCE(string_agg(to_jsonb(t)::text, E'\n' ORDER BY t.id), '')))
    FROM pedidos t
  UNION ALL
  SELECT p_etapa, 'huella:pedido_items',
         to_jsonb(md5(COALESCE(string_agg((to_jsonb(t) - 'unidades_por_bloque_al_crear'
                                                         - 'origen_unidades_por_bloque')::text,
                                           E'\n' ORDER BY t.id), '')))
    FROM pedido_items t
  UNION ALL
  SELECT p_etapa, 'huella:pagos',
         to_jsonb(md5(COALESCE(string_agg(to_jsonb(t)::text, E'\n' ORDER BY t.id), '')))
    FROM pagos t
  UNION ALL
  SELECT p_etapa, 'huella:clientes',
         to_jsonb(md5(COALESCE(string_agg(to_jsonb(t)::text, E'\n' ORDER BY t.id), '')))
    FROM clientes t
  UNION ALL
  SELECT p_etapa, 'huella:productos',
         to_jsonb(md5(COALESCE(string_agg(to_jsonb(t)::text, E'\n' ORDER BY t.id), '')))
    FROM productos t
  UNION ALL
  SELECT p_etapa, 'huella:producto_lotes',
         to_jsonb(md5(COALESCE(string_agg(to_jsonb(t)::text, E'\n' ORDER BY t.id), '')))
    FROM producto_lotes t
  UNION ALL
  SELECT p_etapa, 'huella:promociones',
         to_jsonb(md5(COALESCE(string_agg(to_jsonb(t)::text, E'\n' ORDER BY t.id), '')))
    FROM promociones t
  UNION ALL
  SELECT p_etapa, 'huella:stock_historico', to_jsonb(count(*)::text || '/' || COALESCE(max(id), 0)::text)
    FROM stock_historico
  UNION ALL
  SELECT p_etapa, 'huella:promo_ajustes', to_jsonb(count(*)::text || '/' || COALESCE(max(id), 0)::text)
    FROM promo_ajustes;
END
$f$;

-- Los reportes que leen el factor (pg_get_functiondef ~ 'factor_bonificacion' o
-- 'unidades_por_bloque_al_crear', 04/11): reporte_gerencial, reporte_rentabilidad (con los
-- bloques de #1363) y reporte_bonificaciones. hojas_de_ruta_deposito también lo lee, pero sólo
-- de los pedidos de un recorrido o pendientes, y ninguno de los 70 pedidos está en un
-- recorrido ni pendiente. Las demás que lo nombran escriben líneas (edición, dividir,
-- sustituir, partir combo) y no corren acá.
-- Corre como el admin con más sucursales activas (como la 241 y la 318), por Red y por cada
-- sucursal suya, en abril, en mayo y en los dos meses juntos (las 70 son del 06/04 al 13/05).
CREATE FUNCTION pg_temp._m1407_fotografiar(p_etapa text) RETURNS integer
LANGUAGE plpgsql AS $f$
DECLARE
  v_admin   uuid;
  v_claims  text := current_setting('request.jwt.claims', true);
  v_r       record;
  v_suc     bigint;
  v_n       integer;
BEGIN
  SELECT us.usuario_id INTO v_admin
    FROM usuario_sucursales us
    JOIN perfiles pf   ON pf.id = us.usuario_id AND pf.rol = 'admin'
    JOIN sucursales s  ON s.id = us.sucursal_id AND s.activa
   GROUP BY us.usuario_id
   ORDER BY count(*) DESC, us.usuario_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'mig NNN · el ensayo necesita un admin con al menos una sucursal activa asignada';
  END IF;
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  FOR v_r IN
    SELECT * FROM (VALUES
      ('abril',     DATE '2026-04-01', DATE '2026-04-30'),
      ('mayo',      DATE '2026-05-01', DATE '2026-05-31'),
      ('abril_mayo', DATE '2026-04-01', DATE '2026-05-31')
    ) AS t(rango, desde, hasta)
  LOOP
    FOR v_suc IN
      SELECT NULL::bigint
      UNION ALL
      (SELECT s.id FROM sucursales s
         JOIN usuario_sucursales us ON us.sucursal_id = s.id AND us.usuario_id = v_admin
        WHERE s.activa ORDER BY s.id)
    LOOP
      INSERT INTO _m1407_foto (etapa, fn, rango, suc, extra, valor) VALUES
        (p_etapa, 'reporte_gerencial', v_r.rango, v_suc, 'comparar',
           public.reporte_gerencial(v_suc, v_r.desde, v_r.hasta, false, true)),
        (p_etapa, 'reporte_gerencial', v_r.rango, v_suc, 'no_entregados',
           public.reporte_gerencial(v_suc, v_r.desde, v_r.hasta, true, false)),
        (p_etapa, 'reporte_rentabilidad', v_r.rango, v_suc, 'incluir',
           public.reporte_rentabilidad(v_r.desde, v_r.hasta, v_suc, 'incluir')),
        (p_etapa, 'reporte_bonificaciones', v_r.rango, v_suc, '',
           public.reporte_bonificaciones(v_r.desde, v_r.hasta, v_suc, 100000));
    END LOOP;
  END LOOP;

  PERFORM set_config('request.jwt.claims', COALESCE(v_claims, ''), true);

  SELECT count(*) INTO v_n FROM _m1407_foto WHERE etapa = p_etapa;
  RETURN v_n;
END
$f$;

-- Compara una etapa contra 'antes'. Cada foto tiene su par y son idénticas.
CREATE FUNCTION pg_temp._m1407_comparar(p_etapa text, p_solo_huellas boolean) RETURNS integer
LANGUAGE plpgsql AS $f$
DECLARE
  v_n      integer;
  v_fallas text;
BEGIN
  SELECT count(*) INTO v_n
    FROM (SELECT * FROM _m1407_foto WHERE etapa = 'antes'
            AND (NOT p_solo_huellas OR fn LIKE 'huella:%')) a
    FULL JOIN (SELECT * FROM _m1407_foto WHERE etapa = p_etapa) d
      ON d.fn = a.fn AND d.rango = a.rango AND d.suc IS NOT DISTINCT FROM a.suc AND d.extra = a.extra
   WHERE a.fn IS NULL OR d.fn IS NULL;
  IF v_n > 0 THEN
    RAISE EXCEPTION 'mig NNN · las fotos de antes y de % no tienen las mismas llamadas (% sin par)', p_etapa, v_n;
  END IF;

  SELECT count(*), string_agg(format('%s %s suc %s %s', a.fn, a.rango, coalesce(a.suc::text, 'Red'), a.extra), '; ')
    INTO v_n, v_fallas
    FROM _m1407_foto a
    JOIN _m1407_foto d
      ON d.etapa = p_etapa AND d.fn = a.fn AND d.rango = a.rango
     AND d.suc IS NOT DISTINCT FROM a.suc AND d.extra = a.extra
   WHERE a.etapa = 'antes'
     AND pg_temp._m1407_norm(a.valor) IS DISTINCT FROM pg_temp._m1407_norm(d.valor);
  IF v_n > 0 THEN
    RAISE EXCEPTION 'mig NNN · ensayo: % llamada(s) cambiaron entre antes y %: %', v_n, p_etapa, v_fallas;
  END IF;

  SELECT count(*) INTO v_n FROM _m1407_foto WHERE etapa = p_etapa;
  RETURN v_n;
END
$f$;

SELECT pg_temp._m1407_fotografiar('antes');
SELECT pg_temp._m1407_huellas('antes');

-- ---------------------------------------------------------------------------
-- 2 · El factor. El CHECK de unidades_por_bloque_al_crear (>= 1) ya lo acepta; el origen
--     va en el paso 4, con el CHECK nuevo.
-- ---------------------------------------------------------------------------
DO $factor$
DECLARE
  v_n integer;
BEGIN
  UPDATE pedido_items pi
     SET unidades_por_bloque_al_crear = e.factor
    FROM _m1407_lineas l
    JOIN _m1407_esperado e USING (promocion_id)
   WHERE pi.id = l.id
     AND pi.unidades_por_bloque_al_crear IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 70 THEN
    RAISE EXCEPTION 'mig NNN · el UPDATE del factor tocó % líneas, se esperaban 70', v_n;
  END IF;
END
$factor$;

-- ---------------------------------------------------------------------------
-- 3 · El ensayo: los tres reportes y las huellas, idénticos a los de antes. Y cada línea lee
--     con el factor congelado lo mismo que leía con el de la promo y con el de la foto, que
--     es la cascada de factor_bonificacion y de factorDeLaLinea en la boleta.
-- ---------------------------------------------------------------------------
SELECT pg_temp._m1407_fotografiar('despues');
SELECT pg_temp._m1407_huellas('despues');

DO $ensayo$
DECLARE
  v_n      integer;
  v_llam   integer;
BEGIN
  v_llam := pg_temp._m1407_comparar('despues', false);

  SELECT count(*) INTO v_n
    FROM _m1407_lineas l
    JOIN pedido_items pi ON pi.id = l.id
    JOIN promociones pr  ON pr.id = pi.promocion_id
   WHERE public.factor_bonificacion(pi.unidades_por_bloque_al_crear, pr.regalo_mueve_stock, pr.unidades_por_bloque)
           IS DISTINCT FROM l.factor_antes_promo
      OR public.factor_bonificacion(pi.unidades_por_bloque_al_crear, pi.regalo_mueve_stock_foto, pr.unidades_por_bloque)
           IS DISTINCT FROM l.factor_antes_foto
      -- y ya no depende de la promo: con la promo pasada a unidad entera da lo mismo.
      OR public.factor_bonificacion(pi.unidades_por_bloque_al_crear, true, NULL)
           IS DISTINCT FROM l.factor_antes_foto;
  IF v_n > 0 THEN
    RAISE EXCEPTION 'mig NNN · ensayo: % línea(s) cambian de factor', v_n;
  END IF;

  -- Red y al menos una sucursal: 3 rangos × 2 × 4 llamadas, más las 9 huellas.
  IF v_llam < 33 THEN
    RAISE EXCEPTION 'mig NNN · el ensayo comparó sólo % fotos: algo no se fotografió', v_llam;
  END IF;

  RAISE NOTICE 'mig NNN · ensayo OK: % fotos (reportes y huellas) idénticas antes y después; las 70 líneas leen el mismo factor', v_llam;
END
$ensayo$;

-- ---------------------------------------------------------------------------
-- 4 · El origen nuevo. El ALTER va acá, al final, para que el ACCESS EXCLUSIVE dure lo
--     menos posible (ver BLOQUEO). Si no consigue el lock en 5 s aborta todo y se reaplica.
-- ---------------------------------------------------------------------------
SET LOCAL lock_timeout = '5s';

ALTER TABLE public.pedido_items
  DROP CONSTRAINT pedido_items_origen_unidades_por_bloque_check,
  ADD CONSTRAINT pedido_items_origen_unidades_por_bloque_check
    CHECK (origen_unidades_por_bloque IS NULL OR origen_unidades_por_bloque IN (
      'vivo', 'medido_constante', 'sin_fraccion', 'sin_promo', 'inferido_constante'
    ));

COMMENT ON COLUMN public.pedido_items.origen_unidades_por_bloque IS
  'De donde salio el factor. vivo = lo escribio el trigger al insertar. '
  'medido_constante = reconstruido por la mig 212 desde promo_ajustes, con serie '
  'constante e igual al valor vivo. inferido_constante = linea anterior a la primera '
  'medicion de su promo, congelada con el factor de esa serie constante (#1407). '
  'sin_fraccion = promo que nunca fracciono. sin_promo = bonificacion sin promocion_id. '
  'NULL = no reconstruible.';

DO $origen$
DECLARE
  v_n integer;
BEGIN
  UPDATE pedido_items pi
     SET origen_unidades_por_bloque = 'inferido_constante'
    FROM _m1407_lineas l
   WHERE pi.id = l.id
     AND pi.origen_unidades_por_bloque IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 70 THEN
    RAISE EXCEPTION 'mig NNN · el UPDATE del origen tocó % líneas, se esperaban 70', v_n;
  END IF;
END
$origen$;

-- ---------------------------------------------------------------------------
-- 5 · Verificación final: las 70 quedaron con su factor y su origen, no queda ninguna
--     bonificación sin factor, el CHECK quedó validado, y la plata y el stock siguen igual
--     después del segundo UPDATE.
-- ---------------------------------------------------------------------------
SELECT pg_temp._m1407_huellas('final');

DO $verif$
DECLARE
  v_n integer;
BEGIN
  PERFORM pg_temp._m1407_comparar('final', true);

  SELECT count(*) INTO v_n
    FROM _m1407_lineas l
    JOIN _m1407_esperado e USING (promocion_id)
    JOIN pedido_items pi ON pi.id = l.id
   WHERE pi.unidades_por_bloque_al_crear = e.factor
     AND pi.origen_unidades_por_bloque = 'inferido_constante';
  IF v_n <> 70 THEN
    RAISE EXCEPTION 'mig NNN · quedaron % líneas congeladas como se esperaba, no 70', v_n;
  END IF;

  SELECT count(*) INTO v_n
    FROM pedido_items WHERE es_bonificacion AND unidades_por_bloque_al_crear IS NULL;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'mig NNN · quedan % bonificaciones sin factor', v_n;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.pedido_items'::regclass
                    AND conname = 'pedido_items_origen_unidades_por_bloque_check'
                    AND convalidated
                    AND pg_get_constraintdef(oid) LIKE '%inferido_constante%') THEN
    RAISE EXCEPTION 'mig NNN · el CHECK del origen no quedó validado con inferido_constante';
  END IF;

  RAISE NOTICE 'mig NNN OK: 70 bonificaciones congeladas (34 de la promo 1, 29 de la 10, 6 de la 12, 1 de la 13); plata y stock sin cambios';
END
$verif$;

DROP FUNCTION pg_temp._m1407_fotografiar(text);
DROP FUNCTION pg_temp._m1407_comparar(text, boolean);
DROP FUNCTION pg_temp._m1407_huellas(text);
DROP FUNCTION pg_temp._m1407_norm(jsonb);

COMMIT;
