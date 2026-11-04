-- NNN · La venta bloquea los contenedores de sus promos junto con los productos, y la edición
-- guarda fechas y notas en un paso (#1398, #1440 punto 5). Tarjeta 12 de #1378.
--
-- #1398 · QUÉ PASABA
--   crear_pedido_completo y crear_pedido_completo_bot bloquean los productos de sus líneas por
--   id (el bucle sobre v_cantidades_totales). El contenedor del que sale el fardo de una promo
--   con auto-ajuste lo tomaba recién aplicar_uso_promo_acumulador, al cerrar un bloque, y
--   después de bloquear la fila de la promo. Cancelar, editar, la salvedad, sustituir y dividir
--   (431a-d, 447) bloquean productos y contenedores juntos y por id, y la promo después. Con un
--   contenedor distinto del sabor y de id menor que algún producto de la venta, la venta tenía
--   ese producto y pedía el contenedor, y la otra tenía el contenedor y pedía el producto: 40P01.
--   Medido en el arnés (scripts/concurrencia, C12): con el cruce forzado, 100 de 100 contra
--   cancelar (C12b), editar (C12d), el bot (C12e) y otra venta que vende el contenedor suelto
--   (C12f). Con el contenedor igual al sabor, que es lo único que hay hoy en prod, o mayor que
--   todo, 0 (C12i, C12j). No rompía datos: la transacción abortada volvía atrás entera.
--   Aparte, aplicar_uso_promo_acumulador bloquea cada promo en el orden de las líneas, que es el
--   del carrito (ni la app ni el bot ordenan los regalos por promo). Dos ventas con las mismas
--   dos promos en orden inverso, sin ningún producto en común, se cruzaban en las filas de
--   promociones (C12k y C12k2).
--
-- #1398 · QUÉ CAMBIA (sólo el orden de los locks)
--   Antes del bucle de productos, las dos funciones bloquean, en una sentencia y ORDER BY id,
--   los productos de las líneas y los contenedores de las promos de sus regalos
--   (_contenedores_de_promos, el mismo helper de la 431a), y después esas promos, ORDER BY id.
--   El bucle y el motor los vuelven a pedir, ya tomados. Es el orden global: productos (con
--   sus contenedores) por id, y las promos después.
--   Con la fila de la promo tomada desde antes del INSERT de la línea, un cambio de tipo de la
--   promo (el UPDATE de regalo_mueve_stock) espera a que la venta termine: el sello de la línea
--   (451), la foto de capturar_promo_del_pedido y el SELECT que decide la bajada de stock leen el
--   mismo modo (#1442). Medido en C12m a C12o.
--   El costo: _contenedores_de_promos trae el contenedor de cada sabor de la promo, no sólo el
--   del regalo de esta venta (hoy la 13, la única activa con auto-ajuste, tiene 7). Una venta
--   suelta de uno de esos productos espera a la de la promo hasta que confirma, como ya espera a
--   su cancelación o su edición desde la 431. Entre ventas de la misma promo no suma espera: ya
--   se serializaban en la fila de la promo.
--
-- #1398 · QUÉ NO CAMBIA
--   Qué se valida, qué se vende, qué baja del stock y de la barra, los mensajes, las firmas y
--   los EXECUTE. _contenedores_de_promos sigue sin EXECUTE para authenticated: las dos son
--   DEFINER.
--
-- #1440 (punto 5) · QUÉ PASABA
--   handleGuardarEdicion llamaba primero a volver_pedido_a_pendiente_por_edicion y después
--   hacía el UPDATE REST de fecha y notas. Si fallaba el segundo, el pedido quedaba pendiente,
--   fuera de la ruta y con la fecha vieja. Y como la RPC le movía el updated_at, el front ponía
--   la versión de #1323 en null: la siguiente edición de líneas del mismo modal iba sin la
--   concurrencia optimista.
--
-- #1440 (punto 5) · QUÉ CAMBIA
--   actualizar_fechas_y_notas_pedido hace las dos cosas en una transacción. Es SECURITY INVOKER
--   a propósito: el UPDATE es el mismo PATCH que hacía el front, con sus mismos permisos (la
--   policy mt_pedidos_update, el GRANT por columna y pedidos_proteger_columnas, que sólo mira a
--   quien corre como authenticated). Lo único DEFINER es la vuelta a pendiente, que sigue
--   siendo volver_pedido_a_pendiente_por_edicion, con su ventana de las 15:30 (#1372). Si el
--   pedido está asignado y cambia el día, vuelve a pendiente; lo decide con la fila bloqueada,
--   no con lo que vio el modal. Devuelve el updated_at de antes y el nuevo, como sustituir y
--   dividir un regalo (#1376), para que la edición siga con su versión.
--   volver_pedido_a_pendiente_por_edicion no se toca: la siguen llamando los bundles viejos.
--
-- Ensayo: scripts/test-venta-edicion-1398.sql, y C12 del arnés (scripts/concurrencia).
-- Aplicar desde el contenido LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: nada cambió en prod desde que se leyeron los cuerpos
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, md5(p.prosrc) AS md5_vivo
      FROM (VALUES
        ('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)',
         '247645d02bf3d7479d9712bc06a0d0e6'),
        ('public.crear_pedido_completo_bot(uuid,uuid)',
         'e2ca6805598ac75a33b5f2cc5f17ae24'),
        ('public.volver_pedido_a_pendiente_por_edicion(bigint)',
         '2c51b843087773c40a07d3e06cda8a18'),
        ('public._contenedores_de_promos(bigint[],bigint)',
         'cab70e87a44a94a366f9a4b6ec7e42eb')
      ) AS x(firma, md5)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION 'mig NNN · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;
  IF to_regproc('public.actualizar_fechas_y_notas_pedido') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · actualizar_fechas_y_notas_pedido ya existe';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- #1398 · Parches por ancla sobre el cuerpo vivo
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _n_parche (firma text, orden int, ancla text, reemplazo text, veces int DEFAULT 1) ON COMMIT DROP;

INSERT INTO _n_parche (firma, orden, ancla, reemplazo) VALUES
('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)', 1,
$a$  v_pedidos_bundle TEXT;
$a$,
$r$  v_pedidos_bundle TEXT;
  -- #1398: las promos de los regalos del pedido, las que puede mover el motor.
  v_promos_regalo BIGINT[];
$r$),

('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)', 2,
$a$  FOR v_producto_id IN SELECT (key)::INT FROM jsonb_each_text(v_cantidades_totales) LOOP
    v_cant_stock := COALESCE((v_cantidades_stock->>v_producto_id::TEXT)::INT, 0);
$a$,
$r$  -- #1398: lo que la venta va a bloquear, junto y por id, antes de la primera fila:
  -- los productos de las líneas y los contenedores que puede bajar el motor de
  -- promos (_contenedores_de_promos), y después las promos de los regalos. Es el
  -- orden de cancelar, editar, la salvedad y el regalo (#1375, 431a-d). Hasta acá
  -- el contenedor se tomaba recién en aplicar_uso_promo_acumulador, después de su
  -- promo, y cada promo en el orden de las líneas, que es el del carrito: contra
  -- una cancelación o una edición que ya tenía el contenedor, o contra otra venta
  -- con las mismas promos en otro orden, daba 40P01 (C12 del arnés). El bucle de
  -- abajo y el motor los vuelven a pedir, ya tomados.
  v_promos_regalo := ARRAY(SELECT DISTINCT (e->>'promocion_id')::BIGINT
                             FROM jsonb_array_elements(p_items) e
                            WHERE COALESCE((e->>'es_bonificacion')::BOOLEAN, false)
                              AND NULLIF(e->>'promocion_id', '') IS NOT NULL);
  PERFORM 1 FROM productos
   WHERE sucursal_id = v_sucursal
     AND id IN (SELECT (key)::BIGINT FROM jsonb_each_text(v_cantidades_totales)
                UNION
                SELECT c FROM public._contenedores_de_promos(v_promos_regalo, v_sucursal) c)
   ORDER BY id
     FOR UPDATE;
  PERFORM 1 FROM promociones
   WHERE sucursal_id = v_sucursal AND id = ANY (v_promos_regalo)
   ORDER BY id
     FOR UPDATE;

  FOR v_producto_id IN SELECT (key)::INT FROM jsonb_each_text(v_cantidades_totales) LOOP
    v_cant_stock := COALESCE((v_cantidades_stock->>v_producto_id::TEXT)::INT, 0);
$r$),

('public.crear_pedido_completo_bot(uuid,uuid)', 1,
$a$  v_item_guc TEXT;
BEGIN
$a$,
$r$  v_item_guc TEXT;
  -- #1398: las promos de los regalos del pedido, las que puede mover el motor.
  v_promos_regalo BIGINT[];
BEGIN
$r$),

('public.crear_pedido_completo_bot(uuid,uuid)', 2,
$a$  FOR v_producto_id IN SELECT (key)::INT FROM jsonb_each_text(v_cantidades_totales) LOOP
    v_cant_stock := COALESCE((v_cantidades_stock->>v_producto_id::TEXT)::INT, 0);
$a$,
$r$  -- #1398: el mismo lock que crear_pedido_completo, y por lo mismo: los productos
  -- de las líneas con los contenedores de sus promos, juntos y por id, y después
  -- las promos de los regalos.
  v_promos_regalo := ARRAY(SELECT DISTINCT (e->>'promocion_id')::BIGINT
                             FROM jsonb_array_elements(v_pendiente.items) e
                            WHERE COALESCE((e->>'es_bonificacion')::BOOLEAN, false)
                              AND NULLIF(e->>'promocion_id', '') IS NOT NULL);
  PERFORM 1 FROM productos
   WHERE sucursal_id = v_pendiente.sucursal_id
     AND id IN (SELECT (key)::BIGINT FROM jsonb_each_text(v_cantidades_totales)
                UNION
                SELECT c FROM public._contenedores_de_promos(v_promos_regalo, v_pendiente.sucursal_id) c)
   ORDER BY id
     FOR UPDATE;
  PERFORM 1 FROM promociones
   WHERE sucursal_id = v_pendiente.sucursal_id AND id = ANY (v_promos_regalo)
   ORDER BY id
     FOR UPDATE;

  FOR v_producto_id IN SELECT (key)::INT FROM jsonb_each_text(v_cantidades_totales) LOOP
    v_cant_stock := COALESCE((v_cantidades_stock->>v_producto_id::TEXT)::INT, 0);
$r$);

DO $parches$
DECLARE
  v_f   record;
  v_p   record;
  v_def text;
  v_n   int;
BEGIN
  FOR v_f IN SELECT DISTINCT firma FROM _n_parche ORDER BY firma LOOP
    v_def := pg_get_functiondef(v_f.firma::regprocedure);
    FOR v_p IN SELECT * FROM _n_parche WHERE firma = v_f.firma ORDER BY orden LOOP
      v_n := (length(v_def) - length(replace(v_def, v_p.ancla, ''))) / length(v_p.ancla);
      IF v_n <> v_p.veces THEN
        RAISE EXCEPTION 'mig NNN · % parche %: el ancla aparece % vez/veces y se esperaba %',
          v_f.firma, v_p.orden, v_n, v_p.veces;
      END IF;
      v_def := replace(v_def, v_p.ancla, v_p.reemplazo);
    END LOOP;
    EXECUTE v_def;
  END LOOP;
END
$parches$;

-- ---------------------------------------------------------------------------
-- #1440 (punto 5) · La edición de fechas y notas, en un paso
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.actualizar_fechas_y_notas_pedido(
  p_pedido_id bigint,
  p_notas text,
  p_fecha date DEFAULT NULL,
  p_fecha_entrega timestamptz DEFAULT NULL,
  p_fecha_entrega_programada date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'public'
AS $function$
DECLARE
  v_pedido  RECORD;
  v_vuelve  BOOLEAN;
  v_r       JSONB;
  v_version TIMESTAMPTZ;
BEGIN
  -- INVOKER a propósito: el UPDATE de abajo es el PATCH que hacía el front, con sus
  -- mismos permisos (mt_pedidos_update, el GRANT por columna y
  -- pedidos_proteger_columnas, que sólo mira a quien corre como authenticated). Lo
  -- único DEFINER es la vuelta a pendiente, que ya era una RPC (#1372).
  SELECT estado, fecha, fecha_entrega_programada, updated_at INTO v_pedido
    FROM pedidos
   WHERE id = p_pedido_id AND sucursal_id = current_sucursal_id()
     FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'El pedido #% no existe en esta sucursal o no lo podés editar', p_pedido_id
      USING ERRCODE = 'P0002';
  END IF;

  -- #1372: cambiarle el día a un pedido en camino lo saca de la ruta. Se compara
  -- con la fila bloqueada, no con lo que vio el modal. La ventana de las 15:30 del
  -- preventista la mira volver_pedido_a_pendiente_por_edicion.
  v_vuelve := v_pedido.estado = 'asignado'
              AND ((p_fecha IS NOT NULL AND p_fecha IS DISTINCT FROM v_pedido.fecha)
                   OR (p_fecha_entrega_programada IS NOT NULL
                       AND p_fecha_entrega_programada IS DISTINCT FROM v_pedido.fecha_entrega_programada));
  IF v_vuelve THEN
    v_r := public.volver_pedido_a_pendiente_por_edicion(p_pedido_id);
  END IF;

  -- NULL es "sin cambio", como una columna que no viajaba en el PATCH.
  UPDATE pedidos
     SET notas                    = COALESCE(p_notas, notas),
         fecha                    = COALESCE(p_fecha, fecha),
         fecha_entrega            = COALESCE(p_fecha_entrega, fecha_entrega),
         fecha_entrega_programada = COALESCE(p_fecha_entrega_programada, fecha_entrega_programada)
   WHERE id = p_pedido_id
  RETURNING updated_at INTO v_version;

  -- #1323: la versión de antes y la nueva, como sustituir y dividir un regalo
  -- (#1376). Sin vuelta a pendiente son la misma: el PATCH no mueve updated_at.
  RETURN jsonb_build_object(
    'success', true,
    'pedido_id', p_pedido_id,
    'vuelto_a_pendiente', v_vuelve,
    'paradas_eliminadas', COALESCE((v_r->>'paradas_eliminadas')::int, 0),
    'updated_at_anterior', v_pedido.updated_at,
    'updated_at', v_version);
END;
$function$;

REVOKE ALL ON FUNCTION public.actualizar_fechas_y_notas_pedido(bigint, text, date, timestamptz, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.actualizar_fechas_y_notas_pedido(bigint, text, date, timestamptz, date) TO authenticated;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos y los EXECUTE quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT t.firma, t.hash, t.acl, md5(p.prosrc) AS h, p.proacl::text AS a, p.prosecdef AS def, t.def AS def_esperado
      FROM (VALUES
        ('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)',
         'b39d6d60ed41b9d407e1e2a4a4f28a17', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', true),
        ('public.crear_pedido_completo_bot(uuid,uuid)',
         '7677969a6ab3d2e3f50cb3c54a3a0445', '{postgres=X/postgres,service_role=X/postgres}', true),
        ('public.actualizar_fechas_y_notas_pedido(bigint,text,date,timestamp with time zone,date)',
         'd96e3c0a38d363c0a51029af90bc0dca', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', false)
      ) AS t(firma, hash, acl, def)
      JOIN pg_proc p ON p.oid = t.firma::regprocedure
  LOOP
    IF r.h <> r.hash OR r.a IS DISTINCT FROM r.acl OR r.def <> r.def_esperado THEN
      RAISE EXCEPTION '% no quedó como en el repo (md5 %, acl %, definer %)', r.firma, r.h, r.a, r.def;
    END IF;
  END LOOP;
END
$post$;

COMMIT;
