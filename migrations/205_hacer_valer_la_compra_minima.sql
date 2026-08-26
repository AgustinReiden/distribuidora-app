-- Hacer valer la compra minima en los dos caminos que crean pedidos
--
-- La mig 204 dejo el numero configurable por sucursal. Esta lo hace cumplir.
--
-- DONDE SE VALIDA Y POR QUE AHI
-- -----------------------------
-- En el ALTA del pedido, nunca como CHECK sobre `pedidos.total` ni como trigger
-- sobre el UPDATE del total. Dos razones, las dos medidas:
--
--   1. Cancelar un pedido le pone `total = 0` (mig 175, linea 127), y el
--      invariante VENTA-I de `auditoria_integridad()` EXIGE que un pedido
--      cancelado tenga total 0 (mig 105). Un CHECK `total >= minimo` haria
--      imposible cancelar. Verificado en prod: los 175 pedidos en $0 de los
--      ultimos 90 dias son todos `estado = 'cancelado'`.
--
--   2. Cuando el minimo suba, los pedidos viejos que quedaron por debajo eran
--      legales cuando se crearon. La politica rige el alta, no retroactivamente.
--
-- LOS CAMINOS
-- -----------
-- Hay dos cuerpos que insertan en `pedidos` con total de venta, y los dos se
-- parchean aca:
--   crear_pedido_completo      <- web online, replay offline y cambiar_cliente_pedido
--   crear_pedido_completo_bot  <- Telegram
--
-- `crear_pedido_cambio_en_ruta` (mig 090) queda EXENTO y no hace falta tocarlo:
-- inserta directo, con `canal='cambio'` y `total=0` por diseño -- un cambio de
-- producto no es una venta y no tiene por que alcanzar ningun minimo. La
-- exencion es automatica justamente porque no pasa por ninguno de los dos.
--
-- EL ESCAPE HATCH
-- ---------------
-- `app.omitir_minimo_pedido = '1'`, hermano del `app.omitir_minimo_venta` que la
-- mig 174 uso para el minimo por producto, con el mismo criterio: el minimo rige
-- EL PEDIDO, NO LA ENTREGA. Un RPC de salvedad que rearma un pedido no tiene por
-- que quedar trabado por una politica que se cumplio cuando se vendio.
--
-- EL PARCHE
-- ---------
-- Los dos cuerpos son grandes (14k y 12k) y pudieron driftar, asi que NO se
-- copian del archivo: se leen del catalogo vivo con pg_get_functiondef y se les
-- inserta el bloque justo despues del guard de permisos, exigiendo que el ancla
-- aparezca EXACTAMENTE UNA VEZ (patron de las migs 176/191/193/195).
--
-- Cada uno respeta su propia forma de contestar el error, que es contrato con
-- sus clientes: `errores` (array) en crear_pedido_completo, `error` (string) en
-- la del bot.

BEGIN;

-- ---------------------------------------------------------------------------
-- La regla, en un solo lugar.
--
-- Se cumple con `>=`: un pedido que da exactamente el minimo pasa. Y minimo 0
-- no frena nada, que es el estado con el que arranca todo (mig 204).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pedido_incumple_minimo(
  p_total       numeric,
  p_sucursal_id bigint
)
RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_minimo numeric;
BEGIN
  -- Escape hatch: mismo criterio que app.omitir_minimo_venta (mig 174).
  IF COALESCE(current_setting('app.omitir_minimo_pedido', true), '') = '1' THEN
    RETURN NULL;
  END IF;

  v_minimo := public.monto_minimo_pedido(p_sucursal_id);

  IF v_minimo IS NULL OR v_minimo <= 0 THEN
    RETURN NULL;
  END IF;

  IF COALESCE(p_total, 0) >= v_minimo THEN
    RETURN NULL;
  END IF;

  -- El mensaje lleva los dos numeros a proposito: sale por caminos donde nadie
  -- va a ir a buscar cual era el minimo (el replay offline, el bot).
  RETURN format(
    'El pedido no alcanza la compra minima de %s. Total del pedido: %s.',
    to_char(v_minimo, 'FM$999G999G999D00'),
    to_char(COALESCE(p_total, 0), 'FM$999G999G999D00')
  );
END;
$fn$;

COMMENT ON FUNCTION public.pedido_incumple_minimo(numeric, bigint) IS
  'Devuelve el motivo si el pedido no llega al minimo de la sucursal, o NULL si '
  'esta bien. Se evalua SOLO al crear: cancelar pone total=0 y VENTA-I lo exige. '
  'mig 205.';

REVOKE ALL ON FUNCTION public.pedido_incumple_minimo(numeric, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pedido_incumple_minimo(numeric, bigint) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Helper de parcheo: inserta despues de un ancla que debe aparecer 1 sola vez.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._mig205_insertar_tras_ancla(
  p_funcion regprocedure,
  p_ancla   text,
  p_bloque  text
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

  v_def := replace(v_def, p_ancla, p_ancla || p_bloque);
  EXECUTE v_def;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 1 · crear_pedido_completo  (web online, replay offline, cambiar_cliente_pedido)
--     Contesta con `errores` (array de textos).
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE
  v_ancla  text;
  v_bloque text;
BEGIN
  v_ancla := 'IF v_user_role IS NULL OR v_user_role NOT IN (''admin'', ''preventista'', ''encargado'') THEN RETURN jsonb_build_object(''success'', false, ''errores'', jsonb_build_array(''No tiene permisos para crear pedidos'')); END IF;';

  v_bloque := E'\n\n  -- Compra minima de la sucursal (mig 204/205). Va aca, antes de tocar stock\n'
           || E'  -- o promociones, para que un pedido que no llega no deje nada a medias.\n'
           || E'  DECLARE v_motivo_minimo TEXT;\n'
           || E'  BEGIN\n'
           || E'    v_motivo_minimo := public.pedido_incumple_minimo(p_total, v_sucursal);\n'
           || E'    IF v_motivo_minimo IS NOT NULL THEN\n'
           || E'      RETURN jsonb_build_object(''success'', false, ''errores'', jsonb_build_array(v_motivo_minimo));\n'
           || E'    END IF;\n'
           || E'  END;\n';

  PERFORM public._mig205_insertar_tras_ancla(
    'public.crear_pedido_completo(bigint, numeric, uuid, jsonb, text, text, text, date, text, numeric, numeric, date, uuid)'::regprocedure,
    v_ancla,
    v_bloque
  );
END
$patch$;

-- ---------------------------------------------------------------------------
-- 2 · crear_pedido_completo_bot  (Telegram)
--     Contesta con `error` (string). El total y la sucursal vienen de la
--     confirmacion pendiente ya bloqueada con FOR UPDATE.
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE
  v_ancla  text;
  v_bloque text;
BEGIN
  v_ancla := E'  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_perfil_id;\n  IF v_user_role IS NULL OR v_user_role NOT IN (''admin'', ''encargado'', ''preventista'') THEN\n    RETURN jsonb_build_object(''success'', false, ''error'', ''No tiene permisos para crear pedidos'');\n  END IF;';

  v_bloque := E'\n\n  -- Compra minima de la sucursal (mig 204/205). previsualizar_pedido ya avisa\n'
           || E'  -- antes de que el preventista confirme; esto es la red de abajo, para que\n'
           || E'  -- la regla valga aunque se llegue por otro lado.\n'
           || E'  DECLARE v_motivo_minimo TEXT;\n'
           || E'  BEGIN\n'
           || E'    v_motivo_minimo := public.pedido_incumple_minimo(v_pendiente.total, v_pendiente.sucursal_id);\n'
           || E'    IF v_motivo_minimo IS NOT NULL THEN\n'
           || E'      RETURN jsonb_build_object(''success'', false, ''error'', v_motivo_minimo);\n'
           || E'    END IF;\n'
           || E'  END;\n';

  PERFORM public._mig205_insertar_tras_ancla(
    'public.crear_pedido_completo_bot(uuid, uuid)'::regprocedure,
    v_ancla,
    v_bloque
  );
END
$patch$;

-- ---------------------------------------------------------------------------
-- 3 · cambiar_cliente_pedido  <- prende el escape hatch
--
-- Reatribuir un pedido a otro cliente cancela el original y lo vuelve a crear
-- por crear_pedido_completo, asi que sin esto quedaria sujeto al minimo. Y seria
-- el minimo de HOY contra un pedido que se vendio con el de ANTES: si la
-- politica subio en el medio, corregir un cliente mal cargado se volveria
-- imposible. Es exactamente el caso que la mig 199 tuvo que arreglar a mano.
--
-- Es una correccion administrativa de admin sobre una venta que ya ocurrio, no
-- una venta nueva: mismo criterio que los RPCs de salvedad en la mig 174.
-- set_config con is_local = true muere con la transaccion, asi que no se filtra.
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE
  v_ancla  text;
  v_bloque text;
BEGIN
  v_ancla := E'  SELECT rol INTO v_role FROM perfiles WHERE id = v_acting;\n  IF v_role IS NULL OR v_role <> ''admin'' THEN\n    RETURN jsonb_build_object(''success'', false, ''error'', ''No autorizado: solo admin puede cambiar el cliente de un pedido'');\n  END IF;';

  v_bloque := E'\n\n  -- La reatribucion no es una venta nueva: el pedido ya cumplio (o no) el\n'
           || E'  -- minimo cuando se creo. Ver mig 205.\n'
           || E'  PERFORM set_config(''app.omitir_minimo_pedido'', ''1'', true);\n';

  PERFORM public._mig205_insertar_tras_ancla(
    (SELECT p.oid::regprocedure FROM pg_proc p
      WHERE p.pronamespace = 'public'::regnamespace
        AND p.proname = 'cambiar_cliente_pedido'),
    v_ancla,
    v_bloque
  );
END
$patch$;

DROP FUNCTION public._mig205_insertar_tras_ancla(regprocedure, text, text);

-- ---------------------------------------------------------------------------
-- Verificacion: el parche entro en los dos, y el ACL de los dos sigue cerrado.
-- CREATE OR REPLACE conserva el ACL, pero si alguna vez alguien las dropea y
-- recrea, esto avisa.
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  v_def text;
  v_fn  text;
  v_acl text;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY['crear_pedido_completo', 'crear_pedido_completo_bot'] LOOP
    SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = v_fn;

    IF v_def NOT LIKE '%pedido_incumple_minimo%' THEN
      RAISE EXCEPTION '% no quedo con la validacion de compra minima', v_fn;
    END IF;

    SELECT array_to_string(proacl, ',') INTO v_acl
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = v_fn;

    IF v_acl IS NOT NULL AND (v_acl LIKE '=X/%' OR v_acl LIKE '%,=X/%' OR v_acl LIKE '%anon=%') THEN
      RAISE EXCEPTION '% quedo ejecutable por PUBLIC o anon: %', v_fn, v_acl;
    END IF;
  END LOOP;

  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
    AND p.proname = 'cambiar_cliente_pedido';
  IF v_def NOT LIKE '%omitir_minimo_pedido%' THEN
    RAISE EXCEPTION 'cambiar_cliente_pedido no quedo con el escape hatch: una reatribucion podria trabarse por el minimo de hoy';
  END IF;

  -- La regla no debe frenar nada mientras el minimo sea 0 (estado inicial).
  IF public.pedido_incumple_minimo(1, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'Con minimo 0 la validacion no deberia frenar ningun pedido';
  END IF;
END
$verif$;

COMMIT;

-- ROLLBACK: volver a aplicar la mig 132 (que define los dos cuerpos sin este
-- bloque) y despues DROP FUNCTION public.pedido_incumple_minimo(numeric, bigint).
