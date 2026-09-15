-- 252 · El regalo sustituido descuenta del que se entrega
--
-- Cuatro items. Tres son chicos; el primero es el que manda.
--
-- 1 · #653 · `aplicar_sustituciones_regalo_pre_insert` reescribe NEW.producto_id
--     al sustituto, pero `actualizar_pedido_items` ya habia decidido dos cosas
--     con el producto_id del JSON --el ORIGINAL-- que el trigger no revisa:
--
--       · el descuento de stock (`UPDATE productos SET stock = stock - N`), y
--       · desde la 242, `v_container_id`, el contenedor del auto-ajuste.
--
--     La reversion --el FOR agrupado de la misma funcion, cancelar_pedido_con_stock,
--     eliminar_pedido_completo, registrar_salvedad-- lee el producto_id GUARDADO,
--     o sea el sustituto. El fardo salia de un contenedor y volvia a otro: la
--     misma forma que cerro la 242, por otra puerta. Y la 242 lo empeoro, porque
--     antes las dos puntas usaban `ajuste_producto_id` pelado.
--
--     Decision del dueño: el stock y el contenedor SIGUEN AL RENGLON GUARDADO.
--     `sustituir_regalo_pedido` ya movio el stock del original al sustituto
--     cuando se registro la sustitucion (modo A) o reapunto el acumulador
--     (modo B), y las cuatro reversiones ya leen el guardado. El que estaba
--     desalineado era el alta, y es el que se alinea: `INSERT ... RETURNING
--     producto_id` y ese valor manda.
--
--     Por que RETURNING y no "resolver la sustitucion a mano": el que sabe que
--     producto quedo en la fila es la fila. Si mañana el trigger cambia de
--     criterio, el alta lo sigue sin enterarse.
--
--     Que NO arregla: los pedidos historicos. Se miden y se listan en el PR.
--
-- 2 · #632 · `posicion_fiscal` filtraba `canal = 'app'`. Pasa a `canal <> 'cambio'`,
--     que es la definicion de la 241: las ventas del bot se facturan igual.
--
-- 3 · Salvedades, tres puntas:
--     (a) `es_admin_salvedades()` era `es_admin()` sin STABLE y con dos llamadores.
--         Se reemplaza en los dos y se dropea.
--     (b) El encargado veia el boton "Resolver" y el servidor le contestaba
--         "Solo admin". Se decide UNA cosa y se aplica en los dos lados:
--         resolver SI (es_encargado_o_admin), anular NO (es_admin).
--     (c) `anular_salvedad` le inserta items a un pedido entregado y pasa el
--         guard sólo por ser SECURITY DEFINER. Queda escrito en los dos cuerpos
--         y hay un ensayo que se pone rojo si deja de serlo.
--
-- 4 · #661 (la mitad de base) · `bot_audit_log` tenia 406 de 538 filas con mas de
--     90 dias porque el cron de la 016 nunca existio: pg_cron no esta instalada.
--     Se aplica el patron de retencion AL ESCRIBIR de la 073 y la 248. No se
--     instala pg_cron. El digest es OPS-6 y no entra aca.
--
-- Dos checks nuevos en `auditoria_integridad()`: PROMO-B y BOT-A. Los dos medidos
-- contra prod ANTES de agregarlos: 0 violaciones y 0 violaciones.
--
-- Tecnica: parche por ancla sobre el cuerpo vivo (molde de la 241/242/244).

BEGIN;

-- ---------------------------------------------------------------------------
-- 0 · Andamio: parche por ancla, con la guarda de "exactamente una vez".
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 1 · #653 · actualizar_pedido_items: el alta sigue al renglon guardado.
--
--     Cuatro parches sobre el mismo cuerpo:
--       1.1 · dos variables nuevas
--       1.2 · el pre-chequeo de stock mide el producto que se va a descontar
--       1.3 · el INSERT devuelve lo que quedo en la fila
--       1.4 · los tres usos (dos descuentos y el contenedor) pasan a ese valor
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  -- 1.1 · Las dos variables.
  PERFORM public._migsv_ancla('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure,
$ancla$  v_container_id BIGINT;$ancla$,
$nuevo$  v_container_id BIGINT;
  -- mig 252 (#653): lo que el trigger de sustituciones dejo REALMENTE en la
  -- fila. Todo lo que mueve stock de aca para abajo se cuelga de este valor,
  -- no del producto_id que vino en el JSON.
  v_producto_guardado BIGINT;
  v_producto_sustituto BIGINT;$nuevo$);

  -- 1.2 · El pre-chequeo de stock.
  --
  --       Sin esto el fix queda a medias: el descuento pasa a salir del
  --       sustituto pero la validacion sigue exigiendole stock al original, y
  --       un regalo que se sustituyo JUSTAMENTE porque el original se quedo sin
  --       stock hace fallar la edicion entera con "stock insuficiente" de un
  --       producto que nadie va a tocar. El pre-vuelo tiene que medir el mismo
  --       producto que el vuelo.
  --
  --       Pisar v_producto_id es seguro: los dos FOR lo releen del JSON en cada
  --       vuelta.
  PERFORM public._migsv_ancla('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure,
$ancla$    SELECT COALESCE(cantidad, 0) INTO v_cantidad_original
    FROM pedido_items
    WHERE pedido_id = p_pedido_id AND producto_id = v_producto_id
      AND COALESCE(es_bonificacion, false) = v_es_bonificacion
      AND sucursal_id = v_sucursal;$ancla$,
$nuevo$    -- mig 252 (#653): mismo criterio que aplicar_sustituciones_regalo_pre_insert.
    -- El pre-chequeo de stock tiene que mirar el producto que REALMENTE se va a
    -- descontar: si no, un regalo sustituido justamente porque el original se
    -- quedo sin stock hace fallar la edicion entera con "stock insuficiente" de
    -- un producto que nadie va a tocar. Pisar v_producto_id es seguro: los dos
    -- FOR lo releen del JSON en cada vuelta.
    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      v_producto_sustituto := NULL;
      SELECT producto_sustituto_id INTO v_producto_sustituto
        FROM pedido_item_sustituciones
       WHERE pedido_id = p_pedido_id
         AND promocion_id = v_promocion_id
         AND producto_original_id = v_producto_id
         AND sucursal_id = v_sucursal
       ORDER BY created_at DESC
       LIMIT 1;
      IF v_producto_sustituto IS NOT NULL THEN
        v_producto_id := v_producto_sustituto;
      END IF;
    END IF;

    SELECT COALESCE(cantidad, 0) INTO v_cantidad_original
    FROM pedido_items
    WHERE pedido_id = p_pedido_id AND producto_id = v_producto_id
      AND COALESCE(es_bonificacion, false) = v_es_bonificacion
      AND sucursal_id = v_sucursal;$nuevo$);

  -- 1.3 · El INSERT devuelve el producto que quedo en la fila.
  PERFORM public._migsv_ancla('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure,
$ancla$      v_sucursal, v_descripcion_regalo, v_costo_al_crear
    );$ancla$,
$nuevo$      v_sucursal, v_descripcion_regalo, v_costo_al_crear
    )
    -- mig 252 (#653): aplicar_sustituciones_regalo_pre_insert puede haber
    -- reescrito producto_id al sustituto. Lo que sigue descuenta stock y elige
    -- contenedor: tiene que hablar del renglon que quedo, no del que se pidio.
    RETURNING producto_id INTO v_producto_guardado;$nuevo$);

  -- 1.4 · Los tres usos.
  PERFORM public._migsv_ancla('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure,
$ancla$    IF NOT v_es_bonificacion THEN
      UPDATE productos SET stock = stock - v_cantidad_nueva WHERE id = v_producto_id AND sucursal_id = v_sucursal;$ancla$,
$nuevo$    IF NOT v_es_bonificacion THEN
      UPDATE productos SET stock = stock - v_cantidad_nueva WHERE id = v_producto_guardado AND sucursal_id = v_sucursal;$nuevo$);

  PERFORM public._migsv_ancla('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure,
$ancla$      IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
        UPDATE productos SET stock = stock - v_cantidad_nueva WHERE id = v_producto_id AND sucursal_id = v_sucursal;
      END IF;$ancla$,
$nuevo$      IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
        UPDATE productos SET stock = stock - v_cantidad_nueva WHERE id = v_producto_guardado AND sucursal_id = v_sucursal;
      END IF;$nuevo$);

  PERFORM public._migsv_ancla('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure,
$ancla$      v_container_id := CASE WHEN v_promo.producto_regalo_id IS DISTINCT FROM v_producto_id
                             THEN v_producto_id ELSE v_promo.ajuste_producto_id END;$ancla$,
$nuevo$      -- mig 252 (#653): el contenedor del que sale el fardo se decide con el
      -- producto GUARDADO, que es el mismo que van a leer las cuatro
      -- reversiones. Con v_producto_id el fardo salia de uno y volvia a otro.
      v_container_id := CASE WHEN v_promo.producto_regalo_id IS DISTINCT FROM v_producto_guardado
                             THEN v_producto_guardado ELSE v_promo.ajuste_producto_id END;$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 2 · #632 · posicion_fiscal: el canal se filtra en negativo.
--
--     Misma definicion que la 241. Hoy no hay pedidos canal='bot' en prod (0),
--     asi que el numero del mes no se mueve; lo que cambia es que el dia que
--     los haya, se facturan.
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._migsv_ancla('public.posicion_fiscal(bigint,date,date)'::regprocedure,
$ancla$    WHERE estado = 'entregado' AND canal = 'app'$ancla$,
$nuevo$    -- mig 252 (#632): canal EN NEGATIVO, como la 241. La venta del bot se factura igual.
    WHERE estado = 'entregado' AND canal <> 'cambio'$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 3 · Salvedades · resolver lo puede el encargado; anular, no.
--
--     La asimetria no es un descuido, es la regla: `resolver_salvedad` sólo
--     escribe QUIEN se hace cargo --no mueve ni un peso ni una unidad--,
--     mientras que `anular_salvedad` restituye la linea, recalcula los totales
--     (el cliente vuelve a pagar lo que la salvedad le habia sacado) y revierte
--     la merma. La 065 ya deja al encargado REGISTRAR salvedades; que pueda
--     cerrar el circuito de las que registra es la misma altura. Mover plata
--     no lo es.
--
--     Hasta hoy el front mostraba "Resolver" a los dos roles y el servidor le
--     contestaba "Solo admin" al encargado. El espejo se arregla de los dos
--     lados: aca y en `puedeResolverSalvedad` (src/lib/permisos.ts).
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._migsv_ancla('public.resolver_salvedad(bigint,character varying,text,bigint)'::regprocedure,
$ancla$  IF NOT es_admin_salvedades() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin');
  END IF;$ancla$,
$nuevo$  -- mig 252: resolver una salvedad no mueve stock ni plata: solo dice quien se
  -- hace cargo. Lo puede el encargado, que es el que ya las registra (mig 065).
  -- Anularlas --que si mueve las dos cosas-- sigue siendo de admin.
  -- El espejo en la UI es `puedeResolverSalvedad`.
  IF NOT es_encargado_o_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin o encargado');
  END IF;$nuevo$);

  PERFORM public._migsv_ancla('public.anular_salvedad(bigint,text)'::regprocedure,
$ancla$  IF NOT es_admin_salvedades() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin');
  END IF;$ancla$,
$nuevo$  /* mig 252: SOLO ADMIN, y a proposito: anular restituye la linea, recalcula
     los totales y revierte la merma. Resolver, que no mueve nada, lo puede el
     encargado. El espejo en la UI es `puedeAnularSalvedad`.

     Y de paso, lo que hace que esta funcion pueda existir: mas abajo le inserta
     un pedido_item a un pedido YA ENTREGADO. Eso lo prohibe
     `pedido_items_guard_estado`, y pasa por un solo motivo: esta funcion es
     SECURITY DEFINER y es de postgres, asi que el guard la ve con
     current_user <> 'authenticated' y la deja pasar. Si alguien le saca el
     SECURITY DEFINER, anular deja de funcionar para las salvedades cuya linea
     habia quedado en cero. El ensayo de la 252 se pone rojo si eso pasa. */
  IF NOT es_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin');
  END IF;$nuevo$);

  -- El guard, del otro lado del mismo contrato.
  PERFORM public._migsv_ancla('public.pedido_items_guard_estado()'::regprocedure,
$ancla$  IF current_user <> 'authenticated' THEN
    RETURN NEW;
  END IF;$ancla$,
$nuevo$  -- mig 252: esta exencion NO es teorica. `anular_salvedad` le inserta un
  -- pedido_item a un pedido entregado --restituye la linea que la salvedad
  -- habia dejado en cero-- y pasa por aca, por ser SECURITY DEFINER de
  -- postgres. Cambiar esta condicion la rompe.
  IF current_user <> 'authenticated' THEN
    RETURN NEW;
  END IF;$nuevo$);
END
$patch$;

-- Sin mas llamadores: era es_admin() sin STABLE.
DROP FUNCTION public.es_admin_salvedades();

-- ---------------------------------------------------------------------------
-- 4 · #661 · bot_audit_log: la retencion se cobra al escribir.
--
--     El cron de la 016 nunca existio --pg_cron no esta instalada en el
--     cluster-- y el `IF EXISTS (SELECT 1 FROM pg_extension ...)` de aquella
--     migracion hizo que eso no se notara: no fallo, simplemente no programo
--     nada. Cinco meses despues, 406 de 538 filas con mas de 90 dias.
--
--     El patron que si funciona en este repo es cobrar la retencion en el mismo
--     camino que escribe: la 073 (cap de bot_conversaciones) con un trigger, y
--     la 248 (bot_marcar_update) adentro de la propia funcion. Aca tiene que ser
--     un TRIGGER y no una RPC porque el que escribe es la edge function, que
--     hace `from("bot_audit_log").insert(row)` directo (_shared/audit.ts) --y el
--     bot no se toca en esta migracion--.
--
--     Acotado a 200 filas por statement para no bloquear: en regimen borra 0, y
--     el dia que haya atraso lo descuenta de a poco, un mensaje por vez.
-- ---------------------------------------------------------------------------

-- 4.1 · El backfill: las 406 que el cron nunca borro.
DELETE FROM public.bot_audit_log
 WHERE created_at < now() - INTERVAL '90 days';

-- 4.2 · La retencion, al escribir.
CREATE OR REPLACE FUNCTION public.bot_audit_log_retencion()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
BEGIN
  DELETE FROM public.bot_audit_log
   WHERE id IN (
     SELECT id FROM public.bot_audit_log
      WHERE created_at < now() - INTERVAL '90 days'
      ORDER BY id
      LIMIT 200
   );
  RETURN NULL;
END;
$fn$;

COMMENT ON FUNCTION public.bot_audit_log_retencion() IS
  'Retencion de bot_audit_log: 90 dias, barridos por el propio INSERT (mig 252, #661). Acotada a 200 filas por statement. Trigger AFTER INSERT FOR EACH STATEMENT: no la llama nadie a mano.';

-- Funcion de trigger: no necesita EXECUTE para nadie --la invoca el executor
-- como parte del DML, no el caller--. Se revocan las dos mitades que Postgres y
-- Supabase conceden solos (ver CLAUDE.md).
REVOKE ALL ON FUNCTION public.bot_audit_log_retencion() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_bot_audit_log_retencion ON public.bot_audit_log;
CREATE TRIGGER trg_bot_audit_log_retencion
  AFTER INSERT ON public.bot_audit_log
  FOR EACH STATEMENT EXECUTE FUNCTION public.bot_audit_log_retencion();

COMMENT ON TABLE public.bot_audit_log IS
  'Auditoria del bot de Telegram: un renglon por mensaje, comando, tool call, respuesta y error. Retencion: 90 dias, barridos por trg_bot_audit_log_retencion en el mismo INSERT (mig 252). El cron de la 016 nunca existio: pg_cron no esta instalada.';

-- ---------------------------------------------------------------------------
-- 5 · auditoria_integridad · PROMO-B y BOT-A.
--
--     PROMO-B es el gate de §1: por sustitucion de regalo que mueve stock, si
--     despues de la sustitucion aparece un movimiento del ALTA sobre el producto
--     ORIGINAL y ninguno sobre el SUSTITUTO, el descuento se fue al producto
--     equivocado. Es exactamente la firma del bug de #653. Medido contra prod
--     antes de agregarlo: 0.
--
--     BOT-A es el que hubiera avisado hace cinco meses. 100 dias y no 90 para
--     que el barrido del INSERT tenga margen: se pone rojo cuando la retencion
--     dejo de correr, no cuando el bot todavia no escribio hoy. Contracara
--     conocida: si el bot se queda mudo mas de 100 dias no hay INSERT que barra
--     y el check se pone rojo sin que haya nada roto. Un bot mudo cuatro meses
--     tambien es algo que conviene mirar.
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._migsv_ancla('public.auditoria_integridad()'::regprocedure,
$ancla$    ('STK-F','high','funciones de public que suben stock sin declarar app.stock_origen (mig 229)',$ancla$,
$nuevo$    ('PROMO-B','high','sustitucion de regalo: el alta descuenta del sustituto, no del original (mig 252, #653)',
      (SELECT count(*) FROM pedido_item_sustituciones s
        WHERE COALESCE(s.regalo_mueve_stock_snapshot, false)
          AND s.producto_original_id <> s.producto_sustituto_id
          AND EXISTS (SELECT 1 FROM stock_historico h
                       WHERE h.referencia_tipo='pedido' AND h.referencia_id=s.pedido_id
                         AND h.sucursal_id=s.sucursal_id AND h.producto_id=s.producto_original_id
                         AND h.origen='pedido_creado' AND h.created_at > s.created_at
                         AND h.diferencia < 0)
          AND NOT EXISTS (SELECT 1 FROM stock_historico h
                       WHERE h.referencia_tipo='pedido' AND h.referencia_id=s.pedido_id
                         AND h.sucursal_id=s.sucursal_id AND h.producto_id=s.producto_sustituto_id
                         AND h.origen='pedido_creado' AND h.created_at > s.created_at
                         AND h.diferencia < 0))),
    ('BOT-A','high','bot_audit_log sin filas de mas de 100 dias: la retencion al escribir sigue viva (mig 252, #661)',
      (SELECT count(*) FROM bot_audit_log WHERE created_at < now() - INTERVAL '100 days')),
    ('STK-F','high','funciones de public que suben stock sin declarar app.stock_origen (mig 229)',$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 6 · El ensayo.
--
--     6.1 · #653 modo A (el regalo mueve stock): pedido con promo y sustitucion
--           activa, se edita mandando el producto ORIGINAL en el JSON --que es
--           lo que manda un bundle viejo del PWA, o el front con la query de
--           sustituciones todavia en vuelo: por eso el trigger existe--. El
--           stock tiene que bajar del SUSTITUTO, y cancelar tiene que devolver
--           exactamente a los mismos productos.
--
--     6.2 · #653 modo B (el regalo no mueve stock, hay auto-ajuste): el fardo
--           tiene que salir del contenedor del SUSTITUTO, que es al que lo va a
--           devolver la reversion.
--
--     6.3 · #632 · posicion_fiscal ya no filtra por 'app'.
--
--     6.4 · Salvedades: anular_salvedad sigue siendo SECURITY DEFINER, sin lo
--           cual no puede restituirle la linea a un pedido entregado.
--
--     El sub-bloque se deshace solo con un SQLSTATE centinela; si una
--     verificacion falla, la excepcion es otra y se propaga.
-- ---------------------------------------------------------------------------
DO $ensayo$
DECLARE
  v_admin     uuid;
  v_suc       bigint;
  v_cliente   bigint;
  v_venta     bigint;
  v_orig      bigint;
  v_sust      bigint;
  v_cont      bigint;
  v_promo_a   bigint;
  v_promo_b   bigint;
  v_res       jsonb;
  v_pedido    bigint;
  v_item      bigint;
  v_s_venta   int;
  v_s_orig    int;
  v_s_sust    int;
  v_s_cont    int;
  v_guardado  bigint;
  v_contenedor bigint;
BEGIN
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'migsv · el ensayo necesita un admin activo con al menos una sucursal activa';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  PERFORM set_config('app.omitir_minimo_venta', '1', true);

  SELECT id INTO v_cliente FROM clientes
   WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;
  IF v_cliente IS NULL THEN
    RAISE EXCEPTION 'migsv · el ensayo necesita un cliente activo en la sucursal %', v_suc;
  END IF;

  BEGIN
    -- 6.4 · Lo primero, porque no depende de nada: el contrato del guard.
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.anular_salvedad(bigint,text)'::regprocedure) THEN
      RAISE EXCEPTION 'migsv · anular_salvedad dejo de ser SECURITY DEFINER: no puede restituirle la linea a un pedido entregado (pedido_items_guard_estado la rechaza)';
    END IF;

    -- 6.3 · posicion_fiscal ya no se fija en 'app'.
    IF position('canal = ''app''' IN pg_get_functiondef('public.posicion_fiscal(bigint,date,date)'::regprocedure)) > 0 THEN
      RAISE EXCEPTION 'migsv · posicion_fiscal sigue filtrando canal = app (#632)';
    END IF;

    -- -----------------------------------------------------------------
    -- 6.1 · Modo A: el regalo mueve stock.
    -- -----------------------------------------------------------------
    INSERT INTO productos (nombre, precio, stock, sucursal_id)
         VALUES ('ZZ ensayo mig252 venta', 100, 100, v_suc) RETURNING id INTO v_venta;
    INSERT INTO productos (nombre, precio, stock, sucursal_id)
         VALUES ('ZZ ensayo mig252 regalo original', 100, 100, v_suc) RETURNING id INTO v_orig;
    INSERT INTO productos (nombre, precio, stock, sucursal_id)
         VALUES ('ZZ ensayo mig252 regalo sustituto', 100, 100, v_suc) RETURNING id INTO v_sust;

    INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id,
                             producto_regalo_id, regalo_mueve_stock, ajuste_automatico)
         VALUES ('ZZ ensayo mig252 A', 'bonificacion', CURRENT_DATE, v_suc,
                 v_orig, TRUE, FALSE)
      RETURNING id INTO v_promo_a;

    v_res := public.crear_pedido_completo(
      v_cliente, 1000, v_admin,
      jsonb_build_array(jsonb_build_object(
        'producto_id', v_venta, 'cantidad', 10, 'precio_unitario', 100)),
      'ensayo mig252 A');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'migsv · el ensayo no pudo crear el pedido A: %', v_res;
    END IF;
    v_pedido := (v_res->>'pedido_id')::bigint;

    -- El renglon del regalo, como lo dejaria el motor de promos, con su
    -- descuento de stock (la promo mueve stock).
    INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal,
                              es_bonificacion, promocion_id, sucursal_id)
         VALUES (v_pedido, v_orig, 2, 0, 0, TRUE, v_promo_a, v_suc)
      RETURNING id INTO v_item;
    UPDATE productos SET stock = stock - 2 WHERE id = v_orig AND sucursal_id = v_suc;

    -- La sustitucion: devuelve 2 al original y saca 2 del sustituto.
    v_res := public.sustituir_regalo_pedido(v_item, v_sust, 2, 'ensayo mig252');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'migsv · el ensayo no pudo sustituir el regalo: %', v_res;
    END IF;

    SELECT stock INTO v_s_venta FROM productos WHERE id = v_venta;
    SELECT stock INTO v_s_orig  FROM productos WHERE id = v_orig;
    SELECT stock INTO v_s_sust  FROM productos WHERE id = v_sust;
    IF v_s_venta <> 90 OR v_s_orig <> 100 OR v_s_sust <> 98 THEN
      RAISE EXCEPTION 'migsv · linea de base A: venta=% (90), original=% (100), sustituto=% (98)',
        v_s_venta, v_s_orig, v_s_sust;
    END IF;

    -- La edicion, con el producto ORIGINAL en el JSON: el caso del bug.
    v_res := public.actualizar_pedido_items(
      v_pedido,
      jsonb_build_array(
        jsonb_build_object('producto_id', v_venta, 'cantidad', 10, 'precio_unitario', 100),
        jsonb_build_object('producto_id', v_orig,  'cantidad', 2,  'precio_unitario', 0,
                           'es_bonificacion', true, 'promocion_id', v_promo_a)),
      v_admin);
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'migsv · el ensayo no pudo editar el pedido A: %', v_res;
    END IF;

    SELECT producto_id INTO v_guardado FROM pedido_items
     WHERE pedido_id = v_pedido AND COALESCE(es_bonificacion, false) LIMIT 1;
    IF v_guardado <> v_sust THEN
      RAISE EXCEPTION 'migsv · el trigger no reescribio el regalo: quedo % (esperado %)', v_guardado, v_sust;
    END IF;

    SELECT stock INTO v_s_venta FROM productos WHERE id = v_venta;
    SELECT stock INTO v_s_orig  FROM productos WHERE id = v_orig;
    SELECT stock INTO v_s_sust  FROM productos WHERE id = v_sust;
    IF v_s_venta <> 90 OR v_s_orig <> 100 OR v_s_sust <> 98 THEN
      RAISE EXCEPTION 'migsv · #653: despues de editar, venta=% (90), original=% (100), sustituto=% (98). El descuento se fue al producto equivocado.',
        v_s_venta, v_s_orig, v_s_sust;
    END IF;

    -- Cancelar devuelve exactamente a los mismos productos.
    v_res := public.cancelar_pedido_con_stock(v_pedido, 'ensayo mig252', v_admin, 'prueba');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'migsv · el ensayo no pudo cancelar el pedido A: %', v_res;
    END IF;

    SELECT stock INTO v_s_venta FROM productos WHERE id = v_venta;
    SELECT stock INTO v_s_orig  FROM productos WHERE id = v_orig;
    SELECT stock INTO v_s_sust  FROM productos WHERE id = v_sust;
    IF v_s_venta <> 100 OR v_s_orig <> 100 OR v_s_sust <> 100 THEN
      RAISE EXCEPTION 'migsv · #653: despues de cancelar, venta=% (100), original=% (100), sustituto=% (100). Salio de un producto y volvio a otro.',
        v_s_venta, v_s_orig, v_s_sust;
    END IF;

    -- -----------------------------------------------------------------
    -- 6.2 · Modo B: el regalo no mueve stock, pero hay auto-ajuste.
    --       El fardo tiene que salir del contenedor del SUSTITUTO.
    -- -----------------------------------------------------------------
    INSERT INTO productos (nombre, precio, stock, sucursal_id)
         VALUES ('ZZ ensayo mig252 contenedor', 100, 100, v_suc) RETURNING id INTO v_cont;

    INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id,
                             producto_regalo_id, regalo_mueve_stock, ajuste_automatico,
                             ajuste_producto_id, unidades_por_bloque, stock_por_bloque)
         VALUES ('ZZ ensayo mig252 B', 'bonificacion', CURRENT_DATE, v_suc,
                 v_orig, FALSE, TRUE, v_cont, 1, 1)
      RETURNING id INTO v_promo_b;

    v_res := public.crear_pedido_completo(
      v_cliente, 1000, v_admin,
      jsonb_build_array(jsonb_build_object(
        'producto_id', v_venta, 'cantidad', 10, 'precio_unitario', 100)),
      'ensayo mig252 B');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'migsv · el ensayo no pudo crear el pedido B: %', v_res;
    END IF;
    v_pedido := (v_res->>'pedido_id')::bigint;

    INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal,
                              es_bonificacion, promocion_id, sucursal_id)
         VALUES (v_pedido, v_orig, 1, 0, 0, TRUE, v_promo_b, v_suc)
      RETURNING id INTO v_item;

    INSERT INTO pedido_item_sustituciones (
      pedido_id, pedido_item_id, promocion_id, producto_original_id, producto_sustituto_id,
      cantidad_original, cantidad_sustituta, regalo_mueve_stock_snapshot,
      motivo, autorizado_por, sucursal_id
    ) VALUES (
      v_pedido, v_item, v_promo_b, v_orig, v_sust, 1, 1, FALSE,
      'ensayo mig252 B', v_admin, v_suc
    );
    UPDATE pedido_items SET producto_id = v_sust WHERE id = v_item;

    -- El uso que el alta ya habia contado. Sin esto la reversion de la edicion
    -- devolveria un bloque que nunca se consumio y la medicion mediria otra cosa.
    UPDATE promociones SET usos_pendientes = 1 WHERE id = v_promo_b AND sucursal_id = v_suc;

    SELECT stock INTO v_s_cont FROM productos WHERE id = v_cont;
    IF v_s_cont <> 100 THEN
      RAISE EXCEPTION 'migsv · linea de base B: contenedor=% (100)', v_s_cont;
    END IF;

    v_res := public.actualizar_pedido_items(
      v_pedido,
      jsonb_build_array(
        jsonb_build_object('producto_id', v_venta, 'cantidad', 10, 'precio_unitario', 100),
        jsonb_build_object('producto_id', v_orig,  'cantidad', 1,  'precio_unitario', 0,
                           'es_bonificacion', true, 'promocion_id', v_promo_b)),
      v_admin);
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'migsv · el ensayo no pudo editar el pedido B: %', v_res;
    END IF;

    SELECT producto_id INTO v_contenedor FROM promo_ajustes
     WHERE promocion_id = v_promo_b AND sucursal_id = v_suc
       AND unidades_ajustadas > 0
     ORDER BY id DESC LIMIT 1;
    IF v_contenedor IS NULL THEN
      RAISE EXCEPTION 'migsv · el auto-ajuste de la promo B no dejo ninguna fila en promo_ajustes';
    END IF;
    IF v_contenedor <> v_sust THEN
      RAISE EXCEPTION 'migsv · #653: el fardo salio del contenedor % (esperado el del sustituto, %). Con el bug salia de % o de %.',
        v_contenedor, v_sust, v_orig, v_cont;
    END IF;

    SELECT stock INTO v_s_cont FROM productos WHERE id = v_cont;
    IF v_s_cont <> 100 THEN
      RAISE EXCEPTION 'migsv · #653: el auto-ajuste toco el contenedor del original: %=(100)', v_s_cont;
    END IF;

    RAISE EXCEPTION 'migsv-ok' USING ERRCODE = '2F000';
  EXCEPTION WHEN SQLSTATE '2F000' THEN
    IF SQLERRM <> 'migsv-ok' THEN RAISE; END IF;
    RAISE NOTICE 'migsv · ensayo OK: el regalo sustituido descuenta y devuelve del mismo producto, y el fardo sale del contenedor al que vuelve';
  END;
END
$ensayo$;

-- ---------------------------------------------------------------------------
-- 7 · Se saca el andamio.
--     CREATE OR REPLACE preserva la ACL de las cinco funciones parcheadas. La
--     unica funcion nueva es la de trigger, que ya tiene su REVOKE arriba.
-- ---------------------------------------------------------------------------
DROP FUNCTION public._migsv_ancla(regprocedure, text, text);

COMMIT;
