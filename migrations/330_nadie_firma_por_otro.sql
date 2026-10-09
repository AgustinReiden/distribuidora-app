-- #1048 · Nadie firma por otro: guards que no protegían
--
-- 1 · SUPLANTAR A UN ADMIN (grave). `registrar_ingreso_sucursal` y
--     `registrar_transferencia` son SECURITY DEFINER, `authenticated` las
--     ejecutaba, y leían el rol así:
--
--       SELECT rol INTO v_user_role FROM perfiles WHERE id = COALESCE(p_usuario_id, auth.uid());
--
--     sin comparar `p_usuario_id` con `auth.uid()`. Un preventista ve los uuids
--     de su sucursal (perfiles_select_sucursal): pasando el de un admin subía o
--     bajaba `productos.stock` de cualquier producto de la sucursal activa, y el
--     movimiento quedaba firmado por el admin.
--
--     Nadie las llama: ni `src/` (useTransferenciasQuery las deja "como
--     histórico"), ni `supabase/functions/`, ni otra función de la base, ni un
--     cron (no hay pg_cron). Se revocan a las tres mitades. No se borran: las
--     cinco transferencias de `transferencias_stock` salieron de ahí y el
--     código sigue siendo la referencia.
--
--     ¿Hubo abuso? No (verificado en prod el 2026-10-09, sólo lectura).
--     pg_stat_statements (desde 2025-12-26) registra 5 llamadas por PostgREST a
--     `registrar_transferencia` y 0 a `registrar_ingreso_sucursal`.
--     `transferencias_stock` tiene 5 filas (la secuencia va por 5), todas con
--     `usuario_id` de Virginia H (admin), y en cada una el `audit_logs` de los
--     `productos` tocados —que guarda el `auth.uid()` REAL de la sesión, no el
--     parámetro— dice el mismo uuid. No hay ningún ingreso de sucursal.
--
-- 2 · GUARD QUE NUNCA SE EJECUTA. `cerrar_recorridos_vencidos` preguntaba
--     `current_user = 'authenticated'`; adentro de una DEFINER `current_user` es
--     el dueño (postgres), así que la condición era siempre falsa y cualquier
--     logueado cerraba recorridos de cualquier sucursal. Nadie la llama
--     (pg_stat_statements: 0 llamadas): se revoca a las tres mitades y el guard
--     pasa a mirar `auth.uid()`, por si algún día se vuelve a conceder.
--
-- 3 · ROL NULL. `registrar_geolocalizacion_pedido` hacía
--     `... AND v_user_role <> 'admin'`: con rol NULL da NULL y deja pasar. Hoy no
--     se alcanza (un perfil sin fila no tiene sucursal activa, y la función
--     exige la del pedido), pero el guard tiene que decir lo que quiere decir.
--
-- 4 · COMISIONES ENTRE SUCURSALES. Los admins NO ven toda la red (Pablo y
--     Julio sólo Taco Pozo; Virginia, Emilia y Nacho sólo Tucumán). Decisión
--     del dueño (2026-10-09):
--       · una regla de comisión nace atada a la sucursal activa (la manda el
--         front de este mismo PR; hasta que se despliegue, el modal sigue
--         mandando NULL: un admin de una sola sucursal recibe 42501 al agregar
--         una regla y uno de toda la red la crea global. Hoy hay 0 reglas);
--         un admin sólo crea, edita o da de baja reglas de sus
--         sucursales; una regla GLOBAL (sucursal NULL), que rige en todas, sólo
--         la toca un admin asignado a todas las sucursales activas;
--       · `calcular_comisiones` sólo calcula sobre sucursales asignadas al
--         admin. Pedir una ajena es 42501 (el molde de #982); sin sucursales
--         asignadas también (antes veía TODAS).
--     La lectura de `comision_reglas` por REST queda en las globales y las de
--     la sucursal activa.
--
-- 5 · EL GATE. SEG-A (auditoria_definer_sin_rol) se dejaba engañar por la
--     palabra "rol" y por un guard que no se ejecuta. Ahora:
--       · lee el cuerpo SIN comentarios (un helper nombrado en un comentario no
--         es un guard);
--       · la palabra `rol` cuenta como guard sólo si el cuerpo también mira
--         `auth.uid()` (si no, no puede ser el rol del que llama);
--       · marca la suplantación: el rol se lee de perfiles con
--         `COALESCE(<param uuid>, auth.uid())`, o con `id = p_usuario_id`, y el
--         parámetro nunca se compara con `auth.uid()`;
--       · marca el guard muerto: `current_user`/`current_role`/`session_user`
--         comparado con 'authenticated' o 'anon' adentro de una DEFINER.
--     Devuelve también el motivo. Lo que sigue sin ver está escrito en la
--     función, al lado del código.

BEGIN;

-- ---------------------------------------------------------------------------
-- 0 · Andamio: parche por ancla, con la guarda de "exactamente una vez".
--     El mismo de las migs 257, 300 y 314. Si otra sesión cambió el cuerpo
--     vivo, el ancla no aparece y la migración falla en vez de pisar el cambio.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._mig1048_ancla(
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
-- 1 · Las que dejaban suplantar a un admin: sin EXECUTE para la app.
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.registrar_ingreso_sucursal(bigint, date, text, numeric, uuid, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.registrar_transferencia(bigint, date, text, numeric, uuid, jsonb)    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_ingreso_sucursal(bigint, date, text, numeric, uuid, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.registrar_transferencia(bigint, date, text, numeric, uuid, jsonb)    TO service_role;

-- ---------------------------------------------------------------------------
-- 2 · cerrar_recorridos_vencidos: revocada, y con un guard que se ejecuta.
--     auth.uid() es NULL para service_role (el único que la conserva) y no
--     NULL para cualquier sesión de la app.
-- ---------------------------------------------------------------------------
SELECT public._mig1048_ancla('public.cerrar_recorridos_vencidos(bigint)'::regprocedure,
$ancla$  IF current_user = 'authenticated' AND NOT es_encargado_o_admin() THEN$ancla$,
$nuevo$  -- #1048: `current_user` adentro de una DEFINER es el dueño, nunca
  -- 'authenticated'. Lo que distingue a una sesión de la app es auth.uid().
  IF auth.uid() IS NOT NULL AND NOT es_encargado_o_admin() THEN$nuevo$);

REVOKE ALL ON FUNCTION public.cerrar_recorridos_vencidos(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerrar_recorridos_vencidos(bigint) TO service_role;

-- ---------------------------------------------------------------------------
-- 3 · registrar_geolocalizacion_pedido: el rol NULL no pasa por admin.
-- ---------------------------------------------------------------------------
SELECT public._mig1048_ancla('public.registrar_geolocalizacion_pedido(bigint,text,numeric,numeric,numeric,timestamp with time zone,text)'::regprocedure,
$ancla$  IF v_pedido.usuario_id IS DISTINCT FROM v_user_id AND v_user_role <> 'admin' THEN$ancla$,
$nuevo$  -- #1048: con `<>` un rol NULL daba NULL y dejaba pasar.
  IF v_pedido.usuario_id IS DISTINCT FROM v_user_id AND v_user_role IS DISTINCT FROM 'admin' THEN$nuevo$);

-- ---------------------------------------------------------------------------
-- 4 · Comisiones: cada admin, lo de sus sucursales.
-- ---------------------------------------------------------------------------

-- 4.1 · ¿El que llama puede tocar una regla de esta sucursal? Una regla con
--       sucursal rige sólo ahí: alcanza con tenerla asignada. Una regla global
--       (NULL) rige en todas: hay que tener asignadas todas las activas.
--       INVOKER y sin EXECUTE para la app: la llaman las DEFINER de abajo, que
--       corren como el dueño y ven el auth.uid() de la sesión igual.
CREATE OR REPLACE FUNCTION public.comision_regla_alcanzable(p_sucursal_id bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $fn$
  SELECT CASE
    WHEN p_sucursal_id IS NULL THEN
      NOT EXISTS (
        SELECT 1 FROM sucursales s
         WHERE COALESCE(s.activa, true)
           AND NOT EXISTS (SELECT 1 FROM usuario_sucursales us
                            WHERE us.usuario_id = auth.uid() AND us.sucursal_id = s.id))
    ELSE
      EXISTS (SELECT 1 FROM usuario_sucursales us
               WHERE us.usuario_id = auth.uid() AND us.sucursal_id = p_sucursal_id)
  END;
$fn$;

COMMENT ON FUNCTION public.comision_regla_alcanzable(bigint) IS
  '#1048: true si el auth.uid() tiene asignada la sucursal de la regla, o todas las activas si la regla es global (NULL).';

REVOKE ALL ON FUNCTION public.comision_regla_alcanzable(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.comision_regla_alcanzable(bigint) TO service_role;

-- 4.2 · guardar_comision_regla: la sucursal nueva y, al editar, la que la regla
--       ya tenía. Sin lo segundo, un admin de Taco Pozo movía a su sucursal una
--       regla de Tucumán (y la borraba de allá).
SELECT public._mig1048_ancla('public.guardar_comision_regla(bigint,bigint,uuid,text,numeric,date,date,bigint,uuid)'::regprocedure,
$ancla$    RAISE EXCEPTION 'Solo un admin puede definir reglas de comision' USING ERRCODE = '42501';
  END IF;$ancla$,
$nuevo$    RAISE EXCEPTION 'Solo un admin puede definir reglas de comision' USING ERRCODE = '42501';
  END IF;

  -- #1048: los admins no ven toda la red. Una regla con sucursal es de esa
  -- sucursal; una global rige en todas y sólo la toca quien las tiene todas.
  IF NOT comision_regla_alcanzable(p_sucursal_id) THEN
    RAISE EXCEPTION '%', CASE WHEN p_sucursal_id IS NULL
        THEN 'Una regla para todas las sucursales sólo la puede definir un admin asignado a todas'
        ELSE format('No tenés asignada la sucursal %s', p_sucursal_id) END
      USING ERRCODE = '42501';
  END IF;
  IF p_id IS NOT NULL AND EXISTS (
       SELECT 1 FROM comision_reglas r
        WHERE r.id = p_id AND NOT comision_regla_alcanzable(r.sucursal_id)) THEN
    RAISE EXCEPTION 'La regla % es de una sucursal que no tenés asignada', p_id
      USING ERRCODE = '42501';
  END IF;$nuevo$);

-- 4.3 · desactivar_comision_regla: la misma vara.
SELECT public._mig1048_ancla('public.desactivar_comision_regla(bigint)'::regprocedure,
$ancla$  UPDATE comision_reglas SET activo = false WHERE id = p_id;$ancla$,
$nuevo$  -- #1048: sólo reglas de sucursales asignadas (o globales, si las tiene todas).
  IF EXISTS (SELECT 1 FROM comision_reglas r
              WHERE r.id = p_id AND NOT comision_regla_alcanzable(r.sucursal_id)) THEN
    RAISE EXCEPTION 'La regla % es de una sucursal que no tenés asignada', p_id
      USING ERRCODE = '42501';
  END IF;
  UPDATE comision_reglas SET activo = false WHERE id = p_id;$nuevo$);

-- 4.4 · calcular_comisiones: las sucursales pedidas tienen que ser asignadas.
--       NULL o vacío = las asignadas (lo que hace el reporte en modo red). Antes,
--       sin asignadas caía a TODAS las sucursales.
SELECT public._mig1048_ancla('public.calcular_comisiones(date,date,bigint[])'::regprocedure,
$ancla$  v_sucursales := COALESCE(
    p_sucursal_ids,
    ARRAY(SELECT sucursal_id FROM usuario_sucursales WHERE usuario_id = auth.uid())
  );
  IF v_sucursales IS NULL OR array_length(v_sucursales, 1) IS NULL THEN
    v_sucursales := ARRAY(SELECT id FROM sucursales);
  END IF;$ancla$,
$nuevo$  -- #1048 (molde de #982): un admin calcula sólo sobre sus sucursales.
  v_sucursales := ARRAY(SELECT sucursal_id FROM usuario_sucursales WHERE usuario_id = auth.uid());
  IF array_length(v_sucursales, 1) IS NULL THEN
    RAISE EXCEPTION 'Acceso denegado: el usuario no tiene sucursales asignadas'
      USING ERRCODE = '42501';
  END IF;
  IF array_length(p_sucursal_ids, 1) IS NOT NULL THEN
    IF NOT (p_sucursal_ids <@ v_sucursales) THEN
      RAISE EXCEPTION 'Acceso denegado: pediste sucursales que no tenés asignadas'
        USING ERRCODE = '42501';
    END IF;
    v_sucursales := p_sucursal_ids;
  END IF;$nuevo$);

-- 4.5 · La lectura por REST: las globales y las de la sucursal activa. Las
--       DEFINER (calcular_comisiones) no pasan por acá.
DROP POLICY IF EXISTS comision_reglas_admin_select ON public.comision_reglas;
CREATE POLICY comision_reglas_admin_select ON public.comision_reglas
  FOR SELECT TO authenticated
  USING (es_admin() AND (sucursal_id IS NULL OR sucursal_id = current_sucursal_id()));

-- ---------------------------------------------------------------------------
-- 5 · El gate: SEG-A reforzado. Cambia el tipo de salida (suma `motivo`), así
--     que se recrea. auditoria_integridad() sólo cuenta filas.
-- ---------------------------------------------------------------------------
DROP FUNCTION public.auditoria_definer_sin_rol();

CREATE FUNCTION public.auditoria_definer_sin_rol()
RETURNS TABLE(firma text, motivo text)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $fn$
  -- Heurística de texto, como STK-F y COSTO-D. Ver lo que NO ve al final.
  WITH f AS (
    SELECT p.oid::regprocedure::text AS firma,
           -- Sin comentarios: un helper o un "rol" nombrado en un comentario
           -- no es un guard.
           regexp_replace(regexp_replace(p.prosrc, '/\*.*?\*/', ' ', 'g'), '--[^\n]*', ' ', 'g') AS src,
           -- Los parámetros uuid de entrada, por nombre.
           COALESCE(ARRAY(
             SELECT a.n
               FROM unnest(p.proargnames[1:p.pronargs], p.proargtypes::oid[]) AS a(n, t)
              WHERE a.t = 'uuid'::regtype AND a.n IS NOT NULL AND a.n <> ''), '{}') AS uargs
      FROM pg_proc p
      JOIN pg_type t ON t.oid = p.prorettype
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.prokind = 'f'
       AND p.prosecdef
       AND t.typname <> 'trigger'
       AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
       AND NOT EXISTS (
         SELECT 1 FROM pg_depend d
          WHERE d.classid = 'pg_proc'::regclass
            AND d.objid = p.oid
            AND d.deptype = 'e')
  ),
  hallazgos AS (
    -- A · Sin guard de rol. Los helpers de rol (trampa 4 de CLAUDE.md:
    --     es_preventista() y es_transportista() dejan pasar a otros roles;
    --     nombrarlos cuenta como guard para este check, pero no lo hace
    --     correcto). La palabra `rol` cuenta sólo si el cuerpo mira auth.uid():
    --     sin eso no puede ser el rol del que llama.
    SELECT firma, 'sin guard de rol' AS motivo
      FROM f
     WHERE NOT (src ~* '(\mes_admin|\mes_encargado_o_admin|\mes_preventista|\mes_transportista|\mget_mi_rol|\mget_user_role|\mtiene_rol_extra|_rol_en_sucursal|\mpuede_leer_pedido|\mperfil_roles\M)'
                OR (src ~* '\mrol\M' AND src ~* '\mauth\.uid\s*\(\s*\)'))
       AND firma NOT IN (
         -- Sólo tocan filas del propio auth.uid().
         'cambiar_sucursal(bigint)',                 -- valida que la sucursal sea del caller
         'marcar_notificacion_leida(bigint)',
         'marcar_todas_notificaciones_leidas()',
         'generar_codigo_vinculacion_bot()',
         'listar_visitas_hoy()',
         -- Helpers de RLS y de la sucursal activa del caller.
         'current_sucursal_id()',                    -- valida el header contra usuario_sucursales
         'cliente_de_sucursal_activa(bigint)',        -- booleano, policy de cliente_preventistas
         'perfil_de_sucursal_activa(uuid)',           -- booleano, policy de perfiles
         'get_deposito_sucursal()',                   -- coordenadas de la sucursal activa
         'get_destino_sucursal()',
         'parametros_vencimiento()',                  -- días de alerta, sin montos
         -- Wrappers de idempotencia (mig 167): el rol lo exige el _impl, que no
         -- tiene EXECUTE para authenticated. Un replay del mismo
         -- client_request_id (uuid) devuelve el resultado guardado sin pasar por
         -- el _impl: es el de esa misma solicitud, ya autorizada.
         'registrar_pago_cliente_fifo(bigint,numeric,text,date,text,text,uuid)',
         'registrar_pago_combinado_cliente_fifo(bigint,jsonb,date,text,text,uuid)',
         'marcar_pagos_masivo(bigint[],text,date,uuid)',
         'marcar_entrega_y_pago_masivo(bigint[],uuid,text,date,uuid)',
         'imputar_credito_a_pedido(bigint,bigint,numeric,uuid)',
         'crear_nota_credito_venta(bigint,bigint,jsonb,text,text,uuid)',
         -- Delega en crear_pedido_completo, que exige admin/preventista/encargado.
         'crear_pedido_idempotente(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid,text)',
         -- Booleano / fecha de cierre de caja, sin montos. Las usa el front para
         -- la fecha mínima de un pago, y pagos_guard_anulacion_caja_cerrada (un
         -- trigger INVOKER) llama a ultima_fecha_caja_cerrada como el usuario:
         -- revocarla rompería borrar pagos.
         'rendicion_dia_cerrada(date,bigint)',
         'ultima_fecha_caja_cerrada(bigint)'
       )
    UNION ALL
    -- B · Suplantación (#1048): el rol se lee de perfiles con un uuid que pasa
    --     el que llama —COALESCE(p_x, auth.uid()), o `id = p_usuario_id`— y ese
    --     parámetro nunca se compara con auth.uid() ni se pisa con él. La lista
    --     blanca de A no exime de esto.
    SELECT firma, 'el rol sale de un parámetro: ' || u
      FROM f, unnest(f.uargs) AS u
     WHERE (src ~* ('\mperfiles\M[^;]*\mcoalesce\s*\(\s*' || u || '\s*,\s*auth\.uid\s*\(\s*\)')
            OR (u = 'p_usuario_id' AND src ~* '\mperfiles\M[^;]*\mid\s*=\s*p_usuario_id\M'))
       AND src !~* ('\m' || u || '\s*(IS\s+DISTINCT\s+FROM|<>|!=)\s*auth\.uid\s*\(\s*\)')
       AND src !~* ('\mauth\.uid\s*\(\s*\)\s*(IS\s+DISTINCT\s+FROM|<>|!=)\s*' || u || '\M')
       AND src !~* ('\m' || u || '\s*:=\s*auth\.uid\s*\(\s*\)')
    UNION ALL
    -- C · Guard muerto (#1048): adentro de una DEFINER `current_user` es el
    --     dueño, nunca 'authenticated' ni 'anon'. Un IF que lo pregunta no se
    --     ejecuta (o se ejecuta siempre). Los triggers INVOKER que lo usan bien
    --     no entran acá: no son DEFINER.
    SELECT firma, 'guard muerto: compara current_user con un rol de la app'
      FROM f
     WHERE src ~* '\m(current_user|current_role|session_user)\M\s*(=|<>|!=|IN\s*\(|IS\s+(NOT\s+)?DISTINCT\s+FROM)\s*\(?\s*''(authenticated|anon)'''
  )
  SELECT firma, string_agg(motivo, '; ' ORDER BY motivo)
    FROM hallazgos
   GROUP BY firma
   ORDER BY firma;

  -- LO QUE NO VE (es texto, no ejecución):
  --   · Un guard que nombra el helper pero no actúa: `PERFORM es_admin()`, un
  --     `OR true` en la condición, el IF en una rama que nunca corre.
  --   · Comparaciones de rol que dejan pasar NULL: `v_rol <> 'admin'`,
  --     `v_rol NOT IN (...)` sin `IS NULL OR` delante. Hoy no son alcanzables
  --     (perfiles.rol es NOT NULL y sin perfil no hay sucursal activa).
  --   · Suplantación con otro nombre de parámetro (p_perfil_id, p_admin...) sin
  --     COALESCE, o con el rol pedido a un helper que recibe el parámetro
  --     (`_rol_en_sucursal(p_x, ...)`).
  --   · Suplantación por una variable intermedia
  --     (`v := COALESCE(p_x, auth.uid()); SELECT rol FROM perfiles WHERE id = v`):
  --     B pide perfiles y el COALESCE en la misma sentencia.
  --   · Una validación que no corta: B se da por satisfecho con CUALQUIER
  --     comparación o asignación entre el parámetro y auth.uid(), aunque esté
  --     después de la lectura del rol o no lleve a un RAISE/RETURN.
  --   · El guard muerto escrito al revés (`'authenticated' = current_user`) o
  --     con cast (`current_user::text = ...`).
  --   · Un `--` o un `/*` adentro de un literal: el corte de comentarios no
  --     entiende strings (hoy el único caso, `' -- '` en
  --     cancelar_pedido_con_stock, no esconde ningún guard).
  --   · SQL dinámico (EXECUTE format(...)).
  --   · La sucursal: un guard de rol correcto que no cruza la sucursal pedida
  --     con las asignadas (#982) pasa limpio.
$fn$;

COMMENT ON FUNCTION public.auditoria_definer_sin_rol() IS
  'Check SEG-A (#1009, reforzado en #1048): DEFINER de public que authenticated ejecuta sin guard de rol, con el rol leído de un parámetro uuid sin validar contra auth.uid(), o con un guard muerto sobre current_user. Cero o rojo. Lo que no ve está comentado en el cuerpo.';

REVOKE ALL ON FUNCTION public.auditoria_definer_sin_rol() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auditoria_definer_sin_rol() TO service_role;

-- ---------------------------------------------------------------------------
-- 6 · Verificación estructural. El comportamiento por rol lo prueba
--     scripts/test-suplantar-admin-1048.sql.
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  v_fn    text;
  v_lista text;
BEGIN
  -- 6.1 · Revocadas: ni authenticated ni anon; service_role sí.
  FOREACH v_fn IN ARRAY ARRAY[
    'public.registrar_ingreso_sucursal(bigint,date,text,numeric,uuid,jsonb)',
    'public.registrar_transferencia(bigint,date,text,numeric,uuid,jsonb)',
    'public.cerrar_recorridos_vencidos(bigint)',
    'public.comision_regla_alcanzable(bigint)',
    'public.auditoria_definer_sin_rol()'
  ] LOOP
    IF has_function_privilege('authenticated', v_fn, 'EXECUTE')
       OR has_function_privilege('anon', v_fn, 'EXECUTE') THEN
      RAISE EXCEPTION '#1048 · % sigue ejecutable por authenticated o anon', v_fn;
    END IF;
    IF NOT has_function_privilege('service_role', v_fn, 'EXECUTE') THEN
      RAISE EXCEPTION '#1048 · % quedó sin EXECUTE para service_role', v_fn;
    END IF;
  END LOOP;

  -- 6.2 · Las que el front llama conservan su EXECUTE, y anon sigue afuera.
  FOREACH v_fn IN ARRAY ARRAY[
    'public.registrar_geolocalizacion_pedido(bigint,text,numeric,numeric,numeric,timestamp with time zone,text)',
    'public.guardar_comision_regla(bigint,bigint,uuid,text,numeric,date,date,bigint,uuid)',
    'public.desactivar_comision_regla(bigint)',
    'public.calcular_comisiones(date,date,bigint[])'
  ] LOOP
    IF NOT has_function_privilege('authenticated', v_fn, 'EXECUTE') THEN
      RAISE EXCEPTION '#1048 · % perdió el EXECUTE de authenticated', v_fn;
    END IF;
    IF has_function_privilege('anon', v_fn, 'EXECUTE') THEN
      RAISE EXCEPTION '#1048 · % quedó ejecutable por anon', v_fn;
    END IF;
  END LOOP;

  -- 6.3 · SEG-A en cero.
  SELECT string_agg(firma || ' (' || motivo || ')', ', ') INTO v_lista
    FROM public.auditoria_definer_sin_rol();
  IF v_lista IS NOT NULL THEN
    RAISE EXCEPTION '#1048 · SEG-A no está en cero: %', v_lista;
  END IF;
  IF (SELECT count(*) FROM jsonb_array_elements(public.auditoria_integridad() -> 'checks') c
       WHERE c->>'id' = 'SEG-A') <> 1 THEN
    RAISE EXCEPTION '#1048 · SEG-A no aparece una vez en auditoria_integridad()';
  END IF;

  -- 6.4 · El check muerde. Cada canario se deshace solo con un SQLSTATE
  --       centinela. Los que tienen que aparecer:
  --       (a) el molde exacto del bug: el rol de COALESCE(p_usuario_id, auth.uid())
  BEGIN
    CREATE FUNCTION public._canario_seg_a(p_usuario_id uuid) RETURNS boolean
      LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
      AS $c$
      DECLARE v_user_role text;
      BEGIN
        SELECT rol INTO v_user_role FROM perfiles WHERE id = COALESCE(p_usuario_id, auth.uid());
        RETURN v_user_role IS NOT NULL AND v_user_role IN ('admin', 'encargado');
      END $c$;
    GRANT EXECUTE ON FUNCTION public._canario_seg_a(uuid) TO authenticated;
    IF NOT EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol()
                    WHERE firma = '_canario_seg_a(uuid)' AND motivo LIKE '%parámetro: p_usuario_id%') THEN
      RAISE EXCEPTION '#1048 · SEG-A no detecta el rol leído de COALESCE(p_usuario_id, auth.uid())';
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  --       (b) el guard muerto de cerrar_recorridos_vencidos
  BEGIN
    CREATE FUNCTION public._canario_seg_a() RETURNS int
      LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
      AS $c$
      BEGIN
        IF current_user = 'authenticated' AND NOT es_encargado_o_admin() THEN
          RAISE EXCEPTION 'no';
        END IF;
        RETURN 1;
      END $c$;
    GRANT EXECUTE ON FUNCTION public._canario_seg_a() TO authenticated;
    IF NOT EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol()
                    WHERE firma = '_canario_seg_a()' AND motivo LIKE 'guard muerto%') THEN
      RAISE EXCEPTION '#1048 · SEG-A no detecta un guard sobre current_user adentro de una DEFINER';
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  --       (c) el helper nombrado sólo en un comentario
  BEGIN
    CREATE FUNCTION public._canario_seg_a() RETURNS int
      LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
      AS $c$ /* es_admin() */ SELECT 1 -- rol auth.uid()
      $c$;
    GRANT EXECUTE ON FUNCTION public._canario_seg_a() TO authenticated;
    IF NOT EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol()
                    WHERE firma = '_canario_seg_a()' AND motivo = 'sin guard de rol') THEN
      RAISE EXCEPTION '#1048 · SEG-A acepta un helper que sólo aparece en un comentario';
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  --       (d) la palabra `rol` sin auth.uid(): no es el rol del que llama
  BEGIN
    CREATE FUNCTION public._canario_seg_a() RETURNS bigint
      LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
      AS $c$ SELECT count(*) FROM perfiles WHERE rol = 'admin' $c$;
    GRANT EXECUTE ON FUNCTION public._canario_seg_a() TO authenticated;
    IF NOT EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol()
                    WHERE firma = '_canario_seg_a()' AND motivo = 'sin guard de rol') THEN
      RAISE EXCEPTION '#1048 · SEG-A acepta la palabra rol sin auth.uid()';
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  --       Y los que NO tienen que aparecer:
  --       (e) el mismo molde, con el parámetro validado contra auth.uid()
  BEGIN
    CREATE FUNCTION public._canario_seg_a(p_usuario_id uuid) RETURNS boolean
      LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
      AS $c$
      DECLARE v_user_role text;
      BEGIN
        IF p_usuario_id IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'no'; END IF;
        SELECT rol INTO v_user_role FROM perfiles WHERE id = COALESCE(p_usuario_id, auth.uid());
        RETURN v_user_role IS NOT NULL AND v_user_role IN ('admin', 'encargado');
      END $c$;
    GRANT EXECUTE ON FUNCTION public._canario_seg_a(uuid) TO authenticated;
    IF EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol()
                WHERE firma = '_canario_seg_a(uuid)') THEN
      RAISE EXCEPTION '#1048 · SEG-A marca una función que valida el parámetro contra auth.uid()';
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  --       (f) el guard bien hecho, sobre auth.uid()
  BEGIN
    CREATE FUNCTION public._canario_seg_a() RETURNS int
      LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
      AS $c$
      BEGIN
        IF auth.uid() IS NOT NULL AND NOT es_encargado_o_admin() THEN RAISE EXCEPTION 'no'; END IF;
        RETURN 1;
      END $c$;
    GRANT EXECUTE ON FUNCTION public._canario_seg_a() TO authenticated;
    IF EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol()
                WHERE firma = '_canario_seg_a()') THEN
      RAISE EXCEPTION '#1048 · SEG-A marca un guard correcto sobre auth.uid()';
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;
END
$verif$;

DROP FUNCTION public._mig1048_ancla(regprocedure, text, text);

COMMIT;
