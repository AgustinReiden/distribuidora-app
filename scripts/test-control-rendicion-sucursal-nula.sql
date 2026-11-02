-- Ensayo de la regresión de la 435: un gasto nuevo se puede cargar, y una sucursal
-- ajena sigue levantando (mig 436_control_rendicion_sucursal_nula).
--
-- Corre contra prod sin dejar rastro: un único DO que termina siempre en una excepción.
-- Antes de aplicar la migración se corre pegado detrás de su cuerpo, sin el BEGIN y el
-- COMMIT; después, solo. Solo y sin la migración tiene que dar 'ENSAYO FALLÓ'.

DO $ensayo$
DECLARE
  v_adm    uuid;
  v_s      bigint;
  v_u      uuid;
  v_propia bigint;
  v_ajena  bigint;
  v_rubro  bigint;
  v_hoy    date := public._tablero_hoy();
  v_txt    text;
  v_fallas text[] := '{}';
BEGIN
  SELECT us.usuario_id, us.sucursal_id INTO v_adm, v_s
    FROM usuario_sucursales us JOIN perfiles p ON p.id = us.usuario_id
   WHERE p.rol = 'admin' AND p.activo
   ORDER BY us.es_default DESC, us.usuario_id LIMIT 1;

  -- Alguien que tenga una sola sucursal, para que la otra le sea ajena.
  SELECT us.usuario_id, min(us.sucursal_id) INTO v_u, v_propia
    FROM usuario_sucursales us JOIN perfiles p ON p.id = us.usuario_id
   WHERE p.activo
   GROUP BY us.usuario_id HAVING count(*) = 1
   ORDER BY us.usuario_id LIMIT 1;
  SELECT s.id INTO v_ajena FROM sucursales s WHERE s.id <> v_propia ORDER BY s.id LIMIT 1;

  SELECT r.id INTO v_rubro FROM gasto_rubros r WHERE r.nombre ILIKE 'peaje%' LIMIT 1;

  IF v_adm IS NULL OR v_u IS NULL OR v_ajena IS NULL OR v_rubro IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin contexto: admin %, usuario %, ajena %, rubro %', v_adm, v_u, v_ajena, v_rubro;
  END IF;

  -- 1 · un gasto nuevo, como lo arma ModalGasto
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_s::text)::text, true);
    SET LOCAL ROLE authenticated;
    v_txt := public.guardar_gasto(p_gasto => jsonb_build_object(
      'fecha', v_hoy, 'rubro_id', v_rubro, 'monto_total', 5000, 'comprobante', 'ticket',
      'comprobante_numero', NULL, 'alicuota_iva', NULL, 'iva', 0, 'percepcion_iva', 0,
      'percepcion_iibb', 0, 'otros_impuestos', 0, 'sucursal_id', v_s, 'compartido', false,
      'vehiculo_id', NULL, 'litros', NULL, 'km_tablero', NULL,
      'mes_imputado', to_char(date_trunc('month', v_hoy), 'YYYY-MM-DD'), 'repartir_meses', 1,
      'origen_pago', 'oficina', 'rendicion_transportista_id', NULL, 'rendicion_fecha', NULL,
      'observacion', NULL))::text;
    RESET ROLE;
    IF NOT EXISTS (SELECT 1 FROM gastos g WHERE g.id = v_txt::bigint AND g.sucursal_id = v_s) THEN
      v_fallas := v_fallas || format('1 el gasto %s no quedó', v_txt);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    v_fallas := v_fallas || format('1 crear un gasto dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- 2 · sucursal NULL con sesión: false, como antes de la 435
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_u, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_propia::text)::text, true);
    SET LOCAL ROLE authenticated;
    IF public.control_rendicion_cerrado(NULL, NULL, NULL) IS DISTINCT FROM false THEN
      v_fallas := v_fallas || '2 con sucursal NULL no dio false'::text;
    END IF;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    v_fallas := v_fallas || format('2 con sucursal NULL dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- 3 · la propia contesta, y la ajena sigue levantando (lo que quería la 435)
  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM public.control_rendicion_cerrado(v_u, v_propia, v_hoy);
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    v_fallas := v_fallas || format('3 la propia dio %s: %s', SQLSTATE, SQLERRM);
  END;
  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM public.control_rendicion_cerrado(v_u, v_ajena, v_hoy);
    RESET ROLE;
    v_fallas := v_fallas || '3 la ajena no levantó'::text;
  EXCEPTION WHEN insufficient_privilege THEN
    RESET ROLE;
  END;

  -- 4 · el server no pasa por el chequeo
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.headers', '', true);
  IF public.control_rendicion_cerrado(NULL, NULL, NULL) IS DISTINCT FROM false THEN
    v_fallas := v_fallas || '4 el server con sucursal NULL no dio false'::text;
  END IF;

  -- 5 · la lista blanca de SEG-A quedó al día
  IF (SELECT count(*) FROM public.auditoria_definer_sin_rol()) <> 0 THEN
    v_fallas := v_fallas || format('5 SEG-A: %s',
      (SELECT string_agg(firma || ' (' || motivo || ')', '; ') FROM public.auditoria_definer_sin_rol()));
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ (%): %', cardinality(v_fallas), array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · un gasto nuevo se carga; sucursal NULL da false con sesión y sin ella; la ajena sigue levantando; SEG-A en 0';
END
$ensayo$;
