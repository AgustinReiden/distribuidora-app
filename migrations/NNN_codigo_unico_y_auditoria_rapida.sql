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
--   · El `WHEN` compara NEW con esas cuatro columnas puestas como en OLD, contra
--     OLD por imagen (`*=`): más barato que los dos `to_jsonb`, e igual de
--     estricto (otra diferencia, aunque sea de escala, se audita).
--   · `sync_producto_categoria_id` (que pasa a esta tarjeta) no busca el id del
--     rubro por cada producto cuando renombra `renombrar_rubro`: el texto nuevo
--     es el de la fila del rubro, único por sucursal, y el id viaja en las
--     marcas. Fuera de esa RPC hace exactamente lo de antes.
--   · EN TANDAS: aun sin auditoría por fila, un UPDATE de 30.000 productos
--     tarda más de 4 s (el UPDATE pelado, sin triggers, ya tarda 4 s en la
--     máquina de prueba cargada). Las dos RPC reciben `p_lote` (DEFAULT NULL,
--     se borra la firma vieja: un bundle viejo llama sin él y hace todo en una
--     llamada, como antes, y si se corta no queda nada a medias). Con p_lote,
--     cada llamada pasa hasta esa cantidad y dice cuántos faltan; el front repite
--     de a 5.000 mostrando el avance. El rubro queda coherente entre tandas: la
--     fila de renombrar cambia en la primera y los productos guardan su id; la de
--     eliminar se borra con la última. La fila de auditoría es una sola, «en_curso»
--     hasta la última tanda (cantidad acumulada, el antes de cada tanda y, en
--     `new_data.tandas`, quién, cuándo y cuántos), y con ella se retoma: repetir la
--     misma operación sigue donde quedó. NINGÚN RUBRO QUEDA TRABADO: otro cambio por
--     id sobre un rubro con un renombre a medias primero lo termina (una tanda por
--     llamada, «retomado», terminado = false) y después hace lo pedido; la vista
--     previa de eliminar lo cuenta en vez de rechazar; `rubros_a_medias()` los
--     lista para que la pantalla ofrezca «Terminar». Por el camino de texto, lo que
--     falta de un renombre a medias (los productos con el nombre viejo) no se
--     elimina ni se renombra a otra cosa (sólo se retoma al mismo destino), y un
--     rubro nuevo con ese nombre viejo se rechaza
--     (`trg_categorias_no_pisa_rubro_a_medias`). Dos admins a la vez se ordenan en la
--     fila del rubro (FOR UPDATE) y, por nombre, en un lock consultivo que toman
--     los caminos de texto y el comienzo de un renombre.
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
LOCK TABLE public.productos, public.categorias IN ACCESS EXCLUSIVE MODE NOWAIT;

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
    ('public.eliminar_rubro(uuid,text,boolean)',     '7179adade957b3b85f377273ed951820'),
    ('public.sync_producto_categoria_id()',          '08e272b3fcbf50a28aebc4403e3a1ee2')
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

  IF to_regprocedure('public.renombrar_rubro(uuid,text,text,integer)') IS NOT NULL
     OR to_regprocedure('public.eliminar_rubro(uuid,text,boolean,integer)') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · las RPC de rubros con p_lote ya existen';
  END IF;
  IF to_regprocedure('public.rubros_a_medias()') IS NOT NULL
     OR to_regprocedure('public.categorias_no_pisa_rubro_a_medias()') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · rubros_a_medias o categorias_no_pisa_rubro_a_medias ya existen';
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
  -- COALESCE: con un x-sucursal-id ajeno current_sucursal_id() da NULL, y la guarda sin él quedaba
  -- NULL y no cortaba (fallaba abierta, como en #1488).
  IF NOT COALESCE(auth.uid() IS NULL OR (es_admin() AND NEW.sucursal_id = current_sucursal_id()), false) THEN
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
                          AND jsonb_populate_record(NEW, jsonb_build_object('categoria', OLD.categoria,
                                                                            'categoria_id', OLD.categoria_id,
                                                                            'subcategoria_id', OLD.subcategoria_id,
                                                                            'updated_at', OLD.updated_at)) *= OLD), false))
  EXECUTE FUNCTION public.audit_log_changes();

COMMENT ON TRIGGER audit_productos_update ON public.productos IS
  'No audita la baja de stock por venta (ya está en stock_historico, D38) ni, con la marca app.rubro_masivo que ponen renombrar_rubro y eliminar_rubro, una fila cuyo único cambio es el rubro (categoria, categoria_id, subcategoria_id, updated_at): esas dos anotan una fila en el rubro (mig NNN, 1596-b9, decisión del dueño del 19/11). La comparación es NEW con esas cuatro columnas puestas como en OLD, contra OLD, por imagen (*=): cualquier otra diferencia, aunque sea de escala, se audita entera.';

-- La sincronización del id del rubro (1561-b7), con un atajo para renombrar un rubro: el texto
-- nuevo ya es el de la fila del rubro (único por sucursal), así que el id es el del rubro y no
-- hace falta buscarlo en cada producto. Fuera de renombrar_rubro hace exactamente lo de antes.
CREATE OR REPLACE FUNCTION public.sync_producto_categoria_id()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NEW.categoria IS NULL OR trim(NEW.categoria) = '' THEN
    NEW.categoria_id := NULL;
    RETURN NEW;
  END IF;

  -- mig NNN (1596-b9): renombrar_rubro ya le cambió el nombre a la fila del rubro (único por
  -- sucursal: categorias_sucursal_padre_nombre_norm_uk) y escribe ese mismo texto en sus
  -- productos; el id que daría la búsqueda de abajo es el del rubro, y lo deja en las marcas.
  -- Buscarlo por cada producto era un tercio del tiempo de renombrar un rubro grande.
  IF current_setting('app.rubro_masivo', true) = 'renombrar_rubro'
     AND NEW.categoria = current_setting('app.rubro_masivo_nombre', true)
     AND NEW.sucursal_id::text = current_setting('app.rubro_masivo_sucursal', true) THEN
    NEW.categoria_id := current_setting('app.rubro_masivo_id', true)::uuid;
    RETURN NEW;
  END IF;

  -- 1561-b7 (#1561): la comparacion del indice unico (categorias_sucursal_padre_nombre_norm_uk)
  -- y de las RPC de rubros, escrita para que lo use; hay a lo sumo uno. El ORDER BY
  -- deja el LIMIT determinista igual.
  SELECT c.id INTO NEW.categoria_id
  FROM categorias c
  WHERE c.sucursal_id = NEW.sucursal_id
    AND c.parent_id IS NULL
    AND COALESCE(c.parent_id, '00000000-0000-0000-0000-000000000000'::uuid) = '00000000-0000-0000-0000-000000000000'::uuid
    AND upper(btrim(c.nombre)) = upper(btrim(NEW.categoria))
  ORDER BY c.created_at, c.id
  LIMIT 1;

  RETURN NEW;
END;
$function$;

-- Las dos RPC de rubros: DEFINER (escriben la fila de auditoría del rubro) y en tandas. Cambia
-- la firma (suma p_lote con DEFAULT NULL): se borra la vieja para que no queden dos sobrecargas
-- (PGRST203). Un bundle viejo llama sin p_lote y hace todo en una llamada, como antes.
DROP FUNCTION public.renombrar_rubro(uuid, text, text);
DROP FUNCTION public.eliminar_rubro(uuid, text, boolean);

CREATE FUNCTION public.renombrar_rubro(p_categoria_id uuid, p_nombre_actual text, p_nombre_nuevo text,
                                       p_lote integer DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
 SET plan_cache_mode TO 'force_custom_plan'
AS $function$
DECLARE
  v_sucursal  bigint := current_sucursal_id();
  v_nuevo     text := btrim(COALESCE(p_nombre_nuevo, ''));
  v_actual    text;
  v_id        uuid := p_categoria_id;
  v_productos integer := 0;
  v_total     integer := 0;
  v_faltan    integer := 0;
  v_desc      integer := 0;
  v_huerfanos integer := 0;
  v_antes     jsonb;
  v_uid       uuid := auth.uid();
  v_audit     uuid;
  v_pend      record;
  v_lote      bigint[];
  v_pedido    text;
  v_retomo    boolean := false;
BEGIN
  -- mig NNN (1596-b9, decisión del dueño del 19/11): DEFINER, para escribir la fila de
  -- auditoría del rubro. Valida el rol y la sucursal activa como antes, y cada escritura va
  -- acotada a esa sucursal (la RLS ya no la mira).
  -- En tandas (p_lote): cada llamada renombra hasta p_lote productos y dice cuántos faltan; la
  -- fila del rubro se renombra en la primera, y la auditoría es UNA fila «en_curso» que se
  -- completa en cada tanda (con quién, cuándo y cuántos) y queda «terminado» con la última.
  -- Volver a llamar con el mismo nombre nuevo sigue donde quedó. Con otro nombre nuevo, primero
  -- se termina el renombre a medias, una tanda por llamada («retomado», terminado = false), y
  -- la llamada siguiente hace el cambio pedido: ningún rubro queda trabado.
  -- Sin p_lote hace todo de una vez, como antes (lo que llama un bundle viejo).
  -- plan_cache_mode: el plan guardado de la tanda se arma con lo que el planificador cree de
  -- productos; en una base nueva (estadísticas vacías) recorría la tabla por cada id de la
  -- tanda. Una llamada planifica unas pocas sentencias: replanificar cuesta nada.
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin puede renombrar un rubro' USING ERRCODE = '42501';
  END IF;
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No hay una sucursal activa: recargá la página e intentá de nuevo' USING ERRCODE = '22023';
  END IF;
  IF v_nuevo = '' THEN
    RAISE EXCEPTION 'El nombre nuevo no puede estar vacío' USING ERRCODE = '22023';
  END IF;
  IF p_lote IS NOT NULL AND (p_lote < 1 OR p_lote > 100000) THEN
    RAISE EXCEPTION 'La tanda va de 1 a 100.000 productos' USING ERRCODE = '22023';
  END IF;

  IF v_id IS NULL THEN
    -- Un rubro que sólo existe como texto de productos (#763). Si un renombre suyo quedó a
    -- medias, ya tiene fila (con el nombre nuevo): se sigue con ésa.
    v_actual := btrim(COALESCE(p_nombre_actual, ''));
    IF v_actual = '' THEN
      RAISE EXCEPTION 'Falta el rubro a renombrar' USING ERRCODE = '22023';
    END IF;
    -- Dos admins sobre el mismo nombre se ordenan acá (el mismo lock que eliminar_rubro y que el
    -- comienzo de un renombre por id).
    PERFORM pg_advisory_xact_lock(hashtextextended('rubro:' || v_sucursal || ':' || upper(v_actual), 0));
    -- ¿Este texto es lo que falta de un renombre a medias (los productos que todavía no pasaron
    -- conservan el nombre viejo), o un rubro de texto que se está eliminando?
    SELECT a.accion, a.registro_id, a.new_data->>'nombre' AS nuevo INTO v_pend
      FROM audit_logs a
     WHERE a.tabla = 'categorias' AND a.sucursal_id = v_sucursal
       AND a.new_data->>'estado' = 'en_curso'
       AND ((a.accion = 'UPDATE' AND upper(a.old_data->>'nombre') = upper(v_actual))
            OR (a.accion = 'DELETE' AND a.old_data->>'categoria_id' IS NULL AND upper(a.registro_id) = upper(v_actual)))
     ORDER BY a.created_at DESC
     LIMIT 1;
    IF FOUND THEN
      IF v_pend.accion = 'DELETE' THEN
        RAISE EXCEPTION 'El rubro «%» se está eliminando y quedó a medias: tocá «Terminar» en Categorías para terminar.', v_actual
          USING ERRCODE = '22023';
      END IF;
      IF v_pend.nuevo IS DISTINCT FROM v_nuevo THEN
        RAISE EXCEPTION '«%» es lo que falta del rubro «%», que quedó a medias de renombrar: tocá «Terminar» en Categorías y después cambialo.',
          v_actual, v_pend.nuevo USING ERRCODE = '22023';
      END IF;
      v_id := v_pend.registro_id::uuid;
    END IF;
  END IF;

  IF v_id IS NOT NULL THEN
    SELECT c.nombre INTO v_actual
      FROM categorias c
     WHERE c.id = v_id AND c.sucursal_id = v_sucursal AND c.parent_id IS NULL
       FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'El rubro no existe en esta sucursal: recargá la pantalla' USING ERRCODE = 'P0002';
    END IF;
    -- ¿Quedó a medias un cambio de este rubro? (la fila del rubro, tomada arriba, ordena a dos
    -- admins que lo toquen a la vez: el segundo espera y sigue donde dejó el primero)
    SELECT a.id, a.accion, a.old_data->>'nombre' AS viejo, a.new_data->>'nombre' AS nuevo INTO v_pend
      FROM audit_logs a
     WHERE a.tabla = 'categorias' AND a.registro_id = v_id::text AND a.sucursal_id = v_sucursal
       AND a.new_data->>'estado' = 'en_curso'
     ORDER BY a.created_at DESC
     LIMIT 1;
    IF FOUND THEN
      IF v_pend.accion <> 'UPDATE' THEN
        RAISE EXCEPTION 'El rubro «%» se está eliminando y quedó a medias: tocá «Terminar» en Categorías (o «Eliminar») para terminar.', v_actual
          USING ERRCODE = '22023';
      END IF;
      v_actual := v_pend.viejo;
      v_audit := v_pend.id;
      IF v_pend.nuevo IS DISTINCT FROM v_nuevo THEN
        -- Otro destino: primero se termina el renombre a medias, una tanda por llamada; cuando
        -- termina, la llamada siguiente hace el cambio pedido.
        v_pedido := v_nuevo;
        v_nuevo := v_pend.nuevo;
        v_retomo := true;
      END IF;
    ELSE
      -- Empieza un renombre: el mismo lock por nombre que los caminos de texto, para que nadie
      -- toque el texto viejo mientras tanto.
      PERFORM pg_advisory_xact_lock(hashtextextended('rubro:' || v_sucursal || ':' || upper(v_actual), 0));
    END IF;
  ELSIF EXISTS (SELECT 1 FROM categorias c
                 WHERE c.sucursal_id = v_sucursal AND c.parent_id IS NULL
                   AND upper(btrim(c.nombre)) = upper(v_actual)) THEN
    RAISE EXCEPTION 'El rubro «%» ya tiene fila: recargá la pantalla', v_actual USING ERRCODE = '22023';
  END IF;

  IF v_audit IS NULL THEN
    IF v_nuevo = v_actual THEN
      RETURN jsonb_build_object('success', true, 'id', v_id, 'nombre', v_nuevo,
                                'productos', 0, 'productos_total', 0, 'faltan', 0, 'terminado', true,
                                'descuentos', 0, 'descuentos_huerfanos', 0);
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

    -- La fila de auditoría del rubro (las columnas de audit_log_changes), «en_curso» hasta la
    -- última tanda.
    INSERT INTO audit_logs (tabla, registro_id, accion, old_data, new_data, campos_modificados,
                            usuario_id, usuario_email, usuario_rol, sucursal_id)
    VALUES ('categorias', v_id::text, 'UPDATE',
            jsonb_build_object('nombre', v_actual, 'productos', '[]'::jsonb),
            jsonb_build_object('nombre', v_nuevo, 'categoria_id', v_id, 'cantidad_productos', 0,
                               'estado', 'en_curso', 'tandas', '[]'::jsonb),
            ARRAY['nombre'], v_uid,
            (SELECT u.email FROM auth.users u WHERE u.id = v_uid),
            (SELECT pf.rol FROM perfiles pf WHERE pf.id = v_uid AND COALESCE(pf.activo, true)),
            v_sucursal)
    RETURNING id INTO v_audit;
  END IF;

  -- La tanda. Con la marca, la auditoría de productos no anota una fila por producto cuyo único
  -- cambio es el rubro, y la sincronización del id no lo busca (es el del rubro). Las marcas
  -- se borran apenas termina el UPDATE.
  PERFORM set_config('app.rubro_masivo', 'renombrar_rubro', true);
  PERFORM set_config('app.rubro_masivo_id', v_id::text, true);
  PERFORM set_config('app.rubro_masivo_nombre', v_nuevo, true);
  PERFORM set_config('app.rubro_masivo_sucursal', v_sucursal::text, true);
  -- Los ids de la tanda primero, tomados en orden (un IN con la subconsulta y el LIMIT como
  -- parámetro se planificaba como un SubPlan que se repetía por cada fila).
  SELECT COALESCE(array_agg(s.id ORDER BY s.id), '{}') INTO v_lote
    FROM (SELECT q.id
            FROM productos q
           WHERE q.sucursal_id = v_sucursal
             AND (q.categoria_id = v_id OR upper(btrim(q.categoria)) = upper(v_actual))
             AND q.categoria IS DISTINCT FROM v_nuevo
           ORDER BY q.id
           LIMIT p_lote
             FOR UPDATE) s;
  WITH cambiados AS (
    UPDATE productos p
       SET categoria = v_nuevo
      FROM unnest(v_lote) AS l(id)
      JOIN productos o ON o.id = l.id
     WHERE p.id = l.id
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
  PERFORM set_config('app.rubro_masivo_id', '', true);
  PERFORM set_config('app.rubro_masivo_nombre', '', true);
  PERFORM set_config('app.rubro_masivo_sucursal', '', true);

  SELECT count(*) INTO v_faltan
    FROM productos q
   WHERE q.sucursal_id = v_sucursal
     AND (q.categoria_id = v_id OR upper(btrim(q.categoria)) = upper(v_actual))
     AND q.categoria IS DISTINCT FROM v_nuevo;

  IF v_faltan = 0 THEN
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
  END IF;

  UPDATE audit_logs a
     SET old_data = jsonb_set(a.old_data, '{productos}', (a.old_data->'productos') || v_antes),
         new_data = a.new_data
                    || jsonb_build_object('cantidad_productos', (a.new_data->>'cantidad_productos')::int + v_productos,
                                          'estado', CASE WHEN v_faltan = 0 THEN 'terminado' ELSE 'en_curso' END,
                                          'tandas', COALESCE(a.new_data->'tandas', '[]'::jsonb) || jsonb_build_array(
                                            jsonb_build_object('usuario_id', v_uid,
                                                               'usuario_email', (SELECT u.email FROM auth.users u WHERE u.id = v_uid),
                                                               'at', now(), 'productos', v_productos)))
                    || CASE WHEN v_faltan = 0
                            THEN jsonb_build_object('descuentos', v_desc, 'descuentos_huerfanos', v_huerfanos)
                            ELSE '{}'::jsonb END
   WHERE a.id = v_audit
  RETURNING (a.new_data->>'cantidad_productos')::int INTO v_total;

  IF v_retomo THEN
    -- Se avanzó el renombre a medias; el cambio pedido viene en la llamada siguiente.
    RETURN jsonb_build_object('success', true, 'id', v_id, 'nombre', v_pedido,
                              'productos', v_productos, 'productos_total', v_total,
                              'faltan', v_faltan, 'terminado', false,
                              'retomado', jsonb_build_object('de', v_actual, 'a', v_nuevo, 'faltan', v_faltan),
                              'descuentos', v_desc, 'descuentos_huerfanos', v_huerfanos);
  END IF;
  RETURN jsonb_build_object('success', true, 'id', v_id, 'nombre', v_nuevo,
                            'productos', v_productos, 'productos_total', v_total,
                            'faltan', v_faltan, 'terminado', v_faltan = 0,
                            'descuentos', v_desc, 'descuentos_huerfanos', v_huerfanos);
END
$function$;

CREATE FUNCTION public.eliminar_rubro(p_categoria_id uuid, p_nombre text, p_solo_ver boolean DEFAULT false,
                                      p_lote integer DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
 SET plan_cache_mode TO 'force_custom_plan'
AS $function$
DECLARE
  v_sucursal   bigint := current_sucursal_id();
  v_id         uuid := p_categoria_id;
  v_nombre     text;
  v_clave      text;
  v_ids        uuid[];
  v_combos     text[];
  v_comisiones integer;
  v_productos  integer;
  v_total      integer := 0;
  v_faltan     integer := 0;
  v_subrubros  integer;
  v_desc       integer;
  v_metas      integer;
  v_bloqueos   text[] := '{}';
  v_antes      jsonb;
  v_uid        uuid := auth.uid();
  v_audit      uuid;
  v_pend       record;
  v_lote       bigint[];
  v_r          jsonb;
  v_falta_ren  integer;
BEGIN
  -- mig NNN (1596-b9, decisión del dueño del 19/11): DEFINER, para escribir la fila de
  -- auditoría del rubro. Valida el rol y la sucursal activa como antes, y cada escritura va
  -- acotada a esa sucursal (la RLS ya no la mira).
  -- En tandas (p_lote): cada llamada saca del rubro hasta p_lote productos y dice cuántos
  -- faltan; la fila del rubro y sus descuentos se borran con la última, y la auditoría es UNA
  -- fila DELETE «en_curso» que se completa en cada tanda (con quién, cuándo y cuántos) y queda
  -- «terminado» con la última. Volver a llamar sigue donde quedó. Si el rubro tiene un renombre
  -- a medias, primero se termina ése (una tanda por llamada, «retomado»). Sin p_lote, todo de
  -- una vez.
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin puede eliminar un rubro' USING ERRCODE = '42501';
  END IF;
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No hay una sucursal activa: recargá la página e intentá de nuevo' USING ERRCODE = '22023';
  END IF;
  IF p_lote IS NOT NULL AND (p_lote < 1 OR p_lote > 100000) THEN
    RAISE EXCEPTION 'La tanda va de 1 a 100.000 productos' USING ERRCODE = '22023';
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
    v_clave := v_id::text;
  ELSE
    v_nombre := btrim(COALESCE(p_nombre, ''));
    IF v_nombre = '' THEN
      RAISE EXCEPTION 'Falta el rubro a eliminar' USING ERRCODE = '22023';
    END IF;
    -- Sin fila que tomar: dos admins sobre el mismo nombre se ordenan acá (el mismo lock que
    -- renombrar_rubro).
    PERFORM pg_advisory_xact_lock(hashtextextended('rubro:' || v_sucursal || ':' || upper(v_nombre), 0));
    -- ¿Este texto es lo que falta de un renombre a medias? Eso no se elimina por acá: es el otro
    -- rubro, y se termina con «Terminar».
    SELECT a.new_data->>'nombre' AS nuevo INTO v_pend
      FROM audit_logs a
     WHERE a.tabla = 'categorias' AND a.accion = 'UPDATE' AND a.sucursal_id = v_sucursal
       AND a.new_data->>'estado' = 'en_curso'
       AND upper(a.old_data->>'nombre') = upper(v_nombre)
     ORDER BY a.created_at DESC
     LIMIT 1;
    IF FOUND THEN
      IF p_solo_ver THEN
        RETURN jsonb_build_object('success', true, 'solo_ver', true, 'nombre', v_nombre,
          'productos', 0, 'subrubros', 0, 'descuentos', 0, 'metas', 0, 'a_medias', true,
          'bloqueos', jsonb_build_array(format('es lo que falta del rubro «%s», que quedó a medias de renombrar: tocá «Terminar»', v_pend.nuevo)));
      END IF;
      RAISE EXCEPTION '«%» es lo que falta del rubro «%», que quedó a medias de renombrar: tocá «Terminar» en Categorías.',
        v_nombre, v_pend.nuevo USING ERRCODE = '22023';
    END IF;
    -- El texto «BEBIDAS» de un producto es del rubro «Bebidas» (el trigger le pone su id):
    -- borrarlo como texto suelto le sacaría los productos al rubro con fila.
    IF EXISTS (SELECT 1 FROM categorias c
                WHERE c.sucursal_id = v_sucursal AND c.parent_id IS NULL
                  AND upper(btrim(c.nombre)) = upper(v_nombre)) THEN
      RAISE EXCEPTION 'El rubro «%» tiene fila: eliminalo desde ahí, o recargá la pantalla', v_nombre USING ERRCODE = '22023';
    END IF;
    v_ids := '{}';
    v_clave := v_nombre;
  END IF;

  -- ¿Quedó a medias un cambio de este rubro?
  SELECT a.id, a.accion, a.old_data->>'nombre' AS viejo, a.new_data->>'nombre' AS nuevo INTO v_pend
    FROM audit_logs a
   WHERE a.tabla = 'categorias' AND a.registro_id = v_clave AND a.sucursal_id = v_sucursal
     AND a.new_data->>'estado' = 'en_curso'
   ORDER BY a.created_at DESC
   LIMIT 1;
  IF FOUND THEN
    IF v_pend.accion = 'UPDATE' THEN
      -- Un renombre a medias: primero se termina ése (una tanda por llamada), y la llamada
      -- siguiente elimina. La vista previa lo cuenta en vez de rechazar.
      IF p_solo_ver THEN
        SELECT count(*) INTO v_falta_ren
          FROM productos q
         WHERE q.sucursal_id = v_sucursal
           AND (q.categoria_id = v_id OR upper(btrim(q.categoria)) = upper(v_pend.viejo))
           AND q.categoria IS DISTINCT FROM v_pend.nuevo;
      ELSE
        v_r := public.renombrar_rubro(v_id, v_pend.viejo, v_pend.nuevo, p_lote);
        RETURN v_r || jsonb_build_object('solo_ver', false, 'nombre', v_nombre, 'terminado', false,
          'retomado', jsonb_build_object('de', v_pend.viejo, 'a', v_pend.nuevo, 'faltan', v_r->'faltan'));
      END IF;
    ELSE
      v_audit := v_pend.id;
    END IF;
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
      'bloqueos', to_jsonb(v_bloqueos), 'a_medias', v_audit IS NOT NULL OR v_falta_ren IS NOT NULL,
      'renombre_a_medias', CASE WHEN v_falta_ren IS NOT NULL
                                THEN jsonb_build_object('de', v_pend.viejo, 'a', v_pend.nuevo, 'faltan', v_falta_ren) END);
  END IF;

  IF v_audit IS NULL THEN
    -- La fila de auditoría del rubro (las columnas de audit_log_changes), «en_curso» hasta la
    -- última tanda.
    INSERT INTO audit_logs (tabla, registro_id, accion, old_data, new_data, campos_modificados,
                            usuario_id, usuario_email, usuario_rol, sucursal_id)
    VALUES ('categorias', v_clave, 'DELETE',
            jsonb_build_object('nombre', v_nombre, 'categoria_id', v_id, 'productos', '[]'::jsonb,
                               'cantidad_productos', 0, 'subrubros', v_subrubros),
            jsonb_build_object('estado', 'en_curso', 'cantidad_productos', 0, 'tandas', '[]'::jsonb),
            NULL, v_uid,
            (SELECT u.email FROM auth.users u WHERE u.id = v_uid),
            (SELECT pf.rol FROM perfiles pf WHERE pf.id = v_uid AND COALESCE(pf.activo, true)),
            v_sucursal)
    RETURNING id INTO v_audit;
  END IF;

  -- La tanda. Con la marca, la auditoría de productos no anota una fila por producto cuyo único
  -- cambio es el rubro. La marca se borra apenas termina el UPDATE.
  -- Los ids de la tanda primero, tomados en orden (ver renombrar_rubro).
  SELECT COALESCE(array_agg(s.id ORDER BY s.id), '{}') INTO v_lote
    FROM (SELECT q.id
            FROM productos q
           WHERE q.sucursal_id = v_sucursal
             AND (q.categoria_id = v_id OR upper(btrim(q.categoria)) = upper(v_nombre))
           ORDER BY q.id
           LIMIT p_lote
             FOR UPDATE) s;
  PERFORM set_config('app.rubro_masivo', 'eliminar_rubro', true);
  WITH cambiados AS (
    UPDATE productos p
       SET categoria = NULL, subcategoria_id = NULL
      FROM unnest(v_lote) AS l(id)
      JOIN productos o ON o.id = l.id
     WHERE p.id = l.id
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

  SELECT count(*) INTO v_faltan
    FROM productos q
   WHERE q.sucursal_id = v_sucursal
     AND (q.categoria_id = v_id OR upper(btrim(q.categoria)) = upper(v_nombre));

  v_desc := 0;
  IF v_faltan = 0 THEN
    DELETE FROM cliente_descuentos_categoria d
     USING clientes c
     WHERE c.id = d.cliente_id AND c.sucursal_id = v_sucursal
       AND upper(btrim(d.categoria)) = upper(v_nombre);
    GET DIAGNOSTICS v_desc = ROW_COUNT;

    IF v_id IS NOT NULL THEN
      DELETE FROM categorias WHERE id = v_id AND sucursal_id = v_sucursal;
    END IF;
  END IF;

  UPDATE audit_logs a
     SET old_data = jsonb_set(a.old_data, '{productos}', (a.old_data->'productos') || v_antes)
                    || jsonb_build_object('cantidad_productos', (a.old_data->>'cantidad_productos')::int + v_productos)
                    || CASE WHEN v_faltan = 0 THEN jsonb_build_object('descuentos', v_desc) ELSE '{}'::jsonb END,
         new_data = a.new_data
                    || jsonb_build_object('cantidad_productos', (a.old_data->>'cantidad_productos')::int + v_productos,
                                          'estado', CASE WHEN v_faltan = 0 THEN 'terminado' ELSE 'en_curso' END,
                                          'tandas', COALESCE(a.new_data->'tandas', '[]'::jsonb) || jsonb_build_array(
                                            jsonb_build_object('usuario_id', v_uid,
                                                               'usuario_email', (SELECT u.email FROM auth.users u WHERE u.id = v_uid),
                                                               'at', now(), 'productos', v_productos)))
   WHERE a.id = v_audit
  RETURNING (a.old_data->>'cantidad_productos')::int INTO v_total;

  RETURN jsonb_build_object('success', true, 'solo_ver', false, 'nombre', v_nombre,
    'productos', v_productos, 'productos_total', v_total, 'faltan', v_faltan, 'terminado', v_faltan = 0,
    'subrubros', v_subrubros, 'descuentos', v_desc, 'metas', v_metas, 'bloqueos', '[]'::jsonb);
END
$function$;

REVOKE ALL ON FUNCTION public.renombrar_rubro(uuid, text, text, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.eliminar_rubro(uuid, text, boolean, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.renombrar_rubro(uuid, text, text, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.eliminar_rubro(uuid, text, boolean, integer) TO authenticated, service_role;

-- Los cambios de rubro a medias, para que la pantalla ofrezca «Terminar» (1596-b9): ningún
-- rubro queda trabado. Sólo admin, de su sucursal activa.
CREATE FUNCTION public.rubros_a_medias()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_sucursal bigint := current_sucursal_id();
BEGIN
  -- mig NNN (1596-b9): un renombre o una eliminación de rubro que quedó «en_curso» (se cortó
  -- entre tandas). Lee audit_logs, que el front no lee: por eso es DEFINER y sólo de admin.
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin puede ver los cambios de rubro a medias' USING ERRCODE = '42501';
  END IF;
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No hay una sucursal activa: recargá la página e intentá de nuevo' USING ERRCODE = '22023';
  END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(x.fila ORDER BY x.desde)
      FROM (SELECT a.created_at AS desde,
                   jsonb_build_object(
                     'accion', CASE WHEN a.accion = 'UPDATE' THEN 'renombrar' ELSE 'eliminar' END,
                     'id', COALESCE(a.new_data->>'categoria_id', a.old_data->>'categoria_id'),
                     'nombre', a.old_data->>'nombre',
                     'nombre_nuevo', CASE WHEN a.accion = 'UPDATE' THEN a.new_data->>'nombre' END,
                     'hechos', (a.new_data->>'cantidad_productos')::int,
                     'faltan', (SELECT count(*)
                                  FROM productos q
                                 WHERE q.sucursal_id = v_sucursal
                                   AND (q.categoria_id = COALESCE(a.new_data->>'categoria_id', a.old_data->>'categoria_id')::uuid
                                        OR upper(btrim(q.categoria)) = upper(a.old_data->>'nombre'))
                                   AND (a.accion = 'DELETE' OR q.categoria IS DISTINCT FROM a.new_data->>'nombre')),
                     'desde', a.created_at) AS fila
              FROM audit_logs a
             WHERE a.tabla = 'categorias' AND a.sucursal_id = v_sucursal
               AND a.new_data->>'estado' = 'en_curso') x), '[]'::jsonb);
END
$function$;

REVOKE ALL ON FUNCTION public.rubros_a_medias() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rubros_a_medias() TO authenticated, service_role;

-- Un rubro nuevo (o un cambio de nombre por REST) con el nombre viejo de un renombre a medias
-- se rechaza: al retomar, el renombre se llevaría sus productos (H5 de la revisión).
CREATE FUNCTION public.categorias_no_pisa_rubro_a_medias()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_nuevo text;
BEGIN
  -- mig NNN (1596-b9): DEFINER para leer audit_logs. Corre antes que la RLS: sólo mira (y
  -- nombra) para quien pasa la policy de escritura de categorias (un admin en su sucursal
  -- activa) o el server; a cualquier otro le devuelve la fila y lo frena la RLS.
  IF NOT COALESCE(auth.uid() IS NULL OR (es_admin() AND NEW.sucursal_id = current_sucursal_id()), false) THEN
    RETURN NEW;
  END IF;
  SELECT a.new_data->>'nombre' INTO v_nuevo
    FROM audit_logs a
   WHERE a.tabla = 'categorias' AND a.accion = 'UPDATE' AND a.sucursal_id = NEW.sucursal_id
     AND a.new_data->>'estado' = 'en_curso'
     AND upper(a.old_data->>'nombre') = upper(btrim(NEW.nombre))
     AND a.registro_id IS DISTINCT FROM NEW.id::text
   LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION '«%» se está renombrando a «%» y quedó a medias: tocá «Terminar» en Categorías antes de usar ese nombre.',
      btrim(NEW.nombre), v_nuevo USING ERRCODE = '23505';
  END IF;
  RETURN NEW;
END
$function$;

REVOKE ALL ON FUNCTION public.categorias_no_pisa_rubro_a_medias() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.categorias_no_pisa_rubro_a_medias() TO service_role;

CREATE TRIGGER trg_categorias_no_pisa_rubro_a_medias
  BEFORE INSERT OR UPDATE OF nombre, parent_id ON public.categorias
  FOR EACH ROW
  WHEN (NEW.parent_id IS NULL)
  EXECUTE FUNCTION public.categorias_no_pisa_rubro_a_medias();


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
    ('public.productos_codigo_unico()', '2f5067b2fcb1c3586d51c6e057c91120', '{"search_path=public, pg_temp",plan_cache_mode=force_custom_plan}',
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.renombrar_rubro(uuid,text,text,integer)',   'd0855283a3a8f7876470f66ae653f0da', '{"search_path=public, pg_temp",plan_cache_mode=force_custom_plan}',
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.eliminar_rubro(uuid,text,boolean,integer)', '5b2db000767a9dc17f54c10a6f003e3e', '{"search_path=public, pg_temp",plan_cache_mode=force_custom_plan}',
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.sync_producto_categoria_id()',              '092100d0fdb42ce04f3a4e8cde3c7788', '{"search_path=public, pg_temp"}',
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.rubros_a_medias()',                         '4ec92648d2449b0191ac365885065629', '{"search_path=public, pg_temp"}',
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.categorias_no_pisa_rubro_a_medias()',       '3d4521b514f1966bbd8018bbabc5e2c9', '{"search_path=public, pg_temp"}',
     '{postgres=X/postgres,service_role=X/postgres}')
  ) AS t(f, h, cfg, acl) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def, proconfig::text AS cfg INTO x
      FROM pg_proc WHERE oid = to_regprocedure(r.f);
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl
       OR x.def IS DISTINCT FROM (r.f <> 'public.sync_producto_categoria_id()') OR x.cfg IS DISTINCT FROM r.cfg THEN
      v_mal := v_mal || format(E'\n  %s (md5 %s, acl %s, definer %s, config %s)', r.f, x.h, x.a, x.def, x.cfg);
    END IF;
  END LOOP;

  IF (SELECT pg_get_indexdef('public.productos_codigo_unico_por_sucursal'::regclass))
     IS DISTINCT FROM 'CREATE UNIQUE INDEX productos_codigo_unico_por_sucursal ON public.productos USING btree (sucursal_id, upper(btrim((codigo)::text))) WHERE (btrim((codigo)::text) <> ''''::text)' THEN
    v_mal := v_mal || E'\n  el índice productos_codigo_unico_por_sucursal';
  END IF;

  FOR r IN SELECT * FROM (VALUES
    ('audit_productos_update',
     'CREATE TRIGGER audit_productos_update AFTER UPDATE ON public.productos FOR EACH ROW WHEN (((NOT COALESCE(((new.stock < old.stock) AND (current_setting(''app.stock_origen''::text, true) = ANY (ARRAY[''pedido_creado''::text, ''pedido_creado_bot''::text, ''pedido_editado''::text])) AND (((to_jsonb(old.*) - ''stock''::text) - ''updated_at''::text) = ((to_jsonb(new.*) - ''stock''::text) - ''updated_at''::text))), false)) AND (NOT COALESCE(((current_setting(''app.rubro_masivo''::text, true) = ANY (ARRAY[''renombrar_rubro''::text, ''eliminar_rubro''::text])) AND (jsonb_populate_record(new.*, jsonb_build_object(''categoria'', old.categoria, ''categoria_id'', old.categoria_id, ''subcategoria_id'', old.subcategoria_id, ''updated_at'', old.updated_at)) *= old.*)), false)))) EXECUTE FUNCTION audit_log_changes()'),
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

  IF (SELECT pg_get_triggerdef(t.oid) FROM pg_trigger t
       WHERE t.tgrelid = 'public.categorias'::regclass AND t.tgname = 'trg_categorias_no_pisa_rubro_a_medias' AND t.tgenabled = 'O')
     IS DISTINCT FROM 'CREATE TRIGGER trg_categorias_no_pisa_rubro_a_medias BEFORE INSERT OR UPDATE OF nombre, parent_id ON public.categorias FOR EACH ROW WHEN ((new.parent_id IS NULL)) EXECUTE FUNCTION categorias_no_pisa_rubro_a_medias()' THEN
    v_mal := v_mal || format(E'\n  el trigger trg_categorias_no_pisa_rubro_a_medias: %s',
      (SELECT pg_get_triggerdef(t.oid) FROM pg_trigger t
        WHERE t.tgrelid = 'public.categorias'::regclass AND t.tgname = 'trg_categorias_no_pisa_rubro_a_medias'));
  END IF;

  IF to_regprocedure('public.renombrar_rubro(uuid,text,text)') IS NOT NULL
     OR to_regprocedure('public.eliminar_rubro(uuid,text,boolean)') IS NOT NULL THEN
    v_mal := v_mal || E'
  quedó una firma vieja de las RPC de rubros (PGRST203)';
  END IF;

  IF v_mal <> '' THEN
    RAISE EXCEPTION 'mig NNN · no quedaron como en el repo:%', v_mal;
  END IF;
END
$post$;

COMMIT;
