-- =========================================================================
-- NNN · LA NOTA DE CRÉDITO DE VENTA: SE IMPUTA AL MES DE SU BOLETA, TIENE
--       MOTIVOS, Y LE DESCUENTA AL VENDEDOR SEGÚN EL MOTIVO Y SIN IR HACIA ATRÁS
--       (plan #1603, ola 2, tarjeta B16: decisiones del dueño del 16/11 en
--        #1545 y #1551, y del 17/11 en la ficha B16 v3)
--
-- Ensayos: scripts/test-nc-mes-de-la-boleta-ola2-1603.sql (las reglas) y
-- scripts/tiempos-nc-mes-de-la-boleta-ola2-1603.sql (los tiempos).
-- Se aplica en LF.
--
-- =========================================================================
-- 1 · LA NOTA SE IMPUTA AL DÍA DE SU BOLETA (16/11)
-- =========================================================================
-- «lo correcto es que se impute al mismo mes de la boleta y si bien haya un
-- campo de cuando se creó efectivamente, la fecha de imputación también existe
-- y es la que cuenta para estadísticas y fiscalmente».
--   · `notas_credito_venta.fecha` es la fecha de imputación: la de su boleta.
--     Cuándo se creó lo dice `created_at`. La pone
--     `trg_notas_credito_venta_fecha_de_boleta` (BEFORE INSERT OR UPDATE OF
--     fecha, pedido_id; lee la boleta FOR SHARE, así un cambio de fecha
--     concurrente no la deja atrás), mande lo que mande quien escribe; y si
--     cambia la fecha de la boleta, `trg_pedidos_fecha_arrastra_notas_credito`
--     lleva sus notas (vigentes y anuladas) a la nueva.
--   · La plata no cambia de día: el crédito de la nota (sus pagos), la caja y
--     la rendición siguen con el día en que se emitió.
--     crear_nota_credito_venta_impl devuelve `fecha` (la de imputación) y
--     `creada_el` (hoy).
--   · Las notas que ya existen se corrigen a la fecha de su boleta (en
--     producción, al 16/11: tres, de octubre sobre boletas de septiembre).
--   · Los reportes de VENTA y la posición fiscal restan TODA nota vigente, sea
--     cual sea el motivo, por su `fecha` (sin cambiar su cuenta): una nota de
--     noviembre sobre una boleta de octubre cambia la venta y la posición
--     fiscal de octubre. Es la venta real de la empresa. La NC de COMPRA no
--     cambia.
--
-- =========================================================================
-- 2 · LOS MOTIVOS (17/11)
-- =========================================================================
-- Una sola lista, `nc_venta_motivos()`, con espejo en el front
-- (src/constants/motivosNCVenta.espejo.json, su test y
-- scripts/espejo-motivos-nc-venta.mjs). Para cada motivo: si le descuenta al
-- vendedor, si le descuenta unidades y qué pasa con la mercadería (definido y
-- SIN USO: esta migración no mueve stock; lo hace la tarjeta que sigue).
--
--   motivo               descuenta  unidades  mercadería
--   cliente_rechaza      sí         sí        reingresa   El cliente lo devuelve o lo rechaza
--   error_pedido         sí         sí        reingresa   El pedido se tomó mal
--   error_entrega        no         no        reingresa   Se entregó mal
--   producto_vencido     no         no        merma
--   producto_danado      no         no        merma
--   descuento_comercial  sí         no        nada        Descuento comercial acordado después
--   otro                 no         no        nada
--
-- «en los únicos casos que debería descontarle al preventista es si el cliente
-- rechaza el producto por cuestiones propias (cuestión comercial) o porque se
-- haya tomado mal el pedido». Los tres motivos de antes siguen valiendo.
--
-- =========================================================================
-- 3 · QUÉ LE TOCA AL VENDEDOR, Y NADA HACIA ATRÁS (17/11)
-- =========================================================================
-- «Si ya están pagadas las comisiones o si las metas están cumplidas o fuera
-- del mes ya no deberían moverse». Se decide AL CREAR la nota y queda anotado:
--   · `notas_credito_venta.resta_comision`: el motivo descuenta, la boleta
--     tiene vendedor y su comisión todavía no se liquidó (para su vendedor de
--     hoy). Una comisión sin liquidar de un mes anterior sí descuenta. Lo que
--     ya se liquidó no se toca: no hay ajuste en ninguna liquidación.
--   · `nota_credito_venta_metas`: las metas de facturación (y de unidades, si
--     el motivo descuenta unidades) del vendedor de la boleta, activas, cuyo
--     período tiene la boleta, que la nota encuentra en su mes (hoy ≤ fin) y
--     todavía sin cumplir (`_meta_logrado`, la misma cuenta que
--     avance_metas_preventista, antes de esta nota).
--   · Anular la nota devuelve lo restado sólo donde no quedó congelado:
--     `resta_comision` queda si la comisión de la boleta ya se liquidó (el
--     descuento se pagó así), y la fila de una meta queda si la meta ya
--     terminó su mes o ya está cumplida (con el descuento puesto). Lo
--     congelado sigue restando aunque la nota esté anulada; la VENTA no la
--     resta más.
--   · La comisión (`_comision_lineas`, la única) baja por las notas con
--     `resta_comision` (`_nc_resta_comision`), por clave, como en la v2. El
--     factor del adelanto de sueldo va sobre la venta neta de esas notas
--     (boleta de 1.000, nota de 200 que descuenta, 800 con adelanto: base 0);
--     si la nota no descuenta, sobre el total.
--   · Las metas cuentan las notas de su fila (plata; unidades si el motivo las
--     descuenta). Rendimiento (venta, unidades, margen, marca y rubro del
--     vendedor) resta las notas vigentes cuyo motivo le descuenta, sin foto:
--     es el desempeño del mes. El gerencial, en lo del vendedor
--     (`kpis.base_comision`, `vendedores[].base_nc`), resta lo mismo que la
--     comisión; su venta sigue restando toda nota. El bot muestra venta: resta
--     toda nota (bot_ventas_periodo, bot_mis_ventas y el resumen del
--     preventista).
--   · `_liquidacion_lineas` no cambia: con la foto, una nota no produce deltas.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

-- Las tablas con DDL, sus locks primero y sin esperar: pedidos (su CREATE
-- TRIGGER) y metas_preventista (la FK de la tabla nueva) en SHARE ROW
-- EXCLUSIVE; notas_credito_venta (columna, CHECK y triggers) en ACCESS
-- EXCLUSIVE. Si alguno está tomado, falla al instante y se reintenta.
LOCK TABLE public.pedidos, public.metas_preventista IN SHARE ROW EXCLUSIVE MODE NOWAIT;
LOCK TABLE public.notas_credito_venta IN ACCESS EXCLUSIVE MODE NOWAIT;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos de producción en la 526. reporte_gerencial va sin
-- md5 (otras tarjetas le parchan el tramo de compras): se exige que las anclas
-- de su tramo aparezcan una vez.
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)', 'a58b4f71752f8b004fbc3c524b12be8b'),
    ('public._comision_lineas(bigint[])', 'b20534d37d4a481d0154326fbbcccda8'),
    ('public.avance_metas_preventista(uuid,date)', '2e6695223c3add5fe1e23944884493a9'),
    ('public.rendimiento_preventistas(bigint,date)', 'bd3dcdc97f4bf07f325ecafb10f97a09'),
    ('public.bot_ventas_periodo(date,date,bigint,integer)', 'bd6bef33c089422952ddb0e549be3cc9'),
    ('public.bot_mis_ventas(uuid,date,date,bigint,integer)', 'fff91e69cfa74fd6c95ac05b57a5299e'),
    ('public.reporte_gerencial(bigint,date,date,boolean,boolean)', NULL),
    ('public._ventas_nc(bigint[],date,date)', 'c44fdae60942de6e93649d62b2024d75'),
    ('public.anular_nota_credito_venta(bigint,text)', NULL),
    ('public._tablero_hoy()', NULL)
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    IF r.h IS NULL THEN CONTINUE; END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;
  IF to_regproc('public.notas_credito_venta_fecha_de_boleta') IS NOT NULL
     OR to_regproc('public.pedidos_fecha_arrastra_notas_credito') IS NOT NULL
     OR to_regproc('public.notas_credito_venta_foto_vendedor') IS NOT NULL
     OR to_regproc('public.nc_venta_motivos') IS NOT NULL
     OR to_regproc('public.es_motivo_nc_venta') IS NOT NULL
     OR to_regproc('public._meta_logrado') IS NOT NULL
     OR to_regproc('public._nc_resta_comision') IS NOT NULL
     OR to_regclass('public.nota_credito_venta_metas') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · algo de esta migración ya existe: revisar a mano';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_trigger
              WHERE tgname IN ('trg_notas_credito_venta_fecha_de_boleta', 'trg_pedidos_fecha_arrastra_notas_credito',
                               'trg_notas_credito_venta_foto_vendedor', 'trg_notas_credito_venta_foto_vendedor_metas')) THEN
    RAISE EXCEPTION 'mig NNN · los triggers ya existen: revisar a mano';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.notas_credito_venta'::regclass
                AND attname = 'resta_comision' AND NOT attisdropped) THEN
    RAISE EXCEPTION 'mig NNN · notas_credito_venta.resta_comision ya existe: revisar a mano';
  END IF;
END
$premisas$;

-- Reemplaza una sola aparición de un ancla en una definición. Las definiciones
-- se leen en LF (dos de las vivas tienen CRLF en prod: da lo mismo para el SQL).
CREATE FUNCTION pg_temp.parche(p_def text, p_ancla text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v_n int := (length(p_def) - length(replace(p_def, p_ancla, ''))) / length(p_ancla);
BEGIN
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · %: el ancla aparece % vez/veces y se esperaba 1', p_que, v_n;
  END IF;
  RETURN replace(p_def, p_ancla, p_nuevo);
END
$f$;

CREATE FUNCTION pg_temp.def(p_f text)
RETURNS text LANGUAGE sql AS $f$
  SELECT replace(pg_get_functiondef(p_f::regprocedure), E'\r\n', E'\n');
$f$;

-- El tramo de una definición que va desde `p_desde` (incluido) hasta `p_hasta`
-- (excluido). Las dos marcas aparecen una sola vez, en ese orden.
CREATE FUNCTION pg_temp.tramo(p_def text, p_desde text, p_hasta text, p_que text)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v_i int := position(p_desde in p_def);
  v_j int := position(p_hasta in p_def);
BEGIN
  IF (length(p_def) - length(replace(p_def, p_desde, ''))) / length(p_desde) <> 1
     OR (length(p_def) - length(replace(p_def, p_hasta, ''))) / length(p_hasta) <> 1
     OR v_j <= v_i THEN
    RAISE EXCEPTION 'mig NNN · %: las marcas del tramo no aparecen una vez cada una y en orden', p_que;
  END IF;
  RETURN substr(p_def, v_i, v_j - v_i);
END
$f$;

-- =========================================================================
-- 1 · La fecha de la nota es la de su boleta
-- =========================================================================

-- B16 (#1545, decisión del dueño del 16/11): la fecha de una nota de crédito de
-- venta es la de imputación, la de su boleta; cuándo se creó es created_at. Le
-- pone la fecha de la boleta a toda nota que se escribe, venga de donde venga.
CREATE FUNCTION public.notas_credito_venta_fecha_de_boleta()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_fecha date;
BEGIN
  -- FOR SHARE (H2 de la revisión): un cambio de fecha de la boleta en otra
  -- transacción espera a que ésta termine, o ésta lee la fecha que dejó. La RPC
  -- ya tiene la boleta FOR UPDATE, y el arrastre la tiene por su UPDATE: es la
  -- misma transacción, no espera.
  SELECT p.fecha INTO v_fecha
    FROM pedidos p
   WHERE p.id = NEW.pedido_id AND p.sucursal_id = NEW.sucursal_id
     FOR SHARE;
  -- Sin boleta, la FK compuesta rechaza la fila: no hay fecha que poner.
  IF v_fecha IS NOT NULL THEN
    NEW.fecha := v_fecha;
  END IF;
  RETURN NEW;
END
$function$;

REVOKE ALL ON FUNCTION public.notas_credito_venta_fecha_de_boleta() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.notas_credito_venta_fecha_de_boleta() TO service_role;

CREATE TRIGGER trg_notas_credito_venta_fecha_de_boleta
  BEFORE INSERT OR UPDATE OF fecha, pedido_id ON public.notas_credito_venta
  FOR EACH ROW EXECUTE FUNCTION public.notas_credito_venta_fecha_de_boleta();

-- B16: si la boleta cambia de fecha, sus notas (vigentes y anuladas) van con
-- ella. DEFINER: el admin corrige la fecha por REST y authenticated no escribe
-- notas_credito_venta. El orden de locks es el de la NC: la boleta y después
-- sus notas.
CREATE FUNCTION public.pedidos_fecha_arrastra_notas_credito()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  UPDATE notas_credito_venta
     SET fecha = NEW.fecha
   WHERE pedido_id = NEW.id
     AND sucursal_id = NEW.sucursal_id
     AND fecha IS DISTINCT FROM NEW.fecha;
  RETURN NULL;
END
$function$;

REVOKE ALL ON FUNCTION public.pedidos_fecha_arrastra_notas_credito() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pedidos_fecha_arrastra_notas_credito() TO service_role;

CREATE TRIGGER trg_pedidos_fecha_arrastra_notas_credito
  AFTER UPDATE OF fecha ON public.pedidos
  FOR EACH ROW WHEN (OLD.fecha IS DISTINCT FROM NEW.fecha)
  EXECUTE FUNCTION public.pedidos_fecha_arrastra_notas_credito();

COMMENT ON COLUMN public.notas_credito_venta.fecha IS
  'La fecha de imputación: la de su boleta (pedidos.fecha), que la pone trg_notas_credito_venta_fecha_de_boleta y arrastra trg_pedidos_fecha_arrastra_notas_credito (B16, decisión del dueño del 16/11). Es la que cuenta para los reportes y la posición fiscal. Cuándo se creó es created_at; su crédito (pagos) va con la fecha en que se emitió.';

-- Las notas que ya existen, a la fecha de su boleta. En producción, al 16/11,
-- eran tres (dos vigentes y una anulada), creadas en octubre sobre boletas de
-- septiembre: si son muchas más, mirar antes de moverlas.
DO $datos$
DECLARE
  v_total   int;
  v_mover   int;
  v_vig     int;
  v_movidas int;
BEGIN
  SELECT count(*),
         count(*) FILTER (WHERE n.fecha IS DISTINCT FROM p.fecha),
         count(*) FILTER (WHERE n.fecha IS DISTINCT FROM p.fecha AND NOT n.anulada)
    INTO v_total, v_mover, v_vig
    FROM notas_credito_venta n
    JOIN pedidos p ON p.id = n.pedido_id AND p.sucursal_id = n.sucursal_id;
  RAISE NOTICE 'mig NNN · notas de crédito de venta: % en total, % con otra fecha que la de su boleta (% vigentes)',
    v_total, v_mover, v_vig;
  IF v_mover > 20 THEN
    RAISE EXCEPTION 'mig NNN · hay % notas de venta fuera de la fecha de su boleta (el 16/11 eran 3): revisarlas antes de moverlas', v_mover;
  END IF;

  UPDATE notas_credito_venta n
     SET fecha = p.fecha
    FROM pedidos p
   WHERE p.id = n.pedido_id AND p.sucursal_id = n.sucursal_id
     AND n.fecha IS DISTINCT FROM p.fecha;
  GET DIAGNOSTICS v_movidas = ROW_COUNT;
  RAISE NOTICE 'mig NNN · se movieron % notas de crédito de venta a la fecha de su boleta', v_movidas;

  IF v_movidas <> v_mover OR EXISTS (
       SELECT 1 FROM notas_credito_venta n JOIN pedidos p ON p.id = n.pedido_id AND p.sucursal_id = n.sucursal_id
        WHERE n.fecha IS DISTINCT FROM p.fecha) THEN
    RAISE EXCEPTION 'mig NNN · quedaron notas fuera de la fecha de su boleta (movidas %, esperadas %)', v_movidas, v_mover;
  END IF;
END
$datos$;

-- =========================================================================
-- 2 · Los motivos: una sola lista
-- =========================================================================

-- B16 v3 (decisión del dueño del 17/11). Espejo en el front:
-- src/constants/motivosNCVenta.espejo.json (lo vigilan su test y
-- scripts/espejo-motivos-nc-venta.mjs). `mercaderia` está definida y sin uso:
-- esta migración no mueve stock.
CREATE FUNCTION public.nc_venta_motivos()
RETURNS TABLE(motivo text, descuenta_vendedor boolean, descuenta_unidades boolean, mercaderia text)
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path TO 'public'
AS $function$
  VALUES ('cliente_rechaza'::text, true,  true,  'reingresa'::text),
         ('error_pedido',          true,  true,  'reingresa'),
         ('error_entrega',         false, false, 'reingresa'),
         ('producto_vencido',      false, false, 'merma'),
         ('producto_danado',       false, false, 'merma'),
         ('descuento_comercial',   true,  false, 'nada'),
         ('otro',                  false, false, 'nada')
$function$;

CREATE FUNCTION public.es_motivo_nc_venta(p_motivo text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path TO 'public'
AS $function$
  SELECT EXISTS (SELECT 1 FROM public.nc_venta_motivos() m WHERE m.motivo = p_motivo);
$function$;

-- Como formas_pago(): la lista no es un secreto (el front la espeja); anon no.
REVOKE ALL ON FUNCTION public.nc_venta_motivos() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.es_motivo_nc_venta(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.nc_venta_motivos() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.es_motivo_nc_venta(text) TO authenticated, service_role;

DO $motivos$
BEGIN
  IF EXISTS (SELECT 1 FROM notas_credito_venta WHERE NOT public.es_motivo_nc_venta(motivo)) THEN
    RAISE EXCEPTION 'mig NNN · hay notas de venta con un motivo que no está en nc_venta_motivos(): %',
      (SELECT string_agg(DISTINCT motivo, ', ') FROM notas_credito_venta WHERE NOT public.es_motivo_nc_venta(motivo));
  END IF;
END
$motivos$;

ALTER TABLE public.notas_credito_venta
  DROP CONSTRAINT notas_credito_venta_motivo_check,
  ADD CONSTRAINT notas_credito_venta_motivo_valido CHECK (public.es_motivo_nc_venta(motivo));

-- =========================================================================
-- 3 · Qué le toca al vendedor: la foto al crear la nota
-- =========================================================================

ALTER TABLE public.notas_credito_venta
  ADD COLUMN resta_comision boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.notas_credito_venta.resta_comision IS
  'B16 v3 (decisión del dueño del 17/11): la nota resta de la comisión de su boleta. Lo decide trg_notas_credito_venta_foto_vendedor al crearla (el motivo descuenta, la boleta tiene vendedor y su comisión no estaba liquidada) y al anularla (queda si la comisión ya se liquidó: lo pagado no se mueve). Una nota anulada con esta marca sigue restando de la comisión, no de la venta.';

-- B16 v3: las metas de las que resta una nota (la foto al crearla). Tabla de
-- server: se lee y se escribe sólo por los triggers y las funciones de metas.
CREATE TABLE public.nota_credito_venta_metas (
  nota_credito_id bigint      NOT NULL REFERENCES public.notas_credito_venta(id) ON DELETE CASCADE,
  meta_id         bigint      NOT NULL REFERENCES public.metas_preventista(id) ON DELETE CASCADE,
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (nota_credito_id, meta_id)
);

CREATE INDEX nota_credito_venta_metas_meta_idx ON public.nota_credito_venta_metas (meta_id);

COMMENT ON TABLE public.nota_credito_venta_metas IS
  'B16 v3 (decisión del dueño del 17/11): cada fila es una meta de la que resta la nota. Nace al crear la nota (el motivo descuenta, la meta está en su mes y sin cumplir) y se borra al anularla sólo si la meta sigue en su mes y sin cumplir. Tabla de server.';

ALTER TABLE public.nota_credito_venta_metas ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.nota_credito_venta_metas FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.nota_credito_venta_metas TO service_role;

-- Lo logrado de una meta: la cuenta de avance_metas_preventista, en una sola
-- función (la usan avance_metas_preventista y la foto de la nota). Las notas
-- restan sólo de las metas de su fila (plata; unidades si el motivo las
-- descuenta), y sólo mientras la boleta siga siendo venta del vendedor de la
-- meta en su período.
CREATE FUNCTION public._meta_logrado(p_meta_id bigint)
RETURNS numeric
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
  WITH m AS (
    SELECT * FROM metas_preventista WHERE id = p_meta_id
  ),
  ped AS MATERIALIZED (
    SELECT p.id, p.cliente_id
      FROM pedidos p, m
     WHERE p.usuario_id = m.preventista_id
       AND p.sucursal_id = m.sucursal_id
       AND p.estado = 'entregado'
       AND p.canal <> 'cambio'
       -- 3XB: el vale blanco no cuenta para ninguna meta.
       AND p.tipo_factura IS DISTINCT FROM 'VB'
       AND p.fecha BETWEEN m.periodo AND m.periodo_fin
  ),
  it AS MATERIALIZED (
    SELECT pi.cantidad, pi.subtotal, pi.producto_id, prod.categoria_id, prod.marca_id
      FROM ped
      JOIN pedido_items pi ON pi.pedido_id = ped.id
      -- #1262: LEFT. La línea de un producto borrado suma a las metas globales.
      LEFT JOIN productos prod ON prod.id = pi.producto_id
     WHERE pi.es_bonificacion IS NOT TRUE
    UNION ALL
    SELECT CASE WHEN mot.descuenta_unidades THEN -i.cantidad ELSE 0 END, -i.subtotal,
           i.producto_id, prod.categoria_id, prod.marca_id
      FROM nota_credito_venta_metas nm
      JOIN notas_credito_venta n ON n.id = nm.nota_credito_id
      JOIN ped ON ped.id = n.pedido_id
      JOIN nota_credito_venta_items i ON i.nota_credito_id = n.id
      JOIN public.nc_venta_motivos() mot ON mot.motivo = n.motivo
      LEFT JOIN productos prod ON prod.id = i.producto_id
     WHERE nm.meta_id = p_meta_id
  )
  SELECT CASE m.tipo_meta
           WHEN 'facturacion' THEN (
             SELECT COALESCE(SUM(i.subtotal), 0) FROM it i
              WHERE (m.marca_id     IS NULL OR i.marca_id     = m.marca_id)
                AND (m.categoria_id IS NULL OR i.categoria_id = m.categoria_id)
                AND (m.producto_ids IS NULL OR i.producto_id  = ANY(m.producto_ids)))
           WHEN 'unidades' THEN (
             SELECT COALESCE(SUM(i.cantidad), 0) FROM it i
              WHERE (m.marca_id     IS NULL OR i.marca_id     = m.marca_id)
                AND (m.categoria_id IS NULL OR i.categoria_id = m.categoria_id)
                AND (m.producto_ids IS NULL OR i.producto_id  = ANY(m.producto_ids)))
           WHEN 'cobertura' THEN (SELECT COUNT(DISTINCT ped.cliente_id) FROM ped)
           WHEN 'clientes_nuevos' THEN (
             SELECT COUNT(*)
               FROM (SELECT DISTINCT ON (p.cliente_id) p.cliente_id, p.usuario_id, p.fecha
                       FROM pedidos p
                      WHERE p.estado = 'entregado' AND p.canal <> 'cambio'
                        AND p.tipo_factura IS DISTINCT FROM 'VB'  -- 3XB: un vale no hace cliente nuevo
                        AND p.sucursal_id = m.sucursal_id
                      ORDER BY p.cliente_id, p.fecha, p.id) pp
              WHERE pp.usuario_id = m.preventista_id
                AND pp.fecha BETWEEN m.periodo AND m.periodo_fin)
         END::numeric
    FROM m;
$function$;

REVOKE ALL ON FUNCTION public._meta_logrado(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._meta_logrado(bigint) TO service_role;

-- La foto: al crear la nota (BEFORE: si resta de la comisión; AFTER: de qué
-- metas) y al anularla (BEFORE: si sigue restando de la comisión; AFTER: de qué
-- metas sigue restando). DEFINER: la escribe la RPC de la nota o el server.
CREATE FUNCTION public.notas_credito_venta_foto_vendedor()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_descuenta boolean;
  v_unidades  boolean;
  v_liquidada boolean;
  v_vendedor  uuid;
BEGIN
  IF TG_OP = 'UPDATE' AND NOT (NEW.anulada AND NOT OLD.anulada) THEN
    IF TG_WHEN = 'BEFORE' THEN
      RETURN NEW;
    END IF;
    RETURN NULL;
  END IF;

  SELECT m.descuenta_vendedor, m.descuenta_unidades INTO v_descuenta, v_unidades
    FROM public.nc_venta_motivos() m WHERE m.motivo = NEW.motivo;
  v_descuenta := COALESCE(v_descuenta, false);
  v_unidades := COALESCE(v_unidades, false);
  -- El vendedor de hoy de la boleta (con perfil: sin él, nadie comisiona).
  SELECT p.usuario_id INTO v_vendedor
    FROM pedidos p
   WHERE p.id = NEW.pedido_id AND p.usuario_id IN (SELECT id FROM perfiles);
  -- ¿La comisión de la boleta ya se liquidó para ese vendedor?
  v_liquidada := EXISTS (SELECT 1 FROM empleado_liquidacion_lineas l
                          WHERE l.pedido_id = NEW.pedido_id AND l.usuario_id = v_vendedor AND l.vigente);

  IF TG_OP = 'INSERT' THEN
    IF TG_WHEN = 'BEFORE' THEN
      NEW.resta_comision := v_descuenta AND NOT NEW.anulada AND v_vendedor IS NOT NULL AND NOT v_liquidada;
      RETURN NEW;
    END IF;
    IF v_descuenta AND NOT NEW.anulada AND v_vendedor IS NOT NULL THEN
      INSERT INTO nota_credito_venta_metas (nota_credito_id, meta_id)
      SELECT NEW.id, m.id
        FROM pedidos p
        JOIN metas_preventista m ON m.preventista_id = p.usuario_id AND m.sucursal_id = p.sucursal_id
       WHERE p.id = NEW.pedido_id
         AND m.activo
         AND (m.tipo_meta = 'facturacion' OR (m.tipo_meta = 'unidades' AND v_unidades))
         AND p.fecha BETWEEN m.periodo AND m.periodo_fin
         AND public._tablero_hoy() <= m.periodo_fin
         AND public._meta_logrado(m.id) < m.valor_objetivo
       ORDER BY m.id;
    END IF;
    RETURN NULL;
  END IF;

  -- La anulación: vuelve lo que no quedó congelado.
  IF TG_WHEN = 'BEFORE' THEN
    NEW.resta_comision := OLD.resta_comision AND v_liquidada;
    RETURN NEW;
  END IF;
  DELETE FROM nota_credito_venta_metas nm
   USING metas_preventista m
   WHERE nm.nota_credito_id = NEW.id
     AND m.id = nm.meta_id
     AND public._tablero_hoy() <= m.periodo_fin
     AND public._meta_logrado(m.id) < m.valor_objetivo;
  RETURN NULL;
END
$function$;

REVOKE ALL ON FUNCTION public.notas_credito_venta_foto_vendedor() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.notas_credito_venta_foto_vendedor() TO service_role;

CREATE TRIGGER trg_notas_credito_venta_foto_vendedor
  BEFORE INSERT OR UPDATE OF anulada ON public.notas_credito_venta
  FOR EACH ROW EXECUTE FUNCTION public.notas_credito_venta_foto_vendedor();

CREATE TRIGGER trg_notas_credito_venta_foto_vendedor_metas
  AFTER INSERT OR UPDATE OF anulada ON public.notas_credito_venta
  FOR EACH ROW EXECUTE FUNCTION public.notas_credito_venta_foto_vendedor();

-- Las notas que ya existen: su foto con la misma regla. Los motivos de antes
-- (vencido, dañado, otro) no le descuentan al vendedor, así que ninguna resta
-- de la comisión ni de una meta (la columna nace en false y la tabla vacía).
DO $foto$
DECLARE
  v_total int;
  v_descuentan int;
BEGIN
  SELECT count(*),
         count(*) FILTER (WHERE (SELECT m.descuenta_vendedor FROM public.nc_venta_motivos() m WHERE m.motivo = n.motivo))
    INTO v_total, v_descuentan
    FROM notas_credito_venta n;
  RAISE NOTICE 'mig NNN · foto del vendedor: % notas existentes, % con un motivo que le descuenta: ninguna resta de una comisión ni de una meta',
    v_total, v_descuentan;
  IF v_descuentan > 0 THEN
    RAISE EXCEPTION 'mig NNN · hay % notas con un motivo que descuenta al vendedor: no pueden existir antes de esta migración', v_descuentan;
  END IF;
END
$foto$;

-- crear_nota_credito_venta_impl: el motivo de la lista; la nota con la fecha de
-- la boleta (el trigger la pondría igual: así se lee), el crédito con la de hoy;
-- y devuelve qué le resta al vendedor.
DO $nc$
DECLARE
  v_def text := pg_temp.def('public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)');
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  v_fecha     date   := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;$a$,
$n$  v_fecha     date   := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_fecha_nc  date;     -- B16: la de imputación, la de la boleta
  v_resta_com boolean;  -- B16 v3: la foto del vendedor$n$, 'nc · declare');
  v_def := pg_temp.parche(v_def,
$a$  IF COALESCE(p_motivo, '') NOT IN ('producto_vencido', 'producto_danado', 'otro') THEN$a$,
$n$  -- B16 v3: la lista es una, nc_venta_motivos().
  IF NOT public.es_motivo_nc_venta(COALESCE(p_motivo, '')) THEN$n$, 'nc · motivo');
  v_def := pg_temp.parche(v_def,
$a$  INSERT INTO notas_credito_venta (
    sucursal_id, cliente_id, pedido_id, fecha, motivo, observaciones, total, usuario_id,
    neto, iva
  ) VALUES (
    v_sucursal, p_cliente_id, p_pedido_id, v_fecha, p_motivo, NULLIF(trim(p_observaciones), ''),
    v_total, v_user,
    round(v_neto, 2), round(v_iva, 2)
  ) RETURNING id INTO v_nc_id;$a$,
$n$  -- B16 (#1545, decisión del dueño del 16/11): la nota se imputa al día de su
  -- boleta (trg_notas_credito_venta_fecha_de_boleta lo garantiza); cuándo se creó
  -- es created_at. Su crédito (el pago de abajo) es plata de hoy: v_fecha. Qué le
  -- resta al vendedor lo decide trg_notas_credito_venta_foto_vendedor (B16 v3).
  INSERT INTO notas_credito_venta (
    sucursal_id, cliente_id, pedido_id, fecha, motivo, observaciones, total, usuario_id,
    neto, iva
  ) VALUES (
    v_sucursal, p_cliente_id, p_pedido_id, (SELECT pb.fecha FROM pedidos pb WHERE pb.id = p_pedido_id),
    p_motivo, NULLIF(trim(p_observaciones), ''),
    v_total, v_user,
    round(v_neto, 2), round(v_iva, 2)
  ) RETURNING id, fecha, resta_comision INTO v_nc_id, v_fecha_nc, v_resta_com;$n$, 'nc · insert');
  v_def := pg_temp.parche(v_def,
$a$    'fecha', v_fecha,$a$,
$n$    'fecha', v_fecha_nc,
    'creada_el', v_fecha,
    'resta_comision', v_resta_com,
    'metas_restadas', (SELECT count(*) FROM nota_credito_venta_metas WHERE nota_credito_id = v_nc_id),$n$, 'nc · respuesta');
  EXECUTE v_def;
END
$nc$;

-- =========================================================================
-- 4 · La comisión (una sola: _comision_lineas)
-- =========================================================================

-- B16 v3: las notas que restan de la comisión de sus boletas (resta_comision:
-- vigentes, o anuladas con la comisión ya liquidada), por renglón de nota. La
-- usan _comision_lineas y la base del gerencial.
CREATE FUNCTION public._nc_resta_comision(p_pedido_ids bigint[])
RETURNS TABLE(nota_credito_id bigint, pedido_id bigint, pedido_item_id bigint, producto_id bigint, monto numeric)
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
  SELECT n.id, n.pedido_id, i.pedido_item_id, i.producto_id, i.subtotal
    FROM notas_credito_venta n
    JOIN nota_credito_venta_items i ON i.nota_credito_id = n.id
   WHERE n.pedido_id = ANY(p_pedido_ids)
     AND n.resta_comision
     AND n.total > 0
$function$;

REVOKE ALL ON FUNCTION public._nc_resta_comision(bigint[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._nc_resta_comision(bigint[]) TO service_role;

DO $com$
DECLARE
  v_def text := pg_temp.def('public._comision_lineas(bigint[])');
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  WITH ped AS ($a$,
$n$  WITH
  -- B16 v3 (#1545, decisión del dueño del 17/11): las notas de crédito que le
  -- descuentan al vendedor (resta_comision, la foto al crearlas), una vez y
  -- acotadas a estas boletas (MATERIALIZED: H1 de la revisión).
  ncp_it AS MATERIALIZED (
    SELECT * FROM public._nc_resta_comision(p_pedido_ids)
  ),
  ncp AS (
    SELECT ncp_it.pedido_id, SUM(ncp_it.monto) AS monto FROM ncp_it GROUP BY ncp_it.pedido_id
  ),
  ped AS ($n$, 'comision · notas');
  v_def := pg_temp.parche(v_def,
$a$           CASE WHEN p.total > 0
                THEN 1 - LEAST(COALESCE(ad.monto, 0), p.total) / p.total
                ELSE 1
           END AS factor
    FROM pedidos p$a$,
$n$           -- B16 v3 (decisión del dueño del 17/11): sobre la venta neta de las
           -- notas que le descuentan (boleta de 1.000, nota de 200, 800 con
           -- adelanto: base 0). Sin nota que descuente, sobre el total.
           CASE WHEN p.total - COALESCE(ncp.monto, 0) > 0
                THEN 1 - LEAST(COALESCE(ad.monto, 0), p.total - COALESCE(ncp.monto, 0))
                         / (p.total - COALESCE(ncp.monto, 0))
                ELSE 1
           END AS factor
    FROM pedidos p
    LEFT JOIN ncp ON ncp.pedido_id = p.id$n$, 'comision · factor');
  v_def := pg_temp.parche(v_def,
$a$  it AS (
    SELECT ped.id AS pedido_id, ped.usuario_id, ped.fecha, ped.sucursal_id,
           pi.subtotal * ped.factor AS subtotal,$a$,
$n$  lin AS (
    SELECT ped.id AS pedido_id, ped.usuario_id, ped.fecha, ped.sucursal_id,
           pi.subtotal * ped.factor AS subtotal,
           COALESCE(pi.producto_id::text, '-') || '|' || COALESCE(pi.combo_id::text, '-') || '|'
             || COALESCE(pi.origen_precio::text, '-') AS clave,$n$, 'comision · lin');
  v_def := pg_temp.parche(v_def,
$a$      AND ped.factor > 0
  )
  SELECT it.pedido_id,$a$,
$n$      AND ped.factor > 0
  ),
  -- Cada renglón de nota en la clave de su renglón de la boleta o, si la edición
  -- lo rehízo, en la del mismo producto; si la boleta no tiene ese producto
  -- (sólo por una carga directa del server), en la de su renglón de mayor venta.
  -- Con el factor del adelanto de sueldo.
  nc AS (
    SELECT v.pedido_id,
           COALESCE((CASE WHEN pi.id IS NOT NULL THEN pi.producto_id
                          ELSE COALESCE(alt.producto_id, v.producto_id) END)::text, '-') || '|'
             || COALESCE((CASE WHEN pi.id IS NOT NULL THEN pi.combo_id ELSE alt.combo_id END)::text, '-') || '|'
             || COALESCE(CASE WHEN pi.id IS NOT NULL THEN pi.origen_precio::text ELSE alt.origen_precio END, '-') AS clave,
           v.monto * ped.factor AS monto
      FROM ncp_it v
      JOIN ped ON ped.id = v.pedido_id
      LEFT JOIN pedido_items pi ON pi.id = v.pedido_item_id AND pi.pedido_id = v.pedido_id
      LEFT JOIN LATERAL (
        SELECT x.producto_id, x.combo_id, x.origen_precio::text AS origen_precio
          FROM pedido_items x
         WHERE x.pedido_id = v.pedido_id
           AND COALESCE(x.es_bonificacion, false) = false
         ORDER BY (x.producto_id IS NOT DISTINCT FROM v.producto_id) DESC,
                  CASE WHEN x.producto_id IS NOT DISTINCT FROM v.producto_id
                       THEN (x.combo_id IS NULL)::int ELSE 0 END DESC,
                  CASE WHEN x.producto_id IS NOT DISTINCT FROM v.producto_id
                       THEN 0 ELSE x.subtotal END DESC,
                  x.id
         LIMIT 1
      ) alt ON pi.id IS NULL
  ),
  -- Lo que restan las notas en cada clave, con tope en lo que la clave vende.
  -- MATERIALIZED (H1 de la revisión): sin eso el planner, que estima `lin` en
  -- una fila, lo reordenaba por cada renglón. Sólo las boletas con nota.
  nc_clave AS MATERIALIZED (
    SELECT k.pedido_id, k.clave, k.base, LEAST(n.monto, k.base) AS monto
      FROM (SELECT lin.pedido_id, lin.clave, SUM(lin.subtotal) AS base
              FROM lin
             WHERE lin.pedido_id IN (SELECT nc.pedido_id FROM nc)
             GROUP BY lin.pedido_id, lin.clave) k
      JOIN (SELECT nc.pedido_id, nc.clave, SUM(nc.monto) AS monto FROM nc GROUP BY nc.pedido_id, nc.clave) n
        ON n.pedido_id = k.pedido_id AND n.clave = k.clave
     WHERE k.base > 0
  ),
  -- Cada renglón de la clave baja en proporción: los renglones (y los ítems) son
  -- los de la boleta, y la suma de la clave es su venta menos sus notas.
  it AS (
    SELECT l.pedido_id, l.usuario_id, l.fecha, l.sucursal_id,
           CASE WHEN k.pedido_id IS NULL THEN l.subtotal
                ELSE l.subtotal - k.monto * l.subtotal / k.base END AS subtotal,
           l.producto_id, l.combo_id, l.origen_precio, l.categoria_id, l.pct_default
      FROM lin l
      LEFT JOIN nc_clave k ON k.pedido_id = l.pedido_id AND k.clave = l.clave
  )
  SELECT it.pedido_id,$n$, 'comision · nc');
  EXECUTE v_def;
END
$com$;

-- El gerencial, en lo del vendedor: la base de comisión (kpis y vendedores)
-- resta lo mismo que la comisión, con el mismo factor. Su venta sigue restando
-- toda nota (ncl). Sólo el CTE `nc`, por ancla.
DO $ger$
DECLARE
  v_def text := pg_temp.def('public.reporte_gerencial(bigint,date,date,boolean,boolean)');
BEGIN
  v_def := pg_temp.parche(v_def,
$a$           ROUND(GREATEST(pe.total - pe.cargo_envio, 0)
                 * CASE WHEN pe.total > 0
                        THEN 1 - LEAST(COALESCE(ad.monto, 0), pe.total) / pe.total
                        ELSE 1 END, 2) AS total$a$,
$n$           -- B16 v3 (#1545): menos las notas que le descuentan al vendedor
           -- (_nc_resta_comision), con el factor del adelanto sobre la venta neta.
           ROUND(GREATEST(GREATEST(pe.total - pe.cargo_envio, 0) - COALESCE(ncp.monto, 0), 0)
                 * CASE WHEN pe.total - COALESCE(ncp.monto, 0) > 0
                        THEN 1 - LEAST(COALESCE(ad.monto, 0), pe.total - COALESCE(ncp.monto, 0))
                                 / (pe.total - COALESCE(ncp.monto, 0))
                        ELSE 1 END, 2) AS total$n$, 'gerencial · base');
  v_def := pg_temp.parche(v_def,
$a$      ) ad ON true
     WHERE pe.estado='entregado' AND pe.canal <> 'cambio'$a$,
$n$      ) ad ON true
      LEFT JOIN (SELECT x.pedido_id, SUM(x.monto) AS monto
                   FROM public._nc_resta_comision(ARRAY(SELECT p2.id FROM pedidos p2
                                                         WHERE p2.fecha BETWEEN p_desde AND p_hasta
                                                           AND p2.sucursal_id = ANY(v_sucursales))) x
                  GROUP BY x.pedido_id) ncp
        ON ncp.pedido_id = pe.id
     WHERE pe.estado='entregado' AND pe.canal <> 'cambio'$n$, 'gerencial · notas');
  EXECUTE v_def;
END
$ger$;

-- =========================================================================
-- 5 · Las metas y Rendimiento
-- =========================================================================

-- avance_metas_preventista: lo logrado de cada meta sale de _meta_logrado (la
-- misma cuenta que la foto de la nota usa para saber si una meta estaba
-- cumplida). Reemplaza su tramo de ped/it/primer_pedido/logrado.
DO $metas$
DECLARE
  v_def text := pg_temp.def('public.avance_metas_preventista(uuid,date)');
  v_tramo text;
BEGIN
  v_tramo := pg_temp.tramo(v_def, $a$  ped AS MATERIALIZED ($a$, $a$  calc AS ($a$, 'metas · tramo');
  IF position('WHEN ''facturacion'' THEN (' in v_tramo) = 0 OR position('primer_pedido AS (' in v_tramo) = 0 THEN
    RAISE EXCEPTION 'mig NNN · metas: el tramo no es el de ped, it, primer_pedido y logrado';
  END IF;
  v_def := replace(v_def, v_tramo,
$n$  -- MATERIALIZED: _meta_logrado corre una vez por meta (sin esto el planner la
  -- copiaba en cada lugar que lee `logrado`).
  logrado AS MATERIALIZED (
    SELECT m.*,
      (m.periodo_fin - m.periodo + 1) AS dias_periodo,
      GREATEST(0, LEAST(v_hoy - m.periodo + 1, m.periodo_fin - m.periodo + 1)) AS dias_trans,
      -- B16 v3 (decisión del dueño del 17/11): lo logrado es una sola cuenta,
      -- _meta_logrado (las ventas del vendedor en el período, menos las notas
      -- que restan de esta meta según su foto). La foto de la nota la usa para
      -- saber si la meta estaba cumplida.
      public._meta_logrado(m.id) AS logrado
    FROM metas m
  ),
$n$);
  EXECUTE v_def;
END
$metas$;

DO $rend$
DECLARE
  v_def text := pg_temp.def('public.rendimiento_preventistas(bigint,date)');
BEGIN
  v_def := pg_temp.parche(v_def,
$a$    LEFT JOIN categorias cat ON cat.id = prod.categoria_id  -- 1562-b7: el rubro
    WHERE pi.es_bonificacion IS NOT TRUE
  ),$a$,
$n$    LEFT JOIN categorias cat ON cat.id = prod.categoria_id  -- 1562-b7: el rubro
    WHERE pi.es_bonificacion IS NOT TRUE
    UNION ALL
    -- B16 v3 (decisión del dueño del 17/11): el desempeño del vendedor resta las
    -- notas de crédito vigentes de las boletas del mes cuyo motivo le descuenta
    -- (nc_venta_motivos), la plata y, si el motivo lo dice, las unidades. Sin
    -- foto: es el mes del vendedor, no lo que se le paga. No toca el costo. Una
    -- línea acreditada sin costo resta de la venta sin costo.
    SELECT n.usuario_id,
           CASE WHEN mot.descuenta_unidades THEN -n.cantidad ELSE 0 END,
           -n.monto,
           0 * public.costo_valuacion(n.costo_al_crear, prod.costo_promedio,
             prod.costo_real, prod.costo_sin_iva, prod.impuestos_internos),
           COALESCE(mar.nombre, '(sin marca)'),
           CASE WHEN prod.id IS NULL THEN '(producto borrado)'
                ELSE public._rubro_rotulo(COALESCE(cat.nombre, prod.categoria)) END
      FROM public._ventas_nc(v_sucursales, v_periodo, v_hasta) n
      JOIN notas_credito_venta nn ON nn.id = n.nota_credito_id
      JOIN public.nc_venta_motivos() mot ON mot.motivo = nn.motivo AND mot.descuenta_vendedor
      LEFT JOIN productos prod ON prod.id = n.producto_id
      LEFT JOIN marcas mar ON mar.id = prod.marca_id
      LEFT JOIN categorias cat ON cat.id = prod.categoria_id
  ),$n$, 'rendimiento · it');
  EXECUTE v_def;
END
$rend$;

-- =========================================================================
-- 6 · El bot: la VENTA, neta de toda nota (sin cambiar sus JSON)
-- =========================================================================
DO $bot$
DECLARE
  v_def text := pg_temp.def('public.bot_ventas_periodo(date,date,bigint,integer)');
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  WITH ventas_filtradas AS ($a$,
$n$  WITH nc AS MATERIALIZED (
    -- B16 (#1545): las notas de crédito de las boletas del período (_ventas_nc,
    -- imputadas al día de su boleta, de cualquier motivo: es venta) restan de la
    -- venta, del top de clientes y de lo facturado por producto. No de las
    -- unidades. MATERIALIZED: _ventas_nc corre una vez, no una por boleta.
    SELECT n.pedido_id, n.producto_id, n.monto
      FROM public._ventas_nc(ARRAY[p_sucursal_id], p_desde, p_hasta) n
  ),
  ventas_filtradas AS ($n$, 'bot_ventas_periodo · nc');
  v_def := pg_temp.parche(v_def,
$a$    SELECT id, cliente_id, GREATEST(total - cargo_envio, 0) AS total, fecha$a$,
$n$    SELECT id, cliente_id,
           GREATEST(total - cargo_envio, 0)
             - COALESCE((SELECT SUM(nc.monto) FROM nc WHERE nc.pedido_id = pedidos.id), 0) AS total,
           fecha$n$, 'bot_ventas_periodo · total');
  v_def := pg_temp.parche(v_def,
$a$    SELECT p.id, p.codigo, p.nombre, SUM(pi.cantidad) AS unidades, SUM(pi.subtotal) AS facturado$a$,
$n$    SELECT p.id, p.codigo, p.nombre, SUM(pi.cantidad) AS unidades,
           SUM(pi.subtotal) - COALESCE((SELECT SUM(nc.monto) FROM nc WHERE nc.producto_id = p.id), 0) AS facturado$n$,
    'bot_ventas_periodo · facturado');
  v_def := pg_temp.parche(v_def,
$a$    ORDER BY SUM(pi.subtotal) DESC LIMIT p_limit$a$,
$n$    ORDER BY facturado DESC LIMIT p_limit$n$, 'bot_ventas_periodo · orden');
  EXECUTE v_def;

  v_def := pg_temp.def('public.bot_mis_ventas(uuid,date,date,bigint,integer)');
  v_def := pg_temp.parche(v_def,
$a$  WITH ventas_filtradas AS ($a$,
$n$  WITH nc AS MATERIALIZED (
    -- B16 (#1545): las notas de crédito de sus boletas restan de su venta
    -- (_ventas_nc, de cualquier motivo). El resumen del preventista
    -- (bot_digest_preventista) lo lee de acá. MATERIALIZED: _ventas_nc corre una
    -- vez, no una por boleta.
    SELECT n.pedido_id, n.monto
      FROM public._ventas_nc(ARRAY[p_sucursal_id], p_desde, p_hasta) n
     WHERE n.usuario_id = p_preventista_id
  ),
  ventas_filtradas AS ($n$, 'bot_mis_ventas · nc');
  v_def := pg_temp.parche(v_def,
$a$    SELECT p.id, p.cliente_id, GREATEST(p.total - p.cargo_envio, 0) AS total$a$,
$n$    SELECT p.id, p.cliente_id,
           GREATEST(p.total - p.cargo_envio, 0)
             - COALESCE((SELECT SUM(nc.monto) FROM nc WHERE nc.pedido_id = p.id), 0) AS total$n$,
    'bot_mis_ventas · total');
  EXECUTE v_def;
END
$bot$;

-- =========================================================================
-- Poscondiciones
-- =========================================================================
DO $post$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)', 'es_motivo_nc_venta', true),
    ('public._comision_lineas(bigint[])', '_nc_resta_comision', false),
    ('public.reporte_gerencial(bigint,date,date,boolean,boolean)', '_nc_resta_comision', true),
    ('public.avance_metas_preventista(uuid,date)', '_meta_logrado(m.id)', true),
    ('public.rendimiento_preventistas(bigint,date)', 'mot.descuenta_vendedor', true),
    ('public.bot_ventas_periodo(date,date,bigint,integer)', '_ventas_nc', true),
    ('public.bot_mis_ventas(uuid,date,date,bigint,integer)', '_ventas_nc', true)
  ) AS t(f, marca, definer) LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = r.f::regprocedure
                    AND position(r.marca in prosrc) > 0 AND prosecdef = r.definer) THEN
      RAISE EXCEPTION 'mig NNN · el parche de % no entró', r.f;
    END IF;
  END LOOP;
  -- Las de server: sin EXECUTE para nadie de la API.
  FOR r IN SELECT unnest(ARRAY['public.notas_credito_venta_fecha_de_boleta()',
                               'public.pedidos_fecha_arrastra_notas_credito()',
                               'public.notas_credito_venta_foto_vendedor()',
                               'public._meta_logrado(bigint)',
                               'public._nc_resta_comision(bigint[])']) AS f LOOP
    IF has_function_privilege('anon', r.f, 'EXECUTE') OR has_function_privilege('authenticated', r.f, 'EXECUTE') THEN
      RAISE EXCEPTION 'mig NNN · % quedó con EXECUTE para la API', r.f;
    END IF;
  END LOOP;
  IF has_function_privilege('anon', 'public.nc_venta_motivos()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.es_motivo_nc_venta(text)', 'EXECUTE')
     OR has_table_privilege('authenticated', 'public.nota_credito_venta_metas', 'SELECT')
     OR has_table_privilege('anon', 'public.nota_credito_venta_metas', 'SELECT') THEN
    RAISE EXCEPTION 'mig NNN · permisos de más en los motivos o en nota_credito_venta_metas';
  END IF;
  IF (SELECT count(*) FROM pg_trigger
       WHERE (tgname IN ('trg_notas_credito_venta_fecha_de_boleta', 'trg_notas_credito_venta_foto_vendedor',
                         'trg_notas_credito_venta_foto_vendedor_metas')
              AND tgrelid = 'public.notas_credito_venta'::regclass)
          OR (tgname = 'trg_pedidos_fecha_arrastra_notas_credito' AND tgrelid = 'public.pedidos'::regclass)) <> 4 THEN
    RAISE EXCEPTION 'mig NNN · faltan triggers de la nota';
  END IF;
END
$post$;

COMMIT;
