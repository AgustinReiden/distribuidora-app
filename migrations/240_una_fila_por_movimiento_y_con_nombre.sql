-- ============================================================================
-- 240 · Una fila por movimiento de stock, y con nombre
-- ============================================================================
-- Tres arreglos del mismo tema: quien movio el stock, por que, y cuantas veces
-- lo dice el ledger. Los tres se verificaron contra el cuerpo VIVO de PROD
-- (`pg_get_functiondef`), no contra los archivos de `migrations/`.
--
-- 1 · `aplicar_control_stock` (078) escribe DOS filas por cada diferencia.
--     Hace `UPDATE productos SET stock = v_stock_real` --que dispara
--     `trg_stock_historico` y deja una fila `origen='auto'` sin referencia ni
--     usuario, porque la RPC nunca seteo `app.stock_origen`-- y ademas inserta
--     a mano la fila `origen='control_stock'`. La 139 ya habia escrito la regla
--     en su encabezado ("NO se inserta a mano en stock_historico (eso
--     duplicaria filas)"); esta funcion es de la 078 y quedo del otro lado.
--     Medido en el ensayo de esta migracion, antes del arreglo: una planilla
--     con 1 diferencia dejaba 2 filas.
--
-- 2 · `registrar_compra_completa` es el ultimo camino de stock que no etiqueta.
--     Su hermana `actualizar_compra_items` setea las cuatro GUCs desde la 128;
--     el alta no. Cada compra entra al ledger como `origen='auto'`, sin
--     referencia y sin usuario, y engorda STK-D.
--
-- 3 · `sustituir_regalo_pedido` revienta con un item bonificado sin
--     `promocion_id`: carga `v_promo` solo dentro de `IF promocion_id IS NOT
--     NULL`, y despues hace `COALESCE(v_promo.regalo_mueve_stock, TRUE)`
--     incondicional. El resultado es `record "v_promo" is not assigned yet`,
--     que el `EXCEPTION WHEN OTHERS` devuelve como `{success:false}` --o sea,
--     con la misma cara que una validacion de negocio-- y llega al usuario
--     como un cartel incomprensible. Hoy en PROD no hay ningun bonificado sin
--     promocion (0 de 1.363), pero el camino existe:
--     `PedidosContainer.tsx:1241` manda `promocionId` solo si viene
--     (`...(item.promoId ? { promocionId: item.promoId } : {})`).
--
-- ---------------------------------------------------------------------------
-- DECISIONES
--
-- · Las 41 filas `auto` duplicadas que ya estan escritas SE BORRAN. Son 41, de
--   una sola jornada (2026-06-08), y el pareo es 1:1 exacto: 41 filas
--   `control_stock` y 41 gemelas `auto` (mismo producto, misma sucursal, mismo
--   `stock_anterior`, mismo `stock_nuevo`, dentro de 1 segundo, sin referencia
--   ni usuario). Se borra la `auto` y se conserva la `control_stock`, que es la
--   que tiene la sesion y el usuario --y la que lee
--   `useControlStockQuery.fetchDetalle`, que filtra `origen='control_stock'`--.
--   STK-A no se mueve: las dos filas del par tienen el MISMO `stock_nuevo`, asi
--   que la "ultima fila" de cada producto sigue diciendo lo mismo. STK-D baja
--   41.
--
-- · `'compra'` NO entra a la lista blanca de `sincronizar_lotes_stock`. Una
--   compra sube mercaderia NUEVA: va a la bolsa "sin vencimiento", igual que
--   hoy con `'auto'`. Lo mismo `'control_stock'`: un conteo que encuentra
--   unidades de mas no sabe de que lote son, y el camino de BAJADA del trigger
--   no mira el origen, asi que un conteo a la baja sigue consumiendo FEFO como
--   siempre. Ninguno de los dos cambia una sola unidad de `producto_lotes`:
--   cambia quien figura en el ledger.
--
-- · Con `registrar_compra_completa` etiquetada, la excepcion que la 229 le puso
--   al check STK-F deja de tener sentido y SE SACA. Queda sola
--   `registrar_ingreso_sucursal`. Si alguien le quita la etiqueta a la compra,
--   ahora el gate se pone rojo.
--
-- · El `EXCEPTION` de `sustituir_regalo_pedido` se acota a los dos SQLSTATE que
--   vale la pena traducir y el resto propaga:
--     - `raise_exception` (P0001): las validaciones de negocio de los triggers
--       de `pedido_items` (`validar_minimo_venta_item`,
--       `validar_precio_item_pedido`). Son mensajes escritos para el usuario;
--       siguen llegando como `{success:false, error:...}`, igual que hoy.
--     - `unique_violation` (23505): el unico indice unico de
--       `pedido_item_sustituciones` aparte del PK es el parcial sobre
--       `client_request_id`. Es la carrera de dos envios simultaneos de la
--       misma sustitucion, o sea exactamente lo que la guarda de arriba ya
--       resuelve cuando la otra transaccion commiteo antes. Se devuelve el
--       mismo `idempotent_replay`.
--   Todo lo demas --un `record ... is not assigned`, un deadlock, una columna
--   que no existe-- propaga y llega al front como error de verdad. El hook
--   (`useSustituirRegaloMutation.ts:26`) ya hace `if (error) throw error`.
--
-- QUE NO SE TOCA: nada de lo que parchearon la 229 (devoluciones y lista
-- blanca de lotes) ni la 236 (compras y costo promedio), mas alla de las
-- cuatro lineas de `set_config` que se agregan al alta de compra.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 0 · El andamio: cirugia por ancla sobre el cuerpo vivo.
--     Mismo helper que usan la 229 y la 236. Falla si el ancla no aparece
--     exactamente una vez: si otra sesion cambio el cuerpo, esta migracion no
--     entra a medias.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._mig240_ancla(
  p_funcion regprocedure,
  p_ancla   text,
  p_nuevo   text
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
-- 1 · aplicar_control_stock: el trigger escribe la fila, la RPC le pone nombre.
--
--     El cuerpo vivo es identico al del archivo 078 (md5 verificado antes de
--     escribir esta migracion), asi que se reemplaza entero en vez de parchear
--     por ancla: es mas corto de leer y no hay nada de otra migracion que
--     preservar.
--
--     Las cuatro GUCs se setean UNA vez, despues de crear la sesion y antes del
--     bucle: son las mismas para todas las lineas de la planilla y
--     `set_config(..., true)` es por TRANSACCION, no por sentencia.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.aplicar_control_stock(
  p_ajustes      jsonb,
  p_observaciones text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal_id   bigint;
  v_usuario_id    uuid;
  v_sesion_id     bigint;
  v_total_items   integer := 0;
  v_total_altas   integer := 0;
  v_total_bajas   integer := 0;
  v_ajuste        jsonb;
  v_producto_id   bigint;
  v_stock_real    integer;
  v_stock_actual  integer;
  v_diferencia    integer;
  v_aplicados     jsonb := '[]'::jsonb;
  v_no_encontrados jsonb := '[]'::jsonb;
BEGIN
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Solo un administrador puede aplicar ajustes de control de stock';
  END IF;

  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa';
  END IF;
  v_usuario_id := auth.uid();

  INSERT INTO control_stock_sesiones (usuario_id, sucursal_id, observaciones)
  VALUES (v_usuario_id, v_sucursal_id, p_observaciones)
  RETURNING id INTO v_sesion_id;

  /* mig 240 · el ledger lo escribe el trigger, no esta funcion.
     Antes habia un INSERT a mano en stock_historico ADEMAS del que ya dejaba
     trg_stock_historico por el UPDATE: dos filas por diferencia, una util y
     una 'auto' anonima. Ahora se etiqueta el contexto y la unica fila que
     queda es la del trigger, con la sesion y el usuario adentro --lo mismo que
     lee fetchDetalle, que filtra origen='control_stock'--.
     'control_stock' NO esta en la lista blanca de sincronizar_lotes_stock a
     proposito: un conteo que encuentra unidades de mas no sabe de que lote
     son, y van a la bolsa sin vencimiento, igual que antes con 'auto'. El
     camino de BAJADA del trigger no mira el origen, asi que un conteo a la
     baja sigue consumiendo FEFO como siempre. */
  PERFORM set_config('app.stock_origen',   'control_stock', true);
  PERFORM set_config('app.stock_ref_tipo', 'control_stock_sesion', true);
  PERFORM set_config('app.stock_ref_id',   v_sesion_id::text, true);
  PERFORM set_config('app.stock_user_id',  COALESCE(v_usuario_id::text, ''), true);

  FOR v_ajuste IN SELECT * FROM jsonb_array_elements(COALESCE(p_ajustes, '[]'::jsonb))
  LOOP
    v_producto_id := (v_ajuste->>'producto_id')::bigint;
    -- stock_real vacío/null => ítem no contado => se saltea (no se ajusta a 0).
    IF (v_ajuste->>'stock_real') IS NULL OR btrim(v_ajuste->>'stock_real') = '' THEN
      CONTINUE;
    END IF;
    v_stock_real := round((v_ajuste->>'stock_real')::numeric)::integer;
    IF v_stock_real < 0 THEN
      CONTINUE;
    END IF;

    SELECT stock INTO v_stock_actual
    FROM productos
    WHERE id = v_producto_id AND sucursal_id = v_sucursal_id
    FOR UPDATE;

    IF NOT FOUND THEN
      v_no_encontrados := v_no_encontrados || jsonb_build_object('producto_id', v_producto_id);
      CONTINUE;
    END IF;

    v_diferencia := v_stock_real - v_stock_actual;

    IF v_diferencia <> 0 THEN
      UPDATE productos SET stock = v_stock_real, updated_at = now()
      WHERE id = v_producto_id AND sucursal_id = v_sucursal_id;

      v_total_items := v_total_items + 1;
      IF v_diferencia > 0 THEN
        v_total_altas := v_total_altas + v_diferencia;
      ELSE
        v_total_bajas := v_total_bajas + abs(v_diferencia);
      END IF;

      v_aplicados := v_aplicados || jsonb_build_object(
        'producto_id', v_producto_id,
        'stock_anterior', v_stock_actual,
        'stock_nuevo', v_stock_real,
        'diferencia', v_diferencia
      );
    END IF;
  END LOOP;

  UPDATE control_stock_sesiones
  SET total_items = v_total_items, total_altas = v_total_altas, total_bajas = v_total_bajas
  WHERE id = v_sesion_id;

  RETURN jsonb_build_object(
    'sesion_id', v_sesion_id,
    'total_items', v_total_items,
    'total_altas', v_total_altas,
    'total_bajas', v_total_bajas,
    'aplicados', v_aplicados,
    'no_encontrados', v_no_encontrados
  );
END;
$function$;

-- Toda funcion de public nace con EXECUTE para PUBLIC y Supabase se lo concede
-- ademas a anon: las dos mitades se revocan juntas.
REVOKE ALL ON FUNCTION public.aplicar_control_stock(jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.aplicar_control_stock(jsonb, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2 · Las filas duplicadas que ya estan escritas.
--
--     Se borra la gemela 'auto' de cada fila 'control_stock'. El pareo exige
--     mismo producto, misma sucursal, mismo stock_anterior, mismo stock_nuevo y
--     menos de 1 segundo de diferencia, y que la 'auto' no tenga referencia ni
--     usuario (es decir: que sea la que dejo el trigger sin contexto). Medido
--     antes de aplicar: 41 filas 'control_stock' y 41 gemelas, 1:1.
-- ---------------------------------------------------------------------------
DO $limpieza$
DECLARE
  v_cs       bigint;
  v_borradas bigint;
BEGIN
  SELECT count(*) INTO v_cs FROM public.stock_historico WHERE origen = 'control_stock';

  WITH gemelas AS (
    SELECT a.id
      FROM public.stock_historico a
      JOIN public.stock_historico cs
        ON cs.origen         = 'control_stock'
       AND cs.producto_id    = a.producto_id
       AND cs.sucursal_id   IS NOT DISTINCT FROM a.sucursal_id
       AND cs.stock_anterior = a.stock_anterior
       AND cs.stock_nuevo    = a.stock_nuevo
       AND a.created_at BETWEEN cs.created_at - interval '1 second'
                            AND cs.created_at + interval '1 second'
     WHERE a.origen = 'auto'
       AND a.referencia_tipo IS NULL
       AND a.referencia_id   IS NULL
       AND a.usuario_id      IS NULL
  )
  DELETE FROM public.stock_historico s
   USING gemelas g
   WHERE s.id = g.id;

  GET DIAGNOSTICS v_borradas = ROW_COUNT;

  IF v_borradas > v_cs THEN
    RAISE EXCEPTION 'mig240 · se borraron % filas auto para % filas control_stock: el pareo no es 1:1, revisar a mano.',
      v_borradas, v_cs;
  END IF;

  RAISE NOTICE 'mig240 · duplicadas borradas: % (filas control_stock: %)', v_borradas, v_cs;
END
$limpieza$;

-- ---------------------------------------------------------------------------
-- 3 · registrar_compra_completa: la mercaderia nueva dice de que factura viene.
--
--     Las cuatro GUCs van apenas se conoce v_compra_id (o sea, despues del
--     INSERT de cabecera) y antes de cualquier UPDATE de stock. La funcion no
--     tenia NINGUN set_config, asi que no hay etiqueta ajena que pisar.
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE v_fn regprocedure;
BEGIN
  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'registrar_compra_completa';

  PERFORM public._mig240_ancla(v_fn,
$ancla$  )
  RETURNING id INTO v_compra_id;
$ancla$,
$nuevo$  )
  RETURNING id INTO v_compra_id;

  /* mig 240 · el ledger de stock sabe de que compra vino la mercaderia.
     Era el ultimo camino de stock sin etiquetar: las entradas por compra caian
     como origen='auto', sin referencia ni usuario, y las contaba STK-D.
     'compra' NO va a la lista blanca de sincronizar_lotes_stock: lo que sube
     es mercaderia NUEVA y va a la bolsa "sin vencimiento", como hasta hoy. El
     lote, cuando la factura trae vencimiento, se carga aparte. */
  PERFORM set_config('app.stock_origen',   'compra', true);
  PERFORM set_config('app.stock_ref_tipo', 'compra', true);
  PERFORM set_config('app.stock_ref_id',   v_compra_id::TEXT, true);
  PERFORM set_config('app.stock_user_id',  COALESCE(p_usuario_id::TEXT, ''), true);
$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 4 · STK-F pierde una excepcion.
--
--     La 229 dejo afuera del check a registrar_compra_completa y a
--     registrar_ingreso_sucursal "para que el gate arranque en verde". La
--     primera ya no lo necesita. La segunda sigue: sube mercaderia nueva sin
--     etiquetar y no la toca esta migracion.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.auditoria_funciones_stock_sin_origen()
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
  SELECT count(*)
    FROM pg_proc f
   WHERE f.pronamespace = 'public'::regnamespace
     AND f.prokind = 'f'
     AND f.proname NOT IN ('registrar_ingreso_sucursal')
     AND pg_get_functiondef(f.oid) ~* 'UPDATE\s+productos\s+(AS\s+)?(\w+\s+)?SET[^;]*\ystock\s*=\s*(\w+\.)?stock\s*\+'
     AND pg_get_functiondef(f.oid) NOT LIKE '%app.stock_origen%';
$fn$;

COMMENT ON FUNCTION public.auditoria_funciones_stock_sin_origen() IS
  'Cuenta funciones de public que suben productos.stock sin declarar '
  'app.stock_origen. Alimenta el check STK-F. mig 229; la mig 240 le saco la '
  'excepcion de registrar_compra_completa, que ahora etiqueta.';

REVOKE ALL ON FUNCTION public.auditoria_funciones_stock_sin_origen() FROM PUBLIC, anon;

-- ---------------------------------------------------------------------------
-- 5 · sustituir_regalo_pedido: el regalo sin promocion se rechaza a tiempo, y
--     el EXCEPTION deja de tragarse los errores de verdad.
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE v_fn regprocedure;
BEGIN
  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'sustituir_regalo_pedido';

  -- 5.a) El rechazo temprano.
  PERFORM public._mig240_ancla(v_fn,
$ancla$  IF v_item.promocion_id IS NOT NULL THEN
    SELECT id, regalo_mueve_stock, ajuste_automatico, producto_regalo_id,
           ajuste_producto_id, unidades_por_bloque, stock_por_bloque, usos_pendientes
      INTO v_promo FROM promociones WHERE id = v_item.promocion_id AND sucursal_id = v_sucursal;
  END IF;
$ancla$,
$nuevo$  /* mig 240 · sin promocion no hay sustitucion.
     v_promo se cargaba solo si habia promocion_id y dos lineas despues se leia
     igual (COALESCE(v_promo.regalo_mueve_stock, TRUE)): con un bonificado sin
     promocion la funcion moria con 'record "v_promo" is not assigned yet' y el
     EXCEPTION lo devolvia como si fuera una validacion. Ahora se rechaza
     antes, con un mensaje que dice que hacer. */
  IF v_item.promocion_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Este regalo no viene de una promoción, así que no se puede sustituir desde acá. Editá el pedido para cambiarlo.');
  END IF;
  SELECT id, regalo_mueve_stock, ajuste_automatico, producto_regalo_id,
         ajuste_producto_id, unidades_por_bloque, stock_por_bloque, usos_pendientes
    INTO v_promo FROM promociones WHERE id = v_item.promocion_id AND sucursal_id = v_sucursal;
$nuevo$);

  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'sustituir_regalo_pedido';

  -- 5.b) El EXCEPTION acotado.
  PERFORM public._mig240_ancla(v_fn,
$ancla$EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$ancla$,
$nuevo$/* mig 240 · el handler generico traducia TODO a {success:false}: un bug de
   programacion llegaba al usuario con la misma cara que "stock insuficiente",
   y no habia forma de distinguirlos ni desde el front ni desde Sentry. Quedan
   los dos SQLSTATE que vale la pena traducir; el resto propaga. */
EXCEPTION
  WHEN unique_violation THEN
    -- El unico indice unico de pedido_item_sustituciones aparte del PK es el
    -- parcial sobre client_request_id: dos envios simultaneos de la misma
    -- sustitucion. El que perdio la carrera lee lo que el otro ya commiteo y
    -- devuelve el mismo replay que la guarda de arriba.
    SELECT id INTO v_existing
      FROM pedido_item_sustituciones
     WHERE client_request_id = p_client_request_id;
    IF FOUND THEN
      RETURN jsonb_build_object('success', true, 'sustitucion_id', v_existing.id, 'idempotent_replay', true);
    END IF;
    RAISE;
  WHEN raise_exception THEN
    -- P0001: las validaciones de negocio de los triggers de pedido_items
    -- (validar_minimo_venta_item, validar_precio_item_pedido). Son mensajes
    -- escritos para el usuario.
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 6 · Verificacion sobre el cuerpo que quedo vivo.
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  v_def    text;
  v_fallas text := '';
  v_n      bigint;
BEGIN
  -- 6.a) aplicar_control_stock
  v_def := pg_get_functiondef('public.aplicar_control_stock(jsonb, text)'::regprocedure);
  IF v_def LIKE '%INSERT INTO stock_historico%' THEN
    v_fallas := v_fallas || ' [aplicar_control_stock sigue insertando a mano en stock_historico]';
  END IF;
  IF v_def NOT LIKE '%app.stock_origen%' OR v_def NOT LIKE '%control_stock_sesion%' THEN
    v_fallas := v_fallas || ' [aplicar_control_stock no etiqueta el contexto]';
  END IF;

  -- 6.b) registrar_compra_completa
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'registrar_compra_completa';
  IF v_def NOT LIKE '%app.stock_origen%' THEN
    v_fallas := v_fallas || ' [registrar_compra_completa no etiqueta el contexto]';
  END IF;

  -- 6.c) sustituir_regalo_pedido
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'sustituir_regalo_pedido';
  -- Ojo con el patron: el cuerpo nuevo HABLA del handler generico en un
  -- comentario, asi que se busca la clausula entera, no las dos palabras.
  IF v_def LIKE '%EXCEPTION WHEN OTHERS%' THEN
    v_fallas := v_fallas || ' [sustituir_regalo_pedido sigue con el handler generico]';
  END IF;
  IF v_def NOT LIKE '%no viene de una promoci%' THEN
    v_fallas := v_fallas || ' [sustituir_regalo_pedido no rechaza el regalo sin promocion]';
  END IF;

  -- 6.d) STK-F en cero (ya sin la excepcion de la compra) y STK-A intacto.
  SELECT public.auditoria_funciones_stock_sin_origen() INTO v_n;
  IF v_n <> 0 THEN
    v_fallas := v_fallas || format(' [STK-F en rojo: %s funcion(es) suben stock sin origen]', v_n);
  END IF;

  SELECT count(*) INTO v_n
    FROM productos p
    JOIN (SELECT DISTINCT ON (producto_id, sucursal_id) producto_id, sucursal_id, stock_nuevo
            FROM stock_historico ORDER BY producto_id, sucursal_id, created_at DESC, id DESC) u
      ON u.producto_id = p.id AND u.sucursal_id = p.sucursal_id
   WHERE p.stock <> u.stock_nuevo;
  IF v_n <> 0 THEN
    v_fallas := v_fallas || format(' [STK-A en rojo despues de la limpieza: %s producto(s)]', v_n);
  END IF;

  -- 6.e) No quedan gemelas.
  SELECT count(*) INTO v_n
    FROM public.stock_historico a
    JOIN public.stock_historico cs
      ON cs.origen = 'control_stock'
     AND cs.producto_id = a.producto_id
     AND cs.sucursal_id IS NOT DISTINCT FROM a.sucursal_id
     AND cs.stock_anterior = a.stock_anterior
     AND cs.stock_nuevo = a.stock_nuevo
     AND a.created_at BETWEEN cs.created_at - interval '1 second'
                          AND cs.created_at + interval '1 second'
   WHERE a.origen = 'auto' AND a.referencia_tipo IS NULL
     AND a.referencia_id IS NULL AND a.usuario_id IS NULL;
  IF v_n <> 0 THEN
    v_fallas := v_fallas || format(' [quedaron %s filas auto gemelas]', v_n);
  END IF;

  IF v_fallas <> '' THEN
    RAISE EXCEPTION 'mig240 · la verificacion encontro:%', v_fallas;
  END IF;
  RAISE NOTICE 'mig240 · verificacion de cuerpos OK';
END
$verif$;

-- ---------------------------------------------------------------------------
-- 7 · Ensayo funcional, sobre el cuerpo vivo y con ROLLBACK.
--     Los tres escenarios de aceptacion, medidos en el momento de aplicar.
--     Todo lo que crea se deshace con el RAISE del final del bloque interno
--     (mismo molde que la 236); solo avanzan las secuencias.
-- ---------------------------------------------------------------------------
DO $ensayo$
DECLARE
  v_uid      uuid;
  v_suc      bigint;
  v_fallas   text := '';
  v_filas_a  int;
  v_origen_a text;
  v_ref_a    text;
  v_user_a   boolean;
  v_filas_b  int;
  v_origen_b text;
  v_ref_b    boolean;
  v_user_b   boolean;
  v_ok_c     boolean;
  v_err_c    text;
BEGIN
  SELECT p.id, us.sucursal_id INTO v_uid, v_suc
    FROM perfiles p
    JOIN usuario_sucursales us ON us.usuario_id = p.id AND us.es_default
   WHERE p.rol = 'admin'
   ORDER BY p.id
   LIMIT 1;

  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'mig240: no hay ningun admin con sucursal por defecto; el ensayo no puede correr.';
  END IF;

  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);

    DECLARE
      v_p1 bigint; v_p2 bigint; v_p3 bigint; v_pc bigint;
      v_cli bigint; v_ped bigint; v_it bigint;
      v_res jsonb; v_compra bigint;
    BEGIN
      -------------------------------------------------------------------
      -- A · una planilla con 2 diferencias deja 2 filas, no 4
      -------------------------------------------------------------------
      INSERT INTO productos (nombre, precio, sucursal_id, stock)
        VALUES ('ZZZ mig240 A1', 100, v_suc, 100) RETURNING id INTO v_p1;
      INSERT INTO productos (nombre, precio, sucursal_id, stock)
        VALUES ('ZZZ mig240 A2', 100, v_suc, 50) RETURNING id INTO v_p2;
      INSERT INTO productos (nombre, precio, sucursal_id, stock)
        VALUES ('ZZZ mig240 A3', 100, v_suc, 7) RETURNING id INTO v_p3;

      -- dos diferencias (una a la baja, una al alta) y un producto sin
      -- diferencia, que no tiene que dejar ninguna fila.
      v_res := aplicar_control_stock(jsonb_build_array(
                 jsonb_build_object('producto_id', v_p1, 'stock_real', 90),
                 jsonb_build_object('producto_id', v_p2, 'stock_real', 55),
                 jsonb_build_object('producto_id', v_p3, 'stock_real', 7)),
                 'ZZZ ensayo mig240');

      SELECT count(*),
             string_agg(DISTINCT origen, ','),
             string_agg(DISTINCT COALESCE(referencia_tipo, '-') || ':' || COALESCE(referencia_id::text, '-'), ','),
             bool_and(usuario_id = v_uid)
        INTO v_filas_a, v_origen_a, v_ref_a, v_user_a
        FROM stock_historico WHERE producto_id IN (v_p1, v_p2, v_p3);

      -------------------------------------------------------------------
      -- B · una compra deja una fila con origen y referencia
      -------------------------------------------------------------------
      INSERT INTO productos (nombre, precio, sucursal_id, stock)
        VALUES ('ZZZ mig240 B', 100, v_suc, 0) RETURNING id INTO v_pc;

      v_res := registrar_compra_completa(NULL, 'ZZZ mig240', 'ZZZ-240', CURRENT_DATE,
                 100, 0, 0, 100, 'efectivo', 'ensayo mig240', v_uid,
                 jsonb_build_array(jsonb_build_object(
                   'producto_id', v_pc, 'cantidad', 10, 'costo_unitario', 10, 'subtotal', 100,
                   'bonificacion', 0, 'porcentaje_iva', 0, 'impuestos_internos', 0,
                   'condicion_iva', 'no_gravado')),
                 'FC', 0, 0, 0, 0, '[]'::jsonb, '{}'::jsonb, 0);
      IF NOT (v_res->>'success')::boolean THEN
        RAISE EXCEPTION 'B · el alta de compra fallo: %', v_res->>'error';
      END IF;
      v_compra := (v_res->>'compra_id')::bigint;

      SELECT count(*), string_agg(DISTINCT origen, ','),
             bool_and(referencia_tipo = 'compra' AND referencia_id = v_compra),
             bool_and(usuario_id = v_uid)
        INTO v_filas_b, v_origen_b, v_ref_b, v_user_b
        FROM stock_historico WHERE producto_id = v_pc;

      -------------------------------------------------------------------
      -- C · sustituir un regalo sin promocion devuelve el mensaje nuevo
      -------------------------------------------------------------------
      INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
        VALUES ('ZZZ mig240', 'ZZZ mig240', 'ZZZ', v_suc) RETURNING id INTO v_cli;
      INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado)
        VALUES (v_cli, v_suc, v_uid, 0, 'pendiente') RETURNING id INTO v_ped;
      INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario,
                                subtotal, sucursal_id, es_bonificacion)
        VALUES (v_ped, v_p1, 1, 0, 0, v_suc, true) RETURNING id INTO v_it;

      v_res  := sustituir_regalo_pedido(v_it, v_p2, 1, 'ensayo mig240', NULL, gen_random_uuid());
      v_ok_c  := (v_res->>'success')::boolean;
      v_err_c := v_res->>'error';
    END;

    RAISE EXCEPTION 'mig240_rollback_del_ensayo';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'mig240_rollback_del_ensayo' THEN
      RAISE EXCEPTION 'mig240 · el ensayo funcional exploto: %', SQLERRM;
    END IF;
  END;

  -- A
  IF v_filas_a <> 2 THEN
    v_fallas := v_fallas || format(' [A: 2 diferencias dejaron %s filas en stock_historico (antes de la 240 dejaban 4)]', v_filas_a);
  END IF;
  IF v_origen_a IS DISTINCT FROM 'control_stock' THEN
    v_fallas := v_fallas || format(' [A: los origenes fueron "%s" y tenian que ser solo control_stock]', v_origen_a);
  END IF;
  IF v_ref_a IS NULL OR v_ref_a NOT LIKE 'control_stock_sesion:%' OR v_ref_a LIKE '%,%' THEN
    v_fallas := v_fallas || format(' [A: la referencia quedo en "%s"]', v_ref_a);
  END IF;
  IF NOT COALESCE(v_user_a, false) THEN
    v_fallas := v_fallas || ' [A: las filas no quedaron a nombre del usuario]';
  END IF;
  -- B
  IF v_filas_b <> 1 THEN
    v_fallas := v_fallas || format(' [B: la compra dejo %s filas en vez de 1]', v_filas_b);
  END IF;
  IF v_origen_b IS DISTINCT FROM 'compra' THEN
    v_fallas := v_fallas || format(' [B: el origen fue "%s" en vez de compra]', v_origen_b);
  END IF;
  IF NOT COALESCE(v_ref_b, false) THEN
    v_fallas := v_fallas || ' [B: la fila no apunta a la compra]';
  END IF;
  IF NOT COALESCE(v_user_b, false) THEN
    v_fallas := v_fallas || ' [B: la fila no quedo a nombre del usuario]';
  END IF;
  -- C
  IF COALESCE(v_ok_c, true) THEN
    v_fallas := v_fallas || ' [C: sustituir un regalo sin promocion no fue rechazado]';
  END IF;
  IF v_err_c IS NULL OR v_err_c NOT LIKE '%no viene de una promoci%' THEN
    v_fallas := v_fallas || format(' [C: el error fue "%s" en vez del mensaje nuevo]', v_err_c);
  END IF;

  IF v_fallas <> '' THEN
    RAISE EXCEPTION 'mig240 · el ensayo funcional encontro:%', v_fallas;
  END IF;

  RAISE NOTICE 'mig240 · ensayo funcional OK: A filas=% origen=% ref=% · B filas=% origen=% · C error=%',
    v_filas_a, v_origen_a, v_ref_a, v_filas_b, v_origen_b, v_err_c;
END
$ensayo$;

-- ---------------------------------------------------------------------------
-- 8 · Se saca el andamio.
-- ---------------------------------------------------------------------------
DROP FUNCTION public._mig240_ancla(regprocedure, text, text);

COMMIT;
