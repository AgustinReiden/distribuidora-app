-- ============================================================================
-- NNN · El cupo de una promo cuenta el corte, y el cambio de cliente mide el
--       combo contra su foto (#1300, #1301, #1283)
-- ============================================================================
-- Tarjeta 6 del plan #1306 (promos y combos). Aplicar desde el contenido LF.
-- Ensayo: scripts/test-cupo-promo-y-combo-1300-1301-1283.sql; el de la 408
-- (scripts/test-limite-usos-1261.sql) tiene que seguir pasando.
--
-- QUÉ ES ESTO
-- -----------
-- #1300 · Decisión del dueño (29/10): un uso de la promo es EL CORTE, en la
--   unidad de la promo, no la cantidad de la línea. Sustituir el regalo no mueve
--   el cupo. Hasta acá el trigger sumaba `pi.cantidad`, que la sustitución
--   reescribe en la unidad del sustituto: A×4 cambiado por P×19 contaba 19.
--   · `regalo_usos_de_linea` es lo que cuenta una línea: su corte
--     (`regalo_cantidad_base`). Una parte de un reparto cuenta SU parte: el ítem
--     19017 del pedido 5182 es un reparto de 94 en 34+30+30, cuenta 34 y el
--     pedido suma 94. Contar 94 en esa línea daría 154.
--   · El corte de una cadena es el del eslabón, y ni la edición ni la salvedad
--     actualizan eslabones. Si la línea se movió después de su último eslabón,
--     el corte escala con ella: sin esto, un cambio de sabor 12→12 editado a 24
--     seguía contando 12 y el límite se pasaba por la edición. Con el mismo
--     criterio, una salvedad parcial sobre una línea sustituida libera su parte.
--     La inversa es aproximada cuando la edición no convirtió por valor (misma
--     categoría y mismo factor con cantidades distintas): ver #1325 (REG-3).
--   · `_promo_usos` es el conteo de una promo y es UNO: lo usan el trigger, el
--     piso del límite y la lectura de la pantalla.
--   · El rechazo dice qué cuenta el cupo. El prefijo del mensaje no cambia.
--   · PRM-N3 no ocurre: `anular_salvedad` rechaza toda salvedad sobre un regalo
--     de promo y toda restitución que devuelva el derecho a un regalo
--     (`anulacion_toca_promociones`), así que nunca escribe una línea de regalo y
--     este trigger no se dispara. No hay nada que cambiar: lo prueba el ensayo.
--   · PRM-N4 es del front: `fetchPromoMap` y `ModalEditarPedido`. El server ya
--     acepta conservar el regalo de una promo apagada (362).
-- #1283 · `promos_cupo(p_pedido_id)`: el conteo vivo para el chip de la pantalla
--   de promos y el aviso al armar un pedido. Da `usos` y `quedan`, y el front no
--   recalcula nada. Con el pedido que se está editando, su propio regalo no le
--   resta, como en el "quedan" del rechazo.
-- #1301 · `cambiar_cliente_pedido` crea un pedido nuevo, sin `pedido_id`, así que
--   sus combos se medían contra la definición vigente: con la estructura
--   cambiada el cambio no se podía hacer, y con el precio cambiado el pedido
--   quedaba a precio de la foto vieja con una foto nueva al precio vigente.
--   Ahora `cambiar_cliente_pedido` prende `app.combo_foto_pedido` alrededor de
--   `crear_pedido_completo`, y `combo_fuera_de_regla` y `_guardar_combos_pedido`
--   usan la foto del pedido original. El GUC es por transacción, como
--   `app.omitir_minimo_pedido` y `app.cargo_envio_forzado`, y se vacía apenas
--   nace el pedido. Sólo vale una foto de ese combo en esa sucursal: con un pedido
--   que no la tiene se mide lo vigente. La foto sobrevive a la cancelación:
--   `cancelar_pedido_con_stock` no toca `pedido_combos`. `precio_fuera_de_politica`
--   y `completar_origen_precio_item` no llaman a `combo_fuera_de_regla` (lo nombran
--   en un comentario), y la firma de `_guardar_combos_pedido` no cambia.
--
-- QUÉ SE TOCA
-- -----------
-- Nuevas: regalo_usos_de_linea, _promo_usos (de servidor), promos_cupo (RPC).
-- Reescritas enteras, con premisa de md5: validar_limite_usos_promo,
--   limite_usos_no_baja_de_lo_regalado.
-- Parcheadas por reemplazo, con md5 antes y después: combo_fuera_de_regla,
--   _guardar_combos_pedido, cambiar_cliente_pedido.
-- Ni `crear_pedido_completo` ni `sustituir_regalo_pedido` ni `anular_salvedad`.
--
-- Sin efecto sobre lo que ya está: en prod sólo la promo 34 tiene límite, cuenta
-- 16 de 20 antes y después, y ningún número de ninguna promo cambia con esta
-- cuenta; no hay combos. No apaga ninguna promo: si alguna quedara pasada, el
-- paso 5 frena la migración.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0 · Premisas: los cuerpos vivos son los que se leyeron al escribir esto.
-- ---------------------------------------------------------------------------
DO $premisa$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('public.validar_limite_usos_promo()',                 '98fd22bc64c2618b3f76efbb60ef3248'),
      ('public.limite_usos_no_baja_de_lo_regalado()',        '499f4fd54f32e6aa7b72be96bfacef1c'),
      ('public.combo_fuera_de_regla(jsonb,bigint,date,bigint,boolean)', 'dec714e939e09cb05e299c31359b1169'),
      ('public._guardar_combos_pedido(bigint,bigint)',       'd6bc647abfd28ec9fb7fd09fd923531f'),
      ('public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)',
                                                             'b90a769fafab49a6743a5420238b5cb5')) AS v(firma, md5)
  LOOP
    IF to_regprocedure(r.firma) IS NULL
       OR (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure(r.firma)) <> r.md5 THEN
      RAISE EXCEPTION 'Premisa: % cambió desde que se escribió esta migración. Volvé a partir del cuerpo vivo.', r.firma;
    END IF;
  END LOOP;
END
$premisa$;

-- ---------------------------------------------------------------------------
-- 1 · Lo que cuenta una línea y lo que cuenta una promo.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.regalo_usos_de_linea(p_eslabones jsonb, p_cadena uuid, p_cantidad numeric)
 RETURNS bigint
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  -- El corte de la línea (#1090). Si la línea se movió después de su último
  -- eslabón (la edición o una salvedad), el corte escala con ella: los eslabones
  -- no se actualizan.
  WITH ultimo AS (
    SELECT (x->>'cantidad_sustituta')::numeric AS cantidad
      FROM jsonb_array_elements(COALESCE(p_eslabones, '[]'::jsonb)) x
     WHERE p_cadena IS NOT NULL AND (x->>'cadena_id')::uuid = p_cadena
     ORDER BY (x->>'id')::bigint DESC
     LIMIT 1
  ), corte AS (
    SELECT public.regalo_cantidad_base(p_eslabones, p_cadena, p_cantidad) AS cantidad
  )
  SELECT CASE
           WHEN u.cantidad IS NULL OR u.cantidad <= 0 OR u.cantidad = p_cantidad THEN round(c.cantidad)
           ELSE GREATEST(1, round(c.cantidad * p_cantidad / u.cantidad))
         END::bigint
    FROM corte c
    LEFT JOIN ultimo u ON true;
$function$;

REVOKE ALL ON FUNCTION public.regalo_usos_de_linea(jsonb, uuid, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.regalo_usos_de_linea(jsonb, uuid, numeric) TO service_role;

-- `del_pedido`: lo que de ese total usa p_pedido_id. "Quedan" es siempre
-- limite - (usos - del_pedido).
CREATE OR REPLACE FUNCTION public._promo_usos(p_promocion_id bigint, p_pedido_id bigint DEFAULT NULL::bigint)
 RETURNS TABLE(usos bigint, del_pedido bigint)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(sum(l.usos), 0)::bigint,
         COALESCE(sum(l.usos) FILTER (WHERE l.pedido_id = p_pedido_id), 0)::bigint
    FROM (SELECT pi.pedido_id,
                 public.regalo_usos_de_linea(
                   CASE WHEN pi.regalo_cadena_id IS NOT NULL
                        THEN public.regalo_eslabones(pi.pedido_id, pi.promocion_id, pi.sucursal_id) END,
                   pi.regalo_cadena_id, pi.cantidad) AS usos
            FROM pedido_items pi
            JOIN pedidos p ON p.id = pi.pedido_id
           WHERE pi.promocion_id = p_promocion_id
             AND pi.es_bonificacion
             AND p.estado <> 'cancelado') l;
$function$;

REVOKE ALL ON FUNCTION public._promo_usos(bigint, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._promo_usos(bigint, bigint) TO service_role;

-- ---------------------------------------------------------------------------
-- 2 · El trigger del límite y el piso del límite cuentan con _promo_usos.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validar_limite_usos_promo()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_promo  record;
  v_usos   bigint;
  v_pedido bigint;
BEGIN
  -- Dos ventas a la vez se cuentan de a una: la segunda espera acá y, ya con la
  -- promo, cuenta con lo que la primera confirmó.
  SELECT id, nombre, limite_usos, activo INTO v_promo
    FROM promociones WHERE id = NEW.promocion_id FOR UPDATE;
  IF NOT FOUND OR v_promo.limite_usos IS NULL THEN
    RETURN NULL;
  END IF;

  -- #1300: un uso es el corte de la promo, no la cantidad de la línea.
  SELECT u.usos, u.del_pedido INTO v_usos, v_pedido
    FROM public._promo_usos(NEW.promocion_id, NEW.pedido_id) u;

  IF v_usos > v_promo.limite_usos THEN
    RAISE EXCEPTION 'La promo «%» tiene un límite de % unidades de regalo: quedan % y este pedido lleva %. El cupo cuenta el corte de la promo, en su unidad: sustituir el regalo no lo cambia.',
                    v_promo.nombre, v_promo.limite_usos,
                    GREATEST(v_promo.limite_usos - (v_usos - v_pedido), 0), v_pedido
      USING HINT = 'Sacá o achicá el regalo de esa promo, o pedile al admin que suba el límite.';
  END IF;
  -- Al llegar, se apaga. Una cancelación devuelve las unidades, pero no la
  -- reactiva sola: la vuelve a prender el admin.
  IF v_usos >= v_promo.limite_usos AND v_promo.activo THEN
    UPDATE promociones SET activo = false WHERE id = NEW.promocion_id;
  END IF;
  RETURN NULL;
END
$function$;

CREATE OR REPLACE FUNCTION public.limite_usos_no_baja_de_lo_regalado()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_usos bigint;
BEGIN
  SELECT u.usos INTO v_usos FROM public._promo_usos(NEW.id) u;
  IF NEW.limite_usos < v_usos THEN
    RAISE EXCEPTION 'La promo «%» ya regaló % unidades: el límite no puede ser menor.', NEW.nombre, v_usos;
  END IF;
  IF NEW.limite_usos = v_usos THEN
    NEW.activo := false;
  END IF;
  RETURN NEW;
END
$function$;

-- ---------------------------------------------------------------------------
-- 3 · #1283: el conteo vivo. DEFINER porque suma los pedidos de todos los
--     vendedores, como combos_vigentes.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.promos_cupo(p_pedido_id bigint DEFAULT NULL::bigint)
 RETURNS TABLE(promocion_id bigint, limite_usos integer, usos bigint, quedan bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal bigint := public.current_sucursal_id();
BEGIN
  -- Sólo quien arma pedidos (es_preventista: preventista, encargado, admin y
  -- el rol extra).
  IF auth.uid() IS NULL OR v_sucursal IS NULL OR NOT public.es_preventista() THEN
    RETURN;
  END IF;
  RETURN QUERY
    SELECT pr.id, pr.limite_usos, u.usos, GREATEST(pr.limite_usos - (u.usos - u.del_pedido), 0)::bigint
      FROM promociones pr
     CROSS JOIN LATERAL public._promo_usos(pr.id, p_pedido_id) u
     WHERE pr.sucursal_id = v_sucursal
       AND pr.limite_usos IS NOT NULL
     ORDER BY pr.id;
END
$function$;

REVOKE ALL ON FUNCTION public.promos_cupo(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.promos_cupo(bigint) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4 · #1301: el cambio de cliente mide el combo contra la foto del original.
--     Parche por ancla sobre el cuerpo vivo (verificado en el paso 0).
-- ---------------------------------------------------------------------------
DO $parche$
DECLARE
  r       record;
  v_src   text;
  v_def   text;
  v_nuevo text;
  v_par   text[];
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('public.combo_fuera_de_regla(jsonb,bigint,date,bigint,boolean)'::text, ARRAY[
        ARRAY[$a$  v_vendidos bigint;$a$,
              $a$  v_vendidos bigint;
  -- #1301: el cambio de cliente crea un pedido nuevo y mide contra la foto del
  -- original (app.combo_foto_pedido, de cambiar_cliente_pedido).
  v_foto_de  bigint := COALESCE(p_pedido_id,
                                NULLIF(current_setting('app.combo_foto_pedido', true), '')::bigint);$a$],
        ARRAY[$a$    -- Edicion: el combo que el pedido ya tenia se mide contra su foto.$a$,
              $a$    -- Edicion y cambio de cliente: el combo que el pedido ya tenia se mide contra su foto.$a$],
        ARRAY[$a$    IF p_pedido_id IS NOT NULL THEN$a$,
              $a$    IF v_foto_de IS NOT NULL THEN$a$],
        ARRAY[$a$       WHERE f.pedido_id = p_pedido_id AND f.combo_id = r.combo_id AND f.sucursal_id = p_sucursal;$a$,
              $a$       WHERE f.pedido_id = v_foto_de AND f.combo_id = r.combo_id AND f.sucursal_id = p_sucursal;$a$]
      ]),
      ('public._guardar_combos_pedido(bigint,bigint)'::text, ARRAY[
        ARRAY[$a$  v_k   integer;$a$,
              $a$  v_k   integer;
  -- #1301: el pedido nuevo de un cambio de cliente hereda la foto del original.
  v_original bigint := NULLIF(current_setting('app.combo_foto_pedido', true), '')::bigint;$a$],
        ARRAY[$a$      v_def := public._combo_definicion(r.combo_id, p_sucursal);$a$,
              $a$      v_def := NULL;
      IF v_original IS NOT NULL THEN
        SELECT jsonb_build_object('nombre', f.nombre, 'precio', f.precio,
                                  'combina_escalas', f.combina_escalas, 'componentes', f.componentes)
          INTO v_def
          FROM pedido_combos f
         WHERE f.pedido_id = v_original AND f.combo_id = r.combo_id AND f.sucursal_id = p_sucursal;
      END IF;
      v_def := COALESCE(v_def, public._combo_definicion(r.combo_id, p_sucursal));$a$]
      ]),
      ('public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)'::text, ARRAY[
        ARRAY[$a$  v_crear := crear_pedido_completo($a$,
              $a$  -- #1301: los combos del pedido nuevo se miden contra la foto de este, no
  -- contra la definicion vigente, y el nuevo hereda esa foto.
  PERFORM set_config('app.combo_foto_pedido', p_pedido_id::text, true);

  v_crear := crear_pedido_completo($a$],
        ARRAY[$a$  v_nuevo_id := (v_crear->>'pedido_id')::bigint;$a$,
              $a$  v_nuevo_id := (v_crear->>'pedido_id')::bigint;
  PERFORM set_config('app.combo_foto_pedido', '', true);$a$]
      ])
    ) AS t(firma, pares)
  LOOP
    SELECT prosrc INTO v_src FROM pg_proc WHERE oid = to_regprocedure(r.firma);
    v_def   := pg_get_functiondef(to_regprocedure(r.firma));
    v_nuevo := v_src;
    FOREACH v_par SLICE 1 IN ARRAY r.pares LOOP
      IF (length(v_src) - length(replace(v_src, v_par[1], ''))) / length(v_par[1]) <> 1 THEN
        RAISE EXCEPTION 'El ancla de % no aparece una sola vez: %', r.firma, v_par[1];
      END IF;
      v_def   := replace(v_def, v_par[1], v_par[2]);
      v_nuevo := replace(v_nuevo, v_par[1], v_par[2]);
    END LOOP;
    EXECUTE v_def;
    IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure(r.firma)) <> md5(v_nuevo) THEN
      RAISE EXCEPTION '% no quedó como se esperaba', r.firma;
    END IF;
  END LOOP;
END
$parche$;

-- ---------------------------------------------------------------------------
-- 5 · Verificaciones.
-- ---------------------------------------------------------------------------
DO $verifica$
DECLARE
  v_f text;
BEGIN
  -- El límite no arranca pasado: el trigger rechazaría hasta lo que no suma.
  IF EXISTS (SELECT 1 FROM promociones pr
              CROSS JOIN LATERAL public._promo_usos(pr.id) u
              WHERE pr.limite_usos IS NOT NULL AND u.usos > pr.limite_usos) THEN
    RAISE EXCEPTION 'Hay promos con más usos que su límite contando el corte: revisalas antes de aplicar.';
  END IF;

  -- Las dos de servidor: nadie de la API.
  FOREACH v_f IN ARRAY ARRAY['public.regalo_usos_de_linea(jsonb,uuid,numeric)',
                             'public._promo_usos(bigint,bigint)'] LOOP
    IF has_function_privilege('anon', v_f, 'EXECUTE')
       OR has_function_privilege('authenticated', v_f, 'EXECUTE') THEN
      RAISE EXCEPTION '% quedó ejecutable desde la API', v_f;
    END IF;
  END LOOP;
  IF has_function_privilege('anon', 'public.promos_cupo(bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'promos_cupo quedó ejecutable con la anon key';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.promos_cupo(bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'promos_cupo quedó sin EXECUTE para authenticated';
  END IF;

  -- Los triggers siguen sin EXECUTE para nadie de la API (405).
  FOREACH v_f IN ARRAY ARRAY['public.validar_limite_usos_promo()',
                             'public.limite_usos_no_baja_de_lo_regalado()'] LOOP
    IF has_function_privilege('anon', v_f, 'EXECUTE')
       OR has_function_privilege('authenticated', v_f, 'EXECUTE') THEN
      RAISE EXCEPTION '% quedó con EXECUTE para la API', v_f;
    END IF;
  END LOOP;
END
$verifica$;
