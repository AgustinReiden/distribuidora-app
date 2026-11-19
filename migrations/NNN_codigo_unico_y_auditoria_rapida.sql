-- =========================================================================
-- NNN · EL CÓDIGO DE UN PRODUCTO ES ÚNICO POR SUCURSAL, Y LA AUDITORÍA POR
--       FILA DEJA DE CONSULTAR EL CATÁLOGO EN CADA FILA
--       (plan #1603, ola 2, tanda 5, tarjeta C4a: 1561-b1 de #1561 y
--        1596-b9 de #1596)
--
-- Un índice único nuevo en `productos`, una función de trigger nueva con sus
-- dos triggers, `audit_log_changes()`, `renombrar_rubro` y `eliminar_rubro`
-- reescritas enteras con premisa de md5 sobre los cuerpos vivos (ledger en la
-- 530), y el `WHEN` de `audit_productos_update` (se recrea, con premisa sobre
-- su definición). No cambia firmas. No corrige filas.
-- Ensayo: scripts/test-codigo-y-auditoria-ola2-1603.sql. Se aplica en LF.
--
-- =========================================================================
-- 1561-b1 · EL CÓDIGO DE UN PRODUCTO ES ÚNICO POR SUCURSAL (decisión D31)
-- =========================================================================
-- Hasta acá sólo lo frenaba el front (`verificarCodigoLibre`, que compara el
-- texto exacto): la base aceptaba dos productos de la misma sucursal con el
-- mismo código por cualquier otro camino (un envío entre sucursales que crea
-- el producto, un bundle viejo, un PATCH), y la importación de una compra por
-- código se quedaba con el primero que encontraba.
--   · `productos_codigo_unico_por_sucursal`: índice único sobre
--     (sucursal_id, upper(btrim(codigo))), sin los vacíos. Mayúsculas y
--     espacios de los bordes como en los rubros (`upper(btrim(nombre))`, la
--     regla de la B6a): «abc-1», «ABC-1» y « ABC-1 » son el mismo código; un
--     espacio de adentro, no. NULL, '' y sólo espacios no cuentan: un producto
--     sin código no choca con nadie. El código se sigue guardando como se
--     tipeó (el front nuevo le saca los espacios de los bordes).
--   · `trg_productos_codigo_unico` (BEFORE INSERT, con código) y
--     `trg_productos_codigo_unico_upd` (BEFORE UPDATE OF codigo, sucursal_id,
--     sólo si alguno de los dos cambia): dan el mensaje que se entiende, con
--     el producto que ya lo tiene y si está desactivado (el alta y la edición
--     de la ficha, el alta rápida desde una compra, el envío entre sucursales
--     que crea el producto en el destino aceptado por un admin). Buscan por el
--     índice (DEFINER, sin ORDER BY y planificando cada vez: si no, un alta de
--     15.000 productos de una vez en una base nueva es cuadrática; medido,
--     2 min 30 s contra 3 s).
--     El trigger corre ANTES que la RLS, así que nombra el producto sólo a
--     quien pasa la policy de escritura de `productos` (mt_productos_insert y
--     mt_productos_update: `es_admin() AND sucursal_id = current_sucursal_id()`),
--     o al server (sin usuario). A cualquier otro le devuelve la fila y lo
--     frena la RLS con su 42501, sin nada del producto: el depósito, que no
--     lee productos, no puede sondearlos código por código, y al preventista
--     o al encargado no se les dice «usá ese producto» por una escritura que
--     no pueden hacer (H1 de la revisión). El encargado que acepta un envío
--     (la RPC es definer y no pasa por la RLS) recibe el 23505 del índice,
--     que la RPC devuelve en `error` y el front traduce
--     (`mensajeAlAceptarEnvio`).
--     Dos altas que se cruzan pasan las dos el trigger (ninguna ve la fila
--     sin confirmar de la otra): a la segunda la frena el índice con su 23505
--     crudo, que el front nuevo traduce (`esCodigoDuplicadoDeBase`).
--   · No hay una importación masiva de productos: la de una compra
--     (`ModalImportarCompra`) busca por código sin mirar mayúsculas ni
--     bordes, la misma regla, y no crea productos. El bot no escribe
--     `productos.codigo`.
-- Premisa: si hoy hay códigos repetidos en una sucursal (con la misma regla),
-- la migración aborta y los lista, para que el dueño decida cuál queda (D31).
-- Medido en producción el 19/11: 0.
--
-- =========================================================================
-- 1596-b9 · RENOMBRAR O ELIMINAR UN RUBRO GRANDE TARDA
-- =========================================================================
-- `renombrar_rubro` y `eliminar_rubro` hacen un UPDATE de todos los productos
-- del rubro, y `audit_log_changes()` corre por cada fila. Por fila consultaba
-- `information_schema.columns` (una vista con chequeos de privilegios sobre
-- todo el catálogo) para saber si la tabla tiene `sucursal_id`, calculaba
-- `to_jsonb(NEW)` y `to_jsonb(OLD)` hasta tres veces, y armaba el diff con un
-- bucle que concatenaba el JSON clave por clave. Ahora:
--   · «¿la tabla tiene sucursal_id?» sale de `pg_attribute` por el oid de la
--     tabla (`TG_RELID`): la misma respuesta (la función es definer del dueño
--     de las tablas, así que la vista nunca le escondía una columna);
--   · cada `to_jsonb` se calcula una vez;
--   · el diff es una sola consulta (`jsonb_each … WITH ORDINALITY`), con las
--     claves en el mismo orden que el bucle (el de `jsonb_object_keys`).
-- Lo que guarda no cambia NADA: mismas filas, mismas columnas, mismo
-- contenido, también `campos_modificados` en el mismo orden (comparado fila
-- por fila antes y después: UPDATE suelto y masivo, INSERT y DELETE, como
-- authenticated, como service_role, por una RPC definer, con un usuario
-- desactivado y sin usuario). El usuario se sigue leyendo en cada fila
-- (`auth.users`, `perfiles`): guardarlo una vez por transacción cambiaría lo
-- que se anota si el rol o el email cambian en la misma transacción.
-- Con eso solo, 15.000 productos todavía rozaban el corte de 8 s y 30.000 lo
-- pasaban siempre: el piso es el INSERT de una fila de `audit_logs` por
-- producto (ocho índices y dos FK).
-- Decisión del dueño (19/11): al renombrar o eliminar un rubro se anota UNA
-- fila en el rubro, no una por producto, como la baja de stock por venta, que
-- no se audita en `productos` porque ya está en `stock_historico`. Entonces:
--   · `renombrar_rubro` y `eliminar_rubro` pasan a DEFINER (validan
--     `es_admin()` y la sucursal activa adentro, como hasta acá, y acotan cada
--     escritura a la sucursal) y escriben ellas la fila: tabla `categorias`,
--     registro el id del rubro (o su nombre, si es un rubro sólo de texto),
--     UPDATE (nombre viejo → nuevo) o DELETE, cuántos productos alcanzó y, en
--     `old_data.productos`, el antes de cada uno agrupado por (categoria,
--     categoria_id, subcategoria_id) con sus ids: con eso se reconstruye el
--     antes y el después de cada producto. `categorias` no tenía auditoría.
--   · El UPDATE de los productos lleva la marca `app.rubro_masivo` (con
--     `set_config(…, true)`: no sobrevive a la transacción, y la función la
--     borra apenas termina ese UPDATE), y el `WHEN` de `audit_productos_update`
--     saltea la fila sólo si está la marca Y lo único que cambió es el rubro
--     (`categoria`, `categoria_id`, `subcategoria_id` y `updated_at`), el molde
--     de `app.stock_origen`. La marca sola no alcanza: con ella, un cambio de
--     cualquier otra columna se audita entero. Cambiar el rubro de un producto
--     desde la ficha, o por un UPDATE directo, se sigue auditando como siempre.
--     Por REST nadie puede poner la marca (`set_config` no es una RPC).
--   · Quién lee `audit_logs` de `productos`: `precio_fuera_de_politica`, sólo
--     las filas con `precio` (un rubro no lo toca). El front no lee
--     `audit_logs`. Ninguna pantalla cambia.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

-- La tabla que la migración altera (el índice, los triggers nuevos y el DROP/CREATE de
-- audit_productos_update, que pide ACCESS EXCLUSIVE), tomada de una vez y antes de leerla:
-- si alguien la tiene tomada falla al instante y se reintenta, sin dejar a nadie esperando.
-- Frena productos unos milisegundos.
LOCK TABLE public.productos IN ACCESS EXCLUSIVE MODE NOWAIT;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: el cuerpo vivo es el de la 530, lo nuevo no existe, y los códigos
-- no se repiten
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.audit_log_changes()',                   'd0dcffb22ac9e2e91eda9a0048e6b932'),
    ('public.renombrar_rubro(uuid,text,text)',       'b2d1c5d7c645205423f9a71930984295'),
    ('public.eliminar_rubro(uuid,text,boolean)',     '7179adade957b3b85f377273ed951820')
  ) AS t(f, h) LOOP
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = to_regprocedure(r.f);
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;

  SELECT pg_get_triggerdef(t.oid) INTO v FROM pg_trigger t
   WHERE t.tgrelid = 'public.productos'::regclass AND t.tgname = 'audit_productos_update';
  IF v IS DISTINCT FROM 'CREATE TRIGGER audit_productos_update AFTER UPDATE ON public.productos FOR EACH ROW WHEN ((NOT COALESCE(((new.stock < old.stock) AND (current_setting(''app.stock_origen''::text, true) = ANY (ARRAY[''pedido_creado''::text, ''pedido_creado_bot''::text, ''pedido_editado''::text])) AND (((to_jsonb(old.*) - ''stock''::text) - ''updated_at''::text) = ((to_jsonb(new.*) - ''stock''::text) - ''updated_at''::text))), false))) EXECUTE FUNCTION audit_log_changes()' THEN
    RAISE EXCEPTION 'mig NNN · audit_productos_update cambió desde que se leyó: %', v;
  END IF;

  IF to_regprocedure('public.productos_codigo_unico()') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · public.productos_codigo_unico() ya existe';
  END IF;
  IF to_regclass('public.productos_codigo_unico_por_sucursal') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · el índice productos_codigo_unico_por_sucursal ya existe';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_trigger
              WHERE tgrelid = 'public.productos'::regclass
                AND tgname IN ('trg_productos_codigo_unico', 'trg_productos_codigo_unico_upd')) THEN
    RAISE EXCEPTION 'mig NNN · los triggers trg_productos_codigo_unico ya existen';
  END IF;

  -- 1561-b1 (D31): el índice no entra si hoy hay dos productos de una sucursal con el
  -- mismo código (sin mirar mayúsculas ni los espacios de los bordes). Se listan para
  -- que el dueño decida cuál queda.
  SELECT string_agg(format('sucursal %s, código «%s»: %s', d.sucursal_id, d.clave, d.cuales), '; '
                    ORDER BY d.sucursal_id, d.clave)
    INTO v
    FROM (SELECT p.sucursal_id, upper(btrim(p.codigo)) AS clave,
                 string_agg(format('#%s %s (%s)', p.id, p.nombre, CASE WHEN p.activo THEN 'activo' ELSE 'desactivado' END),
                            ', ' ORDER BY p.id) AS cuales
            FROM productos p
           WHERE btrim(p.codigo) <> ''
           GROUP BY 1, 2
          HAVING count(*) > 1) d;
  IF v IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · 1561-b1 · hay productos con el mismo código en la misma sucursal: %. Que el dueño decida cuál queda (y le cambie el código al otro) antes de aplicar.', v;
  END IF;
END
$premisas$;

-- =========================================================================
-- 1561-b1 · El índice y el trigger que da el mensaje
-- =========================================================================
CREATE UNIQUE INDEX productos_codigo_unico_por_sucursal
  ON public.productos (sucursal_id, (upper(btrim(codigo))))
  WHERE btrim(codigo) <> '';

COMMENT ON INDEX public.productos_codigo_unico_por_sucursal IS
  'mig NNN (1561-b1, decisión del dueño D31): el código de un producto es único por sucursal, sin mirar mayúsculas ni los espacios de los bordes (como los rubros). Sin código (NULL, vacío o espacios) no cuenta. El mensaje lo dan los triggers trg_productos_codigo_unico(_upd); esto cubre la carrera y a quien escribe sin pasar por la RLS.';

CREATE FUNCTION public.productos_codigo_unico()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
 SET plan_cache_mode TO 'force_custom_plan'
AS $function$
DECLARE
  v_otro record;
BEGIN
  -- mig NNN (1561-b1, decisión del dueño D31): el código de un producto es único por
  -- sucursal, sin mirar mayúsculas ni los espacios de los bordes. Lo asegura el índice
  -- productos_codigo_unico_por_sucursal; esto da el mensaje que se entiende, con el
  -- producto que ya lo tiene. Un vacío, o un UPDATE que no cambia el código ni la sucursal,
  -- no llega acá (el WHEN de los triggers).

  -- Este trigger corre ANTES que la RLS: nombra el producto sólo a quien pasa la policy de
  -- escritura de productos (mt_productos_insert / mt_productos_update: es_admin() en su
  -- sucursal activa) o al server (sin usuario). A cualquier otro le devuelve la fila sin
  -- mirar nada, y lo frena la RLS con su 42501: el depósito no lee productos y no puede
  -- sondearlos código por código, y al que no puede dar de alta no se le dice «usá ese
  -- producto» (#1559). Lo que pase de largo (el encargado que acepta un envío por la RPC
  -- definer) lo frena el índice.
  IF NOT (auth.uid() IS NULL OR (es_admin() AND NEW.sucursal_id = current_sucursal_id())) THEN
    RETURN NEW;
  END IF;

  -- Por el índice único: si no, la búsqueda recorre la sucursal entera por cada fila y un
  -- alta de 15.000 productos de una vez es cuadrática (medido en una base nueva: 2 min 30 s
  -- sólo en este trigger; así, 3 s). Por eso es DEFINER (con la RLS de quien escribe,
  -- upper() y btrim() no son leakproof y no pueden ser condición del índice), no lleva
  -- ORDER BY (el plan elegía recorrer la clave primaria en orden) y planifica cada vez
  -- (plan_cache_mode): el plan guardado se arma con la tabla casi vacía, en una base nueva o
  -- en una conexión del pool que nació con el catálogo chico, y se queda en
  -- idx_productos_sucursal aunque la sucursal crezca.
  SELECT p.id, p.nombre, p.activo INTO v_otro
    FROM productos p
   WHERE p.sucursal_id = NEW.sucursal_id
     AND btrim(p.codigo) <> ''
     AND upper(btrim(p.codigo)) = upper(btrim(NEW.codigo))
     AND p.id <> NEW.id
   LIMIT 1;

  IF FOUND THEN
    RAISE EXCEPTION 'Ya existe un producto con el código «%» en esta sucursal: «%»%. Usá ese producto (al recibir un envío, elegilo como destino) o cargá este con otro código.',
      btrim(NEW.codigo), v_otro.nombre,
      CASE WHEN v_otro.activo THEN '' ELSE ' (desactivado)' END
      USING ERRCODE = '23505';
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.productos_codigo_unico() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.productos_codigo_unico() TO service_role;

COMMENT ON FUNCTION public.productos_codigo_unico() IS
  'mig NNN (1561-b1, D31): el mensaje del código repetido en la misma sucursal (23505), con el producto que ya lo tiene. El índice productos_codigo_unico_por_sucursal cubre la carrera.';

-- Disparan sólo cuando hay algo que mirar: un alta con código, o un cambio de código o de
-- sucursal (un aumento de precios masivo o renombrar un rubro no los tocan).
CREATE TRIGGER trg_productos_codigo_unico
  BEFORE INSERT ON public.productos
  FOR EACH ROW
  WHEN (btrim(NEW.codigo) <> '')
  EXECUTE FUNCTION public.productos_codigo_unico();

CREATE TRIGGER trg_productos_codigo_unico_upd
  BEFORE UPDATE OF codigo, sucursal_id ON public.productos
  FOR EACH ROW
  WHEN (btrim(NEW.codigo) <> ''
        AND (NEW.codigo IS DISTINCT FROM OLD.codigo OR NEW.sucursal_id IS DISTINCT FROM OLD.sucursal_id))
  EXECUTE FUNCTION public.productos_codigo_unico();

-- =========================================================================
-- 1596-b9 · audit_log_changes(): lo mismo, sin consultar el catálogo por fila
-- =========================================================================
CREATE OR REPLACE FUNCTION public.audit_log_changes()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_old_data JSONB; v_new_data JSONB; v_campos_modificados TEXT[];
  v_usuario_id UUID; v_usuario_email TEXT; v_usuario_rol TEXT;
  v_registro_id TEXT;
  v_sucursal_id BIGINT;
  v_has_sucursal_col BOOLEAN;
BEGIN
  v_usuario_id := auth.uid();
  IF v_usuario_id IS NOT NULL THEN
    SELECT email INTO v_usuario_email FROM auth.users WHERE id = v_usuario_id;
    SELECT rol INTO v_usuario_rol FROM public.perfiles WHERE id = v_usuario_id;
  END IF;

  -- Does the audited table have a sucursal_id column?
  -- mig NNN (1596-b9, #1596): por el oid de la tabla, en el catálogo. Consultar
  -- information_schema.columns en cada fila era lo más caro de un UPDATE masivo
  -- (renombrar o eliminar un rubro). La respuesta es la misma: esta función es definer
  -- del dueño de las tablas, y la vista nunca le escondía una columna.
  SELECT EXISTS (
    SELECT 1 FROM pg_catalog.pg_attribute a
     WHERE a.attrelid = TG_RELID
       AND a.attname  = 'sucursal_id'
       AND a.attnum   > 0
       AND NOT a.attisdropped
  ) INTO v_has_sucursal_col;

  IF TG_OP = 'DELETE' THEN
    v_registro_id := OLD.id::TEXT;
    v_old_data := to_jsonb(OLD);
    v_new_data := NULL;
    v_sucursal_id := COALESCE((v_old_data->>'sucursal_id')::BIGINT, current_sucursal_id());
  ELSIF TG_OP = 'INSERT' THEN
    v_registro_id := NEW.id::TEXT;
    v_old_data := NULL;
    v_new_data := to_jsonb(NEW);
    v_sucursal_id := COALESCE((v_new_data->>'sucursal_id')::BIGINT, current_sucursal_id());
  ELSE
    v_registro_id := NEW.id::TEXT;
    v_old_data := to_jsonb(OLD);
    v_new_data := to_jsonb(NEW);
    v_sucursal_id := COALESCE(
      (v_new_data->>'sucursal_id')::BIGINT,
      (v_old_data->>'sucursal_id')::BIGINT,
      current_sucursal_id()
    );

    -- mig NNN (1596-b9): las columnas que cambiaron, de una pasada, en el orden de las
    -- claves de NEW (el de jsonb_object_keys, el del bucle de antes). Sin cambios no se
    -- anota nada.
    SELECT array_agg(n.key ORDER BY n.ord),
           jsonb_object_agg(n.key, v_old_data->n.key),
           jsonb_object_agg(n.key, n.value)
      INTO v_campos_modificados, v_old_data, v_new_data
      FROM jsonb_each(v_new_data) WITH ORDINALITY AS n(key, value, ord)
     WHERE v_old_data->n.key IS DISTINCT FROM n.value;
    IF v_campos_modificados IS NULL THEN
      RETURN NEW;
    END IF;
  END IF;

  -- FIX H7 (refined): only fail when the table HAS sucursal_id but we
  -- couldn't resolve one. For global tables (perfiles, sucursales, etc.)
  -- log with NULL sucursal_id - those rows are not tenant-scoped.
  IF v_has_sucursal_col AND v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'audit_log_changes: cannot determine sucursal_id for tenant-scoped table %', TG_TABLE_NAME;
  END IF;

  INSERT INTO public.audit_logs (tabla, registro_id, accion, old_data, new_data, campos_modificados, usuario_id, usuario_email, usuario_rol, sucursal_id)
  VALUES (TG_TABLE_NAME, v_registro_id, TG_OP, v_old_data, v_new_data, v_campos_modificados, v_usuario_id, v_usuario_email, v_usuario_rol, v_sucursal_id);

  IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$function$;

-- =========================================================================
-- 1596-b9 · Renombrar o eliminar un rubro: una fila de auditoría en el rubro
-- (decisión del dueño, 19/11)
-- =========================================================================
DROP TRIGGER audit_productos_update ON public.productos;
CREATE TRIGGER audit_productos_update
  AFTER UPDATE ON public.productos
  FOR EACH ROW
  WHEN (NOT COALESCE((NEW.stock < OLD.stock
                      AND current_setting('app.stock_origen', true) = ANY (ARRAY['pedido_creado', 'pedido_creado_bot', 'pedido_editado'])
                      AND (to_jsonb(OLD) - 'stock' - 'updated_at') = (to_jsonb(NEW) - 'stock' - 'updated_at')), false)
        AND NOT COALESCE((current_setting('app.rubro_masivo', true) = ANY (ARRAY['renombrar_rubro', 'eliminar_rubro'])
                          AND (to_jsonb(OLD) - ARRAY['categoria', 'categoria_id', 'subcategoria_id', 'updated_at'])
                            = (to_jsonb(NEW) - ARRAY['categoria', 'categoria_id', 'subcategoria_id', 'updated_at'])), false))
  EXECUTE FUNCTION public.audit_log_changes();

COMMENT ON TRIGGER audit_productos_update ON public.productos IS
  'No audita la baja de stock por venta (ya está en stock_historico, D38) ni, con la marca app.rubro_masivo que ponen renombrar_rubro y eliminar_rubro, una fila cuyo único cambio es el rubro: esas dos anotan una fila en el rubro (mig NNN, 1596-b9, decisión del dueño del 19/11). Con la marca, cualquier otro cambio se audita entero.';

CREATE OR REPLACE FUNCTION public.renombrar_rubro(p_categoria_id uuid, p_nombre_actual text, p_nombre_nuevo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_sucursal  bigint := current_sucursal_id();
  v_nuevo     text := btrim(COALESCE(p_nombre_nuevo, ''));
  v_actual    text;
  v_id        uuid := p_categoria_id;
  v_productos integer := 0;
  v_desc      integer := 0;
  v_huerfanos integer := 0;
  v_antes     jsonb;
  v_uid       uuid := auth.uid();
BEGIN
  -- mig NNN (1596-b9, decisión del dueño del 19/11): DEFINER, para escribir la fila de
  -- auditoría del rubro. Valida el rol y la sucursal activa como antes, y cada escritura
  -- va acotada a esa sucursal (la RLS ya no la mira).
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin puede renombrar un rubro' USING ERRCODE = '42501';
  END IF;
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No hay una sucursal activa: recargá la página e intentá de nuevo' USING ERRCODE = '22023';
  END IF;
  IF v_nuevo = '' THEN
    RAISE EXCEPTION 'El nombre nuevo no puede estar vacío' USING ERRCODE = '22023';
  END IF;

  IF v_id IS NOT NULL THEN
    SELECT c.nombre INTO v_actual
      FROM categorias c
     WHERE c.id = v_id AND c.sucursal_id = v_sucursal AND c.parent_id IS NULL
       FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'El rubro no existe en esta sucursal: recargá la pantalla' USING ERRCODE = 'P0002';
    END IF;
  ELSE
    -- Un rubro que sólo existe como texto de productos (#763): se le crea la fila.
    v_actual := btrim(COALESCE(p_nombre_actual, ''));
    IF v_actual = '' THEN
      RAISE EXCEPTION 'Falta el rubro a renombrar' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM categorias c
                WHERE c.sucursal_id = v_sucursal AND c.parent_id IS NULL
                  AND upper(btrim(c.nombre)) = upper(v_actual)) THEN
      RAISE EXCEPTION 'El rubro «%» ya tiene fila: recargá la pantalla', v_actual USING ERRCODE = '22023';
    END IF;
  END IF;

  IF v_nuevo = v_actual THEN
    RETURN jsonb_build_object('success', true, 'id', v_id, 'nombre', v_nuevo,
                              'productos', 0, 'descuentos', 0, 'descuentos_huerfanos', 0);
  END IF;

  -- No fusiona: el nombre nuevo no puede ser de otro rubro, ni por fila ni por texto.
  IF EXISTS (SELECT 1 FROM categorias c
              WHERE c.sucursal_id = v_sucursal AND c.parent_id IS NULL
                AND upper(btrim(c.nombre)) = upper(v_nuevo)
                AND c.id IS DISTINCT FROM v_id)
     OR (upper(v_nuevo) <> upper(v_actual) AND EXISTS (
          SELECT 1 FROM productos p
           WHERE p.sucursal_id = v_sucursal
             AND upper(btrim(p.categoria)) = upper(v_nuevo))) THEN
    RAISE EXCEPTION 'Ya existe un rubro llamado «%»', v_nuevo USING ERRCODE = '23505';
  END IF;

  IF v_id IS NOT NULL THEN
    UPDATE categorias SET nombre = v_nuevo WHERE id = v_id AND sucursal_id = v_sucursal;
  ELSE
    INSERT INTO categorias (nombre, sucursal_id) VALUES (v_nuevo, v_sucursal) RETURNING id INTO v_id;
  END IF;

  -- El trigger de productos le vuelve a buscar el id por el nombre nuevo: es el mismo rubro.
  -- mig NNN (1596-b9): con la marca, la auditoría de productos no anota una fila por producto
  -- cuyo único cambio es el rubro; la anota esta función, en el rubro, con el antes de cada
  -- uno (agrupado, con sus ids). La marca se borra apenas termina el UPDATE.
  PERFORM set_config('app.rubro_masivo', 'renombrar_rubro', true);
  WITH cambiados AS (
    UPDATE productos p
       SET categoria = v_nuevo
      FROM productos o
     WHERE o.id = p.id
       AND p.sucursal_id = v_sucursal
       AND (p.categoria_id = v_id OR upper(btrim(p.categoria)) = upper(v_actual))
    RETURNING p.id, o.categoria, o.categoria_id, o.subcategoria_id
  )
  SELECT COALESCE(sum(g.n), 0), COALESCE(jsonb_agg(g.grupo ORDER BY g.grupo::text), '[]'::jsonb)
    INTO v_productos, v_antes
    FROM (SELECT count(*) AS n,
                 jsonb_build_object('categoria', c.categoria, 'categoria_id', c.categoria_id,
                                    'subcategoria_id', c.subcategoria_id,
                                    'ids', jsonb_agg(c.id ORDER BY c.id)) AS grupo
            FROM cambiados c
           GROUP BY c.categoria, c.categoria_id, c.subcategoria_id) g;
  PERFORM set_config('app.rubro_masivo', '', true);

  -- Un descuento con el nombre nuevo era de un rubro que no existe: si quedara, empezaría a
  -- aplicar solo a los productos de este rubro.
  IF upper(v_nuevo) <> upper(v_actual) THEN
    DELETE FROM cliente_descuentos_categoria d
     USING clientes c
     WHERE c.id = d.cliente_id AND c.sucursal_id = v_sucursal
       AND upper(btrim(d.categoria)) = upper(v_nuevo);
    GET DIAGNOSTICS v_huerfanos = ROW_COUNT;
  END IF;

  -- El descuento por rubro de cada cliente pasa al nombre nuevo (no hay UPDATE REST: se
  -- reemplaza la fila). Si un cliente tenía dos con distinta caja, queda la exacta.
  WITH viejos AS (
    DELETE FROM cliente_descuentos_categoria d
     USING clientes c
     WHERE c.id = d.cliente_id AND c.sucursal_id = v_sucursal
       AND upper(btrim(d.categoria)) = upper(v_actual)
    RETURNING d.cliente_id, d.categoria, d.descuento_porcentaje
  )
  INSERT INTO cliente_descuentos_categoria (cliente_id, categoria, descuento_porcentaje)
  SELECT DISTINCT ON (cliente_id) cliente_id, v_nuevo, descuento_porcentaje
    FROM viejos
   ORDER BY cliente_id, (categoria = v_actual) DESC, descuento_porcentaje;
  GET DIAGNOSTICS v_desc = ROW_COUNT;

  -- La fila de auditoría del rubro (las columnas de audit_log_changes).
  INSERT INTO audit_logs (tabla, registro_id, accion, old_data, new_data, campos_modificados,
                          usuario_id, usuario_email, usuario_rol, sucursal_id)
  VALUES ('categorias', v_id::text, 'UPDATE',
          jsonb_build_object('nombre', v_actual, 'productos', v_antes),
          jsonb_build_object('nombre', v_nuevo, 'categoria_id', v_id, 'cantidad_productos', v_productos,
                             'descuentos', v_desc, 'descuentos_huerfanos', v_huerfanos),
          ARRAY['nombre'], v_uid,
          (SELECT u.email FROM auth.users u WHERE u.id = v_uid),
          (SELECT pf.rol FROM perfiles pf WHERE pf.id = v_uid AND COALESCE(pf.activo, true)),
          v_sucursal);

  RETURN jsonb_build_object('success', true, 'id', v_id, 'nombre', v_nuevo,
                            'productos', v_productos, 'descuentos', v_desc,
                            'descuentos_huerfanos', v_huerfanos);
END
$function$;

CREATE OR REPLACE FUNCTION public.eliminar_rubro(p_categoria_id uuid, p_nombre text, p_solo_ver boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_sucursal   bigint := current_sucursal_id();
  v_id         uuid := p_categoria_id;
  v_nombre     text;
  v_ids        uuid[];
  v_combos     text[];
  v_comisiones integer;
  v_productos  integer;
  v_subrubros  integer;
  v_desc       integer;
  v_metas      integer;
  v_bloqueos   text[] := '{}';
  v_antes      jsonb;
  v_uid        uuid := auth.uid();
BEGIN
  -- mig NNN (1596-b9, decisión del dueño del 19/11): DEFINER, para escribir la fila de
  -- auditoría del rubro. Valida el rol y la sucursal activa como antes, y cada escritura
  -- va acotada a esa sucursal (la RLS ya no la mira).
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin puede eliminar un rubro' USING ERRCODE = '42501';
  END IF;
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No hay una sucursal activa: recargá la página e intentá de nuevo' USING ERRCODE = '22023';
  END IF;

  IF v_id IS NOT NULL THEN
    SELECT c.nombre INTO v_nombre
      FROM categorias c
     WHERE c.id = v_id AND c.sucursal_id = v_sucursal AND c.parent_id IS NULL
       FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'El rubro no existe en esta sucursal: recargá la pantalla' USING ERRCODE = 'P0002';
    END IF;
    SELECT array_agg(c.id) INTO v_ids
      FROM categorias c
     WHERE c.sucursal_id = v_sucursal AND (c.id = v_id OR c.parent_id = v_id);
  ELSE
    v_nombre := btrim(COALESCE(p_nombre, ''));
    IF v_nombre = '' THEN
      RAISE EXCEPTION 'Falta el rubro a eliminar' USING ERRCODE = '22023';
    END IF;
    -- El texto «BEBIDAS» de un producto es del rubro «Bebidas» (el trigger le pone su id):
    -- borrarlo como texto suelto le sacaría los productos al rubro con fila.
    IF EXISTS (SELECT 1 FROM categorias c
                WHERE c.sucursal_id = v_sucursal AND c.parent_id IS NULL
                  AND upper(btrim(c.nombre)) = upper(v_nombre)) THEN
      RAISE EXCEPTION 'El rubro «%» tiene fila: eliminalo desde ahí, o recargá la pantalla', v_nombre USING ERRCODE = '22023';
    END IF;
    v_ids := '{}';
  END IF;

  -- Lo que frena: la FK no deja, y soltarlos cambiaría el combo o la comisión.
  SELECT array_agg(DISTINCT co.nombre ORDER BY co.nombre) INTO v_combos
    FROM combo_componentes cc
    JOIN combos co ON co.id = cc.combo_id
   WHERE cc.sucursal_id = v_sucursal AND cc.categoria_id = ANY(v_ids);
  SELECT count(*) INTO v_comisiones
    FROM comision_reglas cr
   WHERE cr.sucursal_id = v_sucursal AND cr.categoria_id = ANY(v_ids);

  IF v_combos IS NOT NULL THEN
    v_bloqueos := v_bloqueos || format('está en %s: %s',
      CASE WHEN cardinality(v_combos) = 1 THEN 'el combo' ELSE 'los combos' END,
      array_to_string(v_combos, ', '));
  END IF;
  IF v_comisiones > 0 THEN
    v_bloqueos := v_bloqueos || format('tiene %s %s',
      v_comisiones, CASE WHEN v_comisiones = 1 THEN 'regla de comisión' ELSE 'reglas de comisión' END);
  END IF;

  -- Lo que se lleva.
  SELECT count(*) INTO v_productos
    FROM productos p
   WHERE p.sucursal_id = v_sucursal
     AND (p.categoria_id = v_id OR upper(btrim(p.categoria)) = upper(v_nombre));
  v_subrubros := GREATEST(cardinality(v_ids) - 1, 0);
  SELECT count(*) INTO v_desc
    FROM cliente_descuentos_categoria d
    JOIN clientes c ON c.id = d.cliente_id
   WHERE c.sucursal_id = v_sucursal AND upper(btrim(d.categoria)) = upper(v_nombre);
  SELECT count(*) INTO v_metas
    FROM metas_preventista m
   WHERE m.sucursal_id = v_sucursal AND m.categoria_id = ANY(v_ids);

  IF p_solo_ver OR cardinality(v_bloqueos) > 0 THEN
    IF NOT p_solo_ver THEN
      RAISE EXCEPTION 'No se puede eliminar el rubro «%»: %. Sacalo de ahí antes, o desactivalo en lugar de eliminarlo.',
        v_nombre, array_to_string(v_bloqueos, ' y ') USING ERRCODE = '23503';
    END IF;
    RETURN jsonb_build_object('success', true, 'solo_ver', true, 'nombre', v_nombre,
      'productos', v_productos, 'subrubros', v_subrubros, 'descuentos', v_desc, 'metas', v_metas,
      'bloqueos', to_jsonb(v_bloqueos));
  END IF;

  -- mig NNN (1596-b9): con la marca, la auditoría de productos no anota una fila por producto
  -- cuyo único cambio es el rubro; la anota esta función, en el rubro, con el antes de cada
  -- uno (agrupado, con sus ids). La marca se borra apenas termina el UPDATE.
  PERFORM set_config('app.rubro_masivo', 'eliminar_rubro', true);
  WITH cambiados AS (
    UPDATE productos p
       SET categoria = NULL, subcategoria_id = NULL
      FROM productos o
     WHERE o.id = p.id
       AND p.sucursal_id = v_sucursal
       AND (p.categoria_id = v_id OR upper(btrim(p.categoria)) = upper(v_nombre))
    RETURNING p.id, o.categoria, o.categoria_id, o.subcategoria_id
  )
  SELECT COALESCE(sum(g.n), 0), COALESCE(jsonb_agg(g.grupo ORDER BY g.grupo::text), '[]'::jsonb)
    INTO v_productos, v_antes
    FROM (SELECT count(*) AS n,
                 jsonb_build_object('categoria', c.categoria, 'categoria_id', c.categoria_id,
                                    'subcategoria_id', c.subcategoria_id,
                                    'ids', jsonb_agg(c.id ORDER BY c.id)) AS grupo
            FROM cambiados c
           GROUP BY c.categoria, c.categoria_id, c.subcategoria_id) g;
  PERFORM set_config('app.rubro_masivo', '', true);

  DELETE FROM cliente_descuentos_categoria d
   USING clientes c
   WHERE c.id = d.cliente_id AND c.sucursal_id = v_sucursal
     AND upper(btrim(d.categoria)) = upper(v_nombre);
  GET DIAGNOSTICS v_desc = ROW_COUNT;

  IF v_id IS NOT NULL THEN
    DELETE FROM categorias WHERE id = v_id AND sucursal_id = v_sucursal;
  END IF;

  -- La fila de auditoría del rubro (las columnas de audit_log_changes).
  INSERT INTO audit_logs (tabla, registro_id, accion, old_data, new_data, campos_modificados,
                          usuario_id, usuario_email, usuario_rol, sucursal_id)
  VALUES ('categorias', COALESCE(v_id::text, v_nombre), 'DELETE',
          jsonb_build_object('nombre', v_nombre, 'categoria_id', v_id, 'productos', v_antes,
                             'cantidad_productos', v_productos, 'subrubros', v_subrubros,
                             'descuentos', v_desc),
          NULL, NULL, v_uid,
          (SELECT u.email FROM auth.users u WHERE u.id = v_uid),
          (SELECT pf.rol FROM perfiles pf WHERE pf.id = v_uid AND COALESCE(pf.activo, true)),
          v_sucursal);

  RETURN jsonb_build_object('success', true, 'solo_ver', false, 'nombre', v_nombre,
    'productos', v_productos, 'subrubros', v_subrubros, 'descuentos', v_desc, 'metas', v_metas,
    'bloqueos', '[]'::jsonb);
END
$function$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, el definer, el search_path y los EXECUTE quedaron
-- como en el repo, y el índice y el trigger, como se crearon
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
  v_mal text := '';
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.audit_log_changes()',      'b7618c54079458ca77f85c176d5386e2', '{"search_path=public, pg_temp"}',
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.productos_codigo_unico()', 'c74701dda1cdcdcad67cfac0ca7d4da4', '{"search_path=public, pg_temp",plan_cache_mode=force_custom_plan}',
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.renombrar_rubro(uuid,text,text)',   'ea0171901d85ae741541504ed9080c0a', '{"search_path=public, pg_temp"}',
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.eliminar_rubro(uuid,text,boolean)', '2e0c0eb8ad9d8a9485da605958b2d641', '{"search_path=public, pg_temp"}',
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}')
  ) AS t(f, h, cfg, acl) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def, proconfig::text AS cfg INTO x
      FROM pg_proc WHERE oid = r.f::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl
       OR x.def IS DISTINCT FROM true OR x.cfg IS DISTINCT FROM r.cfg THEN
      v_mal := v_mal || format(E'\n  %s (md5 %s, acl %s, definer %s, config %s)', r.f, x.h, x.a, x.def, x.cfg);
    END IF;
  END LOOP;

  IF (SELECT pg_get_indexdef('public.productos_codigo_unico_por_sucursal'::regclass))
     IS DISTINCT FROM 'CREATE UNIQUE INDEX productos_codigo_unico_por_sucursal ON public.productos USING btree (sucursal_id, upper(btrim((codigo)::text))) WHERE (btrim((codigo)::text) <> ''''::text)' THEN
    v_mal := v_mal || E'\n  el índice productos_codigo_unico_por_sucursal';
  END IF;

  FOR r IN SELECT * FROM (VALUES
    ('audit_productos_update',
     'CREATE TRIGGER audit_productos_update AFTER UPDATE ON public.productos FOR EACH ROW WHEN (((NOT COALESCE(((new.stock < old.stock) AND (current_setting(''app.stock_origen''::text, true) = ANY (ARRAY[''pedido_creado''::text, ''pedido_creado_bot''::text, ''pedido_editado''::text])) AND (((to_jsonb(old.*) - ''stock''::text) - ''updated_at''::text) = ((to_jsonb(new.*) - ''stock''::text) - ''updated_at''::text))), false)) AND (NOT COALESCE(((current_setting(''app.rubro_masivo''::text, true) = ANY (ARRAY[''renombrar_rubro''::text, ''eliminar_rubro''::text])) AND ((to_jsonb(old.*) - ARRAY[''categoria''::text, ''categoria_id''::text, ''subcategoria_id''::text, ''updated_at''::text]) = (to_jsonb(new.*) - ARRAY[''categoria''::text, ''categoria_id''::text, ''subcategoria_id''::text, ''updated_at''::text]))), false)))) EXECUTE FUNCTION audit_log_changes()'),
    ('trg_productos_codigo_unico',
     'CREATE TRIGGER trg_productos_codigo_unico BEFORE INSERT ON public.productos FOR EACH ROW WHEN ((btrim((new.codigo)::text) <> ''''::text)) EXECUTE FUNCTION productos_codigo_unico()'),
    ('trg_productos_codigo_unico_upd',
     'CREATE TRIGGER trg_productos_codigo_unico_upd BEFORE UPDATE OF codigo, sucursal_id ON public.productos FOR EACH ROW WHEN (((btrim((new.codigo)::text) <> ''''::text) AND (((new.codigo)::text IS DISTINCT FROM (old.codigo)::text) OR (new.sucursal_id IS DISTINCT FROM old.sucursal_id)))) EXECUTE FUNCTION productos_codigo_unico()')
  ) AS t(tg, def) LOOP
    SELECT pg_get_triggerdef(t.oid) AS def INTO x FROM pg_trigger t
     WHERE t.tgrelid = 'public.productos'::regclass AND t.tgname = r.tg AND t.tgenabled = 'O';
    IF x.def IS DISTINCT FROM r.def THEN
      v_mal := v_mal || format(E'\n  el trigger %s: %s', r.tg, x.def);
    END IF;
  END LOOP;

  IF v_mal <> '' THEN
    RAISE EXCEPTION 'mig NNN · no quedaron como en el repo:%', v_mal;
  END IF;
END
$post$;

COMMIT;
