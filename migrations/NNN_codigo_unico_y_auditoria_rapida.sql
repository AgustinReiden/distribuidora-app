-- =========================================================================
-- NNN · EL CÓDIGO DE UN PRODUCTO ES ÚNICO POR SUCURSAL, Y LA AUDITORÍA POR
--       FILA DEJA DE CONSULTAR EL CATÁLOGO EN CADA FILA
--       (plan #1603, ola 2, tanda 5, tarjeta C4a: 1561-b1 de #1561 y
--        1596-b9 de #1596)
--
-- Un índice único nuevo en `productos`, una función de trigger nueva con su
-- trigger, y `audit_log_changes()` reescrita entera con premisa de md5 sobre
-- el cuerpo vivo (ledger en la 530). No cambia firmas. No corrige filas. No
-- toca ningún trigger existente.
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
--   · `trg_productos_codigo_unico` (BEFORE INSERT OR UPDATE OF codigo,
--     sucursal_id): da el mensaje que se entiende, con el producto que ya lo
--     tiene y si está desactivado, por cualquier camino (el alta y la edición
--     de la ficha, el alta rápida desde una compra, el envío entre sucursales
--     que crea el producto en el destino). Busca por el índice (es DEFINER,
--     sin ORDER BY y planifica cada vez: si no, un alta de 15.000 productos de
--     una vez en una base nueva es cuadrática; medido, 2 min 30 s contra 3 s),
--     y nombra el producto sólo si quien
--     escribe lo ve: el server, o un usuario en su sucursal activa. Al que
--     escribe en una sucursal ajena lo frena la RLS (42501) sin mostrarle nada
--     (`check-mensajes-trigger`, #1559).
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
-- Lo que queda del tiempo es el INSERT en `audit_logs` (ocho índices y dos
-- FK), que es la evidencia y no se toca.
-- El camino 2 del PR #1631 (una fila de resumen por rubro) no se hizo: deja de
-- anotar el antes y el después de cada producto, y `audit_logs` es evidencia.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

-- La tabla que la migración altera (el índice pide SHARE y el trigger SHARE ROW
-- EXCLUSIVE), tomada de una vez y antes de leerla: si alguien la tiene tomada
-- falla al instante y se reintenta, sin dejar a nadie esperando. Deja leer
-- productos mientras tanto; frena las escrituras unos milisegundos.
LOCK TABLE public.productos IN SHARE ROW EXCLUSIVE MODE NOWAIT;

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
  v text;
BEGIN
  SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = 'public.audit_log_changes()'::regprocedure;
  IF v IS DISTINCT FROM 'd0dcffb22ac9e2e91eda9a0048e6b932' THEN
    RAISE EXCEPTION 'mig NNN · audit_log_changes() cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', v;
  END IF;

  IF to_regprocedure('public.productos_codigo_unico()') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · public.productos_codigo_unico() ya existe';
  END IF;
  IF to_regclass('public.productos_codigo_unico_por_sucursal') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · el índice productos_codigo_unico_por_sucursal ya existe';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_trigger
              WHERE tgrelid = 'public.productos'::regclass AND tgname = 'trg_productos_codigo_unico') THEN
    RAISE EXCEPTION 'mig NNN · el trigger trg_productos_codigo_unico ya existe';
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
  'mig NNN (1561-b1, decisión del dueño D31): el código de un producto es único por sucursal, sin mirar mayúsculas ni los espacios de los bordes (como los rubros). Sin código (NULL, vacío o espacios) no cuenta. El mensaje lo da trg_productos_codigo_unico; esto cubre la carrera.';

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
  -- producto que ya lo tiene. Un vacío no llega acá (el WHEN del trigger).
  IF TG_OP = 'UPDATE'
     AND NEW.codigo IS NOT DISTINCT FROM OLD.codigo
     AND NEW.sucursal_id IS NOT DISTINCT FROM OLD.sucursal_id THEN
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

  -- El mensaje nombra el producto sólo si quien escribe lo ve: el server (sin usuario) o
  -- un usuario en su sucursal activa (la regla de mt_productos_select). Si no, sigue: a un
  -- usuario que escribe en una sucursal ajena lo frena la RLS (42501), y a lo que pase de
  -- largo, el índice; nadie sondea por acá los productos de otra sucursal (#1559).
  IF FOUND AND (auth.uid() IS NULL OR NEW.sucursal_id = current_sucursal_id()) THEN
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

CREATE TRIGGER trg_productos_codigo_unico
  BEFORE INSERT OR UPDATE OF codigo, sucursal_id ON public.productos
  FOR EACH ROW
  WHEN (btrim(NEW.codigo) <> '')
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
    ('public.audit_log_changes()',      'b7618c54079458ca77f85c176d5386e2', '{"search_path=public, pg_temp"}'),
    ('public.productos_codigo_unico()', '6c001f72d53dfc275d9bfa8b776a1bbd', '{"search_path=public, pg_temp",plan_cache_mode=force_custom_plan}')
  ) AS t(f, h, cfg) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def, proconfig::text AS cfg INTO x
      FROM pg_proc WHERE oid = r.f::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM '{postgres=X/postgres,service_role=X/postgres}'
       OR x.def IS DISTINCT FROM true OR x.cfg IS DISTINCT FROM r.cfg THEN
      v_mal := v_mal || format(E'\n  %s (md5 %s, acl %s, definer %s, config %s)', r.f, x.h, x.a, x.def, x.cfg);
    END IF;
  END LOOP;

  IF (SELECT pg_get_indexdef('public.productos_codigo_unico_por_sucursal'::regclass))
     IS DISTINCT FROM 'CREATE UNIQUE INDEX productos_codigo_unico_por_sucursal ON public.productos USING btree (sucursal_id, upper(btrim((codigo)::text))) WHERE (btrim((codigo)::text) <> ''''::text)' THEN
    v_mal := v_mal || E'\n  el índice productos_codigo_unico_por_sucursal';
  END IF;

  IF (SELECT pg_get_triggerdef(t.oid) FROM pg_trigger t
       WHERE t.tgrelid = 'public.productos'::regclass AND t.tgname = 'trg_productos_codigo_unico' AND t.tgenabled = 'O')
     IS DISTINCT FROM 'CREATE TRIGGER trg_productos_codigo_unico BEFORE INSERT OR UPDATE OF codigo, sucursal_id ON public.productos FOR EACH ROW WHEN ((btrim((new.codigo)::text) <> ''''::text)) EXECUTE FUNCTION productos_codigo_unico()' THEN
    v_mal := v_mal || E'\n  el trigger trg_productos_codigo_unico';
  END IF;

  IF v_mal <> '' THEN
    RAISE EXCEPTION 'mig NNN · no quedaron como en el repo:%', v_mal;
  END IF;
END
$post$;

COMMIT;
