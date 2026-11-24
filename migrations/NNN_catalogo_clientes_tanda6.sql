-- =========================================================================
-- NNN · PERMISOS, CATÁLOGO Y CLIENTES: LO QUE ENCONTRÓ LA REAUDITORÍA DEL 24/11
--       (plan #1603, tanda 6, tarjeta C: SEG-1, catalogo-B1, B2, B3, B5, B9, B10 y B11, y permisos-B3
--        y B5, decisiones del dueño del 24/11)
--
-- Ensayo: scripts/test-catalogo-clientes-tanda6-1603.sql. La carrera de dos altas a la vez (B9):
-- scripts/concurrencia/t6c-alta-cliente-duplicada.sh. Se aplica en LF, en una sola transacción.
-- Premisas: md5(prosrc) de los cuerpos vivos de la 540.
--
--   1 · SEG-1 · `cdc_select` (cliente_descuentos_categoria) suma la regla de quién ve a un cliente:
--       un EXISTS sobre `clientes`, que pasa por su RLS (mt_clientes_select → _cliente_visible, la
--       «una sola regla» de 1564-b12). El preventista ya no lee los descuentos de un cliente de otro
--       preventista ni de uno reservado a administración; los de sus clientes, los libres y los de
--       quien le vendió, sí. El admin y el encargado siguen leyendo todos; el chofer y el depósito,
--       ninguno (como hoy: la policy sigue pidiendo es_encargado_o_admin() OR es_preventista()).
--   2 · catalogo-B1 · el dígito verificador del CUIT, en el server (D37 de #1561: «uno inválido se
--       rechaza»). `clientes_tipo_documento_del_valor` (el trigger del tipo, B17) rechaza un CUIT
--       nuevo o cambiado que no tenga 11 dígitos o con el verificador mal (módulo 11, como validarCuit
--       del front y _clientes_documento_grupos). Rige al cambiar el documento: un cliente que ya lo
--       tiene mal se sigue editando mientras sus dígitos no cambien (como errorDeCuit, que no frena el
--       CUIT con el que se abrió la ficha). Por eso es un trigger y no un CHECK.
--   3 · catalogo-B2 · `clientes.latitud` de -90 a 90 y `longitud` de -180 a 180 (dos CHECK, como los de
--       pedidos y visitas_cliente; también dejan afuera el NaN).
--   4 · catalogo-B3 · `actualizar_precios_masivo` redondea el neto y el final al centavo ANTES de mirar
--       que sean > 0: 0,004 entraba y dejaba el producto en $ 0,00 (la columna es numeric(10,2)).
--   5 · catalogo-B5 · `productos`: el precio neto no pasa al final (CHECK
--       productos_precios_venta_neto_hasta_final; el masivo ya lo validaba, el REST no) y el nombre tiene
--       hasta 200 caracteres (productos_nombre_largo). `stock_minimo` NULL NO se toca: vacío es 10
--       (CAT-13, CLAUDE.md).
--   6 · catalogo-B9 · `guardar_cliente` toma un lock de transacción por sucursal
--       (pg_advisory_xact_lock) antes de buscar el duplicado, en el alta y en la edición que cambia la
--       dirección o el punto: dos altas a la vez en la misma dirección (o en el mismo punto) pasaban
--       las dos, porque la búsqueda no ve lo que la otra no confirmó. Ahora la segunda espera a la
--       primera y la ve. Orden: la clave del alta (o la fila del cliente en la edición), después este
--       lock, después el INSERT/UPDATE; nadie toma este lock y después otra fila de clientes.
--   7 · catalogo-B10 · el nombre de una marca es único por sucursal sin mirar mayúsculas ni los
--       espacios de los bordes (índice marcas_sucursal_nombre_norm_uk, como los rubros). El front ya
--       traduce el 23505 («Ya existe una marca llamada…»). Zonas no (es de la distribuidora: queda
--       afuera, bajos-clasificados) y grupos_precio tampoco: `crear_condicion_para_producto` crea la
--       condición con el nombre del producto, y uno que ya está en una condición compartida con ese
--       nombre chocaría (pregunta para el dueño en el informe de la tarjeta).
--   8 · catalogo-B11 · el aviso de producto sin precio del ALTA pasa a ser uno por operación
--       (trigger FOR EACH STATEMENT con la tabla de transición): 100 productos sin precio en un INSERT
--       dejan un aviso por destinatario que dice cuántos son (antes, 100 por destinatario). El alta de
--       uno solo avisa como siempre, con su producto. El precio que pasa a 0 (UPDATE) no cambia.
--   9 · permisos-B3 (decisión del dueño del 24/11) · `promo_ajustes` y `control_stock_sesiones` las
--       leen sólo el admin, el encargado y el depósito de la sucursal activa (no tienen tablas hijas).
--       El preventista y el chofer dejan de leerlas: ninguna pantalla suya las pide (el historial de
--       control de stock es de admin y encargado, puedeControlarStock; el conteo de ajustes de una
--       promo, de quien la elimina, el admin). El depósito, que no tiene helper de rol, con
--       COALESCE(activo, true) (CLAUDE.md, #1474). Las funciones que las leen por dentro son DEFINER
--       o las llaman sólo DEFINER (_barra_mover_neto, _contenedores_de_promos).
--  10 · permisos-B5 (decisión del dueño del 24/11) · un admin de dos sucursales anula un gasto sólo
--       parado en la sucursal del gasto (`_anular_gasto`): «toda rama admin mira la sucursal». El
--       compartido no cambia: es de todas (gastos_select lo muestra en cualquiera) y lo anula quien lo
--       cargó o un admin de todas. Los cierres de rendición que lo llaman (confirmar_rendicion,
--       deshacer_resolucion_rendicion) ya trabajan sobre la sucursal activa. Cancelar un envío de otra
--       sucursal ya se rechazaba (cancelar_movimiento_sucursal compara con la sucursal activa desde
--       #1488): no se toca, el ensayo lo deja como regresión.
--
-- PREMISAS DE DATOS (abortan con el motivo): ningún cliente con coordenadas fuera de rango, ningún
-- producto con el neto mayor que el final ni con un nombre de más de 200 caracteres, ningún par de
-- marcas de una sucursal con el mismo nombre normalizado. Las consultas de conteo para producción
-- están en el informe de la tarjeta.
--
-- LOCKS: ACCESS EXCLUSIVE NOWAIT, al principio y de una vez, sobre clientes, cliente_descuentos_categoria,
-- productos, marcas, promo_ajustes y control_stock_sesiones (ALTER POLICY, ADD CONSTRAINT, CREATE INDEX,
-- DROP/CREATE TRIGGER). Los CHECK
-- recorren clientes y productos una vez para validarse.
--
-- No cambia firmas. Un bundle viejo del PWA sigue andando: ninguno manda un CUIT con el verificador
-- mal (el modal lo frena desde #1561), coordenadas fuera de rango (salen de Google Maps), un neto mayor
-- que el final (el modal lo calcula del final) ni 0,004 en el masivo (redondearPrecio da 0 y el server
-- ya rechazaba 0).
-- =========================================================================

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

SET LOCAL lock_timeout = '5s';

LOCK TABLE public.clientes, public.cliente_descuentos_categoria, public.productos, public.marcas,
           public.promo_ajustes, public.control_stock_sesiones
  IN ACCESS EXCLUSIVE MODE NOWAIT;

-- -------------------------------------------------------------------------
-- Premisas de esquema: los cuerpos, la policy y el trigger, como en la 540
-- -------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.actualizar_precios_masivo(jsonb,jsonb)', 'd055473f216e1f7b9efc370e3551e3f3'),
    ('public.guardar_cliente(jsonb)', 'd106be0a778ce9ffdb563d7030343871'),
    ('public.clientes_tipo_documento_del_valor()', '79e75478f367a4abb24f4b7bbdf6e055'),
    ('public.notificar_producto_sin_precio()', 'ad3e70a98f5590e4056a9dd7f34e15ba'),
    ('public._anular_gasto(bigint,text,boolean)', '2be7627924c78a13671cb1ad025147f6')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;

  IF to_regprocedure('public.notificar_productos_sin_precio_alta()') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · notificar_productos_sin_precio_alta() ya existe: rehacer sobre lo vigente';
  END IF;

  SELECT md5(qual) INTO v FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'cliente_descuentos_categoria' AND policyname = 'cdc_select'
     AND cmd = 'SELECT' AND roles = '{authenticated}';
  IF v IS DISTINCT FROM '04fba009c0016daa131fac19936c792c' THEN
    RAISE EXCEPTION 'mig NNN · la policy cdc_select no es la de la 540 (md5 %): rehacer sobre lo vigente', v;
  END IF;

  IF (SELECT count(*) FROM pg_policies
       WHERE schemaname = 'public' AND cmd = 'SELECT' AND roles = '{authenticated}'
         AND ((tablename = 'promo_ajustes' AND policyname = 'mt_promo_ajustes_select')
           OR (tablename = 'control_stock_sesiones' AND policyname = 'mt_control_stock_sesiones_select'))
         AND qual = '(sucursal_id = current_sucursal_id())') <> 2 THEN
    RAISE EXCEPTION 'mig NNN · las policies de lectura de promo_ajustes y control_stock_sesiones no son las de la 540';
  END IF;

  SELECT pg_get_triggerdef(oid) INTO v FROM pg_trigger
   WHERE tgrelid = 'public.productos'::regclass AND tgname = 'trg_notificar_producto_sin_precio_ins';
  IF v IS DISTINCT FROM 'CREATE TRIGGER trg_notificar_producto_sin_precio_ins AFTER INSERT ON public.productos FOR EACH ROW WHEN (((new.precio IS NULL) OR (new.precio <= (0)::numeric))) EXECUTE FUNCTION notificar_producto_sin_precio()' THEN
    RAISE EXCEPTION 'mig NNN · el trigger del aviso de alta sin precio no es el de la 540: %', v;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_constraint
              WHERE conrelid IN ('public.clientes'::regclass, 'public.productos'::regclass)
                AND conname IN ('clientes_latitud_rango', 'clientes_longitud_rango',
                                'productos_precios_venta_neto_hasta_final', 'productos_nombre_largo'))
     OR to_regclass('public.marcas_sucursal_nombre_norm_uk') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · un CHECK o el índice nuevo ya existe: rehacer sobre lo vigente';
  END IF;
END
$premisas$;

-- -------------------------------------------------------------------------
-- Premisas de datos: lo que los CHECK y el índice nuevos no dejarían
-- -------------------------------------------------------------------------
DO $datos$
DECLARE
  v_geo    int;
  v_neto   int;
  v_nombre int;
  v_marcas text;
BEGIN
  SELECT count(*) INTO v_geo FROM public.clientes
   WHERE NOT (latitud >= -90 AND latitud <= 90) OR NOT (longitud >= -180 AND longitud <= 180);
  SELECT count(*) FILTER (WHERE precio_sin_iva > precio), count(*) FILTER (WHERE char_length(nombre) > 200)
    INTO v_neto, v_nombre FROM public.productos;
  SELECT string_agg(format('sucursal %s «%s» ×%s', sucursal_id, n, c), ', ')
    INTO v_marcas
    FROM (SELECT sucursal_id, upper(btrim(nombre)) AS n, count(*) AS c FROM public.marcas
           GROUP BY 1, 2 HAVING count(*) > 1) d;
  IF v_geo > 0 OR v_neto > 0 OR v_nombre > 0 OR v_marcas IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · datos que no cumplen: % clientes con coordenadas fuera de rango, % productos con el neto mayor que el final, % productos con el nombre de más de 200 caracteres, marcas repetidas: %. Corregirlos antes (consultas de conteo en el informe de la tarjeta)',
      v_geo, v_neto, v_nombre, COALESCE(v_marcas, 'ninguna');
  END IF;
END
$datos$;

-- =========================================================================
-- 1 · SEG-1 · los descuentos por rubro se leen con la regla de quién ve a un cliente
-- =========================================================================
-- El EXISTS lee `clientes` con la RLS de quien consulta (mt_clientes_select → _cliente_visible):
-- la regla es una sola, la de la tabla de clientes. cliente_de_sucursal_activa y el rol quedan como
-- estaban (el gate de la rama admin mira que la rama nombre la sucursal).
ALTER POLICY cdc_select ON public.cliente_descuentos_categoria
  USING (
    public.cliente_de_sucursal_activa(cliente_id)
    AND (public.es_encargado_o_admin() OR public.es_preventista())
    AND EXISTS (SELECT 1 FROM public.clientes c WHERE c.id = cliente_descuentos_categoria.cliente_id)
  );

COMMENT ON POLICY cdc_select ON public.cliente_descuentos_categoria IS
  'SEG-1 (tanda 6 de #1603): el descuento de un cliente lo lee quien ve al cliente. El EXISTS pasa por la RLS de clientes (mt_clientes_select → _cliente_visible, 1564-b12): no repetir la regla acá.';

-- =========================================================================
-- 9 · permisos-B3 · los ajustes de promos y los conteos de stock, para admin, encargado y depósito
-- =========================================================================
ALTER POLICY mt_promo_ajustes_select ON public.promo_ajustes
  USING (
    sucursal_id = public.current_sucursal_id()
    AND (public.es_encargado_o_admin()
         OR EXISTS (SELECT 1 FROM public.perfiles pd
                     WHERE pd.id = (SELECT auth.uid()) AND pd.rol = 'deposito' AND COALESCE(pd.activo, true)))
  );
ALTER POLICY mt_control_stock_sesiones_select ON public.control_stock_sesiones
  USING (
    sucursal_id = public.current_sucursal_id()
    AND (public.es_encargado_o_admin()
         OR EXISTS (SELECT 1 FROM public.perfiles pd
                     WHERE pd.id = (SELECT auth.uid()) AND pd.rol = 'deposito' AND COALESCE(pd.activo, true)))
  );

-- =========================================================================
-- 3 · catalogo-B2 · las coordenadas de un cliente, en rango
-- =========================================================================
ALTER TABLE public.clientes
  ADD CONSTRAINT clientes_latitud_rango CHECK (latitud >= -90 AND latitud <= 90),
  ADD CONSTRAINT clientes_longitud_rango CHECK (longitud >= -180 AND longitud <= 180);

-- =========================================================================
-- 5 · catalogo-B5 · el neto no pasa al final, y el nombre tiene un largo razonable
-- =========================================================================
-- Igual sí (exento o no gravado). Con cualquiera de los dos vacío, pasa. El nombre ordena después de
-- productos_precios_no_nan y productos_precios_no_negativos (Postgres mira los CHECK por nombre): un NaN o
-- un negativo se sigue rechazando con su motivo, no con éste.
ALTER TABLE public.productos
  ADD CONSTRAINT productos_precios_venta_neto_hasta_final CHECK (precio_sin_iva <= precio),
  ADD CONSTRAINT productos_nombre_largo CHECK (char_length(nombre) <= 200);

-- =========================================================================
-- 7 · catalogo-B10 · el nombre de una marca, único sin mirar mayúsculas ni bordes
-- =========================================================================
-- Convive con marcas_sucursal_id_nombre_key (la exacta), que queda: no se saca nada que alguien
-- pueda estar nombrando.
CREATE UNIQUE INDEX marcas_sucursal_nombre_norm_uk ON public.marcas (sucursal_id, upper(btrim(nombre)));

-- =========================================================================
-- 8 · catalogo-B11 · un aviso por operación al dar de alta productos sin precio
-- =========================================================================
CREATE FUNCTION public.notificar_productos_sin_precio_alta()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
DECLARE
  r record;
BEGIN
  -- catalogo-B11 (tanda 6 de #1603): el alta avisaba una vez por producto y por destinatario
  -- (15.000 productos de un catálogo inicial sin precio, 15.000 avisos para cada admin y encargado).
  -- Ahora es un aviso por operación (este INSERT) y por sucursal. Uno solo, como siempre: con su
  -- producto. El precio que pasa a 0 lo sigue avisando notificar_producto_sin_precio, uno por uno.
  FOR r IN
    SELECT n.sucursal_id,
           count(*) AS cant,
           min(n.id) AS primero,
           (array_agg(n.nombre ORDER BY n.id))[1:3] AS nombres,
           (array_agg(n.id ORDER BY n.id))[1:50] AS ids
      FROM nuevos n
     WHERE n.precio IS NULL OR n.precio <= 0
     GROUP BY n.sucursal_id
     ORDER BY n.sucursal_id
  LOOP
    IF r.cant = 1 THEN
      PERFORM _notificar_sucursal_roles(
        r.sucursal_id,
        NULL::uuid,
        'producto_sin_precio'::varchar,
        'Producto sin precio de venta'::text,
        format('«%s» quedó sin precio de venta: no se puede vender hasta que lo cargues.', r.nombres[1])::text,
        'producto'::varchar,
        r.primero,
        jsonb_build_object('producto_id', r.primero, 'nombre', r.nombres[1])
      );
    ELSE
      PERFORM _notificar_sucursal_roles(
        r.sucursal_id,
        NULL::uuid,
        'producto_sin_precio'::varchar,
        'Productos sin precio de venta'::text,
        format('%s productos quedaron sin precio de venta (%s%s): no se pueden vender hasta que los cargues.',
               replace(to_char(r.cant, 'FM999,999,999'), ',', '.'),
               array_to_string(ARRAY(SELECT '«' || x || '»' FROM unnest(r.nombres) x), ', '),
               CASE WHEN r.cant > 3 THEN ' y otros' ELSE '' END)::text,
        NULL::varchar,
        NULL::bigint,
        jsonb_build_object('cantidad', r.cant, 'primeros_ids', to_jsonb(r.ids), 'primeros_nombres', to_jsonb(r.nombres))
      );
    END IF;
  END LOOP;
  RETURN NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public.notificar_productos_sin_precio_alta() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.notificar_productos_sin_precio_alta() TO service_role;

DROP TRIGGER trg_notificar_producto_sin_precio_ins ON public.productos;
CREATE TRIGGER trg_notificar_producto_sin_precio_ins
  AFTER INSERT ON public.productos
  REFERENCING NEW TABLE AS nuevos
  FOR EACH STATEMENT
  EXECUTE FUNCTION public.notificar_productos_sin_precio_alta();

-- =========================================================================
-- 2, 4, 6 y 10 · los parches por ancla
-- =========================================================================
CREATE TEMP TABLE t6c_tramos (ord int PRIMARY KEY, fn text, que text, ancla text, nuevo text) ON COMMIT DROP;

INSERT INTO t6c_tramos VALUES
-- 2 · catalogo-B1
(1, 'public.clientes_tipo_documento_del_valor()', 'declaraciones',
$a$DECLARE
  v_d text;
BEGIN
$a$,
$r$DECLARE
  v_d text;
  v_r int;
BEGIN
$r$),
(2, 'public.clientes_tipo_documento_del_valor()', 'el verificador del CUIT',
$a$  ELSIF v_d NOT LIKE '00%' THEN
    NEW.tipo_documento := 'CUIT';
  END IF;
$a$,
$r$  ELSIF v_d NOT LIKE '00%' THEN
    NEW.tipo_documento := 'CUIT';
    -- catalogo-B1 (tanda 6 de #1603; D37 de #1561: «uno inválido se rechaza»): un CUIT nuevo o
    -- cambiado tiene 11 dígitos y el verificador bien (módulo 11; resto 1 no existe). Rige al cambiar
    -- el documento: uno que ya estaba mal no traba la edición mientras sus dígitos no cambien.
    -- Espejo: errorDeCuit / validarCuit (src/components/modals/utils.ts).
    IF TG_OP = 'INSERT' OR v_d IS DISTINCT FROM regexp_replace(COALESCE(OLD.cuit, ''), '[^0-9]', '', 'g') THEN
      IF v_d !~ '^[0-9]{11}$' THEN
        RAISE EXCEPTION 'El CUIT «%» no es válido: tiene que tener 11 dígitos. Si el cliente no tiene documento, dejá el campo vacío.', NEW.cuit
          USING ERRCODE = '22023';
      END IF;
      v_r := (SELECT sum(substr(v_d, i, 1)::int * (ARRAY[5,4,3,2,7,6,5,4,3,2])[i]) FROM generate_series(1, 10) i) % 11;
      IF v_r = 1 OR (CASE WHEN v_r = 0 THEN 0 ELSE 11 - v_r END) <> substr(v_d, 11, 1)::int THEN
        RAISE EXCEPTION 'El CUIT «%» no es válido: el dígito verificador no coincide. Revisá los números.', NEW.cuit
          USING ERRCODE = '22023';
      END IF;
    END IF;
  END IF;
$r$),
-- 4 · catalogo-B3
(3, 'public.actualizar_precios_masivo(jsonb,jsonb)', 'el precio al centavo antes de la guarda',
$a$      v_neto  := (v_item->>'precio_neto')::NUMERIC;
      v_final := (v_item->>'precio_final')::NUMERIC;
$a$,
$r$      -- catalogo-B3 (tanda 6 de #1603): al centavo ANTES de la guarda, que es lo que guarda la
      -- columna (numeric(10,2)): 0,004 pasaba el > 0 y dejaba el producto en $ 0,00.
      v_neto  := round((v_item->>'precio_neto')::NUMERIC, 2);
      v_final := round((v_item->>'precio_final')::NUMERIC, 2);
$r$),
-- 6 · catalogo-B9
(4, 'public.guardar_cliente(jsonb)', 'el lock de los duplicados en el alta',
$a$    v_ver := public.verificar_duplicado_cliente(NULLIF(v_campos->>'latitud', '')::numeric,
$a$,
$r$    -- catalogo-B9 (tanda 6 de #1603): dos altas a la vez en la misma dirección pasaban las dos (la
    -- búsqueda no ve lo que la otra no confirmó). Las altas y las ediciones que mueven la dirección
    -- de una sucursal se serializan acá, hasta el COMMIT: la segunda espera y ve a la primera. Va
    -- después de la clave del alta (o de la fila del cliente) y antes del INSERT/UPDATE.
    PERFORM pg_advisory_xact_lock(hashtextextended('guardar_cliente:duplicado:' || v_suc, 0));
    v_ver := public.verificar_duplicado_cliente(NULLIF(v_campos->>'latitud', '')::numeric,
$r$),
(5, 'public.guardar_cliente(jsonb)', 'el lock de los duplicados en la edición',
$a$    IF v_toca_dir THEN
      v_ver := public.verificar_duplicado_cliente(
$a$,
$r$    IF v_toca_dir THEN
      -- catalogo-B9: el mismo lock que el alta, después de la fila del cliente.
      PERFORM pg_advisory_xact_lock(hashtextextended('guardar_cliente:duplicado:' || v_suc, 0));
      v_ver := public.verificar_duplicado_cliente(
$r$),
-- 10 · permisos-B5
(6, 'public._anular_gasto(bigint,text,boolean)', 'el admin anula parado en la sucursal del gasto',
$a$    IF NOT EXISTS (SELECT 1 FROM usuario_sucursales WHERE usuario_id = v_uid AND sucursal_id = v_gasto.sucursal_id) THEN
      RAISE EXCEPTION 'No tenés asignada la sucursal de este gasto';
    END IF;
$a$,
$r$    IF NOT EXISTS (SELECT 1 FROM usuario_sucursales WHERE usuario_id = v_uid AND sucursal_id = v_gasto.sucursal_id) THEN
      RAISE EXCEPTION 'No tenés asignada la sucursal de este gasto';
    END IF;
    -- permisos-B5 (tanda 6 de #1603; decisión del dueño del 24/11): toda rama admin mira la sucursal.
    -- Un admin de dos sucursales anula un gasto parado en la del gasto. El compartido es de todas
    -- (gastos_select lo muestra en cualquiera) y sigue con su regla, la de abajo.
    IF NOT v_gasto.compartido AND v_gasto.sucursal_id IS DISTINCT FROM public.current_sucursal_id() THEN
      RAISE EXCEPTION 'Este gasto es de la sucursal «%» y estás trabajando en otra: cambiate a esa sucursal para anularlo.',
        COALESCE((SELECT s.nombre FROM sucursales s WHERE s.id = v_gasto.sucursal_id), v_gasto.sucursal_id::text);
    END IF;
$r$);

DO $parche$
DECLARE
  f     text;
  v_def text;
  r     record;
  v_n   int;
BEGIN
  FOR f IN SELECT DISTINCT fn FROM t6c_tramos ORDER BY 1 LOOP
    v_def := pg_get_functiondef(f::regprocedure);
    FOR r IN SELECT * FROM t6c_tramos WHERE fn = f ORDER BY ord LOOP
      v_n := (length(v_def) - length(replace(v_def, r.ancla, ''))) / length(r.ancla);
      IF v_n <> 1 THEN
        RAISE EXCEPTION 'mig NNN · % (%): el ancla aparece % vez/veces y se esperaba 1', f, r.que, v_n;
      END IF;
      v_def := replace(v_def, r.ancla, r.nuevo);
    END LOOP;
    -- Las tres ya traen `SET search_path TO 'public', 'pg_temp'` (531): pg_get_functiondef lo conserva.
    IF position(E' SET search_path TO ''public'', ''pg_temp''\n' IN v_def) = 0 THEN
      RAISE EXCEPTION 'mig NNN · %: no encuentro su search_path con pg_temp', f;
    END IF;
    EXECUTE v_def;
  END LOOP;
END
$parche$;

-- -------------------------------------------------------------------------
-- Poscondición: los cuerpos nuevos son los del repo, el resto de cada cuerpo no cambió (deshaciendo
-- sus tramos vuelve el md5 de la premisa), y el definer (o no), el search_path y los EXECUTE son los
-- de antes. La policy, los CHECK, el índice y el trigger nuevos, como se escribieron.
-- -------------------------------------------------------------------------
DO $post$
DECLARE
  v_src text;
  v     text;
  r     record;
  t     record;
  x     record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.actualizar_precios_masivo(jsonb,jsonb)',
     'a6591c4955329e1778904cf105e8bc31', 'd055473f216e1f7b9efc370e3551e3f3',
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', true),
    ('public.guardar_cliente(jsonb)',
     '4e291fa6c77c1406bad58400b493d70b', 'd106be0a778ce9ffdb563d7030343871',
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', false),
    ('public.clientes_tipo_documento_del_valor()',
     '3eb8190498b7c8f7243e80fbf4526325', '79e75478f367a4abb24f4b7bbdf6e055',
     '{postgres=X/postgres,service_role=X/postgres}', false),
    ('public._anular_gasto(bigint,text,boolean)',
     'af021b07fcf5741ccbed34890a0004ab', '2be7627924c78a13671cb1ad025147f6',
     '{postgres=X/postgres,service_role=X/postgres}', true)
  ) AS v(fn, h, h_antes, acl, def) LOOP
    SELECT prosrc, md5(prosrc) AS h, proacl::text AS a, prosecdef AS def, proconfig::text AS cfg INTO x
      FROM pg_proc WHERE oid = r.fn::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def
       OR x.cfg IS DISTINCT FROM '{"search_path=public, pg_temp"}' THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %, config %)', r.fn, x.h, x.a, x.def, x.cfg;
    END IF;
    v_src := x.prosrc;
    FOR t IN SELECT * FROM t6c_tramos WHERE fn = r.fn ORDER BY ord DESC LOOP
      IF (length(v_src) - length(replace(v_src, t.nuevo, ''))) / length(t.nuevo) <> 1 THEN
        RAISE EXCEPTION 'mig NNN · % (%): el tramo nuevo no aparece una vez', r.fn, t.que;
      END IF;
      v_src := replace(v_src, t.nuevo, t.ancla);
    END LOOP;
    IF md5(v_src) IS DISTINCT FROM r.h_antes THEN
      RAISE EXCEPTION 'mig NNN · % cambió fuera de sus tramos (md5 sin el parche %)', r.fn, md5(v_src);
    END IF;
  END LOOP;

  -- La función nueva del aviso: su cuerpo, definer, search_path con pg_temp y sin EXECUTE para nadie
  -- más que el server (la invoca el trigger, no quien inserta).
  SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def, proconfig::text AS cfg INTO x
    FROM pg_proc WHERE oid = 'public.notificar_productos_sin_precio_alta()'::regprocedure;
  IF x.h IS DISTINCT FROM '865be3103de3d309a5868c37cf3339a2' OR x.a IS DISTINCT FROM '{postgres=X/postgres,service_role=X/postgres}'
     OR NOT x.def OR x.cfg IS DISTINCT FROM '{"search_path=public, pg_temp"}' THEN
    RAISE EXCEPTION 'mig NNN · notificar_productos_sin_precio_alta() no quedó como en el repo (md5 %, acl %, definer %, config %)',
      x.h, x.a, x.def, x.cfg;
  END IF;

  SELECT pg_get_triggerdef(oid) INTO v FROM pg_trigger
   WHERE tgrelid = 'public.productos'::regclass AND tgname = 'trg_notificar_producto_sin_precio_ins';
  IF v IS DISTINCT FROM 'CREATE TRIGGER trg_notificar_producto_sin_precio_ins AFTER INSERT ON public.productos REFERENCING NEW TABLE AS nuevos FOR EACH STATEMENT EXECUTE FUNCTION notificar_productos_sin_precio_alta()' THEN
    RAISE EXCEPTION 'mig NNN · poscondición: el trigger del aviso de alta quedó %', v;
  END IF;

  SELECT qual INTO v FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'cliente_descuentos_categoria' AND policyname = 'cdc_select'
     AND cmd = 'SELECT' AND roles = '{authenticated}';
  IF v IS DISTINCT FROM '(cliente_de_sucursal_activa(cliente_id) AND (es_encargado_o_admin() OR es_preventista()) AND (EXISTS ( SELECT 1
   FROM clientes c
  WHERE (c.id = cliente_descuentos_categoria.cliente_id))))' THEN
    RAISE EXCEPTION 'mig NNN · poscondición: cdc_select quedó %', v;
  END IF;

  IF (SELECT count(*) FROM pg_policies
       WHERE schemaname = 'public' AND cmd = 'SELECT' AND roles = '{authenticated}'
         AND ((tablename = 'promo_ajustes' AND policyname = 'mt_promo_ajustes_select')
           OR (tablename = 'control_stock_sesiones' AND policyname = 'mt_control_stock_sesiones_select'))
         AND qual = '((sucursal_id = current_sucursal_id()) AND (es_encargado_o_admin() OR (EXISTS ( SELECT 1
   FROM perfiles pd
  WHERE ((pd.id = ( SELECT auth.uid() AS uid)) AND (pd.rol = ''deposito''::text) AND COALESCE(pd.activo, true))))))') <> 2 THEN
    RAISE EXCEPTION 'mig NNN · poscondición: las policies de promo_ajustes y control_stock_sesiones no quedaron como se esperaba';
  END IF;

  IF (SELECT count(*) FROM pg_constraint
       WHERE contype = 'c' AND convalidated
         AND ((conrelid = 'public.clientes'::regclass AND conname IN ('clientes_latitud_rango', 'clientes_longitud_rango'))
           OR (conrelid = 'public.productos'::regclass AND conname IN ('productos_precios_venta_neto_hasta_final', 'productos_nombre_largo')))) <> 4 THEN
    RAISE EXCEPTION 'mig NNN · poscondición: faltan CHECK nuevos';
  END IF;

  IF (SELECT pg_get_indexdef(to_regclass('public.marcas_sucursal_nombre_norm_uk')))
     IS DISTINCT FROM 'CREATE UNIQUE INDEX marcas_sucursal_nombre_norm_uk ON public.marcas USING btree (sucursal_id, upper(btrim(nombre)))' THEN
    RAISE EXCEPTION 'mig NNN · poscondición: el índice de las marcas no quedó como se esperaba';
  END IF;
END
$post$;

COMMIT;
