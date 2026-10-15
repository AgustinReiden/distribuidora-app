-- #1175 · control_rendicion_cerrado entra a la lista blanca de SEG-A.
--
-- Se aplica INMEDIATAMENTE DESPUÉS de 375_roles_extra_y_caja_controlada.sql,
-- que crea el helper. Entre las dos, SEG-A (auditoria_definer_sin_rol) da 1.
--
-- POR QUÉ LISTA BLANCA Y NO UN GUARD DE ROL
--   control_rendicion_cerrado(uuid,bigint,date) es DEFINER, con EXECUTE para
--   authenticated y sin helper de rol: SEG-A lo marca. Lo llama
--   pedidos_proteger_columnas (trigger INVOKER) como el usuario, para saber si
--   un cambio de fecha_entrega/transportista_id/estado borraría un control
--   confirmada o resuelta. mt_pedidos_update deja actualizar al usuario_id y al
--   transportista_id del pedido sin mirar el rol: un guard de rol adentro del
--   helper le devolvería false a quien no lo cumpla, y el guard de caja
--   quedaría abierto para esa persona sin ningún aviso. Un guard que sólo
--   nombre un helper (get_mi_rol() IS NOT NULL) serviría únicamente para
--   engañar la heurística. Es un booleano sin montos, de la misma naturaleza
--   que rendicion_dia_cerrada y ultima_fecha_caja_cerrada, que ya están en la
--   lista blanca.
--
-- Parche por ancla sobre la definición viva (molde de la 373): la entrada se
-- agrega después de la de ultima_fecha_caja_cerrada, cuyo md5 aparece una sola
-- vez. El md5 del helper se calcula acá, del cuerpo que dejó la migración
-- anterior. Si el helper cambia, SEG-A vuelve a salir en rojo con el md5 nuevo.
--
-- Ensayo: scripts/test-roles-columnas-caja-1170-1171-1175.sql (K1) y
-- scripts/test-permisos-definer-sin-rol.sql.

CREATE OR REPLACE FUNCTION pg_temp.rr_parchar(p_def text, p_viejo text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  IF (length(p_def) - length(replace(p_def, p_viejo, ''))) / length(p_viejo) <> 1 THEN
    RAISE EXCEPTION '%: el fragmento no aparece exactamente una vez: revisar a mano', p_que;
  END IF;
  RETURN replace(p_def, p_viejo, p_nuevo);
END
$fn$;

DO $sega$
DECLARE
  v_def text := pg_get_functiondef('public.auditoria_definer_sin_rol()'::regprocedure);
  v_md5 text := (SELECT md5(prosrc) FROM pg_proc
                  WHERE oid = 'public.control_rendicion_cerrado(uuid,bigint,date)'::regprocedure);
BEGIN
  v_def := pg_temp.rr_parchar(v_def,
    $q$'9528437b731a1dfc3d16acedf10f8bc2')$q$,
    $q$'9528437b731a1dfc3d16acedf10f8bc2'),
    -- #1175: booleano de control cerrado por chofer y día, sin montos; lo
    -- llama pedidos_proteger_columnas (INVOKER) como el usuario.
    ('control_rendicion_cerrado(uuid,bigint,date)', $q$ || quote_literal(v_md5) || $q$)$q$,
    'lista blanca SEG-A');
  EXECUTE v_def;
END
$sega$;

REVOKE ALL ON FUNCTION public.auditoria_definer_sin_rol() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auditoria_definer_sin_rol() TO service_role;

DO $verif$
BEGIN
  IF position('control_rendicion_cerrado(uuid,bigint,date)'
              IN pg_get_functiondef('public.auditoria_definer_sin_rol()'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'control_rendicion_cerrado no entró a la lista blanca de SEG-A';
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
