-- 438 · `cliente_preventistas` entra a la auditoría (#1385, decisión del dueño del 02/11).
--
-- QUÉ PASABA
--   Un admin le asigna un cliente a quien no es el dueño de la zona, otro vincula la
--   zona y el cliente vuelve al dueño. La tabla no tenía auditoría: lo único que quedaba
--   era `clientes.preventista_id`, que es el primero de la lista, y `audit_clientes` lo
--   registra sólo cuando cambia. Con el cliente 331 hubo que deducir la secuencia, y
--   esa columna se dropea en la tarjeta 10.
--
-- QUÉ CAMBIA
--   Tres triggers AFTER por sentencia y una función nueva, audit_cliente_preventistas,
--   que deja una fila en `audit_logs` por cada fila que se dio de alta, cambió o se dio
--   de baja.
--     · tabla 'cliente_preventistas', registro_id = cliente_id. La historia de un
--       cliente se lee con el índice (tabla, registro_id) que ya existe.
--     · old_data y new_data llevan la fila más `camino`: qué la escribió.
--     · Reasignar son dos filas de la misma transacción, con el mismo created_at: un
--       DELETE (de quién) y un INSERT (a quién).
--     · `camino` sale de la pila de llamadas, de afuera hacia adentro. Por eso no hizo
--       falta tocar ninguna función de la asignación, y una nueva queda nombrada sola:
--         'asignar_preventista_zona > _asignar_clientes_a'     vincular una zona
--         'clientes_zona_asigna_duenio > _asignar_clientes_a'  cambiarle la zona al cliente
--         'directo'                                            la ficha, por REST, o SQL a mano
--         'cascada'                                            la FK: se borró el cliente o el perfil
--
-- POR QUÉ NO audit_log_changes
--   Hace NEW.id, y esta tabla tiene clave compuesta: el primer INSERT tumbaría la
--   asignación. Además va por fila, con dos lecturas y una consulta a information_schema
--   en cada una.
--
-- POR QUÉ POR SENTENCIA
--   Vincular una zona borra e inserta de una vez: la zona más grande tiene 74 clientes.
--   Por sentencia, la sesión, el camino y las filas se resuelven una vez, y un INSERT
--   ... ON CONFLICT DO NOTHING que no insertó nada no deja rastro: la tabla de
--   transición viene vacía. Una tabla de transición exige un trigger por evento.
--
-- UN TRIGGER DE AUDITORÍA QUE FALLA TUMBA LA ASIGNACIÓN
--   Por eso nada acá levanta. Sin sesión, el usuario y el rol quedan NULL. Un token cuyo
--   usuario ya no existe también: audit_logs tiene FK a auth.users. Si el cliente ya no
--   está (cascada), la sucursal es la de la sesión, y audit_logs.sucursal_id admite NULL.
--
-- QUÉ NO CAMBIA
--   · asignar_preventista_zona, _asignar_clientes_a, clientes_zona_asigna_duenio,
--     cliente_preventistas_no_ajeno, cliente_preventistas_no_reservado, cp_insert y
--     auditoria_integridad(): la migración no los toca, así que no lleva premisa de md5.
--   · No se siembra la foto de hoy: la primera baja de cada asignación trae la fila.
--
-- Trigger de función nueva: sin EXECUTE para nadie de la app (#1245). Lo dispara el
-- executor, y queda en postgres + service_role, como audit_log_changes.
-- Ensayo: scripts/test-auditoria-cliente-preventistas-1385.sql. Aplicar desde el contenido LF.

BEGIN;

DO $lf$
BEGIN
  IF position(chr(13) IN current_query()) > 0 THEN
    RAISE EXCEPTION 'Esta migración se aplica con finales de línea LF';
  END IF;
END
$lf$;

CREATE FUNCTION public.audit_cliente_preventistas()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_filas   jsonb;
  v_pila    text;
  v_camino  text;
  v_usuario uuid;
  v_email   text;
  v_rol     text;
BEGIN
  -- El SQL que nombra una tabla de transición ausente no compila: cada evento tiene
  -- la suya, y el resto de la función trabaja sobre los pares viejo/nuevo.
  IF TG_OP = 'INSERT' THEN
    SELECT jsonb_agg(jsonb_build_object('n', to_jsonb(n))) INTO v_filas
      FROM filas_nuevas n;
  ELSIF TG_OP = 'DELETE' THEN
    SELECT jsonb_agg(jsonb_build_object('o', to_jsonb(o))) INTO v_filas
      FROM filas_viejas o;
  ELSE
    SELECT jsonb_agg(jsonb_build_object('o', to_jsonb(o), 'n', to_jsonb(n))) INTO v_filas
      FROM filas_viejas o
      FULL JOIN filas_nuevas n
        ON n.cliente_id = o.cliente_id AND n.preventista_id = o.preventista_id
     WHERE to_jsonb(o) IS DISTINCT FROM to_jsonb(n);
  END IF;

  IF v_filas IS NULL THEN
    RETURN NULL;
  END IF;

  -- La pila viene de adentro hacia afuera, y la primera función es ésta.
  GET DIAGNOSTICS v_pila = PG_CONTEXT;
  SELECT string_agg(m.f[1], ' > ' ORDER BY m.i DESC) INTO v_camino
    FROM regexp_matches(v_pila, '(?:PL/pgSQL|SQL) function "?(?:public\.)?(\w+)', 'g')
         WITH ORDINALITY AS m(f, i)
   WHERE m.f[1] NOT IN ('audit_cliente_preventistas', 'inline_code_block');

  SELECT u.id, u.email INTO v_usuario, v_email
    FROM auth.users u WHERE u.id = auth.uid();
  IF v_usuario IS NOT NULL THEN
    SELECT p.rol INTO v_rol FROM perfiles p WHERE p.id = v_usuario;
  END IF;

  INSERT INTO audit_logs (tabla, registro_id, accion, old_data, new_data, campos_modificados,
                          usuario_id, usuario_email, usuario_rol, sucursal_id)
  SELECT 'cliente_preventistas',
         f.cliente_id::text,
         TG_OP,
         f.o || jsonb_build_object('camino', x.camino),
         f.n || jsonb_build_object('camino', x.camino),
         CASE WHEN TG_OP = 'UPDATE' THEN
           ARRAY(SELECT k FROM jsonb_object_keys(COALESCE(f.n, f.o)) k WHERE f.o->k IS DISTINCT FROM f.n->k)
         END,
         v_usuario, v_email, v_rol,
         COALESCE(c.sucursal_id, current_sucursal_id())
    -- En un UPDATE que cambia la clave, el lado sin par viene como null de JSON.
    FROM (SELECT NULLIF(e->'o', 'null'::jsonb) AS o, NULLIF(e->'n', 'null'::jsonb) AS n,
                 COALESCE(e->'n'->>'cliente_id', e->'o'->>'cliente_id')::bigint AS cliente_id,
                 COALESCE(e->'n'->>'preventista_id', e->'o'->>'preventista_id')::uuid AS preventista_id
            FROM jsonb_array_elements(v_filas) e) f
    LEFT JOIN clientes c ON c.id = f.cliente_id
    LEFT JOIN perfiles p ON p.id = f.preventista_id
    -- Sin función en la pila: entró directo, o la borró una FK. Lo de una FK corre como
    -- parte de la sentencia de afuera, sin subir pg_trigger_depth(): se nota en que el
    -- cliente o el perfil ya no están.
    CROSS JOIN LATERAL (
      SELECT COALESCE(v_camino, CASE WHEN c.id IS NULL OR p.id IS NULL THEN 'cascada' ELSE 'directo' END) AS camino
    ) x;

  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.audit_cliente_preventistas() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER audit_cliente_preventistas_insert
  AFTER INSERT ON public.cliente_preventistas
  REFERENCING NEW TABLE AS filas_nuevas
  FOR EACH STATEMENT EXECUTE FUNCTION public.audit_cliente_preventistas();

CREATE TRIGGER audit_cliente_preventistas_update
  AFTER UPDATE ON public.cliente_preventistas
  REFERENCING OLD TABLE AS filas_viejas NEW TABLE AS filas_nuevas
  FOR EACH STATEMENT EXECUTE FUNCTION public.audit_cliente_preventistas();

CREATE TRIGGER audit_cliente_preventistas_delete
  AFTER DELETE ON public.cliente_preventistas
  REFERENCING OLD TABLE AS filas_viejas
  FOR EACH STATEMENT EXECUTE FUNCTION public.audit_cliente_preventistas();

DO $verif$
BEGIN
  IF has_function_privilege('anon', 'public.audit_cliente_preventistas()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.audit_cliente_preventistas()', 'EXECUTE') THEN
    RAISE EXCEPTION 'audit_cliente_preventistas quedó ejecutable por la app';
  END IF;
  IF (SELECT count(*) FROM pg_trigger t
       WHERE t.tgrelid = 'public.cliente_preventistas'::regclass
         AND t.tgfoid = 'public.audit_cliente_preventistas()'::regprocedure
         AND t.tgenabled = 'O') <> 3 THEN
    RAISE EXCEPTION 'faltan triggers de auditoría en cliente_preventistas';
  END IF;
END
$verif$;

COMMIT;
