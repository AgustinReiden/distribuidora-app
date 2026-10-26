-- SEG-A reconoce a _tablero_sucursales como guard de rol.
--
-- QUÉ PASABA
--   Desde el 2026-10-23 el gate nocturno de integridad está en rojo: SEG-A
--   (auditoria_definer_sin_rol, #1009) marca 9 funciones tablero_* como DEFINER
--   que authenticated ejecuta "sin guard de rol". Las crearon las migraciones
--   del tablero (tablero_clientes, tablero_categorias_por_nombre,
--   tablero_productos_eliminados), aplicadas directo al ledger.
--
-- POR QUÉ ES UN FALSO POSITIVO Y NO UN AGUJERO
--   Las 9 llaman a _tablero_sucursales(p_sucursal_id) antes de leer nada, y ese
--   helper corta con 'Acceso denegado' a quien no sea admin o encargado activo,
--   a quien no tenga sucursales asignadas y a quien pida una sucursal que no es
--   suya. El helper no tiene EXECUTE para authenticated. SEG-A es una heurística
--   de texto que busca helpers de rol por nombre (es_admin, get_mi_rol, ...) y
--   no conocía éste. tablero_contexto pasaba sólo porque nombra `rol` y
--   auth.uid() al armar el usuario; tablero_guardar_meta_cobertura, porque además
--   exige admin por su cuenta.
--   Lo prueba scripts/test-permisos-tablero.sql: preventista y transportista
--   reciben 'Acceso denegado' de las 9; admin las usa.
--
-- POR QUÉ HELPER Y NO LISTA BLANCA
--   La lista blanca exime un cuerpo (firma + md5): cada cambio a un tablero_*
--   volvería a poner el gate en rojo sin que haya nada roto, y una función nueva
--   del tablero también. Sumar el helper a la regex hace que cualquier tablero_*
--   que pase por _tablero_sucursales cuente como guardada, igual que las que
--   pasan por es_admin. Lo que NO ve (ya listado en la función): un helper
--   nombrado que no actúa (`PERFORM` en una rama que no corre).
--
-- Parche por ancla sobre la definición viva (molde de la 373 y la 376).

DO $sega$
DECLARE
  v_def  text := pg_get_functiondef('public.auditoria_definer_sin_rol()'::regprocedure);
  v_regex_viejo text := $q$_rol_en_sucursal|$q$;
  v_regex_nuevo text := $q$_rol_en_sucursal|\m_tablero_sucursales\M|$q$;
  v_coment_viejo text := $q$sin eso no puede ser el rol del que llama.$q$;
  v_coment_nuevo text := $q$sin eso no puede ser el rol del que llama.
    --     _tablero_sucursales cuenta como helper (mig 392): exige admin o
    --     encargado activo con la sucursal asignada, y authenticated no la ejecuta.$q$;
BEGIN
  IF (length(v_def) - length(replace(v_def, v_regex_viejo, ''))) / length(v_regex_viejo) <> 1 THEN
    RAISE EXCEPTION 'regex de SEG-A: el fragmento no aparece exactamente una vez: revisar a mano';
  END IF;
  IF (length(v_def) - length(replace(v_def, v_coment_viejo, ''))) / length(v_coment_viejo) <> 1 THEN
    RAISE EXCEPTION 'comentario de SEG-A: el fragmento no aparece exactamente una vez: revisar a mano';
  END IF;
  v_def := replace(v_def, v_regex_viejo, v_regex_nuevo);
  v_def := replace(v_def, v_coment_viejo, v_coment_nuevo);
  EXECUTE v_def;
END
$sega$;

REVOKE ALL ON FUNCTION public.auditoria_definer_sin_rol() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auditoria_definer_sin_rol() TO service_role;

DO $verif$
BEGIN
  -- El helper sólo es un guard si nadie de afuera lo puede llamar con otro uid.
  IF has_function_privilege('authenticated', 'public._tablero_sucursales(bigint)'::regprocedure, 'EXECUTE')
     OR has_function_privilege('anon', 'public._tablero_sucursales(bigint)'::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION '_tablero_sucursales es alcanzable por authenticated o anon';
  END IF;
  IF (SELECT count(*) FROM public.auditoria_definer_sin_rol()) <> 0 THEN
    RAISE EXCEPTION 'SEG-A no quedó en 0: %',
      (SELECT string_agg(firma || ' (' || motivo || ')', '; ') FROM public.auditoria_definer_sin_rol());
  END IF;
  IF has_function_privilege('authenticated', 'public.auditoria_definer_sin_rol()'::regprocedure, 'EXECUTE')
     OR has_function_privilege('anon', 'public.auditoria_definer_sin_rol()'::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'auditoria_definer_sin_rol quedó alcanzable por authenticated o anon';
  END IF;
END
$verif$;
