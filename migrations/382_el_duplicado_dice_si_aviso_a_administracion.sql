-- 382 (número final al aplicar) · #1189: el duplicado dice si avisó a administración
--
-- Desde la 379 (#1186) verificar_duplicado_cliente avisa a administración
-- ('cliente_duplicado_oculto') cuando el preventista no puede OPERAR al vecino, aunque lo
-- vea por historial (358) o por reparto (378). En esos casos cliente_visible viene lleno y
-- el front no tenía cómo saber que el aviso había salido: no se lo decía al preventista y,
-- con el vecino inactivo, le pedía reactivarlo desde "Ver inactivos", cosa que no puede
-- hacer con un cliente que no es de su cartera.
--
-- El JSON de retorno suma aviso_admin boolean = EXACTAMENTE la condición del aviso
-- (v_es_prev AND NOT v_operable), con el COALESCE a false que es la semántica del IF.
-- Es true también cuando la deduplicación de un día no vuelve a insertar la notificación:
-- administración ya está avisada de ese vecino. El camino sin vecino devuelve false.
--
-- NO CAMBIA: v_visible ni cliente_visible, v_operable, el bloqueo y sus distancias, el
--   aviso en sí (condición, textos, deduplicación, destinatarios), la firma ni el ACL.
--   No hay función ni tabla nueva. El front trata la falta del campo (RPC vieja) como false.
-- Ensayo: scripts/test-aviso-admin-1189.sql.

SET LOCAL lock_timeout = '5s';

CREATE OR REPLACE FUNCTION pg_temp.cc_parchar(p_def text, p_viejo text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  IF (length(p_def) - length(replace(p_def, p_viejo, ''))) / length(p_viejo) <> 1 THEN
    RAISE EXCEPTION '%: el fragmento no aparece exactamente una vez: revisar a mano', p_que;
  END IF;
  RETURN replace(p_def, p_viejo, p_nuevo);
END
$fn$;

-- ---------------------------------------------------------------------------
-- 1 · verificar_duplicado_cliente devuelve aviso_admin (parche por ancla)
-- ---------------------------------------------------------------------------
DO $duplicado$
DECLARE v_def text;
BEGIN
  v_def := pg_get_functiondef('public.verificar_duplicado_cliente(numeric,numeric,text,bigint)'::regprocedure);
  IF md5(v_def) <> '2b5ef0d32a6cf177f3dcceb680a2653a' THEN
    RAISE EXCEPTION 'verificar_duplicado_cliente cambió desde el relevamiento: revisar a mano';
  END IF;
  v_def := pg_temp.cc_parchar(v_def,
$o$      'distancia_m', NULL, 'cliente_visible', NULL);$o$,
$n$      'distancia_m', NULL, 'cliente_visible', NULL,
      'aviso_admin', false);$n$, 'retorno sin vecino');
  v_def := pg_temp.cc_parchar(v_def,
$o$      ELSE NULL END
  );$o$,
$n$      ELSE NULL END,
    -- #1189: la misma condición del aviso de arriba (el IF trata NULL como false)
    'aviso_admin', COALESCE(v_es_prev AND NOT v_operable, false)
  );$n$, 'retorno con vecino');
  EXECUTE v_def;
END
$duplicado$;

-- ---------------------------------------------------------------------------
-- 2 · Comentario
-- ---------------------------------------------------------------------------
COMMENT ON FUNCTION public.verificar_duplicado_cliente(numeric, numeric, text, bigint) IS
  'Única puerta del guard de clientes duplicados. Devuelve {bloquea, avisa, motivo, distancia_m, cliente_visible{id, codigo, nombre, activo}, aviso_admin}. DOS reglas, las dos sobre el LUGAR: dirección normalizada con altura (bloqueo) y distancia real en metros (<1 m bloqueo, 1-30 m aviso). El nombre NO es parte del criterio desde la mig 260: marcaba homónimos, no duplicados; desde #688 tampoco está en la firma. El número que se le muestra al usuario es codigo, no id. SECURITY DEFINER: ve por encima de la RLS pero no revela la identidad de un cliente que al caller se le tapa (cliente_visible sigue v_visible, la regla de mt_clientes_select). El aviso a administración mira OPERAR (v_operable, #1186), no VER: sale también cuando el vecino se ve por historial (358) o por reparto (378) pero el preventista no puede operarlo. Por rol base, como v_es_prev. aviso_admin (#1189) es exactamente esa condición (v_es_prev AND NOT v_operable; false sin vecino), true aunque la deduplicación de un día no reinserte la notificación: el front lo usa para decirle al preventista que ya se avisó y para no pedirle reactivar un inactivo que no es suyo. Fail-closed sin sesión o sin sucursal.';

-- ---------------------------------------------------------------------------
-- 3 · Verificación
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  f_dup text := 'public.verificar_duplicado_cliente(numeric,numeric,text,bigint)';
  v_src text;
BEGIN
  v_src := (SELECT prosrc FROM pg_proc WHERE oid = f_dup::regprocedure);
  IF (length(v_src) - length(replace(v_src, '''aviso_admin''', ''))) / length('''aviso_admin''') <> 2 THEN
    RAISE EXCEPTION 'verificar_duplicado_cliente no devuelve aviso_admin en sus dos RETURN';
  END IF;
  IF position('''aviso_admin'', COALESCE(v_es_prev AND NOT v_operable, false)' IN v_src) = 0 THEN
    RAISE EXCEPTION 'aviso_admin no es la condición del aviso';
  END IF;
  IF position('IF v_es_prev AND NOT v_operable THEN' IN v_src) = 0 THEN
    RAISE EXCEPTION 'verificar_duplicado_cliente perdió la condición del aviso de la 379';
  END IF;
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
        AND proname = 'verificar_duplicado_cliente') <> 1 THEN
    RAISE EXCEPTION 'apareció una sobrecarga de verificar_duplicado_cliente';
  END IF;
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = f_dup::regprocedure) THEN
    RAISE EXCEPTION 'verificar_duplicado_cliente dejó de ser SECURITY DEFINER';
  END IF;
  IF has_function_privilege('anon', f_dup::regprocedure, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', f_dup::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'ACL de verificar_duplicado_cliente: EXECUTE para anon o sin EXECUTE para authenticated';
  END IF;
  IF position('aviso_admin' IN coalesce(obj_description(f_dup::regprocedure, 'pg_proc'), '')) = 0 THEN
    RAISE EXCEPTION 'el COMMENT de verificar_duplicado_cliente no quedó actualizado';
  END IF;
END
$verif$;
