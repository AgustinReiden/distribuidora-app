-- Ensayo de la limpieza antes del fork (#1475, tarjeta 8 de #1477).
--
--   D1 · Antes: existen los seis helpers viejos, registrar_ingreso_sucursal y las dos tablas, y
--        ningún helper le da EXECUTE a anon. Después: no queda nada de eso, ni sus secuencias.
--   B1 · El trigger de borrado de productos sigue frenando a un producto con historial: uno con
--        pedido_items da 23503 y el mensaje nombra 'pedidos'.
--   B2 · Un producto nuevo, sin historial, se borra sin error. Después de la migración prueba que
--        el trigger ya no lee una tabla que no existe (sería 42P01 en cada DELETE de productos).
--   B3 · Después: el cuerpo del trigger no nombra transferencia_items y su md5 es el de la
--        poscondición.
--   H1 · Los helpers que se quedan siguen respondiendo: es_admin(), es_preventista() y
--        es_transportista() como un admin activo dan true.
--   U1 · Informativo: anon todavía ejecuta unaccent(text). SEG-F-9 no se puede cerrar desde
--        postgres (las funciones son de supabase_admin) y el dueño decidió dejarlo (06/11).
--
-- El ensayo detecta solo si la migración está aplicada (por transferencias_stock).
-- Corre contra prod sin dejar rastro (salvo valores de secuencia): un único DO que termina siempre
-- en una excepción, y cada caso en un sub-bloque que se revierte.

DO $ensayo$
DECLARE
  v_aplicada boolean := to_regclass('public.transferencias_stock') IS NULL;
  v_ok   text[] := '{}';
  v_err  text;
  v_st   text;
  v_prod bigint;
  v_suc  bigint;
  v_adm  uuid;
  v_n    int;
  v_b    boolean;
BEGIN
  -- D1
  SELECT count(*) INTO v_n
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname IN ('is_admin', 'is_preventista', 'is_transportista', 'get_user_role',
                       'get_mi_rol', 'es_transportista_rendiciones', 'registrar_ingreso_sucursal');
  IF v_aplicada THEN
    IF v_n <> 0 OR to_regclass('public.transferencia_items') IS NOT NULL
       OR to_regclass('public.transferencias_stock_id_seq') IS NOT NULL
       OR to_regclass('public.transferencia_items_id_seq') IS NOT NULL THEN
      RAISE EXCEPTION 'D1 · después de la migración quedan % funciones o alguna tabla/secuencia', v_n;
    END IF;
  ELSE
    IF v_n <> 7 OR to_regclass('public.transferencia_items') IS NULL THEN
      RAISE EXCEPTION 'D1 · antes de la migración se esperaban las 7 funciones y las 2 tablas (hay % funciones)', v_n;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'public'
                  AND p.proname IN ('is_admin', 'is_preventista', 'is_transportista', 'get_user_role',
                                    'get_mi_rol', 'es_transportista_rendiciones', 'registrar_ingreso_sucursal')
                  AND has_function_privilege('anon', p.oid, 'EXECUTE')) THEN
      RAISE EXCEPTION 'D1 · un helper viejo tiene EXECUTE para anon';
    END IF;
  END IF;
  v_ok := v_ok || 'D1'::text;

  -- B1
  SELECT pi.producto_id INTO v_prod FROM public.pedido_items pi WHERE pi.producto_id IS NOT NULL LIMIT 1;
  BEGIN
    DELETE FROM public.productos WHERE id = v_prod;
    RAISE EXCEPTION 'B1 · se borró el producto % con historial', v_prod;
  EXCEPTION WHEN SQLSTATE '23503' THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    IF v_err NOT LIKE '%tiene historial (%pedidos%' THEN
      RAISE EXCEPTION 'B1 · el rechazo no nombra pedidos: %', v_err;
    END IF;
  END;
  v_ok := v_ok || 'B1'::text;

  -- B2
  SELECT id INTO v_suc FROM public.sucursales WHERE activa ORDER BY id LIMIT 1;
  BEGIN
    INSERT INTO public.productos (nombre, precio, sucursal_id)
    VALUES ('ensayo 1475 sin historial', 1, v_suc) RETURNING id INTO v_prod;
    DELETE FROM public.productos WHERE id = v_prod;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'B2 · no se borró el producto nuevo';
    END IF;
    RAISE EXCEPTION 'revertir' USING ERRCODE = 'P0099';
  EXCEPTION
    WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT, v_st = RETURNED_SQLSTATE;
      RAISE EXCEPTION 'B2 · borrar un producto sin historial falló (%): %', v_st, v_err;
  END;
  v_ok := v_ok || 'B2'::text;

  -- B3
  IF v_aplicada THEN
    SELECT md5(prosrc), prosrc ~* 'transferencia_items' INTO v_err, v_b
      FROM pg_proc WHERE oid = 'public.productos_rechazar_borrado_con_historial()'::regprocedure;
    IF v_b OR v_err <> '781025173330d3e58aff853ae8de9855' THEN
      RAISE EXCEPTION 'B3 · el trigger no quedó como se esperaba (md5 %)', v_err;
    END IF;
    v_ok := v_ok || 'B3'::text;
  END IF;

  -- H1
  SELECT p.id INTO v_adm FROM public.perfiles p WHERE p.rol = 'admin' AND p.activo ORDER BY p.id LIMIT 1;
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
    IF NOT (public.es_admin() AND public.es_preventista() AND public.es_transportista()) THEN
      RAISE EXCEPTION 'H1 · un helper es_* dio false para el admin %', v_adm;
    END IF;
    RAISE EXCEPTION 'revertir' USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
  END;
  v_ok := v_ok || 'H1'::text;

  -- U1
  v_b := has_function_privilege('anon', 'public.unaccent(text)'::regprocedure, 'EXECUTE');
  v_ok := v_ok || ('U1 (anon ejecuta unaccent: ' || v_b || ')');

  RAISE EXCEPTION 'ENSAYO OK (%) · %', CASE WHEN v_aplicada THEN 'después' ELSE 'antes' END,
    array_to_string(v_ok, ' ');
END
$ensayo$;
