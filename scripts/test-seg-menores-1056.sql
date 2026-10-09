-- Ensayo de #1056: rol NULL en tres guards, limpiar_orden_entrega, la autoría
-- de registrar_nota_credito y el cierre de recorridos vencidos.
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en RAISE
-- EXCEPTION, así que todo lo que escriba se deshace. Simula la sesión como
-- PostgREST (SET LOCAL ROLE authenticated + request.jwt.claims + x-sucursal-id).
--
--   'ENSAYO OK …'    → todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' → lista de lo que no se cumplió.
--
-- Antes de la migración tiene que FALLAR en cada caso; después, pasar.
--
--   psql "$DATABASE_URL" -f scripts/test-seg-menores-1056.sql

DO $ensayo$
DECLARE
  v_fallas   text[] := '{}';
  v_saltados text[] := '{}';

  v_suc      bigint;  -- sucursal de los casos
  v_transp   uuid;    -- transportista de v_suc
  v_otro     uuid;    -- otro transportista de v_suc con pedidos asignados
  v_enc      uuid;    -- encargado o admin de v_suc
  v_compra   bigint;  -- compra no cancelada de v_suc
  v_json     jsonb;
  v_n        int;
  v_src      text;
  r          record;
BEGIN
  -- ---------------------------------------------------------------- datos ---
  SELECT p.transportista_id, p.sucursal_id INTO v_otro, v_suc
    FROM pedidos p JOIN perfiles pf ON pf.id = p.transportista_id AND pf.rol = 'transportista'
   WHERE p.transportista_id IS NOT NULL
   GROUP BY 1, 2 ORDER BY count(*) DESC LIMIT 1;

  SELECT pf.id INTO v_transp
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.rol = 'transportista' AND us.sucursal_id = v_suc AND pf.id <> v_otro
   ORDER BY pf.id LIMIT 1;

  SELECT pf.id INTO v_enc
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.rol IN ('encargado', 'admin') AND COALESCE(pf.activo, true) AND us.sucursal_id = v_suc
   ORDER BY (pf.rol = 'encargado') DESC, pf.id LIMIT 1;

  SELECT id INTO v_compra FROM compras
   WHERE sucursal_id = v_suc AND estado <> 'cancelada' ORDER BY id DESC LIMIT 1;

  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);

  -- ------------------------------------ 1 · rol NULL en tres guards -------
  -- perfiles.rol es NOT NULL y sin perfil no hay sucursal activa: el NULL no se
  -- fabrica sin tocar la tabla. Se mira el cuerpo.
  FOR r IN SELECT * FROM (VALUES
      ('obtener_geolocalizacion_preventistas(date,date)'),
      ('registrar_visita_cliente(bigint,text,numeric,numeric,numeric,timestamp with time zone,text)'),
      ('sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)')) t(firma) LOOP
    SELECT prosrc INTO v_src FROM pg_proc WHERE oid = ('public.' || r.firma)::regprocedure;
    IF v_src ~ 'IF\s+v_user_role\s+(<>|NOT\s+IN)' THEN
      v_fallas := v_fallas || format('%s · el guard compara el rol con <> / NOT IN sin cubrir el NULL', r.firma);
    END IF;
  END LOOP;

  -- -------------------------------------------- 2 · limpiar_orden_entrega --
  -- Un transportista borraba el orden de entrega de los pedidos de otro.
  IF v_transp IS NULL THEN
    v_saltados := v_saltados || 'limpiar_orden_entrega: no hay un segundo transportista en la sucursal'::text;
  ELSE
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_transp, 'role', 'authenticated')::text, true);
    BEGIN
      EXECUTE 'SET LOCAL ROLE authenticated';
      PERFORM public.limpiar_orden_entrega(v_otro);
      EXECUTE 'RESET ROLE';
      v_fallas := v_fallas || 'limpiar_orden_entrega · un transportista borró el orden de entrega de otro'::text;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
  END IF;

  -- --------------------------------------- 3 · autoría de la nota de crédito
  -- La nota queda a nombre de quien la carga, no del uuid que se le pase.
  IF v_enc IS NULL OR v_compra IS NULL THEN
    v_saltados := v_saltados || 'registrar_nota_credito: no hay encargado/admin o compra en la sucursal'::text;
  ELSE
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_enc, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    -- Un ajuste sin mercadería (items vacíos): no toca stock.
    v_json := public.registrar_nota_credito(v_compra, 'ensayo-1056', 'ensayo #1056', 1, 0, 1, v_otro, '[]'::jsonb, 0);
    EXECUTE 'RESET ROLE';
    IF COALESCE((v_json->>'success')::boolean, false) THEN
      SELECT count(*) INTO v_n FROM notas_credito WHERE numero_nota = 'ensayo-1056' AND usuario_id = v_otro;
      IF v_n > 0 THEN
        v_fallas := v_fallas || 'registrar_nota_credito · la nota quedó firmada por otro usuario'::text;
      END IF;
    END IF;
    -- Y la carga legítima, con el propio uuid, sigue andando y queda a su nombre.
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_json := public.registrar_nota_credito(v_compra, 'ensayo-1056-ok', 'ensayo #1056', 1, 0, 1, v_enc, '[]'::jsonb, 0);
    EXECUTE 'RESET ROLE';
    IF NOT COALESCE((v_json->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('registrar_nota_credito · la carga legítima falló: %s', v_json);
    ELSIF NOT EXISTS (SELECT 1 FROM notas_credito WHERE numero_nota = 'ensayo-1056-ok' AND usuario_id = v_enc) THEN
      v_fallas := v_fallas || 'registrar_nota_credito · la carga legítima no quedó a nombre de quien la hizo'::text;
    END IF;
  END IF;

  -- --------------------------------- 4 · cierre de recorridos vencidos ------
  -- 4.1 · El corte es el día argentino, no el UTC: corrida a mano a las 21:30
  --       no cierra la ruta que se está haciendo.
  SELECT prosrc INTO v_src FROM pg_proc WHERE oid = 'public.cerrar_recorridos_vencidos(bigint)'::regprocedure;
  IF v_src ~ 'r\.fecha\s*<\s*CURRENT_DATE' THEN
    v_fallas := v_fallas || 'cerrar_recorridos_vencidos · corta por CURRENT_DATE (UTC), no por el día argentino'::text;
  END IF;
  -- 4.2 · No quedan vencidos sin pendientes.
  SELECT count(*) INTO v_n FROM recorridos rec
   WHERE rec.estado = 'en_curso'
     AND rec.fecha < (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
     AND NOT EXISTS (SELECT 1 FROM recorrido_pedidos rp JOIN pedidos p ON p.id = rp.pedido_id
                      WHERE rp.recorrido_id = rec.id AND p.estado = 'asignado');
  IF v_n > 0 THEN
    v_fallas := v_fallas || format('recorridos · %s en curso de días pasados sin paradas pendientes', v_n);
  END IF;
  -- 4.3 · Y la app no la ejecuta: la llama el workflow con service_role.
  IF has_function_privilege('authenticated', 'public.cerrar_recorridos_vencidos(bigint)', 'EXECUTE') THEN
    v_fallas := v_fallas || 'cerrar_recorridos_vencidos · authenticated la puede ejecutar'::text;
  END IF;

  -- ---------------------------------------------------------- veredicto --
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (% fallas, todo revertido):\n- %\nSaltados:\n- %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), COALESCE(NULLIF(array_to_string(v_saltados, E'\n- '), ''), '(ninguno)');
  END IF;
  RAISE EXCEPTION E'ENSAYO OK (todo revertido). sucursal %, transportista %, otro %, encargado %, compra %.\nSaltados:\n- %',
    v_suc, v_transp, v_otro, v_enc, v_compra, COALESCE(NULLIF(array_to_string(v_saltados, E'\n- '), ''), '(ninguno)');
END
$ensayo$;
