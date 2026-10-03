-- =========================================================================
-- mig 277 · EL IMPUESTO INTERNO SALE DEL ENCUADRE, NO DE UN NUMERO TIPEADO
--
-- Hasta aca `productos.impuestos_internos` era una tasa EFECTIVA tipeada a
-- mano (8,6956 / 4,1667), y el modal de compra la copiaba de vuelta a la ficha
-- cada vez que alguien la editaba en un renglon. Asi entraron en la ficha
-- 9,18 y 4,24 (el factor de ajuste del Excel de la gerencia, horneado en nueve
-- productos de Taco Pozo el 17/09) y 4,17 (el input redondea a 2 decimales).
-- La proxima factura las autocompletaba.
--
-- La ley no le pone tasa a cada producto: lo encuadra (bebida sin jugo, con
-- >=10% de jugo, jugo puro, soda...) y le pone tasa al ENCUADRE, con vigencia.
-- Eso es lo que se modela:
--
--   ii_encuadres  · nombre y criterio legal. Globales: la ley es nacional, y
--                   un id comun entre sucursales hace que un traspaso no
--                   tenga que mapear nada.
--   ii_alicuotas  · tasa NOMINAL por encuadre con vigencia. La efectiva sale
--                   de n/(1-n): el impuesto se liquida "por dentro".
--   productos.ii_encuadre_id
--                 · NULL = SIN DEFINIR. "No alcanzado", "Exento" y "Fuera de
--                   objeto" son encuadres explicitos al 0%.
--
-- `productos.impuestos_internos` NO SE BORRA. Lo leen la venta
-- (crear_pedido*, el bot, los traspasos), `costo_valuacion` y una veintena de
-- funciones mas. Pasa a ser DERIVADO: un trigger lo escribe como la efectiva
-- vigente hoy, a 4 decimales, cada vez que cambia el encuadre o alguien
-- intenta escribirlo; y `refrescar_ii_productos()` lo recalcula en las dos
-- sucursales cuando cambia una alicuota. Asi nadie lo tipea, y el lado venta
-- no se entera del cambio.
--
-- Con encuadre NULL el trigger NO pisa el valor que llega: es el legado de las
-- fichas sin definir y de un PWA viejo que todavia lo manda. Derivar a 0 ahi
-- borraria en silencio la tasa de un producto que nadie encuadro todavia.
--
-- SIN VIGENCIAS FUTURAS (por ahora). En prod no hay pg_cron (decision del
-- #661), asi que no hay quien refresque el derivado el dia que entra en
-- vigencia una alicuota cargada por adelantado. Hasta que exista ese refresco,
-- el trigger de validacion rechaza `vigente_desde` posterior a hoy.
--
-- EFECTO EN LOS DATOS. El derivado de una ficha General pasa de 8,6956 a
-- 8,6957 (8/92 = 8,695652... redondeado a 4; el 8,6956 de antes estaba
-- truncado). La Reducida queda en 4,1667. Las nueve fichas contaminadas de
-- Taco Pozo vuelven a 8,6957 / 4,1667. Sus `costo_real` / `costo_promedio`
-- NO se recalculan (forward-only, como el CPP): los corrige la proxima compra.
--
-- TRASPASOS. `aceptar_movimiento_sucursal` crea el producto destino copiando
-- el snapshot `origen_*` del renglon. Sin un `origen_ii_encuadre_id`, el
-- producto nacia sin encuadre. Se agrega la columna, se la escribe en
-- crear/editar y se la usa al aceptar: PARCHE POR ANCLA sobre el cuerpo vivo
-- (igual que la 236), no CREATE OR REPLACE desde el repo.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 0 · Helper de cirugia sobre el cuerpo vivo (mismo contrato que _mig236_ancla)
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._mig277_ancla(
  p_funcion regprocedure,
  p_ancla   text,
  p_nuevo   text
) RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text;
  v_veces int;
BEGIN
  v_def := pg_get_functiondef(p_funcion);
  v_veces := (length(v_def) - length(replace(v_def, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El ancla aparece % veces en % (se esperaba exactamente 1). El cuerpo vivo cambio: revisar a mano. Ancla: %',
      v_veces, p_funcion, left(p_ancla, 120);
  END IF;
  EXECUTE replace(v_def, p_ancla, p_nuevo);
END;
$fn$;

-- -------------------------------------------------------------------------
-- 1 · Catalogos
-- -------------------------------------------------------------------------
CREATE TABLE public.ii_encuadres (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre      text NOT NULL,
  criterio    text,
  activo      boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ii_encuadres_nombre_uk UNIQUE (nombre),
  CONSTRAINT ii_encuadres_nombre_no_vacio CHECK (btrim(nombre) <> '')
);

COMMENT ON TABLE public.ii_encuadres IS
  'Encuadre de impuestos internos (Ley 24.674). La tasa vive en ii_alicuotas, con vigencia. Global: la ley es nacional.';

CREATE TABLE public.ii_alicuotas (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  encuadre_id    bigint NOT NULL REFERENCES public.ii_encuadres(id) ON DELETE RESTRICT,
  -- NOMINAL y como fraccion: 0.08 es el 8%. La efectiva se deriva (n/(1-n)).
  tasa_nominal   numeric(9,6) NOT NULL,
  vigente_desde  date NOT NULL,
  vigente_hasta  date,
  created_at     timestamptz NOT NULL DEFAULT now(),
  creado_por     uuid DEFAULT auth.uid(),
  CONSTRAINT ii_alicuotas_tasa_rango CHECK (tasa_nominal >= 0 AND tasa_nominal < 1),
  CONSTRAINT ii_alicuotas_vigencia CHECK (vigente_hasta IS NULL OR vigente_hasta >= vigente_desde)
);

CREATE INDEX ii_alicuotas_encuadre_idx ON public.ii_alicuotas (encuadre_id, vigente_desde);

COMMENT ON COLUMN public.ii_alicuotas.tasa_nominal IS
  'Tasa NOMINAL como fraccion (0.08 = 8%). El impuesto se liquida por dentro: la efectiva sobre el neto es n/(1-n).';

-- Sin solapamiento por encuadre, y sin vigencias futuras (ver encabezado).
CREATE OR REPLACE FUNCTION public.validar_ii_alicuota()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $fn$
DECLARE
  v_hoy date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
BEGIN
  IF NEW.vigente_desde > v_hoy THEN
    RAISE EXCEPTION 'Todavia no se pueden cargar alicuotas con vigencia futura (desde %): no hay quien refresque la tasa el dia que empieza.',
      NEW.vigente_desde
      USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.ii_alicuotas a
     WHERE a.encuadre_id = NEW.encuadre_id
       AND a.id IS DISTINCT FROM NEW.id
       AND daterange(a.vigente_desde, a.vigente_hasta, '[]')
           && daterange(NEW.vigente_desde, NEW.vigente_hasta, '[]')
  ) THEN
    RAISE EXCEPTION 'La vigencia se superpone con otra alicuota del mismo encuadre. Cerra la anterior (vigente hasta) antes de cargar la nueva.'
      USING ERRCODE = '23P01';
  END IF;
  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_validar_ii_alicuota
  BEFORE INSERT OR UPDATE ON public.ii_alicuotas
  FOR EACH ROW EXECUTE FUNCTION public.validar_ii_alicuota();

-- La efectiva en PORCENTAJE (8,695652... para el 8%), sin redondear. NULL si
-- el encuadre no tiene alicuota vigente a esa fecha.
CREATE OR REPLACE FUNCTION public.ii_tasa_efectiva(p_encuadre_id bigint, p_fecha date)
RETURNS numeric
LANGUAGE sql
STABLE
SET search_path = public
AS $fn$
  SELECT 100 * a.tasa_nominal / (1 - a.tasa_nominal)
    FROM public.ii_alicuotas a
   WHERE a.encuadre_id = p_encuadre_id
     AND a.vigente_desde <= p_fecha
     AND (a.vigente_hasta IS NULL OR a.vigente_hasta >= p_fecha)
   ORDER BY a.vigente_desde DESC
   LIMIT 1
$fn$;

-- -------------------------------------------------------------------------
-- 2 · RLS y permisos: todos leen, solo admin escribe. Las dos mitades de anon.
-- -------------------------------------------------------------------------
ALTER TABLE public.ii_encuadres ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ii_alicuotas ENABLE ROW LEVEL SECURITY;

CREATE POLICY ii_encuadres_select ON public.ii_encuadres
  FOR SELECT TO authenticated USING (true);
CREATE POLICY ii_encuadres_insert ON public.ii_encuadres
  FOR INSERT TO authenticated WITH CHECK (public.es_admin());
CREATE POLICY ii_encuadres_update ON public.ii_encuadres
  FOR UPDATE TO authenticated USING (public.es_admin()) WITH CHECK (public.es_admin());
CREATE POLICY ii_encuadres_delete ON public.ii_encuadres
  FOR DELETE TO authenticated USING (public.es_admin());

CREATE POLICY ii_alicuotas_select ON public.ii_alicuotas
  FOR SELECT TO authenticated USING (true);
CREATE POLICY ii_alicuotas_insert ON public.ii_alicuotas
  FOR INSERT TO authenticated WITH CHECK (public.es_admin());
CREATE POLICY ii_alicuotas_update ON public.ii_alicuotas
  FOR UPDATE TO authenticated USING (public.es_admin()) WITH CHECK (public.es_admin());
CREATE POLICY ii_alicuotas_delete ON public.ii_alicuotas
  FOR DELETE TO authenticated USING (public.es_admin());

REVOKE ALL ON public.ii_encuadres FROM anon;
REVOKE ALL ON public.ii_alicuotas FROM anon;

-- Lectura inofensiva: el front y el trigger de productos la usan como invoker.
REVOKE EXECUTE ON FUNCTION public.ii_tasa_efectiva(bigint, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ii_tasa_efectiva(bigint, date) TO authenticated, service_role;
-- Funcion de trigger: la invoca el executor, no el caller.
REVOKE EXECUTE ON FUNCTION public.validar_ii_alicuota() FROM PUBLIC, anon, authenticated;

-- -------------------------------------------------------------------------
-- 3 · Seed. vigente_desde 2000-01-01 = "desde siempre para este sistema": las
--     compras arrancan en 2026. Si alguna vez hay que recargar algo anterior a
--     un cambio de ley, se cierra esta fila y se carga la vigencia real.
-- -------------------------------------------------------------------------
INSERT INTO public.ii_encuadres (nombre, criterio) VALUES
  ('General',          'Bebidas analcoholicas que no entran en la reducida (gaseosas sin jugo suficiente). Ley 24.674, art. 26.'),
  ('Reducida',         'Al menos 10% de jugo de fruta (5% si es limon), o agua mineral, mineralizada o saborizada.'),
  ('Exento',           'Jugos puros de fruta, bebidas a base de leche, infusiones sin gasificar.'),
  ('Fuera de objeto',  'Soda: agua carbonatada sin saborizar.'),
  ('No alcanzado',     'Productos que no tributan impuestos internos.');

INSERT INTO public.ii_alicuotas (encuadre_id, tasa_nominal, vigente_desde)
SELECT e.id, v.tasa, DATE '2000-01-01'
  FROM (VALUES ('General', 0.08), ('Reducida', 0.04), ('Exento', 0),
               ('Fuera de objeto', 0), ('No alcanzado', 0)) AS v(nombre, tasa)
  JOIN public.ii_encuadres e ON e.nombre = v.nombre;

-- -------------------------------------------------------------------------
-- 4 · productos.ii_encuadre_id + el derivado
-- -------------------------------------------------------------------------
ALTER TABLE public.productos
  ADD COLUMN ii_encuadre_id bigint REFERENCES public.ii_encuadres(id) ON DELETE RESTRICT;

CREATE INDEX productos_ii_encuadre_idx ON public.productos (ii_encuadre_id);

COMMENT ON COLUMN public.productos.ii_encuadre_id IS
  'Encuadre de impuestos internos (mig 277). NULL = sin definir. Define impuestos_internos.';
COMMENT ON COLUMN public.productos.impuestos_internos IS
  'DERIVADO (mig 277): efectiva vigente hoy del encuadre, en %, a 4 decimales. No se tipea. Con encuadre NULL conserva el valor heredado.';

-- El nombre ordena DESPUES de productos_proteger_columnas (los BEFORE corren
-- en orden alfabetico): asi el rol deposito, que solo mueve stock, nunca ve
-- una diferencia que no hizo. Ademas solo dispara si cambia el encuadre o la
-- tasa, nunca en un UPDATE de stock.
CREATE OR REPLACE FUNCTION public.derivar_ii_producto()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $fn$
BEGIN
  IF NEW.ii_encuadre_id IS NOT NULL THEN
    NEW.impuestos_internos := COALESCE(round(public.ii_tasa_efectiva(
      NEW.ii_encuadre_id,
      (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
    ), 4), 0);
  END IF;
  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_ii_derivado
  BEFORE INSERT OR UPDATE OF ii_encuadre_id, impuestos_internos ON public.productos
  FOR EACH ROW EXECUTE FUNCTION public.derivar_ii_producto();

REVOKE EXECUTE ON FUNCTION public.derivar_ii_producto() FROM PUBLIC, anon, authenticated;

-- Recalcula el derivado en TODAS las sucursales. SECURITY DEFINER porque las
-- policies de productos filtran por la sucursal activa: un admin que cambia
-- una alicuota desde Tucuman no veria las fichas de Taco Pozo. El WHERE deja
-- afuera las filas que no cambian: sin el, cada corrida dejaria una fila por
-- producto en audit_logs.
CREATE OR REPLACE FUNCTION public.refrescar_ii_productos()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_hoy date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_n   integer;
BEGIN
  UPDATE public.productos p
     SET impuestos_internos = d.tasa
    FROM (
      SELECT id, COALESCE(round(public.ii_tasa_efectiva(ii_encuadre_id, v_hoy), 4), 0) AS tasa
        FROM public.productos
       WHERE ii_encuadre_id IS NOT NULL
    ) d
   WHERE p.id = d.id
     AND p.impuestos_internos IS DISTINCT FROM d.tasa;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION public.refrescar_ii_productos() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.refrescar_ii_productos() TO service_role;

CREATE OR REPLACE FUNCTION public.trg_refrescar_ii_productos()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  PERFORM public.refrescar_ii_productos();
  RETURN NULL;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION public.trg_refrescar_ii_productos() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_ii_alicuotas_refrescan
  AFTER INSERT OR UPDATE OR DELETE ON public.ii_alicuotas
  FOR EACH STATEMENT EXECUTE FUNCTION public.trg_refrescar_ii_productos();

-- Cambiar la tasa de un encuadre en UNA transaccion. Desde la pantalla serian
-- dos pedidos (cerrar la vigente, abrir la nueva) y entre uno y otro el
-- encuadre se queda sin tasa: el refresco dejaria el derivado en 0 y una venta
-- en ese hueco saldria sin II. Si ya hay una alicuota que arranca ese mismo
-- dia, es una correccion: se le pisa la tasa.
CREATE OR REPLACE FUNCTION public.cambiar_alicuota_ii(
  p_encuadre_id   bigint,
  p_tasa_nominal  numeric,
  p_vigente_desde date
) RETURNS bigint
LANGUAGE plpgsql
SET search_path = public
AS $fn$
DECLARE
  v_id bigint;
BEGIN
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Solo un administrador puede cambiar alicuotas de impuestos internos' USING ERRCODE = '42501';
  END IF;

  SELECT id INTO v_id FROM public.ii_alicuotas
   WHERE encuadre_id = p_encuadre_id AND vigente_desde = p_vigente_desde
   FOR UPDATE;
  IF FOUND THEN
    UPDATE public.ii_alicuotas SET tasa_nominal = p_tasa_nominal WHERE id = v_id;
    RETURN v_id;
  END IF;

  UPDATE public.ii_alicuotas
     SET vigente_hasta = p_vigente_desde - 1
   WHERE encuadre_id = p_encuadre_id
     AND vigente_desde < p_vigente_desde
     AND (vigente_hasta IS NULL OR vigente_hasta >= p_vigente_desde);

  INSERT INTO public.ii_alicuotas (encuadre_id, tasa_nominal, vigente_desde)
  VALUES (p_encuadre_id, p_tasa_nominal, p_vigente_desde)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION public.cambiar_alicuota_ii(bigint, numeric, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cambiar_alicuota_ii(bigint, numeric, date) TO authenticated;

-- -------------------------------------------------------------------------
-- 5 · Mapeo de las fichas existentes
-- -------------------------------------------------------------------------
-- Por valor: las tasas que existen hoy. 9,18 y 4,24 son el factor del Excel
-- tipeado en Taco Pozo; 4,17 es el 4,1667 redondeado por el input.
UPDATE public.productos
   SET ii_encuadre_id = (SELECT id FROM public.ii_encuadres WHERE nombre = 'General')
 WHERE impuestos_internos IN (8.6956, 9.18);

UPDATE public.productos
   SET ii_encuadre_id = (SELECT id FROM public.ii_encuadres WHERE nombre = 'Reducida')
 WHERE impuestos_internos IN (4.1667, 4.17, 4.24);

-- Por id, revisado a mano contra el nombre (el guard aborta si un id no es lo
-- que se espera: los ids no se reciclan, pero un nombre cambiado si).
DO $mapeo$
DECLARE
  v_casos CONSTANT jsonb := jsonb_build_array(
    -- Jugos puros: exentos
    jsonb_build_object('id', 208, 'patron', 'PINDAPOY', 'encuadre', 'Exento'),
    jsonb_build_object('id', 217, 'patron', 'PINDAPOY', 'encuadre', 'Exento'),
    jsonb_build_object('id', 209, 'patron', 'PINDAPOY', 'encuadre', 'Exento'),
    jsonb_build_object('id', 218, 'patron', 'PINDAPOY', 'encuadre', 'Exento'),
    jsonb_build_object('id', 160, 'patron', 'PINDAPOY', 'encuadre', 'Exento'),
    jsonb_build_object('id', 159, 'patron', 'PINDAPOY', 'encuadre', 'Exento'),
    jsonb_build_object('id', 478, 'patron', 'PINDAPOY', 'encuadre', 'Exento'),
    jsonb_build_object('id', 479, 'patron', 'PINDAPOY', 'encuadre', 'Exento'),
    -- Soda: fuera de objeto
    jsonb_build_object('id', 89,  'patron', 'SODA',     'encuadre', 'Fuera de objeto'),
    jsonb_build_object('id', 158, 'patron', 'SODA',     'encuadre', 'Fuera de objeto'),
    jsonb_build_object('id', 191, 'patron', 'SODA',     'encuadre', 'Fuera de objeto'),
    -- Manaos sin alicuota: dados de alta desde la factura (28/08) sin tasa
    jsonb_build_object('id', 362, 'patron', 'CITRUS',   'encuadre', 'Reducida'),
    jsonb_build_object('id', 361, 'patron', 'LATA',     'encuadre', 'General'),
    -- Lo que hoy tiene 0 y no es bebida alcanzada
    jsonb_build_object('id', 251, 'patron', 'TUTUCA',   'encuadre', 'No alcanzado'),
    jsonb_build_object('id', 342, 'patron', 'ALFATUC',  'encuadre', 'No alcanzado'),
    jsonb_build_object('id', 343, 'patron', 'ALFATUC',  'encuadre', 'No alcanzado'),
    jsonb_build_object('id', 262, 'patron', 'FIDEO',    'encuadre', 'No alcanzado'),
    jsonb_build_object('id', 261, 'patron', 'FIDEO',    'encuadre', 'No alcanzado'),
    jsonb_build_object('id', 245, 'patron', 'NESS',     'encuadre', 'No alcanzado'),
    jsonb_build_object('id', 266, 'patron', 'VINO',     'encuadre', 'No alcanzado'),
    jsonb_build_object('id', 227, 'patron', 'VINO',     'encuadre', 'No alcanzado')
  );
  v_caso   jsonb;
  v_nombre text;
BEGIN
  FOR v_caso IN SELECT * FROM jsonb_array_elements(v_casos) LOOP
    SELECT nombre INTO v_nombre FROM public.productos WHERE id = (v_caso->>'id')::bigint;
    IF v_nombre IS NULL OR v_nombre NOT ILIKE '%' || (v_caso->>'patron') || '%' THEN
      RAISE EXCEPTION 'Mapeo de encuadre: el producto % no es el esperado (%). Nombre: %',
        v_caso->>'id', v_caso->>'patron', v_nombre;
    END IF;
    UPDATE public.productos
       SET ii_encuadre_id = (SELECT id FROM public.ii_encuadres WHERE nombre = v_caso->>'encuadre')
     WHERE id = (v_caso->>'id')::bigint;
  END LOOP;
END
$mapeo$;

-- -------------------------------------------------------------------------
-- 6 · Traspasos entre sucursales llevan el encuadre
-- -------------------------------------------------------------------------
ALTER TABLE public.movimiento_sucursal_items
  ADD COLUMN origen_ii_encuadre_id bigint REFERENCES public.ii_encuadres(id) ON DELETE RESTRICT;

SELECT public._mig277_ancla(
  'public.crear_movimiento_sucursal(bigint, text, jsonb)'::regprocedure,
  'origen_impuestos_internos, origen_porcentaje_iva,',
  'origen_impuestos_internos, origen_ii_encuadre_id, origen_porcentaje_iva,');
SELECT public._mig277_ancla(
  'public.crear_movimiento_sucursal(bigint, text, jsonb)'::regprocedure,
  'v_prod.impuestos_internos, v_prod.porcentaje_iva,',
  'v_prod.impuestos_internos, v_prod.ii_encuadre_id, v_prod.porcentaje_iva,');

SELECT public._mig277_ancla(
  'public.editar_movimiento_sucursal(bigint, text, jsonb)'::regprocedure,
  'origen_impuestos_internos, origen_porcentaje_iva,',
  'origen_impuestos_internos, origen_ii_encuadre_id, origen_porcentaje_iva,');
SELECT public._mig277_ancla(
  'public.editar_movimiento_sucursal(bigint, text, jsonb)'::regprocedure,
  'v_prod.impuestos_internos, v_prod.porcentaje_iva,',
  'v_prod.impuestos_internos, v_prod.ii_encuadre_id, v_prod.porcentaje_iva,');

SELECT public._mig277_ancla(
  'public.aceptar_movimiento_sucursal(bigint, jsonb)'::regprocedure,
  'impuestos_internos, porcentaje_iva, condicion_iva, stock,',
  'impuestos_internos, ii_encuadre_id, porcentaje_iva, condicion_iva, stock,');
SELECT public._mig277_ancla(
  'public.aceptar_movimiento_sucursal(bigint, jsonb)'::regprocedure,
  'v_item.origen_impuestos_internos, v_item.origen_porcentaje_iva,',
  'v_item.origen_impuestos_internos, v_item.origen_ii_encuadre_id, v_item.origen_porcentaje_iva,');

-- Los traspasos pendientes de hoy se crearon sin el snapshot: se completa
-- desde la ficha de origen, que ya quedo mapeada arriba.
UPDATE public.movimiento_sucursal_items i
   SET origen_ii_encuadre_id = p.ii_encuadre_id
  FROM public.productos p, public.movimientos_sucursal m
 WHERE p.id = i.producto_origen_id
   AND m.id = i.movimiento_id
   AND m.estado = 'pendiente'
   AND i.origen_ii_encuadre_id IS NULL;

DROP FUNCTION public._mig277_ancla(regprocedure, text, text);

-- -------------------------------------------------------------------------
-- 7 · Verificacion. Si algo de esto falla, no se aplica nada.
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  v_n integer;
BEGIN
  -- Ninguna ficha con tasa positiva quedo sin encuadre.
  SELECT count(*) INTO v_n FROM public.productos
   WHERE COALESCE(impuestos_internos, 0) > 0 AND ii_encuadre_id IS NULL;
  IF v_n > 0 THEN
    RAISE EXCEPTION 'Quedaron % productos con impuesto interno y sin encuadre', v_n;
  END IF;

  -- El derivado coincide con el encuadre en todas las fichas encuadradas.
  SELECT count(*) INTO v_n FROM public.productos
   WHERE ii_encuadre_id IS NOT NULL
     AND impuestos_internos IS DISTINCT FROM COALESCE(round(public.ii_tasa_efectiva(
           ii_encuadre_id, (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date), 4), 0);
  IF v_n > 0 THEN
    RAISE EXCEPTION '% productos con el derivado distinto del encuadre', v_n;
  END IF;

  -- Ya no queda ninguna de las tasas contaminadas.
  SELECT count(*) INTO v_n FROM public.productos
   WHERE impuestos_internos IN (9.18, 4.24, 4.17, 8.6956);
  IF v_n > 0 THEN
    RAISE EXCEPTION 'Quedaron % fichas con tasas viejas (9,18 / 4,24 / 4,17 / 8,6956)', v_n;
  END IF;

  -- Las tres funciones de traspaso mencionan el encuadre.
  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
   WHERE s.nspname = 'public'
     AND p.proname IN ('crear_movimiento_sucursal', 'editar_movimiento_sucursal', 'aceptar_movimiento_sucursal')
     AND pg_get_functiondef(p.oid) LIKE '%ii_encuadre_id%';
  IF v_n <> 3 THEN
    RAISE EXCEPTION 'Solo % de las 3 funciones de traspaso quedaron con el encuadre', v_n;
  END IF;

  -- Ni anon ni PUBLIC alcanzan las funciones nuevas.
  IF has_function_privilege('anon', 'public.ii_tasa_efectiva(bigint, date)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.refrescar_ii_productos()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.refrescar_ii_productos()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.cambiar_alicuota_ii(bigint, numeric, date)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Permisos de las funciones nuevas mal revocados';
  END IF;
END
$verif$;

COMMIT;
