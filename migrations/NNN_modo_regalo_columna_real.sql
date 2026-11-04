-- NNN · El modo de la foto del regalo llega al front como columna real (#1417).
--
-- QUÉ PASABA
--   La 442 (#1376, punto 2) le dio al front el modo de la foto con una columna computada,
--   regalo_mueve_stock_foto(pedido_items). PostgREST le pasa a una columna computada la fila
--   entera, y pasarla exige SELECT sobre todas las columnas de pedido_items, incluida
--   costo_unitario_al_crear, que authenticated no lee desde la 327: la lista de Pedidos dio
--   403 para todos los roles (#1416). El front volvió al modo de la promo de hoy
--   (promociones.regalo_mueve_stock), que anticipa otra cosa que lo que hace el server si la
--   promo cambió de tipo: la cancelación por falta de stock, la sustitución del regalo y la
--   cantidad en la boleta.
--
-- QUÉ CAMBIA
--   · pedido_items.regalo_mueve_stock_foto es una columna real, con el mismo nombre que la
--     computada: el front ya la lee (cancelacionFaltaStock, unidadesRegalo, ModalEditarPedido),
--     y una PWA anterior a #1416 que todavía la pide vuelve a andar. Vale lo que devuelve
--     _regalo_modo_del_pedido, que es lo que usa el server: en un regalo de promo, el modo de
--     la foto (pedido_promo_reglas) y, sin foto, el de la promo; NULL en el resto.
--   · La sella sellar_modo_regalo_item, BEFORE INSERT y BEFORE UPDATE de las columnas de las
--     que depende y de ella misma: escrita a mano se vuelve a calcular. Ninguna RPC cambia:
--     crear_pedido_completo, el bot, la edición, dividir y sustituir insertan por el trigger.
--   · En el alta la foto todavía no existe. La toma capturar_promo_del_pedido después del
--     INSERT, leyendo la promo de nuevo; si en el medio otra transacción le cambió el tipo, la
--     línea diría un modo y el server haría otro. verificar_modo_regalo_item (AFTER INSERT,
--     corre después de capturar por el nombre) lo rechaza con 40001, que se reintenta.
--   · Con una línea de regalo viva la foto no cambia de modo: capturar_promo_del_pedido no lo
--     pisa (#1324) y actualizar_pedido_items lo rehace sólo en una foto sin regalo vivo. Por
--     eso la columna no se desalinea de la foto.
--   · authenticated la lee por columna, sin anon (el SELECT de pedido_items sigue siendo por
--     columna, #1003), y se suma a PEDIDO_ITEM_COLUMNAS.
--   · Se dropea regalo_mueve_stock_foto(pedido_items): no la usa nada desde #1416, y tenía
--     EXECUTE para authenticated.
--   · Se llenan las líneas que ya existen (1.888 regalos de promo el 04/11, todos con foto),
--     sin la auditoría: no es una edición de nadie, como la 293.
--
-- QUÉ NO CAMBIA
--   capturar_promo_del_pedido, _regalo_modo_del_pedido, las RPCs y lo que hace el server: sigue
--   leyendo la foto. La columna es su espejo para el front.
--
-- Revertir: DROP de los dos triggers y de sus funciones, DROP COLUMN, y volver a crear
-- regalo_mueve_stock_foto(pedido_items) como en la 442, sin pedirla en ningún select.
--
-- Ensayo: scripts/test-modo-foto-regalo-1417.sql.
-- Aplicar desde el contenido LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

DO $premisas$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('public.regalo_mueve_stock_foto(public.pedido_items)', '72b39183fe1fc2e29ddbac729f40943d'),
      ('public._regalo_modo_del_pedido(bigint,bigint,bigint)', 'a6b34b20f9cb25e88c1c78746309da41'),
      ('public.capturar_promo_del_pedido()', 'b4926b8557e7269eef4258fb39626488')
    ) AS t(firma, hash)
  LOOP
    IF to_regprocedure(r.firma) IS NULL THEN
      RAISE EXCEPTION '% no existe en prod: rehacer sobre lo vigente', r.firma;
    END IF;
    IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = r.firma::regprocedure) <> r.hash THEN
      RAISE EXCEPTION '% cambió en prod (md5 %): rehacer sobre el cuerpo vigente',
        r.firma, (SELECT md5(prosrc) FROM pg_proc WHERE oid = r.firma::regprocedure);
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM pg_attribute
              WHERE attrelid = 'public.pedido_items'::regclass
                AND attname = 'regalo_mueve_stock_foto' AND NOT attisdropped) THEN
    RAISE EXCEPTION 'pedido_items.regalo_mueve_stock_foto ya existe';
  END IF;
  IF has_table_privilege('authenticated', 'public.pedido_items', 'SELECT')
     OR has_column_privilege('authenticated', 'public.pedido_items', 'costo_unitario_al_crear', 'SELECT') THEN
    RAISE EXCEPTION 'el SELECT de pedido_items ya no es por columna para authenticated: revisar antes de seguir';
  END IF;
END
$premisas$;

-- La computada se va antes de que nazca la columna: con las dos, PostgREST tendría dos
-- cosas con el mismo nombre.
DROP FUNCTION public.regalo_mueve_stock_foto(public.pedido_items);

ALTER TABLE public.pedido_items ADD COLUMN regalo_mueve_stock_foto boolean;

COMMENT ON COLUMN public.pedido_items.regalo_mueve_stock_foto IS
  'Si el regalo de esta línea mueve stock según la foto de la promo del pedido (_regalo_modo_del_pedido), no según la promo de hoy (#1417). NULL en una línea de venta o en un regalo sin promo. La sella trg_sellar_modo_regalo_item; es el espejo para el front de lo que lee el server.';

CREATE FUNCTION public.sellar_modo_regalo_item()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- #1417: el modo que usa el server, _regalo_modo_del_pedido: la foto y, si todavía no
  -- hay (el primer regalo de la promo en el alta), la promo, que es de donde sale la foto.
  -- DEFINER porque pedido_promo_reglas es sólo de server, como en capturar_promo_del_pedido.
  -- No se respeta lo que venga cargado: escrita a mano se vuelve a calcular.
  IF COALESCE(NEW.es_bonificacion, false) AND NEW.promocion_id IS NOT NULL THEN
    NEW.regalo_mueve_stock_foto :=
      public._regalo_modo_del_pedido(NEW.pedido_id, NEW.promocion_id, NEW.sucursal_id);
  ELSE
    NEW.regalo_mueve_stock_foto := NULL;
  END IF;
  RETURN NEW;
END
$function$;

CREATE FUNCTION public.verificar_modo_regalo_item()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- #1417: en el alta la línea se selló antes de que existiera la foto, y
  -- capturar_promo_del_pedido (que corre antes que este trigger, por el nombre) la tomó
  -- leyendo la promo otra vez. Si en el medio otra transacción le cambió el tipo, la línea
  -- diría un modo y el server haría otro: se rechaza el INSERT entero, que se reintenta.
  IF NEW.regalo_mueve_stock_foto IS DISTINCT FROM
     public._regalo_modo_del_pedido(NEW.pedido_id, NEW.promocion_id, NEW.sucursal_id) THEN
    RAISE EXCEPTION 'La promoción % cambió de tipo mientras se guardaba el pedido %: volvé a intentar',
      NEW.promocion_id, NEW.pedido_id
      USING ERRCODE = '40001';
  END IF;
  RETURN NULL;
END
$function$;

-- Son de trigger: no necesitan EXECUTE para nadie de la app.
REVOKE ALL ON FUNCTION public.sellar_modo_regalo_item() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.verificar_modo_regalo_item() FROM PUBLIC, anon, authenticated;

-- Las líneas que ya existen, antes de los triggers y sin la auditoría (no es una edición
-- de nadie). El ALTER TABLE de arriba ya tiene la tabla tomada hasta el COMMIT.
ALTER TABLE public.pedido_items DISABLE TRIGGER audit_pedido_items;
UPDATE public.pedido_items
   SET regalo_mueve_stock_foto = public._regalo_modo_del_pedido(pedido_id, promocion_id, sucursal_id)
 WHERE COALESCE(es_bonificacion, false) AND promocion_id IS NOT NULL;
ALTER TABLE public.pedido_items ENABLE TRIGGER audit_pedido_items;

CREATE TRIGGER trg_sellar_modo_regalo_item
  BEFORE INSERT OR UPDATE OF es_bonificacion, promocion_id, pedido_id, sucursal_id, regalo_mueve_stock_foto
  ON public.pedido_items
  FOR EACH ROW EXECUTE FUNCTION public.sellar_modo_regalo_item();

CREATE TRIGGER trg_verificar_modo_regalo_item
  AFTER INSERT ON public.pedido_items
  FOR EACH ROW WHEN (NEW.es_bonificacion AND NEW.promocion_id IS NOT NULL)
  EXECUTE FUNCTION public.verificar_modo_regalo_item();

-- La lista entera, como la 2/2 de #1003: el último GRANT de migrations/ es la lista vigente y
-- pedidoItemColumnas.test.ts la compara con PEDIDO_ITEM_COLUMNAS. Volver a conceder las que
-- ya tenía no cambia nada; el costo sigue afuera.
GRANT SELECT (id, pedido_id, producto_id, cantidad, precio_unitario, subtotal, es_bonificacion, promocion_id, neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva, sucursal_id, tp_import_id, descripcion_regalo, stock_al_crear, ingreso_real_unitario, precio_lista_al_crear, origen_precio, descuento_pct, grupo_precio_escala_id, unidades_por_bloque_al_crear, origen_unidades_por_bloque, regalo_cadena_id, combo_id, precio_sin_combo_unitario, combo_roto_id, regalo_mueve_stock_foto) ON public.pedido_items TO authenticated;

DO $post$
DECLARE
  r record;
  v_n bigint;
BEGIN
  IF to_regprocedure('public.regalo_mueve_stock_foto(public.pedido_items)') IS NOT NULL THEN
    RAISE EXCEPTION 'regalo_mueve_stock_foto(pedido_items) sigue existiendo';
  END IF;

  FOR r IN
    SELECT t.firma, t.hash, md5(p.prosrc) AS h, p.proacl::text AS a
      FROM (VALUES
        ('public.sellar_modo_regalo_item()', 'c379fecae5e696070edd9907d20d0eb9'),
        ('public.verificar_modo_regalo_item()', '6e47a167be05bd816f0c900ddcbdcaa5')
      ) AS t(firma, hash)
      JOIN pg_proc p ON p.oid = t.firma::regprocedure
  LOOP
    IF r.h <> r.hash OR r.a IS DISTINCT FROM '{postgres=X/postgres,service_role=X/postgres}' THEN
      RAISE EXCEPTION '% no quedó como en el repo (md5 %, acl %)', r.firma, r.h, r.a;
    END IF;
  END LOOP;

  IF NOT has_column_privilege('authenticated', 'public.pedido_items', 'regalo_mueve_stock_foto', 'SELECT')
     OR has_column_privilege('anon', 'public.pedido_items', 'regalo_mueve_stock_foto', 'SELECT')
     OR has_table_privilege('authenticated', 'public.pedido_items', 'SELECT')
     OR has_column_privilege('authenticated', 'public.pedido_items', 'costo_unitario_al_crear', 'SELECT') THEN
    RAISE EXCEPTION 'los grants de pedido_items no quedaron por columna (authenticated la nueva, anon nada, el costo afuera)';
  END IF;

  SELECT count(*) INTO v_n
    FROM public.pedido_items i
   WHERE i.regalo_mueve_stock_foto IS DISTINCT FROM
         CASE WHEN COALESCE(i.es_bonificacion, false) AND i.promocion_id IS NOT NULL
              THEN public._regalo_modo_del_pedido(i.pedido_id, i.promocion_id, i.sucursal_id) END;
  IF v_n > 0 THEN
    RAISE EXCEPTION '% línea(s) con la columna distinta de _regalo_modo_del_pedido', v_n;
  END IF;

  SELECT count(*) INTO v_n
    FROM pg_trigger
   WHERE tgrelid = 'public.pedido_items'::regclass
     AND ((tgname = 'audit_pedido_items' AND tgenabled = 'O')
       OR (tgname IN ('trg_sellar_modo_regalo_item', 'trg_verificar_modo_regalo_item') AND tgenabled = 'O'));
  IF v_n <> 3 THEN
    RAISE EXCEPTION 'los triggers de pedido_items no quedaron habilitados (% de 3)', v_n;
  END IF;
END
$post$;

NOTIFY pgrst, 'reload schema';

COMMIT;
