-- =========================================================================
-- 450 · GASTOS 7 · ROTURAS A CARGO DEL EMPLEADO (entrega 7 de gastos)
--
-- Diseno: docs/superpowers/specs/2026-11-04-roturas-a-cargo-del-empleado-design.md
-- Plan:   docs/superpowers/plans/2026-11-04-gastos-7-roturas-a-cargo-del-empleado.md (Tarea 2)
-- Ensayo: scripts/test-gastos-7.sql
--
-- Al cargar una baja de stock, o al resolver una salvedad de mercaderia
-- danada, vencida o faltante, el admin le puede cargar el costo a uno o mas
-- empleados. Cada linea es un movimiento 'rotura' (-) en su cuenta, que la
-- liquidacion descuenta como cualquier otro.
--
-- QUE AGREGA
--   * empleado_movimientos.merma_id y .salvedad_id: la 'rotura' apunta a
--     exactamente una de las dos (CHECK rotura_origen). Su compensacion es otra
--     'rotura', positiva, con revierte_id y la misma referencia.
--   * _cargar_roturas: valida y escribe las lineas. De server: sin EXECUTE
--     para authenticated.
--   * registrar_merma_manual y resolver_salvedad con p_cargos jsonb DEFAULT
--     NULL. Las firmas viejas se dropean (PGRST203).
--   * resolver_salvedad: 'descuento_transportista' (en la UI, «A cargo de
--     empleados») es solo de admin, sobre danado, vencido o faltante, y con al
--     menos una linea; ninguna otra resolucion lleva lineas. La salvedad se
--     lockea antes de mirar si esta pendiente: dos resoluciones a la vez ya no
--     pueden cargar dos veces.
--   * anular_salvedad revierte las 'rotura' vivas de su salvedad.
--   * revertir_movimiento_empleado revierte la 'rotura' de una merma (la
--     merma manual no se anula: lo que estaba mal era a quien se le cobro), y
--     rechaza la de una salvedad, que se deshace anulando la salvedad.
--   * _movimiento_origen_json suma merma_id y salvedad_id, asi los ven la
--     cuenta y la liquidacion.
--
-- POR QUE EN LA MISMA LLAMADA. registrar_merma_manual no es idempotente: un
-- segundo llamado para el cargo podria fallar con la merma ya hecha, o
-- repetirse. Viaja en la misma transaccion, y si el cargo falla no hay merma.
--
-- POR QUE LA SALVEDAD Y NO SU MERMA. La merma de una salvedad la deja
-- registrar_salvedad, no la resolucion; y un faltante sobre un regalo no tiene
-- (#847). El cargo apunta a la salvedad, que siempre existe.
--
-- EL ORDEN DE LOS LOCKS. Merma: el producto (como hoy) y despues los
-- empleados, por id. Salvedad: la salvedad y despues los empleados, por id;
-- anular_salvedad los lockea justo despues de la salvedad, antes del pedido.
-- Ningun camino lockea un empleado y despues una salvedad o un producto.
--
-- EL BUNDLE VIEJO. Llama con los argumentos de antes y resuelven por los
-- DEFAULT: la merma sin cargo es la de hoy (mas 'cargos': []), y la salvedad
-- se resuelve como hoy salvo 'descuento_transportista', que nunca se uso
-- (0 filas) y ahora pide el cargo.
--
-- DESPLIEGUE. Toca empleado_movimientos (dos columnas nullable, CHECKs y FKs):
-- locks breves; con lock_timeout de 5s, si choca se reintenta.
-- =========================================================================

SET LOCAL lock_timeout = '5s';

-- -------------------------------------------------------------------------
-- 0 · Las funciones que se reescriben son las de hoy
-- -------------------------------------------------------------------------
-- md5(prosrc) de prod al 2026-11-04. _movimiento_origen_json lleva CRLF.
DO $vivas$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('public.registrar_merma_manual(bigint,integer,text,text,bigint)', '8b9d03b14baf86cd171e4c3b856d09d2'),
      ('public.resolver_salvedad(bigint,character varying,text,bigint)', '8528b9e2c7819615261084e99e5c00ce'),
      ('public.anular_salvedad(bigint,text)', 'da097db9642be74e4853dccaab948941'),
      ('public.revertir_movimiento_empleado(bigint,text)', '77ac954dddc9753fce5a6c5968f20c39'),
      ('public._movimiento_origen_json(empleado_movimientos)', '791da0c0e11600728a6b57f9f248b3ba')) AS v(firma, md5)
  LOOP
    IF to_regprocedure(r.firma) IS NULL
       OR (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure(r.firma)) <> r.md5 THEN
      RAISE EXCEPTION '% no es la de prod del 2026-11-04: rehacer la migracion sobre la definicion viva', r.firma;
    END IF;
  END LOOP;
END
$vivas$;

-- -------------------------------------------------------------------------
-- 1 · empleado_movimientos: el tipo 'rotura' y a que apunta
-- -------------------------------------------------------------------------
ALTER TABLE public.empleado_movimientos
  ADD COLUMN merma_id    bigint REFERENCES public.mermas_stock(id),
  ADD COLUMN salvedad_id bigint REFERENCES public.salvedades_items(id);

ALTER TABLE public.empleado_movimientos DROP CONSTRAINT empleado_movimientos_tipo_check;
ALTER TABLE public.empleado_movimientos ADD CONSTRAINT empleado_movimientos_tipo_check
  CHECK (tipo IN ('mercaderia', 'reintegro', 'adelanto', 'ajuste', 'sueldo', 'comision', 'ajuste_comision', 'pago',
                  'faltante', 'rotura'));
ALTER TABLE public.empleado_movimientos ADD CONSTRAINT empleado_movimientos_rotura_negativa
  CHECK (tipo <> 'rotura' OR revierte_id IS NOT NULL OR monto < 0);
ALTER TABLE public.empleado_movimientos ADD CONSTRAINT empleado_movimientos_rotura_origen
  CHECK ((tipo = 'rotura') = (num_nonnulls(merma_id, salvedad_id) = 1));

CREATE INDEX empleado_movimientos_merma_idx
  ON public.empleado_movimientos (merma_id) WHERE merma_id IS NOT NULL;
CREATE INDEX empleado_movimientos_salvedad_idx
  ON public.empleado_movimientos (salvedad_id) WHERE salvedad_id IS NOT NULL;

-- -------------------------------------------------------------------------
-- 2 · _cargar_roturas: las lineas de un cargo
-- -------------------------------------------------------------------------
-- p_cargos = [{"empleado_id": n, "monto": n}], monto > 0 (lo que se descuenta).
-- Sin tope contra el costo: decide el admin. Devuelve los ids, en el orden de
-- las lineas. Las mismas reglas que una linea de faltante (gastos 6).
CREATE FUNCTION public._cargar_roturas(p_cargos jsonb, p_sucursal_id bigint, p_merma_id bigint,
                                       p_salvedad_id bigint, p_obs text)
RETURNS bigint[]
LANGUAGE plpgsql
SET search_path = public
AS $fn$
DECLARE
  v_ids     bigint[] := '{}';
  v_emp_ids bigint[];
  v_eid     bigint;
  v_e       empleados%ROWTYPE;
  v_l       jsonb;
  v_id      bigint;
BEGIN
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin le carga una rotura a un empleado' USING ERRCODE = '42501';
  END IF;
  IF num_nonnulls(p_merma_id, p_salvedad_id) <> 1 THEN
    RAISE EXCEPTION '_cargar_roturas: la rotura es de una merma o de una salvedad';
  END IF;
  IF jsonb_typeof(p_cargos) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'El cargo a empleados viene con un formato inválido';
  END IF;
  IF jsonb_array_length(p_cargos) = 0 THEN
    RAISE EXCEPTION 'Elegí al menos un empleado para cargarle la rotura';
  END IF;
  BEGIN
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_cargos) l
                WHERE jsonb_typeof(l) <> 'object'
                   OR jsonb_typeof(COALESCE(l->'empleado_id', 'null')) = 'null'
                   OR jsonb_typeof(COALESCE(l->'monto', 'null')) = 'null') THEN
      RAISE EXCEPTION 'formato';
    END IF;
    PERFORM (l->>'empleado_id')::bigint, (l->>'monto')::numeric FROM jsonb_array_elements(p_cargos) l;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_cargos) l
                WHERE abs((l->>'monto')::numeric) > 9999999999.99) THEN
      RAISE EXCEPTION 'formato';
    END IF;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'El cargo a empleados viene con un formato inválido: cada línea lleva un empleado y un monto';
  END;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_cargos) l WHERE round((l->>'monto')::numeric, 2) <= 0) THEN
    RAISE EXCEPTION 'Cada línea del cargo lleva un monto mayor a 0';
  END IF;
  IF (SELECT count(DISTINCT (l->>'empleado_id')::bigint) FROM jsonb_array_elements(p_cargos) l)
     <> jsonb_array_length(p_cargos) THEN
    RAISE EXCEPTION 'Un empleado aparece en dos líneas: juntá sus montos en una';
  END IF;

  -- Los empleados por id: el orden de registrar_movimiento_empleado.
  v_emp_ids := ARRAY(SELECT (l->>'empleado_id')::bigint FROM jsonb_array_elements(p_cargos) l ORDER BY 1);
  FOREACH v_eid IN ARRAY v_emp_ids LOOP
    SELECT * INTO v_e FROM empleados WHERE id = v_eid FOR UPDATE;
    IF NOT FOUND OR NOT public._empleado_visible(v_e.sucursal_id, v_e.de_las_dos) THEN
      RAISE EXCEPTION 'Ese empleado no existe o no lo podés ver';
    END IF;
    IF NOT v_e.activo THEN
      RAISE EXCEPTION 'Ese empleado está dado de baja';
    END IF;
    IF v_e.sucursal_id <> p_sucursal_id AND NOT v_e.de_las_dos THEN
      RAISE EXCEPTION 'Ese empleado no es de esta sucursal';
    END IF;
    IF v_e.usuario_id = auth.uid() THEN
      RAISE EXCEPTION 'Tu propia cuenta la maneja otro admin: no podés cargarte una rotura';
    END IF;
  END LOOP;

  FOR v_l IN SELECT l FROM jsonb_array_elements(p_cargos) WITH ORDINALITY AS x(l, n) ORDER BY n LOOP
    INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, observacion, creado_por, merma_id, salvedad_id)
    VALUES ((v_l->>'empleado_id')::bigint, public._tablero_hoy(), 'rotura', -round((v_l->>'monto')::numeric, 2),
            p_obs, auth.uid(), p_merma_id, p_salvedad_id)
    RETURNING id INTO v_id;
    v_ids := v_ids || v_id;
  END LOOP;
  RETURN v_ids;
END
$fn$;

-- -------------------------------------------------------------------------
-- 3 · registrar_merma_manual con el cargo
-- -------------------------------------------------------------------------
-- El cuerpo es el de hoy (mig 232) hasta el RETURN; el cargo va al final, con
-- la merma ya escrita y su costo congelado.
DROP FUNCTION public.registrar_merma_manual(bigint, integer, text, text, bigint);

CREATE FUNCTION public.registrar_merma_manual(
  p_producto_id   bigint,
  p_cantidad      integer,
  p_motivo        text,
  p_observaciones text DEFAULT NULL,
  p_sucursal_id   bigint DEFAULT NULL,
  p_cargos        jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_sucursal bigint := public.current_sucursal_id();
  v_rol      text;
  v_obs      text;
  v_stock    integer;
  v_merma    public.mermas_stock%ROWTYPE;
  v_nombre   text;
  v_cargos   bigint[] := '{}';
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la sucursal activa';
  END IF;

  -- p_sucursal_id NO elige la sucursal: la elige current_sucursal_id(), que
  -- valida la membresia contra usuario_sucursales. El parametro esta para que
  -- el replay offline -- que reenvia una merma cargada en otra sucursal --
  -- choque con un error claro en vez de escribir en la sucursal equivocada.
  IF p_sucursal_id IS NOT NULL AND p_sucursal_id <> v_sucursal THEN
    RAISE EXCEPTION 'La merma es de la sucursal % y la sesion esta en la %: cambia de sucursal y reintenta',
      p_sucursal_id, v_sucursal;
  END IF;

  SELECT rol INTO v_rol FROM public.perfiles WHERE id = auth.uid();
  IF v_rol IS NULL OR v_rol <> 'admin' THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin';
  END IF;

  IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
    RAISE EXCEPTION 'La cantidad a dar de baja tiene que ser mayor a 0';
  END IF;

  IF p_motivo IS NULL OR p_motivo NOT IN ('rotura', 'vencimiento', 'robo', 'decomiso',
                                          'devolucion', 'error_inventario', 'muestra', 'otro') THEN
    RAISE EXCEPTION 'Motivo de merma invalido: %', COALESCE(p_motivo, '(vacio)');
  END IF;

  v_obs := NULLIF(btrim(COALESCE(p_observaciones, '')), '');

  -- El FOR UPDATE es todo el arreglo: la segunda merma concurrente espera aca
  -- y lee el stock que dejo la primera, en vez de pisarla con su snapshot.
  SELECT stock, nombre INTO v_stock, v_nombre
    FROM public.productos
   WHERE id = p_producto_id AND sucursal_id = v_sucursal
     FOR UPDATE;

  IF v_stock IS NULL THEN
    RAISE EXCEPTION 'El producto % no existe en esta sucursal', p_producto_id;
  END IF;

  IF v_stock < p_cantidad THEN
    RAISE EXCEPTION 'El stock del producto es % y la baja es de %: dejaria stock negativo',
      v_stock, p_cantidad;
  END IF;

  -- stock_anterior/stock_nuevo salen del valor LOCKEADO, no del cliente.
  -- stock_nuevo = GREATEST(stock_anterior - cantidad, 0) es el invariante
  -- MERMA-B; usuario_id nunca NULL es MERMA-I. El costo lo congela solo
  -- trg_mermas_snapshot_costo (mig 119).
  INSERT INTO public.mermas_stock (
    producto_id, cantidad, motivo, observaciones,
    stock_anterior, stock_nuevo, usuario_id, sucursal_id
  ) VALUES (
    p_producto_id, p_cantidad, p_motivo, v_obs,
    v_stock, GREATEST(v_stock - p_cantidad, 0), auth.uid(), v_sucursal
  )
  RETURNING * INTO v_merma;

  -- Incremental, nunca absoluto, y etiquetado para el ledger.
  PERFORM set_config('app.stock_origen',   'merma',           true);
  PERFORM set_config('app.stock_ref_tipo', 'mermas_stock',    true);
  PERFORM set_config('app.stock_ref_id',   v_merma.id::text,  true);
  PERFORM set_config('app.stock_user_id',  auth.uid()::text,  true);

  UPDATE public.productos
     SET stock = stock - p_cantidad,
         updated_at = now()
   WHERE id = p_producto_id AND sucursal_id = v_sucursal;

  -- gastos 7: el cargo a empleados, en la misma transaccion. Si falla, no hay
  -- merma. JSON null o [] es «sin cargo».
  IF p_cargos IS NOT NULL AND jsonb_typeof(p_cargos) <> 'null'
     AND NOT (jsonb_typeof(p_cargos) = 'array' AND jsonb_array_length(p_cargos) = 0) THEN
    v_cargos := public._cargar_roturas(p_cargos, v_sucursal, v_merma.id, NULL,
                                       'Rotura: ' || p_cantidad || ' u. de ' || COALESCE(v_nombre, 'producto #' || p_producto_id));
  END IF;

  RETURN jsonb_build_object(
    'ok',     true,
    'merma',  to_jsonb(v_merma),
    'stock',  v_stock - p_cantidad,
    'cargos', to_jsonb(v_cargos)
  );
END;
$fn$;

-- -------------------------------------------------------------------------
-- 4 · resolver_salvedad con el cargo
-- -------------------------------------------------------------------------
DROP FUNCTION public.resolver_salvedad(bigint, character varying, text, bigint);

CREATE FUNCTION public.resolver_salvedad(
  p_salvedad_id            bigint,
  p_estado_resolucion      character varying,
  p_notas                  text DEFAULT NULL,
  p_pedido_reprogramado_id bigint DEFAULT NULL,
  p_cargos                 jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_salvedad RECORD;
  v_usuario_id UUID := auth.uid();
  v_con_cargo BOOLEAN := p_cargos IS NOT NULL AND jsonb_typeof(p_cargos) <> 'null'
                         AND NOT (jsonb_typeof(p_cargos) = 'array' AND jsonb_array_length(p_cargos) = 0);
  v_nombre   TEXT;
  v_cargos   BIGINT[] := '{}';
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;
  -- mig 252: resolver una salvedad no mueve stock ni plata: solo dice quien se
  -- hace cargo. Lo puede el encargado, que es el que ya las registra (mig 065).
  -- Anularlas --que si mueve las dos cosas-- sigue siendo de admin.
  -- El espejo en la UI es `puedeResolverSalvedad`.
  IF NOT es_encargado_o_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin o encargado');
  END IF;
  -- mig 244 (#621): anular NO es una resolucion. Restituye la linea del pedido,
  -- recalcula los totales y revierte la merma; esta funcion sólo escribe un
  -- estado. Marcar 'anulada' por aca dejaba la plata y el stock donde estaban y
  -- ademas trababa a anular_salvedad para siempre ('Ya anulada').
  IF p_estado_resolucion = 'anulada' THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Anular una salvedad no es una resolucion: mueve stock y plata. Usar la accion "Anular salvedad" (RPC anular_salvedad).',
      'codigo', 'usar_anular_salvedad'
    );
  END IF;
  -- gastos 7: «A cargo de empleados» (descuento_transportista) es la unica
  -- resolucion que cobra, y la decide el admin. Las demas no llevan lineas.
  IF v_con_cargo AND p_estado_resolucion IS DISTINCT FROM 'descuento_transportista' THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Sólo «A cargo de empleados» le carga la salvedad a alguien');
  END IF;
  IF p_estado_resolucion = 'descuento_transportista' THEN
    IF NOT es_admin() THEN
      RETURN jsonb_build_object('success', false, 'error',
        'Sólo un admin le carga una salvedad a un empleado');
    END IF;
    IF NOT v_con_cargo THEN
      RETURN jsonb_build_object('success', false, 'error',
        'Elegí al menos un empleado para cargarle la salvedad');
    END IF;
  END IF;
  -- gastos 7: lockeada. Con el cargo, dos resoluciones a la vez cobrarian dos
  -- veces; la segunda espera y ve 'Ya resuelta'.
  SELECT * INTO v_salvedad FROM salvedades_items WHERE id = p_salvedad_id AND sucursal_id = v_sucursal
     FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'No encontrada'); END IF;
  IF v_salvedad.estado_resolucion != 'pendiente' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Ya resuelta');
  END IF;
  IF p_estado_resolucion = 'descuento_transportista'
     AND v_salvedad.motivo NOT IN ('producto_danado', 'producto_vencido', 'faltante_stock') THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Sólo una salvedad por mercadería dañada, vencida o faltante se le carga a un empleado');
  END IF;
  -- El cargo antes que el estado: si falla, no se escribio nada.
  IF v_con_cargo THEN
    SELECT nombre INTO v_nombre FROM productos WHERE id = v_salvedad.producto_id AND sucursal_id = v_sucursal;
    BEGIN
      v_cargos := public._cargar_roturas(p_cargos, v_sucursal, NULL, p_salvedad_id,
                                         'Rotura: ' || v_salvedad.cantidad_afectada || ' u. de '
                                         || COALESCE(v_nombre, 'producto #' || v_salvedad.producto_id)
                                         || ' · salvedad #' || p_salvedad_id);
    EXCEPTION WHEN others THEN
      RETURN jsonb_build_object('success', false, 'error', SQLERRM);
    END;
  END IF;
  UPDATE salvedades_items SET
    estado_resolucion = p_estado_resolucion,
    resolucion_notas = p_notas,
    resolucion_fecha = NOW(),
    resuelto_por = v_usuario_id,
    pedido_reprogramado_id = p_pedido_reprogramado_id,
    updated_at = NOW()
  WHERE id = p_salvedad_id AND sucursal_id = v_sucursal;
  INSERT INTO salvedad_historial (salvedad_id, accion, estado_anterior, estado_nuevo, notas, usuario_id, sucursal_id)
  VALUES (p_salvedad_id, 'resolucion', v_salvedad.estado_resolucion, p_estado_resolucion, p_notas, v_usuario_id, v_sucursal);
  RETURN jsonb_build_object('success', true, 'nuevo_estado', p_estado_resolucion, 'cargos', to_jsonb(v_cargos));
END;
$fn$;

-- -------------------------------------------------------------------------
-- 5 · anular_salvedad revierte sus roturas
-- -------------------------------------------------------------------------
-- Parche por anclas sobre la definicion viva, como la 433: el cuerpo tiene
-- ~350 lineas y una copia a mano puede perder algo sin que falle nada.
--   a) dos variables nuevas;
--   b) los empleados de las roturas vivas, lockeados despues de la salvedad, y
--      el rechazo si alguna es del que anula (nadie se carga movimientos a si
--      mismo, tampoco la compensacion: deshacer_resolucion_rendicion igual);
--   c) la compensacion de cada rotura viva, antes de marcar la salvedad.
DO $parche$
DECLARE
  v_def text := pg_get_functiondef('public.anular_salvedad(bigint,text)'::regprocedure);
  v_a   text := $a$  v_caja_cerrada  TEXT;
BEGIN
$a$;
  v_a2  text := $a$  v_caja_cerrada  TEXT;
  -- gastos 7: las roturas a cargo de empleados.
  v_rot_emp       BIGINT[];
  r_rot           RECORD;
BEGIN
$a$;
  v_b   text := $b$  IF v_salvedad.estado_resolucion = 'anulada' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Ya anulada');
  END IF;
$b$;
  v_b2  text := $b$  IF v_salvedad.estado_resolucion = 'anulada' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Ya anulada');
  END IF;

  -- gastos 7: los empleados de las roturas vivas de esta salvedad, despues
  -- de la salvedad y antes que nada mas (el orden de _cargar_roturas). Una
  -- rotura viva es la que nadie compenso.
  v_rot_emp := ARRAY(SELECT DISTINCT m.empleado_id FROM empleado_movimientos m
                      WHERE m.salvedad_id = p_salvedad_id AND m.tipo = 'rotura' AND m.revierte_id IS NULL
                        AND NOT EXISTS (SELECT 1 FROM empleado_movimientos rv WHERE rv.revierte_id = m.id)
                      ORDER BY 1);
  PERFORM 1 FROM empleados WHERE id = ANY (v_rot_emp) ORDER BY id FOR UPDATE;
  IF EXISTS (SELECT 1 FROM empleados WHERE id = ANY (v_rot_emp) AND usuario_id = v_usuario_id) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Esta salvedad le cargó una rotura a tu propia cuenta: la anula otro admin', 'codigo', 'rotura_propia');
  END IF;
$b$;
  v_c   text := $c$  UPDATE salvedades_items SET
    estado_resolucion = 'anulada',
$c$;
  v_c2  text := $c$  -- gastos 7: cada rotura viva se compensa, con la misma salvedad. Si ya
  -- estaba liquidada, la compensacion entra en la liquidacion siguiente.
  FOR r_rot IN
    SELECT m.* FROM empleado_movimientos m
     WHERE m.salvedad_id = p_salvedad_id AND m.tipo = 'rotura' AND m.revierte_id IS NULL
       AND NOT EXISTS (SELECT 1 FROM empleado_movimientos rv WHERE rv.revierte_id = m.id)
     ORDER BY m.id
  LOOP
    INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, observacion, revierte_id, creado_por, salvedad_id)
    VALUES (r_rot.empleado_id, public._tablero_hoy(), 'rotura', -r_rot.monto,
            'Anulación de la salvedad #' || p_salvedad_id || COALESCE(': ' || NULLIF(btrim(p_notas), ''), ''),
            r_rot.id, v_usuario_id, p_salvedad_id);
  END LOOP;

  UPDATE salvedades_items SET
    estado_resolucion = 'anulada',
$c$;
  v_n int;
BEGIN
  v_n := (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'gastos_7 · el ancla a de anular_salvedad aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  v_n := (length(v_def) - length(replace(v_def, v_b, ''))) / length(v_b);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'gastos_7 · el ancla b de anular_salvedad aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  v_n := (length(v_def) - length(replace(v_def, v_c, ''))) / length(v_c);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'gastos_7 · el ancla c de anular_salvedad aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(replace(replace(v_def, v_a, v_a2), v_b, v_b2), v_c, v_c2);
END
$parche$;

-- -------------------------------------------------------------------------
-- 6 · revertir_movimiento_empleado: la rotura de una merma
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.revertir_movimiento_empleado(p_movimiento_id bigint, p_motivo text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_m  empleado_movimientos%ROWTYPE;
  v_e  empleados%ROWTYPE;
  v_id bigint;
BEGIN
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin ve y carga el personal' USING ERRCODE = '42501';
  END IF;
  -- El empleado antes que el movimiento: el mismo orden de locks que
  -- registrar_movimiento_empleado.
  SELECT e.* INTO v_e FROM empleados e JOIN empleado_movimientos m ON m.empleado_id = e.id
   WHERE m.id = p_movimiento_id FOR UPDATE OF e;
  IF NOT FOUND OR NOT public._empleado_visible(v_e.sucursal_id, v_e.de_las_dos) THEN
    RAISE EXCEPTION 'Ese empleado no existe o no lo podés ver';
  END IF;
  IF v_e.usuario_id = auth.uid() THEN
    RAISE EXCEPTION 'Tu propia cuenta la maneja otro admin: no podés cambiar tu arreglo, tu usuario ni tus movimientos';
  END IF;
  SELECT * INTO v_m FROM empleado_movimientos WHERE id = p_movimiento_id;
  IF v_m.tipo = 'pago' AND v_m.liquidacion_id IS NOT NULL THEN
    RAISE EXCEPTION 'Un pago de una liquidación se revierte anulando la liquidación';
  END IF;
  -- gastos 6: lo imputado al resolver una rendicion se deshace todo junto.
  IF v_m.tipo = 'faltante' THEN
    RAISE EXCEPTION 'Un faltante de rendición se deshace desde la rendición, con «Deshacer resolución»';
  END IF;
  -- gastos 7: la rotura de una salvedad se deshace con la salvedad. La de una
  -- merma si se revierte aca (la merma manual no se anula), tambien liquidada:
  -- la compensacion entra en la liquidacion siguiente.
  IF v_m.tipo = 'rotura' AND v_m.salvedad_id IS NOT NULL THEN
    RAISE EXCEPTION 'Una rotura de salvedad se deshace anulando la salvedad';
  END IF;
  IF v_m.tipo NOT IN ('adelanto', 'ajuste', 'pago', 'rotura') THEN
    RAISE EXCEPTION 'Sólo se revierte un movimiento cargado a mano';
  END IF;
  IF v_m.revierte_id IS NOT NULL THEN
    RAISE EXCEPTION 'Un movimiento que revierte a otro no se revierte: cargá uno nuevo';
  END IF;
  IF EXISTS (SELECT 1 FROM empleado_movimientos WHERE revierte_id = v_m.id) THEN
    RAISE EXCEPTION 'Ese movimiento ya está revertido';
  END IF;
  IF p_motivo IS NULL OR btrim(p_motivo) = '' THEN
    RAISE EXCEPTION 'Escribí por qué se revierte';
  END IF;
  IF v_m.rendicion_fecha IS NOT NULL THEN
    PERFORM public._rendicion_bloquear(ARRAY[public._rendicion_clave(v_m.rendicion_transportista_id, v_m.rendicion_fecha,
                                                                     v_m.rendicion_sucursal_id)]);
    IF public.control_rendicion_cerrado(v_m.rendicion_transportista_id, v_m.rendicion_sucursal_id, v_m.rendicion_fecha) THEN
      RAISE EXCEPTION 'Ese pago salió de una rendición ya cerrada: no se revierte, corregilo con un ajuste';
    END IF;
  END IF;
  -- gastos 7: la compensacion apunta a lo mismo que el original
  -- (CHECK rotura_origen).
  INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, observacion, revierte_id, creado_por,
                                    rendicion_transportista_id, rendicion_fecha, rendicion_sucursal_id,
                                    merma_id, salvedad_id)
  VALUES (v_m.empleado_id, public._tablero_hoy(), v_m.tipo, -v_m.monto, btrim(p_motivo), v_m.id, auth.uid(),
          v_m.rendicion_transportista_id, v_m.rendicion_fecha, v_m.rendicion_sucursal_id,
          v_m.merma_id, v_m.salvedad_id)
  RETURNING id INTO v_id;
  RETURN v_id;
END
$fn$;

-- -------------------------------------------------------------------------
-- 7 · _movimiento_origen_json: a que apunta una rotura
-- -------------------------------------------------------------------------
-- La cuenta y la liquidacion lo concatenan (||) a cada movimiento: las dos
-- claves quedan al primer nivel.
CREATE OR REPLACE FUNCTION public._movimiento_origen_json(p_m empleado_movimientos)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = public
AS $fn$
  SELECT jsonb_build_object(
    'liquidacion', (SELECT jsonb_build_object(
                             'id', li.id, 'desde', li.desde, 'hasta', li.hasta, 'frecuencia', li.frecuencia,
                             'pedidos', COALESCE((SELECT (c.detalle->>'pedidos')::integer
                                                    FROM empleado_liquidacion_conceptos c
                                                   WHERE c.liquidacion_id = li.id AND c.concepto = 'comision'), 0),
                             'anulada', li.anulada_at IS NOT NULL)
                      FROM empleado_liquidaciones li WHERE li.id = p_m.liquidacion_id),
    'rendicion', (SELECT jsonb_build_object('transportista_nombre', tr.nombre, 'fecha', p_m.rendicion_fecha)
                    FROM perfiles tr WHERE tr.id = p_m.rendicion_transportista_id),
    'merma_id', p_m.merma_id,
    'salvedad_id', p_m.salvedad_id);
$fn$;

-- -------------------------------------------------------------------------
-- 8 · Permisos
-- -------------------------------------------------------------------------
-- Las RPCs nuevas nacen con EXECUTE para PUBLIC y para anon (CLAUDE.md).
-- CREATE OR REPLACE conserva los grants de revertir_movimiento_empleado,
-- _movimiento_origen_json y anular_salvedad, y se reafirman igual.
REVOKE ALL ON FUNCTION public._cargar_roturas(jsonb, bigint, bigint, bigint, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._cargar_roturas(jsonb, bigint, bigint, bigint, text) TO service_role;
REVOKE ALL ON FUNCTION public._movimiento_origen_json(empleado_movimientos) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._movimiento_origen_json(empleado_movimientos) TO service_role;

REVOKE ALL ON FUNCTION public.registrar_merma_manual(bigint, integer, text, text, bigint, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.resolver_salvedad(bigint, character varying, text, bigint, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.anular_salvedad(bigint, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.revertir_movimiento_empleado(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_merma_manual(bigint, integer, text, text, bigint, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.resolver_salvedad(bigint, character varying, text, bigint, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.anular_salvedad(bigint, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.revertir_movimiento_empleado(bigint, text) TO authenticated, service_role;

-- -------------------------------------------------------------------------
-- 9 · Verificacion estructural
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  v_f text;
BEGIN
  IF (SELECT count(*) FROM pg_proc WHERE proname = 'registrar_merma_manual' AND pronamespace = 'public'::regnamespace) <> 1
     OR to_regprocedure('public.registrar_merma_manual(bigint,integer,text,text,bigint,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'gastos_7: tiene que quedar una sola registrar_merma_manual, la de seis argumentos';
  END IF;
  IF (SELECT count(*) FROM pg_proc WHERE proname = 'resolver_salvedad' AND pronamespace = 'public'::regnamespace) <> 1
     OR to_regprocedure('public.resolver_salvedad(bigint,character varying,text,bigint,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'gastos_7: tiene que quedar una sola resolver_salvedad, la de cinco argumentos';
  END IF;
  FOREACH v_f IN ARRAY ARRAY['public.registrar_merma_manual(bigint,integer,text,text,bigint,jsonb)',
                             'public.resolver_salvedad(bigint,character varying,text,bigint,jsonb)',
                             'public.anular_salvedad(bigint,text)',
                             'public.revertir_movimiento_empleado(bigint,text)',
                             'public._cargar_roturas(jsonb,bigint,bigint,bigint,text)',
                             'public._movimiento_origen_json(empleado_movimientos)'] LOOP
    IF has_function_privilege('anon', v_f, 'EXECUTE') THEN
      RAISE EXCEPTION 'gastos_7: anon ejecuta %', v_f;
    END IF;
  END LOOP;
  IF has_function_privilege('authenticated', 'public._cargar_roturas(jsonb,bigint,bigint,bigint,text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._movimiento_origen_json(empleado_movimientos)', 'EXECUTE') THEN
    RAISE EXCEPTION 'gastos_7: authenticated ejecuta un helper de server';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.registrar_merma_manual(bigint,integer,text,text,bigint,jsonb)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.resolver_salvedad(bigint,character varying,text,bigint,jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'gastos_7: authenticated perdio una RPC del front';
  END IF;
  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.anular_salvedad(bigint,text)'::regprocedure) !~ 'gastos 7: cada rotura viva'
     OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.anular_salvedad(bigint,text)'::regprocedure) THEN
    RAISE EXCEPTION 'gastos_7: anular_salvedad no quedo parchada o perdio el SECURITY DEFINER';
  END IF;
END
$verif$;
