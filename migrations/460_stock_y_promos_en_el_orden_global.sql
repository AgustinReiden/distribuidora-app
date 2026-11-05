-- 460 · Stock y promos en el orden global de locks: productos (con sus contenedores) por id,
-- y las promos después, por id (#1460: C2, C3, C4, C5 y C8). Tarjeta 14 de #1378.
--
-- QUÉ PASABA
--   La venta (crear_pedido_completo y el bot, desde la 455) bloquea los productos de sus
--   líneas y los contenedores de sus promos, juntos y por id, y después sus promos, por id.
--   Seis caminos tomaban esas filas en otro orden, y contra una venta daban 40P01. No
--   rompían datos: la transacción abortada volvía atrás entera, salvo en C8.
--   · C2. ajustar_stock_promocion_completo tomaba la promo y después el producto. Y el UPDATE
--     REST de promociones.unidades_por_bloque o stock_por_bloque (ModalPromocion manda las dos
--     columnas en cada edición de la promo) tiene la fila de la promo y, cuando el factor nuevo
--     cierra un bloque, bloquea cada contenedor en el trigger AFTER
--     trg_renormalizar_bloques_por_cambio_factor. Promo → contenedor contra contenedor → promo.
--   · C3. actualizar_pedido_items tomaba las promos de las líneas viejas por id (al devolver la
--     barra) y las de las nuevas en el orden del JSON: al reinsertar cada línea de regalo (la FK
--     de pedido_items.promocion_id) y en aplicar_uso_promo_acumulador. Una edición con una promo
--     nueva de id menor que otra que ya tenía, contra una venta con las dos, sin ningún
--     producto en común.
--   · C4. registrar_salvedad sobre un pedido con el regalo de una promo que cambió de tipo
--     (#1324: se puede con pedidos abiertos). Ese regalo no pasa por el motor
--     (_regalo_barra_vale), así que la salvedad tomaba el cliente al cambiar el total y la
--     promo recién al confirmar, en trg_limite_usos_promo (un UPDATE de la cantidad del regalo
--     lo dispara). La venta de esa promo al mismo cliente va promo → cliente. La edición no
--     cruza: reinsertar la línea de regalo toma la promo (la FK) antes que el cliente.
--     anular_salvedad, sustituir_regalo_pedido y dividir_regalo_pedido tampoco: la anulación
--     rechaza todo lo que toque un regalo de promo, y las otras dos no cambian el total.
--   · C5. eliminar_pedido_completo recorría las líneas sin ORDER BY. Cada una bloqueaba su
--     producto al devolverlo y, si era un regalo, aplicar_uso_promo_acumulador tomaba la promo
--     y después el contenedor. Contra una venta: contenedor → promo, y producto contra producto.
--   · C8. actualizar_precios_masivo hacía un UPDATE por producto en el orden del JSON. Con su
--     EXCEPTION WHEN OTHERS, si el 40P01 caía en el lote, ese producto quedaba con el precio
--     viejo, el resto se confirmaba y el admin veía "Error en producto ID …: deadlock detected".
--   Medido en el arnés (scripts/concurrencia, T14; las tablas van en #1462). Con el cruce
--   forzado (la fila que la venta pide primero, retenida 250 ms), de 92 a 100 rondas de 100
--   con 40P01 en cada camino, y 0 después. En C8, además, 21 de 100 rondas dejaron un precio
--   viejo.
--
-- QUÉ CAMBIA (sólo el orden de los locks)
--   · ajustar_stock_promocion_completo bloquea el producto antes de la promo.
--   · Un trigger nuevo, BEFORE UPDATE OF unidades_por_bloque, stock_por_bloque FOR EACH
--     STATEMENT (trg_promo_factor_bloquea_contenedores), bloquea los contenedores de las promos
--     de la sucursal activa antes de que el UPDATE tome la fila de la promo. Tiene que ser de
--     sentencia: Postgres bloquea la fila antes de correr los triggers de fila, BEFORE incluidos,
--     así que renormalizar_bloques_por_cambio_factor no puede pre-bloquear nada. Una sentencia no
--     sabe qué filas va a tocar, y por eso toma los contenedores de todas las promos de la
--     sucursal (hoy, los de las 5 promos de prod que tienen contenedor). Sin sucursal activa (el
--     server), los de todas.
--   · actualizar_pedido_items bloquea, justo después de los productos, las promos de las líneas
--     de hoy y las del JSON, por id. Las de abajo pasan a ser re-locks.
--   · registrar_salvedad bloquea, justo después de los productos, las promos del pedido, por id.
--     validar_limite_usos_promo no se toca: al confirmar encuentra la promo ya tomada.
--   · eliminar_pedido_completo, cuando restaura el stock, bloquea antes del bucle los productos
--     de sus líneas con los contenedores de sus promos (como cancelar_pedido_con_stock, #1296), y
--     después esas promos, por id.
--   · actualizar_precios_masivo bloquea los productos del lote de la sucursal activa, por id
--     (FOR NO KEY UPDATE, el lock de su UPDATE), antes del bucle. Un id que no es un número no
--     se toma: el bucle lo informa como siempre.
--
-- QUÉ NO CAMBIA
--   Qué se valida, qué se calcula, qué stock se mueve, las barras, los precios, los mensajes,
--   las firmas y los EXECUTE. renormalizar_bloques_por_cambio_factor no se toca. La función del
--   trigger nuevo no tiene EXECUTE para nadie de la app: la invoca el executor.
--
-- Ensayo: scripts/test-stock-promos-orden-1460.sql, y T14 del arnés (scripts/concurrencia).
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
-- Premisas: nada cambió en prod desde que se leyeron los cuerpos (05/11)
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, md5(p.prosrc) AS md5_vivo
      FROM (VALUES
        ('public.ajustar_stock_promocion_completo(bigint,bigint,integer,integer,uuid,text)',
         '043fee8fb70ab7cff2d8179f9c656151'),
        ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)',
         '6ce783bf7f933809525ed800fadea044'),
        ('public.eliminar_pedido_completo(bigint,uuid,text,boolean)',
         '1ece000e6c6adcd5c863531a2ec5f31b'),
        ('public.actualizar_precios_masivo(jsonb)',
         '71d752586e664aa900cca7cea606f32d'),
        ('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)',
         '61c5324693320ac4b9ac6c9b00c4f322'),
        ('public.renormalizar_bloques_por_cambio_factor()',
         '0f5c089fdcd140cc865b0255d4183c13'),
        ('public._contenedores_de_promos(bigint[],bigint)',
         'cab70e87a44a94a366f9a4b6ec7e42eb')
      ) AS x(firma, md5)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION 'mig 460 · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;
  IF to_regproc('public.promo_factor_bloquea_contenedores') IS NOT NULL THEN
    RAISE EXCEPTION 'mig 460 · promo_factor_bloquea_contenedores ya existe';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- Parches por ancla sobre el cuerpo vivo
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _n_parche (firma text, orden int, ancla text, reemplazo text, veces int DEFAULT 1) ON COMMIT DROP;

INSERT INTO _n_parche (firma, orden, ancla, reemplazo) VALUES
-- C2: el producto antes que la promo.
('public.ajustar_stock_promocion_completo(bigint,bigint,integer,integer,uuid,text)', 1,
$a$  SELECT nombre, usos_pendientes INTO v_promo_nombre, v_usos_pendientes
  FROM promociones WHERE id = p_promocion_id AND sucursal_id = v_sucursal FOR UPDATE;
$a$,
$r$  -- #1460 (C2): el producto antes que la promo, el orden de la venta (455). Se
  -- tomaba la promo y después el producto, y contra una venta que ya tenía el
  -- producto (una línea o el contenedor de su promo) y pedía la promo, 40P01.
  -- El SELECT de abajo lo vuelve a pedir, ya tomado.
  PERFORM 1 FROM productos
   WHERE id = p_producto_id AND sucursal_id = v_sucursal
     FOR UPDATE;

  SELECT nombre, usos_pendientes INTO v_promo_nombre, v_usos_pendientes
  FROM promociones WHERE id = p_promocion_id AND sucursal_id = v_sucursal FOR UPDATE;
$r$),

-- C3: las promos de la edición, por id, después de los productos.
('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 1,
$a$                          WHERE e->>'promocion_id' IS NOT NULL), v_sucursal) c)
    ORDER BY id
      FOR UPDATE;

  FOR v_item_nuevo IN SELECT * FROM jsonb_array_elements(v_items) LOOP
$a$,
$r$                          WHERE e->>'promocion_id' IS NOT NULL), v_sucursal) c)
    ORDER BY id
      FOR UPDATE;

  -- #1460 (C3): y después de los productos, las promos de las líneas de hoy y las
  -- del JSON, por id: el orden de la venta (455). Las viejas las tomaba la vuelta
  -- de la barra, por id, y las nuevas la reinserción de cada regalo (la FK de
  -- pedido_items.promocion_id) y aplicar_uso_promo_acumulador, en el orden del
  -- JSON. Una edición que sumaba una promo de id menor que otra que ya tenía,
  -- contra una venta con las dos y sin ningún producto en común, daba 40P01. Las
  -- de abajo pasan a ser re-locks.
  PERFORM 1
     FROM promociones
    WHERE sucursal_id = v_sucursal
      AND id IN (SELECT pi.promocion_id FROM pedido_items pi
                  WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
                    AND pi.promocion_id IS NOT NULL
                 UNION
                 SELECT (e->>'promocion_id')::bigint FROM jsonb_array_elements(v_items) e
                  WHERE e->>'promocion_id' IS NOT NULL)
    ORDER BY id
      FOR UPDATE;

  FOR v_item_nuevo IN SELECT * FROM jsonb_array_elements(v_items) LOOP
$r$),

-- C5: productos con contenedores, y después las promos, antes del bucle.
('public.eliminar_pedido_completo(bigint,uuid,text,boolean)', 1,
$a$    PERFORM set_config('app.stock_user_id', p_usuario_id::TEXT, true);

    FOR v_item IN
$a$,
$r$    PERFORM set_config('app.stock_user_id', p_usuario_id::TEXT, true);

    -- #1460 (C5): los productos de las líneas con los contenedores de sus promos,
    -- juntos y por id, y después esas promos, por id, antes de mover el primero:
    -- el orden de la venta (455) y de cancelar_pedido_con_stock (#1296). El bucle
    -- los tomaba en el orden de las líneas, y aplicar_uso_promo_acumulador la
    -- promo antes que el contenedor: contra una venta, 40P01. El bucle y el motor
    -- los vuelven a pedir, ya tomados.
    PERFORM 1
       FROM productos
      WHERE sucursal_id = v_sucursal
        AND id IN (SELECT pi.producto_id FROM pedido_items pi
                    WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
                   UNION
                   SELECT c FROM public._contenedores_de_promos(
                     ARRAY(SELECT pi.promocion_id FROM pedido_items pi
                            WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
                              AND pi.promocion_id IS NOT NULL), v_sucursal) c)
      ORDER BY id
        FOR UPDATE;
    PERFORM 1
       FROM promociones
      WHERE sucursal_id = v_sucursal
        AND id IN (SELECT pi.promocion_id FROM pedido_items pi
                    WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
                      AND pi.promocion_id IS NOT NULL)
      ORDER BY id
        FOR UPDATE;

    FOR v_item IN
$r$),

-- C4: las promos de la salvedad, por id, después de los productos y antes que el cliente.
('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)', 1,
$a$                           AND pi.promocion_id IS NOT NULL), v_sucursal) c)
   ORDER BY id
     FOR UPDATE;

  IF v_stock_devuelto THEN
$a$,
$r$                           AND pi.promocion_id IS NOT NULL), v_sucursal) c)
   ORDER BY id
     FOR UPDATE;

  -- #1460 (C4): y después de los productos, las promos del pedido, por id, antes
  -- de que el total tome el cliente: el orden de la venta (455). Un regalo cuya
  -- promo cambió de tipo no pasa por aplicar_uso_promo_acumulador
  -- (_regalo_barra_vale), así que su promo la tomaba recién trg_limite_usos_promo
  -- al confirmar, con el cliente ya tomado: contra una venta de esa promo al mismo
  -- cliente (promo → cliente), 40P01. Las de abajo pasan a ser re-locks.
  PERFORM 1
     FROM promociones
    WHERE sucursal_id = v_sucursal
      AND id IN (SELECT pi.promocion_id FROM pedido_items pi
                  WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
                    AND pi.promocion_id IS NOT NULL)
    ORDER BY id
      FOR UPDATE;

  IF v_stock_devuelto THEN
$r$),

-- C8: los productos del lote, por id, antes del primer UPDATE.
('public.actualizar_precios_masivo(jsonb)', 1,
$a$  FOR v_item IN SELECT * FROM jsonb_array_elements(p_productos)
  LOOP
$a$,
$r$  -- #1460 (C8): los productos del lote, por id, antes del primer UPDATE: el orden
  -- de la venta, la edición, la cancelación y la salvedad. El bucle los
  -- actualizaba en el orden del JSON, y contra una venta con los mismos productos
  -- en otro orden el 40P01 caía en el EXCEPTION de un producto: ese quedaba con el
  -- precio viejo y el resto se confirmaba. FOR NO KEY UPDATE es el lock del UPDATE
  -- de abajo. Un id que no es un número no se toma acá: el bucle lo informa como
  -- siempre.
  PERFORM 1
     FROM productos
    WHERE sucursal_id = v_sucursal_id
      AND id IN (SELECT btrim(e->>'producto_id')::bigint FROM jsonb_array_elements(p_productos) e
                  WHERE btrim(e->>'producto_id') ~ '^[0-9]{1,18}$')
    ORDER BY id
      FOR NO KEY UPDATE;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_productos)
  LOOP
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
        RAISE EXCEPTION 'mig 460 · % parche %: el ancla aparece % vez/veces y se esperaba %',
          v_f.firma, v_p.orden, v_n, v_p.veces;
      END IF;
      v_def := replace(v_def, v_p.ancla, v_p.reemplazo);
    END LOOP;
    EXECUTE v_def;
  END LOOP;
END
$parches$;

-- ---------------------------------------------------------------------------
-- C2 · El cambio de factor por REST bloquea los contenedores antes que la promo
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.promo_factor_bloquea_contenedores()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
BEGIN
  -- #1460 (C2): un UPDATE de unidades_por_bloque o stock_por_bloque tiene la fila
  -- de la promo cuando renormalizar_bloques_por_cambio_factor (AFTER, de fila)
  -- bloquea los contenedores de las barras que cierran un bloque. La venta (455)
  -- toma los contenedores antes que la promo: contenedor → promo contra promo →
  -- contenedor, 40P01. Un trigger de fila no puede adelantarlo (Postgres bloquea
  -- la fila antes de correrlo, BEFORE incluido), así que va acá, antes de que la
  -- sentencia toque la primera fila. Una sentencia no sabe qué promos va a
  -- cambiar: toma los contenedores de todas las de la sucursal activa, por id, y
  -- sin sucursal (el server) los de todas. El trigger de fila los vuelve a pedir,
  -- ya tomados.
  PERFORM 1
     FROM productos
    WHERE id IN (SELECT p.ajuste_producto_id FROM promociones p
                  WHERE p.ajuste_producto_id IS NOT NULL
                    AND (v_sucursal IS NULL OR p.sucursal_id = v_sucursal)
                 UNION
                 SELECT a.ajuste_producto_id FROM promo_acumuladores a
                  WHERE a.ajuste_producto_id IS NOT NULL
                    AND (v_sucursal IS NULL OR a.sucursal_id = v_sucursal))
    ORDER BY id
      FOR UPDATE;
  RETURN NULL;
END
$function$;

-- Una función de trigger no necesita EXECUTE para nadie: la invoca el executor.
REVOKE EXECUTE ON FUNCTION public.promo_factor_bloquea_contenedores() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_promo_factor_bloquea_contenedores
  BEFORE UPDATE OF unidades_por_bloque, stock_por_bloque ON public.promociones
  FOR EACH STATEMENT EXECUTE FUNCTION public.promo_factor_bloquea_contenedores();

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos y los EXECUTE quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT t.firma, t.hash, t.acl, md5(p.prosrc) AS h, p.proacl::text AS a, p.prosecdef AS def
      FROM (VALUES
        ('public.ajustar_stock_promocion_completo(bigint,bigint,integer,integer,uuid,text)',
         'ae715049d22943a572d7ce7a0383637a', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)',
         '3462f61e5646aaec6f4a041a7000dc0e', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public.eliminar_pedido_completo(bigint,uuid,text,boolean)',
         '4699d753d43fe0e55ad104f07d0f9ba4', '{postgres=X/postgres,service_role=X/postgres}'),
        ('public.actualizar_precios_masivo(jsonb)',
         '8fcdc176939f6ddc5ed665cf8fc290e9', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)',
         '44d44c4746ae64d8499213c430e65037', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public.promo_factor_bloquea_contenedores()',
         '132df7f62ce68c73171bb7f7190f69bf', '{postgres=X/postgres,service_role=X/postgres}')
      ) AS t(firma, hash, acl)
      JOIN pg_proc p ON p.oid = t.firma::regprocedure
  LOOP
    IF r.h <> r.hash OR r.a IS DISTINCT FROM r.acl OR NOT r.def THEN
      RAISE EXCEPTION '% no quedó como en el repo (md5 %, acl %, definer %)', r.firma, r.h, r.a, r.def;
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgname = 'trg_promo_factor_bloquea_contenedores'
                    AND tgrelid = 'public.promociones'::regclass AND tgenabled = 'O') THEN
    RAISE EXCEPTION 'trg_promo_factor_bloquea_contenedores no quedó creado';
  END IF;
END
$post$;

COMMIT;
