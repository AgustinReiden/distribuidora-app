-- SEG-A · generar_codigo_vinculacion_bot: la lista blanca toma el cuerpo de la 422.
--
-- La 422 (#1311) le agregó el rechazo a quien un admin le apagó el bot, y SEG-A
-- (auditoria_definer_sin_rol) la sacó de la lista blanca, que exime por md5 del
-- cuerpo. SEG-A es `high`: dejó rojo integridad.yml en main.
--
-- QUÉ SE REVISÓ
--   · El cambio es sólo ese bloque: el cuerpo vivo sin él da 88b3fc82…, el md5 de
--     la lista blanca (mig 337).
--   · Quién: cualquier sesión, a propósito. Todos los roles vinculan su Telegram.
--   · Para quién: para el que llama y nadie más. No recibe parámetros, y todo lo
--     que lee y escribe es de auth.uid(). El bloque nuevo sólo mira la marca propia.
--   · Un perfil inactivo con sesión puede generar el código, pero el canje lo
--     rechaza (perfil_invalido); uno marcado, también (apagado_por_admin).
--
-- POR QUÉ LISTA BLANCA Y NO UN GUARD DE ROL
--   No hay un rol que excluir. Un guard que sólo nombre un helper serviría
--   únicamente para engañar la heurística (ver la 376).
--
-- Parche por ancla sobre la definición viva, con premisa de md5 de las dos
-- funciones. auditoria_definer_sin_rol y generar_codigo_vinculacion_bot no se
-- tocan en nada más. Aplicar desde el contenido LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

DO $sega$
DECLARE
  c_viejo CONSTANT text := '''88b3fc8263238a733dde6d9ab38e8134''';
  c_nuevo CONSTANT text := '''6eebcfbefd5390e044ffbca6e40e62fe''';
  v_def   text := pg_get_functiondef('public.auditoria_definer_sin_rol()'::regprocedure);
BEGIN
  IF md5(v_def) <> '386cf7dd020a95eeb054e2e6c20f1726' THEN
    RAISE EXCEPTION 'auditoria_definer_sin_rol cambió en prod (md5 %): rehacer el parche sobre la definición vigente', md5(v_def);
  END IF;
  IF (SELECT md5(prosrc) FROM pg_proc
       WHERE oid = 'public.generar_codigo_vinculacion_bot()'::regprocedure) <> '6eebcfbefd5390e044ffbca6e40e62fe' THEN
    RAISE EXCEPTION 'generar_codigo_vinculacion_bot cambió en prod: revisar el cuerpo vigente antes de eximirlo';
  END IF;
  IF (length(v_def) - length(replace(v_def, c_viejo, ''))) / length(c_viejo) <> 1 THEN
    RAISE EXCEPTION 'el md5 viejo no aparece exactamente una vez en la lista blanca: revisar a mano';
  END IF;

  EXECUTE replace(v_def, c_viejo, c_nuevo);
END
$sega$;

REVOKE ALL ON FUNCTION public.auditoria_definer_sin_rol() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auditoria_definer_sin_rol() TO service_role;

DO $verif$
BEGIN
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

COMMIT;
