-- =========================================================================
-- El lote mas viejo lleva su propio contador
--
-- EL PROBLEMA
-- -----------
-- La distribuidora no lee codigo de barras. Sin lectura no hay forma de saber
-- que unidad fisica salio, asi que tampoco hay forma de saber cuando se vence
-- lo que queda en el deposito. Hoy el vencimiento no existe en ningun lado:
-- `grep -i lote|vencimiento` sobre migrations/ solo devuelve "lote" en el
-- sentido de batch de registros y `vencimiento` como motivo de merma.
--
-- Lo que se necesita es acotado: enterarse a tiempo de lo que esta por vencer
-- para liquidarlo, bonificarlo o devolverlo antes de perderlo. NO se necesita
-- trazabilidad lote -> cliente (eso obligaria a guardar el lote en cada
-- pedido_items y a tocar crear_pedido_completo, que es la funcion mas
-- parcheada del repo).
--
-- EL MODELO: UN LOTE ES UNA FECHA CON UN CONTADOR
-- -----------------------------------------------
-- No lleva costo -- la valuacion de la merma ya la congela
-- trg_mermas_snapshot_costo (mig 119) --, no lleva numero de lote del
-- proveedor, y no se lo referencia desde el pedido.
--
-- La pieza que hace que todo esto funcione sin backfill ni inventario inicial
-- es que la bolsa "sin vencimiento" NO es una fila: es una resta.
--
--   bolsa = productos.stock - SUM(producto_lotes.cantidad_restante)
--
-- De ahi sale el resto solo:
--   * entra mercaderia sin fecha cargada -> sube stock, no hay lote -> engorda
--     la bolsa;
--   * entra con fecha -> sube stock y nace el lote -> la bolsa queda igual;
--   * sale mercaderia -> primero se come la bolsa (automatico, es derivada) y
--     recien cuando llega a 0 se consume del lote que VENCE ANTES;
--   * vuelve mercaderia de una venta -> se devuelve al lote del que salio.
--
-- El invariante que lo sostiene es SUM(cantidad_restante) <= productos.stock
-- por (producto, sucursal). Este codigo NUNCA escribe productos.stock: lo lee y
-- acomoda los lotes contra el. Por eso STK-A y STK-B (los dos critical de
-- auditoria_integridad) quedan intactos -- el ledger de stock sigue siendo la
-- unica verdad del saldo, y los lotes son una particion que lo sigue.
--
-- FEFO, NO FIFO
-- -------------
-- El orden de salida lo manda la fecha de vencimiento, no la de compra. Es la
-- diferencia que importa: si el proveedor manda mercaderia con vencimiento mas
-- corto que la que ya estaba, un FIFO puro la deja tapada en el fondo hasta que
-- se vence. La contrapartida es un compromiso fisico: el deposito tiene que
-- sacar de la caja que vence antes.
--
-- POR QUE UN SOLO TRIGGER Y NO 20 RPCs
-- ------------------------------------
-- Todo lo que mueve stock en esta app pasa por UPDATE productos SET stock, y
-- ya hay un trigger (trg_stock_historico, mig 038) que registra el movimiento
-- leyendo current_setting('app.stock_origen'). Enganchar el consumo de lotes
-- ahi cubre de una sola vez pedidos, bot, mermas -- que ni siquiera pasan por
-- una RPC: son dos statements desde el navegador --, movimientos entre
-- sucursales, control de stock y el ajuste manual desde la ficha.
--
-- Lo que sigue es esta migracion; las RPCs de operacion van en la 224 y los
-- invariantes LOTE-* en la 225.
-- =========================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1 - La tabla
-- ---------------------------------------------------------------------------

-- La FK compuesta necesita este destino. En produccion ya existe (lo creo el
-- barrido dinamico de la mig 187), pero no hay ningun archivo del repo que lo
-- escriba, asi que una base levantada desde migrations/ podria no tenerlo.
-- El nombre es el de la convencion 187: <padre>_<columna>_<tenant_sin_id>_uk.
DO $mig$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'productos_id_sucursal_uk'
       AND conrelid = 'public.productos'::regclass
  ) THEN
    ALTER TABLE public.productos
      ADD CONSTRAINT productos_id_sucursal_uk UNIQUE (id, sucursal_id);
  END IF;
END
$mig$;

CREATE TABLE IF NOT EXISTS public.producto_lotes (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  producto_id       bigint  NOT NULL,
  sucursal_id       bigint  NOT NULL REFERENCES public.sucursales(id),
  fecha_vencimiento date    NOT NULL,
  cantidad          integer NOT NULL CHECK (cantidad > 0),
  cantidad_restante integer NOT NULL CHECK (cantidad_restante >= 0),
  compra_id         bigint,
  origen            text    NOT NULL DEFAULT 'compra'
                      CHECK (origen IN ('compra', 'manual')),
  usuario_id        uuid REFERENCES public.perfiles(id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT producto_lotes_restante_ck CHECK (cantidad_restante <= cantidad),

  -- FKs COMPUESTAS y no simples. Un admin parado en la sucursal A podria colgar
  -- un lote con sucursal_id = A sobre un producto de B: la policy chequea la
  -- fila y pasa, y una FK simple a productos(id) no mira la sucursal. Ademas
  -- check-sucursal-cruzada.mjs marca al dia siguiente cualquier par hija->padre
  -- que no la tenga.
  CONSTRAINT producto_lotes_producto_fk
    FOREIGN KEY (producto_id, sucursal_id)
    REFERENCES public.productos(id, sucursal_id) ON DELETE CASCADE,
  CONSTRAINT producto_lotes_compra_fk
    FOREIGN KEY (compra_id, sucursal_id)
    REFERENCES public.compras(id, sucursal_id) ON DELETE CASCADE,

  -- Una compra no puede cargar dos veces la misma fecha para el mismo producto:
  -- son el mismo lote y van sumados. Con compra_id NULL (lotes manuales) el
  -- UNIQUE no aplica -- en Postgres los NULL son distintos entre si --, y de eso
  -- se encarga crear_lote_manual, que fusiona por (producto, fecha).
  CONSTRAINT producto_lotes_compra_unico UNIQUE (compra_id, producto_id, fecha_vencimiento)
);

COMMENT ON TABLE public.producto_lotes IS
  'Vencimientos por lote. Un lote es una fecha con un contador que baja. La '
  'bolsa "sin vencimiento" NO esta aca: es productos.stock menos la suma de '
  'cantidad_restante. Invariante: esa suma nunca supera productos.stock '
  '(LOTE-A). mig 223.';

COMMENT ON COLUMN public.producto_lotes.cantidad IS
  'Unidades con las que nacio el lote. No cambia salvo re-sync de la compra.';
COMMENT ON COLUMN public.producto_lotes.cantidad_restante IS
  'Lo que queda. Lo baja el trigger de productos por FEFO y lo sube de vuelta '
  'cuando una venta se cancela. 0 = agotado, deja de aparecer en el panel.';
COMMENT ON COLUMN public.producto_lotes.origen IS
  'compra = nacio de una factura de compra. manual = alguien etiqueto parte de '
  'la bolsa desde la ficha del producto (es el camino para el stock que ya '
  'existia cuando se prendio la feature).';

-- El barrido de consumo: por producto, ordenado por fecha, solo los vivos.
CREATE INDEX IF NOT EXISTS idx_producto_lotes_fefo
  ON public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento)
  WHERE cantidad_restante > 0;

-- El panel de vencimientos: por sucursal, ordenado por fecha, solo los vivos.
CREATE INDEX IF NOT EXISTS idx_producto_lotes_alerta
  ON public.producto_lotes (sucursal_id, fecha_vencimiento)
  WHERE cantidad_restante > 0;

CREATE INDEX IF NOT EXISTS idx_producto_lotes_compra
  ON public.producto_lotes (compra_id);

-- ---------------------------------------------------------------------------
-- 2 - RLS
--
-- Cuatro policies separadas y nunca una FOR ALL (criterio de la mig 192). Aca
-- solo va la de SELECT: la escritura entra toda por RPC SECURITY DEFINER, asi
-- que el default-deny de RLS alcanza -- mismo esquema que comision_reglas o
-- promo_acumuladores.
--
-- Ojo con el default privilege del baseline: toda tabla nueva creada por
-- postgres en public nace con INSERT/UPDATE/DELETE para cualquier logueado
-- (mig 186). Lo unico que frena la escritura por PostgREST es que NO exista
-- policy de escritura. Por eso abajo se otorga SELECT y nada mas.
-- ---------------------------------------------------------------------------

ALTER TABLE public.producto_lotes ENABLE ROW LEVEL SECURITY;

-- El EXISTS sobre perfiles va inlineado a proposito: NO existe es_deposito() y
-- no hay que inventarlo (mig 192). es_encargado_o_admin() si existe y cubre a
-- los dos roles de administracion.
DROP POLICY IF EXISTS mt_producto_lotes_select ON public.producto_lotes;
CREATE POLICY mt_producto_lotes_select ON public.producto_lotes
  FOR SELECT TO authenticated
  USING (
    (public.es_encargado_o_admin() OR EXISTS (
      SELECT 1 FROM public.perfiles
       WHERE perfiles.id = auth.uid() AND perfiles.rol = 'deposito'))
    AND sucursal_id = public.current_sucursal_id()
  );

GRANT SELECT ON public.producto_lotes TO authenticated;

-- ---------------------------------------------------------------------------
-- 3 - El motor de consumo
--
-- Nombre con guion bajo adelante: la convencion de migrations/README.md las
-- deja sin EXECUTE para nadie. Solo las llama el trigger, que corre como
-- postgres.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._consumir_lotes_fefo(
  p_producto_id bigint,
  p_sucursal_id bigint,
  p_cantidad    integer
) RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_pendiente integer := p_cantidad;
  v_toma      integer;
  r           record;
BEGIN
  IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
    RETURN 0;
  END IF;

  -- FEFO: vence antes, sale antes. El desempate por id mantiene el orden
  -- estable entre transacciones, que es lo que evita deadlocks cuando dos
  -- pedidos tocan el mismo producto.
  FOR r IN
    SELECT id, cantidad_restante
      FROM public.producto_lotes
     WHERE producto_id = p_producto_id
       AND sucursal_id = p_sucursal_id
       AND cantidad_restante > 0
     ORDER BY fecha_vencimiento ASC, id ASC
     FOR UPDATE
  LOOP
    EXIT WHEN v_pendiente <= 0;
    v_toma := LEAST(v_pendiente, r.cantidad_restante);
    UPDATE public.producto_lotes
       SET cantidad_restante = cantidad_restante - v_toma
     WHERE id = r.id;
    v_pendiente := v_pendiente - v_toma;
  END LOOP;

  -- Si sobra pendiente es porque no habia lotes suficientes: el resto salio de
  -- la bolsa, que es derivada y no hay que tocar. No es un error.
  RETURN p_cantidad - v_pendiente;
END;
$fn$;

COMMENT ON FUNCTION public._consumir_lotes_fefo(bigint, bigint, integer) IS
  'Descuenta N unidades de los lotes del producto, el que vence antes primero. '
  'Devuelve cuanto pudo descontar. mig 223.';

CREATE OR REPLACE FUNCTION public._restaurar_lotes_fefo(
  p_producto_id bigint,
  p_sucursal_id bigint,
  p_cantidad    integer
) RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_pendiente integer := p_cantidad;
  v_pone      integer;
  r           record;
BEGIN
  IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
    RETURN 0;
  END IF;

  -- La inversa exacta del consumo: se devuelve al lote que vence antes, que es
  -- del que se habia sacado. Nunca por encima de `cantidad`, que es el techo
  -- de lo que ese lote llego a tener.
  FOR r IN
    SELECT id, (cantidad - cantidad_restante) AS hueco
      FROM public.producto_lotes
     WHERE producto_id = p_producto_id
       AND sucursal_id = p_sucursal_id
       AND cantidad_restante < cantidad
     ORDER BY fecha_vencimiento ASC, id ASC
     FOR UPDATE
  LOOP
    EXIT WHEN v_pendiente <= 0;
    v_pone := LEAST(v_pendiente, r.hueco);
    UPDATE public.producto_lotes
       SET cantidad_restante = cantidad_restante + v_pone
     WHERE id = r.id;
    v_pendiente := v_pendiente - v_pone;
  END LOOP;

  -- Lo que sobra vuelve a la bolsa: es mercaderia que salio antes de que
  -- existieran los lotes, o de la propia bolsa.
  RETURN p_cantidad - v_pendiente;
END;
$fn$;

COMMENT ON FUNCTION public._restaurar_lotes_fefo(bigint, bigint, integer) IS
  'Devuelve N unidades a los lotes del producto, el que vence antes primero. '
  'Inversa de _consumir_lotes_fefo. mig 223.';

-- ---------------------------------------------------------------------------
-- 4 - El trigger
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.sincronizar_lotes_stock() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_delta    integer := NEW.stock - OLD.stock;
  v_asignado integer;
  v_bolsa    integer;
  v_origen   text := COALESCE(NULLIF(current_setting('app.stock_origen', true), ''), 'auto');
BEGIN
  IF v_delta = 0 THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(SUM(cantidad_restante), 0) INTO v_asignado
    FROM public.producto_lotes
   WHERE producto_id = NEW.id AND sucursal_id = NEW.sucursal_id;

  -- Atajo del caso comun: producto sin lotes vivos. Es el 95% del padron
  -- mientras la feature se va llenando, y sin esto pagariamos un barrido por
  -- cada linea de cada pedido.
  IF v_asignado = 0 THEN
    RETURN NEW;
  END IF;

  IF v_delta < 0 THEN
    -- Sale mercaderia. Primero se come la bolsa, que es derivada y se achica
    -- sola al bajar el stock; los lotes solo se tocan por el excedente.
    v_bolsa := OLD.stock - v_asignado;
    IF (-v_delta) > v_bolsa THEN
      PERFORM public._consumir_lotes_fefo(NEW.id, NEW.sucursal_id, (-v_delta) - v_bolsa);
    END IF;

  -- Sube por una DEVOLUCION de venta: la mercaderia vuelve al lote del que
  -- salio. Sin esta rama el modelo se desangra de a poco -- cada cancelacion
  -- moveria unidades del lote a la bolsa y los contadores mentirian para abajo.
  --
  -- Lo que sube por compra, ingreso entre sucursales, control de stock o ajuste
  -- manual NO entra aca: es mercaderia nueva o de origen desconocido y va a la
  -- bolsa. `pedido_creado` esta en la lista porque actualizar_pedido_items lo
  -- usa para las dos direcciones -- bajar la cantidad de un pedido devuelve
  -- stock.
  ELSIF v_origen IN ('pedido_creado', 'pedido_creado_bot', 'pedido_cancelado',
                     'pedido_eliminado', 'salvedad', 'sustitucion_regalo',
                     'auto_ajuste_promo', 'movimiento_denegado',
                     'movimiento_cancelado') THEN
    PERFORM public._restaurar_lotes_fefo(NEW.id, NEW.sucursal_id, v_delta);
  END IF;

  RETURN NEW;
END;
$fn$;

COMMENT ON FUNCTION public.sincronizar_lotes_stock() IS
  'Acomoda los lotes contra productos.stock despues de cada movimiento. Nunca '
  'escribe stock: solo lo lee. mig 223.';

-- AFTER UPDATE sin `OF stock` y filtrando adentro, igual que
-- registrar_cambio_stock: un UPDATE OF no cubre lo que no nombra, y esa lista
-- es justamente lo que hizo que trigger_actualizar_saldo_pedido no se disparara
-- al mover cliente_id.
--
-- Va SECURITY DEFINER porque productos se puede editar por PostgREST (admin y
-- deposito tienen policy de UPDATE) y producto_lotes no tiene policy de
-- escritura. La advertencia de la mig 181 sobre triggers-guard y SECURITY
-- DEFINER no aplica: esa es para triggers que filtran por current_user, y este
-- no lo mira.
CREATE OR REPLACE TRIGGER trg_lotes_sincronizar
  AFTER UPDATE ON public.productos
  FOR EACH ROW EXECUTE FUNCTION public.sincronizar_lotes_stock();

-- ---------------------------------------------------------------------------
-- 5 - Los umbrales, en la politica comercial de la sucursal
--
-- Un parametro de negocio que cambia va en politicas_comerciales, no en una
-- constante ni en una env var. La tabla es tipada a proposito (mig 204): sumar
-- una politica es una columna con su propio CHECK.
--
-- Dos umbrales y no uno porque son dos decisiones distintas: "ojo con esto,
-- empujalo" y "esto hay que liquidarlo ya". Los defaults van con valor real y
-- no en 0: sin lotes cargados no alertan nada, asi que aplicar la migracion
-- sigue sin cambiarle el comportamiento a nadie -- que es el criterio de la 204.
-- ---------------------------------------------------------------------------

ALTER TABLE public.politicas_comerciales
  ADD COLUMN IF NOT EXISTS dias_alerta_vencimiento  integer NOT NULL DEFAULT 60,
  ADD COLUMN IF NOT EXISTS dias_critico_vencimiento integer NOT NULL DEFAULT 15;

DO $mig$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'politicas_comerciales_dias_alerta_ck') THEN
    ALTER TABLE public.politicas_comerciales
      ADD CONSTRAINT politicas_comerciales_dias_alerta_ck
      CHECK (dias_alerta_vencimiento >= 0 AND dias_alerta_vencimiento <= 3650);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'politicas_comerciales_dias_critico_ck') THEN
    ALTER TABLE public.politicas_comerciales
      ADD CONSTRAINT politicas_comerciales_dias_critico_ck
      CHECK (dias_critico_vencimiento >= 0
             AND dias_critico_vencimiento <= dias_alerta_vencimiento);
  END IF;
END
$mig$;

COMMENT ON COLUMN public.politicas_comerciales.dias_alerta_vencimiento IS
  'Dias de anticipacion para el aviso amarillo. 0 = solo avisa lo ya vencido. '
  'mig 223.';
COMMENT ON COLUMN public.politicas_comerciales.dias_critico_vencimiento IS
  'Dias de anticipacion para el aviso rojo. Siempre <= dias_alerta. mig 223.';

CREATE OR REPLACE FUNCTION public.actualizar_alertas_vencimiento(
  p_dias_alerta  integer,
  p_dias_critico integer
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_sucursal bigint := public.current_sucursal_id();
  v_rol      text;
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la sucursal activa';
  END IF;

  SELECT rol INTO v_rol FROM public.perfiles WHERE id = auth.uid();
  IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin o encargado';
  END IF;

  IF p_dias_alerta IS NULL OR p_dias_alerta < 0 THEN
    RAISE EXCEPTION 'Los dias de alerta no pueden ser negativos';
  END IF;
  IF p_dias_critico IS NULL OR p_dias_critico < 0 THEN
    RAISE EXCEPTION 'Los dias criticos no pueden ser negativos';
  END IF;
  IF p_dias_critico > p_dias_alerta THEN
    RAISE EXCEPTION 'El aviso rojo (% dias) no puede ser antes que el amarillo (% dias)',
      p_dias_critico, p_dias_alerta;
  END IF;

  -- Va por RPC y no por UPDATE directo para sellar actualizado_por con
  -- auth.uid() del lado del servidor (mig 204).
  INSERT INTO public.politicas_comerciales (
    sucursal_id, dias_alerta_vencimiento, dias_critico_vencimiento,
    actualizado_por, actualizado_en
  )
  VALUES (v_sucursal, p_dias_alerta, p_dias_critico, auth.uid(), now())
  ON CONFLICT (sucursal_id) DO UPDATE
    SET dias_alerta_vencimiento  = EXCLUDED.dias_alerta_vencimiento,
        dias_critico_vencimiento = EXCLUDED.dias_critico_vencimiento,
        actualizado_por          = EXCLUDED.actualizado_por,
        actualizado_en           = EXCLUDED.actualizado_en;

  RETURN jsonb_build_object(
    'dias_alerta_vencimiento',  p_dias_alerta,
    'dias_critico_vencimiento', p_dias_critico
  );
END;
$fn$;

COMMENT ON FUNCTION public.actualizar_alertas_vencimiento(integer, integer) IS
  'Fija los dos umbrales de aviso de vencimiento de la sucursal activa. Solo '
  'admin/encargado. mig 223.';

-- ---------------------------------------------------------------------------
-- 6 - Permisos
--
-- Toda funcion nueva de public nace con EXECUTE para PUBLIC y Supabase se lo
-- concede a anon por separado: hay que revocar LAS DOS MITADES en la misma
-- migracion. GRANT TO authenticated no lo revierte.
--
-- sincronizar_lotes_stock() es RETURNS trigger: no lleva EXECUTE para nadie.
-- La invoca el executor como parte del DML, no el caller (mig 213).
-- Los helpers _consumir/_restaurar tampoco: solo los llama el trigger.
-- ---------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public._consumir_lotes_fefo(bigint, bigint, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._restaurar_lotes_fefo(bigint, bigint, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sincronizar_lotes_stock() FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.actualizar_alertas_vencimiento(integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.actualizar_alertas_vencimiento(integer, integer) TO authenticated;

DO $verif$
DECLARE
  v_acl text;
  v_fn  text;
BEGIN
  -- Las que NO tienen que ser alcanzables por nadie con la anon key.
  FOREACH v_fn IN ARRAY ARRAY['_consumir_lotes_fefo', '_restaurar_lotes_fefo',
                              'sincronizar_lotes_stock'] LOOP
    SELECT array_to_string(proacl, ',') INTO v_acl
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = v_fn;

    IF v_acl IS NULL THEN
      RAISE EXCEPTION '% quedo con ACL default (PUBLIC ejecuta)', v_fn;
    END IF;
    IF v_acl LIKE '=X/%' OR v_acl LIKE '%,=X/%' THEN
      RAISE EXCEPTION '% quedo ejecutable por PUBLIC: %', v_fn, v_acl;
    END IF;
    IF v_acl LIKE '%anon=%' THEN
      RAISE EXCEPTION '% quedo ejecutable por anon: %', v_fn, v_acl;
    END IF;
    IF v_acl LIKE '%authenticated=%' THEN
      RAISE EXCEPTION '% no deberia ser ejecutable por authenticated: %', v_fn, v_acl;
    END IF;
  END LOOP;

  -- La que si tiene que llamar el front.
  SELECT array_to_string(proacl, ',') INTO v_acl
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'actualizar_alertas_vencimiento';

  IF v_acl IS NULL THEN
    RAISE EXCEPTION 'actualizar_alertas_vencimiento quedo con ACL default';
  END IF;
  IF v_acl LIKE '=X/%' OR v_acl LIKE '%,=X/%' THEN
    RAISE EXCEPTION 'actualizar_alertas_vencimiento quedo ejecutable por PUBLIC: %', v_acl;
  END IF;
  IF v_acl LIKE '%anon=%' THEN
    RAISE EXCEPTION 'actualizar_alertas_vencimiento quedo ejecutable por anon: %', v_acl;
  END IF;
  IF v_acl NOT LIKE '%authenticated=X%' THEN
    RAISE EXCEPTION 'actualizar_alertas_vencimiento no quedo ejecutable por authenticated: %', v_acl;
  END IF;
END
$verif$;

COMMIT;
