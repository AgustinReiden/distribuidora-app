-- 257 · La valuación sigue al renglón que queda
--
-- #673. Dos cosas que son la misma cosa: quién decide el costo de un renglón de
-- pedido, y con qué cascada.
--
-- 1 · `actualizar_pedido_items` calculaba `v_costo_al_crear` ANTES del INSERT, y
--     leyendo el `producto_id` que vino en el JSON --el ORIGINAL--. La 252 pasó
--     el stock y el contenedor a `v_producto_guardado` (el `RETURNING` del
--     INSERT, que es lo que el trigger dejó en la fila) pero se olvidó del
--     costo, que quedó colgado del original y dependiendo de que
--     `aplicar_sustituciones_regalo_pre_insert` lo reparara después. O sea: el
--     renglón se guardaba con el costo de un producto que nadie entrega.
--
--     Se alinea igual que la 252: el costo se calcula DESPUÉS del INSERT y con
--     el producto que quedó. Por qué RETURNING y no resolver la sustitución a
--     mano: el que sabe qué producto quedó en la fila es la fila.
--
-- 2 · SEIS caminos escribían `pedido_items.costo_unitario_al_crear` y cada uno
--     repetía la cascada inline en vez de llamar a `costo_valuacion(snapshot,
--     promedio, real, sin_iva, ii)` --la única implementación, mig 238--:
--
--       · crear_pedido_completo                      cascada inline
--       · crear_pedido_completo_bot                  cascada inline
--       · actualizar_pedido_items                    cascada inline
--       · anular_salvedad                            cascada inline
--       · aplicar_sustituciones_regalo_pre_insert    cascada inline
--       · sustituir_regalo_pedido                    `costo_real` PELADO
--
--     El último no es una copia distraída: es un número distinto. Un sustituto
--     con `costo_promedio` cargado se guardaba al costo de reposición en vez de
--     al promedio, y en prod 80 de 295 productos tienen `costo_real` distinto de
--     `costo_promedio`. Seis caminos, hasta tres respuestas para la misma
--     pregunta.
--
--     Los seis pasan a llamar a `costo_valuacion(...)`. El orden de precedencia
--     no se toca --snapshot > promedio > real > reconstrucción desde sin_iva--;
--     lo que se toca es que exista una sola vez. Dos diferencias finas que la
--     unificación trae, las dos a favor de la 238:
--       · `costo_sin_iva = 0` ya no vale 0: el `NULLIF` de la 238 dice que un
--         cero no es un costo, y `IS NULL` sobre la cascada ES el predicado
--         `sin_costo` (#511). Las copias inline miraban `IS NULL` a mano y un
--         cero les pasaba como costo bueno.
--       · la reconstrucción no se redondea a 4 decimales. La 238 no redondea, y
--         el que redondeaba de más era el snapshot, no el reporte.
--
-- 3 · Check nuevo `COSTO-A` en `auditoria_integridad()`, estructural como STK-F:
--     cuenta funciones de `public` que escriben `costo_unitario_al_crear` sin
--     mencionar `costo_valuacion`. Medido contra prod ANTES: 6. Después: 0.
--     Es el gate que evita que la séptima copia nazca callada.
--
-- Lo que esta migración NO hace: corregir ítems históricos. De las 10
-- sustituciones vivas en prod, 9 conservan su renglón, y de ésas 1 quedó con el
-- costo del producto ORIGINAL, 1 con `costo_real` pelado teniendo promedio
-- distinto, y 4 en NULL (que es el caso benigno: el reporte cae al costo vivo
-- del producto correcto). Se listan en el PR y se dejan como están: el snapshot
-- es historia, y reescribirla movería CMV ya cerrado.
--
-- Técnica: parche por ancla sobre el cuerpo vivo (molde de la 241/242/244/252).

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
-- 1 · actualizar_pedido_items · el costo se calcula despues del INSERT.
--
--     Tres parches sobre el mismo cuerpo:
--       1.1 · la variable del id del renglon guardado
--       1.2 · el pre-INSERT deja de calcular el costo (sigue calculando el
--             desglose de precio, que si sale del JSON)
--       1.3 · el post-INSERT lo calcula con el producto que quedo
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  -- 1.1
  PERFORM public._migsv_ancla('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure,
$ancla$  v_producto_sustituto BIGINT;$ancla$,
$nuevo$  v_producto_sustituto BIGINT;
  -- mig 257 (#673): el id del renglon que quedo, para poder valuarlo despues
  -- del INSERT --que es cuando recien se sabe de que producto habla--.
  v_pedido_item_guardado BIGINT;$nuevo$);

  -- 1.2 · El pre-INSERT ya no decide el costo.
  --
  --       Ese SELECT lee el producto del JSON, que es el ORIGINAL:
  --       aplicar_sustituciones_regalo_pre_insert puede reescribir producto_id
  --       un renglon mas abajo. Lo que SI puede salir de ahi es el desglose de
  --       precio (IVA/II): se cobra por el precio que vino en el JSON, y un
  --       regalo va con desglose en cero de todas formas.
  PERFORM public._migsv_ancla('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure,
$ancla$    -- CPP primero (mig 129)
    v_costo_al_crear := COALESCE(v_costo_promedio_actual, v_costo_real_actual,
      CASE WHEN v_costo_actual IS NULL THEN NULL
           ELSE round(v_costo_actual * (1 + COALESCE(v_imp_int_actual, 0) / 100), 4) END);$ancla$,
$nuevo$    -- mig 257 (#673): el costo NO se decide aca. El SELECT de arriba lee el
    -- producto del JSON --el ORIGINAL-- y el trigger de sustituciones puede
    -- reescribir producto_id unas lineas mas abajo. Del pre-INSERT sale el
    -- desglose de precio (IVA/II), que se cobra por el precio del JSON; el
    -- costo sale despues del INSERT, del producto que quedo en la fila.
    v_costo_al_crear := NULL;$nuevo$);

  -- 1.3 · El post-INSERT lo calcula con el producto guardado.
  PERFORM public._migsv_ancla('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure,
$ancla$    RETURNING producto_id INTO v_producto_guardado;$ancla$,
$nuevo$    RETURNING id, producto_id INTO v_pedido_item_guardado, v_producto_guardado;

    -- mig 257 (#673): la valuacion sigue al renglon GUARDADO, igual que el
    -- stock y el contenedor desde la 252. Antes se calculaba antes del INSERT
    -- y con el producto del JSON: un regalo sustituido se guardaba con el costo
    -- del original --80 de 295 productos de prod tienen costo_real distinto de
    -- costo_promedio, asi que no es el mismo numero-- y solo se salvaba si el
    -- trigger lo reparaba.
    --
    -- La cascada es UNA sola y vive en costo_valuacion (mig 238): snapshot >
    -- promedio > real > reconstruccion desde sin_iva. Aca no hay snapshot
    -- previo --esto ES el snapshot--, asi que va NULL en el primer argumento.
    SELECT public.costo_valuacion(NULL, p.costo_promedio, p.costo_real,
                                  p.costo_sin_iva, COALESCE(p.impuestos_internos, 0))
      INTO v_costo_al_crear
      FROM productos p
     WHERE p.id = v_producto_guardado AND p.sucursal_id = v_sucursal;

    UPDATE pedido_items SET costo_unitario_al_crear = v_costo_al_crear
     WHERE id = v_pedido_item_guardado;$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 2 · Las otras cinco copias de la cascada.
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  -- 2.1 · El trigger de sustituciones. Repara el snapshot del caller cuando
  --       reescribe producto_id; con la 257 el caller que lo necesitaba ya no
  --       lo necesita, pero el trigger sigue siendo el que manda sobre
  --       cualquier otro INSERT de pedido_items.
  PERFORM public._migsv_ancla('public.aplicar_sustituciones_regalo_pre_insert()'::regprocedure,
$ancla$    SELECT COALESCE(costo_promedio, costo_real,
                    CASE WHEN costo_sin_iva IS NULL THEN NULL
                         ELSE round(costo_sin_iva * (1 + COALESCE(impuestos_internos, 0) / 100), 4) END)
      INTO v_costo_sustituto$ancla$,
$nuevo$    -- mig 257 (#673): la cascada es la de costo_valuacion (mig 238) y no una
    -- copia. Sin snapshot previo: esto ES el snapshot.
    SELECT public.costo_valuacion(NULL, costo_promedio, costo_real, costo_sin_iva,
                                  COALESCE(impuestos_internos, 0))
      INTO v_costo_sustituto$nuevo$);

  -- 2.2 · anular_salvedad, al restituir la linea.
  PERFORM public._migsv_ancla('public.anular_salvedad(bigint,text)'::regprocedure,
$ancla$      COALESCE(v_costo_prom, v_costo_real,
        CASE WHEN v_costo_sin IS NULL THEN NULL ELSE round(v_costo_sin * (1 + v_pct_ii / 100), 4) END),$ancla$,
$nuevo$      -- mig 257 (#673): la cascada unica de la 238, no una copia.
      public.costo_valuacion(NULL, v_costo_prom, v_costo_real, v_costo_sin, v_pct_ii),$nuevo$);

  -- 2.3 · sustituir_regalo_pedido. Este no era una copia distraida: era
  --       `costo_real` PELADO, o sea el costo de REPOSICION, sin caer al
  --       promedio. Un sustituto con promedio cargado se valuaba distinto
  --       segun por que puerta entrara.
  PERFORM public._migsv_ancla('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)'::regprocedure,
$ancla$         costo_unitario_al_crear = (SELECT costo_real FROM productos
                                     WHERE id = p_producto_nuevo_id AND sucursal_id = v_sucursal)$ancla$,
$nuevo$         -- mig 257 (#673): era `costo_real` pelado --el costo de REPOSICION--,
         -- sin caer al promedio. Ahora la misma cascada que todos: la de la 238.
         costo_unitario_al_crear = (SELECT public.costo_valuacion(NULL, costo_promedio,
                                             costo_real, costo_sin_iva,
                                             COALESCE(impuestos_internos, 0))
                                      FROM productos
                                     WHERE id = p_producto_nuevo_id AND sucursal_id = v_sucursal)$nuevo$);

  -- 2.4 y 2.5 · Las dos altas. El snapshot se arma por producto en un JSONB y
  --             se consume mas abajo; lo que cambia es como se calcula el valor.
  PERFORM public._migsv_ancla('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)'::regprocedure,
$ancla$      v_costo_snapshot := v_costo_snapshot || jsonb_build_object(v_producto_id::TEXT,
        COALESCE(v_costo_promedio_actual, v_costo_real_actual,
          CASE WHEN v_costo_actual IS NULL THEN NULL
               ELSE round(v_costo_actual * (1 + COALESCE(v_imp_int_actual, 0) / 100), 4) END));$ancla$,
$nuevo$      -- mig 257 (#673): la cascada unica de la 238. Sin snapshot previo: esto
      -- ES el snapshot que despues leen los reportes.
      v_costo_snapshot := v_costo_snapshot || jsonb_build_object(v_producto_id::TEXT,
        public.costo_valuacion(NULL, v_costo_promedio_actual, v_costo_real_actual,
                               v_costo_actual, COALESCE(v_imp_int_actual, 0)));$nuevo$);

  PERFORM public._migsv_ancla('public.crear_pedido_completo_bot(uuid,uuid)'::regprocedure,
$ancla$      v_costo_snapshot := v_costo_snapshot || jsonb_build_object(v_producto_id::TEXT,
        COALESCE(v_costo_promedio_actual, v_costo_real_actual,
          CASE WHEN v_costo_actual IS NULL THEN NULL
               ELSE round(v_costo_actual * (1 + COALESCE(v_imp_int_actual, 0) / 100), 4) END));$ancla$,
$nuevo$      -- mig 257 (#673): la cascada unica de la 238, igual que crear_pedido_completo.
      v_costo_snapshot := v_costo_snapshot || jsonb_build_object(v_producto_id::TEXT,
        public.costo_valuacion(NULL, v_costo_promedio_actual, v_costo_real_actual,
                               v_costo_actual, COALESCE(v_imp_int_actual, 0)));$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 3 · El gate · COSTO-A, estructural como STK-F.
--
--     No mira datos: mira cuerpos. Una funcion de public que escribe
--     `costo_unitario_al_crear` --sea por INSERT o UPDATE de pedido_items, sea
--     asignandole a NEW-- y no menciona `costo_valuacion` esta repitiendo la
--     cascada, y tarde o temprano da otro numero. Es exactamente la forma de
--     #673.
--
--     El filtro de "escribe" es a proposito mas angosto que "menciona": los
--     reportes nombran la columna todo el tiempo y no la escriben, y
--     `pedido_items_proteger_columnas` la nombra dentro de una lista de
--     columnas prohibidas.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.auditoria_funciones_costo_sin_valuacion()
RETURNS bigint
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
  SELECT count(*)
    FROM pg_proc f
   WHERE f.pronamespace = 'public'::regnamespace
     AND f.prokind = 'f'
     AND pg_get_functiondef(f.oid) ILIKE '%costo_unitario_al_crear%'
     AND (   pg_get_functiondef(f.oid) ~* 'INSERT\s+INTO\s+(public\.)?pedido_items'
          OR pg_get_functiondef(f.oid) ~* 'UPDATE\s+(public\.)?pedido_items'
          OR pg_get_functiondef(f.oid) ~* 'NEW\.costo_unitario_al_crear\s*:=')
     AND pg_get_functiondef(f.oid) NOT ILIKE '%costo_valuacion%';
$fn$;

COMMENT ON FUNCTION public.auditoria_funciones_costo_sin_valuacion() IS
  'Check COSTO-A (mig 257, #673): funciones de public que escriben pedido_items.costo_unitario_al_crear sin pasar por costo_valuacion() (mig 238). Estructural, como auditoria_funciones_stock_sin_origen. Cero o rojo.';

-- Misma ACL que su hermana de STK-F. Postgres y Supabase conceden EXECUTE a
-- PUBLIC y a anon por separado: hay que revocar las dos mitades (ver CLAUDE.md).
REVOKE ALL ON FUNCTION public.auditoria_funciones_costo_sin_valuacion() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.auditoria_funciones_costo_sin_valuacion() TO authenticated, service_role;

DO $patch$
BEGIN
  PERFORM public._migsv_ancla('public.auditoria_integridad()'::regprocedure,
$ancla$    ('STK-F','high','funciones de public que suben stock sin declarar app.stock_origen (mig 229)',$ancla$,
$nuevo$    ('COSTO-A','high','funciones de public que escriben costo_unitario_al_crear sin pasar por costo_valuacion (mig 238, #673)',
      (SELECT public.auditoria_funciones_costo_sin_valuacion())),
    ('STK-F','high','funciones de public que suben stock sin declarar app.stock_origen (mig 229)',$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 4 · El ensayo.
--
--     Un sustituto con costo_real 10 y costo_promedio 12: los dos numeros
--     existen y son distintos, asi que "10" delata la cascada rota y "12" es la
--     respuesta de la 238. El original tiene 99/77 para que su costo tampoco se
--     pueda confundir con el del sustituto.
--
--     4.1 · los seis cuerpos mencionan costo_valuacion y COSTO-A esta en cero.
--     4.2 · crear_pedido_completo valua por la cascada (no por costo_real).
--     4.3 · sustituir_regalo_pedido deja 12, no 10 (era `costo_real` pelado).
--     4.4 · actualizar_pedido_items --mandando el producto ORIGINAL en el JSON,
--           que es el caso del bug-- deja el renglon con el producto sustituto
--           Y con el costo del sustituto.
--     4.5 · los cuatro caminos dan el MISMO numero.
--
--     El sub-bloque se deshace solo con un SQLSTATE centinela; si una
--     verificacion falla, la excepcion es otra y se propaga.
-- ---------------------------------------------------------------------------
DO $ensayo$
DECLARE
  v_admin      uuid;
  v_suc        bigint;
  v_cliente    bigint;
  v_venta      bigint;
  v_orig       bigint;
  v_sust       bigint;
  v_promo      bigint;
  v_res        jsonb;
  v_pedido     bigint;
  v_item       bigint;
  v_costo      numeric;
  v_costo_alta numeric;
  v_costo_sust numeric;
  v_costo_edit numeric;
  v_guardado   bigint;
  v_falta      text;
  v_rojo       bigint;
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
    -- 4.1 · Lo primero, porque no depende de nada: los seis cuerpos.
    SELECT string_agg(f.proname, ', ' ORDER BY f.proname) INTO v_falta
      FROM pg_proc f
     WHERE f.pronamespace = 'public'::regnamespace
       AND f.proname IN ('crear_pedido_completo','crear_pedido_completo_bot',
                         'actualizar_pedido_items','anular_salvedad',
                         'aplicar_sustituciones_regalo_pre_insert','sustituir_regalo_pedido')
       AND pg_get_functiondef(f.oid) NOT ILIKE '%costo_valuacion%';
    IF v_falta IS NOT NULL THEN
      RAISE EXCEPTION 'migsv · #673: estos cuerpos siguen repitiendo la cascada en vez de llamar a costo_valuacion: %', v_falta;
    END IF;

    v_rojo := public.auditoria_funciones_costo_sin_valuacion();
    IF v_rojo <> 0 THEN
      RAISE EXCEPTION 'migsv · COSTO-A nace en % (esperado 0)', v_rojo;
    END IF;

    -- -----------------------------------------------------------------
    -- Los productos. El sustituto: costo_real 10, costo_promedio 12.
    -- -----------------------------------------------------------------
    INSERT INTO productos (nombre, precio, stock, sucursal_id, costo_real, costo_promedio)
         VALUES ('ZZ ensayo mig257 venta', 100, 100, v_suc, 40, 45) RETURNING id INTO v_venta;
    INSERT INTO productos (nombre, precio, stock, sucursal_id, costo_real, costo_promedio)
         VALUES ('ZZ ensayo mig257 regalo original', 100, 100, v_suc, 99, 77) RETURNING id INTO v_orig;
    INSERT INTO productos (nombre, precio, stock, sucursal_id, costo_real, costo_promedio)
         VALUES ('ZZ ensayo mig257 regalo sustituto', 100, 100, v_suc, 10, 12) RETURNING id INTO v_sust;

    INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id,
                             producto_regalo_id, regalo_mueve_stock, ajuste_automatico)
         VALUES ('ZZ ensayo mig257', 'bonificacion', CURRENT_DATE, v_suc,
                 v_orig, TRUE, FALSE)
      RETURNING id INTO v_promo;

    -- 4.2 · El alta valua por la cascada: promedio (45), no costo_real (40).
    v_res := public.crear_pedido_completo(
      v_cliente, 1000, v_admin,
      jsonb_build_array(jsonb_build_object(
        'producto_id', v_venta, 'cantidad', 10, 'precio_unitario', 100)),
      'ensayo mig257');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'migsv · el ensayo no pudo crear el pedido: %', v_res;
    END IF;
    v_pedido := (v_res->>'pedido_id')::bigint;

    SELECT costo_unitario_al_crear INTO v_costo FROM pedido_items
     WHERE pedido_id = v_pedido AND producto_id = v_venta;
    IF v_costo IS DISTINCT FROM 45 THEN
      RAISE EXCEPTION 'migsv · crear_pedido_completo valuo en % (esperado 45, el promedio)', v_costo;
    END IF;

    -- El renglon del regalo, como lo dejaria el motor de promos.
    INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal,
                              es_bonificacion, promocion_id, sucursal_id)
         VALUES (v_pedido, v_orig, 2, 0, 0, TRUE, v_promo, v_suc)
      RETURNING id INTO v_item;
    UPDATE productos SET stock = stock - 2 WHERE id = v_orig AND sucursal_id = v_suc;

    -- 4.3 · La sustitucion valua al sustituto por la cascada: 12, no 10.
    v_res := public.sustituir_regalo_pedido(v_item, v_sust, 2, 'ensayo mig257');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'migsv · el ensayo no pudo sustituir el regalo: %', v_res;
    END IF;

    SELECT costo_unitario_al_crear INTO v_costo_sust FROM pedido_items WHERE id = v_item;
    IF v_costo_sust IS DISTINCT FROM 12 THEN
      RAISE EXCEPTION 'migsv · #673: sustituir_regalo_pedido valuo en % (esperado 12, el promedio del sustituto). 10 seria costo_real pelado.', v_costo_sust;
    END IF;

    -- 4.4 · La edicion, con el producto ORIGINAL en el JSON: el caso del bug.
    --       Cambia la cantidad del regalo de 2 a 3.
    v_res := public.actualizar_pedido_items(
      v_pedido,
      jsonb_build_array(
        jsonb_build_object('producto_id', v_venta, 'cantidad', 10, 'precio_unitario', 100),
        jsonb_build_object('producto_id', v_orig,  'cantidad', 3,  'precio_unitario', 0,
                           'es_bonificacion', true, 'promocion_id', v_promo)),
      v_admin);
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'migsv · el ensayo no pudo editar el pedido: %', v_res;
    END IF;

    SELECT producto_id, costo_unitario_al_crear INTO v_guardado, v_costo_edit
      FROM pedido_items
     WHERE pedido_id = v_pedido AND COALESCE(es_bonificacion, false) LIMIT 1;
    IF v_guardado <> v_sust THEN
      RAISE EXCEPTION 'migsv · el trigger no reescribio el regalo: quedo % (esperado %)', v_guardado, v_sust;
    END IF;
    IF v_costo_edit IS DISTINCT FROM 12 THEN
      RAISE EXCEPTION 'migsv · #673: el renglon sustituido quedo valuado en % (esperado 12, el del sustituto). 77 seria el promedio del ORIGINAL.', v_costo_edit;
    END IF;

    -- La otra punta de la misma edicion: el renglon de venta se revaluo por la
    -- cascada y sigue dando el mismo numero que el alta.
    SELECT costo_unitario_al_crear INTO v_costo_alta FROM pedido_items
     WHERE pedido_id = v_pedido AND producto_id = v_venta;
    IF v_costo_alta IS DISTINCT FROM 45 THEN
      RAISE EXCEPTION 'migsv · actualizar_pedido_items valuo la venta en % (esperado 45, igual que el alta)', v_costo_alta;
    END IF;

    -- 4.5 · Los cuatro caminos, el mismo numero para el mismo producto.
    IF public.costo_valuacion(NULL, 12, 10, NULL, 0) IS DISTINCT FROM v_costo_sust
       OR v_costo_sust IS DISTINCT FROM v_costo_edit THEN
      RAISE EXCEPTION 'migsv · #673: los caminos no coinciden. cascada=%, sustitucion=%, edicion=%',
        public.costo_valuacion(NULL, 12, 10, NULL, 0), v_costo_sust, v_costo_edit;
    END IF;

    RAISE EXCEPTION 'migsv-ok' USING ERRCODE = '2F000';
  EXCEPTION WHEN SQLSTATE '2F000' THEN
    IF SQLERRM <> 'migsv-ok' THEN RAISE; END IF;
    RAISE NOTICE 'migsv · ensayo OK: la valuacion sigue al renglon guardado y los caminos dan el mismo numero';
  END;
END
$ensayo$;

-- ---------------------------------------------------------------------------
-- 5 · Se saca el andamio.
--     CREATE OR REPLACE preserva la ACL de las siete funciones parcheadas. La
--     unica funcion nueva es la del check, que ya tiene su REVOKE/GRANT arriba.
-- ---------------------------------------------------------------------------
DROP FUNCTION public._migsv_ancla(regprocedure, text, text);

COMMIT;
