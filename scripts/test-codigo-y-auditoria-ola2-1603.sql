-- Ensayo de la migración «código único por sucursal y auditoría rápida» (tarjeta C4a de la
-- tanda 5 de la ola 2 del plan #1603: 1561-b1 de #1561 y 1596-b9 de #1596).
--
-- Código único por sucursal (1561-b1, decisión del dueño D31), sin mirar mayúsculas ni
-- los espacios de los bordes:
--   C1 · [F] el alta (REST, admin) con el código de otro producto en otra caja y con
--        espacios choca (23505) con el mensaje que nombra el producto; no queda nada.
--   C2 · [F] la edición (REST, admin) que le pone a un producto el código de otro, igual.
--   C3 · [R] el mismo código en otra sucursal entra.
--   C4 · [R] sin código (NULL, vacío o espacios), cualquier cantidad en la misma sucursal.
--   C5 · [R] el propio producto cambia la caja o los bordes de su código, o cualquier otro
--        dato, sin chocar consigo mismo.
--   C6 · [F] contra un producto desactivado, el mensaje dice «(desactivado)».
--   C7 · [F] el envío entre sucursales que crea el producto en el destino choca con el
--        código de un producto del destino, con el mensaje (y no se acepta nada).
--   C8 · [F] la carrera: sin el trigger del mensaje, el índice único frena el repetido
--        (23505 con el nombre del índice).
--   C9 · [F] el server (postgres, sin usuario) tampoco lo puede repetir.
--   C10 · [R] el mensaje no muestra un producto de una sucursal que quien escribe no ve:
--        un admin de la sucursal 1 que escribe en la 2 recibe el 42501 de la RLS.
--   C11 · [R] el depósito, que no lee productos, recibe el 42501 sin el producto (no puede
--        sondear el catálogo código por código; H1 de la revisión).
--   C12 · [R] el preventista y el encargado, que no dan de alta productos, reciben el 42501,
--        no «ya existe… usá ese producto»; tampoco al editar.
--   C13 · [R] un encargado de otra sucursal, igual.  C14 · [R] un desactivado, igual.
--   C15 · [F] el encargado que acepta un envío que crea el producto choca con el índice (la
--        RPC lo devuelve en `error` y el front lo traduce), sin el nombre, y no se crea nada.
-- Los caminos legítimos nombran el producto: el admin en la ficha (C1, C2, C6; el alta rápida
-- de una compra es la misma escritura), el admin que acepta un envío (C7) y el server (C9).
-- La auditoría por fila (1596-b9): lo que anota `audit_log_changes()` es IGUAL, fila por
-- fila, a lo que anotaba el cuerpo de antes (`pg_temp.ref_audit` es ese cuerpo, copiado
-- tal cual sobre el antes y el después de cada fila):
--   A1 · [R] un UPDATE suelto como authenticated (admin, REST).
--   A2 · [R] un UPDATE masivo como authenticated (REST, 30 productos, también el rubro).
-- Renombrar o eliminar un rubro (1596-b9, decisión del dueño del 19/11): una fila en el rubro.
--   R1 · [F] renombrar un rubro de 30 productos deja UNA fila (categorias, UPDATE, nombre
--        viejo → nuevo, 30 productos, el antes de cada uno agrupado con sus ids), ninguna
--        de productos.
--   R2 · [F] eliminarlo deja UNA fila DELETE con los ids y su subrubro, ninguna de productos.
--   R3 · [R] cambiarle el rubro a un producto desde la ficha deja su fila de siempre, también
--        después de renombrar un rubro en la misma transacción (la marca no sobrevive).
--   R4 · [R] con la marca puesta a mano, un UPDATE de rubro y precio se audita entero.
--   R5 · [R] con la marca puesta a mano, un UPDATE de otra columna se audita entero.
--   R6 · [F] renombrar en tandas de 12: la primera deja el rubro renombrado, 12 productos y UNA
--        fila «en_curso»; otro nombre o eliminarlo se rechazan mientras está a medias; repetir
--        con el mismo nombre sigue donde quedó y la fila termina con los 30 y sus ids.
--   R7 · [F] eliminar en tandas de 20: el rubro sigue hasta la última («a medias» en la vista
--        previa) y queda una sola fila DELETE con los 30.
--   R8 · [R] fuera de las dos RPC la sincronización del id del rubro hace lo de siempre (otra
--        caja y bordes, otro rubro, uno que no existe), también con una marca puesta a mano.
--   A3 · [R] como service_role (sin usuario): productos y perfiles (sin sucursal_id).
--   A4 · [R] por una RPC definer (actualizar_precios_masivo) de un admin.
--   A5 · [R] con el token de un usuario desactivado: productos y perfiles.
--   A6 · [R] sin auth.uid(): INSERT, UPDATE y DELETE de un producto, y perfiles.
--   A7 · [R] un UPDATE que no cambia nada no anota nada.
-- El tiempo (1596-b9) no tiene caso: se mide aparte (15.000 productos, ver el PR).
--   K1 · los EXECUTE de las funciones son los de siempre (trigger: nadie más que el server).
--
-- [F] falla sin la migración y pasa con ella; [R] pasa antes y después.
-- Fixtures: un admin activo de la sucursal 1 (la semilla) y las sucursales 1 y 2 activas.
-- Todo lo demás nace en el ensayo. Un único DO que termina SIEMPRE en una excepción: no
-- deja nada.
--   'ENSAYO OK …'    -> todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' -> lista de lo que no se cumplió.
--
--   psql "$DATABASE_URL" -1 -f scripts/test-codigo-y-auditoria-ola2-1603.sql

-- El cuerpo de audit_log_changes() de antes de esta migración (la 530), sobre el antes y
-- el después de la fila en JSON: la fila que tendría que anotar, o NULL si no anota nada.
CREATE OR REPLACE FUNCTION pg_temp.ref_audit(p_tabla text, p_op text, p_old jsonb, p_new jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_old_data JSONB; v_new_data JSONB; v_campos_modificados TEXT[];
  v_usuario_id UUID; v_usuario_email TEXT; v_usuario_rol TEXT;
  v_registro_id TEXT; v_key TEXT;
  v_old_changed JSONB; v_new_changed JSONB;
  v_sucursal_id BIGINT;
  v_has_sucursal_col BOOLEAN;
BEGIN
  v_usuario_id := auth.uid();
  IF v_usuario_id IS NOT NULL THEN
    SELECT email INTO v_usuario_email FROM auth.users WHERE id = v_usuario_id;
    SELECT rol INTO v_usuario_rol FROM public.perfiles WHERE id = v_usuario_id;
  END IF;
  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = p_tabla AND column_name = 'sucursal_id'
  ) INTO v_has_sucursal_col;

  IF p_op = 'DELETE' THEN
    v_registro_id := p_old->>'id';
    v_old_data := p_old;
    v_new_data := NULL;
    v_sucursal_id := COALESCE((p_old->>'sucursal_id')::BIGINT, current_sucursal_id());
  ELSIF p_op = 'INSERT' THEN
    v_registro_id := p_new->>'id';
    v_old_data := NULL;
    v_new_data := p_new;
    v_sucursal_id := COALESCE((p_new->>'sucursal_id')::BIGINT, current_sucursal_id());
  ELSE
    v_registro_id := p_new->>'id';
    v_old_data := p_old;
    v_new_data := p_new;
    v_sucursal_id := COALESCE((p_new->>'sucursal_id')::BIGINT, (p_old->>'sucursal_id')::BIGINT, current_sucursal_id());
    v_campos_modificados := ARRAY[]::TEXT[];
    v_old_changed := '{}'::JSONB;
    v_new_changed := '{}'::JSONB;
    FOR v_key IN SELECT jsonb_object_keys(v_new_data) LOOP
      IF v_old_data->v_key IS DISTINCT FROM v_new_data->v_key THEN
        v_campos_modificados := array_append(v_campos_modificados, v_key);
        v_old_changed := v_old_changed || jsonb_build_object(v_key, v_old_data->v_key);
        v_new_changed := v_new_changed || jsonb_build_object(v_key, v_new_data->v_key);
      END IF;
    END LOOP;
    IF array_length(v_campos_modificados, 1) IS NULL OR array_length(v_campos_modificados, 1) = 0 THEN
      RETURN NULL;
    END IF;
    v_old_data := v_old_changed;
    v_new_data := v_new_changed;
  END IF;
  IF v_has_sucursal_col AND v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'audit_log_changes: cannot determine sucursal_id for tenant-scoped table %', p_tabla;
  END IF;
  RETURN jsonb_build_object('tabla', p_tabla, 'registro_id', v_registro_id, 'accion', p_op,
    'old_data', v_old_data, 'new_data', v_new_data, 'campos_modificados', to_jsonb(v_campos_modificados),
    'usuario_id', v_usuario_id, 'usuario_email', v_usuario_email, 'usuario_rol', v_usuario_rol,
    'sucursal_id', v_sucursal_id);
END
$fn$;

-- Las filas de audit_logs que no estaban en la foto p_antes, como las arma ref_audit.
CREATE OR REPLACE FUNCTION pg_temp.audit_nuevas(p_antes uuid[])
RETURNS jsonb[] LANGUAGE sql AS $fn$
  SELECT COALESCE(array_agg(x ORDER BY x::text), '{}')
    FROM (SELECT jsonb_build_object('tabla', a.tabla, 'registro_id', a.registro_id, 'accion', a.accion,
                   'old_data', a.old_data, 'new_data', a.new_data, 'campos_modificados', to_jsonb(a.campos_modificados),
                   'usuario_id', a.usuario_id, 'usuario_email', a.usuario_email, 'usuario_rol', a.usuario_rol,
                   'sucursal_id', a.sucursal_id) AS x
            FROM public.audit_logs a
           WHERE a.id NOT IN (SELECT unnest(p_antes))) s;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.audit_foto()
RETURNS uuid[] LANGUAGE sql AS $fn$
  SELECT COALESCE(array_agg(id), '{}') FROM public.audit_logs;
$fn$;

-- Lo que tendría que haber anotado un UPDATE de esas filas: pares (antes, después) por id.
CREATE OR REPLACE FUNCTION pg_temp.esperado(p_tabla text, p_op text, p_antes jsonb[], p_despues jsonb[])
RETURNS jsonb[] LANGUAGE sql AS $fn$
  SELECT COALESCE(array_agg(e ORDER BY e::text) FILTER (WHERE e IS NOT NULL), '{}')
    FROM (SELECT pg_temp.ref_audit(p_tabla, p_op, a.v, d.v) AS e
            FROM unnest(p_antes) AS a(v)
            FULL JOIN unnest(p_despues) AS d(v) ON d.v->>'id' = a.v->>'id') s;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.filas(p_tabla text, p_ids text[])
RETURNS jsonb[] LANGUAGE plpgsql AS $fn$
DECLARE r jsonb[];
BEGIN
  EXECUTE format('SELECT COALESCE(array_agg(to_jsonb(t) ORDER BY t.id::text), ''{}'') FROM public.%I t WHERE t.id::text = ANY ($1)', p_tabla)
    INTO r USING p_ids;
  RETURN r;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.u(p_rol text, p_suc bigint) RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE v uuid := gen_random_uuid();
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'c4a-' || v || '@ensayo.invalid',
          jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), jsonb_build_object('nombre', 'C4a ' || p_rol), now(), now());
  RETURN v;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.como(p_uid uuid, p_suc bigint, p_rol text DEFAULT 'authenticated') RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('request.jwt.claims',
                     CASE WHEN p_uid IS NULL AND p_rol = 'authenticated' THEN ''
                          WHEN p_uid IS NULL THEN json_build_object('role', p_rol)::text
                          ELSE json_build_object('sub', p_uid, 'role', p_rol)::text END, true);
  PERFORM set_config('request.jwt.claim.sub', COALESCE(p_uid::text, ''), true);
  PERFORM set_config('request.headers',
                     CASE WHEN p_suc IS NULL THEN '' ELSE json_build_object('x-sucursal-id', p_suc::text)::text END, true);
END
$fn$;

-- Corre p_sql como p_uid con el rol de base p_rol (authenticated o service_role), parado en
-- p_suc, y devuelve 'PASA <valor>' o 'SQLSTATE mensaje'. Lo que escribió queda.
CREATE OR REPLACE FUNCTION pg_temp.intenta(p_uid uuid, p_suc bigint, p_sql text, p_rol text DEFAULT 'authenticated')
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE r text; x text;
BEGIN
  PERFORM pg_temp.como(p_uid, p_suc, p_rol);
  EXECUTE format('SET LOCAL ROLE %I', p_rol);
  BEGIN
    EXECUTE p_sql INTO x;
    r := 'PASA ' || COALESCE(x, '');
  EXCEPTION WHEN OTHERS THEN
    r := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  RETURN r;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.prod(p_suc bigint, p_nombre text, p_codigo text, p_activo boolean DEFAULT true,
                                        p_categoria text DEFAULT NULL)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, precio_sin_iva, stock, sucursal_id, codigo, activo, categoria)
  VALUES ('ZZ C4a ' || p_nombre, 1210, 1000, 0, p_suc, p_codigo, p_activo, p_categoria)
  RETURNING id;
$fn$;

DO $ensayo$
DECLARE
  v_adm    uuid;
  v_adm1   uuid;
  v_des    uuid;
  v_otro   uuid;
  v_t      text;
  v_a      bigint;
  v_b      bigint;
  v_ids    text[];
  v_foto   uuid[];
  v_antes  jsonb[];
  v_desp   jsonb[];
  v_esp    jsonb[];
  v_real   jsonb[];
  v_j      jsonb;
  v_n      int;
  v_fallas text[] := '{}';
BEGIN
 BEGIN
  SET LOCAL lock_timeout = '5s';

  SELECT us.usuario_id INTO v_adm
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   WHERE us.sucursal_id = 1
   ORDER BY us.usuario_id
   LIMIT 1;
  IF v_adm IS NULL OR NOT EXISTS (SELECT 1 FROM sucursales WHERE id = 2 AND activa) THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin un admin activo de la sucursal 1, o sin la sucursal 2 activa';
  END IF;
  INSERT INTO usuario_sucursales (usuario_id, sucursal_id) VALUES (v_adm, 2) ON CONFLICT DO NOTHING;
  v_adm1 := pg_temp.u('admin', 1);
  v_otro := pg_temp.u('preventista', 1);
  v_des  := pg_temp.u('encargado', 1);
  -- La copia local tiene un auth.users mínimo, sin la columna que escribe perfiles_sync_acceso_auth
  -- al desactivar: ahí ese trigger se apaga para este UPDATE (el token del desactivado sigue vivo
  -- igual, que es lo que se prueba). Se deshace con el resto del ensayo.
  IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'auth.users'::regclass AND attname = 'banned_until') THEN
    ALTER TABLE public.perfiles DISABLE TRIGGER trg_perfiles_sync_acceso_auth;
    UPDATE perfiles SET activo = false WHERE id = v_des;
    ALTER TABLE public.perfiles ENABLE TRIGGER trg_perfiles_sync_acceso_auth;
  ELSE
    UPDATE perfiles SET activo = false WHERE id = v_des;
  END IF;

  -- ===================================================================== C1 ==
  v_a := pg_temp.prod(1, 'C1 existente', ' ABC-1 ');
  v_t := pg_temp.intenta(v_adm, 1, $q$INSERT INTO public.productos (nombre, precio, sucursal_id, codigo)
                                       VALUES ('ZZ C4a C1 nuevo', 100, 1, 'abc-1') RETURNING id::text$q$);
  IF v_t NOT LIKE '23505 Ya existe un producto con el código «abc-1» en esta sucursal: «ZZ C4a C1 existente»%' THEN
    v_fallas := v_fallas || ('C1 · el alta con el código de otro (otra caja, con espacios) tenía que chocar con el mensaje: ' || v_t);
  END IF;
  IF EXISTS (SELECT 1 FROM productos WHERE nombre = 'ZZ C4a C1 nuevo') THEN
    v_fallas := v_fallas || 'C1 · quedó el producto repetido'::text;
  END IF;

  -- ===================================================================== C2 ==
  v_a := pg_temp.prod(1, 'C2 dueño', 'C2-otro');
  v_b := pg_temp.prod(1, 'C2 editado', 'C2-propio');
  v_t := pg_temp.intenta(v_adm, 1, format($q$UPDATE public.productos SET codigo = ' c2-OTRO' WHERE id = %s RETURNING codigo$q$, v_b));
  IF v_t NOT LIKE '23505 Ya existe un producto con el código «c2-OTRO» en esta sucursal: «ZZ C4a C2 dueño»%' THEN
    v_fallas := v_fallas || ('C2 · la edición con el código de otro tenía que chocar con el mensaje: ' || v_t);
  END IF;
  IF (SELECT codigo FROM productos WHERE id = v_b) IS DISTINCT FROM 'C2-propio' THEN
    v_fallas := v_fallas || 'C2 · el producto editado quedó con el código del otro'::text;
  END IF;

  -- ===================================================================== C3 ==
  PERFORM pg_temp.prod(2, 'C3 en la 2', 'C3-X');
  v_t := pg_temp.intenta(v_adm, 1, $q$INSERT INTO public.productos (nombre, precio, sucursal_id, codigo)
                                       VALUES ('ZZ C4a C3 en la 1', 100, 1, 'c3-x') RETURNING id::text$q$);
  IF v_t NOT LIKE 'PASA %' THEN
    v_fallas := v_fallas || ('C3 · el mismo código en otra sucursal tenía que entrar: ' || v_t);
  END IF;

  -- ===================================================================== C4 ==
  v_t := pg_temp.intenta(v_adm, 1, $q$WITH x AS (INSERT INTO public.productos (nombre, precio, sucursal_id, codigo)
                                       VALUES ('ZZ C4a C4 a', 100, 1, NULL), ('ZZ C4a C4 b', 100, 1, NULL),
                                              ('ZZ C4a C4 c', 100, 1, ''), ('ZZ C4a C4 d', 100, 1, ''),
                                              ('ZZ C4a C4 e', 100, 1, '   '), ('ZZ C4a C4 f', 100, 1, ' ')
                                       RETURNING id) SELECT count(*)::text FROM x$q$);
  IF v_t IS DISTINCT FROM 'PASA 6' THEN
    v_fallas := v_fallas || ('C4 · los productos sin código tenían que entrar todos: ' || v_t);
  END IF;

  -- ===================================================================== C5 ==
  v_a := pg_temp.prod(1, 'C5 propio', 'abc-5');
  v_t := pg_temp.intenta(v_adm, 1, format($q$UPDATE public.productos SET codigo = 'ABC-5 ' WHERE id = %s RETURNING codigo$q$, v_a));
  IF v_t IS DISTINCT FROM 'PASA ABC-5 ' THEN
    v_fallas := v_fallas || ('C5 · el producto tenía que poder cambiar la caja de su propio código: ' || v_t);
  END IF;
  v_t := pg_temp.intenta(v_adm, 1, format($q$UPDATE public.productos SET precio = 1500, codigo = codigo WHERE id = %s RETURNING (precio = 1500)::text$q$, v_a));
  IF v_t IS DISTINCT FROM 'PASA true' THEN
    v_fallas := v_fallas || ('C5 · el producto tenía que poder guardarse con su mismo código: ' || v_t);
  END IF;

  -- ===================================================================== C6 ==
  PERFORM pg_temp.prod(1, 'C6 dado de baja', 'C6-B', false);
  v_t := pg_temp.intenta(v_adm, 1, $q$INSERT INTO public.productos (nombre, precio, sucursal_id, codigo)
                                       VALUES ('ZZ C4a C6 nuevo', 100, 1, 'c6-b') RETURNING id::text$q$);
  IF v_t NOT LIKE '23505 Ya existe un producto con el código «c6-b» en esta sucursal: «ZZ C4a C6 dado de baja» (desactivado).%' THEN
    v_fallas := v_fallas || ('C6 · contra un desactivado el mensaje tenía que decirlo: ' || v_t);
  END IF;

  -- ===================================================================== C7 ==
  DECLARE
    v_o bigint; v_mov bigint; v_item bigint; v_r text;
  BEGIN
    v_o := pg_temp.prod(2, 'C7 origen', 'ENV-7');
    UPDATE productos SET stock = 10 WHERE id = v_o;
    PERFORM pg_temp.prod(1, 'C7 ya en el destino', ' env-7', false);
    PERFORM pg_temp.como(v_adm, 2);
    v_j := public.crear_movimiento_sucursal(1, 'ensayo c4a', jsonb_build_array(jsonb_build_object('producto_id', v_o, 'cantidad', 5)));
    v_mov := (v_j->>'movimiento_id')::bigint;
    SELECT id INTO v_item FROM movimiento_sucursal_items WHERE movimiento_id = v_mov;
    PERFORM pg_temp.como(v_adm, 1);
    BEGIN
      v_j := public.aceptar_movimiento_sucursal(v_mov, jsonb_build_array(jsonb_build_object(
               'item_id', v_item, 'accion', 'crear_nuevo')));
      -- La RPC atrapa el error y lo devuelve en `error` (lo muestra el front tal cual).
      v_r := CASE WHEN COALESCE((v_j->>'success')::boolean, false) THEN 'PASA ' || v_j::text
                  ELSE 'RECHAZA ' || COALESCE(v_j->>'error', v_j::text) END;
    EXCEPTION WHEN OTHERS THEN
      v_r := SQLSTATE || ' ' || SQLERRM;
    END;
    IF v_r NOT LIKE 'RECHAZA Ya existe un producto con el código «ENV-7» en esta sucursal: «ZZ C4a C7 ya en el destino» (desactivado). Usá ese producto (al recibir un envío, elegilo como destino)%' THEN
      v_fallas := v_fallas || ('C7 · el envío que crea el producto en el destino tenía que chocar con el mensaje: ' || v_r);
    END IF;
    SELECT count(*) INTO v_n FROM productos WHERE sucursal_id = 1 AND upper(btrim(codigo)) = 'ENV-7';
    IF v_n <> 1 THEN
      v_fallas := v_fallas || format('C7 · en el destino quedaron %s productos con el código', v_n);
    END IF;
  END;

  -- ===================================================================== C8 ==
  BEGIN
    PERFORM pg_temp.prod(1, 'C8 primero', 'C8');
    IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.productos'::regclass AND tgname = 'trg_productos_codigo_unico') THEN
      ALTER TABLE public.productos DISABLE TRIGGER trg_productos_codigo_unico;
    END IF;
    BEGIN
      PERFORM pg_temp.prod(1, 'C8 segundo', 'c8 ');
      v_t := 'PASA';
    EXCEPTION WHEN OTHERS THEN
      v_t := SQLSTATE || ' ' || SQLERRM;
    END;
    IF v_t NOT LIKE '23505 %productos_codigo_unico_por_sucursal%' THEN
      v_fallas := v_fallas || ('C8 · sin el trigger, el índice único tenía que frenar el repetido: ' || v_t);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ===================================================================== C9 ==
  PERFORM pg_temp.como(NULL, NULL);
  PERFORM pg_temp.prod(1, 'C9 primero', 'C9-SRV');
  BEGIN
    PERFORM pg_temp.prod(1, 'C9 segundo', 'c9-srv');
    v_t := 'PASA';
  EXCEPTION WHEN OTHERS THEN
    v_t := SQLSTATE || ' ' || SQLERRM;
  END;
  IF v_t NOT LIKE '23505 Ya existe un producto con el código «c9-srv» en esta sucursal: «ZZ C4a C9 primero»%' THEN
    v_fallas := v_fallas || ('C9 · el server tampoco tenía que poder repetir el código: ' || v_t);
  END IF;

  -- ==================================================================== C10 ==
  PERFORM pg_temp.prod(2, 'C10 secreto de la 2', 'C10-SEC');
  v_t := pg_temp.intenta(v_adm1, 1, $q$INSERT INTO public.productos (nombre, precio, sucursal_id, codigo)
                                        VALUES ('ZZ C4a C10 intruso', 100, 2, 'c10-sec') RETURNING id::text$q$);
  IF v_t NOT LIKE '42501 %' OR v_t LIKE '%secreto%' THEN
    v_fallas := v_fallas || ('C10 · escribir en una sucursal ajena tenía que dar el 42501 de la RLS sin mostrar nada: ' || v_t);
  END IF;

  -- ============================================================= C11 a C14 ==
  -- El trigger corre antes que la RLS: el que no pasa la policy de escritura no recibe el
  -- nombre (ni siquiera «ya existe»), sino el 42501 de la RLS.
  DECLARE
    v_dep uuid := pg_temp.u('deposito', 1);
    v_pre uuid := pg_temp.u('preventista', 1);
    v_enc uuid := pg_temp.u('encargado', 1);
    v_enc2 uuid := pg_temp.u('encargado', 2);
    v_quien text; v_uid uuid; v_suc bigint; v_dest bigint;
  BEGIN
    PERFORM pg_temp.prod(1, 'C11 secreto de deposito', 'C11-SEC', false);
    FOR v_quien, v_uid, v_suc, v_dest IN
      SELECT * FROM (VALUES ('C11 · el depósito', v_dep, 1::bigint, 1::bigint),
                            ('C12 · el preventista', v_pre, 1, 1),
                            ('C12 · el encargado', v_enc, 1, 1),
                            ('C13 · un encargado de otra sucursal', v_enc2, 2, 1),
                            ('C14 · un desactivado', v_des, 1, 1)) t(a, b, c, d)
    LOOP
      v_t := pg_temp.intenta(v_uid, v_suc, format($q$INSERT INTO public.productos (nombre, precio, sucursal_id, codigo)
                                                     VALUES ('ZZ C4a C11 intento', 100, %s, 'c11-sec') RETURNING id::text$q$, v_dest));
      IF v_t NOT LIKE '42501 %' OR v_t LIKE '%secreto%' OR v_t LIKE '%Ya existe%' THEN
        v_fallas := v_fallas || format('%s tenía que recibir el 42501 de la RLS, sin el producto: %s', v_quien, v_t);
      END IF;
    END LOOP;
    -- y por UPDATE: el preventista que le cambia el código a un producto (la RLS no le deja)
    v_a := pg_temp.prod(1, 'C12 otro', 'C12-OTRO');
    v_t := pg_temp.intenta(v_pre, 1, format($q$UPDATE public.productos SET codigo = 'c11-sec' WHERE id = %s RETURNING id::text$q$, v_a));
    IF v_t LIKE '%secreto%' OR v_t LIKE '%Ya existe%' THEN
      v_fallas := v_fallas || ('C12 · la edición del preventista no tenía que mostrar el producto: ' || v_t);
    END IF;

    -- ================================================================ C15 ==
    -- El encargado acepta envíos (RPC definer, sin RLS): no pasa la policy, así que el trigger
    -- no lo nombra; lo frena el índice, la RPC lo devuelve en `error` y no se crea nada.
    DECLARE
      v_o bigint; v_mov bigint; v_item bigint; v_r text;
    BEGIN
      v_o := pg_temp.prod(2, 'C15 origen', 'ENV-15');
      UPDATE productos SET stock = 10 WHERE id = v_o;
      PERFORM pg_temp.prod(1, 'C15 secreto en el destino', ' env-15');
      PERFORM pg_temp.como(v_adm, 2);
      v_j := public.crear_movimiento_sucursal(1, 'ensayo c4a 15', jsonb_build_array(jsonb_build_object('producto_id', v_o, 'cantidad', 5)));
      v_mov := (v_j->>'movimiento_id')::bigint;
      SELECT id INTO v_item FROM movimiento_sucursal_items WHERE movimiento_id = v_mov;
      PERFORM pg_temp.como(v_enc, 1);
      BEGIN
        v_j := public.aceptar_movimiento_sucursal(v_mov, jsonb_build_array(jsonb_build_object('item_id', v_item, 'accion', 'crear_nuevo')));
        v_r := CASE WHEN COALESCE((v_j->>'success')::boolean, false) THEN 'PASA ' || v_j::text
                    ELSE 'RECHAZA ' || COALESCE(v_j->>'error', v_j::text) END;
      EXCEPTION WHEN OTHERS THEN
        v_r := SQLSTATE || ' ' || SQLERRM;
      END;
      IF v_r NOT LIKE 'RECHAZA %productos_codigo_unico_por_sucursal%' OR v_r LIKE '%secreto%' THEN
        v_fallas := v_fallas || ('C15 · el encargado que acepta el envío tenía que chocar con el índice, sin el producto: ' || v_r);
      END IF;
      SELECT count(*) INTO v_n FROM productos WHERE sucursal_id = 1 AND upper(btrim(codigo)) = 'ENV-15';
      IF v_n <> 1 THEN
        v_fallas := v_fallas || format('C15 · en el destino quedaron %s productos con el código', v_n);
      END IF;
    END;
  END;

  -- ===================================================================== A1 ==
  v_a := pg_temp.prod(1, 'A1', 'A1-COD');
  v_ids := ARRAY[v_a::text];
  v_antes := pg_temp.filas('productos', v_ids);
  v_foto := pg_temp.audit_foto();
  v_t := pg_temp.intenta(v_adm, 1, format('UPDATE public.productos SET precio = 1331, stock_minimo = 4 WHERE id = %s RETURNING id::text', v_a));
  v_desp := pg_temp.filas('productos', v_ids);
  v_real := pg_temp.audit_nuevas(v_foto);
  v_esp := pg_temp.esperado('productos', 'UPDATE', v_antes, v_desp);
  IF v_t NOT LIKE 'PASA %' OR cardinality(v_real) <> 1 OR v_real IS DISTINCT FROM v_esp THEN
    v_fallas := v_fallas || format('A1 · UPDATE suelto: %s; anotó %s y tenía que anotar %s', v_t, v_real, v_esp);
  END IF;

  -- ===================================================================== A2 ==
  DECLARE v_cat uuid;
  BEGIN
    INSERT INTO categorias (nombre, sucursal_id) VALUES ('ZZ C4a rubro', 1) RETURNING id INTO v_cat;
    SELECT array_agg(pg_temp.prod(1, 'A2 ' || g, NULL, true, 'ZZ C4a rubro')::text) INTO v_ids FROM generate_series(1, 30) g;
    v_antes := pg_temp.filas('productos', v_ids);
    v_foto := pg_temp.audit_foto();
    v_t := pg_temp.intenta(v_adm, 1, format($q$WITH x AS (UPDATE public.productos SET stock_minimo = 3, categoria = NULL
                                                 WHERE id = ANY (%L::bigint[]) RETURNING 1) SELECT count(*)::text FROM x$q$, v_ids));
    v_desp := pg_temp.filas('productos', v_ids);
    PERFORM pg_temp.como(v_adm, 1);
    v_esp := pg_temp.esperado('productos', 'UPDATE', v_antes, v_desp);
    v_real := ARRAY(SELECT x FROM unnest(pg_temp.audit_nuevas(v_foto)) x WHERE x->>'tabla' = 'productos' ORDER BY x::text);
    IF v_t IS DISTINCT FROM 'PASA 30' OR cardinality(v_real) <> 30 OR v_real IS DISTINCT FROM v_esp THEN
      v_fallas := v_fallas || format('A2 · UPDATE masivo (REST, 30 productos): %s; anotó %s filas de productos distintas de las %s esperadas',
                                     v_t, cardinality(v_real), cardinality(v_esp));
    END IF;
  END;

  -- ===================================================================== R1 ==
  -- Renombrar un rubro de 30 productos (dos con otra caja en el texto, uno con subrubro):
  -- UNA fila, en el rubro, con el antes de cada uno; ninguna de productos.
  DECLARE v_cat uuid; v_sub uuid; v_fila jsonb; v_grupos jsonb; v_todos bigint[];
  BEGIN
    INSERT INTO categorias (nombre, sucursal_id) VALUES ('ZZ C4a R1', 1) RETURNING id INTO v_cat;
    INSERT INTO categorias (nombre, sucursal_id, parent_id) VALUES ('ZZ C4a R1 sub', 1, v_cat) RETURNING id INTO v_sub;
    SELECT array_agg(pg_temp.prod(1, 'R1 ' || g, NULL, true, CASE WHEN g <= 2 THEN 'zz c4a r1' ELSE 'ZZ C4a R1' END)::text)
      INTO v_ids FROM generate_series(1, 30) g;
    UPDATE productos SET subcategoria_id = v_sub WHERE id = v_ids[3]::bigint;
    v_antes := pg_temp.filas('productos', v_ids);
    v_foto := pg_temp.audit_foto();
    v_t := pg_temp.intenta(v_adm, 1, format($q$SELECT public.renombrar_rubro(%L, NULL, 'ZZ C4a R1 nuevo')->>'productos'$q$, v_cat));
    v_real := pg_temp.audit_nuevas(v_foto);
    v_fila := v_real[1];
    v_grupos := v_fila->'old_data'->'productos';
    SELECT array_agg(i::bigint ORDER BY i::bigint) INTO v_todos
      FROM jsonb_array_elements(v_grupos) g, jsonb_array_elements_text(g->'ids') i;
    IF v_t IS DISTINCT FROM 'PASA 30' OR cardinality(v_real) <> 1
       OR v_fila->>'tabla' <> 'categorias' OR v_fila->>'registro_id' <> v_cat::text OR v_fila->>'accion' <> 'UPDATE'
       OR v_fila->'old_data'->>'nombre' <> 'ZZ C4a R1' OR v_fila->'new_data'->>'nombre' <> 'ZZ C4a R1 nuevo'
       OR (v_fila->'new_data'->>'cantidad_productos')::int <> 30 OR v_fila->'campos_modificados' <> '["nombre"]'::jsonb
       OR v_fila->'new_data'->>'estado' IS DISTINCT FROM 'terminado'
       OR v_fila->>'usuario_id' <> v_adm::text OR v_fila->>'usuario_rol' <> 'admin' OR (v_fila->>'sucursal_id')::bigint <> 1
       OR v_todos IS DISTINCT FROM (SELECT array_agg(x::bigint ORDER BY x::bigint) FROM unnest(v_ids) x)
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_grupos) g
                       WHERE g->>'categoria' = 'zz c4a r1' AND jsonb_array_length(g->'ids') = 2)
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_grupos) g
                       WHERE g->>'subcategoria_id' = v_sub::text AND g->'ids' = jsonb_build_array(v_ids[3]::bigint)) THEN
      v_fallas := v_fallas || format('R1 · renombrar un rubro de 30 tenía que dejar una fila en el rubro con el antes de cada uno: %s; anotó %s filas, la primera %s',
                                     v_t, cardinality(v_real), left(v_real[1]::text, 300));
    END IF;

    -- R2 · eliminarlo: UNA fila DELETE con los ids (y su subrubro), ninguna de productos.
    v_foto := pg_temp.audit_foto();
    v_t := pg_temp.intenta(v_adm, 1, format($q$SELECT public.eliminar_rubro(%L, NULL, false)->>'productos'$q$, v_cat));
    v_real := pg_temp.audit_nuevas(v_foto);
    v_fila := v_real[1];
    SELECT array_agg(i::bigint ORDER BY i::bigint) INTO v_todos
      FROM jsonb_array_elements(v_fila->'old_data'->'productos') g, jsonb_array_elements_text(g->'ids') i;
    IF v_t IS DISTINCT FROM 'PASA 30' OR cardinality(v_real) <> 1
       OR v_fila->>'tabla' <> 'categorias' OR v_fila->>'accion' <> 'DELETE' OR v_fila->'new_data' <> 'null'::jsonb
       OR v_fila->'old_data'->>'nombre' <> 'ZZ C4a R1 nuevo' OR (v_fila->'old_data'->>'cantidad_productos')::int <> 30
       OR v_todos IS DISTINCT FROM (SELECT array_agg(x::bigint ORDER BY x::bigint) FROM unnest(v_ids) x)
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_fila->'old_data'->'productos') g
                       WHERE g->>'subcategoria_id' = v_sub::text) THEN
      v_fallas := v_fallas || format('R2 · eliminar un rubro de 30 tenía que dejar una fila DELETE en el rubro con los ids: %s; anotó %s filas, la primera %s',
                                     v_t, cardinality(v_real), left(v_real[1]::text, 300));
    END IF;
  END;

  -- ===================================================================== R3 ==
  -- Cambiarle el rubro a UN producto desde la ficha deja su fila de siempre; y la marca no
  -- sobrevive a renombrar: en la misma transacción, después, también.
  DECLARE v_cat uuid;
  BEGIN
    INSERT INTO categorias (nombre, sucursal_id) VALUES ('ZZ C4a R3', 1) RETURNING id INTO v_cat;
    v_a := pg_temp.prod(1, 'R3', NULL, true, 'ZZ C4a R3');
    v_t := pg_temp.intenta(v_adm, 1, format($q$SELECT public.renombrar_rubro(%L, NULL, 'ZZ C4a R3 b')->>'productos'$q$, v_cat));
    v_antes := pg_temp.filas('productos', ARRAY[v_a::text]);
    v_foto := pg_temp.audit_foto();
    v_t := pg_temp.intenta(v_adm, 1, format($q$UPDATE public.productos SET categoria = NULL WHERE id = %s RETURNING id::text$q$, v_a));
    v_desp := pg_temp.filas('productos', ARRAY[v_a::text]);
    PERFORM pg_temp.como(v_adm, 1);
    v_esp := pg_temp.esperado('productos', 'UPDATE', v_antes, v_desp);
    v_real := pg_temp.audit_nuevas(v_foto);
    IF v_t NOT LIKE 'PASA %' OR cardinality(v_real) <> 1 OR v_real IS DISTINCT FROM v_esp THEN
      v_fallas := v_fallas || format('R3 · el rubro de un producto desde la ficha tenía que auditarse como siempre: %s; anotó %s y tenía que anotar %s',
                                     v_t, v_real, v_esp);
    END IF;
  END;

  -- ============================================================= R4 y R5 ==
  -- Con la marca puesta a mano (como sólo podría hacerlo el server): un UPDATE que cambia el
  -- rubro Y el precio se audita entero, y uno que cambia otra columna, también.
  v_a := pg_temp.prod(1, 'R4', NULL, true, 'ZZ C4a R4');
  v_b := pg_temp.prod(1, 'R5', NULL, true, 'ZZ C4a R4');
  v_antes := pg_temp.filas('productos', ARRAY[v_a::text, v_b::text]);
  v_foto := pg_temp.audit_foto();
  PERFORM pg_temp.como(v_adm, 1);
  PERFORM set_config('app.rubro_masivo', 'renombrar_rubro', true);
  UPDATE productos SET categoria = 'ZZ C4a R4 b', precio = 999 WHERE id = v_a;
  UPDATE productos SET stock_minimo = 9 WHERE id = v_b;
  v_desp := pg_temp.filas('productos', ARRAY[v_a::text, v_b::text]);
  PERFORM set_config('app.rubro_masivo', '', true);
  v_esp := pg_temp.esperado('productos', 'UPDATE', v_antes, v_desp);
  v_real := pg_temp.audit_nuevas(v_foto);
  IF cardinality(v_real) <> 2 OR v_real IS DISTINCT FROM v_esp THEN
    v_fallas := v_fallas || format('R4/R5 · con la marca a mano, un cambio de otra columna tenía que auditarse entero: anotó %s y tenía que anotar %s',
                                   v_real, v_esp);
  END IF;

  -- ===================================================================== R6 ==
  -- Renombrar en tandas de 12: retomable, una sola fila de auditoría que termina con el total,
  -- y otro cambio del mismo rubro se rechaza mientras está a medias.
  DECLARE v_cat uuid; v_fila jsonb; v_todos bigint[]; v_r jsonb;
  BEGIN
    INSERT INTO categorias (nombre, sucursal_id) VALUES ('ZZ C4a R6', 1) RETURNING id INTO v_cat;
    SELECT array_agg(pg_temp.prod(1, 'R6 ' || g, NULL, true, 'ZZ C4a R6')::text) INTO v_ids FROM generate_series(1, 30) g;
    v_foto := pg_temp.audit_foto();
    v_t := pg_temp.intenta(v_adm, 1, format($q$SELECT (public.renombrar_rubro(%L, NULL, 'ZZ C4a R6 b', 12))::text$q$, v_cat));
    v_r := CASE WHEN v_t LIKE 'PASA %' THEN substr(v_t, 6)::jsonb END;
    v_real := pg_temp.audit_nuevas(v_foto);
    IF v_t NOT LIKE 'PASA %' OR (v_r->>'productos')::int <> 12 OR (v_r->>'faltan')::int <> 18 OR (v_r->>'terminado')::boolean
       OR cardinality(v_real) <> 1 OR v_real[1]->'new_data'->>'estado' <> 'en_curso'
       OR (v_real[1]->'new_data'->>'cantidad_productos')::int <> 12
       OR (SELECT nombre FROM categorias WHERE id = v_cat) <> 'ZZ C4a R6 b' THEN
      v_fallas := v_fallas || format('R6 · la primera tanda de 12: %s; anotó %s filas', v_t, cardinality(v_real));
    END IF;
    v_t := pg_temp.intenta(v_adm, 1, format($q$SELECT (public.renombrar_rubro(%L, NULL, 'ZZ C4a R6 otro', 12))::text$q$, v_cat));
    IF v_t NOT LIKE '22023 %quedó a medias%' THEN
      v_fallas := v_fallas || ('R6 · otro nombre con el rubro a medias tenía que rechazarse: ' || v_t);
    END IF;
    v_t := pg_temp.intenta(v_adm, 1, format($q$SELECT (public.eliminar_rubro(%L, NULL, false, 12))::text$q$, v_cat));
    IF v_t NOT LIKE '22023 %quedó a medias%' THEN
      v_fallas := v_fallas || ('R6 · eliminarlo con el renombre a medias tenía que rechazarse: ' || v_t);
    END IF;
    v_t := pg_temp.intenta(v_adm, 1, format($q$SELECT (public.renombrar_rubro(%L, NULL, 'ZZ C4a R6 b', 12))::text$q$, v_cat));
    v_t := pg_temp.intenta(v_adm, 1, format($q$SELECT (public.renombrar_rubro(%L, NULL, 'ZZ C4a R6 b', 12))::text$q$, v_cat));
    v_r := CASE WHEN v_t LIKE 'PASA %' THEN substr(v_t, 6)::jsonb END;
    v_real := pg_temp.audit_nuevas(v_foto);
    v_fila := v_real[1];
    SELECT array_agg(i::bigint ORDER BY i::bigint) INTO v_todos
      FROM jsonb_array_elements(v_fila->'old_data'->'productos') g, jsonb_array_elements_text(g->'ids') i;
    IF v_t NOT LIKE 'PASA %' OR (v_r->>'faltan')::int <> 0 OR NOT (v_r->>'terminado')::boolean
       OR (v_r->>'productos_total')::int <> 30
       OR cardinality(v_real) <> 1 OR v_fila->'new_data'->>'estado' <> 'terminado'
       OR (v_fila->'new_data'->>'cantidad_productos')::int <> 30
       OR v_todos IS DISTINCT FROM (SELECT array_agg(x::bigint ORDER BY x::bigint) FROM unnest(v_ids) x)
       OR EXISTS (SELECT 1 FROM productos WHERE id = ANY (v_ids::bigint[])
                   AND (categoria IS DISTINCT FROM 'ZZ C4a R6 b' OR categoria_id IS DISTINCT FROM v_cat)) THEN
      v_fallas := v_fallas || format('R6 · al terminar: %s; anotó %s filas, la primera %s', v_t, cardinality(v_real), left(v_fila::text, 300));
    END IF;

    -- R7 · eliminarlo en tandas de 20: el rubro sigue hasta la última, y una sola fila DELETE.
    v_foto := pg_temp.audit_foto();
    v_t := pg_temp.intenta(v_adm, 1, format($q$SELECT (public.eliminar_rubro(%L, NULL, false, 20))::text$q$, v_cat));
    v_r := CASE WHEN v_t LIKE 'PASA %' THEN substr(v_t, 6)::jsonb END;
    IF v_t NOT LIKE 'PASA %' OR (v_r->>'faltan')::int <> 10 OR NOT EXISTS (SELECT 1 FROM categorias WHERE id = v_cat)
       OR NOT (public.eliminar_rubro(v_cat, NULL, true)->>'a_medias')::boolean THEN
      v_fallas := v_fallas || ('R7 · la primera tanda de 20 tenía que dejar el rubro, con 10 por sacar y «a medias»: ' || v_t);
    END IF;
    v_t := pg_temp.intenta(v_adm, 1, format($q$SELECT (public.eliminar_rubro(%L, NULL, false, 20))::text$q$, v_cat));
    v_r := CASE WHEN v_t LIKE 'PASA %' THEN substr(v_t, 6)::jsonb END;
    v_real := pg_temp.audit_nuevas(v_foto);
    v_fila := v_real[1];
    IF v_t NOT LIKE 'PASA %' OR NOT (v_r->>'terminado')::boolean OR (v_r->>'productos_total')::int <> 30
       OR EXISTS (SELECT 1 FROM categorias WHERE id = v_cat)
       OR cardinality(v_real) <> 1 OR v_fila->>'accion' <> 'DELETE' OR v_fila->'new_data' <> 'null'::jsonb
       OR (v_fila->'old_data'->>'cantidad_productos')::int <> 30 THEN
      v_fallas := v_fallas || format('R7 · al terminar de eliminar: %s; anotó %s filas, la primera %s', v_t, cardinality(v_real), left(v_fila::text, 300));
    END IF;
  END;

  -- ===================================================================== R8 ==
  -- Fuera de las dos RPC la sincronización del id del rubro hace lo de siempre, también con una
  -- marca puesta a mano que no es la del texto.
  DECLARE v_c1 uuid; v_c2 uuid; v_p bigint; v_ids8 uuid[] := '{}';
  BEGIN
    INSERT INTO categorias (nombre, sucursal_id) VALUES ('ZZ C4a R8 uno', 1) RETURNING id INTO v_c1;
    INSERT INTO categorias (nombre, sucursal_id) VALUES ('ZZ C4a R8 dos', 1) RETURNING id INTO v_c2;
    v_p := pg_temp.prod(1, 'R8', NULL, true, ' zz c4a r8 UNO ');
    v_ids8 := v_ids8 || (SELECT categoria_id FROM productos WHERE id = v_p);
    UPDATE productos SET categoria = 'ZZ C4A R8 DOS' WHERE id = v_p;
    v_ids8 := v_ids8 || (SELECT categoria_id FROM productos WHERE id = v_p);
    UPDATE productos SET categoria = 'ZZ C4a R8 no existe' WHERE id = v_p;
    v_ids8 := v_ids8 || COALESCE((SELECT categoria_id FROM productos WHERE id = v_p), '00000000-0000-0000-0000-000000000000');
    PERFORM set_config('app.rubro_masivo', 'renombrar_rubro', true);
    PERFORM set_config('app.rubro_masivo_id', gen_random_uuid()::text, true);
    PERFORM set_config('app.rubro_masivo_nombre', 'ZZ C4a R8 otro', true);
    PERFORM set_config('app.rubro_masivo_sucursal', '1', true);
    UPDATE productos SET categoria = 'ZZ C4a R8 uno' WHERE id = v_p;
    v_ids8 := v_ids8 || (SELECT categoria_id FROM productos WHERE id = v_p);
    PERFORM set_config('app.rubro_masivo', '', true);
    IF v_ids8 IS DISTINCT FROM ARRAY[v_c1, v_c2, '00000000-0000-0000-0000-000000000000'::uuid, v_c1] THEN
      v_fallas := v_fallas || format('R8 · la sincronización del rubro cambió fuera de las RPC: %s (esperaba %s, %s, ninguno, %s)', v_ids8, v_c1, v_c2, v_c1);
    END IF;
  END;

  -- ===================================================================== A3 ==
  v_a := pg_temp.prod(1, 'A3', NULL);
  v_ids := ARRAY[v_a::text];
  v_antes := pg_temp.filas('productos', v_ids) || pg_temp.filas('perfiles', ARRAY[v_otro::text]);
  v_foto := pg_temp.audit_foto();
  v_t := pg_temp.intenta(NULL, NULL, format($q$WITH a AS (UPDATE public.productos SET etiqueta_bulto = 'caja' WHERE id = %s RETURNING 1),
                                                  b AS (UPDATE public.perfiles SET nombre = 'C4a otro nombre' WHERE id = %L RETURNING 1)
                                             SELECT (SELECT count(*) FROM a) + (SELECT count(*) FROM b)$q$, v_a, v_otro), 'service_role');
  v_desp := pg_temp.filas('productos', v_ids) || pg_temp.filas('perfiles', ARRAY[v_otro::text]);
  PERFORM pg_temp.como(NULL, NULL, 'service_role');
  v_esp := pg_temp.esperado('productos', 'UPDATE', v_antes[1:1], v_desp[1:1])
        || pg_temp.esperado('perfiles', 'UPDATE', v_antes[2:2], v_desp[2:2]);
  v_esp := ARRAY(SELECT x FROM unnest(v_esp) x ORDER BY x::text);
  v_real := pg_temp.audit_nuevas(v_foto);
  IF v_t IS DISTINCT FROM 'PASA 2' OR cardinality(v_real) <> 2 OR v_real IS DISTINCT FROM v_esp
     OR EXISTS (SELECT 1 FROM unnest(v_real) x WHERE x->>'usuario_id' IS NOT NULL) THEN
    v_fallas := v_fallas || format('A3 · como service_role: %s; anotó %s y tenía que anotar %s', v_t, v_real, v_esp);
  END IF;

  -- ===================================================================== A4 ==
  SELECT array_agg(pg_temp.prod(1, 'A4 ' || g, NULL)::text) INTO v_ids FROM generate_series(1, 3) g;
  v_antes := pg_temp.filas('productos', v_ids);
  v_foto := pg_temp.audit_foto();
  v_t := pg_temp.intenta(v_adm, 1, format($q$SELECT public.actualizar_precios_masivo(
            (SELECT jsonb_agg(jsonb_build_object('producto_id', x::bigint, 'precio_neto', 1100, 'precio_final', 1331))
               FROM unnest(%L::text[]) x))->>'actualizados'$q$, v_ids));
  v_desp := pg_temp.filas('productos', v_ids);
  PERFORM pg_temp.como(v_adm, 1);
  v_esp := pg_temp.esperado('productos', 'UPDATE', v_antes, v_desp);
  v_real := ARRAY(SELECT x FROM unnest(pg_temp.audit_nuevas(v_foto)) x WHERE x->>'tabla' = 'productos' ORDER BY x::text);
  IF v_t IS DISTINCT FROM 'PASA 3' OR cardinality(v_real) <> 3 OR v_real IS DISTINCT FROM v_esp THEN
    v_fallas := v_fallas || format('A4 · por una RPC definer: %s; anotó %s y tenía que anotar %s', v_t, v_real, v_esp);
  END IF;

  -- ===================================================================== A5 ==
  v_a := pg_temp.prod(1, 'A5', NULL);
  v_antes := pg_temp.filas('productos', ARRAY[v_a::text]) || pg_temp.filas('perfiles', ARRAY[v_otro::text]);
  v_foto := pg_temp.audit_foto();
  -- Como lo haría una función definer que llama con el token vivo de un desactivado.
  PERFORM pg_temp.como(v_des, 1);
  UPDATE productos SET stock_minimo = 7 WHERE id = v_a;
  UPDATE perfiles SET nombre = 'C4a otro, de nuevo' WHERE id = v_otro;
  v_desp := pg_temp.filas('productos', ARRAY[v_a::text]) || pg_temp.filas('perfiles', ARRAY[v_otro::text]);
  v_esp := pg_temp.esperado('productos', 'UPDATE', v_antes[1:1], v_desp[1:1])
        || pg_temp.esperado('perfiles', 'UPDATE', v_antes[2:2], v_desp[2:2]);
  v_esp := ARRAY(SELECT x FROM unnest(v_esp) x ORDER BY x::text);
  v_real := pg_temp.audit_nuevas(v_foto);
  IF cardinality(v_real) <> 2 OR v_real IS DISTINCT FROM v_esp
     OR NOT EXISTS (SELECT 1 FROM unnest(v_real) x WHERE x->>'tabla' = 'perfiles' AND x->>'sucursal_id' IS NULL
                                                        AND x->>'usuario_id' = v_des::text AND x->>'usuario_rol' = 'encargado') THEN
    v_fallas := v_fallas || format('A5 · con el token de un desactivado: anotó %s y tenía que anotar %s', v_real, v_esp);
  END IF;

  -- ===================================================================== A6 ==
  PERFORM pg_temp.como(NULL, NULL);
  v_foto := pg_temp.audit_foto();
  v_a := pg_temp.prod(1, 'A6', 'A6-COD');
  v_desp := pg_temp.filas('productos', ARRAY[v_a::text]);
  v_esp := pg_temp.esperado('productos', 'INSERT', '{}', v_desp);
  v_antes := v_desp;
  UPDATE productos SET nombre = 'ZZ C4a A6 cambiado', precio = 999 WHERE id = v_a;
  v_desp := pg_temp.filas('productos', ARRAY[v_a::text]);
  v_esp := v_esp || pg_temp.esperado('productos', 'UPDATE', v_antes, v_desp);
  DELETE FROM productos WHERE id = v_a;
  v_esp := v_esp || pg_temp.esperado('productos', 'DELETE', v_desp, '{}');
  v_antes := pg_temp.filas('perfiles', ARRAY[v_otro::text]);
  UPDATE perfiles SET nombre = 'C4a otro, sin usuario' WHERE id = v_otro;
  v_esp := v_esp || pg_temp.esperado('perfiles', 'UPDATE', v_antes, pg_temp.filas('perfiles', ARRAY[v_otro::text]));
  v_esp := ARRAY(SELECT x FROM unnest(v_esp) x ORDER BY x::text);
  v_real := pg_temp.audit_nuevas(v_foto);
  IF cardinality(v_real) <> 4 OR v_real IS DISTINCT FROM v_esp THEN
    v_fallas := v_fallas || format('A6 · sin auth.uid(): anotó %s y tenía que anotar %s', v_real, v_esp);
  END IF;

  -- ===================================================================== A7 ==
  v_a := pg_temp.prod(1, 'A7', NULL);
  v_foto := pg_temp.audit_foto();
  -- Sin cambios no hay fila: ni siquiera updated_at (lo mueve sólo un cambio real).
  ALTER TABLE public.productos DISABLE TRIGGER trigger_update_productos_timestamp;
  UPDATE productos SET precio = precio, nombre = nombre WHERE id = v_a;
  ALTER TABLE public.productos ENABLE TRIGGER trigger_update_productos_timestamp;
  v_real := pg_temp.audit_nuevas(v_foto);
  IF cardinality(v_real) <> 0 THEN
    v_fallas := v_fallas || format('A7 · un UPDATE sin cambios anotó %s', v_real);
  END IF;

  -- ===================================================================== K1 ==
  IF has_function_privilege('anon', 'public.audit_log_changes()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.audit_log_changes()', 'EXECUTE')
     OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.audit_log_changes()'::regprocedure) THEN
    v_fallas := v_fallas || 'K1 · cambiaron el definer o los EXECUTE de audit_log_changes()'::text;
  END IF;
  IF to_regprocedure('public.productos_codigo_unico()') IS NOT NULL
     AND (has_function_privilege('anon', 'public.productos_codigo_unico()', 'EXECUTE')
          OR has_function_privilege('authenticated', 'public.productos_codigo_unico()', 'EXECUTE')) THEN
    v_fallas := v_fallas || 'K1 · productos_codigo_unico() es ejecutable por anon o authenticated'::text;
  END IF;

  IF cardinality(v_fallas) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK · código único por sucursal (C1-C15) y auditoría igual fila por fila (A1-A7), rubros con una fila y en tandas (R1-R8), permisos (K1)'
      USING ERRCODE = 'P0001';
  END IF;
  RAISE EXCEPTION 'ENSAYO FALLÓ (%):%', cardinality(v_fallas), E'\n  ' || array_to_string(v_fallas, E'\n  ')
    USING ERRCODE = 'P0001';
 END;
END
$ensayo$;
