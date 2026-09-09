-- Congelar POR ITEM el factor de fraccion de las bonificaciones
--
-- EL BUG
-- ------
-- reporte_gerencial valoriza el costo de un regalo dividiendo por
-- `promociones.unidades_por_bloque` leido EN VIVO (CTE `it`, via
-- LEFT JOIN promociones pr ON pr.id = pi.promocion_id). pedido_items no congela
-- ese factor, asi que editar la promo hoy reescribe el costo de todas sus
-- bonificaciones historicas.
--
-- Y no es solo el divisor: el GATE tambien es lectura viva
-- (`pr.regalo_mueve_stock IS FALSE AND ...`). ModalPromocion.tsx flipea
-- `regalo_mueve_stock` y nulea `unidades_por_bloque` JUNTOS en un mismo guardado,
-- asi que congelar solo el divisor deja abierto el caso peor: un flip de
-- false -> true MULTIPLICA por 6 o por 12 el costo de todas las bonificaciones
-- historicas de esa promo. Por eso se congela UN SOLO numero que colapsa gate y
-- divisor: 1 = no fraccionar, >1 = dividir, NULL = no reconstruible.
--
-- EL HISTORICO SE RECONSTRUYE, NO SE CONGELA "CON EL VALOR DE HOY PORQUE SI"
-- ------------------------------------------------------------------------
-- No hay historial de promociones: `audit_log_changes` cubre 11 tablas y
-- `promociones` no esta, y `promociones.updated_at` NO es fecha de edicion sino
-- de ULTIMO USO (el trigger no tiene UPDATE OF ni WHEN, y crear_pedido_completo
-- bumpea la fila en cada bonificacion). Tampoco sirve el cociente compra/regalo
-- del pedido: `unidades_por_bloque` no participa de la formula del regalo, son
-- parametros desacoplados (la promo 12 tiene regla 1->1 y factor 12).
--
-- La fuente que SI sirve es `promo_ajustes`. La mig 132 inserta
--   usos_ajustados     = bloques * unidades_por_bloque
--   unidades_ajustadas = bloques * stock_por_bloque
-- con los dos parametros leidos EN VIVO en ese instante. Como `bloques` y
-- `stock_por_bloque` son enteros >= 1, toda fila con |unidades_ajustadas| = 1
-- fuerza bloques = 1 y stock_por_bloque = 1, y entonces |usos_ajustados| ES el
-- `unidades_por_bloque` exacto de ese momento. Es una MEDICION, no una
-- inferencia. Las reversiones usan la misma aritmetica con signo invertido, asi
-- que el ABS las vuelve mediciones validas fechadas al momento de revertir.
--
-- Se toman solo las filas cuyo `observaciones` prueba que el numero salio de una
-- lectura viva: 'Auto-ajuste%' (alta web y bot, edicion), 'Cancelacion pedido #%',
-- 'Eliminacion pedido #%', 'Edicion pedido #%', 'Salvedad%'. Queda afuera el
-- resto, que NO mide nada: las de `sustitucion:%` usan el valor CONGELADO del
-- acumulador (aplicar_uso_promo_acumulador, mig 091) y las de 'Correccion%' /
-- 'Migracion retroactiva%' son numeros tipeados a mano en una migracion.
-- Por el mismo motivo NO se backfillea desde `promo_acumuladores`: ningun camino
-- de creacion de items lo lee -- crear_pedido_completo, el bot y
-- actualizar_pedido_items leen `promociones` en vivo -- asi que copiar de ahi
-- escribiria numeros equivocados. Es testigo secundario, no fuente.
--
-- RESULTADO DE LA RECONSTRUCCION (prod, 2026-09-09): CERO ESCALONES.
-- Las 5 promos que fraccionan tienen UN SOLO valor en toda su historia, igual al
-- vivo de hoy. min = max = valor vivo en las 651 mediciones exactas:
--   promo 13 "Promo Manaos 6 + 2 3L"           factor  6, 446 exactas, 13/05 a 08/09
--   promo 12 "1 Fardo Placer 500cc + Pomelo"   factor 12, 171 exactas, 04/05 a 25/08
--   promo 11 "1 Fardo 3L + 2 Granadina"        factor  6,  27 exactas, 02/05 a 13/05
--   promo 10 "1 Fardo Placer + Manaos 600"     factor 12,   5 exactas, 27/04 a 03/05
--   promo  1 "2 Manaos Citrus de Regalo"       factor  6,   2 exactas, 29/04 a 05/05
-- Corroboracion independiente: el cociente |usos| / |unidades| da el mismo factor
-- en TODAS las filas de esas promos, tambien en las no exactas y en las excluidas
-- (-102/-17 = 6, -96/-16 = 6, 72/12 = 6, 84/7 = 12). Y dentro de las propias
-- migraciones: la 067 dice "modo fraccion: 6 botellas regaladas = 1 fardo"
-- (promo 13) y la 068 "1 fardo cada 12 botellas" (promo 12).
-- Las promos con regalo_mueve_stock = true (9, 14, 15, 16, 17, 18, 19) tienen
-- CERO filas en promo_ajustes y CERO en promo_acumuladores: nunca fraccionaron.
--
-- COBERTURA: 1.313 items bonificados. 1.243 se resuelven (1.093 medidos,
-- 150 sin fraccion). Los 70 restantes caen ANTES de la primera medicion de su
-- promo (34 de la promo 1, 29 de la 10, 6 de la 12, 1 de la 13) y NO son
-- reconstruibles por medicion: quedan en NULL A PROPOSITO. Para esas filas
-- `factor_bonificacion` cae al valor vivo, que es exactamente lo que hace el
-- reporte hoy. Ninguna fila empeora.
--
-- COMO SE REVIERTE: no hace falta despatchear reporte_gerencial. Con las dos
-- columnas en NULL y el trigger dado de baja, `factor_bonificacion` cae siempre
-- al valor vivo y el reporte se comporta igual que antes de esta migracion:
--   DROP TRIGGER trg_completar_unidades_por_bloque_item ON pedido_items;
--   UPDATE pedido_items SET unidades_por_bloque_al_crear = NULL,
--          origen_unidades_por_bloque = NULL
--    WHERE origen_unidades_por_bloque IS NOT NULL;
--
-- NOTA: el UPDATE del backfill dispara audit_pedido_items, que no tiene lista de
-- columnas, asi que deja ~1.250 filas nuevas en audit_logs. No bloquea nada; la
-- mig 202 hizo lo mismo con ~7.000.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1 · Las columnas
-- -------------------------------------------------------------------------
ALTER TABLE public.pedido_items
  ADD COLUMN IF NOT EXISTS unidades_por_bloque_al_crear integer,
  ADD COLUMN IF NOT EXISTS origen_unidades_por_bloque   varchar(20);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'pedido_items_unidades_por_bloque_al_crear_check') THEN
    ALTER TABLE public.pedido_items
      ADD CONSTRAINT pedido_items_unidades_por_bloque_al_crear_check
      CHECK (unidades_por_bloque_al_crear IS NULL OR unidades_por_bloque_al_crear >= 1);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'pedido_items_origen_unidades_por_bloque_check') THEN
    ALTER TABLE public.pedido_items
      ADD CONSTRAINT pedido_items_origen_unidades_por_bloque_check
      CHECK (origen_unidades_por_bloque IS NULL OR origen_unidades_por_bloque IN (
        'vivo', 'medido_constante', 'sin_fraccion', 'sin_promo'
      ));
  END IF;
END $$;

COMMENT ON COLUMN public.pedido_items.unidades_por_bloque_al_crear IS
  'Factor de fraccion de la bonificacion, congelado. Colapsa gate y divisor en un '
  'solo numero: 1 = el regalo no se fracciona, >1 = el costo se divide por eso. '
  'NULL = no reconstruible; el reporte cae al valor vivo de promociones, igual '
  'que antes de la mig 212. Solo se llena en lineas es_bonificacion.';
COMMENT ON COLUMN public.pedido_items.origen_unidades_por_bloque IS
  'De donde salio el factor. vivo = lo escribio el trigger al insertar. '
  'medido_constante = reconstruido por la mig 212 desde promo_ajustes, con serie '
  'constante e igual al valor vivo. sin_fraccion = promo que nunca fracciono. '
  'sin_promo = bonificacion sin promocion_id. NULL = no reconstruible.';

-- -------------------------------------------------------------------------
-- 2 · Asercion dura. Si alguna medicion exacta discrepa del valor vivo de su
--     promo hay un escalon que no entendimos, y es mejor no escribir nada.
--     Con los datos de hoy no se dispara.
-- -------------------------------------------------------------------------
DO $asercion$
DECLARE
  v_malas int;
  v_det   text;
BEGIN
  SELECT count(*), string_agg(DISTINCT format('promo %s: medido %s vs vivo %s',
                                              a.promocion_id, abs(a.usos_ajustados),
                                              coalesce(p.unidades_por_bloque::text, 'NULL')), '; ')
    INTO v_malas, v_det
  FROM promo_ajustes a
  JOIN promociones p ON p.id = a.promocion_id
  WHERE abs(a.unidades_ajustadas) = 1
    AND (a.observaciones LIKE 'Auto-ajuste%'
      OR a.observaciones LIKE 'Cancelacion pedido #%'
      OR a.observaciones LIKE 'Eliminacion pedido #%'
      OR a.observaciones LIKE 'Edicion pedido #%'
      OR a.observaciones LIKE 'Salvedad%')
    AND abs(a.usos_ajustados) IS DISTINCT FROM p.unidades_por_bloque;

  IF v_malas > 0 THEN
    RAISE EXCEPTION 'mig 212: % medicion(es) exacta(s) discrepan del valor vivo (%). '
                    'El factor SI cambio alguna vez: no se puede congelar con el de hoy.',
                    v_malas, v_det;
  END IF;
END
$asercion$;

-- -------------------------------------------------------------------------
-- 3 · Clasificacion de las promos, computada una sola vez.
-- -------------------------------------------------------------------------
CREATE TEMP TABLE _mig212_promos ON COMMIT DROP AS
WITH med AS (
  SELECT promocion_id,
         min(created_at)          AS primera,
         count(*)                 AS n,
         min(abs(usos_ajustados)) AS fmin,
         max(abs(usos_ajustados)) AS fmax
  FROM promo_ajustes
  WHERE abs(unidades_ajustadas) = 1
    AND (observaciones LIKE 'Auto-ajuste%'
      OR observaciones LIKE 'Cancelacion pedido #%'
      OR observaciones LIKE 'Eliminacion pedido #%'
      OR observaciones LIKE 'Edicion pedido #%'
      OR observaciones LIKE 'Salvedad%')
  GROUP BY 1
)
SELECT p.id            AS promocion_id,
       m.primera,
       -- Serie constante, igual al vivo, y el vivo efectivamente fracciona.
       (m.n IS NOT NULL AND m.fmin = m.fmax AND m.fmin = p.unidades_por_bloque
        AND p.regalo_mueve_stock IS FALSE AND p.unidades_por_bloque > 1) AS medido_constante,
       p.unidades_por_bloque AS factor,
       -- Nunca fracciono: sin mediciones, sin una sola fila de ajuste, sin
       -- acumulador fraccional, y hoy el gate esta cerrado con el divisor nulo.
       (m.n IS NULL
        AND p.regalo_mueve_stock IS TRUE
        AND p.unidades_por_bloque IS NULL
        AND NOT EXISTS (SELECT 1 FROM promo_ajustes a WHERE a.promocion_id = p.id)
        AND NOT EXISTS (SELECT 1 FROM promo_acumuladores c
                         WHERE c.promocion_id = p.id
                           AND COALESCE(c.unidades_por_bloque, 0) > 1)) AS sin_fraccion
FROM promociones p
LEFT JOIN med m ON m.promocion_id = p.id;

-- Fecha real de nacimiento de cada linea. pedido_items no tiene timestamp propio
-- y `pedidos.fecha` es un DATE que manda el cliente, asi que no sirve para datar.
-- audit_logs si: el trigger audit_pedido_items escribe una fila INSERT con
-- registro_id = pedido_items.id::text, y como actualizar_pedido_items BORRA y
-- REINSERTA, la fila sobreviviente tiene id nuevo y su INSERT de auditoria es el
-- de la EDICION -- que es justo el instante en que se leyo el factor vivo.
CREATE TEMP TABLE _mig212_nacimiento ON COMMIT DROP AS
SELECT registro_id, min(created_at) AS ts
FROM audit_logs
WHERE tabla = 'pedido_items' AND accion = 'INSERT'
GROUP BY 1;

CREATE INDEX ON _mig212_nacimiento (registro_id);

-- -------------------------------------------------------------------------
-- 4 · Backfill. Solo donde hoy hay NULL, asi la reversion es poner NULL en las
--     mismas filas. Todo lo que no entra en una de las tres ramas queda en NULL
--     a proposito.
-- -------------------------------------------------------------------------

-- Rama A: la promo fracciona y su serie de mediciones es constante e igual al
-- vivo. Solo los items nacidos DENTRO de la ventana medida: antes de la primera
-- medicion no hay evidencia y no se inventa.
UPDATE pedido_items pi
SET unidades_por_bloque_al_crear = pr.factor,
    origen_unidades_por_bloque   = 'medido_constante'
FROM _mig212_promos pr, _mig212_nacimiento nac
WHERE pi.promocion_id = pr.promocion_id
  AND pr.medido_constante
  AND pi.es_bonificacion
  AND pi.unidades_por_bloque_al_crear IS NULL
  AND nac.registro_id = pi.id::text
  AND nac.ts >= pr.primera;

-- Rama B: la promo nunca fracciono. Factor 1.
UPDATE pedido_items pi
SET unidades_por_bloque_al_crear = 1,
    origen_unidades_por_bloque   = 'sin_fraccion'
FROM _mig212_promos pr
WHERE pi.promocion_id = pr.promocion_id
  AND pr.sin_fraccion
  AND pi.es_bonificacion
  AND pi.unidades_por_bloque_al_crear IS NULL;

-- Rama C: bonificacion sin promocion. No hay divisor posible. Factor 1.
UPDATE pedido_items pi
SET unidades_por_bloque_al_crear = 1,
    origen_unidades_por_bloque   = 'sin_promo'
WHERE pi.es_bonificacion
  AND pi.promocion_id IS NULL
  AND pi.unidades_por_bloque_al_crear IS NULL;

-- -------------------------------------------------------------------------
-- 5 · El trigger. NO es opcional: sin el, el backfill SE EVAPORA en la proxima
--     edicion de cualquier pedido, porque actualizar_pedido_items borra y
--     reinserta los items.
--
--     Solo BEFORE INSERT. Que una edicion re-snapshotee con el factor del
--     momento de la edicion ES correcto: el acumulador tambien se revierte y se
--     re-aplica en ese mismo camino. Mismo criterio que el trigger de la 148.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.completar_unidades_por_bloque_item()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $fn$
DECLARE
  v_mueve_stock boolean;
  v_upb         integer;
BEGIN
  -- No se pisa lo que venga cargado, y una linea de venta no se fracciona nunca.
  IF NEW.unidades_por_bloque_al_crear IS NOT NULL
     OR NOT COALESCE(NEW.es_bonificacion, false) THEN
    RETURN NEW;
  END IF;

  IF NEW.promocion_id IS NULL THEN
    NEW.unidades_por_bloque_al_crear := 1;
    NEW.origen_unidades_por_bloque   := COALESCE(NEW.origen_unidades_por_bloque, 'sin_promo');
    RETURN NEW;
  END IF;

  SELECT regalo_mueve_stock, unidades_por_bloque
    INTO v_mueve_stock, v_upb
  FROM promociones WHERE id = NEW.promocion_id;

  -- Un solo numero que colapsa gate y divisor. Si la promo no fracciona -- o si
  -- la promocion_id no existe -- el factor es 1, que es neutro.
  IF v_mueve_stock IS FALSE AND COALESCE(v_upb, 0) > 1 THEN
    NEW.unidades_por_bloque_al_crear := v_upb;
  ELSE
    NEW.unidades_por_bloque_al_crear := 1;
  END IF;
  NEW.origen_unidades_por_bloque := COALESCE(NEW.origen_unidades_por_bloque, 'vivo');

  RETURN NEW;
END;
$fn$;

ALTER FUNCTION public.completar_unidades_por_bloque_item() OWNER TO postgres;

DROP TRIGGER IF EXISTS trg_completar_unidades_por_bloque_item ON public.pedido_items;
CREATE TRIGGER trg_completar_unidades_por_bloque_item
  BEFORE INSERT ON public.pedido_items
  FOR EACH ROW
  EXECUTE FUNCTION public.completar_unidades_por_bloque_item();

-- -------------------------------------------------------------------------
-- 6 · El helper que lee el factor. Un solo lugar donde vive la precedencia
--     congelado -> vivo -> neutro, para que gate y divisor no se puedan
--     desalinear nunca mas.
--
--     NO es STRICT a proposito: el caso normal es que alguno de los tres
--     argumentos sea NULL (item sin promo, o item no reconstruible).
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.factor_bonificacion(
  p_al_crear            integer,
  p_regalo_mueve_stock  boolean,
  p_unidades_por_bloque integer
)
RETURNS integer
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $fn$
  SELECT GREATEST(
    COALESCE(
      p_al_crear,
      CASE WHEN p_regalo_mueve_stock IS FALSE
           THEN NULLIF(p_unidades_por_bloque, 0) END,
      1
    ),
    1
  );
$fn$;

COMMENT ON FUNCTION public.factor_bonificacion(integer, boolean, integer) IS
  'Factor por el que se divide el costo de una bonificacion. 1 = no fraccionar. '
  'Prefiere el congelado del item; si no hay, cae al vivo de la promo, que es lo '
  'que hacia el reporte antes de la mig 212. Nunca devuelve 0 ni NULL.';

REVOKE ALL ON FUNCTION public.factor_bonificacion(integer, boolean, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.factor_bonificacion(integer, boolean, integer) TO authenticated, service_role;

-- -------------------------------------------------------------------------
-- 7 · Parche de reporte_gerencial por ancla, sobre el cuerpo VIVO.
--     migrations/ no es espejo de prod: reporte_gerencial fue redefinida 10
--     veces, asi que copiar el cuerpo del archivo revertiria logica viva en
--     silencio. Se parchea lo que devuelve pg_get_functiondef.
--
--     CREATE OR REPLACE, sin DROP: cambiarle la firma dejaria dos sobrecargas
--     con rangos superpuestos y PostgREST tiraria PGRST203 en runtime.
--
--     Dos anclas, las dos dentro del CTE `it`. Con esas dos alcanza: el
--     bool_or(es_fraccion) y el valor_venta de `bonif_promos` consumen las
--     columnas del CTE y quedan alineados solos. Congelar el costo y no el
--     valor_venta dejaria el margen de la bonificacion incoherente sin fallar.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._mig212_reemplazar_ancla(
  p_funcion regprocedure,
  p_ancla   text,
  p_nuevo   text
)
RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text;
  v_veces int;
BEGIN
  v_def := pg_get_functiondef(p_funcion);

  v_veces := (length(v_def) - length(replace(v_def, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El ancla aparece % veces en % (se esperaba exactamente 1). El cuerpo vivo cambio: revisar a mano.',
      v_veces, p_funcion;
  END IF;

  EXECUTE replace(v_def, p_ancla, p_nuevo);
END;
$fn$;

DO $patch$
DECLARE
  v_fn    regprocedure;
  v_call  text := 'public.factor_bonificacion(pi.unidades_por_bloque_al_crear, pr.regalo_mueve_stock, pr.unidades_por_bloque)';
  v_costo text := 'pi.cantidad * COALESCE(pi.costo_unitario_al_crear, prod.costo_promedio, prod.costo_real, prod.costo_sin_iva*(1+COALESCE(prod.impuestos_internos,0)/100))';
BEGIN
  SELECT p.oid::regprocedure INTO v_fn
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'reporte_gerencial';

  -- Ancla 1: el gate y el divisor que el CTE expone como columnas. Tiene que ser
  -- el bloque de DOS lineas: el fragmento suelto 'pr.unidades_por_bloque,'
  -- tambien aparece dentro del COALESCE de la primera.
  PERFORM public._mig212_reemplazar_ancla(
    v_fn,
    E'           (pr.regalo_mueve_stock IS FALSE AND COALESCE(pr.unidades_por_bloque,0) > 0) AS es_fraccion,\n'
    || E'           pr.unidades_por_bloque,',
    E'           (' || v_call || E' > 1) AS es_fraccion,\n'
    || E'           ' || v_call || E' AS unidades_por_bloque,'
  );

  -- Ancla 2: el CASE que valoriza el costo del regalo.
  PERFORM public._mig212_reemplazar_ancla(
    v_fn,
    E'             CASE WHEN pr.regalo_mueve_stock IS FALSE AND pr.unidades_por_bloque > 0\n'
    || E'                  THEN ' || v_costo || E' / pr.unidades_por_bloque',
    E'             CASE WHEN ' || v_call || E' > 1\n'
    || E'                  THEN ' || v_costo || E' / ' || v_call
  );
END
$patch$;

DROP FUNCTION public._mig212_reemplazar_ancla(regprocedure, text, text);

-- -------------------------------------------------------------------------
-- 8 · Verificacion.
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  v_def         text;
  v_con_valor   bigint;
  v_en_null     bigint;
  v_incoherente bigint;
  v_acl         text;
  v_sobrecargas int;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE unidades_por_bloque_al_crear IS NULL)
    INTO v_con_valor, v_en_null
  FROM pedido_items WHERE es_bonificacion;
  v_con_valor := v_con_valor - v_en_null;

  -- Ninguna linea puede quedar en NULL donde el reporte efectivamente divide y
  -- ademas hay evidencia: si esta dentro de la ventana medida, tiene que tener
  -- valor. (Las anteriores a la primera medicion son las que quedan en NULL.)
  SELECT count(*) INTO v_incoherente
  FROM pedido_items pi
  JOIN _mig212_promos pr ON pr.promocion_id = pi.promocion_id
  JOIN _mig212_nacimiento nac ON nac.registro_id = pi.id::text
  WHERE pi.es_bonificacion AND pr.medido_constante
    AND nac.ts >= pr.primera
    AND pi.unidades_por_bloque_al_crear IS NULL;
  IF v_incoherente > 0 THEN
    RAISE EXCEPTION 'mig 212: % item(s) dentro de la ventana medida quedaron en NULL.', v_incoherente;
  END IF;

  -- El factor congelado nunca puede contradecir a su propia promo medida.
  SELECT count(*) INTO v_incoherente
  FROM pedido_items pi JOIN _mig212_promos pr ON pr.promocion_id = pi.promocion_id
  WHERE pi.origen_unidades_por_bloque = 'medido_constante'
    AND pi.unidades_por_bloque_al_crear IS DISTINCT FROM pr.factor;
  IF v_incoherente > 0 THEN
    RAISE EXCEPTION 'mig 212: % item(s) medidos con factor distinto al de su promo.', v_incoherente;
  END IF;

  -- El parche entro en las dos anclas.
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'reporte_gerencial';
  IF (length(v_def) - length(replace(v_def, 'factor_bonificacion', ''))) / length('factor_bonificacion') <> 4 THEN
    RAISE EXCEPTION 'mig 212: reporte_gerencial no quedo con las 4 llamadas a factor_bonificacion.';
  END IF;
  IF v_def LIKE '%pr.unidades_por_bloque > 0%' THEN
    RAISE EXCEPTION 'mig 212: quedo una lectura viva del divisor en reporte_gerencial.';
  END IF;

  -- Una sola sobrecarga: dos con rangos superpuestos dan PGRST203 en runtime.
  SELECT count(*) INTO v_sobrecargas
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'reporte_gerencial';
  IF v_sobrecargas <> 1 THEN
    RAISE EXCEPTION 'mig 212: hay % sobrecargas de reporte_gerencial.', v_sobrecargas;
  END IF;

  -- El ACL del helper quedo cerrado. Una entrada de PUBLIC no tiene grantee, o
  -- sea que arranca con '='; la de anon arranca con 'anon='.
  SELECT array_to_string(array_agg(a::text), ' ') INTO v_acl
  FROM pg_proc p, unnest(p.proacl) a
  WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'factor_bonificacion'
    AND (a::text LIKE '=%' OR a::text LIKE 'anon=%');
  IF v_acl IS NOT NULL THEN
    RAISE EXCEPTION 'mig 212: factor_bonificacion quedo ejecutable por anon o PUBLIC (%).', v_acl;
  END IF;

  RAISE NOTICE 'mig 212 OK: % bonificaciones con factor congelado, % en NULL (caen al valor vivo).',
               v_con_valor, v_en_null;
END
$verif$;

COMMIT;
