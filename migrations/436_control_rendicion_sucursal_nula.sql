-- 436 · Un gasto nuevo se vuelve a poder cargar (regresión de la 435).
--
-- QUÉ PASABA
--   La 435 hizo que control_rendicion_cerrado levante 42501 si la sucursal no es
--   del que llama, y una sucursal NULL entra en esa rama. `_guardar_gasto` hace, en
--   el paso 10:
--       IF v_viejo.origen_pago = 'rendicion' AND public.control_rendicion_cerrado(...)
--   Al crear un gasto `v_viejo` está vacío. `NULL AND f()` no corta, porque f() podría
--   dar false y el resultado cambiaría: Postgres evalúa f() igual, con todo en NULL. Y
--   entonces ningún usuario podía cargar un gasto nuevo: 'Acceso denegado: la sucursal
--   <NULL> no está asignada al usuario'.
--
-- QUÉ CAMBIA
--   control_rendicion_cerrado contesta false con sucursal NULL, antes del chequeo. Es
--   lo que ya hace rendicion_dia_cerrada, y lo que daba antes de la 435: ninguna
--   rendición tiene sucursal NULL. No le abre nada a nadie: una sucursal ajena sigue
--   levantando.
--
-- QUÉ NO CAMBIA
--   · _guardar_gasto: el arreglo va en la función que cambió, y así no depende de que
--     cada llamador nuevo se acuerde del NULL.
--   · ultima_fecha_caja_cerrada: sus llamadores le pasan la sucursal de una fila que
--     existe. Ninguno tiene el patrón de arriba.
--
-- Ensayo: scripts/test-control-rendicion-sucursal-nula.sql. Aplicar desde el contenido LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

DO $premisas$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('public.control_rendicion_cerrado(uuid,bigint,date)', 'f6817668b4d37888aab2ea3e7addb645'),
      ('public.auditoria_definer_sin_rol()',                 '21c12f100e0836723248a514b88c633c')
    ) AS t(firma, hash)
  LOOP
    IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = r.firma::regprocedure) <> r.hash THEN
      RAISE EXCEPTION '% cambió en prod (md5 %): rehacer el parche sobre el cuerpo vigente',
        r.firma, (SELECT md5(prosrc) FROM pg_proc WHERE oid = r.firma::regprocedure);
    END IF;
  END LOOP;
END
$premisas$;

CREATE OR REPLACE FUNCTION public.control_rendicion_cerrado(p_transportista_id uuid, p_sucursal_id bigint, p_fecha date)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- Sin sucursal no hay rendición que mirar. `_guardar_gasto` llega acá con la
  -- fila vieja vacía al crear un gasto: `NULL AND f()` evalúa f() igual.
  IF p_sucursal_id IS NULL THEN
    RETURN false;
  END IF;

  -- #1175: lo llama pedidos_proteger_columnas (INVOKER, como authenticated),
  -- que no ve rendiciones_control por RLS. Booleano, sin montos. Misma
  -- naturaleza que rendicion_dia_cerrada (lista blanca de SEG-A).
  -- #1334: sólo de las sucursales del que llama. Levanta porque la usan los
  -- guards, y un false les abriría el control cerrado. El server (auth.uid()
  -- NULL) no pasa por acá.
  IF auth.uid() IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM usuario_sucursales us
        WHERE us.usuario_id = auth.uid() AND us.sucursal_id = p_sucursal_id) THEN
    RAISE EXCEPTION 'Acceso denegado: la sucursal % no está asignada al usuario', p_sucursal_id
      USING ERRCODE = '42501';
  END IF;

  RETURN EXISTS (SELECT 1 FROM rendiciones_control
                  WHERE transportista_id = p_transportista_id
                    AND sucursal_id = p_sucursal_id
                    AND fecha = p_fecha
                    AND estado IN ('confirmada', 'resuelta'));
END;
$function$;

-- SEG-A: el cuerpo nuevo. Revisado: sigue siendo un booleano sin montos, y contesta
-- lo mismo que antes de la 435 para una sucursal NULL.
DO $sega$
DECLARE
  v_nuevo text := (SELECT md5(prosrc) FROM pg_proc
                    WHERE oid = 'public.control_rendicion_cerrado(uuid,bigint,date)'::regprocedure);
  v_viejo text := 'f6817668b4d37888aab2ea3e7addb645';
  v_def   text := pg_get_functiondef('public.auditoria_definer_sin_rol()'::regprocedure);
BEGIN
  IF v_nuevo <> '3a5ed52d20b27cf1cb3820b95aa53153' THEN
    RAISE EXCEPTION 'control_rendicion_cerrado quedó con otro cuerpo (md5 %): revisar antes de eximirla', v_nuevo;
  END IF;
  IF (length(v_def) - length(replace(v_def, v_viejo, ''))) / length(v_viejo) <> 1 THEN
    RAISE EXCEPTION 'el md5 viejo no aparece exactamente una vez en la lista blanca';
  END IF;
  EXECUTE replace(v_def, v_viejo, v_nuevo);
END
$sega$;

DO $verif$
BEGIN
  IF (SELECT count(*) FROM public.auditoria_definer_sin_rol()) <> 0 THEN
    RAISE EXCEPTION 'SEG-A no quedó en 0: %',
      (SELECT string_agg(firma || ' (' || motivo || ')', '; ') FROM public.auditoria_definer_sin_rol());
  END IF;
  -- CREATE OR REPLACE conserva los grants: esto lo comprueba.
  IF NOT has_function_privilege('authenticated', 'public.control_rendicion_cerrado(uuid,bigint,date)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.control_rendicion_cerrado(uuid,bigint,date)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.auditoria_definer_sin_rol()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.auditoria_definer_sin_rol()', 'EXECUTE') THEN
    RAISE EXCEPTION 'un grant quedó distinto del que tenía';
  END IF;
END
$verif$;

COMMIT;
