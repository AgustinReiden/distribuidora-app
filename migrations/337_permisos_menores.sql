-- #1074 · Permisos menores (encontrados en la verificación de #1048, #1056 y #1014)
--
-- 1 · avance_metas_preventista cruzaba sucursales. Un admin de una sola
--     sucursal leía el avance de un preventista de otra: la función sacaba las
--     sucursales de las metas del preventista y nunca las cruzaba con las del
--     que llama. Ahora, cuando un admin mira a OTRO, sólo cuentan las metas de
--     las sucursales que tiene asignadas en usuario_sucursales (el mismo cruce
--     que guardar_meta_preventista). El admin de varias sucursales sigue viendo
--     todo lo que veía; el propio preventista y el servicio (auth.uid() NULL),
--     todas sus metas. rendimiento_preventistas la llama con el JWT del admin,
--     así que hereda el cruce.
--
-- 2 · perfil_de_sucursal_activa(uuid) se queda como está. La usa la policy
--     perfiles_select_sucursal, que Postgres evalúa como el usuario: sin
--     EXECUTE para authenticated, leer perfiles falla entero (lo prueba el
--     ensayo). Y no es un oráculo: da true sólo para perfiles que esa misma
--     policy ya le muestra. Se justifica en la lista blanca de SEG-A.
--
-- 3 · pagos_forzar_usuario() es una función de trigger: la invoca el executor
--     como parte del INSERT, no el que llama, así que no necesita EXECUTE para
--     la app (CLAUDE.md). Queda para postgres y service_role.
--
-- 4 · Alta de proveedores para el encargado. Decisión del dueño (2026-10-09):
--     el encargado, que ya registra compras (#1014), puede dar de alta un
--     proveedor de su sucursal desde ModalCompra. Editar y borrar siguen
--     siendo del admin.
--
-- 5 · SEG-A (auditoria_definer_sin_rol). La lista blanca pasa a ser por firma
--     + md5 del cuerpo: si una función exceptuada cambia de cuerpo, vuelve a
--     salir en rojo hasta que alguien la revise y actualice el md5. Y se
--     documenta lo que el check no ve: los helpers permisivos (trampa 4) y lo
--     que el md5 no cubre.
--
-- El comportamiento lo prueba scripts/test-permisos-menores-1074.sql.

BEGIN;

CREATE OR REPLACE FUNCTION public._mig1074_ancla(
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
-- 1 · avance_metas_preventista: las sucursales del que llama.
-- ---------------------------------------------------------------------------
-- 1.a · Las sucursales que cuentan salen de las metas del preventista, ya
--       cruzadas con las del que llama. Todo lo demás se acota con ellas.
SELECT public._mig1074_ancla('public.avance_metas_preventista(uuid,date)'::regprocedure,
$ancla$    AND periodo <= v_mes_hasta AND periodo_fin >= v_mes_desde;

  IF v_sucursales IS NULL THEN$ancla$,
$nuevo$    AND periodo <= v_mes_hasta AND periodo_fin >= v_mes_desde
    -- #1074: un admin que mira a OTRO ve sólo las metas de las sucursales
    -- que tiene asignadas (el mismo cruce que guardar_meta_preventista). El
    -- servicio (auth.uid() NULL) y el propio preventista, todas.
    AND (auth.uid() IS NULL OR v_target = auth.uid()
         OR sucursal_id IN (SELECT us.sucursal_id FROM usuario_sucursales us
                             WHERE us.usuario_id = auth.uid()));

  IF v_sucursales IS NULL THEN$nuevo$);

-- 1.b · Las metas que se calculan.
SELECT public._mig1074_ancla('public.avance_metas_preventista(uuid,date)'::regprocedure,
$ancla$      AND periodo <= v_mes_hasta AND periodo_fin >= v_mes_desde
  ),$ancla$,
$nuevo$      AND periodo <= v_mes_hasta AND periodo_fin >= v_mes_desde
      AND sucursal_id = ANY(v_sucursales)  -- #1074
  ),$nuevo$);

-- 1.c · El aviso de productos sin marca.
SELECT public._mig1074_ancla('public.avance_metas_preventista(uuid,date)'::regprocedure,
$ancla$      AND marca_id IS NOT NULL
  ) INTO v_hay_marca;$ancla$,
$nuevo$      AND marca_id IS NOT NULL
      AND sucursal_id = ANY(v_sucursales)  -- #1074
  ) INTO v_hay_marca;$nuevo$);

-- El patch hace CREATE OR REPLACE, que conserva los grants; se reafirman.
REVOKE ALL ON FUNCTION public.avance_metas_preventista(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.avance_metas_preventista(uuid, date) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2 · perfil_de_sucursal_activa: se queda, con el motivo escrito.
-- ---------------------------------------------------------------------------
COMMENT ON FUNCTION public.perfil_de_sucursal_activa(uuid) IS
  'Helper de la policy perfiles_select_sucursal (mig 228). authenticated necesita EXECUTE: la policy se evalúa como el usuario, y sin él leer perfiles falla entero. No es un oráculo: da true sólo para perfiles que esa policy ya muestra (#1074).';

-- ---------------------------------------------------------------------------
-- 3 · pagos_forzar_usuario: función de trigger, sin EXECUTE para la app.
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.pagos_forzar_usuario() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pagos_forzar_usuario() TO service_role;

-- ---------------------------------------------------------------------------
-- 4 · Proveedores: el encargado da de alta en su sucursal.
-- ---------------------------------------------------------------------------
ALTER POLICY mt_proveedores_insert ON public.proveedores
  WITH CHECK (es_encargado_o_admin() AND sucursal_id = current_sucursal_id());

-- ---------------------------------------------------------------------------
-- 5 · SEG-A: lista blanca por firma + md5, y lo que no ve.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.auditoria_definer_sin_rol()
 RETURNS TABLE(firma text, motivo text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
  -- Heurística de texto, como STK-F y COSTO-D. Ver lo que NO ve al final.
  WITH f AS (
    SELECT p.oid::regprocedure::text AS firma,
           -- El cuerpo tal cual, para la lista blanca.
           md5(p.prosrc) AS hash,
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
  -- LISTA BLANCA DE A, por firma + md5 del cuerpo (#1074). Una entrada exime
  -- a ESE cuerpo: si la función cambia, vuelve a salir en rojo con el md5
  -- nuevo en el motivo. Revisá que el cambio no le abra nada a nadie y
  -- actualizá el md5 acá:
  --   SELECT md5(prosrc) FROM pg_proc WHERE oid = 'public.<firma>'::regprocedure;
  lista_blanca(firma, hash) AS (VALUES
    -- Sólo tocan filas del propio auth.uid().
    ('cambiar_sucursal(bigint)',                 '86322b98dc0aaef539dabe10e74bbc16'),  -- valida que la sucursal sea del caller
    ('marcar_notificacion_leida(bigint)',        '7c97357d2f443b1a88a7830f15e4d01a'),
    ('marcar_todas_notificaciones_leidas()',     '9812bdd67e61af81f4b39d3fc4279db1'),
    ('generar_codigo_vinculacion_bot()',         '88b3fc8263238a733dde6d9ab38e8134'),
    ('listar_visitas_hoy()',                     '2b01c13670d61b16ddcc89cacf3d65b0'),
    -- Helpers de RLS y de la sucursal activa del caller.
    ('current_sucursal_id()',                    '3a28cce558042e50d1f24eda2940c0d4'),  -- valida el header contra usuario_sucursales
    ('cliente_de_sucursal_activa(bigint)',       'f40cb2ef4e2c451a601d2030ec6196d8'),  -- booleano, policy de cliente_preventistas
    -- Booleano de la policy perfiles_select_sucursal, que se evalúa como el
    -- usuario: sin EXECUTE para authenticated, leer perfiles falla entero. Da
    -- true sólo para perfiles que esa policy ya muestra: no es un oráculo
    -- (#1074, lo prueba scripts/test-permisos-menores-1074.sql).
    ('perfil_de_sucursal_activa(uuid)',          'b17dcf26c7a9151592298c8d518f218a'),
    ('get_deposito_sucursal()',                  'ca9a2d0381ac96e1179d55e40f40b8ba'),  -- coordenadas de la sucursal activa
    ('get_destino_sucursal()',                   '6ae185df6f77096963e5d7f0b15ee2b5'),
    ('parametros_vencimiento()',                 '46629184d68b286d0f6fb8d0a73fa88e'),  -- días de alerta, sin montos
    -- Wrappers de idempotencia (mig 167): el rol lo exige el _impl, que no
    -- tiene EXECUTE para authenticated. Un replay del mismo
    -- client_request_id (uuid) devuelve el resultado guardado sin pasar por
    -- el _impl: es el de esa misma solicitud, ya autorizada.
    ('registrar_pago_cliente_fifo(bigint,numeric,text,date,text,text,uuid)',             '459a35102a5bd7b04395876dc1b540a5'),
    ('registrar_pago_combinado_cliente_fifo(bigint,jsonb,date,text,text,uuid)',          'd721b8f0c4041879cdcadc60577f5f3c'),
    ('marcar_pagos_masivo(bigint[],text,date,uuid)',                                     'b36709a92574c543ef6e221c4844ad33'),
    ('marcar_entrega_y_pago_masivo(bigint[],uuid,text,date,uuid)',                       '9c04d7bc15d261cd7a9d5c6564161db2'),
    ('imputar_credito_a_pedido(bigint,bigint,numeric,uuid)',                             '4c4e542cdc21d064aecaab6e41a14e0b'),
    ('crear_nota_credito_venta(bigint,bigint,jsonb,text,text,uuid)',                     'e1da42d326d89c58517baa6fd90381f6'),
    -- Delega en crear_pedido_completo, que exige admin/preventista/encargado.
    ('crear_pedido_idempotente(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid,text)',
                                                 'b375b77581cff72ce7aff8ad9ce8ce24'),
    -- Booleano / fecha de cierre de caja, sin montos. Las usa el front para
    -- la fecha mínima de un pago, y pagos_guard_anulacion_caja_cerrada (un
    -- trigger INVOKER) llama a ultima_fecha_caja_cerrada como el usuario:
    -- revocarla rompería borrar pagos.
    ('rendicion_dia_cerrada(date,bigint)',       'b3434c512abbe0187f20056b94ead40e'),
    ('ultima_fecha_caja_cerrada(bigint)',        '9528437b731a1dfc3d16acedf10f8bc2')
  ),
  hallazgos AS (
    -- A · Sin guard de rol. Los helpers de rol (trampa 4 de CLAUDE.md:
    --     es_preventista() y es_transportista() dejan pasar a otros roles;
    --     nombrarlos cuenta como guard para este check, pero no lo hace
    --     correcto). La palabra `rol` cuenta sólo si el cuerpo mira auth.uid():
    --     sin eso no puede ser el rol del que llama.
    SELECT f.firma,
           CASE WHEN EXISTS (SELECT 1 FROM lista_blanca lb WHERE lb.firma = f.firma)
                THEN 'sin guard de rol: está en la lista blanca pero el cuerpo cambió (md5 '
                     || f.hash || '); revisarla y actualizar el md5'
                ELSE 'sin guard de rol'
           END AS motivo
      FROM f
     WHERE NOT (src ~* '(\mes_admin|\mes_encargado_o_admin|\mes_preventista|\mes_transportista|\mget_mi_rol|\mget_user_role|\mtiene_rol_extra|_rol_en_sucursal|\mpuede_leer_pedido|\mperfil_roles\M)'
                OR (src ~* '\mrol\M' AND src ~* '\mauth\.uid\s*\(\s*\)'))
       AND NOT EXISTS (SELECT 1 FROM lista_blanca lb
                        WHERE lb.firma = f.firma AND lb.hash = f.hash)
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
  --   · Helpers permisivos (trampa 4 de CLAUDE.md). es_preventista() da true
  --     también para admin y encargado (y para el rol extra de perfil_roles);
  --     es_transportista(), para admin. Nombrarlos cuenta como guard, así que
  --     una función que debería ser SÓLO de preventistas y se cuida con
  --     `IF NOT es_preventista()` pasa limpia aunque deje entrar a otros.
  --   · La lista blanca exime un cuerpo (firma + md5 de prosrc), no una
  --     conducta. No mira lo que la función llama: si un wrapper exceptuado
  --     delega en un _impl u otra función y ESA cambia, la excepción sigue
  --     valiendo. Tampoco cubre lo que está fuera del cuerpo: SECURITY
  --     DEFINER, el search_path, los grants.
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
  --     con las asignadas (#982, #1074) pasa limpio.
$function$;

COMMENT ON FUNCTION public.auditoria_definer_sin_rol() IS
  'Check SEG-A (#1009, reforzado en #1048 y #1074): DEFINER de public que authenticated ejecuta sin guard de rol (fuera de una lista blanca por firma + md5 del cuerpo), con el rol leído de un parámetro uuid sin validar contra auth.uid(), o con un guard muerto sobre current_user. Cero o rojo. Lo que no ve está comentado en el cuerpo.';

-- ---------------------------------------------------------------------------
-- 6 · Verificación. El comportamiento lo prueba scripts/test-permisos-menores-1074.sql.
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  v_n int;
BEGIN
  -- 3 · El trigger, sólo para el servidor.
  IF has_function_privilege('authenticated', 'public.pagos_forzar_usuario()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.pagos_forzar_usuario()', 'EXECUTE') THEN
    RAISE EXCEPTION '#1074 · pagos_forzar_usuario sigue ejecutable por authenticated o anon';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.pagos_forzar_usuario()', 'EXECUTE') THEN
    RAISE EXCEPTION '#1074 · pagos_forzar_usuario quedó sin EXECUTE para service_role';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgfoid = 'public.pagos_forzar_usuario()'::regprocedure
                    AND tgrelid = 'public.pagos'::regclass AND tgenabled = 'O') THEN
    RAISE EXCEPTION '#1074 · trg_pagos_forzar_usuario no está activo';
  END IF;

  -- 1 y 2 · Las RPCs de la app siguen para authenticated y no para anon.
  IF NOT has_function_privilege('authenticated', 'public.avance_metas_preventista(uuid,date)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.avance_metas_preventista(uuid,date)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.perfil_de_sucursal_activa(uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.perfil_de_sucursal_activa(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION '#1074 · avance_metas_preventista / perfil_de_sucursal_activa con grants inesperados';
  END IF;
  IF pg_get_functiondef('public.avance_metas_preventista(uuid,date)'::regprocedure) !~ 'usuario_sucursales' THEN
    RAISE EXCEPTION '#1074 · avance_metas_preventista no cruza con usuario_sucursales';
  END IF;

  -- 4 · La policy de alta.
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE schemaname = 'public' AND tablename = 'proveedores'
                    AND policyname = 'mt_proveedores_insert'
                    AND with_check ~ 'es_encargado_o_admin\(\)'
                    AND with_check ~ 'current_sucursal_id\(\)') THEN
    RAISE EXCEPTION '#1074 · mt_proveedores_insert no quedó como se esperaba';
  END IF;

  -- 5 · SEG-A en cero: todos los md5 de la lista blanca coinciden con prod.
  SELECT count(*) INTO v_n FROM public.auditoria_definer_sin_rol();
  IF v_n <> 0 THEN
    RAISE EXCEPTION '#1074 · SEG-A no está en cero: %',
      (SELECT string_agg(firma || ' — ' || motivo, E'\n') FROM public.auditoria_definer_sin_rol());
  END IF;
END
$verif$;

DROP FUNCTION public._mig1074_ancla(regprocedure, text, text);

COMMIT;
