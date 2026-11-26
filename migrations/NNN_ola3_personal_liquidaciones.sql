-- =========================================================================
-- NNN · PERSONAL Y LIQUIDACIONES (ola 3, tarjeta T6 de #1677; #1534, #1392,
--       #1551 y #1554)
--
-- Ensayo: scripts/test-ola3-personal-liquidaciones.sql (falla sin esta
-- migración en 1 a 9, ENSAYO OK con ella). Carrera de dos sesiones:
-- scripts/concurrencia/t6-clave-movimiento-empleado.sh.
-- Se aplica en LF. Dos DDL de tabla (el CHECK de altas_por_clave y una
-- columna nueva de empleado_liquidaciones): sus LOCK van al principio, NOWAIT.
--
-- 1 · #1534: liquidar_empleado topa el pago que sale de una rendición contra
--     _rendicion_efectivo_a_entregar, con la rendición ya bloqueada (la toma
--     _pago_de_rendicion), con el mismo mensaje que el pago suelto (GTO-8).
-- 2 · Com-B3: registrar_movimiento_empleado y liquidar_empleado reciben
--     p_clave (uuid, DEFAULT NULL), con el patrón de altas_por_clave: la misma
--     clave con el mismo contenido devuelve el id del primer intento; con otro
--     contenido, otra operación u otro usuario, 22023. La clave se mira con el
--     empleado ya bloqueado y antes de las validaciones (el reintento de un
--     pago que entró chocaría con «más de lo que se le debe»). Sin clave (un
--     PWA de antes), como siempre. Las firmas viejas se dropean: nada de dos
--     sobrecargas (PGRST203). Un bundle viejo llama con dos argumentos y
--     resuelve a la nueva por el DEFAULT.
-- 3 · Com-B4: _empleado_json muestra el período de un empleado de baja con la
--     misma regla que previsualizar_liquidacion: comisiones o ajustes con total
--     distinto de 0 (antes, sólo comisiones iniciales: uno con sólo un ajuste
--     negativo no aparecía «para liquidar»).
-- 4 · Com-B5 (decisión del dueño del 25/11): guardar_empleado no deja que un
--     admin cambie la ficha de cliente de su propia ficha de empleado (ni la
--     saque ni la cambie), como su usuario, su arreglo y sus movimientos.
-- 5 · m2: _movimiento_origen_json dice si la rendición de un pago está cerrada
--     (control_rendicion_cerrado, la regla con la que revertir lo rechaza), y
--     la cuenta del empleado deja de ofrecer «Revertir» ahí.
-- 6 · m3: anular_liquidacion se rechaza si sus comisiones se calcularon con un
--     usuario que ya no es el del empleado (se lo pasaron a otra ficha o se lo
--     sacaron): las boletas quedaban sin dueño, o para el otro empleado.
-- 7 · m4 (decisión del dueño del 25/11): lo pendiente no se arrastra de una
--     sucursal a otra. guardar_empleado rechaza cambiar la sucursal (o «las
--     dos») de un empleado con comisión sin liquidar, con el monto y la
--     sucursal en el mensaje. Es el único camino que cambia la sucursal de un
--     empleado (dar_de_baja y reactivar no la tocan; empleados no tiene
--     escritura REST), y la sucursal del usuario (usuario_sucursales) no entra
--     en la cuenta de la comisión de la ficha. Lo pendiente sale de
--     _liquidacion_lineas (la cuenta de previsualizar_liquidacion, sobre
--     _comision_lineas, que no se toca), en _empleado_comision_sin_liquidar; el
--     motivo es uno (_empleado_aviso_comision_sin_liquidar), y si lo pendiente
--     entra en un período que todavía no empezó (se liquidó el período en curso
--     y hoy se entregó algo más) dice desde cuándo se puede liquidar. La pantalla
--     lo pide por comision_sin_liquidar_empleado (sólo admin).
--     Decisión del dueño del 26/11: tampoco se le saca el usuario a una ficha con
--     comisión sin liquidar, ni se le pasa otro (lo pendiente es del usuario de
--     la ficha y quedaba sin ficha que lo liquide). La misma cuenta y el mismo
--     motivo, con «cambiarle o sacarle el usuario» (aviso_usuario en la
--     pantalla). El alta, o vincular un usuario a una ficha que no tenía, no se
--     frena.
-- 8 · m5: una liquidación guarda su corte (corte_movimiento_id: el último
--     movimiento del empleado al liquidar). Sin movimientos propios (sueldo 0,
--     sin comisión, sin pago) no adelantaba el corte, y lo ya liquidado volvía
--     a salir en la vista previa siguiente. El corte es uno,
--     _empleado_corte_movimientos: lo usan _liquidacion_json y la fecha del
--     reintegro de gastos_cuenta_empleado (la misma regla, copiada).
--
-- Lo que NO hace: m7 (fetchTransportistas) es sólo del front. No toca
-- _comision_lineas, calcular_comisiones, guardar_comision_regla, las metas,
-- resolver_rendicion, _guardar_gasto ni control_rendicion_cerrado.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

-- Las dos DDL de tabla: sus locks primero, sin esperar. Si un alta o una
-- liquidación las tiene tomadas, falla al instante y se reintenta.
LOCK TABLE public.altas_por_clave IN ACCESS EXCLUSIVE MODE NOWAIT;
LOCK TABLE public.empleado_liquidaciones IN ACCESS EXCLUSIVE MODE NOWAIT;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos de producción en la 548.
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.registrar_movimiento_empleado(bigint,jsonb)', '86f8222bfa56d02fd9955177e39f7718'),
    ('public.liquidar_empleado(bigint,jsonb)', 'e47689d6c4169d1e90c6d42901ff3d96'),
    ('public.anular_liquidacion(bigint,text)', '1184bd8035874821338e71c7a9b6692b'),
    ('public.guardar_empleado(jsonb)', '64100fe2b64479031fde88aa83174c37'),
    ('public._empleado_json(public.empleados)', '2e6c56cc57330c51eb871321e0e4fa37'),
    ('public._liquidacion_json(public.empleados,date,date,numeric)', '1e1ba6d284af8d0a562d5470be611b55'),
    ('public._movimiento_origen_json(public.empleado_movimientos)', '55964f69df430ec0196763c603bf79e3'),
    ('public.gastos_cuenta_empleado()', '19d3a9f583e4acfcc2c438b3f71821d6')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;
  -- Las firmas nuevas y las funciones nuevas no existen todavía (reaplicarla aborta acá).
  IF to_regprocedure('public.registrar_movimiento_empleado(bigint,jsonb,uuid)') IS NOT NULL
     OR to_regprocedure('public.liquidar_empleado(bigint,jsonb,uuid)') IS NOT NULL
     OR to_regprocedure('public.comision_sin_liquidar_empleado(bigint)') IS NOT NULL
     OR to_regprocedure('public._empleado_comision_sin_liquidar(public.empleados)') IS NOT NULL
     OR to_regprocedure('public._empleado_aviso_comision_sin_liquidar(public.empleados,text)') IS NOT NULL
     OR to_regprocedure('public._empleado_corte_movimientos(bigint)') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · ya está aplicada (existen las funciones nuevas)';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.empleado_liquidaciones'::regclass
                AND attname = 'corte_movimiento_id' AND NOT attisdropped) THEN
    RAISE EXCEPTION 'mig NNN · ya está aplicada (existe empleado_liquidaciones.corte_movimiento_id)';
  END IF;
  -- El CHECK de las operaciones de altas_por_clave tiene por lo menos las cinco de la 542. Otras
  -- tarjetas de la ola suman las suyas (T3 'cambio_producto', T8 'visita'): no se pide la lista
  -- exacta, y el CHECK se rearma sobre la vigente (abajo).
  SELECT pg_get_constraintdef(oid) INTO v FROM pg_constraint
   WHERE conrelid = 'public.altas_por_clave'::regclass AND conname = 'altas_por_clave_operacion_check';
  IF v IS NULL OR NOT (ARRAY(SELECT m[1] FROM regexp_matches(v, '''([a-z_]+)''::text', 'g') AS m)
                       @> ARRAY['condicion_mayorista', 'promocion', 'cliente', 'gasto', 'empleado']) THEN
    RAISE EXCEPTION 'mig NNN · el CHECK de altas_por_clave no tiene las cinco operaciones de la 542 (%): rehacer sobre lo vigente', v;
  END IF;
END
$premisas$;

-- Reemplaza un ancla que tiene que aparecer exactamente p_n veces.
CREATE FUNCTION pg_temp.parche(p_def text, p_ancla text, p_nuevo text, p_n int, p_que text)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v_n int := (length(p_def) - length(replace(p_def, p_ancla, ''))) / length(p_ancla);
BEGIN
  IF v_n <> p_n THEN
    RAISE EXCEPTION 'mig NNN · %: el ancla aparece % vez/veces y se esperaba %', p_que, v_n, p_n;
  END IF;
  RETURN replace(p_def, p_ancla, p_nuevo);
END
$f$;

-- =========================================================================
-- DDL: las operaciones de altas_por_clave y el corte de la liquidación
-- =========================================================================
-- Sobre la lista VIGENTE: se leen las operaciones del CHECK de hoy, se suman sólo las de esta
-- migración que falten y se recrea. Las de antes quedan anotadas para la poscondición.
DO $operaciones$
DECLARE
  v_def   text;
  v_antes text[];
  v_ops   text[];
BEGIN
  SELECT pg_get_constraintdef(oid) INTO v_def FROM pg_constraint
   WHERE conrelid = 'public.altas_por_clave'::regclass AND conname = 'altas_por_clave_operacion_check';
  v_antes := ARRAY(SELECT m[1] FROM regexp_matches(v_def, '''([a-z_]+)''::text', 'g') AS m);
  v_ops := v_antes || ARRAY(SELECT o FROM unnest(ARRAY['movimiento_empleado', 'liquidacion_empleado']) AS o
                             WHERE o <> ALL (v_antes));
  PERFORM set_config('mig_t6.operaciones_antes', array_to_string(v_antes, ','), true);
  ALTER TABLE public.altas_por_clave DROP CONSTRAINT altas_por_clave_operacion_check;
  -- Con ARRAY['x'::text, …], la misma forma que dejó la 542 (la que leen las otras tarjetas).
  EXECUTE format('ALTER TABLE public.altas_por_clave ADD CONSTRAINT altas_por_clave_operacion_check CHECK (operacion = ANY (ARRAY[%s]))',
                 (SELECT string_agg(quote_literal(o) || '::text', ', ' ORDER BY n)
                    FROM unnest(v_ops) WITH ORDINALITY AS t(o, n)));
END
$operaciones$;

-- Sin default y nullable: no reescribe la tabla. Las liquidaciones anteriores
-- quedan en NULL y cortan como antes (en su último movimiento).
ALTER TABLE public.empleado_liquidaciones ADD COLUMN corte_movimiento_id bigint;
COMMENT ON COLUMN public.empleado_liquidaciones.corte_movimiento_id IS
  'm5 (#1392): el último movimiento del empleado cuando se liquidó. Lo de antes queda en el saldo anterior de la próxima vista previa, aunque la liquidación no haya escrito movimientos (_empleado_corte_movimientos).';

-- =========================================================================
-- 8 · m5: el corte, una sola regla
-- =========================================================================
CREATE FUNCTION public._empleado_corte_movimientos(p_empleado_id bigint)
RETURNS bigint
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $function$
  -- m5 (#1392): lo posterior a la última liquidación vigente. El corte es el
  -- último de sus movimientos o, si se guardó, el último movimiento del empleado
  -- al liquidar (corte_movimiento_id): una liquidación sin movimientos propios
  -- también corta. GREATEST ignora los NULL (las de antes de la columna).
  SELECT GREATEST(
           (SELECT max(m.id)
              FROM empleado_movimientos m
              JOIN empleado_liquidaciones li ON li.id = m.liquidacion_id AND li.anulada_at IS NULL
             WHERE m.empleado_id = p_empleado_id),
           (SELECT max(li.corte_movimiento_id)
              FROM empleado_liquidaciones li
             WHERE li.empleado_id = p_empleado_id AND li.anulada_at IS NULL));
$function$;
REVOKE ALL ON FUNCTION public._empleado_corte_movimientos(bigint) FROM PUBLIC, anon, authenticated;

DO $corte_json$
DECLARE
  v_def text := pg_get_functiondef('public._liquidacion_json(public.empleados,date,date,numeric)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  SELECT max(m.id) INTO v_corte
    FROM empleado_movimientos m
    JOIN empleado_liquidaciones li ON li.id = m.liquidacion_id AND li.anulada_at IS NULL
   WHERE m.empleado_id = p_e.id;
$a$,
$r$  -- m5 (#1392): el corte es uno (_empleado_corte_movimientos), también el de una
  -- liquidación que no escribió movimientos.
  v_corte := public._empleado_corte_movimientos(p_e.id);
$r$, 1, '_liquidacion_json (corte)');
  EXECUTE v_def;
END
$corte_json$;

DO $corte_gasto$
DECLARE
  v_def text := pg_get_functiondef('public.gastos_cuenta_empleado()'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$      SELECT max(m.id) INTO v_corte
        FROM empleado_movimientos m
        JOIN empleado_liquidaciones li ON li.id = m.liquidacion_id AND li.anulada_at IS NULL
       WHERE m.empleado_id = NEW.empleado_id;
$a$,
$r$      -- m5 (#1392): el mismo corte que la vista previa de la liquidación.
      v_corte := public._empleado_corte_movimientos(NEW.empleado_id);
$r$, 1, 'gastos_cuenta_empleado (corte)');
  EXECUTE v_def;
END
$corte_gasto$;

-- =========================================================================
-- 1, 2 y 8 · liquidar_empleado: el tope de la rendición, la clave y el corte
-- =========================================================================
DO $liquidar$
DECLARE
  v_def text := pg_get_functiondef('public.liquidar_empleado(bigint,jsonb)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$public.liquidar_empleado(p_empleado_id bigint, p_liquidacion jsonb)$a$,
$r$public.liquidar_empleado(p_empleado_id bigint, p_liquidacion jsonb, p_clave uuid DEFAULT NULL::uuid)$r$,
    1, 'liquidar_empleado (firma)');
  v_def := pg_temp.parche(v_def,
$a$  v_t        record;
BEGIN
$a$,
$r$  v_t        record;
  -- Com-B3 (#1554): la clave del intento.
  v_contenido text;
  v_previa    public.altas_por_clave%ROWTYPE;
BEGIN
$r$, 1, 'liquidar_empleado (declaraciones)');
  v_def := pg_temp.parche(v_def,
$a$    RAISE EXCEPTION 'Tu propia cuenta la maneja otro admin: no podés liquidarte ni registrarte pagos';
  END IF;
  -- 3 · formato
$a$,
$r$    RAISE EXCEPTION 'Tu propia cuenta la maneja otro admin: no podés liquidarte ni registrarte pagos';
  END IF;
  -- 2b · Com-B3 (#1554): la clave del intento (altas_por_clave, como el alta de
  --      un empleado). La misma clave con lo mismo es un reintento: devuelve la
  --      liquidación del primero. Con el empleado ya bloqueado, y antes de las
  --      validaciones: el reintento de una liquidación que entró chocaría con
  --      «ya no es el próximo». Sin clave (un PWA de antes), como siempre.
  IF p_clave IS NOT NULL THEN
    v_contenido := md5(jsonb_build_array(p_empleado_id, p_liquidacion)::text);
    INSERT INTO altas_por_clave (clave, operacion, usuario_id, sucursal_id, contenido)
    VALUES (p_clave, 'liquidacion_empleado', v_uid, v_e.sucursal_id, v_contenido)
    ON CONFLICT (clave) DO NOTHING;
    IF NOT FOUND THEN
      SELECT * INTO v_previa FROM altas_por_clave WHERE clave = p_clave;
      IF v_previa.operacion <> 'liquidacion_empleado' OR v_previa.usuario_id IS DISTINCT FROM v_uid THEN
        RAISE EXCEPTION 'Esta clave ya se usó para otra operación: recargá la página e intentá de nuevo.'
          USING ERRCODE = '22023';
      END IF;
      IF v_previa.contenido <> v_contenido THEN
        RAISE EXCEPTION 'Esta liquidación ya se confirmó con el intento anterior y lo que mandaste ahora es distinto: cerrá esta ventana y revisá la cuenta del empleado.'
          USING ERRCODE = '22023';
      END IF;
      IF v_previa.entidad_id IS NULL
         OR NOT EXISTS (SELECT 1 FROM empleado_liquidaciones WHERE id = v_previa.entidad_id AND anulada_at IS NULL) THEN
        RAISE EXCEPTION 'Esta liquidación ya se había confirmado con el intento anterior y después se anuló: cerrá esta ventana y volvé a abrir la liquidación.'
          USING ERRCODE = '22023';
      END IF;
      RETURN v_previa.entidad_id;
    END IF;
  END IF;
  -- 3 · formato
$r$, 1, 'liquidar_empleado (clave)');
  v_def := pg_temp.parche(v_def,
$a$    SELECT * INTO v_rend FROM public._pago_de_rendicion(p_liquidacion);
    v_fpago := COALESCE(v_rend.fecha, v_fpago);
$a$,
$r$    SELECT * INTO v_rend FROM public._pago_de_rendicion(p_liquidacion);
    v_fpago := COALESCE(v_rend.fecha, v_fpago);
    -- #1534: de una rendición no sale más efectivo del que le queda por entregar,
    -- como el pago suelto (GTO-8). La rendición ya está bloqueada
    -- (_pago_de_rendicion): un gasto o un pago de la misma rendición espera.
    IF v_rend.fecha IS NOT NULL
       AND v_pago > public._rendicion_efectivo_a_entregar(v_rend.sucursal_id, v_rend.transportista_id, v_rend.fecha) THEN
      RAISE EXCEPTION 'El pago supera el efectivo que le queda por entregar a esa rendición';
    END IF;
$r$, 1, 'liquidar_empleado (tope de la rendición)');
  v_def := pg_temp.parche(v_def,
$a$                                      saldo_anterior, a_pagar, pagado, fecha_pago, creado_por)
  VALUES (v_e.id, v_desde, v_hasta, v_p.frecuencia, v_e.sucursal_id, v_e.de_las_dos,
          (v_j->>'saldo_anterior')::numeric, v_esperado, v_pago, v_fpago, v_uid)
  RETURNING id INTO v_id;
$a$,
$r$                                      saldo_anterior, a_pagar, pagado, fecha_pago, creado_por, corte_movimiento_id)
  VALUES (v_e.id, v_desde, v_hasta, v_p.frecuencia, v_e.sucursal_id, v_e.de_las_dos,
          (v_j->>'saldo_anterior')::numeric, v_esperado, v_pago, v_fpago, v_uid,
          -- m5 (#1392): el corte, antes de sus movimientos. Con el empleado
          -- bloqueado no entra ningún otro (la FK de empleado_movimientos espera).
          (SELECT max(m.id) FROM empleado_movimientos m WHERE m.empleado_id = v_e.id))
  RETURNING id INTO v_id;
$r$, 1, 'liquidar_empleado (corte)');
  v_def := pg_temp.parche(v_def,
$a$  RETURN v_id;
END
$a$,
$r$  IF p_clave IS NOT NULL THEN
    UPDATE altas_por_clave SET entidad_id = v_id WHERE clave = p_clave;
  END IF;
  RETURN v_id;
END
$r$, 1, 'liquidar_empleado (la clave apunta a la liquidación)');
  DROP FUNCTION public.liquidar_empleado(bigint, jsonb);
  EXECUTE v_def;
END
$liquidar$;
REVOKE ALL ON FUNCTION public.liquidar_empleado(bigint, jsonb, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.liquidar_empleado(bigint, jsonb, uuid) TO authenticated, service_role;

-- =========================================================================
-- 2 · Com-B3: registrar_movimiento_empleado con clave
-- =========================================================================
DO $movimiento$
DECLARE
  v_def text := pg_get_functiondef('public.registrar_movimiento_empleado(bigint,jsonb)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$public.registrar_movimiento_empleado(p_empleado_id bigint, p_movimiento jsonb)$a$,
$r$public.registrar_movimiento_empleado(p_empleado_id bigint, p_movimiento jsonb, p_clave uuid DEFAULT NULL::uuid)$r$,
    1, 'registrar_movimiento_empleado (firma)');
  v_def := pg_temp.parche(v_def,
$a$  v_saldo numeric;
BEGIN
$a$,
$r$  v_saldo numeric;
  -- Com-B3 (#1554): la clave del intento.
  v_contenido text;
  v_previa    public.altas_por_clave%ROWTYPE;
BEGIN
$r$, 1, 'registrar_movimiento_empleado (declaraciones)');
  v_def := pg_temp.parche(v_def,
$a$    RAISE EXCEPTION 'Tu propia cuenta la maneja otro admin: no podés cambiar tu arreglo, tu usuario ni tus movimientos';
  END IF;
  BEGIN
$a$,
$r$    RAISE EXCEPTION 'Tu propia cuenta la maneja otro admin: no podés cambiar tu arreglo, tu usuario ni tus movimientos';
  END IF;
  -- Com-B3 (#1554): la clave del intento (altas_por_clave, como el alta de un
  -- empleado). La misma clave con lo mismo es un reintento: devuelve el
  -- movimiento del primero. Con el empleado ya bloqueado, y antes de las
  -- validaciones: el reintento de un pago que entró chocaría con «más de lo que
  -- se le debe». Sin clave (un PWA de antes), como siempre.
  IF p_clave IS NOT NULL THEN
    v_contenido := md5(jsonb_build_array(p_empleado_id, p_movimiento)::text);
    INSERT INTO altas_por_clave (clave, operacion, usuario_id, sucursal_id, contenido)
    VALUES (p_clave, 'movimiento_empleado', auth.uid(), v_e.sucursal_id, v_contenido)
    ON CONFLICT (clave) DO NOTHING;
    IF NOT FOUND THEN
      SELECT * INTO v_previa FROM altas_por_clave WHERE clave = p_clave;
      IF v_previa.operacion <> 'movimiento_empleado' OR v_previa.usuario_id IS DISTINCT FROM auth.uid() THEN
        RAISE EXCEPTION 'Esta clave ya se usó para otra operación: recargá la página e intentá de nuevo.'
          USING ERRCODE = '22023';
      END IF;
      IF v_previa.contenido <> v_contenido THEN
        RAISE EXCEPTION 'Este movimiento ya se registró con el intento anterior y lo que mandaste ahora es distinto: cerrá esta ventana y revisá la cuenta del empleado.'
          USING ERRCODE = '22023';
      END IF;
      IF v_previa.entidad_id IS NULL OR NOT EXISTS (SELECT 1 FROM empleado_movimientos WHERE id = v_previa.entidad_id) THEN
        RAISE EXCEPTION 'Este movimiento ya se había registrado con el intento anterior y no se encuentra: revisá la cuenta del empleado.'
          USING ERRCODE = '22023';
      END IF;
      -- Un reintento del movimiento que en el medio se revirtió devuelve igual su id,
      -- sin registrarlo de nuevo: es el mismo intento, y la cuenta muestra que está
      -- revertido. Uno nuevo lleva otra clave (el front la cambia al salir bien).
      RETURN v_previa.entidad_id;
    END IF;
  END IF;
  BEGIN
$r$, 1, 'registrar_movimiento_empleado (clave)');
  v_def := pg_temp.parche(v_def,
$a$  RETURNING id INTO v_id;
  RETURN v_id;
$a$,
$r$  RETURNING id INTO v_id;
  IF p_clave IS NOT NULL THEN
    UPDATE altas_por_clave SET entidad_id = v_id WHERE clave = p_clave;
  END IF;
  RETURN v_id;
$r$, 1, 'registrar_movimiento_empleado (la clave apunta al movimiento)');
  DROP FUNCTION public.registrar_movimiento_empleado(bigint, jsonb);
  EXECUTE v_def;
END
$movimiento$;
REVOKE ALL ON FUNCTION public.registrar_movimiento_empleado(bigint, jsonb, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_movimiento_empleado(bigint, jsonb, uuid) TO authenticated, service_role;

-- =========================================================================
-- 3 · Com-B4: _empleado_json con la regla de previsualizar_liquidacion
-- =========================================================================
DO $empleado_json$
DECLARE
  v_def text := pg_get_functiondef('public._empleado_json(public.empleados)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$                 WHERE CASE WHEN ps.desde > p_e.fecha_baja
                            THEN EXISTS (SELECT 1 FROM public._liquidacion_lineas(p_e, ps.hasta) l
                                          WHERE l.tipo = 'inicial' AND abs(l.comision) >= 0.005)
                            ELSE true END));
$a$,
$r$                 -- Com-B4 (#1554): de baja, la regla de previsualizar_liquidacion (los
                 -- totales de _liquidacion_json): comisiones o ajustes distintos de 0. Un
                 -- ajuste negativo solo también se liquida.
                 WHERE CASE WHEN ps.desde > p_e.fecha_baja
                            THEN (SELECT COALESCE(round(sum(l.comision) FILTER (WHERE l.tipo = 'inicial'), 2), 0) <> 0
                                         OR COALESCE(round(sum(l.comision) FILTER (WHERE l.tipo <> 'inicial'), 2), 0) <> 0
                                    FROM public._liquidacion_lineas(p_e, ps.hasta) l)
                            ELSE true END));
$r$, 1, '_empleado_json (período de baja)');
  EXECUTE v_def;
END
$empleado_json$;

-- =========================================================================
-- 5 · m2: la rendición del pago dice si está cerrada
-- =========================================================================
DO $origen$
DECLARE
  v_def text := pg_get_functiondef('public._movimiento_origen_json(public.empleado_movimientos)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$    'rendicion', (SELECT jsonb_build_object('transportista_nombre', tr.nombre, 'fecha', p_m.rendicion_fecha)
$a$,
$r$    -- m2 (#1392): «cerrada» es la regla con la que revertir_movimiento_empleado y
    -- anular_liquidacion la miran (control_rendicion_cerrado). Esa función rechaza
    -- una sucursal que no es de quien llama: ahí revertir tampoco anda, va true y
    -- «de_otra_sucursal» dice por qué.
    'rendicion', (SELECT jsonb_build_object('transportista_nombre', tr.nombre, 'fecha', p_m.rendicion_fecha,
                                            'de_otra_sucursal', auth.uid() IS NOT NULL
                                                              AND NOT EXISTS (SELECT 1 FROM usuario_sucursales us
                                                                               WHERE us.usuario_id = auth.uid()
                                                                                 AND us.sucursal_id = p_m.rendicion_sucursal_id),
                                            'cerrada', CASE WHEN auth.uid() IS NULL
                                                              OR EXISTS (SELECT 1 FROM usuario_sucursales us
                                                                          WHERE us.usuario_id = auth.uid()
                                                                            AND us.sucursal_id = p_m.rendicion_sucursal_id)
                                                            THEN public.control_rendicion_cerrado(p_m.rendicion_transportista_id,
                                                                                                  p_m.rendicion_sucursal_id,
                                                                                                  p_m.rendicion_fecha)
                                                            ELSE true END)
$r$, 1, '_movimiento_origen_json (rendición cerrada)');
  EXECUTE v_def;
END
$origen$;

-- =========================================================================
-- 6 · m3: anular_liquidacion con el usuario de sus comisiones
-- =========================================================================
DO $anular$
DECLARE
  v_def text := pg_get_functiondef('public.anular_liquidacion(bigint,text)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  IF p_motivo IS NULL OR btrim(p_motivo) = '' THEN
    RAISE EXCEPTION 'Escribí por qué se anula';
  END IF;
$a$,
$r$  IF p_motivo IS NULL OR btrim(p_motivo) = '' THEN
    RAISE EXCEPTION 'Escribí por qué se anula';
  END IF;
  -- m3 (#1392): las comisiones iniciales vuelven a quedar pendientes del usuario
  -- con el que se calcularon, y las toma la ficha que hoy lo tiene. Si ya no es
  -- este empleado (se lo pasaron a otra ficha, o se lo sacaron), esas boletas
  -- quedaban sin dueño o para el otro: se rechaza. Sólo las 'inicial': un
  -- 'ajuste' o una 'linea_nueva' vuelve a la ficha por empleado_id, sea cual sea
  -- su usuario (si no, la liquidación con un ajuste del usuario viejo no se podía
  -- anular nunca, ni las anteriores).
  IF EXISTS (SELECT 1 FROM empleado_liquidacion_lineas l
              WHERE l.liquidacion_id = v_l.id AND l.tipo = 'inicial'
                AND l.usuario_id IS DISTINCT FROM v_e.usuario_id) THEN
    RAISE EXCEPTION 'No se puede anular: el usuario con el que se calcularon sus comisiones ya no es el de este empleado. Volvé a vincularle ese usuario para anularla, o corregí la diferencia con un ajuste';
  END IF;
$r$, 1, 'anular_liquidacion (usuario de las comisiones)');
  EXECUTE v_def;
END
$anular$;

-- =========================================================================
-- 7 · m4: la comisión sin liquidar de una ficha
-- =========================================================================
CREATE FUNCTION public._empleado_comision_sin_liquidar(p_e public.empleados)
RETURNS numeric
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $function$
  -- m4 (#1392): lo que todavía no se le liquidó al empleado, entregado hasta hoy:
  -- las comisiones y los ajustes de _liquidacion_lineas (la cuenta de
  -- previsualizar_liquidacion y de liquidar_empleado, sobre _comision_lineas), en
  -- la sucursal de la ficha (o las dos).
  SELECT COALESCE(round(sum(l.comision), 2), 0)
    FROM public._liquidacion_lineas(p_e, public._tablero_hoy()) l;
$function$;
REVOKE ALL ON FUNCTION public._empleado_comision_sin_liquidar(public.empleados) FROM PUBLIC, anon, authenticated;

-- El motivo por el que no se lo pasa de sucursal, o no se le cambia ni se le saca
-- el usuario (p_cambio 'sucursal' o 'usuario'; NULL: no tiene nada pendiente).
-- Una sola redacción: la usan guardar_empleado y la ficha (comision_sin_liquidar_empleado).
CREATE FUNCTION public._empleado_aviso_comision_sin_liquidar(p_e public.empleados, p_cambio text)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_pend    numeric := public._empleado_comision_sin_liquidar(p_e);
  v_desde   date;
  v_frec    text;
  v_plata   text;
  v_suc     text;
  v_antes   text;
  v_despues text;
BEGIN
  IF p_cambio IS NULL OR p_cambio NOT IN ('sucursal', 'usuario') THEN
    RAISE EXCEPTION '_empleado_aviso_comision_sin_liquidar: cambio desconocido %', p_cambio;
  END IF;
  IF v_pend = 0 THEN
    RETURN NULL;
  END IF;
  v_antes   := CASE p_cambio WHEN 'sucursal' THEN 'pasarlo de sucursal' ELSE 'cambiarle o sacarle el usuario' END;
  v_despues := CASE p_cambio WHEN 'sucursal' THEN 'pasalo de sucursal' ELSE 'cambiale o sacale el usuario' END;
  v_plata := CASE WHEN v_pend < 0 THEN '-' ELSE '' END || '$ '
             || translate(to_char(abs(v_pend), 'FM999,999,999,990.00'), ',.', '.,');
  v_suc := CASE WHEN p_e.de_las_dos THEN 'las dos sucursales'
                ELSE COALESCE((SELECT s.nombre FROM sucursales s WHERE s.id = p_e.sucursal_id), 'su sucursal') END;
  SELECT ps.desde, ps.frecuencia INTO v_desde, v_frec FROM public._empleado_periodo_siguiente(p_e) ps;
  -- Ya se liquidó el período en curso y hoy se entregó algo más: eso entra en el
  -- próximo, que liquidar_empleado no deja liquidar antes de que empiece. Se dice
  -- desde cuándo, para que el «liquidalo antes» no quede sin salida.
  IF v_desde > public._tablero_hoy() THEN
    RETURN format('Tiene %s de comisión sin liquidar en %s, de %s: se puede liquidar desde el %s %s; %s después',
                  v_plata, v_suc, CASE WHEN v_frec = 'mensual' THEN 'este mes' ELSE 'esta semana' END,
                  (ARRAY['lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado', 'domingo'])[extract(isodow FROM v_desde)::int],
                  to_char(v_desde, 'FMDD/FMMM'), v_despues);
  END IF;
  RETURN format('Tiene %s de comisión sin liquidar en %s: liquidalo antes de %s', v_plata, v_suc, v_antes);
END
$function$;
REVOKE ALL ON FUNCTION public._empleado_aviso_comision_sin_liquidar(public.empleados, text) FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.comision_sin_liquidar_empleado(p_empleado_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
-- m4 (#1392): para que la ficha avise antes de cambiar de sucursal a un empleado
-- con comisión sin liquidar: el monto y el mismo motivo con que guardar_empleado lo
-- rechaza (aviso NULL: se puede mover). aviso_usuario, lo mismo para cambiarle o
-- sacarle el usuario (decisión del dueño del 26/11).
DECLARE
  v_e empleados%ROWTYPE;
BEGIN
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin ve y carga el personal' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_e FROM empleados WHERE id = p_empleado_id;
  IF NOT FOUND OR NOT public._empleado_visible(v_e.sucursal_id, v_e.de_las_dos) THEN
    RAISE EXCEPTION 'Ese empleado no existe o no lo podés ver';
  END IF;
  RETURN jsonb_build_object('monto', public._empleado_comision_sin_liquidar(v_e),
                            'aviso', public._empleado_aviso_comision_sin_liquidar(v_e, 'sucursal'),
                            'aviso_usuario', public._empleado_aviso_comision_sin_liquidar(v_e, 'usuario'));
END
$function$;
REVOKE ALL ON FUNCTION public.comision_sin_liquidar_empleado(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.comision_sin_liquidar_empleado(bigint) TO authenticated, service_role;

-- =========================================================================
-- 4 y 7 · guardar_empleado: la ficha de cliente propia y lo pendiente al
--         cambiar de sucursal
-- =========================================================================
DO $guardar$
DECLARE
  v_def text := pg_get_functiondef('public.guardar_empleado(jsonb)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  v_previa    public.altas_por_clave%ROWTYPE;
BEGIN
$a$,
$r$  v_previa    public.altas_por_clave%ROWTYPE;
  -- m4 (#1392): el motivo por el que no se lo cambia de sucursal (ni de usuario).
  v_aviso     text;
BEGIN
$r$, 1, 'guardar_empleado (declaraciones)');
  v_def := pg_temp.parche(v_def,
$a$  IF v_mueve AND NOT public._tiene_todas_las_sucursales() THEN
    RAISE EXCEPTION 'La sucursal y «las dos» sólo las cambia un admin de todas las sucursales';
  END IF;
$a$,
$r$  IF v_mueve AND NOT public._tiene_todas_las_sucursales() THEN
    RAISE EXCEPTION 'La sucursal y «las dos» sólo las cambia un admin de todas las sucursales';
  END IF;
  -- m4 (#1392, decisión del dueño del 25/11): lo pendiente no se arrastra de una
  -- sucursal a otra; cada sucursal paga lo que se vendió en ella. Con comisión
  -- sin liquidar (en la sucursal de hoy, o en las dos) no se cambia: primero se
  -- liquida. La ficha lo avisa antes con comision_sin_liquidar_empleado.
  IF v_mueve THEN
    v_aviso := public._empleado_aviso_comision_sin_liquidar(v_viejo, 'sucursal');
    IF v_aviso IS NOT NULL THEN
      RAISE EXCEPTION '%', v_aviso;
    END IF;
  END IF;
  -- Decisión del dueño del 26/11: tampoco se le saca el usuario ni se le pasa
  -- otro. Lo pendiente es del usuario de la ficha: soltado, queda sin ficha que lo
  -- liquide. Vincular un usuario a una ficha que no tenía no se frena.
  IF v_id IS NOT NULL AND v_viejo.usuario_id IS NOT NULL AND v_usr IS DISTINCT FROM v_viejo.usuario_id THEN
    v_aviso := public._empleado_aviso_comision_sin_liquidar(v_viejo, 'usuario');
    IF v_aviso IS NOT NULL THEN
      RAISE EXCEPTION '%', v_aviso;
    END IF;
  END IF;
$r$, 1, 'guardar_empleado (m4)');
  v_def := pg_temp.parche(v_def,
$a$  END IF;

  -- 6 · vinculos.$a$,
$r$  END IF;
  -- Com-B5 (decisión del dueño del 25/11): tampoco la ficha de cliente de la
  -- propia cuenta (ni sacarla ni cambiarla): soltada, otro admin se la vincula a
  -- otro empleado y le carga un adelanto de sueldo que no es suyo.
  IF v_id IS NOT NULL AND v_viejo.usuario_id = v_uid AND v_cli IS DISTINCT FROM v_viejo.cliente_id THEN
    RAISE EXCEPTION 'Tu propia cuenta la maneja otro admin: no podés cambiar tu ficha de cliente';
  END IF;

  -- 6 · vinculos.$r$, 1, 'guardar_empleado (Com-B5)');
  EXECUTE v_def;
END
$guardar$;

-- ---------------------------------------------------------------------------
-- Poscondiciones
-- ---------------------------------------------------------------------------
DO $pos$
DECLARE
  r record;
  v text;
BEGIN
  IF to_regprocedure('public.registrar_movimiento_empleado(bigint,jsonb)') IS NOT NULL
     OR to_regprocedure('public.liquidar_empleado(bigint,jsonb)') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · quedó una firma vieja (dos sobrecargas: PGRST203)';
  END IF;
  -- Los cuerpos que deja esta migración.
  FOR r IN SELECT * FROM (VALUES
    ('public.registrar_movimiento_empleado(bigint,jsonb,uuid)', '9b31925ab82d19d6b64b409677d24c4a'),
    ('public.liquidar_empleado(bigint,jsonb,uuid)', 'eeecb4cc3602c310ca26ecbe7ba327a5'),
    ('public.anular_liquidacion(bigint,text)', '4b82927bd1086c7b369dddac50d0a142'),
    ('public.guardar_empleado(jsonb)', '09718d8accf2965619cf25d644292a76'),
    ('public._empleado_json(public.empleados)', '05d767c3dab2a4b218d92802c37615ee'),
    ('public._liquidacion_json(public.empleados,date,date,numeric)', '91f898e4be9e37699c73dc61b26b2fb7'),
    ('public._movimiento_origen_json(public.empleado_movimientos)', '4e6026a6c51ac095a4d8030f3ba30a60'),
    ('public.gastos_cuenta_empleado()', 'cb2e72fc8d088ba4c51a7920b009386e'),
    ('public._empleado_corte_movimientos(bigint)', 'da9efdc59f183da5d1e718994d2b6b67'),
    ('public._empleado_comision_sin_liquidar(public.empleados)', '7078278b5f20c22850036bf658d5737d'),
    ('public._empleado_aviso_comision_sin_liquidar(public.empleados,text)', '84d938a72443a71daa2f686ac2b2a74c'),
    ('public.comision_sin_liquidar_empleado(bigint)', 'b2981349f885dfb6e4e887dacd562957')
  ) AS t(f, h) LOOP
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como se esperaba (md5 %)', r.f, v;
    END IF;
  END LOOP;
  -- search_path terminado en pg_temp y los grants: las RPC de authenticated (sin
  -- anon), y las de server sin ninguno de los dos.
  FOR r IN SELECT * FROM (VALUES
    ('public.registrar_movimiento_empleado(bigint,jsonb,uuid)', true),
    ('public.liquidar_empleado(bigint,jsonb,uuid)', true),
    ('public.comision_sin_liquidar_empleado(bigint)', true),
    ('public.anular_liquidacion(bigint,text)', true),
    ('public.guardar_empleado(jsonb)', true),
    ('public._empleado_corte_movimientos(bigint)', false),
    ('public._empleado_comision_sin_liquidar(public.empleados)', false),
    ('public._empleado_aviso_comision_sin_liquidar(public.empleados,text)', false),
    ('public._empleado_json(public.empleados)', false),
    ('public._liquidacion_json(public.empleados,date,date,numeric)', false),
    ('public._movimiento_origen_json(public.empleado_movimientos)', false)
  ) AS t(f, rpc) LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = r.f::regprocedure
                    AND p.proconfig @> ARRAY['search_path=public, pg_temp']) THEN
      RAISE EXCEPTION 'mig NNN · % no fija search_path = public, pg_temp', r.f;
    END IF;
    IF has_function_privilege('anon', r.f, 'EXECUTE')
       OR has_function_privilege('authenticated', r.f, 'EXECUTE') IS DISTINCT FROM r.rpc THEN
      RAISE EXCEPTION 'mig NNN · los grants de % no quedaron bien', r.f;
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = 'public.gastos_cuenta_empleado()'::regprocedure AND prosecdef) THEN
    RAISE EXCEPTION 'mig NNN · gastos_cuenta_empleado dejó de ser SECURITY DEFINER';
  END IF;
  -- El CHECK quedó con las operaciones de antes más las dos de esta migración, y nada más.
  SELECT pg_get_constraintdef(oid) INTO v FROM pg_constraint
   WHERE conrelid = 'public.altas_por_clave'::regclass AND conname = 'altas_por_clave_operacion_check';
  IF (SELECT array_agg(DISTINCT m[1] ORDER BY m[1]) FROM regexp_matches(v, '''([a-z_]+)''::text', 'g') AS m)
     IS DISTINCT FROM
     (SELECT array_agg(DISTINCT o ORDER BY o)
        FROM unnest(string_to_array(current_setting('mig_t6.operaciones_antes'), ',')
                    || ARRAY['movimiento_empleado', 'liquidacion_empleado']) AS o) THEN
    RAISE EXCEPTION 'mig NNN · el CHECK de altas_por_clave no quedó con las de antes más las dos nuevas (%)', v;
  END IF;
END
$pos$;

COMMIT;
